unit JpegWrite;

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
  LeptonConsts, LeptonErrors, LeptonHelpers,
  JpegCodes, JpegBitStream, JpegBlockImage, JpegHeader, JpegHuffman,
  JpegPositionState, JpegRowSpec;

procedure EncodeBlockSeq(BitWriter: TJpegBitWriter; const DCTable, ACTable: THuffCodes;
  const Block: TAlignedBlock);

function JpegWriteEntireScan(const ImageData: TBlockBasedImageArray; JpegHeader: TJpegHeader;
  const RInfo: TReconstructionInfo; CurrentScanIndex: SizeInt): TBytes;

function JpegWriteBaselineRowRange(EncodedLength: SizeInt; const RestartInfo: TRestartSegmentCodingInfo;
  const ImageData: TBlockBasedImageArray; JpegHeader: TJpegHeader;
  const RInfo: TReconstructionInfo): TBytes;

type
  PRestartSegmentCodingInfo = ^TRestartSegmentCodingInfo;

  TJpegIncrementalWriter = class
  private
    FLastDC: TLastDCArray;
    FHuffW: TJpegBitWriter;
    FReconstructionInfo: TReconstructionInfo;
    FJpegHeader: TJpegHeader;
    FCapacity: SizeInt;
    FCurrentScanIndex: SizeInt;
  public
    constructor Create(Capacity: SizeInt; const ReconstructionInfo: TReconstructionInfo;
      RestartInfo: PRestartSegmentCodingInfo; JpegHeader: TJpegHeader; CurrentScanIndex: SizeInt);
    destructor Destroy; override;
    function AmountBuffered: SizeInt;
    function ProcessRow(const CurRow: TRowSpec; const ImageData: TBlockBasedImageArray): Boolean;
    function DetachBuffer: TBytes;
  end;

implementation

type
  TByteDynArray = array of Byte;

function AbsSmallIntToWord(V: SmallInt): Word; inline;
var
  I: LongInt;
begin
  I := V;
  if I < 0 then
    I := -I;
  Result := Word(I);
end;

function DivPow2(V: SmallInt; P: Byte): SmallInt; inline;
var
  I: LongInt;
begin
  // Rust: (if v < 0 { v + ((1<<p)-1) } else { v }) >> p  -- arithmetic shift, not div.
  I := V;
  if I < 0 then
    Inc(I, (LongInt(1) shl P) - 1);
  Result := SmallInt(SarLongint(I, P));
end;


function ArithmeticShiftRightSmall(V: SmallInt; P: Byte): SmallInt; inline;
begin
  // Rust uses `i16 >> cs_sal` which is an arithmetic (floor) shift, not a
  // truncating division. SarLongint preserves the sign and rounds toward -inf.
  Result := SmallInt(SarLongint(LongInt(V), P));
end;

function EncodeEOBRunBits(S: Byte; V: Word): Word; inline;
begin
  Result := V - (Word(1) shl S);
end;

procedure WriteCoef(BitWriter: TJpegBitWriter; IsNeg: Boolean; AbsCoef: Word; Z: LongWord;
  const Table: THuffCodes);
var
  S: LongWord;
  HC: LongWord;
  Index: LongWord;
  Val: LongWord;
  NewBits: LongWord;
begin
  S := U32BitLength(AbsCoef);
  HC := (Z shl 4) or S;
  if HC > 255 then
    LeptonFail(lecUnsupportedJpeg, 'invalid coefficient huffman selector');

  Index := HC;
  if IsNeg then
    Inc(Index, 256);

  Val := Table.CValShiftS[Index] xor LongWord(AbsCoef);
  NewBits := Table.CLenPlusS[HC];
  BitWriter.WriteBits(Val, NewBits);
end;

procedure EncodeBlockSeq(BitWriter: TJpegBitWriter; const DCTable, ACTable: THuffCodes;
  const Block: TAlignedBlock);
var
  B: TBlockCoefficients;
  BPos: SizeInt;
  Zeros: LongWord;
  V: SmallInt;
begin
  B := Block.RawData;

  WriteCoef(BitWriter, B[0] < 0, AbsSmallIntToWord(B[0]), 0, DCTable);

  BPos := 1;
  while BPos < 64 do
  begin
    Zeros := 0;
    while (BPos < 64) and (B[BPos] = 0) do
    begin
      Inc(Zeros);
      Inc(BPos);
    end;

    if BPos >= 64 then
      Break;

    while Zeros > 15 do
    begin
      WriteCoef(BitWriter, False, 0, 15, ACTable); // symbol F0, zero-size coefficient
      Dec(Zeros, 16);
    end;

    V := B[BPos];
    WriteCoef(BitWriter, V < 0, AbsSmallIntToWord(V), Zeros, ACTable);
    Inc(BPos);
  end;

  if BPos < 64 then
    LeptonFail(lecAssertionFailure, 'unexpected sequential block position');

  // EOB is needed unless the last coefficient was emitted exactly at position 63.
  if (B[63] = 0) then
    BitWriter.WriteBits(ACTable.CVal[$00], ACTable.CLen[$00]);
end;

procedure EncodeCRBits(BitWriter: TJpegBitWriter; var CorrectionBits: TByteDynArray);
var
  I: SizeInt;
begin
  for I := 0 to Length(CorrectionBits) - 1 do
    BitWriter.WriteBits(CorrectionBits[I], 1);
  SetLength(CorrectionBits, 0);
end;

procedure AppendCorrectionBit(var CorrectionBits: TByteDynArray; B: Byte);
var
  N: SizeInt;
begin
  N := Length(CorrectionBits);
  SetLength(CorrectionBits, N + 1);
  CorrectionBits[N] := B and 1;
end;

procedure EncodeEOBRun(BitWriter: TJpegBitWriter; const ACTable: THuffCodes;
  var State: TJpegPositionState);
var
  S: Byte;
  N: Word;
  HC: Byte;
begin
  if State.EOBRun > 0 then
  begin
    if State.EOBRun > ACTable.MaxEOBRun then
      LeptonFail(lecUnsupportedJpeg, 'EOB run exceeds huffman table capacity');

    S := U16BitLength(State.EOBRun);
    Dec(S);
    N := EncodeEOBRunBits(S, State.EOBRun);
    HC := S shl 4;
    BitWriter.WriteBits(ACTable.CVal[HC], ACTable.CLen[HC]);
    BitWriter.WriteBits(N, S);
    State.EOBRun := 0;
  end;
end;

procedure EncodeACProgressiveFirstStage(BitWriter: TJpegBitWriter; const ACTable: THuffCodes;
  const Block: TBlockCoefficients; var State: TJpegPositionState; ScanFrom, ScanTo: Byte);
var
  BPos: Byte;
  Z: LongWord;
  Tmp: SmallInt;
begin
  Z := 0;
  for BPos := ScanFrom to ScanTo do
  begin
    Tmp := Block[BPos];
    if Tmp <> 0 then
    begin
      EncodeEOBRun(BitWriter, ACTable, State);
      while Z >= 16 do
      begin
        BitWriter.WriteBits(ACTable.CVal[$F0], ACTable.CLen[$F0]);
        Dec(Z, 16);
      end;

      WriteCoef(BitWriter, Tmp < 0, AbsSmallIntToWord(Tmp), Z, ACTable);
      Z := 0;
    end
    else
      Inc(Z);
  end;

  if Z > 0 then
  begin
    if ACTable.MaxEOBRun = 0 then
      LeptonFail(lecUnsupportedJpeg, 'there must be at least one EOB symbol run in the huffman table to encode EOBs');
    Inc(State.EOBRun);
    if State.EOBRun = ACTable.MaxEOBRun then
      EncodeEOBRun(BitWriter, ACTable, State);
  end;
end;

procedure EncodeACProgressiveSuccessiveApprox(BitWriter: TJpegBitWriter; const ACTable: THuffCodes;
  const Block: TBlockCoefficients; var State: TJpegPositionState; ScanFrom, ScanTo: Byte;
  var CorrectionBits: TByteDynArray);
var
  EOB, BPos: Integer;
  Z: LongWord;
  Tmp: SmallInt;
begin
  EOB := ScanFrom;
  BPos := ScanTo;
  while BPos >= ScanFrom do
  begin
    if (Block[BPos] = 1) or (Block[BPos] = -1) then
    begin
      EOB := BPos + 1;
      Break;
    end;
    Dec(BPos);
  end;

  if (EOB > ScanFrom) and (State.EOBRun > 0) then
  begin
    EncodeEOBRun(BitWriter, ACTable, State);
    EncodeCRBits(BitWriter, CorrectionBits);
  end;

  Z := 0;
  for BPos := ScanFrom to EOB - 1 do
  begin
    Tmp := Block[BPos];
    if Tmp = 0 then
    begin
      Inc(Z);
      if Z = 16 then
      begin
        BitWriter.WriteBits(ACTable.CVal[$F0], ACTable.CLen[$F0]);
        EncodeCRBits(BitWriter, CorrectionBits);
        Z := 0;
      end;
    end
    else if (Tmp = 1) or (Tmp = -1) then
    begin
      WriteCoef(BitWriter, Tmp < 0, AbsSmallIntToWord(Tmp), Z, ACTable);
      EncodeCRBits(BitWriter, CorrectionBits);
      Z := 0;
    end
    else
      AppendCorrectionBit(CorrectionBits, Byte(Tmp and 1));
  end;

  for BPos := EOB to ScanTo do
    if Block[BPos] <> 0 then
      AppendCorrectionBit(CorrectionBits, Byte(Block[BPos] and 1));

  if EOB <= ScanTo then
  begin
    if ACTable.MaxEOBRun = 0 then
      LeptonFail(lecUnsupportedJpeg, 'there must be at least one EOB symbol run in the huffman table to encode EOBs');
    Inc(State.EOBRun);
    if State.EOBRun = ACTable.MaxEOBRun then
    begin
      EncodeEOBRun(BitWriter, ACTable, State);
      EncodeCRBits(BitWriter, CorrectionBits);
    end;
  end;
end;

function RecodeOneMCURow(BitWriter: TJpegBitWriter; MCU: LongWord; var LastDC: TLastDCArray;
  const Framebuffer: TBlockBasedImageArray; JF: TJpegHeader; const RInfo: TReconstructionInfo;
  CurrentScanIndex: SizeInt): Boolean;
var
  State: TJpegPositionState;
  CumulativeResetMarkers: LongWord;
  EndOfRow: Boolean;
  CorrectionBits: TByteDynArray;
  Sta: TJpegDecodeStatus;
  CurrentBlock: TAlignedBlock;
  Block: TAlignedBlock;
  RawBlock: TBlockCoefficients;
  OldMCU: LongWord;
  DC, Tmp, V: SmallInt;
  BPos: Byte;
  RST: Byte;
begin
  State := TJpegPositionState.Init(JF, MCU);
  CumulativeResetMarkers := State.GetCumulativeResetMarkers(JF);
  EndOfRow := False;
  SetLength(CorrectionBits, 0);

  while not EndOfRow do
  begin
    Sta := jdsDecodeInProgress;

    while Sta = jdsDecodeInProgress do
    begin
      CurrentBlock := Framebuffer[State.GetCmp].GetBlock(State.GetDPos);
      OldMCU := State.GetMCU;

      if JF.JpegType = jtSequential then
      begin
        Block := CurrentBlock.ZigZagFromTransposed;
        RawBlock := Block.RawData;
        DC := RawBlock[0];
        RawBlock[0] := SmallInt(RawBlock[0] - LastDC[State.GetCmp]);
        LastDC[State.GetCmp] := DC;
        Block.RawData := RawBlock;

        EncodeBlockSeq(BitWriter, JF.GetHuffDCCodes(State.GetCmp), JF.GetHuffACCodes(State.GetCmp), Block);
        Sta := State.NextMCUPos(JF);
      end
      else if JF.CSTo = 0 then
      begin
        if JF.CSSAH = 0 then
        begin
          Tmp := ArithmeticShiftRightSmall(CurrentBlock.GetTransposedFromZigZag(0), JF.CSSAL);
          V := SmallInt(Tmp - LastDC[State.GetCmp]);
          LastDC[State.GetCmp] := Tmp;
          WriteCoef(BitWriter, V < 0, AbsSmallIntToWord(V), 0, JF.GetHuffDCCodes(State.GetCmp));
        end
        else
          BitWriter.WriteBits(ArithmeticShiftRightSmall(CurrentBlock.GetTransposedFromZigZag(0), JF.CSSAL) and 1, 1);

        Sta := State.NextMCUPos(JF);
      end
      else
      begin
        FillChar(RawBlock, SizeOf(RawBlock), 0);
        for BPos := JF.CSFrom to JF.CSTo do
          RawBlock[BPos] := DivPow2(CurrentBlock.GetTransposedFromZigZag(BPos), JF.CSSAL);

        if JF.CSSAH = 0 then
        begin
          EncodeACProgressiveFirstStage(BitWriter, JF.GetHuffACCodes(State.GetCmp), RawBlock,
            State, JF.CSFrom, JF.CSTo);
          Sta := State.NextMCUPos(JF);
          if Sta <> jdsDecodeInProgress then
            EncodeEOBRun(BitWriter, JF.GetHuffACCodes(State.GetCmp), State);
        end
        else
        begin
          EncodeACProgressiveSuccessiveApprox(BitWriter, JF.GetHuffACCodes(State.GetCmp), RawBlock,
            State, JF.CSFrom, JF.CSTo, CorrectionBits);
          Sta := State.NextMCUPos(JF);
          if Sta <> jdsDecodeInProgress then
          begin
            EncodeEOBRun(BitWriter, JF.GetHuffACCodes(State.GetCmp), State);
            EncodeCRBits(BitWriter, CorrectionBits);
          end;
        end;
      end;

      if (JF.MCUH <> 0) and ((State.GetMCU mod JF.MCUH) = 0) and (OldMCU <> State.GetMCU) then
      begin
        EndOfRow := True;
        if Sta = jdsDecodeInProgress then
        begin
          // completed only MCU aligned row, not reset interval so don't emit anything special
          Result := False;
          Exit;
        end;
      end;
    end;

    if RInfo.HasPadBit then
      BitWriter.Pad(RInfo.PadBit)
    else
      BitWriter.Pad(0);

    if not BitWriter.HasNoRemainder then
      LeptonFail(lecAssertionFailure, 'JPEG writer should not have bit remainder after padding');

    if Sta = jdsScanCompleted then
    begin
      Result := True;
      Exit;
    end
    else if Sta = jdsRestartIntervalExpired then
    begin
      if JF.RSTI > 0 then
      begin
        if (Length(RInfo.RstCnt) = 0) or (not RInfo.RstCntSet) or
           (CumulativeResetMarkers < RInfo.RstCnt[CurrentScanIndex]) then
        begin
          RST := JPEG_RST0 + Byte(CumulativeResetMarkers and 7);
          BitWriter.WriteByteUnescaped($FF);
          BitWriter.WriteByteUnescaped(RST);
          Inc(CumulativeResetMarkers);
        end;

        State.ResetRSTW(JF);
        FillChar(LastDC, SizeOf(LastDC), 0);
      end;
    end
    else
      LeptonFail(lecAssertionFailure, 'unexpected JPEG writer state');
  end;

  Result := False;
end;

function BuildDefaultMaxCodedHeights(const ImageData: TBlockBasedImageArray): TLongWordDynArray;
var
  I: SizeInt;
begin
  SetLength(Result, Length(ImageData));
  for I := 0 to Length(ImageData) - 1 do
    Result[I] := ImageData[I].OriginalHeight;
end;

constructor TJpegIncrementalWriter.Create(Capacity: SizeInt; const ReconstructionInfo: TReconstructionInfo;
  RestartInfo: PRestartSegmentCodingInfo; JpegHeader: TJpegHeader; CurrentScanIndex: SizeInt);
begin
  inherited Create;
  FillChar(FLastDC, SizeOf(FLastDC), 0);
  FHuffW := TJpegBitWriter.Create;
  FReconstructionInfo := ReconstructionInfo;
  FJpegHeader := JpegHeader;
  FCapacity := Capacity;
  FCurrentScanIndex := CurrentScanIndex;

  if RestartInfo <> nil then
  begin
    FLastDC := RestartInfo^.LastDC;
    FHuffW.ResetFromOverhangByteAndNumBits(RestartInfo^.OverhangByte, RestartInfo^.NumOverhangBits);
  end;
end;

destructor TJpegIncrementalWriter.Destroy;
begin
  FHuffW.Free;
  inherited Destroy;
end;

function TJpegIncrementalWriter.AmountBuffered: SizeInt;
begin
  Result := FHuffW.AmountBuffered;
end;

function TJpegIncrementalWriter.ProcessRow(const CurRow: TRowSpec; const ImageData: TBlockBasedImageArray): Boolean;
begin
  if CurRow.LastRowToCompleteMCU then
  begin
    FHuffW.EnsureSpace(FCapacity);
    Result := RecodeOneMCURow(FHuffW, CurRow.MCURowIndex * FJpegHeader.MCUH, FLastDC,
      ImageData, FJpegHeader, FReconstructionInfo, FCurrentScanIndex);
  end
  else
    Result := False;
end;

function TJpegIncrementalWriter.DetachBuffer: TBytes;
begin
  Result := FHuffW.DetachBuffer;
end;

function JpegWriteEntireScan(const ImageData: TBlockBasedImageArray; JpegHeader: TJpegHeader;
  const RInfo: TReconstructionInfo; CurrentScanIndex: SizeInt): TBytes;
var
  IncWrite: TJpegIncrementalWriter;
  MaxCodedHeights: TLongWordDynArray;
  DecodeIndex: LongWord;
  CurRow: TRowSpec;
begin
  IncWrite := TJpegIncrementalWriter.Create(128 * 1024, RInfo, nil, JpegHeader, CurrentScanIndex);
  try
    MaxCodedHeights := BuildDefaultMaxCodedHeights(ImageData);
    DecodeIndex := 0;
    while True do
    begin
      CurRow := TRowSpec.GetRowSpecFromIndex(DecodeIndex, ImageData, JpegHeader.MCUV, MaxCodedHeights);
      Inc(DecodeIndex);

      if CurRow.Done then
        Break;
      if CurRow.Skip then
        Continue;
      if IncWrite.ProcessRow(CurRow, ImageData) then
        Break;
    end;
    Result := IncWrite.DetachBuffer;
  finally
    IncWrite.Free;
  end;
end;

function JpegWriteBaselineRowRange(EncodedLength: SizeInt; const RestartInfo: TRestartSegmentCodingInfo;
  const ImageData: TBlockBasedImageArray; JpegHeader: TJpegHeader;
  const RInfo: TReconstructionInfo): TBytes;
var
  IncWrite: TJpegIncrementalWriter;
  MaxCodedHeights: TLongWordDynArray;
  DecodeIndex: LongWord;
  CurRow: TRowSpec;
begin
  IncWrite := TJpegIncrementalWriter.Create(EncodedLength, RInfo, @RestartInfo, JpegHeader, 0);
  try
    MaxCodedHeights := BuildDefaultMaxCodedHeights(ImageData);
    DecodeIndex := 0;
    while True do
    begin
      CurRow := TRowSpec.GetRowSpecFromIndex(DecodeIndex, ImageData, JpegHeader.MCUV, MaxCodedHeights);
      Inc(DecodeIndex);

      if CurRow.Done then
        Break;
      if CurRow.Skip then
        Continue;
      if IncWrite.ProcessRow(CurRow, ImageData) then
        Break;
    end;
    Result := IncWrite.DetachBuffer;
  finally
    IncWrite.Free;
  end;
end;

end.
