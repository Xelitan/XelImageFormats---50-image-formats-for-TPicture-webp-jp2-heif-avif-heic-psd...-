unit LeptonCore;

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
// Port of `structs/lepton_encoder.rs` and `structs/lepton_decoder.rs`
//  (the single-thread row-range code paths).

interface

uses
  Classes, SysUtils,
  LeptonConsts, LeptonErrors, LeptonHelpers, LeptonFeatures,
  JpegBlockImage, JpegHeader, JpegComponentInfo, JpegRowSpec, TruncateComponents,
  LeptonQuantizationTables, VpxBoolCoder,
  LeptonNeighbor, LeptonProbability, LeptonBlockContext, LeptonModel;

type
  TQuantizationTablesArray = array of TQuantizationTables;

function ConstructQuantizationTables(JpegHeader: TJpegHeader): TQuantizationTablesArray;

function WriteCoefficientBlock(AllPresent: Boolean; ColorIndex: Integer;
  const Nd: TNeighborData; const HereTr: TAlignedBlock; M: PModel;
  Writer: TVpxBoolWriter; const Qt: TQuantizationTables; const Pt: TProbabilityTables;
  const Features: TEnabledFeatures): TNeighborSummary;

function ReadCoefficientBlock(AllPresent: Boolean; ColorIndex: Integer;
  const Nd: TNeighborData; M: PModel; Reader: TVpxBoolReader;
  const Qt: TQuantizationTables; const Pt: TProbabilityTables;
  const Features: TEnabledFeatures; out NS: TNeighborSummary): TAlignedBlock;

procedure LeptonEncodeRowRange(const Qts: TQuantizationTablesArray;
  const ImageData: TBlockBasedImageArray; OutStream: TStream;
  Colldata: TTruncateComponents; MinY, MaxY: LongWord;
  IsLastThread, FullFileCompression: Boolean; const Features: TEnabledFeatures);

procedure LeptonDecodeRowRange(const Qts: TQuantizationTablesArray; JpegHeader: TJpegHeader;
  Trunc: TTruncateComponents; ReaderStream: TStream; MinY, MaxY: LongWord;
  IsLastThread, FullFileCompression: Boolean; const Features: TEnabledFeatures;
  out ImageData: TBlockBasedImageArray);

implementation

function ConstructQuantizationTables(JpegHeader: TJpegHeader): TQuantizationTablesArray;
var
  I: Integer;
  Tbl: TQuantTable;
  J: Integer;
begin
  SetLength(Result, JpegHeader.CmpC);
  for I := 0 to JpegHeader.CmpC - 1 do
  begin
    for J := 0 to 63 do
      Tbl[J] := JpegHeader.QTables[JpegHeader.CmpInfo[I].QTableIndex][J];
    Result[I] := TQuantizationTables.FromTable(Tbl);
  end;
end;

function CountNonZero(V: SmallInt): Byte; inline;
begin
  if V = 0 then Result := 0 else Result := 1;
end;


// ---------- edge coding ----------

procedure EncodeOneEdge(AllPresent, Horizontal: Boolean; const Block: TAlignedBlock;
  var MPC: TModelPerColor; Writer: TVpxBoolWriter; const Pred: TI32x8;
  const Qt: TQuantizationTables; const Pt: TProbabilityTables;
  NumNonZerosBin, EstEob: Byte);
var
  NumNonZerosEdge: Byte;
  Delta, Zig15offset, CoordTr, Lane, K: Integer;
  BestPrior: LongInt;
  Coef: SmallInt;
begin
  NumNonZerosEdge := 0;
  if not Horizontal then
    for K := 1 to 7 do
      NumNonZerosEdge := NumNonZerosEdge + CountNonZero(Block.Coefficient(K))
  else
    for K := 1 to 7 do
      NumNonZerosEdge := NumNonZerosEdge + CountNonZero(Block.Coefficient(K * 8));

  ModelWriteNonZeroEdgeCount(Writer, MPC, Horizontal, EstEob, NumNonZerosBin, NumNonZerosEdge);

  if Horizontal then begin Delta := 8; Zig15offset := 0; end
  else begin Delta := 1; Zig15offset := 7; end;

  CoordTr := Delta;
  for Lane := 0 to 6 do
  begin
    if NumNonZerosEdge = 0 then Break;
    BestPrior := Pt.CalcCoefficientContext8Lak(AllPresent, Horizontal, Qt, CoordTr, Pred);
    Coef := Block.Coefficient(CoordTr);
    ModelWriteEdgeCoefficient(Writer, MPC, Qt, Coef, Zig15offset, NumNonZerosEdge, BestPrior);
    if Coef <> 0 then Dec(NumNonZerosEdge);
    Inc(CoordTr, Delta);
    Inc(Zig15offset);
  end;
end;

procedure EncodeEdge(AllPresent: Boolean; const Nd: TNeighborData; const HereTr: TAlignedBlock;
  var MPC: TModelPerColor; Writer: TVpxBoolWriter; const Qt: TQuantizationTables;
  const Pt: TProbabilityTables; NumNonZeros7x7, EobX, EobY: Byte;
  out Raster: TRaster64; out NextHorizPred, NextVertPred: TI32x8);
var
  QtTr: TQuantTable;
  I: Integer;
  CurrHorizPred, CurrVertPred: TI32x8;
  NumNonZerosBin: Byte;
begin
  QtTr := Qt.QuantizationTableTransposed;
  FillChar(Raster, SizeOf(Raster), 0);
  for I := 1 to 63 do
    Raster[I] := LongInt(HereTr.Coefficient(I)) * LongInt(QtTr[I]);

  ProbPredictCurrentEdges(Nd, Raster, CurrHorizPred, CurrVertPred);
  NumNonZerosBin := (NumNonZeros7x7 + 3) div 7;

  EncodeOneEdge(AllPresent, True, HereTr, MPC, Writer, CurrHorizPred, Qt, Pt, NumNonZerosBin, EobX);
  EncodeOneEdge(AllPresent, False, HereTr, MPC, Writer, CurrVertPred, Qt, Pt, NumNonZerosBin, EobY);

  ProbPredictNextEdges(Raster, NextHorizPred, NextVertPred);
end;

procedure DecodeOneEdge(AllPresent, Horizontal: Boolean; var MPC: TModelPerColor;
  Reader: TVpxBoolReader; const Pred: TI32x8; var HereMut: TAlignedBlock;
  const Qt: TQuantizationTables; const Pt: TProbabilityTables;
  NumNonZerosBin, EstEob: Byte; var Raster: TRaster64);
var
  NumNonZerosEdge: Byte;
  Delta, Zig15offset, CoordTr, Lane: Integer;
  BestPrior: LongInt;
  Coef: SmallInt;
  QtTr: TQuantTable;
begin
  NumNonZerosEdge := ModelReadNonZeroEdgeCount(Reader, MPC, Horizontal, EstEob, NumNonZerosBin);
  QtTr := Qt.QuantizationTableTransposed;

  if Horizontal then begin Delta := 8; Zig15offset := 0; end
  else begin Delta := 1; Zig15offset := 7; end;

  CoordTr := Delta;
  for Lane := 0 to 6 do
  begin
    if NumNonZerosEdge = 0 then Break;
    BestPrior := Pt.CalcCoefficientContext8Lak(AllPresent, Horizontal, Qt, CoordTr, Pred);
    Coef := ModelReadEdgeCoefficient(Reader, MPC, Qt, Zig15offset, NumNonZerosEdge, BestPrior);
    if Coef <> 0 then
    begin
      Dec(NumNonZerosEdge);
      HereMut.SetCoefficient(CoordTr, Coef);
      Raster[CoordTr] := LongInt(Coef) * LongInt(QtTr[CoordTr]);
    end;
    Inc(CoordTr, Delta);
    Inc(Zig15offset);
  end;

  if NumNonZerosEdge <> 0 then
    LeptonFail(lecStreamInconsistent, 'StreamInconsistent edge');
end;

procedure DecodeEdge(AllPresent: Boolean; const Nd: TNeighborData; var MPC: TModelPerColor;
  Reader: TVpxBoolReader; var HereMut: TAlignedBlock; const Qt: TQuantizationTables;
  const Pt: TProbabilityTables; NumNonZeros7x7: Byte; var Raster: TRaster64;
  EobX, EobY: Byte; out NextHorizPred, NextVertPred: TI32x8);
var
  CurrHorizPred, CurrVertPred: TI32x8;
  NumNonZerosBin: Byte;
begin
  NumNonZerosBin := (NumNonZeros7x7 + 3) div 7;
  ProbPredictCurrentEdges(Nd, Raster, CurrHorizPred, CurrVertPred);

  DecodeOneEdge(AllPresent, True, MPC, Reader, CurrHorizPred, HereMut, Qt, Pt, NumNonZerosBin, EobX, Raster);
  DecodeOneEdge(AllPresent, False, MPC, Reader, CurrVertPred, HereMut, Qt, Pt, NumNonZerosBin, EobY, Raster);

  ProbPredictNextEdges(Raster, NextHorizPred, NextVertPred);
end;

// ---------- full block coding ----------

function WriteCoefficientBlock(AllPresent: Boolean; ColorIndex: Integer;
  const Nd: TNeighborData; const HereTr: TAlignedBlock; M: PModel;
  Writer: TVpxBoolWriter; const Qt: TQuantizationTables; const Pt: TProbabilityTables;
  const Features: TEnabledFeatures): TNeighborSummary;
var
  ContextBin, NumNonZeros7x7: Byte;
  EobX, EobY: LongWord;
  Remaining, Bin, Zig49, CoordTr, Bpl: Integer;
  BestPriors: TBestPrior64;
  Coef: SmallInt;
  Raster: TRaster64;
  HorizPred, VertPred: TI32x8;
  Q0, AvgPredictedDc, DcCheck: LongInt;
  Predicted: TPredictDCResult;
  QTbl: TQuantTable;
begin
  ContextBin := Pt.CalcNumNonZeros7x7ContextBin(AllPresent, Nd);
  NumNonZeros7x7 := HereTr.CountNonZeros7x7;
  ModelWriteNonZero7x7Count(Writer, M^.PerColor[ColorIndex], ContextBin, NumNonZeros7x7);

  EobX := 0; EobY := 0;
  Remaining := NumNonZeros7x7;
  if Remaining > 0 then
  begin
    BestPriors := Pt.CalcCoefficientContext7x7AavgBlock(AllPresent, Nd.Left, Nd.Above, Nd.AboveLeft);
    Bin := ProbNumNonZerosToBin7x7(Remaining);
    for Zig49 := 0 to 48 do
    begin
      CoordTr := UNZIGZAG_49_TR[Zig49];
      Bpl := U16BitLength(BestPriors[CoordTr]);
      Coef := HereTr.Coefficient(CoordTr);
      ModelWriteCoef(Writer, M^.PerColor[ColorIndex], Coef, Zig49, Bin, Bpl);
      if Coef <> 0 then
      begin
        if (LongWord(CoordTr) shr 3) > EobX then EobX := LongWord(CoordTr) shr 3;
        if (LongWord(CoordTr) and 7) > EobY then EobY := LongWord(CoordTr) and 7;
        Dec(Remaining);
        if Remaining = 0 then Break;
        Bin := ProbNumNonZerosToBin7x7(Remaining);
      end;
    end;
  end;

  EncodeEdge(AllPresent, Nd, HereTr, M^.PerColor[ColorIndex], Writer, Qt, Pt,
    NumNonZeros7x7, Byte(EobX), Byte(EobY), Raster, HorizPred, VertPred);

  QTbl := Qt.QuantizationTable;
  Q0 := QTbl[0];
  Predicted := Pt.AdvPredictDcPix(AllPresent, Raster, Q0, Nd, Features);

  AvgPredictedDc := ProbAdvPredictOrUnpredictDc(HereTr.DC, False, Predicted.PredictedDC);
  DcCheck := ProbAdvPredictOrUnpredictDc(SmallInt(Word(AvgPredictedDc and $FFFF)), True, Predicted.PredictedDC);
  if LongInt(HereTr.DC) <> DcCheck then
    LeptonFail(lecStreamInconsistent, 'BlockDC mismatch');

  ModelWriteDc(Writer, M, ColorIndex, SmallInt(Word(AvgPredictedDc and $FFFF)),
    Predicted.Uncertainty, Predicted.Uncertainty2);

  Result := TNeighborSummary.New(Predicted.NextEdgePixelsH, Predicted.NextEdgePixelsV,
    LongInt(HereTr.DC) * Q0, NumNonZeros7x7, HorizPred, VertPred);
end;

function ReadCoefficientBlock(AllPresent: Boolean; ColorIndex: Integer;
  const Nd: TNeighborData; M: PModel; Reader: TVpxBoolReader;
  const Qt: TQuantizationTables; const Pt: TProbabilityTables;
  const Features: TEnabledFeatures; out NS: TNeighborSummary): TAlignedBlock;
var
  ContextBin, NumNonZeros7x7: Byte;
  Output: TAlignedBlock;
  Raster: TRaster64;
  EobX, EobY: LongWord;
  Remaining, Bin, Zig49, CoordTr, Bpl: Integer;
  BestPriors: TBestPrior64;
  Coef: SmallInt;
  HorizPred, VertPred: TI32x8;
  Q0: LongInt;
  Predicted: TPredictDCResult;
  QTbl, QtTr: TQuantTable;
begin
  ContextBin := Pt.CalcNumNonZeros7x7ContextBin(AllPresent, Nd);
  NumNonZeros7x7 := ModelReadNonZero7x7Count(Reader, M^.PerColor[ColorIndex], ContextBin);
  if NumNonZeros7x7 > 49 then
    LeptonFail(lecStreamInconsistent, 'numNonzeros7x7 > 49');

  Output := TAlignedBlock.Zero;
  FillChar(Raster, SizeOf(Raster), 0);
  QtTr := Qt.QuantizationTableTransposed;

  EobX := 0; EobY := 0;
  Remaining := NumNonZeros7x7;
  if Remaining > 0 then
  begin
    BestPriors := Pt.CalcCoefficientContext7x7AavgBlock(AllPresent, Nd.Left, Nd.Above, Nd.AboveLeft);
    Bin := ProbNumNonZerosToBin7x7(Remaining);
    for Zig49 := 0 to 48 do
    begin
      CoordTr := UNZIGZAG_49_TR[Zig49];
      Bpl := U16BitLength(BestPriors[CoordTr]);
      Coef := ModelReadCoef(Reader, M^.PerColor[ColorIndex], Zig49, Bin, Bpl);
      if Coef <> 0 then
      begin
        if (LongWord(CoordTr) shr 3) > EobX then EobX := LongWord(CoordTr) shr 3;
        if (LongWord(CoordTr) and 7) > EobY then EobY := LongWord(CoordTr) and 7;
        Output.SetCoefficient(CoordTr, Coef);
        Raster[CoordTr] := LongInt(Coef) * LongInt(QtTr[CoordTr]);
        Dec(Remaining);
        if Remaining = 0 then Break;
        Bin := ProbNumNonZerosToBin7x7(Remaining);
      end;
    end;
  end;

  if Remaining > 0 then
    LeptonFail(lecStreamInconsistent, 'not enough nonzeros in 7x7 block');

  DecodeEdge(AllPresent, Nd, M^.PerColor[ColorIndex], Reader, Output, Qt, Pt,
    NumNonZeros7x7, Raster, Byte(EobX), Byte(EobY), HorizPred, VertPred);

  QTbl := Qt.QuantizationTable;
  Q0 := QTbl[0];
  Predicted := Pt.AdvPredictDcPix(AllPresent, Raster, Q0, Nd, Features);

  Coef := ModelReadDc(Reader, M, ColorIndex, Predicted.Uncertainty, Predicted.Uncertainty2);
  Output.SetDC(SmallInt(Word(ProbAdvPredictOrUnpredictDc(Coef, True, Predicted.PredictedDC) and $FFFF)));

  NS := TNeighborSummary.New(Predicted.NextEdgePixelsH, Predicted.NextEdgePixelsV,
    LongInt(Output.DC) * Q0, NumNonZeros7x7, HorizPred, VertPred);
  Result := Output;
end;

// ---------- row ranges ----------

function CopyHeights(const A: TArray<UInt32>): TLongWordDynArray;
var I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

procedure ProcessRowEncode(M: PModel; Writer: TVpxBoolWriter;
  const LeftModel, MiddleModel: TProbabilityTables; ColorIndex: Integer;
  ImageData: TBlockBasedImage; const Qt: TQuantizationTables;
  var NSCache: TNeighborSummaryArray; CurrY, ComponentSizeInBlock: LongWord;
  const Features: TEnabledFeatures);
var
  Ctx: TBlockContext;
  BlockWidth, JpegX, Offset: LongWord;
  Pt: TProbabilityTables;
  Nd: TNeighborData;
  Block: TAlignedBlock;
  NS: TNeighborSummary;
  AllPresent: Boolean;
begin
  Ctx := TBlockContext.OffY(CurrY, ImageData);
  BlockWidth := ImageData.BlockWidth;
  JpegX := 0;
  while JpegX < BlockWidth do
  begin
    if JpegX = 0 then Pt := LeftModel else Pt := MiddleModel;
    AllPresent := Pt.IsAllPresent;
    Block := Ctx.Here(ImageData);
    Nd := GetNeighborData(Ctx, ImageData, NSCache, Pt, AllPresent);
    NS := WriteCoefficientBlock(AllPresent, ColorIndex, Nd, Block, M, Writer, Qt, Pt, Features);
    SetNeighborSummaryHere(NSCache, Ctx, NS);
    Offset := Ctx.Next;
    if Offset >= ComponentSizeInBlock then Exit;
    Inc(JpegX);
  end;
end;

procedure LeptonEncodeRowRange(const Qts: TQuantizationTablesArray;
  const ImageData: TBlockBasedImageArray; OutStream: TStream;
  Colldata: TTruncateComponents; MinY, MaxY: LongWord;
  IsLastThread, FullFileCompression: Boolean; const Features: TEnabledFeatures);
var
  M: PModel;
  Writer: TVpxBoolWriter;
  IsTopRow: array of Boolean;
  NSCache: array of TNeighborSummaryArray;
  CompSizes, MaxCodedHeights: TLongWordDynArray;
  EncodeIndex: LongWord;
  CurRow: TRowSpec;
  Component, I: Integer;
  LeftModel, MiddleModel: TProbabilityTables;
begin
  M := NewModel;
  Writer := TVpxBoolWriter.Create(OutStream, False);
  try
    SetLength(IsTopRow, Length(ImageData));
    SetLength(NSCache, Length(ImageData));
    for I := 0 to High(ImageData) do
    begin
      IsTopRow[I] := True;
      SetLength(NSCache[I], ImageData[I].BlockWidth * 2);
    end;

    CompSizes := CopyHeights(Colldata.GetComponentSizesInBlocks);
    MaxCodedHeights := CopyHeights(Colldata.GetMaxCodedHeights);

    EncodeIndex := 0;
    while True do
    begin
      CurRow := TRowSpec.GetRowSpecFromIndex(EncodeIndex, ImageData,
        Colldata.McuCountVertical, MaxCodedHeights);
      Inc(EncodeIndex);

      if CurRow.Done then Break;
      if (CurRow.LumaY >= MaxY) and (not (IsLastThread and FullFileCompression)) then Break;
      if CurRow.Skip then Continue;
      if CurRow.LumaY < MinY then Continue;

      Component := CurRow.Component;
      if IsTopRow[Component] then
      begin
        IsTopRow[Component] := False;
        LeftModel := PT_NO_NEIGHBORS;
        MiddleModel := PT_LEFT_ONLY;
      end
      else
      begin
        LeftModel := PT_TOP_ONLY;
        MiddleModel := PT_ALL;
      end;

      ProcessRowEncode(M, Writer, LeftModel, MiddleModel, ProbGetColorIndex(Component),
        ImageData[Component], Qts[Component], NSCache[Component], CurRow.CurrY,
        CompSizes[Component], Features);

      Writer.FlushNonFinalData;
    end;

    Writer.Finish;
  finally
    Writer.Free;
    FreeModel(M);
  end;
end;

procedure DecodeRowWrapper(M: PModel; Reader: TVpxBoolReader;
  const LeftModel, MiddleModel: TProbabilityTables; ColorIndex: Integer;
  ImageData: TBlockBasedImage; const Qt: TQuantizationTables;
  var NSCache: TNeighborSummaryArray; CurrY, ComponentSizeInBlocks: LongWord;
  const Features: TEnabledFeatures);
var
  Ctx: TBlockContext;
  BlockWidth, JpegX, Offset: LongWord;
  Pt: TProbabilityTables;
  Nd: TNeighborData;
  Block: TAlignedBlock;
  NS: TNeighborSummary;
  AllPresent: Boolean;
begin
  Ctx := TBlockContext.OffY(CurrY, ImageData);
  BlockWidth := ImageData.BlockWidth;
  JpegX := 0;
  while JpegX < BlockWidth do
  begin
    if JpegX = 0 then Pt := LeftModel else Pt := MiddleModel;
    AllPresent := Pt.IsAllPresent;
    Nd := GetNeighborData(Ctx, ImageData, NSCache, Pt, AllPresent);
    Block := ReadCoefficientBlock(AllPresent, ColorIndex, Nd, M, Reader, Qt, Pt, Features, NS);
    SetNeighborSummaryHere(NSCache, Ctx, NS);
    ImageData.AppendBlock(Block);
    Offset := Ctx.Next;
    if Offset >= ComponentSizeInBlocks then Exit;
    Inc(JpegX);
  end;
end;

procedure LeptonDecodeRowRange(const Qts: TQuantizationTablesArray; JpegHeader: TJpegHeader;
  Trunc: TTruncateComponents; ReaderStream: TStream; MinY, MaxY: LongWord;
  IsLastThread, FullFileCompression: Boolean; const Features: TEnabledFeatures;
  out ImageData: TBlockBasedImageArray);
var
  M: PModel;
  Reader: TVpxBoolReader;
  IsTopRow: array of Boolean;
  NSCache: array of TNeighborSummaryArray;
  CompSizes, MaxCodedHeights: TLongWordDynArray;
  DecodeIndex: LongWord;
  CurRow: TRowSpec;
  Component, I: Integer;
  LeftModel, MiddleModel: TProbabilityTables;
  LumaBcv: LongWord;
begin
  SetLength(ImageData, JpegHeader.CmpC);
  LumaBcv := JpegHeader.CmpInfo[0].BCV;
  for I := 0 to JpegHeader.CmpC - 1 do
    if IsLastThread then
      // the last thread's image extends all the way to the bottom
      ImageData[I] := TBlockBasedImage.CreateForComponent(
        JpegHeader.CmpInfo[I].BCH, JpegHeader.CmpInfo[I].BCV, LumaBcv, MinY, LumaBcv)
    else
      ImageData[I] := TBlockBasedImage.CreateForComponent(
        JpegHeader.CmpInfo[I].BCH, JpegHeader.CmpInfo[I].BCV, LumaBcv, MinY, MaxY);

  M := NewModel;
  Reader := TVpxBoolReader.Create(ReaderStream, False);
  try
    SetLength(IsTopRow, Length(ImageData));
    SetLength(NSCache, Length(ImageData));
    for I := 0 to High(ImageData) do
    begin
      IsTopRow[I] := True;
      SetLength(NSCache[I], ImageData[I].BlockWidth * 2);
    end;

    CompSizes := CopyHeights(Trunc.GetComponentSizesInBlocks);
    MaxCodedHeights := CopyHeights(Trunc.GetMaxCodedHeights);

    DecodeIndex := 0;
    while True do
    begin
      CurRow := TRowSpec.GetRowSpecFromIndex(DecodeIndex, ImageData,
        Trunc.McuCountVertical, MaxCodedHeights);
      Inc(DecodeIndex);

      if CurRow.Done then Break;
      if (CurRow.LumaY >= MaxY) and (not (IsLastThread and FullFileCompression)) then Break;
      if CurRow.Skip then Continue;
      if CurRow.LumaY < MinY then Continue;

      Component := CurRow.Component;
      if IsTopRow[Component] then
      begin
        IsTopRow[Component] := False;
        LeftModel := PT_NO_NEIGHBORS;
        MiddleModel := PT_LEFT_ONLY;
      end
      else
      begin
        LeftModel := PT_TOP_ONLY;
        MiddleModel := PT_ALL;
      end;

      DecodeRowWrapper(M, Reader, LeftModel, MiddleModel, ProbGetColorIndex(Component),
        ImageData[Component], Qts[Component], NSCache[Component], CurRow.CurrY,
        CompSizes[Component], Features);
    end;
  finally
    Reader.Free;
    FreeModel(M);
  end;
end;

end.
