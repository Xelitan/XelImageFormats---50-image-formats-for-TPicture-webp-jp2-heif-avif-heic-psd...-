unit Heif.Encode;

// HEIF/HEIC image encoder.
//
// Drives the pure-Pascal BPG HEVC encoder (h265_enc) to code a picture as an
// HEVC intra frame, then wraps it in a HEIF/ISOBMFF container (Heif.Writer) with
// a synthesized standard SPS/VPS + hvcC (Heif.H265.Emit).
//
// Input is 8-bit RGB (top-down, R,G,B per pixel). The picture is coded as 4:2:0
// YCbCr using BT.601 limited range — the exact inverse of Heif.Decode's colour
// conversion, so an encode/decode round-trip is faithful.

{$mode delphi}{$H+}

interface

uses
  SysUtils, Heif.Reader, Heif.Hevc, Heif.H265.Emit, Heif.Writer,
  h265_common, h265_hevc_defs, h265_frame, h265_putbits, h265_enc;

type
  EHeifEncode = class(Exception);

// Encodes an 8-bit RGB image to a HEIC byte buffer.
// AQuality is 0..100 (higher = better/larger); maps to an HEVC QP.
// AChromaFormat: 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4.
// AExif/AIcc: optional metadata to embed (raw TIFF/Exif, ICC profile).
function EncodeHeifFromRGB(const ARGB: TBytes; AWidth, AHeight: Integer;
  AQuality: Integer; AChromaFormat: Integer;
  const AExif: TBytes = nil; const AIcc: TBytes = nil): TBytes;

implementation

function Clip(V, Lo, Hi: Integer): Integer; inline;
begin
  if V < Lo then Result := Lo
  else if V > Hi then Result := Hi
  else Result := V;
end;

function BufToBytes(const B: TByteBuf): TBytes;
begin
  SetLength(Result, B.Len);
  if B.Len > 0 then
    Move(B.Buf^, Result[0], B.Len);
end;

// Sets a 16-bit sample in an AVFrame plane.
procedure PlaneSet(F: PAVFrame; CIdx, X, Y: Integer; V: Word); inline;
begin
  (PWord(F^.Data[CIdx] + Y * F^.Linesize[CIdx]) + X)^ := V;
end;

function EncodeHeifFromRGB(const ARGB: TBytes; AWidth, AHeight: Integer;
  AQuality: Integer; AChromaFormat: Integer;
  const AExif: TBytes; const AIcc: TBytes): TBytes;
var
  Enc: TH265Encoder;
  EncW, EncH, PadW, PadH, CW, CH: Integer;
  SubW, SubH: Integer;
  Qp: Integer;
  X, Y, Sx, Sy, R, G, B: Integer;
  YV, CbV, CrV: Integer;
  SumCb, SumCr: Int64;
  Cnt, CntLog2: Integer;
  P: THevcParams;
  Vps, Sps, PpsNal, SliceNal, HvcC, ItemData: TBytes;
  SliceLen: Integer;
  Color: TNclxColor;

  function RgbIdx(Px, Py: Integer): Integer;
  begin
    // clamp into the valid image for edge replication of padding
    if Px >= AWidth then Px := AWidth - 1;
    if Py >= AHeight then Py := AHeight - 1;
    Result := (Py * AWidth + Px) * 3;
  end;

begin
  if (AWidth <= 0) or (AHeight <= 0) then
    raise EHeifEncode.Create('Invalid dimensions');
  if (AChromaFormat < 1) or (AChromaFormat > 3) then
    raise EHeifEncode.CreateFmt('Unsupported chroma format %d', [AChromaFormat]);

  if AChromaFormat = 1 then begin SubW := 2; SubH := 2; end       // 4:2:0
  else if AChromaFormat = 2 then begin SubW := 2; SubH := 1; end  // 4:2:2
  else begin SubW := 1; SubH := 1; end;                            // 4:4:4

  // The coded size must be a whole number of chroma samples: an odd size is
  // rounded up (the extra column / row repeats the edge pixels) and a 'clap'
  // (clean aperture) property crops the picture back to AWidth x AHeight.
  EncW := ((AWidth + SubW - 1) div SubW) * SubW;
  EncH := ((AHeight + SubH - 1) div SubH) * SubH;

  // Coded size padded up to the min coding block size (8).
  PadW := (EncW + 7) and (not 7);
  PadH := (EncH + 7) and (not 7);

  Qp := Clip(((100 - AQuality) * 51) div 100, 0, 51);

  // Encoder defaults: intra, SAO + deblocking on, no lossless/screen.
  h265_enc_lossless(False);
  h265_enc_screen(False);
  h265_enc_sao(True);
  h265_enc_deblock(True);
  h265_enc_modes(True);
  h265_enc_ccp(False);

  if h265_enc_init(Enc, EncW, EncH, AChromaFormat, 8, Qp) < 0 then
    raise EHeifEncode.Create('h265_enc_init failed');
  try
    CW := PadW div SubW;
    CH := PadH div SubH;

    // BT.601 limited range with the exact coefficients (x 2^16 / 255), the
    // inverse of what decoders apply for matrix 6, rounded to nearest. The
    // old 66/129/25 over 256 approximation and truncating division cost
    // several dB before any coding. Luma: full padded resolution, the padding
    // edge-replicated.
    for Y := 0 to PadH - 1 do
      for X := 0 to PadW - 1 do
      begin
        R := ARGB[RgbIdx(X, Y) + 0];
        G := ARGB[RgbIdx(X, Y) + 1];
        B := ARGB[RgbIdx(X, Y) + 2];
        YV := 16 + SarInt64(16829 * Int64(R) + 33039 * G + 6416 * B + 32768, 16);
        PlaneSet(Enc.Src, 0, X, Y, Word(Clip(YV, 0, 255)));
      end;

    // Chroma planes: the average over each SubW x SubH luma block.
    CntLog2 := Ord(SubW = 2) + Ord(SubH = 2);
    for Y := 0 to CH - 1 do
      for X := 0 to CW - 1 do
      begin
        SumCb := 0; SumCr := 0; Cnt := 0;
        for Sy := 0 to SubH - 1 do
          for Sx := 0 to SubW - 1 do
          begin
            R := ARGB[RgbIdx(X * SubW + Sx, Y * SubH + Sy) + 0];
            G := ARGB[RgbIdx(X * SubW + Sx, Y * SubH + Sy) + 1];
            B := ARGB[RgbIdx(X * SubW + Sx, Y * SubH + Sy) + 2];
            SumCb := SumCb + (-9714 * Int64(R) - 19070 * G + 28784 * B);
            SumCr := SumCr + (28784 * Int64(R) - 24103 * G - 4681 * B);
            Inc(Cnt);
          end;
        // round(Sum / (Cnt * 2^16)); Cnt is a power of two (1, 2, 4), so
        // one arithmetic shift rounds negatives correctly too
        CbV := 128 + SarInt64(SumCb + Cnt * 32768, 16 + CntLog2);
        CrV := 128 + SarInt64(SumCr + Cnt * 32768, 16 + CntLog2);
        PlaneSet(Enc.Src, 1, X, Y, Word(Clip(CbV, 0, 255)));
        PlaneSet(Enc.Src, 2, X, Y, Word(Clip(CrV, 0, 255)));
      end;

    if h265_enc_picture(Enc) < 0 then
      raise EHeifEncode.Create('h265_enc_picture failed');

    // --- assemble parameter sets and container ---
    FillChar(P, SizeOf(P), 0);
    P.ChromaFormatIdc := AChromaFormat;
    P.BitDepthLuma := 8;
    P.BitDepthChroma := 8;
    P.CodedWidth := PadW;
    P.CodedHeight := PadH;
    P.ConfWinRight := (PadW - EncW) div SubW;
    P.ConfWinBottom := (PadH - EncH) div SubH;
    P.Log2MinCbSize := 3;
    P.Log2MaxCbSize := 5;
    P.Log2MinTbSize := 2;
    P.Log2MaxTbSize := 5;
    P.MaxTransformHierarchyDepth := 3;
    P.AmpEnabled := 1;
    P.SaoEnabled := Enc.Sps.SaoEnabled;
    P.StrongIntraSmoothing := Enc.Sps.StrongIntraSmoothing;
    FillProfileLevel(P);

    Vps := EmitVpsNal;
    Sps := EmitSpsNal(P);
    PpsNal := WrapRbspNal(NAL_PPS, BufToBytes(Enc.PpsRbsp));
    SliceNal := WrapRbspNal(NAL_IDR_W_RADL, BufToBytes(Enc.SliceRbsp));
    HvcC := BuildHvcC(Vps, Sps, PpsNal, P);

    // Item data: 4-byte length prefix + slice NAL (lengthSizeMinusOne = 3).
    SliceLen := Length(SliceNal);
    SetLength(ItemData, 4 + SliceLen);
    ItemData[0] := (SliceLen shr 24) and $FF;
    ItemData[1] := (SliceLen shr 16) and $FF;
    ItemData[2] := (SliceLen shr 8) and $FF;
    ItemData[3] := SliceLen and $FF;
    if SliceLen > 0 then
      Move(SliceNal[0], ItemData[4], SliceLen);

    // We encode BT.601 limited-range YCbCr with BT.709/sRGB primaries, so
    // signal that in the nclx box: primaries=1 (BT.709), transfer=13 (sRGB),
    // matrix=6 (BT.601 / SMPTE 170M), limited range.
    Color.Primaries := 1;
    Color.Transfer := 13;
    Color.Matrix := 6;
    Color.FullRange := False;
    Result := BuildHeifFileCropped(HvcC, ItemData, EncW, EncH, AWidth, AHeight,
      Color, AExif, AIcc);
  finally
    h265_enc_free(Enc);
  end;
end;

end.
