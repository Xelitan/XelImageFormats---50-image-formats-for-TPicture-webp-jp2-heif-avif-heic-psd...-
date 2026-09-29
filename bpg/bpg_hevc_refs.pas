// BPG decoder -- Free Pascal port of libbpg 0.9.8
// Decoded picture buffer, reference picture sets and lists, POC computation.
// Corresponds to: libavcodec/hevc_refs.c
//
// ff_thread_get_buffer / ff_thread_release_buffer collapse to plain buffer
// allocation because libbpg is single-threaded.
unit bpg_hevc_refs;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  bpg_common, bpg_hevc_defs, bpg_frame;

procedure ff_hevc_unref_frame(S: PHEVCContext; Frame: PHEVCFrame; Flags: Integer);
function ff_hevc_get_ref_list(S: PHEVCContext; Ref: PHEVCFrame; X0, Y0: Integer): PRefPicList;
procedure ff_hevc_clear_refs(S: PHEVCContext);
procedure ff_hevc_flush_dpb(S: PHEVCContext);
function ff_hevc_set_new_ref(S: PHEVCContext; var Frame: PAVFrame; Poc: Integer): Integer;
function ff_hevc_output_frame(S: PHEVCContext; Out_: PAVFrame; Flush: Integer): Integer;
procedure ff_hevc_bump_frame(S: PHEVCContext);
function ff_hevc_slice_rpl(S: PHEVCContext): Integer;
function ff_hevc_frame_rps(S: PHEVCContext): Integer;
function ff_hevc_compute_poc(S: PHEVCContext; PocLsb: Integer): Integer;
function ff_hevc_frame_nb_refs(S: PHEVCContext): Integer;

implementation

procedure ff_hevc_unref_frame(S: PHEVCContext; Frame: PHEVCFrame; Flags: Integer);
begin
  if (Frame^.Frame = nil) or (Frame^.Frame^.Buf[0] = nil) then Exit;
  Frame^.flags := Frame^.flags and (not Byte(Flags));
  if Frame^.flags = 0 then
  begin
    av_frame_unref(Frame^.Frame);
    av_freep(@Frame^.tab_mvf_buf);
    Frame^.tab_mvf := nil;
    av_freep(@Frame^.rpl_buf);
    av_freep(@Frame^.rpl_tab_buf);
    Frame^.rpl_tab := nil;
    Frame^.refPicList := nil;
    Frame^.collocated_ref := nil;
    Frame^.rpl_buf_count := 0;
  end;
end;

function ff_hevc_get_ref_list(S: PHEVCContext; Ref: PHEVCFrame; X0, Y0: Integer): PRefPicList;
var
  x_cb, y_cb, pic_width_cb, ctb_addr_ts: Integer;
begin
  x_cb := X0 shr S^.sps^.log2_ctb_size;
  y_cb := Y0 shr S^.sps^.log2_ctb_size;
  pic_width_cb := S^.sps^.ctb_width;
  ctb_addr_ts := S^.pps^.ctb_addr_rs_to_ts[y_cb * pic_width_cb + x_cb];
  Result := PRefPicList(Ref^.rpl_tab[ctb_addr_ts]);
end;

procedure ff_hevc_clear_refs(S: PHEVCContext);
var
  I: Integer;
begin
  for I := 0 to MAX_DPB_COUNT - 1 do
    ff_hevc_unref_frame(S, @S^.DPB[I],
      HEVC_FRAME_FLAG_SHORT_REF or HEVC_FRAME_FLAG_LONG_REF);
end;

procedure ff_hevc_flush_dpb(S: PHEVCContext);
var
  I: Integer;
begin
  for I := 0 to MAX_DPB_COUNT - 1 do
    ff_hevc_unref_frame(S, @S^.DPB[I], -1);
end;

function alloc_frame(S: PHEVCContext): PHEVCFrame;
var
  I, J: Integer;
  Frame: PHEVCFrame;
  MvfSize, RplTabSize: SizeInt;
begin
  for I := 0 to MAX_DPB_COUNT - 1 do
  begin
    Frame := @S^.DPB[I];
    if Frame^.Frame^.Buf[0] <> nil then Continue;

    if frame_get_buffer(Frame^.Frame, S^.sps^.width, S^.sps^.height,
                        S^.sps^.chroma_format_idc) < 0 then
      Exit(nil);

    Frame^.ctb_count := S^.sps^.ctb_width * S^.sps^.ctb_height;

    Frame^.rpl_buf_count := S^.nb_nals;
    if Frame^.rpl_buf_count < 1 then Frame^.rpl_buf_count := 1;
    Frame^.rpl_buf := av_mallocz(Frame^.rpl_buf_count * SizeOf(TRefPicListTab));
    if Frame^.rpl_buf = nil then
    begin
      ff_hevc_unref_frame(S, Frame, -1);
      Exit(nil);
    end;

    MvfSize := SizeInt(S^.sps^.min_pu_width) * S^.sps^.min_pu_height * SizeOf(TMvField);
    Frame^.tab_mvf_buf := av_mallocz(MvfSize);
    if Frame^.tab_mvf_buf = nil then
    begin
      ff_hevc_unref_frame(S, Frame, -1);
      Exit(nil);
    end;
    Frame^.tab_mvf := PMvField(Frame^.tab_mvf_buf);

    RplTabSize := SizeInt(Frame^.ctb_count) * SizeOf(PRefPicListTab);
    Frame^.rpl_tab_buf := av_mallocz(RplTabSize);
    if Frame^.rpl_tab_buf = nil then
    begin
      ff_hevc_unref_frame(S, Frame, -1);
      Exit(nil);
    end;
    Frame^.rpl_tab := PPRefPicListTab(Frame^.rpl_tab_buf);
    for J := 0 to Frame^.ctb_count - 1 do
      Frame^.rpl_tab[J] := PRefPicListTab(Frame^.rpl_buf);

    Exit(Frame);
  end;
  Result := nil;
end;

function ff_hevc_set_new_ref(S: PHEVCContext; var Frame: PAVFrame; Poc: Integer): Integer;
var
  Ref: PHEVCFrame;
  I: Integer;
begin
  for I := 0 to MAX_DPB_COUNT - 1 do
    if (S^.DPB[I].Frame^.Buf[0] <> nil) and (S^.DPB[I].sequence = S^.seq_decode) and
       (S^.DPB[I].poc = Poc) then
      Exit(AVERROR_INVALIDDATA);

  Ref := alloc_frame(S);
  if Ref = nil then Exit(AVERROR_ENOMEM);

  Frame := Ref^.Frame;
  S^.ref := Ref;

  if S^.sh.pic_output_flag <> 0 then
    Ref^.flags := HEVC_FRAME_FLAG_OUTPUT or HEVC_FRAME_FLAG_SHORT_REF
  else
    Ref^.flags := HEVC_FRAME_FLAG_SHORT_REF;

  Ref^.poc := Poc;
  Ref^.sequence := S^.seq_decode;
  Ref^.window := S^.sps^.output_window;
  Result := 0;
end;

function ff_hevc_output_frame(S: PHEVCContext; Out_: PAVFrame; Flush: Integer): Integer;
var
  nb_output, min_poc, I, min_idx, Ret: Integer;
  Frame: PHEVCFrame;
  Src: PAVFrame;
begin
  while True do
  begin
    nb_output := 0;
    min_poc := $7FFFFFFF;
    min_idx := 0;

    if S^.sh.no_output_of_prior_pics_flag = 1 then
      for I := 0 to MAX_DPB_COUNT - 1 do
      begin
        Frame := @S^.DPB[I];
        if ((Frame^.flags and HEVC_FRAME_FLAG_BUMPING) = 0) and (Frame^.poc <> S^.poc) and
           (Frame^.sequence = S^.seq_output) then
          ff_hevc_unref_frame(S, Frame, HEVC_FRAME_FLAG_OUTPUT);
      end;

    for I := 0 to MAX_DPB_COUNT - 1 do
    begin
      Frame := @S^.DPB[I];
      if ((Frame^.flags and HEVC_FRAME_FLAG_OUTPUT) <> 0) and
         (Frame^.sequence = S^.seq_output) then
      begin
        Inc(nb_output);
        if Frame^.poc < min_poc then
        begin
          min_poc := Frame^.poc;
          min_idx := I;
        end;
      end;
    end;

    if (Flush = 0) and (S^.seq_output = S^.seq_decode) and (S^.sps <> nil) and
       (nb_output <= S^.sps^.temporal_layer[S^.sps^.max_sub_layers - 1].num_reorder_pics) then
      Exit(0);

    if nb_output <> 0 then
    begin
      Frame := @S^.DPB[min_idx];
      Src := Frame^.Frame;
      Ret := av_frame_ref(Out_, Src);
      if (Frame^.flags and HEVC_FRAME_FLAG_BUMPING) <> 0 then
        ff_hevc_unref_frame(S, Frame, HEVC_FRAME_FLAG_OUTPUT or HEVC_FRAME_FLAG_BUMPING)
      else
        ff_hevc_unref_frame(S, Frame, HEVC_FRAME_FLAG_OUTPUT);
      if Ret < 0 then Exit(Ret);
      Exit(1);
    end;

    if S^.seq_output <> S^.seq_decode then
      S^.seq_output := (S^.seq_output + 1) and $FF
    else
      Break;
  end;
  Result := 0;
end;

procedure ff_hevc_bump_frame(S: PHEVCContext);
var
  dpb, min_poc, I: Integer;
  Frame: PHEVCFrame;
begin
  dpb := 0;
  min_poc := $7FFFFFFF;
  for I := 0 to MAX_DPB_COUNT - 1 do
  begin
    Frame := @S^.DPB[I];
    if (Frame^.flags <> 0) and (Frame^.sequence = S^.seq_output) and
       (Frame^.poc <> S^.poc) then
      Inc(dpb);
  end;
  if (S^.sps <> nil) and
     (dpb >= S^.sps^.temporal_layer[S^.sps^.max_sub_layers - 1].max_dec_pic_buffering) then
  begin
    for I := 0 to MAX_DPB_COUNT - 1 do
    begin
      Frame := @S^.DPB[I];
      if (Frame^.flags <> 0) and (Frame^.sequence = S^.seq_output) and
         (Frame^.poc <> S^.poc) then
        if (Frame^.flags = HEVC_FRAME_FLAG_OUTPUT) and (Frame^.poc < min_poc) then
          min_poc := Frame^.poc;
    end;
    for I := 0 to MAX_DPB_COUNT - 1 do
    begin
      Frame := @S^.DPB[I];
      if ((Frame^.flags and HEVC_FRAME_FLAG_OUTPUT) <> 0) and
         (Frame^.sequence = S^.seq_output) and (Frame^.poc <= min_poc) then
        Frame^.flags := Frame^.flags or HEVC_FRAME_FLAG_BUMPING;
    end;
    Dec(dpb);
  end;
end;

function init_slice_rpl(S: PHEVCContext): Integer;
var
  Frame: PHEVCFrame;
  ctb_count, ctb_addr_ts, I: Integer;
begin
  Frame := S^.ref;
  ctb_count := Frame^.ctb_count;
  ctb_addr_ts := S^.pps^.ctb_addr_rs_to_ts[S^.sh.slice_segment_addr];
  if S^.slice_idx >= Frame^.rpl_buf_count then
    Exit(AVERROR_INVALIDDATA);
  for I := ctb_addr_ts to ctb_count - 1 do
    Frame^.rpl_tab[I] := PRefPicListTab(Frame^.rpl_buf) + S^.slice_idx;
  Frame^.refPicList := PRefPicList(Frame^.rpl_tab[ctb_addr_ts]);
  Result := 0;
end;

function ff_hevc_slice_rpl(S: PHEVCContext): Integer;
var
  SH: PSliceHeader;
  nb_list, list_idx: Byte;
  I, J, Ret, Idx: Integer;
  rpl_tmp: TRefPicList;
  RPL: PRefPicList;
  cand_lists: array[0..2] of Integer;
  RPS: PRefPicList;
begin
  SH := @S^.sh;
  if SH^.slice_type = B_SLICE then nb_list := 2 else nb_list := 1;

  Ret := init_slice_rpl(S);
  if Ret < 0 then Exit(Ret);

  if (S^.rps[ST_CURR_BEF].nb_refs + S^.rps[ST_CURR_AFT].nb_refs +
      S^.rps[LT_CURR].nb_refs) = 0 then
    Exit(AVERROR_INVALIDDATA);

  for list_idx := 0 to nb_list - 1 do
  begin
    FillChar(rpl_tmp, SizeOf(rpl_tmp), 0);
    RPL := @S^.ref^.refPicList[list_idx];
    if list_idx <> 0 then cand_lists[0] := ST_CURR_AFT else cand_lists[0] := ST_CURR_BEF;
    if list_idx <> 0 then cand_lists[1] := ST_CURR_BEF else cand_lists[1] := ST_CURR_AFT;
    cand_lists[2] := LT_CURR;

    while Cardinal(rpl_tmp.nb_refs) < SH^.nb_refs[list_idx] do
      for I := 0 to 2 do
      begin
        RPS := @S^.rps[cand_lists[I]];
        J := 0;
        while (J < RPS^.nb_refs) and (rpl_tmp.nb_refs < 16) do
        begin
          rpl_tmp.List[rpl_tmp.nb_refs] := RPS^.List[J];
          rpl_tmp.Ref[rpl_tmp.nb_refs] := RPS^.Ref[J];
          rpl_tmp.isLongTerm[rpl_tmp.nb_refs] := Ord(I = 2);
          Inc(rpl_tmp.nb_refs);
          Inc(J);
        end;
      end;

    if SH^.rpl_modification_flag[list_idx] <> 0 then
    begin
      for I := 0 to Integer(SH^.nb_refs[list_idx]) - 1 do
      begin
        Idx := Integer(SH^.list_entry_lx[list_idx][I]);
        if Idx >= rpl_tmp.nb_refs then Exit(AVERROR_INVALIDDATA);
        RPL^.List[I] := rpl_tmp.List[Idx];
        RPL^.Ref[I] := rpl_tmp.Ref[Idx];
        RPL^.isLongTerm[I] := rpl_tmp.isLongTerm[Idx];
        Inc(RPL^.nb_refs);
      end;
    end
    else
    begin
      Move(rpl_tmp, RPL^, SizeOf(TRefPicList));
      RPL^.nb_refs := FFMIN(RPL^.nb_refs, Integer(SH^.nb_refs[list_idx]));
    end;

    if (SH^.collocated_list = list_idx) and
       (SH^.collocated_ref_idx < Cardinal(RPL^.nb_refs)) then
      S^.ref^.collocated_ref := RPL^.Ref[SH^.collocated_ref_idx];
  end;
  Result := 0;
end;

function find_ref_idx(S: PHEVCContext; Poc: Integer): PHEVCFrame;
var
  I, LtMask: Integer;
  Ref: PHEVCFrame;
begin
  LtMask := (1 shl S^.sps^.log2_max_poc_lsb) - 1;
  for I := 0 to MAX_DPB_COUNT - 1 do
  begin
    Ref := @S^.DPB[I];
    if (Ref^.Frame^.Buf[0] <> nil) and (Ref^.sequence = S^.seq_decode) then
      if (Ref^.poc and LtMask) = Poc then Exit(Ref);
  end;
  for I := 0 to MAX_DPB_COUNT - 1 do
  begin
    Ref := @S^.DPB[I];
    if (Ref^.Frame^.Buf[0] <> nil) and (Ref^.sequence = S^.seq_decode) then
      if (Ref^.poc = Poc) or ((Ref^.poc and LtMask) = Poc) then Exit(Ref);
  end;
  Result := nil;
end;

procedure mark_ref(Frame: PHEVCFrame; Flag: Integer);
begin
  Frame^.flags := Frame^.flags and
    (not Byte(HEVC_FRAME_FLAG_LONG_REF or HEVC_FRAME_FLAG_SHORT_REF));
  Frame^.flags := Frame^.flags or Byte(Flag);
end;

function generate_missing_ref(S: PHEVCContext; Poc: Integer): PHEVCFrame;
var
  Frame: PHEVCFrame;
  I, X, Y: Integer;
  Row: PWord;
  Val: Word;
begin
  Frame := alloc_frame(S);
  if Frame = nil then Exit(nil);
  // pixel_shift is always 1 in the MSPS configuration
  Val := Word(1 shl (S^.sps^.bit_depth - 1));
  I := 0;
  while (I < 3) and (Frame^.Frame^.Data[I] <> nil) do
  begin
    for Y := 0 to (S^.sps^.height shr S^.sps^.vshift[I]) - 1 do
    begin
      Row := PWord(Frame^.Frame^.Data[I] + Y * Frame^.Frame^.Linesize[I]);
      for X := 0 to (S^.sps^.width shr S^.sps^.hshift[I]) - 1 do
        Row[X] := Val;
    end;
    Inc(I);
  end;
  Frame^.poc := Poc;
  Frame^.sequence := S^.seq_decode;
  Frame^.flags := 0;
  Result := Frame;
end;

function add_candidate_ref(S: PHEVCContext; List: PRefPicList;
  Poc, RefFlag: Integer): Integer;
var
  Ref: PHEVCFrame;
begin
  Ref := find_ref_idx(S, Poc);
  if Ref = S^.ref then Exit(AVERROR_INVALIDDATA);
  if Ref = nil then
  begin
    Ref := generate_missing_ref(S, Poc);
    if Ref = nil then Exit(AVERROR_ENOMEM);
  end;
  List^.List[List^.nb_refs] := Ref^.poc;
  List^.Ref[List^.nb_refs] := Ref;
  Inc(List^.nb_refs);
  mark_ref(Ref, RefFlag);
  Result := 0;
end;

function ff_hevc_frame_rps(S: PHEVCContext): Integer;
var
  short_rps: PShortTermRPS;
  long_rps: PLongTermRPS;
  RPS: PRefPicList;
  I, Ret, Poc, List: Integer;
  Frame: PHEVCFrame;
begin
  short_rps := S^.sh.short_term_rps;
  long_rps := @S^.sh.long_term_rps;
  RPS := @S^.rps[0];

  if short_rps = nil then
  begin
    S^.rps[0].nb_refs := 0;
    S^.rps[1].nb_refs := 0;
    Exit(0);
  end;

  for I := 0 to MAX_DPB_COUNT - 1 do
  begin
    Frame := @S^.DPB[I];
    if Frame = S^.ref then Continue;
    mark_ref(Frame, 0);
  end;

  for I := 0 to NB_RPS_TYPE - 1 do
    S^.rps[I].nb_refs := 0;

  for I := 0 to short_rps^.num_delta_pocs - 1 do
  begin
    Poc := S^.poc + short_rps^.delta_poc[I];
    if short_rps^.used[I] = 0 then List := ST_FOLL
    else if Cardinal(I) < short_rps^.num_negative_pics then List := ST_CURR_BEF
    else List := ST_CURR_AFT;
    Ret := add_candidate_ref(S, @S^.rps[List], Poc, HEVC_FRAME_FLAG_SHORT_REF);
    if Ret < 0 then Exit(Ret);
  end;

  for I := 0 to long_rps^.nb_refs - 1 do
  begin
    Poc := long_rps^.poc[I];
    if long_rps^.used[I] <> 0 then List := LT_CURR else List := LT_FOLL;
    Ret := add_candidate_ref(S, @S^.rps[List], Poc, HEVC_FRAME_FLAG_LONG_REF);
    if Ret < 0 then Exit(Ret);
  end;

  for I := 0 to MAX_DPB_COUNT - 1 do
    ff_hevc_unref_frame(S, @S^.DPB[I], 0);
  Result := 0;
end;

function ff_hevc_compute_poc(S: PHEVCContext; PocLsb: Integer): Integer;
var
  max_poc_lsb, prev_poc_lsb, prev_poc_msb, poc_msb: Integer;
begin
  max_poc_lsb := 1 shl S^.sps^.log2_max_poc_lsb;
  prev_poc_lsb := S^.pocTid0 mod max_poc_lsb;
  prev_poc_msb := S^.pocTid0 - prev_poc_lsb;
  if (PocLsb < prev_poc_lsb) and (prev_poc_lsb - PocLsb >= max_poc_lsb div 2) then
    poc_msb := prev_poc_msb + max_poc_lsb
  else if (PocLsb > prev_poc_lsb) and (PocLsb - prev_poc_lsb > max_poc_lsb div 2) then
    poc_msb := prev_poc_msb - max_poc_lsb
  else
    poc_msb := prev_poc_msb;
  if (S^.nal_unit_type = NAL_BLA_W_LP) or (S^.nal_unit_type = NAL_BLA_W_RADL) or
     (S^.nal_unit_type = NAL_BLA_N_LP) then
    poc_msb := 0;
  Result := poc_msb + PocLsb;
end;

function ff_hevc_frame_nb_refs(S: PHEVCContext): Integer;
var
  Ret, I: Integer;
  RPS: PShortTermRPS;
  long_rps: PLongTermRPS;
begin
  Ret := 0;
  RPS := S^.sh.short_term_rps;
  long_rps := @S^.sh.long_term_rps;
  if RPS <> nil then
  begin
    for I := 0 to RPS^.num_delta_pocs - 1 do
      Ret := Ret + Ord(RPS^.used[I] <> 0);
  end;
  for I := 0 to long_rps^.nb_refs - 1 do
    Ret := Ret + Ord(long_rps^.used[I] <> 0);
  Result := Ret;
end;

end.
