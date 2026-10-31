// Av1.DecFilter.inc - in-loop filters: deblocking edge masks + filtering,
// CDEF, loop restoration, and the restoration-unit syntax. The CDEF / LR
// kernels are shared with the original still-image decoder (dav1d ports).
// Included by Av1.Decoder.

const
  RESTORE_NONE = 0; RESTORE_WIENER = 1; RESTORE_SGRPROJ = 2;
  CdefDir: array[0..11, 0..1, 0..1] of Integer = (
    ((1,0),(2,0)), ((1,0),(2,-1)), ((-1,1),(-2,2)), ((0,1),(-1,2)),
    ((0,1),(0,2)), ((0,1),(1,2)), ((1,1),(2,2)), ((1,0),(2,1)),
    ((1,0),(2,0)), ((1,0),(2,-1)), ((-1,1),(-2,2)), ((0,1),(-1,2)));
  CdefDivTable: array[0..6] of Integer = (840, 420, 280, 210, 168, 140, 120);
  SgrP0: array[0..15] of Boolean = (True,True,True,True,True,True,True,True,True,True,False,False,False,False,True,True);
  SgrP1: array[0..15] of Boolean = (True,True,True,True,True,True,True,True,True,True,True,True,True,True,False,False);

var
  SBd: Integer = 8;          // sample bit depth of the frame being filtered
  SPixMax: Integer = 255;
  SBdShift: Integer = 0;

function ClipQ(v: Integer): Integer; inline;
begin if v < 0 then Result := 0 else if v > SPixMax then Result := SPixMax else Result := v; end;

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

procedure TAv1Decoder.LrPlane(p: Integer; dstP, cdef, db: PWord; stride, w, h, bufH: Integer);
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


// ---------------------------------------------------------------- deblock masks

procedure TAv1Decoder.FillLevels(const Lv: TLfLvlTable; SegId, RefIdx, ModeIdx: Integer; HasChroma: Boolean);
var bw4, bh4, x, y, i, cbw4, cbh4, l0, l1: Integer;
begin
  bw4 := IMin(w4 - bx, BlockDim[B.bs][0]);
  bh4 := IMin(h4 - by, BlockDim[B.bs][1]);
  l0 := Lv[SegId][0][RefIdx][ModeIdx]; l1 := Lv[SegId][1][RefIdx][ModeIdx];
  for y := 0 to bh4 - 1 do
    for x := 0 to bw4 - 1 do
    begin
      i := ((by + y) * b4Stride + bx + x) * 2;
      LvlY[i] := l0; LvlY[i + 1] := l1;
    end;
  if not HasChroma then Exit;
  cbw4 := IMin(((w4 + ssH) shr ssH) - (bx shr ssH), (BlockDim[B.bs][0] + ssH) shr ssH);
  cbh4 := IMin(((h4 + ssV) shr ssV) - (by shr ssV), (BlockDim[B.bs][1] + ssV) shr ssV);
  l0 := Lv[SegId][2][RefIdx][ModeIdx]; l1 := Lv[SegId][3][RefIdx][ModeIdx];
  for y := 0 to cbh4 - 1 do
    for x := 0 to cbw4 - 1 do
    begin
      i := (((by shr ssV) + y) * b4Stride + (bx shr ssH) + x) * 2;
      LvlC[i] := l0; LvlC[i + 1] := l1;
    end;
end;

procedure TAv1Decoder.MaskEdgesIntra(Bs, Ytx, Uvtx: Integer; HasChroma: Boolean);
var
  bw4, bh4, x, y, twl4c, thl4c, hstep, vstep, cbw4, cbh4, cbx, cby, base: Integer;
  td: PTxDim;
begin
  bw4 := IMin(w4 - bx, BlockDim[Bs][0]);
  bh4 := IMin(h4 - by, BlockDim[Bs][1]);
  if (bw4 > 0) and (bh4 > 0) then
  begin
    td := @TxDims[Ytx];
    twl4c := IMin(2, td^.lw); thl4c := IMin(2, td^.lh);
    for y := 0 to bh4 - 1 do
      EdgeVY[(by + y) * b4Stride + bx] := 1 + IMin(twl4c, L.txlpfy[by + y]);
    for x := 0 to bw4 - 1 do
      EdgeHY[by * b4Stride + bx + x] := 1 + IMin(thl4c, A.txlpfy[bx + x]);
    hstep := td^.w;
    x := hstep;
    while x < bw4 do
    begin
      for y := 0 to bh4 - 1 do EdgeVY[(by + y) * b4Stride + bx + x] := 1 + twl4c;
      Inc(x, hstep);
    end;
    vstep := td^.h;
    y := vstep;
    while y < bh4 do
    begin
      base := (by + y) * b4Stride + bx;
      for x := 0 to bw4 - 1 do EdgeHY[base + x] := 1 + thl4c;
      Inc(y, vstep);
    end;
    SetBytes(A.txlpfy, bx, bw4, thl4c);
    SetBytes(L.txlpfy, by, bh4, twl4c);
  end;
  if not HasChroma then Exit;
  cbw4 := IMin(((w4 + ssH) shr ssH) - (bx shr ssH), (BlockDim[Bs][0] + ssH) shr ssH);
  cbh4 := IMin(((h4 + ssV) shr ssV) - (by shr ssV), (BlockDim[Bs][1] + ssV) shr ssV);
  if (cbw4 <= 0) or (cbh4 <= 0) then Exit;
  cbx := bx shr ssH; cby := by shr ssV;
  td := @TxDims[Uvtx];
  twl4c := Ord(td^.lw <> 0); thl4c := Ord(td^.lh <> 0);
  for y := 0 to cbh4 - 1 do
    EdgeVC[(cby + y) * b4Stride + cbx] := 1 + IMin(twl4c, L.txlpfuv[cby + y]);
  for x := 0 to cbw4 - 1 do
    EdgeHC[cby * b4Stride + cbx + x] := 1 + IMin(thl4c, A.txlpfuv[cbx + x]);
  hstep := td^.w;
  x := hstep;
  while x < cbw4 do
  begin
    for y := 0 to cbh4 - 1 do EdgeVC[(cby + y) * b4Stride + cbx + x] := 1 + twl4c;
    Inc(x, hstep);
  end;
  vstep := td^.h;
  y := vstep;
  while y < cbh4 do
  begin
    base := (cby + y) * b4Stride + cbx;
    for x := 0 to cbw4 - 1 do EdgeHC[base + x] := 1 + thl4c;
    Inc(y, vstep);
  end;
  SetBytes(A.txlpfuv, cbx, cbw4, thl4c);
  SetBytes(L.txlpfuv, cby, cbh4, twl4c);
end;

type
  TTxa = record
    lw, lh, stepW, stepH: array[0..31, 0..31] of Byte;   // [y][x]
  end;

procedure DecompTx(var T: TTxa; From, Depth, YOff, XOff, Y0, X0: Integer; const TxMasks: array of Integer);
var td: PTxDim; isSplit, sub, htw4, hth4, lw, lh, y, x: Integer;
begin
  td := @TxDims[From];
  if (From = TX_4X4) or (Depth > 1) then isSplit := 0
  else isSplit := (TxMasks[Depth] shr (YOff * 4 + XOff)) and 1;
  if isSplit <> 0 then
  begin
    sub := td^.sub;
    htw4 := td^.w shr 1; hth4 := td^.h shr 1;
    DecompTx(T, sub, Depth + 1, YOff * 2 + 0, XOff * 2 + 0, Y0, X0, TxMasks);
    if td^.w >= td^.h then
      DecompTx(T, sub, Depth + 1, YOff * 2 + 0, XOff * 2 + 1, Y0, X0 + htw4, TxMasks);
    if td^.h >= td^.w then
    begin
      DecompTx(T, sub, Depth + 1, YOff * 2 + 1, XOff * 2 + 0, Y0 + hth4, X0, TxMasks);
      if td^.w >= td^.h then
        DecompTx(T, sub, Depth + 1, YOff * 2 + 1, XOff * 2 + 1, Y0 + hth4, X0 + htw4, TxMasks);
    end;
  end
  else
  begin
    lw := IMin(2, td^.lw); lh := IMin(2, td^.lh);
    for y := 0 to td^.h - 1 do
    begin
      if Y0 + y > 31 then Break;
      for x := 0 to td^.w - 1 do
        if X0 + x <= 31 then
        begin
          T.lw[Y0 + y][X0 + x] := lw;
          T.lh[Y0 + y][X0 + x] := lh;
        end;
      T.stepW[Y0 + y][X0] := td^.w;
    end;
    for x := 0 to td^.w - 1 do
      if X0 + x <= 31 then T.stepH[Y0][X0 + x] := td^.h;
  end;
end;

procedure TAv1Decoder.MaskEdgesInter(Bs, MaxYtx, Uvtx: Integer; const TxSplit: array of Integer;
  HasChroma: Boolean);
var
  bw4, bh4, x, y, xOff, yOff, ltx, rtx, ttx, btx, step, cbw4, cbh4, cbx, cby, twl4c, thl4c,
  hstep, vstep, base: Integer;
  td: PTxDim;
  T: ^TTxa;
  skipInter: Boolean;
begin
  skipInter := B.skip <> 0;
  bw4 := IMin(w4 - bx, BlockDim[Bs][0]);
  bh4 := IMin(h4 - by, BlockDim[Bs][1]);
  if (bw4 > 0) and (bh4 > 0) then
  begin
    New(T);
    try
      td := @TxDims[MaxYtx];
      y := 0; yOff := 0;
      while y < bh4 do
      begin
        x := 0; xOff := 0;
        while x < bw4 do
        begin
          DecompTx(T^, MaxYtx, 0, yOff, xOff, y, x, TxSplit);
          Inc(x, td^.w); Inc(xOff);
        end;
        Inc(y, td^.h); Inc(yOff);
      end;
      for y := 0 to bh4 - 1 do
        EdgeVY[(by + y) * b4Stride + bx] := 1 + IMin(T^.lw[y][0], L.txlpfy[by + y]);
      for x := 0 to bw4 - 1 do
        EdgeHY[by * b4Stride + bx + x] := 1 + IMin(T^.lh[0][x], A.txlpfy[bx + x]);
      if not skipInter then
      begin
        for y := 0 to bh4 - 1 do
        begin
          ltx := T^.lw[y][0];
          step := T^.stepW[y][0];
          x := step;
          while x < bw4 do
          begin
            rtx := T^.lw[y][x];
            EdgeVY[(by + y) * b4Stride + bx + x] := 1 + IMin(rtx, ltx);
            ltx := rtx;
            step := T^.stepW[y][x];
            Inc(x, step);
          end;
        end;
        for x := 0 to bw4 - 1 do
        begin
          ttx := T^.lh[0][x];
          step := T^.stepH[0][x];
          y := step;
          while y < bh4 do
          begin
            btx := T^.lh[y][x];
            EdgeHY[(by + y) * b4Stride + bx + x] := 1 + IMin(ttx, btx);
            ttx := btx;
            step := T^.stepH[y][x];
            Inc(y, step);
          end;
        end;
      end;
      for y := 0 to bh4 - 1 do L.txlpfy[by + y] := T^.lw[y][bw4 - 1];
      for x := 0 to bw4 - 1 do A.txlpfy[bx + x] := T^.lh[bh4 - 1][x];
    finally
      Dispose(T);
    end;
  end;
  if not HasChroma then Exit;
  cbw4 := IMin(((w4 + ssH) shr ssH) - (bx shr ssH), (BlockDim[Bs][0] + ssH) shr ssH);
  cbh4 := IMin(((h4 + ssV) shr ssV) - (by shr ssV), (BlockDim[Bs][1] + ssV) shr ssV);
  if (cbw4 <= 0) or (cbh4 <= 0) then Exit;
  cbx := bx shr ssH; cby := by shr ssV;
  td := @TxDims[Uvtx];
  twl4c := Ord(td^.lw <> 0); thl4c := Ord(td^.lh <> 0);
  for y := 0 to cbh4 - 1 do
    EdgeVC[(cby + y) * b4Stride + cbx] := 1 + IMin(twl4c, L.txlpfuv[cby + y]);
  for x := 0 to cbw4 - 1 do
    EdgeHC[cby * b4Stride + cbx + x] := 1 + IMin(thl4c, A.txlpfuv[cbx + x]);
  if not skipInter then
  begin
    hstep := td^.w;
    x := hstep;
    while x < cbw4 do
    begin
      for y := 0 to cbh4 - 1 do EdgeVC[(cby + y) * b4Stride + cbx + x] := 1 + twl4c;
      Inc(x, hstep);
    end;
    vstep := td^.h;
    y := vstep;
    while y < cbh4 do
    begin
      base := (cby + y) * b4Stride + cbx;
      for x := 0 to cbw4 - 1 do EdgeHC[base + x] := 1 + thl4c;
      Inc(y, vstep);
    end;
  end;
  SetBytes(A.txlpfuv, cbx, cbw4, thl4c);
  SetBytes(L.txlpfuv, cby, cbh4, twl4c);
end;

procedure TAv1Decoder.DeblockFrame;
var lut: TLfLut; cw4, ch4: Integer;

  procedure DoCols(P: PWord; Stride: Integer; Lv, Ev: PByte; Gw, Gh, LvOff: Integer; Chroma: Boolean);
  var x4, y4, b4, Lvl, e, wd: Integer;
  begin
    for y4 := 0 to Gh - 1 do
      for x4 := 1 to Gw - 1 do
      begin
        b4 := y4 * b4Stride + x4;
        e := Ev[b4];
        if e = 0 then Continue;
        Lvl := Lv[b4 * 2 + LvOff]; if Lvl = 0 then Lvl := Lv[(b4 - 1) * 2 + LvOff];
        if Lvl = 0 then Continue;
        if Chroma then wd := 4 + 2 * (e - 1) else wd := 4 shl (e - 1);
        LfEdge(@P[y4 * 4 * Stride + x4 * 4], lut.e[Lvl] shl SBdShift, lut.i[Lvl] shl SBdShift,
          (Lvl shr 4) shl SBdShift, Stride, 1, wd);
      end;
  end;

  procedure DoRows(P: PWord; Stride: Integer; Lv, Eh: PByte; Gw, Gh, LvOff: Integer; Chroma: Boolean);
  var x4, y4, b4, Lvl, e, wd: Integer;
  begin
    for y4 := 1 to Gh - 1 do
      for x4 := 0 to Gw - 1 do
      begin
        b4 := y4 * b4Stride + x4;
        e := Eh[b4];
        if e = 0 then Continue;
        Lvl := Lv[b4 * 2 + LvOff]; if Lvl = 0 then Lvl := Lv[(b4 - b4Stride) * 2 + LvOff];
        if Lvl = 0 then Continue;
        if Chroma then wd := 4 + 2 * (e - 1) else wd := 4 shl (e - 1);
        LfEdge(@P[y4 * 4 * Stride + x4 * 4], lut.e[Lvl] shl SBdShift, lut.i[Lvl] shl SBdShift,
          (Lvl shr 4) shl SBdShift, 1, Stride, wd);
      end;
  end;

begin
  SBd := Bd; SPixMax := PixMax; SBdShift := Bd - 8;
  if (Fh.LoopFilter.LevelY[0] = 0) and (Fh.LoopFilter.LevelY[1] = 0) then Exit;
  CalcEih(lut, Fh.LoopFilter.Sharpness);
  cw4 := (w4 + ssH) shr ssH; ch4 := (h4 + ssV) shr ssV;
  DoCols(@Yp[0], StrideY, @LvlY[0], @EdgeVY[0], w4, h4, 0, False);
  if (NumPlanes = 3) and ((Fh.LoopFilter.LevelU <> 0) or (Fh.LoopFilter.LevelV <> 0)) then
  begin
    DoCols(@Up[0], StrideC, @LvlC[0], @EdgeVC[0], cw4, ch4, 0, True);
    DoCols(@Vp[0], StrideC, @LvlC[0], @EdgeVC[0], cw4, ch4, 1, True);
  end;
  DoRows(@Yp[0], StrideY, @LvlY[0], @EdgeHY[0], w4, h4, 1, False);
  if (NumPlanes = 3) and ((Fh.LoopFilter.LevelU <> 0) or (Fh.LoopFilter.LevelV <> 0)) then
  begin
    DoRows(@Up[0], StrideC, @LvlC[0], @EdgeHC[0], cw4, ch4, 0, True);
    DoRows(@Vp[0], StrideC, @LvlC[0], @EdgeHC[0], cw4, ch4, 1, True);
  end;
end;

// ---------------------------------------------------------------- CDEF

procedure TAv1Decoder.CdefFrame;
var
  UvDirT: array[0..7] of Integer;
  bxx, byy, ci, damping, edges, yLvl, uvLvl, yPri, ySec, uvPri, uvSec: Integer;
  dir, uvdir, adjPri, cpx, cpy, cw, ch: Integer; vari: LongWord;
  anyStr: Boolean;

  function NoSkip(X, Y: Integer): Boolean; inline;
  begin Result := (X < Self.bw) and (Y < Self.bh) and (NoskipMi[Y * b4Stride + X] <> 0); end;

begin
  SBd := Bd; SPixMax := PixMax; SBdShift := Bd - 8;
  // pre-CDEF (deblocked) copies: CDEF and loop-restoration stripe edges read them
  SetLength(YpPre, Length(Yp)); Move(Yp[0], YpPre[0], Length(Yp) * 2);
  if NumPlanes = 3 then
  begin
    SetLength(UpPre, Length(Up)); Move(Up[0], UpPre[0], Length(Up) * 2);
    SetLength(VpPre, Length(Vp)); Move(Vp[0], VpPre[0], Length(Vp) * 2);
  end;
  if not Seq.Cdef then Exit;
  anyStr := False;
  for ci := 0 to (1 shl Fh.Cdef.NBits) - 1 do
    if (Fh.Cdef.YStrength[ci] <> 0) or (Fh.Cdef.UvStrength[ci] <> 0) then anyStr := True;
  if not anyStr then Exit;
  damping := Fh.Cdef.Damping + SBdShift;
  if (ssH = 1) and (ssV = 0) then
  begin UvDirT[0]:=7; UvDirT[1]:=0; UvDirT[2]:=2; UvDirT[3]:=4; UvDirT[4]:=5; UvDirT[5]:=6; UvDirT[6]:=6; UvDirT[7]:=6; end
  else for dir := 0 to 7 do UvDirT[dir] := dir;
  byy := 0;
  while byy < Self.bh do
  begin
    bxx := 0;
    while bxx < Self.bw do
    begin
      ci := CdefIdx[(byy shr 4) * N64w + (bxx shr 4)];
      if ci = -1 then begin Inc(bxx, 2); Continue; end;
      yLvl := Fh.Cdef.YStrength[ci];
      uvLvl := Fh.Cdef.UvStrength[ci];
      if (yLvl = 0) and (uvLvl = 0) then begin Inc(bxx, 2); Continue; end;
      if not (NoSkip(bxx, byy) or NoSkip(bxx + 1, byy) or NoSkip(bxx, byy + 1) or NoSkip(bxx + 1, byy + 1)) then
      begin Inc(bxx, 2); Continue; end;

      edges := 0;
      if bxx > 0 then edges := edges or CD_LEFT;
      if bxx + 2 < Self.bw then edges := edges or CD_RIGHT;
      if byy > 0 then edges := edges or CD_TOP;
      if byy + 2 < Self.bh then edges := edges or CD_BOTTOM;

      yPri := (yLvl shr 2) shl SBdShift;
      ySec := yLvl and 3; if ySec = 3 then ySec := 4; ySec := ySec shl SBdShift;
      uvPri := (uvLvl shr 2) shl SBdShift;
      uvSec := uvLvl and 3; if uvSec = 3 then uvSec := 4; uvSec := uvSec shl SBdShift;
      dir := 0; vari := 0;
      if (yPri <> 0) or (uvPri <> 0) then dir := CdefFindDir(@YpPre[0], StrideY, bxx * 4, byy * 4, vari);
      if yPri <> 0 then
      begin
        adjPri := AdjustStrength(yPri, vari);
        if (adjPri <> 0) or (ySec <> 0) then
          CdefFilterBlock(@Yp[0], @YpPre[0], StrideY, bxx * 4, byy * 4, 8, 8, adjPri, ySec, dir, damping, edges);
      end
      else if ySec <> 0 then
        CdefFilterBlock(@Yp[0], @YpPre[0], StrideY, bxx * 4, byy * 4, 8, 8, 0, ySec, 0, damping, edges);
      if (uvLvl <> 0) and (NumPlanes = 3) then
      begin
        if uvPri <> 0 then uvdir := UvDirT[dir] else uvdir := 0;
        cpx := (bxx * 4) shr ssH; cpy := (byy * 4) shr ssV;
        cw := 8 shr ssH; ch := 8 shr ssV;
        CdefFilterBlock(@Up[0], @UpPre[0], StrideC, cpx, cpy, cw, ch, uvPri, uvSec, uvdir, damping - 1, edges);
        CdefFilterBlock(@Vp[0], @VpPre[0], StrideC, cpx, cpy, cw, ch, uvPri, uvSec, uvdir, damping - 1, edges);
      end;
      Inc(bxx, 2);
    end;
    Inc(byy, 2);
  end;
end;

// ---------------------------------------------------------------- loop restoration

procedure TAv1Decoder.LrFrame;
var cw, chh: Integer; usesLr: Boolean;
begin
  SBd := Bd; SPixMax := PixMax; SBdShift := Bd - 8;
  usesLr := (Fh.Restoration.LrType[0] <> 0) or (Fh.Restoration.LrType[1] <> 0) or (Fh.Restoration.LrType[2] <> 0);
  if not usesLr then Exit;
  SetLength(YpCdefC, Length(Yp)); Move(Yp[0], YpCdefC[0], Length(Yp) * 2);
  SetLength(YpDbC, Length(YpPre)); if Length(YpPre) > 0 then Move(YpPre[0], YpDbC[0], Length(YpPre) * 2);
  if Fh.Restoration.LrType[0] <> 0 then
    LrPlane(0, @Yp[0], @YpCdefC[0], @YpDbC[0], StrideY, FrmW, FrmH, Self.bh * 4);
  if NumPlanes = 3 then
  begin
    cw := (FrmW + ssH) shr ssH; chh := (FrmH + ssV) shr ssV;
    SetLength(UpCdefC, Length(Up)); Move(Up[0], UpCdefC[0], Length(Up) * 2);
    SetLength(VpCdefC, Length(Vp)); Move(Vp[0], VpCdefC[0], Length(Vp) * 2);
    SetLength(UpDbC, Length(UpPre)); if Length(UpPre) > 0 then Move(UpPre[0], UpDbC[0], Length(UpPre) * 2);
    SetLength(VpDbC, Length(VpPre)); if Length(VpPre) > 0 then Move(VpPre[0], VpDbC[0], Length(VpPre) * 2);
    if Fh.Restoration.LrType[1] <> 0 then
      LrPlane(1, @Up[0], @UpCdefC[0], @UpDbC[0], StrideC, cw, chh, (Self.bh * 4) shr ssV);
    if Fh.Restoration.LrType[2] <> 0 then
      LrPlane(2, @Vp[0], @VpCdefC[0], @VpDbC[0], StrideC, cw, chh, (Self.bh * 4) shr ssV);
  end;
end;

procedure TAv1Decoder.ReadRestorationInfo(P, FrameType, Ux, Uy: Integer);
var lrType, filt, tt, idx, gi: Integer; R: ^TLrUnit;
begin
  R := @TS^.LrRef[P];
  idx := 0;
  if FrameType = RESTORATION_SWITCHABLE then
  begin
    filt := MsacDecodeSymbolAdapt(TS^.Msac, @TS^.Cdf.m.restore_switchable[0], 2);
    if filt = 0 then lrType := RESTORE_NONE
    else if filt = 2 then lrType := RESTORE_SGRPROJ
    else lrType := RESTORE_WIENER;
  end
  else
  begin
    if FrameType = RESTORATION_WIENER then tt := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.restore_wiener[0])
    else tt := MsacDecodeBoolAdapt(TS^.Msac, @TS^.Cdf.m.restore_sgrproj[0]);
    if tt = 0 then lrType := RESTORE_NONE
    else if FrameType = RESTORATION_WIENER then lrType := RESTORE_WIENER
    else lrType := RESTORE_SGRPROJ;
  end;
  if lrType = RESTORE_WIENER then
  begin
    if P = 0 then R^.fv[0] := MsacDecodeSubexp(TS^.Msac, R^.fv[0] + 5, 16, 1) - 5 else R^.fv[0] := 0;
    R^.fv[1] := MsacDecodeSubexp(TS^.Msac, R^.fv[1] + 23, 32, 2) - 23;
    R^.fv[2] := MsacDecodeSubexp(TS^.Msac, R^.fv[2] + 17, 64, 3) - 17;
    if P = 0 then R^.fh[0] := MsacDecodeSubexp(TS^.Msac, R^.fh[0] + 5, 16, 1) - 5 else R^.fh[0] := 0;
    R^.fh[1] := MsacDecodeSubexp(TS^.Msac, R^.fh[1] + 23, 32, 2) - 23;
    R^.fh[2] := MsacDecodeSubexp(TS^.Msac, R^.fh[2] + 17, 64, 3) - 17;
  end
  else if lrType = RESTORE_SGRPROJ then
  begin
    idx := MsacDecodeBools(TS^.Msac, 4);
    if SgrP0[idx] then R^.sw[0] := MsacDecodeSubexp(TS^.Msac, R^.sw[0] + 96, 128, 4) - 96 else R^.sw[0] := 0;
    if SgrP1[idx] then R^.sw[1] := MsacDecodeSubexp(TS^.Msac, R^.sw[1] + 32, 128, 4) - 32 else R^.sw[1] := 95;
  end;
  gi := Uy * LrUnitsW[P] + Ux;
  if (gi >= 0) and (gi < Length(LrGrid[P])) then
  begin
    LrGrid[P][gi].typ := lrType;
    if lrType <> RESTORE_NONE then
    begin
      LrGrid[P][gi].fv := R^.fv; LrGrid[P][gi].fh := R^.fh; LrGrid[P][gi].sw := R^.sw;
      LrGrid[P][gi].sgrIdx := idx;
    end;
  end;
end;

procedure TAv1Decoder.ReadLrSb;
var p, plSv, plSh, ulog2, usz, mask, halfU, y, h, x, w: Integer;
begin
  for p := 0 to 2 do
  begin
    if Fh.Restoration.LrType[p] = RESTORATION_NONE then Continue;
    if (p > 0) and (NumPlanes < 3) then Continue;
    plSv := 0; plSh := 0;
    if p <> 0 then begin plSv := ssV; plSh := ssH; end;
    ulog2 := LrUnitLog2[p];
    usz := 1 shl ulog2;
    mask := usz - 1; halfU := usz shr 1;
    y := (by * 4) shr plSv; h := (FrmH + plSv) shr plSv;
    if (y and mask) <> 0 then Continue;
    if (y <> 0) and (y + halfU > h) then Continue;
    x := (4 * bx) shr plSh;
    if (x and mask) <> 0 then Continue;
    w := (FrmW + plSh) shr plSh;
    if (x <> 0) and (x + halfU > w) then Continue;
    ReadRestorationInfo(p, Fh.Restoration.LrType[p], x shr ulog2, y shr ulog2);
  end;
end;
