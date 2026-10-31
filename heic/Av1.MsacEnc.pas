unit Av1.MsacEnc;

// AV1 multi-symbol arithmetic encoder (the inverse of Av1.Msac), with CDF
// adaptation identical to the decoder's. CDFs use dav1d's inverse-Q15 layout
// (the same tables the decoder adapts), so an encoder and a decoder that walk
// the same symbol sequence stay in lock-step.
//
// Port of libaom aom_dsp/entenc.c (od_ec_enc*, BSD-2-Clause).

{$mode delphi}{$H+}
{$RANGECHECKS OFF}{$OVERFLOWCHECKS OFF}{$POINTERMATH ON}

interface

uses SysUtils;

type
  TMsacEnc = record
    Precarry: array of Word;
    Offs: Integer;
    Low: LongWord;
    Rng: LongWord;
    Cnt: Integer;
    AllowUpdateCdf: Boolean;
  end;

procedure MsacEncInit(var E: TMsacEnc; ADisableCdfUpdate: Boolean);
// Symbol S in 0..NSymbols (NSymbols = alphabet size - 1, as the decoder takes).
procedure MsacEncSymbolAdapt(var E: TMsacEnc; Cdf: PWord; S, NSymbols: Integer);
procedure MsacEncBoolAdapt(var E: TMsacEnc; Cdf: PWord; Bit: Integer);
// Bool with a fixed probability F (as passed to MsacDecodeBool).
procedure MsacEncBool(var E: TMsacEnc; Bit: Integer; F: LongWord);
procedure MsacEncBoolEqui(var E: TMsacEnc; Bit: Integer);
procedure MsacEncBools(var E: TMsacEnc; V: LongWord; N: Integer);
procedure MsacEncUniform(var E: TMsacEnc; V, N: LongWord);
procedure MsacEncGolomb(var E: TMsacEnc; V: LongWord);
// br_tok "hi token" (value 3..15 continues from base token 3).
procedure MsacEncHiTok(var E: TMsacEnc; Cdf: PWord; Tok: Integer);
// Flushes the coder; returns the coded bytes.
function MsacEncDone(var E: TMsacEnc): TBytes;

implementation

const
  EC_PROB_SHIFT = 6;
  EC_MIN_PROB = 4;

function ILogNz(X: LongWord): Integer; inline;
begin
  Result := 0;
  while X <> 0 do begin X := X shr 1; Inc(Result); end;
end;

procedure PutPrecarry(var E: TMsacEnc; V: Word); inline;
begin
  if E.Offs >= Length(E.Precarry) then SetLength(E.Precarry, E.Offs * 2 + 1024);
  E.Precarry[E.Offs] := V;
  Inc(E.Offs);
end;

procedure MsacEncInit(var E: TMsacEnc; ADisableCdfUpdate: Boolean);
begin
  SetLength(E.Precarry, 4096);
  E.Offs := 0;
  E.Low := 0;
  E.Rng := $8000;
  E.Cnt := -9;
  E.AllowUpdateCdf := not ADisableCdfUpdate;
end;

procedure Normalize(var E: TMsacEnc; Low: LongWord; Rng: LongWord);
var d, c, s: Integer; m: LongWord;
begin
  c := E.Cnt;
  d := 16 - ILogNz(Rng);
  s := c + d;
  if s >= 0 then
  begin
    Inc(c, 16);
    m := (LongWord(1) shl c) - 1;
    if s >= 8 then
    begin
      PutPrecarry(E, Word(Low shr c));
      Low := Low and m;
      Dec(c, 8);
      m := m shr 8;
    end;
    PutPrecarry(E, Word(Low shr c));
    s := c + d - 24;
    Low := Low and m;
  end;
  E.Low := Low shl d;
  E.Rng := Rng shl d;
  E.Cnt := s;
end;

// od_ec_encode_q15: fl / fh are the inverse CDF values bounding symbol S.
procedure EncodeQ15(var E: TMsacEnc; Fl, Fh: LongWord; S, NSymbols: Integer);
var l, r, u, v: LongWord;
begin
  l := E.Low; r := E.Rng;
  if Fl < 32768 then
  begin
    u := (((r shr 8) * (Fl shr EC_PROB_SHIFT)) shr (7 - EC_PROB_SHIFT)) + LongWord(EC_MIN_PROB * (NSymbols - (S - 1)));
    v := (((r shr 8) * (Fh shr EC_PROB_SHIFT)) shr (7 - EC_PROB_SHIFT)) + LongWord(EC_MIN_PROB * (NSymbols - S));
    l := l + r - u;
    r := u - v;
  end
  else
    r := r - ((((r shr 8) * (Fh shr EC_PROB_SHIFT)) shr (7 - EC_PROB_SHIFT)) + LongWord(EC_MIN_PROB * (NSymbols - S)));
  Normalize(E, l, r);
end;

procedure MsacEncSymbolAdapt(var E: TMsacEnc; Cdf: PWord; S, NSymbols: Integer);
var fl: LongWord; count, rate, i: LongWord; p: PWord;
begin
  if S > 0 then fl := Cdf[S - 1] else fl := 32768;
  EncodeQ15(E, fl, Cdf[S], S, NSymbols);
  if E.AllowUpdateCdf then
  begin
    count := Cdf[NSymbols];
    rate := 4 + (count shr 4);
    if NSymbols > 2 then Inc(rate);
    i := 0;
    while i < LongWord(S) do
    begin
      p := Cdf + i;
      p^ := p^ + ((32768 - p^) shr rate);
      Inc(i);
    end;
    while i < LongWord(NSymbols) do
    begin
      p := Cdf + i;
      p^ := p^ - (p^ shr rate);
      Inc(i);
    end;
    if count < 32 then Cdf[NSymbols] := count + 1;
  end;
end;

procedure MsacEncBool(var E: TMsacEnc; Bit: Integer; F: LongWord);
var l, r, v: LongWord;
begin
  l := E.Low; r := E.Rng;
  v := (((r shr 8) * (F shr EC_PROB_SHIFT)) shr (7 - EC_PROB_SHIFT)) + EC_MIN_PROB;
  if Bit <> 0 then
  begin
    l := l + r - v;
    r := v;
  end
  else
    r := r - v;
  Normalize(E, l, r);
end;

procedure MsacEncBoolAdapt(var E: TMsacEnc; Cdf: PWord; Bit: Integer);
var count: LongWord; rate: Integer;
begin
  MsacEncBool(E, Bit, Cdf[0]);
  if E.AllowUpdateCdf then
  begin
    count := Cdf[1];
    rate := 4 + (count shr 4);
    if Bit <> 0 then Cdf[0] := Cdf[0] + ((32768 - Cdf[0]) shr rate)
    else Cdf[0] := Cdf[0] - (Cdf[0] shr rate);
    if count < 32 then Cdf[1] := count + 1;
  end;
end;

procedure MsacEncBoolEqui(var E: TMsacEnc; Bit: Integer);
begin
  MsacEncBool(E, Bit, 16384);
end;

procedure MsacEncBools(var E: TMsacEnc; V: LongWord; N: Integer);
var i: Integer;
begin
  for i := N - 1 downto 0 do MsacEncBoolEqui(E, (V shr i) and 1);
end;

procedure MsacEncUniform(var E: TMsacEnc; V, N: LongWord);
var l: Integer; m: LongWord;
begin
  l := ILogNz(N);           // FloorLog2(N) + 1
  m := (LongWord(1) shl l) - N;
  if V < m then MsacEncBools(E, V, l - 1)
  else
  begin
    MsacEncBools(E, (V + m) shr 1, l - 1);
    MsacEncBoolEqui(E, (V + m) and 1);
  end;
end;

procedure MsacEncGolomb(var E: TMsacEnc; V: LongWord);
var x: LongWord; len, i: Integer;
begin
  x := V + 1;
  len := ILogNz(x) - 1;
  for i := 1 to len do MsacEncBoolEqui(E, 0);
  MsacEncBoolEqui(E, 1);
  for i := len - 1 downto 0 do MsacEncBoolEqui(E, (x shr i) and 1);
end;

procedure MsacEncHiTok(var E: TMsacEnc; Cdf: PWord; Tok: Integer);
var rem, s, k: Integer;
begin
  rem := Tok - 3;
  for k := 0 to 3 do
  begin
    if rem > 3 then s := 3 else s := rem;
    MsacEncSymbolAdapt(E, Cdf, s, 3);
    Dec(rem, s);
    if s < 3 then Break;
  end;
end;

function MsacEncDone(var E: TMsacEnc): TBytes;
var
  l, m, e2, n: LongWord;
  c, s, offs, i: Integer;
  carry: LongWord;
begin
  l := E.Low;
  c := E.Cnt;
  s := 10;
  m := $3FFF;
  e2 := ((l + m) and not m) or (m + 1);
  Inc(s, c);
  if s > 0 then
  begin
    n := (LongWord(1) shl (c + 16)) - 1;
    repeat
      PutPrecarry(E, Word(e2 shr (c + 16)));
      e2 := e2 and n;
      Dec(s, 8);
      Dec(c, 8);
      n := n shr 8;
    until s <= 0;
  end;
  offs := E.Offs;
  SetLength(Result, offs);
  carry := 0;
  for i := offs - 1 downto 0 do
  begin
    carry := E.Precarry[i] + carry;
    Result[i] := Byte(carry);
    carry := carry shr 8;
  end;
end;

end.
