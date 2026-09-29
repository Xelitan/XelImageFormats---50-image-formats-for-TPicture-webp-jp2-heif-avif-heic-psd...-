unit Heif.H265.Params;

// Full HEVC (H.265) parameter-set and slice-header parsing for still-image
// (intra) decoding.
//
// Parses SPS, PPS and the slice segment header into records the reconstruction
// engine consumes. Reference picture / inter-prediction syntax is parsed enough
// to keep bit alignment, but the still-image path only exercises I slices.
//
// Reference: ISO/IEC 23008-2 (HEVC) section 7.3.

{$mode delphi}{$H+}

interface

uses
  SysUtils, Heif.Reader, Heif.Hevc;

type
  EH265 = class(Exception);

  // Scaling list data: 4 sizeId (0..3), each with a number of matrices.
  // sizeId 0 -> 6 lists of 16 coeffs; sizeId 1,2 -> 6 lists of 64;
  // sizeId 3 -> 2 lists of 64. Plus DC coeff for sizeId 2,3.
  TScalingList = record
    Present: Boolean;
    // [sizeId][matrixId][coefIndex]
    List0: array[0..5, 0..15] of Byte;                 // sizeId 0
    List1: array[0..5, 0..63] of Byte;                 // sizeId 1
    List2: array[0..5, 0..63] of Byte;                 // sizeId 2
    List3: array[0..1, 0..63] of Byte;                 // sizeId 3
    DC2: array[0..5] of Byte;                          // sizeId 2 DC
    DC3: array[0..1] of Byte;                          // sizeId 3 DC
  end;

  TShortTermRPS = record
    NumNegative: Integer;
    NumPositive: Integer;
    DeltaPoc: array[0..15] of Integer;   // combined list
    UsedByCurr: array[0..15] of Boolean;
    NumDeltaPocs: Integer;
  end;

  TSps = record
    SpsId: Integer;
    ChromaFormatIdc: Integer;
    SeparateColourPlane: Boolean;
    PicWidthInLumaSamples: Integer;
    PicHeightInLumaSamples: Integer;
    ConfWinLeft, ConfWinRight, ConfWinTop, ConfWinBottom: Integer;
    BitDepthLuma: Integer;
    BitDepthChroma: Integer;
    Log2MaxPicOrderCntLsb: Integer;
    Log2MinLumaCbSize: Integer;        // log2 of min coding block size
    Log2CtbSize: Integer;              // log2 of CTB size
    Log2MinTransformBlockSize: Integer;
    Log2MaxTransformBlockSize: Integer;
    MaxTransformHierarchyDepthInter: Integer;
    MaxTransformHierarchyDepthIntra: Integer;
    ScalingListEnabled: Boolean;
    ScalingList: TScalingList;
    // sps_scaling_list_data_present_flag, and the bit offset (in the RBSP,
    // from the NAL header) where scaling_list_data() starts
    ScalingListDataPresent: Boolean;
    ScalingListBitPos: Integer;
    AmpEnabled: Boolean;
    SaoEnabled: Boolean;
    PcmEnabled: Boolean;
    PcmBitDepthLuma: Integer;
    PcmBitDepthChroma: Integer;
    Log2MinPcmCbSize: Integer;
    Log2MaxPcmCbSize: Integer;
    PcmLoopFilterDisabled: Boolean;
    NumShortTermRPS: Integer;
    ShortTermRPS: array of TShortTermRPS;
    LongTermRefPicsPresent: Boolean;
    TemporalMvpEnabled: Boolean;
    StrongIntraSmoothing: Boolean;
    // Colour signalling from the VUI (when present).
    VuiColourPresent: Boolean;
    VuiPrimaries: Integer;
    VuiTransfer: Integer;
    VuiMatrix: Integer;
    VuiFullRange: Boolean;
    // Derived:
    CtbSize: Integer;                  // 1 shl Log2CtbSize
    MinCbSize: Integer;
    PicWidthInCtbs: Integer;
    PicHeightInCtbs: Integer;
    PicWidthInMinCbs: Integer;
    PicHeightInMinCbs: Integer;
    PicSizeInCtbs: Integer;
    SubWidthC, SubHeightC: Integer;
  end;

  TPps = record
    PpsId: Integer;
    SpsId: Integer;
    DependentSliceSegmentsEnabled: Boolean;
    OutputFlagPresent: Boolean;
    NumExtraSliceHeaderBits: Integer;
    SignDataHiding: Boolean;
    CabacInitPresent: Boolean;
    NumRefIdxL0DefaultActive: Integer;
    NumRefIdxL1DefaultActive: Integer;
    InitQp: Integer;                  // 26 + pic_init_qp_minus26
    ConstrainedIntraPred: Boolean;
    TransformSkipEnabled: Boolean;
    CuQpDeltaEnabled: Boolean;
    DiffCuQpDeltaDepth: Integer;
    CbQpOffset: Integer;
    CrQpOffset: Integer;
    SliceChromaQpOffsetsPresent: Boolean;
    WeightedPred: Boolean;
    WeightedBipred: Boolean;
    TransquantBypassEnabled: Boolean;
    TilesEnabled: Boolean;
    EntropyCodingSyncEnabled: Boolean;
    NumTileColumns: Integer;
    NumTileRows: Integer;
    UniformSpacing: Boolean;
    ColWidth: array of Integer;        // in CTBs
    RowHeight: array of Integer;
    LoopFilterAcrossTiles: Boolean;
    LoopFilterAcrossSlices: Boolean;
    DeblockingFilterControlPresent: Boolean;
    DeblockingFilterOverrideEnabled: Boolean;
    DeblockingFilterDisabled: Boolean;
    BetaOffsetDiv2: Integer;
    TcOffsetDiv2: Integer;
    ScalingListDataPresent: Boolean;
    ScalingList: TScalingList;
    ListsModificationPresent: Boolean;
    Log2ParallelMergeLevel: Integer;
    SliceSegmentHeaderExtensionPresent: Boolean;
  end;

  TSliceHeader = record
    FirstSliceInPic: Boolean;
    NoOutputOfPriorPics: Boolean;
    PpsId: Integer;
    DependentSlice: Boolean;
    SliceSegmentAddress: Integer;
    SliceType: Integer;               // 0=B,1=P,2=I
    PicOutputFlag: Boolean;
    ColourPlaneId: Integer;
    SaoLuma: Boolean;
    SaoChroma: Boolean;
    SliceQpDelta: Integer;
    SliceQp: Integer;                 // derived: 26 + init_qp_minus26 + slice_qp_delta
    CbQpOffset: Integer;
    CrQpOffset: Integer;
    DeblockingFilterDisabled: Boolean;
    BetaOffsetDiv2: Integer;
    TcOffsetDiv2: Integer;
    LoopFilterAcrossSlices: Boolean;
    CabacInitFlag: Boolean;
    NumEntryPointOffsets: Integer;
    // byte offset where slice data (CABAC) begins, from start of NAL RBSP
    DataByteOffset: Integer;
  end;

const
  SLICE_B = 0;
  SLICE_P = 1;
  SLICE_I = 2;

procedure ParseSps(const ANalRbsp: TBytes; out ASps: TSps);
procedure ParsePps(const ANalRbsp: TBytes; out APps: TPps);
// Parses the slice segment header. Requires the SPS and PPS it refers to.
// ANalUnit is the full slice NAL (with header + emulation bytes); this routine
// strips emulation and records where CABAC data starts.
procedure ParseSliceHeader(const ANalUnit: TBytes; const ASps: TSps;
  const APps: TPps; ANalType: Integer; out ASh: TSliceHeader);

implementation

procedure SkipProfileTierLevel(BR: TBitReader; AMaxSubLayersMinus1: Integer);
var
  I: Integer;
  ProfilePresent, LevelPresent: array[0..7] of Boolean;
begin
  BR.ReadBits(2 + 1 + 5);   // general profile_space/tier/idc
  BR.ReadBits(32);          // compat flags
  BR.ReadBits(32);          // constraint flags high
  BR.ReadBits(16);          // constraint flags low
  BR.ReadBits(8);           // general_level_idc
  for I := 0 to AMaxSubLayersMinus1 - 1 do
  begin
    ProfilePresent[I] := BR.ReadBit = 1;
    LevelPresent[I] := BR.ReadBit = 1;
  end;
  if AMaxSubLayersMinus1 > 0 then
    for I := AMaxSubLayersMinus1 to 7 do
      BR.ReadBits(2);
  for I := 0 to AMaxSubLayersMinus1 - 1 do
  begin
    if ProfilePresent[I] then
    begin
      BR.ReadBits(2 + 1 + 5);
      BR.ReadBits(32);
      BR.ReadBits(32);
      BR.ReadBits(16);
    end;
    if LevelPresent[I] then
      BR.ReadBits(8);
  end;
end;

// helper: for sizeId==3, the pred_matrix_id_delta is multiplied by 3.
function IfInc(ASizeId: Integer): Integer;
begin
  if ASizeId = 3 then Result := 3 else Result := 1;
end;

procedure ParseScalingListData(BR: TBitReader; var ASL: TScalingList);
var
  SizeId, MatrixId, CoefNum, I: Integer;
  PredModeFlag: Boolean;
  DeltaCoef, NextCoef, ScalingListDcCoefMinus8: Integer;
  RefMatrixId: Integer;
begin
  ASL.Present := True;
  for SizeId := 0 to 3 do
  begin
    MatrixId := 0;
    while MatrixId < 6 do
    begin
      PredModeFlag := BR.ReadBit = 1; // scaling_list_pred_mode_flag
      if not PredModeFlag then
      begin
        // scaling_list_pred_matrix_id_delta
        RefMatrixId := MatrixId - BR.ReadUE * IfInc(SizeId);
        // Copy from reference matrix (or default if delta==0). For simplicity
        // we do not fully reconstruct copied lists here; still-image streams
        // that use custom scaling lists are rare. We keep bit alignment only.
      end
      else
      begin
        NextCoef := 8;
        if SizeId > 1 then
        begin
          ScalingListDcCoefMinus8 := BR.ReadSE;
          NextCoef := ScalingListDcCoefMinus8 + 8;
          if SizeId = 2 then ASL.DC2[MatrixId] := Byte(NextCoef)
          else if SizeId = 3 then ASL.DC3[MatrixId div 3] := Byte(NextCoef);
        end;
        if SizeId = 0 then CoefNum := 16 else CoefNum := 64;
        for I := 0 to CoefNum - 1 do
        begin
          DeltaCoef := BR.ReadSE;
          NextCoef := (NextCoef + DeltaCoef + 256) mod 256;
          case SizeId of
            0: ASL.List0[MatrixId, I] := Byte(NextCoef);
            1: ASL.List1[MatrixId, I] := Byte(NextCoef);
            2: ASL.List2[MatrixId, I] := Byte(NextCoef);
            3: ASL.List3[MatrixId div 3, I] := Byte(NextCoef);
          end;
        end;
      end;
      if SizeId = 3 then
        Inc(MatrixId, 3)
      else
        Inc(MatrixId);
    end;
  end;
end;

procedure ParseShortTermRPS(BR: TBitReader; var ARPS: array of TShortTermRPS;
  AIdx: Integer; ANumRPS: Integer);
var
  RPS: ^TShortTermRPS;
  InterRpsPred: Boolean;
  I, J, K: Integer;
  DeltaIdxMinus1, DeltaRpsSign, AbsDeltaRpsMinus1, DeltaRps: Integer;
  RefRPS: ^TShortTermRPS;
  UsedByCurrPicFlag, UseDeltaFlag: Boolean;
  DPoc: Integer;
begin
  RPS := @ARPS[AIdx];
  FillChar(RPS^, SizeOf(TShortTermRPS), 0);
  InterRpsPred := False;
  if AIdx <> 0 then
    InterRpsPred := BR.ReadBit = 1;

  if InterRpsPred then
  begin
    DeltaIdxMinus1 := 0;
    if AIdx = ANumRPS then
      DeltaIdxMinus1 := BR.ReadUE;
    DeltaRpsSign := BR.ReadBit;
    AbsDeltaRpsMinus1 := BR.ReadUE;
    DeltaRps := (1 - 2 * DeltaRpsSign) * (AbsDeltaRpsMinus1 + 1);
    RefRPS := @ARPS[AIdx - 1 - DeltaIdxMinus1];
    K := 0;
    for J := 0 to RefRPS^.NumDeltaPocs do
    begin
      UsedByCurrPicFlag := BR.ReadBit = 1;
      UseDeltaFlag := True;
      if not UsedByCurrPicFlag then
        UseDeltaFlag := BR.ReadBit = 1;
      if UsedByCurrPicFlag or UseDeltaFlag then
      begin
        if J < RefRPS^.NumDeltaPocs then
          DPoc := RefRPS^.DeltaPoc[J] + DeltaRps
        else
          DPoc := DeltaRps;
        if K < 16 then
        begin
          RPS^.DeltaPoc[K] := DPoc;
          RPS^.UsedByCurr[K] := UsedByCurrPicFlag;
          Inc(K);
        end;
      end;
    end;
    RPS^.NumDeltaPocs := K;
    RPS^.NumNegative := K; // approximate; not needed for intra
  end
  else
  begin
    RPS^.NumNegative := BR.ReadUE;
    RPS^.NumPositive := BR.ReadUE;
    DPoc := 0;
    for I := 0 to RPS^.NumNegative - 1 do
    begin
      DPoc := DPoc - (BR.ReadUE + 1); // delta_poc_s0_minus1
      if I < 16 then RPS^.DeltaPoc[I] := DPoc;
      RPS^.UsedByCurr[I] := BR.ReadBit = 1;
    end;
    DPoc := 0;
    for I := 0 to RPS^.NumPositive - 1 do
    begin
      DPoc := DPoc + (BR.ReadUE + 1); // delta_poc_s1_minus1
      J := RPS^.NumNegative + I;
      if J < 16 then RPS^.DeltaPoc[J] := DPoc;
      if J < 16 then RPS^.UsedByCurr[J] := BR.ReadBit = 1;
    end;
    RPS^.NumDeltaPocs := RPS^.NumNegative + RPS^.NumPositive;
  end;
end;

procedure ParseSps(const ANalRbsp: TBytes; out ASps: TSps);
var
  BR: TBitReader;
  MaxSubLayersMinus1: Integer;
  SubLayerOrderingPresent: Boolean;
  I: Integer;
  PcmSampleBitDepthLumaMinus1, PcmSampleBitDepthChromaMinus1: Integer;
  Rbsp: TBytes;
begin
  FillChar(ASps, SizeOf(ASps), 0);
  Rbsp := RemoveEmulationPrevention(ANalRbsp);
  BR := TBitReader.Create(@Rbsp[0], Length(Rbsp));
  try
    BR.ReadBits(16); // NAL header
    BR.ReadBits(4);  // sps_video_parameter_set_id
    MaxSubLayersMinus1 := BR.ReadBits(3);
    BR.ReadBit;      // sps_temporal_id_nesting_flag
    SkipProfileTierLevel(BR, MaxSubLayersMinus1);

    ASps.SpsId := BR.ReadUE;
    ASps.ChromaFormatIdc := BR.ReadUE;
    if ASps.ChromaFormatIdc = 3 then
      ASps.SeparateColourPlane := BR.ReadBit = 1;
    ASps.PicWidthInLumaSamples := BR.ReadUE;
    ASps.PicHeightInLumaSamples := BR.ReadUE;
    if BR.ReadBit = 1 then // conformance_window_flag
    begin
      ASps.ConfWinLeft := BR.ReadUE;
      ASps.ConfWinRight := BR.ReadUE;
      ASps.ConfWinTop := BR.ReadUE;
      ASps.ConfWinBottom := BR.ReadUE;
    end;
    ASps.BitDepthLuma := BR.ReadUE + 8;
    ASps.BitDepthChroma := BR.ReadUE + 8;
    ASps.Log2MaxPicOrderCntLsb := BR.ReadUE + 4;

    SubLayerOrderingPresent := BR.ReadBit = 1;
    if SubLayerOrderingPresent then I := 0 else I := MaxSubLayersMinus1;
    while I <= MaxSubLayersMinus1 do
    begin
      BR.ReadUE; // sps_max_dec_pic_buffering_minus1
      BR.ReadUE; // sps_max_num_reorder_pics
      BR.ReadUE; // sps_max_latency_increase_plus1
      Inc(I);
    end;

    ASps.Log2MinLumaCbSize := BR.ReadUE + 3;
    ASps.Log2CtbSize := ASps.Log2MinLumaCbSize + BR.ReadUE;
    ASps.Log2MinTransformBlockSize := BR.ReadUE + 2;
    ASps.Log2MaxTransformBlockSize := ASps.Log2MinTransformBlockSize + BR.ReadUE;
    ASps.MaxTransformHierarchyDepthInter := BR.ReadUE;
    ASps.MaxTransformHierarchyDepthIntra := BR.ReadUE;

    ASps.ScalingListEnabled := BR.ReadBit = 1;
    if ASps.ScalingListEnabled then
      if BR.ReadBit = 1 then // sps_scaling_list_data_present_flag
      begin
        ASps.ScalingListDataPresent := True;
        ASps.ScalingListBitPos := Integer(BR.BitsRead);
        ParseScalingListData(BR, ASps.ScalingList);
      end;

    ASps.AmpEnabled := BR.ReadBit = 1;
    ASps.SaoEnabled := BR.ReadBit = 1;
    ASps.PcmEnabled := BR.ReadBit = 1;
    if ASps.PcmEnabled then
    begin
      PcmSampleBitDepthLumaMinus1 := BR.ReadBits(4);
      PcmSampleBitDepthChromaMinus1 := BR.ReadBits(4);
      ASps.PcmBitDepthLuma := PcmSampleBitDepthLumaMinus1 + 1;
      ASps.PcmBitDepthChroma := PcmSampleBitDepthChromaMinus1 + 1;
      ASps.Log2MinPcmCbSize := BR.ReadUE + 3;
      ASps.Log2MaxPcmCbSize := ASps.Log2MinPcmCbSize + BR.ReadUE;
      ASps.PcmLoopFilterDisabled := BR.ReadBit = 1;
    end;

    ASps.NumShortTermRPS := BR.ReadUE;
    if ASps.NumShortTermRPS > 0 then
    begin
      SetLength(ASps.ShortTermRPS, ASps.NumShortTermRPS);
      for I := 0 to ASps.NumShortTermRPS - 1 do
        ParseShortTermRPS(BR, ASps.ShortTermRPS, I, ASps.NumShortTermRPS);
    end;

    ASps.LongTermRefPicsPresent := BR.ReadBit = 1;
    if ASps.LongTermRefPicsPresent then
    begin
      I := BR.ReadUE; // num_long_term_ref_pics_sps
      while I > 0 do
      begin
        BR.ReadBits(ASps.Log2MaxPicOrderCntLsb); // lt_ref_pic_poc_lsb_sps
        BR.ReadBit;                              // used_by_curr_pic_lt_sps_flag
        Dec(I);
      end;
    end;

    ASps.TemporalMvpEnabled := BR.ReadBit = 1;
    ASps.StrongIntraSmoothing := BR.ReadBit = 1;

    // vui_parameters(): parse only the colour-description fields, then stop.
    if BR.ReadBit = 1 then // vui_parameters_present_flag
    begin
      if BR.ReadBit = 1 then // aspect_ratio_info_present_flag
        if BR.ReadBits(8) = 255 then // aspect_ratio_idc == EXTENDED_SAR
        begin
          BR.ReadBits(16); BR.ReadBits(16); // sar_width, sar_height
        end;
      if BR.ReadBit = 1 then // overscan_info_present_flag
        BR.ReadBit;          // overscan_appropriate_flag
      if BR.ReadBit = 1 then // video_signal_type_present_flag
      begin
        BR.ReadBits(3);      // video_format
        ASps.VuiFullRange := BR.ReadBit = 1;
        if BR.ReadBit = 1 then // colour_description_present_flag
        begin
          ASps.VuiPrimaries := BR.ReadBits(8);
          ASps.VuiTransfer := BR.ReadBits(8);
          ASps.VuiMatrix := BR.ReadBits(8);
          ASps.VuiColourPresent := True;
        end;
      end;
      // remaining VUI fields not needed for reconstruction.
    end;

    // Derived values.
    if ASps.ChromaFormatIdc = 1 then begin ASps.SubWidthC := 2; ASps.SubHeightC := 2; end
    else if ASps.ChromaFormatIdc = 2 then begin ASps.SubWidthC := 2; ASps.SubHeightC := 1; end
    else begin ASps.SubWidthC := 1; ASps.SubHeightC := 1; end;
    ASps.CtbSize := 1 shl ASps.Log2CtbSize;
    ASps.MinCbSize := 1 shl ASps.Log2MinLumaCbSize;
    ASps.PicWidthInCtbs := (ASps.PicWidthInLumaSamples + ASps.CtbSize - 1) div ASps.CtbSize;
    ASps.PicHeightInCtbs := (ASps.PicHeightInLumaSamples + ASps.CtbSize - 1) div ASps.CtbSize;
    ASps.PicWidthInMinCbs := ASps.PicWidthInLumaSamples div ASps.MinCbSize;
    ASps.PicHeightInMinCbs := ASps.PicHeightInLumaSamples div ASps.MinCbSize;
    ASps.PicSizeInCtbs := ASps.PicWidthInCtbs * ASps.PicHeightInCtbs;
  finally
    BR.Free;
  end;
end;

procedure ParsePps(const ANalRbsp: TBytes; out APps: TPps);
var
  BR: TBitReader;
  Rbsp: TBytes;
  I: Integer;
begin
  FillChar(APps, SizeOf(APps), 0);
  Rbsp := RemoveEmulationPrevention(ANalRbsp);
  BR := TBitReader.Create(@Rbsp[0], Length(Rbsp));
  try
    BR.ReadBits(16); // NAL header
    APps.PpsId := BR.ReadUE;
    APps.SpsId := BR.ReadUE;
    APps.DependentSliceSegmentsEnabled := BR.ReadBit = 1;
    APps.OutputFlagPresent := BR.ReadBit = 1;
    APps.NumExtraSliceHeaderBits := BR.ReadBits(3);
    APps.SignDataHiding := BR.ReadBit = 1;
    APps.CabacInitPresent := BR.ReadBit = 1;
    APps.NumRefIdxL0DefaultActive := BR.ReadUE + 1;
    APps.NumRefIdxL1DefaultActive := BR.ReadUE + 1;
    APps.InitQp := 26 + BR.ReadSE;
    APps.ConstrainedIntraPred := BR.ReadBit = 1;
    APps.TransformSkipEnabled := BR.ReadBit = 1;
    APps.CuQpDeltaEnabled := BR.ReadBit = 1;
    if APps.CuQpDeltaEnabled then
      APps.DiffCuQpDeltaDepth := BR.ReadUE;
    APps.CbQpOffset := BR.ReadSE;
    APps.CrQpOffset := BR.ReadSE;
    APps.SliceChromaQpOffsetsPresent := BR.ReadBit = 1;
    APps.WeightedPred := BR.ReadBit = 1;
    APps.WeightedBipred := BR.ReadBit = 1;
    APps.TransquantBypassEnabled := BR.ReadBit = 1;
    APps.TilesEnabled := BR.ReadBit = 1;
    APps.EntropyCodingSyncEnabled := BR.ReadBit = 1;
    if APps.TilesEnabled then
    begin
      APps.NumTileColumns := BR.ReadUE + 1;
      APps.NumTileRows := BR.ReadUE + 1;
      APps.UniformSpacing := BR.ReadBit = 1;
      if not APps.UniformSpacing then
      begin
        SetLength(APps.ColWidth, APps.NumTileColumns);
        for I := 0 to APps.NumTileColumns - 2 do
          APps.ColWidth[I] := BR.ReadUE + 1;
        SetLength(APps.RowHeight, APps.NumTileRows);
        for I := 0 to APps.NumTileRows - 2 do
          APps.RowHeight[I] := BR.ReadUE + 1;
      end;
      APps.LoopFilterAcrossTiles := BR.ReadBit = 1;
    end
    else
    begin
      APps.NumTileColumns := 1;
      APps.NumTileRows := 1;
      APps.LoopFilterAcrossTiles := True;
    end;
    APps.LoopFilterAcrossSlices := BR.ReadBit = 1;
    APps.DeblockingFilterControlPresent := BR.ReadBit = 1;
    if APps.DeblockingFilterControlPresent then
    begin
      APps.DeblockingFilterOverrideEnabled := BR.ReadBit = 1;
      APps.DeblockingFilterDisabled := BR.ReadBit = 1;
      if not APps.DeblockingFilterDisabled then
      begin
        APps.BetaOffsetDiv2 := BR.ReadSE;
        APps.TcOffsetDiv2 := BR.ReadSE;
      end;
    end;
    APps.ScalingListDataPresent := BR.ReadBit = 1;
    if APps.ScalingListDataPresent then
      ParseScalingListData(BR, APps.ScalingList);
    APps.ListsModificationPresent := BR.ReadBit = 1;
    APps.Log2ParallelMergeLevel := BR.ReadUE + 2;
    APps.SliceSegmentHeaderExtensionPresent := BR.ReadBit = 1;
    // pps_extension flags ignored.
  finally
    BR.Free;
  end;
end;

function CeilLog2(X: Integer): Integer;
var
  V: Integer;
begin
  Result := 0;
  V := 1;
  while V < X do
  begin
    V := V shl 1;
    Inc(Result);
  end;
end;

procedure ParseSliceHeader(const ANalUnit: TBytes; const ASps: TSps;
  const APps: TPps; ANalType: Integer; out ASh: TSliceHeader);
var
  BR: TBitReader;
  Rbsp: TBytes;
  I: Integer;
  IdrPic: Boolean;
  SliceAddrBits: Integer;
  NumEntryPointOffsets, OffsetLenMinus1: Integer;
begin
  FillChar(ASh, SizeOf(ASh), 0);
  Rbsp := RemoveEmulationPrevention(ANalUnit);
  BR := TBitReader.Create(@Rbsp[0], Length(Rbsp));
  try
    BR.ReadBits(16); // NAL header
    ASh.FirstSliceInPic := BR.ReadBit = 1;
    IdrPic := (ANalType >= NAL_BLA_W_LP) and (ANalType <= 23);
    if IdrPic then
      ASh.NoOutputOfPriorPics := BR.ReadBit = 1;
    ASh.PpsId := BR.ReadUE;

    if not ASh.FirstSliceInPic then
    begin
      if APps.DependentSliceSegmentsEnabled then
        ASh.DependentSlice := BR.ReadBit = 1;
      SliceAddrBits := CeilLog2(ASps.PicSizeInCtbs);
      ASh.SliceSegmentAddress := BR.ReadBits(SliceAddrBits);
    end;

    if not ASh.DependentSlice then
    begin
      for I := 0 to APps.NumExtraSliceHeaderBits - 1 do
        BR.ReadBit;
      ASh.SliceType := BR.ReadUE;
      if APps.OutputFlagPresent then
        ASh.PicOutputFlag := BR.ReadBit = 1
      else
        ASh.PicOutputFlag := True;
      if ASps.SeparateColourPlane then
        ASh.ColourPlaneId := BR.ReadBits(2);

      if not IdrPic then
      begin
        // Reference-picture syntax. For intra still images this is absent in
        // practice, but parse it to stay aligned if present.
        BR.ReadBits(ASps.Log2MaxPicOrderCntLsb); // slice_pic_order_cnt_lsb
        if BR.ReadBit = 0 then // short_term_ref_pic_set_sps_flag == 0
        begin
          // st_ref_pic_set(num_short_term_ref_pic_sets) inline -- rare; skip
          // safely is not possible, so raise if encountered.
          raise EH265.Create('Inline st_ref_pic_set in non-IDR slice not supported');
        end
        else if ASps.NumShortTermRPS > 1 then
          BR.ReadBits(CeilLog2(ASps.NumShortTermRPS));
        // long-term and TMVP omitted (intra path)
      end;

      if ASps.SaoEnabled then
      begin
        ASh.SaoLuma := BR.ReadBit = 1;
        if ASps.ChromaFormatIdc <> 0 then
          ASh.SaoChroma := BR.ReadBit = 1;
      end;

      // slice_type I => no ref idx / pred weight / merge syntax.
      ASh.SliceQpDelta := BR.ReadSE;
      ASh.SliceQp := APps.InitQp + ASh.SliceQpDelta;
      if APps.SliceChromaQpOffsetsPresent then
      begin
        ASh.CbQpOffset := BR.ReadSE;
        ASh.CrQpOffset := BR.ReadSE;
      end;

      if APps.DeblockingFilterControlPresent then
      begin
        if APps.DeblockingFilterOverrideEnabled then
        begin
          if BR.ReadBit = 1 then // deblocking_filter_override_flag
          begin
            ASh.DeblockingFilterDisabled := BR.ReadBit = 1;
            if not ASh.DeblockingFilterDisabled then
            begin
              ASh.BetaOffsetDiv2 := BR.ReadSE;
              ASh.TcOffsetDiv2 := BR.ReadSE;
            end;
          end
          else
          begin
            ASh.DeblockingFilterDisabled := APps.DeblockingFilterDisabled;
            ASh.BetaOffsetDiv2 := APps.BetaOffsetDiv2;
            ASh.TcOffsetDiv2 := APps.TcOffsetDiv2;
          end;
        end
        else
        begin
          ASh.DeblockingFilterDisabled := APps.DeblockingFilterDisabled;
          ASh.BetaOffsetDiv2 := APps.BetaOffsetDiv2;
          ASh.TcOffsetDiv2 := APps.TcOffsetDiv2;
        end;
      end
      else
      begin
        ASh.BetaOffsetDiv2 := APps.BetaOffsetDiv2;
        ASh.TcOffsetDiv2 := APps.TcOffsetDiv2;
      end;

      ASh.LoopFilterAcrossSlices := APps.LoopFilterAcrossSlices;
      if APps.LoopFilterAcrossSlices and
         (ASh.SaoLuma or ASh.SaoChroma or (not ASh.DeblockingFilterDisabled)) then
        ASh.LoopFilterAcrossSlices := BR.ReadBit = 1;
    end;

    if APps.TilesEnabled or APps.EntropyCodingSyncEnabled then
    begin
      NumEntryPointOffsets := BR.ReadUE;
      ASh.NumEntryPointOffsets := NumEntryPointOffsets;
      if NumEntryPointOffsets > 0 then
      begin
        OffsetLenMinus1 := BR.ReadUE;
        for I := 0 to NumEntryPointOffsets - 1 do
          BR.ReadBits(OffsetLenMinus1 + 1);
      end;
    end;

    if APps.SliceSegmentHeaderExtensionPresent then
    begin
      I := BR.ReadUE; // slice_segment_header_extension_length
      while I > 0 do
      begin
        BR.ReadBits(8);
        Dec(I);
      end;
    end;

    // byte_alignment(): alignment_bit_equal_to_one then zeros to byte boundary.
    BR.ReadBit;         // alignment_bit_equal_to_one
    BR.ByteAlign;
    ASh.DataByteOffset := BR.BytePos;
  finally
    BR.Free;
  end;
end;

end.
