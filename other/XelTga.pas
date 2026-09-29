unit XelTga;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, XelPng;

type
  ETgaError = class(Exception);

function DecodeTga(InBuf: TBytes; out Width, Height: Integer): TBytes; // RGBA8
function EncodeTga(InBuf: TBytes; Width, Height: Integer): TBytes;      // InBuf = RGBA8

implementation

const
  TGA_HEADER_SIZE = 18;
  TGA_FOOTER_SIZE = 26;

function ReadLE16(P: PByte): Word; inline;
begin
  Result := Word(P[0]) or (Word(P[1]) shl 8);
end;

procedure PutLE16(P: PByte; V: Word); inline;
begin
  P[0] := Byte(V);
  P[1] := Byte(V shr 8);
end;

procedure Need(const Data: TBytes; Pos, Count: NativeUInt); inline;
var
  L: NativeUInt;
begin
  L := NativeUInt(Length(Data));
  if (Pos > L) or (Count > L - Pos) then
    raise ETgaError.Create('TGA: truncated file');
end;

function Scale5To8(V: Cardinal): Byte; inline;
begin
  Result := Byte((V * 255 + 15) div 31);
end;

function DecodePaletteEntry(P: PByte; Bits: Byte): TRGBA;
var
  V: Word;
begin
  Result.R := 0;
  Result.G := 0;
  Result.B := 0;
  Result.A := 255;

  case Bits of
    8:
      begin
        Result.R := P[0];
        Result.G := P[0];
        Result.B := P[0];
      end;
    15:
      begin
        V := ReadLE16(P);
        Result.B := Scale5To8(V and $1F);
        Result.G := Scale5To8((V shr 5) and $1F);
        Result.R := Scale5To8((V shr 10) and $1F);
      end;
    16:
      begin
        V := ReadLE16(P);
        Result.B := Scale5To8(V and $1F);
        Result.G := Scale5To8((V shr 5) and $1F);
        Result.R := Scale5To8((V shr 10) and $1F);
        if (V and $8000) <> 0 then Result.A := 255 else Result.A := 0;
      end;
    24:
      begin
        Result.B := P[0];
        Result.G := P[1];
        Result.R := P[2];
      end;
    32:
      begin
        Result.B := P[0];
        Result.G := P[1];
        Result.R := P[2];
        Result.A := P[3];
      end;
  else
    raise ETgaError.CreateFmt('TGA: unsupported color-map entry size %d', [Bits]);
  end;
end;

function DecodeTga(InBuf: TBytes; out Width, Height: Integer): TBytes;
type
  TPalette = array of TRGBA;
var
  IDLength, ColorMapType, ImageType: Byte;
  CMapFirst, CMapLength: Word;
  CMapDepth: Byte;
  W, H: Word;
  PixelDepth, Descriptor, BaseType: Byte;
  AttrBits: Byte;
  TopOrigin, RightOrigin, IsRLE: Boolean;
  Pos, EntryBytes, PixelBytes, Total, Seq: NativeUInt;
  Palette: TPalette;
  I, PacketCount, K: NativeUInt;
  Header: Byte;
  C: TRGBA;

  function ReadOnePixel: TRGBA;
  var
    V, MapIndex: Word;
    RelIndex: Integer;
  begin
    Result.R := 0;
    Result.G := 0;
    Result.B := 0;
    Result.A := 255;

    Need(InBuf, Pos, PixelBytes);

    case BaseType of
      1: // color mapped
        begin
          if PixelDepth = 8 then
            MapIndex := InBuf[Pos]
          else if PixelDepth = 16 then
            MapIndex := ReadLE16(@InBuf[Pos])
          else
            raise ETgaError.CreateFmt('TGA: unsupported color-map index depth %d', [PixelDepth]);

          RelIndex := Integer(MapIndex) - Integer(CMapFirst);
          if (RelIndex < 0) or (RelIndex >= Length(Palette)) then
            raise ETgaError.CreateFmt('TGA: palette index %d out of range', [MapIndex]);
          Result := Palette[RelIndex];
        end;

      2: // true color
        case PixelDepth of
          15:
            begin
              V := ReadLE16(@InBuf[Pos]);
              Result.B := Scale5To8(V and $1F);
              Result.G := Scale5To8((V shr 5) and $1F);
              Result.R := Scale5To8((V shr 10) and $1F);
            end;
          16:
            begin
              V := ReadLE16(@InBuf[Pos]);
              Result.B := Scale5To8(V and $1F);
              Result.G := Scale5To8((V shr 5) and $1F);
              Result.R := Scale5To8((V shr 10) and $1F);
              if AttrBits <> 0 then
              begin
                if (V and $8000) <> 0 then Result.A := 255 else Result.A := 0;
              end;
            end;
          24:
            begin
              Result.B := InBuf[Pos];
              Result.G := InBuf[Pos + 1];
              Result.R := InBuf[Pos + 2];
            end;
          32:
            begin
              Result.B := InBuf[Pos];
              Result.G := InBuf[Pos + 1];
              Result.R := InBuf[Pos + 2];
              if AttrBits <> 0 then Result.A := InBuf[Pos + 3]
              else Result.A := 255;
            end;
        else
          raise ETgaError.CreateFmt('TGA: unsupported true-color depth %d', [PixelDepth]);
        end;

      3: // grayscale
        case PixelDepth of
          8:
            begin
              Result.R := InBuf[Pos];
              Result.G := InBuf[Pos];
              Result.B := InBuf[Pos];
            end;
          16:
            begin
              Result.R := InBuf[Pos];
              Result.G := InBuf[Pos];
              Result.B := InBuf[Pos];
              Result.A := InBuf[Pos + 1];
            end;
        else
          raise ETgaError.CreateFmt('TGA: unsupported grayscale depth %d', [PixelDepth]);
        end;
    end;

    Inc(Pos, PixelBytes);
  end;

  procedure PutPixel(Index: NativeUInt; const Color: TRGBA);
  var
    FileX, FileY, X, Y: NativeUInt;
  begin
    FileY := Index div NativeUInt(W);
    FileX := Index - FileY * NativeUInt(W);

    if RightOrigin then X := NativeUInt(W) - 1 - FileX
    else X := FileX;

    if TopOrigin then Y := FileY
    else Y := NativeUInt(H) - 1 - FileY;

    SetPx(Result, Integer(W), Integer(X), Integer(Y), Color);
  end;

begin
  Width := 0;
  Height := 0;
  SetLength(Result, 0);
  SetLength(Palette, 0);

  Need(InBuf, 0, TGA_HEADER_SIZE);

  IDLength := InBuf[0];
  ColorMapType := InBuf[1];
  ImageType := InBuf[2];
  CMapFirst := ReadLE16(@InBuf[3]);
  CMapLength := ReadLE16(@InBuf[5]);
  CMapDepth := InBuf[7];
  W := ReadLE16(@InBuf[12]);
  H := ReadLE16(@InBuf[14]);
  PixelDepth := InBuf[16];
  Descriptor := InBuf[17];
  AttrBits := Descriptor and $0F;

  if (W = 0) or (H = 0) then
    raise ETgaError.Create('TGA: invalid image dimensions');
  if ColorMapType > 1 then
    raise ETgaError.CreateFmt('TGA: unsupported color-map type %d', [ColorMapType]);
  if (Descriptor and $C0) <> 0 then
    raise ETgaError.Create('TGA: interleaved images are not supported');

  case ImageType of
    1: begin BaseType := 1; IsRLE := False; end;
    2: begin BaseType := 2; IsRLE := False; end;
    3: begin BaseType := 3; IsRLE := False; end;
    9: begin BaseType := 1; IsRLE := True; end;
    10: begin BaseType := 2; IsRLE := True; end;
    11: begin BaseType := 3; IsRLE := True; end;
  else
    raise ETgaError.CreateFmt('TGA: unsupported image type %d', [ImageType]);
  end;

  if (BaseType = 1) and (ColorMapType <> 1) then
    raise ETgaError.Create('TGA: color-mapped image without a color map');

  case BaseType of
    1:
      if not (PixelDepth in [8, 16]) then
        raise ETgaError.CreateFmt('TGA: unsupported palette index depth %d', [PixelDepth]);
    2:
      if not (PixelDepth in [15, 16, 24, 32]) then
        raise ETgaError.CreateFmt('TGA: unsupported true-color depth %d', [PixelDepth]);
    3:
      if not (PixelDepth in [8, 16]) then
        raise ETgaError.CreateFmt('TGA: unsupported grayscale depth %d', [PixelDepth]);
  end;

  Pos := TGA_HEADER_SIZE;
  Need(InBuf, Pos, IDLength);
  Inc(Pos, IDLength);

  if ColorMapType = 1 then
  begin
    if CMapLength = 0 then
      raise ETgaError.Create('TGA: empty color map');
    if not (CMapDepth in [8, 15, 16, 24, 32]) then
      raise ETgaError.CreateFmt('TGA: unsupported color-map entry size %d', [CMapDepth]);

    EntryBytes := (NativeUInt(CMapDepth) + 7) div 8;
    if NativeUInt(CMapLength) > High(NativeUInt) div EntryBytes then
      raise ETgaError.Create('TGA: color map is too large');
    Need(InBuf, Pos, NativeUInt(CMapLength) * EntryBytes);

    SetLength(Palette, CMapLength);
    I := 0;
    while I < NativeUInt(CMapLength) do
    begin
      Palette[I] := DecodePaletteEntry(@InBuf[Pos], CMapDepth);
      Inc(Pos, EntryBytes);
      Inc(I);
    end;
  end;

  PixelBytes := (NativeUInt(PixelDepth) + 7) div 8;
  if PixelBytes = 0 then
    raise ETgaError.Create('TGA: invalid pixel size');

  Width := Integer(W);
  Height := Integer(H);
  SetLength(Result, NativeInt(UInt64(W) * UInt64(H) * 4));

  TopOrigin := (Descriptor and $20) <> 0;
  RightOrigin := (Descriptor and $10) <> 0;

  Total := NativeUInt(W) * NativeUInt(H);
  Seq := 0;

  if not IsRLE then
  begin
    while Seq < Total do
    begin
      C := ReadOnePixel;
      PutPixel(Seq, C);
      Inc(Seq);
    end;
  end
  else
  begin
    while Seq < Total do
    begin
      Need(InBuf, Pos, 1);
      Header := InBuf[Pos];
      Inc(Pos);
      PacketCount := NativeUInt(Header and $7F) + 1;
      if PacketCount > Total - Seq then
        raise ETgaError.Create('TGA: RLE packet exceeds image size');

      if (Header and $80) <> 0 then
      begin
        C := ReadOnePixel;
        K := 0;
        while K < PacketCount do
        begin
          PutPixel(Seq, C);
          Inc(Seq);
          Inc(K);
        end;
      end
      else
      begin
        K := 0;
        while K < PacketCount do
        begin
          C := ReadOnePixel;
          PutPixel(Seq, C);
          Inc(Seq);
          Inc(K);
        end;
      end;
    end;
  end;
end;

function SameStoredPixel(const A, B: TRGBA; WriteAlpha: Boolean): Boolean; inline;
begin
  Result := (A.R = B.R) and (A.G = B.G) and (A.B = B.B);
  if Result and WriteAlpha then
    Result := A.A = B.A;
end;

function EncodeTga(InBuf: TBytes; Width, Height: Integer): TBytes;
const
  RLE = True;
  WriteAlpha = True;
var
  S: TMemoryStream;
  Header: array[0..TGA_HEADER_SIZE - 1] of Byte;
  Footer: array[0..TGA_FOOTER_SIZE - 1] of Byte;
  PixelDepth, Descriptor, PacketHeader: Byte;
  Total, I, RunLen, RawStart, RawCount, J: NativeUInt;
  C, D: TRGBA;
  Sig: AnsiString;

  function PixelAt(Index: NativeUInt): TRGBA; inline;
  var
    X, Y: NativeUInt;
  begin
    Y := Index div NativeUInt(Width);
    X := Index - Y * NativeUInt(Width);
    Result := GetPx(InBuf, Width, Integer(X), Integer(Y));
  end;

  procedure WriteByte(V: Byte); inline;
  begin
    S.WriteBuffer(V, 1);
  end;

  procedure WritePixel(const P: TRGBA); inline;
  begin
    WriteByte(P.B);
    WriteByte(P.G);
    WriteByte(P.R);
    if WriteAlpha then WriteByte(P.A);
  end;

begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then
    raise ETgaError.Create('TGA: image is empty');
  if (Width > 65535) or (Height > 65535) then
    raise ETgaError.Create('TGA: dimensions exceed 65535');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise ETgaError.Create('TGA: RGBA8 buffer size does not match Width*Height*4');

  FillChar(Header, SizeOf(Header), 0);
  FillChar(Footer, SizeOf(Footer), 0);

  if WriteAlpha then
  begin
    PixelDepth := 32;
    Descriptor := $20 or 8; // top-left origin + 8 attribute bits
  end
  else
  begin
    PixelDepth := 24;
    Descriptor := $20;      // top-left origin
  end;

  if RLE then Header[2] := 10 else Header[2] := 2;
  PutLE16(@Header[12], Word(Width));
  PutLE16(@Header[14], Word(Height));
  Header[16] := PixelDepth;
  Header[17] := Descriptor;

  S := TMemoryStream.Create;
  try
    S.WriteBuffer(Header, SizeOf(Header));
    Total := NativeUInt(Width) * NativeUInt(Height);

    if not RLE then
    begin
      I := 0;
      while I < Total do
      begin
        C := PixelAt(I);
        WritePixel(C);
        Inc(I);
      end;
    end
    else
    begin
      I := 0;
      while I < Total do
      begin
        C := PixelAt(I);
        RunLen := 1;
        while (RunLen < 128) and (I + RunLen < Total) do
        begin
          D := PixelAt(I + RunLen);
          if not SameStoredPixel(C, D, WriteAlpha) then Break;
          Inc(RunLen);
        end;

        if RunLen >= 2 then
        begin
          PacketHeader := $80 or Byte(RunLen - 1);
          WriteByte(PacketHeader);
          WritePixel(C);
          Inc(I, RunLen);
        end
        else
        begin
          RawStart := I;
          RawCount := 1;
          Inc(I);

          while (RawCount < 128) and (I < Total) do
          begin
            C := PixelAt(I);
            RunLen := 1;
            while (RunLen < 2) and (I + RunLen < Total) do
            begin
              D := PixelAt(I + RunLen);
              if not SameStoredPixel(C, D, WriteAlpha) then Break;
              Inc(RunLen);
            end;
            if RunLen >= 2 then Break;
            Inc(RawCount);
            Inc(I);
          end;

          PacketHeader := Byte(RawCount - 1);
          WriteByte(PacketHeader);
          J := 0;
          while J < RawCount do
          begin
            C := PixelAt(RawStart + J);
            WritePixel(C);
            Inc(J);
          end;
        end;
      end;
    end;

    // TGA 2.0 footer: extension offset=0, developer offset=0,
    // signature="TRUEVISION-XFILE." + NUL.
    Sig := 'TRUEVISION-XFILE.';
    Move(Sig[1], Footer[8], Length(Sig));
    Footer[25] := 0;
    S.WriteBuffer(Footer, SizeOf(Footer));

    if S.Size > 0 then
    begin
      SetLength(Result, NativeInt(S.Size));
      S.Position := 0;
      S.ReadBuffer(Result[0], Length(Result));
    end;
  finally
    S.Free;
  end;
end;

end.
