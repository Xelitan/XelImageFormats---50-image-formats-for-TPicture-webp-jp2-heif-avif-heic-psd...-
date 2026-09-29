// Proves that trial_begin / trial_rollback restore everything a speculative
// encode can disturb.
//
// The picture is encoded twice. The second time, every coding unit is encoded
// once inside a trial, rolled back, and then encoded again for real. If the
// rollback is complete the two bitstreams are identical; if anything is left
// behind -- a context state, a reconstructed sample, an entry in tab_ipm that
// changes a later block's most-probable-mode list -- the second encode diverges
// and the comparison fails.
//
// This is deliberately a stronger check than "the picture still decodes": a
// leak would produce a perfectly valid bitstream that simply codes something
// else, which is the failure mode that cost the most time in this project.
program t_trial;

{$mode Delphi}
{$H+}
{$POINTERMATH ON}

uses
  SysUtils, bpg_common, bpg_hevc_defs, bpg_putbits, bpg_enc, bpg_enc_trial;

var
  Trials: Integer = 0;

procedure TrialThenReal(var Enc: TBpgEncoder; X0, Y0, Log2CbSize: Integer);
var
  T: TEncTrial;
  Saved: TEncodeCuProc;
begin
  // the hook must not recurse into itself
  Saved := enc_cu_hook;
  enc_cu_hook := nil;
  trial_begin(T, Enc, X0, Y0, 1 shl Log2CbSize);
  encode_coding_unit(Enc, X0, Y0, Log2CbSize);
  trial_rollback(T);
  encode_coding_unit(Enc, X0, Y0, Log2CbSize);
  Inc(Trials);
  enc_cu_hook := Saved;
end;

procedure FillSource(var Enc: TBpgEncoder; W, H, Cfi: Integer);
var
  X, Y, C, PW, PH: Integer;
begin
  for C := 0 to 2 do
  begin
    if Enc.Src^.Data[C] = nil then Continue;
    PW := Enc.Ctx.sps^.width shr Enc.Ctx.sps^.hshift[C];
    PH := Enc.Ctx.sps^.height shr Enc.Ctx.sps^.vshift[C];
    for Y := 0 to PH - 1 do
      for X := 0 to PW - 1 do
        (PWord(Enc.Src^.Data[C] + Y * Enc.Src^.Linesize[C]) + X)^ :=
          Word((X * 7 + Y * 13 + C * 61 + ((X * Y) shr 3)) and 255);
  end;
end;

function EncodeOnce(W, H, Cfi, Qp: Integer; UseTrial: Boolean;
  out Len: Integer; out Data: PByte): Boolean;
var
  Enc: TBpgEncoder;
begin
  Result := False;
  if bpg_enc_init(Enc, W, H, Cfi, 8, Qp) < 0 then Exit;
  FillSource(Enc, W, H, Cfi);
  if UseTrial then enc_cu_hook := TrialThenReal else enc_cu_hook := nil;
  if bpg_enc_picture(Enc) < 0 then Exit;
  enc_cu_hook := nil;
  Len := Enc.SliceRbsp.Len;
  Data := av_malloc(Len);
  Move(Enc.SliceRbsp.Buf^, Data^, Len);
  bpg_enc_free(Enc);
  Result := True;
end;

var
  LenA, LenB, I, Cfi, Qp, Bad: Integer;
  A, B: PByte;
  W, H: Integer;
begin
  Bad := 0;
  for Cfi in [0, 1, 2, 3] do
    for Qp in [8, 26, 40] do
    begin
      W := 96;
      H := 80;
      if not EncodeOnce(W, H, Cfi, Qp, False, LenA, A) then
      begin
        WriteLn('plain encode FAILED');
        Halt(1);
      end;
      if not EncodeOnce(W, H, Cfi, Qp, True, LenB, B) then
      begin
        WriteLn('trial encode FAILED');
        Halt(1);
      end;
      if (LenA <> LenB) or (not CompareMem(A, B, LenA)) then
      begin
        WriteLn(Format('  MISMATCH cfi=%d qp=%-3d plain=%d bytes trial=%d bytes',
          [Cfi, Qp, LenA, LenB]));
        for I := 0 to LenA - 1 do
          if (I >= LenB) or (A[I] <> B[I]) then
          begin
            WriteLn(Format('    first difference at byte %d', [I]));
            Break;
          end;
        Inc(Bad);
      end
      else
        WriteLn(Format('  cfi=%d qp=%-3d %5d bytes identical', [Cfi, Qp, LenA]));
      av_free(A);
      av_free(B);
    end;

  if Bad = 0 then
    WriteLn(Format('trial rollback OK (%d coding units trialled)', [Trials]))
  else
  begin
    WriteLn(Format('FAILED: %d configurations differ', [Bad]));
    Halt(1);
  end;
end.
