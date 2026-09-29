// BPG encoder -- Free Pascal
// Growable output buffer, MSB-first bit writer and Exp-Golomb codes.
// Mirrors bpg_bits (the decoder side) and the PutBitState helpers in bpgenc.c.
unit bpg_putbits;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  bpg_common;

type
  // Growable byte buffer. Owns its storage; call Free when done.
  TByteBuf = record
    Buf: PByte;
    Len: Integer;
    Size: Integer;
  end;
  PByteBuf = ^TByteBuf;

procedure buf_init(var B: TByteBuf);
procedure buf_free(var B: TByteBuf);
procedure buf_reserve(var B: TByteBuf; N: Integer);
procedure buf_put_byte(var B: TByteBuf; V: Byte);
procedure buf_put(var B: TByteBuf; Data: PByte; N: Integer);

type
  // MSB-first bit writer over a TByteBuf.
  TPutBitContext = record
    Out_: PByteBuf;
    Cache: Cardinal;      // pending bits, left aligned in the low byte
    NBits: Integer;       // number of pending bits, 0..7
  end;

procedure put_bits_init(var S: TPutBitContext; Out_: PByteBuf);
procedure put_bit(var S: TPutBitContext; Bit: Integer);
procedure put_bits(var S: TPutBitContext; N: Integer; V: Cardinal);
procedure put_ue_golomb(var S: TPutBitContext; V: Cardinal);
procedure put_se_golomb(var S: TPutBitContext; V: Integer);
// rbsp_stop_one_bit followed by zero bits until byte aligned
procedure put_rbsp_trailing_bits(var S: TPutBitContext);
// zero bits until byte aligned; the caller must already have emitted a stop bit
procedure put_byte_align(var S: TPutBitContext);
function put_bits_count(const S: TPutBitContext): Integer;

// Copies Src into Dst inserting the 0x03 emulation prevention bytes, i.e. turns
// an RBSP into an EBSP.
procedure put_rbsp_escaped(var Dst: TByteBuf; Src: PByte; N: Integer);

// Writes a start code, the two-byte NAL header and the escaped payload.
// The BPG header's variable length unsigned integer, seven bits per byte with
// the top bit marking "more to come".
procedure put_ue_var(var B: TByteBuf; V: Cardinal);

// A NAL without the start code, which is what the first NAL of a BPG file is.
procedure put_nal_no_startcode(var B: TByteBuf; NalType: Integer;
  Rbsp: PByte; N: Integer);

procedure put_nal(var Dst: TByteBuf; NalType, TemporalIdPlus1: Integer;
  Rbsp: PByte; N: Integer);
// Same, but with an explicit nuh_layer_id. BPG carries the alpha plane as a
// second HEVC stream on layer 1, interleaved with the colour stream; the
// decoder splits them on this field and rewrites it back to 0.
procedure put_nal_layer(var Dst: TByteBuf; NalType, LayerId, TemporalIdPlus1: Integer;
  Rbsp: PByte; N: Integer);

implementation

procedure put_ue_var(var B: TByteBuf; V: Cardinal);
var
  Tmp: array[0..4] of Byte;
  N, I: Integer;
begin
  N := 0;
  repeat
    Tmp[N] := Byte(V and $7F);
    V := V shr 7;
    Inc(N);
  until V = 0;
  for I := N - 1 downto 0 do
    if I > 0 then buf_put_byte(B, Tmp[I] or $80)
    else buf_put_byte(B, Tmp[I]);
end;

procedure put_nal_no_startcode(var B: TByteBuf; NalType: Integer;
  Rbsp: PByte; N: Integer);
begin
  buf_put_byte(B, Byte((NalType and $3F) shl 1));
  buf_put_byte(B, 1);
  put_rbsp_escaped(B, Rbsp, N);
end;

procedure buf_init(var B: TByteBuf);
begin
  B.Buf := nil;
  B.Len := 0;
  B.Size := 0;
end;

procedure buf_free(var B: TByteBuf);
begin
  av_free(B.Buf);
  B.Buf := nil;
  B.Len := 0;
  B.Size := 0;
end;

procedure buf_reserve(var B: TByteBuf; N: Integer);
var
  NewSize: Integer;
begin
  if N <= B.Size then Exit;
  NewSize := (B.Size * 3) div 2;
  if NewSize < N then NewSize := N;
  if NewSize < 64 then NewSize := 64;
  B.Buf := av_realloc(B.Buf, NewSize);
  B.Size := NewSize;
end;

procedure buf_put_byte(var B: TByteBuf; V: Byte);
begin
  buf_reserve(B, B.Len + 1);
  B.Buf[B.Len] := V;
  Inc(B.Len);
end;

procedure buf_put(var B: TByteBuf; Data: PByte; N: Integer);
begin
  if N <= 0 then Exit;
  buf_reserve(B, B.Len + N);
  Move(Data^, B.Buf[B.Len], N);
  Inc(B.Len, N);
end;

// ---------------- bit writer ----------------

procedure put_bits_init(var S: TPutBitContext; Out_: PByteBuf);
begin
  S.Out_ := Out_;
  S.Cache := 0;
  S.NBits := 0;
end;

procedure put_bit(var S: TPutBitContext; Bit: Integer);
begin
  S.Cache := (S.Cache shl 1) or Cardinal(Bit and 1);
  Inc(S.NBits);
  if S.NBits = 8 then
  begin
    buf_put_byte(S.Out_^, Byte(S.Cache));
    S.Cache := 0;
    S.NBits := 0;
  end;
end;

procedure put_bits(var S: TPutBitContext; N: Integer; V: Cardinal);
var
  I: Integer;
begin
  for I := N - 1 downto 0 do
    put_bit(S, Integer((V shr I) and 1));
end;

procedure put_ue_golomb(var S: TPutBitContext; V: Cardinal);
var
  N, I: Integer;
  X: Cardinal;
begin
  // code V as (V + 1) in binary, prefixed by its length - 1 zero bits
  X := V + 1;
  N := 0;
  while (X shr N) > 1 do Inc(N);
  for I := 0 to N - 1 do put_bit(S, 0);
  for I := N downto 0 do put_bit(S, Integer((X shr I) and 1));
end;

procedure put_se_golomb(var S: TPutBitContext; V: Integer);
begin
  if V <= 0 then
    put_ue_golomb(S, Cardinal(-2 * V))
  else
    put_ue_golomb(S, Cardinal(2 * V - 1));
end;

procedure put_rbsp_trailing_bits(var S: TPutBitContext);
begin
  put_bit(S, 1);
  while S.NBits <> 0 do put_bit(S, 0);
end;

procedure put_byte_align(var S: TPutBitContext);
begin
  while S.NBits <> 0 do put_bit(S, 0);
end;

function put_bits_count(const S: TPutBitContext): Integer;
begin
  Result := S.Out_^.Len * 8 + S.NBits;
end;

// ---------------- NAL packaging ----------------

procedure put_rbsp_escaped(var Dst: TByteBuf; Src: PByte; N: Integer);
var
  I, ZeroRun: Integer;
begin
  ZeroRun := 0;
  for I := 0 to N - 1 do
  begin
    // two zero bytes may not be followed by 0x00..0x03
    if (ZeroRun = 2) and (Src[I] <= 3) then
    begin
      buf_put_byte(Dst, $03);
      ZeroRun := 0;
    end;
    buf_put_byte(Dst, Src[I]);
    if Src[I] = 0 then Inc(ZeroRun) else ZeroRun := 0;
  end;
end;

procedure put_nal_layer(var Dst: TByteBuf; NalType, LayerId, TemporalIdPlus1: Integer;
  Rbsp: PByte; N: Integer);
begin
  buf_put_byte(Dst, $00);
  buf_put_byte(Dst, $00);
  buf_put_byte(Dst, $00);
  buf_put_byte(Dst, $01);
  // forbidden_zero_bit = 0, nal_unit_type(6), nuh_layer_id(6), temporal_id_plus1(3)
  buf_put_byte(Dst, Byte(((NalType and $3F) shl 1) or ((LayerId shr 5) and 1)));
  buf_put_byte(Dst, Byte(((LayerId and $1F) shl 3) or (TemporalIdPlus1 and $07)));
  put_rbsp_escaped(Dst, Rbsp, N);
end;

procedure put_nal(var Dst: TByteBuf; NalType, TemporalIdPlus1: Integer;
  Rbsp: PByte; N: Integer);
begin
  put_nal_layer(Dst, NalType, 0, TemporalIdPlus1, Rbsp, N);
end;

end.
