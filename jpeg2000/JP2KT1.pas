// JPEG 2000 based on JASPER 4.2.9
// License: JasPer-2.0 (similar to MIT )
// Author: www.xelitan.com
//
// JP2KT1 - Tier-1 (EBCOT) bit-plane coder.
//
// Port of jpc_t1cod.c (context formation + LUTs), jpc_t1enc.c and jpc_t1dec.c.
// A code-block of signed integer coefficients is coded bit-plane by bit-plane
// using three coding passes (significance propagation, magnitude refinement,
// cleanup) driven by the MQ arithmetic coder.
//
// Simplifications for the "simple" codec (code-block style = 0):
//    * MQ path only (no raw/lazy bypass), single segment per code-block.
//    * no vertically-causal contexts, segmentation symbols, ROI, or per-pass
//      termination/reset; the whole code-block is one MQ segment flushed once.
//    * JPC_NUMEXTRABITS = 0, so code-block data are plain signed integers and
//      the 5/3 lossless path reconstructs exactly.
//
// Processing order matches JasPer exactly (4-row stripes; within a stripe,
// columns left-to-right, rows top-to-bottom), so encoder and decoder keep
// identical neighbour-flag state at every step.

unit JP2KT1;

{$mode delphi}
{$H+}
{$Q-}
{$R-}

interface

uses
  SysUtils, JP2KCommon, JP2KMQ, JP2KBS;

const
  // Subband orientations (match jpc_tsfb_orient).
  ORIENT_LL = 0;
  ORIENT_LH = 1;
  ORIENT_HL = 2;
  ORIENT_HH = 3;

// Number of magnitude bit-planes needed for a code-block (= floor(log2(maxabs))+1).
function T1NumBps(const Data: TIntArray; Count: Integer): Integer;

// Encode a code-block (Data: row-major signed coefficients, W*H).
// Returns the MQ byte stream; NumPasses receives 3*numbps-2 (0 if numbps=0).
function T1Encode(const Data: TIntArray; W, H, Orient, NumBps: Integer;
  out NumPasses: Integer): TBytes;

// Decode a code-block back into Data (allocated W*H, zero-filled here).
procedure T1Decode(const Bytes: TBytes; W, H, Orient, NumBps: Integer;
  var Data: TIntArray);

const
  // Code-block style flags (match jpc_cs JPC_COX_*).
  COX_LAZY    = $01;   // selective arithmetic-coding bypass (raw passes)
  COX_RESET   = $02;   // reset MQ contexts each pass
  COX_TERMALL = $04;   // terminate each coding pass
  COX_VSC     = $08;   // vertically causal contexts
  COX_PTERM   = $10;   // predictable termination
  COX_SEGSYM  = $20;   // segmentation symbols

type
  TSegInfo = record
    np: Integer;       // number of coding passes in this segment
    raw: Boolean;      // True = raw (bypass) segment, False = MQ
    data: TBytes;      // this segment's coded bytes (accumulated over layers)
    dlen: Integer;     // valid bytes in data
    maxcap: Integer;   // pass capacity (internal, used while building)
  end;

// Decode a code-block that may use any code-block style (lazy/termall/VSC/
// segsym/reset/pterm), given its segment list (computed by tier-2).
procedure T1DecodeSeg(const Segs: array of TSegInfo;
  W, H, Orient, NumBps, Cbsty: Integer; var Data: TIntArray);

implementation

const
  // Per-sample neighbour-significance / sign flag bits.
  F_NESIG = $0001; F_SESIG = $0002; F_SWSIG = $0004; F_NWSIG = $0008;
  F_NSIG = $0010; F_ESIG = $0020; F_SSIG = $0040; F_WSIG = $0080;
  F_OTHSIGMSK = F_NSIG or F_NESIG or F_ESIG or F_SESIG or F_SSIG or
                F_SWSIG or F_WSIG or F_NWSIG;                      // $00FF
  F_PRIMSIGMSK = F_NSIG or F_ESIG or F_SSIG or F_WSIG;            // $00F0
  F_NSGN = $0100; F_ESGN = $0200; F_SSGN = $0400; F_WSGN = $0800;
  F_SGNMSK = F_NSGN or F_ESGN or F_SSGN or F_WSGN;                // $0F00
  F_SIG = $1000; F_REFINE = $2000; F_VISIT = $4000;

  NUMAGGCTXS = 1; NUMZCCTXS = 9; NUMMAGCTXS = 3; NUMSCCTXS = 5; NUMUCTXS = 1;
  AGGCTXNO = 0;
  ZCCTXNO  = AGGCTXNO + NUMAGGCTXS;   // 1
  MAGCTXNO = ZCCTXNO + NUMZCCTXS;     // 10
  SCCTXNO  = MAGCTXNO + NUMMAGCTXS;   // 13
  UCTXNO   = SCCTXNO + NUMSCCTXS;     // 18
  NUMCTXS  = UCTXNO + NUMUCTXS;       // 19

var
  zcctxnolut: array[0..4*256 - 1] of Byte;
  spblut: array[0..255] of Byte;
  scctxnolut: array[0..255] of Byte;
  magctxnolut: array[0..4095] of Byte;
  mqctxs: TMqCtxArray;

// ------------------------------------------------ context computation ---

function CalcZcCtxNo(f, orient: Integer): Integer;
var
  n, t, hv, h, v, d: Integer;
begin
  h := Ord((f and F_WSIG) <> 0) + Ord((f and F_ESIG) <> 0);
  v := Ord((f and F_NSIG) <> 0) + Ord((f and F_SSIG) <> 0);
  d := Ord((f and F_NWSIG) <> 0) + Ord((f and F_NESIG) <> 0) +
       Ord((f and F_SESIG) <> 0) + Ord((f and F_SWSIG) <> 0);
  n := 0;
  case orient of
    ORIENT_HL, ORIENT_LL, ORIENT_LH:
      begin
        if orient = ORIENT_HL then
        begin
          t := h; h := v; v := t;
        end;
        if h = 0 then
        begin
          if v = 0 then
          begin
            if d = 0 then n := 0
            else if d = 1 then n := 1
            else n := 2;
          end
          else if v = 1 then n := 3
          else n := 4;
        end
        else if h = 1 then
        begin
          if v = 0 then
          begin
            if d = 0 then n := 5 else n := 6;
          end
          else n := 7;
        end
        else n := 8;
      end;
    ORIENT_HH:
      begin
        hv := h + v;
        if d = 0 then
        begin
          if hv = 0 then n := 0
          else if hv = 1 then n := 1
          else n := 2;
        end
        else if d = 1 then
        begin
          if hv = 0 then n := 3
          else if hv = 1 then n := 4
          else n := 5;
        end
        else if d = 2 then
        begin
          if hv = 0 then n := 6 else n := 7;
        end
        else n := 8;
      end;
  end;
  Result := ZCCTXNO + n;
end;

function CalcSpb(f: Integer): Integer;
var
  hc, vc, n: Integer;
begin
  hc := MinI(Ord((f and (F_ESIG or F_ESGN)) = F_ESIG) +
             Ord((f and (F_WSIG or F_WSGN)) = F_WSIG), 1) -
        MinI(Ord((f and (F_ESIG or F_ESGN)) = (F_ESIG or F_ESGN)) +
             Ord((f and (F_WSIG or F_WSGN)) = (F_WSIG or F_WSGN)), 1);
  vc := MinI(Ord((f and (F_NSIG or F_NSGN)) = F_NSIG) +
             Ord((f and (F_SSIG or F_SSGN)) = F_SSIG), 1) -
        MinI(Ord((f and (F_NSIG or F_NSGN)) = (F_NSIG or F_NSGN)) +
             Ord((f and (F_SSIG or F_SSGN)) = (F_SSIG or F_SSGN)), 1);
  if (hc = 0) and (vc = 0) then
    n := 0
  else
    n := Ord(not ((hc > 0) or ((hc = 0) and (vc > 0))));
  Result := n;
end;

function CalcScCtxNo(f: Integer): Integer;
var
  hc, vc, n: Integer;
begin
  hc := MinI(Ord((f and (F_ESIG or F_ESGN)) = F_ESIG) +
             Ord((f and (F_WSIG or F_WSGN)) = F_WSIG), 1) -
        MinI(Ord((f and (F_ESIG or F_ESGN)) = (F_ESIG or F_ESGN)) +
             Ord((f and (F_WSIG or F_WSGN)) = (F_WSIG or F_WSGN)), 1);
  vc := MinI(Ord((f and (F_NSIG or F_NSGN)) = F_NSIG) +
             Ord((f and (F_SSIG or F_SSGN)) = F_SSIG), 1) -
        MinI(Ord((f and (F_NSIG or F_NSGN)) = (F_NSIG or F_NSGN)) +
             Ord((f and (F_SSIG or F_SSGN)) = (F_SSIG or F_SSGN)), 1);
  if hc < 0 then
  begin
    hc := -hc; vc := -vc;
  end;
  if hc = 0 then
  begin
    if vc = -1 then n := 1
    else if vc = 0 then n := 0
    else n := 1;
  end
  else
  begin
    if vc = -1 then n := 2
    else if vc = 0 then n := 3
    else n := 4;
  end;
  Result := SCCTXNO + n;
end;

function CalcMagCtxNo(f: Integer): Integer;
var
  n: Integer;
begin
  if (f and F_REFINE) = 0 then
  begin
    if (f and F_OTHSIGMSK) <> 0 then n := 1 else n := 0;
  end
  else
    n := 2;
  Result := MAGCTXNO + n;
end;

procedure InitLuts;
var
  orient, i, refine: Integer;
begin
  for orient := 0 to 3 do
    for i := 0 to 255 do
      zcctxnolut[(orient shl 8) or i] := CalcZcCtxNo(i, orient);
  for i := 0 to 255 do
    spblut[i] := CalcSpb(i shl 4);
  for i := 0 to 255 do
    scctxnolut[i] := CalcScCtxNo(i shl 4);
  for refine := 0 to 1 do
    for i := 0 to 2047 do
      magctxnolut[(refine shl 11) + i] :=
        CalcMagCtxNo((Ord(refine = 1) * F_REFINE) or i);
end;

procedure InitMqCtxs;
var
  i: Integer;
begin
  SetLength(mqctxs, NUMCTXS);
  for i := 0 to NUMCTXS - 1 do
  begin
    mqctxs[i].Mps := 0;
    case i of
      UCTXNO:   mqctxs[i].Ind := 46;
      ZCCTXNO:  mqctxs[i].Ind := 4;
      AGGCTXNO: mqctxs[i].Ind := 3;
    else
      mqctxs[i].Ind := 0;
    end;
  end;
end;

// Context-lookup helpers (the JPC_GET* macros).
function GETZCCTXNO(f, orient: Integer): Integer; inline;
begin
  Result := zcctxnolut[(orient shl 8) or (f and F_OTHSIGMSK)];
end;

function GETSPB(f: Integer): Integer; inline;
begin
  Result := spblut[(f and (F_PRIMSIGMSK or F_SGNMSK)) shr 4];
end;

function GETSCCTXNO(f: Integer): Integer; inline;
begin
  Result := scctxnolut[(f and (F_PRIMSIGMSK or F_SGNMSK)) shr 4];
end;

function GETMAGCTXNO(f: Integer): Integer; inline;
begin
  Result := magctxnolut[(f and F_OTHSIGMSK) or (Ord((f and F_REFINE) <> 0) shl 11)];
end;

// Update neighbour flags around fp after a coefficient became significant.
// s = sign (True = negative). Vertically-causal mode is unused (always False).
procedure UpdateFlags4(var Flags: TIntArray; fp, frowstep: Integer; s: Boolean); inline;
var
  np, sp: Integer;
begin
  np := fp - frowstep;
  sp := fp + frowstep;
  Flags[np - 1] := Flags[np - 1] or F_SESIG;
  Flags[np + 1] := Flags[np + 1] or F_SWSIG;
  Flags[sp - 1] := Flags[sp - 1] or F_NESIG;
  Flags[sp + 1] := Flags[sp + 1] or F_NWSIG;
  if s then
  begin
    Flags[np] := Flags[np] or (F_SSIG or F_SSGN);
    Flags[sp] := Flags[sp] or (F_NSIG or F_NSGN);
    Flags[fp - 1] := Flags[fp - 1] or (F_ESIG or F_ESGN);
    Flags[fp + 1] := Flags[fp + 1] or (F_WSIG or F_WSGN);
  end
  else
  begin
    Flags[np] := Flags[np] or F_SSIG;
    Flags[sp] := Flags[sp] or F_NSIG;
    Flags[fp - 1] := Flags[fp - 1] or F_ESIG;
    Flags[fp + 1] := Flags[fp + 1] or F_WSIG;
  end;
end;

// ============================================================ public ====

function T1NumBps(const Data: TIntArray; Count: Integer): Integer;
var
  i, mx, v: Integer;
begin
  mx := 0;
  for i := 0 to Count - 1 do
  begin
    v := Abs(Data[i]);
    if v > mx then mx := v;
  end;
  Result := IntFirstOne(mx) + 1;
  if Result < 0 then Result := 0;
end;

function T1Encode(const Data: TIntArray; W, H, Orient, NumBps: Integer;
  out NumPasses: Integer): TBytes;
var
  ms: TMemStream;
  enc: TMqEnc;
  flags: TIntArray;
  frowstep, fbase: Integer;
  bitpos, passno, passtype, one: Integer;
  i, j, k, r, vscanlen, fp, dp, f, sgn, runlen: Integer;
  v: Boolean;

  function FIdx(rr, cc: Integer): Integer; inline;
  begin
    Result := fbase + rr * frowstep + cc;
  end;

begin
  if NumBps > 0 then NumPasses := 3 * NumBps - 2 else NumPasses := 0;
  ms := TMemStream.Create;
  enc := TMqEnc.Create(NUMCTXS, ms);
  enc.SetCtxs(mqctxs);
  frowstep := W + 2;
  fbase := frowstep + 1;
  SetLength(flags, (W + 2) * (H + 2));  // zero-filled

  bitpos := NumBps - 1;
  for passno := 0 to NumPasses - 1 do
  begin
    passtype := passno mod 3;   // 0=CLN, 1=SIG, 2=REF
    one := 1 shl bitpos;

    if passtype = 1 then
    begin
      // ---- significance propagation pass ----
      i := 0;
      while i < H do
      begin
        vscanlen := MinI(4, H - i);
        for j := 0 to W - 1 do
          for k := 0 to vscanlen - 1 do
          begin
            r := i + k; fp := FIdx(r, j); dp := r * W + j;
            f := flags[fp];
            if ((f and F_OTHSIGMSK) <> 0) and ((f and (F_SIG or F_VISIT)) = 0) then
            begin
              v := (Abs(Data[dp]) and one) <> 0;
              enc.SetCurCtx(GETZCCTXNO(f, Orient));
              enc.PutBit(Ord(v));
              if v then
              begin
                sgn := Ord(Data[dp] < 0);
                enc.SetCurCtx(GETSCCTXNO(f));
                enc.PutBit(sgn xor GETSPB(f));
                UpdateFlags4(flags, fp, frowstep, sgn = 1);
                flags[fp] := flags[fp] or F_SIG;
              end;
              flags[fp] := flags[fp] or F_VISIT;
            end;
          end;
        Inc(i, 4);
      end;
    end
    else if passtype = 2 then
    begin
      // ---- magnitude refinement pass ----
      i := 0;
      while i < H do
      begin
        vscanlen := MinI(4, H - i);
        for j := 0 to W - 1 do
          for k := 0 to vscanlen - 1 do
          begin
            r := i + k; fp := FIdx(r, j); dp := r * W + j;
            if (flags[fp] and (F_SIG or F_VISIT)) = F_SIG then
            begin
              enc.SetCurCtx(GETMAGCTXNO(flags[fp]));
              enc.PutBit(Ord((Abs(Data[dp]) and one) <> 0));
              flags[fp] := flags[fp] or F_REFINE;
            end;
          end;
        Inc(i, 4);
      end;
    end
    else
    begin
      // ---- cleanup pass (with run-length aggregation) ----
      i := 0;
      while i < H do
      begin
        vscanlen := MinI(4, H - i);
        for j := 0 to W - 1 do
        begin
          k := 0;                  // start sample within vscan
          if (vscanlen >= 4) and
             ((flags[FIdx(i, j)] and (F_SIG or F_VISIT or F_OTHSIGMSK)) = 0) and
             ((flags[FIdx(i + 1, j)] and (F_SIG or F_VISIT or F_OTHSIGMSK)) = 0) and
             ((flags[FIdx(i + 2, j)] and (F_SIG or F_VISIT or F_OTHSIGMSK)) = 0) and
             ((flags[FIdx(i + 3, j)] and (F_SIG or F_VISIT or F_OTHSIGMSK)) = 0) then
          begin
            runlen := 0;
            while runlen < vscanlen do
            begin
              if (Abs(Data[(i + runlen) * W + j]) and one) <> 0 then Break;
              Inc(runlen);
            end;
            if runlen >= 4 then
            begin
              enc.SetCurCtx(AGGCTXNO);
              enc.PutBit(0);
              Continue;            // next column
            end;
            enc.SetCurCtx(AGGCTXNO);
            enc.PutBit(1);
            enc.SetCurCtx(UCTXNO);
            enc.PutBit((runlen shr 1) and 1);
            enc.PutBit(runlen and 1);
            // run-length sample is significant: emit sign directly
            r := i + runlen; fp := FIdx(r, j); dp := r * W + j;
            f := flags[fp];
            sgn := Ord(Data[dp] < 0);
            enc.SetCurCtx(GETSCCTXNO(f));
            enc.PutBit(sgn xor GETSPB(f));
            UpdateFlags4(flags, fp, frowstep, sgn = 1);
            flags[fp] := (flags[fp] or F_SIG) and (not F_VISIT);
            k := runlen + 1;
          end;

          while k < vscanlen do
          begin
            r := i + k; fp := FIdx(r, j); dp := r * W + j;
            f := flags[fp];
            if (f and (F_SIG or F_VISIT)) = 0 then
            begin
              enc.SetCurCtx(GETZCCTXNO(f, Orient));
              v := (Abs(Data[dp]) and one) <> 0;
              enc.PutBit(Ord(v));
              if v then
              begin
                f := flags[fp];
                sgn := Ord(Data[dp] < 0);
                enc.SetCurCtx(GETSCCTXNO(f));
                enc.PutBit(sgn xor GETSPB(f));
                UpdateFlags4(flags, fp, frowstep, sgn = 1);
                flags[fp] := flags[fp] or F_SIG;
              end;
            end;
            flags[fp] := flags[fp] and (not F_VISIT);
            Inc(k);
          end;
        end;
        Inc(i, 4);
      end;
    end;

    if passtype = 0 then Dec(bitpos);
  end;

  enc.Flush(JPC_MQENC_DEFTERM);
  Result := ms.ToBytes;
  enc.Free;
  ms.Free;
end;

procedure T1Decode(const Bytes: TBytes; W, H, Orient, NumBps: Integer;
  var Data: TIntArray);
var
  ms: TMemStream;
  mqd: TMqDec;
  flags: TIntArray;
  frowstep, fbase: Integer;
  bitpos, passno, passtype, numpasses, one, half, oneplushalf: Integer;
  poshalf, neghalf, t: Integer;
  i, j, k, r, vscanlen, fp, dp, f, v, runlen: Integer;

  function FIdx(rr, cc: Integer): Integer; inline;
  begin
    Result := fbase + rr * frowstep + cc;
  end;

begin
  SetLength(Data, W * H);
  FillChar(Data[0], W * H * SizeOf(Integer), 0);
  if NumBps <= 0 then Exit;
  numpasses := 3 * NumBps - 2;

  ms := TMemStream.Create(Bytes, Length(Bytes));
  mqd := TMqDec.Create(NUMCTXS, ms);
  mqd.SetCtxs(mqctxs);
  frowstep := W + 2;
  fbase := frowstep + 1;
  SetLength(flags, (W + 2) * (H + 2));

  bitpos := NumBps - 1;
  for passno := 0 to numpasses - 1 do
  begin
    passtype := passno mod 3;
    one := 1 shl bitpos;
    half := one shr 1;
    oneplushalf := one or half;

    if passtype = 1 then
    begin
      i := 0;
      while i < H do
      begin
        vscanlen := MinI(4, H - i);
        for j := 0 to W - 1 do
          for k := 0 to vscanlen - 1 do
          begin
            r := i + k; fp := FIdx(r, j); dp := r * W + j;
            f := flags[fp];
            if ((f and F_OTHSIGMSK) <> 0) and ((f and (F_SIG or F_VISIT)) = 0) then
            begin
              mqd.SetCurCtx(GETZCCTXNO(f, Orient));
              if mqd.GetBit = 1 then
              begin
                mqd.SetCurCtx(GETSCCTXNO(f));
                v := mqd.GetBit xor GETSPB(f);
                UpdateFlags4(flags, fp, frowstep, v = 1);
                flags[fp] := flags[fp] or F_SIG;
                if v = 1 then Data[dp] := -oneplushalf else Data[dp] := oneplushalf;
              end;
              flags[fp] := flags[fp] or F_VISIT;
            end;
          end;
        Inc(i, 4);
      end;
    end
    else if passtype = 2 then
    begin
      poshalf := one shr 1;
      if bitpos > 0 then neghalf := -poshalf else neghalf := -1;
      i := 0;
      while i < H do
      begin
        vscanlen := MinI(4, H - i);
        for j := 0 to W - 1 do
          for k := 0 to vscanlen - 1 do
          begin
            r := i + k; fp := FIdx(r, j); dp := r * W + j;
            if (flags[fp] and (F_SIG or F_VISIT)) = F_SIG then
            begin
              mqd.SetCurCtx(GETMAGCTXNO(flags[fp]));
              if mqd.GetBit = 1 then t := poshalf else t := neghalf;
              if Data[dp] < 0 then Data[dp] := Data[dp] - t
              else Data[dp] := Data[dp] + t;
              flags[fp] := flags[fp] or F_REFINE;
            end;
          end;
        Inc(i, 4);
      end;
    end
    else
    begin
      i := 0;
      while i < H do
      begin
        vscanlen := MinI(4, H - i);
        for j := 0 to W - 1 do
        begin
          k := 0;
          if (vscanlen >= 4) and
             ((flags[FIdx(i, j)] and (F_SIG or F_VISIT or F_OTHSIGMSK)) = 0) and
             ((flags[FIdx(i + 1, j)] and (F_SIG or F_VISIT or F_OTHSIGMSK)) = 0) and
             ((flags[FIdx(i + 2, j)] and (F_SIG or F_VISIT or F_OTHSIGMSK)) = 0) and
             ((flags[FIdx(i + 3, j)] and (F_SIG or F_VISIT or F_OTHSIGMSK)) = 0) then
          begin
            mqd.SetCurCtx(AGGCTXNO);
            if mqd.GetBit = 0 then
              Continue;             // whole column insignificant
            mqd.SetCurCtx(UCTXNO);
            runlen := (mqd.GetBit shl 1) or mqd.GetBit;
            r := i + runlen; fp := FIdx(r, j); dp := r * W + j;
            f := flags[fp];
            mqd.SetCurCtx(GETSCCTXNO(f));
            v := mqd.GetBit xor GETSPB(f);
            if v = 1 then Data[dp] := -oneplushalf else Data[dp] := oneplushalf;
            UpdateFlags4(flags, fp, frowstep, v = 1);
            flags[fp] := (flags[fp] or F_SIG) and (not F_VISIT);
            k := runlen + 1;
          end;

          while k < vscanlen do
          begin
            r := i + k; fp := FIdx(r, j); dp := r * W + j;
            f := flags[fp];
            if (f and (F_SIG or F_VISIT)) = 0 then
            begin
              mqd.SetCurCtx(GETZCCTXNO(f, Orient));
              if mqd.GetBit = 1 then
              begin
                mqd.SetCurCtx(GETSCCTXNO(f));
                v := mqd.GetBit xor GETSPB(f);
                if v = 1 then Data[dp] := -oneplushalf else Data[dp] := oneplushalf;
                UpdateFlags4(flags, fp, frowstep, v = 1);
                flags[fp] := flags[fp] or F_SIG;
              end;
            end;
            flags[fp] := flags[fp] and (not F_VISIT);
            Inc(k);
          end;
        end;
        Inc(i, 4);
      end;
    end;

    if passtype = 0 then Dec(bitpos);
  end;

  mqd.Free;
  ms.Free;
end;

// ===================================== full code-block decoder (cbsty) ==

// Neighbour-flag update with optional vertically-causal mode (the north
// neighbour is not updated when vcausal is set - jpc_t1cod JPC_UPDATEFLAGS4).
procedure UpdateFlags4V(var Flags: TIntArray; fp, frowstep: Integer;
  s, vcausal: Boolean);
var
  np, sp: Integer;
begin
  np := fp - frowstep; sp := fp + frowstep;
  if vcausal then
  begin
    Flags[sp - 1] := Flags[sp - 1] or F_NESIG;
    Flags[sp + 1] := Flags[sp + 1] or F_NWSIG;
    if s then
    begin
      Flags[sp] := Flags[sp] or (F_NSIG or F_NSGN);
      Flags[fp - 1] := Flags[fp - 1] or (F_ESIG or F_ESGN);
      Flags[fp + 1] := Flags[fp + 1] or (F_WSIG or F_WSGN);
    end
    else
    begin
      Flags[sp] := Flags[sp] or F_NSIG;
      Flags[fp - 1] := Flags[fp - 1] or F_ESIG;
      Flags[fp + 1] := Flags[fp + 1] or F_WSIG;
    end;
  end
  else
    UpdateFlags4(Flags, fp, frowstep, s);
end;

type
  TCblkDec = class
  public
    W, H, frowstep, fbase, Orient: Integer;
    Vcausal, Segsym: Boolean;
    flags, data: TIntArray;
    mqd: TMqDec;
    constructor Create(AW, AH, AOrient: Integer; AVcausal, ASegsym: Boolean);
    destructor Destroy; override;
    function FIdx(r, c: Integer): Integer; inline;
    procedure SetMQInput(ms: TMemStream);
    procedure ResetCtx;
    procedure SigPassMQ(bitpos: Integer);
    procedure RefPassMQ(bitpos: Integer);
    procedure ClnPassMQ(bitpos: Integer);
    procedure SigPassRaw(bs: TBitStream; bitpos: Integer);
    procedure RefPassRaw(bs: TBitStream; bitpos: Integer);
  end;

constructor TCblkDec.Create(AW, AH, AOrient: Integer; AVcausal, ASegsym: Boolean);
begin
  inherited Create;
  W := AW; H := AH; Orient := AOrient; Vcausal := AVcausal; Segsym := ASegsym;
  frowstep := W + 2; fbase := frowstep + 1;
  SetLength(flags, (W + 2) * (H + 2));
  SetLength(data, W * H);
  mqd := TMqDec.Create(NUMCTXS, nil);
  mqd.SetCtxs(mqctxs);
end;

destructor TCblkDec.Destroy;
begin
  mqd.Free;
  inherited Destroy;
end;

function TCblkDec.FIdx(r, c: Integer): Integer;
begin
  Result := fbase + r * frowstep + c;
end;

procedure TCblkDec.SetMQInput(ms: TMemStream);
begin
  mqd.SetInput(ms);
  mqd.Init;     // resets coder registers; contexts persist
end;

procedure TCblkDec.ResetCtx;
begin
  mqd.SetCtxs(mqctxs);
end;

procedure TCblkDec.SigPassMQ(bitpos: Integer);
var
  i, j, k, r, vsl, fp, dp, f, v, one, oph: Integer;
begin
  one := 1 shl bitpos; oph := one or (one shr 1);
  i := 0;
  while i < H do
  begin
    vsl := MinI(4, H - i);
    for j := 0 to W - 1 do
      for k := 0 to vsl - 1 do
      begin
        r := i + k; fp := FIdx(r, j); dp := r * W + j;
        f := flags[fp];
        if ((f and F_OTHSIGMSK) <> 0) and ((f and (F_SIG or F_VISIT)) = 0) then
        begin
          mqd.SetCurCtx(GETZCCTXNO(f, Orient));
          if mqd.GetBit = 1 then
          begin
            mqd.SetCurCtx(GETSCCTXNO(f));
            v := mqd.GetBit xor GETSPB(f);
            UpdateFlags4V(flags, fp, frowstep, v = 1, (k = 0) and Vcausal);
            flags[fp] := flags[fp] or F_SIG;
            if v = 1 then data[dp] := -oph else data[dp] := oph;
          end;
          flags[fp] := flags[fp] or F_VISIT;
        end;
      end;
    Inc(i, 4);
  end;
end;

procedure TCblkDec.SigPassRaw(bs: TBitStream; bitpos: Integer);
var
  i, j, k, r, vsl, fp, dp, f, v, sgn, one, oph: Integer;
begin
  one := 1 shl bitpos; oph := one or (one shr 1);
  i := 0;
  while i < H do
  begin
    vsl := MinI(4, H - i);
    for j := 0 to W - 1 do
      for k := 0 to vsl - 1 do
      begin
        r := i + k; fp := FIdx(r, j); dp := r * W + j;
        f := flags[fp];
        if ((f and F_OTHSIGMSK) <> 0) and ((f and (F_SIG or F_VISIT)) = 0) then
        begin
          v := bs.GetBit;
          if v = 1 then
          begin
            sgn := bs.GetBit;     // raw sign, no SPB
            UpdateFlags4V(flags, fp, frowstep, sgn = 1, (k = 0) and Vcausal);
            flags[fp] := flags[fp] or F_SIG;
            if sgn = 1 then data[dp] := -oph else data[dp] := oph;
          end;
          flags[fp] := flags[fp] or F_VISIT;
        end;
      end;
    Inc(i, 4);
  end;
end;

procedure TCblkDec.RefPassMQ(bitpos: Integer);
var
  i, j, k, r, vsl, fp, dp, one, poshalf, neghalf, t: Integer;
begin
  one := 1 shl bitpos; poshalf := one shr 1;
  if bitpos > 0 then neghalf := -poshalf else neghalf := -1;
  i := 0;
  while i < H do
  begin
    vsl := MinI(4, H - i);
    for j := 0 to W - 1 do
      for k := 0 to vsl - 1 do
      begin
        r := i + k; fp := FIdx(r, j); dp := r * W + j;
        if (flags[fp] and (F_SIG or F_VISIT)) = F_SIG then
        begin
          mqd.SetCurCtx(GETMAGCTXNO(flags[fp]));
          if mqd.GetBit = 1 then t := poshalf else t := neghalf;
          if data[dp] < 0 then data[dp] := data[dp] - t else data[dp] := data[dp] + t;
          flags[fp] := flags[fp] or F_REFINE;
        end;
      end;
    Inc(i, 4);
  end;
end;

procedure TCblkDec.RefPassRaw(bs: TBitStream; bitpos: Integer);
var
  i, j, k, r, vsl, fp, dp, one, poshalf, neghalf, t: Integer;
begin
  one := 1 shl bitpos; poshalf := one shr 1;
  if bitpos > 0 then neghalf := -poshalf else neghalf := -1;
  i := 0;
  while i < H do
  begin
    vsl := MinI(4, H - i);
    for j := 0 to W - 1 do
      for k := 0 to vsl - 1 do
      begin
        r := i + k; fp := FIdx(r, j); dp := r * W + j;
        if (flags[fp] and (F_SIG or F_VISIT)) = F_SIG then
        begin
          if bs.GetBit = 1 then t := poshalf else t := neghalf;
          if data[dp] < 0 then data[dp] := data[dp] - t else data[dp] := data[dp] + t;
          flags[fp] := flags[fp] or F_REFINE;
        end;
      end;
    Inc(i, 4);
  end;
end;

procedure TCblkDec.ClnPassMQ(bitpos: Integer);
var
  i, j, k, r, vsl, fp, dp, f, v, runlen, one, oph, segv: Integer;
  vc: Boolean;
begin
  one := 1 shl bitpos; oph := one or (one shr 1);
  i := 0;
  while i < H do
  begin
    vsl := MinI(4, H - i);
    for j := 0 to W - 1 do
    begin
      k := 0;
      if (vsl >= 4) and
         ((flags[FIdx(i, j)] and (F_SIG or F_VISIT or F_OTHSIGMSK)) = 0) and
         ((flags[FIdx(i + 1, j)] and (F_SIG or F_VISIT or F_OTHSIGMSK)) = 0) and
         ((flags[FIdx(i + 2, j)] and (F_SIG or F_VISIT or F_OTHSIGMSK)) = 0) and
         ((flags[FIdx(i + 3, j)] and (F_SIG or F_VISIT or F_OTHSIGMSK)) = 0) then
      begin
        mqd.SetCurCtx(AGGCTXNO);
        if mqd.GetBit = 0 then Continue;
        mqd.SetCurCtx(UCTXNO);
        runlen := (mqd.GetBit shl 1) or mqd.GetBit;
        r := i + runlen; fp := FIdx(r, j); dp := r * W + j;
        f := flags[fp];
        mqd.SetCurCtx(GETSCCTXNO(f));
        v := mqd.GetBit xor GETSPB(f);
        vc := (runlen = 0) and Vcausal;
        if v = 1 then data[dp] := -oph else data[dp] := oph;
        UpdateFlags4V(flags, fp, frowstep, v = 1, vc);
        flags[fp] := (flags[fp] or F_SIG) and (not F_VISIT);
        k := runlen + 1;
      end;
      while k < vsl do
      begin
        r := i + k; fp := FIdx(r, j); dp := r * W + j;
        f := flags[fp];
        if (f and (F_SIG or F_VISIT)) = 0 then
        begin
          mqd.SetCurCtx(GETZCCTXNO(f, Orient));
          if mqd.GetBit = 1 then
          begin
            mqd.SetCurCtx(GETSCCTXNO(f));
            v := mqd.GetBit xor GETSPB(f);
            vc := (k = 0) and Vcausal;
            if v = 1 then data[dp] := -oph else data[dp] := oph;
            UpdateFlags4V(flags, fp, frowstep, v = 1, vc);
            flags[fp] := flags[fp] or F_SIG;
          end;
        end;
        flags[fp] := flags[fp] and (not F_VISIT);
        Inc(k);
      end;
    end;
    Inc(i, 4);
  end;

  if Segsym then
  begin
    mqd.SetCurCtx(UCTXNO);
    segv := 0;
    segv := (segv shl 1) or mqd.GetBit;
    segv := (segv shl 1) or mqd.GetBit;
    segv := (segv shl 1) or mqd.GetBit;
    segv := (segv shl 1) or mqd.GetBit;
    // segv should be 0xA; ignore mismatch (corrupt stream)
  end;
end;

procedure T1DecodeSeg(const Segs: array of TSegInfo;
  W, H, Orient, NumBps, Cbsty: Integer; var Data: TIntArray);
var
  cb: TCblkDec;
  bitpos, passno, s, pp, passtype: Integer;
  segbytes: TBytes;
  segms: TMemStream;
  bs: TBitStream;
  vcausal, segsym, reset: Boolean;
begin
  SetLength(Data, W * H);
  FillChar(Data[0], W * H * SizeOf(Integer), 0);
  if (NumBps <= 0) or (Length(Segs) = 0) then Exit;

  vcausal := (Cbsty and COX_VSC) <> 0;
  segsym := (Cbsty and COX_SEGSYM) <> 0;
  reset := (Cbsty and COX_RESET) <> 0;

  cb := TCblkDec.Create(W, H, Orient, vcausal, segsym);
  try
    bitpos := NumBps - 1;
    passno := 0;
    for s := 0 to High(Segs) do
    begin
      segbytes := Copy(Segs[s].data, 0, Segs[s].dlen);
      bs := nil; segms := nil;
      if Segs[s].raw then
        bs := TBitStream.Create(TMemStream.Create(segbytes, Length(segbytes)), False)
      else
      begin
        segms := TMemStream.Create(segbytes, Length(segbytes));
        cb.SetMQInput(segms);
      end;
      for pp := 0 to Segs[s].np - 1 do
      begin
        passtype := passno mod 3;   // 0=CLN,1=SIG,2=REF
        if passtype = 1 then
        begin
          if Segs[s].raw then cb.SigPassRaw(bs, bitpos) else cb.SigPassMQ(bitpos);
        end
        else if passtype = 2 then
        begin
          if Segs[s].raw then cb.RefPassRaw(bs, bitpos) else cb.RefPassMQ(bitpos);
        end
        else
          cb.ClnPassMQ(bitpos);     // cleanup is always MQ
        if reset and not Segs[s].raw then cb.ResetCtx;
        if passtype = 0 then Dec(bitpos);
        Inc(passno);
      end;
      if bs <> nil then bs.Free;
    end;
    Move(cb.data[0], Data[0], W * H * SizeOf(Integer));
  finally
    cb.Free;
  end;
end;

initialization
  InitLuts;
  InitMqCtxs;

end.
