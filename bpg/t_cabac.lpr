// Round-trip self test for the CABAC engine: encodes a pseudo-random mix of
// context-coded bins, bypass bins and terminating bins with bpg_cabac_enc, then
// decodes the result with bpg_cabac and checks that every bin comes back.
program t_cabac;

{$mode Delphi}
{$H+}
{$POINTERMATH ON}

uses
  SysUtils, bpg_common, bpg_cabac, bpg_cabac_enc, bpg_putbits;

const
  NCTX = 8;
  NBIN = 20000;

var
  Seed: Cardinal = 12345;

function Rnd(N: Integer): Integer;
begin
  Seed := Seed * 1103515245 + 12345;
  Result := Integer((Seed shr 16) mod Cardinal(N));
end;

var
  Bins, Kinds, Ctxs: array[0 .. NBIN - 1] of Integer;
  EncState, DecState: array[0 .. NCTX - 1] of Byte;
  Buf: TByteBuf;
  E: TCabacEncoder;
  D: TCABACContext;
  I, Got, Bad, NTerm: Integer;
begin
  // a spread of plausible initial context states
  for I := 0 to NCTX - 1 do
    EncState[I] := Byte(2 * (I * 7 + 3) + (I and 1));
  Move(EncState, DecState, SizeOf(EncState));

  NTerm := 0;
  for I := 0 to NBIN - 1 do
  begin
    // kind 0 = context coded, 1 = bypass, 2 = terminate(0)
    if (I > 0) and (I mod 97 = 0) then Kinds[I] := 2
    else if Rnd(4) = 0 then Kinds[I] := 1
    else Kinds[I] := 0;
    Ctxs[I] := Rnd(NCTX);
    if Kinds[I] = 2 then
    begin
      Bins[I] := 0;
      Inc(NTerm);
    end
    else
      Bins[I] := Rnd(2);
  end;

  buf_init(Buf);
  cabac_enc_init(E, @Buf);
  for I := 0 to NBIN - 1 do
    case Kinds[I] of
      0: cabac_enc_bin(E, @EncState[Ctxs[I]], Bins[I]);
      1: cabac_enc_bypass(E, Bins[I]);
      2: cabac_enc_terminate(E, 0);
    end;
  cabac_enc_terminate(E, 1);
  cabac_enc_finish(E);

  WriteLn(Format('encoded %d bins (%d terminating) into %d bytes',
    [NBIN, NTerm, Buf.Len]));

  ff_init_cabac_decoder(D, Buf.Buf, Buf.Len);
  Bad := 0;
  for I := 0 to NBIN - 1 do
  begin
    case Kinds[I] of
      0: Got := get_cabac(D, @DecState[Ctxs[I]]);
      1: Got := get_cabac_bypass(D);
    else
      Got := Ord(get_cabac_terminate(D) <> 0);
    end;
    if Got <> Bins[I] then
    begin
      if Bad < 5 then
        WriteLn(Format('  mismatch at bin %d: kind=%d ctx=%d want=%d got=%d',
          [I, Kinds[I], Ctxs[I], Bins[I], Got]));
      Inc(Bad);
    end;
  end;

  if Bad = 0 then
  begin
    Got := Ord(get_cabac_terminate(D) <> 0);
    if Got <> 1 then
    begin
      WriteLn('final terminating bin not seen');
      Halt(1);
    end;
    // the context states must have evolved identically on both sides
    for I := 0 to NCTX - 1 do
      if EncState[I] <> DecState[I] then
      begin
        WriteLn(Format('context %d diverged: enc=%d dec=%d',
          [I, EncState[I], DecState[I]]));
        Halt(1);
      end;
    WriteLn('CABAC round trip OK');
  end
  else
  begin
    WriteLn(Format('FAILED: %d of %d bins wrong', [Bad, NBIN]));
    Halt(1);
  end;
  buf_free(Buf);
end.
