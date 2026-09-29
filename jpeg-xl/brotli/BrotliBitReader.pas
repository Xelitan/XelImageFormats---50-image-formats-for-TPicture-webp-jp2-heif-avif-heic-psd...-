unit BrotliBitReader;

// Author: www.xelitan.com
// License: MIT

{$mode Delphi}
{$H+}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses SysUtils, BrotliBase;

const
  BROTLI_SHORT_FILL_BIT_WINDOW_READ = SizeOf(brotli_reg_t) div 2;
  BROTLI_FAST_INPUT_SLACK = 28;

type
  PBrotliBitReader = ^TBrotliBitReader;
  TBrotliBitReader = record
    val_: brotli_reg_t;
    bit_pos_: brotli_reg_t;
    next_in: PByte;
    guard_in: PByte;
    last_in: PByte;
  end;

  PBrotliBitReaderState = ^TBrotliBitReaderState;
  TBrotliBitReaderState = record
    val_: brotli_reg_t;
    bit_pos_: brotli_reg_t;
    next_in: PByte;
    avail_in: size_t;
  end;

procedure BrotliInitBitReader(br: PBrotliBitReader);
function BrotliWarmupBitReader(br: PBrotliBitReader): BROTLI_BOOL;
function BrotliSafeReadBits32Slow(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t): BROTLI_BOOL;
function BrotliBitReaderGetAvailIn(br: PBrotliBitReader): size_t; inline;
procedure BrotliBitReaderSaveState(from_: PBrotliBitReader; to_: PBrotliBitReaderState); inline;
procedure BrotliBitReaderSetInput(br: PBrotliBitReader; next_in: PByte; avail_in: size_t); inline;
procedure BrotliBitReaderRestoreState(to_: PBrotliBitReader; from_: PBrotliBitReaderState); inline;
function BrotliGetAvailableBits(br: PBrotliBitReader): brotli_reg_t; inline;
function BrotliGetRemainingBytes(br: PBrotliBitReader): size_t; inline;
function BrotliCheckInputAmount(br: PBrotliBitReader): BROTLI_BOOL; inline;
function BrotliBitReaderLoadBits(val, new_bits, count, offset: brotli_reg_t): brotli_reg_t; inline;
procedure BrotliFillBitWindow(br: PBrotliBitReader; n_bits: brotli_reg_t); inline;
procedure BrotliFillBitWindow16(br: PBrotliBitReader); inline;
function BrotliPullByte(br: PBrotliBitReader): BROTLI_BOOL; inline;
function BrotliGetBitsUnmasked(br: PBrotliBitReader): brotli_reg_t; inline;
function BrotliGet16BitsUnmasked(br: PBrotliBitReader): brotli_reg_t; inline;
function BitMask(n: brotli_reg_t): brotli_reg_t; inline;
function BrotliGetBits(br: PBrotliBitReader; n_bits: brotli_reg_t): brotli_reg_t; inline;
function BrotliSafeGetBits(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t): BROTLI_BOOL; inline;
procedure BrotliDropBits(br: PBrotliBitReader; n_bits: brotli_reg_t); inline;
procedure BrotliBitReaderNormalize(br: PBrotliBitReader); inline;
procedure BrotliBitReaderUnload(br: PBrotliBitReader); inline;
procedure BrotliTakeBits(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t); inline;
function BrotliReadBits24(br: PBrotliBitReader; n_bits: brotli_reg_t): brotli_reg_t; inline;
function BrotliReadBits32(br: PBrotliBitReader; n_bits: brotli_reg_t): brotli_reg_t; inline;
function BrotliSafeReadBits(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t): BROTLI_BOOL; inline;
function BrotliSafeReadBits32(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t): BROTLI_BOOL; inline;
function BrotliJumpToByteBoundary(br: PBrotliBitReader): BROTLI_BOOL; inline;
procedure BrotliDropBytes(br: PBrotliBitReader; num: size_t); inline;
procedure BrotliCopyBytes(dest: PByte; br: PBrotliBitReader; num: size_t);

implementation

const
  kBrotliBitMask: array[0..32] of brotli_reg_t = (
    $00000000, $00000001, $00000003, $00000007, $0000000F, $0000001F,
    $0000003F, $0000007F, $000000FF, $000001FF, $000003FF, $000007FF,
    $00000FFF, $00001FFF, $00003FFF, $00007FFF, $0000FFFF, $0001FFFF,
    $0003FFFF, $0007FFFF, $000FFFFF, $001FFFFF, $003FFFFF, $007FFFFF,
    $00FFFFFF, $01FFFFFF, $03FFFFFF, $07FFFFFF, $0FFFFFFF, $1FFFFFFF,
    $3FFFFFFF, $7FFFFFFF, $FFFFFFFF);

function BitMask(n: brotli_reg_t): brotli_reg_t; inline;
begin
  if n <= 32 then Result := kBrotliBitMask[n]
  else if n >= 64 then Result := High(brotli_reg_t)
  else Result := (brotli_reg_t(1) shl n) - 1;
end;

procedure BrotliInitBitReader(br: PBrotliBitReader);
begin
  br^.val_ := 0;
  br^.bit_pos_ := 0;
  br^.next_in := nil;
  br^.guard_in := nil;
  br^.last_in := nil;
end;

function BrotliWarmupBitReader(br: PBrotliBitReader): BROTLI_BOOL;
begin
  if br^.bit_pos_ = 0 then begin
    br^.val_ := 0;
    if br^.next_in = br^.last_in then Exit(BROTLI_FALSE);
    br^.val_ := br^.next_in^;
    Inc(br^.next_in);
    br^.bit_pos_ := 8;
  end;
  Result := BROTLI_TRUE;
end;

function BrotliSafeReadBits32Slow(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t): BROTLI_BOOL;
var low, high: brotli_reg_t;
begin
  if n_bits <= 24 then Exit(BrotliSafeReadBits(br, n_bits, val));
  if BrotliSafeReadBits(br, 16, low) = BROTLI_FALSE then Exit(BROTLI_FALSE);
  if BrotliSafeReadBits(br, n_bits - 16, high) = BROTLI_FALSE then Exit(BROTLI_FALSE);
  val := low or (high shl 16);
  Result := BROTLI_TRUE;
end;

function BrotliBitReaderGetAvailIn(br: PBrotliBitReader): size_t; inline;
begin
  Result := br^.last_in - br^.next_in;
end;

procedure BrotliBitReaderSaveState(from_: PBrotliBitReader; to_: PBrotliBitReaderState); inline;
begin
  to_^.val_ := from_^.val_;
  to_^.bit_pos_ := from_^.bit_pos_;
  to_^.next_in := from_^.next_in;
  to_^.avail_in := BrotliBitReaderGetAvailIn(from_);
end;

procedure BrotliBitReaderSetInput(br: PBrotliBitReader; next_in: PByte; avail_in: size_t); inline;
begin
  br^.next_in := next_in;
  if avail_in = 0 then br^.last_in := next_in else br^.last_in := next_in + avail_in;
  if avail_in + 1 > BROTLI_FAST_INPUT_SLACK then
    br^.guard_in := next_in + (avail_in + 1 - BROTLI_FAST_INPUT_SLACK)
  else
    br^.guard_in := next_in;
end;

procedure BrotliBitReaderRestoreState(to_: PBrotliBitReader; from_: PBrotliBitReaderState); inline;
begin
  to_^.val_ := from_^.val_;
  to_^.bit_pos_ := from_^.bit_pos_;
  to_^.next_in := from_^.next_in;
  BrotliBitReaderSetInput(to_, from_^.next_in, from_^.avail_in);
end;

function BrotliGetAvailableBits(br: PBrotliBitReader): brotli_reg_t; inline;
begin
  Result := br^.bit_pos_;
end;

function BrotliGetRemainingBytes(br: PBrotliBitReader): size_t; inline;
const kCap: size_t = size_t(1) shl BROTLI_LARGE_MAX_WBITS;
var avail_in: size_t;
begin
  avail_in := BrotliBitReaderGetAvailIn(br);
  if avail_in > kCap then Exit(kCap);
  Result := avail_in + (BrotliGetAvailableBits(br) shr 3);
end;

function BrotliCheckInputAmount(br: PBrotliBitReader): BROTLI_BOOL; inline;
begin
  Result := TO_BROTLI_BOOL(br^.next_in < br^.guard_in);
end;

function BrotliBitReaderLoadBits(val, new_bits, count, offset: brotli_reg_t): brotli_reg_t; inline;
begin
  Result := val or (new_bits shl offset);
end;

procedure BrotliFillBitWindow(br: PBrotliBitReader; n_bits: brotli_reg_t); inline;
var bit_pos: brotli_reg_t;
begin
  bit_pos := br^.bit_pos_;
  if (bit_pos <= 32) and (br^.next_in + 4 <= br^.last_in) then begin
    br^.val_ := BrotliBitReaderLoadBits(br^.val_, BrotliLoad32LE(br^.next_in), 32, bit_pos);
    br^.bit_pos_ := bit_pos + 32;
    Inc(br^.next_in, BROTLI_SHORT_FILL_BIT_WINDOW_READ);
  end else begin
    while br^.bit_pos_ < n_bits + 1 do begin
      if BrotliPullByte(br) = BROTLI_FALSE then Break;
    end;
  end;
end;

procedure BrotliFillBitWindow16(br: PBrotliBitReader); inline;
begin
  BrotliFillBitWindow(br, 17);
end;

function BrotliPullByte(br: PBrotliBitReader): BROTLI_BOOL; inline;
begin
  if br^.next_in = br^.last_in then Exit(BROTLI_FALSE);
  br^.val_ := BrotliBitReaderLoadBits(br^.val_, br^.next_in^, 8, br^.bit_pos_);
  Inc(br^.bit_pos_, 8);
  Inc(br^.next_in);
  Result := BROTLI_TRUE;
end;

function BrotliGetBitsUnmasked(br: PBrotliBitReader): brotli_reg_t; inline;
begin
  Result := br^.val_;
end;

function BrotliGet16BitsUnmasked(br: PBrotliBitReader): brotli_reg_t; inline;
begin
  BrotliFillBitWindow(br, 16);
  Result := BrotliGetBitsUnmasked(br);
end;

function BrotliGetBits(br: PBrotliBitReader; n_bits: brotli_reg_t): brotli_reg_t; inline;
begin
  BrotliFillBitWindow(br, n_bits);
  Result := BrotliGetBitsUnmasked(br) and BitMask(n_bits);
end;

function BrotliSafeGetBits(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t): BROTLI_BOOL; inline;
begin
  while BrotliGetAvailableBits(br) < n_bits do begin
    if BrotliPullByte(br) = BROTLI_FALSE then Exit(BROTLI_FALSE);
  end;
  val := BrotliGetBitsUnmasked(br) and BitMask(n_bits);
  Result := BROTLI_TRUE;
end;

procedure BrotliDropBits(br: PBrotliBitReader; n_bits: brotli_reg_t); inline;
begin
  Dec(br^.bit_pos_, n_bits);
  br^.val_ := br^.val_ shr n_bits;
end;

procedure BrotliBitReaderNormalize(br: PBrotliBitReader); inline;
begin
  if br^.bit_pos_ < SizeOf(brotli_reg_t) * 8 then
    if br^.bit_pos_ = 0 then br^.val_ := 0 else br^.val_ := br^.val_ and ((brotli_reg_t(1) shl br^.bit_pos_) - 1);
end;

procedure BrotliBitReaderUnload(br: PBrotliBitReader); inline;
var unused_bytes, unused_bits: brotli_reg_t;
begin
  unused_bytes := BrotliGetAvailableBits(br) shr 3;
  unused_bits := unused_bytes shl 3;
  if unused_bytes <> 0 then Dec(br^.next_in, unused_bytes);
  Dec(br^.bit_pos_, unused_bits);
  BrotliBitReaderNormalize(br);
end;

procedure BrotliTakeBits(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t); inline;
begin
  val := BrotliGetBitsUnmasked(br) and BitMask(n_bits);
  BrotliDropBits(br, n_bits);
end;

function BrotliReadBits24(br: PBrotliBitReader; n_bits: brotli_reg_t): brotli_reg_t; inline;
begin
  BrotliFillBitWindow(br, n_bits);
  BrotliTakeBits(br, n_bits, Result);
end;

function BrotliReadBits32(br: PBrotliBitReader; n_bits: brotli_reg_t): brotli_reg_t; inline;
begin
  BrotliFillBitWindow(br, n_bits);
  BrotliTakeBits(br, n_bits, Result);
end;

function BrotliSafeReadBits(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t): BROTLI_BOOL; inline;
begin
  while BrotliGetAvailableBits(br) < n_bits do begin
    if BrotliPullByte(br) = BROTLI_FALSE then Exit(BROTLI_FALSE);
  end;
  BrotliTakeBits(br, n_bits, val);
  Result := BROTLI_TRUE;
end;

function BrotliSafeReadBits32(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t): BROTLI_BOOL; inline;
begin
  if n_bits <= 24 then Result := BrotliSafeReadBits(br, n_bits, val)
  else Result := BrotliSafeReadBits32Slow(br, n_bits, val);
end;

function BrotliJumpToByteBoundary(br: PBrotliBitReader): BROTLI_BOOL; inline;
var pad_bits_count, pad_bits: brotli_reg_t;
begin
  pad_bits_count := BrotliGetAvailableBits(br) and 7;
  pad_bits := 0;
  if pad_bits_count <> 0 then BrotliTakeBits(br, pad_bits_count, pad_bits);
  BrotliBitReaderNormalize(br);
  Result := TO_BROTLI_BOOL(pad_bits = 0);
end;

procedure BrotliDropBytes(br: PBrotliBitReader; num: size_t); inline;
begin
  Inc(br^.next_in, num);
end;

procedure BrotliCopyBytes(dest: PByte; br: PBrotliBitReader; num: size_t);
begin
  while (BrotliGetAvailableBits(br) >= 8) and (num > 0) do begin
    dest^ := Byte(BrotliGetBitsUnmasked(br));
    BrotliDropBits(br, 8);
    Inc(dest);
    Dec(num);
  end;
  BrotliBitReaderNormalize(br);
  if num > 0 then begin
    Move(br^.next_in^, dest^, num);
    BrotliDropBytes(br, num);
  end;
end;

end.
