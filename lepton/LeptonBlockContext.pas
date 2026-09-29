unit LeptonBlockContext;

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
// Port of `structs/block_context.rs` (the BlockContext part).

interface

uses
  JpegBlockImage, LeptonNeighbor, LeptonProbability;

type
  TNeighborSummaryArray = array of TNeighborSummary;

  TBlockContext = record
    BlockWidth: LongWord;
    CurBlockIndex: LongWord;
    CurNeighborSummaryIndex: LongWord;
    AboveNeighborSummaryIndex: LongWord;
    class function OffY(Y: LongWord; ImageData: TBlockBasedImage): TBlockContext; static;
    function Next: LongWord;
    function Here(ImageData: TBlockBasedImage): TAlignedBlock;
  end;

function GetNeighborData(const Ctx: TBlockContext; ImageData: TBlockBasedImage;
  const NSCache: TNeighborSummaryArray; const Pt: TProbabilityTables;
  AllPresent: Boolean): TNeighborData;

procedure SetNeighborSummaryHere(var NSCache: TNeighborSummaryArray;
  const Ctx: TBlockContext; const NS: TNeighborSummary);

implementation

class function TBlockContext.OffY(Y: LongWord; ImageData: TBlockBasedImage): TBlockContext;
begin
  Result.BlockWidth := ImageData.BlockWidth;
  Result.CurBlockIndex := Result.BlockWidth * Y;
  if (Y and 1) <> 0 then
  begin
    Result.CurNeighborSummaryIndex := Result.BlockWidth;
    Result.AboveNeighborSummaryIndex := 0;
  end
  else
  begin
    Result.CurNeighborSummaryIndex := 0;
    Result.AboveNeighborSummaryIndex := Result.BlockWidth;
  end;
end;

function TBlockContext.Next: LongWord;
begin
  Inc(CurBlockIndex);
  Inc(CurNeighborSummaryIndex);
  Inc(AboveNeighborSummaryIndex);
  Result := CurBlockIndex;
end;

function TBlockContext.Here(ImageData: TBlockBasedImage): TAlignedBlock;
begin
  Result := ImageData.GetBlock(CurBlockIndex);
end;

function GetNeighborData(const Ctx: TBlockContext; ImageData: TBlockBasedImage;
  const NSCache: TNeighborSummaryArray; const Pt: TProbabilityTables;
  AllPresent: Boolean): TNeighborData;
begin
  if AllPresent then
    Result.AboveLeft := ImageData.GetBlock(Ctx.CurBlockIndex - Ctx.BlockWidth - 1)
  else
    Result.AboveLeft := TAlignedBlock.Zero;

  if AllPresent or Pt.IsAbovePresent then
    Result.Above := ImageData.GetBlock(Ctx.CurBlockIndex - Ctx.BlockWidth)
  else
    Result.Above := TAlignedBlock.Zero;

  if AllPresent or Pt.IsLeftPresent then
    Result.Left := ImageData.GetBlock(Ctx.CurBlockIndex - 1)
  else
    Result.Left := TAlignedBlock.Zero;

  if AllPresent or Pt.IsAbovePresent then
    Result.NeighborContextAbove := NSCache[Ctx.AboveNeighborSummaryIndex]
  else
    Result.NeighborContextAbove := TNeighborSummary.Empty;

  if AllPresent or Pt.IsLeftPresent then
    Result.NeighborContextLeft := NSCache[Ctx.CurNeighborSummaryIndex - 1]
  else
    Result.NeighborContextLeft := TNeighborSummary.Empty;
end;

procedure SetNeighborSummaryHere(var NSCache: TNeighborSummaryArray;
  const Ctx: TBlockContext; const NS: TNeighborSummary);
begin
  NSCache[Ctx.CurNeighborSummaryIndex] := NS;
end;

end.
