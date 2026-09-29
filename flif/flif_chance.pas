// FLIF - Free Lossless Image Format -- Free Pascal port
// Adaptive binary probability model (12-bit chances) and the log4k table.
// Corresponds to: src/maniac/chance.hpp, src/maniac/chance.cpp
//
// Only SimpleBitChance is needed: the reference build defines
// FAST_BUT_WORSE_COMPRESSION, which makes every FLIFBitChance* alias
// SimpleBitChance.
unit flif_chance;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

type
  // A SimpleBitChance is just a 12-bit number; it is stored inline in the
  // SymbolChance arrays, so no class wrapper here.
  TBitChance = Word;

  TChanceStateTable = array[0..4095] of Word;

  TBitChanceTable = class
  public
    Next: array[0..1] of TChanceStateTable; // stored as 12-bit numbers
    Alpha: Cardinal;
    Cut: Integer;
    constructor Create(ACut: Integer; AAlpha: Cardinal);
  end;

var
  Log4kData: array[0..4096] of Word;
  Log4kScale: Integer;

// Tables are expensive to build (4096 iterations) and are shared by every coder
// using the same (cut, alpha) pair, so they are cached and owned by this unit.
function GetBitChanceTable(Cut: Integer; Alpha: Cardinal): TBitChanceTable;
procedure FreeBitChanceTableCache;

procedure BuildTable(var ZeroState, OneState: TChanceStateTable;
  Size: Integer; Factor: Cardinal; MaxP: Cardinal);

// chance.put(bit, table)
procedure BitChancePut(var Chance: TBitChance; Bit: Boolean; Table: TBitChanceTable); inline;
// chance.estim(bit, total)
procedure BitChanceEstim(Chance: TBitChance; Bit: Boolean; var Total: QWord); inline;

implementation

// TBitChanceTable

constructor TBitChanceTable.Create(ACut: Integer; AAlpha: Cardinal);
begin
  inherited Create;
  Cut := ACut;
  Alpha := AAlpha;
  BuildTable(Next[0], Next[1], 4096, AAlpha, Cardinal(4096 - ACut));
end;

procedure BuildTable(var ZeroState, OneState: TChanceStateTable;
  Size: Integer; Factor: Cardinal; MaxP: Cardinal);
const
  One = Int64(1) shl 32;
var
  P: Int64;
  LastP8, P8: Cardinal;
  I: Integer;
begin
  FillChar(ZeroState, SizeOf(Word) * Size, 0);
  FillChar(OneState, SizeOf(Word) * Size, 0);

  LastP8 := 0;
  P := One div 2;
  for I := 0 to (Size div 2) - 1 do
  begin
    P8 := Cardinal((Int64(Size) * P + One div 2) shr 32);
    if P8 <= LastP8 then P8 := LastP8 + 1;
    if (LastP8 <> 0) and (LastP8 < Cardinal(Size)) and (P8 <= MaxP) then
      OneState[LastP8] := Word(P8);
    P := P + (((One - P) * Int64(Factor) + One div 2) shr 32);
    LastP8 := P8;
  end;

  for I := Size - Integer(MaxP) to Integer(MaxP) do
  begin
    if OneState[I] <> 0 then Continue;
    P := (Int64(I) * One + Size div 2) div Size;
    P := P + (((One - P) * Int64(Factor) + One div 2) shr 32);
    P8 := Cardinal((Int64(Size) * P + One div 2) shr 32);
    if P8 <= Cardinal(I) then P8 := Cardinal(I) + 1;
    if P8 > MaxP then P8 := MaxP;
    OneState[I] := Word(P8);
  end;

  for I := 1 to Size - 1 do
    ZeroState[I] := Word(Size - OneState[Size - I]);
end;

// Computes an approximation of log(4096 / x) / log(2) * base
function Log4kf(X: Integer; Base: Cardinal): Cardinal;
var
  Bits: Integer;
  Y: QWord;
  Res, Add: Cardinal;
begin
  Bits := 32 - (31 - BsrDWord(Cardinal(X)));  // == ilog2(x)+1
  Y := QWord(Cardinal(X)) shl (32 - Bits);
  Res := Base * Cardinal(13 - Bits);
  Add := Base;
  while (Add > 1) and ((Y and $7FFFFFFF) <> 0) do
  begin
    Y := (Y * Y + $40000000) shr 31;
    Add := Add shr 1;
    if (Y shr 32) <> 0 then
    begin
      Res := Res - Add;
      Y := Y shr 1;
    end;
  end;
  Result := Res;
end;

procedure InitLog4k;
var
  I: Integer;
begin
  Log4kData[0] := 0;
  for I := 1 to 4096 do
    Log4kData[I] := Word((Log4kf(I, (Cardinal(65535) shl 16) div 12) + (1 shl 15)) shr 16);
  Log4kScale := 65535 div 12;
end;

procedure BitChancePut(var Chance: TBitChance; Bit: Boolean; Table: TBitChanceTable);
begin
  if Bit then
    Chance := Table.Next[1][Chance]
  else
    Chance := Table.Next[0][Chance];
end;

procedure BitChanceEstim(Chance: TBitChance; Bit: Boolean; var Total: QWord);
begin
  if Bit then
    Total := Total + Log4kData[Chance]
  else
    Total := Total + Log4kData[4096 - Chance];
end;

// ---- table cache ----

type
  TCacheEntry = record
    Cut: Integer;
    Alpha: Cardinal;
    Table: TBitChanceTable;
  end;

var
  Cache: array of TCacheEntry;

function GetBitChanceTable(Cut: Integer; Alpha: Cardinal): TBitChanceTable;
var
  I, N: Integer;
begin
  for I := 0 to High(Cache) do
    if (Cache[I].Cut = Cut) and (Cache[I].Alpha = Alpha) then
      Exit(Cache[I].Table);
  N := Length(Cache);
  SetLength(Cache, N + 1);
  Cache[N].Cut := Cut;
  Cache[N].Alpha := Alpha;
  Cache[N].Table := TBitChanceTable.Create(Cut, Alpha);
  Result := Cache[N].Table;
end;

procedure FreeBitChanceTableCache;
var
  I: Integer;
begin
  for I := 0 to High(Cache) do
    Cache[I].Table.Free;
  SetLength(Cache, 0);
end;

initialization
  InitLog4k;

finalization
  FreeBitChanceTableCache;

end.
