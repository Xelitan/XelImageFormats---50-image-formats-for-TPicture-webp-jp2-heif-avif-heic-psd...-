unit Av1.Obu;

// AV1 OBU (Open Bitstream Unit) parsing and sequence-header decoding.
//
// Splits an AV1 elementary stream (low-overhead bitstream format, as carried in
// AVIF item data and av1C config OBUs) into OBUs, and parses the sequence header
// into a record the rest of the decoder consumes.
//
// Reference: AV1 spec sections 5.2 (OBU), 5.5 (sequence header), 5.9 (color).

{$mode delphi}{$H+}

interface

uses
  SysUtils, Av1.Bits;

const
  OBU_SEQUENCE_HEADER   = 1;
  OBU_TEMPORAL_DELIMITER = 2;
  OBU_FRAME_HEADER      = 3;
  OBU_TILE_GROUP        = 4;
  OBU_METADATA          = 5;
  OBU_FRAME             = 6;
  OBU_REDUNDANT_FRAME_HEADER = 7;
  OBU_TILE_LIST         = 8;
  OBU_PADDING           = 15;

  // color primaries / transfer / matrix constants used in color_config
  CP_BT_709 = 1;
  CP_UNSPECIFIED = 2;
  TC_SRGB = 13;
  TC_UNSPECIFIED = 2;
  MC_IDENTITY = 0;
  MC_UNSPECIFIED = 2;

  CSP_UNKNOWN = 0;
  CSP_VERTICAL = 1;
  CSP_COLOCATED = 2;

type
  TObu = record
    ObuType: Integer;
    TemporalId: Integer;
    SpatialId: Integer;
    HasSize: Boolean;
    Payload: PByte;       // pointer into the source buffer
    PayloadSize: NativeInt;
  end;
  TObuArray = array of TObu;

  TAv1SequenceHeader = record
    Valid: Boolean;
    SeqProfile: Integer;
    StillPicture: Boolean;
    ReducedStillPicture: Boolean;
    SeqLevelIdx0: Integer;
    FrameWidthBits: Integer;
    FrameHeightBits: Integer;
    MaxFrameWidth: Integer;
    MaxFrameHeight: Integer;
    FrameIdNumbersPresent: Boolean;
    DeltaFrameIdLength: Integer;
    AdditionalFrameIdLength: Integer;
    Use128x128Superblock: Boolean;
    EnableFilterIntra: Boolean;
    EnableIntraEdgeFilter: Boolean;
    EnableInterintraCompound: Boolean;
    EnableMaskedCompound: Boolean;
    EnableWarpedMotion: Boolean;
    EnableDualFilter: Boolean;
    EnableOrderHint: Boolean;
    EnableJntComp: Boolean;
    EnableRefFrameMvs: Boolean;
    SeqForceScreenContentTools: Integer;
    SeqForceIntegerMv: Integer;
    OrderHintBits: Integer;
    EnableSuperres: Boolean;
    EnableCdef: Boolean;
    EnableRestoration: Boolean;
    // color_config
    BitDepth: Integer;
    MonoChrome: Boolean;
    NumPlanes: Integer;
    ColorPrimaries: Integer;
    TransferCharacteristics: Integer;
    MatrixCoefficients: Integer;
    ColorRange: Integer;
    SubsamplingX: Integer;
    SubsamplingY: Integer;
    ChromaSamplePosition: Integer;
    SeparateUvDeltaQ: Boolean;
    FilmGrainParamsPresent: Boolean;
  end;

// Splits a low-overhead AV1 bitstream into OBUs.
function SplitObus(AData: PByte; ASize: NativeInt): TObuArray;

// Parses a sequence-header OBU payload.
procedure ParseSequenceHeader(AData: PByte; ASize: NativeInt;
  out ASeq: TAv1SequenceHeader);

function ObuTypeName(AType: Integer): string;

implementation

function ObuTypeName(AType: Integer): string;
begin
  case AType of
    OBU_SEQUENCE_HEADER: Result := 'SEQUENCE_HEADER';
    OBU_TEMPORAL_DELIMITER: Result := 'TEMPORAL_DELIMITER';
    OBU_FRAME_HEADER: Result := 'FRAME_HEADER';
    OBU_TILE_GROUP: Result := 'TILE_GROUP';
    OBU_METADATA: Result := 'METADATA';
    OBU_FRAME: Result := 'FRAME';
    OBU_REDUNDANT_FRAME_HEADER: Result := 'REDUNDANT_FRAME_HEADER';
    OBU_TILE_LIST: Result := 'TILE_LIST';
    OBU_PADDING: Result := 'PADDING';
  else
    Result := 'OBU_' + IntToStr(AType);
  end;
end;

function SplitObus(AData: PByte; ASize: NativeInt): TObuArray;
var
  Pos: NativeInt;
  Count: Integer;
  B: TAv1Bits;
  ExtFlag, HasSize: Boolean;
  ObuType, HeaderBytes: Integer;
  Size: UInt64;
  Obu: TObu;
  StartByte: NativeInt;
begin
  SetLength(Result, 0);
  Count := 0;
  Pos := 0;
  while Pos < ASize do
  begin
    StartByte := Pos;
    // Parse the 1-2 byte OBU header with a small bit reader.
    B := TAv1Bits.Create(@AData[Pos], ASize - Pos);
    try
      B.f(1);                       // obu_forbidden_bit
      ObuType := B.f(4);
      ExtFlag := B.f(1) = 1;
      HasSize := B.f(1) = 1;
      B.f(1);                       // obu_reserved_1bit
      if ExtFlag then
      begin
        Obu.TemporalId := B.f(3);
        Obu.SpatialId := B.f(2);
        B.f(3);                     // extension reserved
      end
      else
      begin
        Obu.TemporalId := 0;
        Obu.SpatialId := 0;
      end;
      if HasSize then
        Size := B.leb128
      else
        Size := 0;
      HeaderBytes := B.BytePos;
    finally
      B.Free;
    end;

    Obu.ObuType := ObuType;
    Obu.HasSize := HasSize;
    if HasSize then
      Obu.PayloadSize := NativeInt(Size)
    else
      Obu.PayloadSize := ASize - (StartByte + HeaderBytes);
    Obu.Payload := @AData[StartByte + HeaderBytes];

    if StartByte + HeaderBytes + Obu.PayloadSize > ASize then
      Obu.PayloadSize := ASize - (StartByte + HeaderBytes); // tolerate truncation

    if Count >= Length(Result) then
      SetLength(Result, (Count + 1) * 2);
    Result[Count] := Obu;
    Inc(Count);

    Pos := StartByte + HeaderBytes + Obu.PayloadSize;
    if Obu.PayloadSize < 0 then Break;
  end;
  SetLength(Result, Count);
end;

procedure ParseColorConfig(B: TAv1Bits; var S: TAv1SequenceHeader);
var
  HighBitdepth, TwelveBit: Integer;
  ColorDescPresent: Boolean;
begin
  HighBitdepth := B.f(1);
  if (S.SeqProfile = 2) and (HighBitdepth = 1) then
  begin
    TwelveBit := B.f(1);
    if TwelveBit = 1 then S.BitDepth := 12 else S.BitDepth := 10;
  end
  else if S.SeqProfile <= 2 then
  begin
    if HighBitdepth = 1 then S.BitDepth := 10 else S.BitDepth := 8;
  end;

  if S.SeqProfile = 1 then
    S.MonoChrome := False
  else
    S.MonoChrome := B.f(1) = 1;
  if S.MonoChrome then S.NumPlanes := 1 else S.NumPlanes := 3;

  ColorDescPresent := B.f(1) = 1;
  if ColorDescPresent then
  begin
    S.ColorPrimaries := B.f(8);
    S.TransferCharacteristics := B.f(8);
    S.MatrixCoefficients := B.f(8);
  end
  else
  begin
    S.ColorPrimaries := CP_UNSPECIFIED;
    S.TransferCharacteristics := TC_UNSPECIFIED;
    S.MatrixCoefficients := MC_UNSPECIFIED;
  end;

  if S.MonoChrome then
  begin
    S.ColorRange := B.f(1);
    S.SubsamplingX := 1; S.SubsamplingY := 1;
    S.ChromaSamplePosition := CSP_UNKNOWN;
    S.SeparateUvDeltaQ := False;
    Exit;
  end
  else if (S.ColorPrimaries = CP_BT_709) and
          (S.TransferCharacteristics = TC_SRGB) and
          (S.MatrixCoefficients = MC_IDENTITY) then
  begin
    S.ColorRange := 1;
    S.SubsamplingX := 0; S.SubsamplingY := 0;   // 4:4:4
  end
  else
  begin
    S.ColorRange := B.f(1);
    if S.SeqProfile = 0 then
    begin
      S.SubsamplingX := 1; S.SubsamplingY := 1; // 4:2:0
    end
    else if S.SeqProfile = 1 then
    begin
      S.SubsamplingX := 0; S.SubsamplingY := 0; // 4:4:4
    end
    else
    begin
      if S.BitDepth = 12 then
      begin
        S.SubsamplingX := B.f(1);
        if S.SubsamplingX = 1 then S.SubsamplingY := B.f(1) else S.SubsamplingY := 0;
      end
      else
      begin
        S.SubsamplingX := 1; S.SubsamplingY := 0; // 4:2:2
      end;
    end;
    if (S.SubsamplingX = 1) and (S.SubsamplingY = 1) then
      S.ChromaSamplePosition := B.f(2);
  end;
  S.SeparateUvDeltaQ := B.f(1) = 1;
end;

procedure ParseSequenceHeader(AData: PByte; ASize: NativeInt;
  out ASeq: TAv1SequenceHeader);
var
  B: TAv1Bits;
  I, OpCnt: Integer;
  n: Integer;
  seqChooseScreenContentTools, seqChooseIntegerMv: Integer;
  InitDisplayDelayPresent: Boolean;
begin
  FillChar(ASeq, SizeOf(ASeq), 0);
  B := TAv1Bits.Create(AData, ASize);
  try
    ASeq.SeqProfile := B.f(3);
    ASeq.StillPicture := B.f(1) = 1;
    ASeq.ReducedStillPicture := B.f(1) = 1;

    if ASeq.ReducedStillPicture then
    begin
      ASeq.SeqLevelIdx0 := B.f(5);
    end
    else
    begin
      if B.f(1) = 1 then // timing_info_present_flag
        raise EAv1.Create('AV1 timing_info not supported (video, not still image)');
      // decoder_model_info_present_flag = 0 in this branch (no timing info).
      InitDisplayDelayPresent := B.f(1) = 1;
      OpCnt := B.f(5); // operating_points_cnt_minus_1
      for I := 0 to OpCnt do
      begin
        B.f(12);                       // operating_point_idc[i]
        n := B.f(5);                   // seq_level_idx[i]
        if I = 0 then ASeq.SeqLevelIdx0 := n;
        if n > 7 then B.f(1);          // seq_tier[i]
        // decoder_model_info_present_flag is 0, so no operating parameters.
        if InitDisplayDelayPresent then
          if B.f(1) = 1 then           // initial_display_delay_present_for_this_op
            B.f(4);                    // initial_display_delay_minus_1
      end;
    end;

    ASeq.FrameWidthBits := B.f(4) + 1;
    ASeq.FrameHeightBits := B.f(4) + 1;
    ASeq.MaxFrameWidth := B.f(ASeq.FrameWidthBits) + 1;
    ASeq.MaxFrameHeight := B.f(ASeq.FrameHeightBits) + 1;

    if ASeq.ReducedStillPicture then
      ASeq.FrameIdNumbersPresent := False
    else
      ASeq.FrameIdNumbersPresent := B.f(1) = 1;
    if ASeq.FrameIdNumbersPresent then
    begin
      ASeq.DeltaFrameIdLength := B.f(4) + 2;
      ASeq.AdditionalFrameIdLength := B.f(3) + 1;
    end;

    ASeq.Use128x128Superblock := B.f(1) = 1;
    ASeq.EnableFilterIntra := B.f(1) = 1;
    ASeq.EnableIntraEdgeFilter := B.f(1) = 1;

    if ASeq.ReducedStillPicture then
    begin
      ASeq.SeqForceScreenContentTools := 2; // SELECT_SCREEN_CONTENT_TOOLS
      ASeq.SeqForceIntegerMv := 2;          // SELECT_INTEGER_MV
      ASeq.OrderHintBits := 0;
    end
    else
    begin
      ASeq.EnableInterintraCompound := B.f(1) = 1;
      ASeq.EnableMaskedCompound := B.f(1) = 1;
      ASeq.EnableWarpedMotion := B.f(1) = 1;
      ASeq.EnableDualFilter := B.f(1) = 1;
      ASeq.EnableOrderHint := B.f(1) = 1;
      if ASeq.EnableOrderHint then
      begin
        ASeq.EnableJntComp := B.f(1) = 1;
        ASeq.EnableRefFrameMvs := B.f(1) = 1;
      end;
      seqChooseScreenContentTools := B.f(1);
      if seqChooseScreenContentTools = 1 then
        ASeq.SeqForceScreenContentTools := 2
      else
        ASeq.SeqForceScreenContentTools := B.f(1);
      if ASeq.SeqForceScreenContentTools > 0 then
      begin
        seqChooseIntegerMv := B.f(1);
        if seqChooseIntegerMv = 1 then
          ASeq.SeqForceIntegerMv := 2
        else
          ASeq.SeqForceIntegerMv := B.f(1);
      end
      else
        ASeq.SeqForceIntegerMv := 2;
      if ASeq.EnableOrderHint then
        ASeq.OrderHintBits := B.f(3) + 1
      else
        ASeq.OrderHintBits := 0;
    end;

    ASeq.EnableSuperres := B.f(1) = 1;
    ASeq.EnableCdef := B.f(1) = 1;
    ASeq.EnableRestoration := B.f(1) = 1;

    ParseColorConfig(B, ASeq);

    ASeq.FilmGrainParamsPresent := B.f(1) = 1;
    ASeq.Valid := True;
  finally
    B.Free;
  end;
end;

end.
