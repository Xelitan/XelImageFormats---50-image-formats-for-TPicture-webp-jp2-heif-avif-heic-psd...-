unit Av1.Tables;

// AV1 block / transform / motion-compensation lookup tables and the wedge and
// inter-intra blend masks. Mirrors dav1d src/tables.c, src/levels.h and
// src/wedge.c so the decoder can be ported 1:1.
//
// Reference: dav1d (BSD-2-Clause).

{$mode delphi}{$H+}
{$RANGECHECKS OFF}{$OVERFLOWCHECKS OFF}

interface

const
  // BlockLevel
  BL_128X128 = 0; BL_64X64 = 1; BL_32X32 = 2; BL_16X16 = 3; BL_8X8 = 4;

  // BlockPartition
  PARTITION_NONE = 0; PARTITION_H = 1; PARTITION_V = 2; PARTITION_SPLIT = 3;
  PARTITION_T_TOP_SPLIT = 4; PARTITION_T_BOTTOM_SPLIT = 5;
  PARTITION_T_LEFT_SPLIT = 6; PARTITION_T_RIGHT_SPLIT = 7;
  PARTITION_H4 = 8; PARTITION_V4 = 9;

  // BlockSize
  BS_128x128 = 0; BS_128x64 = 1; BS_64x128 = 2; BS_64x64 = 3; BS_64x32 = 4;
  BS_64x16 = 5; BS_32x64 = 6; BS_32x32 = 7; BS_32x16 = 8; BS_32x8 = 9;
  BS_16x64 = 10; BS_16x32 = 11; BS_16x16 = 12; BS_16x8 = 13; BS_16x4 = 14;
  BS_8x32 = 15; BS_8x16 = 16; BS_8x8 = 17; BS_8x4 = 18; BS_4x16 = 19;
  BS_4x8 = 20; BS_4x4 = 21;

  // (Rect)TxfmSize
  TX_4X4 = 0; TX_8X8 = 1; TX_16X16 = 2; TX_32X32 = 3; TX_64X64 = 4;
  RTX_4X8 = 5; RTX_8X4 = 6; RTX_8X16 = 7; RTX_16X8 = 8; RTX_16X32 = 9;
  RTX_32X16 = 10; RTX_32X64 = 11; RTX_64X32 = 12; RTX_4X16 = 13;
  RTX_16X4 = 14; RTX_8X32 = 15; RTX_32X8 = 16; RTX_16X64 = 17; RTX_64X16 = 18;

  // TxfmType
  DCT_DCT = 0; ADST_DCT = 1; DCT_ADST = 2; ADST_ADST = 3; FLIPADST_DCT = 4;
  DCT_FLIPADST = 5; FLIPADST_FLIPADST = 6; ADST_FLIPADST = 7; FLIPADST_ADST = 8;
  IDTX = 9; V_DCT = 10; H_DCT = 11; V_ADST = 12; H_ADST = 13; V_FLIPADST = 14;
  H_FLIPADST = 15; WHT_WHT = 16;

  TX_CLASS_2D = 0; TX_CLASS_H = 1; TX_CLASS_V = 2;

  // IntraPredMode (+ dav1d's implementation-only resolved modes)
  DC_PRED = 0; VERT_PRED = 1; HOR_PRED = 2; DIAG_DOWN_LEFT_PRED = 3;
  DIAG_DOWN_RIGHT_PRED = 4; VERT_RIGHT_PRED = 5; HOR_DOWN_PRED = 6;
  HOR_UP_PRED = 7; VERT_LEFT_PRED = 8; SMOOTH_PRED = 9; SMOOTH_V_PRED = 10;
  SMOOTH_H_PRED = 11; PAETH_PRED = 12;
  N_INTRA_PRED_MODES = 13; CFL_PRED = 13; FILTER_PRED = 13;
  N_UV_INTRA_PRED_MODES = 14;
  LEFT_DC_PRED = 3; TOP_DC_PRED = 4; DC_128_PRED = 5;
  Z1_PRED = 6; Z2_PRED = 7; Z3_PRED = 8;

  // InterIntraPredMode
  II_DC_PRED = 0; II_VERT_PRED = 1; II_HOR_PRED = 2; II_SMOOTH_PRED = 3;

  // Filter2d (order: horizontal, vertical)
  FILTER_2D_8TAP_REGULAR = 0; FILTER_2D_8TAP_REGULAR_SMOOTH = 1;
  FILTER_2D_8TAP_REGULAR_SHARP = 2; FILTER_2D_8TAP_SHARP_REGULAR = 3;
  FILTER_2D_8TAP_SHARP_SMOOTH = 4; FILTER_2D_8TAP_SHARP = 5;
  FILTER_2D_8TAP_SMOOTH_REGULAR = 6; FILTER_2D_8TAP_SMOOTH = 7;
  FILTER_2D_8TAP_SMOOTH_SHARP = 8; FILTER_2D_BILINEAR = 9;

  // Dav1dFilterMode
  FILTER_8TAP_REGULAR = 0; FILTER_8TAP_SMOOTH = 1; FILTER_8TAP_SHARP = 2;
  N_SWITCHABLE_FILTERS = 3; FILTER_BILINEAR = 3; FILTER_SWITCHABLE = 4;

  // MVJoint
  MV_JOINT_ZERO = 0; MV_JOINT_H = 1; MV_JOINT_V = 2; MV_JOINT_HV = 3;

  // InterPredMode / CompInterPredMode
  NEARESTMV = 0; NEARMV = 1; GLOBALMV = 2; NEWMV = 3;
  NEARESTMV_NEARESTMV = 0; NEARMV_NEARMV = 1; NEARESTMV_NEWMV = 2;
  NEWMV_NEARESTMV = 3; NEARMV_NEWMV = 4; NEWMV_NEARMV = 5;
  GLOBALMV_GLOBALMV = 6; NEWMV_NEWMV = 7;
  NEAREST_DRL = 0; NEARER_DRL = 1; NEAR_DRL = 2; NEARISH_DRL = 3;

  // CompInterType
  COMP_INTER_NONE = 0; COMP_INTER_WEIGHTED_AVG = 1; COMP_INTER_AVG = 2;
  COMP_INTER_SEG = 3; COMP_INTER_WEDGE = 4;

  // InterIntraType
  INTER_INTRA_NONE = 0; INTER_INTRA_BLEND = 1; INTER_INTRA_WEDGE = 2;

  // MotionMode
  MM_TRANSLATION = 0; MM_OBMC = 1; MM_WARP = 2;

  // Warped motion types
  WM_TYPE_IDENTITY = 0; WM_TYPE_TRANSLATION = 1; WM_TYPE_ROT_ZOOM = 2;
  WM_TYPE_AFFINE = 3;

  // Intra edge flags (dav1d EdgeFlags)
  EDGE_I444_TOP_HAS_RIGHT = 1; EDGE_I422_TOP_HAS_RIGHT = 2;
  EDGE_I420_TOP_HAS_RIGHT = 4; EDGE_I444_LEFT_HAS_BOTTOM = 8;
  EDGE_I422_LEFT_HAS_BOTTOM = 16; EDGE_I420_LEFT_HAS_BOTTOM = 32;
  EDGE_ALL_TOP_HAS_RIGHT = 7; EDGE_ALL_LEFT_HAS_BOTTOM = 56;
  EDGE_ALL_TR_AND_BL = 63;

  INVALID_MV = LongWord($80008000);

type
  TTxDim = record
    w, h, lw, lh, min, max, sub, ctx: Byte;
  end;
  PTxDim = ^TTxDim;

const
  AlPartCtx: array[0..1, 0..4, 0..9] of Byte = (
    ( ($00,$00,$10,$FF,$00,$10,$10,$10,$FF,$FF),
      ($10,$10,$18,$FF,$10,$18,$18,$18,$10,$1c),
      ($18,$18,$1c,$FF,$18,$1c,$1c,$1c,$18,$1e),
      ($1c,$1c,$1e,$FF,$1c,$1e,$1e,$1e,$1c,$1f),
      ($1e,$1e,$1f,$1f,$FF,$FF,$FF,$FF,$FF,$FF) ),
    ( ($00,$10,$00,$FF,$10,$10,$00,$10,$FF,$FF),
      ($10,$18,$10,$FF,$18,$18,$10,$18,$1c,$10),
      ($18,$1c,$18,$FF,$1c,$1c,$18,$1c,$1e,$18),
      ($1c,$1e,$1c,$FF,$1e,$1e,$1c,$1e,$1f,$1c),
      ($1e,$1f,$1e,$1f,$FF,$FF,$FF,$FF,$FF,$FF) ));

  BlockSizes: array[0..4, 0..9, 0..1] of Byte = (
    ( (BS_128x128,0), (BS_128x64,0), (BS_64x128,0), (0,0),
      (BS_64x64,BS_128x64), (BS_128x64,BS_64x64), (BS_64x64,BS_64x128),
      (BS_64x128,BS_64x64), (0,0), (0,0) ),
    ( (BS_64x64,0), (BS_64x32,0), (BS_32x64,0), (0,0),
      (BS_32x32,BS_64x32), (BS_64x32,BS_32x32), (BS_32x32,BS_32x64),
      (BS_32x64,BS_32x32), (BS_64x16,0), (BS_16x64,0) ),
    ( (BS_32x32,0), (BS_32x16,0), (BS_16x32,0), (0,0),
      (BS_16x16,BS_32x16), (BS_32x16,BS_16x16), (BS_16x16,BS_16x32),
      (BS_16x32,BS_16x16), (BS_32x8,0), (BS_8x32,0) ),
    ( (BS_16x16,0), (BS_16x8,0), (BS_8x16,0), (0,0),
      (BS_8x8,BS_16x8), (BS_16x8,BS_8x8), (BS_8x8,BS_8x16),
      (BS_8x16,BS_8x8), (BS_16x4,0), (BS_4x16,0) ),
    ( (BS_8x8,0), (BS_8x4,0), (BS_4x8,0), (BS_4x4,0),
      (0,0), (0,0), (0,0), (0,0), (0,0), (0,0) ));

  // [bs] -> w4, h4, log2(w4), log2(h4)
  BlockDim: array[0..21, 0..3] of Byte = (
    (32,32,5,5),(32,16,5,4),(16,32,4,5),(16,16,4,4),(16,8,4,3),(16,4,4,2),
    (8,16,3,4),(8,8,3,3),(8,4,3,2),(8,2,3,1),(4,16,2,4),(4,8,2,3),(4,4,2,2),
    (4,2,2,1),(4,1,2,0),(2,8,1,3),(2,4,1,2),(2,2,1,1),(2,1,1,0),(1,4,0,2),
    (1,2,0,1),(1,1,0,0));

  TxDims: array[0..18] of TTxDim = (
    (w:1;  h:1;  lw:0; lh:0; min:0; max:0; sub:0;          ctx:0),
    (w:2;  h:2;  lw:1; lh:1; min:1; max:1; sub:TX_4X4;     ctx:1),
    (w:4;  h:4;  lw:2; lh:2; min:2; max:2; sub:TX_8X8;     ctx:2),
    (w:8;  h:8;  lw:3; lh:3; min:3; max:3; sub:TX_16X16;   ctx:3),
    (w:16; h:16; lw:4; lh:4; min:4; max:4; sub:TX_32X32;   ctx:4),
    (w:1;  h:2;  lw:0; lh:1; min:0; max:1; sub:TX_4X4;     ctx:1),
    (w:2;  h:1;  lw:1; lh:0; min:0; max:1; sub:TX_4X4;     ctx:1),
    (w:2;  h:4;  lw:1; lh:2; min:1; max:2; sub:TX_8X8;     ctx:2),
    (w:4;  h:2;  lw:2; lh:1; min:1; max:2; sub:TX_8X8;     ctx:2),
    (w:4;  h:8;  lw:2; lh:3; min:2; max:3; sub:TX_16X16;   ctx:3),
    (w:8;  h:4;  lw:3; lh:2; min:2; max:3; sub:TX_16X16;   ctx:3),
    (w:8;  h:16; lw:3; lh:4; min:3; max:4; sub:TX_32X32;   ctx:4),
    (w:16; h:8;  lw:4; lh:3; min:3; max:4; sub:TX_32X32;   ctx:4),
    (w:1;  h:4;  lw:0; lh:2; min:0; max:2; sub:RTX_4X8;    ctx:1),
    (w:4;  h:1;  lw:2; lh:0; min:0; max:2; sub:RTX_8X4;    ctx:1),
    (w:2;  h:8;  lw:1; lh:3; min:1; max:3; sub:RTX_8X16;   ctx:2),
    (w:8;  h:2;  lw:3; lh:1; min:1; max:3; sub:RTX_16X8;   ctx:2),
    (w:4;  h:16; lw:2; lh:4; min:2; max:4; sub:RTX_16X32;  ctx:3),
    (w:16; h:4;  lw:4; lh:2; min:2; max:4; sub:RTX_32X16;  ctx:3));

  // [bs][y, 420, 422, 444]
  MaxTxfmSizeForBs: array[0..21, 0..3] of Byte = (
    (TX_64X64, TX_32X32, TX_32X32, TX_32X32),
    (TX_64X64, TX_32X32, TX_32X32, TX_32X32),
    (TX_64X64, TX_32X32, 0, TX_32X32),
    (TX_64X64, TX_32X32, TX_32X32, TX_32X32),
    (RTX_64X32, RTX_32X16, TX_32X32, TX_32X32),
    (RTX_64X16, RTX_32X8, RTX_32X16, RTX_32X16),
    (RTX_32X64, RTX_16X32, 0, TX_32X32),
    (TX_32X32, TX_16X16, RTX_16X32, TX_32X32),
    (RTX_32X16, RTX_16X8, TX_16X16, RTX_32X16),
    (RTX_32X8, RTX_16X4, RTX_16X8, RTX_32X8),
    (RTX_16X64, RTX_8X32, 0, RTX_16X32),
    (RTX_16X32, RTX_8X16, 0, RTX_16X32),
    (TX_16X16, TX_8X8, RTX_8X16, TX_16X16),
    (RTX_16X8, RTX_8X4, TX_8X8, RTX_16X8),
    (RTX_16X4, RTX_8X4, RTX_8X4, RTX_16X4),
    (RTX_8X32, RTX_4X16, 0, RTX_8X32),
    (RTX_8X16, RTX_4X8, 0, RTX_8X16),
    (TX_8X8, TX_4X4, RTX_4X8, TX_8X8),
    (RTX_8X4, TX_4X4, TX_4X4, RTX_8X4),
    (RTX_4X16, RTX_4X8, 0, RTX_4X16),
    (RTX_4X8, TX_4X4, 0, RTX_4X8),
    (TX_4X4, TX_4X4, TX_4X4, TX_4X4));

  TxtpFromUvMode: array[0..13] of Byte = (
    DCT_DCT, ADST_DCT, DCT_ADST, DCT_DCT, ADST_ADST, ADST_DCT, DCT_ADST,
    DCT_ADST, ADST_DCT, ADST_ADST, ADST_DCT, DCT_ADST, ADST_ADST, DCT_DCT);

  CompInterPredModes: array[0..7, 0..1] of Byte = (
    (NEARESTMV, NEARESTMV), (NEARMV, NEARMV), (NEARESTMV, NEWMV),
    (NEWMV, NEARESTMV), (NEARMV, NEWMV), (NEWMV, NEARMV),
    (GLOBALMV, GLOBALMV), (NEWMV, NEWMV));

  PartitionTypeCount: array[0..4] of Byte = (7, 9, 9, 9, 3);

  TxTypesPerSet: array[0..39] of Byte = (
    IDTX, DCT_DCT, ADST_ADST, ADST_DCT, DCT_ADST,
    IDTX, DCT_DCT, V_DCT, H_DCT, ADST_ADST, ADST_DCT, DCT_ADST,
    IDTX, V_DCT, H_DCT, DCT_DCT, ADST_DCT, DCT_ADST, FLIPADST_DCT,
    DCT_FLIPADST, ADST_ADST, FLIPADST_FLIPADST, ADST_FLIPADST, FLIPADST_ADST,
    IDTX, V_DCT, H_DCT, V_ADST, H_ADST, V_FLIPADST, H_FLIPADST,
    DCT_DCT, ADST_DCT, DCT_ADST, FLIPADST_DCT, DCT_FLIPADST,
    ADST_ADST, FLIPADST_FLIPADST, ADST_FLIPADST, FLIPADST_ADST);

  YmodeSizeContext: array[0..21] of Byte = (
    3,3,3,3,3,2,3,3,2,1,2,2,2,1,0,1,1,1,0,0,0,0);

  TxTypeClass: array[0..16] of Byte = (
    0,0,0,0,0,0,0,0,0,0, TX_CLASS_V,TX_CLASS_H,TX_CLASS_V,TX_CLASS_H,
    TX_CLASS_V,TX_CLASS_H, 0);

  // [filter_y][filter_x] -> Filter2d
  Filter2dTab: array[0..3, 0..3] of Byte = (
    (FILTER_2D_8TAP_REGULAR, FILTER_2D_8TAP_REGULAR_SMOOTH, FILTER_2D_8TAP_REGULAR_SHARP, 0),
    (FILTER_2D_8TAP_SMOOTH_REGULAR, FILTER_2D_8TAP_SMOOTH, FILTER_2D_8TAP_SMOOTH_SHARP, 0),
    (FILTER_2D_8TAP_SHARP_REGULAR, FILTER_2D_8TAP_SHARP_SMOOTH, FILTER_2D_8TAP_SHARP, 0),
    (0, 0, 0, FILTER_2D_BILINEAR));

  // Filter2d -> (filter[0], filter[1]) = (vertical, horizontal) as coded
  FilterDir: array[0..9, 0..1] of Byte = (
    (FILTER_8TAP_REGULAR, FILTER_8TAP_REGULAR),
    (FILTER_8TAP_SMOOTH,  FILTER_8TAP_REGULAR),
    (FILTER_8TAP_SHARP,   FILTER_8TAP_REGULAR),
    (FILTER_8TAP_REGULAR, FILTER_8TAP_SHARP),
    (FILTER_8TAP_SMOOTH,  FILTER_8TAP_SHARP),
    (FILTER_8TAP_SHARP,   FILTER_8TAP_SHARP),
    (FILTER_8TAP_REGULAR, FILTER_8TAP_SMOOTH),
    (FILTER_8TAP_SMOOTH,  FILTER_8TAP_SMOOTH),
    (FILTER_8TAP_SHARP,   FILTER_8TAP_SMOOTH),
    (FILTER_BILINEAR,     FILTER_BILINEAR));

  FilterModeToYMode: array[0..4] of Byte = (DC_PRED, VERT_PRED, HOR_PRED, HOR_DOWN_PRED, DC_PRED);

  IntraModeContext: array[0..12] of Byte = (0,1,2,3,4,4,4,4,3,0,1,2,0);

  WedgeCtxLut: array[0..21] of Byte = (
    0,0,0,0,0,0,0, 6,5,8, 0,4,3,2, 0, 7,1,0, 0,0,0,0);

  WedgeAllowedMask = (1 shl BS_32x32) or (1 shl BS_32x16) or (1 shl BS_32x8) or
    (1 shl BS_16x32) or (1 shl BS_16x16) or (1 shl BS_16x8) or (1 shl BS_8x32) or
    (1 shl BS_8x16) or (1 shl BS_8x8);
  InterIntraAllowedMask = (1 shl BS_32x32) or (1 shl BS_32x16) or
    (1 shl BS_16x32) or (1 shl BS_16x16) or (1 shl BS_16x8) or
    (1 shl BS_8x16) or (1 shl BS_8x8);
  CflAllowedMask = (1 shl BS_32x32) or (1 shl BS_32x16) or (1 shl BS_32x8) or
    (1 shl BS_16x32) or (1 shl BS_16x16) or (1 shl BS_16x8) or (1 shl BS_16x4) or
    (1 shl BS_8x32) or (1 shl BS_8x16) or (1 shl BS_8x8) or (1 shl BS_8x4) or
    (1 shl BS_4x16) or (1 shl BS_4x8) or (1 shl BS_4x4);

{$I Av1.McTables.inc}

var
  // Wedge masks: [chroma layout idx 0=444,1=422,2=420][bs - BS_32x32][sign][wedge_idx].
  WedgeMasks: array[0..2, 0..10, 0..1, 0..15] of PByte;
  // Inter-intra masks: [chroma layout idx][bs - BS_32x32][II mode].
  IIMasks: array[0..2, 0..10, 0..3] of PByte;

function CtzI(v: LongWord): Integer;
function ULog2(v: LongWord): Integer;

implementation

var
  MaskStore: array of Byte;   // backing memory for WedgeMasks / IIMasks

function CtzI(v: LongWord): Integer;
begin
  Result := 0;
  if v = 0 then Exit;
  while (v and 1) = 0 do begin v := v shr 1; Inc(Result); end;
end;

function ULog2(v: LongWord): Integer;
begin
  Result := -1;
  while v <> 0 do begin v := v shr 1; Inc(Result); end;
end;

// ---- wedge / inter-intra mask generation (dav1d wedge.c) ----

const
  WEDGE_HORIZONTAL = 0; WEDGE_VERTICAL = 1; WEDGE_OBLIQUE27 = 2;
  WEDGE_OBLIQUE63 = 3; WEDGE_OBLIQUE117 = 4; WEDGE_OBLIQUE153 = 5;

type
  TWedgeCode = record dir, xoff, yoff: Byte; end;
  TWedgeBook = array[0..15] of TWedgeCode;

const
  WedgeHgtw: TWedgeBook = (
    (dir:WEDGE_OBLIQUE27;xoff:4;yoff:4),(dir:WEDGE_OBLIQUE63;xoff:4;yoff:4),
    (dir:WEDGE_OBLIQUE117;xoff:4;yoff:4),(dir:WEDGE_OBLIQUE153;xoff:4;yoff:4),
    (dir:WEDGE_HORIZONTAL;xoff:4;yoff:2),(dir:WEDGE_HORIZONTAL;xoff:4;yoff:4),
    (dir:WEDGE_HORIZONTAL;xoff:4;yoff:6),(dir:WEDGE_VERTICAL;xoff:4;yoff:4),
    (dir:WEDGE_OBLIQUE27;xoff:4;yoff:2),(dir:WEDGE_OBLIQUE27;xoff:4;yoff:6),
    (dir:WEDGE_OBLIQUE153;xoff:4;yoff:2),(dir:WEDGE_OBLIQUE153;xoff:4;yoff:6),
    (dir:WEDGE_OBLIQUE63;xoff:2;yoff:4),(dir:WEDGE_OBLIQUE63;xoff:6;yoff:4),
    (dir:WEDGE_OBLIQUE117;xoff:2;yoff:4),(dir:WEDGE_OBLIQUE117;xoff:6;yoff:4));
  WedgeHltw: TWedgeBook = (
    (dir:WEDGE_OBLIQUE27;xoff:4;yoff:4),(dir:WEDGE_OBLIQUE63;xoff:4;yoff:4),
    (dir:WEDGE_OBLIQUE117;xoff:4;yoff:4),(dir:WEDGE_OBLIQUE153;xoff:4;yoff:4),
    (dir:WEDGE_VERTICAL;xoff:2;yoff:4),(dir:WEDGE_VERTICAL;xoff:4;yoff:4),
    (dir:WEDGE_VERTICAL;xoff:6;yoff:4),(dir:WEDGE_HORIZONTAL;xoff:4;yoff:4),
    (dir:WEDGE_OBLIQUE27;xoff:4;yoff:2),(dir:WEDGE_OBLIQUE27;xoff:4;yoff:6),
    (dir:WEDGE_OBLIQUE153;xoff:4;yoff:2),(dir:WEDGE_OBLIQUE153;xoff:4;yoff:6),
    (dir:WEDGE_OBLIQUE63;xoff:2;yoff:4),(dir:WEDGE_OBLIQUE63;xoff:6;yoff:4),
    (dir:WEDGE_OBLIQUE117;xoff:2;yoff:4),(dir:WEDGE_OBLIQUE117;xoff:6;yoff:4));
  WedgeHeqw: TWedgeBook = (
    (dir:WEDGE_OBLIQUE27;xoff:4;yoff:4),(dir:WEDGE_OBLIQUE63;xoff:4;yoff:4),
    (dir:WEDGE_OBLIQUE117;xoff:4;yoff:4),(dir:WEDGE_OBLIQUE153;xoff:4;yoff:4),
    (dir:WEDGE_HORIZONTAL;xoff:4;yoff:2),(dir:WEDGE_HORIZONTAL;xoff:4;yoff:6),
    (dir:WEDGE_VERTICAL;xoff:2;yoff:4),(dir:WEDGE_VERTICAL;xoff:6;yoff:4),
    (dir:WEDGE_OBLIQUE27;xoff:4;yoff:2),(dir:WEDGE_OBLIQUE27;xoff:4;yoff:6),
    (dir:WEDGE_OBLIQUE153;xoff:4;yoff:2),(dir:WEDGE_OBLIQUE153;xoff:4;yoff:6),
    (dir:WEDGE_OBLIQUE63;xoff:2;yoff:4),(dir:WEDGE_OBLIQUE63;xoff:6;yoff:4),
    (dir:WEDGE_OBLIQUE117;xoff:2;yoff:4),(dir:WEDGE_OBLIQUE117;xoff:6;yoff:4));

  MasterBorder: array[0..2, 0..7] of Byte = (
    (1, 2, 6, 18, 37, 53, 60, 63),     // odd
    (1, 4, 11, 27, 46, 58, 62, 63),    // even
    (0, 2, 7, 21, 43, 57, 62, 64));    // vert

  IIWeights1d: array[0..31] of Byte = (
    60, 52, 45, 39, 34, 30, 26, 22, 19, 17, 15, 13, 11, 10,  8,  7,
     6,  6,  5,  4,  4,  3,  3,  2,  2,  2,  2,  1,  1,  1,  1,  1);

  IIBs: array[0..6] of Byte = (BS_32x32, BS_32x16, BS_16x32, BS_16x16, BS_16x8, BS_8x16, BS_8x8);

type
  TMaster = array[0..5, 0..64*64-1] of Byte;

var
  StorePos: Integer;

function Alloc(n: Integer): PByte;
begin
  Result := @MaskStore[StorePos];
  Inc(StorePos, (n + 15) and not 15);
end;

procedure InsertBorder(dst: PByte; const src: array of Byte; ctr: Integer);
var i, a, b, n: Integer;
begin
  if ctr > 4 then FillChar(dst^, ctr - 4, 0);
  if ctr > 4 then a := ctr else a := 4;
  if 4 - ctr > 0 then b := 4 - ctr else b := 0;
  n := 64 - ctr; if n > 8 then n := 8;
  for i := 0 to n - 1 do dst[a - 4 + i] := src[b + i];
  if ctr < 64 - 4 then FillChar(dst[ctr + 4], 64 - 4 - ctr, 64);
end;

procedure BuildWedge(const master: TMaster; w, h, bsIdx: Integer;
  const cb: TWedgeBook; signs: LongWord);
var
  n, sign, x, y, xo, yo, c, ss: Integer;
  m444, mc: PByte;
  sum: Integer;
begin
  for n := 0 to 15 do
  begin
    sign := signs and 1;
    m444 := Alloc(w * h);
    xo := 32 - ((w * cb[n].xoff) shr 3);
    yo := 32 - ((h * cb[n].yoff) shr 3);
    for y := 0 to h - 1 do
      for x := 0 to w - 1 do
        if sign <> 0 then m444[y*w + x] := 64 - master[cb[n].dir][(yo + y)*64 + xo + x]
        else m444[y*w + x] := master[cb[n].dir][(yo + y)*64 + xo + x];
    WedgeMasks[0][bsIdx][0][n] := m444;
    WedgeMasks[0][bsIdx][1][n] := m444;
    // chroma: c=1 is 4:2:2 (ss_ver=0), c=2 is 4:2:0 (ss_ver=1); [s] = rounding sign
    for c := 1 to 2 do
    begin
      ss := c - 1;
      for sign := 0 to 1 do
      begin
        mc := Alloc((w shr 1) * (h shr ss));
        y := 0;
        while y < h do
        begin
          x := 0;
          while x < w do
          begin
            sum := m444[y*w + x] + m444[y*w + x + 1] + 1;
            if ss <> 0 then Inc(sum, m444[(y+1)*w + x] + m444[(y+1)*w + x + 1] + 1);
            mc[(y shr ss) * (w shr 1) + (x shr 1)] := (sum - sign) shr (1 + ss);
            Inc(x, 2);
          end;
          Inc(y, 1 + ss);
        end;
        WedgeMasks[c][bsIdx][sign][n] := mc;
      end;
    end;
    signs := signs shr 1;
  end;
end;

function BuildNonDcII(w, h, step: Integer): PByte;
var x, y, a: Integer; mv, mh, ms: PByte;
begin
  Result := Alloc(3 * w * h);
  mv := Result; mh := Result + w*h; ms := Result + 2*w*h;
  for y := 0 to h - 1 do
  begin
    FillChar(mv[y*w], w, IIWeights1d[y * step]);
    for x := 0 to w - 1 do
    begin
      if x < y then a := x else a := y;
      ms[y*w + x] := IIWeights1d[a * step];
      mh[y*w + x] := IIWeights1d[x * step];
    end;
  end;
end;

procedure InitMasks;
var
  master: ^TMaster;
  y, x, ctr, c, p: Integer;
  dc, ii32x32, ii16x32, ii16x16, ii8x32, ii8x16, ii8x8, ii4x16, ii4x8, ii4x4: PByte;

  procedure AssignII(bs, w444, h444: Integer; m444: PByte; w422, h422: Integer; m422: PByte;
                     w420, h420: Integer; m420: PByte);
  var pp: Integer;
  begin
    for pp := 0 to 2 do
    begin
      IIMasks[0][bs - BS_32x32][pp + 1] := m444 + pp * w444 * h444;
      IIMasks[1][bs - BS_32x32][pp + 1] := m422 + pp * w422 * h422;
      IIMasks[2][bs - BS_32x32][pp + 1] := m420 + pp * w420 * h420;
    end;
  end;

begin
  SetLength(MaskStore, 600000);
  StorePos := 0;
  New(master);
  try
    FillChar(master^, SizeOf(TMaster), 0);
    for y := 0 to 63 do
      InsertBorder(@master^[WEDGE_VERTICAL][y*64], MasterBorder[2], 32);
    ctr := 48; y := 0;
    while y < 64 do
    begin
      InsertBorder(@master^[WEDGE_OBLIQUE63][y*64], MasterBorder[1], ctr);
      InsertBorder(@master^[WEDGE_OBLIQUE63][(y+1)*64], MasterBorder[0], ctr - 1);
      Inc(y, 2); Dec(ctr);
    end;
    for y := 0 to 63 do
      for x := 0 to 63 do
      begin
        master^[WEDGE_OBLIQUE27][x*64 + y] := master^[WEDGE_OBLIQUE63][y*64 + x];
        master^[WEDGE_HORIZONTAL][x*64 + y] := master^[WEDGE_VERTICAL][y*64 + x];
      end;
    for y := 0 to 63 do
      for x := 0 to 63 do
      begin
        master^[WEDGE_OBLIQUE117][y*64 + 63 - x] := master^[WEDGE_OBLIQUE63][y*64 + x];
        master^[WEDGE_OBLIQUE153][y*64 + 63 - x] := master^[WEDGE_OBLIQUE27][y*64 + x];
      end;

    BuildWedge(master^, 32, 32, BS_32x32 - BS_32x32, WedgeHeqw, $7bfb);
    BuildWedge(master^, 32, 16, BS_32x16 - BS_32x32, WedgeHltw, $7beb);
    BuildWedge(master^, 32,  8, BS_32x8  - BS_32x32, WedgeHltw, $6beb);
    BuildWedge(master^, 16, 32, BS_16x32 - BS_32x32, WedgeHgtw, $7beb);
    BuildWedge(master^, 16, 16, BS_16x16 - BS_32x32, WedgeHeqw, $7bfb);
    BuildWedge(master^, 16,  8, BS_16x8  - BS_32x32, WedgeHltw, $7beb);
    BuildWedge(master^,  8, 32, BS_8x32  - BS_32x32, WedgeHgtw, $7aeb);
    BuildWedge(master^,  8, 16, BS_8x16  - BS_32x32, WedgeHgtw, $7beb);
    BuildWedge(master^,  8,  8, BS_8x8   - BS_32x32, WedgeHeqw, $7bfb);
  finally
    Dispose(master);
  end;

  dc := Alloc(32 * 32);
  FillChar(dc^, 32 * 32, 32);
  for c := 0 to 2 do
    for p := 0 to 6 do
      IIMasks[c][IIBs[p] - BS_32x32][II_DC_PRED] := dc;

  ii32x32 := BuildNonDcII(32, 32, 1);
  ii16x32 := BuildNonDcII(16, 32, 1);
  ii16x16 := BuildNonDcII(16, 16, 2);
  ii8x32  := BuildNonDcII( 8, 32, 1);
  ii8x16  := BuildNonDcII( 8, 16, 2);
  ii8x8   := BuildNonDcII( 8,  8, 4);
  ii4x16  := BuildNonDcII( 4, 16, 2);
  ii4x8   := BuildNonDcII( 4,  8, 4);
  ii4x4   := BuildNonDcII( 4,  4, 8);
  AssignII(BS_32x32, 32, 32, ii32x32, 16, 32, ii16x32, 16, 16, ii16x16);
  AssignII(BS_32x16, 32, 32, ii32x32, 16, 16, ii16x16, 16, 16, ii16x16);
  AssignII(BS_16x32, 16, 32, ii16x32,  8, 32, ii8x32,   8, 16, ii8x16);
  AssignII(BS_16x16, 16, 16, ii16x16,  8, 16, ii8x16,   8,  8, ii8x8);
  AssignII(BS_16x8,  16, 16, ii16x16,  8,  8, ii8x8,    8,  8, ii8x8);
  AssignII(BS_8x16,   8, 16, ii8x16,   4, 16, ii4x16,   4,  8, ii4x8);
  AssignII(BS_8x8,    8,  8, ii8x8,    4,  8, ii4x8,    4,  4, ii4x4);
end;

initialization
  InitMasks;

end.
