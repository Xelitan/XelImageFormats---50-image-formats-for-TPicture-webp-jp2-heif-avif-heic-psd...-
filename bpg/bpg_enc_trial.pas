// BPG encoder -- Free Pascal
// Speculative encoding with rollback.
//
// Every rate-distortion decision left to make -- CU size, transform tree split,
// a wider mode search -- needs the same primitive: encode a region one way,
// measure it, undo everything, encode it the other way, keep the cheaper.
//
// "Everything" is more than the bitstream. The encoder's state that a trial
// touches, and that later blocks read, is:
//
//   * the CABAC context states and the arithmetic encoder itself;
//   * the reconstruction, which later blocks predict from;
//   * tab_ipm, which feeds the most-probable-mode derivation of later blocks;
//   * tab_ct_depth, which feeds the split_cu_flag context;
//   * qp_y_tab, skip_flag and the pred_flag in tab_mvf.
//
// Miss any one of them and a trial leaves a trace that changes what is coded
// afterwards. The test in t_trial catches exactly that: it encodes a picture
// where every coding unit is trial-encoded, rolled back, then encoded for real,
// and requires the result to be identical to a straight encode.
unit bpg_enc_trial;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}

interface

uses
  bpg_common, bpg_hevc_defs, bpg_putbits, bpg_cabac_enc, bpg_enc;

type
  TEncTrial = record
    Enc: ^TBpgEncoder;
    // arithmetic coder and its output
    CtxSave: array[0 .. HEVC_CONTEXTS - 1] of Byte;
    ESave: TCabacEncoder;
    OutLen: Integer;
    // the reconstruction rectangle, in luma coordinates
    X0, Y0, Size: Integer;
    Planes: array[0..2] of array of Word;
    PW, PH: array[0..2] of Integer;
    // per-picture tables, saved whole -- they are small next to the frame
    Ipm, CtDepth, Skip: array of Byte;
    QpY: array of Int8;
    Mvf: array of TMvField;
    // the local context, which carries cu / tu / pu state across the trial
    LcSave: THEVCLocalContext;
    CtbDone: Integer;
  end;

// Captures the state a trial over the given luma rectangle can disturb.
procedure trial_begin(var T: TEncTrial; var Enc: TBpgEncoder; X0, Y0, Size: Integer);
// Keeps whatever the trial produced.
procedure trial_commit(var T: TEncTrial);
// Puts everything back as it was at trial_begin.
procedure trial_rollback(var T: TEncTrial);
// Bits written since trial_begin, for the rate term of a cost.
function trial_bits(const T: TEncTrial): Integer;

implementation

procedure save_rect(var T: TEncTrial; Store: Boolean);
var
  S: PHEVCContext;
  C, Y, W, H, XP, YP, Stride: Integer;
  Src: PWord;
begin
  S := @T.Enc^.Ctx;
  for C := 0 to 2 do
  begin
    if S^.frame^.Data[C] = nil then
    begin
      T.PW[C] := 0;
      T.PH[C] := 0;
      Continue;
    end;
    XP := T.X0 shr S^.sps^.hshift[C];
    YP := T.Y0 shr S^.sps^.vshift[C];
    W := T.Size shr S^.sps^.hshift[C];
    H := T.Size shr S^.sps^.vshift[C];
    // clip to the coded picture
    if XP + W > (S^.sps^.width shr S^.sps^.hshift[C]) then
      W := (S^.sps^.width shr S^.sps^.hshift[C]) - XP;
    if YP + H > (S^.sps^.height shr S^.sps^.vshift[C]) then
      H := (S^.sps^.height shr S^.sps^.vshift[C]) - YP;
    if (W <= 0) or (H <= 0) then
    begin
      T.PW[C] := 0;
      T.PH[C] := 0;
      Continue;
    end;
    T.PW[C] := W;
    T.PH[C] := H;
    if Store then SetLength(T.Planes[C], W * H);
    Stride := S^.frame^.Linesize[C] div SizeOf(Word);
    for Y := 0 to H - 1 do
    begin
      Src := PWord(S^.frame^.Data[C]) + (YP + Y) * Stride + XP;
      if Store then
        Move(Src^, T.Planes[C][Y * W], W * SizeOf(Word))
      else
        Move(T.Planes[C][Y * W], Src^, W * SizeOf(Word));
    end;
  end;
end;

procedure save_tables(var T: TEncTrial; Store: Boolean);
var
  S: PHEVCContext;
  NCb, NPu: Integer;
begin
  S := @T.Enc^.Ctx;
  NCb := S^.sps^.min_cb_width * S^.sps^.min_cb_height;
  NPu := S^.sps^.min_pu_width * S^.sps^.min_pu_height;
  if Store then
  begin
    SetLength(T.Ipm, NPu);
    SetLength(T.CtDepth, NCb);
    SetLength(T.Skip, NCb);
    SetLength(T.QpY, NCb);
    SetLength(T.Mvf, NPu);
    Move(S^.tab_ipm^, T.Ipm[0], NPu);
    Move(S^.tab_ct_depth^, T.CtDepth[0], NCb);
    Move(S^.skip_flag^, T.Skip[0], NCb);
    Move(S^.qp_y_tab^, T.QpY[0], NCb);
    Move(S^.ref^.tab_mvf^, T.Mvf[0], NPu * SizeOf(TMvField));
  end
  else
  begin
    Move(T.Ipm[0], S^.tab_ipm^, NPu);
    Move(T.CtDepth[0], S^.tab_ct_depth^, NCb);
    Move(T.Skip[0], S^.skip_flag^, NCb);
    Move(T.QpY[0], S^.qp_y_tab^, NCb);
    Move(T.Mvf[0], S^.ref^.tab_mvf^, NPu * SizeOf(TMvField));
  end;
end;

procedure trial_begin(var T: TEncTrial; var Enc: TBpgEncoder; X0, Y0, Size: Integer);
begin
  T.Enc := @Enc;
  T.X0 := X0;
  T.Y0 := Y0;
  T.Size := Size;
  Move(Enc.Ctx.HEVClc^.cabac_state, T.CtxSave, SizeOf(T.CtxSave));
  T.ESave := Enc.E;
  T.OutLen := Enc.SliceRbsp.Len;
  T.LcSave := Enc.Ctx.HEVClc^;
  T.CtbDone := Enc.CtbDone;
  save_rect(T, True);
  save_tables(T, True);
end;

procedure trial_commit(var T: TEncTrial);
begin
  SetLength(T.Planes[0], 0);
  SetLength(T.Planes[1], 0);
  SetLength(T.Planes[2], 0);
  SetLength(T.Ipm, 0);
  SetLength(T.CtDepth, 0);
  SetLength(T.Skip, 0);
  SetLength(T.QpY, 0);
  SetLength(T.Mvf, 0);
end;

procedure trial_rollback(var T: TEncTrial);
begin
  Move(T.CtxSave, T.Enc^.Ctx.HEVClc^.cabac_state, SizeOf(T.CtxSave));
  // restoring the whole local context also restores cabac_state, so put the
  // saved states back afterwards -- the order matters
  T.Enc^.Ctx.HEVClc^ := T.LcSave;
  Move(T.CtxSave, T.Enc^.Ctx.HEVClc^.cabac_state, SizeOf(T.CtxSave));
  T.Enc^.E := T.ESave;
  T.Enc^.SliceRbsp.Len := T.OutLen;
  T.Enc^.CtbDone := T.CtbDone;
  save_rect(T, False);
  save_tables(T, False);
  trial_commit(T);
end;

function trial_bits(const T: TEncTrial): Integer;
begin
  Result := (T.Enc^.SliceRbsp.Len - T.OutLen) * 8 +
            (T.Enc^.E.NBits - T.ESave.NBits);
end;

end.
