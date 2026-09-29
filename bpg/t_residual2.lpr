// Round-trip test for the WHOLE residual coder.
//
// This is the test that should have existed from the start. t_residual only
// covers the two helper functions whose maths was derived rather than mirrored;
// everything else was assumed covered by the end-to-end encode/decode runs. It
// was not: those runs never used a quantiser low enough to produce large
// coefficient levels, so a defect that only shows up at qp 0..8 survived.
//
// Here random quantised blocks are written with ff_hevc_hls_residual_coding_enc
// and read back with ff_hevc_hls_residual_coding, over every transform size,
// luma and chroma, all three scan orders, and level magnitudes spanning 1 to
// 32767. The decoder is diverted through residual_capture so the dequantised
// coefficients can be compared directly.
program t_residual2;

{$mode Delphi}
{$H+}
{$POINTERMATH ON}

uses
  SysUtils, bpg_common, bpg_hevc_defs, bpg_bits, bpg_cabac, bpg_cabac_enc,
  bpg_putbits, bpg_hevc_cabac, bpg_hevc, bpg_enc;

const
  MaxLevs: array[0..4] of Integer = (1, 3, 20, 500, 32767);

var
  Seed: Cardinal = 20250731;

function Rnd(N: Integer): Integer;
begin
  Seed := Seed * 1103515245 + 12345;
  Result := Integer((Seed shr 16) mod Cardinal(N));
end;

var
  Enc: TBpgEncoder;
  S: PHEVCContext;
  Sent, Got, Deq: array[0 .. 32 * 32 - 1] of Int16;
  Save: array[0 .. HEVC_CONTEXTS - 1] of Byte;
  Buf: TByteBuf;
  E: TCabacEncoder;
  Log2Size, ScanIdx, CIdx, N, I, Trial, MaxLev, Bad, Cases, NzWanted: Integer;
  LevIdx: Integer;
  Lvl: Integer;
  Desc: string;
begin
  // the context the decoder needs; bpg_enc_init already builds a real one
  if bpg_enc_init(Enc, 64, 64, 1, 8, 26) < 0 then
  begin
    WriteLn('context setup FAILED');
    Halt(1);
  end;
  S := @Enc.Ctx;
  S^.HEVClc^.cu.pred_mode := MODE_INTRA;
  S^.HEVClc^.cu.cu_transquant_bypass_flag := 0;
  S^.HEVClc^.tu.intra_pred_mode := 0;

  Bad := 0;
  Cases := 0;

  for Log2Size := 2 to 5 do
    for CIdx := 0 to 1 do
      for ScanIdx := 0 to 2 do
        for LevIdx := 0 to High(MaxLevs) do
          for Trial := 1 to 6 do
          begin
            // the format only uses the non-diagonal scans for transforms
            // smaller than 16x16, and the inverse scan tables are sized for
            // that, so anything else is outside the domain
            if (ScanIdx <> SCAN_DIAG) and (Log2Size >= 4) then Continue;
            MaxLev := MaxLevs[LevIdx];
            N := 1 shl (2 * Log2Size);
            FillChar(Sent, SizeOf(Sent), 0);
            // a sparse block, as quantisation actually produces
            NzWanted := 1 + Rnd(N div 2 + 1);
            for I := 1 to NzWanted do
            begin
              Lvl := 1 + Rnd(MaxLev);
              if Rnd(2) = 0 then Lvl := -Lvl;
              Sent[Rnd(N)] := Int16(Lvl);
            end;
            // the writer requires at least one non-zero coefficient
            if Sent[0] = 0 then Sent[0] := Int16(1 + Rnd(MaxLev));
            // the PPS built by bpg_enc_init enables sign data hiding, so the
            // parity pre-pass belongs to the writer's contract
            sign_hide_adjust(S, @Sent[0], nil, Log2Size, ScanIdx, 26);

            Move(S^.HEVClc^.cabac_state, Save, SizeOf(Save));
            buf_init(Buf);
            cabac_enc_init(E, @Buf);
            ff_hevc_hls_residual_coding_enc(S, E, @Sent[0], Log2Size, ScanIdx, CIdx);
            cabac_enc_terminate(E, 1);
            cabac_enc_finish(E);

            // rewind the context states and read it back
            Move(Save, S^.HEVClc^.cabac_state, SizeOf(Save));
            ff_init_cabac_decoder(S^.HEVClc^.cc, Buf.Buf, Buf.Len);
            FillChar(Got, SizeOf(Got), 0);
            residual_capture := @Got[0];
            ff_hevc_hls_residual_coding(S, 0, 0, Log2Size, ScanIdx, CIdx);
            residual_capture := nil;

            // the decoder dequantises on the way out, so scale the input the
            // same way before comparing
            Move(Sent, Deq, N * SizeOf(Int16));
            dequant_for_test(S, @Deq[0], Log2Size, CIdx, Enc.Qp);

            Inc(Cases);
            for I := 0 to N - 1 do
              if Got[I] <> Deq[I] then
              begin
                Desc := Format('%dx%d cidx=%d scan=%d maxlev=%d',
                  [1 shl Log2Size, 1 shl Log2Size, CIdx, ScanIdx, MaxLev]);
                if Bad < 8 then
                  WriteLn(Format('  MISMATCH %-28s pos=%-4d sent=%-6d got=%-6d want=%d',
                    [Desc, I, Sent[I], Got[I], Deq[I]]));
                Inc(Bad);
                Break;
              end;
            buf_free(Buf);
          end;

  if Bad = 0 then
    WriteLn(Format('residual coder round trip OK (%d blocks)', [Cases]))
  else
  begin
    WriteLn(Format('FAILED: %d of %d blocks differ', [Bad, Cases]));
    Halt(1);
  end;
  bpg_enc_free(Enc);
end.
