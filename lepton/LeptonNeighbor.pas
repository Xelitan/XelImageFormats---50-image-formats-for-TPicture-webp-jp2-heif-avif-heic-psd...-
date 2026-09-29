unit LeptonNeighbor;

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
// Port of `structs/neighbor_summary.rs` and the NeighborData part of
//  `structs/block_context.rs`.  The SIMD i16x8 / i32x8 lanes from the Rust
//  original are represented here as plain 8-element arrays.

interface

uses
  JpegBlockImage;

type
  TI16x8 = array[0..7] of SmallInt;
  TI32x8 = array[0..7] of LongInt;

  TNeighborSummary = record
  private
    FEdgePixelsH: TI16x8;
    FEdgePixelsV: TI16x8;
    FEdgeCoefsH: TI32x8;
    FEdgeCoefsV: TI32x8;
    FNumNonZeros: Byte;
  public
    class function Empty: TNeighborSummary; static;
    class function New(const EdgePixelsH, EdgePixelsV: TI16x8; DcDeq: LongInt;
      NumNonZeros7x7: Byte; const HorizPred, VertPred: TI32x8): TNeighborSummary; static;
    function NumNonZeros: Byte; inline;
    function VerticalPix: TI16x8; inline;
    function HorizontalPix: TI16x8; inline;
    function VerticalCoef: TI32x8; inline;
    function HorizontalCoef: TI32x8; inline;
  end;

  // Value-copy neighborhood data used while (de)coding a single block.  The
  //  Rust version holds references; we hold copies which is simpler and safe
  //  since this data is only read during block coding.
  TNeighborData = record
    Above: TAlignedBlock;
    Left: TAlignedBlock;
    AboveLeft: TAlignedBlock;
    NeighborContextAbove: TNeighborSummary;
    NeighborContextLeft: TNeighborSummary;
  end;

function NeighborDataEmpty: TNeighborSummary;

implementation

class function TNeighborSummary.Empty: TNeighborSummary;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

function NeighborDataEmpty: TNeighborSummary;
begin
  Result := TNeighborSummary.Empty;
end;

class function TNeighborSummary.New(const EdgePixelsH, EdgePixelsV: TI16x8; DcDeq: LongInt;
  NumNonZeros7x7: Byte; const HorizPred, VertPred: TI32x8): TNeighborSummary;
var
  I: Integer;
  D: SmallInt;
begin
  D := SmallInt(Word(DcDeq and $FFFF));
  for I := 0 to 7 do
  begin
    Result.FEdgePixelsH[I] := SmallInt(Word((EdgePixelsH[I] + D) and $FFFF));
    Result.FEdgePixelsV[I] := SmallInt(Word((EdgePixelsV[I] + D) and $FFFF));
    Result.FEdgeCoefsH[I] := HorizPred[I];
    Result.FEdgeCoefsV[I] := VertPred[I];
  end;
  Result.FNumNonZeros := NumNonZeros7x7;
end;

function TNeighborSummary.NumNonZeros: Byte;
begin
  Result := FNumNonZeros;
end;

function TNeighborSummary.VerticalPix: TI16x8;
begin
  Result := FEdgePixelsV;
end;

function TNeighborSummary.HorizontalPix: TI16x8;
begin
  Result := FEdgePixelsH;
end;

function TNeighborSummary.VerticalCoef: TI32x8;
begin
  Result := FEdgeCoefsV;
end;

function TNeighborSummary.HorizontalCoef: TI32x8;
begin
  Result := FEdgeCoefsH;
end;

end.
