// BPG decoder -- Free Pascal port of libbpg 0.9.8
// Context Adaptive Binary Arithmetic Coder (decoder side only).
// Corresponds to: libavcodec/cabac.h, cabac.c, cabac_functions.h,
//                 cabac_tablegen.h
//
// The reference build has CONFIG_HARDCODED_TABLES=0 (tables are generated at
// startup), ARCH_X86=0 (pure C paths) and CONFIG_SAFE_BITSTREAM_READER=1
// (so UNCHECKED_BITSTREAM_READER is 0 and bytestream advancing is guarded).
unit bpg_cabac;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  bpg_common;

const
  CABAC_BITS = 16;
  CABAC_MASK = (1 shl CABAC_BITS) - 1;

  H264_NORM_SHIFT_OFFSET = 0;
  H264_LPS_RANGE_OFFSET = 512;
  H264_MLPS_STATE_OFFSET = 1024;
  H264_LAST_COEFF_FLAG_OFFSET_8x8_OFFSET = 1280;

type
  TCABACContext = record
    Low: Int32;
    Range: Int32;
    OutstandingCount: Int32;
    BytestreamStart: PByte;
    Bytestream: PByte;
    BytestreamEnd: PByte;
  end;
  PCABACContext = ^TCABACContext;

var
  ff_h264_cabac_tables: array[0 .. 512 + 4 * 2 * 64 + 4 * 64 + 63 - 1] of Byte;
  ff_h264_norm_shift: PByte;
  ff_h264_lps_range: PByte;
  ff_h264_mlps_state: PByte;
  ff_h264_last_coeff_flag_offset_8x8: PByte;

procedure ff_init_cabac_states;
procedure ff_init_cabac_decoder(var C: TCABACContext; Buf: PByte; BufSize: Integer);

function get_cabac(var C: TCABACContext; State: PByte): Integer; inline;
function get_cabac_bypass(var C: TCABACContext): Integer; inline;
function get_cabac_bypass_sign(var C: TCABACContext; Val: Integer): Integer; inline;
function get_cabac_terminate(var C: TCABACContext): Integer; inline;
function skip_bytes(var C: TCABACContext; N: Integer): PByte;

// The state-transition tables are shared with the CABAC encoder in
// bpg_cabac_enc; a context byte is 2 * pStateIdx + valMPS, exactly as in the
// decoder, so cabac_init_state's output feeds either engine unchanged.
function cabac_lps_range(StateIdx, QIdx: Integer): Byte; inline;
function cabac_mps_state(StateIdx: Integer): Byte; inline;
function cabac_lps_state(StateIdx: Integer): Byte; inline;

implementation

const
  lps_range: array[0..63, 0..3] of Byte = (
    (128,176,208,240), (128,167,197,227), (128,158,187,216), (123,150,178,205),
    (116,142,169,195), (111,135,160,185), (105,128,152,175), (100,122,144,166),
    ( 95,116,137,158), ( 90,110,130,150), ( 85,104,123,142), ( 81, 99,117,135),
    ( 77, 94,111,128), ( 73, 89,105,122), ( 69, 85,100,116), ( 66, 80, 95,110),
    ( 62, 76, 90,104), ( 59, 72, 86, 99), ( 56, 69, 81, 94), ( 53, 65, 77, 89),
    ( 51, 62, 73, 85), ( 48, 59, 69, 80), ( 46, 56, 66, 76), ( 43, 53, 63, 72),
    ( 41, 50, 59, 69), ( 39, 48, 56, 65), ( 37, 45, 54, 62), ( 35, 43, 51, 59),
    ( 33, 41, 48, 56), ( 32, 39, 46, 53), ( 30, 37, 43, 50), ( 29, 35, 41, 48),
    ( 27, 33, 39, 45), ( 26, 31, 37, 43), ( 24, 30, 35, 41), ( 23, 28, 33, 39),
    ( 22, 27, 32, 37), ( 21, 26, 30, 35), ( 20, 24, 29, 33), ( 19, 23, 27, 31),
    ( 18, 22, 26, 30), ( 17, 21, 25, 28), ( 16, 20, 23, 27), ( 15, 19, 22, 25),
    ( 14, 18, 21, 24), ( 14, 17, 20, 23), ( 13, 16, 19, 22), ( 12, 15, 18, 21),
    ( 12, 14, 17, 20), ( 11, 14, 16, 19), ( 11, 13, 15, 18), ( 10, 12, 15, 17),
    ( 10, 12, 14, 16), (  9, 11, 13, 15), (  9, 11, 12, 14), (  8, 10, 12, 14),
    (  8,  9, 11, 13), (  7,  9, 11, 12), (  7,  9, 10, 12), (  7,  8, 10, 11),
    (  6,  8,  9, 11), (  6,  7,  9, 10), (  6,  7,  8,  9), (  2,  2,  2,  2)
  );

  mps_state: array[0..63] of Byte = (
     1, 2, 3, 4, 5, 6, 7, 8,
     9,10,11,12,13,14,15,16,
    17,18,19,20,21,22,23,24,
    25,26,27,28,29,30,31,32,
    33,34,35,36,37,38,39,40,
    41,42,43,44,45,46,47,48,
    49,50,51,52,53,54,55,56,
    57,58,59,60,61,62,62,63
  );

  lps_state: array[0..63] of Byte = (
     0, 0, 1, 2, 2, 4, 4, 5,
     6, 7, 8, 9, 9,11,11,12,
    13,13,15,15,16,16,18,18,
    19,19,21,21,22,22,23,24,
    24,25,26,26,27,27,28,29,
    29,30,30,30,31,32,32,33,
    33,33,34,34,35,35,35,36,
    36,36,37,37,37,38,38,63
  );

  last_coeff_flag_offset_8x8: array[0..62] of Byte = (
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8
  );

var
  Initialized: Boolean = False;

function cabac_lps_range(StateIdx, QIdx: Integer): Byte;
begin
  Result := lps_range[StateIdx][QIdx];
end;

function cabac_mps_state(StateIdx: Integer): Byte;
begin
  Result := mps_state[StateIdx];
end;

function cabac_lps_state(StateIdx: Integer): Byte;
begin
  Result := lps_state[StateIdx];
end;

procedure cabac_tableinit;
var
  I, J: Integer;
begin
  for I := 0 to 511 do
    if I <> 0 then
      ff_h264_norm_shift[I] := 8 - av_log2(I)
    else
      ff_h264_norm_shift[I] := 9;

  for I := 0 to 63 do
  begin
    for J := 0 to 3 do
    begin
      ff_h264_lps_range[J * 2 * 64 + 2 * I + 0] := lps_range[I][J];
      ff_h264_lps_range[J * 2 * 64 + 2 * I + 1] := lps_range[I][J];
    end;
    ff_h264_mlps_state[128 + 2 * I + 0] := 2 * mps_state[I] + 0;
    ff_h264_mlps_state[128 + 2 * I + 1] := 2 * mps_state[I] + 1;
    if I <> 0 then
    begin
      ff_h264_mlps_state[128 - 2 * I - 1] := 2 * lps_state[I] + 0;
      ff_h264_mlps_state[128 - 2 * I - 2] := 2 * lps_state[I] + 1;
    end
    else
    begin
      ff_h264_mlps_state[128 - 2 * I - 1] := 1;
      ff_h264_mlps_state[128 - 2 * I - 2] := 0;
    end;
  end;
  for I := 0 to 62 do
    ff_h264_last_coeff_flag_offset_8x8[I] := last_coeff_flag_offset_8x8[I];
end;

procedure ff_init_cabac_states;
begin
  if Initialized then Exit;
  cabac_tableinit;
  Initialized := True;
end;

procedure ff_init_cabac_decoder(var C: TCABACContext; Buf: PByte; BufSize: Integer);
begin
  C.BytestreamStart := Buf;
  C.Bytestream := Buf;
  C.BytestreamEnd := Buf + BufSize;

  C.Low := Int32(C.Bytestream^) shl 18; Inc(C.Bytestream);
  C.Low := C.Low + (Int32(C.Bytestream^) shl 10); Inc(C.Bytestream);
  C.Low := C.Low + ((Int32(C.Bytestream^) shl 2) + 2); Inc(C.Bytestream);
  C.Range := $1FE;
end;

procedure refill(var C: TCABACContext); inline;
begin
  C.Low := C.Low + ((Int32(C.Bytestream[0]) shl 9) + (Int32(C.Bytestream[1]) shl 1));
  C.Low := C.Low - CABAC_MASK;
  if PtrUInt(C.Bytestream) < PtrUInt(C.BytestreamEnd) then
    C.Bytestream := C.Bytestream + (CABAC_BITS div 8);
end;

procedure refill2(var C: TCABACContext); inline;
var
  I, X: Int32;
begin
  X := C.Low xor (C.Low - 1);
  I := 7 - ff_h264_norm_shift[Cardinal(X) shr (CABAC_BITS - 1)];
  X := -CABAC_MASK;
  X := X + ((Int32(C.Bytestream[0]) shl 9) + (Int32(C.Bytestream[1]) shl 1));
  C.Low := C.Low + (X shl I);
  if PtrUInt(C.Bytestream) < PtrUInt(C.BytestreamEnd) then
    C.Bytestream := C.Bytestream + (CABAC_BITS div 8);
end;

procedure renorm_cabac_decoder_once(var C: TCABACContext); inline;
var
  Shift: Integer;
begin
  Shift := Integer(Cardinal(C.Range - $100) shr 31);
  C.Range := C.Range shl Shift;
  C.Low := C.Low shl Shift;
  if (C.Low and CABAC_MASK) = 0 then refill(C);
end;

function get_cabac(var C: TCABACContext; State: PByte): Integer;
var
  S, RangeLPS, LpsMask: Int32;
begin
  S := State^;
  RangeLPS := ff_h264_lps_range[2 * (C.Range and $C0) + S];

  C.Range := C.Range - RangeLPS;
  LpsMask := SarLongint((C.Range shl (CABAC_BITS + 1)) - C.Low, 31);

  C.Low := C.Low - ((C.Range shl (CABAC_BITS + 1)) and LpsMask);
  C.Range := C.Range + ((RangeLPS - C.Range) and LpsMask);

  S := S xor LpsMask;
  State^ := ff_h264_mlps_state[128 + S];
  Result := S and 1;

  LpsMask := ff_h264_norm_shift[C.Range];
  C.Range := C.Range shl LpsMask;
  C.Low := C.Low shl LpsMask;
  if (C.Low and CABAC_MASK) = 0 then refill2(C);
end;

function get_cabac_bypass(var C: TCABACContext): Integer;
var
  Rng: Int32;
begin
  C.Low := C.Low + C.Low;
  if (C.Low and CABAC_MASK) = 0 then refill(C);
  Rng := C.Range shl (CABAC_BITS + 1);
  if C.Low < Rng then
    Result := 0
  else
  begin
    C.Low := C.Low - Rng;
    Result := 1;
  end;
end;

function get_cabac_bypass_sign(var C: TCABACContext; Val: Integer): Integer;
var
  Rng, Mask: Int32;
begin
  C.Low := C.Low + C.Low;
  if (C.Low and CABAC_MASK) = 0 then refill(C);
  Rng := C.Range shl (CABAC_BITS + 1);
  C.Low := C.Low - Rng;
  Mask := SarLongint(C.Low, 31);
  Rng := Rng and Mask;
  C.Low := C.Low + Rng;
  Result := (Val xor Mask) - Mask;
end;

function get_cabac_terminate(var C: TCABACContext): Integer;
begin
  C.Range := C.Range - 2;
  if C.Low < (C.Range shl (CABAC_BITS + 1)) then
  begin
    renorm_cabac_decoder_once(C);
    Result := 0;
  end
  else
    Result := Integer(PtrUInt(C.Bytestream) - PtrUInt(C.BytestreamStart));
end;

function skip_bytes(var C: TCABACContext; N: Integer): PByte;
var
  Ptr: PByte;
begin
  Ptr := C.Bytestream;
  if (C.Low and 1) <> 0 then Dec(Ptr);
  if (C.Low and $1FF) <> 0 then Dec(Ptr);
  if Integer(PtrUInt(C.BytestreamEnd) - PtrUInt(Ptr)) < N then Exit(nil);
  ff_init_cabac_decoder(C, Ptr + N, Integer(PtrUInt(C.BytestreamEnd) - PtrUInt(Ptr)) - N);
  Result := Ptr;
end;

initialization
  ff_h264_norm_shift := @ff_h264_cabac_tables[H264_NORM_SHIFT_OFFSET];
  ff_h264_lps_range := @ff_h264_cabac_tables[H264_LPS_RANGE_OFFSET];
  ff_h264_mlps_state := @ff_h264_cabac_tables[H264_MLPS_STATE_OFFSET];
  ff_h264_last_coeff_flag_offset_8x8 := @ff_h264_cabac_tables[H264_LAST_COEFF_FLAG_OFFSET_8x8_OFFSET];
  // the reference fills these from ff_hevc_decode_init; doing it here guarantees
  // the tables exist before any decoder context is created
  ff_init_cabac_states;

end.
