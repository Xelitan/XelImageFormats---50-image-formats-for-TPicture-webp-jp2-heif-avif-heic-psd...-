unit Heif.Hevc;

// Pure-Pascal HEVC (H.265) bitstream front-end for HEIF.
//
// This unit covers everything up to (but not including) actual pixel
// reconstruction:
// - parsing the hvcC decoder-configuration record,
// - splitting the coded item data into NAL units (length-prefixed),
// - emulation-prevention (RBSP) removal,
// - NAL header parsing,
// - an SPS geometry parse (dimensions, chroma format, bit depth,
// conformance window) sufficient to describe the image.
//
// A full SPS/PPS parse for reconstruction is layered on top of this later.
//
// Reference: ISO/IEC 23008-2 (HEVC). Cross-checked against libheif
// codecs/hevc_boxes.cc.

{$mode delphi}{$H+}

interface

uses
  SysUtils, Heif.Reader;

const
  // HEVC NAL unit types (subset relevant to still images).
  NAL_TRAIL_N   = 0;
  NAL_TRAIL_R   = 1;
  NAL_BLA_W_LP  = 16;
  NAL_IDR_W_RADL = 19;
  NAL_IDR_N_LP  = 20;
  NAL_CRA_NUT   = 21;
  NAL_VPS       = 32;
  NAL_SPS       = 33;
  NAL_PPS       = 34;
  NAL_AUD       = 35;
  NAL_SEI_PREFIX = 39;
  NAL_SEI_SUFFIX = 40;

type
  EHevc = class(Exception);

  TNalUnit = record
    NalType: Integer;      // nal_unit_type
    LayerId: Integer;
    TemporalId: Integer;   // nuh_temporal_id_plus1 - 1
    Data: TBytes;          // full NAL unit incl. 2-byte header (with emulation bytes)
  end;

  TNalUnitArray = array of TNalUnit;

  THevcConfig = record
    ConfigurationVersion: Integer;
    GeneralProfileSpace: Integer;
    GeneralTierFlag: Integer;
    GeneralProfileIdc: Integer;
    GeneralProfileCompat: LongWord;
    GeneralLevelIdc: Integer;
    ChromaFormat: Integer;     // 0=mono,1=4:2:0,2=4:2:2,3=4:4:4
    BitDepthLuma: Integer;
    BitDepthChroma: Integer;
    LengthSize: Integer;       // bytes of NAL length prefix in coded data (1,2,4)
    Vps: TNalUnitArray;
    Sps: TNalUnitArray;
    Pps: TNalUnitArray;
  end;

  // Geometry recovered from the SPS.
  THevcGeometry = record
    Width: LongWord;           // after conformance-window cropping
    Height: LongWord;
    CodedWidth: LongWord;      // before cropping
    CodedHeight: LongWord;
    ChromaFormatIdc: Integer;
    BitDepthLuma: Integer;
    BitDepthChroma: Integer;
    ConfWinLeft, ConfWinRight, ConfWinTop, ConfWinBottom: LongWord;
  end;

// Removes HEVC emulation-prevention bytes (0x00 0x00 0x03 -> 0x00 0x00) from a
// NAL unit payload, producing the raw RBSP.
function RemoveEmulationPrevention(const AData: TBytes): TBytes; overload;
function RemoveEmulationPrevention(AData: PByte; ASize: NativeInt): TBytes; overload;

// Inserts HEVC emulation-prevention bytes: after any 00 00 followed by a byte
// <= 0x03, a 0x03 is inserted. Inverse of RemoveEmulationPrevention.
function AddEmulationPrevention(const AData: TBytes): TBytes;

// Wraps an RBSP into a complete NAL unit: 2-byte NAL header (given type,
// layer 0, temporal_id_plus1 = 1) followed by the emulation-encoded RBSP.
function WrapRbspNal(ANalType: Integer; const ARbsp: TBytes): TBytes;

// Parses an hvcC configuration record payload (the bytes after the box header).
procedure ParseHvcC(const AData: TBytes; out AConfig: THevcConfig);

// Splits length-prefixed coded item data into NAL units using ALengthSize.
function SplitNalUnits(const AData: TBytes; ALengthSize: Integer): TNalUnitArray;

// Fills the header fields of a TNalUnit from its first two bytes.
procedure ParseNalHeader(var ANal: TNalUnit);

// Parses just enough of an SPS RBSP to recover image geometry.
// ANalUnit is the full SPS NAL unit (with header, emulation bytes intact).
procedure ParseSpsGeometry(const ANalUnit: TBytes; out AGeom: THevcGeometry);

function NalTypeName(ANalType: Integer): string;

implementation

function RemoveEmulationPrevention(AData: PByte; ASize: NativeInt): TBytes;
var
  I, O: NativeInt;
  ZeroRun: Integer;
begin
  SetLength(Result, ASize);
  O := 0;
  ZeroRun := 0;
  I := 0;
  while I < ASize do
  begin
    if (ZeroRun >= 2) and (AData[I] = 3) then
    begin
      // Drop the emulation_prevention_three_byte; reset the zero run.
      // (A 0x03 following two 0x00s is removed; the byte after it is kept.)
      ZeroRun := 0;
      Inc(I);
      Continue;
    end;
    Result[O] := AData[I];
    if AData[I] = 0 then
      Inc(ZeroRun)
    else
      ZeroRun := 0;
    Inc(O);
    Inc(I);
  end;
  SetLength(Result, O);
end;

function RemoveEmulationPrevention(const AData: TBytes): TBytes;
begin
  if Length(AData) = 0 then
    Exit(nil);
  Result := RemoveEmulationPrevention(@AData[0], Length(AData));
end;

function AddEmulationPrevention(const AData: TBytes): TBytes;
var
  I, O, ZeroRun: Integer;
begin
  SetLength(Result, Length(AData) * 2 + 4);
  O := 0;
  ZeroRun := 0;
  for I := 0 to High(AData) do
  begin
    if (ZeroRun >= 2) and (AData[I] <= 3) then
    begin
      Result[O] := 3; Inc(O);
      ZeroRun := 0;
    end;
    Result[O] := AData[I]; Inc(O);
    if AData[I] = 0 then Inc(ZeroRun) else ZeroRun := 0;
  end;
  SetLength(Result, O);
end;

function WrapRbspNal(ANalType: Integer; const ARbsp: TBytes): TBytes;
var
  Raw: TBytes;
  I: Integer;
begin
  SetLength(Raw, Length(ARbsp) + 2);
  Raw[0] := Byte((ANalType shl 1) and $7F); // forbidden=0, type, layerid hi=0
  Raw[1] := 1;                                // layerid lo=0, tid_plus1=1
  for I := 0 to High(ARbsp) do
    Raw[2 + I] := ARbsp[I];
  Result := AddEmulationPrevention(Raw);
end;

procedure ParseNalHeader(var ANal: TNalUnit);
var
  B0, B1: Byte;
begin
  if Length(ANal.Data) < 2 then
    raise EHevc.Create('NAL unit too short for header');
  B0 := ANal.Data[0];
  B1 := ANal.Data[1];
  // forbidden_zero_bit(1) nal_unit_type(6) nuh_layer_id(6) nuh_temporal_id_plus1(3)
  ANal.NalType := (B0 shr 1) and $3F;
  ANal.LayerId := ((B0 and 1) shl 5) or ((B1 shr 3) and $1F);
  ANal.TemporalId := (B1 and $07) - 1;
end;

procedure ParseHvcC(const AData: TBytes; out AConfig: THevcConfig);
var
  R: TByteReader;
  B: Byte;
  NumArrays, U, NUnits, I: Integer;
  NalType, Size: Integer;
  Nal: TNalUnit;
  procedure AddNal(ANalType: Integer);
  begin
    Nal.Data := R.ReadBytes(Size);
    ParseNalHeader(Nal);
    case ANalType of
      NAL_VPS:
        begin
          SetLength(AConfig.Vps, Length(AConfig.Vps) + 1);
          AConfig.Vps[High(AConfig.Vps)] := Nal;
        end;
      NAL_SPS:
        begin
          SetLength(AConfig.Sps, Length(AConfig.Sps) + 1);
          AConfig.Sps[High(AConfig.Sps)] := Nal;
        end;
      NAL_PPS:
        begin
          SetLength(AConfig.Pps, Length(AConfig.Pps) + 1);
          AConfig.Pps[High(AConfig.Pps)] := Nal;
        end;
    end;
  end;
begin
  FillChar(AConfig, SizeOf(AConfig), 0);
  R := TByteReader.CreateOwned(AData);
  try
    AConfig.ConfigurationVersion := R.ReadU8;
    B := R.ReadU8;
    AConfig.GeneralProfileSpace := (B shr 6) and 3;
    AConfig.GeneralTierFlag := (B shr 5) and 1;
    AConfig.GeneralProfileIdc := B and $1F;
    AConfig.GeneralProfileCompat := R.ReadU32;
    R.Skip(6); // general_constraint_indicator_flags (48 bits)
    AConfig.GeneralLevelIdc := R.ReadU8;
    R.ReadU16; // min_spatial_segmentation_idc (4 reserved + 12)
    R.ReadU8;  // parallelismType (6 reserved + 2)
    AConfig.ChromaFormat := R.ReadU8 and $03;
    AConfig.BitDepthLuma := (R.ReadU8 and $07) + 8;
    AConfig.BitDepthChroma := (R.ReadU8 and $07) + 8;
    R.ReadU16; // avgFrameRate
    B := R.ReadU8;
    AConfig.LengthSize := (B and $03) + 1;
    NumArrays := R.ReadU8;
    for I := 0 to NumArrays - 1 do
    begin
      B := R.ReadU8;
      NalType := B and $3F;
      NUnits := R.ReadU16;
      for U := 0 to NUnits - 1 do
      begin
        Size := R.ReadU16;
        if Size = 0 then
          Continue;
        AddNal(NalType);
      end;
    end;
  finally
    R.Free;
  end;
end;

function SplitNalUnits(const AData: TBytes; ALengthSize: Integer): TNalUnitArray;
var
  R: TByteReader;
  Len: NativeInt;
  Nal: TNalUnit;
  Count: Integer;
begin
  SetLength(Result, 0);
  if Length(AData) = 0 then
    Exit;
  if (ALengthSize < 1) or (ALengthSize > 4) then
    raise EHevc.CreateFmt('Invalid NAL length size %d', [ALengthSize]);
  Count := 0;
  R := TByteReader.CreateOwned(AData);
  try
    while R.Remaining >= ALengthSize do
    begin
      Len := NativeInt(R.ReadUInt(ALengthSize));
      if Len <= 0 then
        Break;
      if Len > R.Remaining then
        Len := R.Remaining; // tolerate truncation
      Nal.Data := R.ReadBytes(Len);
      ParseNalHeader(Nal);
      if Count >= Length(Result) then
        SetLength(Result, (Count + 1) * 2);
      Result[Count] := Nal;
      Inc(Count);
    end;
  finally
    R.Free;
  end;
  SetLength(Result, Count);
end;

procedure ParseSpsGeometry(const ANalUnit: TBytes; out AGeom: THevcGeometry);
var
  Rbsp: TBytes;
  BR: TBitReader;
  MaxSubLayersMinus1: Integer;
  I: Integer;
  ProfilePresent, LevelPresent: array[0..7] of Boolean;
  ChromaIdc: LongWord;
  Value: LongWord;
  ConfWin: Boolean;
  SubW, SubH: LongWord;
begin
  FillChar(AGeom, SizeOf(AGeom), 0);
  Rbsp := RemoveEmulationPrevention(ANalUnit);
  if Length(Rbsp) = 0 then
    raise EHevc.Create('Empty SPS');
  BR := TBitReader.Create(@Rbsp[0], Length(Rbsp));
  try
    BR.ReadBits(16); // NAL header (2 bytes)
    BR.ReadBits(4);  // sps_video_parameter_set_id
    MaxSubLayersMinus1 := BR.ReadBits(3);
    BR.ReadBit;      // sps_temporal_id_nesting_flag

    // profile_tier_level( 1, MaxSubLayersMinus1 )
    BR.ReadBits(2);  // general_profile_space
    BR.ReadBit;      // general_tier_flag
    BR.ReadBits(5);  // general_profile_idc
    BR.ReadBits(32); // general_profile_compatibility_flags
    BR.ReadBits(32); // constraint flags (48 bits total split across reads)
    BR.ReadBits(16);
    BR.ReadBits(8);  // general_level_idc

    for I := 0 to MaxSubLayersMinus1 - 1 do
    begin
      ProfilePresent[I] := BR.ReadBit = 1;
      LevelPresent[I] := BR.ReadBit = 1;
    end;
    if MaxSubLayersMinus1 > 0 then
      for I := MaxSubLayersMinus1 to 7 do
        BR.ReadBits(2); // reserved_zero_2bits
    for I := 0 to MaxSubLayersMinus1 - 1 do
    begin
      if ProfilePresent[I] then
      begin
        BR.ReadBits(2 + 1 + 5);
        BR.ReadBits(32);
        BR.ReadBits(16);
      end;
      if LevelPresent[I] then
        BR.ReadBits(8);
    end;

    BR.ReadUE; // sps_seq_parameter_set_id
    ChromaIdc := BR.ReadUE;
    if ChromaIdc > 3 then
      raise EHevc.Create('SPS chroma_format_idc out of range');
    AGeom.ChromaFormatIdc := ChromaIdc;
    if ChromaIdc = 3 then
      BR.ReadBit; // separate_colour_plane_flag

    AGeom.CodedWidth := BR.ReadUE;  // pic_width_in_luma_samples
    AGeom.CodedHeight := BR.ReadUE; // pic_height_in_luma_samples
    AGeom.Width := AGeom.CodedWidth;
    AGeom.Height := AGeom.CodedHeight;

    ConfWin := BR.ReadBit = 1;
    if ConfWin then
    begin
      AGeom.ConfWinLeft := BR.ReadUE;
      AGeom.ConfWinRight := BR.ReadUE;
      AGeom.ConfWinTop := BR.ReadUE;
      AGeom.ConfWinBottom := BR.ReadUE;
      SubW := 1; SubH := 1;
      if ChromaIdc = 1 then begin SubW := 2; SubH := 2; end
      else if ChromaIdc = 2 then SubW := 2;
      AGeom.Width := AGeom.CodedWidth -
        SubW * (AGeom.ConfWinLeft + AGeom.ConfWinRight);
      AGeom.Height := AGeom.CodedHeight -
        SubH * (AGeom.ConfWinTop + AGeom.ConfWinBottom);
    end;

    Value := BR.ReadUE; // bit_depth_luma_minus8
    if Value > 8 then
      raise EHevc.Create('SPS bit_depth_luma out of range');
    AGeom.BitDepthLuma := Value + 8;
    Value := BR.ReadUE; // bit_depth_chroma_minus8
    if Value > 8 then
      raise EHevc.Create('SPS bit_depth_chroma out of range');
    AGeom.BitDepthChroma := Value + 8;
  finally
    BR.Free;
  end;
end;

function NalTypeName(ANalType: Integer): string;
begin
  case ANalType of
    NAL_TRAIL_N: Result := 'TRAIL_N';
    NAL_TRAIL_R: Result := 'TRAIL_R';
    NAL_BLA_W_LP: Result := 'BLA_W_LP';
    NAL_IDR_W_RADL: Result := 'IDR_W_RADL';
    NAL_IDR_N_LP: Result := 'IDR_N_LP';
    NAL_CRA_NUT: Result := 'CRA_NUT';
    NAL_VPS: Result := 'VPS';
    NAL_SPS: Result := 'SPS';
    NAL_PPS: Result := 'PPS';
    NAL_AUD: Result := 'AUD';
    NAL_SEI_PREFIX: Result := 'SEI_PREFIX';
    NAL_SEI_SUFFIX: Result := 'SEI_SUFFIX';
  else
    Result := 'NAL_' + IntToStr(ANalType);
  end;
end;

end.
