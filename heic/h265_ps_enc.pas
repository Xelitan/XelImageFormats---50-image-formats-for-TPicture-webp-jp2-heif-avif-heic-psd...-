// BPG encoder -- Free Pascal
// Writers for the parameter sets: the BPG "modified SPS" and a plain HEVC PPS.
// The inverse of h265_hevc_ps.
//
// The MSPS is what a BPG file actually stores. Its first ten bytes
// (chroma_format_idc, width, height, bit_depth - 8) are prepended by the
// container when it rebuilds the NAL, so write_msps emits only the tail, which
// is what goes into the file after the length prefix.
unit h265_ps_enc;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}

interface

uses
  h265_common, h265_putbits;

type
  // The encoder's view of a sequence. Only the fields the BPG profile can
  // actually vary are present; everything else is fixed by the format.
  TEncSps = record
    Width, Height: Integer;
    ChromaFormatIdc: Integer; // 0 = gray, 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4
    BitDepth: Integer; // 8 .. 14
    Log2MinCbSize: Integer; // >= 3
    Log2MaxCbSize: Integer;
    Log2MinTbSize: Integer; // >= 2, < Log2MinCbSize
    Log2MaxTbSize: Integer;
    MaxTransformHierarchyDepth: Integer;
    SaoEnabled: Integer;
    StrongIntraSmoothing: Integer;
    ImplicitRdpcm: Integer;
  end;

  TEncPps = record
    InitQpMinus26: Integer;
    SignDataHiding: Integer;
    ConstrainedIntraPred: Integer;
    TransformSkipEnabled: Integer;
    CrossComponentPred: Integer;
    CuQpDeltaEnabled: Integer;
    DiffCuQpDeltaDepth: Integer;
    CbQpOffset, CrQpOffset: Integer;
    TransquantBypassEnabled: Integer;
    LoopFilterAcrossSlices: Integer;
    DeblockingControlPresent: Integer;
    DeblockingDisabled: Integer;
    BetaOffsetDiv2, TcOffsetDiv2: Integer;
  end;

// Emits the MSPS tail (everything the decoder reads after the fixed ten bytes)
// into Out_, byte aligned, with the rbsp stop bit.
procedure write_msps(var Out_: TByteBuf; const S: TEncSps);

// Emits a complete PPS RBSP (no NAL header, no start code).
procedure write_pps(var Out_: TByteBuf; const P: TEncPps);

implementation

procedure write_msps(var Out_: TByteBuf; const S: TEncSps);
var
  B: TPutBitContext;
begin
  put_bits_init(B, @Out_);
  put_ue_golomb(B, Cardinal(S.Log2MinCbSize - 3));
  put_ue_golomb(B, Cardinal(S.Log2MaxCbSize - S.Log2MinCbSize));
  put_ue_golomb(B, Cardinal(S.Log2MinTbSize - 2));
  put_ue_golomb(B, Cardinal(S.Log2MaxTbSize - S.Log2MinTbSize));
  put_ue_golomb(B, Cardinal(S.MaxTransformHierarchyDepth));
  put_bit(B, S.SaoEnabled);
  put_bit(B, 0); // pcm_enabled_flag
  put_bit(B, S.StrongIntraSmoothing);
  // The range extension carries implicit RDPCM, which is what makes lossless
  // coding worth anything: with purely horizontal or vertical prediction the
  // residual is differentiated along the prediction direction, and a smooth
  // gradient collapses to near zero. BPG copies the tail of the SPS verbatim
  // into the modified SPS, so the extension travels intact.
  if S.ImplicitRdpcm <> 0 then
  begin
    put_bit(B, 1); // sps_extension_present_flag
    put_bit(B, 1); // sps_range_extension_flag
    put_bits(B, 7, 0); // sps_extension_7bits
    put_bit(B, 0); // transform_skip_rotation_enabled
    put_bit(B, 0); // transform_skip_context_enabled
    put_bit(B, 1); // implicit_rdpcm_enabled
    put_bit(B, 0); // explicit_rdpcm_enabled
    put_bit(B, 0); // extended_precision_processing
    put_bit(B, 0); // intra_smoothing_disabled
    put_bit(B, 0); // high_precision_offsets_enabled
    put_bit(B, 0); // persistent_rice_adaptation_enabled
    put_bit(B, 0); // cabac_bypass_alignment_enabled
  end
  else
    put_bit(B, 0); // no sps extension
  put_rbsp_trailing_bits(B);
end;

procedure write_pps(var Out_: TByteBuf; const P: TEncPps);
var
  B: TPutBitContext;
begin
  put_bits_init(B, @Out_);
  put_ue_golomb(B, 0); // pps_pic_parameter_set_id
  put_ue_golomb(B, 0); // pps_seq_parameter_set_id
  put_bit(B, 0); // dependent_slice_segments_enabled
  put_bit(B, 0); // output_flag_present
  put_bits(B, 3, 0); // num_extra_slice_header_bits
  put_bit(B, P.SignDataHiding);
  put_bit(B, 0); // cabac_init_present
  put_ue_golomb(B, 0); // num_ref_idx_l0_default_active_minus1
  put_ue_golomb(B, 0); // num_ref_idx_l1_default_active_minus1
  put_se_golomb(B, P.InitQpMinus26);
  put_bit(B, P.ConstrainedIntraPred);
  put_bit(B, P.TransformSkipEnabled);
  put_bit(B, P.CuQpDeltaEnabled);
  if P.CuQpDeltaEnabled <> 0 then
    put_ue_golomb(B, Cardinal(P.DiffCuQpDeltaDepth));
  put_se_golomb(B, P.CbQpOffset);
  put_se_golomb(B, P.CrQpOffset);
  put_bit(B, 0); // pps_slice_chroma_qp_offsets_present
  put_bit(B, 0); // weighted_pred
  put_bit(B, 0); // weighted_bipred
  put_bit(B, P.TransquantBypassEnabled);
  put_bit(B, 0); // tiles_enabled
  put_bit(B, 0); // entropy_coding_sync_enabled
  put_bit(B, P.LoopFilterAcrossSlices);
  put_bit(B, P.DeblockingControlPresent);
  if P.DeblockingControlPresent <> 0 then
  begin
    put_bit(B, 0); // deblocking_filter_override_enabled
    put_bit(B, P.DeblockingDisabled);
    if P.DeblockingDisabled = 0 then
    begin
      put_se_golomb(B, P.BetaOffsetDiv2);
      put_se_golomb(B, P.TcOffsetDiv2);
    end;
  end;
  put_bit(B, 0); // pps_scaling_list_data_present
  put_bit(B, 0); // lists_modification_present
  put_ue_golomb(B, 0); // log2_parallel_merge_level_minus2
  put_bit(B, 0); // slice_segment_header_extension_present
  // Cross-component prediction lives in the range extension. It predicts each
  // chroma residual from the reconstructed luma residual, which for a 4:4:4 RGB
  // picture -- where the planes are G, B, R -- is predicting two highly
  // correlated channels from the third.
  if P.CrossComponentPred <> 0 then
  begin
    put_bit(B, 1); // pps_extension_present_flag
    put_bit(B, 1); // pps_range_extension_flag
    put_bits(B, 7, 0); // the remaining extension flags
    if P.TransformSkipEnabled <> 0 then
      put_ue_golomb(B, 0); // log2_max_transform_skip_block_size_minus2
    put_bit(B, 1); // cross_component_prediction_enabled
    put_bit(B, 0); // chroma_qp_offset_list_enabled
    put_ue_golomb(B, 0); // log2_sao_offset_scale_luma
    put_ue_golomb(B, 0); // log2_sao_offset_scale_chroma
  end
  else
    put_bit(B, 0); // pps_extension_present
  put_rbsp_trailing_bits(B);
end;

end.
