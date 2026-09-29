{$mode delphi}
unit jxl_color;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// Color-space transforms for JPEG XL:
//   XYB → linear sRGB → sRGB (gamma)
//   Linear sRGB → sRGB
//   Tone mapping helpers

interface

uses SysUtils, Math, jxl_types;

// XYB to linear sRGB (in-place, 3 planes)
procedure XYBToLinearSRGB(var X, Y, B: TFloat32Plane);

// Linear light → display-referred sRGB gamma (IEC 61966-2-1)
function  LinearToSRGB(v: Single): Single; inline;

// Display-referred sRGB → linear
function  SRGBToLinear(v: Single): Single; inline;

// PQ (SMPTE ST 2084) transfer function
function  LinearToPQ(v: Single): Single;
function  PQToLinear(v: Single): Single;

// HLG (Rec. ITU-R BT.2100)
function  LinearToHLG(v: Single): Single;
function  HLGToLinear(v: Single): Single;

// Convert a float32 sample in [0,1] to an 8-bit byte value (clamped)
function  FloatToByte(v: Single): Byte; inline;

// Convert a float32 sample in [0,1] to a 16-bit word (clamped, linear)
function  FloatToWord(v: Single): Word; inline;

// Convert integer modular sample to float in [0,1]
function  IntSampleToFloat(v: Int64; bitDepth: Integer): Single; inline;

// Apply the appropriate transfer function given the metadata
procedure ApplyTransferFunction(var plane: TFloat32Plane;
                                tf: TJxlTransferFunction; gamma: Double);

implementation

// ---------------------------------------------------------------------------
// XYB → linear sRGB
// The XYB color space in JXL:
//   X  = (0.5*(L' - M'))
//   Y  = (0.5*(L' + M'))  // actually luminance-like
//   B  = S'
// where L', M', S' are gamma-encoded LMS values.
//
// Inverse (linear sRGB):
//   L' = Y + X
//   M' = Y - X
//   S' = B
// Then apply the inverse LMS→XYZ matrix and XYZ→sRGB matrix.
// (Opsin inverse matrix from libjxl)
// ---------------------------------------------------------------------------
const
  // Default inverse opsin absorbance matrix (libjxl cms/opsin_params.h,
  // kDefaultInverseOpsinAbsorbanceMatrix): mixed LMS -> linear sRGB.
  kM: array[0..8] of Double = (
    11.031566901960783, -9.866943921568629,  -0.16462299647058826,
    -3.254147380392157,  4.418770392156863,  -0.16462299647058826,
    -3.6588512862745097, 2.7129230470588235,  1.9459282392156863
  );
  // Opsin absorbance bias (kOpsinAbsorbanceBias0).
  kOpsinBias = 0.0037930732552754493;

// dec_xyb-inl.h XybToRgb: the encoder stores cbrt(LMS + bias) - cbrt(bias),
// so LMS = (gamma + cbrt(bias))^3 - bias. No clamping: out-of-gamut values
// are kept (they may be in gamut in a wider space).
procedure XYBToLinearSRGB(var X, Y, B: TFloat32Plane);
var
  i, n: Integer;
  Lp, Mp, Sp, CbrtBias: Double;
  L, M, S: Double;
begin
  CbrtBias := Power(kOpsinBias, 1.0 / 3.0);
  n := X.Width * X.Height;
  for i := 0 to n - 1 do
  begin
    Lp := Y.Data[i] + X.Data[i] + CbrtBias;
    Mp := Y.Data[i] - X.Data[i] + CbrtBias;
    Sp := B.Data[i] + CbrtBias;
    // guard against overflow on malformed input
    if Lp > 1e6 then Lp := 1e6 else if Lp < -1e6 then Lp := -1e6;
    if Mp > 1e6 then Mp := 1e6 else if Mp < -1e6 then Mp := -1e6;
    if Sp > 1e6 then Sp := 1e6 else if Sp < -1e6 then Sp := -1e6;
    L := Lp * Lp * Lp - kOpsinBias;
    M := Mp * Mp * Mp - kOpsinBias;
    S := Sp * Sp * Sp - kOpsinBias;
    X.Data[i] := kM[0] * L + kM[1] * M + kM[2] * S;
    Y.Data[i] := kM[3] * L + kM[4] * M + kM[5] * S;
    B.Data[i] := kM[6] * L + kM[7] * M + kM[8] * S;
  end;
end;

// ---------------------------------------------------------------------------
function LinearToSRGB(v: Single): Single;
begin
  if IsNaN(v) or IsInfinite(v) then begin Result := 0; Exit; end;
  if v <= 0.0 then
    Result := v * 12.92
  else if v <= 0.0031308 then
    Result := v * 12.92
  else if v >= 1.0 then
    Result := 1.0
  else
    Result := 1.055 * Power(v, 1.0/2.4) - 0.055;
end;

function SRGBToLinear(v: Single): Single;
begin
  if v <= 0.04045 then
    Result := v / 12.92
  else
    Result := Power((v + 0.055) / 1.055, 2.4);
end;

// ---------------------------------------------------------------------------
// PQ transfer function (SMPTE ST 2084)
const
  kPQM1   = 0.1593017578125;
  kPQM2   = 78.84375;
  kPQC1   = 0.8359375;
  kPQC2   = 18.8515625;
  kPQC3   = 18.6875;

function LinearToPQ(v: Single): Single;
var Yp: Single;
begin
  if v <= 0 then begin Result := 0; Exit; end;
  Yp     := Power(v / 10000.0, kPQM1);
  Result := Power((kPQC1 + kPQC2*Yp) / (1.0 + kPQC3*Yp), kPQM2);
end;

function PQToLinear(v: Single): Single;
var Ep: Single;
begin
  if v <= 0 then begin Result := 0; Exit; end;
  Ep     := Power(v, 1.0/kPQM2);
  Result := 10000.0 * Power(Max(0.0, Ep - kPQC1) / (kPQC2 - kPQC3*Ep),
                             1.0/kPQM1);
end;

// ---------------------------------------------------------------------------
// HLG transfer function (ITU-R BT.2100)
const
  kHLGa = 0.17883277;
  kHLGb = 0.28466892;
  kHLGc = 0.55991073;

function LinearToHLG(v: Single): Single;
begin
  if v <= 1.0/12.0 then
    Result := Sqrt(3.0 * v)
  else
    Result := kHLGa * Ln(12.0*v - kHLGb) + kHLGc;
end;

function HLGToLinear(v: Single): Single;
begin
  if v <= 0.5 then
    Result := v * v / 3.0
  else
    Result := (Exp((v - kHLGc) / kHLGa) + kHLGb) / 12.0;
end;

// ---------------------------------------------------------------------------
function FloatToByte(v: Single): Byte;
begin
  if IsNaN(v) or IsInfinite(v) or (v <= 0.0) then begin Result := 0; Exit; end;
  if v >= 1.0 then begin Result := 255; Exit; end;
  Result := Byte(Round(v * 255.0));
end;

function FloatToWord(v: Single): Word;
begin
  if IsNaN(v) or IsInfinite(v) or (v <= 0.0) then begin Result := 0; Exit; end;
  if v >= 1.0 then begin Result := 65535; Exit; end;
  Result := Word(Round(v * 65535.0));
end;

function IntSampleToFloat(v: Int64; bitDepth: Integer): Single;
begin
  if bitDepth <= 0 then begin Result := 0; Exit; end;
  Result := v / ((Int64(1) shl bitDepth) - 1);
end;

// ---------------------------------------------------------------------------
procedure ApplyTransferFunction(var plane: TFloat32Plane;
                                tf: TJxlTransferFunction; gamma: Double);
var i, n: Integer; v: Single;
begin
  n := plane.Width * plane.Height;
  for i := 0 to n - 1 do begin
    v := plane.Data[i];
    case tf of
      jtfSRGB:   v := LinearToSRGB(v);
      jtf709:    begin  // Rec.709 gamma
                   if v < 0.018 then v := v * 4.5
                   else v := 1.099 * Power(v, 0.45) - 0.099;
                 end;
      jtfLinear: ;  // no-op
      jtfPQ:     v := LinearToPQ(v);
      jtfHLG:    v := LinearToHLG(v);
      jtfGamma:  if gamma > 0 then v := Power(Max(0.0, v), gamma);
    else ;
    end;
    plane.Data[i] := v;
  end;
end;

end.
