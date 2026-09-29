unit Av1.Itx;

// AV1 inverse transforms (add-to-destination). Ported from dav1d itx_1d.c
// (the 1D DCT/ADST/identity kernels) and itx_tmpl.c inv_txfm_add_c (the 2D
// driver). All right-shifts are arithmetic (SarLongint) — dav1d relies on
// signed >> flooring. Intermediate clipping matches the spec's 16-bit range.

{$mode delphi}{$H+}
{$RANGECHECKS OFF}{$OVERFLOWCHECKS OFF}

interface

uses SysUtils;

const
  ITX_4X4 = 0; ITX_8X8 = 1; ITX_16X16 = 2; ITX_32X32 = 3; ITX_64X64 = 4;
  ItxShift: array[0..4] of Integer = (0, 1, 2, 2, 2);
  ItxDim: array[0..4] of Integer = (4, 8, 16, 32, 64);
  // Rectangular-inclusive tables, indexed by RectTxfmSize (0..18).
  ItxWpx: array[0..18] of Integer = (4,8,16,32,64, 4,8,8,16,16,32,32,64, 4,16,8,32,16,64);
  ItxHpx: array[0..18] of Integer = (4,8,16,32,64, 8,4,16,8,32,16,64,32, 16,4,32,8,64,16);
  ItxShiftT: array[0..18] of Integer = (0,1,2,2,2, 0,0,1,1,1,1,1,1, 1,1,2,2,2,2);

type
  TItx1dFn = procedure(c: PInteger; stride, min, max: Integer);

function ClipPixel8(V: Integer): Byte; inline;

procedure InvDct4(c: PInteger; stride, min, max: Integer);
procedure InvDct8(c: PInteger; stride, min, max: Integer);
procedure InvDct16(c: PInteger; stride, min, max: Integer);
procedure InvDct32(c: PInteger; stride, min, max: Integer);
procedure InvDct64(c: PInteger; stride, min, max: Integer);

// Transform kinds for the 1D selector.
const
  TK_DCT = 0; TK_ADST = 1; TK_FLIPADST = 2; TK_IDENTITY = 3;
  // txtp -> (row kind, col kind); row=first_1d (over rows), col=second_1d.
  TxtpRowKind: array[0..15] of Byte =
    (TK_DCT,TK_DCT,TK_ADST,TK_ADST,TK_DCT,TK_FLIPADST,TK_FLIPADST,TK_FLIPADST,
     TK_ADST,TK_IDENTITY,TK_IDENTITY,TK_DCT,TK_IDENTITY,TK_ADST,TK_IDENTITY,TK_FLIPADST);
  TxtpColKind: array[0..15] of Byte =
    (TK_DCT,TK_ADST,TK_DCT,TK_ADST,TK_FLIPADST,TK_DCT,TK_FLIPADST,TK_ADST,
     TK_FLIPADST,TK_IDENTITY,TK_DCT,TK_IDENTITY,TK_ADST,TK_IDENTITY,TK_FLIPADST,TK_IDENTITY);

procedure InvAdst4(c: PInteger; stride, min, max: Integer);
procedure InvAdst8(c: PInteger; stride, min, max: Integer);
procedure InvAdst16(c: PInteger; stride, min, max: Integer);
procedure InvFlipAdst4(c: PInteger; stride, min, max: Integer);
procedure InvFlipAdst8(c: PInteger; stride, min, max: Integer);
procedure InvFlipAdst16(c: PInteger; stride, min, max: Integer);
procedure InvIdentity4(c: PInteger; stride, min, max: Integer);
procedure InvIdentity8(c: PInteger; stride, min, max: Integer);
procedure InvIdentity16(c: PInteger; stride, min, max: Integer);
procedure InvIdentity32(c: PInteger; stride, min, max: Integer);

// Row/column 1D kernel for (kind, size) where size in {4,8,16,32,64}.
function ItxFn(kind, size: Integer): TItx1dFn;

// DC-only fast path (has_dconly). ACf[0] is the dequantised DC; consumed.
procedure InvTxfmAddDcOnly(Dst: PWord; Stride: Integer; ACf: PInteger;
  W, H, Shift, PixMax: Integer; IsRect2: Boolean);

// Full 2D inverse transform + add. First/Second are the row/column 1D kernels.
// Bd is the sample bit depth (8/10/12), used for the intermediate clamps.
procedure InvTxfmAdd(Dst: PWord; DstStride: Integer; Coeff: PInteger;
  Eob, W, H, Shift: Integer; First, Second: TItx1dFn; HasDconly, Bd: Integer);

// Lossless 4x4 inverse Walsh-Hadamard transform + add (dav1d WHT_WHT).
procedure InvWhtAdd4x4(Dst: PWord; DstStride: Integer; Coeff: PInteger; PixMax: Integer);

implementation

function Sar(V, N: Integer): Integer; inline;
begin Result := SarLongint(V, N); end;

function Clip(V, Mn, Mx: Integer): Integer; inline;
begin
  if V < Mn then Result := Mn
  else if V > Mx then Result := Mx
  else Result := V;
end;

function ClipPixel8(V: Integer): Byte; inline;
begin
  if V < 0 then Result := 0
  else if V > 255 then Result := 255
  else Result := Byte(V);
end;

function ClipPixelM(V, PixMax: Integer): Word; inline;
begin
  if V < 0 then Result := 0
  else if V > PixMax then Result := Word(PixMax)
  else Result := Word(V);
end;

// ---- 1D DCT kernels (itx_1d.c). c[k] means c[k*stride]. ----

procedure Dct4Internal(c: PInteger; stride, min, max, tx64: Integer);
var in0, in1, in2, in3, t0, t1, t2, t3: Integer;
begin
  in0 := c[0]; in1 := c[stride];
  if tx64 <> 0 then
  begin
    t0 := Sar(in0 * 181 + 128, 8); t1 := t0;
    t2 := Sar(in1 * 1567 + 2048, 12);
    t3 := Sar(in1 * 3784 + 2048, 12);
  end
  else
  begin
    in2 := c[2 * stride]; in3 := c[3 * stride];
    t0 := Sar((in0 + in2) * 181 + 128, 8);
    t1 := Sar((in0 - in2) * 181 + 128, 8);
    t2 := Sar(in1 * 1567 - in3 * (3784 - 4096) + 2048, 12) - in3;
    t3 := Sar(in1 * (3784 - 4096) + in3 * 1567 + 2048, 12) + in1;
  end;
  c[0]          := Clip(t0 + t3, min, max);
  c[stride]     := Clip(t1 + t2, min, max);
  c[2 * stride] := Clip(t1 - t2, min, max);
  c[3 * stride] := Clip(t0 - t3, min, max);
end;

procedure Dct8Internal(c: PInteger; stride, min, max, tx64: Integer);
var in1, in3, in5, in7, t0, t1, t2, t3, t4, t5, t6, t7, t4a, t5a, t6a, t7a: Integer;
begin
  Dct4Internal(c, stride shl 1, min, max, tx64);
  in1 := c[stride]; in3 := c[3 * stride];
  if tx64 <> 0 then
  begin
    t4a := Sar(in1 * 799 + 2048, 12);
    t5a := Sar(in3 * (-2276) + 2048, 12);
    t6a := Sar(in3 * 3406 + 2048, 12);
    t7a := Sar(in1 * 4017 + 2048, 12);
  end
  else
  begin
    in5 := c[5 * stride]; in7 := c[7 * stride];
    t4a := Sar(in1 * 799 - in7 * (4017 - 4096) + 2048, 12) - in7;
    t5a := Sar(in5 * 1703 - in3 * 1138 + 1024, 11);
    t6a := Sar(in5 * 1138 + in3 * 1703 + 1024, 11);
    t7a := Sar(in1 * (4017 - 4096) + in7 * 799 + 2048, 12) + in1;
  end;
  t4  := Clip(t4a + t5a, min, max);
  t5a := Clip(t4a - t5a, min, max);
  t7  := Clip(t7a + t6a, min, max);
  t6a := Clip(t7a - t6a, min, max);
  t5  := Sar((t6a - t5a) * 181 + 128, 8);
  t6  := Sar((t6a + t5a) * 181 + 128, 8);
  t0 := c[0]; t1 := c[2 * stride]; t2 := c[4 * stride]; t3 := c[6 * stride];
  c[0]          := Clip(t0 + t7, min, max);
  c[stride]     := Clip(t1 + t6, min, max);
  c[2 * stride] := Clip(t2 + t5, min, max);
  c[3 * stride] := Clip(t3 + t4, min, max);
  c[4 * stride] := Clip(t3 - t4, min, max);
  c[5 * stride] := Clip(t2 - t5, min, max);
  c[6 * stride] := Clip(t1 - t6, min, max);
  c[7 * stride] := Clip(t0 - t7, min, max);
end;

procedure Dct16Internal(c: PInteger; stride, min, max, tx64: Integer);
var
  in1, in3, in5, in7, in9, in11, in13, in15: Integer;
  t0, t1, t2, t3, t4, t5, t6, t7: Integer;
  t8, t9, t10, t11, t12, t13, t14, t15: Integer;
  t8a, t9a, t10a, t11a, t12a, t13a, t14a, t15a: Integer;
begin
  Dct8Internal(c, stride shl 1, min, max, tx64);
  in1 := c[stride]; in3 := c[3 * stride]; in5 := c[5 * stride]; in7 := c[7 * stride];
  if tx64 <> 0 then
  begin
    t8a  := Sar(in1 * 401 + 2048, 12);
    t9a  := Sar(in7 * (-2598) + 2048, 12);
    t10a := Sar(in5 * 1931 + 2048, 12);
    t11a := Sar(in3 * (-1189) + 2048, 12);
    t12a := Sar(in3 * 3920 + 2048, 12);
    t13a := Sar(in5 * 3612 + 2048, 12);
    t14a := Sar(in7 * 3166 + 2048, 12);
    t15a := Sar(in1 * 4076 + 2048, 12);
  end
  else
  begin
    in9 := c[9 * stride]; in11 := c[11 * stride]; in13 := c[13 * stride]; in15 := c[15 * stride];
    t8a  := Sar(in1  * 401 - in15 * (4076 - 4096) + 2048, 12) - in15;
    t9a  := Sar(in9  * 1583 - in7 * 1299 + 1024, 11);
    t10a := Sar(in5  * 1931 - in11 * (3612 - 4096) + 2048, 12) - in11;
    t11a := Sar(in13 * (3920 - 4096) - in3 * 1189 + 2048, 12) + in13;
    t12a := Sar(in13 * 1189 + in3 * (3920 - 4096) + 2048, 12) + in3;
    t13a := Sar(in5  * (3612 - 4096) + in11 * 1931 + 2048, 12) + in5;
    t14a := Sar(in9  * 1299 + in7 * 1583 + 1024, 11);
    t15a := Sar(in1  * (4076 - 4096) + in15 * 401 + 2048, 12) + in1;
  end;
  t8  := Clip(t8a  + t9a, min, max);
  t9  := Clip(t8a  - t9a, min, max);
  t10 := Clip(t11a - t10a, min, max);
  t11 := Clip(t11a + t10a, min, max);
  t12 := Clip(t12a + t13a, min, max);
  t13 := Clip(t12a - t13a, min, max);
  t14 := Clip(t15a - t14a, min, max);
  t15 := Clip(t15a + t14a, min, max);
  t9a  := Sar(t14 * 1567 - t9 * (3784 - 4096) + 2048, 12) - t9;
  t14a := Sar(t14 * (3784 - 4096) + t9 * 1567 + 2048, 12) + t14;
  t10a := Sar(-(t13 * (3784 - 4096) + t10 * 1567) + 2048, 12) - t13;
  t13a := Sar(t13 * 1567 - t10 * (3784 - 4096) + 2048, 12) - t10;
  t8a  := Clip(t8 + t11, min, max);
  t9   := Clip(t9a + t10a, min, max);
  t10  := Clip(t9a - t10a, min, max);
  t11a := Clip(t8 - t11, min, max);
  t12a := Clip(t15 - t12, min, max);
  t13  := Clip(t14a - t13a, min, max);
  t14  := Clip(t14a + t13a, min, max);
  t15a := Clip(t15 + t12, min, max);
  t10a := Sar((t13 - t10) * 181 + 128, 8);
  t13a := Sar((t13 + t10) * 181 + 128, 8);
  t11  := Sar((t12a - t11a) * 181 + 128, 8);
  t12  := Sar((t12a + t11a) * 181 + 128, 8);
  t0 := c[0]; t1 := c[2*stride]; t2 := c[4*stride]; t3 := c[6*stride];
  t4 := c[8*stride]; t5 := c[10*stride]; t6 := c[12*stride]; t7 := c[14*stride];
  c[0]       := Clip(t0 + t15a, min, max);
  c[stride]  := Clip(t1 + t14, min, max);
  c[2*stride]:= Clip(t2 + t13a, min, max);
  c[3*stride]:= Clip(t3 + t12, min, max);
  c[4*stride]:= Clip(t4 + t11, min, max);
  c[5*stride]:= Clip(t5 + t10a, min, max);
  c[6*stride]:= Clip(t6 + t9, min, max);
  c[7*stride]:= Clip(t7 + t8a, min, max);
  c[8*stride]:= Clip(t7 - t8a, min, max);
  c[9*stride]:= Clip(t6 - t9, min, max);
  c[10*stride]:=Clip(t5 - t10a, min, max);
  c[11*stride]:=Clip(t4 - t11, min, max);
  c[12*stride]:=Clip(t3 - t12, min, max);
  c[13*stride]:=Clip(t2 - t13a, min, max);
  c[14*stride]:=Clip(t1 - t14, min, max);
  c[15*stride]:=Clip(t0 - t15a, min, max);
end;

{$I Av1.ItxDct32.inc}
{$I Av1.ItxDct64.inc}

procedure InvDct4(c: PInteger; stride, min, max: Integer); begin Dct4Internal(c, stride, min, max, 0); end;
procedure InvDct8(c: PInteger; stride, min, max: Integer); begin Dct8Internal(c, stride, min, max, 0); end;
procedure InvDct16(c: PInteger; stride, min, max: Integer); begin Dct16Internal(c, stride, min, max, 0); end;
procedure InvDct32(c: PInteger; stride, min, max: Integer); begin Dct32Internal(c, stride, min, max, 0); end;

{$I Av1.ItxAdst.inc}

procedure InvAdst4(c: PInteger; stride, min, max: Integer); begin Adst4Internal(c, stride, min, max, c, stride); end;
procedure InvAdst8(c: PInteger; stride, min, max: Integer); begin Adst8Internal(c, stride, min, max, c, stride); end;
procedure InvAdst16(c: PInteger; stride, min, max: Integer); begin Adst16Internal(c, stride, min, max, c, stride); end;
procedure InvFlipAdst4(c: PInteger; stride, min, max: Integer); begin Adst4Internal(c, stride, min, max, @c[3*stride], -stride); end;
procedure InvFlipAdst8(c: PInteger; stride, min, max: Integer); begin Adst8Internal(c, stride, min, max, @c[7*stride], -stride); end;
procedure InvFlipAdst16(c: PInteger; stride, min, max: Integer); begin Adst16Internal(c, stride, min, max, @c[15*stride], -stride); end;

procedure InvIdentity4(c: PInteger; stride, min, max: Integer);
var i, v: Integer;
begin for i := 0 to 3 do begin v := c[i*stride]; c[i*stride] := v + Sar(v*1697+2048, 12); end; end;
procedure InvIdentity8(c: PInteger; stride, min, max: Integer);
var i: Integer;
begin for i := 0 to 7 do c[i*stride] := c[i*stride] * 2; end;
procedure InvIdentity16(c: PInteger; stride, min, max: Integer);
var i, v: Integer;
begin for i := 0 to 15 do begin v := c[i*stride]; c[i*stride] := 2*v + Sar(v*1697+1024, 11); end; end;
procedure InvIdentity32(c: PInteger; stride, min, max: Integer);
var i: Integer;
begin for i := 0 to 31 do c[i*stride] := c[i*stride] * 4; end;

function ItxFn(kind, size: Integer): TItx1dFn;
begin
  case kind of
    TK_DCT:
      case size of
        4: Result := @InvDct4; 8: Result := @InvDct8; 16: Result := @InvDct16;
        32: Result := @InvDct32;
      else Result := @InvDct64; end;
    TK_ADST:
      case size of 4: Result := @InvAdst4; 8: Result := @InvAdst8; else Result := @InvAdst16; end;
    TK_FLIPADST:
      case size of 4: Result := @InvFlipAdst4; 8: Result := @InvFlipAdst8; else Result := @InvFlipAdst16; end;
  else // TK_IDENTITY
    case size of
      4: Result := @InvIdentity4; 8: Result := @InvIdentity8; 16: Result := @InvIdentity16;
    else Result := @InvIdentity32; end;
  end;
end;

// ---- drivers ----

procedure InvTxfmAddDcOnly(Dst: PWord; Stride: Integer; ACf: PInteger;
  W, H, Shift, PixMax: Integer; IsRect2: Boolean);
var dc, rnd, x, y: Integer; Row: PWord;
begin
  dc := ACf[0]; ACf[0] := 0;
  rnd := (1 shl Shift) shr 1;
  if IsRect2 then dc := Sar(dc * 181 + 128, 8);
  dc := Sar(dc * 181 + 128, 8);
  dc := Sar(dc + rnd, Shift);
  dc := Sar(dc * 181 + 128 + 2048, 12);
  for y := 0 to H - 1 do
  begin
    Row := Dst + y * Stride;
    for x := 0 to W - 1 do Row[x] := ClipPixelM(Row[x] + dc, PixMax);
  end;
end;

procedure InvTxfmAdd(Dst: PWord; DstStride: Integer; Coeff: PInteger;
  Eob, W, H, Shift: Integer; First, Second: TItx1dFn; HasDconly, Bd: Integer);
var
  isRect2: Boolean;
  rnd, sh, sw, i, x, y, rcMin, rcMax, ccMin, ccMax, dc, pixMax: Integer;
  tmp: array[0..64*64-1] of Integer;
  cptr: PInteger; Row: PWord;
begin
  isRect2 := (W * 2 = H) or (H * 2 = W);
  rnd := (1 shl Shift) shr 1;
  pixMax := (1 shl Bd) - 1;

  if Eob < HasDconly then
  begin
    InvTxfmAddDcOnly(Dst, DstStride, Coeff, W, H, Shift, pixMax, isRect2);
    Exit;
  end;

  sh := W; if H < W then sh := H; if sh > 32 then sh := 32;   // imin(h,32) -> below
  sh := H; if sh > 32 then sh := 32;
  sw := W; if sw > 32 then sw := 32;
  // itx intermediate clamps: 8-bit uses INT16; higher bd uses ~max<<7 (row), ~max<<5 (col).
  if Bd = 8 then
  begin rcMin := -32768; ccMin := -32768; end
  else
  begin rcMin := (not pixMax) shl 7; ccMin := (not pixMax) shl 5; end;
  rcMax := not rcMin; ccMax := not ccMin;

  FillChar(tmp, SizeOf(tmp), 0);
  cptr := @tmp[0];
  for y := 0 to sh - 1 do
  begin
    if isRect2 then
      for x := 0 to sw - 1 do cptr[x] := Sar(Coeff[y + x * sh] * 181 + 128, 8)
    else
      for x := 0 to sw - 1 do cptr[x] := Coeff[y + x * sh];
    First(cptr, 1, rcMin, rcMax);
    cptr := cptr + W;
  end;

  // clear the consumed coefficients
  FillChar(Coeff^, sw * sh * SizeOf(Integer), 0);

  for i := 0 to W * sh - 1 do
    tmp[i] := Clip(Sar(tmp[i] + rnd, Shift), ccMin, ccMax);

  for x := 0 to W - 1 do
    Second(@tmp[x], W, ccMin, ccMax);

  cptr := @tmp[0];
  for y := 0 to H - 1 do
  begin
    Row := Dst + y * DstStride;
    for x := 0 to W - 1 do
    begin
      Row[x] := ClipPixelM(Row[x] + Sar(cptr^ + 8, 4), pixMax);
      Inc(cptr);
    end;
  end;
end;

procedure Wht1d(c: PInteger; stride: Integer); inline;
var in0, in1, in2, in3, t0, t1, t2, t3, t4: Integer;
begin
  in0 := c[0]; in1 := c[stride]; in2 := c[2*stride]; in3 := c[3*stride];
  t0 := in0 + in1; t2 := in2 - in3; t4 := Sar(t0 - t2, 1);
  t3 := t4 - in3; t1 := t4 - in1;
  c[0] := t0 - t3; c[stride] := t3; c[2*stride] := t1; c[3*stride] := t2 + t1;
end;

procedure InvWhtAdd4x4(Dst: PWord; DstStride: Integer; Coeff: PInteger; PixMax: Integer);
var tmp: array[0..15] of Integer; x, y: Integer; Row: PWord;
begin
  for y := 0 to 3 do
  begin
    for x := 0 to 3 do tmp[y*4 + x] := Sar(Coeff[y + x*4], 2);
    Wht1d(@tmp[y*4], 1);
  end;
  for x := 0 to 3 do Wht1d(@tmp[x], 4);
  FillChar(Coeff^, 16 * SizeOf(Integer), 0);
  for y := 0 to 3 do
  begin
    Row := Dst + y * DstStride;
    for x := 0 to 3 do Row[x] := ClipPixelM(Row[x] + tmp[y*4 + x], PixMax);
  end;
end;

end.
