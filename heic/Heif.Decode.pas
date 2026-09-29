unit Heif.Decode;

// HEIF/HEIC image decoder.
//
// Ties the pure-Pascal HEIF container (Heif.Container) to the pure-Pascal HEVC
// decoder ported in the BPG project (h265_hevc et al.). The HEVC codec used by
// HEIC and by BPG is the same; only the container differs. This unit:
//
// 1. extracts the VPS/SPS/PPS parameter sets (from hvcC) and the coded slice
// NAL units (from the item's iloc extents),
// 2. assembles them into an Annex-B elementary stream (start-code prefixed),
// 3. runs the HEVC decoder to reconstruct the YCbCr planes,
// 4. applies the SPS conformance-window crop to the display size.
//
// The result planes are 8-bit (the common HEIC case).

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Math, Heif.Reader, Heif.Container, Heif.Hevc, Heif.H265.Params,
  h265_common, h265_bits, h265_hevc_defs, h265_hevc_ps, h265_frame, h265_hevc, Av1.Decoder;

type
  EHeifDecode = class(Exception);

  // One image-plane of native-bit-depth samples (8..16 bit), tightly packed.
  TSamplePlane = array of Word;

  THeifImage = record
    Width, Height: Integer;    // display size after conformance-window crop
    ChromaFormat: Integer;     // 0=mono,1=4:2:0,2=4:2:2,3=4:4:4
    BitDepth: Integer;         // 8, 10, 12
    // Planar YCbCr at native bit depth. For mono, U/V are empty.
    Y, U, V: TSamplePlane;
    ChromaWidth, ChromaHeight: Integer;
    // Colour signalling from the nclx 'colr' box (defaults: BT.601 limited).
    HasNclx: Boolean;
    ColorPrimaries: Integer;
    TransferCharacteristics: Integer;
    MatrixCoefficients: Integer;   // 1=BT.709, 5/6=BT.601, 9=BT.2020ncl
    FullRange: Boolean;
    Rotation: Integer;             // display rotation, degrees counter-clockwise (0/90/180/270)
    // Auxiliary alpha (from an auxC/auxl aux item), at the luma resolution.
    HasAlpha: Boolean;
    Alpha: TSamplePlane;
    AlphaBitDepth: Integer;
  end;

// Decodes the given item (must be an 'hvc1' image item) to YCbCr planes.
function DecodeHeifItem(C: THeifContainer; AItemID: LongWord;
  out AImg: THeifImage): Boolean;

// Convenience: decode the primary item.
function DecodeHeifPrimary(C: THeifContainer; out AImg: THeifImage): Boolean;

// Converts a decoded image to packed 8-bit RGB (top-down, R,G,B), applying the
// image's colour matrix/range (bilinear chroma upsampling) and display rotation.
// AOutW/AOutH receive the output dimensions (swapped for 90/270 rotation).
procedure HeifImageToRGB(const AImg: THeifImage; out ARGB: TBytes;
  out AOutW, AOutH: Integer);

// As HeifImageToRGB but packs 8-bit RGBA, filling the alpha channel from the
// image's auxiliary alpha plane (255 opaque where absent).
procedure HeifImageToRGBA(const AImg: THeifImage; out ARGBA: TBytes;
  out AOutW, AOutH: Integer);

implementation

// Parses an nclx 'colr' property into the image's colour fields. Leaves the
// BT.601-limited defaults in place for any other colour type (e.g. ICC 'prof').
procedure ParseColr(AProp: THeifProperty; var AImg: THeifImage);
var
  R: TByteReader;
  ColorType: string;
  B: Byte;
begin
  if (AProp = nil) or (Length(AProp.Data) < 4) then Exit;
  R := AProp.AsReader;
  try
    ColorType := R.ReadFourCC;
    if (ColorType = 'nclx') and (R.Remaining >= 7) then
    begin
      AImg.ColorPrimaries := R.ReadU16;
      AImg.TransferCharacteristics := R.ReadU16;
      AImg.MatrixCoefficients := R.ReadU16;
      B := R.ReadU8;
      AImg.FullRange := (B and $80) <> 0;
      AImg.HasNclx := True;
    end;
  finally
    R.Free;
  end;
end;

const
  START_CODE_LEN = 4;

// Appends 00 00 00 01 + NAL bytes to ABuf at AOfs; returns new offset.
function AppendNal(var ABuf: TBytes; AOfs: Integer; const ANal: TBytes): Integer;
var
  L: Integer;
begin
  L := Length(ANal);
  ABuf[AOfs] := 0; ABuf[AOfs+1] := 0; ABuf[AOfs+2] := 0; ABuf[AOfs+3] := 1;
  Inc(AOfs, START_CODE_LEN);
  if L > 0 then
    Move(ANal[0], ABuf[AOfs], L);
  Result := AOfs + L;
end;

function TotalNalSize(const ANals: TNalUnitArray): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(ANals) do
    Inc(Result, START_CODE_LEN + Length(ANals[I].Data));
end;

// Builds BPG's compact "modified SPS" NAL (nal_unit_type = 48) from a fully
// parsed standard SPS. The bit layout mirrors h265_hevc_ps.ff_hevc_decode_nal_sps
// exactly. The decoder installs it as SPS id 0 (the id is not carried), so the
// stream's PPS must reference sps_id 0 (the HEIC norm).
function BuildModifiedSps(const ASps: TSps): TBytes;
var
  W: TBitWriter;
  Raw: TBytes;
begin
  W := TBitWriter.Create;
  try
    // 2-byte NAL header: forbidden(0) type(48) layerid(0) tid_plus1(1).
    W.WriteBit(0);
    W.WriteBits(48, 6);
    W.WriteBits(0, 6);
    W.WriteBits(1, 3);
    // payload
    W.WriteBits(LongWord(ASps.ChromaFormatIdc), 8);
    W.WriteBits(LongWord(ASps.PicWidthInLumaSamples), 32);
    W.WriteBits(LongWord(ASps.PicHeightInLumaSamples), 32);
    W.WriteBits(LongWord(ASps.BitDepthLuma - 8), 8);
    W.WriteUE(LongWord(ASps.Log2MinLumaCbSize - 3));
    W.WriteUE(LongWord(ASps.Log2CtbSize - ASps.Log2MinLumaCbSize));
    W.WriteUE(LongWord(ASps.Log2MinTransformBlockSize - 2));
    W.WriteUE(LongWord(ASps.Log2MaxTransformBlockSize - ASps.Log2MinTransformBlockSize));
    W.WriteUE(LongWord(ASps.MaxTransformHierarchyDepthIntra));
    W.WriteBit(Ord(ASps.SaoEnabled));
    W.WriteBit(Ord(ASps.PcmEnabled));
    if ASps.PcmEnabled then
    begin
      W.WriteBits(LongWord(ASps.PcmBitDepthLuma - 1), 4);
      W.WriteBits(LongWord(ASps.PcmBitDepthChroma - 1), 4);
      W.WriteUE(LongWord(ASps.Log2MinPcmCbSize - 3));
      W.WriteUE(LongWord(ASps.Log2MaxPcmCbSize - ASps.Log2MinPcmCbSize));
      W.WriteBit(Ord(ASps.PcmLoopFilterDisabled));
    end;
    W.WriteBit(Ord(ASps.StrongIntraSmoothing));
    W.WriteBit(0); // sps_extension present flag (no range extensions)
    // rbsp_stop_one_bit: mandatory. Without it the final byte can be all zeros
    // and merge with the following start code, truncating the RBSP.
    W.WriteBit(1);
    Raw := W.ToBytes;
  finally
    W.Free;
  end;
  Result := AddEmulationPrevention(Raw);
end;

function BuildAnnexB(const AMsps: TBytes; const APps: TNalUnitArray;
  const ASliceNals: TNalUnitArray): TBytes;
var
  Total, Ofs, I: Integer;
begin
  Total := START_CODE_LEN + Length(AMsps) +
           TotalNalSize(APps) + TotalNalSize(ASliceNals);
  // Extra padding the decoder's bitreader relies on.
  SetLength(Result, Total + FF_INPUT_BUFFER_PADDING_SIZE);
  Ofs := 0;
  Ofs := AppendNal(Result, Ofs, AMsps);
  for I := 0 to High(APps) do Ofs := AppendNal(Result, Ofs, APps[I].Data);
  for I := 0 to High(ASliceNals) do Ofs := AppendNal(Result, Ofs, ASliceNals[I].Data);
  // The padding tail is already zero (SetLength zero-fills new memory).
end;

// Copies a native-bit-depth plane out of the decoder's 16-bit-sample plane,
// cropping to [X0..X0+W) x [Y0..Y0+H) and masking to the coded bit depth.
procedure CopyPlane(ASrc: PByte; ALinesize: Integer; AX0, AY0, AW, AH: Integer;
  ABitDepth: Integer; out ADest: TSamplePlane);
var
  X, Y: Integer;
  SrcRow: PWord;
  DstOfs: Integer;
  Mask: Word;
begin
  Mask := Word((1 shl ABitDepth) - 1);
  SetLength(ADest, AW * AH);
  DstOfs := 0;
  for Y := 0 to AH - 1 do
  begin
    SrcRow := PWord(ASrc + (AY0 + Y) * ALinesize);
    for X := 0 to AW - 1 do
    begin
      ADest[DstOfs] := SrcRow[AX0 + X] and Mask;
      Inc(DstOfs);
    end;
  end;
end;

// The compact SPS the decoder is fed has no room for scaling lists, so when the
// real SPS enables them they are set up here (the defaults, or the SPS's own
// scaling_list_data() parsed by the decoder's routine) and the decoder picks
// them up with the SPS. Without this, streams using them -- iPhone photos use
// the defaults -- decode slightly wrong.
procedure InstallScalingLists(Ctx: PHEVCContext; const ASpsNal: TBytes;
  const ASps: TSps);
var
  Rbsp: TBytes;
  TmpSps: PHEVCSPS;
begin
  set_default_scaling_list_data(@Ctx^.ext_sps_scaling_list);
  if ASps.ScalingListDataPresent then
  begin
    Rbsp := RemoveEmulationPrevention(ASpsNal);
    SetLength(Rbsp, Length(Rbsp) + FF_INPUT_BUFFER_PADDING_SIZE);
    init_get_bits(Ctx^.HEVClc^.gb, @Rbsp[0],
      (Length(Rbsp) - FF_INPUT_BUFFER_PADDING_SIZE) * 8);
    skip_bits(Ctx^.HEVClc^.gb, ASps.ScalingListBitPos);
    TmpSps := av_mallocz(SizeOf(THEVCSPS));   // only chroma_format_idc is read
    if TmpSps = nil then
      raise EHeifDecode.Create('Out of memory (SPS)');
    try
      TmpSps^.chroma_format_idc := ASps.ChromaFormatIdc;
      if scaling_list_data(Ctx, @Ctx^.ext_sps_scaling_list, TmpSps) < 0 then
        raise EHeifDecode.Create('Invalid SPS scaling list data');
    finally
      av_free(TmpSps);
    end;
  end;
  Ctx^.ext_sps_scaling := 1;
end;

// Decodes a single 'hvc1' image item to YCbCr.
function DecodeHvcItem(C: THeifContainer; Item: THeifItem;
  out AImg: THeifImage): Boolean;
var
  Prop: THeifProperty;
  Config: THevcConfig;
  Sps: TSps;
  Msps, ItemData, AnnexB: TBytes;
  SliceNals: TNalUnitArray;
  Ctx: PHEVCContext;
  Frame: PAVFrame;
  GotFrame: Integer;
  Ret: Integer;
  SubW, SubH: Integer;
  LumaX0, LumaY0, ChromaX0, ChromaY0: Integer;
begin
  Result := False;
  FillChar(AImg, SizeOf(AImg), 0);

  if Item.ItemType <> 'hvc1' then
    raise EHeifDecode.CreateFmt('Item %d is not HEVC (type=%s)', [Item.ID, Item.ItemType]);

  Prop := Item.FindProperty('hvcC');
  if Prop = nil then
    raise EHeifDecode.Create('Item has no hvcC configuration');

  ParseHvcC(Prop.Data, Config);
  if Length(Config.Sps) = 0 then
    raise EHeifDecode.Create('No SPS in hvcC');
  ParseSps(Config.Sps[0].Data, Sps);
  Msps := BuildModifiedSps(Sps);

  ItemData := C.GetItemData(Item.ID);
  SliceNals := SplitNalUnits(ItemData, Config.LengthSize);
  if Length(SliceNals) = 0 then
    raise EHeifDecode.Create('No coded slice data');

  AnnexB := BuildAnnexB(Msps, Config.Pps, SliceNals);

  Ctx := av_mallocz(SizeOf(THEVCContext));
  if Ctx = nil then
    raise EHeifDecode.Create('Out of memory (context)');
  Frame := nil;
  try
    if hevc_init_context(Ctx) < 0 then
      raise EHeifDecode.Create('hevc_init_context failed');
    if Sps.ScalingListEnabled then
      InstallScalingLists(Ctx, Config.Sps[0].Data, Sps);
    Frame := av_frame_alloc;
    if Frame = nil then
      raise EHeifDecode.Create('av_frame_alloc failed');

    GotFrame := 0;
    Ret := hevc_decode_frame(Ctx, Frame, GotFrame, @AnnexB[0],
      Length(AnnexB) - FF_INPUT_BUFFER_PADDING_SIZE);
    if (Ret < 0) or (GotFrame = 0) then
    begin
      if GetEnvironmentVariable('HEIF_DUMP') <> '' then
        with TFileStream.Create(GetEnvironmentVariable('HEIF_DUMP'), fmCreate) do
          try WriteBuffer(AnnexB[0], Length(AnnexB) - FF_INPUT_BUFFER_PADDING_SIZE);
          finally Free; end;
      raise EHeifDecode.CreateFmt('HEVC decode failed (ret=%d got=%d)', [Ret, GotFrame]);
    end;

    // Fill output metadata (conformance-window crop applied to display size).
    if Sps.ChromaFormatIdc = 1 then begin SubW := 2; SubH := 2; end
    else if Sps.ChromaFormatIdc = 2 then begin SubW := 2; SubH := 1; end
    else begin SubW := 1; SubH := 1; end;

    AImg.Width := Sps.PicWidthInLumaSamples - SubW * (Sps.ConfWinLeft + Sps.ConfWinRight);
    AImg.Height := Sps.PicHeightInLumaSamples - SubH * (Sps.ConfWinTop + Sps.ConfWinBottom);
    AImg.ChromaFormat := Sps.ChromaFormatIdc;
    AImg.BitDepth := Sps.BitDepthLuma;

    LumaX0 := SubW * Sps.ConfWinLeft;
    LumaY0 := SubH * Sps.ConfWinTop;
    ChromaX0 := Sps.ConfWinLeft;
    ChromaY0 := Sps.ConfWinTop;

    // Colour signalling precedence: nclx box > HEVC VUI > BT.601 default.
    AImg.MatrixCoefficients := 6;   // BT.601
    AImg.ColorPrimaries := 6;
    AImg.TransferCharacteristics := 6;
    AImg.FullRange := False;
    if Sps.VuiColourPresent then
    begin
      AImg.MatrixCoefficients := Sps.VuiMatrix;
      AImg.ColorPrimaries := Sps.VuiPrimaries;
      AImg.TransferCharacteristics := Sps.VuiTransfer;
      AImg.FullRange := Sps.VuiFullRange;
    end;
    ParseColr(Item.FindProperty('colr'), AImg);

    CopyPlane(Frame^.Data[0], Frame^.Linesize[0], LumaX0, LumaY0,
      AImg.Width, AImg.Height, Sps.BitDepthLuma, AImg.Y);

    if Sps.ChromaFormatIdc <> 0 then
    begin
      AImg.ChromaWidth := (AImg.Width + SubW - 1) div SubW;
      AImg.ChromaHeight := (AImg.Height + SubH - 1) div SubH;
      CopyPlane(Frame^.Data[1], Frame^.Linesize[1], ChromaX0, ChromaY0,
        AImg.ChromaWidth, AImg.ChromaHeight, Sps.BitDepthChroma, AImg.U);
      CopyPlane(Frame^.Data[2], Frame^.Linesize[2], ChromaX0, ChromaY0,
        AImg.ChromaWidth, AImg.ChromaHeight, Sps.BitDepthChroma, AImg.V);
    end;

    Result := True;
  finally
    if Frame <> nil then
      av_frame_free(Frame);
    hevc_decode_free(Ctx);
    av_free(Ctx);
  end;
end;

// Decodes a single 'av01' (AVIF) image item to YCbCr via the pure-Pascal AV1
// decoder. The AV1 sequence header lives in the av1C property's configOBUs;
// the coded frame OBUs are the item data. Concatenating them gives one OBU
// stream. 8-bit only.
function DecodeAv1Item(C: THeifContainer; Item: THeifItem;
  out AImg: THeifImage): Boolean;
var
  Prop: THeifProperty;
  ConfigOBUs, ItemData, Stream: TBytes;
  F: TAv1Frame;
  I, cn: Integer;
begin
  Result := False;
  FillChar(AImg, SizeOf(AImg), 0);
  if Item.ItemType <> 'av01' then
    raise EHeifDecode.CreateFmt('Item %d is not AV1 (type=%s)', [Item.ID, Item.ItemType]);

  Prop := Item.FindProperty('av1C');
  if (Prop = nil) or (Length(Prop.Data) < 4) then
    raise EHeifDecode.Create('Item has no av1C configuration');
  // av1C: 4 fixed bytes (marker/version, profile/level, tier/depth/chroma,
  // reserved/delay) then configOBUs.
  SetLength(ConfigOBUs, Length(Prop.Data) - 4);
  if Length(ConfigOBUs) > 0 then Move(Prop.Data[4], ConfigOBUs[0], Length(ConfigOBUs));

  ItemData := C.GetItemData(Item.ID);
  SetLength(Stream, Length(ConfigOBUs) + Length(ItemData));
  if Length(ConfigOBUs) > 0 then Move(ConfigOBUs[0], Stream[0], Length(ConfigOBUs));
  if Length(ItemData) > 0 then Move(ItemData[0], Stream[Length(ConfigOBUs)], Length(ItemData));

  if not Av1Decode(@Stream[0], Length(Stream), F) then
    raise EHeifDecode.Create('AV1 decode failed');

  AImg.Width := F.Width;
  AImg.Height := F.Height;
  AImg.BitDepth := F.BitDepth;
  if F.NumPlanes = 1 then AImg.ChromaFormat := 0
  else if (F.SsH = 1) and (F.SsV = 1) then AImg.ChromaFormat := 1
  else if (F.SsH = 1) and (F.SsV = 0) then AImg.ChromaFormat := 2
  else AImg.ChromaFormat := 3;

  // Colour signalling: nclx 'colr' box, else AVIF default BT.601 limited.
  AImg.MatrixCoefficients := 6;
  AImg.ColorPrimaries := 6;
  AImg.TransferCharacteristics := 6;
  AImg.FullRange := False;
  ParseColr(Item.FindProperty('colr'), AImg);

  SetLength(AImg.Y, F.Width * F.Height);
  for I := 0 to F.Width*F.Height - 1 do AImg.Y[I] := F.Y[I];
  if F.NumPlanes = 3 then
  begin
    AImg.ChromaWidth := F.ChromaW;
    AImg.ChromaHeight := F.ChromaH;
    cn := F.ChromaW * F.ChromaH;
    SetLength(AImg.U, cn); SetLength(AImg.V, cn);
    for I := 0 to cn-1 do begin AImg.U[I] := F.U[I]; AImg.V[I] := F.V[I]; end;
  end;
  Result := True;
end;

// Fills a plane region [0..W)x[0..H) with a constant value.
procedure FillPlane(var P: TSamplePlane; W, H: Integer; V: Word);
var
  I: Integer;
begin
  SetLength(P, W * H);
  for I := 0 to High(P) do P[I] := V;
end;

function FindItemByID(C: THeifContainer; AID: LongWord): THeifItem;
var
  K: Integer;
begin
  for K := 0 to C.Items.Count - 1 do
    if C.Items[K].ID = AID then
      Exit(C.Items[K]);
  Result := nil;
end;

// Reads the 'irot' property (rotation in 90-degree CCW steps) into AImg.
procedure ApplyIrot(Item: THeifItem; var AImg: THeifImage);
var
  Prop: THeifProperty;
begin
  Prop := Item.FindProperty('irot');
  if (Prop <> nil) and (Length(Prop.Data) >= 1) then
    AImg.Rotation := (Prop.Data[0] and 3) * 90;
end;

// Copies one tile's plane into a destination canvas plane at (ADX,ADY).
procedure PlaceTile(const ASrc: TSamplePlane; ASrcW, ASrcH: Integer;
  var ADst: TSamplePlane; ADstW, ADstH, ADX, ADY: Integer);
var
  X, Y, DY: Integer;
begin
  for Y := 0 to ASrcH - 1 do
  begin
    DY := ADY + Y;
    if (DY < 0) or (DY >= ADstH) then Continue;
    for X := 0 to ASrcW - 1 do
      if (ADX + X >= 0) and (ADX + X < ADstW) then
        ADst[DY * ADstW + ADX + X] := ASrc[Y * ASrcW + X];
  end;
end;

procedure CropImage(var AImg: THeifImage; W, H: Integer); forward;

// Decodes a 'grid' derived item: assembles its dimg tiles into the full image.
function DecodeHeifGrid(C: THeifContainer; Item: THeifItem;
  out AImg: THeifImage): Boolean;
var
  GridData: TBytes;
  R: TByteReader;
  Flags, Rows, Cols: Integer;
  OutW, OutH: Integer;
  Tiles: TArray<LongWord>;
  Tile: THeifImage;
  TileW, TileH, TileCW, TileCH: Integer;
  CanvasW, CanvasH, CanvasCW, CanvasCH: Integer;
  I, Row, Col: Integer;
  TileItem: THeifItem;
begin
  Result := False;
  FillChar(AImg, SizeOf(AImg), 0);

  GridData := C.GetItemData(Item.ID);
  if Length(GridData) < 8 then
    raise EHeifDecode.Create('Grid item data too short');
  R := TByteReader.CreateOwned(GridData);
  try
    R.ReadU8;                 // version
    Flags := R.ReadU8;
    Rows := R.ReadU8 + 1;
    Cols := R.ReadU8 + 1;
    if (Flags and 1) = 1 then
    begin
      OutW := R.ReadU32; OutH := R.ReadU32;
    end
    else
    begin
      OutW := R.ReadU16; OutH := R.ReadU16;
    end;
  finally
    R.Free;
  end;

  Tiles := C.GetReferences(Item.ID, 'dimg');
  if Length(Tiles) < Rows * Cols then
    raise EHeifDecode.CreateFmt('Grid needs %d tiles but has %d', [Rows * Cols, Length(Tiles)]);

  // Decode the first tile to learn tile geometry and format.
  TileItem := FindItemByID(C, Tiles[0]);
  if (TileItem = nil) or (not DecodeHvcItem(C, TileItem, Tile)) then
    raise EHeifDecode.Create('Failed to decode first grid tile');
  TileW := Tile.Width; TileH := Tile.Height;
  TileCW := Tile.ChromaWidth; TileCH := Tile.ChromaHeight;

  CanvasW := Cols * TileW;  CanvasH := Rows * TileH;
  AImg.Width := CanvasW;    AImg.Height := CanvasH;
  AImg.ChromaFormat := Tile.ChromaFormat;
  AImg.BitDepth := Tile.BitDepth;
  AImg.MatrixCoefficients := Tile.MatrixCoefficients;
  AImg.ColorPrimaries := Tile.ColorPrimaries;
  AImg.TransferCharacteristics := Tile.TransferCharacteristics;
  AImg.FullRange := Tile.FullRange;
  AImg.HasNclx := Tile.HasNclx;

  SetLength(AImg.Y, CanvasW * CanvasH);
  if AImg.ChromaFormat <> 0 then
  begin
    CanvasCW := Cols * TileCW;  CanvasCH := Rows * TileCH;
    AImg.ChromaWidth := CanvasCW;  AImg.ChromaHeight := CanvasCH;
    SetLength(AImg.U, CanvasCW * CanvasCH);
    SetLength(AImg.V, CanvasCW * CanvasCH);
  end;

  for I := 0 to Rows * Cols - 1 do
  begin
    Row := I div Cols;  Col := I mod Cols;
    if I > 0 then // tile 0 already decoded
    begin
      TileItem := FindItemByID(C, Tiles[I]);
      if (TileItem = nil) or (not DecodeHvcItem(C, TileItem, Tile)) then
        raise EHeifDecode.CreateFmt('Failed to decode grid tile %d', [I]);
    end;
    PlaceTile(Tile.Y, Tile.Width, Tile.Height, AImg.Y, CanvasW, CanvasH,
      Col * TileW, Row * TileH);
    if AImg.ChromaFormat <> 0 then
    begin
      PlaceTile(Tile.U, Tile.ChromaWidth, Tile.ChromaHeight, AImg.U,
        AImg.ChromaWidth, AImg.ChromaHeight, Col * TileCW, Row * TileCH);
      PlaceTile(Tile.V, Tile.ChromaWidth, Tile.ChromaHeight, AImg.V,
        AImg.ChromaWidth, AImg.ChromaHeight, Col * TileCW, Row * TileCH);
    end;
  end;

  // Crop the canvas to the grid's output dimensions.
  if (OutW < CanvasW) or (OutH < CanvasH) then
    CropImage(AImg, OutW, OutH);

  ApplyIrot(Item, AImg);
  Result := True;
end;

// Crops an image in place to WxH (top-left), reallocating planes.
procedure CropImage(var AImg: THeifImage; W, H: Integer);
var
  NewY, NewU, NewV: TSamplePlane;
  SubW, SubH, CW, CH, Y: Integer;
begin
  SetLength(NewY, W * H);
  for Y := 0 to H - 1 do
    Move(AImg.Y[Y * AImg.Width], NewY[Y * W], W * SizeOf(Word));
  if AImg.ChromaFormat = 1 then begin SubW := 2; SubH := 2; end
  else if AImg.ChromaFormat = 2 then begin SubW := 2; SubH := 1; end
  else begin SubW := 1; SubH := 1; end;
  if AImg.ChromaFormat <> 0 then
  begin
    CW := (W + SubW - 1) div SubW;  CH := (H + SubH - 1) div SubH;
    SetLength(NewU, CW * CH);  SetLength(NewV, CW * CH);
    for Y := 0 to CH - 1 do
    begin
      Move(AImg.U[Y * AImg.ChromaWidth], NewU[Y * CW], CW * SizeOf(Word));
      Move(AImg.V[Y * AImg.ChromaWidth], NewV[Y * CW], CW * SizeOf(Word));
    end;
    AImg.ChromaWidth := CW;  AImg.ChromaHeight := CH;
    AImg.U := NewU;  AImg.V := NewV;
  end;
  AImg.Width := W;  AImg.Height := H;
  AImg.Y := NewY;
end;

function DecodeHeifOverlay(C: THeifContainer; Item: THeifItem;
  out AImg: THeifImage): Boolean; forward;

// Reads the item's 'ispe' (image spatial extent) display size, if present.
// ispe is a FullBox: version+flags (4 bytes), then image_width, image_height
// as big-endian u32. Returns False when there is no usable ispe.
function ReadIspe(Item: THeifItem; out W, H: Integer): Boolean;
var P: THeifProperty;
begin
  Result := False;
  P := Item.FindProperty('ispe');
  if (P = nil) or (Length(P.Data) < 12) then Exit;
  W := (P.Data[4] shl 24) or (P.Data[5] shl 16) or (P.Data[6] shl 8) or P.Data[7];
  H := (P.Data[8] shl 24) or (P.Data[9] shl 16) or (P.Data[10] shl 8) or P.Data[11];
  Result := (W > 0) and (H > 0);
end;

// Crops the decoded planes to the rectangle (X0,Y0,W,H) in luma samples.
procedure CropImageRect(var AImg: THeifImage; X0, Y0, W, H: Integer);
var
  NewY, NewU, NewV: TSamplePlane;
  SubW, SubH, CW, CH, CX0, CY0, Y: Integer;
begin
  if X0 < 0 then X0 := 0;
  if Y0 < 0 then Y0 := 0;
  if X0 + W > AImg.Width  then W := AImg.Width  - X0;
  if Y0 + H > AImg.Height then H := AImg.Height - Y0;
  if (W <= 0) or (H <= 0) then Exit;

  SetLength(NewY, W * H);
  for Y := 0 to H - 1 do
    Move(AImg.Y[(Y + Y0) * AImg.Width + X0], NewY[Y * W], W * SizeOf(Word));

  if AImg.ChromaFormat = 1 then begin SubW := 2; SubH := 2; end
  else if AImg.ChromaFormat = 2 then begin SubW := 2; SubH := 1; end
  else begin SubW := 1; SubH := 1; end;
  if AImg.ChromaFormat <> 0 then
  begin
    CX0 := X0 div SubW;  CY0 := Y0 div SubH;
    CW := (W + SubW - 1) div SubW;  CH := (H + SubH - 1) div SubH;
    SetLength(NewU, CW * CH);  SetLength(NewV, CW * CH);
    for Y := 0 to CH - 1 do
    begin
      Move(AImg.U[(Y + CY0) * AImg.ChromaWidth + CX0], NewU[Y * CW], CW * SizeOf(Word));
      Move(AImg.V[(Y + CY0) * AImg.ChromaWidth + CX0], NewV[Y * CW], CW * SizeOf(Word));
    end;
    AImg.ChromaWidth := CW;  AImg.ChromaHeight := CH;
    AImg.U := NewU;  AImg.V := NewV;
  end;
  AImg.Width := W;  AImg.Height := H;
  AImg.Y := NewY;
end;

// Reads a 'clap' (clean aperture) box and computes the crop rectangle in luma
// samples. clap is a plain Box of eight big-endian u32: cleanW N/D, cleanH N/D,
// horizOff N/D, vertOff N/D. The aperture is centred on the image, offset by
// (horizOff,vertOff), per ISO/IEC 14496-12. Returns False when absent/unusable.
function ReadClap(Item: THeifItem; ImgW, ImgH: Integer;
  out X0, Y0, W, H: Integer): Boolean;
var
  P: THeifProperty;
  function U32(Ofs: Integer): Int64;
  begin
    Result := (Int64(P.Data[Ofs]) shl 24) or (P.Data[Ofs+1] shl 16)
              or (P.Data[Ofs+2] shl 8) or P.Data[Ofs+3];
  end;
  function S32(Ofs: Integer): Int64;
  begin
    Result := U32(Ofs);
    if Result >= (Int64(1) shl 31) then Result := Result - (Int64(1) shl 32);
  end;
var
  cwN, cwD, chN, chD, hoD, voD: Int64;
  pcX, pcY, leftF, topF: Double;
begin
  Result := False;
  P := Item.FindProperty('clap');
  if (P = nil) or (Length(P.Data) < 32) then Exit;
  cwN := U32(0);  cwD := U32(4);
  chN := U32(8);  chD := U32(12);
  hoD := U32(20); voD := U32(28);
  if (cwD = 0) or (chD = 0) or (hoD = 0) or (voD = 0) then Exit;

  W := cwN div cwD;  H := chN div chD;
  pcX := S32(16) / hoD;  pcY := S32(24) / voD;
  // left = (imgW-1)/2 + horizOff - (cleanW-1)/2  (same for top)
  leftF := (ImgW - 1) / 2 + pcX - (W - 1) / 2;
  topF  := (ImgH - 1) / 2 + pcY - (H - 1) / 2;
  X0 := Round(leftF);  Y0 := Round(topF);
  Result := (W > 0) and (H > 0);
end;

// Applies the container's display crop after decoding. A 'clap' (clean aperture)
// box is authoritative and marked essential; otherwise fall back to cropping the
// coded picture down to the 'ispe' display size when the coding padded it larger.
procedure ApplyDisplayCrop(Item: THeifItem; var AImg: THeifImage);
var X0, Y0, W, H: Integer;
begin
  if ReadClap(Item, AImg.Width, AImg.Height, X0, Y0, W, H) then
  begin
    if (X0 <> 0) or (Y0 <> 0) or (W < AImg.Width) or (H < AImg.Height) then
      CropImageRect(AImg, X0, Y0, W, H);
  end
  else if ReadIspe(Item, W, H) then
    if (W < AImg.Width) or (H < AImg.Height) then
      CropImage(AImg, W, H);
end;

// Decodes a master item (grid, overlay, or single hvc1) without aux channels.
function DecodeMaster(C: THeifContainer; Item: THeifItem;
  out AImg: THeifImage): Boolean;
begin
  if Item.ItemType = 'grid' then
    Result := DecodeHeifGrid(C, Item, AImg)
  else if Item.ItemType = 'iovl' then
    Result := DecodeHeifOverlay(C, Item, AImg)
  else if Item.ItemType = 'av01' then
  begin
    Result := DecodeAv1Item(C, Item, AImg);
    if Result then ApplyDisplayCrop(Item, AImg);
  end
  else
  begin
    Result := DecodeHvcItem(C, Item, AImg);
    if Result then ApplyDisplayCrop(Item, AImg);
  end;
end;

// Decodes an 'iovl' image overlay: paints its dimg images onto a canvas.
function DecodeHeifOverlay(C: THeifContainer; Item: THeifItem;
  out AImg: THeifImage): Boolean;
var
  Data: TBytes;
  R: TByteReader;
  Flags, FieldLen: Integer;
  FillR, FillG, FillB: Integer;
  OutW, OutH: Integer;
  Tiles: TArray<LongWord>;
  HOfs, VOfs: array of Integer;
  I, SubW, SubH: Integer;
  Sub: THeifImage;
  FillY, FillU, FillV: Integer;
  TileItem: THeifItem;
begin
  Result := False;
  FillChar(AImg, SizeOf(AImg), 0);
  Data := C.GetItemData(Item.ID);
  Tiles := C.GetReferences(Item.ID, 'dimg');
  if Length(Tiles) = 0 then
    raise EHeifDecode.Create('Overlay has no images');
  SetLength(HOfs, Length(Tiles));
  SetLength(VOfs, Length(Tiles));

  R := TByteReader.CreateOwned(Data);
  try
    R.ReadU8;                       // version
    Flags := R.ReadU8;
    FillR := R.ReadU16;             // canvas_fill_value R,G,B,A (u16 each)
    FillG := R.ReadU16;
    FillB := R.ReadU16;
    R.ReadU16;                      // A (ignored)
    if (Flags and 1) = 1 then FieldLen := 4 else FieldLen := 2;
    OutW := R.ReadUInt(FieldLen);
    OutH := R.ReadUInt(FieldLen);
    for I := 0 to High(Tiles) do
    begin
      HOfs[I] := LongInt(R.ReadUInt(FieldLen));
      VOfs[I] := LongInt(R.ReadUInt(FieldLen));
    end;
  finally
    R.Free;
  end;

  // Decode the first image to learn the format.
  TileItem := FindItemByID(C, Tiles[0]);
  if (TileItem = nil) or (not DecodeHvcItem(C, TileItem, Sub)) then
    raise EHeifDecode.Create('Failed to decode first overlay image');

  AImg.Width := OutW; AImg.Height := OutH;
  AImg.ChromaFormat := Sub.ChromaFormat;
  AImg.BitDepth := Sub.BitDepth;
  AImg.MatrixCoefficients := Sub.MatrixCoefficients;
  AImg.ColorPrimaries := Sub.ColorPrimaries;
  AImg.TransferCharacteristics := Sub.TransferCharacteristics;
  AImg.FullRange := Sub.FullRange;

  if AImg.ChromaFormat = 1 then begin SubW := 2; SubH := 2; end
  else if AImg.ChromaFormat = 2 then begin SubW := 2; SubH := 1; end
  else begin SubW := 1; SubH := 1; end;

  // Canvas background from the fill colour (BT.601), at the image bit depth.
  FillY := (66 * FillR + 129 * FillG + 25 * FillB + 128) div 256 + 16;
  FillU := (-38 * FillR - 74 * FillG + 112 * FillB + 128) div 256 + 128;
  FillV := (112 * FillR - 94 * FillG - 18 * FillB + 128) div 256 + 128;
  FillPlane(AImg.Y, OutW, OutH, Word(FillY shl (AImg.BitDepth - 8)));
  if AImg.ChromaFormat <> 0 then
  begin
    AImg.ChromaWidth := (OutW + SubW - 1) div SubW;
    AImg.ChromaHeight := (OutH + SubH - 1) div SubH;
    FillPlane(AImg.U, AImg.ChromaWidth, AImg.ChromaHeight, Word(FillU shl (AImg.BitDepth - 8)));
    FillPlane(AImg.V, AImg.ChromaWidth, AImg.ChromaHeight, Word(FillV shl (AImg.BitDepth - 8)));
  end;

  for I := 0 to High(Tiles) do
  begin
    if I > 0 then
    begin
      TileItem := FindItemByID(C, Tiles[I]);
      if (TileItem = nil) or (not DecodeHvcItem(C, TileItem, Sub)) then
        Continue;
    end;
    PlaceTile(Sub.Y, Sub.Width, Sub.Height, AImg.Y, OutW, OutH, HOfs[I], VOfs[I]);
    if AImg.ChromaFormat <> 0 then
    begin
      PlaceTile(Sub.U, Sub.ChromaWidth, Sub.ChromaHeight, AImg.U,
        AImg.ChromaWidth, AImg.ChromaHeight, HOfs[I] div SubW, VOfs[I] div SubH);
      PlaceTile(Sub.V, Sub.ChromaWidth, Sub.ChromaHeight, AImg.V,
        AImg.ChromaWidth, AImg.ChromaHeight, HOfs[I] div SubW, VOfs[I] div SubH);
    end;
  end;

  ApplyIrot(Item, AImg);
  Result := True;
end;

// True if an auxC property marks its item as an alpha plane.
function IsAlphaAux(Item: THeifItem): Boolean;
var
  Prop: THeifProperty;
  R: TByteReader;
  URN: string;
begin
  Result := False;
  Prop := Item.FindProperty('auxC');
  if Prop = nil then Exit;
  R := Prop.AsReader;
  try
    R.Skip(4);               // version + flags
    URN := R.ReadCString;    // aux_type
    Result := (Pos('auxid:1', URN) > 0) or (Pos('alpha', LowerCase(URN)) > 0)
              or (Pos('Alpha', URN) > 0);
  finally
    R.Free;
  end;
end;

// Finds the alpha auxiliary item that references AMasterID via 'auxl'.
function FindAlphaAux(C: THeifContainer; AMasterID: LongWord): THeifItem;
var
  K: Integer;
  Refs: TArray<LongWord>;
  J: Integer;
begin
  Result := nil;
  for K := 0 to C.Items.Count - 1 do
    if IsAlphaAux(C.Items[K]) then
    begin
      Refs := C.GetReferences(C.Items[K].ID, 'auxl');
      for J := 0 to High(Refs) do
        if Refs[J] = AMasterID then
          Exit(C.Items[K]);
    end;
end;

function DecodeHeifItem(C: THeifContainer; AItemID: LongWord;
  out AImg: THeifImage): Boolean;
var
  Item, AlphaItem: THeifItem;
  AlphaImg: THeifImage;
  N: Integer;
begin
  Item := FindItemByID(C, AItemID);
  if Item = nil then
    raise EHeifDecode.CreateFmt('Item %d not found', [AItemID]);
  Result := DecodeMaster(C, Item, AImg);
  if not Result then Exit;

  // Attach an alpha plane if a matching alpha aux item exists.
  AlphaItem := FindAlphaAux(C, AItemID);
  if (AlphaItem <> nil) and DecodeMaster(C, AlphaItem, AlphaImg) then
  begin
    N := AImg.Width * AImg.Height;
    // Alpha is coded as luma; use its Y plane if the geometry matches.
    if Length(AlphaImg.Y) = N then
    begin
      AImg.Alpha := AlphaImg.Y;
      AImg.AlphaBitDepth := AlphaImg.BitDepth;
      AImg.HasAlpha := True;
    end;
  end;
end;

function DecodeHeifPrimary(C: THeifContainer; out AImg: THeifImage): Boolean;
begin
  Result := DecodeHeifItem(C, C.PrimaryItemID, AImg);
end;

procedure HeifImageToRGB(const AImg: THeifImage; out ARGB: TBytes;
  out AOutW, AOutH: Integer);
var
  X, Y, Ofs, OX, OY, OutW, OutH: Integer;
  Kr, Kb, Kg: Double;
  Yn, Cbn, Crn: Double;
  Rr, Gg, Bb: Double;
  YV: Integer;
  UVf, VVf: Double;
  HShiftX, HShiftY: Integer;
  UseNearestChroma: Boolean;
  Scale, MaxVal, ChromaMid: Integer;

  function ClipB(V: Double): Byte;
  var I: Integer;
  begin
    I := Round(V * 255);
    if I < 0 then I := 0 else if I > 255 then I := 255;
    Result := Byte(I);
  end;

  function SampleAt(const Plane: TSamplePlane; PX, PY: Integer): Double; inline;
  begin
    if PX < 0 then PX := 0 else if PX >= AImg.ChromaWidth then PX := AImg.ChromaWidth - 1;
    if PY < 0 then PY := 0 else if PY >= AImg.ChromaHeight then PY := AImg.ChromaHeight - 1;
    Result := Plane[PY * AImg.ChromaWidth + PX];
  end;

  // Bilinear-samples a chroma plane at the luma pixel (LX,LY), accounting for
  // subsampling. Uses centered 4:2:0 siting to match our encoder's 2x2 box
  // averaging: chroma sample c represents the centre of its 2x2 luma block, at
  // luma coordinate 2c+0.5, so the chroma coordinate of luma pixel L is
  // (L-0.5)/2. Non-subsampled dimensions map straight through.
  function BilinearChroma(const Plane: TSamplePlane; LX, LY: Integer): Double;
  var
    Fx, Fy, Wx, Wy: Double;
    X0, Y0: Integer;
    C00, C10, C01, C11, Top, Bot: Double;
  begin
    if HShiftX = 1 then Fx := (LX - 0.5) / 2.0 else Fx := LX;
    if HShiftY = 1 then Fy := (LY - 0.5) / 2.0 else Fy := LY;
    X0 := Floor(Fx); Y0 := Floor(Fy);
    Wx := Fx - X0;   Wy := Fy - Y0;
    if UseNearestChroma then
    begin
      Result := SampleAt(Plane, Round(Fx), Round(Fy));
      Exit;
    end;
    C00 := SampleAt(Plane, X0,     Y0);
    C10 := SampleAt(Plane, X0 + 1, Y0);
    C01 := SampleAt(Plane, X0,     Y0 + 1);
    C11 := SampleAt(Plane, X0 + 1, Y0 + 1);
    Top := C00 + (C10 - C00) * Wx;
    Bot := C01 + (C11 - C01) * Wx;
    Result := Top + (Bot - Top) * Wy;
  end;

begin
  // Luma/chroma weights per matrix_coefficients.
  case AImg.MatrixCoefficients of
    1: begin Kr := 0.2126; Kb := 0.0722; end;       // BT.709
    9, 10: begin Kr := 0.2627; Kb := 0.0593; end;    // BT.2020
  else
    begin Kr := 0.299; Kb := 0.114; end;             // BT.601 (5/6) and default
  end;
  Kg := 1.0 - Kr - Kb;
  UseNearestChroma := GetEnvironmentVariable('HEIF_NEAREST') <> '';
  Scale := 1 shl (AImg.BitDepth - 8);          // 1, 4, 16 for 8/10/12-bit
  MaxVal := (1 shl AImg.BitDepth) - 1;
  ChromaMid := 1 shl (AImg.BitDepth - 1);      // 128, 512, 2048

  // Chroma subsampling shifts.
  case AImg.ChromaFormat of
    1: begin HShiftX := 1; HShiftY := 1; end;  // 4:2:0
    2: begin HShiftX := 1; HShiftY := 0; end;  // 4:2:2
  else
    begin HShiftX := 0; HShiftY := 0; end;     // 4:4:4 / mono
  end;

  // Output dimensions and coordinate mapping account for the display rotation.
  if (AImg.Rotation = 90) or (AImg.Rotation = 270) then
  begin
    OutW := AImg.Height; OutH := AImg.Width;
  end
  else
  begin
    OutW := AImg.Width; OutH := AImg.Height;
  end;

  SetLength(ARGB, OutW * OutH * 3);
  for OY := 0 to OutH - 1 do
    for OX := 0 to OutW - 1 do
    begin
      // Map output pixel (OX,OY) back to source (X,Y). Rotation is CCW.
      case AImg.Rotation of
        90:  begin X := AImg.Width - 1 - OY; Y := OX; end;
        180: begin X := AImg.Width - 1 - OX; Y := AImg.Height - 1 - OY; end;
        270: begin X := OY; Y := AImg.Height - 1 - OX; end;
      else
        begin X := OX; Y := OY; end;
      end;
      Ofs := (OY * OutW + OX) * 3;

      YV := AImg.Y[Y * AImg.Width + X];
      if AImg.ChromaFormat = 0 then
      begin
        UVf := ChromaMid; VVf := ChromaMid;
      end
      else
      begin
        UVf := BilinearChroma(AImg.U, X, Y);
        VVf := BilinearChroma(AImg.V, X, Y);
      end;

      // Normalise to Y in [0,1], Cb/Cr in [-0.5,0.5], at the coded bit depth.
      if AImg.FullRange then
      begin
        Yn := YV / MaxVal;
        Cbn := (UVf - ChromaMid) / MaxVal;
        Crn := (VVf - ChromaMid) / MaxVal;
      end
      else
      begin
        Yn := (YV - 16 * Scale) / (219 * Scale);
        Cbn := (UVf - ChromaMid) / (224 * Scale);
        Crn := (VVf - ChromaMid) / (224 * Scale);
      end;

      Rr := Yn + 2 * (1 - Kr) * Crn;
      Bb := Yn + 2 * (1 - Kb) * Cbn;
      Gg := Yn - (2 * Kb * (1 - Kb) / Kg) * Cbn - (2 * Kr * (1 - Kr) / Kg) * Crn;

      ARGB[Ofs + 0] := ClipB(Rr);
      ARGB[Ofs + 1] := ClipB(Gg);
      ARGB[Ofs + 2] := ClipB(Bb);
    end;
  AOutW := OutW;
  AOutH := OutH;
end;

procedure HeifImageToRGBA(const AImg: THeifImage; out ARGBA: TBytes;
  out AOutW, AOutH: Integer);
var
  RGB: TBytes;
  OX, OY, X, Y, AMax: Integer;
  A: Integer;
begin
  HeifImageToRGB(AImg, RGB, AOutW, AOutH);
  SetLength(ARGBA, AOutW * AOutH * 4);
  if AImg.HasAlpha then AMax := (1 shl AImg.AlphaBitDepth) - 1 else AMax := 255;
  for OY := 0 to AOutH - 1 do
    for OX := 0 to AOutW - 1 do
    begin
      if AImg.HasAlpha then
      begin
        // Same rotation mapping as HeifImageToRGB to align alpha with colour.
        case AImg.Rotation of
          90:  begin X := AImg.Width - 1 - OY; Y := OX; end;
          180: begin X := AImg.Width - 1 - OX; Y := AImg.Height - 1 - OY; end;
          270: begin X := OY; Y := AImg.Height - 1 - OX; end;
        else
          begin X := OX; Y := OY; end;
        end;
        A := (AImg.Alpha[Y * AImg.Width + X] * 255 + AMax div 2) div AMax;
      end
      else
        A := 255;
      ARGBA[(OY * AOutW + OX) * 4 + 0] := RGB[(OY * AOutW + OX) * 3 + 0];
      ARGBA[(OY * AOutW + OX) * 4 + 1] := RGB[(OY * AOutW + OX) * 3 + 1];
      ARGBA[(OY * AOutW + OX) * 4 + 2] := RGB[(OY * AOutW + OX) * 3 + 2];
      ARGBA[(OY * AOutW + OX) * 4 + 3] := Byte(A);
    end;
end;

end.
