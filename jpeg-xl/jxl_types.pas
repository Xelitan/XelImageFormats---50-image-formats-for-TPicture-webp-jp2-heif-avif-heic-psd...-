{$mode delphi}
unit jxl_types;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT

interface

uses SysUtils;

const
  JXL_MAX_SIZE        = 268435456;  // 2^28
  ANS_LOG_TAB_SIZE    = 12;
  ANS_TAB_SIZE        = 1 shl ANS_LOG_TAB_SIZE;  // 4096
  ANS_TAB_MASK        = ANS_TAB_SIZE - 1;
  BROTLI_MAX_ALPHABET = 4098;
  MAX_NUM_PASSES      = 11;
  kGroupDim          = 256;

type
  EJxlError = class(Exception);

  TJxlStatus = (jsOK, jsError, jsNeedMoreInput, jsEndOfFile);

  TJxlColorSpace = (
    jcsRGB,
    jcsGray,
    jcsXYB,
    jcsUnknown
  );

  TJxlWhitePoint = (
    jwpD65    = 1,
    jwpCustom = 2,
    jwpE      = 10,
    jwpDCI    = 11
  );

  TJxlPrimaries = (
    jpSRGB   = 1,
    jpCustom = 2,
    jpP3D65  = 3,
    jp2100   = 9
  );

  TJxlTransferFunction = (
    jtf709     = 1,
    jtfUnknown = 2,
    jtfLinear  = 8,
    jtfSRGB    = 13,
    jtfPQ      = 16,
    jtfDCI     = 17,
    jtfHLG     = 18,
    jtfGamma   = 4096
  );

  TJxlRenderingIntent = (
    jriPerceptual = 0,
    jriRelative   = 1,
    jriSaturation = 2,
    jriAbsolute   = 3
  );

  TJxlExtraChannelType = (
    jectAlpha       = 0,
    jectDepth       = 1,
    jectSpotColor   = 2,
    jectSelection   = 3,
    jectBlack       = 4,
    jectCFA         = 5,
    jectThermal     = 6,
    jectOptional    = 15
  );

  TJxlColorEncoding = record
    WantICC:         Boolean;
    ColorSpace:      TJxlColorSpace;
    WhitePoint:      TJxlWhitePoint;
    WhiteCustomX:    Double;
    WhiteCustomY:    Double;
    Primaries:       TJxlPrimaries;
    PrimRX, PrimRY:  Double;
    PrimGX, PrimGY:  Double;
    PrimBX, PrimBY:  Double;
    TransferFn:      TJxlTransferFunction;
    Gamma:           Double;
    RenderIntent:    TJxlRenderingIntent;
    HasICC:          Boolean;
  end;

  TJxlExtraChannelInfo = record
    ChanType:     TJxlExtraChannelType;
    BitsPerSample: Integer;
    ExponentBits: Integer;
    DimShift:     Integer;
    Name:         AnsiString;
    AlphaAssoc:   Boolean;       // premultiplied alpha
    SpotColor:    array[0..3] of Single;
    CFARaw:       Boolean;
    CFAChannel:   Integer;
  end;

  TJxlImageMetadata = record
    XSize, YSize:      Cardinal;
    Orientation:       Integer;   // 1-8
    IntrinsicXSize:    Cardinal;
    IntrinsicYSize:    Cardinal;
    BitsPerSample:     Integer;
    ExponentBits:      Integer;
    FloatSamples:      Boolean;
    AlphaBits:         Integer;
    AlphaExponentBits: Integer;
    AlphaPremultiplied:Boolean;
    ColorEncoding:     TJxlColorEncoding;
    XYBEncoded:        Boolean;
    IntensityTarget:   Single;
    MinNits:           Single;
    RelativeToMax:     Boolean;
    LinearBelow:       Single;
    ExtraChannels:     array of TJxlExtraChannelInfo;
    ICCProfile:        array of Byte;
    // preview and animation headers
    HavePreview:       Boolean;
    PreviewXSize, PreviewYSize: Cardinal;
    HaveAnimation:     Boolean;
    TpsNumerator, TpsDenominator, NumLoops: Cardinal;
    HaveTimecodes:     Boolean;
    // CustomTransformData (image_metadata.h): opsin inverse matrix and
    // biases, quantization biases and the upsampling kernel weights
    OpsinInverse:      array[0..8] of Single;   // row-major 3x3
    OpsinBias:         array[0..2] of Single;   // negative biases, as libjxl
    QuantBias:         array[0..3] of Single;
    Ups2Weights:       array[0..14] of Single;
    Ups4Weights:       array[0..54] of Single;
    Ups8Weights:       array[0..209] of Single;
  end;

  TJxlBlendMode = (
    jbmReplace = 0,
    jbmAdd     = 1,
    jbmBlend   = 2,
    jbmMulAdd  = 3,
    jbmMul     = 4
  );

  TJxlFrameType = (
    jftRegular        = 0,
    jftLF             = 1,
    jftReferenceOnly  = 2,
    jftSkipProgressive= 3
  );

  // A plane of 32-bit float samples, row-major
  TFloat32Plane = record
    Width, Height: Integer;
    Stride:        Integer;   // samples per row (>= Width)
    Data:          array of Single;
  end;
  PFloat32Plane = ^TFloat32Plane;

  // Multi-channel image (float)
  TJxlImageF = record
    Width, Height: Integer;
    NumChannels:   Integer;   // 1 (gray) or 3 (RGB/XYB)
    Planes:        array[0..3] of TFloat32Plane;
    ExtraPlanes:   array of TFloat32Plane;
  end;

  // Final decoded image in 8-bit RGBA
  TJxlImage8 = record
    Width, Height:  Integer;
    HasAlpha:       Boolean;
    Pixels:         array of Byte;  // RGBA or RGB, row-major
  end;

procedure InitFloat32Plane(var p: TFloat32Plane; w, h: Integer);
function  PlaneAt(const p: TFloat32Plane; x, y: Integer): Single; inline;
procedure PlaneSet(var p: TFloat32Plane; x, y: Integer; v: Single); inline;

implementation

procedure InitFloat32Plane(var p: TFloat32Plane; w, h: Integer);
begin
  p.Width  := w;
  p.Height := h;
  p.Stride := w;
  SetLength(p.Data, w * h);
end;

function PlaneAt(const p: TFloat32Plane; x, y: Integer): Single;
begin
  Result := p.Data[y * p.Stride + x];
end;

procedure PlaneSet(var p: TFloat32Plane; x, y: Integer; v: Single);
begin
  p.Data[y * p.Stride + x] := v;
end;

end.
