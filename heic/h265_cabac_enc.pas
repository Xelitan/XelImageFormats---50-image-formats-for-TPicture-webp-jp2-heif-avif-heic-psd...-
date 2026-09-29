// BPG encoder -- Free Pascal
// CABAC arithmetic encoder, the exact inverse of the decoder in h265_cabac.
// Follows H.265 clause 9.3.4.3 (EncodeDecision, EncodeBypass, EncodeTerminate,
// RenormE, PutBit, EncodeFlush).
//
// There is no encoder in libbpg to port -- it delegates to x265 or the JCTVC HM
// reference encoder -- so this is written from the specification. It reuses the
// state-transition tables exported by h265_cabac, and a context byte has the same
// layout on both sides (2 * pStateIdx + valMPS), so cabac_init_state's output
// drives either engine unchanged.
unit h265_cabac_enc;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  h265_common, h265_cabac, h265_putbits;

type
  TCabacEncoder = record
    Out_: PByteBuf;
    Low: Cardinal;
    Range: Cardinal;
    BitsOutstanding: Integer;
    FirstBitFlag: Boolean;
    // partial output byte
    Cache: Cardinal;
    NBits: Integer;
  end;

procedure cabac_enc_init(var E: TCabacEncoder; Out_: PByteBuf);
// State is the context byte, updated in place.
procedure cabac_enc_bin(var E: TCabacEncoder; State: PByte; Bin: Integer);
procedure cabac_enc_bypass(var E: TCabacEncoder; Bin: Integer);
procedure cabac_enc_bypass_bits(var E: TCabacEncoder; N: Integer; V: Cardinal);
// end_of_slice_segment_flag / pcm_flag use the terminating bin
procedure cabac_enc_terminate(var E: TCabacEncoder; Bin: Integer);
// Emits the final bits after a terminating bin of 1. Leaves the buffer byte
// aligned; the caller appends the rbsp trailing byte if the syntax needs one.
procedure cabac_enc_finish(var E: TCabacEncoder);

implementation

procedure emit_bit(var E: TCabacEncoder; B: Integer); inline;
begin
  E.Cache := (E.Cache shl 1) or Cardinal(B and 1);
  Inc(E.NBits);
  if E.NBits = 8 then
  begin
    buf_put_byte(E.Out_^, Byte(E.Cache));
    E.Cache := 0;
    E.NBits := 0;
  end;
end;

// 9.3.4.3.4 PutBit
procedure put_bit_c(var E: TCabacEncoder; B: Integer);
begin
  if E.FirstBitFlag then
    E.FirstBitFlag := False
  else
    emit_bit(E, B);
  while E.BitsOutstanding > 0 do
  begin
    emit_bit(E, 1 - (B and 1));
    Dec(E.BitsOutstanding);
  end;
end;

// 9.3.4.3.3 RenormE
procedure renorm_e(var E: TCabacEncoder);
begin
  while E.Range < 256 do
  begin
    if E.Low < 256 then
      put_bit_c(E, 0)
    else if E.Low >= 512 then
    begin
      E.Low := E.Low - 512;
      put_bit_c(E, 1);
    end
    else
    begin
      E.Low := E.Low - 256;
      Inc(E.BitsOutstanding);
    end;
    E.Range := E.Range shl 1;
    E.Low := E.Low shl 1;
  end;
end;

procedure cabac_enc_init(var E: TCabacEncoder; Out_: PByteBuf);
begin
  E.Out_ := Out_;
  E.Low := 0;
  E.Range := 510;
  E.BitsOutstanding := 0;
  E.FirstBitFlag := True;
  E.Cache := 0;
  E.NBits := 0;
end;

// 9.3.4.3.2 EncodeDecision
procedure cabac_enc_bin(var E: TCabacEncoder; State: PByte; Bin: Integer);
var
  pStateIdx, valMPS, qRangeIdx: Integer;
  rLPS: Cardinal;
begin
  pStateIdx := State^ shr 1;
  valMPS := State^ and 1;
  qRangeIdx := (E.Range shr 6) and 3;
  rLPS := cabac_lps_range(pStateIdx, qRangeIdx);
  E.Range := E.Range - rLPS;
  if (Bin and 1) <> valMPS then
  begin
    E.Low := E.Low + E.Range;
    E.Range := rLPS;
    if pStateIdx = 0 then valMPS := 1 - valMPS;
    pStateIdx := cabac_lps_state(pStateIdx);
  end
  else
    pStateIdx := cabac_mps_state(pStateIdx);
  State^ := Byte(2 * pStateIdx + valMPS);
  renorm_e(E);
end;

// 9.3.4.3.4 EncodeBypass
procedure cabac_enc_bypass(var E: TCabacEncoder; Bin: Integer);
begin
  E.Low := E.Low shl 1;
  if (Bin and 1) <> 0 then
    E.Low := E.Low + E.Range;
  if E.Low >= 1024 then
  begin
    put_bit_c(E, 1);
    E.Low := E.Low - 1024;
  end
  else if E.Low < 512 then
    put_bit_c(E, 0)
  else
  begin
    E.Low := E.Low - 512;
    Inc(E.BitsOutstanding);
  end;
end;

procedure cabac_enc_bypass_bits(var E: TCabacEncoder; N: Integer; V: Cardinal);
var
  I: Integer;
begin
  for I := N - 1 downto 0 do
    cabac_enc_bypass(E, Integer((V shr I) and 1));
end;

// 9.3.4.3.5 EncodeTerminate
procedure cabac_enc_terminate(var E: TCabacEncoder; Bin: Integer);
begin
  E.Range := E.Range - 2;
  if (Bin and 1) <> 0 then
  begin
    E.Low := E.Low + E.Range;
    // EncodeFlush
    E.Range := 2;
    renorm_e(E);
    put_bit_c(E, Integer((E.Low shr 9) and 1));
    // the final two bits, with the rbsp stop bit already folded in
    emit_bit(E, Integer((E.Low shr 8) and 1));
    emit_bit(E, 1);
  end
  else
    renorm_e(E);
end;

procedure cabac_enc_finish(var E: TCabacEncoder);
begin
  // EncodeFlush has already produced the stop bit; pad to a byte boundary
  while E.NBits <> 0 do
    emit_bit(E, 0);
end;

end.
