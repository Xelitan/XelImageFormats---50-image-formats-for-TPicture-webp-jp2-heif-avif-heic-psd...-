unit Av1.Decoder;

// AV1 decoder: still images (AVIF items) and full video sequences (AVIF image
// sequences / animations). Implements the complete decoding process for 8, 10
// and 12-bit 4:0:0 / 4:2:0 / 4:2:2 / 4:4:4 streams: key, intra-only, inter and
// switch frames, hidden frames and show_existing_frame, reference management,
// CDF propagation, segmentation, delta q / lf, all intra tools (directional,
// smooth, paeth, CFL, palette, filter-intra, intra block copy), all inter tools
// (single / compound prediction, NEWMV/NEARMV/GLOBALMV, temporal MVs, OBMC,
// local and global warp, wedge / difference-weighted / distance-weighted
// compound, inter-intra), variable transform partitioning, and the in-loop
// filters (deblocking, CDEF, loop restoration).
//
// Not supported (an EAv1 is raised): super-resolution, reference frames of a
// different size (scaled motion compensation), quantizer matrices. Film grain
// is parsed but not synthesised (output is the clean decoded frame).
//
// Structure mirrors dav1d (BSD-2-Clause), which this is ported from, so that
// the bitstream semantics are bit-exact.

{$mode delphi}{$H+}
{$RANGECHECKS OFF}{$OVERFLOWCHECKS OFF}{$POINTERMATH ON}{$T+}

interface

uses
  SysUtils, Classes, Av1.Bits, Av1.Obu, Av1.Headers, Av1.Tables, Av1.Cdf, Av1.Msac,
  Av1.Recon, Av1.Itx, Av1.Ipred, Av1.LoopFilter, Av1.Mc, Av1.Refmvs, Av1.MsacEnc;

type
  // Decoded picture, cropped to the frame size. Samples at native bit depth.
  TAv1Frame = record
    Width, Height, SsH, SsV, ChromaW, ChromaH, NumPlanes, BitDepth: Integer;
    Y, U, V: array of Word;   // Y stride = Width, chroma stride = ChromaW
  end;

  TAv1Picture = record
    Y, U, V: array of Word;
    StrideY, StrideC: Integer;
    W, H: Integer;            // coded (visible) luma size
    Hdr: TFrameHdr;
  end;

  TRefSlot = record
    Valid: Boolean;
    Pic: TAv1Picture;
    Cdf: TCdfContext;
    SegMap: TBytes;
    Mvs: TTemporalArr;
    RefPoc: array[0..6] of Integer;
  end;

  TCtxArrays = record
    mode, lcoef, ccoef0, ccoef1, segpred, skip, skipmode, intra, comptype,
    filter0, filter1, txlpfy, txlpfuv, partition, uvmode, palsz, palszuv: array of Byte;
    ref0, ref1, txintra, tx: array of ShortInt;
    pal: array of array[0..2, 0..7] of Word;
  end;

  TBlk = record
    bl, bs, bp: Integer;
    intra, segId, skipMode, skip: Integer;
    uvtx, ymode, uvmode, tx: Integer;
    palSz: array[0..1] of Integer;
    yAngle, uvAngle: Integer;
    cflAlpha: array[0..1] of Integer;
    mv: array[0..1] of TMv;
    wedgeIdx, maskSign, interintraMode, interintraType: Integer;
    ref: array[0..1] of Integer;
    compType, interMode, motionMode, drlIdx, filter2d: Integer;
    maxYtx, txSplit0, txSplit1: Integer;
  end;

  TLrUnit = record
    typ, sgrIdx: Integer;          // typ: 0 none, 1 wiener, 2 sgrproj
    fv, fh: array[0..2] of Integer;
    sw: array[0..1] of Integer;
  end;

  TDqTable = array[0..7, 0..2, 0..1] of Integer;
  TLfLvlTable = array[0..7, 0..3, 0..7, 0..1] of Byte;

  TTileState = record
    Msac: TMsac;
    Cdf: TCdfContext;
    LastQidx: Integer;
    LastDeltaLf: array[0..3] of Integer;
    Dq: TDqTable;
    LfLvl: TLfLvlTable;
    LrRef: array[0..2] of TLrUnit;
    ColStart, ColEnd, RowStart, RowEnd: Integer;   // in 4x4 units
    TileRow, TileCol: Integer;
  end;

  TAv1Decoder = class
  private
    Seq: TSeqHdr;
    SeqValid: Boolean;
    Fh: TFrameHdr;
    Slots: array[0..7] of TRefSlot;
    Refp: array[0..6] of Integer;   // slot index per ref (refidx)

    // current frame
    Yp, Up, Vp: array of Word;
    StrideY, StrideC: Integer;
    FrmW, FrmH: Integer;            // coded luma size
    w4, h4, bw, bh, sb128w, sb128h, sbShift, sbStep, sbh, b4Stride: Integer;
    ssH, ssV, Layout, Bd, PixMax, NumPlanes: Integer;
    InCdf, OutCdf, UpdCdf: TCdfContext;
    UpdCdfSet: Boolean;
    FrameDq: TDqTable;
    FrameLfLvl: TLfLvlTable;
    JntWeights: array[0..6, 0..6] of Integer;
    GmvWarpAllowed: array[0..6] of Boolean;
    CurSegMap, PrevSegMap: TBytes;
    HavePrevSegMap: Boolean;
    CurMvs: TTemporalArr;
    RefPoc: array[0..6] of Integer;
    RefRefPoc: array[0..48] of Integer;
    RF: TRefmvsFrame;
    Tiles: array of TTileState;
    TS: ^TTileState;                // current tile
    A, L: TCtxArrays;
    // loop filter data
    LvlY, LvlC: array of Byte;      // [b4 * 2 + dir]
    EdgeVY, EdgeHY, EdgeVC, EdgeHC: array of Byte;   // 0 = none, else 1 + size class
    CdefIdx: array of ShortInt;     // per 64x64
    NoskipMi: array of Byte;
    N64w, N64h: Integer;
    LrGrid: array[0..2] of array of TLrUnit;
    LrUnitsW, LrUnitsH, LrUnitLog2: array[0..2] of Integer;
    // block scratch
    by, bx: Integer;                // current block position (4x4 units)
    B: TBlk;
    Cf: array[0..64*64-1] of Integer;
    TxtpMap: array[0..32*32-1] of Byte;
    TlFilter: Integer;              // filter2d of the top-left 4x4 (sub8x8 chroma)
    WarpMv: TWarpParams;
    Pal: array[0..2, 0..7] of Word;
    PalIdxY, PalIdxC: array[0..64*64-1] of Byte;
    EmuBuf: array of Word;
    Lap: array[0..128*64-1] of Word;
    CompTmp: array[0..1, 0..128*128-1] of SmallInt;
    SegMask: array[0..128*128-1] of Byte;
    IITmp: array[0..64*64-1] of Word;
    EdgeBuf: array[0..520] of Integer;

    // output
    FOutput: TAv1Frame;
    FHasOutput: Boolean;

    procedure ResetSlots;
    procedure ShowExisting(Idx: Integer);
    procedure DecodeFrame(TileData: PByte; TileSize: NativeInt; NTileGroups: Integer;
      const TgPtr: array of PByte; const TgSize: array of NativeInt;
      const TgStart, TgEnd: array of Integer);
    procedure SetupFrame;
    procedure InitQuantTables(QIdx: Integer; var Dq: TDqTable);
    procedure CalcLfValues(var Lv: TLfLvlTable; const Delta: array of Integer);
    procedure ResetCtx(var C: TCtxArrays; From, Count: Integer; KeyFrame: Boolean; IsLeft: Boolean);
    procedure DecodeTileSbrow(TileIdx, SbyAbs: Integer);
    function DecodeSb(Bl, Node: Integer): Boolean;
    procedure DecodeBlock(Bl, Bs, Bp, EdgeFlags: Integer);
    procedure ReadRestorationInfo(P, FrameType, Ux, Uy: Integer);
    procedure ReadLrSb;
    // block helpers
    procedure ReadMvResidual(var Mv: TMv; MvPrec: Integer; Intrabc: Boolean);
    procedure ReadTxTree(From, Depth: Integer; var Masks: array of Integer; XOff, YOff: Integer);
    procedure ReadVartxTree(Bs: Integer);
    procedure FindMatchingRef(EdgeFlags, Bw4, Bh4, W4, H4: Integer; HaveLeft, HaveTop: Boolean;
      Ref: Integer; var Masks: array of UInt64);
    procedure DeriveWarpMv(Bw4, Bh4: Integer; const Masks: array of UInt64; const Mv: TMv);
    procedure ReadPalPlane(Pl, SzCtx, Bx4, By4: Integer);
    procedure ReadPalUv(SzCtx, Bx4, By4: Integer);
    procedure ReadPalIndices(PalIdx: PByte; PalSz, Pl, W4, H4, Bw4, Bh4: Integer);
    // reconstruction
    procedure ReconIntra(Bs, EdgeFlags: Integer);
    procedure ReconInter(Bs: Integer);
    function PrepareIntraEdges(X: Integer; HaveLeft: Boolean; Y: Integer; HaveTop: Boolean;
      W, H, EdgeFlags: Integer; Dst: PWord; Stride, Mode: Integer; var Angle: Integer;
      Tw, Th: Integer; FilterEdge: Boolean): Integer;
    procedure IntraPred(Mode: Integer; Dst: PWord; Stride, Tw, Th, Angle, MaxW, MaxH: Integer);
    procedure ReadCoefTree(Bs, Ytx, Depth: Integer; const TxSplit: array of Integer;
      XOff, YOff: Integer; Dst: PWord);
    procedure Mc(Dst: PWord; Dst16: PSmallInt; DstStride, Bw4, Bh4, Bxx, Byy, Pl: Integer;
      const Mv: TMv; RefIdx, Filter2d: Integer; Intrabc: Boolean);
    procedure Obmc(Dst: PWord; DstStride, Pl, W4, H4: Integer);
    procedure WarpAffine(Dst: PWord; Dst16: PSmallInt; DStride, Bs, Pl, RefIdx: Integer;
      const Wmp: TWarpParams);
    function RefPlane(RefIdx, Pl: Integer; Intrabc: Boolean; out Stride, W, H: Integer): PWord;
    function DqFor(Pl, Which: Integer): Integer;
    // loop filter masks + filters
    procedure MaskEdgesIntra(Bs, Ytx, Uvtx: Integer; HasChroma: Boolean);
    procedure MaskEdgesInter(Bs, MaxYtx, Uvtx: Integer; const TxSplit: array of Integer;
      HasChroma: Boolean);
    procedure FillLevels(const Lv: TLfLvlTable; SegId, RefIdx, ModeIdx: Integer; HasChroma: Boolean);
    procedure DeblockFrame;
    procedure CdefFrame;
    procedure LrFrame;
    procedure LrPlane(p: Integer; dstP, cdef, db: PWord; stride, w, h, bufH: Integer);
  public
    // Test aids: OutputHidden also outputs frames with show_frame = 0;
    // CollectAll appends every output to Collected.
    OutputHidden: Boolean;
    CollectAll: Boolean;
    Collected: array of TAv1Frame;
    constructor Create;
    // Decode one temporal unit (concatenated OBUs). Returns True if a frame is
    // to be shown; Frame then receives it.
    function DecodeTemporalUnit(Data: PByte; Size: NativeInt; out Frame: TAv1Frame): Boolean;
    // Install a sequence header (e.g. from av1C configOBUs) before decoding.
    procedure SetConfigObus(Data: PByte; Size: NativeInt);
  end;

  // Encoder settings. Input planes are 8-bit; Layout is LAYOUT_I400,
  // LAYOUT_I420 or LAYOUT_I444. QIdx is the AV1 base_q_idx (1..255; lower is
  // better quality).
  TAv1EncConfig = record
    Width, Height: Integer;
    Layout: Integer;
    QIdx: Integer;
    FullRange: Boolean;
    ColorPrimaries, TransferCharacteristics, MatrixCoefficients: Integer;
    KeyFrameInterval: Integer;   // 0 = only the first frame is a key frame
  end;

  TAv1Encoder = class(TAv1Decoder)
  private
    Cfg: TAv1EncConfig;
    SeqPayload: TBytes;
    FrameCount: Integer;
    IsKey: Boolean;
    E: TMsacEnc;
    SrcP: array[0..2] of array of Byte;   // source planes padded to the coded size
    SrcStride: array[0..2] of Integer;
    TxScale: array[0..4] of Double;
    DctT: array[0..4] of array of Double;
    LvlBuf: array of Integer;
    LvlCount: Integer;
    SplitThr: Double;
    FLevelIdx: Integer;
    Lambda: Integer;                      // SAD units per estimated bit
    FStack: TMvStack;                     // MV candidates of the current block
    FNMvs, FMvCtx: Integer;
    CandMode, CandDrl: Integer;           // inter choice from MotionSearch
    CandMv: TMv;
    McTmp: array[0..64 * 64 - 1] of Word;
    procedure Calibrate;
    function BuildSeqHdr: TBytes;
    function BuildFrameHdr: TBytes;
    function LoopFilterLevel: Integer;
    procedure LoadSource(const Y, U, V: array of Byte);
    function Sad(Pl, X, Y, W, H: Integer): Int64;
    function RefSadInt(Bw4, Bh4, Dx, Dy: Integer): Int64;
    function McSad(Bw4, Bh4: Integer; const Mv: TMv): Int64;
    function MotionSearch(Bs, EdgeFlags: Integer): Int64;
    procedure EncodeMvComp(var C: TCdfMvComponent; D: Integer);
    procedure EncodeInterMode;
    procedure PredictLuma(Bs, Mode, EdgeFlags: Integer);
    function QuantTx(Pl, Tx, Px, Py: Integer; Dst: PWord; Stride: Integer; Intra: Boolean): Integer;
    function WalkTx(Pass, Bs, EdgeFlags: Integer; HasChroma: Boolean): Boolean;
    procedure EncodeBlock(Bl, Bs, Bp, EdgeFlags: Integer; UseInter: Boolean; YMode: Integer);
    function ChooseMode(Bs, EdgeFlags: Integer; out UseInter: Boolean; out YMode: Integer): Int64;
    procedure EncodeSb(Bl, Node: Integer);
  public
    constructor Create(const AConfig: TAv1EncConfig);
    // The sequence header OBU (for the av1C configOBUs).
    function SequenceHeaderObu: TBytes;
    // seq_level_idx[0] written in the sequence header (for av1C).
    property SeqLevelIdx: Integer read FLevelIdx;
    // Encodes one frame. Y is Width*Height bytes, U/V are the chroma planes
    // (ignored for 4:0:0). Returns the temporal unit: sequence header (key
    // frames) followed by an OBU_FRAME.
    function EncodeFrame(const Y, U, V: array of Byte; ForceKey: Boolean;
      out IsKeyFrame: Boolean): TBytes;
  end;

// Decode a still image: concatenated OBUs (sequence header + frame).
function Av1Decode(Data: PByte; Size: NativeInt; out F: TAv1Frame): Boolean;

implementation

const
  AV1_LOSSLESS_DUMMY = 0;

{$I Av1.Dq8.inc}
{$I Av1.DqHi.inc}
{$I FilterIntraTaps.inc}

function IMin(a, b: Integer): Integer; inline; begin if a < b then Result := a else Result := b; end;
function IMax(a, b: Integer): Integer; inline; begin if a > b then Result := a else Result := b; end;
function IClip(v, lo, hi: Integer): Integer; inline;
begin if v < lo then Result := lo else if v > hi then Result := hi else Result := v; end;
function ApplySign(v, s: Integer): Integer; inline;
begin if s < 0 then Result := -v else Result := v; end;

function IsInterOrSwitch(const F: TFrameHdr): Boolean; inline;
begin Result := (F.FrameType and 1) <> 0; end;
function IsKeyOrIntra(const F: TFrameHdr): Boolean; inline;
begin Result := (F.FrameType and 1) = 0; end;

procedure SetBytes(var Arr: array of Byte; From, Count: Integer; V: Byte); inline;
begin if Count > 0 then FillChar(Arr[From], Count, V); end;
procedure SetShorts(var Arr: array of ShortInt; From, Count: Integer; V: ShortInt); inline;
begin if Count > 0 then FillChar(Arr[From], Count, Byte(V)); end;

{$I Av1.DecBlock.inc}
{$I Av1.DecRecon.inc}
{$I Av1.DecFilter.inc}

// ======================================================================
// Frame level
// ======================================================================

constructor TAv1Decoder.Create;
begin
  inherited Create;
  BuildEdgeTree;
  ResetSlots;
end;

procedure TAv1Decoder.ResetSlots;
var i: Integer;
begin
  for i := 0 to 7 do
  begin
    Slots[i].Valid := False;
    Slots[i].Pic.Y := nil; Slots[i].Pic.U := nil; Slots[i].Pic.V := nil;
    Slots[i].SegMap := nil;
    Slots[i].Mvs := nil;
  end;
end;

procedure TAv1Decoder.SetConfigObus(Data: PByte; Size: NativeInt);
var Obus: TObuArray; i: Integer;
begin
  if (Data = nil) or (Size <= 0) then Exit;
  Obus := SplitObus(Data, Size);
  for i := 0 to High(Obus) do
    if Obus[i].ObuType = OBU_SEQUENCE_HEADER then
    begin
      ParseSeqHdr(Obus[i].Payload, Obus[i].PayloadSize, Seq);
      SeqValid := True;
    end;
end;

procedure CopyPlanesOut(const P: TAv1Picture; const S: TSeqHdr; out F: TAv1Frame);
var y, cw, ch, ssh, ssv: Integer;
begin
  F.Width := P.W; F.Height := P.H; F.BitDepth := S.BitDepth;
  if S.Layout = LAYOUT_I400 then F.NumPlanes := 1 else F.NumPlanes := 3;
  ssh := S.SsHor; ssv := S.SsVer;
  if S.Layout = LAYOUT_I400 then begin ssh := 1; ssv := 1; end;
  F.SsH := ssh; F.SsV := ssv;
  SetLength(F.Y, P.W * P.H);
  for y := 0 to P.H - 1 do Move(P.Y[y * P.StrideY], F.Y[y * P.W], P.W * 2);
  if F.NumPlanes = 3 then
  begin
    cw := (P.W + ssh) shr ssh; ch := (P.H + ssv) shr ssv;
    F.ChromaW := cw; F.ChromaH := ch;
    SetLength(F.U, cw * ch); SetLength(F.V, cw * ch);
    for y := 0 to ch - 1 do
    begin
      Move(P.U[y * P.StrideC], F.U[y * cw], cw * 2);
      Move(P.V[y * P.StrideC], F.V[y * cw], cw * 2);
    end;
  end
  else
  begin
    F.ChromaW := 0; F.ChromaH := 0;
    F.U := nil; F.V := nil;
  end;
end;

procedure TAv1Decoder.ShowExisting(Idx: Integer);
var i: Integer;
begin
  if not Slots[Idx].Valid then raise EAv1.Create('AV1: show_existing_frame of empty slot');
  CopyPlanesOut(Slots[Idx].Pic, Seq, FOutput);
  FHasOutput := True;
  if CollectAll then
  begin
    SetLength(Collected, Length(Collected) + 1);
    Collected[High(Collected)] := FOutput;
  end;
  if Slots[Idx].Pic.Hdr.FrameType = KEY_FRAME then
    for i := 0 to 7 do
      if i <> Idx then
      begin
        Slots[i].Valid := True;
        Slots[i].Pic := Slots[Idx].Pic;
        Slots[i].Cdf := Slots[Idx].Cdf;
        Slots[i].SegMap := Slots[Idx].SegMap;
        Slots[i].Mvs := nil;
        Slots[i].RefPoc := Slots[Idx].RefPoc;
      end;
end;

function TAv1Decoder.DecodeTemporalUnit(Data: PByte; Size: NativeInt; out Frame: TAv1Frame): Boolean;
var
  Obus: TObuArray;
  i, nTiles, numTiles, tgStart, tgEnd, tileBits, nTg: Integer;
  hdrBits: Int64;
  haveHdr: Boolean;
  refs: TRefHdrs;
  B: TAv1Bits;
  tgPtr: array of PByte;
  tgSize: array of NativeInt;
  tgS, tgE: array of Integer;
  p: PByte; sz: NativeInt; hb: NativeInt;

  procedure FillRefs;
  var k: Integer;
  begin
    for k := 0 to 7 do
      if Slots[k].Valid then refs[k] := @Slots[k].Pic.Hdr else refs[k] := nil;
  end;

  procedure AddTileGroup(Ptr: PByte; Len: NativeInt);
  begin
    numTiles := Fh.Tiling.Cols * Fh.Tiling.Rows;
    B := TAv1Bits.Create(Ptr, Len);
    try
      tgStart := 0; tgEnd := numTiles - 1;
      if numTiles > 1 then
        if B.f(1) = 1 then
        begin
          tileBits := Fh.Tiling.Log2Cols + Fh.Tiling.Log2Rows;
          tgStart := B.f(tileBits);
          tgEnd := B.f(tileBits);
        end;
      B.ByteAlign;
      hb := B.BytePos;
    finally
      B.Free;
    end;
    SetLength(tgPtr, nTg + 1); SetLength(tgSize, nTg + 1);
    SetLength(tgS, nTg + 1); SetLength(tgE, nTg + 1);
    tgPtr[nTg] := Ptr + hb; tgSize[nTg] := Len - hb;
    tgS[nTg] := tgStart; tgE[nTg] := tgEnd;
    Inc(nTg);
    nTiles := tgEnd + 1;
    if nTiles >= numTiles then
    begin
      DecodeFrame(nil, 0, nTg, tgPtr, tgSize, tgS, tgE);
      haveHdr := False;
      nTg := 0;
    end;
  end;

begin
  Result := False;
  FHasOutput := False;
  Obus := SplitObus(Data, Size);
  haveHdr := False; nTg := 0;
  for i := 0 to High(Obus) do
    case Obus[i].ObuType of
      OBU_SEQUENCE_HEADER:
        begin
          ParseSeqHdr(Obus[i].Payload, Obus[i].PayloadSize, Seq);
          SeqValid := True;
        end;
      OBU_TEMPORAL_DELIMITER: haveHdr := False;
      OBU_FRAME_HEADER, OBU_FRAME:
        begin
          if not SeqValid then raise EAv1.Create('AV1: frame without sequence header');
          if haveHdr and (Obus[i].ObuType = OBU_FRAME_HEADER) then Continue;  // redundant copy
          FillRefs;
          ParseFrameHdr(Seq, refs, Obus[i].TemporalId, Obus[i].SpatialId,
            Obus[i].Payload, Obus[i].PayloadSize, Fh, hdrBits);
          if Fh.ShowExistingFrame then
          begin
            ShowExisting(Fh.ExistingFrameIdx);
            Continue;
          end;
          haveHdr := True; nTg := 0;
          if Obus[i].ObuType = OBU_FRAME then
          begin
            sz := (hdrBits + 7) shr 3;
            p := Obus[i].Payload + sz;
            AddTileGroup(p, Obus[i].PayloadSize - sz);
          end;
        end;
      OBU_TILE_GROUP:
        if haveHdr then AddTileGroup(Obus[i].Payload, Obus[i].PayloadSize);
    end;
  if FHasOutput then
  begin
    Frame := FOutput;
    Result := True;
  end;
end;

procedure TAv1Decoder.InitQuantTables(QIdx: Integer; var Dq: TDqTable);
var i, n, yac, ydc, uac, udc, vac, vdc: Integer;

  function DcQ(q: Integer): Integer;
  begin case Bd of 10: Result := Dq10Dc[q]; 12: Result := Dq12Dc[q]; else Result := Dq8Dc[q]; end; end;
  function AcQ(q: Integer): Integer;
  begin case Bd of 10: Result := Dq10Ac[q]; 12: Result := Dq12Ac[q]; else Result := Dq8Ac[q]; end; end;

begin
  if Fh.Segmentation.Enabled then n := 8 else n := 1;
  for i := 0 to n - 1 do
  begin
    if Fh.Segmentation.Enabled then yac := IClip(QIdx + Fh.Segmentation.SegData.D[i].DeltaQ, 0, 255)
    else yac := QIdx;
    ydc := IClip(yac + Fh.Quant.YdcDelta, 0, 255);
    uac := IClip(yac + Fh.Quant.UacDelta, 0, 255);
    udc := IClip(yac + Fh.Quant.UdcDelta, 0, 255);
    vac := IClip(yac + Fh.Quant.VacDelta, 0, 255);
    vdc := IClip(yac + Fh.Quant.VdcDelta, 0, 255);
    Dq[i][0][0] := DcQ(ydc); Dq[i][0][1] := AcQ(yac);
    Dq[i][1][0] := DcQ(udc); Dq[i][1][1] := AcQ(uac);
    Dq[i][2][0] := DcQ(vdc); Dq[i][2][1] := AcQ(vac);
  end;
end;

procedure TAv1Decoder.CalcLfValues(var Lv: TLfLvlTable; const Delta: array of Integer);
var s, nSeg, dm: Integer; useMr: Boolean;

  procedure CalcOne(var V: array of Byte {8*2}; BaseLvl, LfDelta, SegDelta: Integer; Chroma: Boolean);
  var base, sh, r, m, dlt: Integer;
  begin
    if Chroma and (BaseLvl = 0) then begin FillChar(V[0], 16, 0); Exit; end;
    base := IClip(IClip(BaseLvl + LfDelta, 0, 63) + SegDelta, 0, 63);
    if not useMr then begin FillChar(V[0], 16, base); Exit; end;
    sh := Ord(base >= 32);
    V[0] := IClip(base + Fh.LoopFilter.ModeRefDeltas.RefDelta[0] * (1 shl sh), 0, 63);
    V[1] := V[0];
    for r := 1 to 7 do
      for m := 0 to 1 do
      begin
        dlt := Fh.LoopFilter.ModeRefDeltas.ModeDelta[m] + Fh.LoopFilter.ModeRefDeltas.RefDelta[r];
        V[r * 2 + m] := IClip(base + dlt * (1 shl sh), 0, 63);
      end;
  end;

begin
  if Fh.Segmentation.Enabled then nSeg := 8 else nSeg := 1;
  if (Fh.LoopFilter.LevelY[0] = 0) and (Fh.LoopFilter.LevelY[1] = 0) then
  begin
    FillChar(Lv, SizeOf(Lv), 0);
    Exit;
  end;
  useMr := Fh.LoopFilter.ModeRefDeltaEnabled;
  if Fh.DeltaLfMulti then dm := 1 else dm := 0;
  for s := 0 to nSeg - 1 do
    with Fh.Segmentation.SegData.D[s] do
    begin
      if Fh.Segmentation.Enabled then
      begin
        CalcOne(Lv[s][0][0], Fh.LoopFilter.LevelY[0], Delta[0], DeltaLfYV, False);
        CalcOne(Lv[s][1][0], Fh.LoopFilter.LevelY[1], Delta[1 * dm], DeltaLfYH, False);
        CalcOne(Lv[s][2][0], Fh.LoopFilter.LevelU, Delta[2 * dm], DeltaLfU, True);
        CalcOne(Lv[s][3][0], Fh.LoopFilter.LevelV, Delta[3 * dm], DeltaLfV, True);
      end
      else
      begin
        CalcOne(Lv[s][0][0], Fh.LoopFilter.LevelY[0], Delta[0], 0, False);
        CalcOne(Lv[s][1][0], Fh.LoopFilter.LevelY[1], Delta[1 * dm], 0, False);
        CalcOne(Lv[s][2][0], Fh.LoopFilter.LevelU, Delta[2 * dm], 0, True);
        CalcOne(Lv[s][3][0], Fh.LoopFilter.LevelV, Delta[3 * dm], 0, True);
      end;
    end;
end;

procedure TAv1Decoder.ResetCtx(var C: TCtxArrays; From, Count: Integer; KeyFrame: Boolean; IsLeft: Boolean);
var cFrom, cCount: Integer;
begin
  // chroma-indexed arrays (uvmode, ccoef) use chroma 4x4 units
  if IsLeft then begin cFrom := From shr ssV; cCount := (Count + ssV) shr ssV; end
  else begin cFrom := From shr ssH; cCount := (Count + ssH) shr ssH; end;
  SetBytes(C.intra, From, Count, Ord(KeyFrame));
  SetBytes(C.uvmode, cFrom, cCount, DC_PRED);
  if KeyFrame then SetBytes(C.mode, From, Count, DC_PRED);
  SetBytes(C.partition, From shr 1, (Count + 1) shr 1, 0);
  SetBytes(C.skip, From, Count, 0);
  SetBytes(C.skipmode, From, Count, 0);
  SetShorts(C.txintra, From, Count, -1);
  SetShorts(C.tx, From, Count, TX_64X64);
  if not KeyFrame then
  begin
    SetShorts(C.ref0, From, Count, -1);
    SetShorts(C.ref1, From, Count, -1);
    SetBytes(C.comptype, From, Count, 0);
    SetBytes(C.mode, From, Count, NEARESTMV);
  end;
  SetBytes(C.lcoef, From, Count, $40);
  SetBytes(C.ccoef0, cFrom, cCount, $40);
  SetBytes(C.ccoef1, cFrom, cCount, $40);
  SetBytes(C.filter0, From, Count, N_SWITCHABLE_FILTERS);
  SetBytes(C.filter1, From, Count, N_SWITCHABLE_FILTERS);
  SetBytes(C.segpred, From, Count, 0);
  SetBytes(C.palsz, From, Count, 0);
  if IsLeft then SetBytes(C.palszuv, From, Count, 0);
end;

procedure AllocCtx(var C: TCtxArrays; N: Integer);
begin
  SetLength(C.mode, N); SetLength(C.lcoef, N); SetLength(C.ccoef0, N); SetLength(C.ccoef1, N);
  SetLength(C.segpred, N); SetLength(C.skip, N); SetLength(C.skipmode, N); SetLength(C.intra, N);
  SetLength(C.comptype, N); SetLength(C.filter0, N); SetLength(C.filter1, N);
  SetLength(C.txlpfy, N); SetLength(C.txlpfuv, N); SetLength(C.partition, N);
  SetLength(C.uvmode, N); SetLength(C.palsz, N); SetLength(C.palszuv, N);
  SetLength(C.ref0, N); SetLength(C.ref1, N); SetLength(C.txintra, N); SetLength(C.tx, N);
  SetLength(C.pal, N);
end;

procedure TAv1Decoder.SetupFrame;
var
  i, j, k, n, refidx, d0, d1, order, c0, c1, qcat: Integer;
  S: ^TRefSlot;
  rpRef: array[0..6] of PRefmvsTemporal;
  refW, refH: Integer;
const
  QuantDistWeight: array[0..2, 0..1] of Integer = ((2, 3), (2, 5), (2, 7));
  QuantDistLookup: array[0..3, 0..1] of Integer = ((9, 7), (11, 5), (12, 4), (13, 3));
begin
  if Fh.Width[0] <> Fh.Width[1] then raise EAv1.Create('AV1: super-resolution is not supported');
  if Fh.Quant.Qm then raise EAv1.Create('AV1: quantizer matrices are not supported');

  Layout := Seq.Layout;
  Bd := Seq.BitDepth; PixMax := (1 shl Bd) - 1;
  ssH := Seq.SsHor; ssV := Seq.SsVer;
  if Layout = LAYOUT_I400 then NumPlanes := 1 else NumPlanes := 3;
  FrmW := Fh.Width[0]; FrmH := Fh.Height;
  w4 := (FrmW + 3) shr 2; h4 := (FrmH + 3) shr 2;
  bw := ((FrmW + 7) shr 3) shl 1; bh := ((FrmH + 7) shr 3) shl 1;
  sb128w := (bw + 31) shr 5; sb128h := (bh + 31) shr 5;
  sbShift := 4 + Ord(Seq.Sb128); sbStep := 16 shl Ord(Seq.Sb128);
  sbh := (bh + sbStep - 1) shr sbShift;
  b4Stride := (bw + 31) and not 31;

  // reference checks
  if IsInterOrSwitch(Fh) then
    for i := 0 to 6 do
    begin
      refidx := Fh.RefIdx[i];
      Refp[i] := refidx;
      S := @Slots[refidx];
      if not S^.Valid then raise EAv1.Create('AV1: missing reference frame');
      if (S^.Pic.W <> FrmW) or (S^.Pic.H <> FrmH) then
        raise EAv1.Create('AV1: scaled reference frames are not supported');
      GmvWarpAllowed[i] := (Fh.Gmv[i].WmType > WM_TYPE_TRANSLATION) and (Fh.ForceIntegerMv = 0) and
        not GetShearParams(Fh.Gmv[i]);
    end;

  // entropy
  if Fh.PrimaryRefFrame = PRIMARY_REF_NONE then
  begin
    qcat := QCatIdx(Fh.Quant.Yac);
    LoadCdfDefault(InCdf, qcat);
  end
  else
  begin
    S := @Slots[Fh.RefIdx[Fh.PrimaryRefFrame]];
    if not S^.Valid then raise EAv1.Create('AV1: missing primary reference');
    InCdf := S^.Cdf;
  end;
  UpdCdfSet := False;

  // current picture: planes padded to 128 like dav1d (predictions of blocks
  // overhanging the frame edge write whole blocks)
  StrideY := (FrmW + 127) and not 127;
  n := ((FrmH + 127) and not 127) + 128;
  if NumPlanes = 3 then StrideC := StrideY shr ssH else StrideC := 0;
  Yp := nil; Up := nil; Vp := nil;
  SetLength(Yp, StrideY * n);
  if NumPlanes = 3 then
  begin
    SetLength(Up, StrideC * (n shr ssV));
    SetLength(Vp, StrideC * (n shr ssV));
  end;

  // contexts
  AllocCtx(A, b4Stride + 64);
  AllocCtx(L, bh + 64);
  SetBytes(A.txlpfy, 0, Length(A.txlpfy), 2); SetBytes(A.txlpfuv, 0, Length(A.txlpfuv), 1);
  SetBytes(L.txlpfy, 0, Length(L.txlpfy), 2); SetBytes(L.txlpfuv, 0, Length(L.txlpfuv), 1);

  // loop filter data
  n := b4Stride * (bh + 32);
  SetLength(LvlY, 0); SetLength(LvlY, n * 2);
  SetLength(LvlC, 0); SetLength(LvlC, n * 2);
  SetLength(EdgeVY, 0); SetLength(EdgeVY, n);
  SetLength(EdgeHY, 0); SetLength(EdgeHY, n);
  SetLength(EdgeVC, 0); SetLength(EdgeVC, n);
  SetLength(EdgeHC, 0); SetLength(EdgeHC, n);
  N64w := (bw + 15) shr 4; N64h := (bh + 15) shr 4;
  SetLength(CdefIdx, N64w * N64h);
  for i := 0 to High(CdefIdx) do CdefIdx[i] := -1;
  SetLength(NoskipMi, 0); SetLength(NoskipMi, n);
  for i := 0 to 2 do
  begin
    if i = 0 then k := Fh.Restoration.UnitSize[0] else k := Fh.Restoration.UnitSize[1];
    LrUnitLog2[i] := k;
    if i = 0 then begin refW := FrmW; refH := FrmH; end
    else begin refW := (FrmW + ssH) shr ssH; refH := (FrmH + ssV) shr ssV; end;
    LrUnitsW[i] := ((refW + (1 shl k) - 1) shr k) + 1;
    LrUnitsH[i] := ((refH + (1 shl k) - 1) shr k) + 1;
    SetLength(LrGrid[i], 0);
    SetLength(LrGrid[i], LrUnitsW[i] * LrUnitsH[i]);
  end;
  CalcLfValues(FrameLfLvl, [0, 0, 0, 0]);

  // ref mvs
  CurMvs := nil;
  if IsInterOrSwitch(Fh) or Fh.AllowIntrabc then
  begin
    n := ((FrmW + 127) and not 127) shr 3;
    SetLength(CurMvs, n * (((bh shr 1) + 31) and not 15) + n);
    if not Fh.AllowIntrabc then
      for i := 0 to 6 do RefPoc[i] := Slots[Fh.RefIdx[i]].Pic.Hdr.FrameOffset
    else
      for i := 0 to 6 do RefPoc[i] := 0;
    for i := 0 to 6 do
    begin
      rpRef[i] := nil;
      for j := 0 to 6 do RefRefPoc[i * 7 + j] := 0;
    end;
    if Fh.UseRefFrameMvs then
      for i := 0 to 6 do
      begin
        S := @Slots[Fh.RefIdx[i]];
        if (S^.Mvs <> nil) and ((((S^.Pic.W + 7) shr 3) shl 1) = bw) and
           ((((S^.Pic.H + 7) shr 3) shl 1) = bh) then
          rpRef[i] := @S^.Mvs[0];
        for j := 0 to 6 do RefRefPoc[i * 7 + j] := S^.RefPoc[j];
      end;
    RefmvsInitFrame(RF, Seq, Fh, RefPoc, @CurMvs[0], RefRefPoc, rpRef);
  end;

  // segmentation map
  HavePrevSegMap := False;
  PrevSegMap := nil;
  if Fh.Segmentation.Enabled then
  begin
    if Fh.Segmentation.Temporal or not Fh.Segmentation.UpdateMap then
    begin
      S := @Slots[Fh.RefIdx[Fh.PrimaryRefFrame]];
      if (S^.SegMap <> nil) and ((((S^.Pic.W + 7) shr 3) shl 1) = bw) and
         ((((S^.Pic.H + 7) shr 3) shl 1) = bh) then
      begin
        PrevSegMap := S^.SegMap;
        HavePrevSegMap := True;
      end;
    end;
    if Fh.Segmentation.UpdateMap then
    begin
      CurSegMap := nil;
      SetLength(CurSegMap, b4Stride * (sb128h * 32));
    end
    else if HavePrevSegMap then
      CurSegMap := PrevSegMap
    else
    begin
      CurSegMap := nil;
      SetLength(CurSegMap, b4Stride * (sb128h * 32));
    end;
  end
  else
    CurSegMap := nil;

  InitQuantTables(Fh.Quant.Yac, FrameDq);

  // jnt_comp weights
  if Fh.SwitchableCompRefs then
    for i := 0 to 6 do
      for j := i + 1 to 6 do
      begin
        d1 := IMin(Abs(GetPocDiff(Seq.OrderHintNBits, Slots[Fh.RefIdx[i]].Pic.Hdr.FrameOffset, Fh.FrameOffset)), 31);
        d0 := IMin(Abs(GetPocDiff(Seq.OrderHintNBits, Slots[Fh.RefIdx[j]].Pic.Hdr.FrameOffset, Fh.FrameOffset)), 31);
        order := Ord(d0 <= d1);
        k := 0;
        while k < 3 do
        begin
          c0 := QuantDistWeight[k][order];
          c1 := QuantDistWeight[k][1 - order];
          if ((d0 > d1) and (d0 * c0 < d1 * c1)) or ((d0 <= d1) and (d0 * c0 > d1 * c1)) then Break;
          Inc(k);
        end;
        JntWeights[i][j] := QuantDistLookup[k][order];
      end;

  // per-frame scratch
  if Length(EmuBuf) < 400 * 400 then SetLength(EmuBuf, 400 * 400);
  IPredMax := PixMax;
  LfMax := PixMax; LfBdShift := Bd - 8; LfFlatLim := 1 shl (Bd - 8);
  if Bd = 8 then Av1.Recon.ReconCfMax := (1 shl 15) - 1
  else Av1.Recon.ReconCfMax := (1 shl (Bd + 7)) - 1;
end;

procedure CdfUpdateCounters(const Hdr: TFrameHdr; var Dst: TCdfContext; const Src: TCdfContext);
var
  i, j, k, l: Integer;
  keep: TCdfModeContext;
  keepMv: TCdfMvContext;
  isIntra: Boolean;
begin
  isIntra := IsKeyOrIntra(Hdr);
  keep := Dst.m;
  keepMv := Dst.mv;
  Dst.coef := Src.coef;
  Dst.m := Src.m;
  Dst.m.intrabc := keep.intrabc;
  if isIntra then
  begin
    // inter-only CDFs are not propagated by key / intra frames
    Dst.m.y_mode := keep.y_mode; Dst.m.wedge_idx := keep.wedge_idx;
    Dst.m.comp_inter_mode := keep.comp_inter_mode; Dst.m.filter := keep.filter;
    Dst.m.interintra_mode := keep.interintra_mode; Dst.m.motion_mode := keep.motion_mode;
    Dst.m.skip_mode := keep.skip_mode; Dst.m.newmv_mode := keep.newmv_mode;
    Dst.m.globalmv_mode := keep.globalmv_mode; Dst.m.refmv_mode := keep.refmv_mode;
    Dst.m.drl_bit := keep.drl_bit; Dst.m.intra := keep.intra; Dst.m.comp := keep.comp;
    Dst.m.comp_dir := keep.comp_dir; Dst.m.jnt_comp := keep.jnt_comp;
    Dst.m.mask_comp := keep.mask_comp; Dst.m.wedge_comp := keep.wedge_comp;
    Dst.m.ref := keep.ref; Dst.m.comp_fwd_ref := keep.comp_fwd_ref;
    Dst.m.comp_bwd_ref := keep.comp_bwd_ref; Dst.m.comp_uni_ref := keep.comp_uni_ref;
    Dst.m.seg_pred := keep.seg_pred; Dst.m.interintra := keep.interintra;
    Dst.m.interintra_wedge := keep.interintra_wedge; Dst.m.obmc := keep.obmc;
    Dst.mv := keepMv;
  end
  else
    Dst.mv := Src.mv;

  with Dst.coef do
  begin
    for i := 0 to 1 do for j := 0 to 1 do
    begin
      eob_bin_16[i][j][4] := 0; eob_bin_32[i][j][5] := 0; eob_bin_64[i][j][6] := 0;
      eob_bin_128[i][j][7] := 0; eob_bin_256[i][j][8] := 0;
    end;
    for i := 0 to 1 do begin eob_bin_512[i][9] := 0; eob_bin_1024[i][10] := 0; end;
    for i := 0 to 4 do for j := 0 to 1 do for k := 0 to 3 do eob_base_tok[i][j][k][2] := 0;
    for i := 0 to 4 do for j := 0 to 1 do for k := 0 to 40 do base_tok[i][j][k][3] := 0;
    for i := 0 to 3 do for j := 0 to 1 do for k := 0 to 20 do br_tok[i][j][k][3] := 0;
    for i := 0 to 4 do for j := 0 to 1 do for k := 0 to 8 do eob_hi_bit[i][j][k][1] := 0;
    for i := 0 to 4 do for j := 0 to 12 do skip[i][j][1] := 0;
    for i := 0 to 1 do for j := 0 to 2 do dc_sign[i][j][1] := 0;
  end;
  with Dst.m do
  begin
    for k := 0 to 1 do for j := 0 to 12 do uv_mode[k][j][13 - Ord(k = 0)] := 0;
    for j := 0 to 3 do partition[0][j][7] := 0;
    for k := 1 to 3 do for j := 0 to 3 do partition[k][j][9] := 0;
    for j := 0 to 3 do partition[4][j][3] := 0;
    for j := 0 to 5 do cfl_alpha[j][15] := 0;
    for j := 0 to 1 do txtp_inter1[j][15] := 0;
    txtp_inter2[11] := 0;
    for k := 0 to 1 do for j := 0 to 12 do txtp_intra1[k][j][6] := 0;
    for k := 0 to 2 do for j := 0 to 12 do txtp_intra2[k][j][4] := 0;
    cfl_sign[7] := 0;
    for j := 0 to 7 do angle_delta[j][6] := 0;
    filter_intra[4] := 0;
    for j := 0 to 2 do seg_id[j][7] := 0;
    for k := 0 to 1 do for j := 0 to 6 do pal_sz[k][j][6] := 0;
    for l := 0 to 1 do for k := 0 to 6 do for j := 0 to 4 do color_map[l][k][j][k + 1] := 0;
    for k := 0 to 3 do for j := 0 to 2 do txsz[k][j][IMin(k + 1, 2)] := 0;
    delta_q[3] := 0;
    for j := 0 to 4 do delta_lf[j][3] := 0;
    restore_switchable[2] := 0;
    restore_wiener[1] := 0;
    restore_sgrproj[1] := 0;
    for j := 0 to 3 do txtp_inter3[j][1] := 0;
    for j := 0 to 21 do use_filter_intra[j][1] := 0;
    for k := 0 to 6 do for j := 0 to 2 do txpart[k][j][1] := 0;
    for j := 0 to 2 do skip[j][1] := 0;
    for k := 0 to 6 do for j := 0 to 2 do pal_y[k][j][1] := 0;
    for j := 0 to 1 do pal_uv[j][1] := 0;
    if not isIntra then
    begin
      for j := 0 to 3 do y_mode[j][12] := 0;
      for j := 0 to 8 do wedge_idx[j][15] := 0;
      for j := 0 to 7 do comp_inter_mode[j][7] := 0;
      for k := 0 to 1 do for j := 0 to 7 do filter[k][j][2] := 0;
      for j := 0 to 3 do interintra_mode[j][3] := 0;
      for j := 0 to 21 do motion_mode[j][2] := 0;
      for j := 0 to 2 do skip_mode[j][1] := 0;
      for j := 0 to 5 do newmv_mode[j][1] := 0;
      for j := 0 to 1 do globalmv_mode[j][1] := 0;
      for j := 0 to 5 do refmv_mode[j][1] := 0;
      for j := 0 to 2 do drl_bit[j][1] := 0;
      for j := 0 to 3 do intra[j][1] := 0;
      for j := 0 to 4 do comp[j][1] := 0;
      for j := 0 to 4 do comp_dir[j][1] := 0;
      for j := 0 to 5 do jnt_comp[j][1] := 0;
      for j := 0 to 5 do mask_comp[j][1] := 0;
      for j := 0 to 8 do wedge_comp[j][1] := 0;
      for k := 0 to 5 do for j := 0 to 2 do ref[k][j][1] := 0;
      for k := 0 to 2 do for j := 0 to 2 do comp_fwd_ref[k][j][1] := 0;
      for k := 0 to 1 do for j := 0 to 2 do comp_bwd_ref[k][j][1] := 0;
      for k := 0 to 2 do for j := 0 to 2 do comp_uni_ref[k][j][1] := 0;
      for j := 0 to 2 do seg_pred[j][1] := 0;
      for j := 0 to 3 do interintra[j][1] := 0;
      for j := 0 to 6 do interintra_wedge[j][1] := 0;
      for j := 0 to 21 do obmc[j][1] := 0;
    end;
  end;
  if not isIntra then
    with Dst.mv do
    begin
      for k := 0 to 1 do
      begin
        comp[k].classes[10] := 0;
        comp[k].sign[1] := 0;
        comp[k].class0[1] := 0;
        for j := 0 to 1 do comp[k].class0_fp[j][3] := 0;
        comp[k].class0_hp[1] := 0;
        for j := 0 to 9 do comp[k].classN[j][1] := 0;
        comp[k].classN_fp[3] := 0;
        comp[k].classN_hp[1] := 0;
      end;
      joint[3] := 0;
    end;
end;

procedure TAv1Decoder.DecodeFrame(TileData: PByte; TileSize: NativeInt; NTileGroups: Integer;
  const TgPtr: array of PByte; const TgSize: array of NativeInt;
  const TgStart, TgEnd: array of Integer);
var
  g, j, tr, tc, tileRow, sby, sbyEnd, byEnd, nts, p: Integer;
  ptr: PByte; rem, tsz: NativeInt;
  tile: ^TTileState;
  i: Integer;
begin
  SetupFrame;
  nts := Fh.Tiling.Cols * Fh.Tiling.Rows;
  SetLength(Tiles, nts);
  if Fh.RefreshContext then OutCdf := InCdf;

  // set up tiles
  for g := 0 to NTileGroups - 1 do
  begin
    ptr := TgPtr[g]; rem := TgSize[g];
    for j := TgStart[g] to TgEnd[g] do
    begin
      if j = TgEnd[g] then tsz := rem
      else
      begin
        if Fh.Tiling.NBytes > rem then raise EAv1.Create('AV1: truncated tile data');
        tsz := 0;
        for i := 0 to Fh.Tiling.NBytes - 1 do tsz := tsz or (NativeInt(ptr[i]) shl (i * 8));
        Inc(tsz);
        Inc(ptr, Fh.Tiling.NBytes); Dec(rem, Fh.Tiling.NBytes);
        if tsz > rem then raise EAv1.Create('AV1: truncated tile data');
      end;
      tr := j div Fh.Tiling.Cols; tc := j mod Fh.Tiling.Cols;
      tile := @Tiles[j];
      tile^.Cdf := InCdf;
      tile^.LastQidx := Fh.Quant.Yac;
      FillChar(tile^.LastDeltaLf, SizeOf(tile^.LastDeltaLf), 0);
      tile^.Dq := FrameDq;
      tile^.LfLvl := FrameLfLvl;
      MsacInit(tile^.Msac, ptr, tsz, Fh.DisableCdfUpdate);
      tile^.TileRow := tr; tile^.TileCol := tc;
      tile^.ColStart := Fh.Tiling.ColStartSb[tc] shl sbShift;
      tile^.ColEnd := IMin(Fh.Tiling.ColStartSb[tc + 1] shl sbShift, bw);
      tile^.RowStart := Fh.Tiling.RowStartSb[tr] shl sbShift;
      tile^.RowEnd := IMin(Fh.Tiling.RowStartSb[tr + 1] shl sbShift, bh);
      for p := 0 to 2 do
      begin
        tile^.LrRef[p].fv[0] := 3; tile^.LrRef[p].fv[1] := -7; tile^.LrRef[p].fv[2] := 15;
        tile^.LrRef[p].fh[0] := 3; tile^.LrRef[p].fh[1] := -7; tile^.LrRef[p].fh[2] := 15;
        tile^.LrRef[p].sw[0] := -32; tile^.LrRef[p].sw[1] := 31;
      end;
      Inc(ptr, tsz); Dec(rem, tsz);
    end;
  end;

  // above contexts reset (per tile row: done at each tile row start below)
  for tileRow := 0 to Fh.Tiling.Rows - 1 do
  begin
    ResetCtx(A, 0, Length(A.mode), IsKeyOrIntra(Fh), False);
    sbyEnd := IMin(Fh.Tiling.RowStartSb[tileRow + 1], sbh);
    for sby := Fh.Tiling.RowStartSb[tileRow] to sbyEnd - 1 do
    begin
      by := sby shl sbShift;
      byEnd := (by + sbStep) shr 1;
      if Fh.UseRefFrameMvs then
        RefmvsLoadTmvs(RF, 0, bw shr 1, by shr 1, byEnd);
      for tc := 0 to Fh.Tiling.Cols - 1 do
        DecodeTileSbrow(tileRow * Fh.Tiling.Cols + tc, sby);
      if IsInterOrSwitch(Fh) then
        RefmvsSaveTmvs(RF, 0, bw shr 1, by shr 1, byEnd);
    end;
  end;

  // in-loop filters (whole frame)
  DeblockFrame;
  CdefFrame;
  LrFrame;

  // entropy context update
  if Fh.RefreshContext and UpdCdfSet then
    CdfUpdateCounters(Fh, OutCdf, UpdCdf);

  // references
  for i := 0 to 7 do
    if (Fh.RefreshFrameFlags and (1 shl i)) <> 0 then
    begin
      Slots[i].Valid := True;
      Slots[i].Pic.Y := Yp; Slots[i].Pic.U := Up; Slots[i].Pic.V := Vp;
      Slots[i].Pic.StrideY := StrideY; Slots[i].Pic.StrideC := StrideC;
      Slots[i].Pic.W := FrmW; Slots[i].Pic.H := FrmH;
      Slots[i].Pic.Hdr := Fh;
      if Fh.RefreshContext then Slots[i].Cdf := OutCdf else Slots[i].Cdf := InCdf;
      Slots[i].SegMap := CurSegMap;
      if not Fh.AllowIntrabc then Slots[i].Mvs := CurMvs else Slots[i].Mvs := nil;
      for j := 0 to 6 do Slots[i].RefPoc[j] := RefPoc[j];
    end;

  if Fh.ShowFrame or OutputHidden then
  begin
    FOutput := Default(TAv1Frame);
    with FOutput do
    begin
      Width := FrmW; Height := FrmH; BitDepth := Bd;
      NumPlanes := Self.NumPlanes;
    end;
    // copy cropped planes
    SetLength(FOutput.Y, FrmW * FrmH);
    for j := 0 to FrmH - 1 do Move(Yp[j * StrideY], FOutput.Y[j * FrmW], FrmW * 2);
    if NumPlanes = 3 then
    begin
      FOutput.SsH := ssH; FOutput.SsV := ssV;
      FOutput.ChromaW := (FrmW + ssH) shr ssH; FOutput.ChromaH := (FrmH + ssV) shr ssV;
      SetLength(FOutput.U, FOutput.ChromaW * FOutput.ChromaH);
      SetLength(FOutput.V, FOutput.ChromaW * FOutput.ChromaH);
      for j := 0 to FOutput.ChromaH - 1 do
      begin
        Move(Up[j * StrideC], FOutput.U[j * FOutput.ChromaW], FOutput.ChromaW * 2);
        Move(Vp[j * StrideC], FOutput.V[j * FOutput.ChromaW], FOutput.ChromaW * 2);
      end;
    end
    else
    begin
      FOutput.SsH := 1; FOutput.SsV := 1;
    end;
    FHasOutput := True;
    if CollectAll then
    begin
      SetLength(Collected, Length(Collected) + 1);
      Collected[High(Collected)] := FOutput;
    end;
  end;
end;

procedure TAv1Decoder.DecodeTileSbrow(TileIdx, SbyAbs: Integer);
var rootBl, sbx, sb128y: Integer;
begin
  TS := @Tiles[TileIdx];
  if Seq.Sb128 then rootBl := BL_128X128 else rootBl := BL_64X64;
  by := SbyAbs shl sbShift;
  if IsInterOrSwitch(Fh) or Fh.AllowIntrabc then
    RefmvsTileInit(RF, TS^.ColStart, TS^.ColEnd, TS^.RowStart, TS^.RowEnd);
  ResetCtx(L, by, sbStep, IsKeyOrIntra(Fh), True);
  sb128y := by shr 5;
  bx := TS^.ColStart;
  while bx < TS^.ColEnd do
  begin
    // cdef index slots for this SB
    if rootBl = BL_128X128 then
    begin
      sbx := (by shr 4) * N64w + (bx shr 4);
      CdefIdx[sbx] := -1;
      if (bx shr 4) + 1 < N64w then CdefIdx[sbx + 1] := -1;
      if (by shr 4) + 1 < N64h then
      begin
        CdefIdx[sbx + N64w] := -1;
        if (bx shr 4) + 1 < N64w then CdefIdx[sbx + N64w + 1] := -1;
      end;
    end
    else
      CdefIdx[(by shr 4) * N64w + (bx shr 4)] := -1;
    ReadLrSb;
    DecodeSb(rootBl, -1);
    Inc(bx, sbStep);
  end;
  if sb128y < 0 then ;
  // remember the CDFs of the context-update tile once it is finished
  if Fh.RefreshContext and (TileIdx = Fh.Tiling.Update) and
     (((SbyAbs + 1) shl sbShift) >= TS^.RowEnd) then
  begin
    UpdCdf := TS^.Cdf;
    UpdCdfSet := True;
  end;
end;

function Av1Decode(Data: PByte; Size: NativeInt; out F: TAv1Frame): Boolean;
var D: TAv1Decoder;
begin
  D := TAv1Decoder.Create;
  try
    Result := D.DecodeTemporalUnit(Data, Size, F);
  finally
    D.Free;
  end;
end;


{$I Av1.Enc.inc}

end.
