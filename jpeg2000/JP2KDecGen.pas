// JPEG 2000 based on JASPER 4.2.9
// License: JasPer-2.0 (similar to MIT )
// Author: www.xelitan.com
//
// JP2KDecGen - general single-tile JPEG 2000 decoder.
//
// Extends the focused decoder in JP2KCodec towards the full Part-1 feature set
// that JasPer can read.
//
// Supports: single tile, multiple layers, precinct partitions, LRCP/RLCP/RPCL/
// PCRL/CPRL, ROI (maxshift), 5/3 + 9/7, no subsampling, code-block style 0
// (MQ only).  Reuses the MQ/T1/tag-tree/wavelet/MCT primitives.

unit JP2KDecGen;

{$mode delphi}
{$H+}

interface

uses
  SysUtils, JP2KCommon, JP2KMatrix, JP2KMCT, JP2KWavelet, JP2KT1,
  JP2KTagTree, JP2KBS, JP2KCodec;

// Decode a raw .jpc codestream (general single-tile).
function DecodeGeneralJpc(const Bytes: TBytes): TJp2kImage;
// Decode .jp2 or .jpc (auto-detected).
function DecodeGeneral(const Bytes: TBytes): TJp2kImage;

implementation

const
  MS_SOC = $ff4f; MS_SOT = $ff90; MS_SOD = $ff93; MS_EOC = $ffd9;
  MS_SIZ = $ff51; MS_COD = $ff52; MS_COC = $ff53; MS_RGN = $ff5e;
  MS_QCD = $ff5c; MS_QCC = $ff5d; MS_COM = $ff64;

type
  TBandCoord = record
    cxs, cys, cxe, cye, locxs, locys, orient: Integer;
  end;

  TGCb = record
    cx0, cy0, cx1, cy1: Integer;
    numpasses, numimsbs, numlenbits, firstpassno: Integer;
    segs: array of TSegInfo;  // coding-pass segments (lazy/termall aware)
    nsegs: Integer;
  end;
  TGPr = record
    nh, nv, nc: Integer;
    cb: array of TGCb;
    incl, imsb: TTagTree;
  end;
  TGBd = record
    orient, bndno: Integer;
    present: Boolean;
    cxs, cys, cxe, cye, locx, locy: Integer;
    pr: array of TGPr;
  end;
  TGRl = record
    xs, ys, xe, ye: Integer;
    prcwe, prche, cbgwe, cbghe, cbwe, cbhe: Integer;
    nhp, nvp, np, nb: Integer;
    bd: array of TGBd;
  end;
  TGCo = record
    nrl: Integer;
    rl: array of TGRl;
    tcx0, tcy0, tcx1, tcy1, hs, vs: Integer;   // tile-component coords [tcx0,tcx1)
  end;
  TPktRef = record c, r, prc, lyr: Integer; end;
  TPktCb = record bd, cbi, seg, len: Integer; end;

// ----- small endian / quant helpers (local copies) -----

function RU16(ms: TMemStream): Integer;
var a, b: Integer;
begin a := ms.GetC; b := ms.GetC; Result := (a shl 8) or b; end;

function RU32(ms: TMemStream): LongWord;
var a, b, c, d: Integer;
begin
  a := ms.GetC; b := ms.GetC; c := ms.GetC; d := ms.GetC;
  Result := (LongWord(a) shl 24) or (LongWord(b) shl 16) or (LongWord(c) shl 8) or LongWord(d);
end;

function RDbl(ms: TMemStream): Double;
var hi, lo: LongWord; q: Int64; v: Double absolute q;
begin hi := RU32(ms); lo := RU32(ms); q := (Int64(hi) shl 32) or Int64(lo); Result := v; end;

function Pow2d(n: Integer): Double;
begin
  if n >= 0 then Result := Int64(1) shl n else Result := 1.0 / (Int64(1) shl (-n));
end;

function StepAbs(word, prec: Integer): Double;
begin
  Result := (1.0 + (word and $7ff) / 2048.0) * Pow2d(prec - (word shr 11));
end;

// ----- variable-length codes (tier-2) -----

function GetCommaCode(bs: TBitStream): Integer;
var n, v: Integer;
begin
  n := 0;
  while True do
  begin
    v := bs.GetBit;
    if v < 0 then Exit(-1);
    if v = 0 then Break;
    Inc(n);
    if n > 40 then Exit(-1);   // guard against EOF/desync infinite loop
  end;
  Result := n;
end;

function GetNumNewPasses(bs: TBitStream): Integer;
var n: Integer;
begin
  n := bs.GetBit;
  if n > 0 then
  begin
    n := bs.GetBit;
    if n > 0 then
    begin
      n := bs.GetBits(2);
      if n = 3 then
      begin
        n := bs.GetBits(5);
        if n = 31 then
        begin
          n := bs.GetBits(7);
          if n >= 0 then n := n + 36 + 1;
        end
        else if n >= 0 then n := n + 5 + 1;
      end
      else if n >= 0 then n := n + 2 + 1;
    end
    else if n = 0 then n := n + 2;
  end
  else if n = 0 then n := n + 1;
  Result := n;
end;

// ----- subband coordinates (jpc_tsfb_getbands2), origin (0,0) -----

procedure GGetBands(locxs, locys, xs, ys, xe, ye, numlvls: Integer;
  var bnds: array of TBandCoord; var n: Integer);
var
  nxs, nys, nxe, nye: Integer;
begin
  nxs := CeilDivPow2(xs, 1); nys := CeilDivPow2(ys, 1);
  nxe := CeilDivPow2(xe, 1); nye := CeilDivPow2(ye, 1);
  if numlvls > 0 then
  begin
    GGetBands(locxs, locys, nxs, nys, nxe, nye, numlvls - 1, bnds, n);
    bnds[n].cxs := FloorDivPow2(xs, 1); bnds[n].cys := nys;
    bnds[n].cxe := FloorDivPow2(xe, 1); bnds[n].cye := nye;
    bnds[n].locxs := locxs + nxe - nxs; bnds[n].locys := locys;
    bnds[n].orient := ORIENT_HL; Inc(n);
    bnds[n].cxs := nxs; bnds[n].cys := FloorDivPow2(ys, 1);
    bnds[n].cxe := nxe; bnds[n].cye := FloorDivPow2(ye, 1);
    bnds[n].locxs := locxs; bnds[n].locys := locys + nye - nys;
    bnds[n].orient := ORIENT_LH; Inc(n);
    bnds[n].cxs := FloorDivPow2(xs, 1); bnds[n].cys := FloorDivPow2(ys, 1);
    bnds[n].cxe := FloorDivPow2(xe, 1); bnds[n].cye := FloorDivPow2(ye, 1);
    bnds[n].locxs := locxs + nxe - nxs; bnds[n].locys := locys + nye - nys;
    bnds[n].orient := ORIENT_HH; Inc(n);
  end
  else
  begin
    bnds[n].cxs := xs; bnds[n].cys := ys; bnds[n].cxe := xe; bnds[n].cye := ye;
    bnds[n].locxs := locxs; bnds[n].locys := locys;
    bnds[n].orient := ORIENT_LL; Inc(n);
  end;
end;

// ============================================================ decoder ===

// Coding-pass segment length/type (jpc_t1cod JPC_SEGPASSCNT / JPC_SEGTYPE,
// decoder form with an effectively unbounded pass count).
function SegPassCnt(passno, firstpassno, cbsty: Integer): Integer;
begin
  if (cbsty and COX_TERMALL) <> 0 then Result := 1
  else if (cbsty and COX_LAZY) <> 0 then
  begin
    if passno < firstpassno + 10 then Result := 10 - (passno - firstpassno)
    else if (passno mod 3) = 1 then Result := 2   // SIG
    else Result := 1;                             // REF or CLN
  end
  else Result := 32 * 3 - 2;                       // JPC_PREC*3 - 2
end;

function SegIsRaw(passno, firstpassno, cbsty: Integer): Boolean;
begin
  if (cbsty and COX_LAZY) <> 0 then
  begin
    if (passno mod 3) = 0 then Result := False     // cleanup always MQ
    else Result := passno >= firstpassno + 10;
  end
  else
    Result := False;
end;

function DecodeGeneralJpc(const Bytes: TBytes): TJp2kImage;
var
  ms: TMemStream;
  marker, seglen, segend, i, c, r, bno, p, k, x, y, scod: Integer;
  W, H, NumComps, L: Integer;
  XOsiz, YOsiz, XTsiz, YTsiz, XTOsiz, YTOsiz: Integer;
  numtilesX, numtilesY, ntiles, tnum, tcol, trow: Integer;
  curTx0, curTy0, curTx1, curTy1: Integer;          // current tile reference coords
  tilebody: array of TBytes;                        // accumulated packet data per tile
  isot, psot, sotmarkpos, dpos, m2, l2: Integer;
  prec, hsamp, vsamp, roishift: TIntArray;
  reversible, mct: Boolean;
  prog, numlayers, cbwexp, cbhexp, cbsty: Integer;
  usesop, useeph: Boolean;
  prcwe, prche: TIntArray;
  q, ncomp_q, w16, numgbits, qstyleMain, numbands: Integer;
  numbps, stepw: array of TIntArray;
  defbps, defstepw: TIntArray;
  step: Double;
  comps: array of TGCo;
  bnds: array of TBandCoord;
  nbnd: Integer;
  body: TMemStream;
  pkts: array of TPktRef;
  npk: Integer;
  Img: TJp2kImage;
  mis: array of TIntMatrix;
  mds: array of TDblMatrix;
  shift, v: Integer;

  procedure BuildRes(ci, ri: Integer);
  var
    rl: ^TGRl;
    bdi, bndidx, prccnt, prcno, hcnt: Integer;
    tlpx, tlpy, brpx, brpy, tlcbgx, tlcbgy, brcbgx: Integer;
    cbgx, cbgy, cbgxe, cbgye: Integer;
    tlcbx, tlcby, brcbx, brcby, cbx, cby, cbxe, cbye: Integer;
    txs, tys, txe, tye, ci2, cbi: Integer;
  begin
    rl := @comps[ci].rl[ri];
    rl^.xs := CeilDivPow2(comps[ci].tcx0, L - ri);
    rl^.ys := CeilDivPow2(comps[ci].tcy0, L - ri);
    rl^.xe := CeilDivPow2(comps[ci].tcx1, L - ri);
    rl^.ye := CeilDivPow2(comps[ci].tcy1, L - ri);
    rl^.prcwe := prcwe[ri]; rl^.prche := prche[ri];
    tlpx := FloorDivPow2(rl^.xs, rl^.prcwe) shl rl^.prcwe;
    tlpy := FloorDivPow2(rl^.ys, rl^.prche) shl rl^.prche;
    brpx := CeilDivPow2(rl^.xe, rl^.prcwe) shl rl^.prcwe;
    brpy := CeilDivPow2(rl^.ye, rl^.prche) shl rl^.prche;
    rl^.nhp := (brpx - tlpx) shr rl^.prcwe;
    rl^.nvp := (brpy - tlpy) shr rl^.prche;
    rl^.np := rl^.nhp * rl^.nvp;
    rl^.nb := 0;
    if (rl^.xs >= rl^.xe) or (rl^.ys >= rl^.ye) then
    begin
      rl^.np := 0; rl^.nhp := 0; rl^.nvp := 0; Exit;
    end;
    if ri = 0 then
    begin
      tlcbgx := tlpx; tlcbgy := tlpy; brcbgx := brpx;
      rl^.cbgwe := rl^.prcwe; rl^.cbghe := rl^.prche;
    end
    else
    begin
      tlcbgx := CeilDivPow2(tlpx, 1); tlcbgy := CeilDivPow2(tlpy, 1);
      brcbgx := CeilDivPow2(brpx, 1);
      rl^.cbgwe := rl^.prcwe - 1; rl^.cbghe := rl^.prche - 1;
    end;
    rl^.cbwe := MinI(cbwexp, rl^.cbgwe);
    rl^.cbhe := MinI(cbhexp, rl^.cbghe);
    if ri = 0 then rl^.nb := 1 else rl^.nb := 3;
    SetLength(rl^.bd, rl^.nb);

    for bdi := 0 to rl^.nb - 1 do
    begin
      if ri = 0 then bndidx := 0 else bndidx := 3 * (ri - 1) + 1 + bdi;
      rl^.bd[bdi].orient := bnds[bndidx].orient;
      rl^.bd[bdi].bndno := bndidx;
      rl^.bd[bdi].cxs := bnds[bndidx].cxs; rl^.bd[bdi].cys := bnds[bndidx].cys;
      rl^.bd[bdi].cxe := bnds[bndidx].cxe; rl^.bd[bdi].cye := bnds[bndidx].cye;
      rl^.bd[bdi].locx := bnds[bndidx].locxs; rl^.bd[bdi].locy := bnds[bndidx].locys;
      rl^.bd[bdi].present := (bnds[bndidx].cxs < bnds[bndidx].cxe) and
                             (bnds[bndidx].cys < bnds[bndidx].cye);
      SetLength(rl^.bd[bdi].pr, rl^.np);
      if not rl^.bd[bdi].present then Continue;

      cbgx := tlcbgx; cbgy := tlcbgy;
      for prccnt := 0 to rl^.np - 1 do
      begin
        cbgxe := cbgx + (1 shl rl^.cbgwe);
        cbgye := cbgy + (1 shl rl^.cbghe);
        txs := MaxI(cbgx, rl^.bd[bdi].cxs);
        tys := MaxI(cbgy, rl^.bd[bdi].cys);
        txe := MinI(cbgxe, rl^.bd[bdi].cxe);
        tye := MinI(cbgye, rl^.bd[bdi].cye);
        if (txe > txs) and (tye > tys) then
        begin
          tlcbx := FloorDivPow2(txs, rl^.cbwe) shl rl^.cbwe;
          tlcby := FloorDivPow2(tys, rl^.cbhe) shl rl^.cbhe;
          brcbx := CeilDivPow2(txe, rl^.cbwe) shl rl^.cbwe;
          brcby := CeilDivPow2(tye, rl^.cbhe) shl rl^.cbhe;
          rl^.bd[bdi].pr[prccnt].nh := (brcbx - tlcbx) shr rl^.cbwe;
          rl^.bd[bdi].pr[prccnt].nv := (brcby - tlcby) shr rl^.cbhe;
          rl^.bd[bdi].pr[prccnt].nc := rl^.bd[bdi].pr[prccnt].nh * rl^.bd[bdi].pr[prccnt].nv;
          rl^.bd[bdi].pr[prccnt].incl := TTagTree.Create(rl^.bd[bdi].pr[prccnt].nh, rl^.bd[bdi].pr[prccnt].nv);
          rl^.bd[bdi].pr[prccnt].imsb := TTagTree.Create(rl^.bd[bdi].pr[prccnt].nh, rl^.bd[bdi].pr[prccnt].nv);
          SetLength(rl^.bd[bdi].pr[prccnt].cb, rl^.bd[bdi].pr[prccnt].nc);
          cbx := cbgx; cby := cbgy; cbi := 0;
          while cbi < rl^.bd[bdi].pr[prccnt].nc do
          begin
            cbxe := cbx + (1 shl rl^.cbwe);
            cbye := cby + (1 shl rl^.cbhe);
            if (MinI(cbxe, txe) > MaxI(cbx, txs)) and (MinI(cbye, tye) > MaxI(cby, tys)) then
            begin
              rl^.bd[bdi].pr[prccnt].cb[cbi].cx0 := MaxI(cbx, txs);
              rl^.bd[bdi].pr[prccnt].cb[cbi].cy0 := MaxI(cby, tys);
              rl^.bd[bdi].pr[prccnt].cb[cbi].cx1 := MinI(cbxe, txe);
              rl^.bd[bdi].pr[prccnt].cb[cbi].cy1 := MinI(cbye, tye);
              rl^.bd[bdi].pr[prccnt].cb[cbi].numpasses := 0;
              rl^.bd[bdi].pr[prccnt].cb[cbi].numimsbs := 0;
              rl^.bd[bdi].pr[prccnt].cb[cbi].numlenbits := 3;
              rl^.bd[bdi].pr[prccnt].cb[cbi].firstpassno := 0;
              rl^.bd[bdi].pr[prccnt].cb[cbi].nsegs := 0;
              Inc(cbi);
            end;
            cbx := cbx + (1 shl rl^.cbwe);
            if cbx >= cbgxe then begin cbx := cbgx; cby := cby + (1 shl rl^.cbhe); end;
          end;
        end
        else
          rl^.bd[bdi].pr[prccnt].nc := 0;
        cbgx := cbgx + (1 shl rl^.cbgwe);
        if cbgx >= brcbgx then begin cbgx := tlcbgx; cbgy := cbgy + (1 shl rl^.cbghe); end;
      end;
    end;
  end;

  procedure AddPkt(cc, rr, pp, ll: Integer);
  begin
    if npk >= Length(pkts) then SetLength(pkts, (npk + 1) * 2);
    pkts[npk].c := cc; pkts[npk].r := rr; pkts[npk].prc := pp; pkts[npk].lyr := ll;
    Inc(npk);
  end;

  procedure BuildOrder;
  var
    lyr, res, cc, prc, yy, xx, xstep, ystep, rr2, rpx, rpy, e, sx, sy: Integer;
    prchind, prcvind, prcno: Integer;

    procedure SpatialAt(cc, res, xx, yy: Integer);
    var rr, hs2, vs2, rpx, rpy, ph, pv, pno, lyr2, trx0, try0: Integer;
        selx, sely: Boolean;
    begin
      if res >= comps[cc].nrl then Exit;
      if comps[cc].rl[res].np = 0 then Exit;
      rr := comps[cc].nrl - 1 - res; hs2 := comps[cc].hs; vs2 := comps[cc].vs;
      trx0 := CeilDiv(curTx0, hs2 shl rr); try0 := CeilDiv(curTy0, vs2 shl rr);
      rpx := rr + comps[cc].rl[res].prcwe; rpy := rr + comps[cc].rl[res].prche;
      selx := ((xx = curTx0) and (((trx0 shl rr) mod (1 shl rpx)) <> 0)) or ((xx mod (hs2 shl rpx)) = 0);
      sely := ((yy = curTy0) and (((try0 shl rr) mod (1 shl rpy)) <> 0)) or ((yy mod (vs2 shl rpy)) = 0);
      if selx and sely then
      begin
        ph := FloorDivPow2(CeilDiv(xx, hs2 shl rr), comps[cc].rl[res].prcwe) - FloorDivPow2(trx0, comps[cc].rl[res].prcwe);
        pv := FloorDivPow2(CeilDiv(yy, vs2 shl rr), comps[cc].rl[res].prche) - FloorDivPow2(try0, comps[cc].rl[res].prche);
        pno := pv * comps[cc].rl[res].nhp + ph;
        if (pno >= 0) and (pno < comps[cc].rl[res].np) then
          for lyr2 := 0 to numlayers - 1 do AddPkt(cc, res, pno, lyr2);
      end;
    end;

  begin
    npk := 0; SetLength(pkts, 64);
    xstep := 0; ystep := 0;
    for cc := 0 to NumComps - 1 do
      for res := 0 to L do
      begin
        e := comps[cc].hs * (1 shl (prcwe[res] + (L + 1) - res - 1));
        if (xstep = 0) or (e < xstep) then xstep := e;
        e := comps[cc].vs * (1 shl (prche[res] + (L + 1) - res - 1));
        if (ystep = 0) or (e < ystep) then ystep := e;
      end;
    if xstep <= 0 then xstep := 1;
    if ystep <= 0 then ystep := 1;

    case prog of
      0:
        for lyr := 0 to numlayers - 1 do
          for res := 0 to L do
            for cc := 0 to NumComps - 1 do
              if res < comps[cc].nrl then
                for prc := 0 to comps[cc].rl[res].np - 1 do AddPkt(cc, res, prc, lyr);
      1:
        for res := 0 to L do
          for lyr := 0 to numlayers - 1 do
            for cc := 0 to NumComps - 1 do
              if res < comps[cc].nrl then
                for prc := 0 to comps[cc].rl[res].np - 1 do AddPkt(cc, res, prc, lyr);
      2:
        for res := 0 to L do
        begin
          yy := curTy0;
          while yy < curTy1 do
          begin
            xx := curTx0;
            while xx < curTx1 do
            begin
              for cc := 0 to NumComps - 1 do SpatialAt(cc, res, xx, yy);
              sx := xstep - (xx mod xstep); xx := xx + sx;
            end;
            sy := ystep - (yy mod ystep); yy := yy + sy;
          end;
        end;
      3:
        begin
          yy := curTy0;
          while yy < curTy1 do
          begin
            xx := curTx0;
            while xx < curTx1 do
            begin
              for cc := 0 to NumComps - 1 do
                for res := 0 to comps[cc].nrl - 1 do SpatialAt(cc, res, xx, yy);
              sx := xstep - (xx mod xstep); xx := xx + sx;
            end;
            sy := ystep - (yy mod ystep); yy := yy + sy;
          end;
        end;
      4:
        for cc := 0 to NumComps - 1 do
        begin
          yy := curTy0;
          while yy < curTy1 do
          begin
            xx := curTx0;
            while xx < curTx1 do
            begin
              for res := 0 to comps[cc].nrl - 1 do SpatialAt(cc, res, xx, yy);
              sx := xstep - (xx mod xstep); xx := xx + sx;
            end;
            sy := ystep - (yy mod ystep); yy := yy + sy;
          end;
        end;
    end;
  end;

  procedure DecodePkts;
  var
    pi, present, bi, cbi, included, numnew, m, len, lyr: Integer;
    rl: ^TGRl; bd: ^TGBd; pr: ^TGPr; cb: ^TGCb;
    bs: TBitStream;
    cc, rr, pp, ci2: Integer;
    pktcbN: Integer;
    pktcb: array of TPktCb;
    j, oldlen, rem, passno, segidx, n: Integer;
    p0, b1, b2: Integer;
  begin
    for pi := 0 to npk - 1 do
    begin
      cc := pkts[pi].c; rr := pkts[pi].r; pp := pkts[pi].prc; lyr := pkts[pi].lyr;
      rl := @comps[cc].rl[rr];
      if pp >= rl^.np then Continue;
      // SOP marker segment (ff91 0004 Nsop) may precede each packet.
      if usesop and (body.Position + 6 <= body.Size) then
      begin
        p0 := body.Position;
        b1 := body.GetC; b2 := body.GetC;
        if (b1 = $ff) and (b2 = $91) then
          body.Seek(p0 + 6, SEEK_SET)
        else
          body.Seek(p0, SEEK_SET);
      end;
      bs := TBitStream.Create(body, False);
      pktcbN := 0; SetLength(pktcb, 16);
      present := bs.GetBit;
      if present > 0 then
      begin
        for bi := 0 to rl^.nb - 1 do
        begin
          bd := @rl^.bd[bi];
          if not bd^.present then Continue;
          pr := @bd^.pr[pp];
          for cbi := 0 to pr^.nc - 1 do
          begin
            cb := @pr^.cb[cbi];
            if cb^.numpasses = 0 then
              included := pr^.incl.Decode(pr^.incl.GetLeaf(cbi), lyr + 1, bs)
            else
              included := bs.GetBit;
            if included <= 0 then Continue;
            if cb^.numpasses = 0 then
            begin
              m := 1;
              while pr^.imsb.Decode(pr^.imsb.GetLeaf(cbi), m, bs) = 0 do Inc(m);
              cb^.numimsbs := m - 1;
              cb^.firstpassno := cb^.numimsbs * 3;
            end;
            numnew := GetNumNewPasses(bs);
            m := GetCommaCode(bs);
            cb^.numlenbits := cb^.numlenbits + m;
            // split the new passes into coding-pass segments
            rem := numnew;
            while rem > 0 do
            begin
              passno := cb^.firstpassno + cb^.numpasses;
              if (cb^.nsegs = 0) or
                 (cb^.segs[cb^.nsegs - 1].np >= cb^.segs[cb^.nsegs - 1].maxcap) then
              begin
                if cb^.nsegs >= Length(cb^.segs) then SetLength(cb^.segs, cb^.nsegs + 4);
                cb^.segs[cb^.nsegs].np := 0;
                cb^.segs[cb^.nsegs].dlen := 0;
                cb^.segs[cb^.nsegs].maxcap := SegPassCnt(passno, cb^.firstpassno, cbsty);
                cb^.segs[cb^.nsegs].raw := SegIsRaw(passno, cb^.firstpassno, cbsty);
                SetLength(cb^.segs[cb^.nsegs].data, 0);
                Inc(cb^.nsegs);
              end;
              segidx := cb^.nsegs - 1;
              n := MinI(rem, cb^.segs[segidx].maxcap - cb^.segs[segidx].np);
              len := bs.GetBits(cb^.numlenbits + Integer(FloorLog2(n)));
              cb^.segs[segidx].np := cb^.segs[segidx].np + n;
              cb^.numpasses := cb^.numpasses + n;
              rem := rem - n;
              if pktcbN >= Length(pktcb) then SetLength(pktcb, (pktcbN + 1) * 2);
              pktcb[pktcbN].bd := bi; pktcb[pktcbN].cbi := cbi;
              pktcb[pktcbN].seg := segidx; pktcb[pktcbN].len := len;
              Inc(pktcbN);
            end;
          end;
        end;
        bs.InAlign(0, 0);
      end
      else
        bs.InAlign($7f, 0);
      bs.CloseBs; bs.Free;

      // EPH marker (ff92) terminates the packet header when signalled in Scod.
      if useeph and (body.Position + 2 <= body.Size) then
      begin
        p0 := body.Position;
        b1 := body.GetC; b2 := body.GetC;
        if (b1 <> $ff) or (b2 <> $92) then
          body.Seek(p0, SEEK_SET);
      end;

      // Packet body: append each segment's bytes (read from body, in order).
      for j := 0 to pktcbN - 1 do
      begin
        cb := @rl^.bd[pktcb[j].bd].pr[pp].cb[pktcb[j].cbi];
        segidx := pktcb[j].seg;
        len := pktcb[j].len;
        oldlen := cb^.segs[segidx].dlen;
        if oldlen + len > Length(cb^.segs[segidx].data) then
          SetLength(cb^.segs[segidx].data, oldlen + len);
        for m := 0 to len - 1 do
          cb^.segs[segidx].data[oldlen + m] := body.GetC and $ff;
        cb^.segs[segidx].dlen := oldlen + len;
      end;
    end;
  end;

  procedure Reconstruct;
  var
    cc, rr, bi, prc, cbi, cbw, cbh, nb, xx, yy, mr, mc, cols: Integer;
    rl: ^TGRl; bd: ^TGBd; pr: ^TGPr; cb: ^TGCb;
    cdata: TIntArray;
    bytesz: TBytes;
    abss: Double; thresh, mag, val: Integer;
  begin
    if reversible then SetLength(mis, NumComps) else SetLength(mds, NumComps);
    for cc := 0 to NumComps - 1 do
    begin
      cols := comps[cc].tcx1 - comps[cc].tcx0;
      if reversible then
      begin
        mis[cc] := TIntMatrix.Create(comps[cc].tcy1 - comps[cc].tcy0, cols);
        mis[cc].Clear;
      end
      else
      begin
        mds[cc] := TDblMatrix.Create(comps[cc].tcy1 - comps[cc].tcy0, cols);
        mds[cc].Clear;
      end;
      for rr := 0 to comps[cc].nrl - 1 do
      begin
        rl := @comps[cc].rl[rr];
        for bi := 0 to rl^.nb - 1 do
        begin
          bd := @rl^.bd[bi];
          if not bd^.present then Continue;
          nb := 0;
          abss := StepAbs(stepw[cc][bd^.bndno], prec[cc]);
          for prc := 0 to rl^.np - 1 do
          begin
            pr := @bd^.pr[prc];
            for cbi := 0 to pr^.nc - 1 do
            begin
              cb := @pr^.cb[cbi];
              if cb^.numpasses <= 0 then Continue;
              cbw := cb^.cx1 - cb^.cx0; cbh := cb^.cy1 - cb^.cy0;
              nb := numbps[cc][bd^.bndno] - cb^.numimsbs;
              T1DecodeSeg(Copy(cb^.segs, 0, cb^.nsegs), cbw, cbh, bd^.orient, nb, cbsty, cdata);
              // ROI maxshift undo on integer indices.
              if roishift[cc] > 0 then
              begin
                thresh := 1 shl roishift[cc];
                for yy := 0 to cbw * cbh - 1 do
                begin
                  val := cdata[yy]; mag := Abs(val);
                  if mag >= thresh then
                  begin
                    mag := mag shr roishift[cc];
                    if val < 0 then cdata[yy] := -mag else cdata[yy] := mag;
                  end;
                end;
              end;
              for yy := 0 to cbh - 1 do
                for xx := 0 to cbw - 1 do
                begin
                  mc := bd^.locx + (cb^.cx0 - bd^.cxs) + xx;
                  mr := bd^.locy + (cb^.cy0 - bd^.cys) + yy;
                  if reversible then
                    mis[cc].Data[mr * cols + mc] := cdata[yy * cbw + xx]
                  else
                  begin
                    val := cdata[yy * cbw + xx];
                    if qstyleMain <> 0 then
                    begin
                      if val > 0 then mds[cc].Data[mr * cols + mc] := (val + 0.5) * abss
                      else if val < 0 then mds[cc].Data[mr * cols + mc] := (val - 0.5) * abss
                      else mds[cc].Data[mr * cols + mc] := 0;
                    end
                    else
                      mds[cc].Data[mr * cols + mc] := val * step;
                  end;
                end;
            end;
          end;
        end;
      end;
      if reversible then Inv53Org(mis[cc], L, comps[cc].tcx0, comps[cc].tcy0)
      else Inv97Org(mds[cc], L, comps[cc].tcx0, comps[cc].tcy0);
    end;

    if (NumComps >= 3) and mct then
    begin
      if reversible then IRCT(mis[0], mis[1], mis[2]) else IICT(mds[0], mds[1], mds[2]);
    end;

    // Img is preallocated by the caller; write this tile's region.
    for cc := 0 to NumComps - 1 do
    begin
      shift := 1 shl (prec[cc] - 1);
      cols := comps[cc].tcx1 - comps[cc].tcx0;
      for yy := 0 to (comps[cc].tcy1 - comps[cc].tcy0) - 1 do
        for xx := 0 to cols - 1 do
        begin
          if reversible then v := mis[cc].Data[yy * cols + xx] + shift
          else v := Round(mds[cc].Data[yy * cols + xx]) + shift;
          if v < 0 then v := 0;
          if v > (1 shl prec[cc]) - 1 then v := (1 shl prec[cc]) - 1;
          Img.Comps[cc][(comps[cc].tcy0 + yy) * W + (comps[cc].tcx0 + xx)] := v;
        end;
      if reversible then mis[cc].Free else mds[cc].Free;
    end;
  end;

begin
  ms := TMemStream.Create(Bytes, Length(Bytes));
  W := 0; H := 0; NumComps := 1; L := 1; reversible := True; mct := False;
  prog := 0; numlayers := 1; cbwexp := 6; cbhexp := 6; cbsty := 0;
  usesop := False; useeph := False;
  numbands := 0; qstyleMain := 0; step := 1.0;
  SetLength(defbps, 0); SetLength(defstepw, 0); SetLength(prcwe, 0);

  XOsiz := 0; YOsiz := 0; XTsiz := 0; YTsiz := 0; XTOsiz := 0; YTOsiz := 0;
  if RU16(ms) <> MS_SOC then raise EJp2kError.Create('no SOC');
  while True do
  begin
    marker := RU16(ms);
    if (marker = MS_SOT) or (marker = MS_EOC) or (marker < 0) then Break;
    seglen := RU16(ms);
    segend := ms.Position + seglen - 2;
    case marker of
      MS_SIZ:
        begin
          RU16(ms);
          W := RU32(ms); H := RU32(ms);
          XOsiz := RU32(ms); YOsiz := RU32(ms);
          XTsiz := RU32(ms); YTsiz := RU32(ms);
          XTOsiz := RU32(ms); YTOsiz := RU32(ms);
          NumComps := RU16(ms);
          SetLength(prec, NumComps); SetLength(hsamp, NumComps);
          SetLength(vsamp, NumComps); SetLength(roishift, NumComps);
          for c := 0 to NumComps - 1 do
          begin
            prec[c] := (ms.GetC and $7f) + 1;
            hsamp[c] := ms.GetC; vsamp[c] := ms.GetC; roishift[c] := 0;
          end;
        end;
      MS_COD:
        begin
          scod := ms.GetC;
          usesop := (scod and 2) <> 0;   // SOP marker before packets
          useeph := (scod and 4) <> 0;   // EPH marker after packet headers
          prog := ms.GetC;
          numlayers := RU16(ms);
          mct := ms.GetC <> 0;
          L := ms.GetC;
          cbwexp := ms.GetC + 2; cbhexp := ms.GetC + 2;
          cbsty := ms.GetC;
          reversible := ms.GetC <> 0;
          numbands := 1 + 3 * L;
          SetLength(prcwe, L + 1); SetLength(prche, L + 1);
          if (scod and 1) <> 0 then
            for i := 0 to L do
            begin
              k := ms.GetC; prcwe[i] := k and $0f; prche[i] := (k shr 4) and $0f;
            end
          else
            for i := 0 to L do begin prcwe[i] := 15; prche[i] := 15; end;
        end;
      MS_QCD:
        begin
          if numbands = 0 then numbands := 1 + 3 * L;
          SetLength(defbps, numbands); SetLength(defstepw, numbands);
          q := ms.GetC; qstyleMain := q and $1f; numgbits := q shr 5;
          if qstyleMain = 0 then
            for bno := 0 to numbands - 1 do
            begin
              if ms.Position >= segend then Break;
              k := ms.GetC shr 3; defbps[bno] := numgbits + k - 1; defstepw[bno] := k shl 11;
            end
          else
            for bno := 0 to numbands - 1 do
            begin
              if ms.Position >= segend then Break;
              w16 := RU16(ms); defbps[bno] := numgbits + (w16 shr 11) - 1; defstepw[bno] := w16;
            end;
        end;
      MS_QCC:
        begin
          if NumComps < 257 then ncomp_q := ms.GetC else ncomp_q := RU16(ms);
          if Length(numbps) = 0 then
          begin
            SetLength(numbps, NumComps); SetLength(stepw, NumComps);
            for c := 0 to NumComps - 1 do
            begin
              SetLength(numbps[c], numbands); SetLength(stepw[c], numbands);
              for bno := 0 to numbands - 1 do
                if bno < Length(defbps) then begin numbps[c][bno] := defbps[bno]; stepw[c][bno] := defstepw[bno]; end;
            end;
          end;
          if (ncomp_q >= 0) and (ncomp_q < NumComps) then
          begin
            q := ms.GetC; qstyleMain := q and $1f; numgbits := q shr 5;
            if qstyleMain = 0 then
              for bno := 0 to numbands - 1 do
              begin
                if ms.Position >= segend then Break;
                k := ms.GetC shr 3; numbps[ncomp_q][bno] := numgbits + k - 1; stepw[ncomp_q][bno] := k shl 11;
              end
            else
              for bno := 0 to numbands - 1 do
              begin
                if ms.Position >= segend then Break;
                w16 := RU16(ms); numbps[ncomp_q][bno] := numgbits + (w16 shr 11) - 1; stepw[ncomp_q][bno] := w16;
              end;
          end;
        end;
      MS_RGN:
        begin
          if NumComps < 257 then c := ms.GetC else c := RU16(ms);
          ms.GetC;
          if (c >= 0) and (c < NumComps) then roishift[c] := ms.GetC else ms.GetC;
        end;
      MS_COM:
        if RU16(ms) = 1 then step := RDbl(ms);
    end;
    ms.Seek(segend, SEEK_SET);
  end;

  if Length(numbps) = 0 then
  begin
    SetLength(numbps, NumComps); SetLength(stepw, NumComps);
    for c := 0 to NumComps - 1 do
    begin
      SetLength(numbps[c], numbands); SetLength(stepw[c], numbands);
      for bno := 0 to numbands - 1 do
        if bno < Length(defbps) then begin numbps[c][bno] := defbps[bno]; stepw[c][bno] := defstepw[bno]; end;
    end;
  end;

  for c := 0 to NumComps - 1 do
    if (hsamp[c] <> 1) or (vsamp[c] <> 1) then
      raise EJp2kError.Create('component subsampling not supported');
  if (XOsiz <> 0) or (YOsiz <> 0) then
    raise EJp2kError.Create('nonzero image offset not supported');

  if XTsiz <= 0 then XTsiz := W;
  if YTsiz <= 0 then YTsiz := H;
  numtilesX := CeilDiv(W - XTOsiz, XTsiz);
  numtilesY := CeilDiv(H - YTOsiz, YTsiz);
  ntiles := numtilesX * numtilesY;
  SetLength(tilebody, ntiles);

  // ---- collect packet data per tile (marker currently = first SOT) ----
  while marker = MS_SOT do
  begin
    sotmarkpos := ms.Position - 2;            // position of the FF90 marker
    RU16(ms);                                 // Lsot
    isot := RU16(ms);
    psot := Integer(RU32(ms));
    ms.GetC; ms.GetC;                         // TPsot, TNsot
    while True do                             // skip tile-part header to SOD
    begin
      m2 := RU16(ms);
      if (m2 = MS_SOD) or (m2 = MS_EOC) or (m2 < 0) then Break;
      l2 := RU16(ms);
      ms.Seek(ms.Position + l2 - 2, SEEK_SET);
    end;
    dpos := ms.Position;                      // first packet byte
    if psot > 0 then
      k := sotmarkpos + psot
    else
    begin
      k := dpos;
      while k + 1 < Length(Bytes) do
      begin
        if (Bytes[k] = $ff) and ((Bytes[k + 1] = $90) or (Bytes[k + 1] = $d9)) then Break;
        Inc(k);
      end;
      if k + 1 >= Length(Bytes) then k := Length(Bytes);
    end;
    if k > Length(Bytes) then k := Length(Bytes);
    if (isot >= 0) and (isot < ntiles) and (k > dpos) then
    begin
      i := Length(tilebody[isot]);
      SetLength(tilebody[isot], i + (k - dpos));
      Move(Bytes[dpos], tilebody[isot][i], k - dpos);
    end;
    ms.Seek(k, SEEK_SET);
    if ms.Position + 1 >= Length(Bytes) then Break;
    marker := RU16(ms);
  end;

  // ---- decode each tile into its region of the image ----
  Img := TJp2kImage.Create(W, H, NumComps, prec[0]);
  SetLength(bnds, 1 + 3 * L);
  for tnum := 0 to ntiles - 1 do
  begin
    tcol := tnum mod numtilesX; trow := tnum div numtilesX;
    curTx0 := XTOsiz + tcol * XTsiz; if curTx0 < 0 then curTx0 := 0;
    curTy0 := YTOsiz + trow * YTsiz; if curTy0 < 0 then curTy0 := 0;
    curTx1 := MinI(curTx0 + XTsiz, W);
    curTy1 := MinI(curTy0 + YTsiz, H);
    SetLength(comps, NumComps);
    for c := 0 to NumComps - 1 do
    begin
      comps[c].hs := hsamp[c]; comps[c].vs := vsamp[c];
      comps[c].tcx0 := CeilDiv(curTx0, hsamp[c]); comps[c].tcy0 := CeilDiv(curTy0, vsamp[c]);
      comps[c].tcx1 := CeilDiv(curTx1, hsamp[c]); comps[c].tcy1 := CeilDiv(curTy1, vsamp[c]);
      comps[c].nrl := L + 1;
      SetLength(comps[c].rl, L + 1);
      nbnd := 0;
      GGetBands(0, 0, comps[c].tcx0, comps[c].tcy0, comps[c].tcx1, comps[c].tcy1, L, bnds, nbnd);
      for r := 0 to L do BuildRes(c, r);
    end;
    body := TMemStream.Create(tilebody[tnum], Length(tilebody[tnum]));
    BuildOrder;
    DecodePkts;
    Reconstruct;
    body.Free;
  end;

  ms.Free;
  Result := Img;
end;

function DecodeGeneral(const Bytes: TBytes): TJp2kImage;
begin
  if IsJp2(Bytes) then Result := DecodeGeneralJpc(UnwrapJp2(Bytes))
  else Result := DecodeGeneralJpc(Bytes);
end;

end.
