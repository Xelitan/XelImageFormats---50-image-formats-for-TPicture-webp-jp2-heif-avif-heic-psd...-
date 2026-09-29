{$mode delphi}
unit jxl_frame;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// JPEG XL frame decoder, ported from libjxl 0.11.2:
//   frame_header.cc, loop_filter.cc   FrameHeader, Passes, BlendingInfo,
//                                     LoopFilter
//   toc.cc, coeff_order.cc,           TOC with its permutation, coefficient
//   lehmer_code.h                     orders
//   dec_frame.cc                      section dispatch (DC global, DC groups,
//                                     AC global, AC groups/passes)
//   dec_modular.cc                    modular frame data: global image, group
//                                     streams, VarDCT DC and AC metadata,
//                                     int -> float conversion
//   quantizer.cc, chroma_from_luma.cc,
//   entropy_coder.cc, ac_context.h,
//   compressed_dc.cc, epf.cc          VarDCT side information
//   dec_group.cc                      AC coefficients, dequantization, IDCT
//   dec_cache.cc (PreparePipeline)    render stages, applied to whole planes
//                                     (see jxl_render / jxl_features)
// Frames are composed (blending, reference frames, DC frames) as libjxl does
// when coalescing.

interface

uses
  SysUtils, Math, jxl_types, jxl_bits, jxl_ans, jxl_modular, jxl_quant,
  jxl_dct, jxl_render, jxl_features, jxl_color;

const
  kFlagNoise = 1;
  kFlagPatches = 2;
  kFlagSplines = 16;
  kFlagUseDcFrame = 32;
  kFlagSkipAdaptiveDCSmoothing = 128;

  CT_XYB = 0;
  CT_NONE = 1;
  CT_YCBCR = 2;

  FT_REGULAR = 0;
  FT_DC = 1;
  FT_REFONLY = 2;
  FT_SKIPPROG = 3;

  BM_REPLACE = 0;
  BM_ADD = 1;
  BM_BLEND = 2;
  BM_AWADD = 3;
  BM_MUL = 4;

type
  TBlendingInfo = record
    Mode, AlphaChannel, Source: Integer;
    Clamp: Boolean;
  end;

  TFrameHeader = record
    FrameType: Integer;
    IsModular: Boolean;
    Flags: UInt64;
    ColorTransform: Integer;
    ChannelMode: array[0..2] of Integer;
    Upsampling: Integer;
    ECUpsampling: array of Integer;
    GroupSizeShift: Integer;
    XQMScale, BQMScale: Integer;
    NumPasses, NumDownsample: Integer;
    Shift: array[0..10] of Integer;
    Downsample, LastPass: array[0..3] of Integer;
    DcLevel: Integer;
    CustomSizeOrOrigin: Boolean;
    X0, Y0: Integer;
    XSize, YSize: Integer;          // frame_size; 0 = image size
    Blending: TBlendingInfo;
    ECBlending: array of TBlendingInfo;
    Duration, Timecode: Cardinal;
    IsLast: Boolean;
    SaveAsReference: Integer;
    SaveBeforeCT: Boolean;
    Name: AnsiString;
    Gab: Boolean;
    LF: TLoopFilterParams;
    IsPreview: Boolean;
  end;

  TFrameDim = record
    XSize, YSize, XSizeUpsampled, YSizeUpsampled, XSizePadded, YSizePadded,
    XSizeBlocks, YSizeBlocks, XSizeGroups, YSizeGroups, XSizeDCGroups,
    YSizeDCGroups, NumGroups, NumDCGroups, GroupDim, DCGroupDim: Integer;
  end;

  // State shared by the frames of one codestream.
  TJxlDecodeState = class
  public
    Metadata: TJxlImageMetadata;
    Refs: TJxlRefFrames;
    DcFrames: array[0..3] of TPlaneArray;
    VisibleIdx, NonvisibleIdx: Cardinal;
    constructor Create(const md: TJxlImageMetadata);
  end;

// Decodes the frame that starts at byte `pos` of the codestream and returns
// the byte position after it. When skip is set only the header and TOC are
// read. displayed is True for a frame that is shown (regular/skip-progressive,
// last or with a duration); output then holds the composed image-size result:
// 3 colour planes in the output colour space followed by the extra channels.
function DecodeJxlFrame(st: TJxlDecodeState; data: PByte; size: NativeUInt;
                        pos: NativeUInt; isPreview, skip: Boolean;
                        out hdr: TFrameHeader; out displayed: Boolean;
                        var output: TPlaneArray): NativeUInt;

implementation

const
  kQuantMax = 256;
  kNonZeroBuckets = 37;
  kZeroDensityContextCount = 458;
  kZeroDensityContextLimit = 474;
  kPermutationContexts = 8;
  kColorTileDimInBlocks = 8;
  kDefaultColorFactor = 84;
  kNumOrders = 13;

  kCoeffFreqContext: array[0..63] of Integer = (
    0, 0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14,
    15,    15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
    23,    23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26,
    27,    27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30);
  kCoeffNumNonzeroContext: array[0..63] of Integer = (
    0, 0,   31,  62,  62,  93,  93,  93,  93,  123, 123, 123, 123,
    152,   152, 152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180,
    180,   180, 180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206,
    206,   206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
    206,   206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206);
  kDefaultCtxMap: array[0..38] of Byte = (
    0, 1, 2, 2, 3,  3,  4,  5,  6,  6,  6,  6,  6,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14);

  kHShiftMode: array[0..3] of Integer = (0, 1, 1, 0);
  kVShiftMode: array[0..3] of Integer = (0, 1, 0, 1);

type
  TBlockCtxMap = record
    DcThresholds: array[0..2] of array of Integer;
    QfThresholds: array of Cardinal;
    CtxMap: array of Byte;
    NumCtxs, NumDcCtxs: Integer;
  end;

  TFrameDec = class
  private
    st: TJxlDecodeState;
    md: TJxlImageMetadata;
    H: TFrameHeader;
    FD: TFrameDim;
    NumEC: Integer;
    MaxHS, MaxVS: Integer;
    HS, VS: array[0..2] of Integer;
    // sections (by section id, offsets relative to the frame start)
    SecOff, SecSize: array of NativeUInt;
    Data: PByte;
    FrameSize: NativeUInt;
    SingleSection: Boolean;
    // global
    Matrices: TDequantMatrices;
    Patches: TPatchDictionary;
    Noise: TNoiseParams;
    // modular
    Tree: TMATree;
    TreeAns: TANSDecoder;
    Full: TModImage;
    GlobalHdr: TModGroupHeader;
    DoColor: Boolean;
    // VarDCT
    GlobalScale, QuantDC: Integer;
    InvGlobalScale, QuantScale: Single;
    MulDC: array[0..2] of Single;
    BCtx: TBlockCtxMap;
    ColorFactor: Integer;
    BaseCorrX, BaseCorrB: Single;
    YtoXDC, YtoBDC: Integer;
    DCFactors: array[0..2] of Single;
    Acs: array of ShortInt;         // strategy of every block, -1 = unset
    AcsFirst: array of Boolean;
    QF: array of Int32;
    Sharp: array of Byte;
    Sigma: array of Single;         // inverse sigma per block
    QDC: array of Byte;
    DC: TPlanes3;                   // xsize_blocks x ysize_blocks
    UseDcFrame: Boolean;
    CmapW, CmapH: Integer;
    YtoX, YtoB: array of ShortInt;
    UsedAcs: Cardinal;
    NumHistograms: Integer;
    CoeffOrders: array of array of Cardinal;   // per pass
    AcAns: array of TANSDecoder;               // per pass
    XDmMul, BDmMul: Single;
    Pix: TPlanes3;                             // VarDCT pixels (padded)
    // the frame: colour at channel resolution + extra channels
    Planes: TPlaneArray;

    function SectionReader(id: Integer): TBitReader;
    procedure ReadHeader(br: TBitReader);
    procedure ComputeDims;
    procedure ReadTOC(br: TBitReader);

    procedure ProcessDCGlobal(br: TBitReader);
    procedure ProcessDCGroup(g: Integer; br: TBitReader);
    procedure FinalizeDC;
    procedure ProcessACGlobal(br: TBitReader);
    procedure ProcessACGroup(g: Integer; const brs: array of TBitReader);
    procedure ModularGroupPass(g, pass: Integer; br: TBitReader);

    procedure ModularGlobal(br: TBitReader);
    procedure ModularGroup(x0, y0, xs, ys: Integer; br: TBitReader;
                           minShift, maxShift, streamId: Integer);
    procedure ModularFinalize;
    procedure ReadRawQuantTable(br: TBitReader; idx, sizeX, sizeY: Integer;
                                var table: array of Integer);

    procedure DecodeQuantizer(br: TBitReader);
    procedure DecodeBlockCtxMap(br: TBitReader);
    procedure DecodeCmapDC(br: TBitReader);
    procedure DecodeVarDCTDC(g: Integer; br: TBitReader);
    procedure DecodeAcMetadata(g: Integer; br: TBitReader);
    procedure ComputeSigma(bx0, by0, bxs, bys: Integer);
    procedure DecodeCoeffOrders(usedOrders: Cardinal; var order: array of Cardinal;
                                br: TBitReader);
    function BlockContext(dcIdx: Integer; qf: Cardinal; ord, c: Integer): Integer;

    procedure RenderFrame;
    procedure Compose(out displayed: Boolean; var output: TPlaneArray);
  public
    constructor Create(ast: TJxlDecodeState);
    destructor Destroy; override;
  end;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function DivCeil(a, b: Int64): Int64; inline;
begin
  Result := (a + b - 1) div b;
end;

function FloorLog2(x: UInt64): Integer;
var v: UInt64;
begin
  Result := -1;
  v := x;
  while v <> 0 do begin Inc(Result); v := v shr 1; end;
end;

function CeilLog2Nonzero(x: UInt64): Integer;
begin
  Result := FloorLog2(x);
  if (x and (x - 1)) <> 0 then Inc(Result);
end;

function UnpackSignedI(v: Cardinal): Int64; inline;
begin
  if (v and 1) <> 0 then Result := -((Int64(v) + 1) shr 1)
  else Result := Int64(v) shr 1;
end;

procedure SkipExtensions(br: TBitReader);
var
  mask, total, n: UInt64;
  i: Integer;
begin
  mask := br.ReadU64;
  if mask = 0 then Exit;
  total := 0;
  for i := 0 to 63 do
    if ((mask shr i) and 1) <> 0 then
    begin
      n := br.ReadU64;
      if n > UInt64(1) shl 40 then raise EJxlError.Create('Invalid extension size');
      Inc(total, n);
    end;
  while total >= 32 do begin br.ReadBits(32); Dec(total, 32); end;
  if total > 0 then br.ReadBits(Integer(total));
end;

function CopyPlane(const p: TFloat32Plane): TFloat32Plane;
begin
  Result.Width := p.Width;
  Result.Height := p.Height;
  Result.Stride := p.Stride;
  Result.Data := Copy(p.Data);
end;

// Crops (or zero-pads) a plane to w x h with a tight stride.
procedure CropPlane(var p: TFloat32Plane; w, h: Integer);
var
  o: TFloat32Plane;
  y, cw: Integer;
begin
  if (p.Width = w) and (p.Height = h) and (p.Stride = w) then Exit;
  InitFloat32Plane(o, w, h);
  cw := Min(w, p.Width);
  if cw > 0 then
    for y := 0 to Min(h, p.Height) - 1 do
      Move(p.Data[y * p.Stride], o.Data[y * w], cw * SizeOf(Single));
  p := o;
end;

// ---------------------------------------------------------------------------
// Lehmer code / permutations (lehmer_code.h, coeff_order.cc)
// ---------------------------------------------------------------------------
function CoeffOrderContext(val: Cardinal): Integer; inline;
begin
  if val = 0 then Result := 0
  else Result := 1 + FloorLog2(val);
  if Result > kPermutationContexts - 1 then Result := kPermutationContexts - 1;
end;

procedure DecodeLehmerCode(const code: array of Cardinal; n: Integer; perm: PCardinal);
var
  log2n, padded, i, j: Integer;
  temp: array of Cardinal;
  rank: Cardinal;
  bit, next, cand: Integer;
begin
  log2n := CeilLog2Nonzero(n);
  padded := 1 shl log2n;
  SetLength(temp, padded);
  for i := 0 to padded - 1 do temp[i] := Cardinal((i + 1) and -(i + 1));
  for i := 0 to n - 1 do
  begin
    if Int64(code[i]) + i >= n then raise EJxlError.Create('Invalid lehmer code');
    rank := code[i] + 1;
    bit := padded;
    next := 0;
    for j := 0 to log2n do
    begin
      cand := next + bit;
      bit := bit shr 1;
      if (cand >= 1) and (cand <= padded) and (temp[cand - 1] < rank) then
      begin
        next := cand;
        Dec(rank, temp[cand - 1]);
      end;
    end;
    perm[i] := next;
    Inc(next);
    while next <= padded do
    begin
      Dec(temp[next - 1]);
      Inc(next, next and -next);
    end;
  end;
end;

procedure ReadPermutation(br: TBitReader; ans: TANSDecoder; skip, size: Integer;
                          order: PCardinal);
var
  lehmer: array of Cardinal;
  endv, i: Integer;
  last: Cardinal;
begin
  SetLength(lehmer, size);
  endv := Integer(ans.Decode(CoeffOrderContext(size), br)) + skip;
  if endv > size then raise EJxlError.Create('Invalid permutation size');
  last := 0;
  for i := skip to endv - 1 do
  begin
    lehmer[i] := ans.Decode(CoeffOrderContext(last), br);
    last := lehmer[i];
    if lehmer[i] >= Cardinal(size - i) then raise EJxlError.Create('Invalid lehmer code');
  end;
  if order = nil then Exit;
  DecodeLehmerCode(lehmer, size, order);
end;

// ---------------------------------------------------------------------------
// TJxlDecodeState
// ---------------------------------------------------------------------------
constructor TJxlDecodeState.Create(const md: TJxlImageMetadata);
begin
  inherited Create;
  Metadata := md;
end;

// ---------------------------------------------------------------------------
// TFrameDec: setup
// ---------------------------------------------------------------------------
constructor TFrameDec.Create(ast: TJxlDecodeState);
begin
  inherited Create;
  st := ast;
  md := ast.Metadata;
  NumEC := Length(md.ExtraChannels);
  Matrices := TDequantMatrices.Create;
  ColorFactor := kDefaultColorFactor;
  BaseCorrX := 0;
  BaseCorrB := 1.0;   // used by the noise of modular frames too
end;

destructor TFrameDec.Destroy;
var i: Integer;
begin
  Matrices.Free;
  TreeAns.Free;
  for i := 0 to High(AcAns) do AcAns[i].Free;
  inherited;
end;

function TFrameDec.SectionReader(id: Integer): TBitReader;
begin
  Result := TBitReader.Create(Data + SecOff[id], SecSize[id]);
end;

// ---------------------------------------------------------------------------
// Frame header (frame_header.cc)
// ---------------------------------------------------------------------------
procedure ReadBlendingInfo(br: TBitReader; var bi: TBlendingInfo;
                           numEC: Integer; isPartial: Boolean);
begin
  bi.Mode := Integer(br.ReadU32(0, 0, 1, 0, 2, 0, 3, 2));
  if bi.Mode > BM_MUL then raise EJxlError.Create('Invalid blend mode');
  bi.AlphaChannel := 0;
  bi.Clamp := False;
  bi.Source := 0;
  if (numEC > 0) and ((bi.Mode = BM_BLEND) or (bi.Mode = BM_AWADD)) then
  begin
    bi.AlphaChannel := Integer(br.ReadU32(0, 0, 1, 0, 2, 0, 3, 3));
    if bi.AlphaChannel >= numEC then
      raise EJxlError.Create('Invalid alpha channel for blending');
  end;
  if ((numEC > 0) and ((bi.Mode = BM_BLEND) or (bi.Mode = BM_AWADD))) or
     (bi.Mode = BM_MUL) then
    bi.Clamp := br.ReadBit;
  if (bi.Mode <> BM_REPLACE) or isPartial then
    bi.Source := Integer(br.ReadU32(0, 0, 1, 0, 2, 0, 3, 0));
end;

procedure ReadLoopFilter(br: TBitReader; var h: TFrameHeader; isModular: Boolean);
var i: Integer;
begin
  h.Gab := True;
  SetDefaultLoopFilter(h.LF);
  if br.ReadBit then Exit;   // all default
  h.Gab := br.ReadBit;
  if h.Gab then
    if br.ReadBit then   // gab_custom
      for i := 0 to 2 do
      begin
        h.LF.GabW[i][0] := br.ReadF16;
        h.LF.GabW[i][1] := br.ReadF16;
        if Abs(1.0 + (h.LF.GabW[i][0] + h.LF.GabW[i][1]) * 4) < 1e-8 then
          raise EJxlError.Create('Gaborish weights lead to near 0 kernel');
      end;
  h.LF.EpfIters := br.ReadBits(2);
  if h.LF.EpfIters > 0 then
  begin
    if not isModular then
      if br.ReadBit then
        for i := 0 to 7 do h.LF.EpfSharpLut[i] := br.ReadF16;
    if br.ReadBit then
    begin
      for i := 0 to 2 do h.LF.EpfChannelScale[i] := br.ReadF16;
      h.LF.EpfPass1Zeroflush := br.ReadF16;
      h.LF.EpfPass2Zeroflush := br.ReadF16;
    end;
    if br.ReadBit then
    begin
      if not isModular then h.LF.EpfQuantMul := br.ReadF16;
      h.LF.EpfPass0SigmaScale := br.ReadF16;
      h.LF.EpfPass2SigmaScale := br.ReadF16;
      h.LF.EpfBorderSadMul := br.ReadF16;
    end;
    if isModular then
    begin
      h.LF.EpfSigmaForModular := br.ReadF16;
      if h.LF.EpfSigmaForModular < 1e-8 then
        raise EJxlError.Create('EPF: sigma for modular is too small');
    end;
  end;
  SkipExtensions(br);
end;

procedure TFrameDec.ReadHeader(br: TBitReader);
var
  i, j, dimShift, imgW, imgH: Integer;
  isPartial, xyb: Boolean;
  ux0, uy0, nameLen, ecu: Cardinal;
begin
  // defaults
  H.FrameType := FT_REGULAR;
  H.IsModular := False;
  H.Flags := 0;
  xyb := md.XYBEncoded;
  if xyb then H.ColorTransform := CT_XYB else H.ColorTransform := CT_NONE;
  for i := 0 to 2 do H.ChannelMode[i] := 0;
  H.Upsampling := 1;
  SetLength(H.ECUpsampling, NumEC);
  for i := 0 to NumEC - 1 do H.ECUpsampling[i] := 1 shl md.ExtraChannels[i].DimShift;
  H.GroupSizeShift := 1;
  if xyb then begin H.XQMScale := 3; H.BQMScale := 2; end
  else begin H.XQMScale := 2; H.BQMScale := 2; end;
  H.NumPasses := 1;
  H.NumDownsample := 0;
  for i := 0 to 10 do H.Shift[i] := 0;
  H.DcLevel := 0;
  H.CustomSizeOrOrigin := False;
  H.X0 := 0; H.Y0 := 0; H.XSize := 0; H.YSize := 0;
  FillChar(H.Blending, SizeOf(H.Blending), 0);
  SetLength(H.ECBlending, NumEC);
  for i := 0 to NumEC - 1 do FillChar(H.ECBlending[i], SizeOf(TBlendingInfo), 0);
  H.Duration := 0; H.Timecode := 0;
  H.IsLast := True;
  H.SaveAsReference := 0;
  H.SaveBeforeCT := False;
  H.Name := '';
  H.Gab := True;
  SetDefaultLoopFilter(H.LF);

  if H.IsPreview then
  begin
    imgW := md.PreviewXSize; imgH := md.PreviewYSize;
  end
  else
  begin
    imgW := md.XSize; imgH := md.YSize;
  end;

  if br.ReadBit then Exit;   // all default

  H.FrameType := Integer(br.ReadU32(0, 0, 1, 0, 2, 0, 3, 0));
  if H.IsPreview and (H.FrameType <> FT_REGULAR) then
    raise EJxlError.Create('Only regular frame could be a preview');
  H.IsModular := br.ReadBit;
  H.Flags := br.ReadU64;
  if not xyb then
    if br.ReadBit then H.ColorTransform := CT_YCBCR;
  if (H.ColorTransform = CT_YCBCR) and ((H.Flags and kFlagUseDcFrame) = 0) then
    for i := 0 to 2 do H.ChannelMode[i] := br.ReadBits(2);

  if (H.Flags and kFlagUseDcFrame) = 0 then
  begin
    H.Upsampling := Integer(br.ReadU32(1, 0, 2, 0, 4, 0, 8, 0));
    for i := 0 to NumEC - 1 do
    begin
      dimShift := md.ExtraChannels[i].DimShift;
      ecu := br.ReadU32(1, 0, 2, 0, 4, 0, 8, 0);
      H.ECUpsampling[i] := Integer(ecu shl dimShift);
      if H.ECUpsampling[i] < H.Upsampling then
        raise EJxlError.Create('EC upsampling < color upsampling');
      if H.ECUpsampling[i] > 8 then
        raise EJxlError.Create('EC upsampling too large');
    end;
  end;

  if H.IsModular then H.GroupSizeShift := br.ReadBits(2);
  if (not H.IsModular) and (H.ColorTransform = CT_XYB) then
  begin
    H.XQMScale := br.ReadBits(3);
    H.BQMScale := br.ReadBits(3);
  end
  else
  begin
    H.XQMScale := 2; H.BQMScale := 2;
  end;

  if H.FrameType <> FT_REFONLY then
  begin
    H.NumPasses := Integer(br.ReadU32(1, 0, 2, 0, 3, 0, 4, 3));
    if H.NumPasses > MAX_NUM_PASSES then raise EJxlError.Create('Too many passes');
    if H.NumPasses <> 1 then
    begin
      H.NumDownsample := Integer(br.ReadU32(0, 0, 1, 0, 2, 0, 3, 1));
      if H.NumDownsample > H.NumPasses then
        raise EJxlError.Create('num_downsample > num_passes');
      for i := 0 to H.NumPasses - 2 do H.Shift[i] := br.ReadBits(2);
      H.Shift[H.NumPasses - 1] := 0;
      for i := 0 to H.NumDownsample - 1 do
      begin
        H.Downsample[i] := Integer(br.ReadU32(1, 0, 2, 0, 4, 0, 8, 0));
        if (i > 0) and (H.Downsample[i] >= H.Downsample[i - 1]) then
          raise EJxlError.Create('downsample sequence should be decreasing');
      end;
      for i := 0 to H.NumDownsample - 1 do
      begin
        H.LastPass[i] := Integer(br.ReadU32(0, 0, 1, 0, 2, 0, 0, 3));
        if (i > 0) and (H.LastPass[i] <= H.LastPass[i - 1]) then
          raise EJxlError.Create('last_pass sequence should be increasing');
        if H.LastPass[i] >= H.NumPasses then
          raise EJxlError.Create('last_pass >= num_passes');
      end;
    end;
  end;

  if H.FrameType = FT_DC then
    H.DcLevel := Integer(br.ReadU32(1, 0, 2, 0, 3, 0, 4, 0));

  isPartial := False;
  if H.FrameType <> FT_DC then
  begin
    H.CustomSizeOrOrigin := br.ReadBit;
    if H.CustomSizeOrOrigin then
    begin
      if (H.FrameType = FT_REGULAR) or (H.FrameType = FT_SKIPPROG) then
      begin
        ux0 := br.ReadU32(0, 8, 256, 11, 2304, 14, 18688, 30);
        uy0 := br.ReadU32(0, 8, 256, 11, 2304, 14, 18688, 30);
        H.X0 := Integer(UnpackSignedI(ux0));
        H.Y0 := Integer(UnpackSignedI(uy0));
      end;
      H.XSize := Integer(br.ReadU32(0, 8, 256, 11, 2304, 14, 18688, 30));
      H.YSize := Integer(br.ReadU32(0, 8, 256, 11, 2304, 14, 18688, 30));
      if (H.XSize = 0) or (H.YSize = 0) then
        raise EJxlError.Create('Invalid crop dimensions for frame');
      if (H.FrameType = FT_REGULAR) or (H.FrameType = FT_SKIPPROG) then
        isPartial := (H.X0 > 0) or (H.Y0 > 0) or (H.XSize + H.X0 < imgW) or
                     (H.YSize + H.Y0 < imgH);
    end;
  end;

  if (H.FrameType = FT_REGULAR) or (H.FrameType = FT_SKIPPROG) then
  begin
    ReadBlendingInfo(br, H.Blending, NumEC, isPartial);
    for i := 0 to NumEC - 1 do
      ReadBlendingInfo(br, H.ECBlending[i], NumEC, isPartial);
    if md.HaveAnimation then
    begin
      H.Duration := br.ReadU32(0, 0, 1, 0, 0, 8, 0, 32);
      if md.HaveTimecodes then H.Timecode := br.ReadBits(32);
    end;
    H.IsLast := br.ReadBit;
  end
  else
    H.IsLast := False;

  if (H.FrameType <> FT_DC) and not H.IsLast then
    H.SaveAsReference := Integer(br.ReadU32(0, 0, 1, 0, 2, 0, 3, 0));

  if H.FrameType <> FT_DC then
  begin
    if (not H.IsLast) and ((H.Duration = 0) or (H.SaveAsReference <> 0)) and
       (H.Blending.Mode = BM_REPLACE) and not isPartial and
       ((H.FrameType = FT_REGULAR) or (H.FrameType = FT_SKIPPROG)) then
      H.SaveBeforeCT := br.ReadBit
    else if H.FrameType = FT_REFONLY then
      H.SaveBeforeCT := br.ReadBit;
  end
  else
    H.SaveBeforeCT := True;

  nameLen := br.ReadU32(0, 0, 0, 4, 16, 5, 48, 10);
  SetLength(H.Name, nameLen);
  for j := 1 to Integer(nameLen) do H.Name[j] := AnsiChar(br.ReadBits(8));

  ReadLoopFilter(br, H, H.IsModular);
  SkipExtensions(br);
end;

procedure TFrameDec.ComputeDims;
var
  xs, ys, c, gd: Integer;
begin
  MaxHS := 0; MaxVS := 0;
  for c := 0 to 2 do
  begin
    MaxHS := Max(MaxHS, kHShiftMode[H.ChannelMode[c]]);
    MaxVS := Max(MaxVS, kVShiftMode[H.ChannelMode[c]]);
  end;
  for c := 0 to 2 do
  begin
    HS[c] := MaxHS - kHShiftMode[H.ChannelMode[c]];
    VS[c] := MaxVS - kVShiftMode[H.ChannelMode[c]];
  end;
  if H.IsPreview then begin xs := md.PreviewXSize; ys := md.PreviewYSize; end
  else begin xs := md.XSize; ys := md.YSize; end;
  if H.XSize <> 0 then xs := H.XSize;
  if H.YSize <> 0 then ys := H.YSize;
  if H.DcLevel <> 0 then
  begin
    xs := DivCeil(xs, Int64(1) shl (3 * H.DcLevel));
    ys := DivCeil(ys, Int64(1) shl (3 * H.DcLevel));
  end;
  gd := (kGroupDim shr 1) shl H.GroupSizeShift;
  FD.GroupDim := gd;
  FD.DCGroupDim := gd * 8;
  FD.XSizeUpsampled := xs;
  FD.YSizeUpsampled := ys;
  FD.XSize := DivCeil(xs, H.Upsampling);
  FD.YSize := DivCeil(ys, H.Upsampling);
  FD.XSizeBlocks := DivCeil(FD.XSize, 8 shl MaxHS) shl MaxHS;
  FD.YSizeBlocks := DivCeil(FD.YSize, 8 shl MaxVS) shl MaxVS;
  FD.XSizePadded := FD.XSizeBlocks * 8;
  FD.YSizePadded := FD.YSizeBlocks * 8;
  if H.IsModular then
  begin
    FD.XSizePadded := FD.XSize;
    FD.YSizePadded := FD.YSize;
  end;
  FD.XSizeGroups := DivCeil(FD.XSize, gd);
  FD.YSizeGroups := DivCeil(FD.YSize, gd);
  FD.XSizeDCGroups := DivCeil(FD.XSizeBlocks, gd);
  FD.YSizeDCGroups := DivCeil(FD.YSizeBlocks, gd);
  FD.NumGroups := FD.XSizeGroups * FD.YSizeGroups;
  FD.NumDCGroups := FD.XSizeDCGroups * FD.YSizeDCGroups;
end;

// ---------------------------------------------------------------------------
// TOC (toc.cc). Offsets are relative to the start of the frame.
// ---------------------------------------------------------------------------
procedure TFrameDec.ReadTOC(br: TBitReader);
var
  n, i: Integer;
  perm: array of Cardinal;
  sizes: array of Cardinal;
  offs: array of NativeUInt;
  ans: TANSDecoder;
  base, sum: NativeUInt;
begin
  if (FD.NumGroups = 1) and (H.NumPasses = 1) then n := 1
  else n := 2 + FD.NumDCGroups + FD.NumGroups * H.NumPasses;
  if n > 65536 then raise EJxlError.Create('Too many TOC entries');
  SingleSection := n = 1;
  SetLength(perm, 0);
  if br.ReadBit then
  begin
    SetLength(perm, n);
    ans := TANSDecoder.Create;
    try
      ans.Init(br, kPermutationContexts);
      ReadPermutation(br, ans, 0, n, @perm[0]);
      if not ans.CheckFinalState then raise EJxlError.Create('TOC: invalid ANS stream');
    finally
      ans.Free;
    end;
  end;
  br.AlignToByte;
  SetLength(sizes, n);
  for i := 0 to n - 1 do
    sizes[i] := br.ReadU32(0, 10, 1024, 14, 17408, 22, 4211712, 30);
  br.AlignToByte;
  base := br.BitsRead div 8;
  SetLength(offs, n);
  sum := 0;
  for i := 0 to n - 1 do
  begin
    offs[i] := sum;
    Inc(sum, sizes[i]);
  end;
  SetLength(SecOff, n);
  SetLength(SecSize, n);
  for i := 0 to n - 1 do
    if Length(perm) > 0 then
    begin
      SecOff[i] := base + offs[perm[i]];
      SecSize[i] := sizes[perm[i]];
    end
    else
    begin
      SecOff[i] := base + offs[i];
      SecSize[i] := sizes[i];
    end;
  FrameSize := base + sum;
end;

// ---------------------------------------------------------------------------
// Modular frame data (dec_modular.cc)
// ---------------------------------------------------------------------------
procedure MakeModImage(var img: TModImage; n, bitDepth: Integer);
begin
  SetLength(img.Channels, n);
  img.NumChannels := n;
  img.NumMetaChannels := 0;
  img.BitDepth := bitDepth;
end;

procedure TFrameDec.ModularGlobal(br: TBitReader);
var
  nbChans, c, ec, ecups, ww, hh, sh: Integer;
  maxTree: Int64;
  isGray, hasTree: Boolean;
begin
  DoColor := H.IsModular;
  isGray := md.ColorEncoding.ColorSpace = jcsGray;
  nbChans := 3;
  if isGray and (H.ColorTransform = CT_NONE) then nbChans := 1;
  hasTree := br.ReadBit;
  if hasTree then
  begin
    ReadMATree(br, Tree);
    maxTree := Min(Int64(1) shl 22, 1024 + Int64(FD.XSize) * FD.YSize * (nbChans + NumEC) div 16);
    if Length(Tree) > maxTree then raise EJxlError.Create('Modular: tree too large');
    TreeAns := TANSDecoder.Create;
    TreeAns.InitCode(br, (Length(Tree) + 1) div 2);
  end;
  if not DoColor then nbChans := 0;
  if (md.BitsPerSample >= 32) and DoColor and (H.ColorTransform <> CT_XYB) then
  begin
    if (md.BitsPerSample = 32) and not md.FloatSamples then
      raise EJxlError.Create('uint32_t not supported in dec_modular')
    else if md.BitsPerSample > 32 then
      raise EJxlError.Create('bits_per_sample > 32 not supported');
  end;
  MakeModImage(Full, nbChans + NumEC, md.BitsPerSample);
  for c := 0 to nbChans - 1 do
  begin
    if H.ColorTransform = CT_YCBCR then
    begin
      ww := DivCeil(FD.XSize, 1 shl HS[c]);
      hh := DivCeil(FD.YSize, 1 shl VS[c]);
      InitModChannel(Full.Channels[c], ww, hh, HS[c], VS[c]);
    end
    else
      InitModChannel(Full.Channels[c], FD.XSize, FD.YSize, 0, 0);
  end;
  for ec := 0 to NumEC - 1 do
  begin
    c := nbChans + ec;
    ecups := H.ECUpsampling[ec];
    sh := CeilLog2Nonzero(ecups) - CeilLog2Nonzero(H.Upsampling);
    InitModChannel(Full.Channels[c], DivCeil(FD.XSizeUpsampled, ecups),
                   DivCeil(FD.YSizeUpsampled, ecups), sh, sh);
  end;
  ModularGenericDecompress(br, Full, Tree, TreeAns, 0, False, FD.GroupDim, GlobalHdr);
end;

procedure TFrameDec.ModularGroup(x0, y0, xs, ys: Integer; br: TBitReader;
                                 minShift, maxShift, streamId: Integer);
var
  gi: TModImage;
  c, beginc, shift, n, rx, ry, rw, rh, y, gic: Integer;
  hdr: TModGroupHeader;
  map: array of Integer;
begin
  c := Full.NumMetaChannels;
  while c < Full.NumChannels do
  begin
    if (Full.Channels[c].Width > FD.GroupDim) or (Full.Channels[c].Height > FD.GroupDim) then Break;
    Inc(c);
  end;
  beginc := c;
  MakeModImage(gi, 0, Full.BitDepth);
  SetLength(map, 0);
  for c := beginc to Full.NumChannels - 1 do
  begin
    shift := Min(Full.Channels[c].HShift, Full.Channels[c].VShift);
    if (shift > maxShift) or (shift < minShift) then Continue;
    rx := x0 shr Full.Channels[c].HShift;
    ry := y0 shr Full.Channels[c].VShift;
    rw := xs shr Full.Channels[c].HShift;
    rh := ys shr Full.Channels[c].VShift;
    if rx >= Full.Channels[c].Width then rw := 0 else rw := Min(rw, Full.Channels[c].Width - rx);
    if ry >= Full.Channels[c].Height then rh := 0 else rh := Min(rh, Full.Channels[c].Height - ry);
    if (rw = 0) or (rh = 0) then Continue;
    n := gi.NumChannels;
    SetLength(gi.Channels, n + 1);
    InitModChannel(gi.Channels[n], rw, rh, Full.Channels[c].HShift, Full.Channels[c].VShift);
    gi.NumChannels := n + 1;
    SetLength(map, n + 1);
    map[n] := c;
  end;
  if gi.NumChannels = 0 then Exit;
  ModularGenericDecompress(br, gi, Tree, TreeAns, streamId, True, MaxInt, hdr);
  for gic := 0 to gi.NumChannels - 1 do
  begin
    c := map[gic];
    rx := x0 shr Full.Channels[c].HShift;
    ry := y0 shr Full.Channels[c].VShift;
    for y := 0 to gi.Channels[gic].Height - 1 do
      Move(gi.Channels[gic].Data[y * gi.Channels[gic].Width],
           Full.Channels[c].Data[(ry + y) * Full.Channels[c].Width + rx],
           gi.Channels[gic].Width * SizeOf(Int32));
  end;
end;

// Passes::GetDownsamplingBracket
procedure TFrameDec.ModularGroupPass(g, pass: Integer; br: TBitReader);
var
  minShift, maxShift, i, j, gx, gy: Integer;
begin
  maxShift := 2;
  minShift := 3;
  i := 0;
  while True do
  begin
    for j := 0 to H.NumDownsample - 1 do
      if i = H.LastPass[j] then
        case H.Downsample[j] of
          8: minShift := 3;
          4: minShift := 2;
          2: minShift := 1;
          1: minShift := 0;
        end;
    if i = H.NumPasses - 1 then minShift := 0;
    if i = pass then Break;
    maxShift := minShift - 1;
    Inc(i);
  end;
  gx := g mod FD.XSizeGroups; gy := g div FD.XSizeGroups;
  ModularGroup(gx * FD.GroupDim, gy * FD.GroupDim, FD.GroupDim, FD.GroupDim, br,
               minShift, maxShift,
               1 + 3 * FD.NumDCGroups + kNumQuantTables + FD.NumGroups * pass + g);
end;

procedure IntToFloatRow(src: PInt32; dst: PSingle; n, bits, expBits: Integer);
var
  x, expBias, signShift, mantBits, mantShift, e, mant, signbit: Integer;
  f: Cardinal;
begin
  if bits = 32 then
  begin
    Move(src^, dst^, n * 4);
    Exit;
  end;
  expBias := (1 shl (expBits - 1)) - 1;
  signShift := bits - 1;
  mantBits := bits - expBits - 1;
  mantShift := 23 - mantBits;
  for x := 0 to n - 1 do
  begin
    f := Cardinal(src[x]);
    signbit := (f shr signShift) and 1;
    f := f and ((Cardinal(1) shl signShift) - 1);
    if f = 0 then
    begin
      if signbit <> 0 then dst[x] := -0.0 else dst[x] := 0;
      Continue;
    end;
    e := f shr mantBits;
    mant := f and ((1 shl mantBits) - 1);
    mant := mant shl mantShift;
    if (e = 0) and (expBits < 8) then
    begin
      while (mant and $800000) = 0 do
      begin
        mant := mant shl 1;
        Dec(e);
      end;
      Inc(e);
      mant := mant and $7FFFFF;
    end;
    e := e - expBias + 127;
    if e < 0 then e := 0;
    f := (Cardinal(signbit) shl 31) or (Cardinal(e) shl 23) or Cardinal(mant);
    dst[x] := PSingle(@f)^;
  end;
end;

procedure TFrameDec.ModularFinalize;
var
  c, cIn, ec, y, x, ww, hh, bits, expBits: Integer;
  factor: Double;
  rgbFromGray, fp: Boolean;
  src, srcY: PInt32;
  dst: PSingle;
begin
  UndoModularTransforms(Full, GlobalHdr);
  SetLength(GlobalHdr.Transforms, 0);
  c := 0;
  if DoColor then
  begin
    rgbFromGray := (md.ColorEncoding.ColorSpace = jcsGray) and (H.ColorTransform = CT_NONE);
    fp := md.FloatSamples and (H.ColorTransform <> CT_XYB);
    while c < 3 do
    begin
      if Full.BitDepth < 32 then factor := 1.0 / ((Int64(1) shl Full.BitDepth) - 1)
      else factor := 0;
      cIn := c;
      if H.ColorTransform = CT_XYB then
      begin
        factor := Matrices.DCQuant[c];
        if c < 2 then cIn := 1 - c;
      end
      else if rgbFromGray then
        cIn := 0;
      ww := Full.Channels[cIn].Width;
      hh := Full.Channels[cIn].Height;
      if (ww = 0) or (hh = 0) then raise EJxlError.Create('Empty image');
      InitFloat32Plane(Planes[c], ww, hh);
      for y := 0 to hh - 1 do
      begin
        src := @Full.Channels[cIn].Data[y * ww];
        dst := @Planes[c].Data[y * ww];
        if (H.ColorTransform = CT_XYB) and (c = 2) then
        begin
          srcY := @Full.Channels[0].Data[y * Full.Channels[0].Width];
          for x := 0 to ww - 1 do dst[x] := (Int64(src[x]) + srcY[x]) * factor;
        end
        else if fp then
          IntToFloatRow(src, dst, ww, md.BitsPerSample, md.ExponentBits)
        else
          for x := 0 to ww - 1 do dst[x] := src[x] * factor;
      end;
      if rgbFromGray then
      begin
        Planes[1] := CopyPlane(Planes[0]);
        Planes[2] := CopyPlane(Planes[0]);
        Break;
      end;
      Inc(c);
    end;
    if rgbFromGray then c := 1 else c := 3;
  end;
  for ec := 0 to NumEC - 1 do
  begin
    bits := md.ExtraChannels[ec].BitsPerSample;
    expBits := md.ExtraChannels[ec].ExponentBits;
    fp := expBits > 0;
    ww := Full.Channels[c].Width;
    hh := Full.Channels[c].Height;
    InitFloat32Plane(Planes[3 + ec], ww, hh);
    if not fp then factor := 1.0 / ((Int64(1) shl bits) - 1) else factor := 0;
    for y := 0 to hh - 1 do
    begin
      src := @Full.Channels[c].Data[y * ww];
      dst := @Planes[3 + ec].Data[y * ww];
      if fp then IntToFloatRow(src, dst, ww, bits, expBits)
      else for x := 0 to ww - 1 do dst[x] := src[x] * factor;
    end;
    Inc(c);
  end;
end;

procedure TFrameDec.ReadRawQuantTable(br: TBitReader; idx, sizeX, sizeY: Integer;
                                      var table: array of Integer);
var
  img: TModImage;
  c, x, y: Integer;
  hdr: TModGroupHeader;
begin
  MakeModImage(img, 3, 8);
  for c := 0 to 2 do InitModChannel(img.Channels[c], sizeX, sizeY, 0, 0);
  ModularGenericDecompress(br, img, Tree, TreeAns, 1 + 3 * FD.NumDCGroups + idx,
                           True, MaxInt, hdr);
  for c := 0 to 2 do
    for y := 0 to sizeY - 1 do
      for x := 0 to sizeX - 1 do
        table[c * sizeX * sizeY + y * sizeX + x] := img.Channels[c].Data[y * sizeX + x];
end;

// ---------------------------------------------------------------------------
// VarDCT global side information
// ---------------------------------------------------------------------------
procedure TFrameDec.DecodeQuantizer(br: TBitReader);
var c: Integer;
begin
  GlobalScale := Integer(br.ReadU32(1, 11, 2049, 11, 4097, 12, 8193, 16));
  QuantDC := Integer(br.ReadU32(16, 0, 1, 5, 1, 8, 1, 16));
  QuantScale := GlobalScale * (1.0 / 65536);
  InvGlobalScale := 65536.0 / GlobalScale;
  for c := 0 to 2 do
    MulDC[c] := (InvGlobalScale / QuantDC) * Matrices.DCQuant[c];
end;

procedure TFrameDec.DecodeBlockCtxMap(br: TBitReader);
var
  j, i, nh, n: Integer;
  ans: TANSDecoder;
  cm: TBytes;
begin
  if br.ReadBit then
  begin
    for j := 0 to 2 do SetLength(BCtx.DcThresholds[j], 0);
    SetLength(BCtx.QfThresholds, 0);
    SetLength(BCtx.CtxMap, Length(kDefaultCtxMap));
    for i := 0 to High(kDefaultCtxMap) do BCtx.CtxMap[i] := kDefaultCtxMap[i];
    BCtx.NumCtxs := 15;
    BCtx.NumDcCtxs := 1;
    Exit;
  end;
  BCtx.NumDcCtxs := 1;
  for j := 0 to 2 do
  begin
    SetLength(BCtx.DcThresholds[j], br.ReadBits(4));
    BCtx.NumDcCtxs := BCtx.NumDcCtxs * (Length(BCtx.DcThresholds[j]) + 1);
    for i := 0 to High(BCtx.DcThresholds[j]) do
      BCtx.DcThresholds[j][i] := Integer(UnpackSignedI(
        br.ReadU32(0, 4, 16, 8, 272, 16, 65808, 32)));
  end;
  SetLength(BCtx.QfThresholds, br.ReadBits(4));
  for i := 0 to High(BCtx.QfThresholds) do
    BCtx.QfThresholds[i] := br.ReadU32(0, 2, 4, 3, 12, 5, 44, 8) + 1;
  if BCtx.NumDcCtxs * (Length(BCtx.QfThresholds) + 1) > 64 then
    raise EJxlError.Create('Invalid block context map: too big');
  n := 3 * kNumOrders * BCtx.NumDcCtxs * (Length(BCtx.QfThresholds) + 1);
  ans := TANSDecoder.Create;
  try
    cm := ans.DecodeStandaloneContextMap(br, n, nh);
  finally
    ans.Free;
  end;
  SetLength(BCtx.CtxMap, n);
  for i := 0 to n - 1 do BCtx.CtxMap[i] := cm[i];
  BCtx.NumCtxs := nh;
  if BCtx.NumCtxs > 16 then
    raise EJxlError.Create('Invalid block context map: too many distinct contexts');
end;

function TFrameDec.BlockContext(dcIdx: Integer; qf: Cardinal; ord, c: Integer): Integer;
var
  qfIdx, i, idx: Integer;
begin
  qfIdx := 0;
  for i := 0 to High(BCtx.QfThresholds) do
    if qf > BCtx.QfThresholds[i] then Inc(qfIdx);
  if c < 2 then idx := c xor 1 else idx := 2;
  idx := idx * kNumOrders + ord;
  idx := idx * (Length(BCtx.QfThresholds) + 1) + qfIdx;
  idx := idx * BCtx.NumDcCtxs + dcIdx;
  Result := BCtx.CtxMap[idx];
end;

procedure TFrameDec.DecodeCmapDC(br: TBitReader);
begin
  ColorFactor := kDefaultColorFactor;
  // ColorCorrelationMap::Create is called with its default XYB = true on
  // decode, so the default B correlation is kYToBRatio for every image.
  BaseCorrX := 0;
  BaseCorrB := 1.0;
  YtoXDC := 0; YtoBDC := 0;
  if not br.ReadBit then
  begin
    ColorFactor := Integer(br.ReadU32(84, 0, 256, 0, 2, 8, 258, 16));
    BaseCorrX := br.ReadF16;
    if Abs(BaseCorrX) > 4 then raise EJxlError.Create('Base X correlation is out of range');
    BaseCorrB := br.ReadF16;
    if Abs(BaseCorrB) > 4 then raise EJxlError.Create('Base B correlation is out of range');
    YtoXDC := Integer(br.ReadBits(8)) - 128;
    YtoBDC := Integer(br.ReadBits(8)) - 128;
  end;
  DCFactors[0] := BaseCorrX + YtoXDC * (1.0 / ColorFactor);
  DCFactors[1] := 0;
  DCFactors[2] := BaseCorrB + YtoBDC * (1.0 / ColorFactor);
end;

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------
procedure TFrameDec.ProcessDCGlobal(br: TBitReader);
var
  i, bw, bh, c: Integer;
begin
  if (H.Flags and kFlagPatches) <> 0 then
  begin
    DecodePatches(br, Patches, FD.XSizePadded, FD.YSizePadded, NumEC, st.Refs);
    if H.Upsampling <> 1 then
      for i := 0 to NumEC - 1 do
        if H.ECUpsampling[i] <> H.Upsampling then
          raise EJxlError.Create('Cannot use extra channels in patches with different upsampling');
  end;
  if (H.Flags and kFlagSplines) <> 0 then
    raise EJxlError.Create('JPEG XL splines are not supported');
  if (H.Flags and kFlagNoise) <> 0 then
    DecodeNoise(br, Noise);
  Matrices.DecodeDC(br);

  if not H.IsModular then
  begin
    DecodeQuantizer(br);
    DecodeBlockCtxMap(br);
    DecodeCmapDC(br);
    bw := FD.XSizeBlocks; bh := FD.YSizeBlocks;
    SetLength(Acs, bw * bh);
    for i := 0 to High(Acs) do Acs[i] := -1;
    SetLength(AcsFirst, bw * bh);
    SetLength(QF, bw * bh);
    SetLength(Sharp, bw * bh);
    SetLength(Sigma, bw * bh);
    SetLength(QDC, bw * bh);
    CmapW := DivCeil(bw, 8); CmapH := DivCeil(bh, 8);
    SetLength(YtoX, CmapW * CmapH);
    SetLength(YtoB, CmapW * CmapH);
    UseDcFrame := (H.Flags and kFlagUseDcFrame) <> 0;
    if UseDcFrame then
    begin
      if H.DcLevel = 4 then raise EJxlError.Create('Invalid DC level for kUseDcFrame');
      if Length(st.DcFrames[H.DcLevel]) < 3 then
        raise EJxlError.Create('kUseDcFrame without a decoded DC frame');
      for c := 0 to 2 do
      begin
        DC[c] := CopyPlane(st.DcFrames[H.DcLevel][c]);
        CropPlane(DC[c], Max(DC[c].Width, bw), Max(DC[c].Height, bh));
      end;
    end
    else
      for c := 0 to 2 do InitFloat32Plane(DC[c], bw, bh);
  end;
  ModularGlobal(br);
end;

procedure TFrameDec.DecodeVarDCTDC(g: Integer; br: TBitReader);
var
  gx, gy, x0, y0, xs, ys, c, ch, x, y, extraPrec: Integer;
  img: TModImage;
  hdr: TModGroupHeader;
  mul, facX, facY, facB, yv: Single;
  qx, qy, qb: PInt32;
  bx, by, bb, t, bucketX, bucketY, bucketB: Integer;
  rw, rh: Integer;
begin
  gx := g mod FD.XSizeDCGroups; gy := g div FD.XSizeDCGroups;
  x0 := gx * FD.GroupDim; y0 := gy * FD.GroupDim;
  xs := Min(FD.GroupDim, FD.XSizeBlocks - x0);
  ys := Min(FD.GroupDim, FD.YSizeBlocks - y0);
  extraPrec := br.ReadBits(2);
  mul := 1.0 / (1 shl extraPrec);
  MakeModImage(img, 3, Full.BitDepth);
  for c := 0 to 2 do
  begin
    if c < 2 then ch := c xor 1 else ch := c;
    InitModChannel(img.Channels[ch], xs shr HS[c], ys shr VS[c], 0, 0);
  end;
  ModularGenericDecompress(br, img, Tree, TreeAns, 1 + g, True, MaxInt, hdr);
  // DequantDC
  if (MaxHS = 0) and (MaxVS = 0) then
  begin
    facX := MulDC[0] * mul; facY := MulDC[1] * mul; facB := MulDC[2] * mul;
    for y := 0 to ys - 1 do
    begin
      qx := @img.Channels[1].Data[y * xs];
      qy := @img.Channels[0].Data[y * xs];
      qb := @img.Channels[2].Data[y * xs];
      for x := 0 to xs - 1 do
      begin
        yv := qy[x] * facY;
        DC[1].Data[(y0 + y) * DC[1].Stride + x0 + x] := yv;
        DC[0].Data[(y0 + y) * DC[0].Stride + x0 + x] := yv * DCFactors[0] + qx[x] * facX;
        DC[2].Data[(y0 + y) * DC[2].Stride + x0 + x] := yv * DCFactors[2] + qb[x] * facB;
      end;
    end;
  end
  else
    for c := 0 to 2 do
    begin
      if c < 2 then ch := c xor 1 else ch := c;
      facX := MulDC[c] * mul;
      rw := xs shr HS[c]; rh := ys shr VS[c];
      for y := 0 to rh - 1 do
        for x := 0 to rw - 1 do
          DC[c].Data[((y0 shr VS[c]) + y) * DC[c].Stride + (x0 shr HS[c]) + x] :=
            img.Channels[ch].Data[y * img.Channels[ch].Width + x] * facX;
    end;
  // quant_dc buckets
  for y := 0 to ys - 1 do
    for x := 0 to xs - 1 do
    begin
      if BCtx.NumDcCtxs <= 1 then
        bb := 0
      else
      begin
        bucketX := 0; bucketY := 0; bucketB := 0;
        by := y shr VS[0]; bx := x shr HS[0];
        for t := 0 to High(BCtx.DcThresholds[0]) do
          if img.Channels[1].Data[by * img.Channels[1].Width + bx] > BCtx.DcThresholds[0][t] then Inc(bucketX);
        by := y shr VS[1]; bx := x shr HS[1];
        for t := 0 to High(BCtx.DcThresholds[1]) do
          if img.Channels[0].Data[by * img.Channels[0].Width + bx] > BCtx.DcThresholds[1][t] then Inc(bucketY);
        by := y shr VS[2]; bx := x shr HS[2];
        for t := 0 to High(BCtx.DcThresholds[2]) do
          if img.Channels[2].Data[by * img.Channels[2].Width + bx] > BCtx.DcThresholds[2][t] then Inc(bucketB);
        bb := bucketX;
        bb := bb * (Length(BCtx.DcThresholds[2]) + 1) + bucketB;
        bb := bb * (Length(BCtx.DcThresholds[1]) + 1) + bucketY;
      end;
      QDC[(y0 + y) * FD.XSizeBlocks + x0 + x] := bb;
    end;
end;

procedure TFrameDec.ComputeSigma(bx0, by0, bxs, bys: Integer);
var
  bx, by, ix, iy, s, bw: Integer;
  sigmaQuant, sg: Single;
begin
  bw := FD.XSizeBlocks;
  for by := by0 to by0 + bys - 1 do
    for bx := bx0 to bx0 + bxs - 1 do
    begin
      if not AcsFirst[by * bw + bx] then Continue;
      s := Acs[by * bw + bx];
      sigmaQuant := H.LF.EpfQuantMul / (QuantScale * QF[by * bw + bx] * kInvSigmaNum);
      for iy := 0 to kAcsCoveredY[s] - 1 do
        for ix := 0 to kAcsCoveredX[s] - 1 do
        begin
          sg := sigmaQuant * H.LF.EpfSharpLut[Sharp[(by + iy) * bw + bx + ix]];
          if sg > -1e-4 then sg := -1e-4;
          Sigma[(by + iy) * bw + bx + ix] := 1.0 / sg;
        end;
    end;
end;

procedure TFrameDec.DecodeAcMetadata(g: Integer; br: TBitReader);
var
  gx, gy, x0, y0, xs, ys, count, cx0, cy0, cxs, cys, x, y, num, s, v: Integer;
  img: TModImage;
  hdr: TModGroupHeader;
  bw, xlim, ylim, nx, ny: Integer;
  is444: Boolean;
begin
  gx := g mod FD.XSizeDCGroups; gy := g div FD.XSizeDCGroups;
  x0 := gx * FD.GroupDim; y0 := gy * FD.GroupDim;
  xs := Min(FD.GroupDim, FD.XSizeBlocks - x0);
  ys := Min(FD.GroupDim, FD.YSizeBlocks - y0);
  count := Integer(br.ReadBits(CeilLog2Nonzero(xs * ys))) + 1;
  cx0 := x0 shr 3; cy0 := y0 shr 3;
  cxs := (xs + 7) shr 3; cys := (ys + 7) shr 3;
  MakeModImage(img, 4, Full.BitDepth);
  InitModChannel(img.Channels[0], cxs, cys, 3, 3);
  InitModChannel(img.Channels[1], cxs, cys, 3, 3);
  InitModChannel(img.Channels[2], count, 2, 0, 0);
  InitModChannel(img.Channels[3], xs, ys, 0, 0);
  ModularGenericDecompress(br, img, Tree, TreeAns, 1 + 2 * FD.NumDCGroups + g,
                           True, MaxInt, hdr);
  for y := 0 to cys - 1 do
    for x := 0 to cxs - 1 do
    begin
      if (cy0 + y >= CmapH) or (cx0 + x >= CmapW) then Continue;
      v := img.Channels[0].Data[y * cxs + x];
      YtoX[(cy0 + y) * CmapW + cx0 + x] := Max(-128, Min(127, v));
      v := img.Channels[1].Data[y * cxs + x];
      YtoB[(cy0 + y) * CmapW + cx0 + x] := Max(-128, Min(127, v));
    end;
  bw := FD.XSizeBlocks;
  xlim := Min(bw, x0 + xs);
  ylim := Min(FD.YSizeBlocks, y0 + ys);
  is444 := (MaxHS = 0) and (MaxVS = 0);
  num := 0;
  for y := 0 to ys - 1 do
    for x := 0 to xs - 1 do
    begin
      v := img.Channels[3].Data[y * xs + x];
      if (v < 0) or (v >= 8) then raise EJxlError.Create('Corrupted sharpness field');
      Sharp[(y0 + y) * bw + x0 + x] := v;
      if Acs[(y0 + y) * bw + x0 + x] >= 0 then Continue;
      if num >= count then raise EJxlError.Create('Corrupted stream');
      s := img.Channels[2].Data[num];
      if (s < 0) or (s >= kNumAcStrategies) then raise EJxlError.Create('Invalid AC strategy');
      UsedAcs := UsedAcs or (Cardinal(1) shl s);
      if ((kAcsCoveredX[s] > 1) or (kAcsCoveredY[s] > 1)) and not is444 then
        raise EJxlError.Create('AC strategy not compatible with chroma subsampling');
      if (x0 + x + kAcsCoveredX[s] > ((x0 + x) div 32 + 1) * 32) or
         (x0 + x + kAcsCoveredX[s] > xlim) then
        raise EJxlError.Create('Invalid AC strategy, x overflow');
      if (y0 + y + kAcsCoveredY[s] > ((y0 + y) div 32 + 1) * 32) or
         (y0 + y + kAcsCoveredY[s] > ylim) then
        raise EJxlError.Create('Invalid AC strategy, y overflow');
      for ny := 0 to kAcsCoveredY[s] - 1 do
        for nx := 0 to kAcsCoveredX[s] - 1 do
        begin
          if Acs[(y0 + y + ny) * bw + x0 + x + nx] >= 0 then
            raise EJxlError.Create('Invalid AC strategy: overlapping blocks');
          Acs[(y0 + y + ny) * bw + x0 + x + nx] := s;
        end;
      AcsFirst[(y0 + y) * bw + x0 + x] := True;
      v := img.Channels[2].Data[count + num];
      QF[(y0 + y) * bw + x0 + x] := 1 + Max(0, Min(kQuantMax - 1, v));
      Inc(num);
    end;
  if H.LF.EpfIters > 0 then ComputeSigma(x0, y0, xs, ys);
end;

procedure TFrameDec.ProcessDCGroup(g: Integer; br: TBitReader);
var
  gx, gy: Integer;
begin
  gx := g mod FD.XSizeDCGroups; gy := g div FD.XSizeDCGroups;
  if (not H.IsModular) and not UseDcFrame then
    DecodeVarDCTDC(g, br);
  ModularGroup(gx * FD.DCGroupDim, gy * FD.DCGroupDim, FD.DCGroupDim, FD.DCGroupDim,
               br, 3, 1000, 1 + FD.NumDCGroups + g);
  if not H.IsModular then
    DecodeAcMetadata(g, br);
end;

// compressed_dc.cc AdaptiveDCSmoothing
procedure TFrameDec.FinalizeDC;
const
  w1 = 0.20345139757231578;
  w2 = 0.0334829185968739;
  w0 = 1.0 - 4.0 * (w1 + w2);
var
  xs, ys, x, y, c: Integer;
  src: array[0..2] of array of Single;
  mc, sm: array[0..2] of Single;
  gap, factor: Single;

  function P(cc, yy, xx: Integer): Single; inline;
  begin
    Result := src[cc][yy * xs + xx];
  end;

begin
  if H.IsModular or ((H.Flags and kFlagSkipAdaptiveDCSmoothing) <> 0) or UseDcFrame then Exit;
  xs := FD.XSizeBlocks; ys := FD.YSizeBlocks;
  if (ys <= 2) or (xs <= 2) then Exit;
  for c := 0 to 2 do
  begin
    SetLength(src[c], xs * ys);
    Move(DC[c].Data[0], src[c][0], xs * ys * SizeOf(Single));
  end;
  for y := 1 to ys - 2 do
    for x := 1 to xs - 2 do
    begin
      gap := 0.5;
      for c := 0 to 2 do
      begin
        mc[c] := P(c, y, x);
        sm[c] := (P(c, y - 1, x - 1) + P(c, y - 1, x + 1) + P(c, y + 1, x - 1) + P(c, y + 1, x + 1)) * w2 +
                 ((P(c, y, x - 1) + P(c, y, x + 1) + P(c, y - 1, x) + P(c, y + 1, x)) * w1 + mc[c] * w0);
        gap := Max(gap, Abs((mc[c] - sm[c]) / MulDC[c]));
      end;
      factor := Max(0.0, 3.0 - 4.0 * gap);
      for c := 0 to 2 do
        DC[c].Data[y * xs + x] := (sm[c] - mc[c]) * factor + mc[c];
    end;
end;

procedure TFrameDec.DecodeCoeffOrders(usedOrders: Cardinal; var order: array of Cardinal;
                                      br: TBitReader);
var
  computed, acsMask: Cardinal;
  o, ord, c, llf, sz, k: Integer;
  used: Boolean;
  ans: TANSDecoder;
  natural, tmp: array of Cardinal;
begin
  computed := 0;
  ans := nil;
  try
    if usedOrders <> 0 then
    begin
      ans := TANSDecoder.Create;
      ans.Init(br, kPermutationContexts);
    end;
    acsMask := 0;
    for o := 0 to kNumAcStrategies - 1 do
      if (UsedAcs and (Cardinal(1) shl o)) <> 0 then
        acsMask := acsMask or (Cardinal(1) shl kStrategyOrder[o]);
    for o := 0 to kNumAcStrategies - 1 do
    begin
      ord := kStrategyOrder[o];
      if (computed and (Cardinal(1) shl ord)) <> 0 then Continue;
      computed := computed or (Cardinal(1) shl ord);
      used := (acsMask and (Cardinal(1) shl ord)) <> 0;
      llf := kAcsCoveredX[o] * kAcsCoveredY[o];
      sz := 64 * llf;
      if used or ((usedOrders and (Cardinal(1) shl ord)) <> 0) then
      begin
        SetLength(natural, sz);
        ComputeNaturalCoeffOrder(o, @natural[0]);
      end;
      if (usedOrders and (Cardinal(1) shl ord)) = 0 then
      begin
        if used then
          for c := 0 to 2 do
            Move(natural[0], order[kCoeffOrderOffset[3 * ord + c] * 64], sz * SizeOf(Cardinal));
      end
      else
      begin
        SetLength(tmp, sz);
        for c := 0 to 2 do
          if used then
          begin
            ReadPermutation(br, ans, llf, sz, @tmp[0]);
            for k := 0 to sz - 1 do
              order[kCoeffOrderOffset[3 * ord + c] * 64 + k] := natural[tmp[k]];
          end
          else
            ReadPermutation(br, ans, llf, sz, nil);
      end;
    end;
    if (usedOrders <> 0) and not ans.CheckFinalState then
      raise EJxlError.Create('Coefficient orders: invalid ANS stream');
  finally
    ans.Free;
  end;
end;

procedure TFrameDec.ProcessACGlobal(br: TBitReader);
var
  p, numCtx, c: Integer;
  usedOrders: Cardinal;
begin
  if H.IsModular then Exit;
  Matrices.Decode(br, ReadRawQuantTable);
  Matrices.EnsureComputed(UsedAcs);
  NumHistograms := 1 + Integer(br.ReadBits(CeilLog2Nonzero(FD.NumGroups)));
  SetLength(CoeffOrders, H.NumPasses);
  SetLength(AcAns, H.NumPasses);
  for p := 0 to H.NumPasses - 1 do
  begin
    SetLength(CoeffOrders[p], kCoeffOrderLimit * 64);
    usedOrders := br.ReadU32($5F, 0, $13, 0, 0, 0, 0, kNumOrders);
    DecodeCoeffOrders(usedOrders, CoeffOrders[p], br);
    numCtx := NumHistograms * BCtx.NumCtxs * (kNonZeroBuckets + kZeroDensityContextCount);
    AcAns[p] := TANSDecoder.Create;
    AcAns[p].InitCode(br, numCtx);
    AcAns[p].ExtendContextMap(numCtx + kZeroDensityContextLimit - kZeroDensityContextCount);
  end;
  XDmMul := Power(1 / 1.25, H.XQMScale - 2.0);
  BDmMul := Power(1 / 1.25, H.BQMScale - 2.0);
  for c := 0 to 2 do
    InitFloat32Plane(Pix[c], FD.XSizePadded shr HS[c], FD.YSizePadded shr VS[c]);
end;

function PredictFromTopAndLeft(top, row: PInt32; x: Integer; def: Integer): Integer; inline;
begin
  if x = 0 then
  begin
    if top = nil then Result := def else Result := top[x];
    Exit;
  end;
  if top = nil then Exit(row[x - 1]);
  Result := (top[x] + row[x - 1] + 1) div 2;
end;

// dec_group.cc: DecodeGroupImpl with all passes at once
procedure TFrameDec.ProcessACGroup(g: Integer; const brs: array of TBitReader);
const
  cOrder: array[0..2] of Integer = (1, 0, 2);
var
  gx, gy, bx0, by0, bxs, bys, p, c, ci, bx, by, sbx, sby, s, ord, blockCtx,
    predicted, nzCtx, histoOffset, k, covered, log2cov, size, x, y, bw,
    tx, ty, prev, i, pixX, pixY, hsel, qdcIdx, qfv: Integer;
  nzeros: Int64;
  u, magnitude: Cardinal;
  coeff: Int64;
  ctxOffset: array[0..MAX_NUM_PASSES - 1] of Integer;
  numNz: array of array[0..2] of array of Int32;   // [pass][c] 32x32
  top, row: PInt32;
  qblock: array[0..2] of array of Int32;
  block: array of Single;
  order: PCardinal;
  xcc, bcc, sdq, sdqx, sdqb: Single;
  mat: PSingle;
  xm, ym, bm, dx, dy, db: Single;
  biasArr: array[0..3] of Single;
  dcp: PSingle;

  function AdjustQuantBias(cc: Integer; qv: Int32): Single; inline;
  var fq: Single;
  begin
    fq := qv;
    if Abs(fq) < 1.125 then
    begin
      if qv = 0 then Result := 0
      else if qv > 0 then Result := biasArr[cc]
      else Result := -biasArr[cc];
    end
    else
      Result := fq - biasArr[3] / fq;
  end;

begin
  gx := g mod FD.XSizeGroups; gy := g div FD.XSizeGroups;
  bw := FD.XSizeBlocks;
  bx0 := gx * (FD.GroupDim shr 3); by0 := gy * (FD.GroupDim shr 3);
  bxs := Min(FD.GroupDim shr 3, FD.XSizeBlocks - bx0);
  bys := Min(FD.GroupDim shr 3, FD.YSizeBlocks - by0);
  if (bxs <= 0) or (bys <= 0) then Exit;
  hsel := CeilLog2Nonzero(NumHistograms);
  for p := 0 to H.NumPasses - 1 do
  begin
    k := 0;
    if hsel <> 0 then k := brs[p].ReadBits(hsel);
    if k >= NumHistograms then raise EJxlError.Create('Invalid histogram selector');
    ctxOffset[p] := k * BCtx.NumCtxs * (kNonZeroBuckets + kZeroDensityContextCount);
    AcAns[p].BeginReader(brs[p], 0);
  end;
  SetLength(numNz, H.NumPasses);
  for p := 0 to H.NumPasses - 1 do
    for c := 0 to 2 do
      SetLength(numNz[p][c], 32 * 32);
  for c := 0 to 2 do SetLength(qblock[c], 256 * 256);
  SetLength(block, 3 * 256 * 256);
  for i := 0 to 3 do biasArr[i] := md.QuantBias[i];

  for by := 0 to bys - 1 do
  begin
    ty := (by0 + by) div kColorTileDimInBlocks;
    bx := 0;
    while bx < bxs do
    begin
      i := (by0 + by) * bw + bx0 + bx;
      s := Acs[i];
      if s < 0 then raise EJxlError.Create('VarDCT: missing AC strategy');
      if not AcsFirst[i] then
      begin
        Inc(bx, kAcsCoveredX[s]);
        Continue;
      end;
      tx := (bx0 + bx) div kColorTileDimInBlocks;
      xcc := BaseCorrX + YtoX[ty * CmapW + tx] * (1.0 / ColorFactor);
      bcc := BaseCorrB + YtoB[ty * CmapW + tx] * (1.0 / ColorFactor);
      log2cov := kAcsLog2Covered[s];
      covered := 1 shl log2cov;
      size := covered * 64;
      ord := kStrategyOrder[s];
      for c := 0 to 2 do FillChar(qblock[c][0], size * SizeOf(Int32), 0);
      qdcIdx := QDC[(by0 + by) * bw + bx0 + bx];
      // LoadBlock
      for ci := 0 to 2 do
      begin
        c := cOrder[ci];
        sbx := bx shr HS[c]; sby := by shr VS[c];
        if ((sbx shl HS[c]) <> bx) or ((sby shl VS[c]) <> by) then Continue;
        qfv := QF[(by0 + by) * bw + bx0 + sbx];
        blockCtx := BlockContext(qdcIdx, Cardinal(qfv), ord, c);
        for p := 0 to H.NumPasses - 1 do
        begin
          row := @numNz[p][c][sby * 32];
          if sby = 0 then top := nil else top := @numNz[p][c][(sby - 1) * 32];
          predicted := PredictFromTopAndLeft(top, row, sbx, 32);
          order := @CoeffOrders[p][kCoeffOrderOffset[3 * ord + c] * 64];
          if predicted >= 64 then predicted := 64;
          if predicted < 8 then nzCtx := predicted else nzCtx := 4 + predicted div 2;
          nzCtx := nzCtx * BCtx.NumCtxs + blockCtx + ctxOffset[p];
          nzeros := AcAns[p].Decode(nzCtx, brs[p]);
          if nzeros > size - covered then
            raise EJxlError.Create('Invalid AC: nzeros too large');
          for y := 0 to kAcsCoveredY[s] - 1 do
            for x := 0 to kAcsCoveredX[s] - 1 do
              if (sby + y < 32) and (sbx + x < 32) then
                numNz[p][c][(sby + y) * 32 + sbx + x] :=
                  (nzeros + covered - 1) shr log2cov;
          histoOffset := ctxOffset[p] + BCtx.NumCtxs * kNonZeroBuckets +
                         kZeroDensityContextCount * blockCtx;
          if nzeros > size div 16 then prev := 0 else prev := 1;
          k := covered;
          while (k < size) and (nzeros <> 0) do
          begin
            u := AcAns[p].Decode(histoOffset +
                   (kCoeffNumNonzeroContext[(nzeros + covered - 1) shr log2cov] +
                    kCoeffFreqContext[k shr log2cov]) * 2 + prev, brs[p]);
            magnitude := u shr 1;
            if (u and 1) <> 0 then coeff := -Int64(magnitude) - 1
            else coeff := magnitude;
            coeff := coeff * (Int64(1) shl H.Shift[p]);
            qblock[c][order[k]] := qblock[c][order[k]] + coeff;
            if u <> 0 then prev := 1 else prev := 0;
            Dec(nzeros, prev);
            Inc(k);
          end;
          if nzeros <> 0 then
            raise EJxlError.Create('Invalid AC: nzeros at end of block');
        end;
      end;
      // dequantize
      sdq := InvGlobalScale / QF[(by0 + by) * bw + bx0 + bx];
      sdqx := sdq * XDmMul;
      sdqb := sdq * BDmMul;
      mat := Matrices.Matrix(s);
      for k := 0 to size - 1 do
      begin
        xm := mat[k] * sdqx;
        ym := mat[size + k] * sdq;
        bm := mat[2 * size + k] * sdqb;
        dx := AdjustQuantBias(0, qblock[0][k]) * xm;
        dy := AdjustQuantBias(1, qblock[1][k]) * ym;
        db := AdjustQuantBias(2, qblock[2][k]) * bm;
        block[k] := xcc * dy + dx;
        block[size + k] := dy;
        block[2 * size + k] := bcc * dy + db;
      end;
      for c := 0 to 2 do
      begin
        sbx := bx shr HS[c]; sby := by shr VS[c];
        dcp := @DC[c].Data[((by0 shr VS[c]) + sby) * DC[c].Stride + (bx0 shr HS[c]) + sbx];
        LowestFrequenciesFromDC(s, dcp, DC[c].Stride, @block[c * size]);
      end;
      for ci := 0 to 2 do
      begin
        c := cOrder[ci];
        sbx := bx shr HS[c]; sby := by shr VS[c];
        if ((sbx shl HS[c]) <> bx) or ((sby shl VS[c]) <> by) then Continue;
        pixX := ((bx0 shr HS[c]) + sbx) * 8;
        pixY := ((by0 shr VS[c]) + sby) * 8;
        TransformToPixels(s, @block[c * size],
                          @Pix[c].Data[pixY * Pix[c].Stride + pixX], Pix[c].Stride);
      end;
      Inc(bx, kAcsCoveredX[s]);
    end;
  end;
  for p := 0 to H.NumPasses - 1 do
    if not AcAns[p].CheckFinalState then
      raise EJxlError.Create('VarDCT: ANS checksum failure');
end;

// ---------------------------------------------------------------------------
// Rendering (dec_cache.cc PreparePipeline order)
// ---------------------------------------------------------------------------
procedure TFrameDec.RenderFrame;
var
  c, ec, shift, bw: Integer;
  p3: TPlanes3;
  lateEC: Boolean;
  noisePl: array[0..2] of TFloat32Plane;
  ecInfo: TBlendChannelInfos;
begin
  // VarDCT colour planes come from the IDCT (padded); crop to the frame
  if not H.IsModular then
    for c := 0 to 2 do
    begin
      Planes[c] := Pix[c];
      CropPlane(Planes[c], DivCeil(FD.XSize, 1 shl HS[c]), DivCeil(FD.YSize, 1 shl VS[c]));
    end;

  // chroma upsampling
  for c := 0 to 2 do
  begin
    if HS[c] <> 0 then ChromaUpsampleH(Planes[c], FD.XSize);
    if VS[c] <> 0 then ChromaUpsampleV(Planes[c], FD.YSize);
  end;

  for c := 0 to 2 do p3[c] := Planes[c];
  if H.Gab then Gaborish(p3, H.LF);
  if H.LF.EpfIters > 0 then
  begin
    bw := FD.XSizeBlocks;
    if H.IsModular then
    begin
      bw := DivCeil(FD.XSize, 8);
      SetLength(Sigma, bw * DivCeil(FD.YSize, 8));
      for c := 0 to High(Sigma) do Sigma[c] := kInvSigmaNum / H.LF.EpfSigmaForModular;
    end;
    if H.LF.EpfIters >= 3 then EPFStage(0, p3, Sigma, bw, H.LF);
    if H.LF.EpfIters >= 1 then EPFStage(1, p3, Sigma, bw, H.LF);
    if H.LF.EpfIters >= 2 then EPFStage(2, p3, Sigma, bw, H.LF);
  end;
  for c := 0 to 2 do Planes[c] := p3[c];

  lateEC := H.Upsampling <> 1;
  for ec := 0 to NumEC - 1 do
    if H.ECUpsampling[ec] <> H.Upsampling then lateEC := False;
  if not lateEC then
    for ec := 0 to NumEC - 1 do
      if H.ECUpsampling[ec] <> 1 then
        Upsample(Planes[3 + ec], CeilLog2Nonzero(H.ECUpsampling[ec]), md,
                 FD.XSizeUpsampled, FD.YSizeUpsampled);

  SetLength(ecInfo, NumEC);
  for ec := 0 to NumEC - 1 do
  begin
    ecInfo[ec].IsAlpha := md.ExtraChannels[ec].ChanType = jectAlpha;
    ecInfo[ec].AlphaAssociated := md.ExtraChannels[ec].AlphaAssoc;
  end;
  if (H.Flags and kFlagPatches) <> 0 then
    ApplyPatches(Patches, Planes, st.Refs, ecInfo);

  if H.Upsampling <> 1 then
  begin
    shift := CeilLog2Nonzero(H.Upsampling);
    for c := 0 to 2 do
      Upsample(Planes[c], shift, md, FD.XSizeUpsampled, FD.YSizeUpsampled);
    if lateEC then
      for ec := 0 to NumEC - 1 do
        Upsample(Planes[3 + ec], shift, md, FD.XSizeUpsampled, FD.YSizeUpsampled);
  end;

  if ((H.Flags and kFlagNoise) <> 0) and NoiseHasAny(Noise) then
  begin
    GenerateNoisePlanes(noisePl, FD.XSizeUpsampled, FD.YSizeUpsampled, FD.GroupDim,
                        H.Upsampling, FD.XSizeGroups, FD.YSizeGroups,
                        st.VisibleIdx, st.NonvisibleIdx);
    ConvolveNoise(noisePl);
    AddNoise(Planes, noisePl, Noise, BaseCorrX, BaseCorrB);
  end;
end;

// Stores planes (copied) as a reference frame.
procedure StoreRef(var r: TJxlRefFrame; const pl: TPlaneArray; inXYB: Boolean);
var i: Integer;
begin
  r.Valid := True;
  SetLength(r.Planes, Length(pl));
  for i := 0 to High(pl) do r.Planes[i] := CopyPlane(pl[i]);
  r.XSize := pl[0].Width;
  r.YSize := pl[0].Height;
  r.IbIsInXYB := inXYB;
end;

procedure TFrameDec.Compose(out displayed: Boolean; var output: TPlaneArray);
var
  canBeRef, needsBlending: Boolean;
  c, ec, imgW, imgH, x0, y0, x1, y1, y, n, src: Integer;
  p3: TPlanes3;
  canvas: TPlaneArray;
  bg, fg: array of PSingle;
  cb: TPatchBlending;
  ecb: array of TPatchBlending;
  ecInfo: TBlendChannelInfos;

  function ToPatch(const bi: TBlendingInfo): TPatchBlending;
  begin
    Result.AlphaChannel := bi.AlphaChannel;
    Result.Clamp := bi.Clamp;
    case bi.Mode of
      BM_ADD: Result.Mode := PBM_ADD;
      BM_MUL: Result.Mode := PBM_MUL;
      BM_BLEND: Result.Mode := PBM_BLEND_ABOVE;
      BM_AWADD: Result.Mode := PBM_AWADD_ABOVE;
    else Result.Mode := PBM_REPLACE;
    end;
  end;

begin
  displayed := False;
  canBeRef := (not H.IsLast) and (H.FrameType <> FT_DC) and
              ((H.Duration = 0) or (H.SaveAsReference <> 0));

  if H.DcLevel <> 0 then
  begin
    SetLength(st.DcFrames[H.DcLevel - 1], 3);
    for c := 0 to 2 do st.DcFrames[H.DcLevel - 1][c] := CopyPlane(Planes[c]);
    Exit;
  end;

  if canBeRef and H.SaveBeforeCT then
    StoreRef(st.Refs[H.SaveAsReference], Planes, True);

  // colour transform
  for c := 0 to 2 do p3[c] := Planes[c];
  if H.ColorTransform = CT_YCBCR then
    YCbCrToRGB(p3)
  else if H.ColorTransform = CT_XYB then
    XYBToSRGB(p3, md);
  for c := 0 to 2 do Planes[c] := p3[c];

  needsBlending := (H.FrameType = FT_REGULAR) or (H.FrameType = FT_SKIPPROG);
  if needsBlending then
  begin
    needsBlending := H.CustomSizeOrOrigin or (H.Blending.Mode <> BM_REPLACE);
    for ec := 0 to NumEC - 1 do
      if H.ECBlending[ec].Mode <> BM_REPLACE then needsBlending := True;
  end;

  if needsBlending then
  begin
    imgW := md.XSize; imgH := md.YSize;
    n := 3 + NumEC;
    SetLength(canvas, n);
    for c := 0 to n - 1 do
    begin
      if c < 3 then src := H.Blending.Source else src := H.ECBlending[c - 3].Source;
      if st.Refs[src].Valid and (st.Refs[src].XSize > 0) then
      begin
        if st.Refs[src].IbIsInXYB then
          raise EJxlError.Create('Trying to blend XYB reference frame and non-XYB frame');
        if (st.Refs[src].XSize < imgW) or (st.Refs[src].YSize < imgH) then
          raise EJxlError.Create('Trying to use a crop as a background');
        canvas[c] := CopyPlane(st.Refs[src].Planes[c]);
        CropPlane(canvas[c], imgW, imgH);
      end
      else
        InitFloat32Plane(canvas[c], imgW, imgH);
    end;
    cb := ToPatch(H.Blending);
    SetLength(ecb, NumEC);
    for ec := 0 to NumEC - 1 do ecb[ec] := ToPatch(H.ECBlending[ec]);
    SetLength(ecInfo, NumEC);
    for ec := 0 to NumEC - 1 do
    begin
      ecInfo[ec].IsAlpha := md.ExtraChannels[ec].ChanType = jectAlpha;
      ecInfo[ec].AlphaAssociated := md.ExtraChannels[ec].AlphaAssoc;
    end;
    x0 := Max(0, H.X0); y0 := Max(0, H.Y0);
    x1 := Min(imgW, H.X0 + Planes[0].Width);
    y1 := Min(imgH, H.Y0 + Planes[0].Height);
    SetLength(bg, n); SetLength(fg, n);
    if (x1 > x0) and (y1 > y0) then
      for y := y0 to y1 - 1 do
      begin
        for c := 0 to n - 1 do
        begin
          bg[c] := @canvas[c].Data[y * canvas[c].Stride + x0];
          fg[c] := @Planes[c].Data[(y - H.Y0) * Planes[c].Stride + (x0 - H.X0)];
        end;
        PerformBlending(bg, fg, bg, x1 - x0, cb, ecb, ecInfo);
      end;
    Planes := canvas;
  end;

  if canBeRef and not H.SaveBeforeCT then
    StoreRef(st.Refs[H.SaveAsReference], Planes, False);

  if (not H.IsPreview) and ((H.FrameType = FT_REGULAR) or (H.FrameType = FT_SKIPPROG)) and
     (H.IsLast or (H.Duration > 0)) then
  begin
    displayed := True;
    output := Planes;
  end;
end;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
function DecodeJxlFrame(st: TJxlDecodeState; data: PByte; size: NativeUInt;
                        pos: NativeUInt; isPreview, skip: Boolean;
                        out hdr: TFrameHeader; out displayed: Boolean;
                        var output: TPlaneArray): NativeUInt;
var
  fr: TFrameDec;
  br: TBitReader;
  readers: array of TBitReader;
  i, g, p: Integer;
  brs: array of TBitReader;
begin
  displayed := False;
  fr := TFrameDec.Create(st);
  br := TBitReader.Create(data + pos, size - pos);
  try
    fr.H.IsPreview := isPreview;
    fr.ReadHeader(br);
    fr.ComputeDims;
    fr.ReadTOC(br);
    hdr := fr.H;
    Result := pos + fr.FrameSize;
    if Result > size then raise EJxlError.Create('Truncated JPEG XL frame');

    if (not isPreview) and (fr.H.IsLast or (fr.H.Duration > 0)) and
       ((fr.H.FrameType = FT_REGULAR) or (fr.H.FrameType = FT_SKIPPROG)) then
    begin
      Inc(st.VisibleIdx);
      st.NonvisibleIdx := 0;
    end
    else
      Inc(st.NonvisibleIdx);

    if skip then Exit;

    if ((fr.MaxHS <> 0) or (fr.MaxVS <> 0)) and (not fr.H.IsModular) and
       ((fr.H.Flags and kFlagSkipAdaptiveDCSmoothing) = 0) then
      raise EJxlError.Create('Non-444 chroma subsampling requires skipping adaptive DC smoothing');

    fr.Data := data + pos;
    SetLength(fr.Planes, 3 + fr.NumEC);
    SetLength(readers, Length(fr.SecOff));
    for i := 0 to High(readers) do readers[i] := nil;
    try
      if fr.SingleSection then
      begin
        readers[0] := fr.SectionReader(0);
        fr.ProcessDCGlobal(readers[0]);
        fr.ProcessDCGroup(0, readers[0]);
        fr.FinalizeDC;
        fr.ProcessACGlobal(readers[0]);
        if not fr.H.IsModular then fr.ProcessACGroup(0, [readers[0]]);
        fr.ModularGroupPass(0, 0, readers[0]);
      end
      else
      begin
        for i := 0 to High(readers) do readers[i] := fr.SectionReader(i);
        fr.ProcessDCGlobal(readers[0]);
        for g := 0 to fr.FD.NumDCGroups - 1 do
          fr.ProcessDCGroup(g, readers[1 + g]);
        fr.FinalizeDC;
        fr.ProcessACGlobal(readers[1 + fr.FD.NumDCGroups]);
        SetLength(brs, fr.H.NumPasses);
        for g := 0 to fr.FD.NumGroups - 1 do
        begin
          for p := 0 to fr.H.NumPasses - 1 do
            brs[p] := readers[2 + fr.FD.NumDCGroups + p * fr.FD.NumGroups + g];
          if not fr.H.IsModular then fr.ProcessACGroup(g, brs);
          for p := 0 to fr.H.NumPasses - 1 do
            fr.ModularGroupPass(g, p, brs[p]);
        end;
      end;
    finally
      for i := 0 to High(readers) do readers[i].Free;
    end;
    fr.ModularFinalize;
    fr.RenderFrame;
    fr.Compose(displayed, output);
  finally
    br.Free;
    fr.Free;
  end;
end;

end.
