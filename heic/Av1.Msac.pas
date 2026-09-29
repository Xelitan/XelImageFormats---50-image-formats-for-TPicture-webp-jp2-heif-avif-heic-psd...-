unit Av1.Msac;

// AV1 multi-symbol arithmetic (entropy) decoder — msac.
//
// Bit-exact pure-Pascal port of dav1d's src/msac.c (BSD-2). The context uses a
// 64-bit decode window (ec_win). CDFs are stored INVERSE, Q15 (cdf[i] decreasing
// toward 0, cdf[n_symbols] holds the adaptation counter), matching dav1d.
//
// Reference: dav1d src/msac.c, src/msac.h.

{$mode delphi}{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, Av1.Bits;

const
  EC_PROB_SHIFT = 6;
  EC_MIN_PROB = 4;
  EC_WIN_SIZE = 64;

type
  PWordArray = ^TWordArrayU;
  TWordArrayU = array[0..65535] of Word;

  TMsac = record
    BufPos: PByte;
    BufEnd: PByte;
    Dif: QWord;
    Rng: LongWord;
    Cnt: LongInt;
    AllowUpdateCdf: Boolean;
  end;

procedure MsacInit(var S: TMsac; AData: PByte; ASize: NativeInt;
  ADisableCdfUpdate: Boolean);

// Core: decode a symbol against an inverse-CDF array of n_symbols+1 entries.
function MsacDecodeSymbolAdapt(var S: TMsac; Cdf: PWord; NSymbols: Integer): LongWord;
function MsacDecodeBoolEqui(var S: TMsac): LongWord;
function MsacDecodeBool(var S: TMsac; F: LongWord): LongWord;
function MsacDecodeBoolAdapt(var S: TMsac; Cdf: PWord): LongWord;
function MsacDecodeBools(var S: TMsac; N: Integer): LongWord;
function MsacDecodeUniform(var S: TMsac; N: LongWord): Integer;
function MsacDecodeSubexp(var S: TMsac; Ref, N: Integer; K: LongWord): Integer;
function MsacDecodeHiTok(var S: TMsac; Cdf: PWord): LongWord;

implementation

// index a uint16 CDF pointer
function CdfAt(Cdf: PWord; I: Integer): PWord; inline;
begin
  Result := PWord(PByte(Cdf) + I * 2);
end;

procedure CtxRefill(var S: TMsac);
var
  C: Integer;
  Dif: QWord;
begin
  C := EC_WIN_SIZE - S.Cnt - 24;
  Dif := S.Dif;
  while (C >= 0) and (NativeUInt(S.BufPos) < NativeUInt(S.BufEnd)) do
  begin
    Dif := Dif xor (QWord(S.BufPos^) shl C);
    Inc(S.BufPos);
    Dec(C, 8);
  end;
  S.Dif := Dif;
  S.Cnt := EC_WIN_SIZE - C - 24;
end;

procedure CtxNorm(var S: TMsac; ADif: QWord; ARng: LongWord);
var
  D: Integer;
begin
  D := 15 - FloorLog2(ARng);
  Dec(S.Cnt, D);
  S.Dif := ((ADif + 1) shl D) - 1;
  S.Rng := ARng shl D;
  if S.Cnt < 0 then
    CtxRefill(S);
end;

procedure MsacInit(var S: TMsac; AData: PByte; ASize: NativeInt;
  ADisableCdfUpdate: Boolean);
begin
  S.BufPos := AData;
  S.BufEnd := AData + ASize;
  S.Dif := (QWord(1) shl (EC_WIN_SIZE - 1)) - 1;
  S.Rng := $8000;
  S.Cnt := -15;
  S.AllowUpdateCdf := not ADisableCdfUpdate;
  CtxRefill(S);
end;

function MsacDecodeSymbolAdapt(var S: TMsac; Cdf: PWord; NSymbols: Integer): LongWord;
var
  C, R, U, V, Val: LongWord;
  Count, Rate, I: LongWord;
  P: PWord;
begin
  C := LongWord(S.Dif shr (EC_WIN_SIZE - 16));
  R := S.Rng shr 8;
  V := S.Rng;
  Val := LongWord(-1);
  repeat
    Inc(Val);
    U := V;
    P := CdfAt(Cdf, Val);
    V := R * (P^ shr EC_PROB_SHIFT);
    V := V shr (7 - EC_PROB_SHIFT);
    V := V + LongWord(EC_MIN_PROB) * (LongWord(NSymbols) - Val);
  until C >= V;

  CtxNorm(S, S.Dif - (QWord(V) shl (EC_WIN_SIZE - 16)), U - V);

  if S.AllowUpdateCdf then
  begin
    Count := CdfAt(Cdf, NSymbols)^;
    Rate := 4 + (Count shr 4);
    if NSymbols > 2 then Inc(Rate);
    I := 0;
    while I < Val do
    begin
      P := CdfAt(Cdf, I);
      P^ := P^ + ((32768 - P^) shr Rate);
      Inc(I);
    end;
    while I < LongWord(NSymbols) do
    begin
      P := CdfAt(Cdf, I);
      P^ := P^ - (P^ shr Rate);
      Inc(I);
    end;
    if Count < 32 then
      CdfAt(Cdf, NSymbols)^ := Count + 1;
  end;

  Result := Val;
end;

function MsacDecodeBoolEqui(var S: TMsac): LongWord;
var
  R, V, Ret: LongWord;
  Dif, Vw: QWord;
begin
  R := S.Rng;
  Dif := S.Dif;
  V := ((R shr 8) shl 7) + EC_MIN_PROB;
  Vw := QWord(V) shl (EC_WIN_SIZE - 16);
  if Dif >= Vw then Ret := 1 else Ret := 0;
  Dif := Dif - Ret * Vw;
  V := V + Ret * (R - 2 * V);
  CtxNorm(S, Dif, V);
  Result := 1 - Ret;
end;

function MsacDecodeBool(var S: TMsac; F: LongWord): LongWord;
var
  R, V, Ret: LongWord;
  Dif, Vw: QWord;
begin
  R := S.Rng;
  Dif := S.Dif;
  V := ((R shr 8) * (F shr EC_PROB_SHIFT) shr (7 - EC_PROB_SHIFT)) + EC_MIN_PROB;
  Vw := QWord(V) shl (EC_WIN_SIZE - 16);
  if Dif >= Vw then Ret := 1 else Ret := 0;
  Dif := Dif - Ret * Vw;
  V := V + Ret * (R - 2 * V);
  CtxNorm(S, Dif, V);
  Result := 1 - Ret;
end;

function MsacDecodeBoolAdapt(var S: TMsac; Cdf: PWord): LongWord;
var
  Bit, Count: LongWord;
  Rate: Integer;
  P0, P1: PWord;
begin
  P0 := Cdf;
  P1 := CdfAt(Cdf, 1);
  Bit := MsacDecodeBool(S, P0^);
  if S.AllowUpdateCdf then
  begin
    Count := P1^;
    Rate := 4 + (Count shr 4);
    if Bit <> 0 then
      P0^ := P0^ + ((32768 - P0^) shr Rate)
    else
      P0^ := P0^ - (P0^ shr Rate);
    if Count < 32 then
      P1^ := Count + 1;
  end;
  Result := Bit;
end;

function MsacDecodeBools(var S: TMsac; N: Integer): LongWord;
begin
  Result := 0;
  while N > 0 do
  begin
    Result := (Result shl 1) or MsacDecodeBoolEqui(S);
    Dec(N);
  end;
end;

function MsacDecodeUniform(var S: TMsac; N: LongWord): Integer;
var
  L: Integer;
  M, V: LongWord;
begin
  L := FloorLog2(N) + 1;
  M := (LongWord(1) shl L) - N;
  V := MsacDecodeBools(S, L - 1);
  if V < M then
    Result := Integer(V)
  else
    Result := Integer((V shl 1) - M + MsacDecodeBoolEqui(S));
end;

function InvRecenter(R, V: LongWord): LongWord;
begin
  if V > (R shl 1) then
    Result := V
  else if (V and 1) = 0 then
    Result := (V shr 1) + R
  else
    Result := R - ((V + 1) shr 1);
end;

function MsacDecodeSubexp(var S: TMsac; Ref, N: Integer; K: LongWord): Integer;
var
  A, V: LongWord;
begin
  A := 0;
  if MsacDecodeBoolEqui(S) <> 0 then
  begin
    if MsacDecodeBoolEqui(S) <> 0 then
      K := K + MsacDecodeBoolEqui(S) + 1;
    A := LongWord(1) shl K;
  end;
  V := MsacDecodeBools(S, K) + A;
  if Ref * 2 <= N then
    Result := Integer(InvRecenter(LongWord(Ref), V))
  else
    Result := N - 1 - Integer(InvRecenter(LongWord(N - 1 - Ref), V));
end;

function MsacDecodeHiTok(var S: TMsac; Cdf: PWord): LongWord;
var
  TokBr, Tok: LongWord;
begin
  TokBr := MsacDecodeSymbolAdapt(S, Cdf, 3);
  Tok := 3 + TokBr;
  if TokBr = 3 then
  begin
    TokBr := MsacDecodeSymbolAdapt(S, Cdf, 3);
    Tok := 6 + TokBr;
    if TokBr = 3 then
    begin
      TokBr := MsacDecodeSymbolAdapt(S, Cdf, 3);
      Tok := 9 + TokBr;
      if TokBr = 3 then
        Tok := 12 + MsacDecodeSymbolAdapt(S, Cdf, 3);
    end;
  end;
  Result := Tok;
end;

end.
