unit JpegHeader;

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//

{$mode delphi}
{$H+}
{$R-}
{$Q-}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils,
  LeptonConsts, LeptonErrors, LeptonHelpers, LeptonFeatures,
  JpegCodes, JpegComponentInfo, JpegHuffman;

type
  TJpegHeader = class;

  TLongWordArray = array of LongWord;
  TByteArray = TBytes;
  TMaxDPosArray = array[0..3] of LongWord;
  TLastDCArray = array[0..3] of SmallInt;
  TComponentInfoArray = array[0..3] of TComponentInfo;
  TQuantTables = array[0..3, 0..63] of Word;
  THuffCodesByClass = array[0..1, 0..3] of THuffCodes;
  THuffTreesByClass = array[0..1, 0..3] of THuffTree;
  THuffSetByClass = array[0..1, 0..3] of Byte;
  TCurrentScanComponents = array[0..3] of SizeInt;

  TRestartSegmentCodingInfo = record
    OverhangByte: Byte;
    NumOverhangBits: Byte;
    LumaYStart: LongWord;
    LumaYEnd: LongWord;
    LastDC: TLastDCArray;
    class function Create(AOverhangByte, ANumOverhangBits: Byte;
      const ALastDC: TLastDCArray; MCU: LongWord; JF: TJpegHeader): TRestartSegmentCodingInfo; static;
  end;

  TReconstructionInfo = record
    MaxCmp: LongWord;
    MaxBPos: LongWord;
    MaxSAH: Byte;
    MaxDPos: TMaxDPosArray;
    EarlyEOFEncountered: Boolean;
    HasPadBit: Boolean;
    PadBit: Byte;
    RstCnt: TLongWordArray;
    RstCntSet: Boolean;
    RstErr: TByteArray;
    RawJpegHeader: TByteArray;
    GarbageData: TByteArray;
    class function Default: TReconstructionInfo; static;
  end;

  TJpegParseSegmentResult = (jpsContinue, jpsEOI, jpsSOS);

  TJpegHeader = class
  private
    FHCodes: THuffCodesByClass;
    FHTrees: THuffTreesByClass;
    FHTSet: THuffSetByClass;
    function ParseNextSegment(Stream: TStream; const EnabledFeatures: TEnabledFeatures; RawOut: TStream): TJpegParseSegmentResult;
    procedure ReadExact(Stream: TStream; var Buffer; Count: SizeInt; RawOut: TStream = nil);
    procedure AppendRaw(RawOut: TStream; const Buffer; Count: SizeInt);
  public
    QTables: TQuantTables;
    CmpInfo: TComponentInfoArray;
    CmpC: SizeInt;
    ImgWidth: LongWord;
    ImgHeight: LongWord;
    JpegType: TJpegType;
    SFHM: LongWord;
    SFVM: LongWord;
    MCUV: LongWord;
    MCUH: LongWord;
    MCUC: LongWord;
    RSTI: LongWord;
    CSCmpC: SizeInt;
    CSCmp: TCurrentScanComponents;
    CSFrom: Byte;
    CSTo: Byte;
    CSSAH: Byte;
    CSSAL: Byte;

    constructor Create;
    procedure Reset;
    function Parse(Stream: TStream; const EnabledFeatures: TEnabledFeatures; RawOut: TStream = nil): Boolean;
    function IsSingleScan: Boolean;
    procedure VerifyHuffmanTable(DCPresent, ACPresent: Boolean);
    function GetHuffDCCodes(Cmp: SizeInt): THuffCodes;
    function GetHuffDCTree(Cmp: SizeInt): THuffTree;
    function GetHuffACCodes(Cmp: SizeInt): THuffCodes;
    function GetHuffACTree(Cmp: SizeInt): THuffTree;
  end;

function ParseJpegHeader(Stream: TStream; const EnabledFeatures: TEnabledFeatures;
  JpegHeader: TJpegHeader; var RInfo: TReconstructionInfo): Boolean;

implementation

function CeilDiv(A, B: LongWord): LongWord; inline;
begin
  if B = 0 then
    LeptonFail(lecUnsupportedJpeg, 'division by zero while parsing JPEG geometry');
  Result := (A + B - 1) div B;
end;

class function TRestartSegmentCodingInfo.Create(AOverhangByte, ANumOverhangBits: Byte;
  const ALastDC: TLastDCArray; MCU: LongWord; JF: TJpegHeader): TRestartSegmentCodingInfo;
var
  MCUY, LumaMul: LongWord;
begin
  if JF = nil then
    LeptonFail(lecAssertionFailure, 'RestartSegmentCodingInfo requires a JPEG header');
  if JF.MCUH = 0 then
    LeptonFail(lecUnsupportedJpeg, 'RestartSegmentCodingInfo: MCUH is zero');

  MCUY := MCU div JF.MCUH;
  if JF.MCUV = 0 then
    LeptonFail(lecUnsupportedJpeg, 'RestartSegmentCodingInfo: MCUV is zero');
  LumaMul := JF.CmpInfo[0].BCV div JF.MCUV;

  Result.OverhangByte := AOverhangByte;
  Result.NumOverhangBits := ANumOverhangBits;
  Result.LastDC := ALastDC;
  Result.LumaYStart := LumaMul * MCUY;
  Result.LumaYEnd := LumaMul * (MCUY + 1);
end;

class function TReconstructionInfo.Default: TReconstructionInfo;
begin
  FillChar(Result.MaxDPos, SizeOf(Result.MaxDPos), 0);
  Result.MaxCmp := 0;
  Result.MaxBPos := 0;
  Result.MaxSAH := 0;
  Result.EarlyEOFEncountered := False;
  Result.HasPadBit := False;
  Result.PadBit := 0;
  SetLength(Result.RstCnt, 0);
  Result.RstCntSet := False;
  SetLength(Result.RstErr, 0);
  SetLength(Result.RawJpegHeader, 0);
  SetLength(Result.GarbageData, 0);
end;

constructor TJpegHeader.Create;
begin
  inherited Create;
  Reset;
end;

procedure TJpegHeader.Reset;
var
  I, J: SizeInt;
begin
  FillChar(QTables, SizeOf(QTables), 0);
  for I := 0 to 3 do
    CmpInfo[I] := TComponentInfo.Default;

  for I := 0 to 1 do
    for J := 0 to 3 do
    begin
      FHCodes[I, J] := THuffCodes.Default;
      FHTrees[I, J] := THuffTree.Default;
      FHTSet[I, J] := 0;
    end;

  CmpC := 0;
  ImgWidth := 0;
  ImgHeight := 0;
  JpegType := jtUnknown;
  SFHM := 0;
  SFVM := 0;
  MCUV := 1;
  MCUH := 1;
  MCUC := 0;
  RSTI := 0;
  CSCmpC := 0;
  CSFrom := 0;
  CSTo := 0;
  CSSAH := 0;
  CSSAL := 0;
  for I := 0 to 3 do
    CSCmp[I] := 0;
end;

procedure TJpegHeader.AppendRaw(RawOut: TStream; const Buffer; Count: SizeInt);
begin
  if (RawOut <> nil) and (Count > 0) then
    RawOut.WriteBuffer(Buffer, Count);
end;

procedure TJpegHeader.ReadExact(Stream: TStream; var Buffer; Count: SizeInt; RawOut: TStream);
var
  Got: SizeInt;
begin
  if Count = 0 then
    Exit;
  Got := Stream.Read(Buffer, Count);
  if Got <> Count then
    LeptonFail(lecUnsupportedJpeg, 'unexpected end of JPEG header');
  AppendRaw(RawOut, Buffer, Count);
end;

function TJpegHeader.IsSingleScan: Boolean;
begin
  if JpegType = jtUnknown then
    LeptonFail(lecAssertionFailure, 'JPEG type is unknown');
  Result := (JpegType = jtSequential) and (CmpC = CSCmpC);
end;

function TJpegHeader.GetHuffDCCodes(Cmp: SizeInt): THuffCodes;
begin
  Result := FHCodes[0, CmpInfo[Cmp].HuffDC];
end;

function TJpegHeader.GetHuffDCTree(Cmp: SizeInt): THuffTree;
begin
  Result := FHTrees[0, CmpInfo[Cmp].HuffDC];
end;

function TJpegHeader.GetHuffACCodes(Cmp: SizeInt): THuffCodes;
begin
  Result := FHCodes[1, CmpInfo[Cmp].HuffAC];
end;

function TJpegHeader.GetHuffACTree(Cmp: SizeInt): THuffTree;
begin
  Result := FHTrees[1, CmpInfo[Cmp].HuffAC];
end;

procedure TJpegHeader.VerifyHuffmanTable(DCPresent, ACPresent: Boolean);
var
  ICSC, ICmp: SizeInt;
begin
  for ICSC := 0 to CSCmpC - 1 do
  begin
    ICmp := CSCmp[ICSC];
    if DCPresent and (FHTSet[0, CmpInfo[ICmp].HuffDC] = 0) then
      LeptonFail(lecUnsupportedJpeg, Format('DC huffman table missing for component %d', [ICmp]))
    else if ACPresent and (FHTSet[1, CmpInfo[ICmp].HuffAC] = 0) then
      LeptonFail(lecUnsupportedJpeg, Format('AC huffman table missing for component %d', [ICmp]));
  end;
end;

function TJpegHeader.Parse(Stream: TStream; const EnabledFeatures: TEnabledFeatures; RawOut: TStream): Boolean;
var
  Cmp: SizeInt;
begin
  while True do
  begin
    case ParseNextSegment(Stream, EnabledFeatures, RawOut) of
      jpsEOI:
        begin
          Result := False;
          Exit;
        end;
      jpsSOS:
        Break;
    end;
  end;

  if CmpC = 0 then
    LeptonFail(lecUnsupportedJpeg, 'header contains incomplete information');

  for Cmp := 0 to CmpC - 1 do
  begin
    if (CmpInfo[Cmp].SFV = 0) or (CmpInfo[Cmp].SFH = 0) or
       (QTables[CmpInfo[Cmp].QTableIndex, 0] = 0) or (JpegType = jtUnknown) then
      LeptonFail(lecUnsupportedJpeg, 'header contains incomplete information (components)');
  end;

  SFHM := 0;
  SFVM := 0;
  for Cmp := 0 to CmpC - 1 do
  begin
    if CmpInfo[Cmp].SFH > SFHM then
      SFHM := CmpInfo[Cmp].SFH;
    if CmpInfo[Cmp].SFV > SFVM then
      SFVM := CmpInfo[Cmp].SFV;
  end;

  MCUV := CeilDiv(ImgHeight, 8 * SFHM);
  if MCUV = 0 then
    LeptonFail(lecUnsupportedJpeg, 'mcuv is zero');
  MCUH := CeilDiv(ImgWidth, 8 * SFVM);
  if MCUH = 0 then
    LeptonFail(lecUnsupportedJpeg, 'mcuh is zero');
  MCUC := MCUV * MCUH;

  for Cmp := 0 to CmpC - 1 do
  begin
    CmpInfo[Cmp].MBS := CmpInfo[Cmp].SFV * CmpInfo[Cmp].SFH;
    CmpInfo[Cmp].BCV := MCUV * CmpInfo[Cmp].SFH;
    CmpInfo[Cmp].BCH := MCUH * CmpInfo[Cmp].SFV;
    CmpInfo[Cmp].BC := CmpInfo[Cmp].BCV * CmpInfo[Cmp].BCH;
    CmpInfo[Cmp].NCV := CeilDiv(ImgHeight * CmpInfo[Cmp].SFH, 8 * SFHM);
    CmpInfo[Cmp].NCH := CeilDiv(ImgWidth * CmpInfo[Cmp].SFV, 8 * SFVM);
    CmpInfo[Cmp].NC := CmpInfo[Cmp].NCV * CmpInfo[Cmp].NCH;
  end;

  if CmpC <= 3 then
  begin
    for Cmp := 0 to CmpC - 1 do
      CmpInfo[Cmp].SID := Cmp;
  end
  else
  begin
    for Cmp := 0 to CmpC - 1 do
      CmpInfo[Cmp].SID := 0;
  end;

  Result := True;
end;

function TJpegHeader.ParseNextSegment(Stream: TStream; const EnabledFeatures: TEnabledFeatures; RawOut: TStream): TJpegParseSegmentResult;
var
  Header: array[0..3] of Byte;
  BType: Byte;
  SegmentSize: Word;
  Segment: TBytes;
  HPos, Len, LVal, RVal, Skip, I, Cmp: SizeInt;
  QuantizationTableValue: Byte;
begin
  Result := jpsContinue;

  if Stream.Read(Header[0], 1) = 0 then
  begin
    Result := jpsEOI;
    Exit;
  end;
  AppendRaw(RawOut, Header[0], 1);

  if Header[0] <> $FF then
    LeptonFail(lecUnsupportedJpeg, 'invalid header encountered');

  ReadExact(Stream, Header[1], 1, RawOut);
  BType := Header[1];
  if BType = JPEG_EOI then
  begin
    Result := jpsEOI;
    Exit;
  end;

  ReadExact(Stream, Header[2], 2, RawOut);
  SegmentSize := BShort(Header[2], Header[3]);
  if SegmentSize < 2 then
    LeptonFail(lecUnsupportedJpeg, 'segment is too short');

  SetLength(Segment, SegmentSize - 2);
  if Length(Segment) > 0 then
    ReadExact(Stream, Segment[0], Length(Segment), RawOut);

  HPos := 0;
  Len := Length(Segment);

  case BType of
    JPEG_DHT:
      begin
        while HPos < Len do
        begin
          EnsureSegmentSpace(Segment, HPos, 1, 'DHT missing table selector');
          LVal := LBits(Segment[HPos], 4);
          RVal := RBits(Segment[HPos], 4);
          if (LVal >= 2) or (RVal >= 4) then
            Break;
          Inc(HPos);

          FHCodes[LVal, RVal] := THuffCodes.ConstructFromSegment(Segment, HPos);
          FHTrees[LVal, RVal] := THuffTree.ConstructHuffTree(FHCodes[LVal, RVal], EnabledFeatures.AcceptInvalidDht);
          FHTSet[LVal, RVal] := 1;

          Skip := 16;
          EnsureSegmentSpace(Segment, HPos, 16, 'DHT length table too short');
          for I := 0 to 15 do
            Inc(Skip, Segment[HPos + I]);
          Inc(HPos, Skip);
        end;

        if HPos <> Len then
          LeptonFail(lecUnsupportedJpeg, 'size mismatch in dht marker');
      end;

    JPEG_DQT:
      begin
        while HPos < Len do
        begin
          EnsureSegmentSpace(Segment, HPos, 1, 'DQT missing table selector');
          LVal := LBits(Segment[HPos], 4);
          RVal := RBits(Segment[HPos], 4);
          if (LVal >= 2) or (RVal >= 4) then
            LeptonFail(lecUnsupportedJpeg, 'DQT has invalid index');
          Inc(HPos);

          if LVal = 0 then
          begin
            EnsureSegmentSpace(Segment, HPos, 64, 'DQT 8-bit table too short');
            for I := 0 to 63 do
            begin
              QTables[RVal, I] := Segment[HPos + I];
              if QTables[RVal, I] = 0 then
              begin
                if EnabledFeatures.RejectDqtsWithZeros then
                  LeptonFail(lecUnsupportedJpegWithZeroIdct0, 'DQT has zero value')
                else
                  Break;
              end;
            end;
            Inc(HPos, 64);
          end
          else
          begin
            EnsureSegmentSpace(Segment, HPos, 128, 'DQT 16-bit table too short');
            for I := 0 to 63 do
            begin
              QTables[RVal, I] := BShort(Segment[HPos + 2 * I], Segment[HPos + 2 * I + 1]);
              if QTables[RVal, I] = 0 then
              begin
                if EnabledFeatures.RejectDqtsWithZeros then
                  LeptonFail(lecUnsupportedJpegWithZeroIdct0, 'DQT has zero value')
                else
                  Break;
              end;
            end;
            Inc(HPos, 128);
          end;
        end;

        if HPos <> Len then
          LeptonFail(lecUnsupportedJpeg, 'size mismatch in dqt marker');
      end;

    JPEG_DRI:
      begin
        EnsureSegmentSpace(Segment, HPos, 2, 'DRI segment too short');
        RSTI := BShort(Segment[HPos], Segment[HPos + 1]);
      end;

    JPEG_SOS:
      begin
        EnsureSegmentSpace(Segment, HPos, 1, 'SOS segment too short');
        CSCmpC := Segment[HPos];
        if CSCmpC = 0 then
          LeptonFail(lecUnsupportedJpeg, 'zero components in scan');
        if CSCmpC > CmpC then
          LeptonFail(lecUnsupportedJpeg, Format('%d components in scan, only %d are allowed', [CSCmpC, CmpC]));

        Inc(HPos);
        for I := 0 to CSCmpC - 1 do
        begin
          EnsureSegmentSpace(Segment, HPos, 2, 'SOS component table too short');

          Cmp := 0;
          while (Cmp < CmpC) and (Segment[HPos] <> CmpInfo[Cmp].JID) do
            Inc(Cmp);
          if Cmp = CmpC then
            LeptonFail(lecUnsupportedJpeg, 'component id mismatch in start-of-scan');

          CSCmp[I] := Cmp;
          CmpInfo[Cmp].HuffDC := LBits(Segment[HPos + 1], 4);
          CmpInfo[Cmp].HuffAC := RBits(Segment[HPos + 1], 4);
          if (CmpInfo[Cmp].HuffDC >= 4) or (CmpInfo[Cmp].HuffAC >= 4) then
            LeptonFail(lecUnsupportedJpeg, 'huffman table number mismatch');
          Inc(HPos, 2);
        end;

        EnsureSegmentSpace(Segment, HPos, 3, 'SOS spectral data too short');
        CSFrom := Segment[HPos];
        CSTo := Segment[HPos + 1];
        CSSAH := LBits(Segment[HPos + 2], 4);
        CSSAL := RBits(Segment[HPos + 2], 4);

        if (CSFrom > CSTo) or (CSFrom > 63) or (CSTo > 63) then
          LeptonFail(lecUnsupportedJpeg, 'spectral selection parameter out of range');
        if (CSSAH >= 12) or (CSSAL >= 12) then
          LeptonFail(lecUnsupportedJpeg, 'successive approximation parameter out of range');

        Result := jpsSOS;
      end;

    JPEG_SOF0, JPEG_SOF1, JPEG_SOF2:
      begin
        if JpegType <> jtUnknown then
          LeptonFail(lecUnsupportedJpeg, 'image cannot have multiple SOF blocks');

        if BType = JPEG_SOF2 then
        begin
          if not EnabledFeatures.Progressive then
            LeptonFail(lecUnsupportedJpeg, 'progressive JPEG is disabled');
          JpegType := jtProgressive;
        end
        else
          JpegType := jtSequential;

        EnsureSegmentSpace(Segment, HPos, 6, 'SOF segment too short');
        LVal := Segment[HPos];
        if LVal <> 8 then
          LeptonFail(lecUnsupportedJpeg, Format('%d bit data precision is not supported', [LVal]));

        ImgHeight := BShort(Segment[HPos + 1], Segment[HPos + 2]);
        ImgWidth := BShort(Segment[HPos + 3], Segment[HPos + 4]);
        if (ImgHeight = 0) or (ImgWidth = 0) then
          LeptonFail(lecUnsupportedJpeg, 'image dimensions can''t be zero');
        if (ImgHeight > EnabledFeatures.MaxJpegHeight) or (ImgWidth > EnabledFeatures.MaxJpegWidth) then
          LeptonFail(lecUnsupportedJpeg, Format('image dimensions larger than %dx%d', [EnabledFeatures.MaxJpegWidth, EnabledFeatures.MaxJpegHeight]));

        CmpC := Segment[HPos + 5];
        if CmpC > 4 then
          LeptonFail(lecUnsupportedJpeg, Format('image has %d components, max 4 are supported', [CmpC]));

        Inc(HPos, 6);
        for Cmp := 0 to CmpC - 1 do
        begin
          EnsureSegmentSpace(Segment, HPos, 3, 'SOF component table too short');
          CmpInfo[Cmp].JID := Segment[HPos];
          CmpInfo[Cmp].SFV := LBits(Segment[HPos + 1], 4);
          CmpInfo[Cmp].SFH := RBits(Segment[HPos + 1], 4);
          if (CmpInfo[Cmp].SFV > 2) or (CmpInfo[Cmp].SFH > 2) then
            LeptonFail(lecSamplingBeyondTwoUnsupported, 'Sampling type beyond two not supported');

          QuantizationTableValue := Segment[HPos + 2];
          if QuantizationTableValue >= 4 then
            LeptonFail(lecUnsupportedJpeg, 'quantizationTableValue too big');
          CmpInfo[Cmp].QTableIndex := QuantizationTableValue;
          Inc(HPos, 3);
        end;
      end;

    $C3:
      LeptonFail(lecUnsupportedJpeg, 'sof3 marker found, image is coded lossless');
    $C5:
      LeptonFail(lecUnsupportedJpeg, 'sof5 marker found, image is coded diff. sequential');
    $C6:
      LeptonFail(lecUnsupportedJpeg, 'sof6 marker found, image is coded diff. progressive');
    $C7:
      LeptonFail(lecUnsupportedJpeg, 'sof7 marker found, image is coded diff. lossless');
    $C9:
      LeptonFail(lecUnsupportedJpeg, 'sof9 marker found, image is coded arithm. sequential');
    $CA:
      LeptonFail(lecUnsupportedJpeg, 'sof10 marker found, image is coded arithm. progressive');
    $CB:
      LeptonFail(lecUnsupportedJpeg, 'sof11 marker found, image is coded arithm. lossless');
    $CD:
      LeptonFail(lecUnsupportedJpeg, 'sof13 marker found, image is coded arithm. diff. sequential');
    $CE:
      LeptonFail(lecUnsupportedJpeg, 'sof14 marker found, image is coded arithm. diff. progressive');
    $CF:
      LeptonFail(lecUnsupportedJpeg, 'sof15 marker found, image is coded arithm. diff. lossless');

    $E0..$EF, $FE:
      begin
      end;

    JPEG_RST0, $D1, $D2, $D3, $D4, $D5, $D6, $D7:
      LeptonFail(lecUnsupportedJpeg, 'rst marker found out of place');

    JPEG_SOI:
      LeptonFail(lecUnsupportedJpeg, 'soi marker found out of place');

    JPEG_EOI:
      LeptonFail(lecUnsupportedJpeg, 'eoi marker found out of place');

  else
    LeptonFail(lecUnsupportedJpeg, 'unknown marker found: FF ' + IntToHex(BType, 2));
  end;
end;

function ParseJpegHeader(Stream: TStream; const EnabledFeatures: TEnabledFeatures;
  JpegHeader: TJpegHeader; var RInfo: TReconstructionInfo): Boolean;
var
  Raw: TMemoryStream;
  OldLen, NewLen: SizeInt;
begin
  if JpegHeader = nil then
    LeptonFail(lecAssertionFailure, 'ParseJpegHeader requires a header object');

  Raw := TMemoryStream.Create;
  try
    Result := JpegHeader.Parse(Stream, EnabledFeatures, Raw);
    OldLen := Length(RInfo.RawJpegHeader);

    if Result then
    begin
      SetLength(RInfo.RawJpegHeader, OldLen + Raw.Size);
      if Raw.Size > 0 then
      begin
        Raw.Position := 0;
        Raw.ReadBuffer(RInfo.RawJpegHeader[OldLen], Raw.Size);
      end;
    end
    else
    begin
      if Raw.Size > 2 then
        NewLen := OldLen + Raw.Size - 2
      else
        NewLen := OldLen;
      SetLength(RInfo.RawJpegHeader, NewLen);
      if Raw.Size > 2 then
      begin
        Raw.Position := 0;
        Raw.ReadBuffer(RInfo.RawJpegHeader[OldLen], Raw.Size - 2);
      end;
    end;
  finally
    Raw.Free;
  end;
end;

end.
