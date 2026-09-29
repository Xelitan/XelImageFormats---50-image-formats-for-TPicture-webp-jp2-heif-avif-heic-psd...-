// BPG decoder -- Free Pascal port of libbpg 0.9.8
// Parameter sets: short-term RPS, scaling lists, SPS (BPG "modified SPS"
// variant) and PPS including the tile / CTB address tables.
// Corresponds to: libavcodec/hevc_ps.c (as compiled with USE_MSPS)
//
// The VPS is never read by the decoder in this configuration (create_dummy_vps
// only fills a struct nobody inspects), so it is omitted entirely.
unit bpg_hevc_ps;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, bpg_common, bpg_bits, bpg_cabac, bpg_hevc_defs, bpg_scan;

function ff_hevc_decode_short_term_rps(S: PHEVCContext; RPS: PShortTermRPS;
  SPS: PHEVCSPS; IsSliceHeader: Integer): Integer;
function ff_hevc_decode_nal_sps(S: PHEVCContext): Integer;
function ff_hevc_decode_nal_pps(S: PHEVCContext): Integer;

procedure hevc_pps_free(PPS: PHEVCPPS);
procedure hevc_sps_free(SPS: PHEVCSPS);

implementation

const
  default_scaling_list_intra: array[0..63] of Byte = (
    16, 16, 16, 16, 17, 18, 21, 24,
    16, 16, 16, 16, 17, 19, 22, 25,
    16, 16, 17, 18, 20, 22, 25, 29,
    16, 16, 18, 21, 24, 27, 31, 36,
    17, 17, 20, 24, 30, 35, 41, 47,
    18, 19, 22, 27, 35, 44, 54, 65,
    21, 22, 25, 31, 41, 54, 70, 88,
    24, 25, 29, 36, 47, 65, 88, 115
  );

  default_scaling_list_inter: array[0..63] of Byte = (
    16, 16, 16, 16, 17, 18, 20, 24,
    16, 16, 16, 17, 18, 20, 24, 25,
    16, 16, 17, 18, 20, 24, 25, 28,
    16, 17, 18, 20, 24, 25, 28, 33,
    17, 18, 20, 24, 25, 28, 33, 41,
    18, 20, 24, 25, 28, 33, 41, 54,
    20, 24, 25, 28, 33, 41, 54, 71,
    24, 25, 28, 33, 41, 54, 71, 91
  );

procedure hevc_sps_free(SPS: PHEVCSPS);
begin
  if SPS <> nil then FreeMem(SPS);
end;

procedure hevc_pps_free(PPS: PHEVCPPS);
begin
  if PPS = nil then Exit;
  av_freep(@PPS^.column_width);
  av_freep(@PPS^.row_height);
  av_freep(@PPS^.col_bd);
  av_freep(@PPS^.row_bd);
  av_freep(@PPS^.col_idxX);
  av_freep(@PPS^.ctb_addr_rs_to_ts);
  av_freep(@PPS^.ctb_addr_ts_to_rs);
  av_freep(@PPS^.tile_pos_rs);
  av_freep(@PPS^.tile_id);
  av_freep(@PPS^.min_tb_addr_zs_tab);
  FreeMem(PPS);
end;

function ff_hevc_decode_short_term_rps(S: PHEVCContext; RPS: PShortTermRPS;
  SPS: PHEVCSPS; IsSliceHeader: Integer): Integer;
var
  LC: PHEVCLocalContext;
  GB: PGetBitContext;
  rps_predict: Byte;
  delta_poc: Integer;
  k0, k1, k, i: Integer;
  rps_ridx: PShortTermRPS;
  delta_rps: Integer;
  abs_delta_rps: Cardinal;
  use_delta_flag, delta_rps_sign: Byte;
  delta_idx: Cardinal;
  used, tmp: Integer;
  prev, nb_positive_pics: Cardinal;
begin
  LC := S^.HEVClc;
  rps_predict := 0;
  k0 := 0;
  k1 := 0;
  k := 0;
  GB := @LC^.gb;

  if (RPS <> @SPS^.st_rps[0]) and (SPS^.nb_st_rps <> 0) then
    rps_predict := get_bits1(GB^);

  if rps_predict <> 0 then
  begin
    use_delta_flag := 0;
    if IsSliceHeader <> 0 then
    begin
      delta_idx := get_ue_golomb_long(GB^) + 1;
      if delta_idx > SPS^.nb_st_rps then
        Exit(AVERROR_INVALIDDATA);
      rps_ridx := @SPS^.st_rps[SPS^.nb_st_rps - delta_idx];
    end
    else
      rps_ridx := @SPS^.st_rps[(PtrUInt(RPS) - PtrUInt(@SPS^.st_rps[0])) div SizeOf(TShortTermRPS) - 1];

    delta_rps_sign := get_bits1(GB^);
    abs_delta_rps := get_ue_golomb_long(GB^) + 1;
    if (abs_delta_rps < 1) or (abs_delta_rps > 32768) then
      Exit(AVERROR_INVALIDDATA);
    delta_rps := (1 - (Integer(delta_rps_sign) shl 1)) * Integer(abs_delta_rps);

    for i := 0 to rps_ridx^.num_delta_pocs do
    begin
      RPS^.used[k] := get_bits1(GB^);
      used := RPS^.used[k];
      if used = 0 then
        use_delta_flag := get_bits1(GB^);
      if (used <> 0) or (use_delta_flag <> 0) then
      begin
        if i < rps_ridx^.num_delta_pocs then
          delta_poc := delta_rps + rps_ridx^.delta_poc[i]
        else
          delta_poc := delta_rps;
        RPS^.delta_poc[k] := delta_poc;
        if delta_poc < 0 then Inc(k0) else Inc(k1);
        Inc(k);
      end;
    end;

    RPS^.num_delta_pocs := k;
    RPS^.num_negative_pics := k0;

    if RPS^.num_delta_pocs <> 0 then
    begin
      for i := 1 to RPS^.num_delta_pocs - 1 do
      begin
        delta_poc := RPS^.delta_poc[i];
        used := RPS^.used[i];
        for k := i - 1 downto 0 do
        begin
          tmp := RPS^.delta_poc[k];
          if delta_poc < tmp then
          begin
            RPS^.delta_poc[k + 1] := tmp;
            RPS^.used[k + 1] := RPS^.used[k];
            RPS^.delta_poc[k] := delta_poc;
            RPS^.used[k] := Byte(used);
          end;
        end;
      end;
    end;

    if (RPS^.num_negative_pics shr 1) <> 0 then
    begin
      k := Integer(RPS^.num_negative_pics) - 1;
      for i := 0 to Integer(RPS^.num_negative_pics shr 1) - 1 do
      begin
        delta_poc := RPS^.delta_poc[i];
        used := RPS^.used[i];
        RPS^.delta_poc[i] := RPS^.delta_poc[k];
        RPS^.used[i] := RPS^.used[k];
        RPS^.delta_poc[k] := delta_poc;
        RPS^.used[k] := Byte(used);
        Dec(k);
      end;
    end;
  end
  else
  begin
    RPS^.num_negative_pics := get_ue_golomb_long(GB^);
    nb_positive_pics := get_ue_golomb_long(GB^);
    if (RPS^.num_negative_pics >= 16) or (nb_positive_pics >= 16) then
      Exit(AVERROR_INVALIDDATA);
    RPS^.num_delta_pocs := Integer(RPS^.num_negative_pics) + Integer(nb_positive_pics);
    if RPS^.num_delta_pocs <> 0 then
    begin
      prev := 0;
      for i := 0 to Integer(RPS^.num_negative_pics) - 1 do
      begin
        delta_poc := Integer(get_ue_golomb_long(GB^)) + 1;
        prev := prev - Cardinal(delta_poc);
        RPS^.delta_poc[i] := Int32(prev);
        RPS^.used[i] := get_bits1(GB^);
      end;
      prev := 0;
      for i := 0 to Integer(nb_positive_pics) - 1 do
      begin
        delta_poc := Integer(get_ue_golomb_long(GB^)) + 1;
        prev := prev + Cardinal(delta_poc);
        RPS^.delta_poc[Integer(RPS^.num_negative_pics) + i] := Int32(prev);
        RPS^.used[Integer(RPS^.num_negative_pics) + i] := get_bits1(GB^);
      end;
    end;
  end;
  Result := 0;
end;

procedure set_default_scaling_list_data(SL: PScalingList);
var
  matrixId: Integer;
begin
  for matrixId := 0 to 5 do
  begin
    FillChar(SL^.sl[0][matrixId][0], 16, 16);
    SL^.sl_dc[0][matrixId] := 16;
    SL^.sl_dc[1][matrixId] := 16;
  end;
  for matrixId := 1 to 3 do
  begin
    Move(default_scaling_list_intra[0], SL^.sl[matrixId][0][0], 64);
    Move(default_scaling_list_intra[0], SL^.sl[matrixId][1][0], 64);
    Move(default_scaling_list_intra[0], SL^.sl[matrixId][2][0], 64);
    Move(default_scaling_list_inter[0], SL^.sl[matrixId][3][0], 64);
    Move(default_scaling_list_inter[0], SL^.sl[matrixId][4][0], 64);
    Move(default_scaling_list_inter[0], SL^.sl[matrixId][5][0], 64);
  end;
end;

function scaling_list_data(S: PHEVCContext; SL: PScalingList; SPS: PHEVCSPS): Integer;
var
  GB: PGetBitContext;
  scaling_list_pred_mode_flag: Byte;
  scaling_list_dc_coef: array[0..1, 0..5] of Int32;
  size_id, matrix_id, pos, i: Integer;
  delta: Cardinal;
  next_coef, coef_num: Integer;
  scaling_list_delta_coef: Int32;
begin
  GB := @S^.HEVClc^.gb;
  for size_id := 0 to 3 do
  begin
    matrix_id := 0;
    while matrix_id < 6 do
    begin
      scaling_list_pred_mode_flag := get_bits1(GB^);
      if scaling_list_pred_mode_flag = 0 then
      begin
        delta := get_ue_golomb_long(GB^);
        if delta <> 0 then
        begin
          if Cardinal(matrix_id) < delta then
            Exit(AVERROR_INVALIDDATA);
          if size_id > 0 then
            Move(SL^.sl[size_id][matrix_id - delta][0], SL^.sl[size_id][matrix_id][0], 64)
          else
            Move(SL^.sl[size_id][matrix_id - delta][0], SL^.sl[size_id][matrix_id][0], 16);
          if size_id > 1 then
            SL^.sl_dc[size_id - 2][matrix_id] := SL^.sl_dc[size_id - 2][matrix_id - delta];
        end;
      end
      else
      begin
        next_coef := 8;
        coef_num := FFMIN(64, 1 shl (4 + (size_id shl 1)));
        if size_id > 1 then
        begin
          scaling_list_dc_coef[size_id - 2][matrix_id] := get_se_golomb(GB^) + 8;
          next_coef := scaling_list_dc_coef[size_id - 2][matrix_id];
          SL^.sl_dc[size_id - 2][matrix_id] := Byte(next_coef);
        end;
        for i := 0 to coef_num - 1 do
        begin
          if size_id = 0 then
            pos := 4 * ff_hevc_diag_scan4x4_y[i] + ff_hevc_diag_scan4x4_x[i]
          else
            pos := 8 * ff_hevc_diag_scan8x8_y[i] + ff_hevc_diag_scan8x8_x[i];
          scaling_list_delta_coef := get_se_golomb(GB^);
          next_coef := (next_coef + scaling_list_delta_coef + 256) mod 256;
          SL^.sl[size_id][matrix_id][pos] := Byte(next_coef);
        end;
      end;
      if size_id = 3 then Inc(matrix_id, 3) else Inc(matrix_id);
    end;
  end;

  if SPS^.chroma_format_idc = 3 then
  begin
    for i := 0 to 63 do
    begin
      SL^.sl[3][1][i] := SL^.sl[2][1][i];
      SL^.sl[3][2][i] := SL^.sl[2][2][i];
      SL^.sl[3][4][i] := SL^.sl[2][4][i];
      SL^.sl[3][5][i] := SL^.sl[2][5][i];
    end;
    SL^.sl_dc[1][1] := SL^.sl_dc[0][1];
    SL^.sl_dc[1][2] := SL^.sl_dc[0][2];
    SL^.sl_dc[1][4] := SL^.sl_dc[0][4];
    SL^.sl_dc[1][5] := SL^.sl_dc[0][5];
  end;
  Result := 0;
end;

function ff_hevc_decode_nal_sps(S: PHEVCContext): Integer;
var
  GB: PGetBitContext;
  Ret: Integer;
  sps_id: Cardinal;
  log2_diff_max_min_transform_block_size: Integer;
  i, m: Integer;
  SPS: PHEVCSPS;
  sps_extension_flag: Integer;
  extended_precision_processing_flag: Integer;
  high_precision_offsets_enabled_flag: Integer;
  cabac_bypass_alignment_enabled_flag: Integer;
label
  err;
begin
  GB := @S^.HEVClc^.gb;
  Ret := 0;
  sps_id := 0;
  SPS := av_mallocz(SizeOf(THEVCSPS));
  if SPS = nil then Exit(AVERROR_ENOMEM);

  // create_dummy_vps(): the VPS contents are never read, so nothing to do
  SPS^.vps_id := 0;
  SPS^.max_sub_layers := 1;

  SPS^.chroma_format_idc := Integer(get_bits(GB^, 8));
  if SPS^.chroma_format_idc > 3 then
  begin
    Ret := AVERROR_INVALIDDATA;
    goto err;
  end;
  SPS^.separate_colour_plane_flag := 0;
  SPS^.width := Integer(get_bits_long(GB^, 32));
  SPS^.height := Integer(get_bits_long(GB^, 32));
  Ret := av_image_check_size(Cardinal(SPS^.width), Cardinal(SPS^.height));
  if Ret < 0 then goto err;

  SPS^.bit_depth := Integer(get_bits(GB^, 8)) + 8;
  case SPS^.chroma_format_idc of
    0: SPS^.pix_fmt := AV_PIX_FMT_GRAY16LE;
    1: SPS^.pix_fmt := AV_PIX_FMT_YUV420P16LE;
    2: SPS^.pix_fmt := AV_PIX_FMT_YUV422P16LE;
  else
    SPS^.pix_fmt := AV_PIX_FMT_YUV444P16LE;
  end;
  SPS^.pixel_shift := 1;

  // av_pix_fmt_desc_get(): only log2_chroma_w/h are used
  SPS^.hshift[0] := 0;
  SPS^.vshift[0] := 0;
  case SPS^.chroma_format_idc of
    0, 3:
      begin
        SPS^.hshift[1] := 0; SPS^.hshift[2] := 0;
        SPS^.vshift[1] := 0; SPS^.vshift[2] := 0;
      end;
    1:
      begin
        SPS^.hshift[1] := 1; SPS^.hshift[2] := 1;
        SPS^.vshift[1] := 1; SPS^.vshift[2] := 1;
      end;
    2:
      begin
        SPS^.hshift[1] := 1; SPS^.hshift[2] := 1;
        SPS^.vshift[1] := 0; SPS^.vshift[2] := 0;
      end;
  end;

  SPS^.log2_max_poc_lsb := 8;
  for i := 0 to SPS^.max_sub_layers - 1 do
  begin
    SPS^.temporal_layer[i].max_dec_pic_buffering := 1;
    SPS^.temporal_layer[i].num_reorder_pics := 0;
    SPS^.temporal_layer[i].max_latency_increase := -1;
  end;

  SPS^.log2_min_cb_size := get_ue_golomb_long(GB^) + 3;
  m := (1 shl SPS^.log2_min_cb_size) - 1;
  SPS^.width := (SPS^.width + m) and (not m);
  SPS^.height := (SPS^.height + m) and (not m);

  SPS^.log2_diff_max_min_coding_block_size := get_ue_golomb_long(GB^);
  SPS^.log2_min_tb_size := get_ue_golomb_long(GB^) + 2;
  log2_diff_max_min_transform_block_size := Integer(get_ue_golomb_long(GB^));
  SPS^.log2_max_trafo_size := Cardinal(log2_diff_max_min_transform_block_size) + SPS^.log2_min_tb_size;

  if SPS^.log2_min_tb_size >= SPS^.log2_min_cb_size then
  begin
    Ret := AVERROR_INVALIDDATA;
    goto err;
  end;

  SPS^.max_transform_hierarchy_depth_intra := Integer(get_ue_golomb_long(GB^));
  SPS^.max_transform_hierarchy_depth_inter := SPS^.max_transform_hierarchy_depth_intra;

  SPS^.amp_enabled_flag := 1;
  SPS^.sao_enabled := get_bits1(GB^);
  SPS^.pcm_enabled_flag := Integer(get_bits1(GB^));
  if SPS^.pcm_enabled_flag <> 0 then
  begin
    SPS^.pcm.bit_depth := Byte(get_bits(GB^, 4) + 1);
    SPS^.pcm.bit_depth_chroma := Byte(get_bits(GB^, 4) + 1);
    SPS^.pcm.log2_min_pcm_cb_size := get_ue_golomb_long(GB^) + 3;
    SPS^.pcm.log2_max_pcm_cb_size := SPS^.pcm.log2_min_pcm_cb_size + get_ue_golomb_long(GB^);
    if SPS^.pcm.bit_depth > SPS^.bit_depth then
    begin
      Ret := AVERROR_INVALIDDATA;
      goto err;
    end;
    SPS^.pcm.loop_filter_disable_flag := get_bits1(GB^);
  end;

  SPS^.nb_st_rps := 0;
  SPS^.long_term_ref_pics_present_flag := 0;
  SPS^.sps_temporal_mvp_enabled_flag := 1;
  SPS^.sps_strong_intra_smoothing_enable_flag := get_bits1(GB^);
  SPS^.vui.sar.Num := 0;
  SPS^.vui.sar.Den := 1;

  if get_bits1(GB^) <> 0 then
  begin
    sps_extension_flag := Integer(get_bits1(GB^));
    skip_bits(GB^, 7);
    if sps_extension_flag <> 0 then
    begin
      SPS^.transform_skip_rotation_enabled_flag := Integer(get_bits1(GB^));
      SPS^.transform_skip_context_enabled_flag := Integer(get_bits1(GB^));
      SPS^.implicit_rdpcm_enabled_flag := Integer(get_bits1(GB^));
      SPS^.explicit_rdpcm_enabled_flag := Integer(get_bits1(GB^));
      extended_precision_processing_flag := Integer(get_bits1(GB^));
      SPS^.intra_smoothing_disabled_flag := Integer(get_bits1(GB^));
      high_precision_offsets_enabled_flag := Integer(get_bits1(GB^));
      SPS^.persistent_rice_adaptation_enabled_flag := Integer(get_bits1(GB^));
      cabac_bypass_alignment_enabled_flag := Integer(get_bits1(GB^));
      // extended precision / high precision offsets / cabac bypass alignment
      // are not implemented by the reference decoder either
    end;
  end;

  SPS^.output_width := SPS^.width;
  SPS^.output_height := SPS^.height;
  SPS^.log2_ctb_size := SPS^.log2_min_cb_size + SPS^.log2_diff_max_min_coding_block_size;
  SPS^.log2_min_pu_size := SPS^.log2_min_cb_size - 1;

  SPS^.ctb_width := (SPS^.width + (1 shl SPS^.log2_ctb_size) - 1) shr SPS^.log2_ctb_size;
  SPS^.ctb_height := (SPS^.height + (1 shl SPS^.log2_ctb_size) - 1) shr SPS^.log2_ctb_size;
  SPS^.ctb_size := SPS^.ctb_width * SPS^.ctb_height;

  SPS^.min_cb_width := SPS^.width shr SPS^.log2_min_cb_size;
  SPS^.min_cb_height := SPS^.height shr SPS^.log2_min_cb_size;
  SPS^.min_tb_width := SPS^.width shr SPS^.log2_min_tb_size;
  SPS^.min_tb_height := SPS^.height shr SPS^.log2_min_tb_size;
  SPS^.min_pu_width := SPS^.width shr SPS^.log2_min_pu_size;
  SPS^.min_pu_height := SPS^.height shr SPS^.log2_min_pu_size;
  SPS^.tb_mask := (1 shl (SPS^.log2_ctb_size - SPS^.log2_min_tb_size)) - 1;

  SPS^.qp_bd_offset := 6 * (SPS^.bit_depth - 8);

  if ((SPS^.width and ((1 shl SPS^.log2_min_cb_size) - 1)) <> 0) or
     ((SPS^.height and ((1 shl SPS^.log2_min_cb_size) - 1)) <> 0) then
    goto err;
  if SPS^.log2_ctb_size > 6 then
    goto err;
  if SPS^.max_transform_hierarchy_depth_inter >
     Integer(SPS^.log2_ctb_size) - Integer(SPS^.log2_min_tb_size) then
    goto err;
  if SPS^.max_transform_hierarchy_depth_intra >
     Integer(SPS^.log2_ctb_size) - Integer(SPS^.log2_min_tb_size) then
    goto err;
  if SPS^.log2_max_trafo_size > Cardinal(FFMIN(Integer(SPS^.log2_ctb_size), 5)) then
    goto err;
  if get_bits_left(GB^) < 0 then
    goto err;

  // install the new SPS, mirroring the ownership dance of the reference
  if (S^.sps_list[sps_id] <> nil) and
     CompareMem(S^.sps_list[sps_id], SPS, SizeOf(THEVCSPS)) then
  begin
    hevc_sps_free(SPS);
  end
  else
  begin
    for i := 0 to MAX_PPS_COUNT - 1 do
      if (S^.pps_list[i] <> nil) and (S^.pps_list[i]^.sps_id = sps_id) then
      begin
        hevc_pps_free(S^.pps_list[i]);
        S^.pps_list[i] := nil;
      end;
    if (S^.sps_list[sps_id] <> nil) and (S^.sps = S^.sps_list[sps_id]) then
    begin
      // the active SPS is still in use: transfer its ownership to current_sps
      // instead of freeing it
      if S^.current_sps <> nil then hevc_sps_free(S^.current_sps);
      S^.current_sps := S^.sps_list[sps_id];
      S^.sps_list[sps_id] := nil;
    end;
    if S^.sps_list[sps_id] <> nil then hevc_sps_free(S^.sps_list[sps_id]);
    S^.sps_list[sps_id] := SPS;
  end;
  Exit(0);

err:
  hevc_sps_free(SPS);
  if Ret = 0 then Ret := AVERROR_INVALIDDATA;
  Result := Ret;
end;

function pps_range_extensions(S: PHEVCContext; PPS: PHEVCPPS; SPS: PHEVCSPS): Integer;
var
  GB: PGetBitContext;
  i: Integer;
begin
  GB := @S^.HEVClc^.gb;
  if PPS^.transform_skip_enabled_flag <> 0 then
    PPS^.log2_max_transform_skip_block_size := Byte(get_ue_golomb_long(GB^) + 2);
  PPS^.cross_component_prediction_enabled_flag := get_bits1(GB^);
  PPS^.chroma_qp_offset_list_enabled_flag := get_bits1(GB^);
  if PPS^.chroma_qp_offset_list_enabled_flag <> 0 then
  begin
    PPS^.diff_cu_chroma_qp_offset_depth := Byte(get_ue_golomb_long(GB^));
    PPS^.chroma_qp_offset_list_len_minus1 := Byte(get_ue_golomb_long(GB^));
    if (PPS^.chroma_qp_offset_list_len_minus1 <> 0) and
       (PPS^.chroma_qp_offset_list_len_minus1 >= 5) then
      Exit(AVERROR_INVALIDDATA);
    for i := 0 to PPS^.chroma_qp_offset_list_len_minus1 do
    begin
      PPS^.cb_qp_offset_list[i] := Int8(get_se_golomb_long(GB^));
      PPS^.cr_qp_offset_list[i] := Int8(get_se_golomb_long(GB^));
    end;
  end;
  PPS^.log2_sao_offset_scale_luma := Byte(get_ue_golomb_long(GB^));
  PPS^.log2_sao_offset_scale_chroma := Byte(get_ue_golomb_long(GB^));
  Result := 0;
end;

function ff_hevc_decode_nal_pps(S: PHEVCContext): Integer;
var
  GB: PGetBitContext;
  SPS: PHEVCSPS;
  pic_area_in_ctbs: Integer;
  log2_diff_ctb_min_tb_size: Integer;
  i, j, x, y, ctb_addr_rs, tile_id: Integer;
  Ret: Integer;
  pps_id: Cardinal;
  PPS: PHEVCPPS;
  sum: QWord;
  tb_x, tb_y, tile_x, tile_y, val, mm: Integer;
  pps_range_extensions_flag: Integer;
label
  err;
begin
  GB := @S^.HEVClc^.gb;
  SPS := nil;
  Ret := 0;
  pps_id := 0;
  tile_id := 0;
  PPS := av_mallocz(SizeOf(THEVCPPS));
  if PPS = nil then Exit(AVERROR_ENOMEM);

  PPS^.loop_filter_across_tiles_enabled_flag := 1;
  PPS^.num_tile_columns := 1;
  PPS^.num_tile_rows := 1;
  PPS^.uniform_spacing_flag := 1;
  PPS^.disable_dbf := 0;
  PPS^.beta_offset := 0;
  PPS^.tc_offset := 0;
  PPS^.log2_max_transform_skip_block_size := 2;

  pps_id := get_ue_golomb_long(GB^);
  if pps_id >= 256 then
  begin
    Ret := AVERROR_INVALIDDATA;
    goto err;
  end;
  PPS^.sps_id := get_ue_golomb_long(GB^);
  if PPS^.sps_id >= 32 then
  begin
    Ret := AVERROR_INVALIDDATA;
    goto err;
  end;
  if S^.sps_list[PPS^.sps_id] = nil then
  begin
    Ret := AVERROR_INVALIDDATA;
    goto err;
  end;
  SPS := S^.sps_list[PPS^.sps_id];

  PPS^.dependent_slice_segments_enabled_flag := get_bits1(GB^);
  PPS^.output_flag_present_flag := get_bits1(GB^);
  PPS^.num_extra_slice_header_bits := Integer(get_bits(GB^, 3));
  PPS^.sign_data_hiding_flag := get_bits1(GB^);
  PPS^.cabac_init_present_flag := get_bits1(GB^);
  PPS^.num_ref_idx_l0_default_active := Integer(get_ue_golomb_long(GB^)) + 1;
  PPS^.num_ref_idx_l1_default_active := Integer(get_ue_golomb_long(GB^)) + 1;
  PPS^.pic_init_qp_minus26 := get_se_golomb(GB^);
  PPS^.constrained_intra_pred_flag := get_bits1(GB^);
  PPS^.transform_skip_enabled_flag := get_bits1(GB^);
  PPS^.cu_qp_delta_enabled_flag := get_bits1(GB^);
  PPS^.diff_cu_qp_delta_depth := 0;
  if PPS^.cu_qp_delta_enabled_flag <> 0 then
    PPS^.diff_cu_qp_delta_depth := Integer(get_ue_golomb_long(GB^));

  PPS^.cb_qp_offset := get_se_golomb(GB^);
  if (PPS^.cb_qp_offset < -12) or (PPS^.cb_qp_offset > 12) then
  begin
    Ret := AVERROR_INVALIDDATA;
    goto err;
  end;
  PPS^.cr_qp_offset := get_se_golomb(GB^);
  if (PPS^.cr_qp_offset < -12) or (PPS^.cr_qp_offset > 12) then
  begin
    Ret := AVERROR_INVALIDDATA;
    goto err;
  end;
  PPS^.pic_slice_level_chroma_qp_offsets_present_flag := get_bits1(GB^);
  PPS^.weighted_pred_flag := get_bits1(GB^);
  PPS^.weighted_bipred_flag := get_bits1(GB^);
  PPS^.transquant_bypass_enable_flag := get_bits1(GB^);
  PPS^.tiles_enabled_flag := get_bits1(GB^);
  PPS^.entropy_coding_sync_enabled_flag := get_bits1(GB^);

  if PPS^.tiles_enabled_flag <> 0 then
  begin
    PPS^.num_tile_columns := Integer(get_ue_golomb_long(GB^)) + 1;
    PPS^.num_tile_rows := Integer(get_ue_golomb_long(GB^)) + 1;
    if (PPS^.num_tile_columns = 0) or (PPS^.num_tile_columns >= SPS^.width) then
    begin
      Ret := AVERROR_INVALIDDATA;
      goto err;
    end;
    if (PPS^.num_tile_rows = 0) or (PPS^.num_tile_rows >= SPS^.height) then
    begin
      Ret := AVERROR_INVALIDDATA;
      goto err;
    end;
    PPS^.column_width := av_malloc_array(PPS^.num_tile_columns, SizeOf(Cardinal));
    PPS^.row_height := av_malloc_array(PPS^.num_tile_rows, SizeOf(Cardinal));
    if (PPS^.column_width = nil) or (PPS^.row_height = nil) then
    begin
      Ret := AVERROR_ENOMEM;
      goto err;
    end;
    PPS^.uniform_spacing_flag := get_bits1(GB^);
    if PPS^.uniform_spacing_flag = 0 then
    begin
      sum := 0;
      for i := 0 to PPS^.num_tile_columns - 2 do
      begin
        PPS^.column_width[i] := get_ue_golomb_long(GB^) + 1;
        sum := sum + PPS^.column_width[i];
      end;
      if sum >= QWord(SPS^.ctb_width) then
      begin
        Ret := AVERROR_INVALIDDATA;
        goto err;
      end;
      PPS^.column_width[PPS^.num_tile_columns - 1] := Cardinal(SPS^.ctb_width) - Cardinal(sum);
      sum := 0;
      for i := 0 to PPS^.num_tile_rows - 2 do
      begin
        PPS^.row_height[i] := get_ue_golomb_long(GB^) + 1;
        sum := sum + PPS^.row_height[i];
      end;
      if sum >= QWord(SPS^.ctb_height) then
      begin
        Ret := AVERROR_INVALIDDATA;
        goto err;
      end;
      PPS^.row_height[PPS^.num_tile_rows - 1] := Cardinal(SPS^.ctb_height) - Cardinal(sum);
    end;
    PPS^.loop_filter_across_tiles_enabled_flag := get_bits1(GB^);
  end;

  PPS^.seq_loop_filter_across_slices_enabled_flag := get_bits1(GB^);
  PPS^.deblocking_filter_control_present_flag := get_bits1(GB^);
  if PPS^.deblocking_filter_control_present_flag <> 0 then
  begin
    PPS^.deblocking_filter_override_enabled_flag := get_bits1(GB^);
    PPS^.disable_dbf := get_bits1(GB^);
    if PPS^.disable_dbf = 0 then
    begin
      PPS^.beta_offset := get_se_golomb(GB^) * 2;
      PPS^.tc_offset := get_se_golomb(GB^) * 2;
      if (PPS^.beta_offset div 2 < -6) or (PPS^.beta_offset div 2 > 6) then
      begin
        Ret := AVERROR_INVALIDDATA;
        goto err;
      end;
      if (PPS^.tc_offset div 2 < -6) or (PPS^.tc_offset div 2 > 6) then
      begin
        Ret := AVERROR_INVALIDDATA;
        goto err;
      end;
    end;
  end;

  PPS^.scaling_list_data_present_flag := get_bits1(GB^);
  if PPS^.scaling_list_data_present_flag <> 0 then
  begin
    set_default_scaling_list_data(@PPS^.scaling_list);
    Ret := scaling_list_data(S, @PPS^.scaling_list, SPS);
    if Ret < 0 then goto err;
  end;

  PPS^.lists_modification_present_flag := get_bits1(GB^);
  PPS^.log2_parallel_merge_level := Integer(get_ue_golomb_long(GB^)) + 2;
  if Cardinal(PPS^.log2_parallel_merge_level) > SPS^.log2_ctb_size then
  begin
    Ret := AVERROR_INVALIDDATA;
    goto err;
  end;

  PPS^.slice_header_extension_present_flag := get_bits1(GB^);

  if get_bits1(GB^) <> 0 then
  begin
    pps_range_extensions_flag := Integer(get_bits1(GB^));
    get_bits(GB^, 7);
    if pps_range_extensions_flag <> 0 then
      pps_range_extensions(S, PPS, SPS);
  end;

  PPS^.col_bd := av_malloc_array(PPS^.num_tile_columns + 1, SizeOf(Cardinal));
  PPS^.row_bd := av_malloc_array(PPS^.num_tile_rows + 1, SizeOf(Cardinal));
  PPS^.col_idxX := av_malloc_array(SPS^.ctb_width, SizeOf(Integer));
  if (PPS^.col_bd = nil) or (PPS^.row_bd = nil) or (PPS^.col_idxX = nil) then
  begin
    Ret := AVERROR_ENOMEM;
    goto err;
  end;

  if PPS^.uniform_spacing_flag <> 0 then
  begin
    if PPS^.column_width = nil then
    begin
      PPS^.column_width := av_malloc_array(PPS^.num_tile_columns, SizeOf(Cardinal));
      PPS^.row_height := av_malloc_array(PPS^.num_tile_rows, SizeOf(Cardinal));
    end;
    if (PPS^.column_width = nil) or (PPS^.row_height = nil) then
    begin
      Ret := AVERROR_ENOMEM;
      goto err;
    end;
    for i := 0 to PPS^.num_tile_columns - 1 do
      PPS^.column_width[i] := Cardinal(((i + 1) * SPS^.ctb_width) div PPS^.num_tile_columns -
                                       (i * SPS^.ctb_width) div PPS^.num_tile_columns);
    for i := 0 to PPS^.num_tile_rows - 1 do
      PPS^.row_height[i] := Cardinal(((i + 1) * SPS^.ctb_height) div PPS^.num_tile_rows -
                                     (i * SPS^.ctb_height) div PPS^.num_tile_rows);
  end;

  PPS^.col_bd[0] := 0;
  for i := 0 to PPS^.num_tile_columns - 1 do
    PPS^.col_bd[i + 1] := PPS^.col_bd[i] + PPS^.column_width[i];
  PPS^.row_bd[0] := 0;
  for i := 0 to PPS^.num_tile_rows - 1 do
    PPS^.row_bd[i + 1] := PPS^.row_bd[i] + PPS^.row_height[i];

  j := 0;
  for i := 0 to SPS^.ctb_width - 1 do
  begin
    if Cardinal(i) > PPS^.col_bd[j] then Inc(j);
    PPS^.col_idxX[i] := j;
  end;

  pic_area_in_ctbs := SPS^.ctb_width * SPS^.ctb_height;
  PPS^.ctb_addr_rs_to_ts := av_malloc_array(pic_area_in_ctbs, SizeOf(Integer));
  PPS^.ctb_addr_ts_to_rs := av_malloc_array(pic_area_in_ctbs, SizeOf(Integer));
  PPS^.tile_id := av_malloc_array(pic_area_in_ctbs, SizeOf(Integer));
  PPS^.min_tb_addr_zs_tab := av_malloc_array((SPS^.tb_mask + 2) * (SPS^.tb_mask + 2), SizeOf(Integer));
  if (PPS^.ctb_addr_rs_to_ts = nil) or (PPS^.ctb_addr_ts_to_rs = nil) or
     (PPS^.tile_id = nil) or (PPS^.min_tb_addr_zs_tab = nil) then
  begin
    Ret := AVERROR_ENOMEM;
    goto err;
  end;

  for ctb_addr_rs := 0 to pic_area_in_ctbs - 1 do
  begin
    tb_x := ctb_addr_rs mod SPS^.ctb_width;
    tb_y := ctb_addr_rs div SPS^.ctb_width;
    tile_x := 0;
    tile_y := 0;
    val := 0;
    for i := 0 to PPS^.num_tile_columns - 1 do
      if Cardinal(tb_x) < PPS^.col_bd[i + 1] then
      begin
        tile_x := i;
        Break;
      end;
    for i := 0 to PPS^.num_tile_rows - 1 do
      if Cardinal(tb_y) < PPS^.row_bd[i + 1] then
      begin
        tile_y := i;
        Break;
      end;
    for i := 0 to tile_x - 1 do
      val := val + Integer(PPS^.row_height[tile_y] * PPS^.column_width[i]);
    for i := 0 to tile_y - 1 do
      val := val + SPS^.ctb_width * Integer(PPS^.row_height[i]);
    val := val + (tb_y - Integer(PPS^.row_bd[tile_y])) * Integer(PPS^.column_width[tile_x]) +
           tb_x - Integer(PPS^.col_bd[tile_x]);
    PPS^.ctb_addr_rs_to_ts[ctb_addr_rs] := val;
    PPS^.ctb_addr_ts_to_rs[val] := ctb_addr_rs;
  end;

  tile_id := 0;
  for j := 0 to PPS^.num_tile_rows - 1 do
    for i := 0 to PPS^.num_tile_columns - 1 do
    begin
      for y := Integer(PPS^.row_bd[j]) to Integer(PPS^.row_bd[j + 1]) - 1 do
        for x := Integer(PPS^.col_bd[i]) to Integer(PPS^.col_bd[i + 1]) - 1 do
          PPS^.tile_id[PPS^.ctb_addr_rs_to_ts[y * SPS^.ctb_width + x]] := tile_id;
      Inc(tile_id);
    end;

  PPS^.tile_pos_rs := av_malloc_array(tile_id, SizeOf(Integer));
  if PPS^.tile_pos_rs = nil then
  begin
    Ret := AVERROR_ENOMEM;
    goto err;
  end;
  for j := 0 to PPS^.num_tile_rows - 1 do
    for i := 0 to PPS^.num_tile_columns - 1 do
      PPS^.tile_pos_rs[j * PPS^.num_tile_columns + i] :=
        Integer(PPS^.row_bd[j]) * SPS^.ctb_width + Integer(PPS^.col_bd[i]);

  log2_diff_ctb_min_tb_size := Integer(SPS^.log2_ctb_size) - Integer(SPS^.log2_min_tb_size);
  PPS^.min_tb_addr_zs := @PPS^.min_tb_addr_zs_tab[1 * (SPS^.tb_mask + 2) + 1];
  for y := 0 to SPS^.tb_mask + 1 do
  begin
    PPS^.min_tb_addr_zs_tab[y * (SPS^.tb_mask + 2)] := -1;
    PPS^.min_tb_addr_zs_tab[y] := -1;
  end;
  for y := 0 to SPS^.tb_mask do
    for x := 0 to SPS^.tb_mask do
    begin
      tb_x := x shr log2_diff_ctb_min_tb_size;
      tb_y := y shr log2_diff_ctb_min_tb_size;
      ctb_addr_rs := SPS^.ctb_width * tb_y + tb_x;
      val := PPS^.ctb_addr_rs_to_ts[ctb_addr_rs] shl (log2_diff_ctb_min_tb_size * 2);
      for i := 0 to log2_diff_ctb_min_tb_size - 1 do
      begin
        mm := 1 shl i;
        if (mm and x) <> 0 then val := val + mm * mm;
        if (mm and y) <> 0 then val := val + 2 * mm * mm;
      end;
      PPS^.min_tb_addr_zs[y * (SPS^.tb_mask + 2) + x] := val;
    end;

  if get_bits_left(GB^) < 0 then
    goto err;

  if S^.pps_list[pps_id] <> nil then hevc_pps_free(S^.pps_list[pps_id]);
  S^.pps_list[pps_id] := PPS;
  Exit(0);

err:
  hevc_pps_free(PPS);
  if Ret = 0 then Ret := AVERROR_INVALIDDATA;
  Result := Ret;
end;

end.
