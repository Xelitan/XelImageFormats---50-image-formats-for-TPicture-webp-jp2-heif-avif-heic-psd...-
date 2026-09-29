unit Av1.Decoder;

// AV1 intra keyframe decoder (4:2:0 / 4:4:4). Partition recursion, neighbour
// entropy contexts, intra prediction with reconstructed edges, coefficient
// decode, inverse transform, and the full post-filter chain (deblock, CDEF,
// loop restoration). Decodes a still AVIF frame (concatenated OBUs) to 8-bit
// planar YUV. Validated bit-exact against dav1d.

{$mode delphi}{$H+}
{$RANGECHECKS OFF}{$OVERFLOWCHECKS OFF}

interface

type
  // 8-bit planar output. Y stride = Width, chroma stride = ChromaW.
  TAv1Frame = record
    Width, Height, SsH, SsV, ChromaW, ChromaH, NumPlanes, BitDepth: Integer;
    Y, U, V: array of Word;   // native bit depth (8/10/12), one sample per element
  end;

// Decode a concatenated OBU buffer (sequence header + frame) into F.
function Av1Decode(Data: PByte; Size: NativeInt; out F: TAv1Frame): Boolean;

implementation

uses
  SysUtils, Classes, Av1.Bits, Av1.Obu, Av1.Frame, Av1.Cdf, Av1.Msac, Av1.Recon, Av1.Itx, Av1.Ipred, Av1.LoopFilter;

const
  // Block levels.
  BL_128X128 = 0; BL_64X64 = 1; BL_32X32 = 2; BL_16X16 = 3; BL_8X8 = 4;
  // Partitions.
  PARTITION_NONE = 0; PARTITION_H = 1; PARTITION_V = 2; PARTITION_SPLIT = 3;
  PART_T_TOP = 4; PART_T_BOTTOM = 5; PART_T_LEFT = 6; PART_T_RIGHT = 7;
  PART_H4 = 8; PART_V4 = 9;
  PartitionTypeCount: array[0..4] of Integer = (7, 9, 9, 9, 3);
  // intra-edge flags (dav1d EdgeFlags): per-layout TOP_HAS_RIGHT / LEFT_HAS_BOTTOM.
  E444TR = 1; E422TR = 2; E420TR = 4; E444LB = 8; E422LB = 16; E420LB = 32;
  ALLTR = E444TR or E422TR or E420TR;   // 7
  ALLLB = E444LB or E422LB or E420LB;   // 56
  // dav1d_sgr_params nonzero flags (for SGR weight conditionals)
  SgrP0: array[0..15] of Boolean = (True,True,True,True,True,True,True,True,True,True,False,False,False,False,True,True);
  SgrP1: array[0..15] of Boolean = (True,True,True,True,True,True,True,True,True,True,True,True,True,True,False,False);
  // BlockSize per square BL (NONE): 64,32,16,8.
  BsForBl: array[1..4] of Integer = (3, 7, 12, 17);   // BS_64x64,32,16,8
  // TX per square BL.
  TxForBl: array[1..4] of Integer = (TX_64X64, TX_32X32, TX_16X16, TX_8X8);
  IntraModeCtx: array[0..12] of Byte = (0,1,2,3,4,4,4,4,3,0,1,2,0);
  AlPartCtx: array[0..1, 0..4, 0..9] of Byte = (
    ( ($00,$00,$10,$00,$00,$10,$10,$10,$00,$00),
      ($10,$10,$18,$00,$10,$18,$18,$18,$10,$1c),
      ($18,$18,$1c,$00,$18,$1c,$1c,$1c,$18,$1e),
      ($1c,$1c,$1e,$00,$1c,$1e,$1e,$1e,$1c,$1f),
      ($1e,$1e,$1f,$1f,$00,$00,$00,$00,$00,$00) ),
    ( ($00,$10,$00,$00,$10,$10,$00,$10,$00,$00),
      ($10,$18,$10,$00,$18,$18,$10,$18,$1c,$10),
      ($18,$1c,$18,$00,$1c,$1c,$18,$1c,$1e,$18),
      ($1c,$1e,$1c,$00,$1e,$1e,$1c,$1e,$1f,$1c),
      ($1e,$1f,$1e,$1f,$00,$00,$00,$00,$00,$00) ));
  CflAllowedMask =
    (1 shl 7) or (1 shl 8) or (1 shl 9) or (1 shl 11) or (1 shl 12) or
    (1 shl 13) or (1 shl 14) or (1 shl 15) or (1 shl 16) or (1 shl 17) or
    (1 shl 18) or (1 shl 19) or (1 shl 20) or (1 shl 21);

{$I Av1.Dq8.inc}
{$I Av1.DqHi.inc}
{$I FilterIntraTaps.inc}

const
  FilterModeToYMode: array[0..4] of Byte = (0, 1, 2, 6, 0);
  FILTER_PRED = 13;
  ModeToAngle: array[0..7] of Integer = (90, 180, 45, 135, 113, 157, 203, 67);
  // BS enum -> largest luma tx (col 0) and chroma tx per layout (dav1d
  // max_txfm_size_for_bs). MaxTxCh[layout][bs], layout: 0=444,1=422,2=420.
  MaxTxLuma: array[0..21] of Integer = (4,4,4,4,12,18,11,3,10,16,17,9,2,8,14,15,7,1,6,13,5,0);
  MaxTxCh444: array[0..21] of Integer = (3,3,3,3,3,10,3,3,10,16,9,9,2,8,14,15,7,1,6,13,5,0);
  MaxTxCh422: array[0..21] of Integer = (3,3,0,3,3,10,0,9,2,8,0,0,7,1,6,0,0,5,0,0,0,0);
  MaxTxCh420: array[0..21] of Integer = (3,3,9,3,10,16,9,2,8,14,15,7,1,6,6,13,5,0,0,5,0,0);
  // txfm_dimensions fields indexed by RectTxfmSize (0..18): max category, sub tx,
  // and log2 width/height (for tx-size context).
  TxDmax: array[0..18] of Integer = (0,1,2,3,4, 1,1,2,2,3,3,4,4, 2,2,3,3,4,4);
  TxDsub: array[0..18] of Integer = (0,0,1,2,3, 0,0,1,1,2,2,3,3, 5,6,7,8,9,10);
  TxDlw:  array[0..18] of Integer = (0,1,2,3,4, 0,1,1,2,2,3,3,4, 0,2,1,3,2,4);
  TxDlh:  array[0..18] of Integer = (0,1,2,3,4, 1,0,2,1,3,2,4,3, 2,0,3,1,4,2);
  // CDEF tap directions as (dy,dx) per pass; row index = dir+2 maps the 8 dirs
  // (dav1d_cdef_directions, table stride 12 decoded to dy/dx).
  CdefDir: array[0..11, 0..1, 0..1] of Integer = (
    ((1,0),(2,0)), ((1,0),(2,-1)), ((-1,1),(-2,2)), ((0,1),(-1,2)),
    ((0,1),(0,2)), ((0,1),(1,2)), ((1,1),(2,2)), ((1,0),(2,1)),
    ((1,0),(2,0)), ((1,0),(2,-1)), ((-1,1),(-2,2)), ((0,1),(-1,2)));
  CdefDivTable: array[0..6] of Integer = (840, 420, 280, 210, 168, 140, 120);
  // BsLut[log2(bw4)][log2(bh4)] -> BS enum (-1 = invalid aspect).
  BsLut: array[0..4, 0..4] of Integer = (
    (21, 20, 19, -1, -1),   // w=4
    (18, 17, 16, 15, -1),   // w=8
    (14, 13, 12, 11, 10),   // w=16
    (-1,  9,  8,  7,  6),   // w=32
    (-1, -1,  5,  4,  3));  // w=64

var
  Seq: TAv1SequenceHeader;
  Fh: TAv1FrameHeader;
  Msac: TMsac;
  Cdf: TCdfContext;
  FrmW, FrmH, FrmW4, FrmH4: Integer;   // luma dims (px, and 4px units)
  ssH, ssV: Integer;                   // chroma subsampling (0/1)
  FrmWc, FrmHc, FrmW4c, FrmH4c: Integer; // chroma plane dims (px, and 4px units)
  MaxTxChSel: array[0..21] of Integer;   // chroma tx table for the frame layout
  TileColMi, TileRowMi, TileColEndMi, TileRowEndMi: Integer;  // current tile bounds (luma mi)
  PredX0, PredY0, PredX1, PredY1: Integer;   // current plane's tile bounds (plane px)
  Yp, Up, Vp: array of Word;   // reconstructed planes (chroma at its own res, native bit depth)
  DqYDc, DqYAc, DqUDc, DqUAc, DqVDc, DqVAc: Integer;
  QIdxZero: Boolean;
  // neighbour context (frame-wide)
  partA, partL: array[0..255] of Byte;   // partition ctx, absolute (bx>>1) units
  skipA, skipL, modeA, modeL: array[0..255] of Byte;
  uvmodeA, uvmodeL: array[0..255] of Byte;   // neighbour chroma uvmode (init DC)
  txiA, txiL: array[0..255] of ShortInt;   // neighbour intra tx log-dim (init -1)
  // palette neighbour context (all LUMA-coord indexed, aomedia bug 2183)
  palSzA, palSzL: array[0..255] of Byte;         // luma palette size
  palSzUvA, palSzUvL: array[0..255] of Byte;     // uv palette size
  alPalA: array[0..255, 0..2, 0..15] of Word;    // above block palettes [bx4][pl][col]
  alPalL: array[0..255, 0..2, 0..15] of Word;    // left  block palettes [by4][pl][col]
  // current block palette
  curPal: array[0..2, 0..15] of Word;            // colours (Y, U, V)
  curPalSz: array[0..1] of Integer;              // sizes (Y, UV)
  palIdxY: array[0..64*64-1] of Byte;
  palIdxC: array[0..64*64-1] of Byte;   // 4:4:4 chroma up to 64x64
  // loop-restoration reference units (for subexp coding); bits consumed only.
  lrRefFV, lrRefFH: array[0..2, 0..2] of Integer;
  lrRefSgr: array[0..2, 0..1] of Integer;
  caY, clY, caU, clU, caV, clV: array[0..255] of Byte;   // coef ctx per plane (4px units)
  // deblock per-4x4 state (frame-wide)
  LvY0, LvY1, LvU, LvV: array of Byte;                    // filter levels
  VstY, HstY, WcY, HcY: array of Byte;                    // luma tx boundary + class
  VstC, HstC, WcC, HcC: array of Byte;                    // chroma tx boundary + class
  // CDEF: per-mi non-skip flag + per-64x64 cdef index (-1 = all-skip)
  NoskipMi: array of Byte;                                // FrmW4*FrmH4
  CdefIdxSb: array of ShortInt;                           // n64w*n64h
  N64w, N64h: Integer;

type
  TLrUnit = record
    typ, sgrIdx: Integer;
    fv, fh: array[0..2] of Integer;
    sw: array[0..1] of Integer;
  end;
var
  // LR per-unit params, per plane, flat [uy*LrUnitsW+ux]
  LrGrid: array[0..2] of array of TLrUnit;
  LrUnitsW, LrUnitsH: array[0..2] of Integer;
  LrUnitLog2: array[0..2] of Integer;

var DbgTrace: Boolean = False;

function IMin(a, b: Integer): Integer; inline; begin if a < b then Result := a else Result := b; end;
function IMax(a, b: Integer): Integer; inline; begin if a > b then Result := a else Result := b; end;
var
  SBd: Integer = 8;          // sample bit depth (8/10/12)
  SPixMax: Integer = 255;    // (1 shl SBd) - 1
  SPixBase: Integer = 128;   // 1 shl (SBd-1)  (neutral / edge-fill base)
  SBdShift: Integer = 0;     // SBd - 8

function ClipQ(v: Integer): Integer; inline; begin if v < 0 then Result := 0 else if v > SPixMax then Result := SPixMax else Result := v; end;
function Clip255(v: Integer): Integer; inline; begin if v < 0 then Result := 0 else if v > 255 then Result := 255 else Result := v; end;
function DqDc(qi: Integer): Integer; inline;
begin case SBd of 10: Result := Dq10Dc[qi]; 12: Result := Dq12Dc[qi]; else Result := Dq8Dc[qi]; end; end;
function DqAc(qi: Integer): Integer; inline;
begin case SBd of 10: Result := Dq10Ac[qi]; 12: Result := Dq12Ac[qi]; else Result := Dq8Ac[qi]; end; end;

function CtzI(v: Integer): Integer; begin Result := 0; while (v and 1) = 0 do begin v := v shr 1; Inc(Result); end; end;

// per-block deblock level for a base level (intra ref-delta applied).
function LfLvl(baseLvl: Integer; isChroma: Boolean): Integer;
var sh: Integer;
begin
  if isChroma and (baseLvl = 0) then begin Result := 0; Exit; end;
  if not Fh.LoopFilterDeltaEnabled then Result := baseLvl
  else
  begin
    sh := Ord(baseLvl >= 32);
    Result := baseLvl + Fh.LoopFilterRefDeltas[0] * (1 shl sh);
    if Result < 0 then Result := 0 else if Result > 63 then Result := 63;
  end;
end;

// record a transform block's deblock boundaries + width/height class.
procedure MarkTx(Vst, Hst, Wc, Hc: PByte; gridW, x4, y4, tw4, th4: Integer);
var xx, yy, b4, wc0, hc0: Integer;
begin
  wc0 := CtzI(tw4); if wc0 > 2 then wc0 := 2;
  hc0 := CtzI(th4); if hc0 > 2 then hc0 := 2;
  for yy := 0 to th4-1 do for xx := 0 to tw4-1 do
  begin
    b4 := (y4+yy)*gridW + (x4+xx);
    Wc[b4] := wc0; Hc[b4] := hc0;
    if xx = 0 then Vst[b4] := 1;
    if yy = 0 then Hst[b4] := 1;
  end;
end;

// DC value from reconstructed edges (dc_gen; square blocks).
function DcValue(P: PWord; stride, px, py, w, h: Integer): Integer;
var haveT, haveL: Boolean; i, sum: Integer;
begin
  haveT := py > PredY0; haveL := px > PredX0;
  if haveT and haveL then
  begin
    sum := (w + h) shr 1;
    for i := 0 to w - 1 do Inc(sum, P[(py-1)*stride + px + i]);
    for i := 0 to h - 1 do Inc(sum, P[(py+i)*stride + px - 1]);
    Result := sum shr CtzI(w + h);
    if w <> h then   // non-square: renormalise (dc_gen MULTIPLIER >> BASE_SHIFT)
    begin
      if (w > h*2) or (h > w*2) then Result := (Result * $3334) shr 16
      else Result := (Result * $5556) shr 16;
    end;
  end
  else if haveT then
  begin
    sum := w shr 1;
    for i := 0 to w - 1 do Inc(sum, P[(py-1)*stride + px + i]);
    Result := sum shr CtzI(w);
  end
  else if haveL then
  begin
    sum := h shr 1;
    for i := 0 to h - 1 do Inc(sum, P[(py+i)*stride + px - 1]);
    Result := sum shr CtzI(h);
  end
  else
    Result := 1 shl (Seq.BitDepth - 1);
end;

// DC intra prediction into a w x h block at (px,py) of plane P.
procedure PredictDC(P: PWord; stride, px, py, w, h: Integer);
var i, j, dc: Integer;
begin
  dc := DcValue(P, stride, px, py, w, h);
  for i := 0 to h - 1 do for j := 0 to w - 1 do P[(py+i)*stride + px + j] := Word(dc);
end;

// CFL chroma prediction: dc(chroma edges) + alpha*luma_ac. Chroma block is
// cw x ch chroma-px at (cpx,cpy); the luma footprint is subsampled per ssH/ssV.
procedure PredictCfl(Pc: PWord; cstride, cpx, cpy, cw, ch, alpha: Integer);
var ac: array[0..32*32-1] of Integer;
  x, y, sum, avg, dc, diff, log2sz, a, lx, ly, s, shift: Integer;
begin
  dc := DcValue(Pc, cstride, cpx, cpy, cw, ch);
  shift := 1 + (1 - ssV) + (1 - ssH);
  for y := 0 to ch-1 do
    for x := 0 to cw-1 do
    begin
      lx := (cpx + x) shl ssH; ly := (cpy + y) shl ssV;
      s := Yp[ly*FrmW + lx];
      if ssH <> 0 then Inc(s, Yp[ly*FrmW + lx + 1]);
      if ssV <> 0 then
      begin
        Inc(s, Yp[(ly+1)*FrmW + lx]);
        if ssH <> 0 then Inc(s, Yp[(ly+1)*FrmW + lx + 1]);
      end;
      ac[y*cw+x] := s shl shift;
    end;
  log2sz := CtzI(cw) + CtzI(ch);
  sum := (1 shl log2sz) shr 1;
  for x := 0 to cw*ch-1 do Inc(sum, ac[x]);
  avg := sum shr log2sz;
  for x := 0 to cw*ch-1 do Dec(ac[x], avg);
  for y := 0 to ch-1 do for x := 0 to cw-1 do
  begin
    diff := alpha * ac[y*cw+x];
    a := (Abs(diff) + 32) shr 6; if diff < 0 then a := -a;
    Pc[(cpy+y)*cstride + (cpx+x)] := ClipQ(dc + a);
  end;
end;

// Filter-intra prediction (ipred_filter_c). Reads reconstructed top/left
// neighbours and recursively fills 4x2 patches.
procedure PredictFilter(P: PWord; stride, px, py, w, h, filtIdx: Integer);
const CORNER = 40;
var x, y, xx, yy, k, acc, i: Integer; pv: array[0..6] of Integer;
  eb: array[0..79] of Integer; tl: PInteger; haveT, haveL: Boolean;
begin
  // prepared boundary edge (ipred prepare: 127 top / 129 left / 128 corner defaults)
  tl := @eb[CORNER];
  haveT := py > PredY0; haveL := px > PredX0;
  for i := 0 to w-1 do
    if haveT then tl[1+i] := P[(py-1)*stride+px+i]
    else if haveL then tl[1+i] := P[py*stride+px-1] else tl[1+i] := SPixBase-1;
  for i := 0 to h-1 do
    if haveL then tl[-(1+i)] := P[(py+i)*stride+px-1]
    else if haveT then tl[-(1+i)] := P[(py-1)*stride+px] else tl[-(1+i)] := SPixBase+1;
  if haveL then begin if haveT then tl[0] := P[(py-1)*stride+px-1] else tl[0] := P[py*stride+px-1]; end
  else if haveT then tl[0] := P[(py-1)*stride+px] else tl[0] := SPixBase;

  y := 0;
  while y < h do
  begin
    x := 0;
    while x < w do
    begin
      if y = 0 then
      begin
        if x = 0 then pv[0] := tl[0] else pv[0] := tl[x];
        pv[1] := tl[1+x]; pv[2] := tl[2+x]; pv[3] := tl[3+x]; pv[4] := tl[4+x];
      end
      else
      begin
        if x = 0 then pv[0] := tl[-y]   // left edge at row y (corner-column)
        else pv[0] := P[(py+y-1)*stride+px+x-1];
        pv[1] := P[(py+y-1)*stride+px+x]; pv[2] := P[(py+y-1)*stride+px+x+1];
        pv[3] := P[(py+y-1)*stride+px+x+2]; pv[4] := P[(py+y-1)*stride+px+x+3];
      end;
      if x = 0 then begin pv[5] := tl[-(1+y)]; pv[6] := tl[-(2+y)]; end
      else begin pv[5] := P[(py+y)*stride+px+x-1]; pv[6] := P[(py+y+1)*stride+px+x-1]; end;
      for yy := 0 to 1 do
        for xx := 0 to 3 do
        begin
          acc := 0;
          for k := 0 to 6 do Inc(acc, FilterIntraTaps[filtIdx][yy*4+xx][k] * pv[k]);
          P[(py+y+yy)*stride + (px+x+xx)] := ClipQ((acc + 8) shr 4);
        end;
      Inc(x, 4);
    end;
    Inc(y, 2);
  end;
end;

function IfThenB(c: Boolean; a, b: Integer): Byte; inline;
begin if c then Result := Byte(a) else Result := Byte(b); end;

procedure FillCharPlane(P: PWord; stride, px, py, w, h, val: Integer);
var x, y: Integer;
begin for y := 0 to h-1 do for x := 0 to w-1 do P[(py+y)*stride+px+x] := Word(val); end;

// Port of dav1d_prepare_intra_edges + dispatch. Builds a centred Integer edge
// buffer and calls the right kernel. edgeTR/edgeBL = neighbour availability of
// the top-right / bottom-left region; intraFlags = is_sm|edge_filter (bits 9/10).
const
  ZONE1 = 101; ZONE2 = 102; ZONE3 = 103;  // resolved directional
  DC128 = 110; DCTOP = 111; DCLEFT = 112;  // resolved DC variants

procedure Predict(P: PWord; stride, plW, plH, px, py, tw, th, mode, angle, edgeTR, edgeBL, intraFlags, maxW, maxH: Integer; filterE: Boolean);
const CORNER = 260;
var
  eb: array[0..519] of Integer; tl: PInteger; dst: PWord;
  haveT, haveL: Boolean; a, i, sz, pxHave, implMode, dm: Integer;
  needsT, needsL, needsTL, needsTR, needsBL, hasTR, hasBL: Boolean;
begin
  haveT := py > PredY0; haveL := px > PredX0;
  dst := @P[py*stride + px];
  a := angle;
  implMode := mode;
  // resolve
  if (mode >= VERT_PRED) and (mode <= VERT_LEFT_PRED) then
  begin
    a := ModeToAngle[mode - VERT_PRED] + 3 * angle;
    if a <= 90 then begin if (a < 90) and haveT then implMode := ZONE1 else implMode := VERT_PRED; end
    else if a < 180 then implMode := ZONE2
    else begin if (a > 180) and haveL then implMode := ZONE3 else implMode := HOR_PRED; end;
  end
  else if mode = DC_PRED then
  begin
    if haveL and haveT then implMode := DC_PRED else if haveT then implMode := DCTOP
    else if haveL then implMode := DCLEFT else implMode := DC128;
  end
  else if mode = PAETH_PRED then
  begin
    if haveL and haveT then implMode := PAETH_PRED else if haveT then implMode := VERT_PRED
    else if haveL then implMode := HOR_PRED else implMode := DC128;
  end;

  // needs flags per resolved mode
  needsT := False; needsL := False; needsTL := False; needsTR := False; needsBL := False;
  case implMode of
    DC_PRED, SMOOTH_PRED, SMOOTH_V_PRED, SMOOTH_H_PRED: begin needsT := True; needsL := True; end;
    VERT_PRED, DCTOP: needsT := True;
    HOR_PRED, DCLEFT: needsL := True;
    PAETH_PRED: begin needsT := True; needsL := True; needsTL := True; end;
    ZONE1: begin needsT := True; needsTR := True; needsTL := True; end;
    ZONE2: begin needsL := True; needsT := True; needsTL := True; end;
    ZONE3: begin needsL := True; needsBL := True; needsTL := True; end;
  end;

  tl := @eb[CORNER];
  // LEFT (+ bottom-left)
  if needsL then
  begin
    sz := th;
    if haveL then
    begin
      pxHave := sz; if plH - py < sz then pxHave := plH - py;
      for i := 0 to pxHave-1 do tl[-(1+i)] := P[(py+i)*stride + px - 1];
      for i := pxHave to sz-1 do tl[-(1+i)] := tl[-pxHave];
    end
    else
    begin
      if haveT then dm := P[(py-1)*stride+px] else dm := SPixBase+1;   // avoid eager OOB read
      for i := 0 to sz-1 do tl[-(1+i)] := dm;
    end;
    if needsBL then
    begin
      hasBL := haveL and (py + th < plH) and (edgeBL <> 0);
      if hasBL then
      begin
        pxHave := sz; if plH - py - th < sz then pxHave := plH - py - th;
        for i := 0 to pxHave-1 do tl[-(sz+1+i)] := P[(py+sz+i)*stride + px - 1];
        for i := pxHave to sz-1 do tl[-(sz+1+i)] := tl[-(sz+pxHave)];
      end
      else
        for i := 0 to sz-1 do tl[-(sz+1+i)] := tl[-sz];
    end;
  end;
  // TOP (+ top-right)
  if needsT then
  begin
    sz := tw;
    if haveT then
    begin
      pxHave := sz; if plW - px < sz then pxHave := plW - px;
      for i := 0 to pxHave-1 do tl[1+i] := P[(py-1)*stride + px + i];
      for i := pxHave to sz-1 do tl[1+i] := tl[pxHave];
    end
    else
    begin
      if haveL then dm := P[py*stride+px-1] else dm := SPixBase-1;   // avoid eager OOB read
      for i := 0 to sz-1 do tl[1+i] := dm;
    end;
    if needsTR then
    begin
      hasTR := haveT and (px + tw < plW) and (edgeTR <> 0);
      if hasTR then
      begin
        pxHave := sz; if plW - px - tw < sz then pxHave := plW - px - tw;
        for i := 0 to pxHave-1 do tl[1+sz+i] := P[(py-1)*stride + px + sz + i];
        for i := pxHave to sz-1 do tl[1+sz+i] := tl[sz+pxHave];
      end
      else
        for i := 0 to sz-1 do tl[1+sz+i] := tl[sz];
    end;
  end;
  // CORNER
  if needsTL then
  begin
    if haveL then begin if haveT then tl[0] := P[(py-1)*stride+px-1] else tl[0] := P[py*stride+px-1]; end
    else if haveT then tl[0] := P[(py-1)*stride+px] else tl[0] := SPixBase;
    if (implMode = ZONE2) and ((tw div 4)+(th div 4) >= 6) and filterE then
      tl[0] := ((tl[-1] + tl[1]) * 5 + tl[0] * 6 + 8) shr 4;
  end;

  case implMode of
    DC_PRED, DCTOP, DCLEFT: PredictDC(P, stride, px, py, tw, th);
    DC128: FillCharPlane(P, stride, px, py, tw, th, SPixBase);
    VERT_PRED: IPredV(dst, stride, tl, tw, th);
    HOR_PRED: IPredH(dst, stride, tl, tw, th);
    SMOOTH_PRED: IPredSmooth(dst, stride, tl, tw, th);
    SMOOTH_V_PRED: IPredSmoothV(dst, stride, tl, tw, th);
    SMOOTH_H_PRED: IPredSmoothH(dst, stride, tl, tw, th);
    PAETH_PRED: IPredPaeth(dst, stride, tl, tw, th);
    ZONE1: IPredZ1(dst, stride, tl, tw, th, a or intraFlags, maxW, maxH);
    ZONE2: IPredZ2(dst, stride, tl, tw, th, a or intraFlags, maxW, maxH);
    ZONE3: IPredZ3(dst, stride, tl, tw, th, a or intraFlags, maxW, maxH);
  else
    raise Exception.CreateFmt('intra mode %d not supported', [implMode]);
  end;
end;

function LoadFile(const Name: string): TBytes;
var FS: TFileStream;
begin FS := TFileStream.Create(Name, fmOpenRead);
  try SetLength(Result, FS.Size); if FS.Size>0 then FS.ReadBuffer(Result[0], FS.Size);
  finally FS.Free; end; end;

var TilePtr: PByte; TileSize: NativeInt;

// selects the DCT kernel by tx size
function DctFn(tx: Integer): TItx1dFn;
begin
  case tx of
    TX_4X4: Result := @InvDct4;
    TX_8X8: Result := @InvDct8;
    TX_16X16: Result := @InvDct16;
    TX_32X32: Result := @InvDct32;
  else Result := @InvDct64;
  end;
end;

// Reconstruct one plane of a coded block: iterate transform blocks, predicting
// (DC or filter-intra) and adding residual per transform.
procedure ReconPlaneTx(P: PWord; stride, plW, plH, bpx, bpy, bw, bh, lumaBW4, lumaBH4, tx,
  plane, chroma, useFilter, filtMode, predMode, predAngle, intraFlags,
  blockTHR, blockLHB, isCfl, cflAlpha, ymodeTxtp, uvmode, dqDc, dqAc, ssHorA, ssVerA, apalPred: Integer; ca, cl: PByte);
var
  txw, txh, tyy, txx, px, py, eob, txtp, resCtx, i: Integer;
  tw4, th4, xmi, ymi, edgeTR, edgeBL, blkW4, blkH4, gridW, pfW, pfH: Integer; c1, c2: Boolean;
  cf: array[0..64*64-1] of Integer;
begin
  txw := ItxWpx[tx]; txh := ItxHpx[tx];   // rectangular tx dims
  tw4 := txw div 4; th4 := txh div 4;
  blkW4 := bw div 4; blkH4 := bh div 4;   // this plane's block dims (4px units)
  if plane = 0 then
  begin
    gridW := FrmW4; pfW := FrmW4*4; pfH := FrmH4*4;   // mi-rounded (dav1d 4*f->bw/bh)
    PredX0 := TileColMi*4; PredY0 := TileRowMi*4;
    PredX1 := IMin(TileColEndMi*4, FrmW4*4); PredY1 := IMin(TileRowEndMi*4, FrmH4*4);
  end
  else
  begin
    gridW := FrmW4c; pfW := FrmW4c*4; pfH := FrmH4c*4;
    PredX0 := (TileColMi shr ssH)*4; PredY0 := (TileRowMi shr ssV)*4;
    PredX1 := IMin((TileColEndMi shr ssH)*4, FrmW4c*4); PredY1 := IMin((TileRowEndMi shr ssV)*4, FrmH4c*4);
  end;
  tyy := 0;
  while tyy < bh do
  begin
    txx := 0;
    while txx < bw do
    begin
      px := bpx + txx; py := bpy + tyy;
      if plane = 0 then MarkTx(@VstY[0], @HstY[0], @WcY[0], @HcY[0], gridW, px div 4, py div 4, tw4, th4)
      else if plane = 1 then MarkTx(@VstC[0], @HstC[0], @WcC[0], @HcC[0], gridW, px div 4, py div 4, tw4, th4);
      xmi := txx div 4; ymi := tyy div 4;
      // per-tx edge availability (recon_tmpl.c formula; single-SB, init=0)
      c1 := (ymi > 0) or (blockTHR = 0);
      c2 := (xmi + tw4) >= blkW4;
      edgeTR := Ord(not (c1 and c2));
      if xmi > 0 then edgeBL := 0
      else if (blockLHB = 0) and ((ymi + th4) >= blkH4) then edgeBL := 0
      else edgeBL := 1;
      if apalPred <> 0 then                       // palette: block already predicted
      else if (chroma = 0) and (useFilter <> 0) then PredictFilter(P, stride, px, py, txw, txh, filtMode)
      else if (chroma <> 0) and (isCfl <> 0) then PredictCfl(P, stride, px, py, txw, txh, cflAlpha)
      else Predict(P, stride, PredX1, PredY1, px, py, txw, txh, predMode, predAngle, edgeTR, edgeBL,
        intraFlags, pfW - px, pfH - py, Seq.EnableIntraEdgeFilter);
      FillChar(cf, SizeOf(cf), 0);
      eob := DecodeCoefs(Msac, Cdf, tx, lumaBW4, lumaBH4, 1, plane, chroma, ssHorA, ssVerA,
        @ca[px shr 2], @cl[py shr 2], dqDc, dqAc, @cf[0], ymodeTxtp, uvmode,
        Fh.ReducedTxSet, QIdxZero, txtp, resCtx);
      if eob >= 0 then
        if Fh.CodedLossless then
          InvWhtAdd4x4(@P[py*stride + px], stride, @cf[0], SPixMax)
        else
          InvTxfmAdd(@P[py*stride + px], stride, @cf[0], eob, txw, txh, ItxShiftT[tx],
            ItxFn(TxtpRowKind[txtp], txw), ItxFn(TxtpColKind[txtp], txh), Ord(txtp = 0), SBd);
      for i := 0 to tw4-1 do ca[(px shr 2)+i] := Byte(resCtx);
      for i := 0 to th4-1 do cl[(py shr 2)+i] := Byte(resCtx);
      Inc(txx, txw);
    end;
    Inc(tyy, txh);
  end;
end;

function SmFlag(m: Integer): Integer; inline;
begin if (m >= SMOOTH_PRED) and (m <= SMOOTH_H_PRED) then Result := 512 else Result := 0; end;

// --- Palette (screen content) -------------------------------------------------
// Read one plane's palette colours (dav1d read_pal_plane). pl: 0=Y, 1=U. Uses
// LUMA-coord neighbour context. Result in curPal[pl], size in curPalSz[pl].
procedure ReadPalPlane(pl, szCtx, bx4, by4: Integer);
var
  cache: array[0..15] of Word; usedCache: array[0..7] of Word;
  pal: array[0..15] of Word;
  lCache, aCache, nCache, i, n, m, nUsedCache, prev, bits, maxV, delta, palSz, notpl: Integer;
  lp, ap, done: Integer;
begin
  palSz := MsacDecodeSymbolAdapt(Msac, @Cdf.m.pal_sz[pl][szCtx][0], 6) + 2;
  curPalSz[pl] := palSz;
  notpl := Ord(pl = 0);
  if DbgTrace then Writeln(ErrOutput, Format('ReadPalPlane pl=%d sz=%d bx4=%d by4=%d', [pl, palSz, bx4, by4]));
  if pl <> 0 then lCache := palSzUvL[by4] else lCache := palSzL[by4];
  if (by4 and 15) = 0 then aCache := 0
  else if pl <> 0 then aCache := palSzUvA[bx4]
  else aCache := palSzA[bx4];
  lp := 0; ap := 0; nCache := 0;
  while (lCache > 0) and (aCache > 0) do
  begin
    if alPalL[by4][pl][lp] < alPalA[bx4][pl][ap] then
    begin
      if (nCache = 0) or (cache[nCache-1] <> alPalL[by4][pl][lp]) then begin cache[nCache] := alPalL[by4][pl][lp]; Inc(nCache); end;
      Inc(lp); Dec(lCache);
    end
    else
    begin
      if alPalA[bx4][pl][ap] = alPalL[by4][pl][lp] then begin Inc(lp); Dec(lCache); end;
      if (nCache = 0) or (cache[nCache-1] <> alPalA[bx4][pl][ap]) then begin cache[nCache] := alPalA[bx4][pl][ap]; Inc(nCache); end;
      Inc(ap); Dec(aCache);
    end;
  end;
  if lCache > 0 then
    repeat
      if (nCache = 0) or (cache[nCache-1] <> alPalL[by4][pl][lp]) then begin cache[nCache] := alPalL[by4][pl][lp]; Inc(nCache); end;
      Inc(lp); Dec(lCache);
    until lCache <= 0
  else if aCache > 0 then
    repeat
      if (nCache = 0) or (cache[nCache-1] <> alPalA[bx4][pl][ap]) then begin cache[nCache] := alPalA[bx4][pl][ap]; Inc(nCache); end;
      Inc(ap); Dec(aCache);
    until aCache <= 0;
  // reused cache entries
  i := 0; n := 0;
  while (n < nCache) and (i < palSz) do
  begin
    if MsacDecodeBoolEqui(Msac) <> 0 then begin usedCache[i] := cache[n]; Inc(i); end;
    Inc(n);
  end;
  nUsedCache := i;
  if i < palSz then
  begin
    prev := MsacDecodeBools(Msac, Seq.BitDepth);
    pal[i] := prev; Inc(i);
    if i < palSz then
    begin
      bits := Seq.BitDepth - 3 + Integer(MsacDecodeBools(Msac, 2));
      maxV := (1 shl Seq.BitDepth) - 1;
      done := 0;
      repeat
        delta := MsacDecodeBools(Msac, bits);
        prev := IMin(prev + delta + notpl, maxV);
        pal[i] := prev; Inc(i);
        if prev + notpl >= maxV then
        begin
          while i < palSz do begin pal[i] := maxV; Inc(i); end;
          done := 1;
        end
        else bits := IMin(bits, 1 + FloorLog2(maxV - prev - notpl));
      until (i >= palSz) or (done <> 0);
    end;
    // merge cache + new entries
    n := 0; m := nUsedCache;
    for i := 0 to palSz-1 do
      if (n < nUsedCache) and ((m >= palSz) or (usedCache[n] <= pal[m])) then
        begin curPal[pl][i] := usedCache[n]; Inc(n); end
      else begin curPal[pl][i] := pal[m]; Inc(m); end;
  end
  else
    for i := 0 to nUsedCache-1 do curPal[pl][i] := usedCache[i];
  if DbgTrace then Writeln(ErrOutput, Format('  Post-pal[pl=%d,sz=%d]: r=%d', [pl, palSz, Msac.Rng]));
end;

// V-plane palette (dav1d read_pal_uv tail). Requires curPalSz[1] already read.
procedure ReadPalUvV;
var bits, prev, maxV, i, delta: Integer;
begin
  if MsacDecodeBoolEqui(Msac) <> 0 then
  begin
    bits := Seq.BitDepth - 4 + Integer(MsacDecodeBools(Msac, 2));
    prev := MsacDecodeBools(Msac, Seq.BitDepth); curPal[2][0] := prev;
    maxV := (1 shl Seq.BitDepth) - 1;
    for i := 1 to curPalSz[1]-1 do
    begin
      delta := MsacDecodeBools(Msac, bits);
      if (delta <> 0) and (MsacDecodeBoolEqui(Msac) <> 0) then delta := -delta;
      prev := (prev + delta) and maxV;
      curPal[2][i] := prev;
    end;
  end
  else
    for i := 0 to curPalSz[1]-1 do curPal[2][i] := MsacDecodeBools(Msac, Seq.BitDepth);
end;

// Palette index-map ordering context for one wavefront diagonal (order_palette).
procedure OrderPalette(palIdx: PByte; stride, i, first, last: Integer; order, ctx: PByte);
var haveTop, haveLeft, j, n, oIdx, l, t, tl, v: Integer; mask, mm: LongWord; bit: Integer; p: PByte;
  procedure Add(vv: Integer); begin order[n*8+oIdx] := vv; Inc(oIdx); mask := mask or (LongWord(1) shl vv); end;
begin
  haveTop := Ord(i > first);
  p := palIdx + first + (i - first)*stride;
  n := 0; j := first;
  while j >= last do
  begin
    haveLeft := Ord(j > 0);
    mask := 0; oIdx := 0;
    if haveLeft = 0 then begin ctx[n] := 0; Add(p[-stride]); end
    else if haveTop = 0 then begin ctx[n] := 0; Add(p[-1]); end
    else
    begin
      l := p[-1]; t := p[-stride]; tl := p[-(stride+1)];
      if (t = l) and (t = tl) then begin ctx[n] := 4; Add(t); end
      else if t = l then begin ctx[n] := 3; Add(t); Add(tl); end
      else if (t = tl) or (l = tl) then
      begin ctx[n] := 2; Add(tl); if t = tl then Add(l) else Add(t); end
      else begin ctx[n] := 1; Add(IMin(t,l)); Add(IMax(t,l)); Add(tl); end;
    end;
    mm := 1; bit := 0;
    while mm < $100 do
    begin
      if (mask and mm) = 0 then begin order[n*8+oIdx] := bit; Inc(oIdx); end;
      mm := mm shl 1; Inc(bit);
    end;
    haveTop := 1; Dec(j); Inc(n); p := p + (stride - 1);
  end;
end;

// Read a plane's palette index map (dav1d read_pal_indices). palIdx stride = bw4*4.
procedure ReadPalIndices(pl, w4, h4, bw4, bh4: Integer; palIdx: PByte; palSz: Integer);
var stride, i, first, last, j, m, colorIdx, y: Integer;
  order: array[0..64*8-1] of Byte; ctx: array[0..63] of Byte;
begin
  stride := bw4 * 4;
  if DbgTrace then Writeln(ErrOutput, Format('ReadPalIndices pl=%d w4=%d h4=%d bw4=%d bh4=%d sz=%d', [pl, w4, h4, bw4, bh4, palSz]));
  palIdx[0] := MsacDecodeUniform(Msac, palSz);
  for i := 1 to 4*(w4+h4) - 2 do
  begin
    first := IMin(i, w4*4 - 1);
    last := IMax(0, i - h4*4 + 1);
    OrderPalette(palIdx, stride, i, first, last, @order[0], @ctx[0]);
    m := 0; j := first;
    while j >= last do
    begin
      colorIdx := MsacDecodeSymbolAdapt(Msac, @Cdf.m.color_map[pl][palSz-2][ctx[m]][0], palSz-1);
      palIdx[(i-j)*stride + j] := order[m*8 + colorIdx];
      Dec(j); Inc(m);
    end;
  end;
  if bw4 > w4 then
    for y := 0 to 4*h4-1 do
      FillChar(palIdx[y*stride + 4*w4], 4*(bw4-w4), palIdx[y*stride + 4*w4 - 1]);
  if h4 < bh4 then
    for y := h4*4 to bh4*4-1 do
      Move(palIdx[stride*(4*h4-1)], palIdx[y*stride], bw4*4);
  if DbgTrace then Writeln(ErrOutput, Format('  Post-pal-indices[pl=%d]: r=%d', [pl, Msac.Rng]));
end;

// Palette prediction: dst = pal[idx]. idx stride = w.
procedure PalPred(P: PWord; stride, px, py, w, h: Integer; pal: PWord; palIdx: PByte);
var x, y: Integer;
begin
  for y := 0 to h-1 do
    for x := 0 to w-1 do
      P[(py+y)*stride + px + x] := pal[palIdx[y*w + x]];
end;

// full block reconstruct (rectangular, intra keyframe). ef = 6-bit intra-edge
// flags (per-layout TOP_HAS_RIGHT / LEFT_HAS_BOTTOM).
procedure DecodeBlock(bx, by, bw4, bh4, ef: Integer);
var
  px, py, w, h, bs, tx, txC, bx4, by4, i, filtIntraOk: Integer;
  skipCtx, skip, ymode, uvmode, cflAllowed, isFilt, filtMode, ymodeTxtp: Integer;
  yAngle, uvAngle, bdimSum, lumaIF, chromaIF: Integer;
  isCfl, cflU, cflV, sgn, sgnU, sgnV: Integer;
  cbx4, cby4, cbw4, cbh4, cpx, cpy, cw, ch, txCtx, txDepth: Integer; hasChroma: Boolean;
  bThrY, bLhbY, bThrC, bLhbC, shAmt, sbStep4, nkx, nky: Integer;
begin
  px := bx * 4; py := by * 4; bx4 := bx; by4 := by;
  bs := BsLut[CtzI(bw4)][CtzI(bh4)];
  tx := MaxTxLuma[bs]; txC := MaxTxChSel[bs];
  if Fh.CodedLossless then begin tx := 0; txC := 0; end;   // lossless: all tx = TX_4X4 (WHT)
  w := bw4 * 4; h := bh4 * 4;
  // chroma geometry (dav1d decode_b)
  cbx4 := bx4 shr ssH; cby4 := by4 shr ssV;
  cbw4 := (bw4 + ssH) shr ssH; cbh4 := (bh4 + ssV) shr ssV;
  cpx := cbx4 * 4; cpy := cby4 * 4; cw := cbw4 * 4; ch := cbh4 * 4;
  hasChroma := (Seq.NumPlanes = 3) and
               ((bw4 > ssH) or ((bx4 and 1) <> 0)) and
               ((bh4 > ssV) or ((by4 and 1) <> 0));
  // per-plane top-right / bottom-left availability (recon_tmpl sb_has_tr/bl)
  if Seq.Use128x128Superblock then sbStep4 := 32 else sbStep4 := 16;
  bThrY := Ord((sbStep4 < bw4) or ((ef and E444TR) <> 0));
  bLhbY := Ord((sbStep4 < bh4) or ((ef and E444LB) <> 0));
  shAmt := 2 - (ssH + ssV);   // 420->0 (I420 bits), 422->1, 444->2 (I444 bits)
  bThrC := Ord(((sbStep4 shr ssH) < cbw4) or ((ef and (E420TR shr shAmt)) <> 0));
  bLhbC := Ord(((sbStep4 shr ssV) < cbh4) or ((ef and (E420LB shr shAmt)) <> 0));

  if DbgTrace then Writeln(ErrOutput, Format('BLK bx4=%d by4=%d bw4=%d bh4=%d hasC=%d', [bx4,by4,bw4,bh4,Ord(hasChroma)]));
  // skip
  skipCtx := skipA[bx4] + skipL[by4];
  skip := MsacDecodeBoolAdapt(Msac, @Cdf.m.skip[skipCtx][0]);
  if DbgTrace then Writeln(ErrOutput, Format('Post-skip[%d]: r=%d', [skip, Msac.Rng]));
  // cdef index (dav1d decode_b): first non-skip block in each 64x64 reads n_bits.
  if skip = 0 then
  begin
    i := (by4 shr 4) * N64w + (bx4 shr 4);
    if (i >= 0) and (i < Length(CdefIdxSb)) and (CdefIdxSb[i] = -1) then
    begin
      if Fh.CdefBits > 0 then filtIntraOk := MsacDecodeBools(Msac, Fh.CdefBits) else filtIntraOk := 0;
      CdefIdxSb[i] := filtIntraOk;
      if (bw4 > 16) and (i+1 < Length(CdefIdxSb)) then CdefIdxSb[i+1] := filtIntraOk;
      if (bh4 > 16) and (i+N64w < Length(CdefIdxSb)) then CdefIdxSb[i+N64w] := filtIntraOk;
      if (bw4 = 32) and (bh4 = 32) and (i+N64w+1 < Length(CdefIdxSb)) then CdefIdxSb[i+N64w+1] := filtIntraOk;
    end;
    // record per-mi non-skip for CDEF block gating
    for nky := 0 to bh4-1 do for nkx := 0 to bw4-1 do
      NoskipMi[(by4+nky)*FrmW4 + (bx4+nkx)] := 1;
  end;
  // keyframe intra
  // y_mode (key-frame CDF, neighbour-mode context)
  ymode := MsacDecodeSymbolAdapt(Msac, @Cdf.kfym[IntraModeCtx[modeA[bx4]]][IntraModeCtx[modeL[by4]]][0], 12);
  if DbgTrace then Writeln(ErrOutput, Format('Post-ymode[%d]: r=%d', [ymode, Msac.Rng]));
  // angle delta (luma) for directional modes
  bdimSum := CtzI(bw4) + CtzI(bh4);   // b_dim[2]+b_dim[3]
  yAngle := 0;
  if (bdimSum >= 2) and (ymode >= VERT_PRED) and (ymode <= VERT_LEFT_PRED) then
    yAngle := MsacDecodeSymbolAdapt(Msac, @Cdf.m.angle_delta[ymode - VERT_PRED][0], 6) - 3;
  // uv_mode (+ cfl / uv angle) — only present when this block carries chroma
  uvmode := DC_PRED; uvAngle := 0; cflU := 0; cflV := 0; isCfl := 0;
  if hasChroma then
  begin
    if Fh.CodedLossless then cflAllowed := Ord((cbw4 = 1) and (cbh4 = 1))
    else cflAllowed := Ord((CflAllowedMask and (1 shl bs)) <> 0);
    uvmode := MsacDecodeSymbolAdapt(Msac, @Cdf.m.uv_mode[cflAllowed][ymode][0], N_UV_INTRA_PRED_MODES - 1 - (1 - cflAllowed));
    if DbgTrace then Writeln(ErrOutput, Format('Post-uvmode[%d]: r=%d', [uvmode, Msac.Rng]));
    if uvmode = N_UV_INTRA_PRED_MODES - 1 then   // CFL_PRED
    begin
      isCfl := 1;
      sgn := MsacDecodeSymbolAdapt(Msac, @Cdf.m.cfl_sign[0], 7) + 1;
      sgnU := (sgn * $56) shr 8; sgnV := sgn - sgnU * 3;
      if sgnU <> 0 then
      begin i := Ord(sgnU = 2) * 3 + sgnV;
        cflU := MsacDecodeSymbolAdapt(Msac, @Cdf.m.cfl_alpha[i][0], 15) + 1;
        if sgnU = 1 then cflU := -cflU; end;
      if sgnV <> 0 then
      begin i := Ord(sgnV = 2) * 3 + sgnU;
        cflV := MsacDecodeSymbolAdapt(Msac, @Cdf.m.cfl_alpha[i][0], 15) + 1;
        if sgnV = 1 then cflV := -cflV; end;
    end
    else if (bdimSum >= 2) and (uvmode >= VERT_PRED) and (uvmode <= VERT_LEFT_PRED) then
      uvAngle := MsacDecodeSymbolAdapt(Msac, @Cdf.m.angle_delta[uvmode - VERT_PRED][0], 6) - 3;
    if DbgTrace and (isCfl <> 0) then Writeln(ErrOutput, Format('Post-uvalphas[%d/%d]: r=%d', [cflU, cflV, Msac.Rng]));
  end;
  // palette (screen-content)
  curPalSz[0] := 0; curPalSz[1] := 0;
  if (Fh.AllowScreenContentTools <> 0) and (bw4 <= 16) and (bh4 <= 16) and (bw4 + bh4 >= 4) then
  begin
    if ymode = DC_PRED then
    begin
      i := Ord(palSzA[bx4] > 0) + Ord(palSzL[by4] > 0);   // pal_ctx
      sgn := MsacDecodeBoolAdapt(Msac, @Cdf.m.pal_y[bdimSum-2][i][0]);
      if DbgTrace then Writeln(ErrOutput, Format('Post-y_pal[%d]: r=%d', [sgn, Msac.Rng]));
      if sgn <> 0 then ReadPalPlane(0, bdimSum-2, bx4, by4);
    end;
    if hasChroma and (uvmode = DC_PRED) then
    begin
      i := Ord(curPalSz[0] > 0);
      sgn := MsacDecodeBoolAdapt(Msac, @Cdf.m.pal_uv[i][0]);
      if DbgTrace then Writeln(ErrOutput, Format('Post-uv_pal[%d]: r=%d', [sgn, Msac.Rng]));
      if sgn <> 0 then begin ReadPalPlane(1, bdimSum-2, bx4, by4); ReadPalUvV; end;
    end;
  end;
  // filter-intra (dav1d order: after palette COLOURS, BEFORE palette INDICES).
  // Allowed when max(log2 bw4, log2 bh4) <= 3; not for a luma-palette block.
  isFilt := 0; filtMode := 0; ymodeTxtp := ymode;
  if CtzI(bw4) >= CtzI(bh4) then filtIntraOk := Ord(CtzI(bw4) <= 3) else filtIntraOk := Ord(CtzI(bh4) <= 3);
  if (ymode = 0) and (curPalSz[0] = 0) and Seq.EnableFilterIntra and (filtIntraOk <> 0) then
  begin
    isFilt := MsacDecodeBoolAdapt(Msac, @Cdf.m.use_filter_intra[bs][0]);
    if isFilt <> 0 then
    begin
      filtMode := MsacDecodeSymbolAdapt(Msac, @Cdf.m.filter_intra[0], 4);
      ymodeTxtp := FilterModeToYMode[filtMode];   // for luma txtp derivation
    end;
    if DbgTrace then Writeln(ErrOutput, Format('Post-filterintramode[%d]: r=%d', [isFilt, Msac.Rng]));
  end;
  // palette index maps (after filter-intra)
  if curPalSz[0] > 0 then
    ReadPalIndices(0, IMin(bw4, FrmW4 - bx4), IMin(bh4, FrmH4 - by4), bw4, bh4, @palIdxY[0], curPalSz[0]);
  if hasChroma and (curPalSz[1] > 0) then
    ReadPalIndices(1, IMin(cbw4, FrmW4c - cbx4), IMin(cbh4, FrmH4c - cby4), cbw4, cbh4, @palIdxC[0], curPalSz[1]);
  // tx size: largest, then (TX_MODE_SELECT) read a split depth.
  if (Fh.TxMode = TX_MODE_SELECT) and (TxDmax[tx] > 0) then
  begin
    txCtx := Ord(txiL[by4] >= TxDlh[tx]) + Ord(txiA[bx4] >= TxDlw[tx]);
    txDepth := MsacDecodeSymbolAdapt(Msac, @Cdf.m.txsz[TxDmax[tx]-1][txCtx][0], IMin(TxDmax[tx], 2));
    while txDepth > 0 do begin tx := TxDsub[tx]; Dec(txDepth); end;
  end;
  if DbgTrace then Writeln(ErrOutput, Format('Post-tx[%d]: r=%d', [tx, Msac.Rng]));
  // mark neighbour tx context with the final luma tx dims
  for i := 0 to (w shr 2)-1 do txiA[bx4+i] := TxDlw[tx];
  for i := 0 to (h shr 2)-1 do txiL[by4+i] := TxDlh[tx];

  lumaIF := SmFlag(modeA[bx4]) or SmFlag(modeL[by4]) or (Ord(Seq.EnableIntraEdgeFilter) shl 10);
  chromaIF := SmFlag(uvmodeA[cbx4]) or SmFlag(uvmodeL[cby4]) or (Ord(Seq.EnableIntraEdgeFilter) shl 10);

  if DbgTrace and (curPalSz[0] > 0) then Writeln(ErrOutput, Format('  recon pal px=%d py=%d w=%d h=%d tx=%d hasC=%d cw=%d ch=%d', [px,py,w,h,tx,Ord(hasChroma),cw,ch]));
  // --- luma ---
  if curPalSz[0] > 0 then PalPred(@Yp[0], FrmW, px, py, w, h, @curPal[0][0], @palIdxY[0]);
  ReconPlaneTx(@Yp[0], FrmW, FrmW, FrmH, px, py, w, h, w shr 2, h shr 2, tx, 0, 0, isFilt, filtMode, ymode, yAngle, lumaIF, bThrY, bLhbY, 0, 0, ymodeTxtp, uvmode, DqYDc, DqYAc, 0, 0, Ord(curPalSz[0] > 0), @caY[0], @clY[0]);
  // --- chroma U / V ---
  if hasChroma then
  begin
    if curPalSz[1] > 0 then
    begin
      PalPred(@Up[0], FrmWc, cpx, cpy, cw, ch, @curPal[1][0], @palIdxC[0]);
      PalPred(@Vp[0], FrmWc, cpx, cpy, cw, ch, @curPal[2][0], @palIdxC[0]);
    end;
    ReconPlaneTx(@Up[0], FrmWc, FrmWc, FrmHc, cpx, cpy, cw, ch, w shr 2, h shr 2, txC, 1, 1, 0, 0, uvmode, uvAngle, chromaIF, bThrC, bLhbC, isCfl, cflU, ymodeTxtp, uvmode, DqUDc, DqUAc, ssH, ssV, Ord(curPalSz[1] > 0), @caU[0], @clU[0]);
    ReconPlaneTx(@Vp[0], FrmWc, FrmWc, FrmHc, cpx, cpy, cw, ch, w shr 2, h shr 2, txC, 2, 1, 0, 0, uvmode, uvAngle, chromaIF, bThrC, bLhbC, isCfl, cflV, ymodeTxtp, uvmode, DqVDc, DqVAc, ssH, ssV, Ord(curPalSz[1] > 0), @caV[0], @clV[0]);
  end;

  // context updates
  for i := 0 to (w shr 2)-1 do begin skipA[bx4+i] := skip; modeA[bx4+i] := ymode; end;
  for i := 0 to (h shr 2)-1 do begin skipL[by4+i] := skip; modeL[by4+i] := ymode; end;
  if hasChroma then
  begin
    for i := 0 to cbw4-1 do uvmodeA[cbx4+i] := uvmode;
    for i := 0 to cbh4-1 do uvmodeL[cby4+i] := uvmode;
  end;
  // palette neighbour context (LUMA coords, over luma block dims)
  sgn := curPalSz[0]; if hasChroma then sgnU := curPalSz[1] else sgnU := 0;
  for i := 0 to bw4-1 do begin palSzA[bx4+i] := sgn; palSzUvA[bx4+i] := sgnU; end;
  for i := 0 to bh4-1 do begin palSzL[by4+i] := sgn; palSzUvL[by4+i] := sgnU; end;
  if curPalSz[0] > 0 then
  begin
    for i := 0 to bw4-1 do Move(curPal[0][0], alPalA[bx4+i][0][0], 32);
    for i := 0 to bh4-1 do Move(curPal[0][0], alPalL[by4+i][0][0], 32);
  end;
  if hasChroma and (curPalSz[1] > 0) then
  begin
    for i := 0 to bw4-1 do begin Move(curPal[1][0], alPalA[bx4+i][1][0], 32); Move(curPal[2][0], alPalA[bx4+i][2][0], 32); end;
    for i := 0 to bh4-1 do begin Move(curPal[1][0], alPalL[by4+i][1][0], 32); Move(curPal[2][0], alPalL[by4+i][2][0], 32); end;
  end;

  // deblock filter levels: luma per-4x4 (luma grid); chroma per-4x4 (chroma grid).
  for py := 0 to bh4-1 do for px := 0 to bw4-1 do
  begin
    i := (by4+py)*FrmW4 + (bx4+px);
    LvY0[i] := LfLvl(Fh.LoopFilterLevel[0], False);
    LvY1[i] := LfLvl(Fh.LoopFilterLevel[1], False);
  end;
  if hasChroma then
    for py := 0 to cbh4-1 do for px := 0 to cbw4-1 do
    begin
      i := (cby4+py)*FrmW4c + (cbx4+px);
      LvU[i] := LfLvl(Fh.LoopFilterLevel[2], True);
      LvV[i] := LfLvl(Fh.LoopFilterLevel[3], True);
    end;
end;

// Split-probabilities for partial superblocks (dav1d env.h gather_*_partition_prob).
function GatherTopPart(pc: PWord; bl: Integer): LongWord;
begin
  Result := LongWord(pc[1]) - pc[4] + pc[5];
  if bl <> BL_128X128 then Result := Result + LongWord(pc[8]) - pc[7];
end;
function GatherLeftPart(pc: PWord; bl: Integer): LongWord;
begin
  Result := LongWord(pc[0]) - pc[1] + pc[2] - pc[6];
  if bl <> BL_128X128 then Result := Result + LongWord(pc[7]) - pc[8];
end;

// ef = node's 6-bit intra-edge flags (dav1d intra_edge tree). Children derive
// their flags via init_edges (per-partition, per-subsampling).
procedure DecodeSb(bl, bx, by, ef: Integer);
var hsz, bx8, by8, ctx, bp, i, isTip, thrB, lhbB: Integer; haveH, haveV: Boolean;
  function SplitChildEf(n: Integer): Integer;
  var tr, lb: Boolean;
  begin
    tr := not ((n = 3) or ((n = 1) and (thrB = 0)));
    lb := (n = 0) or ((n = 2) and (lhbB <> 0));
    Result := 0; if tr then Result := Result or ALLTR; if lb then Result := Result or ALLLB;
  end;
begin
  hsz := 16 shr bl;
  isTip := Ord(bl = BL_8X8);
  thrB := Ord((ef and E444TR) <> 0); lhbB := Ord((ef and E444LB) <> 0);
  haveH := FrmW4 > bx + hsz;   // note: bw in mi
  haveV := FrmH4 > by + hsz;
  if (not haveH) and (not haveV) then begin DecodeSb(bl+1, bx, by, SplitChildEf(0)); Exit; end;

  bx8 := bx shr 1; by8 := by shr 1;   // absolute partition-ctx index
  ctx := ((partA[bx8] shr (4-bl)) and 1) + (((partL[by8] shr (4-bl)) and 1) shl 1);

  // partial superblock (only one split dimension available): read a split bool.
  if not (haveH and haveV) then
  begin
    if haveH then   // bottom edge: split into L/R, or PARTITION_H (top block)
    begin
      if MsacDecodeBool(Msac, GatherTopPart(@Cdf.m.partition[bl][ctx][0], bl)) <> 0 then
      begin
        DecodeSb(bl+1, bx, by, SplitChildEf(0));
        DecodeSb(bl+1, bx+hsz, by, SplitChildEf(1));
      end
      else
      begin
        DecodeBlock(bx, by, 2*hsz, hsz, ef or ALLLB);
        for i := 0 to hsz-1 do begin partA[bx8+i] := AlPartCtx[0][bl][PARTITION_H]; partL[by8+i] := AlPartCtx[1][bl][PARTITION_H]; end;
      end;
    end
    else            // right edge: split into T/B, or PARTITION_V (left block)
    begin
      if MsacDecodeBool(Msac, GatherLeftPart(@Cdf.m.partition[bl][ctx][0], bl)) <> 0 then
      begin
        DecodeSb(bl+1, bx, by, SplitChildEf(0));
        DecodeSb(bl+1, bx, by+hsz, SplitChildEf(2));
      end
      else
      begin
        DecodeBlock(bx, by, hsz, 2*hsz, ef or ALLTR);
        for i := 0 to hsz-1 do begin partA[bx8+i] := AlPartCtx[0][bl][PARTITION_V]; partL[by8+i] := AlPartCtx[1][bl][PARTITION_V]; end;
      end;
    end;
    Exit;
  end;

  bp := MsacDecodeSymbolAdapt(Msac, @Cdf.m.partition[bl][ctx][0], PartitionTypeCount[bl]);
  if DbgTrace then Writeln(ErrOutput, Format('y=%d,x=%d,bl=%d,ctx=%d,bp=%d: r=%d', [by, bx, bl, ctx, bp, Msac.Rng]));

  case bp of
    PARTITION_NONE:
      DecodeBlock(bx, by, 2*hsz, 2*hsz, ef);
    PARTITION_H:
      begin
        DecodeBlock(bx, by, 2*hsz, hsz, ef or ALLLB);
        if isTip <> 0 then i := ef and (ALLLB or E420TR) else i := ef and ALLLB;
        if by + hsz < FrmH4 then DecodeBlock(bx, by+hsz, 2*hsz, hsz, i);
      end;
    PARTITION_V:
      begin
        DecodeBlock(bx, by, hsz, 2*hsz, ef or ALLTR);
        if isTip <> 0 then i := ef and (ALLTR or E420LB or E422LB) else i := ef and ALLTR;
        if bx + hsz < FrmW4 then DecodeBlock(bx+hsz, by, hsz, 2*hsz, i);
      end;
    PARTITION_SPLIT:
      if isTip <> 0 then
      begin
        DecodeBlock(bx, by, hsz, hsz, ALLTR or ALLLB);
        DecodeBlock(bx+hsz, by, hsz, hsz, (ef and ALLTR) or E422LB);
        DecodeBlock(bx, by+hsz, hsz, hsz, ef or E444TR);
        DecodeBlock(bx+hsz, by+hsz, hsz, hsz, ef and (E420TR or E420LB or E422LB));
      end
      else
      begin
        DecodeSb(bl+1, bx, by, SplitChildEf(0));
        DecodeSb(bl+1, bx+hsz, by, SplitChildEf(1));
        DecodeSb(bl+1, bx, by+hsz, SplitChildEf(2));
        DecodeSb(bl+1, bx+hsz, by+hsz, SplitChildEf(3));
      end;
    PART_T_TOP:    // tts: 2 quarters on top, wide half on bottom
      begin
        DecodeBlock(bx, by, hsz, hsz, ALLTR or ALLLB);
        DecodeBlock(bx+hsz, by, hsz, hsz, ef and ALLTR);
        DecodeBlock(bx, by+hsz, 2*hsz, hsz, ef and ALLLB);
      end;
    PART_T_BOTTOM: // tbs: wide half on top, 2 quarters on bottom
      begin
        DecodeBlock(bx, by, 2*hsz, hsz, ef or ALLLB);
        DecodeBlock(bx, by+hsz, hsz, hsz, ef or ALLTR);
        DecodeBlock(bx+hsz, by+hsz, hsz, hsz, 0);
      end;
    PART_T_LEFT:   // tls: 2 quarters on left, tall half on right
      begin
        DecodeBlock(bx, by, hsz, hsz, ALLTR or ALLLB);
        DecodeBlock(bx, by+hsz, hsz, hsz, ef and ALLLB);
        DecodeBlock(bx+hsz, by, hsz, 2*hsz, ef and ALLTR);
      end;
    PART_T_RIGHT:  // trs: tall half on left, 2 quarters on right
      begin
        DecodeBlock(bx, by, hsz, 2*hsz, ef or ALLTR);
        DecodeBlock(bx+hsz, by, hsz, hsz, ef or ALLLB);
        DecodeBlock(bx+hsz, by+hsz, hsz, hsz, 0);
      end;
    PART_H4:       // h4: 4 horizontal strips
      begin
        DecodeBlock(bx, by, 2*hsz, hsz shr 1, ef or ALLLB);
        if bl = BL_16X16 then i := ALLLB or (ef and E420TR) else i := ALLLB;
        DecodeBlock(bx, by+(hsz shr 1), 2*hsz, hsz shr 1, i);
        DecodeBlock(bx, by+hsz, 2*hsz, hsz shr 1, ALLLB);
        if by + (hsz*3 shr 1) < FrmH4 then DecodeBlock(bx, by+(hsz*3 shr 1), 2*hsz, hsz shr 1, ef and ALLLB);
      end;
    PART_V4:       // v4: 4 vertical strips
      begin
        DecodeBlock(bx, by, hsz shr 1, 2*hsz, ef or ALLTR);
        if bl = BL_16X16 then i := ALLTR or (ef and (E420LB or E422LB)) else i := ALLTR;
        DecodeBlock(bx+(hsz shr 1), by, hsz shr 1, 2*hsz, i);
        DecodeBlock(bx+hsz, by, hsz shr 1, 2*hsz, ALLTR);
        if bx + (hsz*3 shr 1) < FrmW4 then DecodeBlock(bx+(hsz*3 shr 1), by, hsz shr 1, 2*hsz, ef and ALLTR);
      end;
  else
    raise Exception.CreateFmt('partition %d not supported yet', [bp]);
  end;
  // partition context propagation (dav1d decode_sb): set for NONE/H/V/T/H4/V4,
  // and for an 8x8 SPLIT (its 4x4 leaves have no deeper recursion to set it);
  // larger SPLITs let their recursive children set their own context.
  if (bp <> PARTITION_SPLIT) or (bl = BL_8X8) then
    for i := 0 to hsz-1 do
    begin partA[bx8+i] := AlPartCtx[0][bl][bp]; partL[by8+i] := AlPartCtx[1][bl][bp]; end;
end;

// Whole-frame deblock: all vertical edges then all horizontal, per plane.
procedure DeblockFrame;
var lut: TLfLut;
  procedure DoPlane(pl: Integer);
  var x4, y4, b4, L, idx, wd, gW, gH, stride: Integer; P: PWord; Lv, Vst, Hst, Wc, Hc: PByte;
  begin
    if pl = 0 then begin P := @Yp[0]; Vst := @VstY[0]; Hst := @HstY[0]; Wc := @WcY[0]; Hc := @HcY[0]; Lv := @LvY0[0]; gW := FrmW4; gH := FrmH4; stride := FrmW; end
    else if pl = 1 then begin P := @Up[0]; Vst := @VstC[0]; Hst := @HstC[0]; Wc := @WcC[0]; Hc := @HcC[0]; Lv := @LvU[0]; gW := FrmW4c; gH := FrmH4c; stride := FrmWc; end
    else begin P := @Vp[0]; Vst := @VstC[0]; Hst := @HstC[0]; Wc := @WcC[0]; Hc := @HcC[0]; Lv := @LvV[0]; gW := FrmW4c; gH := FrmH4c; stride := FrmWc; end;
    // vertical edges
    for y4 := 0 to gH-1 do
      for x4 := 1 to gW-1 do
      begin
        b4 := y4*gW + x4;
        if Vst[b4] = 0 then Continue;
        L := Lv[b4]; if L = 0 then L := Lv[b4-1];
        if L = 0 then Continue;
        idx := Wc[b4]; if Wc[b4-1] < idx then idx := Wc[b4-1];
        if pl = 0 then wd := 4 shl idx else begin if idx > 1 then idx := 1; wd := 4 + 2*idx; end;
        LfEdge(@P[y4*4*stride + x4*4], lut.e[L] shl SBdShift, lut.i[L] shl SBdShift, (L shr 4) shl SBdShift, stride, 1, wd);
      end;
    // horizontal edges (use y-horizontal level for luma)
    if pl = 0 then Lv := @LvY1[0];
    for y4 := 1 to gH-1 do
      for x4 := 0 to gW-1 do
      begin
        b4 := y4*gW + x4;
        if Hst[b4] = 0 then Continue;
        L := Lv[b4]; if L = 0 then L := Lv[b4-gW];
        if L = 0 then Continue;
        idx := Hc[b4]; if Hc[b4-gW] < idx then idx := Hc[b4-gW];
        if pl = 0 then wd := 4 shl idx else begin if idx > 1 then idx := 1; wd := 4 + 2*idx; end;
        LfEdge(@P[y4*4*stride + x4*4], lut.e[L] shl SBdShift, lut.i[L] shl SBdShift, (L shr 4) shl SBdShift, 1, stride, wd);
      end;
  end;
begin
  if (Fh.LoopFilterLevel[0] = 0) and (Fh.LoopFilterLevel[1] = 0) then Exit;
  CalcEih(lut, Fh.LoopFilterSharpness);
  DoPlane(0); DoPlane(1); DoPlane(2);
end;

function SaveRef(const Name: string): TBytes;
begin Result := LoadFile(Name); end;

// --- CDEF (constrained directional enhancement filter) ---------------------
// Applied to the deblocked frame. We keep a pre-CDEF copy of each plane and
// read every neighbour from it (CDEF never reads a post-CDEF pixel), which is
// functionally identical to dav1d's streaming line-buffer design.
const
  CD_LEFT = 1; CD_RIGHT = 2; CD_TOP = 4; CD_BOTTOM = 8;
  CD_SENT = -32768;   // INT16_MIN sentinel for missing edges
var
  YpPre, UpPre, VpPre: array of Word;

function ULog2(x: Integer): Integer; inline;
begin Result := 0; while x > 1 do begin x := x shr 1; Inc(Result); end; end;

function UMin(a, b: Integer): Integer; inline;
begin if LongWord(a) < LongWord(b) then Result := a else Result := b; end;

function CdConstrain(diff, threshold, shift: Integer): Integer; inline;
var ad, v: Integer;
begin
  ad := Abs(diff);
  v := threshold - (ad shr shift); if v < 0 then v := 0;
  if ad < v then v := ad;               // imin(ad, max(0, thr-(ad>>shift)))
  if diff < 0 then Result := -v else Result := v;
end;

function AdjustStrength(strength: Integer; vari: LongWord): Integer;
var i: Integer;
begin
  if vari = 0 then Exit(0);
  if (vari shr 6) <> 0 then begin i := ULog2(vari shr 6); if i > 12 then i := 12; end else i := 0;
  Result := (strength * (4 + i) + 8) shr 4;
end;

// Direction search on an 8x8 luma block (dav1d cdef_find_dir_c, 8-bit).
function CdefFindDir(Pre: PWord; stride, bpx, bpy: Integer; out vari: LongWord): Integer;
var
  psHv: array[0..1, 0..7] of Integer;
  psDiag: array[0..1, 0..14] of Integer;
  psAlt: array[0..3, 0..10] of Integer;
  cost: array[0..7] of Integer;
  x, y, pxv, n, m, d, bestDir, bestCost: Integer;
begin
  FillChar(psHv, SizeOf(psHv), 0); FillChar(psDiag, SizeOf(psDiag), 0); FillChar(psAlt, SizeOf(psAlt), 0);
  for y := 0 to 7 do
    for x := 0 to 7 do
    begin
      pxv := (Pre[(bpy+y)*stride + (bpx+x)] shr SBdShift) - 128;
      Inc(psDiag[0][y + x], pxv);
      Inc(psAlt[0][y + (x shr 1)], pxv);
      Inc(psHv[0][y], pxv);
      Inc(psAlt[1][3 + y - (x shr 1)], pxv);
      Inc(psDiag[1][7 + y - x], pxv);
      Inc(psAlt[2][3 - (y shr 1) + x], pxv);
      Inc(psHv[1][x], pxv);
      Inc(psAlt[3][(y shr 1) + x], pxv);
    end;
  FillChar(cost, SizeOf(cost), 0);
  for n := 0 to 7 do
  begin
    Inc(cost[2], psHv[0][n]*psHv[0][n]);
    Inc(cost[6], psHv[1][n]*psHv[1][n]);
  end;
  cost[2] := cost[2] * 105; cost[6] := cost[6] * 105;
  for n := 0 to 6 do
  begin
    d := CdefDivTable[n];
    Inc(cost[0], (psDiag[0][n]*psDiag[0][n] + psDiag[0][14-n]*psDiag[0][14-n]) * d);
    Inc(cost[4], (psDiag[1][n]*psDiag[1][n] + psDiag[1][14-n]*psDiag[1][14-n]) * d);
  end;
  Inc(cost[0], psDiag[0][7]*psDiag[0][7]*105);
  Inc(cost[4], psDiag[1][7]*psDiag[1][7]*105);
  for n := 0 to 3 do
  begin
    for m := 0 to 4 do Inc(cost[n*2+1], psAlt[n][3+m]*psAlt[n][3+m]);
    cost[n*2+1] := cost[n*2+1] * 105;
    for m := 0 to 2 do
    begin
      d := CdefDivTable[2*m+1];
      Inc(cost[n*2+1], (psAlt[n][m]*psAlt[n][m] + psAlt[n][10-m]*psAlt[n][10-m]) * d);
    end;
  end;
  bestDir := 0; bestCost := cost[0];
  for n := 1 to 7 do if LongWord(cost[n]) > LongWord(bestCost) then begin bestCost := cost[n]; bestDir := n; end;
  vari := LongWord(bestCost - cost[bestDir xor 4]) shr 10;
  Result := bestDir;
end;

// One CDEF filter block (unified 4x4/4x8/8x8), matching cdef_filter_block_c.
procedure CdefFilterBlock(P, Pre: PWord; stride, bpx, bpy, w, h,
  priStrength, secStrength, dir, damping, edges: Integer);
var
  tmp: array[0..143] of SmallInt;
  base, ts, x, y, idx, r, priTap, priShift, secShift, ptk, k: Integer;
  pxv, sum, mn, mx, off1, off2, off3, p0, p1, s0, s1, s2, s3, secTap, val: Integer;
  hasT, hasB, hasL, hasR, sentinel: Boolean;
begin
  ts := 12; base := 2*ts + 2;
  hasT := (edges and CD_TOP) <> 0; hasB := (edges and CD_BOTTOM) <> 0;
  hasL := (edges and CD_LEFT) <> 0; hasR := (edges and CD_RIGHT) <> 0;
  for y := -2 to h+1 do
    for x := -2 to w+1 do
    begin
      sentinel := ((not hasT) and (y < 0)) or ((not hasB) and (y >= h)) or
                  ((not hasL) and (x < 0)) or ((not hasR) and (x >= w));
      idx := base + y*ts + x;
      if sentinel then tmp[idx] := CD_SENT
      else tmp[idx] := Pre[(bpy+y)*stride + (bpx+x)];
    end;
  priTap := 0; priShift := 0; secShift := 0;
  if priStrength > 0 then
  begin
    priTap := 4 - ((priStrength shr SBdShift) and 1);
    priShift := damping - ULog2(priStrength); if priShift < 0 then priShift := 0;
  end;
  if secStrength > 0 then secShift := damping - ULog2(secStrength);
  for r := 0 to h-1 do
    for x := 0 to w-1 do
    begin
      idx := base + r*ts + x;
      pxv := tmp[idx]; sum := 0; mn := pxv; mx := pxv;
      if priStrength > 0 then
      begin
        ptk := priTap;
        for k := 0 to 1 do
        begin
          off1 := CdefDir[dir+2][k][0]*ts + CdefDir[dir+2][k][1];
          p0 := tmp[idx+off1]; p1 := tmp[idx-off1];
          Inc(sum, ptk*CdConstrain(p0-pxv, priStrength, priShift));
          Inc(sum, ptk*CdConstrain(p1-pxv, priStrength, priShift));
          ptk := (ptk and 3) or 2;
          if secStrength > 0 then
          begin mn := UMin(p0, mn); if p0 > mx then mx := p0; mn := UMin(p1, mn); if p1 > mx then mx := p1; end;
        end;
      end;
      if secStrength > 0 then
        for k := 0 to 1 do
        begin
          off2 := CdefDir[dir+4][k][0]*ts + CdefDir[dir+4][k][1];
          off3 := CdefDir[dir+0][k][0]*ts + CdefDir[dir+0][k][1];
          s0 := tmp[idx+off2]; s1 := tmp[idx-off2]; s2 := tmp[idx+off3]; s3 := tmp[idx-off3];
          secTap := 2 - k;
          Inc(sum, secTap*CdConstrain(s0-pxv, secStrength, secShift));
          Inc(sum, secTap*CdConstrain(s1-pxv, secStrength, secShift));
          Inc(sum, secTap*CdConstrain(s2-pxv, secStrength, secShift));
          Inc(sum, secTap*CdConstrain(s3-pxv, secStrength, secShift));
          mn := UMin(s0, mn); if s0 > mx then mx := s0; mn := UMin(s1, mn); if s1 > mx then mx := s1;
          mn := UMin(s2, mn); if s2 > mx then mx := s2; mn := UMin(s3, mn); if s3 > mx then mx := s3;
        end;
      val := pxv + ((sum - Ord(sum < 0) + 8) shr 4);
      if (priStrength > 0) and (secStrength > 0) then
      begin if val < mn then val := mn else if val > mx then val := mx; end;
      P[(bpy+r)*stride + (bpx+x)] := Word(val);
    end;
end;

procedure CdefFrame;
var
  UvDirT: array[0..7] of Integer;
  bx, by, ci, damping, edges, yLvl, uvLvl, yPri, ySec, uvPri, uvSec: Integer;
  dir, uvdir, adjPri, cpx, cpy, cw, ch: Integer; vari: LongWord;
  anyStr: Boolean;
begin
  if Seq.MonoChrome then ; // still filters luma
  if not Seq.EnableCdef then Exit;
  if Fh.CodedLossless then Exit;
  anyStr := False;
  for ci := 0 to (1 shl Fh.CdefBits)-1 do
    if (Fh.CdefYPriStrength[ci] <> 0) or (Fh.CdefYSecStrength[ci] <> 0) or
       (Fh.CdefUVPriStrength[ci] <> 0) or (Fh.CdefUVSecStrength[ci] <> 0) then anyStr := True;
  if not anyStr then Exit;
  damping := Fh.CdefDampingMinus3 + 3 + SBdShift;
  // uv direction remap: I420/I444 identity; I422 uses the alt table.
  if (ssH = 1) and (ssV = 0) then
  begin UvDirT[0]:=7; UvDirT[1]:=0; UvDirT[2]:=2; UvDirT[3]:=4; UvDirT[4]:=5; UvDirT[5]:=6; UvDirT[6]:=6; UvDirT[7]:=6; end
  else for dir := 0 to 7 do UvDirT[dir] := dir;
  // pre-CDEF copies
  SetLength(YpPre, Length(Yp)); Move(Yp[0], YpPre[0], Length(Yp)*2);
  if Seq.NumPlanes = 3 then
  begin
    SetLength(UpPre, Length(Up)); Move(Up[0], UpPre[0], Length(Up)*2);
    SetLength(VpPre, Length(Vp)); Move(Vp[0], VpPre[0], Length(Vp)*2);
  end;
  by := 0;
  while by < FrmH4 do
  begin
    bx := 0;
    while bx < FrmW4 do
    begin
      ci := CdefIdxSb[(by shr 4)*N64w + (bx shr 4)];
      if ci = -1 then begin Inc(bx, 2); Continue; end;
      yLvl := (Fh.CdefYPriStrength[ci] shl 2) or Fh.CdefYSecStrength[ci];
      uvLvl := (Fh.CdefUVPriStrength[ci] shl 2) or Fh.CdefUVSecStrength[ci];
      if (yLvl = 0) and (uvLvl = 0) then begin Inc(bx, 2); Continue; end;
      // per-8x8 non-skip gate (any of the 2x2 mi is non-skip)
      if (NoskipMi[by*FrmW4 + bx] = 0) and
         ((bx+1 >= FrmW4) or (NoskipMi[by*FrmW4 + bx+1] = 0)) and
         ((by+1 >= FrmH4) or (NoskipMi[(by+1)*FrmW4 + bx] = 0)) and
         ((bx+1 >= FrmW4) or (by+1 >= FrmH4) or (NoskipMi[(by+1)*FrmW4 + bx+1] = 0)) then
      begin Inc(bx, 2); Continue; end;

      edges := 0;
      if bx > 0 then edges := edges or CD_LEFT;
      if bx + 2 < FrmW4 then edges := edges or CD_RIGHT;
      if by > 0 then edges := edges or CD_TOP;
      if by + 2 < FrmH4 then edges := edges or CD_BOTTOM;

      yPri := Fh.CdefYPriStrength[ci] shl SBdShift; ySec := Fh.CdefYSecStrength[ci] shl SBdShift;
      uvPri := Fh.CdefUVPriStrength[ci] shl SBdShift; uvSec := Fh.CdefUVSecStrength[ci] shl SBdShift;
      dir := 0; vari := 0;
      if (yPri <> 0) or (uvPri <> 0) then dir := CdefFindDir(@YpPre[0], FrmW, bx*4, by*4, vari);
      // luma 8x8
      if yPri <> 0 then
      begin
        adjPri := AdjustStrength(yPri, vari);
        if (adjPri <> 0) or (ySec <> 0) then
          CdefFilterBlock(@Yp[0], @YpPre[0], FrmW, bx*4, by*4, 8, 8, adjPri, ySec, dir, damping, edges);
      end
      else if ySec <> 0 then
        CdefFilterBlock(@Yp[0], @YpPre[0], FrmW, bx*4, by*4, 8, 8, 0, ySec, 0, damping, edges);
      // chroma
      if (uvLvl <> 0) and (Seq.NumPlanes = 3) then
      begin
        if uvPri <> 0 then uvdir := UvDirT[dir] else uvdir := 0;
        cpx := (bx*4) shr ssH; cpy := (by*4) shr ssV;
        cw := 8 shr ssH; ch := 8 shr ssV;
        CdefFilterBlock(@Up[0], @UpPre[0], FrmWc, cpx, cpy, cw, ch, uvPri, uvSec, uvdir, damping-1, edges);
        CdefFilterBlock(@Vp[0], @VpPre[0], FrmWc, cpx, cpy, cw, ch, uvPri, uvSec, uvdir, damping-1, edges);
      end;
      Inc(bx, 2);
    end;
    Inc(by, 2);
  end;
end;

// --- Loop restoration (Wiener / self-guided) --------------------------------
// Applied to the CDEF output. Stripe interiors read the CDEF frame; the 3 rows
// above/below each 64-row stripe come from the deblock-only frame (dav1d fills
// lr_lpf_line before CDEF). We keep full copies of both stages.
const
  REST = 390;                     // REST_UNIT_STRIDE
  SgrXbyX: array[0..255] of Byte = (
    255,128, 85, 64, 51, 43, 37, 32, 28, 26, 23, 21, 20, 18, 17,
     16, 15, 14, 13, 13, 12, 12, 11, 11, 10, 10,  9,  9,  9,  9,
      8,  8,  8,  8,  7,  7,  7,  7,  7,  6,  6,  6,  6,  6,  6,
      6,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  4,  4,  4,  4,
      4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  3,  3,
      3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,
      3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  2,  2,  2,
      2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
      2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
      2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
      2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
      2,  2,  2,  2,  2,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
      1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
      1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
      1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
      1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
      1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
      0);
  SgrParams: array[0..15, 0..1] of Integer = (
    (140,3236),(112,2158),(93,1618),(80,1438),(70,1295),(58,1177),(47,1079),(37,996),
    (30,925),(25,863),(0,2589),(0,1618),(0,1177),(0,925),(56,0),(22,0));
var
  YpCdefC, UpCdefC, VpCdefC: array of Word;   // post-CDEF (pre-LR) copies
  YpDbC, UpDbC, VpDbC: array of Word;         // deblock-only copies
  LrTmp: array[0..70*REST-1] of Word;              // pixels (native bit depth)
  LrHor: array[0..70*REST-1] of LongInt;
  LrSumsq: array[0..68*REST-1] of LongInt;
  LrSumB: array[0..68*REST-1] of LongInt;           // wider than SmallInt for >8-bit
  LrDst0, LrDst1: array[0..64*384-1] of LongInt;

function ClipT(v, lo, hi: Integer): Integer; inline;
begin if v < lo then Result := lo else if v > hi then Result := hi else Result := v; end;

// Build the padded stripe buffer LrTmp (dav1d padding()); interior from cdef,
// stripe boundaries from db. ux0/y0 = unit origin (plane px), rowEnd = y0+h.
procedure LrPadding(cdef, db: PWord; stride, ux0, y0, w, h, rowEnd, bufH, edges: Integer);
var r, c, sRow, srb, cols, tw: Integer; sf: PWord; defA, defB: Boolean;
begin
  cols := w + 6; tw := w;
  defA := False; defB := False;
  for r := 0 to h+5 do
  begin
    sf := nil; sRow := 0;
    if r <= 2 then
    begin
      if (edges and CD_TOP) <> 0 then begin sf := db; if r < 2 then sRow := y0-2 else sRow := y0-1; end
      else begin defA := True; Continue; end;
    end
    else if r >= 3+h then
    begin
      if (edges and CD_BOTTOM) <> 0 then begin sf := db; if r = 3+h then sRow := rowEnd else sRow := rowEnd+1; end
      else begin defB := True; Continue; end;
    end
    else begin sf := cdef; sRow := y0 + (r-3); end;
    if sRow < 0 then sRow := 0; if sRow > bufH-1 then sRow := bufH-1;
    srb := sRow*stride;
    for c := 0 to tw-1 do LrTmp[r*REST + 3 + c] := sf[srb + ux0 + c];
    if (edges and CD_LEFT) <> 0 then
      for c := 0 to 2 do LrTmp[r*REST + c] := sf[srb + ux0-3 + c]
    else
      for c := 0 to 2 do LrTmp[r*REST + c] := LrTmp[r*REST + 3];
    if (edges and CD_RIGHT) <> 0 then
      for c := 0 to 2 do LrTmp[r*REST + 3+tw + c] := sf[srb + ux0+tw + c]
    else
      for c := 0 to 2 do LrTmp[r*REST + 3+tw + c] := LrTmp[r*REST + 3+tw-1];
  end;
  if defA then for r := 0 to 2 do Move(LrTmp[3*REST], LrTmp[r*REST], cols*SizeOf(Word));
  if defB then for r := 3+h to 5+h do Move(LrTmp[(2+h)*REST], LrTmp[r*REST], cols*SizeOf(Word));
end;

procedure LrWiener(dstP: PWord; stride, ux0, y0, w, h: Integer; const fh, fv: array of Integer);
var f0, f1: array[0..6] of Integer; j, i, k: Integer; sum: LongInt;
  rbh, roh, clipLim, sumBase, rbv, rov, roff: Integer;
begin
  // bit-depth-dependent rounding (dav1d wiener_c)
  rbh := 3; if SBd = 12 then rbh := 5;
  roh := 1 shl (rbh-1);
  clipLim := (1 shl (SBd + 1 + 7 - rbh)) - 1;
  sumBase := 1 shl (SBd + 6);
  rbv := 11; if SBd = 12 then rbv := 9;
  rov := 1 shl (rbv-1);
  roff := 1 shl (SBd + rbv - 1);
  f0[0]:=fh[0]; f0[6]:=fh[0]; f0[1]:=fh[1]; f0[5]:=fh[1]; f0[2]:=fh[2]; f0[4]:=fh[2];
  f0[3]:=-(fh[0]+fh[1]+fh[2])*2;
  if SBd <> 8 then f0[3] := f0[3] + 128;   // 8-bit adds +128 per-sample instead
  f1[0]:=fv[0]; f1[6]:=fv[0]; f1[1]:=fv[1]; f1[5]:=fv[1]; f1[2]:=fv[2]; f1[4]:=fv[2];
  f1[3]:=128-(fv[0]+fv[1]+fv[2])*2;
  for j := 0 to h+5 do
    for i := 0 to w-1 do
    begin
      sum := sumBase;
      if SBd = 8 then Inc(sum, LrTmp[j*REST + i+3]*128);
      for k := 0 to 6 do Inc(sum, LrTmp[j*REST + i+k]*f0[k]);
      LrHor[j*REST + i] := ClipT((sum + roh) shr rbh, 0, clipLim);
    end;
  for j := 0 to h-1 do
    for i := 0 to w-1 do
    begin
      sum := -roff;
      for k := 0 to 6 do Inc(sum, LrHor[(j+k)*REST + i]*f1[k]);
      dstP[(y0+j)*stride + ux0 + i] := ClipQ((sum + rov) shr rbv);
    end;
end;

// boxsum over 3x3 (n=9) — writes LrSumsq/LrSumB (raw, row*REST+col).
procedure LrBoxsum3(w, h: Integer);
var x, y, r, sIdx, svIdx: Integer; a, a2, b, b2, c, c2: LongInt;
begin
  for x := 1 to w-2 do
  begin
    sIdx := REST + x;                 // src row1 col x
    a := LrTmp[sIdx]; a2 := a*a;
    b := LrTmp[sIdx + REST]; b2 := b*b;
    svIdx := x;                       // row0 col x
    for y := 2 to h-3 do
    begin
      sIdx := sIdx + REST;
      c := LrTmp[sIdx + REST]; c2 := c*c;
      svIdx := svIdx + REST;
      LrSumB[svIdx] := a + b + c;
      LrSumsq[svIdx] := a2 + b2 + c2;
      a := b; a2 := b2; b := c; b2 := c2;
    end;
  end;
  for y := 2 to h-3 do
  begin
    r := y-1;                        // C advances the row pointer once before the loop
    a := LrSumB[r*REST + 1]; a2 := LrSumsq[r*REST + 1];
    b := LrSumB[r*REST + 2]; b2 := LrSumsq[r*REST + 2];
    for x := 2 to w-3 do
    begin
      c := LrSumB[r*REST + x+1]; c2 := LrSumsq[r*REST + x+1];
      LrSumB[r*REST + x] := a + b + c;
      LrSumsq[r*REST + x] := a2 + b2 + c2;
      a := b; a2 := b2; b := c; b2 := c2;
    end;
  end;
end;

// boxsum over 5x5 (n=25).
procedure LrBoxsum5(w, h: Integer);
var x, y, r, sIdx, svIdx: Integer; a,a2,b,b2,c,c2,d,d2,e,e2: LongInt;
begin
  for x := 0 to w-1 do
  begin
    sIdx := 3*REST + x;
    a := LrTmp[sIdx - 3*REST]; a2 := a*a;
    b := LrTmp[sIdx - 2*REST]; b2 := b*b;
    c := LrTmp[sIdx - 1*REST]; c2 := c*c;
    d := LrTmp[sIdx]; d2 := d*d;
    svIdx := x;
    for y := 2 to h-3 do
    begin
      sIdx := sIdx + REST;
      e := LrTmp[sIdx]; e2 := e*e;
      svIdx := svIdx + REST;
      LrSumB[svIdx] := a+b+c+d+e;
      LrSumsq[svIdx] := a2+b2+c2+d2+e2;
      a:=b; b:=c; c:=d; d:=e; a2:=b2; b2:=c2; c2:=d2; d2:=e2;
    end;
  end;
  for y := 2 to h-3 do
  begin
    r := y-1;                        // C advances the row pointer once before the loop
    a := LrSumB[r*REST+0]; a2 := LrSumsq[r*REST+0];
    b := LrSumB[r*REST+1]; b2 := LrSumsq[r*REST+1];
    c := LrSumB[r*REST+2]; c2 := LrSumsq[r*REST+2];
    d := LrSumB[r*REST+3]; d2 := LrSumsq[r*REST+3];
    for x := 2 to w-3 do
    begin
      e := LrSumB[r*REST+x+2]; e2 := LrSumsq[r*REST+x+2];
      LrSumB[r*REST+x] := a+b+c+d+e;
      LrSumsq[r*REST+x] := a2+b2+c2+d2+e2;
      a:=b; b:=c; c:=d; d:=e; a2:=b2; b2:=c2; c2:=d2; d2:=e2;
    end;
  end;
end;

// self-guided filter -> dst[j*384+i] (dav1d selfguided_filter, 8-bit).
procedure LrSelfGuided(var dst: array of LongInt; w, h, n: Integer; s: LongWord);
var oneByX, step, Aofs, Bofs, AA, BB, j, i, srcOfs: Integer;
    av, bv, bLoc: LongInt; pv, zv, xv: LongWord; a6, b6: LongInt;
begin
  if n = 25 then oneByX := 164 else oneByX := 455;
  Aofs := 2*REST + 3; Bofs := 2*REST + 3;
  step := Ord(n = 25) + 1;
  if n = 25 then LrBoxsum5(w+6, h+6) else LrBoxsum3(w+6, h+6);
  AA := Aofs - REST; BB := Bofs - REST;
  j := -1;
  while j < h+1 do
  begin
    for i := -1 to w do
    begin
      // bitdepth_min_8 rounding (dav1d selfguided_filter); a/b only feed p->z->x,
      // while AA[i] is recomputed from the ORIGINAL (unshifted) BB[i].
      if SBdShift = 0 then
      begin av := LrSumsq[AA + i]; bLoc := LrSumB[BB + i]; end
      else
      begin
        av := (LrSumsq[AA + i] + ((1 shl (2*SBdShift)) shr 1)) shr (2*SBdShift);
        bLoc := (LrSumB[BB + i] + ((1 shl SBdShift) shr 1)) shr SBdShift;
      end;
      bv := LrSumB[BB + i];
      pv := LongWord(IMax(av*n - bLoc*bLoc, 0));
      zv := (pv * s + (1 shl 19)) shr 20;
      if zv > 255 then xv := SgrXbyX[255] else xv := SgrXbyX[zv];
      LrSumsq[AA + i] := (LongInt(xv) * bv * oneByX + (1 shl 11)) shr 12;
      LrSumB[BB + i] := xv;
    end;
    Inc(AA, step*REST); Inc(BB, step*REST);
    Inc(j, step);
  end;
  srcOfs := 3*REST + 3;
  if n = 25 then
  begin
    j := 0;
    while j < h-1 do
    begin
      for i := 0 to w-1 do
      begin
        a6 := (LrSumB[Bofs+j*REST+i-REST] + LrSumB[Bofs+j*REST+i+REST])*6 +
              (LrSumB[Bofs+j*REST+i-1-REST] + LrSumB[Bofs+j*REST+i-1+REST] +
               LrSumB[Bofs+j*REST+i+1-REST] + LrSumB[Bofs+j*REST+i+1+REST])*5;
        b6 := (LrSumsq[Aofs+j*REST+i-REST] + LrSumsq[Aofs+j*REST+i+REST])*6 +
              (LrSumsq[Aofs+j*REST+i-1-REST] + LrSumsq[Aofs+j*REST+i-1+REST] +
               LrSumsq[Aofs+j*REST+i+1-REST] + LrSumsq[Aofs+j*REST+i+1+REST])*5;
        dst[j*384+i] := (b6 - a6*LrTmp[srcOfs+j*REST+i] + (1 shl 8)) shr 9;
      end;
      for i := 0 to w-1 do
      begin
        a6 := LrSumB[Bofs+(j+1)*REST+i]*6 + (LrSumB[Bofs+(j+1)*REST+i-1] + LrSumB[Bofs+(j+1)*REST+i+1])*5;
        b6 := LrSumsq[Aofs+(j+1)*REST+i]*6 + (LrSumsq[Aofs+(j+1)*REST+i-1] + LrSumsq[Aofs+(j+1)*REST+i+1])*5;
        dst[(j+1)*384+i] := (b6 - a6*LrTmp[srcOfs+(j+1)*REST+i] + (1 shl 7)) shr 8;
      end;
      Inc(j, 2);
    end;
    if j = h-1 then
      for i := 0 to w-1 do
      begin
        a6 := (LrSumB[Bofs+j*REST+i-REST] + LrSumB[Bofs+j*REST+i+REST])*6 +
              (LrSumB[Bofs+j*REST+i-1-REST] + LrSumB[Bofs+j*REST+i-1+REST] +
               LrSumB[Bofs+j*REST+i+1-REST] + LrSumB[Bofs+j*REST+i+1+REST])*5;
        b6 := (LrSumsq[Aofs+j*REST+i-REST] + LrSumsq[Aofs+j*REST+i+REST])*6 +
              (LrSumsq[Aofs+j*REST+i-1-REST] + LrSumsq[Aofs+j*REST+i-1+REST] +
               LrSumsq[Aofs+j*REST+i+1-REST] + LrSumsq[Aofs+j*REST+i+1+REST])*5;
        dst[j*384+i] := (b6 - a6*LrTmp[srcOfs+j*REST+i] + (1 shl 8)) shr 9;
      end;
  end
  else
  begin
    for j := 0 to h-1 do
      for i := 0 to w-1 do
      begin
        a6 := (LrSumB[Bofs+j*REST+i] + LrSumB[Bofs+j*REST+i-1] + LrSumB[Bofs+j*REST+i+1] +
               LrSumB[Bofs+j*REST+i-REST] + LrSumB[Bofs+j*REST+i+REST])*4 +
              (LrSumB[Bofs+j*REST+i-1-REST] + LrSumB[Bofs+j*REST+i-1+REST] +
               LrSumB[Bofs+j*REST+i+1-REST] + LrSumB[Bofs+j*REST+i+1+REST])*3;
        b6 := (LrSumsq[Aofs+j*REST+i] + LrSumsq[Aofs+j*REST+i-1] + LrSumsq[Aofs+j*REST+i+1] +
               LrSumsq[Aofs+j*REST+i-REST] + LrSumsq[Aofs+j*REST+i+REST])*4 +
              (LrSumsq[Aofs+j*REST+i-1-REST] + LrSumsq[Aofs+j*REST+i-1+REST] +
               LrSumsq[Aofs+j*REST+i+1-REST] + LrSumsq[Aofs+j*REST+i+1+REST])*3;
        dst[j*384+i] := (b6 - a6*LrTmp[srcOfs+j*REST+i] + (1 shl 8)) shr 9;
      end;
  end;
end;

// One stripe chunk with unit params U. dst=final plane, cdef/db copies, stride.
procedure LrStripeChunk(dstP, cdef, db: PWord; stride, ux0, y0, w, h, rowEnd, bufH, edges: Integer;
  const U: TLrUnit);
var i, j, s0, s1, w0, w1, v: Integer;
begin
  LrPadding(cdef, db, stride, ux0, y0, w, h, rowEnd, bufH, edges);
  if U.typ = RESTORE_WIENER then
  begin
    LrWiener(dstP, stride, ux0, y0, w, h, U.fh, U.fv);
    Exit;
  end;
  // SGR
  s0 := SgrParams[U.sgrIdx][0]; s1 := SgrParams[U.sgrIdx][1];
  w0 := U.sw[0]; w1 := 128 - (U.sw[0] + U.sw[1]);
  if (s0 <> 0) and (s1 <> 0) then
  begin
    LrSelfGuided(LrDst0, w, h, 25, s0);
    LrSelfGuided(LrDst1, w, h, 9, s1);
    for j := 0 to h-1 do
      for i := 0 to w-1 do
      begin
        v := w0*LrDst0[j*384+i] + w1*LrDst1[j*384+i];
        dstP[(y0+j)*stride+ux0+i] := ClipQ(dstP[(y0+j)*stride+ux0+i] + ((v + (1 shl 10)) shr 11));
      end;
  end
  else if s0 <> 0 then
  begin
    LrSelfGuided(LrDst0, w, h, 25, s0);
    for j := 0 to h-1 do
      for i := 0 to w-1 do
      begin
        v := w0*LrDst0[j*384+i];
        dstP[(y0+j)*stride+ux0+i] := ClipQ(dstP[(y0+j)*stride+ux0+i] + ((v + (1 shl 10)) shr 11));
      end;
  end
  else
  begin
    LrSelfGuided(LrDst1, w, h, 9, s1);
    for j := 0 to h-1 do
      for i := 0 to w-1 do
      begin
        v := w1*LrDst1[j*384+i];
        dstP[(y0+j)*stride+ux0+i] := ClipQ(dstP[(y0+j)*stride+ux0+i] + ((v + (1 shl 10)) shr 11));
      end;
  end;
end;

// Filter one plane (dav1d lr_sbrow driven over all SB rows).
procedure LrPlane(p: Integer; dstP, cdef, db: PWord; stride, w, h, bufH: Integer);
var plsv, ulog2, usz, halfU, maxU, sbh, sby, offY, notLast, nextRy, rowH, yStripe: Integer;
    rowY, alignedPos, uyc, x, ux, restore, edges, y, stripeH, rowEnd, unitW, gi: Integer;
begin
  if p = 0 then plsv := 0 else plsv := ssV;
  ulog2 := LrUnitLog2[p]; usz := 1 shl ulog2; halfU := usz shr 1; maxU := usz + halfU;
  sbh := N64h;
  for sby := 0 to sbh-1 do
  begin
    offY := 8 shr plsv; if sby = 0 then offY := 0;
    notLast := Ord(sby+1 < sbh);
    nextRy := (sby+1) shl (6 - plsv);
    rowH := IMin(nextRy - (8 shr plsv)*notLast, h);
    yStripe := (sby shl (6 - plsv)) - offY;
    // vertical unit row
    if yStripe > 0 then rowY := yStripe + (8 shr plsv) else rowY := yStripe;
    alignedPos := rowY and not (usz-1);
    if (alignedPos <> 0) and (alignedPos + halfU > h) then Dec(alignedPos, usz);
    uyc := alignedPos shr ulog2;
    // horizontal loop over units
    edges := CD_RIGHT; if yStripe > 0 then edges := edges or CD_TOP;
    x := 0;
    while x + maxU <= w do
    begin
      ux := x shr ulog2;
      gi := uyc*LrUnitsW[p] + ux;
      restore := 0;
      if (gi >= 0) and (gi < Length(LrGrid[p])) then restore := Ord(LrGrid[p][gi].typ <> RESTORE_NONE);
      // chunk loop (vertical) within this sby band for this unit column
      if restore <> 0 then
      begin
        y := yStripe;
        stripeH := IMin((64 - 8*Ord(y=0)) shr plsv, rowH - y);
        while y + stripeH <= rowH do
        begin
          rowEnd := y + stripeH;
          if (notLast <> 0) or (rowEnd <> rowH) then edges := edges or CD_BOTTOM else edges := edges and not CD_BOTTOM;
          if y > 0 then edges := edges or CD_TOP;
          LrStripeChunk(dstP, cdef, db, stride, x, y, usz, stripeH, rowEnd, bufH, edges, LrGrid[p][gi]);
          Inc(y, stripeH);
          stripeH := IMin(64 shr plsv, rowH - y);
          if stripeH = 0 then Break;
        end;
      end;
      Inc(x, usz);
      edges := edges or CD_LEFT;
    end;
    // last (partial) unit
    ux := x shr ulog2;
    gi := uyc*LrUnitsW[p] + ux;
    restore := 0;
    if (gi >= 0) and (gi < Length(LrGrid[p])) then restore := Ord(LrGrid[p][gi].typ <> RESTORE_NONE);
    if restore <> 0 then
    begin
      edges := edges and not CD_RIGHT;
      unitW := w - x;
      y := yStripe;
      stripeH := IMin((64 - 8*Ord(y=0)) shr plsv, rowH - y);
      while y + stripeH <= rowH do
      begin
        rowEnd := y + stripeH;
        if (notLast <> 0) or (rowEnd <> rowH) then edges := edges or CD_BOTTOM else edges := edges and not CD_BOTTOM;
        if y > 0 then edges := edges or CD_TOP;
        LrStripeChunk(dstP, cdef, db, stride, x, y, unitW, stripeH, rowEnd, bufH, edges, LrGrid[p][gi]);
        Inc(y, stripeH);
        stripeH := IMin(64 shr plsv, rowH - y);
        if stripeH = 0 then Break;
      end;
    end;
  end;
end;

procedure LrFrame;
begin
  if not Fh.UsesLr then Exit;
  SetLength(YpCdefC, Length(Yp)); Move(Yp[0], YpCdefC[0], Length(Yp)*2);
  SetLength(YpDbC, Length(YpPre)); if Length(YpPre) > 0 then Move(YpPre[0], YpDbC[0], Length(YpPre)*2);
  if Fh.FrameRestorationType[0] <> RESTORE_NONE then
    LrPlane(0, @Yp[0], @YpCdefC[0], @YpDbC[0], FrmW, FrmW, FrmH, FrmH4*4);
  if Seq.NumPlanes = 3 then
  begin
    SetLength(UpCdefC, Length(Up)); Move(Up[0], UpCdefC[0], Length(Up)*2);
    SetLength(VpCdefC, Length(Vp)); Move(Vp[0], VpCdefC[0], Length(Vp)*2);
    SetLength(UpDbC, Length(UpPre)); if Length(UpPre) > 0 then Move(UpPre[0], UpDbC[0], Length(UpPre)*2);
    SetLength(VpDbC, Length(VpPre)); if Length(VpPre) > 0 then Move(VpPre[0], VpDbC[0], Length(VpPre)*2);
    if Fh.FrameRestorationType[1] <> RESTORE_NONE then
      LrPlane(1, @Up[0], @UpCdefC[0], @UpDbC[0], FrmWc, FrmWc, FrmHc, FrmH4c*4);
    if Fh.FrameRestorationType[2] <> RESTORE_NONE then
      LrPlane(2, @Vp[0], @VpCdefC[0], @VpDbC[0], FrmWc, FrmWc, FrmHc, FrmH4c*4);
  end;
end;

// Neighbour-context resets (dav1d reset_context). Above persists down a tile;
// left resets each superblock row.
procedure ResetAboveCtx;
begin
  FillChar(partA, SizeOf(partA), 0); FillChar(skipA, SizeOf(skipA), 0);
  FillChar(modeA, SizeOf(modeA), 0); FillChar(uvmodeA, SizeOf(uvmodeA), 0);
  FillChar(txiA, SizeOf(txiA), $FF);
  FillChar(palSzA, SizeOf(palSzA), 0); FillChar(palSzUvA, SizeOf(palSzUvA), 0);
  FillChar(caY, SizeOf(caY), $40); FillChar(caU, SizeOf(caU), $40); FillChar(caV, SizeOf(caV), $40);
end;
procedure ResetLeftCtx;
begin
  FillChar(partL, SizeOf(partL), 0); FillChar(skipL, SizeOf(skipL), 0);
  FillChar(modeL, SizeOf(modeL), 0); FillChar(uvmodeL, SizeOf(uvmodeL), 0);
  FillChar(txiL, SizeOf(txiL), $FF);
  FillChar(palSzL, SizeOf(palSzL), 0); FillChar(palSzUvL, SizeOf(palSzUvL), 0);
  FillChar(clY, SizeOf(clY), $40); FillChar(clU, SizeOf(clU), $40); FillChar(clV, SizeOf(clV), $40);
end;

// Read one restoration unit's info (dav1d read_restoration_info) and store the
// decoded params into LrGrid[p] at unit (uy,ux). lrRef* track the subexp base.
procedure ReadRestorationInfo(p, frameType, uy, ux: Integer);
var lrType, filt, tt, idx, gi: Integer;
begin
  if frameType = RESTORE_SWITCHABLE then
  begin
    filt := MsacDecodeSymbolAdapt(Msac, @Cdf.m.restore_switchable[0], 2);
    if filt = 0 then lrType := RESTORE_NONE
    else if filt = 2 then lrType := RESTORE_SGRPROJ else lrType := RESTORE_WIENER;
  end
  else
  begin
    if frameType = RESTORE_WIENER then tt := MsacDecodeBoolAdapt(Msac, @Cdf.m.restore_wiener[0])
    else tt := MsacDecodeBoolAdapt(Msac, @Cdf.m.restore_sgrproj[0]);
    if tt <> 0 then lrType := frameType else lrType := RESTORE_NONE;
  end;
  if lrType = RESTORE_WIENER then
  begin
    if p = 0 then lrRefFV[p][0] := MsacDecodeSubexp(Msac, lrRefFV[p][0]+5, 16, 1)-5 else lrRefFV[p][0] := 0;
    lrRefFV[p][1] := MsacDecodeSubexp(Msac, lrRefFV[p][1]+23, 32, 2)-23;
    lrRefFV[p][2] := MsacDecodeSubexp(Msac, lrRefFV[p][2]+17, 64, 3)-17;
    if p = 0 then lrRefFH[p][0] := MsacDecodeSubexp(Msac, lrRefFH[p][0]+5, 16, 1)-5 else lrRefFH[p][0] := 0;
    lrRefFH[p][1] := MsacDecodeSubexp(Msac, lrRefFH[p][1]+23, 32, 2)-23;
    lrRefFH[p][2] := MsacDecodeSubexp(Msac, lrRefFH[p][2]+17, 64, 3)-17;
    if DbgTrace then Writeln(ErrOutput, Format('Post-lr_wiener[pl=%d]: r=%d', [p, Msac.Rng]));
  end
  else if lrType = RESTORE_SGRPROJ then
  begin
    idx := MsacDecodeBools(Msac, 4);
    if SgrP0[idx] then lrRefSgr[p][0] := MsacDecodeSubexp(Msac, lrRefSgr[p][0]+96, 128, 4)-96 else lrRefSgr[p][0] := 0;
    if SgrP1[idx] then lrRefSgr[p][1] := MsacDecodeSubexp(Msac, lrRefSgr[p][1]+32, 128, 4)-32 else lrRefSgr[p][1] := 95;
    if DbgTrace then Writeln(ErrOutput, Format('Post-lr_sgrproj[pl=%d,idx=%d]: r=%d', [p, idx, Msac.Rng]));
  end;
  // store into grid
  gi := uy*LrUnitsW[p] + ux;
  if (gi >= 0) and (gi < Length(LrGrid[p])) then
  begin
    LrGrid[p][gi].typ := lrType;
    if lrType = RESTORE_WIENER then
    begin
      LrGrid[p][gi].fv[0] := lrRefFV[p][0]; LrGrid[p][gi].fv[1] := lrRefFV[p][1]; LrGrid[p][gi].fv[2] := lrRefFV[p][2];
      LrGrid[p][gi].fh[0] := lrRefFH[p][0]; LrGrid[p][gi].fh[1] := lrRefFH[p][1]; LrGrid[p][gi].fh[2] := lrRefFH[p][2];
    end
    else if lrType = RESTORE_SGRPROJ then
    begin
      LrGrid[p][gi].sgrIdx := idx;
      LrGrid[p][gi].sw[0] := lrRefSgr[p][0]; LrGrid[p][gi].sw[1] := lrRefSgr[p][1];
    end;
  end;
end;

// Per-superblock LR read (no-superres path). sbx,sby = SB origin (luma mi).
procedure ReadLrSb(sbx, sby: Integer);
var p, plSv, plSh, usz, mask, halfU, y, h, x, w: Integer;
begin
  for p := 0 to 2 do
  begin
    if Fh.FrameRestorationType[p] = RESTORE_NONE then Continue;
    plSv := 0; plSh := 0;
    if p <> 0 then begin plSv := ssV; plSh := ssH; end;
    if p = 0 then usz := Fh.LoopRestorationSize[0] else usz := Fh.LoopRestorationSize[1];
    mask := usz - 1; halfU := usz shr 1;
    y := (sby*4) shr plSv;  h := (FrmH + plSv) shr plSv;
    if (y and mask) <> 0 then Continue;
    if (y <> 0) and (y + halfU > h) then Continue;
    x := (sbx*4) shr plSh; w := (FrmW + plSh) shr plSh;
    if (x and mask) <> 0 then Continue;
    if (x <> 0) and (x + halfU > w) then Continue;
    ReadRestorationInfo(p, Fh.FrameRestorationType[p], y shr LrUnitLog2[p], x shr LrUnitLog2[p]);
  end;
end;

// Parse the tile-group header and decode every tile it covers. Each tile has
// its own CDF copy (from frame default), MSAC, and neighbour contexts.
procedure DecodeAllTiles;
var
  B: TAv1Bits; numTiles, tgStart, tgEnd, tileBits, tileNum, tr, tc, startPresent: Integer;
  RootBl, sbStep, sbx, sby, colS, colE, rowS, rowE: Integer;
  p: PByte; hdrBytes, rem, curTsz: NativeInt;
begin
  if Seq.Use128x128Superblock then begin RootBl := BL_128X128; sbStep := 32; end
  else begin RootBl := BL_64X64; sbStep := 16; end;
  numTiles := Fh.TileCols * Fh.TileRows;
  B := TAv1Bits.Create(TilePtr, TileSize);
  startPresent := 0;
  if numTiles > 1 then startPresent := B.f(1);
  if (numTiles = 1) or (startPresent = 0) then begin tgStart := 0; tgEnd := numTiles - 1; end
  else begin tileBits := Fh.TileColsLog2 + Fh.TileRowsLog2; tgStart := B.f(tileBits); tgEnd := B.f(tileBits); end;
  B.ByteAlign;
  hdrBytes := B.BytePos;
  B.Free;
  p := TilePtr + hdrBytes;
  rem := TileSize - hdrBytes;
  if DbgTrace then Writeln(ErrOutput, Format('TG: numTiles=%d start=%d tg=%d..%d hdrBytes=%d TileSize=%d TileSizeBytes=%d cols=%d rows=%d MiCol[0..2]=%d,%d,%d',
    [numTiles, startPresent, tgStart, tgEnd, hdrBytes, TileSize, Fh.TileSizeBytes, Fh.TileCols, Fh.TileRows, Fh.MiColStarts[0], Fh.MiColStarts[1], Fh.MiColStarts[2]]));
  for tileNum := tgStart to tgEnd do
  begin
    tr := tileNum div Fh.TileCols; tc := tileNum mod Fh.TileCols;
    if tileNum = tgEnd then curTsz := rem
    else
    begin
      B := TAv1Bits.Create(p, Fh.TileSizeBytes);
      curTsz := NativeInt(B.le(Fh.TileSizeBytes)) + 1;   // tile_size_minus_1
      B.Free;
      Inc(p, Fh.TileSizeBytes); Dec(rem, Fh.TileSizeBytes);
    end;
    colS := Fh.MiColStarts[tc]; colE := Fh.MiColStarts[tc+1];
    rowS := Fh.MiRowStarts[tr]; rowE := Fh.MiRowStarts[tr+1];
    if DbgTrace then Writeln(ErrOutput, Format('  tile %d: tc=%d tr=%d size=%d data0=%.2x cols[%d..%d] rows[%d..%d]',
      [tileNum, tc, tr, curTsz, p[0], colS, colE, rowS, rowE]));
    TileColMi := colS; TileRowMi := rowS; TileColEndMi := colE; TileRowEndMi := rowE;
    LoadCdfDefault(Cdf, QCatIdx(Fh.BaseQIdx));
    MsacInit(Msac, p, curTsz, Fh.DisableCdfUpdate);
    if DbgTrace and (tileNum = tgStart) then Writeln(ErrOutput, Format('  baseQ=%d qcat=%d disableCdf=%d initRng=%d p[0..3]=%.2x %.2x %.2x %.2x',
      [Fh.BaseQIdx, QCatIdx(Fh.BaseQIdx), Ord(Fh.DisableCdfUpdate), Msac.Rng, p[0], p[1], p[2], p[3]]));
    ResetAboveCtx;
    // init LR reference units (dav1d dav1d_decode_tile default values)
    for tr := 0 to 2 do
    begin
      lrRefFV[tr][0] := 3; lrRefFV[tr][1] := -7; lrRefFV[tr][2] := 15;
      lrRefFH[tr][0] := 3; lrRefFH[tr][1] := -7; lrRefFH[tr][2] := 15;
      lrRefSgr[tr][0] := -32; lrRefSgr[tr][1] := 31;
    end;
    sby := rowS;
    while sby < rowE do
    begin
      ResetLeftCtx;
      sbx := colS;
      while sbx < colE do
      begin
        if Fh.UsesLr then ReadLrSb(sbx, sby);
        DecodeSb(RootBl, sbx, sby, ALLTR);
        Inc(sbx, sbStep);
      end;
      Inc(sby, sbStep);
    end;
    Inc(p, curTsz); Dec(rem, curTsz);
  end;
end;

function Av1Decode(Data: PByte; Size: NativeInt; out F: TAv1Frame): Boolean;
var
  Obus: TObuArray;
  FhEnd: NativeInt;
  I, bad, n: Integer;
begin
  Result := False;
  DbgTrace := GetEnvironmentVariable('DBGT') <> '';
  Av1.Recon.DebugCoefs := GetEnvironmentVariable('DBGC') <> '';
  Obus := SplitObus(Data, Size);
  TilePtr := nil; TileSize := 0;
  if GetEnvironmentVariable('DBGT') <> '' then
    for I := 0 to High(Obus) do
      Writeln(ErrOutput, Format('OBU[%d] type=%d payloadSize=%d', [I, Obus[I].ObuType, Obus[I].PayloadSize]));
  for I := 0 to High(Obus) do
    case Obus[I].ObuType of
      OBU_SEQUENCE_HEADER: ParseSequenceHeader(Obus[I].Payload, Obus[I].PayloadSize, Seq);
      OBU_FRAME_HEADER: ParseFrameHeader(Seq, Obus[I].Payload, Obus[I].PayloadSize, Fh, FhEnd);
      OBU_TILE_GROUP: begin TilePtr := Obus[I].Payload; TileSize := Obus[I].PayloadSize; end;
      OBU_FRAME: begin ParseFrameHeader(Seq, Obus[I].Payload, Obus[I].PayloadSize, Fh, FhEnd);
        TilePtr := Obus[I].Payload + FhEnd; TileSize := Obus[I].PayloadSize - FhEnd; end;
    end;

  // bit-depth setup (drives all pixel clamps/dequant/filters)
  SBd := Seq.BitDepth; SPixMax := (1 shl SBd) - 1; SPixBase := 1 shl (SBd - 1); SBdShift := SBd - 8;
  IPredMax := SPixMax;
  LfMax := SPixMax; LfBdShift := SBdShift; LfFlatLim := 1 shl SBdShift;
  if SBd = 8 then Av1.Recon.ReconCfMax := (1 shl 15) - 1
  else Av1.Recon.ReconCfMax := (1 shl (SBd + 7)) - 1;

  FrmW := Fh.FrameWidth; FrmH := Fh.FrameHeight; FrmW4 := (FrmW+3) shr 2; FrmH4 := (FrmH+3) shr 2;
  ssH := Seq.SubsamplingX; ssV := Seq.SubsamplingY;
  if Seq.MonoChrome then begin ssH := 1; ssV := 1; end;
  FrmWc := (FrmW + ssH) shr ssH; FrmHc := (FrmH + ssV) shr ssV;
  FrmW4c := (FrmWc+3) shr 2; FrmH4c := (FrmHc+3) shr 2;
  if (ssH = 1) and (ssV = 1) then Move(MaxTxCh420[0], MaxTxChSel[0], SizeOf(MaxTxChSel))
  else if (ssH = 1) and (ssV = 0) then Move(MaxTxCh422[0], MaxTxChSel[0], SizeOf(MaxTxChSel))
  else Move(MaxTxCh444[0], MaxTxChSel[0], SizeOf(MaxTxChSel));
  // planes padded to the mi grid (blocks in a partial edge SB extend to FrmH4*4).
  SetLength(Yp, FrmW*(FrmH4*4)); SetLength(Up, FrmWc*(FrmH4c*4)); SetLength(Vp, FrmWc*(FrmH4c*4));
  SetLength(LvY0, FrmW4*FrmH4); SetLength(LvY1, FrmW4*FrmH4);
  SetLength(LvU, FrmW4c*FrmH4c); SetLength(LvV, FrmW4c*FrmH4c);
  SetLength(VstY, FrmW4*FrmH4); SetLength(HstY, FrmW4*FrmH4);
  SetLength(WcY, FrmW4*FrmH4); SetLength(HcY, FrmW4*FrmH4);
  SetLength(VstC, FrmW4c*FrmH4c); SetLength(HstC, FrmW4c*FrmH4c);
  SetLength(WcC, FrmW4c*FrmH4c); SetLength(HcC, FrmW4c*FrmH4c);
  N64w := (FrmW4 + 15) shr 4; N64h := (FrmH4 + 15) shr 4;
  SetLength(NoskipMi, FrmW4*FrmH4);       // zero-initialised
  SetLength(CdefIdxSb, N64w*N64h);
  for I := 0 to High(CdefIdxSb) do CdefIdxSb[I] := -1;
  // LR per-unit param grids (records default-zero => typ=RESTORE_NONE=0)
  for n := 0 to 2 do
  begin
    if n = 0 then bad := Fh.LoopRestorationSize[0] else bad := Fh.LoopRestorationSize[1];
    LrUnitLog2[n] := 0; while (1 shl LrUnitLog2[n]) < bad do Inc(LrUnitLog2[n]);
    if n = 0 then begin I := FrmW; bad := FrmH; end else begin I := FrmWc; bad := FrmHc; end;
    LrUnitsW[n] := ((I + (1 shl LrUnitLog2[n]) - 1) shr LrUnitLog2[n]) + 1;
    LrUnitsH[n] := ((bad + (1 shl LrUnitLog2[n]) - 1) shr LrUnitLog2[n]) + 1;
    SetLength(LrGrid[n], LrUnitsW[n]*LrUnitsH[n]);
  end;
  QIdxZero := Fh.BaseQIdx = 0;
  // per-plane dequant: Y-AC uses base; DC and chroma add signalled deltas.
  DqYDc := DqDc(Clip255(Fh.BaseQIdx + Fh.DeltaQYDc)); DqYAc := DqAc(Fh.BaseQIdx);
  DqUDc := DqDc(Clip255(Fh.BaseQIdx + Fh.DeltaQUDc)); DqUAc := DqAc(Clip255(Fh.BaseQIdx + Fh.DeltaQUAc));
  DqVDc := DqDc(Clip255(Fh.BaseQIdx + Fh.DeltaQVDc)); DqVAc := DqAc(Clip255(Fh.BaseQIdx + Fh.DeltaQVAc));

  if DbgTrace then Writeln(ErrOutput, Format('LR: types=%d,%d,%d sizes=%d,%d,%d usesLr=%d',
    [Fh.FrameRestorationType[0], Fh.FrameRestorationType[1], Fh.FrameRestorationType[2],
     Fh.LoopRestorationSize[0], Fh.LoopRestorationSize[1], Fh.LoopRestorationSize[2], Ord(Fh.UsesLr)]));
  if DbgTrace then Writeln(ErrOutput, Format('SR: useSuperres=%d FrameW=%d UpscaledW=%d denom=%d UsingQM=%d', [Ord(Fh.UseSuperres), Fh.FrameWidth, Fh.UpscaledWidth, Fh.SuperresDenom, Ord(Fh.UsingQMatrix)]));
  if DbgTrace then Writeln(ErrOutput, Format('CDEF: bits=%d damp=%d yPri[0..3]=%d,%d,%d,%d ySec[0..3]=%d,%d,%d,%d uvPri0=%d uvSec0=%d',
    [Fh.CdefBits, Fh.CdefDampingMinus3+3, Fh.CdefYPriStrength[0], Fh.CdefYPriStrength[1], Fh.CdefYPriStrength[2], Fh.CdefYPriStrength[3],
     Fh.CdefYSecStrength[0], Fh.CdefYSecStrength[1], Fh.CdefYSecStrength[2], Fh.CdefYSecStrength[3], Fh.CdefUVPriStrength[0], Fh.CdefUVSecStrength[0]]));
  if DbgTrace then Writeln(ErrOutput, Format('FLAGS: FilterIntra=%d TxMode=%d ss=%d,%d ScreenContent=%d ReducedTx=%d tiles=%dx%d',
    [Ord(Seq.EnableFilterIntra), Fh.TxMode, ssH, ssV, Fh.AllowScreenContentTools, Ord(Fh.ReducedTxSet), Fh.TileCols, Fh.TileRows]));

  DecodeAllTiles;
  if GetEnvironmentVariable('NOLF') = '' then DeblockFrame;
  // save deblock-only copies (LR stripe boundaries read the pre-CDEF frame)
  SetLength(YpPre, Length(Yp)); Move(Yp[0], YpPre[0], Length(Yp)*2);
  if Seq.NumPlanes = 3 then
  begin
    SetLength(UpPre, Length(Up)); Move(Up[0], UpPre[0], Length(Up)*2);
    SetLength(VpPre, Length(Vp)); Move(Vp[0], VpPre[0], Length(Vp)*2);
  end;
  if GetEnvironmentVariable('NOCDEF') = '' then CdefFrame;
  if GetEnvironmentVariable('NOLR') = '' then LrFrame;

  // Fill the output record with cropped planes (stride = plane width).
  F.Width := FrmW; F.Height := FrmH; F.BitDepth := SBd;
  F.SsH := ssH; F.SsV := ssV;
  F.NumPlanes := Seq.NumPlanes;
  n := FrmW*FrmH;
  SetLength(F.Y, n); Move(Yp[0], F.Y[0], n*2);
  if Seq.NumPlanes = 3 then
  begin
    F.ChromaW := FrmWc; F.ChromaH := FrmHc;
    SetLength(F.U, FrmWc*FrmHc); Move(Up[0], F.U[0], FrmWc*FrmHc*2);
    SetLength(F.V, FrmWc*FrmHc); Move(Vp[0], F.V[0], FrmWc*FrmHc*2);
  end
  else begin F.ChromaW := 0; F.ChromaH := 0; end;
  Result := True;
end;

end.
