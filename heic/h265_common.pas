// BPG (Better Portable Graphics) decoder -- Free Pascal port of libbpg 0.9.8
// (Copyright (c) 2014-2018 Fabrice Bellard; HEVC decoder from FFmpeg, LGPL 2.1+)
//
// Shared scalar helpers, mirroring libavutil/common.h and libavutil/intreadwrite.h.
unit h265_common;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

type
  PInt8 = ^Int8;
  PInt16 = ^Int16;
  PInt32 = ^Int32;
  PUInt8 = ^UInt8;
  PUInt16 = ^UInt16;
  PUInt32 = ^UInt32;
  PPByte = ^PByte;

const
  // FFmpeg pads input buffers so that the 32-bit bitstream cache may read past
  // the last useful byte.
  FF_INPUT_BUFFER_PADDING_SIZE = 32;

  AVERROR_INVALIDDATA = -(Ord('I') or (Ord('N') shl 8) or (Ord('D') shl 16) or (Ord('A') shl 24));
  AVERROR_ENOMEM = -12;
  AVERROR_PATCHWELCOME = -(Ord('P') or (Ord('A') shl 8) or (Ord('W') shl 16) or (Ord('E') shl 24));

function av_log2(V: Cardinal): Integer; inline;
function av_clip(A, Amin, Amax: Integer): Integer; inline;
function av_clip_uint8(A: Integer): Byte; inline;
function av_clip_int8(A: Integer): Int8; inline;
function av_clip_uintp2(A, P: Integer): Integer; inline;
function av_clip_c(A, Amin, Amax: Integer): Integer; inline;
function FFMIN(A, B: Integer): Integer; inline;
function FFMAX(A, B: Integer): Integer; inline;
function FFABS(A: Integer): Integer; inline;
function FFSWAP(var A, B: Integer): Integer;
function sign_extend(Val, Bits: Integer): Integer; inline;
function zero_extend(Val: Cardinal; Bits: Integer): Cardinal; inline;
// arithmetic shift right; Pascal's SHR is logical
function SAR(X: Int32; N: Integer): Int32; inline;

function AV_RB16(P: PByte): Cardinal; inline;
function AV_RB24(P: PByte): Cardinal; inline;
function AV_RB32(P: PByte): Cardinal; inline;

procedure av_memset16(P: PInt16; Value: Int16; Count: Integer);
procedure av_memset32(P: PInt32; Value: Int32; Count: Integer);

// libavutil/mem.h equivalents
function av_malloc(Size: SizeInt): Pointer;
function av_mallocz(Size: SizeInt): Pointer;
function av_malloc_array(Nmemb, Size: SizeInt): Pointer;
function av_mallocz_array(Nmemb, Size: SizeInt): Pointer;
procedure av_free(P: Pointer);
procedure av_freep(P: PPointer);
function av_realloc(P: Pointer; Size: SizeInt): Pointer;
function av_realloc_array(P: Pointer; Nmemb, Size: SizeInt): Pointer;
function av_reallocp_array(P: PPointer; Nmemb, Size: SizeInt): Integer;
// Grow-only scratch buffer: the old contents are NOT preserved, matching
// libavutil's av_fast_malloc contract.
procedure av_fast_malloc(P: PPointer; var Size: Integer; MinSize: SizeInt);

// libavutil/imgutils.c
function av_image_check_size(W, H: Cardinal): Integer;

implementation

function av_log2(V: Cardinal): Integer;
begin
  if V = 0 then Result := 0 else Result := BsrDWord(V);
end;

function av_clip(A, Amin, Amax: Integer): Integer;
begin
  if A < Amin then Result := Amin
  else if A > Amax then Result := Amax
  else Result := A;
end;

function av_clip_c(A, Amin, Amax: Integer): Integer;
begin
  if A < Amin then Result := Amin
  else if A > Amax then Result := Amax
  else Result := A;
end;

function av_clip_uint8(A: Integer): Byte;
begin
  if (A and (not $FF)) <> 0 then
  begin
    if A < 0 then Result := 0 else Result := 255;
  end
  else
    Result := Byte(A);
end;

function av_clip_int8(A: Integer): Int8;
begin
  if ((A + $80) and (not $FF)) <> 0 then
  begin
    if A < 0 then Result := -128 else Result := 127;
  end
  else
    Result := Int8(A);
end;

function av_clip_uintp2(A, P: Integer): Integer;
begin
  if (A and (not ((1 shl P) - 1))) <> 0 then
  begin
    if A < 0 then Result := 0 else Result := (1 shl P) - 1;
  end
  else
    Result := A;
end;

function FFMIN(A, B: Integer): Integer;
begin
  if A < B then Result := A else Result := B;
end;

function FFMAX(A, B: Integer): Integer;
begin
  if A > B then Result := A else Result := B;
end;

function FFABS(A: Integer): Integer;
begin
  if A < 0 then Result := -A else Result := A;
end;

function FFSWAP(var A, B: Integer): Integer;
var
  T: Integer;
begin
  T := A; A := B; B := T;
  Result := 0;
end;

function sign_extend(Val, Bits: Integer): Integer;
var
  Shift: Integer;
begin
  Shift := 32 - Bits;
  Result := SarLongint(Val shl Shift, Shift);
end;

function zero_extend(Val: Cardinal; Bits: Integer): Cardinal;
begin
  Result := (Val shl (32 - Bits)) shr (32 - Bits);
end;

function SAR(X: Int32; N: Integer): Int32;
begin
  Result := SarLongint(X, N);
end;

function AV_RB16(P: PByte): Cardinal;
begin
  Result := (Cardinal(P[0]) shl 8) or P[1];
end;

function AV_RB24(P: PByte): Cardinal;
begin
  Result := (Cardinal(P[0]) shl 16) or (Cardinal(P[1]) shl 8) or P[2];
end;

function AV_RB32(P: PByte): Cardinal;
begin
  Result := (Cardinal(P[0]) shl 24) or (Cardinal(P[1]) shl 16) or
            (Cardinal(P[2]) shl 8) or P[3];
end;

procedure av_memset16(P: PInt16; Value: Int16; Count: Integer);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do P[I] := Value;
end;

procedure av_memset32(P: PInt32; Value: Int32; Count: Integer);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do P[I] := Value;
end;

function av_malloc(Size: SizeInt): Pointer;
begin
  if Size <= 0 then Size := 1;
  GetMem(Result, Size);
end;

function av_mallocz(Size: SizeInt): Pointer;
begin
  if Size <= 0 then Size := 1;
  Result := AllocMem(Size);
end;

function av_malloc_array(Nmemb, Size: SizeInt): Pointer;
begin
  Result := av_malloc(Nmemb * Size);
end;

function av_mallocz_array(Nmemb, Size: SizeInt): Pointer;
begin
  Result := av_mallocz(Nmemb * Size);
end;

procedure av_free(P: Pointer);
begin
  if P <> nil then FreeMem(P);
end;

function av_realloc(P: Pointer; Size: SizeInt): Pointer;
begin
  if Size <= 0 then Size := 1;
  Result := P;
  ReAllocMem(Result, Size);
end;

function av_realloc_array(P: Pointer; Nmemb, Size: SizeInt): Pointer;
begin
  Result := av_realloc(P, Nmemb * Size);
end;

function av_reallocp_array(P: PPointer; Nmemb, Size: SizeInt): Integer;
begin
  P^ := av_realloc(P^, Nmemb * Size);
  if P^ = nil then Result := AVERROR_ENOMEM else Result := 0;
end;

procedure av_fast_malloc(P: PPointer; var Size: Integer; MinSize: SizeInt);
begin
  if MinSize <= Size then Exit;
  av_free(P^);
  P^ := av_malloc(MinSize);
  if P^ = nil then Size := 0 else Size := MinSize;
end;

procedure av_freep(P: PPointer);
begin
  if P^ <> nil then
  begin
    FreeMem(P^);
    P^ := nil;
  end;
end;

function av_image_check_size(W, H: Cardinal): Integer;
begin
  if (Int32(W) > 0) and (Int32(H) > 0) and
     (QWord(W + 128) * QWord(H + 128) < (QWord(MaxInt) div 8)) then
    Result := 0
  else
    Result := -22; // AVERROR(EINVAL)
end;

end.
