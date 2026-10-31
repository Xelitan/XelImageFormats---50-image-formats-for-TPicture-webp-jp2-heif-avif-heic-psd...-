unit Av1.Refmvs;

// AV1 motion vector prediction: spatial / temporal candidate list ("ref MV
// stack") construction, temporal MV projection (load_tmvs) and saving the
// current frame's MVs for later frames (save_tmvs).
//
// Port of dav1d src/refmvs.c (BSD-2-Clause). dav1d keeps a 35-row ring buffer
// of per-4x4 block info; here a full-frame array is used, which is equivalent
// because every access is bounded by the current tile / superblock row.

{$mode delphi}{$H+}
{$RANGECHECKS OFF}{$OVERFLOWCHECKS OFF}{$POINTERMATH ON}

interface

uses Av1.Tables, Av1.Headers, Av1.Mc;

type
  TMv = packed record
    case Integer of
      0: (y, x: SmallInt);
      1: (n: LongWord);
  end;
  PMv = ^TMv;

  TMvPair = packed record
    case Integer of
      0: (mv: array[0..1] of TMv);
      1: (n: UInt64);
  end;

  TRefPair = packed record
    case Integer of
      0: (ref: array[0..1] of ShortInt);
      1: (pair: Word);
  end;

  TRefmvsBlock = packed record
    mv: TMvPair;
    ref: TRefPair;
    bs, mf: Byte;    // mf: 1 = globalmv+affine, 2 = newmv
  end;
  PRefmvsBlock = ^TRefmvsBlock;

  TRefmvsTemporal = packed record
    mv: TMv;
    ref: Byte;
  end;
  PRefmvsTemporal = ^TRefmvsTemporal;
  TTemporalArr = array of TRefmvsTemporal;

  TRefmvsCandidate = record
    mv: TMvPair;
    weight: Integer;
  end;
  TMvStack = array[0..8] of TRefmvsCandidate;

  TRefmvsFrame = record
    Frm: PFrameHdr;
    Seq: PSeqHdr;
    iw4, ih4, iw8, ih8, sbsz: Integer;
    UseRefFrameMvs: Boolean;
    SignBias, MfmvSign: array[0..6] of Byte;
    PocDiff: array[0..6] of Integer;
    MfmvRef: array[0..2] of Integer;
    MfmvRef2Cur: array[0..2] of Integer;
    MfmvRef2Ref: array[0..2, 0..6] of Integer;
    NMfmvs: Integer;
    Rp: PRefmvsTemporal;                     // current frame's saved tmvs
    RpRef: array[0..6] of PRefmvsTemporal;   // reference frames' tmvs (nil = none)
    RpProj: array of TRefmvsTemporal;        // 16-row ring
    RpStride: Integer;
    R: array of TRefmvsBlock;                // full frame, per 4x4
    RStride: Integer;
    TileColStart, TileColEnd, TileRowStart, TileRowEnd: Integer;
  end;

const
  INVALID_REF2CUR = -32;

procedure RefmvsInitFrame(var RF: TRefmvsFrame; const Seq: TSeqHdr; const Frm: TFrameHdr;
  const RefPoc: array of Integer; Rp: PRefmvsTemporal;
  const RefRefPoc: array of Integer {7x7}; const RpRef: array of PRefmvsTemporal);
procedure RefmvsTileInit(var RF: TRefmvsFrame; ColStart4, ColEnd4, RowStart4, RowEnd4: Integer);
procedure RefmvsFind(var RF: TRefmvsFrame; var MvStack: TMvStack; out Cnt, Ctx: Integer;
  Ref0, Ref1: Integer; Bs, EdgeFlags, By4, Bx4: Integer);
procedure RefmvsLoadTmvs(var RF: TRefmvsFrame; ColStart8, ColEnd8, RowStart8, RowEnd8: Integer);
procedure RefmvsSaveTmvs(var RF: TRefmvsFrame; ColStart8, ColEnd8, RowStart8, RowEnd8: Integer);
procedure RefmvsSplat(var RF: TRefmvsFrame; const Tmpl: TRefmvsBlock; By4, Bx4, Bw4, Bh4: Integer);

function RowPtr(var RF: TRefmvsFrame; Y4: Integer): PRefmvsBlock; inline;

function GetGmv2d(const Gmv: TWarpParams; Bx4, By4, Bw4, Bh4: Integer; const Hdr: TFrameHdr): TMv;
procedure FixMvPrecision(const Hdr: TFrameHdr; var Mv: TMv);

implementation

function IMin(a, b: Integer): Integer; inline; begin if a < b then Result := a else Result := b; end;
function IMax(a, b: Integer): Integer; inline; begin if a > b then Result := a else Result := b; end;
function IClip(v, lo, hi: Integer): Integer; inline;
begin if v < lo then Result := lo else if v > hi then Result := hi else Result := v; end;
function ApplySign(v, s: Integer): Integer; inline;
begin if s < 0 then Result := -v else Result := v; end;

function RowPtr(var RF: TRefmvsFrame; Y4: Integer): PRefmvsBlock;
begin Result := @RF.R[Y4 * RF.RStride]; end;

procedure FixIntMvPrecision(var Mv: TMv); inline;
var x, y: Integer;
begin
  x := Mv.x; y := Mv.y;
  Mv.x := SmallInt((x - SarLongint(x, 15) + 3) and not 7);
  Mv.y := SmallInt((y - SarLongint(y, 15) + 3) and not 7);
end;

procedure FixMvPrecision(const Hdr: TFrameHdr; var Mv: TMv);
var x, y: Integer;
begin
  if Hdr.ForceIntegerMv <> 0 then FixIntMvPrecision(Mv)
  else if not Hdr.Hp then
  begin
    x := Mv.x; y := Mv.y;
    Mv.x := SmallInt((x - SarLongint(x, 15)) and not 1);
    Mv.y := SmallInt((y - SarLongint(y, 15)) and not 1);
  end;
end;

function GetGmv2d(const Gmv: TWarpParams; Bx4, By4, Bw4, Bh4: Integer; const Hdr: TFrameHdr): TMv;
var x, y, xc, yc, shift, rnd, nhp: Integer;
begin
  Result.n := 0;
  case Gmv.WmType of
    WM_TYPE_IDENTITY: Result.n := 0;
    WM_TYPE_TRANSLATION:
      begin
        Result.y := SmallInt(SarLongint(Gmv.Matrix[0], 13));
        Result.x := SmallInt(SarLongint(Gmv.Matrix[1], 13));
        if Hdr.ForceIntegerMv <> 0 then FixIntMvPrecision(Result);
      end;
  else
    begin
      x := Bx4 * 4 + Bw4 * 2 - 1;
      y := By4 * 4 + Bh4 * 2 - 1;
      xc := (Gmv.Matrix[2] - (1 shl 16)) * x + Gmv.Matrix[3] * y + Gmv.Matrix[0];
      yc := (Gmv.Matrix[5] - (1 shl 16)) * y + Gmv.Matrix[4] * x + Gmv.Matrix[1];
      nhp := Ord(not Hdr.Hp);
      shift := 16 - (3 - nhp);
      rnd := (1 shl shift) shr 1;
      Result.y := SmallInt(ApplySign(((Abs(yc) + rnd) shr shift) shl nhp, yc));
      Result.x := SmallInt(ApplySign(((Abs(xc) + rnd) shr shift) shl nhp, xc));
      if Hdr.ForceIntegerMv <> 0 then FixIntMvPrecision(Result);
    end;
  end;
end;

procedure AddSpatialCandidate(var MvStack: TMvStack; var Cnt: Integer; Weight: Integer;
  B: PRefmvsBlock; const Ref: TRefPair; const Gmv: array of TMv;
  var HaveNewmvMatch, HaveRefmvMatch: Integer);
var n, m, last: Integer; candMv: TMv; candPair: TMvPair;
begin
  if B^.mv.mv[0].n = INVALID_MV then Exit;
  if Ref.ref[1] = -1 then
  begin
    for n := 0 to 1 do
      if B^.ref.ref[n] = Ref.ref[0] then
      begin
        if ((B^.mf and 1) <> 0) and (Gmv[0].n <> INVALID_MV) then candMv := Gmv[0]
        else candMv := B^.mv.mv[n];
        HaveRefmvMatch := 1;
        HaveNewmvMatch := HaveNewmvMatch or (B^.mf shr 1);
        last := Cnt;
        for m := 0 to last - 1 do
          if MvStack[m].mv.mv[0].n = candMv.n then
          begin
            Inc(MvStack[m].weight, Weight);
            Exit;
          end;
        if last < 8 then
        begin
          MvStack[last].mv.mv[0] := candMv;
          MvStack[last].weight := Weight;
          Cnt := last + 1;
        end;
        Exit;
      end;
  end
  else if B^.ref.pair = Ref.pair then
  begin
    if ((B^.mf and 1) <> 0) and (Gmv[0].n <> INVALID_MV) then candPair.mv[0] := Gmv[0]
    else candPair.mv[0] := B^.mv.mv[0];
    if ((B^.mf and 1) <> 0) and (Gmv[1].n <> INVALID_MV) then candPair.mv[1] := Gmv[1]
    else candPair.mv[1] := B^.mv.mv[1];
    HaveRefmvMatch := 1;
    HaveNewmvMatch := HaveNewmvMatch or (B^.mf shr 1);
    last := Cnt;
    for n := 0 to last - 1 do
      if MvStack[n].mv.n = candPair.n then
      begin
        Inc(MvStack[n].weight, Weight);
        Exit;
      end;
    if last < 8 then
    begin
      MvStack[last].mv := candPair;
      MvStack[last].weight := Weight;
      Cnt := last + 1;
    end;
  end;
end;

function ScanRow(var MvStack: TMvStack; var Cnt: Integer; const Ref: TRefPair;
  const Gmv: array of TMv; B: PRefmvsBlock; Bw4, W4, MaxRows, Step: Integer;
  var HaveNewmvMatch, HaveRefmvMatch: Integer): Integer;
var candB: PRefmvsBlock; candBw4, len, weight, x: Integer;
begin
  candB := B;
  candBw4 := BlockDim[candB^.bs][0];
  len := IMax(Step, IMin(Bw4, candBw4));
  if Bw4 <= candBw4 then
  begin
    if Bw4 = 1 then weight := 2
    else weight := IMax(2, IMin(2 * MaxRows, BlockDim[candB^.bs][1]));
    AddSpatialCandidate(MvStack, Cnt, len * weight, candB, Ref, Gmv, HaveNewmvMatch, HaveRefmvMatch);
    Exit(weight shr 1);
  end;
  x := 0;
  while True do
  begin
    AddSpatialCandidate(MvStack, Cnt, len * 2, candB, Ref, Gmv, HaveNewmvMatch, HaveRefmvMatch);
    Inc(x, len);
    if x >= W4 then Exit(1);
    candB := B + x;
    candBw4 := BlockDim[candB^.bs][0];
    len := IMax(Step, candBw4);
  end;
end;

function ScanCol(var RF: TRefmvsFrame; var MvStack: TMvStack; var Cnt: Integer;
  const Ref: TRefPair; const Gmv: array of TMv; Row0, Bh4, H4, Bx4, MaxCols, Step: Integer;
  var HaveNewmvMatch, HaveRefmvMatch: Integer): Integer;
var candB: PRefmvsBlock; candBh4, len, weight, y: Integer;
begin
  candB := RowPtr(RF, Row0) + Bx4;
  candBh4 := BlockDim[candB^.bs][1];
  len := IMax(Step, IMin(Bh4, candBh4));
  if Bh4 <= candBh4 then
  begin
    if Bh4 = 1 then weight := 2
    else weight := IMax(2, IMin(2 * MaxCols, BlockDim[candB^.bs][0]));
    AddSpatialCandidate(MvStack, Cnt, len * weight, candB, Ref, Gmv, HaveNewmvMatch, HaveRefmvMatch);
    Exit(weight shr 1);
  end;
  y := 0;
  while True do
  begin
    AddSpatialCandidate(MvStack, Cnt, len * 2, candB, Ref, Gmv, HaveNewmvMatch, HaveRefmvMatch);
    Inc(y, len);
    if y >= H4 then Exit(1);
    candB := RowPtr(RF, Row0 + y) + Bx4;
    candBh4 := BlockDim[candB^.bs][1];
    len := IMax(Step, candBh4);
  end;
end;

const
  DivMult: array[0..31] of Word = (
       0, 16384, 8192, 5461, 4096, 3276, 2730, 2340,
    2048,  1820, 1638, 1489, 1365, 1260, 1170, 1092,
    1024,   963,  910,  862,  819,  780,  744,  712,
     682,   655,  630,  606,  585,  564,  546,  528);

function MvProjection(const Mv: TMv; Num, Den: Integer): TMv;
var frac, y, x: Integer;
begin
  frac := Num * DivMult[Den];
  y := Mv.y * frac; x := Mv.x * frac;
  Result.y := SmallInt(IClip(SarLongint(y + 8192 + SarLongint(y, 31), 14), -$3fff, $3fff));
  Result.x := SmallInt(IClip(SarLongint(x + 8192 + SarLongint(x, 31), 14), -$3fff, $3fff));
end;

procedure AddTemporalCandidate(var RF: TRefmvsFrame; var MvStack: TMvStack; var Cnt: Integer;
  Rb: PRefmvsTemporal; const Ref: TRefPair; GlobalMvCtx: PInteger; const Gmv: array of TMv;
  Weight: Integer);
var mv: TMv; mvp: TMvPair; last, n: Integer;
begin
  if Rb^.mv.n = INVALID_MV then Exit;
  mv := MvProjection(Rb^.mv, RF.PocDiff[Ref.ref[0] - 1], Rb^.ref);
  FixMvPrecision(RF.Frm^, mv);
  last := Cnt;
  if Ref.ref[1] = -1 then
  begin
    if GlobalMvCtx <> nil then
      GlobalMvCtx^ := Ord((Abs(mv.x - Gmv[0].x) or Abs(mv.y - Gmv[0].y)) >= 16);
    for n := 0 to last - 1 do
      if MvStack[n].mv.mv[0].n = mv.n then
      begin
        Inc(MvStack[n].weight, Weight);
        Exit;
      end;
    if last < 8 then
    begin
      MvStack[last].mv.mv[0] := mv;
      MvStack[last].weight := Weight;
      Cnt := last + 1;
    end;
  end
  else
  begin
    mvp.mv[0] := mv;
    mvp.mv[1] := MvProjection(Rb^.mv, RF.PocDiff[Ref.ref[1] - 1], Rb^.ref);
    FixMvPrecision(RF.Frm^, mvp.mv[1]);
    for n := 0 to last - 1 do
      if MvStack[n].mv.n = mvp.n then
      begin
        Inc(MvStack[n].weight, Weight);
        Exit;
      end;
    if last < 8 then
    begin
      MvStack[last].mv := mvp;
      MvStack[last].weight := Weight;
      Cnt := last + 1;
    end;
  end;
end;

// same = MvStack[base..base+1], diff = MvStack[base+2..base+3];
// counts[0..1] = same_count, counts[2..3] = diff_count
procedure AddCompoundExtendedCandidate(var MvStack: TMvStack; Base: Integer;
  var Counts: array of Integer; CandB: PRefmvsBlock; Sign0, Sign1: Integer;
  const Ref: TRefPair; const SignBias: array of Byte);
var n, candRef: Integer; candMv, iCandMv: TMv;
begin
  for n := 0 to 1 do
  begin
    candRef := CandB^.ref.ref[n];
    if candRef <= 0 then Break;
    candMv := CandB^.mv.mv[n];
    if candRef = Ref.ref[0] then
    begin
      if Counts[0] < 2 then begin MvStack[Base + Counts[0]].mv.mv[0] := candMv; Inc(Counts[0]); end;
      if Counts[3] < 2 then
      begin
        if (Sign1 xor SignBias[candRef - 1]) <> 0 then
        begin candMv.y := -candMv.y; candMv.x := -candMv.x; end;
        MvStack[Base + 2 + Counts[3]].mv.mv[1] := candMv; Inc(Counts[3]);
      end;
    end
    else if candRef = Ref.ref[1] then
    begin
      if Counts[1] < 2 then begin MvStack[Base + Counts[1]].mv.mv[1] := candMv; Inc(Counts[1]); end;
      if Counts[2] < 2 then
      begin
        if (Sign0 xor SignBias[candRef - 1]) <> 0 then
        begin candMv.y := -candMv.y; candMv.x := -candMv.x; end;
        MvStack[Base + 2 + Counts[2]].mv.mv[0] := candMv; Inc(Counts[2]);
      end;
    end
    else
    begin
      iCandMv.x := -candMv.x; iCandMv.y := -candMv.y;
      if Counts[2] < 2 then
      begin
        if (Sign0 xor SignBias[candRef - 1]) <> 0 then MvStack[Base + 2 + Counts[2]].mv.mv[0] := iCandMv
        else MvStack[Base + 2 + Counts[2]].mv.mv[0] := candMv;
        Inc(Counts[2]);
      end;
      if Counts[3] < 2 then
      begin
        if (Sign1 xor SignBias[candRef - 1]) <> 0 then MvStack[Base + 2 + Counts[3]].mv.mv[1] := iCandMv
        else MvStack[Base + 2 + Counts[3]].mv.mv[1] := candMv;
        Inc(Counts[3]);
      end;
    end;
  end;
end;

procedure AddSingleExtendedCandidate(var MvStack: TMvStack; var Cnt: Integer;
  CandB: PRefmvsBlock; Sign: Integer; const SignBias: array of Byte);
var n, m, last, candRef: Integer; candMv: TMv;
begin
  for n := 0 to 1 do
  begin
    candRef := CandB^.ref.ref[n];
    if candRef <= 0 then Break;
    candMv := CandB^.mv.mv[n];
    if (Sign xor SignBias[candRef - 1]) <> 0 then
    begin candMv.y := -candMv.y; candMv.x := -candMv.x; end;
    last := Cnt;
    m := 0;
    while m < last do
    begin
      if candMv.n = MvStack[m].mv.mv[0].n then Break;
      Inc(m);
    end;
    if m = last then
    begin
      MvStack[m].mv.mv[0] := candMv;
      MvStack[m].weight := 2;
      Cnt := last + 1;
    end;
  end;
end;

procedure RefmvsFind(var RF: TRefmvsFrame; var MvStack: TMvStack; out Cnt, Ctx: Integer;
  Ref0, Ref1: Integer; Bs, EdgeFlags, By4, Bx4: Integer);
var
  ref: TRefPair;
  bw4, w4, bh4, h4: Integer;
  gmv, tgmv: array[0..1] of TMv;
  haveNewmv, haveColMvs, haveRowMvs, haveDummy: Integer;
  maxRows, nRows, maxCols, nCols: LongWord;
  bTop: PRefmvsBlock;
  nearestMatch, nearestCnt, n, refMatchCount, refmvCtx, newmvCtx, len, last, m: Integer;
  globalmvCtx: Integer;
  stride, by8, bx8, stepH, stepV, w8, h8, x, y, runLen, bh8, bw8: Integer;
  rbi, rb, run: PRefmvsTemporal;
  runGmvCtx: PInteger;
  mvn: LongWord;
  hasBottom: Boolean;
  tmp: TRefmvsCandidate;
  sign0, sign1, sz4, l: Integer;
  counts: array[0..3] of Integer;
  same: Integer;
  candB: PRefmvsBlock;
  left, right, top, bottom, nRefmvs, sign: Integer;
begin
  ref.ref[0] := Ref0; ref.ref[1] := Ref1;
  bw4 := BlockDim[Bs][0]; w4 := IMin(IMin(bw4, 16), RF.TileColEnd - Bx4);
  bh4 := BlockDim[Bs][1]; h4 := IMin(IMin(bh4, 16), RF.TileRowEnd - By4);
  Cnt := 0;
  if Ref0 > 0 then
  begin
    tgmv[0] := GetGmv2d(RF.Frm^.Gmv[Ref0 - 1], Bx4, By4, bw4, bh4, RF.Frm^);
    if RF.Frm^.Gmv[Ref0 - 1].WmType > WM_TYPE_TRANSLATION then gmv[0] := tgmv[0]
    else gmv[0].n := INVALID_MV;
  end
  else
  begin
    tgmv[0].n := 0;
    gmv[0].n := INVALID_MV;
  end;
  if Ref1 > 0 then
  begin
    tgmv[1] := GetGmv2d(RF.Frm^.Gmv[Ref1 - 1], Bx4, By4, bw4, bh4, RF.Frm^);
    if RF.Frm^.Gmv[Ref1 - 1].WmType > WM_TYPE_TRANSLATION then gmv[1] := tgmv[1]
    else gmv[1].n := INVALID_MV;
  end;

  // top
  haveNewmv := 0; haveColMvs := 0; haveRowMvs := 0;
  maxRows := 0; nRows := $FFFFFFFF; bTop := nil;
  if By4 > RF.TileRowStart then
  begin
    maxRows := IMin((By4 - RF.TileRowStart + 1) shr 1, 2 + Ord(bh4 > 1));
    bTop := RowPtr(RF, By4 - 1) + Bx4;
    if bw4 >= 16 then n := 4 else n := 1;
    nRows := ScanRow(MvStack, Cnt, ref, gmv, bTop, bw4, w4, maxRows, n, haveNewmv, haveRowMvs);
  end;
  // left
  maxCols := 0; nCols := $FFFFFFFF;
  if Bx4 > RF.TileColStart then
  begin
    maxCols := IMin((Bx4 - RF.TileColStart + 1) shr 1, 2 + Ord(bw4 > 1));
    if bh4 >= 16 then n := 4 else n := 1;
    nCols := ScanCol(RF, MvStack, Cnt, ref, gmv, By4, bh4, h4, Bx4 - 1, maxCols, n, haveNewmv, haveColMvs);
  end;
  // top/right
  if (nRows <> $FFFFFFFF) and ((EdgeFlags and EDGE_I444_TOP_HAS_RIGHT) <> 0) and
     (IMax(bw4, bh4) <= 16) and (bw4 + Bx4 < RF.TileColEnd) then
    AddSpatialCandidate(MvStack, Cnt, 4, bTop + bw4, ref, gmv, haveNewmv, haveRowMvs);

  nearestMatch := haveColMvs + haveRowMvs;
  nearestCnt := Cnt;
  for n := 0 to nearestCnt - 1 do Inc(MvStack[n].weight, 640);

  // temporal
  globalmvCtx := Ord(RF.Frm^.UseRefFrameMvs);
  if RF.UseRefFrameMvs then
  begin
    stride := RF.RpStride;
    by8 := By4 shr 1; bx8 := Bx4 shr 1;
    rbi := @RF.RpProj[(by8 and 15) * stride + bx8];
    rb := rbi;
    if bw4 >= 16 then stepH := 2 else stepH := 1;
    if bh4 >= 16 then stepV := 2 else stepV := 1;
    w8 := IMin((w4 + 1) shr 1, 8); h8 := IMin((h4 + 1) shr 1, 8);
    run := rb; runLen := 1; runGmvCtx := @globalmvCtx;
    y := 0;
    while y < h8 do
    begin
      if y <> 0 then x := 0 else x := stepH;
      while x < w8 do
      begin
        mvn := rb[x].mv.n;
        if (mvn = run^.mv.n) and ((mvn = INVALID_MV) or (rb[x].ref = run^.ref)) then
        begin
          Inc(runLen);
        end
        else
        begin
          AddTemporalCandidate(RF, MvStack, Cnt, run, ref, runGmvCtx, tgmv, 2 * runLen);
          runGmvCtx := nil;
          run := @rb[x];
          runLen := 1;
        end;
        Inc(x, stepH);
      end;
      Inc(rb, stride * stepV);
      Inc(y, stepV);
    end;
    AddTemporalCandidate(RF, MvStack, Cnt, run, ref, runGmvCtx, tgmv, 2 * runLen);
    if (IMin(bw4, bh4) >= 2) and (IMax(bw4, bh4) < 16) then
    begin
      bh8 := bh4 shr 1; bw8 := bw4 shr 1;
      rb := rbi + bh8 * stride;
      hasBottom := by8 + bh8 < IMin(RF.TileRowEnd shr 1, (by8 and not 7) + 8);
      if hasBottom and (bx8 - 1 >= IMax(RF.TileColStart shr 1, bx8 and not 7)) then
        AddTemporalCandidate(RF, MvStack, Cnt, rb - 1, ref, nil, tgmv, 2);
      if bx8 + bw8 < IMin(RF.TileColEnd shr 1, (bx8 and not 7) + 8) then
      begin
        if hasBottom then
          AddTemporalCandidate(RF, MvStack, Cnt, rb + bw8, ref, nil, tgmv, 2);
        if by8 + bh8 - 1 < IMin(RF.TileRowEnd shr 1, (by8 and not 7) + 8) then
          AddTemporalCandidate(RF, MvStack, Cnt, rb + bw8 - stride, ref, nil, tgmv, 2);
      end;
    end;
  end;

  // top/left
  if (nRows or nCols) <> $FFFFFFFF then
    AddSpatialCandidate(MvStack, Cnt, 4, bTop - 1, ref, gmv, haveDummy, haveRowMvs);

  // secondary top & left edges (8x8 resolution)
  for n := 2 to 3 do
  begin
    if (LongWord(n) > nRows) and (LongWord(n) <= maxRows) then
    begin
      if bw4 >= 16 then m := 4 else m := 2;
      Inc(nRows, LongWord(ScanRow(MvStack, Cnt, ref, gmv,
        RowPtr(RF, (By4 - 2 * n + 1) or 1) + (Bx4 or 1),
        bw4, w4, 1 + Integer(maxRows) - n, m, haveDummy, haveRowMvs)));
    end;
    if (LongWord(n) > nCols) and (LongWord(n) <= maxCols) then
    begin
      if bh4 >= 16 then m := 4 else m := 2;
      Inc(nCols, LongWord(ScanCol(RF, MvStack, Cnt, ref, gmv, By4 or 1, bh4, h4,
        (Bx4 - n * 2 + 1) or 1, 1 + Integer(maxCols) - n, m, haveDummy, haveColMvs)));
    end;
  end;

  refMatchCount := haveColMvs + haveRowMvs;
  refmvCtx := 0; newmvCtx := 0;
  case nearestMatch of
    0: begin refmvCtx := IMin(2, refMatchCount); newmvCtx := Ord(refMatchCount > 0); end;
    1: begin refmvCtx := IMin(refMatchCount * 3, 4); newmvCtx := 3 - haveNewmv; end;
    2: begin refmvCtx := 5; newmvCtx := 5 - haveNewmv; end;
  end;

  // sorting
  len := nearestCnt;
  while len > 0 do
  begin
    last := 0;
    for n := 1 to len - 1 do
      if MvStack[n - 1].weight < MvStack[n].weight then
      begin
        tmp := MvStack[n - 1]; MvStack[n - 1] := MvStack[n]; MvStack[n] := tmp;
        last := n;
      end;
    len := last;
  end;
  len := Cnt;
  while len > nearestCnt do
  begin
    last := nearestCnt;
    for n := nearestCnt + 1 to len - 1 do
      if MvStack[n - 1].weight < MvStack[n].weight then
      begin
        tmp := MvStack[n - 1]; MvStack[n - 1] := MvStack[n]; MvStack[n] := tmp;
        last := n;
      end;
    len := last;
  end;

  if Ref1 > 0 then
  begin
    if Cnt < 2 then
    begin
      sign0 := RF.SignBias[Ref0 - 1];
      sign1 := RF.SignBias[Ref1 - 1];
      sz4 := IMin(w4, h4);
      same := Cnt;
      counts[0] := 0; counts[1] := 0; counts[2] := 0; counts[3] := 0;
      if nRows <> $FFFFFFFF then
      begin
        x := 0;
        while x < sz4 do
        begin
          candB := bTop + x;
          AddCompoundExtendedCandidate(MvStack, same, counts, candB, sign0, sign1, ref, RF.SignBias);
          Inc(x, BlockDim[candB^.bs][0]);
        end;
      end;
      if nCols <> $FFFFFFFF then
      begin
        y := 0;
        while y < sz4 do
        begin
          candB := RowPtr(RF, By4 + y) + (Bx4 - 1);
          AddCompoundExtendedCandidate(MvStack, same, counts, candB, sign0, sign1, ref, RF.SignBias);
          Inc(y, BlockDim[candB^.bs][1]);
        end;
      end;
      // merge
      for n := 0 to 1 do
      begin
        m := counts[n];
        if m >= 2 then Continue;
        l := counts[2 + n];
        if l <> 0 then
        begin
          MvStack[same + m].mv.mv[n] := MvStack[same + 2].mv.mv[n];
          Inc(m);
          if m = 2 then Continue;
          if l = 2 then
          begin
            MvStack[same + 1].mv.mv[n] := MvStack[same + 3].mv.mv[n];
            Continue;
          end;
        end;
        repeat
          MvStack[same + m].mv.mv[n] := tgmv[n];
          Inc(m);
        until m >= 2;
      end;
      n := Cnt;
      if (n = 1) and (MvStack[0].mv.n = MvStack[same].mv.n) then
        MvStack[1].mv := MvStack[2].mv;
      repeat
        MvStack[n].weight := 2;
        Inc(n);
      until n >= 2;
      Cnt := 2;
    end;

    left := -(Bx4 + bw4 + 4) * 4 * 8;
    right := (RF.iw4 - Bx4 + 4) * 4 * 8;
    top := -(By4 + bh4 + 4) * 4 * 8;
    bottom := (RF.ih4 - By4 + 4) * 4 * 8;
    nRefmvs := Cnt;
    n := 0;
    repeat
      MvStack[n].mv.mv[0].x := IClip(MvStack[n].mv.mv[0].x, left, right);
      MvStack[n].mv.mv[0].y := IClip(MvStack[n].mv.mv[0].y, top, bottom);
      MvStack[n].mv.mv[1].x := IClip(MvStack[n].mv.mv[1].x, left, right);
      MvStack[n].mv.mv[1].y := IClip(MvStack[n].mv.mv[1].y, top, bottom);
      Inc(n);
    until n >= nRefmvs;

    case refmvCtx shr 1 of
      0: Ctx := IMin(newmvCtx, 1);
      1: Ctx := 1 + IMin(newmvCtx, 3);
    else Ctx := IClip(3 + newmvCtx, 4, 7);
    end;
    Exit;
  end
  else if (Cnt < 2) and (Ref0 > 0) then
  begin
    sign := RF.SignBias[Ref0 - 1];
    sz4 := IMin(w4, h4);
    if nRows <> $FFFFFFFF then
    begin
      x := 0;
      while (x < sz4) and (Cnt < 2) do
      begin
        candB := bTop + x;
        AddSingleExtendedCandidate(MvStack, Cnt, candB, sign, RF.SignBias);
        Inc(x, BlockDim[candB^.bs][0]);
      end;
    end;
    if nCols <> $FFFFFFFF then
    begin
      y := 0;
      while (y < sz4) and (Cnt < 2) do
      begin
        candB := RowPtr(RF, By4 + y) + (Bx4 - 1);
        AddSingleExtendedCandidate(MvStack, Cnt, candB, sign, RF.SignBias);
        Inc(y, BlockDim[candB^.bs][1]);
      end;
    end;
  end;

  nRefmvs := Cnt;
  if nRefmvs <> 0 then
  begin
    left := -(Bx4 + bw4 + 4) * 4 * 8;
    right := (RF.iw4 - Bx4 + 4) * 4 * 8;
    top := -(By4 + bh4 + 4) * 4 * 8;
    bottom := (RF.ih4 - By4 + 4) * 4 * 8;
    for n := 0 to nRefmvs - 1 do
    begin
      MvStack[n].mv.mv[0].x := IClip(MvStack[n].mv.mv[0].x, left, right);
      MvStack[n].mv.mv[0].y := IClip(MvStack[n].mv.mv[0].y, top, bottom);
    end;
  end;
  for n := Cnt to 1 do MvStack[n].mv.mv[0] := tgmv[0];
  Ctx := (refmvCtx shl 4) or (globalmvCtx shl 3) or newmvCtx;
end;

procedure RefmvsTileInit(var RF: TRefmvsFrame; ColStart4, ColEnd4, RowStart4, RowEnd4: Integer);
begin
  RF.TileRowStart := RowStart4;
  RF.TileRowEnd := IMin(RowEnd4, RF.ih4);
  RF.TileColStart := ColStart4;
  RF.TileColEnd := IMin(ColEnd4, RF.iw4);
end;

procedure RefmvsLoadTmvs(var RF: TRefmvsFrame; ColStart8, ColEnd8, RowStart8, RowEnd8: Integer);
var
  colStart8i, colEnd8i, stride, y, x, n, ref2cur, ref, refSign, ySbAlign, yProjStart, yProjEnd,
  bRef, ref2ref, posX, posY, xSbAlign: Integer;
  rpProj: PRefmvsTemporal;
  r, rb: PRefmvsTemporal;
  bMv, offset: TMv;
  pos: Integer;
begin
  RowEnd8 := IMin(RowEnd8, RF.ih8);
  colStart8i := IMax(ColStart8 - 8, 0);
  colEnd8i := IMin(ColEnd8 + 8, RF.iw8);
  stride := RF.RpStride;
  rpProj := @RF.RpProj[(RowStart8 and 15) * stride];
  for y := RowStart8 to RowEnd8 - 1 do
  begin
    for x := ColStart8 to ColEnd8 - 1 do rpProj[x].mv.n := INVALID_MV;
    Inc(rpProj, stride);
  end;
  rpProj := @RF.RpProj[0];
  for n := 0 to RF.NMfmvs - 1 do
  begin
    ref2cur := RF.MfmvRef2Cur[n];
    if ref2cur = INVALID_REF2CUR then Continue;
    ref := RF.MfmvRef[n];
    refSign := ref - 4;
    r := RF.RpRef[ref] + RowStart8 * stride;
    for y := RowStart8 to RowEnd8 - 1 do
    begin
      ySbAlign := y and not 7;
      yProjStart := IMax(ySbAlign, RowStart8);
      yProjEnd := IMin(ySbAlign + 8, RowEnd8);
      x := colStart8i;
      while x < colEnd8i do
      begin
        rb := r + x;
        bRef := rb^.ref;
        if bRef = 0 then begin Inc(x); Continue; end;
        ref2ref := RF.MfmvRef2Ref[n][bRef - 1];
        if ref2ref = 0 then begin Inc(x); Continue; end;
        bMv := rb^.mv;
        offset := MvProjection(bMv, ref2cur, ref2ref);
        posX := x + ApplySign(Abs(offset.x) shr 6, offset.x xor refSign);
        posY := y + ApplySign(Abs(offset.y) shr 6, offset.y xor refSign);
        if (posY >= yProjStart) and (posY < yProjEnd) then
        begin
          pos := (posY and 15) * stride;
          while True do
          begin
            xSbAlign := x and not 7;
            if (posX >= IMax(xSbAlign - 8, ColStart8)) and (posX < IMin(xSbAlign + 16, ColEnd8)) then
            begin
              rpProj[pos + posX].mv := rb^.mv;
              rpProj[pos + posX].ref := ref2ref;
            end;
            Inc(x);
            if x >= colEnd8i then Break;
            Inc(rb);
            if (rb^.ref <> bRef) or (rb^.mv.n <> bMv.n) then Break;
            Inc(posX);
          end;
        end
        else
        begin
          while True do
          begin
            Inc(x);
            if x >= colEnd8i then Break;
            Inc(rb);
            if (rb^.ref <> bRef) or (rb^.mv.n <> bMv.n) then Break;
          end;
        end;
        // x already points past the run (C's x-- then loop x++)
      end;
      Inc(r, stride);
    end;
  end;
end;

procedure RefmvsSaveTmvs(var RF: TRefmvsFrame; ColStart8, ColEnd8, RowStart8, RowEnd8: Integer);
var y, x, n, bw8, stride: Integer; b, candB: PRefmvsBlock; rp: PRefmvsTemporal; tmv: TRefmvsTemporal;
begin
  RowEnd8 := IMin(RowEnd8, RF.ih8);
  ColEnd8 := IMin(ColEnd8, RF.iw8);
  stride := RF.RpStride;
  rp := RF.Rp + RowStart8 * stride;
  for y := RowStart8 to RowEnd8 - 1 do
  begin
    b := RowPtr(RF, y * 2 + 1);
    x := ColStart8;
    while x < ColEnd8 do
    begin
      candB := b + (x * 2 + 1);
      bw8 := (BlockDim[candB^.bs][0] + 1) shr 1;
      if (candB^.ref.ref[1] > 0) and (RF.MfmvSign[candB^.ref.ref[1] - 1] <> 0) and
         ((Abs(candB^.mv.mv[1].y) or Abs(candB^.mv.mv[1].x)) < 4096) then
      begin
        tmv.mv := candB^.mv.mv[1]; tmv.ref := candB^.ref.ref[1];
        for n := 0 to bw8 - 1 do begin rp[x] := tmv; Inc(x); end;
      end
      else if (candB^.ref.ref[0] > 0) and (RF.MfmvSign[candB^.ref.ref[0] - 1] <> 0) and
              ((Abs(candB^.mv.mv[0].y) or Abs(candB^.mv.mv[0].x)) < 4096) then
      begin
        tmv.mv := candB^.mv.mv[0]; tmv.ref := candB^.ref.ref[0];
        for n := 0 to bw8 - 1 do begin rp[x] := tmv; Inc(x); end;
      end
      else
      begin
        FillChar(rp[x], bw8 * SizeOf(TRefmvsTemporal), 0);
        Inc(x, bw8);
      end;
    end;
    Inc(rp, stride);
  end;
end;

procedure RefmvsSplat(var RF: TRefmvsFrame; const Tmpl: TRefmvsBlock; By4, Bx4, Bw4, Bh4: Integer);
var y, x: Integer; r: PRefmvsBlock;
begin
  for y := 0 to Bh4 - 1 do
  begin
    r := RowPtr(RF, By4 + y) + Bx4;
    for x := 0 to Bw4 - 1 do r[x] := Tmpl;
  end;
end;

procedure RefmvsInitFrame(var RF: TRefmvsFrame; const Seq: TSeqHdr; const Frm: TFrameHdr;
  const RefPoc: array of Integer; Rp: PRefmvsTemporal;
  const RefRefPoc: array of Integer; const RpRef: array of PRefmvsTemporal);
var i, n, m, poc, total, rpoc, diff1, diff2, rows: Integer;
begin
  RF.RpStride := ((Frm.Width[0] + 127) and not 127) shr 3;
  RF.sbsz := 16 shl Ord(Seq.Sb128);
  RF.Frm := @Frm;
  RF.Seq := @Seq;
  RF.iw8 := (Frm.Width[0] + 7) shr 3;
  RF.ih8 := (Frm.Height + 7) shr 3;
  RF.iw4 := RF.iw8 shl 1;
  RF.ih4 := RF.ih8 shl 1;
  RF.Rp := Rp;
  RF.RStride := RF.RpStride * 2;
  rows := ((RF.ih4 + 31) and not 31) + 32;
  if Length(RF.R) < rows * RF.RStride then SetLength(RF.R, rows * RF.RStride);
  if Length(RF.RpProj) < 16 * RF.RpStride then SetLength(RF.RpProj, 16 * RF.RpStride);

  poc := Frm.FrameOffset;
  for i := 0 to 6 do
  begin
    n := GetPocDiff(Seq.OrderHintNBits, RefPoc[i], poc);
    RF.SignBias[i] := Ord(n > 0);
    RF.MfmvSign[i] := Ord(n < 0);
    RF.PocDiff[i] := IClip(GetPocDiff(Seq.OrderHintNBits, poc, RefPoc[i]), -31, 31);
  end;

  RF.NMfmvs := 0;
  for i := 0 to 6 do RF.RpRef[i] := RpRef[i];
  if Frm.UseRefFrameMvs and (Seq.OrderHintNBits <> 0) then
  begin
    total := 2;
    if (RpRef[0] <> nil) and (RefRefPoc[0 * 7 + 6] <> RefPoc[3]) then
    begin
      RF.MfmvRef[RF.NMfmvs] := 0; Inc(RF.NMfmvs);
      total := 3;
    end;
    if (RpRef[4] <> nil) and (GetPocDiff(Seq.OrderHintNBits, RefPoc[4], Frm.FrameOffset) > 0) then
    begin RF.MfmvRef[RF.NMfmvs] := 4; Inc(RF.NMfmvs); end;
    if (RpRef[5] <> nil) and (GetPocDiff(Seq.OrderHintNBits, RefPoc[5], Frm.FrameOffset) > 0) then
    begin RF.MfmvRef[RF.NMfmvs] := 5; Inc(RF.NMfmvs); end;
    if (RF.NMfmvs < total) and (RpRef[6] <> nil) and
       (GetPocDiff(Seq.OrderHintNBits, RefPoc[6], Frm.FrameOffset) > 0) then
    begin RF.MfmvRef[RF.NMfmvs] := 6; Inc(RF.NMfmvs); end;
    if (RF.NMfmvs < total) and (RpRef[1] <> nil) then
    begin RF.MfmvRef[RF.NMfmvs] := 1; Inc(RF.NMfmvs); end;

    for n := 0 to RF.NMfmvs - 1 do
    begin
      rpoc := RefPoc[RF.MfmvRef[n]];
      diff1 := GetPocDiff(Seq.OrderHintNBits, rpoc, Frm.FrameOffset);
      if Abs(diff1) > 31 then
        RF.MfmvRef2Cur[n] := INVALID_REF2CUR
      else
      begin
        if RF.MfmvRef[n] < 4 then RF.MfmvRef2Cur[n] := -diff1 else RF.MfmvRef2Cur[n] := diff1;
        for m := 0 to 6 do
        begin
          diff2 := GetPocDiff(Seq.OrderHintNBits, rpoc, RefRefPoc[RF.MfmvRef[n] * 7 + m]);
          if LongWord(diff2) > 31 then RF.MfmvRef2Ref[n][m] := 0
          else RF.MfmvRef2Ref[n][m] := diff2;
        end;
      end;
    end;
  end;
  RF.UseRefFrameMvs := RF.NMfmvs > 0;
end;

end.
