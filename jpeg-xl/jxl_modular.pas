{$mode delphi}
unit jxl_modular;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// Modular image decoder for JPEG XL — faithful port of libjxl 0.11.2
// (modular/encoding/{dec_ma,encoding}.cc and context_predict.h).
//
// Implements:
//   * GroupHeader (use_global_tree, weighted-predictor header, transforms)
//   * Meta-Adaptive (MA) tree decode (own entropy decoder, 6 tree contexts)
//   * Per-pixel decode: full 16 non-ref property vector + reference-channel
//     properties, all 14 predictors, and the self-correcting weighted predictor
//   * Inverse RCT (all 42 types)
// Squeeze and Palette transforms are parsed but their MetaApply/inverse are
// not yet implemented (they raise a clear error).

interface

uses
  SysUtils, Math, jxl_types, jxl_bits, jxl_ans;

const
  // Predictor IDs (modular/options.h Predictor enum)
  kNumModularPredictors = 14;
  PRED_ZERO     = 0;
  PRED_LEFT     = 1;
  PRED_TOP      = 2;
  PRED_AVG0     = 3;   // (left+top)/2
  PRED_SELECT   = 4;
  PRED_GRADIENT = 5;   // ClampedGradient(left,top,topleft)
  PRED_WEIGHTED = 6;
  PRED_TOPRIGHT = 7;
  PRED_TOPLEFT  = 8;
  PRED_LEFTLEFT = 9;
  PRED_AVG1     = 10;  // (left+topleft)/2
  PRED_AVG2     = 11;  // (topleft+top)/2
  PRED_AVG3     = 12;  // (top+topright)/2
  PRED_AVG4     = 13;

  // Property layout
  kNumStaticProperties  = 2;     // channel, group
  kNumNonrefProperties  = 16;    // 2 static + 13 + 1 WP
  kExtraPropsPerChannel = 4;
  kWPProp               = 15;

  // MA tree entropy contexts (ma_common.h)
  kSplitValContext       = 0;
  kPropertyContext       = 1;
  kPredictorContext      = 2;
  kOffsetContext         = 3;
  kMultiplierLogContext  = 4;
  kMultiplierBitsContext = 5;
  kNumTreeContexts       = 6;

type
  TModChannel = record
    Width, Height:  Integer;
    HShift, VShift: Integer;
    Data:           array of Int32;   // row-major (pixel_type = int32)
  end;

  TModImage = record
    Channels:        array of TModChannel;
    NumChannels:     Integer;
    NumMetaChannels: Integer;
    BitDepth:        Integer;
  end;

  TMATreeNode = record
    Prop:       Integer;   // -1 => leaf
    SplitVal:   Int32;
    LChild:     Integer;
    RChild:     Integer;
    Predictor:  Integer;
    Offset:     Int64;
    Multiplier: Int64;
    CtxId:      Integer;   // leaf context (== leaf index)
  end;
  TMATree = array of TMATreeNode;

  TWPHeader = record
    p1C, p2C, p3Ca, p3Cb, p3Cc, p3Cd, p3Ce: Integer;
    w: array[0..3] of Cardinal;
  end;

  // Self-correcting weighted predictor state (context_predict.h weighted::State)
  TWPState = record
    Header:     TWPHeader;
    XSize:      Integer;
    PredErrors: array[0..3] of array of UInt32;  // each (xsize+2)*2
    ErrVal:     array of Int32;                   // (xsize+2)*2
    Prediction: array[0..3] of Int64;
    Pred:       Int64;
  end;

procedure InitModChannel(var c: TModChannel; w, h, hs, vs: Integer);
function  ModChannelAt(const c: TModChannel; x, y: Integer): Int64; inline;
procedure ModChannelSet(var c: TModChannel; x, y: Integer; v: Int64); inline;

// Decode a standalone modular image (its own MA tree, no global tree).
procedure DecodeModularImage(br: TBitReader; var img: TModImage;
                             numColorChannels: Integer;
                             numExtraChannels: Integer;
                             xsize, ysize: Integer;
                             bitDepth: Integer);

type
  TSqueezeParamPub = record
    Horizontal, InPlace: Boolean;
    BeginC, NumC: Integer;
  end;

  TModTransformPub = record
    Id:       Integer;       // 0=RCT,1=Palette,2=Squeeze
    BeginC:   Integer;
    RctType:  Integer;
    NumC:     Integer;
    NbColors: Integer;
    NbDeltas: Integer;
    Predictor: Integer;
    NumSqueezes: Integer;
    Squeezes: array of TSqueezeParamPub;
  end;
  TModTransformList = array of TModTransformPub;

// Decode the channels of an already-laid-out modular image. Reads the
// GroupHeader; if it requests the global tree, uses globalTree/globalAns
// (globalAns must already be InitCode'd); otherwise decodes a local tree.
procedure ModularDecodeImage(br: TBitReader; var img: TModImage;
                             const globalTree: TMATree; globalAns: TANSDecoder;
                             groupId: Integer; undoTransforms: Boolean);

// Options variant: channels at index >= NumMetaChannels whose width or height
// exceeds maxChanSize stop the decode (libjxl "break" semantics); the parsed
// transform list is returned so the caller can undo it later on the
// reassembled full image.
procedure ModularDecodeImageOpts(br: TBitReader; var img: TModImage;
                                 const globalTree: TMATree;
                                 globalAns: TANSDecoder;
                                 groupId: Integer; undoTransforms: Boolean;
                                 maxChanSize: Integer;
                                 out transformsOut: TModTransformList);

// Undo a previously captured transform list on a (reassembled) image.
procedure ApplyInverseTransformList(var img: TModImage;
                                    const transforms: TModTransformList);

type
  // GroupHeader (encoding.h): the stream's weighted-predictor parameters and
  // transforms, kept so the transforms can be undone later.
  TModGroupHeader = record
    UseGlobalTree: Boolean;
    WP: TWPHeader;
    Transforms: TModTransformList;
  end;

// ModularGenericDecompress (encoding.cc): reads the group header, applies the
// transforms' channel layout, decodes the channels (those at index >=
// NumMetaChannels larger than maxChanSize stop the decode, as in libjxl) and,
// if undoTransforms, undoes the transforms. hdr returns the header.
procedure ModularGenericDecompress(br: TBitReader; var img: TModImage;
                                   const globalTree: TMATree;
                                   globalAns: TANSDecoder; streamId: Integer;
                                   undoTransforms: Boolean;
                                   maxChanSize: Integer;
                                   out hdr: TModGroupHeader);

// Undo the transforms of a header (last first) with its WP parameters.
procedure UndoModularTransforms(var img: TModImage; const hdr: TModGroupHeader);

// Decode just an MA tree (its own entropy decoder). Public for the global
// tree decoded in VarDCT LFGlobal.
procedure ReadMATree(br: TBitReader; var tree: TMATree);

procedure InverseRCT(var img: TModImage; rctType: Integer; beginChan: Integer);

implementation

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
function UnpackSigned(v: Cardinal): Int64; inline;
begin
  if (v and 1) <> 0 then Result := -((Int64(v) + 1) shr 1)
  else Result := Int64(v) shr 1;
end;

// Arithmetic (floor) right shift for signed Int64.
function ASR(v: Int64; n: Integer): Int64; inline;
begin
  Result := v div (Int64(1) shl n);
  if (v < 0) and ((v and ((Int64(1) shl n) - 1)) <> 0) then Dec(Result);
end;

function FloorLog2NZ(x: UInt64): Integer; inline;
var v: UInt64;
begin
  Result := 0;
  v := x;
  while v > 1 do begin v := v shr 1; Inc(Result); end;
end;

procedure InitModChannel(var c: TModChannel; w, h, hs, vs: Integer);
begin
  c.Width := w; c.Height := h; c.HShift := hs; c.VShift := vs;
  SetLength(c.Data, w * h);
end;

function ModChannelAt(const c: TModChannel; x, y: Integer): Int64;
begin
  if (x < 0) or (y < 0) or (x >= c.Width) or (y >= c.Height) then Result := 0
  else Result := c.Data[y * c.Width + x];
end;

procedure ModChannelSet(var c: TModChannel; x, y: Integer; v: Int64);
begin
  c.Data[y * c.Width + x] := Int32(v);
end;

// ---------------------------------------------------------------------------
// Predictors
// ---------------------------------------------------------------------------
function ClampedGradient(n, w, l: Int64): Int64; inline;
var m, mm, grad: Int64;
begin
  if n < w then begin m := n; mm := w; end else begin m := w; mm := n; end;
  grad := n + w - l;
  if l < m then Result := mm
  else if l > mm then Result := m
  else Result := grad;
end;

function SelectPred(a, b, c: Int64): Int64; inline;
var p, pa, pb: Int64;
begin
  p := a + b - c;
  pa := Abs(p - a);
  pb := Abs(p - b);
  if pa < pb then Result := a else Result := b;
end;

// detail::PredictOne (context_predict.h)
function PredictOne(p: Integer; left, top, toptop, topleft, topright,
                    leftleft, toprightright, wpPred: Int64): Int64;
begin
  case p of
    PRED_ZERO:     Result := 0;
    PRED_LEFT:     Result := left;
    PRED_TOP:      Result := top;
    PRED_AVG0:     Result := (left + top) div 2;
    PRED_SELECT:   Result := SelectPred(left, top, topleft);
    PRED_GRADIENT: Result := ClampedGradient(left, top, topleft);
    PRED_WEIGHTED: Result := wpPred;
    PRED_TOPRIGHT: Result := topright;
    PRED_TOPLEFT:  Result := topleft;
    PRED_LEFTLEFT: Result := leftleft;
    PRED_AVG1:     Result := (left + topleft) div 2;
    PRED_AVG2:     Result := (topleft + top) div 2;
    PRED_AVG3:     Result := (top + topright) div 2;
    PRED_AVG4:     Result := (6*top - 2*toptop + 7*left + leftleft +
                              toprightright + 3*topright + 8) div 16;
  else             Result := 0;
  end;
end;

// ---------------------------------------------------------------------------
// Weighted predictor
// ---------------------------------------------------------------------------
const
  kPredExtraBits  = 3;
  kPredictionRnd  = ((1 shl kPredExtraBits) shr 1) - 1;   // = 3

  kDivLookup: array[0..63] of UInt32 = (
    16777216, 8388608, 5592405, 4194304, 3355443, 2796202, 2396745, 2097152,
    1864135,  1677721, 1525201, 1398101, 1290555, 1198372, 1118481, 1048576,
    986895,   932067,  883011,  838860,  798915,  762600,  729444,  699050,
    671088,   645277,  621378,  599186,  578524,  559240,  541200,  524288,
    508400,   493447,  479349,  466033,  453438,  441505,  430185,  419430,
    409200,   399457,  390167,  381300,  372827,  364722,  356962,  349525,
    342392,   335544,  328965,  322638,  316551,  310689,  305040,  299593,
    294337,   289262,  284359,  279620,  275036,  270600,  266305,  262144);

function WPErrorWeight(x: UInt64; maxweight: Cardinal): Cardinal; inline;
var shift: Integer;
begin
  shift := FloorLog2NZ(x + 1) - 5;
  if shift < 0 then shift := 0;
  Result := 4 + ((maxweight * kDivLookup[x shr shift]) shr shift);
end;

procedure WPInit(var st: TWPState; const hdr: TWPHeader; xsize, ysize: Integer);
var i, n: Integer;
begin
  st.Header := hdr;
  st.XSize  := xsize;
  n := (xsize + 2) * 2;
  for i := 0 to 3 do begin
    SetLength(st.PredErrors[i], n);
    FillChar(st.PredErrors[i][0], n * SizeOf(UInt32), 0);
  end;
  SetLength(st.Errval, n);
  FillChar(st.Errval[0], n * SizeOf(Int32), 0);
end;

function WPWeightedAverage(const p: array of Int64; w: array of Cardinal): Int64;
var i: Integer; weightSum: Cardinal; logW: Integer; sum: Int64;
begin
  weightSum := 0;
  for i := 0 to 3 do Inc(weightSum, w[i]);
  logW := FloorLog2NZ(weightSum);
  weightSum := 0;
  for i := 0 to 3 do begin
    w[i] := w[i] shr (logW - 4);
    Inc(weightSum, w[i]);
  end;
  sum := Int64(weightSum shr 1) - 1;
  for i := 0 to 3 do sum := sum + p[i] * Int64(w[i]);
  Result := ASR(sum * Int64(kDivLookup[weightSum - 1]), 24);
end;

// weighted::State::Predict. Returns guess; if computeProps, sets props[offset].
function WPPredict(var st: TWPState; x, y, xsize: Integer;
                   N, W, NE, NW, NN: Int64;
                   computeProps: Boolean; var props: array of Int64;
                   offset: Integer): Int64;
var
  curRow, prevRow, posN, posNE, posNW, i: Integer;
  weights: array[0..3] of Cardinal;
  teW, teN, teNW, teNE, sumWN, pp, mx, mn: Int64;
begin
  if (y and 1) <> 0 then begin curRow := 0; prevRow := xsize + 2; end
  else begin curRow := xsize + 2; prevRow := 0; end;
  posN := prevRow + x;
  if x < xsize - 1 then posNE := posN + 1 else posNE := posN;
  if x > 0 then posNW := posN - 1 else posNW := posN;

  for i := 0 to 3 do begin
    weights[i] := st.PredErrors[i][posN] + st.PredErrors[i][posNE] +
                  st.PredErrors[i][posNW];
    weights[i] := WPErrorWeight(weights[i], st.Header.w[i]);
  end;

  N := N * 8; W := W * 8; NE := NE * 8; NW := NW * 8; NN := NN * 8;

  if x = 0 then teW := 0 else teW := st.Errval[curRow + x - 1];
  teN  := st.Errval[posN];
  teNW := st.Errval[posNW];
  teNE := st.Errval[posNE];
  sumWN := teN + teW;

  if computeProps then begin
    pp := teW;
    if Abs(teN)  > Abs(pp) then pp := teN;
    if Abs(teNW) > Abs(pp) then pp := teNW;
    if Abs(teNE) > Abs(pp) then pp := teNE;
    props[offset] := pp;
  end;

  st.Prediction[0] := W + NE - N;
  st.Prediction[1] := N - ASR((sumWN + teNE) * st.Header.p1C, 5);
  st.Prediction[2] := W - ASR((sumWN + teNW) * st.Header.p2C, 5);
  st.Prediction[3] := N - ASR(teNW * st.Header.p3Ca + teN * st.Header.p3Cb +
                              teNE * st.Header.p3Cc + (NN - N) * st.Header.p3Cd +
                              (NW - W) * st.Header.p3Ce, 5);

  st.Pred := WPWeightedAverage(st.Prediction, weights);

  if ((teN xor teW) or (teN xor teNW)) > 0 then begin
    Result := ASR(st.Pred + kPredictionRnd, kPredExtraBits);
    Exit;
  end;

  mx := Max(W, Max(NE, N));
  mn := Min(W, Min(NE, N));
  st.Pred := Max(mn, Min(mx, st.Pred));
  Result := ASR(st.Pred + kPredictionRnd, kPredExtraBits);
end;

procedure WPUpdateErrors(var st: TWPState; val: Int64; x, y, xsize: Integer);
var curRow, prevRow, i: Integer; err: Int64;
begin
  if (y and 1) <> 0 then begin curRow := 0; prevRow := xsize + 2; end
  else begin curRow := xsize + 2; prevRow := 0; end;
  val := val * 8;
  st.Errval[curRow + x] := Int32(st.Pred - val);
  for i := 0 to 3 do begin
    err := ASR(Abs(st.Prediction[i] - val) + kPredictionRnd, kPredExtraBits);
    st.PredErrors[i][curRow + x] := UInt32(err);
    Inc(st.PredErrors[i][prevRow + x + 1], UInt32(err));
  end;
end;

// ---------------------------------------------------------------------------
// Weighted-predictor header (context_predict.h weighted::Header::VisitFields)
// ---------------------------------------------------------------------------
procedure ReadWPHeaderDefault(var hdr: TWPHeader);
begin
  hdr.p1C := 16; hdr.p2C := 10; hdr.p3Ca := 7; hdr.p3Cb := 7;
  hdr.p3Cc := 7; hdr.p3Cd := 0; hdr.p3Ce := 0;
  hdr.w[0] := $d; hdr.w[1] := $c; hdr.w[2] := $c; hdr.w[3] := $c;
end;

procedure ReadWPHeader(br: TBitReader; var hdr: TWPHeader);
var allDefault: Boolean;
begin
  // defaults (PredictorMode preset 0 / SetDefault)
  hdr.p1C := 16; hdr.p2C := 10; hdr.p3Ca := 7; hdr.p3Cb := 7;
  hdr.p3Cc := 7; hdr.p3Cd := 0; hdr.p3Ce := 0;
  hdr.w[0] := $d; hdr.w[1] := $c; hdr.w[2] := $c; hdr.w[3] := $c;

  allDefault := br.ReadBit;        // AllDefault: bit==1 -> default
  if allDefault then Exit;

  hdr.p1C  := br.ReadBits(5);
  hdr.p2C  := br.ReadBits(5);
  hdr.p3Ca := br.ReadBits(5);
  hdr.p3Cb := br.ReadBits(5);
  hdr.p3Cc := br.ReadBits(5);
  hdr.p3Cd := br.ReadBits(5);
  hdr.p3Ce := br.ReadBits(5);
  hdr.w[0] := br.ReadBits(4);
  hdr.w[1] := br.ReadBits(4);
  hdr.w[2] := br.ReadBits(4);
  hdr.w[3] := br.ReadBits(4);
end;

// ---------------------------------------------------------------------------
// MA tree decode (dec_ma.cc DecodeTree) — uses its own entropy decoder.
// ---------------------------------------------------------------------------
procedure ReadMATree(br: TBitReader; var tree: TMATree);
var
  ans: TANSDecoder;
  toDecode, leafId: Integer;
  prop1, predictor, mulLog, mulBits: Cardinal;
  property_, splitval: Integer;
  node: TMATreeNode;
  cnt: Integer;
begin
  SetLength(tree, 0);
  ans := TANSDecoder.Create;
  try
    ans.Init(br, kNumTreeContexts);

    toDecode := 1;
    leafId   := 0;
    cnt      := 0;
    while toDecode > 0 do begin
      Inc(cnt);
      if cnt > (1 shl 20) then
        raise EJxlError.Create('Modular: MA tree too large');
      Dec(toDecode);

      prop1 := ans.Decode(kPropertyContext, br);
      if prop1 > 256 then
        raise EJxlError.Create('Modular: invalid tree property');
      property_ := Integer(prop1) - 1;

      if property_ = -1 then begin
        // Leaf
        predictor := ans.Decode(kPredictorContext, br);
        if predictor >= kNumModularPredictors then
          raise EJxlError.Create('Modular: invalid predictor');
        node.Prop       := -1;
        node.SplitVal   := 0;
        node.LChild     := -1;
        node.RChild     := -1;
        node.Predictor  := Integer(predictor);
        node.Offset     := UnpackSigned(ans.Decode(kOffsetContext, br));
        mulLog          := ans.Decode(kMultiplierLogContext, br);
        if mulLog >= 31 then
          raise EJxlError.Create('Modular: invalid multiplier log');
        mulBits         := ans.Decode(kMultiplierBitsContext, br);
        node.Multiplier := (Int64(mulBits) + 1) shl mulLog;
        node.CtxId      := leafId;
        Inc(leafId);
        SetLength(tree, Length(tree) + 1);
        tree[High(tree)] := node;
        Continue;
      end;

      // Internal node
      splitval := Integer(UnpackSigned(ans.Decode(kSplitValContext, br)));
      node.Prop       := property_;
      node.SplitVal   := splitval;
      node.LChild     := Length(tree) + toDecode + 1;
      node.RChild     := Length(tree) + toDecode + 2;
      node.Predictor  := PRED_ZERO;
      node.Offset     := 0;
      node.Multiplier := 1;
      node.CtxId      := 0;
      SetLength(tree, Length(tree) + 1);
      tree[High(tree)] := node;
      Inc(toDecode, 2);
    end;

    if not ans.CheckFinalState then
      raise EJxlError.Create('Modular: MA tree ANS final state error');
  finally
    ans.Free;
  end;
end;

// Maximum property index referenced by any internal node (+1).
function TreeMaxProp(const tree: TMATree): Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to High(tree) do
    if (tree[i].Prop >= 0) and (tree[i].Prop + 1 > Result) then
      Result := tree[i].Prop + 1;
end;

// ---------------------------------------------------------------------------
// Decode one channel using the MA tree, predictors, WP and references.
// ---------------------------------------------------------------------------
procedure DecodeModularChannel(br: TBitReader; var img: TModImage;
                               chan, groupId: Integer; const tree: TMATree;
                               ans: TANSDecoder; const wpHdr: TWPHeader;
                               numProps: Integer);
var
  ch: ^TModChannel;
  x, y, i, idx, off, nRef: Integer;
  left, top, toptop, topleft, topright, leftleft, toprightright: Int64;
  wpPred, guess, v, prevGrad: Int64;
  props: array of Int64;
  wp: TWPState;
  useWP: Boolean;
  refChans: array of Integer;
  refCount: Integer;
  rp: ^TModChannel;
  rv, rvl, rvt, rvtl, rpred: Int64;
  node: TMATreeNode;
  pred, mult: Integer;
  poffset: Int64;
begin
  ch := @img.Channels[chan];
  if (ch^.Width = 0) or (ch^.Height = 0) then Exit;

  SetLength(props, numProps);
  for i := 0 to numProps - 1 do props[i] := 0;
  props[0] := chan;
  props[1] := groupId;

  // Determine whether WP is needed (any leaf uses it, or property 15 used).
  useWP := False;
  for i := 0 to High(tree) do begin
    if (tree[i].Prop = kWPProp) then useWP := True;
    if (tree[i].Prop = -1) and (tree[i].Predictor = PRED_WEIGHTED) then useWP := True;
  end;

  // Reference channels: prior channels with identical geometry.
  nRef := (numProps - kNumNonrefProperties) div kExtraPropsPerChannel;
  SetLength(refChans, 0);
  refCount := 0;
  i := chan - 1;
  while (i >= 0) and (refCount < nRef) do begin
    if (img.Channels[i].Width = ch^.Width) and
       (img.Channels[i].Height = ch^.Height) and
       (img.Channels[i].HShift = ch^.HShift) and
       (img.Channels[i].VShift = ch^.VShift) then begin
      SetLength(refChans, refCount + 1);
      refChans[refCount] := i;
      Inc(refCount);
    end;
    Dec(i);
  end;

  if useWP then WPInit(wp, wpHdr, ch^.Width, ch^.Height);

  for y := 0 to ch^.Height - 1 do begin
    props[2] := y;
    prevGrad := 0;   // property 9 persists across the row (init 0)
    for x := 0 to ch^.Width - 1 do begin
      if x > 0 then left := ch^.Data[y*ch^.Width + x-1]
      else if y > 0 then left := ch^.Data[(y-1)*ch^.Width + x]
      else left := 0;
      if y > 0 then top := ch^.Data[(y-1)*ch^.Width + x] else top := left;
      if (x > 0) and (y > 0) then topleft := ch^.Data[(y-1)*ch^.Width + x-1]
      else topleft := left;
      if (x+1 < ch^.Width) and (y > 0) then topright := ch^.Data[(y-1)*ch^.Width + x+1]
      else topright := top;
      if x > 1 then leftleft := ch^.Data[y*ch^.Width + x-2] else leftleft := left;
      if y > 1 then toptop := ch^.Data[(y-2)*ch^.Width + x] else toptop := top;
      if (x+2 < ch^.Width) and (y > 0) then toprightright := ch^.Data[(y-1)*ch^.Width + x+2]
      else toprightright := topright;

      // Properties 3..14
      off := 3;
      props[off] := x; Inc(off);                       // 3
      props[off] := Abs(top); Inc(off);                // 4
      props[off] := Abs(left); Inc(off);               // 5
      props[off] := top; Inc(off);                     // 6
      props[off] := left; Inc(off);                    // 7
      props[off] := left - prevGrad; Inc(off);         // 8 = left - prev gradient
      prevGrad := left + top - topleft;
      props[off] := prevGrad; Inc(off);                // 9 = gradient
      props[off] := left - topleft; Inc(off);          // 10
      props[off] := topleft - top; Inc(off);           // 11
      props[off] := top - topright; Inc(off);          // 12
      props[off] := top - toptop; Inc(off);            // 13
      props[off] := left - leftleft; Inc(off);         // 14  (off now 15)

      wpPred := 0;
      if useWP then
        wpPred := WPPredict(wp, x, y, ch^.Width, top, left, topright, topleft,
                            toptop, True, props, off);
      // off (15) now holds WP property (if useWP); advance past it.
      off := kNumNonrefProperties;                     // 16

      // Reference-channel properties
      for i := 0 to refCount - 1 do begin
        rp := @img.Channels[refChans[i]];
        rv := rp^.Data[y*rp^.Width + x];
        if x > 0 then rvl := rp^.Data[y*rp^.Width + x-1] else rvl := 0;
        if y > 0 then rvt := rp^.Data[(y-1)*rp^.Width + x] else rvt := rvl;
        if (x > 0) and (y > 0) then rvtl := rp^.Data[(y-1)*rp^.Width + x-1] else rvtl := rvl;
        rpred := ClampedGradient(rvl, rvt, rvtl);
        props[off] := Abs(rv);        Inc(off);
        props[off] := rv;             Inc(off);
        props[off] := Abs(rv-rpred);  Inc(off);
        props[off] := rv - rpred;     Inc(off);
      end;

      // Traverse MA tree
      if Length(tree) = 0 then begin
        pred := PRED_GRADIENT; poffset := 0; mult := 1; node.CtxId := 0;
      end else begin
        idx := 0;
        while True do begin
          node := tree[idx];
          if node.Prop = -1 then Break;
          if props[node.Prop] > node.SplitVal then idx := node.LChild
          else idx := node.RChild;
          if (idx < 0) or (idx > High(tree)) then begin node.Prop := -1; node.CtxId := 0; node.Predictor := PRED_GRADIENT; node.Offset := 0; node.Multiplier := 1; Break; end;
        end;
        pred    := node.Predictor;
        poffset := node.Offset;
        mult    := node.Multiplier;
      end;

      guess := poffset + PredictOne(pred, left, top, toptop, topleft, topright,
                                    leftleft, toprightright, wpPred);

      v := UnpackSigned(ans.Decode(node.CtxId, br)) * mult + guess;
      ch^.Data[y*ch^.Width + x] := Int32(v);

      if useWP then WPUpdateErrors(wp, v, x, y, ch^.Width);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Transform parsing (transform.h Transform::VisitFields)
// ---------------------------------------------------------------------------
type
  TSqueezeParam = TSqueezeParamPub;
  TModTransform = TModTransformPub;

procedure ReadTransform(br: TBitReader; var t: TModTransform);
var i: Integer;
begin
  FillChar(t, SizeOf(t), 0);
  t.Id := Integer(br.ReadU32(0,0, 1,0, 2,0, 3,0));   // Val(0..3), default 0
  if t.Id = 3 then raise EJxlError.Create('Modular: invalid transform id');

  if (t.Id = 0) or (t.Id = 1) then
    t.BeginC := Integer(br.ReadU32(0,3, 8,6, 72,10, 1096,13));

  if t.Id = 0 then begin
    t.RctType := Integer(br.ReadU32(6,0, 0,2, 2,4, 10,6));
    if t.RctType >= 42 then raise EJxlError.Create('Modular: invalid RCT type');
  end;

  if t.Id = 1 then begin
    t.NumC     := Integer(br.ReadU32(1,0, 3,0, 4,0, 1,13));
    t.NbColors := Integer(br.ReadU32(0,8, 256,10, 1280,12, 5376,16));
    t.NbDeltas := Integer(br.ReadU32(0,0, 1,8, 257,10, 1281,16));
    t.Predictor := br.ReadBits(4);
  end;

  if t.Id = 2 then begin
    t.NumSqueezes := Integer(br.ReadU32(0,0, 1,4, 9,6, 41,8));
    SetLength(t.Squeezes, t.NumSqueezes);
    for i := 0 to t.NumSqueezes - 1 do begin
      t.Squeezes[i].Horizontal := br.ReadBit;
      t.Squeezes[i].InPlace    := br.ReadBit;
      t.Squeezes[i].BeginC := Integer(br.ReadU32(0,3, 8,6, 72,10, 1096,13));
      t.Squeezes[i].NumC   := Integer(br.ReadU32(1,0, 2,0, 3,0, 4,4));
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Inverse RCT (rct.cc InvRCT / InvRCTRow) — all 42 types.
// ---------------------------------------------------------------------------
procedure InverseRCT(var img: TModImage; rctType: Integer; beginChan: Integer);
var
  perm, custom, second, third: Integer;
  m, x, y, w, h: Integer;
  o0, o1, o2: Integer;
  i0, i1, i2: ^TModChannel;
  oo0, oo1, oo2: ^TModChannel;
  va, vb, vc, vYY, vCo, vCg, tmp, vGr, vBl, vRd: Int64;
begin
  if beginChan + 2 >= img.NumChannels then Exit;
  perm   := rctType div 7;
  custom := rctType mod 7;
  m := beginChan;

  o0 := m + (perm mod 3);
  o1 := m + ((perm + 1 + perm div 3) mod 3);
  o2 := m + ((perm + 2 - perm div 3) mod 3);

  // custom == 0 (permute-only) is handled by RCTPermuteOnly before this call.
  second := custom shr 1;
  third  := custom and 1;
  w := img.Channels[m].Width;
  h := img.Channels[m].Height;
  i0 := @img.Channels[m]; i1 := @img.Channels[m+1]; i2 := @img.Channels[m+2];
  oo0 := @img.Channels[o0]; oo1 := @img.Channels[o1]; oo2 := @img.Channels[o2];

  for y := 0 to h - 1 do
    for x := 0 to w - 1 do begin
      va := i0^.Data[y*w + x];
      vb := i1^.Data[y*w + x];
      vc := i2^.Data[y*w + x];
      if custom = 6 then begin
        vYY := va; vCo := vb; vCg := vc;
        tmp := vYY - ASR(vCg, 1);
        vGr := vCg + tmp;
        vBl := tmp - ASR(vCo, 1);
        vRd := vBl + vCo;
        oo0^.Data[y*w + x] := Int32(vRd);
        oo1^.Data[y*w + x] := Int32(vGr);
        oo2^.Data[y*w + x] := Int32(vBl);
      end else begin
        if third <> 0 then vc := vc + va;
        if second = 1 then vb := vb + va
        else if second = 2 then vb := vb + ASR(va + vc, 1);
        oo0^.Data[y*w + x] := Int32(va);
        oo1^.Data[y*w + x] := Int32(vb);
        oo2^.Data[y*w + x] := Int32(vc);
      end;
    end;
end;

// Permutation-only RCT (custom==0): reorder three channels.
procedure RCTPermuteOnly(var img: TModImage; rctType, beginChan: Integer);
var perm, m, o0, o1, o2: Integer; c0, c1, c2: TModChannel;
begin
  perm := rctType div 7;
  m := beginChan;
  o0 := m + (perm mod 3);
  o1 := m + ((perm + 1 + perm div 3) mod 3);
  o2 := m + ((perm + 2 - perm div 3) mod 3);
  c0 := img.Channels[m]; c1 := img.Channels[m+1]; c2 := img.Channels[m+2];
  img.Channels[o0] := c0;
  img.Channels[o1] := c1;
  img.Channels[o2] := c2;
end;

// ---------------------------------------------------------------------------
// Channel-array helpers
// ---------------------------------------------------------------------------
procedure ChanInsert(var img: TModImage; pos: Integer; const ch: TModChannel);
var i: Integer;
begin
  SetLength(img.Channels, img.NumChannels + 1);
  for i := img.NumChannels downto pos + 1 do
    img.Channels[i] := img.Channels[i - 1];
  img.Channels[pos] := ch;
  Inc(img.NumChannels);
end;

procedure ChanDelete(var img: TModImage; pos, count: Integer);
var i: Integer;
begin
  for i := pos to img.NumChannels - count - 1 do
    img.Channels[i] := img.Channels[i + count];
  Dec(img.NumChannels, count);
  SetLength(img.Channels, img.NumChannels);
end;

// ---------------------------------------------------------------------------
// Squeeze (modular/transform/squeeze.cc)
// ---------------------------------------------------------------------------
function SmoothTendency(B, a, n: Int64): Int64;
var diff: Int64;
begin
  diff := 0;
  if (B >= a) and (a >= n) then begin
    diff := (4*B - 3*n - a + 6) div 12;
    if diff - (diff and 1) > 2 * (B - a) then diff := 2 * (B - a) + 1;
    if diff + (diff and 1) > 2 * (a - n) then diff := 2 * (a - n);
  end else if (B <= a) and (a <= n) then begin
    diff := (4*B - 3*n - a - 6) div 12;
    if diff + (diff and 1) < 2 * (B - a) then diff := 2 * (B - a) - 1;
    if diff - (diff and 1) < 2 * (a - n) then diff := 2 * (a - n);
  end;
  Result := diff;
end;

procedure InvHSqueezeCh(var img: TModImage; c, rc: Integer);
var
  chout: TModChannel;
  x, y: Integer;
  avg, nextAvg, left, tendency, diff, A: Int64;
begin
  if img.Channels[rc].Width = 0 then begin
    Dec(img.Channels[c].HShift);
    Exit;
  end;
  InitModChannel(chout, img.Channels[c].Width + img.Channels[rc].Width,
                 img.Channels[c].Height, img.Channels[c].HShift - 1,
                 img.Channels[c].VShift);
  for y := 0 to chout.Height - 1 do begin
    for x := 0 to img.Channels[rc].Width - 1 do begin
      avg := img.Channels[c].Data[y * img.Channels[c].Width + x];
      if x + 1 < img.Channels[c].Width then
        nextAvg := img.Channels[c].Data[y * img.Channels[c].Width + x + 1]
      else nextAvg := avg;
      if x > 0 then left := chout.Data[y * chout.Width + (x shl 1) - 1]
      else left := avg;
      tendency := SmoothTendency(left, avg, nextAvg);
      diff := img.Channels[rc].Data[y * img.Channels[rc].Width + x] + tendency;
      // avg + diff/2 with truncation toward zero (C++ semantics)
      A := avg + (diff div 2);
      chout.Data[y * chout.Width + (x shl 1)]     := Int32(A);
      chout.Data[y * chout.Width + (x shl 1) + 1] := Int32(A - diff);
    end;
    if (chout.Width and 1) <> 0 then
      chout.Data[y * chout.Width + chout.Width - 1] :=
        img.Channels[c].Data[y * img.Channels[c].Width + img.Channels[c].Width - 1];
  end;
  img.Channels[c] := chout;
end;

procedure InvVSqueezeCh(var img: TModImage; c, rc: Integer);
var
  chout: TModChannel;
  x, y: Integer;
  avg, nextAvg, top, tendency, diff, outv: Int64;
begin
  if img.Channels[rc].Height = 0 then begin
    Dec(img.Channels[c].VShift);
    Exit;
  end;
  InitModChannel(chout, img.Channels[c].Width,
                 img.Channels[c].Height + img.Channels[rc].Height,
                 img.Channels[c].HShift, img.Channels[c].VShift - 1);
  for y := 0 to img.Channels[rc].Height - 1 do
    for x := 0 to img.Channels[c].Width - 1 do begin
      avg := img.Channels[c].Data[y * img.Channels[c].Width + x];
      if y + 1 < img.Channels[c].Height then
        nextAvg := img.Channels[c].Data[(y + 1) * img.Channels[c].Width + x]
      else nextAvg := avg;
      if y > 0 then top := chout.Data[((y shl 1) - 1) * chout.Width + x]
      else top := avg;
      tendency := SmoothTendency(top, avg, nextAvg);
      diff := img.Channels[rc].Data[y * img.Channels[rc].Width + x] + tendency;
      outv := avg + (diff div 2);
      chout.Data[(y shl 1) * chout.Width + x]       := Int32(outv);
      chout.Data[((y shl 1) + 1) * chout.Width + x] := Int32(outv - diff);
    end;
  if (chout.Height and 1) <> 0 then begin
    y := img.Channels[c].Height - 1;
    for x := 0 to img.Channels[c].Width - 1 do
      chout.Data[(y shl 1) * chout.Width + x] :=
        img.Channels[c].Data[y * img.Channels[c].Width + x];
  end;
  img.Channels[c] := chout;
end;

procedure DefaultSqueezeParams(var t: TModTransform; const img: TModImage);
const kMaxFirstPreviewSize = 8;
var
  nb, w, h: Integer;
  p: TSqueezeParam;
  procedure Push(const pp: TSqueezeParam);
  begin
    SetLength(t.Squeezes, Length(t.Squeezes) + 1);
    t.Squeezes[High(t.Squeezes)] := pp;
  end;
begin
  SetLength(t.Squeezes, 0);
  nb := img.NumChannels - img.NumMetaChannels;
  w := img.Channels[img.NumMetaChannels].Width;
  h := img.Channels[img.NumMetaChannels].Height;
  if (nb > 2) and (img.Channels[img.NumMetaChannels + 1].Width = w) and
     (img.Channels[img.NumMetaChannels + 1].Height = h) then begin
    p.Horizontal := True; p.InPlace := False;
    p.BeginC := img.NumMetaChannels + 1; p.NumC := 2;
    Push(p);
    p.Horizontal := False;
    Push(p);
  end;
  p.BeginC := img.NumMetaChannels;
  p.NumC := nb;
  p.InPlace := True;
  if w <= h then
    if h > kMaxFirstPreviewSize then begin
      p.Horizontal := False; Push(p); h := (h + 1) div 2;
    end;
  while (w > kMaxFirstPreviewSize) or (h > kMaxFirstPreviewSize) do begin
    if w > kMaxFirstPreviewSize then begin
      p.Horizontal := True; Push(p); w := (w + 1) div 2;
    end;
    if h > kMaxFirstPreviewSize then begin
      p.Horizontal := False; Push(p); h := (h + 1) div 2;
    end;
  end;
  t.NumSqueezes := Length(t.Squeezes);
end;

procedure MetaSqueeze(var img: TModImage; var t: TModTransform);
var
  i, c, beginc, endc, offset, w, h: Integer;
  ph: TModChannel;
begin
  if Length(t.Squeezes) = 0 then
    DefaultSqueezeParams(t, img);
  for i := 0 to High(t.Squeezes) do begin
    beginc := t.Squeezes[i].BeginC;
    endc   := beginc + t.Squeezes[i].NumC - 1;
    if (beginc < 0) or (endc >= img.NumChannels) then
      raise EJxlError.Create('Modular: invalid squeeze channel range');
    if beginc < img.NumMetaChannels then begin
      if (endc >= img.NumMetaChannels) or not t.Squeezes[i].InPlace then
        raise EJxlError.Create('Modular: invalid meta squeeze');
      Inc(img.NumMetaChannels, t.Squeezes[i].NumC);
    end;
    if t.Squeezes[i].InPlace then offset := endc + 1
    else offset := img.NumChannels;
    for c := beginc to endc do begin
      w := img.Channels[c].Width;
      h := img.Channels[c].Height;
      if (w = 0) or (h = 0) then
        raise EJxlError.Create('Modular: squeezing empty channel');
      if t.Squeezes[i].Horizontal then begin
        img.Channels[c].Width := (w + 1) div 2;
        if img.Channels[c].HShift >= 0 then Inc(img.Channels[c].HShift);
        w := w - (w + 1) div 2;
      end else begin
        img.Channels[c].Height := (h + 1) div 2;
        if img.Channels[c].VShift >= 0 then Inc(img.Channels[c].VShift);
        h := h - (h + 1) div 2;
      end;
      SetLength(img.Channels[c].Data,
                img.Channels[c].Width * img.Channels[c].Height);
      InitModChannel(ph, w, h, img.Channels[c].HShift, img.Channels[c].VShift);
      ChanInsert(img, offset + (c - beginc), ph);
    end;
  end;
end;

procedure InvSqueezeAll(var img: TModImage; const t: TModTransform);
var
  i, c, beginc, endc, offset: Integer;
begin
  for i := High(t.Squeezes) downto 0 do begin
    beginc := t.Squeezes[i].BeginC;
    endc   := beginc + t.Squeezes[i].NumC - 1;
    if t.Squeezes[i].InPlace then offset := endc + 1
    else offset := img.NumChannels + beginc - endc - 1;
    if beginc < img.NumMetaChannels then
      Dec(img.NumMetaChannels, t.Squeezes[i].NumC);
    for c := beginc to endc do begin
      if t.Squeezes[i].Horizontal then
        InvHSqueezeCh(img, c, offset + c - beginc)
      else
        InvVSqueezeCh(img, c, offset + c - beginc);
    end;
    ChanDelete(img, offset, endc - beginc + 1);
  end;
end;

// ---------------------------------------------------------------------------
// Palette (modular/transform/palette.{h,cc})
// ---------------------------------------------------------------------------
const
  kDeltaPalette: array[0..71, 0..2] of Integer = (
    (0,0,0),(4,4,4),(11,0,0),(0,0,-13),(0,-12,0),(-10,-10,-10),
    (-18,-18,-18),(-27,-27,-27),(-18,-18,0),(0,0,-32),(-32,0,0),(-37,-37,-37),
    (0,-32,-32),(24,24,45),(50,50,50),(-45,-24,-24),(-24,-45,-45),(0,-24,-24),
    (-34,-34,0),(-24,0,-24),(-45,-45,-24),(64,64,64),(-32,0,-32),(0,-32,0),
    (-32,0,32),(-24,-45,-24),(45,24,45),(24,-24,-45),(-45,-24,24),(80,80,80),
    (64,0,0),(0,0,-64),(0,-64,-64),(-24,-24,45),(96,96,96),(64,64,0),
    (45,-24,-24),(34,-34,0),(112,112,112),(24,-45,-45),(45,45,-24),(0,-32,32),
    (24,-24,45),(0,96,96),(45,-24,24),(24,-45,-24),(-24,-45,24),(0,-64,0),
    (96,0,0),(128,128,128),(64,0,64),(144,144,144),(96,96,0),(-36,-36,36),
    (45,-24,-45),(45,-45,-24),(0,0,-96),(0,128,128),(0,96,0),(45,24,-45),
    (-128,0,0),(24,-45,24),(-45,24,-45),(64,0,-64),(64,-64,-64),(96,0,96),
    (45,-45,24),(24,45,-45),(64,64,-64),(128,128,0),(0,0,-128),(-24,45,-45));

function GetPaletteValue(const img: TModImage; index: Integer; c: Integer;
                         paletteSize, bitDepth: Integer): Int64;
const
  kLargeCube = 5;
  kSmallCube = 4;
  kLargeCubeOffset = kSmallCube * kSmallCube * kSmallCube;   // 64
var
  res: Int64;
begin
  if index < 0 then begin
    if c >= 3 then begin Result := 0; Exit; end;
    index := -(index + 1);
    index := index mod (1 + 2 * 71);
    res := kDeltaPalette[(index + 1) shr 1][c];
    if (index and 1) = 0 then res := -res;
    if bitDepth > 8 then
      res := res * (Int64(1) shl (bitDepth - 8));
    Result := res;
  end else if (paletteSize <= index) and (index < paletteSize + kLargeCubeOffset) then begin
    if c >= 3 then begin Result := 0; Exit; end;
    Dec(index, paletteSize);
    index := index shr (c * 2);                    // kSmallCubeBits = 2
    res := ((Int64(index mod kSmallCube) * ((Int64(1) shl bitDepth) - 1)) shr 2);
    if bitDepth - 3 > 0 then
      Result := res + (Int64(1) shl (bitDepth - 3))
    else
      Result := res + 1;
  end else if index >= paletteSize + kLargeCubeOffset then begin
    if c >= 3 then begin Result := 0; Exit; end;
    Dec(index, paletteSize + kLargeCubeOffset);
    case c of
      1: index := index div kLargeCube;
      2: index := index div (kLargeCube * kLargeCube);
    end;
    Result := (Int64(index mod kLargeCube) * ((Int64(1) shl bitDepth) - 1)) shr 2;
  end else
    Result := img.Channels[0].Data[c * img.Channels[0].Width + index];
end;

procedure MetaPalette(var img: TModImage; var t: TModTransform);
var
  nb: Integer;
  pch: TModChannel;
begin
  nb := t.NumC;
  if t.BeginC >= img.NumMetaChannels then
    Inc(img.NumMetaChannels)
  else begin
    if t.BeginC + nb - 1 >= img.NumMetaChannels then
      raise EJxlError.Create('Modular: palette mixes meta/non-meta');
    Inc(img.NumMetaChannels, 2 - nb);
  end;
  ChanDelete(img, t.BeginC + 1, nb - 1);
  InitModChannel(pch, t.NbColors + t.NbDeltas, nb, -1, -1);
  ChanInsert(img, 0, pch);
end;

procedure InvPalette(var img: TModImage; const t: TModTransform;
                     const wpHdr: TWPHeader);
var
  nb, c0, w, h, c, x, y, index: Integer;
  ch: TModChannel;
  useWP: Boolean;
  wp: TWPState;
  left, top, topleft, topright, leftleft, toptop, toprightright: Int64;
  guess, val, pe: Int64;
  pred: Integer;
  idx: array of Int32;
  pch: ^TModChannel;
  dummyProps: array[0..0] of Int64;
  bd: Integer;
begin
  nb := img.Channels[0].Height;
  c0 := t.BeginC + 1;
  w := img.Channels[c0].Width;
  h := img.Channels[c0].Height;
  // Expand to nb channels (the index channel is reused as channel 0 output).
  for c := 1 to nb - 1 do begin
    InitModChannel(ch, w, h, img.Channels[c0].HShift, img.Channels[c0].VShift);
    ChanInsert(img, c0 + 1, ch);
  end;

  // Copy out the indices.
  SetLength(idx, w * h);
  if w * h > 0 then
    Move(img.Channels[c0].Data[0], idx[0], w * h * SizeOf(Int32));

  pred  := t.Predictor;
  useWP := pred = PRED_WEIGHTED;
  bd := img.BitDepth;
  if bd > 24 then bd := 24;

  // InvPalette: a one-channel palette without deltas or prediction clamps
  // the index to the palette
  if (nb = 1) and (t.NbDeltas = 0) and (pred = PRED_ZERO) then
    for x := 0 to w * h - 1 do
    begin
      if idx[x] < 0 then idx[x] := 0
      else if idx[x] > img.Channels[0].Width - 1 then
        idx[x] := img.Channels[0].Width - 1;
    end;

  for c := 0 to nb - 1 do begin
    pch := @img.Channels[c0 + c];
    if useWP then WPInit(wp, wpHdr, w, h);
    for y := 0 to h - 1 do
      for x := 0 to w - 1 do begin
        index := idx[y * w + x];
        pe := GetPaletteValue(img, index, c, img.Channels[0].Width, bd);
        if index < t.NbDeltas then begin
          // delta entry: prediction (no tree) + palette delta
          if x > 0 then left := pch^.Data[y*w + x-1]
          else if y > 0 then left := pch^.Data[(y-1)*w + x]
          else left := 0;
          if y > 0 then top := pch^.Data[(y-1)*w + x] else top := left;
          if (x > 0) and (y > 0) then topleft := pch^.Data[(y-1)*w + x-1]
          else topleft := left;
          if (x+1 < w) and (y > 0) then topright := pch^.Data[(y-1)*w + x+1]
          else topright := top;
          if x > 1 then leftleft := pch^.Data[y*w + x-2] else leftleft := left;
          if y > 1 then toptop := pch^.Data[(y-2)*w + x] else toptop := top;
          if (x+2 < w) and (y > 0) then toprightright := pch^.Data[(y-1)*w + x+2]
          else toprightright := topright;
          if useWP then
            guess := WPPredict(wp, x, y, w, top, left, topright,
                               topleft, toptop, False, dummyProps, 0)
          else
            guess := PredictOne(pred, left, top, toptop, topleft, topright,
                                leftleft, toprightright, 0);
          val := guess + pe;
        end else
          val := pe;
        pch^.Data[y*w + x] := Int32(val);
        if useWP then WPUpdateErrors(wp, val, x, y, w);
      end;
  end;

  if c0 >= img.NumMetaChannels then
    Dec(img.NumMetaChannels)
  else
    Dec(img.NumMetaChannels, 2 - nb);
  ChanDelete(img, 0, 1);
end;

// ---------------------------------------------------------------------------
// ModularDecodeImage — decode channels of an already-laid-out image.
// Reads GroupHeader; uses the global tree if requested, else a local tree.
// ---------------------------------------------------------------------------
procedure ApplyInverseTransformList(var img: TModImage;
                                    const transforms: TModTransformList);
var i: Integer; wpHdr: TWPHeader;
begin
  // Default WP header (only used by delta-palette with the WP predictor).
  wpHdr.p1C := 16; wpHdr.p2C := 10; wpHdr.p3Ca := 7; wpHdr.p3Cb := 7;
  wpHdr.p3Cc := 7; wpHdr.p3Cd := 0; wpHdr.p3Ce := 0;
  wpHdr.w[0] := $d; wpHdr.w[1] := $c; wpHdr.w[2] := $c; wpHdr.w[3] := $c;
  for i := High(transforms) downto 0 do
    case transforms[i].Id of
      0: if (transforms[i].RctType mod 7) = 0 then
           RCTPermuteOnly(img, transforms[i].RctType, transforms[i].BeginC)
         else
           InverseRCT(img, transforms[i].RctType, transforms[i].BeginC);
      1: InvPalette(img, transforms[i], wpHdr);
      2: InvSqueezeAll(img, transforms[i]);
    end;
end;

procedure UndoModularTransforms(var img: TModImage; const hdr: TModGroupHeader);
var i: Integer;
begin
  for i := High(hdr.Transforms) downto 0 do
    case hdr.Transforms[i].Id of
      0: if (hdr.Transforms[i].RctType mod 7) = 0 then
           RCTPermuteOnly(img, hdr.Transforms[i].RctType, hdr.Transforms[i].BeginC)
         else
           InverseRCT(img, hdr.Transforms[i].RctType, hdr.Transforms[i].BeginC);
      1: InvPalette(img, hdr.Transforms[i], hdr.WP);
      2: InvSqueezeAll(img, hdr.Transforms[i]);
    end;
end;

procedure ModularGenericDecompress(br: TBitReader; var img: TModImage;
                                   const globalTree: TMATree;
                                   globalAns: TANSDecoder; streamId: Integer;
                                   undoTransforms: Boolean;
                                   maxChanSize: Integer;
                                   out hdr: TModGroupHeader);
var
  i, numTransforms, numProps, maxProp, distMul, numLeaves, nDecode,
    numChans: Integer;
  ownAns: Boolean;
  tree: TMATree;
  ans: TANSDecoder;
begin
  hdr.UseGlobalTree := False;
  SetLength(hdr.Transforms, 0);
  ReadWPHeaderDefault(hdr.WP);
  if img.NumChannels = 0 then Exit;   // libjxl: empty image -> nothing to read

  // GroupHeader: use_global_tree, wp_header, transforms.
  hdr.UseGlobalTree := br.ReadBit;
  ReadWPHeader(br, hdr.WP);
  numTransforms := Integer(br.ReadU32(0,0, 1,0, 2,4, 18,8));
  SetLength(hdr.Transforms, numTransforms);
  for i := 0 to numTransforms - 1 do
    ReadTransform(br, hdr.Transforms[i]);

  // MetaApply: reshape the channel list before decoding.
  for i := 0 to numTransforms - 1 do
    case hdr.Transforms[i].Id of
      0: if hdr.Transforms[i].BeginC + 2 >= img.NumChannels then
           raise EJxlError.Create('Modular: RCT channel range');
      1: MetaPalette(img, hdr.Transforms[i]);
      2: MetaSqueeze(img, hdr.Transforms[i]);
    end;

  // Channels coded here: up to the first non-empty non-meta channel larger
  // than maxChanSize (libjxl break semantics); empty channels are skipped.
  nDecode := img.NumChannels;
  numChans := 0;
  distMul := 0;
  for i := 0 to img.NumChannels - 1 do
  begin
    if (img.Channels[i].Width = 0) or (img.Channels[i].Height = 0) then Continue;
    if (i >= img.NumMetaChannels) and
       ((img.Channels[i].Width > maxChanSize) or
        (img.Channels[i].Height > maxChanSize)) then
    begin
      nDecode := i;
      Break;
    end;
    if img.Channels[i].Width > distMul then distMul := img.Channels[i].Width;
    Inc(numChans);
  end;

  if numChans > 0 then
  begin
    if hdr.UseGlobalTree then
    begin
      if (Length(globalTree) = 0) or (globalAns = nil) then
        raise EJxlError.Create('Modular: global tree requested but not available');
      tree   := globalTree;
      ans    := globalAns;
      ownAns := False;
      ans.BeginReader(br, Cardinal(distMul));
    end
    else
    begin
      ReadMATree(br, tree);
      numLeaves := (Length(tree) + 1) div 2;
      if numLeaves < 1 then numLeaves := 1;
      ans    := TANSDecoder.Create;
      ownAns := True;
      ans.Init(br, numLeaves, Cardinal(distMul));
    end;

    // Property count (FilterTree rounding).
    maxProp := TreeMaxProp(tree);
    if maxProp > kNumNonrefProperties then
      numProps := ((maxProp - kNumNonrefProperties + kExtraPropsPerChannel - 1)
                   div kExtraPropsPerChannel) * kExtraPropsPerChannel
                  + kNumNonrefProperties
    else
      numProps := kNumNonrefProperties;

    try
      for i := 0 to nDecode - 1 do
        DecodeModularChannel(br, img, i, streamId, tree, ans, hdr.WP, numProps);
      if not ans.CheckFinalState then
        raise EJxlError.Create('Modular: channel ANS final state error');
    finally
      if ownAns then ans.Free;
    end;
  end;

  if undoTransforms then
  begin
    UndoModularTransforms(img, hdr);
    SetLength(hdr.Transforms, 0);
  end;
end;

procedure ModularDecodeImageOpts(br: TBitReader; var img: TModImage;
                                 const globalTree: TMATree;
                                 globalAns: TANSDecoder;
                                 groupId: Integer; undoTransforms: Boolean;
                                 maxChanSize: Integer;
                                 out transformsOut: TModTransformList);
var hdr: TModGroupHeader;
begin
  ModularGenericDecompress(br, img, globalTree, globalAns, groupId,
                           undoTransforms, maxChanSize, hdr);
  transformsOut := hdr.Transforms;
end;

procedure ModularDecodeImage(br: TBitReader; var img: TModImage;
                             const globalTree: TMATree; globalAns: TANSDecoder;
                             groupId: Integer; undoTransforms: Boolean);
var dummy: TModTransformList;
begin
  ModularDecodeImageOpts(br, img, globalTree, globalAns, groupId,
                         undoTransforms, MaxInt, dummy);
end;

// ---------------------------------------------------------------------------
// DecodeModularImage — standalone modular decode (own tree, no globals).
// ---------------------------------------------------------------------------
procedure DecodeModularImage(br: TBitReader; var img: TModImage;
                             numColorChannels: Integer;
                             numExtraChannels: Integer;
                             xsize, ysize: Integer;
                             bitDepth: Integer);
var
  total, i: Integer;
  emptyTree: TMATree;
begin
  total := numColorChannels + numExtraChannels;
  img.NumChannels := total;
  img.NumMetaChannels := 0;
  img.BitDepth := bitDepth;
  SetLength(img.Channels, total);
  for i := 0 to total - 1 do
    InitModChannel(img.Channels[i], xsize, ysize, 0, 0);
  SetLength(emptyTree, 0);
  ModularDecodeImage(br, img, emptyTree, nil, 0, True);
end;

end.
