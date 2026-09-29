// Smoke test for the intra encoder, before the BPG container exists.
//
// Encodes a synthetic picture and checks the encoder's own reconstruction
// against the source. SAO and deblocking are off, so the reconstruction is
// exactly what a decoder will produce; a large error here means the
// transform/quantisation path or the prediction is wrong, while a bitstream
// that decodes to something else entirely would only show up once the
// container and CLI let bpgdec.exe read it.
program t_enc;

{$mode Delphi}
{$H+}
{$POINTERMATH ON}

uses
  SysUtils, bpg_common, bpg_hevc_defs, bpg_frame, bpg_enc;

var
  Enc: TBpgEncoder;
  W, H, X, Y, C, Qp: Integer;
  P: PWord;
  Stride, N, D, MaxErr, SumAbs: Integer;
  Rec, Src: PWord;
  RecStride, SrcStride: Integer;
  Ok: Boolean;
begin
  Ok := True;
  for Qp in [10, 26, 38] do
  begin
    W := 96;
    H := 72;
    if bpg_enc_init(Enc, W, H, 1, 8, Qp) < 0 then
    begin
      WriteLn('encoder init FAILED');
      Halt(1);
    end;

    // a smooth gradient plus a hard edge, so both flat and detailed areas are
    // exercised
    for C := 0 to 2 do
    begin
      Stride := Enc.Src^.Linesize[C] div SizeOf(Word);
      P := PWord(Enc.Src^.Data[C]);
      for Y := 0 to (H shr Ord(C > 0)) - 1 do
        for X := 0 to (W shr Ord(C > 0)) - 1 do
          if C = 0 then
          begin
            if X > (W div 2) then P[Y * Stride + X] := 200
            else P[Y * Stride + X] := Word((X * 3 + Y * 2) and 255);
          end
          else
            P[Y * Stride + X] := Word(100 + C * 20 + ((X + Y) and 31));
    end;

    if bpg_enc_picture(Enc) < 0 then
    begin
      WriteLn('encode FAILED');
      Halt(1);
    end;

    // luma reconstruction versus source
    RecStride := Enc.Ctx.frame^.Linesize[0] div SizeOf(Word);
    SrcStride := Enc.Src^.Linesize[0] div SizeOf(Word);
    Rec := PWord(Enc.Ctx.frame^.Data[0]);
    Src := PWord(Enc.Src^.Data[0]);
    MaxErr := 0;
    SumAbs := 0;
    N := 0;
    for Y := 0 to H - 1 do
      for X := 0 to W - 1 do
      begin
        D := Rec[Y * RecStride + X] - Src[Y * SrcStride + X];
        if Abs(D) > MaxErr then MaxErr := Abs(D);
        SumAbs := SumAbs + Abs(D);
        Inc(N);
      end;

    WriteLn(Format('qp=%-3d slice %5d bytes  luma maxerr=%-4d meanabs=%d',
      [Qp, Enc.SliceRbsp.Len, MaxErr, SumAbs div N]));

    if Enc.SliceRbsp.Len < 8 then
    begin
      WriteLn('  FAIL: slice suspiciously short');
      Ok := False;
    end;
    // at qp 10 the reconstruction should be very close to the source
    if (Qp = 10) and (SumAbs div N > 4) then
    begin
      WriteLn('  FAIL: reconstruction error too large for qp 10');
      Ok := False;
    end;
    if MaxErr > 200 then
    begin
      WriteLn('  FAIL: reconstruction diverged');
      Ok := False;
    end;

    bpg_enc_free(Enc);
  end;

  if Ok then WriteLn('encoder reconstruction OK') else Halt(1);
end.
