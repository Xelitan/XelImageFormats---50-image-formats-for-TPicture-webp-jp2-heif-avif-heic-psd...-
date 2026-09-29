unit LeptonModel;

{$mode delphi}
{$H+}
{$R-}
{$Q-}
{$modeswitch advancedrecords}

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//
// Port of `structs/model.rs`. The probability model holds a large set of
//  arithmetic-coding branches. Because every field is a TLeptonBranch (a Word
//  initialised to $0101), the whole model can be initialised in one shot with
//  FillChar(..., $01).

interface

uses
  LeptonErrors, LeptonHelpers, LeptonBranch, VpxBoolCoder, LeptonQuantizationTables;

const
  BLOCK_TYPES = 2;
  NUMERIC_LENGTH_MAX = 12;
  MAX_EXPONENT = 11;
  COEF_BITS = MAX_EXPONENT - 1;            // 10
  NUM_NON_ZERO_7X7_BINS = 9;
  NUM_NON_ZERO_EDGE_BINS = 7;
  RESIDUAL_NOISE_FLOOR_C = 7;
  RTC_D1 = 1 shl (1 + RESIDUAL_NOISE_FLOOR_C);  // 256
  RTC_D2 = 1 + RESIDUAL_NOISE_FLOOR_C - 2;      // 6
  RTC_D3 = 1 shl RESIDUAL_NOISE_FLOOR_C;        // 128

type
  TBranch11 = array[0..MAX_EXPONENT - 1] of TLeptonBranch;
  TBranch10 = array[0..COEF_BITS - 1] of TLeptonBranch;
  TBranch8 = array[0..7] of TLeptonBranch;
  TBranch64 = array[0..63] of TLeptonBranch;
  TBranch3 = array[0..2] of TLeptonBranch;

  TResidualThreshArr = array[0..RTC_D3 - 1] of TLeptonBranch;
  PResidualThreshArr = ^TResidualThreshArr;

  TCounts7x7 = record
    ExponentCounts: array[0..NUMERIC_LENGTH_MAX - 1] of TBranch11;
    ResidualNoiseCounts: TBranch10;
  end;

  TCountsEdge = record
    ExponentCounts: array[0..MAX_EXPONENT - 1] of TBranch11;
    ResidualNoiseCounts: TBranch3;
  end;

  TCountsDC = record
    ExponentCounts: array[0..16] of TBranch11;
    ResidualNoiseCounts: TBranch10;
  end;

  TNumNonZerosCountsT = array[0..7, 0..7] of TBranch8;

  TModelPerColor = record
    NumNonZerosCounts7x7: array[0..NUM_NON_ZERO_7X7_BINS - 1] of TBranch64;
    Counts: array[0..NUM_NON_ZERO_7X7_BINS - 1, 0..48] of TCounts7x7;
    NumNonZerosCounts1x8: TNumNonZerosCountsT;
    NumNonZerosCounts8x1: TNumNonZerosCountsT;
    CountsX: array[0..NUM_NON_ZERO_EDGE_BINS - 1, 0..13] of TCountsEdge;
    ResidualThresholdCounts: array[0..RTC_D1 - 1, 0..RTC_D2 - 1] of TResidualThreshArr;
    SignCounts: array[0..2] of array[0..NUMERIC_LENGTH_MAX - 1] of TLeptonBranch;
  end;

  TModel = record
    PerColor: array[0..BLOCK_TYPES - 1] of TModelPerColor;
    CountsDC: array[0..NUMERIC_LENGTH_MAX - 1] of TCountsDC;
  end;
  PModel = ^TModel;

function NewModel: PModel;
procedure FreeModel(M: PModel);

// 7x7 count
procedure ModelWriteNonZero7x7Count(Writer: TVpxBoolWriter; var MPC: TModelPerColor;
  ContextBin, NumNonZeros7x7: Byte);
function ModelReadNonZero7x7Count(Reader: TVpxBoolReader; var MPC: TModelPerColor;
  ContextBin: Byte): Byte;

// edge count
procedure ModelWriteNonZeroEdgeCount(Writer: TVpxBoolWriter; var MPC: TModelPerColor;
  Horizontal: Boolean; EstEob, NumNonZerosBin, NumNonZerosEdge: Byte);
function ModelReadNonZeroEdgeCount(Reader: TVpxBoolReader; var MPC: TModelPerColor;
  Horizontal: Boolean; EstEob, NumNonZerosBin: Byte): Byte;

// 7x7 inner coefficient
procedure ModelWriteCoef(Writer: TVpxBoolWriter; var MPC: TModelPerColor;
  Coef: SmallInt; Zig49, NumNonZerosBin, BestPriorBitLen: Integer);
function ModelReadCoef(Reader: TVpxBoolReader; var MPC: TModelPerColor;
  Zig49, NumNonZerosBin, BestPriorBitLen: Integer): SmallInt;

// edge coefficient
procedure ModelWriteEdgeCoefficient(Writer: TVpxBoolWriter; var MPC: TModelPerColor;
  const Qt: TQuantizationTables; Coef: SmallInt; Zig15offset: Integer;
  NumNonZerosEdge: Byte; BestPrior: LongInt);
function ModelReadEdgeCoefficient(Reader: TVpxBoolReader; var MPC: TModelPerColor;
  const Qt: TQuantizationTables; Zig15offset: Integer; NumNonZerosEdge: Byte;
  BestPrior: LongInt): SmallInt;

// DC
procedure ModelWriteDc(Writer: TVpxBoolWriter; M: PModel; ColorIndex: Integer;
  Coef: SmallInt; Uncertainty, Uncertainty2: SmallInt);
function ModelReadDc(Reader: TVpxBoolReader; M: PModel; ColorIndex: Integer;
  Uncertainty, Uncertainty2: SmallInt): SmallInt;

implementation

function NewModel: PModel;
begin
  New(Result);
  FillChar(Result^, SizeOf(TModel), $01);
end;

procedure FreeModel(M: PModel);
begin
  Dispose(M);
end;

// ----- shared length/sign/coef helpers -----

procedure WriteLengthSignCoef(Writer: TVpxBoolWriter; Coef: SmallInt;
  var Mag: array of TLeptonBranch; var Sign: TLeptonBranch; var Bits: array of TLeptonBranch);
var
  AbsCoef: Word;
  CoefBitLen: Byte;
begin
  AbsCoef := Word(Abs(LongInt(Coef)));
  CoefBitLen := U16BitLength(AbsCoef);

  if CoefBitLen > Length(Mag) then
    LeptonFail(lecStreamInconsistent, 'coefficient > MAX_EXPONENT');

  Writer.PutUnaryEncoded(CoefBitLen, Mag);
  if Coef <> 0 then
    Writer.PutBit(Coef > 0, Sign);

  if CoefBitLen > 1 then
    Writer.PutNBits(AbsCoef, CoefBitLen - 1, Bits);
end;

function ReadLengthSignCoef(Reader: TVpxBoolReader;
  var Mag: array of TLeptonBranch; var Sign: TLeptonBranch; var Bits: array of TLeptonBranch): SmallInt;
var
  Length_: SizeInt;
  Coef: LongInt;
  Neg: Boolean;
begin
  Length_ := Reader.GetUnaryEncoded(Mag);
  Coef := 0;
  if Length_ <> 0 then
  begin
    Neg := not Reader.GetBit(Sign);
    if Length_ > 1 then
      Coef := Reader.GetNBits(Length_ - 1, Bits);
    Coef := Coef or (LongInt(1) shl (Length_ - 1));
    if Neg then
      Coef := -Coef;
  end;
  Result := SmallInt(Word(Coef and $FFFF));
end;

// ----- 7x7 count -----

procedure ModelWriteNonZero7x7Count(Writer: TVpxBoolWriter; var MPC: TModelPerColor;
  ContextBin, NumNonZeros7x7: Byte);
begin
  Writer.PutGrid(NumNonZeros7x7, MPC.NumNonZerosCounts7x7[ContextBin], 64);
end;

function ModelReadNonZero7x7Count(Reader: TVpxBoolReader; var MPC: TModelPerColor;
  ContextBin: Byte): Byte;
begin
  Result := Byte(Reader.GetGrid(MPC.NumNonZerosCounts7x7[ContextBin], 64));
end;

// ----- edge count -----

procedure ModelWriteNonZeroEdgeCount(Writer: TVpxBoolWriter; var MPC: TModelPerColor;
  Horizontal: Boolean; EstEob, NumNonZerosBin, NumNonZerosEdge: Byte);
begin
  if Horizontal then
    Writer.PutGrid(NumNonZerosEdge, MPC.NumNonZerosCounts8x1[EstEob][NumNonZerosBin], 8)
  else
    Writer.PutGrid(NumNonZerosEdge, MPC.NumNonZerosCounts1x8[EstEob][NumNonZerosBin], 8);
end;

function ModelReadNonZeroEdgeCount(Reader: TVpxBoolReader; var MPC: TModelPerColor;
  Horizontal: Boolean; EstEob, NumNonZerosBin: Byte): Byte;
begin
  if Horizontal then
    Result := Byte(Reader.GetGrid(MPC.NumNonZerosCounts8x1[EstEob][NumNonZerosBin], 8))
  else
    Result := Byte(Reader.GetGrid(MPC.NumNonZerosCounts1x8[EstEob][NumNonZerosBin], 8));
end;

// ----- 7x7 inner coefficient -----

procedure ModelWriteCoef(Writer: TVpxBoolWriter; var MPC: TModelPerColor;
  Coef: SmallInt; Zig49, NumNonZerosBin, BestPriorBitLen: Integer);
begin
  WriteLengthSignCoef(Writer, Coef,
    MPC.Counts[NumNonZerosBin][Zig49].ExponentCounts[BestPriorBitLen],
    MPC.SignCounts[0][0],
    MPC.Counts[NumNonZerosBin][Zig49].ResidualNoiseCounts);
end;

function ModelReadCoef(Reader: TVpxBoolReader; var MPC: TModelPerColor;
  Zig49, NumNonZerosBin, BestPriorBitLen: Integer): SmallInt;
begin
  Result := ReadLengthSignCoef(Reader,
    MPC.Counts[NumNonZerosBin][Zig49].ExponentCounts[BestPriorBitLen],
    MPC.SignCounts[0][0],
    MPC.Counts[NumNonZerosBin][Zig49].ResidualNoiseCounts);
end;

// ----- edge coefficient -----

function GetResidualThresholdCounts(var MPC: TModelPerColor; BestPriorAbs: LongWord;
  MinThreshold, Length_: LongInt): PResidualThreshArr;
var
  Idx1, Idx2: LongInt;
begin
  Idx1 := LongInt((BestPriorAbs and $FFFF) shr MinThreshold);
  if Idx1 > RTC_D1 - 1 then Idx1 := RTC_D1 - 1;
  Idx2 := Length_ - MinThreshold - 2;
  if Idx2 > RTC_D2 - 1 then Idx2 := RTC_D2 - 1;
  Result := @MPC.ResidualThresholdCounts[Idx1][Idx2];
end;

procedure ModelWriteEdgeCoefficient(Writer: TVpxBoolWriter; var MPC: TModelPerColor;
  const Qt: TQuantizationTables; Coef: SmallInt; Zig15offset: Integer;
  NumNonZerosEdge: Byte; BestPrior: LongInt);
var
  Bin: Integer;
  BestPriorAbs: LongWord;
  BestPriorBitLen: Integer;
  AbsCoef: Word;
  Len, MinThreshold, I: LongInt;
  ThreshProb: PResidualThreshArr;
  EncodedSoFar: LongInt;
  CurBit: Boolean;
begin
  Bin := NumNonZerosEdge - 1;
  BestPriorAbs := LongWord(Abs(Int64(BestPrior)));
  BestPriorBitLen := U32BitLength(BestPriorAbs);
  if BestPriorBitLen > MAX_EXPONENT - 1 then BestPriorBitLen := MAX_EXPONENT - 1;

  AbsCoef := Word(Abs(LongInt(Coef)));
  Len := U16BitLength(AbsCoef);

  if Len > MAX_EXPONENT then
    LeptonFail(lecStreamInconsistent, 'CoefficientOutOfRange');

  Writer.PutUnaryEncoded(Len, MPC.CountsX[Bin][Zig15offset].ExponentCounts[BestPriorBitLen]);

  if Coef <> 0 then
  begin
    Writer.PutBit(Coef >= 0,
      MPC.SignCounts[CalcSignIndex(SmallInt(Word(BestPrior and $FFFF)))][BestPriorBitLen]);

    if Len > 1 then
    begin
      MinThreshold := Qt.MinNoiseThreshold(Zig15offset);
      I := Len - 2;
      if I >= MinThreshold then
      begin
        ThreshProb := GetResidualThresholdCounts(MPC, BestPriorAbs, MinThreshold, Len);
        EncodedSoFar := 1;
        while I >= MinThreshold do
        begin
          CurBit := (AbsCoef and (Word(1) shl I)) <> 0;
          Writer.PutBit(CurBit, ThreshProb^[EncodedSoFar]);
          EncodedSoFar := EncodedSoFar shl 1;
          if CurBit then
            EncodedSoFar := EncodedSoFar or 1;
          if EncodedSoFar > RTC_D3 - 1 then
            EncodedSoFar := RTC_D3 - 1;
          Dec(I);
        end;
      end;

      if I >= 0 then
        Writer.PutNBits(AbsCoef, I + 1, MPC.CountsX[Bin][Zig15offset].ResidualNoiseCounts);
    end;
  end;
end;

function ModelReadEdgeCoefficient(Reader: TVpxBoolReader; var MPC: TModelPerColor;
  const Qt: TQuantizationTables; Zig15offset: Integer; NumNonZerosEdge: Byte;
  BestPrior: LongInt): SmallInt;
var
  Bin: Integer;
  BestPriorAbs: LongWord;
  BestPriorBitLen: Integer;
  Len, MinThreshold, I: LongInt;
  Coef: LongInt;
  Neg: Boolean;
  ThreshProb: PResidualThreshArr;
  DecodedSoFar: LongInt;
  CurBit: LongInt;
begin
  Bin := NumNonZerosEdge - 1;
  BestPriorAbs := LongWord(Abs(Int64(BestPrior)));
  BestPriorBitLen := U32BitLength(BestPriorAbs);
  if BestPriorBitLen > MAX_EXPONENT - 1 then BestPriorBitLen := MAX_EXPONENT - 1;

  Len := Reader.GetUnaryEncoded(MPC.CountsX[Bin][Zig15offset].ExponentCounts[BestPriorBitLen]);

  Coef := 0;
  if Len <> 0 then
  begin
    Neg := not Reader.GetBit(
      MPC.SignCounts[CalcSignIndex(SmallInt(Word(BestPrior and $FFFF)))][BestPriorBitLen]);
    Coef := 1;

    if Len > 1 then
    begin
      MinThreshold := Qt.MinNoiseThreshold(Zig15offset);
      I := Len - 2;
      if I >= MinThreshold then
      begin
        ThreshProb := GetResidualThresholdCounts(MPC, BestPriorAbs, MinThreshold, Len);
        DecodedSoFar := 1;
        while I >= MinThreshold do
        begin
          if Reader.GetBit(ThreshProb^[DecodedSoFar]) then
            CurBit := 1
          else
            CurBit := 0;
          Coef := Coef shl 1;
          Coef := Coef or CurBit;
          DecodedSoFar := Coef;
          if DecodedSoFar > RTC_D3 - 1 then
            DecodedSoFar := RTC_D3 - 1;
          Dec(I);
        end;
      end;

      if I >= 0 then
      begin
        Coef := Coef shl (I + 1);
        Coef := Coef or Reader.GetNBits(I + 1, MPC.CountsX[Bin][Zig15offset].ResidualNoiseCounts);
      end;
    end;

    if Neg then
      Coef := -Coef;
  end;
  Result := SmallInt(Word(Coef and $FFFF));
end;

// ----- DC -----

procedure ModelWriteDc(Writer: TVpxBoolWriter; M: PModel; ColorIndex: Integer;
  Coef: SmallInt; Uncertainty, Uncertainty2: SmallInt);
var
  LenMxm, LenOffset, LenClamp: Integer;
begin
  LenMxm := U16BitLength(Word(Abs(LongInt(Uncertainty))));
  LenOffset := U16BitLength(Word(Abs(LongInt(Uncertainty2))));
  LenClamp := LenMxm;
  if LenClamp > NUMERIC_LENGTH_MAX - 1 then LenClamp := NUMERIC_LENGTH_MAX - 1;

  WriteLengthSignCoef(Writer, Coef,
    M^.CountsDC[LenClamp].ExponentCounts[LenOffset],
    M^.PerColor[ColorIndex].SignCounts[0][CalcSignIndex(Uncertainty2) + 1],
    M^.CountsDC[LenClamp].ResidualNoiseCounts);
end;

function ModelReadDc(Reader: TVpxBoolReader; M: PModel; ColorIndex: Integer;
  Uncertainty, Uncertainty2: SmallInt): SmallInt;
var
  LenMxm, LenOffset, LenClamp: Integer;
begin
  LenMxm := U16BitLength(Word(Abs(LongInt(Uncertainty))));
  LenOffset := U16BitLength(Word(Abs(LongInt(Uncertainty2))));
  LenClamp := LenMxm;
  if LenClamp > NUMERIC_LENGTH_MAX - 1 then LenClamp := NUMERIC_LENGTH_MAX - 1;

  Result := ReadLengthSignCoef(Reader,
    M^.CountsDC[LenClamp].ExponentCounts[LenOffset],
    M^.PerColor[ColorIndex].SignCounts[0][CalcSignIndex(Uncertainty2) + 1],
    M^.CountsDC[LenClamp].ResidualNoiseCounts);
end;

end.
