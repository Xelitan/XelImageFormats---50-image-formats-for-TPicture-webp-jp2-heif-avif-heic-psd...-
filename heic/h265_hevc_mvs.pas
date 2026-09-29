// BPG decoder -- Free Pascal port of libbpg 0.9.8
// Motion-vector prediction: spatial/temporal merge candidates and AMVP.
// Corresponds to: libavcodec/hevc_mvs.c
//
// Only reachable for animated BPG (inter-coded frames).
// The ff_thread_await_progress() calls are dropped: libbpg is single-threaded.
unit h265_hevc_mvs;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  h265_common, h265_hevc_defs, h265_hevc_refs;

procedure ff_hevc_set_neighbour_available(S: PHEVCContext; X0, Y0, nPbW, nPbH: Integer);
procedure ff_hevc_luma_mv_merge_mode(S: PHEVCContext; X0, Y0, nPbW, nPbH,
  Log2CbSize, PartIdx, MergeIdx: Integer; MV: PMvField);
procedure ff_hevc_luma_mv_mvp_mode(S: PHEVCContext; X0, Y0, nPbW, nPbH,
  Log2CbSize, PartIdx, MergeIdx: Integer; MV: PMvField; MvpLxFlag, LX: Integer);

implementation

const
  l0_l1_cand_idx: array[0..11, 0..1] of Byte = (
    (0, 1), (1, 0), (0, 2), (2, 0), (1, 2), (2, 1),
    (0, 3), (3, 0), (1, 3), (3, 1), (2, 3), (3, 2)
  );

function av_clip_int8_c(A: Integer): Integer; inline;
begin
  if ((A + $80) and (not $FF)) <> 0 then
  begin
    if A < 0 then Result := -128 else Result := 127;
  end
  else
    Result := A;
end;

function av_clip_int16_c(A: Integer): Integer; inline;
begin
  if ((A + $8000) and (not $FFFF)) <> 0 then
  begin
    if A < 0 then Result := -32768 else Result := 32767;
  end
  else
    Result := A;
end;

procedure ff_hevc_set_neighbour_available(S: PHEVCContext; X0, Y0, nPbW, nPbH: Integer);
var
  LC: PHEVCLocalContext;
  x0b, y0b: Integer;
begin
  LC := S^.HEVClc;
  x0b := X0 and ((1 shl S^.sps^.log2_ctb_size) - 1);
  y0b := Y0 and ((1 shl S^.sps^.log2_ctb_size) - 1);
  LC^.na.cand_up := Ord((LC^.ctb_up_flag <> 0) or (y0b <> 0));
  LC^.na.cand_left := Ord((LC^.ctb_left_flag <> 0) or (x0b <> 0));
  if (x0b = 0) and (y0b = 0) then
    LC^.na.cand_up_left := LC^.ctb_up_left_flag
  else
    LC^.na.cand_up_left := Ord((LC^.na.cand_left <> 0) and (LC^.na.cand_up <> 0));
  if (x0b + nPbW) = (1 shl S^.sps^.log2_ctb_size) then
    LC^.na.cand_up_right_sap := Ord((LC^.ctb_up_right_flag <> 0) and (y0b = 0))
  else
    LC^.na.cand_up_right_sap := LC^.na.cand_up;
  LC^.na.cand_up_right :=
    Ord((LC^.na.cand_up_right_sap <> 0) and ((X0 + nPbW) < LC^.end_of_tiles_x));
  if (Y0 + nPbH) >= LC^.end_of_tiles_y then
    LC^.na.cand_bottom_left := 0
  else
    LC^.na.cand_bottom_left := LC^.na.cand_left;
end;

function z_scan_block_avail(S: PHEVCContext; XCurr, YCurr, XN, YN: Integer): Integer;
var
  xCurr_ctb, yCurr_ctb, xN_ctb, yN_ctb, Curr, N, TbMask2: Integer;
begin
  xCurr_ctb := XCurr shr S^.sps^.log2_ctb_size;
  yCurr_ctb := YCurr shr S^.sps^.log2_ctb_size;
  xN_ctb := XN shr S^.sps^.log2_ctb_size;
  yN_ctb := YN shr S^.sps^.log2_ctb_size;
  if (yN_ctb < yCurr_ctb) or (xN_ctb < xCurr_ctb) then
    Result := 1
  else
  begin
    TbMask2 := S^.sps^.tb_mask + 2;
    Curr := S^.pps^.min_tb_addr_zs[
      ((YCurr shr S^.sps^.log2_min_tb_size) and S^.sps^.tb_mask) * TbMask2 +
      ((XCurr shr S^.sps^.log2_min_tb_size) and S^.sps^.tb_mask)];
    N := S^.pps^.min_tb_addr_zs[
      ((YN shr S^.sps^.log2_min_tb_size) and S^.sps^.tb_mask) * TbMask2 +
      ((XN shr S^.sps^.log2_min_tb_size) and S^.sps^.tb_mask)];
    Result := Ord(N <= Curr);
  end;
end;

function is_diff_mer(S: PHEVCContext; XN, YN, XP, YP: Integer): Boolean; inline;
var
  plevel: Byte;
begin
  plevel := S^.pps^.log2_parallel_merge_level;
  Result := ((XN shr plevel) = (XP shr plevel)) and ((YN shr plevel) = (YP shr plevel));
end;

function MvEq(const A, B: TMv): Boolean; inline;
begin
  Result := (A.x = B.x) and (A.y = B.y);
end;

function compare_mv_ref_idx(const A, B: TMvField): Boolean;
var
  a_pf, b_pf: Integer;
begin
  a_pf := A.pred_flag;
  b_pf := B.pred_flag;
  if a_pf = b_pf then
  begin
    if a_pf = PF_BI then
      Exit((A.ref_idx[0] = B.ref_idx[0]) and MvEq(A.mv[0], B.mv[0]) and
           (A.ref_idx[1] = B.ref_idx[1]) and MvEq(A.mv[1], B.mv[1]))
    else if a_pf = PF_L0 then
      Exit((A.ref_idx[0] = B.ref_idx[0]) and MvEq(A.mv[0], B.mv[0]))
    else if a_pf = PF_L1 then
      Exit((A.ref_idx[1] = B.ref_idx[1]) and MvEq(A.mv[1], B.mv[1]));
  end;
  Result := False;
end;

procedure mv_scale(Dst, Src: PMv; Td, Tb: Integer);
var
  Tx, scale_factor: Integer;
begin
  Td := av_clip_int8_c(Td);
  Tb := av_clip_int8_c(Tb);
  Tx := ($4000 + Abs(Td div 2)) div Td;
  scale_factor := av_clip_c(SarLongint(Tb * Tx + 32, 6), -4096, 4095);
  Dst^.x := Int16(av_clip_int16_c(SarLongint(scale_factor * Src^.x + 127 +
    Ord(scale_factor * Src^.x < 0), 8)));
  Dst^.y := Int16(av_clip_int16_c(SarLongint(scale_factor * Src^.y + 127 +
    Ord(scale_factor * Src^.y < 0), 8)));
end;

function check_mvset(MvLXCol, MvCol: PMv; ColPic, Poc: Integer;
  RefPicList_: PRefPicList; X, RefIdxLx: Integer;
  RefPicListCol: PRefPicList; ListCol, RefIdxCol: Integer): Integer;
var
  cur_lt, col_lt, col_poc_diff, cur_poc_diff: Integer;
begin
  cur_lt := RefPicList_[X].isLongTerm[RefIdxLx];
  col_lt := RefPicListCol[ListCol].isLongTerm[RefIdxCol];
  if cur_lt <> col_lt then
  begin
    MvLXCol^.x := 0;
    MvLXCol^.y := 0;
    Exit(0);
  end;
  col_poc_diff := ColPic - RefPicListCol[ListCol].List[RefIdxCol];
  cur_poc_diff := Poc - RefPicList_[X].List[RefIdxLx];
  if (cur_lt <> 0) or (col_poc_diff = cur_poc_diff) or (col_poc_diff = 0) then
  begin
    MvLXCol^.x := MvCol^.x;
    MvLXCol^.y := MvCol^.y;
  end
  else
    mv_scale(MvLXCol, MvCol, col_poc_diff, cur_poc_diff);
  Result := 1;
end;

function derive_temporal_colocated_mvs(S: PHEVCContext; const TempCol: TMvField;
  RefIdxLx: Integer; MvLXCol: PMv; X, ColPic: Integer;
  RefPicListCol: PRefPicList): Integer;
var
  RefPicList_: PRefPicList;
  check_diffpicount, I, J: Integer;
  TC: TMvField;
begin
  RefPicList_ := S^.ref^.refPicList;
  TC := TempCol;
  if TC.pred_flag = PF_INTRA then Exit(0);
  if (TC.pred_flag and PF_L0) = 0 then
    Exit(check_mvset(MvLXCol, @TC.mv[1], ColPic, S^.poc, RefPicList_, X, RefIdxLx,
      RefPicListCol, 1, TC.ref_idx[1]))
  else if TC.pred_flag = PF_L0 then
    Exit(check_mvset(MvLXCol, @TC.mv[0], ColPic, S^.poc, RefPicList_, X, RefIdxLx,
      RefPicListCol, 0, TC.ref_idx[0]))
  else if TC.pred_flag = PF_BI then
  begin
    check_diffpicount := 0;
    for J := 0 to 1 do
      for I := 0 to RefPicList_[J].nb_refs - 1 do
        if RefPicList_[J].List[I] > S^.poc then
        begin
          Inc(check_diffpicount);
          Break;
        end;
    if check_diffpicount = 0 then
    begin
      if X = 0 then
        Exit(check_mvset(MvLXCol, @TC.mv[0], ColPic, S^.poc, RefPicList_, X, RefIdxLx,
          RefPicListCol, 0, TC.ref_idx[0]))
      else
        Exit(check_mvset(MvLXCol, @TC.mv[1], ColPic, S^.poc, RefPicList_, X, RefIdxLx,
          RefPicListCol, 1, TC.ref_idx[1]));
    end
    else
    begin
      if S^.sh.collocated_list = 1 then
        Exit(check_mvset(MvLXCol, @TC.mv[0], ColPic, S^.poc, RefPicList_, X, RefIdxLx,
          RefPicListCol, 0, TC.ref_idx[0]))
      else
        Exit(check_mvset(MvLXCol, @TC.mv[1], ColPic, S^.poc, RefPicList_, X, RefIdxLx,
          RefPicListCol, 1, TC.ref_idx[1]));
    end;
  end;
  Result := 0;
end;

function temporal_luma_motion_vector(S: PHEVCContext; X0, Y0, nPbW, nPbH,
  RefIdxLx: Integer; MvLXCol: PMv; X: Integer): Integer;
var
  tab_mvf: PMvField;
  temp_col: TMvField;
  Xc, Yc, x_pu, y_pu, min_pu_width, availableFlagLXCol, ColPic: Integer;
  Ref: PHEVCFrame;
begin
  min_pu_width := S^.sps^.min_pu_width;
  availableFlagLXCol := 0;
  Ref := S^.ref^.collocated_ref;
  if Ref = nil then
  begin
    FillChar(MvLXCol^, SizeOf(TMv), 0);
    Exit(0);
  end;
  tab_mvf := Ref^.tab_mvf;
  ColPic := Ref^.poc;
  Xc := X0 + nPbW;
  Yc := Y0 + nPbH;
  if (tab_mvf <> nil) and
     ((Y0 shr S^.sps^.log2_ctb_size) = (Yc shr S^.sps^.log2_ctb_size)) and
     (Yc < S^.sps^.height) and (Xc < S^.sps^.width) then
  begin
    Xc := Xc and (not 15);
    Yc := Yc and (not 15);
    x_pu := Xc shr S^.sps^.log2_min_pu_size;
    y_pu := Yc shr S^.sps^.log2_min_pu_size;
    temp_col := tab_mvf[y_pu * min_pu_width + x_pu];
    availableFlagLXCol := derive_temporal_colocated_mvs(S, temp_col, RefIdxLx,
      MvLXCol, X, ColPic, ff_hevc_get_ref_list(S, Ref, Xc, Yc));
  end;
  if (tab_mvf <> nil) and (availableFlagLXCol = 0) then
  begin
    Xc := X0 + (nPbW shr 1);
    Yc := Y0 + (nPbH shr 1);
    Xc := Xc and (not 15);
    Yc := Yc and (not 15);
    x_pu := Xc shr S^.sps^.log2_min_pu_size;
    y_pu := Yc shr S^.sps^.log2_min_pu_size;
    temp_col := tab_mvf[y_pu * min_pu_width + x_pu];
    availableFlagLXCol := derive_temporal_colocated_mvs(S, temp_col, RefIdxLx,
      MvLXCol, X, ColPic, ff_hevc_get_ref_list(S, Ref, Xc, Yc));
  end;
  Result := availableFlagLXCol;
end;

type
  TMergeCandList = array[0..4] of TMvField;

procedure derive_spatial_merge_candidates(S: PHEVCContext; X0, Y0, nPbW, nPbH,
  Log2CbSize, SingleMCLFlag, PartIdx, MergeIdx: Integer;
  var MergeCandList: TMergeCandList);
var
  LC: PHEVCLocalContext;
  RefPicList_: PRefPicList;
  tab_mvf: PMvField;
  min_pu_width, lps: Integer;
  cand_bottom_left, cand_left, cand_up_left, cand_up, cand_up_right: Integer;
  xA1, yA1, xB1, yB1, xB0, yB0, xA0, yA0, xB2, yB2: Integer;
  nb_refs, zero_idx, nb_merge_cand, nb_orig_merge_cand: Integer;
  is_available_a0, is_available_a1, is_available_b0, is_available_b1, is_available_b2: Integer;
  mv_l0_col, mv_l1_col: TMv;
  available_l0, available_l1, comb_idx, l0_cand_idx, l1_cand_idx: Integer;
  l0_cand, l1_cand: TMvField;

  function MVF(Xp, Yp: Integer): PMvField; inline;
  begin
    Result := @tab_mvf[(Yp shr lps) * min_pu_width + (Xp shr lps)];
  end;

begin
  LC := S^.HEVClc;
  RefPicList_ := S^.ref^.refPicList;
  tab_mvf := S^.ref^.tab_mvf;
  min_pu_width := S^.sps^.min_pu_width;
  lps := S^.sps^.log2_min_pu_size;
  cand_bottom_left := LC^.na.cand_bottom_left;
  cand_left := LC^.na.cand_left;
  cand_up_left := LC^.na.cand_up_left;
  cand_up := LC^.na.cand_up;
  cand_up_right := LC^.na.cand_up_right_sap;
  xA1 := X0 - 1;             yA1 := Y0 + nPbH - 1;
  xB1 := X0 + nPbW - 1;      yB1 := Y0 - 1;
  xB0 := X0 + nPbW;          yB0 := Y0 - 1;
  xA0 := X0 - 1;             yA0 := Y0 + nPbH;
  xB2 := X0 - 1;             yB2 := Y0 - 1;

  if S^.sh.slice_type = P_SLICE then
    nb_refs := Integer(S^.sh.nb_refs[0])
  else
    nb_refs := FFMIN(Integer(S^.sh.nb_refs[0]), Integer(S^.sh.nb_refs[1]));
  zero_idx := 0;
  nb_merge_cand := 0;
  is_available_a1 := 0;
  is_available_b1 := 0;

  // NOTE: && binds tighter than || in C, so the whole first conjunction is
  // ORed with is_diff_mer(). Reproduced as written.
  if (((SingleMCLFlag = 0) and (PartIdx = 1) and
       ((LC^.cu.part_mode = PART_Nx2N) or (LC^.cu.part_mode = PART_nLx2N) or
        (LC^.cu.part_mode = PART_nRx2N)))) or is_diff_mer(S, xA1, yA1, X0, Y0) then
    is_available_a1 := 0
  else
  begin
    is_available_a1 := Ord((cand_left <> 0) and (MVF(xA1, yA1)^.pred_flag <> PF_INTRA));
    if is_available_a1 <> 0 then
    begin
      MergeCandList[nb_merge_cand] := MVF(xA1, yA1)^;
      if MergeIdx = 0 then Exit;
      Inc(nb_merge_cand);
    end;
  end;

  if (((SingleMCLFlag = 0) and (PartIdx = 1) and
       ((LC^.cu.part_mode = PART_2NxN) or (LC^.cu.part_mode = PART_2NxnU) or
        (LC^.cu.part_mode = PART_2NxnD)))) or is_diff_mer(S, xB1, yB1, X0, Y0) then
    is_available_b1 := 0
  else
  begin
    is_available_b1 := Ord((cand_up <> 0) and (MVF(xB1, yB1)^.pred_flag <> PF_INTRA));
    if (is_available_b1 <> 0) and
       not ((is_available_a1 <> 0) and compare_mv_ref_idx(MVF(xB1, yB1)^, MVF(xA1, yA1)^)) then
    begin
      MergeCandList[nb_merge_cand] := MVF(xB1, yB1)^;
      if MergeIdx = nb_merge_cand then Exit;
      Inc(nb_merge_cand);
    end;
  end;

  is_available_b0 := Ord((cand_up_right <> 0) and (MVF(xB0, yB0)^.pred_flag <> PF_INTRA) and
    (xB0 < S^.sps^.width) and (z_scan_block_avail(S, X0, Y0, xB0, yB0) <> 0) and
    not is_diff_mer(S, xB0, yB0, X0, Y0));
  if (is_available_b0 <> 0) and
     not ((is_available_b1 <> 0) and compare_mv_ref_idx(MVF(xB0, yB0)^, MVF(xB1, yB1)^)) then
  begin
    MergeCandList[nb_merge_cand] := MVF(xB0, yB0)^;
    if MergeIdx = nb_merge_cand then Exit;
    Inc(nb_merge_cand);
  end;

  is_available_a0 := Ord((cand_bottom_left <> 0) and (MVF(xA0, yA0)^.pred_flag <> PF_INTRA) and
    (yA0 < S^.sps^.height) and (z_scan_block_avail(S, X0, Y0, xA0, yA0) <> 0) and
    not is_diff_mer(S, xA0, yA0, X0, Y0));
  if (is_available_a0 <> 0) and
     not ((is_available_a1 <> 0) and compare_mv_ref_idx(MVF(xA0, yA0)^, MVF(xA1, yA1)^)) then
  begin
    MergeCandList[nb_merge_cand] := MVF(xA0, yA0)^;
    if MergeIdx = nb_merge_cand then Exit;
    Inc(nb_merge_cand);
  end;

  is_available_b2 := Ord((cand_up_left <> 0) and (MVF(xB2, yB2)^.pred_flag <> PF_INTRA) and
    not is_diff_mer(S, xB2, yB2, X0, Y0));
  if (is_available_b2 <> 0) and
     not ((is_available_a1 <> 0) and compare_mv_ref_idx(MVF(xB2, yB2)^, MVF(xA1, yA1)^)) and
     not ((is_available_b1 <> 0) and compare_mv_ref_idx(MVF(xB2, yB2)^, MVF(xB1, yB1)^)) and
     (nb_merge_cand <> 4) then
  begin
    MergeCandList[nb_merge_cand] := MVF(xB2, yB2)^;
    if MergeIdx = nb_merge_cand then Exit;
    Inc(nb_merge_cand);
  end;

  if (S^.sh.slice_temporal_mvp_enabled_flag <> 0) and
     (Cardinal(nb_merge_cand) < S^.sh.max_num_merge_cand) then
  begin
    FillChar(mv_l0_col, SizeOf(TMv), 0);
    FillChar(mv_l1_col, SizeOf(TMv), 0);
    available_l0 := temporal_luma_motion_vector(S, X0, Y0, nPbW, nPbH, 0, @mv_l0_col, 0);
    if S^.sh.slice_type = B_SLICE then
      available_l1 := temporal_luma_motion_vector(S, X0, Y0, nPbW, nPbH, 0, @mv_l1_col, 1)
    else
      available_l1 := 0;
    if (available_l0 <> 0) or (available_l1 <> 0) then
    begin
      MergeCandList[nb_merge_cand].pred_flag := Int8(available_l0 + (available_l1 shl 1));
      MergeCandList[nb_merge_cand].ref_idx[0] := 0;
      MergeCandList[nb_merge_cand].ref_idx[1] := 0;
      MergeCandList[nb_merge_cand].mv[0] := mv_l0_col;
      MergeCandList[nb_merge_cand].mv[1] := mv_l1_col;
      if MergeIdx = nb_merge_cand then Exit;
      Inc(nb_merge_cand);
    end;
  end;

  nb_orig_merge_cand := nb_merge_cand;
  if (S^.sh.slice_type = B_SLICE) and (nb_orig_merge_cand > 1) and
     (Cardinal(nb_orig_merge_cand) < S^.sh.max_num_merge_cand) then
  begin
    comb_idx := 0;
    while (Cardinal(nb_merge_cand) < S^.sh.max_num_merge_cand) and
          (comb_idx < nb_orig_merge_cand * (nb_orig_merge_cand - 1)) do
    begin
      l0_cand_idx := l0_l1_cand_idx[comb_idx][0];
      l1_cand_idx := l0_l1_cand_idx[comb_idx][1];
      l0_cand := MergeCandList[l0_cand_idx];
      l1_cand := MergeCandList[l1_cand_idx];
      if ((l0_cand.pred_flag and PF_L0) <> 0) and ((l1_cand.pred_flag and PF_L1) <> 0) and
         ((RefPicList_[0].List[l0_cand.ref_idx[0]] <> RefPicList_[1].List[l1_cand.ref_idx[1]]) or
          not MvEq(l0_cand.mv[0], l1_cand.mv[1])) then
      begin
        MergeCandList[nb_merge_cand].ref_idx[0] := l0_cand.ref_idx[0];
        MergeCandList[nb_merge_cand].ref_idx[1] := l1_cand.ref_idx[1];
        MergeCandList[nb_merge_cand].pred_flag := PF_BI;
        MergeCandList[nb_merge_cand].mv[0] := l0_cand.mv[0];
        MergeCandList[nb_merge_cand].mv[1] := l1_cand.mv[1];
        if MergeIdx = nb_merge_cand then Exit;
        Inc(nb_merge_cand);
      end;
      Inc(comb_idx);
    end;
  end;

  while Cardinal(nb_merge_cand) < S^.sh.max_num_merge_cand do
  begin
    MergeCandList[nb_merge_cand].pred_flag :=
      Int8(PF_L0 + (Ord(S^.sh.slice_type = B_SLICE) shl 1));
    MergeCandList[nb_merge_cand].mv[0].x := 0;
    MergeCandList[nb_merge_cand].mv[0].y := 0;
    MergeCandList[nb_merge_cand].mv[1].x := 0;
    MergeCandList[nb_merge_cand].mv[1].y := 0;
    if zero_idx < nb_refs then
    begin
      MergeCandList[nb_merge_cand].ref_idx[0] := Int8(zero_idx);
      MergeCandList[nb_merge_cand].ref_idx[1] := Int8(zero_idx);
    end
    else
    begin
      MergeCandList[nb_merge_cand].ref_idx[0] := 0;
      MergeCandList[nb_merge_cand].ref_idx[1] := 0;
    end;
    if MergeIdx = nb_merge_cand then Exit;
    Inc(nb_merge_cand);
    Inc(zero_idx);
  end;
end;

procedure ff_hevc_luma_mv_merge_mode(S: PHEVCContext; X0, Y0, nPbW, nPbH,
  Log2CbSize, PartIdx, MergeIdx: Integer; MV: PMvField);
var
  SingleMCLFlag, nCS, nPbW2, nPbH2: Integer;
  MergeCandList: TMergeCandList;
  LC: PHEVCLocalContext;
begin
  SingleMCLFlag := 0;
  nCS := 1 shl Log2CbSize;
  FillChar(MergeCandList, SizeOf(MergeCandList), 0);
  nPbW2 := nPbW;
  nPbH2 := nPbH;
  LC := S^.HEVClc;
  if (S^.pps^.log2_parallel_merge_level > 2) and (nCS = 8) then
  begin
    SingleMCLFlag := 1;
    X0 := LC^.cu.x;
    Y0 := LC^.cu.y;
    nPbW := nCS;
    nPbH := nCS;
    PartIdx := 0;
  end;
  ff_hevc_set_neighbour_available(S, X0, Y0, nPbW, nPbH);
  derive_spatial_merge_candidates(S, X0, Y0, nPbW, nPbH, Log2CbSize,
    SingleMCLFlag, PartIdx, MergeIdx, MergeCandList);
  if (MergeCandList[MergeIdx].pred_flag = PF_BI) and ((nPbW2 + nPbH2) = 12) then
    MergeCandList[MergeIdx].pred_flag := PF_L0;
  MV^ := MergeCandList[MergeIdx];
end;

procedure dist_scale(S: PHEVCContext; MV: PMv; MinPuWidth, X, Y, EList,
  RefIdxCurr, RefIdx: Integer);
var
  RefPicList_: PRefPicList;
  tab_mvf: PMvField;
  ref_pic_elist, ref_pic_curr, poc_diff: Integer;
begin
  RefPicList_ := S^.ref^.refPicList;
  tab_mvf := S^.ref^.tab_mvf;
  ref_pic_elist := RefPicList_[EList].List[tab_mvf[Y * MinPuWidth + X].ref_idx[EList]];
  ref_pic_curr := RefPicList_[RefIdxCurr].List[RefIdx];
  if ref_pic_elist <> ref_pic_curr then
  begin
    poc_diff := S^.poc - ref_pic_elist;
    if poc_diff = 0 then poc_diff := 1;
    mv_scale(MV, MV, poc_diff, S^.poc - ref_pic_curr);
  end;
end;

function mv_mp_mode_mx(S: PHEVCContext; X, Y, PredFlagIndex: Integer; MV: PMv;
  RefIdxCurr, RefIdx: Integer): Integer;
var
  tab_mvf: PMvField;
  min_pu_width: Integer;
  RefPicList_: PRefPicList;
begin
  tab_mvf := S^.ref^.tab_mvf;
  min_pu_width := S^.sps^.min_pu_width;
  RefPicList_ := S^.ref^.refPicList;
  if ((tab_mvf[Y * min_pu_width + X].pred_flag and (1 shl PredFlagIndex)) <> 0) and
     (RefPicList_[PredFlagIndex].List[tab_mvf[Y * min_pu_width + X].ref_idx[PredFlagIndex]] =
      RefPicList_[RefIdxCurr].List[RefIdx]) then
  begin
    MV^ := tab_mvf[Y * min_pu_width + X].mv[PredFlagIndex];
    Exit(1);
  end;
  Result := 0;
end;

function mv_mp_mode_mx_lt(S: PHEVCContext; X, Y, PredFlagIndex: Integer; MV: PMv;
  RefIdxCurr, RefIdx: Integer): Integer;
var
  tab_mvf: PMvField;
  min_pu_width, currIsLongTerm, colIsLongTerm: Integer;
  RefPicList_: PRefPicList;
begin
  tab_mvf := S^.ref^.tab_mvf;
  min_pu_width := S^.sps^.min_pu_width;
  RefPicList_ := S^.ref^.refPicList;
  if (tab_mvf[Y * min_pu_width + X].pred_flag and (1 shl PredFlagIndex)) <> 0 then
  begin
    currIsLongTerm := RefPicList_[RefIdxCurr].isLongTerm[RefIdx];
    colIsLongTerm := RefPicList_[PredFlagIndex].isLongTerm[
      tab_mvf[Y * min_pu_width + X].ref_idx[PredFlagIndex]];
    if colIsLongTerm = currIsLongTerm then
    begin
      MV^ := tab_mvf[Y * min_pu_width + X].mv[PredFlagIndex];
      if currIsLongTerm = 0 then
        dist_scale(S, MV, min_pu_width, X, Y, PredFlagIndex, RefIdxCurr, RefIdx);
      Exit(1);
    end;
  end;
  Result := 0;
end;

procedure ff_hevc_luma_mv_mvp_mode(S: PHEVCContext; X0, Y0, nPbW, nPbH,
  Log2CbSize, PartIdx, MergeIdx: Integer; MV: PMvField; MvpLxFlag, LX: Integer);
var
  LC: PHEVCLocalContext;
  tab_mvf: PMvField;
  isScaledFlag_L0, availableFlagLXA0, availableFlagLXB0, numMVPCandLX: Integer;
  min_pu_width, lps: Integer;
  xA0, yA0, xA1, yA1, xB0, yB0, xB1, yB1, xB2, yB2: Integer;
  is_available_a0, is_available_a1, is_available_b0, is_available_b1, is_available_b2: Integer;
  mvpcand_list: array[0..1] of TMv;
  mxA, mxB, mv_col: TMv;
  ref_idx_curr, ref_idx, pred_flag_index_l0, pred_flag_index_l1: Integer;
  cand_bottom_left, cand_left, cand_up_left, cand_up, cand_up_right: Integer;
  available_col: Integer;

  function PF(V: Integer): Integer; inline;
  begin
    Result := V shr lps;
  end;

  function IsIntraAt(Xp, Yp: Integer): Boolean; inline;
  begin
    Result := tab_mvf[(Yp shr lps) * min_pu_width + (Xp shr lps)].pred_flag = PF_INTRA;
  end;

label
  b_candidates, scalef;
begin
  LC := S^.HEVClc;
  tab_mvf := S^.ref^.tab_mvf;
  isScaledFlag_L0 := 0;
  availableFlagLXA0 := 1;
  availableFlagLXB0 := 1;
  numMVPCandLX := 0;
  min_pu_width := S^.sps^.min_pu_width;
  lps := S^.sps^.log2_min_pu_size;
  FillChar(mvpcand_list, SizeOf(mvpcand_list), 0);
  FillChar(mxA, SizeOf(mxA), 0);
  FillChar(mxB, SizeOf(mxB), 0);
  cand_bottom_left := LC^.na.cand_bottom_left;
  cand_left := LC^.na.cand_left;
  cand_up_left := LC^.na.cand_up_left;
  cand_up := LC^.na.cand_up;
  cand_up_right := LC^.na.cand_up_right_sap;
  ref_idx_curr := LX;
  ref_idx := MV^.ref_idx[LX];
  pred_flag_index_l0 := LX;
  pred_flag_index_l1 := Ord(LX = 0);

  xA0 := X0 - 1;
  yA0 := Y0 + nPbH;
  is_available_a0 := Ord((cand_bottom_left <> 0) and not IsIntraAt(xA0, yA0) and
    (yA0 < S^.sps^.height) and (z_scan_block_avail(S, X0, Y0, xA0, yA0) <> 0));
  xA1 := X0 - 1;
  yA1 := Y0 + nPbH - 1;
  is_available_a1 := Ord((cand_left <> 0) and not IsIntraAt(xA1, yA1));
  if (is_available_a0 <> 0) or (is_available_a1 <> 0) then isScaledFlag_L0 := 1;

  if is_available_a0 <> 0 then
  begin
    if mv_mp_mode_mx(S, PF(xA0), PF(yA0), pred_flag_index_l0, @mxA, ref_idx_curr, ref_idx) <> 0 then goto b_candidates;
    if mv_mp_mode_mx(S, PF(xA0), PF(yA0), pred_flag_index_l1, @mxA, ref_idx_curr, ref_idx) <> 0 then goto b_candidates;
  end;
  if is_available_a1 <> 0 then
  begin
    if mv_mp_mode_mx(S, PF(xA1), PF(yA1), pred_flag_index_l0, @mxA, ref_idx_curr, ref_idx) <> 0 then goto b_candidates;
    if mv_mp_mode_mx(S, PF(xA1), PF(yA1), pred_flag_index_l1, @mxA, ref_idx_curr, ref_idx) <> 0 then goto b_candidates;
  end;
  if is_available_a0 <> 0 then
  begin
    if mv_mp_mode_mx_lt(S, PF(xA0), PF(yA0), pred_flag_index_l0, @mxA, ref_idx_curr, ref_idx) <> 0 then goto b_candidates;
    if mv_mp_mode_mx_lt(S, PF(xA0), PF(yA0), pred_flag_index_l1, @mxA, ref_idx_curr, ref_idx) <> 0 then goto b_candidates;
  end;
  if is_available_a1 <> 0 then
  begin
    if mv_mp_mode_mx_lt(S, PF(xA1), PF(yA1), pred_flag_index_l0, @mxA, ref_idx_curr, ref_idx) <> 0 then goto b_candidates;
    if mv_mp_mode_mx_lt(S, PF(xA1), PF(yA1), pred_flag_index_l1, @mxA, ref_idx_curr, ref_idx) <> 0 then goto b_candidates;
  end;
  availableFlagLXA0 := 0;

b_candidates:
  xB0 := X0 + nPbW;
  yB0 := Y0 - 1;
  is_available_b0 := Ord((cand_up_right <> 0) and not IsIntraAt(xB0, yB0) and
    (xB0 < S^.sps^.width) and (z_scan_block_avail(S, X0, Y0, xB0, yB0) <> 0));
  xB1 := X0 + nPbW - 1;
  yB1 := Y0 - 1;
  is_available_b1 := Ord((cand_up <> 0) and not IsIntraAt(xB1, yB1));
  xB2 := X0 - 1;
  yB2 := Y0 - 1;
  is_available_b2 := Ord((cand_up_left <> 0) and not IsIntraAt(xB2, yB2));

  if is_available_b0 <> 0 then
  begin
    if mv_mp_mode_mx(S, PF(xB0), PF(yB0), pred_flag_index_l0, @mxB, ref_idx_curr, ref_idx) <> 0 then goto scalef;
    if mv_mp_mode_mx(S, PF(xB0), PF(yB0), pred_flag_index_l1, @mxB, ref_idx_curr, ref_idx) <> 0 then goto scalef;
  end;
  if is_available_b1 <> 0 then
  begin
    if mv_mp_mode_mx(S, PF(xB1), PF(yB1), pred_flag_index_l0, @mxB, ref_idx_curr, ref_idx) <> 0 then goto scalef;
    if mv_mp_mode_mx(S, PF(xB1), PF(yB1), pred_flag_index_l1, @mxB, ref_idx_curr, ref_idx) <> 0 then goto scalef;
  end;
  if is_available_b2 <> 0 then
  begin
    if mv_mp_mode_mx(S, PF(xB2), PF(yB2), pred_flag_index_l0, @mxB, ref_idx_curr, ref_idx) <> 0 then goto scalef;
    if mv_mp_mode_mx(S, PF(xB2), PF(yB2), pred_flag_index_l1, @mxB, ref_idx_curr, ref_idx) <> 0 then goto scalef;
  end;
  availableFlagLXB0 := 0;

scalef:
  if isScaledFlag_L0 = 0 then
  begin
    if availableFlagLXB0 <> 0 then
    begin
      availableFlagLXA0 := 1;
      mxA := mxB;
    end;
    availableFlagLXB0 := 0;
    if is_available_b0 <> 0 then
    begin
      availableFlagLXB0 := mv_mp_mode_mx_lt(S, PF(xB0), PF(yB0), pred_flag_index_l0, @mxB, ref_idx_curr, ref_idx);
      if availableFlagLXB0 = 0 then
        availableFlagLXB0 := mv_mp_mode_mx_lt(S, PF(xB0), PF(yB0), pred_flag_index_l1, @mxB, ref_idx_curr, ref_idx);
    end;
    if (is_available_b1 <> 0) and (availableFlagLXB0 = 0) then
    begin
      availableFlagLXB0 := mv_mp_mode_mx_lt(S, PF(xB1), PF(yB1), pred_flag_index_l0, @mxB, ref_idx_curr, ref_idx);
      if availableFlagLXB0 = 0 then
        availableFlagLXB0 := mv_mp_mode_mx_lt(S, PF(xB1), PF(yB1), pred_flag_index_l1, @mxB, ref_idx_curr, ref_idx);
    end;
    if (is_available_b2 <> 0) and (availableFlagLXB0 = 0) then
    begin
      availableFlagLXB0 := mv_mp_mode_mx_lt(S, PF(xB2), PF(yB2), pred_flag_index_l0, @mxB, ref_idx_curr, ref_idx);
      if availableFlagLXB0 = 0 then
        availableFlagLXB0 := mv_mp_mode_mx_lt(S, PF(xB2), PF(yB2), pred_flag_index_l1, @mxB, ref_idx_curr, ref_idx);
    end;
  end;

  if availableFlagLXA0 <> 0 then
  begin
    mvpcand_list[numMVPCandLX] := mxA;
    Inc(numMVPCandLX);
  end;
  if (availableFlagLXB0 <> 0) and
     ((availableFlagLXA0 = 0) or (mxA.x <> mxB.x) or (mxA.y <> mxB.y)) then
  begin
    mvpcand_list[numMVPCandLX] := mxB;
    Inc(numMVPCandLX);
  end;
  if (numMVPCandLX < 2) and (S^.sh.slice_temporal_mvp_enabled_flag <> 0) and
     (MvpLxFlag = numMVPCandLX) then
  begin
    FillChar(mv_col, SizeOf(mv_col), 0);
    available_col := temporal_luma_motion_vector(S, X0, Y0, nPbW, nPbH, ref_idx, @mv_col, LX);
    if available_col <> 0 then
    begin
      mvpcand_list[numMVPCandLX] := mv_col;
      Inc(numMVPCandLX);
    end;
  end;
  MV^.mv[LX] := mvpcand_list[MvpLxFlag];
end;

end.
