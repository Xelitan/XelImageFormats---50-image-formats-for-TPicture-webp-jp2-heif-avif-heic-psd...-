unit JpegBlockImage;

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
  SysUtils, LeptonConsts, LeptonErrors;

type
  TBlockCoefficients = array[0..63] of SmallInt;

  TAlignedBlock = record
  private
    FRawData: TBlockCoefficients;
  public
    class function Zero: TAlignedBlock; static;
    class function FromArray(const A: TBlockCoefficients): TAlignedBlock; static;
    class function ZigZagToTransposed(const A: TBlockCoefficients): TAlignedBlock; static;
    function ZigZagFromTransposed: TAlignedBlock;
    function DC: SmallInt; inline;
    procedure SetDC(Value: SmallInt); inline;
    function Coefficient(Index: SizeInt): SmallInt; inline;
    procedure SetCoefficient(Index: SizeInt; Value: SmallInt); inline;
    function GetTransposedFromZigZag(Index: SizeInt): SmallInt; inline;
    procedure SetTransposedFromZigZag(Index: SizeInt; Value: SmallInt); inline;
    function CountNonZeros7x7: Byte;
    function Hash: LongInt;
    property RawData: TBlockCoefficients read FRawData write FRawData;
  end;

  PAlignedBlock = ^TAlignedBlock;

  TBlockBasedImage = class
  private
    FBlockWidth: LongWord;
    FOriginalHeight: LongWord;
    FDPosOffset: LongWord;
    FImage: array of TAlignedBlock;
    FCount: SizeInt;
    procedure EnsureCapacity(Capacity: SizeInt);
  public
    constructor Create(BlockWidth, OriginalHeight, Capacity, DPosOffset: LongWord);
    class function CreateForComponent(BlockWidth, OriginalHeight, LumaHeight, LumaYStart, LumaYEnd: LongWord): TBlockBasedImage; static;
    function BlockWidth: LongWord; inline;
    function OriginalHeight: LongWord; inline;
    function DPosOffset: LongWord; inline;
    function Count: SizeInt; inline;
    function Capacity: SizeInt; inline;
    procedure Clear;
    function FillUpToDPos(DPos: LongWord; const BlockToWrite: TAlignedBlock; WriteBlock: Boolean): PAlignedBlock;
    procedure SetBlockData(DPos: LongWord; const BlockData: TAlignedBlock);
    function GetBlock(DPos: LongWord): TAlignedBlock;
    function GetBlockPtr(DPos: LongWord): PAlignedBlock;
    procedure AppendBlock(const Block: TAlignedBlock);
  end;

function EmptyAlignedBlock: TAlignedBlock;

implementation

function EmptyAlignedBlock: TAlignedBlock;
begin
  Result := TAlignedBlock.Zero;
end;

class function TAlignedBlock.Zero: TAlignedBlock;
begin
  FillChar(Result.FRawData, SizeOf(Result.FRawData), 0);
end;

class function TAlignedBlock.FromArray(const A: TBlockCoefficients): TAlignedBlock;
begin
  Result.FRawData := A;
end;

class function TAlignedBlock.ZigZagToTransposed(const A: TBlockCoefficients): TAlignedBlock;
begin
  Result.FRawData[0] := A[0];   Result.FRawData[1] := A[2];   Result.FRawData[2] := A[3];   Result.FRawData[3] := A[9];
  Result.FRawData[4] := A[10];  Result.FRawData[5] := A[20];  Result.FRawData[6] := A[21];  Result.FRawData[7] := A[35];
  Result.FRawData[8] := A[1];   Result.FRawData[9] := A[4];   Result.FRawData[10] := A[8];  Result.FRawData[11] := A[11];
  Result.FRawData[12] := A[19]; Result.FRawData[13] := A[22]; Result.FRawData[14] := A[34]; Result.FRawData[15] := A[36];
  Result.FRawData[16] := A[5];  Result.FRawData[17] := A[7];  Result.FRawData[18] := A[12]; Result.FRawData[19] := A[18];
  Result.FRawData[20] := A[23]; Result.FRawData[21] := A[33]; Result.FRawData[22] := A[37]; Result.FRawData[23] := A[48];
  Result.FRawData[24] := A[6];  Result.FRawData[25] := A[13]; Result.FRawData[26] := A[17]; Result.FRawData[27] := A[24];
  Result.FRawData[28] := A[32]; Result.FRawData[29] := A[38]; Result.FRawData[30] := A[47]; Result.FRawData[31] := A[49];
  Result.FRawData[32] := A[14]; Result.FRawData[33] := A[16]; Result.FRawData[34] := A[25]; Result.FRawData[35] := A[31];
  Result.FRawData[36] := A[39]; Result.FRawData[37] := A[46]; Result.FRawData[38] := A[50]; Result.FRawData[39] := A[57];
  Result.FRawData[40] := A[15]; Result.FRawData[41] := A[26]; Result.FRawData[42] := A[30]; Result.FRawData[43] := A[40];
  Result.FRawData[44] := A[45]; Result.FRawData[45] := A[51]; Result.FRawData[46] := A[56]; Result.FRawData[47] := A[58];
  Result.FRawData[48] := A[27]; Result.FRawData[49] := A[29]; Result.FRawData[50] := A[41]; Result.FRawData[51] := A[44];
  Result.FRawData[52] := A[52]; Result.FRawData[53] := A[55]; Result.FRawData[54] := A[59]; Result.FRawData[55] := A[62];
  Result.FRawData[56] := A[28]; Result.FRawData[57] := A[42]; Result.FRawData[58] := A[43]; Result.FRawData[59] := A[53];
  Result.FRawData[60] := A[54]; Result.FRawData[61] := A[60]; Result.FRawData[62] := A[61]; Result.FRawData[63] := A[63];
end;

function TAlignedBlock.ZigZagFromTransposed: TAlignedBlock;
var
  A: TBlockCoefficients;
begin
  A := FRawData;
  Result.FRawData[0] := A[0];   Result.FRawData[1] := A[8];   Result.FRawData[2] := A[1];   Result.FRawData[3] := A[2];
  Result.FRawData[4] := A[9];   Result.FRawData[5] := A[16];  Result.FRawData[6] := A[24];  Result.FRawData[7] := A[17];
  Result.FRawData[8] := A[10];  Result.FRawData[9] := A[3];   Result.FRawData[10] := A[4];  Result.FRawData[11] := A[11];
  Result.FRawData[12] := A[18]; Result.FRawData[13] := A[25]; Result.FRawData[14] := A[32]; Result.FRawData[15] := A[40];
  Result.FRawData[16] := A[33]; Result.FRawData[17] := A[26]; Result.FRawData[18] := A[19]; Result.FRawData[19] := A[12];
  Result.FRawData[20] := A[5];  Result.FRawData[21] := A[6];  Result.FRawData[22] := A[13]; Result.FRawData[23] := A[20];
  Result.FRawData[24] := A[27]; Result.FRawData[25] := A[34]; Result.FRawData[26] := A[41]; Result.FRawData[27] := A[48];
  Result.FRawData[28] := A[56]; Result.FRawData[29] := A[49]; Result.FRawData[30] := A[42]; Result.FRawData[31] := A[35];
  Result.FRawData[32] := A[28]; Result.FRawData[33] := A[21]; Result.FRawData[34] := A[14]; Result.FRawData[35] := A[7];
  Result.FRawData[36] := A[15]; Result.FRawData[37] := A[22]; Result.FRawData[38] := A[29]; Result.FRawData[39] := A[36];
  Result.FRawData[40] := A[43]; Result.FRawData[41] := A[50]; Result.FRawData[42] := A[57]; Result.FRawData[43] := A[58];
  Result.FRawData[44] := A[51]; Result.FRawData[45] := A[44]; Result.FRawData[46] := A[37]; Result.FRawData[47] := A[30];
  Result.FRawData[48] := A[23]; Result.FRawData[49] := A[31]; Result.FRawData[50] := A[38]; Result.FRawData[51] := A[45];
  Result.FRawData[52] := A[52]; Result.FRawData[53] := A[59]; Result.FRawData[54] := A[60]; Result.FRawData[55] := A[53];
  Result.FRawData[56] := A[46]; Result.FRawData[57] := A[39]; Result.FRawData[58] := A[47]; Result.FRawData[59] := A[54];
  Result.FRawData[60] := A[61]; Result.FRawData[61] := A[62]; Result.FRawData[62] := A[55]; Result.FRawData[63] := A[63];
end;

function TAlignedBlock.DC: SmallInt;
begin
  Result := FRawData[0];
end;

procedure TAlignedBlock.SetDC(Value: SmallInt);
begin
  FRawData[0] := Value;
end;

function TAlignedBlock.Coefficient(Index: SizeInt): SmallInt;
begin
  Result := FRawData[Index];
end;

procedure TAlignedBlock.SetCoefficient(Index: SizeInt; Value: SmallInt);
begin
  FRawData[Index] := Value;
end;

function TAlignedBlock.GetTransposedFromZigZag(Index: SizeInt): SmallInt;
begin
  Result := FRawData[ZIGZAG_TO_TRANSPOSED[Index]];
end;

procedure TAlignedBlock.SetTransposedFromZigZag(Index: SizeInt; Value: SmallInt);
begin
  FRawData[ZIGZAG_TO_TRANSPOSED[Index]] := Value;
end;

function TAlignedBlock.CountNonZeros7x7: Byte;
var
  Row, Col: Integer;
begin
  Result := 0;
  for Row := 1 to 7 do
    for Col := 1 to 7 do
      if FRawData[Row * 8 + Col] <> 0 then
        Inc(Result);
end;

function TAlignedBlock.Hash: LongInt;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to 63 do
    Inc(Result, FRawData[I]);
end;

constructor TBlockBasedImage.Create(BlockWidth, OriginalHeight, Capacity, DPosOffset: LongWord);
begin
  inherited Create;
  FBlockWidth := BlockWidth;
  FOriginalHeight := OriginalHeight;
  FDPosOffset := DPosOffset;
  FCount := 0;
  SetLength(FImage, Capacity);
end;

class function TBlockBasedImage.CreateForComponent(BlockWidth, OriginalHeight, LumaHeight, LumaYStart, LumaYEnd: LongWord): TBlockBasedImage;
var
  MaxSize, ImageCapacity, DPosOffset: QWord;
begin
  if LumaHeight = 0 then
    LeptonFail(lecAssertionFailure, 'CreateForComponent: luma height is zero');
  MaxSize := QWord(BlockWidth) * OriginalHeight;
  ImageCapacity := (MaxSize * (LumaYEnd - LumaYStart) + (LumaHeight - 1)) div LumaHeight;
  DPosOffset := MaxSize * LumaYStart div LumaHeight;
  Result := TBlockBasedImage.Create(BlockWidth, OriginalHeight, LongWord(ImageCapacity), LongWord(DPosOffset));
end;

procedure TBlockBasedImage.EnsureCapacity(Capacity: SizeInt);
begin
  if Length(FImage) < Capacity then
    SetLength(FImage, Capacity);
end;

function TBlockBasedImage.BlockWidth: LongWord;
begin
  Result := FBlockWidth;
end;

function TBlockBasedImage.OriginalHeight: LongWord;
begin
  Result := FOriginalHeight;
end;

function TBlockBasedImage.DPosOffset: LongWord;
begin
  Result := FDPosOffset;
end;

function TBlockBasedImage.Count: SizeInt;
begin
  Result := FCount;
end;

function TBlockBasedImage.Capacity: SizeInt;
begin
  Result := Length(FImage);
end;

procedure TBlockBasedImage.Clear;
begin
  FCount := 0;
end;

function TBlockBasedImage.FillUpToDPos(DPos: LongWord; const BlockToWrite: TAlignedBlock; WriteBlock: Boolean): PAlignedBlock;
var
  RelativeOffset, I: SizeInt;
  Empty: TAlignedBlock;
begin
  if DPos < FDPosOffset then
    LeptonFail(lecAssertionFailure, 'FillUpToDPos: dpos before image offset');
  RelativeOffset := DPos - FDPosOffset;
  EnsureCapacity(RelativeOffset + 1);

  if RelativeOffset < FCount then
  begin
    if WriteBlock then
      FImage[RelativeOffset] := BlockToWrite;
  end
  else
  begin
    Empty := TAlignedBlock.Zero;
    for I := FCount to RelativeOffset - 1 do
      FImage[I] := Empty;
    if WriteBlock then
      FImage[RelativeOffset] := BlockToWrite
    else
      FImage[RelativeOffset] := Empty;
    FCount := RelativeOffset + 1;
  end;

  Result := @FImage[RelativeOffset];
end;

procedure TBlockBasedImage.SetBlockData(DPos: LongWord; const BlockData: TAlignedBlock);
begin
  FillUpToDPos(DPos, BlockData, True);
end;

function TBlockBasedImage.GetBlock(DPos: LongWord): TAlignedBlock;
var
  RelativeOffset: SizeInt;
begin
  if DPos < FDPosOffset then
    Exit(TAlignedBlock.Zero);
  RelativeOffset := DPos - FDPosOffset;
  if RelativeOffset >= FCount then
    Result := TAlignedBlock.Zero
  else
    Result := FImage[RelativeOffset];
end;

function TBlockBasedImage.GetBlockPtr(DPos: LongWord): PAlignedBlock;
var
  Empty: TAlignedBlock;
begin
  Empty := TAlignedBlock.Zero;
  Result := FillUpToDPos(DPos, Empty, False);
end;

procedure TBlockBasedImage.AppendBlock(const Block: TAlignedBlock);
begin
  EnsureCapacity(FCount + 1);
  FImage[FCount] := Block;
  Inc(FCount);
end;

end.
