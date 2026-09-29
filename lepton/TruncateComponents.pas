// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//
//  Port of `jpeg/truncate_components.rs` to Free Pascal.
// 
//  This unit implements logic for computing per‑component truncation bounds
//  when only part of the JPEG image should be decoded or encoded.  Each
//  component has an initial block count and vertical block count derived from
//  the JPEG header.  The `TTruncateComponents` class maintains these values
//  and exposes methods to derive truncated heights and sizes based on a
//  maximum coefficient position (`max_d_pos`).

unit TruncateComponents;

{$mode delphi}

interface

uses
  SysUtils,
  Classes,
  JpegComponentInfo, JpegHeader;

type
  // Internal record storing per‑component truncation information.
  TTruncateComponentsInfo = record
    TruncBCV: UInt32;  // number of vertical blocks in this truncated component
    TruncBC: UInt32;   // total number of blocks retained in this component
  end;

  // Class encapsulating truncation logic for JPEG components.  Each instance
  //  stores the computed truncation information for all components and exposes
  //  methods similar to its Rust counterpart.
  TTruncateComponents = class
  private
    FTruncInfo: array of TTruncateComponentsInfo;
    FComponentsCount: Integer;
    FMcuCountHorizontal: UInt32;
    FMcuCountVertical: UInt32;
    class function GetMinVerticalExtCmpMultiple(const CmpInfo: TComponentInfo;
      McuCountVertical: UInt32): UInt32; static;
    class procedure SetBlockCountDPos(var TI: TTruncateComponentsInfo;
      const CI: TComponentInfo; TruncBC: UInt32; McuCountVertical: UInt32); static;
  public
    constructor Create;
    procedure Init(const JpegHeader: TJpegHeader);
    function GetMaxCodedHeights: TArray<UInt32>;
    procedure SetTruncationBounds(const JpegHeader: TJpegHeader; const MaxDPos: array of UInt32);
    function GetBlockHeight(Cmp: Integer): UInt32;
    function GetComponentSizesInBlocks: TArray<UInt32>;
    property ComponentsCount: Integer read FComponentsCount;
    property McuCountHorizontal: UInt32 read FMcuCountHorizontal;
    property McuCountVertical: UInt32 read FMcuCountVertical;
  end;

implementation

// TTruncateComponents

constructor TTruncateComponents.Create;
begin
  inherited Create;
  FComponentsCount := 0;
  SetLength(FTruncInfo, 0);
  FMcuCountHorizontal := 0;
  FMcuCountVertical := 0;
end;

procedure TTruncateComponents.Init(const JpegHeader: TJpegHeader);
var
  I: Integer;
begin
  // Initialize counts from JPEG header
  FMcuCountHorizontal := JpegHeader.McuH;
  FMcuCountVertical := JpegHeader.McuV;
  FComponentsCount := JpegHeader.CmpC;

  SetLength(FTruncInfo, FComponentsCount);

  for I := 0 to FComponentsCount - 1 do
  begin
    // Copy the original vertical block count and block count
    FTruncInfo[I].TruncBCV := JpegHeader.CmpInfo[I].BCV;
    FTruncInfo[I].TruncBC := JpegHeader.CmpInfo[I].BC;
  end;
end;

function TTruncateComponents.GetMaxCodedHeights: TArray<UInt32>;
var
  I: Integer;
begin
  SetLength(Result, FComponentsCount);
  for I := 0 to FComponentsCount - 1 do
    Result[I] := FTruncInfo[I].TruncBCV;
end;

function TTruncateComponents.GetBlockHeight(Cmp: Integer): UInt32;
begin
  if (Cmp < 0) or (Cmp >= FComponentsCount) then
    raise ERangeError.CreateFmt('GetBlockHeight: component index %d out of range', [Cmp]);
  Result := FTruncInfo[Cmp].TruncBCV;
end;

function TTruncateComponents.GetComponentSizesInBlocks: TArray<UInt32>;
var
  I: Integer;
begin
  SetLength(Result, FComponentsCount);
  for I := 0 to FComponentsCount - 1 do
    Result[I] := FTruncInfo[I].TruncBC;
end;

procedure TTruncateComponents.SetTruncationBounds(const JpegHeader: TJpegHeader;
  const MaxDPos: array of UInt32);
var
  I: Integer;
  TruncBC: UInt32;
begin
  // Apply truncation bounds for each component. The array MaxDPos should
  // contain at least ComponentsCount elements; each value represents the
  // highest coefficient position decoded for the corresponding component.
  for I := 0 to FComponentsCount - 1 do
  begin
    if I < Length(MaxDPos) then
      TruncBC := MaxDPos[I] + 1
    else
      TruncBC := 0;
    SetBlockCountDPos(FTruncInfo[I], JpegHeader.CmpInfo[I], TruncBC, FMcuCountVertical);
  end;
end;

class procedure TTruncateComponents.SetBlockCountDPos(var TI: TTruncateComponentsInfo;
  const CI: TComponentInfo; TruncBC: UInt32; McuCountVertical: UInt32);
var
  VerticalScanLines, Ratio: UInt32;
begin
  // Sanity check: original number of vertical blocks for this component should
  // equal (CI.BC / CI.BCH) with rounding up to handle partial MCU rows.
  Assert(CI.BCV = (CI.BC div CI.BCH) + Ord((CI.BC mod CI.BCH) <> 0),
    'TTruncateComponents.SetBlockCountDPos: inconsistent component geometry');

  // Compute how many vertical scan lines are required to cover TruncBC blocks.
  VerticalScanLines := (TruncBC div CI.BCH) + Ord((TruncBC mod CI.BCH) <> 0);
  // Limit by the original vertical block count
  if VerticalScanLines > CI.BCV then
    VerticalScanLines := CI.BCV;
  // Compute the minimal multiple so that the truncated component covers full
  // MCU rows.  ratio = luma_height / number_of_mcu_rows
  Ratio := GetMinVerticalExtCmpMultiple(CI, McuCountVertical);
  // Increase VerticalScanLines until it is a multiple of Ratio, ensuring the
  // truncated component covers complete extended component rows.
  while (VerticalScanLines mod Ratio <> 0) and (VerticalScanLines + 1 <= CI.BCV) do
    Inc(VerticalScanLines);

  Assert(VerticalScanLines <= CI.BCV,
    'TTruncateComponents.SetBlockCountDPos: VerticalScanLines exceeds original height');
  TI.TruncBCV := VerticalScanLines;
  TI.TruncBC := TruncBC;
end;

class function TTruncateComponents.GetMinVerticalExtCmpMultiple(
  const CmpInfo: TComponentInfo; McuCountVertical: UInt32): UInt32;
var
  LumaHeight: UInt32;
begin
  // Determine the height in blocks of the full luminance component.  Dividing
  // by the total number of MCU rows yields the number of vertical blocks per
  // extended component row.
  LumaHeight := CmpInfo.BCV;
  if McuCountVertical = 0 then
    Result := 1
  else
    Result := LumaHeight div McuCountVertical;
end;

end.