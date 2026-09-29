{$mode delphi}
unit jxl_ans;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// JPEG XL hybrid entropy decoder — correct implementation based on libjxl 0.11.2
//
// Per-block decoding (TANSDecoder.Init → reads from bitstream):
//   1. LZ77 bundle allDefault (1 bit; 0 = disabled, skip body)
//   2. If num_contexts > 1: read context map (simple or complex)
//   3. use_prefix_code (1 bit)
//   4. If ANS: log_alpha_size = ReadBits(2) + 5   (5..8)
//   5. One HybridUintConfig per histogram
//   6. One histogram per cluster (ANS alias table or prefix Huffman)
//   7. If ANS: 32-bit initial state
//
// TANSDecoder.Decode(ctx, br):
//   context_map[ctx] → histogram index → decode symbol → HybridUint extension

interface

uses SysUtils, Math, jxl_types, jxl_bits;

const
  ANS_LOG_TAB_SIZE = 12;
  ANS_TAB_SIZE     = 1 shl ANS_LOG_TAB_SIZE;  // 4096
  ANS_TAB_MASK     = ANS_TAB_SIZE - 1;
  ANS_SIGNATURE    = $13;
  PREFIX_MAX_BITS  = 15;
  HUFF_FAST_BITS   = 8;
  HUFF_FAST_SIZE   = 256;  // 1 shl HUFF_FAST_BITS

type
  // Alias table entry — matches libjxl AliasTable::Entry exactly (8 bytes, packed)
  // Layout: [Cutoff:u8][RightValue:u8][Freq0:u16][Offsets1:u16][Freq1XorFreq0:u16]
  TAliasEntry = packed record
    Cutoff:        Byte;   // if pos < Cutoff → symbol = table_index i
    RightValue:    Byte;   // if pos >= Cutoff → symbol = RightValue
    Freq0:         Word;   // frequency of symbol i
    Offsets1:      Word;   // pos-offset for RightValue (offsets1 + pos = full offset)
    Freq1XorFreq0: Word;   // Freq1 XOR Freq0 (branchless recovery of Freq1)
  end;

  // HybridUint config — extends small symbol tokens to larger integers
  THybridUintConfig = record
    SplitExponent: Integer;
    MsbInToken:    Integer;
    LsbInToken:    Integer;
    SplitToken:    Cardinal;  // = 1 shl SplitExponent
  end;

  // Two-level Huffman table entry (fast path + overflow)
  THuffEntry = packed record
    Value: Word;  // symbol (fast) or overflow table index (slow root)
    Bits:  Byte;  // bits consumed (fast) or kHuffFastBits+extra (slow root)
    Pad:   Byte;
  end;

  // One histogram (= one cluster): either ANS alias table or prefix Huffman
  THistogram = record
    IsPrefix:         Boolean;
    // ANS fields
    LogAlphaSize:     Integer;   // 5..8
    LogEntrySize:     Integer;   // ANS_LOG_TAB_SIZE - LogAlphaSize
    EntryMask:        Cardinal;  // (1 << LogEntrySize) - 1
    Alias:            array of TAliasEntry;  // length = 1 << LogAlphaSize
    DegenerateSymbol: Integer;   // >=0 when only one distinct symbol
    // Prefix code fields
    HuffFast:         array[0..HUFF_FAST_SIZE-1] of THuffEntry;
    HuffSlow:         array of THuffEntry;
    HuffMaxBits:      Integer;
    // canonical code, for codes longer than HUFF_FAST_BITS: the number of
    // codes of each length and the symbols sorted by (length, symbol)
    HuffCount:        array[0..PREFIX_MAX_BITS] of Word;
    HuffSorted:       array of Word;
    // HybridUint config (shared between ANS and prefix paths)
    UintCfg:          THybridUintConfig;
  end;

  TANSDecoder = class
  private
    FHistograms:     array of THistogram;
    FContextMap:     array of Byte;
    FNumHistograms:  Integer;
    FNumContexts:    Integer;
    FANSState:       Cardinal;
    FUsePrefixCode:  Boolean;
    FLogAlphaSize:   Integer;  // shared across all ANS histograms in this block

    // LZ77 state (hybrid LZ77 + ANS, dec_ans.h)
    FLZ77Enabled:    Boolean;
    FLZ77MinSymbol:  Cardinal;   // = threshold
    FLZ77MinLength:  Cardinal;
    FLZ77Ctx:        Integer;    // distance histogram (clustered) index
    FLZ77LenCfg:     THybridUintConfig;
    FNumToCopy:      Cardinal;
    FCopyPos:        Cardinal;
    FNumDecoded:     Cardinal;
    FWindow:         array of Cardinal;
    FDistMultiplier: Cardinal;
    FNumSpecialDist: Integer;
    FSpecialDist:    array[0..119] of Integer;

    // Helpers
    function  DecodeSymbol(hi: Integer; br: TBitReader): Cardinal;
    function  DVarLenU8(br: TBitReader): Integer;
    function  DVarLenU16(br: TBitReader): Integer;
    procedure ReadContextMapData(br: TBitReader; nCtx: Integer; out nHist: Integer);
    procedure ReadUintConfig(out cfg: THybridUintConfig; logAlpha: Integer; br: TBitReader);
    procedure ReadHistogram(hi: Integer; br: TBitReader);
    procedure BuildAlias(hi: Integer; const counts: array of Integer; n: Integer);
    procedure ReadHuffmanTree(hi: Integer; alphabetSize: Integer; br: TBitReader);
    procedure BuildHuffFromLengths(var h: THistogram; const lens: array of Integer; n: Integer);
    function  DecodeANS(hi: Integer; br: TBitReader): Cardinal;
    function  DecodeHuff(hi: Integer; br: TBitReader): Cardinal;
    function  ReadHybridUint(token: Cardinal; const cfg: THybridUintConfig;
                              br: TBitReader): Cardinal;
    procedure IMTFTransform(p: PByte; n: Integer);
  public
    constructor Create;
    destructor  Destroy; override;

    // Read the full entropy header and prepare for decoding.
    // distMultiplier enables LZ77 special (2D) distances; 0 disables them.
    procedure Init(br: TBitReader; nContexts: Integer; distMultiplier: Cardinal = 0);

    // Split form: InitCode reads the shared "code" (histograms/context map/
    // lz77/configs) once; BeginReader starts a fresh per-group ANS reader over
    // that code. Used for the modular global tree shared across groups.
    procedure InitCode(br: TBitReader; nContexts: Integer);
    procedure BeginReader(br: TBitReader; distMultiplier: Cardinal);

    // Standalone context-map decode (dec_context_map.cc DecodeContextMap),
    // used by the VarDCT block context map. Returns nCtx entries.
    function DecodeStandaloneContextMap(br: TBitReader; nCtx: Integer;
                                        out numHist: Integer): TBytes;

    // Pads the context map with zeros to n entries (libjxl resizes the AC
    // context maps by kZeroDensityContextLimit - kZeroDensityContextCount).
    procedure ExtendContextMap(n: Integer);

    // Decode one integer from the given context
    function  Decode(ctx: Integer; br: TBitReader): Cardinal;

    // After all symbols decoded, ANS state should equal ANS_SIGNATURE<<16
    function  CheckFinalState: Boolean;

    property NumContexts: Integer read FNumContexts;
  end;

implementation

const
  LZ77_WINDOW_SIZE = 1 shl 20;
  LZ77_WINDOW_MASK = LZ77_WINDOW_SIZE - 1;
  NUM_SPECIAL_DISTANCES = 120;

  // Table of special distance codes (dx, dy) from WebP lossless. dec_ans.h.
  kSpecialDistDX: array[0..NUM_SPECIAL_DISTANCES-1] of Integer = (
     0, 1, 1,-1, 0, 2, 1,-1, 2,-2, 2,-2, 0, 3, 1,-1,
     3,-3, 2,-2, 3,-3, 0, 4, 1,-1, 4,-4, 3,-3, 2,-2,
     4,-4, 0, 3,-3, 4,-4, 5, 1,-1, 5,-5, 2,-2, 5,-5,
     4,-4, 3,-3, 5,-5, 0, 6, 1,-1, 6,-6, 2,-2, 6,-6,
     4,-4, 5,-5, 3,-3, 6,-6, 0, 7, 1,-1, 5,-5, 7,-7,
     4,-4, 6,-6, 2,-2, 7,-7, 3,-3, 7,-7, 5,-5, 6,-6,
     8, 4,-4, 7,-7, 8, 8, 6,-6, 8, 5,-5, 7,-7, 8, 6,
    -6, 7,-7, 8, 7,-7, 8, 8);
  kSpecialDistDY: array[0..NUM_SPECIAL_DISTANCES-1] of Integer = (
     1, 0, 1, 1, 2, 0, 2, 2, 1, 1, 2, 2, 3, 0, 3, 3,
     1, 1, 3, 3, 2, 2, 4, 0, 4, 4, 1, 1, 3, 3, 4, 4,
     2, 2, 5, 4, 4, 3, 3, 0, 5, 5, 1, 1, 5, 5, 2, 2,
     4, 4, 5, 5, 3, 3, 6, 0, 6, 6, 1, 1, 6, 6, 2, 2,
     5, 5, 4, 4, 6, 6, 3, 3, 7, 0, 7, 7, 5, 5, 1, 1,
     6, 6, 4, 4, 7, 7, 2, 2, 7, 7, 3, 3, 6, 6, 5, 5,
     0, 7, 7, 4, 4, 1, 2, 6, 6, 3, 7, 7, 5, 5, 4, 7,
     7, 6, 6, 5, 7, 7, 6, 7);

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

function FloorLog2(n: Cardinal): Integer; inline;
var v: Cardinal;
begin
  Result := 0;
  v := n;
  while v > 1 do begin Inc(Result); v := v shr 1; end;
end;

function CeilLog2NonZero(n: Integer): Integer; inline;
begin
  if n <= 1 then begin Result := 0; Exit; end;
  Result := FloorLog2(n - 1) + 1;
end;

// From libjxl ans_common.h GetPopulationCountPrecision
function GetPCPrec(logcount, shift: Integer): Integer; inline;
var r: Integer;
begin
  r := logcount;
  if shift - Integer((ANS_LOG_TAB_SIZE - logcount) shr 1) < r then
    r := shift - Integer((ANS_LOG_TAB_SIZE - logcount) shr 1);
  if r < 0 then r := 0;
  Result := r;
end;

// ---------------------------------------------------------------------------
// DecodeVarLenUint8 / DecodeVarLenUint16 — from libjxl dec_ans.cc
// ---------------------------------------------------------------------------
function TANSDecoder.DVarLenU8(br: TBitReader): Integer;
var nbits: Integer;
begin
  if br.ReadBit then begin
    nbits := br.ReadBits(3);
    if nbits = 0 then Result := 1
    else Result := Integer(br.ReadBits(nbits)) + (1 shl nbits);
  end else
    Result := 0;
end;

function TANSDecoder.DVarLenU16(br: TBitReader): Integer;
var nbits: Integer;
begin
  if br.ReadBit then begin
    nbits := br.ReadBits(4);
    if nbits = 0 then Result := 1
    else Result := Integer(br.ReadBits(nbits)) + (1 shl nbits);
  end else
    Result := 0;
end;

// ---------------------------------------------------------------------------
// ReadContextMapData — libjxl dec_context_map.cc DecodeContextMap
// ---------------------------------------------------------------------------
procedure TANSDecoder.ReadContextMapData(br: TBitReader; nCtx: Integer;
                                          out nHist: Integer);
var
  i, maxVal: Integer;
  isSimple: Boolean;
  bitsPerEntry: Integer;
  useMtf: Boolean;
  sub: TANSDecoder;
  sym: Cardinal;
begin
  SetLength(FContextMap, nCtx);
  FillChar(FContextMap[0], nCtx, 0);
  nHist := 1;

  isSimple := br.ReadBit;
  if isSimple then begin
    // Simple case: all entries in 0..2 bits
    bitsPerEntry := br.ReadBits(2);
    if bitsPerEntry = 0 then begin
      // All zero → 1 histogram
      for i := 0 to nCtx - 1 do FContextMap[i] := 0;
    end else begin
      maxVal := 0;
      for i := 0 to nCtx - 1 do begin
        FContextMap[i] := Byte(br.ReadBits(bitsPerEntry));
        if FContextMap[i] > maxVal then maxVal := FContextMap[i];
      end;
      nHist := maxVal + 1;
    end;
  end else begin
    // Complex case: context map values encoded with a sub-decoder
    useMtf := br.ReadBit;
    // Recursive: decode context map entries using their own entropy decoder
    sub := TANSDecoder.Create;
    try
      sub.Init(br, 1);
      maxVal := 0;
      for i := 0 to nCtx - 1 do begin
        sym := sub.Decode(0, br);
        if sym > 255 then sym := 255;
        FContextMap[i] := Byte(sym);
        if Integer(sym) > maxVal then maxVal := sym;
      end;
      if not sub.CheckFinalState then
        raise EJxlError.Create('ANS: context map sub-decoder final state error');
    finally
      sub.Free;
    end;
    if useMtf then
      IMTFTransform(@FContextMap[0], nCtx);
    // VerifyContextMap: the count follows the final (post-MTF) values
    maxVal := 0;
    for i := 0 to nCtx - 1 do
      if FContextMap[i] > maxVal then maxVal := FContextMap[i];
    nHist := maxVal + 1;
  end;
end;

// Inverse Move-To-Front transform
procedure TANSDecoder.IMTFTransform(p: PByte; n: Integer);
var
  mtf: array[0..255] of Byte;
  i, j, v, sym: Integer;
begin
  for i := 0 to 255 do mtf[i] := i;
  for i := 0 to n - 1 do begin
    v := p[i];
    sym := mtf[v];
    p[i] := sym;
    // Move sym to front
    j := v;
    while j > 0 do begin
      mtf[j] := mtf[j - 1];
      Dec(j);
    end;
    mtf[0] := sym;
  end;
end;

// ---------------------------------------------------------------------------
// ReadUintConfig — libjxl dec_ans.cc DecodeUintConfig
// ---------------------------------------------------------------------------
procedure TANSDecoder.ReadUintConfig(out cfg: THybridUintConfig;
                                      logAlpha: Integer; br: TBitReader);
var
  se, nbits, msb, lsb: Integer;
begin
  // split_exponent: CeilLog2NonZero(log_alpha_size + 1) bits
  se := br.ReadBits(CeilLog2NonZero(logAlpha + 1));
  msb := 0; lsb := 0;
  if se <> logAlpha then begin
    // msb_in_token: CeilLog2NonZero(se + 1) bits
    nbits := CeilLog2NonZero(se + 1);
    msb := br.ReadBits(nbits);
    if msb > se then msb := se;
    // lsb_in_token: CeilLog2NonZero(se - msb + 1) bits
    nbits := CeilLog2NonZero(se - msb + 1);
    lsb := br.ReadBits(nbits);
  end;
  cfg.SplitExponent := se;
  cfg.MsbInToken    := msb;
  cfg.LsbInToken    := lsb;
  if se > 0 then cfg.SplitToken := Cardinal(1) shl se
  else            cfg.SplitToken := 1;
end;

// ---------------------------------------------------------------------------
// Hardcoded 7-bit Huffman table for ANS histogram log-counts
// Each entry: [nbits_to_consume, log_count_value]  (libjxl dec_ans.cc)
// ---------------------------------------------------------------------------
const HUFF_LOG: array[0..127, 0..1] of Byte = (
  (3,10),(7,12),(3,7),(4,3),(3,6),(3,8),(3,9),(4,5),
  (3,10),(4,4),(3,7),(4,1),(3,6),(3,8),(3,9),(4,2),
  (3,10),(5,0),(3,7),(4,3),(3,6),(3,8),(3,9),(4,5),
  (3,10),(4,4),(3,7),(4,1),(3,6),(3,8),(3,9),(4,2),
  (3,10),(6,11),(3,7),(4,3),(3,6),(3,8),(3,9),(4,5),
  (3,10),(4,4),(3,7),(4,1),(3,6),(3,8),(3,9),(4,2),
  (3,10),(5,0),(3,7),(4,3),(3,6),(3,8),(3,9),(4,5),
  (3,10),(4,4),(3,7),(4,1),(3,6),(3,8),(3,9),(4,2),
  (3,10),(7,13),(3,7),(4,3),(3,6),(3,8),(3,9),(4,5),
  (3,10),(4,4),(3,7),(4,1),(3,6),(3,8),(3,9),(4,2),
  (3,10),(5,0),(3,7),(4,3),(3,6),(3,8),(3,9),(4,5),
  (3,10),(4,4),(3,7),(4,1),(3,6),(3,8),(3,9),(4,2),
  (3,10),(6,11),(3,7),(4,3),(3,6),(3,8),(3,9),(4,5),
  (3,10),(4,4),(3,7),(4,1),(3,6),(3,8),(3,9),(4,2),
  (3,10),(5,0),(3,7),(4,3),(3,6),(3,8),(3,9),(4,5),
  (3,10),(4,4),(3,7),(4,1),(3,6),(3,8),(3,9),(4,2)
);

// ---------------------------------------------------------------------------
// ReadHistogram — libjxl dec_ans.cc ReadHistogram (for ANS, precision=12)
// ---------------------------------------------------------------------------
procedure TANSDecoder.ReadHistogram(hi: Integer; br: TBitReader);
const
  PRECISION = ANS_LOG_TAB_SIZE;  // 12
  RANGE      = ANS_TAB_SIZE;     // 4096
var
  simple_code: Boolean;
  num_sym: Integer;
  syms:  array[0..1] of Integer;
  is_flat: Boolean;
  alpha_size, flat_each, flat_rem: Integer;
  upper_bound_log, log_level: Integer;
  shift, length: Integer;
  logcounts: array of Integer;
  same:      array of Integer;
  omit_log, omit_pos: Integer;
  i, idx, rle_length: Integer;
  numsame, prev, total_count, bitcount, code: Integer;
  counts: array of Integer;
  n, cnt_i: Integer;
begin
  simple_code := br.ReadBit;
  if simple_code then begin
    // Simple case: 1 or 2 symbols
    num_sym := Integer(br.ReadBit) + 1;
    syms[0] := DVarLenU8(br);
    syms[1] := 0;
    if num_sym = 2 then syms[1] := DVarLenU8(br);

    n := syms[0] + 1;
    if (num_sym = 2) and (syms[1] + 1 > n) then n := syms[1] + 1;
    SetLength(counts, n);
    FillChar(counts[0], n * SizeOf(Integer), 0);

    if num_sym = 1 then
      counts[syms[0]] := RANGE
    else begin
      counts[syms[0]] := br.ReadBits(PRECISION);
      counts[syms[1]] := RANGE - counts[syms[0]];
    end;

    BuildAlias(hi, counts, n);
    Exit;
  end;

  is_flat := br.ReadBit;
  if is_flat then begin
    // Flat distribution: all symbols equally likely
    alpha_size := DVarLenU8(br) + 1;
    SetLength(counts, alpha_size);
    flat_each := RANGE div alpha_size;
    flat_rem  := RANGE - flat_each * alpha_size;
    for i := 0 to alpha_size - 1 do begin
      if i < flat_rem then counts[i] := flat_each + 1
      else counts[i] := flat_each;
    end;
    BuildAlias(hi, counts, alpha_size);
    Exit;
  end;

  // Complex case: shift + alphabet size + log-counts via Huffman
  // Decode shift: FloorLog2(ANS_LOG_TAB_SIZE + 1) = FloorLog2(13) = 3
  upper_bound_log := 3;
  log_level := 0;
  while log_level < upper_bound_log do begin
    if not br.ReadBit then Break;
    Inc(log_level);
  end;
  if log_level = 0 then shift := 0
  else shift := Integer(br.ReadBits(log_level) or (Cardinal(1) shl log_level)) - 1;

  // Alphabet size
  length := DVarLenU8(br) + 3;
  SetLength(counts, length);
  FillChar(counts[0], length * SizeOf(Integer), 0);
  SetLength(logcounts, length);
  SetLength(same, length);
  FillChar(logcounts[0], length * SizeOf(Integer), 0);
  FillChar(same[0], length * SizeOf(Integer), 0);

  omit_log := -1;
  omit_pos := -1;
  i := 0;
  while i < length do begin
    idx := br.PeekBits(7);
    br.SkipBits(HUFF_LOG[idx][0]);
    logcounts[i] := HUFF_LOG[idx][1];
    // RLE marker = ANS_LOG_TAB_SIZE + 1 = 13
    if logcounts[i] = PRECISION + 1 then begin
      rle_length := DVarLenU8(br);
      same[i] := rle_length + 5;
      Inc(i, rle_length + 4);  // skip rle_length+3 entries, then continue from i+rle_length+4
      Continue;
    end;
    if logcounts[i] > omit_log then begin
      omit_log := logcounts[i];
      omit_pos := i;
    end;
    Inc(i);
  end;

  if omit_pos < 0 then begin
    // Degenerate: treat as single-symbol flat
    SetLength(counts, 1);
    counts[0] := RANGE;
    BuildAlias(hi, counts, 1);
    Exit;
  end;

  // Expand log-counts to actual counts
  total_count := 0;
  numsame := 0;
  prev := 0;
  for i := 0 to length - 1 do begin
    if same[i] > 0 then begin
      numsame := same[i] - 1;
      if i > 0 then prev := counts[i - 1] else prev := 0;
    end;
    if numsame > 0 then begin
      counts[i] := prev;
      Dec(numsame);
    end else begin
      if i = omit_pos then Continue;
      code := logcounts[i];
      case code of
        0: counts[i] := 0;
        1: counts[i] := 1;
      else begin
        bitcount := GetPCPrec(code - 1, shift);
        cnt_i := (1 shl (code - 1));
        if bitcount > 0 then
          cnt_i := cnt_i + Integer(br.ReadBits(bitcount) shl (code - 1 - bitcount));
        counts[i] := cnt_i;
      end;
      end;
    end;
    Inc(total_count, counts[i]);
  end;
  counts[omit_pos] := RANGE - total_count;
  if counts[omit_pos] <= 0 then
    raise EJxlError.Create('ANS: invalid histogram — omit_pos count <= 0');

  BuildAlias(hi, counts, length);
end;

// ---------------------------------------------------------------------------
// BuildAlias — libjxl ans_common.cc InitAliasTable
// ---------------------------------------------------------------------------
procedure TANSDecoder.BuildAlias(hi: Integer; const counts: array of Integer; n: Integer);
var
  tabSize, entrySize, i, sym: Integer;
  distribution: array of Integer;
  cutoffs:   array of Cardinal;
  underfull, overfull: array of Integer;
  uf_count, of_count: Integer;
  overfull_i, underfull_i: Integer;
  underfull_by: Integer;
  freq0, freq1, i1: Integer;
  logAlpha: Integer;
  a: ^TAliasEntry;
  singleSym: Integer;
  sum: Integer;
begin
  logAlpha := FHistograms[hi].LogAlphaSize;
  tabSize  := 1 shl logAlpha;
  entrySize := ANS_TAB_SIZE shr logAlpha;  // = 1 shl LogEntrySize

  SetLength(FHistograms[hi].Alias, tabSize);

  // Copy distribution (trimming trailing zeros)
  SetLength(distribution, n);
  for i := 0 to n - 1 do distribution[i] := counts[i];
  while (Length(distribution) > 0) and (distribution[High(distribution)] = 0) do
    SetLength(distribution, Length(distribution) - 1);
  if Length(distribution) = 0 then begin
    SetLength(distribution, 1);
    distribution[0] := ANS_TAB_SIZE;
  end;

  // Check for single-symbol degenerate distribution
  singleSym := -1;
  sum := 0;
  for sym := 0 to High(distribution) do begin
    Inc(sum, distribution[sym]);
    if distribution[sym] = ANS_TAB_SIZE then begin
      if singleSym = -1 then singleSym := sym
      else singleSym := -1;  // multiple full-range symbols → not degenerate
    end;
  end;
  FHistograms[hi].DegenerateSymbol := singleSym;

  n := Length(distribution);

  // Single-symbol fast path
  if singleSym >= 0 then begin
    for i := 0 to tabSize - 1 do begin
      a := @FHistograms[hi].Alias[i];
      a^.RightValue    := Byte(singleSym);
      a^.Cutoff        := 0;
      a^.Offsets1      := entrySize * i;
      a^.Freq0         := 0;
      a^.Freq1XorFreq0 := ANS_TAB_SIZE;
    end;
    Exit;
  end;

  // General alias construction (Vose's algorithm, matching libjxl)
  SetLength(cutoffs,   tabSize);
  SetLength(underfull, tabSize);
  SetLength(overfull,  tabSize);
  uf_count := 0; of_count := 0;

  for i := 0 to tabSize - 1 do
    if i < n then cutoffs[i] := distribution[i]
    else cutoffs[i] := 0;

  for i := 0 to tabSize - 1 do begin
    if Integer(cutoffs[i]) > entrySize then begin
      overfull[of_count] := i; Inc(of_count);
    end else if Integer(cutoffs[i]) < entrySize then begin
      underfull[uf_count] := i; Inc(uf_count);
    end;
  end;

  // Initialize right_value to self (will be overridden for underfull entries)
  for i := 0 to tabSize - 1 do begin
    FHistograms[hi].Alias[i].RightValue := Byte(i);
    FHistograms[hi].Alias[i].Offsets1   := 0;
  end;

  while of_count > 0 do begin
    Dec(of_count);
    overfull_i := overfull[of_count];
    Dec(uf_count);
    underfull_i := underfull[uf_count];

    underfull_by := entrySize - Integer(cutoffs[underfull_i]);
    Dec(cutoffs[overfull_i], underfull_by);

    FHistograms[hi].Alias[underfull_i].RightValue := Byte(overfull_i);
    FHistograms[hi].Alias[underfull_i].Offsets1   := cutoffs[overfull_i];

    if Integer(cutoffs[overfull_i]) < entrySize then begin
      underfull[uf_count] := overfull_i; Inc(uf_count);
    end else if Integer(cutoffs[overfull_i]) > entrySize then begin
      overfull[of_count] := overfull_i; Inc(of_count);
    end;
  end;

  // Finalize entries
  for i := 0 to tabSize - 1 do begin
    a := @FHistograms[hi].Alias[i];
    if Integer(cutoffs[i]) = entrySize then begin
      a^.RightValue := Byte(i);
      a^.Offsets1   := 0;
      a^.Cutoff     := 0;
    end else begin
      // offsets1 was set during reassign; subtract cutoff
      a^.Offsets1 := a^.Offsets1 - cutoffs[i];
      a^.Cutoff   := Byte(cutoffs[i]);
    end;

    freq0 := 0;
    if i < n then freq0 := distribution[i];

    i1 := a^.RightValue;
    freq1 := 0;
    if i1 < n then freq1 := distribution[i1];

    a^.Freq0         := Word(freq0);
    a^.Freq1XorFreq0 := Word(freq1 xor freq0);
  end;
end;

// ---------------------------------------------------------------------------
// DecodeANS — libjxl dec_ans.h ReadSymbolANSWithoutRefill
// ---------------------------------------------------------------------------
function TANSDecoder.DecodeANS(hi: Integer; br: TBitReader): Cardinal;
var
  res, i, pos: Cardinal;
  greater: Boolean;
  a: TAliasEntry;
  sym, freq, offset: Cardinal;
  entryMask: Cardinal;
begin
  entryMask := FHistograms[hi].EntryMask;

  res := FANSState and ANS_TAB_MASK;
  i   := res shr FHistograms[hi].LogEntrySize;
  pos := res and entryMask;

  a       := FHistograms[hi].Alias[i];
  greater := pos >= a.Cutoff;
  if greater then sym := a.RightValue else sym := i;
  if greater then offset := a.Offsets1 + pos
  else offset := pos;
  if greater then freq := a.Freq0 xor a.Freq1XorFreq0
  else freq := a.Freq0;

  FANSState := freq * (FANSState shr ANS_LOG_TAB_SIZE) + offset;

  // Renormalise: if state < 2^16, read 16 more bits
  if FANSState < (1 shl 16) then
    FANSState := (FANSState shl 16) or br.ReadBits(16);

  Result := sym;
end;

// ---------------------------------------------------------------------------
// Huffman tree reading and decode
// ---------------------------------------------------------------------------
// Canonical prefix code from code lengths (dec_huffman.cc BuildHuffmanTable).
// Codes are read LSB-first with the code's MSB first, as in Brotli. A code
// with a single used symbol takes no bits.
procedure TANSDecoder.BuildHuffFromLengths(var h: THistogram;
                                            const lens: array of Integer; n: Integer);
var
  i, sym, code, len, maxBits, used, lastSym: Integer;
  bl_count: array[0..PREFIX_MAX_BITS] of Integer;
  next_code: array[0..PREFIX_MAX_BITS] of Integer;
  offs: array[0..PREFIX_MAX_BITS + 1] of Integer;
  rev_code, j: Integer;
begin
  for i := 0 to HUFF_FAST_SIZE - 1 do begin
    h.HuffFast[i].Bits  := 0;
    h.HuffFast[i].Value := 0;
  end;
  SetLength(h.HuffSlow, 0);
  FillChar(h.HuffCount, SizeOf(h.HuffCount), 0);
  SetLength(h.HuffSorted, 0);

  maxBits := 0; used := 0; lastSym := 0;
  FillChar(bl_count, SizeOf(bl_count), 0);
  for i := 0 to n - 1 do
    if (lens[i] > 0) and (lens[i] <= PREFIX_MAX_BITS) then begin
      Inc(bl_count[lens[i]]);
      if lens[i] > maxBits then maxBits := lens[i];
      Inc(used); lastSym := i;
    end;
  h.HuffMaxBits := maxBits;
  if used <= 1 then begin
    h.DegenerateSymbol := lastSym;   // 0 bits (also the empty code)
    Exit;
  end;
  h.DegenerateSymbol := -1;

  // symbols sorted by (length, symbol)
  for i := 1 to PREFIX_MAX_BITS do h.HuffCount[i] := bl_count[i];
  SetLength(h.HuffSorted, used);
  offs[1] := 0;
  for i := 1 to PREFIX_MAX_BITS do offs[i + 1] := offs[i] + bl_count[i];
  for sym := 0 to n - 1 do
    if (lens[sym] > 0) and (lens[sym] <= PREFIX_MAX_BITS) then begin
      h.HuffSorted[offs[lens[sym]]] := Word(sym);
      Inc(offs[lens[sym]]);
    end;

  // starting codes; the fast table for codes of up to HUFF_FAST_BITS bits
  code := 0; bl_count[0] := 0;
  for i := 1 to maxBits do begin
    code := (code + bl_count[i-1]) shl 1;
    next_code[i] := code;
  end;
  for sym := 0 to n - 1 do begin
    len := lens[sym];
    if (len <= 0) or (len > PREFIX_MAX_BITS) then Continue;
    code := next_code[len];
    Inc(next_code[len]);
    if len > HUFF_FAST_BITS then Continue;
    rev_code := 0;
    for j := 0 to len - 1 do begin
      rev_code := (rev_code shl 1) or (code and 1);
      code := code shr 1;
    end;
    j := rev_code;
    while j < HUFF_FAST_SIZE do begin
      h.HuffFast[j].Bits  := Byte(len);
      h.HuffFast[j].Value := Word(sym);
      Inc(j, 1 shl len);
    end;
  end;
end;

// One symbol from a prefix code: the fast table, else bit by bit.
function HuffDecodeWith(const h: THistogram; br: TBitReader): Cardinal;
var
  e: THuffEntry;
  len, code, first, index, count: Integer;
begin
  if h.DegenerateSymbol >= 0 then begin
    Result := Cardinal(h.DegenerateSymbol);
    Exit;
  end;
  e := h.HuffFast[br.PeekBits(HUFF_FAST_BITS)];
  if e.Bits > 0 then begin
    br.SkipBits(e.Bits);
    Result := e.Value;
    Exit;
  end;
  code := 0; first := 0; index := 0;
  for len := 1 to PREFIX_MAX_BITS do begin
    code := code or Integer(br.ReadBits(1));
    count := h.HuffCount[len];
    if code - first < count then begin
      Result := h.HuffSorted[index + code - first];
      Exit;
    end;
    Inc(index, count);
    first := (first + count) shl 1;
    code := code shl 1;
  end;
  raise EJxlError.Create('ANS: invalid prefix code');
end;

// dec_huffman.cc HuffmanDecodingData::ReadFromBitStream (Brotli prefix code).
procedure TANSDecoder.ReadHuffmanTree(hi: Integer; alphabetSize: Integer; br: TBitReader);
const
  kCLCodes = 18;
  kCLOrder: array[0..17] of Byte =
    (1,2,3,4,0,5,17,6,16,7,8,9,10,11,12,13,14,15);
  // Static 4-bit prefix code for the code length code lengths
  kMetaHuffV: array[0..15] of Byte = (0,4,3,2, 0,4,3,1, 0,4,3,2, 0,4,3,5);
  kMetaHuffB: array[0..15] of Byte = (2,2,2,3, 2,2,2,4, 2,2,2,3, 2,2,2,4);
var
  simple_code_or_skip: Integer;
  i, j, sym, extra, space, num_codes: Integer;
  clLens: array[0..kCLCodes-1] of Integer;
  fullLens: array of Integer;
  repeat_code_len, prev_code_len, code_len: Integer;
  repeat_, old_repeat, repeat_delta: Integer;
  max_bits: Integer;
  num_symbols: Integer;
  symArr: array[0..3] of Integer;
  t: Integer;
  clH: THistogram;
begin
  FHistograms[hi].IsPrefix := True;
  SetLength(fullLens, alphabetSize);
  FillChar(fullLens[0], alphabetSize * SizeOf(Integer), 0);

  simple_code_or_skip := br.ReadBits(2);
  if simple_code_or_skip = 1 then begin
    // ReadSimpleCode: 1..4 symbols (5 = the 1,2,3,3 shape)
    if alphabetSize <= 1 then max_bits := 0
    else max_bits := FloorLog2(alphabetSize - 1) + 1;
    num_symbols := br.ReadBits(2) + 1;
    FillChar(symArr, SizeOf(symArr), 0);
    for i := 0 to num_symbols - 1 do begin
      sym := br.ReadBits(max_bits);
      if sym >= alphabetSize then
        raise EJxlError.Create('ANS: invalid simple prefix code');
      symArr[i] := sym;
    end;
    if (num_symbols = 4) and br.ReadBit then
      Inc(num_symbols);
    case num_symbols of
      1: fullLens[symArr[0]] := 1;   // single symbol: built as a 0-bit code
      2: begin
           fullLens[symArr[0]] := 1; fullLens[symArr[1]] := 1;
         end;
      3: begin
           fullLens[symArr[0]] := 1; fullLens[symArr[1]] := 2; fullLens[symArr[2]] := 2;
         end;
      4: for i := 0 to 3 do fullLens[symArr[i]] := 2;
      5: begin
           fullLens[symArr[0]] := 1; fullLens[symArr[1]] := 2;
           fullLens[symArr[2]] := 3; fullLens[symArr[3]] := 3;
         end;
    end;
    BuildHuffFromLengths(FHistograms[hi], fullLens, alphabetSize);
    Exit;
  end;

  // Complex code: the code length code lengths, in kCLOrder
  FillChar(clLens, SizeOf(clLens), 0);
  space := 32; num_codes := 0;
  i := simple_code_or_skip;
  while (i < kCLCodes) and (space > 0) do begin
    j := br.PeekBits(4);
    br.SkipBits(kMetaHuffB[j]);
    sym := kMetaHuffV[j];
    clLens[kCLOrder[i]] := sym;
    if sym <> 0 then begin
      Dec(space, 32 shr sym);
      Inc(num_codes);
    end;
    Inc(i);
  end;
  if (num_codes <> 1) and (space <> 0) then
    raise EJxlError.Create('ANS: invalid prefix code length code');
  BuildHuffFromLengths(clH, clLens, kCLCodes);

  // ReadHuffmanCodeLengths
  prev_code_len := 8;
  repeat_ := 0;
  repeat_code_len := 0;
  space := 32768;
  sym := 0;
  while (sym < alphabetSize) and (space > 0) do begin
    code_len := HuffDecodeWith(clH, br);
    if code_len < 16 then begin
      repeat_ := 0;
      fullLens[sym] := code_len;
      Inc(sym);
      if code_len <> 0 then begin
        prev_code_len := code_len;
        Dec(space, 32768 shr code_len);
      end;
    end else begin
      extra := code_len - 14;
      if code_len = 16 then t := prev_code_len else t := 0;
      if repeat_code_len <> t then begin
        repeat_ := 0; repeat_code_len := t;
      end;
      old_repeat := repeat_;
      if repeat_ > 0 then begin
        Dec(repeat_, 2);
        repeat_ := repeat_ shl extra;
      end;
      repeat_ := repeat_ + Integer(br.ReadBits(extra)) + 3;
      repeat_delta := repeat_ - old_repeat;
      if sym + repeat_delta > alphabetSize then
        raise EJxlError.Create('ANS: invalid prefix code lengths');
      for i := 0 to repeat_delta - 1 do begin
        fullLens[sym] := repeat_code_len;
        Inc(sym);
      end;
      if repeat_code_len <> 0 then
        Dec(space, repeat_delta shl (15 - repeat_code_len));
    end;
  end;
  if space <> 0 then
    raise EJxlError.Create('ANS: incomplete prefix code');
  BuildHuffFromLengths(FHistograms[hi], fullLens, alphabetSize);
end;

function TANSDecoder.DecodeHuff(hi: Integer; br: TBitReader): Cardinal;
begin
  Result := HuffDecodeWith(FHistograms[hi], br);
end;

// ---------------------------------------------------------------------------
// ReadHybridUint — libjxl dec_ans.h ReadHybridUintConfig
// ---------------------------------------------------------------------------
function TANSDecoder.ReadHybridUint(token: Cardinal;
                                     const cfg: THybridUintConfig;
                                     br: TBitReader): Cardinal;
var
  nbits, low, bits: Cardinal;
  res: Cardinal;
begin
  // NOTE: no special case for SplitExponent=0 — libjxl's general path applies
  // (token >= split_token still reads (token - split_token) extra bits).
  if token < cfg.SplitToken then begin
    Result := token; Exit;
  end;
  // Number of extra bits from stream
  nbits := Cardinal(cfg.SplitExponent - cfg.MsbInToken - cfg.LsbInToken)
         + ((token - cfg.SplitToken) shr (cfg.MsbInToken + cfg.LsbInToken));
  if nbits > 29 then begin Result := 0; Exit; end;  // malformed input guard (libjxl)
  // LSBs in token
  low   := token and (Cardinal(1 shl cfg.LsbInToken) - 1);
  token := token shr cfg.LsbInToken;
  // MSBs in token
  bits  := token and (Cardinal(1 shl cfg.MsbInToken) - 1);
  // Reconstruct (dec_ans.h ReadHybridUintConfig):
  //   ret = ((((1<<msb) | msb_bits) << nbits | stream_bits) << lsb) | low
  // The implicit leading 1 goes ABOVE the msb token bits; that prefix then
  // shifts above the freshly-read stream bits.
  res := (Cardinal(1) shl cfg.MsbInToken) or bits;
  res := (res shl nbits) or br.ReadBits(nbits);
  res := (res shl cfg.LsbInToken) or low;
  Result := res;
end;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
constructor TANSDecoder.Create;
begin
  inherited;
  FNumHistograms := 0;
  FNumContexts   := 0;
  FANSState      := Cardinal(ANS_SIGNATURE) shl 16;
  FUsePrefixCode := False;
  FLogAlphaSize  := ANS_LOG_TAB_SIZE;
end;

destructor TANSDecoder.Destroy;
var i: Integer;
begin
  for i := 0 to High(FHistograms) do begin
    SetLength(FHistograms[i].Alias, 0);
    SetLength(FHistograms[i].HuffSlow, 0);
  end;
  SetLength(FHistograms, 0);
  SetLength(FContextMap, 0);
  inherited;
end;

// ---------------------------------------------------------------------------
function TANSDecoder.DecodeStandaloneContextMap(br: TBitReader; nCtx: Integer;
                                                out numHist: Integer): TBytes;
var i: Integer;
begin
  Result := nil;
  ReadContextMapData(br, nCtx, numHist);
  SetLength(Result, nCtx);
  for i := 0 to nCtx - 1 do
    Result[i] := FContextMap[i];
end;

// ---------------------------------------------------------------------------
// InitCode — implements libjxl's DecodeHistograms (the shared "code": lz77
// params, context map, uint configs, and histograms). Does NOT read the
// per-reader 32-bit ANS state (see BeginReader).
// ---------------------------------------------------------------------------
procedure TANSDecoder.InitCode(br: TBitReader; nContexts: Integer);
var
  i, nHist, cmContexts: Integer;
  alphaSizes: array of Integer;
begin
  FNumContexts := nContexts;

  // 1. LZ77 params bundle (dec_ans.cc LZ77Params::VisitFields).
  //    NO AllDefault bit; starts directly with Bool(false, &enabled): bit==1 -> on.
  FLZ77Enabled := br.ReadBit;
  if FLZ77Enabled then begin
    FLZ77MinSymbol := br.ReadU32(224,0, 512,0, 4096,0, 8,15);
    FLZ77MinLength := br.ReadU32(3,0, 4,0, 5,2, 9,8);
    ReadUintConfig(FLZ77LenCfg, 8, br);
  end;

  // The context map covers nContexts (+1 for the LZ77 distance context).
  cmContexts := nContexts;
  if FLZ77Enabled then Inc(cmContexts);

  // 2. Context map (only if more than 1 context)
  nHist := 1;
  if cmContexts > 1 then
    ReadContextMapData(br, cmContexts, nHist)
  else begin
    SetLength(FContextMap, 1);
    FContextMap[0] := 0;
  end;

  // LZ77 distance context = histogram of the last (extra) context entry.
  if FLZ77Enabled then
    FLZ77Ctx := FContextMap[cmContexts - 1];

  FNumHistograms := nHist;
  SetLength(FHistograms, nHist);

  // 3. use_prefix_code
  FUsePrefixCode := br.ReadBit;

  // 4. log_alpha_size
  if FUsePrefixCode then
    FLogAlphaSize := PREFIX_MAX_BITS
  else
    FLogAlphaSize := Integer(br.ReadBits(2)) + 5;   // 5..8

  for i := 0 to nHist - 1 do begin
    FHistograms[i].IsPrefix    := FUsePrefixCode;
    FHistograms[i].LogAlphaSize := FLogAlphaSize;
    FHistograms[i].LogEntrySize := ANS_LOG_TAB_SIZE - FLogAlphaSize;
    FHistograms[i].EntryMask   := Cardinal((1 shl FHistograms[i].LogEntrySize) - 1);
    FHistograms[i].DegenerateSymbol := -1;
  end;

  // 5. uint configs (one per histogram)
  for i := 0 to nHist - 1 do
    ReadUintConfig(FHistograms[i].UintCfg, FLogAlphaSize, br);

  // 6. Histograms
  if FUsePrefixCode then begin
    SetLength(alphaSizes, nHist);
    for i := 0 to nHist - 1 do
      alphaSizes[i] := DVarLenU16(br) + 1;
    for i := 0 to nHist - 1 do
      if alphaSizes[i] > 1 then
        ReadHuffmanTree(i, alphaSizes[i], br)
      else
        FHistograms[i].DegenerateSymbol := 0;   // 0-bit code
  end else begin
    for i := 0 to nHist - 1 do
      ReadHistogram(i, br);
  end;

end;

// ---------------------------------------------------------------------------
// BeginReader — start a fresh ANS reader over the current code (libjxl
// ANSSymbolReader::Create). Reads the 32-bit ANS state and resets the LZ77
// window/counters. distMultiplier enables 2D special distances.
// ---------------------------------------------------------------------------
procedure TANSDecoder.BeginReader(br: TBitReader; distMultiplier: Cardinal);
var i, dist: Integer;
begin
  FDistMultiplier := distMultiplier;
  FNumToCopy  := 0;
  FCopyPos    := 0;
  FNumDecoded := 0;
  if FLZ77Enabled then begin
    SetLength(FWindow, LZ77_WINDOW_SIZE);
    if distMultiplier = 0 then
      FNumSpecialDist := 0
    else begin
      FNumSpecialDist := NUM_SPECIAL_DISTANCES;
      for i := 0 to NUM_SPECIAL_DISTANCES - 1 do begin
        dist := kSpecialDistDX[i] + Integer(distMultiplier) * kSpecialDistDY[i];
        if dist < 1 then dist := 1;
        FSpecialDist[i] := dist;
      end;
    end;
  end else
    FNumSpecialDist := 0;

  if not FUsePrefixCode then
    FANSState := br.ReadBits(32);
end;

// ---------------------------------------------------------------------------
// Init — standalone code + reader (the common case).
// ---------------------------------------------------------------------------
procedure TANSDecoder.Init(br: TBitReader; nContexts: Integer; distMultiplier: Cardinal = 0);
begin
  InitCode(br, nContexts);
  BeginReader(br, distMultiplier);
end;

// ---------------------------------------------------------------------------
// DecodeSymbol — decode a raw token from a clustered histogram index
// ---------------------------------------------------------------------------
function TANSDecoder.DecodeSymbol(hi: Integer; br: TBitReader): Cardinal;
begin
  if hi >= FNumHistograms then hi := 0;
  if FHistograms[hi].IsPrefix then
    Result := DecodeHuff(hi, br)
  else
    Result := DecodeANS(hi, br);
end;

// ---------------------------------------------------------------------------
// Decode — one integer value from given context (with hybrid LZ77)
// Mirrors dec_ans.h ReadHybridUintClusteredInlined<uses_lz77>.
// ---------------------------------------------------------------------------
function TANSDecoder.Decode(ctx: Integer; br: TBitReader): Cardinal;
var
  hi: Integer;
  token, token2, distance, ret: Cardinal;
  toFill, k: Cardinal;
begin
  // Emit pending LZ77 copy output first.
  if FLZ77Enabled and (FNumToCopy > 0) then begin
    ret := FWindow[FCopyPos and LZ77_WINDOW_MASK];
    Inc(FCopyPos);
    Dec(FNumToCopy);
    FWindow[FNumDecoded and LZ77_WINDOW_MASK] := ret;
    Inc(FNumDecoded);
    Result := ret;
    Exit;
  end;

  // Map context → histogram
  if (ctx >= 0) and (ctx < Length(FContextMap)) then
    hi := FContextMap[ctx]
  else
    hi := 0;
  if hi >= FNumHistograms then hi := 0;

  token := DecodeSymbol(hi, br);

  if FLZ77Enabled and (token >= FLZ77MinSymbol) then begin
    // This token starts an LZ77 copy: decode length, then distance.
    FNumToCopy := ReadHybridUint(token - FLZ77MinSymbol, FLZ77LenCfg, br)
                  + FLZ77MinLength;

    token2   := DecodeSymbol(FLZ77Ctx, br);
    distance := ReadHybridUint(token2, FHistograms[FLZ77Ctx].UintCfg, br);

    if distance < Cardinal(FNumSpecialDist) then
      distance := Cardinal(FSpecialDist[distance])
    else
      distance := distance + 1 - Cardinal(FNumSpecialDist);

    if distance > FNumDecoded then distance := FNumDecoded;
    if distance > LZ77_WINDOW_SIZE then distance := LZ77_WINDOW_SIZE;
    FCopyPos := FNumDecoded - distance;

    if distance = 0 then begin
      // Only possible at the very start (copy_pos == num_decoded == 0).
      toFill := FNumToCopy;
      if toFill > LZ77_WINDOW_SIZE then toFill := LZ77_WINDOW_SIZE;
      for k := 0 to toFill - 1 do FWindow[k] := 0;
    end;

    if FNumToCopy < FLZ77MinLength then begin
      Result := 0;
      Exit;
    end;

    ret := FWindow[FCopyPos and LZ77_WINDOW_MASK];
    Inc(FCopyPos);
    Dec(FNumToCopy);
    FWindow[FNumDecoded and LZ77_WINDOW_MASK] := ret;
    Inc(FNumDecoded);
    Result := ret;
    Exit;
  end;

  ret := ReadHybridUint(token, FHistograms[hi].UintCfg, br);
  if FLZ77Enabled then begin
    FWindow[FNumDecoded and LZ77_WINDOW_MASK] := ret;
    Inc(FNumDecoded);
  end;
  Result := ret;
end;

// ---------------------------------------------------------------------------
procedure TANSDecoder.ExtendContextMap(n: Integer);
var i, old: Integer;
begin
  old := Length(FContextMap);
  if n <= old then Exit;
  SetLength(FContextMap, n);
  for i := old to n - 1 do FContextMap[i] := 0;
end;

function TANSDecoder.CheckFinalState: Boolean;
begin
  if FUsePrefixCode then
    Result := True  // Huffman doesn't have a final state check
  else
    Result := (FANSState = Cardinal(ANS_SIGNATURE) shl 16);
end;

end.
