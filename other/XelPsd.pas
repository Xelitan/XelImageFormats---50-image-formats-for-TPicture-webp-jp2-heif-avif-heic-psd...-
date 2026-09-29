unit XelPsd;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}
//PSD encoder/decoder
//Author: Xelitan.com
//License: MIT

interface

uses
  SysUtils, Classes, XelPng;

type
  EPsdError = class(Exception);

  TPsdCompression = (
    psdRaw,
    psdRLE
  );

// Decodes the flattened (composite) image of a PSD (8BPS v1) to RGBA8. Modes: Bitmap,
// Grayscale, Indexed, RGB, CMYK, Multichannel, Duotone (as grayscale), Lab; 1/8/16-bit;
// raw and PackBits RLE compression. Layers are ignored.
function DecodePsd(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8

// Writes a flattened PSD, 8 bits/channel. InBuf = RGBA8. Optional Compression
// (default psdRLE) and WriteAlpha (default True = 4th channel).
function EncodePsd(InBuf: TBytes; Width, Height: Integer;
  Compression: TPsdCompression = psdRLE;
  WriteAlpha: Boolean = True): TBytes;                                    // InBuf = RGBA8

// Number of layers in the PSD file (0 when there is no layer section).
function PsdLayerCount(InBuf: TBytes): Integer;

// Decodes a single layer (0-based) to RGBA8. Width/Height is the size of the
// layer rectangle (may be smaller than the canvas). Color channels by their ID
// (0..n-1) are converted according to the file's color mode (RGB/CMYK/Lab/...),
// alpha = ID -1; missing alpha = 255, an RGB layer with only channel 0 is
// replicated to R,G,B.
function DecodePsdLayer(InBuf: TBytes; LayerIndex: Integer;
  out Width, Height: Integer): TBytes;                                    // RGBA8

implementation

const
  PSD_MODE_BITMAP    = 0;
  PSD_MODE_GRAYSCALE = 1;
  PSD_MODE_INDEXED   = 2;
  PSD_MODE_RGB       = 3;
  PSD_MODE_CMYK      = 4;
  PSD_MODE_MULTICHANNEL = 7;
  PSD_MODE_DUOTONE   = 8;
  PSD_MODE_LAB       = 9;

type
  TBytePlane = TBytes;
  TPlaneArray = array of TBytePlane;
  TRGBPalette = array[0..255] of TRGBA;

procedure Need(const Data: TBytes; Pos, Count: NativeUInt); inline;
begin
  if (Pos > NativeUInt(Length(Data))) or
     (Count > NativeUInt(Length(Data)) - Pos) then
    raise EPsdError.Create('PSD: unexpected end of file');
end;

function ReadBE16(const Data: TBytes; var Pos: NativeUInt): Word; inline;
begin
  Need(Data, Pos, 2);
  Result := (Word(Data[Pos]) shl 8) or Word(Data[Pos + 1]);
  Inc(Pos, 2);
end;

function ReadBE32(const Data: TBytes; var Pos: NativeUInt): Cardinal; inline;
begin
  Need(Data, Pos, 4);
  Result := (Cardinal(Data[Pos]) shl 24) or
            (Cardinal(Data[Pos + 1]) shl 16) or
            (Cardinal(Data[Pos + 2]) shl 8) or
             Cardinal(Data[Pos + 3]);
  Inc(Pos, 4);
end;

procedure PutBE16(var D: TBytes; Pos: NativeUInt; V: Word); inline;
begin
  D[Pos] := Byte(V shr 8);
  D[Pos + 1] := Byte(V);
end;

procedure PutBE32(var D: TBytes; Pos: NativeUInt; V: Cardinal); inline;
begin
  D[Pos] := Byte(V shr 24);
  D[Pos + 1] := Byte(V shr 16);
  D[Pos + 2] := Byte(V shr 8);
  D[Pos + 3] := Byte(V);
end;

procedure AppendByte(var D: TBytes; B: Byte); inline;
var
  N: NativeUInt;
begin
  N := Length(D);
  SetLength(D, N + 1);
  D[N] := B;
end;

procedure AppendData(var D: TBytes; const S: TBytes);
var
  N, M: NativeUInt;
begin
  M := Length(S);
  if M = 0 then Exit;
  N := Length(D);
  SetLength(D, N + M);
  Move(S[0], D[N], M);
end;

procedure SkipSection(const Data: TBytes; var Pos: NativeUInt);
var
  N: Cardinal;
begin
  N := ReadBE32(Data, Pos);
  Need(Data, Pos, N);
  Inc(Pos, N);
end;

function RowBytesForDepth(W: Cardinal; Depth: Word): NativeUInt;
begin
  case Depth of
    1: Result := (NativeUInt(W) + 7) div 8;
    8: Result := W;
    16: Result := NativeUInt(W) * 2;
  else
    raise EPsdError.CreateFmt('PSD: unsupported channel depth %d', [Depth]);
  end;
end;

procedure InitBitmap(var Buf: TBytes; W, H: Cardinal);
begin
  SetLength(Buf, NativeInt(W) * NativeInt(H) * 4);
end;

function PackBitsDecodeRow(const Data: TBytes; var Pos: NativeUInt;
  PackedLen, Expected: NativeUInt): TBytes;
var
  EndPos, OutPos, N, Count: NativeUInt;
  S: ShortInt;
  B: Byte;
begin
  SetLength(Result, Expected);
  Need(Data, Pos, PackedLen);
  EndPos := Pos + PackedLen;
  OutPos := 0;

  while Pos < EndPos do
  begin
    S := ShortInt(Data[Pos]);
    Inc(Pos);

    if S >= 0 then
    begin
      Count := NativeUInt(Integer(S) + 1);
      if Count > EndPos - Pos then
        raise EPsdError.Create('PSD: malformed PackBits literal run');
      if Count > Expected - OutPos then
        raise EPsdError.Create('PSD: PackBits row is too long');
      if Count <> 0 then
      begin
        Move(Data[Pos], Result[OutPos], Count);
        Inc(Pos, Count);
        Inc(OutPos, Count);
      end;
    end
    else if S <> -128 then
    begin
      Count := NativeUInt(1 - Integer(S));
      if Pos >= EndPos then
        raise EPsdError.Create('PSD: malformed PackBits repeat run');
      if Count > Expected - OutPos then
        raise EPsdError.Create('PSD: PackBits row is too long');
      B := Data[Pos];
      Inc(Pos);
      N := 0;
      while N < Count do
      begin
        Result[OutPos] := B;
        Inc(OutPos);
        Inc(N);
      end;
    end;
  end;

  if OutPos <> Expected then
    raise EPsdError.CreateFmt('PSD: PackBits row decoded to %d bytes, expected %d',
      [OutPos, Expected]);
end;

function PackBitsEncodeRow(P: PByte; Count: NativeUInt): TBytes;
var
  I, Run, LitStart, LitLen, J: NativeUInt;
begin
  SetLength(Result, 0);
  I := 0;

  while I < Count do
  begin
    Run := 1;
    while (I + Run < Count) and (Run < 128) and
          (P[I + Run] = P[I]) do
      Inc(Run);

    if Run >= 3 then
    begin
      AppendByte(Result, Byte(257 - Run));
      AppendByte(Result, P[I]);
      Inc(I, Run);
    end
    else
    begin
      LitStart := I;
      LitLen := 0;
      while I < Count do
      begin
        Run := 1;
        while (I + Run < Count) and (Run < 128) and
              (P[I + Run] = P[I]) do
          Inc(Run);
        if (Run >= 3) or (LitLen >= 128) then Break;
        Inc(I);
        Inc(LitLen);
      end;

      if LitLen = 0 then
      begin
        LitLen := Run;
        if LitLen > 2 then LitLen := 2;
        Inc(I, LitLen);
      end;

      AppendByte(Result, Byte(LitLen - 1));
      J := 0;
      while J < LitLen do
      begin
        AppendByte(Result, P[LitStart + J]);
        Inc(J);
      end;
    end;
  end;
end;

procedure NormalizeRowToPlane(const Row: TBytes; Depth: Word; W: Cardinal;
  var Plane: TBytes; DestOffset: NativeUInt; BitmapMode: Boolean);
var
  X: NativeUInt;
  V: Word;
  Bit: Byte;
begin
  X := 0;
  case Depth of
    1:
      begin
        while X < W do
        begin
          Bit := (Row[X shr 3] shr (7 - (X and 7))) and 1;
          if BitmapMode then
          begin
            if Bit <> 0 then Plane[DestOffset + X] := 0
            else Plane[DestOffset + X] := 255;
          end
          else
          begin
            if Bit <> 0 then Plane[DestOffset + X] := 255
            else Plane[DestOffset + X] := 0;
          end;
          Inc(X);
        end;
      end;
    8:
      begin
        if W <> 0 then Move(Row[0], Plane[DestOffset], W);
      end;
    16:
      begin
        while X < W do
        begin
          V := (Word(Row[X * 2]) shl 8) or Word(Row[X * 2 + 1]);
          Plane[DestOffset + X] := Byte((Cardinal(V) * 255 + 32767) div 65535);
          Inc(X);
        end;
      end;
  end;
end;

procedure DecodeCompositePlanes(const Data: TBytes; var Pos: NativeUInt;
  Channels: Word; W, H: Cardinal; Depth: Word; ColorMode: Word;
  var Planes: TPlaneArray);
var
  Compression: Word;
  RowBytes, PlaneBytes, C, Y, Idx, TableCount: NativeUInt;
  RowLens: array of Word;
  Row: TBytes;
  PackedLen: NativeUInt;
begin
  Compression := ReadBE16(Data, Pos);
  if (Compression <> 0) and (Compression <> 1) then
    raise EPsdError.CreateFmt('PSD: image compression %d is not supported (only raw/RLE)',
      [Compression]);

  RowBytes := RowBytesForDepth(W, Depth);
  PlaneBytes := NativeUInt(W) * NativeUInt(H);
  SetLength(Planes, Channels);
  C := 0;
  while C < Channels do
  begin
    SetLength(Planes[C], PlaneBytes);
    Inc(C);
  end;

  if Compression = 0 then
  begin
    C := 0;
    while C < Channels do
    begin
      Y := 0;
      while Y < H do
      begin
        Need(Data, Pos, RowBytes);
        SetLength(Row, RowBytes);
        if RowBytes <> 0 then Move(Data[Pos], Row[0], RowBytes);
        Inc(Pos, RowBytes);
        NormalizeRowToPlane(Row, Depth, W, Planes[C], Y * W,
          ColorMode = PSD_MODE_BITMAP);
        Inc(Y);
      end;
      Inc(C);
    end;
  end
  else
  begin
    TableCount := NativeUInt(Channels) * NativeUInt(H);
    SetLength(RowLens, TableCount);
    Idx := 0;
    while Idx < TableCount do
    begin
      RowLens[Idx] := ReadBE16(Data, Pos);
      Inc(Idx);
    end;

    C := 0;
    Idx := 0;
    while C < Channels do
    begin
      Y := 0;
      while Y < H do
      begin
        PackedLen := RowLens[Idx];
        Inc(Idx);
        Row := PackBitsDecodeRow(Data, Pos, PackedLen, RowBytes);
        NormalizeRowToPlane(Row, Depth, W, Planes[C], Y * W,
          ColorMode = PSD_MODE_BITMAP);
        Inc(Y);
      end;
      Inc(C);
    end;
  end;
end;

function ClampByte(V: Integer): Byte; inline;
begin
  if V < 0 then Result := 0
  else if V > 255 then Result := 255
  else Result := Byte(V);
end;

// Number of color channels (excluding alpha) for the given mode. Multichannel has
// no alpha - all channels are (spot) inks.
function ColorChannelCount(ColorMode: Word; Channels: Integer): Integer;
begin
  case ColorMode of
    PSD_MODE_RGB,
    PSD_MODE_LAB:          Result := 3;
    PSD_MODE_CMYK:         Result := 4;
    PSD_MODE_MULTICHANNEL: Result := Channels;
  else
    Result := 1;           // Bitmap, Grayscale, Indexed, Duotone
  end;
end;

// ------------------------------- Lab -> sRGB -------------------------------

var
  SrgbGammaLut: array[0..4095] of Byte;   // linear 0..1 (x4095) -> sRGB 8-bit

procedure InitSrgbGammaLut;
var
  I: Integer;
  V: Double;
begin
  for I := 0 to 4095 do
  begin
    V := I / 4095;
    if V <= 0.0031308 then V := V * 12.92
    else V := 1.055 * Exp(Ln(V) / 2.4) - 0.055;
    SrgbGammaLut[I] := ClampByte(Round(V * 255));
  end;
end;

function LabFInv(T: Double): Double; inline;
begin
  if T > 6 / 29 then Result := T * T * T
  else Result := (T - 4 / 29) * (108 / 841);   // 3 * (6/29)^2
end;

function LinearToSrgb(V: Double): Byte; inline;
begin
  if V <= 0 then Result := SrgbGammaLut[0]
  else if V >= 1 then Result := SrgbGammaLut[4095]
  else Result := SrgbGammaLut[Round(V * 4095)];
end;

// Photoshop Lab (D50): L 0..255 -> 0..100, a/b 0..255 with 128 = 0.
// Lab -> XYZ(D50) -> linear sRGB (matrix incl. Bradford adaptation D50->D65) -> gamma.
procedure LabToRGB(L8, A8, B8: Byte; var Px: TRGBA);
var
  L, Fx, Fy, Fz, X, Y, Z: Double;
begin
  L := L8 * (100 / 255);
  Fy := (L + 16) / 116;
  Fx := Fy + (Integer(A8) - 128) / 500;
  Fz := Fy - (Integer(B8) - 128) / 200;
  X := 0.96422 * LabFInv(Fx);
  Y := LabFInv(Fy);
  Z := 0.82521 * LabFInv(Fz);
  Px.R := LinearToSrgb( 3.1338561 * X - 1.6168667 * Y - 0.4906146 * Z);
  Px.G := LinearToSrgb(-0.9787684 * X + 1.9161415 * Y + 0.0334540 * Z);
  Px.B := LinearToSrgb( 0.0719453 * X - 0.2289914 * Y + 1.4052427 * Z);
end;

// Photoshop stores CMYK/Multichannel channels inverted:
// 255 = 0% ink, 0 = 100% ink.
procedure CMYKToRGB(C0, C1, C2, C3: Byte; var Px: TRGBA); inline;
var
  K: Integer;
begin
  K := 255 - C3;
  Px.R := ClampByte(C0 - K);   // = 255 - C - K
  Px.G := ClampByte(C1 - K);
  Px.B := ClampByte(C2 - K);
end;

// Color = color channel planes (ColorChannelCount), Alpha = optional alpha
// plane (empty = opaque).
procedure PlanesToBitmap(const Color: TPlaneArray; const Alpha: TBytes;
  W, H: Cardinal; ColorMode: Word; const Palette: TRGBPalette;
  PaletteValid: Boolean; var Buf: TBytes);
var
  X, Y, P: NativeUInt;
  NC: Integer;
  G: Byte;
  HasAlpha: Boolean;
  Px: TRGBA;
begin
  NC := Length(Color);
  case ColorMode of
    PSD_MODE_BITMAP, PSD_MODE_GRAYSCALE, PSD_MODE_DUOTONE:
      if NC < 1 then raise EPsdError.Create('PSD: grayscale image has no channel');
    PSD_MODE_INDEXED:
      begin
        if not PaletteValid then raise EPsdError.Create('PSD: indexed image has no palette');
        if NC < 1 then raise EPsdError.Create('PSD: indexed image has no channel');
      end;
    PSD_MODE_RGB:
      if NC < 3 then raise EPsdError.Create('PSD: RGB image has fewer than 3 channels');
    PSD_MODE_CMYK:
      if NC < 4 then raise EPsdError.Create('PSD: CMYK image has fewer than 4 channels');
    PSD_MODE_LAB:
      if NC < 3 then raise EPsdError.Create('PSD: Lab image has fewer than 3 channels');
    PSD_MODE_MULTICHANNEL:
      if NC < 1 then raise EPsdError.Create('PSD: multichannel image has no channel');
  else
    raise EPsdError.CreateFmt('PSD: unsupported color mode %d', [ColorMode]);
  end;
  HasAlpha := NativeUInt(Length(Alpha)) >= NativeUInt(W) * NativeUInt(H);

  InitBitmap(Buf, W, H);
  Y := 0;
  P := 0;
  while Y < H do
  begin
    X := 0;
    while X < W do
    begin
      case ColorMode of
        PSD_MODE_BITMAP,
        PSD_MODE_GRAYSCALE,
        PSD_MODE_DUOTONE:     // duotone: ink specification is undocumented -> grayscale
          begin
            G := Color[0][P];
            Px.R := G; Px.G := G; Px.B := G;
          end;

        PSD_MODE_INDEXED:
          Px := Palette[Color[0][P]];

        PSD_MODE_RGB:
          begin
            Px.R := Color[0][P];
            Px.G := Color[1][P];
            Px.B := Color[2][P];
          end;

        PSD_MODE_CMYK:
          CMYKToRGB(Color[0][P], Color[1][P], Color[2][P], Color[3][P], Px);

        PSD_MODE_LAB:
          LabToRGB(Color[0][P], Color[1][P], Color[2][P], Px);

        PSD_MODE_MULTICHANNEL:
          case NC of
            1: begin   // single ink -> grayscale
                 G := Color[0][P];
                 Px.R := G; Px.G := G; Px.B := G;
               end;
            2: begin   // two overprinted inks -> product
                 G := Byte((Cardinal(Color[0][P]) * Color[1][P] + 127) div 255);
                 Px.R := G; Px.G := G; Px.B := G;
               end;
            3: begin   // C, M, Y (e.g. after conversion from RGB)
                 Px.R := Color[0][P];
                 Px.G := Color[1][P];
                 Px.B := Color[2][P];
               end;
          else         // C, M, Y, K (+ extra spot inks ignored)
            CMYKToRGB(Color[0][P], Color[1][P], Color[2][P], Color[3][P], Px);
          end;
      end;

      if HasAlpha then Px.A := Alpha[P] else Px.A := 255;
      SetPx(Buf, Integer(W), Integer(X), Integer(Y), Px);
      Inc(P);
      Inc(X);
    end;
    Inc(Y);
  end;
end;

type
  TPsdHeader = record
    Channels, Depth, ColorMode: Word;
    W, H: Cardinal;
    Palette: TRGBPalette;
    PaletteValid: Boolean;
  end;

// Reads and validates the header (26 B) and the Color Mode Data section (palette
// for Indexed). On return Pos points at the Image Resources section.
procedure ReadPsdHeader(const Data: TBytes; var Pos: NativeUInt; out Hdr: TPsdHeader);
var
  Version: Word;
  ColorLen: Cardinal;
  I: NativeUInt;
begin
  Pos := 0;
  Need(Data, Pos, 26);
  if (Data[0] <> Ord('8')) or (Data[1] <> Ord('B')) or
     (Data[2] <> Ord('P')) or (Data[3] <> Ord('S')) then
    raise EPsdError.Create('PSD: invalid signature');
  Pos := 4;

  Version := ReadBE16(Data, Pos);
  if Version <> 1 then
    raise EPsdError.CreateFmt('PSD: unsupported version %d (PSB is not supported)', [Version]);

  Need(Data, Pos, 6);
  Inc(Pos, 6);
  Hdr.Channels := ReadBE16(Data, Pos);
  Hdr.H := ReadBE32(Data, Pos);
  Hdr.W := ReadBE32(Data, Pos);
  Hdr.Depth := ReadBE16(Data, Pos);
  Hdr.ColorMode := ReadBE16(Data, Pos);

  if (Hdr.Channels = 0) or (Hdr.Channels > 56) then
    raise EPsdError.CreateFmt('PSD: invalid channel count %d', [Hdr.Channels]);
  if (Hdr.W = 0) or (Hdr.H = 0) then
    raise EPsdError.Create('PSD: invalid image size');
  if (Hdr.Depth <> 1) and (Hdr.Depth <> 8) and (Hdr.Depth <> 16) then
    raise EPsdError.CreateFmt('PSD: unsupported depth %d', [Hdr.Depth]);
  case Hdr.ColorMode of
    PSD_MODE_BITMAP:
      if Hdr.Depth <> 1 then
        raise EPsdError.Create('PSD: Bitmap mode must use 1-bit depth');
    PSD_MODE_INDEXED:
      if Hdr.Depth <> 8 then
        raise EPsdError.Create('PSD: Indexed mode must use 8-bit depth');
    PSD_MODE_GRAYSCALE, PSD_MODE_RGB, PSD_MODE_CMYK:
      ;
    PSD_MODE_MULTICHANNEL, PSD_MODE_DUOTONE, PSD_MODE_LAB:
      if Hdr.Depth = 1 then
        raise EPsdError.CreateFmt('PSD: color mode %d cannot use 1-bit depth',
          [Hdr.ColorMode]);
  else
    raise EPsdError.CreateFmt('PSD: unsupported color mode %d', [Hdr.ColorMode]);
  end;

  Hdr.PaletteValid := False;
  I := 0;
  while I < 256 do
  begin
    Hdr.Palette[I].R := 0; Hdr.Palette[I].G := 0; Hdr.Palette[I].B := 0;
    Hdr.Palette[I].A := 255;
    Inc(I);
  end;

  // Color Mode Data: palette (Indexed) or duotone specification (undocumented,
  // skipped - duotone is rendered as grayscale, as recommended by Adobe).
  ColorLen := ReadBE32(Data, Pos);
  Need(Data, Pos, ColorLen);
  if Hdr.ColorMode = PSD_MODE_INDEXED then
  begin
    if ColorLen < 768 then
      raise EPsdError.Create('PSD: indexed palette is shorter than 768 bytes');
    I := 0;
    while I < 256 do
    begin
      Hdr.Palette[I].R := Data[Pos + I];
      Hdr.Palette[I].G := Data[Pos + 256 + I];
      Hdr.Palette[I].B := Data[Pos + 512 + I];
      Hdr.Palette[I].A := 255;
      Inc(I);
    end;
    Hdr.PaletteValid := True;
  end;
  Inc(Pos, ColorLen);
end;

function DecodePsd(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Data: TBytes;
  Pos: NativeUInt;
  Hdr: TPsdHeader;
  Planes, Color: TPlaneArray;
  Alpha: TBytes;
  CC: Integer;
begin
  Data := InBuf;
  Width := 0;
  Height := 0;
  SetLength(Result, 0);

  ReadPsdHeader(Data, Pos, Hdr);
  // Image Resources
  SkipSection(Data, Pos);
  // Layer and Mask Information
  SkipSection(Data, Pos);

  DecodeCompositePlanes(Data, Pos, Hdr.Channels, Hdr.W, Hdr.H, Hdr.Depth,
    Hdr.ColorMode, Planes);

  // Color channels; the first channel after them (if any) is alpha.
  CC := ColorChannelCount(Hdr.ColorMode, Hdr.Channels);
  if CC > Hdr.Channels then CC := Hdr.Channels;   // PlanesToBitmap will raise an error
  Color := Copy(Planes, 0, CC);
  if Hdr.Channels > CC then Alpha := Planes[CC]
  else SetLength(Alpha, 0);

  PlanesToBitmap(Color, Alpha, Hdr.W, Hdr.H, Hdr.ColorMode, Hdr.Palette,
    Hdr.PaletteValid, Result);
  Width := Integer(Hdr.W);
  Height := Integer(Hdr.H);
end;

procedure BuildChannelRow(const Buf: TBytes; W: Integer; Channel: Integer; Y: NativeUInt;
  var Row: TBytes);
var
  X: NativeUInt;
  P: TRGBA;
begin
  SetLength(Row, W);
  X := 0;
  while Integer(X) < W do
  begin
    P := GetPx(Buf, W, Integer(X), Integer(Y));
    case Channel of
      0: Row[X] := P.R;
      1: Row[X] := P.G;
      2: Row[X] := P.B;
      3: Row[X] := P.A;
    else
      Row[X] := 0;
    end;
    Inc(X);
  end;
end;

function EncodePsd(InBuf: TBytes; Width, Height: Integer; Compression: TPsdCompression;
  WriteAlpha: Boolean): TBytes;
var
  Channels: Word;
  HeaderSize, C, Y, TablePos: NativeUInt;
  Row, PackedRow: TBytes;
  RowLens: array of Word;
  RowIndex: NativeUInt;
  Body: TBytes;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then
    raise EPsdError.Create('PSD: cannot encode an empty bitmap');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EPsdError.Create('PSD: RGBA8 buffer size does not match Width*Height*4');

  if WriteAlpha then Channels := 4 else Channels := 3;

  // 26-byte header + three zero-length sections + 2-byte image compression.
  HeaderSize := 26 + 4 + 4 + 4;
  SetLength(Result, HeaderSize);

  Result[0] := Ord('8'); Result[1] := Ord('B'); Result[2] := Ord('P'); Result[3] := Ord('S');
  PutBE16(Result, 4, 1);
  // bytes 6..11 reserved = zero
  PutBE16(Result, 12, Channels);
  PutBE32(Result, 14, Height);
  PutBE32(Result, 18, Width);
  PutBE16(Result, 22, 8);
  PutBE16(Result, 24, PSD_MODE_RGB);
  // color mode data length, image resources length, layer/mask length are zero

  SetLength(Body, 2);
  if Compression = psdRaw then PutBE16(Body, 0, 0)
  else PutBE16(Body, 0, 1);

  if Compression = psdRaw then
  begin
    C := 0;
    while C < Channels do
    begin
      Y := 0;
      while Y < Height do
      begin
        BuildChannelRow(InBuf, Width, Integer(C), Y, Row);
        AppendData(Body, Row);
        Inc(Y);
      end;
      Inc(C);
    end;
  end
  else
  begin
    SetLength(RowLens, NativeUInt(Channels) * Height);
    SetLength(Result, HeaderSize); // keep header only until table/body are complete
    SetLength(Body, 2 + NativeUInt(Channels) * Height * 2);
    PutBE16(Body, 0, 1);
    TablePos := 2;
    RowIndex := 0;

    C := 0;
    while C < Channels do
    begin
      Y := 0;
      while Y < Height do
      begin
        BuildChannelRow(InBuf, Width, Integer(C), Y, Row);
        if Length(Row) = 0 then SetLength(PackedRow, 0)
        else PackedRow := PackBitsEncodeRow(@Row[0], Length(Row));
        if Length(PackedRow) > 65535 then
          raise EPsdError.Create('PSD: one PackBits row exceeds 65535 bytes');
        RowLens[RowIndex] := Word(Length(PackedRow));
        PutBE16(Body, TablePos, RowLens[RowIndex]);
        Inc(TablePos, 2);
        Inc(RowIndex);
        AppendData(Body, PackedRow);
        Inc(Y);
      end;
      Inc(C);
    end;
  end;

  AppendData(Result, Body);
end;

// ================================= layers ==================================

type
  TPsdChannelInfo = record
    ID    : SmallInt;      // 0=R, 1=G, 2=B, -1=alpha, -2=user mask...
    Len   : Cardinal;      // channel data length (including the compression word)
    Offset: NativeUInt;    // absolute offset of the channel data in the buffer
  end;
  TPsdChannelArray = array of TPsdChannelInfo;

  TPsdLayerInfo = record
    Top, Left, Bottom, Right: Integer;
    Channels: TPsdChannelArray;
  end;
  TPsdLayerArray = array of TPsdLayerInfo;

// Walks the header + sections up to "Layer and Mask Information" and parses
// the layer records, computing the absolute data offset of every channel.
// Returns False (Layers empty) when the file contains no layers.
function ParseLayers(const Data: TBytes; out Hdr: TPsdHeader;
  out Layers: TPsdLayerArray): Boolean;
var
  Pos: NativeUInt;
  LMLen, LILen: Cardinal;
  LayerCount, nCh, li, ci: Integer;
  ExtraLen: Cardinal;
  Cumu: NativeUInt;
begin
  Result := False;
  SetLength(Layers, 0);

  ReadPsdHeader(Data, Pos, Hdr);     // header + Color Mode Data

  SkipSection(Data, Pos);            // Image Resources

  // Layer and Mask Information
  if Pos + 4 > NativeUInt(Length(Data)) then Exit(True);
  LMLen := ReadBE32(Data, Pos);
  if LMLen = 0 then Exit(True);
  Need(Data, Pos, LMLen);

  // Layer Info
  LILen := ReadBE32(Data, Pos);
  if LILen = 0 then Exit(True);

  LayerCount := SmallInt(ReadBE16(Data, Pos));
  if LayerCount < 0 then LayerCount := -LayerCount;   // <0 = first alpha channel is merged transparency
  if LayerCount = 0 then Exit(True);

  SetLength(Layers, LayerCount);
  for li := 0 to LayerCount - 1 do
  begin
    Layers[li].Top    := Integer(ReadBE32(Data, Pos));
    Layers[li].Left   := Integer(ReadBE32(Data, Pos));
    Layers[li].Bottom := Integer(ReadBE32(Data, Pos));
    Layers[li].Right  := Integer(ReadBE32(Data, Pos));

    nCh := ReadBE16(Data, Pos);
    if nCh < 0 then nCh := 0;
    SetLength(Layers[li].Channels, nCh);
    for ci := 0 to nCh - 1 do
    begin
      Layers[li].Channels[ci].ID  := SmallInt(ReadBE16(Data, Pos));
      Layers[li].Channels[ci].Len := ReadBE32(Data, Pos);
    end;

    Need(Data, Pos, 12);
    Inc(Pos, 8);                 // blend mode signature (4) + key (4)
    Inc(Pos, 4);                 // opacity, clipping, flags, filler

    ExtraLen := ReadBE32(Data, Pos);   // layer mask + blending ranges + name...
    Need(Data, Pos, ExtraLen);
    Inc(Pos, ExtraLen);
  end;

  // Pos now points at the start of the channel image data. Each channel takes
  // exactly Len bytes, in layer and channel order.
  Cumu := Pos;
  for li := 0 to LayerCount - 1 do
    for ci := 0 to High(Layers[li].Channels) do
    begin
      Layers[li].Channels[ci].Offset := Cumu;
      Cumu := Cumu + Layers[li].Channels[ci].Len;
    end;

  Result := True;
end;

// Decodes a single layer channel (raw or PackBits RLE) into an 8-bit plane.
function DecodeChannelPlane(const Data: TBytes; ChOffset: NativeUInt;
  W, H: Cardinal; Depth: Word): TBytes;
var
  Pos, RowBytes, Y: NativeUInt;
  Compression: Word;
  RowLens: array of Word;
  Row: TBytes;
  PackedLen: NativeUInt;
begin
  SetLength(Result, NativeInt(W) * NativeInt(H));
  if (W = 0) or (H = 0) then Exit;

  Pos := ChOffset;
  Compression := ReadBE16(Data, Pos);
  RowBytes := RowBytesForDepth(W, Depth);

  if Compression = 0 then
  begin
    Y := 0;
    while Y < H do
    begin
      Need(Data, Pos, RowBytes);
      SetLength(Row, RowBytes);
      if RowBytes <> 0 then Move(Data[Pos], Row[0], RowBytes);
      Inc(Pos, RowBytes);
      NormalizeRowToPlane(Row, Depth, W, Result, Y * W, False);
      Inc(Y);
    end;
  end
  else if Compression = 1 then
  begin
    SetLength(RowLens, H);
    Y := 0;
    while Y < H do
    begin
      RowLens[Y] := ReadBE16(Data, Pos);
      Inc(Y);
    end;
    Y := 0;
    while Y < H do
    begin
      PackedLen := RowLens[Y];
      Row := PackBitsDecodeRow(Data, Pos, PackedLen, RowBytes);
      NormalizeRowToPlane(Row, Depth, W, Result, Y * W, False);
      Inc(Y);
    end;
  end
  else
    raise EPsdError.CreateFmt('PSD: unsupported layer channel compression %d',
      [Compression]);
end;

function PsdLayerCount(InBuf: TBytes): Integer;
var
  Hdr: TPsdHeader;
  Layers: TPsdLayerArray;
begin
  Result := 0;
  try
    if ParseLayers(InBuf, Hdr, Layers) then
      Result := Length(Layers);
  except
    Result := 0;
  end;
end;

function DecodePsdLayer(InBuf: TBytes; LayerIndex: Integer;
  out Width, Height: Integer): TBytes;
var
  Data: TBytes;
  Hdr: TPsdHeader;
  Layers: TPsdLayerArray;
  L: TPsdLayerInfo;
  W, H: Cardinal;
  ci, ID, CC: Integer;
  Color: TPlaneArray;
  Alpha: TBytes;
  Fill: Byte;
begin
  Data := InBuf;
  Width := 0;
  Height := 0;
  SetLength(Result, 0);

  if not ParseLayers(Data, Hdr, Layers) then Exit;
  if (LayerIndex < 0) or (LayerIndex >= Length(Layers)) then
    raise EPsdError.CreateFmt('PSD: layer index %d out of range', [LayerIndex]);
  if (Hdr.Depth <> 8) and (Hdr.Depth <> 16) then
    raise EPsdError.CreateFmt('PSD: unsupported layer depth %d', [Hdr.Depth]);

  L := Layers[LayerIndex];
  if (L.Right <= L.Left) or (L.Bottom <= L.Top) then Exit;   // empty layer
  W := Cardinal(L.Right - L.Left);
  H := Cardinal(L.Bottom - L.Top);

  // Number of color channels: by mode; for Multichannel = highest ID + 1.
  CC := 0;
  for ci := 0 to High(L.Channels) do
    if L.Channels[ci].ID + 1 > CC then CC := L.Channels[ci].ID + 1;
  if Hdr.ColorMode <> PSD_MODE_MULTICHANNEL then
    CC := ColorChannelCount(Hdr.ColorMode, CC);
  if CC < 1 then CC := 1;
  SetLength(Color, CC);
  SetLength(Alpha, 0);

  // Decode only color and alpha channels (masks -2/-3 have a different rectangle).
  for ci := 0 to High(L.Channels) do
  begin
    ID := L.Channels[ci].ID;
    if ID = -1 then
      Alpha := DecodeChannelPlane(Data, L.Channels[ci].Offset, W, H, Hdr.Depth)
    else if (ID >= 0) and (ID < CC) then
      Color[ID] := DecodeChannelPlane(Data, L.Channels[ci].Offset, W, H, Hdr.Depth);
  end;

  // Missing color channels: RGB -> copy of channel 0 (grayscale), CMYK/Multichannel
  // -> 255 (no ink), Lab a/b -> 128 (neutral), others -> 0.
  for ci := 0 to CC - 1 do
    if Length(Color[ci]) = 0 then
    begin
      if (Hdr.ColorMode = PSD_MODE_RGB) and (ci > 0) and (Length(Color[0]) > 0) then
        Color[ci] := Copy(Color[0])
      else
      begin
        case Hdr.ColorMode of
          PSD_MODE_CMYK, PSD_MODE_MULTICHANNEL: Fill := 255;
          PSD_MODE_LAB: if ci > 0 then Fill := 128 else Fill := 0;
        else
          Fill := 0;
        end;
        SetLength(Color[ci], NativeInt(W) * NativeInt(H));
        FillChar(Color[ci][0], Length(Color[ci]), Fill);
      end;
    end;

  PlanesToBitmap(Color, Alpha, W, H, Hdr.ColorMode, Hdr.Palette,
    Hdr.PaletteValid, Result);
  Width := Integer(W);
  Height := Integer(H);
end;

initialization
  InitSrgbGammaLut;

end.
