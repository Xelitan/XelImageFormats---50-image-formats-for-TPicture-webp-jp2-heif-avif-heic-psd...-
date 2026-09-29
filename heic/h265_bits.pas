// BPG decoder -- Free Pascal port of libbpg 0.9.8
// Big-endian bitstream reader and Exp-Golomb codes.
// Corresponds to: libavcodec/get_bits.h, libavcodec/golomb.h/.c
//
// The reference build has CONFIG_SAFE_BITSTREAM_READER=1 (so the bit index is
// clamped to size_in_bits+8) and does not define BITSTREAM_READER_LE or
// LONG_BITSTREAM_READER, i.e. MSB-first with a 32-bit cache.
unit h265_bits;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  h265_common;

const
  MIN_CACHE_BITS = 25;

type
  TGetBitContext = record
    Buffer: PByte;
    BufferEnd: PByte;
    Index: Integer;
    SizeInBits: Integer;
    SizeInBitsPlus8: Integer;
  end;
  PGetBitContext = ^TGetBitContext;

{$i golomb_tables.inc}

function init_get_bits(var S: TGetBitContext; Buffer: PByte; BitSize: Integer): Integer;
function init_get_bits8(var S: TGetBitContext; Buffer: PByte; ByteSize: Integer): Integer;
function get_bits_count(const S: TGetBitContext): Integer; inline;
function get_bits_left(const S: TGetBitContext): Integer; inline;
procedure skip_bits_long(var S: TGetBitContext; N: Integer); inline;
function get_bits(var S: TGetBitContext; N: Integer): Cardinal; inline;
function get_bits1(var S: TGetBitContext): Cardinal; inline;
function show_bits(var S: TGetBitContext; N: Integer): Cardinal; inline;
function show_bits_long(var S: TGetBitContext; N: Integer): Cardinal;
procedure skip_bits(var S: TGetBitContext; N: Integer); inline;
procedure skip_bits1(var S: TGetBitContext); inline;
function get_bits_long(var S: TGetBitContext; N: Integer): Cardinal;
function get_sbits(var S: TGetBitContext; N: Integer): Integer; inline;
function align_get_bits(var S: TGetBitContext): PByte;

function get_ue_golomb(var GB: TGetBitContext): Integer;
function get_ue_golomb_long(var GB: TGetBitContext): Cardinal;
function get_se_golomb(var GB: TGetBitContext): Integer;
function get_se_golomb_long(var GB: TGetBitContext): Integer;

implementation

// ---- internal cache helpers (OPEN_READER / UPDATE_CACHE / ... ) ----

function UpdateCache(const S: TGetBitContext; Idx: Cardinal): Cardinal; inline;
begin
  Result := AV_RB32(S.Buffer + (Idx shr 3)) shl (Idx and 7);
end;

function ShowUBits(Cache: Cardinal; Num: Integer): Cardinal; inline;
begin
  Result := Cache shr (32 - Num);
end;

function ShowSBits(Cache: Cardinal; Num: Integer): Integer; inline;
begin
  Result := SarLongint(Int32(Cache), 32 - Num);
end;

function SkipCounter(const S: TGetBitContext; Idx: Cardinal; Num: Integer): Cardinal; inline;
begin
  if Int64(Idx) + Num > S.SizeInBitsPlus8 then
    Result := Cardinal(S.SizeInBitsPlus8)
  else
    Result := Idx + Cardinal(Num);
end;

// ---- API ----

function init_get_bits(var S: TGetBitContext; Buffer: PByte; BitSize: Integer): Integer;
var
  BufferSize: Integer;
begin
  Result := 0;
  if (BitSize < 0) or (Buffer = nil) then
  begin
    BitSize := 0;
    Buffer := nil;
    Result := AVERROR_INVALIDDATA;
  end;
  BufferSize := (BitSize + 7) shr 3;
  S.Buffer := Buffer;
  S.SizeInBits := BitSize;
  S.SizeInBitsPlus8 := BitSize + 8;
  S.BufferEnd := Buffer + BufferSize;
  S.Index := 0;
end;

function init_get_bits8(var S: TGetBitContext; Buffer: PByte; ByteSize: Integer): Integer;
begin
  if ByteSize < 0 then ByteSize := -1;
  Result := init_get_bits(S, Buffer, ByteSize * 8);
end;

function get_bits_count(const S: TGetBitContext): Integer;
begin
  Result := S.Index;
end;

function get_bits_left(const S: TGetBitContext): Integer;
begin
  Result := S.SizeInBits - S.Index;
end;

procedure skip_bits_long(var S: TGetBitContext; N: Integer);
begin
  S.Index := S.Index + av_clip(N, -S.Index, S.SizeInBitsPlus8 - S.Index);
end;

function get_bits(var S: TGetBitContext; N: Integer): Cardinal;
var
  Idx, Cache: Cardinal;
begin
  Idx := Cardinal(S.Index);
  Cache := UpdateCache(S, Idx);
  Result := ShowUBits(Cache, N);
  S.Index := Integer(SkipCounter(S, Idx, N));
end;

function get_sbits(var S: TGetBitContext; N: Integer): Integer;
var
  Idx, Cache: Cardinal;
begin
  Idx := Cardinal(S.Index);
  Cache := UpdateCache(S, Idx);
  Result := ShowSBits(Cache, N);
  S.Index := Integer(SkipCounter(S, Idx, N));
end;

function show_bits(var S: TGetBitContext; N: Integer): Cardinal;
begin
  Result := ShowUBits(UpdateCache(S, Cardinal(S.Index)), N);
end;

procedure skip_bits(var S: TGetBitContext; N: Integer);
begin
  S.Index := Integer(SkipCounter(S, Cardinal(S.Index), N));
end;

function get_bits1(var S: TGetBitContext): Cardinal;
var
  Idx: Cardinal;
  Res: Byte;
begin
  Idx := Cardinal(S.Index);
  Res := S.Buffer[Idx shr 3];
  Res := Byte(Res shl (Idx and 7));
  Res := Res shr 7;
  if S.Index < S.SizeInBitsPlus8 then Inc(Idx);
  S.Index := Integer(Idx);
  Result := Res;
end;

procedure skip_bits1(var S: TGetBitContext);
begin
  skip_bits(S, 1);
end;

function get_bits_long(var S: TGetBitContext; N: Integer): Cardinal;
var
  Ret: Cardinal;
begin
  if N = 0 then
    Result := 0
  else if N <= MIN_CACHE_BITS then
    Result := get_bits(S, N)
  else
  begin
    Ret := get_bits(S, 16) shl (N - 16);
    Result := Ret or get_bits(S, N - 16);
  end;
end;

function show_bits_long(var S: TGetBitContext; N: Integer): Cardinal;
var
  GB: TGetBitContext;
begin
  if N <= MIN_CACHE_BITS then
    Result := show_bits(S, N)
  else
  begin
    GB := S;
    Result := get_bits_long(GB, N);
  end;
end;

function align_get_bits(var S: TGetBitContext): PByte;
var
  N: Integer;
begin
  N := (-get_bits_count(S)) and 7;
  if N <> 0 then skip_bits(S, N);
  Result := S.Buffer + (S.Index shr 3);
end;

// ---- Exp-Golomb ----

function get_ue_golomb(var GB: TGetBitContext): Integer;
var
  Idx, Cache, Buf: Cardinal;
  Lg: Integer;
begin
  Idx := Cardinal(GB.Index);
  Cache := UpdateCache(GB, Idx);
  Buf := Cache;
  if Buf >= (1 shl 27) then
  begin
    Buf := Buf shr (32 - 9);
    GB.Index := Integer(SkipCounter(GB, Idx, FFGolombVlcLen[Buf]));
    Result := FFUEGolombVlcCode[Buf];
  end
  else
  begin
    Lg := 2 * av_log2(Buf) - 31;
    GB.Index := Integer(SkipCounter(GB, Idx, 32 - Lg));
    Buf := Buf shr Lg;
    Dec(Buf);
    Result := Integer(Buf);
  end;
end;

function get_ue_golomb_long(var GB: TGetBitContext): Cardinal;
var
  Buf: Cardinal;
  Lg: Integer;
begin
  Buf := show_bits_long(GB, 32);
  Lg := 31 - av_log2(Buf);
  skip_bits_long(GB, Lg);
  Result := get_bits_long(GB, Lg + 1) - 1;
end;

function get_se_golomb(var GB: TGetBitContext): Integer;
var
  Idx, Cache, Buf: Cardinal;
  Lg: Integer;
begin
  Idx := Cardinal(GB.Index);
  Cache := UpdateCache(GB, Idx);
  Buf := Cache;
  if Buf >= (1 shl 27) then
  begin
    Buf := Buf shr (32 - 9);
    GB.Index := Integer(SkipCounter(GB, Idx, FFGolombVlcLen[Buf]));
    Result := FFSEGolombVlcCode[Buf];
  end
  else
  begin
    Lg := av_log2(Buf);
    Idx := SkipCounter(GB, Idx, 31 - Lg);
    Cache := UpdateCache(GB, Idx);
    Buf := Cache;
    Buf := Buf shr Lg;
    GB.Index := Integer(SkipCounter(GB, Idx, 32 - Lg));
    if (Buf and 1) <> 0 then
      Result := -Integer(Buf shr 1)
    else
      Result := Integer(Buf shr 1);
  end;
end;

function get_se_golomb_long(var GB: TGetBitContext): Integer;
var
  Buf: Cardinal;
begin
  Buf := get_ue_golomb_long(GB);
  if (Buf and 1) <> 0 then
    Buf := (Buf + 1) shr 1
  else
    Buf := Cardinal(-Integer(Buf shr 1));
  Result := Integer(Buf);
end;

end.
