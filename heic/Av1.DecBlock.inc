// Av1.DecBlock.inc - block / partition syntax (port of dav1d decode.c decode_b,
// decode_sb and helpers, env.h context derivations). Included by Av1.Decoder.

// ---------------------------------------------------------------- edge tree

type
  TEdgeNode = record
    o, h0, h1, v0, v1: Byte;
    h4, v4: Byte;                       // branches
    split: array[0..3] of Integer;      // branches: child node indices
    tsplit: array[0..2] of Byte;        // tips (BL_8X8)
  end;

var
  EdgeNodes: array of TEdgeNode;
  EdgeRoot: array[0..1] of Integer;     // [0] = sb128 root, [1] = sb64 root
  EdgeTreeBuilt: Boolean = False;

function NewEdgeNode: Integer;
begin
  Result := Length(EdgeNodes);
  SetLength(EdgeNodes, Result + 1);
  FillChar(EdgeNodes[Result], SizeOf(TEdgeNode), 0);
end;

procedure InitEdges(N: Integer; Bl, Flags: Integer);
begin
  with EdgeNodes[N] do
  begin
    o := Flags;
    h0 := Flags or EDGE_ALL_LEFT_HAS_BOTTOM;
    v0 := Flags or EDGE_ALL_TOP_HAS_RIGHT;
    if Bl = BL_8X8 then
    begin
      h1 := Flags and (EDGE_ALL_LEFT_HAS_BOTTOM or EDGE_I420_TOP_HAS_RIGHT);
      v1 := Flags and (EDGE_ALL_TOP_HAS_RIGHT or EDGE_I420_LEFT_HAS_BOTTOM or EDGE_I422_LEFT_HAS_BOTTOM);
      tsplit[0] := (Flags and EDGE_ALL_TOP_HAS_RIGHT) or EDGE_I422_LEFT_HAS_BOTTOM;
      tsplit[1] := Flags or EDGE_I444_TOP_HAS_RIGHT;
      tsplit[2] := Flags and (EDGE_I420_TOP_HAS_RIGHT or EDGE_I420_LEFT_HAS_BOTTOM or EDGE_I422_LEFT_HAS_BOTTOM);
    end
    else
    begin
      h1 := Flags and EDGE_ALL_LEFT_HAS_BOTTOM;
      v1 := Flags and EDGE_ALL_TOP_HAS_RIGHT;
      h4 := EDGE_ALL_LEFT_HAS_BOTTOM;
      v4 := EDGE_ALL_TOP_HAS_RIGHT;
      if Bl = BL_16X16 then
      begin
        h4 := h4 or (Flags and EDGE_I420_TOP_HAS_RIGHT);
        v4 := v4 or (Flags and (EDGE_I420_LEFT_HAS_BOTTOM or EDGE_I422_LEFT_HAS_BOTTOM));
      end;
    end;
  end;
end;

function InitModeNode(Bl: Integer; TopHasRight, LeftHasBottom: Boolean): Integer;
var n, c, f: Integer;
begin
  Result := NewEdgeNode;
  f := 0;
  if TopHasRight then f := f or EDGE_ALL_TOP_HAS_RIGHT;
  if LeftHasBottom then f := f or EDGE_ALL_LEFT_HAS_BOTTOM;
  InitEdges(Result, Bl, f);
  for n := 0 to 3 do
  begin
    if Bl = BL_16X16 then
    begin
      c := NewEdgeNode;
      f := 0;
      if not ((n = 3) or ((n = 1) and not TopHasRight)) then f := f or EDGE_ALL_TOP_HAS_RIGHT;
      if (n = 0) or ((n = 2) and LeftHasBottom) then f := f or EDGE_ALL_LEFT_HAS_BOTTOM;
      InitEdges(c, Bl + 1, f);
    end
    else
      c := InitModeNode(Bl + 1, not ((n = 3) or ((n = 1) and not TopHasRight)),
                        (n = 0) or ((n = 2) and LeftHasBottom));
    EdgeNodes[Result].split[n] := c;
  end;
end;

procedure BuildEdgeTree;
begin
  if EdgeTreeBuilt then Exit;
  SetLength(EdgeNodes, 0);
  EdgeRoot[0] := InitModeNode(BL_128X128, True, False);
  EdgeRoot[1] := InitModeNode(BL_64X64, True, False);
  EdgeTreeBuilt := True;
end;

// ---------------------------------------------------------------- contexts

function NegDeinterleave(diff, ref, max: Integer): Integer;
begin
  if ref = 0 then Exit(diff);
  if ref >= max - 1 then Exit(max - diff - 1);
  if 2 * ref < max then
  begin
    if diff <= 2 * ref then
    begin
      if (diff and 1) <> 0 then Exit(ref + ((diff + 1) shr 1))
      else Exit(ref - (diff shr 1));
    end;
    Exit(diff);
  end
  else
  begin
    if diff <= 2 * (max - ref - 1) then
    begin
      if (diff and 1) <> 0 then Exit(ref + ((diff + 1) shr 1))
      else Exit(ref - (diff shr 1));
    end;
    Exit(max - (diff + 1));
  end;
end;

function GetDrlContext(const S: TMvStack; RefIdx: Integer): Integer;
begin
  if S[RefIdx].weight >= 640 then Result := Ord(S[RefIdx + 1].weight < 640)
  else if S[RefIdx + 1].weight < 640 then Result := 2
  else Result := 0;
end;

// ---------------------------------------------------------------- MVs

procedure TAv1Decoder.ReadMvResidual(var Mv: TMv; MvPrec: Integer; Intrabc: Boolean);
var joint: Integer;

  function ReadComp(var C: TCdfMvComponent): Integer;
  var sign, cl, up, fp, hp, n: Integer;
  begin
    sign := MsacDecodeBoolAdapt(TS^.Msac, @C.sign[0]);
    cl := MsacDecodeSymbolAdapt(TS^.Msac, @C.classes[0], 10);
    fp := 3; hp := 1;
    if cl = 0 then
    begin
      up := MsacDecodeBoolAdapt(TS^.Msac, @C.class0[0]);
      if MvPrec >= 0 then
      begin
        fp := MsacDecodeSymbolAdapt(TS^.Msac, @C.class0_fp[up][0], 3);
        if MvPrec > 0 then hp := MsacDecodeBoolAdapt(TS^.Msac, @C.class0_hp[0]);
      end;
    end
    else
    begin
      up := 1 shl cl;
      for n := 0 to cl - 1 do
        up := up or (Integer(MsacDecodeBoolAdapt(TS^.Msac, @C.classN[n][0])) shl n);
      if MvPrec >= 0 then
      begin
        fp := MsacDecodeSymbolAdapt(TS^.Msac, @C.classN_fp[0], 3);
        if MvPrec > 0 then hp := MsacDecodeBoolAdapt(TS^.Msac, @C.classN_hp[0]);
      end;
    end;
    Result := ((up shl 3) or (fp shl 1) or hp) + 1;
    if sign <> 0 then Result := -Result;
  end;

begin
  // intra block copy uses the same (separately reset) MV CDF set as inter MVs
  joint := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.mv.joint[0], 3);
  if (joint and MV_JOINT_V) <> 0 then Mv.y := Mv.y + ReadComp(TS^.Cdf.mv.comp[0]);
  if (joint and MV_JOINT_H) <> 0 then Mv.x := Mv.x + ReadComp(TS^.Cdf.mv.comp[1]);
  if Intrabc then ;
end;

// ---------------------------------------------------------------- tx trees

procedure TAv1Decoder.ReadTxTree(From, Depth: Integer; var Masks: array of Integer; XOff, YOff: Integer);
var
  td, sub: PTxDim;
  txw, txh, cat, ca, cl, isSplit, subTx, txsw, txsh: Integer;
begin
  td := @TxDims[From];
  txw := td^.lw; txh := td^.lh;
  if (Depth < 2) and (From > TX_4X4) then
  begin
    cat := 2 * (TX_64X64 - td^.max) - Depth;
    ca := Ord(A.tx[bx] < txw);
    cl := Ord(L.tx[by] < txh);
    isSplit := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.txpart[cat][ca + cl][0]);
    if isSplit <> 0 then Masks[Depth] := Masks[Depth] or (1 shl (YOff * 4 + XOff));
  end
  else isSplit := 0;

  if (isSplit <> 0) and (td^.max > TX_8X8) then
  begin
    subTx := td^.sub;
    sub := @TxDims[subTx];
    txsw := sub^.w; txsh := sub^.h;
    ReadTxTree(subTx, Depth + 1, Masks, XOff * 2 + 0, YOff * 2 + 0);
    Inc(bx, txsw);
    if (txw >= txh) and (bx < Self.bw) then
      ReadTxTree(subTx, Depth + 1, Masks, XOff * 2 + 1, YOff * 2 + 0);
    Dec(bx, txsw);
    Inc(by, txsh);
    if (txh >= txw) and (by < Self.bh) then
    begin
      ReadTxTree(subTx, Depth + 1, Masks, XOff * 2 + 0, YOff * 2 + 1);
      Inc(bx, txsw);
      if (txw >= txh) and (bx < Self.bw) then
        ReadTxTree(subTx, Depth + 1, Masks, XOff * 2 + 1, YOff * 2 + 1);
      Dec(bx, txsw);
    end;
    Dec(by, txsh);
  end
  else
  begin
    if isSplit <> 0 then
    begin
      SetShorts(A.tx, bx, td^.w, TX_4X4);
      SetShorts(L.tx, by, td^.h, TX_4X4);
    end
    else
    begin
      SetShorts(A.tx, bx, td^.w, txw);
      SetShorts(L.tx, by, td^.h, txh);
    end;
  end;
end;

procedure TAv1Decoder.ReadVartxTree(Bs: Integer);
var
  bw4, bh4, x, y, xOff, yOff: Integer;
  ytx: PTxDim;
  split: array[0..1] of Integer;
begin
  bw4 := BlockDim[Bs][0]; bh4 := BlockDim[Bs][1];
  split[0] := 0; split[1] := 0;
  B.maxYtx := MaxTxfmSizeForBs[Bs][0];
  if (B.skip = 0) and (Fh.Segmentation.Lossless[B.segId] or (B.maxYtx = TX_4X4)) then
  begin
    B.maxYtx := TX_4X4; B.uvtx := TX_4X4;
    if Fh.TxfmMode = TX_SWITCHABLE then
    begin
      SetShorts(A.tx, bx, bw4, TX_4X4);
      SetShorts(L.tx, by, bh4, TX_4X4);
    end;
  end
  else if (Fh.TxfmMode <> TX_SWITCHABLE) or (B.skip <> 0) then
  begin
    if Fh.TxfmMode = TX_SWITCHABLE then
    begin
      SetShorts(A.tx, bx, bw4, BlockDim[Bs][2]);
      SetShorts(L.tx, by, bh4, BlockDim[Bs][3]);
    end;
    B.uvtx := MaxTxfmSizeForBs[Bs][Layout];
  end
  else
  begin
    ytx := @TxDims[B.maxYtx];
    y := 0; yOff := 0;
    while y < bh4 do
    begin
      x := 0; xOff := 0;
      while x < bw4 do
      begin
        ReadTxTree(B.maxYtx, 0, split, xOff, yOff);
        Inc(bx, ytx^.w);
        Inc(x, ytx^.w); Inc(xOff);
      end;
      Dec(bx, x);
      Inc(by, ytx^.h);
      Inc(y, ytx^.h); Inc(yOff);
    end;
    Dec(by, y);
    B.uvtx := MaxTxfmSizeForBs[Bs][Layout];
  end;
  B.txSplit0 := split[0];
  B.txSplit1 := split[1];
end;

// ---------------------------------------------------------------- warp

procedure TAv1Decoder.FindMatchingRef(EdgeFlags, Bw4, Bh4, W4, H4: Integer; HaveLeft, HaveTop: Boolean;
  Ref: Integer; var Masks: array of UInt64);
var
  count, aw4, off, x, lh4, y: Integer;
  haveTopLeft, haveTopRight: Boolean;
  r2: PRefmvsBlock;
  mask: LongWord;

  function Matches(P: PRefmvsBlock): Boolean; inline;
  begin Result := (P^.ref.ref[0] = Ref + 1) and (P^.ref.ref[1] = -1); end;

begin
  count := 0;
  haveTopLeft := HaveTop and HaveLeft;
  haveTopRight := (IMax(Bw4, Bh4) < 32) and HaveTop and (bx + Bw4 < TS^.ColEnd) and
                  ((EdgeFlags and EDGE_I444_TOP_HAS_RIGHT) <> 0);
  if HaveTop then
  begin
    r2 := RowPtr(RF, by - 1) + bx;
    if Matches(r2) then begin Masks[0] := Masks[0] or 1; count := 1; end;
    aw4 := BlockDim[r2^.bs][0];
    if aw4 >= Bw4 then
    begin
      off := bx and (aw4 - 1);
      if off <> 0 then haveTopLeft := False;
      if aw4 - off > Bw4 then haveTopRight := False;
    end
    else
    begin
      mask := LongWord(1) shl aw4;
      x := aw4;
      while x < W4 do
      begin
        Inc(r2, aw4);
        if Matches(r2) then
        begin
          Masks[0] := Masks[0] or mask;
          Inc(count);
          if count >= 8 then Exit;
        end;
        aw4 := BlockDim[r2^.bs][0];
        mask := mask shl aw4;
        Inc(x, aw4);
      end;
    end;
  end;
  if HaveLeft then
  begin
    r2 := RowPtr(RF, by) + (bx - 1);
    if Matches(r2) then
    begin
      Masks[1] := Masks[1] or 1;
      Inc(count);
      if count >= 8 then Exit;
    end;
    lh4 := BlockDim[r2^.bs][1];
    if lh4 >= Bh4 then
    begin
      if (by and (lh4 - 1)) <> 0 then haveTopLeft := False;
    end
    else
    begin
      mask := LongWord(1) shl lh4;
      y := lh4;
      while y < H4 do
      begin
        r2 := RowPtr(RF, by + y) + (bx - 1);
        if Matches(r2) then
        begin
          Masks[1] := Masks[1] or mask;
          Inc(count);
          if count >= 8 then Exit;
        end;
        lh4 := BlockDim[r2^.bs][1];
        mask := mask shl lh4;
        Inc(y, lh4);
      end;
    end;
  end;
  if haveTopLeft and Matches(RowPtr(RF, by - 1) + (bx - 1)) then
  begin
    Masks[1] := Masks[1] or (UInt64(1) shl 32);
    Inc(count);
    if count >= 8 then Exit;
  end;
  if haveTopRight and Matches(RowPtr(RF, by - 1) + (bx + Bw4)) then
    Masks[0] := Masks[0] or (UInt64(1) shl 32);
end;

procedure TAv1Decoder.DeriveWarpMv(Bw4, Bh4: Integer; const Masks: array of UInt64; const Mv: TMv);
var
  pts: array[0..7, 0..3] of Integer;   // in.x, in.y, out.x, out.y
  np, i, j, k, ret, thresh, off, tz: Integer;
  mvd: array[0..7] of Integer;
  xmask, ymask: LongWord;
  flat: array[0..31] of Integer;

  procedure AddSample(dx, dy, sx, sy: Integer; Rp: PRefmvsBlock);
  begin
    pts[np][0] := 16 * (2 * dx + sx * BlockDim[Rp^.bs][0]) - 8;
    pts[np][1] := 16 * (2 * dy + sy * BlockDim[Rp^.bs][1]) - 8;
    pts[np][2] := pts[np][0] + Rp^.mv.mv[0].x;
    pts[np][3] := pts[np][1] + Rp^.mv.mv[0].y;
    Inc(np);
  end;

begin
  np := 0;
  if (LongWord(Masks[0]) = 1) and ((Masks[1] shr 32) = 0) then
  begin
    off := bx and (BlockDim[(RowPtr(RF, by - 1) + bx)^.bs][0] - 1);
    AddSample(-off, 0, 1, -1, RowPtr(RF, by - 1) + bx);
  end
  else
  begin
    off := 0; xmask := LongWord(Masks[0]);
    while (np < 8) and (xmask <> 0) do
    begin
      tz := CtzI(xmask);
      Inc(off, tz);
      xmask := xmask shr tz;
      AddSample(off, 0, 1, -1, RowPtr(RF, by - 1) + (bx + off));
      xmask := xmask and not LongWord(1);
    end;
  end;
  if (np < 8) and (Masks[1] = 1) then
  begin
    off := by and (BlockDim[(RowPtr(RF, by) + (bx - 1))^.bs][1] - 1);
    AddSample(0, -off, -1, 1, RowPtr(RF, by - off) + (bx - 1));
  end
  else
  begin
    off := 0; ymask := LongWord(Masks[1]);
    while (np < 8) and (ymask <> 0) do
    begin
      tz := CtzI(ymask);
      Inc(off, tz);
      ymask := ymask shr tz;
      AddSample(0, off, -1, 1, RowPtr(RF, by + off) + (bx - 1));
      ymask := ymask and not LongWord(1);
    end;
  end;
  if (np < 8) and ((Masks[1] shr 32) <> 0) then
    AddSample(0, 0, -1, -1, RowPtr(RF, by - 1) + (bx - 1));
  if (np < 8) and ((Masks[0] shr 32) <> 0) then
    AddSample(Bw4, 0, 1, -1, RowPtr(RF, by - 1) + (bx + Bw4));

  ret := 0;
  thresh := 4 * IClip(IMax(Bw4, Bh4), 4, 28);
  for i := 0 to np - 1 do
  begin
    mvd[i] := Abs(pts[i][2] - pts[i][0] - Mv.x) + Abs(pts[i][3] - pts[i][1] - Mv.y);
    if mvd[i] > thresh then mvd[i] := -1 else Inc(ret);
  end;
  if ret = 0 then ret := 1
  else
  begin
    i := 0; j := np - 1; k := 0;
    while k < np - ret do
    begin
      while mvd[i] <> -1 do Inc(i);
      while mvd[j] = -1 do Dec(j);
      if i > j then Break;
      mvd[i] := mvd[j];
      pts[i] := pts[j];
      Inc(k); Inc(i); Dec(j);
    end;
  end;
  for i := 0 to 7 do for k := 0 to 3 do flat[i * 4 + k] := pts[i][k];
  if (not FindAffineInt(flat, ret, Bw4, Bh4, Mv.y, Mv.x, WarpMv, bx, by)) and
     (not GetShearParams(WarpMv)) then
    WarpMv.WmType := WM_TYPE_AFFINE
  else
    WarpMv.WmType := WM_TYPE_IDENTITY;
end;

// ---------------------------------------------------------------- palette

procedure TAv1Decoder.ReadPalPlane(Pl, SzCtx, Bx4, By4: Integer);
var
  cache: array[0..15] of Word; usedCache: array[0..7] of Word;
  palSz, lCache, aCache, nCache, i, n, nUsed, prev, bits, maxV, delta, notpl, lp, ap, m: Integer;
  newp: array[0..7] of Word;
  lPal, aPal: PWord;
begin
  palSz := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.pal_sz[Pl][SzCtx][0], 6) + 2;
  B.palSz[Pl] := palSz;
  if Pl <> 0 then lCache := L.palszuv[By4] else lCache := L.palsz[By4];
  if (By4 and 15) = 0 then aCache := 0
  else if Pl <> 0 then aCache := A.palszuv[Bx4]
  else aCache := A.palsz[Bx4];
  lPal := @L.pal[By4][Pl][0];
  aPal := @A.pal[Bx4][Pl][0];
  nCache := 0; lp := 0; ap := 0;
  while (lCache > 0) and (aCache > 0) do
  begin
    if lPal[lp] < aPal[ap] then
    begin
      if (nCache = 0) or (cache[nCache - 1] <> lPal[lp]) then begin cache[nCache] := lPal[lp]; Inc(nCache); end;
      Inc(lp); Dec(lCache);
    end
    else
    begin
      if aPal[ap] = lPal[lp] then begin Inc(lp); Dec(lCache); end;
      if (nCache = 0) or (cache[nCache - 1] <> aPal[ap]) then begin cache[nCache] := aPal[ap]; Inc(nCache); end;
      Inc(ap); Dec(aCache);
    end;
  end;
  if lCache > 0 then
    repeat
      if (nCache = 0) or (cache[nCache - 1] <> lPal[lp]) then begin cache[nCache] := lPal[lp]; Inc(nCache); end;
      Inc(lp); Dec(lCache);
    until lCache <= 0
  else if aCache > 0 then
    repeat
      if (nCache = 0) or (cache[nCache - 1] <> aPal[ap]) then begin cache[nCache] := aPal[ap]; Inc(nCache); end;
      Inc(ap); Dec(aCache);
    until aCache <= 0;

  i := 0; n := 0;
  while (n < nCache) and (i < palSz) do
  begin
    if MsacDecodeBoolEqui(TS^.Msac) <> 0 then begin usedCache[i] := cache[n]; Inc(i); end;
    Inc(n);
  end;
  nUsed := i;
  notpl := Ord(Pl = 0);
  if i < palSz then
  begin
    prev := MsacDecodeBools(TS^.Msac, Bd);
    newp[i] := prev; Inc(i);
    if i < palSz then
    begin
      bits := Bd - 3 + Integer(MsacDecodeBools(TS^.Msac, 2));
      maxV := (1 shl Bd) - 1;
      repeat
        delta := MsacDecodeBools(TS^.Msac, bits);
        prev := IMin(prev + delta + notpl, maxV);
        newp[i] := prev; Inc(i);
        if prev + notpl >= maxV then
        begin
          while i < palSz do begin newp[i] := maxV; Inc(i); end;
          Break;
        end;
        bits := IMin(bits, 1 + ULog2(maxV - prev - notpl));
      until i >= palSz;
    end;
    // merge
    n := 0; m := nUsed;
    for i := 0 to palSz - 1 do
      if (n < nUsed) and ((m >= palSz) or (usedCache[n] <= newp[m])) then
      begin Pal[Pl][i] := usedCache[n]; Inc(n); end
      else begin Pal[Pl][i] := newp[m]; Inc(m); end;
  end
  else
    for i := 0 to nUsed - 1 do Pal[Pl][i] := usedCache[i];
end;

procedure TAv1Decoder.ReadPalUv(SzCtx, Bx4, By4: Integer);
var bits, prev, maxV, i, delta: Integer;
begin
  ReadPalPlane(1, SzCtx, Bx4, By4);
  if MsacDecodeBoolEqui(TS^.Msac) <> 0 then
  begin
    bits := Bd - 4 + Integer(MsacDecodeBools(TS^.Msac, 2));
    prev := MsacDecodeBools(TS^.Msac, Bd);
    Pal[2][0] := prev;
    maxV := (1 shl Bd) - 1;
    for i := 1 to B.palSz[1] - 1 do
    begin
      delta := MsacDecodeBools(TS^.Msac, bits);
      if (delta <> 0) and (MsacDecodeBoolEqui(TS^.Msac) <> 0) then delta := -delta;
      prev := (prev + delta) and maxV;
      Pal[2][i] := prev;
    end;
  end
  else
    for i := 0 to B.palSz[1] - 1 do Pal[2][i] := MsacDecodeBools(TS^.Msac, Bd);
end;

procedure TAv1Decoder.ReadPalIndices(PalIdx: PByte; PalSz, Pl, W4, H4, Bw4, Bh4: Integer);
var
  stride, i, j, first, last, l, t, tl, ctx, prio, colorIdx, y, rank, v, k: Integer;
  haveTop, haveLeft: Boolean;
  p: array[0..2] of Integer;
  mask: LongWord;
  row: PByte;
begin
  stride := Bw4 * 4;
  PalIdx[0] := MsacDecodeUniform(TS^.Msac, PalSz);
  for i := 1 to 4 * (W4 + H4) - 2 do
  begin
    first := IMin(i, W4 * 4 - 1);
    last := IMax(0, i - H4 * 4 + 1);
    haveTop := i > first;
    row := PalIdx + first + (i - first) * stride;
    j := first;
    while j >= last do
    begin
      haveLeft := j > 0;
      if not haveLeft then
      begin ctx := 0; prio := 1; p[0] := row[-stride]; mask := LongWord(1) shl p[0]; end
      else if not haveTop then
      begin ctx := 0; prio := 1; p[0] := row[-1]; mask := LongWord(1) shl p[0]; end
      else
      begin
        l := row[-1]; t := row[-stride]; tl := row[-(stride + 1)];
        if (t = l) and (t = tl) then
        begin ctx := 4; prio := 1; p[0] := t; mask := LongWord(1) shl t; end
        else if t = l then
        begin ctx := 3; prio := 2; p[0] := t; p[1] := tl; mask := (LongWord(1) shl t) or (LongWord(1) shl tl); end
        else if (t = tl) or (l = tl) then
        begin
          ctx := 2; prio := 2; p[0] := tl;
          if t = tl then p[1] := l else p[1] := t;
          mask := (LongWord(1) shl tl) or (LongWord(1) shl p[1]);
        end
        else
        begin
          ctx := 1; prio := 3; p[0] := IMin(t, l); p[1] := IMax(t, l); p[2] := tl;
          mask := (LongWord(1) shl t) or (LongWord(1) shl l) or (LongWord(1) shl tl);
        end;
      end;
      colorIdx := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.color_map[Pl][PalSz - 2][ctx][0], PalSz - 1);
      if colorIdx < prio then v := p[colorIdx]
      else
      begin
        // the (colorIdx - prio)-th value not in mask, ascending
        rank := colorIdx - prio;
        v := 0;
        k := -1;
        while True do
        begin
          if (mask and (LongWord(1) shl v)) = 0 then
          begin
            Inc(k);
            if k = rank then Break;
          end;
          Inc(v);
        end;
      end;
      row^ := v;
      haveTop := True;
      Dec(j);
      Inc(row, stride - 1);
    end;
  end;
  if Bw4 > W4 then
    for y := 0 to 4 * H4 - 1 do
      FillChar(PalIdx[y * stride + 4 * W4], 4 * (Bw4 - W4), PalIdx[y * stride + 4 * W4 - 1]);
  if H4 < Bh4 then
    for y := H4 * 4 to Bh4 * 4 - 1 do
      Move(PalIdx[stride * (4 * H4 - 1)], PalIdx[y * stride], Bw4 * 4);
end;

// ---------------------------------------------------------------- partition

function TAv1Decoder.DecodeSb(Bl, Node: Integer): Boolean;
var
  hsz, bx8, by8, ctx, bp: Integer;
  haveH, haveV: Boolean;
  pc: PWord;
  isSplit: LongWord;
  N: ^TEdgeNode;
  tlFilt: Integer;

  function GatherTop: LongWord;
  begin
    Result := LongWord(pc[PARTITION_V - 1]) - pc[PARTITION_T_TOP_SPLIT];
    Result := Result + pc[PARTITION_T_LEFT_SPLIT - 1];
    if Bl <> BL_128X128 then Result := Result + LongWord(pc[PARTITION_V4 - 1]) - pc[PARTITION_T_RIGHT_SPLIT];
  end;
  function GatherLeft: LongWord;
  begin
    Result := LongWord(pc[PARTITION_H - 1]) - pc[PARTITION_H];
    Result := Result + LongWord(pc[PARTITION_SPLIT - 1]) - pc[PARTITION_T_LEFT_SPLIT];
    if Bl <> BL_128X128 then Result := Result + LongWord(pc[PARTITION_H4 - 1]) - pc[PARTITION_H4];
  end;
  procedure SetPartCtx;
  var k: Integer;
  begin
    for k := 0 to hsz - 1 do
    begin
      A.partition[bx8 + k] := AlPartCtx[0][Bl][bp];
      L.partition[by8 + k] := AlPartCtx[1][Bl][bp];
    end;
  end;

begin
  Result := False;
  if Node < 0 then
  begin
    if Bl = BL_128X128 then Node := EdgeRoot[0] else Node := EdgeRoot[1];
  end;
  N := @EdgeNodes[Node];
  hsz := 16 shr Bl;
  haveH := Self.bw > bx + hsz;
  haveV := Self.bh > by + hsz;
  if (not haveH) and (not haveV) then
  begin
    DecodeSb(Bl + 1, N^.split[0]);
    Exit;
  end;
  bx8 := bx shr 1; by8 := by shr 1;
  ctx := ((A.partition[bx8] shr (4 - Bl)) and 1) + (((L.partition[by8] shr (4 - Bl)) and 1) shl 1);
  pc := @TS^.Cdf.m.partition[Bl][ctx][0];

  if haveH and haveV then
  begin
    bp := MsacDecodeSymbolAdapt(TS^.Msac, pc, PartitionTypeCount[Bl]);
    if (Layout = LAYOUT_I422) and ((bp = PARTITION_V) or (bp = PARTITION_V4) or
       (bp = PARTITION_T_LEFT_SPLIT) or (bp = PARTITION_T_RIGHT_SPLIT)) then
      raise EAv1.Create('AV1: invalid 4:2:2 partition');
    case bp of
      PARTITION_NONE:
        DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.o);
      PARTITION_H:
        begin
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.h0);
          Inc(by, hsz);
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.h1);
          Dec(by, hsz);
        end;
      PARTITION_V:
        begin
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.v0);
          Inc(bx, hsz);
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.v1);
          Dec(bx, hsz);
        end;
      PARTITION_SPLIT:
        if Bl = BL_8X8 then
        begin
          DecodeBlock(Bl, BS_4x4, bp, EDGE_ALL_TR_AND_BL);
          tlFilt := TlFilter;
          Inc(bx);
          DecodeBlock(Bl, BS_4x4, bp, N^.tsplit[0]);
          Dec(bx); Inc(by);
          DecodeBlock(Bl, BS_4x4, bp, N^.tsplit[1]);
          Inc(bx);
          TlFilter := tlFilt;
          DecodeBlock(Bl, BS_4x4, bp, N^.tsplit[2]);
          Dec(bx); Dec(by);
        end
        else
        begin
          DecodeSb(Bl + 1, N^.split[0]);
          Inc(bx, hsz);
          DecodeSb(Bl + 1, N^.split[1]);
          Dec(bx, hsz); Inc(by, hsz);
          DecodeSb(Bl + 1, N^.split[2]);
          Inc(bx, hsz);
          DecodeSb(Bl + 1, N^.split[3]);
          Dec(bx, hsz); Dec(by, hsz);
        end;
      PARTITION_T_TOP_SPLIT:
        begin
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, EDGE_ALL_TR_AND_BL);
          Inc(bx, hsz);
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.v1);
          Dec(bx, hsz); Inc(by, hsz);
          DecodeBlock(Bl, BlockSizes[Bl][bp][1], bp, N^.h1);
          Dec(by, hsz);
        end;
      PARTITION_T_BOTTOM_SPLIT:
        begin
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.h0);
          Inc(by, hsz);
          DecodeBlock(Bl, BlockSizes[Bl][bp][1], bp, N^.v0);
          Inc(bx, hsz);
          DecodeBlock(Bl, BlockSizes[Bl][bp][1], bp, 0);
          Dec(bx, hsz); Dec(by, hsz);
        end;
      PARTITION_T_LEFT_SPLIT:
        begin
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, EDGE_ALL_TR_AND_BL);
          Inc(by, hsz);
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.h1);
          Dec(by, hsz); Inc(bx, hsz);
          DecodeBlock(Bl, BlockSizes[Bl][bp][1], bp, N^.v1);
          Dec(bx, hsz);
        end;
      PARTITION_T_RIGHT_SPLIT:
        begin
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.v0);
          Inc(bx, hsz);
          DecodeBlock(Bl, BlockSizes[Bl][bp][1], bp, N^.h0);
          Inc(by, hsz);
          DecodeBlock(Bl, BlockSizes[Bl][bp][1], bp, 0);
          Dec(by, hsz); Dec(bx, hsz);
        end;
      PARTITION_H4:
        begin
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.h0);
          Inc(by, hsz shr 1);
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.h4);
          Inc(by, hsz shr 1);
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, EDGE_ALL_LEFT_HAS_BOTTOM);
          Inc(by, hsz shr 1);
          if by < Self.bh then DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.h1);
          Dec(by, (hsz * 3) shr 1);
        end;
      PARTITION_V4:
        begin
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.v0);
          Inc(bx, hsz shr 1);
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.v4);
          Inc(bx, hsz shr 1);
          DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, EDGE_ALL_TOP_HAS_RIGHT);
          Inc(bx, hsz shr 1);
          if bx < Self.bw then DecodeBlock(Bl, BlockSizes[Bl][bp][0], bp, N^.v1);
          Dec(bx, (hsz * 3) shr 1);
        end;
    end;
  end
  else if haveH then
  begin
    isSplit := MsacDecodeBool(TS^.Msac, GatherTop);
    if isSplit <> 0 then
    begin
      bp := PARTITION_SPLIT;
      DecodeSb(Bl + 1, N^.split[0]);
      Inc(bx, hsz);
      DecodeSb(Bl + 1, N^.split[1]);
      Dec(bx, hsz);
    end
    else
    begin
      bp := PARTITION_H;
      DecodeBlock(Bl, BlockSizes[Bl][PARTITION_H][0], PARTITION_H, N^.h0);
    end;
  end
  else
  begin
    isSplit := MsacDecodeBool(TS^.Msac, GatherLeft);
    if (Layout = LAYOUT_I422) and (isSplit = 0) then
      raise EAv1.Create('AV1: invalid 4:2:2 partition');
    if isSplit <> 0 then
    begin
      bp := PARTITION_SPLIT;
      DecodeSb(Bl + 1, N^.split[0]);
      Inc(by, hsz);
      DecodeSb(Bl + 1, N^.split[2]);
      Dec(by, hsz);
    end
    else
    begin
      bp := PARTITION_V;
      DecodeBlock(Bl, BlockSizes[Bl][PARTITION_V][0], PARTITION_V, N^.v0);
    end;
  end;

  if (bp <> PARTITION_SPLIT) or (Bl = BL_8X8) then SetPartCtx;
end;

// ---------------------------------------------------------------- block

procedure TAv1Decoder.DecodeBlock(Bl, Bs, Bp, EdgeFlags: Integer);
var
  bw4, bh4, w4, h4, cbx4, cby4, cbw4, cbh4, cw4, ch4: Integer;
  haveLeft, haveTop, hasChroma: Boolean;
  segActive: Boolean;
  seg: ^TSegData;
  segPred, segCtx, predSegId, diff, lastActive, idx, v, i, x, y: Integer;
  smctx, sctx, prevQidx, deltaQ, nBits, nLfs, deltaLf, ictx: Integer;
  prevDeltaLf: array[0..3] of Integer;
  changedLf: Boolean;
  ymodeCdf: PWord;
  cflAllowed, sign, signU, signV, ctx, szCtx, palCtx, usePal, isFilter, tctx, depth: Integer;
  td: PTxDim;
  ymodeNoFilt: Integer;
  isComp, hasSubpel, dirCtx, ctx1, ctx2, ctx3, ctx4, nMvs, mvCtx, mvPrec: Integer;
  mvstack: TMvStack;
  im0, im1, iiSzGrp, wedgeCtx, maskCtx, isSegwedge, jntCtx: Integer;
  masks: array[0..1] of UInt64;
  allowWarp: Boolean;
  filter: array[0..1] of Integer;
  isGlobalmv: Boolean;
  tmpl: TRefmvsBlock;
  borderLeft, borderTop, borderRight, srcLeft, srcTop, srcRight, srcBottom, sbx, sbyy, sbSize: Integer;
  ytxL, uvtxL: Integer;
  split2: array[0..1] of Integer;
  noskipY: Integer;

  procedure AssignCompMv(n, Mode: Integer);
  begin
    case Mode of
      NEARMV, NEARESTMV:
        begin
          B.mv[n] := mvstack[B.drlIdx].mv.mv[n];
          FixMvPrecision(Fh, B.mv[n]);
        end;
      GLOBALMV:
        begin
          if Fh.Gmv[B.ref[n]].WmType = WM_TYPE_TRANSLATION then hasSubpel := 1;
          B.mv[n] := GetGmv2d(Fh.Gmv[B.ref[n]], bx, by, bw4, bh4, Fh);
        end;
      NEWMV:
        begin
          B.mv[n] := mvstack[B.drlIdx].mv.mv[n];
          ReadMvResidual(B.mv[n], Ord(Fh.Hp) - Fh.ForceIntegerMv, False);
        end;
    end;
  end;

  function FindOddZero(const Arr: array of Byte; From, Len: Integer): Boolean;
  var k: Integer;
  begin
    for k := 0 to Len - 1 do
      if Arr[From + k * 2] = 0 then Exit(True);
    Result := False;
  end;

  // env.h context helpers (absolute indices)
  function IntraCtx: Integer;
  begin
    if haveLeft then
    begin
      if haveTop then
      begin
        Result := L.intra[by] + A.intra[bx];
        Result := Result + Ord(Result = 2);
      end
      else Result := L.intra[by] * 2;
    end
    else if haveTop then Result := A.intra[bx] * 2
    else Result := 0;
  end;

  function CompCtx: Integer;
  begin
    if haveTop then
    begin
      if haveLeft then
      begin
        if A.comptype[bx] <> 0 then
        begin
          if L.comptype[by] <> 0 then Result := 4
          else Result := 2 + Ord(LongWord(Integer(L.ref0[by])) >= 4);
        end
        else if L.comptype[by] <> 0 then
          Result := 2 + Ord(LongWord(Integer(A.ref0[bx])) >= 4)
        else
          Result := Ord(L.ref0[by] >= 4) xor Ord(A.ref0[bx] >= 4);
      end
      else
      begin
        if A.comptype[bx] <> 0 then Result := 3 else Result := Ord(A.ref0[bx] >= 4);
      end;
    end
    else if haveLeft then
    begin
      if L.comptype[by] <> 0 then Result := 3 else Result := Ord(L.ref0[by] >= 4);
    end
    else Result := 1;
  end;

  function HasUniCompA: Boolean; begin Result := (A.ref0[bx] < 4) = (A.ref1[bx] < 4); end;
  function HasUniCompL: Boolean; begin Result := (L.ref0[by] < 4) = (L.ref1[by] < 4); end;

  function CompDirCtx: Integer;
  var aIntra, lIntra, aComp, lComp, aUni, lUni, eUni: Boolean; aRef0, lRef0, eComp: Integer;
  begin
    if haveTop and haveLeft then
    begin
      aIntra := A.intra[bx] <> 0; lIntra := L.intra[by] <> 0;
      if aIntra and lIntra then Exit(2);
      if aIntra or lIntra then
      begin
        if aIntra then begin eComp := L.comptype[by]; eUni := HasUniCompL; end
        else begin eComp := A.comptype[bx]; eUni := HasUniCompA; end;
        if eComp = COMP_INTER_NONE then Exit(2);
        Exit(1 + 2 * Ord(eUni));
      end;
      aComp := A.comptype[bx] <> COMP_INTER_NONE;
      lComp := L.comptype[by] <> COMP_INTER_NONE;
      aRef0 := A.ref0[bx]; lRef0 := L.ref0[by];
      if (not aComp) and (not lComp) then
        Exit(1 + 2 * Ord((aRef0 >= 4) = (lRef0 >= 4)))
      else if (not aComp) or (not lComp) then
      begin
        if aComp then eUni := HasUniCompA else eUni := HasUniCompL;
        if not eUni then Exit(1);
        Exit(3 + Ord((aRef0 >= 4) = (lRef0 >= 4)));
      end
      else
      begin
        aUni := HasUniCompA; lUni := HasUniCompL;
        if (not aUni) and (not lUni) then Exit(0);
        if (not aUni) or (not lUni) then Exit(2);
        Exit(3 + Ord((aRef0 = 4) = (lRef0 = 4)));
      end;
    end
    else if haveTop or haveLeft then
    begin
      if haveLeft then
      begin
        if L.intra[by] <> 0 then Exit(2);
        if L.comptype[by] = COMP_INTER_NONE then Exit(2);
        Exit(4 * Ord(HasUniCompL));
      end
      else
      begin
        if A.intra[bx] <> 0 then Exit(2);
        if A.comptype[bx] = COMP_INTER_NONE then Exit(2);
        Exit(4 * Ord(HasUniCompA));
      end;
    end
    else Result := 2;
  end;

  // counts references of the above / left neighbours (av1_get_*_ctx)
  procedure CountRefs(var Cnt: array of Integer; Kind: Integer);
    procedure AddOne(r: Integer);
    begin
      case Kind of
        0: Inc(Cnt[Ord(r >= 4)]);                                 // ref_ctx / uni_p
        1: if r < 4 then Inc(Cnt[r]);                             // fwd_ref
        2: if r < 2 then Inc(Cnt[r]);                             // fwd_ref_1
        3: if LongWord(r xor 2) < 2 then Inc(Cnt[r - 2]);         // fwd_ref_2 / uni_p2
        4: if r >= 4 then Inc(Cnt[r - 4]);                        // bwd_ref / bwd_ref_1
        5: if LongWord(r - 1) < 3 then Inc(Cnt[r - 1]);           // uni_p1
      end;
    end;
  begin
    if haveTop and (A.intra[bx] = 0) then
    begin
      AddOne(A.ref0[bx]);
      if A.comptype[bx] <> 0 then AddOne(A.ref1[bx]);
    end;
    if haveLeft and (L.intra[by] = 0) then
    begin
      AddOne(L.ref0[by]);
      if L.comptype[by] <> 0 then AddOne(L.ref1[by]);
    end;
  end;

  function Cmp3(c0, c1: Integer): Integer; inline;
  begin
    if c0 = c1 then Result := 1 else if c0 < c1 then Result := 0 else Result := 2;
  end;

  function RefCtx: Integer;       var c: array[0..1] of Integer;
  begin c[0] := 0; c[1] := 0; CountRefs(c, 0); Result := Cmp3(c[0], c[1]); end;
  function FwdRefCtx: Integer;    var c: array[0..3] of Integer;
  begin FillChar(c, SizeOf(c), 0); CountRefs(c, 1); Result := Cmp3(c[0] + c[1], c[2] + c[3]); end;
  function FwdRef1Ctx: Integer;   var c: array[0..1] of Integer;
  begin c[0] := 0; c[1] := 0; CountRefs(c, 2); Result := Cmp3(c[0], c[1]); end;
  function FwdRef2Ctx: Integer;   var c: array[0..1] of Integer;
  begin c[0] := 0; c[1] := 0; CountRefs(c, 3); Result := Cmp3(c[0], c[1]); end;
  function BwdRefCtx: Integer;    var c: array[0..2] of Integer;
  begin FillChar(c, SizeOf(c), 0); CountRefs(c, 4); Result := Cmp3(c[0] + c[1], c[2]); end;
  function BwdRef1Ctx: Integer;   var c: array[0..2] of Integer;
  begin FillChar(c, SizeOf(c), 0); CountRefs(c, 4); Result := Cmp3(c[0], c[1]); end;
  function UniP1Ctx: Integer;     var c: array[0..2] of Integer;
  begin FillChar(c, SizeOf(c), 0); CountRefs(c, 5); Result := Cmp3(c[0], c[1] + c[2]); end;

  function FilterCtx(Comp, Dir, Ref: Integer): Integer;
  var af, lf: Integer;
  begin
    if (A.ref0[bx] = Ref) or (A.ref1[bx] = Ref) then
    begin if Dir = 0 then af := A.filter0[bx] else af := A.filter1[bx]; end
    else af := N_SWITCHABLE_FILTERS;
    if (L.ref0[by] = Ref) or (L.ref1[by] = Ref) then
    begin if Dir = 0 then lf := L.filter0[by] else lf := L.filter1[by]; end
    else lf := N_SWITCHABLE_FILTERS;
    if af = lf then Result := Comp * 4 + af
    else if af = N_SWITCHABLE_FILTERS then Result := Comp * 4 + lf
    else if lf = N_SWITCHABLE_FILTERS then Result := Comp * 4 + af
    else Result := Comp * 4 + N_SWITCHABLE_FILTERS;
  end;

  function JntCompCtx: Integer;
  var d0, d1, offset, actx, lctx, poc, r0poc, r1poc: Integer;
  begin
    poc := Fh.FrameOffset;
    r0poc := Slots[Fh.RefIdx[B.ref[0]]].Pic.Hdr.FrameOffset;
    r1poc := Slots[Fh.RefIdx[B.ref[1]]].Pic.Hdr.FrameOffset;
    d0 := Abs(GetPocDiff(Seq.OrderHintNBits, r0poc, poc));
    d1 := Abs(GetPocDiff(Seq.OrderHintNBits, poc, r1poc));
    offset := Ord(d0 = d1);
    actx := Ord((A.comptype[bx] >= COMP_INTER_AVG) or (A.ref0[bx] = 6));
    lctx := Ord((L.comptype[by] >= COMP_INTER_AVG) or (L.ref0[by] = 6));
    Result := 3 * offset + actx + lctx;
  end;

  function MaskCompCtx: Integer;
  var actx, lctx: Integer;
  begin
    if A.comptype[bx] >= COMP_INTER_SEG then actx := 1
    else if A.ref0[bx] = 6 then actx := 3 else actx := 0;
    if L.comptype[by] >= COMP_INTER_SEG then lctx := 1
    else if L.ref0[by] = 6 then lctx := 3 else lctx := 0;
    Result := IMin(actx + lctx, 5);
  end;

  function PrevFrameSegId: Integer;
  var xx, yy, hh: Integer;
  begin
    Result := 8;
    yy := 0; hh := h4;
    repeat
      for xx := 0 to w4 - 1 do
        Result := IMin(Result, PrevSegMap[(by + yy) * b4Stride + bx + xx]);
      Inc(yy); Dec(hh);
    until (hh <= 0) or (Result = 0);
  end;

  function CurFrameSegId(out SegCtx: Integer): Integer;
  var base, ll, aa, al: Integer;
  begin
    base := by * b4Stride + bx;
    if haveLeft and haveTop then
    begin
      ll := CurSegMap[base - 1];
      aa := CurSegMap[base - b4Stride];
      al := CurSegMap[base - b4Stride - 1];
      if (ll = aa) and (al = ll) then SegCtx := 2
      else if (ll = aa) or (al = ll) or (aa = al) then SegCtx := 1
      else SegCtx := 0;
      if aa = al then Result := aa else Result := ll;
    end
    else
    begin
      SegCtx := 0;
      if haveLeft then Result := CurSegMap[base - 1]
      else if haveTop then Result := CurSegMap[base - b4Stride]
      else Result := 0;
    end;
  end;

  procedure SetEdge(var C: TCtxArrays; Off, Cnt: Integer; Intra, Skip, SkipMode, SegPred, Mode, PalSz,
    PalSzUv, TxIntra, TxV: Integer; SetTx: Boolean; CompType, F0, F1, R0, R1: Integer; SetInter: Boolean);
  begin
    SetBytes(C.intra, Off, Cnt, Intra);
    SetBytes(C.skip, Off, Cnt, Skip);
    SetBytes(C.skipmode, Off, Cnt, SkipMode);
    SetBytes(C.segpred, Off, Cnt, SegPred);
    SetBytes(C.mode, Off, Cnt, Mode);
    SetBytes(C.palsz, Off, Cnt, PalSz);
    SetBytes(C.palszuv, Off, Cnt, PalSzUv);
    SetShorts(C.txintra, Off, Cnt, TxIntra);
    if SetTx then SetShorts(C.tx, Off, Cnt, TxV);
    if SetInter then
    begin
      SetBytes(C.comptype, Off, Cnt, CompType);
      SetBytes(C.filter0, Off, Cnt, F0);
      SetBytes(C.filter1, Off, Cnt, F1);
      SetShorts(C.ref0, Off, Cnt, R0);
      SetShorts(C.ref1, Off, Cnt, R1);
    end;
  end;

begin
  bw4 := BlockDim[Bs][0]; bh4 := BlockDim[Bs][1];
  w4 := IMin(bw4, Self.bw - bx); h4 := IMin(bh4, Self.bh - by);
  cbx4 := bx shr ssH; cby4 := by shr ssV;
  cbw4 := (bw4 + ssH) shr ssH; cbh4 := (bh4 + ssV) shr ssV;
  cw4 := (w4 + ssH) shr ssH; ch4 := (h4 + ssV) shr ssV;
  haveLeft := bx > TS^.ColStart;
  haveTop := by > TS^.RowStart;
  hasChroma := (Layout <> LAYOUT_I400) and ((bw4 > ssH) or ((bx and 1) <> 0)) and
               ((bh4 > ssV) or ((by and 1) <> 0));

  FillChar(B, SizeOf(B), 0);
  B.bl := Bl; B.bp := Bp; B.bs := Bs;
  B.ref[0] := -1; B.ref[1] := -1;
  seg := nil;
  segPred := 0;

  // segment id (pre-skip)
  if Fh.Segmentation.Enabled then
  begin
    if not Fh.Segmentation.UpdateMap then
    begin
      if HavePrevSegMap then
      begin
        v := PrevFrameSegId;
        if v >= 8 then raise EAv1.Create('AV1: invalid segment id');
        B.segId := v;
      end
      else B.segId := 0;
      seg := @Fh.Segmentation.SegData.D[B.segId];
    end
    else if Fh.Segmentation.SegData.Preskip then
    begin
      if Fh.Segmentation.Temporal then
        segPred := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.seg_pred[A.segpred[bx] + L.segpred[by]][0]);
      if Fh.Segmentation.Temporal and (segPred <> 0) then
      begin
        if HavePrevSegMap then
        begin
          v := PrevFrameSegId;
          if v >= 8 then raise EAv1.Create('AV1: invalid segment id');
          B.segId := v;
        end
        else B.segId := 0;
      end
      else
      begin
        predSegId := CurFrameSegId(segCtx);
        diff := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.seg_id[segCtx][0], 7);
        lastActive := Fh.Segmentation.SegData.LastActiveSegId;
        B.segId := NegDeinterleave(diff, predSegId, lastActive + 1);
        if B.segId > lastActive then B.segId := 0;
        if B.segId >= 8 then B.segId := 0;
      end;
      seg := @Fh.Segmentation.SegData.D[B.segId];
    end;
  end;

  // skip_mode
  if ((seg = nil) or ((not seg^.GlobalMv) and (seg^.Ref = -1) and (not seg^.Skip))) and
     Fh.SkipModeEnabled and (IMin(bw4, bh4) > 1) then
  begin
    smctx := A.skipmode[bx] + L.skipmode[by];
    B.skipMode := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.skip_mode[smctx][0]);
  end;

  // skip
  if (B.skipMode <> 0) or ((seg <> nil) and seg^.Skip) then
    B.skip := 1
  else
  begin
    sctx := A.skip[bx] + L.skip[by];
    B.skip := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.skip[sctx][0]);
  end;

  // segment id (post-skip)
  if Fh.Segmentation.Enabled and Fh.Segmentation.UpdateMap and not Fh.Segmentation.SegData.Preskip then
  begin
    if (B.skip = 0) and Fh.Segmentation.Temporal then
      segPred := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.seg_pred[A.segpred[bx] + L.segpred[by]][0]);
    if (B.skip = 0) and Fh.Segmentation.Temporal and (segPred <> 0) then
    begin
      if HavePrevSegMap then
      begin
        v := PrevFrameSegId;
        if v >= 8 then raise EAv1.Create('AV1: invalid segment id');
        B.segId := v;
      end
      else B.segId := 0;
    end
    else
    begin
      predSegId := CurFrameSegId(segCtx);
      if B.skip <> 0 then B.segId := predSegId
      else
      begin
        diff := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.seg_id[segCtx][0], 7);
        lastActive := Fh.Segmentation.SegData.LastActiveSegId;
        B.segId := NegDeinterleave(diff, predSegId, lastActive + 1);
        if B.segId > lastActive then B.segId := 0;
      end;
      if B.segId >= 8 then B.segId := 0;
    end;
    seg := @Fh.Segmentation.SegData.D[B.segId];
  end;

  // cdef index
  if B.skip = 0 then
  begin
    idx := (by shr 4) * N64w + (bx shr 4);
    if CdefIdx[idx] = -1 then
    begin
      v := MsacDecodeBools(TS^.Msac, Fh.Cdef.NBits);
      CdefIdx[idx] := v;
      if (bw4 > 16) and ((bx shr 4) + 1 < N64w) then CdefIdx[idx + 1] := v;
      if (bh4 > 16) and ((by shr 4) + 1 < N64h) then CdefIdx[idx + N64w] := v;
      if (bw4 = 32) and (bh4 = 32) and ((bx shr 4) + 1 < N64w) and ((by shr 4) + 1 < N64h) then
        CdefIdx[idx + N64w + 1] := v;
    end;
  end;

  // delta q / lf (first block of each superblock)
  if ((bx or by) and (31 shr Ord(not Seq.Sb128))) = 0 then
  begin
    prevQidx := TS^.LastQidx;
    for i := 0 to 3 do prevDeltaLf[i] := TS^.LastDeltaLf[i];
    if Seq.Sb128 then i := BS_128x128 else i := BS_64x64;
    if Fh.DeltaQPresent and ((Bs <> i) or (B.skip = 0)) then
    begin
      deltaQ := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.delta_q[0], 3);
      if deltaQ = 3 then
      begin
        nBits := 1 + Integer(MsacDecodeBools(TS^.Msac, 3));
        deltaQ := Integer(MsacDecodeBools(TS^.Msac, nBits)) + 1 + (1 shl nBits);
      end;
      if deltaQ <> 0 then
      begin
        if MsacDecodeBoolEqui(TS^.Msac) <> 0 then deltaQ := -deltaQ;
        deltaQ := deltaQ * (1 shl Fh.DeltaQResLog2);
      end;
      TS^.LastQidx := IClip(TS^.LastQidx + deltaQ, 1, 255);
      if Fh.DeltaLfPresent then
      begin
        if Fh.DeltaLfMulti then
        begin
          if Layout <> LAYOUT_I400 then nLfs := 4 else nLfs := 2;
        end
        else nLfs := 1;
        for i := 0 to nLfs - 1 do
        begin
          deltaLf := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.delta_lf[i + Ord(Fh.DeltaLfMulti)][0], 3);
          if deltaLf = 3 then
          begin
            nBits := 1 + Integer(MsacDecodeBools(TS^.Msac, 3));
            deltaLf := Integer(MsacDecodeBools(TS^.Msac, nBits)) + 1 + (1 shl nBits);
          end;
          if deltaLf <> 0 then
          begin
            if MsacDecodeBoolEqui(TS^.Msac) <> 0 then deltaLf := -deltaLf;
            deltaLf := deltaLf * (1 shl Fh.DeltaLfResLog2);
          end;
          TS^.LastDeltaLf[i] := IClip(TS^.LastDeltaLf[i] + deltaLf, -63, 63);
        end;
      end;
    end;
    if TS^.LastQidx = Fh.Quant.Yac then TS^.Dq := FrameDq
    else if TS^.LastQidx <> prevQidx then InitQuantTables(TS^.LastQidx, TS^.Dq);
    changedLf := False;
    for i := 0 to 3 do if TS^.LastDeltaLf[i] <> prevDeltaLf[i] then changedLf := True;
    if (TS^.LastDeltaLf[0] = 0) and (TS^.LastDeltaLf[1] = 0) and (TS^.LastDeltaLf[2] = 0) and
       (TS^.LastDeltaLf[3] = 0) then
      TS^.LfLvl := FrameLfLvl
    else if changedLf then
      CalcLfValues(TS^.LfLvl, TS^.LastDeltaLf);
  end;

  // intra / inter
  if B.skipMode <> 0 then B.intra := 0
  else if IsInterOrSwitch(Fh) then
  begin
    if (seg <> nil) and ((seg^.Ref >= 0) or seg^.GlobalMv) then
      B.intra := Ord(seg^.Ref = 0)
    else
    begin
      ictx := IntraCtx;
      B.intra := 1 - MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.intra[ictx][0]);
    end;
  end
  else if Fh.AllowIntrabc then
    B.intra := 1 - MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.intrabc[0])
  else
    B.intra := 1;

  if B.intra <> 0 then
  begin
    // ---------------- intra block
    if IsInterOrSwitch(Fh) then ymodeCdf := @TS^.Cdf.m.y_mode[YmodeSizeContext[Bs]][0]
    else ymodeCdf := @TS^.Cdf.kfym[IntraModeContext[A.mode[bx]]][IntraModeContext[L.mode[by]]][0];
    B.ymode := MsacDecodeSymbolAdapt(TS^.Msac, ymodeCdf, N_INTRA_PRED_MODES - 1);
    if (BlockDim[Bs][2] + BlockDim[Bs][3] >= 2) and (B.ymode >= VERT_PRED) and (B.ymode <= VERT_LEFT_PRED) then
      B.yAngle := Integer(MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.angle_delta[B.ymode - VERT_PRED][0], 6)) - 3;
    if hasChroma then
    begin
      if Fh.Segmentation.Lossless[B.segId] then cflAllowed := Ord((cbw4 = 1) and (cbh4 = 1))
      else cflAllowed := Ord((CflAllowedMask and (1 shl Bs)) <> 0);
      B.uvmode := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.uv_mode[cflAllowed][B.ymode][0],
        N_UV_INTRA_PRED_MODES - 1 - (1 - cflAllowed));
      if B.uvmode = CFL_PRED then
      begin
        sign := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.cfl_sign[0], 7) + 1;
        signU := (sign * $56) shr 8; signV := sign - signU * 3;
        if signU <> 0 then
        begin
          ctx := Ord(signU = 2) * 3 + signV;
          B.cflAlpha[0] := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.cfl_alpha[ctx][0], 15) + 1;
          if signU = 1 then B.cflAlpha[0] := -B.cflAlpha[0];
        end;
        if signV <> 0 then
        begin
          ctx := Ord(signV = 2) * 3 + signU;
          B.cflAlpha[1] := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.cfl_alpha[ctx][0], 15) + 1;
          if signV = 1 then B.cflAlpha[1] := -B.cflAlpha[1];
        end;
      end
      else if (BlockDim[Bs][2] + BlockDim[Bs][3] >= 2) and (B.uvmode >= VERT_PRED) and (B.uvmode <= VERT_LEFT_PRED) then
        B.uvAngle := Integer(MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.angle_delta[B.uvmode - VERT_PRED][0], 6)) - 3;
    end;

    B.palSz[0] := 0; B.palSz[1] := 0;
    if (Fh.AllowScreenContentTools <> 0) and (IMax(bw4, bh4) <= 16) and (bw4 + bh4 >= 4) then
    begin
      szCtx := BlockDim[Bs][2] + BlockDim[Bs][3] - 2;
      if B.ymode = DC_PRED then
      begin
        palCtx := Ord(A.palsz[bx] > 0) + Ord(L.palsz[by] > 0);
        usePal := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.pal_y[szCtx][palCtx][0]);
        if usePal <> 0 then ReadPalPlane(0, szCtx, bx, by);
      end;
      if hasChroma and (B.uvmode = DC_PRED) then
      begin
        palCtx := Ord(B.palSz[0] > 0);
        usePal := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.pal_uv[palCtx][0]);
        if usePal <> 0 then ReadPalUv(szCtx, bx, by);
      end;
    end;

    if (B.ymode = DC_PRED) and (B.palSz[0] = 0) and (IMax(BlockDim[Bs][2], BlockDim[Bs][3]) <= 3) and
       Seq.FilterIntra then
    begin
      isFilter := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.use_filter_intra[Bs][0]);
      if isFilter <> 0 then
      begin
        B.ymode := FILTER_PRED;
        B.yAngle := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.filter_intra[0], 4);
      end;
    end;

    if B.palSz[0] <> 0 then ReadPalIndices(@PalIdxY[0], B.palSz[0], 0, w4, h4, bw4, bh4);
    if hasChroma and (B.palSz[1] <> 0) then ReadPalIndices(@PalIdxC[0], B.palSz[1], 1, cw4, ch4, cbw4, cbh4);

    if Fh.Segmentation.Lossless[B.segId] then
    begin
      B.tx := TX_4X4; B.uvtx := TX_4X4;
      td := @TxDims[TX_4X4];
    end
    else
    begin
      B.tx := MaxTxfmSizeForBs[Bs][0];
      B.uvtx := MaxTxfmSizeForBs[Bs][Layout];
      td := @TxDims[B.tx];
      if (Fh.TxfmMode = TX_SWITCHABLE) and (td^.max > TX_4X4) then
      begin
        tctx := Ord(L.txintra[by] >= td^.lh) + Ord(A.txintra[bx] >= td^.lw);
        depth := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.txsz[td^.max - 1][tctx][0], IMin(td^.max, 2));
        while depth > 0 do
        begin
          B.tx := td^.sub;
          td := @TxDims[B.tx];
          Dec(depth);
        end;
      end;
    end;

    ReconIntra(Bs, EdgeFlags);

    if (Fh.LoopFilter.LevelY[0] <> 0) or (Fh.LoopFilter.LevelY[1] <> 0) then
    begin
      FillLevels(TS^.LfLvl, B.segId, 0, 0, hasChroma);
      MaskEdgesIntra(Bs, B.tx, B.uvtx, hasChroma);
    end;

    if B.ymode = FILTER_PRED then ymodeNoFilt := DC_PRED else ymodeNoFilt := B.ymode;
    if hasChroma then i := B.palSz[1] else i := 0;
    SetEdge(A, bx, bw4, 1, B.skip, 0, segPred, ymodeNoFilt, B.palSz[0], i, td^.lw, td^.lw, True,
      COMP_INTER_NONE, N_SWITCHABLE_FILTERS, N_SWITCHABLE_FILTERS, -1, -1, IsInterOrSwitch(Fh));
    SetEdge(L, by, bh4, 1, B.skip, 0, segPred, ymodeNoFilt, B.palSz[0], i, td^.lh, td^.lh, True,
      COMP_INTER_NONE, N_SWITCHABLE_FILTERS, N_SWITCHABLE_FILTERS, -1, -1, IsInterOrSwitch(Fh));
    if B.palSz[0] <> 0 then
    begin
      for x := 0 to bw4 - 1 do Move(Pal[0][0], A.pal[bx + x][0][0], 16);
      for y := 0 to bh4 - 1 do Move(Pal[0][0], L.pal[by + y][0][0], 16);
    end;
    if hasChroma then
    begin
      SetBytes(A.uvmode, cbx4, cbw4, B.uvmode);
      SetBytes(L.uvmode, cby4, cbh4, B.uvmode);
      if B.palSz[1] <> 0 then
        for i := 1 to 2 do
        begin
          for x := 0 to bw4 - 1 do Move(Pal[i][0], A.pal[bx + x][i][0], 16);
          for y := 0 to bh4 - 1 do Move(Pal[i][0], L.pal[by + y][i][0], 16);
        end;
    end;
    if IsInterOrSwitch(Fh) or Fh.AllowIntrabc then
    begin
      FillChar(tmpl, SizeOf(tmpl), 0);
      tmpl.ref.ref[0] := 0; tmpl.ref.ref[1] := -1;
      tmpl.mv.mv[0].n := INVALID_MV;
      tmpl.bs := Bs; tmpl.mf := 0;
      RefmvsSplat(RF, tmpl, by, bx, bw4, bh4);
    end;
  end
  else if IsKeyOrIntra(Fh) then
  begin
    // ---------------- intra block copy
    RefmvsFind(RF, mvstack, nMvs, mvCtx, 0, -1, Bs, EdgeFlags, by, bx);
    if mvstack[0].mv.mv[0].n <> 0 then B.mv[0] := mvstack[0].mv.mv[0]
    else if mvstack[1].mv.mv[0].n <> 0 then B.mv[0] := mvstack[1].mv.mv[0]
    else
    begin
      if by - (16 shl Ord(Seq.Sb128)) < TS^.RowStart then
      begin
        B.mv[0].y := 0;
        B.mv[0].x := -(512 shl Ord(Seq.Sb128)) - 2048;
      end
      else
      begin
        B.mv[0].y := -(512 shl Ord(Seq.Sb128));
        B.mv[0].x := 0;
      end;
    end;
    ReadMvResidual(B.mv[0], -1, True);
    borderLeft := TS^.ColStart * 4;
    borderTop := TS^.RowStart * 4;
    if hasChroma then
    begin
      if (bw4 < 2) and (ssH <> 0) then Inc(borderLeft, 4);
      if (bh4 < 2) and (ssV <> 0) then Inc(borderTop, 4);
    end;
    srcLeft := bx * 4 + SarLongint(B.mv[0].x, 3);
    srcTop := by * 4 + SarLongint(B.mv[0].y, 3);
    srcRight := srcLeft + bw4 * 4;
    srcBottom := srcTop + bh4 * 4;
    borderRight := ((TS^.ColEnd + (bw4 - 1)) and not (bw4 - 1)) * 4;
    if srcLeft < borderLeft then
    begin
      Inc(srcRight, borderLeft - srcLeft); Inc(srcLeft, borderLeft - srcLeft);
    end
    else if srcRight > borderRight then
    begin
      Dec(srcLeft, srcRight - borderRight); Dec(srcRight, srcRight - borderRight);
    end;
    if srcTop < borderTop then
    begin
      Inc(srcBottom, borderTop - srcTop); Inc(srcTop, borderTop - srcTop);
    end;
    sbx := (bx shr (4 + Ord(Seq.Sb128))) shl (6 + Ord(Seq.Sb128));
    sbyy := (by shr (4 + Ord(Seq.Sb128))) shl (6 + Ord(Seq.Sb128));
    sbSize := 1 shl (6 + Ord(Seq.Sb128));
    if (srcBottom > sbyy) and (srcRight > sbx) then
    begin
      if srcTop - borderTop >= srcBottom - sbyy then
      begin
        Dec(srcTop, srcBottom - sbyy); Dec(srcBottom, srcBottom - sbyy);
      end
      else if srcLeft - borderLeft >= srcRight - sbx then
      begin
        Dec(srcLeft, srcRight - sbx); Dec(srcRight, srcRight - sbx);
      end;
    end;
    if srcBottom > sbyy + sbSize then
    begin
      Dec(srcTop, srcBottom - (sbyy + sbSize)); Dec(srcBottom, srcBottom - (sbyy + sbSize));
    end;
    if (srcBottom > sbyy) and (srcRight > sbx) then
      raise EAv1.Create('AV1: invalid intra block copy vector');
    B.mv[0].x := (srcLeft - bx * 4) * 8;
    B.mv[0].y := (srcTop - by * 4) * 8;
    ReadVartxTree(Bs);
    B.filter2d := FILTER_2D_BILINEAR;
    B.compType := COMP_INTER_NONE;
    ReconInter(Bs);
    FillChar(tmpl, SizeOf(tmpl), 0);
    tmpl.ref.ref[0] := 0; tmpl.ref.ref[1] := -1;
    tmpl.mv.mv[0] := B.mv[0];
    tmpl.bs := Bs; tmpl.mf := 0;
    RefmvsSplat(RF, tmpl, by, bx, bw4, bh4);
    SetEdge(A, bx, bw4, 0, B.skip, 0, segPred, DC_PRED, 0, 0, BlockDim[Bs][2], 0, False,
      0, 0, 0, 0, 0, False);
    SetEdge(L, by, bh4, 0, B.skip, 0, segPred, DC_PRED, 0, 0, BlockDim[Bs][3], 0, False,
      0, 0, 0, 0, 0, False);
    if hasChroma then
    begin
      SetBytes(A.uvmode, cbx4, cbw4, DC_PRED);
      SetBytes(L.uvmode, cby4, cbh4, DC_PRED);
    end;
    if (Fh.LoopFilter.LevelY[0] <> 0) or (Fh.LoopFilter.LevelY[1] <> 0) then
    begin
      FillLevels(TS^.LfLvl, B.segId, 0, 1, hasChroma);
      split2[0] := B.txSplit0; split2[1] := B.txSplit1;
      MaskEdgesInter(Bs, B.maxYtx, B.uvtx, split2, hasChroma);
    end;
  end
  else
  begin
    // ---------------- inter block
    if B.skipMode <> 0 then isComp := 1
    else if ((seg = nil) or ((seg^.Ref = -1) and (not seg^.GlobalMv) and (not seg^.Skip))) and
            Fh.SwitchableCompRefs and (IMin(bw4, bh4) > 1) then
      isComp := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.comp[CompCtx][0])
    else isComp := 0;

    hasSubpel := 0;
    if B.skipMode <> 0 then
    begin
      B.ref[0] := Fh.SkipModeRefs[0];
      B.ref[1] := Fh.SkipModeRefs[1];
      B.compType := COMP_INTER_AVG;
      B.interMode := NEARESTMV_NEARESTMV;
      B.drlIdx := NEAREST_DRL;
      RefmvsFind(RF, mvstack, nMvs, mvCtx, B.ref[0] + 1, B.ref[1] + 1, Bs, EdgeFlags, by, bx);
      B.mv[0] := mvstack[0].mv.mv[0];
      B.mv[1] := mvstack[0].mv.mv[1];
      FixMvPrecision(Fh, B.mv[0]);
      FixMvPrecision(Fh, B.mv[1]);
    end
    else if isComp <> 0 then
    begin
      dirCtx := CompDirCtx;
      if MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.comp_dir[dirCtx][0]) <> 0 then
      begin
        ctx1 := FwdRefCtx;
        if MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.comp_fwd_ref[0][ctx1][0]) <> 0 then
        begin
          ctx2 := FwdRef2Ctx;
          B.ref[0] := 2 + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.comp_fwd_ref[2][ctx2][0]));
        end
        else
        begin
          ctx2 := FwdRef1Ctx;
          B.ref[0] := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.comp_fwd_ref[1][ctx2][0]);
        end;
        ctx3 := BwdRefCtx;
        if MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.comp_bwd_ref[0][ctx3][0]) <> 0 then
          B.ref[1] := 6
        else
        begin
          ctx4 := BwdRef1Ctx;
          B.ref[1] := 4 + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.comp_bwd_ref[1][ctx4][0]));
        end;
      end
      else
      begin
        ctx1 := RefCtx;   // uni_p
        if MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.comp_uni_ref[0][ctx1][0]) <> 0 then
        begin
          B.ref[0] := 4; B.ref[1] := 6;
        end
        else
        begin
          ctx2 := UniP1Ctx;
          B.ref[0] := 0;
          B.ref[1] := 1 + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.comp_uni_ref[1][ctx2][0]));
          if B.ref[1] = 2 then
          begin
            ctx3 := FwdRef2Ctx;   // uni_p2
            B.ref[1] := B.ref[1] + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.comp_uni_ref[2][ctx3][0]));
          end;
        end;
      end;

      RefmvsFind(RF, mvstack, nMvs, mvCtx, B.ref[0] + 1, B.ref[1] + 1, Bs, EdgeFlags, by, bx);
      B.interMode := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.comp_inter_mode[mvCtx][0], 7);
      im0 := CompInterPredModes[B.interMode][0];
      im1 := CompInterPredModes[B.interMode][1];
      B.drlIdx := NEAREST_DRL;
      if B.interMode = NEWMV_NEWMV then
      begin
        if nMvs > 1 then
        begin
          B.drlIdx := B.drlIdx + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.drl_bit[GetDrlContext(mvstack, 0)][0]));
          if (B.drlIdx = NEARER_DRL) and (nMvs > 2) then
            B.drlIdx := B.drlIdx + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.drl_bit[GetDrlContext(mvstack, 1)][0]));
        end;
      end
      else if (im0 = NEARMV) or (im1 = NEARMV) then
      begin
        B.drlIdx := NEARER_DRL;
        if nMvs > 2 then
        begin
          B.drlIdx := B.drlIdx + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.drl_bit[GetDrlContext(mvstack, 1)][0]));
          if (B.drlIdx = NEAR_DRL) and (nMvs > 3) then
            B.drlIdx := B.drlIdx + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.drl_bit[GetDrlContext(mvstack, 2)][0]));
        end;
      end;
      hasSubpel := Ord((IMin(bw4, bh4) = 1) or (B.interMode <> GLOBALMV_GLOBALMV));
      AssignCompMv(0, im0);
      AssignCompMv(1, im1);

      isSegwedge := 0;
      if Seq.MaskedCompound then
      begin
        maskCtx := MaskCompCtx;
        isSegwedge := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.mask_comp[maskCtx][0]);
      end;
      if isSegwedge = 0 then
      begin
        if Seq.JntComp then
        begin
          jntCtx := JntCompCtx;
          B.compType := COMP_INTER_WEIGHTED_AVG +
            Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.jnt_comp[jntCtx][0]));
        end
        else B.compType := COMP_INTER_AVG;
      end
      else
      begin
        if (WedgeAllowedMask and (1 shl Bs)) <> 0 then
        begin
          ctx := WedgeCtxLut[Bs];
          B.compType := COMP_INTER_WEDGE -
            Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.wedge_comp[ctx][0]));
          if B.compType = COMP_INTER_WEDGE then
            B.wedgeIdx := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.wedge_idx[ctx][0], 15);
        end
        else B.compType := COMP_INTER_SEG;
        B.maskSign := MsacDecodeBoolEqui(TS^.Msac);
      end;
    end
    else
    begin
      B.compType := COMP_INTER_NONE;
      if (seg <> nil) and (seg^.Ref > 0) then B.ref[0] := seg^.Ref - 1
      else if (seg <> nil) and (seg^.GlobalMv or seg^.Skip) then B.ref[0] := 0
      else
      begin
        ctx1 := RefCtx;
        if MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.ref[0][ctx1][0]) <> 0 then
        begin
          ctx2 := BwdRefCtx;   // ref_2
          if MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.ref[1][ctx2][0]) <> 0 then B.ref[0] := 6
          else
          begin
            ctx3 := BwdRef1Ctx;   // ref_6
            B.ref[0] := 4 + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.ref[5][ctx3][0]));
          end;
        end
        else
        begin
          ctx2 := FwdRefCtx;   // ref_3
          if MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.ref[2][ctx2][0]) <> 0 then
          begin
            ctx3 := FwdRef2Ctx;   // ref_5
            B.ref[0] := 2 + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.ref[4][ctx3][0]));
          end
          else
          begin
            ctx3 := FwdRef1Ctx;   // ref_4
            B.ref[0] := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.ref[3][ctx3][0]);
          end;
        end;
      end;
      B.ref[1] := -1;

      RefmvsFind(RF, mvstack, nMvs, mvCtx, B.ref[0] + 1, -1, Bs, EdgeFlags, by, bx);

      if ((seg <> nil) and (seg^.Skip or seg^.GlobalMv)) or
         (MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.newmv_mode[mvCtx and 7][0]) <> 0) then
      begin
        if ((seg <> nil) and (seg^.Skip or seg^.GlobalMv)) or
           (MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.globalmv_mode[(mvCtx shr 3) and 1][0]) = 0) then
        begin
          B.interMode := GLOBALMV;
          B.mv[0] := GetGmv2d(Fh.Gmv[B.ref[0]], bx, by, bw4, bh4, Fh);
          hasSubpel := Ord((IMin(bw4, bh4) = 1) or (Fh.Gmv[B.ref[0]].WmType = WM_TYPE_TRANSLATION));
        end
        else
        begin
          hasSubpel := 1;
          if MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.refmv_mode[(mvCtx shr 4) and 15][0]) <> 0 then
          begin
            B.interMode := NEARMV;
            B.drlIdx := NEARER_DRL;
            if nMvs > 2 then
            begin
              B.drlIdx := B.drlIdx + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.drl_bit[GetDrlContext(mvstack, 1)][0]));
              if (B.drlIdx = NEAR_DRL) and (nMvs > 3) then
                B.drlIdx := B.drlIdx + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.drl_bit[GetDrlContext(mvstack, 2)][0]));
            end;
          end
          else
          begin
            B.interMode := NEARESTMV;
            B.drlIdx := NEAREST_DRL;
          end;
          B.mv[0] := mvstack[B.drlIdx].mv.mv[0];
          if B.drlIdx < NEAR_DRL then FixMvPrecision(Fh, B.mv[0]);
        end;
      end
      else
      begin
        hasSubpel := 1;
        B.interMode := NEWMV;
        B.drlIdx := NEAREST_DRL;
        if nMvs > 1 then
        begin
          B.drlIdx := B.drlIdx + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.drl_bit[GetDrlContext(mvstack, 0)][0]));
          if (B.drlIdx = NEARER_DRL) and (nMvs > 2) then
            B.drlIdx := B.drlIdx + Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.drl_bit[GetDrlContext(mvstack, 1)][0]));
        end;
        if nMvs > 1 then B.mv[0] := mvstack[B.drlIdx].mv.mv[0]
        else
        begin
          B.mv[0] := mvstack[0].mv.mv[0];
          FixMvPrecision(Fh, B.mv[0]);
        end;
        mvPrec := Ord(Fh.Hp) - Fh.ForceIntegerMv;
        ReadMvResidual(B.mv[0], mvPrec, False);
      end;

      // inter-intra
      iiSzGrp := YmodeSizeContext[Bs];
      if Seq.InterIntra and ((InterIntraAllowedMask and (1 shl Bs)) <> 0) and
         (MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.interintra[iiSzGrp][0]) <> 0) then
      begin
        B.interintraMode := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.interintra_mode[iiSzGrp][0], 3);
        wedgeCtx := WedgeCtxLut[Bs];
        B.interintraType := INTER_INTRA_BLEND +
          Integer(MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.interintra_wedge[wedgeCtx][0]));
        if B.interintraType = INTER_INTRA_WEDGE then
          B.wedgeIdx := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.wedge_idx[wedgeCtx][0], 15);
      end
      else B.interintraType := INTER_INTRA_NONE;

      // motion mode
      if Fh.SwitchableMotionMode and (B.interintraType = INTER_INTRA_NONE) and (IMin(bw4, bh4) >= 2) and
         not ((Fh.ForceIntegerMv = 0) and (B.interMode = GLOBALMV) and
              (Fh.Gmv[B.ref[0]].WmType > WM_TYPE_TRANSLATION)) and
         ((haveLeft and FindOddZero(L.intra, by + 1, h4 shr 1)) or
          (haveTop and FindOddZero(A.intra, bx + 1, w4 shr 1))) then
      begin
        masks[0] := 0; masks[1] := 0;
        FindMatchingRef(EdgeFlags, bw4, bh4, w4, h4, haveLeft, haveTop, B.ref[0], masks);
        allowWarp := (Fh.ForceIntegerMv = 0) and Fh.WarpMotion and ((masks[0] or masks[1]) <> 0);
        if allowWarp then
          B.motionMode := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.motion_mode[Bs][0], 2)
        else
          B.motionMode := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.obmc[Bs][0]);
        if B.motionMode = MM_WARP then
        begin
          hasSubpel := 0;
          DeriveWarpMv(bw4, bh4, masks, B.mv[0]);
        end;
      end
      else B.motionMode := MM_TRANSLATION;
    end;

    // subpel filter
    if Fh.SubpelFilterMode = FILTER_SWITCHABLE then
    begin
      if hasSubpel <> 0 then
      begin
        i := Ord(B.compType <> COMP_INTER_NONE);
        ctx1 := FilterCtx(i, 0, B.ref[0]);
        filter[0] := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.filter[0][ctx1][0], N_SWITCHABLE_FILTERS - 1);
        if Seq.DualFilter then
        begin
          ctx2 := FilterCtx(i, 1, B.ref[0]);
          filter[1] := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.filter[1][ctx2][0], N_SWITCHABLE_FILTERS - 1);
        end
        else filter[1] := filter[0];
      end
      else
      begin
        filter[0] := FILTER_8TAP_REGULAR; filter[1] := FILTER_8TAP_REGULAR;
      end;
    end
    else
    begin
      filter[0] := Fh.SubpelFilterMode; filter[1] := Fh.SubpelFilterMode;
    end;
    B.filter2d := Filter2dTab[filter[1]][filter[0]];

    ReadVartxTree(Bs);
    ReconInter(Bs);

    if (Fh.LoopFilter.LevelY[0] <> 0) or (Fh.LoopFilter.LevelY[1] <> 0) then
    begin
      if isComp <> 0 then isGlobalmv := B.interMode = GLOBALMV_GLOBALMV
      else isGlobalmv := B.interMode = GLOBALMV;
      FillLevels(TS^.LfLvl, B.segId, B.ref[0] + 1, Ord(not isGlobalmv), hasChroma);
      split2[0] := B.txSplit0; split2[1] := B.txSplit1;
      if Fh.Segmentation.Lossless[B.segId] then begin ytxL := TX_4X4; uvtxL := TX_4X4; end
      else begin ytxL := B.maxYtx; uvtxL := B.uvtx; end;
      MaskEdgesInter(Bs, ytxL, uvtxL, split2, hasChroma);
    end;

    // context updates
    FillChar(tmpl, SizeOf(tmpl), 0);
    tmpl.bs := Bs;
    if isComp <> 0 then
    begin
      tmpl.ref.ref[0] := B.ref[0] + 1; tmpl.ref.ref[1] := B.ref[1] + 1;
      tmpl.mv.mv[0] := B.mv[0]; tmpl.mv.mv[1] := B.mv[1];
      tmpl.mf := Ord(B.interMode = GLOBALMV_GLOBALMV) or
                 (Ord(((1 shl B.interMode) and $bc) <> 0) * 2);
    end
    else
    begin
      tmpl.ref.ref[0] := B.ref[0] + 1;
      if B.interintraType <> 0 then tmpl.ref.ref[1] := 0 else tmpl.ref.ref[1] := -1;
      tmpl.mv.mv[0] := B.mv[0];
      tmpl.mf := Ord((B.interMode = GLOBALMV) and (IMin(bw4, bh4) >= 2)) or
                 (Ord(B.interMode = NEWMV) * 2);
    end;
    RefmvsSplat(RF, tmpl, by, bx, bw4, bh4);

    SetEdge(A, bx, bw4, 0, B.skip, B.skipMode, segPred, B.interMode, 0, 0, BlockDim[Bs][2], 0, False,
      B.compType, filter[0], filter[1], B.ref[0], B.ref[1], True);
    SetEdge(L, by, bh4, 0, B.skip, B.skipMode, segPred, B.interMode, 0, 0, BlockDim[Bs][3], 0, False,
      B.compType, filter[0], filter[1], B.ref[0], B.ref[1], True);
    if hasChroma then
    begin
      SetBytes(A.uvmode, cbx4, cbw4, DC_PRED);
      SetBytes(L.uvmode, cby4, cbh4, DC_PRED);
    end;
  end;

  // segmentation map
  if Fh.Segmentation.Enabled and Fh.Segmentation.UpdateMap then
    for y := 0 to bh4 - 1 do
      FillChar(CurSegMap[(by + y) * b4Stride + bx], bw4, B.segId);

  // non-skip map for CDEF
  if B.skip = 0 then
    for y := 0 to bh4 - 1 do
    begin
      noskipY := (by + y) * b4Stride + bx;
      FillChar(NoskipMi[noskipY], bw4, 1);
    end;
end;
