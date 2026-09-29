{$mode delphi}
unit jxl_render;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// Frame rendering stages, ported from libjxl 0.11.2 render_pipeline/
// (stage_chroma_upsampling, stage_gaborish, stage_epf, stage_upsampling,
// stage_ycbcr, stage_xyb) and epf.cc. Every stage works on whole planes;
// pixels outside a plane are mirrored at its edge, as the libjxl pipeline
// does before each stage.

interface

uses
  SysUtils, Math, jxl_types, jxl_color;

type
  TPlanes3 = array[0..2] of TFloat32Plane;

  TLoopFilterParams = record
    Gab: Boolean;
    GabW: array[0..2, 0..1] of Single;   // weight1, weight2 per channel
    EpfIters: Integer;
    EpfSharpLut: array[0..7] of Single;
    EpfChannelScale: array[0..2] of Single;
    EpfPass1Zeroflush, EpfPass2Zeroflush: Single;
    EpfQuantMul, EpfPass0SigmaScale, EpfPass2SigmaScale: Single;
    EpfBorderSadMul, EpfSigmaForModular: Single;
  end;

const
  kInvSigmaNum = -1.1715728752538099024;
  kMinSigma = -3.90524291751269967465540850526868;

procedure SetDefaultLoopFilter(var lf: TLoopFilterParams);

// Mirror an out-of-range coordinate into [0, size) (image_ops.h Mirror).
function Mirror(x, size: Integer): Integer; inline;

// Chroma upsampling (stage_chroma_upsampling): doubles the width (height)
// of a plane with 3/4, 1/4 weights; the result is cropped to outW (outH).
procedure ChromaUpsampleH(var p: TFloat32Plane; outW: Integer);
procedure ChromaUpsampleV(var p: TFloat32Plane; outH: Integer);

procedure Gaborish(var planes: TPlanes3; const lf: TLoopFilterParams);

// EPF: invSigma holds 1/sigma per 8x8 block (sigmaW blocks per row).
procedure EPFStage(stage: Integer; var planes: TPlanes3;
                   const invSigma: array of Single; sigmaW: Integer;
                   const lf: TLoopFilterParams);

// Non-separable upsampling by 2^shift (stage_upsampling); the result is
// cropped to outW x outH.
procedure Upsample(var p: TFloat32Plane; shift: Integer;
                   const md: TJxlImageMetadata; outW, outH: Integer);

// YCbCr (Cb, Y, Cr planes, full-range BT.601) -> RGB, in place.
procedure YCbCrToRGB(var planes: TPlanes3);

// XYB -> linear sRGB (with the image's opsin matrix and intensity target)
// -> sRGB-encoded, in place.
procedure XYBToSRGB(var planes: TPlanes3; const md: TJxlImageMetadata);

implementation

procedure SetDefaultLoopFilter(var lf: TLoopFilterParams);
var i: Integer;
begin
  lf.Gab := True;
  for i := 0 to 2 do
  begin
    lf.GabW[i][0] := 1.1 * 0.104699568;
    lf.GabW[i][1] := 1.1 * 0.055680538;
  end;
  lf.EpfIters := 2;
  for i := 0 to 7 do lf.EpfSharpLut[i] := i / 7.0;
  lf.EpfChannelScale[0] := 40.0;
  lf.EpfChannelScale[1] := 5.0;
  lf.EpfChannelScale[2] := 3.5;
  lf.EpfPass1Zeroflush := 0.45;
  lf.EpfPass2Zeroflush := 0.6;
  lf.EpfQuantMul := 0.46;
  lf.EpfPass0SigmaScale := 0.9;
  lf.EpfPass2SigmaScale := 6.5;
  lf.EpfBorderSadMul := 0.6666666666666666;
  lf.EpfSigmaForModular := 1.0;
end;

function Mirror(x, size: Integer): Integer;
var v: Integer;
begin
  v := x;
  while (v < 0) or (v >= size) do
    if v < 0 then v := -v - 1
    else v := 2 * size - 1 - v;
  Result := v;
end;

// ---------------------------------------------------------------------------
// Chroma upsampling
// ---------------------------------------------------------------------------
procedure ChromaUpsampleH(var p: TFloat32Plane; outW: Integer);
var
  o: TFloat32Plane;
  x, y, w, ox: Integer;
  cur, prev, next: Single;
  src: PSingle;
begin
  w := p.Width;
  InitFloat32Plane(o, outW, p.Height);
  for y := 0 to p.Height - 1 do
  begin
    src := @p.Data[y * p.Stride];
    for x := 0 to w - 1 do
    begin
      cur := src[x] * 0.75;
      prev := src[Mirror(x - 1, w)];
      next := src[Mirror(x + 1, w)];
      ox := 2 * x;
      if ox < outW then o.Data[y * outW + ox] := 0.25 * prev + cur;
      if ox + 1 < outW then o.Data[y * outW + ox + 1] := 0.25 * next + cur;
    end;
  end;
  p := o;
end;

procedure ChromaUpsampleV(var p: TFloat32Plane; outH: Integer);
var
  o: TFloat32Plane;
  x, y, h, w: Integer;
  t, m, b: PSingle;
begin
  h := p.Height; w := p.Width;
  InitFloat32Plane(o, w, outH);
  for y := 0 to h - 1 do
  begin
    t := @p.Data[Mirror(y - 1, h) * p.Stride];
    m := @p.Data[y * p.Stride];
    b := @p.Data[Mirror(y + 1, h) * p.Stride];
    for x := 0 to w - 1 do
    begin
      if 2 * y < outH then o.Data[2 * y * w + x] := t[x] * 0.25 + m[x] * 0.75;
      if 2 * y + 1 < outH then o.Data[(2 * y + 1) * w + x] := b[x] * 0.25 + m[x] * 0.75;
    end;
  end;
  p := o;
end;

// ---------------------------------------------------------------------------
// Gaborish
// ---------------------------------------------------------------------------
procedure Gaborish(var planes: TPlanes3; const lf: TLoopFilterParams);
var
  c, x, y, w, h: Integer;
  w0, w1, w2, d: Single;
  src: array of Single;
  xm, xp, ym, yp: Integer;
begin
  for c := 0 to 2 do
  begin
    w := planes[c].Width; h := planes[c].Height;
    if (w = 0) or (h = 0) then Continue;
    d := 1.0 + 4.0 * (lf.GabW[c][0] + lf.GabW[c][1]);
    w0 := 1.0 / d;
    w1 := lf.GabW[c][0] / d;
    w2 := lf.GabW[c][1] / d;
    SetLength(src, w * h);
    Move(planes[c].Data[0], src[0], w * h * SizeOf(Single));
    for y := 0 to h - 1 do
    begin
      ym := Mirror(y - 1, h) * w; yp := Mirror(y + 1, h) * w;
      for x := 0 to w - 1 do
      begin
        xm := Mirror(x - 1, w); xp := Mirror(x + 1, w);
        planes[c].Data[y * w + x] :=
          src[y * w + x] * w0 +
          (src[y * w + xm] + src[y * w + xp] + src[ym + x] + src[yp + x]) * w1 +
          (src[ym + xm] + src[ym + xp] + src[yp + xm] + src[yp + xp]) * w2;
      end;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// EPF (stage_epf.cc)
// ---------------------------------------------------------------------------
procedure EPFStage(stage: Integer; var planes: TPlanes3;
                   const invSigma: array of Single; sigmaW: Integer;
                   const lf: TLoopFilterParams);
const
  // EPF0: 12 neighbours
  kOff0: array[0..11, 0..1] of Integer = ((-2, 0), (-1, -1), (-1, 0), (-1, 1),
    (0, -2), (0, -1), (0, 1), (0, 2), (1, -1), (1, 0), (1, 1), (2, 0));
  kPlus: array[0..4, 0..1] of Integer = ((0, 0), (-1, 0), (0, -1), (1, 0), (0, 1));
  // EPF1 / EPF2: 4 neighbours
  kOff1: array[0..3, 0..1] of Integer = ((-1, 0), (0, -1), (0, 1), (1, 0));
var
  src: array[0..2] of array of Single;
  w, h, c, x, y, i, k: Integer;
  sm, bsm, sig, sad, weight, wsum, s: Single;
  smRow: array[0..7] of Single;
  vals: array[0..2] of Single;

  function P(cc, yy, xx: Integer): Single; inline;
  begin
    Result := src[cc][Mirror(yy, h) * w + Mirror(xx, w)];
  end;

begin
  w := planes[0].Width; h := planes[0].Height;
  if (w = 0) or (h = 0) then Exit;
  for c := 0 to 2 do
  begin
    SetLength(src[c], w * h);
    Move(planes[c].Data[0], src[c][0], w * h * SizeOf(Single));
  end;
  case stage of
    0: sm := lf.EpfPass0SigmaScale * 1.65;
    1: sm := 1.65;
  else sm := lf.EpfPass2SigmaScale * 1.65;
  end;
  bsm := sm * lf.EpfBorderSadMul;
  for y := 0 to h - 1 do
  begin
    // border rows of a block use the border multiplier everywhere
    for i := 0 to 7 do
      if ((y mod 8) = 0) or ((y mod 8) = 7) or (i = 0) or (i = 7) then
        smRow[i] := bsm
      else
        smRow[i] := sm;
    for x := 0 to w - 1 do
    begin
      sig := invSigma[(y div 8) * sigmaW + (x div 8)];
      if sig < kMinSigma then Continue;     // pixel unchanged
      sig := sig * smRow[x mod 8];
      for c := 0 to 2 do vals[c] := src[c][y * w + x];
      wsum := 1.0;
      case stage of
        0:
          for i := 0 to 11 do
          begin
            sad := 0;
            for c := 0 to 2 do
            begin
              s := 0;
              for k := 0 to 4 do
                s := s + Abs(P(c, y + kPlus[k][0], x + kPlus[k][1]) -
                             P(c, y + kOff0[i][0] + kPlus[k][0],
                                  x + kOff0[i][1] + kPlus[k][1]));
              sad := sad + s * lf.EpfChannelScale[c];
            end;
            weight := sad * sig + 1.0;
            if weight < 0 then weight := 0;
            wsum := wsum + weight;
            for c := 0 to 2 do
              vals[c] := vals[c] + weight * P(c, y + kOff0[i][0], x + kOff0[i][1]);
          end;
        1:
          for i := 0 to 3 do
          begin
            // SAD over the plus shape around the pixel and around the neighbour
            sad := 0;
            for c := 0 to 2 do
            begin
              s := 0;
              for k := 0 to 4 do
                s := s + Abs(P(c, y + kPlus[k][0], x + kPlus[k][1]) -
                             P(c, y + kOff1[i][0] + kPlus[k][0],
                                  x + kOff1[i][1] + kPlus[k][1]));
              sad := sad + s * lf.EpfChannelScale[c];
            end;
            weight := sad * sig + 1.0;
            if weight < 0 then weight := 0;
            wsum := wsum + weight;
            for c := 0 to 2 do
              vals[c] := vals[c] + weight * P(c, y + kOff1[i][0], x + kOff1[i][1]);
          end;
      else
        for i := 0 to 3 do
        begin
          sad := 0;
          for c := 0 to 2 do
            sad := sad + Abs(P(c, y + kOff1[i][0], x + kOff1[i][1]) -
                             src[c][y * w + x]) * lf.EpfChannelScale[c];
          weight := sad * sig + 1.0;
          if weight < 0 then weight := 0;
          wsum := wsum + weight;
          for c := 0 to 2 do
            vals[c] := vals[c] + weight * P(c, y + kOff1[i][0], x + kOff1[i][1]);
        end;
      end;
      for c := 0 to 2 do
        planes[c].Data[y * w + x] := vals[c] / wsum;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Upsampling
// ---------------------------------------------------------------------------
procedure Upsample(var p: TFloat32Plane; shift: Integer;
                   const md: TJxlImageMetadata; outW, outH: Integer);
var
  kernel: array[0..3, 0..3, 0..4, 0..4] of Single;
  N, NK, i, j, yy, xx, x, y, ox, oy, ix, iy, w, h, a, b, ky, kx: Integer;
  wt: PSingle;
  o: TFloat32Plane;
  sum, v, mn, mx, kv: Single;
begin
  w := p.Width; h := p.Height;
  case shift of
    1: wt := @md.Ups2Weights[0];
    2: wt := @md.Ups4Weights[0];
  else wt := @md.Ups8Weights[0];
  end;
  NK := 1 shl (shift - 1);
  for i := 0 to 5 * NK - 1 do
    for j := 0 to 5 * NK - 1 do
    begin
      yy := Min(i, j); xx := Max(i, j);
      kernel[j div 5][i div 5][j mod 5][i mod 5] :=
        wt[5 * NK * yy - yy * (yy - 1) div 2 + xx - yy];
    end;
  N := 1 shl shift;
  InitFloat32Plane(o, outW, outH);
  for y := 0 to h - 1 do
    for x := 0 to w - 1 do
    begin
      mn := p.Data[y * p.Stride + x]; mx := mn;
      for iy := -2 to 2 do
        for ix := -2 to 2 do
        begin
          v := p.Data[Mirror(y + iy, h) * p.Stride + Mirror(x + ix, w)];
          if v < mn then mn := v;
          if v > mx then mx := v;
        end;
      for oy := 0 to N - 1 do
      begin
        if y * N + oy >= outH then Break;
        for ox := 0 to N - 1 do
        begin
          if x * N + ox >= outW then Break;
          sum := 0;
          for iy := -2 to 2 do
            for ix := -2 to 2 do
            begin
              case N of
                2: begin
                     a := 0; b := 0;
                     if (oy mod 2) <> 0 then ky := 4 - (iy + 2) else ky := iy + 2;
                     if (ox mod 2) <> 0 then kx := 4 - (ix + 2) else kx := ix + 2;
                   end;
                4: begin
                     if (oy mod 4) < 2 then begin a := oy mod 2; ky := iy + 2; end
                     else begin a := 1 - oy mod 2; ky := 4 - (iy + 2); end;
                     if (ox mod 4) < 2 then begin b := ox mod 2; kx := ix + 2; end
                     else begin b := 1 - ox mod 2; kx := 4 - (ix + 2); end;
                   end;
              else begin
                     if (oy mod 8) < 4 then begin a := oy mod 4; ky := iy + 2; end
                     else begin a := 3 - oy mod 4; ky := 4 - (iy + 2); end;
                     if (ox mod 8) < 4 then begin b := ox mod 4; kx := ix + 2; end
                     else begin b := 3 - ox mod 4; kx := 4 - (ix + 2); end;
                   end;
              end;
              kv := kernel[a][b][ky][kx];
              sum := sum + kv * p.Data[Mirror(y + iy, h) * p.Stride + Mirror(x + ix, w)];
            end;
          if sum < mn then sum := mn else if sum > mx then sum := mx;
          o.Data[(y * N + oy) * outW + x * N + ox] := sum;
        end;
      end;
    end;
  p := o;
end;

// ---------------------------------------------------------------------------
// Colour transforms
// ---------------------------------------------------------------------------
procedure YCbCrToRGB(var planes: TPlanes3);
const
  c128 = 128.0 / 255;
  crcr = 1.402;
  cgcb = -0.114 * 1.772 / 0.587;
  cgcr = -0.299 * 1.402 / 0.587;
  cbcb = 1.772;
var
  i, n: Integer;
  yv, cb, cr: Single;
begin
  n := planes[1].Width * planes[1].Height;
  for i := 0 to n - 1 do
  begin
    yv := planes[1].Data[i] + c128;
    cb := planes[0].Data[i];
    cr := planes[2].Data[i];
    planes[0].Data[i] := crcr * cr + yv;
    planes[1].Data[i] := cgcr * cr + (cgcb * cb + yv);
    planes[2].Data[i] := cbcb * cb + yv;
  end;
end;

type
  TMat3 = array[0..2, 0..2] of Double;

function Mul3(const a, b: TMat3): TMat3;
var i, j, k: Integer;
begin
  for i := 0 to 2 do
    for j := 0 to 2 do
    begin
      Result[i][j] := 0;
      for k := 0 to 2 do Result[i][j] := Result[i][j] + a[i][k] * b[k][j];
    end;
end;

function Inv3(const m: TMat3): TMat3;
var det: Double;
begin
  det := m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
         m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
         m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
  if Abs(det) < 1e-12 then raise EJxlError.Create('Singular colour matrix');
  det := 1 / det;
  Result[0][0] := (m[1][1] * m[2][2] - m[1][2] * m[2][1]) * det;
  Result[0][1] := (m[0][2] * m[2][1] - m[0][1] * m[2][2]) * det;
  Result[0][2] := (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * det;
  Result[1][0] := (m[1][2] * m[2][0] - m[1][0] * m[2][2]) * det;
  Result[1][1] := (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * det;
  Result[1][2] := (m[0][2] * m[1][0] - m[0][0] * m[1][2]) * det;
  Result[2][0] := (m[1][0] * m[2][1] - m[1][1] * m[2][0]) * det;
  Result[2][1] := (m[0][1] * m[2][0] - m[0][0] * m[2][1]) * det;
  Result[2][2] := (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * det;
end;

// cms: PrimariesToXYZ
function PrimariesToXYZ(rx, ry, gx, gy, bx, by, wx, wy: Double): TMat3;
var
  p, pinv: TMat3;
  w, sv: array[0..2] of Double;
  i, j: Integer;
begin
  p[0][0] := rx; p[0][1] := gx; p[0][2] := bx;
  p[1][0] := ry; p[1][1] := gy; p[1][2] := by;
  p[2][0] := 1 - rx - ry; p[2][1] := 1 - gx - gy; p[2][2] := 1 - bx - by;
  pinv := Inv3(p);
  w[0] := wx / wy; w[1] := 1; w[2] := (1 - wx - wy) / wy;
  for i := 0 to 2 do
    sv[i] := pinv[i][0] * w[0] + pinv[i][1] * w[1] + pinv[i][2] * w[2];
  for i := 0 to 2 do
    for j := 0 to 2 do
      Result[i][j] := p[i][j] * sv[j];
end;

// cms: AdaptToXYZD50 (Bradford)
function AdaptToXYZD50(wx, wy: Double): TMat3;
const
  kB: TMat3 = ((0.8951, 0.2664, -0.1614), (-0.7502, 1.7135, 0.0367),
               (0.0389, -0.0685, 1.0296));
var
  w, w50, lms, lms50: array[0..2] of Double;
  a: TMat3;
  i: Integer;
begin
  w[0] := wx / wy; w[1] := 1; w[2] := (1 - wx - wy) / wy;
  w50[0] := 0.96422; w50[1] := 1; w50[2] := 0.82521;
  for i := 0 to 2 do
  begin
    lms[i] := kB[i][0] * w[0] + kB[i][1] * w[1] + kB[i][2] * w[2];
    lms50[i] := kB[i][0] * w50[0] + kB[i][1] * w50[1] + kB[i][2] * w50[2];
  end;
  FillChar(a, SizeOf(a), 0);
  for i := 0 to 2 do a[i][i] := lms50[i] / lms[i];
  Result := Mul3(Inv3(kB), Mul3(a, kB));
end;

procedure GetPrimaries(const ce: TJxlColorEncoding; out rx, ry, gx, gy, bx, by: Double);
begin
  case ce.Primaries of
    jpCustom:
      begin
        rx := ce.PrimRX; ry := ce.PrimRY; gx := ce.PrimGX; gy := ce.PrimGY;
        bx := ce.PrimBX; by := ce.PrimBY;
      end;
    jpP3D65:
      begin
        rx := 0.680; ry := 0.320; gx := 0.265; gy := 0.690; bx := 0.150; by := 0.060;
      end;
    jp2100:
      begin
        rx := 0.708; ry := 0.292; gx := 0.170; gy := 0.797; bx := 0.131; by := 0.046;
      end;
  else
    begin
      rx := 0.639998686; ry := 0.330010138; gx := 0.300003784; gy := 0.600003357;
      bx := 0.150002046; by := 0.059997204;
    end;
  end;
end;

procedure GetWhitePoint(const ce: TJxlColorEncoding; out wx, wy: Double);
begin
  case ce.WhitePoint of
    jwpCustom: begin wx := ce.WhiteCustomX; wy := ce.WhiteCustomY; end;
    jwpE: begin wx := 1 / 3; wy := 1 / 3; end;
    jwpDCI: begin wx := 0.314; wy := 0.351; end;
  else begin wx := 0.3127; wy := 0.3290; end;
  end;
end;

// Encodes a linear sample with the output transfer function
// (render_pipeline/stage_from_linear.cc).
function FromLinear(v: Single; tf: TJxlTransferFunction; gamma, intensity: Double): Single;
var a: Single;
begin
  case tf of
    jtfLinear: Result := v;
    jtfGamma:
      if (v <= 0) or (gamma <= 0) then Result := 0
      else Result := Power(v, 1 / gamma);
    jtfDCI:
      if v <= 0 then Result := 0
      else Result := Power(v, 1 / 2.6);
    jtf709:
      begin
        a := Abs(v);
        if a < 0.018 then Result := 4.5 * a
        else Result := 1.099 * Power(a, 0.45) - 0.099;
        if v < 0 then Result := -Result;
      end;
    jtfPQ: Result := LinearToPQ(v * intensity);
    jtfHLG:
      if v <= 0 then Result := 0 else Result := LinearToHLG(v);
  else
    begin
      a := Abs(v);
      if a <= 0.0031308 then Result := a * 12.92
      else Result := 1.055 * Power(a, 1 / 2.4) - 0.055;
      if v < 0 then Result := -Result;
    end;
  end;
end;

// XYB -> linear (dec_xyb.cc OutputEncodingInfo, stage_xyb.cc) -> output
// encoding. The output encoding is the image's own when it is not an ICC
// profile, otherwise sRGB. Grey images use the luminance row for R, G, B.
procedure XYBToSRGB(var planes: TPlanes3; const md: TJxlImageMetadata);
var
  i, j, n: Integer;
  m, s2x, x2o, lum: TMat3;
  mf: array[0..8] of Single;
  cbrtBias: array[0..2] of Single;
  scale: Double;
  gr, gg, gb, lr, lg, lb, xv, yv, bv: Single;
  rx, ry, gx, gy, bx, by, wx, wy: Double;
  ce: TJxlColorEncoding;
  isGray: Boolean;
  tf: TJxlTransferFunction;

  function Cbrt(v: Double): Double;
  begin
    if v < 0 then Result := -Power(-v, 1.0 / 3.0)
    else Result := Power(v, 1.0 / 3.0);
  end;

begin
  ce := md.ColorEncoding;
  isGray := ce.ColorSpace = jcsGray;
  tf := ce.TransferFn;
  if ce.WantICC or (ce.ColorSpace = jcsUnknown) or (ce.ColorSpace = jcsXYB) then
  begin
    tf := jtfSRGB;
    ce.Primaries := jpSRGB;
    ce.WhitePoint := jwpD65;
  end;
  for i := 0 to 2 do
    for j := 0 to 2 do
      m[i][j] := md.OpsinInverse[i * 3 + j];
  if (not isGray) and ((ce.Primaries <> jpSRGB) or (ce.WhitePoint <> jwpD65)) then
  begin
    GetPrimaries(ce, rx, ry, gx, gy, bx, by);
    GetWhitePoint(ce, wx, wy);
    // linear sRGB -> XYZ D50 -> the original primaries
    s2x := Mul3(AdaptToXYZD50(0.3127, 0.3290),
                PrimariesToXYZ(0.639998686, 0.330010138, 0.300003784, 0.600003357,
                               0.150002046, 0.059997204, 0.3127, 0.3290));
    x2o := Inv3(Mul3(AdaptToXYZD50(wx, wy), PrimariesToXYZ(rx, ry, gx, gy, bx, by, wx, wy)));
    m := Mul3(Mul3(x2o, s2x), m);
  end;
  if isGray then
  begin
    for i := 0 to 2 do
    begin
      lum[i][0] := 0.2126; lum[i][1] := 0.7152; lum[i][2] := 0.0722;
    end;
    m := Mul3(lum, m);
  end;
  if md.IntensityTarget > 0 then scale := 255.0 / md.IntensityTarget
  else scale := 1.0;
  for i := 0 to 2 do
    for j := 0 to 2 do
      mf[i * 3 + j] := m[i][j] * scale;
  for i := 0 to 2 do cbrtBias[i] := Cbrt(md.OpsinBias[i]);
  n := planes[0].Width * planes[0].Height;
  for i := 0 to n - 1 do
  begin
    xv := planes[0].Data[i]; yv := planes[1].Data[i]; bv := planes[2].Data[i];
    gr := yv + xv - cbrtBias[0];
    gg := yv - xv - cbrtBias[1];
    gb := bv - cbrtBias[2];
    gr := gr * gr * gr + md.OpsinBias[0];
    gg := gg * gg * gg + md.OpsinBias[1];
    gb := gb * gb * gb + md.OpsinBias[2];
    lr := mf[0] * gr + mf[1] * gg + mf[2] * gb;
    lg := mf[3] * gr + mf[4] * gg + mf[5] * gb;
    lb := mf[6] * gr + mf[7] * gg + mf[8] * gb;
    planes[0].Data[i] := FromLinear(lr, tf, ce.Gamma, md.IntensityTarget);
    planes[1].Data[i] := FromLinear(lg, tf, ce.Gamma, md.IntensityTarget);
    planes[2].Data[i] := FromLinear(lb, tf, ce.Gamma, md.IntensityTarget);
  end;
end;

end.
