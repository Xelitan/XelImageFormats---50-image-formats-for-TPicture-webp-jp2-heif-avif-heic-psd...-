unit Decode2;

// Author: www.xelitan.com
// License: MIT

{$mode Delphi}
{$H+}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, BrotliBase, BrotliBitReader, BrotliHuffman, BrotliCommon,
  BrotliSharedDictionary, Decode1;

type
  PSizeT = ^size_t;
  PPByte = ^PByte;
  PBrotliReg = ^brotli_reg_t;
  PInt = ^LongInt;

  TCmdLutElement = packed record
    insert_len_extra_bits: uint8_t;
    copy_len_extra_bits: uint8_t;
    distance_code: ShortInt;
    context: uint8_t;
    insert_len_offset: uint16_t;
    copy_len_offset: uint16_t;
  end;

function HuffmanTreeGroupDecode(group: PTHuffmanTreeGroup; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function DecodeContextMap(context_map_size: brotli_reg_t; num_htrees: PBrotliReg; context_map_arg: PPByte; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function DecodeBlockTypeAndLength(safe: LongInt; s: PBrotliDecoderState; tree_type: LongInt): TBrotliDecoderErrorCode;
procedure DetectTrivialLiteralBlockTypes(s: PBrotliDecoderState);
procedure PrepareLiteralDecoding(s: PBrotliDecoderState);
function DecodeLiteralBlockSwitchInternal(safe: LongInt; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function DecodeLiteralBlockSwitch(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function SafeDecodeLiteralBlockSwitch(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function DecodeCommandBlockSwitchInternal(safe: LongInt; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function DecodeCommandBlockSwitch(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function SafeDecodeCommandBlockSwitch(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function DecodeDistanceBlockSwitchInternal(safe: LongInt; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function DecodeDistanceBlockSwitch(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function SafeDecodeDistanceBlockSwitch(s: PBrotliDecoderState): BROTLI_BOOL;
function UnwrittenBytes(s: PBrotliDecoderState; wrap: BROTLI_BOOL): size_t;
function WriteRingBuffer(s: PBrotliDecoderState; available_out: PSizeT; next_out: PPByte; total_out: PSizeT; force: BROTLI_BOOL): TBrotliDecoderErrorCode;
procedure WrapRingBuffer(s: PBrotliDecoderState);
function BrotliEnsureRingBuffer(s: PBrotliDecoderState): BROTLI_BOOL;
function SkipMetadataBlock(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function CopyUncompressedBlockToOutput(available_out: PSizeT; next_out: PPByte; total_out: PSizeT; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
function AttachCompoundDictionary(state: PBrotliDecoderState; data: PByte; size: size_t): BROTLI_BOOL;
procedure EnsureCompoundDictionaryInitialized(state: PBrotliDecoderState);
function InitializeCompoundDictionaryCopy(s: PBrotliDecoderState; address, length: uint32_t): BROTLI_BOOL;
function GetCompoundDictionarySize(s: PBrotliDecoderState): uint32_t;
function CopyFromCompoundDictionary(s: PBrotliDecoderState; pos: LongInt): LongInt;
function BrotliDecoderAttachDictionary(state: PBrotliDecoderState; dict_type: TBrotliSharedDictionaryType; data_size: size_t; data: PByte): BROTLI_BOOL;
procedure BrotliCalculateRingBufferSize(s: PBrotliDecoderState);
function ReadContextModes(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
procedure TakeDistanceFromRingBuffer(s: PBrotliDecoderState);
function SafeReadBits(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t): BROTLI_BOOL;
function SafeReadBits32(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t): BROTLI_BOOL;
procedure CalculateDistanceLut(s: PBrotliDecoderState);
function ReadDistanceInternal(safe: LongInt; s: PBrotliDecoderState; br: PBrotliBitReader): BROTLI_BOOL;
procedure ReadDistance(s: PBrotliDecoderState; br: PBrotliBitReader);
function SafeReadDistance(s: PBrotliDecoderState; br: PBrotliBitReader): BROTLI_BOOL;
function ReadCommandInternal(safe: LongInt; s: PBrotliDecoderState; br: PBrotliBitReader; insert_length: PInt): BROTLI_BOOL;
procedure ReadCommand(s: PBrotliDecoderState; br: PBrotliBitReader; insert_length: PInt);
function SafeReadCommand(s: PBrotliDecoderState; br: PBrotliBitReader; insert_length: PInt): BROTLI_BOOL;
function CheckInputAmount(safe: LongInt; br: PBrotliBitReader): BROTLI_BOOL;

implementation

const
  SHARED_BROTLI_MAX_COMPOUND_DICTS = 15;
  SHARED_BROTLI_MAX_RAW_DICT_SIZE = uint32_t($7FFFFFFF);
  kCmdLut: array[0..BROTLI_NUM_COMMAND_SYMBOLS - 1] of TCmdLutElement = (
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 0; insert_len_offset: 0; copy_len_offset: 2),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 1; insert_len_offset: 0; copy_len_offset: 3),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 2; insert_len_offset: 0; copy_len_offset: 4),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 5),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 6),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 7),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 8),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 9),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 0; insert_len_offset: 1; copy_len_offset: 2),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 1; insert_len_offset: 1; copy_len_offset: 3),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 2; insert_len_offset: 1; copy_len_offset: 4),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 5),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 6),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 7),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 8),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 9),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 0; insert_len_offset: 2; copy_len_offset: 2),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 1; insert_len_offset: 2; copy_len_offset: 3),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 2; insert_len_offset: 2; copy_len_offset: 4),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 5),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 6),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 7),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 8),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 9),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 0; insert_len_offset: 3; copy_len_offset: 2),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 1; insert_len_offset: 3; copy_len_offset: 3),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 2; insert_len_offset: 3; copy_len_offset: 4),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 5),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 6),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 7),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 8),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 9),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 0; insert_len_offset: 4; copy_len_offset: 2),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 1; insert_len_offset: 4; copy_len_offset: 3),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 2; insert_len_offset: 4; copy_len_offset: 4),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 5),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 6),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 7),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 8),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 9),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 0; insert_len_offset: 5; copy_len_offset: 2),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 1; insert_len_offset: 5; copy_len_offset: 3),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 2; insert_len_offset: 5; copy_len_offset: 4),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 5),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 6),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 7),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 8),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 9),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 0; insert_len_offset: 6; copy_len_offset: 2),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 1; insert_len_offset: 6; copy_len_offset: 3),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 2; insert_len_offset: 6; copy_len_offset: 4),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 5),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 6),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 7),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 8),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 9),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 0; insert_len_offset: 8; copy_len_offset: 2),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 1; insert_len_offset: 8; copy_len_offset: 3),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 2; insert_len_offset: 8; copy_len_offset: 4),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 5),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 6),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 7),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 8),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 9),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 10),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 12),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 14),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 18),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 22),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 30),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 38),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 0; copy_len_offset: 54),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 10),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 12),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 14),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 18),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 22),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 30),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 38),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 1; copy_len_offset: 54),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 10),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 12),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 14),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 18),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 22),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 30),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 38),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 2; copy_len_offset: 54),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 10),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 12),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 14),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 18),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 22),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 30),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 38),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 3; copy_len_offset: 54),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 10),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 12),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 14),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 18),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 22),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 30),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 38),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 4; copy_len_offset: 54),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 10),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 12),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 14),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 18),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 22),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 30),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 38),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 5; copy_len_offset: 54),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 10),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 12),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 14),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 18),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 22),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 30),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 38),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 6; copy_len_offset: 54),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 10),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 1; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 12),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 14),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 2; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 18),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 22),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 3; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 30),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 38),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 4; distance_code: 0; context: 3; insert_len_offset: 8; copy_len_offset: 54),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 0; copy_len_offset: 2),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 0; copy_len_offset: 3),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 0; copy_len_offset: 4),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 5),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 6),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 7),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 8),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 9),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 1; copy_len_offset: 2),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 1; copy_len_offset: 3),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 1; copy_len_offset: 4),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 5),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 6),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 7),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 8),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 9),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 2; copy_len_offset: 2),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 2; copy_len_offset: 3),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 2; copy_len_offset: 4),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 5),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 6),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 7),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 8),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 9),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 3; copy_len_offset: 2),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 3; copy_len_offset: 3),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 3; copy_len_offset: 4),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 5),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 6),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 7),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 8),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 9),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 4; copy_len_offset: 2),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 4; copy_len_offset: 3),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 4; copy_len_offset: 4),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 5),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 6),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 7),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 8),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 9),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 5; copy_len_offset: 2),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 5; copy_len_offset: 3),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 5; copy_len_offset: 4),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 5),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 6),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 7),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 8),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 9),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 6; copy_len_offset: 2),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 6; copy_len_offset: 3),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 6; copy_len_offset: 4),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 5),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 6),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 7),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 8),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 9),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 8; copy_len_offset: 2),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 8; copy_len_offset: 3),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 8; copy_len_offset: 4),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 5),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 6),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 7),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 8),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 9),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 10),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 12),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 14),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 18),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 22),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 30),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 38),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 54),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 10),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 12),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 14),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 18),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 22),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 30),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 38),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 54),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 10),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 12),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 14),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 18),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 22),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 30),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 38),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 54),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 10),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 12),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 14),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 18),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 22),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 30),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 38),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 54),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 10),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 12),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 14),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 18),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 22),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 30),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 38),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 54),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 10),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 12),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 14),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 18),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 22),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 30),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 38),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 54),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 10),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 12),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 14),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 18),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 22),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 30),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 38),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 54),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 10),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 12),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 14),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 18),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 22),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 30),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 38),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 54),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 10; copy_len_offset: 2),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 10; copy_len_offset: 3),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 10; copy_len_offset: 4),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 5),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 6),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 7),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 8),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 9),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 14; copy_len_offset: 2),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 14; copy_len_offset: 3),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 14; copy_len_offset: 4),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 5),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 6),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 7),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 8),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 9),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 18; copy_len_offset: 2),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 18; copy_len_offset: 3),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 18; copy_len_offset: 4),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 5),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 6),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 7),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 8),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 9),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 26; copy_len_offset: 2),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 26; copy_len_offset: 3),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 26; copy_len_offset: 4),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 5),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 6),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 7),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 8),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 9),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 34; copy_len_offset: 2),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 34; copy_len_offset: 3),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 34; copy_len_offset: 4),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 5),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 6),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 7),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 8),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 9),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 50; copy_len_offset: 2),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 50; copy_len_offset: 3),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 50; copy_len_offset: 4),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 5),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 6),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 7),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 8),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 9),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 66; copy_len_offset: 2),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 66; copy_len_offset: 3),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 66; copy_len_offset: 4),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 5),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 6),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 7),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 8),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 9),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 98; copy_len_offset: 2),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 98; copy_len_offset: 3),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 98; copy_len_offset: 4),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 5),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 6),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 7),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 8),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 9),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 10),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 12),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 14),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 18),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 22),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 30),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 38),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 54),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 10),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 12),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 14),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 18),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 22),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 30),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 38),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 54),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 10),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 12),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 14),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 18),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 22),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 30),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 38),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 54),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 10),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 12),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 14),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 18),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 22),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 30),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 38),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 54),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 10),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 12),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 14),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 18),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 22),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 30),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 38),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 54),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 10),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 12),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 14),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 18),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 22),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 30),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 38),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 54),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 10),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 12),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 14),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 18),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 22),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 30),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 38),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 54),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 10),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 12),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 14),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 18),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 22),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 30),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 38),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 54),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 70),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 102),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 134),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 198),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 326),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 582),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 1094),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 0; copy_len_offset: 2118),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 70),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 102),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 134),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 198),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 326),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 582),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 1094),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 1; copy_len_offset: 2118),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 70),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 102),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 134),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 198),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 326),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 582),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 1094),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 2; copy_len_offset: 2118),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 70),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 102),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 134),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 198),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 326),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 582),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 1094),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 3; copy_len_offset: 2118),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 70),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 102),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 134),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 198),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 326),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 582),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 1094),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 4; copy_len_offset: 2118),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 70),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 102),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 134),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 198),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 326),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 582),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 1094),
    (insert_len_extra_bits: 0; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 5; copy_len_offset: 2118),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 70),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 102),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 134),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 198),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 326),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 582),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 1094),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 6; copy_len_offset: 2118),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 70),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 102),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 134),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 198),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 326),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 582),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 1094),
    (insert_len_extra_bits: 1; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 8; copy_len_offset: 2118),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 130; copy_len_offset: 2),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 130; copy_len_offset: 3),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 130; copy_len_offset: 4),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 5),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 6),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 7),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 8),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 9),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 194; copy_len_offset: 2),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 194; copy_len_offset: 3),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 194; copy_len_offset: 4),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 5),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 6),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 7),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 8),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 9),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 322; copy_len_offset: 2),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 322; copy_len_offset: 3),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 322; copy_len_offset: 4),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 5),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 6),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 7),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 8),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 9),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 578; copy_len_offset: 2),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 578; copy_len_offset: 3),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 578; copy_len_offset: 4),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 5),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 6),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 7),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 8),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 9),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 1090; copy_len_offset: 2),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 1090; copy_len_offset: 3),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 1090; copy_len_offset: 4),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 5),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 6),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 7),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 8),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 9),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 2114; copy_len_offset: 2),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 2114; copy_len_offset: 3),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 2114; copy_len_offset: 4),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 5),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 6),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 7),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 8),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 9),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 6210; copy_len_offset: 2),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 6210; copy_len_offset: 3),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 6210; copy_len_offset: 4),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 5),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 6),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 7),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 8),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 9),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 0; distance_code: -1; context: 0; insert_len_offset: 22594; copy_len_offset: 2),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 0; distance_code: -1; context: 1; insert_len_offset: 22594; copy_len_offset: 3),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 0; distance_code: -1; context: 2; insert_len_offset: 22594; copy_len_offset: 4),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 5),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 6),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 7),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 8),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 0; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 9),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 70),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 102),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 134),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 198),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 326),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 582),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 1094),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 10; copy_len_offset: 2118),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 70),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 102),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 134),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 198),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 326),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 582),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 1094),
    (insert_len_extra_bits: 2; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 14; copy_len_offset: 2118),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 70),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 102),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 134),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 198),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 326),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 582),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 1094),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 18; copy_len_offset: 2118),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 70),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 102),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 134),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 198),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 326),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 582),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 1094),
    (insert_len_extra_bits: 3; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 26; copy_len_offset: 2118),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 70),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 102),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 134),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 198),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 326),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 582),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 1094),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 34; copy_len_offset: 2118),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 70),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 102),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 134),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 198),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 326),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 582),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 1094),
    (insert_len_extra_bits: 4; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 50; copy_len_offset: 2118),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 70),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 102),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 134),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 198),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 326),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 582),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 1094),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 66; copy_len_offset: 2118),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 70),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 102),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 134),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 198),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 326),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 582),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 1094),
    (insert_len_extra_bits: 5; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 98; copy_len_offset: 2118),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 10),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 12),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 14),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 18),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 22),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 30),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 38),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 54),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 10),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 12),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 14),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 18),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 22),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 30),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 38),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 54),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 10),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 12),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 14),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 18),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 22),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 30),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 38),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 54),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 10),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 12),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 14),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 18),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 22),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 30),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 38),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 54),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 10),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 12),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 14),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 18),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 22),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 30),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 38),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 54),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 10),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 12),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 14),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 18),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 22),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 30),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 38),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 54),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 10),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 12),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 14),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 18),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 22),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 30),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 38),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 54),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 10),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 1; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 12),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 14),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 2; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 18),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 22),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 3; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 30),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 38),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 4; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 54),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 70),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 102),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 134),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 198),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 326),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 582),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 1094),
    (insert_len_extra_bits: 6; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 130; copy_len_offset: 2118),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 70),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 102),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 134),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 198),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 326),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 582),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 1094),
    (insert_len_extra_bits: 7; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 194; copy_len_offset: 2118),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 70),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 102),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 134),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 198),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 326),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 582),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 1094),
    (insert_len_extra_bits: 8; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 322; copy_len_offset: 2118),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 70),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 102),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 134),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 198),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 326),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 582),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 1094),
    (insert_len_extra_bits: 9; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 578; copy_len_offset: 2118),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 70),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 102),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 134),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 198),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 326),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 582),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 1094),
    (insert_len_extra_bits: 10; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 1090; copy_len_offset: 2118),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 70),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 102),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 134),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 198),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 326),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 582),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 1094),
    (insert_len_extra_bits: 12; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 2114; copy_len_offset: 2118),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 70),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 102),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 134),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 198),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 326),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 582),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 1094),
    (insert_len_extra_bits: 14; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 6210; copy_len_offset: 2118),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 70),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 5; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 102),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 6; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 134),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 7; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 198),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 8; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 326),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 9; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 582),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 10; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 1094),
    (insert_len_extra_bits: 24; copy_len_extra_bits: 24; distance_code: -1; context: 3; insert_len_offset: 22594; copy_len_offset: 2118)
  );

function HuffmanTreeGroupDecode(group: PTHuffmanTreeGroup; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
var h: PBrotliMetablockHeaderArena; table_size: uint64_t; res: TBrotliDecoderErrorCode;
begin
  h := @s^.arena.header;
  if h^.substate_tree_group <> BROTLI_STATE_TREE_GROUP_LOOP then begin
    h^.next := group^.codes; h^.htree_index := 0; h^.substate_tree_group := BROTLI_STATE_TREE_GROUP_LOOP;
  end;
  while h^.htree_index < group^.num_htrees do begin
    table_size := 0;
    res := ReadHuffmanCode(group^.alphabet_size_max, group^.alphabet_size_limit, h^.next, @table_size, s);
    if res <> BROTLI_DECODER_SUCCESS then Exit(res);
    group^.htrees[h^.htree_index] := h^.next; Inc(h^.next, NativeInt(table_size)); Inc(h^.htree_index);
  end;
  h^.substate_tree_group := BROTLI_STATE_TREE_GROUP_NONE; Result := BROTLI_DECODER_SUCCESS;
end;

function DecodeContextMap(context_map_size: brotli_reg_t; num_htrees: PBrotliReg; context_map_arg: PPByte; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
var br: PBrotliBitReader; h: PBrotliMetablockHeaderArena; res: TBrotliDecoderErrorCode;
    bits, alphabet_size, context_index, max_run_length_prefix, code, reps: brotli_reg_t;
    context_map: PByte; skip_preamble: Boolean;
begin
  br := @s^.br; h := @s^.arena.header;
  if h^.substate_context_map = BROTLI_STATE_CONTEXT_MAP_NONE then begin
    res := DecodeVarLenUint8(s, br, PUInt64(num_htrees)); if res <> BROTLI_DECODER_SUCCESS then Exit(res);
    Inc(num_htrees^); h^.context_index := 0;
    GetMem(context_map_arg^, context_map_size); if context_map_arg^ = nil then Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MAP));
    if num_htrees^ <= 1 then begin FillChar(context_map_arg^^, context_map_size, 0); Exit(BROTLI_DECODER_SUCCESS); end;
    h^.substate_context_map := BROTLI_STATE_CONTEXT_MAP_READ_PREFIX;
  end;
  if h^.substate_context_map = BROTLI_STATE_CONTEXT_MAP_READ_PREFIX then begin
    if BrotliSafeGetBits(br, 5, bits) = BROTLI_FALSE then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
    if (bits and 1) <> 0 then begin h^.max_run_length_prefix := (bits shr 1) + 1; BrotliDropBits(br, 5); end
    else begin h^.max_run_length_prefix := 0; BrotliDropBits(br, 1); end;
    h^.substate_context_map := BROTLI_STATE_CONTEXT_MAP_HUFFMAN;
  end;
  if h^.substate_context_map = BROTLI_STATE_CONTEXT_MAP_HUFFMAN then begin
    alphabet_size := num_htrees^ + h^.max_run_length_prefix;
    res := ReadHuffmanCode(alphabet_size, alphabet_size, @h^.context_map_table[0], nil, s); if res <> BROTLI_DECODER_SUCCESS then Exit(res);
    h^.code := $FFFF; h^.substate_context_map := BROTLI_STATE_CONTEXT_MAP_DECODE;
  end;
  if h^.substate_context_map = BROTLI_STATE_CONTEXT_MAP_DECODE then begin
    context_index := h^.context_index; max_run_length_prefix := h^.max_run_length_prefix; context_map := context_map_arg^; code := h^.code;
    skip_preamble := (code <> $FFFF);
    while (context_index < context_map_size) or skip_preamble do begin
      if not skip_preamble then begin
        if SafeReadSymbol(@h^.context_map_table[0], br, code) = BROTLI_FALSE then begin h^.code := $FFFF; h^.context_index := context_index; Exit(BROTLI_DECODER_NEEDS_MORE_INPUT); end;
        if code = 0 then begin context_map[context_index] := 0; Inc(context_index); Continue; end;
        if code > max_run_length_prefix then begin context_map[context_index] := uint8_t(code - max_run_length_prefix); Inc(context_index); Continue; end;
      end else skip_preamble := False;
      if BrotliSafeReadBits(br, code, reps) = BROTLI_FALSE then begin h^.code := code; h^.context_index := context_index; Exit(BROTLI_DECODER_NEEDS_MORE_INPUT); end;
      Inc(reps, brotli_reg_t(1) shl code);
      if context_index + reps > context_map_size then Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_CONTEXT_MAP_REPEAT));
      while reps <> 0 do begin context_map[context_index] := 0; Inc(context_index); Dec(reps); end;
    end;
    h^.substate_context_map := BROTLI_STATE_CONTEXT_MAP_TRANSFORM;
  end;
  if h^.substate_context_map = BROTLI_STATE_CONTEXT_MAP_TRANSFORM then begin
    if BrotliSafeReadBits(br, 1, bits) = BROTLI_FALSE then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
    if bits <> 0 then InverseMoveToFrontTransform(context_map_arg^, context_map_size, s);
    h^.substate_context_map := BROTLI_STATE_CONTEXT_MAP_NONE; Exit(BROTLI_DECODER_SUCCESS);
  end;
  Result := BROTLI_FAILURE(BROTLI_DECODER_ERROR_UNREACHABLE);
end;

function DecodeBlockTypeAndLength(safe: LongInt; s: PBrotliDecoderState; tree_type: LongInt): TBrotliDecoderErrorCode;
var max_block_type, block_type: brotli_reg_t; type_tree, len_tree: PHuffmanCode; br: PBrotliBitReader; ringbuffer: PBrotliReg; memento: TBrotliBitReaderState;
begin
  max_block_type := s^.num_block_types[tree_type]; type_tree := s^.block_type_trees + tree_type * BROTLI_HUFFMAN_MAX_SIZE_258; len_tree := s^.block_len_trees + tree_type * BROTLI_HUFFMAN_MAX_SIZE_26; br := @s^.br; ringbuffer := @s^.block_type_rb[tree_type * 2];
  if max_block_type <= 1 then Exit(BROTLI_DECODER_ERROR_FORMAT_BLOCK_SWITCH);
  if safe = 0 then begin block_type := ReadSymbol(type_tree, br); s^.block_length[tree_type] := ReadBlockLength(len_tree, br); end
  else begin
    BrotliBitReaderSaveState(br, @memento);
    if SafeReadSymbol(type_tree, br, block_type) = BROTLI_FALSE then Exit(BROTLI_DECODER_NEEDS_MORE_INPUT);
    if SafeReadBlockLength(s, s^.block_length[tree_type], len_tree, br) = BROTLI_FALSE then begin s^.substate_read_block_length := BROTLI_STATE_READ_BLOCK_LENGTH_NONE; BrotliBitReaderRestoreState(br, @memento); Exit(BROTLI_DECODER_NEEDS_MORE_INPUT); end;
  end;
  if block_type = 1 then block_type := ringbuffer[1] + 1 else if block_type = 0 then block_type := ringbuffer[0] else Dec(block_type, 2);
  if block_type >= max_block_type then Dec(block_type, max_block_type);
  ringbuffer[0] := ringbuffer[1]; ringbuffer[1] := block_type; Result := BROTLI_DECODER_SUCCESS;
end;

procedure DetectTrivialLiteralBlockTypes(s: PBrotliDecoderState);
var i, j, offset, sample, error: size_t;
begin
  for i := 0 to 7 do s^.trivial_literal_contexts[i] := 0; i := 0;
  while i < s^.num_block_types[0] do begin
    offset := i shl BROTLI_LITERAL_CONTEXT_BITS; error := 0; sample := s^.context_map[offset]; j := 0;
    while j < (size_t(1) shl BROTLI_LITERAL_CONTEXT_BITS) do begin error := error or (s^.context_map[offset + j] xor sample); Inc(j); end;
    if error = 0 then s^.trivial_literal_contexts[i shr 5] := s^.trivial_literal_contexts[i shr 5] or (uint32_t(1) shl (i and 31)); Inc(i);
  end;
end;

procedure PrepareLiteralDecoding(s: PBrotliDecoderState);
var context_mode: uint8_t; trivial: size_t; block_type, context_offset: brotli_reg_t;
begin
  block_type := s^.block_type_rb[1]; context_offset := block_type shl BROTLI_LITERAL_CONTEXT_BITS; s^.context_map_slice := s^.context_map + context_offset;
  trivial := s^.trivial_literal_contexts[block_type shr 5]; s^.trivial_literal_context := (trivial shr (block_type and 31)) and 1;
  s^.literal_htree := s^.literal_hgroup.htrees[s^.context_map_slice[0]]; context_mode := s^.context_modes[block_type] and 3; s^.context_lookup := BrotliContextLut(TContextType(context_mode));
end;

function DecodeLiteralBlockSwitchInternal(safe: LongInt; s: PBrotliDecoderState): TBrotliDecoderErrorCode; begin Result := DecodeBlockTypeAndLength(safe, s, 0); if Result = BROTLI_DECODER_SUCCESS then PrepareLiteralDecoding(s); end;
function DecodeLiteralBlockSwitch(s: PBrotliDecoderState): TBrotliDecoderErrorCode; begin Result := DecodeLiteralBlockSwitchInternal(0, s); end;
function SafeDecodeLiteralBlockSwitch(s: PBrotliDecoderState): TBrotliDecoderErrorCode; begin Result := DecodeLiteralBlockSwitchInternal(1, s); end;
function DecodeCommandBlockSwitchInternal(safe: LongInt; s: PBrotliDecoderState): TBrotliDecoderErrorCode; begin Result := DecodeBlockTypeAndLength(safe, s, 1); if Result = BROTLI_DECODER_SUCCESS then s^.htree_command := s^.insert_copy_hgroup.htrees[s^.block_type_rb[3]]; end;
function DecodeCommandBlockSwitch(s: PBrotliDecoderState): TBrotliDecoderErrorCode; begin Result := DecodeCommandBlockSwitchInternal(0, s); end;
function SafeDecodeCommandBlockSwitch(s: PBrotliDecoderState): TBrotliDecoderErrorCode; begin Result := DecodeCommandBlockSwitchInternal(1, s); end;
function DecodeDistanceBlockSwitchInternal(safe: LongInt; s: PBrotliDecoderState): TBrotliDecoderErrorCode; begin Result := DecodeBlockTypeAndLength(safe, s, 2); if Result = BROTLI_DECODER_SUCCESS then begin s^.dist_context_map_slice := s^.dist_context_map + (s^.block_type_rb[5] shl BROTLI_DISTANCE_CONTEXT_BITS); s^.dist_htree_index := s^.dist_context_map_slice[s^.distance_context]; end; end;
function DecodeDistanceBlockSwitch(s: PBrotliDecoderState): TBrotliDecoderErrorCode; begin Result := DecodeDistanceBlockSwitchInternal(0, s); end;
function SafeDecodeDistanceBlockSwitch(s: PBrotliDecoderState): BROTLI_BOOL; var r: TBrotliDecoderErrorCode; begin r := DecodeDistanceBlockSwitchInternal(1, s); Result := TO_BROTLI_BOOL(r = BROTLI_DECODER_SUCCESS); end;

function UnwrittenBytes(s: PBrotliDecoderState; wrap: BROTLI_BOOL): size_t;
var pos, partial_pos_rb: size_t;
begin if (wrap <> 0) and (s^.pos > s^.ringbuffer_size) then pos := s^.ringbuffer_size else pos := s^.pos; partial_pos_rb := (s^.rb_roundtrips * size_t(s^.ringbuffer_size)) + pos; Result := partial_pos_rb - s^.partial_pos_out; end;

function WriteRingBuffer(s: PBrotliDecoderState; available_out: PSizeT; next_out: PPByte; total_out: PSizeT; force: BROTLI_BOOL): TBrotliDecoderErrorCode;
var start: PByte; to_write, num_written: size_t;
begin
  start := s^.ringbuffer + (s^.partial_pos_out and size_t(s^.ringbuffer_mask)); to_write := UnwrittenBytes(s, BROTLI_TRUE); num_written := available_out^; if num_written > to_write then num_written := to_write;
  if s^.meta_block_remaining_len < 0 then Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_1));
  if (next_out <> nil) and (next_out^ = nil) then next_out^ := start else if next_out <> nil then begin Move(start^, next_out^^, num_written); Inc(next_out^, num_written); end;
  Dec(available_out^, num_written); Inc(s^.partial_pos_out, num_written); if total_out <> nil then total_out^ := s^.partial_pos_out;
  if num_written < to_write then begin if (s^.ringbuffer_size = (1 shl s^.window_bits)) or (force <> 0) then Exit(BROTLI_DECODER_NEEDS_MORE_OUTPUT) else Exit(BROTLI_DECODER_SUCCESS); end;
  if (s^.ringbuffer_size = (1 shl s^.window_bits)) and (s^.pos >= s^.ringbuffer_size) then begin Dec(s^.pos, s^.ringbuffer_size); Inc(s^.rb_roundtrips); s^.should_wrap_ringbuffer := Ord(size_t(s^.pos) <> 0); end;
  Result := BROTLI_DECODER_SUCCESS;
end;
procedure WrapRingBuffer(s: PBrotliDecoderState); begin if s^.should_wrap_ringbuffer <> 0 then begin Move(s^.ringbuffer_end^, s^.ringbuffer^, size_t(s^.pos)); s^.should_wrap_ringbuffer := 0; end; end;

function BrotliEnsureRingBuffer(s: PBrotliDecoderState): BROTLI_BOOL;
var old_ringbuffer: PByte;
begin
  old_ringbuffer := s^.ringbuffer; if s^.ringbuffer_size = s^.new_ringbuffer_size then Exit(BROTLI_TRUE);
  GetMem(s^.ringbuffer, size_t(s^.new_ringbuffer_size) + kRingBufferWriteAheadSlack); if s^.ringbuffer = nil then begin s^.ringbuffer := old_ringbuffer; Exit(BROTLI_FALSE); end;
  s^.ringbuffer[s^.new_ringbuffer_size - 2] := 0; s^.ringbuffer[s^.new_ringbuffer_size - 1] := 0;
  if old_ringbuffer <> nil then begin Move(old_ringbuffer^, s^.ringbuffer^, size_t(s^.pos)); FreeMem(old_ringbuffer); end;
  s^.ringbuffer_size := s^.new_ringbuffer_size; s^.ringbuffer_mask := s^.new_ringbuffer_size - 1; s^.ringbuffer_end := s^.ringbuffer + s^.ringbuffer_size; Result := BROTLI_TRUE;
end;

function SkipMetadataBlock(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
var br: PBrotliBitReader; nbytes: LongInt; buffer: array[0..7] of uint8_t;
begin
  br := @s^.br; if s^.meta_block_remaining_len = 0 then Exit(BROTLI_DECODER_SUCCESS);
  if BrotliGetAvailableBits(br) >= 8 then begin nbytes := LongInt(BrotliGetAvailableBits(br) shr 3); if nbytes > s^.meta_block_remaining_len then nbytes := s^.meta_block_remaining_len; BrotliCopyBytes(@buffer[0], br, size_t(nbytes)); if Assigned(s^.metadata_chunk_func) then s^.metadata_chunk_func(s^.metadata_callback_opaque, @buffer[0], size_t(nbytes)); Dec(s^.meta_block_remaining_len, nbytes); if s^.meta_block_remaining_len = 0 then Exit(BROTLI_DECODER_SUCCESS); end;
  nbytes := LongInt(BrotliGetRemainingBytes(br)); if nbytes > s^.meta_block_remaining_len then nbytes := s^.meta_block_remaining_len;
  if nbytes > 0 then begin if Assigned(s^.metadata_chunk_func) then s^.metadata_chunk_func(s^.metadata_callback_opaque, br^.next_in, size_t(nbytes)); BrotliDropBytes(br, size_t(nbytes)); Dec(s^.meta_block_remaining_len, nbytes); if s^.meta_block_remaining_len = 0 then Exit(BROTLI_DECODER_SUCCESS); end;
  Result := BROTLI_DECODER_NEEDS_MORE_INPUT;
end;

function CopyUncompressedBlockToOutput(available_out: PSizeT; next_out: PPByte; total_out: PSizeT; s: PBrotliDecoderState): TBrotliDecoderErrorCode;
var nbytes: LongInt; res: TBrotliDecoderErrorCode;
begin
  if BrotliEnsureRingBuffer(s) = BROTLI_FALSE then Exit(BROTLI_FAILURE(BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_1));
  while True do case s^.substate_uncompressed of
    BROTLI_STATE_UNCOMPRESSED_NONE: begin nbytes := LongInt(BrotliGetRemainingBytes(@s^.br)); if nbytes > s^.meta_block_remaining_len then nbytes := s^.meta_block_remaining_len; if s^.pos + nbytes > s^.ringbuffer_size then nbytes := s^.ringbuffer_size - s^.pos; BrotliCopyBytes(@s^.ringbuffer[s^.pos], @s^.br, size_t(nbytes)); Inc(s^.pos, nbytes); Dec(s^.meta_block_remaining_len, nbytes); if s^.pos < (1 shl s^.window_bits) then begin if s^.meta_block_remaining_len = 0 then Exit(BROTLI_DECODER_SUCCESS); Exit(BROTLI_DECODER_NEEDS_MORE_INPUT); end; s^.substate_uncompressed := BROTLI_STATE_UNCOMPRESSED_WRITE; end;
    BROTLI_STATE_UNCOMPRESSED_WRITE: begin res := WriteRingBuffer(s, available_out, next_out, total_out, BROTLI_FALSE); if res <> BROTLI_DECODER_SUCCESS then Exit(res); if s^.ringbuffer_size = (1 shl s^.window_bits) then s^.max_distance := s^.max_backward_distance; s^.substate_uncompressed := BROTLI_STATE_UNCOMPRESSED_NONE; end;
  end;
end;

function AttachCompoundDictionary(state: PBrotliDecoderState; data: PByte; size: size_t): BROTLI_BOOL;
var addon: PBrotliDecoderCompoundDictionary;
begin
  addon := state^.compound_dictionary; if size = 0 then Exit(BROTLI_TRUE); if size > SHARED_BROTLI_MAX_RAW_DICT_SIZE then Exit(BROTLI_FALSE); if state^.state <> BROTLI_STATE_UNINITED then Exit(BROTLI_FALSE);
  if addon = nil then begin New(addon); FillChar(addon^, SizeOf(addon^), 0); addon^.block_bits := 255; addon^.chunk_offsets[0] := 0; state^.compound_dictionary := addon; end;
  if addon^.num_chunks = SHARED_BROTLI_MAX_COMPOUND_DICTS then Exit(BROTLI_FALSE); if size > SHARED_BROTLI_MAX_RAW_DICT_SIZE - addon^.total_size then Exit(BROTLI_FALSE);
  addon^.chunks[addon^.num_chunks] := data; Inc(addon^.num_chunks); Inc(addon^.total_size, uint32_t(size)); addon^.chunk_offsets[addon^.num_chunks] := addon^.total_size; Result := BROTLI_TRUE;
end;
procedure EnsureCompoundDictionaryInitialized(state: PBrotliDecoderState);
var addon: PBrotliDecoderCompoundDictionary; block_bits, index: size_t; cursor, maximal_address: uint32_t;
begin addon := state^.compound_dictionary; block_bits := 8; cursor := 0; index := 0; maximal_address := addon^.total_size - 1; if addon^.block_bits <> 255 then Exit; while (maximal_address shr block_bits) <> 0 do Inc(block_bits); Dec(block_bits, 8); addon^.block_bits := uint8_t(block_bits); while cursor <= maximal_address do begin while addon^.chunk_offsets[index + 1] < cursor do Inc(index); addon^.block_map[cursor shr block_bits] := uint8_t(index); Inc(cursor, uint32_t(1) shl block_bits); end; end;
function InitializeCompoundDictionaryCopy(s: PBrotliDecoderState; address, length: uint32_t): BROTLI_BOOL;
var addon: PBrotliDecoderCompoundDictionary; index: size_t;
begin addon := s^.compound_dictionary; EnsureCompoundDictionaryInitialized(s); index := addon^.block_map[address shr addon^.block_bits]; while address >= addon^.chunk_offsets[index + 1] do Inc(index); if length > addon^.total_size - address then Exit(BROTLI_FALSE); s^.dist_rb[s^.dist_rb_idx and 3] := s^.distance_code; Inc(s^.dist_rb_idx); Dec(s^.meta_block_remaining_len, length); addon^.br_index := uint16_t(index); addon^.br_offset := address - addon^.chunk_offsets[index]; addon^.br_length := length; addon^.br_copied := 0; Result := BROTLI_TRUE; end;
function GetCompoundDictionarySize(s: PBrotliDecoderState): uint32_t; begin if s^.compound_dictionary <> nil then Result := s^.compound_dictionary^.total_size else Result := 0; end;
function CopyFromCompoundDictionary(s: PBrotliDecoderState; pos: LongInt): LongInt;
var addon: PBrotliDecoderCompoundDictionary; orig_pos, space: LongInt; copy_dst, copy_src: PByte; rem_chunk_length, length: uint32_t;
begin addon := s^.compound_dictionary; orig_pos := pos; while addon^.br_length <> addon^.br_copied do begin copy_dst := @s^.ringbuffer[pos]; copy_src := addon^.chunks[addon^.br_index] + addon^.br_offset; space := s^.ringbuffer_size - pos; rem_chunk_length := (addon^.chunk_offsets[addon^.br_index + 1] - addon^.chunk_offsets[addon^.br_index]) - addon^.br_offset; length := addon^.br_length - addon^.br_copied; if length > rem_chunk_length then length := rem_chunk_length; if length > uint32_t(space) then length := uint32_t(space); Move(copy_src^, copy_dst^, size_t(length)); Inc(pos, length); Inc(addon^.br_offset, length); Inc(addon^.br_copied, length); if length = rem_chunk_length then begin Inc(addon^.br_index); addon^.br_offset := 0; end; if pos = s^.ringbuffer_size then Break; end; Result := pos - orig_pos; end;
function BrotliDecoderAttachDictionary(state: PBrotliDecoderState; dict_type: TBrotliSharedDictionaryType; data_size: size_t; data: PByte): BROTLI_BOOL; begin if state^.state <> BROTLI_STATE_UNINITED then Exit(BROTLI_FALSE); Result := AttachCompoundDictionary(state, data, data_size); end;

procedure BrotliCalculateRingBufferSize(s: PBrotliDecoderState);
var window_size, new_ringbuffer_size, min_size, output_size: LongInt;
begin window_size := 1 shl s^.window_bits; new_ringbuffer_size := window_size; if s^.ringbuffer_size <> 0 then min_size := s^.ringbuffer_size else min_size := 1024; if s^.ringbuffer_size = window_size then Exit; if s^.is_metadata <> 0 then Exit; if s^.ringbuffer = nil then output_size := 0 else output_size := s^.pos; Inc(output_size, s^.meta_block_remaining_len); if min_size < output_size then min_size := output_size; if s^.canny_ringbuffer_allocation <> 0 then while (new_ringbuffer_size shr 1) >= min_size do new_ringbuffer_size := new_ringbuffer_size shr 1; s^.new_ringbuffer_size := new_ringbuffer_size; end;
function ReadContextModes(s: PBrotliDecoderState): TBrotliDecoderErrorCode;
var br: PBrotliBitReader; i: LongInt; bits: brotli_reg_t;
begin br := @s^.br; i := s^.loop_counter; while i < LongInt(s^.num_block_types[0]) do begin if BrotliSafeReadBits(br, 2, bits) = BROTLI_FALSE then begin s^.loop_counter := i; Exit(BROTLI_DECODER_NEEDS_MORE_INPUT); end; s^.context_modes[i] := uint8_t(bits); Inc(i); end; Result := BROTLI_DECODER_SUCCESS; end;
procedure TakeDistanceFromRingBuffer(s: PBrotliDecoderState);
var offset, index_delta, delta, base: LongInt;
begin offset := s^.distance_code - 3; if s^.distance_code <= 3 then begin s^.distance_context := 1 shr s^.distance_code; s^.distance_code := s^.dist_rb[(s^.dist_rb_idx - offset) and 3]; Dec(s^.dist_rb_idx, s^.distance_context); end else begin index_delta := 3; base := s^.distance_code - 10; if s^.distance_code < 10 then base := s^.distance_code - 4 else index_delta := 2; delta := (($605142 shr (4 * base)) and $F) - 3; s^.distance_code := s^.dist_rb[(s^.dist_rb_idx + index_delta) and 3] + delta; if s^.distance_code <= 0 then s^.distance_code := $7FFFFFFF; end; end;
function SafeReadBits(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t): BROTLI_BOOL; begin if n_bits <> 0 then Result := BrotliSafeReadBits(br, n_bits, val) else begin val := 0; Result := BROTLI_TRUE; end; end;
function SafeReadBits32(br: PBrotliBitReader; n_bits: brotli_reg_t; out val: brotli_reg_t): BROTLI_BOOL; begin if n_bits <> 0 then Result := BrotliSafeReadBits32(br, n_bits, val) else begin val := 0; Result := BROTLI_TRUE; end; end;
procedure CalculateDistanceLut(s: PBrotliDecoderState);
var b: PBrotliMetablockBodyArena; npostfix, ndirect, alphabet_size_limit, postfix, j, bits, half, i, base: brotli_reg_t;
begin b := @s^.arena.body; npostfix := s^.distance_postfix_bits; ndirect := s^.num_direct_distance_codes; alphabet_size_limit := s^.distance_hgroup.alphabet_size_limit; postfix := brotli_reg_t(1) shl npostfix; bits := 1; half := 0; i := BROTLI_NUM_DISTANCE_SHORT_CODES; j := 0; while j < ndirect do begin b^.dist_extra_bits[i] := 0; b^.dist_offset[i] := j + 1; Inc(i); Inc(j); end; while i < alphabet_size_limit do begin base := ndirect + ((((2 + half) shl bits) - 4) shl npostfix) + 1; j := 0; while j < postfix do begin b^.dist_extra_bits[i] := uint8_t(bits); b^.dist_offset[i] := base + j; Inc(i); Inc(j); end; Inc(bits, half); half := half xor 1; end; end;
function ReadDistanceInternal(safe: LongInt; s: PBrotliDecoderState; br: PBrotliBitReader): BROTLI_BOOL;
var b: PBrotliMetablockBodyArena; code, bits: brotli_reg_t; memento: TBrotliBitReaderState; distance_tree: PHuffmanCode;
begin b := @s^.arena.body; distance_tree := s^.distance_hgroup.htrees[s^.dist_htree_index]; if safe = 0 then code := ReadSymbol(distance_tree, br) else begin BrotliBitReaderSaveState(br, @memento); if SafeReadSymbol(distance_tree, br, code) = BROTLI_FALSE then Exit(BROTLI_FALSE); end; Dec(s^.block_length[2]); s^.distance_context := 0; if (code and (not brotli_reg_t($F))) = 0 then begin s^.distance_code := LongInt(code); TakeDistanceFromRingBuffer(s); Exit(BROTLI_TRUE); end; if safe = 0 then bits := BrotliReadBits32(br, b^.dist_extra_bits[code]) else if SafeReadBits32(br, b^.dist_extra_bits[code], bits) = BROTLI_FALSE then begin Inc(s^.block_length[2]); BrotliBitReaderRestoreState(br, @memento); Exit(BROTLI_FALSE); end; s^.distance_code := LongInt(b^.dist_offset[code] + (bits shl s^.distance_postfix_bits)); Result := BROTLI_TRUE; end;
procedure ReadDistance(s: PBrotliDecoderState; br: PBrotliBitReader); begin ReadDistanceInternal(0, s, br); end;
function SafeReadDistance(s: PBrotliDecoderState; br: PBrotliBitReader): BROTLI_BOOL; begin Result := ReadDistanceInternal(1, s, br); end;
function ReadCommandInternal(safe: LongInt; s: PBrotliDecoderState; br: PBrotliBitReader; insert_length: PInt): BROTLI_BOOL;
var cmd_code, insert_len_extra, copy_length: brotli_reg_t; v: TCmdLutElement; memento: TBrotliBitReaderState;
begin insert_len_extra := 0; if safe = 0 then cmd_code := ReadSymbol(s^.htree_command, br) else begin BrotliBitReaderSaveState(br, @memento); if SafeReadSymbol(s^.htree_command, br, cmd_code) = BROTLI_FALSE then Exit(BROTLI_FALSE); end; v := kCmdLut[cmd_code]; s^.distance_code := v.distance_code; s^.distance_context := v.context; s^.dist_htree_index := s^.dist_context_map_slice[s^.distance_context]; insert_length^ := v.insert_len_offset; if safe = 0 then begin if v.insert_len_extra_bits <> 0 then insert_len_extra := BrotliReadBits24(br, v.insert_len_extra_bits); copy_length := BrotliReadBits24(br, v.copy_len_extra_bits); end else begin if (SafeReadBits(br, v.insert_len_extra_bits, insert_len_extra) = BROTLI_FALSE) or (SafeReadBits(br, v.copy_len_extra_bits, copy_length) = BROTLI_FALSE) then begin BrotliBitReaderRestoreState(br, @memento); Exit(BROTLI_FALSE); end; end; s^.copy_length := LongInt(copy_length) + v.copy_len_offset; Dec(s^.block_length[1]); Inc(insert_length^, LongInt(insert_len_extra)); Result := BROTLI_TRUE; end;
procedure ReadCommand(s: PBrotliDecoderState; br: PBrotliBitReader; insert_length: PInt); begin ReadCommandInternal(0, s, br, insert_length); end;
function SafeReadCommand(s: PBrotliDecoderState; br: PBrotliBitReader; insert_length: PInt): BROTLI_BOOL; begin Result := ReadCommandInternal(1, s, br, insert_length); end;
function CheckInputAmount(safe: LongInt; br: PBrotliBitReader): BROTLI_BOOL; begin if safe <> 0 then Result := BROTLI_TRUE else Result := BrotliCheckInputAmount(br); end;



end.
