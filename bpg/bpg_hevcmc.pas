// BPG decoder -- Free Pascal port of libbpg 0.9.8
// Motion compensation: the uni-directional quarter-pel (luma) and eighth-pel
// (chroma) interpolation filters, their weighted-prediction variants, and the
// edge emulation helper.
// Corresponds to: the put_hevc_pel/qpel/epel_uni* half of libavcodec/hevcdsp.c
//                 and ff_emulated_edge_mc from libavcodec/videodsp_template.c
//
// libbpg builds only the "_var" flavour of these functions: the pixel type is
// always uint16_t and the bit depth is a runtime argument. The reference
// dispatch tables are indexed [width_idx][my != 0][mx != 0], but every one of
// the ten width slots is filled with the same function (see hevcdsp.c:824), so
// the width index carries no information and is dropped here -- callers select
// on the two fractional-position bits alone.
//
// Only uni-directional prediction is present. libbpg strips the bi-directional
// put_hevc_*_bi* paths, so B-slices with two active lists never reach here;
// hls_prediction_unit averages the two uni results itself.
unit bpg_hevcmc;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  bpg_common, bpg_hevcdsp;

const
  MC_TMP_STRIDE = 64;

procedure ff_emulated_edge_mc(Buf, Src: PByte; buf_linesize, src_linesize: PtrInt;
  block_w, block_h, src_x, src_y, W, H: Integer);

// Unweighted uni-prediction. MxNz select the variant:
// put_hevc_qpel_uni(dst, dststride, src, srcstride, height, mx, my, width, bd)
procedure put_hevc_qpel_uni(Dst: PByte; DstStride: PtrInt; Src: PByte; SrcStride: PtrInt;
  Height, Mx, My, Width, BitDepth: Integer);
procedure put_hevc_epel_uni(Dst: PByte; DstStride: PtrInt; Src: PByte; SrcStride: PtrInt;
  Height, Mx, My, Width, BitDepth: Integer);

// Weighted uni-prediction.
procedure put_hevc_qpel_uni_w(Dst: PByte; DstStride: PtrInt; Src: PByte; SrcStride: PtrInt;
  Height, Denom, Wx, Ox, Mx, My, Width, BitDepth: Integer);
procedure put_hevc_epel_uni_w(Dst: PByte; DstStride: PtrInt; Src: PByte; SrcStride: PtrInt;
  Height, Denom, Wx, Ox, Mx, My, Width, BitDepth: Integer);

implementation

procedure ff_emulated_edge_mc(Buf, Src: PByte; buf_linesize, src_linesize: PtrInt;
  block_w, block_h, src_x, src_y, W, H: Integer);
const
  PixSize = SizeOf(Word);
var
  X, Y, start_y, start_x, end_y, end_x, CopyW: Integer;
  bufp: PWord;
  Rows: Integer;
begin
  if (W = 0) or (H = 0) then Exit;

  if src_y >= H then
  begin
    Src := Src - src_y * src_linesize;
    Src := Src + (H - 1) * src_linesize;
    src_y := H - 1;
  end
  else if src_y <= -block_h then
  begin
    Src := Src - src_y * src_linesize;
    Src := Src + (1 - block_h) * src_linesize;
    src_y := 1 - block_h;
  end;
  if src_x >= W then
  begin
    Src := Src + (W - 1 - src_x) * PixSize;
    src_x := W - 1;
  end
  else if src_x <= -block_w then
  begin
    Src := Src + (1 - block_w - src_x) * PixSize;
    src_x := 1 - block_w;
  end;

  start_y := 0; if -src_y > 0 then start_y := -src_y;
  start_x := 0; if -src_x > 0 then start_x := -src_x;
  end_y := block_h; if H - src_y < end_y then end_y := H - src_y;
  end_x := block_w; if W - src_x < end_x then end_x := W - src_x;

  CopyW := end_x - start_x;
  Src := Src + start_y * src_linesize + start_x * PixSize;
  Buf := Buf + start_x * PixSize;

  // top
  Y := 0;
  while Y < start_y do
  begin
    Move(Src^, Buf^, CopyW * PixSize);
    Buf := Buf + buf_linesize;
    Inc(Y);
  end;
  // existing part
  while Y < end_y do
  begin
    Move(Src^, Buf^, CopyW * PixSize);
    Src := Src + src_linesize;
    Buf := Buf + buf_linesize;
    Inc(Y);
  end;
  // bottom
  Src := Src - src_linesize;
  while Y < block_h do
  begin
    Move(Src^, Buf^, CopyW * PixSize);
    Buf := Buf + buf_linesize;
    Inc(Y);
  end;

  Buf := Buf - (block_h * buf_linesize + start_x * PixSize);
  Rows := block_h;
  while Rows > 0 do
  begin
    bufp := PWord(Buf);
    for X := 0 to start_x - 1 do
      bufp[X] := bufp[start_x];
    for X := end_x to block_w - 1 do
      bufp[X] := bufp[end_x - 1];
    Buf := Buf + buf_linesize;
    Dec(Rows);
  end;
end;

// ---------------- unweighted ----------------

procedure put_hevc_pel_uni_pixels(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, Width: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  Y: Integer;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  for Y := 0 to Height - 1 do
  begin
    Move(S^, D^, Width * SizeOf(Word));
    S := S + ss;
    D := D + ds;
  end;
end;

procedure put_hevc_qpel_uni_h(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, Mx, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  F: PInt8;
  Shift, Offset, X, Y: Integer;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  F := @ff_hevc_qpel_filters[Mx - 1][0];
  Shift := 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR(SAR(F[0] * S[X - 3] + F[1] * S[X - 2] + F[2] * S[X - 1] + F[3] * S[X] +
                F[4] * S[X + 1] + F[5] * S[X + 2] + F[6] * S[X + 3] + F[7] * S[X + 4],
                BitDepth - 8) + Offset, Shift), BitDepth));
    S := S + ss;
    D := D + ds;
  end;
end;

procedure put_hevc_qpel_uni_v(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, My, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  F: PInt8;
  Shift, Offset, X, Y: Integer;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  F := @ff_hevc_qpel_filters[My - 1][0];
  Shift := 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR(SAR(F[0] * S[X - 3 * ss] + F[1] * S[X - 2 * ss] + F[2] * S[X - ss] + F[3] * S[X] +
                F[4] * S[X + ss] + F[5] * S[X + 2 * ss] + F[6] * S[X + 3 * ss] + F[7] * S[X + 4 * ss],
                BitDepth - 8) + Offset, Shift), BitDepth));
    S := S + ss;
    D := D + ds;
  end;
end;

procedure put_hevc_qpel_uni_hv(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, Mx, My, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  F: PInt8;
  Shift, Offset, X, Y: Integer;
  tmp_array: array[0 .. (64 + 7) * MC_TMP_STRIDE - 1] of Int16;
  Tmp: PInt16;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  Shift := 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  S := S - 3 * ss;
  F := @ff_hevc_qpel_filters[Mx - 1][0];
  Tmp := @tmp_array[0];
  for Y := 0 to Height + 7 - 1 do
  begin
    for X := 0 to Width - 1 do
      Tmp[X] := Int16(SAR(F[0] * S[X - 3] + F[1] * S[X - 2] + F[2] * S[X - 1] + F[3] * S[X] +
                          F[4] * S[X + 1] + F[5] * S[X + 2] + F[6] * S[X + 3] + F[7] * S[X + 4],
                          BitDepth - 8));
    S := S + ss;
    Tmp := Tmp + MC_TMP_STRIDE;
  end;
  Tmp := @tmp_array[3 * MC_TMP_STRIDE];
  F := @ff_hevc_qpel_filters[My - 1][0];
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR(SAR(F[0] * Tmp[X - 3 * MC_TMP_STRIDE] + F[1] * Tmp[X - 2 * MC_TMP_STRIDE] +
                F[2] * Tmp[X - MC_TMP_STRIDE] + F[3] * Tmp[X] +
                F[4] * Tmp[X + MC_TMP_STRIDE] + F[5] * Tmp[X + 2 * MC_TMP_STRIDE] +
                F[6] * Tmp[X + 3 * MC_TMP_STRIDE] + F[7] * Tmp[X + 4 * MC_TMP_STRIDE],
                6) + Offset, Shift), BitDepth));
    Tmp := Tmp + MC_TMP_STRIDE;
    D := D + ds;
  end;
end;

procedure put_hevc_epel_uni_h(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, Mx, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  F: PInt8;
  Shift, Offset, X, Y: Integer;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  F := @ff_hevc_epel_filters[Mx - 1][0];
  Shift := 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR(SAR(F[0] * S[X - 1] + F[1] * S[X] + F[2] * S[X + 1] + F[3] * S[X + 2],
                BitDepth - 8) + Offset, Shift), BitDepth));
    S := S + ss;
    D := D + ds;
  end;
end;

procedure put_hevc_epel_uni_v(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, My, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  F: PInt8;
  Shift, Offset, X, Y: Integer;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  F := @ff_hevc_epel_filters[My - 1][0];
  Shift := 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR(SAR(F[0] * S[X - ss] + F[1] * S[X] + F[2] * S[X + ss] + F[3] * S[X + 2 * ss],
                BitDepth - 8) + Offset, Shift), BitDepth));
    S := S + ss;
    D := D + ds;
  end;
end;

procedure put_hevc_epel_uni_hv(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, Mx, My, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  F: PInt8;
  Shift, Offset, X, Y: Integer;
  tmp_array: array[0 .. (64 + 3) * MC_TMP_STRIDE - 1] of Int16;
  Tmp: PInt16;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  F := @ff_hevc_epel_filters[Mx - 1][0];
  Shift := 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  S := S - ss;
  Tmp := @tmp_array[0];
  for Y := 0 to Height + 3 - 1 do
  begin
    for X := 0 to Width - 1 do
      Tmp[X] := Int16(SAR(F[0] * S[X - 1] + F[1] * S[X] + F[2] * S[X + 1] + F[3] * S[X + 2],
                          BitDepth - 8));
    S := S + ss;
    Tmp := Tmp + MC_TMP_STRIDE;
  end;
  Tmp := @tmp_array[MC_TMP_STRIDE];
  F := @ff_hevc_epel_filters[My - 1][0];
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR(SAR(F[0] * Tmp[X - MC_TMP_STRIDE] + F[1] * Tmp[X] +
                F[2] * Tmp[X + MC_TMP_STRIDE] + F[3] * Tmp[X + 2 * MC_TMP_STRIDE],
                6) + Offset, Shift), BitDepth));
    Tmp := Tmp + MC_TMP_STRIDE;
    D := D + ds;
  end;
end;

// ---------------- weighted ----------------

procedure put_hevc_pel_uni_w_pixels(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, Denom, Wx, Ox, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  Shift, Offset, X, Y, O: Integer;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  Shift := Denom + 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  O := Ox * (1 shl (BitDepth - 8));
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR((S[X] shl (14 - BitDepth)) * Wx + Offset, Shift) + O, BitDepth));
    S := S + ss;
    D := D + ds;
  end;
end;

procedure put_hevc_qpel_uni_w_h(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, Denom, Wx, Ox, Mx, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  F: PInt8;
  Shift, Offset, X, Y, O: Integer;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  F := @ff_hevc_qpel_filters[Mx - 1][0];
  Shift := Denom + 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  O := Ox * (1 shl (BitDepth - 8));
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR(SAR(F[0] * S[X - 3] + F[1] * S[X - 2] + F[2] * S[X - 1] + F[3] * S[X] +
                F[4] * S[X + 1] + F[5] * S[X + 2] + F[6] * S[X + 3] + F[7] * S[X + 4],
                BitDepth - 8) * Wx + Offset, Shift) + O, BitDepth));
    S := S + ss;
    D := D + ds;
  end;
end;

procedure put_hevc_qpel_uni_w_v(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, Denom, Wx, Ox, My, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  F: PInt8;
  Shift, Offset, X, Y, O: Integer;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  F := @ff_hevc_qpel_filters[My - 1][0];
  Shift := Denom + 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  O := Ox * (1 shl (BitDepth - 8));
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR(SAR(F[0] * S[X - 3 * ss] + F[1] * S[X - 2 * ss] + F[2] * S[X - ss] + F[3] * S[X] +
                F[4] * S[X + ss] + F[5] * S[X + 2 * ss] + F[6] * S[X + 3 * ss] + F[7] * S[X + 4 * ss],
                BitDepth - 8) * Wx + Offset, Shift) + O, BitDepth));
    S := S + ss;
    D := D + ds;
  end;
end;

procedure put_hevc_qpel_uni_w_hv(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, Denom, Wx, Ox, Mx, My, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  F: PInt8;
  Shift, Offset, X, Y, O: Integer;
  tmp_array: array[0 .. (64 + 7) * MC_TMP_STRIDE - 1] of Int16;
  Tmp: PInt16;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  Shift := Denom + 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  S := S - 3 * ss;
  F := @ff_hevc_qpel_filters[Mx - 1][0];
  Tmp := @tmp_array[0];
  for Y := 0 to Height + 7 - 1 do
  begin
    for X := 0 to Width - 1 do
      Tmp[X] := Int16(SAR(F[0] * S[X - 3] + F[1] * S[X - 2] + F[2] * S[X - 1] + F[3] * S[X] +
                          F[4] * S[X + 1] + F[5] * S[X + 2] + F[6] * S[X + 3] + F[7] * S[X + 4],
                          BitDepth - 8));
    S := S + ss;
    Tmp := Tmp + MC_TMP_STRIDE;
  end;
  Tmp := @tmp_array[3 * MC_TMP_STRIDE];
  F := @ff_hevc_qpel_filters[My - 1][0];
  O := Ox * (1 shl (BitDepth - 8));
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR(SAR(F[0] * Tmp[X - 3 * MC_TMP_STRIDE] + F[1] * Tmp[X - 2 * MC_TMP_STRIDE] +
                F[2] * Tmp[X - MC_TMP_STRIDE] + F[3] * Tmp[X] +
                F[4] * Tmp[X + MC_TMP_STRIDE] + F[5] * Tmp[X + 2 * MC_TMP_STRIDE] +
                F[6] * Tmp[X + 3 * MC_TMP_STRIDE] + F[7] * Tmp[X + 4 * MC_TMP_STRIDE],
                6) * Wx + Offset, Shift) + O, BitDepth));
    Tmp := Tmp + MC_TMP_STRIDE;
    D := D + ds;
  end;
end;

procedure put_hevc_epel_uni_w_h(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, Denom, Wx, Ox, Mx, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  F: PInt8;
  Shift, Offset, X, Y, O: Integer;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  F := @ff_hevc_epel_filters[Mx - 1][0];
  Shift := Denom + 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  O := Ox * (1 shl (BitDepth - 8));
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR(SAR(F[0] * S[X - 1] + F[1] * S[X] + F[2] * S[X + 1] + F[3] * S[X + 2],
                BitDepth - 8) * Wx + Offset, Shift) + O, BitDepth));
    D := D + ds;
    S := S + ss;
  end;
end;

procedure put_hevc_epel_uni_w_v(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, Denom, Wx, Ox, My, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  F: PInt8;
  Shift, Offset, X, Y, O: Integer;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  F := @ff_hevc_epel_filters[My - 1][0];
  Shift := Denom + 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  O := Ox * (1 shl (BitDepth - 8));
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR(SAR(F[0] * S[X - ss] + F[1] * S[X] + F[2] * S[X + ss] + F[3] * S[X + 2 * ss],
                BitDepth - 8) * Wx + Offset, Shift) + O, BitDepth));
    D := D + ds;
    S := S + ss;
  end;
end;

procedure put_hevc_epel_uni_w_hv(Dst: PByte; DstStride: PtrInt; Src: PByte;
  SrcStride: PtrInt; Height, Denom, Wx, Ox, Mx, My, Width, BitDepth: Integer);
var
  S, D: PWord;
  ss, ds: PtrInt;
  F: PInt8;
  Shift, Offset, X, Y, O: Integer;
  tmp_array: array[0 .. (64 + 3) * MC_TMP_STRIDE - 1] of Int16;
  Tmp: PInt16;
begin
  S := PWord(Src); ss := SrcStride div SizeOf(Word);
  D := PWord(Dst); ds := DstStride div SizeOf(Word);
  F := @ff_hevc_epel_filters[Mx - 1][0];
  Shift := Denom + 14 - BitDepth;
  Offset := (1 shl Shift) shr 1;
  S := S - ss;
  Tmp := @tmp_array[0];
  for Y := 0 to Height + 3 - 1 do
  begin
    for X := 0 to Width - 1 do
      Tmp[X] := Int16(SAR(F[0] * S[X - 1] + F[1] * S[X] + F[2] * S[X + 1] + F[3] * S[X + 2],
                          BitDepth - 8));
    S := S + ss;
    Tmp := Tmp + MC_TMP_STRIDE;
  end;
  Tmp := @tmp_array[MC_TMP_STRIDE];
  F := @ff_hevc_epel_filters[My - 1][0];
  O := Ox * (1 shl (BitDepth - 8));
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(
        SAR(SAR(F[0] * Tmp[X - MC_TMP_STRIDE] + F[1] * Tmp[X] +
                F[2] * Tmp[X + MC_TMP_STRIDE] + F[3] * Tmp[X + 2 * MC_TMP_STRIDE],
                6) * Wx + Offset, Shift) + O, BitDepth));
    Tmp := Tmp + MC_TMP_STRIDE;
    D := D + ds;
  end;
end;

// ---------------- dispatch ----------------

procedure put_hevc_qpel_uni(Dst: PByte; DstStride: PtrInt; Src: PByte; SrcStride: PtrInt;
  Height, Mx, My, Width, BitDepth: Integer);
begin
  if My <> 0 then
  begin
    if Mx <> 0 then
      put_hevc_qpel_uni_hv(Dst, DstStride, Src, SrcStride, Height, Mx, My, Width, BitDepth)
    else
      put_hevc_qpel_uni_v(Dst, DstStride, Src, SrcStride, Height, My, Width, BitDepth);
  end
  else
  begin
    if Mx <> 0 then
      put_hevc_qpel_uni_h(Dst, DstStride, Src, SrcStride, Height, Mx, Width, BitDepth)
    else
      put_hevc_pel_uni_pixels(Dst, DstStride, Src, SrcStride, Height, Width);
  end;
end;

procedure put_hevc_epel_uni(Dst: PByte; DstStride: PtrInt; Src: PByte; SrcStride: PtrInt;
  Height, Mx, My, Width, BitDepth: Integer);
begin
  if My <> 0 then
  begin
    if Mx <> 0 then
      put_hevc_epel_uni_hv(Dst, DstStride, Src, SrcStride, Height, Mx, My, Width, BitDepth)
    else
      put_hevc_epel_uni_v(Dst, DstStride, Src, SrcStride, Height, My, Width, BitDepth);
  end
  else
  begin
    if Mx <> 0 then
      put_hevc_epel_uni_h(Dst, DstStride, Src, SrcStride, Height, Mx, Width, BitDepth)
    else
      put_hevc_pel_uni_pixels(Dst, DstStride, Src, SrcStride, Height, Width);
  end;
end;

procedure put_hevc_qpel_uni_w(Dst: PByte; DstStride: PtrInt; Src: PByte; SrcStride: PtrInt;
  Height, Denom, Wx, Ox, Mx, My, Width, BitDepth: Integer);
begin
  if My <> 0 then
  begin
    if Mx <> 0 then
      put_hevc_qpel_uni_w_hv(Dst, DstStride, Src, SrcStride, Height, Denom, Wx, Ox, Mx, My, Width, BitDepth)
    else
      put_hevc_qpel_uni_w_v(Dst, DstStride, Src, SrcStride, Height, Denom, Wx, Ox, My, Width, BitDepth);
  end
  else
  begin
    if Mx <> 0 then
      put_hevc_qpel_uni_w_h(Dst, DstStride, Src, SrcStride, Height, Denom, Wx, Ox, Mx, Width, BitDepth)
    else
      put_hevc_pel_uni_w_pixels(Dst, DstStride, Src, SrcStride, Height, Denom, Wx, Ox, Width, BitDepth);
  end;
end;

procedure put_hevc_epel_uni_w(Dst: PByte; DstStride: PtrInt; Src: PByte; SrcStride: PtrInt;
  Height, Denom, Wx, Ox, Mx, My, Width, BitDepth: Integer);
begin
  if My <> 0 then
  begin
    if Mx <> 0 then
      put_hevc_epel_uni_w_hv(Dst, DstStride, Src, SrcStride, Height, Denom, Wx, Ox, Mx, My, Width, BitDepth)
    else
      put_hevc_epel_uni_w_v(Dst, DstStride, Src, SrcStride, Height, Denom, Wx, Ox, My, Width, BitDepth);
  end
  else
  begin
    if Mx <> 0 then
      put_hevc_epel_uni_w_h(Dst, DstStride, Src, SrcStride, Height, Denom, Wx, Ox, Mx, Width, BitDepth)
    else
      put_hevc_pel_uni_w_pixels(Dst, DstStride, Src, SrcStride, Height, Denom, Wx, Ox, Width, BitDepth);
  end;
end;

end.
