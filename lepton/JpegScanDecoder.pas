unit JpegScanDecoder;

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
  JpegBitStream, JpegBlockImage, JpegHeader, JpegHuffman, JpegPositionState;

type
  TBlockBasedImageArray = array of TBlockBasedImage;

  TRestartPartition = record
    Offset: Int64;
    CodingInfo: TRestartSegmentCodingInfo;
  end;

  TRestartPartitionArray = array of TRestartPartition;

function DecodeBlockSeq(BitReader: TJpegBitReader; const DCTree, ACTree: THuffTree;
  var Block: TBlockCoefficients): SizeInt;

procedure ReadFirstScan(JF: TJpegHeader; Stream: TStream; var Partitions: TRestartPartitionArray;
  var ImageData: TBlockBasedImageArray; var RInfo: TReconstructionInfo);

procedure ReadProgressiveScan(JF: TJpegHeader; Stream: TStream; var ImageData: TBlockBasedImageArray;
  var RInfo: TReconstructionInfo);

implementation

procedure AddPartition(var Partitions: TRestartPartitionArray; Offset: Int64;
  const CodingInfo: TRestartSegmentCodingInfo);
var
  N: SizeInt;
begin
  N := Length(Partitions);
  SetLength(Partitions, N + 1);
  Partitions[N].Offset := Offset;
  Partitions[N].CodingInfo := CodingInfo;
end;

function MaxLW(A, B: LongWord): LongWord; inline;
begin
  if A > B then
    Result := A
  else
    Result := B;
end;

function MaxByte(A, B: Byte): Byte; inline;
begin
  if A > B then
    Result := A
  else
    Result := B;
end;

procedure ReadAndStoreFillBits(BitReader: TJpegBitReader; var RInfo: TReconstructionInfo);
var
  Pad: Integer;
begin
  if RInfo.HasPadBit then
    Pad := RInfo.PadBit
  else
    Pad := -1;

  BitReader.ReadAndVerifyFillBits(Pad);

  if Pad >= 0 then
  begin
    RInfo.HasPadBit := True;
    RInfo.PadBit := Byte(Pad);
  end;
end;

function NextHuffCode(BitReader: TJpegBitReader; const CTree: THuffTree): Byte;
var
  Node: Word;
  Bit: Word;
begin
  Node := 0;

  while Node < 256 do
  begin
    Bit := BitReader.ReadBits(1);
    Node := CTree.Node[Node, Bit];
  end;

  if Node = $FFFF then
    LeptonFail(lecUnsupportedJpeg, 'illegal Huffman code detected');

  Result := Byte(Node - 256);
end;

function ReadCoef(BitReader: TJpegBitReader; const Tree: THuffTree;
  out ZeroRun: SizeInt; out Coef: SmallInt): Boolean;
var
  HC: Byte;
  Code, CodeLen: Byte;
  PeekValue: Byte;
  PeekLen: LongWord;
  LiteralBits: Byte;
  Value: Word;
begin
  while True do
  begin
    BitReader.Peek(PeekValue, PeekLen);
    Code := Tree.PeekSymbol[PeekValue];
    CodeLen := Tree.PeekLength[PeekValue];

    if LongWord(CodeLen) <= PeekLen then
    begin
      HC := Code;
      BitReader.Advance(CodeLen);
      Break;
    end
    else if PeekLen < 8 then
      BitReader.FillRegister(8)
    else
    begin
      HC := NextHuffCode(BitReader, Tree);
      Break;
    end;
  end;

  if HC <> 0 then
  begin
    ZeroRun := LBits(HC, 4);
    LiteralBits := RBits(HC, 4);
    Value := BitReader.ReadBits(LiteralBits);
    Coef := DevLI(LiteralBits, Value);
    Result := True;
  end
  else
  begin
    ZeroRun := 0;
    Coef := 0;
    Result := False;
  end;
end;

function ReadDC(BitReader: TJpegBitReader; const Tree: THuffTree): SmallInt;
var
  Z: SizeInt;
  Coef: SmallInt;
begin
  if not ReadCoef(BitReader, Tree, Z, Coef) then
    Exit(0);

  if Z <> 0 then
    LeptonFail(lecUnsupportedJpeg, 'not expecting non-zero run in DC coefficient');

  Result := Coef;
end;

function DecodeBlockSeq(BitReader: TJpegBitReader; const DCTree, ACTree: THuffTree;
  var Block: TBlockCoefficients): SizeInt;
var
  EOB, BPos, Z: SizeInt;
  Coef: SmallInt;
  EOFailFixup: Boolean;
begin
  FillChar(Block, SizeOf(Block), 0);
  EOB := 64;

  Block[0] := ReadDC(BitReader, DCTree);

  EOFailFixup := False;
  BPos := 1;
  while BPos < 64 do
  begin
    if ReadCoef(BitReader, ACTree, Z, Coef) then
    begin
      if Z + BPos >= 64 then
      begin
        EOFailFixup := True;
        Break;
      end;

      Inc(BPos, Z);
      Block[BPos] := Coef;
      Inc(BPos);
    end
    else
    begin
      EOB := BPos;
      Break;
    end;
  end;

  if EOFailFixup then
  begin
    if not BitReader.IsEOF then
      LeptonFail(lecUnsupportedJpeg, 'If 0run is longer than the block must be truncated');

    while BPos < EOB do
    begin
      Block[BPos] := 0;
      Inc(BPos);
    end;

    if EOB > 0 then
      Block[EOB - 1] := 1;
  end;

  Result := EOB;
end;

function DecodeEOBRunBits(S: Byte; N: Word): Word; inline;
begin
  Result := N + (Word(1) shl S);
end;

function DecodeACProgressiveFirstStage(BitReader: TJpegBitReader; const ACTree: THuffTree;
  var Block: TBlockCoefficients; var State: TJpegPositionState; ScanFrom, ScanTo: Byte): Byte;
var
  BPos, Z, S, L, R: Byte;
  HC: Byte;
  N: Word;
begin
  if State.EOBRun <> 0 then
    LeptonFail(lecAssertionFailure, 'DecodeACProgressiveFirstStage requires EOBRun = 0');

  BPos := ScanFrom;
  while BPos <= ScanTo do
  begin
    HC := NextHuffCode(BitReader, ACTree);
    L := LBits(HC, 4);
    R := RBits(HC, 4);

    if (L = 15) or (R > 0) then
    begin
      Z := L;
      S := R;
      N := BitReader.ReadBits(S);
      if Z + BPos > ScanTo then
        LeptonFail(lecUnsupportedJpeg, 'run is too long');

      while Z > 0 do
      begin
        Block[BPos] := 0;
        Dec(Z);
        Inc(BPos);
      end;

      Block[BPos] := DevLI(S, N);
      Inc(BPos);
    end
    else
    begin
      S := L;
      N := BitReader.ReadBits(S);
      State.EOBRun := DecodeEOBRunBits(S, N);
      Dec(State.EOBRun);
      Break;
    end;
  end;

  Result := BPos;
end;

procedure DecodeEOBRunSuccessiveApprox(BitReader: TJpegBitReader; var Block: TBlockCoefficients;
  var State: TJpegPositionState; ScanFrom, ScanTo: Byte);
var
  BPos: SizeInt;
  N: SmallInt;
begin
  if State.EOBRun = 0 then
    LeptonFail(lecAssertionFailure, 'DecodeEOBRunSuccessiveApprox requires EOBRun > 0');

  for BPos := ScanFrom to ScanTo do
  begin
    if Block[BPos] <> 0 then
    begin
      N := SmallInt(BitReader.ReadBits(1));
      if Block[BPos] > 0 then
        Block[BPos] := N
      else
        Block[BPos] := -N;
    end;
  end;

  Dec(State.EOBRun);
end;

function DecodeACProgressiveSuccessiveApprox(BitReader: TJpegBitReader; const ACTree: THuffTree;
  var Block: TBlockCoefficients; var State: TJpegPositionState; ScanFrom, ScanTo: Byte): Byte;
var
  BPos, EOB, Z, S, L, R: Byte;
  HC: Byte;
  N: Word;
  V: SmallInt;
begin
  if State.EOBRun <> 0 then
    LeptonFail(lecAssertionFailure, 'DecodeACProgressiveSuccessiveApprox requires EOBRun = 0');

  BPos := ScanFrom;
  EOB := ScanTo;

  while BPos <= ScanTo do
  begin
    HC := NextHuffCode(BitReader, ACTree);
    L := LBits(HC, 4);
    R := RBits(HC, 4);

    if (L = 15) or (R > 0) then
    begin
      Z := L;
      S := R;

      if S = 0 then
        V := 0
      else if S = 1 then
      begin
        N := BitReader.ReadBits(1);
        if N = 0 then
          V := -1
        else
          V := 1;
      end
      else
        LeptonFail(lecUnsupportedJpeg, 'decoding error');

      while True do
      begin
        if Block[BPos] = 0 then
        begin
          if Z > 0 then
            Dec(Z)
          else
          begin
            Block[BPos] := V;
            Inc(BPos);
            Break;
          end;
        end
        else
        begin
          N := BitReader.ReadBits(1);
          if Block[BPos] > 0 then
            Block[BPos] := SmallInt(N)
          else
            Block[BPos] := -SmallInt(N);
        end;

        if BPos >= ScanTo then
          LeptonFail(lecUnsupportedJpeg, 'decoding error');

        Inc(BPos);
      end;
    end
    else
    begin
      EOB := BPos;
      S := L;
      N := BitReader.ReadBits(S);
      State.EOBRun := DecodeEOBRunBits(S, N);
      DecodeEOBRunSuccessiveApprox(BitReader, Block, State, BPos, ScanTo);
      Break;
    end;
  end;

  Result := EOB;
end;

function DecodeBaselineRST(var State: TJpegPositionState; BitReader: TJpegBitReader;
  var ImageData: TBlockBasedImageArray; var DoHandoff: Boolean; JF: TJpegHeader;
  var RInfo: TReconstructionInfo; var Partitions: TRestartPartitionArray): TJpegDecodeStatus;
var
  LastDC: TLastDCArray;
  BitsAlreadyRead, ByteBeingRead: Byte;
  Block: TBlockCoefficients;
  BlockTR: TAlignedBlock;
  EOB: SizeInt;
  OldMCU: LongWord;
begin
  JF.VerifyHuffmanTable(True, True);
  FillChar(LastDC, SizeOf(LastDC), 0);

  Result := jdsDecodeInProgress;
  while Result = jdsDecodeInProgress do
  begin
    if DoHandoff then
    begin
      BitReader.Overhang(BitsAlreadyRead, ByteBeingRead);
      AddPartition(Partitions, BitReader.StreamPosition,
        TRestartSegmentCodingInfo.Create(ByteBeingRead, BitsAlreadyRead, LastDC, State.GetMCU, JF));
      DoHandoff := False;
    end;

    if not BitReader.IsEOF then
      RInfo.MaxDPos[State.GetCmp] := MaxLW(State.GetDPos, RInfo.MaxDPos[State.GetCmp]);

    EOB := DecodeBlockSeq(BitReader, JF.GetHuffDCTree(State.GetCmp), JF.GetHuffACTree(State.GetCmp), Block);

    if (EOB > 1) and (Block[EOB - 1] = 0) then
      LeptonFail(lecUnsupportedJpeg, 'cannot encode image with eob after last 0');

    Block[0] := SmallInt(Block[0] + LastDC[State.GetCmp]);
    LastDC[State.GetCmp] := Block[0];

    BlockTR := TAlignedBlock.ZigZagToTransposed(Block);
    ImageData[State.GetCmp].SetBlockData(State.GetDPos, BlockTR);

    OldMCU := State.GetMCU;
    Result := State.NextMCUPos(JF);

    if (JF.MCUH <> 0) and ((State.GetMCU mod JF.MCUH) = 0) and (OldMCU <> State.GetMCU) then
      DoHandoff := True;

    if BitReader.IsEOF then
    begin
      Result := jdsScanCompleted;
      RInfo.EarlyEOFEncountered := True;
    end;
  end;
end;

procedure ReadFirstScan(JF: TJpegHeader; Stream: TStream; var Partitions: TRestartPartitionArray;
  var ImageData: TBlockBasedImageArray; var RInfo: TReconstructionInfo);
var
  BitReader: TJpegBitReader;
  State: TJpegPositionState;
  DoHandoff: Boolean;
  Sta: TJpegDecodeStatus;
  LastDC: TLastDCArray;
  CurrentBlock: PAlignedBlock;
  Coef: SmallInt;
  V: SmallInt;
  OldMCU: LongWord;
begin
  BitReader := TJpegBitReader.Create(Stream, False);
  try
    State := TJpegPositionState.Init(JF, 0);
    DoHandoff := True;
    Sta := jdsDecodeInProgress;

    while Sta <> jdsScanCompleted do
    begin
      State.ResetRSTW(JF);

      if JF.JpegType = jtSequential then
        Sta := DecodeBaselineRST(State, BitReader, ImageData, DoHandoff, JF, RInfo, Partitions)
      else if (JF.CSTo = 0) and (JF.CSSAH = 0) then
      begin
        JF.VerifyHuffmanTable(True, False);
        FillChar(LastDC, SizeOf(LastDC), 0);

        while Sta = jdsDecodeInProgress do
        begin
          CurrentBlock := ImageData[State.GetCmp].GetBlockPtr(State.GetDPos);

          if DoHandoff then
          begin
            AddPartition(Partitions, 0,
              TRestartSegmentCodingInfo.Create(0, 0, LastDC, State.GetMCU, JF));
            DoHandoff := False;
          end;

          Coef := ReadDC(BitReader, JF.GetHuffDCTree(State.GetCmp));
          V := SmallInt(Coef + LastDC[State.GetCmp]);
          LastDC[State.GetCmp] := V;
          CurrentBlock^.SetTransposedFromZigZag(0, SmallInt(V shl JF.CSSAL));

          OldMCU := State.GetMCU;
          Sta := State.NextMCUPos(JF);

          if (JF.MCUH <> 0) and ((State.GetMCU mod JF.MCUH) = 0) and (OldMCU <> State.GetMCU) then
            DoHandoff := True;
        end;
      end
      else
        LeptonFail(lecUnsupportedJpeg, 'progress must start with DC stage');

      ReadAndStoreFillBits(BitReader, RInfo);

      if Sta = jdsRestartIntervalExpired then
      begin
        BitReader.VerifyResetCode;
        Sta := jdsDecodeInProgress;
      end;
    end;
  finally
    BitReader.Free;
  end;
end;

procedure ReadProgressiveScan(JF: TJpegHeader; Stream: TStream; var ImageData: TBlockBasedImageArray;
  var RInfo: TReconstructionInfo);
var
  BitReader: TJpegBitReader;
  State: TJpegPositionState;
  Sta: TJpegDecodeStatus;
  CurrentBlock: PAlignedBlock;
  Value: SmallInt;
  Block: TBlockCoefficients;
  BPos: Byte;
  EOB: Byte;
begin
  RInfo.MaxSAH := MaxByte(RInfo.MaxSAH, MaxByte(JF.CSSAL, JF.CSSAH));

  BitReader := TJpegBitReader.Create(Stream, False);
  try
    State := TJpegPositionState.Init(JF, 0);
    Sta := jdsDecodeInProgress;

    while Sta <> jdsScanCompleted do
    begin
      State.ResetRSTW(JF);

      if JF.CSTo = 0 then
      begin
        if JF.CSSAH = 0 then
          LeptonFail(lecUnsupportedJpeg, 'progress can''t have two DC first stages');

        JF.VerifyHuffmanTable(True, False);

        while Sta = jdsDecodeInProgress do
        begin
          CurrentBlock := ImageData[State.GetCmp].GetBlockPtr(State.GetDPos);
          Value := SmallInt(BitReader.ReadBits(1));
          CurrentBlock^.SetTransposedFromZigZag(0,
            SmallInt(CurrentBlock^.GetTransposedFromZigZag(0) + (Value shl JF.CSSAL)));
          Sta := State.NextMCUPos(JF);
        end;
      end
      else
      begin
        if (JF.CSFrom = 0) or (JF.CSTo >= 64) or (JF.CSFrom >= JF.CSTo) then
          LeptonFail(lecUnsupportedJpeg,
            Format('progressive encoding range was invalid %d to %d', [JF.CSFrom, JF.CSTo]));

        JF.VerifyHuffmanTable(False, True);

        if JF.CSSAH = 0 then
        begin
          if JF.CSCmpC <> 1 then
            LeptonFail(lecUnsupportedJpeg, 'Progressive AC encoding cannot be interleaved');

          FillChar(Block, SizeOf(Block), 0);
          while Sta = jdsDecodeInProgress do
          begin
            CurrentBlock := ImageData[State.GetCmp].GetBlockPtr(State.GetDPos);

            if State.EOBRun = 0 then
            begin
              EOB := DecodeACProgressiveFirstStage(BitReader, JF.GetHuffACTree(State.GetCmp),
                Block, State, JF.CSFrom, JF.CSTo);
              State.CheckOptimalEOBRun(EOB = JF.CSFrom, JF.GetHuffACCodes(State.GetCmp));

              for BPos := JF.CSFrom to EOB - 1 do
                CurrentBlock^.SetTransposedFromZigZag(BPos, SmallInt(Block[BPos] shl JF.CSSAL));
            end;

            Sta := State.SkipEOBRun(JF);
            if Sta = jdsDecodeInProgress then
              Sta := State.NextMCUPos(JF);
          end;
        end
        else
        begin
          while Sta = jdsDecodeInProgress do
          begin
            CurrentBlock := ImageData[State.GetCmp].GetBlockPtr(State.GetDPos);
            FillChar(Block, SizeOf(Block), 0);

            for BPos := JF.CSFrom to JF.CSTo do
              Block[BPos] := CurrentBlock^.GetTransposedFromZigZag(BPos);

            if State.EOBRun = 0 then
            begin
              EOB := DecodeACProgressiveSuccessiveApprox(BitReader, JF.GetHuffACTree(State.GetCmp),
                Block, State, JF.CSFrom, JF.CSTo);
              State.CheckOptimalEOBRun(EOB = JF.CSFrom, JF.GetHuffACCodes(State.GetCmp));
            end
            else
              DecodeEOBRunSuccessiveApprox(BitReader, Block, State, JF.CSFrom, JF.CSTo);

            for BPos := JF.CSFrom to JF.CSTo do
              CurrentBlock^.SetTransposedFromZigZag(BPos,
                SmallInt(CurrentBlock^.GetTransposedFromZigZag(BPos) + (Block[BPos] shl JF.CSSAL)));

            Sta := State.NextMCUPos(JF);
          end;
        end;
      end;

      ReadAndStoreFillBits(BitReader, RInfo);

      if Sta = jdsRestartIntervalExpired then
      begin
        BitReader.VerifyResetCode;
        Sta := jdsDecodeInProgress;
      end;
    end;
  finally
    BitReader.Free;
  end;
end;

end.
