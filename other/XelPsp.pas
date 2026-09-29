unit XelPsp;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$R-}{$Q-}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Paint Shop Pro image (.psp/.pspimage/.tub/.pfr) decoder       //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// File layout (all little-endian):
//   * 32-byte signature "Paint Shop Pro Image File" + #10#26, then two WORDs
//     (major / minor file version; 3 = PSP 5, 4 = PSP 6, 5..14 = PSP 7..X).
//   * a flat list of blocks: "~BK"#0, WORD id, (v3 only: DWORD initial chunk
//     length), DWORD body length. From v4 on most block bodies begin with a
//     chunk whose first DWORD is its own size, so newer, longer chunks and
//     unknown sub-blocks can always be skipped by size.
//
// What we read:
//   * 0  General image attributes: size, bit depth (1/4/8/24), compression
//        (0 none, 1 RLE, 2 zlib "LZ77"), greyscale flag.
//   * 2  Colour palette (for 1/4/8-bit and greyscale documents).
//   * 10 Extended data: the transparent palette index.
//   * 16 Composite image bank: pre-flattened copies of the document. The full
//        size one (type 0) is preferred because it already contains vector,
//        adjustment and art-media layers. It is either a JPEG block or a
//        composite image block with ordinary channel sub-blocks.
//   * 3  Layer bank: when there is no full-size composite, the visible raster
//        layers are composited here - placed by their rectangles, with layer
//        opacity, transparency mask, user mask and the usual blend modes.
// Each channel is one plane of W x H bytes (packed rows for 1/4-bit indices),
// the "uncompressed size" field is unreliable (v3 even counts a DIB header).

interface

uses
  SysUtils, Classes, Math, XelInflate, XelJpeg;

type
  EPspError = class(Exception);

var
  // True: show the pre-flattened composite stored by PSP when present (it
  // includes vector / adjustment layers). False: always composite the raster
  // layers ourselves.
  PspUseComposite: Boolean = True;

// Decodes a Paint Shop Pro image to RGBA8 (straight alpha).
function DecodePsp(InBuf: TBytes; out Width, Height: Integer): TBytes;

implementation

const
  SIG = 'Paint Shop Pro Image File';

  BLK_IMAGE = 0; BLK_COLOR = 2; BLK_LAYER_BANK = 3; BLK_LAYER = 4;
  BLK_CHANNEL = 5; BLK_COMPOSITE_IMAGE = 9; BLK_EXTENDED = 10;
  BLK_COMPOSITE_BANK = 16; BLK_COMPOSITE_ATTR = 17; BLK_JPEG = 18;

  // bitmap types carried by a channel
  BMP_IMAGE = 0; BMP_TRANS_MASK = 1; BMP_USER_MASK = 2;
  BMP_COMPOSITE = 8; BMP_COMPOSITE_TRANS = 9;

  COMP_NONE = 0; COMP_RLE = 1; COMP_ZLIB = 2; COMP_JPEG = 3;

type
  TPspRect = record L, T, R, B: Integer; end;

  // One bitmap made of planes, as found in a layer or composite image.
  TPlanes = record
    Red, Green, Blue, Index, Trans, UserMask: TBytes;
    HaveRGB: Boolean;
  end;

  TLayer = record
    Kind: Integer;
    Rect, Saved, MaskRect, MaskSaved: TPspRect;
    Opacity, Blend: Integer;
    Visible, MaskOn, MaskInvert: Boolean;
    Planes: TPlanes;
  end;

  TPspDoc = record
    D: TBytes;
    N: NativeInt;
    Ver: Integer;
    W, H, BitDepth, Compression: Integer;
    Grey: Boolean;
    Pal: array[0..255, 0..2] of Byte;
    PalCount: Integer;
    TransIndex: Integer;          // -1 = none
    Layers: array of TLayer;
    NonRasterLayers: Boolean;     // vector / adjustment / group / ... present
    CompRGBA: TBytes;             // full-size composite, if any
    CompHasAlpha: Boolean;
  end;

// ---------------------------- bounded reads ------------------------------

procedure Need(const Doc: TPspDoc; P, Len: NativeInt);
begin
  if (P < 0) or (Len < 0) or (P + Len > Doc.N) then
    raise EPspError.Create('PSP: truncated file');
end;

function U8(const Doc: TPspDoc; P: NativeInt): Integer;
begin
  Need(Doc, P, 1); Result := Doc.D[P];
end;

function U16(const Doc: TPspDoc; P: NativeInt): Integer;
begin
  Need(Doc, P, 2); Result := Doc.D[P] or (Doc.D[P + 1] shl 8);
end;

function U32(const Doc: TPspDoc; P: NativeInt): Cardinal;
begin
  Need(Doc, P, 4);
  Result := Cardinal(Doc.D[P]) or (Cardinal(Doc.D[P + 1]) shl 8) or
            (Cardinal(Doc.D[P + 2]) shl 16) or (Cardinal(Doc.D[P + 3]) shl 24);
end;

function I32(const Doc: TPspDoc; P: NativeInt): Integer;
begin
  Result := Integer(U32(Doc, P));
end;

function ReadRect(const Doc: TPspDoc; P: NativeInt): TPspRect;
begin
  Result.L := I32(Doc, P); Result.T := I32(Doc, P + 4);
  Result.R := I32(Doc, P + 8); Result.B := I32(Doc, P + 12);
end;

// Block header at P. Body = [Body, Body + Len), clipped to the file.
function ReadBlock(const Doc: TPspDoc; P: NativeInt; out Id: Integer;
  out Body, Len: NativeInt): Boolean;
var hdr: Integer;
begin
  Result := False;
  if Doc.Ver = 3 then hdr := 14 else hdr := 10;
  if P + hdr > Doc.N then Exit;
  if (Doc.D[P] <> Ord('~')) or (Doc.D[P + 1] <> Ord('B')) or
     (Doc.D[P + 2] <> Ord('K')) or (Doc.D[P + 3] <> 0) then Exit;
  Id := U16(Doc, P + 4);
  Len := U32(Doc, P + hdr - 4);
  Body := P + hdr;
  if Body + Len > Doc.N then Len := Doc.N - Body;
  Result := True;
end;

function IsBlock(const Doc: TPspDoc; P: NativeInt): Boolean;
begin
  Result := (P + 4 <= Doc.N) and (Doc.D[P] = Ord('~')) and (Doc.D[P + 1] = Ord('B')) and
            (Doc.D[P + 2] = Ord('K')) and (Doc.D[P + 3] = 0);
end;

// ---------------------------- decompression ------------------------------

// PSP RLE: a count byte below 128 copies that many literal bytes, a count
// of 128 + n repeats the next byte n times.
function UnRle(const Doc: TPspDoc; P, Len: NativeInt): TBytes;
var
  i, e, n, o: NativeInt;
  c: Integer;
begin
  Result := nil;
  // size the output with a first pass
  i := P; e := P + Len; n := 0;
  while i < e do
  begin
    c := Doc.D[i]; Inc(i);
    if c < 128 then begin Inc(n, c); Inc(i, c); end
    else begin Inc(n, c - 128); Inc(i); end;
  end;
  SetLength(Result, n);
  i := P; o := 0;
  while (i < e) and (o < n) do
  begin
    c := Doc.D[i]; Inc(i);
    if c < 128 then
    begin
      c := Min(c, Min(e - i, n - o));
      if c > 0 then Move(Doc.D[i], Result[o], c);
      Inc(i, c); Inc(o, c);
    end
    else
    begin
      c := Min(c - 128, n - o);
      if (i < e) and (c > 0) then FillChar(Result[o], c, Doc.D[i]);
      Inc(i); Inc(o, c);
    end;
  end;
end;

function Unpack(const Doc: TPspDoc; P, Len: NativeInt; Compression: Integer): TBytes;
begin
  Result := nil;
  Need(Doc, P, Len);
  case Compression of
    COMP_NONE:
      begin
        SetLength(Result, Len);
        if Len > 0 then Move(Doc.D[P], Result[0], Len);
      end;
    COMP_RLE: Result := UnRle(Doc, P, Len);
    COMP_ZLIB:
      if Len > 0 then
      try
        Result := InflateZlib(@Doc.D[P], NativeUInt(Len));
      except
        on E: Exception do
          raise EPspError.Create('PSP: corrupt compressed channel (' + E.Message + ')');
      end;
  else
    raise EPspError.CreateFmt('PSP: unsupported channel compression %d', [Compression]);
  end;
end;

// Reads one channel block body into the matching plane of Planes.
procedure ReadChannel(const Doc: TPspDoc; Body, Len: NativeInt; Compression: Integer;
  var Planes: TPlanes);
var
  info, clen: NativeInt;
  bmp, chan: Integer;
  data: TBytes;
begin
  if Doc.Ver = 3 then info := Body else info := Body + 4;
  clen := U32(Doc, info);
  bmp := U16(Doc, info + 8);
  chan := U16(Doc, info + 10);
  if Doc.Ver = 3 then Inc(info, 12)
  else info := Body + NativeInt(U32(Doc, Body));        // data follows the chunk
  if (info < Body) or (info + clen > Body + Len) then
    clen := Max(0, Body + Len - info);
  data := Unpack(Doc, info, clen, Compression);
  case bmp of
    BMP_IMAGE, BMP_COMPOSITE:
      case chan of
        0: Planes.Index := data;
        1: begin Planes.Red := data; Planes.HaveRGB := True; end;
        2: Planes.Green := data;
        3: Planes.Blue := data;
      end;
    BMP_TRANS_MASK, BMP_COMPOSITE_TRANS: Planes.Trans := data;
    BMP_USER_MASK: Planes.UserMask := data;
  end;
end;

// ------------------------------ planes -> RGBA ---------------------------

function PlaneByte(const Pl: TBytes; Idx: NativeInt; Def: Byte): Byte; inline;
begin
  if Idx < Length(Pl) then Result := Pl[Idx] else Result := Def;
end;

// Palette index of pixel (x, y) in a plane of W x H at BitDepth 1/4/8.
function IndexAt(const Pl: TBytes; x, y, W, H, BitDepth: Integer): Integer;
var stride, need: NativeInt; b: Integer;
begin
  need := (NativeInt(W) * BitDepth + 7) div 8;
  stride := need;
  if (H > 0) and (Length(Pl) div H > need) then stride := Length(Pl) div H;   // padded rows
  case BitDepth of
    1: begin
         b := PlaneByte(Pl, y * stride + x shr 3, 0);
         Result := (b shr (7 - (x and 7))) and 1;
       end;
    4: begin
         b := PlaneByte(Pl, y * stride + x shr 1, 0);
         if (x and 1) = 0 then Result := b shr 4 else Result := b and $F;
       end;
  else
    Result := PlaneByte(Pl, y * stride + x, 0);
  end;
end;

// Colour + alpha of pixel (x, y) of a W x H bitmap.
procedure PixelAt(const Doc: TPspDoc; const Pl: TPlanes; BitDepth, x, y, W, H: Integer;
  out r, g, b, a: Integer);
var i: NativeInt; k: Integer;
begin
  i := NativeInt(y) * W + x;
  if Pl.HaveRGB then
  begin
    r := PlaneByte(Pl.Red, i, 0); g := PlaneByte(Pl.Green, i, 0); b := PlaneByte(Pl.Blue, i, 0);
    a := 255;
  end
  else
  begin
    k := IndexAt(Pl.Index, x, y, W, H, BitDepth);
    if (Doc.PalCount > 0) and (k < Doc.PalCount) then
    begin
      r := Doc.Pal[k, 0]; g := Doc.Pal[k, 1]; b := Doc.Pal[k, 2];
    end
    else
    begin
      // greyscale without palette: stretch the index range
      if BitDepth < 8 then k := k * 255 div ((1 shl BitDepth) - 1);
      r := k; g := k; b := k;
    end;
    if k = Doc.TransIndex then a := 0 else a := 255;
  end;
  if Length(Pl.Trans) > 0 then a := a * PlaneByte(Pl.Trans, i, 255) div 255;
end;

// ------------------------------- blending --------------------------------

function Lum(r, g, b: Double): Double; inline;
begin
  Result := 0.3 * r + 0.59 * g + 0.11 * b;
end;

procedure ClipColor(var r, g, b: Double);
var l, n, x: Double;
begin
  l := Lum(r, g, b);
  n := Min(r, Min(g, b)); x := Max(r, Max(g, b));
  if (n < 0) and (l - n > 1e-12) then
  begin
    r := l + (r - l) * l / (l - n); g := l + (g - l) * l / (l - n); b := l + (b - l) * l / (l - n);
  end;
  if (x > 1) and (x - l > 1e-12) then
  begin
    r := l + (r - l) * (1 - l) / (x - l); g := l + (g - l) * (1 - l) / (x - l);
    b := l + (b - l) * (1 - l) / (x - l);
  end;
end;

procedure SetLum(var r, g, b: Double; l: Double);
var d: Double;
begin
  d := l - Lum(r, g, b);
  r := r + d; g := g + d; b := b + d;
  ClipColor(r, g, b);
end;

function Sat(r, g, b: Double): Double; inline;
begin
  Result := Max(r, Max(g, b)) - Min(r, Min(g, b));
end;

procedure SetSat(var r, g, b: Double; s: Double);
var mx, mn: Double;
  function Adj(c: Double): Double;
  begin
    if mx = mn then Result := 0
    else if c = mx then Result := s
    else if c = mn then Result := 0
    else Result := (c - mn) * s / (mx - mn);
  end;
begin
  mx := Max(r, Max(g, b)); mn := Min(r, Min(g, b));
  r := Adj(r); g := Adj(g); b := Adj(b);
end;

function Separable(Mode: Integer; cb, cs: Double): Double;
begin
  case Mode of
    1:  Result := Min(cb, cs);                                   // darken
    2:  Result := Max(cb, cs);                                   // lighten
    7:  Result := cb * cs;                                       // multiply
    8:  Result := cb + cs - cb * cs;                             // screen
    10: if cb <= 0.5 then Result := 2 * cb * cs                  // overlay
        else Result := 1 - 2 * (1 - cb) * (1 - cs);
    11: if cs <= 0.5 then Result := 2 * cb * cs                  // hard light
        else Result := 1 - 2 * (1 - cb) * (1 - cs);
    12: if cs <= 0.5 then                                        // soft light
          Result := cb - (1 - 2 * cs) * cb * (1 - cb)
        else if cb <= 0.25 then
          Result := cb + (2 * cs - 1) * (((16 * cb - 12) * cb + 4) * cb - cb)
        else
          Result := cb + (2 * cs - 1) * (Sqrt(cb) - cb);
    13: Result := Abs(cb - cs);                                  // difference
    14: if cb <= 0 then Result := 0                              // dodge
        else if cs >= 1 then Result := 1
        else Result := Min(1, cb / (1 - cs));
    15: if cb >= 1 then Result := 1                              // burn
        else if cs <= 0 then Result := 0
        else Result := 1 - Min(1, (1 - cb) / cs);
    16: Result := cb + cs - 2 * cb * cs;                         // exclusion
  else
    Result := cs;                                                // normal / dissolve / unknown
  end;
end;

// Blend mode B(backdrop, source) per channel, all values 0..1.
procedure BlendColor(Mode: Integer; br, bg, bb: Double; var sr, sg, sb: Double);
var r, g, b: Double;
begin
  case Mode of
    3: begin r := sr; g := sg; b := sb;                          // hue
         SetSat(r, g, b, Sat(br, bg, bb)); SetLum(r, g, b, Lum(br, bg, bb)); end;
    4: begin r := br; g := bg; b := bb;                          // saturation
         SetSat(r, g, b, Sat(sr, sg, sb)); SetLum(r, g, b, Lum(br, bg, bb)); end;
    5: begin r := sr; g := sg; b := sb;                          // colour
         SetLum(r, g, b, Lum(br, bg, bb)); end;
    6: begin r := br; g := bg; b := bb;                          // luminosity
         SetLum(r, g, b, Lum(sr, sg, sb)); end;
  else
    begin
      r := Separable(Mode, br, sr); g := Separable(Mode, bg, sg); b := Separable(Mode, bb, sb);
    end;
  end;
  sr := r; sg := g; sb := b;
end;

// Source-over of one layer pixel onto the canvas (straight alpha).
procedure CompositePixel(Dst: PByte; Mode, r, g, b, a: Integer);
var
  asrc, adst, ao, cr, cg, cb, dr, dg, db: Double;
begin
  if a <= 0 then Exit;
  asrc := a / 255; adst := Dst[3] / 255;
  cr := r / 255; cg := g / 255; cb := b / 255;
  dr := Dst[0] / 255; dg := Dst[1] / 255; db := Dst[2] / 255;
  if (Mode <> 0) and (adst > 0) then
  begin
    BlendColor(Mode, dr, dg, db, cr, cg, cb);
    // where the backdrop is transparent the plain source colour shows
    cr := (1 - adst) * (r / 255) + adst * cr;
    cg := (1 - adst) * (g / 255) + adst * cg;
    cb := (1 - adst) * (b / 255) + adst * cb;
  end;
  ao := asrc + adst * (1 - asrc);
  Dst[0] := Round((asrc * cr + adst * (1 - asrc) * dr) / ao * 255);
  Dst[1] := Round((asrc * cg + adst * (1 - asrc) * dg) / ao * 255);
  Dst[2] := Round((asrc * cb + adst * (1 - asrc) * db) / ao * 255);
  Dst[3] := Round(ao * 255);
end;

procedure DrawLayer(const Doc: TPspDoc; const L: TLayer; var Canvas: TBytes);
var
  sw, sh, x, y, cx, cy, mw, mh, mx, my, r, g, b, a, m: Integer;
  ox, oy: Int64;
  x0, x1, y0, y1: Integer;
begin
  sw := L.Saved.R - L.Saved.L; sh := L.Saved.B - L.Saved.T;
  if (sw <= 0) or (sh <= 0) then Exit;
  mw := L.MaskSaved.R - L.MaskSaved.L; mh := L.MaskSaved.B - L.MaskSaved.T;
  // only the part of the stored rectangle that lands on the canvas
  ox := Int64(L.Rect.L) + L.Saved.L; oy := Int64(L.Rect.T) + L.Saved.T;
  x0 := Integer(Max(Int64(0), -ox)); x1 := Integer(Min(Int64(sw), Doc.W - ox)) - 1;
  y0 := Integer(Max(Int64(0), -oy)); y1 := Integer(Min(Int64(sh), Doc.H - oy)) - 1;
  for y := y0 to y1 do
  begin
    cy := Integer(oy + y);
    for x := x0 to x1 do
    begin
      cx := Integer(ox + x);
      PixelAt(Doc, L.Planes, Doc.BitDepth, x, y, sw, sh, r, g, b, a);
      a := a * L.Opacity div 255;
      if L.MaskOn and (mw > 0) and (mh > 0) then
      begin
        // mask pixels are stored for the saved part of the mask rectangle
        mx := cx - (L.MaskRect.L + L.MaskSaved.L);
        my := cy - (L.MaskRect.T + L.MaskSaved.T);
        if (mx >= 0) and (my >= 0) and (mx < mw) and (my < mh) then
          m := PlaneByte(L.Planes.UserMask, NativeInt(my) * mw + mx, 255)
        else
          m := 255;
        if L.MaskInvert then m := 255 - m;
        a := a * m div 255;
      end;
      CompositePixel(@Canvas[(NativeInt(cy) * Doc.W + cx) * 4], L.Blend, r, g, b, a);
    end;
  end;
end;

// ------------------------------- blocks ----------------------------------

procedure ReadImageAttributes(var Doc: TPspDoc; Body: NativeInt);
var p: NativeInt;
begin
  if Doc.Ver = 3 then p := Body else p := Body + 4;
  Doc.W := I32(Doc, p);
  Doc.H := I32(Doc, p + 4);
  Doc.Compression := U16(Doc, p + 17);
  Doc.BitDepth := U16(Doc, p + 19);
  Doc.Grey := U8(Doc, p + 27) <> 0;
end;

procedure ReadPalette(var Doc: TPspDoc; Body, Len: NativeInt);
var p: NativeInt; n, i: Integer;
begin
  if Doc.Ver = 3 then p := Body else p := Body + 4;
  n := Integer(U32(Doc, p));
  if Doc.Ver = 3 then Inc(p, 4) else p := Body + NativeInt(U32(Doc, Body));
  n := Min(n, 256);
  n := Min(n, Integer((Body + Len - p) div 4));
  for i := 0 to n - 1 do
  begin
    Doc.Pal[i, 0] := Doc.D[p + i * 4 + 2];      // stored B, G, R, reserved
    Doc.Pal[i, 1] := Doc.D[p + i * 4 + 1];
    Doc.Pal[i, 2] := Doc.D[p + i * 4 + 0];
  end;
  Doc.PalCount := Max(n, 0);
end;

// Extended data: a list of "~FL"#0 fields (WORD type, DWORD length, data).
procedure ReadExtended(var Doc: TPspDoc; Body, Len: NativeInt);
var p, e: NativeInt; typ: Integer; flen: NativeInt;
begin
  p := Body; e := Body + Len;
  while p + 10 <= e do
  begin
    if (Doc.D[p] = Ord('~')) and (Doc.D[p + 1] = Ord('F')) and (Doc.D[p + 2] = Ord('L')) then
    begin
      typ := U16(Doc, p + 4);
      flen := U32(Doc, p + 6);
      if (typ = 0) and (flen >= 2) then Doc.TransIndex := U16(Doc, p + 10);
      p := p + 10 + flen;
    end
    else
      Inc(p);
  end;
end;

procedure ReadLayer(var Doc: TPspDoc; Body, Len: NativeInt);
var
  L: TLayer;
  p, e, sub, slen, fields: NativeInt;
  id, flags, n: Integer;
begin
  L := Default(TLayer);
  e := Body + Len;
  if Doc.Ver = 3 then fields := Body + 256
  else fields := Body + 6 + U16(Doc, Body + 4);        // chunk size, name length, name
  L.Kind := U8(Doc, fields);
  L.Rect := ReadRect(Doc, fields + 1);
  L.Saved := ReadRect(Doc, fields + 17);
  L.Opacity := U8(Doc, fields + 33);
  L.Blend := U8(Doc, fields + 34);
  flags := U8(Doc, fields + 35);                       // v3: visible flag
  L.Visible := (flags and 1) <> 0;
  L.MaskRect := ReadRect(Doc, fields + 38);
  L.MaskSaved := ReadRect(Doc, fields + 54);
  L.MaskOn := ((Doc.Ver = 3) or ((flags and 2) <> 0)) and (U8(Doc, fields + 71) = 0);
  L.MaskInvert := U8(Doc, fields + 72) <> 0;

  // v3: 0 normal, 1 floating selection. v4+: 0 undefined, 1 raster,
  // 2 floating raster selection; higher kinds are vector, adjustment,
  // group, mask, art media ... which we cannot render
  if (Doc.Ver = 3) and (L.Kind > 1) or (Doc.Ver > 3) and (L.Kind > 2) then
  begin
    Doc.NonRasterLayers := True;
    Exit;
  end;

  // channels: v3 has two WORD counts after the fixed fields; v4+ has a
  // chain of chunks and sub-blocks after the layer info chunk
  if Doc.Ver = 3 then p := fields + 119
  else p := Body + NativeInt(U32(Doc, Body));
  while p < e do
  begin
    if IsBlock(Doc, p) then
    begin
      if not ReadBlock(Doc, p, id, sub, slen) then Break;
      if id = BLK_CHANNEL then ReadChannel(Doc, sub, slen, Doc.Compression, L.Planes);
      p := sub + slen;
    end
    else
    begin
      n := Integer(U32(Doc, p));                       // an unnamed chunk (bitmap info)
      if n < 4 then Break;
      p := p + n;
    end;
  end;

  if L.Visible and ((L.Planes.HaveRGB) or (Length(L.Planes.Index) > 0)) then
  begin
    SetLength(Doc.Layers, Length(Doc.Layers) + 1);
    Doc.Layers[High(Doc.Layers)] := L;
  end;
end;

procedure ReadLayerBank(var Doc: TPspDoc; Body, Len: NativeInt);
var p, e, sub, slen: NativeInt; id, n: Integer;
begin
  p := Body; e := Body + Len;
  while p < e do
  begin
    if IsBlock(Doc, p) then
    begin
      if not ReadBlock(Doc, p, id, sub, slen) then Break;
      if id = BLK_LAYER then ReadLayer(Doc, sub, slen);
      p := sub + slen;
    end
    else
    begin
      n := Integer(U32(Doc, p));
      if n < 4 then Break;
      p := p + n;
    end;
  end;
end;

// Composite image bank: attribute blocks first, then the image blocks in the
// same order. We decode the full-size composite (type 0), if there is one.
procedure ReadCompositeBank(var Doc: TPspDoc; Body, Len: NativeInt);
type
  TAttr = record W, H, BitDepth, Compression, Kind: Integer; end;
var
  attrs: array of TAttr;
  p, e, sub, slen, q, qe, jp, jl: NativeInt;
  id, idx, n, w, h, r, g, b, a, x, y, sid: Integer;
  Pl: TPlanes;
  jpg, rgba: TBytes;
  o: NativeInt;
begin
  attrs := nil;
  p := Body + NativeInt(U32(Doc, Body)); e := Body + Len;
  idx := 0;
  while p < e do
  begin
    if not IsBlock(Doc, p) then
    begin
      n := Integer(U32(Doc, p));
      if n < 4 then Break;
      p := p + n;
      Continue;
    end;
    if not ReadBlock(Doc, p, id, sub, slen) then Break;
    case id of
      BLK_COMPOSITE_ATTR:
        begin
          SetLength(attrs, Length(attrs) + 1);
          with attrs[High(attrs)] do
          begin
            W := I32(Doc, sub + 4); H := I32(Doc, sub + 8);
            BitDepth := U16(Doc, sub + 12); Compression := U16(Doc, sub + 14);
            Kind := U16(Doc, sub + 22);
          end;
        end;
      BLK_JPEG, BLK_COMPOSITE_IMAGE:
        begin
          if (idx < Length(attrs)) and (attrs[idx].Kind = 0) and (Length(Doc.CompRGBA) = 0) and
             (attrs[idx].W = Doc.W) and (attrs[idx].H = Doc.H) then
          try
            if id = BLK_JPEG then
            begin
              jp := sub + NativeInt(U32(Doc, sub));
              jl := U32(Doc, sub + 4);
              if jp + jl > sub + slen then jl := sub + slen - jp;
              Need(Doc, jp, jl);
              SetLength(jpg, jl);
              Move(Doc.D[jp], jpg[0], jl);
              rgba := DecodeJpeg(jpg, w, h);
              if (w = Doc.W) and (h = Doc.H) then Doc.CompRGBA := rgba;
            end
            else
            begin
              Pl := Default(TPlanes);
              q := sub + NativeInt(U32(Doc, sub)); qe := sub + slen;
              while q < qe do
              begin
                if not IsBlock(Doc, q) then Break;
                if not ReadBlock(Doc, q, sid, jp, jl) then Break;
                if sid = BLK_CHANNEL then ReadChannel(Doc, jp, jl, attrs[idx].Compression, Pl)
                else if sid = BLK_COLOR then ReadPalette(Doc, jp, jl);
                q := jp + jl;
              end;
              if Pl.HaveRGB or (Length(Pl.Index) > 0) then
              begin
                SetLength(rgba, NativeInt(Doc.W) * Doc.H * 4);
                for y := 0 to Doc.H - 1 do
                  for x := 0 to Doc.W - 1 do
                  begin
                    PixelAt(Doc, Pl, attrs[idx].BitDepth, x, y, Doc.W, Doc.H, r, g, b, a);
                    o := (NativeInt(y) * Doc.W + x) * 4;
                    rgba[o] := r; rgba[o + 1] := g; rgba[o + 2] := b; rgba[o + 3] := a;
                  end;
                Doc.CompRGBA := rgba;
                Doc.CompHasAlpha := Length(Pl.Trans) > 0;
              end;
            end;
          except
            on E: EPspError do raise;
            on E: Exception do Doc.CompRGBA := nil;   // broken composite: use the layers
          end;
          Inc(idx);
        end;
    end;
    p := sub + slen;
  end;
end;

// ------------------------------- driver ----------------------------------

function DecodePsp(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Doc: TPspDoc;
  p, body, len: NativeInt;
  id, i: Integer;
  Canvas: TBytes;
  alphaFromLayers: Boolean;
begin
  Width := 0; Height := 0; Result := nil;
  Doc := Default(TPspDoc);
  Doc.D := InBuf; Doc.N := Length(InBuf);
  Doc.TransIndex := -1;
  if (Doc.N < 40) or not CompareMem(@InBuf[0], PAnsiChar(AnsiString(SIG)), Length(SIG)) then
    raise EPspError.Create('PSP: not a Paint Shop Pro image');
  Doc.Ver := U16(Doc, 32);
  if Doc.Ver < 3 then
    raise EPspError.CreateFmt('PSP: file version %d is not supported', [Doc.Ver]);

  p := 36;
  if not ReadBlock(Doc, p, id, body, len) or (id <> BLK_IMAGE) then
    raise EPspError.Create('PSP: missing image attributes block');
  ReadImageAttributes(Doc, body);
  if (Doc.W <= 0) or (Doc.H <= 0) or (Int64(Doc.W) * Doc.H > 1 shl 28) then
    raise EPspError.CreateFmt('PSP: invalid image size %dx%d', [Doc.W, Doc.H]);
  if not (Doc.BitDepth in [1, 4, 8, 24]) then
    raise EPspError.CreateFmt('PSP: unsupported bit depth %d', [Doc.BitDepth]);
  p := body + len;

  // palette and extended data may appear anywhere: read the whole block list
  // first, then decode what we found
  while ReadBlock(Doc, p, id, body, len) do
  begin
    case id of
      BLK_COLOR: ReadPalette(Doc, body, len);
      BLK_EXTENDED: ReadExtended(Doc, body, len);
      BLK_LAYER_BANK: ReadLayerBank(Doc, body, len);
    end;
    p := body + len;
  end;
  p := 36;
  while ReadBlock(Doc, p, id, body, len) do
  begin
    if (id = BLK_COMPOSITE_BANK) and (Doc.Ver > 3) and PspUseComposite then
      ReadCompositeBank(Doc, body, len);
    p := body + len;
  end;

  // flatten the raster layers: they give the image when there is no
  // composite, and the transparency when the composite has none
  alphaFromLayers := (Length(Doc.Layers) > 0) and not Doc.NonRasterLayers;
  if (Length(Doc.CompRGBA) = 0) or (alphaFromLayers and not Doc.CompHasAlpha) then
  begin
    SetLength(Canvas, NativeInt(Doc.W) * Doc.H * 4);    // fully transparent
    for i := 0 to High(Doc.Layers) do DrawLayer(Doc, Doc.Layers[i], Canvas);
  end;

  if Length(Doc.CompRGBA) > 0 then
  begin
    Result := Doc.CompRGBA;
    if not Doc.CompHasAlpha then
      for i := 0 to Doc.W * Doc.H - 1 do
        if alphaFromLayers then Result[i * 4 + 3] := Canvas[i * 4 + 3]
        else Result[i * 4 + 3] := 255;
  end
  else if Length(Doc.Layers) > 0 then
    Result := Canvas
  else
    raise EPspError.Create('PSP: no raster layer or composite image to show');

  Width := Doc.W; Height := Doc.H;
end;

end.
