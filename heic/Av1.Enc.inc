// AV1 encoder (included into Av1.Decoder; TAv1Encoder derives from the decoder
// so prediction, inverse transforms and context bookkeeping are shared and the
// encoder's reconstruction is bit-identical to what a decoder produces).
//
// Toolset (8-bit, profile 0 4:2:0 / 4:0:0 or profile 1 4:4:4, 64x64
// superblocks, one tile, TX_MODE_LARGEST, reduced transform set, DCT only):
//  - key frames: square partitions 64..8 chosen from the prediction error,
//    luma DC / V / H / SMOOTH / SMOOTH_V / SMOOTH_H / PAETH, chroma DC;
//  - inter frames (single reference: the previous frame): segment 1 blocks
//    are motion compensated from it (NEARESTMV / NEARMV / GLOBALMV, or NEWMV
//    from a diamond search refined to quarter pixels) with an optional
//    residual; segment 0 blocks are intra coded. The segment features carry
//    the reference frame, so no reference syntax is needed.
// After a frame is coded it is run through the decoder, which leaves the
// reference slots (post-loop-filter) exactly as any decoder will have them.

type
  TBitW = record
    Buf: TBytes;
    Pos: Int64;
  end;

procedure BwPut(var W: TBitW; V: LongWord; N: Integer);
var i: Integer;
begin
  for i := N - 1 downto 0 do
  begin
    if (W.Pos shr 3) >= Length(W.Buf) then SetLength(W.Buf, Length(W.Buf) * 2 + 64);
    if ((V shr i) and 1) <> 0 then
      W.Buf[W.Pos shr 3] := W.Buf[W.Pos shr 3] or Byte(128 shr (W.Pos and 7));
    Inc(W.Pos);
  end;
end;

function BwBytes(var W: TBitW; Trailing: Boolean): TBytes;
begin
  if Trailing then BwPut(W, 1, 1);
  while (W.Pos and 7) <> 0 do BwPut(W, 0, 1);
  Result := Copy(W.Buf, 0, W.Pos shr 3);
end;

function ObuWrap(ObuType: Integer; const Payload: TBytes): TBytes;
var n, k: Integer; v: UInt64;
begin
  SetLength(Result, 1 + 8 + Length(Payload));
  Result[0] := Byte((ObuType shl 3) or 2);   // has_size_field
  n := 1;
  v := Length(Payload);
  repeat
    Result[n] := Byte(v and $7F);
    v := v shr 7;
    if v <> 0 then Result[n] := Result[n] or $80;
    Inc(n);
  until v = 0;
  for k := 0 to High(Payload) do Result[n + k] := Payload[k];
  SetLength(Result, n + Length(Payload));
end;

function TileLog2(BlkSize, Target: Integer): Integer;
begin
  Result := 0;
  while (BlkSize shl Result) < Target do Inc(Result);
end;

const
  ENC_CHUNK_LUMA = 0;
  // candidate luma intra modes (all use the DCT and need no angle search)
  EncYModes: array[0..6] of Integer = (DC_PRED, VERT_PRED, HOR_PRED, SMOOTH_PRED,
    SMOOTH_V_PRED, SMOOTH_H_PRED, PAETH_PRED);

constructor TAv1Encoder.Create(const AConfig: TAv1EncConfig);
var t, n, k, i: Integer; c: Double;
begin
  inherited Create;
  Cfg := AConfig;
  if (Cfg.Width < 1) or (Cfg.Height < 1) or (Cfg.Width > 65536) or (Cfg.Height > 65536) then
    raise EAv1.Create('AV1 encoder: invalid frame size');
  if not (Cfg.Layout in [LAYOUT_I400, LAYOUT_I420, LAYOUT_I444]) then
    raise EAv1.Create('AV1 encoder: unsupported chroma layout');
  if Cfg.QIdx < 1 then Cfg.QIdx := 1;
  if Cfg.QIdx > 255 then Cfg.QIdx := 255;
  SeqPayload := BuildSeqHdr;
  ParseSeqHdr(@SeqPayload[0], Length(SeqPayload), Seq);
  SeqValid := True;
  // orthonormal DCT-II bases
  for t := 0 to 4 do
  begin
    n := 4 shl t;
    SetLength(DctT[t], n * n);
    for k := 0 to n - 1 do
    begin
      if k = 0 then c := Sqrt(1 / n) else c := Sqrt(2 / n);
      for i := 0 to n - 1 do
        DctT[t][k * n + i] := c * Cos(Pi * (2 * i + 1) * k / (2 * n));
    end;
  end;
  Calibrate;
end;

// Gain of the decoder's inverse DCT per square size: a DC coefficient c adds
// c * TxScale / n to every pixel (n = transform side), i.e. it is the factor
// between an orthonormal DCT coefficient and the AV1 coefficient domain.
procedure TAv1Encoder.Calibrate;
var t, n, c, i, sum: Integer; buf: array of Word; d: Double;
begin
  SetLength(buf, 64 * 64);
  for t := 0 to 4 do
  begin
    n := 4 shl t;
    c := 64;
    repeat
      FillChar(buf[0], Length(buf) * 2, 0);
      FillChar(Cf[0], SizeOf(Cf), 0);
      Cf[0] := c;
      DoItx(@buf[0], 64, @Cf[0], 0, t, DCT_DCT, 8);
      sum := 0;
      for i := 0 to n * n - 1 do Inc(sum, buf[(i div n) * 64 + (i mod n)]);
      d := sum / (n * n);
      if d >= 60 then Break;
      c := c * 2;
    until c > 1 shl 20;
    TxScale[t] := d * n / c;
  end;
end;

function TAv1Encoder.BuildSeqHdr: TBytes;
var W: TBitW; wb, hb, lvl, area, profile: Integer;
begin
  W := Default(TBitW);
  if Cfg.Layout = LAYOUT_I444 then profile := 1 else profile := 0;
  BwPut(W, profile, 3);     // seq_profile
  BwPut(W, 0, 1);           // still_picture
  BwPut(W, 0, 1);           // reduced_still_picture_header
  BwPut(W, 0, 1);           // timing_info_present_flag
  BwPut(W, 0, 1);           // initial_display_delay_present_flag
  BwPut(W, 0, 5);           // operating_points_cnt_minus_1
  BwPut(W, 0, 12);          // operating_point_idc[0]
  area := Cfg.Width * Cfg.Height;
  if (area <= 147456) and (Cfg.Width <= 2048) and (Cfg.Height <= 1152) then lvl := 0
  else if (area <= 278784) and (Cfg.Width <= 2816) and (Cfg.Height <= 1584) then lvl := 1
  else if (area <= 665856) and (Cfg.Width <= 4352) and (Cfg.Height <= 2448) then lvl := 4
  else if (area <= 1065024) and (Cfg.Width <= 5504) and (Cfg.Height <= 3096) then lvl := 5
  else if (area <= 2359296) and (Cfg.Width <= 6144) and (Cfg.Height <= 3456) then lvl := 8
  else if (area <= 8912896) and (Cfg.Width <= 8192) and (Cfg.Height <= 4352) then lvl := 12
  else if (area <= 35651584) and (Cfg.Width <= 16384) and (Cfg.Height <= 8704) then lvl := 16
  else lvl := 31;
  FLevelIdx := lvl;
  BwPut(W, lvl, 5);         // seq_level_idx[0]
  if lvl > 7 then BwPut(W, 0, 1);   // seq_tier[0]
  wb := 1; while (1 shl wb) < Cfg.Width do Inc(wb);
  hb := 1; while (1 shl hb) < Cfg.Height do Inc(hb);
  BwPut(W, wb - 1, 4); BwPut(W, hb - 1, 4);
  BwPut(W, Cfg.Width - 1, wb); BwPut(W, Cfg.Height - 1, hb);
  BwPut(W, 0, 1);           // frame_id_numbers_present_flag
  BwPut(W, 0, 1);           // use_128x128_superblock
  BwPut(W, 0, 1);           // enable_filter_intra
  BwPut(W, 0, 1);           // enable_intra_edge_filter
  BwPut(W, 0, 1);           // enable_interintra_compound
  BwPut(W, 0, 1);           // enable_masked_compound
  BwPut(W, 0, 1);           // enable_warped_motion
  BwPut(W, 0, 1);           // enable_dual_filter
  BwPut(W, 0, 1);           // enable_order_hint
  BwPut(W, 0, 1);           // seq_choose_screen_content_tools
  BwPut(W, 0, 1);           // seq_force_screen_content_tools
  BwPut(W, 0, 1);           // enable_superres
  BwPut(W, 0, 1);           // enable_cdef
  BwPut(W, 0, 1);           // enable_restoration
  // color_config
  BwPut(W, 0, 1);           // high_bitdepth
  if profile <> 1 then BwPut(W, Ord(Cfg.Layout = LAYOUT_I400), 1);   // mono_chrome
  BwPut(W, 1, 1);           // color_description_present_flag
  BwPut(W, Cfg.ColorPrimaries, 8);
  BwPut(W, Cfg.TransferCharacteristics, 8);
  BwPut(W, Cfg.MatrixCoefficients, 8);
  if Cfg.Layout = LAYOUT_I400 then
    BwPut(W, Ord(Cfg.FullRange), 1)
  else if (Cfg.ColorPrimaries = CP_BT_709) and (Cfg.TransferCharacteristics = TC_SRGB) and
          (Cfg.MatrixCoefficients = MC_IDENTITY) then
  begin
    // implied full range 4:4:4
    BwPut(W, 0, 1);         // separate_uv_delta_q
  end
  else
  begin
    BwPut(W, Ord(Cfg.FullRange), 1);    // color_range
    if profile = 0 then BwPut(W, 0, 2); // chroma_sample_position (unknown)
    BwPut(W, 0, 1);         // separate_uv_delta_q
  end;
  BwPut(W, 0, 1);           // film_grain_params_present
  Result := BwBytes(W, True);
end;

function TAv1Encoder.SequenceHeaderObu: TBytes;
begin
  Result := ObuWrap(OBU_SEQUENCE_HEADER, SeqPayload);
end;

function TAv1Encoder.LoopFilterLevel: Integer;
var q: Integer;
begin
  q := Dq8Ac[Cfg.QIdx];
  if IsKey then Result := SarLongint(q * 17563 - 421574 + (1 shl 17), 18)
  else Result := SarLongint(q * 6017 + 650707 + (1 shl 17), 18);
  Result := IClip(Result, 0, 63);
end;

function TAv1Encoder.BuildFrameHdr: TBytes;
var
  W: TBitW;
  i, j, lf, sbCols, sbRows, maxLog2Cols, maxLog2Rows, minLog2Cols, minLog2Tiles: Integer;
begin
  W := Default(TBitW);
  BwPut(W, 0, 1);                       // show_existing_frame
  if IsKey then BwPut(W, KEY_FRAME, 2) else BwPut(W, INTER_FRAME, 2);
  BwPut(W, 1, 1);                       // show_frame
  if not IsKey then BwPut(W, 0, 1);     // error_resilient_mode
  BwPut(W, 0, 1);                       // disable_cdf_update
  BwPut(W, 0, 1);                       // frame_size_override_flag
  if not IsKey then
  begin
    BwPut(W, PRIMARY_REF_NONE, 3);      // primary_ref_frame
    BwPut(W, 1, 8);                     // refresh_frame_flags: slot 0
    for i := 0 to 6 do BwPut(W, 0, 3);  // ref_frame_idx[i] = slot 0
    BwPut(W, 0, 1);                     // render_and_frame_size_different
    BwPut(W, 0, 1);                     // allow_high_precision_mv
    BwPut(W, 0, 1);                     // is_filter_switchable
    BwPut(W, 0, 2);                     // interpolation_filter: EIGHTTAP
    BwPut(W, 0, 1);                     // is_motion_mode_switchable
  end
  else
    BwPut(W, 0, 1);                     // render_and_frame_size_different
  BwPut(W, 1, 1);                       // disable_frame_end_update_cdf

  // tile_info: uniform spacing, as few tiles as allowed (must be one)
  sbCols := (((Cfg.Width + 7) shr 3) * 2 + 15) shr 4;
  sbRows := (((Cfg.Height + 7) shr 3) * 2 + 15) shr 4;
  minLog2Cols := TileLog2(4096 shr 6, sbCols);
  maxLog2Cols := TileLog2(1, IMin(sbCols, 64));
  maxLog2Rows := TileLog2(1, IMin(sbRows, 64));
  minLog2Tiles := IMax(minLog2Cols, TileLog2((4096 * 2304) shr 12, sbRows * sbCols));
  if minLog2Tiles > 0 then raise EAv1.Create('AV1 encoder: frame too large for a single tile');
  BwPut(W, 1, 1);                       // uniform_tile_spacing_flag
  if maxLog2Cols > 0 then BwPut(W, 0, 1);   // increment_tile_cols_log2
  if maxLog2Rows > 0 then BwPut(W, 0, 1);   // increment_tile_rows_log2

  // quantization_params
  BwPut(W, Cfg.QIdx, 8);
  BwPut(W, 0, 1);                       // DeltaQYDc
  if Cfg.Layout <> LAYOUT_I400 then
  begin
    BwPut(W, 0, 1);                     // DeltaQUDc
    BwPut(W, 0, 1);                     // DeltaQUAc
  end;
  BwPut(W, 0, 1);                       // using_qmatrix

  // segmentation_params
  if IsKey then BwPut(W, 0, 1)
  else
  begin
    BwPut(W, 1, 1);                     // segmentation_enabled (update_map/data implied)
    for i := 0 to 7 do
      for j := 0 to 7 do
        if (i = 0) and (j = 5) then begin BwPut(W, 1, 1); BwPut(W, 0, 3); end       // seg 0: ref INTRA
        else if (i = 1) and (j = 5) then begin BwPut(W, 1, 1); BwPut(W, 1, 3); end  // seg 1: ref LAST
        else BwPut(W, 0, 1);
  end;

  BwPut(W, 0, 1);                       // delta_q_present (base_q_idx > 0)

  // loop_filter_params
  lf := LoopFilterLevel;
  BwPut(W, lf, 6); BwPut(W, lf, 6);
  if (Cfg.Layout <> LAYOUT_I400) and (lf <> 0) then
  begin
    BwPut(W, lf, 6); BwPut(W, lf, 6);
  end;
  BwPut(W, 0, 3);                       // loop_filter_sharpness
  BwPut(W, 0, 1);                       // loop_filter_delta_enabled

  BwPut(W, 0, 1);                       // tx_mode_select = 0 -> TX_MODE_LARGEST
  if not IsKey then BwPut(W, 0, 1);     // reference_select
  BwPut(W, 1, 1);                       // reduced_tx_set
  if not IsKey then
    for i := 1 to 7 do BwPut(W, 0, 1);  // is_global
  Result := BwBytes(W, False);
end;

procedure TAv1Encoder.LoadSource(const Y, U, V: array of Byte);
var pl, pw, ph, sw, sh, xx, yy, sx, sy: Integer; src: PByte;
begin
  for pl := 0 to NumPlanes - 1 do
  begin
    if pl = 0 then begin pw := bw * 4; ph := bh * 4; sw := FrmW; sh := FrmH; src := @Y[0]; end
    else
    begin
      pw := (bw * 4) shr ssH; ph := (bh * 4) shr ssV;
      sw := (FrmW + ssH) shr ssH; sh := (FrmH + ssV) shr ssV;
      if pl = 1 then src := @U[0] else src := @V[0];
    end;
    SrcStride[pl] := pw;
    SetLength(SrcP[pl], pw * ph);
    for yy := 0 to ph - 1 do
    begin
      sy := IMin(yy, sh - 1);
      for xx := 0 to pw - 1 do
      begin
        sx := IMin(xx, sw - 1);
        SrcP[pl][yy * pw + xx] := src[sy * sw + sx];
      end;
    end;
  end;
end;

function TAv1Encoder.Sad(Pl, X, Y, W, H: Integer): Int64;
var dst: PWord; s: PByte; i, j, stride: Integer;
begin
  Result := 0;
  if Pl = 0 then stride := StrideY else stride := StrideC;
  dst := PlanePtr(Self, Pl) + Y * stride + X;
  s := @SrcP[Pl][Y * SrcStride[Pl] + X];
  for j := 0 to H - 1 do
  begin
    for i := 0 to W - 1 do Inc(Result, Abs(Integer(s[i]) - Integer(dst[i])));
    Inc(dst, stride); Inc(s, SrcStride[Pl]);
  end;
end;

// ---------------------------------------------------------------- motion search

// Luma SAD of the source block against the reference at a whole-pixel
// displacement, the reference clamped at its edges (the decoder's emulation).
function TAv1Encoder.RefSadInt(Bw4, Bh4, Dx, Dy: Integer): Int64;
var
  x0, y0, w, h, rw, rh, rs, i, j, yy: Integer;
  P: ^TAv1Picture;
  s: PByte; r: PWord;
begin
  P := @Slots[Refp[0]].Pic;
  x0 := bx * 4 + Dx; y0 := by * 4 + Dy; w := Bw4 * 4; h := Bh4 * 4;
  rw := P^.W; rh := P^.H; rs := P^.StrideY;
  Result := 0;
  s := @SrcP[0][by * 4 * SrcStride[0] + bx * 4];
  if (x0 >= 0) and (y0 >= 0) and (x0 + w <= rw) and (y0 + h <= rh) then
  begin
    r := @P^.Y[y0 * rs + x0];
    for j := 0 to h - 1 do
    begin
      for i := 0 to w - 1 do Inc(Result, Abs(Integer(s[i]) - Integer(r[i])));
      Inc(s, SrcStride[0]); Inc(r, rs);
    end;
  end
  else
    for j := 0 to h - 1 do
    begin
      yy := IClip(y0 + j, 0, rh - 1) * rs;
      for i := 0 to w - 1 do
        Inc(Result, Abs(Integer(s[i]) - Integer(P^.Y[yy + IClip(x0 + i, 0, rw - 1)])));
      Inc(s, SrcStride[0]);
    end;
end;

// Luma SAD of the exact (sub-pixel) prediction for Mv.
function TAv1Encoder.McSad(Bw4, Bh4: Integer; const Mv: TMv): Int64;
var i, j, w, h: Integer; s: PByte; p: PWord;
begin
  w := Bw4 * 4; h := Bh4 * 4;
  Mc(@McTmp[0], nil, w, Bw4, Bh4, bx, by, 0, Mv, 0, Filter2dTab[Fh.SubpelFilterMode][Fh.SubpelFilterMode], False);
  Result := 0;
  s := @SrcP[0][by * 4 * SrcStride[0] + bx * 4];
  p := @McTmp[0];
  for j := 0 to h - 1 do
  begin
    for i := 0 to w - 1 do Inc(Result, Abs(Integer(s[i]) - Integer(p[i])));
    Inc(s, SrcStride[0]); Inc(p, w);
  end;
end;

// Approximate cost in bits of coding Mv as a residual against Ref.
function MvCompBits(D: Integer): Integer;
var v, up: Integer;
begin
  if D = 0 then Exit(0);
  v := Abs(D) - 1;
  up := v shr 3;
  Result := 4;
  while up >= 2 do begin Inc(Result); up := up shr 1; end;
end;

function MvBits(const Mv, Ref: TMv): Integer;
begin
  Result := 2 + MvCompBits(Mv.x - Ref.x) + MvCompBits(Mv.y - Ref.y);
end;

function MakeMv(X, Y: Integer): TMv; inline;
begin
  Result.x := X; Result.y := Y;
end;

// Picks the inter mode (NEARESTMV / NEARMV / GLOBALMV / NEWMV) and motion
// vector for the block at the current position; leaves the choice in Cand*
// and returns its luma SAD plus the rate term.
function TAv1Encoder.MotionSearch(Bs, EdgeFlags: Integer): Int64;
const
  Dirs: array[0..7, 0..1] of Integer = ((-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1));
var
  bw4, bh4, d, k, step, ix, iy, nx, ny, bestDrl, bits, range: Integer;
  cand, m, refMv, bestMv: TMv;
  j, bestJ, sad, tot: Int64;
  improved: Boolean;

  procedure Consider(Mode, Drl: Integer; const Mv: TMv; ModeBits: Integer);
  var jj: Int64;
  begin
    jj := McSad(bw4, bh4, Mv) + Int64(Lambda) * ModeBits;
    if jj < tot then
    begin
      tot := jj; CandMode := Mode; CandDrl := Drl; CandMv := Mv;
    end;
  end;

  function NewRef(Drl: Integer): TMv;
  begin
    if FNMvs > 1 then Result := FStack[Drl].mv.mv[0]
    else
    begin
      Result := FStack[0].mv.mv[0];
      FixMvPrecision(Fh, Result);
    end;
  end;

begin
  bw4 := BlockDim[Bs][0]; bh4 := BlockDim[Bs][1];
  RefmvsFind(RF, FStack, FNMvs, FMvCtx, 1, -1, Bs, EdgeFlags, by, bx);
  tot := High(Int64);

  // modes that reuse a predicted vector
  cand := GetGmv2d(Fh.Gmv[0], bx, by, bw4, bh4, Fh);
  Consider(GLOBALMV, 0, cand, 2);
  if FNMvs > 0 then
  begin
    cand := FStack[0].mv.mv[0]; FixMvPrecision(Fh, cand);
    Consider(NEARESTMV, NEAREST_DRL, cand, 2);
  end;
  if FNMvs > 1 then
  begin
    cand := FStack[1].mv.mv[0]; FixMvPrecision(Fh, cand);
    Consider(NEARMV, NEARER_DRL, cand, 3);
  end;
  if FNMvs > 2 then Consider(NEARMV, NEAR_DRL, FStack[2].mv.mv[0], 4);
  if FNMvs > 3 then Consider(NEARMV, NEARISH_DRL, FStack[3].mv.mv[0], 5);

  // NEWMV: whole-pixel diamond search from the best predictor, then half
  // and quarter pixel refinement on the exact prediction
  refMv := NewRef(0);
  range := 64;
  ix := SarLongint(CandMv.x + 4, 3); iy := SarLongint(CandMv.y + 4, 3);
  bestJ := RefSadInt(bw4, bh4, ix, iy) + Int64(Lambda) * MvBits(MakeMv(ix * 8, iy * 8), refMv);
  if (ix <> 0) or (iy <> 0) then
  begin
    j := RefSadInt(bw4, bh4, 0, 0) + Int64(Lambda) * MvBits(MakeMv(0, 0), refMv);
    if j < bestJ then begin bestJ := j; ix := 0; iy := 0; end;
  end;
  step := 8;
  while step >= 1 do
  begin
    repeat
      improved := False;
      nx := ix; ny := iy;
      for k := 0 to 7 do
      begin
        m := MakeMv((ix + Dirs[k][0] * step) * 8, (iy + Dirs[k][1] * step) * 8);
        if (Abs(m.x) > range * 8) or (Abs(m.y) > range * 8) then Continue;
        j := RefSadInt(bw4, bh4, ix + Dirs[k][0] * step, iy + Dirs[k][1] * step) +
          Int64(Lambda) * MvBits(m, refMv);
        if j < bestJ then
        begin
          bestJ := j; nx := ix + Dirs[k][0] * step; ny := iy + Dirs[k][1] * step; improved := True;
        end;
      end;
      ix := nx; iy := ny;
    until not improved;
    step := step shr 1;
  end;
  bestMv := MakeMv(ix * 8, iy * 8);
  bestJ := McSad(bw4, bh4, bestMv) + Int64(Lambda) * MvBits(bestMv, refMv);
  step := 4;                          // 1/8-pel units: half, then quarter pixel
  while step >= 2 do
  begin
    m := bestMv;
    for k := 0 to 7 do
    begin
      cand := MakeMv(m.x + Dirs[k][0] * step, m.y + Dirs[k][1] * step);
      j := McSad(bw4, bh4, cand) + Int64(Lambda) * MvBits(cand, refMv);
      if j < bestJ then begin bestJ := j; bestMv := cand; end;
    end;
    step := step shr 1;
  end;

  // reference vector (drl index) with the cheapest residual
  bestDrl := 0;
  bits := MvBits(bestMv, refMv);
  if FNMvs > 1 then
    for d := 1 to IMin(FNMvs - 1, 2) do
      if MvBits(bestMv, NewRef(d)) + d < bits then
      begin
        bits := MvBits(bestMv, NewRef(d)) + d;
        bestDrl := d;
      end;
  refMv := NewRef(bestDrl);
  // quarter-pel vectors need an even residual (high precision is off)
  if (((bestMv.x - refMv.x) and 1) = 0) and (((bestMv.y - refMv.y) and 1) = 0) and
     (Abs(bestMv.x - refMv.x) < 16384) and (Abs(bestMv.y - refMv.y) < 16384) then
  begin
    sad := McSad(bw4, bh4, bestMv);
    j := sad + Int64(Lambda) * (3 + bits);
    if j < tot then
    begin
      tot := j; CandMode := NEWMV; CandDrl := bestDrl; CandMv := bestMv;
    end;
  end;
  Result := tot;
end;

// Codes one motion vector residual component (D <> 0, even: 1/4 pel).
procedure TAv1Encoder.EncodeMvComp(var C: TCdfMvComponent; D: Integer);
var v, up, fp, cl, n: Integer;
begin
  MsacEncBoolAdapt(E, @C.sign[0], Ord(D < 0));
  v := Abs(D) - 1;
  up := v shr 3; fp := (v shr 1) and 3;
  if up < 2 then
  begin
    MsacEncSymbolAdapt(E, @C.classes[0], 0, 10);
    MsacEncBoolAdapt(E, @C.class0[0], up);
    MsacEncSymbolAdapt(E, @C.class0_fp[up][0], fp, 3);
  end
  else
  begin
    cl := 1;
    while (up shr (cl + 1)) <> 0 do Inc(cl);
    MsacEncSymbolAdapt(E, @C.classes[0], cl, 10);
    for n := 0 to cl - 1 do
      MsacEncBoolAdapt(E, @C.classN[n][0], (up shr n) and 1);
    MsacEncSymbolAdapt(E, @C.classN_fp[0], fp, 3);
  end;
end;

// Inter mode, reference-vector index and NEWMV residual, as DecodeBlock reads them.
procedure TAv1Encoder.EncodeInterMode;
var refMv: TMv; joint: Integer;
begin
  if B.interMode = NEWMV then
  begin
    MsacEncBoolAdapt(E, @TS^.Cdf.m.newmv_mode[FMvCtx and 7][0], 0);
    if FNMvs > 1 then
    begin
      MsacEncBoolAdapt(E, @TS^.Cdf.m.drl_bit[GetDrlContext(FStack, 0)][0], Ord(B.drlIdx >= NEARER_DRL));
      if (B.drlIdx >= NEARER_DRL) and (FNMvs > 2) then
        MsacEncBoolAdapt(E, @TS^.Cdf.m.drl_bit[GetDrlContext(FStack, 1)][0], Ord(B.drlIdx >= NEAR_DRL));
      refMv := FStack[B.drlIdx].mv.mv[0];
    end
    else
    begin
      refMv := FStack[0].mv.mv[0];
      FixMvPrecision(Fh, refMv);
    end;
    joint := 0;
    if B.mv[0].y <> refMv.y then joint := joint or MV_JOINT_V;
    if B.mv[0].x <> refMv.x then joint := joint or MV_JOINT_H;
    MsacEncSymbolAdapt(E, @TS^.Cdf.mv.joint[0], joint, 3);
    if (joint and MV_JOINT_V) <> 0 then EncodeMvComp(TS^.Cdf.mv.comp[0], B.mv[0].y - refMv.y);
    if (joint and MV_JOINT_H) <> 0 then EncodeMvComp(TS^.Cdf.mv.comp[1], B.mv[0].x - refMv.x);
  end
  else
  begin
    MsacEncBoolAdapt(E, @TS^.Cdf.m.newmv_mode[FMvCtx and 7][0], 1);
    MsacEncBoolAdapt(E, @TS^.Cdf.m.globalmv_mode[(FMvCtx shr 3) and 1][0], Ord(B.interMode <> GLOBALMV));
    if B.interMode <> GLOBALMV then
    begin
      MsacEncBoolAdapt(E, @TS^.Cdf.m.refmv_mode[(FMvCtx shr 4) and 15][0], Ord(B.interMode = NEARMV));
      if (B.interMode = NEARMV) and (FNMvs > 2) then
      begin
        MsacEncBoolAdapt(E, @TS^.Cdf.m.drl_bit[GetDrlContext(FStack, 1)][0], Ord(B.drlIdx >= NEAR_DRL));
        if (B.drlIdx >= NEAR_DRL) and (FNMvs > 3) then
          MsacEncBoolAdapt(E, @TS^.Cdf.m.drl_bit[GetDrlContext(FStack, 2)][0], Ord(B.drlIdx >= NEARISH_DRL));
      end;
    end;
  end;
end;

// Luma intra prediction of the whole block (a single transform) with Mode.
procedure TAv1Encoder.PredictLuma(Bs, Mode, EdgeFlags: Integer);
var td: PTxDim; angle, m, ef: Integer; dst: PWord;
begin
  td := @TxDims[MaxTxfmSizeForBs[Bs][0]];
  dst := @Yp[4 * (by * StrideY + bx)];
  angle := 0;
  ef := 0;
  if (EdgeFlags and EDGE_I444_TOP_HAS_RIGHT) <> 0 then ef := ef or EDGE_I444_TOP_HAS_RIGHT;
  if (EdgeFlags and EDGE_I444_LEFT_HAS_BOTTOM) <> 0 then ef := ef or EDGE_I444_LEFT_HAS_BOTTOM;
  m := PrepareIntraEdges(bx, bx > TS^.ColStart, by, by > TS^.RowStart, TS^.ColEnd, TS^.RowEnd,
    ef, dst, StrideY, Mode, angle, td^.w, td^.h, Seq.IntraEdgeFilter);
  IntraPred(m, dst, StrideY, td^.w * 4, td^.h * 4, angle, 4 * Self.bw - 4 * bx, 4 * Self.bh - 4 * by);
end;

function DequantLevel(Lvl, Dq, Shift: Integer): Integer;
var s: Integer; tok, m: LongWord;
begin
  s := Ord(Lvl < 0);
  tok := LongWord(Abs(Lvl));
  if tok >= 15 then
  begin
    tok := tok and $FFFFF;
    m := ((LongWord(Dq) * tok) and $FFFFFF) shr Shift;
    m := m - LongWord(s);
    if m > LongWord(Av1.Recon.ReconCfMax) then m := LongWord(Av1.Recon.ReconCfMax);
  end
  else
    m := ((LongWord(Dq) * tok) shr Shift) - LongWord(s);
  Result := Integer(m xor LongWord(-s));
end;

// Forward transform + quantisation of one square transform block at plane
// pixel position (Px, Py) whose prediction is in Dst; the levels are appended
// to LvlBuf and the reconstruction is written to Dst. Returns the eob.
function TAv1Encoder.QuantTx(Pl, Tx, Px, Py: Integer; Dst: PWord; Stride: Integer; Intra: Boolean): Integer;
var
  n, nc, t, u, v, i, j, shift, dq, lvl, base: Integer;
  r: array of Double;
  tmp: array of Double;
  s: PByte;
  acc, a, rnd, scale: Double;
  C: PDouble;
  lv: PInteger;
begin
  t := Tx;                              // square sizes: tx index = log2(n) - 2
  n := 4 shl t; nc := IMin(n, 32);
  SetLength(r, n * n); SetLength(tmp, n * nc);
  s := @SrcP[Pl][Py * SrcStride[Pl] + Px];
  for j := 0 to n - 1 do
    for i := 0 to n - 1 do
      r[j * n + i] := Integer(s[j * SrcStride[Pl] + i]) - Integer(Dst[j * Stride + i]);
  C := @DctT[t][0];
  // rows: tmp[y][u]
  for j := 0 to n - 1 do
    for u := 0 to nc - 1 do
    begin
      acc := 0;
      for i := 0 to n - 1 do acc := acc + r[j * n + i] * C[u * n + i];
      tmp[j * nc + u] := acc;
    end;
  base := LvlCount;
  if Length(LvlBuf) < base + nc * nc then SetLength(LvlBuf, (base + nc * nc) * 2);
  lv := @LvlBuf[base];
  FillChar(lv^, nc * nc * SizeOf(Integer), 0);
  shift := IMax(0, t - 2);
  scale := (1 shl shift) / TxScale[t];
  for v := 0 to nc - 1 do
    for u := 0 to nc - 1 do
    begin
      acc := 0;
      for j := 0 to n - 1 do acc := acc + C[v * n + j] * tmp[j * nc + u];
      if (u = 0) and (v = 0) then begin dq := DqFor(Pl, 0); rnd := 0.5; end
      else
      begin
        dq := DqFor(Pl, 1);
        rnd := 0.36;
      end;
      a := Abs(acc) * scale / dq;
      lvl := Trunc(a + rnd);
      if lvl > 65535 then lvl := 65535;
      if acc < 0 then lvl := -lvl;
      lv[u * nc + v] := lvl;
    end;
  Inc(LvlCount, nc * nc);
  Result := CoefEob(Tx, lv);
  if Result >= 0 then
  begin
    FillChar(Cf[0], nc * nc * SizeOf(Integer), 0);
    for i := 0 to nc * nc - 1 do
      if lv[i] <> 0 then
      begin
        if i = 0 then dq := DqFor(Pl, 0) else dq := DqFor(Pl, 1);
        Cf[i] := DequantLevel(lv[i], dq, shift);
      end;
    DoItx(Dst, Stride, @Cf[0], Result, Tx, DCT_DCT, Bd);
  end;
end;

// Walks the transform blocks of the current block in decoder order. Pass 0
// predicts (intra), quantises and reconstructs, storing the levels; pass 1
// writes the stored levels (or the all-skip contexts). Returns True when any
// level is non-zero (pass 0).
function TAv1Encoder.WalkTx(Pass, Bs, EdgeFlags: Integer; HasChroma: Boolean): Boolean;
var
  bw4, bh4, w4l, h4l, cw4, ch4, cbw4, cbh4, cbx4, cby4: Integer;
  td, uvtd: PTxDim;
  initX, initY, subW4, subH4, subCw4, subCh4, x, y, pl, xx, yy: Integer;
  sbHasTr, sbHasBl, uvSbHasTr, uvSbHasBl, ef, angle, m, eob, cfCtx, stride, rd: Integer;
  intraB: Boolean;
  dst: PWord;
  actx, lctx: PByte;
begin
  Result := False;
  bw4 := BlockDim[Bs][0]; bh4 := BlockDim[Bs][1];
  w4l := IMin(bw4, Self.bw - bx); h4l := IMin(bh4, Self.bh - by);
  cw4 := (w4l + ssH) shr ssH; ch4 := (h4l + ssV) shr ssV;
  cbw4 := (bw4 + ssH) shr ssH; cbh4 := (bh4 + ssV) shr ssV;
  cbx4 := bx shr ssH; cby4 := by shr ssV;
  td := @TxDims[B.tx]; uvtd := @TxDims[B.uvtx];
  intraB := B.intra <> 0;
  if (Pass = 1) and (B.skip <> 0) then
  begin
    SetBytes(A.lcoef, bx, bw4, $40);
    SetBytes(L.lcoef, by, bh4, $40);
    if HasChroma then
    begin
      SetBytes(A.ccoef0, cbx4, cbw4, $40); SetBytes(A.ccoef1, cbx4, cbw4, $40);
      SetBytes(L.ccoef0, cby4, cbh4, $40); SetBytes(L.ccoef1, cby4, cbh4, $40);
    end;
    Exit;
  end;
  if Pass = 0 then LvlCount := 0;
  rd := 0;
  initY := 0;
  while initY < h4l do
  begin
    subH4 := IMin(h4l, 16 + initY);
    subCh4 := IMin(ch4, (initY + 16) shr ssV);
    initX := 0;
    while initX < w4l do
    begin
      subW4 := IMin(w4l, initX + 16);
      if initX + 16 < w4l then sbHasTr := 1
      else if initY <> 0 then sbHasTr := 0
      else sbHasTr := EdgeFlags and EDGE_I444_TOP_HAS_RIGHT;
      if initX <> 0 then sbHasBl := 0
      else if initY + 16 < h4l then sbHasBl := 1
      else sbHasBl := EdgeFlags and EDGE_I444_LEFT_HAS_BOTTOM;
      // luma
      y := initY;
      while y < subH4 do
      begin
        x := initX;
        while x < subW4 do
        begin
          xx := bx + x; yy := by + y;
          dst := @Yp[4 * (yy * StrideY + xx)];
          if Pass = 0 then
          begin
            if intraB then
            begin
              angle := 0; ef := 0;
              if not (((y > initY) or (sbHasTr = 0)) and (x + td^.w >= subW4)) then ef := ef or EDGE_I444_TOP_HAS_RIGHT;
              if not ((x > initX) or ((sbHasBl = 0) and (y + td^.h >= subH4))) then ef := ef or EDGE_I444_LEFT_HAS_BOTTOM;
              m := PrepareIntraEdges(xx, xx > TS^.ColStart, yy, yy > TS^.RowStart, TS^.ColEnd, TS^.RowEnd,
                ef, dst, StrideY, B.ymode, angle, td^.w, td^.h, Seq.IntraEdgeFilter);
              IntraPred(m, dst, StrideY, td^.w * 4, td^.h * 4, angle, 4 * Self.bw - 4 * xx, 4 * Self.bh - 4 * yy);
            end;
            if QuantTx(0, B.tx, xx * 4, yy * 4, dst, StrideY, intraB) >= 0 then Result := True;
          end
          else
          begin
            EncodeCoefs(E, TS^.Cdf, B.tx, bw4, bh4, B.intra, 0, 0, ssH, ssV,
              @A.lcoef[xx], @L.lcoef[yy], @LvlBuf[rd], B.ymode,
              Fh.ReducedTxtpSet, False, False, DCT_DCT, cfCtx);
            Inc(rd, IMin(td^.w * 4, 32) * IMin(td^.h * 4, 32));
            SetBytes(A.lcoef, xx, IMin(td^.w, Self.bw - xx), cfCtx);
            SetBytes(L.lcoef, yy, IMin(td^.h, Self.bh - yy), cfCtx);
          end;
          Inc(x, td^.w);
        end;
        Inc(y, td^.h);
      end;

      // chroma
      if HasChroma then
      begin
        stride := StrideC;
        if ((initX + 16) shr ssH) < cw4 then uvSbHasTr := 1
        else if initY <> 0 then uvSbHasTr := 0
        else uvSbHasTr := EdgeFlags and (EDGE_I420_TOP_HAS_RIGHT shr (Layout - 1));
        if initX <> 0 then uvSbHasBl := 0
        else if ((initY + 16) shr ssV) < ch4 then uvSbHasBl := 1
        else uvSbHasBl := EdgeFlags and (EDGE_I420_LEFT_HAS_BOTTOM shr (Layout - 1));
        subCw4 := IMin(cw4, (initX + 16) shr ssH);
        for pl := 0 to 1 do
        begin
          y := initY shr ssV;
          while y < subCh4 do
          begin
            x := initX shr ssH;
            while x < subCw4 do
            begin
              xx := bx + (x shl ssH); yy := by + (y shl ssV);   // luma 4x4 units
              dst := PlanePtr(Self, 1 + pl) + 4 * ((cby4 + y) * stride + cbx4 + x);
              if Pass = 0 then
              begin
                if intraB then
                begin
                  angle := 0; ef := 0;
                  if not (((y > (initY shr ssV)) or (uvSbHasTr = 0)) and (x + uvtd^.w >= subCw4)) then
                    ef := ef or EDGE_I444_TOP_HAS_RIGHT;
                  if not ((x > (initX shr ssH)) or ((uvSbHasBl = 0) and (y + uvtd^.h >= subCh4))) then
                    ef := ef or EDGE_I444_LEFT_HAS_BOTTOM;
                  m := PrepareIntraEdges(cbx4 + x, cbx4 + x > (TS^.ColStart shr ssH), cby4 + y,
                    cby4 + y > (TS^.RowStart shr ssV), TS^.ColEnd shr ssH, TS^.RowEnd shr ssV, ef, dst, stride,
                    B.uvmode, angle, uvtd^.w, uvtd^.h, Seq.IntraEdgeFilter);
                  IntraPred(m, dst, stride, uvtd^.w * 4, uvtd^.h * 4, angle,
                    (4 * Self.bw + ssH - 4 * (xx and not ssH)) shr ssH,
                    (4 * Self.bh + ssV - 4 * (yy and not ssV)) shr ssV);
                end;
                if QuantTx(1 + pl, B.uvtx, (cbx4 + x) * 4, (cby4 + y) * 4, dst, stride, intraB) >= 0 then
                  Result := True;
              end
              else
              begin
                if pl = 0 then begin actx := @A.ccoef0[cbx4 + x]; lctx := @L.ccoef0[cby4 + y]; end
                else begin actx := @A.ccoef1[cbx4 + x]; lctx := @L.ccoef1[cby4 + y]; end;
                EncodeCoefs(E, TS^.Cdf, B.uvtx, bw4, bh4, B.intra, 1 + pl, 1, ssH, ssV,
                  actx, lctx, @LvlBuf[rd], B.ymode,
                  Fh.ReducedTxtpSet, False, False, DCT_DCT, cfCtx);
                Inc(rd, IMin(uvtd^.w * 4, 32) * IMin(uvtd^.h * 4, 32));
                if pl = 0 then
                begin
                  SetBytes(A.ccoef0, cbx4 + x, IMin(uvtd^.w, (Self.bw - xx + ssH) shr ssH), cfCtx);
                  SetBytes(L.ccoef0, cby4 + y, IMin(uvtd^.h, (Self.bh - yy + ssV) shr ssV), cfCtx);
                end
                else
                begin
                  SetBytes(A.ccoef1, cbx4 + x, IMin(uvtd^.w, (Self.bw - xx + ssH) shr ssH), cfCtx);
                  SetBytes(L.ccoef1, cby4 + y, IMin(uvtd^.h, (Self.bh - yy + ssV) shr ssV), cfCtx);
                end;
              end;
              Inc(x, uvtd^.w);
            end;
            Inc(y, uvtd^.h);
          end;
        end;
      end;
      Inc(initX, 16);
    end;
    Inc(initY, 16);
  end;
end;

procedure TAv1Encoder.EncodeBlock(Bl, Bs, Bp, EdgeFlags: Integer; UseInter: Boolean; YMode: Integer);
var
  bw4, bh4, cbx4, cby4, cbw4, cbh4, ctx, segCtx, pred, d, cflAllowed, y: Integer;
  haveLeft, haveTop, hasChroma, nz: Boolean;
  tmpl: TRefmvsBlock;
  sav: array[0..191] of Byte;

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

begin
  bw4 := BlockDim[Bs][0]; bh4 := BlockDim[Bs][1];
  cbx4 := bx shr ssH; cby4 := by shr ssV;
  cbw4 := (bw4 + ssH) shr ssH; cbh4 := (bh4 + ssV) shr ssV;
  haveLeft := bx > TS^.ColStart;
  haveTop := by > TS^.RowStart;
  hasChroma := (Layout <> LAYOUT_I400) and ((bw4 > ssH) or ((bx and 1) <> 0)) and
               ((bh4 > ssV) or ((by and 1) <> 0));

  FillChar(B, SizeOf(B), 0);
  B.bl := Bl; B.bp := Bp; B.bs := Bs;
  B.segId := Ord(UseInter);
  B.intra := Ord(not UseInter);
  B.ymode := YMode;
  B.uvmode := DC_PRED;
  B.tx := MaxTxfmSizeForBs[Bs][0];
  B.uvtx := MaxTxfmSizeForBs[Bs][Layout];

  // prediction + quantisation (reconstruction lands in the frame planes)
  if UseInter then
  begin
    // the candidate stack is unchanged since ChooseMode (no block coded since)
    RefmvsFind(RF, FStack, FNMvs, FMvCtx, 1, -1, Bs, EdgeFlags, by, bx);
    B.ref[0] := 0; B.ref[1] := -1;
    B.interMode := CandMode; B.drlIdx := CandDrl; B.mv[0] := CandMv;
    B.compType := COMP_INTER_NONE; B.motionMode := MM_TRANSLATION;
    B.interintraType := INTER_INTRA_NONE;
    B.filter2d := Filter2dTab[Fh.SubpelFilterMode][Fh.SubpelFilterMode];
    B.maxYtx := B.tx;
    // prediction only (skip set): ReconInter then resets the coefficient
    // contexts of the block's rows / columns, which still hold the
    // neighbours' contexts the residual below is coded against
    Move(A.lcoef[bx], sav[0], bw4); Move(L.lcoef[by], sav[32], bh4);
    Move(A.ccoef0[cbx4], sav[64], cbw4); Move(A.ccoef1[cbx4], sav[96], cbw4);
    Move(L.ccoef0[cby4], sav[128], cbh4); Move(L.ccoef1[cby4], sav[160], cbh4);
    B.skip := 1;
    ReconInter(Bs);
    B.skip := 0;
    Move(sav[0], A.lcoef[bx], bw4); Move(sav[32], L.lcoef[by], bh4);
    Move(sav[64], A.ccoef0[cbx4], cbw4); Move(sav[96], A.ccoef1[cbx4], cbw4);
    Move(sav[128], L.ccoef0[cby4], cbh4); Move(sav[160], L.ccoef1[cby4], cbh4);
  end;
  nz := WalkTx(0, Bs, EdgeFlags, hasChroma);
  B.skip := Ord(not nz);

  // syntax
  if not IsKey then
  begin
    pred := CurFrameSegId(segCtx);
    d := 0;
    while NegDeinterleave(d, pred, 2) <> B.segId do Inc(d);
    MsacEncSymbolAdapt(E, @TS^.Cdf.m.seg_id[segCtx][0], d, 7);
  end;
  ctx := A.skip[bx] + L.skip[by];
  MsacEncBoolAdapt(E, @TS^.Cdf.m.skip[ctx][0], B.skip);
  if B.intra <> 0 then
  begin
    if IsKey then
      MsacEncSymbolAdapt(E, @TS^.Cdf.kfym[IntraModeContext[A.mode[bx]]][IntraModeContext[L.mode[by]]][0],
        B.ymode, N_INTRA_PRED_MODES - 1)
    else
      MsacEncSymbolAdapt(E, @TS^.Cdf.m.y_mode[YmodeSizeContext[Bs]][0], B.ymode, N_INTRA_PRED_MODES - 1);
    if (BlockDim[Bs][2] + BlockDim[Bs][3] >= 2) and (B.ymode >= VERT_PRED) and (B.ymode <= VERT_LEFT_PRED) then
      MsacEncSymbolAdapt(E, @TS^.Cdf.m.angle_delta[B.ymode - VERT_PRED][0], 3, 6);
    if hasChroma then
    begin
      cflAllowed := Ord((CflAllowedMask and (1 shl Bs)) <> 0);
      MsacEncSymbolAdapt(E, @TS^.Cdf.m.uv_mode[cflAllowed][B.ymode][0], B.uvmode,
        N_UV_INTRA_PRED_MODES - 1 - (1 - cflAllowed));
    end;
  end
  else
  begin
    EncodeInterMode;
  end;
  WalkTx(1, Bs, EdgeFlags, hasChroma);

  // contexts used by later symbols
  SetBytes(A.skip, bx, bw4, B.skip); SetBytes(L.skip, by, bh4, B.skip);
  SetBytes(A.intra, bx, bw4, B.intra); SetBytes(L.intra, by, bh4, B.intra);
  if B.intra <> 0 then
  begin
    SetBytes(A.mode, bx, bw4, B.ymode); SetBytes(L.mode, by, bh4, B.ymode);
  end
  else
  begin
    SetBytes(A.mode, bx, bw4, GLOBALMV); SetBytes(L.mode, by, bh4, GLOBALMV);
  end;
  if hasChroma then
  begin
    SetBytes(A.uvmode, cbx4, cbw4, DC_PRED); SetBytes(L.uvmode, cby4, cbh4, DC_PRED);
  end;
  if not IsKey then
  begin
    for y := 0 to bh4 - 1 do
      FillChar(CurSegMap[(by + y) * b4Stride + bx], bw4, B.segId);
    // motion vector candidates for later blocks (as DecodeBlock splats them)
    FillChar(tmpl, SizeOf(tmpl), 0);
    tmpl.bs := Bs;
    if B.intra <> 0 then
    begin
      tmpl.ref.ref[0] := 0; tmpl.ref.ref[1] := -1;
      tmpl.mv.mv[0].n := INVALID_MV;
    end
    else
    begin
      tmpl.ref.ref[0] := 1; tmpl.ref.ref[1] := -1;
      tmpl.mv.mv[0] := B.mv[0];
      tmpl.mf := Ord((B.interMode = GLOBALMV) and (IMin(bw4, bh4) >= 2)) or (Ord(B.interMode = NEWMV) * 2);
    end;
    RefmvsSplat(RF, tmpl, by, bx, bw4, bh4);
  end;
end;

// Chooses inter (motion search) or the best intra mode for the block at the
// current position; returns the luma SAD of the choice. The prediction is
// left in the frame planes.
function TAv1Encoder.ChooseMode(Bs, EdgeFlags: Integer; out UseInter: Boolean; out YMode: Integer): Int64;
var bw4, bh4, k, n: Integer; s, best, interSad: Int64;
begin
  bw4 := BlockDim[Bs][0]; bh4 := BlockDim[Bs][1];
  n := bw4 * bh4 * 16;
  best := High(Int64); YMode := DC_PRED;
  for k := 0 to High(EncYModes) do
  begin
    PredictLuma(Bs, EncYModes[k], EdgeFlags);
    s := Sad(0, bx * 4, by * 4, bw4 * 4, bh4 * 4);
    if EncYModes[k] <> DC_PRED then Inc(s, n div 16);
    if s < best then begin best := s; YMode := EncYModes[k]; end;
  end;
  UseInter := False;
  if not IsKey then
  begin
    interSad := MotionSearch(Bs, EdgeFlags);
    if interSad <= best + n div 8 then
    begin
      UseInter := True;
      best := interSad;
    end;
  end;
  Result := best;
end;

procedure TAv1Encoder.EncodeSb(Bl, Node: Integer);
var
  hsz, bx8, by8, ctx, bp, k, ymode, bs: Integer;
  haveH, haveV, split, useInter: Boolean;
  pc: PWord;
  N: ^TEdgeNode;
  cost: Int64;
  thr: Double;

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

begin
  if Node < 0 then Node := EdgeRoot[1];
  N := @EdgeNodes[Node];
  hsz := 16 shr Bl;
  haveH := Self.bw > bx + hsz;
  haveV := Self.bh > by + hsz;
  if (not haveH) and (not haveV) then
  begin
    EncodeSb(Bl + 1, N^.split[0]);
    Exit;
  end;
  bx8 := bx shr 1; by8 := by shr 1;
  ctx := ((A.partition[bx8] shr (4 - Bl)) and 1) + (((L.partition[by8] shr (4 - Bl)) and 1) shl 1);
  pc := @TS^.Cdf.m.partition[Bl][ctx][0];
  ymode := DC_PRED; useInter := False;

  if haveH and haveV then
  begin
    bs := BlockSizes[Bl][PARTITION_NONE][0];
    if (bx + 2 * hsz > Self.bw) or (by + 2 * hsz > Self.bh) then split := True
    else
    begin
      cost := ChooseMode(bs, N^.o, useInter, ymode);
      if Bl = BL_64X64 then begin if useInter then thr := SplitThr * 0.15 else thr := SplitThr * 0.3; end
      else if useInter then thr := SplitThr * 0.8 else thr := SplitThr;
      split := (Bl < BL_8X8) and (cost > thr * BlockDim[bs][0] * BlockDim[bs][1] * 16);
    end;
    if split then bp := PARTITION_SPLIT else bp := PARTITION_NONE;
    MsacEncSymbolAdapt(E, pc, bp, PartitionTypeCount[Bl]);
    if split then
    begin
      EncodeSb(Bl + 1, N^.split[0]);
      Inc(bx, hsz);
      EncodeSb(Bl + 1, N^.split[1]);
      Dec(bx, hsz); Inc(by, hsz);
      EncodeSb(Bl + 1, N^.split[2]);
      Inc(bx, hsz);
      EncodeSb(Bl + 1, N^.split[3]);
      Dec(bx, hsz); Dec(by, hsz);
    end
    else
      EncodeBlock(Bl, bs, bp, N^.o, useInter, ymode);
  end
  else if haveH then
  begin
    // bottom half outside the frame: always split
    MsacEncBool(E, 1, GatherTop);
    bp := PARTITION_SPLIT;
    EncodeSb(Bl + 1, N^.split[0]);
    Inc(bx, hsz);
    EncodeSb(Bl + 1, N^.split[1]);
    Dec(bx, hsz);
  end
  else
  begin
    MsacEncBool(E, 1, GatherLeft);
    bp := PARTITION_SPLIT;
    EncodeSb(Bl + 1, N^.split[0]);
    Inc(by, hsz);
    EncodeSb(Bl + 1, N^.split[2]);
    Dec(by, hsz);
  end;

  if (bp <> PARTITION_SPLIT) or (Bl = BL_8X8) then
    for k := 0 to hsz - 1 do
    begin
      A.partition[bx8 + k] := AlPartCtx[0][Bl][bp];
      L.partition[by8 + k] := AlPartCtx[1][Bl][bp];
    end;
end;

function TAv1Encoder.EncodeFrame(const Y, U, V: array of Byte; ForceKey: Boolean;
  out IsKeyFrame: Boolean): TBytes;
var
  hdr, tile, payload, tu: TBytes;
  refs: TRefHdrs;
  hdrBits: Int64;
  k, sby: Integer;
  ts0: ^TTileState;
  dummy: TAv1Frame;
begin
  IsKey := ForceKey or (FrameCount = 0) or
    ((Cfg.KeyFrameInterval > 0) and (FrameCount mod Cfg.KeyFrameInterval = 0));
  IsKeyFrame := IsKey;
  hdr := BuildFrameHdr;
  for k := 0 to 7 do
    if Slots[k].Valid then refs[k] := @Slots[k].Pic.Hdr else refs[k] := nil;
  ParseFrameHdr(Seq, refs, 0, 0, @hdr[0], Length(hdr), Fh, hdrBits);
  SetupFrame;
  LoadSource(Y, U, V);
  SplitThr := 0.6 * (FrameDq[0][0][1] / 8) + 1.0;
  Lambda := IMax(1, FrameDq[0][0][1] div 16);

  SetLength(Tiles, 1);
  ts0 := @Tiles[0];
  ts0^.Cdf := InCdf;
  ts0^.LastQidx := Fh.Quant.Yac;
  FillChar(ts0^.LastDeltaLf, SizeOf(ts0^.LastDeltaLf), 0);
  ts0^.Dq := FrameDq;
  ts0^.LfLvl := FrameLfLvl;
  ts0^.TileRow := 0; ts0^.TileCol := 0;
  ts0^.ColStart := 0; ts0^.ColEnd := bw;
  ts0^.RowStart := 0; ts0^.RowEnd := bh;
  TS := ts0;
  MsacEncInit(E, Fh.DisableCdfUpdate);
  ResetCtx(A, 0, Length(A.mode), IsKeyOrIntra(Fh), False);
  for sby := 0 to sbh - 1 do
  begin
    by := sby shl sbShift;
    if not IsKey then RefmvsTileInit(RF, TS^.ColStart, TS^.ColEnd, TS^.RowStart, TS^.RowEnd);
    ResetCtx(L, by, sbStep, IsKeyOrIntra(Fh), True);
    bx := 0;
    while bx < bw do
    begin
      EncodeSb(BL_64X64, -1);
      Inc(bx, sbStep);
    end;
  end;
  tile := MsacEncDone(E);

  SetLength(payload, Length(hdr) + Length(tile));
  Move(hdr[0], payload[0], Length(hdr));
  if Length(tile) > 0 then Move(tile[0], payload[Length(hdr)], Length(tile));
  payload := ObuWrap(OBU_FRAME, payload);
  if IsKey then
  begin
    tu := SequenceHeaderObu;
    k := Length(tu);
    SetLength(tu, k + Length(payload));
    Move(payload[0], tu[k], Length(payload));
  end
  else tu := payload;

  // decode it: references (post loop filter) as every decoder will see them
  DecodeTemporalUnit(@tu[0], Length(tu), dummy);
  Inc(FrameCount);
  Result := tu;
end;
