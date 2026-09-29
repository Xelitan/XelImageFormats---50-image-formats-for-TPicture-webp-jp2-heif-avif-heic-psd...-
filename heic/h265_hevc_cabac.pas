// BPG decoder -- Free Pascal port of libbpg 0.9.8
// CABAC syntax-element decoding, including residual coding.
// Corresponds to: libavcodec/hevc_cabac.c
//
// libbpg always runs single-threaded, so the threads_number branches of
// ff_hevc_cabac_init() collapse to the cabac_reinit() path.
unit h265_hevc_cabac;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  h265_common, h265_bits, h265_cabac, h265_cabac_enc, h265_hevc_defs, h265_hevcdsp, h265_scan;

{$i cabac_tables.inc}

procedure ff_hevc_save_states(S: PHEVCContext; CtbAddrTs: Integer);
procedure ff_hevc_cabac_init(S: PHEVCContext; CtbAddrTs: Integer);

// Base context index of a syntax element, indexed by the SAO_MERGE_FLAG..
// CU_CHROMA_QP_OFFSET_IDX constants. Exported so the encoder in h265_syntax_enc
// derives context indices with the very same table.
function hevc_elem_offset(Idx: Integer): Integer; inline;

function ff_hevc_sao_merge_flag_decode(S: PHEVCContext): Integer;
function ff_hevc_sao_type_idx_decode(S: PHEVCContext): Integer;
function ff_hevc_sao_band_position_decode(S: PHEVCContext): Integer;
function ff_hevc_sao_offset_abs_decode(S: PHEVCContext): Integer;
function ff_hevc_sao_offset_sign_decode(S: PHEVCContext): Integer;
function ff_hevc_sao_eo_class_decode(S: PHEVCContext): Integer;
function ff_hevc_end_of_slice_flag_decode(S: PHEVCContext): Integer;
function ff_hevc_cu_transquant_bypass_flag_decode(S: PHEVCContext): Integer;
function ff_hevc_skip_flag_decode(S: PHEVCContext; X0, Y0, XCb, YCb: Integer): Integer;
function ff_hevc_cu_qp_delta_abs(S: PHEVCContext): Integer;
function ff_hevc_cu_qp_delta_sign_flag(S: PHEVCContext): Integer;
function ff_hevc_cu_chroma_qp_offset_flag(S: PHEVCContext): Integer;
function ff_hevc_cu_chroma_qp_offset_idx(S: PHEVCContext): Integer;
function ff_hevc_pred_mode_decode(S: PHEVCContext): Integer;
function ff_hevc_split_coding_unit_flag_decode(S: PHEVCContext; CtDepth, X0, Y0: Integer): Integer;
function ff_hevc_part_mode_decode(S: PHEVCContext; Log2CbSize: Integer): Integer;
function ff_hevc_pcm_flag_decode(S: PHEVCContext): Integer;
function ff_hevc_prev_intra_luma_pred_flag_decode(S: PHEVCContext): Integer;
function ff_hevc_mpm_idx_decode(S: PHEVCContext): Integer;
function ff_hevc_rem_intra_luma_pred_mode_decode(S: PHEVCContext): Integer;
function ff_hevc_intra_chroma_pred_mode_decode(S: PHEVCContext): Integer;
function ff_hevc_merge_idx_decode(S: PHEVCContext): Integer;
function ff_hevc_merge_flag_decode(S: PHEVCContext): Integer;
function ff_hevc_inter_pred_idc_decode(S: PHEVCContext; nPbW, nPbH: Integer): Integer;
function ff_hevc_ref_idx_lx_decode(S: PHEVCContext; NumRefIdxLx: Integer): Integer;
function ff_hevc_mvp_lx_flag_decode(S: PHEVCContext): Integer;
function ff_hevc_no_residual_syntax_flag_decode(S: PHEVCContext): Integer;
function ff_hevc_split_transform_flag_decode(S: PHEVCContext; Log2TrafoSize: Integer): Integer;
function ff_hevc_cbf_cb_cr_decode(S: PHEVCContext; TrafoDepth: Integer): Integer;
function ff_hevc_cbf_luma_decode(S: PHEVCContext; TrafoDepth: Integer): Integer;
function ff_hevc_log2_res_scale_abs(S: PHEVCContext; Idx: Integer): Integer;
function ff_hevc_res_scale_sign_flag(S: PHEVCContext; Idx: Integer): Integer;

procedure ff_hevc_hls_residual_coding(S: PHEVCContext; X0, Y0, Log2TrafoSize,
  ScanIdx, CIdx: Integer);
procedure ff_hevc_hls_mvd_coding(S: PHEVCContext; X0, Y0, Log2CbSize: Integer);

// Resets the context states for a new slice. ff_hevc_cabac_init also attaches
// the arithmetic decoder to a bitstream, which the encoder must not do.
procedure ff_hevc_cabac_init_enc(S: PHEVCContext);

// Test hook. When set, ff_hevc_hls_residual_coding copies the dequantised
// coefficients here and returns without reconstructing, so a round-trip test
// can compare them against what the encoder fed in. Nil in normal operation.
var
  residual_capture: PInt16 = nil;

// encoder counterpart, see residual_enc.inc
// exposed for t_residual: the two helpers whose maths is derived, not mirrored
procedure split_last_sig_test(V: Integer; out Prefix, Suffix, SuffixLen: Integer);
procedure enc_coeff_abs_level_remaining_test(var E: TCabacEncoder;
  Value, RcRiceParam: Integer);
procedure ff_hevc_hls_residual_coding_enc(S: PHEVCContext; var E: TCabacEncoder;
  Coeffs: PInt16; Log2TrafoSize, ScanIdx, CIdx: Integer; TSkip: Integer = 0);
// parity pre-pass for sign data hiding; must run before the encoder-side
// reconstruction of the block
procedure sign_hide_adjust(S: PHEVCContext; Coeffs, PreQ: PInt16;
  Log2TrafoSize, ScanIdx, QpUsed: Integer);
// the scan-table selection of ff_hevc_hls_residual_coding, exported for the
// encoder's coefficient-level RD passes
procedure enc_scan_tables(Log2TrafoSize, ScanIdx: Integer;
  out ScanXCg, ScanYCg, ScanXOff, ScanYOff: PByte);

implementation

function CtxPtr(S: PHEVCContext; Idx: Integer): PByte; inline;
begin
  Result := @S^.HEVClc^.cabac_state[Idx];
end;

procedure ff_hevc_save_states(S: PHEVCContext; CtbAddrTs: Integer);
begin
  if (S^.pps^.entropy_coding_sync_enabled_flag <> 0) and
     ((CtbAddrTs mod S^.sps^.ctb_width = 2) or
      ((S^.sps^.ctb_width = 2) and (CtbAddrTs mod S^.sps^.ctb_width = 0))) then
    Move(S^.HEVClc^.cabac_state[0], S^.cabac_state^, 199);
end;

procedure load_states(S: PHEVCContext);
begin
  Move(S^.cabac_state^, S^.HEVClc^.cabac_state[0], 199);
end;

procedure cabac_reinit(LC: PHEVCLocalContext);
begin
  skip_bytes(LC^.cc, 0);
end;

procedure cabac_init_decoder(S: PHEVCContext);
var
  GB: PGetBitContext;
begin
  GB := @S^.HEVClc^.gb;
  skip_bits(GB^, 1);
  align_get_bits(GB^);
  ff_init_cabac_decoder(S^.HEVClc^.cc, GB^.Buffer + (get_bits_count(GB^) div 8),
    (get_bits_left(GB^) + 7) div 8);
end;

procedure cabac_init_state(S: PHEVCContext);
var
  init_type, I, init_value, M, N, Pre: Integer;
begin
  init_type := 2 - S^.sh.slice_type;
  if (S^.sh.cabac_init_flag <> 0) and (S^.sh.slice_type <> I_SLICE) then
    init_type := init_type xor 3;
  for I := 0 to 198 do
  begin
    init_value := init_values[init_type][I];
    M := (init_value shr 4) * 5 - 45;
    N := ((init_value and 15) shl 3) - 16;
    Pre := 2 * (SarLongint(M * av_clip_c(S^.sh.slice_qp, 0, 51), 4) + N) - 127;
    Pre := Pre xor SarLongint(Pre, 31);
    if Pre > 124 then Pre := 124 + (Pre and 1);
    S^.HEVClc^.cabac_state[I] := Byte(Pre);
  end;
  for I := 0 to 3 do
    S^.HEVClc^.stat_coeff[I] := 0;
end;

function hevc_elem_offset(Idx: Integer): Integer;
begin
  Result := elem_offset[Idx];
end;

procedure ff_hevc_cabac_init(S: PHEVCContext; CtbAddrTs: Integer);
begin
  if CtbAddrTs = S^.pps^.ctb_addr_rs_to_ts[S^.sh.slice_ctb_addr_rs] then
  begin
    cabac_init_decoder(S);
    if (S^.sh.dependent_slice_segment_flag = 0) or
       ((S^.pps^.tiles_enabled_flag <> 0) and
        (S^.pps^.tile_id[CtbAddrTs] <> S^.pps^.tile_id[CtbAddrTs - 1])) then
      cabac_init_state(S);
    if (S^.sh.first_slice_in_pic_flag = 0) and
       (S^.pps^.entropy_coding_sync_enabled_flag <> 0) then
    begin
      if CtbAddrTs mod S^.sps^.ctb_width = 0 then
      begin
        if S^.sps^.ctb_width = 1 then
          cabac_init_state(S)
        else if S^.sh.dependent_slice_segment_flag = 1 then
          load_states(S);
      end;
    end;
  end
  else
  begin
    if (S^.pps^.tiles_enabled_flag <> 0) and
       (S^.pps^.tile_id[CtbAddrTs] <> S^.pps^.tile_id[CtbAddrTs - 1]) then
    begin
      cabac_reinit(S^.HEVClc);
      cabac_init_state(S);
    end;
    if S^.pps^.entropy_coding_sync_enabled_flag <> 0 then
    begin
      if CtbAddrTs mod S^.sps^.ctb_width = 0 then
      begin
        get_cabac_terminate(S^.HEVClc^.cc);
        cabac_reinit(S^.HEVClc);
        if S^.sps^.ctb_width = 1 then
          cabac_init_state(S)
        else
          load_states(S);
      end;
    end;
  end;
end;

function ff_hevc_sao_merge_flag_decode(S: PHEVCContext): Integer;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[SAO_MERGE_FLAG]));
end;

function ff_hevc_sao_type_idx_decode(S: PHEVCContext): Integer;
begin
  if get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[SAO_TYPE_IDX])) = 0 then Exit(0);
  if get_cabac_bypass(S^.HEVClc^.cc) = 0 then Exit(SAO_BAND);
  Result := SAO_EDGE;
end;

function ff_hevc_sao_band_position_decode(S: PHEVCContext): Integer;
var
  I, Value: Integer;
begin
  Value := get_cabac_bypass(S^.HEVClc^.cc);
  for I := 0 to 3 do
    Value := (Value shl 1) or get_cabac_bypass(S^.HEVClc^.cc);
  Result := Value;
end;

function ff_hevc_sao_offset_abs_decode(S: PHEVCContext): Integer;
var
  I, Length_: Integer;
begin
  I := 0;
  Length_ := (1 shl (FFMIN(S^.sps^.bit_depth, 10) - 5)) - 1;
  while (I < Length_) and (get_cabac_bypass(S^.HEVClc^.cc) <> 0) do
    Inc(I);
  Result := I;
end;

function ff_hevc_sao_offset_sign_decode(S: PHEVCContext): Integer;
begin
  Result := get_cabac_bypass(S^.HEVClc^.cc);
end;

function ff_hevc_sao_eo_class_decode(S: PHEVCContext): Integer;
begin
  Result := get_cabac_bypass(S^.HEVClc^.cc) shl 1;
  Result := Result or get_cabac_bypass(S^.HEVClc^.cc);
end;

function ff_hevc_end_of_slice_flag_decode(S: PHEVCContext): Integer;
begin
  Result := get_cabac_terminate(S^.HEVClc^.cc);
end;

function ff_hevc_cu_transquant_bypass_flag_decode(S: PHEVCContext): Integer;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[CU_TRANSQUANT_BYPASS_FLAG]));
end;

function ff_hevc_skip_flag_decode(S: PHEVCContext; X0, Y0, XCb, YCb: Integer): Integer;
var
  min_cb_width, IncV, x0b, y0b: Integer;
begin
  min_cb_width := S^.sps^.min_cb_width;
  IncV := 0;
  x0b := X0 and ((1 shl S^.sps^.log2_ctb_size) - 1);
  y0b := Y0 and ((1 shl S^.sps^.log2_ctb_size) - 1);
  if (S^.HEVClc^.ctb_left_flag <> 0) or (x0b <> 0) then
    IncV := Ord(S^.skip_flag[YCb * min_cb_width + XCb - 1] <> 0);
  if (S^.HEVClc^.ctb_up_flag <> 0) or (y0b <> 0) then
    IncV := IncV + Ord(S^.skip_flag[(YCb - 1) * min_cb_width + XCb] <> 0);
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[SKIP_FLAG] + IncV));
end;

function ff_hevc_cu_qp_delta_abs(S: PHEVCContext): Integer;
var
  prefix_val, suffix_val, IncV, K: Integer;
begin
  prefix_val := 0;
  suffix_val := 0;
  IncV := 0;
  while (prefix_val < 5) and
        (get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[CU_QP_DELTA] + IncV)) <> 0) do
  begin
    Inc(prefix_val);
    IncV := 1;
  end;
  if prefix_val >= 5 then
  begin
    K := 0;
    while (K < 31) and (get_cabac_bypass(S^.HEVClc^.cc) <> 0) do
    begin
      suffix_val := suffix_val + (1 shl K);
      Inc(K);
    end;
    while K > 0 do
    begin
      Dec(K);
      suffix_val := suffix_val + (get_cabac_bypass(S^.HEVClc^.cc) shl K);
    end;
  end;
  Result := prefix_val + suffix_val;
end;

function ff_hevc_cu_qp_delta_sign_flag(S: PHEVCContext): Integer;
begin
  Result := get_cabac_bypass(S^.HEVClc^.cc);
end;

function ff_hevc_cu_chroma_qp_offset_flag(S: PHEVCContext): Integer;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[CU_CHROMA_QP_OFFSET_FLAG]));
end;

function ff_hevc_cu_chroma_qp_offset_idx(S: PHEVCContext): Integer;
var
  c_max, I: Integer;
begin
  c_max := FFMAX(5, S^.pps^.chroma_qp_offset_list_len_minus1);
  I := 0;
  while (I < c_max) and
        (get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[CU_CHROMA_QP_OFFSET_IDX])) <> 0) do
    Inc(I);
  Result := I;
end;

function ff_hevc_pred_mode_decode(S: PHEVCContext): Integer;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[PRED_MODE_FLAG]));
end;

function ff_hevc_split_coding_unit_flag_decode(S: PHEVCContext; CtDepth, X0, Y0: Integer): Integer;
var
  IncV, depth_left, depth_top, x0b, y0b, x_cb, y_cb: Integer;
begin
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
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[SPLIT_CODING_UNIT_FLAG] + IncV));
end;

function ff_hevc_part_mode_decode(S: PHEVCContext; Log2CbSize: Integer): Integer;
begin
  if get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[PART_MODE])) <> 0 then Exit(PART_2Nx2N);
  if Log2CbSize = Integer(S^.sps^.log2_min_cb_size) then
  begin
    if S^.HEVClc^.cu.pred_mode = MODE_INTRA then Exit(PART_NxN);
    if get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[PART_MODE] + 1)) <> 0 then Exit(PART_2NxN);
    if Log2CbSize = 3 then Exit(PART_Nx2N);
    if get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[PART_MODE] + 2)) <> 0 then Exit(PART_Nx2N);
    Exit(PART_NxN);
  end;
  if S^.sps^.amp_enabled_flag = 0 then
  begin
    if get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[PART_MODE] + 1)) <> 0 then Exit(PART_2NxN);
    Exit(PART_Nx2N);
  end;
  if get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[PART_MODE] + 1)) <> 0 then
  begin
    if get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[PART_MODE] + 3)) <> 0 then Exit(PART_2NxN);
    if get_cabac_bypass(S^.HEVClc^.cc) <> 0 then Exit(PART_2NxnD);
    Exit(PART_2NxnU);
  end;
  if get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[PART_MODE] + 3)) <> 0 then Exit(PART_Nx2N);
  if get_cabac_bypass(S^.HEVClc^.cc) <> 0 then Exit(PART_nRx2N);
  Result := PART_nLx2N;
end;

function ff_hevc_pcm_flag_decode(S: PHEVCContext): Integer;
begin
  Result := get_cabac_terminate(S^.HEVClc^.cc);
end;

function ff_hevc_prev_intra_luma_pred_flag_decode(S: PHEVCContext): Integer;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[PREV_INTRA_LUMA_PRED_FLAG]));
end;

function ff_hevc_mpm_idx_decode(S: PHEVCContext): Integer;
var
  I: Integer;
begin
  I := 0;
  while (I < 2) and (get_cabac_bypass(S^.HEVClc^.cc) <> 0) do Inc(I);
  Result := I;
end;

function ff_hevc_rem_intra_luma_pred_mode_decode(S: PHEVCContext): Integer;
var
  I, Value: Integer;
begin
  Value := get_cabac_bypass(S^.HEVClc^.cc);
  for I := 0 to 3 do
    Value := (Value shl 1) or get_cabac_bypass(S^.HEVClc^.cc);
  Result := Value;
end;

function ff_hevc_intra_chroma_pred_mode_decode(S: PHEVCContext): Integer;
begin
  if get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[INTRA_CHROMA_PRED_MODE])) = 0 then
    Exit(4);
  Result := get_cabac_bypass(S^.HEVClc^.cc) shl 1;
  Result := Result or get_cabac_bypass(S^.HEVClc^.cc);
end;

function ff_hevc_merge_idx_decode(S: PHEVCContext): Integer;
var
  I: Integer;
begin
  I := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[MERGE_IDX]));
  if I <> 0 then
    while (Cardinal(I) < S^.sh.max_num_merge_cand - 1) and
          (get_cabac_bypass(S^.HEVClc^.cc) <> 0) do
      Inc(I);
  Result := I;
end;

function ff_hevc_merge_flag_decode(S: PHEVCContext): Integer;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[MERGE_FLAG]));
end;

function ff_hevc_inter_pred_idc_decode(S: PHEVCContext; nPbW, nPbH: Integer): Integer;
begin
  if nPbW + nPbH = 12 then
    Exit(get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[INTER_PRED_IDC] + 4)));
  if get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[INTER_PRED_IDC] + S^.HEVClc^.ct_depth)) <> 0 then
    Exit(PRED_BI);
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[INTER_PRED_IDC] + 4));
end;

function ff_hevc_ref_idx_lx_decode(S: PHEVCContext; NumRefIdxLx: Integer): Integer;
var
  I, Max, MaxCtx: Integer;
begin
  I := 0;
  Max := NumRefIdxLx - 1;
  MaxCtx := FFMIN(Max, 2);
  while (I < MaxCtx) and
        (get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[REF_IDX_L0] + I)) <> 0) do
    Inc(I);
  if I = 2 then
    while (I < Max) and (get_cabac_bypass(S^.HEVClc^.cc) <> 0) do Inc(I);
  Result := I;
end;

function ff_hevc_mvp_lx_flag_decode(S: PHEVCContext): Integer;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[MVP_LX_FLAG]));
end;

function ff_hevc_no_residual_syntax_flag_decode(S: PHEVCContext): Integer;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[NO_RESIDUAL_DATA_FLAG]));
end;

function abs_mvd_greater0_flag_decode(S: PHEVCContext): Integer; inline;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[ABS_MVD_GREATER0_FLAG]));
end;

function abs_mvd_greater1_flag_decode(S: PHEVCContext): Integer; inline;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[ABS_MVD_GREATER1_FLAG] + 1));
end;

function mvd_decode(S: PHEVCContext): Integer;
var
  Ret, K: Integer;
begin
  Ret := 2;
  K := 1;
  while (K < 31) and (get_cabac_bypass(S^.HEVClc^.cc) <> 0) do
  begin
    Ret := Ret + (1 shl K);
    Inc(K);
  end;
  while K > 0 do
  begin
    Dec(K);
    Ret := Ret + (get_cabac_bypass(S^.HEVClc^.cc) shl K);
  end;
  Result := get_cabac_bypass_sign(S^.HEVClc^.cc, -Ret);
end;

function mvd_sign_flag_decode(S: PHEVCContext): Integer; inline;
begin
  Result := get_cabac_bypass_sign(S^.HEVClc^.cc, -1);
end;

function ff_hevc_split_transform_flag_decode(S: PHEVCContext; Log2TrafoSize: Integer): Integer;
begin
  Result := get_cabac(S^.HEVClc^.cc,
    CtxPtr(S, elem_offset[SPLIT_TRANSFORM_FLAG] + 5 - Log2TrafoSize));
end;

function ff_hevc_cbf_cb_cr_decode(S: PHEVCContext; TrafoDepth: Integer): Integer;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[CBF_CB_CR] + TrafoDepth));
end;

function ff_hevc_cbf_luma_decode(S: PHEVCContext; TrafoDepth: Integer): Integer;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[CBF_LUMA] + Ord(TrafoDepth = 0)));
end;

function transform_skip_flag_decode(S: PHEVCContext; CIdx: Integer): Integer; inline;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[TRANSFORM_SKIP_FLAG] + Ord(CIdx <> 0)));
end;

function explicit_rdpcm_flag_decode(S: PHEVCContext; CIdx: Integer): Integer; inline;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[EXPLICIT_RDPCM_FLAG] + Ord(CIdx <> 0)));
end;

function explicit_rdpcm_dir_flag_decode(S: PHEVCContext; CIdx: Integer): Integer; inline;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[EXPLICIT_RDPCM_DIR_FLAG] + Ord(CIdx <> 0)));
end;

function ff_hevc_log2_res_scale_abs(S: PHEVCContext; Idx: Integer): Integer;
var
  I: Integer;
begin
  I := 0;
  while (I < 4) and
        (get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[LOG2_RES_SCALE_ABS] + 4 * Idx + I)) <> 0) do
    Inc(I);
  Result := I;
end;

function ff_hevc_res_scale_sign_flag(S: PHEVCContext; Idx: Integer): Integer;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[RES_SCALE_SIGN_FLAG] + Idx));
end;

procedure last_significant_coeff_xy_prefix_decode(S: PHEVCContext; CIdx, Log2Size: Integer;
  out LastScxPrefix, LastScyPrefix: Integer);
var
  I, Max, ctx_offset, ctx_shift: Integer;
begin
  I := 0;
  Max := (Log2Size shl 1) - 1;
  if CIdx = 0 then
  begin
    ctx_offset := 3 * (Log2Size - 2) + ((Log2Size - 1) shr 2);
    ctx_shift := (Log2Size + 1) shr 2;
  end
  else
  begin
    ctx_offset := 15;
    ctx_shift := Log2Size - 2;
  end;
  while (I < Max) and
        (get_cabac(S^.HEVClc^.cc,
          CtxPtr(S, elem_offset[LAST_SIGNIFICANT_COEFF_X_PREFIX] + (I shr ctx_shift) + ctx_offset)) <> 0) do
    Inc(I);
  LastScxPrefix := I;
  I := 0;
  while (I < Max) and
        (get_cabac(S^.HEVClc^.cc,
          CtxPtr(S, elem_offset[LAST_SIGNIFICANT_COEFF_Y_PREFIX] + (I shr ctx_shift) + ctx_offset)) <> 0) do
    Inc(I);
  LastScyPrefix := I;
end;

function last_significant_coeff_suffix_decode(S: PHEVCContext; Prefix: Integer): Integer;
var
  I, Length_, Value: Integer;
begin
  Length_ := (Prefix shr 1) - 1;
  Value := get_cabac_bypass(S^.HEVClc^.cc);
  for I := 1 to Length_ - 1 do
    Value := (Value shl 1) or get_cabac_bypass(S^.HEVClc^.cc);
  Result := Value;
end;

function significant_coeff_group_flag_decode(S: PHEVCContext; CIdx, CtxCg: Integer): Integer; inline;
var
  IncV: Integer;
begin
  IncV := FFMIN(CtxCg, 1);
  if CIdx > 0 then IncV := IncV + 2;
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[SIGNIFICANT_COEFF_GROUP_FLAG] + IncV));
end;

function significant_coeff_flag_decode(S: PHEVCContext; XC, YC, Offset: Integer;
  CtxIdxMap: PByte): Integer; inline;
var
  IncV: Integer;
begin
  IncV := CtxIdxMap[(YC shl 2) + XC] + Offset;
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[SIGNIFICANT_COEFF_FLAG] + IncV));
end;

function significant_coeff_flag_decode_0(S: PHEVCContext; CIdx, Offset: Integer): Integer; inline;
begin
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[SIGNIFICANT_COEFF_FLAG] + Offset));
end;

function coeff_abs_level_greater1_flag_decode(S: PHEVCContext; CIdx, Inc_: Integer): Integer; inline;
begin
  if CIdx > 0 then Inc_ := Inc_ + 16;
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[COEFF_ABS_LEVEL_GREATER1_FLAG] + Inc_));
end;

function coeff_abs_level_greater2_flag_decode(S: PHEVCContext; CIdx, Inc_: Integer): Integer; inline;
begin
  if CIdx > 0 then Inc_ := Inc_ + 4;
  Result := get_cabac(S^.HEVClc^.cc, CtxPtr(S, elem_offset[COEFF_ABS_LEVEL_GREATER2_FLAG] + Inc_));
end;

function coeff_abs_level_remaining_decode(S: PHEVCContext; RcRiceParam: Integer): Integer;
var
  Prefix, Suffix, I, prefix_minus3: Integer;
begin
  Prefix := 0;
  Suffix := 0;
  while (Prefix < 31) and (get_cabac_bypass(S^.HEVClc^.cc) <> 0) do Inc(Prefix);
  if Prefix < 3 then
  begin
    for I := 0 to RcRiceParam - 1 do
      Suffix := (Suffix shl 1) or get_cabac_bypass(S^.HEVClc^.cc);
    Result := (Prefix shl RcRiceParam) + Suffix;
  end
  else
  begin
    prefix_minus3 := Prefix - 3;
    for I := 0 to prefix_minus3 + RcRiceParam - 1 do
      Suffix := (Suffix shl 1) or get_cabac_bypass(S^.HEVClc^.cc);
    Result := (((1 shl prefix_minus3) + 3 - 1) shl RcRiceParam) + Suffix;
  end;
end;

function coeff_sign_flag_decode(S: PHEVCContext; Nb: Byte): Integer;
var
  I, Ret: Integer;
begin
  Ret := 0;
  for I := 0 to Nb - 1 do
    Ret := (Ret shl 1) or get_cabac_bypass(S^.HEVClc^.cc);
  Result := Ret;
end;

const
  sig_ctx_idx_map: array[0..79] of Byte = (
    0, 1, 4, 5, 2, 3, 4, 5, 6, 6, 8, 8, 7, 7, 8, 8,
    1, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 1, 0, 0, 2, 1, 0, 0, 2, 1, 0, 0, 2, 1, 0, 0,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
  );
  qp_c_tab: array[0..13] of Integer = (29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37);
  // NOTE: the reference declares these as [51 + 4*6 + 1] but only initialises
  // 74 entries, so C zero-fills indices 74 and 75. Reproduced verbatim.
  rem6: array[0..51 + 4 * 6] of Byte = (
    0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5, 0, 1, 2,
    3, 4, 5, 0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5,
    0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5, 0, 1, 2, 3,
    4, 5, 0, 1, 2, 3, 4, 5, 0, 1, 0, 0
  );
  div6: array[0..51 + 4 * 6] of Byte = (
    0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 3, 3, 3,
    3, 3, 3, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6,
    7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 10, 10, 10, 10,
    10, 10, 11, 11, 11, 11, 11, 11, 12, 12, 0, 0
  );
  level_scale: array[0..5] of Byte = (40, 45, 51, 57, 64, 72);

procedure ff_hevc_hls_residual_coding(S: PHEVCContext; X0, Y0, Log2TrafoSize,
  ScanIdx, CIdx: Integer);
var
  LC: PHEVCLocalContext;
  transform_skip_flag: Integer;
  last_significant_coeff_x, last_significant_coeff_y: Integer;
  last_scan_pos, n_end, num_coeff, greater1_ctx, num_last_subset: Integer;
  x_cg_last_sig, y_cg_last_sig: Integer;
  scan_x_cg, scan_y_cg, scan_x_off, scan_y_off: PByte;
  Stride: PtrInt;
  HShift, VShift: Integer;
  Dst: PByte;
  Coeffs: PInt16;
  significant_coeff_group_flag: array[0..7, 0..7] of Byte;
  explicit_rdpcm_flag, explicit_rdpcm_dir_flag: Integer;
  trafo_size, I: Integer;
  qp, shift, add, scale, scale_m: Integer;
  scale_matrix: PByte;
  dc_scale: Byte;
  pred_mode_intra: Integer;
  qp_y, qp_i, offset, matrix_id: Integer;
  SL: PScalingList;
  suffix, tmpi: Integer;
  last_x_c, last_y_c: Integer;
  N, M: Integer;
  x_cg, y_cg, x_c, y_c, pos: Integer;
  implicit_non_zero_coeff: Integer;
  trans_coeff_level: Int64;
  prev_sig, offs, rice_init, ctx_cg: Integer;
  significant_coeff_flag_idx: array[0..15] of Byte;
  nb_significant_coeff_flag: Byte;
  ctx_idx_map_p: PByte;
  scf_offset: Integer;
  first_nz_pos_in_cg, last_nz_pos_in_cg, c_rice_param, first_greater1_coeff_idx: Integer;
  coeff_abs_level_greater1_flag: array[0..7] of Byte;
  coeff_sign_flag: Word;
  sum_abs, sign_hidden, sb_type, ctx_set: Integer;
  inc_: Integer;
  last_coeff_abs_level_remaining, c_rice_p_init: Integer;
  rot, mode_, max_xy, col_limit: Integer;
  coeffs_y: PInt16;
  tmp16: Int16;
begin
  LC := S^.HEVClc;
  transform_skip_flag := 0;
  num_coeff := 0;
  greater1_ctx := 1;
  explicit_rdpcm_flag := 0;
  explicit_rdpcm_dir_flag := 0;
  scale_matrix := nil;
  sb_type := 0;
  scale_m := 16;

  Stride := S^.frame^.Linesize[CIdx];
  HShift := S^.sps^.hshift[CIdx];
  VShift := S^.sps^.vshift[CIdx];
  Dst := S^.frame^.Data[CIdx] + (Y0 shr VShift) * Stride +
         ((X0 shr HShift) shl S^.sps^.pixel_shift);
  if CIdx <> 0 then
    Coeffs := PInt16(@LC^.edge_emu_buffer2[0])
  else
    Coeffs := PInt16(@LC^.edge_emu_buffer[0]);
  FillChar(significant_coeff_group_flag, SizeOf(significant_coeff_group_flag), 0);
  trafo_size := 1 shl Log2TrafoSize;
  if CIdx = 0 then pred_mode_intra := LC^.tu.intra_pred_mode
  else pred_mode_intra := LC^.tu.intra_pred_mode_c;

  FillChar(Coeffs^, trafo_size * trafo_size * SizeOf(Int16), 0);

  if LC^.cu.cu_transquant_bypass_flag = 0 then
  begin
    qp_y := LC^.qp_y;
    if (S^.pps^.transform_skip_enabled_flag <> 0) and
       (Log2TrafoSize <= S^.pps^.log2_max_transform_skip_block_size) then
      transform_skip_flag := transform_skip_flag_decode(S, CIdx);
    if CIdx = 0 then
      qp := qp_y + S^.sps^.qp_bd_offset
    else
    begin
      if CIdx = 1 then
        offset := S^.pps^.cb_qp_offset + S^.sh.slice_cb_qp_offset + LC^.tu.cu_qp_offset_cb
      else
        offset := S^.pps^.cr_qp_offset + S^.sh.slice_cr_qp_offset + LC^.tu.cu_qp_offset_cr;
      qp_i := av_clip_c(qp_y + offset, -S^.sps^.qp_bd_offset, 57);
      if S^.sps^.chroma_format_idc = 1 then
      begin
        if qp_i < 30 then qp := qp_i
        else if qp_i > 43 then qp := qp_i - 6
        else qp := qp_c_tab[qp_i - 30];
      end
      else
      begin
        if qp_i > 51 then qp := 51 else qp := qp_i;
      end;
      qp := qp + S^.sps^.qp_bd_offset;
    end;
    shift := S^.sps^.bit_depth + Log2TrafoSize - 5;
    add := 1 shl (shift - 1);
    scale := level_scale[rem6[qp]] shl div6[qp];
    scale_m := 16;
    dc_scale := 16;
    if (S^.sps^.scaling_list_enable_flag <> 0) and
       not ((transform_skip_flag <> 0) and (Log2TrafoSize > 2)) then
    begin
      if S^.pps^.scaling_list_data_present_flag <> 0 then
        SL := @S^.pps^.scaling_list
      else
        SL := @S^.sps^.scaling_list;
      matrix_id := Ord(LC^.cu.pred_mode <> MODE_INTRA);
      matrix_id := 3 * matrix_id + CIdx;
      scale_matrix := @SL^.sl[Log2TrafoSize - 2][matrix_id][0];
      if Log2TrafoSize >= 4 then
        dc_scale := SL^.sl_dc[Log2TrafoSize - 4][matrix_id];
    end;
  end
  else
  begin
    shift := 0;
    add := 0;
    scale := 0;
    dc_scale := 0;
  end;

  if (LC^.cu.pred_mode = MODE_INTER) and (S^.sps^.explicit_rdpcm_enabled_flag <> 0) and
     ((transform_skip_flag <> 0) or (LC^.cu.cu_transquant_bypass_flag <> 0)) then
  begin
    explicit_rdpcm_flag := explicit_rdpcm_flag_decode(S, CIdx);
    if explicit_rdpcm_flag <> 0 then
      explicit_rdpcm_dir_flag := explicit_rdpcm_dir_flag_decode(S, CIdx);
  end;

  last_significant_coeff_xy_prefix_decode(S, CIdx, Log2TrafoSize,
    last_significant_coeff_x, last_significant_coeff_y);

  if last_significant_coeff_x > 3 then
  begin
    suffix := last_significant_coeff_suffix_decode(S, last_significant_coeff_x);
    last_significant_coeff_x := (1 shl ((last_significant_coeff_x shr 1) - 1)) *
      (2 + (last_significant_coeff_x and 1)) + suffix;
  end;
  if last_significant_coeff_y > 3 then
  begin
    suffix := last_significant_coeff_suffix_decode(S, last_significant_coeff_y);
    last_significant_coeff_y := (1 shl ((last_significant_coeff_y shr 1) - 1)) *
      (2 + (last_significant_coeff_y and 1)) + suffix;
  end;
  if ScanIdx = SCAN_VERT then
  begin
    tmpi := last_significant_coeff_y;
    last_significant_coeff_y := last_significant_coeff_x;
    last_significant_coeff_x := tmpi;
  end;
  x_cg_last_sig := last_significant_coeff_x shr 2;
  y_cg_last_sig := last_significant_coeff_y shr 2;

  case ScanIdx of
    SCAN_DIAG:
      begin
        last_x_c := last_significant_coeff_x and 3;
        last_y_c := last_significant_coeff_y and 3;
        scan_x_off := @ff_hevc_diag_scan4x4_x[0];
        scan_y_off := @ff_hevc_diag_scan4x4_y[0];
        num_coeff := diag_scan4x4_inv[(last_y_c shl 2) + last_x_c];
        if trafo_size = 4 then
        begin
          scan_x_cg := @scan_1x1[0];
          scan_y_cg := @scan_1x1[0];
        end
        else if trafo_size = 8 then
        begin
          num_coeff := num_coeff + (diag_scan2x2_inv[(y_cg_last_sig shl 1) + x_cg_last_sig] shl 4);
          scan_x_cg := @diag_scan2x2_x[0];
          scan_y_cg := @diag_scan2x2_y[0];
        end
        else if trafo_size = 16 then
        begin
          num_coeff := num_coeff + (diag_scan4x4_inv[(y_cg_last_sig shl 2) + x_cg_last_sig] shl 4);
          scan_x_cg := @ff_hevc_diag_scan4x4_x[0];
          scan_y_cg := @ff_hevc_diag_scan4x4_y[0];
        end
        else
        begin
          num_coeff := num_coeff + (diag_scan8x8_inv[(y_cg_last_sig shl 3) + x_cg_last_sig] shl 4);
          scan_x_cg := @ff_hevc_diag_scan8x8_x[0];
          scan_y_cg := @ff_hevc_diag_scan8x8_y[0];
        end;
      end;
    SCAN_HORIZ:
      begin
        scan_x_cg := @horiz_scan2x2_x[0];
        scan_y_cg := @horiz_scan2x2_y[0];
        scan_x_off := @horiz_scan4x4_x[0];
        scan_y_off := @horiz_scan4x4_y[0];
        num_coeff := horiz_scan8x8_inv[(last_significant_coeff_y shl 3) + last_significant_coeff_x];
      end;
  else
    scan_x_cg := @horiz_scan2x2_y[0];
    scan_y_cg := @horiz_scan2x2_x[0];
    scan_x_off := @horiz_scan4x4_y[0];
    scan_y_off := @horiz_scan4x4_x[0];
    num_coeff := horiz_scan8x8_inv[(last_significant_coeff_x shl 3) + last_significant_coeff_y];
  end;
  Inc(num_coeff);
  num_last_subset := (num_coeff - 1) shr 4;

  for I := num_last_subset downto 0 do
  begin
    implicit_non_zero_coeff := 0;
    prev_sig := 0;
    offs := I shl 4;
    rice_init := 0;
    nb_significant_coeff_flag := 0;
    x_cg := scan_x_cg[I];
    y_cg := scan_y_cg[I];

    if (I < num_last_subset) and (I > 0) then
    begin
      ctx_cg := 0;
      if x_cg < (1 shl (Log2TrafoSize - 2)) - 1 then
        ctx_cg := ctx_cg + significant_coeff_group_flag[x_cg + 1][y_cg];
      if y_cg < (1 shl (Log2TrafoSize - 2)) - 1 then
        ctx_cg := ctx_cg + significant_coeff_group_flag[x_cg][y_cg + 1];
      significant_coeff_group_flag[x_cg][y_cg] :=
        Byte(significant_coeff_group_flag_decode(S, CIdx, ctx_cg));
      implicit_non_zero_coeff := 1;
    end
    else
      significant_coeff_group_flag[x_cg][y_cg] :=
        Byte(Ord(((x_cg = x_cg_last_sig) and (y_cg = y_cg_last_sig)) or
                 ((x_cg = 0) and (y_cg = 0))));

    last_scan_pos := num_coeff - offs - 1;
    if I = num_last_subset then
    begin
      n_end := last_scan_pos - 1;
      significant_coeff_flag_idx[0] := Byte(last_scan_pos);
      nb_significant_coeff_flag := 1;
    end
    else
      n_end := 15;

    if x_cg < (((1 shl Log2TrafoSize) - 1) shr 2) then
      prev_sig := Ord(significant_coeff_group_flag[x_cg + 1][y_cg] <> 0);
    if y_cg < (((1 shl Log2TrafoSize) - 1) shr 2) then
      prev_sig := prev_sig + (Ord(significant_coeff_group_flag[x_cg][y_cg + 1] <> 0) shl 1);

    if (significant_coeff_group_flag[x_cg][y_cg] <> 0) and (n_end >= 0) then
    begin
      scf_offset := 0;
      if (S^.sps^.transform_skip_context_enabled_flag <> 0) and
         ((transform_skip_flag <> 0) or (LC^.cu.cu_transquant_bypass_flag <> 0)) then
      begin
        ctx_idx_map_p := @sig_ctx_idx_map[4 * 16];
        if CIdx = 0 then scf_offset := 40 else scf_offset := 14 + 27;
      end
      else
      begin
        if CIdx <> 0 then scf_offset := 27;
        if Log2TrafoSize = 2 then
          ctx_idx_map_p := @sig_ctx_idx_map[0]
        else
        begin
          ctx_idx_map_p := @sig_ctx_idx_map[(prev_sig + 1) shl 4];
          if CIdx = 0 then
          begin
            if (x_cg > 0) or (y_cg > 0) then scf_offset := scf_offset + 3;
            if Log2TrafoSize = 3 then
            begin
              if ScanIdx = SCAN_DIAG then scf_offset := scf_offset + 9
              else scf_offset := scf_offset + 15;
            end
            else
              scf_offset := scf_offset + 21;
          end
          else
          begin
            if Log2TrafoSize = 3 then scf_offset := scf_offset + 9
            else scf_offset := scf_offset + 12;
          end;
        end;
      end;

      for N := n_end downto 1 do
      begin
        x_c := scan_x_off[N];
        y_c := scan_y_off[N];
        if significant_coeff_flag_decode(S, x_c, y_c, scf_offset, ctx_idx_map_p) <> 0 then
        begin
          significant_coeff_flag_idx[nb_significant_coeff_flag] := Byte(N);
          Inc(nb_significant_coeff_flag);
          implicit_non_zero_coeff := 0;
        end;
      end;

      if implicit_non_zero_coeff = 0 then
      begin
        if (S^.sps^.transform_skip_context_enabled_flag <> 0) and
           ((transform_skip_flag <> 0) or (LC^.cu.cu_transquant_bypass_flag <> 0)) then
        begin
          if CIdx = 0 then scf_offset := 42 else scf_offset := 16 + 27;
        end
        else
        begin
          if I = 0 then
          begin
            if CIdx = 0 then scf_offset := 0 else scf_offset := 27;
          end
          else
            scf_offset := 2 + scf_offset;
        end;
        if significant_coeff_flag_decode_0(S, CIdx, scf_offset) = 1 then
        begin
          significant_coeff_flag_idx[nb_significant_coeff_flag] := 0;
          Inc(nb_significant_coeff_flag);
        end;
      end
      else
      begin
        significant_coeff_flag_idx[nb_significant_coeff_flag] := 0;
        Inc(nb_significant_coeff_flag);
      end;
    end;

    n_end := nb_significant_coeff_flag;
    if n_end <> 0 then
    begin
      c_rice_param := 0;
      first_greater1_coeff_idx := -1;
      sum_abs := 0;
      if (I > 0) and (CIdx = 0) then ctx_set := 2 else ctx_set := 0;
      if S^.sps^.persistent_rice_adaptation_enabled_flag <> 0 then
      begin
        if (transform_skip_flag = 0) and (LC^.cu.cu_transquant_bypass_flag = 0) then
          sb_type := 2 * Ord(CIdx = 0)
        else
          sb_type := 2 * Ord(CIdx = 0) + 1;
        c_rice_param := LC^.stat_coeff[sb_type] div 4;
      end;
      if (I <> num_last_subset) and (greater1_ctx = 0) then Inc(ctx_set);
      greater1_ctx := 1;
      last_nz_pos_in_cg := significant_coeff_flag_idx[0];

      for M := 0 to FFMIN(n_end, 8) - 1 do
      begin
        inc_ := (ctx_set shl 2) + greater1_ctx;
        coeff_abs_level_greater1_flag[M] :=
          Byte(coeff_abs_level_greater1_flag_decode(S, CIdx, inc_));
        if coeff_abs_level_greater1_flag[M] <> 0 then
        begin
          greater1_ctx := 0;
          if first_greater1_coeff_idx = -1 then first_greater1_coeff_idx := M;
        end
        else if (greater1_ctx > 0) and (greater1_ctx < 3) then
          Inc(greater1_ctx);
      end;
      first_nz_pos_in_cg := significant_coeff_flag_idx[n_end - 1];

      if (LC^.cu.cu_transquant_bypass_flag <> 0) or
         ((LC^.cu.pred_mode = MODE_INTRA) and
          (S^.sps^.implicit_rdpcm_enabled_flag <> 0) and (transform_skip_flag <> 0) and
          ((pred_mode_intra = 10) or (pred_mode_intra = 26))) or
         (explicit_rdpcm_flag <> 0) then
        sign_hidden := 0
      else
        sign_hidden := Ord(last_nz_pos_in_cg - first_nz_pos_in_cg >= 4);

      if first_greater1_coeff_idx <> -1 then
        coeff_abs_level_greater1_flag[first_greater1_coeff_idx] :=
          Byte(coeff_abs_level_greater1_flag[first_greater1_coeff_idx] +
               coeff_abs_level_greater2_flag_decode(S, CIdx, ctx_set));

      if (S^.pps^.sign_data_hiding_flag = 0) or (sign_hidden = 0) then
        coeff_sign_flag := Word(coeff_sign_flag_decode(S, nb_significant_coeff_flag) shl
          (16 - nb_significant_coeff_flag))
      else
        coeff_sign_flag := Word(coeff_sign_flag_decode(S, nb_significant_coeff_flag - 1) shl
          (16 - (nb_significant_coeff_flag - 1)));

      for M := 0 to n_end - 1 do
      begin
        N := significant_coeff_flag_idx[M];
        x_c := (x_cg shl 2) + scan_x_off[N];
        y_c := (y_cg shl 2) + scan_y_off[N];
        if M < 8 then
        begin
          trans_coeff_level := 1 + coeff_abs_level_greater1_flag[M];
          if ((M = first_greater1_coeff_idx) and (trans_coeff_level = 3)) or
             ((M <> first_greater1_coeff_idx) and (trans_coeff_level = 2)) then
          begin
            last_coeff_abs_level_remaining := coeff_abs_level_remaining_decode(S, c_rice_param);
            trans_coeff_level := trans_coeff_level + last_coeff_abs_level_remaining;
            if trans_coeff_level > (3 shl c_rice_param) then
            begin
              if S^.sps^.persistent_rice_adaptation_enabled_flag <> 0 then
                c_rice_param := c_rice_param + 1
              else
                c_rice_param := FFMIN(c_rice_param + 1, 4);
            end;
            if (S^.sps^.persistent_rice_adaptation_enabled_flag <> 0) and (rice_init = 0) then
            begin
              c_rice_p_init := LC^.stat_coeff[sb_type] div 4;
              if last_coeff_abs_level_remaining >= (3 shl c_rice_p_init) then
                Inc(LC^.stat_coeff[sb_type])
              else if 2 * last_coeff_abs_level_remaining < (1 shl c_rice_p_init) then
                if LC^.stat_coeff[sb_type] > 0 then Dec(LC^.stat_coeff[sb_type]);
              rice_init := 1;
            end;
          end;
        end
        else
        begin
          last_coeff_abs_level_remaining := coeff_abs_level_remaining_decode(S, c_rice_param);
          trans_coeff_level := 1 + last_coeff_abs_level_remaining;
          if trans_coeff_level > (3 shl c_rice_param) then
          begin
            if S^.sps^.persistent_rice_adaptation_enabled_flag <> 0 then
              c_rice_param := c_rice_param + 1
            else
              c_rice_param := FFMIN(c_rice_param + 1, 4);
          end;
          if (S^.sps^.persistent_rice_adaptation_enabled_flag <> 0) and (rice_init = 0) then
          begin
            c_rice_p_init := LC^.stat_coeff[sb_type] div 4;
            if last_coeff_abs_level_remaining >= (3 shl c_rice_p_init) then
              Inc(LC^.stat_coeff[sb_type])
            else if 2 * last_coeff_abs_level_remaining < (1 shl c_rice_p_init) then
              if LC^.stat_coeff[sb_type] > 0 then Dec(LC^.stat_coeff[sb_type]);
            rice_init := 1;
          end;
        end;

        if (S^.pps^.sign_data_hiding_flag <> 0) and (sign_hidden <> 0) then
        begin
          sum_abs := sum_abs + Integer(trans_coeff_level);
          if (N = first_nz_pos_in_cg) and ((sum_abs and 1) <> 0) then
            trans_coeff_level := -trans_coeff_level;
        end;
        if (coeff_sign_flag shr 15) <> 0 then
          trans_coeff_level := -trans_coeff_level;
        coeff_sign_flag := Word(coeff_sign_flag shl 1);

        if LC^.cu.cu_transquant_bypass_flag = 0 then
        begin
          if (S^.sps^.scaling_list_enable_flag <> 0) and
             not ((transform_skip_flag <> 0) and (Log2TrafoSize > 2)) then
          begin
            if (y_c <> 0) or (x_c <> 0) or (Log2TrafoSize < 4) then
            begin
              case Log2TrafoSize of
                3: pos := (y_c shl 3) + x_c;
                4: pos := ((y_c shr 1) shl 3) + (x_c shr 1);
                5: pos := ((y_c shr 2) shl 3) + (x_c shr 2);
              else
                pos := (y_c shl 2) + x_c;
              end;
              scale_m := scale_matrix[pos];
            end
            else
              scale_m := dc_scale;
          end;
          trans_coeff_level := SarInt64(trans_coeff_level * Int64(scale) * Int64(scale_m) + add, shift);
          if trans_coeff_level < 0 then
          begin
            if ((not trans_coeff_level) and Int64($0FFFFFFFFFFF8000)) <> 0 then
              trans_coeff_level := -32768;
          end
          else
          begin
            if (trans_coeff_level and Int64($FFFFFFFFFFFF8000)) <> 0 then
              trans_coeff_level := 32767;
          end;
        end;
        Coeffs[y_c * trafo_size + x_c] := Int16(trans_coeff_level);
      end;
    end;
  end;

  if residual_capture <> nil then
  begin
    Move(Coeffs^, residual_capture^, (1 shl (2 * Log2TrafoSize)) * SizeOf(Int16));
    Exit;
  end;

  if LC^.cu.cu_transquant_bypass_flag <> 0 then
  begin
    if (explicit_rdpcm_flag <> 0) or
       ((S^.sps^.implicit_rdpcm_enabled_flag <> 0) and
        ((pred_mode_intra = 10) or (pred_mode_intra = 26))) then
    begin
      if S^.sps^.implicit_rdpcm_enabled_flag <> 0 then
        mode_ := Ord(pred_mode_intra = 26)
      else
        mode_ := explicit_rdpcm_dir_flag;
      transform_rdpcm(Coeffs, Log2TrafoSize, mode_);
    end;
  end
  else
  begin
    if transform_skip_flag <> 0 then
    begin
      rot := Ord((S^.sps^.transform_skip_rotation_enabled_flag <> 0) and
                 (Log2TrafoSize = 2) and (LC^.cu.pred_mode = MODE_INTRA));
      if rot <> 0 then
        for I := 0 to 7 do
        begin
          tmp16 := Coeffs[16 - I - 1];
          Coeffs[16 - I - 1] := Coeffs[I];
          Coeffs[I] := tmp16;
        end;
      transform_skip(Coeffs, Log2TrafoSize, S^.sps^.bit_depth);
      if (explicit_rdpcm_flag <> 0) or
         ((S^.sps^.implicit_rdpcm_enabled_flag <> 0) and
          (LC^.cu.pred_mode = MODE_INTRA) and
          ((pred_mode_intra = 10) or (pred_mode_intra = 26))) then
      begin
        if explicit_rdpcm_flag <> 0 then mode_ := explicit_rdpcm_dir_flag
        else mode_ := Ord(pred_mode_intra = 26);
        transform_rdpcm(Coeffs, Log2TrafoSize, mode_);
      end;
    end
    else if (LC^.cu.pred_mode = MODE_INTRA) and (CIdx = 0) and (Log2TrafoSize = 2) then
      transform_4x4_luma(Coeffs, S^.sps^.bit_depth)
    else
    begin
      max_xy := FFMAX(last_significant_coeff_x, last_significant_coeff_y);
      if max_xy = 0 then
        idct_dc(Log2TrafoSize - 2, Coeffs, S^.sps^.bit_depth)
      else
      begin
        col_limit := last_significant_coeff_x + last_significant_coeff_y + 4;
        if max_xy < 4 then col_limit := FFMIN(4, col_limit)
        else if max_xy < 8 then col_limit := FFMIN(8, col_limit)
        else if max_xy < 12 then col_limit := FFMIN(24, col_limit);
        idct(Log2TrafoSize - 2, Coeffs, col_limit, S^.sps^.bit_depth);
      end;
    end;
  end;

  if LC^.tu.cross_pf <> 0 then
  begin
    coeffs_y := PInt16(@LC^.edge_emu_buffer[0]);
    for I := 0 to trafo_size * trafo_size - 1 do
      Coeffs[I] := Int16(Coeffs[I] + SarLongint(LC^.tu.res_scale_val * coeffs_y[I], 3));
  end;

  transform_add(Log2TrafoSize - 2, Dst, Coeffs, Stride, S^.sps^.bit_depth);
end;

procedure ff_hevc_hls_mvd_coding(S: PHEVCContext; X0, Y0, Log2CbSize: Integer);
var
  LC: PHEVCLocalContext;
  X, Y: Integer;
begin
  LC := S^.HEVClc;
  X := abs_mvd_greater0_flag_decode(S);
  Y := abs_mvd_greater0_flag_decode(S);
  if X <> 0 then X := X + abs_mvd_greater1_flag_decode(S);
  if Y <> 0 then Y := Y + abs_mvd_greater1_flag_decode(S);
  case X of
    2: LC^.pu.mvd.x := Int16(mvd_decode(S));
    1: LC^.pu.mvd.x := Int16(mvd_sign_flag_decode(S));
    0: LC^.pu.mvd.x := 0;
  end;
  case Y of
    2: LC^.pu.mvd.y := Int16(mvd_decode(S));
    1: LC^.pu.mvd.y := Int16(mvd_sign_flag_decode(S));
    0: LC^.pu.mvd.y := 0;
  end;
end;

procedure ff_hevc_cabac_init_enc(S: PHEVCContext);
begin
  cabac_init_state(S);
end;

{$i residual_enc.inc}

procedure split_last_sig_test(V: Integer; out Prefix, Suffix, SuffixLen: Integer);
begin
  split_last_sig(V, Prefix, Suffix, SuffixLen);
end;

procedure enc_coeff_abs_level_remaining_test(var E: TCabacEncoder;
  Value, RcRiceParam: Integer);
begin
  enc_coeff_abs_level_remaining(E, Value, RcRiceParam);
end;


end.
