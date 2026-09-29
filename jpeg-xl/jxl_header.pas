{$mode delphi}
unit jxl_header;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// JPEG XL codestream header parsing — corrected against libjxl 0.11.2 source.
// Key principle: every Bundle (nested struct) starts with 1 bit AllDefault.
// libjxl read semantics (fields.cc ReadVisitor / VisitorBase::Bool):
//   value = (bit == 1).  So:
//   bit=1 -> all_default = TRUE  (skip the rest, use defaults)
//   bit=0 -> all_default = FALSE (explicit fields follow)
// This applies to EVERY Bool field too: on read it is always value=(bit==1),
// regardless of the encoder-side default. There is NO inversion on read.

interface

uses
  SysUtils, jxl_types, jxl_bits;

function AspectRatioXSize(ysize: Cardinal; ratio: Integer): Cardinal;
procedure ReadSizeHeader(br: TBitReader; var md: TJxlImageMetadata);
procedure ReadImageMetadata(br: TBitReader; var md: TJxlImageMetadata);
// CustomTransformData follows ImageMetadata in the codestream.
procedure ReadCustomTransformData(br: TBitReader; var md: TJxlImageMetadata);
// Defaults of the fields set by ReadCustomTransformData.
procedure SetDefaultTransformData(var md: TJxlImageMetadata);

implementation

// ---------------------------------------------------------------------------
// Enum coder (fields.h VisitorBase::Enum): every enum is encoded with the
// single uniform distribution U32(Val(0), Val(1), BitsOffset(4,2), BitsOffset(6,18)).
//   sel=0 -> 0, sel=1 -> 1, sel=2 -> 2 + Bits(4), sel=3 -> 18 + Bits(6)
// ---------------------------------------------------------------------------
function ReadEnum(br: TBitReader): Cardinal; inline;
begin
  Result := br.ReadU32(0,0, 1,0, 2,4, 18,6);
end;

// UnpackSigned: even -> v/2, odd -> -(v+1)/2 (JXL zig-zag)
function UnpackSigned(v: Cardinal): Int64; inline;
begin
  if (v and 1) <> 0 then
    Result := -((Int64(v) + 1) shr 1)
  else
    Result := Int64(v) shr 1;
end;

// Customxy nested bundle: two packed-signed U32 values (x, y).
// U32(Bits(19), BitsOffset(19,524288), BitsOffset(20,1048576), BitsOffset(21,2097152))
procedure ReadCustomXY(br: TBitReader; out cx, cy: Double);
var ux, uy: Cardinal;
begin
  ux := br.ReadU32(0,19, 524288,19, 1048576,20, 2097152,21);
  cx := UnpackSigned(ux) / 1000000.0;   // stored in units of 1e-6
  uy := br.ReadU32(0,19, 524288,19, 1048576,20, 2097152,21);
  cy := UnpackSigned(uy) / 1000000.0;
end;

// ---------------------------------------------------------------------------
// xsize for a SizeHeader aspect-ratio code (headers.cc FixedAspectRatios):
// ysize * num / den with the division truncated, as libjxl computes it.
function AspectRatioXSize(ysize: Cardinal; ratio: Integer): Cardinal;
begin
  case ratio of
    1: Result := ysize;
    2: Result := Cardinal(UInt64(ysize) * 12 div 10);   // 12:10
    3: Result := Cardinal(UInt64(ysize) * 4  div 3);    // 4:3
    4: Result := Cardinal(UInt64(ysize) * 3  div 2);    // 3:2
    5: Result := Cardinal(UInt64(ysize) * 16 div 9);    // 16:9
    6: Result := Cardinal(UInt64(ysize) * 5  div 4);    // 5:4
    7: Result := Cardinal(UInt64(ysize) * 2);           // 2:1
  else Result := ysize;
  end;
end;

// ---------------------------------------------------------------------------
// SizeHeader — headers.cc SizeHeader::VisitFields
//   Non-small: U32(BitsOffset(9,1), BitsOffset(13,1), BitsOffset(18,1), BitsOffset(30,1))
//   Small: 1-bit div8, ysize=(ytmp+1)*8, 3-bit ratio, optional xsize=(xtmp+1)*8
// NOTE: SizeHeader has NO AllDefault preamble in the JXL spec.
// ---------------------------------------------------------------------------
procedure ReadSizeHeader(br: TBitReader; var md: TJxlImageMetadata);
var
  small: Boolean;
  ytmp, xtmp, ratio: Cardinal;
begin
  small := br.ReadBit;
  if small then begin
    ytmp     := br.ReadBits(5);
    md.YSize := (ytmp + 1) * 8;
    ratio    := br.ReadBits(3);
    if ratio = 0 then begin
      xtmp     := br.ReadBits(5);
      md.XSize := (xtmp + 1) * 8;
    end else
      md.XSize := AspectRatioXSize(md.YSize, ratio);
  end else begin
    // BitsOffset(9,1)=sel0, BitsOffset(13,1)=sel1,
    // BitsOffset(18,1)=sel2, BitsOffset(30,1)=sel3
    md.YSize := br.ReadU32(1, 9,  1, 13,  1, 18,  1, 30);
    ratio    := br.ReadBits(3);
    if ratio = 0 then
      md.XSize := br.ReadU32(1, 9,  1, 13,  1, 18,  1, 30)
    else
      md.XSize := AspectRatioXSize(md.YSize, ratio);
  end;
end;

// ---------------------------------------------------------------------------
// PreviewHeader — different U32 from SizeHeader (headers.cc PreviewHeader::VisitFields)
// ---------------------------------------------------------------------------
procedure ReadPreviewHeader(br: TBitReader; var md: TJxlImageMetadata);
var
  div8: Boolean;
  ratio: Cardinal;
begin
  div8 := br.ReadBit;
  if div8 then
    md.PreviewYSize := 8 * br.ReadU32(16, 0,  32, 0,  1, 5,  33, 9)   // ysize_div8
  else
    md.PreviewYSize := br.ReadU32(1, 6,  65, 8,  321, 10,  1345, 12);   // ysize

  ratio := br.ReadBits(3);
  if ratio = 0 then begin
    if div8 then
      md.PreviewXSize := 8 * br.ReadU32(16, 0,  32, 0,  1, 5,  33, 9)
    else
      md.PreviewXSize := br.ReadU32(1, 6,  65, 8,  321, 10,  1345, 12);
  end else
    md.PreviewXSize := AspectRatioXSize(md.PreviewYSize, ratio);
end;

// ---------------------------------------------------------------------------
// AnimationHeader — headers.cc AnimationHeader::VisitFields
// ---------------------------------------------------------------------------
procedure ReadAnimationHeader(br: TBitReader; var md: TJxlImageMetadata);
begin
  md.TpsNumerator   := br.ReadU32(100, 0,  1000, 0,  1, 10,  1, 30);
  md.TpsDenominator := br.ReadU32(1, 0,  1001, 0,  1, 8,  1, 10);
  // U32(Val(0), Bits(3), Bits(16), Bits(32))
  md.NumLoops       := br.ReadU32(0, 0,  0, 3,  0, 16,  0, 32);
  md.HaveTimecodes  := br.ReadBit;
end;

// ---------------------------------------------------------------------------
// BitDepth — image_metadata.cc BitDepth::VisitFields
// Has AllDefault preamble: bit 0 = all default (skip), bit 1 = fields follow.
// Defaults: floating_point_sample=false, bits_per_sample=8, exponent_bits=0
// ---------------------------------------------------------------------------
procedure ReadBitDepth(br: TBitReader; var md: TJxlImageMetadata);
var
  floatSample: Boolean;
  expMinus1: Cardinal;
begin
  // NOTE: BitDepth has NO AllDefault bit (image_metadata.cc BitDepth::VisitFields
  // begins directly with Bool(false, &floating_point_sample)).
  floatSample      := br.ReadBit;
  md.FloatSamples  := floatSample;
  if not floatSample then begin
    // U32(Val(8), Val(10), Val(12), BitsOffset(6,1))
    md.BitsPerSample := br.ReadU32(8, 0,  10, 0,  12, 0,  1, 6);
    md.ExponentBits  := 0;
  end else begin
    // U32(Val(32), Val(16), Val(24), BitsOffset(6,1))
    md.BitsPerSample := br.ReadU32(32, 0,  16, 0,  24, 0,  1, 6);
    // exponent_bits stored as (value-1) in 4 bits
    expMinus1       := br.ReadBits(4);
    md.ExponentBits := Integer(expMinus1) + 1;
  end;
end;

// ---------------------------------------------------------------------------
// ReadBitDepthEC — read BitDepth for an extra channel (same structure, diff target)
// ---------------------------------------------------------------------------
procedure ReadBitDepthEC(br: TBitReader; var ec: TJxlExtraChannelInfo);
var
  floatSample: Boolean;
  expMinus1: Cardinal;
begin
  // BitDepth has NO AllDefault bit.
  floatSample := br.ReadBit;
  if not floatSample then begin
    ec.BitsPerSample := br.ReadU32(8, 0,  10, 0,  12, 0,  1, 6);
    ec.ExponentBits  := 0;
  end else begin
    ec.BitsPerSample := br.ReadU32(32, 0,  16, 0,  24, 0,  1, 6);
    expMinus1        := br.ReadBits(4);
    ec.ExponentBits  := Integer(expMinus1) + 1;
  end;
end;

// ---------------------------------------------------------------------------
// ColorEncoding — color_encoding_internal.cc ColorEncoding::VisitFields
// Has AllDefault preamble.
// Defaults: want_icc=false, kRGB, D65, sRGB primaries, sRGB TF, relative intent
// ---------------------------------------------------------------------------
procedure ReadColorEncoding(br: TBitReader; var ce: TJxlColorEncoding);
var
  allDefault, hasPrimaries: Boolean;
  csRaw, wpRaw, primRaw, tfRaw, riRaw, gammaRaw: Cardinal;
  haveGamma: Boolean;
begin
  // Sensible defaults first
  ce.WantICC      := False;
  ce.ColorSpace   := jcsRGB;
  ce.WhitePoint   := jwpD65;
  ce.Primaries    := jpSRGB;
  ce.TransferFn   := jtfSRGB;
  ce.RenderIntent := jriRelative;
  ce.Gamma        := 0;

  // AllDefault preamble (bit==1 -> all default)
  allDefault := br.ReadBit;
  if allDefault then Exit;

  // want_icc Bool
  ce.WantICC := br.ReadBit;

  // colour_space Enum (default kRGB) — ALWAYS sent, even if want_icc.
  csRaw := ReadEnum(br);
  case csRaw of
    0: ce.ColorSpace := jcsRGB;
    1: ce.ColorSpace := jcsGray;
    2: ce.ColorSpace := jcsXYB;
  else ce.ColorSpace := jcsUnknown;
  end;

  // If want_icc, the remaining fields are NOT serialized (ICC blob follows
  // in the codestream and is read separately).
  if ce.WantICC then Exit;

  hasPrimaries := (ce.ColorSpace <> jcsGray) and (ce.ColorSpace <> jcsXYB);

  // White point — only if NOT implicit (implicit when color_space == kXYB)
  if ce.ColorSpace <> jcsXYB then begin
    wpRaw := ReadEnum(br);
    case wpRaw of
      1:  ce.WhitePoint := jwpD65;
      2:  ce.WhitePoint := jwpCustom;
      10: ce.WhitePoint := jwpE;
      11: ce.WhitePoint := jwpDCI;
    else  ce.WhitePoint := jwpD65;
    end;
    if ce.WhitePoint = jwpCustom then
      ReadCustomXY(br, ce.WhiteCustomX, ce.WhiteCustomY);
  end else
    ce.WhitePoint := jwpD65;

  // Primaries — only if HasPrimaries
  if hasPrimaries then begin
    primRaw := ReadEnum(br);
    case primRaw of
      1:  ce.Primaries := jpSRGB;
      2:  ce.Primaries := jpCustom;
      9:  ce.Primaries := jp2100;
      11: ce.Primaries := jpP3D65;
    else  ce.Primaries := jpSRGB;
    end;
    if ce.Primaries = jpCustom then begin
      ReadCustomXY(br, ce.PrimRX, ce.PrimRY);
      ReadCustomXY(br, ce.PrimGX, ce.PrimGY);
      ReadCustomXY(br, ce.PrimBX, ce.PrimBY);
    end;
  end;

  // CustomTransferFunction — implicit (linear) only for kXYB
  if ce.ColorSpace = jcsXYB then begin
    ce.TransferFn := jtfLinear;
  end else begin
    haveGamma := br.ReadBit;
    if haveGamma then begin
      gammaRaw     := br.ReadBits(24);  // gamma * 1e7
      ce.TransferFn := jtfGamma;
      if gammaRaw <> 0 then
        ce.Gamma := 1.0 / (gammaRaw / 10000000.0)   // stored exponent is 1/gamma
      else
        ce.Gamma := 0;
    end else begin
      tfRaw := ReadEnum(br);
      case tfRaw of
        1:  ce.TransferFn := jtf709;
        8:  ce.TransferFn := jtfLinear;
        13: ce.TransferFn := jtfSRGB;
        16: ce.TransferFn := jtfPQ;
        17: ce.TransferFn := jtfDCI;
        18: ce.TransferFn := jtfHLG;
      else  ce.TransferFn := jtfUnknown;
      end;
    end;
  end;

  // rendering_intent Enum (default kRelative)
  riRaw := ReadEnum(br);
  case riRaw of
    0: ce.RenderIntent := jriPerceptual;
    1: ce.RenderIntent := jriRelative;
    2: ce.RenderIntent := jriSaturation;
    3: ce.RenderIntent := jriAbsolute;
  else ce.RenderIntent := jriRelative;
  end;
end;

// ---------------------------------------------------------------------------
// ExtraChannelInfo — image_metadata.cc ExtraChannelInfo::VisitFields
// Has AllDefault preamble.
// Defaults: kAlpha, 8-bit uint, dim_shift=0, no name, not premultiplied
// ---------------------------------------------------------------------------
procedure ReadExtraChannelInfo(br: TBitReader; var ec: TJxlExtraChannelInfo);
var
  allDefault: Boolean;
  typeRaw, nameLen, i: Integer;
begin
  allDefault := br.ReadBit;
  if allDefault then begin
    ec.ChanType      := jectAlpha;
    ec.BitsPerSample := 8;
    ec.ExponentBits  := 0;
    ec.DimShift      := 0;
    ec.AlphaAssoc    := False;
    Exit;
  end;

  // type is an Enum (uniform enum coder)
  typeRaw := Integer(ReadEnum(br));
  case typeRaw of
    0: ec.ChanType := jectAlpha;
    1: ec.ChanType := jectDepth;
    2: ec.ChanType := jectSpotColor;
    3: ec.ChanType := jectSelection;
    4: ec.ChanType := jectBlack;
    5: ec.ChanType := jectCFA;
    6: ec.ChanType := jectThermal;
  else ec.ChanType := jectOptional;
  end;

  // nested BitDepth (with its own AllDefault)
  ReadBitDepthEC(br, ec);

  // dim_shift: U32(Val(0), Val(3), Val(4), BitsOffset(3,1))
  ec.DimShift := br.ReadU32(0, 0,  3, 0,  4, 0,  1, 3);

  // name: U32(Val(0), Bits(4), BitsOffset(5,16), BitsOffset(10,48)) + chars
  nameLen := br.ReadU32(0, 0,  0, 4,  16, 5,  48, 10);
  SetLength(ec.Name, nameLen);
  for i := 1 to nameLen do
    ec.Name[i] := Chr(br.ReadBits(8));

  // Conditional fields
  case ec.ChanType of
    jectAlpha:
      ec.AlphaAssoc := br.ReadBit;
    jectSpotColor: begin
      ec.SpotColor[0] := br.ReadF16;
      ec.SpotColor[1] := br.ReadF16;
      ec.SpotColor[2] := br.ReadF16;
      ec.SpotColor[3] := br.ReadF16;
    end;
    jectCFA:
      // U32(Val(1), Bits(2), BitsOffset(4,3), BitsOffset(8,19))
      ec.CFAChannel := br.ReadU32(1, 0,  0, 2,  3, 4,  19, 8);
  end;
end;

// ---------------------------------------------------------------------------
// ToneMapping — image_metadata.cc ToneMapping::VisitFields
// Has AllDefault preamble.
// Defaults: intensity_target=255, min_nits=0, relative_to_max=false, linear_below=0
// ---------------------------------------------------------------------------
procedure ReadToneMapping(br: TBitReader; var md: TJxlImageMetadata);
var allDefault: Boolean;
begin
  allDefault := br.ReadBit;
  if allDefault then begin
    md.IntensityTarget := 255.0;
    md.MinNits         := 0.0;
    md.RelativeToMax   := False;
    md.LinearBelow     := 0.0;
    Exit;
  end;
  md.IntensityTarget := br.ReadF16;
  md.MinNits         := br.ReadF16;
  md.RelativeToMax   := br.ReadBit;
  md.LinearBelow     := br.ReadF16;
end;

// ---------------------------------------------------------------------------
// ImageMetadata — image_metadata.cc ImageMetadata::VisitFields
// Has AllDefault preamble.
// Defaults: orientation=1, no extra channels, xyb_encoded=true,
//           sRGB color space, 8-bit, intensity_target=255
// ---------------------------------------------------------------------------
procedure ReadImageMetadata(br: TBitReader; var md: TJxlImageMetadata);
var
  allDefault: Boolean;
  extra_fields: Boolean;
  have_intrinsic_size, have_preview, have_animation: Boolean;
  numExtra, i: Integer;
  tmpMd: TJxlImageMetadata;
begin
  // AllDefault preamble for the entire ImageMetadata bundle
  allDefault := br.ReadBit;
  if allDefault then begin
    // Use all defaults:
    md.Orientation     := 1;
    md.IntrinsicXSize  := 0;
    md.IntrinsicYSize  := 0;
    md.FloatSamples    := False;
    md.BitsPerSample   := 8;
    md.ExponentBits    := 0;
    md.XYBEncoded      := True;   // JXL default is XYB=true
    SetLength(md.ExtraChannels, 0);
    md.ColorEncoding.WantICC    := False;
    md.ColorEncoding.ColorSpace := jcsRGB;
    md.ColorEncoding.WhitePoint := jwpD65;
    md.ColorEncoding.Primaries  := jpSRGB;
    md.ColorEncoding.TransferFn := jtfSRGB;
    md.ColorEncoding.RenderIntent := jriRelative;
    md.IntensityTarget := 255.0;
    md.MinNits         := 0.0;
    md.RelativeToMax   := False;
    md.LinearBelow     := 0.0;
    Exit;
  end;

  // extra_fields gates orientation + intrinsic_size + preview + animation
  // AND tone_mapping (at the end)
  extra_fields := br.ReadBit;

  if extra_fields then begin
    // orientation stored as (value-1) in 3 bits, then +1 on read
    md.Orientation := Integer(br.ReadBits(3)) + 1;

    have_intrinsic_size := br.ReadBit;
    if have_intrinsic_size then begin
      FillChar(tmpMd, SizeOf(tmpMd), 0);
      ReadSizeHeader(br, tmpMd);
      md.IntrinsicXSize := tmpMd.XSize;
      md.IntrinsicYSize := tmpMd.YSize;
    end else begin
      md.IntrinsicXSize := 0;
      md.IntrinsicYSize := 0;
    end;

    have_preview := br.ReadBit;
    md.HavePreview := have_preview;
    if have_preview then
      ReadPreviewHeader(br, md);

    have_animation := br.ReadBit;
    md.HaveAnimation := have_animation;
    if have_animation then
      ReadAnimationHeader(br, md);
  end else begin
    md.Orientation    := 1;
    md.IntrinsicXSize := 0;
    md.IntrinsicYSize := 0;
  end;

  // BitDepth (nested bundle with AllDefault)
  ReadBitDepth(br, md);

  // modular_16_bit_buffer_sufficient (Bool, default=true) — read and discard
  br.ReadBit;

  // num_extra_channels: U32(Val(0), Val(1), BitsOffset(4,2), BitsOffset(12,1))
  // Direct U32, NO separate hasExtras boolean
  numExtra := br.ReadU32(0, 0,  1, 0,  2, 4,  1, 12);
  SetLength(md.ExtraChannels, numExtra);
  for i := 0 to numExtra - 1 do
    ReadExtraChannelInfo(br, md.ExtraChannels[i]);

  // xyb_encoded (Bool, default=true)
  md.XYBEncoded := br.ReadBit;

  // ColorEncoding (nested bundle with AllDefault)
  ReadColorEncoding(br, md.ColorEncoding);

  // ToneMapping (nested bundle with AllDefault) — only when extra_fields=True
  if extra_fields then
    ReadToneMapping(br, md)
  else begin
    md.IntensityTarget := 255.0;
    md.MinNits         := 0.0;
    md.RelativeToMax   := False;
    md.LinearBelow     := 0.0;
  end;

  // Extensions (U64) — read and discard
  br.ReadU64;
end;

// ---------------------------------------------------------------------------
// CustomTransformData (image_metadata.cc): opsin inverse matrix (XYB only)
// and the custom upsampling weights. Has an AllDefault bit.
// ---------------------------------------------------------------------------
const
  kDefaultUps2: array[0..14] of Single = (
    -0.01716200, -0.03452303, -0.04022174, -0.02921014, -0.00624645,
    0.14111091, 0.28896755, 0.00278718, -0.01610267, 0.56661550,
    0.03777607, -0.01986694, -0.03144731, -0.01185068, -0.00213539);
  kDefaultUps4: array[0..54] of Single = (
    -0.02419067, -0.03491987, -0.03693351, -0.03094285, -0.00529785,
    -0.01663432, -0.03556863, -0.03888905, -0.03516850, -0.00989469,
    0.23651958, 0.33392945, -0.01073543, -0.01313181, -0.03556694,
    0.13048175, 0.40103025, 0.03951150, -0.02077584, 0.46914198,
    -0.00209270, -0.01484589, -0.04064806, 0.18942530, 0.56279892,
    0.06674400, -0.02335494, -0.03551682, -0.00754830, -0.02267919,
    -0.02363578, 0.00315804, -0.03399098, -0.01359519, -0.00091653,
    -0.00335467, -0.01163294, -0.01610294, -0.00974088, -0.00191622,
    -0.01095446, -0.03198464, -0.04455121, -0.02799790, -0.00645912,
    0.06390599, 0.22963888, 0.00630981, -0.01897349, 0.67537268,
    0.08483369, -0.02534994, -0.02205197, -0.01667999, -0.00384443);
  kDefaultUps8: array[0..209] of Single = (
    -0.02928613, -0.03706353, -0.03783812, -0.03324558, -0.00447632,
    -0.02519406, -0.03752601, -0.03901508, -0.03663285, -0.00646649,
    -0.02066407, -0.03838633, -0.04002101, -0.03900035, -0.00901973,
    -0.01626393, -0.03954148, -0.04046620, -0.03979621, -0.01224485,
    0.29895328, 0.35757708, -0.02447552, -0.01081748, -0.04314594,
    0.23903219, 0.41119301, -0.00573046, -0.01450239, -0.04246845,
    0.17567618, 0.45220643, 0.02287757, -0.01936783, -0.03583255,
    0.11572472, 0.47416733, 0.06284440, -0.02685066, 0.42720050,
    -0.02248939, -0.01155273, -0.04562755, 0.28689496, 0.49093869,
    -0.00007891, -0.01545926, -0.04562659, 0.21238920, 0.53980934,
    0.03369474, -0.02070211, -0.03866988, 0.14229550, 0.56593398,
    0.08045181, -0.02888298, -0.03680918, -0.00542229, -0.02920477,
    -0.02788574, -0.02118180, -0.03942402, -0.00775547, -0.02433614,
    -0.03193943, -0.02030828, -0.04044014, -0.01074016, -0.01930822,
    -0.03620399, -0.01974125, -0.03919545, -0.01456093, -0.00045072,
    -0.00360110, -0.01020207, -0.01231907, -0.00638988, -0.00071592,
    -0.00279122, -0.00957115, -0.01288327, -0.00730937, -0.00107783,
    -0.00210156, -0.00890705, -0.01317668, -0.00813895, -0.00153491,
    -0.02128481, -0.04173044, -0.04831487, -0.03293190, -0.00525260,
    -0.01720322, -0.04052736, -0.05045706, -0.03607317, -0.00738030,
    -0.01341764, -0.03965629, -0.05151616, -0.03814886, -0.01005819,
    0.18968273, 0.33063684, -0.01300105, -0.01372950, -0.04017465,
    0.13727832, 0.36402234, 0.01027890, -0.01832107, -0.03365072,
    0.08734506, 0.38194295, 0.04338228, -0.02525993, 0.56408126,
    0.00458352, -0.01648227, -0.04887868, 0.24585519, 0.62026135,
    0.04314807, -0.02213737, -0.04158014, 0.16637289, 0.65027023,
    0.09621636, -0.03101388, -0.04082742, -0.00904519, -0.02790922,
    -0.02117818, 0.00798662, -0.03995711, -0.01243427, -0.02231705,
    -0.02946266, 0.00992055, -0.03600283, -0.01684920, -0.00111684,
    -0.00411204, -0.01297130, -0.01723725, -0.01022545, -0.00165306,
    -0.00313110, -0.01218016, -0.01763266, -0.01125620, -0.00231663,
    -0.01374149, -0.03797620, -0.05142937, -0.03117307, -0.00581914,
    -0.01064003, -0.03608089, -0.05272168, -0.03375670, -0.00795586,
    0.09628104, 0.27129991, -0.00353779, -0.01734151, -0.03153981,
    0.05686230, 0.28500998, 0.02230594, -0.02374955, 0.68214326,
    0.05018048, -0.02320852, -0.04383616, 0.18459474, 0.71517975,
    0.10805613, -0.03263677, -0.03637639, -0.01394373, -0.02511203,
    -0.01728636, 0.05407331, -0.02867568, -0.01893131, -0.00240854,
    -0.00446511, -0.01636187, -0.02377053, -0.01522848, -0.00333334,
    -0.00819975, -0.02964169, -0.04499287, -0.02745350, -0.00612408,
    0.02727416, 0.19446600, 0.00159832, -0.02232473, 0.74982506,
    0.11452620, -0.03348048, -0.01605681, -0.02070339, -0.00458223);
  kDefaultInvOpsin: array[0..8] of Single = (
    11.031566901960783, -9.866943921568629, -0.16462299647058826,
    -3.254147380392157, 4.418770392156863, -0.16462299647058826,
    -3.6588512862745097, 2.7129230470588235, 1.9459282392156863);
  kOpsinAbsorbanceBias = 0.0037930732552754493;
  kDefQuantBias: array[0..3] of Single = (1.0 - 0.05465007330715401,
    1.0 - 0.07005449891748593, 1.0 - 0.049935103337343655, 0.145);

procedure SetDefaultTransformData(var md: TJxlImageMetadata);
var i: Integer;
begin
  for i := 0 to 8 do md.OpsinInverse[i] := kDefaultInvOpsin[i];
  for i := 0 to 2 do md.OpsinBias[i] := -kOpsinAbsorbanceBias;
  for i := 0 to 3 do md.QuantBias[i] := kDefQuantBias[i];
  for i := 0 to 14 do md.Ups2Weights[i] := kDefaultUps2[i];
  for i := 0 to 54 do md.Ups4Weights[i] := kDefaultUps4[i];
  for i := 0 to 209 do md.Ups8Weights[i] := kDefaultUps8[i];
end;

procedure ReadCustomTransformData(br: TBitReader; var md: TJxlImageMetadata);
var
  i, mask: Integer;
begin
  SetDefaultTransformData(md);
  if br.ReadBit then Exit;   // all default
  if md.XYBEncoded then
  begin
    // OpsinInverseMatrix, with its own AllDefault bit
    if not br.ReadBit then
    begin
      for i := 0 to 8 do md.OpsinInverse[i] := br.ReadF16;
      for i := 0 to 2 do md.OpsinBias[i] := br.ReadF16;
      for i := 0 to 3 do md.QuantBias[i] := br.ReadF16;
    end;
  end;
  mask := br.ReadBits(3);
  if (mask and 1) <> 0 then
    for i := 0 to 14 do md.Ups2Weights[i] := br.ReadF16;
  if (mask and 2) <> 0 then
    for i := 0 to 54 do md.Ups4Weights[i] := br.ReadF16;
  if (mask and 4) <> 0 then
    for i := 0 to 209 do md.Ups8Weights[i] := br.ReadF16;
end;

end.
