unit Av1.Frame;

// AV1 frame (uncompressed) header parsing for still images.
//
// AVIF coded images are single KEY_FRAMEs, so this implements the intra/key path
// of the uncompressed_header syntax (spec 5.9.2) and its sub-syntaxes: frame
// size, superres, render size, tile info, quantization, segmentation, delta-Q /
// delta-LF, loop filter, CDEF, loop restoration, tx mode. Inter-only syntax
// (reference frames, motion, global motion, skip mode) is not needed and is
// omitted; if such a stream is encountered the parse of an intra header still
// succeeds because those branches are gated on frame_type.
//
// Reference: AV1 spec section 5.9.

{$mode delphi}{$H+}

interface

uses
  SysUtils, Av1.Bits, Av1.Obu;

var
  DebugFH: Boolean = False;

const
  KEY_FRAME = 0;
  INTER_FRAME = 1;
  INTRA_ONLY_FRAME = 2;
  SWITCH_FRAME = 3;

  NUM_REF_FRAMES = 8;
  PRIMARY_REF_NONE = 7;
  MAX_SEGMENTS = 8;
  SEG_LVL_MAX = 8;
  SEG_LVL_ALT_Q = 0;
  SEG_LVL_REF_FRAME = 5;
  SEG_LVL_SKIP = 6;
  SEG_LVL_GLOBALMV = 7;
  MAX_TILE_WIDTH = 4096;
  MAX_TILE_AREA = 4096 * 2304;
  MAX_TILE_COLS = 64;
  MAX_TILE_ROWS = 64;

  RESTORE_NONE = 0;
  RESTORE_SWITCHABLE = 3;
  RESTORE_WIENER = 1;
  RESTORE_SGRPROJ = 2;

  ONLY_4X4 = 0;
  TX_MODE_LARGEST = 1;
  TX_MODE_SELECT = 2;

  Segmentation_Feature_Bits: array[0..SEG_LVL_MAX-1] of Integer =
    (8, 6, 6, 6, 6, 3, 0, 0);
  Segmentation_Feature_Signed: array[0..SEG_LVL_MAX-1] of Integer =
    (1, 1, 1, 1, 1, 0, 0, 0);
  Segmentation_Feature_Max: array[0..SEG_LVL_MAX-1] of Integer =
    (255, 63, 63, 63, 63, 7, 0, 0);

type
  TAv1FrameHeader = record
    FrameType: Integer;
    ShowFrame: Boolean;
    ShowableFrame: Boolean;
    ErrorResilientMode: Boolean;
    DisableCdfUpdate: Boolean;
    AllowScreenContentTools: Integer;
    ForceIntegerMv: Integer;
    FrameSizeOverride: Boolean;
    OrderHint: Integer;
    PrimaryRefFrame: Integer;
    // sizes
    FrameWidth, FrameHeight: Integer;
    UpscaledWidth: Integer;
    RenderWidth, RenderHeight: Integer;
    SuperresDenom: Integer;
    UseSuperres: Boolean;
    MiCols, MiRows: Integer;
    // features
    AllowIntrabc: Boolean;
    DisableFrameEndUpdateCdf: Boolean;
    // tiles
    TileColsLog2, TileRowsLog2: Integer;
    TileCols, TileRows: Integer;
    MiColStarts: array[0..MAX_TILE_COLS] of Integer;
    MiRowStarts: array[0..MAX_TILE_ROWS] of Integer;
    ContextUpdateTileId: Integer;
    TileSizeBytes: Integer;
    // quantization
    BaseQIdx: Integer;
    DeltaQYDc: Integer;
    DeltaQUDc, DeltaQUAc: Integer;
    DeltaQVDc, DeltaQVAc: Integer;
    UsingQMatrix: Boolean;
    QmY, QmU, QmV: Integer;
    // segmentation
    SegmentationEnabled: Boolean;
    FeatureEnabled: array[0..MAX_SEGMENTS-1, 0..SEG_LVL_MAX-1] of Boolean;
    FeatureData: array[0..MAX_SEGMENTS-1, 0..SEG_LVL_MAX-1] of Integer;
    SegQMLevel: array[0..2, 0..MAX_SEGMENTS-1] of Integer;
    // delta q / lf
    DeltaQPresent: Boolean;
    DeltaQRes: Integer;
    DeltaLfPresent: Boolean;
    DeltaLfRes: Integer;
    DeltaLfMulti: Boolean;
    // loop filter
    LoopFilterLevel: array[0..3] of Integer;
    LoopFilterSharpness: Integer;
    LoopFilterDeltaEnabled: Boolean;
    LoopFilterRefDeltas: array[0..NUM_REF_FRAMES-1] of Integer;
    LoopFilterModeDeltas: array[0..1] of Integer;
    // cdef
    CdefDampingMinus3: Integer;
    CdefBits: Integer;
    CdefYPriStrength: array[0..7] of Integer;
    CdefYSecStrength: array[0..7] of Integer;
    CdefUVPriStrength: array[0..7] of Integer;
    CdefUVSecStrength: array[0..7] of Integer;
    // loop restoration
    FrameRestorationType: array[0..2] of Integer;
    UsesLr: Boolean;
    LoopRestorationSize: array[0..2] of Integer;
    // tx / other
    TxMode: Integer;
    ReducedTxSet: Boolean;
    CodedLossless: Boolean;
    AllLossless: Boolean;
    LosslessArray: array[0..MAX_SEGMENTS-1] of Boolean;
  end;

procedure ParseFrameHeader(const ASeq: TAv1SequenceHeader;
  AData: PByte; ASize: NativeInt; out AFh: TAv1FrameHeader;
  out AEndByte: NativeInt);

implementation

function IfMin(A, B: Integer): Integer;
begin if A < B then Result := A else Result := B; end;

function IfMax(A, B: Integer): Integer;
begin if A > B then Result := A else Result := B; end;

function IfMaxI(A, B: Integer): Integer;
begin if A > B then Result := A else Result := B; end;

function TileLog2(BlkSize, Target: Integer): Integer;
begin
  Result := 0;
  while (BlkSize shl Result) < Target do
    Inc(Result);
end;

function GetQIndex(const AFh: TAv1FrameHeader; ASegmentId: Integer): Integer;
begin
  // Ignoring per-segment delta for the lossless test (base only + seg feature).
  if AFh.SegmentationEnabled and AFh.FeatureEnabled[ASegmentId, SEG_LVL_ALT_Q] then
  begin
    Result := AFh.BaseQIdx + AFh.FeatureData[ASegmentId, SEG_LVL_ALT_Q];
    if Result < 0 then Result := 0;
    if Result > 255 then Result := 255;
  end
  else
    Result := AFh.BaseQIdx;
end;

procedure ReadDeltaQ(B: TAv1Bits; out V: Integer);
begin
  if B.f(1) = 1 then  // delta_coded
    V := B.su(6)
  else
    V := 0;
end;

procedure ParseFrameSize(B: TAv1Bits; const ASeq: TAv1SequenceHeader;
  var AFh: TAv1FrameHeader);
begin
  if AFh.FrameSizeOverride then
  begin
    AFh.FrameWidth := B.f(ASeq.FrameWidthBits) + 1;
    AFh.FrameHeight := B.f(ASeq.FrameHeightBits) + 1;
  end
  else
  begin
    AFh.FrameWidth := ASeq.MaxFrameWidth;
    AFh.FrameHeight := ASeq.MaxFrameHeight;
  end;
  // superres_params
  if ASeq.EnableSuperres then
    AFh.UseSuperres := B.f(1) = 1
  else
    AFh.UseSuperres := False;
  if AFh.UseSuperres then
    AFh.SuperresDenom := B.f(3) + 9   // SUPERRES_DENOM_MIN=9
  else
    AFh.SuperresDenom := 8;           // SUPERRES_NUM
  AFh.UpscaledWidth := AFh.FrameWidth;
  AFh.FrameWidth := (AFh.UpscaledWidth * 8 + (AFh.SuperresDenom div 2)) div AFh.SuperresDenom;
  // compute_image_size
  AFh.MiCols := 2 * ((AFh.FrameWidth + 7) shr 3);
  AFh.MiRows := 2 * ((AFh.FrameHeight + 7) shr 3);
end;

procedure ParseRenderSize(B: TAv1Bits; var AFh: TAv1FrameHeader);
begin
  if B.f(1) = 1 then // render_and_frame_size_different
  begin
    AFh.RenderWidth := B.f(16) + 1;
    AFh.RenderHeight := B.f(16) + 1;
  end
  else
  begin
    AFh.RenderWidth := AFh.UpscaledWidth;
    AFh.RenderHeight := AFh.FrameHeight;
  end;
end;

procedure ParseTileInfo(B: TAv1Bits; const ASeq: TAv1SequenceHeader;
  var AFh: TAv1FrameHeader);
var
  sbCols, sbRows, sbShift, sbSize: Integer;
  maxTileWidthSb, maxTileAreaSb: Integer;
  minLog2TileCols, maxLog2TileCols, maxLog2TileRows, minLog2TileRows, minLog2Tiles: Integer;
  uniform: Boolean;
  startSb, i, sizeSb, widestTileSb, maxWidth, maxHeight: Integer;
  tileWidthSb, tileHeightSb: Integer;
  incrementTileColsLog2: Integer;
begin
  if ASeq.Use128x128Superblock then begin sbShift := 5; end else begin sbShift := 4; end;
  sbSize := sbShift + 2;
  sbCols := (AFh.MiCols + (1 shl sbShift) - 1) shr sbShift;
  sbRows := (AFh.MiRows + (1 shl sbShift) - 1) shr sbShift;
  maxTileWidthSb := MAX_TILE_WIDTH shr sbSize;
  maxTileAreaSb := MAX_TILE_AREA shr (2 * sbSize);
  minLog2TileCols := TileLog2(maxTileWidthSb, sbCols);
  maxLog2TileCols := TileLog2(1, IfMin(sbCols, MAX_TILE_COLS));
  maxLog2TileRows := TileLog2(1, IfMin(sbRows, MAX_TILE_ROWS));
  minLog2Tiles := IfMaxI(minLog2TileCols, TileLog2(maxTileAreaSb, sbRows * sbCols));

  uniform := B.f(1) = 1;
  if uniform then
  begin
    AFh.TileColsLog2 := minLog2TileCols;
    while AFh.TileColsLog2 < maxLog2TileCols do
    begin
      if B.f(1) = 1 then Inc(AFh.TileColsLog2) else Break;
    end;
    tileWidthSb := (sbCols + (1 shl AFh.TileColsLog2) - 1) shr AFh.TileColsLog2;
    i := 0; startSb := 0;
    while startSb < sbCols do
    begin
      AFh.MiColStarts[i] := startSb shl sbShift;
      Inc(i);
      Inc(startSb, tileWidthSb);
    end;
    AFh.MiColStarts[i] := AFh.MiCols;
    AFh.TileCols := i;

    minLog2TileRows := IfMaxI(minLog2Tiles - AFh.TileColsLog2, 0);
    AFh.TileRowsLog2 := minLog2TileRows;
    while AFh.TileRowsLog2 < maxLog2TileRows do
    begin
      if B.f(1) = 1 then Inc(AFh.TileRowsLog2) else Break;
    end;
    tileHeightSb := (sbRows + (1 shl AFh.TileRowsLog2) - 1) shr AFh.TileRowsLog2;
    i := 0; startSb := 0;
    while startSb < sbRows do
    begin
      AFh.MiRowStarts[i] := startSb shl sbShift;
      Inc(i);
      Inc(startSb, tileHeightSb);
    end;
    AFh.MiRowStarts[i] := AFh.MiRows;
    AFh.TileRows := i;
  end
  else
  begin
    widestTileSb := 0;
    startSb := 0; i := 0;
    while startSb < sbCols do
    begin
      AFh.MiColStarts[i] := startSb shl sbShift;
      maxWidth := IfMin(sbCols - startSb, maxTileWidthSb);
      sizeSb := B.ns(maxWidth) + 1;
      widestTileSb := IfMaxI(sizeSb, widestTileSb);
      Inc(startSb, sizeSb);
      Inc(i);
    end;
    AFh.MiColStarts[i] := AFh.MiCols;
    AFh.TileCols := i;
    AFh.TileColsLog2 := TileLog2(1, AFh.TileCols);

    if minLog2Tiles > 0 then
      maxTileAreaSb := (sbRows * sbCols) shr (minLog2Tiles + 1)
    else
      maxTileAreaSb := sbRows * sbCols;
    maxHeight := IfMax(maxTileAreaSb div widestTileSb, 1);
    startSb := 0; i := 0;
    while startSb < sbRows do
    begin
      AFh.MiRowStarts[i] := startSb shl sbShift;
      sizeSb := B.ns(IfMin(sbRows - startSb, maxHeight)) + 1;
      Inc(startSb, sizeSb);
      Inc(i);
    end;
    AFh.MiRowStarts[i] := AFh.MiRows;
    AFh.TileRows := i;
    AFh.TileRowsLog2 := TileLog2(1, AFh.TileRows);
  end;

  if (AFh.TileColsLog2 > 0) or (AFh.TileRowsLog2 > 0) then
  begin
    AFh.ContextUpdateTileId := B.f(AFh.TileRowsLog2 + AFh.TileColsLog2);
    AFh.TileSizeBytes := B.f(2) + 1;
  end
  else
  begin
    AFh.ContextUpdateTileId := 0;
    AFh.TileSizeBytes := 1;
  end;
end;

procedure ParseQuantizationParams(B: TAv1Bits; const ASeq: TAv1SequenceHeader;
  var AFh: TAv1FrameHeader);
var
  diffUvDelta: Boolean;
begin
  AFh.BaseQIdx := B.f(8);
  ReadDeltaQ(B, AFh.DeltaQYDc);
  if ASeq.NumPlanes > 1 then
  begin
    if ASeq.SeparateUvDeltaQ then
      diffUvDelta := B.f(1) = 1
    else
      diffUvDelta := False;
    ReadDeltaQ(B, AFh.DeltaQUDc);
    ReadDeltaQ(B, AFh.DeltaQUAc);
    if diffUvDelta then
    begin
      ReadDeltaQ(B, AFh.DeltaQVDc);
      ReadDeltaQ(B, AFh.DeltaQVAc);
    end
    else
    begin
      AFh.DeltaQVDc := AFh.DeltaQUDc;
      AFh.DeltaQVAc := AFh.DeltaQUAc;
    end;
  end;
  AFh.UsingQMatrix := B.f(1) = 1;
  if AFh.UsingQMatrix then
  begin
    AFh.QmY := B.f(4);
    AFh.QmU := B.f(4);
    if not ASeq.SeparateUvDeltaQ then
      AFh.QmV := AFh.QmU
    else
      AFh.QmV := B.f(4);
  end;
end;

procedure ParseSegmentationParams(B: TAv1Bits; var AFh: TAv1FrameHeader);
var
  i, j, bitsToRead, clippedValue, limit: Integer;
begin
  AFh.SegmentationEnabled := B.f(1) = 1;
  if AFh.SegmentationEnabled then
  begin
    // Intra/key frame: primary_ref_frame == NONE, so segmentation_update_map,
    // _temporal_update and _update_data are inferred (1,0,1) and not coded.
    for i := 0 to MAX_SEGMENTS - 1 do
      for j := 0 to SEG_LVL_MAX - 1 do
      begin
        AFh.FeatureEnabled[i, j] := B.f(1) = 1;
        clippedValue := 0;
        if AFh.FeatureEnabled[i, j] then
        begin
          bitsToRead := Segmentation_Feature_Bits[j];
          limit := Segmentation_Feature_Max[j];
          if Segmentation_Feature_Signed[j] = 1 then
          begin
            clippedValue := B.su(bitsToRead);
            if clippedValue < -limit then clippedValue := -limit;
            if clippedValue > limit then clippedValue := limit;
          end
          else
          begin
            clippedValue := B.f(bitsToRead);
            if clippedValue > limit then clippedValue := limit;
          end;
        end;
        AFh.FeatureData[i, j] := clippedValue;
      end;
  end;
end;

procedure ParseLoopFilterParams(B: TAv1Bits; const ASeq: TAv1SequenceHeader;
  var AFh: TAv1FrameHeader);
var
  i: Integer;
begin
  if AFh.CodedLossless or AFh.AllowIntrabc then
  begin
    AFh.LoopFilterLevel[0] := 0; AFh.LoopFilterLevel[1] := 0;
    AFh.LoopFilterRefDeltas[0] := 1;  AFh.LoopFilterRefDeltas[1] := 0;
    AFh.LoopFilterRefDeltas[2] := 0;  AFh.LoopFilterRefDeltas[3] := 0;
    AFh.LoopFilterRefDeltas[4] := -1; AFh.LoopFilterRefDeltas[5] := 0;
    AFh.LoopFilterRefDeltas[6] := -1; AFh.LoopFilterRefDeltas[7] := -1;
    AFh.LoopFilterModeDeltas[0] := 0; AFh.LoopFilterModeDeltas[1] := 0;
    Exit;
  end;
  AFh.LoopFilterLevel[0] := B.f(6);
  AFh.LoopFilterLevel[1] := B.f(6);
  if ASeq.NumPlanes > 1 then
    if (AFh.LoopFilterLevel[0] <> 0) or (AFh.LoopFilterLevel[1] <> 0) then
    begin
      AFh.LoopFilterLevel[2] := B.f(6);
      AFh.LoopFilterLevel[3] := B.f(6);
    end;
  AFh.LoopFilterSharpness := B.f(3);
  AFh.LoopFilterDeltaEnabled := B.f(1) = 1;
  // defaults
  AFh.LoopFilterRefDeltas[0] := 1;  AFh.LoopFilterRefDeltas[1] := 0;
  AFh.LoopFilterRefDeltas[2] := 0;  AFh.LoopFilterRefDeltas[3] := 0;
  AFh.LoopFilterRefDeltas[4] := -1; AFh.LoopFilterRefDeltas[5] := 0;
  AFh.LoopFilterRefDeltas[6] := -1; AFh.LoopFilterRefDeltas[7] := -1;
  AFh.LoopFilterModeDeltas[0] := 0; AFh.LoopFilterModeDeltas[1] := 0;
  if AFh.LoopFilterDeltaEnabled then
    if B.f(1) = 1 then // loop_filter_delta_update
    begin
      for i := 0 to NUM_REF_FRAMES - 1 do
        if B.f(1) = 1 then AFh.LoopFilterRefDeltas[i] := B.su(6);
      for i := 0 to 1 do
        if B.f(1) = 1 then AFh.LoopFilterModeDeltas[i] := B.su(6);
    end;
end;

procedure ParseCdefParams(B: TAv1Bits; const ASeq: TAv1SequenceHeader;
  var AFh: TAv1FrameHeader);
var
  i, numStrengths: Integer;
begin
  if AFh.CodedLossless or AFh.AllowIntrabc or (not ASeq.EnableCdef) then
  begin
    AFh.CdefBits := 0;
    AFh.CdefYPriStrength[0] := 0; AFh.CdefYSecStrength[0] := 0;
    AFh.CdefUVPriStrength[0] := 0; AFh.CdefUVSecStrength[0] := 0;
    AFh.CdefDampingMinus3 := 0;
    Exit;
  end;
  AFh.CdefDampingMinus3 := B.f(2);
  AFh.CdefBits := B.f(2);
  numStrengths := 1 shl AFh.CdefBits;
  for i := 0 to numStrengths - 1 do
  begin
    AFh.CdefYPriStrength[i] := B.f(4);
    AFh.CdefYSecStrength[i] := B.f(2);
    if AFh.CdefYSecStrength[i] = 3 then Inc(AFh.CdefYSecStrength[i]);
    if ASeq.NumPlanes > 1 then
    begin
      AFh.CdefUVPriStrength[i] := B.f(4);
      AFh.CdefUVSecStrength[i] := B.f(2);
      if AFh.CdefUVSecStrength[i] = 3 then Inc(AFh.CdefUVSecStrength[i]);
    end;
  end;
end;

procedure ParseLrParams(B: TAv1Bits; const ASeq: TAv1SequenceHeader;
  var AFh: TAv1FrameHeader);
var
  i, lrType, lrUnitShift, lrUvShift: Integer;
  usesLr, usesChromaLr: Boolean;
  RemapLrType: array[0..3] of Integer;
begin
  RemapLrType[0] := RESTORE_NONE;
  RemapLrType[1] := RESTORE_SWITCHABLE;
  RemapLrType[2] := RESTORE_WIENER;
  RemapLrType[3] := RESTORE_SGRPROJ;
  if AFh.AllLossless or AFh.AllowIntrabc or (not ASeq.EnableRestoration) then
  begin
    AFh.FrameRestorationType[0] := RESTORE_NONE;
    AFh.FrameRestorationType[1] := RESTORE_NONE;
    AFh.FrameRestorationType[2] := RESTORE_NONE;
    AFh.UsesLr := False;
    Exit;
  end;
  usesLr := False; usesChromaLr := False;
  for i := 0 to ASeq.NumPlanes - 1 do
  begin
    lrType := B.f(2);
    AFh.FrameRestorationType[i] := RemapLrType[lrType];
    if AFh.FrameRestorationType[i] <> RESTORE_NONE then
    begin
      usesLr := True;
      if i > 0 then usesChromaLr := True;
    end;
  end;
  AFh.UsesLr := usesLr;
  if usesLr then
  begin
    if ASeq.Use128x128Superblock then
    begin
      lrUnitShift := B.f(1) + 1;
    end
    else
    begin
      lrUnitShift := B.f(1);
      if lrUnitShift = 1 then
        lrUnitShift := lrUnitShift + B.f(1);
    end;
    AFh.LoopRestorationSize[0] := 64 shl lrUnitShift; // RESTORATION_TILESIZE_MAX=256 -> 64<<shift
    if (ASeq.SubsamplingX = 1) and (ASeq.SubsamplingY = 1) and usesChromaLr then
      lrUvShift := B.f(1)
    else
      lrUvShift := 0;
    AFh.LoopRestorationSize[1] := AFh.LoopRestorationSize[0] shr lrUvShift;
    AFh.LoopRestorationSize[2] := AFh.LoopRestorationSize[0] shr lrUvShift;
  end;
end;

procedure ParseFrameHeader(const ASeq: TAv1SequenceHeader;
  AData: PByte; ASize: NativeInt; out AFh: TAv1FrameHeader;
  out AEndByte: NativeInt);
var
  B: TAv1Bits;
  idLen: Integer;
  i: Integer;
  allZero: Boolean;
begin
  FillChar(AFh, SizeOf(AFh), 0);
  B := TAv1Bits.Create(AData, ASize);
  try
    if ASeq.ReducedStillPicture then
    begin
      AFh.FrameType := KEY_FRAME;
      AFh.ShowFrame := True;
      AFh.PrimaryRefFrame := PRIMARY_REF_NONE;
      // show_existing_frame=0, error_resilient_mode=1 implied
      AFh.AllowScreenContentTools := ASeq.SeqForceScreenContentTools;
      if AFh.AllowScreenContentTools = 2 then AFh.AllowScreenContentTools := 1; // conservative
    end
    else
    begin
      if B.f(1) = 1 then // show_existing_frame
        raise EAv1.Create('show_existing_frame not supported for still image');
      AFh.FrameType := B.f(2);
      AFh.ShowFrame := B.f(1) = 1;
      if AFh.ShowFrame then
        AFh.ShowableFrame := AFh.FrameType <> KEY_FRAME
      else
        AFh.ShowableFrame := B.f(1) = 1;
      if (AFh.FrameType = SWITCH_FRAME) then
        AFh.ErrorResilientMode := True
      else if (AFh.FrameType = KEY_FRAME) and AFh.ShowFrame then
        AFh.ErrorResilientMode := True
      else
        AFh.ErrorResilientMode := B.f(1) = 1;
    end;

    AFh.DisableCdfUpdate := B.f(1) = 1;
    if ASeq.SeqForceScreenContentTools = 2 then
      AFh.AllowScreenContentTools := B.f(1)
    else
      AFh.AllowScreenContentTools := ASeq.SeqForceScreenContentTools;
    if AFh.AllowScreenContentTools <> 0 then
    begin
      if ASeq.SeqForceIntegerMv = 2 then
        AFh.ForceIntegerMv := B.f(1)
      else
        AFh.ForceIntegerMv := ASeq.SeqForceIntegerMv;
    end
    else
      AFh.ForceIntegerMv := 0;
    // KEY_FRAME is always intra -> force_integer_mv = 1 (unused here).

    if ASeq.FrameIdNumbersPresent then
    begin
      idLen := ASeq.AdditionalFrameIdLength + ASeq.DeltaFrameIdLength;
      B.f(idLen);  // current_frame_id
    end;

    if AFh.FrameType = SWITCH_FRAME then
      AFh.FrameSizeOverride := True
    else if ASeq.ReducedStillPicture then
      AFh.FrameSizeOverride := False
    else
      AFh.FrameSizeOverride := B.f(1) = 1;

    if ASeq.OrderHintBits > 0 then
      AFh.OrderHint := B.f(ASeq.OrderHintBits);

    AFh.PrimaryRefFrame := PRIMARY_REF_NONE; // key/intra frames

    // For a KEY_FRAME that is shown, refresh_frame_flags = allFrames but not read.
    // allow_intrabc appears in the intra path after frame size + render size.

    ParseFrameSize(B, ASeq, AFh);
    ParseRenderSize(B, AFh);
    if DebugFH then Writeln(ErrOutput, 'FH after size: bit=', B.BitPosition);

    if (AFh.AllowScreenContentTools <> 0) and (AFh.UpscaledWidth = AFh.FrameWidth) then
      AFh.AllowIntrabc := B.f(1) = 1;

    // (inter-only ref/mv syntax is skipped for intra key frames)
    // disable_frame_end_update_cdf
    if ASeq.ReducedStillPicture or AFh.DisableCdfUpdate then
      AFh.DisableFrameEndUpdateCdf := True
    else
      AFh.DisableFrameEndUpdateCdf := B.f(1) = 1;

    ParseTileInfo(B, ASeq, AFh);
    if DebugFH then Writeln(ErrOutput, 'FH after tile: bit=', B.BitPosition);
    ParseQuantizationParams(B, ASeq, AFh);
    if DebugFH then Writeln(ErrOutput, 'FH after quant: bit=', B.BitPosition);
    ParseSegmentationParams(B, AFh);
    if DebugFH then Writeln(ErrOutput, 'FH after seg: bit=', B.BitPosition);

    // delta_q_params
    if AFh.BaseQIdx > 0 then
      AFh.DeltaQPresent := B.f(1) = 1
    else
      AFh.DeltaQPresent := False;
    if AFh.DeltaQPresent then
      AFh.DeltaQRes := B.f(2);
    // delta_lf_params
    if AFh.DeltaQPresent then
    begin
      if not AFh.AllowIntrabc then
        AFh.DeltaLfPresent := B.f(1) = 1;
      if AFh.DeltaLfPresent then
      begin
        AFh.DeltaLfRes := B.f(2);
        AFh.DeltaLfMulti := B.f(1) = 1;
      end;
    end;

    // coded_lossless
    AFh.CodedLossless := True;
    for i := 0 to MAX_SEGMENTS - 1 do
    begin
      AFh.LosslessArray[i] := (GetQIndex(AFh, i) = 0) and (AFh.DeltaQYDc = 0) and
        (AFh.DeltaQUAc = 0) and (AFh.DeltaQUDc = 0) and
        (AFh.DeltaQVAc = 0) and (AFh.DeltaQVDc = 0);
      if not AFh.LosslessArray[i] then AFh.CodedLossless := False;
    end;
    AFh.AllLossless := AFh.CodedLossless and (AFh.FrameWidth = AFh.UpscaledWidth);

    if DebugFH then Writeln(ErrOutput, 'FH before lf: bit=', B.BitPosition);
    ParseLoopFilterParams(B, ASeq, AFh);
    if DebugFH then Writeln(ErrOutput, 'FH after lf: bit=', B.BitPosition);
    ParseCdefParams(B, ASeq, AFh);
    if DebugFH then Writeln(ErrOutput, 'FH after cdef: bit=', B.BitPosition);
    ParseLrParams(B, ASeq, AFh);
    if DebugFH then Writeln(ErrOutput, 'FH after lr: bit=', B.BitPosition);

    // read_tx_mode
    if AFh.CodedLossless then
      AFh.TxMode := ONLY_4X4
    else
      if B.f(1) = 1 then AFh.TxMode := TX_MODE_SELECT else AFh.TxMode := TX_MODE_LARGEST;

    // frame_reference_mode: intra -> reference_select = 0 (not read for KEY/INTRA)
    // skip_mode_params: skipModeAllowed=0 for intra -> skip_mode_present=0
    // KEY/INTRA: no global motion.

    // allow_warped_motion (only inter). reduced_tx_set:
    AFh.ReducedTxSet := B.f(1) = 1;
    // global_motion_params (intra: none) and film_grain (handled at output) end
    // the uncompressed header. Byte-align: the tile group follows in OBU_FRAME.
    if DebugFH then Writeln(ErrOutput, 'FH after txmode/reducedtx: bit=', B.BitPosition);
    B.ByteAlign;
    AEndByte := B.BytePos;
  finally
    B.Free;
  end;
end;

end.
