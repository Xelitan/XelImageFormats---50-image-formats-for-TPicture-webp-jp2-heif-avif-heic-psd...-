unit XelPsd;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, XelPng;

type
  EPsdError = class(Exception);

  TPsdCompression = (
    psdRaw,
    psdRLE
  );

// Dekoduje splaszczony obraz z PSD (8BPS v1) do RGBA8. Tryby: Bitmap, Grayscale,
// Indexed, RGB, CMYK; 1/8/16-bit; kompresja raw i PackBits RLE. Warstwy pomijane.
function DecodePsd(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8

// Zapisuje splaszczony PSD, 8 bit/kanal. InBuf = RGBA8. Opcjonalnie Compression
// (domyslnie psdRLE) i WriteAlpha (domyslnie True = 4-ty kanal).
function EncodePsd(InBuf: TBytes; Width, Height: Integer;
  Compression: TPsdCompression = psdRLE;
  WriteAlpha: Boolean = True): TBytes;                                    // InBuf = RGBA8

// Liczba warstw (layers) w pliku PSD (0 gdy brak sekcji warstw).
function PsdLayerCount(InBuf: TBytes): Integer;

// Dekoduje pojedyncza warstwe (0-based) do RGBA8. Width/Height to rozmiar
// prostokata warstwy (moze byc mniejszy niz plotno). Kanaly R/G/B/A wg ich ID;
// brakujaca alfa = 255, obraz grayscale (tylko kanal 0) powielany na R,G,B.
function DecodePsdLayer(InBuf: TBytes; LayerIndex: Integer;
  out Width, Height: Integer): TBytes;                                    // RGBA8

implementation

const
  PSD_MODE_BITMAP    = 0;
  PSD_MODE_GRAYSCALE = 1;
  PSD_MODE_INDEXED   = 2;
  PSD_MODE_RGB       = 3;
  PSD_MODE_CMYK      = 4;

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

procedure PlanesToBitmap(const Planes: TPlaneArray; Channels: Word;
  W, H: Cardinal; ColorMode: Word; const Palette: TRGBPalette;
  PaletteValid: Boolean; var Buf: TBytes);
var
  X, Y, P: NativeUInt;
  C, M, Ye, K, G, Idx: Integer;
  A: Byte;
  Px: TRGBA;
begin
  InitBitmap(Buf, W, H);
  Y := 0;
  P := 0;
  while Y < H do
  begin
    X := 0;
    while X < W do
    begin
      Px.R := 0;
      Px.G := 0;
      Px.B := 0;
      Px.A := 255;

      case ColorMode of
        PSD_MODE_BITMAP,
        PSD_MODE_GRAYSCALE:
          begin
            if Channels < 1 then raise EPsdError.Create('PSD: grayscale image has no channel');
            G := Planes[0][P];
            Px.R := G; Px.G := G; Px.B := G;
            if Channels >= 2 then Px.A := Planes[1][P];
          end;

        PSD_MODE_INDEXED:
          begin
            if not PaletteValid then raise EPsdError.Create('PSD: indexed image has no palette');
            if Channels < 1 then raise EPsdError.Create('PSD: indexed image has no channel');
            Idx := Planes[0][P];
            Px := Palette[Idx];
            if Channels >= 2 then Px.A := Planes[1][P]
            else Px.A := 255;
          end;

        PSD_MODE_RGB:
          begin
            if Channels < 3 then raise EPsdError.Create('PSD: RGB image has fewer than 3 channels');
            Px.R := Planes[0][P];
            Px.G := Planes[1][P];
            Px.B := Planes[2][P];
            if Channels >= 4 then Px.A := Planes[3][P];
          end;

        PSD_MODE_CMYK:
          begin
            if Channels < 4 then raise EPsdError.Create('PSD: CMYK image has fewer than 4 channels');
            // Photoshop PSD stores CMYK composite samples inverted:
            // 255 means 0% ink, 0 means 100% ink.
            C := 255 - Planes[0][P];
            M := 255 - Planes[1][P];
            Ye := 255 - Planes[2][P];
            K := 255 - Planes[3][P];
            Px.R := ClampByte(255 - C - K);
            Px.G := ClampByte(255 - M - K);
            Px.B := ClampByte(255 - Ye - K);
            if Channels >= 5 then Px.A := Planes[4][P];
          end;
      else
        raise EPsdError.CreateFmt('PSD: unsupported color mode %d', [ColorMode]);
      end;

      SetPx(Buf, Integer(W), Integer(X), Integer(Y), Px);
      Inc(P);
      Inc(X);
    end;
    Inc(Y);
  end;
end;

function DecodePsd(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Data: TBytes;
  Pos, I: NativeUInt;
  Version, Channels, Depth, ColorMode: Word;
  H, W, ColorLen: Cardinal;
  Palette: TRGBPalette;
  PaletteValid: Boolean;
  Planes: TPlaneArray;
begin
  Data := InBuf;
  Width := 0;
  Height := 0;
  SetLength(Result, 0);

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
  Channels := ReadBE16(Data, Pos);
  H := ReadBE32(Data, Pos);
  W := ReadBE32(Data, Pos);
  Depth := ReadBE16(Data, Pos);
  ColorMode := ReadBE16(Data, Pos);

  if (Channels = 0) or (Channels > 56) then
    raise EPsdError.CreateFmt('PSD: invalid channel count %d', [Channels]);
  if (W = 0) or (H = 0) then
    raise EPsdError.Create('PSD: invalid image size');
  if (Depth <> 1) and (Depth <> 8) and (Depth <> 16) then
    raise EPsdError.CreateFmt('PSD: unsupported depth %d', [Depth]);
  if (ColorMode = PSD_MODE_BITMAP) and (Depth <> 1) then
    raise EPsdError.Create('PSD: Bitmap mode must use 1-bit depth');
  if (ColorMode = PSD_MODE_INDEXED) and (Depth <> 8) then
    raise EPsdError.Create('PSD: Indexed mode must use 8-bit depth');
  if (ColorMode <> PSD_MODE_BITMAP) and
     (ColorMode <> PSD_MODE_GRAYSCALE) and
     (ColorMode <> PSD_MODE_INDEXED) and
     (ColorMode <> PSD_MODE_RGB) and
     (ColorMode <> PSD_MODE_CMYK) then
    raise EPsdError.CreateFmt('PSD: unsupported color mode %d', [ColorMode]);

  PaletteValid := False;
  I := 0;
  while I < 256 do
  begin
    Palette[I].R := 0; Palette[I].G := 0; Palette[I].B := 0; Palette[I].A := 255;
    Inc(I);
  end;

  ColorLen := ReadBE32(Data, Pos);
  Need(Data, Pos, ColorLen);
  if ColorMode = PSD_MODE_INDEXED then
  begin
    if ColorLen < 768 then
      raise EPsdError.Create('PSD: indexed palette is shorter than 768 bytes');
    I := 0;
    while I < 256 do
    begin
      Palette[I].R := Data[Pos + I];
      Palette[I].G := Data[Pos + 256 + I];
      Palette[I].B := Data[Pos + 512 + I];
      Palette[I].A := 255;
      Inc(I);
    end;
    PaletteValid := True;
  end;
  Inc(Pos, ColorLen);

  // Image Resources
  SkipSection(Data, Pos);
  // Layer and Mask Information
  SkipSection(Data, Pos);

  Width := Integer(W);
  Height := Integer(H);
  DecodeCompositePlanes(Data, Pos, Channels, W, H, Depth, ColorMode, Planes);
  PlanesToBitmap(Planes, Channels, W, H, ColorMode, Palette, PaletteValid, Result);
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

// ============================ warstwy (layers) ============================

type
  TPsdChannelInfo = record
    ID    : SmallInt;      // 0=R, 1=G, 2=B, -1=alpha, -2=maska uzytkownika...
    Len   : Cardinal;      // dlugosc danych kanalu (razem ze slowem kompresji)
    Offset: NativeUInt;    // absolutny offset danych kanalu w buforze
  end;
  TPsdChannelArray = array of TPsdChannelInfo;

  TPsdLayerInfo = record
    Top, Left, Bottom, Right: Integer;
    Channels: TPsdChannelArray;
  end;
  TPsdLayerArray = array of TPsdLayerInfo;

// Przechodzi naglowek + sekcje do "Layer and Mask Information" i parsuje
// rekordy warstw, wyznaczajac absolutne offsety danych kazdego kanalu.
// Zwraca False (Layers puste), gdy plik nie zawiera warstw.
function ParseLayers(const Data: TBytes; out Depth: Word;
  out Layers: TPsdLayerArray): Boolean;
var
  Pos: NativeUInt;
  Version: Word;
  ColorLen, LMLen, LILen: Cardinal;
  LayerCount, nCh, li, ci: Integer;
  ExtraLen: Cardinal;
  Cumu: NativeUInt;
begin
  Result := False;
  SetLength(Layers, 0);
  Depth := 8;

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
  ReadBE16(Data, Pos);            // channels
  ReadBE32(Data, Pos);            // height
  ReadBE32(Data, Pos);            // width
  Depth := ReadBE16(Data, Pos);
  ReadBE16(Data, Pos);            // color mode - nieuzywane tutaj

  ColorLen := ReadBE32(Data, Pos);   // Color Mode Data
  Need(Data, Pos, ColorLen);
  Inc(Pos, ColorLen);

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
  if LayerCount < 0 then LayerCount := -LayerCount;   // <0 = pierwszy kanal to alpha
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

  // Teraz Pos wskazuje na poczatek danych obrazu kanalow. Kazdy kanal zajmuje
  // dokladnie Len bajtow, w kolejnosci warstw i kanalow.
  Cumu := Pos;
  for li := 0 to LayerCount - 1 do
    for ci := 0 to High(Layers[li].Channels) do
    begin
      Layers[li].Channels[ci].Offset := Cumu;
      Cumu := Cumu + Layers[li].Channels[ci].Len;
    end;

  Result := True;
end;

// Dekoduje pojedynczy kanal warstwy (raw lub PackBits RLE) do plaszczyzny 8-bit.
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
  Depth: Word;
  Layers: TPsdLayerArray;
begin
  Result := 0;
  try
    if ParseLayers(InBuf, Depth, Layers) then
      Result := Length(Layers);
  except
    Result := 0;
  end;
end;

function DecodePsdLayer(InBuf: TBytes; LayerIndex: Integer;
  out Width, Height: Integer): TBytes;
var
  Data: TBytes;
  Depth: Word;
  Layers: TPsdLayerArray;
  L: TPsdLayerInfo;
  W, H: Cardinal;
  ci: Integer;
  Plane, PlaneR, PlaneG, PlaneB, PlaneA: TBytes;
  HasR, HasG, HasB, HasA: Boolean;
  X, Y, P: NativeUInt;
  Px: TRGBA;
begin
  Data := InBuf;
  Width := 0;
  Height := 0;
  SetLength(Result, 0);

  if not ParseLayers(Data, Depth, Layers) then Exit;
  if (LayerIndex < 0) or (LayerIndex >= Length(Layers)) then
    raise EPsdError.CreateFmt('PSD: layer index %d out of range', [LayerIndex]);
  if (Depth <> 8) and (Depth <> 16) then
    raise EPsdError.CreateFmt('PSD: unsupported layer depth %d', [Depth]);

  L := Layers[LayerIndex];
  if (L.Right <= L.Left) or (L.Bottom <= L.Top) then Exit;   // pusta warstwa
  W := Cardinal(L.Right - L.Left);
  H := Cardinal(L.Bottom - L.Top);

  HasR := False; HasG := False; HasB := False; HasA := False;
  for ci := 0 to High(L.Channels) do
  begin
    Plane := DecodeChannelPlane(Data, L.Channels[ci].Offset, W, H, Depth);
    case L.Channels[ci].ID of
       0: begin PlaneR := Plane; HasR := True; end;
       1: begin PlaneG := Plane; HasG := True; end;
       2: begin PlaneB := Plane; HasB := True; end;
      -1: begin PlaneA := Plane; HasA := True; end;
    end;
  end;

  Width := Integer(W);
  Height := Integer(H);
  InitBitmap(Result, W, H);

  P := 0;
  Y := 0;
  while Y < H do
  begin
    X := 0;
    while X < W do
    begin
      if HasR then Px.R := PlaneR[P] else Px.R := 0;
      if HasG then Px.G := PlaneG[P] else Px.G := Px.R;   // grayscale -> szary
      if HasB then Px.B := PlaneB[P] else Px.B := Px.R;
      if HasA then Px.A := PlaneA[P] else Px.A := 255;
      SetPx(Result, Integer(W), Integer(X), Integer(Y), Px);
      Inc(P);
      Inc(X);
    end;
    Inc(Y);
  end;
end;

end.
