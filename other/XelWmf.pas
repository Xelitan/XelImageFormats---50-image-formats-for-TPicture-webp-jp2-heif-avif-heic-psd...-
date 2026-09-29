unit XelWmf;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$R-}{$Q-}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Windows Metafile (WMF / EMF / WMZ / EMZ) -> SVG converter      //
// Version:	0.2                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// A metafile is a recorded list of GDI calls. This unit plays those calls on a
// small GDI emulator (mapping modes, window / viewport, EMF world transform,
// DC save / restore, pens, brushes, fonts, EMF paths) and writes what would be
// drawn as an SVG document, which the wrapper renders with SimpleSVG. Only SVG
// that SimpleSVG understands is produced: <path> (lines and cubic curves, with
// fill-rule, dashes, opacity, caps / joins), <text>, <pattern> tiles and
// <clipPath> groups. Everything is converted to output pixels, so no SVG
// transforms are needed except rotation for text.
//
// Clipping (rectangles, regions, paths), dashed pens and hatch / pattern
// brushes are reproduced. EMF+ (GDI+) records are played for EMF+-only files
// and, by default, for dual files (see WmfUseEmfPlus): transforms,
// containers, clips, alpha, hatch / texture brushes, linear and path
// gradients (as colour bands / rings), pens, curves, text (with word wrap
// from built-in font widths) and images, including nested metafiles.
//
// Not reproduced: raster operations other than plain copy (a few mask
// tricks are approximated), anti-aliasing, partial image alpha (a pixel is
// drawn or not), texture brush rotation, EMF+ custom caps and compound pens.

interface

uses
  SysUtils, Classes, Math, XelInflate, XelJpeg, XelPng, XelGif, XelBmp, XelTiff;

type
  EWmfError = class(Exception);

// True for WMF (placeable or not), EMF and gzip-compressed variants.
function IsMetafile(const Data: TBytes): Boolean;

var
  // EMF files with both EMF+ and EMF records (dual): True plays the EMF+
  // records (what GDI+ shows: alpha, gradients, anti-aliasing aside), and
  // falls back to the EMF records when the EMF+ part needs something not
  // reproduced here (text wrapped in a layout box, glyph-index text, an
  // undecodable image); False always plays the EMF records (what GDI shows).
  // EMF+-only files are always played as EMF+.
  WmfUseEmfPlus: Boolean = True;

// Converts a WMF / EMF / WMZ / EMZ file to an SVG document. Width and Height
// are the natural picture size in pixels (96 dpi), also written to the SVG.
function MetafileToSvg(const Data: TBytes; out Width, Height: Integer): string;

implementation

const
  MAX_SIDE = 4096;          // largest output side in pixels
  MAX_BITMAP_CELLS = 250000; // bitmap rect budget per image

type
  TXf = record              // x' = A x + C y + E,  y' = B x + D y + F
    A, B, C, D, E, F: Double;
  end;

  TRGBAImage = record
    W, H: Integer;
    Px: array of Cardinal;  // $AARRGGBB, top-down
  end;

  TClipRect = record
    L, T, R, B: Double;     // output pixels
  end;
  TClipRects = array of TClipRect;
  TStrArr = array of string;
  TSvgNums = array of Double;

  TPenRec = record
    Style: Integer;         // PS_* (low byte); 5 = null
    Width: Double;          // logical units, 0 = cosmetic (1 px)
    Color: Cardinal;
    Cosmetic: Boolean;
    Dash: array of Double;  // PS_USERSTYLE entries
    Transp: Integer;        // 255 - alpha (EMF+); 0 = opaque
    Cap, Join: Integer;     // EMF+: 1 butt / 2 round / 3 square; 1 miter / 2 bevel / 3 round (0 = from Style)
  end;

  TBrushRec = record
    Style: Integer;         // 0 solid, 1 null, 2 hatched, 3 pattern, 4 image tile (EMF+)
    Color: Cardinal;
    Hatch: Integer;
    Pat: TRGBAImage;        // pattern brush bitmap (empty = unknown)
    Mono: Boolean;          // monochrome pattern: text / background colours
    Transp: Integer;        // 255 - alpha (EMF+); 0 = opaque
    PatXf: TXf;             // style 4: tile pixel -> output (scale and offset used)
  end;

  TFontRec = record
    Height, Escapement, Weight: Integer;
    Italic, Underline, StrikeOut: Boolean;
    Charset: Integer;
    Face: string;
    EmHeight: Double;       // > 0: em size in logical units (EMF+), overrides Height
  end;

  TObjKind = (okNone, okPen, okBrush, okFont, okRegion, okOther);
  TGdiObj = record
    Kind: TObjKind;
    Pen: TPenRec;
    Brush: TBrushRec;
    Font: TFontRec;
    Region: array of Double; // WMF region: l,t,r,b quadruples, logical units
  end;

  TDC = record
    MapMode: Integer;
    WinOrgX, WinOrgY, WinExtX, WinExtY: Double;
    VpOrgX, VpOrgY, VpExtX, VpExtY: Double;
    World: TXf;
    Pen: TPenRec;
    Brush: TBrushRec;
    Font: TFontRec;
    TextColor, BkColor: Cardinal;
    TextTransp: Integer;    // 255 - alpha of text (EMF+)
    BkMode, PolyFill, TextAlign, ArcDir: Integer;
    CurX, CurY: Double;
    // clipping: ClipOn = a rectangle region is in force; each ClipPaths
    // entry ("N|" or "E|" + path data) is intersected with it
    ClipOn: Boolean;
    ClipRects: TClipRects;
    ClipPaths: TStrArr;
    ClipId: Integer;        // changes whenever the clip changes
  end;

  TDCArr = array of TDC;
  TGdiObjArr = array of TGdiObj;

  // The GDI emulator; the WMF and EMF players drive it.
  TGdi = class
  private
    FOut: TStringBuilder;
    FFS: TFormatSettings;
    FMeasure: Boolean;      // pass that only collects the drawing's bounds
    FMinX, FMinY, FMaxX, FMaxY: Double;
    FInPath: Boolean;
    FPath: TStringBuilder;  // current EMF path in output coordinates
    FFigureOpen: Boolean;
    FClipSerial, FCurClip, FGroupDepth, FDefSerial: Integer;
    FPatterns: TStringList; // pattern key -> id
    procedure PutDef(const S: string);
    procedure SyncClip;
    procedure NewClip;
    function DevScale: Double;
    function HatchUrl: string;
    function PatternUrl: string;
    function ImagePatUrl: string;
    procedure AddRun(Runs: TStringList; c: Cardinal; x, y, w, h: Double);
    function FlushRuns(Runs: TStringList): string;
    function N(v: Double): string;
    function Color(c: Cardinal): string;
    procedure Track(x, y: Double);
    function StrokeAttr: string;
    function DashAttr(w: Double): string;
    function FillAttr: string;
    function HasFill: Boolean;
    function HasStroke: Boolean;
    procedure Put(const S: string);
  public
    DC: TDC;
    Stack: TDCArr;
    Objects: TGdiObjArr;
    OutScaleX, OutScaleY, OutOffX, OutOffY: Double;   // device -> output
    DevPxPerMmX, DevPxPerMmY: Double;                 // reference device
    NoPlus: Boolean;        // play dual EMF files from their EMF records
    PlusLossy: Boolean;     // the EMF+ player met something it cannot reproduce
    constructor Create(AMeasure: Boolean);
    destructor Destroy; override;
    procedure ResetDC;
    function Full: TXf;                 // logical -> output
    procedure Map(x, y: Double; out ox, oy: Double);
    function LinScaleX: Double;         // output length of one logical x unit
    function LinScaleY: Double;
    function Flipped: Boolean;
    // building shapes: logical coordinates in, output path data out
    procedure PathMove(sb: TStringBuilder; x, y: Double);
    procedure PathLine(sb: TStringBuilder; x, y: Double);
    procedure PathCubic(sb: TStringBuilder; x1, y1, x2, y2, x3, y3: Double);
    procedure EllipseArc(sb: TStringBuilder; cx, cy, rx, ry, t0, sweep: Double; MoveFirst: Boolean);
    procedure EmitShape(const D: string; DoFill, DoStroke: Boolean);
    // GDI operations
    procedure SaveDC;
    procedure RestoreDC(n: Integer);
    procedure SelectObj(Index: Integer);
    procedure SelectStock(Index: Integer);
    function NewObjectSlot: Integer;    // WMF: lowest free slot
    procedure SetObj(Index: Integer; const O: TGdiObj);
    procedure DeleteObj(Index: Integer);
    procedure MoveTo(x, y: Double);
    procedure LineTo(x, y: Double);
    procedure Poly(const Pts: array of Double; Count: Integer; Closed, Draw: Boolean);
    procedure PolyPoly(const Pts: array of Double; const Counts: array of Integer; Closed: Boolean);
    procedure PolyBezier(const Pts: array of Double; Count: Integer; FromCurrent: Boolean);
    procedure Rectangle(l, t, r, b: Double);
    procedure RoundRect(l, t, r, b, ew, eh: Double);
    procedure Ellipse(l, t, r, b: Double);
    procedure ArcShape(l, t, r, b, xs, ys, xe, ye: Double; Kind: Integer); // 0 arc,1 chord,2 pie,3 arcto
    procedure AngleArc(cx, cy, r, StartDeg, SweepDeg: Double);
    procedure FillRectColor(l, t, r, b: Double; c: Cardinal);
    procedure FillRectBrush(l, t, r, b: Double);
    procedure SetPixel(x, y: Double; c: Cardinal);
    procedure BeginPath;
    procedure EndPath;
    procedure CloseFigure;
    procedure DrawPath(DoFill, DoStroke: Boolean);
    procedure AbortPath;
    procedure Text(x, y: Double; const S: string; const Dx: array of Double; HasDx: Boolean);
    procedure Bitmap(const Img: TRGBAImage; dl, dt, dw, dh: Double; sx, sy, sw, sh: Integer; Rop: Cardinal);
    procedure GradientRect(x0, y0, x1, y1: Double; c0, c1: Cardinal; Vertical: Boolean);
    // clipping
    procedure ClipRectLogical(l, t, r, b: Double; Exclude: Boolean);
    procedure ClipRectsOutput(const Rects: TClipRects; Mode: Integer);
    procedure ClipResetAll;
    procedure ClipSelectPath(Mode: Integer);
    procedure ClipOffset(dx, dy: Double);
    procedure SelectAny(Index: Integer);
    function BuildSvg(W, H: Integer): string;
  end;

// ---------------------------- small helpers -------------------------------

function RdU8(const D: TBytes; P: NativeInt): Integer; inline;
begin
  if (P >= 0) and (P < Length(D)) then Result := D[P] else Result := 0;
end;

function RdU16(const D: TBytes; P: NativeInt): Integer; inline;
begin
  Result := RdU8(D, P) or (RdU8(D, P + 1) shl 8);
end;

function RdI16(const D: TBytes; P: NativeInt): Integer; inline;
begin
  Result := SmallInt(RdU16(D, P));
end;

function RdU32(const D: TBytes; P: NativeInt): Cardinal; inline;
begin
  Result := Cardinal(RdU16(D, P)) or (Cardinal(RdU16(D, P + 2)) shl 16);
end;

function RdI32(const D: TBytes; P: NativeInt): Integer; inline;
begin
  Result := Integer(RdU32(D, P));
end;

function RdF32(const D: TBytes; P: NativeInt): Double;
var c: Cardinal; s: Single;
begin
  c := RdU32(D, P);
  if (c and $7F800000) = $7F800000 then Exit(0);   // NaN / Inf
  Move(c, s, 4);
  Result := s;
end;

function Ident: TXf;
begin
  Result.A := 1; Result.B := 0; Result.C := 0; Result.D := 1; Result.E := 0; Result.F := 0;
end;

// M1 applied after M2
function XfMul(const M1, M2: TXf): TXf;
begin
  Result.A := M1.A * M2.A + M1.C * M2.B;
  Result.B := M1.B * M2.A + M1.D * M2.B;
  Result.C := M1.A * M2.C + M1.C * M2.D;
  Result.D := M1.B * M2.C + M1.D * M2.D;
  Result.E := M1.A * M2.E + M1.C * M2.F + M1.E;
  Result.F := M1.B * M2.E + M1.D * M2.F + M1.F;
end;

function XmlEscape(const S: string): string;
var i: Integer; c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      #0..#8, #11, #12, #14..#31: ;              // not allowed in XML
    else
      Result := Result + c;
    end;
  end;
end;

// Windows-1252 byte -> UTF-8 (the usual metafile text encoding).
function Cp1252ToUtf8(const B: array of Byte; Count: Integer): string;
const
  Hi: array[$80..$9F] of Word = (
    $20AC,$0081,$201A,$0192,$201E,$2026,$2020,$2021,$02C6,$2030,$0160,$2039,$0152,$008D,$017D,$008F,
    $0090,$2018,$2019,$201C,$201D,$2022,$2013,$2014,$02DC,$2122,$0161,$203A,$0153,$009D,$017E,$0178);
var
  i: Integer;
  u: UnicodeString;
  w: Word;
begin
  SetLength(u, Count);
  for i := 0 to Count - 1 do
  begin
    w := B[i];
    if (w >= $80) and (w <= $9F) then w := Hi[w];
    u[i + 1] := WideChar(w);
  end;
  Result := UTF8Encode(u);
end;

// ANSI text with a GDI charset -> UTF-8.
function AnsiToUtf8(const B: array of Byte; Count, Charset: Integer): string;
var
  cp: Integer;
  r: RawByteString;
begin
  case Charset of
    238: cp := 1250;  204: cp := 1251;  161: cp := 1253;  162: cp := 1254;
    177: cp := 1255;  178: cp := 1256;  186: cp := 1257;  163: cp := 1258;
    222: cp := 874;   128: cp := 932;   134: cp := 936;   129: cp := 949;
    136: cp := 950;
  else
    cp := 1252;
  end;
  if cp = 1252 then Exit(Cp1252ToUtf8(B, Count));
  SetLength(r, Count);
  if Count > 0 then Move(B[0], r[1], Count);
  SetCodePage(r, cp, False);
  Result := UTF8Encode(UnicodeString(r));
end;

// ------------------------------- TGdi -------------------------------------

constructor TGdi.Create(AMeasure: Boolean);
begin
  inherited Create;
  FOut := TStringBuilder.Create;
  FPath := TStringBuilder.Create;
  FFS := DefaultFormatSettings;
  FFS.DecimalSeparator := '.';
  FPatterns := TStringList.Create;
  FMeasure := AMeasure;
  FMinX := MaxDouble; FMinY := MaxDouble; FMaxX := -MaxDouble; FMaxY := -MaxDouble;
  OutScaleX := 1; OutScaleY := 1; OutOffX := 0; OutOffY := 0;
  DevPxPerMmX := 96 / 25.4; DevPxPerMmY := 96 / 25.4;
  ResetDC;
end;

destructor TGdi.Destroy;
begin
  FOut.Free;
  FPath.Free;
  FPatterns.Free;
  inherited;
end;

procedure TGdi.ResetDC;
begin
  DC := Default(TDC);
  DC.MapMode := 1;
  DC.WinExtX := 1; DC.WinExtY := 1; DC.VpExtX := 1; DC.VpExtY := 1;
  DC.World := Ident;
  DC.Pen.Style := 0; DC.Pen.Width := 0; DC.Pen.Color := 0; DC.Pen.Cosmetic := True;
  DC.Brush.Style := 0; DC.Brush.Color := $FFFFFF;
  DC.Font.Height := 0; DC.Font.Weight := 400; DC.Font.Face := 'Arial';
  DC.TextColor := 0; DC.BkColor := $FFFFFF;
  DC.BkMode := 2; DC.PolyFill := 1; DC.TextAlign := 0; DC.ArcDir := 1;
end;

function TGdi.N(v: Double): string;
var i: Integer;
begin
  if Abs(v) < 0.005 then Exit('0');
  Result := FloatToStrF(v, ffFixed, 15, 2, FFS);
  if Pos('.', Result) > 0 then
  begin
    i := Length(Result);
    while Result[i] = '0' do Dec(i);
    if Result[i] = '.' then Dec(i);
    SetLength(Result, i);
  end;
end;

function TGdi.Color(c: Cardinal): string;
begin
  Result := '#' + IntToHex(c and $FF, 2) + IntToHex((c shr 8) and $FF, 2) +
            IntToHex((c shr 16) and $FF, 2);
end;

procedure TGdi.Track(x, y: Double);
begin
  if x < FMinX then FMinX := x;
  if x > FMaxX then FMaxX := x;
  if y < FMinY then FMinY := y;
  if y > FMaxY then FMaxY := y;
end;

procedure TGdi.PutDef(const S: string);
begin
  if not FMeasure then FOut.Append(S).Append(#10);
end;

// drawing output: brings the open clip groups in line with the DC first
procedure TGdi.Put(const S: string);
begin
  if FMeasure then Exit;
  SyncClip;
  FOut.Append(S).Append(#10);
end;

function TGdi.DevScale: Double;
begin
  Result := Sqrt(Abs(OutScaleX * OutScaleY));
  if Result <= 0 then Result := 1;
end;

procedure TGdi.NewClip;
begin
  Inc(FClipSerial);
  DC.ClipId := FClipSerial;
end;

// The clip is written as nested groups: one for the rectangle region and one
// per clip path, each referring to its own <clipPath>.
procedure TGdi.SyncClip;
var
  i, j: Integer;
  id, d, rule: string;
  r: TClipRect;
begin
  if DC.ClipId = FCurClip then Exit;
  for i := 1 to FGroupDepth do FOut.Append('</g>').Append(#10);
  FGroupDepth := 0;
  FCurClip := DC.ClipId;
  if DC.ClipOn then
  begin
    Inc(FDefSerial);
    id := 'clip' + IntToStr(FDefSerial);
    d := '';
    for j := 0 to High(DC.ClipRects) do
    begin
      r := DC.ClipRects[j];
      d := d + 'M' + N(r.L) + ' ' + N(r.T) + ' L' + N(r.R) + ' ' + N(r.T) + ' L' + N(r.R) + ' ' +
           N(r.B) + ' L' + N(r.L) + ' ' + N(r.B) + ' Z ';
    end;
    if d = '' then
      FOut.Append('<clipPath id="' + id + '"></clipPath>').Append(#10)   // clips everything
    else
      FOut.Append('<clipPath id="' + id + '"><path d="' + Trim(d) + '" clip-rule="nonzero"/></clipPath>').Append(#10);
    FOut.Append('<g clip-path="url(#' + id + ')">').Append(#10);
    Inc(FGroupDepth);
  end;
  for j := 0 to High(DC.ClipPaths) do
  begin
    Inc(FDefSerial);
    id := 'clip' + IntToStr(FDefSerial);
    if Copy(DC.ClipPaths[j], 1, 1) = 'N' then rule := 'nonzero' else rule := 'evenodd';
    FOut.Append('<clipPath id="' + id + '"><path d="' + Trim(Copy(DC.ClipPaths[j], 3, MaxInt)) +
      '" clip-rule="' + rule + '"/></clipPath>').Append(#10);
    FOut.Append('<g clip-path="url(#' + id + ')">').Append(#10);
    Inc(FGroupDepth);
  end;
end;

// ---- clip region algebra on rectangles (like GDI regions) ----

const
  CLIP_INF = 2e6;
  RGN_AND = 1; RGN_OR = 2; RGN_XOR = 3; RGN_DIFF = 4; RGN_COPY = 5;

function ClipRect(l, t, r, b: Double): TClipRect;
begin
  Result.L := Min(l, r); Result.R := Max(l, r);
  Result.T := Min(t, b); Result.B := Max(t, b);
end;

function RectsHave(const A: TClipRects; x, y: Double): Boolean;
var i: Integer;
begin
  for i := 0 to High(A) do
    if (x > A[i].L) and (x < A[i].R) and (y > A[i].T) and (y < A[i].B) then Exit(True);
  Result := False;
end;

procedure SortUnique(var V: TSvgNums);
var i, j, n: Integer; t: Double;
begin
  for i := 1 to High(V) do
  begin
    t := V[i]; j := i - 1;
    while (j >= 0) and (V[j] > t) do begin V[j + 1] := V[j]; Dec(j); end;
    V[j + 1] := t;
  end;
  n := 0;
  for i := 0 to High(V) do
    if (n = 0) or (V[i] > V[n - 1] + 1e-9) then begin V[n] := V[i]; Inc(n); end;
  SetLength(V, n);
end;

// Boolean operation of two rectangle sets, evaluated on the grid of all their
// edges; each row's kept cells are merged into rectangles.
function ClipOp(const A, B: TClipRects; Op: Integer): TClipRects;
var
  xs, ys: TSvgNums;
  i, j, k, n: Integer;
  cx, cy, x0: Double;
  ina, inb, keep, run: Boolean;

  procedure Emit(l, t, r, b: Double);
  begin
    SetLength(Result, n + 1);
    Result[n] := ClipRect(l, t, r, b);
    Inc(n);
  end;

begin
  Result := nil; n := 0;
  if Op = RGN_COPY then Exit(Copy(B));
  SetLength(xs, (Length(A) + Length(B)) * 2);
  SetLength(ys, Length(xs));
  k := 0;
  for i := 0 to High(A) do
  begin
    xs[k] := A[i].L; ys[k] := A[i].T; Inc(k); xs[k] := A[i].R; ys[k] := A[i].B; Inc(k);
  end;
  for i := 0 to High(B) do
  begin
    xs[k] := B[i].L; ys[k] := B[i].T; Inc(k); xs[k] := B[i].R; ys[k] := B[i].B; Inc(k);
  end;
  SortUnique(xs); SortUnique(ys);
  if Int64(Length(xs)) * Length(ys) > 250000 then
  begin
    // too complex for the grid: a simple approximation
    case Op of
      RGN_OR:
        begin
          Result := Copy(A);
          for i := 0 to High(B) do
          begin
            SetLength(Result, Length(Result) + 1);
            Result[High(Result)] := B[i];
          end;
        end;
      RGN_AND:
        for i := 0 to High(A) do
          for j := 0 to High(B) do
            if (Max(A[i].L, B[j].L) < Min(A[i].R, B[j].R)) and (Max(A[i].T, B[j].T) < Min(A[i].B, B[j].B)) then
              Emit(Max(A[i].L, B[j].L), Max(A[i].T, B[j].T), Min(A[i].R, B[j].R), Min(A[i].B, B[j].B));
    else
      Result := Copy(A);
    end;
    Exit;
  end;
  for j := 0 to High(ys) - 1 do
  begin
    cy := (ys[j] + ys[j + 1]) / 2;
    run := False; x0 := 0;
    for i := 0 to High(xs) - 1 do
    begin
      cx := (xs[i] + xs[i + 1]) / 2;
      ina := RectsHave(A, cx, cy); inb := RectsHave(B, cx, cy);
      case Op of
        RGN_AND: keep := ina and inb;
        RGN_OR: keep := ina or inb;
        RGN_XOR: keep := ina xor inb;
      else keep := ina and not inb;          // RGN_DIFF
      end;
      if keep and not run then begin run := True; x0 := xs[i]; end
      else if (not keep) and run then begin run := False; Emit(x0, ys[j], xs[i], ys[j + 1]); end;
    end;
    if run then Emit(x0, ys[j], xs[High(xs)], ys[j + 1]);
  end;
end;

function InfiniteClip: TClipRects;
begin
  SetLength(Result, 1);
  Result[0] := ClipRect(-CLIP_INF, -CLIP_INF, CLIP_INF, CLIP_INF);
end;

// IntersectClipRect / ExcludeClipRect: a logical rectangle (its bounding box
// in device space when the transform rotates it).
procedure TGdi.ClipRectLogical(l, t, r, b: Double; Exclude: Boolean);
var
  R1: TClipRects;
  x0, y0, x1, y1, x2, y2, x3, y3: Double;
begin
  Map(l, t, x0, y0); Map(r, t, x1, y1); Map(r, b, x2, y2); Map(l, b, x3, y3);
  SetLength(R1, 1);
  R1[0] := ClipRect(Min(Min(x0, x1), Min(x2, x3)), Min(Min(y0, y1), Min(y2, y3)),
                    Max(Max(x0, x1), Max(x2, x3)), Max(Max(y0, y1), Max(y2, y3)));
  if Exclude then
  begin
    if DC.ClipOn then DC.ClipRects := ClipOp(DC.ClipRects, R1, RGN_DIFF)
    else DC.ClipRects := ClipOp(InfiniteClip, R1, RGN_DIFF);
  end
  else if DC.ClipOn then DC.ClipRects := ClipOp(DC.ClipRects, R1, RGN_AND)
  else DC.ClipRects := R1;
  DC.ClipOn := True;
  NewClip;
end;

// SelectClipRgn / ExtSelectClipRgn with a region already in output pixels.
procedure TGdi.ClipRectsOutput(const Rects: TClipRects; Mode: Integer);
begin
  case Mode of
    RGN_COPY:
      begin
        DC.ClipRects := Copy(Rects); DC.ClipOn := True; DC.ClipPaths := nil;
      end;
    RGN_AND:
      begin
        if DC.ClipOn then DC.ClipRects := ClipOp(DC.ClipRects, Rects, RGN_AND)
        else DC.ClipRects := Copy(Rects);
        DC.ClipOn := True;
      end;
    RGN_OR:
      if DC.ClipOn then DC.ClipRects := ClipOp(DC.ClipRects, Rects, RGN_OR)
      else Exit;                               // everything OR x = everything
  else
    begin                                      // XOR / DIFF
      if DC.ClipOn then DC.ClipRects := ClipOp(DC.ClipRects, Rects, Mode)
      else DC.ClipRects := ClipOp(InfiniteClip, Rects, Mode);
      DC.ClipOn := True;
    end;
  end;
  NewClip;
end;

procedure TGdi.ClipResetAll;
begin
  DC.ClipOn := False; DC.ClipRects := nil; DC.ClipPaths := nil;
  NewClip;
end;

// SelectClipPath: the current path becomes (part of) the clip.
procedure TGdi.ClipSelectPath(Mode: Integer);
var d, e: string; P: TStrArr;
begin
  FInPath := False;
  d := Trim(FPath.ToString);
  FPath.Clear;
  if d = '' then Exit;
  if DC.PolyFill = 2 then e := 'N|' + d else e := 'E|' + d;
  if Mode = RGN_COPY then
  begin
    DC.ClipOn := False; DC.ClipRects := nil;
    SetLength(P, 1); P[0] := e;
  end
  else
  begin
    // AND (and, approximately, the other modes) intersects
    P := Copy(DC.ClipPaths);
    SetLength(P, Length(P) + 1);
    P[High(P)] := e;
  end;
  DC.ClipPaths := P;
  NewClip;
end;

procedure TGdi.ClipOffset(dx, dy: Double);
var M: TXf; ox, oy: Double; i: Integer; R1: TClipRects;
begin
  if not DC.ClipOn then Exit;
  M := Full;
  ox := M.A * dx + M.C * dy; oy := M.B * dx + M.D * dy;
  R1 := Copy(DC.ClipRects);
  for i := 0 to High(R1) do
  begin
    R1[i].L := R1[i].L + ox; R1[i].R := R1[i].R + ox;
    R1[i].T := R1[i].T + oy; R1[i].B := R1[i].B + oy;
  end;
  DC.ClipRects := R1;
  NewClip;
end;

// ---- pixel runs ----
// Pattern pixels and bitmap cells are written as polygon paths, one path per
// colour: GDI fills adjacent polygons edge to edge, whereas a pen-less
// Rectangle() leaves its right / bottom edge out (a 1-pixel rect would vanish).

procedure TGdi.AddRun(Runs: TStringList; c: Cardinal; x, y, w, h: Double);
var i: Integer; sb: TStringBuilder; key: string;
begin
  key := IntToHex(c and $FFFFFF, 6);
  i := Runs.IndexOf(key);
  if i < 0 then i := Runs.AddObject(key, TStringBuilder.Create);
  sb := TStringBuilder(Runs.Objects[i]);
  sb.Append('M').Append(N(x)).Append(' ').Append(N(y)).Append(' h').Append(N(w))
    .Append(' v').Append(N(h)).Append(' h').Append(N(-w)).Append(' Z ');
end;

function TGdi.FlushRuns(Runs: TStringList): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to Runs.Count - 1 do
  begin
    Result := Result + '<path d="' + Trim(TStringBuilder(Runs.Objects[i]).ToString) +
      '" fill="#' + Runs[i] + '" stroke="none"/>';
    Runs.Objects[i].Free;
  end;
  Runs.Clear;
end;

// ---- hatch and pattern brushes as <pattern> ----

// GDI hatches are 8 x 8 device pixels anchored at the device origin; the
// background shows only in OPAQUE background mode.
function TGdi.HatchUrl: string;
var
  key, id, def: string;
  s: Double;
  x, y, i, hs: Integer;
  bits: array[0..7, 0..7] of Boolean;
  runs: TStringList;
  fg: Cardinal;
begin
  hs := DC.Brush.Hatch;
  key := 'h' + IntToStr(hs) + '_' + IntToHex(DC.Brush.Color, 6) + '_' + IntToStr(DC.BkMode) + '_' + IntToHex(DC.BkColor, 6);
  i := FPatterns.IndexOfName(key);
  if i >= 0 then Exit('url(#' + FPatterns.ValueFromIndex[i] + ')');
  Inc(FDefSerial);
  id := 'pat' + IntToStr(FDefSerial);
  FillChar(bits, SizeOf(bits), 0);
  for i := 0 to 7 do
  begin
    if hs in [0, 4] then bits[3, i] := True;            // horizontal
    if hs in [1, 4] then bits[i, 3] := True;            // vertical
    if hs in [2, 5] then bits[i, i] := True;            // forward diagonal \
    if hs in [3, 5] then bits[7 - i, i] := True;        // backward diagonal /
  end;
  // like GDI: 8 x 8 pixels of the output, anchored at the output origin
  s := 1;
  def := '<pattern id="' + id + '" patternUnits="userSpaceOnUse" x="0" y="0" width="' + N(8 * s) +
         '" height="' + N(8 * s) + '">';
  runs := TStringList.Create;
  try
    if DC.BkMode = 2 then
      def := def + '<path d="M0 0 h' + N(8 * s) + ' v' + N(8 * s) + ' h' + N(-8 * s) + ' Z" fill="' +
             Color(DC.BkColor) + '" stroke="none"/>';
    fg := ((DC.Brush.Color and $FF) shl 16) or (DC.Brush.Color and $FF00) or ((DC.Brush.Color shr 16) and $FF);
    for y := 0 to 7 do
      for x := 0 to 7 do
        if bits[y, x] then AddRun(runs, fg, x * s, y * s, s, s);
    def := def + FlushRuns(runs);
  finally
    runs.Free;
  end;
  PutDef(def + '</pattern>');
  FPatterns.Add(key + '=' + id);
  Result := 'url(#' + id + ')';
end;

// Pattern brushes: the brush bitmap, one device pixel per bitmap pixel.
function TGdi.PatternUrl: string;
var
  key, id: string;
  sb: TStringBuilder;
  s: Double;
  x, y, i, run: Integer;
  c: Cardinal;
  Img: TRGBAImage;
  runs: TStringList;

  function Px(xx, yy: Integer): Cardinal;
  var cr: Cardinal;
  begin
    Result := Img.Px[yy * Img.W + xx] and $FFFFFF;
    if DC.Brush.Mono then
    begin
      // black (0) bits take the text colour, white (1) bits the background
      if Result = 0 then cr := DC.TextColor else cr := DC.BkColor;
      Result := ((cr and $FF) shl 16) or (cr and $FF00) or ((cr shr 16) and $FF);   // COLORREF -> RGB
    end;
  end;

begin
  Img := DC.Brush.Pat;
  key := 'p' + IntToHex(PtrUInt(Pointer(Img.Px)), 16);
  if DC.Brush.Mono then key := key + '_' + IntToHex(DC.TextColor, 6) + '_' + IntToHex(DC.BkColor, 6);
  i := FPatterns.IndexOfName(key);
  if i >= 0 then Exit('url(#' + FPatterns.ValueFromIndex[i] + ')');
  Inc(FDefSerial);
  id := 'pat' + IntToStr(FDefSerial);
  s := 1;                                    // one output pixel per brush pixel, like GDI
  sb := TStringBuilder.Create;
  try
    sb.Append('<pattern id="' + id + '" patternUnits="userSpaceOnUse" x="0" y="0" width="' +
              N(Img.W * s) + '" height="' + N(Img.H * s) + '">');
    runs := TStringList.Create;
    try
      for y := 0 to Img.H - 1 do
      begin
        x := 0;
        while x < Img.W do
        begin
          c := Px(x, y); run := 1;
          while (x + run < Img.W) and (Px(x + run, y) = c) do Inc(run);
          AddRun(runs, c, x * s, y * s, run * s, s);
          Inc(x, run);
        end;
      end;
      sb.Append(FlushRuns(runs));
    finally
      runs.Free;
    end;
    sb.Append('</pattern>');
    PutDef(sb.ToString);
  finally
    sb.Free;
  end;
  FPatterns.Add(key + '=' + id);
  Result := 'url(#' + id + ')';
end;

// EMF+ image tiles (texture and hatch brushes): the tile's pixel grid is
// mapped by Brush.PatXf (scale and offset; rotation is not reproduced).
// Pixels with alpha below one half are left out.
function TGdi.ImagePatUrl: string;
var
  key, id: string;
  sb: TStringBuilder;
  x, y, i, run: Integer;
  c: Cardinal;
  h: Cardinal;
  sx, sy, ox, oy: Double;
  Img: TRGBAImage;
  runs: TStringList;

  function Px(xx, yy: Integer): Cardinal;
  begin
    Result := Img.Px[yy * Img.W + xx];
    if (Result shr 24) < 128 then Result := 0 else Result := Result or $FF000000;
  end;

begin
  Img := DC.Brush.Pat;
  sx := Max(0.01, Abs(DC.Brush.PatXf.A)); sy := Max(0.01, Abs(DC.Brush.PatXf.D));
  ox := DC.Brush.PatXf.E; oy := DC.Brush.PatXf.F;
  if DC.Brush.PatXf.A < 0 then ox := ox - Img.W * sx;
  if DC.Brush.PatXf.D < 0 then oy := oy - Img.H * sy;
  h := 2166136261;
  for i := 0 to High(Img.Px) do h := (h xor Img.Px[i]) * 16777619;
  key := 'i' + IntToHex(h, 8) + '_' + IntToStr(Img.W) + 'x' + IntToStr(Img.H) + '_' + N(sx) + '_' + N(sy) +
         '_' + N(ox) + '_' + N(oy);
  i := FPatterns.IndexOfName(key);
  if i >= 0 then Exit('url(#' + FPatterns.ValueFromIndex[i] + ')');
  Inc(FDefSerial);
  id := 'pat' + IntToStr(FDefSerial);
  sb := TStringBuilder.Create;
  runs := TStringList.Create;
  try
    sb.Append('<pattern id="' + id + '" patternUnits="userSpaceOnUse" x="' + N(ox) + '" y="' + N(oy) +
              '" width="' + N(Img.W * sx) + '" height="' + N(Img.H * sy) + '">');
    for y := 0 to Img.H - 1 do
    begin
      x := 0;
      while x < Img.W do
      begin
        c := Px(x, y); run := 1;
        while (x + run < Img.W) and (Px(x + run, y) = c) do Inc(run);
        if c <> 0 then AddRun(runs, c, x * sx, y * sy, run * sx, sy);
        Inc(x, run);
      end;
    end;
    sb.Append(FlushRuns(runs));
    sb.Append('</pattern>');
    PutDef(sb.ToString);
  finally
    runs.Free;
    sb.Free;
  end;
  FPatterns.Add(key + '=' + id);
  Result := 'url(#' + id + ')';
end;

function TGdi.Full: TXf;
var
  sx, sy, m, u: Double;
  P: TXf;
begin
  // page -> device
  case DC.MapMode of
    2..6:
      begin
        case DC.MapMode of
          2: u := 0.1;           // MM_LOMETRIC  0.1 mm
          3: u := 0.01;          // MM_HIMETRIC  0.01 mm
          4: u := 0.254;         // MM_LOENGLISH 0.01 inch
          5: u := 0.0254;        // MM_HIENGLISH 0.001 inch
        else
          u := 25.4 / 1440;      // MM_TWIPS
        end;
        sx := u * DevPxPerMmX; sy := -u * DevPxPerMmY;   // y grows upwards
      end;
    7, 8:
      begin
        if DC.WinExtX = 0 then sx := 1 else sx := DC.VpExtX / DC.WinExtX;
        if DC.WinExtY = 0 then sy := 1 else sy := DC.VpExtY / DC.WinExtY;
        if DC.MapMode = 7 then          // isotropic: equal unit sizes
        begin
          m := Min(Abs(sx), Abs(sy));
          sx := Sign(sx) * m; sy := Sign(sy) * m;
          if sx = 0 then sx := m;
          if sy = 0 then sy := m;
        end;
      end;
  else
    begin sx := 1; sy := 1; end;       // MM_TEXT
  end;
  P.A := sx; P.B := 0; P.C := 0; P.D := sy;
  P.E := DC.VpOrgX - DC.WinOrgX * sx;
  P.F := DC.VpOrgY - DC.WinOrgY * sy;
  // device -> output
  P.A := P.A * OutScaleX; P.E := P.E * OutScaleX + OutOffX;
  P.D := P.D * OutScaleY; P.F := P.F * OutScaleY + OutOffY;
  Result := XfMul(P, DC.World);
end;

procedure TGdi.Map(x, y: Double; out ox, oy: Double);
const LIM = 1e6;          // far outside any picture; keeps corrupt files sane
var M: TXf;
begin
  M := Full;
  ox := EnsureRange(M.A * x + M.C * y + M.E, -LIM, LIM);
  oy := EnsureRange(M.B * x + M.D * y + M.F, -LIM, LIM);
  if FMeasure then Track(ox, oy);
end;

function TGdi.LinScaleX: Double;
var M: TXf;
begin
  M := Full;
  Result := Sqrt(M.A * M.A + M.B * M.B);
end;

function TGdi.LinScaleY: Double;
var M: TXf;
begin
  M := Full;
  Result := Sqrt(M.C * M.C + M.D * M.D);
end;

function TGdi.Flipped: Boolean;
var M: TXf;
begin
  M := Full;
  Result := M.A * M.D - M.B * M.C < 0;
end;

procedure TGdi.PathMove(sb: TStringBuilder; x, y: Double);
var ox, oy: Double;
begin
  Map(x, y, ox, oy);
  sb.Append('M').Append(N(ox)).Append(' ').Append(N(oy)).Append(' ');
end;

procedure TGdi.PathLine(sb: TStringBuilder; x, y: Double);
var ox, oy: Double;
begin
  Map(x, y, ox, oy);
  sb.Append('L').Append(N(ox)).Append(' ').Append(N(oy)).Append(' ');
end;

procedure TGdi.PathCubic(sb: TStringBuilder; x1, y1, x2, y2, x3, y3: Double);
var a, b, c, d, e, f: Double;
begin
  Map(x1, y1, a, b); Map(x2, y2, c, d); Map(x3, y3, e, f);
  sb.Append('C').Append(N(a)).Append(' ').Append(N(b)).Append(' ')
    .Append(N(c)).Append(' ').Append(N(d)).Append(' ')
    .Append(N(e)).Append(' ').Append(N(f)).Append(' ');
end;

// Elliptical arc as cubic curves, in logical space (so any affine mapping,
// including the EMF world transform, stays exact). t0 and sweep in radians.
procedure TGdi.EllipseArc(sb: TStringBuilder; cx, cy, rx, ry, t0, sweep: Double; MoveFirst: Boolean);
var
  n, i: Integer;
  dt, k, a0, a1: Double;
begin
  n := Max(1, Ceil(Abs(sweep) / (Pi / 2) - 1e-9));
  dt := sweep / n;
  k := 4 / 3 * Tan(dt / 4);
  if MoveFirst then PathMove(sb, cx + rx * Cos(t0), cy + ry * Sin(t0))
  else PathLine(sb, cx + rx * Cos(t0), cy + ry * Sin(t0));
  for i := 0 to n - 1 do
  begin
    a0 := t0 + dt * i; a1 := a0 + dt;
    PathCubic(sb,
      cx + rx * (Cos(a0) - k * Sin(a0)), cy + ry * (Sin(a0) + k * Cos(a0)),
      cx + rx * (Cos(a1) + k * Sin(a1)), cy + ry * (Sin(a1) - k * Cos(a1)),
      cx + rx * Cos(a1), cy + ry * Sin(a1));
  end;
end;

function TGdi.HasFill: Boolean;
begin
  Result := DC.Brush.Style <> 1;
end;

function TGdi.HasStroke: Boolean;
begin
  Result := (DC.Pen.Style and $FF) <> 5;
end;

function TGdi.FillAttr: string;
begin
  if (DC.Brush.Style = 2) and (DC.Brush.Hatch in [0..5]) then
    Result := ' fill="' + HatchUrl + '" fill-rule="'
  else if (DC.Brush.Style = 3) and (Length(DC.Brush.Pat.Px) > 0) and
          (Int64(DC.Brush.Pat.W) * DC.Brush.Pat.H <= 4096) then
    Result := ' fill="' + PatternUrl + '" fill-rule="'
  else if (DC.Brush.Style = 4) and (Length(DC.Brush.Pat.Px) > 0) then
    Result := ' fill="' + ImagePatUrl + '" fill-rule="'
  else
    Result := ' fill="' + Color(DC.Brush.Color) + '" fill-rule="';
  if DC.PolyFill = 2 then Result := Result + 'nonzero"' else Result := Result + 'evenodd"';
  if DC.Brush.Transp > 0 then
    Result := Result + ' fill-opacity="' + FloatToStrF((255 - DC.Brush.Transp) / 255, ffFixed, 6, 3, FFS) + '"';
end;

function TGdi.StrokeAttr: string;
var w: Double; cap, join: Integer;
begin
  if DC.Pen.Cosmetic or (DC.Pen.Width <= 0) then w := 1
  else w := EnsureRange(DC.Pen.Width * Sqrt(LinScaleX * LinScaleY), 1, 1e5);
  Result := ' stroke="' + Color(DC.Pen.Color) + '" stroke-width="' + N(w) + '"';
  if DC.Pen.Transp > 0 then
    Result := Result + ' stroke-opacity="' + FloatToStrF((255 - DC.Pen.Transp) / 255, ffFixed, 6, 3, FFS) + '"';
  // caps and joins: EMF+ pens say so; GDI geometric pens carry PS_ENDCAP_* /
  // PS_JOIN_* bits (round is the default of both)
  cap := DC.Pen.Cap; join := DC.Pen.Join;
  if (cap = 0) and not DC.Pen.Cosmetic then
    case DC.Pen.Style and $F00 of
      $100: cap := 3;
      $200: cap := 1;
    end;
  if (join = 0) and not DC.Pen.Cosmetic then
    case DC.Pen.Style and $F000 of
      $1000: join := 2;
      $2000: join := 1;
    end;
  case cap of
    1: Result := Result + ' stroke-linecap="butt"';
    3: Result := Result + ' stroke-linecap="square"';
  end;
  case join of
    1: Result := Result + ' stroke-linejoin="miter"';
    2: Result := Result + ' stroke-linejoin="bevel"';
  end;
  Result := Result + DashAttr(w);
end;

// GDI dash patterns: cosmetic pens use fixed device-pixel patterns, geometric
// pens multiples of the pen width; PS_USERSTYLE lists its own lengths.
function TGdi.DashAttr(w: Double): string;
const
  CosDash: array[1..4, 0..5] of Integer = ((18, 6, 0, 0, 0, 0), (3, 3, 0, 0, 0, 0),
                                           (9, 6, 3, 6, 0, 0), (9, 3, 3, 3, 3, 3));
  GeoDash: array[1..4, 0..5] of Integer = ((3, 1, 0, 0, 0, 0), (1, 1, 0, 0, 0, 0),
                                           (3, 1, 1, 1, 0, 0), (3, 1, 1, 1, 1, 1));
  DashLen: array[1..4] of Integer = (2, 2, 4, 6);
var
  st, i: Integer;
  u: Double;
  cosm: Boolean;
begin
  Result := '';
  st := DC.Pen.Style and $F;
  cosm := DC.Pen.Cosmetic or (DC.Pen.Width <= 0);
  case st of
    1..4:
      begin
        Result := ' stroke-dasharray="';
        for i := 0 to DashLen[st] - 1 do
        begin
          if i > 0 then Result := Result + ',';
          if cosm then Result := Result + N(CosDash[st, i])                  // output pixels
          else Result := Result + N(GeoDash[st, i] * w);
        end;
        Result := Result + '"';
      end;
    7:
      if Length(DC.Pen.Dash) > 0 then
      begin
        if cosm then u := 1 else u := Sqrt(LinScaleX * LinScaleY);
        Result := ' stroke-dasharray="';
        for i := 0 to High(DC.Pen.Dash) do
        begin
          if i > 0 then Result := Result + ',';
          Result := Result + N(Max(0.1, DC.Pen.Dash[i] * u));
        end;
        Result := Result + '"';
      end;
    8: Result := ' stroke-dasharray="1,1"';                                     // PS_ALTERNATE
  end;
end;

procedure TGdi.EmitShape(const D: string; DoFill, DoStroke: Boolean);
var S: string;
begin
  if FInPath then
  begin
    FPath.Append(D);
    Exit;
  end;
  DoFill := DoFill and HasFill;
  DoStroke := DoStroke and HasStroke;
  if not (DoFill or DoStroke) or FMeasure then Exit;
  S := '<path d="' + Trim(D) + '"';
  if DoFill then S := S + FillAttr else S := S + ' fill="none"';
  if DoStroke then S := S + StrokeAttr else S := S + ' stroke="none"';
  Put(S + '/>');
end;

procedure TGdi.SaveDC;
begin
  SetLength(Stack, Length(Stack) + 1);
  Stack[High(Stack)] := DC;
end;

procedure TGdi.RestoreDC(n: Integer);
var target: Integer;
begin
  if Length(Stack) = 0 then Exit;
  if n < 0 then target := Length(Stack) + n        // relative: -1 = last save
  else target := n - 1;                            // absolute (1-based)
  if (target < 0) or (target > High(Stack)) then target := High(Stack);
  DC := Stack[target];
  SetLength(Stack, target);
end;

function TGdi.NewObjectSlot: Integer;
var i: Integer;
begin
  for i := 0 to High(Objects) do
    if Objects[i].Kind = okNone then Exit(i);
  SetLength(Objects, Length(Objects) + 1);
  Result := High(Objects);
end;

procedure TGdi.SetObj(Index: Integer; const O: TGdiObj);
begin
  if (Index < 0) or (Index > 65535) then Exit;
  if Index > High(Objects) then SetLength(Objects, Index + 1);
  Objects[Index] := O;
end;

procedure TGdi.DeleteObj(Index: Integer);
begin
  if (Index >= 0) and (Index <= High(Objects)) then Objects[Index].Kind := okNone;
end;

procedure TGdi.SelectObj(Index: Integer);
begin
  if (Index < 0) or (Index > High(Objects)) then Exit;
  case Objects[Index].Kind of
    okPen: DC.Pen := Objects[Index].Pen;
    okBrush: DC.Brush := Objects[Index].Brush;
    okFont: DC.Font := Objects[Index].Font;
  end;
end;

procedure TGdi.SelectStock(Index: Integer);
const
  Grey: array[0..4] of Cardinal = ($FFFFFF, $C0C0C0, $808080, $404040, $000000);
begin
  case Index of
    0..4: begin DC.Brush.Style := 0; DC.Brush.Color := Grey[Index]; end;
    5:    DC.Brush.Style := 1;                                     // NULL_BRUSH
    6:    begin DC.Pen.Style := 0; DC.Pen.Color := $FFFFFF; DC.Pen.Cosmetic := True; end;
    7:    begin DC.Pen.Style := 0; DC.Pen.Color := 0; DC.Pen.Cosmetic := True; end;
    8:    DC.Pen.Style := 5;                                       // NULL_PEN
    10, 11, 16:
          begin DC.Font := Default(TFontRec); DC.Font.Face := 'Courier New'; DC.Font.Weight := 400; end;
    12, 13, 14, 17:
          begin DC.Font := Default(TFontRec); DC.Font.Face := 'Arial'; DC.Font.Weight := 400; end;
  end;
end;

procedure TGdi.MoveTo(x, y: Double);
var sb: TStringBuilder;
begin
  DC.CurX := x; DC.CurY := y;
  if FInPath then
  begin
    sb := TStringBuilder.Create;
    try
      PathMove(sb, x, y);
      FPath.Append(sb.ToString);
    finally sb.Free; end;
    FFigureOpen := True;
  end;
end;

procedure TGdi.LineTo(x, y: Double);
var sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    if FInPath then
    begin
      if not FFigureOpen then PathMove(sb, DC.CurX, DC.CurY);
      PathLine(sb, x, y);
      FPath.Append(sb.ToString);
      FFigureOpen := True;
    end
    else
    begin
      PathMove(sb, DC.CurX, DC.CurY);
      PathLine(sb, x, y);
      EmitShape(sb.ToString, False, True);
    end;
  finally sb.Free; end;
  DC.CurX := x; DC.CurY := y;
end;

// Pts = x0,y0,x1,y1,...  Draw=False: POLYLINETO style (continue from the
// current position and move it).
procedure TGdi.Poly(const Pts: array of Double; Count: Integer; Closed, Draw: Boolean);
var
  sb: TStringBuilder;
  i: Integer;
begin
  if Count <= 0 then Exit;
  sb := TStringBuilder.Create;
  try
    if Draw then
    begin
      PathMove(sb, Pts[0], Pts[1]);
      for i := 1 to Count - 1 do PathLine(sb, Pts[i * 2], Pts[i * 2 + 1]);
      if Closed then sb.Append('Z ');
      EmitShape(sb.ToString, Closed, True);
    end
    else
    begin
      if not (FInPath and FFigureOpen) then PathMove(sb, DC.CurX, DC.CurY);
      for i := 0 to Count - 1 do PathLine(sb, Pts[i * 2], Pts[i * 2 + 1]);
      if FInPath then begin FPath.Append(sb.ToString); FFigureOpen := True; end
      else EmitShape(sb.ToString, False, True);
      DC.CurX := Pts[(Count - 1) * 2]; DC.CurY := Pts[(Count - 1) * 2 + 1];
    end;
  finally sb.Free; end;
end;

procedure TGdi.PolyPoly(const Pts: array of Double; const Counts: array of Integer; Closed: Boolean);
var
  sb: TStringBuilder;
  i, j, k: Integer;
begin
  sb := TStringBuilder.Create;
  try
    k := 0;
    for i := 0 to High(Counts) do
    begin
      if Counts[i] <= 0 then Continue;
      if (k + Counts[i]) * 2 > Length(Pts) then Break;
      PathMove(sb, Pts[k * 2], Pts[k * 2 + 1]);
      for j := 1 to Counts[i] - 1 do PathLine(sb, Pts[(k + j) * 2], Pts[(k + j) * 2 + 1]);
      if Closed then sb.Append('Z ');
      Inc(k, Counts[i]);
    end;
    EmitShape(sb.ToString, Closed, True);
  finally sb.Free; end;
end;

// POLYBEZIER: first point then groups of three; POLYBEZIERTO: groups of three
// starting at the current position.
procedure TGdi.PolyBezier(const Pts: array of Double; Count: Integer; FromCurrent: Boolean);
var
  sb: TStringBuilder;
  i, s: Integer;
begin
  if Count <= 0 then Exit;
  sb := TStringBuilder.Create;
  try
    if FromCurrent then
    begin
      if not (FInPath and FFigureOpen) then PathMove(sb, DC.CurX, DC.CurY);
      s := 0;
    end
    else
    begin
      PathMove(sb, Pts[0], Pts[1]);
      s := 1;
    end;
    i := s;
    while i + 2 < Count + 0 do
    begin
      PathCubic(sb, Pts[i * 2], Pts[i * 2 + 1], Pts[i * 2 + 2], Pts[i * 2 + 3], Pts[i * 2 + 4], Pts[i * 2 + 5]);
      Inc(i, 3);
    end;
    if FInPath then begin FPath.Append(sb.ToString); FFigureOpen := True; end
    else EmitShape(sb.ToString, False, True);
    if FromCurrent and (Count >= 3) then
    begin
      DC.CurX := Pts[(i - 1) * 2]; DC.CurY := Pts[(i - 1) * 2 + 1];
    end;
  finally sb.Free; end;
end;

procedure TGdi.Rectangle(l, t, r, b: Double);
var sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    PathMove(sb, l, t); PathLine(sb, r, t); PathLine(sb, r, b); PathLine(sb, l, b);
    sb.Append('Z ');
    EmitShape(sb.ToString, True, True);
  finally sb.Free; end;
end;

procedure TGdi.RoundRect(l, t, r, b, ew, eh: Double);
var
  sb: TStringBuilder;
  rx, ry, x0, x1, y0, y1: Double;
begin
  x0 := Min(l, r); x1 := Max(l, r); y0 := Min(t, b); y1 := Max(t, b);
  rx := Min(Abs(ew) / 2, (x1 - x0) / 2); ry := Min(Abs(eh) / 2, (y1 - y0) / 2);
  if (rx <= 0) or (ry <= 0) then begin Rectangle(l, t, r, b); Exit; end;
  sb := TStringBuilder.Create;
  try
    EllipseArc(sb, x1 - rx, y0 + ry, rx, ry, -Pi / 2, Pi / 2, True);
    EllipseArc(sb, x1 - rx, y1 - ry, rx, ry, 0, Pi / 2, False);
    EllipseArc(sb, x0 + rx, y1 - ry, rx, ry, Pi / 2, Pi / 2, False);
    EllipseArc(sb, x0 + rx, y0 + ry, rx, ry, Pi, Pi / 2, False);
    sb.Append('Z ');
    EmitShape(sb.ToString, True, True);
  finally sb.Free; end;
end;

procedure TGdi.Ellipse(l, t, r, b: Double);
var sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    EllipseArc(sb, (l + r) / 2, (t + b) / 2, Abs(r - l) / 2, Abs(b - t) / 2, 0, 2 * Pi, True);
    sb.Append('Z ');
    EmitShape(sb.ToString, True, True);
  finally sb.Free; end;
end;

// ARC / CHORD / PIE / ARCTO: the arc runs from the radial through the start
// point to the radial through the end point, counter-clockwise on screen
// unless SetArcDirection chose clockwise.
procedure TGdi.ArcShape(l, t, r, b, xs, ys, xe, ye: Double; Kind: Integer);
var
  sb: TStringBuilder;
  cx, cy, rx, ry, t0, t1, sweep, dir: Double;
begin
  cx := (l + r) / 2; cy := (t + b) / 2;
  rx := Abs(r - l) / 2; ry := Abs(b - t) / 2;
  if (rx <= 0) or (ry <= 0) then Exit;
  t0 := ArcTan2((ys - cy) * rx, (xs - cx) * ry);
  t1 := ArcTan2((ye - cy) * rx, (xe - cx) * ry);
  // counter-clockwise on screen = decreasing angle in y-down space
  if (DC.ArcDir = 2) xor Flipped then dir := 1 else dir := -1;
  sweep := (t1 - t0) * dir;
  while sweep <= 1e-9 do sweep := sweep + 2 * Pi;
  sweep := sweep * dir;
  sb := TStringBuilder.Create;
  try
    case Kind of
      2: begin                                   // pie: centre, arc, back
           PathMove(sb, cx, cy);
           EllipseArc(sb, cx, cy, rx, ry, t0, sweep, False);
           sb.Append('Z ');
           EmitShape(sb.ToString, True, True);
         end;
      1: begin                                   // chord
           EllipseArc(sb, cx, cy, rx, ry, t0, sweep, True);
           sb.Append('Z ');
           EmitShape(sb.ToString, True, True);
         end;
      3: begin                                   // arcto: line from current
           if not (FInPath and FFigureOpen) then PathMove(sb, DC.CurX, DC.CurY);
           EllipseArc(sb, cx, cy, rx, ry, t0, sweep, False);
           if FInPath then begin FPath.Append(sb.ToString); FFigureOpen := True; end
           else EmitShape(sb.ToString, False, True);
           DC.CurX := cx + rx * Cos(t0 + sweep); DC.CurY := cy + ry * Sin(t0 + sweep);
         end;
    else
      begin
        EllipseArc(sb, cx, cy, rx, ry, t0, sweep, True);
        EmitShape(sb.ToString, False, True);
      end;
    end;
  finally sb.Free; end;
end;

procedure TGdi.AngleArc(cx, cy, r, StartDeg, SweepDeg: Double);
var sb: TStringBuilder; t0, sw: Double;
begin
  // angles are counter-clockwise from the x axis in y-up sense; a sweep over
  // two turns only repeats itself
  SweepDeg := EnsureRange(SweepDeg, -720, 720);
  StartDeg := StartDeg - 360 * Trunc(EnsureRange(StartDeg, -1e9, 1e9) / 360);
  t0 := -DegToRad(StartDeg); sw := -DegToRad(SweepDeg);
  if Flipped then begin t0 := -t0; sw := -sw; end;
  sb := TStringBuilder.Create;
  try
    if not (FInPath and FFigureOpen) then PathMove(sb, DC.CurX, DC.CurY);
    EllipseArc(sb, cx, cy, r, r, t0, sw, False);
    if FInPath then begin FPath.Append(sb.ToString); FFigureOpen := True; end
    else EmitShape(sb.ToString, False, True);
    DC.CurX := cx + r * Cos(t0 + sw); DC.CurY := cy + r * Sin(t0 + sw);
  finally sb.Free; end;
end;

procedure TGdi.FillRectColor(l, t, r, b: Double; c: Cardinal);
var sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    PathMove(sb, l, t); PathLine(sb, r, t); PathLine(sb, r, b); PathLine(sb, l, b);
    sb.Append('Z');
    if not FMeasure then Put('<path d="' + sb.ToString + '" fill="' + Color(c) + '" stroke="none"/>');
  finally sb.Free; end;
end;

procedure TGdi.FillRectBrush(l, t, r, b: Double);
var sb: TStringBuilder;
begin
  if not HasFill then Exit;
  sb := TStringBuilder.Create;
  try
    PathMove(sb, l, t); PathLine(sb, r, t); PathLine(sb, r, b); PathLine(sb, l, b);
    sb.Append('Z');
    if not FMeasure then Put('<path d="' + sb.ToString + '"' + FillAttr + ' stroke="none"/>');
  finally sb.Free; end;
end;

procedure TGdi.SetPixel(x, y: Double; c: Cardinal);
var ox, oy: Double;
begin
  Map(x, y, ox, oy);
  Put('<rect x="' + N(ox) + '" y="' + N(oy) + '" width="1" height="1" fill="' + Color(c) + '"/>');
end;

procedure TGdi.BeginPath;
begin
  FInPath := True;
  FPath.Clear;
  FFigureOpen := False;
end;

procedure TGdi.EndPath;
begin
  FInPath := False;
end;

procedure TGdi.CloseFigure;
begin
  if FInPath then
  begin
    FPath.Append('Z ');
    FFigureOpen := False;
  end;
end;

procedure TGdi.DrawPath(DoFill, DoStroke: Boolean);
var D: string;
begin
  FInPath := False;
  D := FPath.ToString;
  FPath.Clear;
  if D <> '' then EmitShape(D, DoFill, DoStroke);
end;

procedure TGdi.AbortPath;
begin
  FInPath := False;
  FPath.Clear;
end;

procedure TGdi.Text(x, y: Double; const S: string; const Dx: array of Double; HasDx: Boolean);
var
  ox, oy, esc, vx, vy, dirx, diry, ang, size, sx, sy, total, pos: Double;
  M: TXf;
  st, xs: string;
  i, h, v: Integer;
begin
  if (DC.TextAlign and 1) <> 0 then begin x := DC.CurX; y := DC.CurY; end;   // TA_UPDATECP
  Map(x, y, ox, oy);
  if FMeasure or (S = '') then Exit;
  M := Full;
  // baseline direction: escapement is counter-clockwise on screen
  esc := DegToRad(DC.Font.Escapement / 10);
  vx := Cos(esc);
  if Flipped then vy := Sin(esc) else vy := -Sin(esc);
  dirx := M.A * vx + M.C * vy; diry := M.B * vx + M.D * vy;
  ang := RadToDeg(ArcTan2(diry, dirx));
  sx := LinScaleX; sy := LinScaleY;
  h := DC.Font.Height;
  if DC.Font.EmHeight > 0 then size := DC.Font.EmHeight * sy
  else if h < 0 then size := -h * sy
  else if h > 0 then size := h * 0.83 * sy      // cell height -> em height
  else size := 16;
  size := EnsureRange(size, 0.5, 1e5);

  st := '<text x="';
  if HasDx and (Length(Dx) > 0) then
  begin
    total := 0;
    for i := 0 to High(Dx) do total := total + Dx[i];
    case DC.TextAlign and 6 of
      2: pos := EnsureRange(ox - total * sx, -1e6, 1e6);       // TA_RIGHT
      6: pos := EnsureRange(ox - total * sx / 2, -1e6, 1e6);   // TA_CENTER
    else pos := ox;
    end;
    xs := '';
    for i := 0 to High(Dx) do
    begin
      if i > 0 then xs := xs + ' ';
      xs := xs + N(EnsureRange(pos, -1e6, 1e6));
      pos := EnsureRange(pos + Dx[i] * sx, -1e6, 1e6);
    end;
    st := st + xs + '"';
  end
  else
  begin
    st := st + N(ox) + '"';
    case DC.TextAlign and 6 of
      2: st := st + ' text-anchor="end"';
      6: st := st + ' text-anchor="middle"';
    end;
  end;
  st := st + ' y="' + N(oy) + '" font-family="' + XmlEscape(DC.Font.Face) + '" font-size="' + N(size) + '"';
  if DC.Font.Weight >= 600 then st := st + ' font-weight="bold"';
  if DC.Font.Italic then st := st + ' font-style="italic"';
  if DC.Font.Underline and DC.Font.StrikeOut then st := st + ' text-decoration="underline line-through"'
  else if DC.Font.Underline then st := st + ' text-decoration="underline"'
  else if DC.Font.StrikeOut then st := st + ' text-decoration="line-through"';
  v := DC.TextAlign and 24;
  if v = 0 then st := st + ' dominant-baseline="text-before-edge"'        // TA_TOP
  else if v = 8 then st := st + ' dominant-baseline="text-after-edge"';   // TA_BOTTOM
  st := st + ' fill="' + Color(DC.TextColor) + '"';
  if DC.TextTransp > 0 then
    st := st + ' fill-opacity="' + FloatToStrF((255 - DC.TextTransp) / 255, ffFixed, 6, 3, FFS) + '"';
  if Abs(ang) > 0.01 then
    st := st + ' transform="rotate(' + N(ang) + ' ' + N(ox) + ' ' + N(oy) + ')"';
  Put(st + ' xml:space="preserve">' + XmlEscape(S) + '</text>');
end;

// Bitmaps become runs of equal-coloured rects (SimpleSVG has no <image>).
// Source pixels are sampled on a grid no finer than the output needs.
procedure TGdi.Bitmap(const Img: TRGBAImage; dl, dt, dw, dh: Double; sx, sy, sw, sh: Integer; Rop: Cardinal);
var
  x0, y0, x1, y1, ox, oy, cw, ch: Double;
  cols, rows, i, j, run, px, py: Integer;
  c, prev: Cardinal;
  f: Double;
  runs: TStringList;

  function Sample(ci, ri: Integer): Cardinal;
  begin
    px := sx + Trunc((ci + 0.5) * sw / cols);
    py := sy + Trunc((ri + 0.5) * sh / rows);
    if (px < 0) or (py < 0) or (px >= Img.W) or (py >= Img.H) then Exit($00000000);
    Result := Img.Px[py * Img.W + px];
    // mask tricks of old metafiles: SRCAND keeps only dark pixels,
    // SRCPAINT / SRCINVERT add only non-black ones
    case Rop of
      $008800C6: if (Result and $FFFFFF) = $FFFFFF then Result := 0;
      $00EE0086, $00660046: if (Result and $FFFFFF) = 0 then Result := 0;
    end;
  end;

begin
  if (sw <= 0) or (sh <= 0) or (Img.W <= 0) then Exit;
  Map(dl, dt, x0, y0); Map(dl + dw, dt + dh, x1, y1);
  if FMeasure then Exit;
  if x1 < x0 then begin ox := x0; x0 := x1; x1 := ox; end;
  if y1 < y0 then begin oy := y0; y0 := y1; y1 := oy; end;
  cols := Max(1, Min(sw, Ceil(x1 - x0)));
  rows := Max(1, Min(sh, Ceil(y1 - y0)));
  if Int64(cols) * rows > MAX_BITMAP_CELLS then
  begin
    f := Sqrt(MAX_BITMAP_CELLS / (Int64(cols) * rows));
    cols := Max(1, Trunc(cols * f)); rows := Max(1, Trunc(rows * f));
  end;
  cw := (x1 - x0) / cols; ch := (y1 - y0) / rows;
  runs := TStringList.Create;
  try
  for j := 0 to rows - 1 do
  begin
    i := 0;
    while i < cols do
    begin
      c := Sample(i, j);
      run := 1;
      while (i + run < cols) do
      begin
        prev := Sample(i + run, j);
        if prev <> c then Break;
        Inc(run);
      end;
      if (c shr 24) >= 128 then AddRun(runs, c, x0 + i * cw, y0 + j * ch, run * cw, ch);
      Inc(i, run);
    end;
  end;
  Put(FlushRuns(runs));
  finally
    runs.Free;
  end;
end;

procedure TGdi.GradientRect(x0, y0, x1, y1: Double; c0, c1: Cardinal; Vertical: Boolean);
const
  STEPS = 48;
var
  i: Integer;
  t, a, b: Double;
  c: Cardinal;
  function Mix(s0, s1: Cardinal; sh: Integer): Cardinal;
  begin
    Result := Round(((s0 shr sh) and $FF) * (1 - t) + ((s1 shr sh) and $FF) * t);
  end;
begin
  for i := 0 to STEPS - 1 do
  begin
    t := (i + 0.5) / STEPS;
    c := Mix(c0, c1, 0) or (Mix(c0, c1, 8) shl 8) or (Mix(c0, c1, 16) shl 16);
    a := i / STEPS; b := (i + 1) / STEPS;
    if Vertical then
      FillRectColor(x0, y0 + (y1 - y0) * a, x1, y0 + (y1 - y0) * b + (y1 - y0) / STEPS * 0.5, c)
    else
      FillRectColor(x0 + (x1 - x0) * a, y0, x0 + (x1 - x0) * b + (x1 - x0) / STEPS * 0.5, y1, c);
  end;
end;

procedure TGdi.SelectAny(Index: Integer);
begin
  if (Cardinal(Index) and $80000000) <> 0 then SelectStock(Integer(Cardinal(Index) and $7FFFFFFF))
  else SelectObj(Index);
end;

function TGdi.BuildSvg(W, H: Integer): string;
  function CloseGroups: string;
  var i: Integer;
  begin
    Result := '';
    for i := 1 to FGroupDepth do Result := Result + '</g>' + #10;
  end;
begin
  Result := '<?xml version="1.0" encoding="UTF-8"?>' + #10 +
    '<svg xmlns="http://www.w3.org/2000/svg" width="' + IntToStr(W) + '" height="' +
    IntToStr(H) + '" viewBox="0 0 ' + IntToStr(W) + ' ' + IntToStr(H) + '">' + #10 +
    FOut.ToString + CloseGroups + '</svg>' + #10;
end;

// ------------------------------ DIB decoding ------------------------------

// Decodes a packed or split DIB (BITMAPINFO at BmiOfs, pixel bits at BitsOfs).
// Pal16 = DIB_PAL_COLORS (palette entries are indices; shown as greys).
function DecodeDib(const D: TBytes; BmiOfs, BmiLen, BitsOfs, BitsLen: NativeInt;
  Usage: Integer; out Img: TRGBAImage): Boolean;
var
  hs, w, h, bpp, comp, nPal, i, x, y, stride, row, v, k, idx: Integer;
  topDown, core: Boolean;
  pal: array[0..255] of Cardinal;
  masks: array[0..2] of Cardinal;
  shifts, bits: array[0..2] of Integer;
  p: NativeInt;
  sub: TBytes;
  ww, hh: Integer;
  rgba: TBytes;

  function MaskInfo(m: Cardinal; out s, b: Integer): Boolean;
  begin
    s := 0; b := 0;
    if m = 0 then Exit(False);
    while (m and 1) = 0 do begin m := m shr 1; Inc(s); end;
    while (m and 1) = 1 do begin m := m shr 1; Inc(b); end;
    Result := True;
  end;

  function Scale(val, b: Integer): Integer;
  begin
    if b <= 0 then Exit(0);
    if b >= 8 then Result := val shr (b - 8)
    else Result := (val * 255) div ((1 shl b) - 1);
  end;

  procedure PutPx(xx, yy: Integer; c: Cardinal);
  var ty: Integer;
  begin
    if (xx < 0) or (xx >= w) or (yy < 0) or (yy >= h) then Exit;
    if topDown then ty := yy else ty := h - 1 - yy;
    Img.Px[ty * w + xx] := c;
  end;

begin
  Result := False;
  Img := Default(TRGBAImage);
  if (BmiOfs < 0) or (BmiOfs + 12 > Length(D)) then Exit;
  hs := RdI32(D, BmiOfs);
  core := hs = 12;
  if core then
  begin
    w := RdU16(D, BmiOfs + 4); h := RdU16(D, BmiOfs + 6);
    bpp := RdU16(D, BmiOfs + 10); comp := 0; nPal := 0;
  end
  else
  begin
    if hs < 40 then Exit;
    w := RdI32(D, BmiOfs + 4); h := RdI32(D, BmiOfs + 8);
    bpp := RdU16(D, BmiOfs + 14); comp := RdI32(D, BmiOfs + 16);
    nPal := RdI32(D, BmiOfs + 32);
  end;
  topDown := h < 0; h := Abs(h);
  if (w <= 0) or (h <= 0) or (Int64(w) * h > 64 * 1024 * 1024) then Exit;

  // compressed payloads that are whole images
  if (comp = 4) or (comp = 5) then
  begin
    if (BitsOfs < 0) or (BitsOfs + BitsLen > Length(D)) or (BitsLen <= 0) then Exit;
    SetLength(sub, BitsLen);
    Move(D[BitsOfs], sub[0], BitsLen);
    try
      if comp = 4 then rgba := DecodeJpeg(sub, ww, hh) else rgba := DecodePng(sub, ww, hh);
    except
      Exit;
    end;
    Img.W := ww; Img.H := hh;
    SetLength(Img.Px, ww * hh);
    for i := 0 to ww * hh - 1 do
      Img.Px[i] := (Cardinal(rgba[i * 4 + 3]) shl 24) or (Cardinal(rgba[i * 4]) shl 16) or
                   (Cardinal(rgba[i * 4 + 1]) shl 8) or rgba[i * 4 + 2];
    Exit(True);
  end;

  Img.W := w; Img.H := h;
  SetLength(Img.Px, w * h);
  for i := 0 to w * h - 1 do Img.Px[i] := $FFFFFFFF;

  // palette / bit fields
  if bpp <= 8 then
  begin
    if nPal <= 0 then nPal := 1 shl bpp;
    nPal := Min(nPal, 256);
    for i := 0 to nPal - 1 do
    begin
      if Usage = 2 then
      begin
        // DIB_PAL_INDICES: no colour table; show indices as a grey ramp
        // (for 1 bpp: 0 = black, 1 = white)
        v := i * 255 div Max(1, nPal - 1);
        pal[i] := $FF000000 or Cardinal(v * $010101);
      end
      else if Usage = 1 then
      begin
        v := RdU16(D, BmiOfs + hs + i * 2) and $FF;
        pal[i] := $FF000000 or Cardinal(v * $010101);
      end
      else if core then
      begin
        p := BmiOfs + hs + i * 3;
        pal[i] := $FF000000 or (Cardinal(RdU8(D, p + 2)) shl 16) or (Cardinal(RdU8(D, p + 1)) shl 8) or RdU8(D, p);
      end
      else
      begin
        p := BmiOfs + hs + i * 4;
        pal[i] := $FF000000 or (Cardinal(RdU8(D, p + 2)) shl 16) or (Cardinal(RdU8(D, p + 1)) shl 8) or RdU8(D, p);
      end;
    end;
    for i := nPal to 255 do pal[i] := $FF000000;
  end;
  if (comp = 3) or (comp = 6) then
  begin
    if hs >= 52 then p := BmiOfs + 40 else p := BmiOfs + hs;
    masks[0] := RdU32(D, p); masks[1] := RdU32(D, p + 4); masks[2] := RdU32(D, p + 8);
  end
  else if bpp = 16 then
  begin
    masks[0] := $7C00; masks[1] := $03E0; masks[2] := $001F;
  end
  else
  begin
    masks[0] := $FF0000; masks[1] := $FF00; masks[2] := $FF;
  end;
  for i := 0 to 2 do MaskInfo(masks[i], shifts[i], bits[i]);

  if (BitsOfs < 0) or (BitsOfs >= Length(D)) then Exit;

  // RLE8 / RLE4
  if (comp = 1) or (comp = 2) then
  begin
    p := BitsOfs; x := 0; y := 0;
    while (p + 1 < Length(D)) and (p < BitsOfs + BitsLen) and (y < h) do
    begin
      v := D[p]; k := D[p + 1]; Inc(p, 2);
      if v > 0 then
      begin
        for i := 0 to v - 1 do
        begin
          if comp = 1 then idx := k
          else if (i and 1) = 0 then idx := k shr 4 else idx := k and $F;
          PutPx(x, y, pal[idx]); Inc(x);
        end;
      end
      else if k = 0 then begin x := 0; Inc(y); end
      else if k = 1 then Break
      else if k = 2 then
      begin
        if p + 1 >= Length(D) then Break;
        Inc(x, D[p]); Inc(y, D[p + 1]); Inc(p, 2);
      end
      else
      begin
        for i := 0 to k - 1 do
        begin
          if comp = 1 then idx := RdU8(D, p + i)
          else if (i and 1) = 0 then idx := RdU8(D, p + i div 2) shr 4
          else idx := RdU8(D, p + i div 2) and $F;
          PutPx(x, y, pal[idx]); Inc(x);
        end;
        if comp = 1 then Inc(p, (k + 1) and not 1)
        else Inc(p, ((k + 1) div 2 + 1) and not 1);
      end;
    end;
    Exit(True);
  end;

  if not (bpp in [1, 4, 8, 16, 24, 32]) then Exit;
  stride := ((w * bpp + 31) div 32) * 4;
  for y := 0 to h - 1 do
  begin
    row := BitsOfs + NativeInt(y) * stride;
    if row + stride > Length(D) then Break;
    for x := 0 to w - 1 do
    begin
      case bpp of
        1: PutPx(x, y, pal[(D[row + x shr 3] shr (7 - x and 7)) and 1]);
        4: begin
             v := D[row + x shr 1];
             if (x and 1) = 0 then v := v shr 4 else v := v and $F;
             PutPx(x, y, pal[v]);
           end;
        8: PutPx(x, y, pal[D[row + x]]);
        16, 32:
          begin
            if bpp = 16 then v := RdU16(D, row + x * 2) else v := Integer(RdU32(D, row + x * 4));
            PutPx(x, y, $FF000000 or
              (Cardinal(Scale((Cardinal(v) and masks[0]) shr shifts[0], bits[0])) shl 16) or
              (Cardinal(Scale((Cardinal(v) and masks[1]) shr shifts[1], bits[1])) shl 8) or
              Cardinal(Scale((Cardinal(v) and masks[2]) shr shifts[2], bits[2])));
          end;
        24: PutPx(x, y, $FF000000 or (Cardinal(D[row + x * 3 + 2]) shl 16) or
                        (Cardinal(D[row + x * 3 + 1]) shl 8) or D[row + x * 3]);
      end;
    end;
  end;
  Result := True;
end;

// Straight-alpha copy of a 32-bit DIB with per-pixel alpha (ALPHABLEND).
procedure ApplyDibAlpha(const D: TBytes; BitsOfs: NativeInt; var Img: TRGBAImage; TopDown: Boolean);
var x, y, ty: Integer; p: NativeInt; a: Cardinal; c: Cardinal;
begin
  for y := 0 to Img.H - 1 do
    for x := 0 to Img.W - 1 do
    begin
      p := BitsOfs + (NativeInt(y) * Img.W + x) * 4;
      if p + 3 >= Length(D) then Exit;
      a := D[p + 3];
      if TopDown then ty := y else ty := Img.H - 1 - y;
      c := Img.Px[ty * Img.W + x] and $FFFFFF;
      if a > 0 then       // premultiplied -> straight
        c := (Min(255, ((c shr 16) and $FF) * 255 div a) shl 16) or
             (Min(255, ((c shr 8) and $FF) * 255 div a) shl 8) or
             Min(255, (c and $FF) * 255 div a);
      Img.Px[ty * Img.W + x] := (a shl 24) or c;
    end;
end;

function AverageColor(const Img: TRGBAImage): Cardinal;
var i: Integer; r, g, b, n: Int64;
begin
  r := 0; g := 0; b := 0; n := Length(Img.Px);
  if n = 0 then Exit($808080);
  for i := 0 to n - 1 do
  begin
    r := r + (Img.Px[i] shr 16) and $FF;
    g := g + (Img.Px[i] shr 8) and $FF;
    b := b + Img.Px[i] and $FF;
  end;
  Result := Cardinal(r div n) or (Cardinal(g div n) shl 8) or (Cardinal(b div n) shl 16);   // COLORREF
end;

function Utf8CharCountOk(const S: string; Count: Integer): Boolean;
var i, n: Integer;
begin
  n := 0;
  for i := 1 to Length(S) do
    if (Ord(S[i]) and $C0) <> $80 then Inc(n);
  Result := n = Count;
end;

// --------------------------------- WMF ------------------------------------

type
  TWmfInfo = record
    Placeable: Boolean;
    L, T, R, B, Inch: Integer;
    Start: NativeInt;       // first record
  end;

function WmfHeader(const D: TBytes; out Info: TWmfInfo): Boolean;
var p: NativeInt; typ, hs: Integer;
begin
  Info := Default(TWmfInfo);
  Result := False;
  p := 0;
  if (Length(D) >= 22) and (RdU32(D, 0) = $9AC6CDD7) then
  begin
    Info.Placeable := True;
    Info.L := RdI16(D, 6); Info.T := RdI16(D, 8); Info.R := RdI16(D, 10); Info.B := RdI16(D, 12);
    Info.Inch := RdU16(D, 14);
    p := 22;
  end;
  if Length(D) < p + 18 then Exit;
  typ := RdU16(D, p); hs := RdU16(D, p + 2);
  if not (typ in [1, 2]) or (hs <> 9) then Exit;
  Info.Start := p + 18;
  Result := True;
end;

procedure PlayWmf(G: TGdi; const D: TBytes; const Info: TWmfInfo);
var
  p, q, e: NativeInt;
  size: Cardinal;
  fn, i, n, np, cnt, opts, slot, k: Integer;
  pts: array of Double;
  counts: array of Integer;
  dxs: array of Double;
  O: TGdiObj;
  s: string;
  bytes: array of Byte;
  img: TRGBAImage;
  rop: Cardinal;
  hasBmp: Boolean;
  crects: TClipRects;
  x0, y0, x1, y1: Double;

  function W(i: Integer): Integer;            // i-th parameter word (signed)
  begin
    Result := RdI16(D, p + 6 + i * 2);
  end;
  function WU(i: Integer): Integer;
  begin
    Result := RdU16(D, p + 6 + i * 2);
  end;
  function Clr(i: Integer): Cardinal;
  begin
    Result := Cardinal(WU(i)) or (Cardinal(WU(i + 1) and $FF) shl 16);
  end;

begin
  p := Info.Start;
  e := Length(D);
  while p + 6 <= e do
  begin
    size := RdU32(D, p);
    fn := RdU16(D, p + 4);
    if (size < 3) or (p + NativeInt(size) * 2 > e) then Break;
    case fn of
      $0000: Break;                                              // EOF
      $0103: if not Info.Placeable or (W(0) in [7, 8]) then G.DC.MapMode := W(0);
      $020B: begin G.DC.WinOrgY := W(0); G.DC.WinOrgX := W(1); end;
      $020C: begin G.DC.WinExtY := W(0); G.DC.WinExtX := W(1); end;
      $020D: begin G.DC.VpOrgY := W(0); G.DC.VpOrgX := W(1); end;
      $020E: begin G.DC.VpExtY := W(0); G.DC.VpExtX := W(1); end;
      $020F: begin G.DC.WinOrgY := G.DC.WinOrgY + W(0); G.DC.WinOrgX := G.DC.WinOrgX + W(1); end;
      $0211: begin G.DC.VpOrgY := G.DC.VpOrgY + W(0); G.DC.VpOrgX := G.DC.VpOrgX + W(1); end;
      $0400: if (W(0) <> 0) and (W(2) <> 0) then
             begin
               G.DC.WinExtY := G.DC.WinExtY * W(1) / W(0);
               G.DC.WinExtX := G.DC.WinExtX * W(3) / W(2);
             end;
      $0412: if (W(0) <> 0) and (W(2) <> 0) then
             begin
               G.DC.VpExtY := G.DC.VpExtY * W(1) / W(0);
               G.DC.VpExtX := G.DC.VpExtX * W(3) / W(2);
             end;
      $001E: G.SaveDC;
      $0127: G.RestoreDC(W(0));
      $0102: G.DC.BkMode := W(0);
      $0106: G.DC.PolyFill := W(0);
      $012E: G.DC.TextAlign := WU(0);
      $0201: G.DC.BkColor := Clr(0);
      $0209: G.DC.TextColor := Clr(0);
      $02FA: begin                                               // CREATEPENINDIRECT
               O := Default(TGdiObj); O.Kind := okPen;
               O.Pen.Style := WU(0); O.Pen.Width := W(1); O.Pen.Color := Clr(3);
               O.Pen.Cosmetic := O.Pen.Width <= 1;               // 0/1 = one device pixel
               // CreatePen: dash styles only exist for 1-pixel pens
               if (O.Pen.Width > 1) and ((O.Pen.Style and $F) in [1..4]) then
                 O.Pen.Style := O.Pen.Style and not $F;
               G.SetObj(G.NewObjectSlot, O);
             end;
      $02FC: begin                                               // CREATEBRUSHINDIRECT
               O := Default(TGdiObj); O.Kind := okBrush;
               O.Brush.Style := WU(0); O.Brush.Color := Clr(1); O.Brush.Hatch := WU(3);
               if O.Brush.Style > 3 then O.Brush.Style := 3;
               G.SetObj(G.NewObjectSlot, O);
             end;
      $02FB: begin                                               // CREATEFONTINDIRECT
               O := Default(TGdiObj); O.Kind := okFont;
               O.Font.Height := W(0); O.Font.Escapement := W(2); O.Font.Weight := W(4);
               q := p + 6 + 10;
               O.Font.Italic := RdU8(D, q) <> 0; O.Font.Underline := RdU8(D, q + 1) <> 0;
               O.Font.StrikeOut := RdU8(D, q + 2) <> 0; O.Font.Charset := RdU8(D, q + 3);
               q := q + 8; s := '';
               while (q < p + NativeInt(size) * 2) and (RdU8(D, q) <> 0) and (Length(s) < 32) do
               begin
                 s := s + Chr(RdU8(D, q)); Inc(q);
               end;
               if s = '' then s := 'Arial';
               O.Font.Face := s;
               G.SetObj(G.NewObjectSlot, O);
             end;
      $0142: begin                                               // DIBCREATEPATTERNBRUSH
               O := Default(TGdiObj); O.Kind := okBrush; O.Brush.Style := 0; O.Brush.Color := $808080;
               cnt := WU(0);                                     // BS_PATTERN = mono bitmap
               k := RdI32(D, p + 10);
               if (k = 40) or (k = 12) then
               begin
                 // bits follow header + palette
                 n := RdU16(D, p + 10 + 14);
                 if n <= 8 then
                 begin
                   np := RdI32(D, p + 10 + 32); if np <= 0 then np := 1 shl n;
                   if WU(1) = 1 then np := np * 2 else np := np * 4;
                 end
                 else np := 0;
                 if DecodeDib(D, p + 10, 0, p + 10 + k + np, p + NativeInt(size) * 2 - (p + 10 + k + np),
                                WU(1), img) then
                 begin
                   O.Brush.Color := AverageColor(img);
                   O.Brush.Style := 3; O.Brush.Pat := img;
                   O.Brush.Mono := (cnt = 3) and (n = 1);
                 end;
               end;
               G.SetObj(G.NewObjectSlot, O);
             end;
      $06FF: begin                                               // CREATEREGION
               O := Default(TGdiObj); O.Kind := okRegion;
               // header: next, type, count(4), size, scan count, max scan,
               // bounding box; then scans of (count, top, bottom, x pairs, count)
               q := p + 6 + 22;
               np := WU(5);
               for i := 0 to np - 1 do
               begin
                 if q + 6 > p + NativeInt(size) * 2 then Break;
                 cnt := RdU16(D, q);
                 for k := 0 to cnt div 2 - 1 do
                 begin
                   SetLength(O.Region, Length(O.Region) + 4);
                   O.Region[High(O.Region) - 3] := RdI16(D, q + 6 + k * 4);
                   O.Region[High(O.Region) - 2] := RdI16(D, q + 2);
                   O.Region[High(O.Region) - 1] := RdI16(D, q + 8 + k * 4);
                   O.Region[High(O.Region)] := RdI16(D, q + 4);
                 end;
                 q := q + 8 + cnt * 2;
               end;
               G.SetObj(G.NewObjectSlot, O);
             end;
      $0416: G.ClipRectLogical(W(3), W(2), W(1), W(0), False);  // INTERSECTCLIPRECT
      $0415: G.ClipRectLogical(W(3), W(2), W(1), W(0), True);   // EXCLUDECLIPRECT
      $0220: G.ClipOffset(W(1), W(0));                          // OFFSETCLIPRGN
      $012C: begin                                               // SELECTCLIPREGION
               k := WU(0);
               if (k <= High(G.Objects)) and (G.Objects[k].Kind = okRegion) then
               begin
                 SetLength(crects, Length(G.Objects[k].Region) div 4);
                 for i := 0 to High(crects) do
                 begin
                   G.Map(G.Objects[k].Region[i * 4], G.Objects[k].Region[i * 4 + 1], x0, y0);
                   G.Map(G.Objects[k].Region[i * 4 + 2], G.Objects[k].Region[i * 4 + 3], x1, y1);
                   crects[i].L := Min(x0, x1); crects[i].R := Max(x0, x1);
                   crects[i].T := Min(y0, y1); crects[i].B := Max(y0, y1);
                 end;
                 G.ClipRectsOutput(crects, RGN_COPY);
               end
               else
                 G.ClipResetAll;
             end;
      $01F9, $00F7:                                              // other objects: take a slot
             begin
               O := Default(TGdiObj); O.Kind := okOther;
               if fn = $01F9 then begin O.Kind := okBrush; O.Brush.Color := $808080; end;
               G.SetObj(G.NewObjectSlot, O);
             end;
      $012D: G.SelectObj(WU(0));
      $01F0: G.DeleteObj(WU(0));
      $0214: G.MoveTo(W(1), W(0));
      $0213: G.LineTo(W(1), W(0));
      $0324, $0325:                                              // POLYGON / POLYLINE
             begin
               n := W(0);
               if (n > 0) and (7 + n * 2 <= NativeInt(size)) then
               begin
                 SetLength(pts, n * 2);
                 for i := 0 to n * 2 - 1 do pts[i] := W(1 + i);
                 G.Poly(pts, n, fn = $0324, True);
               end;
             end;
      $0538: begin                                               // POLYPOLYGON
               np := W(0);
               if (np > 0) and (4 + np <= NativeInt(size)) then
               begin
                 SetLength(counts, np); cnt := 0;
                 for i := 0 to np - 1 do begin counts[i] := W(1 + i); Inc(cnt, Max(0, counts[i])); end;
                 // the points have to fit in the record
                 cnt := Min(cnt, (NativeInt(size) - 4 - np) div 2);
                 SetLength(pts, cnt * 2);
                 for i := 0 to cnt * 2 - 1 do pts[i] := W(1 + np + i);
                 G.PolyPoly(pts, counts, True);
               end;
             end;
      $041B: G.Rectangle(W(3), W(2), W(1), W(0));
      $0418: G.Ellipse(W(3), W(2), W(1), W(0));
      $061C: G.RoundRect(W(5), W(4), W(3), W(2), W(1), W(0));
      $0817: G.ArcShape(W(7), W(6), W(5), W(4), W(3), W(2), W(1), W(0), 0);
      $0830: G.ArcShape(W(7), W(6), W(5), W(4), W(3), W(2), W(1), W(0), 1);
      $081A: G.ArcShape(W(7), W(6), W(5), W(4), W(3), W(2), W(1), W(0), 2);
      $041F: G.SetPixel(W(3), W(2), Clr(0));
      $061D: begin                                               // PATBLT
               rop := Cardinal(WU(0)) or (Cardinal(WU(1)) shl 16);
               case rop of
                 $00000042: G.FillRectColor(W(5), W(4), W(5) + W(3), W(4) + W(2), 0);
                 $00FF0062: G.FillRectColor(W(5), W(4), W(5) + W(3), W(4) + W(2), $FFFFFF);
                 $00F00021: G.FillRectBrush(W(5), W(4), W(5) + W(3), W(4) + W(2));
               end;
             end;
      $0521: begin                                               // TEXTOUT
               n := W(0);
               SetLength(bytes, Max(0, n));
               for i := 0 to n - 1 do bytes[i] := RdU8(D, p + 8 + i);
               q := p + 8 + ((n + 1) and not 1);
               s := AnsiToUtf8(bytes, n, G.DC.Font.Charset);
               G.Text(RdI16(D, q + 2), RdI16(D, q), s, [], False);
             end;
      $0A32: begin                                               // EXTTEXTOUT
               n := W(2); opts := WU(3);
               q := p + 14;
               if (opts and 6) <> 0 then
               begin
                 if (opts and 2) <> 0 then                       // ETO_OPAQUE background
                   G.FillRectColor(RdI16(D, q), RdI16(D, q + 2), RdI16(D, q + 4), RdI16(D, q + 6), G.DC.BkColor);
                 Inc(q, 8);
               end;
               SetLength(bytes, Max(0, n));
               for i := 0 to n - 1 do bytes[i] := RdU8(D, q + i);
               s := AnsiToUtf8(bytes, n, G.DC.Font.Charset);
               q := q + ((n + 1) and not 1);
               SetLength(dxs, 0);
               if (n > 0) and (q + n * 2 <= p + NativeInt(size) * 2) then
               begin
                 SetLength(dxs, n);
                 for i := 0 to n - 1 do dxs[i] := RdI16(D, q + i * 2);
               end;
               if Utf8CharCountOk(s, Length(dxs)) then
                 G.Text(W(1), W(0), s, dxs, Length(dxs) > 0)
               else
                 G.Text(W(1), W(0), s, [], False);
             end;
      $0B41, $0F43, $0940:                                       // DIBSTRETCHBLT / STRETCHDIB / DIBBITBLT
             begin
               rop := Cardinal(WU(0)) or (Cardinal(WU(1)) shl 16);
               hasBmp := NativeInt(size) > (fn shr 8) + 3;
               k := 2;                                           // first word after the rop
               if fn = $0F43 then Inc(k);                        // ColorUsage
               if not hasBmp then
               begin
                 if fn = $0940 then G.FillRectBrush(W(k + 6), W(k + 5), W(k + 6) + W(k + 4), W(k + 5) + W(k + 3))
                 else G.FillRectBrush(W(k + 8), W(k + 7), W(k + 8) + W(k + 6), W(k + 7) + W(k + 5));
               end
               else
               begin
                 if fn = $0940 then q := p + 6 + (k + 6) * 2 else q := p + 6 + (k + 8) * 2;
                 k := RdI32(D, q);
                 n := RdU16(D, q + 14);
                 if n <= 8 then
                 begin
                   np := RdI32(D, q + 32); if (k <> 12) and (np <= 0) then np := 1 shl n;
                   if k = 12 then np := (1 shl n) * 3 else np := np * 4;
                 end
                 else if RdI32(D, q + 16) = 3 then np := 12 else np := 0;
                 if DecodeDib(D, q, 0, q + k + np, p + NativeInt(size) * 2 - (q + k + np), 0, img) then
                 begin
                   if fn = $0940 then                          // BitBlt: 1:1 copy
                     G.Bitmap(img, W(7), W(6), W(5), W(4), W(3), W(2), W(5), W(4), rop)
                   else if fn = $0B41 then                     // StretchBlt: source y from top
                     G.Bitmap(img, W(9), W(8), W(7), W(6), W(5), W(4), W(3), W(2), rop)
                   else                                        // StretchDIBits: from bottom
                     G.Bitmap(img, W(10), W(9), W(8), W(7), W(6), img.H - W(5) - W(3), W(4), W(3), rop);
                 end;
               end;
             end;
    end;
    p := p + NativeInt(size) * 2;
  end;
end;

// --------------------------------- EMF ------------------------------------

// --------------------------------- EMF+ -----------------------------------

// EMF+ records ride in EMR_COMMENT records ("EMF+" after the comment size).
// An EMF+-only file has no usable EMF drawing; a dual file has both, and
// normally its EMF part is played (see WmfUseEmfPlus). EMF+ is played on the
// same GDI emulator: the world / page transform goes into DC.World, EMF+
// clips become the DC clip, and alpha becomes fill- / stroke-opacity.

procedure PlayEmf(G: TGdi; const D: TBytes); forward;

const
  EMFPLUS_SIG = $2B464D45;         // 'EMF+'
  MAX_NEST = 4;                    // metafile images inside metafiles

  // GDI+ hatch styles as 8 x 8 bitmaps (MSB = left pixel)
  PlusHatch: array[0..52, 0..7] of Byte = (
    ($FF, $00, $00, $00, $00, $00, $00, $00), ($80, $80, $80, $80, $80, $80, $80, $80),
    ($80, $40, $20, $10, $08, $04, $02, $01), ($01, $02, $04, $08, $10, $20, $40, $80),
    ($FF, $80, $80, $80, $80, $80, $80, $80), ($81, $42, $24, $18, $18, $24, $42, $81),
    ($80, $00, $00, $00, $08, $00, $00, $00), ($80, $00, $08, $00, $80, $00, $08, $00),
    ($88, $00, $22, $00, $88, $00, $22, $00), ($88, $22, $88, $22, $88, $22, $88, $22),
    ($AA, $44, $AA, $11, $AA, $44, $AA, $11), ($AA, $55, $AA, $51, $AA, $55, $AA, $15),
    ($AA, $55, $AA, $55, $AA, $55, $AA, $55), ($EE, $55, $BB, $55, $EE, $55, $BB, $55),
    ($77, $DD, $77, $DD, $77, $DD, $77, $DD), ($77, $FF, $DD, $FF, $77, $FF, $DD, $FF),
    ($EF, $FF, $FE, $FF, $EF, $FF, $FE, $FF), ($FF, $FF, $FF, $F7, $FF, $FF, $FF, $7F),
    ($88, $44, $22, $11, $88, $44, $22, $11), ($11, $22, $44, $88, $11, $22, $44, $88),
    ($CC, $66, $33, $99, $CC, $66, $33, $99), ($33, $66, $CC, $99, $33, $66, $CC, $99),
    ($C1, $E0, $70, $38, $1C, $0E, $07, $83), ($83, $07, $0E, $1C, $38, $70, $E0, $C1),
    ($88, $88, $88, $88, $88, $88, $88, $88), ($FF, $00, $00, $00, $FF, $00, $00, $00),
    ($55, $55, $55, $55, $55, $55, $55, $55), ($FF, $00, $FF, $00, $FF, $00, $FF, $00),
    ($CC, $CC, $CC, $CC, $CC, $CC, $CC, $CC), ($FF, $FF, $00, $00, $FF, $FF, $00, $00),
    ($00, $00, $88, $44, $22, $11, $00, $00), ($00, $00, $11, $22, $44, $88, $00, $00),
    ($F0, $00, $00, $00, $0F, $00, $00, $00), ($80, $80, $80, $80, $08, $08, $08, $08),
    ($80, $08, $40, $02, $10, $01, $20, $04), ($B1, $30, $03, $1B, $D8, $C0, $0C, $8D),
    ($81, $42, $24, $18, $81, $42, $24, $18), ($00, $18, $25, $C0, $00, $18, $25, $C0),
    ($01, $02, $04, $08, $18, $24, $42, $81), ($FF, $80, $80, $80, $FF, $08, $08, $08),
    ($88, $54, $22, $45, $88, $14, $22, $51), ($AA, $55, $AA, $55, $F0, $F0, $F0, $F0),
    ($00, $10, $08, $10, $00, $80, $01, $80), ($AA, $00, $80, $00, $80, $00, $80, $00),
    ($80, $00, $22, $00, $08, $00, $22, $00), ($03, $84, $48, $30, $0C, $02, $01, $01),
    ($FF, $66, $FF, $99, $FF, $66, $FF, $99), ($77, $89, $8F, $8F, $77, $98, $F8, $F8),
    ($FF, $88, $88, $88, $FF, $88, $88, $88), ($99, $66, $66, $99, $99, $66, $66, $99),
    ($F0, $F0, $F0, $F0, $0F, $0F, $0F, $0F), ($82, $44, $28, $10, $28, $44, $82, $01),
    ($10, $38, $7C, $FE, $7C, $38, $10, $00));

type
  TPlusPt = record
    X, Y: Double;
  end;
  TPlusPts = array of TPlusPt;

  TPlusPath = record
    Pts: TPlusPts;
    Types: array of Byte;     // low 3 bits: 0 start, 1 line, 3 bezier; $80 closes
    Winding: Boolean;         // fill mode (else alternate)
  end;

  TPlusBrush = record
    Kind: Integer;            // 0 solid, 1 hatch, 2 texture, 3 path gradient, 4 linear gradient
    Color, Color2: Cardinal;  // ARGB: solid; hatch fore / back; gradient start / end; centre / surround
    Hatch, Wrap: Integer;
    Xf: TXf;                  // brush space -> world
    Img: TRGBAImage;
    RX, RY, RW, RH: Double;   // linear gradient rectangle
    Preset: Boolean;          // Pos + Cols (preset colours) instead of Pos + Fac (blend)
    Pos, Fac: array of Double;
    Cols: array of Cardinal;
    CX, CY: Double;           // path gradient centre
    Bound: TPlusPath;         // path gradient boundary
    FocusX, FocusY: Double;
  end;

  TPlusPen = record
    Width: Double;
    WUnit, Style: Integer;    // Style: 0 solid, 1..4 dash styles, 5 custom
    Cap, Join: Integer;       // EMF+ LineCap / LineJoin values
    Dash: array of Double;
    Br: TPlusBrush;
  end;

  TPlusObj = record
    Kind: Integer;            // EMF+ object type; 0 = empty slot
    Data: TBytes;
    Want: Int64;              // continued object: total size being collected
    Br: TPlusBrush;
    Pen: TPlusPen;
    Path: TPlusPath;
    Img: TRGBAImage;
    Meta: TBytes;             // metafile image
    FontFace: string;
    FontEm: Double;
    FontUnit, FontStyle: Integer;
    SfFlags, SfAlign, SfLineAlign: Integer;
    SfLead: Double;
  end;

  TClipVal = record
    RectsOn: Boolean;         // False = no rectangle limit
    Rects: TClipRects;
    Paths: TStrArr;           // intersected, "N|d" or "E|d"
  end;

  TPlusSave = record
    Id: Cardinal;
    DC: TDC;
    World, Base: TXf;
    PageUnit: Integer;
    PageScale: Double;
    BaseClip: TClipVal;
  end;

  TEmfPlus = class
  private
    G: TGdi;
    Objs: array[0..63] of TPlusObj;
    World, Base: TXf;         // Base: transform of the innermost container
    PageUnit: Integer;
    PageScale, DpiX, DpiY: Double;
    Video: Boolean;
    BaseClip: TClipVal;
    Stack: array of TPlusSave;
    PlusDC, EmfDC: TDC;
    R: TBytes;                // data of the record being played
    Flags: Integer;
    function UnitF(U: Integer; Dpi: Double): Double;
    procedure Apply;
    function Pts(o: NativeInt; Count: Integer; out P: TPlusPts): Boolean;
    function RectAt(o: NativeInt; out x, y, w, h: Double): Integer;
    function PathD(const P: TPlusPath): string;
    function RectD(x, y, w, h: Double): string;
    function EllipseD(x, y, w, h: Double): string;
    function ArcD(x, y, w, h, a0, sweep: Double; Pie: Boolean): string;
    function PolyD(const P: TPlusPts; Closed: Boolean): string;
    function BezD(const P: TPlusPts): string;
    function CurveD(const P: TPlusPts; Tension: Double; Closed: Boolean; First, NSeg: Integer): string;
    function GetBrush(Id: Cardinal; IsColor: Boolean; out Br: TPlusBrush): Boolean;
    procedure FillD(const d: string; const Br: TPlusBrush; Winding: Boolean);
    procedure FillWith(const d: string; BrushId: Cardinal; Winding: Boolean);
    procedure StrokeD(const d: string; PenId: Integer);
    procedure FillGradient(const d: string; const Br: TPlusBrush; Winding: Boolean);
    function CurClip: TClipVal;
    procedure SetClip(const V: TClipVal);
    function Combine(const A, B: TClipVal; Mode: Integer): TClipVal;
    procedure ApplyClip(const V: TClipVal; Mode: Integer);
    function RectClip(x, y, w, h: Double): TClipVal;
    function PathClip(const P: TPlusPath): TClipVal;
    function RegionNode(const B: TBytes; var o: NativeInt; Depth: Integer): TClipVal;
    function RegionClip(Id: Integer; out V: TClipVal): Boolean;
    procedure PushState(Id: Cardinal);
    procedure PopState(Id: Cardinal);
    procedure ObjectRecord;
    procedure FinishObject(Id: Integer);
    procedure DrawString;
    procedure DrawDriverString;
    procedure DrawImage(Points: Boolean);
    procedure PlayNested(const Meta: TBytes; x, y, w, h: Double);
    procedure SetFont(Id: Integer; out Em: Double);
    procedure Rec(T: Integer);
  public
    GdiOn: Boolean;
    constructor Create(AG: TGdi);
    procedure Comment(const D: TBytes; p: NativeInt; Size: Cardinal);
  end;

threadvar
  NestDepth: Integer;

function ArgbToRef(c: Cardinal): Cardinal;
begin
  Result := ((c shr 16) and $FF) or (c and $FF00) or ((c and $FF) shl 16);
end;

function ArgbMix(c0, c1: Cardinal; t: Double): Cardinal;
var i: Integer; a, b: Double;
begin
  Result := 0;
  for i := 0 to 3 do
  begin
    a := (c0 shr (i * 8)) and $FF; b := (c1 shr (i * 8)) and $FF;
    Result := Result or (Cardinal(EnsureRange(Round(a + (b - a) * t), 0, 255)) shl (i * 8));
  end;
end;

function XfInv(const M: TXf; out Inv: TXf): Boolean;
var det: Double;
begin
  det := M.A * M.D - M.B * M.C;
  Result := Abs(det) > 1e-12;
  if not Result then Exit;
  Inv.A := M.D / det; Inv.B := -M.B / det; Inv.C := -M.C / det; Inv.D := M.A / det;
  Inv.E := -(Inv.A * M.E + Inv.C * M.F);
  Inv.F := -(Inv.B * M.E + Inv.D * M.F);
end;

function RdXf(const B: TBytes; o: NativeInt): TXf;
begin
  Result.A := RdF32(B, o); Result.B := RdF32(B, o + 4); Result.C := RdF32(B, o + 8);
  Result.D := RdF32(B, o + 12); Result.E := RdF32(B, o + 16); Result.F := RdF32(B, o + 20);
end;

// EmfPlusInteger7 / EmfPlusInteger15 of relative points
function RelInt(const B: TBytes; var o: NativeInt): Integer;
var b0: Integer;
begin
  b0 := RdU8(B, o);
  if (b0 and $80) = 0 then
  begin
    Result := b0; if Result >= 64 then Dec(Result, 128);
    Inc(o);
  end
  else
  begin
    Result := ((b0 and $7F) shl 8) or RdU8(B, o + 1); if Result >= $4000 then Dec(Result, $8000);
    Inc(o, 2);
  end;
end;

function RgbaToImg(const Px: TBytes; W, H: Integer; out Img: TRGBAImage): Boolean;
var i: Integer;
begin
  Img := Default(TRGBAImage);
  Result := (W > 0) and (H > 0) and (Int64(W) * H * 4 <= Length(Px));
  if not Result then Exit;
  Img.W := W; Img.H := H;
  SetLength(Img.Px, W * H);
  for i := 0 to W * H - 1 do
    Img.Px[i] := (Cardinal(Px[i * 4 + 3]) shl 24) or (Cardinal(Px[i * 4]) shl 16) or
                 (Cardinal(Px[i * 4 + 1]) shl 8) or Px[i * 4 + 2];
end;

// EmfPlusPath object at o
function ParsePlusPath(const B: TBytes; o: NativeInt; out P: TPlusPath): Boolean;
var
  n, i, k, fl, run: Integer;
  q: NativeInt;
  x, y: Double;
begin
  P := Default(TPlusPath);
  Result := False;
  n := RdI32(B, o + 4); fl := RdI32(B, o + 8);
  q := o + 12;
  if (n <= 0) or (n > Length(B) - q) then Exit;
  SetLength(P.Pts, n); SetLength(P.Types, n);
  P.Winding := (fl and $2000) <> 0;
  if (fl and $0800) <> 0 then
  begin
    x := 0; y := 0;
    for i := 0 to n - 1 do
    begin
      x := x + RelInt(B, q); y := y + RelInt(B, q);
      P.Pts[i].X := x; P.Pts[i].Y := y;
    end;
  end
  else if (fl and $4000) <> 0 then
  begin
    if q + Int64(n) * 4 > Length(B) then Exit;
    for i := 0 to n - 1 do
    begin
      P.Pts[i].X := RdI16(B, q); P.Pts[i].Y := RdI16(B, q + 2); Inc(q, 4);
    end;
  end
  else
  begin
    if q + Int64(n) * 8 > Length(B) then Exit;
    for i := 0 to n - 1 do
    begin
      P.Pts[i].X := RdF32(B, q); P.Pts[i].Y := RdF32(B, q + 4); Inc(q, 8);
    end;
  end;
  if (fl and $1000) <> 0 then
  begin
    // run-length point types: count (6 bits), type
    i := 0;
    while (i < n) and (q + 2 <= Length(B)) do
    begin
      run := RdU8(B, q) and $3F;
      for k := 1 to run do
        if i < n then begin P.Types[i] := RdU8(B, q + 1); Inc(i); end;
      Inc(q, 2);
    end;
  end
  else
    for i := 0 to n - 1 do P.Types[i] := RdU8(B, q + i);
  Result := True;
end;

// EmfPlusImage object at o: a bitmap (raw pixels or a compressed file) or a
// metafile
function ParsePlusImage(const B: TBytes; o: NativeInt; out Img: TRGBAImage; out Meta: TBytes): Boolean;
var
  w, h, stride, pf, bpp, x, y, v, np, i: Integer;
  q, row: NativeInt;
  pal: array of Cardinal;
  sub, px: TBytes;
  ww, hh: Integer;
  c, a, r, g, cb: Cardinal;
begin
  Img := Default(TRGBAImage); Meta := nil;
  Result := False;
  case RdI32(B, o + 4) of
    1:
      begin
        w := RdI32(B, o + 8); h := RdI32(B, o + 12); stride := RdI32(B, o + 16);
        pf := RdI32(B, o + 20);
        q := o + 28;
        if RdI32(B, o + 24) = 1 then
        begin
          // compressed: a complete image file
          if q >= Length(B) then Exit;
          sub := Copy(B, q, Length(B) - q);
          try
            if (Length(sub) > 8) and (sub[0] = $89) and (sub[1] = $50) then px := DecodePng(sub, ww, hh)
            else if (Length(sub) > 4) and (sub[0] = $FF) and (sub[1] = $D8) then px := DecodeJpeg(sub, ww, hh)
            else if (Length(sub) > 6) and (sub[0] = Ord('G')) and (sub[1] = Ord('I')) then px := DecodeGif(sub, ww, hh)
            else if (Length(sub) > 14) and (sub[0] = Ord('B')) and (sub[1] = Ord('M')) then px := DecodeBmp(sub, ww, hh)
            else if (Length(sub) > 8) and (((sub[0] = Ord('I')) and (sub[1] = Ord('I'))) or
                    ((sub[0] = Ord('M')) and (sub[1] = Ord('M')))) then px := DecodeTiff(sub, ww, hh)
            else Exit;
          except
            Exit;
          end;
          Exit(RgbaToImg(px, ww, hh, Img));
        end;
        if (w <= 0) or (h <= 0) or (w > 32768) or (h > 32768) or (Int64(w) * h > 64 * 1024 * 1024) then Exit;
        bpp := (pf shr 8) and $FF;
        if not (bpp in [1, 4, 8, 16, 24, 32, 48, 64]) then Exit;
        if (pf and $10000) <> 0 then
        begin
          // indexed: the palette comes first
          np := RdI32(B, q + 4);
          if (np < 0) or (np > 256) then Exit;
          SetLength(pal, 256);
          for i := 0 to 255 do pal[i] := $FF000000;
          for i := 0 to np - 1 do pal[i] := RdU32(B, q + 8 + i * 4);
          q := q + 8 + np * 4;
        end;
        if (bpp <= 8) and (pal = nil) then
        begin
          SetLength(pal, 256);
          for i := 0 to 255 do pal[i] := $FF000000 or Cardinal((i * 255 div ((1 shl bpp) - 1) and $FF) * $010101);
        end;
        if stride = 0 then stride := ((w * bpp + 31) div 32) * 4;
        stride := Abs(stride);
        if q + Int64(stride) * (h - 1) + (Int64(w) * bpp + 7) div 8 > Length(B) then Exit;
        Img.W := w; Img.H := h;
        SetLength(Img.Px, w * h);
        for y := 0 to h - 1 do
        begin
          row := q + NativeInt(y) * stride;
          for x := 0 to w - 1 do
          begin
            case bpp of
              1: c := pal[(B[row + x shr 3] shr (7 - x and 7)) and 1];
              4: c := pal[(B[row + x shr 1] shr (4 - 4 * (x and 1))) and 15];
              8: c := pal[B[row + x]];
              16:
                begin
                  v := RdU16(B, row + x * 2);
                  case pf of
                    $00021006:                                           // 565
                      c := $FF000000 or (Cardinal((v shr 11) * 255 div 31) shl 16) or
                           (Cardinal(((v shr 5) and 63) * 255 div 63) shl 8) or Cardinal((v and 31) * 255 div 31);
                    $00101004:                                           // 16-bit grey
                      c := $FF000000 or Cardinal((v shr 8) * $010101);
                  else                                                   // 555 / 1555
                    begin
                      c := (Cardinal(((v shr 10) and 31) * 255 div 31) shl 16) or
                           (Cardinal(((v shr 5) and 31) * 255 div 31) shl 8) or Cardinal((v and 31) * 255 div 31);
                      if (pf <> $00061007) or ((v and $8000) <> 0) then c := c or $FF000000;
                    end;
                  end;
                end;
              24: c := $FF000000 or (Cardinal(B[row + x * 3 + 2]) shl 16) or (Cardinal(B[row + x * 3 + 1]) shl 8) or
                       B[row + x * 3];
              32:
                begin
                  c := RdU32(B, row + x * 4);
                  if pf = $00022009 then c := c or $FF000000
                  else if pf = $000E200B then
                  begin
                    a := c shr 24;
                    if (a > 0) and (a < 255) then
                    begin
                      r := Min(255, ((c shr 16) and $FF) * 255 div a);
                      g := Min(255, ((c shr 8) and $FF) * 255 div a);
                      cb := Min(255, (c and $FF) * 255 div a);
                      c := (a shl 24) or (r shl 16) or (g shl 8) or cb;
                    end;
                  end;
                end;
            else
              begin
                // 48 / 64 bpp: 16-bit channels on a 0..8192 scale
                i := bpp div 16;
                cb := Min(255, RdU16(B, row + x * i * 2) * 255 div 8192);
                g := Min(255, RdU16(B, row + x * i * 2 + 2) * 255 div 8192);
                r := Min(255, RdU16(B, row + x * i * 2 + 4) * 255 div 8192);
                if i = 4 then a := Min(255, RdU16(B, row + x * 8 + 6) * 255 div 8192) else a := 255;
                c := (a shl 24) or (r shl 16) or (g shl 8) or cb;
              end;
            end;
            Img.Px[y * w + x] := c;
          end;
        end;
        Result := True;
      end;
    2:
      begin
        v := RdI32(B, o + 12);
        q := o + 16;
        if (v <= 0) or (q + v > Length(B)) then Exit;
        Meta := Copy(B, q, v);
        Result := True;
      end;
  end;
end;

// blend data: count, positions, then factors (4 bytes each) or ARGB colours
function ReadBlend(const B: TBytes; var q: NativeInt; var Br: TPlusBrush; Preset: Boolean): Boolean;
var n, i: Integer;
begin
  n := RdI32(B, q);
  Result := (n >= 2) and (n <= 4096) and (q + 4 + Int64(n) * 8 <= Length(B));
  if not Result then Exit;
  Br.Preset := Preset;
  SetLength(Br.Pos, n); SetLength(Br.Fac, n); SetLength(Br.Cols, n);
  for i := 0 to n - 1 do
  begin
    Br.Pos[i] := RdF32(B, q + 4 + i * 4);
    if Preset then Br.Cols[i] := RdU32(B, q + 4 + n * 4 + i * 4)
    else Br.Fac[i] := RdF32(B, q + 4 + n * 4 + i * 4);
  end;
  q := q + 4 + n * 8;
end;

// EmfPlusBrush object at o
function ParsePlusBrush(const B: TBytes; o: NativeInt; out Br: TPlusBrush): Boolean;
var
  fl, n, i, sz: Integer;
  q: NativeInt;
  meta: TBytes;
  r, g, bl, a: Int64;
  c: Cardinal;
begin
  Br := Default(TPlusBrush);
  Br.Xf := Ident;
  Br.Kind := RdI32(B, o + 4);
  Result := True;
  case Br.Kind of
    0: Br.Color := RdU32(B, o + 8);
    1:
      begin
        Br.Hatch := RdI32(B, o + 8); Br.Color := RdU32(B, o + 12); Br.Color2 := RdU32(B, o + 16);
        if (Br.Hatch < 0) or (Br.Hatch > 52) then Br.Hatch := 0;
      end;
    2:
      begin
        fl := RdI32(B, o + 8); Br.Wrap := RdI32(B, o + 12);
        q := o + 16;
        if (fl and 2) <> 0 then begin Br.Xf := RdXf(B, q); Inc(q, 24); end;
        Result := ParsePlusImage(B, q, Br.Img, meta) and (Length(Br.Img.Px) > 0);
      end;
    3:
      begin
        fl := RdI32(B, o + 8); Br.Wrap := RdI32(B, o + 12);
        Br.Color := RdU32(B, o + 16);
        Br.CX := RdF32(B, o + 20); Br.CY := RdF32(B, o + 24);
        n := RdI32(B, o + 28);
        if (n < 0) or (o + 32 + Int64(n) * 4 > Length(B)) then Exit(False);
        // several surrounding colours: their average
        r := 0; g := 0; bl := 0; a := 0;
        for i := 0 to n - 1 do
        begin
          c := RdU32(B, o + 32 + i * 4);
          a := a + c shr 24; r := r + (c shr 16) and $FF; g := g + (c shr 8) and $FF; bl := bl + c and $FF;
        end;
        if n > 0 then
          Br.Color2 := (Cardinal(a div n) shl 24) or (Cardinal(r div n) shl 16) or (Cardinal(g div n) shl 8) or
                       Cardinal(bl div n)
        else Br.Color2 := Br.Color;
        q := o + 32 + n * 4;
        if (fl and 1) <> 0 then
        begin
          sz := RdI32(B, q);
          if (sz <= 0) or (q + 4 + sz > Length(B)) or not ParsePlusPath(B, q + 4, Br.Bound) then Exit(False);
          q := q + 4 + sz;
        end
        else
        begin
          n := RdI32(B, q);
          if (n <= 0) or (q + 4 + Int64(n) * 8 > Length(B)) then Exit(False);
          SetLength(Br.Bound.Pts, n); SetLength(Br.Bound.Types, n);
          for i := 0 to n - 1 do
          begin
            Br.Bound.Pts[i].X := RdF32(B, q + 4 + i * 8); Br.Bound.Pts[i].Y := RdF32(B, q + 8 + i * 8);
            Br.Bound.Types[i] := 1;
          end;
          Br.Bound.Types[0] := 0; Br.Bound.Types[n - 1] := $81;
          q := q + 4 + n * 8;
        end;
        if (fl and 2) <> 0 then begin Br.Xf := RdXf(B, q); Inc(q, 24); end;
        if (fl and 4) <> 0 then ReadBlend(B, q, Br, True)
        else if (fl and 8) <> 0 then ReadBlend(B, q, Br, False);
        if (fl and $40) <> 0 then
        begin
          Br.FocusX := EnsureRange(RdF32(B, q + 4), 0, 1); Br.FocusY := EnsureRange(RdF32(B, q + 8), 0, 1);
        end;
      end;
    4:
      begin
        fl := RdI32(B, o + 8); Br.Wrap := RdI32(B, o + 12);
        Br.RX := RdF32(B, o + 16); Br.RY := RdF32(B, o + 20);
        Br.RW := RdF32(B, o + 24); Br.RH := RdF32(B, o + 28);
        Br.Color := RdU32(B, o + 32); Br.Color2 := RdU32(B, o + 36);
        q := o + 48;
        if (fl and 2) <> 0 then begin Br.Xf := RdXf(B, q); Inc(q, 24); end;
        if (fl and 4) <> 0 then ReadBlend(B, q, Br, True)
        else if (fl and 8) <> 0 then ReadBlend(B, q, Br, False);
      end;
  else
    Result := False;
  end;
end;

// EmfPlusPen object at o
function ParsePlusPen(const B: TBytes; o: NativeInt; out P: TPlusPen): Boolean;
var fl, n, i: Integer; q: NativeInt;
begin
  P := Default(TPlusPen);
  fl := RdI32(B, o + 8); P.WUnit := RdI32(B, o + 12); P.Width := RdF32(B, o + 16);
  q := o + 20;
  if (fl and $0001) <> 0 then Inc(q, 24);          // transform
  if (fl and $0002) <> 0 then begin P.Cap := RdI32(B, q); Inc(q, 4); end;    // start cap
  if (fl and $0004) <> 0 then begin P.Cap := RdI32(B, q); Inc(q, 4); end;    // end cap
  if (fl and $0008) <> 0 then begin P.Join := RdI32(B, q); Inc(q, 4); end;   // join
  if (fl and $0010) <> 0 then Inc(q, 4);           // miter limit
  if (fl and $0020) <> 0 then begin P.Style := RdI32(B, q); Inc(q, 4); end;
  if (fl and $0040) <> 0 then Inc(q, 4);           // dashed line cap
  if (fl and $0080) <> 0 then Inc(q, 4);           // dash offset
  if (fl and $0100) <> 0 then
  begin
    n := RdI32(B, q);
    if (n < 0) or (n > 1024) then Exit(False);
    SetLength(P.Dash, n);
    for i := 0 to n - 1 do P.Dash[i] := RdF32(B, q + 4 + i * 4);
    q := q + 4 + n * 4;
    if n > 0 then P.Style := 5;
  end;
  if (fl and $0200) <> 0 then Inc(q, 4);           // alignment
  if (fl and $0400) <> 0 then q := q + 4 + Int64(Max(0, Min(RdI32(B, q), 1 shl 20))) * 4;   // compound
  if (fl and $0800) <> 0 then q := q + 4 + Int64(Max(0, RdI32(B, q)));                        // custom caps
  if (fl and $1000) <> 0 then q := q + 4 + Int64(Max(0, RdI32(B, q)));
  if (P.Style < 0) or (P.Style > 5) then P.Style := 0;
  Result := ParsePlusBrush(B, q, P.Br);
end;

function PlusAvgColor(const Br: TPlusBrush): Cardinal;   // ARGB
begin
  case Br.Kind of
    0, 1: Result := Br.Color;
    2: Result := $FF000000 or ArgbToRef(AverageColor(Br.Img));
  else Result := ArgbMix(Br.Color, Br.Color2, 0.5);
  end;
end;

// ---- TEmfPlus ----

constructor TEmfPlus.Create(AG: TGdi);
begin
  inherited Create;
  G := AG;
  World := Ident; Base := Ident;
  PageUnit := 1; PageScale := 1;
  DpiX := 96; DpiY := 96; Video := True;
  EmfDC := G.DC;
  G.DC.MapMode := 1;
  G.DC.WinOrgX := 0; G.DC.WinOrgY := 0; G.DC.VpOrgX := 0; G.DC.VpOrgY := 0;
  G.DC.World := Ident;
end;

function TEmfPlus.UnitF(U: Integer; Dpi: Double): Double;
begin
  case U of
    1: if Video then Result := Dpi / 96 else Result := Dpi / 100;   // display
    3: Result := Dpi / 72;                                           // point
    4: Result := Dpi;                                                // inch
    5: Result := Dpi / 300;                                          // document
    6: Result := Dpi / 25.4;                                         // millimetre
  else Result := 1;                                                  // world, pixel
  end;
end;

// world -> page -> device, into the emulator's world transform
procedure TEmfPlus.Apply;
var P: TXf;
begin
  P := Ident;
  P.A := PageScale * UnitF(PageUnit, DpiX);
  P.D := PageScale * UnitF(PageUnit, DpiY);
  G.DC.World := XfMul(P, World);
end;

// points of a drawing record: float, 16-bit (C flag) or relative (P flag)
function TEmfPlus.Pts(o: NativeInt; Count: Integer; out P: TPlusPts): Boolean;
var i: Integer; x, y: Double;
begin
  P := nil;
  Result := False;
  if (Count <= 0) or (Count > Length(R)) then Exit;
  SetLength(P, Count);
  if (Flags and $0800) <> 0 then
  begin
    x := 0; y := 0;
    for i := 0 to Count - 1 do
    begin
      x := x + RelInt(R, o); y := y + RelInt(R, o);
      P[i].X := x; P[i].Y := y;
    end;
    Result := o <= Length(R);
  end
  else if (Flags and $4000) <> 0 then
  begin
    if o + Int64(Count) * 4 > Length(R) then Exit;
    for i := 0 to Count - 1 do begin P[i].X := RdI16(R, o + i * 4); P[i].Y := RdI16(R, o + i * 4 + 2); end;
    Result := True;
  end
  else
  begin
    if o + Int64(Count) * 8 > Length(R) then Exit;
    for i := 0 to Count - 1 do begin P[i].X := RdF32(R, o + i * 8); P[i].Y := RdF32(R, o + i * 8 + 4); end;
    Result := True;
  end;
end;

function TEmfPlus.RectAt(o: NativeInt; out x, y, w, h: Double): Integer;
begin
  if (Flags and $4000) <> 0 then
  begin
    x := RdI16(R, o); y := RdI16(R, o + 2); w := RdI16(R, o + 4); h := RdI16(R, o + 6);
    Result := 8;
  end
  else
  begin
    x := RdF32(R, o); y := RdF32(R, o + 4); w := RdF32(R, o + 8); h := RdF32(R, o + 12);
    Result := 16;
  end;
end;

function TEmfPlus.PathD(const P: TPlusPath): string;
var sb: TStringBuilder; i, n, t: Integer;
begin
  sb := TStringBuilder.Create;
  try
    n := Min(Length(P.Pts), Length(P.Types));
    i := 0;
    while i < n do
    begin
      t := P.Types[i] and 7;
      if (t = 0) or (i = 0) then G.PathMove(sb, P.Pts[i].X, P.Pts[i].Y)
      else if (t = 3) and (i + 2 < n) then
      begin
        G.PathCubic(sb, P.Pts[i].X, P.Pts[i].Y, P.Pts[i + 1].X, P.Pts[i + 1].Y, P.Pts[i + 2].X, P.Pts[i + 2].Y);
        Inc(i, 2);
      end
      else G.PathLine(sb, P.Pts[i].X, P.Pts[i].Y);
      if (P.Types[i] and $80) <> 0 then sb.Append('Z ');
      Inc(i);
    end;
    Result := Trim(sb.ToString);
  finally
    sb.Free;
  end;
end;

function TEmfPlus.RectD(x, y, w, h: Double): string;
var sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    G.PathMove(sb, x, y); G.PathLine(sb, x + w, y); G.PathLine(sb, x + w, y + h); G.PathLine(sb, x, y + h);
    sb.Append('Z');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function TEmfPlus.EllipseD(x, y, w, h: Double): string;
var sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    G.EllipseArc(sb, x + w / 2, y + h / 2, w / 2, h / 2, 0, 2 * Pi, True);
    sb.Append('Z');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

// Angles are true angles on the ellipse, clockwise (y down), in degrees.
function TEmfPlus.ArcD(x, y, w, h, a0, sweep: Double; Pie: Boolean): string;
var
  sb: TStringBuilder;
  rx, ry, t0, t1, dt: Double;

  function Param(a: Double): Double;
  begin
    a := DegToRad(a);
    Result := ArcTan2(rx * Sin(a), ry * Cos(a));
  end;

begin
  rx := w / 2; ry := h / 2;
  sweep := EnsureRange(sweep, -360, 360);
  if Abs(a0) > 1e9 then a0 := 0;
  a0 := a0 - 360 * Floor(a0 / 360);
  t0 := Param(a0);
  if Abs(sweep) >= 360 then dt := 2 * Pi * Sign(sweep)
  else
  begin
    t1 := Param(a0 + sweep);
    dt := t1 - t0;
    if sweep > 0 then begin while dt < 0 do dt := dt + 2 * Pi; end
    else if sweep < 0 then begin while dt > 0 do dt := dt - 2 * Pi; end;
  end;
  sb := TStringBuilder.Create;
  try
    if Pie then
    begin
      G.PathMove(sb, x + rx, y + ry);
      G.EllipseArc(sb, x + rx, y + ry, rx, ry, t0, dt, False);
      sb.Append('Z');
    end
    else G.EllipseArc(sb, x + rx, y + ry, rx, ry, t0, dt, True);
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function TEmfPlus.PolyD(const P: TPlusPts; Closed: Boolean): string;
var sb: TStringBuilder; i: Integer;
begin
  sb := TStringBuilder.Create;
  try
    for i := 0 to High(P) do
      if i = 0 then G.PathMove(sb, P[i].X, P[i].Y) else G.PathLine(sb, P[i].X, P[i].Y);
    if Closed then sb.Append('Z');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function TEmfPlus.BezD(const P: TPlusPts): string;
var sb: TStringBuilder; i: Integer;
begin
  sb := TStringBuilder.Create;
  try
    if Length(P) > 0 then G.PathMove(sb, P[0].X, P[0].Y);
    i := 1;
    while i + 2 <= High(P) do
    begin
      G.PathCubic(sb, P[i].X, P[i].Y, P[i + 1].X, P[i + 1].Y, P[i + 2].X, P[i + 2].Y);
      Inc(i, 3);
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

// Cardinal spline as Béziers: the tangent at a point is (next - previous)
// times tension * 0.3, as GDI+ draws it.
function TEmfPlus.CurveD(const P: TPlusPts; Tension: Double; Closed: Boolean; First, NSeg: Integer): string;
var
  sb: TStringBuilder;
  n, i, j, a, b: Integer;
  t: Double;
  cin, cout: TPlusPts;
begin
  Result := '';
  n := Length(P);
  if n < 2 then Exit;
  t := Tension * 0.3;
  SetLength(cin, n); SetLength(cout, n);
  for i := 0 to n - 1 do
  begin
    if Closed or ((i > 0) and (i < n - 1)) then
    begin
      a := (i + n - 1) mod n; b := (i + 1) mod n;
      cin[i].X := P[i].X - t * (P[b].X - P[a].X); cin[i].Y := P[i].Y - t * (P[b].Y - P[a].Y);
      cout[i].X := P[i].X + t * (P[b].X - P[a].X); cout[i].Y := P[i].Y + t * (P[b].Y - P[a].Y);
    end
    else if i = 0 then
    begin
      cout[0].X := P[0].X + t * (P[1].X - P[0].X); cout[0].Y := P[0].Y + t * (P[1].Y - P[0].Y);
    end
    else
    begin
      cin[i].X := P[i].X + t * (P[i - 1].X - P[i].X); cin[i].Y := P[i].Y + t * (P[i - 1].Y - P[i].Y);
    end;
  end;
  if Closed then begin First := 0; NSeg := n; end
  else
  begin
    First := EnsureRange(First, 0, n - 2);
    NSeg := EnsureRange(NSeg, 1, n - 1 - First);
  end;
  sb := TStringBuilder.Create;
  try
    G.PathMove(sb, P[First].X, P[First].Y);
    for j := First to First + NSeg - 1 do
    begin
      a := j mod n; b := (j + 1) mod n;
      G.PathCubic(sb, cout[a].X, cout[a].Y, cin[b].X, cin[b].Y, P[b].X, P[b].Y);
    end;
    if Closed then sb.Append('Z');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function TEmfPlus.GetBrush(Id: Cardinal; IsColor: Boolean; out Br: TPlusBrush): Boolean;
begin
  Br := Default(TPlusBrush);
  if IsColor then
  begin
    Br.Kind := 0; Br.Color := Id;
    Exit(True);
  end;
  Result := (Id <= 63) and (Objs[Id].Kind = 1);
  if Result then Br := Objs[Id].Br;
end;

procedure TEmfPlus.FillWith(const d: string; BrushId: Cardinal; Winding: Boolean);
var Br: TPlusBrush;
begin
  if GetBrush(BrushId, (Flags and $8000) <> 0, Br) then FillD(d, Br, Winding);
end;

procedure TEmfPlus.FillD(const d: string; const Br: TPlusBrush; Winding: Boolean);
var
  Img: TRGBAImage;
  x, y: Integer;
  a0, a1: Cardinal;
begin
  if d = '' then Exit;
  Apply;
  if Winding then G.DC.PolyFill := 2 else G.DC.PolyFill := 1;
  G.DC.Brush := Default(TBrushRec);
  case Br.Kind of
    0:
      begin
        if (Br.Color shr 24) = 0 then Exit;
        G.DC.Brush.Color := ArgbToRef(Br.Color);
        G.DC.Brush.Transp := 255 - Integer(Br.Color shr 24);
      end;
    1:
      begin
        a0 := Br.Color shr 24; a1 := Br.Color2 shr 24;
        if (a0 = 0) and (a1 = 0) then Exit;
        Img.W := 8; Img.H := 8;
        SetLength(Img.Px, 64);
        for y := 0 to 7 do
          for x := 0 to 7 do
            if (PlusHatch[Br.Hatch, y] and ($80 shr x)) <> 0 then Img.Px[y * 8 + x] := Br.Color
            else Img.Px[y * 8 + x] := Br.Color2;
        // one alpha for both colours becomes the fill opacity
        if (a0 = a1) or (a1 < 128) then
        begin
          if a0 >= 128 then G.DC.Brush.Transp := 255 - Integer(a0);
        end
        else if a0 < 128 then G.DC.Brush.Transp := 255 - Integer(a1);
        for x := 0 to 63 do
          if (Img.Px[x] shr 24) >= 128 then Img.Px[x] := Img.Px[x] or $FF000000;
        G.DC.Brush.Style := 4;
        G.DC.Brush.Pat := Img;
        G.DC.Brush.PatXf := Ident;                 // device pixels from the origin
        G.DC.Brush.Color := ArgbToRef(Br.Color);
      end;
    2:
      begin
        if Int64(Br.Img.W) * Br.Img.H <= 16384 then
        begin
          G.DC.Brush.Style := 4;
          G.DC.Brush.Pat := Br.Img;
          G.DC.Brush.PatXf := XfMul(G.Full, Br.Xf);
        end
        else G.DC.Brush.Color := AverageColor(Br.Img);
      end;
    3, 4:
      begin
        FillGradient(d, Br, Winding);
        Exit;
      end;
  else
    Exit;
  end;
  G.EmitShape(d, True, False);
end;

procedure TEmfPlus.StrokeD(const d: string; PenId: Integer);
var
  P: TPlusPen;
  c: Cardinal;
  s, w: Double;
  i: Integer;
begin
  if (d = '') or (PenId < 0) or (PenId > 63) or (Objs[PenId].Kind <> 2) then Exit;
  P := Objs[PenId].Pen;
  c := PlusAvgColor(P.Br);
  if (c shr 24) = 0 then Exit;
  Apply;
  s := Sqrt(G.LinScaleX * G.LinScaleY);
  if s < 1e-9 then Exit;
  // width in output pixels
  if P.WUnit = 0 then w := P.Width * s
  else if P.WUnit = 2 then w := P.Width * G.DevScale
  else w := P.Width * UnitF(P.WUnit, DpiX) / Max(1e-9, PageScale * UnitF(PageUnit, DpiX)) * s;
  w := Max(w, 1);
  G.DC.Pen := Default(TPenRec);
  G.DC.Pen.Cosmetic := False;
  G.DC.Pen.Width := w / s;
  G.DC.Pen.Color := ArgbToRef(c);
  G.DC.Pen.Transp := 255 - Integer(c shr 24);
  case P.Cap of                                       // flat, square, round, triangle...
    1: G.DC.Pen.Cap := 3;
    2: G.DC.Pen.Cap := 2;
  else G.DC.Pen.Cap := 1;
  end;
  case P.Join of                                      // miter, bevel, round, miter-clipped
    1: G.DC.Pen.Join := 2;
    2: G.DC.Pen.Join := 3;
  else G.DC.Pen.Join := 1;
  end;
  case P.Style of
    1..4: G.DC.Pen.Style := P.Style;
    5:
      begin
        G.DC.Pen.Style := 7;
        SetLength(G.DC.Pen.Dash, Length(P.Dash));
        for i := 0 to High(P.Dash) do G.DC.Pen.Dash[i] := Max(0.05, P.Dash[i]) * G.DC.Pen.Width;
      end;
  end;
  G.EmitShape(d, False, True);
end;

// output-space bounding box of a path written by the emulator
function DBounds(const d: string; out x0, y0, x1, y1: Double): Boolean;
var
  i, j, k: Integer;
  v: Double;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings; FS.DecimalSeparator := '.';
  x0 := MaxDouble; y0 := MaxDouble; x1 := -MaxDouble; y1 := -MaxDouble;
  k := 0; i := 1;
  while i <= Length(d) do
  begin
    if CharInSet(d[i], ['0'..'9', '-', '.']) then
    begin
      j := i;
      while (j <= Length(d)) and CharInSet(d[j], ['0'..'9', '-', '.']) do Inc(j);
      v := StrToFloatDef(Copy(d, i, j - i), 0, FS);
      if (k and 1) = 0 then begin x0 := Min(x0, v); x1 := Max(x1, v); end
      else begin y0 := Min(y0, v); y1 := Max(y1, v); end;
      Inc(k);
      i := j;
    end
    else Inc(i);
  end;
  Result := (x1 >= x0) and (y1 >= y0);
end;

// Gradients: the shape becomes a clip path and the gradient is painted in
// bands (linear) or rings (path gradient), each a solid colour.
procedure TEmfPlus.FillGradient(const d: string; const Br: TPlusBrush; Winding: Boolean);
var
  x0, y0, x1, y1, L, t0, t1, tmin, tmax, vmin, vmax, u, v, step, ov: Double;
  M, Mi, Save: TXf;
  id, rule: string;
  k, k0, k1, n, i, j: Integer;
  c, prev: Cardinal;
  runStart: Double;
  BP: TPlusPath;
  sx, sy, pos: Double;
  SaveW: TXf;

  function FacAt(t: Double): Double;
  var q: Integer; a: Double;
  begin
    q := 0;
    while (q < High(Br.Pos) - 1) and (t > Br.Pos[q + 1]) do Inc(q);
    a := Br.Pos[q + 1] - Br.Pos[q];
    if Abs(a) < 1e-9 then Result := Br.Fac[q]
    else Result := Br.Fac[q] + (Br.Fac[q + 1] - Br.Fac[q]) * EnsureRange((t - Br.Pos[q]) / a, 0, 1);
    Result := EnsureRange(Result, 0, 1);
  end;

  function BlendAt(t: Double): Cardinal;
  var a, f: Double; q: Integer;
  begin
    // wrap modes: 0 tile, 1..3 flip, 4 clamp
    case Br.Wrap of
      0, 2: t := t - Floor(t);
      1, 3: begin t := t - 2 * Floor(t / 2); if t > 1 then t := 2 - t; end;
    else t := EnsureRange(t, 0, 1);
    end;
    if Length(Br.Pos) >= 2 then
    begin
      q := 0;
      while (q < High(Br.Pos) - 1) and (t > Br.Pos[q + 1]) do Inc(q);
      a := Br.Pos[q + 1] - Br.Pos[q];
      if Abs(a) < 1e-9 then f := 0 else f := EnsureRange((t - Br.Pos[q]) / a, 0, 1);
      if Br.Preset then Exit(ArgbMix(Br.Cols[q], Br.Cols[q + 1], f));
      f := Br.Fac[q] + (Br.Fac[q + 1] - Br.Fac[q]) * f;
      Result := ArgbMix(Br.Color, Br.Color2, f);
    end
    else Result := ArgbMix(Br.Color, Br.Color2, t);
  end;

  procedure Band(c: Cardinal; ta, tb: Double);
  var sb: TStringBuilder; px, py: array[0..3] of Double; q: Integer; op: string;
  begin
    if (c shr 24) = 0 then Exit;
    px[0] := Br.RX + ta * Br.RW; py[0] := vmin; px[1] := Br.RX + tb * Br.RW; py[1] := vmin;
    px[2] := px[1]; py[2] := vmax; px[3] := px[0]; py[3] := vmax;
    sb := TStringBuilder.Create;
    try
      for q := 0 to 3 do
      begin
        if q = 0 then sb.Append('M') else sb.Append(' L');
        sb.Append(G.N(M.A * px[q] + M.C * py[q] + M.E)).Append(' ').Append(G.N(M.B * px[q] + M.D * py[q] + M.F));
      end;
      op := '';
      if (c shr 24) < 255 then op := ' fill-opacity="' + FloatToStrF((c shr 24) / 255, ffFixed, 6, 3, G.FFS) + '"';
      G.Put('<path d="' + sb.ToString + ' Z" fill="' + G.Color(ArgbToRef(c)) + '"' + op + ' stroke="none"/>');
    finally
      sb.Free;
    end;
  end;

  procedure Ring(c: Cardinal; fx, fy: Double);
  var q: Integer; op: string; P2: TPlusPath;
  begin
    if (c shr 24) = 0 then Exit;
    P2 := BP;
    P2.Pts := Copy(BP.Pts);
    for q := 0 to High(P2.Pts) do
    begin
      P2.Pts[q].X := Br.CX + (BP.Pts[q].X - Br.CX) * fx;
      P2.Pts[q].Y := Br.CY + (BP.Pts[q].Y - Br.CY) * fy;
    end;
    op := '';
    if (c shr 24) < 255 then op := ' fill-opacity="' + FloatToStrF((c shr 24) / 255, ffFixed, 6, 3, G.FFS) + '"';
    G.Put('<path d="' + PathD(P2) + '" fill="' + G.Color(ArgbToRef(c)) + '"' + op + ' stroke="none"/>');
  end;

begin
  if G.FMeasure or not DBounds(d, x0, y0, x1, y1) then Exit;
  Inc(G.FDefSerial);
  id := 'clip' + IntToStr(G.FDefSerial);
  if Winding then rule := 'nonzero' else rule := 'evenodd';
  G.Put('<clipPath id="' + id + '"><path d="' + Trim(d) + '" clip-rule="' + rule + '"/></clipPath>');
  G.Put('<g clip-path="url(#' + id + ')">');
  Save := G.DC.World;
  SaveW := World;
  try
    if Br.Kind = 4 then
    begin
      M := XfMul(G.Full, Br.Xf);                    // brush space -> output
      if (Abs(Br.RW) < 1e-9) or not XfInv(M, Mi) then
      begin
        Band(ArgbMix(Br.Color, Br.Color2, 0.5), 0, 1);
        Exit;
      end;
      tmin := MaxDouble; tmax := -MaxDouble; vmin := MaxDouble; vmax := -MaxDouble;
      for i := 0 to 3 do
      begin
        if i in [0, 3] then u := x0 else u := x1;
        if i < 2 then v := y0 else v := y1;
        t0 := Mi.A * u + Mi.C * v + Mi.E; t1 := Mi.B * u + Mi.D * v + Mi.F;
        tmin := Min(tmin, (t0 - Br.RX) / Br.RW); tmax := Max(tmax, (t0 - Br.RX) / Br.RW);
        vmin := Min(vmin, t1); vmax := Max(vmax, t1);
      end;
      vmin := vmin - 1; vmax := vmax + 1;
      L := Min(1e7, Sqrt(Sqr(M.A * Br.RW) + Sqr(M.B * Br.RW)));   // output pixels per gradient period
      n := EnsureRange(Round(L / 1.5), 2, 256);
      tmin := EnsureRange(tmin, -1000, 1000); tmax := EnsureRange(tmax, -1000, 1000);
      k0 := Floor(tmin * n); k1 := Ceil(tmax * n);
      if k1 - k0 > 4000 then
      begin
        n := Max(1, Round(n * 4000 / (k1 - k0)));
        k0 := Floor(tmin * n); k1 := Ceil(tmax * n);
      end;
      step := 1 / n;
      ov := 0;                                           // adjacent bands share exact edges
      prev := BlendAt((k0 + 0.5) * step); runStart := k0 * step;
      for k := k0 + 1 to k1 do
      begin
        if k < k1 then c := BlendAt((k + 0.5) * step) else c := not prev;
        if c <> prev then
        begin
          Band(prev, runStart, k * step + ov);
          prev := c; runStart := k * step;
        end;
      end;
    end
    else
    begin
      // path gradient: the boundary shrunk towards the centre, outside in
      BP := Br.Bound;
      if Length(BP.Pts) < 2 then Exit;
      World := XfMul(World, Br.Xf);
      Apply;
      L := 0;
      for i := 0 to High(BP.Pts) do
      begin
        G.Map(BP.Pts[i].X, BP.Pts[i].Y, u, v);
        G.Map(Br.CX, Br.CY, t0, t1);
        L := Max(L, Sqrt(Sqr(u - t0) + Sqr(v - t1)));
      end;
      n := EnsureRange(Round(L / 1.5), 4, 96);
      for j := 0 to n - 1 do
      begin
        pos := (j + 0.5) / n;                            // 0 = boundary, 1 = centre
        sx := 1 - (1 - Br.FocusX) * j / n; sy := 1 - (1 - Br.FocusY) * j / n;
        if (Length(Br.Pos) >= 2) and Br.Preset then c := BlendAt(pos)
        else if Length(Br.Pos) >= 2 then c := ArgbMix(Br.Color2, Br.Color, FacAt(pos))
        else c := ArgbMix(Br.Color2, Br.Color, pos);
        Ring(c, sx, sy);
      end;
      if (Br.FocusX > 0) or (Br.FocusY > 0) then Ring(Br.Color, Br.FocusX, Br.FocusY);
    end;
  finally
    World := SaveW;
    G.DC.World := Save;
    G.Put('</g>');
  end;
end;

// ---- clipping ----

function TEmfPlus.CurClip: TClipVal;
begin
  Result.RectsOn := G.DC.ClipOn;
  Result.Rects := G.DC.ClipRects;
  Result.Paths := G.DC.ClipPaths;
end;

procedure TEmfPlus.SetClip(const V: TClipVal);
begin
  G.DC.ClipOn := V.RectsOn;
  G.DC.ClipRects := V.Rects;
  G.DC.ClipPaths := V.Paths;
  G.NewClip;
end;

function RectsD(G: TGdi; const Rs: TClipRects): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to High(Rs) do
    Result := Result + 'M' + G.N(Rs[i].L) + ' ' + G.N(Rs[i].T) + ' L' + G.N(Rs[i].R) + ' ' + G.N(Rs[i].T) +
              ' L' + G.N(Rs[i].R) + ' ' + G.N(Rs[i].B) + ' L' + G.N(Rs[i].L) + ' ' + G.N(Rs[i].B) + ' Z ';
end;

// Region algebra on clip values: rectangle sets exactly, paths where the
// operation can be written as a clip path, otherwise approximately.
function TEmfPlus.Combine(const A, B: TClipVal; Mode: Integer): TClipVal;

  function IsInf(const V: TClipVal): Boolean;
  begin
    Result := (not V.RectsOn) and (Length(V.Paths) = 0);
  end;

  function RectsOf(const V: TClipVal): TClipRects;
  begin
    if V.RectsOn then Result := V.Rects else Result := InfiniteClip;
  end;

  // the value as one path ("N|d" / "E|d"), if it is a single component
  function OnePath(const V: TClipVal; out S: string): Boolean;
  begin
    Result := True;
    if (Length(V.Paths) = 1) and not V.RectsOn then S := V.Paths[0]
    else if (Length(V.Paths) = 0) and V.RectsOn then S := 'N|' + RectsD(G, V.Rects)
    else Result := False;
  end;

  function Join(const X, Y: TStrArr): TStrArr;
  var i: Integer;
  begin
    SetLength(Result, Length(X) + Length(Y));
    for i := 0 to High(X) do Result[i] := X[i];
    for i := 0 to High(Y) do Result[Length(X) + i] := Y[i];
  end;

var
  sa, sb: string;
  one: TStrArr;
begin
  Result := Default(TClipVal);
  case Mode of
    0: Result := B;
    1:
      begin
        Result.RectsOn := A.RectsOn or B.RectsOn;
        if A.RectsOn and B.RectsOn then Result.Rects := ClipOp(A.Rects, B.Rects, RGN_AND)
        else if A.RectsOn then Result.Rects := Copy(A.Rects)
        else Result.Rects := Copy(B.Rects);
        Result.Paths := Join(A.Paths, B.Paths);
      end;
    2:
      if IsInf(A) or IsInf(B) then Exit
      else if (Length(A.Paths) = 0) and (Length(B.Paths) = 0) then
      begin
        Result.RectsOn := True;
        Result.Rects := ClipOp(A.Rects, B.Rects, RGN_OR);
      end
      else if OnePath(A, sa) and OnePath(B, sb) then
      begin
        SetLength(Result.Paths, 1);
        Result.Paths[0] := 'N|' + Copy(sa, 3, MaxInt) + ' ' + Copy(sb, 3, MaxInt);
      end;
    3:
      if (Length(A.Paths) = 0) and (Length(B.Paths) = 0) then
      begin
        Result.RectsOn := True;
        Result.Rects := ClipOp(RectsOf(A), RectsOf(B), RGN_XOR);
      end
      else if OnePath(A, sa) and OnePath(B, sb) then
      begin
        SetLength(Result.Paths, 1);
        Result.Paths[0] := 'E|' + Copy(sa, 3, MaxInt) + ' ' + Copy(sb, 3, MaxInt);
      end
      else Result := A;
    4:
      if Length(B.Paths) = 0 then
      begin
        Result := A;
        Result.RectsOn := True;
        Result.Rects := ClipOp(RectsOf(A), RectsOf(B), RGN_DIFF);
      end
      else if (Length(B.Paths) = 1) and not B.RectsOn then
      begin
        // A minus a path: A and (everything xor the path)
        Result := A;
        SetLength(one, 1);
        one[0] := 'E|' + RectsD(G, InfiniteClip) + Copy(B.Paths[0], 3, MaxInt);
        Result.Paths := Join(A.Paths, one);
      end
      else Result := A;
    5: Result := Combine(B, A, 4);
  else
    Result := A;
  end;
end;

procedure TEmfPlus.ApplyClip(const V: TClipVal; Mode: Integer);
begin
  if Mode = 0 then SetClip(Combine(BaseClip, V, 1))       // replace, within the container
  else SetClip(Combine(CurClip, V, Mode));
end;

function TEmfPlus.RectClip(x, y, w, h: Double): TClipVal;
var M: TXf; ax, ay, bx, by: Double;
begin
  Result := Default(TClipVal);
  Apply;
  M := G.Full;
  if (Abs(M.B) < 1e-9) and (Abs(M.C) < 1e-9) then
  begin
    G.Map(x, y, ax, ay); G.Map(x + w, y + h, bx, by);
    Result.RectsOn := True;
    SetLength(Result.Rects, 1);
    Result.Rects[0] := ClipRect(ax, ay, bx, by);
    if (Abs(bx - ax) < 1e-9) or (Abs(by - ay) < 1e-9) then Result.Rects := nil;
  end
  else
  begin
    SetLength(Result.Paths, 1);
    Result.Paths[0] := 'N|' + RectD(x, y, w, h);
  end;
end;

function TEmfPlus.PathClip(const P: TPlusPath): TClipVal;
var d: string;
begin
  Result := Default(TClipVal);
  Apply;
  d := PathD(P);
  if d = '' then
  begin
    Result.RectsOn := True;                                // empty path: nothing visible
    Exit;
  end;
  SetLength(Result.Paths, 1);
  if P.Winding then Result.Paths[0] := 'N|' + d else Result.Paths[0] := 'E|' + d;
end;

function TEmfPlus.RegionNode(const B: TBytes; var o: NativeInt; Depth: Integer): TClipVal;
var
  t: Cardinal;
  sz: Integer;
  P: TPlusPath;
  L, Rt: TClipVal;
begin
  Result := Default(TClipVal);
  t := RdU32(B, o);
  Inc(o, 4);
  case t of
    $10000000:
      begin
        Result := RectClip(RdF32(B, o), RdF32(B, o + 4), RdF32(B, o + 8), RdF32(B, o + 12));
        Inc(o, 16);
      end;
    $10000001:
      begin
        sz := RdI32(B, o);
        if (sz > 0) and (o + 4 + sz <= Length(B)) and ParsePlusPath(B, o + 4, P) then Result := PathClip(P);
        o := o + 4 + Max(0, sz);
      end;
    $10000002: Result.RectsOn := True;                      // empty
    $10000003: ;                                            // infinite
    1..5:
      if Depth < 64 then
      begin
        L := RegionNode(B, o, Depth + 1);
        Rt := RegionNode(B, o, Depth + 1);
        Result := Combine(L, Rt, t);
      end;
  else
    o := Length(B);
  end;
end;

function TEmfPlus.RegionClip(Id: Integer; out V: TClipVal): Boolean;
var o: NativeInt;
begin
  V := Default(TClipVal);
  Result := (Id >= 0) and (Id <= 63) and (Objs[Id].Kind = 4);
  if not Result then Exit;
  o := 8;
  V := RegionNode(Objs[Id].Data, o, 0);
end;

// ---- state ----

procedure TEmfPlus.PushState(Id: Cardinal);
var S: TPlusSave;
begin
  if Length(Stack) >= 4096 then Exit;
  S.Id := Id; S.DC := G.DC; S.World := World; S.Base := Base;
  S.PageUnit := PageUnit; S.PageScale := PageScale; S.BaseClip := BaseClip;
  SetLength(Stack, Length(Stack) + 1);
  Stack[High(Stack)] := S;
end;

procedure TEmfPlus.PopState(Id: Cardinal);
var i: Integer;
begin
  for i := High(Stack) downto 0 do
    if Stack[i].Id = Id then
    begin
      G.DC := Stack[i].DC; World := Stack[i].World; Base := Stack[i].Base;
      PageUnit := Stack[i].PageUnit; PageScale := Stack[i].PageScale; BaseClip := Stack[i].BaseClip;
      G.NewClip;
      SetLength(Stack, i);
      Exit;
    end;
end;

// ---- objects ----

procedure TEmfPlus.ObjectRecord;
var id, kind: Integer; chunk: TBytes; total: Int64;
begin
  id := Flags and $FF; kind := (Flags shr 8) and $7F;
  if id > 63 then Exit;
  if (Flags and $8000) <> 0 then
  begin
    // continued object: total size, then this part
    total := RdU32(R, 0);
    chunk := Copy(R, 4, Length(R) - 4);
    if (Objs[id].Want = 0) or (Objs[id].Kind <> kind) then
    begin
      Objs[id] := Default(TPlusObj);
      Objs[id].Kind := kind;
      Objs[id].Want := Min(total, Int64(256) * 1024 * 1024);
      Objs[id].Data := nil;
    end;
    if Length(Objs[id].Data) + Length(chunk) <= Objs[id].Want then
      Objs[id].Data := Concat(Objs[id].Data, chunk);
    if Length(Objs[id].Data) >= Objs[id].Want then FinishObject(id);
    Exit;
  end;
  if (Objs[id].Want > 0) and (Objs[id].Kind = kind) then
    Objs[id].Data := Concat(Objs[id].Data, R)                // last part of a continued object
  else
  begin
    Objs[id] := Default(TPlusObj);
    Objs[id].Kind := kind;
    Objs[id].Data := Copy(R);
  end;
  FinishObject(id);
end;

procedure TEmfPlus.FinishObject(Id: Integer);
var
  O: ^TPlusObj;
  n, i: Integer;
  u: UnicodeString;
begin
  O := @Objs[Id];
  O^.Want := 0;
  case O^.Kind of
    1: if not ParsePlusBrush(O^.Data, 0, O^.Br) then O^.Kind := 0;
    2: if not ParsePlusPen(O^.Data, 0, O^.Pen) then O^.Kind := 0;
    3: if not ParsePlusPath(O^.Data, 0, O^.Path) then O^.Kind := 0;
    5:
      begin
        if not ParsePlusImage(O^.Data, 0, O^.Img, O^.Meta) then
        begin
          O^.Kind := 0;
          G.PlusLossy := True;
        end;
        O^.Data := nil;
      end;
    6:
      begin
        O^.FontEm := RdF32(O^.Data, 4); O^.FontUnit := RdI32(O^.Data, 8); O^.FontStyle := RdI32(O^.Data, 12);
        n := EnsureRange(RdI32(O^.Data, 20), 0, 256);
        SetLength(u, n);
        for i := 1 to n do u[i] := WideChar(RdU16(O^.Data, 24 + (i - 1) * 2));
        O^.FontFace := UTF8Encode(u);
        if O^.FontFace = '' then O^.FontFace := 'Arial';
      end;
    7:
      begin
        O^.SfFlags := RdI32(O^.Data, 4); O^.SfAlign := RdI32(O^.Data, 12);
        O^.SfLineAlign := RdI32(O^.Data, 16); O^.SfLead := RdF32(O^.Data, 36);
      end;
  end;
end;

// ---- text ----

procedure TEmfPlus.SetFont(Id: Integer; out Em: Double);
var O: TPlusObj; pf: Double;
begin
  Em := 0;
  if (Id < 0) or (Id > 63) or (Objs[Id].Kind <> 6) then Exit;
  O := Objs[Id];
  // em size in world units
  pf := Max(1e-9, PageScale * UnitF(PageUnit, DpiY));
  if O.FontUnit = 0 then Em := O.FontEm
  else Em := O.FontEm * UnitF(O.FontUnit, DpiY) / pf;
  Em := EnsureRange(Em, 0, 1e6);
  G.DC.Font := Default(TFontRec);
  G.DC.Font.Face := O.FontFace;
  G.DC.Font.EmHeight := Em;
  G.DC.Font.Height := -Max(1, Round(Em));
  if (O.FontStyle and 1) <> 0 then G.DC.Font.Weight := 700 else G.DC.Font.Weight := 400;
  G.DC.Font.Italic := (O.FontStyle and 2) <> 0;
  G.DC.Font.Underline := (O.FontStyle and 4) <> 0;
  G.DC.Font.StrikeOut := (O.FontStyle and 8) <> 0;
end;

const
  // advance widths (1/1000 em) of characters 32..126: Helvetica / Arial and
  // Times / Times New Roman share these metrics
  SansWidths: array[32..126] of Word = (
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584);
  SerifWidths: array[32..126] of Word = (
    250, 333, 408, 500, 500, 833, 778, 180, 333, 333, 500, 564, 250, 333, 250, 278,
    500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 278, 278, 564, 564, 564, 444,
    921, 722, 667, 667, 722, 611, 556, 722, 722, 333, 389, 722, 611, 889, 722, 722,
    556, 722, 667, 556, 611, 722, 722, 944, 722, 722, 611, 333, 278, 333, 469, 500,
    333, 444, 500, 444, 500, 444, 333, 500, 500, 278, 278, 500, 278, 778, 500, 500,
    500, 500, 333, 389, 278, 500, 500, 722, 500, 500, 444, 480, 200, 480, 541);

// estimated width of a string in em (no font metrics are available here)
function TextWidthEm(const S: UnicodeString; const Face: string; Bold: Boolean): Double;
var i, c: Integer; serif, mono: Boolean; f: string;
begin
  f := LowerCase(Face);
  serif := (Pos('times', f) > 0) or (Pos('georgia', f) > 0) or (Pos('garamond', f) > 0) or
           (Pos('cambria', f) > 0) or (Pos('serif', f) > 0) and (Pos('sans', f) = 0);
  mono := (Pos('courier', f) > 0) or (Pos('mono', f) > 0) or (Pos('consol', f) > 0);
  Result := 0;
  for i := 1 to Length(S) do
  begin
    c := Ord(S[i]);
    if (c >= $DC00) and (c <= $DFFF) then Continue;           // second half of a pair
    if mono then Result := Result + 0.6
    else if (c >= 32) and (c <= 126) then
    begin
      if serif then Result := Result + SerifWidths[c] / 1000 else Result := Result + SansWidths[c] / 1000;
    end
    else Result := Result + 0.55;
  end;
  if Bold then Result := Result * 1.06;
  if Pos('black', f) > 0 then Result := Result * 1.25;
end;

// GDI+-style word wrap of one paragraph into lines no wider than Avail em
procedure WrapLine(const S: UnicodeString; Avail: Double; const Face: string; Bold: Boolean;
  Lines: TStrings; out Wrapped: Boolean);
var
  cur, word: UnicodeString;
  i, j: Integer;

  procedure Emit(const T: UnicodeString);
  var e: Integer;
  begin
    e := Length(T);
    while (e > 0) and (T[e] = ' ') do Dec(e);
    Lines.Add(UTF8Encode(Copy(T, 1, e)));
  end;

  function Fits(const T: UnicodeString): Boolean;
  var e: Integer;
  begin
    e := Length(T);
    while (e > 0) and (T[e] = ' ') do Dec(e);                 // trailing spaces do not count
    Result := TextWidthEm(Copy(T, 1, e), Face, Bold) <= Avail;
  end;

begin
  Wrapped := False;
  cur := '';
  i := 1;
  while i <= Length(S) do
  begin
    // next word with the spaces after it
    j := i;
    while (j <= Length(S)) and (S[j] <> ' ') do Inc(j);
    while (j <= Length(S)) and (S[j] = ' ') do Inc(j);
    word := Copy(S, i, j - i);
    i := j;
    if Fits(cur + word) then cur := cur + word
    else
    begin
      Wrapped := True;
      if cur <> '' then Emit(cur);
      cur := '';
      // a word wider than the box is broken between characters
      while not Fits(word) and (Length(word) > 1) do
      begin
        j := Length(word) - 1;
        while (j > 1) and not Fits(Copy(word, 1, j)) do Dec(j);
        Emit(Copy(word, 1, j));
        word := Copy(word, j + 1, MaxInt);
      end;
      cur := word;
    end;
  end;
  if (cur <> '') or (Lines.Count = 0) then Emit(cur);
end;

function LineSpacing(const Face: string): Double;
var f: string;
begin
  f := LowerCase(Face);
  if Pos('segoe', f) > 0 then Result := 1.33
  else if (Pos('tahoma', f) > 0) or (Pos('verdana', f) > 0) then Result := 1.21
  else if Pos('calibri', f) > 0 then Result := 1.22
  else if Pos('courier', f) > 0 then Result := 1.133
  else Result := 1.15;
end;

procedure TEmfPlus.DrawString;
var
  Br: TPlusBrush;
  em, x, y, w, h, lh, lead, tx, ty: Double;
  fmt, n, i, align, lalign: Integer;
  u: UnicodeString;
  s: string;
  lines, paras: TStringList;
  c: Cardinal;
  nowrap, noclip, wrapped, any: Boolean;
  Sv: TClipVal;
begin
  if not GetBrush(RdU32(R, 0), (Flags and $8000) <> 0, Br) then Exit;
  c := PlusAvgColor(Br);
  if (c shr 24) = 0 then Exit;
  Apply;
  SetFont(Flags and $FF, em);
  if em <= 0 then Exit;
  fmt := RdI32(R, 4);
  n := RdI32(R, 8);
  if (n <= 0) or (28 + Int64(n) * 2 > Length(R)) then Exit;
  x := RdF32(R, 12); y := RdF32(R, 16); w := RdF32(R, 20); h := RdF32(R, 24);
  align := 0; lalign := 0; lead := 1 / 6; nowrap := False; noclip := False;
  if (fmt >= 0) and (fmt <= 63) and (Objs[fmt].Kind = 7) then
  begin
    align := Objs[fmt].SfAlign; lalign := Objs[fmt].SfLineAlign;
    lead := EnsureRange(Objs[fmt].SfLead, 0, 10);
    nowrap := (Objs[fmt].SfFlags and $1000) <> 0;
    noclip := (Objs[fmt].SfFlags and $4000) <> 0;
  end;
  SetLength(u, n);
  for i := 1 to n do u[i] := WideChar(RdU16(R, 28 + (i - 1) * 2));
  s := StringReplace(UTF8Encode(u), #13, '', [rfReplaceAll]);
  G.DC.TextColor := ArgbToRef(c);
  G.DC.TextTransp := 255 - Integer(c shr 24);
  lh := em * LineSpacing(G.DC.Font.Face);
  lines := TStringList.Create;
  paras := TStringList.Create;
  Sv := CurClip;
  try
    paras.Text := s;
    if paras.Count = 0 then Exit;
    // GDI+ wraps lines longer than the layout box; widths are estimated (see
    // TextWidthEm), so a dual file prefers its exact EMF version then
    any := False;
    for i := 0 to paras.Count - 1 do
      if (w > 0) and not nowrap then
      begin
        WrapLine(UTF8Decode(paras[i]), w / em - 2 * lead, G.DC.Font.Face, G.DC.Font.Weight >= 600, lines, wrapped);
        any := any or wrapped;
      end
      else lines.Add(paras[i]);
    if any then G.PlusLossy := True;
    // the layout box clips, unless the format says otherwise
    if (w > 0) and (h > 0) and not noclip then SetClip(Combine(Sv, RectClip(x, y, w, h), 1));
    case align of
      1: begin tx := x + w / 2; G.DC.TextAlign := 6; end;
      2: begin tx := x + w - lead * em; G.DC.TextAlign := 2; end;
    else begin tx := x + lead * em; G.DC.TextAlign := 0; end;
    end;
    case lalign of
      1: ty := y + (h - lines.Count * lh) / 2;
      2: ty := y + h - lines.Count * lh;
    else ty := y;
    end;
    Apply;
    for i := 0 to lines.Count - 1 do
      if lines[i] <> '' then G.Text(tx, ty + i * lh, lines[i], [], False);
  finally
    if (w > 0) and (h > 0) and not noclip then SetClip(Sv);
    lines.Free;
    paras.Free;
  end;
end;

procedure TEmfPlus.DrawDriverString;
var
  Br: TPlusBrush;
  em: Double;
  opts, n, i, j: Integer;
  u: UnicodeString;
  px, py, dx, merged: array of Double;
  Save: TXf;
  sameY: Boolean;
  s: string;
  c: Cardinal;
begin
  if not GetBrush(RdU32(R, 0), (Flags and $8000) <> 0, Br) then Exit;
  c := PlusAvgColor(Br);
  if (c shr 24) = 0 then Exit;
  opts := RdI32(R, 4);
  n := RdI32(R, 12);
  if (opts and 1) = 0 then
  begin
    G.PlusLossy := True;                                 // glyph indices: no character codes
    Exit;
  end;
  if (n <= 0) or (16 + Int64(n) * 10 > Length(R)) then Exit;
  Save := World;
  if RdI32(R, 8) <> 0 then World := XfMul(World, RdXf(R, 16 + n * 10));
  try
    Apply;
    SetFont(Flags and $FF, em);
    if em <= 0 then Exit;
    G.DC.TextColor := ArgbToRef(c);
    G.DC.TextTransp := 255 - Integer(c shr 24);
    G.DC.TextAlign := 24;                                // baseline
    SetLength(u, n); SetLength(px, n); SetLength(py, n);
    sameY := True;
    for i := 0 to n - 1 do
    begin
      u[i + 1] := WideChar(RdU16(R, 16 + i * 2));
      px[i] := RdF32(R, 16 + n * 2 + i * 8); py[i] := RdF32(R, 20 + n * 2 + i * 8);
      if Abs(py[i] - py[0]) > 0.01 then sameY := False;
    end;
    s := UTF8Encode(u);
    if (opts and 4) <> 0 then G.Text(px[0], py[0], s, [], False)
    else if sameY then
    begin
      SetLength(dx, n);
      for i := 0 to n - 1 do
        if i < n - 1 then dx[i] := px[i + 1] - px[i] else dx[i] := 0;
      SetLength(merged, 0);
      j := 1;
      while j <= n do
      begin
        SetLength(merged, Length(merged) + 1);
        merged[High(merged)] := dx[j - 1];
        if (Ord(u[j]) >= $D800) and (Ord(u[j]) <= $DBFF) and (j < n) then
        begin
          merged[High(merged)] := merged[High(merged)] + dx[j];
          Inc(j);
        end;
        Inc(j);
      end;
      if Utf8CharCountOk(s, Length(merged)) then G.Text(px[0], py[0], s, merged, True)
      else G.Text(px[0], py[0], s, [], False);
    end
    else
      for i := 0 to n - 1 do
        if (Ord(u[i + 1]) < $D800) or (Ord(u[i + 1]) > $DFFF) then
          G.Text(px[i], py[i], UTF8Encode(UnicodeString(u[i + 1])), [], False);
  finally
    World := Save;
  end;
end;

// ---- images ----

procedure TEmfPlus.PlayNested(const Meta: TBytes; x, y, w, h: Double);
var
  SDC: TDC;
  SStack: TDCArr;
  SObjs: TGdiObjArr;
  sOSX, sOSY, sOOX, sOOY, sPX, sPY: Double;
  ox0, oy0, ox1, oy1, fl, ft, fr, fb, devW, devH, mmW, mmH: Double;
  Info: TWmfInfo;
begin
  if NestDepth >= MAX_NEST then Exit;
  Apply;
  G.Map(x, y, ox0, oy0); G.Map(x + w, y + h, ox1, oy1);
  if G.FMeasure then Exit;
  SDC := G.DC; SStack := G.Stack; SObjs := G.Objects;
  sOSX := G.OutScaleX; sOSY := G.OutScaleY; sOOX := G.OutOffX; sOOY := G.OutOffY;
  sPX := G.DevPxPerMmX; sPY := G.DevPxPerMmY;
  Inc(NestDepth);
  try
    G.Stack := nil; G.Objects := nil;
    G.ResetDC;
    G.DC.ClipOn := SDC.ClipOn; G.DC.ClipRects := SDC.ClipRects; G.DC.ClipPaths := SDC.ClipPaths;
    G.DC.ClipId := SDC.ClipId;
    if (Length(Meta) >= 88) and (RdU32(Meta, 0) = 1) and (RdU32(Meta, 40) = $464D4520) then
    begin
      devW := RdI32(Meta, 72); devH := RdI32(Meta, 76); mmW := RdI32(Meta, 80); mmH := RdI32(Meta, 84);
      if (devW > 0) and (mmW > 0) then G.DevPxPerMmX := devW / mmW else G.DevPxPerMmX := 96 / 25.4;
      if (devH > 0) and (mmH > 0) then G.DevPxPerMmY := devH / mmH else G.DevPxPerMmY := 96 / 25.4;
      fl := RdI32(Meta, 24) / 100 * G.DevPxPerMmX; ft := RdI32(Meta, 28) / 100 * G.DevPxPerMmY;
      fr := RdI32(Meta, 32) / 100 * G.DevPxPerMmX; fb := RdI32(Meta, 36) / 100 * G.DevPxPerMmY;
      if (fr - fl < 1) or (fb - ft < 1) then
      begin
        fl := RdI32(Meta, 8); ft := RdI32(Meta, 12); fr := RdI32(Meta, 16) + 1; fb := RdI32(Meta, 20) + 1;
      end;
      if (fr - fl < 1) or (fb - ft < 1) then Exit;
      G.OutScaleX := (ox1 - ox0) / (fr - fl); G.OutScaleY := (oy1 - oy0) / (fb - ft);
      G.OutOffX := ox0 - fl * G.OutScaleX; G.OutOffY := oy0 - ft * G.OutScaleY;
      PlayEmf(G, Meta);
    end
    else if WmfHeader(Meta, Info) and Info.Placeable and (Info.R <> Info.L) and (Info.B <> Info.T) then
    begin
      G.OutScaleX := 1; G.OutScaleY := 1; G.OutOffX := 0; G.OutOffY := 0;
      G.DC.MapMode := 8;
      G.DC.WinOrgX := Info.L; G.DC.WinOrgY := Info.T;
      G.DC.WinExtX := Info.R - Info.L; G.DC.WinExtY := Info.B - Info.T;
      G.DC.VpOrgX := ox0; G.DC.VpOrgY := oy0; G.DC.VpExtX := ox1 - ox0; G.DC.VpExtY := oy1 - oy0;
      PlayWmf(G, Meta, Info);
    end
    else G.PlusLossy := True;
  finally
    Dec(NestDepth);
    G.DC := SDC; G.Stack := SStack; G.Objects := SObjs;
    G.OutScaleX := sOSX; G.OutScaleY := sOSY; G.OutOffX := sOOX; G.OutOffY := sOOY;
    G.DevPxPerMmX := sPX; G.DevPxPerMmY := sPY;
    G.NewClip;
  end;
end;

procedure TEmfPlus.DrawImage(Points: Boolean);
var
  id: Integer;
  sx, sy, sw, sh, x, y, w, h: Double;
  P: TPlusPts;
  T, Save: TXf;
begin
  id := Flags and $FF;
  if (id > 63) or (Objs[id].Kind <> 5) then Exit;
  sx := EnsureRange(RdF32(R, 8), -1e8, 1e8); sy := EnsureRange(RdF32(R, 12), -1e8, 1e8);
  sw := EnsureRange(RdF32(R, 16), -1e8, 1e8); sh := EnsureRange(RdF32(R, 20), -1e8, 1e8);
  Save := World;
  try
    if Points then
    begin
      if (RdI32(R, 24) <> 3) or not Pts(28, 3, P) then Exit;
      // unit square -> parallelogram (upper-left, upper-right, lower-left)
      T.A := P[1].X - P[0].X; T.B := P[1].Y - P[0].Y;
      T.C := P[2].X - P[0].X; T.D := P[2].Y - P[0].Y;
      T.E := P[0].X; T.F := P[0].Y;
      World := XfMul(World, T);
      x := 0; y := 0; w := 1; h := 1;
    end
    else RectAt(24, x, y, w, h);
    if Length(Objs[id].Meta) > 0 then
    begin
      PlayNested(Objs[id].Meta, x, y, w, h);
      Exit;
    end;
    if Length(Objs[id].Img.Px) = 0 then Exit;
    Apply;
    G.Bitmap(Objs[id].Img, x, y, w, h, Round(sx), Round(sy), Max(1, Round(sw)), Max(1, Round(sh)), $00CC0020);
  finally
    World := Save;
  end;
end;

// ---- records ----

procedure TEmfPlus.Rec(T: Integer);
var
  n, k: Integer;
  x, y, w, h, a0, sw, ang: Double;
  P: TPlusPts;
  M: TXf;
  V, Sv: TClipVal;
  append: Boolean;
  oid: Integer;
begin
  oid := Flags and $FF;
  if oid > 63 then oid := 63;
  append := (Flags and $2000) <> 0;
  case T of
    $4001:                                                        // header
      begin
        Video := (RdU32(R, 4) and 1) <> 0;
        if RdI32(R, 8) > 0 then DpiX := RdI32(R, 8);
        if RdI32(R, 12) > 0 then DpiY := RdI32(R, 12);
      end;
    $4008: ObjectRecord;
    $4009:                                                        // clear
      if (RdU32(R, 0) shr 24) > 0 then
      begin
        G.DC.Brush := Default(TBrushRec);
        G.DC.Brush.Color := ArgbToRef(RdU32(R, 0));
        G.DC.Brush.Transp := 255 - Integer(RdU32(R, 0) shr 24);
        G.EmitShape(RectsD(G, InfiniteClip), True, False);
      end;
    $400A:                                                        // fill rects
      begin
        n := RdI32(R, 4); k := 8;
        if (n > 0) and (n <= Length(R) div 8) then
          while n > 0 do
          begin
            k := k + RectAt(k, x, y, w, h);
            if k > Length(R) then Break;
            Apply;
            FillWith(RectD(x, y, w, h), RdU32(R, 0), False);
            Dec(n);
          end;
      end;
    $400B:                                                        // draw rects
      begin
        n := RdI32(R, 0); k := 4;
        if (n > 0) and (n <= Length(R) div 8) then
          while n > 0 do
          begin
            k := k + RectAt(k, x, y, w, h);
            if k > Length(R) then Break;
            Apply;
            StrokeD(RectD(x, y, w, h), Flags and $FF);
            Dec(n);
          end;
      end;
    $400C:                                                        // fill polygon
      if Pts(8, RdI32(R, 4), P) then begin Apply; FillWith(PolyD(P, True), RdU32(R, 0), False); end;
    $400D:                                                        // draw lines
      if Pts(4, RdI32(R, 0), P) then begin Apply; StrokeD(PolyD(P, append), Flags and $FF); end;
    $400E:                                                        // fill ellipse
      begin
        RectAt(4, x, y, w, h); Apply;
        FillWith(EllipseD(x, y, w, h), RdU32(R, 0), False);
      end;
    $400F:
      begin
        RectAt(0, x, y, w, h); Apply;
        StrokeD(EllipseD(x, y, w, h), Flags and $FF);
      end;
    $4010:                                                        // fill pie
      begin
        a0 := RdF32(R, 4); sw := RdF32(R, 8); RectAt(12, x, y, w, h); Apply;
        FillWith(ArcD(x, y, w, h, a0, sw, True), RdU32(R, 0), False);
      end;
    $4011, $4012:                                                 // draw pie / arc
      begin
        a0 := RdF32(R, 0); sw := RdF32(R, 4); RectAt(8, x, y, w, h); Apply;
        StrokeD(ArcD(x, y, w, h, a0, sw, T = $4011), Flags and $FF);
      end;
    $4013:                                                        // fill region
      if RegionClip(oid, V) then
      begin
        Sv := CurClip;
        SetClip(Combine(Sv, V, 1));
        FillWith(RectsD(G, InfiniteClip), RdU32(R, 0), False);
        SetClip(Sv);
      end;
    $4014:                                                        // fill path
      if Objs[oid].Kind = 3 then
      begin
        Apply;
        FillWith(PathD(Objs[oid].Path), RdU32(R, 0), Objs[oid].Path.Winding);
      end;
    $4015:                                                        // draw path
      if Objs[oid].Kind = 3 then
      begin
        Apply;
        StrokeD(PathD(Objs[oid].Path), RdI32(R, 0));
      end;
    $4016:                                                        // fill closed curve
      if Pts(12, RdI32(R, 8), P) then
      begin
        Apply;
        FillWith(CurveD(P, RdF32(R, 4), True, 0, 0), RdU32(R, 0), append);
      end;
    $4017:
      if Pts(8, RdI32(R, 4), P) then
      begin
        Apply;
        StrokeD(CurveD(P, RdF32(R, 0), True, 0, 0), Flags and $FF);
      end;
    $4018:                                                        // draw curve
      if Pts(16, RdI32(R, 12), P) then
      begin
        Apply;
        StrokeD(CurveD(P, RdF32(R, 0), False, RdI32(R, 4), RdI32(R, 8)), Flags and $FF);
      end;
    $4019:
      if Pts(4, RdI32(R, 0), P) then begin Apply; StrokeD(BezD(P), Flags and $FF); end;
    $401A: DrawImage(False);
    $401B: DrawImage(True);
    $401C: DrawString;
    $4036: DrawDriverString;
    $4025: PushState(RdU32(R, 0));                                // save
    $4026, $4029: PopState(RdU32(R, 0));                          // restore / end container
    $4027:                                                        // begin container
      begin
        PushState(RdU32(R, 32));
        x := RdF32(R, 16); y := RdF32(R, 20); w := RdF32(R, 24); h := RdF32(R, 28);
        M := Ident;
        if (Abs(w) > 1e-9) and (Abs(h) > 1e-9) then
        begin
          M.A := RdF32(R, 8) / w; M.D := RdF32(R, 12) / h;
          M.E := RdF32(R, 0) - x * M.A; M.F := RdF32(R, 4) - y * M.D;
        end;
        World := XfMul(World, M);
        Base := World; BaseClip := CurClip;
      end;
    $4028:
      begin
        PushState(RdU32(R, 0));
        Base := World; BaseClip := CurClip;
      end;
    $402A: World := XfMul(Base, RdXf(R, 0));
    $402B: World := Base;
    $402C, $402D, $402E, $402F:
      begin
        M := Ident;
        case T of
          $402C: M := RdXf(R, 0);
          $402D: begin M.E := RdF32(R, 0); M.F := RdF32(R, 4); end;
          $402E: begin M.A := RdF32(R, 0); M.D := RdF32(R, 4); end;
          $402F:
            begin
              ang := RdF32(R, 0);
              if Abs(ang) > 1e9 then ang := 0;
              ang := DegToRad(ang - 360 * Floor(ang / 360));
              M.A := Cos(ang); M.B := Sin(ang); M.C := -Sin(ang); M.D := Cos(ang);
            end;
        end;
        if append then World := XfMul(M, World) else World := XfMul(World, M);
      end;
    $4030:                                                        // page transform
      begin
        PageUnit := Flags and $FF;
        PageScale := RdF32(R, 0);
        if PageScale <= 0 then PageScale := 1;
      end;
    $4031: SetClip(BaseClip);                                     // reset clip
    $4032: ApplyClip(RectClip(RdF32(R, 0), RdF32(R, 4), RdF32(R, 8), RdF32(R, 12)), (Flags shr 8) and $F);
    $4033:
      if Objs[oid].Kind = 3 then
        ApplyClip(PathClip(Objs[oid].Path), (Flags shr 8) and $F);
    $4034:
      if RegionClip(Flags and $FF, V) then ApplyClip(V, (Flags shr 8) and $F);
    $4035:                                                        // offset clip
      begin
        Apply;
        G.ClipOffset(RdF32(R, 0), RdF32(R, 4));
      end;
  end;
end;

// EMR_COMMENT at p: plays the EMF+ records it carries. After GetDC the
// following EMF records are played with the EMF's own DC state.
procedure TEmfPlus.Comment(const D: TBytes; p: NativeInt; Size: Cardinal);
var
  q, e: NativeInt;
  t, rs, ds: Cardinal;
  last: Integer;
begin
  if (Size < 16) or (RdU32(D, p + 12) <> EMFPLUS_SIG) then Exit;
  e := p + 12 + NativeInt(RdU32(D, p + 8));
  if e > p + NativeInt(Size) then e := p + NativeInt(Size);
  if GdiOn then
  begin
    EmfDC := G.DC; G.DC := PlusDC;
    G.NewClip;
    GdiOn := False;
  end;
  q := p + 16;
  last := 0;
  while q + 12 <= e do
  begin
    t := RdU16(D, q); Flags := RdU16(D, q + 2);
    rs := RdU32(D, q + 4); ds := RdU32(D, q + 8);
    if (rs < 12) or (q + NativeInt(rs) > e) then Break;
    if ds > rs - 12 then ds := rs - 12;
    R := Copy(D, q + 12, ds);
    last := t;
    if t = $4002 then Break;                                      // EOF
    Rec(t);
    q := q + NativeInt(rs);
  end;
  if last = $4004 then
  begin
    // GetDC: EMF records follow, drawn with the current EMF+ clip
    PlusDC := G.DC;
    G.DC := EmfDC;
    G.DC.ClipOn := PlusDC.ClipOn; G.DC.ClipRects := PlusDC.ClipRects; G.DC.ClipPaths := PlusDC.ClipPaths;
    G.NewClip;
    GdiOn := True;
  end;
end;

// 0 = no EMF+, 1 = EMF+ only, 2 = dual (EMF+ with an EMF fallback)
function EmfPlusKind(const D: TBytes): Integer;
var p: NativeInt; i: Integer;
begin
  Result := 0;
  p := RdU32(D, 4);                                               // after the header
  for i := 1 to 16 do
  begin
    if (p < 8) or (p + 8 > Length(D)) then Exit;
    if (RdU32(D, p) = 70) and (RdU32(D, p + 4) >= 28) and (RdU32(D, p + 12) = EMFPLUS_SIG) and
       (RdU16(D, p + 16) = $4001) then
    begin
      if (RdU16(D, p + 18) and 1) <> 0 then Result := 2 else Result := 1;
      Exit;
    end;
    if RdU32(D, p + 4) < 8 then Exit;
    p := p + NativeInt(RdU32(D, p + 4));
  end;
end;

procedure PlayEmf(G: TGdi; const D: TBytes);
var
  p, e, q, r: NativeInt;
  typ: Cardinal;
  size: Cardinal;
  i, n, np, cnt, ih, opts, nChars, k: Integer;
  pts: array of Double;
  counts: array of Integer;
  dxs: array of Double;
  O: TGdiObj;
  X: TXf;
  u: UnicodeString;
  s: string;
  bytes: array of Byte;
  img: TRGBAImage;
  rop: Cardinal;
  x0, y0, x1, y1: Double;
  c0, c1: Cardinal;
  crects: TClipRects;
  plus: TEmfPlus;
  pk: Integer;

  function I32(o: Integer): Integer; begin Result := RdI32(D, p + o); end;
  function U32(o: Integer): Cardinal; begin Result := RdU32(D, p + o); end;

  procedure ReadPoints(o, count: Integer; Small: Boolean);
  var j: Integer;
  begin
    SetLength(pts, count * 2);
    for j := 0 to count - 1 do
      if Small then
      begin
        pts[j * 2] := RdI16(D, p + o + j * 4); pts[j * 2 + 1] := RdI16(D, p + o + j * 4 + 2);
      end
      else
      begin
        pts[j * 2] := RdI32(D, p + o + j * 8); pts[j * 2 + 1] := RdI32(D, p + o + j * 8 + 4);
      end;
  end;

  function SafeCount(c, bytesEach, o: Integer): Integer;
  begin
    Result := c;
    if (c < 0) or (Int64(c) * bytesEach + o > size) then Result := 0;
  end;

  // EMRTEXT at offset o: reference point, string, spacing
  procedure DoText(o: Integer; Wide: Boolean);
  var j, offStr, offDx: Integer; rx, ry: Double; merged: array of Double;
  begin
    rx := I32(o); ry := I32(o + 4);
    nChars := I32(o + 8); offStr := I32(o + 12); opts := I32(o + 16);
    offDx := I32(o + 36);
    if (opts and 2) <> 0 then                                   // ETO_OPAQUE
      G.FillRectColor(I32(o + 20), I32(o + 24), I32(o + 28), I32(o + 32), G.DC.BkColor);
    if (nChars <= 0) or (nChars > 65536) or (offStr <= 0) then Exit;
    if Wide then
    begin
      if offStr + nChars * 2 > Integer(size) then Exit;
      SetLength(u, nChars);
      for j := 0 to nChars - 1 do u[j + 1] := WideChar(RdU16(D, p + offStr + j * 2));
      s := UTF8Encode(u);
    end
    else
    begin
      if offStr + nChars > Integer(size) then Exit;
      SetLength(bytes, nChars);
      for j := 0 to nChars - 1 do bytes[j] := RdU8(D, p + offStr + j);
      s := AnsiToUtf8(bytes, nChars, G.DC.Font.Charset);
    end;
    SetLength(dxs, 0);
    if (offDx > 0) and (offDx + nChars * 4 <= Integer(size)) then
    begin
      SetLength(dxs, nChars);
      for j := 0 to nChars - 1 do
        if (opts and $2000) <> 0 then dxs[j] := I32(offDx + j * 8)   // ETO_PDY: dx,dy pairs
        else dxs[j] := I32(offDx + j * 4);
      // one advance per UTF-16 unit: a surrogate pair is one character
      if Wide then
      begin
        SetLength(merged, 0);
        j := 1;
        while j <= nChars do
        begin
          SetLength(merged, Length(merged) + 1);
          merged[High(merged)] := dxs[j - 1];
          if (Ord(u[j]) >= $D800) and (Ord(u[j]) <= $DBFF) and (j < nChars) then
          begin
            merged[High(merged)] := merged[High(merged)] + dxs[j];
            Inc(j);
          end;
          Inc(j);
        end;
        dxs := merged;
      end;
    end;
    if Utf8CharCountOk(s, Length(dxs)) then G.Text(rx, ry, s, dxs, Length(dxs) > 0)
    else G.Text(rx, ry, s, [], False);
  end;

  // bitmap records share one layout from xDest on
  function LoadDib(offBmi, cbBmi, offBits, cbBits, usage: Integer): Boolean;
  begin
    Result := (offBmi > 0) and (cbBmi > 0) and (offBmi + cbBmi <= Integer(size)) and
              (offBits > 0) and (offBits + cbBits <= Integer(size)) and
              DecodeDib(D, p + offBmi, cbBmi, p + offBits, cbBits, usage, img);
  end;

begin
  plus := nil;
  pk := EmfPlusKind(D);
  if (pk = 1) or ((pk = 2) and WmfUseEmfPlus and not G.NoPlus) then plus := TEmfPlus.Create(G);
  try
  e := Length(D);
  p := 0;
  while p + 8 <= e do
  begin
    typ := RdU32(D, p);
    size := RdU32(D, p + 4);
    if (size < 8) or (p + NativeInt(size) > e) then Break;
    if plus <> nil then
    begin
      // EMF+ playback: EMF records count only after an EMF+ GetDC
      if typ = 14 then Break;
      if typ = 70 then plus.Comment(D, p, size);
      if (typ = 70) or not plus.GdiOn then
      begin
        p := p + NativeInt(size);
        Continue;
      end;
    end;
    case typ of
      14: Break;                                                 // EOF
      9:  begin G.DC.WinExtX := I32(8); G.DC.WinExtY := I32(12); end;
      10: begin G.DC.WinOrgX := I32(8); G.DC.WinOrgY := I32(12); end;
      11: begin G.DC.VpExtX := I32(8); G.DC.VpExtY := I32(12); end;
      12: begin G.DC.VpOrgX := I32(8); G.DC.VpOrgY := I32(12); end;
      17: G.DC.MapMode := I32(8);
      31: if (I32(12) <> 0) and (I32(20) <> 0) then                // SCALEVIEWPORTEXTEX
          begin
            G.DC.VpExtX := G.DC.VpExtX * I32(8) / I32(12);
            G.DC.VpExtY := G.DC.VpExtY * I32(16) / I32(20);
          end;
      32: if (I32(12) <> 0) and (I32(20) <> 0) then                // SCALEWINDOWEXTEX
          begin
            G.DC.WinExtX := G.DC.WinExtX * I32(8) / I32(12);
            G.DC.WinExtY := G.DC.WinExtY * I32(16) / I32(20);
          end;
      33: G.SaveDC;
      34: G.RestoreDC(I32(8));
      35, 36:                                                    // world transform
          begin
            X.A := RdF32(D, p + 8); X.B := RdF32(D, p + 12);
            X.C := RdF32(D, p + 16); X.D := RdF32(D, p + 20);
            X.E := RdF32(D, p + 24); X.F := RdF32(D, p + 28);
            if typ = 35 then G.DC.World := X
            else
              case I32(32) of
                1: G.DC.World := Ident;
                2: G.DC.World := XfMul(G.DC.World, X);          // left-multiply: X first
                3: G.DC.World := XfMul(X, G.DC.World);
                4: G.DC.World := X;
              end;
          end;
      18: G.DC.BkMode := I32(8);
      19: G.DC.PolyFill := I32(8);
      22: G.DC.TextAlign := I32(8);
      24: G.DC.TextColor := U32(8) and $FFFFFF;
      25: G.DC.BkColor := U32(8) and $FFFFFF;
      57: G.DC.ArcDir := I32(8);
      37: begin                                                  // SELECTOBJECT
            G.SelectAny(I32(8));
          end;
      40: G.DeleteObj(I32(8));
      38: begin                                                  // CREATEPEN
            O := Default(TGdiObj); O.Kind := okPen;
            O.Pen.Style := I32(12); O.Pen.Width := I32(16); O.Pen.Color := U32(24) and $FFFFFF;
            O.Pen.Cosmetic := O.Pen.Width <= 1;                  // 0/1 = one device pixel
            if (O.Pen.Width > 1) and ((O.Pen.Style and $F) in [1..4]) then
              O.Pen.Style := O.Pen.Style and not $F;             // CreatePen: wide = solid
            G.SetObj(I32(8), O);
          end;
      95: begin                                                  // EXTCREATEPEN
            O := Default(TGdiObj); O.Kind := okPen;
            O.Pen.Style := I32(28) and $FF;
            O.Pen.Width := I32(32);
            O.Pen.Cosmetic := ((Cardinal(I32(28)) and $F0000) = 0) or (O.Pen.Width <= 0);
            O.Pen.Color := U32(40) and $FFFFFF;
            if I32(36) = 1 then O.Pen.Style := 5;                // BS_NULL brush: no line
            n := I32(48);                                        // PS_USERSTYLE entries
            if (n > 0) and (n <= 64) and (52 + n * 4 <= Integer(size)) then
            begin
              SetLength(O.Pen.Dash, n);
              for i := 0 to n - 1 do O.Pen.Dash[i] := U32(52 + i * 4);
            end;
            G.SetObj(I32(8), O);
          end;
      39: begin                                                  // CREATEBRUSHINDIRECT
            O := Default(TGdiObj); O.Kind := okBrush;
            O.Brush.Style := I32(12); O.Brush.Color := U32(16) and $FFFFFF; O.Brush.Hatch := I32(20);
            if O.Brush.Style > 3 then O.Brush.Style := 3;
            G.SetObj(I32(8), O);
          end;
      93, 94:                                                    // mono / DIB pattern brush
          begin
            O := Default(TGdiObj); O.Kind := okBrush; O.Brush.Style := 0; O.Brush.Color := $808080;
            if LoadDib(I32(16), I32(20), I32(24), I32(28), I32(12)) then
            begin
              O.Brush.Color := AverageColor(img);
              O.Brush.Style := 3; O.Brush.Pat := img;
              O.Brush.Mono := typ = 93;                          // CREATEMONOBRUSH
            end;
            G.SetObj(I32(8), O);
          end;
      82: begin                                                  // EXTCREATEFONTINDIRECTW
            O := Default(TGdiObj); O.Kind := okFont;
            O.Font.Height := I32(12); O.Font.Escapement := I32(20); O.Font.Weight := I32(28);
            O.Font.Italic := RdU8(D, p + 32) <> 0; O.Font.Underline := RdU8(D, p + 33) <> 0;
            O.Font.StrikeOut := RdU8(D, p + 34) <> 0; O.Font.Charset := RdU8(D, p + 35);
            u := '';
            for i := 0 to 31 do
            begin
              k := RdU16(D, p + 40 + i * 2);
              if k = 0 then Break;
              u := u + WideChar(k);
            end;
            s := UTF8Encode(u);
            if s = '' then s := 'Arial';
            O.Font.Face := s;
            G.SetObj(I32(8), O);
          end;
      49, 99, 122: begin O := Default(TGdiObj); O.Kind := okOther; G.SetObj(I32(8), O); end;
      27: G.MoveTo(I32(8), I32(12));
      54: G.LineTo(I32(8), I32(12));
      2, 3, 4, 5, 6, 85, 86, 87, 88, 89:                         // poly shapes
          begin
            if typ >= 85 then begin n := SafeCount(I32(24), 4, 28); ReadPoints(28, n, True); end
            else begin n := SafeCount(I32(24), 8, 28); ReadPoints(28, n, False); end;
            case typ of
              2, 85: G.PolyBezier(pts, n, False);
              3, 86: G.Poly(pts, n, True, True);
              4, 87: G.Poly(pts, n, False, True);
              5, 88: G.PolyBezier(pts, n, True);
              6, 89: G.Poly(pts, n, False, False);
            end;
          end;
      7, 8, 90, 91:                                              // POLYPOLY*
          begin
            np := I32(24);
            if (np <= 0) or (32 + Int64(np) * 4 > size) then begin p := p + NativeInt(size); Continue; end;
            SetLength(counts, np); cnt := 0;
            for i := 0 to np - 1 do begin counts[i] := I32(32 + i * 4); Inc(cnt, Max(0, counts[i])); end;
            if typ >= 90 then
            begin
              cnt := SafeCount(cnt, 4, 32 + np * 4); ReadPoints(32 + np * 4, cnt, True);
            end
            else
            begin
              cnt := SafeCount(cnt, 8, 32 + np * 4); ReadPoints(32 + np * 4, cnt, False);
            end;
            G.PolyPoly(pts, counts, (typ = 8) or (typ = 91));
          end;
      56, 92:                                                    // POLYDRAW
          begin
            if typ = 92 then begin n := SafeCount(I32(24), 5, 28); ReadPoints(28, n, True); q := 28 + n * 4; end
            else begin n := SafeCount(I32(24), 9, 28); ReadPoints(28, n, False); q := 28 + n * 8; end;
            i := 0;
            while i < n do
            begin
              k := RdU8(D, p + q + i);
              case k and 6 of
                6: G.MoveTo(pts[i * 2], pts[i * 2 + 1]);
                2: G.LineTo(pts[i * 2], pts[i * 2 + 1]);
                4: if i + 2 < n then
                   begin
                     G.PolyBezier([pts[i * 2], pts[i * 2 + 1], pts[i * 2 + 2], pts[i * 2 + 3],
                                   pts[i * 2 + 4], pts[i * 2 + 5]], 3, True);
                     Inc(i, 2);
                   end;
              end;
              if (k and 1) <> 0 then G.CloseFigure;
              Inc(i);
            end;
          end;
      42: G.Ellipse(I32(8), I32(12), I32(16), I32(20));
      43: G.Rectangle(I32(8), I32(12), I32(16), I32(20));
      44: G.RoundRect(I32(8), I32(12), I32(16), I32(20), I32(24), I32(28));
      45, 46, 47, 55:
          begin
            case typ of 45: k := 0; 46: k := 1; 47: k := 2; else k := 3; end;
            G.ArcShape(I32(8), I32(12), I32(16), I32(20), I32(24), I32(28), I32(32), I32(36), k);
          end;
      41: G.AngleArc(I32(8), I32(12), U32(16), RdF32(D, p + 20), RdF32(D, p + 24));
      15: G.SetPixel(I32(8), I32(12), U32(16) and $FFFFFF);
      26: G.ClipOffset(I32(8), I32(12));                        // OFFSETCLIPRGN
      29: G.ClipRectLogical(I32(8), I32(12), I32(16), I32(20), True);   // EXCLUDECLIPRECT
      30: G.ClipRectLogical(I32(8), I32(12), I32(16), I32(20), False);  // INTERSECTCLIPRECT
      67: G.ClipSelectPath(I32(8));                             // SELECTCLIPPATH
      75: begin                                                 // EXTSELECTCLIPRGN
            k := I32(12);
            if I32(8) = 0 then
            begin
              if k = RGN_COPY then G.ClipResetAll;               // default clip
            end
            else
            begin
              n := I32(16 + 8);
              if (n < 0) or (48 + Int64(n) * 16 > size) then n := 0;
              SetLength(crects, n);
              for i := 0 to n - 1 do
              begin
                r := 48 + i * 16;                                 // device pixels
                crects[i].L := I32(r) * G.OutScaleX + G.OutOffX;
                crects[i].T := I32(r + 4) * G.OutScaleY + G.OutOffY;
                crects[i].R := I32(r + 8) * G.OutScaleX + G.OutOffX;
                crects[i].B := I32(r + 12) * G.OutScaleY + G.OutOffY;
              end;
              G.ClipRectsOutput(crects, k);
            end;
          end;
      59: G.BeginPath;
      60: G.EndPath;
      61: G.CloseFigure;
      62: G.DrawPath(True, False);
      63: G.DrawPath(True, True);
      64: G.DrawPath(False, True);
      68: G.AbortPath;
      83: DoText(36, False);                                     // EXTTEXTOUTA
      84: DoText(36, True);                                      // EXTTEXTOUTW
      96, 97:                                                    // POLYTEXTOUTA/W
          for i := 0 to I32(36) - 1 do
          begin
            if 40 + (i + 1) * 40 > Integer(size) then Break;
            DoText(40 + i * 40, typ = 97);
          end;
      71, 74:                                                    // FILLRGN / PAINTRGN
          begin
            if typ = 71 then begin q := 32; G.SaveDC; G.SelectAny(I32(28)); end else q := 28;
            n := I32(q + 8);
            for i := 0 to n - 1 do
            begin
              r := q + 32 + i * 16;
              if r + 16 > Integer(size) then Break;
              G.FillRectBrush(I32(r), I32(r + 4), I32(r + 8), I32(r + 12));
            end;
            if typ = 71 then G.RestoreDC(-1);
          end;
      76, 77, 114:                                               // BITBLT / STRETCHBLT / ALPHABLEND
          begin
            rop := U32(40);
            if (I32(88) = 0) or not LoadDib(I32(84), I32(88), I32(92), I32(96), I32(80)) then
            begin
              if typ <> 114 then
                case rop of
                  $00000042: G.FillRectColor(I32(24), I32(28), I32(24) + I32(32), I32(28) + I32(36), 0);
                  $00FF0062: G.FillRectColor(I32(24), I32(28), I32(24) + I32(32), I32(28) + I32(36), $FFFFFF);
                  $00F00021: G.FillRectBrush(I32(24), I32(28), I32(24) + I32(32), I32(28) + I32(36));
                end;
            end
            else
            begin
              if (typ = 114) and (RdU16(D, p + I32(84) + 14) = 32) then
                ApplyDibAlpha(D, p + I32(92), img, RdI32(D, p + I32(84) + 8) < 0);
              if typ = 76 then
                G.Bitmap(img, I32(24), I32(28), I32(32), I32(36), I32(44), I32(48), I32(32), I32(36), rop)
              else
                G.Bitmap(img, I32(24), I32(28), I32(32), I32(36), I32(44), I32(48), I32(100), I32(104), rop);
            end;
          end;
      81: begin                                                  // STRETCHDIBITS
            if LoadDib(I32(48), I32(52), I32(56), I32(60), I32(64)) then
              G.Bitmap(img, I32(24), I32(28), I32(72), I32(76),
                I32(32), img.H - I32(36) - I32(44), I32(40), I32(44), U32(68));
          end;
      80: begin                                                  // SETDIBITSTODEVICE
            if LoadDib(I32(48), I32(52), I32(56), I32(60), I32(64)) then
              G.Bitmap(img, I32(24), I32(28), I32(40), I32(44),
                I32(32), img.H - I32(36) - I32(44), I32(40), I32(44), $00CC0020);
          end;
      118: begin                                                 // GRADIENTFILL
             n := I32(24); np := I32(28);
             if (n > 0) and (36 + Int64(n) * 16 <= size) and (I32(32) in [0, 1]) then
               for i := 0 to np - 1 do
               begin
                 q := 36 + n * 16 + i * 8;
                 if q + 8 > Integer(size) then Break;
                 k := I32(q); ih := I32(q + 4);
                 if (k < 0) or (k >= n) or (ih < 0) or (ih >= n) then Continue;
                 r := 36 + k * 16;
                 x0 := I32(r); y0 := I32(r + 4);
                 c0 := (RdU16(D, p + r + 8) shr 8) or ((RdU16(D, p + r + 10) shr 8) shl 8) or ((RdU16(D, p + r + 12) shr 8) shl 16);
                 r := 36 + ih * 16;
                 x1 := I32(r); y1 := I32(r + 4);
                 c1 := (RdU16(D, p + r + 8) shr 8) or ((RdU16(D, p + r + 10) shr 8) shl 8) or ((RdU16(D, p + r + 12) shr 8) shl 16);
                 G.GradientRect(x0, y0, x1, y1, c0, c1, I32(32) = 1);
               end;
           end;
    end;
    p := p + NativeInt(size);
  end;
  finally
    plus.Free;
  end;
end;

// -------------------------------- entry -----------------------------------

// gzip (.wmz / .emz) -> raw bytes
function Gunzip(const D: TBytes): TBytes;
var p: NativeInt; flg: Integer;
begin
  Result := nil;
  if (Length(D) < 18) or (D[0] <> $1F) or (D[1] <> $8B) or (D[2] <> 8) then Exit;
  flg := D[3];
  p := 10;
  if (flg and 4) <> 0 then p := p + 2 + RdU16(D, p);             // FEXTRA
  if (flg and 8) <> 0 then begin while (p < Length(D)) and (D[p] <> 0) do Inc(p); Inc(p); end;
  if (flg and 16) <> 0 then begin while (p < Length(D)) and (D[p] <> 0) do Inc(p); Inc(p); end;
  if (flg and 2) <> 0 then Inc(p, 2);
  if p >= Length(D) - 8 then Exit;
  Result := InflateRaw(@D[p], Length(D) - 8 - p);
end;

function IsEmf(const D: TBytes): Boolean;
begin
  Result := (Length(D) >= 88) and (RdU32(D, 0) = 1) and (RdU32(D, 40) = $464D4520);
end;

function IsMetafile(const Data: TBytes): Boolean;
var Info: TWmfInfo;
begin
  Result := IsEmf(Data) or WmfHeader(Data, Info) or
    ((Length(Data) > 2) and (Data[0] = $1F) and (Data[1] = $8B));
end;

procedure FitSize(var W, H: Double);
var f: Double;
begin
  W := Abs(W); H := Abs(H);
  if (W < 1) or (H < 1) then begin W := Max(W, 1); H := Max(H, 1); end;
  if Max(W, H) > MAX_SIDE then
  begin
    f := MAX_SIDE / Max(W, H);
    W := W * f; H := H * f;
  end;
end;

function MetafileToSvg(const Data: TBytes; out Width, Height: Integer): string;
var
  D: TBytes;
  G, M: TGdi;
  Info: TWmfInfo;
  w, h, fl, ft, fr, fb, devW, devH, mmW, mmH, bw, bh: Double;
  p: NativeInt;
  size: Cardinal;
  foundOrg, foundExt: Boolean;
  ox, oy, ex, ey: Double;

  procedure PlayEmfFile;
  begin
    // picture frame (0.01 mm) mapped onto the reference device (pixels)
    devW := RdI32(D, 72); devH := RdI32(D, 76);
    mmW := RdI32(D, 80); mmH := RdI32(D, 84);
    if (devW > 0) and (mmW > 0) then G.DevPxPerMmX := devW / mmW;
    if (devH > 0) and (mmH > 0) then G.DevPxPerMmY := devH / mmH;
    fl := RdI32(D, 24) / 100 * G.DevPxPerMmX; ft := RdI32(D, 28) / 100 * G.DevPxPerMmY;
    fr := RdI32(D, 32) / 100 * G.DevPxPerMmX; fb := RdI32(D, 36) / 100 * G.DevPxPerMmY;
    if (fr - fl < 1) or (fb - ft < 1) then
    begin
      // no usable frame: use the bounds (device pixels)
      fl := RdI32(D, 8); ft := RdI32(D, 12); fr := RdI32(D, 16) + 1; fb := RdI32(D, 20) + 1;
      if (fr - fl < 1) or (fb - ft < 1) then raise EWmfError.Create('EMF: empty picture frame');
    end;
    // natural size = the frame in reference-device pixels, as Windows
    // (GDI+ Metafile.Width / Height) reports it
    w := fr - fl; h := fb - ft;
    FitSize(w, h);
    G.OutScaleX := w / (fr - fl); G.OutScaleY := h / (fb - ft);
    G.OutOffX := -fl * G.OutScaleX; G.OutOffY := -ft * G.OutScaleY;
    PlayEmf(G, D);
  end;

begin
  Width := 0; Height := 0; Result := '';
  D := Data;
  if (Length(D) > 2) and (D[0] = $1F) and (D[1] = $8B) then
  begin
    try
      D := Gunzip(D);
    except
      on E: Exception do raise EWmfError.Create('WMZ/EMZ: corrupt gzip data (' + E.Message + ')');
    end;
    if D = nil then raise EWmfError.Create('WMZ/EMZ: bad gzip header');
  end;

  G := TGdi.Create(False);
  try
    if IsEmf(D) then
    begin
      PlayEmfFile;
      if G.PlusLossy and (EmfPlusKind(D) = 2) then
      begin
        // dual file whose EMF+ part is not fully reproducible: use its EMF part
        G.Free;
        G := TGdi.Create(False);
        G.NoPlus := True;
        PlayEmfFile;
      end;
    end
    else if WmfHeader(D, Info) then
    begin
      G.DC.MapMode := 8;
      if Info.Placeable and (Info.R <> Info.L) and (Info.B <> Info.T) then
      begin
        if Info.Inch <= 0 then Info.Inch := 1440;
        w := (Info.R - Info.L) / Info.Inch * 96; h := (Info.B - Info.T) / Info.Inch * 96;
        FitSize(w, h);
        G.DC.WinOrgX := Info.L; G.DC.WinOrgY := Info.T;
        G.DC.WinExtX := Info.R - Info.L; G.DC.WinExtY := Info.B - Info.T;
      end
      else
      begin
        // plain WMF: take the first window origin / extent it sets
        foundOrg := False; foundExt := False; ox := 0; oy := 0; ex := 0; ey := 0;
        p := Info.Start;
        while p + 6 <= Length(D) do
        begin
          size := RdU32(D, p);
          if (size < 3) or (p + NativeInt(size) * 2 > Length(D)) then Break;
          case RdU16(D, p + 4) of
            $0000: Break;
            $020B: if not foundOrg then begin oy := RdI16(D, p + 6); ox := RdI16(D, p + 8); foundOrg := True; end;
            $020C: if not foundExt then begin ey := RdI16(D, p + 6); ex := RdI16(D, p + 8); foundExt := True; end;
          end;
          p := p + NativeInt(size) * 2;
        end;
        if foundExt and (ex <> 0) and (ey <> 0) then
        begin
          w := ex; h := ey;
          FitSize(w, h);
          G.DC.WinOrgX := ox; G.DC.WinOrgY := oy; G.DC.WinExtX := ex; G.DC.WinExtY := ey;
        end
        else
        begin
          // nothing to go by: measure the drawing in device units
          M := TGdi.Create(True);
          try
            M.DC.MapMode := 1;
            PlayWmf(M, D, Info);
            if M.FMaxX < M.FMinX then raise EWmfError.Create('WMF: nothing is drawn');
            bw := M.FMaxX - M.FMinX; bh := M.FMaxY - M.FMinY;
            w := bw; h := bh;
            FitSize(w, h);
            G.DC.MapMode := 8;
            G.DC.WinOrgX := M.FMinX; G.DC.WinOrgY := M.FMinY;
            G.DC.WinExtX := Max(bw, 1); G.DC.WinExtY := Max(bh, 1);
          finally M.Free; end;
        end;
      end;
      G.DC.VpOrgX := 0; G.DC.VpOrgY := 0;
      G.DC.VpExtX := w; G.DC.VpExtY := h;
      PlayWmf(G, D, Info);
    end
    else
      raise EWmfError.Create('Not a WMF / EMF file');

    Width := Max(1, Round(w)); Height := Max(1, Round(h));
    Result := G.BuildSvg(Width, Height);
  finally
    G.Free;
  end;
end;

end.
