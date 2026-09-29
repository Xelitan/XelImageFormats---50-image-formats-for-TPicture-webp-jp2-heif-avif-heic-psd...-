{$mode delphi}
unit jxl_encoder;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// Minimal JPEG XL encoder (pure Pascal).
//   - Modular encoding, YCoCg RCT, gradient predictor
//   - Lossy via the MA-tree leaf multiplier M ("compression ratio"):
//     residuals are quantized to step M in a closed loop. M = 1 -> lossless.
//   - Single group: image must be <= 1024 x 1024 (group_size_shift = 3).
//   - Entropy: rANS with exact-precision histograms (shift = 13).
//
// Bitstream structure mirrors libjxl; verified against the decoder in this
// project (jxl_frame / jxl_modular / jxl_ans).

interface

uses SysUtils, Math;

// Encode 8-bit RGB (row-major, 3 bytes/pixel) to a bare JXL codestream.
// quantStep >= 1: residual quantization step (1 = lossless).
function JxlEncodeRGB8(const rgb: array of Byte; width, height: Integer;
                       quantStep: Integer): TBytes;

// Encode 8-bit RGBA (row-major, 4 bytes/pixel: R,G,B,A) to a bare JXL
// codestream with a single 8-bit unassociated alpha extra channel.
// quantStep >= 1 applies to all channels including alpha (1 = lossless).
function JxlEncodeRGBA8(const rgba: array of Byte; width, height: Integer;
                        quantStep: Integer): TBytes;

implementation

const
  ANS_TAB_SIZE  = 4096;
  ANS_SIGNATURE = $13;

// ===========================================================================
// Bit writer (LSB-first, matching TBitReader)
// ===========================================================================
type
  TBitWriter = class
  public
    Data: TBytes;
    Size: Integer;
    Acc:  UInt64;
    Bits: Integer;
    procedure WriteBits(value: Cardinal; n: Integer);
    procedure WriteBit(b: Boolean);
    procedure WriteU32Sized(value: Cardinal; d0: Cardinal; n0: Integer;
                            d1: Cardinal; n1: Integer; d2: Cardinal; n2: Integer;
                            d3: Cardinal; n3: Integer);
    procedure WriteU64Zero;
    procedure WriteVarLenU8(v: Cardinal);
    procedure AlignByte;
    procedure Flush;
  end;

procedure TBitWriter.WriteBits(value: Cardinal; n: Integer);
begin
  if n = 0 then Exit;
  Acc := Acc or (UInt64(value and ((UInt64(1) shl n) - 1)) shl Bits);
  Inc(Bits, n);
  while Bits >= 8 do begin
    if Size >= Length(Data) then SetLength(Data, Length(Data) * 2 + 1024);
    Data[Size] := Byte(Acc and $FF);
    Inc(Size);
    Acc := Acc shr 8;
    Dec(Bits, 8);
  end;
end;

procedure TBitWriter.WriteBit(b: Boolean);
begin
  if b then WriteBits(1, 1) else WriteBits(0, 1);
end;

procedure TBitWriter.WriteU32Sized(value: Cardinal; d0: Cardinal; n0: Integer;
                                   d1: Cardinal; n1: Integer; d2: Cardinal; n2: Integer;
                                   d3: Cardinal; n3: Integer);
begin
  if (value >= d0) and (Int64(value) - d0 < Int64(1) shl n0) then begin
    WriteBits(0, 2); WriteBits(value - d0, n0);
  end else if (value >= d1) and (Int64(value) - d1 < Int64(1) shl n1) then begin
    WriteBits(1, 2); WriteBits(value - d1, n1);
  end else if (value >= d2) and (Int64(value) - d2 < Int64(1) shl n2) then begin
    WriteBits(2, 2); WriteBits(value - d2, n2);
  end else begin
    WriteBits(3, 2); WriteBits(value - d3, n3);
  end;
end;

procedure TBitWriter.WriteU64Zero;
begin
  WriteBits(0, 2);
end;

procedure TBitWriter.WriteVarLenU8(v: Cardinal);
var n: Integer;
begin
  if v = 0 then begin WriteBit(False); Exit; end;
  WriteBit(True);
  n := 0;
  while (Cardinal(1) shl (n + 1)) <= v do Inc(n);
  WriteBits(Cardinal(n), 3);
  WriteBits(v - (Cardinal(1) shl n), n);
end;

procedure TBitWriter.AlignByte;
begin
  if Bits mod 8 <> 0 then WriteBits(0, 8 - (Bits mod 8));
end;

procedure TBitWriter.Flush;
begin
  AlignByte;
end;

// ===========================================================================
// Hybrid uint tokenization (config: split_exponent=4, msb=1, lsb=0)
// ===========================================================================
procedure HybridEncode(v: Cardinal; out token, nbits, bits: Cardinal);
var n: Integer; m: Cardinal;
begin
  if v < 16 then begin
    token := v; nbits := 0; bits := 0;
  end else begin
    n := 0;
    while (v shr (n + 1)) > 0 do Inc(n);             // FloorLog2
    m     := v - (Cardinal(1) shl n);
    token := 16 + Cardinal(n - 4) * 2 + (m shr (n - 1));
    nbits := Cardinal(n - 1);
    bits  := m and ((Cardinal(1) shl (n - 1)) - 1);
  end;
end;

function PackSigned(v: Int64): Cardinal;
begin
  if v >= 0 then Result := Cardinal(v) shl 1
  else Result := (Cardinal(-v) shl 1) - 1;
end;

// ===========================================================================
// Token list
// ===========================================================================
type
  TToken = record
    Token: Cardinal;
    NBits: Cardinal;
    Bits:  Cardinal;
  end;
  TTokenList = record
    Items: array of TToken;
    Count: Integer;
  end;

procedure TokAdd(var L: TTokenList; v: Cardinal);
var t, nb, b: Cardinal;
begin
  HybridEncode(v, t, nb, b);
  if L.Count >= Length(L.Items) then
    SetLength(L.Items, Length(L.Items) * 2 + 256);
  L.Items[L.Count].Token := t;
  L.Items[L.Count].NBits := nb;
  L.Items[L.Count].Bits  := b;
  Inc(L.Count);
end;

// ===========================================================================
// Histogram + alias reverse LUT
// ===========================================================================
procedure NormalizeHistogram(var counts: array of Integer; n: Integer);
var total, i, sum, maxIdx: Integer;
begin
  total := 0;
  for i := 0 to n - 1 do Inc(total, counts[i]);
  if total = 0 then begin counts[0] := ANS_TAB_SIZE; Exit; end;
  sum := 0; maxIdx := 0;
  for i := 0 to n - 1 do begin
    if counts[i] > 0 then begin
      counts[i] := Integer(Int64(counts[i]) * ANS_TAB_SIZE div total);
      if counts[i] = 0 then counts[i] := 1;
    end;
    Inc(sum, counts[i]);
    if counts[i] > counts[maxIdx] then maxIdx := i;
  end;
  Inc(counts[maxIdx], ANS_TAB_SIZE - sum);
end;

const
  // value -> (code, bits) for the fixed log-count Huffman table (LSB-first)
  kLogHuffBits: array[0..13] of Byte = (5,4,4,4,4,4,3,3,3,3,3,6,7,7);
  kLogHuffCode: array[0..13] of Byte = (17,11,15,3,9,7,4,2,5,6,0,33,1,65);

function FloorLog2C(v: Cardinal): Integer;
begin
  Result := 0;
  while v > 1 do begin v := v shr 1; Inc(Result); end;
end;

procedure WriteHistogram(bw: TBitWriter; const counts: array of Integer;
                         n: Integer);
var
  i, used, s0, s1, omitPos, omitLog, code: Integer;
  logc: array of Integer;
begin
  while (n > 1) and (counts[n - 1] = 0) do Dec(n);
  used := 0; s0 := -1; s1 := -1;
  for i := 0 to n - 1 do
    if counts[i] > 0 then begin
      Inc(used);
      if s0 < 0 then s0 := i else if s1 < 0 then s1 := i;
    end;

  if used = 1 then begin
    bw.WriteBit(True);  bw.WriteBit(False);
    bw.WriteVarLenU8(Cardinal(s0));
    Exit;
  end;
  if used = 2 then begin
    bw.WriteBit(True);  bw.WriteBit(True);
    bw.WriteVarLenU8(Cardinal(s0));
    bw.WriteVarLenU8(Cardinal(s1));
    bw.WriteBits(Cardinal(counts[s0]), 12);
    Exit;
  end;

  // complex path, shift = 13 -> exact counts
  bw.WriteBit(False);              // not simple
  bw.WriteBit(False);              // not flat
  bw.WriteBits(7, 3);              // log = 3 (three 1-bits)
  bw.WriteBits(6, 3);              // shift = (6 | 8) - 1 = 13
  bw.WriteVarLenU8(Cardinal(n - 3));

  SetLength(logc, n);
  omitPos := -1; omitLog := -1;
  for i := 0 to n - 1 do begin
    if counts[i] = 0 then logc[i] := 0
    else logc[i] := FloorLog2C(Cardinal(counts[i])) + 1;
    if logc[i] > omitLog then begin omitLog := logc[i]; omitPos := i; end;
  end;
  for i := 0 to n - 1 do begin
    code := logc[i];
    bw.WriteBits(kLogHuffCode[code], kLogHuffBits[code]);
  end;
  for i := 0 to n - 1 do begin
    if i = omitPos then Continue;
    code := logc[i];
    if code > 1 then
      bw.WriteBits(Cardinal(counts[i]) - (Cardinal(1) shl (code - 1)), code - 1);
  end;
end;

// Reverse alias LUT: revSlot[sym * 4096 + offset] = 12-bit res slot.
// Mirrors the decoder's BuildAlias (Vose) exactly.
procedure BuildRevSlots(const counts: array of Integer; n, logAlpha: Integer;
                        var revSlot: array of Integer);
var
  tabSize, entrySize, i, sym, res, pos, off: Integer;
  cutoffs, rightVal, offs1, underfull, overfull: array of Integer;
  ufc, ofc, oi, ui, by: Integer;
begin
  tabSize   := 1 shl logAlpha;
  entrySize := ANS_TAB_SIZE shr logAlpha;
  SetLength(cutoffs, tabSize);  SetLength(rightVal, tabSize);
  SetLength(offs1, tabSize);    SetLength(underfull, tabSize);
  SetLength(overfull, tabSize);
  for i := 0 to tabSize - 1 do begin
    if i < n then cutoffs[i] := counts[i] else cutoffs[i] := 0;
    rightVal[i] := i; offs1[i] := 0;
  end;
  ufc := 0; ofc := 0;
  for i := 0 to tabSize - 1 do
    if cutoffs[i] > entrySize then begin overfull[ofc] := i; Inc(ofc); end
    else if cutoffs[i] < entrySize then begin underfull[ufc] := i; Inc(ufc); end;
  while ofc > 0 do begin
    Dec(ofc); oi := overfull[ofc];
    Dec(ufc); ui := underfull[ufc];
    by := entrySize - cutoffs[ui];
    Dec(cutoffs[oi], by);
    rightVal[ui] := oi;
    offs1[ui]    := cutoffs[oi];
    if cutoffs[oi] < entrySize then begin underfull[ufc] := oi; Inc(ufc); end
    else if cutoffs[oi] > entrySize then begin overfull[ofc] := oi; Inc(ofc); end;
  end;
  for i := 0 to tabSize - 1 do begin
    if cutoffs[i] = entrySize then begin
      rightVal[i] := i; offs1[i] := 0; cutoffs[i] := 0;
    end else
      offs1[i] := offs1[i] - cutoffs[i];
    for pos := 0 to entrySize - 1 do begin
      res := (i shl (12 - logAlpha)) or pos;
      if pos < cutoffs[i] then begin sym := i; off := pos; end
      else begin sym := rightVal[i]; off := offs1[i] + pos; end;
      revSlot[sym * ANS_TAB_SIZE + off] := res;
    end;
  end;
end;

// ===========================================================================
// Entropy code: prepared state, header writing, ANS stream writing
// ===========================================================================
type
  TPreparedCode = record
    N:        Integer;
    LogAlpha: Integer;
    Freq:     array of Integer;
    Rev:      array of Integer;
  end;

procedure PrepareCode(const L: TTokenList; out prep: TPreparedCode);
var i: Integer;
begin
  prep.N := 1;
  for i := 0 to L.Count - 1 do
    if Integer(L.Items[i].Token) + 1 > prep.N then
      prep.N := Integer(L.Items[i].Token) + 1;
  prep.LogAlpha := 5;
  while (1 shl prep.LogAlpha) < prep.N do Inc(prep.LogAlpha);
  if prep.LogAlpha > 8 then
    raise Exception.Create('encoder: alphabet too large');
  SetLength(prep.Freq, prep.N);
  for i := 0 to prep.N - 1 do prep.Freq[i] := 0;
  for i := 0 to L.Count - 1 do Inc(prep.Freq[L.Items[i].Token]);
  NormalizeHistogram(prep.Freq, prep.N);
  SetLength(prep.Rev, prep.N * ANS_TAB_SIZE);
  BuildRevSlots(prep.Freq, prep.N, prep.LogAlpha, prep.Rev);
end;

// DecodeHistograms-format code header (lz77 off, shared histogram 0).
procedure WriteCodeHeader(bw: TBitWriter; const prep: TPreparedCode;
                          nCtx: Integer);
var i: Integer;
begin
  bw.WriteBit(False);                              // lz77 disabled
  if nCtx > 1 then begin
    bw.WriteBit(True);                             // context map: simple
    bw.WriteBits(0, 2);                            // 0 bits/entry -> all zero
  end;
  bw.WriteBit(False);                              // use_prefix_code = 0
  bw.WriteBits(Cardinal(prep.LogAlpha - 5), 2);    // log_alpha_size
  // uint config (split=4, msb=1, lsb=0)
  i := 0; while (1 shl i) < prep.LogAlpha + 1 do Inc(i);
  bw.WriteBits(4, i);
  bw.WriteBits(1, 3);
  bw.WriteBits(0, 2);
  WriteHistogram(bw, prep.Freq, prep.N);
end;

// 32-bit initial state + forward tokens (renorm words interleaved).
procedure WriteANSStream(bw: TBitWriter; const L: TTokenList;
                         const prep: TPreparedCode);
var
  flush: array of Word;
  hasFlush: array of Boolean;
  x: UInt64;
  f, slot: Cardinal;
  t: Integer;
begin
  SetLength(flush, L.Count);
  SetLength(hasFlush, L.Count);
  x := UInt64(ANS_SIGNATURE) shl 16;
  for t := L.Count - 1 downto 0 do begin
    hasFlush[t] := False;
    f := Cardinal(prep.Freq[L.Items[t].Token]);
    if x >= (UInt64(f) shl 20) then begin
      flush[t]    := Word(x and $FFFF);
      hasFlush[t] := True;
      x := x shr 16;
    end;
    slot := Cardinal(prep.Rev[Integer(L.Items[t].Token) * ANS_TAB_SIZE +
                              Integer(x mod f)]);
    x := ((x div f) shl 12) or slot;
  end;
  bw.WriteBits(Cardinal(x and $FFFF), 16);
  bw.WriteBits(Cardinal((x shr 16) and $FFFF), 16);
  for t := 0 to L.Count - 1 do begin
    if hasFlush[t] then bw.WriteBits(flush[t], 16);
    if L.Items[t].NBits > 0 then
      bw.WriteBits(L.Items[t].Bits, Integer(L.Items[t].NBits));
  end;
end;

// ===========================================================================
// The encoder
// ===========================================================================
function ASR1(v: Int64): Int64;   // arithmetic shift right by 1 (floor)
begin
  if v >= 0 then Result := v div 2
  else Result := (v - 1) div 2;
end;

function ClampedGradient(n, w, l: Int64): Int64;
var m, mm: Int64;
begin
  if n < w then begin m := n; mm := w; end else begin m := w; mm := n; end;
  if l < m then Result := mm
  else if l > mm then Result := m
  else Result := n + w - l;
end;

// Tokenize one channel rect (closed loop, gradient predictor, quant step M).
procedure TokenizeRect(var L: TTokenList; const chData: array of Int32;
                       imgW, x0, y0, rw, rh, quantStep: Integer);
var
  rec: array of Int32;
  x, y: Integer;
  left, top, topleft, guess, resid, q: Int64;
begin
  SetLength(rec, rw * rh);
  for y := 0 to rh - 1 do
    for x := 0 to rw - 1 do begin
      if x > 0 then left := rec[y*rw + x-1]
      else if y > 0 then left := rec[(y-1)*rw + x]
      else left := 0;
      if y > 0 then top := rec[(y-1)*rw + x] else top := left;
      if (x > 0) and (y > 0) then topleft := rec[(y-1)*rw + x-1]
      else topleft := left;
      guess := ClampedGradient(left, top, topleft);
      resid := chData[(y0 + y) * imgW + x0 + x] - guess;
      if resid >= 0 then q := (resid + quantStep div 2) div quantStep
      else q := -((-resid + quantStep div 2) div quantStep);
      TokAdd(L, PackSigned(q));
      rec[y*rw + x] := Int32(guess + q * quantStep);
    end;
end;

// GroupHeader bits shared by global and group streams.
procedure WriteGroupHeader(bw: TBitWriter; withRCT: Boolean);
begin
  bw.WriteBit(True);                  // use_global_tree
  bw.WriteBit(True);                  // wp_header: all default
  if withRCT then begin
    bw.WriteBits(1, 2);               // num_transforms = 1 (sel1)
    bw.WriteBits(0, 2);               // transform id = RCT (sel0)
    bw.WriteBits(0, 2); bw.WriteBits(0, 3);   // begin_c = 0 (Bits(3) sel0)
    bw.WriteBits(0, 2);               // rct_type = 6 (sel0 = Val(6))
  end else
    bw.WriteBits(0, 2);               // num_transforms = 0 (sel0)
end;

// Shared encode core. src is row-major with `stride` bytes per pixel
// (3 = RGB, 4 = RGBA). When hasAlpha, the 4th source byte becomes a modular
// extra channel (8-bit unassociated alpha), coded after the 3 colour channels.
function JxlEncodeCore(const src: array of Byte; width, height, quantStep: Integer;
                       hasAlpha: Boolean): TBytes;
const
  kGroupDim = 1024;                   // group_size_shift = 3
var
  bw: TBitWriter;
  sections: array of TBitWriter;
  ch: array[0..3] of array of Int32;  // Y, Co, Cg [, Alpha]
  treeTok: TTokenList;
  groupTok: array of TTokenList;      // per group (numChan channels each)
  allTok: TTokenList;
  treePrep, chanPrep: TPreparedCode;
  c, i, g: Integer;
  r, g8, b, vY, vCo, vCg, tmp: Int64;
  xg, yg, numGroups, numDC, numSections: Integer;
  gx, gy, x0, y0, rw, rh: Integer;
  sizeBytes, totalPayload: Integer;
  ratio: Integer;
  useSmall: Boolean;
  numChan, stride: Integer;
begin
  if quantStep < 1 then quantStep := 1;
  if hasAlpha then begin numChan := 4; stride := 4; end
  else begin numChan := 3; stride := 3; end;

  // --- forward YCoCg RCT on the colour channels (rct_type 6) ---
  for c := 0 to numChan - 1 do SetLength(ch[c], width * height);
  for i := 0 to width * height - 1 do begin
    r := src[i*stride]; g8 := src[i*stride+1]; b := src[i*stride+2];
    vCo := r - b;
    tmp := b + ASR1(vCo);
    vCg := g8 - tmp;
    vY  := tmp + ASR1(vCg);
    ch[0][i] := Int32(vY);
    ch[1][i] := Int32(vCo);
    ch[2][i] := Int32(vCg);
    if hasAlpha then ch[3][i] := Int32(src[i*stride+3]);  // alpha (no RCT)
  end;

  // --- group geometry ---
  xg := (width + kGroupDim - 1) div kGroupDim;
  yg := (height + kGroupDim - 1) div kGroupDim;
  numGroups := xg * yg;
  numDC := ((width + kGroupDim*8 - 1) div (kGroupDim*8)) *
           ((height + kGroupDim*8 - 1) div (kGroupDim*8));

  // --- tree tokens: single leaf (Gradient, offset 0, multiplier M) ---
  treeTok.Count := 0;
  TokAdd(treeTok, 0);                       // property + 1 = 0 -> leaf
  TokAdd(treeTok, 5);                       // predictor = Gradient
  TokAdd(treeTok, PackSigned(0));           // offset
  TokAdd(treeTok, 0);                       // mul_log
  TokAdd(treeTok, Cardinal(quantStep - 1)); // mul_bits -> M = quantStep

  // --- per-group channel tokens (closed loop within each rect) ---
  SetLength(groupTok, numGroups);
  for g := 0 to numGroups - 1 do begin
    groupTok[g].Count := 0;
    gx := g mod xg; gy := g div xg;
    x0 := gx * kGroupDim; y0 := gy * kGroupDim;
    rw := width - x0;  if rw > kGroupDim then rw := kGroupDim;
    rh := height - y0; if rh > kGroupDim then rh := kGroupDim;
    for c := 0 to numChan - 1 do
      TokenizeRect(groupTok[g], ch[c], width, x0, y0, rw, rh, quantStep);
  end;

  // Channel code is global: histogram over all groups' tokens.
  allTok.Count := 0;
  for g := 0 to numGroups - 1 do
    for i := 0 to groupTok[g].Count - 1 do begin
      if allTok.Count >= Length(allTok.Items) then
        SetLength(allTok.Items, Length(allTok.Items) * 2 + 1024);
      allTok.Items[allTok.Count] := groupTok[g].Items[i];
      Inc(allTok.Count);
    end;

  PrepareCode(treeTok, treePrep);
  PrepareCode(allTok, chanPrep);

  // --- section payloads ---
  if numGroups = 1 then numSections := 1
  else numSections := 2 + numDC + numGroups;
  SetLength(sections, numSections);
  for i := 0 to numSections - 1 do begin
    sections[i] := TBitWriter.Create;
    SetLength(sections[i].Data, 4096);
  end;

  // Section 0: LfGlobal
  sections[0].WriteBit(True);                  // DequantMatrices DC: default
  sections[0].WriteBit(True);                  // has_tree
  WriteCodeHeader(sections[0], treePrep, 6);
  WriteANSStream(sections[0], treeTok, treePrep);
  WriteCodeHeader(sections[0], chanPrep, 1);
  WriteGroupHeader(sections[0], True);         // global stream (RCT transform)
  if numGroups = 1 then
    // collapsed: channels coded directly in the global stream
    WriteANSStream(sections[0], groupTok[0], chanPrep)
  else
    // big channels are skipped in the global stream; per-group sections:
    // sections 1..numDC (DC) and numDC+1 (ACGlobal) stay empty.
    for g := 0 to numGroups - 1 do begin
      WriteGroupHeader(sections[numDC + 2 + g], False);
      WriteANSStream(sections[numDC + 2 + g], groupTok[g], chanPrep);
    end;

  totalPayload := 0;
  for i := 0 to numSections - 1 do begin
    sections[i].Flush;
    Inc(totalPayload, sections[i].Size);
  end;

  bw := TBitWriter.Create;
  try
    SetLength(bw.Data, 4096);
    // ---- codestream header ----
    bw.WriteBits($FF, 8); bw.WriteBits($0A, 8);
    // SizeHeader. We always emit the non-small (small=0) form: empirically djxl
    // rejects our small-mode encoding, while small=0 round-trips bit-exactly.
    // We still apply libjxl's aspect-ratio coding (xsize == MulTruncate(ysize)):
    //   1:1, 12:10, 4:3, 3:2, 16:9, 5:4, 2:1  (codes 1..7), else 0 -> send xsize.
    ratio := 0;
    if      width = (height * 1)  div 1  then ratio := 1
    else if width = (height * 12) div 10 then ratio := 2
    else if width = (height * 4)  div 3  then ratio := 3
    else if width = (height * 3)  div 2  then ratio := 4
    else if width = (height * 16) div 9  then ratio := 5
    else if width = (height * 5)  div 4  then ratio := 6
    else if width = (height * 2)  div 1  then ratio := 7;
    useSmall := False;
    bw.WriteBit(useSmall);                                 // small = 0
    bw.WriteU32Sized(Cardinal(height), 1,9, 1,13, 1,18, 1,30);
    bw.WriteBits(Cardinal(ratio), 3);
    if ratio = 0 then
      bw.WriteU32Sized(Cardinal(width), 1,9, 1,13, 1,18, 1,30);
    // ImageMetadata (xyb = false)
    bw.WriteBit(False);                      // all_default = 0
    bw.WriteBit(False);                      // extra_fields
    bw.WriteBit(False);                      // bit_depth: integer
    bw.WriteBits(0, 2);                      // bits_per_sample = 8 (Val(8))
    bw.WriteBit(True);                       // modular_16bit_sufficient
    // num_extra_channels: U32(Val0, Val1, BitsOffset(4,2), BitsOffset(12,1))
    if hasAlpha then begin
      bw.WriteBits(1, 2);                    // num_extra_channels = 1 (sel1=Val1)
      // ExtraChannelInfo: all_default=1 -> 8-bit unassociated alpha (libjxl
      // SetDefault gives type=kAlpha, 8-bit, dim_shift=0, alpha_associated=0).
      bw.WriteBit(True);                     // ec all_default = 1
    end else
      bw.WriteBits(0, 2);                    // num_extra_channels = 0
    bw.WriteBit(False);                      // xyb_encoded = 0
    // ColorEncoding explicit sRGB (matching libjxl): all_default=0
    bw.WriteBit(False);                      // ce all_default = 0
    bw.WriteBit(False);                      // want_icc = 0
    bw.WriteBits(0, 2);                      // colour_space kRGB (enum sel0=Val0)
    bw.WriteBits(1, 2);                      // white_point D65 (enum sel1=Val1)
    bw.WriteBits(1, 2);                      // primaries sRGB (enum sel1=Val1)
    bw.WriteBit(False);                      // have_gamma = 0
    bw.WriteBits(2, 2); bw.WriteBits(11, 4); // transfer kSRGB=13 (enum sel2: 2+11)
    bw.WriteBits(0, 2);                      // rendering_intent kPerceptual (enum sel0=Val0)
    bw.WriteU64Zero;                         // metadata extensions
    bw.WriteBit(True);                       // CustomTransformData all_default
    bw.AlignByte;
    // FrameHeader
    bw.WriteBit(False);                      // all_default
    bw.WriteBits(0, 2);                      // frame_type = regular
    bw.WriteBit(True);                       // is_modular
    bw.WriteU64Zero;                         // flags
    bw.WriteBit(False);                      // DoYCbCr = 0
    bw.WriteBits(0, 2);                      // upsampling = 1
    if hasAlpha then
      bw.WriteBits(0, 2);                    // extra-channel upsampling = 1
    bw.WriteBits(3, 2);                      // group_size_shift = 3
    bw.WriteBits(0, 2);                      // num_passes = 1
    bw.WriteBit(False);                      // custom_size_or_origin
    bw.WriteBits(0, 2);                      // blend mode = replace (main)
    if hasAlpha then
      bw.WriteBits(0, 2);                    // extra-channel blend mode = replace
    bw.WriteBit(True);                       // is_last
    bw.WriteBits(0, 2);                      // name length = 0
    bw.WriteBit(False);                      // LoopFilter all_default = 0
    bw.WriteBit(False);                      // gab = 0
    bw.WriteBits(0, 2);                      // epf_iters = 0
    bw.WriteU64Zero;                         // loop filter extensions
    bw.WriteU64Zero;                         // frame extensions
    // TOC
    bw.WriteBit(False);                      // no permutation
    bw.AlignByte;
    for i := 0 to numSections - 1 do
      bw.WriteU32Sized(Cardinal(sections[i].Size),
                       0,10, 1024,14, 17408,22, 4211712,30);
    bw.AlignByte;
    bw.Flush;

    SetLength(Result, bw.Size + totalPayload);
    if bw.Size > 0 then Move(bw.Data[0], Result[0], bw.Size);
    sizeBytes := bw.Size;
    for i := 0 to numSections - 1 do begin
      if sections[i].Size > 0 then
        Move(sections[i].Data[0], Result[sizeBytes], sections[i].Size);
      Inc(sizeBytes, sections[i].Size);
    end;
  finally
    bw.Free;
    for i := 0 to numSections - 1 do sections[i].Free;
  end;
end;

function JxlEncodeRGB8(const rgb: array of Byte; width, height: Integer;
                       quantStep: Integer): TBytes;
begin
  Result := JxlEncodeCore(rgb, width, height, quantStep, False);
end;

function JxlEncodeRGBA8(const rgba: array of Byte; width, height: Integer;
                        quantStep: Integer): TBytes;
begin
  Result := JxlEncodeCore(rgba, width, height, quantStep, True);
end;

end.
