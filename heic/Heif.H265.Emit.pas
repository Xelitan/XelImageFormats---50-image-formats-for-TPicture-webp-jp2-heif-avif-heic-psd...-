unit Heif.H265.Emit;

// Synthesizes standard HEVC parameter-set NAL units (VPS/SPS) and the HEIF
// hvcC configuration record from known encoder parameters.
//
// The BPG encoder emits a compact "modified SPS"; HEIC requires a standard SPS
// carried in hvcC. This unit writes a conformant standard SPS (and a minimal
// VPS) whose fields match the encoder's fixed configuration, so that both third-
// party HEIC readers and this project's own decoder can parse it.
//
// Reference: ISO/IEC 23008-2 (HEVC) 7.3.2; ISO/IEC 14496-15 (hvcC).

{$mode delphi}{$H+}

interface

uses
  SysUtils, Heif.Reader, Heif.Hevc;

type
  THevcParams = record
    ChromaFormatIdc: Integer;   // 0,1,2,3
    BitDepthLuma: Integer;
    BitDepthChroma: Integer;
    CodedWidth: Integer;        // multiple of min CB size
    CodedHeight: Integer;
    ConfWinRight: Integer;      // in chroma-subsampled units (left/top assumed 0)
    ConfWinBottom: Integer;
    Log2MinCbSize: Integer;     // 3
    Log2MaxCbSize: Integer;     // 5
    Log2MinTbSize: Integer;     // 2
    Log2MaxTbSize: Integer;     // 5
    MaxTransformHierarchyDepth: Integer; // 3
    AmpEnabled: Integer;        // 1
    SaoEnabled: Integer;
    StrongIntraSmoothing: Integer;
    ProfileIdc: Integer;        // derived
    LevelIdc: Integer;          // derived
    TierFlag: Integer;          // 0
  end;

// Derives ProfileIdc/LevelIdc/TierFlag from the picture characteristics.
procedure FillProfileLevel(var P: THevcParams);

// Full NAL units (2-byte header + emulation-encoded RBSP).
function EmitVpsNal: TBytes;
function EmitSpsNal(const P: THevcParams): TBytes;

// hvcC box PAYLOAD (after the 8-byte box header) wrapping the given NALs.
// APps is the standard PPS NAL (from the encoder).
function BuildHvcC(const AVps, ASps, APps: TBytes; const P: THevcParams): TBytes;

implementation

procedure FillProfileLevel(var P: THevcParams);
var
  Samples: Int64;
begin
  if (P.ChromaFormatIdc <= 1) and (P.BitDepthLuma = 8) then
    P.ProfileIdc := 1               // Main
  else if (P.ChromaFormatIdc <= 1) and (P.BitDepthLuma <= 10) then
    P.ProfileIdc := 2               // Main 10
  else
    P.ProfileIdc := 4;              // Range Extensions
  P.TierFlag := 0;
  Samples := Int64(P.CodedWidth) * P.CodedHeight;
  if Samples <= 2228224 then P.LevelIdc := 120        // 4.0
  else if Samples <= 8912896 then P.LevelIdc := 153   // 5.1
  else P.LevelIdc := 186;                              // 6.2
end;

procedure WriteProfileTierLevel(W: TBitWriter; AProfileIdc, ATier, ALevelIdc: Integer);
begin
  W.WriteBits(0, 2);                     // general_profile_space
  W.WriteBit(LongWord(ATier));           // general_tier_flag
  W.WriteBits(LongWord(AProfileIdc), 5); // general_profile_idc
  // general_profile_compatibility_flag[32]: set the bit for this profile.
  W.WriteBits(LongWord(1) shl (31 - AProfileIdc), 32);
  // 48 constraint flags: progressive=1, interlaced=0, non_packed=0,
  // frame_only=1, then 44 reserved zero bits.
  W.WriteBit(1); W.WriteBit(0); W.WriteBit(0); W.WriteBit(1);
  W.WriteBits(0, 32);
  W.WriteBits(0, 12);
  W.WriteBits(LongWord(ALevelIdc), 8);   // general_level_idc
end;

function WrapNal(ANalType: Integer; const ARbsp: TBytes): TBytes;
var
  Raw: TBytes;
  I: Integer;
begin
  // 2-byte NAL header + RBSP, then emulation-prevention encode the whole thing.
  SetLength(Raw, Length(ARbsp) + 2);
  Raw[0] := Byte((ANalType shl 1) and $7F);   // forbidden=0, type, layerid hi=0
  Raw[1] := 1;                                  // layerid lo=0, tid_plus1=1
  for I := 0 to High(ARbsp) do
    Raw[2 + I] := ARbsp[I];
  Result := AddEmulationPrevention(Raw);
end;

function EmitVpsNal: TBytes;
var
  W: TBitWriter;
  Rbsp: TBytes;
begin
  W := TBitWriter.Create;
  try
    W.WriteBits(0, 4);      // vps_video_parameter_set_id
    W.WriteBit(1);          // vps_base_layer_internal_flag
    W.WriteBit(1);          // vps_base_layer_available_flag
    W.WriteBits(0, 6);      // vps_max_layers_minus1
    W.WriteBits(0, 3);      // vps_max_sub_layers_minus1
    W.WriteBit(1);          // vps_temporal_id_nesting_flag
    W.WriteBits($FFFF, 16); // vps_reserved_0xffff_16bits
    WriteProfileTierLevel(W, 1, 0, 120);
    W.WriteBit(0);          // vps_sub_layer_ordering_info_present_flag
    W.WriteUE(0);           // vps_max_dec_pic_buffering_minus1[0]
    W.WriteUE(0);           // vps_max_num_reorder_pics[0]
    W.WriteUE(0);           // vps_max_latency_increase_plus1[0]
    W.WriteBits(0, 6);      // vps_max_layer_id
    W.WriteUE(0);           // vps_num_layer_sets_minus1
    W.WriteBit(0);          // vps_timing_info_present_flag
    W.WriteBit(0);          // vps_extension_flag
    W.WriteBit(1);          // rbsp_stop_one_bit
    Rbsp := W.ToBytes;      // ByteAlign in ToBytes pads with zeros
  finally
    W.Free;
  end;
  Result := WrapNal(NAL_VPS, Rbsp);
end;

function EmitSpsNal(const P: THevcParams): TBytes;
var
  W: TBitWriter;
  Rbsp: TBytes;
  ConfFlag: Boolean;
begin
  W := TBitWriter.Create;
  try
    W.WriteBits(0, 4);      // sps_video_parameter_set_id
    W.WriteBits(0, 3);      // sps_max_sub_layers_minus1
    W.WriteBit(1);          // sps_temporal_id_nesting_flag
    WriteProfileTierLevel(W, P.ProfileIdc, P.TierFlag, P.LevelIdc);
    W.WriteUE(0);           // sps_seq_parameter_set_id
    W.WriteUE(LongWord(P.ChromaFormatIdc));
    if P.ChromaFormatIdc = 3 then
      W.WriteBit(0);        // separate_colour_plane_flag
    W.WriteUE(LongWord(P.CodedWidth));
    W.WriteUE(LongWord(P.CodedHeight));
    ConfFlag := (P.ConfWinRight > 0) or (P.ConfWinBottom > 0);
    W.WriteBit(Ord(ConfFlag));
    if ConfFlag then
    begin
      W.WriteUE(0);                              // conf_win_left_offset
      W.WriteUE(LongWord(P.ConfWinRight));       // conf_win_right_offset
      W.WriteUE(0);                              // conf_win_top_offset
      W.WriteUE(LongWord(P.ConfWinBottom));      // conf_win_bottom_offset
    end;
    W.WriteUE(LongWord(P.BitDepthLuma - 8));
    W.WriteUE(LongWord(P.BitDepthChroma - 8));
    W.WriteUE(4);           // log2_max_pic_order_cnt_lsb_minus4 (=> lsb bits 8)
    W.WriteBit(1);          // sps_sub_layer_ordering_info_present_flag
    W.WriteUE(0);           // sps_max_dec_pic_buffering_minus1[0]
    W.WriteUE(0);           // sps_max_num_reorder_pics[0]
    W.WriteUE(0);           // sps_max_latency_increase_plus1[0]
    W.WriteUE(LongWord(P.Log2MinCbSize - 3));
    W.WriteUE(LongWord(P.Log2MaxCbSize - P.Log2MinCbSize));
    W.WriteUE(LongWord(P.Log2MinTbSize - 2));
    W.WriteUE(LongWord(P.Log2MaxTbSize - P.Log2MinTbSize));
    W.WriteUE(LongWord(P.MaxTransformHierarchyDepth)); // inter
    W.WriteUE(LongWord(P.MaxTransformHierarchyDepth)); // intra
    W.WriteBit(0);          // scaling_list_enabled_flag
    W.WriteBit(LongWord(P.AmpEnabled));
    W.WriteBit(LongWord(P.SaoEnabled));
    W.WriteBit(0);          // pcm_enabled_flag
    W.WriteUE(0);           // num_short_term_ref_pic_sets
    W.WriteBit(0);          // long_term_ref_pics_present_flag
    W.WriteBit(1);          // sps_temporal_mvp_enabled_flag
    W.WriteBit(LongWord(P.StrongIntraSmoothing));
    W.WriteBit(0);          // vui_parameters_present_flag
    W.WriteBit(0);          // sps_extension_present_flag
    W.WriteBit(1);          // rbsp_stop_one_bit
    Rbsp := W.ToBytes;
  finally
    W.Free;
  end;
  Result := WrapNal(NAL_SPS, Rbsp);
end;

procedure PutU16(var B: TBytes; var O: Integer; V: Word);
begin
  B[O] := (V shr 8) and $FF; B[O+1] := V and $FF; Inc(O, 2);
end;

function BuildHvcC(const AVps, ASps, APps: TBytes; const P: THevcParams): TBytes;
var
  Buf: TBytes;
  O: Integer;

  procedure PutByte(V: Byte);
  begin
    Buf[O] := V; Inc(O);
  end;

  procedure PutArray(ANalType: Integer; const ANal: TBytes);
  begin
    PutByte(Byte($80 or ANalType)); // array_completeness=1, reserved=0, NAL type
    PutU16(Buf, O, 1);              // numNalus = 1
    PutU16(Buf, O, Word(Length(ANal)));
    if Length(ANal) > 0 then
    begin
      Move(ANal[0], Buf[O], Length(ANal));
      Inc(O, Length(ANal));
    end;
  end;
begin
  SetLength(Buf, 23 + 3 * (1 + 2 + 2) + Length(AVps) + Length(ASps) + Length(APps));
  O := 0;
  PutByte(1);                        // configurationVersion
  // general_profile_space(2)=0 / tier(1) / profile_idc(5)
  PutByte(Byte(((0 and 3) shl 6) or ((P.TierFlag and 1) shl 5) or (P.ProfileIdc and $1F)));
  // general_profile_compatibility_flags (32)
  PutByte((LongWord(1) shl (31 - P.ProfileIdc)) shr 24 and $FF);
  PutByte((LongWord(1) shl (31 - P.ProfileIdc)) shr 16 and $FF);
  PutByte((LongWord(1) shl (31 - P.ProfileIdc)) shr 8 and $FF);
  PutByte((LongWord(1) shl (31 - P.ProfileIdc)) and $FF);
  // general_constraint_indicator_flags (48): progressive + frame_only, rest 0
  PutByte($90); PutByte(0); PutByte(0); PutByte(0); PutByte(0); PutByte(0);
  PutByte(Byte(P.LevelIdc));         // general_level_idc
  PutByte($F0); PutByte(0);          // min_spatial_segmentation_idc (0) | 0xF000
  PutByte($FC);                      // parallelismType (0) | 0xFC
  PutByte(Byte($FC or (P.ChromaFormatIdc and 3)));       // chromaFormat
  PutByte(Byte($F8 or ((P.BitDepthLuma - 8) and 7)));    // bitDepthLumaMinus8
  PutByte(Byte($F8 or ((P.BitDepthChroma - 8) and 7)));  // bitDepthChromaMinus8
  PutU16(Buf, O, 0);                 // avgFrameRate
  // constantFrameRate(2)=0 numTemporalLayers(3)=1 temporalIdNested(1)=1 lengthSizeMinusOne(2)=3
  PutByte(Byte((1 shl 3) or (1 shl 2) or 3));
  PutByte(3);                        // numOfArrays (VPS, SPS, PPS)
  PutArray(NAL_VPS, AVps);
  PutArray(NAL_SPS, ASps);
  PutArray(NAL_PPS, APps);
  SetLength(Buf, O);
  Result := Buf;
end;

end.
