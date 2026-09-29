{$mode delphi}
unit jxl_quant;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// VarDCT dequantization matrices, ported from libjxl 0.11.2 quant_weights.cc:
// the 17 table kinds with their library defaults, the custom encodings a
// frame may signal (identity, DCT2, DCT4, DCT4x8, AFV, DCT bands, raw), and
// the computation of the per-coefficient dequantization multipliers.

interface

uses
  SysUtils, Math, jxl_types, jxl_bits;

const
  kNumQuantTables = 17;
  kMaxDistanceBands = 17;

  QM_LIBRARY = 0;
  QM_ID      = 1;
  QM_DCT2    = 2;
  QM_DCT4    = 3;
  QM_DCT4X8  = 4;
  QM_AFV     = 5;
  QM_DCT     = 6;
  QM_RAW     = 7;

  // blocks per table kind (quant_weights.h required_size_x / _y)
  kQTRequiredX: array[0..16] of Integer = (1, 1, 1, 1, 2, 4, 1, 1, 2, 1, 1, 8, 4, 16, 8, 32, 16);
  kQTRequiredY: array[0..16] of Integer = (1, 1, 1, 1, 2, 4, 2, 4, 4, 1, 1, 8, 8, 16, 16, 32, 32);

  // default DC quantization (quant_weights.h kInvDCQuant)
  kDefaultDCQuant: array[0..2] of Single = (1.0 / 4096.0, 1.0 / 512.0, 1.0 / 256.0);

type
  TDctParams = record
    NumBands: Integer;
    Bands: array[0..2, 0..kMaxDistanceBands - 1] of Single;
  end;

  TQuantEncoding = record
    Mode: Integer;
    IdWeights:   array[0..2, 0..2] of Single;
    Dct2Weights: array[0..2, 0..5] of Single;
    Dct4Mul:     array[0..2, 0..1] of Single;
    Dct4x8Mul:   array[0..2] of Single;
    AfvWeights:  array[0..2, 0..8] of Single;
    DctParams:   TDctParams;
    DctParamsAfv4x4: TDctParams;
    RawTable:    array of Integer;   // 3 * sizeX*8 * sizeY*8
    RawDen:      Single;
  end;

  // Decodes a raw table image (sizeX x sizeY, 3 channels) with the frame's
  // modular decoder (stream QuantTable(idx)); fills table[c*sx*sy + y*sx + x].
  TRawQuantTableReader = procedure(br: TBitReader; idx, sizeX, sizeY: Integer;
                                   var table: array of Integer) of object;

  TDequantMatrices = class
  private
    FEnc: array[0..kNumQuantTables - 1] of TQuantEncoding;
    FComputedMask: Cardinal;   // table kinds computed
  public
    DCQuant: array[0..2] of Single;
    InvDCQuant: array[0..2] of Single;
    // Dequantization multipliers per table kind: 3 channels of
    // (8*required_x) * (8*required_y) values, coefficient layout.
    Tables: array[0..kNumQuantTables - 1] of array of Single;
    constructor Create;
    procedure DecodeDC(br: TBitReader);
    procedure Decode(br: TBitReader; rawReader: TRawQuantTableReader);
    // Computes the tables used by the strategies in acsMask (bit per raw
    // strategy).
    procedure EnsureComputed(acsMask: Cardinal);
    function Matrix(strategy: Integer): PSingle;   // channel 0; c * size follows
    function IsRawJpeg: Boolean;
  end;

implementation

uses jxl_dct;

const
  kAlmostZero = 1e-8;

// ---------------------------------------------------------------------------
// FastPowf (base/fast_math-inl.h): libjxl interpolates the band weights with
// this approximation, so the tables must use it too.
// ---------------------------------------------------------------------------
function FastLog2f(x: Single): Single;
const
  p0 = -1.8503833400518310E-06; p1 = 1.4287160470083755E+00; p2 = 7.4245873327820566E-01;
  q0 = 9.9032814277590719E-01;  q1 = 1.0096718572241148E+00; q2 = 1.7409343003366853E-01;
var
  xb, expBits, expShifted: LongInt;
  mant, m1, yp, yq: Single;
  mbits: LongInt absolute mant;
  xs: Single;
  xsb: LongInt absolute xs;
begin
  xs := x;
  xb := xsb;
  expBits := xb - $3f2aaaab;
  expShifted := SarLongint(expBits, 23);
  mbits := xb - (expShifted shl 23);
  m1 := mant - 1.0;
  yp := (p2 * m1 + p1) * m1 + p0;
  yq := (q2 * m1 + q1) * m1 + q0;
  Result := yp / yq + expShifted;
end;

function FastPow2f(x: Single): Single;
var
  floorx, frac, num, den, e: Single;
  eb: LongInt absolute e;
begin
  floorx := Floor(x);
  eb := (Trunc(floorx) + 127) shl 23;
  frac := x - floorx;
  num := frac + 1.01749063e+01;
  num := num * frac + 4.88687798e+01;
  num := num * frac + 9.85506591e+01;
  num := num * e;
  den := frac * 2.10242958e-01 + (-2.22328856e-02);
  den := den * frac + (-1.94414990e+01);
  den := den * frac + 9.85506633e+01;
  Result := num / den;
end;

function FastPowf(b, e: Single): Single;
begin
  Result := FastPow2f(FastLog2f(b) * e);
end;

function Mult(v: Single): Single; inline;
begin
  if v > 0 then Result := 1.0 + v else Result := 1.0 / (1.0 - v);
end;

// GetQuantWeights: ROWS x COLS weights per channel, out[c*R*C + y*C + x].
procedure GetQuantWeights(rows, cols: Integer; const params: TDctParams;
                          out_: PSingle);
type TSA = array[0..MaxInt div 8] of Single;
var
  c, i, x, y, idx: Integer;
  bands: array[0..kMaxDistanceBands - 1] of Single;
  scale, rcpcol, rcprow, dy, dy2, dx, dist, pos, a, b: Single;
  o: ^TSA;
begin
  o := Pointer(out_);
  for c := 0 to 2 do
  begin
    bands[0] := params.Bands[c][0];
    if bands[0] < kAlmostZero then raise EJxlError.Create('Invalid distance bands');
    for i := 1 to params.NumBands - 1 do
    begin
      bands[i] := bands[i - 1] * Mult(params.Bands[c][i]);
      if bands[i] < kAlmostZero then raise EJxlError.Create('Invalid distance bands');
    end;
    scale := (params.NumBands - 1) / (Sqrt(2.0) + 1e-6);
    rcpcol := scale / (cols - 1);
    rcprow := scale / (rows - 1);
    for y := 0 to rows - 1 do
    begin
      dy := y * rcprow;
      dy2 := dy * dy;
      for x := 0 to cols - 1 do
      begin
        dx := x * rcpcol;
        dist := Sqrt(dx * dx + dy2);
        if params.NumBands = 1 then
          o[c * cols * rows + y * cols + x] := bands[0]
        else
        begin
          // InterpolateVec: idx = int(pos), a * pow(b/a, frac)
          pos := dist;
          idx := Trunc(pos);
          if idx > params.NumBands - 2 then idx := params.NumBands - 2;
          a := bands[idx]; b := bands[idx + 1];
          o[c * cols * rows + y * cols + x] := a * FastPowf(b / a, pos - idx);
        end;
      end;
    end;
  end;
end;

function Interpolate(pos, mx: Single; const arr: array of Single; len: Integer): Single;
var scaled, a, b: Single; idx: Integer;
begin
  scaled := pos * (len - 1) / mx;
  idx := Trunc(scaled);
  if idx + 1 >= len then raise EJxlError.Create('Invalid AFV interpolation');
  a := arr[idx]; b := arr[idx + 1];
  Result := a * FastPowf(b / a, scaled - idx);
end;

// ---------------------------------------------------------------------------
// Library defaults (DequantMatricesLibraryDef)
// ---------------------------------------------------------------------------
procedure SetDct(var e: TQuantEncoding; mode, nb: Integer; const v: array of Double);
var c, i: Integer;
begin
  e.Mode := mode;
  e.DctParams.NumBands := nb;
  for c := 0 to 2 do
    for i := 0 to nb - 1 do
      e.DctParams.Bands[c][i] := v[c * nb + i];
end;

procedure LibraryEncoding(kind: Integer; var e: TQuantEncoding);
var c: Integer;
const
  kId: array[0..8] of Single = (280, 3160, 3160, 60, 864, 864, 18, 200, 200);
  kDct2: array[0..17] of Single = (3840, 2560, 1280, 640, 480, 300,
    960, 640, 320, 180, 140, 120, 640, 320, 128, 64, 32, 16);
  kAfv: array[0..26] of Single = (3072, 3072, 256, 256, 256, 414, 0, 0, 0,
    1024, 1024, 50, 50, 50, 58, 0, 0, 0, 384, 384, 12, 12, 12, 22, -0.25, -0.25, -0.25);
begin
  // only the fields of the chosen mode are read by ComputeQuantTable
  case kind of
    0: SetDct(e, QM_DCT, 6, [3150.0, 0.0, -0.4, -0.4, -0.4, -2.0,
                             560.0, 0.0, -0.3, -0.3, -0.3, -0.3,
                             512.0, -2.0, -1.0, 0.0, -1.0, -2.0]);
    1: begin
         e.Mode := QM_ID;
         for c := 0 to 2 do
         begin
           e.IdWeights[c][0] := kId[c * 3]; e.IdWeights[c][1] := kId[c * 3 + 1];
           e.IdWeights[c][2] := kId[c * 3 + 2];
         end;
       end;
    2: begin
         e.Mode := QM_DCT2;
         for c := 0 to 17 do e.Dct2Weights[c div 6][c mod 6] := kDct2[c];
       end;
    3: begin
         SetDct(e, QM_DCT4, 4, [2200.0, 0.0, 0.0, 0.0, 392.0, 0.0, 0.0, 0.0,
                                112.0, -0.25, -0.25, -0.5]);
         for c := 0 to 2 do begin e.Dct4Mul[c][0] := 1; e.Dct4Mul[c][1] := 1; end;
       end;
    4: SetDct(e, QM_DCT, 7, [8996.8725711814115328, -1.3000777393353804,
         -0.49424529824571225, -0.439093774457103443, -0.6350101832695744,
         -0.90177264050827612, -1.6162099239887414,
         3191.48366296844234752, -0.67424582104194355, -0.80745813428471001,
         -0.44925837484843441, -0.35865440981033403, -0.31322389111877305,
         -0.37615025315725483,
         1157.50408145487200256, -2.0531423165804414, -1.4,
         -0.50687130033378396, -0.42708730624733904, -1.4856834539296244,
         -4.9209142884401604]);
    5: SetDct(e, QM_DCT, 8, [15718.40830982518931456, -1.025, -0.98, -0.9012,
         -0.4, -0.48819395464, -0.421064, -0.27,
         7305.7636810695983104, -0.8041958212306401, -0.7633036457487539,
         -0.55660379990111464, -0.49785304658857626, -0.43699592683512467,
         -0.40180866526242109, -0.27321683125358037,
         3803.53173721215041536, -3.060733579805728, -2.0413270132490346,
         -2.0235650159727417, -0.5495389509954993, -0.4, -0.4, -0.3]);
    6: SetDct(e, QM_DCT, 7, [7240.7734393502, -0.7, -0.7, -0.2, -0.2, -0.2, -0.5,
         1448.15468787004, -0.5, -0.5, -0.5, -0.2, -0.2, -0.2,
         506.854140754517, -1.4, -0.2, -0.5, -0.5, -1.5, -3.6]);
    7: SetDct(e, QM_DCT, 8, [16283.2494710648897, -1.7812845336559429,
         -1.6309059012653515, -1.0382179034313539, -0.85, -0.7, -0.9,
         -1.2360638576849587,
         5089.15750884921511936, -0.320049391452786891, -0.35362849922161446,
         -0.30340000000000003, -0.61, -0.5, -0.5, -0.6,
         3397.77603275308720128, -0.321327362693153371, -0.34507619223117997,
         -0.70340000000000003, -0.9, -1.0, -1.0, -1.1754605576265209]);
    8: SetDct(e, QM_DCT, 8, [13844.97076442300573, -0.97113799999999995, -0.658,
         -0.42026, -0.22712, -0.2206, -0.226, -0.6,
         4798.964084220744293, -0.61125308982767057, -0.83770786552491361,
         -0.79014862079498627, -0.2692727459704829, -0.38272769465388551,
         -0.22924222653091453, -0.20719098826199578,
         1807.236946760964614, -1.2, -1.2, -0.7, -0.7, -0.7, -0.4, -0.5]);
    9: begin
         SetDct(e, QM_DCT4X8, 4, [2198.050556016380522, -0.96269623020744692,
           -0.76194253026666783, -0.6551140670773547,
           764.3655248643528689, -0.92630200888366945, -0.9675229603596517,
           -0.27845290869168118,
           527.107573587542228, -1.4594385811273854, -1.450082094097871593,
           -1.5843722511996204]);
         for c := 0 to 2 do e.Dct4x8Mul[c] := 1;
       end;
    10: begin
          // AFV0: DCT4X8 params, DCT4X4 params (for the 4x4 part), weights
          LibraryEncoding(9, e);
          e.Mode := QM_AFV;
          e.DctParamsAfv4x4.NumBands := 4;
          e.DctParamsAfv4x4.Bands[0][0] := 2200; e.DctParamsAfv4x4.Bands[0][1] := 0;
          e.DctParamsAfv4x4.Bands[0][2] := 0;    e.DctParamsAfv4x4.Bands[0][3] := 0;
          e.DctParamsAfv4x4.Bands[1][0] := 392;  e.DctParamsAfv4x4.Bands[1][1] := 0;
          e.DctParamsAfv4x4.Bands[1][2] := 0;    e.DctParamsAfv4x4.Bands[1][3] := 0;
          e.DctParamsAfv4x4.Bands[2][0] := 112;  e.DctParamsAfv4x4.Bands[2][1] := -0.25;
          e.DctParamsAfv4x4.Bands[2][2] := -0.25; e.DctParamsAfv4x4.Bands[2][3] := -0.5;
          for c := 0 to 26 do e.AfvWeights[c div 9][c mod 9] := kAfv[c];
        end;
    11: SetDct(e, QM_DCT, 8, [0.9 * 26629.073922049845, -1.025, -0.78, -0.65012,
          -0.19041574084286472, -0.20819395464, -0.421064, -0.32733845535848671,
          0.9 * 9311.3238710010046, -0.3041958212306401, -0.3633036457487539,
          -0.35660379990111464, -0.3443074455424403, -0.33699592683512467,
          -0.30180866526242109, -0.27321683125358037,
          0.9 * 4992.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5]);
    12: SetDct(e, QM_DCT, 8, [0.65 * 23629.073922049845, -1.025, -0.78, -0.65012,
          -0.19041574084286472, -0.20819395464, -0.421064, -0.32733845535848671,
          0.65 * 8611.3238710010046, -0.3041958212306401, -0.3633036457487539,
          -0.35660379990111464, -0.3443074455424403, -0.33699592683512467,
          -0.30180866526242109, -0.27321683125358037,
          0.65 * 4492.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5]);
    13: SetDct(e, QM_DCT, 8, [1.8 * 26629.073922049845, -1.025, -0.78, -0.65012,
          -0.19041574084286472, -0.20819395464, -0.421064, -0.32733845535848671,
          1.8 * 9311.3238710010046, -0.3041958212306401, -0.3633036457487539,
          -0.35660379990111464, -0.3443074455424403, -0.33699592683512467,
          -0.30180866526242109, -0.27321683125358037,
          1.8 * 4992.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5]);
    14: SetDct(e, QM_DCT, 8, [1.3 * 23629.073922049845, -1.025, -0.78, -0.65012,
          -0.19041574084286472, -0.20819395464, -0.421064, -0.32733845535848671,
          1.3 * 8611.3238710010046, -0.3041958212306401, -0.3633036457487539,
          -0.35660379990111464, -0.3443074455424403, -0.33699592683512467,
          -0.30180866526242109, -0.27321683125358037,
          1.3 * 4492.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5]);
    15: SetDct(e, QM_DCT, 8, [3.6 * 26629.073922049845, -1.025, -0.78, -0.65012,
          -0.19041574084286472, -0.20819395464, -0.421064, -0.32733845535848671,
          3.6 * 9311.3238710010046, -0.3041958212306401, -0.3633036457487539,
          -0.35660379990111464, -0.3443074455424403, -0.33699592683512467,
          -0.30180866526242109, -0.27321683125358037,
          3.6 * 4992.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5]);
    16: SetDct(e, QM_DCT, 8, [2.6 * 23629.073922049845, -1.025, -0.78, -0.65012,
          -0.19041574084286472, -0.20819395464, -0.421064, -0.32733845535848671,
          2.6 * 8611.3238710010046, -0.3041958212306401, -0.3633036457487539,
          -0.35660379990111464, -0.3443074455424403, -0.33699592683512467,
          -0.30180866526242109, -0.27321683125358037,
          2.6 * 4492.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5]);
  end;
end;

// ---------------------------------------------------------------------------
// ComputeQuantTable
// ---------------------------------------------------------------------------
procedure ComputeQuantTable(const e: TQuantEncoding; kind: Integer;
                            var table: array of Single);
const
  kFreqs: array[0..15] of Single = (0, 0, 0.8517778890324296, 5.37778436506804,
    0, 0, 4.734747904497923, 5.449245381693219, 1.6598270267479331, 4,
    7.275749096817861, 10.423227632456525, 2.662932286148962, 7.630657783650829,
    8.962388608184032, 12.97166202570235);
  lo = 0.8517778890324296;
var
  wrows, wcols, num, c, x, y, i, start: Integer;
  w: array of Single;
  w4x4: array[0..47] of Single;
  w4x8: array[0..95] of Single;
  bands: array[0..3] of Single;
  hi, v: Single;
begin
  wrows := 8 * kQTRequiredX[kind];
  wcols := 8 * kQTRequiredY[kind];
  num := wrows * wcols;
  SetLength(w, 3 * num);
  case e.Mode of
    QM_ID:
      for c := 0 to 2 do
      begin
        for i := 0 to 63 do w[64 * c + i] := e.IdWeights[c][0];
        w[64 * c + 1] := e.IdWeights[c][1];
        w[64 * c + 8] := e.IdWeights[c][1];
        w[64 * c + 9] := e.IdWeights[c][2];
      end;
    QM_DCT2:
      for c := 0 to 2 do
      begin
        start := c * 64;
        w[start] := $BAD;
        w[start + 1] := e.Dct2Weights[c][0];
        w[start + 8] := e.Dct2Weights[c][0];
        w[start + 9] := e.Dct2Weights[c][1];
        for y := 0 to 1 do
          for x := 0 to 1 do
          begin
            w[start + y * 8 + x + 2] := e.Dct2Weights[c][2];
            w[start + (y + 2) * 8 + x] := e.Dct2Weights[c][2];
          end;
        for y := 0 to 1 do
          for x := 0 to 1 do
            w[start + (y + 2) * 8 + x + 2] := e.Dct2Weights[c][3];
        for y := 0 to 3 do
          for x := 0 to 3 do
          begin
            w[start + y * 8 + x + 4] := e.Dct2Weights[c][4];
            w[start + (y + 4) * 8 + x] := e.Dct2Weights[c][4];
          end;
        for y := 0 to 3 do
          for x := 0 to 3 do
            w[start + (y + 4) * 8 + x + 4] := e.Dct2Weights[c][5];
      end;
    QM_DCT4:
      begin
        GetQuantWeights(4, 4, e.DctParams, @w4x4[0]);
        for c := 0 to 2 do
        begin
          for y := 0 to 7 do
            for x := 0 to 7 do
              w[c * num + y * 8 + x] := w4x4[c * 16 + (y div 2) * 4 + (x div 2)];
          w[c * num + 1] := w[c * num + 1] / e.Dct4Mul[c][0];
          w[c * num + 8] := w[c * num + 8] / e.Dct4Mul[c][0];
          w[c * num + 9] := w[c * num + 9] / e.Dct4Mul[c][1];
        end;
      end;
    QM_DCT4X8:
      begin
        GetQuantWeights(4, 8, e.DctParams, @w4x8[0]);
        for c := 0 to 2 do
        begin
          for y := 0 to 7 do
            for x := 0 to 7 do
              w[c * num + y * 8 + x] := w4x8[c * 32 + (y div 2) * 8 + x];
          w[c * num + 8] := w[c * num + 8] / e.Dct4x8Mul[c];
        end;
      end;
    QM_DCT:
      GetQuantWeights(wrows, wcols, e.DctParams, @w[0]);
    QM_RAW:
      begin
        if Length(e.RawTable) <> 3 * num then
          raise EJxlError.Create('Invalid raw quantization table');
        for i := 0 to 3 * num - 1 do
          w[i] := 1.0 / (e.RawDen * e.RawTable[i]);
      end;
    QM_AFV:
      begin
        GetQuantWeights(4, 8, e.DctParams, @w4x8[0]);
        GetQuantWeights(4, 4, e.DctParamsAfv4x4, @w4x4[0]);
        hi := 12.97166202570235 - lo + 1e-6;
        for c := 0 to 2 do
        begin
          bands[0] := e.AfvWeights[c][5];
          if bands[0] < kAlmostZero then raise EJxlError.Create('Invalid AFV bands');
          for i := 1 to 3 do
          begin
            bands[i] := bands[i - 1] * Mult(e.AfvWeights[c][i + 5]);
            if bands[i] < kAlmostZero then raise EJxlError.Create('Invalid AFV bands');
          end;
          start := c * 64;
          w[start] := 1;
          w[start + 1 * 8 + 0] := e.AfvWeights[c][0];   // (x=0, y=1)
          w[start + 0 * 8 + 1] := e.AfvWeights[c][1];   // (x=1, y=0)
          w[start + 2 * 8 + 0] := e.AfvWeights[c][2];   // (0, 2)
          w[start + 0 * 8 + 2] := e.AfvWeights[c][3];   // (2, 0)
          w[start + 2 * 8 + 2] := e.AfvWeights[c][4];   // (2, 2)
          for y := 0 to 3 do
            for x := 0 to 3 do
            begin
              if (x < 2) and (y < 2) then Continue;
              v := Interpolate(kFreqs[y * 4 + x] - lo, hi, bands, 4);
              w[start + (2 * y) * 8 + 2 * x] := v;
            end;
          for y := 0 to 3 do
            for x := 0 to 7 do
            begin
              if (x = 0) and (y = 0) then Continue;
              w[c * num + (2 * y + 1) * 8 + x] := w4x8[c * 32 + y * 8 + x];
            end;
          for y := 0 to 3 do
            for x := 0 to 3 do
            begin
              if (x = 0) and (y = 0) then Continue;
              w[c * num + (2 * y) * 8 + 2 * x + 1] := w4x4[c * 16 + y * 4 + x];
            end;
        end;
      end;
  end;
  for i := 0 to 3 * num - 1 do
  begin
    if (w[i] >= 1.0 / kAlmostZero) or (w[i] < kAlmostZero) then
      raise EJxlError.Create('Invalid quantization table');
    table[i] := 1.0 / w[i];
  end;
end;

// ---------------------------------------------------------------------------
constructor TDequantMatrices.Create;
var i: Integer;
begin
  inherited Create;
  for i := 0 to 2 do
  begin
    DCQuant[i] := kDefaultDCQuant[i];
    InvDCQuant[i] := 1.0 / kDefaultDCQuant[i];
  end;
  for i := 0 to kNumQuantTables - 1 do
  begin
    FEnc[i].Mode := QM_LIBRARY;
    SetLength(FEnc[i].RawTable, 0);
  end;
  FComputedMask := 0;
end;

procedure TDequantMatrices.DecodeDC(br: TBitReader);
var c: Integer;
begin
  if br.ReadBit then Exit;   // all default
  for c := 0 to 2 do
  begin
    DCQuant[c] := br.ReadF16 * (1.0 / 128.0);
    if DCQuant[c] < kAlmostZero then
      raise EJxlError.Create('Invalid dc_quant');
    InvDCQuant[c] := 1.0 / DCQuant[c];
  end;
end;

procedure DecodeDctParams(br: TBitReader; var p: TDctParams);
var c, i: Integer;
begin
  p.NumBands := Integer(br.ReadBits(4)) + 1;
  for c := 0 to 2 do
  begin
    for i := 0 to p.NumBands - 1 do
      p.Bands[c][i] := br.ReadF16;
    if p.Bands[c][0] < kAlmostZero then
      raise EJxlError.Create('Distance band seed is too small');
    p.Bands[c][0] := p.Bands[c][0] * 64.0;
  end;
end;

procedure TDequantMatrices.Decode(br: TBitReader; rawReader: TRawQuantTableReader);
var
  i, c, j, mode, reqSize, sx, sy: Integer;
begin
  for i := 0 to kNumQuantTables - 1 do FEnc[i].Mode := QM_LIBRARY;
  FComputedMask := 0;
  if br.ReadBit then Exit;   // all default
  for i := 0 to kNumQuantTables - 1 do
  begin
    reqSize := kQTRequiredX[i] * kQTRequiredY[i];
    mode := br.ReadBits(3);
    case mode of
      QM_LIBRARY: ;   // predefined: kCeilLog2NumPredefinedTables = 0 bits
      QM_ID:
        begin
          if reqSize <> 1 then raise EJxlError.Create('Invalid quant mode');
          for c := 0 to 2 do
            for j := 0 to 2 do
            begin
              FEnc[i].IdWeights[c][j] := br.ReadF16;
              if Abs(FEnc[i].IdWeights[c][j]) < kAlmostZero then
                raise EJxlError.Create('ID quantizer is too small');
              FEnc[i].IdWeights[c][j] := FEnc[i].IdWeights[c][j] * 64;
            end;
        end;
      QM_DCT2:
        begin
          if reqSize <> 1 then raise EJxlError.Create('Invalid quant mode');
          for c := 0 to 2 do
            for j := 0 to 5 do
            begin
              FEnc[i].Dct2Weights[c][j] := br.ReadF16;
              if Abs(FEnc[i].Dct2Weights[c][j]) < kAlmostZero then
                raise EJxlError.Create('Quantizer is too small');
              FEnc[i].Dct2Weights[c][j] := FEnc[i].Dct2Weights[c][j] * 64;
            end;
        end;
      QM_DCT4X8:
        begin
          if reqSize <> 1 then raise EJxlError.Create('Invalid quant mode');
          for c := 0 to 2 do
          begin
            FEnc[i].Dct4x8Mul[c] := br.ReadF16;
            if Abs(FEnc[i].Dct4x8Mul[c]) < kAlmostZero then
              raise EJxlError.Create('DCT4X8 multiplier is too small');
          end;
          DecodeDctParams(br, FEnc[i].DctParams);
        end;
      QM_DCT4:
        begin
          if reqSize <> 1 then raise EJxlError.Create('Invalid quant mode');
          for c := 0 to 2 do
            for j := 0 to 1 do
            begin
              FEnc[i].Dct4Mul[c][j] := br.ReadF16;
              if Abs(FEnc[i].Dct4Mul[c][j]) < kAlmostZero then
                raise EJxlError.Create('DCT4 multiplier is too small');
            end;
          DecodeDctParams(br, FEnc[i].DctParams);
        end;
      QM_AFV:
        begin
          if reqSize <> 1 then raise EJxlError.Create('Invalid quant mode');
          for c := 0 to 2 do
          begin
            for j := 0 to 8 do FEnc[i].AfvWeights[c][j] := br.ReadF16;
            for j := 0 to 5 do FEnc[i].AfvWeights[c][j] := FEnc[i].AfvWeights[c][j] * 64;
          end;
          DecodeDctParams(br, FEnc[i].DctParams);
          DecodeDctParams(br, FEnc[i].DctParamsAfv4x4);
        end;
      QM_DCT:
        DecodeDctParams(br, FEnc[i].DctParams);
      QM_RAW:
        begin
          FEnc[i].RawDen := br.ReadF16;
          if FEnc[i].RawDen < kAlmostZero then
            raise EJxlError.Create('Invalid qtable_den');
          sx := 8 * kQTRequiredX[i];
          sy := 8 * kQTRequiredY[i];
          SetLength(FEnc[i].RawTable, 3 * sx * sy);
          if not Assigned(rawReader) then
            raise EJxlError.Create('Raw quantization table without modular decoder');
          rawReader(br, i, sx, sy, FEnc[i].RawTable);
          for j := 0 to High(FEnc[i].RawTable) do
            if FEnc[i].RawTable[j] <= 0 then
              raise EJxlError.Create('Invalid raw quantization table');
        end;
    else
      raise EJxlError.Create('Invalid quantization table encoding');
    end;
    FEnc[i].Mode := mode;
  end;
end;

procedure TDequantMatrices.EnsureComputed(acsMask: Cardinal);
var
  s, kind, num: Integer;
  kindMask: Cardinal;
  lib: TQuantEncoding;
begin
  kindMask := 0;
  for s := 0 to kNumAcStrategies - 1 do
    if (acsMask and (Cardinal(1) shl s)) <> 0 then
      kindMask := kindMask or (Cardinal(1) shl kAcsToQuantTable[s]);
  for kind := 0 to kNumQuantTables - 1 do
  begin
    if (kindMask and (Cardinal(1) shl kind)) = 0 then Continue;
    if (FComputedMask and (Cardinal(1) shl kind)) <> 0 then Continue;
    num := 64 * kQTRequiredX[kind] * kQTRequiredY[kind];
    SetLength(Tables[kind], 3 * num);
    if FEnc[kind].Mode = QM_LIBRARY then
    begin
      LibraryEncoding(kind, lib);
      ComputeQuantTable(lib, kind, Tables[kind]);
    end
    else
      ComputeQuantTable(FEnc[kind], kind, Tables[kind]);
    FComputedMask := FComputedMask or (Cardinal(1) shl kind);
  end;
end;

function TDequantMatrices.Matrix(strategy: Integer): PSingle;
begin
  Result := @Tables[kAcsToQuantTable[strategy]][0];
end;

function TDequantMatrices.IsRawJpeg: Boolean;
begin
  Result := (FEnc[0].Mode = QM_RAW) and (Abs(FEnc[0].RawDen - 1.0 / (8 * 255)) <= 1e-8);
end;

end.
