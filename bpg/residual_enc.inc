// ---------------------------------------------------------------------------
// Encoder side of residual coding. Included into bpg_hevc_cabac so it shares the
// scan tables and sig_ctx_idx_map with ff_hevc_hls_residual_coding rather than
// keeping copies of them.
//
// The simple encoder never enables transform skip, transquant bypass, RDPCM,
// persistent Rice adaptation or sign data hiding, so those branches are absent
// here. The decoder still handles them, for streams from other encoders.
// ---------------------------------------------------------------------------

// same selection ff_hevc_hls_residual_coding makes
procedure enc_scan_tables(Log2TrafoSize, ScanIdx: Integer;
  out ScanXCg, ScanYCg, ScanXOff, ScanYOff: PByte);
var
  trafo_size: Integer;
begin
  trafo_size := 1 shl Log2TrafoSize;
  case ScanIdx of
    SCAN_DIAG:
      begin
        ScanXOff := @ff_hevc_diag_scan4x4_x[0];
        ScanYOff := @ff_hevc_diag_scan4x4_y[0];
        if trafo_size = 4 then
        begin
          ScanXCg := @scan_1x1[0];
          ScanYCg := @scan_1x1[0];
        end
        else if trafo_size = 8 then
        begin
          ScanXCg := @diag_scan2x2_x[0];
          ScanYCg := @diag_scan2x2_y[0];
        end
        else if trafo_size = 16 then
        begin
          ScanXCg := @ff_hevc_diag_scan4x4_x[0];
          ScanYCg := @ff_hevc_diag_scan4x4_y[0];
        end
        else
        begin
          ScanXCg := @ff_hevc_diag_scan8x8_x[0];
          ScanYCg := @ff_hevc_diag_scan8x8_y[0];
        end;
      end;
    SCAN_HORIZ:
      begin
        ScanXCg := @horiz_scan2x2_x[0];
        ScanYCg := @horiz_scan2x2_y[0];
        ScanXOff := @horiz_scan4x4_x[0];
        ScanYOff := @horiz_scan4x4_y[0];
      end;
  else
    ScanXCg := @horiz_scan2x2_y[0];
    ScanYCg := @horiz_scan2x2_x[0];
    ScanXOff := @horiz_scan4x4_y[0];
    ScanYOff := @horiz_scan4x4_x[0];
  end;
end;

procedure enc_last_sig_prefix(S: PHEVCContext; var E: TCabacEncoder;
  CIdx, Log2Size, Value, ElemIdx: Integer);
var
  I, Max, ctx_offset, ctx_shift: Integer;
begin
  Max := (Log2Size shl 1) - 1;
  if CIdx = 0 then
  begin
    ctx_offset := 3 * (Log2Size - 2) + ((Log2Size - 1) shr 2);
    ctx_shift := (Log2Size + 1) shr 2;
  end
  else
  begin
    ctx_offset := 15;
    ctx_shift := Log2Size - 2;
  end;
  for I := 0 to Value - 1 do
    cabac_enc_bin(E, CtxPtr(S, elem_offset[ElemIdx] + (I shr ctx_shift) + ctx_offset), 1);
  if Value < Max then
    cabac_enc_bin(E, CtxPtr(S, elem_offset[ElemIdx] + (Value shr ctx_shift) + ctx_offset), 0);
end;

// splits a last-significant position into the prefix/suffix pair the decoder
// reassembles as (1 shl ((prefix shr 1) - 1)) * (2 + (prefix and 1)) + suffix
procedure split_last_sig(V: Integer; out Prefix, Suffix, SuffixLen: Integer);
var
  G, Base: Integer;
begin
  if V < 4 then
  begin
    Prefix := V;
    Suffix := 0;
    SuffixLen := 0;
    Exit;
  end;
  G := av_log2(Cardinal(V));
  if V < 3 * (1 shl (G - 1)) then Prefix := 2 * G else Prefix := 2 * G + 1;
  Base := (1 shl ((Prefix shr 1) - 1)) * (2 + (Prefix and 1));
  Suffix := V - Base;
  SuffixLen := (Prefix shr 1) - 1;
end;

// inverse of coeff_abs_level_remaining_decode
procedure enc_coeff_abs_level_remaining(var E: TCabacEncoder;
  Value, RcRiceParam: Integer);
var
  Prefix, Suffix, I, prefix_minus3: Integer;
begin
  if Value < (3 shl RcRiceParam) then
  begin
    Prefix := Value shr RcRiceParam;
    Suffix := Value and ((1 shl RcRiceParam) - 1);
    for I := 0 to Prefix - 1 do cabac_enc_bypass(E, 1);
    cabac_enc_bypass(E, 0);
    if RcRiceParam > 0 then
      cabac_enc_bypass_bits(E, RcRiceParam, Cardinal(Suffix));
  end
  else
  begin
    prefix_minus3 := 0;
    while Value >= ((((1 shl (prefix_minus3 + 1)) + 3 - 1) shl RcRiceParam)) do
      Inc(prefix_minus3);
    Prefix := prefix_minus3 + 3;
    Suffix := Value - ((((1 shl prefix_minus3) + 3 - 1) shl RcRiceParam));
    for I := 0 to Prefix - 1 do cabac_enc_bypass(E, 1);
    if Prefix < 31 then cabac_enc_bypass(E, 0);
    cabac_enc_bypass_bits(E, prefix_minus3 + RcRiceParam, Cardinal(Suffix));
  end;
end;

// Sign data hiding demands that, in every coefficient group where the hidden
// sign applies (last minus first significant scan position >= 4), the parity of
// the sum of absolute levels equals the sign of the first significant
// coefficient. This pre-pass adjusts one level by one where the parity is
// wrong. It MUST run before the encoder reconstructs the block: the decoder
// will reconstruct the adjusted levels, so the encoder has to as well, or the
// two drift apart silently.
//
// The adjustment never creates or destroys a significant coefficient (a level
// of 1 is raised, never lowered), so the significance map is untouched. Which
// level to nudge is a free choice distortion-wise -- the transform is
// orthogonal and the quantiser step uniform, so every coefficient costs the
// same reconstruction error -- so the largest one is lowered, which also saves
// bits.
procedure sign_hide_adjust(S: PHEVCContext; Coeffs, PreQ: PInt16;
  Log2TrafoSize, ScanIdx, QpUsed: Integer);
const
  sh_level_scale: array[0..5] of Integer = (40, 45, 51, 57, 64, 72);
var
  trafo_size, NGroups, I, N, x_cg, y_cg, x_c, y_c: Integer;
  scan_x_cg, scan_y_cg, scan_x_off, scan_y_off: PByte;
  first_nz, last_nz, sum_abs, Want, BestIdx, BestAbs, Idx: Integer;
  Pos: array[0..15] of Integer;
  NP: Integer;
  V, BestDir, Dir, Cand: Integer;
  Scale, Shift, Add: Integer;
  BestCost, OldErr, NewErr: Int64;

  function dq(L: Integer): Int64;
  begin
    Result := SarInt64(Int64(L) * Scale * 16 + Add, Shift);
  end;

begin
  if S^.pps^.sign_data_hiding_flag = 0 then Exit;
  trafo_size := 1 shl Log2TrafoSize;
  enc_scan_tables(Log2TrafoSize, ScanIdx, scan_x_cg, scan_y_cg, scan_x_off, scan_y_off);
  NGroups := (trafo_size * trafo_size) div 16;
  for I := 0 to NGroups - 1 do
  begin
    x_cg := scan_x_cg[I];
    y_cg := scan_y_cg[I];
    NP := 0;
    first_nz := 16;
    last_nz := -1;
    sum_abs := 0;
    for N := 0 to 15 do
    begin
      x_c := (x_cg shl 2) + scan_x_off[N];
      y_c := (y_cg shl 2) + scan_y_off[N];
      Idx := y_c * trafo_size + x_c;
      if Coeffs[Idx] <> 0 then
      begin
        Pos[NP] := Idx;
        Inc(NP);
        if N < first_nz then first_nz := N;
        if N > last_nz then last_nz := N;
        sum_abs := sum_abs + Abs(Coeffs[Idx]);
      end;
    end;
    if NP = 0 then Continue;
    if last_nz - first_nz < 4 then Continue;

    // the hidden sign belongs to the coefficient at the FIRST significant scan
    // position, which is the last one the decoder processes
    x_c := (x_cg shl 2) + scan_x_off[first_nz];
    y_c := (y_cg shl 2) + scan_y_off[first_nz];
    Want := Ord(Coeffs[y_c * trafo_size + x_c] < 0);
    if (sum_abs and 1) = Want then Continue;

    // Any single-level change fixes the parity; they differ enormously in what
    // they cost. With the pre-quantisation coefficients available, pick the
    // coefficient and direction whose reconstruction moves LEAST relative to
    // the true value -- for a value that barely rounded down, rounding it up
    // instead costs almost nothing. Without them (PreQ = nil, as in the
    // round-trip test), fall back to lowering the largest level.
    if PreQ <> nil then
    begin
      Shift := S^.sps^.bit_depth + Log2TrafoSize - 5;
      Add := 1 shl (Shift - 1);
      Scale := sh_level_scale[QpUsed mod 6] shl (QpUsed div 6);
      BestIdx := -1;
      BestDir := 1;
      BestCost := High(Int64);
      for N := 0 to NP - 1 do
      begin
        V := Coeffs[Pos[N]];
        OldErr := Abs(dq(V) - PreQ[Pos[N]]);
        for Dir := -1 to 1 do
        begin
          if Dir = 0 then Continue;
          Cand := V + Dir;
          if Cand = 0 then Continue;   // must not disturb the significance map
          NewErr := Abs(dq(Cand) - PreQ[Pos[N]]);
          if NewErr - OldErr < BestCost then
          begin
            BestCost := NewErr - OldErr;
            BestIdx := Pos[N];
            BestDir := Dir;
          end;
        end;
      end;
      Coeffs[BestIdx] := Int16(Coeffs[BestIdx] + BestDir);
    end
    else
    begin
      BestIdx := -1;
      BestAbs := 0;
      for N := 0 to NP - 1 do
        if Abs(Coeffs[Pos[N]]) > BestAbs then
        begin
          BestAbs := Abs(Coeffs[Pos[N]]);
          BestIdx := Pos[N];
        end;
      V := Coeffs[BestIdx];
      if Abs(V) > 1 then
      begin
        if V > 0 then Dec(V) else Inc(V);
      end
      else
      begin
        if V > 0 then Inc(V) else Dec(V);
      end;
      Coeffs[BestIdx] := Int16(V);
    end;
  end;
end;

procedure ff_hevc_hls_residual_coding_enc(S: PHEVCContext; var E: TCabacEncoder;
  Coeffs: PInt16; Log2TrafoSize, ScanIdx, CIdx: Integer; TSkip: Integer);
var
  trafo_size, I, M, N, num_coeff, num_last_subset, offs: Integer;
  last_x, last_y, lx, ly, tmpi: Integer;
  x_cg_last_sig, y_cg_last_sig, x_cg, y_cg, x_c, y_c: Integer;
  scan_x_cg, scan_y_cg, scan_x_off, scan_y_off: PByte;
  sig_group: array[0..7, 0..7] of Byte;
  sig_idx: array[0..15] of Byte;
  nb_sig, implicit_non_zero_coeff, prev_sig, ctx_cg: Integer;
  last_scan_pos, n_end, scf_offset: Integer;
  ctx_idx_map_p: PByte;
  c_rice_param, first_greater1_coeff_idx, ctx_set, greater1_ctx, inc_: Integer;
  g1: array[0..7] of Byte;
  AbsLevel, Base: Integer;
  Prefix, Suffix, SuffixLen, PrefixY, SuffixY, SuffixLenY: Integer;
  Levels: array[0..15] of Integer;
begin
  trafo_size := 1 shl Log2TrafoSize;
  // transform_skip_flag opens residual_coding, on exactly the decoder's test
  if (S^.pps^.transform_skip_enabled_flag <> 0) and
     (S^.HEVClc^.cu.cu_transquant_bypass_flag = 0) and
     (Log2TrafoSize <= S^.pps^.log2_max_transform_skip_block_size) then
    cabac_enc_bin(E, CtxPtr(S, elem_offset[TRANSFORM_SKIP_FLAG] + Ord(CIdx <> 0)),
                  TSkip);
  enc_scan_tables(Log2TrafoSize, ScanIdx, scan_x_cg, scan_y_cg, scan_x_off, scan_y_off);

  // locate the last significant coefficient in scan order
  num_coeff := 0;
  last_x := 0;
  last_y := 0;
  for I := (trafo_size * trafo_size) div 16 - 1 downto 0 do
  begin
    for N := 15 downto 0 do
    begin
      x_c := (scan_x_cg[I] shl 2) + scan_x_off[N];
      y_c := (scan_y_cg[I] shl 2) + scan_y_off[N];
      if Coeffs[y_c * trafo_size + x_c] <> 0 then
      begin
        num_coeff := (I shl 4) + N + 1;
        last_x := x_c;
        last_y := y_c;
        Break;
      end;
    end;
    if num_coeff <> 0 then Break;
  end;
  // the caller must not signal cbf for an all-zero block
  if num_coeff = 0 then Exit;

  lx := last_x;
  ly := last_y;
  if ScanIdx = SCAN_VERT then
  begin
    tmpi := ly;
    ly := lx;
    lx := tmpi;
  end;

  split_last_sig(lx, Prefix, Suffix, SuffixLen);
  split_last_sig(ly, PrefixY, SuffixY, SuffixLenY);
  enc_last_sig_prefix(S, E, CIdx, Log2TrafoSize, Prefix, LAST_SIGNIFICANT_COEFF_X_PREFIX);
  enc_last_sig_prefix(S, E, CIdx, Log2TrafoSize, PrefixY, LAST_SIGNIFICANT_COEFF_Y_PREFIX);
  if SuffixLen > 0 then cabac_enc_bypass_bits(E, SuffixLen, Cardinal(Suffix));
  if SuffixLenY > 0 then cabac_enc_bypass_bits(E, SuffixLenY, Cardinal(SuffixY));

  // lx / ly are the values as CODED: for SCAN_VERT the decoder swaps them back
  // right after reading, so the coefficient group indices must come from the
  // true position, not the swapped one.
  x_cg_last_sig := last_x shr 2;
  y_cg_last_sig := last_y shr 2;

  FillChar(sig_group, SizeOf(sig_group), 0);
  num_last_subset := (num_coeff - 1) shr 4;
  greater1_ctx := 1;

  for I := num_last_subset downto 0 do
  begin
    implicit_non_zero_coeff := 0;
    prev_sig := 0;
    offs := I shl 4;
    nb_sig := 0;
    x_cg := scan_x_cg[I];
    y_cg := scan_y_cg[I];

    M := 0;
    for N := 0 to 15 do
      if Coeffs[((y_cg shl 2) + scan_y_off[N]) * trafo_size +
                (x_cg shl 2) + scan_x_off[N]] <> 0 then M := 1;

    if (I < num_last_subset) and (I > 0) then
    begin
      ctx_cg := 0;
      if x_cg < (1 shl (Log2TrafoSize - 2)) - 1 then
        ctx_cg := ctx_cg + sig_group[x_cg + 1][y_cg];
      if y_cg < (1 shl (Log2TrafoSize - 2)) - 1 then
        ctx_cg := ctx_cg + sig_group[x_cg][y_cg + 1];
      sig_group[x_cg][y_cg] := Byte(M);
      inc_ := FFMIN(ctx_cg, 1);
      if CIdx > 0 then inc_ := inc_ + 2;
      cabac_enc_bin(E, CtxPtr(S, elem_offset[SIGNIFICANT_COEFF_GROUP_FLAG] + inc_), M);
      implicit_non_zero_coeff := 1;
    end
    else
      sig_group[x_cg][y_cg] :=
        Byte(Ord(((x_cg = x_cg_last_sig) and (y_cg = y_cg_last_sig)) or
                 ((x_cg = 0) and (y_cg = 0))));

    last_scan_pos := num_coeff - offs - 1;
    if I = num_last_subset then
    begin
      n_end := last_scan_pos - 1;
      sig_idx[0] := Byte(last_scan_pos);
      nb_sig := 1;
    end
    else
      n_end := 15;

    if x_cg < (((1 shl Log2TrafoSize) - 1) shr 2) then
      prev_sig := Ord(sig_group[x_cg + 1][y_cg] <> 0);
    if y_cg < (((1 shl Log2TrafoSize) - 1) shr 2) then
      prev_sig := prev_sig + (Ord(sig_group[x_cg][y_cg + 1] <> 0) shl 1);

    if (sig_group[x_cg][y_cg] <> 0) and (n_end >= 0) then
    begin
      scf_offset := 0;
      if CIdx <> 0 then scf_offset := 27;
      if Log2TrafoSize = 2 then
        ctx_idx_map_p := @sig_ctx_idx_map[0]
      else
      begin
        ctx_idx_map_p := @sig_ctx_idx_map[(prev_sig + 1) shl 4];
        if CIdx = 0 then
        begin
          if (x_cg > 0) or (y_cg > 0) then scf_offset := scf_offset + 3;
          if Log2TrafoSize = 3 then
          begin
            if ScanIdx = SCAN_DIAG then scf_offset := scf_offset + 9
            else scf_offset := scf_offset + 15;
          end
          else
            scf_offset := scf_offset + 21;
        end
        else
        begin
          if Log2TrafoSize = 3 then scf_offset := scf_offset + 9
          else scf_offset := scf_offset + 12;
        end;
      end;

      for N := n_end downto 1 do
      begin
        x_c := scan_x_off[N];
        y_c := scan_y_off[N];
        M := Ord(Coeffs[((y_cg shl 2) + y_c) * trafo_size + (x_cg shl 2) + x_c] <> 0);
        cabac_enc_bin(E, CtxPtr(S, elem_offset[SIGNIFICANT_COEFF_FLAG] +
          ctx_idx_map_p[(y_c shl 2) + x_c] + scf_offset), M);
        if M <> 0 then
        begin
          sig_idx[nb_sig] := Byte(N);
          Inc(nb_sig);
          implicit_non_zero_coeff := 0;
        end;
      end;

      if implicit_non_zero_coeff = 0 then
      begin
        M := Ord(Coeffs[(y_cg shl 2) * trafo_size + (x_cg shl 2)] <> 0);
        if I = 0 then
        begin
          if CIdx = 0 then scf_offset := 0 else scf_offset := 27;
        end
        else
          scf_offset := 2 + scf_offset;
        cabac_enc_bin(E, CtxPtr(S, elem_offset[SIGNIFICANT_COEFF_FLAG] + scf_offset), M);
        if M <> 0 then
        begin
          sig_idx[nb_sig] := 0;
          Inc(nb_sig);
        end;
      end
      else
      begin
        sig_idx[nb_sig] := 0;
        Inc(nb_sig);
      end;
    end;

    n_end := nb_sig;
    if n_end = 0 then Continue;

    for M := 0 to n_end - 1 do
    begin
      N := sig_idx[M];
      Levels[M] := Coeffs[((y_cg shl 2) + scan_y_off[N]) * trafo_size +
                          (x_cg shl 2) + scan_x_off[N]];
    end;

    c_rice_param := 0;
    first_greater1_coeff_idx := -1;
    if (I > 0) and (CIdx = 0) then ctx_set := 2 else ctx_set := 0;
    if (I <> num_last_subset) and (greater1_ctx = 0) then Inc(ctx_set);
    greater1_ctx := 1;

    for M := 0 to FFMIN(n_end, 8) - 1 do
    begin
      g1[M] := Byte(Ord(Abs(Levels[M]) > 1));
      inc_ := (ctx_set shl 2) + greater1_ctx;
      if CIdx > 0 then inc_ := inc_ + 16;
      cabac_enc_bin(E, CtxPtr(S, elem_offset[COEFF_ABS_LEVEL_GREATER1_FLAG] + inc_), g1[M]);
      if g1[M] <> 0 then
      begin
        greater1_ctx := 0;
        if first_greater1_coeff_idx = -1 then first_greater1_coeff_idx := M;
      end
      else if (greater1_ctx > 0) and (greater1_ctx < 3) then
        Inc(greater1_ctx);
    end;

    if first_greater1_coeff_idx <> -1 then
    begin
      M := Ord(Abs(Levels[first_greater1_coeff_idx]) > 2);
      inc_ := ctx_set;
      if CIdx > 0 then inc_ := inc_ + 4;
      cabac_enc_bin(E, CtxPtr(S, elem_offset[COEFF_ABS_LEVEL_GREATER2_FLAG] + inc_), M);
      g1[first_greater1_coeff_idx] := Byte(g1[first_greater1_coeff_idx] + M);
    end;

    // with sign data hiding, the sign of the coefficient at the first
    // significant scan position -- coding index n_end - 1 -- is inferred from
    // the parity that sign_hide_adjust arranged, and is not coded
    if (S^.pps^.sign_data_hiding_flag <> 0) and
       (sig_idx[0] - sig_idx[n_end - 1] >= 4) then
      N := n_end - 2
    else
      N := n_end - 1;
    for M := 0 to N do
      cabac_enc_bypass(E, Ord(Levels[M] < 0));

    for M := 0 to n_end - 1 do
    begin
      AbsLevel := Abs(Levels[M]);
      if M < 8 then
      begin
        Base := 1 + g1[M];
        if ((M = first_greater1_coeff_idx) and (Base = 3)) or
           ((M <> first_greater1_coeff_idx) and (Base = 2)) then
        begin
          enc_coeff_abs_level_remaining(E, AbsLevel - Base, c_rice_param);
          if AbsLevel > (3 shl c_rice_param) then
            c_rice_param := FFMIN(c_rice_param + 1, 4);
        end;
      end
      else
      begin
        enc_coeff_abs_level_remaining(E, AbsLevel - 1, c_rice_param);
        if AbsLevel > (3 shl c_rice_param) then
          c_rice_param := FFMIN(c_rice_param + 1, 4);
      end;
    end;
  end;
end;
