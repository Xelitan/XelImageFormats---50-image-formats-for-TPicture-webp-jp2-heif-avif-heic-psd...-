// BPG encoder -- Free Pascal
// Rate-distortion decision for the coding unit quadtree.
//
// For every node that the format lets us choose about, the block is encoded
// whole, rolled back, encoded as four children, and the cheaper of the two is
// kept and encoded a third time for real. Cost is the squared error of the
// reconstruction against the source plus lambda times the bits actually
// written -- both measured, neither estimated.
//
// The measurement that motivated this: at qp 24 a smooth picture is
// 47% smaller and 3 dB better with CTU 32 than with CTU 8, while a detailed one
// is 6% smaller and 1.1 dB better the other way round. A fixed size cannot win
// both.
//
// Installing enc_quadtree_hook replaces the plain walk in bpg_enc, so the two
// live side by side and the plain one stays available as a reference.
unit bpg_enc_rd;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}

interface

uses
  Math, bpg_common, bpg_hevc_defs, bpg_putbits, bpg_syntax_enc, bpg_enc,
  bpg_enc_trial;

// Installs (or removes) the rate-distortion quadtree.
procedure bpg_enc_rd_enable(On_: Boolean);

implementation

var
  Lambda: Double;

// squared error of the reconstruction against the source over a luma rectangle,
// summed over every plane at its own subsampling
function block_ssd(var Enc: TBpgEncoder; X0, Y0, Size: Integer): Int64;
var
  S: PHEVCContext;
  C, X, Y, XP, YP, W, H, RS, SS, D: Integer;
  Rec, Src: PWord;
  PlaneSsd: Int64;
  Weight: Double;
begin
  Result := 0;
  S := @Enc.Ctx;
  for C := 0 to 2 do
  begin
    if S^.frame^.Data[C] = nil then Continue;
    XP := X0 shr S^.sps^.hshift[C];
    YP := Y0 shr S^.sps^.vshift[C];
    W := Size shr S^.sps^.hshift[C];
    H := Size shr S^.sps^.vshift[C];
    if XP + W > (S^.sps^.width shr S^.sps^.hshift[C]) then
      W := (S^.sps^.width shr S^.sps^.hshift[C]) - XP;
    if YP + H > (S^.sps^.height shr S^.sps^.vshift[C]) then
      H := (S^.sps^.height shr S^.sps^.vshift[C]) - YP;
    if (W <= 0) or (H <= 0) then Continue;
    RS := S^.frame^.Linesize[C] div SizeOf(Word);
    SS := Enc.Src^.Linesize[C] div SizeOf(Word);
    Rec := PWord(S^.frame^.Data[C]) + YP * RS + XP;
    Src := PWord(Enc.Src^.Data[C]) + YP * SS + XP;
    PlaneSsd := 0;
    for Y := 0 to H - 1 do
      for X := 0 to W - 1 do
      begin
        D := Rec[Y * RS + X] - Src[Y * SS + X];
        PlaneSsd := PlaneSsd + Int64(D) * D;
      end;
    Weight := 1.0;
    if (C > 0) and (S^.sps^.chroma_format_idc <> 3) then
    begin
      if C = 1 then Weight := 3.258 / 3.0 else Weight := 2.476 / 3.0;
      Weight := Weight * (1 shl (S^.sps^.hshift[C] + S^.sps^.vshift[C]));
    end;
    Result := Result + Round(PlaneSsd * Weight);
  end;
end;

function rd_quadtree(var Enc: TBpgEncoder;
  X0, Y0, Log2CbSize, CbDepth: Integer): Integer; forward;

// codes the node as a single coding unit, split_cu_flag included
function code_whole(var Enc: TBpgEncoder;
  X0, Y0, Log2CbSize, CbDepth: Integer; WriteFlag: Boolean): Integer;
begin
  Enc.Ctx.HEVClc^.ct_depth := CbDepth;
  if WriteFlag then
    enc_split_coding_unit_flag(@Enc.Ctx, Enc.E, CbDepth, X0, Y0, 0);
  encode_coding_unit(Enc, X0, Y0, Log2CbSize);
  Result := encode_leaf_tail(Enc, X0, Y0, 1 shl Log2CbSize);
end;

// codes the node as four children, split_cu_flag included
function code_split(var Enc: TBpgEncoder;
  X0, Y0, Log2CbSize, CbDepth: Integer; WriteFlag: Boolean): Integer;
var
  S: PHEVCContext;
  half, X1, Y1, more_data: Integer;
begin
  S := @Enc.Ctx;
  Enc.Ctx.HEVClc^.ct_depth := CbDepth;
  if WriteFlag then
    enc_split_coding_unit_flag(S, Enc.E, CbDepth, X0, Y0, 1);
  half := (1 shl Log2CbSize) shr 1;
  X1 := X0 + half;
  Y1 := Y0 + half;
  more_data := rd_quadtree(Enc, X0, Y0, Log2CbSize - 1, CbDepth + 1);
  if (more_data <> 0) and (X1 < S^.sps^.width) then
    more_data := rd_quadtree(Enc, X1, Y0, Log2CbSize - 1, CbDepth + 1);
  if (more_data <> 0) and (Y1 < S^.sps^.height) then
    more_data := rd_quadtree(Enc, X0, Y1, Log2CbSize - 1, CbDepth + 1);
  if (more_data <> 0) and (X1 < S^.sps^.width) and (Y1 < S^.sps^.height) then
    more_data := rd_quadtree(Enc, X1, Y1, Log2CbSize - 1, CbDepth + 1);
  if more_data <> 0 then
    Result := Ord(((X1 + half) < S^.sps^.width) or ((Y1 + half) < S^.sps^.height))
  else
    Result := 0;
end;

function rd_quadtree(var Enc: TBpgEncoder;
  X0, Y0, Log2CbSize, CbDepth: Integer): Integer;
var
  S: PHEVCContext;
  cb_size: Integer;
  T: TEncTrial;
  CostWhole, CostSplit: Double;
  BitsWhole, BitsSplit: Integer;
  MoreWhole, MoreSplit: Integer;
  Inside: Boolean;
begin
  S := @Enc.Ctx;
  cb_size := 1 shl Log2CbSize;
  Inside := (X0 + cb_size <= S^.sps^.width) and (Y0 + cb_size <= S^.sps^.height);

  // outside the picture the split is inferred and no flag is written; at the
  // minimum size there is nothing to choose
  if not Inside then
  begin
    if Log2CbSize > S^.sps^.log2_min_cb_size then
      Exit(code_split(Enc, X0, Y0, Log2CbSize, CbDepth, False))
    else
      Exit(code_whole(Enc, X0, Y0, Log2CbSize, CbDepth, False));
  end;
  if Log2CbSize <= S^.sps^.log2_min_cb_size then
    Exit(code_whole(Enc, X0, Y0, Log2CbSize, CbDepth, False));

  // try it whole
  trial_begin(T, Enc, X0, Y0, cb_size);
  MoreWhole := code_whole(Enc, X0, Y0, Log2CbSize, CbDepth, True);
  BitsWhole := trial_bits(T);
  CostWhole := block_ssd(Enc, X0, Y0, cb_size) + Lambda * BitsWhole;
  trial_rollback(T);

  // try it split
  trial_begin(T, Enc, X0, Y0, cb_size);
  MoreSplit := code_split(Enc, X0, Y0, Log2CbSize, CbDepth, True);
  BitsSplit := trial_bits(T);
  CostSplit := block_ssd(Enc, X0, Y0, cb_size) + Lambda * BitsSplit;
  trial_rollback(T);

  // encode the winner for real
  if CostSplit < CostWhole then
    Result := code_split(Enc, X0, Y0, Log2CbSize, CbDepth, True)
  else
    Result := code_whole(Enc, X0, Y0, Log2CbSize, CbDepth, True);
end;

// The transform tree split, decided with the same trials as the coding unit
// size. The forced encode_transform_node forms keep the recursion honest: a
// trial of "split" lets each child consult this hook again, so the decision is
// a full tree search bounded by the SPS depth limit.
function rd_tu_split(var Enc: TBpgEncoder;
  X0, Y0, Log2CbSize, Log2TrafoSize, TrafoDepth: Integer): Boolean;
var
  T: TEncTrial;
  CostWhole, CostSplit: Double;
begin
  trial_begin(T, Enc, X0, Y0, 1 shl Log2TrafoSize);
  encode_transform_node(Enc, X0, Y0, Log2CbSize, Log2TrafoSize, TrafoDepth, 0);
  CostWhole := block_ssd(Enc, X0, Y0, 1 shl Log2TrafoSize) + Lambda * trial_bits(T);
  trial_rollback(T);

  trial_begin(T, Enc, X0, Y0, 1 shl Log2TrafoSize);
  encode_transform_node(Enc, X0, Y0, Log2CbSize, Log2TrafoSize, TrafoDepth, 1);
  CostSplit := block_ssd(Enc, X0, Y0, 1 shl Log2TrafoSize) + Lambda * trial_bits(T);
  trial_rollback(T);

  Result := CostSplit < CostWhole;
end;

// PART_NxN against PART_2Nx2N, decided the same way as everything else: code
// it both ways, roll each back, and keep the cheaper on measured bits plus
// exact error. Four quarters with their own intra modes cost four mode
// signallings, so the win has to come from prediction that actually fits the
// block better -- which is why it is decided, not assumed.
function rd_cu_part(var Enc: TBpgEncoder; X0, Y0, Log2CbSize: Integer): Boolean;
var
  T: TEncTrial;
  Cost2, CostN: Double;
  Size: Integer;
begin
  Size := 1 shl Log2CbSize;
  trial_begin(T, Enc, X0, Y0, Size);
  encode_coding_unit_part(Enc, X0, Y0, Log2CbSize, 0);
  Cost2 := block_ssd(Enc, X0, Y0, Size) + Lambda * trial_bits(T);
  trial_rollback(T);

  trial_begin(T, Enc, X0, Y0, Size);
  encode_coding_unit_part(Enc, X0, Y0, Log2CbSize, 1);
  CostN := block_ssd(Enc, X0, Y0, Size) + Lambda * trial_bits(T);
  trial_rollback(T);

  Result := CostN < Cost2;
end;

function rd_quadtree_entry(var Enc: TBpgEncoder;
  X0, Y0, Log2CbSize, CbDepth: Integer): Integer;
var
  S: PHEVCContext;
begin
  S := @Enc.Ctx;
  // the usual HEVC intra lambda
  Lambda := 0.57 * Exp(((Enc.Qp - 12) / 3.0) * Ln(2.0));
  // block_ssd now weights the planes for the RGB metric, which raises the total
  // distortion by roughly the mean weight. Scaling lambda by the same amount
  // keeps the operating point where it was, so what is measured is the change
  // in how bits are SHARED between planes, not simply spending more of them.
  if S^.sps^.chroma_format_idc = 1 then Lambda := Lambda * 1.941
  else if S^.sps^.chroma_format_idc = 2 then Lambda := Lambda * 1.471;
  Result := rd_quadtree(Enc, X0, Y0, Log2CbSize, CbDepth);
end;

procedure bpg_enc_rd_enable(On_: Boolean);
begin
  if On_ then
  begin
    enc_quadtree_hook := rd_quadtree_entry;
    enc_tu_split_hook := rd_tu_split;
    enc_cu_part_hook := rd_cu_part;
  end
  else
  begin
    enc_quadtree_hook := nil;
    enc_tu_split_hook := nil;
    enc_cu_part_hook := rd_cu_part;
  end;
end;

end.
