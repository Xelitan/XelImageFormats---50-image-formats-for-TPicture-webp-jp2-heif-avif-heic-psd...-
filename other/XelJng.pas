unit XelJng;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	JNG (JPEG Network Graphics) decoder -> RGBA8                  //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Clean-room implementation from the JNG specification: PNG-style chunks;    //
// JHDR, colour in JDAT (JPEG), optional alpha in IDAT (PNG-coded grayscale)   //
// or JDAA (JPEG-coded grayscale). Also exports small PNG-chunk helpers used   //
// by the MNG decoder.                                                         //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelPng, XelJpeg;

type
  EJngError = class(Exception);

function DecodeJng(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8

// Decodes a JNG datastream that is embedded somewhere else (e.g. inside MNG):
// Data[Off..] must start with the JHDR chunk (no signature). Stops at IEND;
// EndOff receives the offset just after IEND.
function DecodeJngChunks(const Data: TBytes; Off: NativeUInt; out Width, Height: Integer;
  out EndOff: NativeUInt): TBytes;

// PNG CRC-32 of Len bytes.
function PngCrc32(const Data: TBytes; Off, Len: NativeUInt): Cardinal;
// Appends one PNG chunk (length, type, data, CRC) to Dest.
procedure AppendPngChunk(var Dest: TBytes; const ChunkType: AnsiString; const Data: TBytes);

implementation

var
  CrcTable: array[0..255] of Cardinal;
  CrcReady: Boolean = False;

procedure InitCrc;
var
  n, k: Integer;
  c: Cardinal;
begin
  for n := 0 to 255 do
  begin
    c := Cardinal(n);
    for k := 0 to 7 do
      if (c and 1) <> 0 then c := $EDB88320 xor (c shr 1) else c := c shr 1;
    CrcTable[n] := c;
  end;
  CrcReady := True;
end;

function PngCrc32(const Data: TBytes; Off, Len: NativeUInt): Cardinal;
var
  c: Cardinal;
  i: NativeUInt;
begin
  if not CrcReady then InitCrc;
  c := $FFFFFFFF;
  i := 0;
  while i < Len do
  begin
    c := CrcTable[(c xor Data[Off + i]) and $FF] xor (c shr 8);
    Inc(i);
  end;
  Result := c xor $FFFFFFFF;
end;

procedure AppendPngChunk(var Dest: TBytes; const ChunkType: AnsiString; const Data: TBytes);
var
  p, n: NativeUInt;
  crc: Cardinal;
begin
  n := Length(Data);
  p := Length(Dest);
  SetLength(Dest, p + 12 + n);
  Dest[p] := Byte(n shr 24); Dest[p + 1] := Byte(n shr 16); Dest[p + 2] := Byte(n shr 8); Dest[p + 3] := Byte(n);
  Dest[p + 4] := Byte(ChunkType[1]); Dest[p + 5] := Byte(ChunkType[2]);
  Dest[p + 6] := Byte(ChunkType[3]); Dest[p + 7] := Byte(ChunkType[4]);
  if n > 0 then Move(Data[0], Dest[p + 8], n);
  crc := PngCrc32(Dest, p + 4, n + 4);
  Dest[p + 8 + n] := Byte(crc shr 24); Dest[p + 9 + n] := Byte(crc shr 16);
  Dest[p + 10 + n] := Byte(crc shr 8); Dest[p + 11 + n] := Byte(crc);
end;

function RB32(const D: TBytes; P: NativeUInt): Cardinal; inline;
begin
  Result := (Cardinal(D[P]) shl 24) or (Cardinal(D[P + 1]) shl 16) or
            (Cardinal(D[P + 2]) shl 8) or Cardinal(D[P + 3]);
end;

function IsType(const D: TBytes; P: NativeUInt; const T: AnsiString): Boolean; inline;
begin
  Result := (D[P] = Byte(T[1])) and (D[P + 1] = Byte(T[2])) and
            (D[P + 2] = Byte(T[3])) and (D[P + 3] = Byte(T[4]));
end;

procedure AppendRaw(var Dest: TBytes; const Src: TBytes; Off, Len: NativeUInt);
var
  p: NativeUInt;
begin
  if Len = 0 then Exit;
  p := Length(Dest);
  SetLength(Dest, p + Len);
  Move(Src[Off], Dest[p], Len);
end;

function DecodeJngChunks(const Data: TBytes; Off: NativeUInt; out Width, Height: Integer;
  out EndOff: NativeUInt): TBytes;
var
  N, pos, len, dataOff: NativeUInt;
  W, H, i, aw, ah, jw, jh: Integer;
  ColorType, AlphaDepth, AlphaComp, AlphaInterlace: Byte;
  Jpeg, AlphaJpeg, AlphaPng, Hdr, Alpha: TBytes;
  HaveHdr, SeenSep: Boolean;
  Sig: array[0..7] of Byte;
begin
  Width := 0; Height := 0; Result := nil; EndOff := Off;
  N := NativeUInt(Length(Data));
  pos := Off;
  HaveHdr := False; SeenSep := False;
  W := 0; H := 0; ColorType := 10; AlphaDepth := 0; AlphaComp := 0; AlphaInterlace := 0;
  Jpeg := nil; AlphaJpeg := nil;

  // a PNG stream is built around the IDAT alpha chunks: signature + IHDR later
  Sig[0] := $89; Sig[1] := Ord('P'); Sig[2] := Ord('N'); Sig[3] := Ord('G');
  Sig[4] := 13; Sig[5] := 10; Sig[6] := 26; Sig[7] := 10;
  AlphaPng := nil;

  while pos + 12 <= N do
  begin
    len := RB32(Data, pos);
    dataOff := pos + 8;
    if dataOff + len + 4 > N then raise EJngError.Create('JNG: truncated chunk');
    if IsType(Data, pos + 4, 'JHDR') then
    begin
      if len < 16 then raise EJngError.Create('JNG: bad JHDR');
      W := Integer(RB32(Data, dataOff));
      H := Integer(RB32(Data, dataOff + 4));
      ColorType := Data[dataOff + 8];
      AlphaDepth := Data[dataOff + 12];
      AlphaComp := Data[dataOff + 13];
      AlphaInterlace := Data[dataOff + 15];
      HaveHdr := True;
    end
    else if IsType(Data, pos + 4, 'JDAT') then
    begin
      if not SeenSep then AppendRaw(Jpeg, Data, dataOff, len);   // 8-bit JPEG only
    end
    else if IsType(Data, pos + 4, 'JSEP') then
      SeenSep := True
    else if IsType(Data, pos + 4, 'JDAA') then
      AppendRaw(AlphaJpeg, Data, dataOff, len)
    else if IsType(Data, pos + 4, 'IDAT') then
      AppendRaw(AlphaPng, Data, pos, len + 12)                   // whole chunk, CRC intact
    else if IsType(Data, pos + 4, 'IEND') then
    begin
      pos := pos + 12 + len;
      Break;
    end;
    pos := pos + 12 + len;
  end;
  EndOff := pos;

  if not HaveHdr then raise EJngError.Create('JNG: missing JHDR');
  if (W <= 0) or (H <= 0) then raise EJngError.Create('JNG: invalid dimensions');
  if Length(Jpeg) = 0 then raise EJngError.Create('JNG: no JDAT image data');

  Result := DecodeJpeg(Jpeg, jw, jh);
  if (jw <> W) or (jh <> H) then raise EJngError.Create('JNG: JPEG size differs from JHDR');
  Width := W; Height := H;

  // alpha channel for colour types 12 (gray+alpha) and 14 (colour+alpha)
  Alpha := nil;
  if (ColorType = 12) or (ColorType = 14) then
  begin
    if (AlphaComp = 8) and (Length(AlphaJpeg) > 0) then
      Alpha := DecodeJpeg(AlphaJpeg, aw, ah)
    else if (AlphaComp = 0) and (Length(AlphaPng) > 0) then
    begin
      SetLength(Hdr, 13);
      Hdr[0] := Byte(W shr 24); Hdr[1] := Byte(W shr 16); Hdr[2] := Byte(W shr 8); Hdr[3] := Byte(W);
      Hdr[4] := Byte(H shr 24); Hdr[5] := Byte(H shr 16); Hdr[6] := Byte(H shr 8); Hdr[7] := Byte(H);
      Hdr[8] := AlphaDepth;      // bit depth
      Hdr[9] := 0;               // grayscale
      Hdr[10] := 0; Hdr[11] := 0;
      Hdr[12] := AlphaInterlace;
      Alpha := nil;
      SetLength(Alpha, 8); Move(Sig[0], Alpha[0], 8);
      AppendPngChunk(Alpha, 'IHDR', Hdr);
      AppendRaw(Alpha, AlphaPng, 0, Length(AlphaPng));
      AppendPngChunk(Alpha, 'IEND', nil);
      Alpha := DecodePng(Alpha, aw, ah);
    end;
    if (Length(Alpha) = Length(Result)) then
      for i := 0 to W * H - 1 do
        Result[i * 4 + 3] := Alpha[i * 4];    // gray level -> alpha
  end;
end;

function DecodeJng(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  EndOff: NativeUInt;
begin
  if (Length(InBuf) < 8) or (InBuf[0] <> $8B) or (InBuf[1] <> Ord('J')) or
     (InBuf[2] <> Ord('N')) or (InBuf[3] <> Ord('G')) then
    raise EJngError.Create('JNG: bad signature');
  Result := DecodeJngChunks(InBuf, 8, Width, Height, EndOff);
end;

end.
