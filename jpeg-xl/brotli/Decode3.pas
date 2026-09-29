unit Decode3;

// Author: www.xelitan.com
// License: MIT

{$mode Delphi}
{$H+}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils,
  BrotliBase, BrotliBitReader, BrotliHuffman, BrotliCommon,
  BrotliDictionary, BrotliTransforms, BrotliSharedDictionary,
  Decode1, Decode2;

type
  PPSizeT = ^PSizeT;

function ProcessCommandsInternal(safe: LongInt; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function ProcessCommands(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function SafeProcessCommands(s: PBrotliDecoderState): TBrotliDecoderErrorCode;

function BrotliDecoderDecompress(encoded_size: size_t; encoded_buffer: PByte;
  decoded_size: PSizeT; decoded_buffer: PByte): TBrotliDecoderResult;
function BrotliDecoderDecompressStream(s: PBrotliDecoderState; available_in: PSizeT;
  next_in: PPByte; available_out: PSizeT; next_out: PPByte;
  total_out: PSizeT): TBrotliDecoderResult;

function BrotliDecoderHasMoreOutput(s: PBrotliDecoderState): BROTLI_BOOL;
function BrotliDecoderTakeOutput(s: PBrotliDecoderState; size: PSizeT): PByte;
function BrotliDecoderIsUsed(s: PBrotliDecoderState): BROTLI_BOOL;
function BrotliDecoderIsFinished(s: PBrotliDecoderState): BROTLI_BOOL;
function BrotliDecoderGetErrorCode(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function BrotliDecoderErrorString(c: TBrotliDecoderErrorCode): PChar;
function BrotliDecoderVersion: uint32_t;
procedure BrotliDecoderSetMetadataCallbacks(state: PBrotliDecoderState;
  start_func: TBrotliDecoderMetadataStartFunc;
  chunk_func: TBrotliDecoderMetadataChunkFunc; opaque: Pointer);

implementation

const
  BROTLI_VERSION_VALUE = $01010100; { 1.1.1-style packed version placeholder }

type
  PLongInt = ^LongInt;

function MinInt(a, b: LongInt): LongInt; inline;
begin
  if a < b then Result := a else Result := b;
end;

procedure memmove16(dst, src: PByte); inline;
begin
  Move(src^, dst^, 16);
end;

procedure StateMetablockBegin(s: PBrotliDecoderState);
begin
  s^.meta_block_remaining_len := 0;
  s^.block_length[0] := 1 shl 28;
  s^.block_length[1] := 1 shl 28;
  s^.block_length[2] := 1 shl 28;
  s^.num_block_types[0] := 1;
  s^.num_block_types[1] := 1;
  s^.num_block_types[2] := 1;
  s^.block_type_rb[0] := 1; s^.block_type_rb[1] := 0;
  s^.block_type_rb[2] := 1; s^.block_type_rb[3] := 0;
  s^.block_type_rb[4] := 1; s^.block_type_rb[5] := 0;
  s^.distance_code := 0;
  s^.distance_context := 0;
  s^.copy_length := 0;
end;

procedure FreeHuffmanTreeGroup(group: PTHuffmanTreeGroup);
begin
  if group^.htrees <> nil then begin
    FreeMem(group^.htrees);
    group^.htrees := nil;
    group^.codes := nil;
  end;
end;

procedure StateCleanupAfterMetablock(s: PBrotliDecoderState);
begin
  if s^.context_modes <> nil then begin FreeMem(s^.context_modes); s^.context_modes := nil; end;
  if s^.context_map <> nil then begin FreeMem(s^.context_map); s^.context_map := nil; end;
  if s^.dist_context_map <> nil then begin FreeMem(s^.dist_context_map); s^.dist_context_map := nil; end;
  FreeHuffmanTreeGroup(@s^.literal_hgroup);
  FreeHuffmanTreeGroup(@s^.insert_copy_hgroup);
  FreeHuffmanTreeGroup(@s^.distance_hgroup);
end;

function DecoderHuffmanTreeGroupInit(s: PBrotliDecoderState; group: PTHuffmanTreeGroup;
  alphabet_size_max, alphabet_size_limit, ntrees: brotli_reg_t): BROTLI_BOOL;
var
  max_table_size, code_size, htree_size: size_t;
  p: PPHuffmanCode;
begin
  FillChar(group^, SizeOf(group^), 0);
  group^.alphabet_size_max := uint16_t(alphabet_size_max);
  group^.alphabet_size_limit := uint16_t(alphabet_size_limit);
  group^.num_htrees := uint16_t(ntrees);
  { C uses alphabet_size_limit + 376 — matches brotli/c/dec/state.c exactly. }
  max_table_size := alphabet_size_limit + 376;
  code_size := SizeOf(THuffmanCode) * ntrees * max_table_size;
  htree_size := SizeOf(PHuffmanCode) * ntrees;
  GetMem(p, code_size + htree_size);
  if p = nil then Exit(BROTLI_FALSE);
  group^.htrees := p;
  group^.codes := PHuffmanCode(PByte(p) + htree_size);
  Result := BROTLI_TRUE;
end;

function ProcessCommandsInternal(safe: LongInt; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
label
  CommandBegin, CommandInner, CommandPostDecodeLiterals, CommandPostWrapCopy,
  NextLiteralBlock, saveStateAndReturn;
var
  pos, i, num_steps, src_start, dst_end, src_end, wrap_guard: LongInt;
  err: TBrotliDecoderErrorCode;
  br: PBrotliBitReader;
  compound_dictionary_size: uint32_t;
  bits, value, literal: brotli_reg_t;
  p1, p2, context, dict_id: uint8_t;
  hc: PHuffmanCode;
  copy_dst, copy_src, word: PByte;
  address, offset, mask, word_idx, transform_idx, len, dist_remaining, num: LongInt;
  shift, shift2: brotli_reg_t;
  words, words2: PBrotliDictionary;
  transforms, transforms2: PBrotliTransforms;
  dict_id2: uint8_t;
begin
  pos := s^.pos;
  i := s^.loop_counter;
  err := BROTLI_DECODER_SUCCESS;
  br := @s^.br;
  compound_dictionary_size := GetCompoundDictionarySize(s);

  if CheckInputAmount(safe, br) = BROTLI_FALSE then begin
    err := BROTLI_DECODER_NEEDS_MORE_INPUT;
    goto saveStateAndReturn;
  end;
  if safe = 0 then BrotliWarmupBitReader(br);

  case s^.state of
    BROTLI_STATE_COMMAND_BEGIN: goto CommandBegin;
    BROTLI_STATE_COMMAND_INNER: goto CommandInner;
    BROTLI_STATE_COMMAND_POST_DECODE_LITERALS: goto CommandPostDecodeLiterals;
    BROTLI_STATE_COMMAND_POST_WRAP_COPY: goto CommandPostWrapCopy;
  else
    Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_UNREACHABLE));
  end;

CommandBegin:
  if safe <> 0 then s^.state := BROTLI_STATE_COMMAND_BEGIN;
  if CheckInputAmount(safe, br) = BROTLI_FALSE then begin
    s^.state := BROTLI_STATE_COMMAND_BEGIN;
    err := BROTLI_DECODER_NEEDS_MORE_INPUT;
    goto saveStateAndReturn;
  end;
  if s^.block_length[1] = 0 then begin
    err := DecodeCommandBlockSwitch(s);
    if err <> BROTLI_DECODER_SUCCESS then goto saveStateAndReturn;
    goto CommandBegin;
  end;
  if safe = 0 then ReadCommand(s, br, @i)
  else if SafeReadCommand(s, br, @i) = BROTLI_FALSE then begin
    err := BROTLI_DECODER_NEEDS_MORE_INPUT;
    goto saveStateAndReturn;
  end;
  if i = 0 then goto CommandPostDecodeLiterals;
  Dec(s^.meta_block_remaining_len, i);

CommandInner:
  if safe <> 0 then s^.state := BROTLI_STATE_COMMAND_INNER;
  if s^.trivial_literal_context <> 0 then begin
    PreloadSymbol(safe, s^.literal_htree, br, @bits, @value);
    if safe = 0 then begin
      num_steps := i - 1;
      if (num_steps > 0) and (brotli_reg_t(num_steps) > s^.block_length[0]) then
        num_steps := LongInt(s^.block_length[0]);
      if (s^.ringbuffer_size >= pos) and ((s^.ringbuffer_size - pos) <= num_steps) then
        num_steps := s^.ringbuffer_size - pos - 1;
      if num_steps < 0 then num_steps := 0;
      num_steps := BrotliCopyPreloadedSymbolsToU8(s^.literal_htree, br, @bits,
        @value, s^.ringbuffer, pos, num_steps);
      Inc(pos, num_steps);
      Dec(s^.block_length[0], brotli_reg_t(num_steps));
      Dec(i, num_steps);
      repeat
        if CheckInputAmount(safe, br) = BROTLI_FALSE then begin
          s^.state := BROTLI_STATE_COMMAND_INNER;
          err := BROTLI_DECODER_NEEDS_MORE_INPUT;
          goto saveStateAndReturn;
        end;
        if s^.block_length[0] = 0 then goto NextLiteralBlock;
        BrotliCopyPreloadedSymbolsToU8(s^.literal_htree, br, @bits, @value,
          s^.ringbuffer, pos, 1);
        Dec(s^.block_length[0]);
        Inc(pos);
        if pos = s^.ringbuffer_size then begin
          s^.state := BROTLI_STATE_COMMAND_INNER_WRITE;
          Dec(i);
          goto saveStateAndReturn;
        end;
        Dec(i);
      until i = 0;
    end else begin
      repeat
        if s^.block_length[0] = 0 then goto NextLiteralBlock;
        if SafeReadSymbol(s^.literal_htree, br, literal) = BROTLI_FALSE then begin
          err := BROTLI_DECODER_NEEDS_MORE_INPUT;
          goto saveStateAndReturn;
        end;
        s^.ringbuffer[pos] := uint8_t(literal);
        Dec(s^.block_length[0]);
        Inc(pos);
        if pos = s^.ringbuffer_size then begin
          s^.state := BROTLI_STATE_COMMAND_INNER_WRITE;
          Dec(i);
          goto saveStateAndReturn;
        end;
        Dec(i);
      until i = 0;
    end;
  end else begin
    p1 := s^.ringbuffer[(pos - 1) and s^.ringbuffer_mask];
    p2 := s^.ringbuffer[(pos - 2) and s^.ringbuffer_mask];
    repeat
      if CheckInputAmount(safe, br) = BROTLI_FALSE then begin
        s^.state := BROTLI_STATE_COMMAND_INNER;
        err := BROTLI_DECODER_NEEDS_MORE_INPUT;
        goto saveStateAndReturn;
      end;
      if s^.block_length[0] = 0 then goto NextLiteralBlock;
      context := BrotliContext(p1, p2, s^.context_lookup);
      hc := s^.literal_hgroup.htrees[s^.context_map_slice[context]];
      p2 := p1;
      if safe = 0 then p1 := uint8_t(ReadSymbol(hc, br))
      else begin
        if SafeReadSymbol(hc, br, literal) = BROTLI_FALSE then begin
          err := BROTLI_DECODER_NEEDS_MORE_INPUT;
          goto saveStateAndReturn;
        end;
        p1 := uint8_t(literal);
      end;
      s^.ringbuffer[pos] := p1;
      Dec(s^.block_length[0]);
      Inc(pos);
      if pos = s^.ringbuffer_size then begin
        s^.state := BROTLI_STATE_COMMAND_INNER_WRITE;
        Dec(i);
        goto saveStateAndReturn;
      end;
      Dec(i);
    until i = 0;
  end;
  if s^.meta_block_remaining_len <= 0 then begin
    s^.state := BROTLI_STATE_METABLOCK_DONE;
    goto saveStateAndReturn;
  end;

CommandPostDecodeLiterals:
  if safe <> 0 then s^.state := BROTLI_STATE_COMMAND_POST_DECODE_LITERALS;
  if s^.distance_code >= 0 then begin
    if s^.distance_code <> 0 then s^.distance_context := 0 else s^.distance_context := 1;
    Dec(s^.dist_rb_idx);
    s^.distance_code := s^.dist_rb[s^.dist_rb_idx and 3];
  end else begin
    if s^.block_length[2] = 0 then begin
      err := DecodeDistanceBlockSwitch(s);
      if err <> BROTLI_DECODER_SUCCESS then goto saveStateAndReturn;
    end;
    if safe = 0 then ReadDistance(s, br)
    else if SafeReadDistance(s, br) = BROTLI_FALSE then begin
      err := BROTLI_DECODER_NEEDS_MORE_INPUT;
      goto saveStateAndReturn;
    end;
  end;
  if s^.max_distance <> s^.max_backward_distance then
    s^.max_distance := MinInt(pos, s^.max_backward_distance);
  i := s^.copy_length;

  if s^.distance_code > s^.max_distance then begin
    if s^.distance_code > BROTLI_MAX_ALLOWED_DISTANCE then
      Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_DISTANCE));

    if uint32_t(s^.distance_code - s^.max_distance) - 1 < compound_dictionary_size then begin
      address := LongInt(compound_dictionary_size - uint32_t(s^.distance_code - s^.max_distance));
      if InitializeCompoundDictionaryCopy(s, uint32_t(address), uint32_t(i)) = BROTLI_FALSE then
        Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_COMPOUND_DICTIONARY));
      Inc(pos, CopyFromCompoundDictionary(s, pos));
      if pos >= s^.ringbuffer_size then begin
        s^.state := BROTLI_STATE_COMMAND_POST_WRITE_1;
        goto saveStateAndReturn;
      end;
    end else if (i >= BROTLI_MIN_DICTIONARY_WORD_LENGTH) and
                (i <= BROTLI_MAX_DICTIONARY_WORD_LENGTH) then begin
      { Static dictionary path. This draft uses the built-in dictionary and
        built-in transform table. The multi-dictionary/context-based Brotli
        Shared Dictionary selection can be wired in later using s^.dictionary. }
      words := BrotliGetDictionary;
      transforms := BrotliGetTransforms;
      offset := LongInt(words^.offsets_by_length[i]);
      shift := words^.size_bits_by_length[i];
      address := s^.distance_code - s^.max_distance - 1 - LongInt(compound_dictionary_size);
      mask := LongInt(BitMask(shift));
      word_idx := address and mask;
      transform_idx := address shr shift;
      Inc(s^.dist_rb_idx, s^.distance_context);
      Inc(offset, word_idx * i);
      if words^.size_bits_by_length[i] = 0 then
        Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_DICTIONARY));
      if words^.data = nil then
        Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_DICTIONARY_NOT_SET));
      if transform_idx < LongInt(transforms^.num_transforms) then begin
        word := words^.data + offset;
        len := i;
        if transform_idx = transforms^.cutOffTransforms[0] then begin
          Move(word^, s^.ringbuffer[pos], size_t(len));
        end else begin
          len := BrotliTransformDictionaryWord(@s^.ringbuffer[pos], word, len,
            transforms, transform_idx);
          if (len = 0) and (s^.distance_code <= 120) then begin
            Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_TRANSFORM));
          end;
        end;
        Inc(pos, len);
        Dec(s^.meta_block_remaining_len, len);
        if pos >= s^.ringbuffer_size then begin
          s^.state := BROTLI_STATE_COMMAND_POST_WRITE_1;
          goto saveStateAndReturn;
        end;
      end else begin
        Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_TRANSFORM));
      end;
    end else
      Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_DICTIONARY));
  end else begin
    src_start := (pos - s^.distance_code) and s^.ringbuffer_mask;
    copy_dst := @s^.ringbuffer[pos];
    copy_src := @s^.ringbuffer[src_start];
    dst_end := pos + i;
    src_end := src_start + i;
    s^.dist_rb[s^.dist_rb_idx and 3] := s^.distance_code;
    Inc(s^.dist_rb_idx);
    Dec(s^.meta_block_remaining_len, i);
    memmove16(copy_dst, copy_src);
    if (src_end > pos) and (dst_end > src_start) then goto CommandPostWrapCopy;
    if (dst_end >= s^.ringbuffer_size) or (src_end >= s^.ringbuffer_size) then goto CommandPostWrapCopy;
    Inc(pos, i);
    if i > 16 then begin
      if i > 32 then Move((copy_src + 16)^, (copy_dst + 16)^, size_t(i - 16))
      else memmove16(copy_dst + 16, copy_src + 16);
    end;
  end;
  if s^.meta_block_remaining_len <= 0 then begin
    s^.state := BROTLI_STATE_METABLOCK_DONE;
    goto saveStateAndReturn;
  end else goto CommandBegin;

CommandPostWrapCopy:
  wrap_guard := s^.ringbuffer_size - pos;
  while i > 0 do begin
    s^.ringbuffer[pos] := s^.ringbuffer[(pos - s^.distance_code) and s^.ringbuffer_mask];
    Inc(pos);
    Dec(i);
    Dec(wrap_guard);
    if wrap_guard = 0 then begin
      s^.state := BROTLI_STATE_COMMAND_POST_WRITE_2;
      goto saveStateAndReturn;
    end;
  end;
  if s^.meta_block_remaining_len <= 0 then begin
    s^.state := BROTLI_STATE_METABLOCK_DONE;
    goto saveStateAndReturn;
  end else goto CommandBegin;

NextLiteralBlock:
  err := DecodeLiteralBlockSwitch(s);
  if err <> BROTLI_DECODER_SUCCESS then goto saveStateAndReturn;
  goto CommandInner;

saveStateAndReturn:
  s^.pos := pos;
  s^.loop_counter := i;
  Result := err;
end;

function ProcessCommands(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
begin
  Result := ProcessCommandsInternal(0, s);
end;

function SafeProcessCommands(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
begin
  Result := ProcessCommandsInternal(1, s);
end;

function BrotliDecoderDecompress(encoded_size: size_t; encoded_buffer: PByte;
  decoded_size: PSizeT; decoded_buffer: PByte): TBrotliDecoderResult;
var
  s: PBrotliDecoderState;
  total_out, available_in, available_out: size_t;
  next_in, next_out: PByte;
begin
  s := BrotliDecoderCreateInstance;
  if s = nil then Exit(BROTLI_DECODER_RESULT_ERROR);
  total_out := 0;
  available_in := encoded_size;
  next_in := encoded_buffer;
  available_out := decoded_size^;
  next_out := decoded_buffer;
  Result := BrotliDecoderDecompressStream(s, @available_in, @next_in,
    @available_out, @next_out, @total_out);
  decoded_size^ := total_out;
  BrotliDecoderDestroyInstance(s);
  if Result <> BROTLI_DECODER_RESULT_SUCCESS then
    Result := BROTLI_DECODER_RESULT_ERROR;
end;

function BrotliDecoderDecompressStream(s: PBrotliDecoderState; available_in: PSizeT;
  next_in: PPByte; available_out: PSizeT; next_out: PPByte;
  total_out: PSizeT): TBrotliDecoderResult;
var
  err: TBrotliDecoderErrorCode;
  intermediate_err: TBrotliDecoderErrorCode;
  br: PBrotliBitReader;
  input_size: size_t;
  bits: brotli_reg_t;
  h: PBrotliMetablockHeaderArena;
  alphabet_size, tree_offset: brotli_reg_t;
  npostfix, ndirect, distance_alphabet_size_max, distance_alphabet_size_limit: brotli_reg_t;
  limit: TBrotliDistanceCodeLimit;
  allocation_success: BROTLI_BOOL;
  hgroup: PTHuffmanTreeGroup;
begin
  err := BROTLI_DECODER_SUCCESS;
  br := @s^.br;
  input_size := available_in^;

  if total_out <> nil then total_out^ := s^.partial_pos_out;
  if s^.error_code < 0 then Exit(BROTLI_DECODER_RESULT_ERROR);
  if (available_out^ <> 0) and ((next_out = nil) or (next_out^ = nil)) then
    Exit(SaveErrorCode(s, BROTLI_FAILURE(BROTLI_DECODER_ERROR_INVALID_ARGUMENTS), 0));
  if available_out^ = 0 then next_out := nil;

  if s^.buffer_length = 0 then
    BrotliBitReaderSetInput(br, next_in^, available_in^)
  else begin
    err := BROTLI_DECODER_NEEDS_MORE_INPUT;
    BrotliBitReaderSetInput(br, @s^.buffer_u64, s^.buffer_length);
  end;

  while True do begin
    if err <> BROTLI_DECODER_SUCCESS then begin
      if err = BROTLI_DECODER_NEEDS_MORE_INPUT then begin
        if s^.ringbuffer <> nil then begin
          intermediate_err := WriteRingBuffer(s, available_out, next_out, total_out, BROTLI_TRUE);
          if intermediate_err < BROTLI_DECODER_SUCCESS then begin err := intermediate_err; Break; end;
        end;
        if s^.buffer_length <> 0 then begin
          if br^.next_in = br^.last_in then begin
            s^.buffer_length := 0;
            err := BROTLI_DECODER_SUCCESS;
            BrotliBitReaderSetInput(br, next_in^, available_in^);
            Continue;
          end else if available_in^ <> 0 then begin
            err := BROTLI_DECODER_SUCCESS;
            PByte(@s^.buffer_u64)[s^.buffer_length] := next_in^^;
            Inc(s^.buffer_length);
            BrotliBitReaderSetInput(br, @s^.buffer_u64, s^.buffer_length);
            Inc(next_in^);
            Dec(available_in^);
            Continue;
          end;
          Break;
        end else begin
          next_in^ := br^.next_in;
          available_in^ := BrotliBitReaderGetAvailIn(br);
          while available_in^ <> 0 do begin
            PByte(@s^.buffer_u64)[s^.buffer_length] := next_in^^;
            Inc(s^.buffer_length);
            Inc(next_in^);
            Dec(available_in^);
          end;
          Break;
        end;
      end;

      if s^.buffer_length <> 0 then s^.buffer_length := 0
      else begin
        BrotliBitReaderUnload(br);
        available_in^ := BrotliBitReaderGetAvailIn(br);
        next_in^ := br^.next_in;
      end;
      Break;
    end;

    case s^.state of
      BROTLI_STATE_UNINITED:
        begin
          if BrotliWarmupBitReader(br) = BROTLI_FALSE then begin err := BROTLI_DECODER_NEEDS_MORE_INPUT; Continue; end;
          err := DecodeWindowBits(s, br);
          if err <> BROTLI_DECODER_SUCCESS then Continue;
          if s^.large_window <> 0 then begin s^.state := BROTLI_STATE_LARGE_WINDOW_BITS; Continue; end;
          s^.state := BROTLI_STATE_INITIALIZE;
        end;

      BROTLI_STATE_LARGE_WINDOW_BITS:
        begin
          if BrotliSafeReadBits(br, 6, bits) = BROTLI_FALSE then begin err := BROTLI_DECODER_NEEDS_MORE_INPUT; Continue; end;
          s^.window_bits := bits and 63;
          if (s^.window_bits < BROTLI_LARGE_MIN_WBITS) or
             (s^.window_bits > BROTLI_LARGE_MAX_DISTANCE_BITS) then begin
            err := BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_WINDOW_BITS); Continue;
          end;
          s^.state := BROTLI_STATE_INITIALIZE;
        end;

      BROTLI_STATE_INITIALIZE:
        begin
          s^.max_backward_distance := (1 shl s^.window_bits) - BROTLI_WINDOW_GAP;
          GetMem(s^.block_type_trees, SizeOf(THuffmanCode) * 3 *
            (BROTLI_HUFFMAN_MAX_SIZE_258 + BROTLI_HUFFMAN_MAX_SIZE_26));
          if s^.block_type_trees = nil then begin err := BROTLI_FAILURE(BROTLI_DECODER_ERROR_ALLOC_BLOCK_TYPE_TREES); Continue; end;
          s^.block_len_trees := s^.block_type_trees + 3 * BROTLI_HUFFMAN_MAX_SIZE_258;
          s^.state := BROTLI_STATE_METABLOCK_BEGIN;
        end;

      BROTLI_STATE_METABLOCK_BEGIN:
        begin
          StateMetablockBegin(s);
          s^.state := BROTLI_STATE_METABLOCK_HEADER;
        end;

      BROTLI_STATE_METABLOCK_HEADER:
        begin
          err := DecodeMetaBlockLength(s, br);
          if err <> BROTLI_DECODER_SUCCESS then Continue;
          if (s^.is_metadata <> 0) or (s^.is_uncompressed <> 0) then
            if BrotliJumpToByteBoundary(br) = BROTLI_FALSE then begin err := BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_PADDING_1); Continue; end;
          if s^.is_metadata <> 0 then begin
            s^.state := BROTLI_STATE_METADATA;
            if Assigned(s^.metadata_start_func) then s^.metadata_start_func(s^.metadata_callback_opaque, size_t(s^.meta_block_remaining_len));
            Continue;
          end;
          if s^.meta_block_remaining_len = 0 then begin s^.state := BROTLI_STATE_METABLOCK_DONE; Continue; end;
          BrotliCalculateRingBufferSize(s);
          if s^.is_uncompressed <> 0 then begin s^.state := BROTLI_STATE_UNCOMPRESSED; Continue; end;
          s^.state := BROTLI_STATE_BEFORE_COMPRESSED_METABLOCK_HEADER;
        end;

      BROTLI_STATE_BEFORE_COMPRESSED_METABLOCK_HEADER:
        begin
          h := @s^.arena.header;
          s^.loop_counter := 0;
          h^.sub_loop_counter := 0;
          h^.symbol_lists := @h^.symbols_lists_array[BROTLI_HUFFMAN_MAX_CODE_LENGTH + 1];
          h^.substate_huffman := BROTLI_STATE_HUFFMAN_NONE;
          h^.substate_tree_group := BROTLI_STATE_TREE_GROUP_NONE;
          h^.substate_context_map := BROTLI_STATE_CONTEXT_MAP_NONE;
          s^.state := BROTLI_STATE_HUFFMAN_CODE_0;
        end;

      BROTLI_STATE_HUFFMAN_CODE_0:
        begin
          if s^.loop_counter >= 3 then begin s^.state := BROTLI_STATE_METABLOCK_HEADER_2; Continue; end;
          err := DecodeVarLenUint8(s, br, @s^.num_block_types[s^.loop_counter]);
          if err <> BROTLI_DECODER_SUCCESS then Continue;
          Inc(s^.num_block_types[s^.loop_counter]);
          if s^.num_block_types[s^.loop_counter] < 2 then begin Inc(s^.loop_counter); Continue; end;
          s^.state := BROTLI_STATE_HUFFMAN_CODE_1;
        end;

      BROTLI_STATE_HUFFMAN_CODE_1:
        begin
          alphabet_size := s^.num_block_types[s^.loop_counter] + 2;
          tree_offset := s^.loop_counter * BROTLI_HUFFMAN_MAX_SIZE_258;
          err := ReadHuffmanCode(alphabet_size, alphabet_size, s^.block_type_trees + tree_offset, nil, s);
          if err <> BROTLI_DECODER_SUCCESS then Continue;
          s^.state := BROTLI_STATE_HUFFMAN_CODE_2;
        end;

      BROTLI_STATE_HUFFMAN_CODE_2:
        begin
          alphabet_size := BROTLI_NUM_BLOCK_LEN_SYMBOLS;
          tree_offset := s^.loop_counter * BROTLI_HUFFMAN_MAX_SIZE_26;
          err := ReadHuffmanCode(alphabet_size, alphabet_size, s^.block_len_trees + tree_offset, nil, s);
          if err <> BROTLI_DECODER_SUCCESS then Continue;
          s^.state := BROTLI_STATE_HUFFMAN_CODE_3;
        end;

      BROTLI_STATE_HUFFMAN_CODE_3:
        begin
          tree_offset := s^.loop_counter * BROTLI_HUFFMAN_MAX_SIZE_26;
          if SafeReadBlockLength(s, s^.block_length[s^.loop_counter], s^.block_len_trees + tree_offset, br) = BROTLI_FALSE then begin
            err := BROTLI_DECODER_NEEDS_MORE_INPUT; Continue;
          end;
          Inc(s^.loop_counter);
          s^.state := BROTLI_STATE_HUFFMAN_CODE_0;
        end;

      BROTLI_STATE_UNCOMPRESSED:
        begin
          err := CopyUncompressedBlockToOutput(available_out, next_out, total_out, s);
          if err <> BROTLI_DECODER_SUCCESS then Continue;
          s^.state := BROTLI_STATE_METABLOCK_DONE;
        end;

      BROTLI_STATE_METADATA:
        begin
          err := SkipMetadataBlock(s);
          if err <> BROTLI_DECODER_SUCCESS then Continue;
          s^.state := BROTLI_STATE_METABLOCK_DONE;
        end;

      BROTLI_STATE_METABLOCK_HEADER_2:
        begin
          if BrotliSafeReadBits(br, 6, bits) = BROTLI_FALSE then begin err := BROTLI_DECODER_NEEDS_MORE_INPUT; Continue; end;
          s^.distance_postfix_bits := bits and BitMask(2);
          bits := bits shr 2;
          s^.num_direct_distance_codes := bits shl s^.distance_postfix_bits;
          GetMem(s^.context_modes, size_t(s^.num_block_types[0]));
          if s^.context_modes = nil then begin err := BROTLI_FAILURE(BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MODES); Continue; end;
          s^.loop_counter := 0;
          s^.state := BROTLI_STATE_CONTEXT_MODES;
        end;

      BROTLI_STATE_CONTEXT_MODES:
        begin
          err := ReadContextModes(s);
          if err <> BROTLI_DECODER_SUCCESS then Continue;
          s^.state := BROTLI_STATE_CONTEXT_MAP_1;
        end;

      BROTLI_STATE_CONTEXT_MAP_1:
        begin
          err := DecodeContextMap(s^.num_block_types[0] shl BROTLI_LITERAL_CONTEXT_BITS,
            @s^.num_literal_htrees, @s^.context_map, s);
          if err <> BROTLI_DECODER_SUCCESS then Continue;
          DetectTrivialLiteralBlockTypes(s);
          s^.state := BROTLI_STATE_CONTEXT_MAP_2;
        end;

      BROTLI_STATE_CONTEXT_MAP_2:
        begin
          npostfix := s^.distance_postfix_bits;
          ndirect := s^.num_direct_distance_codes;
          distance_alphabet_size_max := BrotliDistanceAlphabetSize(npostfix, ndirect, BROTLI_MAX_DISTANCE_BITS);
          distance_alphabet_size_limit := distance_alphabet_size_max;
          if s^.large_window <> 0 then begin
            limit := BrotliCalculateDistanceCodeLimit(BROTLI_MAX_ALLOWED_DISTANCE, npostfix, ndirect);
            distance_alphabet_size_max := BrotliDistanceAlphabetSize(npostfix, ndirect, BROTLI_LARGE_MAX_DISTANCE_BITS);
            distance_alphabet_size_limit := limit.max_alphabet_size;
          end;
          err := DecodeContextMap(s^.num_block_types[2] shl BROTLI_DISTANCE_CONTEXT_BITS,
            @s^.num_dist_htrees, @s^.dist_context_map, s);
          if err <> BROTLI_DECODER_SUCCESS then Continue;
          allocation_success := DecoderHuffmanTreeGroupInit(s, @s^.literal_hgroup,
            BROTLI_NUM_LITERAL_SYMBOLS, BROTLI_NUM_LITERAL_SYMBOLS, s^.num_literal_htrees);
          allocation_success := allocation_success and DecoderHuffmanTreeGroupInit(s, @s^.insert_copy_hgroup,
            BROTLI_NUM_COMMAND_SYMBOLS, BROTLI_NUM_COMMAND_SYMBOLS, s^.num_block_types[1]);
          allocation_success := allocation_success and DecoderHuffmanTreeGroupInit(s, @s^.distance_hgroup,
            distance_alphabet_size_max, distance_alphabet_size_limit, s^.num_dist_htrees);
          if allocation_success = BROTLI_FALSE then
            Exit(SaveErrorCode(s, BROTLI_FAILURE(BROTLI_DECODER_ERROR_ALLOC_TREE_GROUPS), input_size - available_in^));
          s^.loop_counter := 0;
          s^.state := BROTLI_STATE_TREE_GROUP;
        end;

      BROTLI_STATE_TREE_GROUP:
        begin
          case s^.loop_counter of
            0: hgroup := @s^.literal_hgroup;
            1: hgroup := @s^.insert_copy_hgroup;
            2: hgroup := @s^.distance_hgroup;
          else
            Exit(SaveErrorCode(s, BROTLI_FAILURE(BROTLI_DECODER_ERROR_UNREACHABLE), input_size - available_in^));
          end;
          err := HuffmanTreeGroupDecode(hgroup, s);
          if err <> BROTLI_DECODER_SUCCESS then Continue;
          Inc(s^.loop_counter);
          if s^.loop_counter < 3 then Continue;
          s^.state := BROTLI_STATE_BEFORE_COMPRESSED_METABLOCK_BODY;
        end;

      BROTLI_STATE_BEFORE_COMPRESSED_METABLOCK_BODY:
        begin
          PrepareLiteralDecoding(s);
          s^.dist_context_map_slice := s^.dist_context_map;
          s^.htree_command := s^.insert_copy_hgroup.htrees[0];
          if BrotliEnsureRingBuffer(s) = BROTLI_FALSE then begin err := BROTLI_FAILURE(BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_2); Continue; end;
          CalculateDistanceLut(s);
          s^.state := BROTLI_STATE_COMMAND_BEGIN;
        end;

      BROTLI_STATE_COMMAND_BEGIN,
      BROTLI_STATE_COMMAND_INNER,
      BROTLI_STATE_COMMAND_POST_DECODE_LITERALS,
      BROTLI_STATE_COMMAND_POST_WRAP_COPY:
        begin
          err := ProcessCommands(s);
          if err = BROTLI_DECODER_NEEDS_MORE_INPUT then err := SafeProcessCommands(s);
        end;

      BROTLI_STATE_COMMAND_INNER_WRITE,
      BROTLI_STATE_COMMAND_POST_WRITE_1,
      BROTLI_STATE_COMMAND_POST_WRITE_2:
        begin
          err := WriteRingBuffer(s, available_out, next_out, total_out, BROTLI_FALSE);
          if err <> BROTLI_DECODER_SUCCESS then Continue;
          WrapRingBuffer(s);
          if s^.ringbuffer_size = (1 shl s^.window_bits) then s^.max_distance := s^.max_backward_distance;
          if s^.state = BROTLI_STATE_COMMAND_POST_WRITE_1 then begin
            if (s^.compound_dictionary <> nil) and (s^.compound_dictionary^.br_length <> s^.compound_dictionary^.br_copied) then begin
              Inc(s^.pos, CopyFromCompoundDictionary(s, s^.pos));
              if s^.pos >= s^.ringbuffer_size then Continue;
            end;
            if s^.meta_block_remaining_len = 0 then s^.state := BROTLI_STATE_METABLOCK_DONE
            else s^.state := BROTLI_STATE_COMMAND_BEGIN;
          end else if s^.state = BROTLI_STATE_COMMAND_POST_WRITE_2 then
            s^.state := BROTLI_STATE_COMMAND_POST_WRAP_COPY
          else begin
            if s^.loop_counter = 0 then begin
              if s^.meta_block_remaining_len = 0 then s^.state := BROTLI_STATE_METABLOCK_DONE
              else s^.state := BROTLI_STATE_COMMAND_POST_DECODE_LITERALS;
            end else s^.state := BROTLI_STATE_COMMAND_INNER;
          end;
        end;

      BROTLI_STATE_METABLOCK_DONE:
        begin
          if s^.meta_block_remaining_len < 0 then begin err := BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_2); Continue; end;
          StateCleanupAfterMetablock(s);
          if s^.is_last_metablock = 0 then begin s^.state := BROTLI_STATE_METABLOCK_BEGIN; Continue; end;
          if BrotliJumpToByteBoundary(br) = BROTLI_FALSE then begin err := BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_PADDING_2); Continue; end;
          if s^.buffer_length = 0 then begin
            BrotliBitReaderUnload(br);
            available_in^ := BrotliBitReaderGetAvailIn(br);
            next_in^ := br^.next_in;
          end;
          s^.state := BROTLI_STATE_DONE;
        end;

      BROTLI_STATE_DONE:
        begin
          if s^.ringbuffer <> nil then begin
            err := WriteRingBuffer(s, available_out, next_out, total_out, BROTLI_TRUE);
            if err <> BROTLI_DECODER_SUCCESS then Continue;
          end;
          Exit(SaveErrorCode(s, err, input_size - available_in^));
        end;
    else
      err := BROTLI_FAILURE(BROTLI_DECODER_ERROR_UNREACHABLE);
    end;
  end;

  Result := SaveErrorCode(s, err, input_size - available_in^);
end;

function BrotliDecoderHasMoreOutput(s: PBrotliDecoderState): BROTLI_BOOL;
begin
  if s^.error_code < 0 then Exit(BROTLI_FALSE);
  Result := TO_BROTLI_BOOL((s^.ringbuffer <> nil) and (UnwrittenBytes(s, BROTLI_FALSE) <> 0));
end;

function BrotliDecoderTakeOutput(s: PBrotliDecoderState; size: PSizeT): PByte;
var
  available_out, requested_out: size_t;
  status: TBrotliDecoderErrorCode;
begin
  Result := nil;
  if size^ <> 0 then available_out := size^ else available_out := size_t(1) shl 24;
  requested_out := available_out;
  if (s^.ringbuffer = nil) or (s^.error_code < 0) then begin size^ := 0; Exit(nil); end;
  WrapRingBuffer(s);
  status := WriteRingBuffer(s, @available_out, @Result, nil, BROTLI_TRUE);
  if (status = BROTLI_DECODER_SUCCESS) or (status = BROTLI_DECODER_NEEDS_MORE_OUTPUT) then
    size^ := requested_out - available_out
  else begin
    if status < BROTLI_DECODER_SUCCESS then SaveErrorCode(s, status, 0);
    size^ := 0;
    Result := nil;
  end;
end;

function BrotliDecoderIsUsed(s: PBrotliDecoderState): BROTLI_BOOL;
begin
  Result := TO_BROTLI_BOOL((s^.state <> BROTLI_STATE_UNINITED) or (BrotliGetAvailableBits(@s^.br) <> 0));
end;

function BrotliDecoderIsFinished(s: PBrotliDecoderState): BROTLI_BOOL;
begin
  Result := TO_BROTLI_BOOL((s^.state = BROTLI_STATE_DONE) and (BrotliDecoderHasMoreOutput(s) = BROTLI_FALSE));
end;

function BrotliDecoderGetErrorCode(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
begin
  Result := TBrotliDecoderErrorCode(s^.error_code);
end;

function BrotliDecoderErrorString(c: TBrotliDecoderErrorCode): PChar;
begin
  case c of
    BROTLI_DECODER_NO_ERROR: Result := 'NO_ERROR';
    BROTLI_DECODER_SUCCESS: Result := 'SUCCESS';
    BROTLI_DECODER_NEEDS_MORE_INPUT: Result := 'NEEDS_MORE_INPUT';
    BROTLI_DECODER_NEEDS_MORE_OUTPUT: Result := 'NEEDS_MORE_OUTPUT';
    BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_NIBBLE: Result := 'ERROR_FORMAT_EXUBERANT_NIBBLE';
    BROTLI_DECODER_ERROR_FORMAT_RESERVED: Result := 'ERROR_FORMAT_RESERVED';
    BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_META_NIBBLE: Result := 'ERROR_FORMAT_EXUBERANT_META_NIBBLE';
    BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_ALPHABET: Result := 'ERROR_FORMAT_SIMPLE_HUFFMAN_ALPHABET';
    BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_SAME: Result := 'ERROR_FORMAT_SIMPLE_HUFFMAN_SAME';
    BROTLI_DECODER_ERROR_FORMAT_CL_SPACE: Result := 'ERROR_FORMAT_CL_SPACE';
    BROTLI_DECODER_ERROR_FORMAT_HUFFMAN_SPACE: Result := 'ERROR_FORMAT_HUFFMAN_SPACE';
    BROTLI_DECODER_ERROR_FORMAT_CONTEXT_MAP_REPEAT: Result := 'ERROR_FORMAT_CONTEXT_MAP_REPEAT';
    BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_1: Result := 'ERROR_FORMAT_BLOCK_LENGTH_1';
    BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_2: Result := 'ERROR_FORMAT_BLOCK_LENGTH_2';
    BROTLI_DECODER_ERROR_FORMAT_TRANSFORM: Result := 'ERROR_FORMAT_TRANSFORM';
    BROTLI_DECODER_ERROR_FORMAT_DICTIONARY: Result := 'ERROR_FORMAT_DICTIONARY';
    BROTLI_DECODER_ERROR_FORMAT_WINDOW_BITS: Result := 'ERROR_FORMAT_WINDOW_BITS';
    BROTLI_DECODER_ERROR_FORMAT_PADDING_1: Result := 'ERROR_FORMAT_PADDING_1';
    BROTLI_DECODER_ERROR_FORMAT_PADDING_2: Result := 'ERROR_FORMAT_PADDING_2';
    BROTLI_DECODER_ERROR_FORMAT_DISTANCE: Result := 'ERROR_FORMAT_DISTANCE';
    BROTLI_DECODER_ERROR_FORMAT_BLOCK_SWITCH: Result := 'ERROR_FORMAT_BLOCK_SWITCH';
    BROTLI_DECODER_ERROR_COMPOUND_DICTIONARY: Result := 'ERROR_COMPOUND_DICTIONARY';
    BROTLI_DECODER_ERROR_DICTIONARY_NOT_SET: Result := 'ERROR_DICTIONARY_NOT_SET';
    BROTLI_DECODER_ERROR_INVALID_ARGUMENTS: Result := 'ERROR_INVALID_ARGUMENTS';
    BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MODES: Result := 'ERROR_ALLOC_CONTEXT_MODES';
    BROTLI_DECODER_ERROR_ALLOC_TREE_GROUPS: Result := 'ERROR_ALLOC_TREE_GROUPS';
    BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MAP: Result := 'ERROR_ALLOC_CONTEXT_MAP';
    BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_1: Result := 'ERROR_ALLOC_RING_BUFFER_1';
    BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_2: Result := 'ERROR_ALLOC_RING_BUFFER_2';
    BROTLI_DECODER_ERROR_ALLOC_BLOCK_TYPE_TREES: Result := 'ERROR_ALLOC_BLOCK_TYPE_TREES';
    BROTLI_DECODER_ERROR_UNREACHABLE: Result := 'ERROR_UNREACHABLE';
  else
    Result := 'INVALID';
  end;
end;

function BrotliDecoderVersion: uint32_t;
begin
  Result := BROTLI_VERSION_VALUE;
end;

procedure BrotliDecoderSetMetadataCallbacks(state: PBrotliDecoderState;
  start_func: TBrotliDecoderMetadataStartFunc;
  chunk_func: TBrotliDecoderMetadataChunkFunc; opaque: Pointer);
begin
  state^.metadata_start_func := start_func;
  state^.metadata_chunk_func := chunk_func;
  state^.metadata_callback_opaque := opaque;
end;

end.
