// BPG decoder -- Free Pascal port of libbpg 0.9.8
// Output stage: chroma upsampling (Lanczos), colour space conversion to
// RGB24/RGB48/RGBA/CMYK, alpha combine/divide, and per-line output.
// Corresponds to: libbpg.c from clamp_pix() to bpg_decoder_get_line().
//
// libbpg is built with USE_VAR_BIT_DEPTH and USE_RGB48, so PIXEL is uint16_t
// throughout and all six output formats exist.
unit bpg_output;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  Math, bpg_common, bpg_container;

function bpg_decoder_start(S: PBPGDecoderContext; out_fmt: Integer): Integer;
function bpg_decoder_get_line(S: PBPGDecoderContext; rgb_line1: Pointer): Integer;
procedure bpg_decoder_output_end(S: PBPGDecoderContext);

implementation

const
  // 8 tap Lanczos interpolator (phase = 0, symmetric)
  IP0C0 = 40;
  IP0C1 = -11;
  IP0C2 = 4;
  IP0C3 = -1;
  // 7 tap Lanczos interpolator (phase = 0.5)
  IP1C0 = -1;
  IP1C1 = 4;
  IP1C2 = -10;
  IP1C3 = 57;
  IP1C4 = 18;
  IP1C5 = -6;
  IP1C6 = 2;

  DIV8_BITS  = 16;
  DIV16_BITS = 15;

type
  // the vertical interpolation ring buffer, as held by TBPGDecoderContext
  TPWordArray8 = array[0 .. ITAPS - 1] of PWord;
  PPWordArray8 = ^TPWordArray8;

function clamp_pix(A, pixel_max: Integer): Integer; inline;
begin
  if A < 0 then Result := 0
  else if A > pixel_max then Result := pixel_max
  else Result := A;
end;

function clamp8(A: Integer): Integer; inline;
begin
  if A < 0 then Result := 0
  else if A > 255 then Result := 255
  else Result := A;
end;

function clamp16(A: Integer): Integer; inline;
begin
  if A < 0 then Result := 0
  else if A > 65535 then Result := 65535
  else Result := A;
end;

// ---------------- chroma upsampling ----------------

// interpolate by a factor of two, chroma aligned with the luma samples
procedure interp2p0_simple(Dst, Src: PWord; N, bit_depth: Integer);
var
  pixel_max: Integer;
begin
  pixel_max := (1 shl bit_depth) - 1;
  while N >= 2 do
  begin
    Dst[0] := Src[0];
    Dst[1] := Word(clamp_pix(SAR((Src[-3] + Src[4]) * IP0C3 +
                                 (Src[-2] + Src[3]) * IP0C2 +
                                 (Src[-1] + Src[2]) * IP0C1 +
                                 (Src[0] + Src[1]) * IP0C0 + 32, 6), pixel_max));
    Dst := Dst + 2;
    Src := Src + 1;
    Dec(N, 2);
  end;
  if N <> 0 then
    Dst[0] := Src[0];
end;

procedure interp2p0_simple16(Dst: PWord; Src: PInt16; N, bit_depth: Integer);
var
  shift1, offset1, shift0, offset0, pixel_max: Integer;
begin
  pixel_max := (1 shl bit_depth) - 1;
  shift0 := 14 - bit_depth;
  offset0 := (1 shl shift0) shr 1;
  shift1 := 20 - bit_depth;
  offset1 := 1 shl (shift1 - 1);

  while N >= 2 do
  begin
    Dst[0] := Word(clamp_pix(SAR(Src[0] + offset0, shift0), pixel_max));
    Dst[1] := Word(clamp_pix(SAR((Src[-3] + Src[4]) * IP0C3 +
                                 (Src[-2] + Src[3]) * IP0C2 +
                                 (Src[-1] + Src[2]) * IP0C1 +
                                 (Src[0] + Src[1]) * IP0C0 + offset1, shift1),
                             pixel_max));
    Dst := Dst + 2;
    Src := Src + 1;
    Dec(N, 2);
  end;
  if N <> 0 then
    Dst[0] := Word(clamp_pix(SAR(Src[0] + offset0, shift0), pixel_max));
end;

// interpolate by a factor of two, chroma between the luma samples
procedure interp2p1_simple(Dst, Src: PWord; N, bit_depth: Integer);
var
  pixel_max, a0, a1, a2, a3, a4, a5, a6: Integer;
begin
  pixel_max := (1 shl bit_depth) - 1;
  a1 := Src[-3];
  a2 := Src[-2];
  a3 := Src[-1];
  a4 := Src[0];
  a5 := Src[1];
  a6 := Src[2];

  while N >= 2 do
  begin
    a0 := a1; a1 := a2; a2 := a3; a3 := a4; a4 := a5; a5 := a6; a6 := Src[3];
    Dst[0] := Word(clamp_pix(SAR(a0 * IP1C6 + a1 * IP1C5 + a2 * IP1C4 + a3 * IP1C3 +
                                 a4 * IP1C2 + a5 * IP1C1 + a6 * IP1C0 + 32, 6), pixel_max));
    Dst[1] := Word(clamp_pix(SAR(a0 * IP1C0 + a1 * IP1C1 + a2 * IP1C2 + a3 * IP1C3 +
                                 a4 * IP1C4 + a5 * IP1C5 + a6 * IP1C6 + 32, 6), pixel_max));
    Dst := Dst + 2;
    Src := Src + 1;
    Dec(N, 2);
  end;
  if N <> 0 then
  begin
    a0 := a1; a1 := a2; a2 := a3; a3 := a4; a4 := a5; a5 := a6; a6 := Src[3];
    Dst[0] := Word(clamp_pix(SAR(a0 * IP1C6 + a1 * IP1C5 + a2 * IP1C4 + a3 * IP1C3 +
                                 a4 * IP1C2 + a5 * IP1C1 + a6 * IP1C0 + 32, 6), pixel_max));
  end;
end;

procedure interp2p1_simple16(Dst: PWord; Src: PInt16; N, bit_depth: Integer);
var
  Shift, Offset, pixel_max, a0, a1, a2, a3, a4, a5, a6: Integer;
begin
  pixel_max := (1 shl bit_depth) - 1;
  Shift := 20 - bit_depth;
  Offset := 1 shl (Shift - 1);
  a1 := Src[-3];
  a2 := Src[-2];
  a3 := Src[-1];
  a4 := Src[0];
  a5 := Src[1];
  a6 := Src[2];

  while N >= 2 do
  begin
    a0 := a1; a1 := a2; a2 := a3; a3 := a4; a4 := a5; a5 := a6; a6 := Src[3];
    Dst[0] := Word(clamp_pix(SAR(a0 * IP1C6 + a1 * IP1C5 + a2 * IP1C4 + a3 * IP1C3 +
                                 a4 * IP1C2 + a5 * IP1C1 + a6 * IP1C0 + Offset, Shift),
                             pixel_max));
    Dst[1] := Word(clamp_pix(SAR(a0 * IP1C0 + a1 * IP1C1 + a2 * IP1C2 + a3 * IP1C3 +
                                 a4 * IP1C4 + a5 * IP1C5 + a6 * IP1C6 + Offset, Shift),
                             pixel_max));
    Dst := Dst + 2;
    Src := Src + 1;
    Dec(N, 2);
  end;
  if N <> 0 then
  begin
    a0 := a1; a1 := a2; a2 := a3; a3 := a4; a4 := a5; a5 := a6; a6 := Src[3];
    Dst[0] := Word(clamp_pix(SAR(a0 * IP1C6 + a1 * IP1C5 + a2 * IP1C4 + a3 * IP1C3 +
                                 a4 * IP1C2 + a5 * IP1C1 + a6 * IP1C0 + Offset, Shift),
                             pixel_max));
  end;
end;

// tmp_buf holds (n2 + 2 * ITAPS2 - 1) pixels
procedure interp2_h(Dst, Src: PWord; N, bit_depth, Phase: Integer; tmp_buf: PWord);
var
  src1: PWord;
  V: Word;
  I, n2: Integer;
begin
  src1 := tmp_buf;
  n2 := (N + 1) div 2;
  Move(Src^, src1[ITAPS2 - 1], n2 * SizeOf(Word));

  V := Src[0];
  for I := 0 to ITAPS2 - 2 do
    src1[I] := V;
  V := Src[n2 - 1];
  for I := 0 to ITAPS2 - 1 do
    src1[ITAPS2 - 1 + n2 + I] := V;

  if Phase = 0 then
    interp2p0_simple(Dst, src1 + (ITAPS2 - 1), N, bit_depth)
  else
    interp2p1_simple(Dst, src1 + (ITAPS2 - 1), N, bit_depth);
end;

// y_pos is the position of sample '0' in the circular buffer 'Src'
procedure interp2_vh(Dst: PWord; Src: PPWordArray8; N, y_pos: Integer;
  tmp_buf: PInt16; bit_depth, frac_pos, c_h_phase: Integer);
var
  src0, src1, src2, src3, src4, src5, src6: PWord;
  I, n2, Shift, Rnd: Integer;
  V: Int16;
begin
  src0 := Src^[(y_pos - 3) and 7];
  src1 := Src^[(y_pos - 2) and 7];
  src2 := Src^[(y_pos - 1) and 7];
  src3 := Src^[(y_pos + 0) and 7];
  src4 := Src^[(y_pos + 1) and 7];
  src5 := Src^[(y_pos + 2) and 7];
  src6 := Src^[(y_pos + 3) and 7];

  // vertical interpolation first
  Shift := bit_depth - 8;
  Rnd := (1 shl Shift) shr 1;
  n2 := (N + 1) div 2;
  if frac_pos = 0 then
  begin
    for I := 0 to n2 - 1 do
      tmp_buf[ITAPS2 - 1 + I] := Int16(SAR(
        src0[I] * IP1C6 + src1[I] * IP1C5 + src2[I] * IP1C4 + src3[I] * IP1C3 +
        src4[I] * IP1C2 + src5[I] * IP1C1 + src6[I] * IP1C0 + Rnd, Shift));
  end
  else
  begin
    for I := 0 to n2 - 1 do
      tmp_buf[ITAPS2 - 1 + I] := Int16(SAR(
        src0[I] * IP1C0 + src1[I] * IP1C1 + src2[I] * IP1C2 + src3[I] * IP1C3 +
        src4[I] * IP1C4 + src5[I] * IP1C5 + src6[I] * IP1C6 + Rnd, Shift));
  end;

  // then horizontal interpolation
  V := tmp_buf[ITAPS2 - 1];
  for I := 0 to ITAPS2 - 2 do
    tmp_buf[I] := V;
  V := tmp_buf[ITAPS2 - 1 + n2 - 1];
  for I := 0 to ITAPS2 - 1 do
    tmp_buf[ITAPS2 - 1 + n2 + I] := V;

  if c_h_phase = 0 then
    interp2p0_simple16(Dst, tmp_buf + (ITAPS2 - 1), N, bit_depth)
  else
    interp2p1_simple16(Dst, tmp_buf + (ITAPS2 - 1), N, bit_depth);
end;

// ---------------- 8 bit output ----------------

procedure ycc_to_rgb24(CS: PColorConvertState; Dst: PByte;
  y_ptr, cb_ptr, cr_ptr: PWord; N, Incr: Integer);
var
  Q: PByte;
  y_val, cb_val, cr_val, X: Integer;
  c_r_cr, c_g_cb, c_g_cr, c_b_cb, Rnd, Shift, Center, c_one: Integer;
begin
  Q := Dst;
  c_r_cr := CS^.c_r_cr;
  c_g_cb := CS^.c_g_cb;
  c_g_cr := CS^.c_g_cr;
  c_b_cb := CS^.c_b_cb;
  c_one := CS^.y_one;
  Rnd := CS^.y_offset;
  Shift := CS^.c_shift;
  Center := CS^.c_center;
  for X := 0 to N - 1 do
  begin
    y_val := y_ptr[X] * c_one;
    cb_val := cb_ptr[X] - Center;
    cr_val := cr_ptr[X] - Center;
    Q[0] := Byte(clamp8(SAR(y_val + c_r_cr * cr_val + Rnd, Shift)));
    Q[1] := Byte(clamp8(SAR(y_val - c_g_cb * cb_val - c_g_cr * cr_val + Rnd, Shift)));
    Q[2] := Byte(clamp8(SAR(y_val + c_b_cb * cb_val + Rnd, Shift)));
    Q := Q + Incr;
  end;
end;

procedure ycgco_to_rgb24(CS: PColorConvertState; Dst: PByte;
  y_ptr, cb_ptr, cr_ptr: PWord; N, Incr: Integer);
var
  Q: PByte;
  y_val, cb_val, cr_val, X, Rnd, Shift, Center, c_one: Integer;
begin
  Q := Dst;
  c_one := CS^.y_one;
  Rnd := CS^.y_offset;
  Shift := CS^.c_shift;
  Center := CS^.c_center;
  for X := 0 to N - 1 do
  begin
    y_val := y_ptr[X];
    cb_val := cb_ptr[X] - Center;
    cr_val := cr_ptr[X] - Center;
    Q[0] := Byte(clamp8(SAR((y_val - cb_val + cr_val) * c_one + Rnd, Shift)));
    Q[1] := Byte(clamp8(SAR((y_val + cb_val) * c_one + Rnd, Shift)));
    Q[2] := Byte(clamp8(SAR((y_val - cb_val - cr_val) * c_one + Rnd, Shift)));
    Q := Q + Incr;
  end;
end;

procedure gray_to_rgb24(CS: PColorConvertState; Dst: PByte;
  y_ptr, cb_ptr, cr_ptr: PWord; N, Incr: Integer);
var
  Q: PByte;
  X, y_val, C, Rnd, Shift: Integer;
begin
  Q := Dst;
  if (CS^.bit_depth = 8) and (CS^.limited_range = 0) then
  begin
    for X := 0 to N - 1 do
    begin
      y_val := y_ptr[X];
      Q[0] := Byte(y_val);
      Q[1] := Byte(y_val);
      Q[2] := Byte(y_val);
      Q := Q + Incr;
    end;
  end
  else
  begin
    C := CS^.y_one;
    Rnd := CS^.y_offset;
    Shift := CS^.c_shift;
    for X := 0 to N - 1 do
    begin
      y_val := clamp8(SAR(y_ptr[X] * C + Rnd, Shift));
      Q[0] := Byte(y_val);
      Q[1] := Byte(y_val);
      Q[2] := Byte(y_val);
      Q := Q + Incr;
    end;
  end;
end;

procedure rgb_to_rgb24(CS: PColorConvertState; Dst: PByte;
  y_ptr, cb_ptr, cr_ptr: PWord; N, Incr: Integer);
var
  Q: PByte;
  X, C, Rnd, Shift: Integer;
begin
  Q := Dst;
  if (CS^.bit_depth = 8) and (CS^.limited_range = 0) then
  begin
    for X := 0 to N - 1 do
    begin
      Q[0] := Byte(cr_ptr[X]);
      Q[1] := Byte(y_ptr[X]);
      Q[2] := Byte(cb_ptr[X]);
      Q := Q + Incr;
    end;
  end
  else
  begin
    C := CS^.y_one;
    Rnd := CS^.y_offset;
    Shift := CS^.c_shift;
    for X := 0 to N - 1 do
    begin
      Q[0] := Byte(clamp8(SAR(cr_ptr[X] * C + Rnd, Shift)));
      Q[1] := Byte(clamp8(SAR(y_ptr[X] * C + Rnd, Shift)));
      Q[2] := Byte(clamp8(SAR(cb_ptr[X] * C + Rnd, Shift)));
      Q := Q + Incr;
    end;
  end;
end;

procedure put_dummy_gray8(Dst: PByte; N, Incr: Integer);
var
  X: Integer;
begin
  for X := 0 to N - 1 do
  begin
    Dst[0] := $FF;
    Dst := Dst + Incr;
  end;
end;

procedure gray_to_gray8(CS: PColorConvertState; Dst: PByte; y_ptr: PWord;
  N, Incr: Integer);
var
  Q: PByte;
  X, y_val, C, Rnd, Shift: Integer;
begin
  Q := Dst;
  if CS^.bit_depth = 8 then
  begin
    for X := 0 to N - 1 do
    begin
      Q[0] := Byte(y_ptr[X]);
      Q := Q + Incr;
    end;
  end
  else
  begin
    C := CS^.c_one;
    Rnd := CS^.c_rnd;
    Shift := CS^.c_shift;
    for X := 0 to N - 1 do
    begin
      y_val := SAR(y_ptr[X] * C + Rnd, Shift);
      Q[0] := Byte(y_val);
      Q := Q + Incr;
    end;
  end;
end;

// c = c * alpha
procedure alpha_combine8(CS: PColorConvertState; Dst: PByte; a_ptr: PWord;
  N, Incr: Integer);
var
  Q: PByte;
  X, a_val, Shift, Rnd: Integer;
begin
  Q := Dst;
  Shift := CS^.bit_depth;
  Rnd := 1 shl (Shift - 1);
  for X := 0 to N - 1 do
  begin
    a_val := a_ptr[X];
    Q[0] := Byte(SAR(Q[0] * a_val + Rnd, Shift));
    Q[1] := Byte(SAR(Q[1] * a_val + Rnd, Shift));
    Q[2] := Byte(SAR(Q[2] * a_val + Rnd, Shift));
    Q := Q + Incr;
  end;
end;

var
  divide8_table: array[0..255] of Cardinal;

procedure alpha_divide8_init;
var
  I: Integer;
begin
  for I := 1 to 255 do
    // the extra 128 makes the result exact for every input
    divide8_table[I] := ((255 shl DIV8_BITS) + Cardinal(I div 2) + 128) div Cardinal(I);
end;

function comp_divide8(Val, Alpha, alpha_inv: Cardinal): Cardinal; inline;
begin
  if Val >= Alpha then Exit(255);
  Result := (Val * alpha_inv + (1 shl (DIV8_BITS - 1))) shr DIV8_BITS;
end;

// c = c / alpha
procedure alpha_divide8(Dst: PByte; N: Integer);
var
  Q: PByte;
  X: Integer;
  a_val, a_inv: Cardinal;
begin
  Q := Dst;
  for X := 0 to N - 1 do
  begin
    a_val := Q[3];
    if a_val = 0 then
    begin
      Q[0] := 255;
      Q[1] := 255;
      Q[2] := 255;
    end
    else
    begin
      a_inv := divide8_table[a_val];
      Q[0] := Byte(comp_divide8(Q[0], a_val, a_inv));
      Q[1] := Byte(comp_divide8(Q[1], a_val, a_inv));
      Q[2] := Byte(comp_divide8(Q[2], a_val, a_inv));
    end;
    Q := Q + 4;
  end;
end;

procedure gray_one_minus8(Dst: PByte; N, Incr: Integer);
var
  X: Integer;
begin
  for X := 0 to N - 1 do
  begin
    Dst[0] := 255 - Dst[0];
    Dst := Dst + Incr;
  end;
end;

// ---------------- 16 bit output ----------------

procedure ycc_to_rgb48(CS: PColorConvertState; Dst: PByte;
  y_ptr, cb_ptr, cr_ptr: PWord; N, Incr: Integer);
var
  Q: PWord;
  y_val, cb_val, cr_val, X: Integer;
  c_r_cr, c_g_cb, c_g_cr, c_b_cb, Rnd, Shift, Center, c_one: Integer;
begin
  Q := PWord(Dst);
  c_r_cr := CS^.c_r_cr;
  c_g_cb := CS^.c_g_cb;
  c_g_cr := CS^.c_g_cr;
  c_b_cb := CS^.c_b_cb;
  c_one := CS^.y_one;
  Rnd := CS^.y_offset;
  Shift := CS^.c_shift;
  Center := CS^.c_center;
  for X := 0 to N - 1 do
  begin
    y_val := y_ptr[X] * c_one;
    cb_val := cb_ptr[X] - Center;
    cr_val := cr_ptr[X] - Center;
    Q[0] := Word(clamp16(SAR(y_val + c_r_cr * cr_val + Rnd, Shift)));
    Q[1] := Word(clamp16(SAR(y_val - c_g_cb * cb_val - c_g_cr * cr_val + Rnd, Shift)));
    Q[2] := Word(clamp16(SAR(y_val + c_b_cb * cb_val + Rnd, Shift)));
    Q := Q + Incr;
  end;
end;

procedure ycgco_to_rgb48(CS: PColorConvertState; Dst: PByte;
  y_ptr, cb_ptr, cr_ptr: PWord; N, Incr: Integer);
var
  Q: PWord;
  y_val, cb_val, cr_val, X, Rnd, Shift, Center, c_one: Integer;
begin
  Q := PWord(Dst);
  c_one := CS^.y_one;
  Rnd := CS^.y_offset;
  Shift := CS^.c_shift;
  Center := CS^.c_center;
  for X := 0 to N - 1 do
  begin
    y_val := y_ptr[X];
    cb_val := cb_ptr[X] - Center;
    cr_val := cr_ptr[X] - Center;
    Q[0] := Word(clamp16(SAR((y_val - cb_val + cr_val) * c_one + Rnd, Shift)));
    Q[1] := Word(clamp16(SAR((y_val + cb_val) * c_one + Rnd, Shift)));
    Q[2] := Word(clamp16(SAR((y_val - cb_val - cr_val) * c_one + Rnd, Shift)));
    Q := Q + Incr;
  end;
end;

procedure gray_to_rgb48(CS: PColorConvertState; Dst: PByte;
  y_ptr, cb_ptr, cr_ptr: PWord; N, Incr: Integer);
var
  Q: PWord;
  X, y_val, C, Rnd, Shift: Integer;
begin
  Q := PWord(Dst);
  C := CS^.y_one;
  Rnd := CS^.y_offset;
  Shift := CS^.c_shift;
  for X := 0 to N - 1 do
  begin
    y_val := clamp16(SAR(y_ptr[X] * C + Rnd, Shift));
    Q[0] := Word(y_val);
    Q[1] := Word(y_val);
    Q[2] := Word(y_val);
    Q := Q + Incr;
  end;
end;

procedure gray_to_gray16(CS: PColorConvertState; Dst: PWord; y_ptr: PWord;
  N, Incr: Integer);
var
  Q: PWord;
  X, y_val, C, Rnd, Shift: Integer;
begin
  Q := Dst;
  C := CS^.c_one;
  Rnd := CS^.c_rnd;
  Shift := CS^.c_shift;
  for X := 0 to N - 1 do
  begin
    y_val := SAR(y_ptr[X] * C + Rnd, Shift);
    Q[0] := Word(y_val);
    Q := Q + Incr;
  end;
end;

procedure luma_to_gray16(CS: PColorConvertState; Dst: PWord; y_ptr: PWord;
  N, Incr: Integer);
var
  Q: PWord;
  X, y_val, C, Rnd, Shift: Integer;
begin
  Q := Dst;
  C := CS^.y_one;
  Rnd := CS^.y_offset;
  Shift := CS^.c_shift;
  for X := 0 to N - 1 do
  begin
    y_val := clamp16(SAR(y_ptr[X] * C + Rnd, Shift));
    Q[0] := Word(y_val);
    Q := Q + Incr;
  end;
end;

procedure rgb_to_rgb48(CS: PColorConvertState; Dst: PByte;
  y_ptr, cb_ptr, cr_ptr: PWord; N, Incr: Integer);
begin
  luma_to_gray16(CS, PWord(Dst) + 1, y_ptr, N, Incr);
  luma_to_gray16(CS, PWord(Dst) + 2, cb_ptr, N, Incr);
  luma_to_gray16(CS, PWord(Dst) + 0, cr_ptr, N, Incr);
end;

procedure put_dummy_gray16(Dst: PWord; N, Incr: Integer);
var
  X: Integer;
begin
  for X := 0 to N - 1 do
  begin
    Dst[0] := $FFFF;
    Dst := Dst + Incr;
  end;
end;

// c = c * alpha
procedure alpha_combine16(CS: PColorConvertState; Dst: PWord; a_ptr: PWord;
  N, Incr: Integer);
var
  Q: PWord;
  X, a_val, Shift, Rnd: Integer;
begin
  Q := Dst;
  Shift := CS^.bit_depth;
  Rnd := 1 shl (Shift - 1);
  for X := 0 to N - 1 do
  begin
    a_val := a_ptr[X];
    Q[0] := Word(SAR(Q[0] * a_val + Rnd, Shift));
    Q[1] := Word(SAR(Q[1] * a_val + Rnd, Shift));
    Q[2] := Word(SAR(Q[2] * a_val + Rnd, Shift));
    Q := Q + Incr;
  end;
end;

function comp_divide16(Val, Alpha, alpha_inv: Cardinal): Cardinal;
begin
  if Val >= Alpha then Exit(65535);
  Result := (Val * alpha_inv + (1 shl (DIV16_BITS - 1))) shr DIV16_BITS;
end;

// c = c / alpha
procedure alpha_divide16(Dst: PWord; N: Integer);
var
  Q: PWord;
  X: Integer;
  a_val, a_inv: Cardinal;
begin
  Q := Dst;
  for X := 0 to N - 1 do
  begin
    a_val := Q[3];
    if a_val = 0 then
    begin
      Q[0] := 65535;
      Q[1] := 65535;
      Q[2] := 65535;
    end
    else
    begin
      a_inv := (Cardinal(65535) shl DIV16_BITS + (a_val div 2)) div a_val;
      Q[0] := Word(comp_divide16(Q[0], a_val, a_inv));
      Q[1] := Word(comp_divide16(Q[1], a_val, a_inv));
      Q[2] := Word(comp_divide16(Q[2], a_val, a_inv));
    end;
    Q := Q + 4;
  end;
end;

procedure gray_one_minus16(Dst: PWord; N, Incr: Integer);
var
  X: Integer;
begin
  for X := 0 to N - 1 do
  begin
    Dst[0] := 65535 - Dst[0];
    Dst := Dst + Incr;
  end;
end;

const
  cs_to_rgb24: array[0 .. BPG_CS_COUNT - 1] of TColorConvertFunc = (
    ycc_to_rgb24, rgb_to_rgb24, ycgco_to_rgb24, ycc_to_rgb24, ycc_to_rgb24);
  cs_to_rgb48: array[0 .. BPG_CS_COUNT - 1] of TColorConvertFunc = (
    ycc_to_rgb48, rgb_to_rgb48, ycgco_to_rgb48, ycc_to_rgb48, ycc_to_rgb48);

// ---------------- setup ----------------

procedure convert_init(CS: PColorConvertState; in_bit_depth, out_bit_depth,
  color_space, limited_range: Integer);
var
  c_shift, in_pixel_max, out_pixel_max: Integer;
  Mult, k_r, k_b, mult_y, mult_c, Scale: Double;
  is_ycc: Boolean;
begin
  c_shift := 30 - out_bit_depth;
  in_pixel_max := (1 shl in_bit_depth) - 1;
  out_pixel_max := (1 shl out_bit_depth) - 1;
  // evaluated in floating point exactly as in the reference; the products are
  // kept out of 32-bit integer range on purpose
  Scale := out_pixel_max;
  Scale := Scale * (1 shl c_shift);
  Mult := Scale / in_pixel_max;
  if limited_range <> 0 then
  begin
    mult_y := Scale / (219 shl (in_bit_depth - 8));
    mult_c := Scale / (224 shl (in_bit_depth - 8));
  end
  else
  begin
    mult_y := Mult;
    mult_c := Mult;
  end;

  k_r := 0; k_b := 0;
  is_ycc := True;
  case color_space of
    BPG_CS_YCbCr:        begin k_r := 0.299;  k_b := 0.114;  end;
    BPG_CS_YCbCr_BT709:  begin k_r := 0.2126; k_b := 0.0722; end;
    BPG_CS_YCbCr_BT2020: begin k_r := 0.2627; k_b := 0.0593; end;
  else
    is_ycc := False;
  end;
  if is_ycc then
  begin
    // lrint() rounds half to even under the default rounding mode, and so does
    // FPC's Round() for Double -- the coefficients match bit for bit.
    CS^.c_r_cr := Round(2 * (1 - k_r) * mult_c);
    CS^.c_g_cb := Round(2 * k_b * (1 - k_b) / (1 - k_b - k_r) * mult_c);
    CS^.c_g_cr := Round(2 * k_r * (1 - k_r) / (1 - k_b - k_r) * mult_c);
    CS^.c_b_cb := Round(2 * (1 - k_b) * mult_c);
  end;

  CS^.c_one := Round(Mult);
  CS^.c_shift := c_shift;
  CS^.c_rnd := 1 shl (c_shift - 1);
  CS^.c_center := 1 shl (in_bit_depth - 1);
  if limited_range <> 0 then
  begin
    CS^.y_one := Round(mult_y);
    CS^.y_offset := -(16 shl (in_bit_depth - 8)) * CS^.y_one + CS^.c_rnd;
  end
  else
  begin
    CS^.y_one := CS^.c_one;
    CS^.y_offset := CS^.c_rnd;
  end;
  CS^.bit_depth := in_bit_depth;
  CS^.limited_range := limited_range;
end;

function bpg_decoder_output_init(S: PBPGDecoderContext; out_fmt: Integer): Integer;
var
  I, out_bd: Integer;
begin
  if (out_fmt < 0) or (out_fmt > BPG_OUTPUT_FORMAT_CMYK64) then Exit(-1);
  S^.is_rgba := Byte(Ord((out_fmt = BPG_OUTPUT_FORMAT_RGBA32) or
                         (out_fmt = BPG_OUTPUT_FORMAT_RGBA64)));
  S^.is_16bpp := Byte(Ord((out_fmt = BPG_OUTPUT_FORMAT_RGB48) or
                          (out_fmt = BPG_OUTPUT_FORMAT_RGBA64) or
                          (out_fmt = BPG_OUTPUT_FORMAT_CMYK64)));
  S^.is_cmyk := Byte(Ord((out_fmt = BPG_OUTPUT_FORMAT_CMYK32) or
                         (out_fmt = BPG_OUTPUT_FORMAT_CMYK64)));

  if (S^.format = BPG_FORMAT_420) or (S^.format = BPG_FORMAT_422) then
  begin
    S^.w2 := (S^.w + 1) div 2;
    S^.h2 := (S^.h + 1) div 2;
    S^.cb_buf2 := av_malloc(S^.w * SizeOf(Word));
    S^.cr_buf2 := av_malloc(S^.w * SizeOf(Word));
    S^.c_buf4 := av_malloc((S^.w2 + 2 * ITAPS2 - 1) * SizeOf(Int16));
    if S^.format = BPG_FORMAT_420 then
      for I := 0 to ITAPS - 1 do
      begin
        S^.cb_buf3[I] := av_malloc(S^.w2 * SizeOf(Word));
        S^.cr_buf3[I] := av_malloc(S^.w2 * SizeOf(Word));
      end;
  end;

  if S^.is_16bpp <> 0 then out_bd := 16 else out_bd := 8;
  convert_init(@S^.cvt, S^.bit_depth, out_bd, S^.color_space, S^.limited_range);

  if S^.format = BPG_FORMAT_GRAY then
  begin
    if S^.is_16bpp <> 0 then
      S^.cvt_func := gray_to_rgb48
    else
      S^.cvt_func := gray_to_rgb24;
  end
  else
  begin
    if S^.is_16bpp <> 0 then
      S^.cvt_func := cs_to_rgb48[S^.color_space]
    else
      S^.cvt_func := cs_to_rgb24[S^.color_space];
  end;
  Result := 0;
end;

procedure bpg_decoder_output_end(S: PBPGDecoderContext);
var
  I: Integer;
begin
  av_free(S^.cb_buf2); S^.cb_buf2 := nil;
  av_free(S^.cr_buf2); S^.cr_buf2 := nil;
  for I := 0 to ITAPS - 1 do
  begin
    av_free(S^.cb_buf3[I]); S^.cb_buf3[I] := nil;
    av_free(S^.cr_buf3[I]); S^.cr_buf3[I] := nil;
  end;
  av_free(S^.c_buf4); S^.c_buf4 := nil;
end;

function bpg_decoder_start(S: PBPGDecoderContext; out_fmt: Integer): Integer;
var
  Ret, c_idx: Integer;
begin
  if S^.frame = nil then Exit(-1);

  if S^.output_inited = 0 then
  begin
    // the first frame has already been decoded
    Ret := bpg_decoder_output_init(S, out_fmt);
    if Ret <> 0 then Exit(Ret);
    S^.output_inited := 1;
    S^.out_fmt := out_fmt;
  end
  else if (S^.has_animation <> 0) and (S^.decode_animation <> 0) then
  begin
    if out_fmt <> S^.out_fmt then Exit(-1);
    if bpg_decoder_decode_next_frame(S) < 0 then Exit(-1);
  end
  else
    Exit(-1);

  S^.y_buf := bpg_decoder_get_data(S, S^.y_linesize, 0);
  if S^.format <> BPG_FORMAT_GRAY then
  begin
    S^.cb_buf := bpg_decoder_get_data(S, S^.cb_linesize, 1);
    S^.cr_buf := bpg_decoder_get_data(S, S^.cr_linesize, 2);
    c_idx := 3;
  end
  else
    c_idx := 1;
  if S^.has_alpha <> 0 then
    S^.a_buf := bpg_decoder_get_data(S, S^.a_linesize, c_idx)
  else
    S^.a_buf := nil;
  S^.y := 0;
  Result := 0;
end;

function bpg_decoder_get_line(S: PBPGDecoderContext; rgb_line1: Pointer): Integer;
var
  rgb_line: PByte;
  W, Y, Pos_, y2, y1, Incr, y_frac, I: Integer;
  y_ptr, cb_ptr, cr_ptr, a_ptr: PWord;
begin
  rgb_line := PByte(rgb_line1);
  Y := S^.y;
  if (Y < 0) or (Y >= S^.h) then Exit(-1);
  W := S^.w;

  y_ptr := PWord(S^.y_buf + Y * S^.y_linesize);
  Incr := 3 + Ord((S^.is_rgba <> 0) or (S^.is_cmyk <> 0));

  case S^.format of
    BPG_FORMAT_GRAY:
      S^.cvt_func(@S^.cvt, rgb_line, y_ptr, nil, nil, W, Incr);

    BPG_FORMAT_420:
      begin
        if Y = 0 then
        begin
          // prime the vertical interpolation ring buffer
          for I := 0 to ITAPS - 1 do
          begin
            y1 := I;
            if y1 > ITAPS2 then Dec(y1, ITAPS);
            if y1 < 0 then y1 := 0
            else if y1 >= S^.h2 then y1 := S^.h2 - 1;
            cb_ptr := PWord(S^.cb_buf + y1 * S^.cb_linesize);
            cr_ptr := PWord(S^.cr_buf + y1 * S^.cr_linesize);
            Move(cb_ptr^, S^.cb_buf3[I]^, S^.w2 * SizeOf(Word));
            Move(cr_ptr^, S^.cr_buf3[I]^, S^.w2 * SizeOf(Word));
          end;
        end;
        y2 := Y shr 1;
        Pos_ := y2 mod ITAPS;
        y_frac := Y and 1;
        interp2_vh(S^.cb_buf2, @S^.cb_buf3, W, Pos_, S^.c_buf4,
                   S^.bit_depth, y_frac, S^.c_h_phase);
        interp2_vh(S^.cr_buf2, @S^.cr_buf3, W, Pos_, S^.c_buf4,
                   S^.bit_depth, y_frac, S^.c_h_phase);
        if y_frac <> 0 then
        begin
          // push a new line into the ring buffer
          Pos_ := (Pos_ + ITAPS2 + 1) mod ITAPS;
          y1 := y2 + ITAPS2 + 1;
          if y1 >= S^.h2 then y1 := S^.h2 - 1;
          cb_ptr := PWord(S^.cb_buf + y1 * S^.cb_linesize);
          cr_ptr := PWord(S^.cr_buf + y1 * S^.cr_linesize);
          Move(cb_ptr^, S^.cb_buf3[Pos_]^, S^.w2 * SizeOf(Word));
          Move(cr_ptr^, S^.cr_buf3[Pos_]^, S^.w2 * SizeOf(Word));
        end;
        S^.cvt_func(@S^.cvt, rgb_line, y_ptr, S^.cb_buf2, S^.cr_buf2, W, Incr);
      end;

    BPG_FORMAT_422:
      begin
        cb_ptr := PWord(S^.cb_buf + Y * S^.cb_linesize);
        cr_ptr := PWord(S^.cr_buf + Y * S^.cr_linesize);
        interp2_h(S^.cb_buf2, cb_ptr, W, S^.bit_depth, S^.c_h_phase, PWord(S^.c_buf4));
        interp2_h(S^.cr_buf2, cr_ptr, W, S^.bit_depth, S^.c_h_phase, PWord(S^.c_buf4));
        S^.cvt_func(@S^.cvt, rgb_line, y_ptr, S^.cb_buf2, S^.cr_buf2, W, Incr);
      end;

    BPG_FORMAT_444:
      begin
        cb_ptr := PWord(S^.cb_buf + Y * S^.cb_linesize);
        cr_ptr := PWord(S^.cr_buf + Y * S^.cr_linesize);
        S^.cvt_func(@S^.cvt, rgb_line, y_ptr, cb_ptr, cr_ptr, W, Incr);
      end;
  else
    Exit(-1);
  end;

  // alpha output or CMYK handling
  if S^.is_cmyk <> 0 then
  begin
    // RGBW -> CMYK
    if S^.is_16bpp <> 0 then
    begin
      if S^.has_w_plane = 0 then put_dummy_gray16(PWord(rgb_line) + 3, W, 4);
      for I := 0 to 3 do
        gray_one_minus16(PWord(rgb_line) + I, W, 4);
    end
    else
    begin
      if S^.has_w_plane = 0 then put_dummy_gray8(rgb_line + 3, W, 4);
      for I := 0 to 3 do
        gray_one_minus8(rgb_line + I, W, 4);
    end;
  end
  else if S^.has_w_plane <> 0 then
  begin
    a_ptr := PWord(S^.a_buf + Y * S^.a_linesize);
    if S^.is_16bpp <> 0 then
    begin
      alpha_combine16(@S^.cvt, PWord(rgb_line), a_ptr, W, Incr);
      if S^.is_rgba <> 0 then put_dummy_gray16(PWord(rgb_line) + 3, W, 4);
    end
    else
    begin
      alpha_combine8(@S^.cvt, rgb_line, a_ptr, W, Incr);
      if S^.is_rgba <> 0 then put_dummy_gray8(rgb_line + 3, W, 4);
    end;
  end
  else if S^.is_rgba <> 0 then
  begin
    if S^.is_16bpp <> 0 then
    begin
      if S^.has_alpha <> 0 then
      begin
        a_ptr := PWord(S^.a_buf + Y * S^.a_linesize);
        gray_to_gray16(@S^.cvt, PWord(rgb_line) + 3, a_ptr, W, 4);
        if S^.premultiplied_alpha <> 0 then alpha_divide16(PWord(rgb_line), W);
      end
      else
        put_dummy_gray16(PWord(rgb_line) + 3, W, 4);
    end
    else
    begin
      if S^.has_alpha <> 0 then
      begin
        a_ptr := PWord(S^.a_buf + Y * S^.a_linesize);
        gray_to_gray8(@S^.cvt, rgb_line + 3, a_ptr, W, 4);
        if S^.premultiplied_alpha <> 0 then alpha_divide8(rgb_line, W);
      end
      else
        put_dummy_gray8(rgb_line + 3, W, 4);
    end;
  end;

  Inc(S^.y);
  Result := 0;
end;

initialization
  alpha_divide8_init;

end.
