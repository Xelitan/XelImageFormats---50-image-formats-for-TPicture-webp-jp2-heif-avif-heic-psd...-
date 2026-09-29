unit Heif.H265.Cabac;

// HEVC CABAC arithmetic decoder — pure Pascal port of libde265 cabac.cc
// (the portable C fallback path, which is bit-identical to its asm path).
//
// A context model is a (state, MPSbit) pair. The decoder operates over a byte
// buffer that is the slice segment data starting at the CABAC entry point
// (after byte alignment). Emulation-prevention bytes must already be removed.

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TContextModel = record
    State: Byte;    // 0..62
    MPSbit: Byte;   // 0 or 1
  end;
  PContextModel = ^TContextModel;

  TCabacDecoder = class
  private
    FData: PByte;
    FCurr: NativeInt;
    FEnd: NativeInt;
    FRange: LongWord;
    FValue: LongWord;
    FBitsNeeded: LongInt;
  public
    // AData/ASize is the RBSP slice data; AStart is the byte offset where CABAC
    // begins (TSliceHeader.DataByteOffset).
    procedure Init(AData: PByte; ASize: NativeInt; AStart: NativeInt);

    function DecodeBit(var AModel: TContextModel): Integer;
    function DecodeBypass: Integer;
    function DecodeTermBit: Integer;

    function DecodeTU(cMax: Integer; var AModel: TContextModel): Integer;
    function DecodeTUBypass(cMax: Integer): Integer;
    function DecodeFLBypass(nBits: Integer): LongWord;
    function DecodeEGkBypass(k: Integer): LongWord;

    property BytePos: NativeInt read FCurr;
  end;

implementation

const
  LPS_table: array[0..63, 0..3] of Byte = (
    (128,176,208,240),(128,167,197,227),(128,158,187,216),(123,150,178,205),
    (116,142,169,195),(111,135,160,185),(105,128,152,175),(100,122,144,166),
    ( 95,116,137,158),( 90,110,130,150),( 85,104,123,142),( 81, 99,117,135),
    ( 77, 94,111,128),( 73, 89,105,122),( 69, 85,100,116),( 66, 80, 95,110),
    ( 62, 76, 90,104),( 59, 72, 86, 99),( 56, 69, 81, 94),( 53, 65, 77, 89),
    ( 51, 62, 73, 85),( 48, 59, 69, 80),( 46, 56, 66, 76),( 43, 53, 63, 72),
    ( 41, 50, 59, 69),( 39, 48, 56, 65),( 37, 45, 54, 62),( 35, 43, 51, 59),
    ( 33, 41, 48, 56),( 32, 39, 46, 53),( 30, 37, 43, 50),( 29, 35, 41, 48),
    ( 27, 33, 39, 45),( 26, 31, 37, 43),( 24, 30, 35, 41),( 23, 28, 33, 39),
    ( 22, 27, 32, 37),( 21, 26, 30, 35),( 20, 24, 29, 33),( 19, 23, 27, 31),
    ( 18, 22, 26, 30),( 17, 21, 25, 28),( 16, 20, 23, 27),( 15, 19, 22, 25),
    ( 14, 18, 21, 24),( 14, 17, 20, 23),( 13, 16, 19, 22),( 12, 15, 18, 21),
    ( 12, 14, 17, 20),( 11, 14, 16, 19),( 11, 13, 15, 18),( 10, 12, 15, 17),
    ( 10, 12, 14, 16),(  9, 11, 13, 15),(  9, 11, 12, 14),(  8, 10, 12, 14),
    (  8,  9, 11, 13),(  7,  9, 11, 12),(  7,  9, 10, 12),(  7,  8, 10, 11),
    (  6,  8,  9, 11),(  6,  7,  9, 10),(  6,  7,  8,  9),(  2,  2,  2,  2)
  );

  renorm_table: array[0..31] of Byte = (
    6,5,4,4, 3,3,3,3, 2,2,2,2, 2,2,2,2,
    1,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,1
  );

  next_state_MPS: array[0..63] of Byte = (
    1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,
    17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,
    33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,
    49,50,51,52,53,54,55,56,57,58,59,60,61,62,62,63
  );

  next_state_LPS: array[0..63] of Byte = (
    0,0,1,2,2,4,4,5,6,7,8,9,9,11,11,12,
    13,13,15,15,16,16,18,18,19,19,21,21,22,22,23,24,
    24,25,26,26,27,27,28,29,29,30,30,30,31,32,32,33,
    33,33,34,34,35,35,35,36,36,36,37,37,37,38,38,63
  );

procedure TCabacDecoder.Init(AData: PByte; ASize: NativeInt; AStart: NativeInt);
var
  Length: NativeInt;
begin
  FData := AData;
  FCurr := AStart;
  FEnd := ASize;
  Length := FEnd - FCurr;

  FRange := 510;
  FBitsNeeded := 8;
  FValue := 0;

  if Length > 0 then
  begin
    FValue := LongWord(FData[FCurr]) shl 8;
    Inc(FCurr);
    Dec(FBitsNeeded, 8);
  end;
  if Length > 1 then
  begin
    FValue := FValue or LongWord(FData[FCurr]);
    Inc(FCurr);
    Dec(FBitsNeeded, 8);
  end;
end;

function TCabacDecoder.DecodeBit(var AModel: TContextModel): Integer;
var
  LPS: LongWord;
  ScaledRange: LongWord;
  NumBits: Byte;
begin
  LPS := LPS_table[AModel.State][(FRange shr 6) - 4];
  FRange := FRange - LPS;
  ScaledRange := FRange shl 7;

  if FValue < ScaledRange then
  begin
    // MPS path
    Result := AModel.MPSbit;
    AModel.State := next_state_MPS[AModel.State];
    if ScaledRange < (256 shl 7) then
    begin
      FRange := ScaledRange shr 6;
      FValue := FValue shl 1;
      Inc(FBitsNeeded);
      if FBitsNeeded = 0 then
      begin
        FBitsNeeded := -8;
        if FCurr < FEnd then
        begin
          FValue := FValue or LongWord(FData[FCurr]);
          Inc(FCurr);
        end;
      end;
    end;
  end
  else
  begin
    // LPS path
    FValue := FValue - ScaledRange;
    NumBits := renorm_table[LPS shr 3];
    FValue := FValue shl NumBits;
    FRange := LPS shl NumBits;
    Result := 1 - AModel.MPSbit;
    if AModel.State = 0 then
      AModel.MPSbit := 1 - AModel.MPSbit;
    AModel.State := next_state_LPS[AModel.State];
    Inc(FBitsNeeded, NumBits);
    if FBitsNeeded >= 0 then
    begin
      if FCurr < FEnd then
      begin
        FValue := FValue or (LongWord(FData[FCurr]) shl FBitsNeeded);
        Inc(FCurr);
      end;
      Dec(FBitsNeeded, 8);
    end;
  end;
end;

function TCabacDecoder.DecodeTermBit: Integer;
var
  ScaledRange: LongWord;
begin
  FRange := FRange - 2;
  ScaledRange := FRange shl 7;
  if FValue >= ScaledRange then
    Result := 1
  else
  begin
    if ScaledRange < (256 shl 7) then
    begin
      FRange := ScaledRange shr 6;
      FValue := FValue * 2;
      Inc(FBitsNeeded);
      if FBitsNeeded = 0 then
      begin
        FBitsNeeded := -8;
        if FCurr < FEnd then
        begin
          FValue := FValue + LongWord(FData[FCurr]);
          Inc(FCurr);
        end;
      end;
    end;
    Result := 0;
  end;
end;

function TCabacDecoder.DecodeBypass: Integer;
var
  ScaledRange: LongWord;
begin
  FValue := FValue shl 1;
  Inc(FBitsNeeded);
  if FBitsNeeded >= 0 then
  begin
    FBitsNeeded := -8;
    if FCurr < FEnd then
    begin
      FValue := FValue or LongWord(FData[FCurr]);
      Inc(FCurr);
    end;
  end;
  ScaledRange := FRange shl 7;
  if FValue >= ScaledRange then
  begin
    FValue := FValue - ScaledRange;
    Result := 1;
  end
  else
    Result := 0;
end;

function TCabacDecoder.DecodeTU(cMax: Integer; var AModel: TContextModel): Integer;
var
  I: Integer;
begin
  for I := 0 to cMax - 1 do
    if DecodeBit(AModel) = 0 then
      Exit(I);
  Result := cMax;
end;

function TCabacDecoder.DecodeTUBypass(cMax: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to cMax - 1 do
    if DecodeBypass = 0 then
      Exit(I);
  Result := cMax;
end;

// Reads nBits of bypass data as an unsigned value (MSB first).
function TCabacDecoder.DecodeFLBypass(nBits: Integer): LongWord;
var
  ScaledRange: LongWord;
  V: LongWord;
  Input: LongWord;
  Remaining: Integer;
begin
  if nBits = 0 then
    Exit(0);
  if nBits <= 8 then
  begin
    // decode_FL_bypass_parallel
    FValue := FValue shl nBits;
    Inc(FBitsNeeded, nBits);
    if FBitsNeeded >= 0 then
    begin
      if FCurr < FEnd then
      begin
        Input := LongWord(FData[FCurr]);
        Inc(FCurr);
        Input := Input shl FBitsNeeded;
        Dec(FBitsNeeded, 8);
        FValue := FValue or Input;
      end;
    end;
    ScaledRange := FRange shl 7;
    V := FValue div ScaledRange;
    if V >= (LongWord(1) shl nBits) then
      V := (LongWord(1) shl nBits) - 1;
    FValue := FValue - V * ScaledRange;
    Result := V;
  end
  else
  begin
    Result := DecodeFLBypass(8);
    Remaining := nBits - 8;
    while Remaining > 0 do
    begin
      Result := Result shl 1;
      Result := Result or LongWord(DecodeBypass);
      Dec(Remaining);
    end;
  end;
end;

function TCabacDecoder.DecodeEGkBypass(k: Integer): LongWord;
var
  Base: LongWord;
  N: Integer;
  Bit: Integer;
  Suffix: LongWord;
begin
  Base := 0;
  N := k;
  while True do
  begin
    Bit := DecodeBypass;
    if Bit = 0 then
      Break
    else
    begin
      if N >= 31 then
        Exit(0);
      Base := Base + (LongWord(1) shl N);
      Inc(N);
    end;
  end;
  Suffix := DecodeFLBypass(N);
  Result := Base + Suffix;
end;

end.
