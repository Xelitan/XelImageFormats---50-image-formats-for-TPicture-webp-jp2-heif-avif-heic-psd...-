unit Av1.Headers;

// AV1 sequence and frame header parsing (full syntax: key, intra-only, inter
// and switch frames, show_existing_frame, reference selection, global motion,
// film grain). Frame headers that depend on earlier frames take the current
// reference slots' headers as input.
//
// Port of dav1d src/obu.c parse_seq_hdr / parse_frame_hdr (BSD-2-Clause).

{$mode delphi}{$H+}
{$RANGECHECKS OFF}{$OVERFLOWCHECKS OFF}

interface

uses SysUtils, Av1.Bits, Av1.Tables, Av1.Mc;

const
  KEY_FRAME = 0; INTER_FRAME = 1; INTRA_ONLY_FRAME = 2; SWITCH_FRAME = 3;
  PRIMARY_REF_NONE = 7;
  ADAPTIVE = 2;

  LAYOUT_I400 = 0; LAYOUT_I420 = 1; LAYOUT_I422 = 2; LAYOUT_I444 = 3;

  TX_4X4_ONLY = 0; TX_LARGEST = 1; TX_SWITCHABLE = 2;

  // dav1d Dav1dRestorationType (= the coded 2-bit value)
  RESTORATION_NONE = 0; RESTORATION_SWITCHABLE = 1; RESTORATION_WIENER = 2;
  RESTORATION_SGRPROJ = 3;

type
  EAv1Header = class(Exception);

  TSeqHdr = record
    Profile: Integer;
    StillPicture, ReducedStillPictureHeader: Boolean;
    TimingInfoPresent: Boolean;
    NumUnitsInTick, TimeScale: LongWord;
    EqualPictureInterval: Boolean;
    NumTicksPerPicture: LongWord;
    DecoderModelInfoPresent: Boolean;
    EncoderDecoderBufferDelayLength, BufferRemovalDelayLength,
    FramePresentationDelayLength: Integer;
    NumOperatingPoints: Integer;
    OpIdc: array[0..31] of Integer;
    OpDecoderModelParamPresent: array[0..31] of Boolean;
    WidthNBits, HeightNBits, MaxWidth, MaxHeight: Integer;
    FrameIdNumbersPresent: Boolean;
    DeltaFrameIdNBits, FrameIdNBits: Integer;
    Sb128, FilterIntra, IntraEdgeFilter, InterIntra, MaskedCompound,
    WarpedMotion, DualFilter, OrderHint, JntComp, RefFrameMvs: Boolean;
    ScreenContentTools, ForceIntegerMv: Integer;   // 0/1/ADAPTIVE
    OrderHintNBits: Integer;
    SuperRes, Cdef, Restoration: Boolean;
    Hbd, BitDepth: Integer;
    Monochrome: Boolean;
    Pri, Trc, Mtrx: Integer;
    ColorRange: Integer;
    Layout, SsHor, SsVer, Chr: Integer;
    SeparateUvDeltaQ: Boolean;
    FilmGrainPresent: Boolean;
  end;
  PSeqHdr = ^TSeqHdr;

  TFilmGrainData = record
    Seed: LongWord;
    NumYPoints: Integer;
    YPoints: array[0..13, 0..1] of Byte;
    ChromaScalingFromLuma: Boolean;
    NumUvPoints: array[0..1] of Integer;
    UvPoints: array[0..1, 0..9, 0..1] of Byte;
    ScalingShift, ArCoeffLag: Integer;
    ArCoeffsY: array[0..23] of ShortInt;
    ArCoeffsUv: array[0..1, 0..27] of ShortInt;
    ArCoeffShift, GrainScaleShift: Integer;
    UvMult, UvLumaMult, UvOffset: array[0..1] of Integer;
    OverlapFlag, ClipToRestrictedRange: Boolean;
  end;

  TSegData = record
    DeltaQ, DeltaLfYV, DeltaLfYH, DeltaLfU, DeltaLfV: Integer;
    Ref: Integer;          // -1 = none
    Skip, GlobalMv: Boolean;
  end;

  TSegDataSet = record
    D: array[0..7] of TSegData;
    Preskip: Boolean;
    LastActiveSegId: Integer;
  end;

  TLfModeRefDeltas = record
    ModeDelta: array[0..1] of Integer;
    RefDelta: array[0..7] of Integer;
  end;

  TFrameHdr = record
    FilmGrain: record
      Data: TFilmGrainData;
      Present, Update: Boolean;
    end;
    FrameType: Integer;
    Width: array[0..1] of Integer;   // [0] = coded (downscaled), [1] = upscaled
    Height: Integer;
    FrameOffset: Integer;
    TemporalId, SpatialId: Integer;
    ShowExistingFrame: Boolean;
    ExistingFrameIdx: Integer;
    FrameId: LongWord;
    ShowFrame, ShowableFrame, ErrorResilientMode, DisableCdfUpdate: Boolean;
    AllowScreenContentTools, ForceIntegerMv: Integer;
    FrameSizeOverride: Boolean;
    PrimaryRefFrame: Integer;
    RefreshFrameFlags: Integer;
    RenderWidth, RenderHeight: Integer;
    SuperResEnabled: Boolean;
    SuperResDenom: Integer;
    HaveRenderSize, AllowIntrabc, FrameRefShortSignaling: Boolean;
    RefIdx: array[0..6] of Integer;
    Hp: Boolean;
    SubpelFilterMode: Integer;
    SwitchableMotionMode, UseRefFrameMvs, RefreshContext: Boolean;
    Tiling: record
      Uniform: Boolean;
      NBytes: Integer;
      MinLog2Cols, MaxLog2Cols, Log2Cols, Cols: Integer;
      MinLog2Rows, MaxLog2Rows, Log2Rows, Rows: Integer;
      ColStartSb: array[0..64] of Integer;
      RowStartSb: array[0..64] of Integer;
      Update: Integer;
    end;
    Quant: record
      Yac, YdcDelta, UdcDelta, UacDelta, VdcDelta, VacDelta: Integer;
      Qm: Boolean;
      QmY, QmU, QmV: Integer;
    end;
    Segmentation: record
      Enabled, UpdateMap, Temporal, UpdateData: Boolean;
      SegData: TSegDataSet;
      Lossless: array[0..7] of Boolean;
      QIdx: array[0..7] of Integer;
    end;
    DeltaQPresent: Boolean; DeltaQResLog2: Integer;
    DeltaLfPresent: Boolean; DeltaLfResLog2: Integer; DeltaLfMulti: Boolean;
    AllLossless: Boolean;
    LoopFilter: record
      LevelY: array[0..1] of Integer;
      LevelU, LevelV: Integer;
      ModeRefDeltaEnabled, ModeRefDeltaUpdate: Boolean;
      ModeRefDeltas: TLfModeRefDeltas;
      Sharpness: Integer;
    end;
    Cdef: record
      Damping, NBits: Integer;
      YStrength, UvStrength: array[0..7] of Integer;
    end;
    Restoration: record
      LrType: array[0..2] of Integer;
      UnitSize: array[0..1] of Integer;   // log2
    end;
    TxfmMode: Integer;
    SwitchableCompRefs, SkipModeAllowed, SkipModeEnabled: Boolean;
    SkipModeRefs: array[0..1] of Integer;
    WarpMotion, ReducedTxtpSet: Boolean;
    Gmv: array[0..6] of TWarpParams;
  end;
  PFrameHdr = ^TFrameHdr;

  // Reference slot headers visible to the frame header parser (nil = empty).
  TRefHdrs = array[0..7] of PFrameHdr;

procedure ParseSeqHdr(Data: PByte; Size: NativeInt; out S: TSeqHdr);
// Parses an uncompressed frame header. On return HdrBits is the bit count
// consumed (before byte alignment for OBU_FRAME).
procedure ParseFrameHdr(const S: TSeqHdr; const Refs: TRefHdrs; TemporalId, SpatialId: Integer;
  Data: PByte; Size: NativeInt; out F: TFrameHdr; out HdrBits: Int64);

function GetPocDiff(OrderHintNBits, Poc0, Poc1: Integer): Integer;
procedure DefaultWarpParams(out W: TWarpParams);

implementation

function IMin(a, b: Integer): Integer; inline; begin if a < b then Result := a else Result := b; end;
function IMax(a, b: Integer): Integer; inline; begin if a > b then Result := a else Result := b; end;

procedure DefaultWarpParams(out W: TWarpParams);
begin
  FillChar(W, SizeOf(W), 0);
  W.WmType := 0;
  W.Matrix[2] := 1 shl 16;
  W.Matrix[5] := 1 shl 16;
end;

function GetPocDiff(OrderHintNBits, Poc0, Poc1: Integer): Integer;
var mask, diff: Integer;
begin
  if OrderHintNBits = 0 then Exit(0);
  mask := 1 shl (OrderHintNBits - 1);
  diff := Poc0 - Poc1;
  Result := (diff and (mask - 1)) - (diff and mask);
end;

procedure ParseSeqHdr(Data: PByte; Size: NativeInt; out S: TSeqHdr);
var B: TAv1Bits; i: Integer; dispModel: Boolean;
begin
  FillChar(S, SizeOf(S), 0);
  B := TAv1Bits.Create(Data, Size);
  try
    S.Profile := B.f(3);
    if S.Profile > 2 then raise EAv1Header.Create('AV1: invalid profile');
    S.StillPicture := B.f(1) = 1;
    S.ReducedStillPictureHeader := B.f(1) = 1;
    if S.ReducedStillPictureHeader then
    begin
      S.NumOperatingPoints := 1;
      B.f(5);   // seq_level_idx[0]
    end
    else
    begin
      S.TimingInfoPresent := B.f(1) = 1;
      if S.TimingInfoPresent then
      begin
        S.NumUnitsInTick := B.f(32);
        S.TimeScale := B.f(32);
        S.EqualPictureInterval := B.f(1) = 1;
        if S.EqualPictureInterval then S.NumTicksPerPicture := B.uvlc + 1;
        S.DecoderModelInfoPresent := B.f(1) = 1;
        if S.DecoderModelInfoPresent then
        begin
          S.EncoderDecoderBufferDelayLength := B.f(5) + 1;
          B.f(32);   // num_units_in_decoding_tick
          S.BufferRemovalDelayLength := B.f(5) + 1;
          S.FramePresentationDelayLength := B.f(5) + 1;
        end;
      end;
      dispModel := B.f(1) = 1;
      S.NumOperatingPoints := B.f(5) + 1;
      for i := 0 to S.NumOperatingPoints - 1 do
      begin
        S.OpIdc[i] := B.f(12);
        if 2 + B.f(3) > 3 then
        begin
          B.f(2);    // minor level
          B.f(1);    // tier
        end
        else B.f(2);
        if S.DecoderModelInfoPresent then
        begin
          S.OpDecoderModelParamPresent[i] := B.f(1) = 1;
          if S.OpDecoderModelParamPresent[i] then
          begin
            B.f(S.EncoderDecoderBufferDelayLength);
            B.f(S.EncoderDecoderBufferDelayLength);
            B.f(1);
          end;
        end;
        if dispModel then
          if B.f(1) = 1 then B.f(4);
      end;
    end;

    S.WidthNBits := B.f(4) + 1;
    S.HeightNBits := B.f(4) + 1;
    S.MaxWidth := B.f(S.WidthNBits) + 1;
    S.MaxHeight := B.f(S.HeightNBits) + 1;
    if not S.ReducedStillPictureHeader then
    begin
      S.FrameIdNumbersPresent := B.f(1) = 1;
      if S.FrameIdNumbersPresent then
      begin
        S.DeltaFrameIdNBits := B.f(4) + 2;
        S.FrameIdNBits := B.f(3) + S.DeltaFrameIdNBits + 1;
      end;
    end;
    S.Sb128 := B.f(1) = 1;
    S.FilterIntra := B.f(1) = 1;
    S.IntraEdgeFilter := B.f(1) = 1;
    if S.ReducedStillPictureHeader then
    begin
      S.ScreenContentTools := ADAPTIVE;
      S.ForceIntegerMv := ADAPTIVE;
    end
    else
    begin
      S.InterIntra := B.f(1) = 1;
      S.MaskedCompound := B.f(1) = 1;
      S.WarpedMotion := B.f(1) = 1;
      S.DualFilter := B.f(1) = 1;
      S.OrderHint := B.f(1) = 1;
      if S.OrderHint then
      begin
        S.JntComp := B.f(1) = 1;
        S.RefFrameMvs := B.f(1) = 1;
      end;
      if B.f(1) = 1 then S.ScreenContentTools := ADAPTIVE else S.ScreenContentTools := B.f(1);
      if S.ScreenContentTools <> 0 then
      begin
        if B.f(1) = 1 then S.ForceIntegerMv := ADAPTIVE else S.ForceIntegerMv := B.f(1);
      end
      else S.ForceIntegerMv := 2;
      if S.OrderHint then S.OrderHintNBits := B.f(3) + 1;
    end;
    S.SuperRes := B.f(1) = 1;
    S.Cdef := B.f(1) = 1;
    S.Restoration := B.f(1) = 1;

    S.Hbd := B.f(1);
    if (S.Profile = 2) and (S.Hbd <> 0) then Inc(S.Hbd, B.f(1));
    S.BitDepth := 8 + 2 * S.Hbd;
    if S.Profile <> 1 then S.Monochrome := B.f(1) = 1;
    if B.f(1) = 1 then
    begin
      S.Pri := B.f(8); S.Trc := B.f(8); S.Mtrx := B.f(8);
    end
    else
    begin
      S.Pri := 2; S.Trc := 2; S.Mtrx := 2;
    end;
    if S.Monochrome then
    begin
      S.ColorRange := B.f(1);
      S.Layout := LAYOUT_I400;
      S.SsHor := 1; S.SsVer := 1;
    end
    else if (S.Pri = 1) and (S.Trc = 13) and (S.Mtrx = 0) then
    begin
      S.Layout := LAYOUT_I444;
      S.ColorRange := 1;
    end
    else
    begin
      S.ColorRange := B.f(1);
      case S.Profile of
        0: begin S.Layout := LAYOUT_I420; S.SsHor := 1; S.SsVer := 1; end;
        1: S.Layout := LAYOUT_I444;
      else
        begin
          if S.Hbd = 2 then
          begin
            S.SsHor := B.f(1);
            if S.SsHor <> 0 then S.SsVer := B.f(1);
          end
          else S.SsHor := 1;
          if S.SsHor <> 0 then
          begin
            if S.SsVer <> 0 then S.Layout := LAYOUT_I420 else S.Layout := LAYOUT_I422;
          end
          else S.Layout := LAYOUT_I444;
        end;
      end;
      if (S.SsHor and S.SsVer) <> 0 then S.Chr := B.f(2);
    end;
    if not S.Monochrome then S.SeparateUvDeltaQ := B.f(1) = 1;
    S.FilmGrainPresent := B.f(1) = 1;
  finally
    B.Free;
  end;
end;

function InvRecenter(r, v: LongWord): LongWord;
begin
  if v > (r shl 1) then Result := v
  else if (v and 1) = 0 then Result := (v shr 1) + r
  else Result := r - ((v + 1) shr 1);
end;

function GetBitsSubexpU(B: TAv1Bits; ref, n: LongWord): LongWord;
var v: LongWord; i, bb: Integer;
begin
  v := 0;
  i := 0;
  while True do
  begin
    if i <> 0 then bb := 3 + i - 1 else bb := 3;
    if n < v + 3 * (LongWord(1) shl bb) then
    begin
      Inc(v, B.ns(n - v + 1));
      Break;
    end;
    if B.f(1) = 0 then
    begin
      Inc(v, B.f(bb));
      Break;
    end;
    Inc(v, LongWord(1) shl bb);
    Inc(i);
  end;
  if ref * 2 <= n then Result := InvRecenter(ref, v)
  else Result := n - InvRecenter(n - ref, v);
end;

function GetBitsSubexp(B: TAv1Bits; ref: Integer; n: Integer): Integer;
begin
  Result := Integer(GetBitsSubexpU(B, LongWord(ref + (1 shl n)), LongWord(2 shl n))) - (1 shl n);
end;

procedure ReadFrameSize(B: TAv1Bits; const S: TSeqHdr; const Refs: TRefHdrs;
  var F: TFrameHdr; UseRef: Boolean);
var i, d: Integer; R: PFrameHdr;
begin
  if UseRef then
    for i := 0 to 6 do
      if B.f(1) = 1 then
      begin
        R := Refs[F.RefIdx[i]];
        if R = nil then raise EAv1Header.Create('AV1: missing reference for frame size');
        F.Width[1] := R^.Width[1];
        F.Height := R^.Height;
        F.RenderWidth := R^.RenderWidth;
        F.RenderHeight := R^.RenderHeight;
        F.SuperResEnabled := S.SuperRes and (B.f(1) = 1);
        if F.SuperResEnabled then
        begin
          d := 9 + B.f(3);
          F.SuperResDenom := d;
          F.Width[0] := IMax((F.Width[1] * 8 + (d shr 1)) div d, IMin(16, F.Width[1]));
        end
        else
        begin
          F.SuperResDenom := 8;
          F.Width[0] := F.Width[1];
        end;
        Exit;
      end;

  if F.FrameSizeOverride then
  begin
    F.Width[1] := B.f(S.WidthNBits) + 1;
    F.Height := B.f(S.HeightNBits) + 1;
  end
  else
  begin
    F.Width[1] := S.MaxWidth;
    F.Height := S.MaxHeight;
  end;
  F.SuperResEnabled := S.SuperRes and (B.f(1) = 1);
  if F.SuperResEnabled then
  begin
    d := 9 + B.f(3);
    F.SuperResDenom := d;
    F.Width[0] := IMax((F.Width[1] * 8 + (d shr 1)) div d, IMin(16, F.Width[1]));
  end
  else
  begin
    F.SuperResDenom := 8;
    F.Width[0] := F.Width[1];
  end;
  F.HaveRenderSize := B.f(1) = 1;
  if F.HaveRenderSize then
  begin
    F.RenderWidth := B.f(16) + 1;
    F.RenderHeight := B.f(16) + 1;
  end
  else
  begin
    F.RenderWidth := F.Width[1];
    F.RenderHeight := F.Height;
  end;
end;

function TileLog2(sz, tgt: Integer): Integer;
begin
  Result := 0;
  while (sz shl Result) < tgt do Inc(Result);
end;

procedure SetDefaultLfDeltas(var D: TLfModeRefDeltas);
begin
  D.ModeDelta[0] := 0; D.ModeDelta[1] := 0;
  D.RefDelta[0] := 1; D.RefDelta[1] := 0; D.RefDelta[2] := 0; D.RefDelta[3] := 0;
  D.RefDelta[4] := -1; D.RefDelta[5] := 0; D.RefDelta[6] := -1; D.RefDelta[7] := -1;
end;

function IsInterOrSwitch(const F: TFrameHdr): Boolean; inline;
begin Result := (F.FrameType and 1) <> 0; end;

procedure ParseFrameHdr(const S: TSeqHdr; const Refs: TRefHdrs; TemporalId, SpatialId: Integer;
  Data: PByte; Size: NativeInt; out F: TFrameHdr; out HdrBits: Int64);
var
  B: TAv1Bits;
  i, j, k, refidx, earliestRef, diff, sbszMin1, sbszLog2, sbw, sbh, maxTileWidthSb,
  maxTileAreaSb, minLog2Tiles, tileW, tileH, sbx, sby, widest, maxTileHeightSb,
  poc, offBefore, offAfter, offBeforeIdx, offAfterIdx, offBefore2, offBefore2Idx,
  refpoc, bits, shift, numYPos, numUvPos, pl: Integer;
  latestOffset, earliestOffset: Integer;
  uEarliest, uLatest, hint: LongWord;
  frameOffset: array[0..7] of Integer;
  deltaLossless: Boolean;
  refGmv: TWarpParams;
  R: PFrameHdr;
  useRef: Boolean;
  mat: ^TWarpParams;
begin
  FillChar(F, SizeOf(F), 0);
  F.TemporalId := TemporalId; F.SpatialId := SpatialId;
  for i := 0 to 6 do DefaultWarpParams(F.Gmv[i]);
  for i := 0 to 7 do F.Segmentation.SegData.D[i].Ref := -1;
  F.SubpelFilterMode := 0;
  B := TAv1Bits.Create(Data, Size);
  try
    if not S.ReducedStillPictureHeader then F.ShowExistingFrame := B.f(1) = 1;
    if F.ShowExistingFrame then
    begin
      F.ExistingFrameIdx := B.f(3);
      if S.DecoderModelInfoPresent and not S.EqualPictureInterval then
        B.f(S.FramePresentationDelayLength);
      if S.FrameIdNumbersPresent then F.FrameId := B.f(S.FrameIdNBits);
      HdrBits := B.BitPosition;
      Exit;
    end;

    if S.ReducedStillPictureHeader then
    begin
      F.FrameType := KEY_FRAME;
      F.ShowFrame := True;
    end
    else
    begin
      F.FrameType := B.f(2);
      F.ShowFrame := B.f(1) = 1;
    end;
    if F.ShowFrame then
    begin
      if S.DecoderModelInfoPresent and not S.EqualPictureInterval then
        B.f(S.FramePresentationDelayLength);
      F.ShowableFrame := F.FrameType <> KEY_FRAME;
    end
    else
      F.ShowableFrame := B.f(1) = 1;
    F.ErrorResilientMode := ((F.FrameType = KEY_FRAME) and F.ShowFrame) or
      (F.FrameType = SWITCH_FRAME) or S.ReducedStillPictureHeader;
    if not F.ErrorResilientMode then F.ErrorResilientMode := B.f(1) = 1;
    F.DisableCdfUpdate := B.f(1) = 1;
    if S.ScreenContentTools = ADAPTIVE then F.AllowScreenContentTools := B.f(1)
    else F.AllowScreenContentTools := S.ScreenContentTools;
    if F.AllowScreenContentTools <> 0 then
    begin
      if S.ForceIntegerMv = ADAPTIVE then F.ForceIntegerMv := B.f(1)
      else F.ForceIntegerMv := S.ForceIntegerMv;
    end;
    if not IsInterOrSwitch(F) then F.ForceIntegerMv := 1;
    if S.FrameIdNumbersPresent then F.FrameId := B.f(S.FrameIdNBits);
    if not S.ReducedStillPictureHeader then
    begin
      if F.FrameType = SWITCH_FRAME then F.FrameSizeOverride := True
      else F.FrameSizeOverride := B.f(1) = 1;
    end;
    if S.OrderHint then F.FrameOffset := B.f(S.OrderHintNBits);
    if (not F.ErrorResilientMode) and IsInterOrSwitch(F) then F.PrimaryRefFrame := B.f(3)
    else F.PrimaryRefFrame := PRIMARY_REF_NONE;

    if S.DecoderModelInfoPresent then
    begin
      if B.f(1) = 1 then   // buffer_removal_time_present
        for i := 0 to S.NumOperatingPoints - 1 do
          if S.OpDecoderModelParamPresent[i] then
            if (S.OpIdc[i] = 0) or ((((S.OpIdc[i] shr TemporalId) and 1) <> 0) and
               (((S.OpIdc[i] shr (SpatialId + 8)) and 1) <> 0)) then
              B.f(S.BufferRemovalDelayLength);
    end;

    if not IsInterOrSwitch(F) then
    begin
      if (F.FrameType = KEY_FRAME) and F.ShowFrame then F.RefreshFrameFlags := $FF
      else F.RefreshFrameFlags := B.f(8);
      if (F.RefreshFrameFlags <> $FF) and F.ErrorResilientMode and S.OrderHint then
        for i := 0 to 7 do B.f(S.OrderHintNBits);
      ReadFrameSize(B, S, Refs, F, False);
      if (F.AllowScreenContentTools <> 0) and not F.SuperResEnabled then
        F.AllowIntrabc := B.f(1) = 1;
    end
    else
    begin
      if F.FrameType = SWITCH_FRAME then F.RefreshFrameFlags := $FF
      else F.RefreshFrameFlags := B.f(8);
      if F.ErrorResilientMode and S.OrderHint then
        for i := 0 to 7 do B.f(S.OrderHintNBits);
      if S.OrderHint then
      begin
        F.FrameRefShortSignaling := B.f(1) = 1;
        if F.FrameRefShortSignaling then
        begin
          F.RefIdx[0] := B.f(3);
          F.RefIdx[1] := -1; F.RefIdx[2] := -1;
          F.RefIdx[3] := B.f(3);
          F.RefIdx[4] := -1; F.RefIdx[5] := -1; F.RefIdx[6] := -1;
          earliestRef := -1; earliestOffset := MaxInt;
          for i := 0 to 7 do
          begin
            if Refs[i] = nil then raise EAv1Header.Create('AV1: missing reference');
            diff := GetPocDiff(S.OrderHintNBits, Refs[i]^.FrameOffset, F.FrameOffset);
            frameOffset[i] := diff;
            if diff < earliestOffset then begin earliestOffset := diff; earliestRef := i; end;
          end;
          frameOffset[F.RefIdx[0]] := Low(Integer);
          frameOffset[F.RefIdx[3]] := Low(Integer);
          refidx := -1; latestOffset := 0;
          for i := 0 to 7 do
            if frameOffset[i] >= latestOffset then begin latestOffset := frameOffset[i]; refidx := i; end;
          if refidx >= 0 then frameOffset[refidx] := Low(Integer);
          F.RefIdx[6] := refidx;
          for i := 4 to 5 do
          begin
            uEarliest := 255; refidx := -1;
            for j := 0 to 7 do
            begin
              hint := LongWord(frameOffset[j]);
              if hint < uEarliest then begin uEarliest := hint; refidx := j; end;
            end;
            if refidx >= 0 then frameOffset[refidx] := Low(Integer);
            F.RefIdx[i] := refidx;
          end;
          for i := 1 to 6 do
          begin
            refidx := F.RefIdx[i];
            if refidx < 0 then
            begin
              uLatest := $FFFFFF00;   // ~UINT8_MAX
              for j := 0 to 7 do
              begin
                hint := LongWord(frameOffset[j]);
                if hint >= uLatest then begin uLatest := hint; refidx := j; end;
              end;
              if refidx >= 0 then frameOffset[refidx] := Low(Integer);
              if refidx >= 0 then F.RefIdx[i] := refidx else F.RefIdx[i] := earliestRef;
            end;
          end;
        end;
      end;
      for i := 0 to 6 do
      begin
        if not F.FrameRefShortSignaling then F.RefIdx[i] := B.f(3);
        if S.FrameIdNumbersPresent then B.f(S.DeltaFrameIdNBits);
      end;
      useRef := (not F.ErrorResilientMode) and F.FrameSizeOverride;
      ReadFrameSize(B, S, Refs, F, useRef);
      if F.ForceIntegerMv = 0 then F.Hp := B.f(1) = 1;
      if B.f(1) = 1 then F.SubpelFilterMode := 4 else F.SubpelFilterMode := B.f(2);
      F.SwitchableMotionMode := B.f(1) = 1;
      if (not F.ErrorResilientMode) and S.RefFrameMvs and S.OrderHint and IsInterOrSwitch(F) then
        F.UseRefFrameMvs := B.f(1) = 1;
    end;

    if (not S.ReducedStillPictureHeader) and (not F.DisableCdfUpdate) then
      F.RefreshContext := B.f(1) = 0;

    // tiling
    F.Tiling.Uniform := B.f(1) = 1;
    if S.Sb128 then begin sbszMin1 := 127; sbszLog2 := 7; end
    else begin sbszMin1 := 63; sbszLog2 := 6; end;
    sbw := (F.Width[0] + sbszMin1) shr sbszLog2;
    sbh := (F.Height + sbszMin1) shr sbszLog2;
    maxTileWidthSb := 4096 shr sbszLog2;
    maxTileAreaSb := (4096 * 2304) shr (2 * sbszLog2);
    F.Tiling.MinLog2Cols := TileLog2(maxTileWidthSb, sbw);
    F.Tiling.MaxLog2Cols := TileLog2(1, IMin(sbw, 64));
    F.Tiling.MaxLog2Rows := TileLog2(1, IMin(sbh, 64));
    minLog2Tiles := IMax(TileLog2(maxTileAreaSb, sbw * sbh), F.Tiling.MinLog2Cols);
    if F.Tiling.Uniform then
    begin
      F.Tiling.Log2Cols := F.Tiling.MinLog2Cols;
      while (F.Tiling.Log2Cols < F.Tiling.MaxLog2Cols) and (B.f(1) = 1) do Inc(F.Tiling.Log2Cols);
      tileW := 1 + ((sbw - 1) shr F.Tiling.Log2Cols);
      F.Tiling.Cols := 0; sbx := 0;
      while sbx < sbw do
      begin
        F.Tiling.ColStartSb[F.Tiling.Cols] := sbx;
        Inc(sbx, tileW); Inc(F.Tiling.Cols);
      end;
      F.Tiling.MinLog2Rows := IMax(minLog2Tiles - F.Tiling.Log2Cols, 0);
      F.Tiling.Log2Rows := F.Tiling.MinLog2Rows;
      while (F.Tiling.Log2Rows < F.Tiling.MaxLog2Rows) and (B.f(1) = 1) do Inc(F.Tiling.Log2Rows);
      tileH := 1 + ((sbh - 1) shr F.Tiling.Log2Rows);
      F.Tiling.Rows := 0; sby := 0;
      while sby < sbh do
      begin
        F.Tiling.RowStartSb[F.Tiling.Rows] := sby;
        Inc(sby, tileH); Inc(F.Tiling.Rows);
      end;
    end
    else
    begin
      F.Tiling.Cols := 0; widest := 0; maxTileAreaSb := sbw * sbh; sbx := 0;
      while (sbx < sbw) and (F.Tiling.Cols < 64) do
      begin
        k := IMin(sbw - sbx, maxTileWidthSb);
        if k > 1 then tileW := 1 + Integer(B.ns(k)) else tileW := 1;
        F.Tiling.ColStartSb[F.Tiling.Cols] := sbx;
        Inc(sbx, tileW);
        widest := IMax(widest, tileW);
        Inc(F.Tiling.Cols);
      end;
      F.Tiling.Log2Cols := TileLog2(1, F.Tiling.Cols);
      if minLog2Tiles <> 0 then maxTileAreaSb := maxTileAreaSb shr (minLog2Tiles + 1);
      maxTileHeightSb := IMax(maxTileAreaSb div widest, 1);
      F.Tiling.Rows := 0; sby := 0;
      while (sby < sbh) and (F.Tiling.Rows < 64) do
      begin
        k := IMin(sbh - sby, maxTileHeightSb);
        if k > 1 then tileH := 1 + Integer(B.ns(k)) else tileH := 1;
        F.Tiling.RowStartSb[F.Tiling.Rows] := sby;
        Inc(sby, tileH);
        Inc(F.Tiling.Rows);
      end;
      F.Tiling.Log2Rows := TileLog2(1, F.Tiling.Rows);
    end;
    F.Tiling.ColStartSb[F.Tiling.Cols] := sbw;
    F.Tiling.RowStartSb[F.Tiling.Rows] := sbh;
    if (F.Tiling.Log2Cols <> 0) or (F.Tiling.Log2Rows <> 0) then
    begin
      F.Tiling.Update := B.f(F.Tiling.Log2Cols + F.Tiling.Log2Rows);
      if F.Tiling.Update >= F.Tiling.Cols * F.Tiling.Rows then
        raise EAv1Header.Create('AV1: invalid context_update_tile_id');
      F.Tiling.NBytes := B.f(2) + 1;
    end;

    // quantization
    F.Quant.Yac := B.f(8);
    if B.f(1) = 1 then F.Quant.YdcDelta := B.su(6);
    if not S.Monochrome then
    begin
      if S.SeparateUvDeltaQ then k := B.f(1) else k := 0;
      if B.f(1) = 1 then F.Quant.UdcDelta := B.su(6);
      if B.f(1) = 1 then F.Quant.UacDelta := B.su(6);
      if k <> 0 then
      begin
        if B.f(1) = 1 then F.Quant.VdcDelta := B.su(6);
        if B.f(1) = 1 then F.Quant.VacDelta := B.su(6);
      end
      else
      begin
        F.Quant.VdcDelta := F.Quant.UdcDelta;
        F.Quant.VacDelta := F.Quant.UacDelta;
      end;
    end;
    F.Quant.Qm := B.f(1) = 1;
    if F.Quant.Qm then
    begin
      F.Quant.QmY := B.f(4);
      F.Quant.QmU := B.f(4);
      if S.SeparateUvDeltaQ then F.Quant.QmV := B.f(4) else F.Quant.QmV := F.Quant.QmU;
    end;

    // segmentation
    F.Segmentation.Enabled := B.f(1) = 1;
    if F.Segmentation.Enabled then
    begin
      if F.PrimaryRefFrame = PRIMARY_REF_NONE then
      begin
        F.Segmentation.UpdateMap := True;
        F.Segmentation.UpdateData := True;
      end
      else
      begin
        F.Segmentation.UpdateMap := B.f(1) = 1;
        if F.Segmentation.UpdateMap then F.Segmentation.Temporal := B.f(1) = 1;
        F.Segmentation.UpdateData := B.f(1) = 1;
      end;
      if F.Segmentation.UpdateData then
      begin
        F.Segmentation.SegData.LastActiveSegId := -1;
        for i := 0 to 7 do
          with F.Segmentation.SegData.D[i] do
          begin
            if B.f(1) = 1 then begin DeltaQ := B.su(8); F.Segmentation.SegData.LastActiveSegId := i; end;
            if B.f(1) = 1 then begin DeltaLfYV := B.su(6); F.Segmentation.SegData.LastActiveSegId := i; end;
            if B.f(1) = 1 then begin DeltaLfYH := B.su(6); F.Segmentation.SegData.LastActiveSegId := i; end;
            if B.f(1) = 1 then begin DeltaLfU := B.su(6); F.Segmentation.SegData.LastActiveSegId := i; end;
            if B.f(1) = 1 then begin DeltaLfV := B.su(6); F.Segmentation.SegData.LastActiveSegId := i; end;
            if B.f(1) = 1 then
            begin
              Ref := B.f(3);
              F.Segmentation.SegData.LastActiveSegId := i;
              F.Segmentation.SegData.Preskip := True;
            end
            else Ref := -1;
            Skip := B.f(1) = 1;
            if Skip then
            begin
              F.Segmentation.SegData.LastActiveSegId := i;
              F.Segmentation.SegData.Preskip := True;
            end;
            GlobalMv := B.f(1) = 1;
            if GlobalMv then
            begin
              F.Segmentation.SegData.LastActiveSegId := i;
              F.Segmentation.SegData.Preskip := True;
            end;
          end;
      end
      else
      begin
        R := Refs[F.RefIdx[F.PrimaryRefFrame]];
        if R = nil then raise EAv1Header.Create('AV1: missing primary reference');
        F.Segmentation.SegData := R^.Segmentation.SegData;
      end;
    end;

    // delta q / lf
    if F.Quant.Yac <> 0 then
    begin
      F.DeltaQPresent := B.f(1) = 1;
      if F.DeltaQPresent then
      begin
        F.DeltaQResLog2 := B.f(2);
        if not F.AllowIntrabc then
        begin
          F.DeltaLfPresent := B.f(1) = 1;
          if F.DeltaLfPresent then
          begin
            F.DeltaLfResLog2 := B.f(2);
            F.DeltaLfMulti := B.f(1) = 1;
          end;
        end;
      end;
    end;

    deltaLossless := (F.Quant.YdcDelta = 0) and (F.Quant.UdcDelta = 0) and
      (F.Quant.UacDelta = 0) and (F.Quant.VdcDelta = 0) and (F.Quant.VacDelta = 0);
    F.AllLossless := True;
    for i := 0 to 7 do
    begin
      if F.Segmentation.Enabled then
      begin
        k := F.Quant.Yac + F.Segmentation.SegData.D[i].DeltaQ;
        if k < 0 then k := 0 else if k > 255 then k := 255;
        F.Segmentation.QIdx[i] := k;
      end
      else F.Segmentation.QIdx[i] := F.Quant.Yac;
      F.Segmentation.Lossless[i] := (F.Segmentation.QIdx[i] = 0) and deltaLossless;
      F.AllLossless := F.AllLossless and F.Segmentation.Lossless[i];
    end;

    // loop filter
    if F.AllLossless or F.AllowIntrabc then
    begin
      F.LoopFilter.ModeRefDeltaEnabled := True;
      F.LoopFilter.ModeRefDeltaUpdate := True;
      SetDefaultLfDeltas(F.LoopFilter.ModeRefDeltas);
    end
    else
    begin
      F.LoopFilter.LevelY[0] := B.f(6);
      F.LoopFilter.LevelY[1] := B.f(6);
      if (not S.Monochrome) and ((F.LoopFilter.LevelY[0] <> 0) or (F.LoopFilter.LevelY[1] <> 0)) then
      begin
        F.LoopFilter.LevelU := B.f(6);
        F.LoopFilter.LevelV := B.f(6);
      end;
      F.LoopFilter.Sharpness := B.f(3);
      if F.PrimaryRefFrame = PRIMARY_REF_NONE then
        SetDefaultLfDeltas(F.LoopFilter.ModeRefDeltas)
      else
      begin
        R := Refs[F.RefIdx[F.PrimaryRefFrame]];
        if R = nil then raise EAv1Header.Create('AV1: missing primary reference');
        F.LoopFilter.ModeRefDeltas := R^.LoopFilter.ModeRefDeltas;
      end;
      F.LoopFilter.ModeRefDeltaEnabled := B.f(1) = 1;
      if F.LoopFilter.ModeRefDeltaEnabled then
      begin
        F.LoopFilter.ModeRefDeltaUpdate := B.f(1) = 1;
        if F.LoopFilter.ModeRefDeltaUpdate then
        begin
          for i := 0 to 7 do
            if B.f(1) = 1 then F.LoopFilter.ModeRefDeltas.RefDelta[i] := B.su(6);
          for i := 0 to 1 do
            if B.f(1) = 1 then F.LoopFilter.ModeRefDeltas.ModeDelta[i] := B.su(6);
        end;
      end;
    end;

    // cdef
    if (not F.AllLossless) and S.Cdef and (not F.AllowIntrabc) then
    begin
      F.Cdef.Damping := B.f(2) + 3;
      F.Cdef.NBits := B.f(2);
      for i := 0 to (1 shl F.Cdef.NBits) - 1 do
      begin
        F.Cdef.YStrength[i] := B.f(6);
        if not S.Monochrome then F.Cdef.UvStrength[i] := B.f(6);
      end;
    end;

    // loop restoration
    if ((not F.AllLossless) or F.SuperResEnabled) and S.Restoration and (not F.AllowIntrabc) then
    begin
      F.Restoration.LrType[0] := B.f(2);
      if not S.Monochrome then
      begin
        F.Restoration.LrType[1] := B.f(2);
        F.Restoration.LrType[2] := B.f(2);
      end;
      if (F.Restoration.LrType[0] <> 0) or (F.Restoration.LrType[1] <> 0) or (F.Restoration.LrType[2] <> 0) then
      begin
        F.Restoration.UnitSize[0] := 6 + Ord(S.Sb128);
        if B.f(1) = 1 then
        begin
          Inc(F.Restoration.UnitSize[0]);
          if not S.Sb128 then Inc(F.Restoration.UnitSize[0], B.f(1));
        end;
        F.Restoration.UnitSize[1] := F.Restoration.UnitSize[0];
        if ((F.Restoration.LrType[1] <> 0) or (F.Restoration.LrType[2] <> 0)) and
           (S.SsHor = 1) and (S.SsVer = 1) then
          Dec(F.Restoration.UnitSize[1], B.f(1));
      end
      else F.Restoration.UnitSize[0] := 8;
    end;

    if not F.AllLossless then
    begin
      if B.f(1) = 1 then F.TxfmMode := TX_SWITCHABLE else F.TxfmMode := TX_LARGEST;
    end
    else F.TxfmMode := TX_4X4_ONLY;
    if IsInterOrSwitch(F) then F.SwitchableCompRefs := B.f(1) = 1;

    if F.SwitchableCompRefs and IsInterOrSwitch(F) and S.OrderHint then
    begin
      poc := F.FrameOffset;
      offBefore := -1; offAfter := -1; offBeforeIdx := 0; offAfterIdx := 0;
      for i := 0 to 6 do
      begin
        R := Refs[F.RefIdx[i]];
        if R = nil then raise EAv1Header.Create('AV1: missing reference');
        refpoc := R^.FrameOffset;
        diff := GetPocDiff(S.OrderHintNBits, refpoc, poc);
        if diff > 0 then
        begin
          if (offAfter < 0) or (GetPocDiff(S.OrderHintNBits, offAfter, refpoc) > 0) then
          begin offAfter := refpoc; offAfterIdx := i; end;
        end
        else if (diff < 0) and ((offBefore < 0) or (GetPocDiff(S.OrderHintNBits, refpoc, offBefore) > 0)) then
        begin offBefore := refpoc; offBeforeIdx := i; end;
      end;
      if (offBefore or offAfter) >= 0 then
      begin
        F.SkipModeRefs[0] := IMin(offBeforeIdx, offAfterIdx);
        F.SkipModeRefs[1] := IMax(offBeforeIdx, offAfterIdx);
        F.SkipModeAllowed := True;
      end
      else if offBefore >= 0 then
      begin
        offBefore2 := -1; offBefore2Idx := 0;
        for i := 0 to 6 do
        begin
          refpoc := Refs[F.RefIdx[i]]^.FrameOffset;
          if GetPocDiff(S.OrderHintNBits, refpoc, offBefore) < 0 then
            if (offBefore2 < 0) or (GetPocDiff(S.OrderHintNBits, refpoc, offBefore2) > 0) then
            begin offBefore2 := refpoc; offBefore2Idx := i; end;
        end;
        if offBefore2 >= 0 then
        begin
          F.SkipModeRefs[0] := IMin(offBeforeIdx, offBefore2Idx);
          F.SkipModeRefs[1] := IMax(offBeforeIdx, offBefore2Idx);
          F.SkipModeAllowed := True;
        end;
      end;
    end;
    if F.SkipModeAllowed then F.SkipModeEnabled := B.f(1) = 1;
    if (not F.ErrorResilientMode) and IsInterOrSwitch(F) and S.WarpedMotion then
      F.WarpMotion := B.f(1) = 1;
    F.ReducedTxtpSet := B.f(1) = 1;

    // global motion
    if IsInterOrSwitch(F) then
      for i := 0 to 6 do
      begin
        if B.f(1) = 0 then F.Gmv[i].WmType := WM_TYPE_IDENTITY
        else if B.f(1) = 1 then F.Gmv[i].WmType := WM_TYPE_ROT_ZOOM
        else if B.f(1) = 1 then F.Gmv[i].WmType := WM_TYPE_TRANSLATION
        else F.Gmv[i].WmType := WM_TYPE_AFFINE;
        if F.Gmv[i].WmType = WM_TYPE_IDENTITY then Continue;
        if F.PrimaryRefFrame = PRIMARY_REF_NONE then DefaultWarpParams(refGmv)
        else
        begin
          R := Refs[F.RefIdx[F.PrimaryRefFrame]];
          if R = nil then raise EAv1Header.Create('AV1: missing primary reference');
          refGmv := R^.Gmv[i];
        end;
        mat := @F.Gmv[i];
        if F.Gmv[i].WmType >= WM_TYPE_ROT_ZOOM then
        begin
          mat^.Matrix[2] := (1 shl 16) + 2 * GetBitsSubexp(B, SarLongint(refGmv.Matrix[2] - (1 shl 16), 1), 12);
          mat^.Matrix[3] := 2 * GetBitsSubexp(B, SarLongint(refGmv.Matrix[3], 1), 12);
          bits := 12; shift := 10;
        end
        else
        begin
          bits := 9 - Ord(not F.Hp);
          shift := 13 + Ord(not F.Hp);
        end;
        if F.Gmv[i].WmType = WM_TYPE_AFFINE then
        begin
          mat^.Matrix[4] := 2 * GetBitsSubexp(B, SarLongint(refGmv.Matrix[4], 1), 12);
          mat^.Matrix[5] := (1 shl 16) + 2 * GetBitsSubexp(B, SarLongint(refGmv.Matrix[5] - (1 shl 16), 1), 12);
        end
        else
        begin
          mat^.Matrix[4] := -mat^.Matrix[3];
          mat^.Matrix[5] := mat^.Matrix[2];
        end;
        mat^.Matrix[0] := GetBitsSubexp(B, SarLongint(refGmv.Matrix[0], shift), bits) * (1 shl shift);
        mat^.Matrix[1] := GetBitsSubexp(B, SarLongint(refGmv.Matrix[1], shift), bits) * (1 shl shift);
      end;

    // film grain
    if S.FilmGrainPresent and (F.ShowFrame or F.ShowableFrame) then
    begin
      F.FilmGrain.Present := B.f(1) = 1;
      if F.FilmGrain.Present then
      begin
        k := B.f(16);   // seed
        F.FilmGrain.Update := (F.FrameType <> INTER_FRAME) or (B.f(1) = 1);
        if not F.FilmGrain.Update then
        begin
          refidx := B.f(3);
          j := -1;
          for i := 0 to 6 do if F.RefIdx[i] = refidx then begin j := i; Break; end;
          if (j < 0) or (Refs[refidx] = nil) then raise EAv1Header.Create('AV1: invalid film grain ref');
          F.FilmGrain.Data := Refs[refidx]^.FilmGrain.Data;
          F.FilmGrain.Data.Seed := k;
        end
        else
          with F.FilmGrain.Data do
          begin
            Seed := k;
            NumYPoints := B.f(4);
            if NumYPoints > 14 then raise EAv1Header.Create('AV1: invalid film grain');
            for i := 0 to NumYPoints - 1 do
            begin
              YPoints[i][0] := B.f(8);
              if (i > 0) and (YPoints[i-1][0] >= YPoints[i][0]) then raise EAv1Header.Create('AV1: invalid film grain');
              YPoints[i][1] := B.f(8);
            end;
            if not S.Monochrome then ChromaScalingFromLuma := B.f(1) = 1;
            if S.Monochrome or ChromaScalingFromLuma or ((S.SsVer = 1) and (S.SsHor = 1) and (NumYPoints = 0)) then
            begin
              NumUvPoints[0] := 0; NumUvPoints[1] := 0;
            end
            else
              for pl := 0 to 1 do
              begin
                NumUvPoints[pl] := B.f(4);
                if NumUvPoints[pl] > 10 then raise EAv1Header.Create('AV1: invalid film grain');
                for i := 0 to NumUvPoints[pl] - 1 do
                begin
                  UvPoints[pl][i][0] := B.f(8);
                  if (i > 0) and (UvPoints[pl][i-1][0] >= UvPoints[pl][i][0]) then raise EAv1Header.Create('AV1: invalid film grain');
                  UvPoints[pl][i][1] := B.f(8);
                end;
              end;
            if (S.SsHor = 1) and (S.SsVer = 1) and ((NumUvPoints[0] <> 0) <> (NumUvPoints[1] <> 0)) then
              raise EAv1Header.Create('AV1: invalid film grain');
            ScalingShift := B.f(2) + 8;
            ArCoeffLag := B.f(2);
            numYPos := 2 * ArCoeffLag * (ArCoeffLag + 1);
            if NumYPoints <> 0 then
              for i := 0 to numYPos - 1 do ArCoeffsY[i] := Integer(B.f(8)) - 128;
            for pl := 0 to 1 do
              if (NumUvPoints[pl] <> 0) or ChromaScalingFromLuma then
              begin
                numUvPos := numYPos + Ord(NumYPoints <> 0);
                for i := 0 to numUvPos - 1 do ArCoeffsUv[pl][i] := Integer(B.f(8)) - 128;
                if NumYPoints = 0 then ArCoeffsUv[pl][numUvPos] := 0;
              end;
            ArCoeffShift := B.f(2) + 6;
            GrainScaleShift := B.f(2);
            for pl := 0 to 1 do
              if NumUvPoints[pl] <> 0 then
              begin
                UvMult[pl] := Integer(B.f(8)) - 128;
                UvLumaMult[pl] := Integer(B.f(8)) - 128;
                UvOffset[pl] := Integer(B.f(9)) - 256;
              end;
            OverlapFlag := B.f(1) = 1;
            ClipToRestrictedRange := B.f(1) = 1;
          end;
      end;
    end;
    HdrBits := B.BitPosition;
  finally
    B.Free;
  end;
end;

end.
