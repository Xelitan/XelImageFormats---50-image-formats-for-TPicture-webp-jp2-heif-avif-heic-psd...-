unit XelJxr;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}
{$R-}{$Q-}{$B-}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	JPEG XR / HD Photo (.jxr/.wdp/.hdp) decoder                   //
// Version:	1.1 (Free Pascal port of jxrlib, BSD-2)                       //
// Date:	27-SEP-2026                                                   //
// License:     MIT (wrapper) / BSD-2 (jxrlib-derived codec)                  //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		Codec portions (c) Microsoft Corp., BSD-2 (see jxrlib LICENSE)  //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// Free Pascal port of the decoding path of Microsoft's jxrlib (BSD-2):
//   * container  - the "II 0xBC" TIFF-like package (JXRGlueJxr.c)
//   * header     - WMPHOTO codestream + image plane header (strdec.c)
//   * bit I/O    - MSB-first reader; jxrlib's packet ring buffer is only a
//                  streaming optimisation, its bit semantics are kept exactly
//   * entropy    - adaptive Huffman (adapthuff.c) and macroblock DC/LP/HP/CBP
//                  decoding (segdec.c)
//   * prediction - DC/AD/AC and CBP prediction, dequantisation
//                  (strPredQuant.c, strPredQuantDec.c)
//   * transform  - inverse PCT + overlap post filters, both the original and
//                  the "altered operators / hard tile" variant (strInvTransform.c)
//   * output     - 4:2:x chroma up-sampling, colour transforms and the per
//                  bit-depth sample reconstruction (strdec.c), then the
//                  jxrlib pixel-format-converter rules (JXRGluePFC.c) to RGBA8
// C's ">>" on signed values is arithmetic; Pascal's "shr" is logical, so every
// signed right shift goes through Asr().
//
// Supported: Y-only / YUV 4:2:0 / 4:2:2 / 4:4:4 / CMYK / N-component internal
// formats; RGB, gray, CMYK, RGBE sources; 1, 8, 16-bit, 16/32-bit fixed point,
// half and float (linear scRGB is converted to sRGB), 555 / 565 / 101010;
// interleaved and planar alpha; spatial and frequency bitstreams, tiles, all
// overlap modes, subband truncation, orientation.
// Output is straight RGBA8: YUV sources are up-sampled and converted (BT.601),
// premultiplied formats are un-premultiplied, and HDR sources whose highlights
// exceed SDR white are tone mapped (see JxrToneMapHDR).
// Verified bit-exact against jxrlib on the SAMPLE files plus 74 generated
// encodings covering all of the above, and against Windows' own WIC JPEG XR
// codec on 18 WIC-encoded files (565, 555, 101010, BGR32, BGRA32, Gray16,
// CMYK32, RGB128Float, PBGRA32, PRGBA64, PRGBA128Float).

interface

uses
  SysUtils, Classes, Math;

type
  EJxrError = class(Exception);

  // What the container layer resolves from a JPEG XR file.
  TJxrInfo = record
    Width, Height: Integer;
    PixelFormat: TGUID;        // container pixel format (GUID_PKPixelFormat* / WIC)
    Premultiplied: Boolean;    // colour is premultiplied by alpha (PBGRA/PRGBA)
    ImageOffset: Cardinal;
    ImageByteCount: Cardinal;
    AlphaOffset: Cardinal;     // planar alpha: a second, Y-only codestream
    AlphaByteCount: Cardinal;
    Valid: Boolean;
  end;

var
  // HDR sources (half / float / fixed point / RGBE) whose highlights exceed
  // SDR white (1.0 linear) are tone mapped instead of clipped. False gives
  // jxrlib's plain clip + sRGB conversion. SDR-range files are unaffected.
  JxrToneMapHDR: Boolean = True;
  // Linear level (of max(R,G,B)) below which values are kept unchanged.
  JxrToneMapKnee: Single = 0.75;
  // The highlight peak mapped to white is this percentile of max(R,G,B);
  // the brightest pixels above it clip.
  JxrToneMapPercentile: Single = 99.9;

// Parses the JXR container and fills Info (Valid=False if not a JXR file).
function JxrParseContainer(const InBuf: TBytes; out Info: TJxrInfo): Boolean;

// Decodes a JPEG XR file to RGBA8 (straight, non-premultiplied alpha).
function DecodeJxr(InBuf: TBytes; out Width, Height: Integer): TBytes;

implementation

type
  PInt = PInteger;
  TIntArr = array of Integer;

// C ">>" on a signed int (arithmetic shift, rounds toward -infinity)
function Asr(v, n: Integer): Integer; inline;
begin
  if v >= 0 then Result := v shr n
  else Result := not ((not v) shr n);
end;

function Clip8(v: Integer): Byte; inline;
begin
  if v < 0 then Result := 0
  else if v > 255 then Result := 255
  else Result := Byte(v);
end;

// ============================ container =================================

function U16(const D: TBytes; P: NativeUInt): Word; inline;
begin Result := Word(D[P]) or (Word(D[P+1]) shl 8); end;

function U32(const D: TBytes; P: NativeUInt): Cardinal; inline;
begin
  Result := Cardinal(D[P]) or (Cardinal(D[P+1]) shl 8) or
            (Cardinal(D[P+2]) shl 16) or (Cardinal(D[P+3]) shl 24);
end;

const
  // premultiplied-alpha pixel formats (JXRGlue.h, plus WIC's own GUIDs)
  PremulFormats: array[0..5] of TGUID = (
    '{6FDDC324-4E03-4BFE-B185-3D77768DC910}',   // 32bppPBGRA
    '{3CC4A650-A527-4D37-A916-3142C7EBEDBA}',   // 32bppPRGBA
    '{6FDDC324-4E03-4BFE-B185-3D77768DC917}',   // 64bppPRGBA
    '{6FDDC324-4E03-4BFE-B185-3D77768DC91A}',   // 128bppPRGBAFloat
    '{58AD26C2-C623-4D9D-B320-387E49F8C442}',   // WIC 64bppPRGBAHalf
    '{8C518E8E-A4EC-468B-AE70-C9A35A9C5530}');  // WIC 64bppPBGRA

function IsPremulFormat(const G: TGUID): Boolean;
var i: Integer;
begin
  for i := 0 to High(PremulFormats) do
    if IsEqualGUID(G, PremulFormats[i]) then Exit(True);
  Result := False;
end;

function JxrParseContainer(const InBuf: TBytes; out Info: TJxrInfo): Boolean;
var
  N, ifdOfs, entry: NativeUInt;
  count, i: Integer;
  tag: Word;
  cnt, valOfs: Cardinal;
begin
  FillChar(Info, SizeOf(Info), 0);
  Result := False;
  N := NativeUInt(Length(InBuf));
  if (N < 32) or (InBuf[0] <> Ord('I')) or (InBuf[1] <> Ord('I')) or (InBuf[2] <> $BC) then Exit;

  ifdOfs := U32(InBuf, 4);
  if (ifdOfs = 0) or (ifdOfs + 2 > N) then Exit;
  count := U16(InBuf, ifdOfs);
  for i := 0 to count - 1 do
  begin
    entry := ifdOfs + 2 + NativeUInt(i) * 12;
    if entry + 12 > N then Break;
    tag := U16(InBuf, entry);
    cnt := U32(InBuf, entry + 4);
    valOfs := U32(InBuf, entry + 8);
    case tag of
      $BC01:                                   // PixelFormat (16-byte GUID)
        if (cnt = 16) and (NativeUInt(valOfs) + 16 <= N) then
        begin
          Move(InBuf[valOfs], Info.PixelFormat, 16);   // on-disk layout = TGUID
          Info.Premultiplied := IsPremulFormat(Info.PixelFormat);
        end;
      $BC80: Info.Width := Integer(valOfs);    // ImageWidth
      $BC81: Info.Height := Integer(valOfs);   // ImageHeight
      $BCC0: Info.ImageOffset := valOfs;       // ImageOffset
      $BCC1: Info.ImageByteCount := valOfs;    // ImageByteCount
      $BCC2: Info.AlphaOffset := valOfs;       // AlphaOffset
      $BCC3: Info.AlphaByteCount := valOfs;    // AlphaByteCount
    end;
  end;

  Info.Valid := (Info.Width > 0) and (Info.Height > 0) and (Info.ImageOffset > 0);
  Result := Info.Valid;
end;

// ============================ constants =================================

const
  CF_Y_ONLY = 0; CF_YUV420 = 1; CF_YUV422 = 2; CF_YUV444 = 3; CF_CMYK = 4;
  CF_NCOMPONENT = 6; CF_RGB = 7;
  BD_1 = 0; BD_8 = 1; BD_16 = 2; BD_16S = 3; BD_16F = 4; BD_32 = 5; BD_32S = 6;
  BD_32F = 7; BD_5 = 8; BD_10 = 9; BD_565 = 10; BD_1alt = $f;
  BF_SPATIAL = 0; BF_FREQUENCY = 1;
  OL_NONE = 0; OL_ONE = 1; OL_TWO = 2;
  SB_ALL = 0; SB_NO_FLEXBITS = 1; SB_NO_HIGHPASS = 2; SB_DC_ONLY = 3; SB_ISOLATED = 4;
  LOG_MAX_TILES = 12;
  MAX_TILES = 1 shl LOG_MAX_TILES;
  MAX_CHANNELS = 16;
  MAX_PIXELS = UInt64(1) shl 28;   // 268M pixels (1 GB of RGBA output)
  CODEC_SUBVERSION = 0;
  CODEC_SUBVERSION_NEWSCALING_HARD_TILES = 9;
  CONTEXTX = 8; CTDC = 5; NUMVLCTABLES = 21;
  MAXTOTAL = 32767;
  SHIFTZERO = 1; QPFRACBITS = 2;
  BAND_DC = 1; BAND_LP = 2; BAND_AC = 3;
  AVG_NDIFF = 3;
  MODELWEIGHT = 70;
  ORIENT_WEIGHT = 4;
  THRESHOLD = 8; MEMORY = 8;

  cblkChromas: array[0..8] of Integer = (0, 4, 8, 16, 16, 16, 16, 0, 0);

  blkOffset: array[0..15] of Integer =
    (0, 64, 16, 80, 128, 192, 144, 208, 32, 96, 48, 112, 160, 224, 176, 240);
  blkOffsetUV: array[0..3] of Integer = (0, 32, 16, 48);
  blkOffsetUV_422: array[0..7] of Integer = (0, 64, 16, 80, 32, 96, 48, 112);

  dctIndex: array[0..2, 0..15] of Integer = (
    (0,5,1,6, 10,12,8,14, 2,4,3,7, 9,13,11,15),
    (0,5,1,6, 10,12,8,14, 2,4,3,7, 9,13,11,15),
    (0,128,64,208, 32,240,48,224, 16,192,80,144, 112,176,96,160));

  grgiZigzagInv4x4_lowpass: array[0..15] of Integer =
    (0, 1, 4, 5, 2, 8, 6, 9, 3, 12, 10, 7, 13, 11, 14, 15);
  grgiZigzagInv4x4H: array[0..15] of Integer =
    (0, 1, 4, 5, 2, 8, 6, 9, 3, 12, 10, 7, 13, 11, 14, 15);
  grgiZigzagInv4x4V: array[0..15] of Integer =
    (0, 4, 8, 5, 1, 12, 9, 6, 2, 13, 3, 15, 7, 10, 14, 11);

  // 16th entry mirrors the C out-of-bounds read of the next table (0)
  gSignificantRunBin: array[0..15] of Integer =
    (-1,-1,-1,-1, 2,2,2, 1,1,1,1, 0,0,0,0, 0);
  gSignificantRunFixedLength: array[0..14] of Integer =
    (0,0,1,1,3, 0,0,1,1,2, 0,0,0,0,1);

  idxCC: array[0..15, 0..15] of Byte = (
    ($00,$01,$05,$04, $40,$41,$45,$44, $80,$81,$85,$84, $c0,$c1,$c5,$c4),
    ($02,$03,$07,$06, $42,$43,$47,$46, $82,$83,$87,$86, $c2,$c3,$c7,$c6),
    ($0a,$0b,$0f,$0e, $4a,$4b,$4f,$4e, $8a,$8b,$8f,$8e, $ca,$cb,$cf,$ce),
    ($08,$09,$0d,$0c, $48,$49,$4d,$4c, $88,$89,$8d,$8c, $c8,$c9,$cd,$cc),
    ($10,$11,$15,$14, $50,$51,$55,$54, $90,$91,$95,$94, $d0,$d1,$d5,$d4),
    ($12,$13,$17,$16, $52,$53,$57,$56, $92,$93,$97,$96, $d2,$d3,$d7,$d6),
    ($1a,$1b,$1f,$1e, $5a,$5b,$5f,$5e, $9a,$9b,$9f,$9e, $da,$db,$df,$de),
    ($18,$19,$1d,$1c, $58,$59,$5d,$5c, $98,$99,$9d,$9c, $d8,$d9,$dd,$dc),
    ($20,$21,$25,$24, $60,$61,$65,$64, $a0,$a1,$a5,$a4, $e0,$e1,$e5,$e4),
    ($22,$23,$27,$26, $62,$63,$67,$66, $a2,$a3,$a7,$a6, $e2,$e3,$e7,$e6),
    ($2a,$2b,$2f,$2e, $6a,$6b,$6f,$6e, $aa,$ab,$af,$ae, $ea,$eb,$ef,$ee),
    ($28,$29,$2d,$2c, $68,$69,$6d,$6c, $a8,$a9,$ad,$ac, $e8,$e9,$ed,$ec),
    ($30,$31,$35,$34, $70,$71,$75,$74, $b0,$b1,$b5,$b4, $f0,$f1,$f5,$f4),
    ($32,$33,$37,$36, $72,$73,$77,$76, $b2,$b3,$b7,$b6, $f2,$f3,$f7,$f6),
    ($3a,$3b,$3f,$3e, $7a,$7b,$7f,$7e, $ba,$bb,$bf,$be, $fa,$fb,$ff,$fe),
    ($38,$39,$3d,$3c, $78,$79,$7d,$7c, $b8,$b9,$bd,$bc, $f8,$f9,$fd,$fc));

  idxCC_420: array[0..7, 0..7] of Byte = (
    ($00,$01,$05,$04, $20,$21,$25,$24),
    ($02,$03,$07,$06, $22,$23,$27,$26),
    ($0a,$0b,$0f,$0e, $2a,$2b,$2f,$2e),
    ($08,$09,$0d,$0c, $28,$29,$2d,$2c),
    ($10,$11,$15,$14, $30,$31,$35,$34),
    ($12,$13,$17,$16, $32,$33,$37,$36),
    ($1a,$1b,$1f,$1e, $3a,$3b,$3f,$3e),
    ($18,$19,$1d,$1c, $38,$39,$3d,$3c));

  // ---- adaptive Huffman decode tables (adapthuff.c) ----
  g4HuffLookupTable: array[0..39] of SmallInt = (
    19,19,19,19,27,27,27,27,10,10,10,10,10,10,10,10,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    0,0,0,0,0,0,0,0);

  g5HuffLookupTable: array[0..1, 0..41] of SmallInt = ((
    28,28,36,36,19,19,19,19,10,10,10,10,10,10,10,10,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    0,0,0,0,0,0,0,0,0,0), (
    11,11,11,11,19,19,19,19,27,27,27,27,35,35,35,35,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    0,0,0,0,0,0,0,0,0,0));

  g6HuffLookupTable: array[0..3, 0..43] of SmallInt = ((
    13,29,44,44,19,19,19,19,34,34,34,34,34,34,34,34,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    0,0,0,0,0,0,0,0,0,0,0,0), (
    12,12,28,28,43,43,43,43,2,2,2,2,2,2,2,2,
    18,18,18,18,18,18,18,18,34,34,34,34,34,34,34,34,
    0,0,0,0,0,0,0,0,0,0,0,0), (
    4,4,12,12,43,43,43,43,18,18,18,18,18,18,18,18,
    26,26,26,26,26,26,26,26,34,34,34,34,34,34,34,34,
    0,0,0,0,0,0,0,0,0,0,0,0), (
    5,13,36,36,43,43,43,43,18,18,18,18,18,18,18,18,
    25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,
    0,0,0,0,0,0,0,0,0,0,0,0));

  g7HuffLookupTable: array[0..1, 0..45] of SmallInt = ((
    45,53,36,36,27,27,27,27,2,2,2,2,2,2,2,2,
    10,10,10,10,10,10,10,10,18,18,18,18,18,18,18,18,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0), (
    -32736,37,28,28,19,19,19,19,10,10,10,10,10,10,10,10,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    5,6,0,0,0,0,0,0,0,0,0,0,0,0));

  g8HuffLookupTable: array[0..1, 0..47] of SmallInt = ((
    53,21,28,28,11,11,11,11,43,43,43,43,59,59,59,59,
    2,2,2,2,2,2,2,2,34,34,34,34,34,34,34,34,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0), (
    52,52,20,20,3,3,3,3,11,11,11,11,27,27,27,27,
    35,35,35,35,43,43,43,43,58,58,58,58,58,58,58,58,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0));

  g9HuffLookupTable: array[0..1, 0..49] of SmallInt = ((
    13,29,37,61,20,20,68,68,3,3,3,3,51,51,51,51,
    41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0), (
    -32736,53,28,28,11,11,11,11,19,19,19,19,43,43,43,43,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    -32734,4,7,8,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0));

  g12HuffLookupTable: array[0..4, 0..55] of SmallInt = ((
    -32736,5,76,76,37,53,69,85,43,43,43,43,91,91,91,91,
    57,57,57,57,57,57,57,57,57,57,57,57,57,57,57,57,
    -32734,1,2,3,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0), (
    -32736,85,13,53,4,4,36,36,43,43,43,43,67,67,67,67,
    75,75,75,75,91,91,91,91,58,58,58,58,58,58,58,58,
    2,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0), (
    -32736,37,92,92,11,11,11,11,43,43,43,43,59,59,59,59,
    67,67,67,67,75,75,75,75,2,2,2,2,2,2,2,2,
    -32734,-32732,2,3,6,10,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0), (
    -32736,29,37,69,3,3,3,3,43,43,43,43,59,59,59,59,
    75,75,75,75,91,91,91,91,10,10,10,10,10,10,10,10,
    -32734,10,2,6,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0), (
    -32736,93,28,28,60,60,76,76,3,3,3,3,43,43,43,43,
    9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
    -32734,-32732,-32730,2,4,8,6,10,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0));

  g5DeltaTable: array[0..4] of Integer = (0,-1,0,1,1);
  g6DeltaTable: array[0..17] of Integer = (
    -1, 1, 1, 1, 0, 1,
    -2, 0, 0, 2, 0, 0,
    -1,-1, 0, 1,-2, 0);
  g7DeltaTable: array[0..6] of Integer = (1,0,-1,-1,-1,-1,-1);
  g9DeltaTable: array[0..8] of Integer = (2,2,1,1,-1,-2,-2,-2,-3);
  g12DeltaTable: array[0..47] of Integer = (
     1, 1, 1, 1, 1, 0, 0,-1, 2, 1, 0, 0,
     2, 2,-1,-1,-1, 0,-2,-1, 0, 0,-2,-1,
    -1, 1, 0, 2, 0, 0, 0, 0,-2, 0, 1, 1,
     0, 1, 0, 1,-2, 0,-1,-1,-2,-1,-2,-2);

// ===================== codestream header (SimpleBitIO) ==================

type
  // Codestream parameters resolved from the WMPHOTO header + one plane header.
  TJxrCore = record
    Version, SubVersion: Integer;
    TilingPresent: Boolean;
    BitstreamFormat: Integer;
    Orientation: Integer;
    IndexTable: Boolean;
    Overlap: Integer;
    AbbreviatedHeader: Boolean;
    Inscribed, TrimFlexbits, TileStretch, RBSwapped, AlphaChannel: Boolean;
    CfColorFormatExt, BdBitDepthSrc: Integer;
    Width, Height: Integer;
    ExtraTop, ExtraLeft, ExtraBottom, ExtraRight: Integer;
    NumSliceV, NumSliceH: Integer;
    TileX, TileY: array[0..MAX_TILES] of Cardinal;
    CfColorFormat: Integer;
    ScaledArith: Boolean;
    Subband: Integer;
    NumChannels: Integer;
    ChromaCenteringX, ChromaCenteringY: Integer;
    LenMantissaOrShift, ExpBias: Integer;
    QPMode: Cardinal;
    QPIndexDC, QPIndexLP, QPIndexHP: array[0..MAX_CHANNELS - 1] of Byte;
  end;

  // MSB-first bit reader - jxrlib SimpleBitIO (getBit32_SB) semantics.
  TSBIO = record
    Data: PByte; Pos, Size: NativeInt;
    Acc: Byte; BitLeft: Integer; Read: NativeInt;
  end;

procedure SBReadByte(var s: TSBIO); inline;
begin
  if s.Pos < s.Size then begin s.Acc := s.Data[s.Pos]; Inc(s.Pos); end else s.Acc := 0;
  Inc(s.Read);
end;

function SBGetBits(var s: TSBIO; cBits: Integer): Cardinal;
begin
  Result := 0;
  while s.BitLeft < cBits do
  begin
    Result := Result shl s.BitLeft;
    Result := Result or (Cardinal(s.Acc) shr (8 - s.BitLeft));
    cBits := cBits - s.BitLeft;
    SBReadByte(s);
    s.BitLeft := 8;
  end;
  Result := Result shl cBits;
  Result := Result or (Cardinal(s.Acc) shr (8 - cBits));
  s.Acc := Byte(s.Acc shl cBits);
  s.BitLeft := s.BitLeft - cBits;
end;

procedure SBFlushToByte(var s: TSBIO); inline;
begin
  s.Acc := 0; s.BitLeft := 0;
end;

function ReadQuantizerSB(var QP: array of Byte; var s: TSBIO; cChannel: Integer): Byte;
var chMode: Byte; i: Integer;
begin
  chMode := 0;
  if cChannel >= MAX_CHANNELS then begin Result := 0; Exit; end;
  if cChannel > 1 then chMode := Byte(SBGetBits(s, 2));
  QP[0] := Byte(SBGetBits(s, 8));
  if chMode = 1 then QP[1] := Byte(SBGetBits(s, 8))
  else if chMode > 0 then
    for i := 1 to cChannel - 1 do QP[i] := Byte(SBGetBits(s, 8));
  Result := chMode;
end;

// strdec.c ReadImagePlaneHeader
function ReadImagePlaneHeader(var C: TJxrCore; var s: TSBIO): Boolean;
begin
  Result := False;
  C.CfColorFormat := Integer(SBGetBits(s, 3));
  if (C.CfColorFormat < CF_Y_ONLY) or (C.CfColorFormat > CF_NCOMPONENT) then Exit;
  C.ScaledArith := SBGetBits(s, 1) <> 0;
  C.Subband := Integer(SBGetBits(s, 4));

  case C.CfColorFormat of
    CF_Y_ONLY: C.NumChannels := 1;
    CF_YUV420:
      begin
        C.NumChannels := 3;
        SBGetBits(s, 1); C.ChromaCenteringX := Integer(SBGetBits(s, 3));
        SBGetBits(s, 1); C.ChromaCenteringY := Integer(SBGetBits(s, 3));
      end;
    CF_YUV422:
      begin
        C.NumChannels := 3;
        SBGetBits(s, 1); C.ChromaCenteringX := Integer(SBGetBits(s, 3));
        SBGetBits(s, 4);
      end;
    CF_YUV444:
      begin C.NumChannels := 3; SBGetBits(s, 4); SBGetBits(s, 4); end;
    CF_NCOMPONENT:
      begin C.NumChannels := Integer(SBGetBits(s, 4)) + 1; SBGetBits(s, 4); end;
    CF_CMYK: C.NumChannels := 4;
  end;

  case C.BdBitDepthSrc of
    BD_16, BD_16S, BD_32, BD_32S: C.LenMantissaOrShift := Integer(SBGetBits(s, 8));
    BD_32F: begin C.LenMantissaOrShift := Integer(SBGetBits(s, 8)); C.ExpBias := Integer(SBGetBits(s, 8)); end;
  end;

  C.QPMode := 0;
  if SBGetBits(s, 1) = 1 then
    C.QPMode := C.QPMode + (Cardinal(ReadQuantizerSB(C.QPIndexDC, s, C.NumChannels)) shl 3)
  else
    Inc(C.QPMode);
  if C.Subband <> SB_DC_ONLY then
  begin
    if SBGetBits(s, 1) = 0 then
    begin
      C.QPMode := C.QPMode + $200;
      if SBGetBits(s, 1) = 1 then
        C.QPMode := C.QPMode + (Cardinal(ReadQuantizerSB(C.QPIndexLP, s, C.NumChannels)) shl 5)
      else
        C.QPMode := C.QPMode + 2;
    end
    else
      C.QPMode := C.QPMode + ((C.QPMode and 1) shl 1) + ((C.QPMode and $18) shl 2);

    if C.Subband <> SB_NO_HIGHPASS then
    begin
      if SBGetBits(s, 1) = 0 then
      begin
        C.QPMode := C.QPMode + $400;
        if SBGetBits(s, 1) = 1 then
          C.QPMode := C.QPMode + (Cardinal(ReadQuantizerSB(C.QPIndexHP, s, C.NumChannels)) shl 7)
        else
          C.QPMode := C.QPMode + 4;
      end
      else
        C.QPMode := C.QPMode + ((C.QPMode and 2) shl 1) + ((C.QPMode and $60) shl 2);
    end;
  end;

  if C.Subband = SB_DC_ONLY then C.QPMode := C.QPMode or $200
  else if C.Subband = SB_NO_HIGHPASS then C.QPMode := C.QPMode or $400;
  if (C.QPMode and $600) = 0 then Exit;

  SBFlushToByte(s);
  Result := True;
end;

// strdec.c ReadWMIHeader. D points at the codestream ("WMPHOTO"); on success s
// is left byte-aligned just after the first plane header.
function ReadWMIHeader(D: PByte; DSize: NativeInt; var C: TJxrCore; var s: TSBIO): Boolean;
var
  i: Integer;
begin
  Result := False;
  FillChar(C, SizeOf(C), 0);
  if DSize < 16 then Exit;
  if not ((D[0] = Ord('W')) and (D[1] = Ord('M')) and (D[2] = Ord('P')) and
          (D[3] = Ord('H')) and (D[4] = Ord('O')) and (D[5] = Ord('T')) and
          (D[6] = Ord('O'))) then Exit;

  s.Data := D + 8; s.Size := DSize - 8;
  s.Pos := 0; s.Acc := 0; s.BitLeft := 0; s.Read := 0;

  C.Version := Integer(SBGetBits(s, 4));
  if C.Version <> 1 then Exit;
  C.SubVersion := Integer(SBGetBits(s, 4));

  C.TilingPresent := SBGetBits(s, 1) <> 0;
  C.BitstreamFormat := Integer(SBGetBits(s, 1));
  C.Orientation := Integer(SBGetBits(s, 3));
  C.IndexTable := SBGetBits(s, 1) <> 0;
  C.Overlap := Integer(SBGetBits(s, 2));
  if C.Overlap = 3 then Exit;

  C.AbbreviatedHeader := SBGetBits(s, 1) <> 0;
  SBGetBits(s, 1);                              // long-word flag (forced BD_LONG)
  C.Inscribed := SBGetBits(s, 1) <> 0;
  C.TrimFlexbits := SBGetBits(s, 1) <> 0;
  C.TileStretch := SBGetBits(s, 1) <> 0;
  C.RBSwapped := SBGetBits(s, 1) <> 0;
  SBGetBits(s, 1);                              // reserved
  C.AlphaChannel := SBGetBits(s, 1) <> 0;

  C.CfColorFormatExt := Integer(SBGetBits(s, 4));
  C.BdBitDepthSrc := Integer(SBGetBits(s, 4));
  if C.BdBitDepthSrc = BD_1alt then C.BdBitDepthSrc := BD_1;

  if C.AbbreviatedHeader then
  begin
    C.Width := Integer(SBGetBits(s, 16)) + 1;
    C.Height := Integer(SBGetBits(s, 16)) + 1;
  end
  else
  begin
    C.Width := Integer(SBGetBits(s, 32)) + 1;
    C.Height := Integer(SBGetBits(s, 32)) + 1;
  end;
  if (not C.Inscribed) and ((C.Width and $f) <> 0) then C.ExtraRight := $10 - (C.Width and $f);
  if (not C.Inscribed) and ((C.Height and $f) <> 0) then C.ExtraBottom := $10 - (C.Height and $f);

  if C.TilingPresent then
  begin
    C.NumSliceV := Integer(SBGetBits(s, LOG_MAX_TILES));
    C.NumSliceH := Integer(SBGetBits(s, LOG_MAX_TILES));
  end;
  if (not C.IndexTable) and ((C.BitstreamFormat = BF_FREQUENCY) or (C.NumSliceV + C.NumSliceH > 0)) then Exit;

  for i := 0 to C.NumSliceV - 1 do
    C.TileX[i + 1] := SBGetBits(s, IfThen(C.AbbreviatedHeader, 8, 16)) + C.TileX[i];
  for i := 0 to C.NumSliceH - 1 do
    C.TileY[i + 1] := SBGetBits(s, IfThen(C.AbbreviatedHeader, 8, 16)) + C.TileY[i];
  if C.TileStretch then
    for i := 0 to (C.NumSliceV + 1) * (C.NumSliceH + 1) - 1 do SBGetBits(s, 8);

  if C.Inscribed then
  begin
    C.ExtraTop := Integer(SBGetBits(s, 6));
    C.ExtraLeft := Integer(SBGetBits(s, 6));
    C.ExtraBottom := Integer(SBGetBits(s, 6));
    C.ExtraRight := Integer(SBGetBits(s, 6));
  end;

  if (((C.Width + C.ExtraLeft + C.ExtraRight) and $f) + ((C.Height + C.ExtraTop + C.ExtraBottom) and $f)) <> 0 then
  begin
    if ((C.Width and $f) + (C.Height and $f) + C.ExtraLeft + C.ExtraTop) <> 0 then Exit;
    if (C.Width <= C.ExtraRight) or (C.Height <= C.ExtraBottom) then Exit;
    C.Width := C.Width - C.ExtraRight;
    C.Height := C.Height - C.ExtraBottom;
  end;

  SBFlushToByte(s);
  if not ReadImagePlaneHeader(C, s) then Exit;
  Result := True;
end;

// ============================ bit reader ================================

type
  // MSB-first reader over the whole codestream (replaces jxrlib's packet
  // ring buffer; the bit semantics of peek/flush/get are identical).
  TBitIO = record
    D: PByte; Size: NativeInt; BytePos: NativeInt;
    Acc: UInt64; Cnt: Integer;
  end;
  PBitIO = ^TBitIO;

procedure BIOAttach(var b: TBitIO; D: PByte; Size, Pos: NativeInt);
begin
  b.D := D; b.Size := Size; b.BytePos := Pos; b.Acc := 0; b.Cnt := 0;
end;

procedure BIOFill(var b: TBitIO);
begin
  while b.Cnt <= 56 do
  begin
    if (b.BytePos >= 0) and (b.BytePos < b.Size) then
      b.Acc := (b.Acc shl 8) or UInt64(b.D[b.BytePos])
    else
      b.Acc := b.Acc shl 8;
    Inc(b.BytePos); Inc(b.Cnt, 8);
  end;
end;

function BPeek(var b: TBitIO; n: Integer): Cardinal; inline;
begin
  if n <= 0 then begin Result := 0; Exit; end;
  if b.Cnt < n then BIOFill(b);
  Result := Cardinal((b.Acc shr (b.Cnt - n)) and ((UInt64(1) shl n) - 1));
end;

procedure BFlush(var b: TBitIO; n: Integer); inline;
begin
  if n <= 0 then Exit;
  if b.Cnt < n then BIOFill(b);
  Dec(b.Cnt, n);
end;

function BGet(var b: TBitIO; n: Integer): Integer; inline;
begin
  Result := Integer(BPeek(b, n));
  BFlush(b, n);
end;

// _getSign: 0 for a 0-bit, -1 for a 1-bit
function BGetSign(var b: TBitIO): Integer; inline;
begin
  Result := -BGet(b, 1);
end;

// _getBit16s: cBits+1 bits = magnitude + trailing sign; 0 consumes only cBits
function BGetBit16s(var b: TBitIO; cBits: Integer): Integer;
var r: Integer;
begin
  r := Integer(BPeek(b, cBits + 1));
  r := (Asr(r, 1) xor (-(r and 1))) + (r and 1);
  BFlush(b, cBits + Ord(r <> 0));
  Result := r;
end;

function BPosRead(const b: TBitIO): NativeInt;
begin
  Result := (b.BytePos * 8 - b.Cnt) div 8;
end;

procedure BFlushToByte(var b: TBitIO);
var consumed: NativeInt;
begin
  consumed := b.BytePos * 8 - b.Cnt;
  BFlush(b, Integer((8 - (consumed and 7)) and 7));
end;

// decode.h getHuff (5-bit root table, then a binary tree for long codes)
function GetHuff(Tbl: PSmallInt; var b: TBitIO): Integer;
var iSymbol, iSymbolHuff: Integer;
begin
  iSymbol := Tbl[BPeek(b, 5)];
  if iSymbol < 0 then BFlush(b, 5) else BFlush(b, iSymbol and 7);
  iSymbolHuff := Asr(iSymbol, 3);
  if iSymbolHuff < 0 then
  begin
    iSymbolHuff := iSymbol;
    repeat
      iSymbolHuff := Tbl[iSymbolHuff + 32768 + BGet(b, 1)];
    until iSymbolHuff >= 0;
  end;
  Result := iSymbolHuff;
end;

function GetHuffShort(Tbl: PSmallInt; var b: TBitIO): Integer; inline;
var s: Integer;
begin
  s := Tbl[BPeek(b, 5)];
  BFlush(b, s and 7);
  Result := Asr(s, 3);
end;

// ========================= adaptive Huffman =============================

type
  TAdHuff = record
    NSymbols, TableIndex, Discriminant, Discriminant1: Integer;
    UpperBound, LowerBound: Integer;
    Initialize: Boolean;
    DecTable: PSmallInt;
    Delta, Delta1: PInteger;
  end;
  PAdHuff = ^TAdHuff;

procedure AdaptDiscriminant(var h: TAdHuff);
const
  gMaxTables: array[0..12] of Integer = (0,0,0,0, 1,2, 4,2, 2,2, 0,0,5);
  gSecondDisc: array[0..12] of Integer = (0,0,0,0, 0,0, 1,0, 0,0, 0,0,1);
var
  iSym, t, dL, dH: Integer;
  bChange: Boolean;
begin
  iSym := h.NSymbols;
  bChange := False;
  if not h.Initialize then
  begin
    h.Initialize := True;
    h.Discriminant := 0; h.Discriminant1 := 0;
    h.TableIndex := gSecondDisc[iSym];
  end;
  dL := h.Discriminant; dH := h.Discriminant;
  if gSecondDisc[iSym] <> 0 then dH := h.Discriminant1;
  if dL < h.LowerBound then begin Dec(h.TableIndex); bChange := True; end
  else if dH > h.UpperBound then begin Inc(h.TableIndex); bChange := True; end;
  if bChange then begin h.Discriminant := 0; h.Discriminant1 := 0; end;
  if h.Discriminant < -THRESHOLD * MEMORY then h.Discriminant := -THRESHOLD * MEMORY
  else if h.Discriminant > THRESHOLD * MEMORY then h.Discriminant := THRESHOLD * MEMORY;
  if h.Discriminant1 < -THRESHOLD * MEMORY then h.Discriminant1 := -THRESHOLD * MEMORY
  else if h.Discriminant1 > THRESHOLD * MEMORY then h.Discriminant1 := THRESHOLD * MEMORY;

  t := h.TableIndex;
  if t < 0 then t := 0;
  if (gMaxTables[iSym] > 0) and (t > gMaxTables[iSym] - 1) then t := gMaxTables[iSym] - 1;
  h.TableIndex := t;
  if t = 0 then h.LowerBound := Low(Integer) else h.LowerBound := -THRESHOLD;
  if t = gMaxTables[iSym] - 1 then h.UpperBound := 1 shl 30 else h.UpperBound := THRESHOLD;

  case iSym of
    4: begin h.DecTable := @g4HuffLookupTable[0]; h.Delta := nil; end;
    5: begin h.DecTable := @g5HuffLookupTable[t, 0]; h.Delta := @g5DeltaTable[0]; end;
    6: begin
         h.Delta1 := @g6DeltaTable[iSym * (t - Ord(t + 1 = gMaxTables[iSym]))];
         h.Delta := @g6DeltaTable[(t - 1 + Ord(t = 0)) * iSym];
         h.DecTable := @g6HuffLookupTable[t, 0];
       end;
    7: begin h.DecTable := @g7HuffLookupTable[t, 0]; h.Delta := @g7DeltaTable[0]; end;
    8: begin h.DecTable := @g8HuffLookupTable[0, 0]; h.Delta := nil; end;
    9: begin h.DecTable := @g9HuffLookupTable[t, 0]; h.Delta := @g9DeltaTable[0]; end;
    12: begin
          h.Delta1 := @g12DeltaTable[iSym * (t - Ord(t + 1 = gMaxTables[iSym]))];
          h.Delta := @g12DeltaTable[(t - 1 + Ord(t = 0)) * iSym];
          h.DecTable := @g12HuffLookupTable[t, 0];
        end;
  end;
end;

// ========================== coding context ==============================

type
  TAdaptiveScan = record
    uTotal, uScan: Cardinal;
  end;
  PAdaptiveScan = ^TAdaptiveScan;

  TAdaptiveModel = record
    FlcState, FlcBits: array[0..1] of Integer;
    Band: Integer;
  end;

  TCBPModel = record
    Count0, Count1, State: array[0..1] of Integer;
  end;

  TCodingContext = record
    IODC, IOLP, IOAC, IOFL: PBitIO;
    AHCBPCY, AHCBPCY1: TAdHuff;
    AHexpt: array[0..NUMVLCTABLES - 1] of TAdHuff;
    ScanLowpass, ScanHoriz, ScanVert: array[0..15] of TAdaptiveScan;
    ModelAC, ModelLP, ModelDC: TAdaptiveModel;
    CBPCountZero, CBPCountMax: Integer;
    CBPModel: TCBPModel;
    TrimFlexBits: Integer;
  end;
  PCodingContext = ^TCodingContext;

procedure AdaptLowpassDec(var ctx: TCodingContext);
var kk: Integer;
begin
  for kk := 0 to CONTEXTX + CTDC - 1 do AdaptDiscriminant(ctx.AHexpt[kk]);
end;

procedure AdaptHighpassDec(var ctx: TCodingContext);
var kk: Integer;
begin
  AdaptDiscriminant(ctx.AHCBPCY);
  AdaptDiscriminant(ctx.AHCBPCY1);
  for kk := 0 to CONTEXTX - 1 do AdaptDiscriminant(ctx.AHexpt[kk + CONTEXTX + CTDC]);
end;

procedure InitZigzagScan(var ctx: TCodingContext);
var i: Integer;
begin
  for i := 0 to 15 do
  begin
    ctx.ScanLowpass[i].uScan := grgiZigzagInv4x4_lowpass[i];
    ctx.ScanHoriz[i].uScan := dctIndex[0, grgiZigzagInv4x4H[i]];
    ctx.ScanVert[i].uScan := dctIndex[0, grgiZigzagInv4x4V[i]];
  end;
end;

procedure ResetCodingContext(var ctx: TCodingContext);
begin
  FillChar(ctx.ModelAC, SizeOf(ctx.ModelAC), 0); ctx.ModelAC.Band := BAND_AC;
  FillChar(ctx.ModelLP, SizeOf(ctx.ModelLP), 0); ctx.ModelLP.Band := BAND_LP;
  ctx.ModelLP.FlcBits[0] := 4; ctx.ModelLP.FlcBits[1] := 4;
  FillChar(ctx.ModelDC, SizeOf(ctx.ModelDC), 0); ctx.ModelDC.Band := BAND_DC;
  ctx.ModelDC.FlcBits[0] := 8; ctx.ModelDC.FlcBits[1] := 8;
  ctx.CBPCountMax := 1; ctx.CBPCountZero := 1;
  ctx.CBPModel.Count0[0] := -4; ctx.CBPModel.Count0[1] := -4;
  ctx.CBPModel.Count1[0] := 4; ctx.CBPModel.Count1[1] := 4;
  ctx.CBPModel.State[0] := 0; ctx.CBPModel.State[1] := 0;
end;

procedure ResetCodingContextDec(var ctx: TCodingContext);
var k: Integer;
begin
  ctx.AHCBPCY.Initialize := False;
  ctx.AHCBPCY1.Initialize := False;
  for k := 0 to NUMVLCTABLES - 1 do ctx.AHexpt[k].Initialize := False;
  AdaptLowpassDec(ctx);
  AdaptHighpassDec(ctx);
  InitZigzagScan(ctx);
  ResetCodingContext(ctx);
end;

procedure AllocateCodingContext(var ctx: TCodingContext; cf: Integer);
const
  aAlphabet: array[0..20] of Integer = (5,4,8,7,7, 12,6,6,12,6,6,7,7, 12,6,6,12,6,6,7,7);
var k, iCBPSize: Integer;
begin
  FillChar(ctx, SizeOf(ctx), 0);
  if (cf = CF_Y_ONLY) or (cf = CF_NCOMPONENT) or (cf = CF_CMYK) then iCBPSize := 5 else iCBPSize := 9;
  ctx.AHCBPCY.NSymbols := iCBPSize;
  ctx.AHCBPCY1.NSymbols := 5;
  for k := 0 to NUMVLCTABLES - 1 do ctx.AHexpt[k].NSymbols := aAlphabet[k];
  ResetCodingContextDec(ctx);
end;

// image.c UpdateModelMB
procedure UpdateModelMB(cf, iChannels: Integer; var LM: array of Integer; var M: TAdaptiveModel);
const
  aWeight0: array[0..2] of Integer = (240, 12, 1);
  aWeight1: array[0..2, 0..15] of Integer = (
    (0,240,120,80, 60,48,40,34, 30,27,24,22, 20,18,17,16),
    (0,12,6,4,     3,2,2,2,     2,1,1,1,     1,1,1,1),
    (0,16,8,5,     4,3,3,2,     2,2,2,1,     1,1,1,1));
  aWeight2: array[0..5] of Integer = (120, 37, 2, 120, 18, 1);
var j, iLM, iMS, iDelta: Integer;
begin
  LM[0] := LM[0] * aWeight0[M.Band - BAND_DC];
  if cf = CF_YUV420 then
    LM[1] := LM[1] * aWeight2[M.Band - BAND_DC]
  else if cf = CF_YUV422 then
    LM[1] := LM[1] * aWeight2[3 + M.Band - BAND_DC]
  else
  begin
    LM[1] := LM[1] * aWeight1[M.Band - BAND_DC, iChannels - 1];
    if M.Band = BAND_AC then LM[1] := Asr(LM[1], 4);
  end;

  for j := 0 to 1 do
  begin
    iLM := LM[j];
    iMS := M.FlcState[j];
    iDelta := Asr(iLM - MODELWEIGHT, 2);
    if iDelta <= -8 then
    begin
      iDelta := iDelta + 4;
      if iDelta < -16 then iDelta := -16;
      iMS := iMS + iDelta;
      if iMS < -8 then
      begin
        if M.FlcBits[j] = 0 then iMS := -8
        else begin iMS := 0; Dec(M.FlcBits[j]); end;
      end;
    end
    else if iDelta >= 8 then
    begin
      iDelta := iDelta - 4;
      if iDelta > 15 then iDelta := 15;
      iMS := iMS + iDelta;
      if iMS > 8 then
      begin
        if M.FlcBits[j] >= 15 then begin M.FlcBits[j] := 15; iMS := 8; end
        else begin iMS := 0; Inc(M.FlcBits[j]); end;
      end;
    end;
    M.FlcState[j] := iMS;
    if cf = CF_Y_ONLY then Break;
  end;
end;

// ============================ quantizers ================================

type
  TQuantizer = record
    Index: Integer;
    QP: Integer;
  end;
  TQArr = array of TQuantizer;
  TQChan = array[0..MAX_CHANNELS - 1] of TQArr;

  TTile = record
    QDC, QLP, QHP: TQChan;
    cNumQPLP, cNumQPHP, cBitsLP, cBitsHP: Integer;
    bUseDC, bUseLP: Boolean;
    cChModeDC: Integer;
    cChModeLP, cChModeHP: array[0..15] of Integer;
  end;
  PTile = ^TTile;

// strPredQuant.c remapQP (only the reconstruction step size is needed)
procedure RemapQP(var Q: TQuantizer; iShift: Integer; bScaledArith: Boolean);
var man, ex: Integer;
begin
  if Q.Index = 0 then begin Q.QP := 1; Exit; end;       // lossless
  if not bScaledArith then
  begin
    if Q.Index < 32 then
    begin man := Asr(Q.Index + 3, 2); ex := 0; end
    else if Q.Index < 48 then
    begin man := Asr(16 + (Q.Index and $f) + 1, 1); ex := (Q.Index shr 4) - 2; end
    else
    begin man := 16 + (Q.Index and $f); ex := (Q.Index shr 4) - 3; end;
  end
  else
  begin
    if Q.Index < 16 then begin man := Q.Index; ex := iShift; end
    else begin man := 16 + (Q.Index and $f); ex := ((Q.Index shr 4) - 1) + iShift; end;
  end;
  if ex < 0 then ex := 0;
  Q.QP := man shl ex;
end;

procedure FormatQuantizer(var Q: TQChan; chMode, cCh, iPos: Integer;
  bShiftedUV, bScaledArith: Boolean);
var iCh, sh: Integer;
begin
  for iCh := 0 to cCh - 1 do
  begin
    if iCh > 0 then
      if chMode = 0 then Q[iCh][iPos] := Q[0][iPos]
      else if chMode = 1 then Q[iCh][iPos] := Q[1][iPos];
    if (iCh > 0) and bShiftedUV then sh := SHIFTZERO - 1 else sh := SHIFTZERO;
    RemapQP(Q[iCh][iPos], sh, bScaledArith);
  end;
end;

procedure AllocQuantizer(var Q: TQChan; cCh, cQP: Integer);
var i: Integer;
begin
  for i := 0 to MAX_CHANNELS - 1 do Q[i] := nil;
  for i := 0 to cCh - 1 do SetLength(Q[i], cQP);
end;

function ReadQuantizer(var Q: TQChan; var io: TBitIO; cCh, iPos: Integer): Integer;
var chMode, i: Integer;
begin
  chMode := 0;
  if cCh > 1 then chMode := BGet(io, 2);
  Q[0][iPos].Index := BGet(io, 8);
  if chMode = 1 then Q[1][iPos].Index := BGet(io, 8)
  else if chMode > 0 then
    for i := 1 to cCh - 1 do Q[i][iPos].Index := BGet(io, 8);
  Result := chMode;
end;

function DQuantBits(cQP: Integer): Integer;
begin
  if cQP < 2 then Result := 0
  else if cQP < 4 then Result := 1
  else if cQP < 6 then Result := 2
  else if cQP < 10 then Result := 3
  else Result := 4;
end;

function DecodeQPIndex(var io: TBitIO; cBits: Integer): Integer;
begin
  if BGet(io, 1) = 0 then Result := 0
  else Result := BGet(io, cBits) + 1;
end;

// ====================== entropy decode helpers ==========================

function DecodeSignificantAbsLevel(var h: TAdHuff; var io: TBitIO): Integer;
const
  aRemap: array[0..5] of Integer = (2, 3, 4, 6, 10, 14);
  aFixedLength: array[0..5] of Integer = (0, 0, 1, 2, 2, 2);
var iIndex, iFixed: Integer;
begin
  iIndex := GetHuff(h.DecTable, io);
  if iIndex > 6 then iIndex := 6;
  h.Discriminant := h.Discriminant + h.Delta[iIndex];
  if iIndex < 2 then
    Result := iIndex + 2
  else if iIndex < 6 then
    Result := aRemap[iIndex] + BGet(io, aFixedLength[iIndex])
  else
  begin
    iFixed := BGet(io, 4) + 4;
    if iFixed = 19 then
    begin
      iFixed := iFixed + BGet(io, 2);
      if iFixed = 22 then iFixed := iFixed + BGet(io, 3);
    end;
    Result := 2 + (1 shl iFixed);
    Result := Result + BGet(io, iFixed);
  end;
end;

function DecodeSignificantRun(iMaxRun: Integer; var h: TAdHuff; var io: TBitIO): Integer;
const
  aRemap: array[0..14] of Integer = (1,2,3,5,7, 1,2,3,5,7, 1,2,3,4,5);
var iIndex, iBin, iRun, iFLC: Integer;
begin
  if iMaxRun < 5 then
  begin
    if iMaxRun <= 1 then Exit(1)
    else if BGet(io, 1) <> 0 then Exit(1)
    else if (iMaxRun = 2) or (BGet(io, 1) <> 0) then Exit(2)
    else if (iMaxRun = 3) or (BGet(io, 1) <> 0) then Exit(3);
    Exit(4);
  end;
  if iMaxRun > 15 then iMaxRun := 15;
  iBin := gSignificantRunBin[iMaxRun];
  iIndex := GetHuffShort(h.DecTable, io);
  iIndex := iIndex + iBin * 5;
  if iIndex < 0 then iIndex := 0 else if iIndex > 14 then iIndex := 14;
  iRun := aRemap[iIndex];
  iFLC := gSignificantRunFixedLength[iIndex];
  if iFLC <> 0 then iRun := iRun + BGet(io, iFLC);
  Result := iRun;
end;

procedure DecodeFirstIndex(out iIndex: Integer; var h: TAdHuff; var io: TBitIO);
begin
  iIndex := GetHuff(h.DecTable, io);
  if iIndex < 0 then iIndex := 0 else if iIndex > 11 then iIndex := 11;
  h.Discriminant := h.Discriminant + h.Delta[iIndex];
  h.Discriminant1 := h.Discriminant1 + h.Delta1[iIndex];
end;

procedure DecodeIndex(out iIndex: Integer; iLoc: Integer; var h: TAdHuff; var io: TBitIO);
begin
  if iLoc < 15 then
  begin
    iIndex := GetHuffShort(h.DecTable, io);
    if iIndex < 0 then iIndex := 0 else if iIndex > 5 then iIndex := 5;
    h.Discriminant := h.Discriminant + h.Delta[iIndex];
    h.Discriminant1 := h.Discriminant1 + h.Delta1[iIndex];
  end
  else if iLoc = 15 then
  begin
    if BGet(io, 1) = 0 then iIndex := 0
    else if BGet(io, 1) = 0 then iIndex := 2
    else iIndex := 1 + 2 * BGet(io, 1);
  end
  else
    iIndex := BGet(io, 1);
end;

// segdec.c DecodeBlock (lowpass run/level pairs)
function DecodeBlock(bChroma: Boolean; var aLocalCoef: array of Integer;
  var ctx: TCodingContext; iContextOffset: Integer; var io: TBitIO;
  iLocation: Integer): Integer;
var
  iSR, iSRn, iIndex, iNumNonzero, iCont, iSign, base: Integer;
begin
  base := iContextOffset + Ord(bChroma) * 3;
  DecodeFirstIndex(iIndex, ctx.AHexpt[base], io);
  iSR := iIndex and 1;
  iSRn := iIndex shr 2;
  iCont := iSR and iSRn;
  iSign := BGetSign(io);
  if (iIndex and 2) <> 0 then
    aLocalCoef[1] := (DecodeSignificantAbsLevel(ctx.AHexpt[6 + iContextOffset + iCont], io) xor iSign) - iSign
  else
    aLocalCoef[1] := 1 or iSign;
  aLocalCoef[0] := 0;
  if iSR = 0 then
    aLocalCoef[0] := DecodeSignificantRun(15 - iLocation, ctx.AHexpt[0], io);
  iLocation := iLocation + aLocalCoef[0] + 1;
  iNumNonzero := 1;
  while (iSRn <> 0) and (iNumNonzero < 16) do
  begin
    iSR := iSRn and 1;
    aLocalCoef[iNumNonzero * 2] := 0;
    if iSR = 0 then
      aLocalCoef[iNumNonzero * 2] := DecodeSignificantRun(15 - iLocation, ctx.AHexpt[0], io);
    iLocation := iLocation + aLocalCoef[iNumNonzero * 2] + 1;
    DecodeIndex(iIndex, iLocation, ctx.AHexpt[base + iCont + 1], io);
    iSRn := iIndex shr 1;
    iCont := iCont and iSRn;
    iSign := BGetSign(io);
    if (iIndex and 1) <> 0 then
      aLocalCoef[iNumNonzero * 2 + 1] :=
        (DecodeSignificantAbsLevel(ctx.AHexpt[6 + iContextOffset + iCont], io) xor iSign) - iSign
    else
      aLocalCoef[iNumNonzero * 2 + 1] := 1 or iSign;
    Inc(iNumNonzero);
  end;
  Result := iNumNonzero;
end;

procedure SwapScan(pScan: PAdaptiveScan; i: Integer); inline;
var t: TAdaptiveScan;
begin
  t := pScan[i]; pScan[i] := pScan[i - 1]; pScan[i - 1] := t;
end;

// segdec.c DecodeBlockHighpass
function DecodeBlockHighpass(bChroma: Boolean; var ctx: TCodingContext; var io: TBitIO;
  iQP: Integer; pCoef: PInt; pScan: PAdaptiveScan): Integer;
const
  iContextOffset = CTDC + CONTEXTX;
var
  iLoc, iSR, iSRn, iIndex, iNumNonzero, iCont, iSign, iLevel, base: Integer;
begin
  base := iContextOffset + Ord(bChroma) * 3;
  iLoc := 1;
  DecodeFirstIndex(iIndex, ctx.AHexpt[base], io);
  iSR := iIndex and 1;
  iSRn := iIndex shr 2;
  iCont := iSR and iSRn;
  iSign := BGetSign(io);
  iLevel := (iQP xor iSign) - iSign;
  if (iIndex and 2) <> 0 then
    iLevel := iLevel * DecodeSignificantAbsLevel(ctx.AHexpt[6 + iContextOffset + iCont], io);
  if iSR = 0 then
    iLoc := iLoc + DecodeSignificantRun(15 - iLoc, ctx.AHexpt[0], io);
  iLoc := iLoc and $f;
  pCoef[pScan[iLoc].uScan] := iLevel;
  Inc(pScan[iLoc].uTotal);
  if (iLoc <> 0) and (pScan[iLoc].uTotal > pScan[iLoc - 1].uTotal) then SwapScan(pScan, iLoc);
  iLoc := (iLoc + 1) and $f;
  iNumNonzero := 1;
  while iSRn <> 0 do
  begin
    iSR := iSRn and 1;
    if iSR = 0 then
    begin
      iLoc := iLoc + DecodeSignificantRun(15 - iLoc, ctx.AHexpt[0], io);
      if iLoc >= 16 then Exit(16);
    end;
    DecodeIndex(iIndex, iLoc + 1, ctx.AHexpt[base + iCont + 1], io);
    iSRn := iIndex shr 1;
    iCont := iCont and iSRn;
    iSign := BGetSign(io);
    iLevel := (iQP xor iSign) - iSign;
    if (iIndex and 1) <> 0 then
      iLevel := iLevel * DecodeSignificantAbsLevel(ctx.AHexpt[6 + iContextOffset + iCont], io);
    pCoef[pScan[iLoc].uScan] := iLevel;
    Inc(pScan[iLoc].uTotal);
    if (iLoc <> 0) and (pScan[iLoc].uTotal > pScan[iLoc - 1].uTotal) then SwapScan(pScan, iLoc);
    iLoc := (iLoc + 1) and $f;
    Inc(iNumNonzero);
    if iNumNonzero > 16 then Break;
  end;
  Result := iNumNonzero;
end;

// segdec.c DecodeBlockAdaptive (HP coefficients + flexbits refinement)
function DecodeBlockAdaptive(bNoSkip, bChroma: Boolean; var ctx: TCodingContext;
  io, ioFL: PBitIO; pCoeffs: PInt; pScan: PAdaptiveScan;
  iModelBits, iTrim, iQP: Integer; bSkipFlexbits: Boolean): Integer;
var
  k, kk, iFlex, iNumNonzero, iQP1, fine: Integer;
  pk: PInt;
begin
  iNumNonzero := 0;
  iFlex := iModelBits - iTrim;
  if (iFlex < 0) or bSkipFlexbits then iFlex := 0;
  if bNoSkip then
  begin
    iQP1 := iQP shl iModelBits;
    iNumNonzero := DecodeBlockHighpass(bChroma, ctx, io^, iQP1, pCoeffs, pScan);
  end;
  if iFlex <> 0 then
  begin
    if iQP + iTrim = 1 then
    begin
      for k := 1 to 15 do
      begin
        pk := pCoeffs + dctIndex[0, k];
        if pk^ < 0 then begin fine := BGet(ioFL^, iFlex); pk^ := pk^ - fine; end
        else if pk^ > 0 then begin fine := BGet(ioFL^, iFlex); pk^ := pk^ + fine; end
        else pk^ := BGetBit16s(ioFL^, iFlex);
      end;
    end
    else
    begin
      iQP1 := iQP shl iTrim;
      for k := 1 to 15 do
      begin
        kk := pCoeffs[dctIndex[0, k]];
        if kk < 0 then
        begin
          fine := BGet(ioFL^, iFlex);
          pCoeffs[dctIndex[0, k]] := pCoeffs[dctIndex[0, k]] - iQP1 * fine;
        end
        else if kk > 0 then
        begin
          fine := BGet(ioFL^, iFlex);
          pCoeffs[dctIndex[0, k]] := pCoeffs[dctIndex[0, k]] + iQP1 * fine;
        end
        else
          pCoeffs[dctIndex[0, k]] := iQP1 * BGetBit16s(ioFL^, iFlex);
      end;
    end;
  end;
  Result := iNumNonzero;
end;

// ======================= transform primitives ===========================

procedure strDCT2x2dn(pa, pb, pc, pd: PInt);
var a, b, c, d, CC, t: Integer;
begin
  a := pa^; b := pb^; CC := pc^; d := pd^;
  a := a + d;
  b := b - CC;
  t := Asr(a - b, 1);
  c := t - d;
  d := t - CC;
  a := a - d;
  b := b + c;
  pa^ := a; pb^ := b; pc^ := c; pd^ := d;
end;

procedure strDCT2x2up(pa, pb, pc, pd: PInt);
var a, b, c, d, CC, t: Integer;
begin
  a := pa^; b := pb^; CC := pc^; d := pd^;
  a := a + d;
  b := b - CC;
  t := Asr(a - b + 1, 1);
  c := t - d;
  d := t - CC;
  a := a - d;
  b := b + c;
  pa^ := a; pb^ := b; pc^ := c; pd^ := d;
end;

procedure strDCT2x2dnDec(pa, pb, pc, pd: PInt);
var a, b, c, d, CC, t: Integer;
begin
  a := pa^; b := pb^; CC := pc^; d := pd^;
  a := a + d;
  b := b - CC;
  t := Asr(a - b, 1);
  c := t - d;
  d := t - CC;
  a := a - d;
  b := b + c;
  pa^ := a * 2; pb^ := b * 2; pc^ := c * 2; pd^ := d * 2;
end;

procedure IRot1(pa, pb: PInt); inline;              // IROTATE1 on memory
begin
  pa^ := pa^ - Asr(pb^ + 1, 1);
  pb^ := pb^ + Asr(pa^ + 1, 1);
end;

procedure invOdd(pa, pb, pc, pd: PInt);
var a, b, c, d: Integer;
begin
  a := pa^; b := pb^; c := pc^; d := pd^;
  b := b + d;
  a := a - c;
  d := d - Asr(b, 1);
  c := c + Asr(a + 1, 1);
  // IROTATE2(a, b); IROTATE2(c, d)
  a := a - Asr(b * 3 + 4, 3); b := b + Asr(a * 3 + 4, 3);
  c := c - Asr(d * 3 + 4, 3); d := d + Asr(c * 3 + 4, 3);
  c := c - Asr(b + 1, 1);
  d := Asr(a + 1, 1) - d;
  b := b + c;
  a := a - d;
  pa^ := a; pb^ := b; pc^ := c; pd^ := d;
end;

procedure invOddOdd(pa, pb, pc, pd: PInt);
var a, b, c, d, t1, t2: Integer;
begin
  a := pa^; b := pb^; c := pc^; d := pd^;
  d := d + a;
  c := c - b;
  t1 := Asr(d, 1); a := a - t1;
  t2 := Asr(c, 1); b := b + t2;
  a := a - Asr(b * 3 + 3, 3);
  b := b + Asr(a * 3 + 3, 2);
  a := a - Asr(b * 3 + 4, 3);
  b := b - t2;
  a := a + t1;
  c := c + b;
  d := d - a;
  pa^ := a; pb^ := -b; pc^ := -c; pd^ := d;
end;

procedure invOddOddPost(pa, pb, pc, pd: PInt);
var a, b, c, d, t1, t2: Integer;
begin
  a := pa^; b := pb^; c := pc^; d := pd^;
  d := d + a;
  c := c - b;
  t1 := Asr(d, 1); a := a - t1;
  t2 := Asr(c, 1); b := b + t2;
  a := a - Asr(b * 3 + 6, 3);
  b := b + Asr(a * 3 + 2, 2);
  a := a - Asr(b * 3 + 4, 3);
  b := b - t2;
  a := a + t1;
  c := c + b;
  d := d - a;
  pa^ := a; pb^ := b; pc^ := c; pd^ := d;
end;

procedure FourButterfly(p: PInt; i00, i01, i02, i03, i10, i11, i12, i13,
  i20, i21, i22, i23, i30, i31, i32, i33: Integer);
begin
  strDCT2x2dn(p + i00, p + i01, p + i02, p + i03);
  strDCT2x2dn(p + i10, p + i11, p + i12, p + i13);
  strDCT2x2dn(p + i20, p + i21, p + i22, p + i23);
  strDCT2x2dn(p + i30, p + i31, p + i32, p + i33);
end;

procedure strIDCT4x4Stage1(p: PInt);
begin
  strDCT2x2up(p + 0, p + 1, p + 2, p + 3);
  invOdd(p + 5, p + 4, p + 7, p + 6);
  invOdd(p + 10, p + 8, p + 11, p + 9);
  invOddOdd(p + 15, p + 14, p + 13, p + 12);
  // FOURBUTTERFLY_HARDCODED1
  strDCT2x2dn(p + 0, p + 4, p + 8, p + 12);
  strDCT2x2dn(p + 1, p + 5, p + 9, p + 13);
  strDCT2x2dn(p + 2, p + 6, p + 10, p + 14);
  strDCT2x2dn(p + 3, p + 7, p + 11, p + 15);
end;

procedure strIDCT4x4Stage2(p: PInt);
begin
  invOdd(p + 32, p + 48, p + 96, p + 112);
  invOdd(p + 128, p + 192, p + 144, p + 208);
  invOddOdd(p + 160, p + 224, p + 176, p + 240);
  strDCT2x2up(p + 0, p + 64, p + 16, p + 80);
  FourButterfly(p, 0, 192, 48, 240, 64, 128, 112, 176, 16, 208, 32, 224, 80, 144, 96, 160);
end;

procedure strNormalizeDec(p: PInt; bChroma: Boolean);
var i: Integer;
begin
  if bChroma then
  begin
    i := 0;
    while i < 256 do begin p[i] := p[i] + p[i]; Inc(i, 16); end;
  end;
end;

procedure strPost2(a, b: PInt);
begin
  b^ := b^ + Asr(a^ + 4, 3);
  a^ := a^ + Asr(b^ + 2, 2);
  b^ := b^ + Asr(a^ + 4, 3);
end;

procedure strPost2_alternate(pa, pb: PInt);
var a, b: Integer;
begin
  a := pa^; b := pb^;
  b := b + Asr(a + 2, 2);
  a := a + Asr(b + 1, 1);
  a := a + Asr(b, 5);
  a := a + Asr(b, 9);
  a := a + Asr(b, 13);
  b := b + Asr(a + 2, 2);
  pa^ := a; pb^ := b;
end;

procedure strPost2x2(pa, pb, pc, pd: PInt);
var a, b, c, d: Integer;
begin
  a := pa^; b := pb^; c := pc^; d := pd^;
  a := a + d;
  b := b + c;
  d := d - Asr(a + 1, 1);
  c := c - Asr(b + 1, 1);
  b := b + Asr(a + 2, 2);
  a := a + Asr(b + 1, 1);
  b := b + Asr(a + 2, 2);
  d := d + Asr(a + 1, 1);
  c := c + Asr(b + 1, 1);
  a := a - d;
  b := b - c;
  pa^ := a; pb^ := b; pc^ := c; pd^ := d;
end;

procedure strPost2x2_alternate(pa, pb, pc, pd: PInt);
var a, b, c, d: Integer;
begin
  a := pa^; b := pb^; c := pc^; d := pd^;
  a := a + d;
  b := b + c;
  d := d - Asr(a + 1, 1);
  c := c - Asr(b + 1, 1);
  b := b + Asr(a + 2, 2);
  a := a + Asr(b + 1, 1);
  a := a + Asr(b, 5);
  a := a + Asr(b, 9);
  a := a + Asr(b, 13);
  b := b + Asr(a + 2, 2);
  d := d + Asr(a + 1, 1);
  c := c + Asr(b + 1, 1);
  a := a - d;
  b := b - c;
  pa^ := a; pb^ := b; pc^ := c; pd^ := d;
end;

procedure strHSTdec1_edge(var a, d: Integer);
begin
  a := a + d;
  d := Asr(a, 1) - d;
  a := a + Asr(d * 3 + 0, 3);
  d := d + Asr(a * 3 + 0, 4);
  d := d + Asr(a, 7);
  d := d - Asr(a, 10);
  a := a + Asr(d * 3 + 4, 3);
  d := d - Asr(a, 1);
  a := a + d;
  d := -d;
end;

procedure strPost4(pa, pb, pc, pd: PInt);
var a, b, c, d: Integer;
begin
  a := pa^; b := pb^; c := pc^; d := pd^;
  a := a + d; b := b + c;
  d := d - Asr(a + 1, 1); c := c - Asr(b + 1, 1);
  // IROTATE1(c, d)
  c := c - Asr(d + 1, 1); d := d + Asr(c + 1, 1);
  d := d + Asr(a + 1, 1); c := c + Asr(b + 1, 1);
  a := a - (d - Asr(d * 3 + 16, 5)); b := b - (c - Asr(c * 3 + 16, 5));
  d := d + Asr(a * 3 + 8, 4); c := c + Asr(b * 3 + 8, 4);
  a := a + Asr(d * 3 + 16, 5); b := b + Asr(c * 3 + 16, 5);
  pa^ := a; pb^ := b; pc^ := c; pd^ := d;
end;

procedure strPost4_alternate(pa, pb, pc, pd: PInt);
var a, b, c, d: Integer;
begin
  a := pa^; b := pb^; c := pc^; d := pd^;
  a := a + d; b := b + c;
  d := d - Asr(a + 1, 1); c := c - Asr(b + 1, 1);
  strHSTdec1_edge(a, d); strHSTdec1_edge(b, c);
  // IROTATE1(c, d)
  c := c - Asr(d + 1, 1); d := d + Asr(c + 1, 1);
  d := d + Asr(a + 1, 1); c := c + Asr(b + 1, 1);
  a := a - d; b := b - c;
  pa^ := a; pb^ := b; pc^ := c; pd^ := d;
end;

procedure strHSTdec1(pa, pd: PInt);
var a, d: Integer;
begin
  a := pa^; d := pd^;
  a := a + d;
  d := Asr(a, 1) - d;
  a := a + Asr(d * 3 + 0, 3);
  d := d + Asr(a * 3 + 0, 4);
  pa^ := a; pd^ := d;
end;

procedure strHSTdec1_alternate(pa, pd: PInt);
var a, d: Integer;
begin
  a := pa^; d := pd^;
  a := a + d;
  d := Asr(a, 1) - d;
  a := a + Asr(d * 3 + 0, 3);
  d := d + Asr(a * 3 + 0, 4);
  d := d + Asr(a, 7);
  d := d - Asr(a, 10);
  pa^ := a; pd^ := d;
end;

procedure strHSTdec(pa, pb, pc, pd: PInt);
var a, b, c, d: Integer;
begin
  a := pa^; b := pb^; c := pc^; d := pd^;
  b := b - c;
  a := a + Asr(d * 3 + 4, 3);
  d := d - Asr(b, 1);
  c := Asr(a - b, 1) - c;
  pc^ := d;
  pd^ := c;
  pa^ := a - c;
  pb^ := b + d;
end;

procedure DCCompensate(a, b, c, d: PInt; iDC: Integer);
begin
  iDC := Asr(iDC, 1);
  a^ := a^ - iDC;
  d^ := d^ - iDC;
  b^ := b^ + iDC;
  c^ := c^ + iDC;
end;

function ClipDCL(iDCL, iAltDCL: Integer): Integer;
begin
  Result := 0;
  if iDCL > 0 then
  begin
    if iAltDCL > 0 then Result := Min(iDCL, iAltDCL);
  end
  else if iDCL < 0 then
  begin
    if iAltDCL < 0 then Result := Max(iDCL, iAltDCL);
  end;
end;

procedure strPost4x4Stage1Split(p0, p1: PInt; iOffset, iHPQP: Integer; bHPAbsent: Boolean);
var
  p2, p3: PInt;
  k, iTmp, iDCL, iDCLAlt: Integer;
begin
  p2 := p0 + 72 - iOffset;
  p3 := p1 + 64 - iOffset;
  p0 := p0 + 12;
  p1 := p1 + 4;
  for k := 0 to 3 do strDCT2x2dn(p0 + k, p2 + k, p1 + k, p3 + k);
  invOddOddPost(p3 + 0, p3 + 1, p3 + 2, p3 + 3);
  IRot1(p1 + 2, p1 + 3);
  IRot1(p1 + 0, p1 + 1);
  IRot1(p2 + 1, p2 + 3);
  IRot1(p2 + 0, p2 + 2);
  for k := 0 to 3 do strHSTdec1(p0 + k, p3 + k);
  for k := 0 to 3 do strHSTdec(p0 + k, p2 + k, p1 + k, p3 + k);
  for k := 0 to 3 do
  begin
    iTmp := Asr(p0[k] + p1[k] + p2[k] + p3[k], 1);
    iDCL := Asr(iTmp * 595 + 65536, 17);           // approx 27/5947
    if ((Abs(iDCL) < iHPQP) and (iHPQP > 20)) or bHPAbsent then
    begin
      iDCLAlt := Asr(p0[k] - p1[k] - p2[k] + p3[k], 1);
      iDCL := ClipDCL(iDCL, iDCLAlt);
      DCCompensate(p0 + k, p2 + k, p1 + k, p3 + k, iDCL);
    end;
  end;
end;

procedure strPost4x4Stage1(p: PInt; iOffset, iHPQP: Integer; bHPAbsent: Boolean);
begin
  strPost4x4Stage1Split(p, p + 16, iOffset, iHPQP, bHPAbsent);
end;

procedure strPost4x4Stage1Split_alternate(p0, p1: PInt; iOffset: Integer);
var
  p2, p3: PInt;
  k: Integer;
begin
  p2 := p0 + 72 - iOffset;
  p3 := p1 + 64 - iOffset;
  p0 := p0 + 12;
  p1 := p1 + 4;
  for k := 0 to 3 do strDCT2x2dn(p0 + k, p2 + k, p1 + k, p3 + k);
  invOddOddPost(p3 + 0, p3 + 1, p3 + 2, p3 + 3);
  IRot1(p1 + 2, p1 + 3);
  IRot1(p1 + 0, p1 + 1);
  IRot1(p2 + 1, p2 + 3);
  IRot1(p2 + 0, p2 + 2);
  for k := 0 to 3 do strHSTdec1_alternate(p0 + k, p3 + k);
  for k := 0 to 3 do strHSTdec(p0 + k, p2 + k, p1 + k, p3 + k);
end;

procedure strPost4x4Stage1_alternate(p: PInt; iOffset: Integer);
begin
  strPost4x4Stage1Split_alternate(p, p + 16, iOffset);
end;

procedure strPost4x4Stage2Split(p0, p1: PInt);
begin
  strDCT2x2dn(p0 - 96, p0 + 96, p1 - 112, p1 + 80);
  strDCT2x2dn(p0 - 32, p0 + 32, p1 - 48, p1 + 16);
  strDCT2x2dn(p0 - 80, p0 + 112, p1 - 128, p1 + 64);
  strDCT2x2dn(p0 - 16, p0 + 48, p1 - 64, p1 + 0);
  invOddOddPost(p1 + 0, p1 + 64, p1 + 16, p1 + 80);
  IRot1(p0 + 48, p0 + 32);
  IRot1(p0 + 112, p0 + 96);
  IRot1(p1 - 64, p1 - 128);
  IRot1(p1 - 48, p1 - 112);
  strHSTdec1(p0 - 96, p1 + 80);
  strHSTdec1(p0 - 32, p1 + 16);
  strHSTdec1(p0 - 80, p1 + 64);
  strHSTdec1(p0 - 16, p1 + 0);
  strHSTdec(p0 - 96, p1 - 112, p0 + 96, p1 + 80);
  strHSTdec(p0 - 32, p1 - 48, p0 + 32, p1 + 16);
  strHSTdec(p0 - 80, p1 - 128, p0 + 112, p1 + 64);
  strHSTdec(p0 - 16, p1 - 64, p0 + 48, p1 + 0);
end;

procedure strPost4x4Stage2Split_alternate(p0, p1: PInt);
begin
  strDCT2x2dn(p0 - 96, p0 + 96, p1 - 112, p1 + 80);
  strDCT2x2dn(p0 - 32, p0 + 32, p1 - 48, p1 + 16);
  strDCT2x2dn(p0 - 80, p0 + 112, p1 - 128, p1 + 64);
  strDCT2x2dn(p0 - 16, p0 + 48, p1 - 64, p1 + 0);
  invOddOddPost(p1 + 0, p1 + 64, p1 + 16, p1 + 80);
  IRot1(p0 + 48, p0 + 32);
  IRot1(p0 + 112, p0 + 96);
  IRot1(p1 - 64, p1 - 128);
  IRot1(p1 - 48, p1 - 112);
  strHSTdec1_alternate(p0 - 96, p1 + 80);
  strHSTdec1_alternate(p0 - 32, p1 + 16);
  strHSTdec1_alternate(p0 - 80, p1 + 64);
  strHSTdec1_alternate(p0 - 16, p1 + 0);
  strHSTdec(p0 - 96, p1 - 112, p0 + 96, p1 + 80);
  strHSTdec(p0 - 32, p1 - 48, p0 + 32, p1 + 16);
  strHSTdec(p0 - 80, p1 - 128, p0 + 112, p1 + 64);
  strHSTdec(p0 - 16, p1 - 64, p0 + 48, p1 + 0);
end;

// ========================== decoder state ===============================

type
  TMBInfo = record
    iBlockDC: array[0..MAX_CHANNELS - 1, 0..15] of Integer;
    iOrientation: Integer;
    iCBP, iDiffCBP: array[0..MAX_CHANNELS - 1] of Integer;
    iQIndexLP, iQIndexHP: Integer;
  end;

  TPredInfo = record
    iQPIndex, iCBP, iDC: Integer;
    iAD: array[0..5] of Integer;
  end;
  TPredArr = array of TPredInfo;

  TJxrSC = class
  public
    // parameters
    CF, NumCh, Subband, BF, Overlap, SubVersion: Integer;
    ScaledArith, HardTiles, TrimFlexbitsFlag, IndexTableFlag: Boolean;
    QPMode: Cardinal;
    QPIdxDC, QPIdxLP, QPIdxHP: array[0..MAX_CHANNELS - 1] of Byte;
    NumSliceV, NumSliceH: Integer;
    TileXs, TileYs: array of Cardinal;
    cmbWidth, cmbHeight: Integer;
    DecodeLP, DecodeHP, SkipFlexbits: Boolean;
    // position
    cRow, cColumn, cTileColumn, cTileRow: Integer;
    bCtxLeft, bCtxTop, bResetContext, bResetRGITotals: Boolean;
    // coding state
    Tiles: array of TTile;
    CtxA: array of TCodingContext;
    MB: TMBInfo;
    Pred, PredPrev: array[0..MAX_CHANNELS - 1] of TPredArr;
    Buf0, Buf1: array[0..MAX_CHANNELS - 1] of TIntArr;
    a0, a1, p0, p1: array[0..MAX_CHANNELS - 1] of PInt;
    Stride: array[0..MAX_CHANNELS - 1] of Integer;
    ResU, ResV: TIntArr;
    // hard-tile transform state (pSC->mbX etc.)
    hmbX, hmbY, htileX, htileY: Integer;
    bVertTB, bHoriTB, bOneMBLeftVertTB, bOneMBRightVertTB: Boolean;
    iPredBefore, iPredAfter: array[0..1, 0..1] of Integer;
    // bitstreams
    IOHeader: PBitIO;
    BitIO: array of PBitIO;
    NumBitIO, cSB: Integer;
    IndexTable: array of Int64;
    HeaderSize: Int64;
    Data: PByte; DataSize: NativeInt;
    IOStore: array of TBitIO;
    HeaderIOStore: TBitIO;
    // alpha plane
    NextSC: TJxrSC;
    Secondary: Boolean;

    procedure InitFromHeader(const H: TJxrCore; AData: PByte; ASize: NativeInt);
    function StrIODecInit(HdrEnd: NativeInt): Boolean;
    procedure ShareIO(Prim: TJxrSC);
    function StrDecInit: Boolean;
    procedure SetBitIOPointers;
    procedure UseDCQuantizer(iTile: Integer);
    procedure UseLPQuantizer(cQP, iTile: Integer);
    procedure SetUniformQuantizer(sb: Integer);

    procedure GetTilePos(mbX, mbY: Integer);
    function ReadPackets: Boolean;
    function ReadTileHeaderDC(var io: TBitIO): Boolean;
    function ReadTileHeaderLP(var io: TBitIO): Boolean;
    function ReadTileHeaderHP(var io: TBitIO): Boolean;

    function DecodeMBDC(ctx: PCodingContext): Boolean;
    function DecodeMBLP(ctx: PCodingContext): Boolean;
    function DecodeMBHP(ctx: PCodingContext): Boolean;
    procedure DecodeCBP(ctx: PCodingContext);
    function DecodeCoeffs(ctx: PCodingContext): Boolean;

    function GetDCACPredMode(mbX: Integer): Integer;
    function GetACPredMode: Integer;
    procedure PredDCACDec;
    procedure PredACDec;
    procedure PredCBPDec(ctx: PCodingContext);
    procedure DequantizeMB;
    procedure UpdatePredInfo;

    procedure InvTransformMB;
    procedure InvTransformMBHard;
    procedure Transform;
    function ProcessMB: Boolean;

    procedure InitMRPtr;
    procedure AdvanceMRPtr;
    procedure SwapMRPtr;
    procedure AdvanceOneMBRow;
    procedure InterpolateUV;
  end;

procedure TJxrSC.InitFromHeader(const H: TJxrCore; AData: PByte; ASize: NativeInt);
var i: Integer;
begin
  CF := H.CfColorFormat;
  NumCh := H.NumChannels;
  Subband := H.Subband;
  BF := H.BitstreamFormat;
  Overlap := H.Overlap;
  SubVersion := H.SubVersion;
  HardTiles := H.SubVersion = CODEC_SUBVERSION_NEWSCALING_HARD_TILES;
  TrimFlexbitsFlag := H.TrimFlexbits;
  IndexTableFlag := H.IndexTable;
  ScaledArith := H.ScaledArith;
  QPMode := H.QPMode;
  for i := 0 to MAX_CHANNELS - 1 do
  begin
    QPIdxDC[i] := H.QPIndexDC[i]; QPIdxLP[i] := H.QPIndexLP[i]; QPIdxHP[i] := H.QPIndexHP[i];
  end;
  NumSliceV := H.NumSliceV; NumSliceH := H.NumSliceH;
  SetLength(TileXs, NumSliceV + 2);
  SetLength(TileYs, NumSliceH + 2);
  for i := 0 to NumSliceV do TileXs[i] := H.TileX[i];
  for i := 0 to NumSliceH do TileYs[i] := H.TileY[i];
  cmbWidth := (H.Width + H.ExtraLeft + H.ExtraRight + 15) div 16;
  cmbHeight := (H.Height + H.ExtraTop + H.ExtraBottom + 15) div 16;
  SkipFlexbits := Subband = SB_NO_FLEXBITS;
  DecodeHP := (Subband = SB_ALL) or (Subband = SB_NO_FLEXBITS);
  DecodeLP := Subband <> SB_DC_ONLY;
  Data := AData; DataSize := ASize;
end;

// GetVLWordEsc
function GetVLWordEsc(var io: TBitIO): Int64;
var s: Int64;
begin
  s := BGet(io, 8);
  if (s = $fd) or (s = $fe) or (s = $ff) then
    s := 0
  else if s < $fb then
    s := (s shl 8) or BGet(io, 8)
  else
  begin
    s := s - $fb;
    if s <> 0 then
    begin
      s := Int64(BGet(io, 16)) shl 16;
      s := (s or BGet(io, 16)) shl 16;
      s := s shl 16;
    end;
    s := s or (Int64(BGet(io, 16)) shl 16);
    s := s or BGet(io, 16);
  end;
  Result := s;
end;

// strcodec.c allocateBitIOInfo + strdec.c StrIODecInit/readIndexTable
function TJxrSC.StrIODecInit(HdrEnd: NativeInt): Boolean;
var i, iEntry: Integer;
begin
  Result := False;
  case Subband of
    SB_DC_ONLY: cSB := 1;
    SB_NO_HIGHPASS: cSB := 2;
    SB_NO_FLEXBITS: cSB := 3;
  else cSB := 4;
  end;
  if not IndexTableFlag then NumBitIO := 0
  else if BF = BF_SPATIAL then NumBitIO := NumSliceV + 1
  else NumBitIO := (NumSliceV + 1) * cSB;
  if NumBitIO > MAX_TILES * 4 then Exit;
  SetLength(IOStore, NumBitIO);
  SetLength(BitIO, NumBitIO);
  for i := 0 to NumBitIO - 1 do BitIO[i] := @IOStore[i];
  if NumBitIO > 0 then SetLength(IndexTable, NumBitIO * (NumSliceH + 1));

  IOHeader := @HeaderIOStore;
  BIOAttach(IOHeader^, Data, DataSize, HdrEnd);
  if NumBitIO > 0 then
  begin
    iEntry := NumBitIO * (NumSliceH + 1);
    if BGet(IOHeader^, 16) <> 1 then Exit;
    for i := 0 to iEntry - 1 do IndexTable[i] := GetVLWordEsc(IOHeader^);
  end;
  HeaderSize := GetVLWordEsc(IOHeader^);
  BFlushToByte(IOHeader^);
  HeaderSize := HeaderSize + BPosRead(IOHeader^);
  Result := True;
end;

procedure TJxrSC.ShareIO(Prim: TJxrSC);
var i: Integer;
begin
  IOHeader := Prim.IOHeader;
  NumBitIO := Prim.NumBitIO;
  cSB := Prim.cSB;
  SetLength(BitIO, NumBitIO);
  for i := 0 to NumBitIO - 1 do BitIO[i] := Prim.BitIO[i];
  HeaderSize := Prim.HeaderSize;
end;

procedure TJxrSC.SetBitIOPointers;
var i, j: Integer;
begin
  if NumBitIO > 0 then
  begin
    for i := 0 to NumSliceV do
    begin
      if BF = BF_SPATIAL then
      begin
        CtxA[i].IODC := BitIO[i]; CtxA[i].IOLP := BitIO[i];
        CtxA[i].IOAC := BitIO[i]; CtxA[i].IOFL := BitIO[i];
      end
      else
      begin
        j := cSB;
        CtxA[i].IODC := BitIO[i * j];
        if j > 1 then CtxA[i].IOLP := BitIO[i * j + 1];
        if j > 2 then CtxA[i].IOAC := BitIO[i * j + 2];
        if j > 3 then CtxA[i].IOFL := BitIO[i * j + 3];
      end;
    end;
  end
  else
  begin
    CtxA[0].IODC := IOHeader; CtxA[0].IOLP := IOHeader;
    CtxA[0].IOAC := IOHeader; CtxA[0].IOFL := IOHeader;
  end;
end;

procedure TJxrSC.SetUniformQuantizer(sb: Integer);
var iCh, iTile: Integer;
begin
  for iCh := 0 to NumCh - 1 do
    for iTile := 1 to NumSliceV do
      case sb of
        0: Tiles[iTile].QDC[iCh] := Tiles[0].QDC[iCh];
        1: Tiles[iTile].QLP[iCh] := Tiles[0].QLP[iCh];
      else Tiles[iTile].QHP[iCh] := Tiles[0].QHP[iCh];
      end;
end;

procedure TJxrSC.UseDCQuantizer(iTile: Integer);
var iCh: Integer;
begin
  for iCh := 0 to NumCh - 1 do
    Tiles[iTile].QLP[iCh][0] := Tiles[iTile].QDC[iCh][0];
end;

procedure TJxrSC.UseLPQuantizer(cQP, iTile: Integer);
var iCh, iQP: Integer;
begin
  for iCh := 0 to NumCh - 1 do
    for iQP := 0 to cQP - 1 do
      Tiles[iTile].QHP[iCh][iQP] := Tiles[iTile].QLP[iCh][iQP];
end;

// strdec.c StrDecInit
function TJxrSC.StrDecInit: Boolean;
const PAD = 512;
var i, sz, chromaStride: Integer;
begin
  Result := False;
  if (CF = CF_YUV420) or (CF = CF_YUV422) then
  begin
    SetLength(ResU, 256 * (cmbWidth + 1));
    SetLength(ResV, 256 * (cmbWidth + 1));
  end;

  for i := 0 to NumCh - 1 do
  begin
    SetLength(Pred[i], cmbWidth + 1);
    SetLength(PredPrev[i], cmbWidth + 1);
  end;

  SetLength(Tiles, NumSliceV + 1);
  for i := 0 to NumSliceV do
  begin
    Tiles[i].cNumQPHP := 1; Tiles[i].cNumQPLP := 1;
    Tiles[i].cBitsHP := 0; Tiles[i].cBitsLP := 0;
  end;

  if (QPMode and 1) = 0 then
  begin
    AllocQuantizer(Tiles[0].QDC, NumCh, 1);
    SetUniformQuantizer(0);
    for i := 0 to NumCh - 1 do Tiles[0].QDC[i][0].Index := QPIdxDC[i];
    FormatQuantizer(Tiles[0].QDC, (QPMode shr 3) and 3, NumCh, 0, True, ScaledArith);
  end;
  if Subband <> SB_DC_ONLY then
  begin
    if (QPMode and 2) = 0 then
    begin
      AllocQuantizer(Tiles[0].QLP, NumCh, 1);
      SetUniformQuantizer(1);
      if (QPMode and $200) = 0 then
        UseDCQuantizer(0)
      else
      begin
        for i := 0 to NumCh - 1 do Tiles[0].QLP[i][0].Index := QPIdxLP[i];
        FormatQuantizer(Tiles[0].QLP, (QPMode shr 5) and 3, NumCh, 0, True, ScaledArith);
      end;
    end;
    if Subband <> SB_NO_HIGHPASS then
    begin
      if (QPMode and 4) = 0 then
      begin
        AllocQuantizer(Tiles[0].QHP, NumCh, 1);
        SetUniformQuantizer(2);
        if (QPMode and $400) = 0 then
          UseLPQuantizer(1, 0)
        else
        begin
          for i := 0 to NumCh - 1 do Tiles[0].QHP[i][0].Index := QPIdxHP[i];
          FormatQuantizer(Tiles[0].QHP, (QPMode shr 7) and 3, NumCh, 0, False, ScaledArith);
        end;
      end;
    end;
  end;

  if NumSliceV >= MAX_TILES then Exit;
  SetLength(CtxA, NumSliceV + 1);
  for i := 0 to NumSliceV do AllocateCodingContext(CtxA[i], CF);
  SetBitIOPointers;

  // macroblock row buffers (current + previous), with guard padding
  chromaStride := cblkChromas[CF] * 16;
  for i := 0 to NumCh - 1 do
  begin
    if i = 0 then Stride[i] := 256 else Stride[i] := chromaStride;
    sz := PAD + Stride[i] * (cmbWidth + 1) + PAD;
    SetLength(Buf0[i], sz);
    SetLength(Buf1[i], sz);
    a0[i] := @Buf0[i][PAD];
    a1[i] := @Buf1[i][PAD];
  end;
  Result := True;
end;

procedure TJxrSC.InitMRPtr;
var i: Integer;
begin
  for i := 0 to NumCh - 1 do begin p0[i] := a0[i]; p1[i] := a1[i]; end;
end;

procedure TJxrSC.AdvanceMRPtr;
var i: Integer;
begin
  for i := 0 to NumCh - 1 do
  begin
    p0[i] := p0[i] + Stride[i];
    p1[i] := p1[i] + Stride[i];
  end;
end;

procedure TJxrSC.SwapMRPtr;
var i: Integer; t: PInt;
begin
  for i := 0 to NumCh - 1 do begin t := a0[i]; a0[i] := a1[i]; a1[i] := t; end;
end;

procedure TJxrSC.AdvanceOneMBRow;
var i: Integer; t: TPredArr;
begin
  for i := 0 to NumCh - 1 do begin t := Pred[i]; Pred[i] := PredPrev[i]; PredPrev[i] := t; end;
end;

// strcodec.c getTilePos
procedure TJxrSC.GetTilePos(mbX, mbY: Integer);
begin
  if mbX = 0 then cTileColumn := 0
  else if (cTileColumn < NumSliceV) and (Cardinal(mbX) = TileXs[cTileColumn + 1]) then Inc(cTileColumn);
  if mbY = 0 then cTileRow := 0
  else if (cTileRow < NumSliceH) and (Cardinal(mbY) = TileYs[cTileRow + 1]) then Inc(cTileRow);

  bCtxLeft := Cardinal(mbX) = TileXs[cTileColumn];
  bCtxTop := Cardinal(mbY) = TileYs[cTileRow];

  bResetContext := ((Cardinal(mbX) - TileXs[cTileColumn]) and $f) = 0;
  bResetRGITotals := bResetContext;
  if cTileColumn = NumSliceV then
  begin
    if mbX + 1 = cmbWidth then bResetContext := True;
  end
  else if Cardinal(mbX + 1) = TileXs[cTileColumn + 1] then
    bResetContext := True;
end;

function ReadPacketHeader(var io: TBitIO): Boolean;
begin
  Result := False;
  if BGet(io, 8) <> 0 then Exit;
  if BGet(io, 8) <> 0 then Exit;
  if BGet(io, 8) <> 1 then Exit;
  BGet(io, 8);                                     // packet ID
  Result := True;
end;

// strdec.c readPackets
function TJxrSC.ReadPackets: Boolean;
var
  k: Integer;
  io: PBitIO;
  c: PCodingContext;
begin
  Result := False;
  if (cColumn = 0) and (Cardinal(cRow) = TileYs[cTileRow]) then
  begin
    if Secondary then
    begin
      if NumBitIO > 0 then
        for k := 0 to NumSliceV do ResetCodingContextDec(CtxA[k])
      else
        ResetCodingContextDec(CtxA[0]);
    end
    else
    begin
      for k := 0 to NumBitIO - 1 do
        BIOAttach(BitIO[k]^, Data, DataSize,
          NativeInt(IndexTable[NumBitIO * cTileRow + k] + HeaderSize));
      if NumBitIO = 0 then
        BIOAttach(IOHeader^, Data, DataSize, NativeInt(HeaderSize));
      for k := 0 to NumSliceV do
      begin
        if BF = BF_SPATIAL then
        begin
          if NumBitIO = 0 then io := IOHeader else io := BitIO[k];
          if not ReadPacketHeader(io^) then Exit;
          if TrimFlexbitsFlag then CtxA[k].TrimFlexBits := BGet(io^, 4)
          else CtxA[k].TrimFlexBits := 0;
        end
        else
        begin
          if not ReadPacketHeader(BitIO[k * cSB + 0]^) then Exit;
          if cSB > 1 then if not ReadPacketHeader(BitIO[k * cSB + 1]^) then Exit;
          if cSB > 2 then if not ReadPacketHeader(BitIO[k * cSB + 2]^) then Exit;
          if cSB > 3 then
          begin
            ReadPacketHeader(BitIO[k * cSB + 3]^);   // bad flexbits packet is tolerated
            if TrimFlexbitsFlag then CtxA[k].TrimFlexBits := BGet(BitIO[k * cSB + 3]^, 4)
            else CtxA[k].TrimFlexBits := 0;
          end;
        end;
        ResetCodingContextDec(CtxA[k]);
      end;
    end;
  end;

  if bCtxLeft and bCtxTop and (not Secondary) then
  begin
    c := @CtxA[cTileColumn];
    if not ReadTileHeaderDC(c.IODC^) then Exit;
    if NextSC <> nil then if not NextSC.ReadTileHeaderDC(c.IODC^) then Exit;
    if cSB > 1 then
    begin
      if not ReadTileHeaderLP(c.IOLP^) then Exit;
      if NextSC <> nil then if not NextSC.ReadTileHeaderLP(c.IOLP^) then Exit;
    end;
    if cSB > 2 then
    begin
      if not ReadTileHeaderHP(c.IOAC^) then Exit;
      if NextSC <> nil then if not NextSC.ReadTileHeaderHP(c.IOAC^) then Exit;
    end;
  end;
  Result := True;
end;

function TJxrSC.ReadTileHeaderDC(var io: TBitIO): Boolean;
var iTile: Integer; t: PTile;
begin
  if (QPMode and 1) <> 0 then
  begin
    t := @Tiles[cTileColumn];
    if cTileRow + cTileColumn = 0 then
      for iTile := 0 to NumSliceV do AllocQuantizer(Tiles[iTile].QDC, NumCh, 1);
    t.cChModeDC := ReadQuantizer(t.QDC, io, NumCh, 0);
    FormatQuantizer(t.QDC, t.cChModeDC, NumCh, 0, True, ScaledArith);
  end;
  Result := True;
end;

function TJxrSC.ReadTileHeaderLP(var io: TBitIO): Boolean;
var i: Integer; t: PTile;
begin
  if (Subband <> SB_DC_ONLY) and ((QPMode and 2) <> 0) then
  begin
    t := @Tiles[cTileColumn];
    t.bUseDC := BGet(io, 1) = 1;
    t.cBitsLP := 0;
    t.cNumQPLP := 1;
    if t.bUseDC then
    begin
      AllocQuantizer(t.QLP, NumCh, t.cNumQPLP);
      UseDCQuantizer(cTileColumn);
    end
    else
    begin
      t.cNumQPLP := BGet(io, 4) + 1;
      t.cBitsLP := DQuantBits(t.cNumQPLP);
      AllocQuantizer(t.QLP, NumCh, t.cNumQPLP);
      for i := 0 to t.cNumQPLP - 1 do
      begin
        t.cChModeLP[i] := ReadQuantizer(t.QLP, io, NumCh, i);
        FormatQuantizer(t.QLP, t.cChModeLP[i], NumCh, i, True, ScaledArith);
      end;
    end;
  end;
  Result := True;
end;

function TJxrSC.ReadTileHeaderHP(var io: TBitIO): Boolean;
var i: Integer; t: PTile;
begin
  if (Subband <> SB_DC_ONLY) and (Subband <> SB_NO_HIGHPASS) and ((QPMode and 4) <> 0) then
  begin
    t := @Tiles[cTileColumn];
    t.bUseLP := BGet(io, 1) = 1;
    t.cBitsHP := 0;
    t.cNumQPHP := 1;
    if t.bUseLP then
    begin
      t.cNumQPHP := t.cNumQPLP;
      AllocQuantizer(t.QHP, NumCh, t.cNumQPHP);
      UseLPQuantizer(t.cNumQPHP, cTileColumn);
    end
    else
    begin
      t.cNumQPHP := BGet(io, 4) + 1;
      t.cBitsHP := DQuantBits(t.cNumQPHP);
      AllocQuantizer(t.QHP, NumCh, t.cNumQPHP);
      for i := 0 to t.cNumQPHP - 1 do
      begin
        t.cChModeHP[i] := ReadQuantizer(t.QHP, io, NumCh, i);
        FormatQuantizer(t.QHP, t.cChModeHP[i], NumCh, i, False, ScaledArith);
      end;
    end;
  end;
  Result := True;
end;

// --------------------------- DC band -----------------------------------

function TJxrSC.DecodeMBDC(ctx: PCodingContext): Boolean;
var
  t: PTile;
  io: PBitIO;
  i, iIndex, iModelBits, iQDCY, iQDCU, iQDCV, pLM, kk: Integer;
  LM: array[0..1] of Integer;
begin
  Result := False;
  t := @Tiles[cTileColumn];
  io := ctx.IODC;
  LM[0] := 0; LM[1] := 0; pLM := 0;
  iModelBits := ctx.ModelDC.FlcBits[0];
  for i := 0 to NumCh - 1 do FillChar(MB.iBlockDC[i], SizeOf(MB.iBlockDC[i]), 0);

  MB.iQIndexLP := 0; MB.iQIndexHP := 0;
  if (BF = BF_SPATIAL) and (Subband <> SB_DC_ONLY) then
  begin
    if t.cBitsLP > 0 then MB.iQIndexLP := DecodeQPIndex(io^, t.cBitsLP);
    if (Subband <> SB_NO_HIGHPASS) and (t.cBitsHP > 0) then
      MB.iQIndexHP := DecodeQPIndex(io^, t.cBitsHP);
  end;
  if (t.cBitsHP = 0) and (t.cNumQPHP > 1) then MB.iQIndexHP := MB.iQIndexLP;
  if (MB.iQIndexLP >= t.cNumQPLP) or (MB.iQIndexHP >= t.cNumQPHP) then Exit;

  if (CF = CF_Y_ONLY) or (CF = CF_CMYK) or (CF = CF_NCOMPONENT) then
  begin
    for i := 0 to NumCh - 1 do
    begin
      iQDCY := 0;
      if BGet(io^, 1) <> 0 then
      begin
        iQDCY := DecodeSignificantAbsLevel(ctx.AHexpt[3], io^) - 1;
        Inc(LM[pLM]);
      end;
      if iModelBits <> 0 then iQDCY := (iQDCY shl iModelBits) or BGet(io^, iModelBits);
      if (iQDCY <> 0) and (BGet(io^, 1) <> 0) then iQDCY := -iQDCY;
      MB.iBlockDC[i, 0] := iQDCY;
      pLM := 1;
      iModelBits := ctx.ModelDC.FlcBits[1];
    end;
  end
  else
  begin
    iIndex := GetHuff(ctx.AHexpt[2].DecTable, io^);
    iQDCY := iIndex shr 2;
    iQDCU := (iIndex shr 1) and 1;
    iQDCV := iIndex and 1;
    if iQDCY <> 0 then
    begin
      iQDCY := DecodeSignificantAbsLevel(ctx.AHexpt[3], io^) - 1;
      Inc(LM[pLM]);
    end;
    if iModelBits <> 0 then iQDCY := (iQDCY shl iModelBits) or BGet(io^, iModelBits);
    if (iQDCY <> 0) and (BGet(io^, 1) <> 0) then iQDCY := -iQDCY;
    MB.iBlockDC[0, 0] := iQDCY;

    pLM := 1;
    iModelBits := ctx.ModelDC.FlcBits[1];
    if iQDCU <> 0 then
    begin
      iQDCU := DecodeSignificantAbsLevel(ctx.AHexpt[4], io^) - 1;
      Inc(LM[pLM]);
    end;
    if iModelBits <> 0 then iQDCU := (iQDCU shl iModelBits) or BGet(io^, iModelBits);
    if (iQDCU <> 0) and (BGet(io^, 1) <> 0) then iQDCU := -iQDCU;
    MB.iBlockDC[1, 0] := iQDCU;

    if iQDCV <> 0 then
    begin
      iQDCV := DecodeSignificantAbsLevel(ctx.AHexpt[4], io^) - 1;
      Inc(LM[pLM]);
    end;
    if iModelBits <> 0 then iQDCV := (iQDCV shl iModelBits) or BGet(io^, iModelBits);
    if (iQDCV <> 0) and (BGet(io^, 1) <> 0) then iQDCV := -iQDCV;
    MB.iBlockDC[2, 0] := iQDCV;
  end;

  UpdateModelMB(CF, NumCh, LM, ctx.ModelDC);
  if (Subband = SB_DC_ONLY) and bResetContext then
    for kk := 2 to 4 do AdaptDiscriminant(ctx.AHexpt[kk]);
  Result := True;
end;

// --------------------------- LP band -----------------------------------

function TJxrSC.DecodeMBLP(ctx: PCodingContext): Boolean;
const
  aRemap: array[0..6] of Integer = (4, 1, 2, 3, 5, 6, 7);
var
  io: PBitIO;
  pScan: PAdaptiveScan;
  iFullPlanes, iModelBits, iNumNonzero, iIndex, iChannel, iCBP, k, iCountM, iCountZ,
  iMax, iWeight, pLM, iCount, remapOfs, r1, c, v: Integer;
  aRLCoeffs: array[0..31] of Integer;
  aTemp: array[0..15] of Integer;
  LM: array[0..1] of Integer;
  aDC: array[0..MAX_CHANNELS - 1] of PInt;
  pCoeffs: PInt;
  t: TAdaptiveScan;
begin
  Result := False;
  if (CF = CF_YUV420) or (CF = CF_YUV422) then iFullPlanes := 2 else iFullPlanes := NumCh;
  pScan := @ctx.ScanLowpass[0];
  io := ctx.IOLP;
  iModelBits := ctx.ModelLP.FlcBits[0];
  LM[0] := 0; LM[1] := 0; pLM := 0;
  iCBP := 0;

  if (BF <> BF_SPATIAL) and (Tiles[cTileColumn].cBitsLP > 0) then
    MB.iQIndexLP := DecodeQPIndex(io^, Tiles[cTileColumn].cBitsLP);

  for k := 0 to NumCh - 1 do aDC[k and 15] := @MB.iBlockDC[k, 0];

  if bResetRGITotals then
  begin
    iWeight := 2 * 16;
    pScan[0].uTotal := MAXTOTAL;
    for k := 1 to 15 do begin pScan[k].uTotal := iWeight; Dec(iWeight, 2); end;
  end;

  if (CF = CF_YUV420) or (CF = CF_YUV422) or (CF = CF_YUV444) then
  begin
    iCountM := ctx.CBPCountMax; iCountZ := ctx.CBPCountZero;
    iMax := iFullPlanes * 4 - 5;
    if (iCountZ <= 0) or (iCountM < 0) then
    begin
      iCBP := 0;
      if BGet(io^, 1) <> 0 then
      begin
        iCBP := 1;
        k := BGet(io^, iFullPlanes - 1);
        if k <> 0 then iCBP := k * 2 + BGet(io^, 1);
      end;
      if iCountM < iCountZ then iCBP := iMax - iCBP;
    end
    else
      iCBP := BGet(io^, iFullPlanes);
    iCountM := iCountM + 1 - 4 * Ord(iCBP = iMax);
    iCountZ := iCountZ + 1 - 4 * Ord(iCBP = 0);
    if iCountM < -8 then iCountM := -8 else if iCountM > 7 then iCountM := 7;
    ctx.CBPCountMax := iCountM;
    if iCountZ < -8 then iCountZ := -8 else if iCountZ > 7 then iCountZ := 7;
    ctx.CBPCountZero := iCountZ;
  end
  else
  begin
    for iChannel := 0 to NumCh - 1 do
      iCBP := iCBP or (BGet(io^, 1) shl iChannel);
  end;

  for iChannel := 0 to iFullPlanes - 1 do
  begin
    pCoeffs := aDC[iChannel];
    if (iCBP and 1) <> 0 then
    begin
      iNumNonzero := DecodeBlock(iChannel > 0, aRLCoeffs, ctx^, CTDC, io^,
        1 + 9 * Ord((CF = CF_YUV420) and (iChannel = 1)) + Ord((CF = CF_YUV422) and (iChannel = 1)));
      if ((CF = CF_YUV420) or (CF = CF_YUV422)) and (iChannel <> 0) then
      begin
        if CF = CF_YUV420 then begin remapOfs := 1; iCount := 6; end
        else begin remapOfs := 0; iCount := 14; end;
        LM[pLM] := LM[pLM] + iNumNonzero;
        iIndex := 0;
        FillChar(aTemp, SizeOf(aTemp), 0);
        for k := 0 to iNumNonzero - 1 do
        begin
          iIndex := iIndex + aRLCoeffs[k * 2];
          aTemp[iIndex and $f] := aRLCoeffs[k * 2 + 1];
          Inc(iIndex);
        end;
        for k := 0 to iCount - 1 do
          aDC[(k and 1) + 1][aRemap[remapOfs + (k shr 1)]] := aTemp[k];
      end
      else
      begin
        LM[pLM] := LM[pLM] + iNumNonzero;
        iIndex := 1;
        for k := 0 to iNumNonzero - 1 do
        begin
          iIndex := iIndex + aRLCoeffs[k * 2];
          if (iIndex < 1) or (iIndex > 15) then Break;
          pCoeffs[pScan[iIndex].uScan] := aRLCoeffs[k * 2 + 1];
          Inc(pScan[iIndex].uTotal);
          if pScan[iIndex].uTotal > pScan[iIndex - 1].uTotal then
          begin
            t := pScan[iIndex]; pScan[iIndex] := pScan[iIndex - 1]; pScan[iIndex - 1] := t;
          end;
          Inc(iIndex);
        end;
      end;
    end;

    if iModelBits <> 0 then
    begin
      if ((CF = CF_YUV420) or (CF = CF_YUV422)) and (iChannel <> 0) then
      begin
        for k := 1 to IfThen(CF = CF_YUV420, 3, 7) do
          for c := 1 to 2 do
          begin
            v := aDC[c][k];
            if v > 0 then
              v := (v shl iModelBits) + BGet(io^, iModelBits)
            else if v < 0 then
              v := (v shl iModelBits) - BGet(io^, iModelBits)
            else
            begin
              v := BGet(io^, iModelBits);
              if (v <> 0) and (BGet(io^, 1) <> 0) then v := -v;
            end;
            aDC[c][k] := v;
          end;
      end
      else
      begin
        for k := 1 to 15 do
        begin
          if pCoeffs[k] > 0 then
            pCoeffs[k] := (pCoeffs[k] shl iModelBits) + BGet(io^, iModelBits)
          else if pCoeffs[k] < 0 then
            pCoeffs[k] := (pCoeffs[k] shl iModelBits) - BGet(io^, iModelBits)
          else
          begin
            r1 := Integer(BPeek(io^, iModelBits + 1));
            pCoeffs[k] := (Asr(r1, 1) xor (-(r1 and 1))) + (r1 and 1);
            BFlush(io^, iModelBits + Ord(pCoeffs[k] <> 0));
          end;
        end;
      end;
    end;
    pLM := 1;
    iModelBits := ctx.ModelLP.FlcBits[1];
    iCBP := iCBP shr 1;
  end;

  UpdateModelMB(CF, NumCh, LM, ctx.ModelLP);
  if bResetContext then AdaptLowpassDec(ctx^);
  Result := True;
end;

// --------------------------- CBP ---------------------------------------

procedure TJxrSC.DecodeCBP(ctx: PCodingContext);
const
  gFLC0: array[0..5] of Integer = (0, 2, 1, 2, 2, 0);
  gOff0: array[0..5] of Integer = (0, 4, 2, 8, 12, 1);
  gOut0: array[0..15] of Integer = (0, 15, 3, 12, 1, 2, 4, 8, 5, 6, 9, 10, 7, 11, 13, 14);
  aTab: array[0..3] of Integer = (6, 9, 10, 12);
  iShift422: array[0..3] of Integer = (0, 1, 4, 5);
var
  io: PBitIO;
  iChannel, i, iBlock, k, iNumCBP, iNumBlockCBP, iCode, iCode1, val: Integer;
  iCBPCY, iCBPCU, iCBPCV: Integer;
begin
  io := ctx.IOAC;
  if (CF = CF_NCOMPONENT) or (CF = CF_CMYK) then iChannel := NumCh else iChannel := 1;
  for i := 0 to iChannel - 1 do
  begin
    iCBPCY := 0; iCBPCU := 0; iCBPCV := 0;
    iNumCBP := GetHuffShort(ctx.AHCBPCY1.DecTable, io^);
    if iNumCBP < 0 then iNumCBP := 0 else if iNumCBP > 4 then iNumCBP := 4;
    ctx.AHCBPCY1.Discriminant := ctx.AHCBPCY1.Discriminant + ctx.AHCBPCY1.Delta[iNumCBP];
    case iNumCBP of
      2:
        begin
          iNumCBP := BGet(io^, 2);
          if iNumCBP = 0 then iNumCBP := 3
          else if iNumCBP = 1 then iNumCBP := 5
          else iNumCBP := aTab[iNumCBP * 2 + BGet(io^, 1) - 4];
        end;
      1: iNumCBP := 1 shl BGet(io^, 2);
      3: iNumCBP := $f xor (1 shl BGet(io^, 2));
      4: iNumCBP := $f;
    end;

    for iBlock := 0 to 3 do
      if (iNumCBP and (1 shl iBlock)) <> 0 then
      begin
        iNumBlockCBP := GetHuff(ctx.AHCBPCY.DecTable, io^);
        if iNumBlockCBP < 0 then iNumBlockCBP := 0
        else if iNumBlockCBP > ctx.AHCBPCY.NSymbols - 1 then iNumBlockCBP := ctx.AHCBPCY.NSymbols - 1;
        val := iNumBlockCBP + 1;
        ctx.AHCBPCY.Discriminant := ctx.AHCBPCY.Discriminant + ctx.AHCBPCY.Delta[iNumBlockCBP];
        iNumBlockCBP := 0;
        if val >= 6 then
        begin
          if BGet(io^, 1) <> 0 then iNumBlockCBP := $10
          else if BGet(io^, 1) <> 0 then iNumBlockCBP := $20
          else iNumBlockCBP := $30;
          if val = 9 then
          begin
            if BGet(io^, 1) <> 0 then
              // keep 9
            else if BGet(io^, 1) <> 0 then val := 10
            else val := 11;
          end;
          val := val - 6;
        end;
        if val > 5 then val := 5;
        iCode1 := gOff0[val];
        if gFLC0[val] <> 0 then iCode1 := iCode1 + BGet(io^, gFLC0[val]);
        iNumBlockCBP := iNumBlockCBP + gOut0[iCode1 and 15];

        case CF of
          CF_YUV444:
            begin
              iCBPCY := iCBPCY or ((iNumBlockCBP and $f) shl (iBlock * 4));
              for k := 0 to 1 do
                if ((iNumBlockCBP shr (k + 4)) and 1) <> 0 then
                begin
                  iCode := GetHuffShort(ctx.AHexpt[1].DecTable, io^);
                  case iCode of
                    1:
                      begin
                        iCode := BGet(io^, 2);
                        if iCode = 0 then iCode := 3
                        else if iCode = 1 then iCode := 5
                        else iCode := aTab[iCode * 2 + BGet(io^, 1) - 4];
                      end;
                    0: iCode := 1 shl BGet(io^, 2);
                    2: iCode := $f xor (1 shl BGet(io^, 2));
                    3: iCode := $f;
                  end;
                  if k = 0 then iCBPCU := iCBPCU or (iCode shl (iBlock * 4))
                  else iCBPCV := iCBPCV or (iCode shl (iBlock * 4));
                end;
            end;
          CF_YUV420:
            begin
              iCBPCY := iCBPCY or ((iNumBlockCBP and $f) shl (iBlock * 4));
              iCBPCU := iCBPCU or (((iNumBlockCBP shr 4) and 1) shl iBlock);
              iCBPCV := iCBPCV or (((iNumBlockCBP shr 5) and 1) shl iBlock);
            end;
          CF_YUV422:
            begin
              iCBPCY := iCBPCY or ((iNumBlockCBP and $f) shl (iBlock * 4));
              for k := 0 to 1 do
              begin
                iCode := 5;
                if ((iNumBlockCBP shr (k + 4)) and 1) <> 0 then
                begin
                  if BGet(io^, 1) <> 0 then iCode := 1
                  else if BGet(io^, 1) <> 0 then iCode := 4;
                  iCode := iCode shl iShift422[iBlock];
                  if k = 0 then iCBPCU := iCBPCU or iCode
                  else iCBPCV := iCBPCV or iCode;
                end;
              end;
            end;
        else
          iCBPCY := iCBPCY or (iNumBlockCBP shl (iBlock * 4));
        end;
      end;

    MB.iDiffCBP[i] := iCBPCY;
    if (CF = CF_YUV420) or (CF = CF_YUV444) or (CF = CF_YUV422) then
    begin
      MB.iDiffCBP[1] := iCBPCU;
      MB.iDiffCBP[2] := iCBPCV;
    end;
  end;
end;

// --------------------------- CBP prediction ----------------------------

function NumOnes(i: Integer): Integer;
const g_Count: array[0..15] of Integer = (0,1,1,2, 1,2,2,3, 1,2,2,3, 2,3,3,4);
begin
  Result := 0;
  i := i and $ffff;
  while i <> 0 do begin Result := Result + g_Count[i and $f]; i := i shr 4; end;
end;

procedure Saturate32(var x: Integer); inline;
begin
  if Cardinal(x + 16) >= 32 then
    if x < 0 then x := -16 else x := 15;
end;

procedure UpdateCBPModelState(var M: TCBPModel; c1, iNOrig: Integer);
begin
  M.Count0[c1] := M.Count0[c1] + iNOrig - AVG_NDIFF;
  Saturate32(M.Count0[c1]);
  M.Count1[c1] := M.Count1[c1] + 16 - iNOrig - AVG_NDIFF;
  Saturate32(M.Count1[c1]);
  if M.Count0[c1] < 0 then
  begin
    if M.Count0[c1] < M.Count1[c1] then M.State[c1] := 1 else M.State[c1] := 2;
  end
  else if M.Count1[c1] < 0 then M.State[c1] := 2
  else M.State[c1] := 0;
end;

procedure TJxrSC.PredCBPDec(ctx: PCodingContext);
var
  i, iChannels, mbX, iCBP, c1: Integer;

  function PredCBPC(iCBPx, c: Integer): Integer;
  begin
    if c <> 0 then c1 := 1 else c1 := 0;
    if ctx.CBPModel.State[c1] = 0 then
    begin
      if bCtxLeft then
      begin
        if bCtxTop then iCBPx := iCBPx xor 1
        else iCBPx := iCBPx xor ((PredPrev[c][mbX].iCBP shr 10) and 1);
      end
      else
        iCBPx := iCBPx xor ((Pred[c][mbX - 1].iCBP shr 5) and 1);
      iCBPx := iCBPx xor ($02 and (iCBPx shl 1));
      iCBPx := iCBPx xor ($10 and (iCBPx shl 3));
      iCBPx := iCBPx xor ($20 and (iCBPx shl 1));
      iCBPx := iCBPx xor ((iCBPx and $33) shl 2);
      iCBPx := iCBPx xor ((iCBPx and $cc) shl 6);
      iCBPx := iCBPx xor ((iCBPx and $3300) shl 2);
    end
    else if ctx.CBPModel.State[c1] = 2 then
      iCBPx := iCBPx xor $ffff;
    UpdateCBPModelState(ctx.CBPModel, c1, NumOnes(iCBPx));
    Result := iCBPx;
  end;

  function PredCBPC420(iCBPx, c: Integer): Integer;
  begin
    if ctx.CBPModel.State[1] = 0 then
    begin
      if bCtxLeft then
      begin
        if bCtxTop then iCBPx := iCBPx xor 1
        else iCBPx := iCBPx xor ((PredPrev[c][mbX].iCBP shr 2) and 1);
      end
      else
        iCBPx := iCBPx xor ((Pred[c][mbX - 1].iCBP shr 1) and 1);
      iCBPx := iCBPx xor ($02 and (iCBPx shl 1));
      iCBPx := iCBPx xor ((iCBPx and $3) shl 2);
    end
    else if ctx.CBPModel.State[1] = 2 then
      iCBPx := iCBPx xor $f;
    UpdateCBPModelState(ctx.CBPModel, 1, NumOnes(iCBPx) * 4);
    Result := iCBPx;
  end;

  function PredCBPC422(iCBPx, c: Integer): Integer;
  begin
    if ctx.CBPModel.State[1] = 0 then
    begin
      if bCtxLeft then
      begin
        if bCtxTop then iCBPx := iCBPx xor 1
        else iCBPx := iCBPx xor ((PredPrev[c][mbX].iCBP shr 6) and 1);
      end
      else
        iCBPx := iCBPx xor ((Pred[c][mbX - 1].iCBP shr 1) and 1);
      iCBPx := iCBPx xor ((iCBPx and $1) shl 1);
      iCBPx := iCBPx xor ((iCBPx and $3) shl 2);
      iCBPx := iCBPx xor ((iCBPx and $c) shl 2);
      iCBPx := iCBPx xor ((iCBPx and $30) shl 2);
    end
    else if ctx.CBPModel.State[1] = 2 then
      iCBPx := iCBPx xor $ff;
    UpdateCBPModelState(ctx.CBPModel, 1, NumOnes(iCBPx) * 2);
    Result := iCBPx;
  end;

begin
  mbX := cColumn;
  if (CF = CF_YUV420) or (CF = CF_YUV422) then iChannels := 1 else iChannels := NumCh;
  for i := 0 to iChannels - 1 do
  begin
    iCBP := PredCBPC(MB.iDiffCBP[i], i);
    MB.iCBP[i] := iCBP;
    Pred[i][mbX].iCBP := iCBP;
  end;
  if CF = CF_YUV422 then
  begin
    iCBP := PredCBPC422(MB.iDiffCBP[1], 1); MB.iCBP[1] := iCBP; Pred[1][mbX].iCBP := iCBP;
    iCBP := PredCBPC422(MB.iDiffCBP[2], 2); MB.iCBP[2] := iCBP; Pred[2][mbX].iCBP := iCBP;
  end
  else if CF = CF_YUV420 then
  begin
    iCBP := PredCBPC420(MB.iDiffCBP[1], 1); MB.iCBP[1] := iCBP; Pred[1][mbX].iCBP := iCBP;
    iCBP := PredCBPC420(MB.iDiffCBP[2], 2); MB.iCBP[2] := iCBP; Pred[2][mbX].iCBP := iCBP;
  end;
end;

// --------------------------- HP band -----------------------------------

function TJxrSC.DecodeCoeffs(ctx: PCodingContext): Boolean;
var
  t: PTile;
  io, ioFL: PBitIO;
  i, iBlock, iSubblock, iNBlocks, iPlanes, iModelBits, iQP, iIndex, iNumNonZero, pLM, qch: Integer;
  iCBPCY: Cardinal;
  LM: array[0..1] of Integer;
  pScan: PAdaptiveScan;
  pCoeffs: PInt;
  bChroma: Boolean;
begin
  Result := False;
  t := @Tiles[cTileColumn];
  io := ctx.IOAC; ioFL := ctx.IOFL;
  if (CF = CF_YUV420) or (CF = CF_YUV422) then iPlanes := 1 else iPlanes := NumCh;
  iModelBits := ctx.ModelAC.FlcBits[0];
  LM[0] := 0; LM[1] := 0; pLM := 0;
  bChroma := False;
  iCBPCY := Cardinal(MB.iCBP[0]);
  if MB.iOrientation = 1 then pScan := @ctx.ScanVert[0] else pScan := @ctx.ScanHoriz[0];

  iNBlocks := 4;
  if CF = CF_YUV420 then
  begin
    iNBlocks := 6;
    iCBPCY := iCBPCY + (Cardinal(MB.iCBP[1]) shl 16) + (Cardinal(MB.iCBP[2]) shl 20);
  end
  else if CF = CF_YUV422 then
  begin
    iNBlocks := 8;
    iCBPCY := iCBPCY + (Cardinal(MB.iCBP[1]) shl 16) + (Cardinal(MB.iCBP[2]) shl 24);
  end;

  for i := 0 to iPlanes - 1 do
  begin
    iIndex := 0;
    for iBlock := 0 to iNBlocks - 1 do
    begin
      if iPlanes > 1 then qch := i
      else if iBlock > 3 then
      begin
        if CF = CF_YUV420 then qch := iBlock - 3 else qch := iBlock div 2 - 1;
      end
      else qch := 0;
      iQP := t.QHP[qch][MB.iQIndexHP].QP;

      for iSubblock := 0 to 3 do
      begin
        pCoeffs := p1[i] + blkOffset[iIndex and $f];
        if iBlock >= 4 then
        begin
          if CF = CF_YUV420 then
            pCoeffs := p1[iBlock - 3] + blkOffsetUV[iSubblock]
          else
            pCoeffs := p1[1 + (1 and (iBlock shr 1))] + ((iBlock and 1) * 32) + blkOffsetUV_422[iSubblock];
        end;
        iNumNonZero := DecodeBlockAdaptive((iCBPCY and 1) <> 0, bChroma, ctx^, io, ioFL,
          pCoeffs, pScan, iModelBits, ctx.TrimFlexBits, iQP, SkipFlexbits);
        if iNumNonZero > 16 then Exit;
        LM[pLM] := LM[pLM] + iNumNonZero;
        Inc(iIndex);
        iCBPCY := iCBPCY shr 1;
      end;
      if iBlock = 3 then
      begin
        iModelBits := ctx.ModelAC.FlcBits[1];
        pLM := 1;
        bChroma := True;
      end;
    end;
    iCBPCY := Cardinal(MB.iCBP[(i + 1) and $f]);
  end;

  UpdateModelMB(CF, NumCh, LM, ctx.ModelAC);
  Result := True;
end;

function TJxrSC.DecodeMBHP(ctx: PCodingContext): Boolean;
var k, iWeight: Integer;
begin
  Result := False;
  if bResetRGITotals then
  begin
    iWeight := 2 * 16;
    ctx.ScanHoriz[0].uTotal := MAXTOTAL; ctx.ScanVert[0].uTotal := MAXTOTAL;
    for k := 1 to 15 do
    begin
      ctx.ScanHoriz[k].uTotal := iWeight; ctx.ScanVert[k].uTotal := iWeight;
      Dec(iWeight, 2);
    end;
  end;
  if (BF <> BF_SPATIAL) and (Tiles[cTileColumn].cBitsHP > 0) then
  begin
    MB.iQIndexHP := DecodeQPIndex(ctx.IOAC^, Tiles[cTileColumn].cBitsHP);
    if MB.iQIndexHP >= Tiles[cTileColumn].cNumQPHP then Exit;
  end
  else if (Tiles[cTileColumn].cBitsHP = 0) and (Tiles[cTileColumn].cNumQPHP > 1) then
    MB.iQIndexHP := MB.iQIndexLP;

  DecodeCBP(ctx);
  PredCBPDec(ctx);
  if not DecodeCoeffs(ctx) then Exit;
  if bResetContext then AdaptHighpassDec(ctx^);
  Result := True;
end;

// --------------------------- prediction --------------------------------

function TJxrSC.GetACPredMode: Integer;
var StrH, StrV: Integer; pc, pu, pv: PInt;
begin
  pc := @MB.iBlockDC[0, 0];
  StrH := Abs(pc[1]) + Abs(pc[2]) + Abs(pc[3]);
  StrV := Abs(pc[4]) + Abs(pc[8]) + Abs(pc[12]);
  if (CF <> CF_Y_ONLY) and (CF <> CF_NCOMPONENT) then
  begin
    pu := @MB.iBlockDC[1, 0];
    pv := @MB.iBlockDC[2, 0];
    StrH := StrH + Abs(pu[1]) + Abs(pv[1]);
    if CF = CF_YUV420 then
      StrV := StrV + Abs(pu[2]) + Abs(pv[2])
    else if CF = CF_YUV422 then
    begin
      StrV := StrV + Abs(pu[2]) + Abs(pv[2]) + Abs(pu[6]) + Abs(pv[6]);
      StrH := StrH + Abs(pu[5]) + Abs(pv[5]);
    end
    else
      StrV := StrV + Abs(pu[4]) + Abs(pv[4]);
  end;
  if StrH * ORIENT_WEIGHT < StrV then Result := 1
  else if StrV * ORIENT_WEIGHT < StrH then Result := 0
  else Result := 2;
end;

function TJxrSC.GetDCACPredMode(mbX: Integer): Integer;
var
  iDCMode, iADMode, iL, iT, iTL, StrH, StrV, scale: Integer;
begin
  iADMode := 2;
  if bCtxLeft and bCtxTop then iDCMode := 3
  else if bCtxLeft then iDCMode := 1
  else if bCtxTop then iDCMode := 0
  else
  begin
    iL := Pred[0][mbX - 1].iDC; iT := PredPrev[0][mbX].iDC; iTL := PredPrev[0][mbX - 1].iDC;
    if (CF = CF_Y_ONLY) or (CF = CF_NCOMPONENT) then
    begin
      StrH := Abs(iTL - iL);
      StrV := Abs(iTL - iT);
    end
    else
    begin
      if CF = CF_YUV420 then scale := 8 else if CF = CF_YUV422 then scale := 4 else scale := 2;
      StrH := Abs(iTL - iL) * scale
        + Abs(PredPrev[1][mbX - 1].iDC - Pred[1][mbX - 1].iDC)
        + Abs(PredPrev[2][mbX - 1].iDC - Pred[2][mbX - 1].iDC);
      StrV := Abs(iTL - iT) * scale
        + Abs(PredPrev[1][mbX - 1].iDC - PredPrev[1][mbX].iDC)
        + Abs(PredPrev[2][mbX - 1].iDC - PredPrev[2][mbX].iDC);
    end;
    if StrH * ORIENT_WEIGHT < StrV then iDCMode := 1
    else if StrV * ORIENT_WEIGHT < StrH then iDCMode := 0
    else iDCMode := 2;
  end;
  if (iDCMode = 1) and (MB.iQIndexLP = PredPrev[0][mbX].iQPIndex) then iADMode := 1;
  if (iDCMode = 0) and (MB.iQIndexLP = Pred[0][mbX - 1].iQPIndex) then iADMode := 0;
  Result := iDCMode + (iADMode shl 2);
end;

procedure TJxrSC.PredDCACDec;
var
  iChannels, mbX, iDCACPredMode, iDCPredMode, iADPredMode, ii: Integer;
  pOrg: PInt;
begin
  if (CF = CF_YUV420) or (CF = CF_YUV422) then iChannels := 1 else iChannels := NumCh;
  mbX := cColumn;
  iDCACPredMode := GetDCACPredMode(mbX);
  iDCPredMode := iDCACPredMode and $3;
  iADPredMode := iDCACPredMode and $C;

  for ii := 0 to iChannels - 1 do
  begin
    pOrg := @MB.iBlockDC[ii, 0];
    if iDCPredMode = 1 then
      pOrg[0] := pOrg[0] + PredPrev[ii][mbX].iDC
    else if iDCPredMode = 0 then
      pOrg[0] := pOrg[0] + Pred[ii][mbX - 1].iDC
    else if iDCPredMode = 2 then
      pOrg[0] := pOrg[0] + Asr(Pred[ii][mbX - 1].iDC + PredPrev[ii][mbX].iDC, 1);

    if iADPredMode = 4 then
    begin
      pOrg[4] := pOrg[4] + PredPrev[ii][mbX].iAD[3];
      pOrg[8] := pOrg[8] + PredPrev[ii][mbX].iAD[4];
      pOrg[12] := pOrg[12] + PredPrev[ii][mbX].iAD[5];
    end
    else if iADPredMode = 0 then
    begin
      pOrg[1] := pOrg[1] + Pred[ii][mbX - 1].iAD[0];
      pOrg[2] := pOrg[2] + Pred[ii][mbX - 1].iAD[1];
      pOrg[3] := pOrg[3] + Pred[ii][mbX - 1].iAD[2];
    end;
  end;

  if CF = CF_YUV420 then
  begin
    for ii := 1 to 2 do
    begin
      pOrg := @MB.iBlockDC[ii, 0];
      if iDCPredMode = 1 then
        pOrg[0] := pOrg[0] + PredPrev[ii][mbX].iDC
      else if iDCPredMode = 0 then
        pOrg[0] := pOrg[0] + Pred[ii][mbX - 1].iDC
      else if iDCPredMode = 2 then
        pOrg[0] := pOrg[0] + Asr(Pred[ii][mbX - 1].iDC + PredPrev[ii][mbX].iDC + 1, 1);
      if iADPredMode = 4 then
        pOrg[2] := pOrg[2] + PredPrev[ii][mbX].iAD[1]
      else if iADPredMode = 0 then
        pOrg[1] := pOrg[1] + Pred[ii][mbX - 1].iAD[0];
    end;
  end
  else if CF = CF_YUV422 then
  begin
    for ii := 1 to 2 do
    begin
      pOrg := @MB.iBlockDC[ii, 0];
      if iDCPredMode = 1 then
        pOrg[0] := pOrg[0] + PredPrev[ii][mbX].iDC
      else if iDCPredMode = 0 then
        pOrg[0] := pOrg[0] + Pred[ii][mbX - 1].iDC
      else if iDCPredMode = 2 then
        pOrg[0] := pOrg[0] + Asr(Pred[ii][mbX - 1].iDC + PredPrev[ii][mbX].iDC + 1, 1);
      if iADPredMode = 4 then
      begin
        pOrg[4] := pOrg[4] + PredPrev[ii][mbX].iAD[4];
        pOrg[2] := pOrg[2] + PredPrev[ii][mbX].iAD[3];
        pOrg[6] := pOrg[6] + pOrg[2];
      end
      else if iADPredMode = 0 then
      begin
        pOrg[4] := pOrg[4] + Pred[ii][mbX - 1].iAD[4];
        pOrg[1] := pOrg[1] + Pred[ii][mbX - 1].iAD[0];
        pOrg[5] := pOrg[5] + Pred[ii][mbX - 1].iAD[2];
      end
      else if iDCPredMode = 1 then
        pOrg[6] := pOrg[6] + pOrg[2];
    end;
  end;
  MB.iOrientation := 2 - GetACPredMode;
end;

procedure TJxrSC.PredACDec;
const
  blkIdxTop: array[0..11] of Integer = (1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 14, 15);
var
  iChannels, iACPredMode, i, j: Integer;
  pSrc, pOrg, pRef: PInt;
begin
  if (CF = CF_YUV420) or (CF = CF_YUV422) then iChannels := 1 else iChannels := NumCh;
  iACPredMode := 2 - MB.iOrientation;
  for i := 0 to iChannels - 1 do
  begin
    pSrc := p1[i];
    case iACPredMode of
      1:
        for j := 0 to 11 do
        begin
          pOrg := pSrc + 16 * blkIdxTop[j];
          pRef := pOrg - 16;
          pOrg[2] := pOrg[2] + pRef[2];
          pOrg[10] := pOrg[10] + pRef[10];
          pOrg[9] := pOrg[9] + pRef[9];
        end;
      0:
        begin
          j := 64;
          while j < 256 do
          begin
            pOrg := pSrc + j;
            pRef := pOrg - 64;
            pOrg[1] := pOrg[1] + pRef[1];
            pOrg[5] := pOrg[5] + pRef[5];
            pOrg[6] := pOrg[6] + pRef[6];
            Inc(j, 16);
          end;
        end;
    end;
  end;

  if CF = CF_YUV420 then
  begin
    for i := 1 to 2 do
    begin
      pSrc := p1[i];
      case iACPredMode of
        1:
          begin
            j := 1;
            while j <= 3 do
            begin
              pOrg := pSrc + 16 * j;
              pRef := pOrg - 16;
              pOrg[2] := pOrg[2] + pRef[2];
              pOrg[10] := pOrg[10] + pRef[10];
              pOrg[9] := pOrg[9] + pRef[9];
              Inc(j, 2);
            end;
          end;
        0:
          for j := 2 to 3 do
          begin
            pOrg := pSrc + 16 * j;
            pRef := pOrg - 32;
            pOrg[1] := pOrg[1] + pRef[1];
            pOrg[5] := pOrg[5] + pRef[5];
            pOrg[6] := pOrg[6] + pRef[6];
          end;
      end;
    end;
  end
  else if CF = CF_YUV422 then
  begin
    for i := 1 to 2 do
    begin
      pSrc := p1[i];
      case iACPredMode of
        1:
          for j := 2 to 7 do
          begin
            pOrg := pSrc + blkOffsetUV_422[j];
            pRef := pOrg - 16;
            pOrg[10] := pOrg[10] + pRef[10];
            pOrg[2] := pOrg[2] + pRef[2];
            pOrg[9] := pOrg[9] + pRef[9];
          end;
        0:
          begin
            j := 1;
            while j < 8 do
            begin
              pOrg := pSrc + blkOffsetUV_422[j];
              pRef := pOrg - 64;
              pOrg[1] := pOrg[1] + pRef[1];
              pOrg[5] := pOrg[5] + pRef[5];
              pOrg[6] := pOrg[6] + pRef[6];
              Inc(j, 2);
            end;
          end;
      end;
    end;
  end;
end;

procedure TJxrSC.DequantizeMB;
var
  i, k, qp: Integer;
  t: PTile;
  pRec, pOrg: PInt;
begin
  t := @Tiles[cTileColumn];
  for i := 0 to NumCh - 1 do
  begin
    pRec := p1[i];
    pOrg := @MB.iBlockDC[i, 0];
    pRec[0] := pOrg[0] * t.QDC[i][0].QP;
    if Subband <> SB_DC_ONLY then
    begin
      qp := t.QLP[i][MB.iQIndexLP].QP;
      if (i = 0) or ((CF <> CF_YUV422) and (CF <> CF_YUV420)) then
      begin
        for k := 1 to 15 do pRec[dctIndex[2, k]] := pOrg[k] * qp;
      end
      else if CF = CF_YUV422 then
      begin
        pRec[64] := pOrg[1] * qp;
        pRec[16] := pOrg[2] * qp;
        pRec[80] := pOrg[3] * qp;
        pRec[32] := pOrg[4] * qp;
        pRec[96] := pOrg[5] * qp;
        pRec[48] := pOrg[6] * qp;
        pRec[112] := pOrg[7] * qp;
      end
      else
      begin
        pRec[32] := pOrg[1] * qp;
        pRec[16] := pOrg[2] * qp;
        pRec[48] := pOrg[3] * qp;
      end;
    end;
  end;
end;

procedure TJxrSC.UpdatePredInfo;
var
  i, iChannels, mbX: Integer;
  pc: PInt;
begin
  mbX := cColumn;
  if (CF = CF_YUV420) or (CF = CF_YUV422) then iChannels := 1 else iChannels := NumCh;
  for i := 0 to iChannels - 1 do
  begin
    pc := @MB.iBlockDC[i, 0];
    Pred[i][mbX].iDC := pc[0];
    Pred[i][mbX].iQPIndex := MB.iQIndexLP;
    Pred[i][mbX].iAD[0] := pc[1];
    Pred[i][mbX].iAD[1] := pc[2];
    Pred[i][mbX].iAD[2] := pc[3];
    Pred[i][mbX].iAD[3] := pc[4];
    Pred[i][mbX].iAD[4] := pc[8];
    Pred[i][mbX].iAD[5] := pc[12];
  end;
  if CF = CF_YUV420 then
  begin
    for i := 1 to 2 do
    begin
      pc := @MB.iBlockDC[i, 0];
      Pred[i][mbX].iDC := pc[0];
      Pred[i][mbX].iQPIndex := MB.iQIndexLP;
      Pred[i][mbX].iAD[0] := pc[1];
      Pred[i][mbX].iAD[1] := pc[2];
    end;
  end
  else if CF = CF_YUV422 then
  begin
    for i := 1 to 2 do
    begin
      pc := @MB.iBlockDC[i, 0];
      Pred[i][mbX].iQPIndex := MB.iQIndexLP;
      Pred[i][mbX].iDC := pc[0];
      Pred[i][mbX].iAD[0] := pc[1];
      Pred[i][mbX].iAD[1] := pc[2];
      Pred[i][mbX].iAD[2] := pc[5];
      Pred[i][mbX].iAD[3] := pc[6];
      Pred[i][mbX].iAD[4] := pc[4];
    end;
  end;
end;

// ---------------------- inverse transform (original) -------------------

procedure TJxrSC.InvTransformMB;
var
  left, right, top, bottom, topORbottom, leftORright, bottomORright, bHPAbsent: Boolean;
  i, j, iChannels, iHPQP, jEnd: Integer;
  q0, q1, p: PInt;
begin
  left := cColumn = 0; right := cColumn = cmbWidth;
  top := cRow = 0; bottom := cRow = cmbHeight;
  topORbottom := top or bottom; leftORright := left or right;
  bottomORright := bottom or right;
  if (CF = CF_YUV420) or (CF = CF_YUV422) then iChannels := 1 else iChannels := NumCh;
  bHPAbsent := (Subband = SB_NO_HIGHPASS) or (Subband = SB_DC_ONLY);

  // ---- 400_Y, 444_YUV ----
  for i := 0 to iChannels - 1 do
  begin
    q0 := p0[i]; q1 := p1[i];
    iHPQP := 255;
    if not bHPAbsent then iHPQP := Tiles[cTileColumn].QHP[i][MB.iQIndexHP].QP;

    if not bottomORright then
    begin
      strIDCT4x4Stage2(q1);
      if ScaledArith then strNormalizeDec(q1, i <> 0);
    end;

    if Overlap = OL_TWO then
    begin
      if leftORright and (not topORbottom) then
      begin
        if left then j := 0 else j := -128;
        strPost4(q0 + j + 32, q0 + j + 48, q1 + j + 0, q1 + j + 16);
        strPost4(q0 + j + 96, q0 + j + 112, q1 + j + 64, q1 + j + 80);
      end;
      if not leftORright then
      begin
        if topORbottom then
        begin
          if top then p := q1 else p := q0 + 32;
          strPost4(p - 128, p - 64, p + 0, p + 64);
          strPost4(p - 112, p - 48, p + 16, p + 80);
        end
        else
          strPost4x4Stage2Split(q0, q1);
      end;
    end;

    if not top then
    begin
      if left then j := 32 else j := -96;
      if right then jEnd := 32 else jEnd := 160;
      while j < jEnd do begin strIDCT4x4Stage1(q0 + j + 0); strIDCT4x4Stage1(q0 + j + 16); Inc(j, 64); end;
    end;
    if not bottom then
    begin
      if left then j := 0 else j := -128;
      if right then jEnd := 0 else jEnd := 128;
      while j < jEnd do begin strIDCT4x4Stage1(q1 + j + 0); strIDCT4x4Stage1(q1 + j + 16); Inc(j, 64); end;
    end;

    if Overlap <> OL_NONE then
    begin
      if leftORright then
      begin
        if left then j := 0 + 10 else j := -64 + 14;
        if not top then
        begin
          p := q0 + 16 + j;
          strPost4(p + 0, p - 2, p + 6, p + 8);
          strPost4(p + 1, p - 1, p + 7, p + 9);
          strPost4(p + 16, p + 14, p + 22, p + 24);
          strPost4(p + 17, p + 15, p + 23, p + 25);
        end;
        if not bottom then
        begin
          p := q1 + j;
          strPost4(p + 0, p - 2, p + 6, p + 8);
          strPost4(p + 1, p - 1, p + 7, p + 9);
        end;
        if not topORbottom then
        begin
          strPost4(q0 + 48 + j + 0, q0 + 48 + j - 2, q1 - 10 + j, q1 - 8 + j);
          strPost4(q0 + 48 + j + 1, q0 + 48 + j - 1, q1 - 9 + j, q1 - 7 + j);
        end;
      end;

      if left then j := 0 else j := -192;
      if right then jEnd := -64 else jEnd := 64;
      if top then
      begin
        while j < jEnd do
        begin
          p := q1 + j;
          strPost4(p + 5, p + 4, p + 64, p + 65);
          strPost4(p + 7, p + 6, p + 66, p + 67);
          strPost4x4Stage1(q1 + j, 0, iHPQP, bHPAbsent);
          Inc(j, 64);
        end;
      end
      else if bottom then
      begin
        while j < jEnd do
        begin
          strPost4x4Stage1(q0 + 16 + j, 0, iHPQP, bHPAbsent);
          strPost4x4Stage1(q0 + 32 + j, 0, iHPQP, bHPAbsent);
          p := q0 + 48 + j;
          strPost4(p + 15, p + 14, p + 74, p + 75);
          strPost4(p + 13, p + 12, p + 72, p + 73);
          Inc(j, 64);
        end;
      end
      else
      begin
        while j < jEnd do
        begin
          strPost4x4Stage1(q0 + 16 + j, 0, iHPQP, bHPAbsent);
          strPost4x4Stage1(q0 + 32 + j, 0, iHPQP, bHPAbsent);
          strPost4x4Stage1Split(q0 + 48 + j, q1 + j, 0, iHPQP, bHPAbsent);
          strPost4x4Stage1(q1 + j, 0, iHPQP, bHPAbsent);
          Inc(j, 64);
        end;
      end;
    end;
  end;

  // ---- 420_UV ----
  if CF = CF_YUV420 then
  for i := 0 to 1 do
  begin
    q0 := p0[1 + i]; q1 := p1[1 + i];
    iHPQP := 255;
    if not bHPAbsent then iHPQP := Tiles[cTileColumn].QHP[i][MB.iQIndexHP].QP;

    if not bottomORright then
    begin
      if not ScaledArith then strDCT2x2dn(q1, q1 + 32, q1 + 16, q1 + 48)
      else strDCT2x2dnDec(q1, q1 + 32, q1 + 16, q1 + 48);
    end;

    if Overlap = OL_TWO then
    begin
      if leftORright and (not topORbottom) then
      begin
        if left then j := 0 else j := -32;
        strPost2(q0 + j + 16, q1 + j);
      end;
      if not leftORright then
      begin
        if topORbottom then
        begin
          if top then p := q1 else p := q0 + 16;
          strPost2(p - 32, p);
        end
        else
          strPost2x2(q0 - 16, q0 + 16, q1 - 32, q1);
      end;
    end;

    if not top then
    begin
      if left then j := 16 else j := -16;
      if right then jEnd := 16 else jEnd := 48;
      while j < jEnd do begin strIDCT4x4Stage1(q0 + j); Inc(j, 32); end;
    end;
    if not bottom then
    begin
      if left then j := 0 else j := -32;
      if right then jEnd := 0 else jEnd := 32;
      while j < jEnd do begin strIDCT4x4Stage1(q1 + j); Inc(j, 32); end;
    end;

    if Overlap <> OL_NONE then
    begin
      if (not left) and (not top) then
      begin
        if right then jEnd := -16 else jEnd := 16;
        j := -48;
        if bottom then
        begin
          while j < jEnd do
          begin
            p := q0 + j;
            strPost4(p + 15, p + 14, p + 42, p + 43);
            strPost4(p + 13, p + 12, p + 40, p + 41);
            Inc(j, 32);
          end;
        end
        else
        begin
          while j < jEnd do
          begin
            strPost4x4Stage1Split(q0 + j, q1 - 16 + j, 32, iHPQP, bHPAbsent);
            Inc(j, 32);
          end;
        end;
        if right then
        begin
          if not bottom then
          begin
            strPost4(q0 - 2, q0 - 4, q1 - 28, q1 - 26);
            strPost4(q0 - 1, q0 - 3, q1 - 27, q1 - 25);
          end;
          strPost4(q0 - 18, q0 - 20, q0 - 12, q0 - 10);
          strPost4(q0 - 17, q0 - 19, q0 - 11, q0 - 9);
        end
        else
          strPost4x4Stage1(q0 - 32, 32, iHPQP, bHPAbsent);
        strPost4x4Stage1(q0 - 64, 32, iHPQP, bHPAbsent);
      end
      else if top then
      begin
        if left then j := 0 else j := -64;
        if right then jEnd := -32 else jEnd := 0;
        while j < jEnd do
        begin
          p := q1 + j + 4;
          strPost4(p + 1, p + 0, p + 28, p + 29);
          strPost4(p + 3, p + 2, p + 30, p + 31);
          Inc(j, 32);
        end;
      end
      else if left then
      begin
        if not bottom then
        begin
          strPost4(q0 + 26, q0 + 24, q1 + 0, q1 + 2);
          strPost4(q0 + 27, q0 + 25, q1 + 1, q1 + 3);
        end;
        strPost4(q0 + 10, q0 + 8, q0 + 16, q0 + 18);
        strPost4(q0 + 11, q0 + 9, q0 + 17, q0 + 19);
      end;
    end;
  end;

  // ---- 422_UV ----
  if CF = CF_YUV422 then
  for i := 0 to 1 do
  begin
    q0 := p0[1 + i]; q1 := p1[1 + i];
    iHPQP := 255;
    if not bHPAbsent then iHPQP := Tiles[cTileColumn].QHP[i][MB.iQIndexHP].QP;

    if not bottomORright then
    begin
      q1[0] := q1[0] - Asr(q1[32] + 1, 1);
      q1[32] := q1[32] + q1[0];
      if not ScaledArith then
      begin
        strDCT2x2dn(q1 + 0, q1 + 64, q1 + 16, q1 + 80);
        strDCT2x2dn(q1 + 32, q1 + 96, q1 + 48, q1 + 112);
      end
      else
      begin
        strDCT2x2dnDec(q1 + 0, q1 + 64, q1 + 16, q1 + 80);
        strDCT2x2dnDec(q1 + 32, q1 + 96, q1 + 48, q1 + 112);
      end;
    end;

    if Overlap = OL_TWO then
    begin
      if not bottom then
      begin
        if leftORright then
        begin
          if not top then
          begin
            if left then j := 0 else j := -64;
            strPost2(q0 + 48 + j, q1 + j);
          end;
          if left then j := 16 else j := -48;
          strPost2(q1 + j, q1 + j + 16);
        end
        else
        begin
          if top then strPost2(q1 - 64, q1)
          else strPost2x2(q0 - 16, q0 + 48, q1 - 64, q1);
          strPost2x2(q1 - 48, q1 + 16, q1 - 32, q1 + 32);
        end;
      end
      else if not leftORright then
        strPost2(q0 - 16, q0 + 48);
    end;

    if not top then
    begin
      if left then j := 48 else j := -16;
      if right then jEnd := 48 else jEnd := 112;
      while j < jEnd do begin strIDCT4x4Stage1(q0 + j); Inc(j, 64); end;
    end;
    if not bottom then
    begin
      if left then j := 0 else j := -64;
      if right then jEnd := 0 else jEnd := 64;
      while j < jEnd do
      begin
        strIDCT4x4Stage1(q1 + j + 0);
        strIDCT4x4Stage1(q1 + j + 16);
        strIDCT4x4Stage1(q1 + j + 32);
        Inc(j, 64);
      end;
    end;

    if Overlap <> OL_NONE then
    begin
      if not top then
      begin
        if leftORright then
        begin
          if left then j := 32 + 10 else j := -32 + 14;
          p := q0 + j;
          strPost4(p + 0, p - 2, p + 6, p + 8);
          strPost4(p + 1, p - 1, p + 7, p + 9);
        end;
        if left then j := 0 else j := -128;
        if right then jEnd := -64 else jEnd := 0;
        while j < jEnd do begin strPost4x4Stage1(q0 + j + 32, 0, iHPQP, bHPAbsent); Inc(j, 64); end;
      end;
      if not bottom then
      begin
        if leftORright then
        begin
          if left then j := 0 + 10 else j := -64 + 14;
          p := q1 + j;
          strPost4(p + 0, p - 2, p + 6, p + 8);
          strPost4(p + 1, p - 1, p + 7, p + 9);
          p := p + 16;
          strPost4(p + 0, p - 2, p + 6, p + 8);
          strPost4(p + 1, p - 1, p + 7, p + 9);
        end;
        if left then j := 0 else j := -128;
        if right then jEnd := -64 else jEnd := 0;
        while j < jEnd do
        begin
          strPost4x4Stage1(q1 + j + 0, 0, iHPQP, bHPAbsent);
          strPost4x4Stage1(q1 + j + 16, 0, iHPQP, bHPAbsent);
          Inc(j, 64);
        end;
      end;
      if topORbottom then
      begin
        if top then p := q1 + 5 else p := q0 + 48 + 13;
        if left then j := 0 else j := -128;
        if right then jEnd := -64 else jEnd := 0;
        while j < jEnd do
        begin
          strPost4(p + j + 0, p + j - 1, p + j + 59, p + j + 60);
          strPost4(p + j + 2, p + j + 1, p + j + 61, p + j + 62);
          Inc(j, 64);
        end;
      end
      else
      begin
        if leftORright then
        begin
          if left then j := 0 + 0 else j := -64 + 4;
          strPost4(q0 + j + 48 + 10 + 0, q0 + j + 48 + 10 - 2, q1 + j + 0, q1 + j + 2);
          strPost4(q0 + j + 48 + 10 + 1, q0 + j + 48 + 10 - 1, q1 + j + 1, q1 + j + 3);
        end;
        if left then j := 0 else j := -128;
        if right then jEnd := -64 else jEnd := 0;
        while j < jEnd do
        begin
          strPost4x4Stage1Split(q0 + j + 48, q1 + j + 0, 0, iHPQP, bHPAbsent);
          Inc(j, 64);
        end;
      end;
    end;
  end;
end;

// -------------- inverse transform (altered operators / hard tiles) ------

procedure TJxrSC.InvTransformMBHard;
var
  left, right, top, bottom, topORbottom, leftORright, bottomORright: Boolean;
  leftAdj, rightAdj: Boolean;
  i, j, iChannels, jEnd: Integer;
  q0, q1, p: PInt;
begin
  left := cColumn = 0; right := cColumn = cmbWidth;
  top := cRow = 0; bottom := cRow = cmbHeight;
  topORbottom := top or bottom; leftORright := left or right;
  bottomORright := bottom or right;
  leftAdj := cColumn = 1; rightAdj := cColumn = cmbWidth - 1;
  if (CF = CF_YUV420) or (CF = CF_YUV422) then iChannels := 1 else iChannels := NumCh;

  // tile boundary tracking (naming follows jxrlib literally)
  if HardTiles then
  begin
    if cColumn = 0 then begin bVertTB := False; htileY := 0; end;
    bOneMBLeftVertTB := False; bOneMBRightVertTB := False;
    if (htileY > 0) and (htileY <= NumSliceH) and (Cardinal(cColumn - 1) = TileYs[htileY]) then
      bOneMBRightVertTB := True;
    if (htileY < NumSliceH) and (Cardinal(cColumn) = TileYs[htileY + 1]) then
    begin bVertTB := True; Inc(htileY); end
    else
      bVertTB := False;
    if (htileY < NumSliceH) and (Cardinal(cColumn + 1) = TileYs[htileY + 1]) then
      bOneMBLeftVertTB := True;
    if cRow = 0 then begin bHoriTB := False; htileX := 0; end
    else if (hmbY <> cRow) and (htileX < NumSliceV) and (Cardinal(cRow) = TileXs[htileX + 1]) then
    begin bHoriTB := True; Inc(htileX); end
    else if hmbY <> cRow then
      bHoriTB := False;
  end
  else
  begin
    bVertTB := False; bHoriTB := False;
    bOneMBLeftVertTB := False; bOneMBRightVertTB := False;
  end;
  hmbX := cColumn; hmbY := cRow;

  // ---- 400_Y, 444_YUV ----
  for i := 0 to iChannels - 1 do
  begin
    q0 := p0[i]; q1 := p1[i];
    if not bottomORright then
    begin
      strIDCT4x4Stage2(q1);
      if ScaledArith then strNormalizeDec(q1, i <> 0);
    end;

    if Overlap = OL_TWO then
    begin
      if (top or bHoriTB) and (left or bVertTB) then
        strPost4_alternate(q1 + 0, q1 + 64, q1 + 0 + 16, q1 + 64 + 16);
      if (top or bHoriTB) and (right or bVertTB) then
        strPost4_alternate(q1 - 128, q1 - 64, q1 - 128 + 16, q1 - 64 + 16);
      if (bottom or bHoriTB) and (left or bVertTB) then
        strPost4_alternate(q0 + 32, q0 + 96, q0 + 32 + 16, q0 + 96 + 16);
      if (bottom or bHoriTB) and (right or bVertTB) then
        strPost4_alternate(q0 - 96, q0 - 32, q0 - 96 + 16, q0 - 32 + 16);
      if (leftORright or bVertTB) and ((not topORbottom) and (not bHoriTB)) then
      begin
        if left or bVertTB then
        begin
          j := 0;
          strPost4_alternate(q0 + j + 32, q0 + j + 48, q1 + j + 0, q1 + j + 16);
          strPost4_alternate(q0 + j + 96, q0 + j + 112, q1 + j + 64, q1 + j + 80);
        end;
        if right or bVertTB then
        begin
          j := -128;
          strPost4_alternate(q0 + j + 32, q0 + j + 48, q1 + j + 0, q1 + j + 16);
          strPost4_alternate(q0 + j + 96, q0 + j + 112, q1 + j + 64, q1 + j + 80);
        end;
      end;
      if not leftORright then
      begin
        if (topORbottom or bHoriTB) and (not bVertTB) then
        begin
          if top or bHoriTB then
          begin
            p := q1;
            strPost4_alternate(p - 128, p - 64, p + 0, p + 64);
            strPost4_alternate(p - 112, p - 48, p + 16, p + 80);
          end;
          if bottom or bHoriTB then
          begin
            p := q0 + 32;
            strPost4_alternate(p - 128, p - 64, p + 0, p + 64);
            strPost4_alternate(p - 112, p - 48, p + 16, p + 80);
          end;
        end;
        if (not topORbottom) and (not bHoriTB) and (not bVertTB) then
          strPost4x4Stage2Split_alternate(q0, q1);
      end;
    end;

    if not top then
    begin
      if left then j := 32 else j := -96;
      if right then jEnd := 32 else jEnd := 160;
      while j < jEnd do begin strIDCT4x4Stage1(q0 + j + 0); strIDCT4x4Stage1(q0 + j + 16); Inc(j, 64); end;
    end;
    if not bottom then
    begin
      if left then j := 0 else j := -128;
      if right then jEnd := 0 else jEnd := 128;
      while j < jEnd do begin strIDCT4x4Stage1(q1 + j + 0); strIDCT4x4Stage1(q1 + j + 16); Inc(j, 64); end;
    end;

    if Overlap <> OL_NONE then
    begin
      if leftORright or bVertTB then
      begin
        if (top or bHoriTB) and (left or bVertTB) then
          strPost4_alternate(q1 + 0, q1 + 1, q1 + 2, q1 + 3);
        if (top or bHoriTB) and (right or bVertTB) then
          strPost4_alternate(q1 - 59, q1 - 60, q1 - 57, q1 - 58);
        if (bottom or bHoriTB) and (left or bVertTB) then
          strPost4_alternate(q0 + 48 + 10, q0 + 48 + 11, q0 + 48 + 8, q0 + 48 + 9);
        if (bottom or bHoriTB) and (right or bVertTB) then
          strPost4_alternate(q0 - 1, q0 - 2, q0 - 3, q0 - 4);
        if left or bVertTB then
        begin
          j := 0 + 10;
          if not top then
          begin
            p := q0 + 16 + j;
            strPost4_alternate(p + 0, p - 2, p + 6, p + 8);
            strPost4_alternate(p + 1, p - 1, p + 7, p + 9);
            strPost4_alternate(p + 16, p + 14, p + 22, p + 24);
            strPost4_alternate(p + 17, p + 15, p + 23, p + 25);
          end;
          if not bottom then
          begin
            p := q1 + j;
            strPost4_alternate(p + 0, p - 2, p + 6, p + 8);
            strPost4_alternate(p + 1, p - 1, p + 7, p + 9);
          end;
          if (not topORbottom) and (not bHoriTB) then
          begin
            strPost4_alternate(q0 + 48 + j + 0, q0 + 48 + j - 2, q1 - 10 + j, q1 - 8 + j);
            strPost4_alternate(q0 + 48 + j + 1, q0 + 48 + j - 1, q1 - 9 + j, q1 - 7 + j);
          end;
        end;
        if right or bVertTB then
        begin
          j := -64 + 14;
          if not top then
          begin
            p := q0 + 16 + j;
            strPost4_alternate(p + 0, p - 2, p + 6, p + 8);
            strPost4_alternate(p + 1, p - 1, p + 7, p + 9);
            strPost4_alternate(p + 16, p + 14, p + 22, p + 24);
            strPost4_alternate(p + 17, p + 15, p + 23, p + 25);
          end;
          if not bottom then
          begin
            p := q1 + j;
            strPost4_alternate(p + 0, p - 2, p + 6, p + 8);
            strPost4_alternate(p + 1, p - 1, p + 7, p + 9);
          end;
          if (not topORbottom) and (not bHoriTB) then
          begin
            strPost4_alternate(q0 + 48 + j + 0, q0 + 48 + j - 2, q1 - 10 + j, q1 - 8 + j);
            strPost4_alternate(q0 + 48 + j + 1, q0 + 48 + j - 1, q1 - 9 + j, q1 - 7 + j);
          end;
        end;
      end;

      if left then j := 0 else j := -192;
      if right then jEnd := -64 else jEnd := 64;
      if top or bHoriTB then
      begin
        j := IfThen(left, 0, -192);
        while j < jEnd do
        begin
          if (not bVertTB) or (j <> -64) then
          begin
            p := q1 + j;
            strPost4_alternate(p + 5, p + 4, p + 64, p + 65);
            strPost4_alternate(p + 7, p + 6, p + 66, p + 67);
            strPost4x4Stage1_alternate(q1 + j, 0);
          end;
          Inc(j, 64);
        end;
      end;
      if bottom or bHoriTB then
      begin
        j := IfThen(left, 0, -192);
        while j < jEnd do
        begin
          if (not bVertTB) or (j <> -64) then
          begin
            strPost4x4Stage1_alternate(q0 + 16 + j, 0);
            strPost4x4Stage1_alternate(q0 + 32 + j, 0);
            p := q0 + 48 + j;
            strPost4_alternate(p + 15, p + 14, p + 74, p + 75);
            strPost4_alternate(p + 13, p + 12, p + 72, p + 73);
          end;
          Inc(j, 64);
        end;
      end;
      if (not top) and (not bottom) and (not bHoriTB) then
      begin
        j := IfThen(left, 0, -192);
        while j < jEnd do
        begin
          if (not bVertTB) or (j <> -64) then
          begin
            strPost4x4Stage1_alternate(q0 + 16 + j, 0);
            strPost4x4Stage1_alternate(q0 + 32 + j, 0);
            strPost4x4Stage1Split_alternate(q0 + 48 + j, q1 + j, 0);
            strPost4x4Stage1_alternate(q1 + j, 0);
          end;
          Inc(j, 64);
        end;
      end;
    end;
  end;

  // ---- 420_UV ----
  if CF = CF_YUV420 then
  for i := 0 to 1 do
  begin
    q0 := p0[1 + i]; q1 := p1[1 + i];
    if not bottomORright then
    begin
      if not ScaledArith then strDCT2x2dn(q1, q1 + 32, q1 + 16, q1 + 48)
      else strDCT2x2dnDec(q1, q1 + 32, q1 + 16, q1 + 48);
    end;

    if Overlap = OL_TWO then
    begin
      if (leftAdj or bOneMBRightVertTB) and (top or bHoriTB) then
        q1[-64 + 0] := q1[-64 + 0] - q1[-64 + 32];
      if (rightAdj or bOneMBLeftVertTB) and (top or bHoriTB) then
        iPredBefore[i, 0] := q1[0];
      if (right or bVertTB) and (top or bHoriTB) then
        q1[-64 + 32] := q1[-64 + 32] - iPredBefore[i, 0];
      if (leftAdj or bOneMBRightVertTB) and (bottom or bHoriTB) then
        q0[-64 + 16] := q0[-64 + 16] - q0[-64 + 48];
      if (rightAdj or bOneMBLeftVertTB) and (bottom or bHoriTB) then
        iPredBefore[i, 1] := q0[16];
      if (right or bVertTB) and (bottom or bHoriTB) then
        q0[-64 + 48] := q0[-64 + 48] - iPredBefore[i, 1];

      if (leftORright or bVertTB) and (not topORbottom) and (not bHoriTB) then
      begin
        if left or bVertTB then strPost2_alternate(q0 + 0 + 16, q1 + 0);
        if right or bVertTB then strPost2_alternate(q0 - 32 + 16, q1 - 32);
      end;
      if not leftORright then
      begin
        if (topORbottom or bHoriTB) and (not bVertTB) then
        begin
          if top or bHoriTB then strPost2_alternate(q1 - 32, q1);
          if bottom or bHoriTB then strPost2_alternate(q0 + 16 - 32, q0 + 16);
        end
        else if (not topORbottom) and (not bHoriTB) and (not bVertTB) then
          strPost2x2_alternate(q0 - 16, q0 + 16, q1 - 32, q1);
      end;

      if (leftAdj or bOneMBRightVertTB) and (top or bHoriTB) then
        q1[-64 + 0] := q1[-64 + 0] + q1[-64 + 32];
      if (rightAdj or bOneMBLeftVertTB) and (top or bHoriTB) then
        iPredAfter[i, 0] := q1[0];
      if (right or bVertTB) and (top or bHoriTB) then
        q1[-64 + 32] := q1[-64 + 32] + iPredAfter[i, 0];
      if (leftAdj or bOneMBRightVertTB) and (bottom or bHoriTB) then
        q0[-64 + 16] := q0[-64 + 16] + q0[-64 + 48];
      if (rightAdj or bOneMBLeftVertTB) and (bottom or bHoriTB) then
        iPredAfter[i, 1] := q0[16];
      if (right or bVertTB) and (bottom or bHoriTB) then
        q0[-64 + 48] := q0[-64 + 48] + iPredAfter[i, 1];
    end;

    if not top then
    begin
      if left then j := 48
      else if leftAdj or bOneMBRightVertTB then j := -48
      else j := -16;
      if right or bVertTB then jEnd := 16 else jEnd := 48;
      while j < jEnd do begin strIDCT4x4Stage1(q0 + j); Inc(j, 32); end;
    end;
    if not bottom then
    begin
      if left then j := 32
      else if leftAdj or bOneMBRightVertTB then j := -64
      else j := -32;
      if right or bVertTB then jEnd := 0 else jEnd := 32;
      while j < jEnd do begin strIDCT4x4Stage1(q1 + j); Inc(j, 32); end;
    end;

    if Overlap <> OL_NONE then
    begin
      if (top or bHoriTB) and (leftAdj or bOneMBRightVertTB) then
        strPost4_alternate(q1 - 64 + 0, q1 - 64 + 1, q1 - 64 + 2, q1 - 64 + 3);
      if (top or bHoriTB) and (right or bVertTB) then
        strPost4_alternate(q1 - 27, q1 - 28, q1 - 25, q1 - 26);
      if (bottom or bHoriTB) and (leftAdj or bOneMBRightVertTB) then
        strPost4_alternate(q0 - 64 + 16 + 10, q0 - 64 + 16 + 11, q0 - 64 + 16 + 8, q0 - 64 + 16 + 9);
      if (bottom or bHoriTB) and (right or bVertTB) then
        strPost4_alternate(q0 - 1, q0 - 2, q0 - 3, q0 - 4);

      if (not left) and (not top) then
      begin
        if leftAdj or bOneMBRightVertTB then
        begin
          if (not bottom) and (not bHoriTB) then
          begin
            strPost4_alternate(q0 - 64 + 26, q0 - 64 + 24, q1 - 64 + 0, q1 - 64 + 2);
            strPost4_alternate(q0 - 64 + 27, q0 - 64 + 25, q1 - 64 + 1, q1 - 64 + 3);
          end;
          strPost4_alternate(q0 - 64 + 10, q0 - 64 + 8, q0 - 64 + 16, q0 - 64 + 18);
          strPost4_alternate(q0 - 64 + 11, q0 - 64 + 9, q0 - 64 + 17, q0 - 64 + 19);
        end;
        if bottom or bHoriTB then
        begin
          p := q0 - 48;
          strPost4_alternate(p + 15, p + 14, p + 42, p + 43);
          strPost4_alternate(p + 13, p + 12, p + 40, p + 41);
          if (not right) and (not bVertTB) then
          begin
            p := q0 - 16;
            strPost4_alternate(p + 15, p + 14, p + 42, p + 43);
            strPost4_alternate(p + 13, p + 12, p + 40, p + 41);
          end;
        end
        else
        begin
          strPost4x4Stage1Split_alternate(q0 - 48, q1 - 16 - 48, 32);
          if (not right) and (not bVertTB) then
            strPost4x4Stage1Split_alternate(q0 - 16, q1 - 16 - 16, 32);
        end;
        if right or bVertTB then
        begin
          if (not bottom) and (not bHoriTB) then
          begin
            strPost4_alternate(q0 - 2, q0 - 4, q1 - 28, q1 - 26);
            strPost4_alternate(q0 - 1, q0 - 3, q1 - 27, q1 - 25);
          end;
          strPost4_alternate(q0 - 18, q0 - 20, q0 - 12, q0 - 10);
          strPost4_alternate(q0 - 17, q0 - 19, q0 - 11, q0 - 9);
        end
        else
          strPost4x4Stage1_alternate(q0 - 32, 32);
        strPost4x4Stage1_alternate(q0 - 64, 32);
      end;
      if top or bHoriTB then
      begin
        if not left then
        begin
          p := q1 - 64 + 4;
          strPost4_alternate(p + 1, p + 0, p + 28, p + 29);
          strPost4_alternate(p + 3, p + 2, p + 30, p + 31);
        end;
        if (not left) and (not right) and (not bVertTB) then
        begin
          p := q1 - 32 + 4;
          strPost4_alternate(p + 1, p + 0, p + 28, p + 29);
          strPost4_alternate(p + 3, p + 2, p + 30, p + 31);
        end;
      end;
    end;
  end;

  // ---- 422_UV ----
  if CF = CF_YUV422 then
  for i := 0 to 1 do
  begin
    q0 := p0[1 + i]; q1 := p1[1 + i];
    if not bottomORright then
    begin
      q1[0] := q1[0] - Asr(q1[32] + 1, 1);
      q1[32] := q1[32] + q1[0];
      if not ScaledArith then
      begin
        strDCT2x2dn(q1 + 0, q1 + 64, q1 + 16, q1 + 80);
        strDCT2x2dn(q1 + 32, q1 + 96, q1 + 48, q1 + 112);
      end
      else
      begin
        strDCT2x2dnDec(q1 + 0, q1 + 64, q1 + 16, q1 + 80);
        strDCT2x2dnDec(q1 + 32, q1 + 96, q1 + 48, q1 + 112);
      end;
    end;

    if Overlap = OL_TWO then
    begin
      if (leftAdj or bOneMBRightVertTB) and (top or bHoriTB) then
        q1[-128 + 0] := q1[-128 + 0] - q1[-128 + 64];
      if (rightAdj or bOneMBLeftVertTB) and (top or bHoriTB) then
        iPredBefore[i, 0] := q1[0];
      if (right or bVertTB) and (top or bHoriTB) then
        q1[-128 + 64] := q1[-128 + 64] - iPredBefore[i, 0];
      if (leftAdj or bOneMBRightVertTB) and (bottom or bHoriTB) then
        q0[-128 + 48] := q0[-128 + 48] - q0[-128 + 112];
      if (rightAdj or bOneMBLeftVertTB) and (bottom or bHoriTB) then
        iPredBefore[i, 1] := q0[48];
      if (right or bVertTB) and (bottom or bHoriTB) then
        q0[-128 + 112] := q0[-128 + 112] - iPredBefore[i, 1];

      if not bottom then
      begin
        if leftORright or bVertTB then
        begin
          if (not top) and (not bHoriTB) then
          begin
            if left or bVertTB then strPost2_alternate(q0 + 48 + 0, q1 + 0);
            if right or bVertTB then strPost2_alternate(q0 + 48 - 64, q1 - 64);
          end;
          if left or bVertTB then strPost2_alternate(q1 + 16, q1 + 16 + 16);
          if right or bVertTB then strPost2_alternate(q1 - 48, q1 - 48 + 16);
        end;
        if (not leftORright) and (not bVertTB) then
        begin
          if top or bHoriTB then strPost2_alternate(q1 - 64, q1)
          else strPost2x2_alternate(q0 - 16, q0 + 48, q1 - 64, q1);
          strPost2x2_alternate(q1 - 48, q1 + 16, q1 - 32, q1 + 32);
        end;
      end;
      if (bottom or bHoriTB) and ((not leftORright) and (not bVertTB)) then
        strPost2_alternate(q0 - 16, q0 + 48);

      if (leftAdj or bOneMBRightVertTB) and (top or bHoriTB) then
        q1[-128 + 0] := q1[-128 + 0] + q1[-128 + 64];
      if (rightAdj or bOneMBLeftVertTB) and (top or bHoriTB) then
        iPredAfter[i, 0] := q1[0];
      if (right or bVertTB) and (top or bHoriTB) then
        q1[-128 + 64] := q1[-128 + 64] + iPredAfter[i, 0];
      if (leftAdj or bOneMBRightVertTB) and (bottom or bHoriTB) then
        q0[-128 + 48] := q0[-128 + 48] + q0[-128 + 112];
      if (rightAdj or bOneMBLeftVertTB) and (bottom or bHoriTB) then
        iPredAfter[i, 1] := q0[48];
      if (right or bVertTB) and (bottom or bHoriTB) then
        q0[-128 + 112] := q0[-128 + 112] + iPredAfter[i, 1];
    end;

    if not top then
    begin
      if left then j := 112
      else if leftAdj or bOneMBRightVertTB then j := -80
      else j := -16;
      if right or bVertTB then jEnd := 48 else jEnd := 112;
      while j < jEnd do begin strIDCT4x4Stage1(q0 + j); Inc(j, 64); end;
    end;
    if not bottom then
    begin
      if left then j := 64
      else if leftAdj or bOneMBRightVertTB then j := -128
      else j := -64;
      if right or bVertTB then jEnd := 0 else jEnd := 64;
      while j < jEnd do
      begin
        strIDCT4x4Stage1(q1 + j + 0);
        strIDCT4x4Stage1(q1 + j + 16);
        strIDCT4x4Stage1(q1 + j + 32);
        Inc(j, 64);
      end;
    end;

    if Overlap <> OL_NONE then
    begin
      if (top or bHoriTB) and (leftAdj or bOneMBRightVertTB) then
        strPost4_alternate(q1 - 128 + 0, q1 - 128 + 1, q1 - 128 + 2, q1 - 128 + 3);
      if (top or bHoriTB) and (right or bVertTB) then
        strPost4_alternate(q1 - 59, q1 - 60, q1 - 57, q1 - 58);
      if (bottom or bHoriTB) and (leftAdj or bOneMBRightVertTB) then
        strPost4_alternate(q0 - 128 + 48 + 10, q0 - 128 + 48 + 11, q0 - 128 + 48 + 8, q0 - 128 + 48 + 9);
      if (bottom or bHoriTB) and (right or bVertTB) then
        strPost4_alternate(q0 - 1, q0 - 2, q0 - 3, q0 - 4);

      if not top then
      begin
        if leftAdj or bOneMBRightVertTB then
        begin
          p := q0 + 32 + 10 - 128;
          strPost4_alternate(p + 0, p - 2, p + 6, p + 8);
          strPost4_alternate(p + 1, p - 1, p + 7, p + 9);
        end;
        if right or bVertTB then
        begin
          p := q0 - 32 + 14;
          strPost4_alternate(p + 0, p - 2, p + 6, p + 8);
          strPost4_alternate(p + 1, p - 1, p + 7, p + 9);
        end;
        if left then j := 0 else j := -128;
        if right or bVertTB then jEnd := -64 else jEnd := 0;
        while j < jEnd do begin strPost4x4Stage1_alternate(q0 + j + 32, 0); Inc(j, 64); end;
      end;
      if not bottom then
      begin
        if leftAdj or bOneMBRightVertTB then
        begin
          p := q1 + 0 + 10 - 128;
          strPost4_alternate(p + 0, p - 2, p + 6, p + 8);
          strPost4_alternate(p + 1, p - 1, p + 7, p + 9);
          p := p + 16;
          strPost4_alternate(p + 0, p - 2, p + 6, p + 8);
          strPost4_alternate(p + 1, p - 1, p + 7, p + 9);
        end;
        if right or bVertTB then
        begin
          p := q1 - 64 + 14;
          strPost4_alternate(p + 0, p - 2, p + 6, p + 8);
          strPost4_alternate(p + 1, p - 1, p + 7, p + 9);
          p := p + 16;
          strPost4_alternate(p + 0, p - 2, p + 6, p + 8);
          strPost4_alternate(p + 1, p - 1, p + 7, p + 9);
        end;
        if left then j := 0 else j := -128;
        if right or bVertTB then jEnd := -64 else jEnd := 0;
        while j < jEnd do
        begin
          strPost4x4Stage1_alternate(q1 + j + 0, 0);
          strPost4x4Stage1_alternate(q1 + j + 16, 0);
          Inc(j, 64);
        end;
      end;
      if topORbottom or bHoriTB then
      begin
        if right or bVertTB then jEnd := -64 else jEnd := 0;
        if top or bHoriTB then
        begin
          p := q1 + 5;
          if left then j := 0 else j := -128;
          while j < jEnd do
          begin
            strPost4_alternate(p + j + 0, p + j - 1, p + j + 59, p + j + 60);
            strPost4_alternate(p + j + 2, p + j + 1, p + j + 61, p + j + 62);
            Inc(j, 64);
          end;
        end;
        if bottom or bHoriTB then
        begin
          p := q0 + 48 + 13;
          if left then j := 0 else j := -128;
          while j < jEnd do
          begin
            strPost4_alternate(p + j + 0, p + j - 1, p + j + 59, p + j + 60);
            strPost4_alternate(p + j + 2, p + j + 1, p + j + 61, p + j + 62);
            Inc(j, 64);
          end;
        end;
      end
      else
      begin
        if leftAdj or bOneMBRightVertTB then
        begin
          j := 0 + 0 - 128;
          strPost4_alternate(q0 + j + 48 + 10 + 0, q0 + j + 48 + 10 - 2, q1 + j + 0, q1 + j + 2);
          strPost4_alternate(q0 + j + 48 + 10 + 1, q0 + j + 48 + 10 - 1, q1 + j + 1, q1 + j + 3);
        end;
        if right or bVertTB then
        begin
          j := -64 + 4;
          strPost4_alternate(q0 + j + 48 + 10 + 0, q0 + j + 48 + 10 - 2, q1 + j + 0, q1 + j + 2);
          strPost4_alternate(q0 + j + 48 + 10 + 1, q0 + j + 48 + 10 - 1, q1 + j + 1, q1 + j + 3);
        end;
        if left then j := 0 else j := -128;
        if right or bVertTB then jEnd := -64 else jEnd := 0;
        while j < jEnd do
        begin
          strPost4x4Stage1Split_alternate(q0 + j + 48, q1 + j + 0, 0);
          Inc(j, 64);
        end;
      end;
    end;
  end;
end;

procedure TJxrSC.Transform;
begin
  if SubVersion = CODEC_SUBVERSION then InvTransformMB else InvTransformMBHard;
end;

// strdec.c processMacroblockDec (one plane)
function TJxrSC.ProcessMB: Boolean;
var
  ctx: PCodingContext;
begin
  Result := False;
  if not ((cRow = cmbHeight) or (cColumn = cmbWidth)) then
  begin
    GetTilePos(cColumn, cRow);
    if NextSC <> nil then
    begin
      NextSC.cTileColumn := cTileColumn;
      NextSC.cTileRow := cTileRow;
    end;
    ctx := @CtxA[cTileColumn];
    if not ReadPackets then Exit;
    if not DecodeMBDC(ctx) then Exit;
    if DecodeLP then if not DecodeMBLP(ctx) then Exit;
    PredDCACDec;
    DequantizeMB;
    if DecodeHP then
    begin
      if not DecodeMBHP(ctx) then Exit;
      PredACDec;
    end;
    UpdatePredInfo;
  end;
  Transform;
  Result := True;
end;

// strdec.c interpolateUV - 4:2:2 / 4:2:0 chroma to 4:4:4 (into ResU/ResV)
procedure TJxrSC.InterpolateUV;
var
  cWidthPx, iRow, iColumn, iIdxS, iIdxD, iL, iIdxL, iC, iIdxC, cMB, cPix, iIdxT, iIdxB: Integer;
  pSrcU, pSrcV, pDstU, pDstV: PInt;
begin
  cWidthPx := cmbWidth * 16;
  pSrcU := a0[1]; pSrcV := a0[2];
  pDstU := @ResU[0]; pDstV := @ResV[0];
  iIdxD := 0; iIdxS := 0;
  if CF = CF_YUV422 then
  begin
    for iRow := 0 to 15 do
    begin
      iColumn := 0;
      while iColumn < cWidthPx do
      begin
        iIdxS := ((iColumn shr 4) shl 7) + idxCC[iRow, (iColumn shr 1) and 7];
        iIdxD := ((iColumn shr 4) shl 8) + idxCC[iRow, iColumn and 15];
        pDstU[iIdxD] := pSrcU[iIdxS];
        pDstV[iIdxD] := pSrcV[iIdxS];
        if iColumn > 0 then
        begin
          iL := iColumn - 2; iIdxL := ((iL shr 4) shl 8) + idxCC[iRow, iL and 15];
          iC := iColumn - 1; iIdxC := ((iC shr 4) shl 8) + idxCC[iRow, iC and 15];
          pDstU[iIdxC] := Asr(pDstU[iIdxL] + pDstU[iIdxD] + 1, 1);
          pDstV[iIdxC] := Asr(pDstV[iIdxL] + pDstV[iIdxD] + 1, 1);
        end;
        Inc(iColumn, 2);
      end;
      iIdxS := (((iColumn - 1) shr 4) shl 8) + idxCC[iRow, (iColumn - 1) and 15];
      pDstU[iIdxS] := pDstU[iIdxD];
      pDstV[iIdxS] := pDstV[iIdxD];
    end;
  end
  else
  begin
    iColumn := 0;
    while iColumn < cWidthPx do
    begin
      cMB := (iColumn shr 4) shl 8;
      cPix := iColumn and 15;
      iRow := 0;
      while iRow < 16 do
      begin
        iIdxS := ((iColumn shr 4) shl 6) + idxCC_420[iRow shr 1, (iColumn shr 1) and 7];
        iIdxD := cMB + idxCC[iRow, cPix];
        pDstU[iIdxD] := pSrcU[iIdxS];
        pDstV[iIdxD] := pSrcV[iIdxS];
        if iRow > 0 then
        begin
          iIdxT := cMB + idxCC[iRow - 2, cPix];
          iIdxC := cMB + idxCC[iRow - 1, cPix];
          pDstU[iIdxC] := Asr(pDstU[iIdxT] + pDstU[iIdxD] + 1, 1);
          pDstV[iIdxC] := Asr(pDstV[iIdxT] + pDstV[iIdxD] + 1, 1);
        end;
        Inc(iRow, 2);
      end;
      iIdxS := cMB + idxCC[15, cPix];
      if cRow = cmbHeight then
      begin
        pDstU[iIdxS] := pDstU[iIdxD];
        pDstV[iIdxS] := pDstV[iIdxD];
      end
      else
      begin
        iIdxB := ((iColumn shr 4) shl 6) + idxCC_420[0, (iColumn shr 1) and 7];
        pDstU[iIdxS] := Asr(a1[1][iIdxB] + pDstU[iIdxD] + 1, 1);
        pDstV[iIdxS] := Asr(a1[2][iIdxB] + pDstV[iIdxD] + 1, 1);
      end;
      Inc(iColumn, 2);
    end;
    for iRow := 0 to 15 do
    begin
      iColumn := 1;
      while iColumn < cWidthPx - 2 do
      begin
        iIdxL := (((iColumn - 1) shr 4) shl 8) + idxCC[iRow, (iColumn - 1) and 15];
        iIdxD := ((iColumn shr 4) shl 8) + idxCC[iRow, iColumn and 15];
        iIdxS := (((iColumn + 1) shr 4) shl 8) + idxCC[iRow, (iColumn + 1) and 15];
        pDstU[iIdxD] := Asr(pDstU[iIdxS] + pDstU[iIdxL] + 1, 1);
        pDstV[iIdxD] := Asr(pDstV[iIdxS] + pDstV[iIdxL] + 1, 1);
        Inc(iColumn, 2);
      end;
      iIdxD := (((cWidthPx - 1) shr 4) shl 8) + idxCC[iRow, (cWidthPx - 1) and 15];
      pDstU[iIdxD] := pDstU[iIdxS];
      pDstV[iIdxD] := pDstV[iIdxS];
    end;
  end;
end;

// ============================= output ===================================

const
  CF_RGBE = 8;

type
  // How decoded samples map back to the source pixel format (strdec.c).
  TOutFmt = record
    BD, CFExt, NLen, ExpBias, Shift: Integer;
    RBSwapped: Boolean;
    BiasC, BiasA: Integer;       // colour / alpha rounding + level bias
    AsAlpha: Boolean;            // planar alpha stream: no sRGB transfer
  end;

procedure SetupOutFmt(var F: TOutFmt; const Hdr: TJxrCore; AsAlpha: Boolean);
var sh, half: Integer; scaled: Boolean;
begin
  F.BD := Hdr.BdBitDepthSrc;
  F.CFExt := Hdr.CfColorFormatExt;
  F.NLen := Hdr.LenMantissaOrShift;
  F.ExpBias := ShortInt(Byte(Hdr.ExpBias));
  F.RBSwapped := Hdr.RBSwapped;
  F.AsAlpha := AsAlpha;
  scaled := Hdr.ScaledArith;
  if scaled then sh := SHIFTZERO + QPFRACBITS else sh := 0;
  F.Shift := sh;
  if sh > 0 then half := 1 shl (sh - 1) else half := 0;
  case F.BD of
    BD_8:   F.BiasC := (128 shl sh) + IfThen(scaled, half - 1, 0);
    BD_16:  F.BiasC := (((1 shl 15) shr F.NLen) shl sh) + half;
    BD_5:   F.BiasC := (16 shl sh) + IfThen(scaled, half - 1, 0);
    BD_565: F.BiasC := (32 shl sh) + IfThen(scaled, half - 1, 0);
    BD_10:  F.BiasC := (512 shl sh) + IfThen(scaled, half - 1, 0);
  else      F.BiasC := IfThen(scaled, half - 1, 0);   // 16S/16F/32S/32F/1
  end;
  if F.CFExt = CF_RGBE then F.BiasC := IfThen(scaled, half - 1, 0);
  case F.BD of
    BD_8:  F.BiasA := (1 shl (sh + 7)) + half;
    BD_16: F.BiasA := (1 shl (sh + 15)) + half;
  else     F.BiasA := half;
  end;
end;

// JXRGluePFC.c Convert_Float_To_U8: linear scRGB -> sRGB
function LinToSRGB8(f: Single): Byte;
begin
  if not (f > 0) then Result := 0       // also NaN
  else if f <= 0.0031308 then Result := Trunc(255.0 * f * 12.92 + 0.5)
  else if f < 1.0 then Result := Trunc(255.0 * (1.055 * Power(f, 1.0 / 2.4) - 0.055) + 0.5)
  else Result := 255;
end;

function LinToAlpha8(f: Single): Byte;
begin
  if not (f > 0) then Result := 0
  else if f < 1.0 then Result := Trunc(255.0 * f + 0.5)
  else Result := 255;
end;

// IEEE bits -> Single. NaN / Inf never reach the FPU (corrupt streams can
// produce any bit pattern and signalling NaNs would raise): NaN and -Inf
// become 0, +Inf the largest finite value.
function BitsToSingle(i: Cardinal): Single;
begin
  if (i and $7f800000) = $7f800000 then
  begin
    if ((i and $007fffff) = 0) and ((i and $80000000) = 0) then i := $7f7fffff
    else i := 0;
  end;
  Result := PSingle(@i)^;
end;

// JXRGluePFC.c Convert_Half_To_Float (denormals flush to zero)
function HalfToFloat(h: Word): Single;
var s, e, m: Cardinal;
begin
  s := (h shr 15) and 1; e := (h shr 10) and $1f; m := h and $3ff;
  if e = 0 then Result := BitsToSingle(s shl 31)
  else if e = 31 then Result := BitsToSingle((s shl 31) or ($ff shl 23) or (m shl 13))
  else Result := BitsToSingle((s shl 31) or ((e - 15 + 127) shl 23) or (m shl 13));
end;

// strdec.c backwardHalf: sign-magnitude -> half bits
function BackwardHalf(v: Integer): Word; inline;
var s: Integer;
begin
  s := Asr(v, 31);
  Result := Word(((v and $7fff) xor s) - s);
end;

// strdec.c pixel2float
function Pixel2Float(h: Integer; c, lm: Integer): Single;
var s, t, m, e, lmshift: Integer;
begin
  lmshift := 1 shl lm;
  s := Asr(h, 31);
  t := (h xor s) - s;
  e := Integer(Cardinal(t) shr lm);
  m := (t and (lmshift - 1)) or lmshift;
  if e = 0 then begin m := m xor lmshift; e := 1; end;
  e := e + (127 - c);
  while (m < lmshift) and (e > 1) and (m > 0) do begin Dec(e); m := m shl 1; end;
  if m < lmshift then e := 0 else m := m xor lmshift;
  m := m shl (23 - lm);
  Result := BitsToSingle((Cardinal(s) and $80000000) or (Cardinal(e) shl 23) or Cardinal(m));
end;

// One already-shifted sample in the source pixel format -> display byte.
function ChanToByte(const F: TOutFmt; v: Integer; Alpha: Boolean): Byte;
var fl: Single; u: Integer;
begin
  case F.BD of
    BD_8: Exit(Clip8(v));
    BD_16:
      begin
        u := v shl F.NLen;
        if u < 0 then u := 0 else if u > 65535 then u := 65535;
        Exit(Byte(u shr 8));
      end;
    BD_5: Exit(Byte(EnsureRange(v, 0, 31) shl 3));
    BD_10: Exit(Byte(EnsureRange(v, 0, 1023) shr 2));
    BD_16S: fl := EnsureRange(v shl F.NLen, -32768, 32767) * (1.0 / 8192);
    BD_16F: fl := HalfToFloat(BackwardHalf(v));
    BD_32S: fl := (v shl F.NLen) * (1.0 / 16777216);
    BD_32F: fl := Pixel2Float(v, F.ExpBias, F.NLen);
  else
    Exit(Clip8(v));
  end;
  if Alpha or F.AsAlpha then Result := LinToAlpha8(fl) else Result := LinToSRGB8(fl);
end;

// strdec.c inverseConvert + RGBE -> float (JXRGluePFC.c RGBE_RGB96Float)
procedure RGBEToLinear(r, g, b: Integer; out fr, fg, fb: Single);
var
  m, e: array[0..2] of Integer;
  v: array[0..2] of Integer;
  i, ee: Integer;
begin
  v[0] := r; v[1] := g; v[2] := b;
  for i := 0 to 2 do
    if v[i] <= 0 then begin m[i] := 0; e[i] := 0; end
    else if (v[i] shr 7) > 1 then begin e[i] := (v[i] shr 7) and $ff; m[i] := (v[i] and $7f) or $80; end
    else begin e[i] := 1; m[i] := v[i] and $ff; end;
  ee := Max(Max(e[0], e[1]), e[2]);
  for i := 0 to 2 do
    if ee > e[i] then m[i] := ((m[i] * 2 + 1) shr (ee - e[i] + 1)) and $ff;
  if ee = 0 then begin fr := 0; fg := 0; fb := 0; Exit; end;
  fr := Ldexp(m[0], ee - 128 - 8);
  fg := Ldexp(m[1], ee - 128 - 8);
  fb := Ldexp(m[2], ee - 128 - 8);
end;

// Linear-light sample (fixed point / half / float formats) as a double.
function ChanToLinear(const F: TOutFmt; v: Integer): Double;
begin
  case F.BD of
    BD_16S: Result := EnsureRange(v shl F.NLen, -32768, 32767) * (1.0 / 8192);
    BD_16F: Result := HalfToFloat(BackwardHalf(v));
    BD_32S: Result := (v shl F.NLen) * (1.0 / 16777216);
    BD_32F: Result := Pixel2Float(v, F.ExpBias, F.NLen);
  else
    Result := 0;
  end;
end;

// Formats whose samples are linear scRGB light (HDR capable).
function IsLinearFmt(const F: TOutFmt): Boolean;
begin
  Result := (not F.AsAlpha) and (F.CFExt <> CF_CMYK) and
    ((F.BD in [BD_16S, BD_16F, BD_32S, BD_32F]) or (F.CFExt = CF_RGBE));
end;

const
  HIST_STOPS_LO = 24;              // histogram covers 2^-24 .. 2^24
  HIST_PER_STOP = 32;
  HIST_BINS = 2 * HIST_STOPS_LO * HIST_PER_STOP;

type
  // Per-decode output state shared by all MB rows.
  TOutCtx = record
    HistPass: Boolean;             // pass 1 of HDR tone mapping: only gather statistics
    Hist: array of Cardinal;       // [0] = non-positive, [1..HIST_BINS] = log2 bins
    ToneMap: Boolean;
    TMKnee, TMPeak, TMS: Double;
    Premul: Boolean;               // container says colour is premultiplied by alpha
    // planar alpha at full precision, one Single per (un-oriented) pixel in
    // native units: 0..255 (8-bit), 0..65535 (16-bit) or linear (float/fixed)
    AlphaIn: PSingle;              // read when decoding the image
    AlphaOut: PSingle;             // written when decoding the alpha codestream
    YUVPlanes: Boolean;            // external YUV 4:2:0 / 4:2:2: collect planes
    Is420: Boolean;
    CU, CV: TBytes;                // chroma planes in padded coordinates
    CStride: Integer;
  end;

procedure HistAdd(var C: TOutCtx; M: Double);
var b: Integer;
begin
  if not (M > 0) then begin Inc(C.Hist[0]); Exit; end;
  b := Floor((Log2(M) + HIST_STOPS_LO) * HIST_PER_STOP);
  if b < 0 then b := 0 else if b >= HIST_BINS then b := HIST_BINS - 1;
  Inc(C.Hist[b + 1]);
end;

// Lower edge of the histogram bin holding the given percentile of max(R,G,B)
// (lower, so that content peaking at exactly 1.0 never counts as HDR).
function HistPercentile(const C: TOutCtx; Pct: Double): Double;
var total, target, cum: Double; i: Integer;
begin
  total := 0;
  for i := 0 to High(C.Hist) do total := total + C.Hist[i];
  Result := 0;
  if total <= 0 then Exit;
  target := total * EnsureRange(Pct, 0, 100) / 100;
  cum := C.Hist[0];
  if cum >= target then Exit;
  for i := 1 to HIST_BINS do
  begin
    cum := cum + C.Hist[i];
    if cum >= target then
      Exit(Power(2, (i - 1) / HIST_PER_STOP - HIST_STOPS_LO));
  end;
  Result := Power(2, HIST_STOPS_LO);
end;

// Knee curve on max(R,G,B): identity below the knee, then a Reinhard-shaped
// shoulder that is C1-continuous at the knee and reaches 1.0 at the peak.
// Returns the factor applied to all three channels (keeps hue).
function ToneScale(const C: TOutCtx; M: Double): Double;
var t: Double;
begin
  if M <= C.TMKnee then Exit(1);
  t := (M - C.TMKnee) / (C.TMPeak - C.TMKnee);
  Result := (C.TMKnee + (1 - C.TMKnee) * C.TMS * t / (1 + (C.TMS - 1) * t)) / M;
end;

// Double -> Single without trapping: corrupt data (e.g. a tiny alpha in a
// premultiplied file) can produce quotients beyond the Single range.
function SatSingle(x: Double): Single; inline;
begin
  if not (x = x) then Result := 0                   // NaN
  else if x > 3.4e38 then Result := 3.4e38
  else if x < -3.4e38 then Result := -3.4e38
  else Result := x;
end;

// Linear RGB (+ linear alpha) -> sRGB bytes, with un-premultiply and tone map.
procedure EmitLinear(var C: TOutCtx; lr, lg, lb, la: Double; HasAlpha: Boolean;
  out br, bg, bb: Byte; out Skip: Boolean);
var m, s: Double;
begin
  Skip := False;
  if C.Premul and HasAlpha then
  begin
    if la > 0 then begin lr := lr / la; lg := lg / la; lb := lb / la; end
    else begin lr := 0; lg := 0; lb := 0; end;
  end;
  if C.HistPass or C.ToneMap then
  begin
    m := Max(lr, Max(lg, lb));
    if C.HistPass then begin HistAdd(C, m); Skip := True; Exit; end;
    if m > 0 then
    begin
      s := ToneScale(C, m);
      lr := lr * s; lg := lg * s; lb := lb * s;
    end;
  end;
  br := LinToSRGB8(SatSingle(lr)); bg := LinToSRGB8(SatSingle(lg));
  bb := LinToSRGB8(SatSingle(lb));
end;

// Integer un-premultiply: c, a in the same unit (8 or 16 bit) -> 8-bit colour.
function Unpremul8(c, a: Integer): Byte;
begin
  if (a <= 0) or (c <= 0) then Exit(0);
  Result := Byte(Min(Int64(255), (Int64(c) * 255 + a div 2) div a));
end;

// strdec.c outputMBRow / outputNChannel / outputMBRowAlpha for MB row cRow-1,
// converted to RGBA8 for display.
procedure OutputMBRow(P, A: TJxrSC; const F: TOutFmt; var C: TOutCtx; Dest: PByte;
  W, H, ExtraLeft, ExtraTop: Integer);
var
  r, iRow, iColumn, x, y, cWidthPx, iIdx, sh, iTh, iBias1, iBias2, cx, cy, cRows: Integer;
  pY, pU, pV, pK, pA: PInt;
  rr, gg, bb, aa, cc, mm, yy, kk, t, a16, c16: Integer;
  fr, fg, fb, la: Single;
  lr, lg, lb: Double;
  o: NativeInt;
  Gray, Sub, Linear, HaveAlpha, Skip: Boolean;
  br, bg, bbb: Byte;
begin
  r := P.cRow - 1;
  cWidthPx := P.cmbWidth * 16;
  sh := F.Shift;
  Gray := (P.CF = CF_Y_ONLY) or (F.CFExt = CF_Y_ONLY) or
          ((F.CFExt = CF_NCOMPONENT) and (P.NumCh < 3));
  Sub := (P.CF = CF_YUV420) or (P.CF = CF_YUV422);
  Linear := IsLinearFmt(F);
  pY := P.a0[0];
  pU := nil; pV := nil; pK := nil;

  if C.YUVPlanes then
  begin
    // external YUV 4:2:x: keep the native chroma samples, upsampled later
    if C.HistPass then Exit;
    if C.Is420 then cRows := 8 else cRows := 16;
    for cy := 0 to cRows - 1 do
      for cx := 0 to P.cmbWidth * 8 - 1 do
      begin
        if C.Is420 then iIdx := ((cx shr 3) shl 6) + idxCC_420[cy, cx and 7]
        else iIdx := ((cx shr 3) shl 7) + idxCC[cy, cx and 7];
        o := NativeInt(r * cRows + cy) * C.CStride + cx;
        C.CU[o] := ChanToByte(F, Asr(P.a0[1][iIdx] + F.BiasC, sh), False);
        C.CV[o] := ChanToByte(F, Asr(P.a0[2][iIdx] + F.BiasC, sh), False);
      end;
  end
  else if not Gray then
  begin
    if Sub then
    begin
      P.InterpolateUV;
      pU := @P.ResU[0]; pV := @P.ResV[0];
    end
    else
    begin
      pU := P.a0[1]; pV := P.a0[2];
      if P.NumCh > 3 then pK := P.a0[3];
    end;
  end;
  if A <> nil then pA := A.a0[0] else pA := nil;
  HaveAlpha := (pA <> nil) or (C.AlphaIn <> nil);
  iTh := IfThen(sh > 0, 1 shl Max(sh - 1, 0), 1);

  for iRow := 0 to 15 do
  begin
    y := r * 16 + iRow - ExtraTop;
    if (y < 0) or (y >= H) then Continue;
    for iColumn := 0 to cWidthPx - 1 do
    begin
      x := iColumn - ExtraLeft;
      if (x < 0) or (x >= W) then Continue;
      iIdx := ((iColumn shr 4) shl 8) + idxCC[iRow, iColumn and 15];
      o := (NativeInt(y) * W + x) * 4;

      // alpha first: premultiplied colour needs it
      aa := 255; la := 1;
      if pA <> nil then
      begin
        if (F.BD = BD_8) and (F.CFExt = CF_RGB) then
          aa := Clip8(Asr(pA[iIdx] + F.BiasC, sh))
        else
          aa := ChanToByte(F, Asr(pA[iIdx] + F.BiasA, sh), True);
        if Linear then la := ChanToLinear(F, Asr(pA[iIdx] + F.BiasA, sh));
      end
      else if C.AlphaIn <> nil then
      begin
        la := C.AlphaIn[NativeInt(y) * W + x];
        if F.BD = BD_16 then aa := EnsureRange(Round(la), 0, 65535) shr 8
        else aa := Clip8(Round(la));
      end;

      if C.AlphaOut <> nil then
      begin
        // this is the planar alpha codestream: keep full precision
        t := Asr(pY[iIdx] + F.BiasC, sh);
        case F.BD of
          BD_8:  C.AlphaOut[NativeInt(y) * W + x] := Clip8(t);
          BD_16: C.AlphaOut[NativeInt(y) * W + x] := EnsureRange(t shl F.NLen, 0, 65535);
          BD_16S, BD_16F, BD_32S, BD_32F:
                 C.AlphaOut[NativeInt(y) * W + x] := ChanToLinear(F, t);
        else     C.AlphaOut[NativeInt(y) * W + x] := ChanToByte(F, t, True);
        end;
      end;

      if C.YUVPlanes then
      begin
        br := ChanToByte(F, Asr(pY[iIdx] + F.BiasC, sh), False);   // Y, chroma added later
        bg := 0; bbb := 0;
      end
      else if Gray then
      begin
        if F.BD = BD_1 then
          br := IfThen(pY[iIdx] >= iTh, 255, 0)
        else if Linear then
        begin
          lr := ChanToLinear(F, Asr(pY[iIdx] + F.BiasC, sh));
          EmitLinear(C, lr, lr, lr, la, HaveAlpha, br, bg, bbb, Skip);
          if Skip then Continue;
        end
        else
          br := ChanToByte(F, Asr(pY[iIdx] + F.BiasC, sh), False);
        bg := br; bbb := br;
      end
      else if F.CFExt = CF_CMYK then
      begin
        if F.BD = BD_16 then iBias1 := ((32768 shr F.NLen) shl sh)
        else if F.BD = BD_8 then iBias1 := 128 shl sh
        else iBias1 := 0;
        iBias2 := F.BiasC - iBias1;
        mm := -pY[iIdx] + iBias1; cc := pU[iIdx]; yy := -pV[iIdx];
        if pK <> nil then kk := pK[iIdx] + iBias2 else kk := iBias2;
        // _ICC_CMYK
        kk := kk - Asr(mm + 1, 1);
        mm := mm - (Asr(cc, 1) - kk);
        cc := cc - (Asr(yy + 1, 1) - mm);
        yy := yy + cc;
        cc := ChanToByte(F, Asr(cc, sh), True);
        mm := ChanToByte(F, Asr(mm, sh), True);
        yy := ChanToByte(F, Asr(yy, sh), True);
        kk := ChanToByte(F, Asr(kk, sh), True);
        br := ((255 - cc) * (255 - kk) + 127) div 255;
        bg := ((255 - mm) * (255 - kk) + 127) div 255;
        bbb := ((255 - yy) * (255 - kk) + 127) div 255;
      end
      else if F.CFExt = CF_YUV444 then
      begin
        // stored directly as Y Cb Cr (no transform in the codestream)
        rr := ChanToByte(F, Asr(pY[iIdx] + F.BiasC, sh), False);
        gg := ChanToByte(F, Asr(pU[iIdx] + F.BiasC, sh), False) - 128;
        bb := ChanToByte(F, Asr(pV[iIdx] + F.BiasC, sh), False) - 128;
        br := Clip8(rr + Asr(91881 * bb + 32768, 16));
        bg := Clip8(rr + Asr(-22554 * gg - 46802 * bb + 32768, 16));
        bbb := Clip8(rr + Asr(116130 * gg + 32768, 16));
      end
      else if F.CFExt = CF_NCOMPONENT then
      begin
        br := ChanToByte(F, Asr(pY[iIdx] + F.BiasC, sh), False);
        bg := ChanToByte(F, Asr(pU[iIdx] + F.BiasC, sh), False);
        bbb := ChanToByte(F, Asr(pV[iIdx] + F.BiasC, sh), False);
      end
      else
      begin
        // CF_RGB / CF_RGBE: YCoCg-style reversible transform
        gg := pY[iIdx] + F.BiasC;
        rr := -pU[iIdx];
        bb := pV[iIdx];
        gg := gg - Asr(rr, 1);
        rr := rr - (Asr(bb + 1, 1) - gg);
        bb := bb + rr;
        if F.CFExt = CF_RGBE then
        begin
          RGBEToLinear(Asr(rr, sh), Asr(gg, sh), Asr(bb, sh), fr, fg, fb);
          EmitLinear(C, fr, fg, fb, la, HaveAlpha, br, bg, bbb, Skip);
          if Skip then Continue;
        end
        else if Linear then
        begin
          lr := ChanToLinear(F, Asr(rr, sh));
          lg := ChanToLinear(F, Asr(gg, sh));
          lb := ChanToLinear(F, Asr(bb, sh));
          EmitLinear(C, lr, lg, lb, la, HaveAlpha, br, bg, bbb, Skip);
          if Skip then Continue;
        end
        else if F.BD = BD_565 then
        begin
          gg := EnsureRange(Asr(gg, sh), 0, 63);
          rr := EnsureRange(Asr(rr, sh + 1), 0, 31);
          bb := EnsureRange(Asr(bb, sh + 1), 0, 31);
          if not F.RBSwapped then begin t := rr; rr := bb; bb := t; end;
          br := rr shl 3; bg := gg shl 2; bbb := bb shl 3;
        end
        else
        begin
          rr := Asr(rr, sh); gg := Asr(gg, sh); bb := Asr(bb, sh);
          if ((F.BD = BD_5) or (F.BD = BD_10)) and not F.RBSwapped then
          begin t := rr; rr := bb; bb := t; end;
          if C.Premul and HaveAlpha and ((F.BD = BD_8) or (F.BD = BD_16)) then
          begin
            if F.BD = BD_16 then
            begin
              // 16-bit integer: divide at full precision
              if pA <> nil then
                a16 := EnsureRange(Asr(pA[iIdx] + F.BiasA, sh) shl F.NLen, 0, 65535)
              else
                a16 := EnsureRange(Round(la), 0, 65535);
              c16 := EnsureRange(rr shl F.NLen, 0, 65535); br := Unpremul8(c16, a16);
              c16 := EnsureRange(gg shl F.NLen, 0, 65535); bg := Unpremul8(c16, a16);
              c16 := EnsureRange(bb shl F.NLen, 0, 65535); bbb := Unpremul8(c16, a16);
            end
            else
            begin
              br := Unpremul8(Clip8(rr), aa);
              bg := Unpremul8(Clip8(gg), aa);
              bbb := Unpremul8(Clip8(bb), aa);
            end;
          end
          else
          begin
            br := ChanToByte(F, rr, False);
            bg := ChanToByte(F, gg, False);
            bbb := ChanToByte(F, bb, False);
          end;
        end;
      end;

      if C.HistPass then Continue;
      Dest[o + 0] := br;
      Dest[o + 1] := bg;
      Dest[o + 2] := bbb;
      if pA <> nil then Dest[o + 3] := aa else Dest[o + 3] := 255;
    end;
  end;
end;

// External YUV 4:2:2 / 4:2:0: upsample the native chroma planes with the same
// interpolation jxrlib uses internally (strdec.c interpolateUV, applied to the
// output samples) and convert Y Cb Cr -> RGB (BT.601, full range, fixed point).
// Y was stored in the R byte of each pixel.
procedure FinishYUV(Dest: PByte; const C: TOutCtx; W, H, ExtraLeft, ExtraTop,
  PadW, PadH: Integer);

  function Samp(const Pl: TBytes; cx, cy: Integer): Integer; inline;
  begin
    Result := Pl[NativeInt(cy) * C.CStride + cx];
  end;

  // chroma at padded (col,row) after vertical interpolation, even col only
  function Vert(const Pl: TBytes; cx, row: Integer): Integer;
  begin
    if not C.Is420 then Exit(Samp(Pl, cx, row));
    if (row and 1) = 0 then Result := Samp(Pl, cx, row shr 1)
    else if row = PadH - 1 then Result := Samp(Pl, cx, row shr 1)
    else Result := (Samp(Pl, cx, row shr 1) + Samp(Pl, cx, (row shr 1) + 1) + 1) shr 1;
  end;

  function Chroma(const Pl: TBytes; col, row: Integer): Integer;
  begin
    if (col and 1) = 0 then Result := Vert(Pl, col shr 1, row)
    else if col = PadW - 1 then Result := Vert(Pl, (col - 1) shr 1, row)
    else Result := (Vert(Pl, (col - 1) shr 1, row) + Vert(Pl, (col + 1) shr 1, row) + 1) shr 1;
  end;

var
  x, y, col, row, yv, cb, cr: Integer;
  o: NativeInt;
begin
  for y := 0 to H - 1 do
  begin
    row := y + ExtraTop;
    for x := 0 to W - 1 do
    begin
      col := x + ExtraLeft;
      o := (NativeInt(y) * W + x) * 4;
      yv := Dest[o];
      cb := Chroma(C.CU, col, row) - 128;
      cr := Chroma(C.CV, col, row) - 128;
      Dest[o + 0] := Clip8(yv + Asr(91881 * cr + 32768, 16));
      Dest[o + 1] := Clip8(yv + Asr(-22554 * cb - 46802 * cr + 32768, 16));
      Dest[o + 2] := Clip8(yv + Asr(116130 * cb + 32768, 16));
      Dest[o + 3] := 255;
    end;
  end;
end;

// Applies the header's presentation orientation (rotate CW first, then flips).
function ApplyOrientation(const Src: TBytes; var W, H: Integer; O: Integer): TBytes;
var
  x, y, nx, ny, NW, NH: Integer;
  s, d: NativeInt;
begin
  if (O <= 0) or (O > 7) then begin Result := Src; Exit; end;
  if (O and 4) <> 0 then begin NW := H; NH := W; end else begin NW := W; NH := H; end;
  SetLength(Result, NativeInt(NW) * NH * 4);
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      if (O and 4) <> 0 then begin nx := H - 1 - y; ny := x; end
      else begin nx := x; ny := y; end;
      if (O and 2) <> 0 then nx := NW - 1 - nx;
      if (O and 1) <> 0 then ny := NH - 1 - ny;
      s := (NativeInt(y) * W + x) * 4;
      d := (NativeInt(ny) * NW + nx) * 4;
      PCardinal(@Result[d])^ := PCardinal(@Src[s])^;
    end;
  W := NW; H := NH;
end;

// ============================ DecodeJxr =================================

// Decodes one WMPHOTO codestream (D points at "WMPHOTO") to RGBA8 in stored
// (un-oriented) order. AlphaIn: already decoded planar alpha, used to
// un-premultiply colour when Premul is set.
function DecodeCodestream(D: PByte; DSize: NativeInt; out Width, Height,
  Orientation: Integer; AsAlpha, Premul: Boolean; AlphaIn, AlphaOut: PSingle): TBytes;
const
  BDNames: array[0..15] of string = ('1-bit', '8-bit', '16-bit', '16-bit signed',
    '16-bit half float', '32-bit', '32-bit signed', '32-bit float', '5-bit (555)',
    '10-bit (101010)', '565', '?', '?', '?', '?', '1-bit');
var
  Hdr, HdrA: TJxrCore;
  s: TSBIO;
  HdrEnd: NativeInt;
  W, H: Integer;
  F: TOutFmt;
  C: TOutCtx;
  Res: TBytes;

  procedure RunPass;
  var
    P, A: TJxrSC;
    k: Integer;

    procedure ZeroRow(SC: TJxrSC);
    var i: Integer;
    begin
      for i := 0 to SC.NumCh - 1 do
        FillChar(SC.p1[i]^, SC.Stride[i] * SC.cmbWidth * SizeOf(Integer), 0);
    end;

    procedure DoMB;
    begin
      if not P.ProcessMB then raise EJxrError.Create('JXR: macroblock decode error');
      if A <> nil then
      begin
        A.cRow := P.cRow; A.cColumn := P.cColumn;
        if not A.ProcessMB then raise EJxrError.Create('JXR: alpha macroblock decode error');
      end;
    end;

  begin
    P := TJxrSC.Create;
    A := nil;
    try
      P.InitFromHeader(Hdr, D, DSize);
      if not P.StrIODecInit(HdrEnd) then
        raise EJxrError.Create('JXR: could not read the index table');
      if not P.StrDecInit then
        raise EJxrError.Create('JXR: decoder initialisation failed');

      if Hdr.AlphaChannel then
      begin
        A := TJxrSC.Create;
        A.InitFromHeader(HdrA, D, DSize);
        A.CF := CF_Y_ONLY;
        A.NumCh := 1;
        A.Secondary := True;
        A.NextSC := P;
        P.NextSC := A;
        A.ShareIO(P);
        if not A.StrDecInit then
          raise EJxrError.Create('JXR: alpha decoder initialisation failed');
      end;

      if C.YUVPlanes and not C.HistPass then
      begin
        C.CStride := P.cmbWidth * 8;
        SetLength(C.CU, NativeInt(C.CStride) * P.cmbHeight * IfThen(C.Is420, 8, 16));
        SetLength(C.CV, Length(C.CU));
      end;

      for k := 0 to P.cmbHeight do
      begin
        P.cRow := k;
        P.cColumn := 0;
        P.InitMRPtr;
        ZeroRow(P);
        if A <> nil then begin A.cRow := k; A.InitMRPtr; ZeroRow(A); end;

        DoMB;
        P.AdvanceMRPtr;
        if A <> nil then A.AdvanceMRPtr;
        P.cColumn := 1;
        while P.cColumn < P.cmbWidth do
        begin
          DoMB;
          P.AdvanceMRPtr;
          if A <> nil then A.AdvanceMRPtr;
          Inc(P.cColumn);
        end;
        P.cColumn := P.cmbWidth;
        DoMB;

        if P.cRow > 0 then
          OutputMBRow(P, A, F, C, @Res[0], W, H, Hdr.ExtraLeft, Hdr.ExtraTop);

        P.AdvanceOneMBRow; P.SwapMRPtr;
        if A <> nil then begin A.AdvanceOneMBRow; A.SwapMRPtr; end;
      end;

      if C.YUVPlanes and not C.HistPass then
        FinishYUV(@Res[0], C, W, H, Hdr.ExtraLeft, Hdr.ExtraTop,
          P.cmbWidth * 16, P.cmbHeight * 16);
    finally
      A.Free;
      P.Free;
    end;
  end;

begin
  Width := 0; Height := 0; Orientation := 0; Result := nil;
  if not ReadWMIHeader(D, DSize, Hdr, s) then
    raise EJxrError.Create('JXR: could not parse the WMPHOTO codestream header');
  if Hdr.AlphaChannel then
  begin
    HdrA := Hdr;
    if not ReadImagePlaneHeader(HdrA, s) then
      raise EJxrError.Create('JXR: could not parse the alpha plane header');
  end;
  HdrEnd := 8 + s.Read;

  if not (Hdr.BdBitDepthSrc in [BD_1, BD_8, BD_16, BD_16S, BD_16F, BD_32S, BD_32F,
                                 BD_5, BD_10, BD_565]) then
    raise EJxrError.CreateFmt('JXR: %s sources are not supported',
      [BDNames[Hdr.BdBitDepthSrc and 15]]);
  if Hdr.CfColorFormatExt > CF_RGBE then
    raise EJxrError.CreateFmt('JXR: unknown colour format %d', [Hdr.CfColorFormatExt]);
  if Hdr.Subband = SB_ISOLATED then
    raise EJxrError.Create('JXR: isolated-subband bitstream cannot be decoded');

  W := Hdr.Width; H := Hdr.Height;
  if (W <= 0) or (H <= 0) or (UInt64(W) * UInt64(H) > MAX_PIXELS) or
     (UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt))) then
    raise EJxrError.CreateFmt('JXR: invalid or unsupported image size %dx%d', [W, H]);
  SetupOutFmt(F, Hdr, AsAlpha);

  C := Default(TOutCtx);
  C.Premul := Premul and (Hdr.AlphaChannel or (AlphaIn <> nil));
  C.AlphaIn := AlphaIn;
  C.AlphaOut := AlphaOut;
  C.YUVPlanes := (not AsAlpha) and
    ((Hdr.CfColorFormatExt = CF_YUV420) or (Hdr.CfColorFormatExt = CF_YUV422)) and
    ((Hdr.CfColorFormat = CF_YUV420) or (Hdr.CfColorFormat = CF_YUV422));
  C.Is420 := Hdr.CfColorFormat = CF_YUV420;
  SetLength(Res, NativeInt(W) * H * 4);

  // HDR: pass 1 measures the highlight peak, pass 2 tone maps if it exceeds
  // SDR white (1.0); SDR-range images are left exactly as jxrlib converts them
  if JxrToneMapHDR and IsLinearFmt(F) then
  begin
    C.HistPass := True;
    SetLength(C.Hist, HIST_BINS + 1);
    RunPass;
    C.HistPass := False;
    C.TMPeak := HistPercentile(C, JxrToneMapPercentile);
    C.TMKnee := EnsureRange(JxrToneMapKnee, 0.0, 0.99);
    C.ToneMap := C.TMPeak > 1.0;
    if C.ToneMap then C.TMS := (C.TMPeak - C.TMKnee) / (1 - C.TMKnee);
  end;
  RunPass;

  Result := Res;
  Width := W; Height := H;
  Orientation := Hdr.Orientation;
end;

// Clamps a container (offset, byte count) pair to the buffer.
function StreamBounds(const InBuf: TBytes; Ofs, Count: Cardinal; out D: PByte;
  out DSize: NativeInt): Boolean;
begin
  Result := (Ofs > 0) and (NativeInt(Ofs) < Length(InBuf));
  if not Result then Exit;
  D := @InBuf[Ofs];
  DSize := NativeInt(Length(InBuf)) - NativeInt(Ofs);
  if (Count > 0) and (NativeInt(Count) < DSize) then DSize := Count;
end;

function DecodeJxr(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Info: TJxrInfo;
  D: PByte;
  DSize: NativeInt;
  Alpha: TBytes;
  AW, AH, AO, Orient: Integer;
  i: NativeInt;
  HavePlanar, Match: Boolean;
  Hdr: TJxrCore;
  s: TSBIO;
  ALin: array of Single;
  AIn, AOut: PSingle;
begin
  Width := 0; Height := 0;
  if not JxrParseContainer(InBuf, Info) then
    raise EJxrError.Create('JXR: not a JPEG XR / HD Photo file');

  // planar alpha is a separate Y-only codestream; decode it first so that
  // premultiplied colour can be divided by it
  Alpha := nil; ALin := nil; AIn := nil; AOut := nil;
  HavePlanar := StreamBounds(InBuf, Info.AlphaOffset, Info.AlphaByteCount, D, DSize);
  if HavePlanar then
  begin
    // premultiplied colour is divided by the full-precision alpha
    if Info.Premultiplied and ReadWMIHeader(D, DSize, Hdr, s) and
       (Hdr.Width > 0) and (Hdr.Height > 0) and
       (UInt64(Hdr.Width) * UInt64(Hdr.Height) <= MAX_PIXELS) then
    begin
      SetLength(ALin, NativeInt(Hdr.Width) * Hdr.Height);
      AOut := @ALin[0];
    end;
    Alpha := DecodeCodestream(D, DSize, AW, AH, AO, True, False, nil, AOut);
    if NativeInt(AW) * AH <> Length(ALin) then ALin := nil;
  end;

  if not StreamBounds(InBuf, Info.ImageOffset, Info.ImageByteCount, D, DSize) then
    raise EJxrError.Create('JXR: image data offset is outside the file');
  Match := HavePlanar and ReadWMIHeader(D, DSize, Hdr, s) and
           (Hdr.Width = AW) and (Hdr.Height = AH);
  if Match and (ALin <> nil) then AIn := @ALin[0];
  Result := DecodeCodestream(D, DSize, Width, Height, Orient, False,
    Info.Premultiplied, AIn, nil);
  if Match and (AW = Width) and (AH = Height) then
    for i := 0 to NativeInt(Width) * Height - 1 do
      Result[i * 4 + 3] := Alpha[i * 4];

  if Orient <> 0 then
    Result := ApplyOrientation(Result, Width, Height, Orient);
end;

end.
