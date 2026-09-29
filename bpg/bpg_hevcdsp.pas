// BPG decoder -- Free Pascal port of libbpg 0.9.8
// DSP: inverse transforms, transform-skip/RDPCM, PCM, SAO band/edge filters
// and the deblocking loop filters.
// Corresponds to: libavcodec/hevcdsp.c + hevcdsp_template.c
//                 (single instantiation, samples are always 16-bit)
//
// The reference dispatches through HEVCDSPContext function pointers; since only
// one instantiation exists here the functions are called directly.
//
// NOTE: inter-prediction (put_hevc_qpel*/epel* motion compensation) is not in
// this unit yet -- it is only reachable for animated BPG. See bpg_hevcmc.pas.
unit bpg_hevcdsp;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  bpg_common, bpg_bits, bpg_hevc_defs;

procedure hevc_transform_init;

// g_aiT32[K][J] of the HEVC integer DCT. The N-point matrix is the strided set
// of rows g_aiT_N[k][j] = hevc_tr_coef(k * (32 div N), j). Used by the forward
// transform in bpg_hevcdsp_enc.
function hevc_tr_coef(K, J: Integer): Integer; inline;

procedure put_pcm(Dst: PByte; Stride: PtrInt; Width, Height: Integer;
  GB: PGetBitContext; PcmBitDepth, BitDepth: Integer);

procedure transform_add(Idx: Integer; Dst: PByte; Coeffs: PInt16;
  Stride: PtrInt; BitDepth: Integer);
procedure transform_skip(Coeffs: PInt16; Log2Size: Int16; BitDepth: Integer);
procedure transform_rdpcm(Coeffs: PInt16; Log2Size: Int16; Mode: Integer);
procedure transform_4x4_luma(Coeffs: PInt16; BitDepth: Integer);
procedure idct(Idx: Integer; Coeffs: PInt16; ColLimit: Integer; BitDepth: Integer);
procedure idct_dc(Idx: Integer; Coeffs: PInt16; BitDepth: Integer);

procedure sao_band_filter(Dst, Src: PByte; StrideDst, StrideSrc: PtrInt;
  Sao: PSAOParams; Borders: PInteger; Width, Height, CIdx, BitDepth: Integer);
procedure sao_edge_filter(Which: Integer; Dst, Src: PByte;
  StrideDst, StrideSrc: PtrInt; Sao: PSAOParams; Borders: PInteger;
  Width, Height, CIdx: Integer; VertEdge, HorizEdge, DiagEdge: PByte;
  BitDepth: Integer);

procedure hevc_h_loop_filter_luma(Pix: PByte; Stride: PtrInt; Beta: Integer;
  Tc: PInt32; NoP, NoQ: PByte; BitDepth: Integer);
procedure hevc_v_loop_filter_luma(Pix: PByte; Stride: PtrInt; Beta: Integer;
  Tc: PInt32; NoP, NoQ: PByte; BitDepth: Integer);
procedure hevc_h_loop_filter_chroma(Pix: PByte; Stride: PtrInt;
  Tc: PInt32; NoP, NoQ: PByte; BitDepth: Integer);
procedure hevc_v_loop_filter_chroma(Pix: PByte; Stride: PtrInt;
  Tc: PInt32; NoP, NoQ: PByte; BitDepth: Integer);

const
  ff_hevc_epel_filters: array[0..6, 0..3] of Int8 = (
    ( -2, 58, 10, -2),
    ( -4, 54, 16, -2),
    ( -6, 46, 28, -4),
    ( -4, 36, 36, -4),
    ( -4, 28, 46, -6),
    ( -2, 16, 54, -4),
    ( -2, 10, 58, -2)
  );
  ff_hevc_qpel_filters: array[0..2, 0..15] of Int8 = (
    ( -1, 4,-10, 58, 17, -5, 1, 0, -1, 4,-10, 58, 17, -5, 1, 0),
    ( -1, 4,-11, 40, 40,-11, 4, -1, -1, 4,-11, 40, 40,-11, 4, -1),
    (  0, 1, -5, 17, 58,-10, 4, -1,  0, 1, -5, 17, 58,-10, 4, -1)
  );

implementation

const
  dct_coefs: array[0..31] of Int8 = (
    64, 90, 90, 90, 89, 88, 87, 85, 83, 82, 80, 78, 75, 73, 70, 67,
    64, 61, 57, 54, 50, 46, 43, 38, 36, 31, 25, 22, 18, 13, 9, 4
  );

var
  transform: array[0..31, 0..31] of Int8;

function av_clip_int16(A: Integer): Int16; inline;
begin
  if ((A + $8000) and (not $FFFF)) <> 0 then
  begin
    if A < 0 then Result := -32768 else Result := 32767;
  end
  else
    Result := Int16(A);
end;

procedure hevc_transform_init;
var
  I, J, K, Sg: Integer;
begin
  if transform[0][0] <> 0 then Exit;
  for I := 0 to 31 do
    for J := 0 to 31 do
    begin
      K := ((2 * J + 1) * I) mod 128;
      Sg := 1;
      if K >= 64 then
      begin
        K := K - 64;
        Sg := -1;
      end;
      if K >= 32 then
      begin
        K := 64 - K;
        Sg := -Sg;
      end;
      transform[I][J] := Int8(dct_coefs[K] * Sg);
    end;
end;

function hevc_tr_coef(K, J: Integer): Integer;
begin
  Result := transform[K][J];
end;

procedure put_pcm(Dst: PByte; Stride: PtrInt; Width, Height: Integer;
  GB: PGetBitContext; PcmBitDepth, BitDepth: Integer);
var
  X, Y: Integer;
  D: PWord;
begin
  D := PWord(Dst);
  Stride := Stride div SizeOf(Word);
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(get_bits(GB^, PcmBitDepth) shl (BitDepth - PcmBitDepth));
    D := D + Stride;
  end;
end;

procedure transform_add(Idx: Integer; Dst: PByte; Coeffs: PInt16;
  Stride: PtrInt; BitDepth: Integer);
var
  X, Y, Size: Integer;
  D: PWord;
begin
  Size := 4 shl Idx;
  D := PWord(Dst);
  Stride := Stride div SizeOf(Word);
  for Y := 0 to Size - 1 do
  begin
    for X := 0 to Size - 1 do
    begin
      D[X] := Word(av_clip_uintp2(D[X] + Coeffs^, BitDepth));
      Inc(Coeffs);
    end;
    D := D + Stride;
  end;
end;

procedure transform_rdpcm(Coeffs: PInt16; Log2Size: Int16; Mode: Integer);
var
  X, Y, Size: Integer;
begin
  Size := 1 shl Log2Size;
  if Mode <> 0 then
  begin
    Coeffs := Coeffs + Size;
    for Y := 0 to Size - 2 do
    begin
      for X := 0 to Size - 1 do
        Coeffs[X] := Int16(Coeffs[X] + Coeffs[X - Size]);
      Coeffs := Coeffs + Size;
    end;
  end
  else
  begin
    for Y := 0 to Size - 1 do
    begin
      for X := 1 to Size - 1 do
        Coeffs[X] := Int16(Coeffs[X] + Coeffs[X - 1]);
      Coeffs := Coeffs + Size;
    end;
  end;
end;

procedure transform_skip(Coeffs: PInt16; Log2Size: Int16; BitDepth: Integer);
var
  Shift, X, Y, Size, Offset: Integer;
begin
  Shift := 15 - BitDepth - Log2Size;
  Size := 1 shl Log2Size;
  if Shift > 0 then
  begin
    Offset := 1 shl (Shift - 1);
    for Y := 0 to Size - 1 do
      for X := 0 to Size - 1 do
      begin
        Coeffs^ := Int16(SarLongint(Coeffs^ + Offset, Shift));
        Inc(Coeffs);
      end;
  end
  else
  begin
    for Y := 0 to Size - 1 do
      for X := 0 to Size - 1 do
      begin
        Coeffs^ := Int16(Coeffs^ shl (-Shift));
        Inc(Coeffs);
      end;
  end;
end;

// TR_4 with the "luma" (DST-VII) coefficients
procedure transform_4x4_luma(Coeffs: PInt16; BitDepth: Integer);
var
  I, Shift, Add, C0, C1, C2, C3: Integer;
  Src: PInt16;
begin
  Shift := 7;
  Add := 1 shl (Shift - 1);
  Src := Coeffs;
  for I := 0 to 3 do
  begin
    C0 := Src[0 * 4] + Src[2 * 4];
    C1 := Src[2 * 4] + Src[3 * 4];
    C2 := Src[0 * 4] - Src[3 * 4];
    C3 := 74 * Src[1 * 4];
    Src[2 * 4] := av_clip_int16(SarLongint(74 * (Src[0 * 4] - Src[2 * 4] + Src[3 * 4]) + Add, Shift));
    Src[0 * 4] := av_clip_int16(SarLongint(29 * C0 + 55 * C1 + C3 + Add, Shift));
    Src[1 * 4] := av_clip_int16(SarLongint(55 * C2 - 29 * C1 + C3 + Add, Shift));
    Src[3 * 4] := av_clip_int16(SarLongint(55 * C0 + 29 * C2 - C3 + Add, Shift));
    Inc(Src);
  end;
  Shift := 20 - BitDepth;
  Add := 1 shl (Shift - 1);
  for I := 0 to 3 do
  begin
    C0 := Coeffs[0] + Coeffs[2];
    C1 := Coeffs[2] + Coeffs[3];
    C2 := Coeffs[0] - Coeffs[3];
    C3 := 74 * Coeffs[1];
    Coeffs[2] := av_clip_int16(SarLongint(74 * (Coeffs[0] - Coeffs[2] + Coeffs[3]) + Add, Shift));
    Coeffs[0] := av_clip_int16(SarLongint(29 * C0 + 55 * C1 + C3 + Add, Shift));
    Coeffs[1] := av_clip_int16(SarLongint(55 * C2 - 29 * C1 + C3 + Add, Shift));
    Coeffs[3] := av_clip_int16(SarLongint(55 * C0 + 29 * C2 - C3 + Add, Shift));
    Coeffs := Coeffs + 4;
  end;
end;

// TR_4(dst, src, dstep, sstep) with SET semantics into an integer array
procedure TR4_Set(var E: array of Integer; Src: PInt16; SStep: Integer); inline;
var
  E0, E1, O0, O1: Integer;
begin
  E0 := 64 * Src[0 * SStep] + 64 * Src[2 * SStep];
  E1 := 64 * Src[0 * SStep] - 64 * Src[2 * SStep];
  O0 := 83 * Src[1 * SStep] + 36 * Src[3 * SStep];
  O1 := 36 * Src[1 * SStep] - 83 * Src[3 * SStep];
  E[0] := E0 + O0;
  E[1] := E1 + O1;
  E[2] := E1 - O1;
  E[3] := E0 - O0;
end;

procedure idct_4x4_pass(Src: PInt16; SStep, Shift, Add: Integer); inline;
var
  E0, E1, O0, O1: Integer;
begin
  E0 := 64 * Src[0 * SStep] + 64 * Src[2 * SStep];
  E1 := 64 * Src[0 * SStep] - 64 * Src[2 * SStep];
  O0 := 83 * Src[1 * SStep] + 36 * Src[3 * SStep];
  O1 := 36 * Src[1 * SStep] - 83 * Src[3 * SStep];
  Src[0 * SStep] := av_clip_int16(SarLongint(E0 + O0 + Add, Shift));
  Src[1 * SStep] := av_clip_int16(SarLongint(E1 + O1 + Add, Shift));
  Src[2 * SStep] := av_clip_int16(SarLongint(E1 - O1 + Add, Shift));
  Src[3 * SStep] := av_clip_int16(SarLongint(E0 - O0 + Add, Shift));
end;

procedure idct_4x4_var(Coeffs: PInt16; ColLimit, BitDepth: Integer);
var
  I, Shift, Add: Integer;
  Src: PInt16;
begin
  Shift := 7;
  Add := 1 shl (Shift - 1);
  Src := Coeffs;
  for I := 0 to 3 do
  begin
    idct_4x4_pass(Src, 4, Shift, Add);
    Inc(Src);
  end;
  Shift := 20 - BitDepth;
  Add := 1 shl (Shift - 1);
  for I := 0 to 3 do
  begin
    idct_4x4_pass(Coeffs, 1, Shift, Add);
    Coeffs := Coeffs + 4;
  end;
end;

procedure TR8_Body(Src: PInt16; SStep, Shift, Add, Limit: Integer); inline;
var
  I, J: Integer;
  E8: array[0..3] of Integer;
  O8: array[0..3] of Integer;
begin
  for I := 0 to 3 do O8[I] := 0;
  for I := 0 to 3 do
  begin
    J := 1;
    while J < Limit do
    begin
      O8[I] := O8[I] + transform[4 * J][I] * Src[J * SStep];
      Inc(J, 2);
    end;
  end;
  TR4_Set(E8, Src, 2 * SStep);
  for I := 0 to 3 do
  begin
    Src[I * SStep] := av_clip_int16(SarLongint(E8[I] + O8[I] + Add, Shift));
    Src[(7 - I) * SStep] := av_clip_int16(SarLongint(E8[I] - O8[I] + Add, Shift));
  end;
end;

procedure idct_8x8_var(Coeffs: PInt16; ColLimit, BitDepth: Integer);
var
  I, Shift, Add, Limit, Limit2: Integer;
  Src: PInt16;
begin
  Shift := 7;
  Add := 1 shl (Shift - 1);
  Src := Coeffs;
  Limit := FFMIN(ColLimit, 8);
  Limit2 := FFMIN(ColLimit + 4, 8);
  for I := 0 to 7 do
  begin
    TR8_Body(Src, 8, Shift, Add, Limit2);
    if (Limit2 < 8) and (I mod 4 = 0) and (I <> 0) then Limit2 := Limit2 - 4;
    Inc(Src);
  end;
  Shift := 20 - BitDepth;
  Add := 1 shl (Shift - 1);
  for I := 0 to 7 do
  begin
    TR8_Body(Coeffs, 1, Shift, Add, Limit);
    Coeffs := Coeffs + 8;
  end;
end;

// TR_8 with SET semantics, writing into E16
procedure TR8_Set(var E16: array of Integer; Src: PInt16; SStep: Integer); inline;
var
  I, J: Integer;
  E8: array[0..3] of Integer;
  O8: array[0..3] of Integer;
begin
  for I := 0 to 3 do O8[I] := 0;
  for I := 0 to 3 do
  begin
    J := 1;
    while J < 8 do
    begin
      O8[I] := O8[I] + transform[4 * J][I] * Src[J * 2 * SStep];
      Inc(J, 2);
    end;
  end;
  TR4_Set(E8, Src, 2 * 2 * SStep);
  for I := 0 to 3 do
  begin
    E16[I] := E8[I] + O8[I];
    E16[7 - I] := E8[I] - O8[I];
  end;
end;

procedure TR16_Body(Src: PInt16; SStep, Shift, Add, Limit: Integer); inline;
var
  I, J: Integer;
  E16: array[0..7] of Integer;
  O16: array[0..7] of Integer;
begin
  for I := 0 to 7 do O16[I] := 0;
  for I := 0 to 7 do
  begin
    J := 1;
    while J < Limit do
    begin
      O16[I] := O16[I] + transform[2 * J][I] * Src[J * SStep];
      Inc(J, 2);
    end;
  end;
  TR8_Set(E16, Src, SStep);
  for I := 0 to 7 do
  begin
    Src[I * SStep] := av_clip_int16(SarLongint(E16[I] + O16[I] + Add, Shift));
    Src[(15 - I) * SStep] := av_clip_int16(SarLongint(E16[I] - O16[I] + Add, Shift));
  end;
end;

procedure idct_16x16_var(Coeffs: PInt16; ColLimit, BitDepth: Integer);
var
  I, Shift, Add, Limit, Limit2: Integer;
  Src: PInt16;
begin
  Shift := 7;
  Add := 1 shl (Shift - 1);
  Src := Coeffs;
  Limit := FFMIN(ColLimit, 16);
  Limit2 := FFMIN(ColLimit + 4, 16);
  for I := 0 to 15 do
  begin
    TR16_Body(Src, 16, Shift, Add, Limit2);
    if (Limit2 < 16) and (I mod 4 = 0) and (I <> 0) then Limit2 := Limit2 - 4;
    Inc(Src);
  end;
  Shift := 20 - BitDepth;
  Add := 1 shl (Shift - 1);
  for I := 0 to 15 do
  begin
    TR16_Body(Coeffs, 1, Shift, Add, Limit);
    Coeffs := Coeffs + 16;
  end;
end;

// TR_16 with SET semantics, writing into E32 (inner limit is limit/2)
procedure TR16_Set(var E32: array of Integer; Src: PInt16; SStep, Limit: Integer); inline;
var
  I, J: Integer;
  E16: array[0..7] of Integer;
  O16: array[0..7] of Integer;
begin
  for I := 0 to 7 do O16[I] := 0;
  for I := 0 to 7 do
  begin
    J := 1;
    while J < Limit do
    begin
      O16[I] := O16[I] + transform[2 * J][I] * Src[J * 2 * SStep];
      Inc(J, 2);
    end;
  end;
  TR8_Set(E16, Src, 2 * SStep);
  for I := 0 to 7 do
  begin
    E32[I] := E16[I] + O16[I];
    E32[15 - I] := E16[I] - O16[I];
  end;
end;

procedure TR32_Body(Src: PInt16; SStep, Shift, Add, Limit: Integer); inline;
var
  I, J: Integer;
  E32: array[0..15] of Integer;
  O32: array[0..15] of Integer;
begin
  for I := 0 to 15 do O32[I] := 0;
  for I := 0 to 15 do
  begin
    J := 1;
    while J < Limit do
    begin
      O32[I] := O32[I] + transform[J][I] * Src[J * SStep];
      Inc(J, 2);
    end;
  end;
  TR16_Set(E32, Src, SStep, Limit div 2);
  for I := 0 to 15 do
  begin
    Src[I * SStep] := av_clip_int16(SarLongint(E32[I] + O32[I] + Add, Shift));
    Src[(31 - I) * SStep] := av_clip_int16(SarLongint(E32[I] - O32[I] + Add, Shift));
  end;
end;

procedure idct_32x32_var(Coeffs: PInt16; ColLimit, BitDepth: Integer);
var
  I, Shift, Add, Limit, Limit2: Integer;
  Src: PInt16;
begin
  Shift := 7;
  Add := 1 shl (Shift - 1);
  Src := Coeffs;
  Limit := FFMIN(ColLimit, 32);
  Limit2 := FFMIN(ColLimit + 4, 32);
  for I := 0 to 31 do
  begin
    TR32_Body(Src, 32, Shift, Add, Limit2);
    if (Limit2 < 32) and (I mod 4 = 0) and (I <> 0) then Limit2 := Limit2 - 4;
    Inc(Src);
  end;
  Shift := 20 - BitDepth;
  Add := 1 shl (Shift - 1);
  for I := 0 to 31 do
  begin
    TR32_Body(Coeffs, 1, Shift, Add, Limit);
    Coeffs := Coeffs + 32;
  end;
end;

procedure idct(Idx: Integer; Coeffs: PInt16; ColLimit: Integer; BitDepth: Integer);
begin
  case Idx of
    0: idct_4x4_var(Coeffs, ColLimit, BitDepth);
    1: idct_8x8_var(Coeffs, ColLimit, BitDepth);
    2: idct_16x16_var(Coeffs, ColLimit, BitDepth);
  else
    idct_32x32_var(Coeffs, ColLimit, BitDepth);
  end;
end;

procedure idct_dc(Idx: Integer; Coeffs: PInt16; BitDepth: Integer);
var
  I, J, Shift, Add, Coeff, Size: Integer;
begin
  Size := 4 shl Idx;
  Shift := 14 - BitDepth;
  Add := 1 shl (Shift - 1);
  Coeff := SarLongint(SarLongint(Coeffs[0] + 1, 1) + Add, Shift);
  for J := 0 to Size - 1 do
    for I := 0 to Size - 1 do
      Coeffs[I + J * Size] := Int16(Coeff);
end;

// ---------------- SAO ----------------

procedure sao_band_filter(Dst, Src: PByte; StrideDst, StrideSrc: PtrInt;
  Sao: PSAOParams; Borders: PInteger; Width, Height, CIdx, BitDepth: Integer);
var
  D, S: PWord;
  offset_table: array[0..31] of Integer;
  K, Y, X, Shift, sao_left_class: Integer;
  sao_offset_val: PInt16;
begin
  D := PWord(Dst);
  S := PWord(Src);
  FillChar(offset_table, SizeOf(offset_table), 0);
  Shift := BitDepth - 5;
  sao_offset_val := @Sao^.offset_val[CIdx][0];
  sao_left_class := Sao^.band_position[CIdx];
  StrideDst := StrideDst div SizeOf(Word);
  StrideSrc := StrideSrc div SizeOf(Word);
  for K := 0 to 3 do
    offset_table[(K + sao_left_class) and 31] := sao_offset_val[K + 1];
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      D[X] := Word(av_clip_uintp2(S[X] + offset_table[S[X] shr Shift], BitDepth));
    D := D + StrideDst;
    S := S + StrideSrc;
  end;
end;

const
  sao_edge_idx: array[0..4] of Byte = (1, 2, 0, 3, 4);
  sao_pos: array[0..3, 0..1, 0..1] of Int8 = (
    ( ( -1, 0 ), ( 1, 0 ) ),
    ( ( 0, -1 ), ( 0, 1 ) ),
    ( ( -1, -1 ), ( 1, 1 ) ),
    ( ( 1, -1 ), ( -1, 1 ) )
  );

procedure sao_edge_filter_core(Dst, Src: PByte; StrideDst, StrideSrc: PtrInt;
  Sao: PSAOParams; Width, Height, CIdx, InitX, InitY, BitDepth: Integer);
var
  sao_offset_val: PInt16;
  sao_eo_class: Integer;
  D, S: PWord;
  y_stride_src, y_stride_dst: PtrInt;
  pos_0_0, pos_0_1, pos_1_0, pos_1_1: Integer;
  X, Y, diff0, diff1, offset_val: Integer;
  y_stride_0_1, y_stride_1_1: PtrInt;
  A, B: Integer;
begin
  sao_offset_val := @Sao^.offset_val[CIdx][0];
  sao_eo_class := Sao^.eo_class[CIdx];
  D := PWord(Dst);
  S := PWord(Src);
  y_stride_src := InitY * StrideSrc;
  y_stride_dst := InitY * StrideDst;
  pos_0_0 := sao_pos[sao_eo_class][0][0];
  pos_0_1 := sao_pos[sao_eo_class][0][1];
  pos_1_0 := sao_pos[sao_eo_class][1][0];
  pos_1_1 := sao_pos[sao_eo_class][1][1];
  y_stride_0_1 := (InitY + pos_0_1) * StrideSrc;
  y_stride_1_1 := (InitY + pos_1_1) * StrideSrc;
  for Y := InitY to Height - 1 do
  begin
    for X := InitX to Width - 1 do
    begin
      A := S[X + y_stride_src];
      B := S[X + pos_0_0 + y_stride_0_1];
      if A > B then diff0 := 1 else if A = B then diff0 := 0 else diff0 := -1;
      B := S[X + pos_1_0 + y_stride_1_1];
      if A > B then diff1 := 1 else if A = B then diff1 := 0 else diff1 := -1;
      offset_val := sao_edge_idx[2 + diff0 + diff1];
      D[X + y_stride_dst] := Word(av_clip_uintp2(A + sao_offset_val[offset_val], BitDepth));
    end;
    y_stride_src := y_stride_src + StrideSrc;
    y_stride_dst := y_stride_dst + StrideDst;
    y_stride_0_1 := y_stride_0_1 + StrideSrc;
    y_stride_1_1 := y_stride_1_1 + StrideSrc;
  end;
end;

procedure sao_edge_filter(Which: Integer; Dst, Src: PByte;
  StrideDst, StrideSrc: PtrInt; Sao: PSAOParams; Borders: PInteger;
  Width, Height, CIdx: Integer; VertEdge, HorizEdge, DiagEdge: PByte;
  BitDepth: Integer);
var
  X, Y: Integer;
  D, S: PWord;
  sao_offset_val: PInt16;
  sao_eo_class: Integer;
  InitX, InitY, W, H: Integer;
  offset_val, offset: Integer;
  y_stride_dst, y_stride_src: PtrInt;
  save_upper_left, save_upper_right, save_lower_right, save_lower_left: Integer;
begin
  D := PWord(Dst);
  S := PWord(Src);
  sao_offset_val := @Sao^.offset_val[CIdx][0];
  sao_eo_class := Sao^.eo_class[CIdx];
  InitX := 0;
  InitY := 0;
  W := Width;
  H := Height;
  StrideDst := StrideDst div SizeOf(Word);
  StrideSrc := StrideSrc div SizeOf(Word);

  if sao_eo_class <> SAO_EO_VERT then
  begin
    if Borders[0] <> 0 then
    begin
      offset_val := sao_offset_val[0];
      for Y := 0 to H - 1 do
        D[Y * StrideDst] := Word(av_clip_uintp2(S[Y * StrideSrc] + offset_val, BitDepth));
      InitX := 1;
    end;
    if Borders[2] <> 0 then
    begin
      offset_val := sao_offset_val[0];
      offset := W - 1;
      for X := 0 to H - 1 do
        D[X * StrideDst + offset] :=
          Word(av_clip_uintp2(S[X * StrideSrc + offset] + offset_val, BitDepth));
      Dec(W);
    end;
  end;
  if sao_eo_class <> SAO_EO_HORIZ then
  begin
    if Borders[1] <> 0 then
    begin
      offset_val := sao_offset_val[0];
      for X := InitX to W - 1 do
        D[X] := Word(av_clip_uintp2(S[X] + offset_val, BitDepth));
      InitY := 1;
    end;
    if Borders[3] <> 0 then
    begin
      offset_val := sao_offset_val[0];
      y_stride_dst := StrideDst * (H - 1);
      y_stride_src := StrideSrc * (H - 1);
      for X := InitX to W - 1 do
        D[X + y_stride_dst] :=
          Word(av_clip_uintp2(S[X + y_stride_src] + offset_val, BitDepth));
      Dec(H);
    end;
  end;

  // the reference passes the already-divided (element) strides here
  sao_edge_filter_core(PByte(D), PByte(S), StrideDst, StrideSrc,
    Sao, W, H, CIdx, InitX, InitY, BitDepth);

  if Which = 1 then
  begin
    save_upper_left := Ord((DiagEdge[0] = 0) and (sao_eo_class = SAO_EO_135D) and
      (Borders[0] = 0) and (Borders[1] = 0));
    save_upper_right := Ord((DiagEdge[1] = 0) and (sao_eo_class = SAO_EO_45D) and
      (Borders[1] = 0) and (Borders[2] = 0));
    save_lower_right := Ord((DiagEdge[2] = 0) and (sao_eo_class = SAO_EO_135D) and
      (Borders[2] = 0) and (Borders[3] = 0));
    save_lower_left := Ord((DiagEdge[3] = 0) and (sao_eo_class = SAO_EO_45D) and
      (Borders[0] = 0) and (Borders[3] = 0));

    if (VertEdge[0] <> 0) and (sao_eo_class <> SAO_EO_VERT) then
      for Y := InitY + save_upper_left to H - save_lower_left - 1 do
        D[Y * StrideDst] := S[Y * StrideSrc];
    if (VertEdge[1] <> 0) and (sao_eo_class <> SAO_EO_VERT) then
      for Y := InitY + save_upper_right to H - save_lower_right - 1 do
        D[Y * StrideDst + W - 1] := S[Y * StrideSrc + W - 1];
    if (HorizEdge[0] <> 0) and (sao_eo_class <> SAO_EO_HORIZ) then
      for X := InitX + save_upper_left to W - save_upper_right - 1 do
        D[X] := S[X];
    if (HorizEdge[1] <> 0) and (sao_eo_class <> SAO_EO_HORIZ) then
      for X := InitX + save_lower_left to W - save_lower_right - 1 do
        D[(H - 1) * StrideDst + X] := S[(H - 1) * StrideSrc + X];
    if (DiagEdge[0] <> 0) and (sao_eo_class = SAO_EO_135D) then
      D[0] := S[0];
    if (DiagEdge[1] <> 0) and (sao_eo_class = SAO_EO_45D) then
      D[W - 1] := S[W - 1];
    if (DiagEdge[2] <> 0) and (sao_eo_class = SAO_EO_135D) then
      D[StrideDst * (H - 1) + W - 1] := S[StrideSrc * (H - 1) + W - 1];
    if (DiagEdge[3] <> 0) and (sao_eo_class = SAO_EO_45D) then
      D[StrideDst * (H - 1)] := S[StrideSrc * (H - 1)];
  end;
end;

// ---------------- deblocking ----------------

procedure hevc_loop_filter_luma_var(PixB: PByte; XStrideB, YStrideB: PtrInt;
  Beta: Integer; TcArr: PInt32; NoPArr, NoQArr: PByte; BitDepth: Integer);
var
  D, J: Integer;
  Pix: PWord;
  XStride, YStride: PtrInt;
  dp0, dq0, dp3, dq3, d0, d3, Tc, no_p, no_q: Integer;
  beta_3, beta_2, tc25, tc2, tc_2: Integer;
  p3, p2, p1, p0, q0, q1, q2, q3: Integer;
  nd_p, nd_q, delta0, deltap1, deltaq1: Integer;
begin
  Pix := PWord(PixB);
  XStride := XStrideB div SizeOf(Word);
  YStride := YStrideB div SizeOf(Word);
  Beta := Beta shl (BitDepth - 8);
  for J := 0 to 1 do
  begin
    dp0 := Abs(Pix[-3 * XStride] - 2 * Pix[-2 * XStride] + Pix[-1 * XStride]);
    dq0 := Abs(Pix[2 * XStride] - 2 * Pix[1 * XStride] + Pix[0]);
    dp3 := Abs(Pix[-3 * XStride + 3 * YStride] - 2 * Pix[-2 * XStride + 3 * YStride] +
               Pix[-1 * XStride + 3 * YStride]);
    dq3 := Abs(Pix[2 * XStride + 3 * YStride] - 2 * Pix[1 * XStride + 3 * YStride] +
               Pix[3 * YStride]);
    d0 := dp0 + dq0;
    d3 := dp3 + dq3;
    Tc := TcArr[J] shl (BitDepth - 8);
    no_p := NoPArr[J];
    no_q := NoQArr[J];
    if d0 + d3 >= Beta then
    begin
      Pix := Pix + 4 * YStride;
      Continue;
    end;
    beta_3 := Beta shr 3;
    beta_2 := Beta shr 2;
    tc25 := (Tc * 5 + 1) shr 1;
    if (Abs(Pix[-4 * XStride] - Pix[-1 * XStride]) + Abs(Pix[3 * XStride] - Pix[0]) < beta_3) and
       (Abs(Pix[-1 * XStride] - Pix[0]) < tc25) and
       (Abs(Pix[-4 * XStride + 3 * YStride] - Pix[-1 * XStride + 3 * YStride]) +
        Abs(Pix[3 * XStride + 3 * YStride] - Pix[3 * YStride]) < beta_3) and
       (Abs(Pix[-1 * XStride + 3 * YStride] - Pix[3 * YStride]) < tc25) and
       ((d0 shl 1) < beta_2) and ((d3 shl 1) < beta_2) then
    begin
      tc2 := Tc shl 1;
      for D := 0 to 3 do
      begin
        p3 := Pix[-4 * XStride];
        p2 := Pix[-3 * XStride];
        p1 := Pix[-2 * XStride];
        p0 := Pix[-1 * XStride];
        q0 := Pix[0];
        q1 := Pix[1 * XStride];
        q2 := Pix[2 * XStride];
        q3 := Pix[3 * XStride];
        if no_p = 0 then
        begin
          Pix[-1 * XStride] := Word(p0 + av_clip_c(((p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) shr 3) - p0, -tc2, tc2));
          Pix[-2 * XStride] := Word(p1 + av_clip_c(((p2 + p1 + p0 + q0 + 2) shr 2) - p1, -tc2, tc2));
          Pix[-3 * XStride] := Word(p2 + av_clip_c(((2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) shr 3) - p2, -tc2, tc2));
        end;
        if no_q = 0 then
        begin
          Pix[0] := Word(q0 + av_clip_c(((p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) shr 3) - q0, -tc2, tc2));
          Pix[1 * XStride] := Word(q1 + av_clip_c(((p0 + q0 + q1 + q2 + 2) shr 2) - q1, -tc2, tc2));
          Pix[2 * XStride] := Word(q2 + av_clip_c(((2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) shr 3) - q2, -tc2, tc2));
        end;
        Pix := Pix + YStride;
      end;
    end
    else
    begin
      nd_p := 1;
      nd_q := 1;
      tc_2 := Tc shr 1;
      if dp0 + dp3 < ((Beta + (Beta shr 1)) shr 3) then nd_p := 2;
      if dq0 + dq3 < ((Beta + (Beta shr 1)) shr 3) then nd_q := 2;
      for D := 0 to 3 do
      begin
        p2 := Pix[-3 * XStride];
        p1 := Pix[-2 * XStride];
        p0 := Pix[-1 * XStride];
        q0 := Pix[0];
        q1 := Pix[1 * XStride];
        q2 := Pix[2 * XStride];
        delta0 := SarLongint(9 * (q0 - p0) - 3 * (q1 - p1) + 8, 4);
        if Abs(delta0) < 10 * Tc then
        begin
          delta0 := av_clip_c(delta0, -Tc, Tc);
          if no_p = 0 then Pix[-1 * XStride] := Word(av_clip_uintp2(p0 + delta0, BitDepth));
          if no_q = 0 then Pix[0] := Word(av_clip_uintp2(q0 - delta0, BitDepth));
          if (no_p = 0) and (nd_p > 1) then
          begin
            deltap1 := av_clip_c(SarLongint(((p2 + p0 + 1) shr 1) - p1 + delta0, 1), -tc_2, tc_2);
            Pix[-2 * XStride] := Word(av_clip_uintp2(p1 + deltap1, BitDepth));
          end;
          if (no_q = 0) and (nd_q > 1) then
          begin
            deltaq1 := av_clip_c(SarLongint(((q2 + q0 + 1) shr 1) - q1 - delta0, 1), -tc_2, tc_2);
            Pix[1 * XStride] := Word(av_clip_uintp2(q1 + deltaq1, BitDepth));
          end;
        end;
        Pix := Pix + YStride;
      end;
    end;
  end;
end;

procedure hevc_loop_filter_chroma_var(PixB: PByte; XStrideB, YStrideB: PtrInt;
  TcArr: PInt32; NoPArr, NoQArr: PByte; BitDepth: Integer);
var
  D, J, no_p, no_q, Tc: Integer;
  Pix: PWord;
  XStride, YStride: PtrInt;
  delta0, p1, p0, q0, q1: Integer;
begin
  Pix := PWord(PixB);
  XStride := XStrideB div SizeOf(Word);
  YStride := YStrideB div SizeOf(Word);
  for J := 0 to 1 do
  begin
    Tc := TcArr[J] shl (BitDepth - 8);
    if Tc <= 0 then
    begin
      Pix := Pix + 4 * YStride;
      Continue;
    end;
    no_p := NoPArr[J];
    no_q := NoQArr[J];
    for D := 0 to 3 do
    begin
      p1 := Pix[-2 * XStride];
      p0 := Pix[-1 * XStride];
      q0 := Pix[0];
      q1 := Pix[1 * XStride];
      delta0 := av_clip_c(SarLongint((q0 - p0) * 4 + p1 - q1 + 4, 3), -Tc, Tc);
      if no_p = 0 then Pix[-1 * XStride] := Word(av_clip_uintp2(p0 + delta0, BitDepth));
      if no_q = 0 then Pix[0] := Word(av_clip_uintp2(q0 - delta0, BitDepth));
      Pix := Pix + YStride;
    end;
  end;
end;

procedure hevc_h_loop_filter_luma(Pix: PByte; Stride: PtrInt; Beta: Integer;
  Tc: PInt32; NoP, NoQ: PByte; BitDepth: Integer);
begin
  hevc_loop_filter_luma_var(Pix, Stride, SizeOf(Word), Beta, Tc, NoP, NoQ, BitDepth);
end;

procedure hevc_v_loop_filter_luma(Pix: PByte; Stride: PtrInt; Beta: Integer;
  Tc: PInt32; NoP, NoQ: PByte; BitDepth: Integer);
begin
  hevc_loop_filter_luma_var(Pix, SizeOf(Word), Stride, Beta, Tc, NoP, NoQ, BitDepth);
end;

procedure hevc_h_loop_filter_chroma(Pix: PByte; Stride: PtrInt;
  Tc: PInt32; NoP, NoQ: PByte; BitDepth: Integer);
begin
  hevc_loop_filter_chroma_var(Pix, Stride, SizeOf(Word), Tc, NoP, NoQ, BitDepth);
end;

procedure hevc_v_loop_filter_chroma(Pix: PByte; Stride: PtrInt;
  Tc: PInt32; NoP, NoQ: PByte; BitDepth: Integer);
begin
  hevc_loop_filter_chroma_var(Pix, SizeOf(Word), Stride, Tc, NoP, NoQ, BitDepth);
end;

end.
