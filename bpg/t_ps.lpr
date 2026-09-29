// Round-trip test for the parameter set writers: builds an MSPS and a PPS with
// bpg_ps_enc, feeds them through the decoder's own parsers, and checks that
// every field comes back with the value that went in.
program t_ps;

{$mode Delphi}
{$H+}
{$POINTERMATH ON}

uses
  SysUtils, bpg_common, bpg_putbits, bpg_hevc_defs, bpg_bits, bpg_hevc_ps,
  bpg_hevc, bpg_ps_enc, bpg_slice_enc, bpg_cabac;

var
  Ctx: THEVCContext;
  Bad: Integer = 0;

procedure Chk(const Name: string; Got, Want: Integer);
begin
  if Got <> Want then
  begin
    WriteLn(Format('  MISMATCH %-34s got=%d want=%d', [Name, Got, Want]));
    Inc(Bad);
  end;
end;

var
  S: TEncSps;
  P: TEncPps;
  MspsTail, Full, PpsBuf: TByteBuf;
  I: Integer;
  Sps: PHEVCSPS;
  HD: TEncSliceHdr;
  ShBuf: TByteBuf;
  Pps: PHEVCPPS;
begin
  if hevc_init_context(@Ctx) < 0 then Halt(1);

  S.Width := 320;
  S.Height := 240;
  S.ChromaFormatIdc := 1;
  S.BitDepth := 8;
  S.Log2MinCbSize := 3;
  S.Log2MaxCbSize := 6;
  S.Log2MinTbSize := 2;
  S.Log2MaxTbSize := 5;
  S.MaxTransformHierarchyDepth := 2;
  S.SaoEnabled := 1;
  S.StrongIntraSmoothing := 1;

  buf_init(MspsTail);
  write_msps(MspsTail, S);

  // prepend the ten fixed bytes exactly as the container does
  buf_init(Full);
  buf_put_byte(Full, Byte(S.ChromaFormatIdc));
  buf_put_byte(Full, Byte(S.Width shr 24));  buf_put_byte(Full, Byte(S.Width shr 16));
  buf_put_byte(Full, Byte(S.Width shr 8));   buf_put_byte(Full, Byte(S.Width));
  buf_put_byte(Full, Byte(S.Height shr 24)); buf_put_byte(Full, Byte(S.Height shr 16));
  buf_put_byte(Full, Byte(S.Height shr 8));  buf_put_byte(Full, Byte(S.Height));
  buf_put_byte(Full, Byte(S.BitDepth - 8));
  buf_put(Full, MspsTail.Buf, MspsTail.Len);

  WriteLn(Format('msps tail %d bytes, full %d bytes', [MspsTail.Len, Full.Len]));

  if init_get_bits8(Ctx.HEVClc^.gb, Full.Buf, Full.Len) < 0 then Halt(1);
  if ff_hevc_decode_nal_sps(@Ctx) < 0 then
  begin
    WriteLn('SPS parse FAILED');
    Halt(1);
  end;
  Sps := Ctx.sps_list[0];
  if Sps = nil then begin WriteLn('no SPS stored'); Halt(1); end;

  Chk('width', Sps^.width, S.Width);
  Chk('height', Sps^.height, S.Height);
  Chk('chroma_format_idc', Sps^.chroma_format_idc, S.ChromaFormatIdc);
  Chk('bit_depth', Sps^.bit_depth, S.BitDepth);
  Chk('log2_min_cb_size', Sps^.log2_min_cb_size, S.Log2MinCbSize);
  Chk('log2_ctb_size', Sps^.log2_ctb_size, S.Log2MaxCbSize);
  Chk('log2_min_tb_size', Sps^.log2_min_tb_size, S.Log2MinTbSize);
  Chk('log2_max_trafo_size', Integer(Sps^.log2_max_trafo_size), S.Log2MaxTbSize);
  Chk('max_transform_hierarchy_depth_intra',
      Sps^.max_transform_hierarchy_depth_intra, S.MaxTransformHierarchyDepth);
  Chk('sao_enabled', Sps^.sao_enabled, S.SaoEnabled);
  Chk('sps_strong_intra_smoothing_enable_flag',
      Sps^.sps_strong_intra_smoothing_enable_flag, S.StrongIntraSmoothing);
  Chk('pcm_enabled_flag', Sps^.pcm_enabled_flag, 0);
  Chk('scaling_list_enable_flag', Sps^.scaling_list_enable_flag, 0);

  P.InitQpMinus26 := 2;
  P.SignDataHiding := 1;
  P.ConstrainedIntraPred := 0;
  P.TransformSkipEnabled := 0;
  P.CuQpDeltaEnabled := 0;
  P.DiffCuQpDeltaDepth := 0;
  P.CbQpOffset := -1;
  P.CrQpOffset := 3;
  P.TransquantBypassEnabled := 0;
  P.LoopFilterAcrossSlices := 1;
  P.DeblockingControlPresent := 1;
  P.DeblockingDisabled := 0;
  P.BetaOffsetDiv2 := 1;
  P.TcOffsetDiv2 := -2;

  buf_init(PpsBuf);
  write_pps(PpsBuf, P);
  WriteLn(Format('pps %d bytes', [PpsBuf.Len]));

  if init_get_bits8(Ctx.HEVClc^.gb, PpsBuf.Buf, PpsBuf.Len) < 0 then Halt(1);
  if ff_hevc_decode_nal_pps(@Ctx) < 0 then
  begin
    WriteLn('PPS parse FAILED');
    Halt(1);
  end;
  Pps := Ctx.pps_list[0];
  if Pps = nil then begin WriteLn('no PPS stored'); Halt(1); end;

  Chk('pic_init_qp_minus26', Pps^.pic_init_qp_minus26, P.InitQpMinus26);
  Chk('sign_data_hiding_flag', Pps^.sign_data_hiding_flag, P.SignDataHiding);
  Chk('constrained_intra_pred_flag', Pps^.constrained_intra_pred_flag, P.ConstrainedIntraPred);
  Chk('transform_skip_enabled_flag', Pps^.transform_skip_enabled_flag, P.TransformSkipEnabled);
  Chk('cu_qp_delta_enabled_flag', Pps^.cu_qp_delta_enabled_flag, P.CuQpDeltaEnabled);
  Chk('cb_qp_offset', Pps^.cb_qp_offset, P.CbQpOffset);
  Chk('cr_qp_offset', Pps^.cr_qp_offset, P.CrQpOffset);
  Chk('transquant_bypass_enable_flag', Pps^.transquant_bypass_enable_flag, P.TransquantBypassEnabled);
  Chk('seq_loop_filter_across_slices_enabled_flag',
      Pps^.seq_loop_filter_across_slices_enabled_flag, P.LoopFilterAcrossSlices);
  Chk('deblocking_filter_control_present_flag',
      Pps^.deblocking_filter_control_present_flag, P.DeblockingControlPresent);
  Chk('disable_dbf', Pps^.disable_dbf, P.DeblockingDisabled);
  Chk('beta_offset', Pps^.beta_offset, P.BetaOffsetDiv2 * 2);
  Chk('tc_offset', Pps^.tc_offset, P.TcOffsetDiv2 * 2);
  Chk('tiles_enabled_flag', Pps^.tiles_enabled_flag, 0);
  Chk('entropy_coding_sync_enabled_flag', Pps^.entropy_coding_sync_enabled_flag, 0);

  // --- slice header ---
  HD.SliceQpDelta := -2;
  HD.SaoLuma := 1;
  HD.SaoChroma := 1;
  HD.LoopFilterAcrossSlices := 1;

  buf_init(ShBuf);
  write_slice_header(ShBuf, S, P, HD);
  WriteLn(Format('slice header %d bytes', [ShBuf.Len]));

  Ctx.nal_unit_type := NAL_IDR_W_RADL;
  Ctx.temporal_id := 0;
  if init_get_bits8(Ctx.HEVClc^.gb, ShBuf.Buf, ShBuf.Len) < 0 then Halt(1);
  if hls_slice_header(@Ctx) < 0 then
  begin
    WriteLn('slice header parse FAILED');
    Halt(1);
  end;
  Chk('slice_type', Ctx.sh.slice_type, 2);
  Chk('first_slice_in_pic_flag', Ctx.sh.first_slice_in_pic_flag, 1);
  Chk('slice_qp_delta', Ctx.sh.slice_qp_delta, HD.SliceQpDelta);
  Chk('slice_qp', Ctx.sh.slice_qp, 26 + P.InitQpMinus26 + HD.SliceQpDelta);
  Chk('sao luma', Ctx.sh.slice_sample_adaptive_offset_flag[0], HD.SaoLuma);
  Chk('sao chroma', Ctx.sh.slice_sample_adaptive_offset_flag[1], HD.SaoChroma);
  Chk('loop_filter_across_slices',
      Ctx.sh.slice_loop_filter_across_slices_enabled_flag, HD.LoopFilterAcrossSlices);
  Chk('disable_deblocking_filter_flag', Ctx.sh.disable_deblocking_filter_flag,
      P.DeblockingDisabled);
  Chk('num_entry_point_offsets', Ctx.sh.num_entry_point_offsets, 0);
  // The parse stops right after the last syntax element, with the alignment
  // one-bit and its zero padding still unread. Doing what cabac_init_decoder
  // does -- skip the one bit, then align -- must land exactly on the end of the
  // header, which is where the CABAC data begins.
  skip_bits(Ctx.HEVClc^.gb, 1);
  align_get_bits(Ctx.HEVClc^.gb);
  Chk('byte position after align', get_bits_count(Ctx.HEVClc^.gb) div 8, ShBuf.Len);
  Chk('bits left after align', get_bits_left(Ctx.HEVClc^.gb), 0);

  if Bad = 0 then
    WriteLn('parameter set and slice header round trip OK')
  else
  begin
    WriteLn(Format('FAILED: %d mismatched fields', [Bad]));
    Halt(1);
  end;

  buf_free(MspsTail);
  buf_free(Full);
  buf_free(PpsBuf);
  buf_free(ShBuf);
  hevc_decode_free(@Ctx);
end.
