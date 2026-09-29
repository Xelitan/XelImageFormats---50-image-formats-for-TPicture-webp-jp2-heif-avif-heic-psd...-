unit LeptonQuantizationTables;

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
  LeptonConsts, LeptonHelpers;

type
  TQuantTable = array[0..63] of Word;
  TNoiseThresholds = array[0..13] of Byte;

  TQuantizationTables = record
  private
    FQuantizationTable: TQuantTable;
    FQuantizationTableTransposed: TQuantTable;
    FMinNoiseThreshold: TNoiseThresholds;
  public
    class function FromTable(const QuantizationTable: TQuantTable): TQuantizationTables; static;
    function QuantizationTable: TQuantTable;
    function QuantizationTableTransposed: TQuantTable;
    function MinNoiseThreshold(Coef: SizeInt): Byte; inline;
  end;

implementation

class function TQuantizationTables.FromTable(const QuantizationTable: TQuantTable): TQuantizationTables;
var
  PixelRow, PixelColumn, Coord, CoordTr, I: Integer;
  Q, FreqMaxValue: Word;
  MaxLen: Byte;
begin
  FillChar(Result, SizeOf(Result), 0);

  for PixelRow := 0 to 7 do
    for PixelColumn := 0 to 7 do
    begin
      Coord := PixelRow * 8 + PixelColumn;
      CoordTr := PixelColumn * 8 + PixelRow;
      Q := QuantizationTable[RASTER_TO_ZIGZAG[Coord]];
      Result.FQuantizationTable[Coord] := Q;
      Result.FQuantizationTableTransposed[CoordTr] := Q;
    end;

  for I := 0 to 13 do
  begin
    if I < 7 then
      Coord := I + 1
    else
      Coord := (I - 6) * 8;

    if Result.FQuantizationTable[Coord] < 9 then
    begin
      FreqMaxValue := FREQ_MAX[I] + Result.FQuantizationTable[Coord] - 1;
      if Result.FQuantizationTable[Coord] <> 0 then
        FreqMaxValue := FreqMaxValue div Result.FQuantizationTable[Coord];

      MaxLen := U16BitLength(FreqMaxValue);
      if MaxLen > RESIDUAL_NOISE_FLOOR then
        Result.FMinNoiseThreshold[I] := MaxLen - RESIDUAL_NOISE_FLOOR;
    end;
  end;
end;

function TQuantizationTables.QuantizationTable: TQuantTable;
begin
  Result := FQuantizationTable;
end;

function TQuantizationTables.QuantizationTableTransposed: TQuantTable;
begin
  Result := FQuantizationTableTransposed;
end;

function TQuantizationTables.MinNoiseThreshold(Coef: SizeInt): Byte;
begin
  Result := FMinNoiseThreshold[Coef];
end;

end.
