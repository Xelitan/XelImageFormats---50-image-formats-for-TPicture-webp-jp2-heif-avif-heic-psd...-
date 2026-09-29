unit XelPng;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, XelInflate, XelDeflate;

type
  EPngError = class(Exception);

  TRGBA = record
    R, G, B, A: Byte;
  end;

// Dostep do piksela w plaskim buforze RGBA8: Buf[(Y*W + X)*4 + 0..3].
procedure SetPx(var Buf: TBytes; W, X, Y: Integer; const C: TRGBA); inline;
function GetPx(const Buf: TBytes; W, X, Y: Integer): TRGBA; inline;

function DecodePng(InBuf: TBytes; out Width, Height: Integer): TBytes; // RGBA8
function EncodePng(InBuf: TBytes; Width, Height: Integer; Level: Integer = 6): TBytes; // InBuf = RGBA8, Level 0..9 (zlib)

implementation

procedure SetPx(var Buf: TBytes; W, X, Y: Integer; const C: TRGBA); inline;
var
  I: NativeUInt;
begin
  I := (NativeUInt(Y) * NativeUInt(W) + NativeUInt(X)) * 4;
  Buf[I] := C.R;
  Buf[I + 1] := C.G;
  Buf[I + 2] := C.B;
  Buf[I + 3] := C.A;
end;

function GetPx(const Buf: TBytes; W, X, Y: Integer): TRGBA; inline;
var
  I: NativeUInt;
begin
  I := (NativeUInt(Y) * NativeUInt(W) + NativeUInt(X)) * 4;
  Result.R := Buf[I];
  Result.G := Buf[I + 1];
  Result.B := Buf[I + 2];
  Result.A := Buf[I + 3];
end;

const
  PngSignature: array[0..7] of Byte = ($89,$50,$4E,$47,$0D,$0A,$1A,$0A);
  Adam7X0: array[0..6] of Integer = (0,4,0,2,0,1,0);
  Adam7Y0: array[0..6] of Integer = (0,0,4,0,2,0,1);
  Adam7DX: array[0..6] of Integer = (8,8,4,4,2,2,1);
  Adam7DY: array[0..6] of Integer = (8,8,8,4,4,2,2);

type
  TChunkName = array[0..3] of AnsiChar;

function ReadBE32(P: PByte): Cardinal; inline;
begin
  Result := (Cardinal(P[0]) shl 24) or (Cardinal(P[1]) shl 16) or
            (Cardinal(P[2]) shl 8) or Cardinal(P[3]);
end;

function ReadBE16(P: PByte): Word; inline;
begin
  Result := (Word(P[0]) shl 8) or Word(P[1]);
end;

procedure PutBE32(var A: TBytes; Pos: NativeUInt; V: Cardinal); inline;
begin
  A[Pos] := Byte(V shr 24);
  A[Pos + 1] := Byte(V shr 16);
  A[Pos + 2] := Byte(V shr 8);
  A[Pos + 3] := Byte(V);
end;

function ChunkEq(P: PByte; const S: AnsiString): Boolean; inline;
begin
  Result := (Length(S) = 4) and
            (P[0] = Byte(S[1])) and (P[1] = Byte(S[2])) and
            (P[2] = Byte(S[3])) and (P[3] = Byte(S[4]));
end;

function ChunkNameString(P: PByte): string; inline;
begin
  SetLength(Result, 4);
  Result[1] := Char(P[0]);
  Result[2] := Char(P[1]);
  Result[3] := Char(P[2]);
  Result[4] := Char(P[3]);
end;

function CRC32Buf(P: PByte; Len: NativeUInt): Cardinal;
var
  C: Cardinal;
  I, J: NativeUInt;
begin
  C := $FFFFFFFF;
  for I := 0 to Len - 1 do
  begin
    C := C xor P[I];
    for J := 0 to 7 do
      if (C and 1) <> 0 then C := (C shr 1) xor $EDB88320
      else C := C shr 1;
  end;
  Result := not C;
end;

procedure AppendBytes(var Dst: TBytes; Src: PByte; Count: NativeUInt);
var
  Old: NativeUInt;
begin
  if Count = 0 then Exit;
  Old := Length(Dst);
  SetLength(Dst, Old + Count);
  Move(Src^, Dst[Old], Count);
end;

procedure AppendChunk(var OutData: TBytes; const Name: AnsiString; const Payload: TBytes);
var
  Old, N: NativeUInt;
  C: Cardinal;
begin
  if Length(Name) <> 4 then
    raise EPngError.Create('PNG: invalid chunk name');
  Old := Length(OutData);
  N := Length(Payload);
  SetLength(OutData, Old + 12 + N);
  PutBE32(OutData, Old, Cardinal(N));
  OutData[Old + 4] := Byte(Name[1]);
  OutData[Old + 5] := Byte(Name[2]);
  OutData[Old + 6] := Byte(Name[3]);
  OutData[Old + 7] := Byte(Name[4]);
  if N <> 0 then Move(Payload[0], OutData[Old + 8], N);
  C := CRC32Buf(@OutData[Old + 4], N + 4);
  PutBE32(OutData, Old + 8 + N, C);
end;

function ChannelsForColor(ColorType: Byte): Integer;
begin
  case ColorType of
    0: Result := 1;
    2: Result := 3;
    3: Result := 1;
    4: Result := 2;
    6: Result := 4;
  else
    Result := 0;
  end;
end;

function ValidBitDepth(ColorType, BitDepth: Byte): Boolean;
begin
  case ColorType of
    0: Result := BitDepth in [1,2,4,8,16];
    2: Result := BitDepth in [8,16];
    3: Result := BitDepth in [1,2,4,8];
    4: Result := BitDepth in [8,16];
    6: Result := BitDepth in [8,16];
  else
    Result := False;
  end;
end;

function Paeth(A, B, C: Integer): Integer; inline;
var
  P, PA, PB, PC: Integer;
begin
  P := A + B - C;
  PA := Abs(P - A);
  PB := Abs(P - B);
  PC := Abs(P - C);
  if (PA <= PB) and (PA <= PC) then Result := A
  else if PB <= PC then Result := B
  else Result := C;
end;

procedure UnfilterRow(Filter: Byte; Cur, Prev: PByte; RowBytes, Bpp: NativeUInt);
var
  X: NativeUInt;
  A, B, C: Integer;
begin
  case Filter of
    0: ;
    1:
      for X := 0 to RowBytes - 1 do
      begin
        if X >= Bpp then A := Cur[X - Bpp] else A := 0;
        Cur[X] := Byte((Integer(Cur[X]) + A) and $FF);
      end;
    2:
      if Prev <> nil then
        for X := 0 to RowBytes - 1 do
          Cur[X] := Byte((Integer(Cur[X]) + Prev[X]) and $FF);
    3:
      for X := 0 to RowBytes - 1 do
      begin
        if X >= Bpp then A := Cur[X - Bpp] else A := 0;
        if Prev <> nil then B := Prev[X] else B := 0;
        Cur[X] := Byte((Integer(Cur[X]) + ((A + B) shr 1)) and $FF);
      end;
    4:
      for X := 0 to RowBytes - 1 do
      begin
        if X >= Bpp then A := Cur[X - Bpp] else A := 0;
        if Prev <> nil then B := Prev[X] else B := 0;
        if (Prev <> nil) and (X >= Bpp) then C := Prev[X - Bpp] else C := 0;
        Cur[X] := Byte((Integer(Cur[X]) + Paeth(A, B, C)) and $FF);
      end;
  else
    raise EPngError.CreateFmt('PNG: invalid filter %d', [Filter]);
  end;
end;

function ReadSample(Row: PByte; BitDepth: Byte; SampleIndex: NativeUInt): Word; inline;
var
  BitPos, BytePos: NativeUInt;
  Shift: Integer;
begin
  case BitDepth of
    8: Result := Row[SampleIndex];
    16: Result := ReadBE16(@Row[SampleIndex * 2]);
  else
    begin
      BitPos := SampleIndex * BitDepth;
      BytePos := BitPos shr 3;
      Shift := 8 - BitDepth - Integer(BitPos and 7);
      Result := (Row[BytePos] shr Shift) and ((1 shl BitDepth) - 1);
    end;
  end;
end;

function SampleTo8(V: Word; BitDepth: Byte): Byte; inline;
var
  M: Cardinal;
begin
  if BitDepth = 8 then Exit(Byte(V));
  if BitDepth = 16 then Exit(Byte(V shr 8));
  M := (Cardinal(1) shl BitDepth) - 1;
  Result := Byte((Cardinal(V) * 255 + (M shr 1)) div M);
end;

procedure DecodePass(const Raw: TBytes; var RawPos: NativeUInt; var Img: TBytes;
  ImgW: Integer; PassW, PassH: Cardinal; X0, Y0, DX, DY: Integer; ColorType, BitDepth: Byte;
  const Palette, Trns: TBytes; TrGray, TrR, TrG, TrB: Word; HasTrns: Boolean);
var
  Channels, BitsPerPixel: Integer;
  RowBytes, Bpp: NativeUInt;
  PrevRow, CurRow: TBytes;
  Y, X: Cardinal;
  Src: PByte;
  S0, S1, S2, S3: Word;
  R, G, B, A: Byte;
  PI: NativeUInt;
  PaletteCount: NativeUInt;
begin
  if (PassW = 0) or (PassH = 0) then Exit;
  Channels := ChannelsForColor(ColorType);
  BitsPerPixel := Channels * BitDepth;
  RowBytes := (NativeUInt(PassW) * NativeUInt(BitsPerPixel) + 7) div 8;
  Bpp := (BitsPerPixel + 7) div 8;
  if Bpp = 0 then Bpp := 1;
  SetLength(PrevRow, RowBytes);
  SetLength(CurRow, RowBytes);
  if RowBytes <> 0 then FillChar(PrevRow[0], RowBytes, 0);
  PaletteCount := Length(Palette) div 3;

  for Y := 0 to PassH - 1 do
  begin
    if RawPos >= NativeUInt(Length(Raw)) then
      raise EPngError.Create('PNG: truncated inflated image data');
    if RawPos + 1 + RowBytes > NativeUInt(Length(Raw)) then
      raise EPngError.Create('PNG: truncated scanline');
    Src := @Raw[RawPos + 1];
    if RowBytes <> 0 then Move(Src^, CurRow[0], RowBytes);
    if Y = 0 then
      UnfilterRow(Raw[RawPos], @CurRow[0], nil, RowBytes, Bpp)
    else
      UnfilterRow(Raw[RawPos], @CurRow[0], @PrevRow[0], RowBytes, Bpp);
    Inc(RawPos, 1 + RowBytes);

    for X := 0 to PassW - 1 do
    begin
      R := 0; G := 0; B := 0; A := 255;
      case ColorType of
        0:
          begin
            S0 := ReadSample(@CurRow[0], BitDepth, X);
            R := SampleTo8(S0, BitDepth); G := R; B := R;
            if HasTrns and (S0 = TrGray) then A := 0;
          end;
        2:
          begin
            PI := NativeUInt(X) * 3;
            S0 := ReadSample(@CurRow[0], BitDepth, PI);
            S1 := ReadSample(@CurRow[0], BitDepth, PI + 1);
            S2 := ReadSample(@CurRow[0], BitDepth, PI + 2);
            R := SampleTo8(S0, BitDepth);
            G := SampleTo8(S1, BitDepth);
            B := SampleTo8(S2, BitDepth);
            if HasTrns and (S0 = TrR) and (S1 = TrG) and (S2 = TrB) then A := 0;
          end;
        3:
          begin
            S0 := ReadSample(@CurRow[0], BitDepth, X);
            if S0 >= PaletteCount then
              raise EPngError.Create('PNG: palette index out of range');
            PI := NativeUInt(S0) * 3;
            R := Palette[PI]; G := Palette[PI + 1]; B := Palette[PI + 2];
            if NativeUInt(S0) < NativeUInt(Length(Trns)) then A := Trns[S0];
          end;
        4:
          begin
            PI := NativeUInt(X) * 2;
            S0 := ReadSample(@CurRow[0], BitDepth, PI);
            S1 := ReadSample(@CurRow[0], BitDepth, PI + 1);
            R := SampleTo8(S0, BitDepth); G := R; B := R; A := SampleTo8(S1, BitDepth);
          end;
        6:
          begin
            PI := NativeUInt(X) * 4;
            S0 := ReadSample(@CurRow[0], BitDepth, PI);
            S1 := ReadSample(@CurRow[0], BitDepth, PI + 1);
            S2 := ReadSample(@CurRow[0], BitDepth, PI + 2);
            S3 := ReadSample(@CurRow[0], BitDepth, PI + 3);
            R := SampleTo8(S0, BitDepth); G := SampleTo8(S1, BitDepth);
            B := SampleTo8(S2, BitDepth); A := SampleTo8(S3, BitDepth);
          end;
      end;
      PI := (NativeUInt(Y0 + Integer(Y) * DY) * NativeUInt(ImgW) +
             NativeUInt(X0 + Integer(X) * DX)) * 4;
      Img[PI] := R;
      Img[PI + 1] := G;
      Img[PI + 2] := B;
      Img[PI + 3] := A;
    end;
    if RowBytes <> 0 then Move(CurRow[0], PrevRow[0], RowBytes);
  end;
end;

function PassSize(Total: Cardinal; Start, Step: Integer): Cardinal; inline;
begin
  if Total <= Cardinal(Start) then Result := 0
  else Result := (Total - Cardinal(Start) + Cardinal(Step) - 1) div Cardinal(Step);
end;

function DecodePng(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Pos, N, InBufPos: NativeUInt;
  ChunkLen, StoredCRC, CalcCRC: Cardinal;
  P: PByte;
  W, H: Cardinal;
  BitDepth, ColorType, Compression, FilterMethod, Interlace: Byte;
  Palette, Trns, IDAT, Inflated: TBytes;
  SeenIHDR, SeenIEND: Boolean;
  TrGray, TrR, TrG, TrB: Word;
  HasTrns: Boolean;
  PixelsLen: UInt64;
  Pass, X0, Y0, DX, DY: Integer;
  PW, PH: Cardinal;
begin
  Width := 0;
  Height := 0;
  SetLength(Result, 0);
  if Length(InBuf) < 8 then raise EPngError.Create('PNG: file too small');
  for Pos := 0 to 7 do
    if InBuf[Pos] <> PngSignature[Pos] then
      raise EPngError.Create('PNG: bad signature');

  Pos := 8;
  SeenIHDR := False;
  SeenIEND := False;
  W := 0; H := 0; BitDepth := 0; ColorType := 0;
  Compression := 0; FilterMethod := 0; Interlace := 0;
  TrGray := 0; TrR := 0; TrG := 0; TrB := 0; HasTrns := False;

  while Pos + 12 <= NativeUInt(Length(InBuf)) do
  begin
    ChunkLen := ReadBE32(@InBuf[Pos]);
    N := NativeUInt(ChunkLen);
    if N > NativeUInt(Length(InBuf)) - Pos - 12 then
      raise EPngError.Create('PNG: chunk exceeds file');
    P := @InBuf[Pos + 4];
    InBufPos := Pos + 8;
    StoredCRC := ReadBE32(@InBuf[InBufPos + N]);
    CalcCRC := CRC32Buf(P, N + 4);
    if StoredCRC <> CalcCRC then
      raise EPngError.Create('PNG: CRC mismatch');

    if ChunkEq(P, 'IHDR') then
    begin
      if SeenIHDR or (Pos <> 8) or (N <> 13) then
        raise EPngError.Create('PNG: invalid IHDR');
      W := ReadBE32(@InBuf[InBufPos]);
      H := ReadBE32(@InBuf[InBufPos + 4]);
      BitDepth := InBuf[InBufPos + 8];
      ColorType := InBuf[InBufPos + 9];
      Compression := InBuf[InBufPos + 10];
      FilterMethod := InBuf[InBufPos + 11];
      Interlace := InBuf[InBufPos + 12];
      if (W = 0) or (H = 0) then raise EPngError.Create('PNG: zero image size');
      if not ValidBitDepth(ColorType, BitDepth) then raise EPngError.Create('PNG: unsupported color type/bit depth');
      if (Compression <> 0) or (FilterMethod <> 0) or not (Interlace in [0,1]) then
        raise EPngError.Create('PNG: unsupported PNG method');
      SeenIHDR := True;
    end
    else if ChunkEq(P, 'PLTE') then
    begin
      if not SeenIHDR or (N = 0) or ((N mod 3) <> 0) or (N > 768) then
        raise EPngError.Create('PNG: invalid PLTE');
      SetLength(Palette, N);
      Move(InBuf[InBufPos], Palette[0], N);
    end
    else if ChunkEq(P, 'tRNS') then
    begin
      if not SeenIHDR then raise EPngError.Create('PNG: tRNS before IHDR');
      case ColorType of
        0:
          begin
            if N <> 2 then raise EPngError.Create('PNG: invalid grayscale tRNS');
            TrGray := ReadBE16(@InBuf[InBufPos]); HasTrns := True;
          end;
        2:
          begin
            if N <> 6 then raise EPngError.Create('PNG: invalid RGB tRNS');
            TrR := ReadBE16(@InBuf[InBufPos]);
            TrG := ReadBE16(@InBuf[InBufPos + 2]);
            TrB := ReadBE16(@InBuf[InBufPos + 4]); HasTrns := True;
          end;
        3:
          begin
            SetLength(Trns, N);
            if N <> 0 then Move(InBuf[InBufPos], Trns[0], N);
          end;
      else
        raise EPngError.Create('PNG: tRNS not allowed for this color type');
      end;
    end
    else if ChunkEq(P, 'IDAT') then
    begin
      if not SeenIHDR then raise EPngError.Create('PNG: IDAT before IHDR');
      if N <> 0 then AppendBytes(IDAT, @InBuf[InBufPos], N);
    end
    else if ChunkEq(P, 'IEND') then
    begin
      if N <> 0 then raise EPngError.Create('PNG: invalid IEND');
      SeenIEND := True;
      Break;
    end
    else
    begin
      // Unknown critical chunk (uppercase first letter) cannot safely be ignored.
      if (P[0] and $20) = 0 then
        raise EPngError.CreateFmt('PNG: unsupported critical chunk %s', [ChunkNameString(P)]);
    end;
    Inc(Pos, 12 + N);
  end;

  if not SeenIHDR or not SeenIEND then raise EPngError.Create('PNG: incomplete file');
  if (ColorType = 3) and (Length(Palette) = 0) then raise EPngError.Create('PNG: indexed image has no palette');
  if (ColorType = 3) and ((Length(Palette) div 3) > (1 shl BitDepth)) then
    raise EPngError.Create('PNG: palette is too large for indexed bit depth');
  if (ColorType = 3) and (Length(Trns) > (Length(Palette) div 3)) then
    raise EPngError.Create('PNG: tRNS is longer than palette');
  if Length(IDAT) = 0 then raise EPngError.Create('PNG: missing IDAT');

  PixelsLen := UInt64(W) * UInt64(H) * 4;
  if PixelsLen > UInt64(High(NativeInt)) then
    raise EPngError.Create('PNG: image too large');
  if (UInt64(W) > UInt64(High(Integer))) or
     (UInt64(H) > UInt64(High(Integer))) then
    raise EPngError.Create('PNG: image dimensions are too large');

  Width := Integer(W);
  Height := Integer(H);
  SetLength(Result, NativeInt(PixelsLen));

  Inflated := InflateZlib(@IDAT[0], Length(IDAT));
  Pos := 0;
  if Interlace = 0 then
    DecodePass(Inflated, Pos, Result, Integer(W), W, H, 0, 0, 1, 1,
      ColorType, BitDepth, Palette, Trns, TrGray, TrR, TrG, TrB, HasTrns)
  else
    for Pass := 0 to 6 do
    begin
      X0 := Adam7X0[Pass]; Y0 := Adam7Y0[Pass];
      DX := Adam7DX[Pass]; DY := Adam7DY[Pass];
      PW := PassSize(W, X0, DX);
      PH := PassSize(H, Y0, DY);
      DecodePass(Inflated, Pos, Result, Integer(W), PW, PH, X0, Y0, DX, DY,
        ColorType, BitDepth, Palette, Trns, TrGray, TrR, TrG, TrB, HasTrns);
    end;
  if Pos <> NativeUInt(Length(Inflated)) then
    raise EPngError.Create('PNG: unexpected extra inflated data');
end;

function FilterScore(P: PByte; Count: NativeUInt): UInt64;
var
  I: NativeUInt;
  V: Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
  begin
    V := P[I];
    if V > 127 then V := 256 - V;
    Inc(Result, V);
  end;
end;

procedure MakeFiltered(Filter: Byte; Src, Prev, Dst: PByte; Count, Bpp: NativeUInt);
var
  X: NativeUInt;
  A, B, C, Pred: Integer;
begin
  for X := 0 to Count - 1 do
  begin
    if X >= Bpp then A := Src[X - Bpp] else A := 0;
    if Prev <> nil then B := Prev[X] else B := 0;
    if (Prev <> nil) and (X >= Bpp) then C := Prev[X - Bpp] else C := 0;
    case Filter of
      0: Pred := 0;
      1: Pred := A;
      2: Pred := B;
      3: Pred := (A + B) shr 1;
      4: Pred := Paeth(A, B, C);
    else
      Pred := 0;
    end;
    Dst[X] := Byte((Integer(Src[X]) - Pred) and $FF);
  end;
end;

function EncodePng(InBuf: TBytes; Width, Height: Integer; Level: Integer): TBytes;
var
  CompressionLevel: Integer;
  RowBytes, RawLen: UInt64;
  Raw, Comp, IHDR, Empty: TBytes;
  SrcRow, PrevRow: TBytes;
  Prev: PByte;
  Candidates: array[0..4] of TBytes;
  Scores: array[0..4] of UInt64;
  Y: Integer;
  F, BestF: Integer;
  P, O: NativeUInt;
begin
  CompressionLevel := Level;
  if CompressionLevel < 0 then CompressionLevel := 6;
  if CompressionLevel > 9 then CompressionLevel := 9;
  if (Width <= 0) or (Height <= 0) then
    raise EPngError.Create('PNG: invalid image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EPngError.Create('PNG: RGBA8 buffer size does not match Width*Height*4');

  RowBytes := UInt64(Width) * 4;
  RawLen := UInt64(Height) * (RowBytes + 1);
  if (RowBytes > UInt64(High(NativeInt))) or (RawLen > UInt64(High(NativeInt))) then
    raise EPngError.Create('PNG: image too large');

  SetLength(Raw, NativeInt(RawLen));
  SetLength(SrcRow, NativeInt(RowBytes));
  SetLength(PrevRow, NativeInt(RowBytes));
  for F := 0 to 4 do
    SetLength(Candidates[F], NativeInt(RowBytes));

  P := 0;
  Prev := nil;
  for Y := 0 to Height - 1 do
  begin
    O := NativeUInt(Y) * NativeUInt(RowBytes);
    Move(InBuf[O], SrcRow[0], NativeUInt(RowBytes));

    BestF := 0;
    for F := 0 to 4 do
    begin
      MakeFiltered(F, @SrcRow[0], Prev, @Candidates[F][0], NativeUInt(RowBytes), 4);
      Scores[F] := FilterScore(@Candidates[F][0], NativeUInt(RowBytes));
      if (F = 0) or (Scores[F] < Scores[BestF]) then
        BestF := F;
    end;

    Raw[P] := Byte(BestF);
    Move(Candidates[BestF][0], Raw[P + 1], NativeUInt(RowBytes));
    Inc(P, NativeUInt(RowBytes) + 1);
    Move(SrcRow[0], PrevRow[0], NativeUInt(RowBytes));
    Prev := @PrevRow[0];
  end;

  if Length(Raw) = 0 then
    Comp := DeflateZlib(nil, 0, CompressionLevel)
  else
    Comp := DeflateZlib(@Raw[0], Length(Raw), CompressionLevel);

  SetLength(Result, 8);
  Move(PngSignature[0], Result[0], 8);
  SetLength(IHDR, 13);
  PutBE32(IHDR, 0, Cardinal(Width));
  PutBE32(IHDR, 4, Cardinal(Height));
  IHDR[8] := 8; // bit depth
  IHDR[9] := 6; // RGBA
  IHDR[10] := 0;
  IHDR[11] := 0;
  IHDR[12] := 0;
  AppendChunk(Result, 'IHDR', IHDR);
  AppendChunk(Result, 'IDAT', Comp);
  SetLength(Empty, 0);
  AppendChunk(Result, 'IEND', Empty);
end;

end.
