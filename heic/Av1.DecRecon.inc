// Av1.DecRecon.inc - block reconstruction: intra edge preparation and
// prediction, coefficient trees + inverse transforms, motion compensation
// (single / compound / OBMC / warp / inter-intra). Port of dav1d
// recon_tmpl.c, ipred_prepare_tmpl.c and the DC / CFL / filter kernels of
// ipred_tmpl.c. Included by Av1.Decoder.

const
  EDGE_CENTER = 260;

function TAv1Decoder.DqFor(Pl, Which: Integer): Integer;
begin
  Result := TS^.Dq[B.segId][Pl][Which];
end;

// ---------------------------------------------------------------- intra edges

const
  NeedsLeft  = 1; NeedsTop = 2; NeedsTopLeft = 4; NeedsTopRight = 8; NeedsBottomLeft = 16;
  IntraEdgeNeeds: array[0..13] of Byte = (
    NeedsTop or NeedsLeft,                          // DC
    NeedsTop,                                       // VERT
    NeedsLeft,                                      // HOR
    NeedsLeft,                                      // LEFT_DC
    NeedsTop,                                       // TOP_DC
    0,                                              // DC_128
    NeedsTop or NeedsTopRight or NeedsTopLeft,      // Z1
    NeedsLeft or NeedsTop or NeedsTopLeft,          // Z2
    NeedsLeft or NeedsBottomLeft or NeedsTopLeft,   // Z3
    NeedsLeft or NeedsTop,                          // SMOOTH
    NeedsLeft or NeedsTop,                          // SMOOTH_V
    NeedsLeft or NeedsTop,                          // SMOOTH_H
    NeedsLeft or NeedsTop or NeedsTopLeft,          // PAETH
    NeedsLeft or NeedsTop or NeedsTopLeft);         // FILTER
  ModeToAngleMap: array[0..7] of Integer = (90, 180, 45, 135, 113, 157, 203, 67);

function TAv1Decoder.PrepareIntraEdges(X: Integer; HaveLeft: Boolean; Y: Integer; HaveTop: Boolean;
  W, H, EdgeFlags: Integer; Dst: PWord; Stride, Mode: Integer; var Angle: Integer;
  Tw, Th: Integer; FilterEdge: Boolean): Integer;
var
  tl: PInteger;
  dstTop: PWord;
  sz, pxHave, i, v: Integer;
  needs: Integer;
  haveBL, haveTR: Boolean;
begin
  case Mode of
    VERT_PRED, HOR_PRED, DIAG_DOWN_LEFT_PRED, DIAG_DOWN_RIGHT_PRED, VERT_RIGHT_PRED,
    HOR_DOWN_PRED, HOR_UP_PRED, VERT_LEFT_PRED:
      begin
        Angle := ModeToAngleMap[Mode - VERT_PRED] + 3 * Angle;
        if Angle <= 90 then
        begin
          if (Angle < 90) and HaveTop then Mode := Z1_PRED else Mode := VERT_PRED;
        end
        else if Angle < 180 then Mode := Z2_PRED
        else
        begin
          if (Angle > 180) and HaveLeft then Mode := Z3_PRED else Mode := HOR_PRED;
        end;
      end;
    DC_PRED:
      if HaveLeft then
      begin
        if HaveTop then Mode := DC_PRED else Mode := LEFT_DC_PRED;
      end
      else if HaveTop then Mode := TOP_DC_PRED else Mode := DC_128_PRED;
    PAETH_PRED:
      if HaveLeft then
      begin
        if HaveTop then Mode := PAETH_PRED else Mode := HOR_PRED;
      end
      else if HaveTop then Mode := VERT_PRED else Mode := DC_128_PRED;
  end;
  Result := Mode;
  needs := IntraEdgeNeeds[Mode];
  tl := @EdgeBuf[EDGE_CENTER];
  dstTop := nil;
  if HaveTop and (((needs and (NeedsTop or NeedsTopLeft)) <> 0) or
                  (((needs and NeedsLeft) <> 0) and not HaveLeft)) then
    dstTop := Dst - Stride;

  if (needs and NeedsLeft) <> 0 then
  begin
    sz := Th shl 2;
    if HaveLeft then
    begin
      pxHave := IMin(sz, (H - Y) shl 2);
      for i := 0 to pxHave - 1 do tl[-(1 + i)] := Dst[Stride * i - 1];
      for i := pxHave to sz - 1 do tl[-(1 + i)] := tl[-pxHave];
    end
    else
    begin
      if HaveTop then v := dstTop^ else v := ((1 shl Bd) shr 1) + 1;
      for i := 0 to sz - 1 do tl[-(1 + i)] := v;
    end;
    if (needs and NeedsBottomLeft) <> 0 then
    begin
      haveBL := HaveLeft and (Y + Th < H) and ((EdgeFlags and EDGE_I444_LEFT_HAS_BOTTOM) <> 0);
      if haveBL then
      begin
        pxHave := IMin(sz, (H - Y - Th) shl 2);
        for i := 0 to pxHave - 1 do tl[-(sz + 1 + i)] := Dst[(sz + i) * Stride - 1];
        for i := pxHave to sz - 1 do tl[-(sz + 1 + i)] := tl[-(sz + pxHave)];
      end
      else
        for i := 0 to sz - 1 do tl[-(sz + 1 + i)] := tl[-sz];
    end;
  end;

  if (needs and NeedsTop) <> 0 then
  begin
    sz := Tw shl 2;
    if HaveTop then
    begin
      pxHave := IMin(sz, (W - X) shl 2);
      for i := 0 to pxHave - 1 do tl[1 + i] := dstTop[i];
      for i := pxHave to sz - 1 do tl[1 + i] := tl[pxHave];
    end
    else
    begin
      if HaveLeft then v := Dst[-1] else v := ((1 shl Bd) shr 1) - 1;
      for i := 0 to sz - 1 do tl[1 + i] := v;
    end;
    if (needs and NeedsTopRight) <> 0 then
    begin
      haveTR := HaveTop and (X + Tw < W) and ((EdgeFlags and EDGE_I444_TOP_HAS_RIGHT) <> 0);
      if haveTR then
      begin
        pxHave := IMin(sz, (W - X - Tw) shl 2);
        for i := 0 to pxHave - 1 do tl[1 + sz + i] := dstTop[sz + i];
        for i := pxHave to sz - 1 do tl[1 + sz + i] := tl[sz + pxHave];
      end
      else
        for i := 0 to sz - 1 do tl[1 + sz + i] := tl[sz];
    end;
  end;

  if (needs and NeedsTopLeft) <> 0 then
  begin
    if HaveLeft then
    begin
      if HaveTop then tl[0] := dstTop[-1] else tl[0] := Dst[-1];
    end
    else
    begin
      if HaveTop then tl[0] := dstTop^ else tl[0] := (1 shl Bd) shr 1;
    end;
    if (Mode = Z2_PRED) and (Tw + Th >= 6) and FilterEdge then
      tl[0] := ((tl[-1] + tl[1]) * 5 + tl[0] * 6 + 8) shr 4;
  end;
end;

function DcGen(tl: PInteger; W, H, Bd: Integer): Integer;
var i: Integer; dc: LongWord;
begin
  dc := (W + H) shr 1;
  for i := 0 to W - 1 do Inc(dc, tl[i + 1]);
  for i := 0 to H - 1 do Inc(dc, tl[-(i + 1)]);
  dc := dc shr CtzI(W + H);
  if W <> H then
  begin
    if Bd = 8 then
    begin
      if (W > H * 2) or (H > W * 2) then dc := (dc * $3334) shr 16 else dc := (dc * $5556) shr 16;
    end
    else
    begin
      if (W > H * 2) or (H > W * 2) then dc := (dc * $6667) shr 17 else dc := (dc * $AAAB) shr 17;
    end;
  end;
  Result := dc;
end;

function DcGenTop(tl: PInteger; W: Integer): Integer;
var i: Integer; dc: Integer;
begin
  dc := W shr 1;
  for i := 0 to W - 1 do Inc(dc, tl[1 + i]);
  Result := dc shr CtzI(W);
end;

function DcGenLeft(tl: PInteger; H: Integer): Integer;
var i: Integer; dc: Integer;
begin
  dc := H shr 1;
  for i := 0 to H - 1 do Inc(dc, tl[-(1 + i)]);
  Result := dc shr CtzI(H);
end;

procedure SplatDc(Dst: PWord; Stride, W, H, Dc: Integer);
var x, y: Integer;
begin
  for y := 0 to H - 1 do
  begin
    for x := 0 to W - 1 do Dst[x] := Dc;
    Inc(Dst, Stride);
  end;
end;

procedure IPredFilterK(Dst: PWord; Stride: Integer; TopLeftIn: PInteger; W, H, FiltIdx, PixMax: Integer);
var
  x, y, xx, yy, k, acc, leftStride: Integer;
  p: array[0..6] of Integer;
  topI: PInteger; topW: PWord; useTopW: Boolean;
  tlI: PInteger; tlW: PWord; useTlW: Boolean;
  leftI: PInteger; leftW: PWord; useLeftW: Boolean;
  rowPtr: PWord;
begin
  FiltIdx := FiltIdx and 511;
  topI := TopLeftIn + 1; topW := nil; useTopW := False;
  y := 0;
  while y < H do
  begin
    tlI := TopLeftIn - y; useTlW := False; tlW := nil;
    leftI := tlI - 1; useLeftW := False; leftW := nil;
    leftStride := -1;
    x := 0;
    while x < W do
    begin
      if useTlW then p[0] := tlW^ else p[0] := tlI^;
      if useTopW then
      begin p[1] := topW[0]; p[2] := topW[1]; p[3] := topW[2]; p[4] := topW[3]; end
      else
      begin p[1] := topI[0]; p[2] := topI[1]; p[3] := topI[2]; p[4] := topI[3]; end;
      if useLeftW then
      begin p[5] := leftW[0]; p[6] := leftW[leftStride]; end
      else
      begin p[5] := leftI[0]; p[6] := leftI[leftStride]; end;
      rowPtr := Dst + x;
      for yy := 0 to 1 do
      begin
        for xx := 0 to 3 do
        begin
          acc := 0;
          for k := 0 to 6 do Inc(acc, FilterIntraTaps[FiltIdx][yy * 4 + xx][k] * p[k]);
          rowPtr[xx] := IClip(SarLongint(acc + 8, 4), 0, PixMax);
        end;
        Inc(rowPtr, Stride);
      end;
      // next 4x2: left = dst column x+3, top-left = top[3]
      leftW := Dst + x + 4 - 1; useLeftW := True; leftStride := Stride;
      if useTopW then begin tlW := topW + 3; useTlW := True; Inc(topW, 4); end
      else begin tlI := topI + 3; useTlW := False; Inc(topI, 4); end;
      Inc(x, 4);
    end;
    topW := Dst + Stride; useTopW := True;
    Dst := Dst + Stride * 2;
    Inc(y, 2);
  end;
end;

procedure TAv1Decoder.IntraPred(Mode: Integer; Dst: PWord; Stride, Tw, Th, Angle, MaxW, MaxH: Integer);
var tl: PInteger;
begin
  tl := @EdgeBuf[EDGE_CENTER];
  case Mode of
    DC_PRED: SplatDc(Dst, Stride, Tw, Th, DcGen(tl, Tw, Th, Bd));
    LEFT_DC_PRED: SplatDc(Dst, Stride, Tw, Th, DcGenLeft(tl, Th));
    TOP_DC_PRED: SplatDc(Dst, Stride, Tw, Th, DcGenTop(tl, Tw));
    DC_128_PRED: SplatDc(Dst, Stride, Tw, Th, (PixMax + 1) shr 1);
    VERT_PRED: IPredV(Dst, Stride, tl, Tw, Th);
    HOR_PRED: IPredH(Dst, Stride, tl, Tw, Th);
    Z1_PRED: IPredZ1(Dst, Stride, tl, Tw, Th, Angle, MaxW, MaxH);
    Z2_PRED: IPredZ2(Dst, Stride, tl, Tw, Th, Angle, MaxW, MaxH);
    Z3_PRED: IPredZ3(Dst, Stride, tl, Tw, Th, Angle, MaxW, MaxH);
    SMOOTH_PRED: IPredSmooth(Dst, Stride, tl, Tw, Th);
    SMOOTH_V_PRED: IPredSmoothV(Dst, Stride, tl, Tw, Th);
    SMOOTH_H_PRED: IPredSmoothH(Dst, Stride, tl, Tw, Th);
    PAETH_PRED: IPredPaeth(Dst, Stride, tl, Tw, Th);
    FILTER_PRED: IPredFilterK(Dst, Stride, tl, Tw, Th, Angle, PixMax);
  end;
end;

procedure CflAc(Ac: PInteger; Ypx: PWord; Stride, WPad, HPad, Width, Height, SsHor, SsVer: Integer);
var y, x, sum, log2sz, s: Integer; acOrig, p: PInteger;
begin
  acOrig := Ac;
  y := 0;
  while y < Height - 4 * HPad do
  begin
    x := 0;
    while x < Width - 4 * WPad do
    begin
      s := Ypx[x shl SsHor];
      if SsHor <> 0 then Inc(s, Ypx[x * 2 + 1]);
      if SsVer <> 0 then
      begin
        Inc(s, Ypx[(x shl SsHor) + Stride]);
        if SsHor <> 0 then Inc(s, Ypx[x * 2 + 1 + Stride]);
      end;
      Ac[x] := s shl (1 + Ord(SsVer = 0) + Ord(SsHor = 0));
      Inc(x);
    end;
    while x < Width do begin Ac[x] := Ac[x - 1]; Inc(x); end;
    Inc(Ac, Width);
    Inc(Ypx, Stride shl SsVer);
    Inc(y);
  end;
  while y < Height do
  begin
    Move((Ac - Width)^, Ac^, Width * SizeOf(Integer));
    Inc(Ac, Width);
    Inc(y);
  end;
  log2sz := CtzI(Width) + CtzI(Height);
  sum := (1 shl log2sz) shr 1;
  p := acOrig;
  for x := 0 to Width * Height - 1 do Inc(sum, p[x]);
  sum := SarLongint(sum, log2sz);
  for x := 0 to Width * Height - 1 do Dec(p[x], sum);
end;

procedure CflPred(Dst: PWord; Stride, W, H, Dc: Integer; Ac: PInteger; Alpha, PixMax: Integer);
var x, y, diff: Integer;
begin
  for y := 0 to H - 1 do
  begin
    for x := 0 to W - 1 do
    begin
      diff := Alpha * Ac[x];
      Dst[x] := IClip(Dc + ApplySign((Abs(diff) + 32) shr 6, diff), 0, PixMax);
    end;
    Inc(Ac, W);
    Inc(Dst, Stride);
  end;
end;

// ---------------------------------------------------------------- coefficients

function PlanePtr(D: TAv1Decoder; Pl: Integer): PWord; inline;
begin
  case Pl of
    0: Result := @D.Yp[0];
    1: Result := @D.Up[0];
  else Result := @D.Vp[0];
  end;
end;

function IfPl(Pl: Integer; P0, P1: Pointer): Pointer; inline;
begin if Pl = 0 then Result := P0 else Result := P1; end;

procedure DoItx(Dst: PWord; Stride: Integer; Cf: PInteger; Eob, Tx, Txtp, Bd: Integer);
var w, h: Integer;
begin
  if Txtp = WHT_WHT then
    InvWhtAdd4x4(Dst, Stride, Cf, (1 shl Bd) - 1)
  else
  begin
    w := ItxWpx[Tx]; h := ItxHpx[Tx];
    InvTxfmAdd(Dst, Stride, Cf, Eob, w, h, ItxShiftT[Tx],
      ItxFn(TxtpRowKind[Txtp], w), ItxFn(TxtpColKind[Txtp], h), Ord(Txtp = DCT_DCT), Bd);
  end;
end;

procedure TAv1Decoder.ReadCoefTree(Bs, Ytx, Depth: Integer; const TxSplit: array of Integer;
  XOff, YOff: Integer; Dst: PWord);
var
  td, sub: PTxDim;
  txw, txh, txsw, txsh, txtp, cfCtx, eob, y, ymode: Integer;
  subTx: Integer;
begin
  td := @TxDims[Ytx];
  txw := td^.w; txh := td^.h;
  if (Depth < 2) and (TxSplit[Depth] <> 0) and
     ((TxSplit[Depth] and (1 shl (YOff * 4 + XOff))) <> 0) then
  begin
    subTx := td^.sub;
    sub := @TxDims[subTx];
    txsw := sub^.w; txsh := sub^.h;
    ReadCoefTree(Bs, subTx, Depth + 1, TxSplit, XOff * 2 + 0, YOff * 2 + 0, Dst);
    Inc(bx, txsw);
    if (txw >= txh) and (bx < Self.bw) then
      ReadCoefTree(Bs, subTx, Depth + 1, TxSplit, XOff * 2 + 1, YOff * 2 + 0, Dst + 4 * txsw);
    Dec(bx, txsw);
    Inc(by, txsh);
    if (txh >= txw) and (by < Self.bh) then
    begin
      Dst := Dst + 4 * txsh * StrideY;
      ReadCoefTree(Bs, subTx, Depth + 1, TxSplit, XOff * 2 + 0, YOff * 2 + 1, Dst);
      Inc(bx, txsw);
      if (txw >= txh) and (bx < Self.bw) then
        ReadCoefTree(Bs, subTx, Depth + 1, TxSplit, XOff * 2 + 1, YOff * 2 + 1, Dst + 4 * txsw);
      Dec(bx, txsw);
    end;
    Dec(by, txsh);
  end
  else
  begin
    ymode := 0;
    eob := DecodeCoefs(TS^.Msac, TS^.Cdf, Ytx, BlockDim[Bs][0], BlockDim[Bs][1], 0, 0, 0, ssH, ssV,
      @A.lcoef[bx], @L.lcoef[by], DqFor(0, 0), DqFor(0, 1), @Cf[0], ymode, 0,
      Fh.ReducedTxtpSet, Fh.Segmentation.QIdx[B.segId] = 0, Fh.Segmentation.Lossless[B.segId],
      txtp, cfCtx);
    SetBytes(A.lcoef, bx, IMin(txw, Self.bw - bx), cfCtx);
    SetBytes(L.lcoef, by, IMin(txh, Self.bh - by), cfCtx);
    for y := 0 to txh - 1 do
      FillChar(TxtpMap[((by and 31) + y) * 32 + (bx and 31)], txw, txtp);
    if eob >= 0 then DoItx(Dst, StrideY, @Cf[0], eob, Ytx, txtp, Bd);
  end;
end;

// ---------------------------------------------------------------- intra recon

procedure TAv1Decoder.ReconIntra(Bs, EdgeFlags: Integer);
var
  bw4, bh4, w4, h4, cw4, ch4, cbw4, cbh4, cbx4, cby4: Integer;
  hasChroma: Boolean;
  td, uvtd: PTxDim;
  intraEdgeFlag, initY, initX, subH4, subCh4, subW4, subCw4, x, y, pl, angle, m, ef: Integer;
  sbHasTr, sbHasBl, uvSbHasTr, uvSbHasBl, intraFlags, smUvFl, eob, txtp, cfCtx, ymodeNoFilt: Integer;
  dst, ySrc: PWord;
  stride, xpos, ypos, xstart, ystart, uvMode, furthestR, furthestB: Integer;
  ac: array[0..32*32-1] of Integer;

  function SmFlag(var C: TCtxArrays; Idx: Integer): Integer;
  var mm: Integer;
  begin
    if C.intra[Idx] = 0 then Exit(0);
    mm := C.mode[Idx];
    if (mm = SMOOTH_PRED) or (mm = SMOOTH_H_PRED) or (mm = SMOOTH_V_PRED) then Result := 512 else Result := 0;
  end;
  function SmUvFlag(var C: TCtxArrays; Idx: Integer): Integer;
  var mm: Integer;
  begin
    mm := C.uvmode[Idx];
    if (mm = SMOOTH_PRED) or (mm = SMOOTH_H_PRED) or (mm = SMOOTH_V_PRED) then Result := 512 else Result := 0;
  end;

  procedure PalPred(D: PWord; DStride: Integer; P: PWord; Idx: PByte; W, H: Integer);
  var xx, yy: Integer;
  begin
    for yy := 0 to H - 1 do
      for xx := 0 to W - 1 do
        D[yy * DStride + xx] := P[Idx[yy * W + xx]];
  end;

begin
  bw4 := BlockDim[Bs][0]; bh4 := BlockDim[Bs][1];
  w4 := IMin(bw4, Self.bw - bx); h4 := IMin(bh4, Self.bh - by);
  cw4 := (w4 + ssH) shr ssH; ch4 := (h4 + ssV) shr ssV;
  cbw4 := (bw4 + ssH) shr ssH; cbh4 := (bh4 + ssV) shr ssV;
  cbx4 := bx shr ssH; cby4 := by shr ssV;
  hasChroma := (Layout <> LAYOUT_I400) and ((bw4 > ssH) or ((bx and 1) <> 0)) and
               ((bh4 > ssV) or ((by and 1) <> 0));
  td := @TxDims[B.tx];
  uvtd := @TxDims[B.uvtx];
  intraEdgeFlag := Ord(Seq.IntraEdgeFilter) shl 10;
  if B.ymode = FILTER_PRED then ymodeNoFilt := FilterModeToYMode[B.yAngle] else ymodeNoFilt := B.ymode;

  initY := 0;
  while initY < h4 do
  begin
    subH4 := IMin(h4, 16 + initY);
    subCh4 := IMin(ch4, (initY + 16) shr ssV);
    initX := 0;
    while initX < w4 do
    begin
      if B.palSz[0] <> 0 then
        PalPred(@Yp[4 * (by * StrideY + bx)], StrideY, @Pal[0][0], @PalIdxY[0], bw4 * 4, bh4 * 4);

      intraFlags := SmFlag(A, bx) or SmFlag(L, by) or intraEdgeFlag;
      if initX + 16 < w4 then sbHasTr := 1
      else if initY <> 0 then sbHasTr := 0
      else sbHasTr := EdgeFlags and EDGE_I444_TOP_HAS_RIGHT;
      if initX <> 0 then sbHasBl := 0
      else if initY + 16 < h4 then sbHasBl := 1
      else sbHasBl := EdgeFlags and EDGE_I444_LEFT_HAS_BOTTOM;
      subW4 := IMin(w4, initX + 16);

      y := initY;
      Inc(by, initY);
      while y < subH4 do
      begin
        dst := @Yp[4 * (by * StrideY + bx + initX)];
        x := initX;
        Inc(bx, initX);
        while x < subW4 do
        begin
          if B.palSz[0] = 0 then
          begin
            angle := B.yAngle;
            ef := 0;
            if not (((y > initY) or (sbHasTr = 0)) and (x + td^.w >= subW4)) then ef := ef or EDGE_I444_TOP_HAS_RIGHT;
            if not ((x > initX) or ((sbHasBl = 0) and (y + td^.h >= subH4))) then ef := ef or EDGE_I444_LEFT_HAS_BOTTOM;
            m := PrepareIntraEdges(bx, bx > TS^.ColStart, by, by > TS^.RowStart, TS^.ColEnd, TS^.RowEnd,
              ef, dst, StrideY, B.ymode, angle, td^.w, td^.h, Seq.IntraEdgeFilter);
            IntraPred(m, dst, StrideY, td^.w * 4, td^.h * 4, angle or intraFlags,
              4 * Self.bw - 4 * bx, 4 * Self.bh - 4 * by);
          end;
          if B.skip = 0 then
          begin
            eob := DecodeCoefs(TS^.Msac, TS^.Cdf, B.tx, bw4, bh4, 1, 0, 0, ssH, ssV,
              @A.lcoef[bx], @L.lcoef[by], DqFor(0, 0), DqFor(0, 1), @Cf[0], ymodeNoFilt, B.uvmode,
              Fh.ReducedTxtpSet, Fh.Segmentation.QIdx[B.segId] = 0, Fh.Segmentation.Lossless[B.segId],
              txtp, cfCtx);
            SetBytes(A.lcoef, bx, IMin(td^.w, Self.bw - bx), cfCtx);
            SetBytes(L.lcoef, by, IMin(td^.h, Self.bh - by), cfCtx);
            if eob >= 0 then DoItx(dst, StrideY, @Cf[0], eob, B.tx, txtp, Bd);
          end
          else
          begin
            SetBytes(A.lcoef, bx, td^.w, $40);
            SetBytes(L.lcoef, by, td^.h, $40);
          end;
          Inc(dst, 4 * td^.w);
          Inc(x, td^.w); Inc(bx, td^.w);
        end;
        Dec(bx, x);
        Inc(y, td^.h); Inc(by, td^.h);
      end;
      Dec(by, y);

      if hasChroma then
      begin
        stride := StrideC;
        if B.uvmode = CFL_PRED then
        begin
          ySrc := @Yp[4 * (bx and not ssH) + 4 * (by and not ssV) * StrideY];
          furthestR := ((cw4 shl ssH) + td^.w - 1) and not (td^.w - 1);
          furthestB := ((ch4 shl ssV) + td^.h - 1) and not (td^.h - 1);
          CflAc(@ac[0], ySrc, StrideY, cbw4 - (furthestR shr ssH), cbh4 - (furthestB shr ssV),
            cbw4 * 4, cbh4 * 4, ssH, ssV);
          for pl := 0 to 1 do
          begin
            if B.cflAlpha[pl] = 0 then Continue;
            angle := 0;
            xpos := bx shr ssH; ypos := by shr ssV;
            xstart := TS^.ColStart shr ssH; ystart := TS^.RowStart shr ssV;
            dst := PlanePtr(Self, 1 + pl) + 4 * ((bx shr ssH) + (by shr ssV) * stride);
            m := PrepareIntraEdges(xpos, xpos > xstart, ypos, ypos > ystart,
              TS^.ColEnd shr ssH, TS^.RowEnd shr ssV, 0, dst, stride, DC_PRED, angle,
              uvtd^.w, uvtd^.h, False);
            case m of
              DC_PRED: CflPred(dst, stride, uvtd^.w * 4, uvtd^.h * 4,
                DcGen(@EdgeBuf[EDGE_CENTER], uvtd^.w * 4, uvtd^.h * 4, Bd), @ac[0], B.cflAlpha[pl], PixMax);
              LEFT_DC_PRED: CflPred(dst, stride, uvtd^.w * 4, uvtd^.h * 4,
                DcGenLeft(@EdgeBuf[EDGE_CENTER], uvtd^.h * 4), @ac[0], B.cflAlpha[pl], PixMax);
              TOP_DC_PRED: CflPred(dst, stride, uvtd^.w * 4, uvtd^.h * 4,
                DcGenTop(@EdgeBuf[EDGE_CENTER], uvtd^.w * 4), @ac[0], B.cflAlpha[pl], PixMax);
            else CflPred(dst, stride, uvtd^.w * 4, uvtd^.h * 4, (PixMax + 1) shr 1, @ac[0], B.cflAlpha[pl], PixMax);
            end;
          end;
        end
        else if B.palSz[1] <> 0 then
        begin
          PalPred(@Up[4 * ((bx shr ssH) + (by shr ssV) * StrideC)], StrideC, @Pal[1][0], @PalIdxC[0], cbw4 * 4, cbh4 * 4);
          PalPred(@Vp[4 * ((bx shr ssH) + (by shr ssV) * StrideC)], StrideC, @Pal[2][0], @PalIdxC[0], cbw4 * 4, cbh4 * 4);
        end;

        smUvFl := SmUvFlag(A, cbx4) or SmUvFlag(L, cby4);
        if ((initX + 16) shr ssH) < cw4 then uvSbHasTr := 1
        else if initY <> 0 then uvSbHasTr := 0
        else uvSbHasTr := EdgeFlags and (EDGE_I420_TOP_HAS_RIGHT shr (Layout - 1));
        if initX <> 0 then uvSbHasBl := 0
        else if ((initY + 16) shr ssV) < ch4 then uvSbHasBl := 1
        else uvSbHasBl := EdgeFlags and (EDGE_I420_LEFT_HAS_BOTTOM shr (Layout - 1));
        subCw4 := IMin(cw4, (initX + 16) shr ssH);
        for pl := 0 to 1 do
        begin
          y := initY shr ssV;
          Inc(by, initY);
          while y < subCh4 do
          begin
            dst := PlanePtr(Self, 1 + pl) + 4 * ((by shr ssV) * stride + ((bx + initX) shr ssH));
            x := initX shr ssH;
            Inc(bx, initX);
            while x < subCw4 do
            begin
              if not (((B.uvmode = CFL_PRED) and (B.cflAlpha[pl] <> 0)) or (B.palSz[1] <> 0)) then
              begin
                angle := B.uvAngle;
                ef := 0;
                if not (((y > (initY shr ssV)) or (uvSbHasTr = 0)) and (x + uvtd^.w >= subCw4)) then
                  ef := ef or EDGE_I444_TOP_HAS_RIGHT;
                if not ((x > (initX shr ssH)) or ((uvSbHasBl = 0) and (y + uvtd^.h >= subCh4))) then
                  ef := ef or EDGE_I444_LEFT_HAS_BOTTOM;
                if B.uvmode = CFL_PRED then uvMode := DC_PRED else uvMode := B.uvmode;
                xpos := bx shr ssH; ypos := by shr ssV;
                xstart := TS^.ColStart shr ssH; ystart := TS^.RowStart shr ssV;
                m := PrepareIntraEdges(xpos, xpos > xstart, ypos, ypos > ystart,
                  TS^.ColEnd shr ssH, TS^.RowEnd shr ssV, ef, dst, stride, uvMode, angle,
                  uvtd^.w, uvtd^.h, Seq.IntraEdgeFilter);
                angle := angle or intraEdgeFlag;
                IntraPred(m, dst, stride, uvtd^.w * 4, uvtd^.h * 4, angle or smUvFl,
                  (4 * Self.bw + ssH - 4 * (bx and not ssH)) shr ssH,
                  (4 * Self.bh + ssV - 4 * (by and not ssV)) shr ssV);
              end;
              if B.skip = 0 then
              begin
                eob := DecodeCoefs(TS^.Msac, TS^.Cdf, B.uvtx, bw4, bh4, 1, 1 + pl, 1, ssH, ssV,
                  @PByte(IfPl(pl, @A.ccoef0[0], @A.ccoef1[0]))[cbx4 + x],
                  @PByte(IfPl(pl, @L.ccoef0[0], @L.ccoef1[0]))[cby4 + y],
                  DqFor(1 + pl, 0), DqFor(1 + pl, 1), @Cf[0], ymodeNoFilt, B.uvmode,
                  Fh.ReducedTxtpSet, Fh.Segmentation.QIdx[B.segId] = 0, Fh.Segmentation.Lossless[B.segId],
                  txtp, cfCtx);
                if pl = 0 then
                begin
                  SetBytes(A.ccoef0, cbx4 + x, IMin(uvtd^.w, (Self.bw - bx + ssH) shr ssH), cfCtx);
                  SetBytes(L.ccoef0, cby4 + y, IMin(uvtd^.h, (Self.bh - by + ssV) shr ssV), cfCtx);
                end
                else
                begin
                  SetBytes(A.ccoef1, cbx4 + x, IMin(uvtd^.w, (Self.bw - bx + ssH) shr ssH), cfCtx);
                  SetBytes(L.ccoef1, cby4 + y, IMin(uvtd^.h, (Self.bh - by + ssV) shr ssV), cfCtx);
                end;
                if eob >= 0 then DoItx(dst, stride, @Cf[0], eob, B.uvtx, txtp, Bd);
              end
              else
              begin
                if pl = 0 then
                begin
                  SetBytes(A.ccoef0, cbx4 + x, uvtd^.w, $40);
                  SetBytes(L.ccoef0, cby4 + y, uvtd^.h, $40);
                end
                else
                begin
                  SetBytes(A.ccoef1, cbx4 + x, uvtd^.w, $40);
                  SetBytes(L.ccoef1, cby4 + y, uvtd^.h, $40);
                end;
              end;
              Inc(dst, uvtd^.w * 4);
              Inc(x, uvtd^.w);
              Inc(bx, uvtd^.w shl ssH);
            end;
            Dec(bx, x shl ssH);
            Inc(y, uvtd^.h);
            Inc(by, uvtd^.h shl ssV);
          end;
          Dec(by, y shl ssV);
        end;
      end;
      Inc(initX, 16);
    end;
    Inc(initY, 16);
  end;
end;

// ---------------------------------------------------------------- motion compensation

function TAv1Decoder.RefPlane(RefIdx, Pl: Integer; Intrabc: Boolean; out Stride, W, H: Integer): PWord;
var S: ^TRefSlot; lsh, lsv: Integer;
begin
  if Pl <> 0 then begin lsh := ssH; lsv := ssV; end else begin lsh := 0; lsv := 0; end;
  if Intrabc then
  begin
    if Pl = 0 then begin Result := @Yp[0]; Stride := StrideY; end
    else if Pl = 1 then begin Result := @Up[0]; Stride := StrideC; end
    else begin Result := @Vp[0]; Stride := StrideC; end;
    W := (Self.bw * 4) shr lsh; H := (Self.bh * 4) shr lsv;
  end
  else
  begin
    S := @Slots[Refp[RefIdx]];
    if Pl = 0 then begin Result := @S^.Pic.Y[0]; Stride := S^.Pic.StrideY; end
    else if Pl = 1 then begin Result := @S^.Pic.U[0]; Stride := S^.Pic.StrideC; end
    else begin Result := @S^.Pic.V[0]; Stride := S^.Pic.StrideC; end;
    W := (S^.Pic.W + lsh) shr lsh; H := (S^.Pic.H + lsv) shr lsv;
  end;
end;

// emu_edge: copy a bw x bh window at (x,y) of ref with edge replication.
procedure EmuEdge(Bw, Bh, Iw, Ih, X, Y: Integer; Dst: PWord; DstStride: Integer; Ref: PWord; RefStride: Integer);
var yy, xx, sy, sx: Integer; row: PWord;
begin
  for yy := 0 to Bh - 1 do
  begin
    sy := IClip(Y + yy, 0, Ih - 1);
    row := Ref + sy * RefStride;
    for xx := 0 to Bw - 1 do
    begin
      sx := IClip(X + xx, 0, Iw - 1);
      Dst[yy * DstStride + xx] := row[sx];
    end;
  end;
end;

procedure TAv1Decoder.Mc(Dst: PWord; Dst16: PSmallInt; DstStride, Bw4, Bh4, Bxx, Byy, Pl: Integer;
  const Mv: TMv; RefIdx, Filter2d: Integer; Intrabc: Boolean);
var
  lsh, lsv, hMul, vMul, mvx, mvy, mx, my, dx, dy, w, h, refStride: Integer;
  ref: PWord;
begin
  if Pl <> 0 then begin lsh := ssH; lsv := ssV; end else begin lsh := 0; lsv := 0; end;
  hMul := 4 shr lsh; vMul := 4 shr lsv;
  mvx := Mv.x; mvy := Mv.y;
  mx := mvx and (15 shr Ord(lsh = 0));
  my := mvy and (15 shr Ord(lsv = 0));
  ref := RefPlane(RefIdx, Pl, Intrabc, refStride, w, h);
  dx := Bxx * hMul + SarLongint(mvx, 3 + lsh);
  dy := Byy * vMul + SarLongint(mvy, 3 + lsv);
  if (dx < Ord(mx <> 0) * 3) or (dy < Ord(my <> 0) * 3) or
     (dx + Bw4 * hMul + Ord(mx <> 0) * 4 > w) or
     (dy + Bh4 * vMul + Ord(my <> 0) * 4 > h) then
  begin
    EmuEdge(Bw4 * hMul + Ord(mx <> 0) * 7, Bh4 * vMul + Ord(my <> 0) * 7, w, h,
      dx - Ord(mx <> 0) * 3, dy - Ord(my <> 0) * 3, @EmuBuf[0], 192, ref, refStride);
    ref := @EmuBuf[192 * Ord(my <> 0) * 3 + Ord(mx <> 0) * 3];
    refStride := 192;
  end
  else
    ref := ref + refStride * dy + dx;
  if Dst <> nil then
    McPut(Dst, DstStride, ref, refStride, Bw4 * hMul, Bh4 * vMul, mx shl Ord(lsh = 0), my shl Ord(lsv = 0), Filter2d, Bd)
  else
    McPrep(Dst16, ref, refStride, Bw4 * hMul, Bh4 * vMul, mx shl Ord(lsh = 0), my shl Ord(lsv = 0), Filter2d, Bd);
end;

procedure TAv1Decoder.Obmc(Dst: PWord; DstStride, Pl, W4, H4: Integer);
var
  lsh, lsv, hMul, vMul, i, x, y, step4, ow4, oh4: Integer;
  ar, lr: PRefmvsBlock;
  bw4, bh4, bdx, bdy: Integer;
  mv: TMv;
begin
  if Pl <> 0 then begin lsh := ssH; lsv := ssV; end else begin lsh := 0; lsv := 0; end;
  hMul := 4 shr lsh; vMul := 4 shr lsv;
  bw4 := BlockDim[B.bs][0]; bh4 := BlockDim[B.bs][1];
  bdx := BlockDim[B.bs][2]; bdy := BlockDim[B.bs][3];
  if (by > TS^.RowStart) and ((Pl = 0) or (bw4 * hMul + bh4 * vMul >= 16)) then
  begin
    i := 0; x := 0;
    while (x < W4) and (i < IMin(bdx, 4)) do
    begin
      ar := RowPtr(RF, by - 1) + (bx + x + 1);
      step4 := IClip(BlockDim[ar^.bs][0], 2, 16);
      if ar^.ref.ref[0] > 0 then
      begin
        ow4 := IMin(step4, bw4);
        oh4 := IMin(bh4, 16) shr 1;
        mv := ar^.mv.mv[0];
        Mc(@Lap[0], nil, ow4 * hMul, ow4, (oh4 * 3 + 3) shr 2, bx + x, by, Pl, mv, ar^.ref.ref[0] - 1,
          Filter2dTab[A.filter1[bx + x + 1]][A.filter0[bx + x + 1]], False);
        McBlendH(Dst + x * hMul, DstStride, @Lap[0], hMul * ow4, vMul * oh4);
        Inc(i);
      end;
      Inc(x, step4);
    end;
  end;
  if bx > TS^.ColStart then
  begin
    i := 0; y := 0;
    while (y < H4) and (i < IMin(bdy, 4)) do
    begin
      lr := RowPtr(RF, by + y + 1) + (bx - 1);
      step4 := IClip(BlockDim[lr^.bs][1], 2, 16);
      if lr^.ref.ref[0] > 0 then
      begin
        ow4 := IMin(bw4, 16) shr 1;
        oh4 := IMin(step4, bh4);
        mv := lr^.mv.mv[0];
        Mc(@Lap[0], nil, hMul * ow4, ow4, oh4, bx, by + y, Pl, mv, lr^.ref.ref[0] - 1,
          Filter2dTab[L.filter1[by + y + 1]][L.filter0[by + y + 1]], False);
        McBlendV(Dst + y * vMul * DstStride, DstStride, @Lap[0], hMul * ow4, vMul * oh4);
        Inc(i);
      end;
      Inc(y, step4);
    end;
  end;
end;

procedure TAv1Decoder.WarpAffine(Dst: PWord; Dst16: PSmallInt; DStride, Bs, Pl, RefIdx: Integer;
  const Wmp: TWarpParams);
var
  lsh, lsv, hMul, vMul, width, height, x, y, srcX, srcY, dx, dy, mx, my, refStride, rs: Integer;
  mat3y, mat5y, mvx, mvy: Int64;
  ref, refPtr: PWord;
begin
  if Pl <> 0 then begin lsh := ssH; lsv := ssV; end else begin lsh := 0; lsv := 0; end;
  hMul := 4 shr lsh; vMul := 4 shr lsv;
  ref := RefPlane(RefIdx, Pl, False, refStride, width, height);
  y := 0;
  while y < BlockDim[Bs][1] * vMul do
  begin
    srcY := by * 4 + ((y + 4) shl lsv);
    mat3y := Int64(Wmp.Matrix[3]) * srcY + Wmp.Matrix[0];
    mat5y := Int64(Wmp.Matrix[5]) * srcY + Wmp.Matrix[1];
    x := 0;
    while x < BlockDim[Bs][0] * hMul do
    begin
      srcX := bx * 4 + ((x + 4) shl lsh);
      mvx := SarInt64(Int64(Wmp.Matrix[2]) * srcX + mat3y, lsh);
      mvy := SarInt64(Int64(Wmp.Matrix[4]) * srcX + mat5y, lsv);
      dx := Integer(SarInt64(mvx, 16)) - 4;
      mx := ((Integer(mvx) and $ffff) - Wmp.Alpha * 4 - Wmp.Beta * 7) and not $3f;
      dy := Integer(SarInt64(mvy, 16)) - 4;
      my := ((Integer(mvy) and $ffff) - Wmp.Gamma * 4 - Wmp.Delta * 4) and not $3f;
      if (dx < 3) or (dx + 8 + 4 > width) or (dy < 3) or (dy + 8 + 4 > height) then
      begin
        EmuEdge(15, 15, width, height, dx - 3, dy - 3, @EmuBuf[0], 32, ref, refStride);
        refPtr := @EmuBuf[32 * 3 + 3];
        rs := 32;
      end
      else
      begin
        refPtr := ref + refStride * dy + dx;
        rs := refStride;
      end;
      if Dst16 <> nil then Warp8x8t(Dst16 + x, DStride, refPtr, rs, Wmp, mx, my, Bd)
      else Warp8x8(Dst + x, DStride, refPtr, rs, Wmp, mx, my, Bd);
      Inc(x, 8);
    end;
    if Dst <> nil then Dst := Dst + 8 * DStride else Dst16 := Dst16 + 8 * DStride;
    Inc(y, 8);
  end;
end;

procedure TAv1Decoder.ReconInter(Bs: Integer);
var
  bw4, bh4, w4, h4, cbw4, cbh4, cbx4, cby4, cw4, ch4, chrIdx, pl, i, m, angle: Integer;
  hasChroma, isSub8x8, warpLuma: Boolean;
  dst, uvdst: PWord;
  uvdstoff, hOff, vOff, jntWeight, initX, initY, x, y, xOff, yOff, txtp, cfCtx, eob: Integer;
  r0: PRefmvsBlock;
  mask: PByte;
  ytx, uvtx: PTxDim;
  split: array[0..1] of Integer;
  leftF, topF, bbx4, bby4: Integer;
  intrabc: Boolean;
begin
  bbx4 := bx and 31; bby4 := by and 31;
  bw4 := BlockDim[Bs][0]; bh4 := BlockDim[Bs][1];
  w4 := IMin(bw4, Self.bw - bx); h4 := IMin(bh4, Self.bh - by);
  cbw4 := (bw4 + ssH) shr ssH; cbh4 := (bh4 + ssV) shr ssV;
  cbx4 := bx shr ssH; cby4 := by shr ssV;
  hasChroma := (Layout <> LAYOUT_I400) and ((bw4 > ssH) or ((bx and 1) <> 0)) and
               ((bh4 > ssV) or ((by and 1) <> 0));
  if Layout = LAYOUT_I400 then chrIdx := 0 else chrIdx := LAYOUT_I444 - Layout;
  dst := @Yp[4 * (by * StrideY + bx)];
  uvdstoff := 4 * ((bx shr ssH) + (by shr ssV) * StrideC);
  intrabc := IsKeyOrIntra(Fh);

  if intrabc then
  begin
    Mc(dst, nil, StrideY, bw4, bh4, bx, by, 0, B.mv[0], 0, FILTER_2D_BILINEAR, True);
    if hasChroma then
      for pl := 1 to 2 do
        Mc(PlanePtr(Self, pl) + uvdstoff, nil, StrideC,
          bw4 shl Ord(bw4 = ssH), bh4 shl Ord(bh4 = ssV), bx and not ssH, by and not ssV,
          pl, B.mv[0], 0, FILTER_2D_BILINEAR, True);
  end
  else if B.compType = COMP_INTER_NONE then
  begin
    warpLuma := (IMin(bw4, bh4) > 1) and
      (((B.interMode = GLOBALMV) and GmvWarpAllowed[B.ref[0]]) or
       ((B.motionMode = MM_WARP) and (WarpMv.WmType > WM_TYPE_TRANSLATION)));
    if warpLuma then
    begin
      if B.motionMode = MM_WARP then WarpAffine(dst, nil, StrideY, Bs, 0, B.ref[0], WarpMv)
      else WarpAffine(dst, nil, StrideY, Bs, 0, B.ref[0], Fh.Gmv[B.ref[0]]);
    end
    else
    begin
      Mc(dst, nil, StrideY, bw4, bh4, bx, by, 0, B.mv[0], B.ref[0], B.filter2d, False);
      if B.motionMode = MM_OBMC then Obmc(dst, StrideY, 0, w4, h4);
    end;
    if B.interintraType <> 0 then
    begin
      if B.interintraMode = II_SMOOTH_PRED then m := SMOOTH_PRED else m := B.interintraMode;
      angle := 0;
      m := PrepareIntraEdges(bx, bx > TS^.ColStart, by, by > TS^.RowStart, TS^.ColEnd, TS^.RowEnd,
        0, dst, StrideY, m, angle, bw4, bh4, False);
      IntraPred(m, @IITmp[0], 4 * bw4, bw4 * 4, bh4 * 4, 0, 0, 0);
      if B.interintraType = INTER_INTRA_BLEND then mask := IIMasks[0][Bs - BS_32x32][B.interintraMode]
      else mask := WedgeMasks[0][Bs - BS_32x32][0][B.wedgeIdx];
      McBlend(dst, StrideY, @IITmp[0], bw4 * 4, bh4 * 4, mask);
    end;

    if hasChroma then
    begin
      isSub8x8 := (bw4 = ssH) or (bh4 = ssV);
      if isSub8x8 then
      begin
        if bw4 = 1 then isSub8x8 := isSub8x8 and ((RowPtr(RF, by) + (bx - 1))^.ref.ref[0] > 0);
        if bh4 = ssV then isSub8x8 := isSub8x8 and ((RowPtr(RF, by - 1) + bx)^.ref.ref[0] > 0);
        if (bw4 = 1) and (bh4 = ssV) then
          isSub8x8 := isSub8x8 and ((RowPtr(RF, by - 1) + (bx - 1))^.ref.ref[0] > 0);
      end;
      if isSub8x8 then
      begin
        hOff := 0; vOff := 0;
        if (bw4 = 1) and (bh4 = ssV) then
        begin
          r0 := RowPtr(RF, by - 1) + (bx - 1);
          for pl := 0 to 1 do
            Mc(PlanePtr(Self, 1 + pl) + uvdstoff, nil, StrideC, bw4, bh4, bx - 1, by - 1, 1 + pl,
              r0^.mv.mv[0], r0^.ref.ref[0] - 1, TlFilter, False);
          vOff := 2 * StrideC; hOff := 2;
        end;
        if bw4 = 1 then
        begin
          r0 := RowPtr(RF, by) + (bx - 1);
          leftF := Filter2dTab[L.filter1[by]][L.filter0[by]];
          for pl := 0 to 1 do
            Mc(PlanePtr(Self, 1 + pl) + uvdstoff + vOff, nil, StrideC, bw4, bh4, bx - 1, by, 1 + pl,
              r0^.mv.mv[0], r0^.ref.ref[0] - 1, leftF, False);
          hOff := 2;
        end;
        if bh4 = ssV then
        begin
          r0 := RowPtr(RF, by - 1) + bx;
          topF := Filter2dTab[A.filter1[bx]][A.filter0[bx]];
          for pl := 0 to 1 do
            Mc(PlanePtr(Self, 1 + pl) + uvdstoff + hOff, nil, StrideC, bw4, bh4, bx, by - 1, 1 + pl,
              r0^.mv.mv[0], r0^.ref.ref[0] - 1, topF, False);
          vOff := 2 * StrideC;
        end;
        for pl := 0 to 1 do
          Mc(PlanePtr(Self, 1 + pl) + uvdstoff + hOff + vOff, nil, StrideC, bw4, bh4, bx, by, 1 + pl,
            B.mv[0], B.ref[0], B.filter2d, False);
      end
      else
      begin
        if (IMin(cbw4, cbh4) > 1) and
           (((B.interMode = GLOBALMV) and GmvWarpAllowed[B.ref[0]]) or
            ((B.motionMode = MM_WARP) and (WarpMv.WmType > WM_TYPE_TRANSLATION))) then
        begin
          for pl := 0 to 1 do
            if B.motionMode = MM_WARP then
              WarpAffine(PlanePtr(Self, 1 + pl) + uvdstoff, nil, StrideC, Bs, 1 + pl, B.ref[0], WarpMv)
            else
              WarpAffine(PlanePtr(Self, 1 + pl) + uvdstoff, nil, StrideC, Bs, 1 + pl, B.ref[0], Fh.Gmv[B.ref[0]]);
        end
        else
        begin
          for pl := 0 to 1 do
          begin
            Mc(PlanePtr(Self, 1 + pl) + uvdstoff, nil, StrideC,
              bw4 shl Ord(bw4 = ssH), bh4 shl Ord(bh4 = ssV), bx and not ssH, by and not ssV,
              1 + pl, B.mv[0], B.ref[0], B.filter2d, False);
            if B.motionMode = MM_OBMC then
              Obmc(PlanePtr(Self, 1 + pl) + uvdstoff, StrideC, 1 + pl, w4, h4);
          end;
        end;
        if B.interintraType <> 0 then
        begin
          if B.interintraType = INTER_INTRA_BLEND then mask := IIMasks[chrIdx][Bs - BS_32x32][B.interintraMode]
          else mask := WedgeMasks[chrIdx][Bs - BS_32x32][0][B.wedgeIdx];
          for pl := 0 to 1 do
          begin
            if B.interintraMode = II_SMOOTH_PRED then m := SMOOTH_PRED else m := B.interintraMode;
            angle := 0;
            uvdst := PlanePtr(Self, 1 + pl) + uvdstoff;
            m := PrepareIntraEdges(bx shr ssH, (bx shr ssH) > (TS^.ColStart shr ssH),
              by shr ssV, (by shr ssV) > (TS^.RowStart shr ssV),
              TS^.ColEnd shr ssH, TS^.RowEnd shr ssV, 0, uvdst, StrideC, m, angle, cbw4, cbh4, False);
            IntraPred(m, @IITmp[0], cbw4 * 4, cbw4 * 4, cbh4 * 4, 0, 0, 0);
            McBlend(uvdst, StrideC, @IITmp[0], cbw4 * 4, cbh4 * 4, mask);
          end;
        end;
      end;
    end;
    TlFilter := B.filter2d;
  end
  else
  begin
    // compound
    for i := 0 to 1 do
    begin
      if (B.interMode = GLOBALMV_GLOBALMV) and GmvWarpAllowed[B.ref[i]] then
        WarpAffine(nil, @CompTmp[i][0], bw4 * 4, Bs, 0, B.ref[i], Fh.Gmv[B.ref[i]])
      else
        Mc(nil, @CompTmp[i][0], 0, bw4, bh4, bx, by, 0, B.mv[i], B.ref[i], B.filter2d, False);
    end;
    jntWeight := 0;
    mask := nil;
    case B.compType of
      COMP_INTER_AVG:
        McAvg(dst, StrideY, @CompTmp[0][0], @CompTmp[1][0], bw4 * 4, bh4 * 4, Bd);
      COMP_INTER_WEIGHTED_AVG:
        begin
          jntWeight := JntWeights[B.ref[0]][B.ref[1]];
          McWAvg(dst, StrideY, @CompTmp[0][0], @CompTmp[1][0], bw4 * 4, bh4 * 4, jntWeight, Bd);
        end;
      COMP_INTER_SEG:
        begin
          if chrIdx = 0 then
            McWMask(dst, StrideY, @CompTmp[B.maskSign][0], @CompTmp[1 - B.maskSign][0], bw4 * 4, bh4 * 4,
              @SegMask[0], B.maskSign, 0, 0, Bd)
          else if chrIdx = 1 then
            McWMask(dst, StrideY, @CompTmp[B.maskSign][0], @CompTmp[1 - B.maskSign][0], bw4 * 4, bh4 * 4,
              @SegMask[0], B.maskSign, 1, 0, Bd)
          else
            McWMask(dst, StrideY, @CompTmp[B.maskSign][0], @CompTmp[1 - B.maskSign][0], bw4 * 4, bh4 * 4,
              @SegMask[0], B.maskSign, 1, 1, Bd);
          mask := @SegMask[0];
        end;
      COMP_INTER_WEDGE:
        begin
          mask := WedgeMasks[0][Bs - BS_32x32][0][B.wedgeIdx];
          McMask(dst, StrideY, @CompTmp[B.maskSign][0], @CompTmp[1 - B.maskSign][0], bw4 * 4, bh4 * 4, mask, Bd);
          if hasChroma then mask := WedgeMasks[chrIdx][Bs - BS_32x32][B.maskSign][B.wedgeIdx];
        end;
    end;
    if hasChroma then
      for pl := 0 to 1 do
      begin
        for i := 0 to 1 do
        begin
          if (B.interMode = GLOBALMV_GLOBALMV) and (IMin(cbw4, cbh4) > 1) and GmvWarpAllowed[B.ref[i]] then
            WarpAffine(nil, @CompTmp[i][0], (bw4 * 4) shr ssH, Bs, 1 + pl, B.ref[i], Fh.Gmv[B.ref[i]])
          else
            Mc(nil, @CompTmp[i][0], 0, bw4, bh4, bx, by, 1 + pl, B.mv[i], B.ref[i], B.filter2d, False);
        end;
        uvdst := PlanePtr(Self, 1 + pl) + uvdstoff;
        case B.compType of
          COMP_INTER_AVG:
            McAvg(uvdst, StrideC, @CompTmp[0][0], @CompTmp[1][0], (bw4 * 4) shr ssH, (bh4 * 4) shr ssV, Bd);
          COMP_INTER_WEIGHTED_AVG:
            McWAvg(uvdst, StrideC, @CompTmp[0][0], @CompTmp[1][0], (bw4 * 4) shr ssH, (bh4 * 4) shr ssV, jntWeight, Bd);
          COMP_INTER_WEDGE, COMP_INTER_SEG:
            McMask(uvdst, StrideC, @CompTmp[B.maskSign][0], @CompTmp[1 - B.maskSign][0],
              (bw4 * 4) shr ssH, (bh4 * 4) shr ssV, mask, Bd);
        end;
      end;
  end;

  cw4 := (w4 + ssH) shr ssH; ch4 := (h4 + ssV) shr ssV;
  if B.skip <> 0 then
  begin
    SetBytes(A.lcoef, bx, bw4, $40);
    SetBytes(L.lcoef, by, bh4, $40);
    if hasChroma then
    begin
      SetBytes(A.ccoef0, cbx4, cbw4, $40); SetBytes(A.ccoef1, cbx4, cbw4, $40);
      SetBytes(L.ccoef0, cby4, cbh4, $40); SetBytes(L.ccoef1, cby4, cbh4, $40);
    end;
    Exit;
  end;

  uvtx := @TxDims[B.uvtx];
  ytx := @TxDims[B.maxYtx];
  split[0] := B.txSplit0; split[1] := B.txSplit1;
  initY := 0;
  while initY < bh4 do
  begin
    initX := 0;
    while initX < bw4 do
    begin
      yOff := Ord(initY <> 0);
      dst := @Yp[4 * (by * StrideY + bx)] + StrideY * 4 * initY;
      y := initY;
      Inc(by, initY);
      while y < IMin(h4, initY + 16) do
      begin
        xOff := Ord(initX <> 0);
        x := initX;
        Inc(bx, initX);
        while x < IMin(w4, initX + 16) do
        begin
          ReadCoefTree(Bs, B.maxYtx, 0, split, xOff, yOff, dst + x * 4);
          Inc(bx, ytx^.w);
          Inc(x, ytx^.w); Inc(xOff);
        end;
        dst := dst + StrideY * 4 * ytx^.h;
        Dec(bx, x);
        Inc(by, ytx^.h);
        Inc(y, ytx^.h); Inc(yOff);
      end;
      Dec(by, y);

      if hasChroma then
        for pl := 0 to 1 do
        begin
          uvdst := PlanePtr(Self, 1 + pl) + uvdstoff + ((StrideC * initY * 4) shr ssV);
          y := initY shr ssV;
          Inc(by, initY);
          while y < IMin(ch4, (initY + 16) shr ssV) do
          begin
            x := initX shr ssH;
            Inc(bx, initX);
            while x < IMin(cw4, (initX + 16) shr ssH) do
            begin
              txtp := TxtpMap[(bby4 + (y shl ssV)) * 32 + bbx4 + (x shl ssH)];
              eob := DecodeCoefs(TS^.Msac, TS^.Cdf, B.uvtx, bw4, bh4, 0, 1 + pl, 1, ssH, ssV,
                @PByte(IfPl(pl, @A.ccoef0[0], @A.ccoef1[0]))[cbx4 + x],
                @PByte(IfPl(pl, @L.ccoef0[0], @L.ccoef1[0]))[cby4 + y],
                DqFor(1 + pl, 0), DqFor(1 + pl, 1), @Cf[0], 0, 0,
                Fh.ReducedTxtpSet, Fh.Segmentation.QIdx[B.segId] = 0, Fh.Segmentation.Lossless[B.segId],
                txtp, cfCtx);
              if pl = 0 then
              begin
                SetBytes(A.ccoef0, cbx4 + x, IMin(uvtx^.w, (Self.bw - bx + ssH) shr ssH), cfCtx);
                SetBytes(L.ccoef0, cby4 + y, IMin(uvtx^.h, (Self.bh - by + ssV) shr ssV), cfCtx);
              end
              else
              begin
                SetBytes(A.ccoef1, cbx4 + x, IMin(uvtx^.w, (Self.bw - bx + ssH) shr ssH), cfCtx);
                SetBytes(L.ccoef1, cby4 + y, IMin(uvtx^.h, (Self.bh - by + ssV) shr ssV), cfCtx);
              end;
              if eob >= 0 then DoItx(uvdst + 4 * x, StrideC, @Cf[0], eob, B.uvtx, txtp, Bd);
              Inc(bx, uvtx^.w shl ssH);
              Inc(x, uvtx^.w);
            end;
            uvdst := uvdst + StrideC * 4 * uvtx^.h;
            Dec(bx, x shl ssH);
            Inc(by, uvtx^.h shl ssV);
            Inc(y, uvtx^.h);
          end;
          Dec(by, y shl ssV);
        end;
      Inc(initX, 16);
    end;
    Inc(initY, 16);
  end;
end;
