// BPG decoder -- Free Pascal port of libbpg 0.9.8
// In-loop filters: deblocking, SAO application and boundary strengths.
// Corresponds to: libavcodec/hevc_filter.c (USE_SAO_SMALL_BUFFER path)
//
// The ff_thread_report_progress() calls are dropped: libbpg is single-threaded.
unit h265_hevc_filter;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  h265_common, h265_hevc_defs, h265_hevcdsp, h265_hevc_refs;

procedure ff_hevc_set_qPy(S: PHEVCContext; XBase, YBase, Log2CbSize: Integer);
procedure ff_hevc_deblocking_boundary_strengths(S: PHEVCContext; X0, Y0,
  Log2TrafoSize: Integer);
procedure ff_hevc_hls_filter(S: PHEVCContext; X, Y, CtbSize: Integer);
procedure ff_hevc_hls_filters(S: PHEVCContext; XCtb, YCtb, CtbSize: Integer);
// Exported for the encoder's SAO decision. ff_hevc_hls_filter is no use there:
// it filters the CTB one step up and to the left of the coordinates given, not
// the one asked for.
procedure sao_filter_CTB(S: PHEVCContext; X, Y: Integer);

implementation

const
  tctable: array[0..53] of Byte = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4,
    5, 5, 6, 6, 7, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 24
  );
  betatable: array[0..51] of Byte = (
     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6, 7, 8,
     9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36,
    38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64
  );
  qp_c_tab: array[0..13] of Byte = (29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37);

function SAO_AT(S: PHEVCContext; X, Y: Integer): PSAOParams; inline;
begin
  Result := @S^.sao[Y * S^.sps^.ctb_width + X];
end;

function chroma_tc(S: PHEVCContext; QpY, CIdx, TcOffset: Integer): Integer;
var
  qp, qp_i, offset, idxt: Integer;
begin
  if CIdx = 1 then offset := S^.pps^.cb_qp_offset else offset := S^.pps^.cr_qp_offset;
  qp_i := av_clip_c(QpY + offset, 0, 57);
  if S^.sps^.chroma_format_idc = 1 then
  begin
    if qp_i < 30 then qp := qp_i
    else if qp_i > 43 then qp := qp_i - 6
    else qp := qp_c_tab[qp_i - 30];
  end
  else
    qp := av_clip_c(qp_i, 0, 51);
  idxt := av_clip_c(qp + 2 + TcOffset, 0, 53);
  Result := tctable[idxt];
end;

function get_qPy_pred(S: PHEVCContext; XBase, YBase, Log2CbSize: Integer): Integer;
var
  LC: PHEVCLocalContext;
  ctb_size_mask, MinCuQpDeltaSizeMask, xQgBase, yQgBase: Integer;
  min_cb_width, x_cb, y_cb, availableA, availableB: Integer;
  qPy_pred, qPy_a, qPy_b: Integer;
begin
  LC := S^.HEVClc;
  ctb_size_mask := (1 shl S^.sps^.log2_ctb_size) - 1;
  MinCuQpDeltaSizeMask := (1 shl (Integer(S^.sps^.log2_ctb_size) - S^.pps^.diff_cu_qp_delta_depth)) - 1;
  xQgBase := XBase - (XBase and MinCuQpDeltaSizeMask);
  yQgBase := YBase - (YBase and MinCuQpDeltaSizeMask);
  min_cb_width := S^.sps^.min_cb_width;
  x_cb := xQgBase shr S^.sps^.log2_min_cb_size;
  y_cb := yQgBase shr S^.sps^.log2_min_cb_size;
  availableA := Ord(((XBase and ctb_size_mask) <> 0) and ((xQgBase and ctb_size_mask) <> 0));
  availableB := Ord(((YBase and ctb_size_mask) <> 0) and ((yQgBase and ctb_size_mask) <> 0));

  if (LC^.first_qp_group <> 0) or ((xQgBase = 0) and (yQgBase = 0)) then
  begin
    LC^.first_qp_group := Byte(Ord(LC^.tu.is_cu_qp_delta_coded = 0));
    qPy_pred := S^.sh.slice_qp;
  end
  else
    qPy_pred := LC^.qPy_pred;

  if availableA = 0 then qPy_a := qPy_pred
  else qPy_a := S^.qp_y_tab[(x_cb - 1) + y_cb * min_cb_width];
  if availableB = 0 then qPy_b := qPy_pred
  else qPy_b := S^.qp_y_tab[x_cb + (y_cb - 1) * min_cb_width];
  Result := (qPy_a + qPy_b + 1) shr 1;
end;

procedure ff_hevc_set_qPy(S: PHEVCContext; XBase, YBase, Log2CbSize: Integer);
var
  qp_y, off, V, M: Integer;
begin
  qp_y := get_qPy_pred(S, XBase, YBase, Log2CbSize);
  if S^.HEVClc^.tu.cu_qp_delta <> 0 then
  begin
    off := S^.sps^.qp_bd_offset;
    V := qp_y + S^.HEVClc^.tu.cu_qp_delta + 52 + 2 * off;
    M := 52 + off;
    // the reference open-codes a positive modulo here
    if V > 0 then
      S^.HEVClc^.qp_y := Int8(V - M * (V div M) - off)
    else
      S^.HEVClc^.qp_y := Int8(V - M * ((V - M + 1) div M) - off);
  end
  else
    S^.HEVClc^.qp_y := Int8(qp_y);
end;

function get_qPy(S: PHEVCContext; XC, YC: Integer): Integer;
var
  log2_min_cb_size, X, Y: Integer;
begin
  log2_min_cb_size := S^.sps^.log2_min_cb_size;
  X := XC shr log2_min_cb_size;
  Y := YC shr log2_min_cb_size;
  Result := S^.qp_y_tab[X + Y * S^.sps^.min_cb_width];
end;

procedure copy_CTB(Dst, Src: PByte; Width, Height: Integer;
  StrideDst, StrideSrc: Integer);
var
  I: Integer;
begin
  for I := 0 to Height - 1 do
  begin
    Move(Src^, Dst^, Width);
    Dst := Dst + StrideDst;
    Src := Src + StrideSrc;
  end;
end;

procedure copy_pixel(Dst, Src: PByte; PixelShift: Integer); inline;
begin
  if PixelShift <> 0 then PWord(Dst)^ := PWord(Src)^ else Dst^ := Src^;
end;

procedure copy_vert(Dst, Src: PByte; PixelShift, Height, StrideDst, StrideSrc: Integer);
var
  I: Integer;
begin
  if PixelShift = 0 then
    for I := 0 to Height - 1 do
    begin
      Dst^ := Src^;
      Dst := Dst + StrideDst;
      Src := Src + StrideSrc;
    end
  else
    for I := 0 to Height - 1 do
    begin
      PWord(Dst)^ := PWord(Src)^;
      Dst := Dst + StrideDst;
      Src := Src + StrideSrc;
    end;
end;

procedure copy_CTB_to_hv(S: PHEVCContext; Src: PByte; StrideSrc, X, Y,
  Width, Height, CIdx, XCtb, YCtb: Integer);
var
  Sh, W, H: Integer;
begin
  Sh := S^.sps^.pixel_shift;
  W := S^.sps^.width shr S^.sps^.hshift[CIdx];
  H := S^.sps^.height shr S^.sps^.vshift[CIdx];
  Move(Src^, (S^.sao_pixel_buffer_h[CIdx] + (((2 * YCtb) * W + X) shl Sh))^, Width shl Sh);
  Move((Src + StrideSrc * (Height - 1))^,
       (S^.sao_pixel_buffer_h[CIdx] + (((2 * YCtb + 1) * W + X) shl Sh))^, Width shl Sh);
  copy_vert(S^.sao_pixel_buffer_v[CIdx] + (((2 * XCtb) * H + Y) shl Sh), Src,
    Sh, Height, 1 shl Sh, StrideSrc);
  copy_vert(S^.sao_pixel_buffer_v[CIdx] + (((2 * XCtb + 1) * H + Y) shl Sh),
    Src + ((Width - 1) shl Sh), Sh, Height, 1 shl Sh, StrideSrc);
end;

procedure restore_tqb_pixels(S: PHEVCContext; Src1, Dst1: PByte;
  StrideSrc, StrideDst: PtrInt; X0, Y0, Width, Height, CIdx: Integer);
var
  X, Y, N, min_pu_size, hshift, vshift: Integer;
  x_min, y_min, x_max, y_max, Len, lps, ps: Integer;
  Src, Dst: PByte;
begin
  if (S^.pps^.transquant_bypass_enable_flag <> 0) or
     ((S^.sps^.pcm.loop_filter_disable_flag <> 0) and (S^.sps^.pcm_enabled_flag <> 0)) then
  begin
    lps := S^.sps^.log2_min_pu_size;
    ps := S^.sps^.pixel_shift;
    min_pu_size := 1 shl lps;
    hshift := S^.sps^.hshift[CIdx];
    vshift := S^.sps^.vshift[CIdx];
    x_min := X0 shr lps;
    y_min := Y0 shr lps;
    x_max := (X0 + Width) shr lps;
    y_max := (Y0 + Height) shr lps;
    Len := (min_pu_size shr hshift) shl ps;
    for Y := y_min to y_max - 1 do
      for X := x_min to x_max - 1 do
        if S^.is_pcm[Y * S^.sps^.min_pu_width + X] <> 0 then
        begin
          // NOTE: libbpg subtracts the pixel coordinates x0/y0 from the PU
          // indices x/y here, where upstream FFmpeg subtracts x_min/y_min.
          // Reproduced verbatim so that the output matches bpgdec.
          Src := Src1 + (((Y - Y0) shl lps) shr vshift) * StrideSrc +
                 ((((X - X0) shl lps) shr hshift) shl ps);
          Dst := Dst1 + (((Y - Y0) shl lps) shr vshift) * StrideDst +
                 ((((X - X0) shl lps) shr hshift) shl ps);
          for N := 0 to (min_pu_size shr vshift) - 1 do
          begin
            Move(Dst^, Src^, Len);
            Src := Src + StrideSrc;
            Dst := Dst + StrideDst;
          end;
        end;
  end;
end;

function TabSliceAddr(S: PHEVCContext; X, Y: Integer): Int32; inline;
begin
  Result := S^.tab_slice_address[Y * S^.sps^.ctb_width + X];
end;

procedure sao_filter_CTB(S: PHEVCContext; X, Y: Integer);
var
  CIdx, c_count: Integer;
  edges: array[0..3] of Integer;
  x_ctb, y_ctb, ctb_addr_rs, ctb_addr_ts: Integer;
  Sao: PSAOParams;
  vert_edge, horiz_edge: array[0..1] of Byte;
  diag_edge: array[0..3] of Byte;
  lfase, no_tile_filter, restore: Byte;
  left_tile_edge, right_tile_edge, up_tile_edge, bottom_tile_edge: Byte;
  X0, Y0, stride_src, ctb_size_h, ctb_size_v, Width, Height: Integer;
  Src, Dst: PByte;
  stride_dst: Integer;
  W, H, left_edge, top_edge, right_edge, bottom_edge, Sh: Integer;
  left_pixels, right_pixels, Left_, Right_, src_idx, Pos: Integer;
  Src1: array[0..1] of PByte;
  Dst1: PByte;
  CW: Integer;
begin
  x_ctb := X shr S^.sps^.log2_ctb_size;
  y_ctb := Y shr S^.sps^.log2_ctb_size;
  CW := S^.sps^.ctb_width;
  ctb_addr_rs := y_ctb * CW + x_ctb;
  ctb_addr_ts := S^.pps^.ctb_addr_rs_to_ts[ctb_addr_rs];
  Sao := SAO_AT(S, x_ctb, y_ctb);
  vert_edge[0] := 0; vert_edge[1] := 0;
  horiz_edge[0] := 0; horiz_edge[1] := 0;
  diag_edge[0] := 0; diag_edge[1] := 0; diag_edge[2] := 0; diag_edge[3] := 0;
  lfase := S^.filter_slice_edges[y_ctb * CW + x_ctb];
  no_tile_filter := Byte(Ord((S^.pps^.tiles_enabled_flag <> 0) and
    (S^.pps^.loop_filter_across_tiles_enabled_flag = 0)));
  restore := Byte(Ord((no_tile_filter <> 0) or (lfase = 0)));
  left_tile_edge := 0; right_tile_edge := 0; up_tile_edge := 0; bottom_tile_edge := 0;

  edges[0] := Ord(x_ctb = 0);
  edges[1] := Ord(y_ctb = 0);
  edges[2] := Ord(x_ctb = CW - 1);
  edges[3] := Ord(y_ctb = S^.sps^.ctb_height - 1);

  if restore <> 0 then
  begin
    if edges[0] = 0 then
    begin
      left_tile_edge := Byte(Ord((no_tile_filter <> 0) and
        (S^.pps^.tile_id[ctb_addr_ts] <> S^.pps^.tile_id[S^.pps^.ctb_addr_rs_to_ts[ctb_addr_rs - 1]])));
      vert_edge[0] := Byte(Ord(((lfase = 0) and
        (TabSliceAddr(S, x_ctb, y_ctb) <> TabSliceAddr(S, x_ctb - 1, y_ctb))) or (left_tile_edge <> 0)));
    end;
    if edges[2] = 0 then
    begin
      right_tile_edge := Byte(Ord((no_tile_filter <> 0) and
        (S^.pps^.tile_id[ctb_addr_ts] <> S^.pps^.tile_id[S^.pps^.ctb_addr_rs_to_ts[ctb_addr_rs + 1]])));
      vert_edge[1] := Byte(Ord(((lfase = 0) and
        (TabSliceAddr(S, x_ctb, y_ctb) <> TabSliceAddr(S, x_ctb + 1, y_ctb))) or (right_tile_edge <> 0)));
    end;
    if edges[1] = 0 then
    begin
      up_tile_edge := Byte(Ord((no_tile_filter <> 0) and
        (S^.pps^.tile_id[ctb_addr_ts] <> S^.pps^.tile_id[S^.pps^.ctb_addr_rs_to_ts[ctb_addr_rs - CW]])));
      horiz_edge[0] := Byte(Ord(((lfase = 0) and
        (TabSliceAddr(S, x_ctb, y_ctb) <> TabSliceAddr(S, x_ctb, y_ctb - 1))) or (up_tile_edge <> 0)));
    end;
    if edges[3] = 0 then
    begin
      bottom_tile_edge := Byte(Ord((no_tile_filter <> 0) and
        (S^.pps^.tile_id[ctb_addr_ts] <> S^.pps^.tile_id[S^.pps^.ctb_addr_rs_to_ts[ctb_addr_rs + CW]])));
      horiz_edge[1] := Byte(Ord(((lfase = 0) and
        (TabSliceAddr(S, x_ctb, y_ctb) <> TabSliceAddr(S, x_ctb, y_ctb + 1))) or (bottom_tile_edge <> 0)));
    end;
    if (edges[0] = 0) and (edges[1] = 0) then
      diag_edge[0] := Byte(Ord(((lfase = 0) and
        (TabSliceAddr(S, x_ctb, y_ctb) <> TabSliceAddr(S, x_ctb - 1, y_ctb - 1))) or
        (left_tile_edge <> 0) or (up_tile_edge <> 0)));
    if (edges[1] = 0) and (edges[2] = 0) then
      diag_edge[1] := Byte(Ord(((lfase = 0) and
        (TabSliceAddr(S, x_ctb, y_ctb) <> TabSliceAddr(S, x_ctb + 1, y_ctb - 1))) or
        (right_tile_edge <> 0) or (up_tile_edge <> 0)));
    if (edges[2] = 0) and (edges[3] = 0) then
      diag_edge[2] := Byte(Ord(((lfase = 0) and
        (TabSliceAddr(S, x_ctb, y_ctb) <> TabSliceAddr(S, x_ctb + 1, y_ctb + 1))) or
        (right_tile_edge <> 0) or (bottom_tile_edge <> 0)));
    if (edges[0] = 0) and (edges[3] = 0) then
      diag_edge[3] := Byte(Ord(((lfase = 0) and
        (TabSliceAddr(S, x_ctb, y_ctb) <> TabSliceAddr(S, x_ctb - 1, y_ctb + 1))) or
        (left_tile_edge <> 0) or (bottom_tile_edge <> 0)));
  end;

  if S^.sps^.chroma_format_idc <> 0 then c_count := 3 else c_count := 1;
  for CIdx := 0 to c_count - 1 do
  begin
    X0 := X shr S^.sps^.hshift[CIdx];
    Y0 := Y shr S^.sps^.vshift[CIdx];
    stride_src := S^.frame^.Linesize[CIdx];
    ctb_size_h := (1 shl S^.sps^.log2_ctb_size) shr S^.sps^.hshift[CIdx];
    ctb_size_v := (1 shl S^.sps^.log2_ctb_size) shr S^.sps^.vshift[CIdx];
    Width := FFMIN(ctb_size_h, (S^.sps^.width shr S^.sps^.hshift[CIdx]) - X0);
    Height := FFMIN(ctb_size_v, (S^.sps^.height shr S^.sps^.vshift[CIdx]) - Y0);
    Src := S^.frame^.Data[CIdx] + Y0 * stride_src + (X0 shl S^.sps^.pixel_shift);
    stride_dst := ((1 shl S^.sps^.log2_ctb_size) + 2) shl S^.sps^.pixel_shift;
    Dst := S^.sao_pixel_buffer + (1 * stride_dst) + (1 shl S^.sps^.pixel_shift);

    case Sao^.type_idx[CIdx] of
      SAO_BAND:
        begin
          copy_CTB(Dst, Src, Width shl S^.sps^.pixel_shift, Height, stride_dst, stride_src);
          copy_CTB_to_hv(S, Src, stride_src, X0, Y0, Width, Height, CIdx, x_ctb, y_ctb);
          sao_band_filter(Src, Dst, stride_src, stride_dst, Sao, @edges[0],
            Width, Height, CIdx, S^.sps^.bit_depth);
          restore_tqb_pixels(S, Src, Dst, stride_src, stride_dst, X, Y, Width, Height, CIdx);
          Sao^.type_idx[CIdx] := SAO_APPLIED;
        end;
      SAO_EDGE:
        begin
          W := S^.sps^.width shr S^.sps^.hshift[CIdx];
          H := S^.sps^.height shr S^.sps^.vshift[CIdx];
          left_edge := edges[0];
          top_edge := edges[1];
          right_edge := edges[2];
          bottom_edge := edges[3];
          Sh := S^.sps^.pixel_shift;

          if top_edge = 0 then
          begin
            Left_ := 1 - left_edge;
            Right_ := 1 - right_edge;
            Dst1 := Dst - stride_dst - (Left_ shl Sh);
            Src1[0] := Src - stride_src - (Left_ shl Sh);
            Src1[1] := S^.sao_pixel_buffer_h[CIdx] + (((2 * y_ctb - 1) * W + X0 - Left_) shl Sh);
            Pos := 0;
            if Left_ <> 0 then
            begin
              src_idx := Ord(SAO_AT(S, x_ctb - 1, y_ctb - 1)^.type_idx[CIdx] = SAO_APPLIED);
              copy_pixel(Dst1, Src1[src_idx], Sh);
              Pos := Pos + (1 shl Sh);
            end;
            src_idx := Ord(SAO_AT(S, x_ctb, y_ctb - 1)^.type_idx[CIdx] = SAO_APPLIED);
            Move((Src1[src_idx] + Pos)^, (Dst1 + Pos)^, Width shl Sh);
            if Right_ <> 0 then
            begin
              Pos := Pos + (Width shl Sh);
              src_idx := Ord(SAO_AT(S, x_ctb + 1, y_ctb - 1)^.type_idx[CIdx] = SAO_APPLIED);
              copy_pixel(Dst1 + Pos, Src1[src_idx] + Pos, Sh);
            end;
          end;

          if bottom_edge = 0 then
          begin
            Left_ := 1 - left_edge;
            Right_ := 1 - right_edge;
            Dst1 := Dst + Height * stride_dst - (Left_ shl Sh);
            Src1[0] := Src + Height * stride_src - (Left_ shl Sh);
            Src1[1] := S^.sao_pixel_buffer_h[CIdx] + (((2 * y_ctb + 2) * W + X0 - Left_) shl Sh);
            Pos := 0;
            if Left_ <> 0 then
            begin
              src_idx := Ord(SAO_AT(S, x_ctb - 1, y_ctb + 1)^.type_idx[CIdx] = SAO_APPLIED);
              copy_pixel(Dst1, Src1[src_idx], Sh);
              Pos := Pos + (1 shl Sh);
            end;
            src_idx := Ord(SAO_AT(S, x_ctb, y_ctb + 1)^.type_idx[CIdx] = SAO_APPLIED);
            Move((Src1[src_idx] + Pos)^, (Dst1 + Pos)^, Width shl Sh);
            if Right_ <> 0 then
            begin
              Pos := Pos + (Width shl Sh);
              src_idx := Ord(SAO_AT(S, x_ctb + 1, y_ctb + 1)^.type_idx[CIdx] = SAO_APPLIED);
              copy_pixel(Dst1 + Pos, Src1[src_idx] + Pos, Sh);
            end;
          end;

          left_pixels := 0;
          if left_edge = 0 then
          begin
            if SAO_AT(S, x_ctb - 1, y_ctb)^.type_idx[CIdx] = SAO_APPLIED then
              copy_vert(Dst - (1 shl Sh),
                S^.sao_pixel_buffer_v[CIdx] + (((2 * x_ctb - 1) * H + Y0) shl Sh),
                Sh, Height, stride_dst, 1 shl Sh)
            else
              left_pixels := 1;
          end;
          right_pixels := 0;
          if right_edge = 0 then
          begin
            if SAO_AT(S, x_ctb + 1, y_ctb)^.type_idx[CIdx] = SAO_APPLIED then
              copy_vert(Dst + (Width shl Sh),
                S^.sao_pixel_buffer_v[CIdx] + (((2 * x_ctb + 2) * H + Y0) shl Sh),
                Sh, Height, stride_dst, 1 shl Sh)
            else
              right_pixels := 1;
          end;

          copy_CTB(Dst - (left_pixels shl Sh), Src - (left_pixels shl Sh),
            (Width + left_pixels + right_pixels) shl Sh, Height, stride_dst, stride_src);
          copy_CTB_to_hv(S, Src, stride_src, X0, Y0, Width, Height, CIdx, x_ctb, y_ctb);
          sao_edge_filter(restore, Src, Dst, stride_src, stride_dst, Sao, @edges[0],
            Width, Height, CIdx, @vert_edge[0], @horiz_edge[0], @diag_edge[0],
            S^.sps^.bit_depth);
          restore_tqb_pixels(S, Src, Dst, stride_src, stride_dst, X, Y, Width, Height, CIdx);
          Sao^.type_idx[CIdx] := SAO_APPLIED;
        end;
    end;
  end;
end;

function get_pcm(S: PHEVCContext; X, Y: Integer): Integer;
var
  log2_min_pu_size, x_pu, y_pu: Integer;
begin
  log2_min_pu_size := S^.sps^.log2_min_pu_size;
  if (X < 0) or (Y < 0) then Exit(2);
  x_pu := X shr log2_min_pu_size;
  y_pu := Y shr log2_min_pu_size;
  if (x_pu >= S^.sps^.min_pu_width) or (y_pu >= S^.sps^.min_pu_height) then Exit(2);
  Result := S^.is_pcm[y_pu * S^.sps^.min_pu_width + x_pu];
end;

procedure deblocking_filter_CTB(S: PHEVCContext; X0, Y0: Integer);
var
  Src: PByte;
  X, Y, chroma, beta: Integer;
  c_tc, tc: array[0..1] of Int32;
  no_p, no_q: array[0..1] of Byte;
  log2_ctb_size, x_end, x_end2, y_end, ctb_size, ctb: Integer;
  cur_tc_offset, cur_beta_offset, left_tc_offset, left_beta_offset: Integer;
  tc_offset, beta_offset, pcmf, bit_depth: Integer;
  bs0, bs1, qp, qp0, qp1, H, V: Integer;
begin
  no_p[0] := 0; no_p[1] := 0;
  no_q[0] := 0; no_q[1] := 0;
  log2_ctb_size := S^.sps^.log2_ctb_size;
  ctb_size := 1 shl log2_ctb_size;
  ctb := (X0 shr log2_ctb_size) + (Y0 shr log2_ctb_size) * S^.sps^.ctb_width;
  cur_tc_offset := S^.deblock[ctb].tc_offset;
  cur_beta_offset := S^.deblock[ctb].beta_offset;
  pcmf := Ord(((S^.sps^.pcm_enabled_flag <> 0) and (S^.sps^.pcm.loop_filter_disable_flag <> 0)) or
              (S^.pps^.transquant_bypass_enable_flag <> 0));
  bit_depth := S^.sps^.bit_depth;

  if X0 <> 0 then
  begin
    left_tc_offset := S^.deblock[ctb - 1].tc_offset;
    left_beta_offset := S^.deblock[ctb - 1].beta_offset;
  end
  else
  begin
    left_tc_offset := 0;
    left_beta_offset := 0;
  end;

  x_end := X0 + ctb_size;
  if x_end > S^.sps^.width then x_end := S^.sps^.width;
  y_end := Y0 + ctb_size;
  if y_end > S^.sps^.height then y_end := S^.sps^.height;

  tc_offset := cur_tc_offset;
  beta_offset := cur_beta_offset;
  x_end2 := x_end;
  if x_end2 <> S^.sps^.width then x_end2 := x_end2 - 8;

  Y := Y0;
  while Y < y_end do
  begin
    if X0 <> 0 then X := X0 else X := 8;
    while X < x_end do
    begin
      bs0 := S^.vertical_bs[(X + Y * S^.bs_width) shr 2];
      bs1 := S^.vertical_bs[(X + (Y + 4) * S^.bs_width) shr 2];
      if (bs0 <> 0) or (bs1 <> 0) then
      begin
        qp := (get_qPy(S, X - 1, Y) + get_qPy(S, X, Y) + 1) shr 1;
        beta := betatable[av_clip_c(qp + beta_offset, 0, 51)];
        if bs0 <> 0 then
          tc[0] := tctable[av_clip_c(qp + 2 * (bs0 - 1) + ((tc_offset shr 1) shl 1), 0, 53)]
        else tc[0] := 0;
        if bs1 <> 0 then
          tc[1] := tctable[av_clip_c(qp + 2 * (bs1 - 1) + ((tc_offset shr 1) shl 1), 0, 53)]
        else tc[1] := 0;
        Src := S^.frame^.Data[0] + Y * S^.frame^.Linesize[0] + (X shl S^.sps^.pixel_shift);
        if pcmf <> 0 then
        begin
          no_p[0] := Byte(get_pcm(S, X - 1, Y));
          no_p[1] := Byte(get_pcm(S, X - 1, Y + 4));
          no_q[0] := Byte(get_pcm(S, X, Y));
          no_q[1] := Byte(get_pcm(S, X, Y + 4));
        end;
        hevc_v_loop_filter_luma(Src, S^.frame^.Linesize[0], beta, @tc[0],
          @no_p[0], @no_q[0], bit_depth);
      end;
      Inc(X, 8);
    end;

    if Y <> 0 then
    begin
      if X0 <> 0 then X := X0 - 8 else X := 0;
      while X < x_end2 do
      begin
        bs0 := S^.horizontal_bs[(X + Y * S^.bs_width) shr 2];
        bs1 := S^.horizontal_bs[((X + 4) + Y * S^.bs_width) shr 2];
        if (bs0 <> 0) or (bs1 <> 0) then
        begin
          qp := (get_qPy(S, X, Y - 1) + get_qPy(S, X, Y) + 1) shr 1;
          if X >= X0 then tc_offset := cur_tc_offset else tc_offset := left_tc_offset;
          if X >= X0 then beta_offset := cur_beta_offset else beta_offset := left_beta_offset;
          beta := betatable[av_clip_c(qp + beta_offset, 0, 51)];
          if bs0 <> 0 then
            tc[0] := tctable[av_clip_c(qp + 2 * (bs0 - 1) + ((tc_offset shr 1) shl 1), 0, 53)]
          else tc[0] := 0;
          if bs1 <> 0 then
            tc[1] := tctable[av_clip_c(qp + 2 * (bs1 - 1) + ((tc_offset shr 1) shl 1), 0, 53)]
          else tc[1] := 0;
          Src := S^.frame^.Data[0] + Y * S^.frame^.Linesize[0] + (X shl S^.sps^.pixel_shift);
          if pcmf <> 0 then
          begin
            no_p[0] := Byte(get_pcm(S, X, Y - 1));
            no_p[1] := Byte(get_pcm(S, X + 4, Y - 1));
            no_q[0] := Byte(get_pcm(S, X, Y));
            no_q[1] := Byte(get_pcm(S, X + 4, Y));
          end;
          hevc_h_loop_filter_luma(Src, S^.frame^.Linesize[0], beta, @tc[0],
            @no_p[0], @no_q[0], bit_depth);
        end;
        Inc(X, 8);
      end;
    end;
    Inc(Y, 8);
  end;

  if S^.sps^.chroma_format_idc <> 0 then
  for chroma := 1 to 2 do
  begin
    H := 1 shl S^.sps^.hshift[chroma];
    V := 1 shl S^.sps^.vshift[chroma];
    Y := Y0;
    while Y < y_end do
    begin
      if X0 <> 0 then X := X0 else X := 8 * H;
      while X < x_end do
      begin
        bs0 := S^.vertical_bs[(X + Y * S^.bs_width) shr 2];
        bs1 := S^.vertical_bs[(X + (Y + 4 * V) * S^.bs_width) shr 2];
        if (bs0 = 2) or (bs1 = 2) then
        begin
          qp0 := (get_qPy(S, X - 1, Y) + get_qPy(S, X, Y) + 1) shr 1;
          qp1 := (get_qPy(S, X - 1, Y + 4 * V) + get_qPy(S, X, Y + 4 * V) + 1) shr 1;
          if bs0 = 2 then c_tc[0] := chroma_tc(S, qp0, chroma, tc_offset) else c_tc[0] := 0;
          if bs1 = 2 then c_tc[1] := chroma_tc(S, qp1, chroma, tc_offset) else c_tc[1] := 0;
          Src := S^.frame^.Data[chroma] +
                 (Y shr S^.sps^.vshift[chroma]) * S^.frame^.Linesize[chroma] +
                 ((X shr S^.sps^.hshift[chroma]) shl S^.sps^.pixel_shift);
          if pcmf <> 0 then
          begin
            no_p[0] := Byte(get_pcm(S, X - 1, Y));
            no_p[1] := Byte(get_pcm(S, X - 1, Y + 4 * V));
            no_q[0] := Byte(get_pcm(S, X, Y));
            no_q[1] := Byte(get_pcm(S, X, Y + 4 * V));
          end;
          hevc_v_loop_filter_chroma(Src, S^.frame^.Linesize[chroma], @c_tc[0],
            @no_p[0], @no_q[0], bit_depth);
        end;
        Inc(X, 8 * H);
      end;

      if Y <> 0 then
      begin
        if X0 <> 0 then tc_offset := left_tc_offset else tc_offset := cur_tc_offset;
        x_end2 := x_end;
        if x_end <> S^.sps^.width then x_end2 := x_end - 8 * H;
        if X0 <> 0 then X := X0 - 8 * H else X := 0;
        while X < x_end2 do
        begin
          bs0 := S^.horizontal_bs[(X + Y * S^.bs_width) shr 2];
          bs1 := S^.horizontal_bs[((X + 4 * H) + Y * S^.bs_width) shr 2];
          if (bs0 = 2) or (bs1 = 2) then
          begin
            if bs0 = 2 then qp0 := (get_qPy(S, X, Y - 1) + get_qPy(S, X, Y) + 1) shr 1 else qp0 := 0;
            if bs1 = 2 then
              qp1 := (get_qPy(S, X + 4 * H, Y - 1) + get_qPy(S, X + 4 * H, Y) + 1) shr 1
            else qp1 := 0;
            if bs0 = 2 then c_tc[0] := chroma_tc(S, qp0, chroma, tc_offset) else c_tc[0] := 0;
            if bs1 = 2 then c_tc[1] := chroma_tc(S, qp1, chroma, cur_tc_offset) else c_tc[1] := 0;
            Src := S^.frame^.Data[chroma] +
                   (Y shr S^.sps^.vshift[1]) * S^.frame^.Linesize[chroma] +
                   ((X shr S^.sps^.hshift[1]) shl S^.sps^.pixel_shift);
            if pcmf <> 0 then
            begin
              no_p[0] := Byte(get_pcm(S, X, Y - 1));
              no_p[1] := Byte(get_pcm(S, X + 4 * H, Y - 1));
              no_q[0] := Byte(get_pcm(S, X, Y));
              no_q[1] := Byte(get_pcm(S, X + 4 * H, Y));
            end;
            hevc_h_loop_filter_chroma(Src, S^.frame^.Linesize[chroma], @c_tc[0],
              @no_p[0], @no_q[0], bit_depth);
          end;
          Inc(X, 8 * H);
        end;
      end;
      Inc(Y, 8 * V);
    end;
  end;
end;

function MvAbsGE4(A, B: Int16): Boolean; inline;
begin
  Result := Abs(A - B) >= 4;
end;

function boundary_strength(S: PHEVCContext; Curr, Neigh: PMvField;
  NeighRefPicList: PRefPicList): Integer;
var
  A, B: TMv;
  ref_A, ref_B: Integer;
  RPL: PRefPicList;
begin
  RPL := S^.ref^.refPicList;
  if (Curr^.pred_flag = PF_BI) and (Neigh^.pred_flag = PF_BI) then
  begin
    if (RPL[0].List[Curr^.ref_idx[0]] = NeighRefPicList[0].List[Neigh^.ref_idx[0]]) and
       (RPL[0].List[Curr^.ref_idx[0]] = RPL[1].List[Curr^.ref_idx[1]]) and
       (NeighRefPicList[0].List[Neigh^.ref_idx[0]] = NeighRefPicList[1].List[Neigh^.ref_idx[1]]) then
    begin
      if ((MvAbsGE4(Neigh^.mv[0].x, Curr^.mv[0].x) or MvAbsGE4(Neigh^.mv[0].y, Curr^.mv[0].y) or
           MvAbsGE4(Neigh^.mv[1].x, Curr^.mv[1].x) or MvAbsGE4(Neigh^.mv[1].y, Curr^.mv[1].y)) and
          (MvAbsGE4(Neigh^.mv[1].x, Curr^.mv[0].x) or MvAbsGE4(Neigh^.mv[1].y, Curr^.mv[0].y) or
           MvAbsGE4(Neigh^.mv[0].x, Curr^.mv[1].x) or MvAbsGE4(Neigh^.mv[0].y, Curr^.mv[1].y))) then
        Exit(1)
      else
        Exit(0);
    end
    else if (NeighRefPicList[0].List[Neigh^.ref_idx[0]] = RPL[0].List[Curr^.ref_idx[0]]) and
            (NeighRefPicList[1].List[Neigh^.ref_idx[1]] = RPL[1].List[Curr^.ref_idx[1]]) then
    begin
      if MvAbsGE4(Neigh^.mv[0].x, Curr^.mv[0].x) or MvAbsGE4(Neigh^.mv[0].y, Curr^.mv[0].y) or
         MvAbsGE4(Neigh^.mv[1].x, Curr^.mv[1].x) or MvAbsGE4(Neigh^.mv[1].y, Curr^.mv[1].y) then
        Exit(1)
      else
        Exit(0);
    end
    else if (NeighRefPicList[1].List[Neigh^.ref_idx[1]] = RPL[0].List[Curr^.ref_idx[0]]) and
            (NeighRefPicList[0].List[Neigh^.ref_idx[0]] = RPL[1].List[Curr^.ref_idx[1]]) then
    begin
      if MvAbsGE4(Neigh^.mv[1].x, Curr^.mv[0].x) or MvAbsGE4(Neigh^.mv[1].y, Curr^.mv[0].y) or
         MvAbsGE4(Neigh^.mv[0].x, Curr^.mv[1].x) or MvAbsGE4(Neigh^.mv[0].y, Curr^.mv[1].y) then
        Exit(1)
      else
        Exit(0);
    end
    else
      Exit(1);
  end
  else if (Curr^.pred_flag <> PF_BI) and (Neigh^.pred_flag <> PF_BI) then
  begin
    if (Curr^.pred_flag and 1) <> 0 then
    begin
      A := Curr^.mv[0];
      ref_A := RPL[0].List[Curr^.ref_idx[0]];
    end
    else
    begin
      A := Curr^.mv[1];
      ref_A := RPL[1].List[Curr^.ref_idx[1]];
    end;
    if (Neigh^.pred_flag and 1) <> 0 then
    begin
      B := Neigh^.mv[0];
      ref_B := NeighRefPicList[0].List[Neigh^.ref_idx[0]];
    end
    else
    begin
      B := Neigh^.mv[1];
      ref_B := NeighRefPicList[1].List[Neigh^.ref_idx[1]];
    end;
    if ref_A = ref_B then
    begin
      if MvAbsGE4(A.x, B.x) or MvAbsGE4(A.y, B.y) then Exit(1) else Exit(0);
    end
    else
      Exit(1);
  end;
  Result := 1;
end;

procedure ff_hevc_deblocking_boundary_strengths(S: PHEVCContext; X0, Y0,
  Log2TrafoSize: Integer);
var
  LC: PHEVCLocalContext;
  log2_min_pu_size, log2_min_tu_size, min_pu_width, min_tu_width: Integer;
  tab_mvf: PMvField;
  is_intra: Integer;
  J, I, BS, boundary_upper, boundary_left: Integer;
  rpl_top, rpl_left, RPL: PRefPicList;
  yp_pu, yq_pu, yp_tu, yq_tu, x_pu, x_tu, y_pu, y_tu, xp_pu, xq_pu, xp_tu, xq_tu: Integer;
  Top, Curr, Left_: PMvField;
  top_cbf_luma, curr_cbf_luma, left_cbf_luma: Byte;
  ctb_mask: Integer;
begin
  LC := S^.HEVClc;
  log2_min_pu_size := S^.sps^.log2_min_pu_size;
  log2_min_tu_size := S^.sps^.log2_min_tb_size;
  min_pu_width := S^.sps^.min_pu_width;
  min_tu_width := S^.sps^.min_tb_width;
  tab_mvf := S^.ref^.tab_mvf;
  is_intra := Ord(tab_mvf[(Y0 shr log2_min_pu_size) * min_pu_width +
                          (X0 shr log2_min_pu_size)].pred_flag = PF_INTRA);
  ctb_mask := 1 shl S^.sps^.log2_ctb_size;

  boundary_upper := Ord((Y0 > 0) and ((Y0 and 7) = 0));
  if (boundary_upper <> 0) and
     (((S^.sh.slice_loop_filter_across_slices_enabled_flag = 0) and
       ((LC^.boundary_flags and BOUNDARY_UPPER_SLICE) <> 0) and ((Y0 mod ctb_mask) = 0)) or
      ((S^.pps^.loop_filter_across_tiles_enabled_flag = 0) and
       ((LC^.boundary_flags and BOUNDARY_UPPER_TILE) <> 0) and ((Y0 mod ctb_mask) = 0))) then
    boundary_upper := 0;

  if boundary_upper <> 0 then
  begin
    if (LC^.boundary_flags and BOUNDARY_UPPER_SLICE) <> 0 then
      rpl_top := ff_hevc_get_ref_list(S, S^.ref, X0, Y0 - 1)
    else
      rpl_top := S^.ref^.refPicList;
    yp_pu := (Y0 - 1) shr log2_min_pu_size;
    yq_pu := Y0 shr log2_min_pu_size;
    yp_tu := (Y0 - 1) shr log2_min_tu_size;
    yq_tu := Y0 shr log2_min_tu_size;
    I := 0;
    while I < (1 shl Log2TrafoSize) do
    begin
      x_pu := (X0 + I) shr log2_min_pu_size;
      x_tu := (X0 + I) shr log2_min_tu_size;
      Top := @tab_mvf[yp_pu * min_pu_width + x_pu];
      Curr := @tab_mvf[yq_pu * min_pu_width + x_pu];
      top_cbf_luma := S^.cbf_luma[yp_tu * min_tu_width + x_tu];
      curr_cbf_luma := S^.cbf_luma[yq_tu * min_tu_width + x_tu];
      if (Curr^.pred_flag = PF_INTRA) or (Top^.pred_flag = PF_INTRA) then BS := 2
      else if (curr_cbf_luma <> 0) or (top_cbf_luma <> 0) then BS := 1
      else BS := boundary_strength(S, Curr, Top, rpl_top);
      S^.horizontal_bs[((X0 + I) + Y0 * S^.bs_width) shr 2] := Byte(BS);
      Inc(I, 4);
    end;
  end;

  boundary_left := Ord((X0 > 0) and ((X0 and 7) = 0));
  if (boundary_left <> 0) and
     (((S^.sh.slice_loop_filter_across_slices_enabled_flag = 0) and
       ((LC^.boundary_flags and BOUNDARY_LEFT_SLICE) <> 0) and ((X0 mod ctb_mask) = 0)) or
      ((S^.pps^.loop_filter_across_tiles_enabled_flag = 0) and
       ((LC^.boundary_flags and BOUNDARY_LEFT_TILE) <> 0) and ((X0 mod ctb_mask) = 0))) then
    boundary_left := 0;

  if boundary_left <> 0 then
  begin
    if (LC^.boundary_flags and BOUNDARY_LEFT_SLICE) <> 0 then
      rpl_left := ff_hevc_get_ref_list(S, S^.ref, X0 - 1, Y0)
    else
      rpl_left := S^.ref^.refPicList;
    xp_pu := (X0 - 1) shr log2_min_pu_size;
    xq_pu := X0 shr log2_min_pu_size;
    xp_tu := (X0 - 1) shr log2_min_tu_size;
    xq_tu := X0 shr log2_min_tu_size;
    I := 0;
    while I < (1 shl Log2TrafoSize) do
    begin
      y_pu := (Y0 + I) shr log2_min_pu_size;
      y_tu := (Y0 + I) shr log2_min_tu_size;
      Left_ := @tab_mvf[y_pu * min_pu_width + xp_pu];
      Curr := @tab_mvf[y_pu * min_pu_width + xq_pu];
      left_cbf_luma := S^.cbf_luma[y_tu * min_tu_width + xp_tu];
      curr_cbf_luma := S^.cbf_luma[y_tu * min_tu_width + xq_tu];
      if (Curr^.pred_flag = PF_INTRA) or (Left_^.pred_flag = PF_INTRA) then BS := 2
      else if (curr_cbf_luma <> 0) or (left_cbf_luma <> 0) then BS := 1
      else BS := boundary_strength(S, Curr, Left_, rpl_left);
      S^.vertical_bs[(X0 + (Y0 + I) * S^.bs_width) shr 2] := Byte(BS);
      Inc(I, 4);
    end;
  end;

  if (Log2TrafoSize > log2_min_pu_size) and (is_intra = 0) then
  begin
    RPL := S^.ref^.refPicList;
    J := 8;
    while J < (1 shl Log2TrafoSize) do
    begin
      yp_pu := (Y0 + J - 1) shr log2_min_pu_size;
      yq_pu := (Y0 + J) shr log2_min_pu_size;
      I := 0;
      while I < (1 shl Log2TrafoSize) do
      begin
        x_pu := (X0 + I) shr log2_min_pu_size;
        Top := @tab_mvf[yp_pu * min_pu_width + x_pu];
        Curr := @tab_mvf[yq_pu * min_pu_width + x_pu];
        BS := boundary_strength(S, Curr, Top, RPL);
        S^.horizontal_bs[((X0 + I) + (Y0 + J) * S^.bs_width) shr 2] := Byte(BS);
        Inc(I, 4);
      end;
      Inc(J, 8);
    end;
    J := 0;
    while J < (1 shl Log2TrafoSize) do
    begin
      y_pu := (Y0 + J) shr log2_min_pu_size;
      I := 8;
      while I < (1 shl Log2TrafoSize) do
      begin
        xp_pu := (X0 + I - 1) shr log2_min_pu_size;
        xq_pu := (X0 + I) shr log2_min_pu_size;
        Left_ := @tab_mvf[y_pu * min_pu_width + xp_pu];
        Curr := @tab_mvf[y_pu * min_pu_width + xq_pu];
        BS := boundary_strength(S, Curr, Left_, RPL);
        S^.vertical_bs[((X0 + I) + (Y0 + J) * S^.bs_width) shr 2] := Byte(BS);
        Inc(I, 8);
      end;
      Inc(J, 4);
    end;
  end;
end;

procedure ff_hevc_hls_filter(S: PHEVCContext; X, Y, CtbSize: Integer);
var
  x_end, y_end: Boolean;
begin
  x_end := X >= S^.sps^.width - CtbSize;
  deblocking_filter_CTB(S, X, Y);
  if S^.sps^.sao_enabled <> 0 then
  begin
    y_end := Y >= S^.sps^.height - CtbSize;
    if (Y <> 0) and (X <> 0) then sao_filter_CTB(S, X - CtbSize, Y - CtbSize);
    if (X <> 0) and y_end then sao_filter_CTB(S, X - CtbSize, Y);
    if (Y <> 0) and x_end then sao_filter_CTB(S, X, Y - CtbSize);
    if x_end and y_end then sao_filter_CTB(S, X, Y);
  end;
end;

procedure ff_hevc_hls_filters(S: PHEVCContext; XCtb, YCtb, CtbSize: Integer);
var
  x_end, y_end: Boolean;
begin
  x_end := XCtb >= S^.sps^.width - CtbSize;
  y_end := YCtb >= S^.sps^.height - CtbSize;
  if (YCtb <> 0) and (XCtb <> 0) then
    ff_hevc_hls_filter(S, XCtb - CtbSize, YCtb - CtbSize, CtbSize);
  if (YCtb <> 0) and x_end then
    ff_hevc_hls_filter(S, XCtb, YCtb - CtbSize, CtbSize);
  if (XCtb <> 0) and y_end then
    ff_hevc_hls_filter(S, XCtb - CtbSize, YCtb, CtbSize);
end;

end.
