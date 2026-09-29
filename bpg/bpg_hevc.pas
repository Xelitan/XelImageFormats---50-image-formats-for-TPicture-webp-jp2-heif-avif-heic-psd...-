// BPG encoder -- Free Pascal
// Main HEVC decoding layer.
// Corresponds to: libavcodec/hevc.c
//
// hevc.c is fully ported. Deliberate divergences from the reference, each
// marked with a comment at the site:
//   * the AVCC (is_nalff) NAL splitting path is omitted -- libbpg always feeds
//     an Annex-B stream;
//   * chroma plane addresses are computed only when chroma_format_idc <> 0;
//   * thread progress / avctx->execute collapse to direct calls;
//   * the VPS is parsed nowhere, so vps_list has no counterpart here.
//
// The reference threads the decoder through AVCodecContext; the handful of
// fields libbpg actually uses (coded_width/height, pix_fmt) live in
// THEVCContext here instead. Entry points are hevc_init_context,
// hevc_decode_frame and hevc_decode_free.
unit bpg_hevc;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, bpg_common, bpg_bits, bpg_cabac, bpg_hevc_defs, bpg_scan, bpg_frame,
  bpg_hevc_ps, bpg_hevcdsp, bpg_hevcmc, bpg_hevcpred, bpg_hevc_cabac,
  bpg_hevc_refs, bpg_hevc_sei, bpg_hevc_mvs, bpg_hevc_filter;

type
  TIntraCandidates = array[0..2] of Integer;

const
  ff_hevc_pel_weight: array[0..64] of Byte = (
    0, 0, 0, 0, 1, 0, 2, 0, 3, 0, 0, 0, 4, 0, 0, 0,
    5, 0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0,
    7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    9
  );

procedure pic_arrays_free(S: PHEVCContext);
function pic_arrays_init(S: PHEVCContext; SPS: PHEVCSPS): Integer;
function set_sps(S: PHEVCContext; SPS: PHEVCSPS): Integer;
function hls_slice_header(S: PHEVCContext): Integer;
procedure hls_sao_param(S: PHEVCContext; RX, RY: Integer);
function hls_cross_component_pred(S: PHEVCContext; Idx: Integer): Integer;
function hls_transform_tree(S: PHEVCContext; X0, Y0, XBase, YBase,
  cb_xBase, cb_yBase, log2_cb_size, log2_trafo_size, trafo_depth,
  blk_idx: Integer; base_cbf_cb, base_cbf_cr: PInteger): Integer;
function hls_pcm_sample(S: PHEVCContext; X0, Y0, log2_cb_size: Integer): Integer;
function hevc_init_context(S: PHEVCContext): Integer;
procedure hevc_decode_free(S: PHEVCContext);
function hevc_decode_frame(S: PHEVCContext; Data: PAVFrame; out got_output: Integer;
  pkt_data: PByte; pkt_size: Integer): Integer;
procedure hls_prediction_unit(S: PHEVCContext; X0, Y0, nPbW, nPbH,
  log2_cb_size, partIdx, Idx: Integer);
// exported for the encoder: it must set up ctb_left_flag / ctb_up_flag and the
// boundary flags exactly as the decoder does, or the neighbour dependent
// contexts and the intra reference substitution will disagree
procedure hls_decode_neighbour(S: PHEVCContext; x_ctb, y_ctb, ctb_addr_ts: Integer);
procedure luma_intra_candidates(S: PHEVCContext; X0, Y0: Integer;
  out candidate: TIntraCandidates);
// encode direction: given the chosen mode, produce the syntax that selects it
// and update tab_ipm / tab_mvf just as the decoder does
procedure luma_intra_pred_mode_enc(S: PHEVCContext; X0, Y0, pu_size, Mode: Integer;
  out PrevFlag, MpmIdx, RemMode: Integer);
// In 4:2:2 the chroma prediction mode is the luma mode mapped through
// tab_mode_idx; intra_prediction_unit does this and the encoder must match.
function chroma_mode_422(Mode: Integer): Integer;
function hls_coding_quadtree(S: PHEVCContext; X0, Y0, log2_cb_size,
  cb_depth: Integer): Integer;

function av_ceil_log2_c(X: Integer): Integer; inline;

implementation

function av_ceil_log2_c(X: Integer): Integer;
begin
  Result := av_log2(Cardinal((X - 1) shl 1));
end;

procedure pic_arrays_free(S: PHEVCContext);
begin
  av_freep(@S^.sao);
  av_freep(@S^.deblock);
  av_freep(@S^.skip_flag);
  av_freep(@S^.tab_ct_depth);
  av_freep(@S^.tab_ipm);
  av_freep(@S^.cbf_luma);
  av_freep(@S^.is_pcm);
  av_freep(@S^.qp_y_tab);
  av_freep(@S^.tab_slice_address);
  av_freep(@S^.filter_slice_edges);
  av_freep(@S^.horizontal_bs);
  av_freep(@S^.vertical_bs);
  av_freep(@S^.sh.entry_point_offset);
  av_freep(@S^.sh.size);
  av_freep(@S^.sh.offset);
end;

function pic_arrays_init(S: PHEVCContext; SPS: PHEVCSPS): Integer;
var
  log2_min_cb_size, Width, Height: Integer;
  pic_size_in_ctb, ctb_count, min_pu_size: Integer;
label
  fail;
begin
  log2_min_cb_size := SPS^.log2_min_cb_size;
  Width := SPS^.width;
  Height := SPS^.height;
  pic_size_in_ctb := ((Width shr log2_min_cb_size) + 1) *
                     ((Height shr log2_min_cb_size) + 1);
  ctb_count := SPS^.ctb_width * SPS^.ctb_height;
  min_pu_size := SPS^.min_pu_width * SPS^.min_pu_height;

  S^.bs_width := (Width shr 2) + 1;
  S^.bs_height := (Height shr 2) + 1;

  S^.sao := av_mallocz_array(ctb_count, SizeOf(TSAOParams));
  S^.deblock := av_mallocz_array(ctb_count, SizeOf(TDBParams));
  if (S^.sao = nil) or (S^.deblock = nil) then goto fail;

  S^.skip_flag := av_malloc(SPS^.min_cb_height * SPS^.min_cb_width);
  S^.tab_ct_depth := av_malloc_array(SPS^.min_cb_height, SPS^.min_cb_width);
  if (S^.skip_flag = nil) or (S^.tab_ct_depth = nil) then goto fail;

  S^.cbf_luma := av_malloc_array(SPS^.min_tb_width, SPS^.min_tb_height);
  S^.tab_ipm := av_mallocz(min_pu_size);
  S^.is_pcm := av_malloc((SPS^.min_pu_width + 1) * (SPS^.min_pu_height + 1));
  if (S^.tab_ipm = nil) or (S^.cbf_luma = nil) or (S^.is_pcm = nil) then goto fail;

  S^.filter_slice_edges := av_malloc(ctb_count);
  S^.tab_slice_address := av_malloc_array(pic_size_in_ctb, SizeOf(Int32));
  S^.qp_y_tab := av_malloc_array(pic_size_in_ctb, SizeOf(Int8));
  if (S^.qp_y_tab = nil) or (S^.filter_slice_edges = nil) or
     (S^.tab_slice_address = nil) then goto fail;

  S^.horizontal_bs := av_mallocz_array(S^.bs_width, S^.bs_height);
  S^.vertical_bs := av_mallocz_array(S^.bs_width, S^.bs_height);
  if (S^.horizontal_bs = nil) or (S^.vertical_bs = nil) then goto fail;

  // the reference keeps AVBufferPools for tab_mvf / rpl_tab here; the port
  // allocates them per frame in bpg_hevc_refs.alloc_frame instead
  Exit(0);

fail:
  pic_arrays_free(S);
  Result := AVERROR_ENOMEM;
end;

procedure pred_weight_table(S: PHEVCContext; GB: PGetBitContext);
var
  I, J: Integer;
  luma_weight_l0_flag, chroma_weight_l0_flag: array[0..15] of Byte;
  Delta, delta_luma_weight_l0, delta_chroma_weight_l0, delta_chroma_offset_l0: Integer;
begin
  S^.sh.luma_log2_weight_denom := Byte(get_ue_golomb_long(GB^));
  if S^.sps^.chroma_format_idc <> 0 then
  begin
    Delta := get_se_golomb(GB^);
    S^.sh.chroma_log2_weight_denom :=
      Int16(av_clip_c(S^.sh.luma_log2_weight_denom + Delta, 0, 7));
  end;
  for I := 0 to Integer(S^.sh.nb_refs[0]) - 1 do
  begin
    luma_weight_l0_flag[I] := get_bits1(GB^);
    if luma_weight_l0_flag[I] = 0 then
    begin
      S^.sh.luma_weight_l0[I] := Int16(1 shl S^.sh.luma_log2_weight_denom);
      S^.sh.luma_offset_l0[I] := 0;
    end;
  end;
  if S^.sps^.chroma_format_idc <> 0 then
  begin
    for I := 0 to Integer(S^.sh.nb_refs[0]) - 1 do
      chroma_weight_l0_flag[I] := get_bits1(GB^);
  end
  else
    for I := 0 to Integer(S^.sh.nb_refs[0]) - 1 do
      chroma_weight_l0_flag[I] := 0;

  for I := 0 to Integer(S^.sh.nb_refs[0]) - 1 do
  begin
    if luma_weight_l0_flag[I] <> 0 then
    begin
      delta_luma_weight_l0 := get_se_golomb(GB^);
      S^.sh.luma_weight_l0[I] :=
        Int16((1 shl S^.sh.luma_log2_weight_denom) + delta_luma_weight_l0);
      S^.sh.luma_offset_l0[I] := Int16(get_se_golomb(GB^));
    end;
    if chroma_weight_l0_flag[I] <> 0 then
    begin
      for J := 0 to 1 do
      begin
        delta_chroma_weight_l0 := get_se_golomb(GB^);
        delta_chroma_offset_l0 := get_se_golomb(GB^);
        S^.sh.chroma_weight_l0[I][J] :=
          Int16((1 shl S^.sh.chroma_log2_weight_denom) + delta_chroma_weight_l0);
        S^.sh.chroma_offset_l0[I][J] := Int16(av_clip_c(delta_chroma_offset_l0 -
          ((128 * S^.sh.chroma_weight_l0[I][J]) shr S^.sh.chroma_log2_weight_denom) + 128,
          -128, 127));
      end;
    end
    else
    begin
      S^.sh.chroma_weight_l0[I][0] := Int16(1 shl S^.sh.chroma_log2_weight_denom);
      S^.sh.chroma_offset_l0[I][0] := 0;
      S^.sh.chroma_weight_l0[I][1] := Int16(1 shl S^.sh.chroma_log2_weight_denom);
      S^.sh.chroma_offset_l0[I][1] := 0;
    end;
  end;
end;

function decode_lt_rps(S: PHEVCContext; RPS: PLongTermRPS; GB: PGetBitContext): Integer;
var
  SPS: PHEVCSPS;
  max_poc_lsb, prev_delta_msb, I, Delta: Integer;
  nb_sps, nb_sh: Cardinal;
  delta_poc_msb_present, lt_idx_sps: Byte;
begin
  SPS := S^.sps;
  max_poc_lsb := 1 shl SPS^.log2_max_poc_lsb;
  prev_delta_msb := 0;
  nb_sps := 0;
  RPS^.nb_refs := 0;
  if SPS^.long_term_ref_pics_present_flag = 0 then Exit(0);
  if SPS^.num_long_term_ref_pics_sps > 0 then
    nb_sps := get_ue_golomb_long(GB^);
  nb_sh := get_ue_golomb_long(GB^);
  if QWord(nb_sh) + QWord(nb_sps) > 32 then Exit(AVERROR_INVALIDDATA);
  RPS^.nb_refs := Byte(nb_sh + nb_sps);
  for I := 0 to RPS^.nb_refs - 1 do
  begin
    if Cardinal(I) < nb_sps then
    begin
      lt_idx_sps := 0;
      if SPS^.num_long_term_ref_pics_sps > 1 then
        lt_idx_sps := Byte(get_bits(GB^, av_ceil_log2_c(SPS^.num_long_term_ref_pics_sps)));
      RPS^.poc[I] := SPS^.lt_ref_pic_poc_lsb_sps[lt_idx_sps];
      RPS^.used[I] := SPS^.used_by_curr_pic_lt_sps_flag[lt_idx_sps];
    end
    else
    begin
      RPS^.poc[I] := Integer(get_bits(GB^, SPS^.log2_max_poc_lsb));
      RPS^.used[I] := get_bits1(GB^);
    end;
    delta_poc_msb_present := get_bits1(GB^);
    if delta_poc_msb_present <> 0 then
    begin
      Delta := Integer(get_ue_golomb_long(GB^));
      if (I <> 0) and (Cardinal(I) <> nb_sps) then Delta := Delta + prev_delta_msb;
      RPS^.poc[I] := RPS^.poc[I] + S^.poc - Delta * max_poc_lsb - S^.sh.pic_order_cnt_lsb;
      prev_delta_msb := Delta;
    end;
  end;
  Result := 0;
end;

function set_sps(S: PHEVCContext; SPS: PHEVCSPS): Integer;
var
  Ret, ctb_size, c_count, CIdx, W, H: Integer;
label
  fail;
begin
  pic_arrays_free(S);
  Ret := pic_arrays_init(S, SPS);
  if Ret < 0 then goto fail;

  S^.width := SPS^.width;
  S^.height := SPS^.height;

  hevc_transform_init;

  av_freep(@S^.sao_pixel_buffer);
  for CIdx := 0 to 2 do
  begin
    av_freep(@S^.sao_pixel_buffer_h[CIdx]);
    av_freep(@S^.sao_pixel_buffer_v[CIdx]);
  end;

  if SPS^.sao_enabled <> 0 then
  begin
    ctb_size := 1 shl SPS^.log2_ctb_size;
    if SPS^.chroma_format_idc <> 0 then c_count := 3 else c_count := 1;
    S^.sao_pixel_buffer :=
      av_malloc(((ctb_size + 2) * (ctb_size + 2)) shl SPS^.pixel_shift);
    for CIdx := 0 to c_count - 1 do
    begin
      W := SPS^.width shr SPS^.hshift[CIdx];
      H := SPS^.height shr SPS^.vshift[CIdx];
      S^.sao_pixel_buffer_h[CIdx] :=
        av_malloc((W * 2 * SPS^.ctb_height) shl SPS^.pixel_shift);
      S^.sao_pixel_buffer_v[CIdx] :=
        av_malloc((H * 2 * SPS^.ctb_width) shl SPS^.pixel_shift);
    end;
  end;

  S^.sps := SPS;
  // the VPS is never read, so nothing to look up here
  Exit(0);

fail:
  pic_arrays_free(S);
  S^.sps := nil;
  Result := Ret;
end;

function hls_slice_header(S: PHEVCContext): Integer;
var
  GB: PGetBitContext;
  SH: PSliceHeader;
  I, J, Ret: Integer;
  last_sps: PHEVCSPS;
  slice_address_length: Integer;
  short_term_ref_pic_set_sps_flag, Poc, numbits, rps_idx: Integer;
  nb_refs: Integer;
  deblocking_filter_override_flag: Integer;
  offset_len, segments, rest, Val: Integer;
  Length_: Cardinal;
begin
  GB := @S^.HEVClc^.gb;
  SH := @S^.sh;

  SH^.first_slice_in_pic_flag := get_bits1(GB^);
  if (IS_IDR(S) or IS_BLA(S)) and (SH^.first_slice_in_pic_flag <> 0) then
  begin
    S^.seq_decode := (S^.seq_decode + 1) and $FF;
    S^.max_ra := $7FFFFFFF;
    if IS_IDR(S) then ff_hevc_clear_refs(S);
  end;
  SH^.no_output_of_prior_pics_flag := 0;
  if IS_IRAP(S) then
    SH^.no_output_of_prior_pics_flag := get_bits1(GB^);

  SH^.pps_id := get_ue_golomb_long(GB^);
  if (SH^.pps_id >= 256) or (S^.pps_list[SH^.pps_id] = nil) then
    Exit(AVERROR_INVALIDDATA);
  if (SH^.first_slice_in_pic_flag = 0) and (S^.pps <> S^.pps_list[SH^.pps_id]) then
    Exit(AVERROR_INVALIDDATA);
  S^.pps := S^.pps_list[SH^.pps_id];
  if (S^.nal_unit_type = NAL_CRA_NUT) and (S^.last_eos = 1) then
    SH^.no_output_of_prior_pics_flag := 1;

  if S^.sps <> S^.sps_list[S^.pps^.sps_id] then
  begin
    last_sps := S^.sps;
    S^.sps := S^.sps_list[S^.pps^.sps_id];
    if (last_sps <> nil) and IS_IRAP(S) and (S^.nal_unit_type <> NAL_CRA_NUT) then
    begin
      if (S^.sps^.width <> last_sps^.width) or (S^.sps^.height <> last_sps^.height) or
         (S^.sps^.temporal_layer[S^.sps^.max_sub_layers - 1].max_dec_pic_buffering <>
          last_sps^.temporal_layer[last_sps^.max_sub_layers - 1].max_dec_pic_buffering) then
        SH^.no_output_of_prior_pics_flag := 0;
    end;
    ff_hevc_clear_refs(S);
    Ret := set_sps(S, S^.sps);
    if Ret < 0 then Exit(Ret);
    S^.seq_decode := (S^.seq_decode + 1) and $FF;
    S^.max_ra := $7FFFFFFF;
  end;

  SH^.dependent_slice_segment_flag := 0;
  if SH^.first_slice_in_pic_flag = 0 then
  begin
    if S^.pps^.dependent_slice_segments_enabled_flag <> 0 then
      SH^.dependent_slice_segment_flag := get_bits1(GB^);
    slice_address_length := av_ceil_log2_c(S^.sps^.ctb_width * S^.sps^.ctb_height);
    SH^.slice_segment_addr := get_bits(GB^, slice_address_length);
    if SH^.slice_segment_addr >= Cardinal(S^.sps^.ctb_width * S^.sps^.ctb_height) then
      Exit(AVERROR_INVALIDDATA);
    if SH^.dependent_slice_segment_flag = 0 then
    begin
      SH^.slice_addr := SH^.slice_segment_addr;
      Inc(S^.slice_idx);
    end;
  end
  else
  begin
    SH^.slice_segment_addr := 0;
    SH^.slice_addr := 0;
    S^.slice_idx := 0;
    S^.slice_initialized := 0;
  end;

  if SH^.dependent_slice_segment_flag = 0 then
  begin
    S^.slice_initialized := 0;
    for I := 0 to S^.pps^.num_extra_slice_header_bits - 1 do
      skip_bits(GB^, 1);
    SH^.slice_type := Integer(get_ue_golomb_long(GB^));
    if not ((SH^.slice_type = I_SLICE) or (SH^.slice_type = P_SLICE) or
            (SH^.slice_type = B_SLICE)) then
      Exit(AVERROR_INVALIDDATA);
    if IS_IRAP(S) and (SH^.slice_type <> I_SLICE) then
      Exit(AVERROR_INVALIDDATA);

    SH^.pic_output_flag := 1;
    if S^.pps^.output_flag_present_flag <> 0 then
      SH^.pic_output_flag := get_bits1(GB^);
    if S^.sps^.separate_colour_plane_flag <> 0 then
      SH^.colour_plane_id := Byte(get_bits(GB^, 2));

    if not IS_IDR(S) then
    begin
      SH^.pic_order_cnt_lsb := Integer(get_bits(GB^, S^.sps^.log2_max_poc_lsb));
      Poc := ff_hevc_compute_poc(S, SH^.pic_order_cnt_lsb);
      if (SH^.first_slice_in_pic_flag = 0) and (Poc <> S^.poc) then
        Poc := S^.poc;
      S^.poc := Poc;
      short_term_ref_pic_set_sps_flag := Integer(get_bits1(GB^));
      if short_term_ref_pic_set_sps_flag = 0 then
      begin
        Ret := ff_hevc_decode_short_term_rps(S, @SH^.slice_rps, S^.sps, 1);
        if Ret < 0 then Exit(Ret);
        SH^.short_term_rps := @SH^.slice_rps;
      end
      else
      begin
        if S^.sps^.nb_st_rps = 0 then Exit(AVERROR_INVALIDDATA);
        numbits := av_ceil_log2_c(S^.sps^.nb_st_rps);
        if numbits > 0 then rps_idx := Integer(get_bits(GB^, numbits)) else rps_idx := 0;
        SH^.short_term_rps := @S^.sps^.st_rps[rps_idx];
      end;
      Ret := decode_lt_rps(S, @SH^.long_term_rps, GB);
      if S^.sps^.sps_temporal_mvp_enabled_flag <> 0 then
        SH^.slice_temporal_mvp_enabled_flag := get_bits1(GB^)
      else
        SH^.slice_temporal_mvp_enabled_flag := 0;
    end
    else
    begin
      SH^.short_term_rps := nil;
      S^.poc := 0;
    end;

    if (S^.temporal_id = 0) and
       (S^.nal_unit_type <> NAL_TRAIL_N) and (S^.nal_unit_type <> NAL_TSA_N) and
       (S^.nal_unit_type <> NAL_STSA_N) and (S^.nal_unit_type <> NAL_RADL_N) and
       (S^.nal_unit_type <> NAL_RADL_R) and (S^.nal_unit_type <> NAL_RASL_N) and
       (S^.nal_unit_type <> NAL_RASL_R) then
      S^.pocTid0 := S^.poc;

    if S^.sps^.sao_enabled <> 0 then
    begin
      SH^.slice_sample_adaptive_offset_flag[0] := get_bits1(GB^);
      if S^.sps^.chroma_format_idc <> 0 then
      begin
        SH^.slice_sample_adaptive_offset_flag[1] := get_bits1(GB^);
        SH^.slice_sample_adaptive_offset_flag[2] := SH^.slice_sample_adaptive_offset_flag[1];
      end
      else
      begin
        SH^.slice_sample_adaptive_offset_flag[1] := 0;
        SH^.slice_sample_adaptive_offset_flag[2] := 0;
      end;
    end
    else
    begin
      SH^.slice_sample_adaptive_offset_flag[0] := 0;
      SH^.slice_sample_adaptive_offset_flag[1] := 0;
      SH^.slice_sample_adaptive_offset_flag[2] := 0;
    end;

    SH^.nb_refs[0] := 0;
    SH^.nb_refs[1] := 0;
    if (SH^.slice_type = P_SLICE) or (SH^.slice_type = B_SLICE) then
    begin
      SH^.nb_refs[0] := Cardinal(S^.pps^.num_ref_idx_l0_default_active);
      if SH^.slice_type = B_SLICE then
        SH^.nb_refs[1] := Cardinal(S^.pps^.num_ref_idx_l1_default_active);
      if get_bits1(GB^) <> 0 then
      begin
        SH^.nb_refs[0] := get_ue_golomb_long(GB^) + 1;
        if SH^.slice_type = B_SLICE then
          SH^.nb_refs[1] := get_ue_golomb_long(GB^) + 1;
      end;
      if (SH^.nb_refs[0] > 16) or (SH^.nb_refs[1] > 16) then
        Exit(AVERROR_INVALIDDATA);

      SH^.rpl_modification_flag[0] := 0;
      SH^.rpl_modification_flag[1] := 0;
      nb_refs := ff_hevc_frame_nb_refs(S);
      if nb_refs = 0 then Exit(AVERROR_INVALIDDATA);

      if (S^.pps^.lists_modification_present_flag <> 0) and (nb_refs > 1) then
      begin
        SH^.rpl_modification_flag[0] := get_bits1(GB^);
        if SH^.rpl_modification_flag[0] <> 0 then
          for I := 0 to Integer(SH^.nb_refs[0]) - 1 do
            SH^.list_entry_lx[0][I] := get_bits(GB^, av_ceil_log2_c(nb_refs));
        if SH^.slice_type = B_SLICE then
        begin
          SH^.rpl_modification_flag[1] := get_bits1(GB^);
          if SH^.rpl_modification_flag[1] = 1 then
            for I := 0 to Integer(SH^.nb_refs[1]) - 1 do
              SH^.list_entry_lx[1][I] := get_bits(GB^, av_ceil_log2_c(nb_refs));
        end;
      end;

      if SH^.slice_type = B_SLICE then
        SH^.mvd_l1_zero_flag := get_bits1(GB^);
      if S^.pps^.cabac_init_present_flag <> 0 then
        SH^.cabac_init_flag := get_bits1(GB^)
      else
        SH^.cabac_init_flag := 0;

      SH^.collocated_ref_idx := 0;
      if SH^.slice_temporal_mvp_enabled_flag <> 0 then
      begin
        SH^.collocated_list := 0;
        if SH^.slice_type = B_SLICE then
          SH^.collocated_list := Byte(Ord(get_bits1(GB^) = 0));
        if SH^.nb_refs[SH^.collocated_list] > 1 then
        begin
          SH^.collocated_ref_idx := get_ue_golomb_long(GB^);
          if SH^.collocated_ref_idx >= SH^.nb_refs[SH^.collocated_list] then
            Exit(AVERROR_INVALIDDATA);
        end;
      end;

      if ((S^.pps^.weighted_pred_flag <> 0) and (SH^.slice_type = P_SLICE)) or
         ((S^.pps^.weighted_bipred_flag <> 0) and (SH^.slice_type = B_SLICE)) then
        pred_weight_table(S, GB);

      SH^.max_num_merge_cand := 5 - get_ue_golomb_long(GB^);
      if (SH^.max_num_merge_cand < 1) or (SH^.max_num_merge_cand > 5) then
        Exit(AVERROR_INVALIDDATA);
    end;

    SH^.slice_qp_delta := get_se_golomb(GB^);
    if S^.pps^.pic_slice_level_chroma_qp_offsets_present_flag <> 0 then
    begin
      SH^.slice_cb_qp_offset := get_se_golomb(GB^);
      SH^.slice_cr_qp_offset := get_se_golomb(GB^);
    end
    else
    begin
      SH^.slice_cb_qp_offset := 0;
      SH^.slice_cr_qp_offset := 0;
    end;
    if S^.pps^.chroma_qp_offset_list_enabled_flag <> 0 then
      SH^.cu_chroma_qp_offset_enabled_flag := get_bits1(GB^)
    else
      SH^.cu_chroma_qp_offset_enabled_flag := 0;

    if S^.pps^.deblocking_filter_control_present_flag <> 0 then
    begin
      deblocking_filter_override_flag := 0;
      if S^.pps^.deblocking_filter_override_enabled_flag <> 0 then
        deblocking_filter_override_flag := Integer(get_bits1(GB^));
      if deblocking_filter_override_flag <> 0 then
      begin
        SH^.disable_deblocking_filter_flag := get_bits1(GB^);
        if SH^.disable_deblocking_filter_flag = 0 then
        begin
          SH^.beta_offset := get_se_golomb(GB^) * 2;
          SH^.tc_offset := get_se_golomb(GB^) * 2;
        end;
      end
      else
      begin
        SH^.disable_deblocking_filter_flag := S^.pps^.disable_dbf;
        SH^.beta_offset := S^.pps^.beta_offset;
        SH^.tc_offset := S^.pps^.tc_offset;
      end;
    end
    else
    begin
      SH^.disable_deblocking_filter_flag := 0;
      SH^.beta_offset := 0;
      SH^.tc_offset := 0;
    end;

    if (S^.pps^.seq_loop_filter_across_slices_enabled_flag <> 0) and
       ((SH^.slice_sample_adaptive_offset_flag[0] <> 0) or
        (SH^.slice_sample_adaptive_offset_flag[1] <> 0) or
        (SH^.disable_deblocking_filter_flag = 0)) then
      SH^.slice_loop_filter_across_slices_enabled_flag := get_bits1(GB^)
    else
      SH^.slice_loop_filter_across_slices_enabled_flag :=
        S^.pps^.seq_loop_filter_across_slices_enabled_flag;
  end
  else if S^.slice_initialized = 0 then
    Exit(AVERROR_INVALIDDATA);

  SH^.num_entry_point_offsets := 0;
  if (S^.pps^.tiles_enabled_flag <> 0) or (S^.pps^.entropy_coding_sync_enabled_flag <> 0) then
  begin
    SH^.num_entry_point_offsets := Integer(get_ue_golomb_long(GB^));
    if SH^.num_entry_point_offsets > 0 then
    begin
      offset_len := Integer(get_ue_golomb_long(GB^)) + 1;
      segments := offset_len shr 4;
      rest := offset_len and 15;
      av_freep(@SH^.entry_point_offset);
      av_freep(@SH^.offset);
      av_freep(@SH^.size);
      SH^.entry_point_offset := av_malloc_array(SH^.num_entry_point_offsets, SizeOf(Integer));
      SH^.offset := av_malloc_array(SH^.num_entry_point_offsets, SizeOf(Integer));
      SH^.size := av_malloc_array(SH^.num_entry_point_offsets, SizeOf(Integer));
      if (SH^.entry_point_offset = nil) or (SH^.offset = nil) or (SH^.size = nil) then
      begin
        SH^.num_entry_point_offsets := 0;
        Exit(AVERROR_ENOMEM);
      end;
      for I := 0 to SH^.num_entry_point_offsets - 1 do
      begin
        Val := 0;
        for J := 0 to segments - 1 do
        begin
          Val := Val shl 16;
          Val := Val + Integer(get_bits(GB^, 16));
        end;
        if rest <> 0 then
        begin
          Val := Val shl rest;
          Val := Val + Integer(get_bits(GB^, rest));
        end;
        SH^.entry_point_offset[I] := Val + 1;
      end;
    end;
  end;

  if S^.pps^.slice_header_extension_present_flag <> 0 then
  begin
    Length_ := get_ue_golomb_long(GB^);
    if Int64(Length_) * 8 > get_bits_left(GB^) then Exit(AVERROR_INVALIDDATA);
    for I := 0 to Integer(Length_) - 1 do
      skip_bits(GB^, 8);
  end;

  SH^.slice_qp := Int8(26 + S^.pps^.pic_init_qp_minus26 + SH^.slice_qp_delta);
  if (SH^.slice_qp > 51) or (SH^.slice_qp < -S^.sps^.qp_bd_offset) then
    Exit(AVERROR_INVALIDDATA);

  SH^.slice_ctb_addr_rs := Integer(SH^.slice_segment_addr);
  if (S^.sh.slice_ctb_addr_rs = 0) and (S^.sh.dependent_slice_segment_flag <> 0) then
    Exit(AVERROR_INVALIDDATA);
  if get_bits_left(GB^) < 0 then Exit(AVERROR_INVALIDDATA);

  S^.HEVClc^.first_qp_group := Byte(Ord(S^.sh.dependent_slice_segment_flag = 0));
  if S^.pps^.cu_qp_delta_enabled_flag = 0 then
    S^.HEVClc^.qp_y := S^.sh.slice_qp;
  S^.slice_initialized := 1;
  S^.HEVClc^.tu.cu_qp_offset_cb := 0;
  S^.HEVClc^.tu.cu_qp_offset_cr := 0;
  Result := 0;
end;

procedure hls_sao_param(S: PHEVCContext; RX, RY: Integer);
var
  LC: PHEVCLocalContext;
  sao_merge_left_flag, sao_merge_up_flag: Integer;
  Sao, SaoLeft, SaoUp: PSAOParams;
  CIdx, I, c_count, log2_sao_offset_scale: Integer;
  CW: Integer;
begin
  LC := S^.HEVClc;
  sao_merge_left_flag := 0;
  sao_merge_up_flag := 0;
  CW := S^.sps^.ctb_width;
  Sao := @S^.sao[RY * CW + RX];

  if (S^.sh.slice_sample_adaptive_offset_flag[0] <> 0) or
     (S^.sh.slice_sample_adaptive_offset_flag[1] <> 0) then
  begin
    if RX > 0 then
      if LC^.ctb_left_flag <> 0 then
        sao_merge_left_flag := ff_hevc_sao_merge_flag_decode(S);
    if (RY > 0) and (sao_merge_left_flag = 0) then
      if LC^.ctb_up_flag <> 0 then
        sao_merge_up_flag := ff_hevc_sao_merge_flag_decode(S);
  end;

  SaoLeft := @S^.sao[RY * CW + (RX - 1)];
  SaoUp := @S^.sao[(RY - 1) * CW + RX];

  if S^.sps^.chroma_format_idc <> 0 then c_count := 3 else c_count := 1;
  for CIdx := 0 to c_count - 1 do
  begin
    if CIdx = 0 then log2_sao_offset_scale := S^.pps^.log2_sao_offset_scale_luma
    else log2_sao_offset_scale := S^.pps^.log2_sao_offset_scale_chroma;

    if S^.sh.slice_sample_adaptive_offset_flag[CIdx] = 0 then
    begin
      Sao^.type_idx[CIdx] := SAO_NOT_APPLIED;
      Continue;
    end;

    if CIdx = 2 then
    begin
      Sao^.type_idx[2] := Sao^.type_idx[1];
      Sao^.eo_class[2] := Sao^.eo_class[1];
    end
    else
    begin
      if (sao_merge_up_flag = 0) and (sao_merge_left_flag = 0) then
        Sao^.type_idx[CIdx] := Byte(ff_hevc_sao_type_idx_decode(S))
      else if sao_merge_left_flag <> 0 then
        Sao^.type_idx[CIdx] := SaoLeft^.type_idx[CIdx]
      else
        Sao^.type_idx[CIdx] := SaoUp^.type_idx[CIdx];
    end;

    if Sao^.type_idx[CIdx] = SAO_NOT_APPLIED then Continue;

    for I := 0 to 3 do
      if (sao_merge_up_flag = 0) and (sao_merge_left_flag = 0) then
        Sao^.offset_abs[CIdx][I] := ff_hevc_sao_offset_abs_decode(S)
      else if sao_merge_left_flag <> 0 then
        Sao^.offset_abs[CIdx][I] := SaoLeft^.offset_abs[CIdx][I]
      else
        Sao^.offset_abs[CIdx][I] := SaoUp^.offset_abs[CIdx][I];

    if Sao^.type_idx[CIdx] = SAO_BAND then
    begin
      for I := 0 to 3 do
      begin
        if Sao^.offset_abs[CIdx][I] <> 0 then
        begin
          if (sao_merge_up_flag = 0) and (sao_merge_left_flag = 0) then
            Sao^.offset_sign[CIdx][I] := ff_hevc_sao_offset_sign_decode(S)
          else if sao_merge_left_flag <> 0 then
            Sao^.offset_sign[CIdx][I] := SaoLeft^.offset_sign[CIdx][I]
          else
            Sao^.offset_sign[CIdx][I] := SaoUp^.offset_sign[CIdx][I];
        end
        else
          Sao^.offset_sign[CIdx][I] := 0;
      end;
      if (sao_merge_up_flag = 0) and (sao_merge_left_flag = 0) then
        Sao^.band_position[CIdx] := Byte(ff_hevc_sao_band_position_decode(S))
      else if sao_merge_left_flag <> 0 then
        Sao^.band_position[CIdx] := SaoLeft^.band_position[CIdx]
      else
        Sao^.band_position[CIdx] := SaoUp^.band_position[CIdx];
    end
    else if CIdx <> 2 then
    begin
      if (sao_merge_up_flag = 0) and (sao_merge_left_flag = 0) then
        Sao^.eo_class[CIdx] := ff_hevc_sao_eo_class_decode(S)
      else if sao_merge_left_flag <> 0 then
        Sao^.eo_class[CIdx] := SaoLeft^.eo_class[CIdx]
      else
        Sao^.eo_class[CIdx] := SaoUp^.eo_class[CIdx];
    end;

    Sao^.offset_val[CIdx][0] := 0;
    for I := 0 to 3 do
    begin
      Sao^.offset_val[CIdx][I + 1] := Int16(Sao^.offset_abs[CIdx][I]);
      if Sao^.type_idx[CIdx] = SAO_EDGE then
      begin
        if I > 1 then
          Sao^.offset_val[CIdx][I + 1] := -Sao^.offset_val[CIdx][I + 1];
      end
      else if Sao^.offset_sign[CIdx][I] <> 0 then
        Sao^.offset_val[CIdx][I + 1] := -Sao^.offset_val[CIdx][I + 1];
      Sao^.offset_val[CIdx][I + 1] :=
        Int16(Sao^.offset_val[CIdx][I + 1] shl log2_sao_offset_scale);
    end;
  end;
end;

function hls_cross_component_pred(S: PHEVCContext; Idx: Integer): Integer;
var
  LC: PHEVCLocalContext;
  log2_res_scale_abs_plus1, res_scale_sign_flag: Integer;
begin
  LC := S^.HEVClc;
  log2_res_scale_abs_plus1 := ff_hevc_log2_res_scale_abs(S, Idx);
  if log2_res_scale_abs_plus1 <> 0 then
  begin
    res_scale_sign_flag := ff_hevc_res_scale_sign_flag(S, Idx);
    LC^.tu.res_scale_val := (1 shl (log2_res_scale_abs_plus1 - 1)) *
                            (1 - 2 * res_scale_sign_flag);
  end
  else
    LC^.tu.res_scale_val := 0;
  Result := 0;
end;

// Applies the cross-component predicted residual of one chroma plane when that
// plane has no coded residual of its own. Split out of hls_transform_unit so
// the Cb and Cr copies stay in sync; the reference has it twice inline.
procedure cross_pf_add(S: PHEVCContext; X0, Y0, log2_trafo_size_c, CIdx: Integer);
var
  LC: PHEVCLocalContext;
  Stride: PtrInt;
  hshift, vshift, Size, K: Integer;
  coeffs_y, coeffs: PInt16;
  Dst: PByte;
begin
  LC := S^.HEVClc;
  Stride := S^.frame^.linesize[CIdx];
  hshift := S^.sps^.hshift[CIdx];
  vshift := S^.sps^.vshift[CIdx];
  coeffs_y := PInt16(@LC^.edge_emu_buffer[0]);
  coeffs := PInt16(@LC^.edge_emu_buffer2[0]);
  Size := 1 shl log2_trafo_size_c;
  Dst := @S^.frame^.data[CIdx][(Y0 shr vshift) * Stride +
                               ((X0 shr hshift) shl S^.sps^.pixel_shift)];
  for K := 0 to Size * Size - 1 do
    coeffs[K] := Int16(SAR((LC^.tu.res_scale_val * coeffs_y[K]), 3));
  transform_add(log2_trafo_size_c - 2, Dst, coeffs, Stride, S^.sps^.bit_depth);
end;

function hls_transform_unit(S: PHEVCContext; X0, Y0, XBase, YBase,
  cb_xBase, cb_yBase, log2_cb_size, log2_trafo_size, trafo_depth,
  blk_idx, cbf_luma: Integer; cbf_cb, cbf_cr: PInteger): Integer;
var
  LC: PHEVCLocalContext;
  log2_trafo_size_c: Integer;
  I, trafo_size, scan_idx, scan_idx_c, cbf_chroma: Integer;
  trafo_size_h, trafo_size_v, CbCount, Size: Integer;
  cu_chroma_qp_offset_flag, cu_chroma_qp_offset_idx: Integer;
begin
  LC := S^.HEVClc;
  log2_trafo_size_c := log2_trafo_size - S^.sps^.hshift[1];

  if LC^.cu.pred_mode = MODE_INTRA then
  begin
    trafo_size := 1 shl log2_trafo_size;
    ff_hevc_set_neighbour_available(S, X0, Y0, trafo_size, trafo_size);
    intra_pred(S, X0, Y0, log2_trafo_size, 0);
  end;

  if S^.sps^.chroma_format_idc = 2 then CbCount := 2 else CbCount := 1;

  if (cbf_luma <> 0) or (cbf_cb[0] <> 0) or (cbf_cr[0] <> 0) or
     ((S^.sps^.chroma_format_idc = 2) and ((cbf_cb[1] <> 0) or (cbf_cr[1] <> 0))) then
  begin
    scan_idx := SCAN_DIAG;
    scan_idx_c := SCAN_DIAG;
    cbf_chroma := Ord((cbf_cb[0] <> 0) or (cbf_cr[0] <> 0) or
      ((S^.sps^.chroma_format_idc = 2) and ((cbf_cb[1] <> 0) or (cbf_cr[1] <> 0))));

    if (S^.pps^.cu_qp_delta_enabled_flag <> 0) and (LC^.tu.is_cu_qp_delta_coded = 0) then
    begin
      LC^.tu.cu_qp_delta := ff_hevc_cu_qp_delta_abs(S);
      if LC^.tu.cu_qp_delta <> 0 then
        if ff_hevc_cu_qp_delta_sign_flag(S) = 1 then
          LC^.tu.cu_qp_delta := -LC^.tu.cu_qp_delta;
      LC^.tu.is_cu_qp_delta_coded := 1;
      if (LC^.tu.cu_qp_delta < -(26 + S^.sps^.qp_bd_offset div 2)) or
         (LC^.tu.cu_qp_delta > (25 + S^.sps^.qp_bd_offset div 2)) then
        Exit(AVERROR_INVALIDDATA);
      ff_hevc_set_qPy(S, cb_xBase, cb_yBase, log2_cb_size);
    end;

    if (S^.sh.cu_chroma_qp_offset_enabled_flag <> 0) and (cbf_chroma <> 0) and
       (LC^.cu.cu_transquant_bypass_flag = 0) and
       (LC^.tu.is_cu_chroma_qp_offset_coded = 0) then
    begin
      cu_chroma_qp_offset_flag := ff_hevc_cu_chroma_qp_offset_flag(S);
      if cu_chroma_qp_offset_flag <> 0 then
      begin
        cu_chroma_qp_offset_idx := 0;
        if S^.pps^.chroma_qp_offset_list_len_minus1 > 0 then
          cu_chroma_qp_offset_idx := ff_hevc_cu_chroma_qp_offset_idx(S);
        LC^.tu.cu_qp_offset_cb := S^.pps^.cb_qp_offset_list[cu_chroma_qp_offset_idx];
        LC^.tu.cu_qp_offset_cr := S^.pps^.cr_qp_offset_list[cu_chroma_qp_offset_idx];
      end
      else
      begin
        LC^.tu.cu_qp_offset_cb := 0;
        LC^.tu.cu_qp_offset_cr := 0;
      end;
      LC^.tu.is_cu_chroma_qp_offset_coded := 1;
    end;

    if (LC^.cu.pred_mode = MODE_INTRA) and (log2_trafo_size < 4) then
    begin
      if (LC^.tu.intra_pred_mode >= 6) and (LC^.tu.intra_pred_mode <= 14) then
        scan_idx := SCAN_VERT
      else if (LC^.tu.intra_pred_mode >= 22) and (LC^.tu.intra_pred_mode <= 30) then
        scan_idx := SCAN_HORIZ;
      if (LC^.tu.intra_pred_mode_c >= 6) and (LC^.tu.intra_pred_mode_c <= 14) then
        scan_idx_c := SCAN_VERT
      else if (LC^.tu.intra_pred_mode_c >= 22) and (LC^.tu.intra_pred_mode_c <= 30) then
        scan_idx_c := SCAN_HORIZ;
    end;

    LC^.tu.cross_pf := 0;
    if cbf_luma <> 0 then
      ff_hevc_hls_residual_coding(S, X0, Y0, log2_trafo_size, scan_idx, 0);

    if S^.sps^.chroma_format_idc <> 0 then
    begin
      if (log2_trafo_size > 2) or (S^.sps^.chroma_format_idc = 3) then
      begin
        trafo_size_h := 1 shl (log2_trafo_size_c + S^.sps^.hshift[1]);
        trafo_size_v := 1 shl (log2_trafo_size_c + S^.sps^.vshift[1]);
        LC^.tu.cross_pf := Byte(Ord(
          (S^.pps^.cross_component_prediction_enabled_flag <> 0) and (cbf_luma <> 0) and
          ((LC^.cu.pred_mode = MODE_INTER) or (LC^.tu.chroma_mode_c = 4))));
        if LC^.tu.cross_pf <> 0 then
          hls_cross_component_pred(S, 0);

        // The reference reuses the loop counter `i` inside the cross_pf branch,
        // so that branch ends the chroma loop. Cross-component prediction is
        // only signalled for 4:4:4 (CbCount = 1), where it makes no difference;
        // replicated verbatim so 4:2:2 streams would behave identically.
        Size := 1 shl log2_trafo_size_c;
        I := 0;
        while I < CbCount do
        begin
          if LC^.cu.pred_mode = MODE_INTRA then
          begin
            ff_hevc_set_neighbour_available(S, X0, Y0 + (I shl log2_trafo_size_c),
              trafo_size_h, trafo_size_v);
            intra_pred(S, X0, Y0 + (I shl log2_trafo_size_c), log2_trafo_size_c, 1);
          end;
          if cbf_cb[I] <> 0 then
            ff_hevc_hls_residual_coding(S, X0, Y0 + (I shl log2_trafo_size_c),
              log2_trafo_size_c, scan_idx_c, 1)
          else if LC^.tu.cross_pf <> 0 then
          begin
            I := Size * Size;
            cross_pf_add(S, X0, Y0, log2_trafo_size_c, 1);
          end;
          Inc(I);
        end;

        if LC^.tu.cross_pf <> 0 then
          hls_cross_component_pred(S, 1);

        I := 0;
        while I < CbCount do
        begin
          if LC^.cu.pred_mode = MODE_INTRA then
          begin
            ff_hevc_set_neighbour_available(S, X0, Y0 + (I shl log2_trafo_size_c),
              trafo_size_h, trafo_size_v);
            intra_pred(S, X0, Y0 + (I shl log2_trafo_size_c), log2_trafo_size_c, 2);
          end;
          if cbf_cr[I] <> 0 then
            ff_hevc_hls_residual_coding(S, X0, Y0 + (I shl log2_trafo_size_c),
              log2_trafo_size_c, scan_idx_c, 2)
          else if LC^.tu.cross_pf <> 0 then
          begin
            I := Size * Size;
            cross_pf_add(S, X0, Y0, log2_trafo_size_c, 2);
          end;
          Inc(I);
        end;
      end
      else if blk_idx = 3 then
      begin
        trafo_size_h := 1 shl (log2_trafo_size + 1);
        trafo_size_v := 1 shl (log2_trafo_size + S^.sps^.vshift[1]);
        for I := 0 to CbCount - 1 do
        begin
          if LC^.cu.pred_mode = MODE_INTRA then
          begin
            ff_hevc_set_neighbour_available(S, XBase, YBase + (I shl log2_trafo_size),
              trafo_size_h, trafo_size_v);
            intra_pred(S, XBase, YBase + (I shl log2_trafo_size), log2_trafo_size, 1);
          end;
          if cbf_cb[I] <> 0 then
            ff_hevc_hls_residual_coding(S, XBase, YBase + (I shl log2_trafo_size),
              log2_trafo_size, scan_idx_c, 1);
        end;
        for I := 0 to CbCount - 1 do
        begin
          if LC^.cu.pred_mode = MODE_INTRA then
          begin
            ff_hevc_set_neighbour_available(S, XBase, YBase + (I shl log2_trafo_size),
              trafo_size_h, trafo_size_v);
            intra_pred(S, XBase, YBase + (I shl log2_trafo_size), log2_trafo_size, 2);
          end;
          if cbf_cr[I] <> 0 then
            ff_hevc_hls_residual_coding(S, XBase, YBase + (I shl log2_trafo_size),
              log2_trafo_size, scan_idx_c, 2);
        end;
      end;
    end;
  end
  else if (LC^.cu.pred_mode = MODE_INTRA) and (S^.sps^.chroma_format_idc <> 0) then
  begin
    if (log2_trafo_size > 2) or (S^.sps^.chroma_format_idc = 3) then
    begin
      trafo_size_h := 1 shl (log2_trafo_size_c + S^.sps^.hshift[1]);
      trafo_size_v := 1 shl (log2_trafo_size_c + S^.sps^.vshift[1]);
      ff_hevc_set_neighbour_available(S, X0, Y0, trafo_size_h, trafo_size_v);
      intra_pred(S, X0, Y0, log2_trafo_size_c, 1);
      intra_pred(S, X0, Y0, log2_trafo_size_c, 2);
      if S^.sps^.chroma_format_idc = 2 then
      begin
        ff_hevc_set_neighbour_available(S, X0, Y0 + (1 shl log2_trafo_size_c),
          trafo_size_h, trafo_size_v);
        intra_pred(S, X0, Y0 + (1 shl log2_trafo_size_c), log2_trafo_size_c, 1);
        intra_pred(S, X0, Y0 + (1 shl log2_trafo_size_c), log2_trafo_size_c, 2);
      end;
    end
    else if blk_idx = 3 then
    begin
      trafo_size_h := 1 shl (log2_trafo_size + 1);
      trafo_size_v := 1 shl (log2_trafo_size + S^.sps^.vshift[1]);
      ff_hevc_set_neighbour_available(S, XBase, YBase, trafo_size_h, trafo_size_v);
      intra_pred(S, XBase, YBase, log2_trafo_size, 1);
      intra_pred(S, XBase, YBase, log2_trafo_size, 2);
      if S^.sps^.chroma_format_idc = 2 then
      begin
        ff_hevc_set_neighbour_available(S, XBase, YBase + (1 shl log2_trafo_size),
          trafo_size_h, trafo_size_v);
        intra_pred(S, XBase, YBase + (1 shl log2_trafo_size), log2_trafo_size, 1);
        intra_pred(S, XBase, YBase + (1 shl log2_trafo_size), log2_trafo_size, 2);
      end;
    end;
  end;
  Result := 0;
end;

procedure set_deblocking_bypass(S: PHEVCContext; X0, Y0, log2_cb_size: Integer);
var
  cb_size, log2_min_pu_size, min_pu_width, x_end, y_end, I, J: Integer;
begin
  cb_size := 1 shl log2_cb_size;
  log2_min_pu_size := S^.sps^.log2_min_pu_size;
  min_pu_width := S^.sps^.min_pu_width;
  x_end := X0 + cb_size;
  if x_end > S^.sps^.width then x_end := S^.sps^.width;
  y_end := Y0 + cb_size;
  if y_end > S^.sps^.height then y_end := S^.sps^.height;
  for J := (Y0 shr log2_min_pu_size) to (y_end shr log2_min_pu_size) - 1 do
    for I := (X0 shr log2_min_pu_size) to (x_end shr log2_min_pu_size) - 1 do
      S^.is_pcm[I + J * min_pu_width] := 2;
end;

function hls_transform_tree(S: PHEVCContext; X0, Y0, XBase, YBase,
  cb_xBase, cb_yBase, log2_cb_size, log2_trafo_size, trafo_depth,
  blk_idx: Integer; base_cbf_cb, base_cbf_cr: PInteger): Integer;
var
  LC: PHEVCLocalContext;
  split_transform_flag: Integer;
  cbf_cb, cbf_cr: array[0..1] of Integer;
  Ret, inter_split, trafo_size_split, X1, Y1: Integer;
  min_tu_size, log2_min_tu_size, min_tu_width, cbf_luma, I, J, x_tu, y_tu: Integer;
begin
  LC := S^.HEVClc;
  cbf_cb[0] := base_cbf_cb[0];
  cbf_cb[1] := base_cbf_cb[1];
  cbf_cr[0] := base_cbf_cr[0];
  cbf_cr[1] := base_cbf_cr[1];

  if LC^.cu.intra_split_flag <> 0 then
  begin
    if trafo_depth = 1 then
    begin
      LC^.tu.intra_pred_mode := LC^.pu.intra_pred_mode[blk_idx];
      if S^.sps^.chroma_format_idc = 3 then
      begin
        LC^.tu.intra_pred_mode_c := LC^.pu.intra_pred_mode_c[blk_idx];
        LC^.tu.chroma_mode_c := LC^.pu.chroma_mode_c[blk_idx];
      end
      else
      begin
        LC^.tu.intra_pred_mode_c := LC^.pu.intra_pred_mode_c[0];
        LC^.tu.chroma_mode_c := LC^.pu.chroma_mode_c[0];
      end;
    end;
  end
  else
  begin
    LC^.tu.intra_pred_mode := LC^.pu.intra_pred_mode[0];
    LC^.tu.intra_pred_mode_c := LC^.pu.intra_pred_mode_c[0];
    LC^.tu.chroma_mode_c := LC^.pu.chroma_mode_c[0];
  end;

  if (log2_trafo_size <= S^.sps^.log2_max_trafo_size) and
     (log2_trafo_size > S^.sps^.log2_min_tb_size) and
     (trafo_depth < LC^.cu.max_trafo_depth) and
     not ((LC^.cu.intra_split_flag <> 0) and (trafo_depth = 0)) then
    split_transform_flag := ff_hevc_split_transform_flag_decode(S, log2_trafo_size)
  else
  begin
    inter_split := Ord((S^.sps^.max_transform_hierarchy_depth_inter = 0) and
                       (LC^.cu.pred_mode = MODE_INTER) and
                       (LC^.cu.part_mode <> PART_2Nx2N) and
                       (trafo_depth = 0));
    split_transform_flag := Ord((log2_trafo_size > S^.sps^.log2_max_trafo_size) or
                                ((LC^.cu.intra_split_flag <> 0) and (trafo_depth = 0)) or
                                (inter_split <> 0));
  end;

  if ((log2_trafo_size > 2) or (S^.sps^.chroma_format_idc = 3)) and
     (S^.sps^.chroma_format_idc <> 0) then
  begin
    if (trafo_depth = 0) or (cbf_cb[0] <> 0) then
    begin
      cbf_cb[0] := ff_hevc_cbf_cb_cr_decode(S, trafo_depth);
      if (S^.sps^.chroma_format_idc = 2) and
         ((split_transform_flag = 0) or (log2_trafo_size = 3)) then
        cbf_cb[1] := ff_hevc_cbf_cb_cr_decode(S, trafo_depth);
    end;
    if (trafo_depth = 0) or (cbf_cr[0] <> 0) then
    begin
      cbf_cr[0] := ff_hevc_cbf_cb_cr_decode(S, trafo_depth);
      if (S^.sps^.chroma_format_idc = 2) and
         ((split_transform_flag = 0) or (log2_trafo_size = 3)) then
        cbf_cr[1] := ff_hevc_cbf_cb_cr_decode(S, trafo_depth);
    end;
  end;

  if split_transform_flag <> 0 then
  begin
    trafo_size_split := 1 shl (log2_trafo_size - 1);
    X1 := X0 + trafo_size_split;
    Y1 := Y0 + trafo_size_split;
    Ret := hls_transform_tree(S, X0, Y0, X0, Y0, cb_xBase, cb_yBase, log2_cb_size,
      log2_trafo_size - 1, trafo_depth + 1, 0, @cbf_cb[0], @cbf_cr[0]);
    if Ret < 0 then Exit(Ret);
    Ret := hls_transform_tree(S, X1, Y0, X0, Y0, cb_xBase, cb_yBase, log2_cb_size,
      log2_trafo_size - 1, trafo_depth + 1, 1, @cbf_cb[0], @cbf_cr[0]);
    if Ret < 0 then Exit(Ret);
    Ret := hls_transform_tree(S, X0, Y1, X0, Y0, cb_xBase, cb_yBase, log2_cb_size,
      log2_trafo_size - 1, trafo_depth + 1, 2, @cbf_cb[0], @cbf_cr[0]);
    if Ret < 0 then Exit(Ret);
    Ret := hls_transform_tree(S, X1, Y1, X0, Y0, cb_xBase, cb_yBase, log2_cb_size,
      log2_trafo_size - 1, trafo_depth + 1, 3, @cbf_cb[0], @cbf_cr[0]);
    if Ret < 0 then Exit(Ret);
  end
  else
  begin
    min_tu_size := 1 shl S^.sps^.log2_min_tb_size;
    log2_min_tu_size := S^.sps^.log2_min_tb_size;
    min_tu_width := S^.sps^.min_tb_width;
    cbf_luma := 1;
    if (LC^.cu.pred_mode = MODE_INTRA) or (trafo_depth <> 0) or
       (cbf_cb[0] <> 0) or (cbf_cr[0] <> 0) or
       ((S^.sps^.chroma_format_idc = 2) and ((cbf_cb[1] <> 0) or (cbf_cr[1] <> 0))) then
      cbf_luma := ff_hevc_cbf_luma_decode(S, trafo_depth);

    Ret := hls_transform_unit(S, X0, Y0, XBase, YBase, cb_xBase, cb_yBase,
      log2_cb_size, log2_trafo_size, trafo_depth, blk_idx, cbf_luma,
      @cbf_cb[0], @cbf_cr[0]);
    if Ret < 0 then Exit(Ret);

    if cbf_luma <> 0 then
    begin
      I := 0;
      while I < (1 shl log2_trafo_size) do
      begin
        J := 0;
        while J < (1 shl log2_trafo_size) do
        begin
          x_tu := (X0 + J) shr log2_min_tu_size;
          y_tu := (Y0 + I) shr log2_min_tu_size;
          S^.cbf_luma[y_tu * min_tu_width + x_tu] := 1;
          Inc(J, min_tu_size);
        end;
        Inc(I, min_tu_size);
      end;
    end;

    if S^.sh.disable_deblocking_filter_flag = 0 then
    begin
      ff_hevc_deblocking_boundary_strengths(S, X0, Y0, log2_trafo_size);
      if (S^.pps^.transquant_bypass_enable_flag <> 0) and
         (LC^.cu.cu_transquant_bypass_flag <> 0) then
        set_deblocking_bypass(S, X0, Y0, log2_trafo_size);
    end;
  end;
  Result := 0;
end;

function hls_pcm_sample(S: PHEVCContext; X0, Y0, log2_cb_size: Integer): Integer;
var
  LC: PHEVCLocalContext;
  GB: TGetBitContext;
  cb_size, stride0, stride1, stride2, Length_, Ret: Integer;
  dst0, dst1, dst2, pcm: PByte;
begin
  LC := S^.HEVClc;
  cb_size := 1 shl log2_cb_size;
  stride0 := S^.frame^.linesize[0];
  dst0 := @S^.frame^.data[0][Y0 * stride0 + (X0 shl S^.sps^.pixel_shift)];
  stride1 := S^.frame^.linesize[1];
  stride2 := S^.frame^.linesize[2];

  Length_ := cb_size * cb_size * S^.sps^.pcm.bit_depth +
    (((cb_size shr S^.sps^.hshift[1]) * (cb_size shr S^.sps^.vshift[1])) +
     ((cb_size shr S^.sps^.hshift[2]) * (cb_size shr S^.sps^.vshift[2]))) *
    S^.sps^.pcm.bit_depth_chroma;
  pcm := skip_bytes(LC^.cc, (Length_ + 7) shr 3);

  if S^.sh.disable_deblocking_filter_flag = 0 then
    ff_hevc_deblocking_boundary_strengths(S, X0, Y0, log2_cb_size);

  Ret := init_get_bits(GB, pcm, Length_);
  if Ret < 0 then Exit(Ret);

  put_pcm(dst0, stride0, cb_size, cb_size, @GB,
    S^.sps^.pcm.bit_depth, S^.sps^.bit_depth);

  // The reference computes and writes both chroma planes unconditionally; for
  // monochrome there is no plane 1/2 to write to, so skip them. Chroma output
  // is unaffected -- there is none.
  if S^.sps^.chroma_format_idc <> 0 then
  begin
    dst1 := @S^.frame^.data[1][(Y0 shr S^.sps^.vshift[1]) * stride1 +
                               ((X0 shr S^.sps^.hshift[1]) shl S^.sps^.pixel_shift)];
    dst2 := @S^.frame^.data[2][(Y0 shr S^.sps^.vshift[2]) * stride2 +
                               ((X0 shr S^.sps^.hshift[2]) shl S^.sps^.pixel_shift)];
    put_pcm(dst1, stride1, cb_size shr S^.sps^.hshift[1], cb_size shr S^.sps^.vshift[1],
      @GB, S^.sps^.pcm.bit_depth_chroma, S^.sps^.bit_depth);
    put_pcm(dst2, stride2, cb_size shr S^.sps^.hshift[2], cb_size shr S^.sps^.vshift[2],
      @GB, S^.sps^.pcm.bit_depth_chroma, S^.sps^.bit_depth);
  end;
  Result := 0;
end;

const
  EDGE_EMU_STRIDE_PIXELS = 80;

procedure luma_mc_uni(S: PHEVCContext; Dst: PByte; DstStride: PtrInt;
  Ref: PAVFrame; MV: PMv; x_off, y_off, block_w, block_h,
  luma_weight, luma_offset: Integer);
var
  LC: PHEVCLocalContext;
  Src: PByte;
  SrcStride: PtrInt;
  pic_width, pic_height, Mx, My, weight_flag: Integer;
  edge_emu_stride, Offset, buf_offset: Integer;
begin
  LC := S^.HEVClc;
  Src := Ref^.data[0];
  SrcStride := Ref^.linesize[0];
  pic_width := S^.sps^.width;
  pic_height := S^.sps^.height;
  Mx := MV^.x and 3;
  My := MV^.y and 3;
  weight_flag := Ord(((S^.sh.slice_type = P_SLICE) and (S^.pps^.weighted_pred_flag <> 0)) or
                     ((S^.sh.slice_type = B_SLICE) and (S^.pps^.weighted_bipred_flag <> 0)));
  // ff_hevc_pel_weight would give the width index here; libbpg fills every width
  // slot of the dispatch table with the same function, so it is not needed.
  x_off := x_off + SAR(MV^.x, 2);
  y_off := y_off + SAR(MV^.y, 2);
  Src := Src + y_off * SrcStride + (x_off shl S^.sps^.pixel_shift);

  if (x_off < 3) or (y_off < 4) or
     (x_off >= pic_width - block_w - 4) or
     (y_off >= pic_height - block_h - 4) then
  begin
    edge_emu_stride := EDGE_EMU_STRIDE_PIXELS shl S^.sps^.pixel_shift;
    Offset := 3 * SrcStride + (3 shl S^.sps^.pixel_shift);
    buf_offset := 3 * edge_emu_stride + (3 shl S^.sps^.pixel_shift);
    ff_emulated_edge_mc(@LC^.edge_emu_buffer[0], Src - Offset,
      edge_emu_stride, SrcStride, block_w + 7, block_h + 7,
      x_off - 3, y_off - 3, pic_width, pic_height);
    Src := @LC^.edge_emu_buffer[buf_offset];
    SrcStride := edge_emu_stride;
  end;

  if weight_flag = 0 then
    put_hevc_qpel_uni(Dst, DstStride, Src, SrcStride, block_h, Mx, My,
      block_w, S^.sps^.bit_depth)
  else
    put_hevc_qpel_uni_w(Dst, DstStride, Src, SrcStride, block_h,
      S^.sh.luma_log2_weight_denom, luma_weight, luma_offset, Mx, My,
      block_w, S^.sps^.bit_depth);
end;

procedure chroma_mc_uni(S: PHEVCContext; Dst0: PByte; DstStride: PtrInt;
  Src0: PByte; SrcStride: PtrInt; RefList, x_off, y_off, block_w, block_h: Integer;
  current_mv: PMvField; chroma_weight, chroma_offset: Integer);
var
  LC: PHEVCLocalContext;
  pic_width, pic_height, weight_flag, hshift, vshift: Integer;
  MV: PMv;
  Mx, My, _mx, _my: Integer;
  edge_emu_stride, offset0, buf_offset0: Integer;
begin
  LC := S^.HEVClc;
  pic_width := S^.sps^.width shr S^.sps^.hshift[1];
  pic_height := S^.sps^.height shr S^.sps^.vshift[1];
  MV := @current_mv^.mv[RefList];
  weight_flag := Ord(((S^.sh.slice_type = P_SLICE) and (S^.pps^.weighted_pred_flag <> 0)) or
                     ((S^.sh.slice_type = B_SLICE) and (S^.pps^.weighted_bipred_flag <> 0)));
  hshift := S^.sps^.hshift[1];
  vshift := S^.sps^.vshift[1];
  Mx := MV^.x and ((1 shl (2 + hshift)) - 1);
  My := MV^.y and ((1 shl (2 + vshift)) - 1);
  _mx := Mx shl (1 - hshift);
  _my := My shl (1 - vshift);
  x_off := x_off + SAR(MV^.x, 2 + hshift);
  y_off := y_off + SAR(MV^.y, 2 + vshift);
  Src0 := Src0 + y_off * SrcStride + (x_off shl S^.sps^.pixel_shift);

  if (x_off < 1) or (y_off < 2) or
     (x_off >= pic_width - block_w - 2) or
     (y_off >= pic_height - block_h - 2) then
  begin
    edge_emu_stride := EDGE_EMU_STRIDE_PIXELS shl S^.sps^.pixel_shift;
    offset0 := SrcStride + (1 shl S^.sps^.pixel_shift);
    buf_offset0 := edge_emu_stride + (1 shl S^.sps^.pixel_shift);
    ff_emulated_edge_mc(@LC^.edge_emu_buffer[0], Src0 - offset0,
      edge_emu_stride, SrcStride, block_w + 3, block_h + 3,
      x_off - 1, y_off - 1, pic_width, pic_height);
    Src0 := @LC^.edge_emu_buffer[buf_offset0];
    SrcStride := edge_emu_stride;
  end;

  if weight_flag = 0 then
    put_hevc_epel_uni(Dst0, DstStride, Src0, SrcStride, block_h, _mx, _my,
      block_w, S^.sps^.bit_depth)
  else
    put_hevc_epel_uni_w(Dst0, DstStride, Src0, SrcStride, block_h,
      S^.sh.chroma_log2_weight_denom, chroma_weight, chroma_offset, _mx, _my,
      block_w, S^.sps^.bit_depth);
end;

procedure hls_prediction_unit(S: PHEVCContext; X0, Y0, nPbW, nPbH,
  log2_cb_size, partIdx, Idx: Integer);
var
  LC: PHEVCLocalContext;
  merge_idx: Integer;
  current_mv: TMvField;
  min_pu_width: Integer;
  tab_mvf: PMvField;
  refPicList: PRefPicList;
  ref0, ref1: PHEVCFrame;
  dst0, dst1, dst2: PByte;
  log2_min_cb_size, min_cb_width, x_cb, y_cb: Integer;
  ref_idx, mvp_flag: array[0..1] of Integer;
  x_pu, y_pu, I, J, inter_pred_idc: Integer;
  x0_c, y0_c, nPbW_c, nPbH_c: Integer;
  RI: Integer;
begin
  LC := S^.HEVClc;
  merge_idx := 0;
  FillChar(current_mv, SizeOf(current_mv), 0);
  min_pu_width := S^.sps^.min_pu_width;
  tab_mvf := S^.ref^.tab_mvf;
  refPicList := S^.ref^.refPicList;
  ref0 := nil;
  ref1 := nil;

  dst0 := @S^.frame^.data[0][(Y0 shr S^.sps^.vshift[0]) * S^.frame^.linesize[0] +
                             ((X0 shr S^.sps^.hshift[0]) shl S^.sps^.pixel_shift)];
  if S^.sps^.chroma_format_idc <> 0 then
  begin
    dst1 := @S^.frame^.data[1][(Y0 shr S^.sps^.vshift[1]) * S^.frame^.linesize[1] +
                               ((X0 shr S^.sps^.hshift[1]) shl S^.sps^.pixel_shift)];
    dst2 := @S^.frame^.data[2][(Y0 shr S^.sps^.vshift[2]) * S^.frame^.linesize[2] +
                               ((X0 shr S^.sps^.hshift[2]) shl S^.sps^.pixel_shift)];
  end
  else
  begin
    dst1 := nil;
    dst2 := nil;
  end;

  log2_min_cb_size := S^.sps^.log2_min_cb_size;
  min_cb_width := S^.sps^.min_cb_width;
  x_cb := X0 shr log2_min_cb_size;
  y_cb := Y0 shr log2_min_cb_size;

  if S^.skip_flag[y_cb * min_cb_width + x_cb] <> 0 then
  begin
    if S^.sh.max_num_merge_cand > 1 then
      merge_idx := ff_hevc_merge_idx_decode(S)
    else
      merge_idx := 0;
    ff_hevc_luma_mv_merge_mode(S, X0, Y0, 1 shl log2_cb_size, 1 shl log2_cb_size,
      log2_cb_size, partIdx, merge_idx, @current_mv);
    x_pu := X0 shr S^.sps^.log2_min_pu_size;
    y_pu := Y0 shr S^.sps^.log2_min_pu_size;
    for J := 0 to (nPbH shr S^.sps^.log2_min_pu_size) - 1 do
      for I := 0 to (nPbW shr S^.sps^.log2_min_pu_size) - 1 do
        tab_mvf[(y_pu + J) * min_pu_width + x_pu + I] := current_mv;
  end
  else
  begin
    LC^.pu.merge_flag := Byte(ff_hevc_merge_flag_decode(S));
    if LC^.pu.merge_flag <> 0 then
    begin
      if S^.sh.max_num_merge_cand > 1 then
        merge_idx := ff_hevc_merge_idx_decode(S)
      else
        merge_idx := 0;
      ff_hevc_luma_mv_merge_mode(S, X0, Y0, nPbW, nPbH, log2_cb_size,
        partIdx, merge_idx, @current_mv);
      x_pu := X0 shr S^.sps^.log2_min_pu_size;
      y_pu := Y0 shr S^.sps^.log2_min_pu_size;
      for J := 0 to (nPbH shr S^.sps^.log2_min_pu_size) - 1 do
        for I := 0 to (nPbW shr S^.sps^.log2_min_pu_size) - 1 do
          tab_mvf[(y_pu + J) * min_pu_width + x_pu + I] := current_mv;
    end
    else
    begin
      inter_pred_idc := PRED_L0;
      ff_hevc_set_neighbour_available(S, X0, Y0, nPbW, nPbH);
      current_mv.pred_flag := 0;
      if S^.sh.slice_type = B_SLICE then
        inter_pred_idc := ff_hevc_inter_pred_idc_decode(S, nPbW, nPbH);

      if inter_pred_idc <> PRED_L1 then
      begin
        if S^.sh.nb_refs[0] <> 0 then
        begin
          ref_idx[0] := ff_hevc_ref_idx_lx_decode(S, Integer(S^.sh.nb_refs[0]));
          current_mv.ref_idx[0] := Int8(ref_idx[0]);
        end;
        current_mv.pred_flag := PF_L0;
        ff_hevc_hls_mvd_coding(S, X0, Y0, 0);
        mvp_flag[0] := ff_hevc_mvp_lx_flag_decode(S);
        ff_hevc_luma_mv_mvp_mode(S, X0, Y0, nPbW, nPbH, log2_cb_size,
          partIdx, merge_idx, @current_mv, mvp_flag[0], 0);
        current_mv.mv[0].x := Int16(current_mv.mv[0].x + LC^.pu.mvd.x);
        current_mv.mv[0].y := Int16(current_mv.mv[0].y + LC^.pu.mvd.y);
      end;

      if inter_pred_idc <> PRED_L0 then
      begin
        if S^.sh.nb_refs[1] <> 0 then
        begin
          ref_idx[1] := ff_hevc_ref_idx_lx_decode(S, Integer(S^.sh.nb_refs[1]));
          current_mv.ref_idx[1] := Int8(ref_idx[1]);
        end;
        if (S^.sh.mvd_l1_zero_flag = 1) and (inter_pred_idc = PRED_BI) then
        begin
          LC^.pu.mvd.x := 0;
          LC^.pu.mvd.y := 0;
        end
        else
          ff_hevc_hls_mvd_coding(S, X0, Y0, 1);
        current_mv.pred_flag := current_mv.pred_flag + PF_L1;
        mvp_flag[1] := ff_hevc_mvp_lx_flag_decode(S);
        ff_hevc_luma_mv_mvp_mode(S, X0, Y0, nPbW, nPbH, log2_cb_size,
          partIdx, merge_idx, @current_mv, mvp_flag[1], 1);
        current_mv.mv[1].x := Int16(current_mv.mv[1].x + LC^.pu.mvd.x);
        current_mv.mv[1].y := Int16(current_mv.mv[1].y + LC^.pu.mvd.y);
      end;

      x_pu := X0 shr S^.sps^.log2_min_pu_size;
      y_pu := Y0 shr S^.sps^.log2_min_pu_size;
      for J := 0 to (nPbH shr S^.sps^.log2_min_pu_size) - 1 do
        for I := 0 to (nPbW shr S^.sps^.log2_min_pu_size) - 1 do
          tab_mvf[(y_pu + J) * min_pu_width + x_pu + I] := current_mv;
    end;
  end;

  if (current_mv.pred_flag and PF_L0) <> 0 then
  begin
    ref0 := refPicList[0].ref[current_mv.ref_idx[0]];
    if ref0 = nil then Exit;
  end;
  if (current_mv.pred_flag and PF_L1) <> 0 then
  begin
    ref1 := refPicList[1].ref[current_mv.ref_idx[1]];
    if ref1 = nil then Exit;
  end;

  x0_c := X0 shr S^.sps^.hshift[1];
  y0_c := Y0 shr S^.sps^.vshift[1];
  nPbW_c := nPbW shr S^.sps^.hshift[1];
  nPbH_c := nPbH shr S^.sps^.vshift[1];

  if current_mv.pred_flag = PF_L0 then
  begin
    RI := current_mv.ref_idx[0];
    luma_mc_uni(S, dst0, S^.frame^.linesize[0], ref0^.Frame, @current_mv.mv[0],
      X0, Y0, nPbW, nPbH, S^.sh.luma_weight_l0[RI], S^.sh.luma_offset_l0[RI]);
    if S^.sps^.chroma_format_idc <> 0 then
    begin
      chroma_mc_uni(S, dst1, S^.frame^.linesize[1], ref0^.Frame^.data[1],
        ref0^.Frame^.linesize[1], 0, x0_c, y0_c, nPbW_c, nPbH_c, @current_mv,
        S^.sh.chroma_weight_l0[RI][0], S^.sh.chroma_offset_l0[RI][0]);
      chroma_mc_uni(S, dst2, S^.frame^.linesize[2], ref0^.Frame^.data[2],
        ref0^.Frame^.linesize[2], 0, x0_c, y0_c, nPbW_c, nPbH_c, @current_mv,
        S^.sh.chroma_weight_l0[RI][1], S^.sh.chroma_offset_l0[RI][1]);
    end;
  end
  else if current_mv.pred_flag = PF_L1 then
  begin
    RI := current_mv.ref_idx[1];
    luma_mc_uni(S, dst0, S^.frame^.linesize[0], ref1^.Frame, @current_mv.mv[1],
      X0, Y0, nPbW, nPbH, S^.sh.luma_weight_l1[RI], S^.sh.luma_offset_l1[RI]);
    if S^.sps^.chroma_format_idc <> 0 then
    begin
      chroma_mc_uni(S, dst1, S^.frame^.linesize[1], ref1^.Frame^.data[1],
        ref1^.Frame^.linesize[1], 1, x0_c, y0_c, nPbW_c, nPbH_c, @current_mv,
        S^.sh.chroma_weight_l1[RI][0], S^.sh.chroma_offset_l1[RI][0]);
      chroma_mc_uni(S, dst2, S^.frame^.linesize[2], ref1^.Frame^.data[2],
        ref1^.Frame^.linesize[2], 1, x0_c, y0_c, nPbW_c, nPbH_c, @current_mv,
        S^.sh.chroma_weight_l1[RI][1], S^.sh.chroma_offset_l1[RI][1]);
    end;
  end
  else if current_mv.pred_flag = PF_BI then
    // libbpg strips bi-prediction from hevcdsp and calls abort() here; BPG
    // streams never signal it. Raising keeps that contract visible.
    raise Exception.Create('bi-prediction is not supported by the BPG profile');
end;

// The three most probable modes, derived exactly as clause 8.4.2 requires.
// Shared by the decoder below and by the encoder in bpg_enc.
procedure luma_intra_candidates(S: PHEVCContext; X0, Y0: Integer;
  out candidate: TIntraCandidates);
var
  LC: PHEVCLocalContext;
  x_pu, y_pu, min_pu_width, x0b, y0b: Integer;
  cand_up, cand_left, y_ctb: Integer;
begin
  LC := S^.HEVClc;
  x_pu := X0 shr S^.sps^.log2_min_pu_size;
  y_pu := Y0 shr S^.sps^.log2_min_pu_size;
  min_pu_width := S^.sps^.min_pu_width;
  x0b := X0 and ((1 shl S^.sps^.log2_ctb_size) - 1);
  y0b := Y0 and ((1 shl S^.sps^.log2_ctb_size) - 1);
  if (LC^.ctb_up_flag <> 0) or (y0b <> 0) then
    cand_up := S^.tab_ipm[(y_pu - 1) * min_pu_width + x_pu]
  else
    cand_up := INTRA_DC;
  if (LC^.ctb_left_flag <> 0) or (x0b <> 0) then
    cand_left := S^.tab_ipm[y_pu * min_pu_width + x_pu - 1]
  else
    cand_left := INTRA_DC;
  y_ctb := (Y0 shr S^.sps^.log2_ctb_size) shl S^.sps^.log2_ctb_size;

  if (Y0 - 1) < y_ctb then cand_up := INTRA_DC;

  if cand_left = cand_up then
  begin
    if cand_left < 2 then
    begin
      candidate[0] := INTRA_PLANAR;
      candidate[1] := INTRA_DC;
      candidate[2] := INTRA_ANGULAR_26;
    end
    else
    begin
      candidate[0] := cand_left;
      candidate[1] := 2 + ((cand_left - 2 - 1 + 32) and 31);
      candidate[2] := 2 + ((cand_left - 2 + 1) and 31);
    end;
  end
  else
  begin
    candidate[0] := cand_left;
    candidate[1] := cand_up;
    if (candidate[0] <> INTRA_PLANAR) and (candidate[1] <> INTRA_PLANAR) then
      candidate[2] := INTRA_PLANAR
    else if (candidate[0] <> INTRA_DC) and (candidate[1] <> INTRA_DC) then
      candidate[2] := INTRA_DC
    else
      candidate[2] := INTRA_ANGULAR_26;
  end;

end;

function luma_intra_pred_mode(S: PHEVCContext; X0, Y0, pu_size,
  prev_intra_luma_pred_flag: Integer): Integer;
var
  LC: PHEVCLocalContext;
  x_pu, y_pu, min_pu_width, size_in_pus: Integer;
  tab_mvf: PMvField;
  I, J, intra_pred_mode, Tmp: Integer;
  candidate: TIntraCandidates;
begin
  LC := S^.HEVClc;
  x_pu := X0 shr S^.sps^.log2_min_pu_size;
  y_pu := Y0 shr S^.sps^.log2_min_pu_size;
  min_pu_width := S^.sps^.min_pu_width;
  size_in_pus := pu_size shr S^.sps^.log2_min_pu_size;
  tab_mvf := S^.ref^.tab_mvf;
  luma_intra_candidates(S, X0, Y0, candidate);

  if prev_intra_luma_pred_flag <> 0 then
    intra_pred_mode := candidate[LC^.pu.mpm_idx]
  else
  begin
    if candidate[0] > candidate[1] then
    begin Tmp := candidate[1]; candidate[1] := candidate[0]; candidate[0] := Tmp; end;
    if candidate[0] > candidate[2] then
    begin Tmp := candidate[2]; candidate[2] := candidate[0]; candidate[0] := Tmp; end;
    if candidate[1] > candidate[2] then
    begin Tmp := candidate[2]; candidate[2] := candidate[1]; candidate[1] := Tmp; end;
    intra_pred_mode := LC^.pu.rem_intra_luma_pred_mode;
    for I := 0 to 2 do
      if intra_pred_mode >= candidate[I] then Inc(intra_pred_mode);
  end;

  if size_in_pus = 0 then size_in_pus := 1;
  for I := 0 to size_in_pus - 1 do
  begin
    FillChar(S^.tab_ipm[(y_pu + I) * min_pu_width + x_pu], size_in_pus,
             Byte(intra_pred_mode));
    for J := 0 to size_in_pus - 1 do
      tab_mvf[(y_pu + J) * min_pu_width + x_pu + I].pred_flag := PF_INTRA;
  end;
  Result := intra_pred_mode;
end;

procedure luma_intra_pred_mode_enc(S: PHEVCContext; X0, Y0, pu_size, Mode: Integer;
  out PrevFlag, MpmIdx, RemMode: Integer);
var
  x_pu, y_pu, min_pu_width, size_in_pus, I, J, Tmp: Integer;
  candidate: TIntraCandidates;
  tab_mvf: PMvField;
begin
  luma_intra_candidates(S, X0, Y0, candidate);

  PrevFlag := 0;
  MpmIdx := 0;
  RemMode := 0;
  for I := 0 to 2 do
    if candidate[I] = Mode then
    begin
      PrevFlag := 1;
      MpmIdx := I;
      Break;
    end;

  if PrevFlag = 0 then
  begin
    // the decoder sorts the candidates and then bumps the remaining mode past
    // each one, so the encoder subtracts one for each candidate below Mode
    if candidate[0] > candidate[1] then
    begin Tmp := candidate[1]; candidate[1] := candidate[0]; candidate[0] := Tmp; end;
    if candidate[0] > candidate[2] then
    begin Tmp := candidate[2]; candidate[2] := candidate[0]; candidate[0] := Tmp; end;
    if candidate[1] > candidate[2] then
    begin Tmp := candidate[2]; candidate[2] := candidate[1]; candidate[1] := Tmp; end;
    RemMode := Mode;
    for I := 2 downto 0 do
      if Mode > candidate[I] then Dec(RemMode);
  end;

  // the same table updates the decoder performs
  x_pu := X0 shr S^.sps^.log2_min_pu_size;
  y_pu := Y0 shr S^.sps^.log2_min_pu_size;
  min_pu_width := S^.sps^.min_pu_width;
  size_in_pus := pu_size shr S^.sps^.log2_min_pu_size;
  if size_in_pus = 0 then size_in_pus := 1;
  tab_mvf := S^.ref^.tab_mvf;
  for I := 0 to size_in_pus - 1 do
  begin
    FillChar(S^.tab_ipm[(y_pu + I) * min_pu_width + x_pu], size_in_pus, Byte(Mode));
    for J := 0 to size_in_pus - 1 do
      tab_mvf[(y_pu + J) * min_pu_width + x_pu + I].pred_flag := PF_INTRA;
  end;
end;

procedure set_ct_depth(S: PHEVCContext; X0, Y0, log2_cb_size, ct_depth: Integer);
var
  Length_, x_cb, y_cb, Y: Integer;
begin
  Length_ := (1 shl log2_cb_size) shr S^.sps^.log2_min_cb_size;
  x_cb := X0 shr S^.sps^.log2_min_cb_size;
  y_cb := Y0 shr S^.sps^.log2_min_cb_size;
  for Y := 0 to Length_ - 1 do
    FillChar(S^.tab_ct_depth[(y_cb + Y) * S^.sps^.min_cb_width + x_cb], Length_,
             Byte(ct_depth));
end;

const
  tab_mode_idx: array[0..34] of Byte = (
     0, 1, 2, 2, 2, 2, 3, 5, 7, 8, 10, 12, 13, 15, 17, 18, 19, 20,
    21, 22, 23, 23, 24, 24, 25, 25, 26, 27, 27, 28, 28, 29, 29, 30, 31);
  intra_chroma_table: array[0..3] of Byte = (0, 26, 10, 1);

function chroma_mode_422(Mode: Integer): Integer;
begin
  Result := tab_mode_idx[Mode];
end;

procedure intra_prediction_unit(S: PHEVCContext; X0, Y0, log2_cb_size: Integer);
var
  LC: PHEVCLocalContext;
  prev_intra_luma_pred_flag: array[0..3] of Byte;
  Split, pb_size, Side, chroma_mode, I, J, mode_idx: Integer;
begin
  LC := S^.HEVClc;
  Split := Ord(LC^.cu.part_mode = PART_NxN);
  pb_size := (1 shl log2_cb_size) shr Split;
  Side := Split + 1;

  for I := 0 to Side - 1 do
    for J := 0 to Side - 1 do
      prev_intra_luma_pred_flag[2 * I + J] :=
        Byte(ff_hevc_prev_intra_luma_pred_flag_decode(S));

  for I := 0 to Side - 1 do
    for J := 0 to Side - 1 do
    begin
      if prev_intra_luma_pred_flag[2 * I + J] <> 0 then
        LC^.pu.mpm_idx := ff_hevc_mpm_idx_decode(S)
      else
        LC^.pu.rem_intra_luma_pred_mode := ff_hevc_rem_intra_luma_pred_mode_decode(S);
      LC^.pu.intra_pred_mode[2 * I + J] := Byte(luma_intra_pred_mode(S,
        X0 + pb_size * J, Y0 + pb_size * I, pb_size,
        prev_intra_luma_pred_flag[2 * I + J]));
    end;

  if S^.sps^.chroma_format_idc = 3 then
  begin
    for I := 0 to Side - 1 do
      for J := 0 to Side - 1 do
      begin
        chroma_mode := ff_hevc_intra_chroma_pred_mode_decode(S);
        LC^.pu.chroma_mode_c[2 * I + J] := Byte(chroma_mode);
        if chroma_mode <> 4 then
        begin
          if LC^.pu.intra_pred_mode[2 * I + J] = intra_chroma_table[chroma_mode] then
            LC^.pu.intra_pred_mode_c[2 * I + J] := 34
          else
            LC^.pu.intra_pred_mode_c[2 * I + J] := intra_chroma_table[chroma_mode];
        end
        else
          LC^.pu.intra_pred_mode_c[2 * I + J] := LC^.pu.intra_pred_mode[2 * I + J];
      end;
  end
  else if S^.sps^.chroma_format_idc = 2 then
  begin
    chroma_mode := ff_hevc_intra_chroma_pred_mode_decode(S);
    LC^.pu.chroma_mode_c[0] := Byte(chroma_mode);
    if chroma_mode <> 4 then
    begin
      if LC^.pu.intra_pred_mode[0] = intra_chroma_table[chroma_mode] then
        mode_idx := 34
      else
        mode_idx := intra_chroma_table[chroma_mode];
    end
    else
      mode_idx := LC^.pu.intra_pred_mode[0];
    LC^.pu.intra_pred_mode_c[0] := tab_mode_idx[mode_idx];
  end
  else if S^.sps^.chroma_format_idc <> 0 then
  begin
    chroma_mode := ff_hevc_intra_chroma_pred_mode_decode(S);
    if chroma_mode <> 4 then
    begin
      if LC^.pu.intra_pred_mode[0] = intra_chroma_table[chroma_mode] then
        LC^.pu.intra_pred_mode_c[0] := 34
      else
        LC^.pu.intra_pred_mode_c[0] := intra_chroma_table[chroma_mode];
    end
    else
      LC^.pu.intra_pred_mode_c[0] := LC^.pu.intra_pred_mode[0];
  end;
end;

procedure intra_prediction_unit_default_value(S: PHEVCContext;
  X0, Y0, log2_cb_size: Integer);
var
  LC: PHEVCLocalContext;
  pb_size, size_in_pus, min_pu_width, x_pu, y_pu, J, K: Integer;
  tab_mvf: PMvField;
begin
  LC := S^.HEVClc;
  pb_size := 1 shl log2_cb_size;
  size_in_pus := pb_size shr S^.sps^.log2_min_pu_size;
  min_pu_width := S^.sps^.min_pu_width;
  tab_mvf := S^.ref^.tab_mvf;
  x_pu := X0 shr S^.sps^.log2_min_pu_size;
  y_pu := Y0 shr S^.sps^.log2_min_pu_size;
  if size_in_pus = 0 then size_in_pus := 1;
  for J := 0 to size_in_pus - 1 do
    FillChar(S^.tab_ipm[(y_pu + J) * min_pu_width + x_pu], size_in_pus, INTRA_DC);
  if LC^.cu.pred_mode = MODE_INTRA then
    for J := 0 to size_in_pus - 1 do
      for K := 0 to size_in_pus - 1 do
        tab_mvf[(y_pu + J) * min_pu_width + x_pu + K].pred_flag := PF_INTRA;
end;

function hls_coding_unit(S: PHEVCContext; X0, Y0, log2_cb_size: Integer): Integer;
var
  LC: PHEVCLocalContext;
  cb_size, log2_min_cb_size, Length_, min_cb_width, x_cb, y_cb, Idx: Integer;
  qp_block_mask, X, Y, Ret: Integer;
  skip_flag_val: Byte;
  cbf: array[0..1] of Integer;
begin
  cb_size := 1 shl log2_cb_size;
  LC := S^.HEVClc;
  log2_min_cb_size := S^.sps^.log2_min_cb_size;
  Length_ := cb_size shr log2_min_cb_size;
  min_cb_width := S^.sps^.min_cb_width;
  x_cb := X0 shr log2_min_cb_size;
  y_cb := Y0 shr log2_min_cb_size;
  Idx := log2_cb_size - 2;
  qp_block_mask := (1 shl (S^.sps^.log2_ctb_size - S^.pps^.diff_cu_qp_delta_depth)) - 1;

  LC^.cu.x := X0;
  LC^.cu.y := Y0;
  LC^.cu.rqt_root_cbf := 1;
  LC^.cu.pred_mode := MODE_INTRA;
  LC^.cu.part_mode := PART_2Nx2N;
  LC^.cu.intra_split_flag := 0;
  LC^.cu.pcm_flag := 0;
  S^.skip_flag[y_cb * min_cb_width + x_cb] := 0;
  for X := 0 to 3 do
    LC^.pu.intra_pred_mode[X] := 1;

  if S^.pps^.transquant_bypass_enable_flag <> 0 then
  begin
    LC^.cu.cu_transquant_bypass_flag := Byte(ff_hevc_cu_transquant_bypass_flag_decode(S));
    if LC^.cu.cu_transquant_bypass_flag <> 0 then
      set_deblocking_bypass(S, X0, Y0, log2_cb_size);
  end
  else
    LC^.cu.cu_transquant_bypass_flag := 0;

  if S^.sh.slice_type <> I_SLICE then
  begin
    skip_flag_val := Byte(ff_hevc_skip_flag_decode(S, X0, Y0, x_cb, y_cb));
    X := y_cb * min_cb_width + x_cb;
    for Y := 0 to Length_ - 1 do
    begin
      FillChar(S^.skip_flag[X], Length_, skip_flag_val);
      Inc(X, min_cb_width);
    end;
    if skip_flag_val <> 0 then
      LC^.cu.pred_mode := MODE_SKIP
    else
      LC^.cu.pred_mode := MODE_INTER;
  end
  else
  begin
    X := y_cb * min_cb_width + x_cb;
    for Y := 0 to Length_ - 1 do
    begin
      FillChar(S^.skip_flag[X], Length_, 0);
      Inc(X, min_cb_width);
    end;
  end;

  if S^.skip_flag[y_cb * min_cb_width + x_cb] <> 0 then
  begin
    hls_prediction_unit(S, X0, Y0, cb_size, cb_size, log2_cb_size, 0, Idx);
    intra_prediction_unit_default_value(S, X0, Y0, log2_cb_size);
    if S^.sh.disable_deblocking_filter_flag = 0 then
      ff_hevc_deblocking_boundary_strengths(S, X0, Y0, log2_cb_size);
  end
  else
  begin
    if S^.sh.slice_type <> I_SLICE then
      LC^.cu.pred_mode := ff_hevc_pred_mode_decode(S);
    if (LC^.cu.pred_mode <> MODE_INTRA) or (log2_cb_size = S^.sps^.log2_min_cb_size) then
    begin
      LC^.cu.part_mode := ff_hevc_part_mode_decode(S, log2_cb_size);
      LC^.cu.intra_split_flag := Byte(Ord((LC^.cu.part_mode = PART_NxN) and
                                          (LC^.cu.pred_mode = MODE_INTRA)));
    end;

    if LC^.cu.pred_mode = MODE_INTRA then
    begin
      if (LC^.cu.part_mode = PART_2Nx2N) and (S^.sps^.pcm_enabled_flag <> 0) and
         (log2_cb_size >= S^.sps^.pcm.log2_min_pcm_cb_size) and
         (log2_cb_size <= S^.sps^.pcm.log2_max_pcm_cb_size) then
        LC^.cu.pcm_flag := Byte(ff_hevc_pcm_flag_decode(S));
      if LC^.cu.pcm_flag <> 0 then
      begin
        intra_prediction_unit_default_value(S, X0, Y0, log2_cb_size);
        Ret := hls_pcm_sample(S, X0, Y0, log2_cb_size);
        if S^.sps^.pcm.loop_filter_disable_flag <> 0 then
          set_deblocking_bypass(S, X0, Y0, log2_cb_size);
        if Ret < 0 then Exit(Ret);
      end
      else
        intra_prediction_unit(S, X0, Y0, log2_cb_size);
    end
    else
    begin
      intra_prediction_unit_default_value(S, X0, Y0, log2_cb_size);
      case LC^.cu.part_mode of
        PART_2Nx2N:
          hls_prediction_unit(S, X0, Y0, cb_size, cb_size, log2_cb_size, 0, Idx);
        PART_2NxN:
          begin
            hls_prediction_unit(S, X0, Y0, cb_size, cb_size div 2, log2_cb_size, 0, Idx);
            hls_prediction_unit(S, X0, Y0 + cb_size div 2, cb_size, cb_size div 2, log2_cb_size, 1, Idx);
          end;
        PART_Nx2N:
          begin
            hls_prediction_unit(S, X0, Y0, cb_size div 2, cb_size, log2_cb_size, 0, Idx - 1);
            hls_prediction_unit(S, X0 + cb_size div 2, Y0, cb_size div 2, cb_size, log2_cb_size, 1, Idx - 1);
          end;
        PART_2NxnU:
          begin
            hls_prediction_unit(S, X0, Y0, cb_size, cb_size div 4, log2_cb_size, 0, Idx);
            hls_prediction_unit(S, X0, Y0 + cb_size div 4, cb_size, cb_size * 3 div 4, log2_cb_size, 1, Idx);
          end;
        PART_2NxnD:
          begin
            hls_prediction_unit(S, X0, Y0, cb_size, cb_size * 3 div 4, log2_cb_size, 0, Idx);
            hls_prediction_unit(S, X0, Y0 + cb_size * 3 div 4, cb_size, cb_size div 4, log2_cb_size, 1, Idx);
          end;
        PART_nLx2N:
          begin
            hls_prediction_unit(S, X0, Y0, cb_size div 4, cb_size, log2_cb_size, 0, Idx - 2);
            hls_prediction_unit(S, X0 + cb_size div 4, Y0, cb_size * 3 div 4, cb_size, log2_cb_size, 1, Idx - 2);
          end;
        PART_nRx2N:
          begin
            hls_prediction_unit(S, X0, Y0, cb_size * 3 div 4, cb_size, log2_cb_size, 0, Idx - 2);
            hls_prediction_unit(S, X0 + cb_size * 3 div 4, Y0, cb_size div 4, cb_size, log2_cb_size, 1, Idx - 2);
          end;
        PART_NxN:
          begin
            hls_prediction_unit(S, X0, Y0, cb_size div 2, cb_size div 2, log2_cb_size, 0, Idx - 1);
            hls_prediction_unit(S, X0 + cb_size div 2, Y0, cb_size div 2, cb_size div 2, log2_cb_size, 1, Idx - 1);
            hls_prediction_unit(S, X0, Y0 + cb_size div 2, cb_size div 2, cb_size div 2, log2_cb_size, 2, Idx - 1);
            hls_prediction_unit(S, X0 + cb_size div 2, Y0 + cb_size div 2, cb_size div 2, cb_size div 2, log2_cb_size, 3, Idx - 1);
          end;
      end;
    end;

    if LC^.cu.pcm_flag = 0 then
    begin
      if (LC^.cu.pred_mode <> MODE_INTRA) and
         not ((LC^.cu.part_mode = PART_2Nx2N) and (LC^.pu.merge_flag <> 0)) then
        LC^.cu.rqt_root_cbf := Byte(ff_hevc_no_residual_syntax_flag_decode(S));
      if LC^.cu.rqt_root_cbf <> 0 then
      begin
        cbf[0] := 0;
        cbf[1] := 0;
        if LC^.cu.pred_mode = MODE_INTRA then
          LC^.cu.max_trafo_depth := Byte(S^.sps^.max_transform_hierarchy_depth_intra +
                                         LC^.cu.intra_split_flag)
        else
          LC^.cu.max_trafo_depth := Byte(S^.sps^.max_transform_hierarchy_depth_inter);
        Ret := hls_transform_tree(S, X0, Y0, X0, Y0, X0, Y0, log2_cb_size,
          log2_cb_size, 0, 0, @cbf[0], @cbf[0]);
        if Ret < 0 then Exit(Ret);
      end
      else
      begin
        if S^.sh.disable_deblocking_filter_flag = 0 then
          ff_hevc_deblocking_boundary_strengths(S, X0, Y0, log2_cb_size);
      end;
    end;
  end;

  if (S^.pps^.cu_qp_delta_enabled_flag <> 0) and (LC^.tu.is_cu_qp_delta_coded = 0) then
    ff_hevc_set_qPy(S, X0, Y0, log2_cb_size);

  X := y_cb * min_cb_width + x_cb;
  for Y := 0 to Length_ - 1 do
  begin
    FillChar(S^.qp_y_tab[X], Length_, Byte(LC^.qp_y));
    Inc(X, min_cb_width);
  end;

  if (((X0 + (1 shl log2_cb_size)) and qp_block_mask) = 0) and
     (((Y0 + (1 shl log2_cb_size)) and qp_block_mask) = 0) then
    LC^.qPy_pred := LC^.qp_y;

  set_ct_depth(S, X0, Y0, log2_cb_size, LC^.ct_depth);
  Result := 0;
end;

function hls_coding_quadtree(S: PHEVCContext; X0, Y0, log2_cb_size,
  cb_depth: Integer): Integer;
var
  LC: PHEVCLocalContext;
  cb_size, Ret, qp_block_mask, split_cu: Integer;
  cb_size_split, X1, Y1, more_data, end_of_slice_flag: Integer;
begin
  LC := S^.HEVClc;
  cb_size := 1 shl log2_cb_size;
  qp_block_mask := (1 shl (S^.sps^.log2_ctb_size - S^.pps^.diff_cu_qp_delta_depth)) - 1;
  LC^.ct_depth := cb_depth;

  if (X0 + cb_size <= S^.sps^.width) and (Y0 + cb_size <= S^.sps^.height) and
     (log2_cb_size > S^.sps^.log2_min_cb_size) then
    split_cu := ff_hevc_split_coding_unit_flag_decode(S, cb_depth, X0, Y0)
  else
    split_cu := Ord(log2_cb_size > S^.sps^.log2_min_cb_size);

  if (S^.pps^.cu_qp_delta_enabled_flag <> 0) and
     (log2_cb_size >= S^.sps^.log2_ctb_size - S^.pps^.diff_cu_qp_delta_depth) then
  begin
    LC^.tu.is_cu_qp_delta_coded := 0;
    LC^.tu.cu_qp_delta := 0;
  end;
  if (S^.sh.cu_chroma_qp_offset_enabled_flag <> 0) and
     (log2_cb_size >= S^.sps^.log2_ctb_size - S^.pps^.diff_cu_chroma_qp_offset_depth) then
    LC^.tu.is_cu_chroma_qp_offset_coded := 0;

  if split_cu <> 0 then
  begin
    cb_size_split := cb_size shr 1;
    X1 := X0 + cb_size_split;
    Y1 := Y0 + cb_size_split;

    more_data := hls_coding_quadtree(S, X0, Y0, log2_cb_size - 1, cb_depth + 1);
    if more_data < 0 then Exit(more_data);
    if (more_data <> 0) and (X1 < S^.sps^.width) then
    begin
      more_data := hls_coding_quadtree(S, X1, Y0, log2_cb_size - 1, cb_depth + 1);
      if more_data < 0 then Exit(more_data);
    end;
    if (more_data <> 0) and (Y1 < S^.sps^.height) then
    begin
      more_data := hls_coding_quadtree(S, X0, Y1, log2_cb_size - 1, cb_depth + 1);
      if more_data < 0 then Exit(more_data);
    end;
    if (more_data <> 0) and (X1 < S^.sps^.width) and (Y1 < S^.sps^.height) then
    begin
      more_data := hls_coding_quadtree(S, X1, Y1, log2_cb_size - 1, cb_depth + 1);
      if more_data < 0 then Exit(more_data);
    end;

    if (((X0 + (1 shl log2_cb_size)) and qp_block_mask) = 0) and
       (((Y0 + (1 shl log2_cb_size)) and qp_block_mask) = 0) then
      LC^.qPy_pred := LC^.qp_y;

    if more_data <> 0 then
      Result := Ord(((X1 + cb_size_split) < S^.sps^.width) or
                    ((Y1 + cb_size_split) < S^.sps^.height))
    else
      Result := 0;
  end
  else
  begin
    Ret := hls_coding_unit(S, X0, Y0, log2_cb_size);
    if Ret < 0 then Exit(Ret);
    if ((((X0 + cb_size) mod (1 shl S^.sps^.log2_ctb_size)) = 0) or
        (X0 + cb_size >= S^.sps^.width)) and
       ((((Y0 + cb_size) mod (1 shl S^.sps^.log2_ctb_size)) = 0) or
        (Y0 + cb_size >= S^.sps^.height)) then
    begin
      end_of_slice_flag := ff_hevc_end_of_slice_flag_decode(S);
      Result := Ord(end_of_slice_flag = 0);
    end
    else
      Result := 1;
  end;
end;

procedure hls_decode_neighbour(S: PHEVCContext; x_ctb, y_ctb, ctb_addr_ts: Integer);
var
  LC: PHEVCLocalContext;
  ctb_size, ctb_addr_rs, ctb_addr_in_slice, idxX: Integer;
begin
  LC := S^.HEVClc;
  ctb_size := 1 shl S^.sps^.log2_ctb_size;
  ctb_addr_rs := S^.pps^.ctb_addr_ts_to_rs[ctb_addr_ts];
  ctb_addr_in_slice := ctb_addr_rs - S^.sh.slice_addr;
  S^.tab_slice_address[ctb_addr_rs] := S^.sh.slice_addr;

  if S^.pps^.entropy_coding_sync_enabled_flag <> 0 then
  begin
    if (x_ctb = 0) and ((y_ctb and (ctb_size - 1)) = 0) then
      LC^.first_qp_group := 1;
    LC^.end_of_tiles_x := S^.sps^.width;
  end
  else if S^.pps^.tiles_enabled_flag <> 0 then
  begin
    if (ctb_addr_ts <> 0) and
       (S^.pps^.tile_id[ctb_addr_ts] <> S^.pps^.tile_id[ctb_addr_ts - 1]) then
    begin
      idxX := S^.pps^.col_idxX[x_ctb shr S^.sps^.log2_ctb_size];
      LC^.end_of_tiles_x := x_ctb + (S^.pps^.column_width[idxX] shl S^.sps^.log2_ctb_size);
      LC^.first_qp_group := 1;
    end;
  end
  else
    LC^.end_of_tiles_x := S^.sps^.width;

  LC^.end_of_tiles_y := y_ctb + ctb_size;
  if LC^.end_of_tiles_y > S^.sps^.height then LC^.end_of_tiles_y := S^.sps^.height;

  LC^.boundary_flags := 0;
  if S^.pps^.tiles_enabled_flag <> 0 then
  begin
    if (x_ctb > 0) and (S^.pps^.tile_id[ctb_addr_ts] <>
        S^.pps^.tile_id[S^.pps^.ctb_addr_rs_to_ts[ctb_addr_rs - 1]]) then
      LC^.boundary_flags := LC^.boundary_flags or (1 shl 1);
    if (x_ctb > 0) and (S^.tab_slice_address[ctb_addr_rs] <>
        S^.tab_slice_address[ctb_addr_rs - 1]) then
      LC^.boundary_flags := LC^.boundary_flags or (1 shl 0);
    if (y_ctb > 0) and (S^.pps^.tile_id[ctb_addr_ts] <>
        S^.pps^.tile_id[S^.pps^.ctb_addr_rs_to_ts[ctb_addr_rs - S^.sps^.ctb_width]]) then
      LC^.boundary_flags := LC^.boundary_flags or (1 shl 3);
    if (y_ctb > 0) and (S^.tab_slice_address[ctb_addr_rs] <>
        S^.tab_slice_address[ctb_addr_rs - S^.sps^.ctb_width]) then
      LC^.boundary_flags := LC^.boundary_flags or (1 shl 2);
  end
  else
  begin
    // The reference writes `if (!ctb_addr_in_slice > 0)`, which C parses as
    // `(!ctb_addr_in_slice) > 0`, i.e. "ctb_addr_in_slice == 0". Reproduced as
    // written -- the apparently intended `<= 0` would differ for negative
    // values, which do occur for a dependent slice segment.
    if ctb_addr_in_slice = 0 then
      LC^.boundary_flags := LC^.boundary_flags or (1 shl 0);
    if ctb_addr_in_slice < S^.sps^.ctb_width then
      LC^.boundary_flags := LC^.boundary_flags or (1 shl 2);
  end;

  LC^.ctb_left_flag := Byte(Ord((x_ctb > 0) and (ctb_addr_in_slice > 0) and
    ((LC^.boundary_flags and (1 shl 1)) = 0)));
  LC^.ctb_up_flag := Byte(Ord((y_ctb > 0) and (ctb_addr_in_slice >= S^.sps^.ctb_width) and
    ((LC^.boundary_flags and (1 shl 3)) = 0)));
  LC^.ctb_up_right_flag := Byte(Ord((y_ctb > 0) and
    (ctb_addr_in_slice + 1 >= S^.sps^.ctb_width) and
    (S^.pps^.tile_id[ctb_addr_ts] =
     S^.pps^.tile_id[S^.pps^.ctb_addr_rs_to_ts[ctb_addr_rs + 1 - S^.sps^.ctb_width]])));
  LC^.ctb_up_left_flag := Byte(Ord((x_ctb > 0) and (y_ctb > 0) and
    (ctb_addr_in_slice - 1 >= S^.sps^.ctb_width) and
    (S^.pps^.tile_id[ctb_addr_ts] =
     S^.pps^.tile_id[S^.pps^.ctb_addr_rs_to_ts[ctb_addr_rs - 1 - S^.sps^.ctb_width]])));
end;

// The reference dispatches this through avctx->execute with a single thread;
// hls_slice_data collapses to a direct call.
function hls_decode_entry(S: PHEVCContext): Integer;
var
  ctb_size, more_data, x_ctb, y_ctb, ctb_addr_ts, ctb_addr_rs, prev_rs: Integer;
  ctb_per_row: Integer;
begin
  ctb_size := 1 shl S^.sps^.log2_ctb_size;
  more_data := 1;
  x_ctb := 0;
  y_ctb := 0;
  ctb_addr_ts := S^.pps^.ctb_addr_rs_to_ts[S^.sh.slice_ctb_addr_rs];

  if (ctb_addr_ts = 0) and (S^.sh.dependent_slice_segment_flag <> 0) then
    Exit(AVERROR_INVALIDDATA);
  if S^.sh.dependent_slice_segment_flag <> 0 then
  begin
    prev_rs := S^.pps^.ctb_addr_ts_to_rs[ctb_addr_ts - 1];
    if S^.tab_slice_address[prev_rs] <> S^.sh.slice_addr then
      Exit(AVERROR_INVALIDDATA);
  end;

  ctb_per_row := (S^.sps^.width + ctb_size - 1) shr S^.sps^.log2_ctb_size;
  while (more_data <> 0) and (ctb_addr_ts < S^.sps^.ctb_size) do
  begin
    ctb_addr_rs := S^.pps^.ctb_addr_ts_to_rs[ctb_addr_ts];
    x_ctb := (ctb_addr_rs mod ctb_per_row) shl S^.sps^.log2_ctb_size;
    y_ctb := (ctb_addr_rs div ctb_per_row) shl S^.sps^.log2_ctb_size;
    hls_decode_neighbour(S, x_ctb, y_ctb, ctb_addr_ts);
    ff_hevc_cabac_init(S, ctb_addr_ts);
    hls_sao_param(S, x_ctb shr S^.sps^.log2_ctb_size, y_ctb shr S^.sps^.log2_ctb_size);
    S^.deblock[ctb_addr_rs].beta_offset := S^.sh.beta_offset;
    S^.deblock[ctb_addr_rs].tc_offset := S^.sh.tc_offset;
    S^.filter_slice_edges[ctb_addr_rs] := S^.sh.slice_loop_filter_across_slices_enabled_flag;
    more_data := hls_coding_quadtree(S, x_ctb, y_ctb, S^.sps^.log2_ctb_size, 0);
    if more_data < 0 then
    begin
      S^.tab_slice_address[ctb_addr_rs] := -1;
      Exit(more_data);
    end;
    Inc(ctb_addr_ts);
    ff_hevc_save_states(S, ctb_addr_ts);
    ff_hevc_hls_filters(S, x_ctb, y_ctb, ctb_size);
  end;

  if (x_ctb + ctb_size >= S^.sps^.width) and (y_ctb + ctb_size >= S^.sps^.height) then
    ff_hevc_hls_filter(S, x_ctb, y_ctb, ctb_size);
  Result := ctb_addr_ts;
end;

function hls_nal_unit(S: PHEVCContext): Integer;
var
  GB: PGetBitContext;
  nuh_layer_id: Integer;
begin
  GB := @S^.HEVClc^.gb;
  if get_bits1(GB^) <> 0 then Exit(AVERROR_INVALIDDATA);
  S^.nal_unit_type := Integer(get_bits(GB^, 6));
  nuh_layer_id := Integer(get_bits(GB^, 6));
  S^.temporal_id := Integer(get_bits(GB^, 3)) - 1;
  if S^.temporal_id < 0 then Exit(AVERROR_INVALIDDATA);
  Result := Ord(nuh_layer_id = 0);
end;

function hevc_frame_start(S: PHEVCContext): Integer;
var
  LC: PHEVCLocalContext;
  pic_size_in_ctb, Ret: Integer;
label
  fail;
begin
  LC := S^.HEVClc;
  pic_size_in_ctb := ((S^.sps^.width shr S^.sps^.log2_min_cb_size) + 1) *
                     ((S^.sps^.height shr S^.sps^.log2_min_cb_size) + 1);
  FillChar(S^.horizontal_bs^, S^.bs_width * S^.bs_height, 0);
  FillChar(S^.vertical_bs^, S^.bs_width * S^.bs_height, 0);
  FillChar(S^.cbf_luma^, S^.sps^.min_tb_width * S^.sps^.min_tb_height, 0);
  FillChar(S^.is_pcm^, (S^.sps^.min_pu_width + 1) * (S^.sps^.min_pu_height + 1), 0);
  FillChar(S^.tab_slice_address^, pic_size_in_ctb * SizeOf(Int32), $FF);
  S^.is_decoded := 0;
  S^.first_nal_type := S^.nal_unit_type;

  if S^.pps^.tiles_enabled_flag <> 0 then
    LC^.end_of_tiles_x := S^.pps^.column_width[0] shl S^.sps^.log2_ctb_size;

  Ret := ff_hevc_set_new_ref(S, S^.frame, S^.poc);
  if Ret < 0 then goto fail;
  Ret := ff_hevc_frame_rps(S);
  if Ret < 0 then goto fail;

  S^.ref^.Frame^.KeyFrame := Byte(Ord(IS_IRAP(S)));
  // set_side_data() is a no-op in libbpg
  S^.frame^.PictType := 3 - S^.sh.slice_type;
  if not IS_IRAP(S) then
    ff_hevc_bump_frame(S);
  av_frame_unref(S^.output_frame);
  Ret := ff_hevc_output_frame(S, S^.output_frame, 0);
  if Ret < 0 then goto fail;
  Exit(0);

fail:
  // the reference also signals thread progress here; single-threaded, so only
  // the reference pointer needs clearing
  S^.ref := nil;
  Result := Ret;
end;

function decode_nal_unit(S: PHEVCContext; nal: PByte; Length_: Integer): Integer;
var
  LC: PHEVCLocalContext;
  GB: PGetBitContext;
  ctb_addr_ts, Ret: Integer;
begin
  LC := S^.HEVClc;
  GB := @LC^.gb;
  Ret := init_get_bits8(GB^, nal, Length_);
  if Ret < 0 then Exit(Ret);

  Ret := hls_nal_unit(S);
  if Ret < 0 then Exit(0)       // fail: AV_EF_EXPLODE is never set in libbpg
  else if Ret = 0 then Exit(0);

  case S^.nal_unit_type of
    // BPG replaces the full SPS with its "modified SPS" carried in NAL type 48
    48:
      begin
        Ret := ff_hevc_decode_nal_sps(S);
        if Ret < 0 then Exit(0);
      end;
    NAL_PPS:
      begin
        Ret := ff_hevc_decode_nal_pps(S);
        if Ret < 0 then Exit(0);
      end;
    NAL_SEI_PREFIX, NAL_SEI_SUFFIX:
      begin
        Ret := ff_hevc_decode_nal_sei(S);
        if Ret < 0 then Exit(0);
      end;
    NAL_TRAIL_R, NAL_TRAIL_N, NAL_TSA_N, NAL_TSA_R, NAL_STSA_N, NAL_STSA_R,
    NAL_BLA_W_LP, NAL_BLA_W_RADL, NAL_BLA_N_LP, NAL_IDR_W_RADL, NAL_IDR_N_LP,
    NAL_CRA_NUT, NAL_RADL_N, NAL_RADL_R, NAL_RASL_N, NAL_RASL_R:
      begin
        Ret := hls_slice_header(S);
        if Ret < 0 then Exit(Ret);

        if S^.max_ra = $7FFFFFFF then
        begin
          if (S^.nal_unit_type = NAL_CRA_NUT) or IS_BLA(S) then
            S^.max_ra := S^.poc
          else if IS_IDR(S) then
            S^.max_ra := Low(Int32);
        end;

        if ((S^.nal_unit_type = NAL_RASL_R) or (S^.nal_unit_type = NAL_RASL_N)) and
           (S^.poc <= S^.max_ra) then
        begin
          S^.is_decoded := 0;
          Exit(0);
        end
        else if (S^.nal_unit_type = NAL_RASL_R) and (S^.poc > S^.max_ra) then
          S^.max_ra := Low(Int32);

        if S^.sh.first_slice_in_pic_flag <> 0 then
        begin
          Ret := hevc_frame_start(S);
          if Ret < 0 then Exit(Ret);
        end
        else if S^.ref = nil then
          Exit(0);

        if S^.nal_unit_type <> S^.first_nal_type then
          Exit(AVERROR_INVALIDDATA);

        if (S^.sh.dependent_slice_segment_flag = 0) and (S^.sh.slice_type <> I_SLICE) then
        begin
          Ret := ff_hevc_slice_rpl(S);
          if Ret < 0 then Exit(0);
        end;

        ctb_addr_ts := hls_decode_entry(S);
        if ctb_addr_ts >= (S^.sps^.ctb_width * S^.sps^.ctb_height) then
          S^.is_decoded := 1;
        if ctb_addr_ts < 0 then Exit(0);
      end;
    NAL_EOS_NUT, NAL_EOB_NUT:
      begin
        S^.seq_decode := (S^.seq_decode + 1) and $FF;
        S^.max_ra := $7FFFFFFF;
      end;
    NAL_AUD, NAL_FD_NUT:
      ;
  end;
  Result := 0;
end;

function ff_hevc_extract_rbsp(S: PHEVCContext; Src: PByte; Length_: Integer;
  nal: PHEVCNAL): Integer;
var
  I, si, di: Integer;
  Dst: PByte;
label
  nsc;
begin
  S^.skipped_bytes := 0;

  I := 0;
  while I + 1 < Length_ do
  begin
    if Src[I] <> 0 then
    begin
      Inc(I, 2);
      Continue;
    end;
    if (I > 0) and (Src[I - 1] = 0) then Dec(I);
    if (I + 2 < Length_) and (Src[I + 1] = 0) and (Src[I + 2] <= 3) then
    begin
      if Src[I + 2] <> 3 then Length_ := I;
      Break;
    end;
    Inc(I, 2);
  end;

  if I >= Length_ - 1 then
  begin
    nal^.data := Src;
    nal^.size := Length_;
    Exit(Length_);
  end;

  av_fast_malloc(@nal^.rbsp_buffer, nal^.rbsp_buffer_size, Length_ + 32);
  if nal^.rbsp_buffer = nil then Exit(AVERROR_ENOMEM);

  Dst := nal^.rbsp_buffer;
  Move(Src^, Dst^, I);
  si := I;
  di := I;
  while si + 2 < Length_ do
  begin
    if Src[si + 2] > 3 then
    begin
      Dst[di] := Src[si]; Inc(di); Inc(si);
      Dst[di] := Src[si]; Inc(di); Inc(si);
    end
    else if (Src[si] = 0) and (Src[si + 1] = 0) then
    begin
      if Src[si + 2] = 3 then
      begin
        Dst[di] := 0; Inc(di);
        Dst[di] := 0; Inc(di);
        Inc(si, 3);
        Inc(S^.skipped_bytes);
        if S^.skipped_bytes_pos_size < S^.skipped_bytes then
        begin
          S^.skipped_bytes_pos_size := S^.skipped_bytes_pos_size * 2;
          av_reallocp_array(@S^.skipped_bytes_pos, S^.skipped_bytes_pos_size,
                            SizeOf(Integer));
          if S^.skipped_bytes_pos = nil then Exit(AVERROR_ENOMEM);
        end;
        if S^.skipped_bytes_pos <> nil then
          S^.skipped_bytes_pos[S^.skipped_bytes - 1] := di - 1;
        Continue;
      end
      else
        goto nsc;
    end
    else
    begin
      Dst[di] := Src[si]; Inc(di); Inc(si);
    end;
  end;
  while si < Length_ do
  begin
    Dst[di] := Src[si]; Inc(di); Inc(si);
  end;

nsc:
  FillChar(Dst[di], 32, 0);
  nal^.data := Dst;
  nal^.size := di;
  Result := si;
end;

function decode_nal_units(S: PHEVCContext; Buf: PByte; Length_: Integer): Integer;
var
  I, consumed, Ret, extract_length, new_size: Integer;
  nal: PHEVCNAL;
  Tmp: PHEVCNAL;
label
  fail;
begin
  Ret := 0;
  S^.ref := nil;
  S^.last_eos := S^.eos;
  S^.eos := 0;
  S^.nb_nals := 0;

  // libbpg always feeds an Annex-B stream, so the AVCC (is_nalff) branch of the
  // reference is unreachable and is not ported.
  while Length_ >= 4 do
  begin
    while (Buf[0] <> 0) or (Buf[1] <> 0) or (Buf[2] <> 1) do
    begin
      Inc(Buf);
      Dec(Length_);
      if Length_ < 4 then
      begin
        Ret := AVERROR_INVALIDDATA;
        goto fail;
      end;
    end;
    Inc(Buf, 3);
    Dec(Length_, 3);
    extract_length := Length_;

    if S^.nals_allocated < S^.nb_nals + 1 then
    begin
      new_size := S^.nals_allocated + 1;
      Tmp := av_realloc_array(S^.nals, new_size, SizeOf(THEVCNAL));
      if Tmp = nil then
      begin
        Ret := AVERROR_ENOMEM;
        goto fail;
      end;
      S^.nals := Tmp;
      FillChar(S^.nals[S^.nals_allocated],
               (new_size - S^.nals_allocated) * SizeOf(THEVCNAL), 0);
      av_reallocp_array(@S^.skipped_bytes_nal, new_size, SizeOf(Integer));
      av_reallocp_array(@S^.skipped_bytes_pos_size_nal, new_size, SizeOf(Integer));
      av_reallocp_array(@S^.skipped_bytes_pos_nal, new_size, SizeOf(Pointer));
      S^.skipped_bytes_pos_size_nal[S^.nals_allocated] := 1024;
      S^.skipped_bytes_pos_nal[S^.nals_allocated] :=
        av_malloc_array(S^.skipped_bytes_pos_size_nal[S^.nals_allocated], SizeOf(Integer));
      S^.nals_allocated := new_size;
    end;

    S^.skipped_bytes_pos_size := S^.skipped_bytes_pos_size_nal[S^.nb_nals];
    S^.skipped_bytes_pos := PInteger(S^.skipped_bytes_pos_nal[S^.nb_nals]);
    nal := @S^.nals[S^.nb_nals];
    consumed := ff_hevc_extract_rbsp(S, Buf, extract_length, nal);
    S^.skipped_bytes_nal[S^.nb_nals] := S^.skipped_bytes;
    S^.skipped_bytes_pos_size_nal[S^.nb_nals] := S^.skipped_bytes_pos_size;
    S^.skipped_bytes_pos_nal[S^.nb_nals] := S^.skipped_bytes_pos;
    Inc(S^.nb_nals);
    if consumed < 0 then
    begin
      Ret := consumed;
      goto fail;
    end;

    Ret := init_get_bits8(S^.HEVClc^.gb, nal^.data, nal^.size);
    if Ret < 0 then goto fail;
    hls_nal_unit(S);
    if (S^.nal_unit_type = NAL_EOB_NUT) or (S^.nal_unit_type = NAL_EOS_NUT) then
      S^.eos := 1;

    Inc(Buf, consumed);
    Dec(Length_, consumed);
  end;

  for I := 0 to S^.nb_nals - 1 do
  begin
    S^.skipped_bytes := S^.skipped_bytes_nal[I];
    S^.skipped_bytes_pos := PInteger(S^.skipped_bytes_pos_nal[I]);
    Ret := decode_nal_unit(S, S^.nals[I].data, S^.nals[I].size);
    if Ret < 0 then goto fail;
  end;

fail:
  Result := Ret;
end;

function hevc_decode_frame(S: PHEVCContext; Data: PAVFrame; out got_output: Integer;
  pkt_data: PByte; pkt_size: Integer): Integer;
var
  Ret: Integer;
begin
  got_output := 0;
  if pkt_size = 0 then
  begin
    Ret := ff_hevc_output_frame(S, Data, 1);
    if Ret < 0 then Exit(Ret);
    got_output := Ret;
    Exit(0);
  end;

  S^.ref := nil;
  S^.frame_duration := 1;
  Ret := decode_nal_units(S, pkt_data, pkt_size);
  if Ret < 0 then Exit(Ret);

  if S^.is_decoded <> 0 then S^.is_decoded := 0;

  if S^.output_frame^.Buf[0] <> nil then
  begin
    S^.output_frame^.Pts := S^.frame_duration;
    av_frame_move_ref(Data, S^.output_frame);
    got_output := 1;
  end;
  Result := pkt_size;
end;

procedure hevc_decode_free(S: PHEVCContext);
var
  I: Integer;
begin
  pic_arrays_free(S);
  if S^.skipped_bytes_pos_nal <> nil then
    for I := 0 to S^.nals_allocated - 1 do
      av_freep(@S^.skipped_bytes_pos_nal[I]);
  av_freep(@S^.skipped_bytes_pos_size_nal);
  av_freep(@S^.skipped_bytes_nal);
  av_freep(@S^.skipped_bytes_pos_nal);
  av_freep(@S^.cabac_state);
  av_freep(@S^.sao_pixel_buffer);
  for I := 0 to 2 do
  begin
    av_freep(@S^.sao_pixel_buffer_h[I]);
    av_freep(@S^.sao_pixel_buffer_v[I]);
  end;
  av_frame_free(S^.output_frame);
  for I := 0 to MAX_DPB_COUNT - 1 do
  begin
    ff_hevc_unref_frame(S, @S^.DPB[I], -1);
    av_frame_free(S^.DPB[I].Frame);
  end;
  // the parameter-set lists hold plain allocations here, not AVBufferRefs
  for I := 0 to MAX_SPS_COUNT - 1 do
    av_freep(@S^.sps_list[I]);
  for I := 0 to MAX_PPS_COUNT - 1 do
    av_freep(@S^.pps_list[I]);
  S^.sps := nil;
  S^.pps := nil;
  S^.current_sps := nil;
  av_freep(@S^.sh.entry_point_offset);
  av_freep(@S^.sh.offset);
  av_freep(@S^.sh.size);
  av_freep(@S^.HEVClc);
  if S^.nals <> nil then
    for I := 0 to S^.nals_allocated - 1 do
      av_freep(@S^.nals[I].rbsp_buffer);
  av_freep(@S^.nals);
  S^.nals_allocated := 0;
end;

function hevc_init_context(S: PHEVCContext): Integer;
var
  I: Integer;
begin
  FillChar(S^, SizeOf(THEVCContext), 0);
  S^.HEVClc := av_mallocz(SizeOf(THEVCLocalContext));
  if S^.HEVClc = nil then
  begin
    hevc_decode_free(S);
    Exit(AVERROR_ENOMEM);
  end;
  S^.cabac_state := av_malloc(199);
  if S^.cabac_state = nil then
  begin
    hevc_decode_free(S);
    Exit(AVERROR_ENOMEM);
  end;
  S^.output_frame := av_frame_alloc;
  if S^.output_frame = nil then
  begin
    hevc_decode_free(S);
    Exit(AVERROR_ENOMEM);
  end;
  for I := 0 to MAX_DPB_COUNT - 1 do
  begin
    S^.DPB[I].Frame := av_frame_alloc;
    if S^.DPB[I].Frame = nil then
    begin
      hevc_decode_free(S);
      Exit(AVERROR_ENOMEM);
    end;
  end;
  S^.max_ra := $7FFFFFFF;
  S^.context_initialized := 1;
  S^.eos := 0;
  Result := 0;
end;

end.
