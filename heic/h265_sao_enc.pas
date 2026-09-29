// BPG encoder -- Free Pascal
// Sample adaptive offset: the per-CTB decision and the sao() writer.
//
// Two facts make this far simpler than it looks.
//
// The first is that intra prediction reads the UNFILTERED reconstruction. SAO
// therefore changes no residual, no mode, no quadtree decision -- nothing the
// rest of the encoder computed. So the picture is encoded once to get its
// reconstruction, SAO is chosen from that finished picture, and the slice is
// encoded a second time with the parameters written in. Pass two reproduces
// identical decisions by construction; only the syntax differs.
//
// The second is that the decoder's own filter maintains everything SAO needs.
// sao_filter_CTB calls copy_CTB_to_hv before it modifies a block, saving that
// block's boundary rows and columns; later blocks read those saved buffers
// rather than the filtered picture. Driving that routine directly, once per
// CTB in raster order, therefore reproduces the decoder exactly.
//
// There is one trap in driving the decoder's filter. sao_filter_CTB overwrites
// type_idx with SAO_APPLIED once it has filtered a block -- deliberately, as a
// marker so that neighbouring CTBs know to read this block's saved boundary
// buffers instead of the filtered picture. The decision therefore destroys its
// own answer as a side effect of scoring it, and the chosen parameters have to
// be kept in a separate array and put back before the second encoding pass
// writes them. Missing this cost several rounds: the written type_idx was 3,
// which is not a legal type, so the writer coded "band" and then wrote edge
// fields, desynchronising CABAC for the rest of the picture.
//
// Note it has to be sao_filter_CTB and not ff_hevc_hls_filter: the latter
// applies the decoder's one-CTB pipeline delay and filters the block up and to
// the left of the coordinates handed to it. Calling it per candidate measured
// the wrong block and applied SAO several times over, which cost up to 10 dB
// before it was found.
//
// So the candidates are judged by running the decoder's filter and measuring
// the result. That gives the decision one property worth stating plainly:
// offsets derived by an approximate rule can only be a little suboptimal, never
// a regression, because every candidate -- including "off" -- is scored by
// exactly the code the decoder will run.
unit h265_sao_enc;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}

interface

uses
  Math, h265_common, h265_putbits, h265_hevc_defs, h265_frame, h265_cabac_enc, h265_syntax_enc,
  h265_hevc_filter;

// Writes sao() for one CTB, mirroring hls_sao_param.
procedure enc_sao_param(S: PHEVCContext; var E: TCabacEncoder; RX, RY: Integer);

// Chooses S^.sao for every CTB from the reconstruction in S^.frame against the
// source in Src. Backup must hold an untouched copy of the reconstruction; the
// frame is left filtered with the chosen parameters.
procedure sao_decide(S: PHEVCContext; Src, Backup: PAVFrame; Lambda: Double);
procedure sao_set_merge(On_: Boolean);
function sao_merge_hits: Integer;

implementation

// Merge decision per CTB, filled by sao_decide and read by enc_sao_param:
// 0 = code the parameters, 1 = merge left, 2 = merge up.
var
  MergeMode: array of Byte;
  // A/B switch consulted at decision time: with it off the merge candidates are
  // never tried, so the flag and the chosen parameters can never disagree
  UseMerge: Boolean = True;
  MergeHits: Integer = 0;

procedure sao_set_merge(On_: Boolean);
begin
  UseMerge := On_;
end;

function sao_merge_hits: Integer;
begin
  Result := MergeHits;
end;

// ------------------------------------------------------------------

procedure enc_sao_param(S: PHEVCContext; var E: TCabacEncoder; RX, RY: Integer);
var
  LC: PHEVCLocalContext;
  Sao: PSAOParams;
  CIdx, I, c_count, CW, Mode: Integer;
begin
  LC := S^.HEVClc;
  CW := S^.sps^.ctb_width;
  Sao := @S^.sao[RY * CW + RX];

  Mode := 0;
  if (Length(MergeMode) > 0) and (RY * CW + RX < Length(MergeMode)) then
    Mode := MergeMode[RY * CW + RX];

  // A merged CTB codes nothing but the flag. That is the whole value of it:
  // without merging every CTB carries a full set of offsets, which is what kept
  // SAO from paying for itself.
  if (S^.sh.slice_sample_adaptive_offset_flag[0] <> 0) or
     (S^.sh.slice_sample_adaptive_offset_flag[1] <> 0) then
  begin
    if (RX > 0) and (LC^.ctb_left_flag <> 0) then
    begin
      enc_sao_merge_flag(S, E, Ord(Mode = 1));
      if Mode = 1 then Exit;
    end;
    if (RY > 0) and (LC^.ctb_up_flag <> 0) then
    begin
      enc_sao_merge_flag(S, E, Ord(Mode = 2));
      if Mode = 2 then Exit;
    end;
  end;

  if S^.sps^.chroma_format_idc <> 0 then c_count := 3 else c_count := 1;
  for CIdx := 0 to c_count - 1 do
  begin
    if S^.sh.slice_sample_adaptive_offset_flag[CIdx] = 0 then Continue;

    // Cr carries neither its own type nor its own class: both come from Cb.
    if CIdx <> 2 then
      enc_sao_type_idx(S, E, Sao^.type_idx[CIdx]);
    if Sao^.type_idx[CIdx] = SAO_NOT_APPLIED then Continue;

    for I := 0 to 3 do
      enc_sao_offset_abs(S, E, Sao^.offset_abs[CIdx][I]);

    if Sao^.type_idx[CIdx] = SAO_BAND then
    begin
      for I := 0 to 3 do
        if Sao^.offset_abs[CIdx][I] <> 0 then
          enc_sao_offset_sign(S, E, Sao^.offset_sign[CIdx][I]);
      enc_sao_band_position(S, E, Sao^.band_position[CIdx]);
    end
    else if CIdx <> 2 then
      enc_sao_eo_class(S, E, Sao^.eo_class[CIdx]);
  end;
end;

// ------------------------------------------------------------------

// the offset_val derivation at the tail of hls_sao_param, which the filter
// actually reads; the encoder must run it after setting offset_abs/sign
procedure sao_derive_offsets(S: PHEVCContext; Sao: PSAOParams; CIdx: Integer);
var
  I, scale: Integer;
begin
  if CIdx = 0 then scale := S^.pps^.log2_sao_offset_scale_luma
  else scale := S^.pps^.log2_sao_offset_scale_chroma;
  Sao^.offset_val[CIdx][0] := 0;
  for I := 0 to 3 do
  begin
    Sao^.offset_val[CIdx][I + 1] := Int16(Sao^.offset_abs[CIdx][I]);
    if Sao^.type_idx[CIdx] = SAO_EDGE then
    begin
      if I > 1 then
        Sao^.offset_val[CIdx][I + 1] := -Sao^.offset_val[CIdx][I + 1];
    end
    else if Sao^.offset_sign[CIdx][I] <> 0 then
      Sao^.offset_val[CIdx][I + 1] := -Sao^.offset_val[CIdx][I + 1];
    Sao^.offset_val[CIdx][I + 1] :=
      Int16(Sao^.offset_val[CIdx][I + 1] shl scale);
  end;
end;

function plane_w(S: PHEVCContext; CIdx: Integer): Integer; inline;
begin
  Result := S^.sps^.width shr S^.sps^.hshift[CIdx];
end;

function plane_h(S: PHEVCContext; CIdx: Integer): Integer; inline;
begin
  Result := S^.sps^.height shr S^.sps^.vshift[CIdx];
end;

// squared error of one plane over one CTB rectangle, frame against source
function ctb_ssd(S: PHEVCContext; Src: PAVFrame;
  CIdx, X0, Y0, W, H: Integer): Int64;
var
  X, Y, D, RS, SS: Integer;
  R, Sp: PWord;
begin
  Result := 0;
  RS := S^.frame^.Linesize[CIdx] div SizeOf(Word);
  SS := Src^.Linesize[CIdx] div SizeOf(Word);
  R := PWord(S^.frame^.Data[CIdx]) + Y0 * RS + X0;
  Sp := PWord(Src^.Data[CIdx]) + Y0 * SS + X0;
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
    begin
      D := R[Y * RS + X] - Sp[Y * SS + X];
      Result := Result + Int64(D) * D;
    end;
end;

// restores one plane's CTB rectangle from the untouched reconstruction
procedure ctb_restore(S: PHEVCContext; Backup: PAVFrame;
  CIdx, X0, Y0, W, H: Integer);
var
  Y, RS, BS: Integer;
  R, B: PWord;
begin
  RS := S^.frame^.Linesize[CIdx] div SizeOf(Word);
  BS := Backup^.Linesize[CIdx] div SizeOf(Word);
  R := PWord(S^.frame^.Data[CIdx]) + Y0 * RS + X0;
  B := PWord(Backup^.Data[CIdx]) + Y0 * BS + X0;
  for Y := 0 to H - 1 do
    Move((B + Y * BS)^, (R + Y * RS)^, W * SizeOf(Word));
end;

// The edge category of one sample, as the decoder's edge filter computes it:
// the sign of the difference to each of the two neighbours along the class
// direction, summed and mapped to 1..4 with 0 meaning "no change". Only used to
// derive candidate offsets; the scoring is done by the real filter.
const
  eo_dx: array[0..3, 0..1] of Integer = ((-1, 1), (0, 0), (-1, 1), (1, -1));
  eo_dy: array[0..3, 0..1] of Integer = ((0, 0), (-1, 1), (-1, 1), (-1, 1));

// Derives offsets for one plane and one candidate type, writing them into Sao.
// Reads the UNFILTERED plane from Backup so the classification matches what the
// filter will see.
procedure derive_candidate(S: PHEVCContext; Src, Backup: PAVFrame;
  Sao: PSAOParams; CIdx, TypeIdx, Class_, X0, Y0, W, H: Integer);
var
  X, Y, I, K, Cat, D, BS, SS, MaxOff, Band, BestBand: Integer;
  Cur, N0, N1: Integer;
  B, Sp: PWord;
  Sum: array[0..31] of Int64;
  Cnt: array[0..31] of Int64;
  BandGain, BestGain: Int64;
  Off: Integer;
begin
  BS := Backup^.Linesize[CIdx] div SizeOf(Word);
  SS := Src^.Linesize[CIdx] div SizeOf(Word);
  B := PWord(Backup^.Data[CIdx]);
  Sp := PWord(Src^.Data[CIdx]);
  // the format caps the magnitude at (1 shl (min(bitDepth,10) - 5)) - 1
  MaxOff := (1 shl (FFMIN(S^.sps^.bit_depth, 10) - 5)) - 1;

  FillChar(Sum, SizeOf(Sum), 0);
  FillChar(Cnt, SizeOf(Cnt), 0);

  Sao^.type_idx[CIdx] := Byte(TypeIdx);
  for I := 0 to 3 do
  begin
    Sao^.offset_abs[CIdx][I] := 0;
    Sao^.offset_sign[CIdx][I] := 0;
  end;

  if TypeIdx = SAO_EDGE then
  begin
    Sao^.eo_class[CIdx] := Class_;
    for Y := Y0 to Y0 + H - 1 do
      for X := X0 to X0 + W - 1 do
      begin
        // samples whose neighbours fall outside the picture are not filtered
        if (X + eo_dx[Class_][0] < 0) or (X + eo_dx[Class_][1] >= plane_w(S, CIdx)) or
           (X + eo_dx[Class_][1] < 0) or (X + eo_dx[Class_][0] >= plane_w(S, CIdx)) or
           (Y + eo_dy[Class_][0] < 0) or (Y + eo_dy[Class_][1] >= plane_h(S, CIdx)) or
           (Y + eo_dy[Class_][1] < 0) or (Y + eo_dy[Class_][0] >= plane_h(S, CIdx)) then
          Continue;
        Cur := B[Y * BS + X];
        N0 := B[(Y + eo_dy[Class_][0]) * BS + X + eo_dx[Class_][0]];
        N1 := B[(Y + eo_dy[Class_][1]) * BS + X + eo_dx[Class_][1]];
        Cat := 2 + Sign(Cur - N0) + Sign(Cur - N1);
        // 2 is the flat category, which carries no offset
        if Cat = 2 then Continue;
        if Cat < 2 then K := Cat // 0, 1 -> offsets 0, 1, positive
        else K := Cat - 1; // 3, 4 -> offsets 2, 3, negative
        Sum[K] := Sum[K] + (Sp[Y * SS + X] - Cur);
        Cnt[K] := Cnt[K] + 1;
      end;

    for I := 0 to 3 do
    begin
      if Cnt[I] = 0 then Continue;
      Off := Round(Sum[I] / Cnt[I]);
      // categories 0 and 1 may only brighten, 2 and 3 only darken -- the
      // decoder negates the last two, so the magnitude is what is coded
      if I < 2 then
      begin
        if Off < 0 then Off := 0;
      end
      else
      begin
        if Off > 0 then Off := 0;
        Off := -Off;
      end;
      Sao^.offset_abs[CIdx][I] := FFMIN(Off, MaxOff);
    end;
  end
  else
  begin
    // Band offset: 32 bands over the sample range, four consecutive of them
    // carry offsets. Pick the run of four with the largest total squared-error
    // reduction.
    for Y := Y0 to Y0 + H - 1 do
      for X := X0 to X0 + W - 1 do
      begin
        Cur := B[Y * BS + X];
        Band := Cur shr (S^.sps^.bit_depth - 5);
        Sum[Band] := Sum[Band] + (Sp[Y * SS + X] - Cur);
        Cnt[Band] := Cnt[Band] + 1;
      end;

    BestBand := 0;
    BestGain := -1;
    for Band := 0 to 28 do
    begin
      BandGain := 0;
      for I := 0 to 3 do
        if Cnt[Band + I] > 0 then
        begin
          Off := Round(Sum[Band + I] / Cnt[Band + I]);
          if Off > MaxOff then Off := MaxOff;
          if Off < -MaxOff then Off := -MaxOff;
          // squared error removed by shifting this band by Off
          BandGain := BandGain + 2 * Int64(Off) * Sum[Band + I] -
                      Int64(Off) * Off * Cnt[Band + I];
        end;
      if BandGain > BestGain then
      begin
        BestGain := BandGain;
        BestBand := Band;
      end;
    end;

    Sao^.band_position[CIdx] := Byte(BestBand);
    for I := 0 to 3 do
      if Cnt[BestBand + I] > 0 then
      begin
        Off := Round(Sum[BestBand + I] / Cnt[BestBand + I]);
        if Off > MaxOff then Off := MaxOff;
        if Off < -MaxOff then Off := -MaxOff;
        Sao^.offset_abs[CIdx][I] := Abs(Off);
        Sao^.offset_sign[CIdx][I] := Ord(Off < 0);
      end;
  end;

  sao_derive_offsets(S, Sao, CIdx);
end;

// ------------------------------------------------------------------

// bits sao() costs for one CTB, by trial-encoding it and throwing it away
function sao_bits(S: PHEVCContext; RX, RY: Integer): Integer;
var
  Save: array[0 .. HEVC_CONTEXTS - 1] of Byte;
  Buf: TByteBuf;
  E: TCabacEncoder;
begin
  Move(S^.HEVClc^.cabac_state, Save, SizeOf(Save));
  buf_init(Buf);
  cabac_enc_init(E, @Buf);
  enc_sao_param(S, E, RX, RY);
  cabac_enc_terminate(E, 1);
  cabac_enc_finish(E);
  Result := Buf.Len * 8;
  buf_free(Buf);
  Move(Save, S^.HEVClc^.cabac_state, SizeOf(Save));
end;

procedure sao_decide(S: PHEVCContext; Src, Backup: PAVFrame; Lambda: Double);
var
  ctb_size, RX, RY, CIdx, Cand, c_count: Integer;
  X0, Y0, W, H: Integer;
  Sao: PSAOParams;
  BestLCand, BestCCand: Integer;
  Chosen: array of TSAOParams;
  BitsOn, BitsOff, BitsPlain, MTry, NIdx, BestMerge: Integer;
  BestTotal, MSsd: Int64;
  BestCost, MCost: Int64;
  SaveSao: TSAOParams;
  GainL, GainC: Int64;
  OffL, OffC: Int64;
  BestLSsd, BestCSsd, SsdL, SsdC: Int64;
  Any: Boolean;

  procedure geom(CI: Integer; out XP, YP, WP, HP: Integer);
  begin
    XP := (RX * ctb_size) shr S^.sps^.hshift[CI];
    YP := (RY * ctb_size) shr S^.sps^.vshift[CI];
    WP := W shr S^.sps^.hshift[CI];
    HP := H shr S^.sps^.vshift[CI];
  end;

  function ssd_of(CI: Integer): Int64;
  var
    XP, YP, WP, HP: Integer;
  begin
    geom(CI, XP, YP, WP, HP);
    // Deliberately UNWEIGHTED, unlike the four rate-distortion sites in
    // h265_enc. Weighting chroma here for the RGB metric was tried both ways and
    // both lost: with lambda rescaled by the mean weight -0.069/-0.056 dB
    // equivalent on photographs, without it -0.124/-0.275. The difference from
    // the other sites is that SAO decides each plane against its own "off"
    // baseline, so a weight applied to both sides of that comparison cannot
    // change which side wins -- it only unbalances the joint rate gate that
    // follows. See task #28.
    Result := ctb_ssd(S, Src, CI, XP, YP, WP, HP);
  end;

  procedure restore(CI: Integer);
  var
    XP, YP, WP, HP: Integer;
  begin
    geom(CI, XP, YP, WP, HP);
    ctb_restore(S, Backup, CI, XP, YP, WP, HP);
  end;

  procedure derive(CI, TypeIdx, Class_: Integer);
  var
    XP, YP, WP, HP: Integer;
  begin
    geom(CI, XP, YP, WP, HP);
    derive_candidate(S, Src, Backup, Sao, CI, TypeIdx, Class_, XP, YP, WP, HP);
  end;

begin
  ctb_size := 1 shl S^.sps^.log2_ctb_size;
  SetLength(Chosen, S^.sps^.ctb_width * S^.sps^.ctb_height);
  SetLength(MergeMode, S^.sps^.ctb_width * S^.sps^.ctb_height);
  FillChar(MergeMode[0], Length(MergeMode), 0);
  MergeHits := 0;
  if S^.sps^.chroma_format_idc <> 0 then c_count := 3 else c_count := 1;

  for RY := 0 to S^.sps^.ctb_height - 1 do
    for RX := 0 to S^.sps^.ctb_width - 1 do
    begin
      X0 := RX * ctb_size;
      Y0 := RY * ctb_size;
      W := FFMIN(ctb_size, S^.sps^.width - X0);
      H := FFMIN(ctb_size, S^.sps^.height - Y0);
      Sao := @S^.sao[RY * S^.sps^.ctb_width + RX];

      // "off" is the reference every candidate must beat, scored exactly the
      // way the candidates are: filtered picture against source
      for CIdx := 0 to c_count - 1 do
        Sao^.type_idx[CIdx] := SAO_NOT_APPLIED;
      BestLSsd := ssd_of(0);
      OffL := BestLSsd;
      BestLCand := -1;
      BestCSsd := 0;
      if c_count = 3 then BestCSsd := ssd_of(1) + ssd_of(2);
      OffC := BestCSsd;
      BestCCand := -1;

      // candidates: band offset, then the four edge classes. Luma is decided on
      // its own; chroma is decided jointly, because the syntax gives Cb and Cr
      // one type_idx and one eo_class between them and only the offsets and the
      // band position are per plane.
      for Cand := 0 to 4 do
      begin
        for CIdx := 0 to c_count - 1 do
        begin
          restore(CIdx);
          if Cand = 0 then derive(CIdx, SAO_BAND, 0)
          else derive(CIdx, SAO_EDGE, Cand - 1);
        end;
        if c_count = 3 then
        begin
          Sao^.type_idx[2] := Sao^.type_idx[1];
          Sao^.eo_class[2] := Sao^.eo_class[1];
          sao_derive_offsets(S, Sao, 2);
        end;

        sao_filter_CTB(S, X0, Y0);

        SsdL := ssd_of(0);
        if SsdL < BestLSsd then
        begin
          BestLSsd := SsdL;
          BestLCand := Cand;
        end;
        if c_count = 3 then
        begin
          SsdC := ssd_of(1) + ssd_of(2);
          if SsdC < BestCSsd then
          begin
            BestCSsd := SsdC;
            BestCCand := Cand;
          end;
        end;
      end;

      // install the winners -- luma from its own best, chroma from the joint
      // one -- then filter once for real, so the frame the next CTB reads its
      // boundaries from carries the chosen result
      Any := False;
      for CIdx := 0 to c_count - 1 do
      begin
        restore(CIdx);
        Sao^.type_idx[CIdx] := SAO_NOT_APPLIED;
      end;

      // Re-derive the winner rather than restoring a snapshot of the record.
      // Snapshotting mixed state from different candidates -- band_position
      // from one, eo_class from another -- and produced an out-of-range
      // type_idx, which the writer then coded as a valid but wrong type and
      // desynchronised the whole stream. Re-deriving cannot do that: each call
      // sets every field the type needs.
      if BestLCand = 0 then derive(0, SAO_BAND, 0)
      else if BestLCand > 0 then derive(0, SAO_EDGE, BestLCand - 1);
      if Sao^.type_idx[0] <> SAO_NOT_APPLIED then Any := True;

      if c_count = 3 then
      begin
        if BestCCand = 0 then
        begin
          derive(1, SAO_BAND, 0);
          derive(2, SAO_BAND, 0);
        end
        else if BestCCand > 0 then
        begin
          derive(1, SAO_EDGE, BestCCand - 1);
          derive(2, SAO_EDGE, BestCCand - 1);
        end;
        // Cr takes its type and class from Cb; the syntax carries neither
        Sao^.type_idx[2] := Sao^.type_idx[1];
        Sao^.eo_class[2] := Sao^.eo_class[1];
        sao_derive_offsets(S, Sao, 2);
        if Sao^.type_idx[1] <> SAO_NOT_APPLIED then Any := True;
      end;

      // Rate gate. The decision above minimises squared error alone, and SAO
      // syntax is not cheap: coded for every CTB with explicit offsets it can
      // add a third to the file. Charge the bits it actually costs -- measured
      // by trial-encoding sao() both ways -- and fall back to "off" when the
      // error it removes is not worth them.
      if (BestLCand >= 0) or (BestCCand >= 0) then
      begin
        BitsOn := sao_bits(S, RX, RY);
        for CIdx := 0 to c_count - 1 do
          Sao^.type_idx[CIdx] := SAO_NOT_APPLIED;
        BitsOff := sao_bits(S, RX, RY);
        GainL := OffL - BestLSsd;
        GainC := OffC - BestCSsd;
        if (GainL + GainC) < Round(Lambda * (BitsOn - BitsOff)) then
        begin
          BestLCand := -1;
          BestCCand := -1;
        end;
        // re-install, since the bit count above cleared the types
        for CIdx := 0 to c_count - 1 do
          Sao^.type_idx[CIdx] := SAO_NOT_APPLIED;
        if BestLCand = 0 then derive(0, SAO_BAND, 0)
        else if BestLCand > 0 then derive(0, SAO_EDGE, BestLCand - 1);
        if c_count = 3 then
        begin
          if BestCCand = 0 then begin derive(1, SAO_BAND, 0); derive(2, SAO_BAND, 0); end
          else if BestCCand > 0 then
          begin
            derive(1, SAO_EDGE, BestCCand - 1);
            derive(2, SAO_EDGE, BestCCand - 1);
          end;
          Sao^.type_idx[2] := Sao^.type_idx[1];
          Sao^.eo_class[2] := Sao^.eo_class[1];
          sao_derive_offsets(S, Sao, 2);
        end;
      end;

      // Merge candidates: reuse the left or upper neighbour's parameters and
      // code nothing but the flag. Read them from Chosen, not from S^.sao --
      // the filter has already overwritten the neighbours there with its
      // SAO_APPLIED markers. Scored on total error over all planes, since
      // merging is all or nothing.
      BestMerge := 0;
      BestTotal := BestLSsd + BestCSsd;
      MergeMode[RY * S^.sps^.ctb_width + RX] := 0;
      BitsPlain := sao_bits(S, RX, RY);
      BestCost := BestTotal + Round(Lambda * BitsPlain);
      SaveSao := Sao^;

      for MTry := 1 to 2 do
      begin
        if not UseMerge then Break;
        if (MTry = 1) and (RX = 0) then Continue;
        if (MTry = 2) and (RY = 0) then Continue;
        if MTry = 1 then NIdx := RY * S^.sps^.ctb_width + RX - 1
        else NIdx := (RY - 1) * S^.sps^.ctb_width + RX;

        Sao^ := Chosen[NIdx];
        for CIdx := 0 to c_count - 1 do
        begin
          restore(CIdx);
          sao_derive_offsets(S, Sao, CIdx);
        end;
        sao_filter_CTB(S, X0, Y0);
        MSsd := ssd_of(0);
        if c_count = 3 then MSsd := MSsd + ssd_of(1) + ssd_of(2);

        MergeMode[RY * S^.sps^.ctb_width + RX] := MTry;
        MCost := MSsd + Round(Lambda * sao_bits(S, RX, RY));
        if MCost < BestCost then
        begin
          BestCost := MCost;
          SaveSao := Sao^;
          BestMerge := MTry;
        end;
      end;
      MergeMode[RY * S^.sps^.ctb_width + RX] := BestMerge;
      if BestMerge <> 0 then Inc(MergeHits);
      Sao^ := SaveSao;
      for CIdx := 0 to c_count - 1 do
        restore(CIdx);

      // keep the answer before filtering destroys it
      Chosen[RY * S^.sps^.ctb_width + RX] := Sao^;

      // always, even when every plane came out "not applied": the filter also
      // saves this CTB's unfiltered boundary rows and columns, which the next
      // CTB reads instead of the filtered picture
      sao_filter_CTB(S, X0, Y0);
    end;

  // put the chosen parameters back, over the SAO_APPLIED markers the filter
  // left behind, so the second pass writes what was actually decided
  for RY := 0 to S^.sps^.ctb_height - 1 do
    for RX := 0 to S^.sps^.ctb_width - 1 do
      S^.sao[RY * S^.sps^.ctb_width + RX] :=
        Chosen[RY * S^.sps^.ctb_width + RX];
end;

end.
