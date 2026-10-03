unit XelMet;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$R-}{$Q-}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	OS/2 Presentation Manager Metafile (.met) -> SVG converter    //
// Version:	0.1                                                           //
// Date:	30-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// An OS/2 metafile is a MO:DCA-L data stream: big-endian structured fields
// (document, resource group, colour table, graphics object, image objects)
// that carry GOCA drawing orders. Inside the Graphics Data fields everything
// is little-endian (Intel order) and coordinates are 16 or 32 bits wide, as
// the Graphics Data Descriptor says.
//
// This unit plays the drawing orders on a small GOCA emulator (attribute
// stack, current position, areas, paths, clip paths, arc parameters,
// colour tables, fonts from Map Coded Font) and writes what would be drawn
// as an SVG document for SimpleSVG: <path> (lines and cubic curves, fill
// rules, dashes, caps / joins), <text>, <pattern> tiles and <clipPath>
// groups. Everything is converted to output pixels; text only uses rotate().
//
// Reproduced: lines, relative lines, polylines, boxes (rounded), fillets,
// sharp fillets (conics), cubic Beziers, 3-point arcs, full and partial arcs
// (general arc parameters), polygons, markers, character strings (angle,
// cell, direction, alignment, increments, code page 850), areas (alternate /
// winding), the default pattern set (dots, hatches), paths (fill, outline,
// stroke via Modify Path, clip), GOCA bilevel images and IOCA image objects
// drawn with Bit Blt.
//
// Not reproduced: model / viewing transforms and segment calls, raster mixes
// other than overpaint and leave-alone, custom patterns, character shear
// (shown as italic) and outline font glyph shapes.

interface

uses
  SysUtils, Classes, Math;

type
  EMetError = class(Exception);

// True for data that starts like an OS/2 metafile (MO:DCA-L structured fields).
function IsOs2Met(const Data: TBytes): Boolean;

// Converts an OS/2 .met file to an SVG document. Width and Height are the
// natural picture size in pixels (96 dpi), also written to the SVG.
function MetToSvg(const Data: TBytes; out Width, Height: Integer): string;

implementation

const
  MAX_SIDE = 4096;           // largest output side in pixels
  MAX_BITMAP_CELLS = 250000; // bitmap rect budget per image
  DEF_TEXT_PX = 16;          // text size when neither cell nor font gives one
  DEF_MARKER_PX = 8;         // marker cell when none is set

  // structured field ids (type and category bytes)
  SF_BDT = $A8A8; SF_EDT = $A9A8;
  SF_CAT = $B077;
  SF_BIM = $A8FB; SF_EIM = $A9FB; SF_IPD = $EEFB;
  SF_BGR = $A8BB; SF_EGR = $A9BB; SF_GDD = $A6BB; SF_GAD = $EEBB;
  SF_MCF = $AB8A; SF_MDR = $ABC3;

type
  TRGBAImage = record
    W, H: Integer;
    Px: array of Cardinal;  // $AARRGGBB, top-down
  end;

  // A colour table: explicit entries plus at most one bit generator.
  TPalette = record
    Loaded: Boolean;
    Ent: array of Cardinal;       // $01RRGGBB when defined, 0 when not
    GenOn, GenSub, GenGray: Boolean;
    GenStart: Int64;
    GenS: array[0..2] of Integer;
  end;

  TFontDef = record
    Lid: Integer;
    Cp: Integer;                  // IBM code page of the font, 0 = document's
    Face: string;
    Bold, Italic, Under, Strike: Boolean;
    H, W: Double;                 // world units, 0 = unknown
  end;

  TBitmapDef = record
    Id: Cardinal;
    Name: string;
    Img: TRGBAImage;
  end;

  TGraphicsObj = record
    Gdd, Gad: TBytes;
  end;

  TAttrs = record
    Col, BgCol: array[1..5] of Cardinal;   // line, char, marker, pattern, image
    Mix, BgMix: array[1..5] of Integer;
    ArcP, ArcQ, ArcR, ArcS: Double;
    ChAngX, ChAngY: Double;
    CellW, CellH: Double;                  // 0 = default
    ChDir, ChSet: Integer;
    ShearX, ShearY: Double;
    TxtH, TxtV: Integer;
    CurX, CurY: Double;
    LineType, LineEnd, LineJoin: Integer;
    LineW: Double;                         // cosmetic multiplier
    GeomW: Double;                         // geometric width, world units
    MkW, MkH: Double;
    MkSym: Integer;
    PatSet, PatSym: Integer;
    MA, MB, MC, MD, ME, MF: Double;        // model transform: x' = MA x + MC y + ME
  end;

  TPushRec = record
    Code, A, P: Integer;
    Saved: TAttrs;
  end;

  TPathDef = record
    Id: Cardinal;
    D: string;
    Stroked: Boolean;
  end;

  TMetDoc = record
    Fonts: array of TFontDef;
    Bitmaps: array of TBitmapDef;
    Handles: TStringList;         // image name -> bitmap handle (Map Data Resource)
    Pal: TPalette;                // main colour table
    DefCp: Integer;               // document code page (IBM CPGID)
    Objs: array of TGraphicsObj;
  end;

  { TMetPlayer }

  TMetPlayer = class
  private
    FFS: TFormatSettings;
    FOut: TStringBuilder;
    FMeasure: Boolean;
    FMinX, FMinY, FMaxX, FMaxY: Double;
    FPts: array of Double;        // measure pass: sampled points (x, y pairs)
    FPtCount, FPtSeen: Integer;
    FNoSample: Boolean;           // estimated extents: bounds only, not sampled
    FDoc: ^TMetDoc;
    // order stream
    B: TBytes;
    FP, FEnd: Integer;            // read window of the current order
    C32: Boolean;
    A, DefA: TAttrs;
    Stack: array of TPushRec;
    // figure building
    FLoose, FAreaSB, FPathSB: TStringBuilder;
    FInArea, FInPath, FFigOpen: Boolean;
    FAreaFlags: Integer;
    FAreaA: TAttrs;               // pattern attributes current at Begin Area
    FPathId: Cardinal;
    FFigX, FFigY: Double;
    Paths: array of TPathDef;
    // clipping
    FClipD: string;
    FClipRule: string;
    FClipSerial, FCurClip, FGroupDepth, FDefSerial: Integer;
    FPatterns: TStringList;
    // GOCA bilevel image in progress
    FImgOn: Boolean;
    FImgX, FImgY: Double;
    FImgW, FImgH, FImgRow: Integer;
    FImgRuns: TStringList;
    // viewing: window -> viewport (x' = FVA x + FVE, y' = FVD y + FVF)
    FVA, FVD, FVE, FVF: Double;
    FViewClipD: string;
    FEscRects: array of array[0..3] of Double;
    function N(v: Double): string;
    function Color(c: Cardinal): string;
    function MX(x: Double): Double;
    function MY(y: Double): Double;
    function Scale: Double;
    procedure Track(x, y: Double);
    procedure Xf(x, y: Double; out tx, ty: Double);
    function OutPt(x, y: Double): string;
    procedure ReadMatrix(Mask: Integer; out na, nb, nc, nd, ne, nf: Double);
    procedure SetModelTransform;
    procedure ReadScd;
    function ViewScale: Double;
    procedure DoEscape;
    procedure DoViewWindow;
    procedure Put(const S: string);
    procedure PutDef(const S: string);
    procedure SyncClip;
    // readers (bounded by the current order)
    function R8: Integer;
    function R16: Integer;
    function RS16: Integer;
    function R24: Cardinal;
    function R32: Cardinal;
    function RS32: Integer;
    function RC: Double;
    procedure RPt(out x, y: Double);
    function Left: Integer;
    function CoordSize: Integer;
    // colours
    function PalColor(Idx: Cardinal): Cardinal;
    function IndexedColor(Flags: Integer; Idx: Cardinal; Bg: Boolean): Cardinal;
    function StdColor(v: Integer; Bg: Boolean): Cardinal;
    // attributes
    procedure Push(Code: Integer);
    procedure Pop;
    procedure SetAttr(Code, Len: Integer);
    // geometry
    function Target: TStringBuilder;
    procedure FigStart(x, y: Double);
    procedure FigLine(x, y: Double);
    procedure FigCubic(x1, y1, x2, y2, x3, y3: Double);
    procedure FigConic(ax, ay, ex, ey, w: Double);
    procedure FigClose;
    procedure FigArc(bx, by, a11, a12, a21, a22, t0, sweep: Double; Lead: Integer);
    procedure FigDone;
    function Standalone: Boolean;
    // output
    function StrokeAttr(c: Cardinal; w: Double): string;
    function LineWidthPx: Double;
    function FillAttr(const At: TAttrs): string;
    function PatternUrl(Sym: Integer; Fg, Bg: Cardinal; OpaqueBg: Boolean): string;
    procedure EmitStroke(const D: string);
    procedure EmitFill(const D: string; const At: TAttrs; Boundary, NonZero: Boolean);
    // orders
    procedure DoLine(Given: Boolean);
    procedure DoRelLine(Given: Boolean);
    procedure DoBox(Given: Boolean);
    procedure DoFillet(Given: Boolean);
    procedure DoSharpFillet(Given: Boolean);
    procedure DoBezier(Given: Boolean);
    procedure DoArc3(Given: Boolean);
    procedure DoFullArc(Given: Boolean);
    procedure DoPartialArc(Given: Boolean);
    procedure DoPolygons;
    procedure DoMarker(Given: Boolean);
    procedure DoText(Given, Move, Ext: Boolean);
    function TextCp: Integer;
    procedure DoBeginArea;
    procedure DoEndArea;
    procedure DoBeginPath;
    procedure DoEndPath;
    procedure DoFillPath;
    procedure DoOutlinePath;
    procedure DoModifyPath;
    procedure DoClipPath;
    procedure DoBeginImage(Given: Boolean);
    procedure DoImageData;
    procedure DoEndImage;
    procedure DoBitBlt;
    procedure DrawBitmap(const Img: TRGBAImage; x0, y0, x1, y1: Double);
    procedure Order(Code, Len: Integer);
    function FindPath(Id: Cardinal): Integer;
  public
    // the picture rectangle read high byte first (some writers store it so)
    HaveAlt: Boolean;
    AX1, AY1, AX2, AY2: Double;
    OX0, OY0, SX, SY: Double;     // world -> output: ((x - OX0) * SX, (OY0 - y) * SY)
    constructor Create(AMeasure: Boolean; var Doc: TMetDoc);
    destructor Destroy; override;
    procedure ReadDescriptor(const G: TBytes; out HaveRect: Boolean;
      out X1, Y1, X2, Y2, PxPerUnitX, PxPerUnitY: Double);
    procedure Play(const G: TBytes);
    function BuildSvg(W, H: Integer): string;
    function PointShare(x1, y1, x2, y2: Double): Double;
    property MinX: Double read FMinX;
    property MinY: Double read FMinY;
    property MaxX: Double read FMaxX;
    property MaxY: Double read FMaxY;
  end;

// ------------------------------ helpers ------------------------------------

const
  // code page 850, bytes $80..$FF
  CP850: array[$80..$FF] of Word = (
    $00C7, $00FC, $00E9, $00E2, $00E4, $00E0, $00E5, $00E7, $00EA, $00EB, $00E8, $00EF, $00EE, $00EC, $00C4, $00C5,
    $00C9, $00E6, $00C6, $00F4, $00F6, $00F2, $00FB, $00F9, $00FF, $00D6, $00DC, $00F8, $00A3, $00D8, $00D7, $0192,
    $00E1, $00ED, $00F3, $00FA, $00F1, $00D1, $00AA, $00BA, $00BF, $00AE, $00AC, $00BD, $00BC, $00A1, $00AB, $00BB,
    $2591, $2592, $2593, $2502, $2524, $00C1, $00C2, $00C0, $00A9, $2563, $2551, $2557, $255D, $00A2, $00A5, $2510,
    $2514, $2534, $252C, $251C, $2500, $253C, $00E3, $00C3, $255A, $2554, $2569, $2566, $2560, $2550, $256C, $00A4,
    $00F0, $00D0, $00CA, $00CB, $00C8, $0131, $00CD, $00CE, $00CF, $2518, $250C, $2588, $2584, $00A6, $00CC, $2580,
    $00D3, $00DF, $00D4, $00D2, $00F5, $00D5, $00B5, $00FE, $00DE, $00DA, $00DB, $00D9, $00FD, $00DD, $00AF, $00B4,
    $00AD, $00B1, $2017, $00BE, $00B6, $00A7, $00F7, $00B8, $00B0, $00A8, $00B7, $00B9, $00B3, $00B2, $25A0, $00A0);

  // PM default logical colour table (CLR_BACKGROUND .. CLR_PALEGRAY)
  PM_COLORS: array[0..15] of Cardinal = (
    $FFFFFF, $0000FF, $FF0000, $FF00FF, $00FF00, $00FFFF, $FFFF00, $000000,
    $808080, $000080, $800000, $800080, $008000, $008080, $804000, $CCCCCC);

  // GOCA standard colour table, values 1..16
  GOCA_COLORS: array[1..16] of Cardinal = (
    $0000FF, $FF0000, $FF00FF, $00FF00, $00FFFF, $FFFF00, $FFFFFF, $000000,
    $0000AA, $FF8000, $AA00AA, $009200, $0092AA, $C4A020, $838383, $903000);

  BAYER8: array[0..7, 0..7] of Byte = (
    ( 0, 32,  8, 40,  2, 34, 10, 42),
    (48, 16, 56, 24, 50, 18, 58, 26),
    (12, 44,  4, 36, 14, 46,  6, 38),
    (60, 28, 52, 20, 62, 30, 54, 22),
    ( 3, 35, 11, 43,  1, 33,  9, 41),
    (51, 19, 59, 27, 49, 17, 57, 25),
    (15, 47,  7, 39, 13, 45,  5, 37),
    (63, 31, 55, 23, 61, 29, 53, 21));

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
      #0..#31: ;
    else
      Result := Result + c;
    end;
  end;
end;

function Utf8Of(cp: Cardinal): string;
begin
  if cp < $80 then Result := Chr(cp)
  else if cp < $800 then
    Result := Chr($C0 or (cp shr 6)) + Chr($80 or (cp and $3F))
  else
    Result := Chr($E0 or (cp shr 12)) + Chr($80 or ((cp shr 6) and $3F)) + Chr($80 or (cp and $3F));
end;

// code page 850 bytes -> UTF-8, one string per character
function DecodeCp850(const D: TBytes; Ofs, Len: Integer): TStringArray;
var i, n: Integer; c: Byte;
begin
  Result := nil;
  n := 0;
  for i := 0 to Len - 1 do
  begin
    if Ofs + i >= Length(D) then Break;
    c := D[Ofs + i];
    if c = 0 then Continue;
    SetLength(Result, n + 1);
    if c < 32 then Result[n] := ' '
    else if c < $80 then Result[n] := Chr(c)
    else Result[n] := Utf8Of(CP850[c]);
    Inc(n);
  end;
end;

// IBM code page -> Windows code page of the double-byte (DBCS) encodings
function DbcsCodePage(Cp: Integer): Integer;
begin
  case Cp of
    301, 897, 932, 941, 942, 943, 1351: Result := 932;          // Japanese
    835, 927, 938, 947, 948, 950, 1370: Result := 950;          // Chinese (traditional)
    928, 936, 946, 1380, 1381, 1383, 1386: Result := 936;       // Chinese (simplified)
    926, 944, 949, 951, 1362, 1363: Result := 949;              // Korean
  else
    Result := 0;
  end;
end;

// text bytes -> UTF-8, one string per character: code page 850 for the
// single-byte pages, the system's converter for the DBCS ones
function DecodeText(const D: TBytes; Ofs, Len, Cp: Integer): TStringArray;
var
  wcp, i, n, k: Integer;
  c: Byte;
  enc: TEncoding;
  two: TBytes;

  function IsLead(b: Byte): Boolean;
  begin
    if wcp = 932 then Result := (b in [$81..$9F]) or (b in [$E0..$FC])
    else Result := b in [$81..$FE];
  end;

begin
  wcp := DbcsCodePage(Cp);
  if wcp = 0 then Exit(DecodeCp850(D, Ofs, Len));
  Result := nil;
  enc := nil;
  try
    try
      enc := TEncoding.GetEncoding(wcp);
    except
      enc := nil;
    end;
    if enc = nil then Exit(DecodeCp850(D, Ofs, Len));
    n := 0;
    i := 0;
    while (i < Len) and (Ofs + i < Length(D)) do
    begin
      c := D[Ofs + i];
      if c = 0 then begin Inc(i); Continue; end;
      if IsLead(c) and (i + 1 < Len) and (Ofs + i + 1 < Length(D)) then k := 2 else k := 1;
      SetLength(two, k);
      Move(D[Ofs + i], two[0], k);
      SetLength(Result, n + 1);
      if (k = 1) and (c < 32) then Result[n] := ' '
      else if (k = 1) and (c < $80) then Result[n] := Chr(c)
      else
      begin
        try
          Result[n] := UTF8Encode(enc.GetString(two));
        except
          Result[n] := '?';
        end;
        if Result[n] = '' then Result[n] := '?';
      end;
      Inc(n);
      Inc(i, k);
    end;
  finally
    enc.Free;
  end;
end;

function BE16(const D: TBytes; p: Integer): Integer;
begin
  if (p < 0) or (p + 1 >= Length(D)) then Exit(0);
  Result := (D[p] shl 8) or D[p + 1];
end;

function BE32(const D: TBytes; p: Integer): Cardinal;
begin
  if (p < 0) or (p + 3 >= Length(D)) then Exit(0);
  Result := (Cardinal(D[p]) shl 24) or (Cardinal(D[p + 1]) shl 16) or (Cardinal(D[p + 2]) shl 8) or D[p + 3];
end;

function LE32(const D: TBytes; p: Integer): Cardinal;
begin
  if (p < 0) or (p + 3 >= Length(D)) then Exit(0);
  Result := D[p] or (Cardinal(D[p + 1]) shl 8) or (Cardinal(D[p + 2]) shl 16) or (Cardinal(D[p + 3]) shl 24);
end;

function Name8(const D: TBytes; p: Integer): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to 7 do
    if p + i < Length(D) then Result := Result + Chr(D[p + i]);
end;

// bitmap handle derived from an 8-character object name ("00000004"),
// taken pairwise as bytes, least significant first
function NameHandle(const S: string): Cardinal;
var i: Integer; b: Byte;
begin
  Result := 0;
  for i := 0 to 3 do
  begin
    if 2 * i + 2 > Length(S) then Break;
    b := Byte(((Ord(S[2 * i + 1]) - $30) shl 4) or ((Ord(S[2 * i + 2]) - $30) and $0F));
    Result := (Result shr 8) or (Cardinal(b) shl 24);
  end;
end;

function CompValue(I, Bits: Integer): Integer;
var M: Int64;
begin
  if Bits <= 0 then Exit(0);
  M := (Int64(1) shl Bits) - 1;
  if I < M / 2 then Result := Round(I / (M + 1) * 255)
  else Result := Round((I + 1) / (M + 1) * 255);
  Result := EnsureRange(Result, 0, 255);
end;

// ------------------------------ colour tables ------------------------------

procedure PalSet(var P: TPalette; Idx: Integer; c: Cardinal);
begin
  if (Idx < 0) or (Idx > $FFFF) then Exit;
  if Idx >= Length(P.Ent) then SetLength(P.Ent, Idx + 1);
  P.Ent[Idx] := $01000000 or (c and $FFFFFF);
end;

// Color Attribute Table data: base part and self-defining parameters.
procedure ParseCat(const D: TBytes; Ofs, Len: Integer; var P: TPalette);
var
  q, e, sdp, typ, fmt, idx, s1, s2, s3, tri, comp1, comp2, comp3, tot, k, j, n: Integer;
  v: array[0..2] of Integer;
  buf: array of Byte;
  gray: Integer;

  function Comp(From, Count: Integer): Integer;
  var t: Integer;
  begin
    Result := 0;
    for t := From to From + Count - 1 do
      Result := (Result shl 8) or buf[t];
  end;

begin
  e := Ofs + Len;
  if e > Length(D) then e := Length(D);
  if Len < 3 then Exit;
  if (D[Ofs] and $40) <> 0 then
  begin
    SetLength(P.Ent, 0);
    P.GenOn := False;
  end;
  P.Loaded := True;
  q := Ofs + 3;
  while q + 1 < e do
  begin
    sdp := D[q];
    if sdp < 2 then Break;
    typ := D[q + 1];
    if (typ = 1) and (sdp >= 11) and (q + 10 < e) then
    begin
      fmt := D[q + 3];
      idx := (D[q + 4] shl 16) or (D[q + 5] shl 8) or D[q + 6];
      s1 := D[q + 7]; s2 := D[q + 8]; s3 := D[q + 9];
      tri := D[q + 10];
      if fmt = 2 then begin s2 := 0; s3 := 0; end;
      comp1 := 1 + (Max(s1, 1) - 1) div 8;
      if s2 > 0 then comp2 := 1 + (s2 - 1) div 8 else comp2 := 0;
      if s3 > 0 then comp3 := 1 + (s3 - 1) div 8 else comp3 := 0;
      tot := comp1 + comp2 + comp3;
      if tri > 0 then
      begin
        SetLength(buf, tot);
        n := (sdp - 11) div tri;
        for k := 0 to n - 1 do
        begin
          if q + 11 + (k + 1) * tri > e then Break;
          // right-align the element in the component buffer
          FillChar(buf[0], tot, 0);
          for j := 0 to Min(tri, tot) - 1 do
            buf[tot - 1 - j] := D[q + 11 + (k + 1) * tri - 1 - j];
          v[0] := CompValue(Comp(0, comp1), s1);
          if fmt = 2 then
          begin
            gray := v[0];
            PalSet(P, idx + k, (Cardinal(gray) shl 16) or (Cardinal(gray) shl 8) or Cardinal(gray));
          end
          else
          begin
            v[1] := CompValue(Comp(comp1, comp2), s2);
            v[2] := CompValue(Comp(comp1 + comp2, comp3), s3);
            PalSet(P, idx + k, (Cardinal(v[0]) shl 16) or (Cardinal(v[1]) shl 8) or Cardinal(v[2]));
          end;
        end;
      end;
    end
    else if (typ = 2) and (sdp >= 10) and (q + 9 < e) then
    begin
      P.GenOn := True;
      P.GenSub := (D[q + 2] and $80) <> 0;
      P.GenGray := D[q + 3] = 2;
      P.GenStart := (D[q + 4] shl 16) or (D[q + 5] shl 8) or D[q + 6];
      P.GenS[0] := Min(D[q + 7], 16); P.GenS[1] := Min(D[q + 8], 16); P.GenS[2] := Min(D[q + 9], 16);
      if P.GenGray then begin P.GenS[1] := 0; P.GenS[2] := 0; end;
    end;
    Inc(q, sdp);
  end;
end;

// Looks an index up; False when the table does not define it.
function PalLookup(const P: TPalette; Idx: Cardinal; out c: Cardinal): Boolean;
var
  nb, k, sh, g: Integer;
  v: array[0..2] of Integer;
  rel, m: Int64;
begin
  Result := False;
  if (Idx < Cardinal(Length(P.Ent))) and ((P.Ent[Idx] and $01000000) <> 0) then
  begin
    c := P.Ent[Idx] and $FFFFFF;
    Exit(True);
  end;
  if P.GenOn then
  begin
    nb := P.GenS[0] + P.GenS[1] + P.GenS[2];
    rel := Int64(Idx) - P.GenStart;
    if (nb > 0) and (rel >= 0) and (rel < (Int64(1) shl nb)) then
    begin
      sh := nb;
      for k := 0 to 2 do
      begin
        sh := sh - P.GenS[k];
        m := (Int64(1) shl P.GenS[k]) - 1;
        v[k] := Integer((rel shr sh) and m);
        if P.GenSub then v[k] := Integer(m) - v[k];
        v[k] := CompValue(v[k], P.GenS[k]);
      end;
      if P.GenGray then
      begin
        g := v[0];
        c := (Cardinal(g) shl 16) or (Cardinal(g) shl 8) or Cardinal(g);
      end
      else
        c := (Cardinal(v[0]) shl 16) or (Cardinal(v[1]) shl 8) or Cardinal(v[2]);
      Exit(True);
    end;
  end;
end;

// ------------------------------ IOCA images --------------------------------

type
  TIocaBuild = record
    W, H, Bpp: Integer;
    Data: TBytes;
    Len: Integer;
  end;

procedure IocaAppend(var IB: TIocaBuild; const D: TBytes; Ofs, Len: Integer);
begin
  if Len <= 0 then Exit;
  if IB.Len + Len > Length(IB.Data) then SetLength(IB.Data, Max(IB.Len + Len, Length(IB.Data) * 2));
  Move(D[Ofs], IB.Data[IB.Len], Len);
  Inc(IB.Len, Len);
end;

// Image Picture Data: IOCA self-defining fields.
procedure ParseIpd(const D: TBytes; Ofs, Len: Integer; var IB: TIocaBuild);
var
  q, e, id, l, a, b: Integer;
begin
  q := Ofs; e := Min(Ofs + Len, Length(D));
  while q + 1 < e do
  begin
    id := D[q];
    if id = $FE then
    begin
      if q + 3 >= e then Break;
      id := $FE00 or D[q + 1];
      l := BE16(D, q + 2);
      Inc(q, 4);
    end
    else
    begin
      l := D[q + 1];
      Inc(q, 2);
    end;
    if q + l > e then l := e - q;
    case id of
      $94: if l >= 9 then
           begin
             // the size field is read as OS/2 writes it; checked against
             // the amount of data when the image is built
             a := BE16(D, q + 5); b := BE16(D, q + 7);
             IB.H := a; IB.W := b;
           end;
      $96: if l >= 1 then IB.Bpp := D[q];
      $FE92: IocaAppend(IB, D, q, l);
    end;
    Inc(q, l);
  end;
end;

function IocaStride(W, Bpp: Integer): Int64;
begin
  Result := ((Int64(W) * Bpp + 31) div 32) * 4;
end;

// OS/2 bitmap rows: bottom-up, 4-byte aligned, 24-bit pixels in RGB order.
function IocaBuildImage(var IB: TIocaBuild; const Pal: TPalette; out Img: TRGBAImage): Boolean;
var
  x, y, t, stride, v, bpp, ncol: Integer;
  p, o: Int64;
  c: Cardinal;
  cols: array[0..255] of Cardinal;
begin
  Result := False;
  Img.W := 0; Img.H := 0; Img.Px := nil;
  bpp := IB.Bpp;
  if not (bpp in [1, 4, 8, 24, 32]) then Exit;
  // the size field order differs between writers: take the one the data fits
  if (IB.W > 0) and (IB.H > 0) and (IocaStride(IB.W, bpp) * IB.H > IB.Len) and
     (IocaStride(IB.H, bpp) * IB.W <= IB.Len) then
  begin
    t := IB.W; IB.W := IB.H; IB.H := t;
  end;
  if (IB.W <= 0) or (IB.H <= 0) or (Int64(IB.W) * IB.H > 64000000) then Exit;
  stride := IocaStride(IB.W, bpp);
  if bpp <= 8 then
  begin
    ncol := 1 shl bpp;
    for t := 0 to ncol - 1 do
      if not PalLookup(Pal, t, cols[t]) then
      begin
        if bpp = 1 then cols[t] := $FFFFFF * Cardinal(t)
        else begin v := t * 255 div (ncol - 1); cols[t] := (Cardinal(v) shl 16) or (Cardinal(v) shl 8) or Cardinal(v); end;
      end;
  end;
  Img.W := IB.W; Img.H := IB.H;
  SetLength(Img.Px, Img.W * Img.H);
  for y := 0 to Img.H - 1 do
  begin
    p := Int64(Img.H - 1 - y) * stride;
    for x := 0 to Img.W - 1 do
    begin
      c := 0;
      o := MaxInt;
      case bpp of
        1: begin
             o := p + x shr 3;
             if o < IB.Len then c := cols[(IB.Data[o] shr (7 - (x and 7))) and 1];
           end;
        4: begin
             o := p + x shr 1;
             if o < IB.Len then
               if (x and 1) = 0 then c := cols[IB.Data[o] shr 4] else c := cols[IB.Data[o] and 15];
           end;
        8: begin
             o := p + x;
             if o < IB.Len then c := cols[IB.Data[o]];
           end;
        24: begin
              o := p + x * 3;
              if o + 2 < IB.Len then
                c := (Cardinal(IB.Data[o]) shl 16) or (Cardinal(IB.Data[o + 1]) shl 8) or IB.Data[o + 2];
            end;
        32: begin
              o := p + x * 4;
              if o + 2 < IB.Len then
                c := (Cardinal(IB.Data[o]) shl 16) or (Cardinal(IB.Data[o + 1]) shl 8) or IB.Data[o + 2];
            end;
      end;
      if o < IB.Len then Img.Px[y * Img.W + x] := $FF000000 or c
      else Img.Px[y * Img.W + x] := 0;     // truncated data
    end;
  end;
  Result := True;
end;

// ------------------------------ TMetPlayer ---------------------------------

constructor TMetPlayer.Create(AMeasure: Boolean; var Doc: TMetDoc);
var i: Integer;
begin
  inherited Create;
  FMeasure := AMeasure;
  FDoc := @Doc;
  FFS := DefaultFormatSettings;
  FFS.DecimalSeparator := '.';
  FOut := TStringBuilder.Create;
  FLoose := TStringBuilder.Create;
  FAreaSB := TStringBuilder.Create;
  FPathSB := TStringBuilder.Create;
  FPatterns := TStringList.Create;
  FImgRuns := TStringList.Create;
  FMinX := 1e300; FMinY := 1e300; FMaxX := -1e300; FMaxY := -1e300;
  OX0 := 0; OY0 := 0; SX := 1; SY := 1;
  FVA := 1; FVD := 1; FVE := 0; FVF := 0;
  C32 := True;
  FillChar(DefA, SizeOf(DefA), 0);
  for i := 1 to 5 do
  begin
    DefA.Col[i] := 0; DefA.BgCol[i] := $FFFFFF;
    DefA.Mix[i] := 2; DefA.BgMix[i] := 5;
  end;
  DefA.ArcP := 1; DefA.ArcQ := 1;
  DefA.ChAngX := 1; DefA.ChDir := 1;
  DefA.ShearY := 1;
  DefA.LineType := 7; DefA.LineW := 1;
  DefA.MkSym := 1;
  DefA.PatSym := $10;
  DefA.MA := 1; DefA.MD := 1;
  A := DefA;
end;

destructor TMetPlayer.Destroy;
var i: Integer;
begin
  FOut.Free; FLoose.Free; FAreaSB.Free; FPathSB.Free;
  FPatterns.Free;
  for i := 0 to FImgRuns.Count - 1 do FImgRuns.Objects[i].Free;
  FImgRuns.Free;
  inherited Destroy;
end;

function TMetPlayer.N(v: Double): string;
var i: Integer;
begin
  if Abs(v) < 0.005 then Exit('0');
  v := EnsureRange(v, -1e7, 1e7);
  Result := FloatToStrF(v, ffFixed, 15, 2, FFS);
  if Pos('.', Result) > 0 then
  begin
    i := Length(Result);
    while Result[i] = '0' do Dec(i);
    if Result[i] = '.' then Dec(i);
    SetLength(Result, i);
  end;
end;

function TMetPlayer.Color(c: Cardinal): string;
begin
  Result := '#' + IntToHex((c shr 16) and $FF, 2) + IntToHex((c shr 8) and $FF, 2) + IntToHex(c and $FF, 2);
end;

function TMetPlayer.MX(x: Double): Double;
begin
  Result := (x - OX0) * SX;
end;

function TMetPlayer.MY(y: Double): Double;
begin
  Result := (OY0 - y) * SY;
end;

function TMetPlayer.Scale: Double;
begin
  Result := Sqrt(Abs(SX * SY));
  if Result <= 0 then Result := 1;
end;

procedure TMetPlayer.Track(x, y: Double);
begin
  if IsNan(x) or IsNan(y) then Exit;
  if x < FMinX then FMinX := x;
  if x > FMaxX then FMaxX := x;
  if y < FMinY then FMinY := y;
  if y > FMaxY then FMaxY := y;
  if FMeasure and not FNoSample then
  begin
    // keep a sample of the points to judge picture rectangles with
    Inc(FPtSeen);
    if FPtCount < 200000 then
    begin
      if 2 * FPtCount + 2 > Length(FPts) then SetLength(FPts, Max(1024, 4 * FPtCount + 4));
      FPts[2 * FPtCount] := x; FPts[2 * FPtCount + 1] := y;
      Inc(FPtCount);
    end
    else if (FPtSeen mod 7) = 0 then
    begin
      FPts[2 * (FPtSeen mod FPtCount)] := x; FPts[2 * (FPtSeen mod FPtCount) + 1] := y;
    end;
  end;
end;

// share of the sampled drawing points inside a rectangle (1 % slack)
function TMetPlayer.PointShare(x1, y1, x2, y2: Double): Double;
var i, n: Integer; dx, dy: Double;
begin
  if FPtCount = 0 then Exit(0);
  dx := (x2 - x1) * 0.01; dy := (y2 - y1) * 0.01;
  n := 0;
  for i := 0 to FPtCount - 1 do
    if (FPts[2 * i] >= x1 - dx) and (FPts[2 * i] <= x2 + dx) and
       (FPts[2 * i + 1] >= y1 - dy) and (FPts[2 * i + 1] <= y2 + dy) then Inc(n);
  Result := n / FPtCount;
end;

// model transform (model space -> world space)
procedure TMetPlayer.Xf(x, y: Double; out tx, ty: Double);
begin
  tx := FVA * (A.MA * x + A.MC * y + A.ME) + FVE;
  ty := FVD * (A.MB * x + A.MD * y + A.MF) + FVF;
end;

function TMetPlayer.ViewScale: Double;
begin
  Result := Sqrt(Abs(FVA * FVD));
  if Result <= 0 then Result := 1;
end;

// Escapes: OS/2 writes the page viewport of a picture drawn through a
// viewing window as escape X'18' (a rectangle x1, y1, x2, y2)
procedure TMetPlayer.DoEscape;
var n: Integer;
begin
  R8;
  if R8 <> $18 then Exit;
  if Left < 4 * CoordSize then Exit;
  n := Length(FEscRects);
  if n >= 8 then
  begin
    Move(FEscRects[1], FEscRects[0], 7 * SizeOf(FEscRects[0]));
    n := 7;
  end;
  SetLength(FEscRects, n + 1);
  FEscRects[n][0] := RC; FEscRects[n][1] := RC; FEscRects[n][2] := RC; FEscRects[n][3] := RC;
end;

// Set Viewing Window: FLAGS, MASK, then Xleft, Xright, Ybottom, Ytop. A
// window that covers the whole coordinate space switches viewing off; a
// finite one is mapped onto the viewport given by the preceding escape
// rectangle (the one that differs from the window) and clips.
procedure TMetPlayer.DoViewWindow;
var
  xl, xr, yb, yt, vx1, vy1, vx2, vy2, t: Double;
  i: Integer;
  found: Boolean;
begin
  R8; R8;
  xl := RC; xr := RC; yb := RC; yt := RC;
  FVA := 1; FVD := 1; FVE := 0; FVF := 0;
  FViewClipD := '';
  if (Abs(xl) > 1e8) or (Abs(xr) > 1e8) or (Abs(yb) > 1e8) or (Abs(yt) > 1e8) or
     (xr = xl) or (yt = yb) then
  begin
    Inc(FClipSerial);
    Exit;
  end;
  if xl > xr then begin t := xl; xl := xr; xr := t; end;
  if yb > yt then begin t := yb; yb := yt; yt := t; end;
  found := False;
  vx1 := xl; vy1 := yb; vx2 := xr; vy2 := yt;
  for i := High(FEscRects) downto 0 do
  begin
    vx1 := Min(FEscRects[i][0], FEscRects[i][2]); vx2 := Max(FEscRects[i][0], FEscRects[i][2]);
    vy1 := Min(FEscRects[i][1], FEscRects[i][3]); vy2 := Max(FEscRects[i][1], FEscRects[i][3]);
    if (vx2 > vx1) and (vy2 > vy1) and
       ((Abs(vx1 - xl) > 0.5) or (Abs(vx2 - xr) > 0.5) or (Abs(vy1 - yb) > 0.5) or (Abs(vy2 - yt) > 0.5)) then
    begin
      found := True;
      Break;
    end;
  end;
  if found then
  begin
    FVA := (vx2 - vx1) / (xr - xl); FVE := vx1 - xl * FVA;
    FVD := (vy2 - vy1) / (yt - yb); FVF := vy1 - yb * FVD;
  end
  else begin vx1 := xl; vy1 := yb; vx2 := xr; vy2 := yt; end;
  FViewClipD := 'M' + N(MX(vx1)) + ' ' + N(MY(vy1)) + ' L' + N(MX(vx2)) + ' ' + N(MY(vy1)) +
    ' L' + N(MX(vx2)) + ' ' + N(MY(vy2)) + ' L' + N(MX(vx1)) + ' ' + N(MY(vy2)) + ' Z';
  Inc(FClipSerial);
end;

// a model-space point as output coordinates "x y"; it counts for the bounds
function TMetPlayer.OutPt(x, y: Double): string;
var tx, ty: Double;
begin
  Xf(x, y, tx, ty);
  Track(tx, ty);
  Result := N(MX(tx)) + ' ' + N(MY(ty));
end;

// Set Model Transform: a type byte, a mask of the elements present in the
// 4 x 4 matrix (bit 0 = M11 .. bit 15 = M44, most significant first), then
// those elements: FIXED 16.16 scale / rotation parts, coordinates for the
// translation row. Type 1 adds the matrix after the current transform,
// type 2 before it; the others replace it.
procedure TMetPlayer.ReadMatrix(Mask: Integer; out na, nb, nc, nd, ne, nf: Double);
var
  i: Integer;
  m: array[0..15] of Double;
begin
  for i := 0 to 15 do
    if i in [0, 5, 10, 15] then m[i] := 1 else m[i] := 0;
  for i := 0 to 15 do
    if (Mask and ($8000 shr i)) <> 0 then
    begin
      if Left <= 0 then Break;
      if i >= 12 then m[i] := RC
      else if C32 then m[i] := RS32 / 65536   // FIXED 16.16
      else m[i] := RS16;                      // 16-bit pictures: integers
    end;
  na := m[0]; nb := m[1]; nc := m[4]; nd := m[5]; ne := m[12]; nf := m[13];
end;

procedure TMetPlayer.SetModelTransform;
var
  typ, mask: Integer;
  na, nb, nc, nd, ne, nf, oa, ob, oc, od, oe, off: Double;
begin
  R8;
  typ := R8;
  mask := R8 shl 8;
  mask := mask or R8;
  ReadMatrix(mask, na, nb, nc, nd, ne, nf);
  oa := A.MA; ob := A.MB; oc := A.MC; od := A.MD; oe := A.ME; off := A.MF;
  case typ of
    1: begin   // current, then new
         A.MA := na * oa + nc * ob; A.MB := nb * oa + nd * ob;
         A.MC := na * oc + nc * od; A.MD := nb * oc + nd * od;
         A.ME := na * oe + nc * off + ne; A.MF := nb * oe + nd * off + nf;
       end;
    2: begin   // new, then current
         A.MA := oa * na + oc * nb; A.MB := ob * na + od * nb;
         A.MC := oa * nc + oc * nd; A.MD := ob * nc + od * nd;
         A.ME := oa * ne + oc * nf + oe; A.MF := ob * ne + od * nf + off;
       end;
  else
    A.MA := na; A.MB := nb; A.MC := nc; A.MD := nd; A.ME := ne; A.MF := nf;
  end;
end;

procedure TMetPlayer.PutDef(const S: string);
begin
  if not FMeasure then FOut.Append(S).Append(#10);
end;

procedure TMetPlayer.Put(const S: string);
begin
  if FMeasure then Exit;
  SyncClip;
  FOut.Append(S).Append(#10);
end;

procedure TMetPlayer.SyncClip;
var
  i: Integer;
  id: string;
begin
  if FClipSerial = FCurClip then Exit;
  for i := 1 to FGroupDepth do FOut.Append('</g>').Append(#10);
  FGroupDepth := 0;
  FCurClip := FClipSerial;
  if FViewClipD <> '' then
  begin
    Inc(FDefSerial);
    id := 'clip' + IntToStr(FDefSerial);
    FOut.Append('<clipPath id="' + id + '"><path d="' + FViewClipD + '"/></clipPath>').Append(#10);
    FOut.Append('<g clip-path="url(#' + id + ')">').Append(#10);
    Inc(FGroupDepth);
  end;
  if FClipD = '' then Exit;
  Inc(FDefSerial);
  id := 'clip' + IntToStr(FDefSerial);
  FOut.Append('<clipPath id="' + id + '"><path d="' + FClipD + '" clip-rule="' + FClipRule +
    '"/></clipPath>').Append(#10);
  FOut.Append('<g clip-path="url(#' + id + ')">').Append(#10);
  Inc(FGroupDepth);
end;

// ---- reading inside the current order ----

function TMetPlayer.Left: Integer;
begin
  Result := FEnd - FP;
end;

function TMetPlayer.CoordSize: Integer;
begin
  if C32 then Result := 4 else Result := 2;
end;

function TMetPlayer.R8: Integer;
begin
  if FP < FEnd then begin Result := B[FP]; Inc(FP); end
  else begin Result := 0; Inc(FP); end;
end;

function TMetPlayer.R16: Integer;
begin
  Result := R8;
  Result := Result or (R8 shl 8);
end;

function TMetPlayer.RS16: Integer;
begin
  Result := SmallInt(Word(R16));
end;

function TMetPlayer.R24: Cardinal;
begin
  Result := Cardinal(R8);
  Result := Result or (Cardinal(R8) shl 8);
  Result := Result or (Cardinal(R8) shl 16);
end;

function TMetPlayer.R32: Cardinal;
begin
  Result := Cardinal(R16);
  Result := Result or (Cardinal(R16) shl 16);
end;

function TMetPlayer.RS32: Integer;
begin
  Result := Integer(R32);
end;

function TMetPlayer.RC: Double;
begin
  if C32 then Result := RS32 else Result := RS16;
end;

procedure TMetPlayer.RPt(out x, y: Double);
begin
  x := RC; y := RC;
end;

// ---- colours ----

function TMetPlayer.PalColor(Idx: Cardinal): Cardinal;
begin
  if PalLookup(FDoc^.Pal, Idx, Result) then Exit;
  if not FDoc^.Pal.Loaded and (Idx <= 15) then Exit(PM_COLORS[Idx]);
  Result := Idx and $FFFFFF;
end;

// Set Indexed Color: FLAGS bit $80 = default, $40 = negative PM value.
function TMetPlayer.IndexedColor(Flags: Integer; Idx: Cardinal; Bg: Boolean): Cardinal;
begin
  if (Flags and $40) <> 0 then
  begin
    case Idx of
      1, 5: Result := $000000;     // CLR_BLACK, CLR_FALSE
      2, 4: Result := $FFFFFF;     // CLR_WHITE, CLR_TRUE
    else
      if Bg then Result := $FFFFFF else Result := $000000;   // CLR_DEFAULT
    end;
  end
  else
    Result := PalColor(Idx);
end;

// Set Color / Set Extended Color: two-byte colour values.
function TMetPlayer.StdColor(v: Integer; Bg: Boolean): Cardinal;
var lo: Integer;
begin
  v := v and $FFFF;
  lo := v and $FF;
  if (v and $FF00) = $FF00 then
  begin
    case lo of
      1..6: Exit(GOCA_COLORS[lo]);
      7, $FB, $FF: Exit($000000);   // neutral; PM CLR_FALSE, CLR_BLACK
      8, $FC, $FE: Exit($FFFFFF);   // colour of medium; PM CLR_TRUE, CLR_WHITE
    else
      if Bg then Exit($FFFFFF) else Exit($000000);
    end;
  end;
  if v = 0 then
  begin
    if Bg then Exit($FFFFFF) else Exit($000000);
  end;
  // small values name the standard colours (PM and GOCA agree on 1..6)
  // unless an explicit colour table entry redefines them
  if (v < Length(FDoc^.Pal.Ent)) and ((FDoc^.Pal.Ent[v] and $01000000) <> 0) then
    Exit(FDoc^.Pal.Ent[v] and $FFFFFF);
  if v <= 15 then Exit(PM_COLORS[v]);
  if v = 16 then Exit(GOCA_COLORS[v]);
  Result := PalColor(v);
end;

// ---- attribute stack ----

procedure TMetPlayer.Push(Code: Integer);
var n: Integer;
begin
  n := Length(Stack);
  if n >= 4096 then Exit;
  SetLength(Stack, n + 1);
  Stack[n].Code := Code;
  Stack[n].A := 0; Stack[n].P := 0;
  Stack[n].Saved := A;
end;

procedure TMetPlayer.Pop;
var
  n, i: Integer;
  S: TAttrs;
begin
  n := Length(Stack);
  if n = 0 then Exit;
  S := Stack[n - 1].Saved;
  case Stack[n - 1].Code of
    $14: begin
           i := Stack[n - 1].P;
           if i in [1..5] then
             case Stack[n - 1].A of
               1: A.Col[i] := S.Col[i];
               2: A.BgCol[i] := S.BgCol[i];
               3: A.Mix[i] := S.Mix[i];
               4: A.BgMix[i] := S.BgMix[i];
             end;
         end;
    $0A, $A6, $26: A.Col := S.Col;
    $25, $A7: A.BgCol := S.BgCol;
    $0C: A.Mix := S.Mix;
    $0D: A.BgMix := S.BgMix;
    $08: A.PatSet := S.PatSet;
    $28: A.PatSym := S.PatSym;
    $1A: A.LineEnd := S.LineEnd;
    $1B: A.LineJoin := S.LineJoin;
    $18: A.LineType := S.LineType;
    $19, $11: A.LineW := S.LineW;
    $15: A.GeomW := S.GeomW;
    $3A: A.ChDir := S.ChDir;
    $38: A.ChSet := S.ChSet;
    $34: begin A.ChAngX := S.ChAngX; A.ChAngY := S.ChAngY; end;
    $33: begin A.CellW := S.CellW; A.CellH := S.CellH; end;
    $35: begin A.ShearX := S.ShearX; A.ShearY := S.ShearY; end;
    $36: begin A.TxtH := S.TxtH; A.TxtV := S.TxtV; end;
    $29: A.MkSym := S.MkSym;
    $37: begin A.MkW := S.MkW; A.MkH := S.MkH; end;
    $22: begin A.ArcP := S.ArcP; A.ArcQ := S.ArcQ; A.ArcR := S.ArcR; A.ArcS := S.ArcS; end;
    $21: begin A.CurX := S.CurX; A.CurY := S.CurY; end;
    $24: begin
           A.MA := S.MA; A.MB := S.MB; A.MC := S.MC; A.MD := S.MD; A.ME := S.ME; A.MF := S.MF;
         end;
  end;
  SetLength(Stack, n - 1);
end;

// Attribute setting orders (the push forms are mapped onto these).
procedure TMetPlayer.SetAttr(Code, Len: Integer);
var
  i, fl, att, prim, v: Integer;
  c: Cardinal;
  x, y: Double;
begin
  case Code of
    $14: begin      // individual attribute
           att := R8; prim := R8; fl := R8;
           if Length(Stack) > 0 then
             if Stack[High(Stack)].Code = $14 then
             begin
               Stack[High(Stack)].A := att; Stack[High(Stack)].P := prim;
             end;
           if not (prim in [1..5]) then Exit;
           case att of
             1, 2: begin
                     if (fl and $80) <> 0 then
                     begin
                       if att = 1 then A.Col[prim] := DefA.Col[prim] else A.BgCol[prim] := DefA.BgCol[prim];
                     end
                     else
                     begin
                       c := IndexedColor(fl, R24, att = 2);
                       if att = 1 then A.Col[prim] := c else A.BgCol[prim] := c;
                     end;
                   end;
             3: begin v := R8; if v = 0 then A.Mix[prim] := DefA.Mix[prim] else A.Mix[prim] := v; end;
             4: begin v := R8; if v = 0 then A.BgMix[prim] := DefA.BgMix[prim] else A.BgMix[prim] := v; end;
           end;
         end;
    $0A, $26: begin  // colour, extended colour
           if Code = $0A then v := $FF00 or R8 else v := R16;
           if (v = 0) or (v = $FF00) then A.Col := DefA.Col
           else
           begin
             c := StdColor(v, False);
             for i := 1 to 5 do A.Col[i] := c;
           end;
         end;
    $A6: begin       // indexed colour
           fl := R8;
           if (fl and $80) <> 0 then A.Col := DefA.Col
           else
           begin
             c := IndexedColor(fl, R24, False);
             for i := 1 to 5 do A.Col[i] := c;
           end;
         end;
    $25: begin       // background colour
           v := R16;
           if (v = 0) or (v = $FF00) then A.BgCol := DefA.BgCol
           else
           begin
             c := StdColor(v, True);
             for i := 1 to 5 do A.BgCol[i] := c;
           end;
         end;
    $A7: begin       // background indexed colour
           fl := R8;
           if (fl and $80) <> 0 then A.BgCol := DefA.BgCol
           else
           begin
             c := IndexedColor(fl, R24, True);
             for i := 1 to 5 do A.BgCol[i] := c;
           end;
         end;
    $0C: begin v := R8; for i := 1 to 5 do if v = 0 then A.Mix[i] := 2 else A.Mix[i] := v; end;
    $0D: begin v := R8; for i := 1 to 5 do if v = 0 then A.BgMix[i] := 5 else A.BgMix[i] := v; end;
    $08: A.PatSet := R8;
    $28: begin v := R8; if v = 0 then A.PatSym := DefA.PatSym else A.PatSym := v; end;
    $1A: A.LineEnd := R8;
    $1B: A.LineJoin := R8;
    $18: begin v := R8; if v = 0 then A.LineType := DefA.LineType else A.LineType := v; end;
    $19: begin v := R8; if v = 0 then A.LineW := 1 else A.LineW := v; end;
    $11: begin      // fractional line width: integer and 1/256 parts
           v := R8; i := R8;
           A.LineW := v + i / 256;
           if A.LineW <= 0 then A.LineW := 1;
         end;
    $15: begin      // geometric (stroke) line width
           fl := R8;
           if (fl and $80) <> 0 then A.GeomW := 0
           else
           begin
             R8;
             A.GeomW := Abs(RC);
           end;
         end;
    $3A: begin v := R8; if v = 0 then A.ChDir := 1 else A.ChDir := v; end;
    $38: A.ChSet := R8;
    $34: begin
           RPt(x, y);
           if (x = 0) and (y = 0) then begin x := 1; y := 0; end;
           A.ChAngX := x; A.ChAngY := y;
         end;
    $33: begin      // character cell
           x := RC; y := RC;
           if (not C32) and (Len >= 8) then
           begin
             x := x + R16 / 65536; y := y + R16 / 65536;
           end;
           A.CellW := x; A.CellH := y;
         end;
    $35: begin
           RPt(x, y);
           A.ShearX := x; A.ShearY := y;
         end;
    $36: begin A.TxtH := R8; A.TxtV := R8; end;
    $29: begin v := R8; if v = 0 then A.MkSym := 1 else A.MkSym := v; end;
    $37: begin
           x := RC; y := RC;
           A.MkW := Abs(x); A.MkH := Abs(y);
         end;
    $22: begin
           A.ArcP := RC; A.ArcQ := RC; A.ArcR := RC; A.ArcS := RC;
         end;
    $21: begin
           RPt(x, y);
           A.CurX := x; A.CurY := y;
         end;
    $24: SetModelTransform;
  end;
end;

// ---- figures ----

function TMetPlayer.Standalone: Boolean;
begin
  Result := not (FInArea or FInPath);
end;

function TMetPlayer.Target: TStringBuilder;
begin
  if FInArea then Result := FAreaSB
  else if FInPath then Result := FPathSB
  else Result := FLoose;
end;

// Starts a primitive at (x, y). Inside an area or path the primitive joins
// the open figure when it starts where that figure ended.
procedure TMetPlayer.FigStart(x, y: Double);
var sb: TStringBuilder;
begin
  sb := Target;
  if Standalone then sb.Clear
  else
  begin
    if FFigOpen and (Abs(x - FFigX) < 1e-7) and (Abs(y - FFigY) < 1e-7) then Exit;
    if FFigOpen and FInArea then sb.Append('Z ');
  end;
  sb.Append('M').Append(OutPt(x, y)).Append(' ');
  FFigOpen := True;
  FFigX := x; FFigY := y;
end;

procedure TMetPlayer.FigLine(x, y: Double);
begin
  Target.Append('L').Append(OutPt(x, y)).Append(' ');
  FFigX := x; FFigY := y;
end;

procedure TMetPlayer.FigCubic(x1, y1, x2, y2, x3, y3: Double);
begin
  Target.Append('C').Append(OutPt(x1, y1)).Append(' ').Append(OutPt(x2, y2)).Append(' ')
    .Append(OutPt(x3, y3)).Append(' ');
  FFigX := x3; FFigY := y3;
end;

// conic section from the current figure point, control (ax, ay), end
// (ex, ey), weight w, as one cubic (exact for w = 1, close otherwise)
procedure TMetPlayer.FigConic(ax, ay, ex, ey, w: Double);
var sx0, sy0, k: Double;
begin
  sx0 := FFigX; sy0 := FFigY;
  if w <= 0 then begin FigLine(ex, ey); Exit; end;
  k := 4 * w / (3 * (1 + w));
  FigCubic(sx0 + k * (ax - sx0), sy0 + k * (ay - sy0), ex + k * (ax - ex), ey + k * (ay - ey), ex, ey);
end;

procedure TMetPlayer.FigClose;
begin
  Target.Append('Z ');
  if not Standalone then FFigOpen := False;
end;

// Elliptic arc (x, y) = B + A (cos t, sin t) for t from t0 over sweep
// (radians). Lead: 0 = continue, 1 = start a primitive at the first point,
// 2 = draw a line to the first point.
procedure TMetPlayer.FigArc(bx, by, a11, a12, a21, a22, t0, sweep: Double; Lead: Integer);
var
  n, i: Integer;
  ta, tb, d, k, ux, uy, vx, vy: Double;

  procedure P(u, v: Double; out x, y: Double);
  begin
    x := bx + a11 * u + a12 * v;
    y := by + a21 * u + a22 * v;
  end;

var x0, y0, x1, y1, x2, y2, x3, y3: Double;
begin
  P(Cos(t0), Sin(t0), x0, y0);
  case Lead of
    1: FigStart(x0, y0);
    2: FigLine(x0, y0);
  end;
  n := Max(1, Ceil(Abs(sweep) / (Pi / 2) - 1e-9));
  if n > 64 then n := 64;
  d := sweep / n;
  k := 4 / 3 * Tan(d / 4);
  for i := 0 to n - 1 do
  begin
    ta := t0 + i * d; tb := ta + d;
    ux := Cos(ta); uy := Sin(ta);
    vx := Cos(tb); vy := Sin(tb);
    P(ux - k * uy, uy + k * ux, x1, y1);
    P(vx + k * vy, vy - k * vx, x2, y2);
    P(vx, vy, x3, y3);
    FigCubic(x1, y1, x2, y2, x3, y3);
  end;
end;

// ends a primitive: a stand-alone one is drawn with the line attributes
procedure TMetPlayer.FigDone;
begin
  if Standalone and (FLoose.Length > 0) then EmitStroke(Trim(FLoose.ToString));
  if Standalone then FLoose.Clear;
end;

// ---- output ----

function TMetPlayer.LineWidthPx: Double;
begin
  if A.GeomW > 0 then Result := Max(A.GeomW * Scale * ViewScale, 0.25)
  else Result := Max(A.LineW, 0.25);
end;

function TMetPlayer.StrokeAttr(c: Cardinal; w: Double): string;
var
  u: Double;
  dash: string;
begin
  Result := ' stroke="' + Color(c) + '" stroke-width="' + N(w) + '"';
  u := Max(w, 1);
  dash := '';
  case A.LineType of
    1: dash := N(u) + ' ' + N(2 * u);                                    // dotted
    2: dash := N(4 * u) + ' ' + N(2 * u);                                // short dash
    3: dash := N(6 * u) + ' ' + N(2 * u) + ' ' + N(u) + ' ' + N(2 * u);  // dash dot
    4: dash := N(u) + ' ' + N(2 * u) + ' ' + N(u) + ' ' + N(4 * u);      // double dot
    5: dash := N(9 * u) + ' ' + N(3 * u);                                // long dash
    6: dash := N(6 * u) + ' ' + N(2 * u) + ' ' + N(u) + ' ' + N(2 * u) + ' ' + N(u) + ' ' + N(2 * u);
  end;
  if dash <> '' then Result := Result + ' stroke-dasharray="' + dash + '"';
  case A.LineEnd of
    2: Result := Result + ' stroke-linecap="square"';
    3: Result := Result + ' stroke-linecap="round"';
  end;
  case A.LineJoin of
    1: Result := Result + ' stroke-linejoin="bevel"';
    2: Result := Result + ' stroke-linejoin="round"';
  end;
end;

procedure TMetPlayer.EmitStroke(const D: string);
begin
  if (D = '') or FMeasure then Exit;
  if (A.LineType = 8) or (A.Mix[1] = 5) then Exit;
  Put('<path d="' + D + '" fill="none"' + StrokeAttr(A.Col[1], LineWidthPx) + '/>');
end;

// Default pattern set as 8 x 8 pel tiles anchored at the output origin.
function TMetPlayer.PatternUrl(Sym: Integer; Fg, Bg: Cardinal; OpaqueBg: Boolean): string;
var
  key, id, def, d: string;
  x, y, i: Integer;
  bits: array[0..7, 0..7] of Boolean;
  cov: Integer;
begin
  key := IntToStr(Sym) + '_' + IntToHex(Fg, 6) + '_' + IntToStr(Ord(OpaqueBg)) + '_' + IntToHex(Bg, 6);
  i := FPatterns.IndexOfName(key);
  if i >= 0 then Exit('url(#' + FPatterns.ValueFromIndex[i] + ')');
  Inc(FDefSerial);
  id := 'pat' + IntToStr(FDefSerial);
  FillChar(bits, SizeOf(bits), 0);
  for y := 0 to 7 do
    for x := 0 to 7 do
      case Sym of
        1..8: begin
                cov := Round((9 - Sym) / 9 * 64);
                bits[y, x] := BAYER8[y, x] < cov;
              end;
        9:  bits[y, x] := x = 0;                                   // vertical
        10: bits[y, x] := y = 0;                                   // horizontal
        11: bits[y, x] := x = 7 - y;                               // "/" thin
        12: bits[y, x] := (x = 7 - y) or (x = (8 - y) and 7);      // "/" thick
        13: bits[y, x] := x = y;                                   // "\" thin
        14: bits[y, x] := (x = y) or (x = (y + 1) and 7);          // "\" thick
        17: bits[y, x] := ((x + y) and 1) = 0;                     // halftone
      else
        bits[y, x] := True;
      end;
  def := '<pattern id="' + id + '" patternUnits="userSpaceOnUse" x="0" y="0" width="8" height="8">';
  if OpaqueBg then
    def := def + '<path d="M0 0 h8 v8 h-8 Z" fill="' + Color(Bg) + '" stroke="none"/>';
  d := '';
  for y := 0 to 7 do
  begin
    x := 0;
    while x < 8 do
    begin
      if bits[y, x] then
      begin
        i := x;
        while (i < 8) and bits[y, i] do Inc(i);
        d := d + 'M' + IntToStr(x) + ' ' + IntToStr(y) + ' h' + IntToStr(i - x) + ' v1 h' + IntToStr(x - i) + ' Z ';
        x := i;
      end
      else Inc(x);
    end;
  end;
  if d <> '' then def := def + '<path d="' + Trim(d) + '" fill="' + Color(Fg) + '" stroke="none"/>';
  PutDef(def + '</pattern>');
  FPatterns.Add(key + '=' + id);
  Result := 'url(#' + id + ')';
end;

// fill paint of the pattern attributes; '' when nothing is filled
function TMetPlayer.FillAttr(const At: TAttrs): string;
var sym: Integer;
begin
  Result := '';
  sym := At.PatSym;
  if (sym = $0F) or (sym = $40) or (At.Mix[4] = 5) then Exit;
  if (At.PatSet <> 0) and (At.PatSet <> $FF) then sym := $10;    // custom pattern sets: solid
  if (sym = $10) or (sym = 0) or (sym > 17) or (sym = 15) or (sym = 16) then
    Result := ' fill="' + Color(At.Col[4]) + '"'
  else
    Result := ' fill="' + PatternUrl(sym, At.Col[4], At.BgCol[4], At.BgMix[4] = 2) + '"';
end;

procedure TMetPlayer.EmitFill(const D: string; const At: TAttrs; Boundary, NonZero: Boolean);
var f, s: string;
begin
  if (D = '') or FMeasure then Exit;
  f := FillAttr(At);
  if Boundary and (A.LineType <> 8) and (A.Mix[1] <> 5) then s := StrokeAttr(A.Col[1], LineWidthPx) else s := '';
  if (f = '') and (s = '') then Exit;
  if f = '' then f := ' fill="none"'
  else if NonZero then f := f + ' fill-rule="nonzero"'
  else f := f + ' fill-rule="evenodd"';
  if s = '' then s := ' stroke="none"';
  Put('<path d="' + D + '"' + f + s + '/>');
end;

// ---- drawing orders ----

procedure TMetPlayer.DoLine(Given: Boolean);
var x, y: Double;
begin
  if Given then
  begin
    if Left < 2 * CoordSize then Exit;
    RPt(x, y);
    A.CurX := x; A.CurY := y;
  end;
  if Left < 2 * CoordSize then begin OutPt(A.CurX, A.CurY); Exit; end;
  FigStart(A.CurX, A.CurY);
  while Left >= 2 * CoordSize do
  begin
    RPt(x, y);
    FigLine(x, y);
  end;
  A.CurX := FFigX; A.CurY := FFigY;
  FigDone;
end;

procedure TMetPlayer.DoRelLine(Given: Boolean);
var x, y: Double;
begin
  if Given then
  begin
    RPt(x, y);
    A.CurX := x; A.CurY := y;
  end;
  if Left < 2 then Exit;
  FigStart(A.CurX, A.CurY);
  x := A.CurX; y := A.CurY;
  while Left >= 2 do
  begin
    x := x + ShortInt(Byte(R8));
    y := y + ShortInt(Byte(R8));
    FigLine(x, y);
  end;
  A.CurX := x; A.CurY := y;
  FigDone;
end;

procedure TMetPlayer.DoBox(Given: Boolean);
var
  fl: Integer;
  x0, y0, x1, y1, h, v, rx, ry, l, r, t, b: Double;
  sb: TStringBuilder;
  fa: TAttrs;
begin
  fl := R8; R8;
  if Given then RPt(x0, y0) else begin x0 := A.CurX; y0 := A.CurY; end;
  RPt(x1, y1);
  h := 0; v := 0;
  if Left >= CoordSize then
  begin
    h := Abs(RC);
    if Left >= CoordSize then v := Abs(RC) else v := h;
  end;
  if Given then begin A.CurX := x0; A.CurY := y0; end;
  l := Min(x0, x1); r := Max(x0, x1); b := Min(y0, y1); t := Max(y0, y1);
  rx := Min(h / 2, (r - l) / 2); ry := Min(v / 2, (t - b) / 2);
  if (h = 0) or (v = 0) then begin rx := 0; ry := 0; end;
  if Standalone then
  begin
    if FMeasure then begin OutPt(l, b); OutPt(r, t); Exit; end;
  end;
  if (rx > 0) and (ry > 0) then
  begin
    FigStart(r - rx, b);
    FigArc(r - rx, b + ry, rx, 0, 0, ry, -Pi / 2, Pi / 2, 0);
    FigLine(r, t - ry);
    FigArc(r - rx, t - ry, rx, 0, 0, ry, 0, Pi / 2, 0);
    FigLine(l + rx, t);
    FigArc(l + rx, t - ry, rx, 0, 0, ry, Pi / 2, Pi / 2, 0);
    FigLine(l, b + ry);
    FigArc(l + rx, b + ry, rx, 0, 0, ry, Pi, Pi / 2, 0);
  end
  else
  begin
    FigStart(l, b);
    FigLine(r, b); FigLine(r, t); FigLine(l, t);
  end;
  FigClose;
  if Standalone then
  begin
    // FLAGS: $40 = fill with the pattern attributes, $20 = draw the outline
    sb := FLoose;
    if (fl and $60) = 0 then fl := $20;
    fa := A;
    if (fl and $40) = 0 then fa.PatSym := $0F;
    EmitFill(Trim(sb.ToString), fa, (fl and $20) <> 0, False);
    sb.Clear;
  end;
end;

procedure TMetPlayer.DoFillet(Given: Boolean);
var
  pts: array of Double;
  n, i: Integer;
  x, y, mx, my: Double;
begin
  n := 0;
  SetLength(pts, 0);
  if not Given then
  begin
    SetLength(pts, 2); pts[0] := A.CurX; pts[1] := A.CurY; n := 1;
  end;
  while Left >= 2 * CoordSize do
  begin
    RPt(x, y);
    SetLength(pts, 2 * n + 2);
    pts[2 * n] := x; pts[2 * n + 1] := y;
    Inc(n);
  end;
  if n = 0 then Exit;
  A.CurX := pts[2 * n - 2]; A.CurY := pts[2 * n - 1];
  if n = 1 then begin OutPt(A.CurX, A.CurY); Exit; end;
  FigStart(pts[0], pts[1]);
  if n = 2 then FigLine(pts[2], pts[3])
  else
    for i := 1 to n - 2 do
    begin
      if i = n - 2 then begin mx := pts[2 * n - 2]; my := pts[2 * n - 1]; end
      else begin mx := (pts[2 * i] + pts[2 * i + 2]) / 2; my := (pts[2 * i + 1] + pts[2 * i + 3]) / 2; end;
      FigConic(pts[2 * i], pts[2 * i + 1], mx, my, 1);
    end;
  FigDone;
end;

// Sharp fillet: pairs of points (control, end) followed by one FIXED
// sharpness (conic weight) per pair.
procedure TMetPlayer.DoSharpFillet(Given: Boolean);
var
  k, i, ps: Integer;
  pts: array of Double;
  w: Double;
begin
  if Given then RPt(A.CurX, A.CurY);
  ps := 2 * CoordSize;
  k := Left div (2 * ps + 4);
  if k <= 0 then begin OutPt(A.CurX, A.CurY); Exit; end;
  SetLength(pts, 4 * k);
  for i := 0 to 2 * k - 1 do RPt(pts[2 * i], pts[2 * i + 1]);
  FigStart(A.CurX, A.CurY);
  for i := 0 to k - 1 do
  begin
    w := RS32 / 65536;
    FigConic(pts[4 * i], pts[4 * i + 1], pts[4 * i + 2], pts[4 * i + 3], w);
  end;
  A.CurX := FFigX; A.CurY := FFigY;
  FigDone;
end;

procedure TMetPlayer.DoBezier(Given: Boolean);
var x1, y1, x2, y2, x3, y3: Double;
begin
  if Given then RPt(A.CurX, A.CurY);
  if Left < 6 * CoordSize then begin OutPt(A.CurX, A.CurY); Exit; end;
  FigStart(A.CurX, A.CurY);
  while Left >= 6 * CoordSize do
  begin
    RPt(x1, y1); RPt(x2, y2); RPt(x3, y3);
    FigCubic(x1, y1, x2, y2, x3, y3);
  end;
  A.CurX := FFigX; A.CurY := FFigY;
  FigDone;
end;

// Arc through three points on an ellipse of the shape given by the arc
// parameters: the points are taken back to the unit-circle space, where the
// arc is circular.
procedure TMetPlayer.DoArc3(Given: Boolean);
var
  x1, y1, x2, y2, x3, y3, det, i11, i12, i21, i22: Double;
  u1, v1, u2, v2, u3, v3, dd, cx, cy, r, a1, a2, a3, s, d2: Double;
begin
  if Given then RPt(x1, y1) else begin x1 := A.CurX; y1 := A.CurY; end;
  RPt(x2, y2); RPt(x3, y3);
  A.CurX := x3; A.CurY := y3;
  det := A.ArcP * A.ArcQ - A.ArcR * A.ArcS;
  FigStart(x1, y1);
  if Abs(det) < 1e-12 then
  begin
    FigLine(x2, y2); FigLine(x3, y3);
    FigDone;
    Exit;
  end;
  // inverse of [P R; S Q]
  i11 := A.ArcQ / det; i12 := -A.ArcR / det;
  i21 := -A.ArcS / det; i22 := A.ArcP / det;
  u1 := i11 * x1 + i12 * y1; v1 := i21 * x1 + i22 * y1;
  u2 := i11 * x2 + i12 * y2; v2 := i21 * x2 + i22 * y2;
  u3 := i11 * x3 + i12 * y3; v3 := i21 * x3 + i22 * y3;
  dd := 2 * (u1 * (v2 - v3) + u2 * (v3 - v1) + u3 * (v1 - v2));
  if Abs(dd) < 1e-9 * Max(1, Abs(u1) + Abs(v1) + Abs(u3) + Abs(v3)) then
  begin
    FigLine(x2, y2); FigLine(x3, y3);
    FigDone;
    Exit;
  end;
  cx := ((u1 * u1 + v1 * v1) * (v2 - v3) + (u2 * u2 + v2 * v2) * (v3 - v1) + (u3 * u3 + v3 * v3) * (v1 - v2)) / dd;
  cy := ((u1 * u1 + v1 * v1) * (u3 - u2) + (u2 * u2 + v2 * v2) * (u1 - u3) + (u3 * u3 + v3 * v3) * (u2 - u1)) / dd;
  r := Hypot(u1 - cx, v1 - cy);
  a1 := ArcTan2(v1 - cy, u1 - cx);
  a2 := ArcTan2(v2 - cy, u2 - cx);
  a3 := ArcTan2(v3 - cy, u3 - cx);
  s := a3 - a1; while s <= 0 do s := s + 2 * Pi; while s > 2 * Pi do s := s - 2 * Pi;
  d2 := a2 - a1; while d2 < 0 do d2 := d2 + 2 * Pi; while d2 >= 2 * Pi do d2 := d2 - 2 * Pi;
  if d2 > s then s := s - 2 * Pi;       // clockwise through the middle point
  FigArc(A.ArcP * cx + A.ArcR * cy, A.ArcS * cx + A.ArcQ * cy,
    A.ArcP * r, A.ArcR * r, A.ArcS * r, A.ArcQ * r, a1, s, 0);
  FigDone;
end;

function ReadMultiplier(P: TMetPlayer; Bytes: Integer): Double;
begin
  if Bytes >= 4 then Result := P.R32 / 65536
  else Result := P.R16 / 256;
end;

procedure TMetPlayer.DoFullArc(Given: Boolean);
var cx, cy, m: Double;
begin
  if Given then RPt(cx, cy) else begin cx := A.CurX; cy := A.CurY; end;
  m := ReadMultiplier(Self, Left);
  A.CurX := cx; A.CurY := cy;
  if m = 0 then Exit;
  FigArc(cx, cy, A.ArcP * m, A.ArcR * m, A.ArcS * m, A.ArcQ * m, 0, 2 * Pi, 1);
  FigClose;
  FigDone;
end;

procedure TMetPlayer.DoPartialArc(Given: Boolean);
var x0, y0, cx, cy, m, st, sw: Double;
begin
  if Given then RPt(x0, y0) else begin x0 := A.CurX; y0 := A.CurY; end;
  RPt(cx, cy);
  m := ReadMultiplier(Self, Left - 8);
  st := RS32 / 65536; sw := RS32 / 65536;
  FigStart(x0, y0);
  FigArc(cx, cy, A.ArcP * m, A.ArcR * m, A.ArcS * m, A.ArcQ * m, DegToRad(st), DegToRad(sw), 2);
  A.CurX := FFigX; A.CurY := FFigY;
  FigDone;
end;

// GpiPolygons: FLAGS (1 = boundary, 2 = winding), then polygons of points;
// the first polygon starts at the current position.
procedure TMetPlayer.DoPolygons;
var
  fl, np, i, j, cnt: Integer;
  x, y: Double;
  keep: TAttrs;
begin
  fl := R8;
  np := Integer(R32);
  if (np <= 0) or (np > 65535) then Exit;
  if Standalone then FLoose.Clear;
  for i := 0 to np - 1 do
  begin
    cnt := Integer(R32);
    if (cnt < 0) or (Int64(cnt) * 2 * CoordSize > Left) then Break;
    if i = 0 then FigStart(A.CurX, A.CurY)
    else
    begin
      if cnt = 0 then Continue;
      RPt(x, y); Dec(cnt);
      if not Standalone then FFigOpen := False;
      if Standalone then
      begin
        Target.Append('M').Append(OutPt(x, y)).Append(' ');
        FFigX := x; FFigY := y;
      end
      else FigStart(x, y);
    end;
    for j := 0 to cnt - 1 do
    begin
      RPt(x, y);
      FigLine(x, y);
    end;
    A.CurX := FFigX; A.CurY := FFigY;
    FigClose;
  end;
  if Standalone then
  begin
    keep := A;
    EmitFill(Trim(FLoose.ToString), keep, (fl and 1) <> 0, (fl and 2) <> 0);
    FLoose.Clear;
  end;
end;

procedure TMetPlayer.DoMarker(Given: Boolean);
var
  x, y, ox, oy, hx, hy, tx, ty: Double;
  d, st, fl: string;
  first, filled: Boolean;

  procedure Pt(px, py: Double; Mv: Boolean);
  begin
    if Mv then d := d + 'M' else d := d + 'L';
    d := d + N(ox + px * hx) + ' ' + N(oy + py * hy) + ' ';
  end;

  procedure Poly(const P: array of Double);
  var i: Integer;
  begin
    for i := 0 to Length(P) div 2 - 1 do Pt(P[2 * i], P[2 * i + 1], i = 0);
    d := d + 'Z ';
  end;

  procedure Circle(r: Double);
  var k: Double;
  begin
    k := 0.5523 * r;
    d := d + 'M' + N(ox + r * hx) + ' ' + N(oy) +
      ' C' + N(ox + r * hx) + ' ' + N(oy + k * hy) + ' ' + N(ox + k * hx) + ' ' + N(oy + r * hy) + ' ' + N(ox) + ' ' + N(oy + r * hy) +
      ' C' + N(ox - k * hx) + ' ' + N(oy + r * hy) + ' ' + N(ox - r * hx) + ' ' + N(oy + k * hy) + ' ' + N(ox - r * hx) + ' ' + N(oy) +
      ' C' + N(ox - r * hx) + ' ' + N(oy - k * hy) + ' ' + N(ox - k * hx) + ' ' + N(oy - r * hy) + ' ' + N(ox) + ' ' + N(oy - r * hy) +
      ' C' + N(ox + k * hx) + ' ' + N(oy - r * hy) + ' ' + N(ox + r * hx) + ' ' + N(oy - k * hy) + ' ' + N(ox + r * hx) + ' ' + N(oy) + ' Z ';
  end;

begin
  if (A.MkW > 0) and (A.MkH > 0) then
  begin
    hx := A.MkW * Abs(SX * FVA) / 2; hy := A.MkH * Abs(SY * FVD) / 2;
  end
  else begin hx := DEF_MARKER_PX / 2; hy := DEF_MARKER_PX / 2; end;
  first := True;
  while first or (Left >= 2 * CoordSize) do
  begin
    if first and not Given then begin x := A.CurX; y := A.CurY; end
    else RPt(x, y);
    first := False;
    A.CurX := x; A.CurY := y;
    OutPt(x, y);
    if FMeasure or (A.Mix[3] = 5) then Continue;
    Xf(x, y, tx, ty);
    ox := MX(tx); oy := MY(ty);
    d := '';
    filled := False;
    case A.MkSym of
      2: begin Pt(-1, 0, True); Pt(1, 0, False); Pt(0, -1, True); Pt(0, 1, False); end;
      3: Poly([0, -1, 1, 0, 0, 1, -1, 0]);
      4: Poly([-1, -1, 1, -1, 1, 1, -1, 1]);
      5: Poly([0, -1, 0.3, -0.5, 0.87, -0.5, 0.58, 0, 0.87, 0.5, 0.3, 0.5,
               0, 1, -0.3, 0.5, -0.87, 0.5, -0.58, 0, -0.87, -0.5, -0.3, -0.5]);
      6: Poly([0, -1, 0.25, -0.6, 0.7, -0.7, 0.6, -0.25, 1, 0, 0.6, 0.25, 0.7, 0.7, 0.25, 0.6,
               0, 1, -0.25, 0.6, -0.7, 0.7, -0.6, 0.25, -1, 0, -0.6, -0.25, -0.7, -0.7, -0.25, -0.6]);
      7: begin Poly([0, -1, 1, 0, 0, 1, -1, 0]); filled := True; end;
      8: begin Poly([-1, -1, 1, -1, 1, 1, -1, 1]); filled := True; end;
      9: begin Circle(0.3); filled := True; end;
      10: Circle(0.6);
      $40: ;
    else
      begin Pt(-1, -1, True); Pt(1, 1, False); Pt(-1, 1, True); Pt(1, -1, False); end;
    end;
    if d = '' then Continue;
    if filled then fl := ' fill="' + Color(A.Col[3]) + '"' else fl := ' fill="none"';
    st := ' stroke="' + Color(A.Col[3]) + '" stroke-width="1"';
    Put('<path d="' + Trim(d) + '"' + fl + st + '/>');
  end;
end;

// Character strings: GCHST / GCCHST, their "move" forms that advance the
// current position, and the extended form (GpiCharStringPosAt) with a
// rectangle, options and optional increments.
procedure TMetPlayer.DoText(Given, Move, Ext: Boolean);
var
  x, y, sizeW, sizePx, ang, deg, cw, adv, ox, oy, pos, tx, ty, ks: Double;
  sizeKnown: Boolean;
  flags, cnt, i, fi, k: Integer;
  chars: TStringArray;
  incs: array of Double;
  hasInc, bold, italic, under, strike: Boolean;
  face, st, xs, ys, txt: string;

  function MapFace(const F: string): string;
  var L: string;
  begin
    L := LowerCase(Trim(F));
    if (L = '') or (L = 'system proportional') or (L = 'helv') or (L = 'helvetica') or
       (L = 'swiss') or (L = 'warpsans') then Result := 'Arial'
    else if (L = 'tms rmn') or (L = 'times new roman') or (L = 'times') or (L = 'roman') or
       (L = 'times new roman wt') then Result := 'Times New Roman'
    else if (L = 'courier') or (L = 'system monospaced') or (L = 'system vio') or
       (L = 'courier new') then Result := 'Courier New'
    else Result := Trim(F);
  end;

begin
  if Given then RPt(x, y) else begin x := A.CurX; y := A.CurY; end;
  flags := 0;
  hasInc := False;
  if Ext then
  begin
    flags := R16;
    R8; R8; R8; R8;                               // rectangle (two points)
    for i := 1 to 4 * CoordSize - 4 do R8;
    cnt := R16;
    cnt := Max(0, Min(cnt, Left));
  end
  else cnt := Max(0, Left);
  chars := DecodeText(B, FP, cnt, TextCp);
  Inc(FP, cnt);
  cnt := Length(chars);
  if Ext and (cnt > 0) and (Left >= cnt * CoordSize) then
  begin
    hasInc := True;
    SetLength(incs, cnt);
    for i := 0 to cnt - 1 do incs[i] := RC;
  end;
  A.CurX := x; A.CurY := y;
  // font
  fi := -1;
  for i := 0 to High(FDoc^.Fonts) do
    if FDoc^.Fonts[i].Lid = A.ChSet then begin fi := i; Break; end;
  face := ''; bold := False; italic := False; under := False; strike := False;
  sizeW := 0; cw := 0;
  if fi >= 0 then
  begin
    face := FDoc^.Fonts[fi].Face;
    bold := FDoc^.Fonts[fi].Bold;
    italic := FDoc^.Fonts[fi].Italic;
    under := FDoc^.Fonts[fi].Under;
    strike := FDoc^.Fonts[fi].Strike;
    sizeW := FDoc^.Fonts[fi].H;
    cw := FDoc^.Fonts[fi].W;
  end;
  if A.CellH <> 0 then sizeW := Abs(A.CellH);
  if A.CellW <> 0 then cw := Abs(A.CellW);
  // the cell is the em box: an average character advances about half of it
  cw := 0.55 * cw;
  sizeKnown := sizeW > 0;
  if sizeKnown then sizePx := sizeW * Abs(SY)
  else begin sizePx := DEF_TEXT_PX; sizeW := DEF_TEXT_PX / Max(Abs(SY), 1e-12); end;
  if (A.ShearY <> 0) and (Abs(A.ShearX / A.ShearY) > 0.05) then italic := True;
  if (flags and $0200) <> 0 then under := True;
  if (flags and $0400) <> 0 then strike := True;
  ang := ArcTan2(A.ChAngY, A.ChAngX);
  if cw <= 0 then cw := 0.55 * sizeW;
  if A.ChDir in [2, 4] then cw := sizeW;
  // advance of the whole string, world units
  adv := 0;
  if hasInc then for i := 0 to cnt - 1 do adv := adv + incs[i]
  else adv := cnt * cw;
  if not sizeKnown and FMeasure then
    OutPt(x, y)      // the size depends on the scale being measured for
  else if A.ChDir in [2, 4] then
  begin
    // vertical strings: the baseline position moves by the cell height
    OutPt(x, y);
    FNoSample := True;
    OutPt(x + cw * Cos(ang), y + cw * Sin(ang));
    if A.ChDir = 2 then k := -1 else k := 1;
    OutPt(x - k * Sin(ang) * cnt * sizeW, y + k * Cos(ang) * cnt * sizeW);
    FNoSample := False;
  end
  else
  begin
    OutPt(x, y);
    FNoSample := True;
    OutPt(x + adv * Cos(ang) - Sin(ang) * sizeW, y + adv * Sin(ang) + Cos(ang) * sizeW);
    OutPt(x + adv * Cos(ang), y + adv * Sin(ang));
    FNoSample := False;
  end;
  if Move or Ext then
  begin
    if A.ChDir = 3 then begin A.CurX := x - adv * Cos(ang); A.CurY := y - adv * Sin(ang); end
    else if not (A.ChDir in [2, 4]) then begin A.CurX := x + adv * Cos(ang); A.CurY := y + adv * Sin(ang); end;
  end;
  if FMeasure or (cnt = 0) or FInPath or (A.Mix[2] = 5) then Exit;

  // through the model transform: origin, baseline direction and size
  Xf(x, y, tx, ty);
  ox := MX(tx); oy := MY(ty);
  ang := ArcTan2(FVD * (A.MB * Cos(ang) + A.MD * Sin(ang)), FVA * (A.MA * Cos(ang) + A.MC * Sin(ang)));
  ks := Sqrt(Abs(A.MA * A.MD - A.MB * A.MC)) * ViewScale;
  if ks <= 0 then ks := 1;
  sizePx := sizePx * ks;
  deg := -RadToDeg(ang);
  // opaque background rectangle of GpiCharStringPosAt (CHS_OPAQUE)
  txt := '';
  xs := ''; ys := '';
  case A.ChDir of
    2, 4:
      begin
        for i := 0 to cnt - 1 do
        begin
          if i > 0 then begin xs := xs + ' '; ys := ys + ' '; end;
          xs := xs + N(ox);
          if A.ChDir = 2 then pos := oy + i * sizePx else pos := oy - i * sizePx;
          ys := ys + N(pos);
          txt := txt + chars[i];
        end;
      end;
    3:
      begin
        pos := ox;
        for i := 0 to cnt - 1 do
        begin
          if i > 0 then xs := xs + ' ';
          if hasInc then pos := pos - incs[i] * Abs(SX) * ks else pos := pos - cw * Abs(SX) * ks;
          xs := xs + N(pos);
          txt := txt + chars[i];
        end;
        ys := N(oy);
      end;
  else
    begin
      if hasInc then
      begin
        pos := ox;
        for i := 0 to cnt - 1 do
        begin
          if i > 0 then xs := xs + ' ';
          xs := xs + N(pos);
          pos := pos + incs[i] * Abs(SX) * ks;
        end;
      end
      else xs := N(ox);
      ys := N(oy);
      for i := 0 to cnt - 1 do txt := txt + chars[i];
    end;
  end;
  if ((flags and 1) <> 0) and Ext then
  begin
    st := '<path d="M' + N(ox) + ' ' + N(oy + 0.25 * sizePx) + ' h' + N(adv * Abs(SX) * ks) + ' v' + N(-sizePx) +
      ' h' + N(-adv * Abs(SX) * ks) + ' Z" fill="' + Color(A.BgCol[2]) + '" stroke="none"';
    if Abs(deg) > 0.01 then
      st := st + ' transform="rotate(' + N(deg) + ' ' + N(ox) + ' ' + N(oy) + ')"';
    Put(st + '/>');
  end;
  st := '<text x="' + xs + '" y="' + ys + '" font-family="' + XmlEscape(MapFace(face)) +
    '" font-size="' + N(EnsureRange(sizePx, 0.5, 1e5)) + '"';
  if bold then st := st + ' font-weight="bold"';
  if italic then st := st + ' font-style="italic"';
  if under and strike then st := st + ' text-decoration="underline line-through"'
  else if under then st := st + ' text-decoration="underline"'
  else if strike then st := st + ' text-decoration="line-through"';
  if not hasInc and not (A.ChDir in [2, 3, 4]) then
    case A.TxtH of
      3: st := st + ' text-anchor="middle"';
      4: st := st + ' text-anchor="end"';
    end;
  case A.TxtV of
    2: st := st + ' dominant-baseline="text-before-edge"';
    3: st := st + ' dominant-baseline="central"';
    5: st := st + ' dominant-baseline="text-after-edge"';
  end;
  st := st + ' fill="' + Color(A.Col[2]) + '"';
  if Abs(deg) > 0.01 then
    st := st + ' transform="rotate(' + N(deg) + ' ' + N(ox) + ' ' + N(oy) + ')"';
  Put(st + ' xml:space="preserve">' + XmlEscape(txt) + '</text>');
end;

// code page of the current character set's font
function TMetPlayer.TextCp: Integer;
var i: Integer;
begin
  Result := FDoc^.DefCp;
  for i := 0 to High(FDoc^.Fonts) do
    if FDoc^.Fonts[i].Lid = A.ChSet then
    begin
      if FDoc^.Fonts[i].Cp <> 0 then Result := FDoc^.Fonts[i].Cp;
      Exit;
    end;
end;

procedure TMetPlayer.DoBeginArea;
begin
  FAreaFlags := R8;
  FInArea := True;
  FAreaSB.Clear;
  FFigOpen := False;
  FAreaA := A;
end;

procedure TMetPlayer.DoEndArea;
var
  d: string;
  keep: TAttrs;
begin
  if not FInArea then Exit;
  if FFigOpen then FAreaSB.Append('Z ');
  FFigOpen := False;
  FInArea := False;
  d := Trim(FAreaSB.ToString);
  FAreaSB.Clear;
  if d = '' then Exit;
  if FInPath then
  begin
    FPathSB.Append(d).Append(' ');
    Exit;
  end;
  keep := FAreaA;
  keep.Mix[4] := FAreaA.Mix[4];
  EmitFill(d, keep, (FAreaFlags and $40) <> 0, (FAreaFlags and $20) <> 0);
end;

procedure TMetPlayer.DoBeginPath;
begin
  R16;
  FPathId := R32;
  FInPath := True;
  FPathSB.Clear;
  FFigOpen := False;
end;

function TMetPlayer.FindPath(Id: Cardinal): Integer;
var i: Integer;
begin
  for i := 0 to High(Paths) do
    if Paths[i].Id = Id then Exit(i);
  Result := -1;
end;

procedure TMetPlayer.DoEndPath;
var i: Integer;
begin
  if not FInPath then Exit;
  if FInArea then DoEndArea;
  FInPath := False;
  FFigOpen := False;
  i := FindPath(FPathId);
  if i < 0 then
  begin
    i := Length(Paths);
    SetLength(Paths, i + 1);
  end;
  Paths[i].Id := FPathId;
  Paths[i].D := Trim(FPathSB.ToString);
  Paths[i].Stroked := False;
  FPathSB.Clear;
end;

procedure TMetPlayer.DoFillPath;
var
  fl, i: Integer;
  id: Cardinal;
  w: Double;
  s: string;
begin
  fl := R16;
  id := R32;
  i := FindPath(id);
  if (i < 0) or (Paths[i].D = '') or FMeasure then Exit;
  if (fl and $20) <> 0 then Exit;
  if Paths[i].Stroked then
  begin
    // a path widened by Modify Path: its outline area is the stroke
    if A.Mix[4] = 5 then Exit;
    w := Max(A.GeomW * Scale * ViewScale, 1);
    s := ' stroke="' + Color(A.Col[4]) + '" stroke-width="' + N(w) + '"';
    case A.LineEnd of
      2: s := s + ' stroke-linecap="square"';
      3: s := s + ' stroke-linecap="round"';
    end;
    case A.LineJoin of
      1: s := s + ' stroke-linejoin="bevel"';
      2: s := s + ' stroke-linejoin="round"';
    end;
    Put('<path d="' + Paths[i].D + '" fill="none"' + s + '/>');
  end
  else
    EmitFill(Paths[i].D, A, False, (fl and $40) <> 0);
end;

procedure TMetPlayer.DoOutlinePath;
var
  i: Integer;
  id: Cardinal;
begin
  R16;
  id := R32;
  i := FindPath(id);
  if (i < 0) or FMeasure then Exit;
  EmitStroke(Paths[i].D);
end;

procedure TMetPlayer.DoModifyPath;
var
  i: Integer;
  id: Cardinal;
begin
  id := 1;
  if Left >= 6 then begin R16; id := R32; end;
  i := FindPath(id);
  if i < 0 then i := FindPath(1);
  if i >= 0 then Paths[i].Stroked := True;
end;

procedure TMetPlayer.DoClipPath;
var
  fl, i: Integer;
  id: Cardinal;
begin
  fl := R16;
  id := R32;
  i := FindPath(id);
  if (id = 0) or (i < 0) or (Paths[i].D = '') then
  begin
    if FClipD = '' then Exit;
    FClipD := '';
  end
  else
  begin
    FClipD := Paths[i].D;
    if (fl and $40) <> 0 then FClipRule := 'nonzero' else FClipRule := 'evenodd';
  end;
  Inc(FClipSerial);
end;

// GOCA bilevel image: one Image Data order per row, B'1' = image colour.
procedure TMetPlayer.DoBeginImage(Given: Boolean);
var i: Integer;
begin
  if Given then RPt(FImgX, FImgY) else begin FImgX := A.CurX; FImgY := A.CurY; end;
  R8; R8;
  FImgW := R16; FImgH := R16;
  A.CurX := FImgX; A.CurY := FImgY;
  FImgOn := (FImgW > 0) and (FImgH > 0);
  FImgRow := 0;
  for i := 0 to FImgRuns.Count - 1 do FImgRuns.Objects[i].Free;
  FImgRuns.Clear;
  OutPt(FImgX, FImgY);
  OutPt(FImgX + FImgW / Max(Abs(SX), 1e-12), FImgY - FImgH / Max(Abs(SY), 1e-12));
end;

procedure TMetPlayer.DoImageData;
var
  x, nb, run: Integer;
  ox, oy: Double;
  bits: TBytes;
  sb: TStringBuilder;
  key: string;
  i: Integer;
  bg: Boolean;

  function Bit(k: Integer): Boolean;
  begin
    Result := (k div 8 < Length(bits)) and (((bits[k div 8] shr (7 - k mod 8)) and 1) <> 0);
  end;

  procedure AddSeg(c: Cardinal; x0, cnt: Integer);
  begin
    key := IntToHex(c, 6);
    i := FImgRuns.IndexOf(key);
    if i < 0 then i := FImgRuns.AddObject(key, TStringBuilder.Create);
    sb := TStringBuilder(FImgRuns.Objects[i]);
    sb.Append('M').Append(N(ox + x0)).Append(' ').Append(N(oy)).Append(' h').Append(IntToStr(cnt))
      .Append(' v1 h').Append(IntToStr(-cnt)).Append(' Z ');
  end;

begin
  if not FImgOn or FMeasure or (FImgRow >= FImgH) then begin Inc(FImgRow); Exit; end;
  nb := Left;
  SetLength(bits, Max(nb, 0));
  for x := 0 to nb - 1 do bits[x] := R8;
  Xf(FImgX, FImgY, ox, oy);
  ox := MX(ox); oy := MY(oy) + FImgRow;
  bg := A.BgMix[5] = 2;
  x := 0;
  while x < FImgW do
  begin
    run := 1;
    while (x + run < FImgW) and (Bit(x + run) = Bit(x)) do Inc(run);
    if Bit(x) then begin if A.Mix[5] <> 5 then AddSeg(A.Col[5], x, run); end
    else if bg then AddSeg(A.BgCol[5], x, run);
    Inc(x, run);
  end;
  Inc(FImgRow);
end;

procedure TMetPlayer.DoEndImage;
var i: Integer; s: string;
begin
  if FImgOn and not FMeasure then
  begin
    s := '';
    for i := 0 to FImgRuns.Count - 1 do
    begin
      s := s + '<path d="' + Trim(TStringBuilder(FImgRuns.Objects[i]).ToString) + '" fill="#' +
        FImgRuns[i] + '" stroke="none"/>';
      FImgRuns.Objects[i].Free;
    end;
    FImgRuns.Clear;
    if s <> '' then Put(s);
  end;
  FImgOn := False;
end;

// Bitmaps become runs of equal-coloured rects (SimpleSVG has no <image>).
procedure TMetPlayer.DrawBitmap(const Img: TRGBAImage; x0, y0, x1, y1: Double);
var
  cols, rows, i, j, run, px, py: Integer;
  cw, ch, f, t: Double;
  c: Cardinal;
  runs: TStringList;
  sb: TStringBuilder;
  key, s: string;

  function Sample(ci, ri: Integer): Cardinal;
  begin
    px := Trunc((ci + 0.5) * Img.W / cols);
    py := Trunc((ri + 0.5) * Img.H / rows);
    Result := Img.Px[Min(py, Img.H - 1) * Img.W + Min(px, Img.W - 1)];
  end;

begin
  if (Img.W <= 0) or (Img.H <= 0) or FMeasure then Exit;
  if x1 < x0 then begin t := x0; x0 := x1; x1 := t; end;
  if y1 < y0 then begin t := y0; y0 := y1; y1 := t; end;
  cols := Max(1, Min(Img.W, Ceil(x1 - x0)));
  rows := Max(1, Min(Img.H, Ceil(y1 - y0)));
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
        while (i + run < cols) and (Sample(i + run, j) = c) do Inc(run);
        if (c shr 24) >= 128 then
        begin
          key := IntToHex(c and $FFFFFF, 6);
          px := runs.IndexOf(key);
          if px < 0 then px := runs.AddObject(key, TStringBuilder.Create);
          sb := TStringBuilder(runs.Objects[px]);
          sb.Append('M').Append(N(x0 + i * cw)).Append(' ').Append(N(y0 + j * ch)).Append(' h')
            .Append(N(run * cw)).Append(' v').Append(N(ch)).Append(' h').Append(N(-run * cw)).Append(' Z ');
        end;
        Inc(i, run);
      end;
    end;
    s := '';
    for i := 0 to runs.Count - 1 do
    begin
      s := s + '<path d="' + Trim(TStringBuilder(runs.Objects[i]).ToString) + '" fill="#' + runs[i] +
        '" stroke="none"/>';
      runs.Objects[i].Free;
    end;
    runs.Clear;
    if s <> '' then Put(s);
  finally
    runs.Free;
  end;
end;

// Bit Blt: draws an image object (identified by its bitmap handle) into
// the target rectangle.
procedure TMetPlayer.DoBitBlt;
var
  id: Cardinal;
  x0, y0, x1, y1: Double;
  i, k: Integer;
begin
  R32;
  id := R32;
  R32;
  RPt(x0, y0); RPt(x1, y1);
  OutPt(x0, y0); OutPt(x1, y1);
  if FMeasure or (A.Mix[5] = 5) then Exit;
  k := -1;
  for i := 0 to High(FDoc^.Bitmaps) do
    if FDoc^.Bitmaps[i].Id = id then begin k := i; Break; end;
  if (k < 0) and (Length(FDoc^.Bitmaps) = 1) then k := 0;
  if k < 0 then Exit;
  Xf(x0, y0, x0, y0); Xf(x1, y1, x1, y1);
  DrawBitmap(FDoc^.Bitmaps[k].Img, MX(x0), MY(y0), MX(x1), MY(y1));
end;

procedure TMetPlayer.Order(Code, Len: Integer);
const
  // push-and-set order -> set order
  PushMap: array[0..34, 0..1] of Integer = (
    ($54, $14), ($4A, $0A), ($E6, $A6), ($66, $26), ($65, $25), ($E7, $A7), ($4C, $0C),
    ($4D, $0D), ($48, $08), ($09, $28), ($E0, $A0), ($5A, $1A), ($5B, $1B), ($58, $18),
    ($59, $19), ($51, $11), ($55, $15), ($7A, $3A), ($79, $39), ($78, $38), ($74, $34),
    ($45, $05), ($03, $33), ($57, $17), ($75, $35), ($76, $36), ($7B, $3B), ($7C, $3C),
    ($69, $29), ($77, $37), ($62, $22), ($61, $21), ($64, $24), ($23, $43), ($67, $27));
var i: Integer;
begin
  for i := 0 to High(PushMap) do
    if PushMap[i, 0] = Code then
    begin
      Push(PushMap[i, 1]);
      SetAttr(PushMap[i, 1], Len);
      Exit;
    end;
  case Code of
    $C1: DoLine(True);
    $81: DoLine(False);
    $E1: DoRelLine(True);
    $A1: DoRelLine(False);
    $C0: DoBox(True);
    $80: DoBox(False);
    $C5: DoFillet(True);
    $85: DoFillet(False);
    $E4: DoSharpFillet(True);
    $A4: DoSharpFillet(False);
    $E5: DoBezier(True);
    $A5: DoBezier(False);
    $C6: DoArc3(True);
    $86: DoArc3(False);
    $C7: DoFullArc(True);
    $87: DoFullArc(False);
    $E3: DoPartialArc(True);
    $A3: DoPartialArc(False);
    $F3: DoPolygons;
    $C2: DoMarker(True);
    $82: DoMarker(False);
    $C3: DoText(True, False, False);
    $83: DoText(False, False, False);
    $F1: DoText(True, True, False);
    $B1: DoText(False, True, False);
    $FEF0: DoText(True, False, True);
    $FEB0: DoText(False, False, True);
    $68: DoBeginArea;
    $60: DoEndArea;
    $D0: DoBeginPath;
    $7F: DoEndPath;
    $D7: DoFillPath;
    $D4: DoOutlinePath;
    $D8: DoModifyPath;
    $B4: DoClipPath;
    $7D: begin
           if FFigOpen then FigClose;
           // the current position returns to the start of the figure
         end;
    $D1: DoBeginImage(True);
    $91: DoBeginImage(False);
    $92: DoImageData;
    $93: DoEndImage;
    $D6: DoBitBlt;
    $FED5: DoEscape;
    $27: DoViewWindow;
    $3F: Pop;
  else
    SetAttr(Code, Len);
  end;
end;

// Set Current Defaults (in the descriptor): SET, MASK (bit 0 = most
// significant), FLAGS ($80 = values follow), then the values of the masked
// items in bit order. Line, character, marker and arc attribute sets and
// the default model transform (set 7) are taken; items not understood end
// the instruction.
procedure TMetPlayer.ReadScd;
var
  st, mask, fl, v: Integer;
  x, y: Double;

  function Has(Bit: Integer): Boolean;
  begin
    Result := (mask and ($8000 shr Bit)) <> 0;
  end;

begin
  st := R8;
  mask := R8 shl 8;
  mask := mask or R8;
  fl := R8;
  if (fl and $80) = 0 then Exit;       // standard defaults: already in force
  case st of
    1: begin
         if Has(0) then begin v := R8; if v <> 0 then DefA.LineType := v; end;
         if Has(1) then begin v := R8; if v <> 0 then DefA.LineW := v; end;
         if Has(2) then DefA.LineEnd := R8;
         if Has(3) then DefA.LineJoin := R8;
       end;
    2: begin
         if Has(0) then
         begin
           RPt(x, y);
           if (x <> 0) or (y <> 0) then begin DefA.ChAngX := x; DefA.ChAngY := y; end;
         end;
         if Has(1) then begin RPt(x, y); DefA.CellW := x; DefA.CellH := y; end;
         if Has(2) then begin v := R8; if v <> 0 then DefA.ChDir := v; end;
         if Has(3) then R8;
         if Has(4) then DefA.ChSet := R8;
       end;
    3: if Has(1) then
       begin
         RPt(x, y);
         DefA.MkW := Abs(x); DefA.MkH := Abs(y);
       end;
    7: ReadMatrix(mask, DefA.MA, DefA.MB, DefA.MC, DefA.MD, DefA.ME, DefA.MF);
    $0B: begin
           if Has(0) then DefA.ArcP := RC;
           if Has(1) then DefA.ArcQ := RC;
           if Has(2) then DefA.ArcR := RC;
           if Has(3) then DefA.ArcS := RC;
         end;
  end;
end;

// Graphics Data Descriptor: coordinate size, units and picture rectangle.
procedure TMetPlayer.ReadDescriptor(const G: TBytes; out HaveRect: Boolean;
  out X1, Y1, X2, Y2, PxPerUnitX, PxPerUnitY: Double);
var
  q, id, l, unitT: Integer;
  b32: Boolean;
  xr, yr, t: Double;

  function Co(var p: Integer): Double;
  begin
    if b32 then begin Result := Integer(LE32(G, p)); Inc(p, 4); end
    else
    begin
      if p + 1 < Length(G) then Result := SmallInt(G[p] or (G[p + 1] shl 8)) else Result := 0;
      Inc(p, 2);
    end;
  end;

  function CoBE(var p: Integer): Double;
  begin
    if b32 then begin Result := Integer(BE32(G, p)); Inc(p, 4); end
    else begin Result := SmallInt(Word(BE16(G, p))); Inc(p, 2); end;
  end;

var p, pb: Integer;
begin
  HaveRect := False;
  HaveAlt := False;
  X1 := 0; Y1 := 0; X2 := 0; Y2 := 0;
  PxPerUnitX := 0; PxPerUnitY := 0;
  q := 0;
  while q + 1 < Length(G) do
  begin
    id := G[q]; l := G[q + 1];
    p := q + 2;
    if p + l > Length(G) then Break;
    case id of
      $F7: if l >= 7 then
           begin
             if G[p + 6] = 5 then C32 := True
             else if G[p + 6] = 4 then C32 := False;
           end;
      $F6: if l >= 4 then
           begin
             b32 := G[p + 2] <> 4;
             unitT := G[p + 3];
             Inc(p, 4);
             xr := Co(p); yr := Co(p); Co(p);
             if (xr > 0) and (yr > 0) then
               case unitT of
                 0: begin PxPerUnitX := 960 / xr; PxPerUnitY := 960 / yr; end;          // per 10 inches
                 1: begin PxPerUnitX := 9600 / 25.4 / xr; PxPerUnitY := 9600 / 25.4 / yr; end;  // per 10 cm
               end;
             if p + 4 * (Ord(b32) * 2 + 2) <= q + 2 + l then
             begin
               pb := p;
               AX1 := CoBE(pb); AX2 := CoBE(pb); AY1 := CoBE(pb); AY2 := CoBE(pb);
               if AX1 > AX2 then begin t := AX1; AX1 := AX2; AX2 := t; end;
               if AY1 > AY2 then begin t := AY1; AY1 := AY2; AY2 := t; end;
               HaveAlt := (AX2 > AX1) and (AY2 > AY1);
               X1 := Co(p); X2 := Co(p); Y1 := Co(p); Y2 := Co(p);
               if X1 > X2 then begin t := X1; X1 := X2; X2 := t; end;
               if Y1 > Y2 then begin t := Y1; Y1 := Y2; Y2 := t; end;
               HaveRect := (X2 > X1) and (Y2 > Y1);
             end;
           end;
      $21: begin
             B := G; FP := p; FEnd := p + l;
             ReadScd;
           end;
    end;
    Inc(q, 2 + l);
  end;
  A := DefA;
end;

// Plays the drawing orders of one graphics object.
procedure TMetPlayer.Play(const G: TBytes);
var
  q, code, len, b1, b2, rem: Integer;
begin
  B := G;
  q := 0;
  while q < Length(B) do
  begin
    code := B[q]; Inc(q);
    if code = $FE then
    begin
      if q >= Length(B) then Break;
      code := $FE00 or B[q]; Inc(q);
    end;
    if (code > $FF) or (code = $F3) then
    begin
      // two-byte length: normally high byte first, but some writers store
      // it low byte first
      if q + 1 >= Length(B) then Break;
      b1 := B[q]; b2 := B[q + 1]; Inc(q, 2);
      rem := Length(B) - q;
      if b2 <> 0 then len := (b1 shl 8) or b2 else len := b1;
      if len > rem then len := b1 or (b2 shl 8);
    end
    else if (code = $36) or (code = $76) then len := 2
    else if (code and $88) = $08 then len := 1
    else if (code = 0) or (code = $FF) then len := 0
    else
    begin
      if q >= Length(B) then Break;
      len := B[q]; Inc(q);
    end;
    if q + len > Length(B) then len := Length(B) - q;
    FP := q; FEnd := q + len;
    try
      Order(code, len);
    except
      on E: EMetError do raise;
      on E: Exception do ;       // a malformed order is skipped
    end;
    q := q + len;
  end;
  if FInArea then DoEndArea;
  if FInPath then DoEndPath;
  if FImgOn then DoEndImage;
end;

function TMetPlayer.BuildSvg(W, H: Integer): string;
var
  i: Integer;
  closeG: string;
begin
  closeG := '';
  for i := 1 to FGroupDepth do closeG := closeG + '</g>' + #10;
  Result := '<?xml version="1.0" encoding="UTF-8"?>' + #10 +
    '<svg xmlns="http://www.w3.org/2000/svg" width="' + IntToStr(W) + '" height="' +
    IntToStr(H) + '" viewBox="0 0 ' + IntToStr(W) + ' ' + IntToStr(H) + '">' + #10 +
    FOut.ToString + closeG + '</svg>' + #10;
end;

// ------------------------------ document -----------------------------------

function IsOs2Met(const Data: TBytes): Boolean;
var l: Integer;
begin
  Result := False;
  if Length(Data) < 16 then Exit;
  l := (Data[0] shl 8) or Data[1];
  if (l < 8) or (Data[2] <> $D3) then Exit;
  Result := (Data[3] = $A8) and (Data[4] = $A8);
end;

// Map Coded Font: triplets naming the typeface and giving its attributes.
procedure ParseMcf(const D: TBytes; Ofs, Len: Integer; var Doc: TMetDoc);
var
  q, e, rg, rge, tl, tid, n: Integer;
  F: TFontDef;
  i, fq, fl: Integer;
  parts: TStringArray;
begin
  q := Ofs; e := Min(Ofs + Len, Length(D));
  while q + 2 <= e do
  begin
    rg := BE16(D, q);
    if rg < 2 then Break;
    rge := Min(q + rg, e);
    F := Default(TFontDef);
    fq := -1; fl := 0;
    Inc(q, 2);
    while q + 1 < rge do
    begin
      tl := D[q]; tid := D[q + 1];
      if tl < 2 then Break;
      case tid of
        $02: if (q + 3 < rge) and (D[q + 2] = $08) then
             begin
               // typeface name: decoded with the font's code page below
               fq := q + 4;
               fl := 0;
               while (fq + fl < Min(q + tl, rge)) and (D[fq + fl] >= 32) do Inc(fl);
             end;
        $20: if q + 5 < rge then F.Cp := BE16(D, q + 4);
        $24: if (q + 3 < rge) and (D[q + 2] = $05) then F.Lid := D[q + 3];
        $1F: if q + 8 < rge then
             begin
               F.Bold := D[q + 2] >= 6;
               F.H := BE16(D, q + 4);
               F.W := BE16(D, q + 6);
               F.Italic := (D[q + 8] and $80) <> 0;
               F.Under := (D[q + 8] and $40) <> 0;
               F.Strike := (D[q + 8] and $08) <> 0;
             end;
      end;
      Inc(q, tl);
    end;
    if fq >= 0 then
    begin
      if F.Cp <> 0 then parts := DecodeText(D, fq, fl, F.Cp)
      else parts := DecodeText(D, fq, fl, Doc.DefCp);
      F.Face := '';
      for i := 0 to High(parts) do F.Face := F.Face + parts[i];
      F.Face := Trim(F.Face);
    end;
    n := Length(Doc.Fonts);
    SetLength(Doc.Fonts, n + 1);
    Doc.Fonts[n] := F;
    q := rge;
  end;
end;

// Map Data Resource: image object name -> bitmap handle.
procedure ParseMdr(const D: TBytes; Ofs, Len: Integer; var Doc: TMetDoc);
var
  q, e, rg, rge, tl, tid: Integer;
  name: string;
  h: Cardinal;
  hasH: Boolean;
begin
  q := Ofs; e := Min(Ofs + Len, Length(D));
  while q + 2 <= e do
  begin
    rg := BE16(D, q);
    if rg < 2 then Break;
    rge := Min(q + rg, e);
    name := ''; h := 0; hasH := False;
    Inc(q, 2);
    while q + 1 < rge do
    begin
      tl := D[q]; tid := D[q + 1];
      if tl < 2 then Break;
      if (tid = $02) and (tl >= 12) then name := Name8(D, q + 4)
      else if (tid = $22) and (tl >= 7) then begin h := BE32(D, q + 3); hasH := True; end;
      Inc(q, tl);
    end;
    if (name <> '') and hasH then Doc.Handles.Values[name] := IntToStr(Int64(h));
    q := rge;
  end;
end;

procedure FitSize(var W, H: Double);
var f: Double;
begin
  W := Abs(W); H := Abs(H);
  if Max(W, H) > MAX_SIDE then
  begin
    f := MAX_SIDE / Max(W, H);
    W := W * f; H := H * f;
  end;
  if W < 1 then W := 1;
  if H < 1 then H := 1;
end;

function MetToSvg(const Data: TBytes; out Width, Height: Integer): string;
var
  Doc: TMetDoc;
  q, l, typ, n, i, k, depth: Integer;
  inImg, haveRect, haveUnits: Boolean;
  imgPal: TPalette;
  IB: TIocaBuild;
  imgName: string;
  M, G: TMetPlayer;
  x1, y1, x2, y2, pux, puy, w, h, hx: Double;
  gad: TBytes;
  gadLen: Integer;
  inGraphics: Boolean;
  gdd: TBytes;
  haveAlt, measured, dummyB: Boolean;
  ax1, ay1, ax2, ay2, mx1, my1, mx2, my2, shLE, shBE, marea: Double;
begin
  Width := 0; Height := 0; Result := '';
  if not IsOs2Met(Data) then raise EMetError.Create('MET: not an OS/2 metafile');
  Doc.Pal := Default(TPalette);
  Doc.DefCp := 850;
  Doc.Fonts := nil; Doc.Bitmaps := nil; Doc.Objs := nil;
  Doc.Handles := TStringList.Create;
  try
    // ---- structured fields ----
    inImg := False; inGraphics := False;
    gad := nil; gadLen := 0; gdd := nil;
    imgPal := Default(TPalette);
    IB := Default(TIocaBuild);
    imgName := '';
    depth := 0;
    q := 0;
    while q + 8 <= Length(Data) do
    begin
      l := (Data[q] shl 8) or Data[q + 1];
      if (Data[q + 2] <> $D3) or (l < 8) then Break;
      typ := (Data[q + 3] shl 8) or Data[q + 4];
      if q + l > Length(Data) then l := Length(Data) - q;
      n := l - 8;
      case typ of
        SF_CAT: if inImg then ParseCat(Data, q + 8, n, imgPal) else ParseCat(Data, q + 8, n, Doc.Pal);
        SF_MCF: ParseMcf(Data, q + 8, n, Doc);
        SF_MDR: ParseMdr(Data, q + 8, n, Doc);
        SF_BIM: begin
                  inImg := True;
                  imgPal := Default(TPalette);
                  IB.W := 0; IB.H := 0; IB.Bpp := 0; IB.Len := 0; IB.Data := nil;
                  imgName := Name8(Data, q + 8);
                end;
        SF_IPD: if inImg then ParseIpd(Data, q + 8, n, IB);
        SF_EIM: if inImg then
                begin
                  inImg := False;
                  k := Length(Doc.Bitmaps);
                  SetLength(Doc.Bitmaps, k + 1);
                  Doc.Bitmaps[k].Name := imgName;
                  if Doc.Handles.IndexOfName(imgName) >= 0 then
                    Doc.Bitmaps[k].Id := Cardinal(StrToInt64Def(Doc.Handles.Values[imgName], 0))
                  else
                    Doc.Bitmaps[k].Id := NameHandle(imgName);
                  if not IocaBuildImage(IB, imgPal, Doc.Bitmaps[k].Img) then
                    SetLength(Doc.Bitmaps, k);
                  IB.Data := nil;
                end;
        SF_BGR: begin inGraphics := True; gadLen := 0; gad := nil; gdd := nil; end;
        SF_GDD: begin SetLength(gdd, n); if n > 0 then Move(Data[q + 8], gdd[0], n); end;
        SF_GAD: begin
                  if gadLen + n > Length(gad) then SetLength(gad, Max(gadLen + n, Length(gad) * 2));
                  if n > 0 then Move(Data[q + 8], gad[gadLen], n);
                  Inc(gadLen, n);
                end;
        SF_EGR: if inGraphics then
                begin
                  inGraphics := False;
                  k := Length(Doc.Objs);
                  SetLength(Doc.Objs, k + 1);
                  SetLength(gad, gadLen);
                  Doc.Objs[k].Gad := gad;
                  Doc.Objs[k].Gdd := gdd;
                  gad := nil; gadLen := 0;
                end;
        SF_EDT: Break;
        SF_BDT: begin
                  // Coded Graphic Character Set triplet: the document code page
                  k := q + 8 + 10;
                  while k + 1 < q + l do
                  begin
                    if Data[k] < 2 then Break;
                    if (Data[k + 1] = $01) and (Data[k] >= 6) then Doc.DefCp := BE16(Data, k + 4);
                    Inc(k, Data[k]);
                  end;
                  if Doc.DefCp = 0 then Doc.DefCp := 850;
                end;
      end;
      Inc(depth);
      if depth > 1000000 then Break;
      Inc(q, l);
    end;
    // an image object cut off before its end field
    if inImg and (IB.Len > 0) then
    begin
      k := Length(Doc.Bitmaps);
      SetLength(Doc.Bitmaps, k + 1);
      Doc.Bitmaps[k].Name := imgName;
      Doc.Bitmaps[k].Id := NameHandle(imgName);
      if not IocaBuildImage(IB, imgPal, Doc.Bitmaps[k].Img) then SetLength(Doc.Bitmaps, k);
    end;
    // a graphics object without its end field
    if inGraphics and (gadLen > 0) then
    begin
      k := Length(Doc.Objs);
      SetLength(Doc.Objs, k + 1);
      SetLength(gad, gadLen);
      Doc.Objs[k].Gad := gad;
      Doc.Objs[k].Gdd := gdd;
    end;
    if Length(Doc.Objs) = 0 then
    begin
      // a metafile that only carries an image object
      if Length(Doc.Bitmaps) = 0 then raise EMetError.Create('MET: no graphics object');
      w := Doc.Bitmaps[0].Img.W; h := Doc.Bitmaps[0].Img.H;
      FitSize(w, h);
      Width := Max(1, Round(w)); Height := Max(1, Round(h));
      G := TMetPlayer.Create(False, Doc);
      try
        G.DrawBitmap(Doc.Bitmaps[0].Img, 0, 0, Width, Height);
        Result := G.BuildSvg(Width, Height);
      finally
        G.Free;
      end;
      Exit;
    end;

    // ---- picture frame ----
    // the descriptor's rectangle is checked against the measured drawing:
    // some writers store it high byte first, some store nonsense
    M := TMetPlayer.Create(True, Doc);
    try
      M.ReadDescriptor(Doc.Objs[0].Gdd, haveRect, x1, y1, x2, y2, pux, puy);
      haveAlt := M.HaveAlt;
      ax1 := M.AX1; ay1 := M.AY1; ax2 := M.AX2; ay2 := M.AY2;
      haveUnits := (pux > 0) and (puy > 0);
      if not haveUnits then begin pux := 1; puy := 1; end;
      for i := 0 to High(Doc.Objs) do
      begin
        M.ReadDescriptor(Doc.Objs[i].Gdd, dummyB, w, w, w, w, hx, hx);
        M.SX := pux; M.SY := puy;
        M.Play(Doc.Objs[i].Gad);
      end;
      measured := (M.MaxX >= M.MinX) and (M.MaxY >= M.MinY);
      mx1 := M.MinX; my1 := M.MinY; mx2 := M.MaxX; my2 := M.MaxY;
      shLE := 0; shBE := 0;
      if measured and haveRect then shLE := M.PointShare(x1, y1, x2, y2);
      if measured and haveAlt then shBE := M.PointShare(ax1, ay1, ax2, ay2);
      // a rectangle far larger than the drawing is not believed either
      marea := Max(mx2 - mx1, 1) * Max(my2 - my1, 1);
      if haveRect and ((x2 - x1) * (y2 - y1) > 64 * marea) then shLE := 0;
      if haveAlt and ((ax2 - ax1) * (ay2 - ay1) > 64 * marea) then shBE := 0;
    finally
      M.Free;
    end;
    if measured then
    begin
      // a rectangle holding (nearly) all of the drawing is taken; of two
      // such readings the tighter one
      if (shLE >= 0.95) and ((shBE < 0.95) or
         ((x2 - x1) * (y2 - y1) <= (ax2 - ax1) * (ay2 - ay1))) then
      else if shBE >= 0.95 then
      begin
        x1 := ax1; y1 := ay1; x2 := ax2; y2 := ay2;
      end
      else
      begin
        x1 := mx1; y1 := my1; x2 := mx2; y2 := my2;
        if x2 - x1 < 1 then x2 := x1 + 1;
        if y2 - y1 < 1 then y2 := y1 + 1;
      end;
    end
    else if not haveRect then raise EMetError.Create('MET: empty picture');
    w := (x2 - x1) * pux; h := (y2 - y1) * puy;
    // a resolution that makes the page absurdly large or small (e.g. one unit per
    // 10 inches for a screen capture) means the units are device pixels
    if haveUnits and (((Max(w, h) > 8 * MAX_SIDE) and (Max(x2 - x1, y2 - y1) <= 8 * MAX_SIDE)) or
       ((Max(w, h) < 32) and (Max(x2 - x1, y2 - y1) >= 32))) then
    begin
      w := x2 - x1; h := y2 - y1;
    end;
    FitSize(w, h);
    Width := Max(1, Round(w)); Height := Max(1, Round(h));

    // ---- drawing ----
    G := TMetPlayer.Create(False, Doc);
    try
      G.OX0 := x1; G.OY0 := y2;
      G.SX := Width / (x2 - x1); G.SY := Height / (y2 - y1);
      for i := 0 to High(Doc.Objs) do
      begin
        G.ReadDescriptor(Doc.Objs[i].Gdd, haveRect, w, w, w, w, hx, hx);
        G.Play(Doc.Objs[i].Gad);
      end;
      Result := G.BuildSvg(Width, Height);
    finally
      G.Free;
    end;
  finally
    Doc.Handles.Free;
  end;
end;

end.
