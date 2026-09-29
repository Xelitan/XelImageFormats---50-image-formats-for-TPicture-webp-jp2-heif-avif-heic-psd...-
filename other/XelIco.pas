unit XelIco;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	ICO / CUR icon codec -> RGBA8 (multi-image)                   //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Clean-room implementation. Each directory entry is a PNG stream or a DIB    //
// (BITMAPINFOHEADER + XOR bitmap + 1bpp AND mask). ICO and CUR share layout.  //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelPng;

type
  EIcoError = class(Exception);

// Liczba obrazow (entries) w pliku ICO/CUR.
function IcoImageCount(InBuf: TBytes): Integer;
// Dekoduje wskazany obraz (0-based) do RGBA8.
function DecodeIcoImage(InBuf: TBytes; Index: Integer; out Width, Height: Integer): TBytes;
// Dekoduje najwiekszy obraz (kompatybilnosc).
function DecodeIco(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8

// Dekoduje ICO/CUR z dowolnego bufora zaczynajacego sie od ICONDIR - uzywane
// tez przez dekoder ANI dla pojedynczej klatki.
function DecodeIcoDir(const Data: TBytes; DirOff: NativeUInt;
  Index: Integer; out Width, Height: Integer): TBytes;
function IcoDirCount(const Data: TBytes; DirOff: NativeUInt): Integer;

implementation

function RL16(const D: TBytes; P: NativeUInt): Word; inline;
begin
  Result := Word(D[P]) or (Word(D[P + 1]) shl 8);
end;

function RL32(const D: TBytes; P: NativeUInt): Cardinal; inline;
begin
  Result := Cardinal(D[P]) or (Cardinal(D[P + 1]) shl 8) or
            (Cardinal(D[P + 2]) shl 16) or (Cardinal(D[P + 3]) shl 24);
end;

function IcoDirCount(const Data: TBytes; DirOff: NativeUInt): Integer;
begin
  if DirOff + 6 > NativeUInt(Length(Data)) then Exit(0);
  // reserved(2)=0, type(2)=1 or 2, count(2)
  Result := RL16(Data, DirOff + 4);
end;

function IcoImageCount(InBuf: TBytes): Integer;
begin
  Result := IcoDirCount(InBuf, 0);
end;

// Decode a DIB (BITMAPINFOHEADER) icon image at Off.
function DecodeDib(const Data: TBytes; Off, Size: NativeUInt;
  out Width, Height: Integer): TBytes;
var
  N, palOff, xorOff, andOff: NativeUInt;
  biSize: Cardinal;
  biW, biH: Integer;
  bitCount: Word;
  compression, clrUsed: Cardinal;
  W, H, x, y, imgY, nColors: Integer;
  xorRow, andRow: NativeUInt;
  Pal: array of TRGBA;
  i, idx: Integer;
  p, ap: NativeUInt;
  bt, andByte: Byte;
  hasAlpha, applyMask: Boolean;
  C: TRGBA;
begin
  Width := 0; Height := 0; SetLength(Result, 0);
  N := NativeUInt(Length(Data));
  if Off + 40 > N then raise EIcoError.Create('ICO: truncated DIB header');
  biSize := RL32(Data, Off);
  if biSize < 40 then raise EIcoError.Create('ICO: unsupported DIB header');
  biW := Integer(RL32(Data, Off + 4));
  biH := Integer(RL32(Data, Off + 8));
  bitCount := RL16(Data, Off + 14);
  compression := RL32(Data, Off + 16);
  clrUsed := RL32(Data, Off + 32);
  if compression <> 0 then raise EIcoError.CreateFmt('ICO: unsupported DIB compression %d', [compression]);

  W := biW;
  H := biH;
  if H >= 2 * W then H := H div 2      // biHeight usually spans XOR+AND
  else H := Abs(biH) div 2;
  if H = 0 then H := Abs(biH);
  if (W <= 0) or (H <= 0) then raise EIcoError.Create('ICO: invalid DIB size');

  if bitCount <= 8 then
  begin
    nColors := Integer(clrUsed);
    if nColors = 0 then nColors := 1 shl bitCount;
  end
  else nColors := 0;

  palOff := Off + biSize;
  SetLength(Pal, nColors);
  for i := 0 to nColors - 1 do
  begin
    p := palOff + NativeUInt(i) * 4;
    if p + 3 < N then
    begin
      Pal[i].B := Data[p]; Pal[i].G := Data[p + 1]; Pal[i].R := Data[p + 2]; Pal[i].A := 255;
    end;
  end;

  xorRow := ((NativeUInt(W) * bitCount + 31) div 32) * 4;
  andRow := ((NativeUInt(W) + 31) div 32) * 4;
  xorOff := palOff + NativeUInt(nColors) * 4;
  andOff := xorOff + xorRow * NativeUInt(H);

  Width := W; Height := H;
  SetLength(Result, NativeInt(W) * H * 4);
  hasAlpha := False;

  for y := 0 to H - 1 do
  begin
    imgY := H - 1 - y;                 // DIB is bottom-up
    for x := 0 to W - 1 do
    begin
      C.R := 0; C.G := 0; C.B := 0; C.A := 255;
      case bitCount of
        1:
          begin
            p := xorOff + NativeUInt(y) * xorRow + NativeUInt(x) div 8;
            if p < N then bt := (Data[p] shr (7 - (x and 7))) and 1 else bt := 0;
            if bt < nColors then C := Pal[bt];
          end;
        4:
          begin
            p := xorOff + NativeUInt(y) * xorRow + NativeUInt(x) div 2;
            if p < N then
            begin
              if (x and 1) = 0 then idx := (Data[p] shr 4) and $0F else idx := Data[p] and $0F;
              if idx < nColors then C := Pal[idx];
            end;
          end;
        8:
          begin
            p := xorOff + NativeUInt(y) * xorRow + NativeUInt(x);
            if p < N then begin idx := Data[p]; if idx < nColors then C := Pal[idx]; end;
          end;
        24:
          begin
            p := xorOff + NativeUInt(y) * xorRow + NativeUInt(x) * 3;
            if p + 2 < N then begin C.B := Data[p]; C.G := Data[p + 1]; C.R := Data[p + 2]; end;
          end;
        32:
          begin
            p := xorOff + NativeUInt(y) * xorRow + NativeUInt(x) * 4;
            if p + 3 < N then
            begin
              C.B := Data[p]; C.G := Data[p + 1]; C.R := Data[p + 2]; C.A := Data[p + 3];
              if C.A <> 0 then hasAlpha := True;
            end;
          end;
      else
        raise EIcoError.CreateFmt('ICO: unsupported bit count %d', [bitCount]);
      end;
      SetPx(Result, W, x, imgY, C);
    end;
  end;

  // Apply the 1bpp AND mask (bit set = transparent) for non-alpha images.
  applyMask := (bitCount < 32) or (not hasAlpha);
  if applyMask and (andOff < N) then
    for y := 0 to H - 1 do
    begin
      imgY := H - 1 - y;
      for x := 0 to W - 1 do
      begin
        ap := andOff + NativeUInt(y) * andRow + NativeUInt(x) div 8;
        if ap < N then
        begin
          andByte := Data[ap];
          if ((andByte shr (7 - (x and 7))) and 1) <> 0 then
          begin
            C := GetPx(Result, W, x, imgY);
            C.A := 0;
            SetPx(Result, W, x, imgY, C);
          end;
        end;
      end;
    end;
end;

function DecodeIcoDir(const Data: TBytes; DirOff: NativeUInt;
  Index: Integer; out Width, Height: Integer): TBytes;
var
  N: NativeUInt;
  Count: Integer;
  entry, imgOff, imgSize: NativeUInt;
begin
  Width := 0; Height := 0; SetLength(Result, 0);
  N := NativeUInt(Length(Data));
  if DirOff + 6 > N then raise EIcoError.Create('ICO: truncated directory');
  Count := RL16(Data, DirOff + 4);
  if (Index < 0) or (Index >= Count) then raise EIcoError.Create('ICO: image index out of range');

  entry := DirOff + 6 + NativeUInt(Index) * 16;
  if entry + 16 > N then raise EIcoError.Create('ICO: truncated directory entry');
  imgSize := RL32(Data, entry + 8);
  imgOff := DirOff + RL32(Data, entry + 12);
  if imgOff + 4 > N then raise EIcoError.Create('ICO: image offset out of range');

  // PNG entry?
  if (Data[imgOff] = $89) and (Data[imgOff + 1] = Ord('P')) and
     (Data[imgOff + 2] = Ord('N')) and (Data[imgOff + 3] = Ord('G')) then
  begin
    Result := DecodePng(Copy(Data, imgOff, imgSize), Width, Height);
    Exit;
  end;

  Result := DecodeDib(Data, imgOff, imgSize, Width, Height);
end;

function DecodeIcoImage(InBuf: TBytes; Index: Integer; out Width, Height: Integer): TBytes;
begin
  Result := DecodeIcoDir(InBuf, 0, Index, Width, Height);
end;

function DecodeIco(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Count, i, best, bestArea, w, h: Integer;
  entry: NativeUInt;
  ew, eh: Integer;
begin
  Count := IcoImageCount(InBuf);
  if Count <= 0 then raise EIcoError.Create('ICO: no images');
  // choose the largest entry by declared area (0 means 256)
  best := 0; bestArea := -1;
  for i := 0 to Count - 1 do
  begin
    entry := 6 + NativeUInt(i) * 16;
    ew := InBuf[entry]; if ew = 0 then ew := 256;
    eh := InBuf[entry + 1]; if eh = 0 then eh := 256;
    if ew * eh > bestArea then begin bestArea := ew * eh; best := i; end;
  end;
  Result := DecodeIcoImage(InBuf, best, w, h);
  Width := w; Height := h;
end;

end.
