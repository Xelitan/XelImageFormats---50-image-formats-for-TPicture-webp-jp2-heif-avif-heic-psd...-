// Self test for the forward transform and quantisation.
//
// For each transform size: take a random residual, run the encoder path
// (forward transform, quantise) and then the decoder path (dequantise with the
// exact expression from bpg_hevc_cabac, inverse transform), and report the
// reconstruction error. A correct pair keeps the error at roughly the
// quantisation step; a wrong scaling shows up immediately as a huge error or as
// a systematic bias.
program t_transform;

{$mode Delphi}
{$H+}
{$POINTERMATH ON}

uses
  SysUtils, bpg_common, bpg_hevcdsp, bpg_hevcdsp_enc;

const
  level_scale: array[0..5] of Integer = (40, 45, 51, 57, 64, 72);

var
  Seed: Cardinal = 987654321;

function Rnd(N: Integer): Integer;
begin
  Seed := Seed * 1103515245 + 12345;
  Result := Integer((Seed shr 16) mod Cardinal(N));
end;

// the dequantisation performed by ff_hevc_hls_residual_coding
procedure dequant(C: PInt16; Log2Size, Qp, BitDepth: Integer);
var
  I, N, Shift, Add, Scale: Integer;
  V: Int64;
begin
  N := 1 shl (2 * Log2Size);
  Shift := BitDepth + Log2Size - 5;
  Add := 1 shl (Shift - 1);
  Scale := level_scale[Qp mod 6] shl (Qp div 6);
  for I := 0 to N - 1 do
  begin
    V := SarInt64(Int64(C[I]) * Scale * 16 + Add, Shift);
    if V > 32767 then V := 32767;
    if V < -32768 then V := -32768;
    C[I] := Int16(V);
  end;
end;

var
  Orig, Work: array[0 .. 32 * 32 - 1] of Int16;
  Log2Size, Size, N, I, Qp, NZ, D, MaxErr, SumAbs, SumErr, Bias: Integer;
  Trial, Trials: Integer;
  UseDST: Boolean;
  Ok: Boolean;
begin
  hevc_transform_init;
  Ok := True;

  for Qp in [4, 16, 26, 34, 45] do
  begin
    WriteLn('qp=', Qp);
    for Log2Size := 2 to 5 do
    begin
      Size := 1 shl Log2Size;
      N := Size * Size;
      for UseDST in [False, True] do
      begin
        if UseDST and (Log2Size <> 2) then Continue;
        MaxErr := 0; SumAbs := 0; SumErr := 0; NZ := 0; Trials := 0;
        for Trial := 1 to 20 do
        begin
        for I := 0 to N - 1 do
          Orig[I] := Int16(Rnd(161) - 80);
        Move(Orig, Work, N * SizeOf(Int16));

        fwd_transform(@Work[0], Log2Size, 8, UseDST);
        NZ := NZ + quantize(@Work[0], Log2Size, Qp, 8, True);
        dequant(@Work[0], Log2Size, Qp, 8);
        if UseDST then
          transform_4x4_luma(@Work[0], 8)
        else
          idct(Log2Size - 2, @Work[0], Size, 8);

        for I := 0 to N - 1 do
        begin
          D := Work[I] - Orig[I];
          SumErr := SumErr + D;
          if Abs(D) > MaxErr then MaxErr := Abs(D);
          SumAbs := SumAbs + Abs(D);
        end;
        Inc(Trials, N);
        end;
        // averaged over 20 random blocks so the bias estimate is meaningful
        // even for a 4x4, which holds only 16 samples
        Bias := SumErr div Trials;
        NZ := NZ div 20;
        WriteLn(Format('  %2dx%-2d %s nz=%-4d maxerr=%-4d meanabs=%-3d bias=%d',
          [Size, Size, BoolToStr(UseDST, 'DST', 'DCT'), NZ, MaxErr,
           SumAbs div Trials, Bias]));
        // a correct pair keeps the mean error well under the quantisation step
        // and shows no systematic bias
        if Abs(Bias) > 3 then
        begin
          WriteLn('    FAIL: systematic bias');
          Ok := False;
        end;
        if (Qp <= 16) and (SumAbs div Trials > 12) then
        begin
          WriteLn('    FAIL: error too large for this qp');
          Ok := False;
        end;
      end;
    end;
  end;

  if Ok then WriteLn('transform round trip OK') else Halt(1);
end.
