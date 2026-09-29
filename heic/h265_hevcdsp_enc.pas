// BPG encoder -- Free Pascal
// Forward transform and quantisation: the inverse of the idct / dequant pair in
// h265_hevcdsp and h265_hevc_cabac.
//
// Written from H.265 and the HM reference encoder rather than ported, since
// libbpg contains no encoder. The DCT basis is the same table the decoder uses
// (h265_hevcdsp.hevc_tr_coef), so the two cannot drift apart; only the DST-VII
// 4x4 matrix, which the decoder implements as an unrolled butterfly, is spelled
// out here.
unit h265_hevcdsp_enc;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  h265_common, h265_hevcdsp;

// Residual in, coefficients out, both Size x Size in raster order.
// UseDST selects the 4x4 DST-VII used for luma intra 4x4 blocks.
procedure fwd_transform(Coeffs: PInt16; Log2Size, BitDepth: Integer; UseDST: Boolean);

// In-place quantisation. Returns the number of non-zero coefficients.
function quantize(Coeffs: PInt16; Log2Size, Qp, BitDepth: Integer;
  IsIntra: Boolean): Integer;

implementation

const
  // HM g_as_DST_MAT_4
  dst_mat_4: array[0..3, 0..3] of Integer = (
    (29, 55, 74, 84),
    (74, 74,  0,-74),
    (84,-29,-74, 55),
    (55,-84, 74,-29));

  // HM g_quantScales, indexed by qp mod 6
  quant_scales: array[0..5] of Integer = (26214, 23302, 20560, 18396, 16384, 14564);

// One separable pass. Reads Size x Size from Src in raster order and writes the
// transposed result to Dst, exactly as HM's partialButterfly does.
procedure fwd_pass(Src, Dst: PInt32; Size, Log2Size, Shift: Integer; UseDST: Boolean);
var
  Row, K, I, Stride, Add, Sum: Integer;
begin
  Stride := 32 div Size;
  Add := 1 shl (Shift - 1);
  for Row := 0 to Size - 1 do
    for K := 0 to Size - 1 do
    begin
      Sum := 0;
      if UseDST then
        for I := 0 to 3 do
          Sum := Sum + dst_mat_4[K][I] * Src[Row * Size + I]
      else
        for I := 0 to Size - 1 do
          Sum := Sum + hevc_tr_coef(K * Stride, I) * Src[Row * Size + I];
      Dst[K * Size + Row] := SAR(Sum + Add, Shift);
    end;
end;

procedure fwd_transform(Coeffs: PInt16; Log2Size, BitDepth: Integer; UseDST: Boolean);
var
  Size, N, I, shift1, shift2: Integer;
  A, B: array[0 .. 32 * 32 - 1] of Int32;
begin
  Size := 1 shl Log2Size;
  N := Size * Size;
  // HM: shift_1st = log2 + bitDepth - 9, shift_2nd = log2 + 6
  shift1 := Log2Size + BitDepth - 9;
  shift2 := Log2Size + 6;
  for I := 0 to N - 1 do
    A[I] := Coeffs[I];
  fwd_pass(@A[0], @B[0], Size, Log2Size, shift1, UseDST);
  fwd_pass(@B[0], @A[0], Size, Log2Size, shift2, UseDST);
  for I := 0 to N - 1 do
    Coeffs[I] := Int16(av_clip_c(A[I], -32768, 32767));
end;

function quantize(Coeffs: PInt16; Log2Size, Qp, BitDepth: Integer;
  IsIntra: Boolean): Integer;
var
  transform_shift, qbits, Add, Scale, I, N, Level, V: Integer;
  Acc: Int64;
begin
  N := 1 shl (2 * Log2Size);
  transform_shift := 15 - BitDepth - Log2Size;
  qbits := 14 + (Qp div 6) + transform_shift;
  if IsIntra then
    Add := 171 shl (qbits - 9)
  else
    Add := 85 shl (qbits - 9);
  Scale := quant_scales[Qp mod 6];

  Result := 0;
  for I := 0 to N - 1 do
  begin
    V := Coeffs[I];
    Acc := Int64(Abs(V)) * Scale + Add;
    Level := Integer(Acc shr qbits);
    if Level > 32767 then Level := 32767;
    if Level <> 0 then
    begin
      Inc(Result);
      if V < 0 then Level := -Level;
    end;
    Coeffs[I] := Int16(Level);
  end;
end;


end.
