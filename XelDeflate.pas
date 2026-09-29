unit XelDeflate;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses SysUtils;

// RFC1951 raw DEFLATE. Level=0 emits stored blocks, 1..9 uses
// a greedy LZ77 parser and the RFC1951 fixed Huffman trees.
function DeflateRaw(Src: PByte; SrcLen: NativeUInt; Level: Integer = 6): TBytes;
// RFC1950 zlib wrapper (CMF/FLG + Adler-32).
function DeflateZlib(Src: PByte; SrcLen: NativeUInt; Level: Integer = 6): TBytes;

implementation

const
  LBase: array[0..28] of Word =
    (3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258);
  LExt: array[0..28] of Byte =
    (0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0);
  DBase: array[0..29] of Word =
    (1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,
     1025,1537,2049,3073,4097,6145,8193,12289,16385,24577);
  DExt: array[0..29] of Byte =
    (0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13);

  HASH_BITS = 15;
  HASH_SIZE = 1 shl HASH_BITS;
  HASH_MASK = HASH_SIZE - 1;
  WINDOW_SIZE = 32768;
  MAX_MATCH = 258;
  MIN_MATCH = 3;

type
  TBitWriter = class
  private
    FData: TBytes;
    FLen: NativeUInt;
    FBitBuf: Cardinal;
    FBitCnt: Integer;
    procedure Ensure(Extra: NativeUInt);
  public
    procedure WriteBits(Value: Cardinal; Count: Integer);
    procedure AlignByte;
    procedure WriteByte(Value: Byte);
    procedure WriteWordLE(Value: Word);
    procedure WriteBytes(Src: PByte; Count: NativeUInt);
    function Finish: TBytes;
  end;

procedure TBitWriter.Ensure(Extra: NativeUInt);
var
  N: NativeUInt;
begin
  if FLen + Extra <= NativeUInt(Length(FData)) then Exit;
  N := NativeUInt(Length(FData));
  if N < 4096 then N := 4096;
  while N < FLen + Extra do
    N := N + (N shr 1) + 1024;
  SetLength(FData, N);
end;

procedure TBitWriter.WriteBits(Value: Cardinal; Count: Integer);
begin
  if Count <= 0 then Exit;
  FBitBuf := FBitBuf or ((Value and ((Cardinal(1) shl Count) - 1)) shl FBitCnt);
  Inc(FBitCnt, Count);
  while FBitCnt >= 8 do
  begin
    Ensure(1);
    FData[FLen] := Byte(FBitBuf and $FF);
    Inc(FLen);
    FBitBuf := FBitBuf shr 8;
    Dec(FBitCnt, 8);
  end;
end;

procedure TBitWriter.AlignByte;
begin
  if FBitCnt > 0 then
  begin
    Ensure(1);
    FData[FLen] := Byte(FBitBuf and $FF);
    Inc(FLen);
    FBitBuf := 0;
    FBitCnt := 0;
  end;
end;

procedure TBitWriter.WriteByte(Value: Byte);
begin
  AlignByte;
  Ensure(1);
  FData[FLen] := Value;
  Inc(FLen);
end;

procedure TBitWriter.WriteWordLE(Value: Word);
begin
  WriteByte(Byte(Value));
  WriteByte(Byte(Value shr 8));
end;

procedure TBitWriter.WriteBytes(Src: PByte; Count: NativeUInt);
begin
  AlignByte;
  if Count = 0 then Exit;
  Ensure(Count);
  Move(Src^, FData[FLen], Count);
  Inc(FLen, Count);
end;

function TBitWriter.Finish: TBytes;
begin
  AlignByte;
  SetLength(FData, FLen);
  Result := FData;
end;

function ReverseBits(Value: Cardinal; Count: Integer): Cardinal;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Count do
  begin
    Result := (Result shl 1) or (Value and 1);
    Value := Value shr 1;
  end;
end;

procedure FixedLitCode(Symbol: Integer; out Code: Cardinal; out Bits: Integer);
begin
  if Symbol <= 143 then
  begin
    Code := $30 + Cardinal(Symbol);
    Bits := 8;
  end
  else if Symbol <= 255 then
  begin
    Code := $190 + Cardinal(Symbol - 144);
    Bits := 9;
  end
  else if Symbol <= 279 then
  begin
    Code := Cardinal(Symbol - 256);
    Bits := 7;
  end
  else
  begin
    Code := $C0 + Cardinal(Symbol - 280);
    Bits := 8;
  end;
  Code := ReverseBits(Code, Bits);
end;

procedure WriteFixedLit(BW: TBitWriter; Symbol: Integer);
var
  C: Cardinal;
  N: Integer;
begin
  FixedLitCode(Symbol, C, N);
  BW.WriteBits(C, N);
end;

procedure WriteLength(BW: TBitWriter; Len: Integer);
var
  I, Extra: Integer;
begin
  for I := 0 to 28 do
  begin
    if I = 28 then
    begin
      if Len = 258 then Break;
    end
    else if Len < LBase[I + 1] then
      Break;
  end;
  WriteFixedLit(BW, 257 + I);
  if LExt[I] <> 0 then
  begin
    Extra := Len - LBase[I];
    BW.WriteBits(Cardinal(Extra), LExt[I]);
  end;
end;

procedure WriteDistance(BW: TBitWriter; Dist: Integer);
var
  I, Extra: Integer;
begin
  for I := 0 to 29 do
  begin
    if (I = 29) or (Dist < DBase[I + 1]) then Break;
  end;
  // Fixed distance alphabet: 5-bit canonical codes 0..31, transmitted LSB-first.
  BW.WriteBits(ReverseBits(Cardinal(I), 5), 5);
  if DExt[I] <> 0 then
  begin
    Extra := Dist - DBase[I];
    BW.WriteBits(Cardinal(Extra), DExt[I]);
  end;
end;

function Hash3(P: PByte): Cardinal; inline;
begin
  Result := ((Cardinal(P[0]) * 251 + Cardinal(P[1])) * 251 + Cardinal(P[2])) and HASH_MASK;
end;

procedure FindMatch(Src: PByte; N, Pos: NativeInt; const Head, Prev: array of Integer;
  MaxChain: Integer; out BestLen, BestDist: Integer);
var
  H: Cardinal;
  Cur, Limit, Chain, L, MaxL: Integer;
begin
  BestLen := 0;
  BestDist := 0;
  if Pos + MIN_MATCH > N then Exit;

  H := Hash3(@Src[Pos]);
  Cur := Head[H];
  Limit := Pos - WINDOW_SIZE;
  if Limit < 0 then Limit := 0;
  MaxL := N - Pos;
  if MaxL > MAX_MATCH then MaxL := MAX_MATCH;
  Chain := 0;

  while (Cur >= Limit) and (Cur >= 0) and (Chain < MaxChain) do
  begin
    if (Src[Cur] = Src[Pos]) and
       (Src[Cur + BestLen] = Src[Pos + BestLen]) then
    begin
      L := 0;
      while (L < MaxL) and (Src[Cur + L] = Src[Pos + L]) do Inc(L);
      if (L >= MIN_MATCH) and (L > BestLen) then
      begin
        BestLen := L;
        BestDist := Pos - Cur;
        if L = MaxL then Exit;
      end;
    end;
    Cur := Prev[Cur];
    Inc(Chain);
  end;
end;

procedure InsertPos(Src: PByte; N, Pos: NativeInt; var Head, Prev: array of Integer);
var
  H: Cardinal;
begin
  if Pos + MIN_MATCH > N then Exit;
  H := Hash3(@Src[Pos]);
  Prev[Pos] := Head[H];
  Head[H] := Pos;
end;

function DeflateStored(Src: PByte; SrcLen: NativeUInt): TBytes;
var
  BW: TBitWriter;
  Pos, Part: NativeUInt;
  Final: Cardinal;
begin
  BW := TBitWriter.Create;
  try
    Pos := 0;
    repeat
      Part := SrcLen - Pos;
      if Part > 65535 then Part := 65535;
      if Pos + Part >= SrcLen then Final := 1 else Final := 0;
      BW.WriteBits(Final, 1);
      BW.WriteBits(0, 2);
      BW.AlignByte;
      BW.WriteWordLE(Word(Part));
      BW.WriteWordLE(not Word(Part));
      if Part <> 0 then BW.WriteBytes(@Src[Pos], Part);
      Inc(Pos, Part);
    until Pos >= SrcLen;
    Result := BW.Finish;
  finally
    BW.Free;
  end;
end;

function DeflateFixed(Src: PByte; SrcLen: NativeUInt; Level: Integer): TBytes;
var
  BW: TBitWriter;
  Head: array of Integer;
  Prev: array of Integer;
  I, K, N: NativeInt;
  BestLen, BestDist, MaxChain: Integer;
begin
  if SrcLen > NativeUInt(High(NativeInt)) then
    raise Exception.Create('Deflate: input too large');
  N := NativeInt(SrcLen);
  SetLength(Head, HASH_SIZE);
  for K := 0 to HASH_SIZE - 1 do Head[K] := -1;
  SetLength(Prev, N);
  for K := 0 to N - 1 do Prev[K] := -1;

  if Level <= 2 then MaxChain := 16
  else if Level <= 5 then MaxChain := 64
  else if Level <= 7 then MaxChain := 128
  else MaxChain := 256;

  BW := TBitWriter.Create;
  try
    // BFINAL=1, BTYPE=01 (fixed Huffman). Bits are written LSB-first.
    BW.WriteBits(1, 1);
    BW.WriteBits(1, 2);

    I := 0;
    while I < N do
    begin
      FindMatch(Src, N, I, Head, Prev, MaxChain, BestLen, BestDist);
      if BestLen >= MIN_MATCH then
      begin
        WriteLength(BW, BestLen);
        WriteDistance(BW, BestDist);
        for K := I to I + BestLen - 1 do
          InsertPos(Src, N, K, Head, Prev);
        Inc(I, BestLen);
      end
      else
      begin
        WriteFixedLit(BW, Src[I]);
        InsertPos(Src, N, I, Head, Prev);
        Inc(I);
      end;
    end;
    WriteFixedLit(BW, 256);
    Result := BW.Finish;
  finally
    BW.Free;
  end;
end;

function DeflateRaw(Src: PByte; SrcLen: NativeUInt; Level: Integer): TBytes;
begin
  if (Src = nil) and (SrcLen <> 0) then
    raise Exception.Create('Deflate: nil input pointer');
  if Level < 0 then Level := 0;
  if Level > 9 then Level := 9;
  if Level = 0 then
    Result := DeflateStored(Src, SrcLen)
  else
    Result := DeflateFixed(Src, SrcLen, Level);
end;

function Adler32(Src: PByte; Len: NativeUInt): Cardinal;
const
  MOD_ADLER = 65521;
var
  S1, S2: Cardinal;
  I, Block: NativeUInt;
begin
  S1 := 1;
  S2 := 0;
  I := 0;
  while I < Len do
  begin
    Block := Len - I;
    if Block > 5552 then Block := 5552;
    while Block <> 0 do
    begin
      Inc(S1, Src[I]);
      Inc(S2, S1);
      Inc(I);
      Dec(Block);
    end;
    S1 := S1 mod MOD_ADLER;
    S2 := S2 mod MOD_ADLER;
  end;
  Result := (S2 shl 16) or S1;
end;

function DeflateZlib(Src: PByte; SrcLen: NativeUInt; Level: Integer): TBytes;
var
  Raw: TBytes;
  CMF, FLG, FLevel: Byte;
  Check, A: Cardinal;
  P: NativeUInt;
begin
  Raw := DeflateRaw(Src, SrcLen, Level);
  CMF := $78; // CM=8 (DEFLATE), CINFO=7 (32 KiB window)
  if Level <= 0 then FLevel := 0
  else if Level <= 3 then FLevel := 1
  else if Level <= 6 then FLevel := 2
  else FLevel := 3;
  FLG := FLevel shl 6;
  Check := (Cardinal(CMF) shl 8) or FLG;
  if (Check mod 31) <> 0 then
    Inc(FLG, 31 - (Check mod 31));

  SetLength(Result, Length(Raw) + 6);
  Result[0] := CMF;
  Result[1] := FLG;
  if Length(Raw) <> 0 then Move(Raw[0], Result[2], Length(Raw));
  if SrcLen = 0 then A := 1 else A := Adler32(Src, SrcLen);
  P := NativeUInt(Length(Result)) - 4;
  Result[P]     := Byte(A shr 24);
  Result[P + 1] := Byte(A shr 16);
  Result[P + 2] := Byte(A shr 8);
  Result[P + 3] := Byte(A);
end;

end.
