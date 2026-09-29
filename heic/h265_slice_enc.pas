// BPG encoder -- Free Pascal
// Slice segment header writer. The inverse of h265_hevc.hls_slice_header for the
// subset a BPG still picture uses: one IDR I-slice per picture, no tiles, no
// wavefronts, no reference lists.
unit h265_slice_enc;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}

interface

uses
  h265_common, h265_putbits, h265_ps_enc;

type
  TEncSliceHdr = record
    SliceQpDelta: Integer; // slice_qp = 26 + init_qp_minus26 + this
    SaoLuma: Integer;
    SaoChroma: Integer;
    LoopFilterAcrossSlices: Integer;
  end;

// Emits the slice segment header including the trailing byte alignment, so the
// CABAC data starts at the next byte.
procedure write_slice_header(var Out_: TByteBuf; const S: TEncSps;
  const P: TEncPps; const H: TEncSliceHdr);

implementation

procedure write_slice_header(var Out_: TByteBuf; const S: TEncSps;
  const P: TEncPps; const H: TEncSliceHdr);
var
  B: TPutBitContext;
  SaoL, SaoC: Integer;
begin
  if S.SaoEnabled <> 0 then
  begin
    SaoL := H.SaoLuma;
    if S.ChromaFormatIdc <> 0 then SaoC := H.SaoChroma else SaoC := 0;
  end
  else
  begin
    SaoL := 0;
    SaoC := 0;
  end;

  put_bits_init(B, @Out_);
  put_bit(B, 1); // first_slice_segment_in_pic_flag
  put_bit(B, 0); // no_output_of_prior_pics_flag (IRAP)
  put_ue_golomb(B, 0); // slice_pic_parameter_set_id
  // dependent_slice_segment_flag and slice_segment_address are absent because
  // this is the first slice segment of the picture
  put_ue_golomb(B, 2); // slice_type = I_SLICE

  // output_flag_present_flag and separate_colour_plane_flag are both 0 in the
  // parameter sets this encoder writes, so neither field is present. The NAL is
  // an IDR, so there is no picture order count or reference picture set.

  if S.SaoEnabled <> 0 then
  begin
    put_bit(B, SaoL);
    if S.ChromaFormatIdc <> 0 then
      put_bit(B, SaoC);
  end;

  put_se_golomb(B, H.SliceQpDelta);

  // pps_slice_chroma_qp_offsets_present_flag and
  // chroma_qp_offset_list_enabled_flag are 0, so no per-slice chroma offsets

  if P.DeblockingControlPresent <> 0 then
  begin
    // deblocking_filter_override_enabled_flag is 0 in our PPS, so no override
    // flag is present and the slice inherits the PPS deblocking parameters
  end;

  if (P.LoopFilterAcrossSlices <> 0) and
     ((SaoL <> 0) or (SaoC <> 0) or (P.DeblockingDisabled = 0)) then
    put_bit(B, H.LoopFilterAcrossSlices);

  // no tiles and no entropy_coding_sync, so no entry point offsets;
  // slice_segment_header_extension_present_flag is 0

  // byte_alignment(): a one bit followed by zeros. The decoder consumes the one
  // bit in cabac_init_decoder before aligning.
  put_rbsp_trailing_bits(B);
end;

end.
