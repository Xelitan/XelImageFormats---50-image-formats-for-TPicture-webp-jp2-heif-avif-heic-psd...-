unit BrotliBase;

// Author: www.xelitan.com
// License: MIT

{$mode Delphi}
{$H+}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses SysUtils;

type
  uint8_t = Byte;
  uint16_t = Word;
  uint32_t = LongWord;
  uint64_t = QWord;
  int32_t = LongInt;
  size_t = NativeUInt;
  brotli_reg_t = QWord;
  BROTLI_BOOL = LongInt;

const
  BROTLI_TRUE = 1;
  BROTLI_FALSE = 0;
  BROTLI_LARGE_MAX_WBITS = 30;
  BROTLI_CODE_LENGTH_CODES = 18;
  BROTLI_HUFFMAN_MAX_CODE_LENGTH = 15;
  BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH = 5;
  BROTLI_HUFFMAN_MAX_SIZE_26 = 396;
  BROTLI_HUFFMAN_MAX_SIZE_258 = 632;
  BROTLI_HUFFMAN_MAX_SIZE_272 = 646;

function TO_BROTLI_BOOL(x: Boolean): BROTLI_BOOL; inline;
function MinSizeT(a, b: size_t): size_t; inline;
function BrotliLoad16LE(p: PByte): uint16_t; inline;
function BrotliLoad32LE(p: PByte): uint32_t; inline;
function BrotliLoad64LE(p: PByte): uint64_t; inline;

implementation

function TO_BROTLI_BOOL(x: Boolean): BROTLI_BOOL; inline;
begin
  if x then Result := BROTLI_TRUE else Result := BROTLI_FALSE;
end;

function MinSizeT(a, b: size_t): size_t; inline;
begin
  if a < b then Result := a else Result := b;
end;

function BrotliLoad16LE(p: PByte): uint16_t; inline;
begin
  Result := uint16_t(p[0]) or (uint16_t(p[1]) shl 8);
end;

function BrotliLoad32LE(p: PByte): uint32_t; inline;
begin
  Result := uint32_t(p[0]) or (uint32_t(p[1]) shl 8) or
            (uint32_t(p[2]) shl 16) or (uint32_t(p[3]) shl 24);
end;

function BrotliLoad64LE(p: PByte): uint64_t; inline;
begin
  Result := uint64_t(BrotliLoad32LE(p)) or (uint64_t(BrotliLoad32LE(p + 4)) shl 32);
end;

end.
