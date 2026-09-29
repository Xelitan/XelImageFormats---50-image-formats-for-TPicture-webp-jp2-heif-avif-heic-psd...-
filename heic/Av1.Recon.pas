unit Av1.Recon;

// AV1 coefficient (residual) decoding — the entropy half of dav1d's decode_coefs
// (recon_tmpl.c). Reads the all-zero flag, transform type, end-of-block, and the
// coefficient tokens for one transform block, adapting the CDFs. Dequantisation
// and the inverse transform are layered on later.
//
// Reference: dav1d src/recon_tmpl.c decode_coefs, src/env.h context helpers.

{$mode delphi}{$H+}
{$RANGECHECKS OFF}{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, Av1.Cdf, Av1.Msac;

var
  DebugCoefs: Boolean = False;
  ReconCfMax: Integer = 32767;   // coefficient clamp: (1 shl ((bd=8?8:bd)+7))-1

const
  // Square transform sizes.
  TX_4X4 = 0; TX_8X8 = 1; TX_16X16 = 2; TX_32X32 = 3; TX_64X64 = 4;
  // Transform types (subset).
  DCT_DCT = 0;
  TX_CLASS_2D = 0; TX_CLASS_H = 1; TX_CLASS_V = 2;

type
  TTxfmInfo = record
    w, h, lw, lh, min, max, ctx: Integer;
  end;

const
  // dav1d_txfm_dimensions (square sizes; enough for the current path).
  TxfmDim: array[0..18] of TTxfmInfo = (
    (w:1;  h:1;  lw:0; lh:0; min:0; max:0; ctx:0),   // TX_4X4
    (w:2;  h:2;  lw:1; lh:1; min:1; max:1; ctx:1),   // TX_8X8
    (w:4;  h:4;  lw:2; lh:2; min:2; max:2; ctx:2),   // TX_16X16
    (w:8;  h:8;  lw:3; lh:3; min:3; max:3; ctx:3),   // TX_32X32
    (w:16; h:16; lw:4; lh:4; min:4; max:4; ctx:4),   // TX_64X64
    (w:1;  h:2;  lw:0; lh:1; min:0; max:1; ctx:1),   // RTX_4X8
    (w:2;  h:1;  lw:1; lh:0; min:0; max:1; ctx:1),   // RTX_8X4
    (w:2;  h:4;  lw:1; lh:2; min:1; max:2; ctx:2),   // RTX_8X16
    (w:4;  h:2;  lw:2; lh:1; min:1; max:2; ctx:2),   // RTX_16X8
    (w:4;  h:8;  lw:2; lh:3; min:2; max:3; ctx:3),   // RTX_16X32
    (w:8;  h:4;  lw:3; lh:2; min:2; max:3; ctx:3),   // RTX_32X16
    (w:8;  h:16; lw:3; lh:4; min:3; max:4; ctx:4),   // RTX_32X64
    (w:16; h:8;  lw:4; lh:3; min:3; max:4; ctx:4),   // RTX_64X32
    (w:1;  h:4;  lw:0; lh:2; min:0; max:2; ctx:1),   // RTX_4X16
    (w:4;  h:1;  lw:2; lh:0; min:0; max:2; ctx:1),   // RTX_16X4
    (w:2;  h:8;  lw:1; lh:3; min:1; max:3; ctx:2),   // RTX_8X32
    (w:8;  h:2;  lw:3; lh:1; min:1; max:3; ctx:2),   // RTX_32X8
    (w:4;  h:16; lw:2; lh:4; min:2; max:4; ctx:3),   // RTX_16X64
    (w:16; h:4;  lw:4; lh:2; min:2; max:4; ctx:3)    // RTX_64X16
  );

  SkipCtxTab: array[0..4, 0..4] of Byte = (
    (1,2,2,2,3),(2,4,4,4,5),(2,4,4,4,5),(2,4,4,4,5),(3,5,5,5,6));

// Decodes one transform block's coefficients and dequantises them.
// A/L point to the above/left coefficient-context byte arrays.
// ADqDc/ADqAc are the DC/AC dequant multipliers for this plane; ACf receives
// the dequantised coefficients in raster order (must hold tx_w*tx_h int32s).
// Returns the eob (>=0), or -1 if the block is all-zero.
function DecodeCoefs(var M: TMsac; var Cdf: TCdfContext;
  ATx, ABsW4, ABsH4: Integer; AIntra, APlane, AChroma: Integer;
  ASsHor, ASsVer: Integer; A, L: PByte;
  ADqDc, ADqAc: Integer; ACf: PInteger;
  AYMode, AUvMode: Integer; AReducedTxtp, AQidxZero: Boolean;
  out ATxtp: Integer; out AResCtx: Integer): Integer;

implementation

function IMin(A, B: Integer): Integer; inline;
begin if A < B then Result := A else Result := B; end;

function IMax(A, B: Integer): Integer; inline;
begin if A > B then Result := A else Result := B; end;

// read_golomb (recon_tmpl.c) — exp-golomb suffix via equiprobable bits.
function ReadGolomb(var M: TMsac): LongWord;
var len: Integer; val: LongWord;
begin
  len := 0; val := 1;
  while (MsacDecodeBoolEqui(M) = 0) and (len < 32) do Inc(len);
  while len > 0 do begin val := (val shl 1) + LongWord(MsacDecodeBoolEqui(M)); Dec(len); end;
  Result := val - 1;
end;

// get_skip_ctx (recon_tmpl.c) — the block-vs-transform context.
function GetSkipCtx(const TD: TTxfmInfo; ABw4, ABh4, AChroma, ASsHor, ASsVer: Integer;
  A, L: PByte): Integer;
var
  bd2, bd3: Integer;
  notOneBlk, ca, cl: Integer;
  la, ll: LongWord;

  function MergeBool(P: PByte; ByteLen: Integer; NoVal: UInt64): Integer;
  var v: UInt64; i: Integer;
  begin
    v := 0;
    for i := 0 to ByteLen - 1 do v := v or (UInt64(P[i]) shl (i * 8));
    if v <> NoVal then Result := 1 else Result := 0;
  end;

  function MergeLevels(P: PByte; TxLog: Integer): LongWord;
  var v: LongWord; tmp: UInt64; i: Integer;
  begin
    if TxLog = TX_64X64 then
    begin
      tmp := 0;
      for i := 0 to 7 do tmp := tmp or (UInt64(P[i]) shl (i*8));
      for i := 0 to 7 do tmp := tmp or (UInt64(P[8+i]) shl (i*8)); // OR the two halves
      // dav1d: tmp = a[0..7] ; tmp |= a[8..15]; l = (tmp>>32)|tmp
      v := LongWord(tmp shr 32) or LongWord(tmp);
    end
    else
    begin
      v := 0;
      case TxLog of
        TX_4X4: v := P[0];
        TX_8X8: v := P[0] or (LongWord(P[1]) shl 8);
        TX_16X16: for i := 0 to 3 do v := v or (LongWord(P[i]) shl (i*8));
        TX_32X32: for i := 0 to 3 do v := v or (LongWord(P[i]) shl (i*8));
      end;
      if TxLog = TX_32X32 then
        for i := 4 to 7 do v := v or (LongWord(P[i]) shl ((i-4)*8)); // |= next word (approx)
    end;
    if TxLog >= TX_16X16 then v := v or (v shr 16);
    if TxLog >= TX_8X8 then v := v or (v shr 8);
    Result := v;
  end;

begin
  bd2 := TD.lw; // recomputed below via block dims
  // block dims from bw4/bh4 log2:
  // b_dim[2]=log2(bw4), b_dim[3]=log2(bh4). Compute:
  bd2 := 0; while (1 shl bd2) < ABw4 do Inc(bd2);
  bd3 := 0; while (1 shl bd3) < ABh4 do Inc(bd3);

  if AChroma <> 0 then
  begin
    notOneBlk := 0;
    if (bd2 - (Ord(bd2 <> 0) and ASsHor)) > TD.lw then notOneBlk := 1;
    if (bd3 - (Ord(bd3 <> 0) and ASsVer)) > TD.lh then notOneBlk := 1;
    ca := 0; cl := 0;
    case TD.lw of
      TX_4X4:   ca := MergeBool(A, 1, $40);
      TX_8X8:   ca := MergeBool(A, 2, $4040);
      TX_16X16: ca := MergeBool(A, 4, $40404040);
      TX_32X32: ca := MergeBool(A, 8, $4040404040404040);
    end;
    case TD.lh of
      TX_4X4:   cl := MergeBool(L, 1, $40);
      TX_8X8:   cl := MergeBool(L, 2, $4040);
      TX_16X16: cl := MergeBool(L, 4, $40404040);
      TX_32X32: cl := MergeBool(L, 8, $4040404040404040);
    end;
    Result := 7 + notOneBlk * 3 + ca + cl;
  end
  else if (bd2 = TD.lw) and (bd3 = TD.lh) then
    Result := 0
  else
  begin
    la := MergeLevels(A, TD.lw);
    ll := MergeLevels(L, TD.lh);
    Result := SkipCtxTab[IMin(la and $3F, 4)][IMin(ll and $3F, 4)];
  end;
end;

// get_dc_sign_ctx — uniform over all sizes: s = Σ(a>>6) + Σ(l>>6) - w - h,
// where w/h are the tx dims in 4px units and the context bytes hold the DC
// sign level in bits 6-7. (Equivalent to dav1d's per-size SIMD variants.)
function GetDcSignCtx(ATx: Integer; A, L: PByte): Integer;
var TD: TTxfmInfo; s, i: Integer;
begin
  TD := TxfmDim[ATx];
  s := -(TD.w + TD.h);
  for i := 0 to TD.w - 1 do Inc(s, A[i] shr 6);
  for i := 0 to TD.h - 1 do Inc(s, L[i] shr 6);
  Result := Ord(s <> 0) + Ord(s > 0);
end;

const
{$I Av1.ScanData.inc}   // Scan_4x4 / Scan_8x8 / Scan_16x16 / Scan_32x32


  // dav1d_lo_ctx_offsets[w?h][y][x].
  LoCtxOffsets: array[0..2, 0..4, 0..4] of Byte = (
    ( (0,1,6,6,21),(1,6,6,21,21),(6,6,21,21,21),(6,21,21,21,21),(21,21,21,21,21) ),
    ( (0,16,6,6,21),(16,16,6,21,21),(16,16,21,21,21),(16,16,21,21,21),(16,16,21,21,21) ),
    ( (0,11,11,11,11),(11,11,11,11,11),(6,6,21,21,21),(6,21,21,21,21),(21,21,21,21,21) )
  );
  // dav1d_tx_type_class: 0=2D, 1=H, 2=V.
  TxTypeClass: array[0..16] of Byte =
    (0,0,0,0,0,0,0,0,0,0, 2,1,2,1,2,1, 0);
  // dav1d_txtp_from_uvmode (index 13 = CFL -> DCT_DCT via C zero-init).
  TxtpFromUvMode: array[0..13] of Byte = (0,1,2,0,3,1,2,2,1,3,1,2,3, 0);
  // dav1d_tx_types_per_set (Intra2|Intra1|Inter2|Inter1).
  TxTypesPerSet: array[0..39] of Byte = (
    9,0,3,1,2,
    9,0,10,11,3,1,2,
    9,10,11,0,1,2,4,5,3,6,7,8,
    9,10,11,12,13,14,15,0,1,2,4,5,3,6,7,8);
  FILTER_PRED = 13;

function ScanFor(ATx: Integer): PWord;
begin
  case ATx of
    0:  Result := @Scan_4x4[0];
    1:  Result := @Scan_8x8[0];
    2:  Result := @Scan_16x16[0];
    3, 4, 11, 12: Result := @Scan_32x32[0];   // 32X32, 64X64, 32X64, 64X32
    5:  Result := @Scan_4x8[0];
    6:  Result := @Scan_8x4[0];
    7:  Result := @Scan_8x16[0];
    8:  Result := @Scan_16x8[0];
    9, 17: Result := @Scan_16x32[0];           // 16X32, 16X64
    10, 18: Result := @Scan_32x16[0];          // 32X16, 64X16
    13: Result := @Scan_4x16[0];
    14: Result := @Scan_16x4[0];
    15: Result := @Scan_8x32[0];
  else  Result := @Scan_32x8[0];               // 16 RTX_32X8
  end;
end;

// get_lo_ctx (recon_tmpl.c). P = levels + x*stride + y.
function GetLoCtx(P: PByte; ATxClass, AOffIdx: Integer; out AHiMag: LongWord;
  X, Y: LongWord; AStride: Integer): Integer;
var mag: LongWord; offset: Integer;
begin
  mag := P[1] + P[AStride];
  if ATxClass = TX_CLASS_2D then
  begin
    Inc(mag, P[AStride + 1]);
    AHiMag := mag;
    Inc(mag, LongWord(P[2]) + P[2 * AStride]);
    offset := LoCtxOffsets[AOffIdx][IMin(Integer(Y), 4)][IMin(Integer(X), 4)];
  end
  else
  begin
    Inc(mag, P[2]);
    AHiMag := mag;
    Inc(mag, LongWord(P[3]) + P[4]);
    if Y > 1 then offset := 26 + 10 else offset := 26 + Integer(Y) * 5;
  end;
  if mag > 512 then Result := offset + 4
  else Result := offset + Integer((mag + 64) shr 7);
end;

// Decodes + dequantises one transform block. AYMode/AUvMode are the block's
// luma/chroma intra modes (for txtp derivation); AReducedTxtp/AQidxZero are
// frame flags. ATxtp receives the chosen transform type.
function DecodeCoefs(var M: TMsac; var Cdf: TCdfContext;
  ATx, ABsW4, ABsH4: Integer; AIntra, APlane, AChroma: Integer;
  ASsHor, ASsVer: Integer; A, L: PByte;
  ADqDc, ADqAc: Integer; ACf: PInteger;
  AYMode, AUvMode: Integer; AReducedTxtp, AQidxZero: Boolean;
  out ATxtp: Integer; out AResCtx: Integer): Integer;
var
  TD: TTxfmInfo;
  sctx, allSkip, txtp, txClass, is1d: Integer;
  ym, idx: Integer;
  tx2dszctx, eobBin, eob, eobHi: Integer;
  dcTok, dcSignCtx, dcSign, dqShift, cfMax: Integer;
  dcDq, acDq, rcTok: LongWord;
  culLevel, dcSignLevel, sign, tok: Integer;
  scan: PWord;
  levels: array[0..2047] of Byte;
  stride, shift, shift2, mask, swc, shc, offIdx: Integer;
  rc, i, ctx, eobTok, levelTok: Integer;
  x, y, rcI: LongWord;
  mag, hiMag: LongWord;
  lvl: PByte;
begin
  TD := TxfmDim[ATx];
  sctx := GetSkipCtx(TD, ABsW4, ABsH4, AChroma, ASsHor, ASsVer, A, L);
  allSkip := MsacDecodeBoolAdapt(M, @Cdf.coef.skip[TD.ctx][sctx][0]);
  if DebugCoefs then Writeln(ErrOutput, Format('Post-non-zero[%d][%d][%d]: r=%d', [TD.ctx, sctx, allSkip, M.Rng]));
  if allSkip <> 0 then
  begin
    ATxtp := DCT_DCT;
    AResCtx := $40;
    Exit(-1);
  end;

  // --- transform type (chroma derived, luma coded) ---
  if TD.max + AIntra >= TX_64X64 then
    txtp := DCT_DCT
  else if AChroma <> 0 then
    txtp := TxtpFromUvMode[AUvMode]
  else if AQidxZero then
    txtp := DCT_DCT
  else
  begin
    if AYMode = FILTER_PRED then ym := 0 else ym := AYMode;   // filter map TODO
    if AReducedTxtp or (TD.min = TX_16X16) then
    begin
      idx := MsacDecodeSymbolAdapt(M, @Cdf.m.txtp_intra2[TD.min][ym][0], 4);
      txtp := TxTypesPerSet[idx + 0];
    end
    else
    begin
      idx := MsacDecodeSymbolAdapt(M, @Cdf.m.txtp_intra1[TD.min][ym][0], 6);
      txtp := TxTypesPerSet[idx + 5];
    end;
    if DebugCoefs then Writeln(ErrOutput, Format('Post-txtp-intra[%d->%d][%d->%d]: r=%d', [ATx, TD.min, idx, txtp, M.Rng]));
  end;
  ATxtp := txtp;
  txClass := TxTypeClass[txtp];
  is1d := Ord(txClass <> TX_CLASS_2D);

  // --- end-of-block ---
  tx2dszctx := IMin(TD.lw, TX_32X32) + IMin(TD.lh, TX_32X32);
  case tx2dszctx of
    0: eobBin := MsacDecodeSymbolAdapt(M, @Cdf.coef.eob_bin_16[AChroma][is1d][0], 4);
    1: eobBin := MsacDecodeSymbolAdapt(M, @Cdf.coef.eob_bin_32[AChroma][is1d][0], 5);
    2: eobBin := MsacDecodeSymbolAdapt(M, @Cdf.coef.eob_bin_64[AChroma][is1d][0], 6);
    3: eobBin := MsacDecodeSymbolAdapt(M, @Cdf.coef.eob_bin_128[AChroma][is1d][0], 7);
    4: eobBin := MsacDecodeSymbolAdapt(M, @Cdf.coef.eob_bin_256[AChroma][is1d][0], 8);
    5: eobBin := MsacDecodeSymbolAdapt(M, @Cdf.coef.eob_bin_512[AChroma][0], 9);
  else eobBin := MsacDecodeSymbolAdapt(M, @Cdf.coef.eob_bin_1024[AChroma][0], 10);
  end;
  if DebugCoefs then Writeln(ErrOutput, Format('Post-eob_bin_%d[%d][%d][%d]: r=%d', [16 shl tx2dszctx, AChroma, is1d, eobBin, M.Rng]));
  if eobBin > 1 then
  begin
    eobHi := MsacDecodeBoolAdapt(M, @Cdf.coef.eob_hi_bit[TD.ctx][AChroma][eobBin][0]);
    if DebugCoefs then Writeln(ErrOutput, Format('Post-eob_hi_bit: r=%d', [M.Rng]));
    eob := ((eobHi or 2) shl (eobBin - 2)) or MsacDecodeBools(M, eobBin - 2);
    if DebugCoefs then Writeln(ErrOutput, Format('Post-eob[%d]: r=%d', [eob, M.Rng]));
  end
  else
    eob := eobBin;

  dqShift := IMax(0, TD.ctx - 2);
  cfMax := ReconCfMax;
  rc := 0; dcTok := 0;

  if eob <> 0 then
  begin
    // class-dependent scan geometry.
    swc := IMin(TD.w, 8); shc := IMin(TD.h, 8);
    case txClass of
      TX_CLASS_2D:
        begin
          scan := ScanFor(ATx);
          stride := 4 * shc;
          if TD.lh < 4 then shift := TD.lh + 2 else shift := 5;
          shift2 := 0; mask := 4 * shc - 1;
          offIdx := Ord(ATx >= 5);              // nonsquare_tx
          offIdx := offIdx + (ATx and offIdx);  // dav1d_lo_ctx_offsets index
        end;
      TX_CLASS_H:
        begin
          scan := nil; stride := 16; shift := TD.lh + 2; shift2 := 0;
          mask := 4 * shc - 1; offIdx := 0;
        end;
    else // TX_CLASS_V
      begin
        scan := nil; stride := 16; shift := TD.lw + 2; shift2 := TD.lh + 2;
        mask := 4 * swc - 1; offIdx := 0;
      end;
    end;
    FillChar(levels, SizeOf(levels), 0);

    // eob coefficient
    ctx := 1 + Ord(eob > swc * shc * 2) + Ord(eob > swc * shc * 4);
    eobTok := MsacDecodeSymbolAdapt(M, @Cdf.coef.eob_base_tok[TD.ctx][AChroma][ctx][0], 2);
    tok := eobTok + 1;
    levelTok := tok * $41;
    case txClass of
      TX_CLASS_2D: begin rc := scan[eob]; x := LongWord(rc) shr shift; y := LongWord(rc) and LongWord(mask); end;
      TX_CLASS_H:  begin x := LongWord(eob) and LongWord(mask); y := LongWord(eob) shr shift; rc := eob; end;
    else           begin x := LongWord(eob) and LongWord(mask); y := LongWord(eob) shr shift; rc := Integer((x shl shift2) or y); end;
    end;
    if DebugCoefs then Writeln(ErrOutput, Format('Post-lo_tok[%d][%d][%d][%d=%d=%d]: r=%d', [TD.ctx, AChroma, ctx, eob, rc, tok, M.Rng]));
    if eobTok = 2 then
    begin
      if txClass = TX_CLASS_2D then begin if (x or y) > 1 then ctx := 14 else ctx := 7; end
      else begin if y <> 0 then ctx := 14 else ctx := 7; end;
      tok := MsacDecodeHiTok(M, @Cdf.coef.br_tok[IMin(TD.ctx, 3)][AChroma][ctx][0]);
      levelTok := tok + (3 shl 6);
      if DebugCoefs then Writeln(ErrOutput, Format('Post-hi_tok[%d][%d][%d][%d=%d=%d]: r=%d', [IMin(TD.ctx,3), AChroma, ctx, eob, rc, tok, M.Rng]));
    end;
    ACf[rc] := tok shl 11;
    levels[Integer(x) * stride + Integer(y)] := Byte(levelTok);

    // ac coefficients (eob-1 .. 1)
    for i := eob - 1 downto 1 do
    begin
      case txClass of
        TX_CLASS_2D: begin rcI := scan[i]; x := rcI shr shift; y := rcI and LongWord(mask); end;
        TX_CLASS_H:  begin x := LongWord(i) and LongWord(mask); y := LongWord(i) shr shift; rcI := i; end;
      else           begin x := LongWord(i) and LongWord(mask); y := LongWord(i) shr shift; rcI := (x shl shift2) or y; end;
      end;
      lvl := @levels[Integer(x) * stride + Integer(y)];
      ctx := GetLoCtx(lvl, txClass, offIdx, mag, x, y, stride);
      if txClass = TX_CLASS_2D then y := y or x;
      tok := MsacDecodeSymbolAdapt(M, @Cdf.coef.base_tok[TD.ctx][AChroma][ctx][0], 3);
      if DebugCoefs then Writeln(ErrOutput, Format('Post-lo_tok[%d][%d][%d][%d=%d=%d]: r=%d', [TD.ctx, AChroma, ctx, i, rcI, tok, M.Rng]));
      if tok = 3 then
      begin
        mag := mag and 63;
        if txClass = TX_CLASS_2D then begin if y > 1 then ctx := 14 else ctx := 7; end
        else begin if y > 0 then ctx := 14 else ctx := 7; end;
        if mag > 12 then Inc(ctx, 6) else Inc(ctx, Integer((mag + 1) shr 1));
        tok := MsacDecodeHiTok(M, @Cdf.coef.br_tok[IMin(TD.ctx, 3)][AChroma][ctx][0]);
        if DebugCoefs then Writeln(ErrOutput, Format('Post-hi_tok[%d][%d][%d][%d=%d=%d]: r=%d', [IMin(TD.ctx,3), AChroma, ctx, i, rcI, tok, M.Rng]));
        lvl^ := Byte(tok + (3 shl 6));
        ACf[rcI] := Integer((LongWord(tok) shl 11) or LongWord(rc));
        rc := Integer(rcI);
      end
      else
      begin
        lvl^ := Byte(tok * $41);
        if tok <> 0 then
        begin
          ACf[rcI] := Integer((LongWord(tok) shl 11) or LongWord(rc));
          rc := Integer(rcI);
        end
        else
          ACf[rcI] := 0;
      end;
    end;

    // dc coefficient
    if txClass = TX_CLASS_2D then ctx := 0
    else ctx := GetLoCtx(@levels[0], txClass, offIdx, mag, 0, 0, stride);
    dcTok := MsacDecodeSymbolAdapt(M, @Cdf.coef.base_tok[TD.ctx][AChroma][ctx][0], 3);
    if DebugCoefs then Writeln(ErrOutput, Format('Post-dc_lo_tok[%d][%d][%d][%d]: r=%d', [TD.ctx, AChroma, ctx, dcTok, M.Rng]));
    if dcTok = 3 then
    begin
      if txClass = TX_CLASS_2D then
        mag := levels[0 * stride + 1] + levels[1 * stride + 0] + levels[1 * stride + 1];
      mag := mag and 63;
      if mag > 12 then ctx := 6 else ctx := Integer((mag + 1) shr 1);
      dcTok := MsacDecodeHiTok(M, @Cdf.coef.br_tok[IMin(TD.ctx, 3)][AChroma][ctx][0]);
      if DebugCoefs then Writeln(ErrOutput, Format('Post-dc_hi_tok[%d][%d][0][%d]: r=%d', [IMin(TD.ctx,3), AChroma, dcTok, M.Rng]));
    end;
  end
  else
  begin
    // dc-only
    eobTok := MsacDecodeSymbolAdapt(M, @Cdf.coef.eob_base_tok[TD.ctx][AChroma][0][0], 2);
    dcTok := 1 + eobTok;
    if DebugCoefs then Writeln(ErrOutput, Format('Post-dc_lo_tok[%d][%d][0][%d]: r=%d', [TD.ctx, AChroma, dcTok, M.Rng]));
    if eobTok = 2 then
    begin
      dcTok := MsacDecodeHiTok(M, @Cdf.coef.br_tok[IMin(TD.ctx, 3)][AChroma][0][0]);
      if DebugCoefs then Writeln(ErrOutput, Format('Post-dc_hi_tok[%d][%d][0][%d]: r=%d', [IMin(TD.ctx,3), AChroma, dcTok, M.Rng]));
    end;
    rc := 0;
  end;

  // --- residual, sign and dequant (non-qmatrix) ---
  if dcTok = 0 then
  begin
    culLevel := 0; dcSignLevel := 1 shl 6;
  end
  else
  begin
    dcSignCtx := GetDcSignCtx(ATx, A, L);
    dcSign := MsacDecodeBoolAdapt(M, @Cdf.coef.dc_sign[AChroma][dcSignCtx][0]);
    if DebugCoefs then Writeln(ErrOutput, Format('Post-dc_sign[%d][%d][%d]: r=%d', [AChroma, dcSignCtx, dcSign, M.Rng]));
    dcDq := LongWord(ADqDc);
    dcSignLevel := Integer((LongWord(dcSign) - 1) and (2 shl 6));
    if dcTok = 15 then
    begin
      dcTok := Integer(ReadGolomb(M) + 15);
      if DebugCoefs then Writeln(ErrOutput, Format('Post-dc_residual[%d->%d]: r=%d', [dcTok-15, dcTok, M.Rng]));
      dcTok := dcTok and $FFFFF;
      dcDq := ((dcDq * LongWord(dcTok)) and $FFFFFF) shr dqShift;
      dcDq := dcDq - LongWord(dcSign);
      if dcDq > LongWord(cfMax) then dcDq := LongWord(cfMax);
    end
    else
      dcDq := ((dcDq * LongWord(dcTok)) shr dqShift) - LongWord(dcSign);
    culLevel := dcTok;
    ACf[0] := Integer(dcDq xor LongWord(-dcSign));
  end;

  // ac dequant loop, walking the rc linked list built above.
  if rc <> 0 then
  begin
    acDq := LongWord(ADqAc);
    repeat
      sign := MsacDecodeBoolEqui(M);
      if DebugCoefs then Writeln(ErrOutput, Format('Post-sign[%d=%d]: r=%d', [rc, sign, M.Rng]));
      rcTok := LongWord(ACf[rc]);
      if rcTok >= (15 shl 11) then
      begin
        tok := Integer(ReadGolomb(M) + 15);
        if DebugCoefs then Writeln(ErrOutput, Format('Post-residual[%d=%d->%d]: r=%d', [rc, tok-15, tok, M.Rng]));
        tok := tok and $FFFFF;
        mag := ((acDq * LongWord(tok)) and $FFFFFF) shr dqShift;
        mag := mag - LongWord(sign);
        if mag > LongWord(cfMax) then mag := LongWord(cfMax);
        ACf[rc] := Integer(mag xor LongWord(-sign));
      end
      else
      begin
        tok := Integer(rcTok shr 11);
        ACf[rc] := Integer((((acDq * LongWord(tok)) shr dqShift) - LongWord(sign)) xor LongWord(-sign));
      end;
      Inc(culLevel, tok);
      rc := Integer(rcTok and $3FF);
    until rc = 0;
  end;

  if culLevel > 63 then culLevel := 63;
  AResCtx := culLevel or dcSignLevel;
  Result := eob;
end;

end.
