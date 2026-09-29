// BPG encoder -- Free Pascal
// CABAC syntax element writers: the mirror of the decoders in h265_hevc_cabac.
//
// Each writer takes the same THEVCContext the decoder uses, so context indices
// are derived by exactly the same expressions on both sides -- including the
// neighbour dependent ones such as split_cu_flag. The encoder keeps its own
// TCabacEncoder, but the context state array lives in HEVClc^.cabac_state, so
// ff_hevc_cabac_init initialises the encoder just as it does the decoder.
//
// Only the elements a BPG intra still picture needs are here; inter syntax is
// deliberately absent.
unit h265_syntax_enc;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}

interface

uses
  h265_common, h265_hevc_defs, h265_hevc_cabac, h265_cabac_enc;

procedure enc_sao_merge_flag(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
procedure enc_sao_type_idx(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
procedure enc_sao_offset_abs(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
procedure enc_sao_offset_sign(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
procedure enc_sao_band_position(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
procedure enc_sao_eo_class(S: PHEVCContext; var E: TCabacEncoder; V: Integer);

procedure enc_split_coding_unit_flag(S: PHEVCContext; var E: TCabacEncoder;
  CtDepth, X0, Y0, V: Integer);
// intra only: PART_2Nx2N or, at the minimum CU size, PART_NxN
procedure enc_part_mode_intra(S: PHEVCContext; var E: TCabacEncoder;
  Log2CbSize, PartMode: Integer);
procedure enc_cu_transquant_bypass_flag(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
procedure enc_cross_comp_pred(S: PHEVCContext; var E: TCabacEncoder; Idx, ScaleVal: Integer);

// How much one sample of a plane is worth in the metric this encoder is judged
// by, and the mean over the picture. The decisions are taken in YCbCr but the
// result is compared in RGB, and the inverse BT.601 spreads a chroma error over
// channels while subsampling spreads it over pixels:
//
// Y  -> 1 + 1 + 1                  = 3.000
// Cb -> 0 + 0.344136^2 + 1.772^2   = 3.258
// Cr -> 1.402^2 + 0.714136^2 + 0   = 2.476
//
// times the pixels one chroma sample covers. In 4:4:4 this encoder codes RGB
// directly, so every weight is 1.
//
// These live here because FOUR separate sites compute a rate-distortion cost
// and every one of them needs the same pair: the plane weight on its
// distortion, the mean on its lambda. Keeping one copy is the point.
function plane_weight(S: PHEVCContext; CIdx: Integer): Double;
function mean_weight(S: PHEVCContext): Double;
procedure enc_prev_intra_luma_pred_flag(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
procedure enc_mpm_idx(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
procedure enc_rem_intra_luma_pred_mode(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
procedure enc_intra_chroma_pred_mode(S: PHEVCContext; var E: TCabacEncoder; V: Integer);

procedure enc_split_transform_flag(S: PHEVCContext; var E: TCabacEncoder;
  Log2TrafoSize, V: Integer);
procedure enc_cbf_cb_cr(S: PHEVCContext; var E: TCabacEncoder; TrafoDepth, V: Integer);
procedure enc_cbf_luma(S: PHEVCContext; var E: TCabacEncoder; TrafoDepth, V: Integer);

procedure enc_end_of_slice_flag(S: PHEVCContext; var E: TCabacEncoder; V: Integer);

implementation

function plane_weight(S: PHEVCContext; CIdx: Integer): Double;
begin
  Result := 1.0;
  if (CIdx = 0) or (S^.sps^.chroma_format_idc = 3) then Exit;
  if CIdx = 1 then Result := 3.258 / 3.0 else Result := 2.476 / 3.0;
  Result := Result * (1 shl (S^.sps^.hshift[CIdx] + S^.sps^.vshift[CIdx]));
end;

function mean_weight(S: PHEVCContext): Double;
begin
  case S^.sps^.chroma_format_idc of
    1: Result := 1.941;
    2: Result := 1.456;
  else
    Result := 1.0;
  end;
end;

function Ctx(S: PHEVCContext; Idx: Integer): PByte; inline;
begin
  Result := @S^.HEVClc^.cabac_state[Idx];
end;

procedure enc_sao_merge_flag(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
begin
  cabac_enc_bin(E, Ctx(S, hevc_elem_offset(SAO_MERGE_FLAG)), V);
end;

procedure enc_sao_type_idx(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
begin
  // 0 = not applied, SAO_BAND, SAO_EDGE
  if V = 0 then
  begin
    cabac_enc_bin(E, Ctx(S, hevc_elem_offset(SAO_TYPE_IDX)), 0);
    Exit;
  end;
  cabac_enc_bin(E, Ctx(S, hevc_elem_offset(SAO_TYPE_IDX)), 1);
  cabac_enc_bypass(E, Ord(V = SAO_EDGE));
end;

procedure enc_sao_offset_abs(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
var
  I, Length_: Integer;
begin
  // truncated rice, all bypass
  Length_ := (1 shl (FFMIN(S^.sps^.bit_depth, 10) - 5)) - 1;
  for I := 0 to V - 1 do
    cabac_enc_bypass(E, 1);
  if V < Length_ then
    cabac_enc_bypass(E, 0);
end;

procedure enc_sao_offset_sign(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
begin
  cabac_enc_bypass(E, V);
end;

procedure enc_sao_band_position(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
begin
  cabac_enc_bypass_bits(E, 5, Cardinal(V));
end;

procedure enc_sao_eo_class(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
begin
  cabac_enc_bypass_bits(E, 2, Cardinal(V));
end;

procedure enc_split_coding_unit_flag(S: PHEVCContext; var E: TCabacEncoder;
  CtDepth, X0, Y0, V: Integer);
var
  IncV, depth_left, depth_top, x0b, y0b, x_cb, y_cb: Integer;
begin
  // identical derivation to ff_hevc_split_coding_unit_flag_decode
  IncV := 0;
  depth_left := 0;
  depth_top := 0;
  x0b := X0 and ((1 shl S^.sps^.log2_ctb_size) - 1);
  y0b := Y0 and ((1 shl S^.sps^.log2_ctb_size) - 1);
  x_cb := X0 shr S^.sps^.log2_min_cb_size;
  y_cb := Y0 shr S^.sps^.log2_min_cb_size;
  if (S^.HEVClc^.ctb_left_flag <> 0) or (x0b <> 0) then
    depth_left := S^.tab_ct_depth[y_cb * S^.sps^.min_cb_width + x_cb - 1];
  if (S^.HEVClc^.ctb_up_flag <> 0) or (y0b <> 0) then
    depth_top := S^.tab_ct_depth[(y_cb - 1) * S^.sps^.min_cb_width + x_cb];
  IncV := IncV + Ord(depth_left > CtDepth);
  IncV := IncV + Ord(depth_top > CtDepth);
  cabac_enc_bin(E, Ctx(S, hevc_elem_offset(SPLIT_CODING_UNIT_FLAG) + IncV), V);
end;

procedure enc_part_mode_intra(S: PHEVCContext; var E: TCabacEncoder;
  Log2CbSize, PartMode: Integer);
begin
  if PartMode = PART_2Nx2N then
  begin
    cabac_enc_bin(E, Ctx(S, hevc_elem_offset(PART_MODE)), 1);
    Exit;
  end;
  // PART_NxN is only legal for an intra CU at the minimum size, where the
  // decoder returns it after a single zero bin
  cabac_enc_bin(E, Ctx(S, hevc_elem_offset(PART_MODE)), 0);
end;

// log2_res_scale_abs_plus1 as truncated unary capped at 4, then the sign.
// ScaleVal is the signed res_scale_val the decoder will reconstruct: 0 means
// the prediction is off for this plane, otherwise +-1, +-2, +-4 or +-8.
procedure enc_cross_comp_pred(S: PHEVCContext; var E: TCabacEncoder; Idx, ScaleVal: Integer);
var
  I, Mag, Plus1: Integer;
begin
  Mag := Abs(ScaleVal);
  if Mag = 0 then Plus1 := 0
  else if Mag = 1 then Plus1 := 1
  else if Mag = 2 then Plus1 := 2
  else if Mag = 4 then Plus1 := 3
  else Plus1 := 4;
  for I := 0 to Plus1 - 1 do
    cabac_enc_bin(E, Ctx(S, hevc_elem_offset(LOG2_RES_SCALE_ABS) + 4 * Idx + I), 1);
  if Plus1 < 4 then
    cabac_enc_bin(E, Ctx(S, hevc_elem_offset(LOG2_RES_SCALE_ABS) + 4 * Idx + Plus1), 0);
  if Plus1 <> 0 then
    cabac_enc_bin(E, Ctx(S, hevc_elem_offset(RES_SCALE_SIGN_FLAG) + Idx),
                  Ord(ScaleVal < 0));
end;

procedure enc_cu_transquant_bypass_flag(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
begin
  cabac_enc_bin(E, Ctx(S, hevc_elem_offset(CU_TRANSQUANT_BYPASS_FLAG)), V);
end;

procedure enc_prev_intra_luma_pred_flag(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
begin
  cabac_enc_bin(E, Ctx(S, hevc_elem_offset(PREV_INTRA_LUMA_PRED_FLAG)), V);
end;

procedure enc_mpm_idx(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
var
  I: Integer;
begin
  // truncated unary, cMax = 2, all bypass
  for I := 0 to V - 1 do
    cabac_enc_bypass(E, 1);
  if V < 2 then
    cabac_enc_bypass(E, 0);
end;

procedure enc_rem_intra_luma_pred_mode(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
begin
  cabac_enc_bypass_bits(E, 5, Cardinal(V));
end;

procedure enc_intra_chroma_pred_mode(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
begin
  if V = 4 then
  begin
    cabac_enc_bin(E, Ctx(S, hevc_elem_offset(INTRA_CHROMA_PRED_MODE)), 0);
    Exit;
  end;
  cabac_enc_bin(E, Ctx(S, hevc_elem_offset(INTRA_CHROMA_PRED_MODE)), 1);
  cabac_enc_bypass_bits(E, 2, Cardinal(V));
end;

procedure enc_split_transform_flag(S: PHEVCContext; var E: TCabacEncoder;
  Log2TrafoSize, V: Integer);
begin
  cabac_enc_bin(E, Ctx(S, hevc_elem_offset(SPLIT_TRANSFORM_FLAG) + 5 - Log2TrafoSize), V);
end;

procedure enc_cbf_cb_cr(S: PHEVCContext; var E: TCabacEncoder; TrafoDepth, V: Integer);
begin
  cabac_enc_bin(E, Ctx(S, hevc_elem_offset(CBF_CB_CR) + TrafoDepth), V);
end;

procedure enc_cbf_luma(S: PHEVCContext; var E: TCabacEncoder; TrafoDepth, V: Integer);
begin
  cabac_enc_bin(E, Ctx(S, hevc_elem_offset(CBF_LUMA) + Ord(TrafoDepth = 0)), V);
end;

procedure enc_end_of_slice_flag(S: PHEVCContext; var E: TCabacEncoder; V: Integer);
begin
  cabac_enc_terminate(E, V);
end;

end.
