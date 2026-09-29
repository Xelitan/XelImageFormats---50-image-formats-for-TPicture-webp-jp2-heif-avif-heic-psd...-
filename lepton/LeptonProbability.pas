unit LeptonProbability;

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
// Port of `structs/probability_tables.rs` and `structs/idct.rs`.
//  All SIMD i16x8 / i32x8 operations are unrolled into scalar loops over
//  8-element arrays. Right shifts of signed values use SarLongint to match
//  Rust's arithmetic shift semantics.

interface

uses
  LeptonConsts, LeptonErrors, LeptonHelpers, LeptonFeatures,
  JpegBlockImage, LeptonQuantizationTables, LeptonNeighbor;

const
  MAX_EXPONENT = 11;

type
  TRaster64 = array[0..63] of LongInt;
  TBestPrior64 = array[0..63] of Word;

  TPredictDCResult = record
    PredictedDC: LongInt;
    Uncertainty: SmallInt;
    Uncertainty2: SmallInt;
    NextEdgePixelsH: TI16x8;
    NextEdgePixelsV: TI16x8;
  end;

  TProbabilityTables = record
  private
    FLeftPresent: Boolean;
    FAbovePresent: Boolean;
    FAllPresent: Boolean;
  public
    class function Make(InLeftPresent, InAbovePresent: Boolean): TProbabilityTables; static;
    function IsAllPresent: Boolean; inline;
    function IsLeftPresent: Boolean; inline;
    function IsAbovePresent: Boolean; inline;

    function CalcNumNonZeros7x7ContextBin(AllPresent: Boolean; const Nd: TNeighborData): Byte;
    function CalcCoefficientContext7x7AavgBlock(AllPresent: Boolean;
      const Left, Above, AboveLeft: TAlignedBlock): TBestPrior64;
    function CalcCoefficientContext8Lak(AllPresent, Horizontal: Boolean;
      const Qt: TQuantizationTables; CoefficientTr: Integer; const Pred: TI32x8): LongInt;
    function AdvPredictDcPix(AllPresent: Boolean; const RasterCols: TRaster64; Q0: LongInt;
      const Nd: TNeighborData; const Features: TEnabledFeatures): TPredictDCResult;
  end;

// static helpers
function ProbAdvPredictOrUnpredictDc(SavedDc: SmallInt; RecoverOriginal: Boolean;
  PredictedVal: LongInt): LongInt;
function ProbGetColorIndex(Component: Integer): Integer; inline;
function ProbNumNonZerosToBin7x7(NumNonZeros: Integer): Integer; inline;
procedure ProbPredictCurrentEdges(const Nd: TNeighborData; const Raster: TRaster64;
  out HorizPred, VertPred: TI32x8);
procedure ProbPredictNextEdges(const Raster: TRaster64; out HorizPred, VertPred: TI32x8);

// run_idct on a transposed dequantized raster, returns 64 pixel values
function RunIdct(const Raster: TRaster64): TBlockCoefficients;

var
  PT_NO_NEIGHBORS: TProbabilityTables;
  PT_TOP_ONLY: TProbabilityTables;
  PT_LEFT_ONLY: TProbabilityTables;
  PT_ALL: TProbabilityTables;

implementation

const
  _W1 = 2841; _W2 = 2676; _W3 = 2408; _W5 = 1609; _W6 = 1108; _W7 = 565;
  W3 = 2408; W6 = 1108; W7 = 565;
  W1PW7 = _W1 + _W7; W1MW7 = _W1 - _W7;
  W2PW6 = _W2 + _W6; W2MW6 = _W2 - _W6;
  W3PW5 = _W3 + _W5; W3MW5 = _W3 - _W5;
  R2 = 181;

function TruncI16(V: LongInt): SmallInt; inline;
begin
  Result := SmallInt(Word(V and $FFFF));
end;

function RunIdct(const Raster: TRaster64): TBlockCoefficients;
var
  L, C, M: Integer;
  inp: array[0..7] of LongInt;
  h: array[0..7, 0..7] of LongInt;
  xv0, xv1, xv2, xv3, xv4, xv5, xv6, xv7, xv8: LongInt;
  yv0, yv1, yv2, yv3, yv4, yv5, yv6, yv7, yv8: LongInt;
begin
  // Horizontal pass: for each lane L, transform the column vector raster[*][L]
  for L := 0 to 7 do
  begin
    for M := 0 to 7 do
      inp[M] := Raster[M * 8 + L];

    xv0 := (inp[0] shl 11) + 128;
    xv1 := inp[1];
    xv2 := inp[2];
    xv3 := inp[3];
    xv4 := inp[4] shl 11;
    xv5 := inp[5];
    xv6 := inp[6];
    xv7 := inp[7];

    // Stage 1
    xv8 := _W7 * (xv1 + xv7);
    xv1 := xv8 + (W1MW7 * xv1);
    xv7 := xv8 - (W1PW7 * xv7);
    xv8 := _W3 * (xv5 + xv3);
    xv5 := xv8 - (W3MW5 * xv5);
    xv3 := xv8 - (W3PW5 * xv3);

    // Stage 2
    xv8 := xv0 + xv4;
    xv0 := xv0 - xv4;
    xv4 := W6 * (xv2 + xv6);
    xv6 := xv4 - (W2PW6 * xv6);
    xv2 := xv4 + (W2MW6 * xv2);
    xv4 := xv1 + xv5;
    xv1 := xv1 - xv5;
    xv5 := xv7 + xv3;
    xv7 := xv7 - xv3;

    // Stage 3
    xv3 := xv8 + xv2;
    xv8 := xv8 - xv2;
    xv2 := xv0 + xv6;
    xv0 := xv0 - xv6;
    xv6 := SarLongint((R2 * (xv1 + xv7)) + 128, 8);
    xv1 := SarLongint((R2 * (xv1 - xv7)) + 128, 8);

    // Stage 4
    h[L][0] := SarLongint(xv3 + xv4, 8);
    h[L][1] := SarLongint(xv2 + xv6, 8);
    h[L][2] := SarLongint(xv0 + xv1, 8);
    h[L][3] := SarLongint(xv8 + xv5, 8);
    h[L][4] := SarLongint(xv8 - xv5, 8);
    h[L][5] := SarLongint(xv0 - xv1, 8);
    h[L][6] := SarLongint(xv2 - xv6, 8);
    h[L][7] := SarLongint(xv3 - xv4, 8);
  end;

  // Vertical pass across the other axis: lane C uses the transposed
  // horizontal outputs h[0..7][C] (mirrors i32x8::transpose(row) that
  // idct.rs performs between the two butterfly passes).
  for C := 0 to 7 do
  begin
    yv0 := (h[0][C] shl 8) + 8192;
    yv1 := h[1][C];
    yv2 := h[2][C];
    yv3 := h[3][C];
    yv4 := h[4][C] shl 8;
    yv5 := h[5][C];
    yv6 := h[6][C];
    yv7 := h[7][C];

    // Stage 1
    yv8 := (W7 * (yv1 + yv7)) + 4;
    yv1 := SarLongint(yv8 + (W1MW7 * yv1), 3);
    yv7 := SarLongint(yv8 - (W1PW7 * yv7), 3);
    yv8 := (W3 * (yv5 + yv3)) + 4;
    yv5 := SarLongint(yv8 - (W3MW5 * yv5), 3);
    yv3 := SarLongint(yv8 - (W3PW5 * yv3), 3);

    // Stage 2
    yv8 := yv0 + yv4;
    yv0 := yv0 - yv4;
    yv4 := (W6 * (yv2 + yv6)) + 4;
    yv6 := SarLongint(yv4 - (W2PW6 * yv6), 3);
    yv2 := SarLongint(yv4 + (W2MW6 * yv2), 3);
    yv4 := yv1 + yv5;
    yv1 := yv1 - yv5;
    yv5 := yv7 + yv3;
    yv7 := yv7 - yv3;

    // Stage 3
    yv3 := yv8 + yv2;
    yv8 := yv8 - yv2;
    yv2 := yv0 + yv6;
    yv0 := yv0 - yv6;
    yv6 := SarLongint((R2 * (yv1 + yv7)) + 128, 8);
    yv1 := SarLongint((R2 * (yv1 - yv7)) + 128, 8);

    // Stage 4
    Result[0 * 8 + C] := TruncI16(SarLongint(yv3 + yv4, 11));
    Result[1 * 8 + C] := TruncI16(SarLongint(yv2 + yv6, 11));
    Result[2 * 8 + C] := TruncI16(SarLongint(yv0 + yv1, 11));
    Result[3 * 8 + C] := TruncI16(SarLongint(yv8 + yv5, 11));
    Result[4 * 8 + C] := TruncI16(SarLongint(yv8 - yv5, 11));
    Result[5 * 8 + C] := TruncI16(SarLongint(yv0 - yv1, 11));
    Result[6 * 8 + C] := TruncI16(SarLongint(yv2 - yv6, 11));
    Result[7 * 8 + C] := TruncI16(SarLongint(yv3 - yv4, 11));
  end;
end;

class function TProbabilityTables.Make(InLeftPresent, InAbovePresent: Boolean): TProbabilityTables;
begin
  Result.FLeftPresent := InLeftPresent;
  Result.FAbovePresent := InAbovePresent;
  Result.FAllPresent := InLeftPresent and InAbovePresent;
end;

function TProbabilityTables.IsAllPresent: Boolean;
begin
  Result := FAllPresent;
end;

function TProbabilityTables.IsLeftPresent: Boolean;
begin
  Result := FLeftPresent;
end;

function TProbabilityTables.IsAbovePresent: Boolean;
begin
  Result := FAbovePresent;
end;

function ProbAdvPredictOrUnpredictDc(SavedDc: SmallInt; RecoverOriginal: Boolean;
  PredictedVal: LongInt): LongInt;
const
  MaxValue = 1 shl (MAX_EXPONENT - 1);
  MinValue = -MaxValue;
  AdjustmentFactor = (2 * MaxValue) + 1;
var
  Retval: LongInt;
begin
  Retval := PredictedVal;
  if RecoverOriginal then
    Retval := LongInt(SavedDc) + Retval
  else
    Retval := LongInt(SavedDc) - Retval;

  if Retval < MinValue then
    Retval := Retval + AdjustmentFactor;
  if Retval > MaxValue then
    Retval := Retval - AdjustmentFactor;

  Result := Retval;
end;

function ProbGetColorIndex(Component: Integer): Integer;
begin
  if Component = 0 then
    Result := 0
  else
    Result := 1;
end;

function ProbNumNonZerosToBin7x7(NumNonZeros: Integer): Integer;
begin
  Result := NON_ZERO_TO_BIN_7X7[NumNonZeros];
end;

function TProbabilityTables.CalcNumNonZeros7x7ContextBin(AllPresent: Boolean;
  const Nd: TNeighborData): Byte;
var
  NumAbove, NumLeft, Context: Integer;
begin
  NumAbove := 0;
  NumLeft := 0;
  if AllPresent or FAbovePresent then
    NumAbove := Nd.NeighborContextAbove.NumNonZeros;
  if AllPresent or FLeftPresent then
    NumLeft := Nd.NeighborContextLeft.NumNonZeros;

  if (not AllPresent) and FAbovePresent and (not FLeftPresent) then
    Context := (NumAbove + 1) div 2
  else if (not AllPresent) and FLeftPresent and (not FAbovePresent) then
    Context := (NumLeft + 1) div 2
  else if AllPresent or (FLeftPresent and FAbovePresent) then
    Context := (NumAbove + NumLeft + 2) div 4
  else
    Context := 0;

  Result := NON_ZERO_TO_BIN[Context];
end;

function TProbabilityTables.CalcCoefficientContext7x7AavgBlock(AllPresent: Boolean;
  const Left, Above, AboveLeft: TAlignedBlock): TBestPrior64;
var
  I, Lane, Idx: Integer;
  AL, AA, AAL: LongWord;
begin
  FillChar(Result, SizeOf(Result), 0);
  if AllPresent then
  begin
    for I := 1 to 7 do
      for Lane := 0 to 7 do
      begin
        Idx := I * 8 + Lane;
        AL := Word(Abs(LongInt(Left.Coefficient(Idx))));
        AA := Word(Abs(LongInt(Above.Coefficient(Idx))));
        AAL := Word(Abs(LongInt(AboveLeft.Coefficient(Idx))));
        Result[Idx] := Word((((AL + AA) * 13 + AAL * 6) and $FFFF) shr 5);
      end;
  end
  else if FLeftPresent then
  begin
    for I := 1 to 7 do
      for Lane := 0 to 7 do
      begin
        Idx := I * 8 + Lane;
        Result[Idx] := Word(Abs(LongInt(Left.Coefficient(Idx))));
      end;
  end
  else if FAbovePresent then
  begin
    for I := 1 to 7 do
      for Lane := 0 to 7 do
      begin
        Idx := I * 8 + Lane;
        Result[Idx] := Word(Abs(LongInt(Above.Coefficient(Idx))));
      end;
  end;
end;

procedure ProbPredictCurrentEdges(const Nd: TNeighborData; const Raster: TRaster64;
  out HorizPred, VertPred: TI32x8);
var
  Col, Lane: Integer;
  Acc: LongInt;
begin
  HorizPred := Nd.NeighborContextAbove.HorizontalCoef;
  VertPred := Nd.NeighborContextLeft.VerticalCoef;

  for Col := 1 to 7 do
  begin
    for Lane := 0 to 7 do
      VertPred[Lane] := VertPred[Lane] - (Raster[Col * 8 + Lane] * ICOS_BASED_8192_SCALED[Col]);

    Acc := 0;
    for Lane := 0 to 7 do
      Acc := Acc + (Raster[Col * 8 + Lane] * ICOS_BASED_8192_SCALED[Lane]);
    HorizPred[Col] := HorizPred[Col] - Acc;
  end;
end;

procedure ProbPredictNextEdges(const Raster: TRaster64; out HorizPred, VertPred: TI32x8);
var
  Col, Lane: Integer;
  Acc: LongInt;
begin
  for Lane := 0 to 7 do
  begin
    HorizPred[Lane] := 0;
    VertPred[Lane] := ICOS_BASED_8192_SCALED_PM[0] * Raster[0 * 8 + Lane];
  end;

  for Col := 1 to 7 do
  begin
    Acc := 0;
    for Lane := 0 to 7 do
      Acc := Acc + (ICOS_BASED_8192_SCALED_PM[Lane] * Raster[Col * 8 + Lane]);
    HorizPred[Col] := Acc;

    for Lane := 0 to 7 do
      VertPred[Lane] := VertPred[Lane] + (ICOS_BASED_8192_SCALED_PM[Col] * Raster[Col * 8 + Lane]);
  end;
end;

function TProbabilityTables.CalcCoefficientContext8Lak(AllPresent, Horizontal: Boolean;
  const Qt: TQuantizationTables; CoefficientTr: Integer; const Pred: TI32x8): LongInt;
var
  BestPrior, Divv: LongInt;
  QtTr: TQuantTable;
begin
  if (not AllPresent) and
     ((Horizontal and (not FAbovePresent)) or ((not Horizontal) and (not FLeftPresent))) then
    Exit(0);

  if Horizontal then
    BestPrior := Pred[CoefficientTr shr 3]
  else
    BestPrior := Pred[CoefficientTr];

  QtTr := Qt.QuantizationTableTransposed;
  Divv := LongInt(QtTr[CoefficientTr]) shl 13;
  if Divv = 0 then
    LeptonFail(lecUnsupportedJpegWithZeroIdct0, 'integer overflow in coefficient context calculation');

  Result := BestPrior div Divv;
end;

function CalcPred(const A1, A2: TI16x8; Is16Bit: Boolean): TI16x8;
var
  I: Integer;
  Pd, Hd: LongInt;
begin
  if Is16Bit then
  begin
    for I := 0 to 7 do
    begin
      Pd := SmallInt(Word((A1[I] - A2[I]) and $FFFF));
      Hd := SarLongint(Pd - SarLongint(Pd, 15), 1);
      Result[I] := SmallInt(Word((A1[I] + Hd) and $FFFF));
    end;
  end
  else
  begin
    for I := 0 to 7 do
    begin
      Pd := LongInt(A1[I]) - LongInt(A2[I]);
      Hd := SarLongint(Pd - SarLongint(Pd, 31), 1);
      Result[I] := TruncI16(LongInt(A1[I]) + Hd);
    end;
  end;
end;

function TProbabilityTables.AdvPredictDcPix(AllPresent: Boolean; const RasterCols: TRaster64;
  Q0: LongInt; const Nd: TNeighborData; const Features: TEnabledFeatures): TPredictDCResult;
var
  Pixels: TBlockCoefficients;
  A1, A2, VPred, HPred: TI16x8;
  Horiz, Vert: TI16x8;
  I: Integer;
  MinDc, MaxDc: SmallInt;
  AvgHorizontal, AvgVertical, Avgmed, FarAfield: LongInt;
begin
  Pixels := RunIdct(RasterCols);

  // v_pred from rows 0 and 1
  for I := 0 to 7 do begin A1[I] := Pixels[0 * 8 + I]; A2[I] := Pixels[1 * 8 + I]; end;
  VPred := CalcPred(A1, A2, Features.Use16BitAdvPredict);

  // h_pred from columns 0 and 1 (stride 8)
  for I := 0 to 7 do begin A1[I] := Pixels[I * 8 + 0]; A2[I] := Pixels[I * 8 + 1]; end;
  HPred := CalcPred(A1, A2, Features.Use16BitAdvPredict);

  // next_edge_pixels_v from rows 7 and 6
  for I := 0 to 7 do begin A1[I] := Pixels[7 * 8 + I]; A2[I] := Pixels[6 * 8 + I]; end;
  Result.NextEdgePixelsV := CalcPred(A1, A2, Features.Use16BitDcEstimate);

  // next_edge_pixels_h from columns 7 and 6 (stride 8)
  for I := 0 to 7 do begin A1[I] := Pixels[I * 8 + 7]; A2[I] := Pixels[I * 8 + 6]; end;
  Result.NextEdgePixelsH := CalcPred(A1, A2, Features.Use16BitDcEstimate);

  if AllPresent then
  begin
    for I := 0 to 7 do
    begin
      Horiz[I] := SmallInt(Word((Nd.NeighborContextLeft.HorizontalPix[I] - HPred[I]) and $FFFF));
      Vert[I] := SmallInt(Word((Nd.NeighborContextAbove.VerticalPix[I] - VPred[I]) and $FFFF));
    end;
    MinDc := High(SmallInt); MaxDc := Low(SmallInt);
    AvgHorizontal := 0; AvgVertical := 0;
    for I := 0 to 7 do
    begin
      if Horiz[I] < MinDc then MinDc := Horiz[I];
      if Vert[I] < MinDc then MinDc := Vert[I];
      if Horiz[I] > MaxDc then MaxDc := Horiz[I];
      if Vert[I] > MaxDc then MaxDc := Vert[I];
      AvgHorizontal := AvgHorizontal + Horiz[I];
      AvgVertical := AvgVertical + Vert[I];
    end;
  end
  else if FLeftPresent then
  begin
    for I := 0 to 7 do
      Horiz[I] := SmallInt(Word((Nd.NeighborContextLeft.HorizontalPix[I] - HPred[I]) and $FFFF));
    MinDc := High(SmallInt); MaxDc := Low(SmallInt);
    AvgHorizontal := 0;
    for I := 0 to 7 do
    begin
      if Horiz[I] < MinDc then MinDc := Horiz[I];
      if Horiz[I] > MaxDc then MaxDc := Horiz[I];
      AvgHorizontal := AvgHorizontal + Horiz[I];
    end;
    AvgVertical := AvgHorizontal;
  end
  else if FAbovePresent then
  begin
    for I := 0 to 7 do
      Vert[I] := SmallInt(Word((Nd.NeighborContextAbove.VerticalPix[I] - VPred[I]) and $FFFF));
    MinDc := High(SmallInt); MaxDc := Low(SmallInt);
    AvgVertical := 0;
    for I := 0 to 7 do
    begin
      if Vert[I] < MinDc then MinDc := Vert[I];
      if Vert[I] > MaxDc then MaxDc := Vert[I];
      AvgVertical := AvgVertical + Vert[I];
    end;
    AvgHorizontal := AvgVertical;
  end
  else
  begin
    Result.PredictedDC := 0;
    Result.Uncertainty := 0;
    Result.Uncertainty2 := 0;
    Exit;
  end;

  Avgmed := SarLongint(AvgVertical + AvgHorizontal, 1);
  Result.Uncertainty := SmallInt(Word(SarLongint(LongInt(MaxDc) - LongInt(MinDc), 3) and $FFFF));
  AvgHorizontal := AvgHorizontal - Avgmed;
  AvgVertical := AvgVertical - Avgmed;

  FarAfield := AvgVertical;
  if Abs(AvgHorizontal) < Abs(AvgVertical) then
    FarAfield := AvgHorizontal;

  Result.Uncertainty2 := SmallInt(Word(SarLongint(FarAfield, 3) and $FFFF));
  Result.PredictedDC := SarLongint((Avgmed div Q0) + 4, 3);
end;

initialization
  PT_NO_NEIGHBORS := TProbabilityTables.Make(False, False);
  PT_TOP_ONLY := TProbabilityTables.Make(False, True);
  PT_LEFT_ONLY := TProbabilityTables.Make(True, False);
  PT_ALL := TProbabilityTables.Make(True, True);
end.
