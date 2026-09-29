unit XelPcx;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, XelPng;

type
  EPcxError = class(Exception);

function DecodePcx(InBuf: TBytes; out Width, Height: Integer): TBytes; // RGBA8
function EncodePcx(InBuf: TBytes; Width, Height: Integer): TBytes;      // InBuf = RGBA8

implementation

type
  TRGBPalette16 = array[0..15] of TRGBA;
  TRGBPalette256 = array[0..255] of TRGBA;

const
  PCX_HEADER_SIZE = 128;
  PCX_MANUFACTURER = $0A;
  PCX_ENCODING_NONE = 0;
  PCX_ENCODING_RLE = 1;
  PCX_VGA_PALETTE_MARKER = $0C;

procedure Need(const Data: TBytes; Pos, Count: NativeUInt); inline;
begin
  if (Pos > NativeUInt(Length(Data))) or
     (Count > NativeUInt(Length(Data)) - Pos) then
    raise EPcxError.Create('PCX: unexpected end of file');
end;

function LE16At(const Data: TBytes; Pos: NativeUInt): Word; inline;
begin
  Need(Data, Pos, 2);
  Result := Word(Data[Pos]) or (Word(Data[Pos + 1]) shl 8);
end;

procedure PutLE16(var Data: TBytes; Pos: NativeUInt; V: Word); inline;
begin
  Data[Pos] := Byte(V);
  Data[Pos + 1] := Byte(V shr 8);
end;

procedure SetOpaque(var C: TRGBA; R, G, B: Byte); inline;
begin
  C.R := R;
  C.G := G;
  C.B := B;
  C.A := 255;
end;

procedure DefaultEGAPalette(var P: TRGBPalette16);
begin
  SetOpaque(P[0],   0,   0,   0);
  SetOpaque(P[1],   0,   0, 170);
  SetOpaque(P[2],   0, 170,   0);
  SetOpaque(P[3],   0, 170, 170);
  SetOpaque(P[4], 170,   0,   0);
  SetOpaque(P[5], 170,   0, 170);
  SetOpaque(P[6], 170,  85,   0);
  SetOpaque(P[7], 170, 170, 170);
  SetOpaque(P[8],  85,  85,  85);
  SetOpaque(P[9],  85,  85, 255);
  SetOpaque(P[10], 85, 255,  85);
  SetOpaque(P[11], 85, 255, 255);
  SetOpaque(P[12],255,  85,  85);
  SetOpaque(P[13],255,  85, 255);
  SetOpaque(P[14],255, 255,  85);
  SetOpaque(P[15],255, 255, 255);
end;

procedure ReadHeaderPalette(const Data: TBytes; Version: Byte;
  var P: TRGBPalette16);
var
  I: Integer;
  Pos: NativeUInt;
  AllZero: Boolean;
begin
  DefaultEGAPalette(P);

  // Version 3 explicitly means PC Paintbrush 2.8 without palette.
  if Version = 3 then Exit;

  Need(Data, 16, 48);
  AllZero := True;
  I := 0;
  while I < 48 do
  begin
    if Data[16 + I] <> 0 then
    begin
      AllZero := False;
      Break;
    end;
    Inc(I);
  end;

  // A completely empty header palette occurs in a number of old files.
  // Keep the conventional EGA palette in that case.
  if AllZero then Exit;

  Pos := 16;
  I := 0;
  while I < 16 do
  begin
    SetOpaque(P[I], Data[Pos], Data[Pos + 1], Data[Pos + 2]);
    Inc(Pos, 3);
    Inc(I);
  end;
end;

function FindVGAPalette(const Data: TBytes; ImageEnd: NativeUInt;
  var P: TRGBPalette256): Boolean;
var
  Pos, I: NativeUInt;
begin
  Result := False;

  // Preferred position: immediately after the compressed image data.
  Pos := ImageEnd;
  if (Pos + 769 <= NativeUInt(Length(Data))) and
     (Data[Pos] = PCX_VGA_PALETTE_MARKER) then
  begin
    Inc(Pos);
  end
  else
  begin
    // Common tolerant fallback: the palette occupies the final 769 bytes.
    if Length(Data) < 769 then Exit;
    Pos := NativeUInt(Length(Data) - 769);
    if Data[Pos] <> PCX_VGA_PALETTE_MARKER then Exit;
    Inc(Pos);
  end;

  Need(Data, Pos, 768);
  I := 0;
  while I < 256 do
  begin
    SetOpaque(P[I], Data[Pos], Data[Pos + 1], Data[Pos + 2]);
    Inc(Pos, 3);
    Inc(I);
  end;
  Result := True;
end;

procedure MakeGrayPalette(var P: TRGBPalette256);
var
  I: Integer;
begin
  I := 0;
  while I < 256 do
  begin
    SetOpaque(P[I], Byte(I), Byte(I), Byte(I));
    Inc(I);
  end;
end;

procedure DecodeBytes(const Data: TBytes; var Pos: NativeUInt;
  Encoding: Byte; var RunLeft: Integer; var RunValue: Byte;
  Dest: PByte; Count: NativeUInt);
var
  OutPos: NativeUInt;
  B: Byte;
begin
  OutPos := 0;

  if Encoding = PCX_ENCODING_NONE then
  begin
    Need(Data, Pos, Count);
    if Count <> 0 then
      Move(Data[Pos], Dest^, Count);
    Inc(Pos, Count);
    Exit;
  end;

  if Encoding <> PCX_ENCODING_RLE then
    raise EPcxError.CreateFmt('PCX: unsupported encoding %d', [Encoding]);

  while OutPos < Count do
  begin
    if RunLeft = 0 then
    begin
      Need(Data, Pos, 1);
      B := Data[Pos];
      Inc(Pos);

      if (B and $C0) = $C0 then
      begin
        RunLeft := B and $3F;
        if RunLeft = 0 then
          raise EPcxError.Create('PCX: invalid zero-length RLE run');
        Need(Data, Pos, 1);
        RunValue := Data[Pos];
        Inc(Pos);
      end
      else
      begin
        RunLeft := 1;
        RunValue := B;
      end;
    end;

    Dest[OutPos] := RunValue;
    Inc(OutPos);
    Dec(RunLeft);
  end;
end;

function PackedIndex(Row: PByte; X: NativeUInt; BitsPerPixel: Byte): Byte; inline;
var
  BytePos: NativeUInt;
  Shift: Integer;
begin
  case BitsPerPixel of
    1:
      begin
        BytePos := X shr 3;
        Shift := 7 - Integer(X and 7);
        Result := (Row[BytePos] shr Shift) and 1;
      end;
    2:
      begin
        BytePos := X shr 2;
        Shift := 6 - Integer((X and 3) shl 1);
        Result := (Row[BytePos] shr Shift) and 3;
      end;
    4:
      begin
        BytePos := X shr 1;
        if (X and 1) = 0 then Shift := 4 else Shift := 0;
        Result := (Row[BytePos] shr Shift) and $0F;
      end;
  else
    Result := 0;
  end;
end;

function DecodePcx(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Version, Encoding, BitsPerPixel, Planes: Byte;
  XMin, YMin, XMax, YMax, BytesPerLine, PaletteInfo: Word;
  W, H: Cardinal;
  Pos, LineBytes, X, Y, Plane: NativeUInt;
  Line: TBytes;
  RunLeft: Integer;
  RunValue, Idx, BitValue: Byte;
  Pal16: TRGBPalette16;
  Pal256: TRGBPalette256;
  HasPal256: Boolean;
  C: TRGBA;
  NeedPerPlane: NativeUInt;
begin
  Width := 0;
  Height := 0;
  SetLength(Result, 0);

  Need(InBuf, 0, PCX_HEADER_SIZE);
  if InBuf[0] <> PCX_MANUFACTURER then
    raise EPcxError.Create('PCX: invalid manufacturer byte');

  Version := InBuf[1];
  Encoding := InBuf[2];
  BitsPerPixel := InBuf[3];
  XMin := LE16At(InBuf, 4);
  YMin := LE16At(InBuf, 6);
  XMax := LE16At(InBuf, 8);
  YMax := LE16At(InBuf, 10);
  Planes := InBuf[65];
  BytesPerLine := LE16At(InBuf, 66);
  PaletteInfo := LE16At(InBuf, 68);

  if XMax < XMin then
    raise EPcxError.Create('PCX: invalid X coordinates');
  if YMax < YMin then
    raise EPcxError.Create('PCX: invalid Y coordinates');

  W := Cardinal(XMax) - Cardinal(XMin) + 1;
  H := Cardinal(YMax) - Cardinal(YMin) + 1;
  if (W = 0) or (H = 0) then
    raise EPcxError.Create('PCX: invalid image dimensions');
  if Planes = 0 then
    raise EPcxError.Create('PCX: zero color planes');
  if BytesPerLine = 0 then
    raise EPcxError.Create('PCX: zero bytes per line');

  case BitsPerPixel of
    1, 2, 4, 8, 24: ;
  else
    raise EPcxError.CreateFmt('PCX: unsupported bits-per-plane %d',
      [BitsPerPixel]);
  end;

  // Validate that each plane can physically contain the visible pixels.
  if BitsPerPixel = 24 then
  begin
    if Planes <> 1 then
      raise EPcxError.Create('PCX: 24-bit packed data must use one plane');
    NeedPerPlane := NativeUInt(W) * 3;
  end
  else
    NeedPerPlane := (NativeUInt(W) * BitsPerPixel + 7) shr 3;

  if NativeUInt(BytesPerLine) < NeedPerPlane then
    raise EPcxError.Create('PCX: bytes-per-line is too small');

  if (BitsPerPixel = 1) and (Planes > 4) then
    raise EPcxError.Create('PCX: more than 4 one-bit planes are unsupported');

  if (BitsPerPixel in [2, 4]) and (Planes <> 1) then
    raise EPcxError.Create('PCX: packed 2/4-bit PCX must use one plane');

  if (BitsPerPixel = 8) and not (Planes in [1, 3, 4]) then
    raise EPcxError.CreateFmt('PCX: unsupported 8-bit plane count %d', [Planes]);

  LineBytes := NativeUInt(BytesPerLine) * NativeUInt(Planes);
  if LineBytes > NativeUInt(High(NativeInt)) then
    raise EPcxError.Create('PCX: scanline is too large');
  SetLength(Line, NativeInt(LineBytes));

  if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then
    raise EPcxError.Create('PCX: image is too large');
  Width := Integer(W);
  Height := Integer(H);
  SetLength(Result, NativeInt(UInt64(W) * UInt64(H) * 4));
  ReadHeaderPalette(InBuf, Version, Pal16);

  Pos := PCX_HEADER_SIZE;
  RunLeft := 0;
  RunValue := 0;

  Y := 0;
  while Y < H do
  begin
    DecodeBytes(InBuf, Pos, Encoding, RunLeft, RunValue,
      @Line[0], LineBytes);

    X := 0;
    while X < W do
    begin
      if (BitsPerPixel = 1) then
      begin
        Idx := 0;
        Plane := 0;
        while Plane < Planes do
        begin
          BitValue := PackedIndex(@Line[Plane * NativeUInt(BytesPerLine)],
            X, 1);
          Idx := Idx or (BitValue shl Plane);
          Inc(Plane);
        end;
        SetPx(Result, Integer(W), Integer(X), Integer(Y), Pal16[Idx and $0F]);
      end
      else if (BitsPerPixel = 2) or (BitsPerPixel = 4) then
      begin
        Idx := PackedIndex(@Line[0], X, BitsPerPixel);
        SetPx(Result, Integer(W), Integer(X), Integer(Y), Pal16[Idx and $0F]);
      end
      else if (BitsPerPixel = 8) and (Planes = 1) then
      begin
        // Palette is applied after all scanlines have been decoded. Temporarily
        // keep the palette index in R.
        Idx := Line[X];
        C.R := Idx; C.G := 0; C.B := 0; C.A := 255;
        SetPx(Result, Integer(W), Integer(X), Integer(Y), C);
      end
      else if (BitsPerPixel = 8) and (Planes = 3) then
      begin
        C.R := Line[X];
        C.G := Line[NativeUInt(BytesPerLine) + X];
        C.B := Line[NativeUInt(BytesPerLine) * 2 + X];
        C.A := 255;
        SetPx(Result, Integer(W), Integer(X), Integer(Y), C);
      end
      else if (BitsPerPixel = 8) and (Planes = 4) then
      begin
        // Non-standard extension seen in some software: RGBA planes.
        C.R := Line[X];
        C.G := Line[NativeUInt(BytesPerLine) + X];
        C.B := Line[NativeUInt(BytesPerLine) * 2 + X];
        C.A := Line[NativeUInt(BytesPerLine) * 3 + X];
        SetPx(Result, Integer(W), Integer(X), Integer(Y), C);
      end
      else if (BitsPerPixel = 24) and (Planes = 1) then
      begin
        C.R := Line[X * 3];
        C.G := Line[X * 3 + 1];
        C.B := Line[X * 3 + 2];
        C.A := 255;
        SetPx(Result, Integer(W), Integer(X), Integer(Y), C);
      end;

      Inc(X);
    end;
    Inc(Y);
  end;

  if (BitsPerPixel = 8) and (Planes = 1) then
  begin
    HasPal256 := FindVGAPalette(InBuf, Pos, Pal256);
    if not HasPal256 then
    begin
      if PaletteInfo = 2 then
        MakeGrayPalette(Pal256)
      else
        raise EPcxError.Create('PCX: missing 256-color VGA palette');
    end;

    Y := 0;
    while Y < H do
    begin
      X := 0;
      while X < W do
      begin
        C := GetPx(Result, Integer(W), Integer(X), Integer(Y));
        Idx := C.R;
        SetPx(Result, Integer(W), Integer(X), Integer(Y), Pal256[Idx]);
        Inc(X);
      end;
      Inc(Y);
    end;
  end;
end;

function RLEEncodeLine(const Src: TBytes): TBytes;
var
  I, J, N, OutPos: NativeInt;
  V: Byte;
begin
  SetLength(Result, 0);
  N := Length(Src);
  if N = 0 then Exit;

  // Worst case: every literal byte is >= $C0 and needs a two-byte escape.
  if N > High(NativeInt) div 2 then
    raise EPcxError.Create('PCX: scanline is too large');
  SetLength(Result, N * 2);

  I := 0;
  OutPos := 0;
  while I < N do
  begin
    V := Src[I];
    J := I + 1;
    while (J < N) and (Src[J] = V) and ((J - I) < 63) do
      Inc(J);

    if ((J - I) > 1) or ((V and $C0) = $C0) then
    begin
      Result[OutPos] := $C0 or Byte(J - I);
      Result[OutPos + 1] := V;
      Inc(OutPos, 2);
    end
    else
    begin
      Result[OutPos] := V;
      Inc(OutPos);
    end;

    I := J;
  end;

  SetLength(Result, OutPos);
end;

function EncodePcx(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  S: TMemoryStream;
  Header, Line, Encoded: TBytes;
  BytesPerLine: Cardinal;
  X, Y: NativeUInt;
  C: TRGBA;
  N: NativeInt;
begin
  SetLength(Result, 0);
  SetLength(Header, 0);
  SetLength(Line, 0);
  SetLength(Encoded, 0);

  if (Width = 0) or (Height = 0) then
    raise EPcxError.Create('PCX: cannot encode an empty image');
  if (Width > 65535) or (Height > 65535) then
    raise EPcxError.Create('PCX: dimensions exceed the 16-bit PCX header');
  if (Width < 0) or (Height < 0) then
    raise EPcxError.Create('PCX: invalid image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EPcxError.Create('PCX: RGBA8 buffer size does not match Width*Height*4');

  BytesPerLine := (Cardinal(Width) + 1) and not Cardinal(1);
  if BytesPerLine > 65535 then
    raise EPcxError.Create('PCX: bytes-per-line exceeds 65535');

  SetLength(Header, PCX_HEADER_SIZE);
  FillChar(Header[0], Length(Header), 0);
  Header[0] := PCX_MANUFACTURER;
  Header[1] := 5;                 // PC Paintbrush 3.0+
  Header[2] := PCX_ENCODING_RLE;
  Header[3] := 8;                 // 8 bits per plane
  PutLE16(Header, 4, 0);          // XMin
  PutLE16(Header, 6, 0);          // YMin
  PutLE16(Header, 8, Word(Width - 1));
  PutLE16(Header, 10, Word(Height - 1));
  PutLE16(Header, 12, 72);        // HDPI
  PutLE16(Header, 14, 72);        // VDPI
  Header[64] := 0;                // Reserved
  Header[65] := 3;                // R, G, B planes
  PutLE16(Header, 66, Word(BytesPerLine));
  PutLE16(Header, 68, 1);         // color/BW
  PutLE16(Header, 70, Word(Width));
  PutLE16(Header, 72, Word(Height));

  S := TMemoryStream.Create;
  try
    S.WriteBuffer(Header[0], Length(Header));
    SetLength(Line, NativeInt(BytesPerLine) * 3);

    Y := 0;
    while Y < Height do
    begin
      FillChar(Line[0], Length(Line), 0);
      X := 0;
      while X < Width do
      begin
        C := GetPx(InBuf, Width, Integer(X), Integer(Y));
        Line[X] := C.R;
        Line[NativeUInt(BytesPerLine) + X] := C.G;
        Line[NativeUInt(BytesPerLine) * 2 + X] := C.B;
        Inc(X);
      end;

      Encoded := RLEEncodeLine(Line);
      if Length(Encoded) <> 0 then
        S.WriteBuffer(Encoded[0], Length(Encoded));
      Inc(Y);
    end;

    if S.Size > 2147483647 then
      raise EPcxError.Create('PCX: encoded file is too large');
    N := NativeInt(S.Size);
    SetLength(Result, N);
    if N <> 0 then
    begin
      S.Position := 0;
      S.ReadBuffer(Result[0], N);
    end;
  finally
    S.Free;
  end;
end;

end.
