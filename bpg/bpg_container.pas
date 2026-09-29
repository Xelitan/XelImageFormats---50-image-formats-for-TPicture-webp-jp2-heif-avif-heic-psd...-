// BPG decoder -- Free Pascal port of libbpg 0.9.8
// Container layer: BPG file header, extension chunks, reconstruction of the
// HEVC bitstream from the "modified SPS", and the split of the interleaved
// colour / alpha NAL streams into two decoders.
// Corresponds to: the first half of libbpg.c (up to bpg_decoder_get_info) and
//                 bpg_decode_header / bpg_decoder_decode near its end.
//
// The reference talks to libavcodec through AVCodecContext; here the two HEVC
// decoders are plain THEVCContext records driven by bpg_hevc directly.
//
// Colour conversion and line output live in bpg_output.
unit bpg_container;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  bpg_common, bpg_hevc_defs, bpg_frame, bpg_hevc;

const
  BPG_HEADER_MAGIC = $425047FB;
  MAX_DATA_SIZE    = (1 shl 30) - 1;

  // BPGImageFormatEnum
  BPG_FORMAT_GRAY       = 0;
  BPG_FORMAT_420        = 1;  // chroma at offset (0.5, 0.5) (JPEG)
  BPG_FORMAT_422        = 2;  // chroma at offset (0.5, 0)   (JPEG)
  BPG_FORMAT_444        = 3;
  BPG_FORMAT_420_VIDEO  = 4;  // chroma at offset (0, 0.5)   (MPEG2)
  BPG_FORMAT_422_VIDEO  = 5;  // chroma at offset (0, 0)     (MPEG2)

  // BPGColorSpaceEnum
  BPG_CS_YCbCr          = 0;
  BPG_CS_RGB            = 1;
  BPG_CS_YCgCo          = 2;
  BPG_CS_YCbCr_BT709    = 3;
  BPG_CS_YCbCr_BT2020   = 4;
  BPG_CS_COUNT          = 5;

  // BPGExtensionTagEnum
  BPG_EXTENSION_TAG_EXIF         = 1;
  BPG_EXTENSION_TAG_ICCP         = 2;
  BPG_EXTENSION_TAG_XMP          = 3;
  BPG_EXTENSION_TAG_THUMBNAIL    = 4;
  BPG_EXTENSION_TAG_ANIM_CONTROL = 5;

  // BPGDecoderOutputFormat
  BPG_OUTPUT_FORMAT_RGB24  = 0;
  BPG_OUTPUT_FORMAT_RGBA32 = 1;
  BPG_OUTPUT_FORMAT_RGB48  = 2;
  BPG_OUTPUT_FORMAT_RGBA64 = 3;
  BPG_OUTPUT_FORMAT_CMYK32 = 4;
  BPG_OUTPUT_FORMAT_CMYK64 = 5;

  ITAPS2 = 4;
  ITAPS  = 2 * ITAPS2;

type
  PBPGExtensionData = ^TBPGExtensionData;
  TBPGExtensionData = record
    tag: Cardinal;
    buf_len: Cardinal;
    buf: PByte;
    next: PBPGExtensionData;
  end;

  TBPGImageInfo = record
    width: Cardinal;
    height: Cardinal;
    format: Byte;
    has_alpha: Byte;
    color_space: Byte;
    bit_depth: Byte;
    premultiplied_alpha: Byte;
    has_w_plane: Byte;
    limited_range: Byte;
    has_animation: Byte;
    loop_count: Word;
  end;
  PBPGImageInfo = ^TBPGImageInfo;

  TColorConvertState = record
    c_shift: Integer;
    c_rnd: Integer;
    c_one: Integer;
    y_one, y_offset: Integer;
    c_r_cr, c_g_cb, c_g_cr, c_b_cb: Integer;
    c_center: Integer;
    bit_depth: Integer;
    limited_range: Integer;
  end;
  PColorConvertState = ^TColorConvertState;

  PBPGDecoderContext = ^TBPGDecoderContext;

  // Signature of the per-line colour converters in bpg_output; kept here so the
  // context record can hold one.
  TColorConvertFunc = procedure(CS: PColorConvertState; Dst: PByte;
    y_ptr, cb_ptr, cr_ptr: PWord; N, Incr: Integer);

  TBPGDecoderContext = record
    dec_ctx: PHEVCContext;
    alpha_dec_ctx: PHEVCContext;
    frame: PAVFrame;
    alpha_frame: PAVFrame;
    w, h: Integer;
    format: Integer;
    c_h_phase: Byte;          // only used for 422 and 420
    has_alpha: Byte;
    bit_depth: Byte;
    has_w_plane: Byte;
    limited_range: Byte;
    premultiplied_alpha: Byte;
    has_animation: Byte;
    color_space: Integer;
    keep_extension_data: Byte;
    decode_animation: Byte;
    first_md: PBPGExtensionData;

    // animation
    loop_count: Word;
    frame_delay_num: Word;
    frame_delay_den: Word;
    input_buf: PByte;
    input_buf_pos: Integer;
    input_buf_len: Integer;

    // format conversion (driven by bpg_output)
    output_inited: Byte;
    out_fmt: Integer;
    is_rgba: Byte;
    is_16bpp: Byte;
    is_cmyk: Byte;
    y: Integer;               // current line
    w2, h2: Integer;
    y_buf, cb_buf, cr_buf, a_buf: PByte;
    y_linesize, cb_linesize, cr_linesize, a_linesize: Integer;
    cb_buf2, cr_buf2: PWord;
    cb_buf3, cr_buf3: array[0 .. ITAPS - 1] of PWord;
    c_buf4: PInt16;
    cvt: TColorConvertState;
    cvt_func: TColorConvertFunc;
  end;

  TBPGHeaderData = record
    width, height: Cardinal;
    format: Integer;
    has_alpha: Byte;
    bit_depth: Byte;
    has_w_plane: Byte;
    premultiplied_alpha: Byte;
    limited_range: Byte;
    has_animation: Byte;
    loop_count: Word;
    frame_delay_num: Word;
    frame_delay_den: Word;
    color_space: Integer;
    hevc_data_len: Cardinal;
    first_md: PBPGExtensionData;
  end;
  PBPGHeaderData = ^TBPGHeaderData;

function bpg_decoder_open: PBPGDecoderContext;
function bpg_decoder_decode(Img: PBPGDecoderContext; Buf: PByte; buf_len: Integer): Integer;
procedure bpg_decoder_close(S: PBPGDecoderContext);
function bpg_decoder_get_data(Img: PBPGDecoderContext; out line_size: Integer;
  Plane: Integer): PByte;
function bpg_decoder_get_info(Img: PBPGDecoderContext; P: PBPGImageInfo): Integer;
procedure bpg_decoder_free_extension_data(first_md: PBPGExtensionData);
procedure bpg_decoder_keep_extension_data(S: PBPGDecoderContext; Enable: Integer);
function bpg_decoder_get_extension_data(S: PBPGDecoderContext): PBPGExtensionData;
procedure bpg_decoder_get_frame_duration(S: PBPGDecoderContext; out Num, Den: Integer);
function bpg_decoder_get_frame_count(S: PBPGDecoderContext): Integer;

// animation: decode the next frame; 0 on success, < 0 when the stream ends
function bpg_decoder_decode_next_frame(S: PBPGDecoderContext): Integer;

function bpg_decode_header(H: PBPGHeaderData; Buf: PByte; buf_len: Integer;
  header_only, load_extensions: Integer): Integer;

implementation

// ---------------- variable-length unsigned integers ----------------

// returns < 0 on error, otherwise the number of bytes consumed
function get_ue32(out V: Cardinal; Buf: PByte; Len: Integer): Integer;
var
  P: PByte;
  Acc: Cardinal;
  A: Integer;
begin
  V := 0;
  if Len <= 0 then Exit(-1);
  P := Buf;
  A := P^; Inc(P); Dec(Len);
  if A < $80 then
  begin
    V := Cardinal(A);
    Exit(1);
  end
  else if A = $80 then
    // non-canonical encodings are rejected
    Exit(-1);
  Acc := Cardinal(A and $7F);
  while True do
  begin
    if Len <= 0 then Exit(-1);
    A := P^; Inc(P); Dec(Len);
    Acc := (Acc shl 7) or Cardinal(A and $7F);
    if (A and $80) = 0 then Break;
  end;
  V := Acc;
  Result := P - Buf;
end;

function get_ue(out V: Cardinal; Buf: PByte; Len: Integer): Integer;
begin
  Result := get_ue32(V, Buf, Len);
  if Result < 0 then Exit;
  // bound the value so later buffer arithmetic cannot overflow
  if V > MAX_DATA_SIZE then Result := -1;
end;

// ---------------- modified SPS -> real HEVC NAL ----------------

function build_msps(out PBuf: PByte; out pbuf_len: Integer;
  input_data: PByte; input_data_len1: Integer;
  Width, Height, chroma_format_idc, bit_depth: Integer): Integer;
var
  input_data_len, Idx, msps_len, Ret, buf_len, I: Integer;
  Len: Cardinal;
  Buf, msps_buf: PByte;
begin
  input_data_len := input_data_len1;
  PBuf := nil;
  pbuf_len := 0;

  Ret := get_ue(Len, input_data, input_data_len);
  if Ret < 0 then Exit(-1);
  Inc(input_data, Ret);
  Dec(input_data_len, Ret);
  if Integer(Len) > input_data_len then Exit(-1);

  msps_len := 1 + 4 + 4 + 1 + Integer(Len);
  msps_buf := av_malloc(msps_len);
  if msps_buf = nil then Exit(-1);
  Idx := 0;
  msps_buf[Idx] := Byte(chroma_format_idc); Inc(Idx);
  msps_buf[Idx] := Byte(Width shr 24); Inc(Idx);
  msps_buf[Idx] := Byte(Width shr 16); Inc(Idx);
  msps_buf[Idx] := Byte(Width shr 8); Inc(Idx);
  msps_buf[Idx] := Byte(Width); Inc(Idx);
  msps_buf[Idx] := Byte(Height shr 24); Inc(Idx);
  msps_buf[Idx] := Byte(Height shr 16); Inc(Idx);
  msps_buf[Idx] := Byte(Height shr 8); Inc(Idx);
  msps_buf[Idx] := Byte(Height); Inc(Idx);
  msps_buf[Idx] := Byte(bit_depth - 8); Inc(Idx);
  Move(input_data^, msps_buf[Idx], Len);
  Inc(Idx, Len);
  Inc(input_data, Len);
  Dec(input_data_len, Len);

  buf_len := 4 + 2 + msps_len * 2;
  Buf := av_malloc(buf_len);
  if Buf = nil then
  begin
    av_free(msps_buf);
    Exit(-1);
  end;

  Idx := 0;
  // start code + NAL header
  Buf[Idx] := $00; Inc(Idx);
  Buf[Idx] := $00; Inc(Idx);
  Buf[Idx] := $00; Inc(Idx);
  Buf[Idx] := $01; Inc(Idx);
  Buf[Idx] := 48 shl 1; Inc(Idx);   // application-specific NAL unit type
  Buf[Idx] := 1; Inc(Idx);

  // re-insert the emulation prevention bytes
  I := 0;
  while I < msps_len do
  begin
    if ((I + 1) < msps_len) and (msps_buf[I] = 0) and (msps_buf[I + 1] = 0) then
    begin
      Buf[Idx] := $00; Inc(Idx);
      Buf[Idx] := $00; Inc(Idx);
      Buf[Idx] := $03; Inc(Idx);
      Inc(I, 2);
    end
    else
    begin
      Buf[Idx] := msps_buf[I]; Inc(Idx); Inc(I);
    end;
  end;
  // the last byte must not be zero
  if (Idx = 0) or (Buf[Idx - 1] = $00) then
  begin
    Buf[Idx] := $80;
    Inc(Idx);
  end;
  av_free(msps_buf);

  pbuf_len := Idx;
  PBuf := Buf;
  Result := input_data_len1 - input_data_len;
end;

// position of the end of the NAL, or -1 on error
function find_nal_end(Buf: PByte; buf_len, has_startcode: Integer): Integer;
var
  Idx: Integer;
begin
  Idx := 0;
  if has_startcode <> 0 then
  begin
    if (buf_len >= 4) and (Buf[0] = 0) and (Buf[1] = 0) and (Buf[2] = 0) and (Buf[3] = 1) then
      Idx := 4
    else if (buf_len >= 3) and (Buf[0] = 0) and (Buf[1] = 0) and (Buf[2] = 1) then
      Idx := 3
    else
      Exit(-1);
  end;
  if Idx + 2 > buf_len then Exit(-1);
  while True do
  begin
    if Idx + 2 >= buf_len then
    begin
      Idx := buf_len;
      Break;
    end;
    if (Buf[Idx] = 0) and (Buf[Idx + 1] = 0) and (Buf[Idx + 2] = 1) then Break;
    if (Idx + 3 < buf_len) and (Buf[Idx] = 0) and (Buf[Idx + 1] = 0) and
       (Buf[Idx + 2] = 0) and (Buf[Idx + 3] = 1) then Break;
    Inc(Idx);
  end;
  Result := Idx;
end;

// ---------------- growable byte buffer ----------------

type
  TDynBuf = record
    buf: PByte;
    size: Integer;
    len: Integer;
  end;
  PDynBuf = ^TDynBuf;

procedure dyn_buf_init(S: PDynBuf);
begin
  S^.buf := nil;
  S^.size := 0;
  S^.len := 0;
end;

function dyn_buf_resize(S: PDynBuf; Size: Integer): Integer;
var
  new_size: Integer;
  new_buf: PByte;
begin
  if Size <= S^.size then Exit(0);
  new_size := (S^.size * 3) div 2;
  if new_size < Size then new_size := Size;
  new_buf := av_realloc(S^.buf, new_size);
  if new_buf = nil then Exit(-1);
  S^.buf := new_buf;
  S^.size := new_size;
  Result := 0;
end;

function dyn_buf_push(S: PDynBuf; Data: PByte; Len: Integer): Integer;
begin
  if dyn_buf_resize(S, S^.len + Len) < 0 then Exit(-1);
  Move(Data^, S^.buf[S^.len], Len);
  Inc(S^.len, Len);
  Result := 0;
end;

// ---------------- HEVC decoder plumbing ----------------

function hevc_decode_init1(PBuf: PDynBuf; out Frame: PAVFrame;
  out Ctx: PHEVCContext; Buf: PByte; buf_len: Integer;
  Width, Height, chroma_format_idc, bit_depth: Integer): Integer;
var
  nal_buf: PByte;
  nal_len, Ret, ret1: Integer;
  C: PHEVCContext;
begin
  Frame := nil;
  Ctx := nil;
  Ret := build_msps(nal_buf, nal_len, Buf, buf_len,
                    Width, Height, chroma_format_idc, bit_depth);
  if Ret < 0 then Exit(-1);
  ret1 := dyn_buf_push(PBuf, nal_buf, nal_len);
  av_free(nal_buf);
  if ret1 < 0 then Exit(-1);

  C := av_mallocz(SizeOf(THEVCContext));
  if C = nil then Exit(-1);
  if hevc_init_context(C) < 0 then
  begin
    av_free(C);
    Exit(-1);
  end;
  Frame := av_frame_alloc;
  if Frame = nil then
  begin
    hevc_decode_free(C);
    av_free(C);
    Exit(-1);
  end;
  Ctx := C;
  Result := Ret;
end;

function hevc_write_frame(Ctx: PHEVCContext; Frame: PAVFrame;
  Buf: PByte; buf_len: Integer): Integer;
var
  Len, got_frame: Integer;
begin
  // keep the decoder from reading uninitialised trailing bytes
  FillChar(Buf[buf_len], FF_INPUT_BUFFER_PADDING_SIZE, 0);
  Len := hevc_decode_frame(Ctx, Frame, got_frame, Buf, buf_len);
  if (Len < 0) or (got_frame = 0) then Result := -1 else Result := 0;
end;

function hevc_decode_frame_internal(S: PBPGDecoderContext;
  abuf, cbuf: PDynBuf; Buf: PByte; buf_len1, first_nal: Integer): Integer;
var
  nal_len, start, nal_buf_len, Ret, nuh_layer_id, buf_len, has_alpha: Integer;
  nut: Integer;
  frame_start_found: array[0..1] of Integer;
  pbuf: PDynBuf;
  nal_buf: PByte;
label
  fail;
begin
  has_alpha := Ord(S^.alpha_dec_ctx <> nil);
  buf_len := buf_len1;
  frame_start_found[0] := 0;
  frame_start_found[1] := 0;

  while buf_len > 0 do
  begin
    if first_nal <> 0 then
    begin
      if buf_len < 3 + 2 then goto fail;
      start := 0;
    end
    else
    begin
      if buf_len < 2 then goto fail;
      start := 3 + Ord(Buf[2] = 0);
    end;
    if buf_len < start + 3 then goto fail;

    nuh_layer_id := ((Buf[start] and 1) shl 5) or (Buf[start + 1] shr 3);
    nut := (Buf[start] shr 1) and $3F;

    // the alpha and colour NALs are assumed to be correctly interleaved
    if ((nut >= 32) and (nut <= 35)) or (nut = 39) or (nut >= 41) then
    begin
      if (frame_start_found[0] <> 0) and (frame_start_found[has_alpha] <> 0) then Break;
    end
    else if ((nut <= 9) or ((nut >= 16) and (nut <= 21))) and
            (start + 2 < buf_len) and ((Buf[start + 2] and $80) <> 0) then
    begin
      // first slice segment
      if (frame_start_found[0] <> 0) and (frame_start_found[has_alpha] <> 0) then Break;
      if (has_alpha <> 0) and (nuh_layer_id = 1) then
        frame_start_found[1] := 1
      else
        frame_start_found[0] := 1;
    end;

    nal_len := find_nal_end(Buf, buf_len, Ord(first_nal = 0));
    if nal_len < 0 then goto fail;
    nal_buf_len := nal_len - start + 3;
    if (has_alpha <> 0) and (nuh_layer_id = 1) then pbuf := abuf else pbuf := cbuf;
    if dyn_buf_resize(pbuf, pbuf^.len + nal_buf_len) < 0 then goto fail;
    nal_buf := pbuf^.buf + pbuf^.len;
    nal_buf[0] := $00;
    nal_buf[1] := $00;
    nal_buf[2] := $01;
    Move(Buf[start], nal_buf[3], nal_len - start);
    // rewrite nuh_layer_id 1 -> 0 so the alpha decoder sees a base layer
    if (has_alpha <> 0) and (nuh_layer_id = 1) then
      nal_buf[4] := nal_buf[4] and $7;
    Inc(pbuf^.len, nal_buf_len);
    Inc(Buf, nal_len);
    Dec(buf_len, nal_len);
    first_nal := 0;
  end;

  if S^.alpha_dec_ctx <> nil then
  begin
    if dyn_buf_resize(abuf, abuf^.len + FF_INPUT_BUFFER_PADDING_SIZE) < 0 then goto fail;
    if hevc_write_frame(S^.alpha_dec_ctx, S^.alpha_frame, abuf^.buf, abuf^.len) < 0 then
      goto fail;
  end;

  if dyn_buf_resize(cbuf, cbuf^.len + FF_INPUT_BUFFER_PADDING_SIZE) < 0 then goto fail;
  if hevc_write_frame(S^.dec_ctx, S^.frame, cbuf^.buf, cbuf^.len) < 0 then goto fail;

  Exit(buf_len1 - buf_len);
fail:
  Result := -1;
end;

// decode the first frame
function hevc_decode_start(S: PBPGDecoderContext; Buf: PByte; buf_len1: Integer;
  Width, Height, chroma_format_idc, bit_depth, has_alpha: Integer): Integer;
var
  Ret, buf_len: Integer;
  abuf_s, cbuf_s: TDynBuf;
  abuf, cbuf: PDynBuf;
begin
  abuf := @abuf_s;
  cbuf := @cbuf_s;
  dyn_buf_init(abuf);
  dyn_buf_init(cbuf);
  buf_len := buf_len1;

  if has_alpha <> 0 then
  begin
    Ret := hevc_decode_init1(abuf, S^.alpha_frame, S^.alpha_dec_ctx,
                             Buf, buf_len, Width, Height, 0, bit_depth);
    if Ret < 0 then
    begin
      av_free(abuf^.buf);
      av_free(cbuf^.buf);
      Exit(-1);
    end;
    Inc(Buf, Ret);
    Dec(buf_len, Ret);
  end;

  Ret := hevc_decode_init1(cbuf, S^.frame, S^.dec_ctx,
                           Buf, buf_len, Width, Height, chroma_format_idc, bit_depth);
  if Ret < 0 then
  begin
    av_free(abuf^.buf);
    av_free(cbuf^.buf);
    Exit(-1);
  end;
  Inc(Buf, Ret);
  Dec(buf_len, Ret);

  Ret := hevc_decode_frame_internal(S, abuf, cbuf, Buf, buf_len, 1);
  av_free(abuf^.buf);
  av_free(cbuf^.buf);
  if Ret < 0 then Exit(-1);
  Dec(buf_len, Ret);
  Result := buf_len1 - buf_len;
end;

// USE_PRED: decode a subsequent animation frame
function hevc_decode_next(S: PBPGDecoderContext; Buf: PByte; buf_len: Integer): Integer;
var
  abuf_s, cbuf_s: TDynBuf;
  abuf, cbuf: PDynBuf;
begin
  abuf := @abuf_s;
  cbuf := @cbuf_s;
  dyn_buf_init(abuf);
  dyn_buf_init(cbuf);
  Result := hevc_decode_frame_internal(S, abuf, cbuf, Buf, buf_len, 0);
  av_free(abuf^.buf);
  av_free(cbuf^.buf);
end;

procedure hevc_decode_end(S: PBPGDecoderContext);
begin
  if S^.alpha_dec_ctx <> nil then
  begin
    hevc_decode_free(S^.alpha_dec_ctx);
    av_free(S^.alpha_dec_ctx);
    S^.alpha_dec_ctx := nil;
  end;
  if S^.dec_ctx <> nil then
  begin
    hevc_decode_free(S^.dec_ctx);
    av_free(S^.dec_ctx);
    S^.dec_ctx := nil;
  end;
end;

// ---------------- public accessors ----------------

function bpg_decoder_get_data(Img: PBPGDecoderContext; out line_size: Integer;
  Plane: Integer): PByte;
var
  c_count: Integer;
begin
  if Img^.format = BPG_FORMAT_GRAY then c_count := 1 else c_count := 3;
  if Plane < c_count then
  begin
    line_size := Img^.frame^.Linesize[Plane];
    Result := Img^.frame^.Data[Plane];
  end
  else if (Img^.has_alpha <> 0) and (Plane = c_count) then
  begin
    line_size := Img^.alpha_frame^.Linesize[0];
    Result := Img^.alpha_frame^.Data[0];
  end
  else
  begin
    line_size := 0;
    Result := nil;
  end;
end;

function bpg_decoder_get_info(Img: PBPGDecoderContext; P: PBPGImageInfo): Integer;
begin
  if Img^.frame = nil then Exit(-1);
  P^.width := Cardinal(Img^.w);
  P^.height := Cardinal(Img^.h);
  P^.format := Byte(Img^.format);
  P^.has_alpha := Byte(Ord((Img^.has_alpha <> 0) and (Img^.has_w_plane = 0)));
  P^.premultiplied_alpha := Img^.premultiplied_alpha;
  P^.has_w_plane := Img^.has_w_plane;
  P^.limited_range := Img^.limited_range;
  P^.color_space := Byte(Img^.color_space);
  P^.bit_depth := Img^.bit_depth;
  P^.has_animation := Img^.has_animation;
  P^.loop_count := Img^.loop_count;
  Result := 0;
end;

procedure bpg_decoder_free_extension_data(first_md: PBPGExtensionData);
var
  md, md_next: PBPGExtensionData;
begin
  md := first_md;
  while md <> nil do
  begin
    md_next := md^.next;
    av_free(md^.buf);
    av_free(md);
    md := md_next;
  end;
end;

procedure bpg_decoder_keep_extension_data(S: PBPGDecoderContext; Enable: Integer);
begin
  S^.keep_extension_data := Byte(Enable);
end;

function bpg_decoder_get_extension_data(S: PBPGDecoderContext): PBPGExtensionData;
begin
  Result := S^.first_md;
end;

procedure bpg_decoder_get_frame_duration(S: PBPGDecoderContext; out Num, Den: Integer);
begin
  // the per-frame duration arrives via the BPG SEI (payload type 257), carried
  // in frame->pts, in units of frame_delay_num / frame_delay_den
  if (S^.frame <> nil) and (S^.has_animation <> 0) then
  begin
    Num := Integer(S^.frame_delay_num) * Integer(S^.frame^.Pts);
    Den := Integer(S^.frame_delay_den);
  end
  else
  begin
    Num := 0;
    Den := 1;
  end;
end;

function bpg_decoder_get_frame_count(S: PBPGDecoderContext): Integer;
begin
  Result := Ord(S^.has_animation <> 0);
end;

// ---------------- header ----------------

function bpg_decode_header(H: PBPGHeaderData; Buf: PByte; buf_len: Integer;
  header_only, load_extensions: Integer): Integer;
var
  Idx, flags1, flags2, has_extension, Ret, alpha1_flag, alpha2_flag: Integer;
  extension_data_len, Tag, ext_buf_len: Cardinal;
  ext_end, idx1: Integer;
  md: PBPGExtensionData;
  plast_md: ^PBPGExtensionData;
  loop_count, frame_delay_num, frame_delay_den: Cardinal;
label
  fail;
begin
  if buf_len < 6 then Exit(-1);
  if (Buf[0] <> ((BPG_HEADER_MAGIC shr 24) and $FF)) or
     (Buf[1] <> ((BPG_HEADER_MAGIC shr 16) and $FF)) or
     (Buf[2] <> ((BPG_HEADER_MAGIC shr 8) and $FF)) or
     (Buf[3] <> (BPG_HEADER_MAGIC and $FF)) then Exit(-1);

  Idx := 4;
  flags1 := Buf[Idx]; Inc(Idx);
  H^.format := flags1 shr 5;
  if H^.format > 5 then Exit(-1);
  alpha1_flag := (flags1 shr 4) and 1;
  H^.bit_depth := Byte((flags1 and $F) + 8);
  if H^.bit_depth > 14 then Exit(-1);

  flags2 := Buf[Idx]; Inc(Idx);
  H^.color_space := (flags2 shr 4) and $F;
  has_extension := (flags2 shr 3) and 1;
  alpha2_flag := (flags2 shr 2) and 1;
  H^.limited_range := Byte((flags2 shr 1) and 1);
  H^.has_animation := Byte(flags2 and 1);
  H^.loop_count := 0;
  H^.frame_delay_num := 0;
  H^.frame_delay_den := 0;
  H^.has_alpha := 0;
  H^.has_w_plane := 0;
  H^.premultiplied_alpha := 0;
  H^.first_md := nil;

  if alpha1_flag <> 0 then
  begin
    H^.has_alpha := 1;
    H^.premultiplied_alpha := Byte(alpha2_flag);
  end
  else if alpha2_flag <> 0 then
  begin
    H^.has_alpha := 1;
    H^.has_w_plane := 1;
  end;

  if (H^.color_space >= BPG_CS_COUNT) or
     ((H^.format = BPG_FORMAT_GRAY) and (H^.color_space <> 0)) or
     ((H^.has_w_plane <> 0) and (H^.format = BPG_FORMAT_GRAY)) then Exit(-1);

  Ret := get_ue(H^.width, Buf + Idx, buf_len - Idx);
  if Ret < 0 then Exit(-1);
  Inc(Idx, Ret);
  Ret := get_ue(H^.height, Buf + Idx, buf_len - Idx);
  if Ret < 0 then Exit(-1);
  Inc(Idx, Ret);
  if (H^.width = 0) or (H^.height = 0) then Exit(-1);
  if header_only <> 0 then Exit(Idx);

  Ret := get_ue(H^.hevc_data_len, Buf + Idx, buf_len - Idx);
  if Ret < 0 then Exit(-1);
  Inc(Idx, Ret);

  extension_data_len := 0;
  if has_extension <> 0 then
  begin
    Ret := get_ue(extension_data_len, Buf + Idx, buf_len - Idx);
    if Ret < 0 then Exit(-1);
    Inc(Idx, Ret);
  end;

  if has_extension <> 0 then
  begin
    ext_end := Idx + Integer(extension_data_len);
    if ext_end > buf_len then Exit(-1);
    if (load_extensions <> 0) or (H^.has_animation <> 0) then
    begin
      plast_md := @H^.first_md;
      while Idx < ext_end do
      begin
        Ret := get_ue32(Tag, Buf + Idx, ext_end - Idx);
        if Ret < 0 then goto fail;
        Inc(Idx, Ret);
        Ret := get_ue(ext_buf_len, Buf + Idx, ext_end - Idx);
        if Ret < 0 then goto fail;
        Inc(Idx, Ret);
        if Idx + Integer(ext_buf_len) > ext_end then goto fail;

        if (H^.has_animation <> 0) and (Tag = BPG_EXTENSION_TAG_ANIM_CONTROL) then
        begin
          idx1 := Idx;
          Ret := get_ue(loop_count, Buf + idx1, ext_end - idx1);
          if Ret < 0 then goto fail;
          Inc(idx1, Ret);
          Ret := get_ue(frame_delay_num, Buf + idx1, ext_end - idx1);
          if Ret < 0 then goto fail;
          Inc(idx1, Ret);
          Ret := get_ue(frame_delay_den, Buf + idx1, ext_end - idx1);
          if Ret < 0 then goto fail;
          Inc(idx1, Ret);
          if (frame_delay_num = 0) or (frame_delay_den = 0) or
             (Word(frame_delay_num) <> frame_delay_num) or
             (Word(frame_delay_den) <> frame_delay_den) or
             (Word(loop_count) <> loop_count) then goto fail;
          H^.loop_count := Word(loop_count);
          H^.frame_delay_num := Word(frame_delay_num);
          H^.frame_delay_den := Word(frame_delay_den);
        end;

        if load_extensions <> 0 then
        begin
          md := av_malloc(SizeOf(TBPGExtensionData));
          if md = nil then goto fail;
          md^.tag := Tag;
          md^.buf_len := ext_buf_len;
          md^.next := nil;
          plast_md^ := md;
          plast_md := @md^.next;
          md^.buf := av_malloc(md^.buf_len);
          if md^.buf = nil then goto fail;
          Move(Buf[Idx], md^.buf^, md^.buf_len);
        end;
        Inc(Idx, Integer(ext_buf_len));
      end;
    end
    else
      // skip the extension data
      Inc(Idx, Integer(extension_data_len));
  end;

  // animations must carry the animation control extension
  if (H^.has_animation <> 0) and (H^.frame_delay_num = 0) then goto fail;

  if H^.hevc_data_len = 0 then
    H^.hevc_data_len := Cardinal(buf_len - Idx);

  Exit(Idx);
fail:
  bpg_decoder_free_extension_data(H^.first_md);
  H^.first_md := nil;
  Result := -1;
end;

// ---------------- decode ----------------

function bpg_decoder_open: PBPGDecoderContext;
begin
  Result := av_mallocz(SizeOf(TBPGDecoderContext));
end;

function bpg_decoder_decode(Img: PBPGDecoderContext; Buf: PByte; buf_len: Integer): Integer;
var
  Idx, has_alpha, bit_depth, color_space, Ret, Len: Integer;
  Width, Height: Cardinal;
  H: TBPGHeaderData;
label
  fail;
begin
  Idx := bpg_decode_header(@H, Buf, buf_len, 0, Img^.keep_extension_data);
  if Idx < 0 then Exit(Idx);

  Width := H.width;
  Height := H.height;
  has_alpha := H.has_alpha;
  color_space := H.color_space;
  bit_depth := H.bit_depth;

  Img^.w := Integer(Width);
  Img^.h := Integer(Height);
  if H.format = BPG_FORMAT_422_VIDEO then
  begin
    Img^.format := BPG_FORMAT_422;
    Img^.c_h_phase := 0;
  end
  else if H.format = BPG_FORMAT_420_VIDEO then
  begin
    Img^.format := BPG_FORMAT_420;
    Img^.c_h_phase := 0;
  end
  else
  begin
    Img^.format := H.format;
    Img^.c_h_phase := 1;
  end;
  Img^.has_alpha := Byte(has_alpha);
  Img^.premultiplied_alpha := H.premultiplied_alpha;
  Img^.has_w_plane := H.has_w_plane;
  Img^.limited_range := H.limited_range;
  Img^.color_space := color_space;
  Img^.bit_depth := Byte(bit_depth);
  Img^.has_animation := H.has_animation;
  Img^.loop_count := H.loop_count;
  Img^.frame_delay_num := H.frame_delay_num;
  Img^.frame_delay_den := H.frame_delay_den;
  Img^.first_md := H.first_md;

  if Idx + Integer(H.hevc_data_len) > buf_len then goto fail;

  Ret := hevc_decode_start(Img, Buf + Idx, buf_len - Idx,
                           Integer(Width), Integer(Height), Img^.format,
                           bit_depth, has_alpha);
  if Ret < 0 then goto fail;
  Inc(Idx, Ret);

  Img^.decode_animation := 1;
  if (Img^.has_animation <> 0) and (Img^.decode_animation <> 0) then
  begin
    // keep the trailing bitstream so the following frames can be decoded
    Len := buf_len - Idx;
    Img^.input_buf := av_malloc(Len);
    if Img^.input_buf = nil then goto fail;
    Move(Buf[Idx], Img^.input_buf^, Len);
    Img^.input_buf_len := Len;
    Img^.input_buf_pos := 0;
  end
  else
    hevc_decode_end(Img);

  if (Img^.frame^.Width < Img^.w) or (Img^.frame^.Height < Img^.h) then goto fail;
  Img^.y := -1;
  Exit(0);

fail:
  av_frame_free(Img^.frame);
  av_frame_free(Img^.alpha_frame);
  bpg_decoder_free_extension_data(Img^.first_md);
  Img^.first_md := nil;
  Result := -1;
end;

function bpg_decoder_decode_next_frame(S: PBPGDecoderContext): Integer;
var
  Ret: Integer;
begin
  if (S^.input_buf = nil) or (S^.input_buf_pos >= S^.input_buf_len) then Exit(-1);
  Ret := hevc_decode_next(S, S^.input_buf + S^.input_buf_pos,
                          S^.input_buf_len - S^.input_buf_pos);
  if Ret < 0 then Exit(-1);
  Inc(S^.input_buf_pos, Ret);
  S^.y := -1;
  Result := 0;
end;

procedure bpg_decoder_close(S: PBPGDecoderContext);
begin
  // bpg_output.bpg_decoder_output_end must have been called by the caller
  av_free(S^.input_buf);
  hevc_decode_end(S);
  av_frame_free(S^.frame);
  av_frame_free(S^.alpha_frame);
  bpg_decoder_free_extension_data(S^.first_md);
  av_free(S);
end;

end.
