unit BrotliHuffman;

// Author: www.xelitan.com
// License: MIT

{$mode Delphi}
{$H+}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses SysUtils, BrotliBase;

type
  PHuffmanCode = ^THuffmanCode;
  THuffmanCode = record
    bits: uint8_t;
    value: uint16_t;
  end;

  PPHuffmanCode = ^PHuffmanCode;
  THuffmanTreeGroup = packed record
    htrees: PPHuffmanCode;
    codes: PHuffmanCode;
    alphabet_size_max: uint16_t;
    alphabet_size_limit: uint16_t;
    num_htrees: uint16_t;
  end;
  PTHuffmanTreeGroup = ^THuffmanTreeGroup;

function ConstructHuffmanCode(bits: uint8_t; value: uint16_t): THuffmanCode; inline;
procedure BrotliBuildCodeLengthsHuffmanTable(table: PHuffmanCode; code_lengths: PByte; count: PWord);
function BrotliBuildHuffmanTable(root_table: PHuffmanCode; root_bits: Integer; symbol_lists: PWord; count: PWord): uint32_t;
function BrotliBuildSimpleHuffmanTable(table: PHuffmanCode; root_bits: Integer; val: PWord; num_symbols: uint32_t): uint32_t;

implementation

const
  BROTLI_REVERSE_BITS_MAX = 8;
  BROTLI_REVERSE_BITS_LOWEST = brotli_reg_t(1) shl (BROTLI_REVERSE_BITS_MAX - 1);
  kReverseBits: array[0..255] of uint8_t = (
    $00, $80, $40, $C0, $20, $A0, $60, $E0, $10, $90, $50, $D0, $30, $B0, $70, $F0,
    $08, $88, $48, $C8, $28, $A8, $68, $E8, $18, $98, $58, $D8, $38, $B8, $78, $F8,
    $04, $84, $44, $C4, $24, $A4, $64, $E4, $14, $94, $54, $D4, $34, $B4, $74, $F4,
    $0C, $8C, $4C, $CC, $2C, $AC, $6C, $EC, $1C, $9C, $5C, $DC, $3C, $BC, $7C, $FC,
    $02, $82, $42, $C2, $22, $A2, $62, $E2, $12, $92, $52, $D2, $32, $B2, $72, $F2,
    $0A, $8A, $4A, $CA, $2A, $AA, $6A, $EA, $1A, $9A, $5A, $DA, $3A, $BA, $7A, $FA,
    $06, $86, $46, $C6, $26, $A6, $66, $E6, $16, $96, $56, $D6, $36, $B6, $76, $F6,
    $0E, $8E, $4E, $CE, $2E, $AE, $6E, $EE, $1E, $9E, $5E, $DE, $3E, $BE, $7E, $FE,
    $01, $81, $41, $C1, $21, $A1, $61, $E1, $11, $91, $51, $D1, $31, $B1, $71, $F1,
    $09, $89, $49, $C9, $29, $A9, $69, $E9, $19, $99, $59, $D9, $39, $B9, $79, $F9,
    $05, $85, $45, $C5, $25, $A5, $65, $E5, $15, $95, $55, $D5, $35, $B5, $75, $F5,
    $0D, $8D, $4D, $CD, $2D, $AD, $6D, $ED, $1D, $9D, $5D, $DD, $3D, $BD, $7D, $FD,
    $03, $83, $43, $C3, $23, $A3, $63, $E3, $13, $93, $53, $D3, $33, $B3, $73, $F3,
    $0B, $8B, $4B, $CB, $2B, $AB, $6B, $EB, $1B, $9B, $5B, $DB, $3B, $BB, $7B, $FB,
    $07, $87, $47, $C7, $27, $A7, $67, $E7, $17, $97, $57, $D7, $37, $B7, $77, $F7,
    $0F, $8F, $4F, $CF, $2F, $AF, $6F, $EF, $1F, $9F, $5F, $DF, $3F, $BF, $7F, $FF  );

function ConstructHuffmanCode(bits: uint8_t; value: uint16_t): THuffmanCode; inline;
begin
  Result.bits := bits;
  Result.value := value;
end;

function HC(p: PHuffmanCode; idx: NativeInt): PHuffmanCode; inline;
begin
  Result := p + idx;
end;

function BrotliReverseBits(num: brotli_reg_t): brotli_reg_t; inline;
begin
  Result := kReverseBits[num and $FF];
end;

procedure ReplicateValue(table: PHuffmanCode; step, ending: Integer; code: THuffmanCode); inline;
begin
  repeat
    Dec(ending, step);
    HC(table, ending)^ := code;
  until ending <= 0;
end;

function NextTableBitSize(count: PWord; len, root_bits: Integer): Integer; inline;
var left: Integer;
begin
  left := 1 shl (len - root_bits);
  while len < BROTLI_HUFFMAN_MAX_CODE_LENGTH do begin
    Dec(left, count[len]);
    if left <= 0 then Break;
    Inc(len);
    left := left shl 1;
  end;
  Result := len - root_bits;
end;

procedure BrotliBuildCodeLengthsHuffmanTable(table: PHuffmanCode; code_lengths: PByte; count: PWord);
var
  code: THuffmanCode;
  symbol: Integer;
  key, key_step: brotli_reg_t;
  step, table_size: Integer;
  sorted: array[0..BROTLI_CODE_LENGTH_CODES-1] of Integer;
  offset: array[0..BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH] of Integer;
  bits, bits_count, i: Integer;
begin
  symbol := -1;
  for bits := 1 to 5 do begin
    Inc(symbol, count[bits]);
    offset[bits] := symbol;
  end;
  offset[0] := BROTLI_CODE_LENGTH_CODES - 1;

  symbol := BROTLI_CODE_LENGTH_CODES;
  repeat
    for i := 0 to 5 do begin
      Dec(symbol);
      sorted[offset[code_lengths[symbol]]] := symbol;
      Dec(offset[code_lengths[symbol]]);
    end;
  until symbol = 0;

  table_size := 1 shl BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH;
  if offset[0] = 0 then begin
    code := ConstructHuffmanCode(0, uint16_t(sorted[0]));
    for i := 0 to table_size - 1 do HC(table, i)^ := code;
    Exit;
  end;

  key := 0;
  key_step := BROTLI_REVERSE_BITS_LOWEST;
  symbol := 0;
  step := 2;
  bits := 1;
  while bits <= BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH do begin
    bits_count := count[bits];
    while bits_count <> 0 do begin
      code := ConstructHuffmanCode(uint8_t(bits), uint16_t(sorted[symbol]));
      Inc(symbol);
      ReplicateValue(HC(table, BrotliReverseBits(key)), step, table_size, code);
      Inc(key, key_step);
      Dec(bits_count);
    end;
    step := step shl 1;
    key_step := key_step shr 1;
    Inc(bits);
  end;
end;

function BrotliBuildHuffmanTable(root_table: PHuffmanCode; root_bits: Integer; symbol_lists: PWord; count: PWord): uint32_t;
var
  code: THuffmanCode;
  table: PHuffmanCode;
  len, symbol: Integer;
  key, key_step, sub_key, sub_key_step: brotli_reg_t;
  step, table_bits, table_size, total_size, max_length, bits, bits_count: Integer;
begin
  max_length := -1;
  while symbol_lists[max_length] = $FFFF do Dec(max_length);
  Inc(max_length, BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1);

  table := root_table;
  table_bits := root_bits;
  table_size := 1 shl table_bits;
  total_size := table_size;

  if table_bits > max_length then begin
    table_bits := max_length;
    table_size := 1 shl table_bits;
  end;

  key := 0;
  key_step := BROTLI_REVERSE_BITS_LOWEST;
  step := 2;
  bits := 1;
  while bits <= table_bits do begin
    symbol := bits - (BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1);
    bits_count := count[bits];
    while bits_count <> 0 do begin
      symbol := symbol_lists[symbol];
      code := ConstructHuffmanCode(uint8_t(bits), uint16_t(symbol));
      ReplicateValue(HC(table, BrotliReverseBits(key)), step, table_size, code);
      Inc(key, key_step);
      Dec(bits_count);
    end;
    step := step shl 1;
    key_step := key_step shr 1;
    Inc(bits);
  end;

  while total_size <> table_size do begin
    Move(table^, HC(table, table_size)^, table_size * SizeOf(THuffmanCode));
    table_size := table_size shl 1;
  end;

  key_step := BROTLI_REVERSE_BITS_LOWEST shr (root_bits - 1);
  sub_key := BROTLI_REVERSE_BITS_LOWEST shl 1;
  sub_key_step := BROTLI_REVERSE_BITS_LOWEST;
  len := root_bits + 1;
  step := 2;
  while len <= max_length do begin
    symbol := len - (BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1);
    while count[len] <> 0 do begin
      if sub_key = (BROTLI_REVERSE_BITS_LOWEST shl 1) then begin
        Inc(table, table_size);
        table_bits := NextTableBitSize(count, len, root_bits);
        table_size := 1 shl table_bits;
        Inc(total_size, table_size);
        sub_key := BrotliReverseBits(key);
        Inc(key, key_step);
        HC(root_table, sub_key)^ := ConstructHuffmanCode(uint8_t(table_bits + root_bits), uint16_t((table - root_table) - sub_key));
        sub_key := 0;
      end;
      symbol := symbol_lists[symbol];
      code := ConstructHuffmanCode(uint8_t(len - root_bits), uint16_t(symbol));
      ReplicateValue(HC(table, BrotliReverseBits(sub_key)), step, table_size, code);
      Inc(sub_key, sub_key_step);
      Dec(count[len]);
    end;
    step := step shl 1;
    sub_key_step := sub_key_step shr 1;
    Inc(len);
  end;
  Result := uint32_t(total_size);
end;

function BrotliBuildSimpleHuffmanTable(table: PHuffmanCode; root_bits: Integer; val: PWord; num_symbols: uint32_t): uint32_t;
var table_size, goal_size: uint32_t; i, k: Integer; t: uint16_t;
begin
  table_size := 1;
  goal_size := uint32_t(1) shl root_bits;
  case num_symbols of
    0: table[0] := ConstructHuffmanCode(0, val[0]);
    1: begin
      if val[1] > val[0] then begin table[0] := ConstructHuffmanCode(1, val[0]); table[1] := ConstructHuffmanCode(1, val[1]); end
      else begin table[0] := ConstructHuffmanCode(1, val[1]); table[1] := ConstructHuffmanCode(1, val[0]); end;
      table_size := 2;
    end;
    2: begin
      table[0] := ConstructHuffmanCode(1, val[0]); table[2] := ConstructHuffmanCode(1, val[0]);
      if val[2] > val[1] then begin table[1] := ConstructHuffmanCode(2, val[1]); table[3] := ConstructHuffmanCode(2, val[2]); end
      else begin table[1] := ConstructHuffmanCode(2, val[2]); table[3] := ConstructHuffmanCode(2, val[1]); end;
      table_size := 4;
    end;
    3: begin
      for i := 0 to 2 do for k := i + 1 to 3 do if val[k] < val[i] then begin t := val[k]; val[k] := val[i]; val[i] := t; end;
      table[0] := ConstructHuffmanCode(2, val[0]); table[2] := ConstructHuffmanCode(2, val[1]);
      table[1] := ConstructHuffmanCode(2, val[2]); table[3] := ConstructHuffmanCode(2, val[3]);
      table_size := 4;
    end;
    4: begin
      if val[3] < val[2] then begin t := val[3]; val[3] := val[2]; val[2] := t; end;
      table[0] := ConstructHuffmanCode(1, val[0]); table[1] := ConstructHuffmanCode(2, val[1]);
      table[2] := ConstructHuffmanCode(1, val[0]); table[3] := ConstructHuffmanCode(3, val[2]);
      table[4] := ConstructHuffmanCode(1, val[0]); table[5] := ConstructHuffmanCode(2, val[1]);
      table[6] := ConstructHuffmanCode(1, val[0]); table[7] := ConstructHuffmanCode(3, val[3]);
      table_size := 8;
    end;
  end;
  while table_size <> goal_size do begin
    Move(table^, table[table_size], table_size * SizeOf(THuffmanCode));
    table_size := table_size shl 1;
  end;
  Result := goal_size;
end;

end.
