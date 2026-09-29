// BPG encoder -- Free Pascal
// Simple HEVC intra picture encoder: one IDR I-slice, fixed CU size, no
// rate-distortion optimisation. Mode decision is a SAD over four candidate
// intra modes.
//
// The design principle throughout is that the encoder drives the decoder's own
// code wherever a decision has to be reproduced bit for bit:
//
//   * the context is a real THEVCContext, built by parsing the parameter sets
//     this encoder just wrote with bpg_hevc_ps's parsers, so every derived
//     field is what the decoder will compute;
//   * prediction is bpg_hevcpred.intra_pred, not a reimplementation;
//   * reconstruction dequantises and inverse transforms with the decoder's own
//     routines, so encoder and decoder cannot drift;
//   * neighbour availability comes from hls_decode_neighbour and
//     ff_hevc_set_neighbour_available.
//
// SAO and the deblocking filter are switched off, which makes the decoded
// picture identical to the encoder's reconstruction and keeps the encoder
// honest -- any mismatch is a real bug, not a filter difference.
unit bpg_enc;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  Math,
  bpg_common, bpg_bits, bpg_putbits, bpg_hevc_defs, bpg_frame, bpg_hevc_ps,
  bpg_hevc, bpg_hevcpred, bpg_hevcdsp, bpg_hevcdsp_enc, bpg_hevc_cabac,
  bpg_hevc_refs, bpg_hevc_mvs, bpg_cabac_enc, bpg_syntax_enc, bpg_ps_enc,
  bpg_slice_enc, bpg_sao_enc;

type
  TBpgEncoder = record
    Ctx: THEVCContext;
    Sps: TEncSps;
    Pps: TEncPps;
    Sh: TEncSliceHdr;
    Qp: Integer;
    // source planes, 16 bit, same geometry as the reconstruction frame
    Src: PAVFrame;
    // the MSPS tail, to be stored by the container
    MspsTail: TByteBuf;
    // PPS rbsp and the slice NAL, ready to be wrapped
    PpsRbsp: TByteBuf;
    SliceRbsp: TByteBuf;
    E: TCabacEncoder;
    NCtb: Integer;
    CtbDone: Integer;
  end;

// Qp is the slice QP, 0..51. Width and height must be multiples of the minimum
// coding block size (8).
function bpg_enc_init(var Enc: TBpgEncoder;
  Width, Height, ChromaFormatIdc, BitDepth, Qp: Integer): Integer;
// The source planes to encode; Enc.Src must be filled before calling.
function bpg_enc_picture(var Enc: TBpgEncoder): Integer;
procedure bpg_enc_free(var Enc: TBpgEncoder);
// Hook used by t_trial to wrap every coding unit in a trial and a rollback;
// nil in normal operation. It will also be how the CU size decision plugs in.
type
  TEncodeCuProc = procedure(var Enc: TBpgEncoder; X0, Y0, Log2CbSize: Integer);
var
  enc_cu_hook: TEncodeCuProc = nil;

procedure encode_coding_unit(var Enc: TBpgEncoder; X0, Y0, Log2CbSize: Integer);

// Same coding unit with the prediction partitioning forced: 0 = PART_2Nx2N,
// 1 = PART_NxN. The forced forms are what the rate-distortion trials use.
procedure encode_coding_unit_part(var Enc: TBpgEncoder;
  X0, Y0, Log2CbSize, ForcePart: Integer);

// Decides PART_NxN against PART_2Nx2N at the minimum coding block size;
// bpg_enc_rd installs a decider. Nil means always PART_2Nx2N.
type
  TCuPartFunc = function(var Enc: TBpgEncoder;
    X0, Y0, Log2CbSize: Integer): Boolean;
var
  enc_cu_part_hook: TCuPartFunc = nil;

// Decides split_transform_flag for one transform tree node; bpg_enc_rd
// installs a rate-distortion decider. Nil means never split.
type
  TTuSplitFunc = function(var Enc: TBpgEncoder;
    X0, Y0, Log2CbSize, Log2TrafoSize, TrafoDepth: Integer): Boolean;
var
  enc_tu_split_hook: TTuSplitFunc = nil;

// One node of the transform tree. ForceSplit: -1 consults the hook, 0 codes the
// node whole, 1 splits -- the forced forms are what the hook's trials use.
procedure encode_transform_node(var Enc: TBpgEncoder;
  X0, Y0, Log2CbSize, Log2TrafoSize, TrafoDepth, ForceSplit: Integer);

// Replaces the whole quadtree walk of one CTU; bpg_enc_rd installs the
// rate-distortion version here. Returns "more data", like encode_quadtree.
type
  TEncodeQuadtreeFunc = function(var Enc: TBpgEncoder;
    X0, Y0, Log2CbSize, CbDepth: Integer): Integer;
var
  enc_quadtree_hook: TEncodeQuadtreeFunc = nil;

// Lossless coding: every coding unit sets cu_transquant_bypass_flag, so the
// residual is carried through the bitstream untouched by transform or
// quantiser and the decoder reconstructs the source exactly. Consulted by
// bpg_enc_init, so set it before initialising.
procedure bpg_enc_lossless(On_: Boolean);
function bpg_enc_is_lossless: Boolean;

// Whole-block level-1 RDOQ. When it was added it measured +0.084 dB at equal
// rate. It no longer does: on photographs it now measures -0.086 dB at qp 26
// and -0.004 at qp 34, with the exact pixel-domain distortion, so this is the
// pass itself and not the transform-domain approximation. What changed is
// everything around it -- RGB-weighted distortion, transform units down to 4x4,
// PART_NxN and cross-component prediction all reduce the residual this pass was
// cleaning up, and its remaining trims now cost more than they save. Kept
// behind the flag with the measurement recorded rather than quietly deleted;
// see task #28.
procedure bpg_enc_rdoq_full(On_: Boolean);

// Transform skip on 4x4 blocks. Strictly better on sharp synthetic content --
// both rate and PSNR improve, up to -1.2% rate -- and slightly negative on
// photographs, where the extra flag costs a bin per block and is almost never
// taken. Content dependent, so it is asked for rather than assumed.
procedure bpg_enc_screen(On_: Boolean);

// Sample adaptive offset. Costs a second encoding pass: the picture is coded
// once for its reconstruction, SAO is chosen from that, and the slice is coded
// again with the parameters written in. Pass two reproduces identical decisions
// because intra prediction reads the unfiltered reconstruction.
procedure bpg_enc_sao(On_: Boolean);

// The deblocking filter. Nothing is needed on the encoder side beyond enabling
// it: intra prediction reads the unfiltered reconstruction, so the filter
// changes no residual and no decision -- the decoder simply applies it to the
// finished picture. The cost is that the encoder's own reconstruction is no
// longer what the decoder outputs, which is why t_enc keeps it off.
procedure bpg_enc_deblock(On_: Boolean);

// All 35 intra modes instead of the four fixed candidates, chosen in two
// stages. A fixed four-mode set was never a claim that the rest are useless --
// widening it measured worse only because a greedy per-block search over 35
// modes picks unusual angles, which wrecks the neighbours' most-probable-mode
// lists and costs more in signalling than the prediction gains. The shortlist
// below always carries the three MPM candidates, so the search can no longer
// drift away from what the neighbours expect.
procedure bpg_enc_modes(On_: Boolean);

// Cross-component prediction (4:4:4 only).
procedure bpg_enc_ccp(On_: Boolean);

// Where the RDOQ loop measures its distortion.
procedure bpg_enc_rdoq_tdomain(On_: Boolean);

// the end_of_slice_flag bookkeeping a quadtree leaf performs
function encode_leaf_tail(var Enc: TBpgEncoder; X0, Y0, cb_size: Integer): Integer;

// exposed for t_residual2: the dequantisation the decoder applies
procedure dequant_for_test(S: PHEVCContext; C: PInt16; Log2Size, CIdx, Qp: Integer);

implementation

var
  Lossless: Boolean = False;
  RdoqFull: Boolean = False;
  ScreenMode: Boolean = False;
  FullModes: Boolean = False;
  SaoMode: Boolean = False;
  DeblockMode: Boolean = False;
  CcpMode: Boolean = True;
  // transform-domain distortion in the RDOQ loop; -exactd turns it off
  RdoqTDomain: Boolean = True;
  // When set, encode_tb subtracts (CcpScaleCur * CcpPred[i]) shr 3 from the
  // residual it forms and reconstruct_tb adds it back -- the encoder side of
  // cross-component prediction. Cleared around every block that does not use
  // it, which is every block outside 4:4:4.
  CcpPred: PInt16 = nil;
  CcpScaleCur: Integer = 0;

procedure bpg_enc_lossless(On_: Boolean);
begin
  Lossless := On_;
end;

function bpg_enc_is_lossless: Boolean;
begin
  Result := Lossless;
end;

procedure bpg_enc_rdoq_full(On_: Boolean);
begin
  RdoqFull := On_;
end;

procedure bpg_enc_screen(On_: Boolean);
begin
  ScreenMode := On_;
end;

procedure bpg_enc_sao(On_: Boolean);
begin
  SaoMode := On_;
end;

procedure bpg_enc_deblock(On_: Boolean);
begin
  DeblockMode := On_;
end;

procedure bpg_enc_ccp(On_: Boolean);
begin
  CcpMode := On_;
end;

procedure bpg_enc_rdoq_tdomain(On_: Boolean);
begin
  RdoqTDomain := On_;
end;

procedure bpg_enc_modes(On_: Boolean);
begin
  FullModes := On_;
end;

const
  // The last-position trim, on by default. Re-measured after the RGB weighting,
  // the 4x4 transform units, PART_NxN and cross-component prediction all landed
  // around it -- the same re-check that showed -slow had gone negative. It is
  // still worth having, though the margin is thin: +0.012 dB equivalent at qp 26
  // and +0.051 at qp 34 on photographs, for 28% more encoding time (2724 ->
  // 3487 ms). Note the raw numbers look alarming and are not -- it takes 3.5%
  // to 5.9% off the file for 0.39 to 0.61 dB of PSNR, which is close to a fair
  // trade at this operating point and slightly better than one.
  RDOQ_TRIM = True;
  // how many modes the rough pass hands to the full reconstruction
  // Kept at 3 by measurement, not by guess: widening the shortlist makes the
  // smooth-content loss WORSE, not better (equivalent -0.41/-0.44 at 5 and
  // -0.45/-0.51 at 8, against -0.20/-0.26 at 3). The more angular modes reach
  // the full stage, the more of them exploit whatever is mis-weighted there --
  // which is what points at lambda rather than at this constant.
  CHROMA_IN_MODE = True;
  ROUGH_KEEP = 3;

  // Candidate modes. Widening this set measures worse even with an exact
  // rate term -- that hypothesis was tested and did not hold. What is left is
  // the greedy search itself: picking unusual modes degrades the neighbours'
  // most-probable-mode lists, and that cost is invisible to a per-block
  // decision. See the note in README.
  cand_modes: array[0..3] of Integer = (INTRA_PLANAR, INTRA_DC, 10, 26);
  level_scale: array[0..5] of Integer = (40, 45, 51, 57, 64, 72);

// the dequantisation ff_hevc_hls_residual_coding performs
procedure dequant_block(C: PInt16; Log2Size, Qp, BitDepth: Integer);
var
  I, N, Shift, Add, Scale: Integer;
  V: Int64;
begin
  N := 1 shl (2 * Log2Size);
  Shift := BitDepth + Log2Size - 5;
  Add := 1 shl (Shift - 1);
  Scale := level_scale[Qp mod 6] shl (Qp div 6);
  for I := 0 to N - 1 do
  begin
    V := SarInt64(Int64(C[I]) * Scale * 16 + Add, Shift);
    if V > 32767 then V := 32767;
    if V < -32768 then V := -32768;
    C[I] := Int16(V);
  end;
end;

// The quantiser the decoder actually uses. Above 8 bits the coded qp_y is
// shifted by qp_bd_offset = 6 * (bit_depth - 8); ff_hevc_hls_residual_coding
// adds it, so the encoder must too.
function luma_qp_of(S: PHEVCContext; QpY: Integer): Integer; inline;
begin
  Result := QpY + S^.sps^.qp_bd_offset;
end;

function chroma_qp_of(S: PHEVCContext; QpY, CIdx: Integer): Integer;
const
  qp_c_tab: array[0..13] of Int8 = (29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37);
var
  Offset, qp_i: Integer;
begin
  if CIdx = 1 then Offset := S^.pps^.cb_qp_offset else Offset := S^.pps^.cr_qp_offset;
  qp_i := av_clip_c(QpY + Offset, -S^.sps^.qp_bd_offset, 57);
  if S^.sps^.chroma_format_idc = 1 then
  begin
    if qp_i < 30 then Result := qp_i
    else if qp_i > 43 then Result := qp_i - 6
    else Result := qp_c_tab[qp_i - 30];
  end
  else
  begin
    if qp_i > 51 then Result := 51 else Result := qp_i;
  end;
  Result := Result + S^.sps^.qp_bd_offset;
end;

function plane_ptr(F: PAVFrame; CIdx, X, Y: Integer): PWord; inline;
begin
  Result := PWord(F^.Data[CIdx] + Y * F^.Linesize[CIdx]) + X;
end;

function plane_stride(F: PAVFrame; CIdx: Integer): Integer; inline;
begin
  Result := F^.Linesize[CIdx] div SizeOf(Word);
end;

// ------------------------------------------------------------------

procedure dequant_for_test(S: PHEVCContext; C: PInt16; Log2Size, CIdx, Qp: Integer);
var
  QpUsed: Integer;
begin
  if CIdx = 0 then QpUsed := luma_qp_of(S, Qp) else QpUsed := chroma_qp_of(S, Qp, CIdx);
  dequant_block(C, Log2Size, QpUsed, S^.sps^.bit_depth);
end;

function bpg_enc_init(var Enc: TBpgEncoder;
  Width, Height, ChromaFormatIdc, BitDepth, Qp: Integer): Integer;
var
  Full, ShBuf: TByteBuf;
  S: PHEVCContext;
begin
  FillChar(Enc, SizeOf(Enc), 0);
  S := @Enc.Ctx;
  if hevc_init_context(S) < 0 then Exit(-1);

  Enc.Qp := Qp;
  Enc.Sps.Width := Width;
  Enc.Sps.Height := Height;
  Enc.Sps.ChromaFormatIdc := ChromaFormatIdc;
  Enc.Sps.BitDepth := BitDepth;
  Enc.Sps.Log2MinCbSize := 3;
  Enc.Sps.Log2MaxCbSize := 5;
  Enc.Sps.Log2MinTbSize := 2;
  Enc.Sps.Log2MaxTbSize := 5;
  // 3, not 2: from a 32x32 coding unit the tree needs three splits to reach
  // 4x4, and with 2 the smallest transform was unreachable there. Measured
  // +0.069 dB equivalent on real photos for 12% more encoding time. The gain is
  // small because the coding-unit quadtree already drops to 8x8 wherever fine
  // transforms are wanted, so this only matters for large units with detail.
  Enc.Sps.MaxTransformHierarchyDepth := 3;
  // SAO cannot help a lossless picture -- the reconstruction is already exact,
  // so every CTB would choose "off" and only the syntax would cost bits
  Enc.Sps.SaoEnabled := Ord(SaoMode and not Lossless);
  // Off, and that is measured. Strong intra smoothing replaces the 64 reference
  // samples of a 32x32 block with a straight line through the two endpoints
  // whenever they are nearly collinear. On a perfectly linear gradient -- the
  // content it exists for -- it measured WORSE: +13.7% rate at qp 6, and
  // -2.90 dB at qp 14. The reason is that the references come from a QUANTISED
  // reconstruction, so the two endpoints carry their own error and the filter
  // propagates it across the whole row, discarding the reconstructed samples in
  // between. It also cannot be switched off per block: the flag is in the SPS
  // and the condition is automatic, so a block it hurts has no escape.
  // Conformance was verified on streams that do exercise it (bpgdec agrees byte
  // for byte), so this is a real trade-off, not a porting bug. Note it is a
  // PERCEPTUAL tool -- it suppresses banding -- and PSNR cannot see that, so a
  // perceptually-driven encoder might well want it on.
  Enc.Sps.StrongIntraSmoothing := 0;
  Enc.Sps.ImplicitRdpcm := Ord(Lossless);

  Enc.Pps.InitQpMinus26 := Qp - 26;
  Enc.Pps.SignDataHiding := 1;
  Enc.Pps.ConstrainedIntraPred := 0;
  Enc.Pps.TransformSkipEnabled := Ord(ScreenMode and not Lossless);
  Enc.Pps.CuQpDeltaEnabled := 0;
  Enc.Pps.DiffCuQpDeltaDepth := 0;
  Enc.Pps.CbQpOffset := 0;
  Enc.Pps.CrQpOffset := 0;
  // cross-component prediction is 4:4:4 only, which in this encoder means the
  // RGB path -- exactly where the three planes are most correlated
  Enc.Pps.CrossComponentPred := Ord((ChromaFormatIdc = 3) and CcpMode);
  Enc.Pps.TransquantBypassEnabled := Ord(Lossless);
  // the decoder sets sign_hidden := 0 whenever cu_transquant_bypass_flag is
  // set, so leaving the PPS flag on would desynchronise the writer
  if Lossless then Enc.Pps.SignDataHiding := 0;
  Enc.Pps.LoopFilterAcrossSlices := 1;
  Enc.Pps.DeblockingControlPresent := 1;
  // in lossless every CU is bypass, and the decoder excludes bypass samples
  // from deblocking anyway, so enabling it only costs the two offsets in the PPS
  Enc.Pps.DeblockingDisabled := Ord(not (DeblockMode and not Lossless));
  Enc.Pps.BetaOffsetDiv2 := 0;
  Enc.Pps.TcOffsetDiv2 := 0;

  Enc.Sh.SliceQpDelta := 0;
  Enc.Sh.SaoLuma := Ord(SaoMode and not Lossless);
  Enc.Sh.SaoChroma := Ord(SaoMode and not Lossless);
  Enc.Sh.LoopFilterAcrossSlices := 1;

  buf_init(Enc.MspsTail);
  buf_init(Enc.PpsRbsp);
  buf_init(Enc.SliceRbsp);
  write_msps(Enc.MspsTail, Enc.Sps);

  // feed the parameter sets through the decoder's own parsers so every derived
  // field matches what the decoder will compute
  buf_init(Full);
  buf_put_byte(Full, Byte(ChromaFormatIdc));
  buf_put_byte(Full, Byte(Width shr 24));  buf_put_byte(Full, Byte(Width shr 16));
  buf_put_byte(Full, Byte(Width shr 8));   buf_put_byte(Full, Byte(Width));
  buf_put_byte(Full, Byte(Height shr 24)); buf_put_byte(Full, Byte(Height shr 16));
  buf_put_byte(Full, Byte(Height shr 8));  buf_put_byte(Full, Byte(Height));
  buf_put_byte(Full, Byte(BitDepth - 8));
  buf_put(Full, Enc.MspsTail.Buf, Enc.MspsTail.Len);
  if init_get_bits8(S^.HEVClc^.gb, Full.Buf, Full.Len) < 0 then Exit(-1);
  if ff_hevc_decode_nal_sps(S) < 0 then Exit(-1);
  buf_free(Full);

  write_pps(Enc.PpsRbsp, Enc.Pps);
  if init_get_bits8(S^.HEVClc^.gb, Enc.PpsRbsp.Buf, Enc.PpsRbsp.Len) < 0 then Exit(-1);
  if ff_hevc_decode_nal_pps(S) < 0 then Exit(-1);

  // the slice header both goes into the output and configures the context
  buf_init(ShBuf);
  write_slice_header(ShBuf, Enc.Sps, Enc.Pps, Enc.Sh);
  S^.nal_unit_type := NAL_IDR_W_RADL;
  S^.temporal_id := 0;
  if init_get_bits8(S^.HEVClc^.gb, ShBuf.Buf, ShBuf.Len) < 0 then Exit(-1);
  if hls_slice_header(S) < 0 then Exit(-1);
  buf_put(Enc.SliceRbsp, ShBuf.Buf, ShBuf.Len);
  buf_free(ShBuf);

  // reconstruction frame and the per-picture tables
  if ff_hevc_set_new_ref(S, S^.frame, 0) < 0 then Exit(-1);
  FillChar(S^.cbf_luma^, S^.sps^.min_tb_width * S^.sps^.min_tb_height, 0);
  FillChar(S^.is_pcm^, (S^.sps^.min_pu_width + 1) * (S^.sps^.min_pu_height + 1), 0);
  FillChar(S^.tab_ct_depth^, S^.sps^.min_cb_width * S^.sps^.min_cb_height, 0);

  Enc.Src := av_frame_alloc;
  if Enc.Src = nil then Exit(-1);
  if frame_get_buffer(Enc.Src, S^.sps^.width, S^.sps^.height,
                      S^.sps^.chroma_format_idc) < 0 then Exit(-1);

  Enc.NCtb := S^.sps^.ctb_width * S^.sps^.ctb_height;
  Result := 0;
end;

procedure bpg_enc_free(var Enc: TBpgEncoder);
begin
  buf_free(Enc.MspsTail);
  buf_free(Enc.PpsRbsp);
  buf_free(Enc.SliceRbsp);
  av_frame_free(Enc.Src);
  hevc_decode_free(@Enc.Ctx);
end;

// ------------------------------------------------------------------

// The exact number of bits the residual coder would emit for one block, got by
// trial-encoding it with a private CABAC encoder and throwing the result away.
// The context states are saved and restored, so nothing observable changes.
function residual_bits(S: PHEVCContext; Coeffs: PInt16;
  Log2Size, ScanIdx, CIdx: Integer): Integer;
var
  Save: array[0 .. HEVC_CONTEXTS - 1] of Byte;
  Buf: TByteBuf;
  E2: TCabacEncoder;
begin
  Move(S^.HEVClc^.cabac_state, Save, SizeOf(Save));
  buf_init(Buf);
  cabac_enc_init(E2, @Buf);
  ff_hevc_hls_residual_coding_enc(S, E2, Coeffs, Log2Size, ScanIdx, CIdx);
  cabac_enc_terminate(E2, 1);
  cabac_enc_finish(E2);
  // The terminating bin and the flush cost a couple of bytes that are not part
  // of the residual, but they are the same for every candidate.
  //
  // Subtracting them was tried: the bias is real -- the overhead cancels
  // between two candidates for the same block but NOT against a candidate with
  // an empty residual, which is charged zero bits -- yet removing it did NOT
  // fix the smooth-content loss it was meant to explain (-7.26% rate for
  // -1.15 dB, essentially unchanged), and its own effect could not be measured
  // cleanly before the session ended. Reverted rather than kept unvalidated.
  // The hypothesis stays open; see task #28.
  Result := Buf.Len * 8;
  buf_free(Buf);
  Move(Save, S^.HEVClc^.cabac_state, SizeOf(Save));
end;

// Last-position trimming, the coefficient-level move the failed block-level
// cbf experiment pointed to. The last significant coefficient in scan order is
// expensive out of proportion: it sets the coded last-position and every
// significance flag on the path to it. When it is small, zeroing it and letting
// the last position move earlier often saves more bits than it costs in error.
//
// Each step is judged on measured bits (a trial encode of the block) and exact
// pixel-domain error, and must win individually; the loop stops at the first
// loss. Returns the number of surviving coefficients; 0 means the residual
// disappeared entirely and the caller signals cbf = 0.
function rdoq_trim_last(var Enc: TBpgEncoder; Coeffs, PreQ: PInt16;
  Log2Size, CIdx, ScanIdx, QpUsed: Integer;
  Pred: PWord; PredStride: Integer; SrcP: PWord; SrcStride: Integer;
  UseDST: Boolean): Integer;
var
  S: PHEVCContext;
  Size, N, PixMax, Iter: Integer;
  scan_x_cg, scan_y_cg, scan_x_off, scan_y_off: PByte;
  LastPos, LastIdx, SaveLev, Nz, I, x_c, y_c, Idx: Integer;
  Res: array[0 .. 32 * 32 - 1] of Int16;
  CurCost, CandCost: Double;
  Lambda: Double;

  // Distortion measured in the TRANSFORM domain: the squared distance between
  // the dequantised levels and the coefficients as they were before
  // quantisation. The inverse transform is skipped entirely, which is what
  // makes this cheap.
  //
  // The HEVC integer transform is only near-orthogonal, so the two domains are
  // related by a scale rather than being equal. That scale was measured rather
  // than derived -- across 4x4 to 32x32 and at 8 and 10 bits it came out as a
  // clean power of two every time, within 1%:
  //
  //   SSD_transform / SSD_pixel = 2^(30 - 2*bitDepth - 2*log2)
  //
  // What is lost is the clipping: the pixel-domain form clamps prediction plus
  // residual to the sample range, and no transform-domain measure can see that.
  // It matters only where the reconstruction would have saturated.
  function cost_of(WithBits: Boolean): Double;
  var
    Ssd, TSsd: Int64;
    XX, YY, DD, Shift: Integer;
  begin
    Move(Coeffs^, Res[0], Size * Size * SizeOf(Int16));
    dequant_block(@Res[0], Log2Size, QpUsed, S^.sps^.bit_depth);

    if RdoqTDomain then
    begin
      TSsd := 0;
      for XX := 0 to Size * Size - 1 do
      begin
        DD := Res[XX] - PreQ[XX];
        TSsd := TSsd + Int64(DD) * DD;
      end;
      Shift := 30 - 2 * S^.sps^.bit_depth - 2 * Log2Size;
      if Shift > 0 then Ssd := SarInt64(TSsd + (Int64(1) shl (Shift - 1)), Shift)
      else if Shift < 0 then Ssd := TSsd shl (-Shift)
      else Ssd := TSsd;
    end
    else
    begin
      if UseDST then
        transform_4x4_luma(@Res[0], S^.sps^.bit_depth)
      else
        idct(Log2Size - 2, @Res[0], Size, S^.sps^.bit_depth);
      Ssd := 0;
      for YY := 0 to Size - 1 do
        for XX := 0 to Size - 1 do
        begin
          DD := av_clip_c(Pred[YY * PredStride + XX] + Res[YY * Size + XX], 0, PixMax) -
                SrcP[YY * SrcStride + XX];
          Ssd := Ssd + Int64(DD) * DD;
        end;
    end;

    Result := Ssd * plane_weight(S, CIdx);
    if WithBits then
      Result := Result + Lambda *
        residual_bits(S, Coeffs, Log2Size, ScanIdx, CIdx);
  end;

begin
  S := @Enc.Ctx;
  Size := 1 shl Log2Size;
  PixMax := (1 shl S^.sps^.bit_depth) - 1;
  Lambda := 0.57 * Exp(((Enc.Qp - 12) / 3.0) * Ln(2.0)) * mean_weight(S);
  enc_scan_tables(Log2Size, ScanIdx, scan_x_cg, scan_y_cg, scan_x_off, scan_y_off);

  CurCost := cost_of(True);
  for Iter := 1 to 8 do
  begin
    // the last significant coefficient in scan order
    LastIdx := -1;
    LastPos := -1;
    for N := 0 to Size * Size - 1 do
    begin
      x_c := (scan_x_cg[N shr 4] shl 2) + scan_x_off[N and 15];
      y_c := (scan_y_cg[N shr 4] shl 2) + scan_y_off[N and 15];
      Idx := y_c * Size + x_c;
      if Coeffs[Idx] <> 0 then
      begin
        LastPos := N;
        LastIdx := Idx;
      end;
    end;
    if LastIdx < 0 then Break;
    // only a level of one is ever worth trimming -- the classic HM rule; a
    // level of two already carries too much signal
    if Abs(Coeffs[LastIdx]) > 1 then Break;

    SaveLev := Coeffs[LastIdx];
    Coeffs[LastIdx] := 0;

    Nz := 0;
    for N := 0 to Size * Size - 1 do
      if Coeffs[N] <> 0 then Inc(Nz);
    if Nz = 0 then
      CandCost := cost_of(False)   // empty block: prediction only, no bits
    else
      CandCost := cost_of(True);

    if CandCost < CurCost then
      CurCost := CandCost
    else
    begin
      Coeffs[LastIdx] := Int16(SaveLev);
      Break;
    end;
    if Nz = 0 then Break;
  end;

  Result := 0;
  for N := 0 to Size * Size - 1 do
    if Coeffs[N] <> 0 then Inc(Result);

  // The same move, no longer restricted to the last position. Trimming only
  // ever reaches the tail of the scan; a level-1 coefficient in the middle of
  // the block is cheaper than the last one but far from free, since it still
  // carries a significance flag, a greater1 flag and a sign. Walking backwards
  // means each decision is taken with the later, more expensive coefficients
  // already settled.
  //
  // Unlike the trim loop this one does NOT stop at the first loss: the
  // coefficients are scattered, so a coefficient that is worth keeping says
  // nothing about the next one.
  if RdoqFull and (Result > 1) then
  begin
    CurCost := cost_of(True);
    for N := Size * Size - 1 downto 0 do
    begin
      x_c := (scan_x_cg[N shr 4] shl 2) + scan_x_off[N and 15];
      y_c := (scan_y_cg[N shr 4] shl 2) + scan_y_off[N and 15];
      Idx := y_c * Size + x_c;

      // Only level 1, and that is a measured choice, not an inherited rule.
      // Offering level N -> N-1 as well was tried and lost: -0.030 dB on
      // average at equal rate, three wins against five losses. The asymmetry is
      // real -- zeroing a level-1 coefficient deletes a whole significance and
      // greater1 chain, while stepping a larger level down by one saves almost
      // nothing (the remainder is Golomb coded) and still costs full
      // quantiser-step distortion.
      if Abs(Coeffs[Idx]) <> 1 then Continue;

      SaveLev := Coeffs[Idx];
      Coeffs[Idx] := 0;
      Nz := 0;
      for I := 0 to Size * Size - 1 do
        if Coeffs[I] <> 0 then Inc(Nz);
      if Nz = 0 then
        CandCost := cost_of(False)
      else
        CandCost := cost_of(True);

      if CandCost < CurCost then
      begin
        CurCost := CandCost;
        if Nz = 0 then Break;
      end
      else
        Coeffs[Idx] := Int16(SaveLev);
    end;

    Result := 0;
    for N := 0 to Size * Size - 1 do
      if Coeffs[N] <> 0 then Inc(Result);
  end;
end;

// The direction the decoder will run its cumulative sum in, or -1 when it will
// not: implicit RDPCM applies to a bypass block predicted exactly horizontally
// (mode 10, sum along rows) or vertically (mode 26, sum down columns).
function rdpcm_mode_of(S: PHEVCContext; CIdx: Integer): Integer;
var
  M: Integer;
begin
  Result := -1;
  if S^.sps^.implicit_rdpcm_enabled_flag = 0 then Exit;
  if S^.HEVClc^.cu.cu_transquant_bypass_flag = 0 then Exit;
  if CIdx = 0 then M := S^.HEVClc^.tu.intra_pred_mode
  else M := S^.HEVClc^.tu.intra_pred_mode_c;
  if M = 10 then Result := 0
  else if M = 26 then Result := 1;
end;

// Inverse of transform_rdpcm: differences instead of the running sum. Taken
// backwards so each difference still sees the original neighbour.
procedure rdpcm_forward(Coeffs: PInt16; Log2Size, Mode: Integer);
var
  X, Y, Size: Integer;
begin
  Size := 1 shl Log2Size;
  if Mode <> 0 then
  begin
    for Y := Size - 1 downto 1 do
      for X := 0 to Size - 1 do
        Coeffs[Y * Size + X] := Int16(Coeffs[Y * Size + X] - Coeffs[(Y - 1) * Size + X]);
  end
  else
  begin
    for Y := 0 to Size - 1 do
      for X := Size - 1 downto 1 do
        Coeffs[Y * Size + X] := Int16(Coeffs[Y * Size + X] - Coeffs[Y * Size + X - 1]);
  end;
end;

// Predicts one transform block into the reconstruction frame, forms the
// residual against the source, transforms and quantises it. Returns the number
// of non-zero coefficients.
function encode_tb(var Enc: TBpgEncoder; X0, Y0, Log2Size, CIdx: Integer;
  Coeffs: PInt16; ScanIdx: Integer; out TSkip: Integer): Integer;
var
  S: PHEVCContext;
  Size, X, Y, HShift, VShift, XP, YP, QpUsed: Integer;
  Rec, SrcP: PWord;
  RecStride, SrcStride: Integer;
  UseDST: Boolean;
  PreQ: array[0 .. 32 * 32 - 1] of Int16;
  Resid, Alt: array[0 .. 15] of Int16;
  AltNz, NormNz, TsShift, I: Integer;
  CostNorm, CostSkip, LambdaT: Double;

  // SSD of the reconstruction against the source plus lambda times the measured
  // bits, for one candidate set of levels
  function tb_cost(C: PInt16; Ts, Nz: Integer): Double;
  var
    W: array[0 .. 15] of Int16;
    XX, YY, DD: Integer;
    Ssd: Int64;
  begin
    if Nz = 0 then
      FillChar(W, SizeOf(W), 0)
    else
    begin
      Move(C^, W[0], 16 * SizeOf(Int16));
      dequant_block(@W[0], 2, QpUsed, S^.sps^.bit_depth);
      if Ts <> 0 then transform_skip(@W[0], 2, S^.sps^.bit_depth)
      else if CIdx = 0 then transform_4x4_luma(@W[0], S^.sps^.bit_depth)
      else idct(0, @W[0], 4, S^.sps^.bit_depth);
    end;
    Ssd := 0;
    for YY := 0 to 3 do
      for XX := 0 to 3 do
      begin
        DD := av_clip_c(Rec[YY * RecStride + XX] + W[YY * 4 + XX],
                        0, (1 shl S^.sps^.bit_depth) - 1) -
              SrcP[YY * SrcStride + XX];
        Ssd := Ssd + Int64(DD) * DD;
      end;
    Result := Ssd * plane_weight(S, CIdx);
    if Nz > 0 then
      Result := Result + LambdaT * (residual_bits(S, C, 2, ScanIdx, CIdx) + 1);
  end;

begin
  S := @Enc.Ctx;
  TSkip := 0;
  Size := 1 shl Log2Size;
  HShift := S^.sps^.hshift[CIdx];
  VShift := S^.sps^.vshift[CIdx];
  XP := X0 shr HShift;
  YP := Y0 shr VShift;

  ff_hevc_set_neighbour_available(S, X0, Y0, Size shl HShift, Size shl VShift);
  intra_pred(S, X0, Y0, Log2Size, CIdx);

  Rec := plane_ptr(S^.frame, CIdx, XP, YP);
  RecStride := plane_stride(S^.frame, CIdx);
  SrcP := plane_ptr(Enc.Src, CIdx, XP, YP);
  SrcStride := plane_stride(Enc.Src, CIdx);

  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
      Coeffs[Y * Size + X] := Int16(SrcP[Y * SrcStride + X] - Rec[Y * RecStride + X]);

  // cross-component prediction: the decoder will add this back, so code only
  // what it cannot predict from the luma residual
  if (CcpPred <> nil) and (CcpScaleCur <> 0) then
    for X := 0 to Size * Size - 1 do
      Coeffs[X] := Int16(Coeffs[X] - SarLongint(CcpScaleCur * CcpPred[X], 3));

  // Lossless: the residual travels as-is. The decoder skips dequantisation and
  // the inverse transform for a bypass block, so the samples in Coeffs are
  // exactly what it will add back to the prediction. Implicit RDPCM means the
  // decoder runs a cumulative sum whenever the prediction is exactly horizontal
  // or vertical, so the encoder writes the differences.
  if Lossless then
  begin
    if rdpcm_mode_of(S, CIdx) >= 0 then
      rdpcm_forward(Coeffs, Log2Size, rdpcm_mode_of(S, CIdx));
    Result := 0;
    for Y := 0 to Size - 1 do
      for X := 0 to Size - 1 do
        if Coeffs[Y * Size + X] <> 0 then Inc(Result);
    Exit;
  end;

  UseDST := (CIdx = 0) and (Log2Size = 2);
  fwd_transform(Coeffs, Log2Size, S^.sps^.bit_depth, UseDST);
  if CIdx = 0 then QpUsed := luma_qp_of(S, Enc.Qp)
  else QpUsed := chroma_qp_of(S, Enc.Qp, CIdx);
  // the pre-quantisation coefficients let the sign hiding pre-pass choose the
  // cheapest level to nudge when the parity is wrong
  Move(Coeffs^, PreQ[0], (1 shl (2 * Log2Size)) * SizeOf(Int16));
  Result := quantize(Coeffs, Log2Size, QpUsed, S^.sps^.bit_depth, True);
  if (Result > 0) and RDOQ_TRIM then
    Result := rdoq_trim_last(Enc, Coeffs, @PreQ[0], Log2Size, CIdx, ScanIdx,
                             QpUsed, Rec, RecStride, SrcP, SrcStride, UseDST);
  if Result > 0 then
    sign_hide_adjust(S, Coeffs, @PreQ[0], Log2Size, ScanIdx, QpUsed);

  // Transform skip, offered only at 4x4 -- the format's own limit, and the size
  // where a residual with sharp edges is genuinely better left alone. The
  // decoder dequantises and then scales by 15 - bitDepth - log2Size, so the
  // encoder scales the residual up by the same amount before quantising it.
  // Both candidates are reconstructed and judged on exact error plus measured
  // bits; the extra flag is charged as one bit to each.
  if (S^.pps^.transform_skip_enabled_flag <> 0) and (Log2Size = 2) and
     (S^.HEVClc^.cu.cu_transquant_bypass_flag = 0) then
  begin
    NormNz := Result;
    LambdaT := 0.57 * Exp(((Enc.Qp - 12) / 3.0) * Ln(2.0)) * mean_weight(S);
    CostNorm := tb_cost(Coeffs, 0, NormNz);

    TsShift := 15 - S^.sps^.bit_depth - 2;
    for I := 0 to 15 do
      Resid[I] := Int16(SrcP[(I shr 2) * SrcStride + (I and 3)] -
                        Rec[(I shr 2) * RecStride + (I and 3)]);
    for I := 0 to 15 do
      Alt[I] := Int16(Resid[I] * (1 shl TsShift));
    AltNz := quantize(@Alt[0], 2, QpUsed, S^.sps^.bit_depth, True);
    if AltNz > 0 then
      sign_hide_adjust(S, @Alt[0], nil, 2, ScanIdx, QpUsed);
    CostSkip := tb_cost(@Alt[0], 1, AltNz);

    if CostSkip < CostNorm then
    begin
      Move(Alt[0], Coeffs^, 16 * SizeOf(Int16));
      Result := AltNz;
      TSkip := 1;
    end;
  end;
end;

// Adds the reconstructed residual of a coded block to the prediction already in
// the frame, using the decoder's own dequantisation and inverse transform.
procedure reconstruct_tb(var Enc: TBpgEncoder; X0, Y0, Log2Size, CIdx: Integer;
  Coeffs: PInt16; TSkip: Integer);
var
  S: PHEVCContext;
  HShift, VShift, QpUsed: Integer;
  Dst: PByte;
begin
  S := @Enc.Ctx;
  HShift := S^.sps^.hshift[CIdx];
  VShift := S^.sps^.vshift[CIdx];
  if Lossless then
  begin
    // neither dequantised nor transformed, exactly as the decoder treats it;
    // only the RDPCM sum, on the same condition the decoder applies
    if rdpcm_mode_of(S, CIdx) >= 0 then
      transform_rdpcm(Coeffs, Log2Size, rdpcm_mode_of(S, CIdx));
  end
  else
  begin
    if CIdx = 0 then QpUsed := luma_qp_of(S, Enc.Qp)
    else QpUsed := chroma_qp_of(S, Enc.Qp, CIdx);
    dequant_block(Coeffs, Log2Size, QpUsed, S^.sps^.bit_depth);
    if TSkip <> 0 then
      transform_skip(Coeffs, Log2Size, S^.sps^.bit_depth)
    else if (CIdx = 0) and (Log2Size = 2) then
      transform_4x4_luma(Coeffs, S^.sps^.bit_depth)
    else
      idct(Log2Size - 2, Coeffs, 1 shl Log2Size, S^.sps^.bit_depth);
  end;
  if (CcpPred <> nil) and (CcpScaleCur <> 0) then
    for HShift := 0 to (1 shl (2 * Log2Size)) - 1 do
      Coeffs[HShift] := Int16(Coeffs[HShift] +
                              SarLongint(CcpScaleCur * CcpPred[HShift], 3));
  HShift := S^.sps^.hshift[CIdx];
  Dst := S^.frame^.Data[CIdx] +
         (Y0 shr VShift) * S^.frame^.Linesize[CIdx] +
         ((X0 shr HShift) shl S^.sps^.pixel_shift);
  transform_add(Log2Size - 2, Dst, Coeffs, S^.frame^.Linesize[CIdx],
                S^.sps^.bit_depth);
end;

// Mirrors the scan selection in hls_transform_unit. Note that the condition is
// on the LUMA transform size for all three components -- the decoder derives
// scan_idx_c inside the same "log2_trafo_size < 4" test, using the luma size,
// not the chroma one.
function scan_for(Mode, Log2LumaSize: Integer): Integer;
begin
  Result := SCAN_DIAG;
  if Log2LumaSize < 4 then
  begin
    if (Mode >= 6) and (Mode <= 14) then Result := SCAN_VERT
    else if (Mode >= 22) and (Mode <= 30) then Result := SCAN_HORIZ;
  end;
end;

// Rate-distortion mode decision.
//
// SAD over the prediction is not enough: the reconstruction is prediction plus
// the QUANTISED residual, and a mode with lower prediction error can still lose
// once quantisation discards its high frequency content. So each candidate is
// reconstructed exactly as the decoder would, and scored on squared error plus
// lambda times the real number of bits, obtained by trial-encoding the residual
// with a private CABAC encoder, plus the cost of signalling the mode itself.
// True cost of what a luma mode does to chroma. intra_chroma_pred_mode is
// coded as 4 ("derived"), so the mode chosen for luma also drives both chroma
// planes; scoring a candidate on luma alone is blind to that, and on smooth
// content chroma carries a large share of the error.
//
// This reconstructs chroma exactly as the encoder will -- predict, residual,
// transform, quantise, sign-hide, dequantise, inverse -- and returns squared
// error against the source, adding the measured residual bits to Bits. An
// earlier attempt used the PREDICTION error instead and measured worse
// everywhere; that was a units mistake, not a refutation: an unquantised
// prediction error sits on a different scale from a reconstruction error, so
// chroma swamped the decision.
function chroma_mode_cost(var Enc: TBpgEncoder; X0, Y0, Log2Size, Mode: Integer;
  var Bits: Int64): Int64;
var
  S: PHEVCContext;
  LC: PHEVCLocalContext;
  C, K, KCount, Log2C, SizeC, HeightC, YC, X, Y, Nz, D, Rec1, QpC, PixMax: Integer;
  PredC, SrcC: PWord;
  PsC, SsC: Integer;
  W2, PreQ2: array[0 .. 32 * 32 - 1] of Int16;
  PlaneSsd: Int64;
  Weight: Double;
begin
  Result := 0;
  S := @Enc.Ctx;
  LC := S^.HEVClc;
  if S^.sps^.chroma_format_idc = 0 then Exit;
  Log2C := Log2Size - S^.sps^.hshift[1];
  if Log2C < 2 then Exit;          // chroma is coded at the parent node
  SizeC := 1 shl Log2C;
  PixMax := (1 shl S^.sps^.bit_depth) - 1;
  if S^.sps^.chroma_format_idc = 2 then KCount := 2 else KCount := 1;
  HeightC := SizeC;

  LC^.tu.intra_pred_mode_c := Mode;
  for C := 1 to 2 do
  begin
    QpC := chroma_qp_of(S, Enc.Qp, C);
    for K := 0 to KCount - 1 do
    begin
      YC := Y0 + (K shl Log2C);
      ff_hevc_set_neighbour_available(S, X0, YC,
        SizeC shl S^.sps^.hshift[C], SizeC shl S^.sps^.vshift[C]);
      intra_pred(S, X0, YC, Log2C, C);
      PredC := plane_ptr(S^.frame, C, X0 shr S^.sps^.hshift[C],
                         YC shr S^.sps^.vshift[C]);
      SrcC := plane_ptr(Enc.Src, C, X0 shr S^.sps^.hshift[C],
                        YC shr S^.sps^.vshift[C]);
      PsC := plane_stride(S^.frame, C);
      SsC := plane_stride(Enc.Src, C);

      for Y := 0 to HeightC - 1 do
        for X := 0 to SizeC - 1 do
          W2[Y * SizeC + X] :=
            Int16(SrcC[Y * SsC + X] - PredC[Y * PsC + X]);

      fwd_transform(@W2[0], Log2C, S^.sps^.bit_depth, False);
      Move(W2, PreQ2, SizeC * SizeC * SizeOf(Int16));
      Nz := quantize(@W2[0], Log2C, QpC, S^.sps^.bit_depth, True);
      if Nz > 0 then
      begin
        sign_hide_adjust(S, @W2[0], @PreQ2[0], Log2C,
          scan_for(Mode, Log2Size), QpC);
        Bits := Bits + residual_bits(S, @W2[0], Log2C,
                                     scan_for(Mode, Log2Size), C);
        dequant_block(@W2[0], Log2C, QpC, S^.sps^.bit_depth);
        idct(Log2C - 2, @W2[0], SizeC, S^.sps^.bit_depth);
      end
      else
        FillChar(W2, SizeC * SizeC * SizeOf(Int16), 0);

      // the same RGB weighting block_ssd uses: a chroma sample error is worth
      // several luma sample errors once the inverse colour transform and the
      // subsampling have spread it
      if S^.sps^.chroma_format_idc = 3 then
        Weight := 1.0
      else
      begin
        if C = 1 then Weight := 3.258 / 3.0 else Weight := 2.476 / 3.0;
        Weight := Weight * (1 shl (S^.sps^.hshift[C] + S^.sps^.vshift[C]));
      end;
      PlaneSsd := 0;
      for Y := 0 to HeightC - 1 do
        for X := 0 to SizeC - 1 do
        begin
          Rec1 := av_clip_c(PredC[Y * PsC + X] + W2[Y * SizeC + X], 0, PixMax);
          D := SrcC[Y * SsC + X] - Rec1;
          PlaneSsd := PlaneSsd + Int64(D) * D;
        end;
      Result := Result + Round(PlaneSsd * Weight);
    end;
  end;
end;

function choose_luma_mode(var Enc: TBpgEncoder; X0, Y0, Log2Size: Integer): Integer;
var
  S: PHEVCContext;
  LC: PHEVCLocalContext;
  Size, I, J, X, Y, Nz, D, Rec1, BestMode: Integer;
  Ssd, Bits: Int64;
  Cost, Best: Double;
  Lambda: Double;
  Pred, SrcP: PWord;
  PredStride, SrcStride, PixMax: Integer;
  Resid: array[0 .. 32 * 32 - 1] of Int16;
  Work: array[0 .. 32 * 32 - 1] of Int16;
  PreQ: array[0 .. 32 * 32 - 1] of Int16;
  candidate: TIntraCandidates;
  IsMpm: Boolean;
  Cands: array[0 .. 15] of Integer;
  NCand, BestRough: Integer;
  Sad: Int64;
  LambdaSad: Double;
  RoughCost: array[0 .. 34] of Int64;
begin
  S := @Enc.Ctx;
  LC := S^.HEVClc;
  Size := 1 shl Log2Size;
  PixMax := (1 shl S^.sps^.bit_depth) - 1;
  Best := 1e30;
  BestMode := INTRA_PLANAR;
  PredStride := plane_stride(S^.frame, 0);
  SrcStride := plane_stride(Enc.Src, 0);
  luma_intra_candidates(S, X0, Y0, candidate);

  // the usual HEVC lambda for an intra picture
  Lambda := 0.57 * Exp(((Enc.Qp - 12) / 3.0) * Ln(2.0));
  // chroma_mode_cost weights the chroma planes for the RGB metric, so this
  // lambda needs the same mean-weight rescale bpg_enc_rd applies -- otherwise
  // the mode search simply spends more bits instead of sharing them better
  if CHROMA_IN_MODE then
  begin
    if S^.sps^.chroma_format_idc = 1 then Lambda := Lambda * 1.941
    else if S^.sps^.chroma_format_idc = 2 then Lambda := Lambda * 1.456;
  end;
  LambdaSad := Sqrt(Lambda);

  // Stage one, the rough decision: predict with every mode and score it on
  // absolute difference plus the cost of signalling the mode. This is cheap --
  // prediction only, no transform, no quantiser -- and its job is just to cut
  // 35 modes down to a handful worth a full reconstruction.
  // Lossless keeps the fixed set. The rough pass scores the SAD of the
  // prediction, which cannot see that implicit RDPCM makes modes 10 and 26 far
  // cheaper than their prediction error suggests -- it would filter them out
  // before the full stage ever weighs them, and the file grew 31% when it did.
  NCand := 0;
  if (not FullModes) or Lossless then
  begin
    for I := 0 to High(cand_modes) do
    begin
      Cands[NCand] := cand_modes[I];
      Inc(NCand);
    end;
  end
  else
  begin
    for I := 0 to 34 do
    begin
      LC^.tu.intra_pred_mode := I;
      ff_hevc_set_neighbour_available(S, X0, Y0, Size, Size);
      intra_pred(S, X0, Y0, Log2Size, 0);
      Pred := plane_ptr(S^.frame, 0, X0, Y0);
      SrcP := plane_ptr(Enc.Src, 0, X0, Y0);
      // SAD, not SATD. Replacing it with a 4x4 Hadamard SATD was tried on the
      // hypothesis that SAD misjudges the low-frequency error of smooth
      // gradients: it did not fix the smooth loss and made it worse at qp 32
      // (-0.89 dB equivalent against -0.26 with SAD), while gaining only
      // ~0.2 dB on gray and noise. Reverted; see task #28.
      Sad := 0;
      for Y := 0 to Size - 1 do
        for X := 0 to Size - 1 do
          Sad := Sad + Abs(SrcP[Y * SrcStride + X] - Pred[Y * PredStride + X]);
      IsMpm := False;
      for J := 0 to 2 do
        if candidate[J] = I then IsMpm := True;
      // lambda is calibrated against SQUARED error; this pass scores absolute
      // error, so the rate term belongs in the same domain -- sqrt(lambda).
      // Mixing the two overweights rate enormously and the search trades away
      // far more quality than it saves: measured -1 dB for -7% rate before
      // this was fixed.
      if IsMpm then RoughCost[I] := Sad + Round(LambdaSad * 2)
      else RoughCost[I] := Sad + Round(LambdaSad * 6);
    end;

    // the best few by rough cost
    for J := 0 to ROUGH_KEEP - 1 do
    begin
      BestRough := -1;
      for I := 0 to 34 do
        if (RoughCost[I] >= 0) and
           ((BestRough < 0) or (RoughCost[I] < RoughCost[BestRough])) then
          BestRough := I;
      if BestRough < 0 then Break;
      Cands[NCand] := BestRough;
      Inc(NCand);
      RoughCost[BestRough] := -1;
    end;

    // and the three most probable modes, always -- this is the whole point
    for J := 0 to 2 do
    begin
      IsMpm := False;
      for I := 0 to NCand - 1 do
        if Cands[I] = candidate[J] then IsMpm := True;
      if not IsMpm then
      begin
        Cands[NCand] := candidate[J];
        Inc(NCand);
      end;
    end;
  end;

  for I := 0 to NCand - 1 do
  begin
    LC^.tu.intra_pred_mode := Cands[I];
    ff_hevc_set_neighbour_available(S, X0, Y0, Size, Size);
    intra_pred(S, X0, Y0, Log2Size, 0);
    Pred := plane_ptr(S^.frame, 0, X0, Y0);
    SrcP := plane_ptr(Enc.Src, 0, X0, Y0);

    for Y := 0 to Size - 1 do
      for X := 0 to Size - 1 do
        Resid[Y * Size + X] :=
          Int16(SrcP[Y * SrcStride + X] - Pred[Y * PredStride + X]);

    // Lossless takes a different path entirely: no transform, no quantiser, and
    // implicit RDPCM on modes 10 and 26. Judging the candidates by a
    // transformed and quantised residual that will never be coded measures the
    // wrong thing -- and it hides the whole point of RDPCM, which is that those
    // two modes are far cheaper than their prediction error suggests. The
    // reconstruction is exact whatever the mode, so the distortion term is zero
    // and the decision is pure bit minimisation.
    if Lossless then
    begin
      Move(Resid, Work, Size * Size * SizeOf(Int16));
      if Cands[I] = 10 then rdpcm_forward(@Work[0], Log2Size, 0)
      else if Cands[I] = 26 then rdpcm_forward(@Work[0], Log2Size, 1);
      Nz := 0;
      for X := 0 to Size * Size - 1 do
        if Work[X] <> 0 then Inc(Nz);

      IsMpm := False;
      for J := 0 to 2 do
        if candidate[J] = Cands[I] then IsMpm := True;
      if Nz > 0 then
        Bits := residual_bits(S, @Work[0], Log2Size,
                              scan_for(Cands[I], Log2Size), 0)
      else
        Bits := 0;
      if IsMpm then Bits := Bits + 3 else Bits := Bits + 6;

      Cost := Lambda * Bits;
      if Cost < Best then
      begin
        Best := Cost;
        BestMode := Cands[I];
      end;
      Continue;
    end;

    Move(Resid, Work, Size * Size * SizeOf(Int16));
    fwd_transform(@Work[0], Log2Size, S^.sps^.bit_depth, (Log2Size = 2));
    Move(Work, PreQ, Size * Size * SizeOf(Int16));
    Nz := quantize(@Work[0], Log2Size, luma_qp_of(S, Enc.Qp), S^.sps^.bit_depth, True);
    if Nz > 0 then
    begin
      sign_hide_adjust(S, @Work[0], @PreQ[0], Log2Size,
        scan_for(Cands[I], Log2Size), luma_qp_of(S, Enc.Qp));
      dequant_block(@Work[0], Log2Size, luma_qp_of(S, Enc.Qp), S^.sps^.bit_depth);
      if Log2Size = 2 then transform_4x4_luma(@Work[0], S^.sps^.bit_depth)
      else idct(Log2Size - 2, @Work[0], Size, S^.sps^.bit_depth);
    end
    else
      FillChar(Work, Size * Size * SizeOf(Int16), 0);

    Ssd := 0;
    for Y := 0 to Size - 1 do
      for X := 0 to Size - 1 do
      begin
        Rec1 := av_clip_c(Pred[Y * PredStride + X] + Work[Y * Size + X], 0, PixMax);
        D := SrcP[Y * SrcStride + X] - Rec1;
        Ssd := Ssd + Int64(D) * D;
      end;

    IsMpm := False;
    for J := 0 to 2 do
      if candidate[J] = Cands[I] then IsMpm := True;
    if Nz > 0 then
    begin
      Move(Resid, Work, Size * Size * SizeOf(Int16));
      fwd_transform(@Work[0], Log2Size, S^.sps^.bit_depth, (Log2Size = 2));
      Move(Work, PreQ, Size * Size * SizeOf(Int16));
      quantize(@Work[0], Log2Size, luma_qp_of(S, Enc.Qp), S^.sps^.bit_depth, True);
      sign_hide_adjust(S, @Work[0], @PreQ[0], Log2Size,
        scan_for(Cands[I], Log2Size), luma_qp_of(S, Enc.Qp));
      Bits := residual_bits(S, @Work[0], Log2Size,
                            scan_for(Cands[I], Log2Size), 0);
    end
    else
      Bits := 0;
    // cbf_luma plus prev_intra_luma_pred_flag and either mpm_idx or the five
    // bit remainder
    if IsMpm then Bits := Bits + 3 else Bits := Bits + 6;

    // Chroma is NOT in this score, and that is a known gap rather than an
    // oversight: intra_chroma_pred_mode is coded as 4 ("derived"), so the luma
    // mode chosen here also drives chroma. Adding the chroma PREDICTION error
    // was tried and measured worse everywhere (smooth -0.28/-0.43 against
    // -0.20/-0.26, n_rgb -0.03 against +0.22) -- but that test was itself
    // flawed: it mixes an unquantised prediction error for chroma with a
    // reconstruction error for luma, and the two are on different scales, so
    // chroma dominates the decision. A fair test has to reconstruct chroma per
    // candidate, which costs a full encode of both chroma blocks per mode. The
    // hypothesis is therefore NOT refuted, only untested. See task #28.
    // Chroma distortion enters unweighted, and that is a measured choice.
    // Lambda is tied to the luma quantiser while chroma uses its own, which the
    // format's table holds below luma above qp 30, so the textbook combination
    // scales the chroma part by 2^((qpL - qpC)/3). That was implemented and
    // measured: it helps synthetic smooth content (+0.15 dB at qp 32, on BOTH
    // axes) but loses on real photographs (-0.099 dB equivalent at qp 34).
    // The likely reason is that this encoder is judged on RGB PSNR, which
    // weights the three channels equally, while the textbook weight optimises a
    // YCbCr-domain cost -- the two do not agree. Reverted; see task #28.
    if CHROMA_IN_MODE then
      Ssd := Ssd + chroma_mode_cost(Enc, X0, Y0, Log2Size, Cands[I], Bits);

    Cost := Ssd + Lambda * Bits;
    if Cost < Best then
    begin
      Best := Cost;
      BestMode := Cands[I];
    end;
  end;

  Result := BestMode;
end;

// The scale the decoder will apply, chosen by a least-squares fit of the chroma
// residual against the reconstructed luma residual and snapped to the values the
// syntax can carry: 0, +-1, +-2, +-4, +-8, in eighths. Returning 0 turns the
// prediction off for that plane, which the writer signals in one bin.
function ccp_choose_scale(Chroma, Luma: PInt16; N: Integer): Integer;
const
  allowed: array[0..3] of Integer = (1, 2, 4, 8);
var
  I, Best, K: Integer;
  Num, Den: Int64;
  A, D, BestD: Double;
begin
  Result := 0;
  Num := 0;
  Den := 0;
  for I := 0 to N - 1 do
  begin
    Num := Num + Int64(Chroma[I]) * Luma[I];
    Den := Den + Int64(Luma[I]) * Luma[I];
  end;
  if Den = 0 then Exit;
  A := 8.0 * Num / Den;
  if Abs(A) < 0.5 then Exit;
  Best := 0;
  BestD := 1e30;
  for K := 0 to 3 do
  begin
    D := Abs(Abs(A) - allowed[K]);
    if D < BestD then
    begin
      BestD := D;
      Best := allowed[K];
    end;
  end;
  if A < 0 then Result := -Best else Result := Best;
end;

// One leaf of the transform tree: luma, then the chroma blocks, then the coded
// block flags, then the residuals. The cbf values have to be written before any
// residual, so all the blocks are encoded into buffers first.
procedure encode_tt_leaf(var Enc: TBpgEncoder;
  X0, Y0, Log2TrafoSize, TrafoDepth: Integer);
var
  S: PHEVCContext;
  LC: PHEVCLocalContext;
  Log2C, CbCount, K, YC, Mode: Integer;
  nzL: Integer;
  nzCb, nzCr: array[0..1] of Integer;
  CoefL: array[0 .. 32 * 32 - 1] of Int16;
  CoefCb, CoefCr: array[0 .. 2 * 32 * 32 - 1] of Int16;
  Scratch: array[0 .. 32 * 32 - 1] of Int16;
  HasChroma: Boolean;
  tsL: Integer;
  tsCb, tsCr: array[0..1] of Integer;
  LumaRes: array[0 .. 32 * 32 - 1] of Int16;
  Probe: array[0 .. 32 * 32 - 1] of Int16;
  CcpScale: array[0..1] of Integer;
  tsProbe, C, nzProbe, nzTry: Integer;
  BitsPlain, BitsCcp: Integer;
  Try_: array[0 .. 32 * 32 - 1] of Int16;
  UseCcp: Boolean;
begin
  S := @Enc.Ctx;
  LC := S^.HEVClc;
  Mode := LC^.tu.intra_pred_mode;
  HasChroma := S^.sps^.chroma_format_idc <> 0;
  Log2C := Log2TrafoSize - S^.sps^.hshift[1];
  if S^.sps^.chroma_format_idc = 2 then CbCount := 2 else CbCount := 1;

  FillChar(CoefL, SizeOf(CoefL), 0);
  FillChar(CoefCb, SizeOf(CoefCb), 0);
  FillChar(CoefCr, SizeOf(CoefCr), 0);
  tsL := 0;
  for K := 0 to 1 do
  begin
    tsCb[K] := 0;
    tsCr[K] := 0;
  end;

  nzL := encode_tb(Enc, X0, Y0, Log2TrafoSize, 0, @CoefL[0],
    scan_for(Mode, Log2TrafoSize), tsL);
  if nzL > 0 then
  begin
    Move(CoefL[0], Scratch[0], (1 shl (2 * Log2TrafoSize)) * SizeOf(Int16));
    reconstruct_tb(Enc, X0, Y0, Log2TrafoSize, 0, @Scratch[0], tsL);
    // reconstruct_tb leaves the reconstructed luma residual in Scratch, which
    // is exactly what the decoder will cross-predict chroma from
    Move(Scratch[0], LumaRes[0], (1 shl (2 * Log2TrafoSize)) * SizeOf(Int16));
  end;
  UseCcp := (S^.pps^.cross_component_prediction_enabled_flag <> 0) and
            (nzL > 0) and (S^.sps^.chroma_format_idc = 3) and
            (LC^.tu.chroma_mode_c = 4);
  CcpScale[0] := 0;
  CcpScale[1] := 0;
  for K := 0 to 1 do
  begin
    nzCb[K] := 0;
    nzCr[K] := 0;
  end;
  if HasChroma then
  begin
    for C := 1 to 2 do
      for K := 0 to CbCount - 1 do
      begin
        YC := Y0 + (K shl Log2C);
        // pick the scale from the plain residual first, then encode with it
        CcpPred := nil;
        CcpScaleCur := 0;
        if UseCcp then
        begin
          // the plain residual, both to fit the scale against and to compare
          // with -- a least-squares fit says how well luma predicts chroma, not
          // whether coding the scale pays for itself
          nzProbe := encode_tb(Enc, X0, YC, Log2C, C, @Probe[0],
            scan_for(Mode, Log2TrafoSize), tsProbe);
          if nzProbe > 0 then
            BitsPlain := residual_bits(S, @Probe[0], Log2C,
                                       scan_for(Mode, Log2TrafoSize), C)
          else
            BitsPlain := 0;

          CcpScale[C - 1] := ccp_choose_scale(@Probe[0], @LumaRes[0],
                                              1 shl (2 * Log2C));
          if CcpScale[C - 1] <> 0 then
          begin
            CcpPred := @LumaRes[0];
            CcpScaleCur := CcpScale[C - 1];
            nzTry := encode_tb(Enc, X0, YC, Log2C, C, @Try_[0],
              scan_for(Mode, Log2TrafoSize), tsProbe);
            if nzTry > 0 then
              BitsCcp := residual_bits(S, @Try_[0], Log2C,
                                       scan_for(Mode, Log2TrafoSize), C)
            else
              BitsCcp := 0;
            // the scale itself costs a few bins; charge it and only keep the
            // prediction when it still comes out ahead
            if BitsCcp + 6 >= BitsPlain then CcpScale[C - 1] := 0;
          end;
          CcpPred := @LumaRes[0];
          CcpScaleCur := CcpScale[C - 1];
        end;
        if C = 1 then
        begin
          nzCb[K] := encode_tb(Enc, X0, YC, Log2C, 1, @CoefCb[K * 32 * 32],
            scan_for(Mode, Log2TrafoSize), tsCb[K]);
          if (nzCb[K] > 0) or (CcpScaleCur <> 0) then
          begin
            Move(CoefCb[K * 32 * 32], Scratch[0], (1 shl (2 * Log2C)) * SizeOf(Int16));
            if nzCb[K] = 0 then
              FillChar(Scratch[0], (1 shl (2 * Log2C)) * SizeOf(Int16), 0);
            reconstruct_tb(Enc, X0, YC, Log2C, 1, @Scratch[0], tsCb[K]);
          end;
        end
        else
        begin
          nzCr[K] := encode_tb(Enc, X0, YC, Log2C, 2, @CoefCr[K * 32 * 32],
            scan_for(Mode, Log2TrafoSize), tsCr[K]);
          if (nzCr[K] > 0) or (CcpScaleCur <> 0) then
          begin
            Move(CoefCr[K * 32 * 32], Scratch[0], (1 shl (2 * Log2C)) * SizeOf(Int16));
            if nzCr[K] = 0 then
              FillChar(Scratch[0], (1 shl (2 * Log2C)) * SizeOf(Int16), 0);
            reconstruct_tb(Enc, X0, YC, Log2C, 2, @Scratch[0], tsCr[K]);
          end;
        end;
        CcpPred := nil;
        CcpScaleCur := 0;
      end;
  end;

  if HasChroma then
  begin
    enc_cbf_cb_cr(S, Enc.E, TrafoDepth, Ord(nzCb[0] > 0));
    if CbCount = 2 then enc_cbf_cb_cr(S, Enc.E, TrafoDepth, Ord(nzCb[1] > 0));
    enc_cbf_cb_cr(S, Enc.E, TrafoDepth, Ord(nzCr[0] > 0));
    if CbCount = 2 then enc_cbf_cb_cr(S, Enc.E, TrafoDepth, Ord(nzCr[1] > 0));
  end;
  enc_cbf_luma(S, Enc.E, TrafoDepth, Ord(nzL > 0));

  if nzL > 0 then
    ff_hevc_hls_residual_coding_enc(S, Enc.E, @CoefL[0], Log2TrafoSize,
      scan_for(Mode, Log2TrafoSize), 0, tsL);
  if UseCcp then enc_cross_comp_pred(S, Enc.E, 0, CcpScale[0]);
  for K := 0 to CbCount - 1 do
    if nzCb[K] > 0 then
      ff_hevc_hls_residual_coding_enc(S, Enc.E, @CoefCb[K * 32 * 32], Log2C,
        scan_for(Mode, Log2TrafoSize), 1, tsCb[K]);
  if UseCcp then enc_cross_comp_pred(S, Enc.E, 1, CcpScale[1]);
  for K := 0 to CbCount - 1 do
    if nzCr[K] > 0 then
      ff_hevc_hls_residual_coding_enc(S, Enc.E, @CoefCr[K * 32 * 32], Log2C,
        scan_for(Mode, Log2TrafoSize), 2, tsCr[K]);
end;

// The one transform-tree shape the format builds differently: an 8x8 luma node
// split into four 4x4 blocks. Chroma cannot follow, because a 4x4 chroma block
// would become 2x2, which the format does not have. So chroma stays whole at
// the parent -- its coded-block flags are signalled at the parent node, and its
// residual is written once, after the LAST luma child (blk_idx 3). Everything
// about the chroma half is what a leaf at 8x8 would have done; only the luma
// half is split, and the four children carry no chroma syntax of their own.
procedure encode_tt_split_min(var Enc: TBpgEncoder;
  X0, Y0, TrafoDepth: Integer);
var
  S: PHEVCContext;
  LC: PHEVCLocalContext;
  CbCount, K, YC, Mode, B, BX, BY: Integer;
  nzCb, nzCr: array[0..1] of Integer;
  tsCb, tsCr: array[0..1] of Integer;
  nzL, tsL: array[0..3] of Integer;
  CoefL: array[0 .. 4 * 16 - 1] of Int16;
  CoefCb, CoefCr: array[0 .. 2 * 32 * 32 - 1] of Int16;
  Scratch: array[0 .. 32 * 32 - 1] of Int16;
  HasChroma: Boolean;
begin
  S := @Enc.Ctx;
  LC := S^.HEVClc;
  Mode := LC^.tu.intra_pred_mode;
  HasChroma := S^.sps^.chroma_format_idc <> 0;
  if S^.sps^.chroma_format_idc = 2 then CbCount := 2 else CbCount := 1;

  FillChar(CoefL, SizeOf(CoefL), 0);
  FillChar(CoefCb, SizeOf(CoefCb), 0);
  FillChar(CoefCr, SizeOf(CoefCr), 0);
  for K := 0 to 1 do
  begin
    nzCb[K] := 0; nzCr[K] := 0; tsCb[K] := 0; tsCr[K] := 0;
  end;

  // chroma first, so its coded-block flags are known before they are written
  if HasChroma then
    for K := 0 to CbCount - 1 do
    begin
      YC := Y0 + (K shl 2);
      nzCb[K] := encode_tb(Enc, X0, YC, 2, 1, @CoefCb[K * 32 * 32],
        scan_for(Mode, 2), tsCb[K]);
      if nzCb[K] > 0 then
      begin
        Move(CoefCb[K * 32 * 32], Scratch[0], 16 * SizeOf(Int16));
        reconstruct_tb(Enc, X0, YC, 2, 1, @Scratch[0], tsCb[K]);
      end;
      nzCr[K] := encode_tb(Enc, X0, YC, 2, 2, @CoefCr[K * 32 * 32],
        scan_for(Mode, 2), tsCr[K]);
      if nzCr[K] > 0 then
      begin
        Move(CoefCr[K * 32 * 32], Scratch[0], 16 * SizeOf(Int16));
        reconstruct_tb(Enc, X0, YC, 2, 2, @Scratch[0], tsCr[K]);
      end;
    end;

  if HasChroma then
  begin
    enc_cbf_cb_cr(S, Enc.E, TrafoDepth, Ord(nzCb[0] > 0));
    if CbCount = 2 then enc_cbf_cb_cr(S, Enc.E, TrafoDepth, Ord(nzCb[1] > 0));
    enc_cbf_cb_cr(S, Enc.E, TrafoDepth, Ord(nzCr[0] > 0));
    if CbCount = 2 then enc_cbf_cb_cr(S, Enc.E, TrafoDepth, Ord(nzCr[1] > 0));
  end;

  // the four luma children, each luma-only
  for B := 0 to 3 do
  begin
    BX := X0 + ((B and 1) shl 2);
    BY := Y0 + ((B shr 1) shl 2);
    nzL[B] := encode_tb(Enc, BX, BY, 2, 0, @CoefL[B * 16],
      scan_for(Mode, 2), tsL[B]);
    if nzL[B] > 0 then
    begin
      Move(CoefL[B * 16], Scratch[0], 16 * SizeOf(Int16));
      reconstruct_tb(Enc, BX, BY, 2, 0, @Scratch[0], tsL[B]);
    end;
    enc_cbf_luma(S, Enc.E, TrafoDepth + 1, Ord(nzL[B] > 0));
    if nzL[B] > 0 then
      ff_hevc_hls_residual_coding_enc(S, Enc.E, @CoefL[B * 16], 2,
        scan_for(Mode, 2), 0, tsL[B]);

    // chroma rides along with the last child
    if (B = 3) and HasChroma then
    begin
      for K := 0 to CbCount - 1 do
        if nzCb[K] > 0 then
          ff_hevc_hls_residual_coding_enc(S, Enc.E, @CoefCb[K * 32 * 32], 2,
            scan_for(Mode, 2), 1, tsCb[K]);
      for K := 0 to CbCount - 1 do
        if nzCr[K] > 0 then
          ff_hevc_hls_residual_coding_enc(S, Enc.E, @CoefCr[K * 32 * 32], 2,
            scan_for(Mode, 2), 2, tsCr[K]);
    end;
  end;
end;

procedure encode_transform_node(var Enc: TBpgEncoder;
  X0, Y0, Log2CbSize, Log2TrafoSize, TrafoDepth, ForceSplit: Integer);
var
  S: PHEVCContext;
  FlagPresent, DoSplit: Boolean;
  Half: Integer;
begin
  S := @Enc.Ctx;
  // intra_split_flag is always 0 here, so the presence condition reduces to
  FlagPresent := (Log2TrafoSize <= Integer(S^.sps^.log2_max_trafo_size)) and
                 (Log2TrafoSize > S^.sps^.log2_min_tb_size) and
                 (TrafoDepth < S^.sps^.max_transform_hierarchy_depth_intra);

  if not FlagPresent then
    DoSplit := False    // inferred: our CU never exceeds the max transform size
  else if ForceSplit >= 0 then
    DoSplit := ForceSplit <> 0
  else if Assigned(enc_tu_split_hook) and (Log2TrafoSize > 2) then
    DoSplit := enc_tu_split_hook(Enc, X0, Y0, Log2CbSize, Log2TrafoSize, TrafoDepth)
  else
    DoSplit := False;   // the plain encoder, and anything at 8x8 or below

  if FlagPresent then
    enc_split_transform_flag(S, Enc.E, Log2TrafoSize, Ord(DoSplit));

  if DoSplit and (Log2TrafoSize = 3) and (S^.sps^.chroma_format_idc <> 3) then
  begin
    // the 8x8 -> 4x4 split, where chroma stays at the parent
    encode_tt_split_min(Enc, X0, Y0, TrafoDepth);
  end
  else if DoSplit then
  begin
    // A chroma cbf at a non-leaf node is not a claim about coefficients; it
    // only says "each child codes its own flag". Writing 1 is always legal and
    // costs at most a few bins when the whole subtree's chroma is zero, which
    // the rate-distortion trial sees and charges for. The 4:2:2 second flag is
    // absent at a split node unless log2 = 3, which we never split.
    if S^.sps^.chroma_format_idc <> 0 then
    begin
      enc_cbf_cb_cr(S, Enc.E, TrafoDepth, 1);
      enc_cbf_cb_cr(S, Enc.E, TrafoDepth, 1);
    end;
    Half := 1 shl (Log2TrafoSize - 1);
    encode_transform_node(Enc, X0, Y0, Log2CbSize, Log2TrafoSize - 1, TrafoDepth + 1, -1);
    encode_transform_node(Enc, X0 + Half, Y0, Log2CbSize, Log2TrafoSize - 1, TrafoDepth + 1, -1);
    encode_transform_node(Enc, X0, Y0 + Half, Log2CbSize, Log2TrafoSize - 1, TrafoDepth + 1, -1);
    encode_transform_node(Enc, X0 + Half, Y0 + Half, Log2CbSize, Log2TrafoSize - 1, TrafoDepth + 1, -1);
  end
  else
    encode_tt_leaf(Enc, X0, Y0, Log2TrafoSize, TrafoDepth);
end;

// A coding unit at the minimum size may split its PREDICTION into four, each
// quarter carrying its own intra mode -- PART_NxN. The transform tree is then
// forced to split at depth 0 without a flag, so the four 4x4 luma blocks line up
// with the four prediction quarters, and chroma stays whole at the parent
// exactly as in encode_tt_split_min. Chroma follows the FIRST quarter's mode,
// which is what intra_prediction_unit derives for anything but 4:4:4.
//
// Two phases, because the decisions have to run in reconstruction order while
// the syntax has to come out in the order the format fixes. Phase one chooses,
// derives and reconstructs each quarter in turn -- each quarter's mode search
// needs its predecessor already reconstructed, and each call to
// luma_intra_pred_mode_enc updates tab_ipm so the next quarter's
// most-probable-mode list is right. Phase two writes: part_mode, then all four
// prev_intra_luma_pred_flag, then all four payloads, then chroma.
procedure encode_cu_nxn(var Enc: TBpgEncoder; X0, Y0, Log2CbSize: Integer);
var
  S: PHEVCContext;
  LC: PHEVCLocalContext;
  B, K, CbCount, Half, BX, BY, YC: Integer;
  min_cb_width, x_cb, y_cb, Length_: Integer;
  Modes: array[0..3] of Integer;
  PrevFlag, MpmIdx, RemMode: array[0..3] of Integer;
  nzL, tsL: array[0..3] of Integer;
  nzCb, nzCr, tsCb, tsCr: array[0..1] of Integer;
  CoefL: array[0 .. 4 * 16 - 1] of Int16;
  CoefCb, CoefCr: array[0 .. 2 * 32 * 32 - 1] of Int16;
  Scratch: array[0 .. 32 * 32 - 1] of Int16;
  HasChroma: Boolean;
begin
  S := @Enc.Ctx;
  LC := S^.HEVClc;
  Half := (1 shl Log2CbSize) shr 1;
  HasChroma := S^.sps^.chroma_format_idc <> 0;
  if S^.sps^.chroma_format_idc = 2 then CbCount := 2 else CbCount := 1;

  // the same coding-unit state the 2Nx2N path sets up. Leaving it stale was the
  // bug that made this path produce a perfectly conformant stream decoding to
  // garbage: ff_hevc_set_neighbour_available reads cu.x/cu.y, so every
  // prediction in the unit was resolved against the PREVIOUS unit's position.
  LC^.cu.x := X0;
  LC^.cu.y := Y0;
  LC^.cu.pred_mode := MODE_INTRA;
  LC^.cu.part_mode := PART_NxN;
  LC^.cu.intra_split_flag := 1;
  LC^.cu.pcm_flag := 0;
  LC^.cu.cu_transquant_bypass_flag := 0;
  LC^.cu.max_trafo_depth := 0;
  LC^.tu.cross_pf := 0;
  LC^.tu.is_cu_qp_delta_coded := 1;
  LC^.tu.is_cu_chroma_qp_offset_coded := 1;

  min_cb_width := S^.sps^.min_cb_width;
  x_cb := X0 shr S^.sps^.log2_min_cb_size;
  y_cb := Y0 shr S^.sps^.log2_min_cb_size;
  Length_ := (1 shl Log2CbSize) shr S^.sps^.log2_min_cb_size;
  for K := 0 to Length_ - 1 do
    FillChar(S^.skip_flag[(y_cb + K) * min_cb_width + x_cb], Length_, 0);
  // and the coding tree depth, for the same reason as in the 2Nx2N path:
  // split_cu_flag takes its context from the neighbours' depth. Forgetting it
  // here produced a perfectly conformant stream that decoded to noise -- both
  // decoders agreed with each other and disagreed with the source.
  for K := 0 to Length_ - 1 do
    FillChar(S^.tab_ct_depth[(y_cb + K) * min_cb_width + x_cb], Length_,
             Byte(LC^.ct_depth));

  if S^.pps^.transquant_bypass_enable_flag <> 0 then
    enc_cu_transquant_bypass_flag(S, Enc.E, 0);

  FillChar(CoefL, SizeOf(CoefL), 0);
  FillChar(CoefCb, SizeOf(CoefCb), 0);
  FillChar(CoefCr, SizeOf(CoefCr), 0);
  for K := 0 to 1 do
  begin
    nzCb[K] := 0; nzCr[K] := 0; tsCb[K] := 0; tsCr[K] := 0;
  end;

  // phase one: choose, derive and reconstruct each quarter in order
  for B := 0 to 3 do
  begin
    BX := X0 + ((B and 1) * Half);
    BY := Y0 + ((B shr 1) * Half);
    Modes[B] := choose_luma_mode(Enc, BX, BY, Log2CbSize - 1);
    luma_intra_pred_mode_enc(S, BX, BY, Half, Modes[B],
      PrevFlag[B], MpmIdx[B], RemMode[B]);
    LC^.pu.intra_pred_mode[B] := Byte(Modes[B]);
    LC^.tu.intra_pred_mode := Modes[B];
    nzL[B] := encode_tb(Enc, BX, BY, Log2CbSize - 1, 0, @CoefL[B * 16],
      scan_for(Modes[B], Log2CbSize - 1), tsL[B]);
    if nzL[B] > 0 then
    begin
      Move(CoefL[B * 16], Scratch[0], 16 * SizeOf(Int16));
      reconstruct_tb(Enc, BX, BY, Log2CbSize - 1, 0, @Scratch[0], tsL[B]);
    end;
  end;

  // chroma, whole, following the first quarter
  if HasChroma then
  begin
    LC^.pu.intra_pred_mode_c[0] := Byte(Modes[0]);
    LC^.tu.intra_pred_mode_c := Modes[0];
    LC^.pu.chroma_mode_c[0] := 4;
    LC^.tu.chroma_mode_c := 4;
    for K := 0 to CbCount - 1 do
    begin
      YC := Y0 + (K shl (Log2CbSize - 1));
      nzCb[K] := encode_tb(Enc, X0, YC, Log2CbSize - 1, 1, @CoefCb[K * 32 * 32],
        scan_for(Modes[0], Log2CbSize - 1), tsCb[K]);
      if nzCb[K] > 0 then
      begin
        Move(CoefCb[K * 32 * 32], Scratch[0], 16 * SizeOf(Int16));
        reconstruct_tb(Enc, X0, YC, Log2CbSize - 1, 1, @Scratch[0], tsCb[K]);
      end;
      nzCr[K] := encode_tb(Enc, X0, YC, Log2CbSize - 1, 2, @CoefCr[K * 32 * 32],
        scan_for(Modes[0], Log2CbSize - 1), tsCr[K]);
      if nzCr[K] > 0 then
      begin
        Move(CoefCr[K * 32 * 32], Scratch[0], 16 * SizeOf(Int16));
        reconstruct_tb(Enc, X0, YC, Log2CbSize - 1, 2, @Scratch[0], tsCr[K]);
      end;
    end;
  end;

  // phase two: the syntax, in the order the format fixes
  enc_part_mode_intra(S, Enc.E, Log2CbSize, PART_NxN);
  for B := 0 to 3 do
    enc_prev_intra_luma_pred_flag(S, Enc.E, PrevFlag[B]);
  for B := 0 to 3 do
    if PrevFlag[B] <> 0 then enc_mpm_idx(S, Enc.E, MpmIdx[B])
    else enc_rem_intra_luma_pred_mode(S, Enc.E, RemMode[B]);
  if HasChroma then
    enc_intra_chroma_pred_mode(S, Enc.E, 4);

  // transform tree: split inferred at depth 0, chroma cbf at the parent
  if HasChroma then
  begin
    enc_cbf_cb_cr(S, Enc.E, 0, Ord(nzCb[0] > 0));
    if CbCount = 2 then enc_cbf_cb_cr(S, Enc.E, 0, Ord(nzCb[1] > 0));
    enc_cbf_cb_cr(S, Enc.E, 0, Ord(nzCr[0] > 0));
    if CbCount = 2 then enc_cbf_cb_cr(S, Enc.E, 0, Ord(nzCr[1] > 0));
  end;

  for B := 0 to 3 do
  begin
    LC^.tu.intra_pred_mode := Modes[B];
    enc_cbf_luma(S, Enc.E, 1, Ord(nzL[B] > 0));
    if nzL[B] > 0 then
      ff_hevc_hls_residual_coding_enc(S, Enc.E, @CoefL[B * 16], Log2CbSize - 1,
        scan_for(Modes[B], Log2CbSize - 1), 0, tsL[B]);
    if (B = 3) and HasChroma then
    begin
      for K := 0 to CbCount - 1 do
        if nzCb[K] > 0 then
          ff_hevc_hls_residual_coding_enc(S, Enc.E, @CoefCb[K * 32 * 32],
            Log2CbSize - 1, scan_for(Modes[0], Log2CbSize - 1), 1, tsCb[K]);
      for K := 0 to CbCount - 1 do
        if nzCr[K] > 0 then
          ff_hevc_hls_residual_coding_enc(S, Enc.E, @CoefCr[K * 32 * 32],
            Log2CbSize - 1, scan_for(Modes[0], Log2CbSize - 1), 2, tsCr[K]);
    end;
  end;
end;

procedure encode_cu_2nx2n(var Enc: TBpgEncoder; X0, Y0, Log2CbSize: Integer);
var
  S: PHEVCContext;
  LC: PHEVCLocalContext;
  Mode, PrevFlag, MpmIdx, RemMode: Integer;
  Y, Length_, min_cb_width, x_cb, y_cb: Integer;
  HasChroma: Boolean;
begin
  S := @Enc.Ctx;
  LC := S^.HEVClc;
  LC^.cu.x := X0;
  LC^.cu.y := Y0;
  LC^.cu.pred_mode := MODE_INTRA;
  LC^.cu.part_mode := PART_2Nx2N;
  LC^.cu.intra_split_flag := 0;
  LC^.cu.pcm_flag := 0;
  LC^.cu.cu_transquant_bypass_flag := Ord(Lossless);
  LC^.cu.max_trafo_depth := 0;
  LC^.tu.cross_pf := 0;
  LC^.tu.is_cu_qp_delta_coded := 1;
  LC^.tu.is_cu_chroma_qp_offset_coded := 1;

  min_cb_width := S^.sps^.min_cb_width;
  x_cb := X0 shr S^.sps^.log2_min_cb_size;
  y_cb := Y0 shr S^.sps^.log2_min_cb_size;
  Length_ := (1 shl Log2CbSize) shr S^.sps^.log2_min_cb_size;
  for Y := 0 to Length_ - 1 do
    FillChar(S^.skip_flag[(y_cb + Y) * min_cb_width + x_cb], Length_, 0);
  // the decoder's set_ct_depth: split_cu_flag takes its context from the
  // neighbours' coding tree depth, so the table has to be maintained here or
  // encoder and decoder pick different contexts from the second CTU onwards
  for Y := 0 to Length_ - 1 do
    FillChar(S^.tab_ct_depth[(y_cb + Y) * min_cb_width + x_cb], Length_,
             Byte(LC^.ct_depth));

  // cu_transquant_bypass_flag opens the coding unit whenever the PPS allows it,
  // ahead of every other element
  if S^.pps^.transquant_bypass_enable_flag <> 0 then
    enc_cu_transquant_bypass_flag(S, Enc.E, LC^.cu.cu_transquant_bypass_flag);

  // part_mode is only present at the minimum coding block size
  if Log2CbSize = S^.sps^.log2_min_cb_size then
    enc_part_mode_intra(S, Enc.E, Log2CbSize, PART_2Nx2N);

  Mode := choose_luma_mode(Enc, X0, Y0, Log2CbSize);
  luma_intra_pred_mode_enc(S, X0, Y0, 1 shl Log2CbSize, Mode,
    PrevFlag, MpmIdx, RemMode);
  enc_prev_intra_luma_pred_flag(S, Enc.E, PrevFlag);
  if PrevFlag <> 0 then
    enc_mpm_idx(S, Enc.E, MpmIdx)
  else
    enc_rem_intra_luma_pred_mode(S, Enc.E, RemMode);

  LC^.pu.intra_pred_mode[0] := Byte(Mode);
  LC^.tu.intra_pred_mode := Mode;

  HasChroma := S^.sps^.chroma_format_idc <> 0;
  if HasChroma then
  begin
    // chroma mode 4 is "derived", i.e. the same as luma
    enc_intra_chroma_pred_mode(S, Enc.E, 4);
    LC^.pu.chroma_mode_c[0] := 4;
    LC^.pu.intra_pred_mode_c[0] := Byte(Mode);
    LC^.tu.chroma_mode_c := 4;
    LC^.tu.intra_pred_mode_c := Mode;
  end;

  encode_transform_node(Enc, X0, Y0, Log2CbSize, Log2CbSize, 0, -1);
end;

procedure encode_coding_unit_part(var Enc: TBpgEncoder;
  X0, Y0, Log2CbSize, ForcePart: Integer);
begin
  if ForcePart = 1 then encode_cu_nxn(Enc, X0, Y0, Log2CbSize)
  else encode_cu_2nx2n(Enc, X0, Y0, Log2CbSize);
end;

procedure encode_coding_unit(var Enc: TBpgEncoder; X0, Y0, Log2CbSize: Integer);
var
  UseNxN: Boolean;
begin
  // PART_NxN exists only at the minimum coding block size, and only where the
  // quarters are still whole transform blocks
  UseNxN := False;
  if Assigned(enc_cu_part_hook) and
     (Log2CbSize = Enc.Ctx.sps^.log2_min_cb_size) and
     (Log2CbSize - 1 >= Enc.Ctx.sps^.log2_min_tb_size) and
     (Enc.Ctx.sps^.chroma_format_idc <> 3) and (not Lossless) then
    UseNxN := enc_cu_part_hook(Enc, X0, Y0, Log2CbSize);
  encode_coding_unit_part(Enc, X0, Y0, Log2CbSize, Ord(UseNxN));
end;

function encode_leaf_tail(var Enc: TBpgEncoder; X0, Y0, cb_size: Integer): Integer;
var
  S: PHEVCContext;
begin
  S := @Enc.Ctx;
  if ((((X0 + cb_size) mod (1 shl S^.sps^.log2_ctb_size)) = 0) or
      (X0 + cb_size >= S^.sps^.width)) and
     ((((Y0 + cb_size) mod (1 shl S^.sps^.log2_ctb_size)) = 0) or
      (Y0 + cb_size >= S^.sps^.height)) then
  begin
    Inc(Enc.CtbDone);
    enc_end_of_slice_flag(S, Enc.E, Ord(Enc.CtbDone >= Enc.NCtb));
    Result := Ord(Enc.CtbDone < Enc.NCtb);
  end
  else
    Result := 1;
end;

function encode_quadtree(var Enc: TBpgEncoder;
  X0, Y0, Log2CbSize, CbDepth: Integer): Integer;
var
  S: PHEVCContext;
  cb_size, split_cu, X1, Y1, more_data, cb_size_split: Integer;
begin
  S := @Enc.Ctx;
  cb_size := 1 shl Log2CbSize;
  S^.HEVClc^.ct_depth := CbDepth;

  if (X0 + cb_size <= S^.sps^.width) and (Y0 + cb_size <= S^.sps^.height) and
     (Log2CbSize > S^.sps^.log2_min_cb_size) then
  begin
    // fully inside: the flag is present, and this encoder never splits
    split_cu := 0;
    enc_split_coding_unit_flag(S, Enc.E, CbDepth, X0, Y0, split_cu);
  end
  else
    // partly outside: the split is inferred, no flag is written
    split_cu := Ord(Log2CbSize > S^.sps^.log2_min_cb_size);

  if split_cu <> 0 then
  begin
    cb_size_split := cb_size shr 1;
    X1 := X0 + cb_size_split;
    Y1 := Y0 + cb_size_split;
    more_data := encode_quadtree(Enc, X0, Y0, Log2CbSize - 1, CbDepth + 1);
    if (more_data <> 0) and (X1 < S^.sps^.width) then
      more_data := encode_quadtree(Enc, X1, Y0, Log2CbSize - 1, CbDepth + 1);
    if (more_data <> 0) and (Y1 < S^.sps^.height) then
      more_data := encode_quadtree(Enc, X0, Y1, Log2CbSize - 1, CbDepth + 1);
    if (more_data <> 0) and (X1 < S^.sps^.width) and (Y1 < S^.sps^.height) then
      more_data := encode_quadtree(Enc, X1, Y1, Log2CbSize - 1, CbDepth + 1);
    if more_data <> 0 then
      Result := Ord(((X1 + cb_size_split) < S^.sps^.width) or
                    ((Y1 + cb_size_split) < S^.sps^.height))
    else
      Result := 0;
  end
  else
  begin
    if Assigned(enc_cu_hook) then
      enc_cu_hook(Enc, X0, Y0, Log2CbSize)
    else
      encode_coding_unit(Enc, X0, Y0, Log2CbSize);
    Result := encode_leaf_tail(Enc, X0, Y0, cb_size);
  end;
end;

function bpg_enc_picture(var Enc: TBpgEncoder): Integer;
var
  S: PHEVCContext;
  ctb_size, ctb_addr_ts, ctb_addr_rs, x_ctb, y_ctb, ctb_per_row: Integer;
  more_data, Pass, Passes, C, Y, SliceHdrLen: Integer;
  Backup: PAVFrame;

  procedure one_pass;
  begin
    ff_hevc_cabac_init_enc(S);
    Enc.SliceRbsp.Len := SliceHdrLen;
    cabac_enc_init(Enc.E, @Enc.SliceRbsp);
    Enc.CtbDone := 0;
    more_data := 1;
    ctb_addr_ts := 0;
    while (more_data <> 0) and (ctb_addr_ts < Enc.NCtb) do
    begin
      ctb_addr_rs := S^.pps^.ctb_addr_ts_to_rs[ctb_addr_ts];
      x_ctb := (ctb_addr_rs mod ctb_per_row) shl S^.sps^.log2_ctb_size;
      y_ctb := (ctb_addr_rs div ctb_per_row) shl S^.sps^.log2_ctb_size;
      hls_decode_neighbour(S, x_ctb, y_ctb, ctb_addr_ts);
      if SaoMode and not Lossless then
        enc_sao_param(S, Enc.E, x_ctb shr S^.sps^.log2_ctb_size,
                      y_ctb shr S^.sps^.log2_ctb_size);
      if Assigned(enc_quadtree_hook) then
        more_data := enc_quadtree_hook(Enc, x_ctb, y_ctb, S^.sps^.log2_ctb_size, 0)
      else
        more_data := encode_quadtree(Enc, x_ctb, y_ctb, S^.sps^.log2_ctb_size, 0);
      Inc(ctb_addr_ts);
    end;
    cabac_enc_finish(Enc.E);
  end;

begin
  S := @Enc.Ctx;
  ctb_size := 1 shl S^.sps^.log2_ctb_size;
  ctb_per_row := (S^.sps^.width + ctb_size - 1) shr S^.sps^.log2_ctb_size;
  Backup := nil;
  SliceHdrLen := Enc.SliceRbsp.Len;
  if SaoMode and not Lossless then Passes := 2 else Passes := 1;

  for Pass := 1 to Passes do
  begin
    // Pass one exists only for its reconstruction; its bitstream is thrown
    // away. All SAO parameters are still zero, so the sao() it writes is the
    // "not applied" form and the stream stays parseable either way.
    one_pass;

    if (Pass = 1) and (Passes = 2) then
    begin
      // SAO is chosen against an untouched copy, then the frame is left
      // filtered -- pass two overwrites it as it reconstructs, so nothing of
      // that leaks into the second encode.
      Backup := av_frame_alloc;
      if Backup = nil then Exit(-1);
      if frame_get_buffer(Backup, S^.sps^.width, S^.sps^.height,
                          S^.sps^.chroma_format_idc) < 0 then Exit(-1);
      for C := 0 to 2 do
        if (S^.frame^.Data[C] <> nil) and (Backup^.Data[C] <> nil) then
          for Y := 0 to (S^.sps^.height shr S^.sps^.vshift[C]) - 1 do
            Move((S^.frame^.Data[C] + Y * S^.frame^.Linesize[C])^,
                 (Backup^.Data[C] + Y * Backup^.Linesize[C])^,
                 (S^.sps^.width shr S^.sps^.hshift[C]) * SizeOf(Word));
      sao_decide(S, Enc.Src, Backup,
                 0.57 * Exp(((Enc.Qp - 12) / 3.0) * Ln(2.0)));
    end;
  end;

  if Backup <> nil then av_frame_free(Backup);
  Result := 0;
end;

end.
