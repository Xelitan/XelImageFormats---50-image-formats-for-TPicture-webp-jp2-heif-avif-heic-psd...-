unit Av1.Ipred;

// AV1 intra prediction kernels (ipred_tmpl.c). All operate on a centred Integer
// edge buffer TL (= dav1d's topleft_in): TL[0] is the corner, TL[1+x] the top
// row (extended with top-right), TL[-(1+y)] the left column (extended with
// bottom-left). The caller (edge preparation) fills TL with correct availability
// before calling. Output is written as bytes to Dst. 8-bit.

{$mode delphi}{$H+}
{$RANGECHECKS OFF}{$OVERFLOWCHECKS OFF}

interface

const
  DC_PRED = 0; VERT_PRED = 1; HOR_PRED = 2; DIAG_DOWN_LEFT_PRED = 3;
  DIAG_DOWN_RIGHT_PRED = 4; VERT_RIGHT_PRED = 5; HOR_DOWN_PRED = 6;
  HOR_UP_PRED = 7; VERT_LEFT_PRED = 8; SMOOTH_PRED = 9; SMOOTH_V_PRED = 10;
  SMOOTH_H_PRED = 11; PAETH_PRED = 12;

procedure IPredV(Dst: PWord; Stride: Integer; TL: PInteger; W, H: Integer);
procedure IPredH(Dst: PWord; Stride: Integer; TL: PInteger; W, H: Integer);
procedure IPredPaeth(Dst: PWord; Stride: Integer; TL: PInteger; W, H: Integer);
procedure IPredSmooth(Dst: PWord; Stride: Integer; TL: PInteger; W, H: Integer);
procedure IPredSmoothV(Dst: PWord; Stride: Integer; TL: PInteger; W, H: Integer);
procedure IPredSmoothH(Dst: PWord; Stride: Integer; TL: PInteger; W, H: Integer);
// Angle packed: bits0-8 angle, bit9 is_sm, bit10 enable-edge-filter.
procedure IPredZ1(Dst: PWord; Stride: Integer; TL: PInteger; W, H, Angle, MaxW, MaxH: Integer);
procedure IPredZ2(Dst: PWord; Stride: Integer; TL: PInteger; W, H, Angle, MaxW, MaxH: Integer);
procedure IPredZ3(Dst: PWord; Stride: Integer; TL: PInteger; W, H, Angle, MaxW, MaxH: Integer);

var
  IPredMax: Integer = 255;   // (1 shl BitDepth)-1; set per frame by the decoder

implementation

const
{$I Av1.SmWeights.inc}
  DrIntraDerivative: array[0..43] of Word = (
    0,1023,0,547,372,0,0,273,215,0,178,151,0,132,116,0,102,0,90,80,0,71,64,0,
    57,51,0,45,0,40,35,0,31,27,0,23,19,0,15,0,11,0,7,3);
  FeKernel: array[0..2, 0..4] of Byte = ((0,4,8,4,0),(0,5,6,5,0),(2,4,4,4,2));
  UeKernel: array[0..3] of Shortint = (-1, 9, 9, -1);

function IMin(a, b: Integer): Integer; inline; begin if a < b then Result := a else Result := b; end;
function IMax(a, b: Integer): Integer; inline; begin if a > b then Result := a else Result := b; end;
function IClip(v, lo, hi: Integer): Integer; inline;
begin if v < lo then Result := lo else if v > hi then Result := hi else Result := v; end;
function ClipPx(v: Integer): Integer; inline;
begin if v < 0 then Result := 0 else if v > IPredMax then Result := IPredMax else Result := v; end;
function Sar6(v: Integer): Integer; inline; begin Result := SarLongint(v, 6); end;

procedure IPredV(Dst: PWord; Stride: Integer; TL: PInteger; W, H: Integer);
var x, y: Integer; row: PWord;
begin for y := 0 to H-1 do begin row := @Dst[y*Stride]; for x := 0 to W-1 do row[x] := Word(TL[1+x]); end; end;

procedure IPredH(Dst: PWord; Stride: Integer; TL: PInteger; W, H: Integer);
var x, y: Integer; v: Word;
begin for y := 0 to H-1 do begin v := Word(TL[-(1+y)]); for x := 0 to W-1 do Dst[y*Stride+x] := v; end; end;

procedure IPredPaeth(Dst: PWord; Stride: Integer; TL: PInteger; W, H: Integer);
var x, y, corner, left, top, base, ld, td, tld: Integer; row: PWord;
begin
  corner := TL[0];
  for y := 0 to H-1 do
  begin
    left := TL[-(1+y)]; row := @Dst[y*Stride];
    for x := 0 to W-1 do
    begin
      top := TL[1+x]; base := left + top - corner;
      ld := Abs(left-base); td := Abs(top-base); tld := Abs(corner-base);
      if (ld <= td) and (ld <= tld) then row[x] := Word(left)
      else if td <= tld then row[x] := Word(top) else row[x] := Word(corner);
    end;
  end;
end;

procedure IPredSmooth(Dst: PWord; Stride: Integer; TL: PInteger; W, H: Integer);
var x, y, right, bottom, wv, wh, pred: Integer; row: PWord;
begin
  right := TL[W]; bottom := TL[-H];
  for y := 0 to H-1 do
  begin
    row := @Dst[y*Stride]; wv := SmWeights[H+y];
    for x := 0 to W-1 do
    begin
      wh := SmWeights[W+x];
      pred := wv*TL[1+x] + (256-wv)*bottom + wh*TL[-(1+y)] + (256-wh)*right;
      row[x] := Word((pred + 256) shr 9);
    end;
  end;
end;

procedure IPredSmoothV(Dst: PWord; Stride: Integer; TL: PInteger; W, H: Integer);
var x, y, bottom, wv, pred: Integer; row: PWord;
begin
  bottom := TL[-H];
  for y := 0 to H-1 do
  begin
    row := @Dst[y*Stride]; wv := SmWeights[H+y];
    for x := 0 to W-1 do begin pred := wv*TL[1+x] + (256-wv)*bottom; row[x] := Word((pred+128) shr 8); end;
  end;
end;

procedure IPredSmoothH(Dst: PWord; Stride: Integer; TL: PInteger; W, H: Integer);
var x, y, right, wh, pred: Integer; row: PWord;
begin
  right := TL[W];
  for y := 0 to H-1 do
  begin
    row := @Dst[y*Stride];
    for x := 0 to W-1 do begin wh := SmWeights[W+x]; pred := wh*TL[-(1+y)] + (256-wh)*right; row[x] := Word((pred+128) shr 8); end;
  end;
end;

function GetUpsample(wh, angle, isSm: Integer): Integer; inline;
begin Result := Ord((angle < 40) and (wh <= (16 shr isSm))); end;

function GetFilterStrength(wh, angle, isSm: Integer): Integer;
begin
  Result := 0;
  if isSm <> 0 then
  begin
    if wh <= 8 then begin if angle >= 64 then Result := 2 else if angle >= 40 then Result := 1; end
    else if wh <= 16 then begin if angle >= 48 then Result := 2 else if angle >= 20 then Result := 1; end
    else if wh <= 24 then begin if angle >= 4 then Result := 3; end
    else Result := 3;
  end
  else
  begin
    if wh <= 8 then begin if angle >= 56 then Result := 1; end
    else if wh <= 16 then begin if angle >= 40 then Result := 1; end
    else if wh <= 24 then begin if angle >= 32 then Result := 3 else if angle >= 16 then Result := 2 else if angle >= 8 then Result := 1; end
    else if wh <= 32 then begin if angle >= 32 then Result := 3 else if angle >= 4 then Result := 2 else Result := 1; end
    else Result := 3;
  end;
end;

// filter_edge: In is a centred pointer; In[i] valid, clipped to [from, to-1].
procedure FilterEdge(OutP: PInteger; sz, limFrom, limTo: Integer; InP: PInteger; from, toi, strength: Integer);
var i, j, s: Integer;
begin
  i := 0;
  while i < IMin(sz, limFrom) do begin OutP[i] := InP[IClip(i, from, toi-1)]; Inc(i); end;
  while i < IMin(limTo, sz) do
  begin
    s := 0; for j := 0 to 4 do Inc(s, InP[IClip(i-2+j, from, toi-1)] * FeKernel[strength-1][j]);
    OutP[i] := (s + 8) shr 4; Inc(i);
  end;
  while i < sz do begin OutP[i] := InP[IClip(i, from, toi-1)]; Inc(i); end;
end;

procedure UpsampleEdge(OutP: PInteger; hsz: Integer; InP: PInteger; from, toi: Integer);
var i, j, s: Integer;
begin
  for i := 0 to hsz-2 do
  begin
    OutP[i*2] := InP[IClip(i, from, toi-1)];
    s := 0; for j := 0 to 3 do Inc(s, InP[IClip(i+j-1, from, toi-1)] * UeKernel[j]);
    OutP[i*2+1] := ClipPx((s + 8) shr 4);
  end;
  OutP[(hsz-1)*2] := InP[IClip(hsz-1, from, toi-1)];
end;

procedure IPredZ1(Dst: PWord; Stride: Integer; TL: PInteger; W, H, Angle, MaxW, MaxH: Integer);
var
  isSm, edgeF, dx, maxBaseX, upAbove, baseInc, y, x, xpos, frac, base, v, fs: Integer;
  topOut: array[0..259] of Integer; top: PInteger; row: PWord;
begin
  isSm := (Angle shr 9) and 1; edgeF := Angle shr 10; Angle := Angle and 511;
  dx := DrIntraDerivative[Angle shr 1];
  if edgeF <> 0 then upAbove := GetUpsample(W+H, 90-Angle, isSm) else upAbove := 0;
  if upAbove <> 0 then
  begin
    UpsampleEdge(@topOut[0], W+H, @TL[1], -1, W + IMin(W,H));
    top := @topOut[0]; maxBaseX := 2*(W+H)-2; dx := dx shl 1;
  end
  else
  begin
    if edgeF <> 0 then fs := GetFilterStrength(W+H, 90-Angle, isSm) else fs := 0;
    if fs <> 0 then
    begin
      FilterEdge(@topOut[0], W+H, 0, W+H, @TL[1], -1, W + IMin(W,H), fs);
      top := @topOut[0]; maxBaseX := W+H-1;
    end
    else begin top := @TL[1]; maxBaseX := W + IMin(W,H) - 1; end;
  end;
  baseInc := 1 + upAbove; xpos := dx;
  for y := 0 to H-1 do
  begin
    row := @Dst[y*Stride]; frac := xpos and $3E; base := Sar6(xpos); x := 0;
    while x < W do
    begin
      if base < maxBaseX then begin v := top[base]*(64-frac) + top[base+1]*frac; row[x] := Word((v+32) shr 6); end
      else begin while x < W do begin row[x] := Word(top[maxBaseX]); Inc(x); end; Break; end;
      Inc(x); Inc(base, baseInc);
    end;
    Inc(xpos, dx);
  end;
end;

procedure IPredZ3(Dst: PWord; Stride: Integer; TL: PInteger; W, H, Angle, MaxW, MaxH: Integer);
var
  isSm, edgeF, dy, maxBaseY, upLeft, baseInc, y, x, ypos, frac, base, v, fs: Integer;
  leftOut: array[0..259] of Integer; left: PInteger;
begin
  isSm := (Angle shr 9) and 1; edgeF := Angle shr 10; Angle := Angle and 511;
  dy := DrIntraDerivative[(270 - Angle) shr 1];
  if edgeF <> 0 then upLeft := GetUpsample(W+H, Angle-180, isSm) else upLeft := 0;
  if upLeft <> 0 then
  begin
    UpsampleEdge(@leftOut[0], W+H, @TL[-(W+H)], IMax(W-H,0), W+H+1);
    left := @leftOut[2*(W+H)-2]; maxBaseY := 2*(W+H)-2; dy := dy shl 1;
  end
  else
  begin
    if edgeF <> 0 then fs := GetFilterStrength(W+H, Angle-180, isSm) else fs := 0;
    if fs <> 0 then
    begin
      FilterEdge(@leftOut[0], W+H, 0, W+H, @TL[-(W+H)], IMax(W-H,0), W+H+1, fs);
      left := @leftOut[W+H-1]; maxBaseY := W+H-1;
    end
    else begin left := @TL[-1]; maxBaseY := H + IMin(W,H) - 1; end;
  end;
  baseInc := 1 + upLeft; ypos := dy;
  for x := 0 to W-1 do
  begin
    frac := ypos and $3E; base := Sar6(ypos); y := 0;
    while y < H do
    begin
      if base < maxBaseY then begin v := left[-base]*(64-frac) + left[-(base+1)]*frac; Dst[y*Stride+x] := Word((v+32) shr 6); end
      else begin repeat Dst[y*Stride+x] := Word(left[-maxBaseY]); Inc(y); until y >= H; Break; end;
      Inc(y); Inc(base, baseInc);
    end;
    Inc(ypos, dy);
  end;
end;

procedure IPredZ2(Dst: PWord; Stride: Integer; TL: PInteger; W, H, Angle, MaxW, MaxH: Integer);
var
  isSm, edgeF, dy, dx, upLeft, upAbove, baseIncX, y, x, xpos, ypos, baseX, fracX, baseY, fracY, v, fs, i: Integer;
  edge: array[0..259] of Integer; tlp: PInteger; leftp: PInteger;
begin
  isSm := (Angle shr 9) and 1; edgeF := Angle shr 10; Angle := Angle and 511;
  dy := DrIntraDerivative[(Angle - 90) shr 1];
  dx := DrIntraDerivative[(180 - Angle) shr 1];
  tlp := @edge[130];
  if edgeF <> 0 then upLeft := GetUpsample(W+H, 180-Angle, isSm) else upLeft := 0;
  if edgeF <> 0 then upAbove := GetUpsample(W+H, Angle-90, isSm) else upAbove := 0;
  if upAbove <> 0 then begin UpsampleEdge(@tlp[0], W+1, @TL[0], 0, W+1); dx := dx shl 1; end
  else
  begin
    if edgeF <> 0 then fs := GetFilterStrength(W+H, Angle-90, isSm) else fs := 0;
    if fs <> 0 then FilterEdge(@tlp[1], W, 0, MaxW, @TL[1], -1, W, fs)
    else for i := 0 to W-1 do tlp[1+i] := TL[1+i];
  end;
  if upLeft <> 0 then begin UpsampleEdge(@edge[130 - H*2], H+1, @TL[-H], 0, H+1); dy := dy shl 1; end
  else
  begin
    if edgeF <> 0 then fs := GetFilterStrength(W+H, 180-Angle, isSm) else fs := 0;
    if fs <> 0 then FilterEdge(@edge[130 - H], H, H-MaxH, H, @TL[-H], 0, H+1, fs)
    else for i := 0 to H-1 do tlp[-H+i] := TL[-H+i];
  end;
  tlp[0] := TL[0];
  baseIncX := 1 + upAbove; leftp := @tlp[-(1 + upLeft)];
  xpos := ((1 + upAbove) shl 6) - dx;
  for y := 0 to H-1 do
  begin
    baseX := Sar6(xpos); fracX := xpos and $3E; ypos := (y shl (6 + upLeft)) - dy;
    for x := 0 to W-1 do
    begin
      if baseX >= 0 then v := tlp[baseX]*(64-fracX) + tlp[baseX+1]*fracX
      else begin baseY := Sar6(ypos); fracY := ypos and $3E; v := leftp[-baseY]*(64-fracY) + leftp[-(baseY+1)]*fracY; end;
      Dst[y*Stride + x] := Word((v + 32) shr 6);
      Inc(baseX, baseIncX); Dec(ypos, dy);
    end;
    Dec(xpos, dx);
  end;
end;

end.
