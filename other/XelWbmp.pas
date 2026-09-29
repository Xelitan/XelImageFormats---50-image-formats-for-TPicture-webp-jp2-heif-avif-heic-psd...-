unit XelWbmp;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	WBMP (Wireless Bitmap, type 0) codec -> RGBA8                 //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Clean-room implementation from the public WAP WBMP specification.           //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelPng;

type
  EWbmpError = class(Exception);

// Dekoduje WBMP typu 0 (1 bit/piksel, bit=1 bialy, bit=0 czarny) do RGBA8.
function DecodeWbmp(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8

// Zapisuje WBMP typu 0. InBuf = RGBA8 (progowanie luminancji).
function EncodeWbmp(InBuf: TBytes; Width, Height: Integer): TBytes;        // InBuf = RGBA8

implementation

function ReadUintVar(const D: TBytes; var Pos: NativeUInt): Cardinal;
var
  N: NativeUInt;
  B: Byte;
  Guard: Integer;
begin
  Result := 0;
  N := NativeUInt(Length(D));
  Guard := 0;
  repeat
    if Pos >= N then raise EWbmpError.Create('WBMP: unexpected end of header');
    B := D[Pos]; Inc(Pos);
    Result := (Result shl 7) or Cardinal(B and $7F);
    Inc(Guard);
    if Guard > 5 then raise EWbmpError.Create('WBMP: multi-byte integer too long');
  until (B and $80) = 0;
end;

procedure AppendUintVar(var D: TBytes; var Len: NativeInt; V: Cardinal);
var
  Tmp: array[0..4] of Byte;
  n, i: Integer;
begin
  n := 0;
  repeat
    Tmp[n] := Byte(V and $7F);
    V := V shr 7;
    Inc(n);
  until V = 0;
  // emit most-significant group first, continuation bit set on all but the last
  for i := n - 1 downto 0 do
  begin
    if Len >= Length(D) then SetLength(D, Length(D) * 2 + 16);
    if i > 0 then D[Len] := Tmp[i] or $80 else D[Len] := Tmp[i];
    Inc(Len);
  end;
end;

function DecodeWbmp(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Pos, N: NativeUInt;
  TypeField, FixHdr: Cardinal;
  W, H: Cardinal;
  RowBytes, x, y: NativeUInt;
  BytePos: NativeUInt;
  Mask: Byte;
  C: TRGBA;
begin
  Width := 0; Height := 0; SetLength(Result, 0);
  N := NativeUInt(Length(InBuf));
  Pos := 0;
  TypeField := ReadUintVar(InBuf, Pos);
  if TypeField <> 0 then raise EWbmpError.CreateFmt('WBMP: unsupported type %d', [TypeField]);
  if Pos >= N then raise EWbmpError.Create('WBMP: missing fixed header');
  FixHdr := InBuf[Pos]; Inc(Pos);
  if FixHdr <> 0 then raise EWbmpError.Create('WBMP: extension headers not supported');

  W := ReadUintVar(InBuf, Pos);
  H := ReadUintVar(InBuf, Pos);
  if (W = 0) or (H = 0) or (W > Cardinal(High(Integer))) or (H > Cardinal(High(Integer))) then
    raise EWbmpError.Create('WBMP: invalid dimensions');

  RowBytes := (NativeUInt(W) + 7) div 8;
  if (Pos > N) or (RowBytes * NativeUInt(H) > N - Pos) then
    raise EWbmpError.Create('WBMP: truncated raster');

  Width := Integer(W); Height := Integer(H);
  SetLength(Result, NativeInt(UInt64(W) * UInt64(H) * 4));
  C.A := 255;
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      BytePos := Pos + y * RowBytes + (x shr 3);
      Mask := Byte($80 shr (x and 7));
      if (InBuf[BytePos] and Mask) <> 0 then begin C.R := 255; C.G := 255; C.B := 255; end   // 1 = white
      else begin C.R := 0; C.G := 0; C.B := 0; end;                                          // 0 = black
      SetPx(Result, Integer(W), Integer(x), Integer(y), C);
    end;
end;

function Luma(const C: TRGBA): Integer; inline;
begin
  Result := (Integer(C.R) * 77 + Integer(C.G) * 150 + Integer(C.B) * 29 + 128) shr 8;
end;

function EncodeWbmp(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  Len, Base: NativeInt;
  RowBytes, x, y: NativeUInt;
  C: TRGBA;
  Mask: Byte;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then raise EWbmpError.Create('WBMP: zero image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EWbmpError.Create('WBMP: RGBA8 buffer size does not match Width*Height*4');

  Len := 0;
  SetLength(Result, 16);
  AppendUintVar(Result, Len, 0);   // type 0
  if Len >= Length(Result) then SetLength(Result, Length(Result) + 1);
  Result[Len] := 0; Inc(Len);      // fixed header
  AppendUintVar(Result, Len, Cardinal(Width));
  AppendUintVar(Result, Len, Cardinal(Height));

  RowBytes := (NativeUInt(Width) + 7) div 8;
  Base := Len;
  SetLength(Result, Base + NativeInt(RowBytes) * Height);
  FillChar(Result[Base], NativeInt(RowBytes) * Height, 0);
  for y := 0 to NativeUInt(Height) - 1 do
    for x := 0 to NativeUInt(Width) - 1 do
    begin
      C := GetPx(InBuf, Width, Integer(x), Integer(y));
      if Luma(C) >= 128 then   // white -> bit 1
      begin
        Mask := Byte($80 shr (x and 7));
        Result[Base + NativeInt(y * RowBytes + (x shr 3))] :=
          Result[Base + NativeInt(y * RowBytes + (x shr 3))] or Mask;
      end;
    end;
end;

end.
