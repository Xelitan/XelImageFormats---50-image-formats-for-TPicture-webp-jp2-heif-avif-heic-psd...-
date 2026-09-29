// JPEG 2000 based on JASPER 4.2.9
// License: JasPer-2.0 (similar to MIT )
// Author: www.xelitan.com
//
// JP2KCodec - codestream driver: encoder + decoder (analogue of jpc_enc.c /
// jpc_dec.c, greatly simplified).
//
// Pipeline (single tile = whole image, single quality layer, one precinct per
// resolution level, RLCP order, code-blocks 64x64):
//
//    encode:  level shift -> [MCT] -> per-component DWT -> [quantise] ->
//             split into code-blocks -> tier-1 -> tier-2 packets -> markers
//    decode:  markers -> tier-2 -> tier-1 -> scatter -> inverse DWT ->
//             [inverse MCT] -> inverse level shift
//
// Reversible mode  = 5/3 wavelet + RCT  (lossless).
// Irreversible mode = 9/7 wavelet + ICT (lossy; uniform scalar quantiser).
//
// The codestream uses the real JPEG 2000 marker codes (SOC/SIZ/COD/QCD/SOT/
// SOD/EOC) with compact, self-consistent payloads; it is structurally a valid
// marker-segmented codestream but the QCD payload layout is our own (it carries
// each band's bit-plane count directly) and is not byte-compatible with a
// conformant JPEG 2000 decoder.  All multi-byte fields are big-endian.

unit JP2KCodec;

{$mode delphi}
{$H+}

interface

uses
  SysUtils, JP2KCommon, JP2KMatrix, JP2KMCT, JP2KWavelet, JP2KT1, JP2KT2,
  JP2KTagTree, JP2KBS;

type
  TJp2kImage = class
  public
    W, H, NumComps, Prec: Integer;
    Comps: array of TIntArray;    // NumComps arrays of W*H samples (unsigned)
    constructor Create(AW, AH, ANumComps, APrec: Integer);
  end;

  TEncodeOptions = record
    Reversible: Boolean;   // True = lossless 5/3+RCT; False = lossy 9/7+ICT
    NumLevels: Integer;    // DWT decomposition levels (0 => auto)
    UseMct: Boolean;       // apply colour transform when NumComps = 3
    Step: Double;          // quantiser step for irreversible mode (>0)
  end;

function DefaultEncodeOptions: TEncodeOptions;

function EncodeToJpc(Img: TJp2kImage; const Opt: TEncodeOptions): TBytes;
function DecodeFromJpc(const Bytes: TBytes): TJp2kImage;

// JP2 file-format (box) wrapper.
function IsJp2(const Bytes: TBytes): Boolean;
// Wrap a raw codestream in a minimal, conformant JP2 box structure
// (Signature + File Type + JP2 Header[Image Header + Colour Spec] + Codestream).
function WrapJp2(const Jpc: TBytes; W, H, NumComps, Prec: Integer): TBytes;
// Extract the contiguous codestream (jp2c box) from a JP2 file.
function UnwrapJp2(const Bytes: TBytes): TBytes;

// Encode straight to a .jp2 file (codestream wrapped in JP2 boxes).
function EncodeToJp2(Img: TJp2kImage; const Opt: TEncodeOptions): TBytes;
// Decode either a raw .jpc codestream or a .jp2 file (auto-detected).
function DecodeAny(const Bytes: TBytes): TJp2kImage;

// Decode a *standard* reversible (5/3) JPEG 2000 raw codestream as produced by
// a conformant encoder such as JasPer (jasper -T jpc -O mode=int). Supports the
// single-tile case with no precinct partitions, SOP/EPH off. Raises EJp2kError
// on an irreversible or otherwise unsupported codestream. This demonstrates
// that the tier-1/tier-2/5-3 pipeline here is format-compatible with JasPer.
function DecodeJpcStandard(const Bytes: TBytes): TJp2kImage;

implementation

const
  MS_SOC = $ff4f;
  MS_SOT = $ff90;
  MS_SOD = $ff93;
  MS_EOC = $ffd9;
  MS_SIZ = $ff51;
  MS_COD = $ff52;
  MS_QCD = $ff5c;
  MS_QCC = $ff5d;
  MS_COC = $ff53;
  MS_COM = $ff64;

  CBLK = 64;             // nominal code-block size

type
  TBandRect = record
    Res, Orient, X0, Y0, X1, Y1: Integer;
  end;
  TBandRects = array of TBandRect;

constructor TJp2kImage.Create(AW, AH, ANumComps, APrec: Integer);
var
  c: Integer;
begin
  inherited Create;
  W := AW; H := AH; NumComps := ANumComps; Prec := APrec;
  SetLength(Comps, NumComps);
  for c := 0 to NumComps - 1 do
    SetLength(Comps[c], W * H);
end;

function DefaultEncodeOptions: TEncodeOptions;
begin
  Result.Reversible := True;
  Result.NumLevels := 0;
  Result.UseMct := True;
  Result.Step := 1.0;
end;

// Resolution-level extent.
function ResW(W, L, r: Integer): Integer; inline;
begin
  Result := CeilDivPow2(W, L - r);
end;

function ResH(H, L, r: Integer): Integer; inline;
begin
  Result := CeilDivPow2(H, L - r);
end;

// Enumerate the subbands of a (W,H) image transformed with L levels, in the
// order LL(res0), then for res 1..L the HL, LH, HH bands.
function EnumBands(W, H, L: Integer): TBandRects;
var
  r, llw, llh, fw, fh, n: Integer;

  procedure Add(res, orient, x0, y0, x1, y1: Integer);
  begin
    SetLength(Result, n + 1);
    Result[n].Res := res; Result[n].Orient := orient;
    Result[n].X0 := x0; Result[n].Y0 := y0; Result[n].X1 := x1; Result[n].Y1 := y1;
    Inc(n);
  end;

begin
  n := 0;
  SetLength(Result, 0);
  Add(0, ORIENT_LL, 0, 0, ResW(W, L, 0), ResH(H, L, 0));
  for r := 1 to L do
  begin
    llw := ResW(W, L, r - 1); llh := ResH(H, L, r - 1);
    fw := ResW(W, L, r);      fh := ResH(H, L, r);
    Add(r, ORIENT_HL, llw, 0,   fw,  llh);
    Add(r, ORIENT_LH, 0,   llh, llw, fh);
    Add(r, ORIENT_HH, llw, llh, fw,  fh);
  end;
end;

// ---- big-endian stream helpers ----

procedure PutU16(ms: TMemStream; v: Integer);
begin
  ms.PutC((v shr 8) and $ff);
  ms.PutC(v and $ff);
end;

procedure PutU32(ms: TMemStream; v: LongWord);
begin
  ms.PutC((v shr 24) and $ff);
  ms.PutC((v shr 16) and $ff);
  ms.PutC((v shr 8) and $ff);
  ms.PutC(v and $ff);
end;

function GetU16(ms: TMemStream): Integer;
var
  a, b: Integer;
begin
  a := ms.GetC; b := ms.GetC;
  Result := (a shl 8) or b;
end;

function GetU32(ms: TMemStream): LongWord;
var
  a, b, c, d: Integer;
begin
  a := ms.GetC; b := ms.GetC; c := ms.GetC; d := ms.GetC;
  Result := (LongWord(a) shl 24) or (LongWord(b) shl 16) or (LongWord(c) shl 8) or LongWord(d);
end;

procedure PutDbl(ms: TMemStream; v: Double);
var
  q: Int64 absolute v;
begin
  PutU32(ms, (q shr 32) and $ffffffff);
  PutU32(ms, q and $ffffffff);
end;

function GetDbl(ms: TMemStream): Double;
var
  hi, lo: LongWord;
  q: Int64;
  v: Double absolute q;
begin
  hi := GetU32(ms); lo := GetU32(ms);
  q := (Int64(hi) shl 32) or Int64(lo);
  Result := v;
end;

// Maximum magnitude bit-planes over an integer matrix sub-rectangle.
function BandNumBps(const M: TIntArray; W, x0, y0, x1, y1: Integer): Integer;
var
  x, y, mx, v: Integer;
begin
  mx := 0;
  for y := y0 to y1 - 1 do
    for x := x0 to x1 - 1 do
    begin
      v := Abs(M[y * W + x]);
      if v > mx then mx := v;
    end;
  Result := IntFirstOne(mx) + 1;
  if Result < 0 then Result := 0;
end;

// ============================================================ encode ====

// Absolute quantiser step -> 16-bit expounded QCD step word (inverse of
// StepToAbs), per ISO 15444-1 E.1 / JasPer jpc_abstorelstepsize:
//      word = (expn << 11) or mant,  expn = scaleexpn - floor(log2(delta)),
//      mant = frac(delta / 2^floor(log2 delta)) * 2^11.
// For the irreversible 9/7 transform the nominal band gain is 0, so the
// caller passes scaleexpn = precision for every band.
function StepToWord(absdelta: Double; scaleexpn: Integer): Integer;
var
  p, expn, mant: Integer;

  function P2(n: Integer): Double;
  begin
    if n >= 0 then P2 := Int64(1) shl n
    else P2 := 1.0 / (Int64(1) shl (-n));
  end;

begin
  if absdelta <= 0 then begin Result := 0; Exit; end;
  p := 0;
  while P2(p + 1) <= absdelta do Inc(p);
  while P2(p) > absdelta do Dec(p);
  mant := Trunc((absdelta / P2(p)) * 2048.0) and $7ff;   // strip leading 1
  expn := scaleexpn - p;
  if expn < 0 then expn := 0;
  if expn > 31 then expn := 31;
  Result := ((expn and $1f) shl 11) or mant;
end;

function EncodeToJpc(Img: TJp2kImage; const Opt: TEncodeOptions): TBytes;
var
  L, c, i, x, y: Integer;
  bands: TBandRects;
  coeffs: array of TIntArray;          // per component, integer DWT coefficients
  bandbps: TIntArray;                  // per band (same for all comps): numbps
  shift: Integer;
  out_, body, seg: TMemStream;
  reversible: Boolean;
  numbands: Integer;
  r, bi, cbx, cby, cbw, cbh, bx0, by0, bx1, by1, xx, yy: Integer;
  pkt: TT2Packet;
  cdata: TIntArray;
  numpasses, nb, ci, cgw, cgh: Integer;
  stepword, expn, gbits, maxbps, mb, mbb: Integer;
  mi: array of TIntMatrix;
  md: array of TDblMatrix;
begin
  reversible := Opt.Reversible;
  L := Opt.NumLevels;
  if L <= 0 then
  begin
    L := 0;
    while (MinI(Img.W, Img.H) shr (L + 1)) >= 1 do Inc(L);
    if L > 5 then L := 5;
    if L < 1 then L := 1;
  end;
  shift := 1 shl (Img.Prec - 1);

  SetLength(coeffs, Img.NumComps);
  SetLength(mi, Img.NumComps);
  SetLength(md, Img.NumComps);

  if reversible then
  begin
    // level shift into integer matrices
    for c := 0 to Img.NumComps - 1 do
    begin
      mi[c] := TIntMatrix.Create(Img.H, Img.W);
      for i := 0 to Img.W * Img.H - 1 do
        mi[c].Data[i] := Img.Comps[c][i] - shift;
    end;
    if (Img.NumComps = 3) and Opt.UseMct then
      RCT(mi[0], mi[1], mi[2]);
    for c := 0 to Img.NumComps - 1 do
    begin
      Fwd53(mi[c], L);
      coeffs[c] := mi[c].Data;
    end;
  end
  else
  begin
    for c := 0 to Img.NumComps - 1 do
    begin
      md[c] := TDblMatrix.Create(Img.H, Img.W);
      for i := 0 to Img.W * Img.H - 1 do
        md[c].Data[i] := Img.Comps[c][i] - shift;
    end;
    if (Img.NumComps = 3) and Opt.UseMct then
      ICT(md[0], md[1], md[2]);
    for c := 0 to Img.NumComps - 1 do
    begin
      Fwd97(md[c], L);
      SetLength(coeffs[c], Img.W * Img.H);
      for i := 0 to Img.W * Img.H - 1 do
        // Truncate toward zero (dead-zone quantiser) to match the mid-point
        // (q +/- 0.5)*step dequantisation used by conformant decoders.
        coeffs[c][i] := Trunc(md[c].Data[i] / Opt.Step);
    end;
  end;

  bands := EnumBands(Img.W, Img.H, L);
  numbands := Length(bands);

  // Per-band bit-plane count (max over components).
  SetLength(bandbps, numbands);
  for bi := 0 to numbands - 1 do
  begin
    nb := 0;
    for c := 0 to Img.NumComps - 1 do
      nb := MaxI(nb, BandNumBps(coeffs[c], Img.W,
        bands[bi].X0, bands[bi].Y0, bands[bi].X1, bands[bi].Y1));
    bandbps[bi] := nb;
  end;

  // Irreversible mode: derive a conformant expounded-quantiser step word
  // (one step, applied uniformly to every band) plus the guard-bit count and
  // nominal magnitude bit-depth Mb = numguard + expn - 1 that a standard
  // decoder uses.  Choose just enough guard bits that Mb covers the widest
  // band, so quantised coefficients are never truncated.
  stepword := 0; expn := 0; gbits := 2; mb := 0;
  if not reversible then
  begin
    stepword := StepToWord(Opt.Step, Img.Prec);   // gain 0 for 9/7
    expn := stepword shr 11;
    maxbps := 0;
    for bi := 0 to numbands - 1 do maxbps := MaxI(maxbps, bandbps[bi]);
    gbits := maxbps - expn + 1;
    if gbits < 1 then gbits := 1;
    if gbits > 7 then gbits := 7;
    mb := gbits + expn - 1;
  end;

  // ---- tier-1 + tier-2: encode the body (RLCP: res, then component). ----
  body := TMemStream.Create;
  for r := 0 to L do
    for c := 0 to Img.NumComps - 1 do
    begin
      // Build a packet for (component c, resolution r).
      SetLength(pkt.Bands, 0);
      for bi := 0 to numbands - 1 do
        if bands[bi].Res = r then
        begin
          SetLength(pkt.Bands, Length(pkt.Bands) + 1);
          with pkt.Bands[High(pkt.Bands)] do
          begin
            bx0 := bands[bi].X0; by0 := bands[bi].Y0;
            bx1 := bands[bi].X1; by1 := bands[bi].Y1;
            Present := (bx1 > bx0) and (by1 > by0);
            if Present then
            begin
              cgw := CeilDiv(bx1 - bx0, CBLK);
              cgh := CeilDiv(by1 - by0, CBLK);
            end
            else begin cgw := 0; cgh := 0; end;
            CblksW := cgw; CblksH := cgh;
            SetLength(Cblks, cgw * cgh);
            for cby := 0 to cgh - 1 do
              for cbx := 0 to cgw - 1 do
              begin
                ci := cby * cgw + cbx;
                bx0 := bands[bi].X0 + cbx * CBLK;
                by0 := bands[bi].Y0 + cby * CBLK;
                bx1 := MinI(bx0 + CBLK, bands[bi].X1);
                by1 := MinI(by0 + CBLK, bands[bi].Y1);
                cbw := bx1 - bx0; cbh := by1 - by0;
                SetLength(cdata, cbw * cbh);
                for yy := 0 to cbh - 1 do
                  for xx := 0 to cbw - 1 do
                    cdata[yy * cbw + xx] := coeffs[c][(by0 + yy) * Img.W + (bx0 + xx)];
                nb := T1NumBps(cdata, cbw * cbh);
                // numimsbs is relative to the band's nominal bit-depth: per-band
                // bandbps for reversible (qstyle 0), the common Mb for the
                // expounded irreversible quantiser.
                if reversible then mbb := bandbps[bi] else mbb := mb;
                Cblks[ci].NumImsbs := mbb - nb;
                if nb > 0 then
                begin
                  Cblks[ci].DataBytes := T1Encode(cdata, cbw, cbh, bands[bi].Orient, nb, numpasses);
                  Cblks[ci].NumPasses := numpasses;
                end
                else
                begin
                  Cblks[ci].NumPasses := 0;
                  SetLength(Cblks[ci].DataBytes, 0);
                end;
              end;
          end;
        end;
      T2EncodePacket(body, pkt);
    end;

  // ---- write the codestream ----
  out_ := TMemStream.Create;
  PutU16(out_, MS_SOC);

  // SIZ
  PutU16(out_, MS_SIZ);
  PutU16(out_, 38 + 3 * Img.NumComps);          // Lsiz
  PutU16(out_, 0);                              // Rsiz
  PutU32(out_, Img.W); PutU32(out_, Img.H);     // Xsiz, Ysiz
  PutU32(out_, 0); PutU32(out_, 0);             // XOsiz, YOsiz
  PutU32(out_, Img.W); PutU32(out_, Img.H);     // XTsiz, YTsiz (one tile)
  PutU32(out_, 0); PutU32(out_, 0);             // XTOsiz, YTOsiz
  PutU16(out_, Img.NumComps);                   // Csiz
  for c := 0 to Img.NumComps - 1 do
  begin
    out_.PutC(Img.Prec - 1);                    // Ssiz (unsigned)
    out_.PutC(1); out_.PutC(1);                 // XRsiz, YRsiz
  end;

  // COD (ISO 15444-1 standard layout).
  PutU16(out_, MS_COD);
  PutU16(out_, 12);                             // Lcod
  out_.PutC(0);                                 // Scod (no SOP/EPH, max precinct)
  out_.PutC(0);                                 // SGcod: progression order = LRCP
  PutU16(out_, 1);                              //         number of layers
  out_.PutC(Ord((Img.NumComps = 3) and Opt.UseMct));  // MCT (1 = RCT/ICT)
  out_.PutC(L);                                 // SPcod: decomposition levels
  out_.PutC(4);                                 //         code-block width  exp (2^(4+2)=64)
  out_.PutC(4);                                 //         code-block height exp
  out_.PutC(0);                                 //         code-block style
  out_.PutC(Ord(reversible));                   //         transform: 1=5/3, 0=9/7

  // QCD (ISO 15444-1, conformant). Both modes carry numbps = numguard + exp - 1
  // per band so a standard decoder knows each band's magnitude bit-depth.
  PutU16(out_, MS_QCD);
  if reversible then
  begin
    // No quantisation: 1 byte/band, exponent = bit-planes (numguard = 2).
    PutU16(out_, 2 + 1 + numbands);              // Lqcd
    out_.PutC((2 shl 5) or 0);                   // Sqcd: 2 guard bits, qstyle = 0
    for bi := 0 to numbands - 1 do
      out_.PutC((MaxI(bandbps[bi] - 1, 0) and $1f) shl 3);  // exp = numbps - 1
  end
  else
  begin
    // Scalar expounded quantisation (qstyle = 2): 2 bytes/band carrying the
    // real step word, so conformant decoders (JasPer, OpenJPEG, ...) dequantise
    // correctly.  One uniform step is used, so every band gets the same word.
    PutU16(out_, 2 + 1 + 2 * numbands);          // Lqcd
    out_.PutC((gbits shl 5) or 2);               // Sqcd: guard bits, qstyle = 2
    for bi := 0 to numbands - 1 do
      PutU16(out_, stepword);
  end;

  // SOT / SOD. Psot = length of the whole tile-part: SOT marker (2) +
  // SOT segment (10) + SOD marker (2) + packet data.
  PutU16(out_, MS_SOT);
  PutU16(out_, 10);                             // Lsot
  PutU16(out_, 0);                              // Isot (tile index)
  PutU32(out_, LongWord(14 + body.Size));       // Psot
  out_.PutC(0); out_.PutC(1);                   // TPsot, TNsot
  PutU16(out_, MS_SOD);

  // tile body
  seg := body;
  out_.Write(seg.ToBytes[0], seg.Size);

  PutU16(out_, MS_EOC);

  Result := out_.ToBytes;

  // cleanup
  out_.Free; body.Free;
  for c := 0 to Img.NumComps - 1 do
  begin
    if mi[c] <> nil then mi[c].Free;
    if md[c] <> nil then md[c].Free;
  end;
end;

// ============================================================ JP2 boxes =

const
  BOX_JP   = $6a502020;   // 'jP  '  signature
  BOX_FTYP = $66747970;   // 'ftyp'
  BOX_JP2H = $6a703268;   // 'jp2h'  (superbox)
  BOX_IHDR = $69686472;   // 'ihdr'
  BOX_COLR = $636f6c72;   // 'colr'
  BOX_JP2C = $6a703263;   // 'jp2c'  contiguous codestream
  BRAND_JP2 = $6a703220;  // 'jp2 '
  JP_MAGIC = $0d0a870a;

function RdU32(const B: TBytes; p: Integer): LongWord;
begin
  Result := (LongWord(B[p]) shl 24) or (LongWord(B[p + 1]) shl 16) or
            (LongWord(B[p + 2]) shl 8) or LongWord(B[p + 3]);
end;

function IsJp2(const Bytes: TBytes): Boolean;
begin
  Result := (Length(Bytes) >= 12) and (RdU32(Bytes, 0) = 12) and
            (RdU32(Bytes, 4) = BOX_JP) and (RdU32(Bytes, 8) = JP_MAGIC);
end;

function WrapJp2(const Jpc: TBytes; W, H, NumComps, Prec: Integer): TBytes;
var
  ms: TMemStream;
begin
  ms := TMemStream.Create;
  // Signature box.
  PutU32(ms, 12); PutU32(ms, BOX_JP); PutU32(ms, JP_MAGIC);
  // File Type box.
  PutU32(ms, 20); PutU32(ms, BOX_FTYP);
  PutU32(ms, BRAND_JP2); PutU32(ms, 0); PutU32(ms, BRAND_JP2);
  // JP2 Header superbox = Image Header + Colour Spec.
  PutU32(ms, 45); PutU32(ms, BOX_JP2H);
  PutU32(ms, 22); PutU32(ms, BOX_IHDR);
  PutU32(ms, H); PutU32(ms, W); PutU16(ms, NumComps);
  ms.PutC((Prec - 1) and $7f);    // BPC (unsigned)
  ms.PutC(7);                      // C = 7 (JPEG 2000 codestream)
  ms.PutC(0);                      // UnkC
  ms.PutC(0);                      // IPR
  PutU32(ms, 15); PutU32(ms, BOX_COLR);
  ms.PutC(1);                      // METH = enumerated
  ms.PutC(0);                      // PREC
  ms.PutC(0);                      // APPROX
  if NumComps >= 3 then PutU32(ms, 16)   // sRGB
  else PutU32(ms, 17);                    // greyscale
  // Contiguous Codestream box.
  PutU32(ms, LongWord(8 + Length(Jpc))); PutU32(ms, BOX_JP2C);
  if Length(Jpc) > 0 then ms.Write(Jpc[0], Length(Jpc));
  Result := ms.ToBytes;
  ms.Free;
end;

function UnwrapJp2(const Bytes: TBytes): TBytes;
var
  pos, total, cstart: Integer;
  boxlen: Int64;
  btype: LongWord;
begin
  SetLength(Result, 0);
  total := Length(Bytes);
  pos := 0;
  while pos + 8 <= total do
  begin
    boxlen := RdU32(Bytes, pos);
    btype := RdU32(Bytes, pos + 4);
    cstart := pos + 8;
    if boxlen = 1 then
    begin
      // 64-bit extended length (we only use the low 32 bits).
      if pos + 16 > total then Break;
      boxlen := (Int64(RdU32(Bytes, pos + 8)) shl 32) or Int64(RdU32(Bytes, pos + 12));
      cstart := pos + 16;
    end
    else if boxlen = 0 then
      boxlen := total - pos;             // extends to end of file
    if btype = BOX_JP2C then
    begin
      Result := Copy(Bytes, cstart, (pos + boxlen) - cstart);
      Exit;
    end;
    if boxlen <= 0 then Break;
    pos := pos + Integer(boxlen);
  end;
  raise EJp2kError.Create('JP2 file contains no codestream (jp2c) box');
end;

function EncodeToJp2(Img: TJp2kImage; const Opt: TEncodeOptions): TBytes;
begin
  Result := WrapJp2(EncodeToJpc(Img, Opt), Img.W, Img.H, Img.NumComps, Img.Prec);
end;

function DecodeAny(const Bytes: TBytes): TJp2kImage;
begin
  if IsJp2(Bytes) then
    Result := DecodeJpcStandard(UnwrapJp2(Bytes))
  else
    Result := DecodeJpcStandard(Bytes);
end;

// ============================================================ decode ====

function DecodeFromJpc(const Bytes: TBytes): TJp2kImage;
begin
  // The encoder now emits standard markers; decode via the standard decoder.
  Result := DecodeJpcStandard(Bytes);
end;


// ================================================= standard decoder =====

function Pow2(n: Integer): Double;
begin
  if n >= 0 then Result := Int64(1) shl n
  else Result := 1.0 / (Int64(1) shl (-n));
end;

// Absolute quantiser step from a 16-bit QCD step word (expounded), per
// ISO 15444-1 E.1: absstepsize = (1 + mant/2^11) * 2^(numbits - expn),
// with numbits = prec (the nominal gain is 0 for the 9/7 transform).
function StepToAbs(word, prec: Integer): Double;
var
  expn, mant: Integer;
begin
  expn := word shr 11;
  mant := word and $7ff;
  Result := (1.0 + mant / 2048.0) * Pow2(prec - expn);
end;

function DecodeJpcStandard(const Bytes: TBytes): TJp2kImage;
var
  ms: TMemStream;
  marker, seglen, segend, i, c, r, bi: Integer;
  W, H, NumComps, L: Integer;
  prec: TIntArray;
  reversible, mct: Boolean;
  numgbits, qstyle, qstyleMain, ncomp_q: Integer;
  numbands: Integer;
  numbps: array of TIntArray;       // [comp][band] bit-plane count
  stepw: array of TIntArray;        // [comp][band] 16-bit QCD step word
  defbps: TIntArray;                // QCD defaults (bit-planes)
  defstepw: TIntArray;              // QCD defaults (step words)
  abss: Double;
  bands: TBandRects;
  coeffs: array of TIntArray;
  pkt: TT2Packet;
  cgw, cgh, ci, cbx, cby, bx0, by0, bx1, by1, cbw, cbh, xx, yy, nb: Integer;
  cdata: TIntArray;
  shift, v: Integer;
  step: Double;
  Img: TJp2kImage;
  mis: array of TIntMatrix;
  mds: array of TDblMatrix;

  procedure ReadBandExps(target, steptarget: TIntArray; payloadEnd: Integer);
  var
    bb, expn, st, w: Integer;
  begin
    st := ms.GetC;                  // Sqcd/Sqcc
    qstyle := st and $1f;
    numgbits := st shr 5;
    if qstyle = 0 then              // no quantisation (reversible)
      for bb := 0 to numbands - 1 do
      begin
        if ms.Position >= payloadEnd then Break;
        expn := ms.GetC shr 3;
        target[bb] := numgbits + expn - 1;
        steptarget[bb] := expn shl 11;
      end
    else                            // scalar quantised (irreversible): 2 bytes/band
      for bb := 0 to numbands - 1 do
      begin
        if ms.Position >= payloadEnd then Break;
        w := GetU16(ms);
        target[bb] := numgbits + (w shr 11) - 1;
        steptarget[bb] := w;
      end;
  end;

begin
  ms := TMemStream.Create(Bytes, Length(Bytes));
  W := 0; H := 0; NumComps := 1; L := 1;
  reversible := True; mct := False; step := 1.0; qstyleMain := 0;
  numbands := 0; SetLength(defbps, 0); SetLength(defstepw, 0);
  SetLength(prec, 0);

  if GetU16(ms) <> MS_SOC then
    raise EJp2kError.Create('not a JPEG 2000 codestream (no SOC)');

  while True do
  begin
    marker := GetU16(ms);
    if (marker = MS_SOD) or (marker = MS_EOC) or (marker < 0) then Break;
    seglen := GetU16(ms);
    segend := ms.Position + seglen - 2;
    case marker of
      MS_SIZ:
        begin
          GetU16(ms);                          // Rsiz
          W := GetU32(ms); H := GetU32(ms);
          GetU32(ms); GetU32(ms);              // image offset
          GetU32(ms); GetU32(ms);              // tile size
          GetU32(ms); GetU32(ms);              // tile offset
          NumComps := GetU16(ms);
          SetLength(prec, NumComps);
          for c := 0 to NumComps - 1 do
          begin
            prec[c] := (ms.GetC and $7f) + 1;
            ms.GetC; ms.GetC;                  // subsampling
          end;
        end;
      MS_COD:
        begin
          ms.GetC;                             // Scod
          ms.GetC;                             // progression order
          GetU16(ms);                          // num layers
          mct := ms.GetC <> 0;
          L := ms.GetC;                        // decomposition levels
          // remaining SPcod fields ignored (cblk size fixed 64, style 0)
          ms.GetC; ms.GetC; ms.GetC;
          reversible := ms.GetC <> 0;          // transform: 1 = 5/3
          numbands := 1 + 3 * L;
        end;
      MS_QCD:
        begin
          if numbands = 0 then numbands := 1 + 3 * L;
          SetLength(defbps, numbands);
          SetLength(defstepw, numbands);
          ReadBandExps(defbps, defstepw, segend);
          qstyleMain := qstyle;
        end;
      MS_QCC:
        begin
          if NumComps < 257 then ncomp_q := ms.GetC else ncomp_q := GetU16(ms);
          if (Length(defbps) > 0) then
          begin
            if Length(numbps) = 0 then
            begin
              SetLength(numbps, NumComps);
              SetLength(stepw, NumComps);
              for c := 0 to NumComps - 1 do
              begin
                SetLength(numbps[c], numbands);
                SetLength(stepw[c], numbands);
                for bi := 0 to numbands - 1 do
                  if bi < Length(defbps) then
                  begin
                    numbps[c][bi] := defbps[bi];
                    stepw[c][bi] := defstepw[bi];
                  end;
              end;
            end;
            if (ncomp_q >= 0) and (ncomp_q < NumComps) then
              ReadBandExps(numbps[ncomp_q], stepw[ncomp_q], segend);
          end;
        end;
      MS_COM:
        begin
          if GetU16(ms) = 1 then           // Rcom = 1 : our private binary step
            step := GetDbl(ms);
        end;
    end;
    ms.Seek(segend, SEEK_SET);
  end;

  // Per-component band bit-planes / step words (QCC overrides QCD).
  if Length(numbps) = 0 then
  begin
    SetLength(numbps, NumComps);
    SetLength(stepw, NumComps);
    for c := 0 to NumComps - 1 do
    begin
      SetLength(numbps[c], numbands);
      SetLength(stepw[c], numbands);
      for bi := 0 to numbands - 1 do
        if bi < Length(defbps) then
        begin
          numbps[c][bi] := defbps[bi];
          stepw[c][bi] := defstepw[bi];
        end;
    end;
  end;

  bands := EnumBands(W, H, L);
  SetLength(coeffs, NumComps);
  for c := 0 to NumComps - 1 do
  begin
    SetLength(coeffs[c], W * H);
    FillChar(coeffs[c][0], W * H * SizeOf(Integer), 0);
  end;

  // Tier-2 + tier-1 in LRCP order (1 layer): resolution, then component.
  for r := 0 to L do
    for c := 0 to NumComps - 1 do
    begin
      SetLength(pkt.Bands, 0);
      for bi := 0 to Length(bands) - 1 do
        if bands[bi].Res = r then
        begin
          SetLength(pkt.Bands, Length(pkt.Bands) + 1);
          with pkt.Bands[High(pkt.Bands)] do
          begin
            Present := (bands[bi].X1 > bands[bi].X0) and (bands[bi].Y1 > bands[bi].Y0);
            if Present then
            begin
              cgw := CeilDiv(bands[bi].X1 - bands[bi].X0, CBLK);
              cgh := CeilDiv(bands[bi].Y1 - bands[bi].Y0, CBLK);
            end
            else begin cgw := 0; cgh := 0; end;
            CblksW := cgw; CblksH := cgh;
            SetLength(Cblks, cgw * cgh);
          end;
        end;

      T2DecodePacket(ms, pkt);

      i := 0;
      for bi := 0 to Length(bands) - 1 do
        if bands[bi].Res = r then
        begin
          if pkt.Bands[i].Present then
          begin
            cgw := pkt.Bands[i].CblksW; cgh := pkt.Bands[i].CblksH;
            for cby := 0 to cgh - 1 do
              for cbx := 0 to cgw - 1 do
              begin
                ci := cby * cgw + cbx;
                bx0 := bands[bi].X0 + cbx * CBLK;
                by0 := bands[bi].Y0 + cby * CBLK;
                bx1 := MinI(bx0 + CBLK, bands[bi].X1);
                by1 := MinI(by0 + CBLK, bands[bi].Y1);
                cbw := bx1 - bx0; cbh := by1 - by0;
                if pkt.Bands[i].Cblks[ci].NumPasses > 0 then
                begin
                  nb := numbps[c][bi] - pkt.Bands[i].Cblks[ci].NumImsbs;
                  T1Decode(pkt.Bands[i].Cblks[ci].DataBytes, cbw, cbh,
                    bands[bi].Orient, nb, cdata);
                  for yy := 0 to cbh - 1 do
                    for xx := 0 to cbw - 1 do
                      coeffs[c][(by0 + yy) * W + (bx0 + xx)] := cdata[yy * cbw + xx];
                end;
              end;
          end;
          Inc(i);
        end;
    end;

  // Inverse transform, inverse MCT, level shift, clip.
  Img := TJp2kImage.Create(W, H, NumComps, prec[0]);
  if reversible then
  begin
    SetLength(mis, NumComps);
    for c := 0 to NumComps - 1 do
    begin
      mis[c] := TIntMatrix.Create(H, W);
      Move(coeffs[c][0], mis[c].Data[0], W * H * SizeOf(Integer));
      Inv53(mis[c], L);
    end;
    if (NumComps >= 3) and mct then
      IRCT(mis[0], mis[1], mis[2]);
    for c := 0 to NumComps - 1 do
    begin
      shift := 1 shl (prec[c] - 1);
      for i := 0 to W * H - 1 do
      begin
        v := mis[c].Data[i] + shift;
        if v < 0 then v := 0;
        if v > (1 shl prec[c]) - 1 then v := (1 shl prec[c]) - 1;
        Img.Comps[c][i] := v;
      end;
      mis[c].Free;
    end;
  end
  else
  begin
    SetLength(mds, NumComps);
    for c := 0 to NumComps - 1 do
    begin
      mds[c] := TDblMatrix.Create(H, W);
      if qstyleMain <> 0 then
      begin
        // Standard expounded quantisation: per-band step with mid-point
        //reconstruction (reads lossy 9/7 files from other encoders).
        for bi := 0 to Length(bands) - 1 do
        begin
          abss := StepToAbs(stepw[c][bi], prec[c]);
          for yy := bands[bi].Y0 to bands[bi].Y1 - 1 do
            for xx := bands[bi].X0 to bands[bi].X1 - 1 do
            begin
              v := coeffs[c][yy * W + xx];
              if v > 0 then mds[c].Data[yy * W + xx] := (v + 0.5) * abss
              else if v < 0 then mds[c].Data[yy * W + xx] := (v - 0.5) * abss
              else mds[c].Data[yy * W + xx] := 0;
            end;
        end;
      end
      else
        // Our own files: uniform step quantiser (step from the COM marker).
        for i := 0 to W * H - 1 do
          mds[c].Data[i] := coeffs[c][i] * step;
      Inv97(mds[c], L);
    end;
    if (NumComps >= 3) and mct then
      IICT(mds[0], mds[1], mds[2]);
    for c := 0 to NumComps - 1 do
    begin
      shift := 1 shl (prec[c] - 1);
      for i := 0 to W * H - 1 do
      begin
        v := Round(mds[c].Data[i]) + shift;
        if v < 0 then v := 0;
        if v > (1 shl prec[c]) - 1 then v := (1 shl prec[c]) - 1;
        Img.Comps[c][i] := v;
      end;
      mds[c].Free;
    end;
  end;

  ms.Free;
  Result := Img;
end;

end.
