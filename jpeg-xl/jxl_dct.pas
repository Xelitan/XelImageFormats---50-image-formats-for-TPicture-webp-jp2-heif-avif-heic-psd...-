{$mode delphi}
unit jxl_dct;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// VarDCT block transforms, ported from libjxl 0.11.2 (dct-inl.h,
// dct_scales.h, dec_transforms-inl.h, ac_strategy.cc):
//   * the scaled (I)DCT used for every block size (the recursive radix-2
//     algorithm of Perera and Liu, so the scaling matches libjxl exactly;
//     blocks taller than wide keep their coefficients transposed),
//   * the 8x8 special transforms (identity, DCT2x2, DCT4x4, DCT4x8/8x4, AFV),
//   * the lowest frequencies of large blocks computed from the DC image,
//   * the natural coefficient order of each strategy.

interface

const
  kNumAcStrategies = 27;

  ACS_DCT        = 0;
  ACS_IDENTITY   = 1;
  ACS_DCT2X2     = 2;
  ACS_DCT4X4     = 3;
  ACS_DCT16X16   = 4;
  ACS_DCT32X32   = 5;
  ACS_DCT16X8    = 6;
  ACS_DCT8X16    = 7;
  ACS_DCT32X8    = 8;
  ACS_DCT8X32    = 9;
  ACS_DCT32X16   = 10;
  ACS_DCT16X32   = 11;
  ACS_DCT4X8     = 12;
  ACS_DCT8X4     = 13;
  ACS_AFV0       = 14;
  ACS_AFV1       = 15;
  ACS_AFV2       = 16;
  ACS_AFV3       = 17;
  ACS_DCT64X64   = 18;
  ACS_DCT64X32   = 19;
  ACS_DCT32X64   = 20;
  ACS_DCT128X128 = 21;
  ACS_DCT128X64  = 22;
  ACS_DCT64X128  = 23;
  ACS_DCT256X256 = 24;
  ACS_DCT256X128 = 25;
  ACS_DCT128X256 = 26;

  // Blocks covered by each strategy (names are ROWSxCOLS).
  kAcsCoveredX: array[0..26] of Byte = (1, 1, 1, 1, 2, 4, 1, 2, 1, 4, 2, 4,
    1, 1, 1, 1, 1, 1, 8, 4, 8, 16, 8, 16, 32, 16, 32);
  kAcsCoveredY: array[0..26] of Byte = (1, 1, 1, 1, 2, 4, 2, 1, 4, 1, 4, 2,
    1, 1, 1, 1, 1, 1, 8, 8, 4, 16, 16, 8, 32, 32, 16);
  kAcsLog2Covered: array[0..26] of Byte = (0, 0, 0, 0, 2, 4, 1, 1, 2, 2, 3, 3,
    0, 0, 0, 0, 0, 0, 6, 5, 5, 8, 7, 7, 10, 9, 9);

  // coeff_order.h: strategy -> order bucket, and the bucket offsets (x64)
  kStrategyOrder: array[0..26] of Byte = (0, 1, 1, 1, 2, 3, 4, 4, 5, 5, 6, 6,
    1, 1, 1, 1, 1, 1, 7, 8, 8, 9, 10, 10, 11, 12, 12);
  kCoeffOrderOffset: array[0..39] of Integer = (
    0,    1,    2,    3,    4,    5,    6,    10,   14,   18,
    34,   50,   66,   68,   70,   72,   76,   80,   84,   92,
    100,  108,  172,  236,  300,  332,  364,  396,  652,  908,
    1164, 1292, 1420, 1548, 2572, 3596, 4620, 5132, 5644, 6156);
  kCoeffOrderLimit = 6156;

  // quant_weights.h: strategy -> quantization table kind
  kAcsToQuantTable: array[0..26] of Byte = (0, 1, 2, 3, 4, 5, 6, 6, 7, 7, 8, 8,
    9, 9, 10, 10, 10, 10, 11, 12, 12, 13, 14, 14, 15, 16, 16);

// Pixels of one block from its (dequantized) coefficients. coeffs is the
// strategy's coefficient array (it may be used as scratch); pixels are written
// with the given row stride.
procedure TransformToPixels(strategy: Integer; coeffs: PSingle;
                            pixels: PSingle; stride: Integer);

// The lowest-frequency coefficients of a block from the DC image (one value
// per 8x8 block, dc points at the block's top-left DC sample).
procedure LowestFrequenciesFromDC(strategy: Integer; dc: PSingle;
                                  dcStride: Integer; llf: PSingle);

// The natural coefficient order of a strategy (ac_strategy.cc).
procedure ComputeNaturalCoeffOrder(strategy: Integer; order: PCardinal);

// Scaled 2-D DCT / IDCT of a rows x cols block, as libjxl's
// ComputeScaledDCT / ComputeScaledIDCT: when rows >= cols the coefficient
// array is stored transposed (cols rows of rows values).
procedure ComputeScaledDCT(rows, cols: Integer; from: PSingle;
                           fromStride: Integer; outCoeffs: PSingle);
procedure ComputeScaledIDCT(rows, cols: Integer; coeffs: PSingle;
                            pixels: PSingle; stride: Integer);

implementation

uses Math;

const
  kSqrt2 = 1.41421356237309504880;

var
  // WcMultipliers<N>[i] = 1 / (2 cos((2i+1) pi / (2N))), N = 4..256
  Wc: array[2..8] of array of Single;   // index = log2(N)
  WcReady: Boolean = False;

procedure InitWc;
var l, n, i: Integer;
begin
  if WcReady then Exit;
  for l := 2 to 8 do
  begin
    n := 1 shl l;
    SetLength(Wc[l], n div 2);
    for i := 0 to n div 2 - 1 do
      Wc[l][i] := 1.0 / (2.0 * Cos((2 * i + 1) * Pi / (2.0 * n)));
  end;
  WcReady := True;
end;

function Log2Of(n: Integer): Integer; inline;
begin
  Result := 0;
  while (1 shl Result) < n do Inc(Result);
end;

// ---------------------------------------------------------------------------
// 1-D transforms (dct-inl.h). tmp needs 2*n floats.
// ---------------------------------------------------------------------------
type
  TSingleArr = array[0..MaxInt div SizeOf(Single) - 1] of Single;
  PSingleArr = ^TSingleArr;

procedure IDCT1D(n: Integer; from: PSingleArr; fromStride: Integer;
                 dst: PSingleArr; dstStride: Integer; tmp: PSingleArr);
var
  i, h: Integer;
  a, b, m: Single;
  w: array of Single;
  t: PSingleArr;
begin
  if n = 1 then
  begin
    dst[0] := from[0];
    Exit;
  end;
  if n = 2 then
  begin
    a := from[0]; b := from[fromStride];
    dst[0] := a + b;
    dst[dstStride] := a - b;
    Exit;
  end;
  h := n div 2;
  // ForwardEvenOdd
  for i := 0 to h - 1 do tmp[i] := from[2 * i * fromStride];
  for i := h to n - 1 do tmp[i] := from[(2 * (i - h) + 1) * fromStride];
  IDCT1D(h, tmp, 1, tmp, 1, @tmp[n]);
  // BTranspose on the odd half
  t := @tmp[h];
  for i := h - 1 downto 1 do t[i] := t[i] + t[i - 1];
  t[0] := t[0] * kSqrt2;
  IDCT1D(h, t, 1, t, 1, @tmp[n]);
  // MultiplyAndAdd
  w := Wc[Log2Of(n)];
  for i := 0 to h - 1 do
  begin
    m := w[i];
    a := tmp[i]; b := tmp[h + i];
    dst[i * dstStride] := a + m * b;
    dst[(n - i - 1) * dstStride] := a - m * b;
  end;
end;

// In-place forward DCT of n values (unscaled; callers scale by 1/n).
procedure DCT1D(n: Integer; mem: PSingleArr; tmp: PSingleArr);
var
  i, h: Integer;
  a, b: Single;
  w: array of Single;
  t: PSingleArr;
begin
  if n = 1 then Exit;
  if n = 2 then
  begin
    a := mem[0]; b := mem[1];
    mem[0] := a + b;
    mem[1] := a - b;
    Exit;
  end;
  h := n div 2;
  for i := 0 to h - 1 do tmp[i] := mem[i] + mem[n - 1 - i];   // AddReverse
  DCT1D(h, tmp, @tmp[n]);
  w := Wc[Log2Of(n)];
  for i := 0 to h - 1 do                                        // SubReverse
    tmp[h + i] := (mem[i] - mem[n - 1 - i]) * w[i];             // + Multiply
  t := @tmp[h];
  DCT1D(h, t, @tmp[n]);
  // B on the odd half
  t[0] := t[0] * kSqrt2 + t[1];
  for i := 1 to h - 2 do t[i] := t[i] + t[i + 1];
  // InverseEvenOdd
  for i := 0 to h - 1 do
  begin
    mem[2 * i] := tmp[i];
    mem[2 * i + 1] := tmp[h + i];
  end;
end;

// ---------------------------------------------------------------------------
// 2-D scaled transforms
// ---------------------------------------------------------------------------

// For each of m columns: a length-n DCT down the column (stride = stride),
// scaled by 1/n.
procedure DCTColumns(n, m: Integer; src: PSingleArr; srcStride: Integer;
                     dst: PSingleArr; dstStride: Integer);
var
  col, r: Integer;
  buf, tmp: array of Single;
  inv: Single;
begin
  SetLength(buf, n);
  SetLength(tmp, 2 * n + 2);
  inv := 1.0 / n;
  for col := 0 to m - 1 do
  begin
    for r := 0 to n - 1 do buf[r] := src[r * srcStride + col];
    DCT1D(n, PSingleArr(@buf[0]), PSingleArr(@tmp[0]));
    for r := 0 to n - 1 do dst[r * dstStride + col] := buf[r] * inv;
  end;
end;

procedure IDCTColumns(n, m: Integer; src: PSingleArr; srcStride: Integer;
                      dst: PSingleArr; dstStride: Integer);
var
  col: Integer;
  tmp: array of Single;
begin
  SetLength(tmp, 2 * n + 2);
  for col := 0 to m - 1 do
    IDCT1D(n, PSingleArr(@src[col]), srcStride, PSingleArr(@dst[col]),
           dstStride, PSingleArr(@tmp[0]));
end;

procedure Transpose(rows, cols: Integer; src: PSingleArr; srcStride: Integer;
                    dst: PSingleArr; dstStride: Integer);
var r, c: Integer;
begin
  // dst (cols x rows) <- src (rows x cols)
  for r := 0 to rows - 1 do
    for c := 0 to cols - 1 do
      dst[c * dstStride + r] := src[r * srcStride + c];
end;

procedure ComputeScaledDCT(rows, cols: Integer; from: PSingle;
                           fromStride: Integer; outCoeffs: PSingle);
var
  block: array of Single;
  f, o, b: PSingleArr;
begin
  InitWc;
  SetLength(block, rows * cols);
  f := PSingleArr(from); o := PSingleArr(outCoeffs); b := PSingleArr(@block[0]);
  if rows < cols then
  begin
    DCTColumns(rows, cols, f, fromStride, b, cols);
    Transpose(rows, cols, b, cols, o, rows);
    DCTColumns(cols, rows, o, rows, b, rows);
    Transpose(cols, rows, b, rows, o, cols);
  end
  else
  begin
    DCTColumns(rows, cols, f, fromStride, o, cols);
    Transpose(rows, cols, o, cols, b, rows);
    DCTColumns(cols, rows, b, rows, o, rows);
  end;
end;

procedure ComputeScaledIDCT(rows, cols: Integer; coeffs: PSingle;
                            pixels: PSingle; stride: Integer);
var
  block: array of Single;
  f, p, b: PSingleArr;
begin
  InitWc;
  SetLength(block, rows * cols);
  f := PSingleArr(coeffs); p := PSingleArr(pixels); b := PSingleArr(@block[0]);
  if rows < cols then
  begin
    Transpose(rows, cols, f, cols, b, rows);
    IDCTColumns(cols, rows, b, rows, f, rows);
    Transpose(cols, rows, f, rows, b, cols);
    IDCTColumns(rows, cols, b, cols, p, stride);
  end
  else
  begin
    IDCTColumns(cols, rows, f, rows, b, rows);
    Transpose(cols, rows, b, rows, f, cols);
    IDCTColumns(rows, cols, f, cols, p, stride);
  end;
end;

// ---------------------------------------------------------------------------
// Special 8x8 transforms (dec_transforms-inl.h)
// ---------------------------------------------------------------------------
const
  k4x4AFVBasis: array[0..15, 0..15] of Single = (
    (0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25,
     0.25, 0.25, 0.25, 0.25),
    (0.876902929799142, 0.2206518106944235, -0.10140050393753763,
     -0.1014005039375375, 0.2206518106944236, -0.10140050393753777,
     -0.10140050393753772, -0.10140050393753763, -0.10140050393753758,
     -0.10140050393753769, -0.1014005039375375, -0.10140050393753768,
     -0.10140050393753768, -0.10140050393753759, -0.10140050393753763,
     -0.10140050393753741),
    (0.0, 0.0, 0.40670075830260755, 0.44444816619734445, 0.0, 0.0,
     0.19574399372042936, 0.2929100136981264, -0.40670075830260716,
     -0.19574399372042872, 0.0, 0.11379074460448091, -0.44444816619734384,
     -0.29291001369812636, -0.1137907446044814, 0.0),
    (0.0, 0.0, -0.21255748058288748, 0.3085497062849767, 0.0,
     0.4706702258572536, -0.1621205195722993, 0.0, -0.21255748058287047,
     -0.16212051957228327, -0.47067022585725277, -0.1464291867126764,
     0.3085497062849487, 0.0, -0.14642918671266536, 0.4251149611657548),
    (0.0, -0.7071067811865474, 0.0, 0.0, 0.7071067811865476, 0.0, 0.0, 0.0,
     0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0),
    (-0.4105377591765233, 0.6235485373547691, -0.06435071657946274,
     -0.06435071657946266, 0.6235485373547694, -0.06435071657946284,
     -0.0643507165794628, -0.06435071657946274, -0.06435071657946272,
     -0.06435071657946279, -0.06435071657946266, -0.06435071657946277,
     -0.06435071657946277, -0.06435071657946273, -0.06435071657946274,
     -0.0643507165794626),
    (0.0, 0.0, -0.4517556589999482, 0.15854503551840063, 0.0,
     -0.04038515160822202, 0.0074182263792423875, 0.39351034269210167,
     -0.45175565899994635, 0.007418226379244351, 0.1107416575309343,
     0.08298163094882051, 0.15854503551839705, 0.3935103426921022,
     0.0829816309488214, -0.45175565899994796),
    (0.0, 0.0, -0.304684750724869, 0.5112616136591823, 0.0, 0.0,
     -0.290480129728998, -0.06578701549142804, 0.304684750724884,
     0.2904801297290076, 0.0, -0.23889773523344604, -0.5112616136592012,
     0.06578701549142545, 0.23889773523345467, 0.0),
    (0.0, 0.0, 0.3017929516615495, 0.25792362796341184, 0.0,
     0.16272340142866204, 0.09520022653475037, 0.0, 0.3017929516615503,
     0.09520022653475055, -0.16272340142866173, -0.35312385449816297,
     0.25792362796341295, 0.0, -0.3531238544981624, -0.6035859033230976),
    (0.0, 0.0, 0.40824829046386274, 0.0, 0.0, 0.0, 0.0, -0.4082482904638628,
     -0.4082482904638635, 0.0, 0.0, -0.40824829046386296, 0.0,
     0.4082482904638634, 0.408248290463863, 0.0),
    (0.0, 0.0, 0.1747866975480809, 0.0812611176717539, 0.0, 0.0,
     -0.3675398009862027, -0.307882213957909, -0.17478669754808135,
     0.3675398009862011, 0.0, 0.4826689115059883, -0.08126111767175039,
     0.30788221395790305, -0.48266891150598584, 0.0),
    (0.0, 0.0, -0.21105601049335784, 0.18567180916109802, 0.0, 0.0,
     0.49215859013738733, -0.38525013709251915, 0.21105601049335806,
     -0.49215859013738905, 0.0, 0.17419412659916217, -0.18567180916109904,
     0.3852501370925211, -0.1741941265991621, 0.0),
    (0.0, 0.0, -0.14266084808807264, -0.3416446842253372, 0.0,
     0.7367497537172237, 0.24627107722075148, -0.08574019035519306,
     -0.14266084808807344, 0.24627107722075137, 0.14883399227113567,
     -0.04768680350229251, -0.3416446842253373, -0.08574019035519267,
     -0.047686803502292804, -0.14266084808807242),
    (0.0, 0.0, -0.13813540350758585, 0.3302282550303788, 0.0,
     0.08755115000587084, -0.07946706605909573, -0.4613374887461511,
     -0.13813540350758294, -0.07946706605910261, 0.49724647109535086,
     0.12538059448563663, 0.3302282550303805, -0.4613374887461554,
     0.12538059448564315, -0.13813540350758452),
    (0.0, 0.0, -0.17437602599651067, 0.0702790691196284, 0.0,
     -0.2921026642334881, 0.3623817333531167, 0.0, -0.1743760259965108,
     0.36238173335311646, 0.29210266423348785, -0.4326608024727445,
     0.07027906911962818, 0.0, -0.4326608024727457, 0.34875205199302267),
    (0.0, 0.0, 0.11354987314994337, -0.07417504595810355, 0.0,
     0.19402893032594343, -0.435190496523228, 0.21918684838857466,
     0.11354987314994257, -0.4351904965232251, 0.5550443808910661,
     -0.25468277124066463, -0.07417504595810233, 0.2191868483885728,
     -0.25468277124066413, 0.1135498731499429));

procedure IDCT2TopBlock(S: Integer; blk: PSingleArr);
var
  temp: array[0..63] of Single;
  y, x, h: Integer;
  c00, c01, c10, c11: Single;
begin
  h := S div 2;
  for y := 0 to h - 1 do
    for x := 0 to h - 1 do
    begin
      c00 := blk[y * 8 + x];
      c01 := blk[y * 8 + h + x];
      c10 := blk[(y + h) * 8 + x];
      c11 := blk[(y + h) * 8 + h + x];
      temp[y * 2 * 8 + x * 2] := c00 + c01 + c10 + c11;
      temp[y * 2 * 8 + x * 2 + 1] := c00 + c01 - c10 - c11;
      temp[(y * 2 + 1) * 8 + x * 2] := c00 - c01 + c10 - c11;
      temp[(y * 2 + 1) * 8 + x * 2 + 1] := c00 - c01 - c10 + c11;
    end;
  for y := 0 to S - 1 do
    for x := 0 to S - 1 do
      blk[y * 8 + x] := temp[y * 8 + x];
end;

procedure AFVTransformToPixels(kind: Integer; cf: PSingleArr;
                               px: PSingleArr; stride: Integer);
var
  afvX, afvY, iy, ix, i, j: Integer;
  dcs: array[0..2] of Single;
  coeff: array[0..15] of Single;
  blk: array[0..31] of Single;
  s: Single;
  p: PSingleArr;
begin
  afvX := kind and 1;
  afvY := kind div 2;
  dcs[0] := (cf[0] + cf[8] + cf[1]) * 4.0;
  dcs[1] := cf[0] + cf[8] - cf[1];
  dcs[2] := cf[0] - cf[8];
  // IAFV: (even, even) positions
  coeff[0] := dcs[0];
  for iy := 0 to 3 do
    for ix := 0 to 3 do
      if (ix <> 0) or (iy <> 0) then
        coeff[iy * 4 + ix] := cf[iy * 2 * 8 + ix * 2];
  for i := 0 to 15 do
  begin
    s := 0;
    for j := 0 to 15 do s := s + coeff[j] * k4x4AFVBasis[j][i];
    blk[i] := s;
  end;
  for iy := 0 to 3 do
    for ix := 0 to 3 do
    begin
      if afvY = 1 then i := 3 - iy else i := iy;
      if afvX = 1 then j := 3 - ix else j := ix;
      px[(iy + afvY * 4) * stride + afvX * 4 + ix] := blk[i * 4 + j];
    end;
  // IDCT4x4 in (odd, even) positions
  blk[0] := dcs[1];
  for iy := 0 to 3 do
    for ix := 0 to 3 do
      if (ix <> 0) or (iy <> 0) then
        blk[iy * 4 + ix] := cf[iy * 2 * 8 + ix * 2 + 1];
  if afvX = 1 then j := 0 else j := 4;
  p := @px[afvY * 4 * stride + j];
  ComputeScaledIDCT(4, 4, @blk[0], PSingle(p), stride);
  // IDCT4x8
  blk[0] := dcs[2];
  for iy := 0 to 3 do
    for ix := 0 to 7 do
      if (ix <> 0) or (iy <> 0) then
        blk[iy * 8 + ix] := cf[(1 + iy * 2) * 8 + ix];
  if afvY = 1 then i := 0 else i := 4;
  p := @px[i * stride];
  ComputeScaledIDCT(4, 8, @blk[0], PSingle(p), stride);
end;

procedure TransformToPixels(strategy: Integer; coeffs: PSingle;
                            pixels: PSingle; stride: Integer);
var
  cf, px: PSingleArr;
  dcs: array[0..3] of Single;
  blk: array[0..63] of Single;
  x, y, iy, ix: Integer;
  residual: Single;
  c: PSingleArr;
begin
  InitWc;
  cf := PSingleArr(coeffs);
  px := PSingleArr(pixels);
  case strategy of
    ACS_IDENTITY:
      begin
        dcs[0] := cf[0] + cf[1] + cf[8] + cf[9];
        dcs[1] := cf[0] + cf[1] - cf[8] - cf[9];
        dcs[2] := cf[0] - cf[1] + cf[8] - cf[9];
        dcs[3] := cf[0] - cf[1] - cf[8] + cf[9];
        for y := 0 to 1 do
          for x := 0 to 1 do
          begin
            residual := 0;
            for iy := 0 to 3 do
              for ix := 0 to 3 do
                if (ix <> 0) or (iy <> 0) then
                  residual := residual + cf[(y + iy * 2) * 8 + x + ix * 2];
            px[(4 * y + 1) * stride + 4 * x + 1] :=
              dcs[y * 2 + x] - residual * (1.0 / 16);
            for iy := 0 to 3 do
              for ix := 0 to 3 do
                if (ix <> 1) or (iy <> 1) then
                  px[(y * 4 + iy) * stride + x * 4 + ix] :=
                    cf[(y + iy * 2) * 8 + x + ix * 2] +
                    px[(4 * y + 1) * stride + 4 * x + 1];
            px[y * 4 * stride + x * 4] := cf[(y + 2) * 8 + x + 2] +
              px[(4 * y + 1) * stride + 4 * x + 1];
          end;
      end;
    ACS_DCT8X4:
      begin
        dcs[0] := cf[0] + cf[8];
        dcs[1] := cf[0] - cf[8];
        for x := 0 to 1 do
        begin
          blk[0] := dcs[x];
          for iy := 0 to 3 do
            for ix := 0 to 7 do
              if (ix <> 0) or (iy <> 0) then
                blk[iy * 8 + ix] := cf[(x + iy * 2) * 8 + ix];
          ComputeScaledIDCT(8, 4, @blk[0], PSingle(@px[x * 4]), stride);
        end;
      end;
    ACS_DCT4X8:
      begin
        dcs[0] := cf[0] + cf[8];
        dcs[1] := cf[0] - cf[8];
        for y := 0 to 1 do
        begin
          blk[0] := dcs[y];
          for iy := 0 to 3 do
            for ix := 0 to 7 do
              if (ix <> 0) or (iy <> 0) then
                blk[iy * 8 + ix] := cf[(y + iy * 2) * 8 + ix];
          ComputeScaledIDCT(4, 8, @blk[0], PSingle(@px[y * 4 * stride]), stride);
        end;
      end;
    ACS_DCT4X4:
      begin
        dcs[0] := cf[0] + cf[1] + cf[8] + cf[9];
        dcs[1] := cf[0] + cf[1] - cf[8] - cf[9];
        dcs[2] := cf[0] - cf[1] + cf[8] - cf[9];
        dcs[3] := cf[0] - cf[1] - cf[8] + cf[9];
        for y := 0 to 1 do
          for x := 0 to 1 do
          begin
            blk[0] := dcs[y * 2 + x];
            for iy := 0 to 3 do
              for ix := 0 to 3 do
                if (ix <> 0) or (iy <> 0) then
                  blk[iy * 4 + ix] := cf[(y + iy * 2) * 8 + x + ix * 2];
            ComputeScaledIDCT(4, 4, @blk[0],
              PSingle(@px[y * 4 * stride + x * 4]), stride);
          end;
      end;
    ACS_DCT2X2:
      begin
        for x := 0 to 63 do blk[x] := cf[x];
        c := PSingleArr(@blk[0]);
        IDCT2TopBlock(2, c);
        IDCT2TopBlock(4, c);
        IDCT2TopBlock(8, c);
        for y := 0 to 7 do
          for x := 0 to 7 do
            px[y * stride + x] := blk[y * 8 + x];
      end;
    ACS_AFV0..ACS_AFV3:
      AFVTransformToPixels(strategy - ACS_AFV0, cf, px, stride);
  else
    // every DCT-family strategy: a ROWS x COLS scaled IDCT
    ComputeScaledIDCT(8 * kAcsCoveredY[strategy], 8 * kAcsCoveredX[strategy],
                      coeffs, pixels, stride);
  end;
end;

// DCTTotalResampleScale<N, DCT_N>(k): 1 / (cos(k pi/2M) cos(k pi/M) cos(2k pi/M))
// with M = DCT_N (dct_scales.h, the "inverses" tables).
function ResampleScale(dctN, k: Integer): Single; inline;
begin
  if k = 0 then Exit(1.0);
  Result := 1.0 / (Cos(k * Pi / (2.0 * dctN)) * Cos(k * Pi / dctN) *
                   Cos(2.0 * k * Pi / dctN));
end;

procedure LowestFrequenciesFromDC(strategy: Integer; dc: PSingle;
                                  dcStride: Integer; llf: PSingle);
var
  rows, cols, outStride, y, x: Integer;
  block: array of Single;
  o: PSingleArr;
begin
  rows := kAcsCoveredY[strategy];
  cols := kAcsCoveredX[strategy];
  o := PSingleArr(llf);
  if (rows = 1) and (cols = 1) then
  begin
    o[0] := dc^;
    Exit;
  end;
  // ReinterpretingDCT<8*rows, 8*cols, rows, cols, rows, cols>
  SetLength(block, rows * cols);
  ComputeScaledDCT(rows, cols, dc, dcStride, @block[0]);
  if rows >= cols then outStride := 8 * rows else outStride := 8 * cols;
  if rows < cols then
  begin
    for y := 0 to rows - 1 do
      for x := 0 to cols - 1 do
        o[y * outStride + x] := block[y * cols + x] *
          ResampleScale(8 * rows, y) * ResampleScale(8 * cols, x);
  end
  else
  begin
    for y := 0 to cols - 1 do
      for x := 0 to rows - 1 do
        o[y * outStride + x] := block[y * rows + x] *
          ResampleScale(8 * cols, y) * ResampleScale(8 * rows, x);
  end;
end;

// ---------------------------------------------------------------------------
// Natural coefficient order (ac_strategy.cc CoeffOrderAndLut, is_lut=false)
// ---------------------------------------------------------------------------
procedure ComputeNaturalCoeffOrder(strategy: Integer; order: PCardinal);
type
  TCardArr = array[0..MaxInt div 8] of Cardinal;
var
  cx, cy, t, xs, xsm, xss, cur, i, j, x, y, vv, ip: Integer;
  ord: ^TCardArr;
begin
  ord := Pointer(order);
  cx := kAcsCoveredX[strategy];
  cy := kAcsCoveredY[strategy];
  if cy > cx then begin t := cx; cx := cy; cy := t; end;
  xs  := cx div cy;
  xsm := xs - 1;
  xss := Log2Of(xs);
  cur := cx * cy;
  for i := 0 to cx * 8 - 1 do
    for j := 0 to i do
    begin
      x := j; y := i - j;
      if (i and 1) <> 0 then begin t := x; x := y; y := t; end;
      if (y and xsm) <> 0 then Continue;
      y := y shr xss;
      if (x < cx) and (y < cy) then
        vv := y * cx + x
      else
      begin
        vv := cur; Inc(cur);
      end;
      ord[vv] := Cardinal(y * cx * 8 + x);
    end;
  for ip := cx * 8 - 1 downto 1 do
  begin
    i := ip - 1;
    for j := 0 to i do
    begin
      x := cx * 8 - 1 - (i - j);
      y := cx * 8 - 1 - j;
      if (i and 1) <> 0 then begin t := x; x := y; y := t; end;
      if (y and xsm) <> 0 then Continue;
      y := y shr xss;
      vv := cur; Inc(cur);
      ord[vv] := Cardinal(y * cx * 8 + x);
    end;
  end;
end;

initialization
  InitWc;
end.
