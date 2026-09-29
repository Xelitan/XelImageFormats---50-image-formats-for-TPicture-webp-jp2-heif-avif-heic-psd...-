unit XelDds;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, XelPng;

type
  EDdsError = class(Exception);

  TDdsFormat = (
    ddsBGR24,
    ddsBGRA32,
    ddsRGB565,
    ddsBC1,
    ddsBC2,
    ddsBC3
  );

// Dekoduje pierwsza powierzchnie (mip 0) DDS do RGBA8:
// - nieskompresowane RGB/RGBA 8/16/24/32-bit (maski kanalow), luminancja
// - DXT1/BC1, DXT2/3/BC2, DXT4/5/BC3, ATI1/BC4, ATI2/BC5, DX10 (BC1..5, RGBA8/BGRA8).
function DecodeDds(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8

// Zapisuje pojedyncza powierzchnie DDS. InBuf = RGBA8. Opcjonalny Format
// (domyslnie ddsBGRA32, nieskompresowany); ddsBC1/2/3 = kompresja DXT.
function EncodeDds(InBuf: TBytes; Width, Height: Integer;
  Format: TDdsFormat = ddsBGRA32): TBytes;                                // InBuf = RGBA8

implementation

const
  DDS_MAGIC = $20534444; // 'DDS ' little-endian

  DDSD_CAPS        = $00000001;
  DDSD_HEIGHT      = $00000002;
  DDSD_WIDTH       = $00000004;
  DDSD_PITCH       = $00000008;
  DDSD_PIXELFORMAT = $00001000;
  DDSD_MIPMAPCOUNT = $00020000;
  DDSD_LINEARSIZE  = $00080000;

  DDPF_ALPHAPIXELS = $00000001;
  DDPF_ALPHA       = $00000002;
  DDPF_FOURCC      = $00000004;
  DDPF_RGB         = $00000040;
  DDPF_LUMINANCE   = $00020000;

  DDSCAPS_COMPLEX  = $00000008;
  DDSCAPS_TEXTURE  = $00001000;
  DDSCAPS_MIPMAP   = $00400000;

  FOURCC_DXT1 = $31545844; // DXT1
  FOURCC_DXT2 = $32545844;
  FOURCC_DXT3 = $33545844;
  FOURCC_DXT4 = $34545844;
  FOURCC_DXT5 = $35545844;
  FOURCC_DX10 = $30315844;
  FOURCC_ATI1 = $31495441;
  FOURCC_ATI2 = $32495441;
  FOURCC_BC4U = $55344342; // BC4U
  FOURCC_BC5U = $55354342; // BC5U

  DXGI_FORMAT_R8G8B8A8_UNORM      = 28;
  DXGI_FORMAT_R8G8B8A8_UNORM_SRGB = 29;
  DXGI_FORMAT_BC1_UNORM            = 71;
  DXGI_FORMAT_BC1_UNORM_SRGB       = 72;
  DXGI_FORMAT_BC2_UNORM            = 74;
  DXGI_FORMAT_BC2_UNORM_SRGB       = 75;
  DXGI_FORMAT_BC3_UNORM            = 77;
  DXGI_FORMAT_BC3_UNORM_SRGB       = 78;
  DXGI_FORMAT_BC4_UNORM            = 80;
  DXGI_FORMAT_BC5_UNORM            = 83;
  DXGI_FORMAT_B8G8R8A8_UNORM       = 87;
  DXGI_FORMAT_B8G8R8X8_UNORM       = 88;

type
  TBCColorArray = array[0..3] of TRGBA;
  TAlphaArray = array[0..7] of Byte;

procedure Need(const Data: TBytes; Pos, Count: NativeUInt); inline;
begin
  if (Pos > NativeUInt(Length(Data))) or
     (Count > NativeUInt(Length(Data)) - Pos) then
    raise EDdsError.Create('DDS: unexpected end of file');
end;

function U32At(const Data: TBytes; Pos: NativeUInt): Cardinal; inline;
begin
  Need(Data, Pos, 4);
  Result := Cardinal(Data[Pos]) or
            (Cardinal(Data[Pos + 1]) shl 8) or
            (Cardinal(Data[Pos + 2]) shl 16) or
            (Cardinal(Data[Pos + 3]) shl 24);
end;

function U16At(const Data: TBytes; Pos: NativeUInt): Word; inline;
begin
  Need(Data, Pos, 2);
  Result := Word(Data[Pos]) or (Word(Data[Pos + 1]) shl 8);
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

procedure InitBitmap(var Buf: TBytes; W, H: Cardinal);
begin
  SetLength(Buf, NativeInt(W) * NativeInt(H) * 4);
end;

function ClampByte(V: Integer): Byte; inline;
begin
  if V < 0 then Result := 0
  else if V > 255 then Result := 255
  else Result := Byte(V);
end;

function RGB565ToColor(V: Word): TRGBA; inline;
var
  R, G, B: Integer;
begin
  R := (V shr 11) and 31;
  G := (V shr 5) and 63;
  B := V and 31;
  Result.R := Byte((R * 255 + 15) div 31);
  Result.G := Byte((G * 255 + 31) div 63);
  Result.B := Byte((B * 255 + 15) div 31);
  Result.A := 255;
end;

function ColorTo565(const C: TRGBA): Word; inline;
begin
  Result := Word(((Cardinal(C.R) * 31 + 127) div 255) shl 11) or
            Word(((Cardinal(C.G) * 63 + 127) div 255) shl 5) or
            Word((Cardinal(C.B) * 31 + 127) div 255);
end;

procedure BuildBCColorPalette(C0, C1: Word; ThreeColor: Boolean;
  var P: TBCColorArray);
var
  A, B: TRGBA;
begin
  A := RGB565ToColor(C0);
  B := RGB565ToColor(C1);
  P[0] := A;
  P[1] := B;

  if ThreeColor then
  begin
    P[2].R := Byte((Integer(A.R) + Integer(B.R)) div 2);
    P[2].G := Byte((Integer(A.G) + Integer(B.G)) div 2);
    P[2].B := Byte((Integer(A.B) + Integer(B.B)) div 2);
    P[2].A := 255;
    P[3].R := 0; P[3].G := 0; P[3].B := 0; P[3].A := 0;
  end
  else
  begin
    P[2].R := Byte((2 * Integer(A.R) + Integer(B.R) + 1) div 3);
    P[2].G := Byte((2 * Integer(A.G) + Integer(B.G) + 1) div 3);
    P[2].B := Byte((2 * Integer(A.B) + Integer(B.B) + 1) div 3);
    P[2].A := 255;
    P[3].R := Byte((Integer(A.R) + 2 * Integer(B.R) + 1) div 3);
    P[3].G := Byte((Integer(A.G) + 2 * Integer(B.G) + 1) div 3);
    P[3].B := Byte((Integer(A.B) + 2 * Integer(B.B) + 1) div 3);
    P[3].A := 255;
  end;
end;

procedure BuildAlphaPalette(A0, A1: Byte; var P: TAlphaArray);
begin
  P[0] := A0;
  P[1] := A1;
  if A0 > A1 then
  begin
    P[2] := Byte((6 * Integer(A0) + 1 * Integer(A1) + 3) div 7);
    P[3] := Byte((5 * Integer(A0) + 2 * Integer(A1) + 3) div 7);
    P[4] := Byte((4 * Integer(A0) + 3 * Integer(A1) + 3) div 7);
    P[5] := Byte((3 * Integer(A0) + 4 * Integer(A1) + 3) div 7);
    P[6] := Byte((2 * Integer(A0) + 5 * Integer(A1) + 3) div 7);
    P[7] := Byte((1 * Integer(A0) + 6 * Integer(A1) + 3) div 7);
  end
  else
  begin
    P[2] := Byte((4 * Integer(A0) + 1 * Integer(A1) + 2) div 5);
    P[3] := Byte((3 * Integer(A0) + 2 * Integer(A1) + 2) div 5);
    P[4] := Byte((2 * Integer(A0) + 3 * Integer(A1) + 2) div 5);
    P[5] := Byte((1 * Integer(A0) + 4 * Integer(A1) + 2) div 5);
    P[6] := 0;
    P[7] := 255;
  end;
end;

procedure StorePixel(var Buf: TBytes; W, H: Integer; X, Y: NativeUInt; const C: TRGBA);
begin
  if (Integer(Y) < H) and (Integer(X) < W) then
    SetPx(Buf, W, Integer(X), Integer(Y), C);
end;

procedure DecodeBC1Block(const Data: TBytes; Pos: NativeUInt; BX, BY: NativeUInt;
  var Buf: TBytes; W, H: Integer; ForceFourColor: Boolean);
var
  C0, C1: Word;
  Bits: Cardinal;
  P: TBCColorArray;
  I, X, Y, Idx: NativeUInt;
  Three: Boolean;
begin
  Need(Data, Pos, 8);
  C0 := U16At(Data, Pos);
  C1 := U16At(Data, Pos + 2);
  Bits := U32At(Data, Pos + 4);
  Three := (not ForceFourColor) and (C0 <= C1);
  BuildBCColorPalette(C0, C1, Three, P);

  I := 0;
  while I < 16 do
  begin
    Idx := (Bits shr (I * 2)) and 3;
    X := BX * 4 + (I and 3);
    Y := BY * 4 + (I shr 2);
    StorePixel(Buf, W, H, X, Y, P[Idx]);
    Inc(I);
  end;
end;

function Read48LE(const Data: TBytes; Pos: NativeUInt): UInt64; inline;
begin
  Need(Data, Pos, 6);
  Result := UInt64(Data[Pos]) or
            (UInt64(Data[Pos + 1]) shl 8) or
            (UInt64(Data[Pos + 2]) shl 16) or
            (UInt64(Data[Pos + 3]) shl 24) or
            (UInt64(Data[Pos + 4]) shl 32) or
            (UInt64(Data[Pos + 5]) shl 40);
end;

procedure DecodeBC2Block(const Data: TBytes; Pos: NativeUInt; BX, BY: NativeUInt;
  var Buf: TBytes; W, H: Integer; UnPremultiply: Boolean);
var
  AlphaBits: UInt64;
  C0, C1: Word;
  Bits: Cardinal;
  P: TBCColorArray;
  I, X, Y, Idx: NativeUInt;
  C: TRGBA;
  A4: Byte;
begin
  Need(Data, Pos, 16);
  AlphaBits := UInt64(U32At(Data, Pos)) or (UInt64(U32At(Data, Pos + 4)) shl 32);
  C0 := U16At(Data, Pos + 8);
  C1 := U16At(Data, Pos + 10);
  Bits := U32At(Data, Pos + 12);
  BuildBCColorPalette(C0, C1, False, P);

  I := 0;
  while I < 16 do
  begin
    Idx := (Bits shr (I * 2)) and 3;
    C := P[Idx];
    A4 := Byte((AlphaBits shr (I * 4)) and $F);
    C.A := Byte(A4 * 17);
    if UnPremultiply and (C.A <> 0) then
    begin
      C.R := ClampByte((Integer(C.R) * 255 + C.A div 2) div C.A);
      C.G := ClampByte((Integer(C.G) * 255 + C.A div 2) div C.A);
      C.B := ClampByte((Integer(C.B) * 255 + C.A div 2) div C.A);
    end;
    X := BX * 4 + (I and 3);
    Y := BY * 4 + (I shr 2);
    StorePixel(Buf, W, H, X, Y, C);
    Inc(I);
  end;
end;

procedure DecodeBC3Block(const Data: TBytes; Pos: NativeUInt; BX, BY: NativeUInt;
  var Buf: TBytes; W, H: Integer; UnPremultiply: Boolean);
var
  AP: TAlphaArray;
  ABits: UInt64;
  C0, C1: Word;
  CBits: Cardinal;
  CP: TBCColorArray;
  I, X, Y, CI, AI: NativeUInt;
  C: TRGBA;
begin
  Need(Data, Pos, 16);
  BuildAlphaPalette(Data[Pos], Data[Pos + 1], AP);
  ABits := Read48LE(Data, Pos + 2);
  C0 := U16At(Data, Pos + 8);
  C1 := U16At(Data, Pos + 10);
  CBits := U32At(Data, Pos + 12);
  BuildBCColorPalette(C0, C1, False, CP);

  I := 0;
  while I < 16 do
  begin
    AI := (ABits shr (I * 3)) and 7;
    CI := (CBits shr (I * 2)) and 3;
    C := CP[CI];
    C.A := AP[AI];
    if UnPremultiply and (C.A <> 0) then
    begin
      C.R := ClampByte((Integer(C.R) * 255 + C.A div 2) div C.A);
      C.G := ClampByte((Integer(C.G) * 255 + C.A div 2) div C.A);
      C.B := ClampByte((Integer(C.B) * 255 + C.A div 2) div C.A);
    end;
    X := BX * 4 + (I and 3);
    Y := BY * 4 + (I shr 2);
    StorePixel(Buf, W, H, X, Y, C);
    Inc(I);
  end;
end;

procedure DecodeBC4Block(const Data: TBytes; Pos: NativeUInt; BX, BY: NativeUInt;
  var Buf: TBytes; W, H: Integer; Channel: Integer);
var
  AP: TAlphaArray;
  Bits: UInt64;
  I, X, Y, AI: NativeUInt;
  C: TRGBA;
begin
  Need(Data, Pos, 8);
  BuildAlphaPalette(Data[Pos], Data[Pos + 1], AP);
  Bits := Read48LE(Data, Pos + 2);
  I := 0;
  while I < 16 do
  begin
    AI := (Bits shr (I * 3)) and 7;
    X := BX * 4 + (I and 3);
    Y := BY * 4 + (I shr 2);
    if (Integer(X) < W) and (Integer(Y) < H) then
    begin
      C := GetPx(Buf, W, Integer(X), Integer(Y));
      case Channel of
        0: begin C.R := AP[AI]; C.G := AP[AI]; C.B := AP[AI]; C.A := 255; end;
        1: begin C.R := AP[AI]; C.G := 0; C.B := 0; C.A := 255; end;
        2: begin C.G := AP[AI]; C.A := 255; end;
      end;
      SetPx(Buf, W, Integer(X), Integer(Y), C);
    end;
    Inc(I);
  end;
end;

procedure ClearBitmap(var Buf: TBytes; W, H: Integer; R, G, Bl, A: Byte);
var
  X, Y: NativeUInt;
  C: TRGBA;
begin
  C.R := R; C.G := G; C.B := Bl; C.A := A;
  Y := 0;
  while Integer(Y) < H do
  begin
    X := 0;
    while Integer(X) < W do
    begin
      SetPx(Buf, W, Integer(X), Integer(Y), C);
      Inc(X);
    end;
    Inc(Y);
  end;
end;

procedure DecodeBlockSurface(const Data: TBytes; Pos: NativeUInt; W, H: Cardinal;
  Kind: Integer; var Buf: TBytes);
// Kind: 1=BC1 2=BC2 3=BC3 4=BC4 5=BC5 6=DXT2 7=DXT4
var
  BW, BH, BX, BY, BlockSize: NativeUInt;
begin
  InitBitmap(Buf, W, H);
  ClearBitmap(Buf, Integer(W), Integer(H), 0, 0, 0, 255);
  BW := (NativeUInt(W) + 3) div 4;
  BH := (NativeUInt(H) + 3) div 4;
  if (Kind = 1) or (Kind = 4) then BlockSize := 8 else BlockSize := 16;
  Need(Data, Pos, BW * BH * BlockSize);

  BY := 0;
  while BY < BH do
  begin
    BX := 0;
    while BX < BW do
    begin
      case Kind of
        1: DecodeBC1Block(Data, Pos, BX, BY, Buf, Integer(W), Integer(H), False);
        2: DecodeBC2Block(Data, Pos, BX, BY, Buf, Integer(W), Integer(H), False);
        3: DecodeBC3Block(Data, Pos, BX, BY, Buf, Integer(W), Integer(H), False);
        4: DecodeBC4Block(Data, Pos, BX, BY, Buf, Integer(W), Integer(H), 0);
        5:
          begin
            DecodeBC4Block(Data, Pos, BX, BY, Buf, Integer(W), Integer(H), 1);
            DecodeBC4Block(Data, Pos + 8, BX, BY, Buf, Integer(W), Integer(H), 2);
          end;
        6: DecodeBC2Block(Data, Pos, BX, BY, Buf, Integer(W), Integer(H), True);
        7: DecodeBC3Block(Data, Pos, BX, BY, Buf, Integer(W), Integer(H), True);
      end;
      Inc(Pos, BlockSize);
      Inc(BX);
    end;
    Inc(BY);
  end;
end;

procedure MaskInfo(Mask: Cardinal; var Shift, Bits: Integer);
var
  M: Cardinal;
begin
  Shift := 0;
  Bits := 0;
  if Mask = 0 then Exit;
  M := Mask;
  while (M and 1) = 0 do
  begin
    Inc(Shift);
    M := M shr 1;
  end;
  while (M and 1) <> 0 do
  begin
    Inc(Bits);
    M := M shr 1;
  end;
end;

function ExtractMask(V, Mask: Cardinal; DefaultIfZero: Byte): Byte;
var
  Shift, Bits: Integer;
  Raw, MaxV: Cardinal;
begin
  if Mask = 0 then
  begin
    Result := DefaultIfZero;
    Exit;
  end;
  MaskInfo(Mask, Shift, Bits);
  if Bits <= 0 then
  begin
    Result := DefaultIfZero;
    Exit;
  end;
  Raw := (V and Mask) shr Shift;
  if Bits >= 31 then
    Result := Byte(Raw shr (Bits - 8))
  else
  begin
    MaxV := (Cardinal(1) shl Bits) - 1;
    Result := Byte((UInt64(Raw) * 255 + MaxV div 2) div MaxV);
  end;
end;

function ReadPixelLE(const Data: TBytes; Pos: NativeUInt; BytesPerPixel: Integer): Cardinal;
begin
  Need(Data, Pos, BytesPerPixel);
  Result := Data[Pos];
  if BytesPerPixel >= 2 then Result := Result or (Cardinal(Data[Pos + 1]) shl 8);
  if BytesPerPixel >= 3 then Result := Result or (Cardinal(Data[Pos + 2]) shl 16);
  if BytesPerPixel >= 4 then Result := Result or (Cardinal(Data[Pos + 3]) shl 24);
end;

procedure DecodeUncompressed(const Data: TBytes; Pos: NativeUInt; W, H: Cardinal;
  Pitch: Cardinal; PFFlags, BitCount, RMask, GMask, BMask, AMask: Cardinal;
  var Buf: TBytes);
var
  BPP: Integer;
  MinPitch, RowPitch, X, Y, PPos: NativeUInt;
  V: Cardinal;
  C: TRGBA;
  L: Byte;
begin
  if (BitCount <> 8) and (BitCount <> 16) and
     (BitCount <> 24) and (BitCount <> 32) then
    raise EDdsError.CreateFmt('DDS: unsupported uncompressed bit depth %d', [BitCount]);
  BPP := Integer(BitCount div 8);
  MinPitch := NativeUInt(W) * NativeUInt(BPP);
  RowPitch := Pitch;
  if RowPitch < MinPitch then RowPitch := MinPitch;
  Need(Data, Pos, RowPitch * NativeUInt(H));

  InitBitmap(Buf, W, H);
  Y := 0;
  while Y < H do
  begin
    X := 0;
    while X < W do
    begin
      PPos := Pos + Y * RowPitch + X * NativeUInt(BPP);
      V := ReadPixelLE(Data, PPos, BPP);
      C.A := 255;

      if (PFFlags and DDPF_LUMINANCE) <> 0 then
      begin
        L := ExtractMask(V, RMask, Byte(V and $FF));
        C.R := L; C.G := L; C.B := L;
        if (PFFlags and DDPF_ALPHAPIXELS) <> 0 then C.A := ExtractMask(V, AMask, 255);
      end
      else if ((PFFlags and DDPF_ALPHA) <> 0) and ((PFFlags and DDPF_RGB) = 0) then
      begin
        C.R := 255; C.G := 255; C.B := 255;
        C.A := ExtractMask(V, AMask, Byte(V and $FF));
      end
      else
      begin
        C.R := ExtractMask(V, RMask, 0);
        C.G := ExtractMask(V, GMask, 0);
        C.B := ExtractMask(V, BMask, 0);
        if (PFFlags and DDPF_ALPHAPIXELS) <> 0 then C.A := ExtractMask(V, AMask, 255)
        else C.A := 255;
      end;
      SetPx(Buf, Integer(W), Integer(X), Integer(Y), C);
      Inc(X);
    end;
    Inc(Y);
  end;
end;

function DecodeDds(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Data: TBytes;
  HeaderSize, Flags, H, W, Pitch, MipCount: Cardinal;
  PFSize, PFFlags, FourCC, BitCount, RMask, GMask, BMask, AMask: Cardinal;
  Pos: NativeUInt;
  DXGI, ArraySize: Cardinal;
  Kind: Integer;
begin
  Data := InBuf;
  Width := 0;
  Height := 0;
  SetLength(Result, 0);
  Need(Data, 0, 128);
  if U32At(Data, 0) <> DDS_MAGIC then raise EDdsError.Create('DDS: invalid signature');
  HeaderSize := U32At(Data, 4);
  if HeaderSize <> 124 then raise EDdsError.CreateFmt('DDS: invalid header size %d', [HeaderSize]);

  Flags := U32At(Data, 8);
  H := U32At(Data, 12);
  W := U32At(Data, 16);
  Pitch := U32At(Data, 20);
  MipCount := U32At(Data, 28);
  PFSize := U32At(Data, 76);
  PFFlags := U32At(Data, 80);
  FourCC := U32At(Data, 84);
  BitCount := U32At(Data, 88);
  RMask := U32At(Data, 92);
  GMask := U32At(Data, 96);
  BMask := U32At(Data, 100);
  AMask := U32At(Data, 104);

  if PFSize <> 32 then raise EDdsError.CreateFmt('DDS: invalid pixel format size %d', [PFSize]);
  if (W = 0) or (H = 0) then raise EDdsError.Create('DDS: invalid image size');
  if (Flags and (DDSD_WIDTH or DDSD_HEIGHT or DDSD_PIXELFORMAT)) <>
     (DDSD_WIDTH or DDSD_HEIGHT or DDSD_PIXELFORMAT) then
    raise EDdsError.Create('DDS: required header flags are missing');
  if MipCount = 0 then MipCount := 1;
  // Cubemap/depth and mipmaps are intentionally ignored after first surface/top level.

  Width := Integer(W);
  Height := Integer(H);

  Pos := 128;
  if (PFFlags and DDPF_FOURCC) <> 0 then
  begin
    Kind := 0;
    case FourCC of
      FOURCC_DXT1: Kind := 1;
      FOURCC_DXT2: Kind := 6;
      FOURCC_DXT3: Kind := 2;
      FOURCC_DXT4: Kind := 7;
      FOURCC_DXT5: Kind := 3;
      FOURCC_ATI1, FOURCC_BC4U: Kind := 4;
      FOURCC_ATI2, FOURCC_BC5U: Kind := 5;
      FOURCC_DX10:
        begin
          Need(Data, Pos, 20);
          DXGI := U32At(Data, Pos);
          ArraySize := U32At(Data, Pos + 12);
          if ArraySize = 0 then raise EDdsError.Create('DDS: DX10 array size is zero');
          Inc(Pos, 20);
          case DXGI of
            DXGI_FORMAT_BC1_UNORM, DXGI_FORMAT_BC1_UNORM_SRGB: Kind := 1;
            DXGI_FORMAT_BC2_UNORM, DXGI_FORMAT_BC2_UNORM_SRGB: Kind := 2;
            DXGI_FORMAT_BC3_UNORM, DXGI_FORMAT_BC3_UNORM_SRGB: Kind := 3;
            DXGI_FORMAT_BC4_UNORM: Kind := 4;
            DXGI_FORMAT_BC5_UNORM: Kind := 5;
            DXGI_FORMAT_R8G8B8A8_UNORM,
            DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
              begin
                DecodeUncompressed(Data, Pos, W, H, W * 4,
                  DDPF_RGB or DDPF_ALPHAPIXELS, 32,
                  $000000FF, $0000FF00, $00FF0000, $FF000000, Result);
                Exit;
              end;
            DXGI_FORMAT_B8G8R8A8_UNORM:
              begin
                DecodeUncompressed(Data, Pos, W, H, W * 4,
                  DDPF_RGB or DDPF_ALPHAPIXELS, 32,
                  $00FF0000, $0000FF00, $000000FF, $FF000000, Result);
                Exit;
              end;
            DXGI_FORMAT_B8G8R8X8_UNORM:
              begin
                DecodeUncompressed(Data, Pos, W, H, W * 4,
                  DDPF_RGB, 32,
                  $00FF0000, $0000FF00, $000000FF, 0, Result);
                Exit;
              end;
          else
            raise EDdsError.CreateFmt('DDS: unsupported DXGI format %d', [DXGI]);
          end;
        end;
    else
      raise EDdsError.CreateFmt('DDS: unsupported FourCC $%.8x', [FourCC]);
    end;
    DecodeBlockSurface(Data, Pos, W, H, Kind, Result);
  end
  else
  begin
    if (PFFlags and (DDPF_RGB or DDPF_LUMINANCE or DDPF_ALPHA)) = 0 then
      raise EDdsError.CreateFmt('DDS: unsupported pixel format flags $%.8x', [PFFlags]);
    if (Flags and DDSD_PITCH) = 0 then Pitch := 0;
    DecodeUncompressed(Data, Pos, W, H, Pitch, PFFlags, BitCount,
      RMask, GMask, BMask, AMask, Result);
  end;
end;

function ColorDist(const A, B: TRGBA): Cardinal; inline;
var
  DR, DG, DB: Integer;
begin
  DR := Integer(A.R) - Integer(B.R);
  DG := Integer(A.G) - Integer(B.G);
  DB := Integer(A.B) - Integer(B.B);
  Result := Cardinal(DR * DR + DG * DG + DB * DB);
end;

function AlphaDist(A, B: Byte): Integer; inline;
begin
  Result := Abs(Integer(A) - Integer(B));
end;

procedure GetBlockPixels(const Buf: TBytes; W, H: Integer; BX, BY: NativeUInt;
  var P: array of TRGBA);
var
  I, X, Y: NativeUInt;
begin
  I := 0;
  while I < 16 do
  begin
    X := BX * 4 + (I and 3);
    Y := BY * 4 + (I shr 2);
    if Integer(X) >= W then X := NativeUInt(W - 1);
    if Integer(Y) >= H then Y := NativeUInt(H - 1);
    P[I] := GetPx(Buf, W, Integer(X), Integer(Y));
    Inc(I);
  end;
end;

procedure FindColorEndpoints(const P: array of TRGBA; IgnoreTransparent: Boolean;
  var MinC, MaxC: TRGBA; var Have: Boolean);
var
  I: NativeUInt;
  MinL, MaxL, L: Integer;
  C: TRGBA;
begin
  Have := False;
  MinL := 0; MaxL := 0;
  I := 0;
  while I < 16 do
  begin
    C := P[I];
    if (not IgnoreTransparent) or (C.A >= 128) then
    begin
      L := 2 * Integer(C.R) + 3 * Integer(C.G) + Integer(C.B);
      if not Have then
      begin
        MinC := C; MaxC := C; MinL := L; MaxL := L; Have := True;
      end
      else
      begin
        if L < MinL then begin MinL := L; MinC := C; end;
        if L > MaxL then begin MaxL := L; MaxC := C; end;
      end;
    end;
    Inc(I);
  end;
  if not Have then
  begin
    MinC.R := 0; MinC.G := 0; MinC.B := 0; MinC.A := 255;
    MaxC := MinC;
  end;
end;

procedure WriteColorBlock(var D: TBytes; Pos: NativeUInt; const P: array of TRGBA;
  AllowTransparency: Boolean);
var
  MinC, MaxC: TRGBA;
  Have, HasTrans: Boolean;
  C0, C1, T: Word;
  Pal: TBCColorArray;
  Bits: Cardinal;
  I, J, Best: NativeUInt;
  Dist, BestDist: Cardinal;
begin
  HasTrans := False;
  I := 0;
  while I < 16 do
  begin
    if P[I].A < 128 then HasTrans := True;
    Inc(I);
  end;
  HasTrans := HasTrans and AllowTransparency;

  FindColorEndpoints(P, HasTrans, MinC, MaxC, Have);
  C0 := ColorTo565(MaxC);
  C1 := ColorTo565(MinC);

  if HasTrans then
  begin
    if C0 > C1 then begin T := C0; C0 := C1; C1 := T; end;
    if C0 = C1 then
    begin
      if C1 < $FFFF then Inc(C1)
      else if C0 > 0 then Dec(C0);
    end;
    BuildBCColorPalette(C0, C1, True, Pal);
  end
  else
  begin
    if C0 <= C1 then begin T := C0; C0 := C1; C1 := T; end;
    if C0 = C1 then
    begin
      if C0 < $FFFF then Inc(C0)
      else if C1 > 0 then Dec(C1);
    end;
    BuildBCColorPalette(C0, C1, False, Pal);
  end;

  Bits := 0;
  I := 0;
  while I < 16 do
  begin
    if HasTrans and (P[I].A < 128) then Best := 3
    else
    begin
      Best := 0;
      BestDist := High(Cardinal);
      J := 0;
      if HasTrans then
      begin
        while J < 3 do
        begin
          Dist := ColorDist(P[I], Pal[J]);
          if Dist < BestDist then begin BestDist := Dist; Best := J; end;
          Inc(J);
        end;
      end
      else
      begin
        while J < 4 do
        begin
          Dist := ColorDist(P[I], Pal[J]);
          if Dist < BestDist then begin BestDist := Dist; Best := J; end;
          Inc(J);
        end;
      end;
    end;
    Bits := Bits or (Cardinal(Best) shl (I * 2));
    Inc(I);
  end;

  PutLE16(D, Pos, C0);
  PutLE16(D, Pos + 2, C1);
  PutLE32(D, Pos + 4, Bits);
end;

procedure WriteAlphaBlock(var D: TBytes; Pos: NativeUInt; const P: array of TRGBA);
var
  I, J, Best: NativeUInt;
  A0, A1: Byte;
  AP: TAlphaArray;
  Bits: UInt64;
  Dist, BestDist: Integer;
begin
  A0 := 0;
  A1 := 255;
  I := 0;
  while I < 16 do
  begin
    if P[I].A > A0 then A0 := P[I].A;
    if P[I].A < A1 then A1 := P[I].A;
    Inc(I);
  end;
  BuildAlphaPalette(A0, A1, AP);

  Bits := 0;
  I := 0;
  while I < 16 do
  begin
    Best := 0;
    BestDist := MaxInt;
    J := 0;
    while J < 8 do
    begin
      Dist := AlphaDist(P[I].A, AP[J]);
      if Dist < BestDist then begin BestDist := Dist; Best := J; end;
      Inc(J);
    end;
    Bits := Bits or (UInt64(Best) shl (I * 3));
    Inc(I);
  end;

  D[Pos] := A0;
  D[Pos + 1] := A1;
  D[Pos + 2] := Byte(Bits);
  D[Pos + 3] := Byte(Bits shr 8);
  D[Pos + 4] := Byte(Bits shr 16);
  D[Pos + 5] := Byte(Bits shr 24);
  D[Pos + 6] := Byte(Bits shr 32);
  D[Pos + 7] := Byte(Bits shr 40);
end;

procedure WriteBC2Alpha(var D: TBytes; Pos: NativeUInt; const P: array of TRGBA);
var
  Bits: UInt64;
  I: NativeUInt;
  A4: UInt64;
begin
  Bits := 0;
  I := 0;
  while I < 16 do
  begin
    A4 := (Cardinal(P[I].A) * 15 + 127) div 255;
    Bits := Bits or (A4 shl (I * 4));
    Inc(I);
  end;
  PutLE32(D, Pos, Cardinal(Bits));
  PutLE32(D, Pos + 4, Cardinal(Bits shr 32));
end;

function EncodeDds(InBuf: TBytes; Width, Height: Integer; Format: TDdsFormat): TBytes;
var
  Flags, LinearOrPitch, PFFlags, FourCC, BitCount: Cardinal;
  RMask, GMask, BMask, AMask: Cardinal;
  DataSize, Pos, X, Y, BX, BY, BW, BH, BPP, BlockSize: NativeUInt;
  P: array[0..15] of TRGBA;
  C: TRGBA;
  V16: Word;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then
    raise EDdsError.Create('DDS: cannot encode an empty bitmap');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EDdsError.Create('DDS: RGBA8 buffer size does not match Width*Height*4');

  FourCC := 0; BitCount := 0;
  RMask := 0; GMask := 0; BMask := 0; AMask := 0;
  PFFlags := 0; LinearOrPitch := 0; DataSize := 0; BPP := 0; BlockSize := 0;

  case Format of
    ddsBGR24:
      begin
        Flags := DDSD_CAPS or DDSD_HEIGHT or DDSD_WIDTH or DDSD_PIXELFORMAT or DDSD_PITCH;
        PFFlags := DDPF_RGB;
        BitCount := 24;
        RMask := $00FF0000; GMask := $0000FF00; BMask := $000000FF;
        BPP := 3; LinearOrPitch := Width * 3;
        DataSize := NativeUInt(LinearOrPitch) * Height;
      end;
    ddsBGRA32:
      begin
        Flags := DDSD_CAPS or DDSD_HEIGHT or DDSD_WIDTH or DDSD_PIXELFORMAT or DDSD_PITCH;
        PFFlags := DDPF_RGB or DDPF_ALPHAPIXELS;
        BitCount := 32;
        RMask := $00FF0000; GMask := $0000FF00; BMask := $000000FF; AMask := $FF000000;
        BPP := 4; LinearOrPitch := Width * 4;
        DataSize := NativeUInt(LinearOrPitch) * Height;
      end;
    ddsRGB565:
      begin
        Flags := DDSD_CAPS or DDSD_HEIGHT or DDSD_WIDTH or DDSD_PIXELFORMAT or DDSD_PITCH;
        PFFlags := DDPF_RGB;
        BitCount := 16;
        RMask := $F800; GMask := $07E0; BMask := $001F;
        BPP := 2; LinearOrPitch := Width * 2;
        DataSize := NativeUInt(LinearOrPitch) * Height;
      end;
    ddsBC1, ddsBC2, ddsBC3:
      begin
        Flags := DDSD_CAPS or DDSD_HEIGHT or DDSD_WIDTH or DDSD_PIXELFORMAT or DDSD_LINEARSIZE;
        PFFlags := DDPF_FOURCC;
        if Format = ddsBC1 then begin FourCC := FOURCC_DXT1; BlockSize := 8; end
        else if Format = ddsBC2 then begin FourCC := FOURCC_DXT3; BlockSize := 16; end
        else begin FourCC := FOURCC_DXT5; BlockSize := 16; end;
        BW := (NativeUInt(Width) + 3) div 4;
        BH := (NativeUInt(Height) + 3) div 4;
        DataSize := BW * BH * BlockSize;
        LinearOrPitch := Cardinal(DataSize);
      end;
  else
    raise EDdsError.Create('DDS: invalid encoder format');
  end;

  SetLength(Result, 128 + DataSize);
  PutLE32(Result, 0, DDS_MAGIC);
  PutLE32(Result, 4, 124);
  PutLE32(Result, 8, Flags);
  PutLE32(Result, 12, Height);
  PutLE32(Result, 16, Width);
  PutLE32(Result, 20, LinearOrPitch);
  PutLE32(Result, 24, 0);
  PutLE32(Result, 28, 1);
  // reserved1[11] remains zero
  PutLE32(Result, 76, 32);
  PutLE32(Result, 80, PFFlags);
  PutLE32(Result, 84, FourCC);
  PutLE32(Result, 88, BitCount);
  PutLE32(Result, 92, RMask);
  PutLE32(Result, 96, GMask);
  PutLE32(Result, 100, BMask);
  PutLE32(Result, 104, AMask);
  PutLE32(Result, 108, DDSCAPS_TEXTURE);

  Pos := 128;
  if (Format = ddsBGR24) or (Format = ddsBGRA32) or (Format = ddsRGB565) then
  begin
    Y := 0;
    while Y < Height do
    begin
      X := 0;
      while X < Width do
      begin
        C := GetPx(InBuf, Width, Integer(X), Integer(Y));
        case Format of
          ddsBGR24:
            begin
              Result[Pos] := C.B; Result[Pos + 1] := C.G; Result[Pos + 2] := C.R;
            end;
          ddsBGRA32:
            begin
              Result[Pos] := C.B; Result[Pos + 1] := C.G; Result[Pos + 2] := C.R; Result[Pos + 3] := C.A;
            end;
          ddsRGB565:
            begin
              V16 := ColorTo565(C);
              Result[Pos] := Byte(V16); Result[Pos + 1] := Byte(V16 shr 8);
            end;
        end;
        Inc(Pos, BPP);
        Inc(X);
      end;
      Inc(Y);
    end;
  end
  else
  begin
    BW := (NativeUInt(Width) + 3) div 4;
    BH := (NativeUInt(Height) + 3) div 4;
    BY := 0;
    while BY < BH do
    begin
      BX := 0;
      while BX < BW do
      begin
        GetBlockPixels(InBuf, Width, Height, BX, BY, P);
        if Format = ddsBC1 then
          WriteColorBlock(Result, Pos, P, True)
        else if Format = ddsBC2 then
        begin
          WriteBC2Alpha(Result, Pos, P);
          WriteColorBlock(Result, Pos + 8, P, False);
        end
        else
        begin
          WriteAlphaBlock(Result, Pos, P);
          WriteColorBlock(Result, Pos + 8, P, False);
        end;
        Inc(Pos, BlockSize);
        Inc(BX);
      end;
      Inc(BY);
    end;
  end;
end;

end.
