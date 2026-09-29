unit Decode1;

// Author: www.xelitan.com
// License: MIT

{$mode Delphi}
{$H+}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, BrotliBase, BrotliBitReader, BrotliHuffman, BrotliCommon;

const
  HUFFMAN_TABLE_BITS = 8;
  HUFFMAN_TABLE_MASK = $FF;
  kRingBufferWriteAheadSlack: brotli_reg_t = 542;

type
  PUInt64 = ^uint64_t;
  PBrotliDecoderState = ^TBrotliDecoderState;
  TBrotliDecoderMetadataStartFunc = procedure(opaque: Pointer; size: size_t);
  TBrotliDecoderMetadataChunkFunc = procedure(opaque: Pointer; data: PByte; size: size_t);

  TBrotliDecoderResult = (
    BROTLI_DECODER_RESULT_ERROR = 0,
    BROTLI_DECODER_RESULT_SUCCESS = 1,
    BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT = 2,
    BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT = 3
  );

  TBrotliDecoderErrorCode = (
    BROTLI_DECODER_NO_ERROR = 0,
    BROTLI_DECODER_SUCCESS = 1,
    BROTLI_DECODER_NEEDS_MORE_INPUT = 2,
    BROTLI_DECODER_NEEDS_MORE_OUTPUT = 3,
    BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_NIBBLE = -1,
    BROTLI_DECODER_ERROR_FORMAT_RESERVED = -2,
    BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_META_NIBBLE = -3,
    BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_ALPHABET = -4,
    BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_SAME = -5,
    BROTLI_DECODER_ERROR_FORMAT_CL_SPACE = -6,
    BROTLI_DECODER_ERROR_FORMAT_HUFFMAN_SPACE = -7,
    BROTLI_DECODER_ERROR_FORMAT_CONTEXT_MAP_REPEAT = -8,
    BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_1 = -9,
    BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_2 = -10,
    BROTLI_DECODER_ERROR_FORMAT_TRANSFORM = -11,
    BROTLI_DECODER_ERROR_FORMAT_DICTIONARY = -12,
    BROTLI_DECODER_ERROR_FORMAT_WINDOW_BITS = -13,
    BROTLI_DECODER_ERROR_FORMAT_PADDING_1 = -14,
    BROTLI_DECODER_ERROR_FORMAT_PADDING_2 = -15,
    BROTLI_DECODER_ERROR_FORMAT_DISTANCE = -16,
    BROTLI_DECODER_ERROR_FORMAT_BLOCK_SWITCH = -17,
    BROTLI_DECODER_ERROR_COMPOUND_DICTIONARY = -18,
    BROTLI_DECODER_ERROR_DICTIONARY_NOT_SET = -19,
    BROTLI_DECODER_ERROR_INVALID_ARGUMENTS = -20,
    BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MODES = -21,
    BROTLI_DECODER_ERROR_ALLOC_TREE_GROUPS = -22,
    BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MAP = -25,
    BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_1 = -26,
    BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_2 = -27,
    BROTLI_DECODER_ERROR_ALLOC_BLOCK_TYPE_TREES = -30,
    BROTLI_DECODER_ERROR_UNREACHABLE = -31
  );

  TBrotliDecoderParameter = (
    BROTLI_DECODER_PARAM_DISABLE_RING_BUFFER_REALLOCATION = 0,
    BROTLI_DECODER_PARAM_LARGE_WINDOW = 1
  );

  TBrotliRunningState = (
    BROTLI_STATE_UNINITED,
    BROTLI_STATE_LARGE_WINDOW_BITS,
    BROTLI_STATE_INITIALIZE,
    BROTLI_STATE_METABLOCK_BEGIN,
    BROTLI_STATE_METABLOCK_HEADER,
    BROTLI_STATE_METABLOCK_HEADER_2,
    BROTLI_STATE_CONTEXT_MODES,
    BROTLI_STATE_COMMAND_BEGIN,
    BROTLI_STATE_COMMAND_INNER,
    BROTLI_STATE_COMMAND_POST_DECODE_LITERALS,
    BROTLI_STATE_COMMAND_POST_WRAP_COPY,
    BROTLI_STATE_UNCOMPRESSED,
    BROTLI_STATE_METADATA,
    BROTLI_STATE_COMMAND_INNER_WRITE,
    BROTLI_STATE_METABLOCK_DONE,
    BROTLI_STATE_COMMAND_POST_WRITE_1,
    BROTLI_STATE_COMMAND_POST_WRITE_2,
    BROTLI_STATE_BEFORE_COMPRESSED_METABLOCK_HEADER,
    BROTLI_STATE_HUFFMAN_CODE_0,
    BROTLI_STATE_HUFFMAN_CODE_1,
    BROTLI_STATE_HUFFMAN_CODE_2,
    BROTLI_STATE_HUFFMAN_CODE_3,
    BROTLI_STATE_CONTEXT_MAP_1,
    BROTLI_STATE_CONTEXT_MAP_2,
    BROTLI_STATE_TREE_GROUP,
    BROTLI_STATE_BEFORE_COMPRESSED_METABLOCK_BODY,
    BROTLI_STATE_DONE
  );

  TBrotliRunningMetablockHeaderState = (
    BROTLI_STATE_METABLOCK_HEADER_NONE,
    BROTLI_STATE_METABLOCK_HEADER_EMPTY,
    BROTLI_STATE_METABLOCK_HEADER_NIBBLES,
    BROTLI_STATE_METABLOCK_HEADER_SIZE,
    BROTLI_STATE_METABLOCK_HEADER_UNCOMPRESSED,
    BROTLI_STATE_METABLOCK_HEADER_RESERVED,
    BROTLI_STATE_METABLOCK_HEADER_BYTES,
    BROTLI_STATE_METABLOCK_HEADER_METADATA
  );

  TBrotliRunningUncompressedState = (
    BROTLI_STATE_UNCOMPRESSED_NONE,
    BROTLI_STATE_UNCOMPRESSED_WRITE
  );

  TBrotliRunningTreeGroupState = (
    BROTLI_STATE_TREE_GROUP_NONE,
    BROTLI_STATE_TREE_GROUP_LOOP
  );

  TBrotliRunningContextMapState = (
    BROTLI_STATE_CONTEXT_MAP_NONE,
    BROTLI_STATE_CONTEXT_MAP_READ_PREFIX,
    BROTLI_STATE_CONTEXT_MAP_HUFFMAN,
    BROTLI_STATE_CONTEXT_MAP_DECODE,
    BROTLI_STATE_CONTEXT_MAP_TRANSFORM
  );

  TBrotliRunningHuffmanState = (
    BROTLI_STATE_HUFFMAN_NONE,
    BROTLI_STATE_HUFFMAN_SIMPLE_SIZE,
    BROTLI_STATE_HUFFMAN_SIMPLE_READ,
    BROTLI_STATE_HUFFMAN_SIMPLE_BUILD,
    BROTLI_STATE_HUFFMAN_COMPLEX,
    BROTLI_STATE_HUFFMAN_LENGTH_SYMBOLS
  );

  TBrotliRunningDecodeUint8State = (
    BROTLI_STATE_DECODE_UINT8_NONE,
    BROTLI_STATE_DECODE_UINT8_SHORT,
    BROTLI_STATE_DECODE_UINT8_LONG
  );

  TBrotliRunningReadBlockLengthState = (
    BROTLI_STATE_READ_BLOCK_LENGTH_NONE,
    BROTLI_STATE_READ_BLOCK_LENGTH_SUFFIX
  );

  TBrotliDecoderCompoundDictionary = record
    num_chunks: uint8_t;
    block_bits: uint8_t;
    br_index: uint16_t;
    total_size: uint32_t;
    br_offset: uint32_t;
    br_length: uint32_t;
    br_copied: uint32_t;
    chunks: array[0..15] of PByte;
    chunk_offsets: array[0..15] of uint32_t;
    block_map: array[0..255] of uint8_t;
  end;
  PBrotliDecoderCompoundDictionary = ^TBrotliDecoderCompoundDictionary;

  TBrotliMetablockHeaderArena = record
    substate_tree_group: TBrotliRunningTreeGroupState;
    substate_context_map: TBrotliRunningContextMapState;
    substate_huffman: TBrotliRunningHuffmanState;
    sub_loop_counter: brotli_reg_t;
    repeat_code_len: brotli_reg_t;
    prev_code_len: brotli_reg_t;
    symbol: brotli_reg_t;
    repeat_: brotli_reg_t;
    space: brotli_reg_t;
    table: array[0..31] of THuffmanCode;
    symbol_lists: PWord;
    symbols_lists_array: array[0..BROTLI_HUFFMAN_MAX_CODE_LENGTH + BROTLI_NUM_COMMAND_SYMBOLS] of uint16_t;
    next_symbol: array[0..31] of LongInt;
    code_length_code_lengths: array[0..BROTLI_CODE_LENGTH_CODES - 1] of uint8_t;
    code_length_histo: array[0..15] of uint16_t;
    htree_index: LongInt;
    next: PHuffmanCode;
    context_index: brotli_reg_t;
    max_run_length_prefix: brotli_reg_t;
    code: brotli_reg_t;
    context_map_table: array[0..BROTLI_HUFFMAN_MAX_SIZE_272 - 1] of THuffmanCode;
  end;
  PBrotliMetablockHeaderArena = ^TBrotliMetablockHeaderArena;

  TBrotliMetablockBodyArena = record
    dist_extra_bits: array[0..543] of uint8_t;
    dist_offset: array[0..543] of brotli_reg_t;
  end;
  PBrotliMetablockBodyArena = ^TBrotliMetablockBodyArena;

  TBrotliArena = record
    header: TBrotliMetablockHeaderArena;
    body: TBrotliMetablockBodyArena;
  end;

  TBrotliDecoderState = record
    state: TBrotliRunningState;
    loop_counter: LongInt;
    br: TBrotliBitReader;
    buffer_u64: uint64_t;
    buffer_length: brotli_reg_t;
    pos: LongInt;
    max_backward_distance: LongInt;
    max_distance: LongInt;
    ringbuffer_size: LongInt;
    ringbuffer_mask: LongInt;
    dist_rb_idx: LongInt;
    dist_rb: array[0..3] of LongInt;
    error_code: LongInt;
    meta_block_remaining_len: LongInt;
    ringbuffer: PByte;
    ringbuffer_end: PByte;
    htree_command: PHuffmanCode;
    context_lookup: PByte;
    context_map_slice: PByte;
    dist_context_map_slice: PByte;
    literal_hgroup: THuffmanTreeGroup;
    insert_copy_hgroup: THuffmanTreeGroup;
    distance_hgroup: THuffmanTreeGroup;
    block_type_trees: PHuffmanCode;
    block_len_trees: PHuffmanCode;
    trivial_literal_context: LongInt;
    distance_context: LongInt;
    block_length: array[0..2] of brotli_reg_t;
    block_length_index: brotli_reg_t;
    num_block_types: array[0..2] of brotli_reg_t;
    block_type_rb: array[0..5] of brotli_reg_t;
    distance_postfix_bits: brotli_reg_t;
    num_direct_distance_codes: brotli_reg_t;
    num_dist_htrees: brotli_reg_t;
    dist_context_map: PByte;
    literal_htree: PHuffmanCode;
    rb_roundtrips: size_t;
    partial_pos_out: size_t;
    mtf_upper_bound: brotli_reg_t;
    mtf: array[0..64] of uint32_t;
    copy_length: LongInt;
    distance_code: LongInt;
    dist_htree_index: uint8_t;
    metadata_start_func: TBrotliDecoderMetadataStartFunc;
    metadata_chunk_func: TBrotliDecoderMetadataChunkFunc;
    metadata_callback_opaque: Pointer;
    used_input: uint64_t;
    substate_metablock_header: TBrotliRunningMetablockHeaderState;
    substate_uncompressed: TBrotliRunningUncompressedState;
    substate_decode_uint8: TBrotliRunningDecodeUint8State;
    substate_read_block_length: TBrotliRunningReadBlockLengthState;
    new_ringbuffer_size: LongInt;
    is_last_metablock: uint32_t;
    is_uncompressed: uint32_t;
    is_metadata: uint32_t;
    should_wrap_ringbuffer: uint32_t;
    canny_ringbuffer_allocation: uint32_t;
    large_window: BROTLI_BOOL;
    window_bits: uint32_t;
    size_nibbles: uint8_t;
    num_literal_htrees: brotli_reg_t;
    context_map: PByte;
    context_modes: PByte;
    dictionary: Pointer;
    compound_dictionary: PBrotliDecoderCompoundDictionary;
    trivial_literal_contexts: array[0..7] of uint32_t;
    arena: TBrotliArena;
  end;

function BrotliDecoderSetParameter(state: PBrotliDecoderState; p: TBrotliDecoderParameter; value: uint32_t): BROTLI_BOOL;
function BrotliDecoderCreateInstance: PBrotliDecoderState;
procedure BrotliDecoderDestroyInstance(state: PBrotliDecoderState);
function SaveErrorCode(s: PBrotliDecoderState; e: TBrotliDecoderErrorCode; consumed_input: size_t): TBrotliDecoderResult;
function DecodeWindowBits(s: PBrotliDecoderState; br: PBrotliBitReader): TBrotliDecoderErrorCode;
function DecodeVarLenUint8(s: PBrotliDecoderState; br: PBrotliBitReader; value: PUInt64): TBrotliDecoderErrorCode;
function DecodeMetaBlockLength(s: PBrotliDecoderState; br: PBrotliBitReader): TBrotliDecoderErrorCode;
function DecodeSymbol(bits: brotli_reg_t; table: PHuffmanCode; br: PBrotliBitReader): brotli_reg_t; inline;
function ReadSymbol(table: PHuffmanCode; br: PBrotliBitReader): brotli_reg_t; inline;
function SafeDecodeSymbol(table: PHuffmanCode; br: PBrotliBitReader; out result_: brotli_reg_t): BROTLI_BOOL;
function SafeReadSymbol(table: PHuffmanCode; br: PBrotliBitReader; out result_: brotli_reg_t): BROTLI_BOOL; inline;
procedure PreloadSymbol(safe: LongInt; table: PHuffmanCode; br: PBrotliBitReader; bits, value: PUInt64); inline;
function ReadPreloadedSymbol(table: PHuffmanCode; br: PBrotliBitReader; bits, value: PUInt64): brotli_reg_t; inline;
function BrotliCopyPreloadedSymbolsToU8(table: PHuffmanCode; br: PBrotliBitReader; bits, value: PUInt64; ringbuffer: PByte; pos: LongInt; limit: LongInt): LongInt; inline;
function Log2Floor(x: brotli_reg_t): brotli_reg_t; inline;
function ReadSimpleHuffmanSymbols(alphabet_size_max, alphabet_size_limit: brotli_reg_t; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
procedure ProcessSingleCodeLength(code_len: brotli_reg_t; symbol, repeat_, space, prev_code_len: PUInt64; symbol_lists: PWord; code_length_histo: PWord; next_symbol: PLongInt); inline;
procedure ProcessRepeatedCodeLength(code_len, repeat_delta, alphabet_size: brotli_reg_t; symbol, repeat_, space, prev_code_len, repeat_code_len: PUInt64; symbol_lists: PWord; code_length_histo: PWord; next_symbol: PLongInt); inline;
function ReadSymbolCodeLengths(alphabet_size: brotli_reg_t; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function SafeReadSymbolCodeLengths(alphabet_size: brotli_reg_t; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function ReadCodeLengthCodeLengths(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function ReadHuffmanCode(alphabet_size_max, alphabet_size_limit: brotli_reg_t; table: PHuffmanCode; opt_table_size: PUInt64; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function ReadBlockLength(table: PHuffmanCode; br: PBrotliBitReader): brotli_reg_t; inline;
function SafeReadBlockLength(s: PBrotliDecoderState; out result_: brotli_reg_t; table: PHuffmanCode; br: PBrotliBitReader): BROTLI_BOOL; inline;
procedure InverseMoveToFrontTransform(v: PByte; v_len: brotli_reg_t; state: PBrotliDecoderState);
function BROTLI_FAILURE(e: TBrotliDecoderErrorCode): TBrotliDecoderErrorCode; inline;

implementation

const
  kCodeLengthCodeOrder: array[0..BROTLI_CODE_LENGTH_CODES - 1] of uint8_t = (
    1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15);

  kCodeLengthPrefixLength: array[0..15] of uint8_t = (
    2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4);

  kCodeLengthPrefixValue: array[0..15] of uint8_t = (
    0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5);

function HC(p: PHuffmanCode; idx: NativeInt): PHuffmanCode; inline;
begin
  Result := p + idx;
end;

function HCBits(p: PHuffmanCode): brotli_reg_t; inline;
begin
  Result := p^.bits;
end;

function HCValue(p: PHuffmanCode): brotli_reg_t; inline;
begin
  Result := p^.value;
end;

function BROTLI_FAILURE(e: TBrotliDecoderErrorCode): TBrotliDecoderErrorCode; inline;
begin
  Result := e;
end;

function BrotliDecoderSetParameter(state: PBrotliDecoderState; p: TBrotliDecoderParameter; value: uint32_t): BROTLI_BOOL;
begin
  if (state = nil) or (state^.state <> BROTLI_STATE_UNINITED) then Exit(BROTLI_FALSE);
  case p of
    BROTLI_DECODER_PARAM_DISABLE_RING_BUFFER_REALLOCATION:
      begin
        if value <> 0 then state^.canny_ringbuffer_allocation := 0
        else state^.canny_ringbuffer_allocation := 1;
        Exit(BROTLI_TRUE);
      end;
    BROTLI_DECODER_PARAM_LARGE_WINDOW:
      begin
        state^.large_window := TO_BROTLI_BOOL(value <> 0);
        Exit(BROTLI_TRUE);
      end;
  else
    Result := BROTLI_FALSE;
  end;
end;

function BrotliDecoderCreateInstance: PBrotliDecoderState;
begin
  New(Result);
  FillChar(Result^, SizeOf(Result^), 0);
  Result^.state := BROTLI_STATE_UNINITED;
  Result^.error_code := Ord(BROTLI_DECODER_NO_ERROR);
  Result^.canny_ringbuffer_allocation := 1;
  Result^.dist_rb[0] := 16;
  Result^.dist_rb[1] := 15;
  Result^.dist_rb[2] := 11;
  Result^.dist_rb[3] := 4;
  Result^.mtf_upper_bound := 63;
  Result^.arena.header.symbol_lists := @Result^.arena.header.symbols_lists_array[BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1];
  BrotliInitBitReader(@Result^.br);
end;

procedure BrotliDecoderDestroyInstance(state: PBrotliDecoderState);
  procedure FreeGroup(g: PTHuffmanTreeGroup);
  begin
    if g^.htrees <> nil then begin FreeMem(g^.htrees); g^.htrees := nil; g^.codes := nil; end;
  end;
begin
  if state = nil then Exit;
  if state^.context_modes <> nil then FreeMem(state^.context_modes);
  if state^.context_map <> nil then FreeMem(state^.context_map);
  if state^.dist_context_map <> nil then FreeMem(state^.dist_context_map);
  FreeGroup(@state^.literal_hgroup);
  FreeGroup(@state^.insert_copy_hgroup);
  FreeGroup(@state^.distance_hgroup);
  if state^.ringbuffer <> nil then FreeMem(state^.ringbuffer);
  if state^.block_type_trees <> nil then FreeMem(state^.block_type_trees);
  if state^.compound_dictionary <> nil then Dispose(state^.compound_dictionary);
  Dispose(state);
end;

function SaveErrorCode(s: PBrotliDecoderState; e: TBrotliDecoderErrorCode; consumed_input: size_t): TBrotliDecoderResult;
begin
  s^.error_code := Ord(e);
  Inc(s^.used_input, consumed_input);
  if (s^.buffer_length <> 0) and (s^.br.next_in = s^.br.last_in) then begin
    s^.buffer_length := 0;
  end;
  case e of
    BROTLI_DECODER_SUCCESS: Result := BROTLI_DECODER_RESULT_SUCCESS;
    BROTLI_DECODER_NEEDS_MORE_INPUT: Result := BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT;
    BROTLI_DECODER_NEEDS_MORE_OUTPUT: Result := BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT;
  else
    Result := BROTLI_DECODER_RESULT_ERROR;
  end;
end;

function DecodeWindowBits(s: PBrotliDecoderState; br: PBrotliBitReader): TBrotliDecoderErrorCode;
var
  n: brotli_reg_t;
  large_window: BROTLI_BOOL;
begin
  large_window := s^.large_window;
  s^.large_window := BROTLI_FALSE;
  BrotliTakeBits(br, 1, n);
  if n = 0 then begin
    s^.window_bits := 16;
    Exit(BROTLI_DECODER_SUCCESS);
  end;
  BrotliTakeBits(br, 3, n);
  if n <> 0 then begin
    s^.window_bits := (17 + n) and 63;
    Exit(BROTLI_DECODER_SUCCESS);
  end;
  BrotliTakeBits(br, 3, n);
  if n = 1 then begin
    if large_window <> 0 then begin
      BrotliTakeBits(br, 1, n);
      if n = 1 then Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_WINDOW_BITS));
      s^.large_window := BROTLI_TRUE;
      Exit(BROTLI_DECODER_SUCCESS);
    end else begin
      Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_WINDOW_BITS));
    end;
  end;
  if n <> 0 then begin
    s^.window_bits := (8 + n) and 63;
    Exit(BROTLI_DECODER_SUCCESS);
  end;
  s^.window_bits := 17;
  Result := BROTLI_DECODER_SUCCESS;
end;

procedure memmove16(dst, src: PByte); inline;
begin
  Move(src^, dst^, 16);
end;

function DecodeVarLenUint8(s: PBrotliDecoderState; br: PBrotliBitReader; value: PUInt64): TBrotliDecoderErrorCode;
var
  bits: brotli_reg_t;
begin
  case s^.substate_decode_uint8 of
    BROTLI_STATE_DECODE_UINT8_NONE:
      begin
        if BrotliSafeReadBits(br, 1, bits) = BROTLI_FALSE then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
        if bits = 0 then begin value^ := 0; Exit(BROTLI_DECODER_SUCCESS); end;
      end;
  end;

  case s^.substate_decode_uint8 of
    BROTLI_STATE_DECODE_UINT8_NONE,
    BROTLI_STATE_DECODE_UINT8_SHORT:
      begin
        if BrotliSafeReadBits(br, 3, bits) = BROTLI_FALSE then begin
          s^.substate_decode_uint8 := BROTLI_STATE_DECODE_UINT8_SHORT;
          Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
        end;
        if bits = 0 then begin
          value^ := 1;
          s^.substate_decode_uint8 := BROTLI_STATE_DECODE_UINT8_NONE;
          Exit(BROTLI_DECODER_SUCCESS);
        end;
        value^ := bits;
      end;
  end;

  case s^.substate_decode_uint8 of
    BROTLI_STATE_DECODE_UINT8_NONE,
    BROTLI_STATE_DECODE_UINT8_SHORT,
    BROTLI_STATE_DECODE_UINT8_LONG:
      begin
        if BrotliSafeReadBits(br, value^, bits) = BROTLI_FALSE then begin
          s^.substate_decode_uint8 := BROTLI_STATE_DECODE_UINT8_LONG;
          Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
        end;
        value^ := (brotli_reg_t(1) shl value^) + bits;
        s^.substate_decode_uint8 := BROTLI_STATE_DECODE_UINT8_NONE;
        Exit(BROTLI_DECODER_SUCCESS);
      end;
  else
    Result := BROTLI_FAILURE(BROTLI_DECODER_ERROR_UNREACHABLE);
  end;
end;

function DecodeMetaBlockLength(s: PBrotliDecoderState; br: PBrotliBitReader): TBrotliDecoderErrorCode;
var
  bits: brotli_reg_t;
  i: LongInt;
begin
  while True do begin
    case s^.substate_metablock_header of
      BROTLI_STATE_METABLOCK_HEADER_NONE:
        begin
          if BrotliSafeReadBits(br, 1, bits) = BROTLI_FALSE then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
          if bits <> 0 then s^.is_last_metablock := 1 else s^.is_last_metablock := 0;
          s^.meta_block_remaining_len := 0;
          s^.is_uncompressed := 0;
          s^.is_metadata := 0;
          if s^.is_last_metablock = 0 then begin
            s^.substate_metablock_header := BROTLI_STATE_METABLOCK_HEADER_NIBBLES;
            Continue;
          end;
          s^.substate_metablock_header := BROTLI_STATE_METABLOCK_HEADER_EMPTY;
        end;
    end;

    case s^.substate_metablock_header of
      BROTLI_STATE_METABLOCK_HEADER_EMPTY:
        begin
          if BrotliSafeReadBits(br, 1, bits) = BROTLI_FALSE then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
          if bits <> 0 then begin
            s^.substate_metablock_header := BROTLI_STATE_METABLOCK_HEADER_NONE;
            Exit(BROTLI_DECODER_SUCCESS);
          end;
          s^.substate_metablock_header := BROTLI_STATE_METABLOCK_HEADER_NIBBLES;
        end;
    end;

    case s^.substate_metablock_header of
      BROTLI_STATE_METABLOCK_HEADER_NIBBLES:
        begin
          if BrotliSafeReadBits(br, 2, bits) = BROTLI_FALSE then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
          s^.size_nibbles := uint8_t(bits + 4);
          s^.loop_counter := 0;
          if bits = 3 then begin
            s^.is_metadata := 1;
            s^.substate_metablock_header := BROTLI_STATE_METABLOCK_HEADER_RESERVED;
            Continue;
          end;
          s^.substate_metablock_header := BROTLI_STATE_METABLOCK_HEADER_SIZE;
        end;
    end;

    case s^.substate_metablock_header of
      BROTLI_STATE_METABLOCK_HEADER_SIZE:
        begin
          i := s^.loop_counter;
          while i < LongInt(s^.size_nibbles) do begin
            if BrotliSafeReadBits(br, 4, bits) = BROTLI_FALSE then begin
              s^.loop_counter := i;
              Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
            end;
            if (i + 1 = LongInt(s^.size_nibbles)) and (s^.size_nibbles > 4) and (bits = 0) then
              Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_NIBBLE));
            s^.meta_block_remaining_len := s^.meta_block_remaining_len or LongInt(bits shl (i * 4));
            Inc(i);
          end;
          s^.substate_metablock_header := BROTLI_STATE_METABLOCK_HEADER_UNCOMPRESSED;
        end;
    end;

    case s^.substate_metablock_header of
      BROTLI_STATE_METABLOCK_HEADER_UNCOMPRESSED:
        begin
          if s^.is_last_metablock = 0 then begin
            if BrotliSafeReadBits(br, 1, bits) = BROTLI_FALSE then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
            if bits <> 0 then s^.is_uncompressed := 1 else s^.is_uncompressed := 0;
          end;
          Inc(s^.meta_block_remaining_len);
          s^.substate_metablock_header := BROTLI_STATE_METABLOCK_HEADER_NONE;
          Exit(BROTLI_DECODER_SUCCESS);
        end;
    end;

    case s^.substate_metablock_header of
      BROTLI_STATE_METABLOCK_HEADER_RESERVED:
        begin
          if BrotliSafeReadBits(br, 1, bits) = BROTLI_FALSE then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
          if bits <> 0 then Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_RESERVED));
          s^.substate_metablock_header := BROTLI_STATE_METABLOCK_HEADER_BYTES;
        end;
    end;

    case s^.substate_metablock_header of
      BROTLI_STATE_METABLOCK_HEADER_BYTES:
        begin
          if BrotliSafeReadBits(br, 2, bits) = BROTLI_FALSE then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
          if bits = 0 then begin
            s^.substate_metablock_header := BROTLI_STATE_METABLOCK_HEADER_NONE;
            Exit(BROTLI_DECODER_SUCCESS);
          end;
          s^.size_nibbles := uint8_t(bits);
          s^.substate_metablock_header := BROTLI_STATE_METABLOCK_HEADER_METADATA;
        end;
    end;

    case s^.substate_metablock_header of
      BROTLI_STATE_METABLOCK_HEADER_METADATA:
        begin
          i := s^.loop_counter;
          while i < LongInt(s^.size_nibbles) do begin
            if BrotliSafeReadBits(br, 8, bits) = BROTLI_FALSE then begin
              s^.loop_counter := i;
              Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
            end;
            if (i + 1 = LongInt(s^.size_nibbles)) and (s^.size_nibbles > 1) and (bits = 0) then
              Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_META_NIBBLE));
            s^.meta_block_remaining_len := s^.meta_block_remaining_len or LongInt(bits shl (i * 8));
            Inc(i);
          end;
          Inc(s^.meta_block_remaining_len);
          s^.substate_metablock_header := BROTLI_STATE_METABLOCK_HEADER_NONE;
          Exit(BROTLI_DECODER_SUCCESS);
        end;
    else
      Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_UNREACHABLE));
    end;
  end;
end;

function DecodeSymbol(bits: brotli_reg_t; table: PHuffmanCode; br: PBrotliBitReader): brotli_reg_t; inline;
var
  p: PHuffmanCode;
  nbits: brotli_reg_t;
begin
  p := HC(table, bits and HUFFMAN_TABLE_MASK);
  if HCBits(p) > HUFFMAN_TABLE_BITS then begin
    nbits := HCBits(p) - HUFFMAN_TABLE_BITS;
    BrotliDropBits(br, HUFFMAN_TABLE_BITS);
    p := HC(p, HCValue(p) + ((bits shr HUFFMAN_TABLE_BITS) and BitMask(nbits)));
  end;
  BrotliDropBits(br, HCBits(p));
  Result := HCValue(p);
end;

function ReadSymbol(table: PHuffmanCode; br: PBrotliBitReader): brotli_reg_t; inline;
begin
  Result := DecodeSymbol(BrotliGet16BitsUnmasked(br), table, br);
end;

function SafeDecodeSymbol(table: PHuffmanCode; br: PBrotliBitReader; out result_: brotli_reg_t): BROTLI_BOOL;
var
  val, available_bits: brotli_reg_t;
  p: PHuffmanCode;
begin
  available_bits := BrotliGetAvailableBits(br);
  p := table;
  if available_bits = 0 then begin
    if HCBits(p) = 0 then begin result_ := HCValue(p); Exit(BROTLI_TRUE); end;
    Exit(BROTLI_FALSE);
  end;
  val := BrotliGetBitsUnmasked(br);
  p := HC(table, val and HUFFMAN_TABLE_MASK);
  if HCBits(p) <= HUFFMAN_TABLE_BITS then begin
    if HCBits(p) <= available_bits then begin
      BrotliDropBits(br, HCBits(p));
      result_ := HCValue(p);
      Exit(BROTLI_TRUE);
    end else Exit(BROTLI_FALSE);
  end;
  if available_bits <= HUFFMAN_TABLE_BITS then Exit(BROTLI_FALSE);
  val := (val and BitMask(HCBits(p))) shr HUFFMAN_TABLE_BITS;
  Dec(available_bits, HUFFMAN_TABLE_BITS);
  p := HC(p, HCValue(p) + val);
  if available_bits < HCBits(p) then Exit(BROTLI_FALSE);
  BrotliDropBits(br, HUFFMAN_TABLE_BITS + HCBits(p));
  result_ := HCValue(p);
  Result := BROTLI_TRUE;
end;

function SafeReadSymbol(table: PHuffmanCode; br: PBrotliBitReader; out result_: brotli_reg_t): BROTLI_BOOL; inline;
var
  val: brotli_reg_t;
begin
  if BrotliSafeGetBits(br, 15, val) <> BROTLI_FALSE then begin
    result_ := DecodeSymbol(val, table, br);
    Exit(BROTLI_TRUE);
  end;
  Result := SafeDecodeSymbol(table, br, result_);
end;

procedure PreloadSymbol(safe: LongInt; table: PHuffmanCode; br: PBrotliBitReader; bits, value: PUInt64); inline;
var
  p: PHuffmanCode;
begin
  if safe <> 0 then Exit;
  p := HC(table, BrotliGetBits(br, HUFFMAN_TABLE_BITS));
  bits^ := HCBits(p);
  value^ := HCValue(p);
end;

function ReadPreloadedSymbol(table: PHuffmanCode; br: PBrotliBitReader; bits, value: PUInt64): brotli_reg_t; inline;
var
  result_val, val, mask: brotli_reg_t;
  ext: PHuffmanCode;
begin
  result_val := value^;
  if bits^ > HUFFMAN_TABLE_BITS then begin
    val := BrotliGet16BitsUnmasked(br);
    ext := HC(table, (val and HUFFMAN_TABLE_MASK) + value^);
    mask := BitMask(bits^ - HUFFMAN_TABLE_BITS);
    BrotliDropBits(br, HUFFMAN_TABLE_BITS);
    ext := HC(ext, (val shr HUFFMAN_TABLE_BITS) and mask);
    BrotliDropBits(br, HCBits(ext));
    result_val := HCValue(ext);
  end else begin
    BrotliDropBits(br, bits^);
  end;
  PreloadSymbol(0, table, br, bits, value);
  Result := result_val;
end;

function BrotliCopyPreloadedSymbolsToU8(table: PHuffmanCode; br: PBrotliBitReader; bits, value: PUInt64; ringbuffer: PByte; pos: LongInt; limit: LongInt): LongInt; inline;
const
  kMaximalOverread = 4;
var
  pos_limit, copies: LongInt;
  new_lim: Int64;
begin
  pos_limit := limit;
  copies := 0;
  new_lim := br^.guard_in - br^.next_in;
  new_lim := new_lim * 8;
  new_lim := new_lim div 15;
  if (new_lim - kMaximalOverread) <= limit then begin
    pos_limit := LongInt(new_lim - kMaximalOverread);
  end;
  if pos_limit < 0 then pos_limit := 0;
  copies := pos_limit;
  Inc(pos_limit, pos);
  while pos < pos_limit do begin
    ringbuffer[pos] := uint8_t(ReadPreloadedSymbol(table, br, bits, value));
    Inc(pos);
  end;
  while (BrotliCheckInputAmount(br) <> BROTLI_FALSE) and (copies < limit) do begin
    ringbuffer[pos] := uint8_t(ReadPreloadedSymbol(table, br, bits, value));
    Inc(pos);
    Inc(copies);
  end;
  Result := copies;
end;

function Log2Floor(x: brotli_reg_t): brotli_reg_t; inline;
begin
  Result := 0;
  while x <> 0 do begin
    x := x shr 1;
    Inc(Result);
  end;
end;

function ReadSimpleHuffmanSymbols(alphabet_size_max, alphabet_size_limit: brotli_reg_t; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
var
  br: PBrotliBitReader;
  h: PBrotliMetablockHeaderArena;
  max_bits, i, num_symbols, v, k: brotli_reg_t;
begin
  br := @s^.br;
  h := @s^.arena.header;
  max_bits := Log2Floor(alphabet_size_max - 1);
  i := h^.sub_loop_counter;
  num_symbols := h^.symbol;
  while i <= num_symbols do begin
    if BrotliSafeReadBits(br, max_bits, v) = BROTLI_FALSE then begin
      h^.sub_loop_counter := i;
      h^.substate_huffman := BROTLI_STATE_HUFFMAN_SIMPLE_READ;
      Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
    end;
    if v >= alphabet_size_limit then Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_ALPHABET));
    h^.symbols_lists_array[i] := uint16_t(v);
    Inc(i);
  end;
  i := 0;
  while i < num_symbols do begin
    k := i + 1;
    while k <= num_symbols do begin
      if h^.symbols_lists_array[i] = h^.symbols_lists_array[k] then
        Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_SAME));
      Inc(k);
    end;
    Inc(i);
  end;
  Result := BROTLI_DECODER_SUCCESS;
end;

procedure ProcessSingleCodeLength(code_len: brotli_reg_t; symbol, repeat_, space, prev_code_len: PUInt64; symbol_lists: PWord; code_length_histo: PWord; next_symbol: PLongInt); inline;
begin
  repeat_^ := 0;
  if code_len <> 0 then begin
    symbol_lists[next_symbol[code_len]] := uint16_t(symbol^);
    next_symbol[code_len] := LongInt(symbol^);
    prev_code_len^ := code_len;
    space^ := space^ - (32768 shr code_len);
    Inc(code_length_histo[code_len]);
  end;
  Inc(symbol^);
end;

procedure ProcessRepeatedCodeLength(code_len, repeat_delta, alphabet_size: brotli_reg_t; symbol, repeat_, space, prev_code_len, repeat_code_len: PUInt64; symbol_lists: PWord; code_length_histo: PWord; next_symbol: PLongInt); inline;
var
  old_repeat, extra_bits, new_len, last: brotli_reg_t;
  next: LongInt;
begin
  extra_bits := 3;
  new_len := 0;
  if code_len = BROTLI_REPEAT_PREVIOUS_CODE_LENGTH then begin
    new_len := prev_code_len^;
    extra_bits := 2;
  end;
  if repeat_code_len^ <> new_len then begin
    repeat_^ := 0;
    repeat_code_len^ := new_len;
  end;
  old_repeat := repeat_^;
  if repeat_^ > 0 then begin
    repeat_^ := repeat_^ - 2;
    repeat_^ := repeat_^ shl extra_bits;
  end;
  repeat_^ := repeat_^ + repeat_delta + 3;
  repeat_delta := repeat_^ - old_repeat;
  if symbol^ + repeat_delta > alphabet_size then begin
    symbol^ := alphabet_size;
    space^ := $FFFFF;
    Exit;
  end;
  if repeat_code_len^ <> 0 then begin
    last := symbol^ + repeat_delta;
    next := next_symbol[repeat_code_len^];
    repeat
      symbol_lists[next] := uint16_t(symbol^);
      next := LongInt(symbol^);
      Inc(symbol^);
    until symbol^ = last;
    next_symbol[repeat_code_len^] := next;
    space^ := space^ - (repeat_delta shl (15 - repeat_code_len^));
    code_length_histo[repeat_code_len^] := uint16_t(code_length_histo[repeat_code_len^] + repeat_delta);
  end else begin
    symbol^ := symbol^ + repeat_delta;
  end;
end;

function ReadSymbolCodeLengths(alphabet_size: brotli_reg_t; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
var
  br: PBrotliBitReader;
  h: PBrotliMetablockHeaderArena;
  symbol, repeat_, space, prev_code_len, repeat_code_len, code_len, extra_bits, repeat_delta: brotli_reg_t;
  p: PHuffmanCode;
begin
  br := @s^.br;
  h := @s^.arena.header;
  symbol := h^.symbol;
  repeat_ := h^.repeat_;
  space := h^.space;
  prev_code_len := h^.prev_code_len;
  repeat_code_len := h^.repeat_code_len;
  if BrotliWarmupBitReader(br) = BROTLI_FALSE then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
  while (symbol < alphabet_size) and (space > 0) do begin
    p := @h^.table[0];
    if BrotliCheckInputAmount(br) = BROTLI_FALSE then begin
      h^.symbol := symbol;
      h^.repeat_ := repeat_;
      h^.prev_code_len := prev_code_len;
      h^.repeat_code_len := repeat_code_len;
      h^.space := space;
      Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
    end;
    BrotliFillBitWindow16(br);
    p := HC(p, BrotliGetBitsUnmasked(br) and BitMask(BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH));
    BrotliDropBits(br, HCBits(p));
    code_len := HCValue(p);
    if code_len < BROTLI_REPEAT_PREVIOUS_CODE_LENGTH then begin
      ProcessSingleCodeLength(code_len, @symbol, @repeat_, @space, @prev_code_len, h^.symbol_lists, @h^.code_length_histo[0], @h^.next_symbol[0]);
    end else begin
      if code_len = BROTLI_REPEAT_PREVIOUS_CODE_LENGTH then extra_bits := 2 else extra_bits := 3;
      repeat_delta := BrotliGetBitsUnmasked(br) and BitMask(extra_bits);
      BrotliDropBits(br, extra_bits);
      ProcessRepeatedCodeLength(code_len, repeat_delta, alphabet_size, @symbol, @repeat_, @space, @prev_code_len, @repeat_code_len, h^.symbol_lists, @h^.code_length_histo[0], @h^.next_symbol[0]);
    end;
  end;
  h^.space := space;
  Result := BROTLI_DECODER_SUCCESS;
end;

function SafeReadSymbolCodeLengths(alphabet_size: brotli_reg_t; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
var
  br: PBrotliBitReader;
  h: PBrotliMetablockHeaderArena;
  get_byte: BROTLI_BOOL;
  p: PHuffmanCode;
  code_len, available_bits, bits, extra_bits, repeat_delta: brotli_reg_t;
begin
  br := @s^.br;
  h := @s^.arena.header;
  get_byte := BROTLI_FALSE;
  while (h^.symbol < alphabet_size) and (h^.space > 0) do begin
    p := @h^.table[0];
    if (get_byte <> BROTLI_FALSE) and (BrotliPullByte(br) = BROTLI_FALSE) then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
    get_byte := BROTLI_FALSE;
    available_bits := BrotliGetAvailableBits(br);
    bits := 0;
    if available_bits <> 0 then bits := uint32_t(BrotliGetBitsUnmasked(br));
    p := HC(p, bits and BitMask(BROTLI_HUFFMAN_MAX_CODE_LENGTH_CODE_LENGTH));
    if HCBits(p) > available_bits then begin
      get_byte := BROTLI_TRUE;
      Continue;
    end;
    code_len := HCValue(p);
    if code_len < BROTLI_REPEAT_PREVIOUS_CODE_LENGTH then begin
      BrotliDropBits(br, HCBits(p));
      ProcessSingleCodeLength(code_len, @h^.symbol, @h^.repeat_, @h^.space, @h^.prev_code_len, h^.symbol_lists, @h^.code_length_histo[0], @h^.next_symbol[0]);
    end else begin
      extra_bits := code_len - 14;
      repeat_delta := (bits shr HCBits(p)) and BitMask(extra_bits);
      if available_bits < HCBits(p) + extra_bits then begin
        get_byte := BROTLI_TRUE;
        Continue;
      end;
      BrotliDropBits(br, HCBits(p) + extra_bits);
      ProcessRepeatedCodeLength(code_len, repeat_delta, alphabet_size, @h^.symbol, @h^.repeat_, @h^.space, @h^.prev_code_len, @h^.repeat_code_len, h^.symbol_lists, @h^.code_length_histo[0], @h^.next_symbol[0]);
    end;
  end;
  Result := BROTLI_DECODER_SUCCESS;
end;

function ReadCodeLengthCodeLengths(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
var
  br: PBrotliBitReader;
  h: PBrotliMetablockHeaderArena;
  num_codes, space, i, ix, v, available_bits: brotli_reg_t;
  code_len_idx: uint8_t;
begin
  br := @s^.br;
  h := @s^.arena.header;
  num_codes := h^.repeat_;
  space := h^.space;
  i := h^.sub_loop_counter;
  while i < BROTLI_CODE_LENGTH_CODES do begin
    code_len_idx := kCodeLengthCodeOrder[i];
    if BrotliSafeGetBits(br, 4, ix) = BROTLI_FALSE then begin
      available_bits := BrotliGetAvailableBits(br);
      if available_bits <> 0 then ix := BrotliGetBitsUnmasked(br) and $F else ix := 0;
      if kCodeLengthPrefixLength[ix] > available_bits then begin
        h^.sub_loop_counter := i;
        h^.repeat_ := num_codes;
        h^.space := space;
        h^.substate_huffman := BROTLI_STATE_HUFFMAN_COMPLEX;
        Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
      end;
    end;
    v := kCodeLengthPrefixValue[ix];
    BrotliDropBits(br, kCodeLengthPrefixLength[ix]);
    h^.code_length_code_lengths[code_len_idx] := uint8_t(v);
    if v <> 0 then begin
      space := space - (32 shr v);
      Inc(num_codes);
      Inc(h^.code_length_histo[v]);
      if space - 1 >= 32 then Break;
    end;
    Inc(i);
  end;
  if not ((num_codes = 1) or (space = 0)) then Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_CL_SPACE));
  Result := BROTLI_DECODER_SUCCESS;
end;

function ReadHuffmanCode(alphabet_size_max, alphabet_size_limit: brotli_reg_t; table: PHuffmanCode; opt_table_size: PUInt64; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
var
  br: PBrotliBitReader;
  h: PBrotliMetablockHeaderArena;
  result_code: TBrotliDecoderErrorCode;
  bits, table_size, i: brotli_reg_t;
begin
  br := @s^.br;
  h := @s^.arena.header;
  while True do begin
    case h^.substate_huffman of
      BROTLI_STATE_HUFFMAN_NONE:
        begin
          if BrotliSafeReadBits(br, 2, h^.sub_loop_counter) = BROTLI_FALSE then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
          if h^.sub_loop_counter <> 1 then begin
            h^.space := 32;
            h^.repeat_ := 0;
            FillChar(h^.code_length_histo[0], SizeOf(h^.code_length_histo), 0);
            FillChar(h^.code_length_code_lengths[0], SizeOf(h^.code_length_code_lengths), 0);
            h^.substate_huffman := BROTLI_STATE_HUFFMAN_COMPLEX;
            Continue;
          end;
          h^.substate_huffman := BROTLI_STATE_HUFFMAN_SIMPLE_SIZE;
        end;
    end;

    case h^.substate_huffman of
      BROTLI_STATE_HUFFMAN_SIMPLE_SIZE:
        begin
          if BrotliSafeReadBits(br, 2, h^.symbol) = BROTLI_FALSE then begin
            h^.substate_huffman := BROTLI_STATE_HUFFMAN_SIMPLE_SIZE;
            Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
          end;
          h^.sub_loop_counter := 0;
          h^.substate_huffman := BROTLI_STATE_HUFFMAN_SIMPLE_READ;
        end;
    end;

    case h^.substate_huffman of
      BROTLI_STATE_HUFFMAN_SIMPLE_READ:
        begin
          result_code := ReadSimpleHuffmanSymbols(alphabet_size_max, alphabet_size_limit, s);
          if result_code <> BROTLI_DECODER_SUCCESS then Exit(result_code);
          h^.substate_huffman := BROTLI_STATE_HUFFMAN_SIMPLE_BUILD;
        end;
    end;

    case h^.substate_huffman of
      BROTLI_STATE_HUFFMAN_SIMPLE_BUILD:
        begin
          if h^.symbol = 3 then begin
            if BrotliSafeReadBits(br, 1, bits) = BROTLI_FALSE then begin
              h^.substate_huffman := BROTLI_STATE_HUFFMAN_SIMPLE_BUILD;
              Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
            end;
            h^.symbol := h^.symbol + bits;
          end;
          table_size := BrotliBuildSimpleHuffmanTable(table, HUFFMAN_TABLE_BITS, @h^.symbols_lists_array[0], uint32_t(h^.symbol));
          if opt_table_size <> nil then opt_table_size^ := table_size;
          h^.substate_huffman := BROTLI_STATE_HUFFMAN_NONE;
          Exit(BROTLI_DECODER_SUCCESS);
        end;
    end;

    case h^.substate_huffman of
      BROTLI_STATE_HUFFMAN_COMPLEX:
        begin
          result_code := ReadCodeLengthCodeLengths(s);
          if result_code <> BROTLI_DECODER_SUCCESS then Exit(result_code);
          BrotliBuildCodeLengthsHuffmanTable(@h^.table[0], @h^.code_length_code_lengths[0], @h^.code_length_histo[0]);
          FillChar(h^.code_length_histo[0], SizeOf(h^.code_length_histo), 0);
          i := 0;
          while i <= BROTLI_HUFFMAN_MAX_CODE_LENGTH do begin
            h^.next_symbol[i] := LongInt(i) - (BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1);
            h^.symbol_lists[h^.next_symbol[i]] := $FFFF;
            Inc(i);
          end;
          h^.symbol := 0;
          h^.prev_code_len := BROTLI_INITIAL_REPEATED_CODE_LENGTH;
          h^.repeat_ := 0;
          h^.repeat_code_len := 0;
          h^.space := 32768;
          h^.substate_huffman := BROTLI_STATE_HUFFMAN_LENGTH_SYMBOLS;
        end;
    end;

    case h^.substate_huffman of
      BROTLI_STATE_HUFFMAN_LENGTH_SYMBOLS:
        begin
          result_code := ReadSymbolCodeLengths(alphabet_size_limit, s);
          if result_code = BROTLI_DECODER_NEEDS_MORE_INPUT then
            result_code := SafeReadSymbolCodeLengths(alphabet_size_limit, s);
          if result_code <> BROTLI_DECODER_SUCCESS then Exit(result_code);
          if h^.space <> 0 then Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_HUFFMAN_SPACE));
          table_size := BrotliBuildHuffmanTable(table, HUFFMAN_TABLE_BITS, h^.symbol_lists, @h^.code_length_histo[0]);
          if opt_table_size <> nil then opt_table_size^ := table_size;
          h^.substate_huffman := BROTLI_STATE_HUFFMAN_NONE;
          Exit(BROTLI_DECODER_SUCCESS);
        end;
    else
      Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_UNREACHABLE));
    end;
  end;
end;

function ReadBlockLength(table: PHuffmanCode; br: PBrotliBitReader): brotli_reg_t; inline;
var
  code, nbits: brotli_reg_t;
begin
  code := ReadSymbol(table, br);
  nbits := kBrotliPrefixCodeRanges[code].nbits;
  Result := kBrotliPrefixCodeRanges[code].offset + BrotliReadBits24(br, nbits);
end;

function SafeReadBlockLength(s: PBrotliDecoderState; out result_: brotli_reg_t; table: PHuffmanCode; br: PBrotliBitReader): BROTLI_BOOL; inline;
var
  index, bits, nbits, offset: brotli_reg_t;
begin
  if s^.substate_read_block_length = BROTLI_STATE_READ_BLOCK_LENGTH_NONE then begin
    if SafeReadSymbol(table, br, index) = BROTLI_FALSE then Exit(BROTLI_FALSE);
  end else begin
    index := s^.block_length_index;
  end;
  nbits := kBrotliPrefixCodeRanges[index].nbits;
  offset := kBrotliPrefixCodeRanges[index].offset;
  if BrotliSafeReadBits(br, nbits, bits) = BROTLI_FALSE then begin
    s^.block_length_index := index;
    s^.substate_read_block_length := BROTLI_STATE_READ_BLOCK_LENGTH_SUFFIX;
    Exit(BROTLI_FALSE);
  end;
  result_ := offset + bits;
  s^.substate_read_block_length := BROTLI_STATE_READ_BLOCK_LENGTH_NONE;
  Result := BROTLI_TRUE;
end;

procedure InverseMoveToFrontTransform(v: PByte; v_len: brotli_reg_t; state: PBrotliDecoderState);
var
  i, upper_bound, index, value, j: brotli_reg_t;
  mtf_bytes: array[0..255] of uint8_t;
begin

  upper_bound := state^.mtf_upper_bound;
  i := 0; while i <= 255 do begin mtf_bytes[i] := uint8_t(i); Inc(i); end; i := 0;
  i := 0;
  while i < v_len do begin
    index := v[i];
    value := mtf_bytes[index];
    j := index;
    while j > 0 do begin
      mtf_bytes[j] := mtf_bytes[j - 1];
      Dec(j);
    end;
    mtf_bytes[0] := uint8_t(value);
    v[i] := uint8_t(value);
    if value > upper_bound then upper_bound := value;
    Inc(i);
  end;
  state^.mtf_upper_bound := upper_bound;
end;

end.
