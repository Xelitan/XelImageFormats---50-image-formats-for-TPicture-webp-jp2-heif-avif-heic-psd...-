unit Av1.Mc;

// AV1 motion-compensation kernels: sub-pixel 8-tap / bilinear interpolation
// (put = to pixels, prep = to 16-bit intermediates for compound prediction),
// compound averaging / masking, OBMC blends, inter-intra blend and the 8x8
// affine warp, plus the warp-model helpers (shear parameters, least-squares
// local warp). Pixels are Word at any bit depth (8/10/12).
//
// Port of dav1d src/mc_tmpl.c and src/warpmv.c (BSD-2-Clause). All signed
// right shifts are arithmetic (SarLongint / SarInt64), as dav1d assumes.

{$mode delphi}{$H+}
{$RANGECHECKS OFF}{$OVERFLOWCHECKS OFF}{$POINTERMATH ON}

interface

uses Av1.Tables;

type
  PSmallIntArr = ^SmallInt;

  TWarpParams = record
    WmType: Integer;
    Matrix: array[0..5] of LongInt;
    Alpha, Beta, Gamma, Delta: SmallInt;
  end;
  PWarpParams = ^TWarpParams;

// put: dst pixels = interpolated src. src points at the block origin; it must
// have 3 valid rows/cols before and 4 after (callers emulate edges).
procedure McPut(Dst: PWord; DstStride: Integer; Src: PWord; SrcStride: Integer;
  W, H, Mx, My, Filter2d, Bd: Integer);
// prep: 16-bit intermediates (W*H, stride W).
procedure McPrep(Tmp: PSmallInt; Src: PWord; SrcStride: Integer;
  W, H, Mx, My, Filter2d, Bd: Integer);

procedure McAvg(Dst: PWord; DstStride: Integer; T1, T2: PSmallInt; W, H, Bd: Integer);
procedure McWAvg(Dst: PWord; DstStride: Integer; T1, T2: PSmallInt; W, H, Weight, Bd: Integer);
procedure McMask(Dst: PWord; DstStride: Integer; T1, T2: PSmallInt; W, H: Integer;
  Mask: PByte; Bd: Integer);
procedure McWMask(Dst: PWord; DstStride: Integer; T1, T2: PSmallInt; W, H: Integer;
  Mask: PByte; Sign, SsHor, SsVer, Bd: Integer);
procedure McBlend(Dst: PWord; DstStride: Integer; Tmp: PWord; W, H: Integer; Mask: PByte);
procedure McBlendV(Dst: PWord; DstStride: Integer; Tmp: PWord; W, H: Integer);
procedure McBlendH(Dst: PWord; DstStride: Integer; Tmp: PWord; W, H: Integer);

procedure Warp8x8(Dst: PWord; DstStride: Integer; Src: PWord; SrcStride: Integer;
  const Wp: TWarpParams; Mx, My, Bd: Integer);
procedure Warp8x8t(Tmp: PSmallInt; TmpStride: Integer; Src: PWord; SrcStride: Integer;
  const Wp: TWarpParams; Mx, My, Bd: Integer);

// warpmv.c
function GetShearParams(var Wm: TWarpParams): Boolean;   // True = invalid
procedure SetAffineMv2d(Bw4, Bh4, MvY, MvX: Integer; var Wm: TWarpParams; Bx4, By4: Integer);
function FindAffineInt(const Pts: array of Integer; Np, Bw4, Bh4, MvY, MvX: Integer;
  var Wm: TWarpParams; Bx4, By4: Integer): Boolean;      // True = failed

implementation

function IMin(a, b: Integer): Integer; inline; begin if a < b then Result := a else Result := b; end;
function IMax(a, b: Integer): Integer; inline; begin if a > b then Result := a else Result := b; end;
function IClip(v, lo, hi: Integer): Integer; inline;
begin if v < lo then Result := lo else if v > hi then Result := hi else Result := v; end;

function IntermediateBits(Bd: Integer): Integer; inline;
begin if Bd = 8 then Result := 4 else Result := 14 - Bd; end;
function PrepBias(Bd: Integer): Integer; inline;
begin if Bd = 8 then Result := 0 else Result := 8192; end;

// filter selection (GET_H_FILTER / GET_V_FILTER)
function HFilter(Mx, W, FType: Integer): PShortInt; inline;
begin
  if Mx = 0 then Result := nil
  else if W > 4 then Result := @McSubpelFilters[FType and 3][Mx - 1][0]
  else Result := @McSubpelFilters[3 + (FType and 1)][Mx - 1][0];
end;
function VFilter(My, H, FType: Integer): PShortInt; inline;
begin
  if My = 0 then Result := nil
  else if H > 4 then Result := @McSubpelFilters[FType shr 2][My - 1][0]
  else Result := @McSubpelFilters[3 + ((FType shr 2) and 1)][My - 1][0];
end;

function F8W(Src: PWord; X: Integer; F: PShortInt; Stride: Integer): Integer; inline;
begin
  Result := F[0] * Src[X - 3*Stride] + F[1] * Src[X - 2*Stride] + F[2] * Src[X - Stride] +
            F[3] * Src[X] + F[4] * Src[X + Stride] + F[5] * Src[X + 2*Stride] +
            F[6] * Src[X + 3*Stride] + F[7] * Src[X + 4*Stride];
end;
function F8S(Src: PSmallInt; X: Integer; F: PShortInt; Stride: Integer): Integer; inline;
begin
  Result := F[0] * Src[X - 3*Stride] + F[1] * Src[X - 2*Stride] + F[2] * Src[X - Stride] +
            F[3] * Src[X] + F[4] * Src[X + Stride] + F[5] * Src[X + 2*Stride] +
            F[6] * Src[X + 3*Stride] + F[7] * Src[X + 4*Stride];
end;

function Rnd(V, Sh: Integer): Integer; inline;
begin Result := SarLongint(V + ((1 shl Sh) shr 1), Sh); end;

// Filter2d -> dav1d filter_type (type_h | type_v << 2). FilterDir holds
// (vertical, horizontal), as dav1d_filter_dir does.
function FilterType(Filter2d: Integer): Integer; inline;
begin Result := FilterDir[Filter2d][1] or (FilterDir[Filter2d][0] shl 2); end;

var
  Mid: array[0..128*136-1] of SmallInt;   // shared scratch (single-threaded decoder)

procedure Put8Tap(Dst: PWord; DstStride: Integer; Src: PWord; SrcStride: Integer;
  W, H, Mx, My, FType, Bd: Integer);
var ib, irnd, pmax, x, y, tmpH: Integer; fh, fv: PShortInt; mp: PSmallInt;
begin
  ib := IntermediateBits(Bd);
  irnd := 32 + ((1 shl (6 - ib)) shr 1);
  pmax := (1 shl Bd) - 1;
  fh := HFilter(Mx, W, FType); fv := VFilter(My, H, FType);
  if fh <> nil then
  begin
    if fv <> nil then
    begin
      tmpH := H + 7;
      Src := Src - SrcStride * 3;
      mp := @Mid[0];
      for y := 0 to tmpH - 1 do
      begin
        for x := 0 to W - 1 do mp[x] := Rnd(F8W(Src, x, fh, 1), 6 - ib);
        Inc(mp, 128); Inc(Src, SrcStride);
      end;
      mp := @Mid[128 * 3];
      for y := 0 to H - 1 do
      begin
        for x := 0 to W - 1 do Dst[x] := IClip(Rnd(F8S(mp, x, fv, 128), 6 + ib), 0, pmax);
        Inc(mp, 128); Inc(Dst, DstStride);
      end;
    end
    else
      for y := 0 to H - 1 do
      begin
        for x := 0 to W - 1 do Dst[x] := IClip(SarLongint(F8W(Src, x, fh, 1) + irnd, 6), 0, pmax);
        Inc(Dst, DstStride); Inc(Src, SrcStride);
      end;
  end
  else if fv <> nil then
    for y := 0 to H - 1 do
    begin
      for x := 0 to W - 1 do Dst[x] := IClip(Rnd(F8W(Src, x, fv, SrcStride), 6), 0, pmax);
      Inc(Dst, DstStride); Inc(Src, SrcStride);
    end
  else
    for y := 0 to H - 1 do
    begin
      Move(Src^, Dst^, W * 2);
      Inc(Dst, DstStride); Inc(Src, SrcStride);
    end;
end;

procedure Prep8Tap(Tmp: PSmallInt; Src: PWord; SrcStride: Integer;
  W, H, Mx, My, FType, Bd: Integer);
var ib, bias, x, y, tmpH: Integer; fh, fv: PShortInt; mp: PSmallInt;
begin
  ib := IntermediateBits(Bd); bias := PrepBias(Bd);
  fh := HFilter(Mx, W, FType); fv := VFilter(My, H, FType);
  if fh <> nil then
  begin
    if fv <> nil then
    begin
      tmpH := H + 7;
      Src := Src - SrcStride * 3;
      mp := @Mid[0];
      for y := 0 to tmpH - 1 do
      begin
        for x := 0 to W - 1 do mp[x] := Rnd(F8W(Src, x, fh, 1), 6 - ib);
        Inc(mp, 128); Inc(Src, SrcStride);
      end;
      mp := @Mid[128 * 3];
      for y := 0 to H - 1 do
      begin
        for x := 0 to W - 1 do Tmp[x] := Rnd(F8S(mp, x, fv, 128), 6) - bias;
        Inc(mp, 128); Inc(Tmp, W);
      end;
    end
    else
      for y := 0 to H - 1 do
      begin
        for x := 0 to W - 1 do Tmp[x] := Rnd(F8W(Src, x, fh, 1), 6 - ib) - bias;
        Inc(Tmp, W); Inc(Src, SrcStride);
      end;
  end
  else if fv <> nil then
    for y := 0 to H - 1 do
    begin
      for x := 0 to W - 1 do Tmp[x] := Rnd(F8W(Src, x, fv, SrcStride), 6 - ib) - bias;
      Inc(Tmp, W); Inc(Src, SrcStride);
    end
  else
    for y := 0 to H - 1 do
    begin
      for x := 0 to W - 1 do Tmp[x] := (Src[x] shl ib) - bias;
      Inc(Tmp, W); Inc(Src, SrcStride);
    end;
end;

function BilW(Src: PWord; X, M, Stride: Integer): Integer; inline;
begin Result := 16 * Src[X] + M * (Src[X + Stride] - Src[X]); end;
function BilS(Src: PSmallInt; X, M, Stride: Integer): Integer; inline;
begin Result := 16 * Src[X] + M * (Src[X + Stride] - Src[X]); end;

procedure PutBilin(Dst: PWord; DstStride: Integer; Src: PWord; SrcStride: Integer;
  W, H, Mx, My, Bd: Integer);
var ib, irnd, pmax, x, y, px: Integer; mp: PSmallInt;
begin
  ib := IntermediateBits(Bd); irnd := (1 shl ib) shr 1; pmax := (1 shl Bd) - 1;
  if Mx <> 0 then
  begin
    if My <> 0 then
    begin
      mp := @Mid[0];
      for y := 0 to H do
      begin
        for x := 0 to W - 1 do mp[x] := Rnd(BilW(Src, x, Mx, 1), 4 - ib);
        Inc(mp, 128); Inc(Src, SrcStride);
      end;
      mp := @Mid[0];
      for y := 0 to H - 1 do
      begin
        for x := 0 to W - 1 do Dst[x] := IClip(Rnd(BilS(mp, x, My, 128), 4 + ib), 0, pmax);
        Inc(mp, 128); Inc(Dst, DstStride);
      end;
    end
    else
      for y := 0 to H - 1 do
      begin
        for x := 0 to W - 1 do
        begin
          px := Rnd(BilW(Src, x, Mx, 1), 4 - ib);
          Dst[x] := IClip(SarLongint(px + irnd, ib), 0, pmax);
        end;
        Inc(Dst, DstStride); Inc(Src, SrcStride);
      end;
  end
  else if My <> 0 then
    for y := 0 to H - 1 do
    begin
      for x := 0 to W - 1 do Dst[x] := IClip(Rnd(BilW(Src, x, My, SrcStride), 4), 0, pmax);
      Inc(Dst, DstStride); Inc(Src, SrcStride);
    end
  else
    for y := 0 to H - 1 do
    begin
      Move(Src^, Dst^, W * 2);
      Inc(Dst, DstStride); Inc(Src, SrcStride);
    end;
end;

procedure PrepBilin(Tmp: PSmallInt; Src: PWord; SrcStride: Integer; W, H, Mx, My, Bd: Integer);
var ib, bias, x, y: Integer; mp: PSmallInt;
begin
  ib := IntermediateBits(Bd); bias := PrepBias(Bd);
  if Mx <> 0 then
  begin
    if My <> 0 then
    begin
      mp := @Mid[0];
      for y := 0 to H do
      begin
        for x := 0 to W - 1 do mp[x] := Rnd(BilW(Src, x, Mx, 1), 4 - ib);
        Inc(mp, 128); Inc(Src, SrcStride);
      end;
      mp := @Mid[0];
      for y := 0 to H - 1 do
      begin
        for x := 0 to W - 1 do Tmp[x] := Rnd(BilS(mp, x, My, 128), 4) - bias;
        Inc(mp, 128); Inc(Tmp, W);
      end;
    end
    else
      for y := 0 to H - 1 do
      begin
        for x := 0 to W - 1 do Tmp[x] := Rnd(BilW(Src, x, Mx, 1), 4 - ib) - bias;
        Inc(Tmp, W); Inc(Src, SrcStride);
      end;
  end
  else if My <> 0 then
    for y := 0 to H - 1 do
    begin
      for x := 0 to W - 1 do Tmp[x] := Rnd(BilW(Src, x, My, SrcStride), 4 - ib) - bias;
      Inc(Tmp, W); Inc(Src, SrcStride);
    end
  else
    for y := 0 to H - 1 do
    begin
      for x := 0 to W - 1 do Tmp[x] := (Src[x] shl ib) - bias;
      Inc(Tmp, W); Inc(Src, SrcStride);
    end;
end;

procedure McPut(Dst: PWord; DstStride: Integer; Src: PWord; SrcStride: Integer;
  W, H, Mx, My, Filter2d, Bd: Integer);
begin
  if Filter2d = FILTER_2D_BILINEAR then PutBilin(Dst, DstStride, Src, SrcStride, W, H, Mx, My, Bd)
  else Put8Tap(Dst, DstStride, Src, SrcStride, W, H, Mx, My, FilterType(Filter2d), Bd);
end;

procedure McPrep(Tmp: PSmallInt; Src: PWord; SrcStride: Integer;
  W, H, Mx, My, Filter2d, Bd: Integer);
begin
  if Filter2d = FILTER_2D_BILINEAR then PrepBilin(Tmp, Src, SrcStride, W, H, Mx, My, Bd)
  else Prep8Tap(Tmp, Src, SrcStride, W, H, Mx, My, FilterType(Filter2d), Bd);
end;

procedure McAvg(Dst: PWord; DstStride: Integer; T1, T2: PSmallInt; W, H, Bd: Integer);
var ib, sh, r, pmax, x, y: Integer;
begin
  ib := IntermediateBits(Bd); sh := ib + 1; r := (1 shl ib) + PrepBias(Bd) * 2;
  pmax := (1 shl Bd) - 1;
  for y := 0 to H - 1 do
  begin
    for x := 0 to W - 1 do Dst[x] := IClip(SarLongint(T1[x] + T2[x] + r, sh), 0, pmax);
    Inc(T1, W); Inc(T2, W); Inc(Dst, DstStride);
  end;
end;

procedure McWAvg(Dst: PWord; DstStride: Integer; T1, T2: PSmallInt; W, H, Weight, Bd: Integer);
var ib, sh, r, pmax, x, y: Integer;
begin
  ib := IntermediateBits(Bd); sh := ib + 4; r := (8 shl ib) + PrepBias(Bd) * 16;
  pmax := (1 shl Bd) - 1;
  for y := 0 to H - 1 do
  begin
    for x := 0 to W - 1 do
      Dst[x] := IClip(SarLongint(T1[x] * Weight + T2[x] * (16 - Weight) + r, sh), 0, pmax);
    Inc(T1, W); Inc(T2, W); Inc(Dst, DstStride);
  end;
end;

procedure McMask(Dst: PWord; DstStride: Integer; T1, T2: PSmallInt; W, H: Integer;
  Mask: PByte; Bd: Integer);
var ib, sh, r, pmax, x, y: Integer;
begin
  ib := IntermediateBits(Bd); sh := ib + 6; r := (32 shl ib) + PrepBias(Bd) * 64;
  pmax := (1 shl Bd) - 1;
  for y := 0 to H - 1 do
  begin
    for x := 0 to W - 1 do
      Dst[x] := IClip(SarLongint(T1[x] * Mask[x] + T2[x] * (64 - Mask[x]) + r, sh), 0, pmax);
    Inc(T1, W); Inc(T2, W); Inc(Mask, W); Inc(Dst, DstStride);
  end;
end;

procedure McWMask(Dst: PWord; DstStride: Integer; T1, T2: PSmallInt; W, H: Integer;
  Mask: PByte; Sign, SsHor, SsVer, Bd: Integer);
var ib, sh, r, pmax, mask_sh, mask_rnd, x, y, d, m, n: Integer;
begin
  ib := IntermediateBits(Bd); sh := ib + 6; r := (32 shl ib) + PrepBias(Bd) * 64;
  pmax := (1 shl Bd) - 1;
  mask_sh := Bd + ib - 4;
  mask_rnd := 1 shl (mask_sh - 5);
  y := H;
  while y > 0 do
  begin
    x := 0;
    while x < W do
    begin
      d := T1[x] - T2[x];
      m := IMin(38 + SarLongint(Abs(d) + mask_rnd, mask_sh), 64);
      Dst[x] := IClip(SarLongint(d * m + T2[x] * 64 + r, sh), 0, pmax);
      if SsHor <> 0 then
      begin
        Inc(x);
        d := T1[x] - T2[x];
        n := IMin(38 + SarLongint(Abs(d) + mask_rnd, mask_sh), 64);
        Dst[x] := IClip(SarLongint(d * n + T2[x] * 64 + r, sh), 0, pmax);
        if (y and SsVer) <> 0 then
          Mask[x shr 1] := (m + n + Mask[x shr 1] + 2 - Sign) shr 2
        else if SsVer <> 0 then
          Mask[x shr 1] := m + n
        else
          Mask[x shr 1] := (m + n + 1 - Sign) shr 1;
      end
      else
        Mask[x] := m;
      Inc(x);
    end;
    Inc(T1, W); Inc(T2, W); Inc(Dst, DstStride);
    if (SsVer = 0) or ((y and 1) <> 0) then Inc(Mask, W shr SsHor);
    Dec(y);
  end;
end;

function BlendPx(a, b, m: Integer): Integer; inline;
begin Result := (a * (64 - m) + b * m + 32) shr 6; end;

procedure McBlend(Dst: PWord; DstStride: Integer; Tmp: PWord; W, H: Integer; Mask: PByte);
var x, y: Integer;
begin
  for y := 0 to H - 1 do
  begin
    for x := 0 to W - 1 do Dst[x] := BlendPx(Dst[x], Tmp[x], Mask[x]);
    Inc(Dst, DstStride); Inc(Tmp, W); Inc(Mask, W);
  end;
end;

procedure McBlendV(Dst: PWord; DstStride: Integer; Tmp: PWord; W, H: Integer);
var x, y: Integer; mask: PByte;
begin
  mask := @ObmcMasks[W];
  for y := 0 to H - 1 do
  begin
    for x := 0 to ((W * 3) shr 2) - 1 do Dst[x] := BlendPx(Dst[x], Tmp[x], mask[x]);
    Inc(Dst, DstStride); Inc(Tmp, W);
  end;
end;

procedure McBlendH(Dst: PWord; DstStride: Integer; Tmp: PWord; W, H: Integer);
var x, y, m: Integer; mask: PByte;
begin
  mask := @ObmcMasks[H];
  for y := 0 to ((H * 3) shr 2) - 1 do
  begin
    m := mask[y];
    for x := 0 to W - 1 do Dst[x] := BlendPx(Dst[x], Tmp[x], m);
    Inc(Dst, DstStride); Inc(Tmp, W);
  end;
end;

procedure WarpH(Src: PWord; SrcStride: Integer; const Wp: TWarpParams; Mx, Bd: Integer;
  var M: array of SmallInt);
var ib, x, y, tmx, k, acc: Integer; f: PShortInt;
begin
  ib := IntermediateBits(Bd);
  Src := Src - 3 * SrcStride;
  for y := 0 to 14 do
  begin
    tmx := Mx;
    for x := 0 to 7 do
    begin
      f := @McWarpFilter[64 + SarLongint(tmx + 512, 10)][0];
      acc := 0;
      for k := 0 to 7 do Inc(acc, f[k] * Src[x - 3 + k]);
      M[y*8 + x] := Rnd(acc, 7 - ib);
      Inc(tmx, Wp.Alpha);
    end;
    Inc(Src, SrcStride);
    Inc(Mx, Wp.Beta);
  end;
end;

procedure Warp8x8(Dst: PWord; DstStride: Integer; Src: PWord; SrcStride: Integer;
  const Wp: TWarpParams; Mx, My, Bd: Integer);
var M: array[0..15*8-1] of SmallInt; ib, pmax, x, y, tmy, k, acc: Integer; f: PShortInt;
begin
  ib := IntermediateBits(Bd); pmax := (1 shl Bd) - 1;
  WarpH(Src, SrcStride, Wp, Mx, Bd, M);
  for y := 0 to 7 do
  begin
    tmy := My;
    for x := 0 to 7 do
    begin
      f := @McWarpFilter[64 + SarLongint(tmy + 512, 10)][0];
      acc := 0;
      for k := 0 to 7 do Inc(acc, f[k] * M[(y + k) * 8 + x]);
      Dst[x] := IClip(Rnd(acc, 7 + ib), 0, pmax);
      Inc(tmy, Wp.Gamma);
    end;
    Inc(Dst, DstStride);
    Inc(My, Wp.Delta);
  end;
end;

procedure Warp8x8t(Tmp: PSmallInt; TmpStride: Integer; Src: PWord; SrcStride: Integer;
  const Wp: TWarpParams; Mx, My, Bd: Integer);
var M: array[0..15*8-1] of SmallInt; bias, x, y, tmy, k, acc: Integer; f: PShortInt;
begin
  bias := PrepBias(Bd);
  WarpH(Src, SrcStride, Wp, Mx, Bd, M);
  for y := 0 to 7 do
  begin
    tmy := My;
    for x := 0 to 7 do
    begin
      f := @McWarpFilter[64 + SarLongint(tmy + 512, 10)][0];
      acc := 0;
      for k := 0 to 7 do Inc(acc, f[k] * M[(y + k) * 8 + x]);
      Tmp[x] := Rnd(acc, 7) - bias;
      Inc(tmy, Wp.Gamma);
    end;
    Inc(Tmp, TmpStride);
    Inc(My, Wp.Delta);
  end;
end;

// ---------------------------------------------------------------- warpmv.c

const
  DivLut: array[0..256] of Word = (
    16384, 16320, 16257, 16194, 16132, 16070, 16009, 15948, 15888, 15828, 15768,
    15709, 15650, 15592, 15534, 15477, 15420, 15364, 15308, 15252, 15197, 15142,
    15087, 15033, 14980, 14926, 14873, 14821, 14769, 14717, 14665, 14614, 14564,
    14513, 14463, 14413, 14364, 14315, 14266, 14218, 14170, 14122, 14075, 14028,
    13981, 13935, 13888, 13843, 13797, 13752, 13707, 13662, 13618, 13574, 13530,
    13487, 13443, 13400, 13358, 13315, 13273, 13231, 13190, 13148, 13107, 13066,
    13026, 12985, 12945, 12906, 12866, 12827, 12788, 12749, 12710, 12672, 12633,
    12596, 12558, 12520, 12483, 12446, 12409, 12373, 12336, 12300, 12264, 12228,
    12193, 12157, 12122, 12087, 12053, 12018, 11984, 11950, 11916, 11882, 11848,
    11815, 11782, 11749, 11716, 11683, 11651, 11619, 11586, 11555, 11523, 11491,
    11460, 11429, 11398, 11367, 11336, 11305, 11275, 11245, 11215, 11185, 11155,
    11125, 11096, 11067, 11038, 11009, 10980, 10951, 10923, 10894, 10866, 10838,
    10810, 10782, 10755, 10727, 10700, 10673, 10645, 10618, 10592, 10565, 10538,
    10512, 10486, 10460, 10434, 10408, 10382, 10356, 10331, 10305, 10280, 10255,
    10230, 10205, 10180, 10156, 10131, 10107, 10082, 10058, 10034, 10010,  9986,
     9963,  9939,  9916,  9892,  9869,  9846,  9823,  9800,  9777,  9754,  9732,
     9709,  9687,  9664,  9642,  9620,  9598,  9576,  9554,  9533,  9511,  9489,
     9468,  9447,  9425,  9404,  9383,  9362,  9341,  9321,  9300,  9279,  9259,
     9239,  9218,  9198,  9178,  9158,  9138,  9118,  9098,  9079,  9059,  9039,
     9020,  9001,  8981,  8962,  8943,  8924,  8905,  8886,  8867,  8849,  8830,
     8812,  8793,  8775,  8756,  8738,  8720,  8702,  8684,  8666,  8648,  8630,
     8613,  8595,  8577,  8560,  8542,  8525,  8508,  8490,  8473,  8456,  8439,
     8422,  8405,  8389,  8372,  8355,  8339,  8322,  8306,  8289,  8273,  8257,
     8240,  8224,  8208,  8192);

function ApplySign(v, s: Integer): Integer; inline;
begin if s < 0 then Result := -v else Result := v; end;
function ApplySign64(v: Integer; s: Int64): Integer; inline;
begin if s < 0 then Result := -v else Result := v; end;

function IClipWmp(v: Integer): Integer;
var cv: Integer;
begin
  cv := IClip(v, -32768, 32767);
  Result := ApplySign((Abs(cv) + 32) shr 6, cv) * 64;
end;

function ULog2_64(v: UInt64): Integer;
begin
  Result := -1;
  while v <> 0 do begin v := v shr 1; Inc(Result); end;
end;

function ResolveDivisor32(d: LongWord; out Shift: Integer): Integer;
var e, f: Integer;
begin
  Shift := ULog2(d);
  e := Integer(d) - (1 shl Shift);
  if Shift > 8 then f := SarLongint(e + (1 shl (Shift - 9)), Shift - 8)
  else f := e shl (8 - Shift);
  Inc(Shift, 14);
  Result := DivLut[f];
end;

function ResolveDivisor64(d: UInt64; out Shift: Integer): Integer;
var e, f: Int64;
begin
  Shift := ULog2_64(d);
  e := Int64(d) - (Int64(1) shl Shift);
  if Shift > 8 then f := SarInt64(e + (Int64(1) shl (Shift - 9)), Shift - 8)
  else f := e shl (8 - Shift);
  Inc(Shift, 14);
  Result := DivLut[f];
end;

function GetShearParams(var Wm: TWarpParams): Boolean;
var shift, y, rnd: Integer; v1, v2: Int64;
begin
  if Wm.Matrix[2] <= 0 then Exit(True);
  Wm.Alpha := IClipWmp(Wm.Matrix[2] - $10000);
  Wm.Beta := IClipWmp(Wm.Matrix[3]);
  y := ApplySign(ResolveDivisor32(Abs(Wm.Matrix[2]), shift), Wm.Matrix[2]);
  v1 := (Int64(Wm.Matrix[4]) * $10000) * y;
  rnd := (1 shl shift) shr 1;
  Wm.Gamma := IClipWmp(ApplySign64(Integer(SarInt64(Abs(v1) + rnd, shift)), v1));
  v2 := (Int64(Wm.Matrix[3]) * Wm.Matrix[4]) * y;
  Wm.Delta := IClipWmp(Wm.Matrix[5] - ApplySign64(Integer(SarInt64(Abs(v2) + rnd, shift)), v2) - $10000);
  Result := (4 * Abs(Integer(Wm.Alpha)) + 7 * Abs(Integer(Wm.Beta)) >= $10000) or
            (4 * Abs(Integer(Wm.Gamma)) + 4 * Abs(Integer(Wm.Delta)) >= $10000);
end;

function GetMultShiftNdiag(px: Int64; idet, shift: Integer): Integer;
var v1: Int64; v2: Integer;
begin
  v1 := px * idet;
  v2 := ApplySign64(Integer(SarInt64(Abs(v1) + (SarInt64(Int64(1) shl shift, 1)), shift)), v1);
  Result := IClip(v2, -$1fff, $1fff);
end;

function GetMultShiftDiag(px: Int64; idet, shift: Integer): Integer;
var v1: Int64; v2: Integer;
begin
  v1 := px * idet;
  v2 := ApplySign64(Integer(SarInt64(Abs(v1) + (SarInt64(Int64(1) shl shift, 1)), shift)), v1);
  Result := IClip(v2, $e001, $11fff);
end;

procedure SetAffineMv2d(Bw4, Bh4, MvY, MvX: Integer; var Wm: TWarpParams; Bx4, By4: Integer);
var rsuy, rsux, isuy, isux: Integer;
begin
  rsuy := 2 * Bh4 - 1; rsux := 2 * Bw4 - 1;
  isuy := By4 * 4 + rsuy; isux := Bx4 * 4 + rsux;
  Wm.Matrix[0] := IClip(MvX * $2000 - (isux * (Wm.Matrix[2] - $10000) + isuy * Wm.Matrix[3]),
                        -$800000, $7fffff);
  Wm.Matrix[1] := IClip(MvY * $2000 - (isux * Wm.Matrix[4] + isuy * (Wm.Matrix[5] - $10000)),
                        -$800000, $7fffff);
end;

// Pts: np records of 4 ints (in.x, in.y, out.x, out.y).
function FindAffineInt(const Pts: array of Integer; Np, Bw4, Bh4, MvY, MvX: Integer;
  var Wm: TWarpParams; Bx4, By4: Integer): Boolean;
var
  a00, a01, a11, bx0, bx1, by0, by1: Integer;
  rsuy, rsux, suy, sux, duy, dux, isuy, isux, i, dx, dy, sx, sy, shift, idet: Integer;
  det: Int64;
begin
  a00 := 0; a01 := 0; a11 := 0; bx0 := 0; bx1 := 0; by0 := 0; by1 := 0;
  rsuy := 2 * Bh4 - 1; rsux := 2 * Bw4 - 1;
  suy := rsuy * 8; sux := rsux * 8;
  duy := suy + MvY; dux := sux + MvX;
  isuy := By4 * 4 + rsuy; isux := Bx4 * 4 + rsux;
  for i := 0 to Np - 1 do
  begin
    dx := Pts[i*4 + 2] - dux; dy := Pts[i*4 + 3] - duy;
    sx := Pts[i*4 + 0] - sux; sy := Pts[i*4 + 1] - suy;
    if (Abs(sx - dx) < 256) and (Abs(sy - dy) < 256) then
    begin
      Inc(a00, SarLongint(sx * sx, 2) + sx * 2 + 8);
      Inc(a01, SarLongint(sx * sy, 2) + sx + sy + 4);
      Inc(a11, SarLongint(sy * sy, 2) + sy * 2 + 8);
      Inc(bx0, SarLongint(sx * dx, 2) + sx + dx + 8);
      Inc(bx1, SarLongint(sy * dx, 2) + sy + dx + 4);
      Inc(by0, SarLongint(sx * dy, 2) + sx + dy + 4);
      Inc(by1, SarLongint(sy * dy, 2) + sy + dy + 8);
    end;
  end;
  det := Int64(a00) * a11 - Int64(a01) * a01;
  if det = 0 then Exit(True);
  idet := ApplySign64(ResolveDivisor64(UInt64(Abs(det)), shift), det);
  Dec(shift, 16);
  if shift < 0 then
  begin
    idet := idet shl (-shift);
    shift := 0;
  end;
  Wm.Matrix[2] := GetMultShiftDiag(Int64(a11) * bx0 - Int64(a01) * bx1, idet, shift);
  Wm.Matrix[3] := GetMultShiftNdiag(Int64(a00) * bx1 - Int64(a01) * bx0, idet, shift);
  Wm.Matrix[4] := GetMultShiftNdiag(Int64(a11) * by0 - Int64(a01) * by1, idet, shift);
  Wm.Matrix[5] := GetMultShiftDiag(Int64(a00) * by1 - Int64(a01) * by0, idet, shift);
  Wm.Matrix[0] := IClip(MvX * $2000 - (isux * (Wm.Matrix[2] - $10000) + isuy * Wm.Matrix[3]),
                        -$800000, $7fffff);
  Wm.Matrix[1] := IClip(MvY * $2000 - (isux * Wm.Matrix[4] + isuy * (Wm.Matrix[5] - $10000)),
                        -$800000, $7fffff);
  Result := False;
end;

end.
