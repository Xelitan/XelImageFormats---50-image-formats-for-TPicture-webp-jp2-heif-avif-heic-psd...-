// FLIF - Free Lossless Image Format -- Free Pascal port
// Symbol (integer) coding on top of the range coder.
// Corresponds to: src/maniac/symbol.hpp, src/maniac/symbol_enc.hpp
unit flif_symbol;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  flif_types, flif_rac, flif_chance;

const
  MAX_SYMBOL_BITS = 18;

  EXP_CHANCES: array[0..16] of Word =
    (1000, 1200, 1500, 1750, 2000, 2300, 2800, 2400, 2300,
     2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048);
  MANT_CHANCES: array[0..17] of Word =
    (1900, 1850, 1800, 1750, 1650, 1600, 1600, 2048, 2048,
     2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048);
  ZERO_CHANCE = 1000;
  SIGN_CHANCE = 2048;

type
  TSymbolChanceBitType = (BIT_ZERO, BIT_SIGN, BIT_EXP, BIT_MANT);

  PBitChance = ^TBitChance;

  // SymbolChance<BitChance, bits>: dimensioned for the largest `bits` that the
  // reference instantiates (18); only the first `bits` entries are ever
  // initialised/used, exactly as in C++.
  TSymbolChance = record
    BitZero: TBitChance;
    BitSign: TBitChance;
    BitExp: array[0..(MAX_SYMBOL_BITS - 1) * 2 - 1] of TBitChance;
    BitMant: array[0..MAX_SYMBOL_BITS - 1] of TBitChance;
  end;
  PSymbolChance = ^TSymbolChance;

  // Abstract bit-level symbol coder; replaces the C++ template parameter.
  TSymbolBitCoder = class
  public
    function Read(Typ: TSymbolChanceBitType; I: Integer): Boolean; virtual; abstract;
    procedure Write(Bit: Boolean; Typ: TSymbolChanceBitType; I: Integer); virtual; abstract;
  end;

  TSimpleSymbolBitCoder = class(TSymbolBitCoder)
  private
    FTable: TBitChanceTable;
    FCtx: PSymbolChance;
    FRacIn: TRacIn;
    FRacOut: TRacOut;
  public
    constructor Create(ATable: TBitChanceTable; ACtx: PSymbolChance;
      ARacIn: TRacIn; ARacOut: TRacOut);
    function Read(Typ: TSymbolChanceBitType; I: Integer): Boolean; override;
    procedure Write(Bit: Boolean; Typ: TSymbolChanceBitType; I: Integer); override;
  end;

  // UniformSymbolCoder: writes/reads a value in [min..min+len] with plain bits
  TUniformSymbolCoder = class
  private
    FRacIn: TRacIn;
    FRacOut: TRacOut;
  public
    constructor Create(ARacIn: TRacIn; ARacOut: TRacOut);
    function ReadInt(Min, Len: Integer): Integer;
    function ReadIntBits(Bits: Integer): Integer;
    procedure WriteInt(Min, Max, Val: Integer);
    procedure WriteIntBits(Bits, Val: Integer);
  end;

  // SimpleSymbolCoder<SimpleBitChance, RAC, bits>
  TSimpleSymbolCoder = class
  private
    FCtx: TSymbolChance;
    FTable: TBitChanceTable;
    FBits: Integer;
    FBitCoder: TSimpleSymbolBitCoder;
  public
    constructor Create(ARacIn: TRacIn; ARacOut: TRacOut; ABits: Integer;
      Cut: Integer = 2; Alpha: Cardinal = Cardinal($FFFFFFFF) div 19);
    destructor Destroy; override;
    function ReadInt(Min, Max: Integer): Integer;
    function ReadInt2(Min, Max: Integer): Integer;
    function ReadIntBits(NBits: Integer): Integer;
    procedure WriteInt(Min, Max, Value: Integer);
    procedure WriteInt2(Min, Max, Value: Integer);
    procedure WriteIntBits(NBits, Value: Integer);
  end;

procedure InitSymbolChance(var SC: TSymbolChance; Bits: Integer);
function SymbolChanceBit(SC: PSymbolChance; Typ: TSymbolChanceBitType; I: Integer): PBitChance; inline;

// reader<bits>/writer<bits> from symbol.hpp (the `bits` template argument is
// unused in the min/max variants)
function ReaderMinMax(Coder: TSymbolBitCoder; Min, Max: Integer): Integer;
function ReaderNBits(Coder: TSymbolBitCoder; Bits: Integer): Integer;
procedure WriterMinMax(Coder: TSymbolBitCoder; Min, Max, Value: Integer);
procedure WriterNBits(Coder: TSymbolBitCoder; Bits, Value: Integer);

implementation

procedure InitSymbolChance(var SC: TSymbolChance; Bits: Integer);
var
  I: Integer;
begin
  FillChar(SC, SizeOf(SC), 0);
  // the C++ default constructor sets every chance to 0x800 first
  SC.BitZero := $800;
  SC.BitSign := $800;
  for I := 0 to High(SC.BitExp) do SC.BitExp[I] := $800;
  for I := 0 to High(SC.BitMant) do SC.BitMant[I] := $800;

  SC.BitZero := ZERO_CHANCE;
  SC.BitSign := SIGN_CHANCE;
  for I := 0 to Bits - 2 do
  begin
    SC.BitExp[2 * I] := EXP_CHANCES[I];
    SC.BitExp[2 * I + 1] := EXP_CHANCES[I];
  end;
  for I := 0 to Bits - 1 do
    SC.BitMant[I] := MANT_CHANCES[I];
end;

function SymbolChanceBit(SC: PSymbolChance; Typ: TSymbolChanceBitType; I: Integer): PBitChance;
begin
  case Typ of
    BIT_SIGN: Result := @SC^.BitSign;
    BIT_EXP:  Result := @SC^.BitExp[I];
    BIT_MANT: Result := @SC^.BitMant[I];
  else
    Result := @SC^.BitZero;
  end;
end;

// TSimpleSymbolBitCoder

constructor TSimpleSymbolBitCoder.Create(ATable: TBitChanceTable; ACtx: PSymbolChance;
  ARacIn: TRacIn; ARacOut: TRacOut);
begin
  inherited Create;
  FTable := ATable;
  FCtx := ACtx;
  FRacIn := ARacIn;
  FRacOut := ARacOut;
end;

function TSimpleSymbolBitCoder.Read(Typ: TSymbolChanceBitType; I: Integer): Boolean;
var
  BC: PBitChance;
begin
  BC := SymbolChanceBit(FCtx, Typ, I);
  Result := FRacIn.Read12BitChance(BC^);
  BitChancePut(BC^, Result, FTable);
end;

procedure TSimpleSymbolBitCoder.Write(Bit: Boolean; Typ: TSymbolChanceBitType; I: Integer);
var
  BC: PBitChance;
begin
  BC := SymbolChanceBit(FCtx, Typ, I);
  FRacOut.Write12BitChance(BC^, Bit);
  BitChancePut(BC^, Bit, FTable);
end;

// TUniformSymbolCoder

constructor TUniformSymbolCoder.Create(ARacIn: TRacIn; ARacOut: TRacOut);
begin
  inherited Create;
  FRacIn := ARacIn;
  FRacOut := ARacOut;
end;

function TUniformSymbolCoder.ReadInt(Min, Len: Integer): Integer;
var
  Med: Integer;
begin
  while Len > 0 do
  begin
    Med := Len div 2;
    if FRacIn.ReadBit then
    begin
      Min := Min + Med + 1;
      Len := Len - (Med + 1);
    end
    else
      Len := Med;
  end;
  Result := Min;
end;

function TUniformSymbolCoder.ReadIntBits(Bits: Integer): Integer;
begin
  Result := ReadInt(0, (1 shl Bits) - 1);
end;

procedure TUniformSymbolCoder.WriteInt(Min, Max, Val: Integer);
var
  Med: Integer;
begin
  if Min <> 0 then
  begin
    Max := Max - Min;
    Val := Val - Min;
    Min := 0;
  end;
  while Max > 0 do
  begin
    Med := Max div 2;
    if Val > Med then
    begin
      FRacOut.WriteBit(True);
      Min := Med + 1;
      Val := Val - Min;
      Max := Max - Min;
    end
    else
    begin
      FRacOut.WriteBit(False);
      Max := Med;
    end;
  end;
end;

procedure TUniformSymbolCoder.WriteIntBits(Bits, Val: Integer);
begin
  WriteInt(0, (1 shl Bits) - 1, Val);
end;

// reader / writer

function ReaderNBits(Coder: TSymbolBitCoder; Bits: Integer): Integer;
var
  Pos, Value, B: Integer;
begin
  Pos := 0;
  Value := 0;
  B := 1;
  while Pos < Bits do
  begin
    Inc(Pos);
    if Coder.Read(BIT_MANT, Pos) then
      Value := Value + B;
    B := B * 2;
  end;
  Result := Value;
end;

procedure WriterNBits(Coder: TSymbolBitCoder; Bits, Value: Integer);
var
  Pos: Integer;
begin
  Pos := 0;
  while Pos < Bits do
  begin
    Inc(Pos);
    Coder.Write((Value and 1) <> 0, BIT_MANT, Pos);
    Value := Value shr 1;
  end;
end;

function ReaderMinMax(Coder: TSymbolBitCoder; Min, Max: Integer): Integer;
var
  Sign: Boolean;
  AMin, AMax, EMax, E, Have, Left, Pos, MinAbs1, MaxAbs0: Integer;
begin
  if Min = Max then Exit(Min);

  if Coder.Read(BIT_ZERO, 0) then Exit(0);
  if Min < 0 then
  begin
    if Max > 0 then
      Sign := Coder.Read(BIT_SIGN, 0)
    else
      Sign := False;
  end
  else
    Sign := True;

  AMin := 1;
  if Sign then AMax := Max else AMax := -Min;

  EMax := ilog2(Cardinal(AMax));
  E := ilog2(Cardinal(AMin));

  while E < EMax do
  begin
    if Coder.Read(BIT_EXP, (E shl 1) + Ord(Sign)) then Break;
    Inc(E);
  end;

  Have := 1 shl E;
  Left := Have - 1;
  Pos := E;
  while Pos > 0 do
  begin
    Left := Left shr 1;
    Dec(Pos);
    MinAbs1 := Have or (1 shl Pos);
    MaxAbs0 := Have or Left;
    if MinAbs1 > AMax then
      Continue
    else if MaxAbs0 >= AMin then
    begin
      if Coder.Read(BIT_MANT, Pos) then Have := MinAbs1;
    end
    else
      Have := MinAbs1;
  end;
  if Sign then Result := Have else Result := -Have;
end;

procedure WriterMinMax(Coder: TSymbolBitCoder; Min, Max, Value: Integer);
var
  Sign, A, E, AMin, AMax, EMax, I, Have, Left, Pos, Bit, MinAbs1, MaxAbs0: Integer;
begin
  if Min = Max then Exit;

  if Value = 0 then
  begin
    Coder.Write(True, BIT_ZERO, 0);
    Exit;
  end;

  Coder.Write(False, BIT_ZERO, 0);
  if Value > 0 then Sign := 1 else Sign := 0;
  if (Max > 0) and (Min < 0) then
    Coder.Write(Sign <> 0, BIT_SIGN, 0);
  if Sign <> 0 then Min := 1;
  if Sign = 0 then Max := -1;
  A := Abs(Value);
  E := ilog2(Cardinal(A));
  if Sign <> 0 then AMin := Abs(Min) else AMin := Abs(Max);
  if Sign <> 0 then AMax := Abs(Max) else AMax := Abs(Min);

  EMax := ilog2(Cardinal(AMax));
  I := ilog2(Cardinal(AMin));

  while I < EMax do
  begin
    if (1 shl (I + 1)) > AMax then Break;
    Coder.Write(I = E, BIT_EXP, (I shl 1) + Sign);
    if I = E then Break;
    Inc(I);
  end;

  Have := 1 shl E;
  Left := Have - 1;
  Pos := E;
  while Pos > 0 do
  begin
    Bit := 1;
    Dec(Pos);
    Left := Left xor (1 shl Pos);
    MinAbs1 := Have or (1 shl Pos);
    MaxAbs0 := Have or Left;
    if MinAbs1 > AMax then
      Bit := 0
    else if MaxAbs0 >= AMin then
    begin
      Bit := (A shr Pos) and 1;
      Coder.Write(Bit <> 0, BIT_MANT, Pos);
    end;
    Have := Have or (Bit shl Pos);
  end;
end;

// TSimpleSymbolCoder

constructor TSimpleSymbolCoder.Create(ARacIn: TRacIn; ARacOut: TRacOut; ABits: Integer;
  Cut: Integer; Alpha: Cardinal);
begin
  inherited Create;
  FBits := ABits;
  FTable := GetBitChanceTable(Cut, Alpha);
  InitSymbolChance(FCtx, ABits);
  FBitCoder := TSimpleSymbolBitCoder.Create(FTable, @FCtx, ARacIn, ARacOut);
end;

destructor TSimpleSymbolCoder.Destroy;
begin
  FBitCoder.Free;
  inherited Destroy;
end;

function TSimpleSymbolCoder.ReadInt(Min, Max: Integer): Integer;
begin
  Result := ReaderMinMax(FBitCoder, Min, Max);
end;

function TSimpleSymbolCoder.ReadInt2(Min, Max: Integer): Integer;
begin
  if Min > 0 then
    Result := ReadInt(0, Max - Min) + Min
  else if Max < 0 then
    Result := ReadInt(Min - Max, 0) + Max
  else
    Result := ReadInt(Min, Max);
end;

function TSimpleSymbolCoder.ReadIntBits(NBits: Integer): Integer;
begin
  Result := ReaderNBits(FBitCoder, NBits);
end;

procedure TSimpleSymbolCoder.WriteInt(Min, Max, Value: Integer);
begin
  WriterMinMax(FBitCoder, Min, Max, Value);
end;

procedure TSimpleSymbolCoder.WriteInt2(Min, Max, Value: Integer);
begin
  if Min > 0 then
    WriteInt(0, Max - Min, Value - Min)
  else if Max < 0 then
    WriteInt(Min - Max, 0, Value - Max)
  else
    WriteInt(Min, Max, Value);
end;

procedure TSimpleSymbolCoder.WriteIntBits(NBits, Value: Integer);
begin
  WriterNBits(FBitCoder, NBits, Value);
end;

end.
