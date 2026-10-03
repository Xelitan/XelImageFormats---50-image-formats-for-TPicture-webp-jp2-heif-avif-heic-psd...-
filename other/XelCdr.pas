unit XelCdr;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$R-}{$Q-}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	CorelDRAW drawing (.cdr) -> SVG converter                     //
// Version:	0.1                                                           //
// Date:	03-OCT-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// CorelDRAW stores a drawing as a tree of RIFF chunks. Versions 6..X3 keep it
// in a plain RIFF file (lists may be zlib-compressed, "cmpr"); X4 and X5 put
// that file into a ZIP archive (content/riffData.cdr); X6 and later keep only
// the tree in content/root.dat and move the chunk payloads to the streams
// listed in content/dataFileList.dat.
//
// The tree is read twice: the first pass collects the document resources
// (fills, outlines, bitmaps, patterns, fonts, text styles, texts, page sizes),
// the second one turns the objects of the first visible page into SVG for
// SimpleSVG: curves, rectangles, ellipses, polygons, splines, bitmaps (as runs
// of rectangles), artistic and paragraph text. Objects are stored top-most
// first, so they are written in reverse order.
//
// Colours: RGB, CMYK (through a table computed from the ISO Coated v2 profile
// CorelDRAW embeds), CMY, HSB, HLS, grey, Lab, YIQ, registration colour and
// document palette entries. Fountain fills are drawn as colour bands inside a
// clip path, two-colour and bitmap pattern fills as <pattern> tiles; uniform
// transparency and bitmap transparency masks are kept. PowerClip contents are
// clipped to their container.
//
// Not reproduced: effects (lenses, blends, contours, envelopes, extrusions,
// drop shadows) show only the objects CorelDRAW stored for them; vector
// pattern fills, arrow heads, text on a path, exact text metrics (the fonts
// come from the system) and spot-colour books (Pantone etc.).

interface

uses
  SysUtils, Classes, Math, Generics.Collections, XelInflate;

type
  ECdrError = class(Exception);

// True for CorelDRAW 6+ files (plain RIFF or ZIP container).
function IsCdr(const Data: TBytes): Boolean;

// Converts a CorelDRAW file to an SVG document. Width and Height are the size
// of the first page in pixels (96 dpi), limited to 4096 on the longer side.
function CdrToSvg(const Data: TBytes; out Width, Height: Integer): string;

implementation

{$I XelCdrCmyk.inc}

const
  MAX_SIDE = 4096;
  MAX_BITMAP_CELLS = 300000;
  MAX_LEVEL = 64;
  PX_PER_INCH = 96.0;
  GRAD_STEPS = 64;

type
  TCdrColor = record
    Model, Pal: Word;
    Value: Cardinal;
  end;

  TGradStop = record
    Offset: Double;
    Color: TCdrColor;
  end;

  TCdrFill = record
    Kind: Integer;              // -1 unset, 0 none, 1 solid, 2 fountain, 7/8 pattern, 9 bitmap, 10 vector, 11 texture
    Color1, Color2: TCdrColor;
    GType, GEdge, GCx, GCy: Integer;
    GAngle: Double;
    Stops: array of TGradStop;
    ImgId: Cardinal;
    ImgW, ImgH: Double;         // tile size, inches (or percent when ImgRel)
    ImgRel: Boolean;
    ImgFlags: Byte;
  end;

  TCdrOutl = record
    LineType: Integer;          // -1 unset; bit 0 = none, bits 1..2 = drawn, bit 2 = dashed, $20 = scale with object
    Caps, Join: Integer;
    Width, Stretch: Double;
    Color: TCdrColor;
    Dash: array of Integer;
  end;

  TCdrStyle = record
    CharSet: Integer;           // -1 unset
    Font: string;
    Size: Double;               // inches
    Align: Integer;
    Fill: TCdrFill;
    Outl: TCdrOutl;
    Parent: Cardinal;
  end;

  TCdrRun = record
    Text: string;               // UTF-8
    Style: TCdrStyle;
  end;
  TCdrPara = array of TCdrRun;

  TCdrText = record
    Paras: array of TCdrPara;
  end;

  TCdrImage = record
    W, H: Integer;
    Px: array of Cardinal;      // $AARRGGBB, top-down
  end;

  TCdrPattern = record
    W, H: Integer;
    Bits: TBytes;               // 1 bit per pixel, rows top-down, (W + 7) div 8 bytes each
  end;

  TMat = record                 // x' = A x + B y + C,  y' = D x + E y + F (libcdr's v0 v1 x0 / v3 v4 y0)
    A, B, C, D, E, F: Double;
  end;
  TMats = array of TMat;

  TPathEl = record
    Cmd: Char;                  // M L C Z
    X1, Y1, X2, Y2, X, Y: Double;
  end;
  TPath = array of TPathEl;

  TPagePt = record
    W, H: Double;
  end;

  TOutKind = (okElem, okOpen, okClose);
  TOutItem = record
    Kind: TOutKind;
    S: string;                  // element, or the clip id of a group
  end;

  { TRd: bounded little-endian reader over a byte buffer }
  TRd = record
    B: TBytes;
    P, E: Integer;
    procedure Init(const ABuf: TBytes; APos, AEnd: Integer);
    function Left: Integer;
    function U8: Integer;
    function U16: Integer;
    function S16: Integer;
    function U32: Cardinal;
    function S32: Integer;
    function U64: UInt64;
    function F64: Double;
    procedure Skip(N: Integer);
  end;

// ------------------------------ reader -------------------------------------

procedure TRd.Init(const ABuf: TBytes; APos, AEnd: Integer);
begin
  B := ABuf;
  P := APos;
  E := Min(AEnd, Length(ABuf));
  if E < P then E := P;
end;

function TRd.Left: Integer;
begin
  Result := E - P;
  if Result < 0 then Result := 0;
end;

function TRd.U8: Integer;
begin
  if P < E then Result := B[P] else Result := 0;
  Inc(P);
end;

function TRd.U16: Integer;
begin
  if P + 2 <= E then Result := B[P] or (B[P + 1] shl 8) else Result := 0;
  Inc(P, 2);
end;

function TRd.S16: Integer;
begin
  Result := SmallInt(Word(U16));
end;

function TRd.U32: Cardinal;
begin
  if P + 4 <= E then
    Result := Cardinal(B[P]) or (Cardinal(B[P + 1]) shl 8) or (Cardinal(B[P + 2]) shl 16) or (Cardinal(B[P + 3]) shl 24)
  else Result := 0;
  Inc(P, 4);
end;

function TRd.S32: Integer;
begin
  Result := Integer(U32);
end;

function TRd.U64: UInt64;
var lo: UInt64;
begin
  lo := U32;
  Result := lo or (UInt64(U32) shl 32);
end;

function TRd.F64: Double;
var q: UInt64;
begin
  q := U64;
  Move(q, Result, 8);
  if IsNan(Result) or IsInfinite(Result) then Result := 0;
end;

procedure TRd.Skip(N: Integer);
begin
  Inc(P, N);
end;

// ------------------------------ ZIP ----------------------------------------

type
  TZipEntry = record
    Name: string;
    Method: Integer;
    CompSize, Size: Cardinal;
    LocalOfs: Cardinal;
  end;
  TZipEntries = array of TZipEntry;

function RdLE16(const D: TBytes; p: Integer): Integer;
begin
  if (p < 0) or (p + 2 > Length(D)) then Exit(0);
  Result := D[p] or (D[p + 1] shl 8);
end;

function RdLE32(const D: TBytes; p: Integer): Cardinal;
begin
  if (p < 0) or (p + 4 > Length(D)) then Exit(0);
  Result := Cardinal(D[p]) or (Cardinal(D[p + 1]) shl 8) or (Cardinal(D[p + 2]) shl 16) or (Cardinal(D[p + 3]) shl 24);
end;

function ZipList(const D: TBytes): TZipEntries;
var
  eocd, p, n, i, nl, xl, cl: Integer;
  cdOfs: Cardinal;
begin
  Result := nil;
  eocd := -1;
  for p := Length(D) - 22 downto Max(0, Length(D) - 65557) do
    if RdLE32(D, p) = $06054B50 then begin eocd := p; Break; end;
  if eocd < 0 then
  begin
    // no central directory: walk the local headers
    p := 0;
    while RdLE32(D, p) = $04034B50 do
    begin
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n].Method := RdLE16(D, p + 8);
      Result[n].CompSize := RdLE32(D, p + 18);
      Result[n].Size := RdLE32(D, p + 22);
      nl := RdLE16(D, p + 26); xl := RdLE16(D, p + 28);
      Result[n].Name := UTF8Encode(TEncoding.ANSI.GetString(D, p + 30, Min(nl, Length(D) - p - 30)));
      Result[n].LocalOfs := p;
      p := p + 30 + nl + xl + Integer(Result[n].CompSize);
      if (RdLE16(D, Integer(Result[n].LocalOfs) + 6) and 8) <> 0 then Break;   // sizes in a data descriptor
    end;
    Exit;
  end;
  n := RdLE16(D, eocd + 10);
  cdOfs := RdLE32(D, eocd + 16);
  p := cdOfs;
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    if RdLE32(D, p) <> $02014B50 then begin SetLength(Result, i); Break; end;
    Result[i].Method := RdLE16(D, p + 10);
    Result[i].CompSize := RdLE32(D, p + 20);
    Result[i].Size := RdLE32(D, p + 24);
    nl := RdLE16(D, p + 28); xl := RdLE16(D, p + 30); cl := RdLE16(D, p + 32);
    Result[i].LocalOfs := RdLE32(D, p + 42);
    if p + 46 + nl <= Length(D) then
      Result[i].Name := UTF8Encode(TEncoding.UTF8.GetString(D, p + 46, nl));
    p := p + 46 + nl + xl + cl;
  end;
end;

function ZipFind(const L: TZipEntries; const Name: string): Integer;
var i: Integer;
begin
  for i := 0 to High(L) do
    if SameText(L[i].Name, Name) then Exit(i);
  Result := -1;
end;

function ZipRead(const D: TBytes; const Ent: TZipEntry): TBytes;
var p, nl, xl: Integer;
begin
  Result := nil;
  p := Ent.LocalOfs;
  if RdLE32(D, p) <> $04034B50 then Exit;
  nl := RdLE16(D, p + 26); xl := RdLE16(D, p + 28);
  p := p + 30 + nl + xl;
  if (p < 0) or (Int64(p) + Ent.CompSize > Length(D)) then Exit;
  case Ent.Method of
    0: begin
         SetLength(Result, Ent.CompSize);
         if Ent.CompSize > 0 then Move(D[p], Result[0], Ent.CompSize);
       end;
    8: if Ent.CompSize > 0 then
         try
           Result := InflateRaw(@D[p], Ent.CompSize);
         except
           Result := nil;      // a damaged entry reads as missing
         end;
  end;
end;

// ------------------------------ helpers ------------------------------------

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
      #0..#8, #11, #12, #14..#31: ;
    else
      Result := Result + c;
    end;
  end;
end;

function Utf8OfCode(cp: Cardinal): string;
begin
  if cp < $80 then Result := Chr(cp)
  else if cp < $800 then Result := Chr($C0 or (cp shr 6)) + Chr($80 or (cp and $3F))
  else if cp < $10000 then
    Result := Chr($E0 or (cp shr 12)) + Chr($80 or ((cp shr 6) and $3F)) + Chr($80 or (cp and $3F))
  else
    Result := Chr($F0 or (cp shr 18)) + Chr($80 or ((cp shr 12) and $3F)) +
      Chr($80 or ((cp shr 6) and $3F)) + Chr($80 or (cp and $3F));
end;

// UTF-16LE bytes -> UTF-8
function Utf16ToUtf8(const D: TBytes; Ofs, Len: Integer): string;
var i, c, c2: Integer;
begin
  Result := '';
  i := Ofs;
  while (i + 1 < Ofs + Len) and (i + 1 < Length(D)) do
  begin
    c := D[i] or (D[i + 1] shl 8);
    Inc(i, 2);
    if (c >= $D800) and (c < $DC00) and (i + 1 < Length(D)) then
    begin
      c2 := D[i] or (D[i + 1] shl 8);
      if (c2 >= $DC00) and (c2 < $E000) then
      begin
        Inc(i, 2);
        c := $10000 + ((c - $D800) shl 10) + (c2 - $DC00);
      end;
    end;
    if c = 0 then Continue;
    Result := Result + Utf8OfCode(c);
  end;
end;

// Windows character set (font charset) -> code page
function CharsetCodePage(cs: Integer): Integer;
begin
  case cs of
    $00, $01: Result := 1252;
    $80: Result := 932;
    $81: Result := 949;
    $86: Result := 936;
    $88: Result := 950;
    $A1: Result := 1253;
    $A2: Result := 1254;
    $A3: Result := 1258;
    $B1: Result := 1255;
    $B2: Result := 1256;
    $BA: Result := 1257;
    $CC: Result := 1251;
    $DE: Result := 874;
    $EE: Result := 1250;
    $02: Result := 0;           // symbol fonts: keep the byte values
  else
    Result := 1252;
  end;
end;

// single / multi-byte text in a code page -> UTF-8
function CodePageToUtf8(const D: TBytes; Ofs, Len, CharSet: Integer): string;
var
  cp, i: Integer;
  enc: TEncoding;
  sub: TBytes;
begin
  Result := '';
  if Len <= 0 then Exit;
  if Ofs + Len > Length(D) then Len := Length(D) - Ofs;
  if Len <= 0 then Exit;
  cp := CharsetCodePage(CharSet);
  if cp = 0 then
  begin
    for i := Ofs to Ofs + Len - 1 do Result := Result + Utf8OfCode(D[i]);
    Exit;
  end;
  SetLength(sub, Len);
  Move(D[Ofs], sub[0], Len);
  enc := nil;
  try
    try
      enc := TEncoding.GetEncoding(cp);
      Result := UTF8Encode(enc.GetString(sub));
    except
      Result := '';
      for i := 0 to Len - 1 do Result := Result + Utf8OfCode(sub[i]);
    end;
  finally
    enc.Free;
  end;
end;

// ------------------------------ JSON (text styles) -------------------------

// Flattens a JSON document into "a.b.c=value" lines.
procedure JsonFlatten(const S: string; L: TStringList);
var p: Integer;

  procedure Ws;
  begin
    while (p <= Length(S)) and (S[p] in [' ', #9, #10, #13]) do Inc(p);
  end;

  function Str: string;
  var c: Char; h: string; code: Integer;
  begin
    Result := '';
    Inc(p);   // opening quote
    while p <= Length(S) do
    begin
      c := S[p]; Inc(p);
      if c = '"' then Exit;
      if c = '\' then
      begin
        if p > Length(S) then Exit;
        c := S[p]; Inc(p);
        case c of
          'n': Result := Result + #10;
          't': Result := Result + #9;
          'r': Result := Result + #13;
          'u': begin
                 h := Copy(S, p, 4); Inc(p, 4);
                 code := StrToIntDef('$' + h, 32);
                 Result := Result + Utf8OfCode(code);
               end;
        else
          Result := Result + c;
        end;
      end
      else Result := Result + c;
    end;
  end;

  procedure Value(const Path: string; Depth: Integer);
  var key, v: string; idx: Integer;
  begin
    Ws;
    if (p > Length(S)) or (Depth > 32) then Exit;
    case S[p] of
      '{': begin
             Inc(p);
             repeat
               Ws;
               if (p <= Length(S)) and (S[p] = '}') then begin Inc(p); Exit; end;
               if (p > Length(S)) or (S[p] <> '"') then Exit;
               key := Str;
               Ws;
               if (p <= Length(S)) and (S[p] = ':') then Inc(p);
               if Path = '' then Value(key, Depth + 1) else Value(Path + '.' + key, Depth + 1);
               Ws;
               if (p <= Length(S)) and (S[p] = ',') then Inc(p)
               else begin if (p <= Length(S)) and (S[p] = '}') then Inc(p); Exit; end;
             until False;
           end;
      '[': begin
             Inc(p); idx := 0;
             repeat
               Ws;
               if (p <= Length(S)) and (S[p] = ']') then begin Inc(p); Exit; end;
               Value(Path + '.' + IntToStr(idx), Depth + 1);
               Inc(idx);
               Ws;
               if (p <= Length(S)) and (S[p] = ',') then Inc(p)
               else begin if (p <= Length(S)) and (S[p] = ']') then Inc(p); Exit; end;
             until False;
           end;
      '"': L.Add(Path + '=' + Str);
    else
      begin
        v := '';
        while (p <= Length(S)) and not (S[p] in [',', '}', ']', ' ', #9, #10, #13]) do
        begin
          v := v + S[p]; Inc(p);
        end;
        L.Add(Path + '=' + v);
      end;
    end;
  end;

begin
  p := 1;
  Value('', 0);
end;

// ------------------------------ colours ------------------------------------

function ClampB(v: Double): Integer;
begin
  Result := EnsureRange(Round(v), 0, 255);
end;

// CMYK (0..255 each) through the ISO Coated table, quadrilinear
function CmykToRgb(c, m, y, k: Double): Cardinal;
var
  f: array[0..3] of Double;
  i0: array[0..3] of Integer;
  w, acc0, acc1, acc2: Double;
  corner, j, idx: Integer;
  v: array[0..3] of Double;
begin
  v[0] := EnsureRange(c, 0, 255); v[1] := EnsureRange(m, 0, 255);
  v[2] := EnsureRange(y, 0, 255); v[3] := EnsureRange(k, 0, 255);
  for j := 0 to 3 do
  begin
    f[j] := v[j] * (CDR_CMYK_N - 1) / 255;
    i0[j] := Min(Trunc(f[j]), CDR_CMYK_N - 2);
    f[j] := f[j] - i0[j];
  end;
  acc0 := 0; acc1 := 0; acc2 := 0;
  for corner := 0 to 15 do
  begin
    w := 1;
    idx := 0;
    for j := 0 to 3 do
    begin
      if (corner shr (3 - j)) and 1 = 1 then
      begin
        w := w * f[j];
        idx := idx * CDR_CMYK_N + i0[j] + 1;
      end
      else
      begin
        w := w * (1 - f[j]);
        idx := idx * CDR_CMYK_N + i0[j];
      end;
    end;
    if w = 0 then Continue;
    acc0 := acc0 + w * CDR_CMYK_LUT[idx * 3];
    acc1 := acc1 + w * CDR_CMYK_LUT[idx * 3 + 1];
    acc2 := acc2 + w * CDR_CMYK_LUT[idx * 3 + 2];
  end;
  Result := (Cardinal(ClampB(acc0)) shl 16) or (Cardinal(ClampB(acc1)) shl 8) or Cardinal(ClampB(acc2));
end;

function LabToRgb(L, a, b: Double): Cardinal;
var
  fy, fx, fz, X, Y, Z, r, g, bl: Double;

  function Finv(t: Double): Double;
  begin
    if t > 6 / 29 then Result := t * t * t else Result := 3 * Sqr(6 / 29) * (t - 4 / 29);
  end;

  function Gam(u: Double): Integer;
  begin
    u := EnsureRange(u, 0, 1);
    if u <= 0.0031308 then u := 12.92 * u else u := 1.055 * Power(u, 1 / 2.4) - 0.055;
    Result := ClampB(u * 255);
  end;

begin
  fy := (L + 16) / 116; fx := fy + a / 500; fz := fy - b / 200;
  // D50 white, Bradford-adapted to D65 sRGB
  X := 0.9642 * Finv(fx); Y := Finv(fy); Z := 0.8249 * Finv(fz);
  r := 3.1338561 * X - 1.6168667 * Y - 0.4906146 * Z;
  g := -0.9787684 * X + 1.9161415 * Y + 0.0334540 * Z;
  bl := 0.0719453 * X - 0.2289914 * Y + 1.4052427 * Z;
  Result := (Cardinal(Gam(r)) shl 16) or (Cardinal(Gam(g)) shl 8) or Cardinal(Gam(bl));
end;

function HueRgb(hue: Integer; out sr, sg, sb: Double): Boolean;
begin
  while hue > 360 do Dec(hue, 360);
  if hue < 120 then begin sr := (120 - hue) / 60; sg := hue / 60; sb := 0; end
  else if hue < 240 then begin sr := 0; sg := (240 - hue) / 60; sb := (hue - 120) / 60; end
  else begin sr := (hue - 240) / 60; sg := 0; sb := (360 - hue) / 60; end;
  sr := Min(sr, 1); sg := Min(sg, 1); sb := Min(sb, 1);
  Result := True;
end;

// ------------------------------ document -----------------------------------

type
  TFillIdx = TDictionary<Cardinal, Integer>;

  { TCdrDoc }

  TCdrDoc = class
  public
    Root: TBytes;
    Streams: array of TBytes;
    Version: Integer;
    Prec32: Boolean;
    // resources
    Fills: array of TCdrFill;
    FillIdx: TDictionary<Cardinal, Integer>;
    Outls: array of TCdrOutl;
    OutlIdx: TDictionary<Cardinal, Integer>;
    Images: array of TCdrImage;
    ImageIdx: TDictionary<Cardinal, Integer>;
    Patterns: array of TCdrPattern;
    PatternIdx: TDictionary<Cardinal, Integer>;
    FontNames: TDictionary<Cardinal, string>;
    FontEnc: TDictionary<Cardinal, Integer>;
    Styles: array of TCdrStyle;
    StyleIdx: TDictionary<Cardinal, Integer>;
    Texts: array of TCdrText;
    TextIdx: TDictionary<Cardinal, Integer>;
    Palette: TDictionary<Cardinal, Cardinal>;   // document palette: colour id -> RGB
    Pages: array of TPagePt;
    PageW, PageH: Double;
    constructor Create;
    destructor Destroy; override;
    // primitives that depend on the version
    function Coord(var R: TRd): Double;
    function Uns(var R: TRd): Cardinal;
    function Int(var R: TRd): Integer;
    function Ang(var R: TRd): Double;
    function ReadColor(var R: TRd): TCdrColor;
    function Rgb(const C: TCdrColor): Cardinal;
    function BmpRgb(Model: Integer; V: Cardinal): Cardinal;
    function ChunkData(const B: TBytes; Pos, Len: Integer; out R: TRd): Boolean;
    procedure SetVersion(V: Integer);
    // resources
    procedure ReadFild(var R: TRd);
    procedure ReadOutl(var R: TRd);
    procedure ReadBmp(var R: TRd; Len: Integer);
    procedure ReadBmpf(var R: TRd; Len: Integer);
    procedure ReadFont(var R: TRd);
    procedure ReadUidr(var R: TRd);
    procedure ReadStlt(var R: TRd);
    procedure ReadTxsm(var R: TRd);
    procedure ReadTxsm16(var R: TRd);
    procedure ReadTxsm6(var R: TRd);
    procedure ReadTxsm5(var R: TRd);
    procedure ReadStyleJson(var R: TRd; Len: Integer; var St: TCdrStyle);
    procedure SkipX3Optional(var R: TRd);
    procedure AddText(TextId, StyleId: Cardinal; const Data: TBytes; const Descr: TBytes;
      const Ovr: TDictionary<Integer, TCdrStyle>);
    function GetStyle(Id: Cardinal): TCdrStyle;
    function FindFill(Id: Cardinal; out F: TCdrFill): Boolean;
    function FindOutl(Id: Cardinal; out O: TCdrOutl): Boolean;
    function ParseColourString(const S: string; out C: TCdrColor): Boolean;
  end;

function DefaultFill: TCdrFill;
begin
  Result := Default(TCdrFill);
  Result.Kind := -1;
end;

function DefaultOutl: TCdrOutl;
begin
  Result := Default(TCdrOutl);
  Result.LineType := -1;
end;

function DefaultStyle: TCdrStyle;
begin
  Result := Default(TCdrStyle);
  Result.CharSet := -1;
  Result.Fill := DefaultFill;
  Result.Outl := DefaultOutl;
end;

procedure OverrideStyle(var S: TCdrStyle; const O: TCdrStyle);
begin
  if (O.CharSet <> -1) or (O.Font <> '') then
  begin
    S.CharSet := O.CharSet;
    S.Font := O.Font;
  end;
  if Abs(O.Size) > 1e-9 then S.Size := O.Size;
  if O.Align <> 0 then S.Align := O.Align;
  if O.Outl.LineType <> -1 then S.Outl := O.Outl;
  if O.Fill.Kind <> -1 then S.Fill := O.Fill;
end;

constructor TCdrDoc.Create;
begin
  inherited Create;
  FillIdx := TDictionary<Cardinal, Integer>.Create;
  OutlIdx := TDictionary<Cardinal, Integer>.Create;
  ImageIdx := TDictionary<Cardinal, Integer>.Create;
  PatternIdx := TDictionary<Cardinal, Integer>.Create;
  FontNames := TDictionary<Cardinal, string>.Create;
  FontEnc := TDictionary<Cardinal, Integer>.Create;
  StyleIdx := TDictionary<Cardinal, Integer>.Create;
  TextIdx := TDictionary<Cardinal, Integer>.Create;
  Palette := TDictionary<Cardinal, Cardinal>.Create;
  PageW := 8.5; PageH := 11;
  Prec32 := True;
end;

destructor TCdrDoc.Destroy;
begin
  FillIdx.Free; OutlIdx.Free; ImageIdx.Free; PatternIdx.Free;
  FontNames.Free; FontEnc.Free; StyleIdx.Free; TextIdx.Free; Palette.Free;
  inherited Destroy;
end;

procedure TCdrDoc.SetVersion(V: Integer);
begin
  Version := V;
  Prec32 := V >= 600;
end;

function TCdrDoc.Coord(var R: TRd): Double;
begin
  if Prec32 then Result := R.S32 / 254000.0 else Result := R.S16 / 1000.0;
end;

function TCdrDoc.Uns(var R: TRd): Cardinal;
begin
  if Prec32 then Result := R.U32 else Result := R.U16;
end;

function TCdrDoc.Int(var R: TRd): Integer;
begin
  if Prec32 then Result := R.S32 else Result := R.S16;
end;

function TCdrDoc.Ang(var R: TRd): Double;
begin
  if Prec32 then Result := Pi * R.S32 / 180000000.0 else Result := Pi * R.S16 / 1800.0;
end;

// X6+ chunks of 16 bytes point into an external stream (or carry the data
// inline after the stream number 0xFFFFFFFF and the length)
function TCdrDoc.ChunkData(const B: TBytes; Pos, Len: Integer; out R: TRd): Boolean;
var sn, l2, ofs: Cardinal;
begin
  Result := True;
  if (Version >= 1600) and (Len = $10) then
  begin
    sn := RdLE32(B, Pos); l2 := RdLE32(B, Pos + 4);
    if sn = $FFFFFFFF then
    begin
      R.Init(B, Pos + 8, Pos + 8 + Integer(Min(l2, $7FFFFFF0)));
      Exit;
    end;
    if sn < Cardinal(Length(Streams)) then
    begin
      ofs := RdLE32(B, Pos + 8);
      R.Init(Streams[sn], Integer(Min(ofs, $7FFFFFF0)), Integer(Min(Int64(ofs) + l2, $7FFFFFF0)));
      Exit(R.Left > 0);
    end;
    R.Init(nil, 0, 0);
    Exit(False);
  end;
  R.Init(B, Pos, Pos + Len);
end;

function TCdrDoc.ReadColor(var R: TRd): TCdrColor;
var cc, mm, yy, kk: Integer;
begin
  Result := Default(TCdrColor);
  if Version >= 500 then
  begin
    Result.Model := R.U16;
    if (Result.Model = $01) and (Version >= 1300) then Result.Model := $19;
    if Result.Model = $1E then
    begin
      Result.Model := $19; Result.Pal := $1E;
    end
    else
    begin
      Result.Pal := R.U16;
      R.Skip(4);
    end;
    Result.Value := R.U32;
  end
  else if Version >= 400 then
  begin
    Result.Model := R.U16;
    cc := R.U16; mm := R.U16; yy := R.U16; kk := R.U16;
    Result.Value := (Cardinal(kk and $FF) shl 24) or (Cardinal(yy and $FF) shl 16) or
      (Cardinal(mm and $FF) shl 8) or Cardinal(cc and $FF);
    R.Skip(2);
  end
  else
  begin
    Result.Model := R.U8;
    Result.Value := R.U32;
  end;
end;

function TCdrDoc.Rgb(const C: TCdrColor): Cardinal;
var
  model: Integer;
  v, pv: Cardinal;
  c0, c1, c2, c3, tint: Integer;
  sr, sg, sb, sat, br, li, tr, tg, tb, y, i, q, rr, gg, bb: Double;
begin
  model := C.Model;
  v := C.Value;
  if model = $19 then
  begin
    // spot colour: the document palette, otherwise a neutral grey by tint
    tint := (v shr 16) and $FFFF;
    if Palette.TryGetValue(v and $FFFF, pv) then
    begin
      if (tint > 0) and (tint < 100) then
      begin
        rr := ((pv shr 16) and $FF) * tint / 100 + 255 * (100 - tint) / 100;
        gg := ((pv shr 8) and $FF) * tint / 100 + 255 * (100 - tint) / 100;
        bb := (pv and $FF) * tint / 100 + 255 * (100 - tint) / 100;
        Exit((Cardinal(ClampB(rr)) shl 16) or (Cardinal(ClampB(gg)) shl 8) or Cardinal(ClampB(bb)));
      end;
      Exit(pv);
    end;
    if (tint > 100) then tint := 100;
    Exit(CmykToRgb(0, 0, 0, tint * 2.55));
  end;
  c0 := v and $FF; c1 := (v shr 8) and $FF; c2 := (v shr 16) and $FF; c3 := (v shr 24) and $FF;
  case model of
    $01, $02, $15: Result := CmykToRgb(c0 * 2.55, c1 * 2.55, c2 * 2.55, c3 * 2.55);
    $03, $11: Result := CmykToRgb(c0, c1, c2, c3);
    $04: Result := (Cardinal(255 - c0) shl 16) or (Cardinal(255 - c1) shl 8) or Cardinal(255 - c2);
    $05: Result := (Cardinal(c2) shl 16) or (Cardinal(c1) shl 8) or Cardinal(c0);
    $06: begin   // HSB
           HueRgb((c1 shl 8) or c0, sr, sg, sb);
           sat := c2 / 255; br := c3 / 255;
           Result := (Cardinal(ClampB(255 * (1 - sat + sat * sr) * br)) shl 16) or
             (Cardinal(ClampB(255 * (1 - sat + sat * sg) * br)) shl 8) or Cardinal(ClampB(255 * (1 - sat + sat * sb) * br));
         end;
    $07: begin   // HLS
           HueRgb((c1 shl 8) or c0, sr, sg, sb);
           li := c2 / 255; sat := c3 / 255;
           tr := 2 * sat * sr + 1 - sat; tg := 2 * sat * sg + 1 - sat; tb := 2 * sat * sb + 1 - sat;
           if li < 0.5 then
             Result := (Cardinal(ClampB(255 * li * tr)) shl 16) or (Cardinal(ClampB(255 * li * tg)) shl 8) or
               Cardinal(ClampB(255 * li * tb))
           else
             Result := (Cardinal(ClampB(255 * ((1 - li) * tr + 2 * li - 1))) shl 16) or
               (Cardinal(ClampB(255 * ((1 - li) * tg + 2 * li - 1))) shl 8) or Cardinal(ClampB(255 * ((1 - li) * tb + 2 * li - 1)));
         end;
    $08: if c0 <> 0 then Result := 0 else Result := $FFFFFF;
    $09: Result := (Cardinal(c0) shl 16) or (Cardinal(c0) shl 8) or Cardinal(c0);
    $0B: begin   // YIQ255
           y := c0 - 100; if y < 0 then y := y / 100 else y := y / 155; y := y * 0.5 + 0.5;
           i := c1 - 100; if i <= 0 then i := i / 100 else i := i / 155; i := i * 0.5957;
           q := c2 - 100; if q <= 0 then q := q / 100 else q := q / 155; q := q * 0.5226;
           rr := EnsureRange(y + 0.9563 * i + 0.6210 * q, 0, 1);
           gg := EnsureRange(y - 0.2127 * i - 0.6474 * q, 0, 1);
           bb := EnsureRange(y - 1.1070 * i + 1.7046 * q, 0, 1);
           Result := (Cardinal(ClampB(255 * rr)) shl 16) or (Cardinal(ClampB(255 * gg)) shl 8) or Cardinal(ClampB(255 * bb));
         end;
    $0C: Result := LabToRgb(c0 * 100 / 255, ShortInt(c1), ShortInt(c2));
    $12: Result := LabToRgb(c0 * 100 / 255, ShortInt(Byte(c1 - $80)), ShortInt(Byte(c2 - $80)));
    $14: begin
           c0 := ClampB(255 * c0 / 100);
           Result := (Cardinal(c0) shl 16) or (Cardinal(c0) shl 8) or Cardinal(c0);
         end;
  else
    Result := 0;
  end;
end;

// colours of bitmap pixels: bitmap colour models map onto the drawing ones
function TCdrDoc.BmpRgb(Model: Integer; V: Cardinal): Cardinal;
var c: TCdrColor;
begin
  c := Default(TCdrColor);
  c.Value := V;
  case Model of
    1, 10: c.Model := 5;
    2: c.Model := 4;
    3: c.Model := 3;
    4: c.Model := 6;
    5: c.Model := 9;
    6: c.Model := 8;
    7: c.Model := 7;
    8, 9: Exit(V and $FFFFFF);
    11: c.Model := 18;
  else
    Exit(V and $FFFFFF);
  end;
  Result := Rgb(c);
end;

// "CMYK,USER,0,0,0,100,100,guid,..." colour strings of the X6+ text styles
function TCdrDoc.ParseColourString(const S: string; out C: TCdrColor): Boolean;
var
  parts: TStringList;
  i, n: Integer;
  vals: array of Integer;
  model: string;
begin
  C := Default(TCdrColor);
  Result := False;
  parts := TStringList.Create;
  try
    parts.StrictDelimiter := True;
    parts.Delimiter := ',';
    parts.DelimitedText := S;
    if parts.Count < 3 then Exit;
    // a fallback colour list after "~" is more reliable than spot colours
    for i := 0 to parts.Count - 1 do
      if (parts[i] = '~') and (i + 3 < parts.Count) then
      begin
        model := '';
        // ~,<name>,<n>,<colour string>,~,...
        Break;
      end;
    model := UpperCase(Trim(parts[0]));
    if model = 'CMYK' then C.Model := 2
    else if model = 'CMYK255' then C.Model := 3
    else if model = 'RGB255' then C.Model := 5
    else if model = 'HSB' then C.Model := 6
    else if model = 'HLS' then C.Model := 7
    else if model = 'GRAY255' then C.Model := 9
    else if model = 'YIQ255' then C.Model := 11
    else if model = 'LAB' then C.Model := 12
    else if model = 'LAB255' then C.Model := 18
    else if model = 'REGCOLOR' then C.Model := 20
    else if (model = 'SPOT') or (model = 'PANTONEHX') then C.Model := $19
    else Exit;
    SetLength(vals, 0);
    for i := 2 to parts.Count - 1 do
    begin
      n := StrToIntDef(Trim(parts[i]), -1);
      if n < 0 then Break;
      SetLength(vals, Length(vals) + 1);
      vals[High(vals)] := n;
    end;
    n := Length(vals);
    if n >= 5 then C.Value := Cardinal(vals[0]) or (Cardinal(vals[1]) shl 8) or (Cardinal(vals[2]) shl 16) or (Cardinal(vals[3]) shl 24)
    else if n >= 4 then
    begin
      if C.Model = 5 then C.Value := Cardinal(vals[2]) or (Cardinal(vals[1]) shl 8) or (Cardinal(vals[0]) shl 16)
      else if C.Model in [6, 7] then C.Value := Cardinal(vals[0]) or (Cardinal(vals[1]) shl 16) or (Cardinal(vals[2]) shl 24)
      else C.Value := Cardinal(vals[0]) or (Cardinal(vals[1]) shl 8) or (Cardinal(vals[2]) shl 16);
    end
    else if n >= 2 then
    begin
      if C.Model in [$19, 14] then C.Value := (Cardinal(vals[1]) shl 16) or Cardinal(vals[0])
      else C.Value := vals[0];
    end
    else if n = 1 then C.Value := vals[0]
    else Exit;
    Result := True;
  finally
    parts.Free;
  end;
end;

function TCdrDoc.FindFill(Id: Cardinal; out F: TCdrFill): Boolean;
var i: Integer;
begin
  Result := FillIdx.TryGetValue(Id, i);
  if Result then F := Fills[i] else F := DefaultFill;
end;

function TCdrDoc.FindOutl(Id: Cardinal; out O: TCdrOutl): Boolean;
var i: Integer;
begin
  Result := OutlIdx.TryGetValue(Id, i);
  if Result then O := Outls[i] else O := DefaultOutl;
end;

function TCdrDoc.GetStyle(Id: Cardinal): TCdrStyle;
var
  chain: array of Integer;
  i, k: Integer;
  cur: Cardinal;
begin
  Result := DefaultStyle;
  chain := nil;
  cur := Id;
  while (cur <> 0) and StyleIdx.TryGetValue(cur, i) and (Length(chain) < 32) do
  begin
    SetLength(chain, Length(chain) + 1);
    chain[High(chain)] := i;
    cur := Styles[i].Parent;
  end;
  for k := High(chain) downto 0 do OverrideStyle(Result, Styles[chain[k]]);
end;

procedure TCdrDoc.SkipX3Optional(var R: TRd);
var t: Cardinal;
begin
  if Version < 1300 then Exit;
  while R.Left >= 4 do
  begin
    t := R.U32;
    if t = $640 then R.Skip(R.U32)
    else if t = $514 then R.Skip(4)
    else begin R.Skip(-4); Exit; end;
  end;
end;

// ---- fills, outlines ----

procedure TCdrDoc.ReadFild(var R: TRd);
var
  id: Cardinal;
  F: TCdrFill;
  n, i, tw, th: Integer;
  fl: Byte;
begin
  id := R.U32;
  if Version >= 1300 then R.Skip(8);
  F := DefaultFill;
  F.Kind := R.U16;
  case F.Kind of
    1: begin
         if Version >= 1300 then R.Skip(13) else R.Skip(2);
         F.Color1 := ReadColor(R);
       end;
    2: begin
         if Version >= 1300 then R.Skip(8) else R.Skip(2);
         F.GType := R.U8;
         if Version >= 1300 then begin R.Skip(17); F.GEdge := R.S16; end
         else if Version >= 600 then begin R.Skip(19); F.GEdge := R.S32; end
         else begin R.Skip(11); F.GEdge := R.S16; end;
         F.GAngle := Ang(R);
         F.GCx := Int(R); F.GCy := Int(R);
         if Version >= 600 then R.Skip(2);
         Uns(R);           // mode
         R.U8;             // mid point
         R.Skip(1);
         n := Uns(R) and $FFFF;
         if Version >= 1300 then R.Skip(3);
         if n > R.Left div 8 then n := R.Left div 8;
         SetLength(F.Stops, n);
         for i := 0 to n - 1 do
         begin
           F.Stops[i].Color := ReadColor(R);
           if Version >= 1500 then R.Skip(26)
           else if Version >= 1300 then R.Skip(5);
           F.Stops[i].Offset := (Uns(R) and $FFFF) / 100;
           if Version >= 1300 then R.Skip(3);
         end;
       end;
    7, 8:
       begin
         if Version >= 1300 then R.Skip(8) else R.Skip(2);
         F.ImgId := R.U32;
         tw := Int(R); th := Int(R);
         if Version < 900 then R.Skip(4) else R.Skip(4);
         R.U16;
         fl := R.U8;
         F.ImgFlags := fl;
         if Version < 600 then begin F.ImgW := tw / 1000; F.ImgH := th / 1000; end
         else begin F.ImgW := tw / 254000; F.ImgH := th / 254000; end;
         if ((fl and 4) <> 0) and (Version < 900) then
         begin
           F.ImgRel := True; F.ImgW := tw / 100; F.ImgH := th / 100;
         end;
         if Version >= 1300 then R.Skip(6) else R.Skip(1);
         F.Color1 := ReadColor(R);
         if Version >= 1600 then R.Skip(31)
         else if Version >= 1300 then R.Skip(10);
         F.Color2 := ReadColor(R);
       end;
    9, 10, 11:
       begin
         if Version >= 1300 then
         begin
           SkipX3Optional(R);
           R.Skip(-4);
         end
         else R.Skip(2);
         F.ImgId := Uns(R);
         if (F.Kind = 11) and (Version < 600) then
         begin
           F.ImgRel := True; F.ImgW := 1; F.ImgH := 1;
         end
         else
         begin
           tw := Uns(R); th := Uns(R);
           R.Skip(4);
           R.U16;
           fl := R.U8;
           F.ImgFlags := fl;
           if Version < 600 then begin F.ImgW := tw / 1000; F.ImgH := th / 1000; end
           else begin F.ImgW := tw / 254000; F.ImgH := th / 254000; end;
           if ((fl and 4) <> 0) and (Version < 900) then
           begin
             F.ImgRel := True; F.ImgW := tw / 100; F.ImgH := th / 100;
           end;
           if Version >= 1300 then R.Skip(17) else R.Skip(21);
           if Version >= 600 then F.ImgId := Uns(R);
         end;
         if (F.Kind = 9) and (Version < 600) then F.Kind := 10;
       end;
  end;
  if FillIdx.TryGetValue(id, i) then Fills[i] := F
  else
  begin
    i := Length(Fills);
    SetLength(Fills, i + 1);
    Fills[i] := F;
    FillIdx.Add(id, i);
  end;
end;

procedure TCdrDoc.ReadOutl(var R: TRd);
var
  id, cid, clen: Cardinal;
  O: TCdrOutl;
  n, i, guard: Integer;
begin
  id := R.U32;
  if Version >= 1300 then
  begin
    cid := 0; clen := 0; guard := 0;
    while cid <> 1 do
    begin
      R.Skip(clen);
      cid := R.U32; clen := R.U32;
      Inc(guard);
      if (R.Left <= 0) or (guard > 64) then Exit;
    end;
  end;
  O := DefaultOutl;
  O.LineType := R.U16;
  O.Caps := R.U16;
  O.Join := R.U16;
  if (Version < 1300) and (Version >= 600) then R.Skip(2);
  O.Width := Coord(R);
  O.Stretch := R.U16 / 100;
  if Version >= 600 then R.Skip(2);
  Ang(R);
  if Version >= 1300 then R.Skip(46)
  else if Version >= 600 then R.Skip(52);
  O.Color := ReadColor(R);
  if Version < 600 then R.Skip(10) else R.Skip(16);
  n := R.U16;
  if n > R.Left div 2 then n := R.Left div 2;
  SetLength(O.Dash, n);
  for i := 0 to n - 1 do O.Dash[i] := R.U16;
  if OutlIdx.TryGetValue(id, i) then Outls[i] := O
  else
  begin
    i := Length(Outls);
    SetLength(Outls, i + 1);
    Outls[i] := O;
    OutlIdx.Add(id, i);
  end;
end;

// ---- bitmaps ----

// a BMP file (CorelDRAW 4 and older keep these)
function DecodeDib(const D: TBytes; Ofs: Integer; out Img: TCdrImage): Boolean;
var
  hs, w, h, bpp, comp, ncol, stride, x, y, i, ty, v, bits: Integer;
  topDown: Boolean;
  pal: array[0..255] of Cardinal;
  p, pix: Integer;
begin
  Result := False;
  Img.W := 0; Img.H := 0; Img.Px := nil;
  if RdLE16(D, Ofs) <> $4D42 then Exit;
  bits := Ofs + Integer(RdLE32(D, Ofs + 10));
  p := Ofs + 14;
  hs := RdLE32(D, p);
  if hs < 40 then Exit;
  w := Integer(RdLE32(D, p + 4)); h := Integer(RdLE32(D, p + 8));
  bpp := RdLE16(D, p + 14); comp := RdLE32(D, p + 16);
  ncol := RdLE32(D, p + 32);
  topDown := h < 0; h := Abs(h);
  if (w <= 0) or (h <= 0) or (Int64(w) * h > 64000000) or (comp <> 0) or not (bpp in [1, 4, 8, 24, 32]) then Exit;
  if (ncol = 0) and (bpp <= 8) then ncol := 1 shl bpp;
  for i := 0 to Min(ncol, 256) - 1 do
    pal[i] := RdLE32(D, p + hs + i * 4) and $FFFFFF;
  stride := ((w * bpp + 31) div 32) * 4;
  Img.W := w; Img.H := h;
  SetLength(Img.Px, w * h);
  for y := 0 to h - 1 do
  begin
    if topDown then ty := y else ty := h - 1 - y;
    pix := bits + y * stride;
    for x := 0 to w - 1 do
    begin
      v := 0;
      case bpp of
        1: if pix + x shr 3 < Length(D) then v := pal[(D[pix + x shr 3] shr (7 - x and 7)) and 1];
        4: if pix + x shr 1 < Length(D) then
             if (x and 1) = 0 then v := pal[D[pix + x shr 1] shr 4] else v := pal[D[pix + x shr 1] and 15];
        8: if pix + x < Length(D) then v := pal[D[pix + x]];
        24, 32: if pix + x * (bpp div 8) + 2 < Length(D) then
             v := D[pix + x * (bpp div 8)] or (D[pix + x * (bpp div 8) + 1] shl 8) or (D[pix + x * (bpp div 8) + 2] shl 16);
      end;
      Img.Px[ty * w + x] := $FF000000 or Cardinal(v);
    end;
  end;
  Result := True;
end;

procedure TCdrDoc.ReadBmp(var R: TRd; Len: Integer);
var
  id: Cardinal;
  cm, w, h, bpp, size, npal, i, j, x, lw, o: Integer;
  pal: array of Cardinal;
  Img: TCdrImage;
  v: Cardinal;
  base, k: Integer;
begin
  id := Uns(R);
  Img := Default(TCdrImage);
  if Version < 500 then
  begin
    if not DecodeDib(R.B, R.P, Img) then Exit;
  end
  else
  begin
    if Version < 600 then R.Skip(14)
    else if Version < 700 then R.Skip(46)
    else R.Skip(50);
    cm := R.U32; R.Skip(4);
    w := R.U32; h := R.U32; R.Skip(4);
    bpp := R.U32; R.Skip(4);
    size := R.U32; R.Skip(32);
    pal := nil;
    if (bpp < 24) and (cm <> 5) and (cm <> 6) then
    begin
      R.Skip(2);
      npal := R.U16;
      if npal > R.Left div 3 then npal := R.Left div 3;
      SetLength(pal, npal);
      for i := 0 to npal - 1 do
      begin
        v := R.U8; v := v or (Cardinal(R.U8) shl 8); v := v or (Cardinal(R.U8) shl 16);
        pal[i] := v;
      end;
    end;
    if (w <= 0) or (h <= 0) or (size <= 0) or (Int64(w) * h > 64000000) then Exit;
    if size > R.Left then size := R.Left;
    base := R.P;
    lw := size div h;
    if lw <= 0 then Exit;
    Img.W := w; Img.H := h;
    SetLength(Img.Px, w * h);
    // rows are stored bottom-up
    for j := 0 to h - 1 do
    begin
      o := base + j * lw;
      for x := 0 to w - 1 do
      begin
        v := 0;
        if cm = 6 then
        begin
          k := o + x shr 3;
          if (k < base + size) and (((R.B[k] shr (7 - x and 7)) and 1) <> 0) then v := $FFFFFF;
        end
        else if cm = 5 then
        begin
          if x < lw then v := BmpRgb(5, R.B[o + x]);
        end
        else if Length(pal) > 0 then
        begin
          if bpp = 8 then k := R.B[o + x]
          else if bpp = 4 then begin k := R.B[o + x shr 1]; if (x and 1) = 0 then k := k shr 4 else k := k and 15; end
          else if bpp = 1 then k := (R.B[o + x shr 3] shr (7 - x and 7)) and 1
          else k := 0;
          if k >= Length(pal) then k := High(pal);
          v := BmpRgb(cm, pal[k]);
        end
        else if bpp = 24 then
        begin
          if 3 * x + 2 < lw then
            v := BmpRgb(cm, Cardinal(R.B[o + 3 * x]) or (Cardinal(R.B[o + 3 * x + 1]) shl 8) or (Cardinal(R.B[o + 3 * x + 2]) shl 16));
        end
        else if bpp = 32 then
        begin
          if 4 * x + 3 < lw then
            v := BmpRgb(cm, Cardinal(R.B[o + 4 * x]) or (Cardinal(R.B[o + 4 * x + 1]) shl 8) or
              (Cardinal(R.B[o + 4 * x + 2]) shl 16) or (Cardinal(R.B[o + 4 * x + 3]) shl 24));
        end
        else if bpp = 8 then v := BmpRgb(5, R.B[o + x]);
        Img.Px[(h - 1 - j) * w + x] := $FF000000 or (v and $FFFFFF);
      end;
    end;
    // a transparency mask may follow the pixels: another "RI" image record
    // of the same size, 8 (or 1) bits per pixel, 0 = transparent
    k := base + size;
    if (k + 78 <= R.E) and (R.B[k] = Ord('R')) and (R.B[k + 1] = Ord('I')) then
    begin
      R.P := k + 14;
      R.U32; R.U32;
      if (Integer(R.U32) = w) and (Integer(R.U32) = h) then
      begin
        R.U32;
        bpp := R.U32;
        lw := R.U32;
        size := R.U32;
        R.Skip(32);
        if (bpp in [1, 8]) and (lw > 0) and (Int64(lw) * h <= R.Left) then
        begin
          base := R.P;
          for j := 0 to h - 1 do
          begin
            o := base + j * lw;
            for x := 0 to w - 1 do
            begin
              if bpp = 8 then v := R.B[o + x]
              else if ((R.B[o + x shr 3] shr (7 - x and 7)) and 1) <> 0 then v := 255
              else v := 0;
              Img.Px[(h - 1 - j) * w + x] := (Img.Px[(h - 1 - j) * w + x] and $FFFFFF) or (v shl 24);
            end;
          end;
        end;
      end;
    end;
  end;
  if ImageIdx.TryGetValue(id, i) then Images[i] := Img
  else
  begin
    i := Length(Images);
    SetLength(Images, i + 1);
    Images[i] := Img;
    ImageIdx.Add(id, i);
  end;
end;

procedure TCdrDoc.ReadBmpf(var R: TRd; Len: Integer);
var
  id: Cardinal;
  w, h, bpp, ds, i: Integer;
  P: TCdrPattern;
begin
  id := R.U32;
  if R.U32 <> 40 then Exit;
  w := R.U32; h := R.U32;
  R.Skip(2);
  bpp := R.U16;
  if bpp <> 1 then Exit;
  R.Skip(4);
  ds := R.U32;
  if (ds <= 0) or (w <= 0) or (h <= 0) or (w > 4096) or (h > 4096) then Exit;
  R.Skip((Len - 4) - ds - 24);
  if ds > R.Left then Exit;
  P.W := w; P.H := h;
  SetLength(P.Bits, ds);
  Move(R.B[R.P], P.Bits[0], ds);
  if PatternIdx.TryGetValue(id, i) then Patterns[i] := P
  else
  begin
    i := Length(Patterns);
    SetLength(Patterns, i + 1);
    Patterns[i] := P;
    PatternIdx.Add(id, i);
  end;
end;

procedure TCdrDoc.ReadFont(var R: TRd);
var
  id, enc, c, st: Integer;
  name: string;
  nb: TBytes;
  u: string;
begin
  id := R.U16;
  enc := R.U16;
  R.Skip(14);
  name := '';
  if Version >= 1200 then
  begin
    st := R.P;
    while R.Left >= 2 do
    begin
      c := R.U16;
      if c = 0 then Break;
    end;
    name := Utf16ToUtf8(R.B, st, R.P - st);
  end
  else
  begin
    st := R.P;
    while R.Left >= 1 do
      if R.U8 = 0 then Break;
    SetLength(nb, Max(0, R.P - st - 1));
    if Length(nb) > 0 then Move(R.B[st], nb[0], Length(nb));
    name := CodePageToUtf8(nb, 0, Length(nb), enc);
  end;
  // encoding hints at the end of some font names ("Arial CE", "Arial Cyr")
  if enc = 0 then
  begin
    u := UpperCase(name);
    if (Pos(' CE', u) > 0) and (Pos(' CE', u) = Length(u) - 2) then begin enc := $EE; SetLength(name, Length(name) - 3); end
    else if (Pos(' CYR', u) > 0) and (Pos(' CYR', u) = Length(u) - 3) then begin enc := $CC; SetLength(name, Length(name) - 4); end;
  end;
  if not FontNames.ContainsKey(id) then
  begin
    FontNames.Add(id, name);
    FontEnc.AddOrSetValue(id, enc);
  end;
end;

procedure TCdrDoc.ReadUidr(var R: TRd);
var
  cid: Cardinal;
  c: TCdrColor;
begin
  cid := R.U32;
  R.U32;
  R.Skip(36);
  c := ReadColor(R);
  if c.Model <> $19 then Palette.AddOrSetValue(cid, Rgb(c));
end;

// ---- text styles ----

procedure TCdrDoc.ReadStlt(var R: TRd);
var
  numRecords, numFills, numOutls, numFonts, numAligns, n, i, fontsSize, num: Integer;
  fillIds, outlIds, fontIds, fontEncs, aligns: TDictionary<Cardinal, Cardinal>;
  fontSizes: TDictionary<Cardinal, Double>;
  fid, sid, styleId, parent, nameLen, fillId, outlId, fontRecId, alignId: Cardinal;
  set11: Boolean;
  st: TCdrStyle;
  v: Cardinal;
  sz: Double;
  k: Integer;
  F: TCdrFill;
  O: TCdrOutl;
begin
  if Version < 700 then Exit;
  numRecords := R.U32;
  if numRecords = 0 then Exit;
  fillIds := TDictionary<Cardinal, Cardinal>.Create;
  outlIds := TDictionary<Cardinal, Cardinal>.Create;
  fontIds := TDictionary<Cardinal, Cardinal>.Create;
  fontEncs := TDictionary<Cardinal, Cardinal>.Create;
  aligns := TDictionary<Cardinal, Cardinal>.Create;
  fontSizes := TDictionary<Cardinal, Double>.Create;
  try
    numFills := R.U32;
    if Version >= 1300 then n := 60 else n := 12;
    if numFills > R.Left div n then numFills := R.Left div n;
    for i := 0 to numFills - 1 do
    begin
      fid := R.U32; R.Skip(4); fillIds.AddOrSetValue(fid, R.U32);
      if Version >= 1300 then R.Skip(48);
    end;
    numOutls := R.U32;
    if numOutls > R.Left div 12 then numOutls := R.Left div 12;
    for i := 0 to numOutls - 1 do
    begin
      fid := R.U32; R.Skip(4); outlIds.AddOrSetValue(fid, R.U32);
    end;
    numFonts := R.U32;
    fontsSize := 4 + 4 + 8 + 4;
    if Version < 1000 then Inc(fontsSize, 24) else Inc(fontsSize, 40);
    if not Prec32 then Dec(fontsSize, 2);
    if numFonts > R.Left div fontsSize then numFonts := R.Left div fontsSize;
    for i := 0 to numFonts - 1 do
    begin
      fid := R.U32;
      if Version < 1000 then R.Skip(12) else R.Skip(20);
      fontIds.AddOrSetValue(fid, R.U16);
      fontEncs.AddOrSetValue(fid, R.U16);
      R.Skip(8);
      fontSizes.AddOrSetValue(fid, Coord(R));
      if Version < 1000 then R.Skip(12) else R.Skip(20);
    end;
    numAligns := R.U32;
    if numAligns > R.Left div 12 then numAligns := R.Left div 12;
    for i := 0 to numAligns - 1 do
    begin
      fid := R.U32; R.Skip(4); aligns.AddOrSetValue(fid, R.U32);
    end;
    n := R.U32; R.Skip(52 * n);         // intervals
    n := R.U32; R.Skip(152 * n);        // set5s
    n := R.U32; R.Skip(784 * n);        // tabs
    n := R.U32;                         // bullets
    for i := 0 to n - 1 do
    begin
      if R.Left < 16 then Break;
      R.Skip(40);
      if Version > 1300 then R.Skip(4);
      if Version >= 1300 then
      begin
        if R.U32 <> 0 then R.Skip(68) else R.Skip(12);
      end
      else
      begin
        R.Skip(20);
        if Version >= 1000 then R.Skip(8);
        if R.U32 <> 0 then R.Skip(8);
        R.Skip(8);
      end;
    end;
    n := R.U32;                         // indents
    k := 4 + 3 * 4;
    if not Prec32 then k := 4 + 3 * 2;
    if n > R.Left div k then n := R.Left div k;
    for i := 0 to n - 1 do
    begin
      R.U32; R.Skip(12); Coord(R); Coord(R); Coord(R);
    end;
    n := R.U32;                         // hyphens
    if Version >= 1300 then R.Skip(36 * n) else R.Skip(32 * n);
    n := R.U32; R.Skip(28 * n);         // drop caps
    set11 := False;
    if Version > 800 then
    begin
      set11 := True;
      n := R.U32; R.Skip(12 * n);
    end;
    for i := 0 to numRecords - 1 do
    begin
      if R.Left < 32 then Break;
      num := R.U32;
      styleId := R.U32;
      parent := R.U32;
      R.Skip(8);
      nameLen := R.U32;
      if Version >= 1200 then nameLen := nameLen * 2;
      R.Skip(nameLen);
      fillId := R.U32;
      outlId := R.U32;
      fontRecId := 0; alignId := 0;
      if num > 1 then
      begin
        fontRecId := R.U32; alignId := R.U32;
        R.U32; R.U32;
        if set11 then R.U32;
      end;
      if num > 2 then R.Skip(20);
      st := DefaultStyle;
      st.Parent := parent;
      if fontRecId <> 0 then
      begin
        if fontIds.TryGetValue(fontRecId, v) then
          if FontNames.ContainsKey(v) then
          begin
            st.Font := FontNames[v];
            if FontEnc.ContainsKey(v) then st.CharSet := FontEnc[v];
          end;
        if fontEncs.TryGetValue(fontRecId, v) and (v <> 0) then st.CharSet := v;
        if fontSizes.TryGetValue(fontRecId, sz) then st.Size := sz;
      end;
      if (alignId <> 0) and aligns.TryGetValue(alignId, v) then st.Align := v;
      if (fillId <> 0) and fillIds.TryGetValue(fillId, v) then
        if FindFill(v, F) then st.Fill := F;
      if (outlId <> 0) and outlIds.TryGetValue(outlId, v) then
        if FindOutl(v, O) then st.Outl := O;
      if StyleIdx.TryGetValue(styleId, k) then Styles[k] := st
      else
      begin
        k := Length(Styles);
        SetLength(Styles, k + 1);
        Styles[k] := st;
        StyleIdx.Add(styleId, k);
      end;
    end;
  finally
    fillIds.Free; outlIds.Free; fontIds.Free; fontEncs.Free; aligns.Free; fontSizes.Free;
  end;
end;

// JSON style strings of the X6+ text records
procedure TCdrDoc.ReadStyleJson(var R: TRd; Len: Integer; var St: TCdrStyle);
var
  s, v: string;
  L: TStringList;
  c: TCdrColor;
begin
  if Len > R.Left then
  begin
    Len := R.Left;
    if (Version < 1700) and Odd(Len) then Dec(Len);
  end;
  if Len <= 0 then Exit;
  if Version >= 1700 then s := UTF8Encode(TEncoding.UTF8.GetString(R.B, R.P, Len))
  else s := Utf16ToUtf8(R.B, R.P, Len);
  R.Skip(Len);
  L := TStringList.Create;
  try
    JsonFlatten(s, L);
    v := L.Values['character.latin.font'];
    if v <> '' then St.Font := v;
    v := L.Values['character.latin.charset'];
    if v <> '' then St.CharSet := StrToIntDef(v, 0)
    else if St.CharSet = -1 then St.CharSet := 0;
    v := L.Values['character.latin.size'];
    if v <> '' then St.Size := StrToFloatDef(v, 0, DefaultFormatSettings) / 254000;
    if L.IndexOfName('character.outline.width') >= 0 then
    begin
      St.Outl := DefaultOutl;
      St.Outl.LineType := 2;
      St.Outl.Stretch := 1;
      St.Outl.Width := StrToFloatDef(L.Values['character.outline.width'], 0) / 254000;
      if ParseColourString(L.Values['character.outline.color'], c) then St.Outl.Color := c;
    end;
    v := L.Values['character.fill.type'];
    if v <> '' then
    begin
      St.Fill := DefaultFill;
      St.Fill.Kind := StrToIntDef(v, 1);
      if ParseColourString(L.Values['character.fill.primaryColor'], c) then St.Fill.Color1 := c;
      St.Fill.Color2 := St.Fill.Color1;
    end;
    v := L.Values['paragraph.justify'];
    if v <> '' then St.Align := StrToIntDef(v, 0);
  finally
    L.Free;
  end;
end;

// Joins the characters of a paragraph into runs of equal style.
procedure TCdrDoc.AddText(TextId, StyleId: Cardinal; const Data: TBytes; const Descr: TBytes;
  const Ovr: TDictionary<Integer, TCdrStyle>);
var
  base, st: TCdrStyle;
  i, j, k, t: Integer;
  cur: Integer;
  para: TCdrPara;
  runStart: Integer;

  procedure Emit(StartByte, EndByte, D: Integer);
  var s: string; n: Integer; o: TCdrStyle;
  begin
    if EndByte <= StartByte then Exit;
    st := base;
    if Ovr.TryGetValue(D and $FE, o) then OverrideStyle(st, o);
    if (D and 1) <> 0 then s := Utf16ToUtf8(Data, StartByte, EndByte - StartByte)
    else s := CodePageToUtf8(Data, StartByte, EndByte - StartByte, Max(st.CharSet, 0));
    n := Length(para);
    SetLength(para, n + 1);
    para[n].Text := s;
    para[n].Style := st;
  end;

begin
  if Length(Data) = 0 then Exit;
  base := GetStyle(StyleId);
  para := nil;
  j := 0;
  cur := -1;
  runStart := 0;
  for i := 0 to High(Descr) do
  begin
    if j >= Length(Data) then Break;
    if Descr[i] <> cur then
    begin
      if cur >= 0 then Emit(runStart, j, cur);
      cur := Descr[i];
      runStart := j;
    end;
    Inc(j);
    if ((cur and 1) <> 0) and (j < Length(Data)) then Inc(j);
  end;
  if cur >= 0 then Emit(runStart, j, cur);
  if not TextIdx.TryGetValue(TextId, k) then
  begin
    k := Length(Texts);
    SetLength(Texts, k + 1);
    TextIdx.Add(TextId, k);
  end;
  t := Length(Texts[k].Paras);
  SetLength(Texts[k].Paras, t + 1);
  Texts[k].Paras[t] := para;
end;

procedure TCdrDoc.ReadTxsm16(var R: TRd);
var
  frameFlag, numFrames, textId, numPara, stlId, styleLen, numRecords, numChars, numBytes: Cardinal;
  i, j: Integer;
  topath, tlen: Cardinal;
  dflt: TCdrStyle;
  styles: TDictionary<Integer, TCdrStyle>;
  f1, f2: Integer;
  jl, el: Cardinal;
  st: TCdrStyle;
  descr, data: TBytes;
  d: UInt64;
begin
  frameFlag := R.U32;
  R.Skip(37);
  numFrames := R.U32;
  textId := 0;
  for i := 0 to Integer(numFrames) - 1 do
  begin
    if R.Left <= 0 then Exit;
    textId := R.U32;
    R.Skip(48);
    topath := R.U32;
    if topath = 1 then R.Skip(48) else R.Skip(8);
    if frameFlag = 0 then
    begin
      R.Skip(16);
      tlen := R.U32;
      if Version > 1600 then R.Skip(tlen) else R.Skip(tlen * 2);
    end;
  end;
  numPara := R.U32;
  styles := TDictionary<Integer, TCdrStyle>.Create;
  try
    for j := 0 to Integer(numPara) - 1 do
    begin
      if R.Left <= 0 then Exit;
      stlId := R.U32;
      R.Skip(1);
      if frameFlag <> 0 then R.Skip(1);
      styleLen := R.U32;
      if Version < 1700 then styleLen := styleLen * 2;
      dflt := DefaultStyle;
      ReadStyleJson(R, styleLen, dflt);
      numRecords := R.U32;
      styles.Clear;
      for i := 0 to Integer(numRecords) - 1 do
      begin
        if R.Left < 17 then Break;
        st := dflt;
        R.Skip(2);
        f1 := R.U16; f2 := R.U16;
        if (f2 and 4) <> 0 then
        begin
          el := R.U32; R.Skip(el * 2);
        end;
        if (f1 <> 0) or ((f2 and 4) <> 0) then
        begin
          jl := R.U32;
          if Version < 1700 then jl := jl * 2;
          ReadStyleJson(R, jl, st);
        end;
        styles.AddOrSetValue(i * 2, st);
      end;
      numChars := R.U32;
      if numChars > Cardinal(R.Left div 8) then numChars := R.Left div 8;
      SetLength(descr, numChars);
      for i := 0 to Integer(numChars) - 1 do
      begin
        d := R.U64 and $FFFFFFFF;
        descr[i] := Byte(((d shr 16) or (d and 1)) and $FF);
      end;
      numBytes := R.U32;
      if numBytes > Cardinal(R.Left) then Exit;
      SetLength(data, numBytes);
      if numBytes > 0 then Move(R.B[R.P], data[0], numBytes);
      R.Skip(numBytes + 1);
      // the paragraph style overrides go on top of the default style string
      if styles.Count = 0 then styles.Add(0, dflt);
      AddText(textId, stlId, data, descr, styles);
    end;
  finally
    styles.Free;
  end;
end;

procedure TCdrDoc.ReadTxsm(var R: TRd);
var
  frameFlag, numFrames, textId, numPara, stlId, numStyles, numChars, numBytes, topath: Cardinal;
  i, j: Integer;
  styles: TDictionary<Integer, TCdrStyle>;
  fl2, fl3: Integer;
  st: TCdrStyle;
  fid: Cardinal;
  descr, data: TBytes;
  d: Cardinal;
  F: TCdrFill;
  O: TCdrOutl;
begin
  if Version < 500 then Exit;
  if Version < 600 then begin ReadTxsm5(R); Exit; end;
  if Version < 700 then begin ReadTxsm6(R); Exit; end;
  if Version >= 1600 then begin ReadTxsm16(R); Exit; end;
  frameFlag := R.U32;
  R.Skip($20);
  if Version >= 1500 then R.Skip(1);
  if Version <= 700 then
  begin
    topath := R.U32;
    if topath = 1 then R.Skip(32);
  end;
  numFrames := R.U32;
  textId := 0;
  for i := 0 to Integer(numFrames) - 1 do
  begin
    if R.Left <= 0 then Exit;
    textId := R.U32;
    R.Skip(48);
    if Version > 700 then
    begin
      topath := R.U32;
      if topath = 1 then
      begin
        R.Skip(4);
        if Version > 1200 then R.Skip(8);
        R.Skip(24);
        if Version >= 1500 then R.Skip(8);
      end
      else if Version >= 1500 then R.Skip(8);
    end;
    if frameFlag = 0 then
    begin
      if Version >= 1500 then R.Skip(40)
      else if Version >= 1400 then R.Skip(36)
      else if Version > 800 then R.Skip(34)
      else if Version >= 800 then R.Skip(32)
      else R.Skip(36);
    end
    else if Version >= 1500 then R.Skip(4);
  end;
  numPara := R.U32;
  styles := TDictionary<Integer, TCdrStyle>.Create;
  try
    for j := 0 to Integer(numPara) - 1 do
    begin
      if R.Left <= 0 then Exit;
      stlId := R.U32;
      R.Skip(1);
      if (Version > 1200) and (frameFlag <> 0) then R.Skip(1);
      numStyles := R.U32;
      styles.Clear;
      for i := 0 to Integer(numStyles) - 1 do
      begin
        if R.Left <= 0 then Exit;
        R.U16;
        fl2 := R.U8;
        fl3 := 0;
        if Version >= 800 then fl3 := R.U8;
        st := DefaultStyle;
        if (fl2 and 1) <> 0 then
        begin
          fid := R.U16;
          if FontNames.ContainsKey(fid) then
          begin
            st.Font := FontNames[fid];
            if FontEnc.ContainsKey(fid) then st.CharSet := FontEnc[fid];
          end;
          fid := R.U16;
          if fid <> 0 then st.CharSet := fid;
        end;
        if (fl2 and 2) <> 0 then R.Skip(4);
        if (fl2 and 4) <> 0 then st.Size := Coord(R);
        if (fl2 and 8) <> 0 then R.Skip(4);
        if (fl2 and $10) <> 0 then R.Skip(4);
        if (fl2 and $20) <> 0 then R.Skip(4);
        if (fl2 and $40) <> 0 then
        begin
          fid := R.U32;
          if FindFill(fid, F) then st.Fill := F;
          if Version >= 1300 then R.Skip(48);
        end;
        if (fl2 and $80) <> 0 then
        begin
          fid := R.U32;
          if FindOutl(fid, O) then st.Outl := O;
        end;
        if (fl3 and 8) <> 0 then
        begin
          if Version >= 1300 then R.Skip(R.U32 * 2) else R.Skip(4);
        end;
        if (fl3 and $20) <> 0 then
        begin
          if R.U8 <> 0 then
          begin
            R.Skip(3);
            if Version >= 1500 then R.Skip(48);
          end
          else R.Skip(-1);
        end;
        styles.AddOrSetValue(2 * i, st);
      end;
      numChars := R.U32;
      if Version >= 1200 then
      begin
        if numChars > Cardinal(R.Left div 8) then numChars := R.Left div 8;
      end
      else if numChars > Cardinal(R.Left div 4) then numChars := R.Left div 4;
      SetLength(descr, numChars);
      for i := 0 to Integer(numChars) - 1 do
      begin
        if Version >= 1200 then d := R.U64 and $FFFFFFFF else d := R.U32;
        descr[i] := Byte(((d shr 16) or (d and 1)) and $FF);
      end;
      numBytes := numChars;
      if Version >= 1200 then numBytes := R.U32;
      if numBytes > Cardinal(R.Left) then Exit;
      SetLength(data, numBytes);
      if numBytes > 0 then Move(R.B[R.P], data[0], numBytes);
      R.Skip(numBytes + 1);
      AddText(textId, stlId, data, descr, styles);
    end;
  finally
    styles.Free;
  end;
end;

procedure TCdrDoc.ReadTxsm6(var R: TRd);
var
  frameFlag, topath, numFrames, textId, numPara, stlId, numSt, numChars: Cardinal;
  i, j: Integer;
  styles: TDictionary<Integer, TCdrStyle>;
  fl: Integer;
  st: TCdrStyle;
  fid: Cardinal;
  descr, data: TBytes;
  F: TCdrFill;
  O: TCdrOutl;
begin
  frameFlag := R.U32;
  R.Skip($18);
  topath := R.U32;
  if topath = 1 then R.Skip(32);
  numFrames := R.U32;
  textId := 0;
  for j := 0 to Integer(numFrames) - 1 do
  begin
    textId := R.U32;
    R.Skip(48);
    if frameFlag = 0 then R.Skip(8);
  end;
  numPara := R.U32;
  styles := TDictionary<Integer, TCdrStyle>.Create;
  try
    for j := 0 to Integer(numPara) - 1 do
    begin
      if R.Left <= 0 then Exit;
      stlId := R.U32;
      numSt := R.U32;
      styles.Clear;
      for i := 0 to Integer(numSt) - 1 do
      begin
        if R.Left <= 0 then Exit;
        st := DefaultStyle;
        fl := R.U8;
        R.Skip(3);
        if (fl and 1) <> 0 then
        begin
          fid := R.U16;
          if FontNames.ContainsKey(fid) then
          begin
            st.Font := FontNames[fid];
            if FontEnc.ContainsKey(fid) then st.CharSet := FontEnc[fid];
          end;
          fid := R.U16;
          if fid <> 0 then st.CharSet := fid;
        end
        else R.Skip(4);
        R.Skip(4);
        if (fl and 4) <> 0 then st.Size := Coord(R) else R.Skip(4);
        R.Skip(44);
        if (fl and $10) <> 0 then begin fid := R.U32; if FindFill(fid, F) then st.Fill := F; end;
        if (fl and $20) <> 0 then begin fid := R.U32; if FindOutl(fid, O) then st.Outl := O; end;
        styles.AddOrSetValue(2 * i, st);
      end;
      numChars := R.U32;
      R.Skip(4);
      if numChars > Cardinal(R.Left div 12) then numChars := R.Left div 12;
      SetLength(data, numChars);
      SetLength(descr, numChars);
      for i := 0 to Integer(numChars) - 1 do
      begin
        data[i] := R.U8;
        R.Skip(5);
        descr[i] := Byte(R.U8 shl 1);
        R.Skip(5);
      end;
      AddText(textId, stlId, data, descr, styles);
    end;
  finally
    styles.Free;
  end;
end;

procedure TCdrDoc.ReadTxsm5(var R: TRd);
var
  numFrames, textId, numPara, stlId, numSt, numChars: Integer;
  i, j: Integer;
  styles: TDictionary<Integer, TCdrStyle>;
  fl: Integer;
  st: TCdrStyle;
  fid: Cardinal;
  descr, data: TBytes;
  F: TCdrFill;
  O: TCdrOutl;
begin
  R.Skip(2);
  numFrames := R.U16;
  textId := 0;
  for j := 0 to numFrames - 1 do
  begin
    textId := R.U16;
    R.Skip(2);
  end;
  numPara := R.U16;
  styles := TDictionary<Integer, TCdrStyle>.Create;
  try
    for j := 0 to numPara - 1 do
    begin
      if R.Left <= 0 then Exit;
      stlId := R.U16;
      numSt := R.U16;
      styles.Clear;
      for i := 0 to numSt - 1 do
      begin
        if R.Left <= 0 then Exit;
        st := DefaultStyle;
        fl := R.U8;
        R.Skip(1);
        if (fl and 1) <> 0 then
        begin
          fid := R.U8;
          if FontNames.ContainsKey(fid) then
          begin
            st.Font := FontNames[fid];
            if FontEnc.ContainsKey(fid) then st.CharSet := FontEnc[fid];
          end;
          fid := R.U8;
          if fid <> 0 then st.CharSet := fid;
        end
        else R.Skip(2);
        R.Skip(6);
        if (fl and 4) <> 0 then st.Size := Coord(R) else R.Skip(2);
        R.Skip(2);
        if (fl and $10) <> 0 then begin fid := R.U32; if FindFill(fid, F) then st.Fill := F; end
        else R.Skip(4);
        if (fl and $20) <> 0 then begin fid := R.U32; if FindOutl(fid, O) then st.Outl := O; end
        else R.Skip(4);
        R.Skip(14);
        styles.AddOrSetValue(2 * i, st);
      end;
      numChars := R.U16;
      if numChars > R.Left div 8 then numChars := R.Left div 8;
      SetLength(data, numChars);
      SetLength(descr, numChars);
      for i := 0 to numChars - 1 do
      begin
        R.Skip(4);
        data[i] := R.U8;
        R.Skip(1);
        descr[i] := Byte((R.U16 shr 3) and $FF);
      end;
      AddText(textId, stlId, data, descr, styles);
    end;
  finally
    styles.Free;
  end;
end;

{$I XelCdrDraw.inc}

end.
