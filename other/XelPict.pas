unit XelPict;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Apple Macintosh PICT (QuickDraw picture) decoder -> RGBA8     //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Clean-room QuickDraw opcode interpreter (PICT v1 and v2, optional 512-byte  //
// file header). Supported: BitsRect/Rgn, PackBitsRect/Rgn (1/2/4/8 bit with   //
// colour table, 1-bit BitMaps), DirectBitsRect/Rgn (16 and 32 bit, pack types //
// 1-4), QuickTime-compressed images (JPEG, PNG), regions, and vector shapes:  //
// lines with pen size, rect, round rect, oval, arc, polygon, region with the  //
// frame / paint / erase / invert / fill verbs and RGB or classic colours.     //
// Text is not rendered (no fonts). The picture is rendered at the native      //
// resolution given by an extended v2 header, otherwise at 72 dpi.            //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelPng, XelJpeg;

type
  EPictError = class(Exception);

function DecodePict(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8

implementation

type
  TRect16 = record Top, Left, Bottom, Right: Integer; end;
  TCol = record R, G, B: Byte; end;
  TPt = record X, Y: Integer; end;
  TPts = array of TPt;

  TPictCtx = class
    D: TBytes;
    DataLen: NativeUInt;
    Pos: NativeUInt;
    Version: Integer;
    // canvas
    Canvas: TBytes;
    CW, CH: Integer;
    OrgX, OrgY: Integer;          // picture coordinate that maps to canvas (0,0)
    ScX, ScY: Double;             // picture units -> canvas pixels
    ClipL, ClipT, ClipR, ClipB: Integer;   // canvas-space clip
    // graphics state
    Fg, Bk: TCol;
    PenW, PenH, PenMode: Integer;
    PenX, PenY: Integer;          // picture coordinates
    OvW, OvH: Integer;
    // patterns: classic 8x8 bit patterns and pixel-pattern tiles (RGBA)
    PenPat, FillPat, BkPat: array[0..7] of Byte;
    PenTile, FillTile, BkTile: TBytes;
    PenTW, PenTH, FillTW, FillTH, BkTW, BkTH: Integer;
    // current paint source, chosen by VerbColor: 0 solid, 1 bit pattern, 2 tile
    SrcKind: Integer;
    SrcPat: array[0..7] of Byte;
    SrcTile: TBytes;
    SrcTW, SrcTH: Integer;
    LastRect, LastRRect, LastOval, LastArc: TRect16;
    LastArcStart, LastArcSweep: Integer;
    LastPoly: TPts;
    LastRgnMask: TBytes; LastRgnBox: TRect16;
    constructor Create(const Data: TBytes);
    function U8: Byte;
    function U16: Word;
    function S16: SmallInt;
    function U32: Cardinal;
    function Rect: TRect16;
    procedure Need(Count: NativeUInt);
    function MX(X: Integer): Integer;
    function MY(Y: Integer): Integer;
    procedure Plot(X, Y: Integer; const C: TCol);
    procedure InvertPx(X, Y: Integer);
    procedure Span(Y, X1, X2: Integer; const C: TCol; Invert: Boolean);
    procedure FillBox(L, T, R, B: Integer; const C: TCol; Invert: Boolean);
    procedure FillPoly(const P: TPts; const C: TCol; Invert: Boolean);
    procedure FillMask(const M: TBytes; const Box: TRect16; const C: TCol; Invert: Boolean);
    procedure Line(X1, Y1, X2, Y2: Integer);
    procedure ShapeRect(Verb: Integer; const R: TRect16);
    procedure ShapeRRect(Verb: Integer; const R: TRect16);
    procedure ShapeOval(Verb: Integer; const R: TRect16);
    procedure ShapeArc(Verb: Integer; const R: TRect16; StartA, Sweep: Integer);
    procedure ShapePoly(Verb: Integer; const P: TPts);
    procedure ShapeRgn(Verb: Integer; const M: TBytes; const Box: TRect16);
    procedure VerbFill(Verb: Integer; const P: TPts; const Frame: TPts);
    function VerbColor(Verb: Integer; out Invert: Boolean): TCol;
    procedure SelectPat(const Pat: array of Byte; const Tile: TBytes; TW, TH: Integer; out Solid: TCol);
    procedure ReadRegion(out Mask: TBytes; out Box: TRect16);
    function ReadPoly: TPts;
    procedure ReadPixPat(Target: Integer);
    procedure DoBits(Op: Integer);
    procedure DoQuickTime(Len: NativeUInt);
    procedure DrawImage(const Img: TBytes; IW, IH: Integer; const Src, Dst: TRect16;
      const Mask: TBytes; const MaskBox: TRect16; HasMask: Boolean);
    procedure Run;
  end;

const
  VERB_FRAME = 0; VERB_PAINT = 1; VERB_ERASE = 2; VERB_INVERT = 3; VERB_FILL = 4;

// -------------------------------------------------------------------------

constructor TPictCtx.Create(const Data: TBytes);
begin
  inherited Create;
  D := Data;
  DataLen := NativeUInt(Length(D));
  Fg.R := 0; Fg.G := 0; Fg.B := 0;
  Bk.R := 255; Bk.G := 255; Bk.B := 255;
  PenW := 1; PenH := 1; PenMode := 8;
  OvW := 0; OvH := 0;
  ScX := 1; ScY := 1;
  FillChar(PenPat, 8, $FF);                     // black
  FillChar(FillPat, 8, $FF);
  FillChar(BkPat, 8, 0);                        // white
end;

procedure TPictCtx.Need(Count: NativeUInt);
begin
  if (Pos > DataLen) or (Count > DataLen - Pos) then raise EPictError.Create('PICT: unexpected end of data');
end;

function TPictCtx.U8: Byte;
begin
  Need(1); Result := D[Pos]; Inc(Pos);
end;

function TPictCtx.U16: Word;
begin
  Need(2); Result := (Word(D[Pos]) shl 8) or D[Pos + 1]; Inc(Pos, 2);
end;

function TPictCtx.S16: SmallInt;
begin
  Result := SmallInt(U16);
end;

function TPictCtx.U32: Cardinal;
begin
  Need(4);
  Result := (Cardinal(D[Pos]) shl 24) or (Cardinal(D[Pos + 1]) shl 16) or
            (Cardinal(D[Pos + 2]) shl 8) or D[Pos + 3];
  Inc(Pos, 4);
end;

function TPictCtx.Rect: TRect16;
begin
  Result.Top := S16; Result.Left := S16; Result.Bottom := S16; Result.Right := S16;
end;

function TPictCtx.MX(X: Integer): Integer;
begin
  Result := Round((X - OrgX) * ScX);
end;

function TPictCtx.MY(Y: Integer): Integer;
begin
  Result := Round((Y - OrgY) * ScY);
end;

procedure TPictCtx.Plot(X, Y: Integer; const C: TCol);
var
  p, q: NativeInt;
  px, py: Integer;
begin
  if (X < ClipL) or (Y < ClipT) or (X >= ClipR) or (Y >= ClipB) then Exit;
  p := (NativeInt(Y) * CW + X) * 4;
  case SrcKind of
    1:
      begin
        // patterns are aligned to the picture coordinate origin
        px := (X + OrgX) and 7; py := (Y + OrgY) and 7;
        if ((SrcPat[py] shr (7 - px)) and 1) <> 0 then
        begin Canvas[p] := Fg.R; Canvas[p + 1] := Fg.G; Canvas[p + 2] := Fg.B; end
        else
        begin Canvas[p] := Bk.R; Canvas[p + 1] := Bk.G; Canvas[p + 2] := Bk.B; end;
      end;
    2:
      begin
        px := ((X + OrgX) mod SrcTW + SrcTW) mod SrcTW;
        py := ((Y + OrgY) mod SrcTH + SrcTH) mod SrcTH;
        q := (NativeInt(py) * SrcTW + px) * 4;
        Canvas[p] := SrcTile[q]; Canvas[p + 1] := SrcTile[q + 1]; Canvas[p + 2] := SrcTile[q + 2];
      end;
  else
    begin Canvas[p] := C.R; Canvas[p + 1] := C.G; Canvas[p + 2] := C.B; end;
  end;
  Canvas[p + 3] := 255;
end;

procedure TPictCtx.InvertPx(X, Y: Integer);
var p: NativeInt;
begin
  if (X < ClipL) or (Y < ClipT) or (X >= ClipR) or (Y >= ClipB) then Exit;
  p := (NativeInt(Y) * CW + X) * 4;
  Canvas[p] := 255 - Canvas[p]; Canvas[p + 1] := 255 - Canvas[p + 1]; Canvas[p + 2] := 255 - Canvas[p + 2];
end;

procedure TPictCtx.Span(Y, X1, X2: Integer; const C: TCol; Invert: Boolean);
var x: Integer;
begin
  if (Y < ClipT) or (Y >= ClipB) then Exit;
  if X1 < ClipL then X1 := ClipL;
  if X2 > ClipR then X2 := ClipR;
  for x := X1 to X2 - 1 do
    if Invert then InvertPx(x, Y) else Plot(x, Y, C);
end;

procedure TPictCtx.FillBox(L, T, R, B: Integer; const C: TCol; Invert: Boolean);
var y: Integer;
begin
  for y := T to B - 1 do Span(y, L, R, C, Invert);
end;

// even-odd scanline polygon fill; vertices in canvas space
procedure TPictCtx.FillPoly(const P: TPts; const C: TCol; Invert: Boolean);
var
  cnt, i, j, y, ymin, ymax, hits, k, t: Integer;
  xs: array of Integer;
  x1, y1, x2, y2: Integer;
  fy: Double;
begin
  cnt := Length(P);
  if cnt < 3 then Exit;
  ymin := P[0].Y; ymax := P[0].Y;
  for i := 1 to cnt - 1 do
  begin
    if P[i].Y < ymin then ymin := P[i].Y;
    if P[i].Y > ymax then ymax := P[i].Y;
  end;
  if ymin < ClipT then ymin := ClipT;
  if ymax > ClipB then ymax := ClipB;
  SetLength(xs, cnt);
  for y := ymin to ymax - 1 do
  begin
    fy := y + 0.5;
    hits := 0;
    for i := 0 to cnt - 1 do
    begin
      j := (i + 1) mod cnt;
      x1 := P[i].X; y1 := P[i].Y; x2 := P[j].X; y2 := P[j].Y;
      if ((y1 <= fy) and (y2 > fy)) or ((y2 <= fy) and (y1 > fy)) then
      begin
        xs[hits] := Round(x1 + (fy - y1) * (x2 - x1) / (y2 - y1));
        Inc(hits);
      end;
    end;
    for i := 1 to hits - 1 do          // insertion sort
    begin
      t := xs[i]; k := i - 1;
      while (k >= 0) and (xs[k] > t) do begin xs[k + 1] := xs[k]; Dec(k); end;
      xs[k + 1] := t;
    end;
    i := 0;
    while i + 1 < hits do
    begin
      Span(y, xs[i], xs[i + 1], C, Invert);
      Inc(i, 2);
    end;
  end;
end;

// Mask is a region bitmap in picture coordinates over Box (1 byte per pixel).
procedure TPictCtx.FillMask(const M: TBytes; const Box: TRect16; const C: TCol; Invert: Boolean);
var
  bw, cx0, cx1, cy0, cy1, cy, cx, px, py: Integer;
begin
  bw := Box.Right - Box.Left;
  if (bw <= 0) or (Length(M) = 0) then Exit;
  cy0 := MY(Box.Top); cy1 := MY(Box.Bottom);
  cx0 := MX(Box.Left); cx1 := MX(Box.Right);
  for cy := cy0 to cy1 - 1 do
  begin
    py := Box.Top + Trunc((cy - cy0 + 0.5) / ScY);
    if (py < Box.Top) or (py >= Box.Bottom) then Continue;
    for cx := cx0 to cx1 - 1 do
    begin
      px := Box.Left + Trunc((cx - cx0 + 0.5) / ScX);
      if (px < Box.Left) or (px >= Box.Right) then Continue;
      if M[(py - Box.Top) * bw + (px - Box.Left)] <> 0 then
        if Invert then InvertPx(cx, cy) else Plot(cx, cy, C);
    end;
  end;
end;

// Picks the paint source for a pattern: a pixel-pattern tile, a solid colour
// (all-ones = foreground, all-zeros = background) or a two-colour bit pattern.
procedure TPictCtx.SelectPat(const Pat: array of Byte; const Tile: TBytes; TW, TH: Integer; out Solid: TCol);
var
  i, ones, zeros: Integer;
begin
  Solid := Fg;
  if (Length(Tile) > 0) and (TW > 0) and (TH > 0) then
  begin
    SrcKind := 2; SrcTile := Tile; SrcTW := TW; SrcTH := TH;
    Exit;
  end;
  ones := 0; zeros := 0;
  for i := 0 to 7 do
  begin
    if Pat[i] = $FF then Inc(ones);
    if Pat[i] = 0 then Inc(zeros);
  end;
  if ones = 8 then begin SrcKind := 0; Solid := Fg; end
  else if zeros = 8 then begin SrcKind := 0; Solid := Bk; end
  else
  begin
    SrcKind := 1;
    for i := 0 to 7 do SrcPat[i] := Pat[i];
  end;
end;

function TPictCtx.VerbColor(Verb: Integer; out Invert: Boolean): TCol;
begin
  Invert := Verb = VERB_INVERT;
  SrcKind := 0;
  Result := Fg;
  case Verb of
    VERB_ERASE: SelectPat(BkPat, BkTile, BkTW, BkTH, Result);
    VERB_FILL: SelectPat(FillPat, FillTile, FillTW, FillTH, Result);
    VERB_INVERT: ;
  else
    SelectPat(PenPat, PenTile, PenTW, PenTH, Result);
  end;
  // pen transfer modes: patXor inverts, patBic paints the background colour
  if (Verb = VERB_PAINT) or (Verb = VERB_FRAME) then
    case PenMode and 7 of
      2: begin Invert := True; SrcKind := 0; end;
      3: begin Result := Bk; SrcKind := 0; end;
    end;
end;

// Line with a rectangular pen that hangs below-right of the pen point.
procedure TPictCtx.Line(X1, Y1, X2, Y2: Integer);
var
  ax, ay, bx, by, dx, dy, sx, sy, err, e2, pw, ph: Integer;
  c: TCol;
  inv: Boolean;
begin
  if (PenW <= 0) or (PenH <= 0) then Exit;
  c := VerbColor(VERB_FRAME, inv);
  pw := Round(PenW * ScX); if pw < 1 then pw := 1;
  ph := Round(PenH * ScY); if ph < 1 then ph := 1;
  ax := MX(X1); ay := MY(Y1); bx := MX(X2); by := MY(Y2);
  dx := Abs(bx - ax); dy := -Abs(by - ay);
  if ax < bx then sx := 1 else sx := -1;
  if ay < by then sy := 1 else sy := -1;
  err := dx + dy;
  while True do
  begin
    FillBox(ax, ay, ax + pw, ay + ph, c, inv);
    if (ax = bx) and (ay = by) then Break;
    e2 := 2 * err;
    if e2 >= dy then begin Inc(err, dy); Inc(ax, sx); end;
    if e2 <= dx then begin Inc(err, dx); Inc(ay, sy); end;
  end;
end;

procedure TPictCtx.VerbFill(Verb: Integer; const P: TPts; const Frame: TPts);
var
  c: TCol;
  inv: Boolean;
begin
  c := VerbColor(Verb, inv);
  if Verb = VERB_FRAME then FillPoly(Frame, c, inv) else FillPoly(P, c, inv);
end;

procedure TPictCtx.ShapeRect(Verb: Integer; const R: TRect16);
var
  c: TCol; inv: Boolean;
  l, t, rr, b, pw, ph: Integer;
begin
  c := VerbColor(Verb, inv);
  l := MX(R.Left); t := MY(R.Top); rr := MX(R.Right); b := MY(R.Bottom);
  if Verb = VERB_FRAME then
  begin
    if (PenW <= 0) or (PenH <= 0) then Exit;
    pw := Round(PenW * ScX); if pw < 1 then pw := 1;
    ph := Round(PenH * ScY); if ph < 1 then ph := 1;
    FillBox(l, t, rr, t + ph, c, inv);
    FillBox(l, b - ph, rr, b, c, inv);
    FillBox(l, t + ph, l + pw, b - ph, c, inv);
    FillBox(rr - pw, t + ph, rr, b - ph, c, inv);
  end
  else
    FillBox(l, t, rr, b, c, inv);
end;

// polygon approximating an ellipse arc inscribed in (L,T,R,B), canvas space.
// Angles in QuickDraw degrees: 0 = 12 o'clock, clockwise.
function ArcPts(L, T, R, B: Double; StartA, Sweep: Double; Wedge: Boolean): TPts;
var
  cx, cy, rx, ry, a: Double;
  cnt, i, k: Integer;
begin
  cx := (L + R) / 2; cy := (T + B) / 2; rx := (R - L) / 2; ry := (B - T) / 2;
  cnt := Round(Abs(Sweep) / 4) + 2;
  if cnt > 200 then cnt := 200;
  k := 0;
  if Wedge then SetLength(Result, cnt + 1) else SetLength(Result, cnt);
  if Wedge then begin Result[0].X := Round(cx); Result[0].Y := Round(cy); k := 1; end;
  for i := 0 to cnt - 1 do
  begin
    a := (StartA + Sweep * i / (cnt - 1)) * Pi / 180;
    Result[k + i].X := Round(cx + rx * Sin(a));
    Result[k + i].Y := Round(cy - ry * Cos(a));
  end;
end;

// ring polygon (outer outline then inner outline reversed) for framed shapes
function RingPts(const Outer, Inner: TPts): TPts;
var i, cnt: Integer;
begin
  cnt := Length(Outer);
  SetLength(Result, cnt + Length(Inner));
  for i := 0 to cnt - 1 do Result[i] := Outer[i];
  for i := 0 to High(Inner) do Result[cnt + i] := Inner[High(Inner) - i];
end;

procedure TPictCtx.ShapeOval(Verb: Integer; const R: TRect16);
var
  l, t, rr, b, pw, ph: Double;
  outer, inner: TPts;
begin
  l := MX(R.Left); t := MY(R.Top); rr := MX(R.Right); b := MY(R.Bottom);
  outer := ArcPts(l, t, rr, b, 0, 360, False);
  if Verb = VERB_FRAME then
  begin
    if (PenW <= 0) or (PenH <= 0) then Exit;
    pw := PenW * ScX; ph := PenH * ScY;
    inner := ArcPts(l + pw, t + ph, rr - pw, b - ph, 0, 360, False);
    VerbFill(Verb, outer, RingPts(outer, inner));
  end
  else
    VerbFill(Verb, outer, outer);
end;

procedure TPictCtx.ShapeArc(Verb: Integer; const R: TRect16; StartA, Sweep: Integer);
var
  l, t, rr, b, pw, ph: Double;
  outer, inner: TPts;
begin
  l := MX(R.Left); t := MY(R.Top); rr := MX(R.Right); b := MY(R.Bottom);
  if Verb = VERB_FRAME then
  begin
    if (PenW <= 0) or (PenH <= 0) then Exit;
    pw := PenW * ScX; ph := PenH * ScY;
    outer := ArcPts(l, t, rr, b, StartA, Sweep, False);
    inner := ArcPts(l + pw, t + ph, rr - pw, b - ph, StartA, Sweep, False);
    VerbFill(Verb, nil, RingPts(outer, inner));
  end
  else
  begin
    outer := ArcPts(l, t, rr, b, StartA, Sweep, True);
    VerbFill(Verb, outer, outer);
  end;
end;

function RoundRectPts(L, T, Rt, B, Rx, Ry: Double): TPts;
var q, k, i: Integer; cx, cy, a: Double;
begin
  SetLength(Result, 4 * 10);
  k := 0;
  for q := 0 to 3 do
    for i := 0 to 9 do
    begin
      a := (q * 90 + i * 10) * Pi / 180;
      case q of
        0: begin cx := Rt - Rx; cy := T + Ry; end;   // top-right
        1: begin cx := Rt - Rx; cy := B - Ry; end;   // bottom-right
        2: begin cx := L + Rx; cy := B - Ry; end;    // bottom-left
      else begin cx := L + Rx; cy := T + Ry; end;    // top-left
      end;
      Result[k].X := Round(cx + Rx * Sin(a));
      Result[k].Y := Round(cy - Ry * Cos(a));
      Inc(k);
    end;
end;

procedure TPictCtx.ShapeRRect(Verb: Integer; const R: TRect16);
var
  l, t, rr, b, rx, ry, pw, ph: Double;
  outer, inner: TPts;
begin
  l := MX(R.Left); t := MY(R.Top); rr := MX(R.Right); b := MY(R.Bottom);
  rx := OvW * ScX / 2; ry := OvH * ScY / 2;
  if rx > (rr - l) / 2 then rx := (rr - l) / 2;
  if ry > (b - t) / 2 then ry := (b - t) / 2;
  outer := RoundRectPts(l, t, rr, b, rx, ry);
  if Verb = VERB_FRAME then
  begin
    if (PenW <= 0) or (PenH <= 0) then Exit;
    pw := PenW * ScX; ph := PenH * ScY;
    inner := RoundRectPts(l + pw, t + ph, rr - pw, b - ph, rx - pw, ry - ph);
    VerbFill(Verb, outer, RingPts(outer, inner));
  end
  else
    VerbFill(Verb, outer, outer);
end;

procedure TPictCtx.ShapePoly(Verb: Integer; const P: TPts);
var
  cp: TPts;
  i: Integer;
begin
  if Length(P) = 0 then Exit;
  if Verb = VERB_FRAME then
  begin
    for i := 0 to High(P) - 1 do Line(P[i].X, P[i].Y, P[i + 1].X, P[i + 1].Y);
    Exit;
  end;
  SetLength(cp, Length(P));
  for i := 0 to High(P) do begin cp[i].X := MX(P[i].X); cp[i].Y := MY(P[i].Y); end;
  VerbFill(Verb, cp, cp);
end;

procedure TPictCtx.ShapeRgn(Verb: Integer; const M: TBytes; const Box: TRect16);
var
  c: TCol; inv: Boolean;
begin
  if Verb = VERB_FRAME then
  begin
    ShapeRect(VERB_FRAME, Box);     // a framed region is approximated by its box
    Exit;
  end;
  c := VerbColor(Verb, inv);
  FillMask(M, Box, c, inv);
end;

// QuickDraw region: size, bbox, then scanline inversion records. The mask
// covers the bbox (1 = inside).
procedure TPictCtx.ReadRegion(out Mask: TBytes; out Box: TRect16);
var
  size, bw, bh, y, x1, x2, prevY, row, i: Integer;
  start: NativeUInt;
  cur: TBytes;
begin
  start := Pos;
  size := U16;
  Box := Rect;
  bw := Box.Right - Box.Left; bh := Box.Bottom - Box.Top;
  if (bw <= 0) or (bh <= 0) or (bw > 32767) or (bh > 32767) then
  begin
    Mask := nil; Pos := start + NativeUInt(size); Exit;
  end;
  SetLength(Mask, bw * bh);
  if size <= 10 then
  begin
    FillChar(Mask[0], Length(Mask), 1);      // rectangular region
    Pos := start + NativeUInt(size);
    Exit;
  end;
  FillChar(Mask[0], Length(Mask), 0);
  SetLength(cur, bw);
  FillChar(cur[0], bw, 0);
  prevY := Box.Top;
  while Pos + 2 <= start + NativeUInt(size) do
  begin
    y := S16;
    if y = $7FFF then Break;
    for row := prevY to y - 1 do
      if (row >= Box.Top) and (row < Box.Bottom) then
        Move(cur[0], Mask[(row - Box.Top) * bw], bw);
    while True do
    begin
      x1 := S16;
      if x1 = $7FFF then Break;
      x2 := S16;
      if x2 = $7FFF then Break;
      for i := x1 to x2 - 1 do
        if (i >= Box.Left) and (i < Box.Right) then cur[i - Box.Left] := cur[i - Box.Left] xor 1;
    end;
    prevY := y;
  end;
  for row := prevY to Box.Bottom - 1 do
    if row >= Box.Top then Move(cur[0], Mask[(row - Box.Top) * bw], bw);
  Pos := start + NativeUInt(size);
end;

function TPictCtx.ReadPoly: TPts;
var
  size, cnt, i: Integer;
  start: NativeUInt;
begin
  start := Pos;
  size := U16;
  Rect;                                        // bounding box
  cnt := (size - 10) div 4;
  if cnt < 0 then cnt := 0;
  SetLength(Result, cnt);
  for i := 0 to cnt - 1 do
  begin
    Result[i].Y := S16; Result[i].X := S16;    // QuickDraw points are (v, h)
  end;
  Pos := start + NativeUInt(size);
end;

// ------------------------------- pixel data --------------------------------

// PackBits-decode into Dst (DstLen bytes) from the next PackedLen bytes;
// UnitSize = 1 (bytes) or 2 (16-bit words).
procedure UnpackBits(const D: TBytes; var Pos: NativeUInt; PackedLen: NativeUInt;
  var Dst: TBytes; DstLen, UnitSize: Integer);
var
  endp: NativeUInt;
  o, cnt, k, u: Integer;
begin
  endp := Pos + PackedLen;
  if endp > NativeUInt(Length(D)) then endp := NativeUInt(Length(D));
  o := 0;
  while (Pos < endp) and (o < DstLen) do
  begin
    cnt := ShortInt(D[Pos]); Inc(Pos);
    if cnt >= 0 then
    begin
      for k := 0 to (cnt + 1) * UnitSize - 1 do
      begin
        if Pos >= endp then Break;
        if o < DstLen then Dst[o] := D[Pos];
        Inc(o); Inc(Pos);
      end;
    end
    else if cnt <> -128 then
    begin
      if Pos + NativeUInt(UnitSize) > endp then Break;
      for k := 0 to -cnt do
        for u := 0 to UnitSize - 1 do
        begin
          if o < DstLen then Dst[o] := D[Pos + NativeUInt(u)];
          Inc(o);
        end;
      Inc(Pos, UnitSize);
    end;
  end;
  Pos := endp;
end;

// Pixel pattern (BkPixPat / PnPixPat / FillPixPat): patType, 8-byte classic
// pattern, then for type 1 a PixMap (rowBytes, bounds, 36 bytes, no base
// address), colour table and pixel rows; type 2 is a plain RGB colour.
procedure TPictCtx.ReadPixPat(Target: Integer);
var
  patType, rb, h, w, i, pk, x, psz, ctFlags, ctSize, idx, v: Integer;
  bounds: TRect16;
  row, tile: TBytes;
  pat: array[0..7] of Byte;
  pal: array[0..255] of TCol;

  procedure SetTile(const T: TBytes; TW, TH: Integer);
  begin
    case Target of
      0: begin BkTile := T; BkTW := TW; BkTH := TH; end;
      1: begin PenTile := T; PenTW := TW; PenTH := TH; end;
    else begin FillTile := T; FillTW := TW; FillTH := TH; end;
    end;
  end;

begin
  patType := U16;
  Need(8);
  for i := 0 to 7 do pat[i] := D[Pos + NativeUInt(i)];
  Inc(Pos, 8);
  // the classic pattern is the fallback; a colour pattern replaces it
  case Target of
    0: Move(pat, BkPat, 8);
    1: Move(pat, PenPat, 8);
  else Move(pat, FillPat, 8);
  end;
  SetTile(nil, 0, 0);
  if patType = 2 then
  begin
    SetLength(tile, 4);
    tile[0] := U16 shr 8; tile[1] := U16 shr 8; tile[2] := U16 shr 8; tile[3] := 255;
    SetTile(tile, 1, 1);
    Exit;
  end;
  if patType <> 1 then Exit;

  rb := U16 and $3FFF;
  bounds := Rect;
  Need(36);
  psz := (Word(D[Pos + 18]) shl 8) or D[Pos + 19];
  Inc(Pos, 36);
  U32; ctFlags := U16; ctSize := U16;
  for i := 0 to 255 do begin pal[i].R := 0; pal[i].G := 0; pal[i].B := 0; end;
  for i := 0 to ctSize do
  begin
    v := U16;
    if (ctFlags and $8000) <> 0 then idx := i and $FF else idx := v and $FF;
    pal[idx].R := U16 shr 8; pal[idx].G := U16 shr 8; pal[idx].B := U16 shr 8;
  end;
  h := bounds.Bottom - bounds.Top;
  w := bounds.Right - bounds.Left;
  if (h <= 0) or (w <= 0) or (h > 4096) or (w > 4096) then raise EPictError.Create('PICT: invalid pixel pattern');
  SetLength(row, rb + 16);
  SetLength(tile, w * h * 4);
  for i := 0 to h - 1 do
  begin
    FillChar(row[0], Length(row), 0);
    if rb < 8 then
    begin
      Need(rb); Move(D[Pos], row[0], rb); Inc(Pos, rb);
    end
    else
    begin
      if rb > 250 then pk := U16 else pk := U8;
      UnpackBits(D, Pos, pk, row, rb, 1);
    end;
    for x := 0 to w - 1 do
    begin
      case psz of
        1: idx := (row[x shr 3] shr (7 - (x and 7))) and 1;
        2: idx := (row[x shr 2] shr (6 - 2 * (x and 3))) and 3;
        4: idx := (row[x shr 1] shr (4 - 4 * (x and 1))) and 15;
      else idx := row[x];
      end;
      tile[(i * w + x) * 4] := pal[idx].R; tile[(i * w + x) * 4 + 1] := pal[idx].G;
      tile[(i * w + x) * 4 + 2] := pal[idx].B; tile[(i * w + x) * 4 + 3] := 255;
    end;
  end;
  SetTile(tile, w, h);
end;

// Draw an RGBA image: source rectangle Src (in image pixels) scaled onto the
// destination Dst (picture coordinates), optionally masked by a region.
procedure TPictCtx.DrawImage(const Img: TBytes; IW, IH: Integer; const Src, Dst: TRect16;
  const Mask: TBytes; const MaskBox: TRect16; HasMask: Boolean);
var
  dl, dt, dr, db, x, y, sx, sy, sw, sh, dw, dh, p, q, px, py, mbw: Integer;
begin
  dl := MX(Dst.Left); dt := MY(Dst.Top); dr := MX(Dst.Right); db := MY(Dst.Bottom);
  sw := Src.Right - Src.Left; sh := Src.Bottom - Src.Top;
  dw := dr - dl; dh := db - dt;
  if (sw <= 0) or (sh <= 0) or (dw <= 0) or (dh <= 0) then Exit;
  mbw := MaskBox.Right - MaskBox.Left;
  for y := dt to db - 1 do
  begin
    if (y < ClipT) or (y >= ClipB) then Continue;
    sy := Src.Top + ((y - dt) * sh) div dh;
    if (sy < 0) or (sy >= IH) then Continue;
    for x := dl to dr - 1 do
    begin
      if (x < ClipL) or (x >= ClipR) then Continue;
      sx := Src.Left + ((x - dl) * sw) div dw;
      if (sx < 0) or (sx >= IW) then Continue;
      if HasMask and (Length(Mask) > 0) then
      begin
        px := OrgX + Trunc((x + 0.5) / ScX);
        py := OrgY + Trunc((y + 0.5) / ScY);
        if (px < MaskBox.Left) or (px >= MaskBox.Right) or (py < MaskBox.Top) or (py >= MaskBox.Bottom) then Continue;
        if Mask[(py - MaskBox.Top) * mbw + (px - MaskBox.Left)] = 0 then Continue;
      end;
      p := (sy * IW + sx) * 4;
      q := (y * CW + x) * 4;
      Canvas[q] := Img[p]; Canvas[q + 1] := Img[p + 1]; Canvas[q + 2] := Img[p + 2]; Canvas[q + 3] := 255;
    end;
  end;
end;

procedure TPictCtx.DoBits(Op: Integer);
var
  rbRaw, rb, pixSize, packType, cmpCount, ctFlags, ctSize, i, idx, W, H, x, y, pk, v: Integer;
  isPixMap, direct, hasRgn, isPacked, alphaUsed: Boolean;
  bounds, src, dst, rgnBox: TRect16;
  pal: array[0..255] of TCol;
  row, img, rgn: TBytes;
  unitSize, rowLen: Integer;
begin
  direct := (Op = $9A) or (Op = $9B);
  hasRgn := (Op = $91) or (Op = $99) or (Op = $9B);
  if direct then U32;                               // baseAddr
  rbRaw := U16;
  isPixMap := (rbRaw and $8000) <> 0;
  rb := rbRaw and $3FFF;
  bounds := Rect;
  pixSize := 1; packType := 0; cmpCount := 1;
  for i := 0 to 255 do begin pal[i].R := 0; pal[i].G := 0; pal[i].B := 0; end;
  if isPixMap then
  begin
    Need(36);
    packType := (Word(D[Pos + 2]) shl 8) or D[Pos + 3];
    pixSize := (Word(D[Pos + 18]) shl 8) or D[Pos + 19];
    cmpCount := (Word(D[Pos + 20]) shl 8) or D[Pos + 21];
    Inc(Pos, 36);
    if not direct then
    begin
      U32; ctFlags := U16; ctSize := U16;
      for i := 0 to ctSize do
      begin
        v := U16;
        if (ctFlags and $8000) <> 0 then idx := i and $FF else idx := v and $FF;
        pal[idx].R := U16 shr 8; pal[idx].G := U16 shr 8; pal[idx].B := U16 shr 8;
      end;
    end;
  end
  else
  begin
    pal[0].R := 255; pal[0].G := 255; pal[0].B := 255;   // BitMap: 0 = white, 1 = black
  end;
  src := Rect; dst := Rect;
  U16;                                                  // transfer mode
  rgn := nil;
  if hasRgn then ReadRegion(rgn, rgnBox);

  W := bounds.Right - bounds.Left;
  H := bounds.Bottom - bounds.Top;
  if (W <= 0) or (H <= 0) or (W > 32767) or (H > 32767) then raise EPictError.Create('PICT: invalid pixel map');
  SetLength(img, W * H * 4);

  isPacked := (Op <> $90) and (Op <> $91) and (rb >= 8);
  if direct then
  begin
    if packType = 0 then
      if pixSize = 32 then packType := 4 else packType := 3;
    if rb < 8 then packType := 1;
  end;
  unitSize := 1;
  if direct and (pixSize = 16) and (packType = 3) then unitSize := 2;

  if direct and (packType = 2) then rowLen := W * 3
  else if direct and (packType = 4) then rowLen := W * cmpCount
  else rowLen := rb;
  SetLength(row, rowLen + 16);
  alphaUsed := False;

  for y := 0 to H - 1 do
  begin
    FillChar(row[0], Length(row), 0);
    if direct and ((packType = 1) or (packType = 2)) then
    begin
      Need(rowLen); Move(D[Pos], row[0], rowLen); Inc(Pos, rowLen);
    end
    else if isPacked or (direct and (packType >= 3)) then
    begin
      if rb > 250 then pk := U16 else pk := U8;
      UnpackBits(D, Pos, pk, row, rowLen, unitSize);
    end
    else
    begin
      Need(rb); Move(D[Pos], row[0], rb); Inc(Pos, rb);
    end;

    for x := 0 to W - 1 do
    begin
      i := (y * W + x) * 4;
      img[i + 3] := 255;
      if direct then
      begin
        case pixSize of
          16:
            begin
              v := (Integer(row[x * 2]) shl 8) or row[x * 2 + 1];
              img[i]     := ((v shr 10) and 31) * 255 div 31;
              img[i + 1] := ((v shr 5) and 31) * 255 div 31;
              img[i + 2] := (v and 31) * 255 div 31;
            end;
        else // 32
          case packType of
            1: begin img[i] := row[x * 4 + 1]; img[i + 1] := row[x * 4 + 2]; img[i + 2] := row[x * 4 + 3]; end;
            2: begin img[i] := row[x * 3]; img[i + 1] := row[x * 3 + 1]; img[i + 2] := row[x * 3 + 2]; end;
          else // 4: component planes, alpha first when cmpCount = 4
            if cmpCount >= 4 then
            begin
              img[i + 3] := row[x];
              if row[x] <> 0 then alphaUsed := True;
              img[i] := row[W + x]; img[i + 1] := row[2 * W + x]; img[i + 2] := row[3 * W + x];
            end
            else
            begin
              img[i] := row[x]; img[i + 1] := row[W + x]; img[i + 2] := row[2 * W + x];
            end;
          end;
        end;
      end
      else
      begin
        case pixSize of
          1: idx := (row[x shr 3] shr (7 - (x and 7))) and 1;
          2: idx := (row[x shr 2] shr (6 - 2 * (x and 3))) and 3;
          4: idx := (row[x shr 1] shr (4 - 4 * (x and 1))) and 15;
        else idx := row[x];
        end;
        if (not isPixMap) and (idx = 1) then begin img[i] := 0; img[i + 1] := 0; img[i + 2] := 0; end
        else begin img[i] := pal[idx].R; img[i + 1] := pal[idx].G; img[i + 2] := pal[idx].B; end;
      end;
    end;
  end;

  // an all-zero alpha plane is unused: keep the image opaque
  if direct and (cmpCount >= 4) and not alphaUsed then
    for i := 0 to W * H - 1 do img[i * 4 + 3] := 255;

  src.Left := src.Left - bounds.Left; src.Right := src.Right - bounds.Left;
  src.Top := src.Top - bounds.Top; src.Bottom := src.Bottom - bounds.Top;
  DrawImage(img, W, H, src, dst, rgn, rgnBox, hasRgn);
end;

// QuickTime 'raw ' codec: uncompressed rows of 32-bit ARGB, 24-bit RGB or
// 16-bit xRGB555 (rows may be padded; the row size is derived from the data).
function DecodeQtRaw(const Src: TBytes; W, H, Depth: Integer; out IW, IH: Integer): TBytes;
var
  bpp, rowBytes, x, y, s, d, v: Integer;
begin
  Result := nil; IW := 0; IH := 0;
  case Depth of
    32: bpp := 4;
    24: bpp := 3;
    16: bpp := 2;
  else Exit;
  end;
  if (W <= 0) or (H <= 0) then Exit;
  rowBytes := Length(Src) div H;
  if rowBytes < W * bpp then Exit;
  SetLength(Result, W * H * 4);
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      s := y * rowBytes + x * bpp;
      d := (y * W + x) * 4;
      case bpp of
        4: begin Result[d] := Src[s + 1]; Result[d + 1] := Src[s + 2]; Result[d + 2] := Src[s + 3]; end;
        3: begin Result[d] := Src[s]; Result[d + 1] := Src[s + 1]; Result[d + 2] := Src[s + 2]; end;
      else
        begin
          v := (Integer(Src[s]) shl 8) or Src[s + 1];
          Result[d] := ((v shr 10) and 31) * 255 div 31;
          Result[d + 1] := ((v shr 5) and 31) * 255 div 31;
          Result[d + 2] := (v and 31) * 255 div 31;
        end;
      end;
      Result[d + 3] := 255;
    end;
  IW := W; IH := H;
end;

// QuickTime-compressed image (opcode $8200): JPEG or PNG payload.
procedure TPictCtx.DoQuickTime(Len: NativeUInt);
var
  start, idOff: NativeUInt;
  a, dd, tx, ty: Double;
  matteSize, maskSize, idSize, dataSize: Cardinal;
  src, dst: TRect16;
  ctype: AnsiString;
  payload, img: TBytes;
  IW, IH: Integer;

  function RdS32(P: NativeUInt): Integer;
  begin
    Result := Integer((Cardinal(D[P]) shl 24) or (Cardinal(D[P + 1]) shl 16) or (Cardinal(D[P + 2]) shl 8) or D[P + 3]);
  end;

begin
  start := Pos;
  if (Len < 68 + 86) or (start + Len > DataLen) then begin Pos := start + Len; Exit; end;
  // version(2), matrix 3x3 (a b u / c d v / tx ty w)
  a  := RdS32(start + 2) / 65536;
  dd := RdS32(start + 2 + 16) / 65536;
  tx := RdS32(start + 2 + 24) / 65536;
  ty := RdS32(start + 2 + 28) / 65536;
  Pos := start + 38;
  matteSize := U32;
  Rect;                                               // matte rect
  U16;                                                // mode
  src := Rect;
  U32;                                                // accuracy
  maskSize := U32;
  Pos := Pos + matteSize + maskSize;
  idOff := Pos;
  if idOff + 86 > start + Len then begin Pos := start + Len; Exit; end;
  idSize := U32;
  SetLength(ctype, 4);
  Move(D[idOff + 4], ctype[1], 4);
  dataSize := (Cardinal(D[idOff + 44]) shl 24) or (Cardinal(D[idOff + 45]) shl 16) or
              (Cardinal(D[idOff + 46]) shl 8) or D[idOff + 47];
  if (idSize < 86) or (idOff + idSize > start + Len) then begin Pos := start + Len; Exit; end;
  if (dataSize = 0) or (idOff + idSize + dataSize > start + Len) then
    dataSize := start + Len - idOff - idSize;
  payload := Copy(D, idOff + idSize, dataSize);
  img := nil; IW := 0; IH := 0;
  try
    if LowerCase(string(ctype)) = 'jpeg' then img := DecodeJpeg(payload, IW, IH)
    else if LowerCase(string(ctype)) = 'png ' then img := DecodePng(payload, IW, IH)
    else if LowerCase(string(ctype)) = 'raw ' then
      img := DecodeQtRaw(payload, (Integer(D[idOff + 32]) shl 8) or D[idOff + 33],
        (Integer(D[idOff + 34]) shl 8) or D[idOff + 35], SmallInt((Word(D[idOff + 82]) shl 8) or D[idOff + 83]), IW, IH);
  except
    img := nil;
  end;
  if (Length(img) > 0) and (IW > 0) and (IH > 0) then
  begin
    if a = 0 then a := 1;
    if dd = 0 then dd := 1;
    dst.Left := Round(src.Left * a + tx); dst.Top := Round(src.Top * dd + ty);
    dst.Right := Round(src.Right * a + tx); dst.Bottom := Round(src.Bottom * dd + ty);
    src.Right := IW; src.Bottom := IH; src.Left := 0; src.Top := 0;
    DrawImage(img, IW, IH, src, dst, nil, src, False);
  end;
  Pos := start + Len;
end;

procedure TPictCtx.Run;
var
  base, opStart: NativeUInt;
  op, verb, ln, v, k, hdrVer: Integer;
  frame, box, srcR: TRect16;
  mask: TBytes;

  function W16(P: NativeUInt): Word;
  begin
    Result := (Word(D[P]) shl 8) or D[P + 1];
  end;

  function ReadRGB: TCol;
  begin
    Result.R := U16 shr 8; Result.G := U16 shr 8; Result.B := U16 shr 8;
  end;

  function ClassicColor(V: Cardinal): TCol;
  begin
    case V of
      33:  begin Result.R := 0;   Result.G := 0;   Result.B := 0;   end;   // black
      30:  begin Result.R := 255; Result.G := 255; Result.B := 255; end;   // white
      205: begin Result.R := 221; Result.G := 8;   Result.B := 6;   end;   // red
      341: begin Result.R := 0;   Result.G := 128; Result.B := 17;  end;   // green
      409: begin Result.R := 0;   Result.G := 0;   Result.B := 212; end;   // blue
      273: begin Result.R := 2;   Result.G := 171; Result.B := 234; end;   // cyan
      137: begin Result.R := 242; Result.G := 8;   Result.B := 132; end;   // magenta
      69:  begin Result.R := 252; Result.G := 243; Result.B := 5;   end;   // yellow
    else begin Result.R := 0; Result.G := 0; Result.B := 0; end;
    end;
  end;

  procedure ReadPat(var Pat: array of Byte);
  var j: Integer;
  begin
    Need(8);
    for j := 0 to 7 do Pat[j] := D[Pos + NativeUInt(j)];
    Inc(Pos, 8);
  end;

  function IsHeader(P: NativeUInt): Boolean;
  begin
    Result := (DataLen >= P + 14) and
      ((W16(P + 10) = $1101) or ((W16(P + 10) = $0011) and (W16(P + 12) = $02FF)));
  end;

  procedure Shape(Group, Verb: Integer; Same: Boolean);
  begin
    case Group of
      $3: begin if not Same then LastRect := Rect; ShapeRect(Verb, LastRect); end;
      $4: begin if not Same then LastRRect := Rect; ShapeRRect(Verb, LastRRect); end;
      $5: begin if not Same then LastOval := Rect; ShapeOval(Verb, LastOval); end;
      $6: begin
            if not Same then LastArc := Rect;
            LastArcStart := S16; LastArcSweep := S16;
            ShapeArc(Verb, LastArc, LastArcStart, LastArcSweep);
          end;
      $7: begin if not Same then LastPoly := ReadPoly; ShapePoly(Verb, LastPoly); end;
      $8: begin if not Same then ReadRegion(LastRgnMask, LastRgnBox); ShapeRgn(Verb, LastRgnMask, LastRgnBox); end;
    end;
  end;

begin
  // locate the picture: an optional 512-byte file header precedes it, and the
  // whole file may be wrapped in a 128-byte MacBinary header
  if IsHeader(512) then base := 512
  else if IsHeader(0) then base := 0
  else if (DataLen > 128) and (D[0] = 0) and (D[1] >= 1) and (D[1] <= 63) and
          (D[74] = 0) and (D[82] = 0) and IsHeader(128 + 512) then base := 128 + 512
  else if (DataLen > 128) and (D[0] = 0) and (D[1] >= 1) and (D[1] <= 63) and
          (D[74] = 0) and (D[82] = 0) and IsHeader(128) then base := 128
  else raise EPictError.Create('PICT: no picture header found');

  Pos := base + 2;                                    // picSize (unreliable)
  frame := Rect;
  if W16(Pos) = $1101 then begin Version := 1; Inc(Pos, 2); end
  else begin Version := 2; Inc(Pos, 4); end;

  OrgX := frame.Left; OrgY := frame.Top;
  CW := frame.Right - frame.Left; CH := frame.Bottom - frame.Top;
  ScX := 1; ScY := 1;

  // an extended v2 header gives the native resolution and source rectangle
  if (Version = 2) and (Pos + 26 <= DataLen) and (W16(Pos) = $0C00) then
  begin
    opStart := Pos;
    Inc(Pos, 2);
    hdrVer := S16;
    U16;
    if hdrVer = -2 then
    begin
      U32; U32;                                       // hRes, vRes (Fixed)
      srcR := Rect;
      if (srcR.Right > srcR.Left) and (srcR.Bottom > srcR.Top) then
      begin
        OrgX := srcR.Left; OrgY := srcR.Top;
        CW := srcR.Right - srcR.Left; CH := srcR.Bottom - srcR.Top;
      end;
    end;
    Pos := opStart + 2 + 24;
  end;

  if (CW <= 0) or (CH <= 0) or (CW > 32767) or (CH > 32767) then raise EPictError.Create('PICT: invalid picture frame');
  SetLength(Canvas, NativeInt(CW) * CH * 4);
  FillChar(Canvas[0], Length(Canvas), 255);           // white paper
  ClipL := 0; ClipT := 0; ClipR := CW; ClipB := CH;
  PenX := OrgX; PenY := OrgY;

  while Pos < DataLen do
  begin
    if Version = 2 then
    begin
      if ((Pos - base) and 1) <> 0 then Inc(Pos);
      if Pos + 2 > DataLen then Break;
      op := U16;
    end
    else
      op := U8;

    case op of
      $0000: ;                                              // NOP
      $00FF: Break;                                         // OpEndPic
      $0001:
        begin                                               // Clip: use the region's box
          ReadRegion(mask, box);
          ClipL := MX(box.Left); ClipT := MY(box.Top); ClipR := MX(box.Right); ClipB := MY(box.Bottom);
          if ClipL < 0 then ClipL := 0;
          if ClipT < 0 then ClipT := 0;
          if ClipR > CW then ClipR := CW;
          if ClipB > CH then ClipB := CH;
          if (ClipR <= ClipL) or (ClipB <= ClipT) then begin ClipL := 0; ClipT := 0; ClipR := CW; ClipB := CH; end;
        end;
      $0002: begin ReadPat(BkPat); BkTile := nil; end;     // BkPat
      $0003: Inc(Pos, 2);                                   // TxFont
      $0004: Inc(Pos, 1);                                   // TxFace
      $0005: Inc(Pos, 2);                                   // TxMode
      $0006: Inc(Pos, 4);                                   // SpExtra
      $0007: begin PenH := S16; PenW := S16; end;           // PnSize (v, h)
      $0008: PenMode := U16;
      $0009: begin ReadPat(PenPat); PenTile := nil; end;   // PnPat
      $000A: begin ReadPat(FillPat); FillTile := nil; end; // FillPat
      $000B: begin OvH := S16; OvW := S16; end;             // OvSize
      $000C: begin v := S16; k := S16; Inc(OrgX, k); Inc(OrgY, v); end;   // Origin dv, dh
      $000D: Inc(Pos, 2);                                   // TxSize
      $000E: Fg := ClassicColor(U32);
      $000F: Bk := ClassicColor(U32);
      $0010: Inc(Pos, 8);                                   // TxRatio
      $0011: if Version = 1 then Inc(Pos, 1) else Inc(Pos, 2);
      $0012: ReadPixPat(0);                                 // BkPixPat
      $0013: ReadPixPat(1);                                 // PnPixPat
      $0014: ReadPixPat(2);                                 // FillPixPat
      $0015, $0016: Inc(Pos, 2);
      $0017..$0019, $001C, $001E: ;
      $001A: Fg := ReadRGB;                                 // RGBFgCol
      $001B: Bk := ReadRGB;
      $001D, $001F: Inc(Pos, 6);                            // HiliteColor, OpColor
      $0020: begin                                          // Line pnLoc newPt
               PenY := S16; PenX := S16; k := S16; v := S16;
               Line(PenX, PenY, v, k); PenX := v; PenY := k;
             end;
      $0021: begin k := S16; v := S16; Line(PenX, PenY, v, k); PenX := v; PenY := k; end;   // LineFrom
      $0022: begin                                          // ShortLine pnLoc dh dv
               PenY := S16; PenX := S16;
               v := ShortInt(U8); k := ShortInt(U8);
               Line(PenX, PenY, PenX + v, PenY + k); Inc(PenX, v); Inc(PenY, k);
             end;
      $0023: begin                                          // ShortLineFrom dh dv
               v := ShortInt(U8); k := ShortInt(U8);
               Line(PenX, PenY, PenX + v, PenY + k); Inc(PenX, v); Inc(PenY, k);
             end;
      $0024..$0027, $002C..$002F, $0092..$0097, $009C..$009F, $00A2..$00AF:
        begin ln := U16; Inc(Pos, ln); end;
      $0028: begin Inc(Pos, 4); ln := U8; Inc(Pos, ln); end;  // LongText
      $0029, $002A: begin Inc(Pos, 1); ln := U8; Inc(Pos, ln); end;   // DHText, DVText
      $002B: begin Inc(Pos, 2); ln := U8; Inc(Pos, ln); end;  // DHDVText
      $0030..$008F:
        begin
          verb := op and 7;
          if verb > 4 then verb := VERB_FRAME;                // reserved verbs
          Shape(op shr 4, verb, (op and $F) >= 8);
        end;
      $0090, $0091, $0098, $0099, $009A, $009B: DoBits(op);
      $00A0: Inc(Pos, 2);                                   // ShortComment
      $00A1: begin U16; ln := U16; Inc(Pos, ln); end;       // LongComment
      $00B0..$00CF: ;
      $00D0..$00FE: begin ln := Integer(U32); Inc(Pos, ln); end;
      $0C00: Inc(Pos, 24);
      $8200: begin ln := Integer(U32); DoQuickTime(NativeUInt(ln)); end;
      $8201: begin ln := Integer(U32); Inc(Pos, ln); end;
    else
      if (op >= $0100) and (op <= $7FFF) then Inc(Pos, (op shr 8) * 2)
      else if (op >= $8000) and (op <= $80FF) then
      else if op >= $8100 then begin ln := Integer(U32); Inc(Pos, ln); end;
    end;
  end;
end;

function DecodePict(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Ctx: TPictCtx;
begin
  Width := 0; Height := 0; Result := nil;
  Ctx := TPictCtx.Create(InBuf);
  try
    try
      Ctx.Run;
    except
      // a truncated or odd opcode stream keeps what was drawn so far
      on E: EPictError do
        if Length(Ctx.Canvas) = 0 then raise;
    end;
    Width := Ctx.CW; Height := Ctx.CH;
    Result := Ctx.Canvas;
  finally
    Ctx.Free;
  end;
end;

end.
