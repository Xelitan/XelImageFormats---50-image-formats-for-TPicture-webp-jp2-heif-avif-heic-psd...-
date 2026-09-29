unit XelBmp;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, XelPng;

type
  EBmpError = class(Exception);

function DecodeBmp(InBuf: TBytes; out Width, Height: Integer): TBytes; // RGBA8
function EncodeBmp(InBuf: TBytes; Width, Height: Integer): TBytes;      // InBuf = RGBA8

implementation

const
  BI_RGB             = 0;
  BI_RLE8            = 1;
  BI_RLE4            = 2;
  BI_BITFIELDS       = 3;
  BI_JPEG            = 4;
  BI_PNG             = 5;
  BI_ALPHABITFIELDS  = 6;

  BMP_FILE_HEADER_SIZE = 14;
  BMP_INFO_HEADER_SIZE = 40;
  BMP_V4_HEADER_SIZE   = 108;

  LCS_sRGB = $73524742;

type
  TRGBAPalette = array of TRGBA;

function ReadLE16(P: PByte): Word; inline;
begin
  Result := Word(P[0]) or (Word(P[1]) shl 8);
end;

function ReadLE32(P: PByte): Cardinal; inline;
begin
  Result := Cardinal(P[0]) or (Cardinal(P[1]) shl 8) or
            (Cardinal(P[2]) shl 16) or (Cardinal(P[3]) shl 24);
end;

function ReadLEInt32(P: PByte): LongInt; inline;
begin
  Result := LongInt(ReadLE32(P));
end;

procedure PutLE16(var D: TBytes; Pos: NativeUInt; V: Word); inline;
begin
  D[Pos] := Byte(V);
  D[Pos + 1] := Byte(V shr 8);
end;

procedure PutLE32(var D: TBytes; Pos: NativeUInt; V: Cardinal); inline;
begin
  D[Pos] := Byte(V);
  D[Pos + 1] := Byte(V shr 8);
  D[Pos + 2] := Byte(V shr 16);
  D[Pos + 3] := Byte(V shr 24);
end;

procedure Need(const Data: TBytes; Pos, Count: NativeUInt); inline;
var
  L: NativeUInt;
begin
  L := NativeUInt(Length(Data));
  if (Pos > L) or (Count > L - Pos) then
    raise EBmpError.Create('BMP: truncated file');
end;

function ScaleMask(V, Mask: Cardinal; DefaultValue: Byte): Byte;
var
  Shift: Integer;
  MaxV, Raw: Cardinal;
begin
  if Mask = 0 then
  begin
    Result := DefaultValue;
    Exit;
  end;

  Shift := 0;
  while ((Mask shr Shift) and 1) = 0 do
    Inc(Shift);
  MaxV := Mask shr Shift;
  Raw := (V and Mask) shr Shift;
  if MaxV = 0 then
    Result := DefaultValue
  else
    Result := Byte((UInt64(Raw) * 255 + (MaxV div 2)) div MaxV);
end;

function PaletteIndexColor(const Palette: TRGBAPalette; Index: Cardinal): TRGBA;
begin
  if Index >= Cardinal(Length(Palette)) then
    raise EBmpError.Create('BMP: palette index out of range');
  Result := Palette[Index];
end;

procedure FillPixels(var B: TBytes; Width, Height: Cardinal; const C: TRGBA);
var
  I, Count: NativeUInt;
begin
  Count := NativeUInt(Width) * NativeUInt(Height);
  I := 0;
  while I < Count do
  begin
    B[I * 4] := C.R;
    B[I * 4 + 1] := C.G;
    B[I * 4 + 2] := C.B;
    B[I * 4 + 3] := C.A;
    Inc(I);
  end;
end;

procedure DecodeRLE(const Data: TBytes; StartPos: NativeUInt; var B: TBytes;
  Width, Height: Cardinal; const Palette: TRGBAPalette;
  IsRLE4, TopDown: Boolean);
var
  Pos: NativeUInt;
  X, FileY, I, N, ByteCount: Cardinal;
  Count, V, PkByte, Idx: Byte;
  C: TRGBA;

  procedure PutIndex(AIndex: Byte);
  var
    DstY: Cardinal;
  begin
    if FileY >= Height then
      raise EBmpError.Create('BMP: RLE row outside image');
    if X >= Width then
      raise EBmpError.Create('BMP: RLE run exceeds row width');
    if AIndex >= Length(Palette) then
      raise EBmpError.Create('BMP: RLE palette index out of range');
    if TopDown then
      DstY := FileY
    else
      DstY := Height - 1 - FileY;
    SetPx(B, Integer(Width), Integer(X), Integer(DstY), Palette[AIndex]);
    Inc(X);
  end;

begin
  if Length(Palette) = 0 then
    raise EBmpError.Create('BMP: RLE image has no palette');

  C := Palette[0];
  FillPixels(B, Width, Height, C);
  Pos := StartPos;
  X := 0;
  FileY := 0;

  while Pos < NativeUInt(Length(Data)) do
  begin
    Need(Data, Pos, 2);
    Count := Data[Pos];
    V := Data[Pos + 1];
    Inc(Pos, 2);

    if Count <> 0 then
    begin
      I := 0;
      if IsRLE4 then
      begin
        while I < Count do
        begin
          if (I and 1) = 0 then
            Idx := V shr 4
          else
            Idx := V and $0F;
          PutIndex(Idx);
          Inc(I);
        end;
      end
      else
      begin
        while I < Count do
        begin
          PutIndex(V);
          Inc(I);
        end;
      end;
      Continue;
    end;

    case V of
      0: begin
           X := 0;
           Inc(FileY);
           if FileY > Height then
             raise EBmpError.Create('BMP: too many RLE rows');
         end;
      1: Exit;
      2: begin
           Need(Data, Pos, 2);
           Inc(X, Data[Pos]);
           Inc(FileY, Data[Pos + 1]);
           Inc(Pos, 2);
           if (X > Width) or (FileY > Height) then
             raise EBmpError.Create('BMP: RLE delta outside image');
         end;
    else
      N := V;
      if IsRLE4 then
      begin
        ByteCount := (N + 1) div 2;
        Need(Data, Pos, ByteCount);
        I := 0;
        while I < N do
        begin
          PkByte := Data[Pos + (I shr 1)];
          if (I and 1) = 0 then
            Idx := PkByte shr 4
          else
            Idx := PkByte and $0F;
          PutIndex(Idx);
          Inc(I);
        end;
        Inc(Pos, ByteCount);
        if (ByteCount and 1) <> 0 then
        begin
          Need(Data, Pos, 1);
          Inc(Pos);
        end;
      end
      else
      begin
        Need(Data, Pos, N);
        I := 0;
        while I < N do
        begin
          PutIndex(Data[Pos + I]);
          Inc(I);
        end;
        Inc(Pos, N);
        if (N and 1) <> 0 then
        begin
          Need(Data, Pos, 1);
          Inc(Pos);
        end;
      end;
    end;
  end;
end;

function DecodeBmp(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  DibSize, PixelOffset, Compression, ColorsUsed: Cardinal;
  W, H: Cardinal;
  SW, SH: LongInt;
  Planes, BitCount: Word;
  TopDown: Boolean;
  Pos, PalPos, RowPos, MaskPos: NativeUInt;
  PaletteCount, PalEntrySize, MaskBytesAfterHeader: Cardinal;
  Palette: TRGBAPalette;
  I, X, FileY, DstY: Cardinal;
  RMask, GMask, BMask, AMask: Cardinal;
  Stride64, RowBits64: UInt64;
  Stride: NativeUInt;
  V16: Word;
  V32: Cardinal;
  Idx: Byte;
  C: TRGBA;
begin
  Width := 0;
  Height := 0;
  SetLength(Result, 0);
  SetLength(Palette, 0);

  Need(InBuf, 0, BMP_FILE_HEADER_SIZE + 4);
  if (InBuf[0] <> Ord('B')) or (InBuf[1] <> Ord('M')) then
    raise EBmpError.Create('BMP: invalid signature');

  PixelOffset := ReadLE32(@InBuf[10]);
  DibSize := ReadLE32(@InBuf[14]);
  if DibSize < 12 then
    raise EBmpError.Create('BMP: unsupported DIB header');
  Need(InBuf, 14, DibSize);

  Compression := BI_RGB;
  ColorsUsed := 0;
  TopDown := False;
  MaskBytesAfterHeader := 0;
  RMask := 0;
  GMask := 0;
  BMask := 0;
  AMask := 0;

  if DibSize = 12 then
  begin
    W := ReadLE16(@InBuf[18]);
    H := ReadLE16(@InBuf[20]);
    Planes := ReadLE16(@InBuf[22]);
    BitCount := ReadLE16(@InBuf[24]);
    PalEntrySize := 3;
  end
  else if DibSize >= 40 then
  begin
    SW := ReadLEInt32(@InBuf[18]);
    SH := ReadLEInt32(@InBuf[22]);
    Planes := ReadLE16(@InBuf[26]);
    BitCount := ReadLE16(@InBuf[28]);
    Compression := ReadLE32(@InBuf[30]);
    ColorsUsed := ReadLE32(@InBuf[46]);
    PalEntrySize := 4;

    if SW <= 0 then
      raise EBmpError.Create('BMP: invalid width');
    W := Cardinal(SW);
    if SH = 0 then
      raise EBmpError.Create('BMP: invalid height');
    if SH < 0 then
    begin
      if SH = Low(LongInt) then
        raise EBmpError.Create('BMP: invalid height');
      TopDown := True;
      H := Cardinal(-SH);
    end
    else
      H := Cardinal(SH);

    if DibSize >= 52 then
    begin
      RMask := ReadLE32(@InBuf[54]);
      GMask := ReadLE32(@InBuf[58]);
      BMask := ReadLE32(@InBuf[62]);
      if DibSize >= 56 then
        AMask := ReadLE32(@InBuf[66]);
    end
    else if (Compression = BI_BITFIELDS) or
            (Compression = BI_ALPHABITFIELDS) then
    begin
      MaskPos := NativeUInt(14) + DibSize;
      Need(InBuf, MaskPos, 12);
      RMask := ReadLE32(@InBuf[MaskPos]);
      GMask := ReadLE32(@InBuf[MaskPos + 4]);
      BMask := ReadLE32(@InBuf[MaskPos + 8]);
      MaskBytesAfterHeader := 12;
      if (Compression = BI_ALPHABITFIELDS) or
         ((BitCount = 32) and
          (NativeUInt(PixelOffset) >= MaskPos + 16)) then
      begin
        Need(InBuf, MaskPos + 12, 4);
        AMask := ReadLE32(@InBuf[MaskPos + 12]);
        MaskBytesAfterHeader := 16;
      end;
    end;
  end
  else
    raise EBmpError.CreateFmt('BMP: unsupported DIB header size %d', [DibSize]);

  if (W = 0) or (H = 0) then
    raise EBmpError.Create('BMP: empty bitmap');
  if Planes <> 1 then
    raise EBmpError.Create('BMP: planes must be 1');

  case BitCount of
    1, 4, 8, 16, 24, 32: ;
  else
    raise EBmpError.CreateFmt('BMP: unsupported bit depth %d', [BitCount]);
  end;

  case Compression of
    BI_RGB: ;
    BI_RLE8:
      if BitCount <> 8 then
        raise EBmpError.Create('BMP: BI_RLE8 requires 8 bpp');
    BI_RLE4:
      if BitCount <> 4 then
        raise EBmpError.Create('BMP: BI_RLE4 requires 4 bpp');
    BI_BITFIELDS, BI_ALPHABITFIELDS:
      if (BitCount <> 16) and (BitCount <> 32) then
        raise EBmpError.Create('BMP: bitfields require 16 or 32 bpp');
    BI_JPEG, BI_PNG:
      raise EBmpError.Create('BMP: embedded JPEG/PNG compression is not supported');
  else
    raise EBmpError.CreateFmt('BMP: unsupported compression %d', [Compression]);
  end;

  if (Compression = BI_RGB) and (BitCount = 16) then
  begin
    RMask := $7C00;
    GMask := $03E0;
    BMask := $001F;
    AMask := 0;
  end;

  if ((Compression = BI_BITFIELDS) or (Compression = BI_ALPHABITFIELDS)) and
     ((RMask = 0) or (GMask = 0) or (BMask = 0)) then
    raise EBmpError.Create('BMP: invalid RGB bit masks');

  if BitCount <= 8 then
  begin
    if ColorsUsed = 0 then
      PaletteCount := Cardinal(1) shl BitCount
    else
      PaletteCount := ColorsUsed;
    if PaletteCount > (Cardinal(1) shl BitCount) then
      raise EBmpError.Create('BMP: palette is larger than bit depth allows');

    PalPos := NativeUInt(14) + DibSize + MaskBytesAfterHeader;
    if NativeUInt(PixelOffset) < PalPos then
      raise EBmpError.Create('BMP: invalid pixel offset');
    if UInt64(PaletteCount) * PalEntrySize > UInt64(NativeUInt(PixelOffset) - PalPos) then
      raise EBmpError.Create('BMP: truncated palette');
    Need(InBuf, PalPos, NativeUInt(PaletteCount) * PalEntrySize);
    SetLength(Palette, PaletteCount);
    I := 0;
    while I < PaletteCount do
    begin
      Pos := PalPos + NativeUInt(I) * PalEntrySize;
      Palette[I].B := InBuf[Pos];
      Palette[I].G := InBuf[Pos + 1];
      Palette[I].R := InBuf[Pos + 2];
      Palette[I].A := 255;
      Inc(I);
    end;
  end;

  if NativeUInt(PixelOffset) > NativeUInt(Length(InBuf)) then
    raise EBmpError.Create('BMP: pixel offset outside file');

  if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then
    raise EBmpError.Create('BMP: image is too large');
  Width := Integer(W);
  Height := Integer(H);
  SetLength(Result, NativeInt(UInt64(W) * UInt64(H) * 4));

  if (Compression = BI_RLE8) or (Compression = BI_RLE4) then
  begin
    DecodeRLE(InBuf, PixelOffset, Result, W, H, Palette, Compression = BI_RLE4, TopDown);
    Exit;
  end;

  RowBits64 := UInt64(W) * BitCount;
  Stride64 := ((RowBits64 + 31) div 32) * 4;
  if Stride64 > UInt64(High(NativeUInt)) then
    raise EBmpError.Create('BMP: row is too large');
  Stride := NativeUInt(Stride64);
  if UInt64(PixelOffset) + Stride64 * H > UInt64(Length(InBuf)) then
    raise EBmpError.Create('BMP: truncated pixel data');

  FileY := 0;
  while FileY < H do
  begin
    if TopDown then
      DstY := FileY
    else
      DstY := H - 1 - FileY;
    RowPos := NativeUInt(PixelOffset) + NativeUInt(FileY) * Stride;
    X := 0;
    while X < W do
    begin
      C.R := 0;
      C.G := 0;
      C.B := 0;
      C.A := 255;
      case BitCount of
        1:
          begin
            Idx := (InBuf[RowPos + (X shr 3)] shr (7 - (X and 7))) and 1;
            C := PaletteIndexColor(Palette, Idx);
          end;
        4:
          begin
            V32 := InBuf[RowPos + (X shr 1)];
            if (X and 1) = 0 then
              Idx := Byte(V32 shr 4)
            else
              Idx := Byte(V32 and $0F);
            C := PaletteIndexColor(Palette, Idx);
          end;
        8:
          begin
            Idx := InBuf[RowPos + X];
            C := PaletteIndexColor(Palette, Idx);
          end;
        16:
          begin
            V16 := ReadLE16(@InBuf[RowPos + NativeUInt(X) * 2]);
            C.R := ScaleMask(V16, RMask, 0);
            C.G := ScaleMask(V16, GMask, 0);
            C.B := ScaleMask(V16, BMask, 0);
            C.A := ScaleMask(V16, AMask, 255);
          end;
        24:
          begin
            Pos := RowPos + NativeUInt(X) * 3;
            C.B := InBuf[Pos];
            C.G := InBuf[Pos + 1];
            C.R := InBuf[Pos + 2];
          end;
        32:
          begin
            Pos := RowPos + NativeUInt(X) * 4;
            if Compression = BI_RGB then
            begin
              C.B := InBuf[Pos];
              C.G := InBuf[Pos + 1];
              C.R := InBuf[Pos + 2];
              C.A := 255;
            end
            else
            begin
              V32 := ReadLE32(@InBuf[Pos]);
              C.R := ScaleMask(V32, RMask, 0);
              C.G := ScaleMask(V32, GMask, 0);
              C.B := ScaleMask(V32, BMask, 0);
              C.A := ScaleMask(V32, AMask, 255);
            end;
          end;
      end;
      SetPx(Result, Integer(W), Integer(X), Integer(DstY), C);
      Inc(X);
    end;
    Inc(FileY);
  end;
end;

function EncodeBmp(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  RowBits64, Stride64, ImageSize64, FileSize64: UInt64;
  Stride: NativeUInt;
  PixelOffset: Cardinal;
  X, Y, SrcY: Integer;
  RowPos, Pos: NativeUInt;
  C: TRGBA;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then
    raise EBmpError.Create('BMP: image dimensions must be non-zero');
  if (Width > High(LongInt)) or (Height > High(LongInt)) then
    raise EBmpError.Create('BMP: image dimensions are too large');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EBmpError.Create('BMP: RGBA8 buffer size does not match Width*Height*4');

  RowBits64 := UInt64(Width) * 24;
  Stride64 := ((RowBits64 + 31) div 32) * 4;
  ImageSize64 := Stride64 * UInt64(Height);
  PixelOffset := BMP_FILE_HEADER_SIZE + BMP_INFO_HEADER_SIZE;
  FileSize64 := UInt64(PixelOffset) + ImageSize64;
  if (Stride64 > UInt64(High(NativeUInt))) or
     (ImageSize64 > UInt64(High(Cardinal))) or
     (FileSize64 > UInt64(High(Cardinal))) or
     (FileSize64 > UInt64(High(NativeInt))) then
    raise EBmpError.Create('BMP: image is too large');
  Stride := NativeUInt(Stride64);

  SetLength(Result, NativeInt(FileSize64));
  FillChar(Result[0], Length(Result), 0);
  Result[0] := Ord('B');
  Result[1] := Ord('M');
  PutLE32(Result, 2, Cardinal(FileSize64));
  PutLE32(Result, 10, PixelOffset);
  PutLE32(Result, 14, BMP_INFO_HEADER_SIZE);
  PutLE32(Result, 18, Cardinal(Width));
  PutLE32(Result, 22, Cardinal(Height));
  PutLE16(Result, 26, 1);
  PutLE16(Result, 28, 24);
  PutLE32(Result, 30, BI_RGB);
  PutLE32(Result, 34, Cardinal(ImageSize64));
  PutLE32(Result, 38, 2835);
  PutLE32(Result, 42, 2835);

  Y := 0;
  while Y < Height do
  begin
    SrcY := Height - 1 - Y;
    RowPos := NativeUInt(PixelOffset) + NativeUInt(Y) * Stride;
    X := 0;
    while X < Width do
    begin
      C := GetPx(InBuf, Width, X, SrcY);
      Pos := RowPos + NativeUInt(X) * 3;
      Result[Pos] := C.B;
      Result[Pos + 1] := C.G;
      Result[Pos + 2] := C.R;
      Inc(X);
    end;
    Inc(Y);
  end;
end;

end.
