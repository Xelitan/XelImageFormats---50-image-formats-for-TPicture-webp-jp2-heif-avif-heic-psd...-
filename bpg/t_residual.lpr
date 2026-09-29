// Tests the two pieces of residual coding whose maths I derived rather than
// mirrored line by line, and which are therefore the likeliest to be wrong:
//
//   * split_last_sig -- the prefix/suffix split of a last-significant position;
//     checked against the reassembly the decoder performs.
//   * coeff_abs_level_remaining -- the Golomb-Rice / exp-Golomb hybrid; encoded
//     through the real bypass engine and decoded with a copy of
//     coeff_abs_level_remaining_decode taken verbatim from bpg_hevc_cabac.
//
// The rest of ff_hevc_hls_residual_coding_enc is a statement-for-statement
// mirror of the decoder in the same unit, so it is covered by the end-to-end
// encode/decode test once the slice encoder exists.
program t_residual;

{$mode Delphi}
{$H+}
{$POINTERMATH ON}

uses
  SysUtils, bpg_common, bpg_cabac, bpg_cabac_enc, bpg_putbits, bpg_hevc_cabac;

var
  Bad: Integer = 0;

// the reassembly performed by ff_hevc_hls_residual_coding
function join_last_sig(Prefix, Suffix: Integer): Integer;
begin
  if Prefix > 3 then
    Result := (1 shl ((Prefix shr 1) - 1)) * (2 + (Prefix and 1)) + Suffix
  else
    Result := Prefix;
end;

// verbatim from bpg_hevc_cabac.coeff_abs_level_remaining_decode
function dec_remaining(var C: TCABACContext; RcRiceParam: Integer): Integer;
var
  Prefix, Suffix, I, prefix_minus3: Integer;
begin
  Prefix := 0;
  Suffix := 0;
  while (Prefix < 31) and (get_cabac_bypass(C) <> 0) do Inc(Prefix);
  if Prefix < 3 then
  begin
    for I := 0 to RcRiceParam - 1 do
      Suffix := (Suffix shl 1) or get_cabac_bypass(C);
    Result := (Prefix shl RcRiceParam) + Suffix;
  end
  else
  begin
    prefix_minus3 := Prefix - 3;
    for I := 0 to prefix_minus3 + RcRiceParam - 1 do
      Suffix := (Suffix shl 1) or get_cabac_bypass(C);
    Result := (((1 shl prefix_minus3) + 3 - 1) shl RcRiceParam) + Suffix;
  end;
end;

var
  V, P, Sx, L, Got, Rice, N: Integer;
  Buf: TByteBuf;
  E: TCabacEncoder;
  D: TCABACContext;
  Vals: array[0 .. 8191] of Integer;
  Rices: array[0 .. 8191] of Integer;
begin
  // --- last significant position ---
  for V := 0 to 31 do
  begin
    split_last_sig_test(V, P, Sx, L);
    Got := join_last_sig(P, Sx);
    if Got <> V then
    begin
      WriteLn(Format('  last_sig MISMATCH v=%d prefix=%d suffix=%d len=%d back=%d',
        [V, P, Sx, L, Got]));
      Inc(Bad);
    end;
    // the suffix must fit in the bits the decoder will read for it
    if (L > 0) and (Sx >= (1 shl L)) then
    begin
      WriteLn(Format('  last_sig suffix overflow v=%d suffix=%d len=%d', [V, Sx, L]));
      Inc(Bad);
    end;
  end;
  if Bad = 0 then WriteLn('last significant position split OK (0..31)');

  // --- coeff_abs_level_remaining ---
  N := 0;
  for Rice := 0 to 4 do
  begin
    for V := 0 to 700 do
    begin
      Vals[N] := V; Rices[N] := Rice; Inc(N);
    end;
    // large levels really do occur at low qp
    V := 700;
    while V < 40000 do
    begin
      Vals[N] := V; Rices[N] := Rice; Inc(N);
      V := V + 617;
    end;
  end;

  buf_init(Buf);
  cabac_enc_init(E, @Buf);
  for V := 0 to N - 1 do
    enc_coeff_abs_level_remaining_test(E, Vals[V], Rices[V]);
  cabac_enc_terminate(E, 1);
  cabac_enc_finish(E);

  ff_init_cabac_decoder(D, Buf.Buf, Buf.Len);
  for V := 0 to N - 1 do
  begin
    Got := dec_remaining(D, Rices[V]);
    if Got <> Vals[V] then
    begin
      if Bad < 6 then
        WriteLn(Format('  remaining MISMATCH value=%d rice=%d got=%d',
          [Vals[V], Rices[V], Got]));
      Inc(Bad);
    end;
  end;

  if Bad = 0 then
  begin
    WriteLn(Format('coeff_abs_level_remaining OK (%d values, %d bytes)', [N, Buf.Len]));
    WriteLn('residual coding helpers OK');
  end
  else
  begin
    WriteLn(Format('FAILED: %d mismatches', [Bad]));
    Halt(1);
  end;
  buf_free(Buf);
end.
