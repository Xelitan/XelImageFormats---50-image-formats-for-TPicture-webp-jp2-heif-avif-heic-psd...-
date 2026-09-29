unit XelCel;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Autodesk Animator CEL / PIC codec -> RGBA8                    //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Layout: word magic $9119, 30-byte header (W,H,X,Y, depth=8, compression=0,  //
// data size, 16 reserved), 768-byte 6-bit RGB palette, W*H 8-bit pixels.      //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelPng;

type
  ECelError = class(Exception);

function DecodeCel(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8
// Zapisuje CEL/PIC (8 bit, paleta 6-bit). Paleta dokladna gdy <=256 kolorow,
// w przeciwnym razie stala kostka 6x7x6. InBuf = RGBA8.
function EncodeCel(InBuf: TBytes; Width, Height: Integer): TBytes;         // InBuf = RGBA8

implementation

const
  CEL_MAGIC  = $9119;
  CEL_HEADER = 32;        // magic + 30-byte header
  CEL_PAL    = 768;

function RL16(const D: TBytes; P: NativeUInt): Word; inline;
begin
  Result := Word(D[P]) or (Word(D[P + 1]) shl 8);
end;

function Six2Eight(V: Byte): Byte; inline;
begin
  V := V and 63;
  Result := (V shl 2) or (V shr 4);
end;

function DecodeCel(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  N, PixOff: NativeUInt;
  W, H, x, y, i: Integer;
  Pal: array[0..255] of TRGBA;
  C: TRGBA;
  Pal6: Boolean;
begin
  Width := 0; Height := 0; SetLength(Result, 0);
  N := NativeUInt(Length(InBuf));
  if N < CEL_HEADER + CEL_PAL then raise ECelError.Create('CEL: file too small');
  if RL16(InBuf, 0) <> CEL_MAGIC then raise ECelError.Create('CEL: bad magic');
  W := RL16(InBuf, 2);
  H := RL16(InBuf, 4);
  if InBuf[10] <> 8 then raise ECelError.CreateFmt('CEL: unsupported depth %d', [InBuf[10]]);
  // The "compression" byte is not reliable in the wild (some writers leave junk
  // there); the only layout ever used is uncompressed, checked by size below.
  if (W <= 0) or (H <= 0) then raise ECelError.Create('CEL: invalid dimensions');

  // Palette is 6-bit (0..63) in Animator files; accept 8-bit ones too.
  Pal6 := True;
  for i := 0 to CEL_PAL - 1 do
    if InBuf[CEL_HEADER + i] > 63 then begin Pal6 := False; Break; end;
  for i := 0 to 255 do
  begin
    if Pal6 then
    begin
      Pal[i].R := Six2Eight(InBuf[CEL_HEADER + i * 3]);
      Pal[i].G := Six2Eight(InBuf[CEL_HEADER + i * 3 + 1]);
      Pal[i].B := Six2Eight(InBuf[CEL_HEADER + i * 3 + 2]);
    end
    else
    begin
      Pal[i].R := InBuf[CEL_HEADER + i * 3];
      Pal[i].G := InBuf[CEL_HEADER + i * 3 + 1];
      Pal[i].B := InBuf[CEL_HEADER + i * 3 + 2];
    end;
    Pal[i].A := 255;
  end;

  PixOff := CEL_HEADER + CEL_PAL;
  if PixOff + NativeUInt(W) * NativeUInt(H) > N then
    raise ECelError.Create('CEL: truncated pixel data');

  Width := W; Height := H;
  SetLength(Result, NativeInt(W) * H * 4);
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      C := Pal[InBuf[PixOff + NativeUInt(y) * NativeUInt(W) + NativeUInt(x)]];
      SetPx(Result, W, x, y, C);
    end;
end;

procedure PutL16(var D: TBytes; P: NativeUInt; V: Word); inline;
begin
  D[P] := Byte(V); D[P + 1] := Byte(V shr 8);
end;

procedure PutL32(var D: TBytes; P: NativeUInt; V: Cardinal); inline;
begin
  D[P] := Byte(V); D[P + 1] := Byte(V shr 8); D[P + 2] := Byte(V shr 16); D[P + 3] := Byte(V shr 24);
end;

function EncodeCel(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  Pal: array[0..255] of Cardinal;      // $RRGGBB (6-bit reduced colours)
  NPal, i, x, y, idx: Integer;
  C: TRGBA;
  key: Cardinal;
  Exact: Boolean;
  Map: array of Integer;               // hash: 18-bit key -> index+1
  PixOff: NativeUInt;
  ri, gi, bi: Integer;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) or (Width > 65535) or (Height > 65535) then
    raise ECelError.Create('CEL: invalid image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise ECelError.Create('CEL: RGBA8 buffer size does not match Width*Height*4');

  // try an exact palette over the 6-bit reduced colours
  SetLength(Map, 1 shl 18);
  NPal := 0; Exact := True;
  for y := 0 to Height - 1 do
  begin
    for x := 0 to Width - 1 do
    begin
      C := GetPx(InBuf, Width, x, y);
      key := (Cardinal(C.R shr 2) shl 12) or (Cardinal(C.G shr 2) shl 6) or Cardinal(C.B shr 2);
      if Map[key] = 0 then
      begin
        if NPal = 256 then begin Exact := False; Break; end;
        Pal[NPal] := key; Inc(NPal); Map[key] := NPal;
      end;
    end;
    if not Exact then Break;
  end;

  if not Exact then
  begin
    // fixed 6x7x6 colour cube
    NPal := 0;
    for ri := 0 to 5 do
      for gi := 0 to 6 do
        for bi := 0 to 5 do
        begin
          Pal[NPal] := (Cardinal(ri * 63 div 5) shl 12) or (Cardinal(gi * 63 div 6) shl 6) or Cardinal(bi * 63 div 5);
          Inc(NPal);
        end;
  end;

  PixOff := CEL_HEADER + CEL_PAL;
  SetLength(Result, PixOff + NativeUInt(Width) * NativeUInt(Height));
  FillChar(Result[0], Length(Result), 0);
  PutL16(Result, 0, CEL_MAGIC);
  PutL16(Result, 2, Word(Width));
  PutL16(Result, 4, Word(Height));
  Result[10] := 8;                       // depth
  Result[11] := 0;                       // compression
  PutL32(Result, 12, Cardinal(Width) * Cardinal(Height));
  for i := 0 to NPal - 1 do
  begin
    Result[CEL_HEADER + i * 3]     := Byte((Pal[i] shr 12) and 63);
    Result[CEL_HEADER + i * 3 + 1] := Byte((Pal[i] shr 6) and 63);
    Result[CEL_HEADER + i * 3 + 2] := Byte(Pal[i] and 63);
  end;

  for y := 0 to Height - 1 do
    for x := 0 to Width - 1 do
    begin
      C := GetPx(InBuf, Width, x, y);
      if Exact then
        idx := Map[(Cardinal(C.R shr 2) shl 12) or (Cardinal(C.G shr 2) shl 6) or Cardinal(C.B shr 2)] - 1
      else
        idx := ((C.R * 5 + 127) div 255) * 42 + ((C.G * 6 + 127) div 255) * 6 + ((C.B * 5 + 127) div 255);
      Result[PixOff + NativeUInt(y) * NativeUInt(Width) + NativeUInt(x)] := Byte(idx);
    end;
end;

end.
