unit XelXbm;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	XBM (X11 BitMap, C source) codec -> RGBA8                     //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Clean-room implementation from the X11 XBM format (LSB-first, 1=set/black). //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelPng;

type
  EXbmError = class(Exception);

// Dekoduje XBM: bit LSB-first w bajcie, bit=1 -> czarny (set), bit=0 -> bialy.
function DecodeXbm(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8

// Zapisuje XBM (C source). InBuf = RGBA8 (progowanie luminancji, ciemny=set).
function EncodeXbm(InBuf: TBytes; Width, Height: Integer): TBytes;         // InBuf = RGBA8

implementation

function ToText(const D: TBytes): AnsiString;
begin
  SetLength(Result, Length(D));
  if Length(D) > 0 then Move(D[0], Result[1], Length(D));
end;

// Read the integer at the end of the line that contains <Suffix> (e.g. "_width").
function DefineValue(const S: AnsiString; const Suffix: AnsiString; out Value: Integer): Boolean;
var
  p, e, r: Integer;
  numStr: AnsiString;
begin
  Result := False;
  Value := 0;
  p := Pos(Suffix, S);
  if p = 0 then Exit;
  e := p;
  while (e <= Length(S)) and (S[e] <> #10) do Inc(e);
  r := e - 1;
  while (r >= p) and not (S[r] in ['0'..'9']) do Dec(r);
  numStr := '';
  while (r >= p) and (S[r] in ['0'..'9']) do
  begin
    numStr := S[r] + numStr;
    Dec(r);
  end;
  if numStr <> '' then
  begin
    Value := StrToIntDef(string(numStr), -1);
    Result := Value >= 0;
  end;
end;

function DecodeXbm(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  S: AnsiString;
  W, H, RowBytes, x, y, i, brace, val, ndig: Integer;
  Bytes: TBytes;
  nBytes: Integer;
  ch: AnsiChar;
  C: TRGBA;
  bt: Byte;
begin
  Width := 0; Height := 0; SetLength(Result, 0);
  S := ToText(InBuf);
  if not DefineValue(S, AnsiString('_width'), W) then raise EXbmError.Create('XBM: missing _width');
  if not DefineValue(S, AnsiString('_height'), H) then raise EXbmError.Create('XBM: missing _height');
  if (W <= 0) or (H <= 0) then raise EXbmError.Create('XBM: invalid dimensions');

  RowBytes := (W + 7) div 8;
  SetLength(Bytes, RowBytes * H);
  nBytes := 0;

  brace := Pos(AnsiString('{'), S);
  if brace = 0 then raise EXbmError.Create('XBM: missing data array');
  i := brace + 1;
  // parse hex (0x..) or decimal byte tokens until closing brace or array full
  while (i <= Length(S)) and (S[i] <> '}') and (nBytes < Length(Bytes)) do
  begin
    ch := S[i];
    if (ch = '0') and (i < Length(S)) and ((S[i+1] = 'x') or (S[i+1] = 'X')) then
    begin
      Inc(i, 2);
      val := 0; ndig := 0;
      while (i <= Length(S)) and (ndig < 2) and
            (S[i] in ['0'..'9', 'a'..'f', 'A'..'F']) do
      begin
        case S[i] of
          '0'..'9': val := val * 16 + (Ord(S[i]) - Ord('0'));
          'a'..'f': val := val * 16 + (Ord(S[i]) - Ord('a') + 10);
          'A'..'F': val := val * 16 + (Ord(S[i]) - Ord('A') + 10);
        end;
        Inc(i); Inc(ndig);
      end;
      if ndig > 0 then begin Bytes[nBytes] := Byte(val); Inc(nBytes); end;
    end
    else
      Inc(i);
  end;

  Width := W; Height := H;
  SetLength(Result, NativeInt(W) * H * 4);
  C.A := 255;
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      bt := Bytes[y * RowBytes + (x shr 3)];
      if (bt and (1 shl (x and 7))) <> 0 then   // LSB-first; set bit = black
        begin C.R := 0; C.G := 0; C.B := 0; end
      else
        begin C.R := 255; C.G := 255; C.B := 255; end;
      SetPx(Result, W, x, y, C);
    end;
end;

function Luma(const C: TRGBA): Integer; inline;
begin
  Result := (Integer(C.R) * 77 + Integer(C.G) * 150 + Integer(C.B) * 29 + 128) shr 8;
end;

procedure AppS(var D: TBytes; var Len: NativeInt; const S: AnsiString);
var i: Integer;
begin
  for i := 1 to Length(S) do
  begin
    if Len >= Length(D) then SetLength(D, Length(D) * 2 + 256);
    D[Len] := Byte(S[i]); Inc(Len);
  end;
end;

function EncodeXbm(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  Len: NativeInt;
  RowBytes, x, y, idx, total, i: Integer;
  bt: Byte;
  C: TRGBA;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then raise EXbmError.Create('XBM: zero image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EXbmError.Create('XBM: RGBA8 buffer size does not match Width*Height*4');

  RowBytes := (Width + 7) div 8;
  total := RowBytes * Height;
  Len := 0;
  SetLength(Result, 256);
  AppS(Result, Len, AnsiString(Format('#define image_width %d'#10, [Width])));
  AppS(Result, Len, AnsiString(Format('#define image_height %d'#10, [Height])));
  AppS(Result, Len, 'static unsigned char image_bits[] = {'#10' ');

  idx := 0;
  for y := 0 to Height - 1 do
    for i := 0 to RowBytes - 1 do
    begin
      bt := 0;
      for x := i * 8 to i * 8 + 7 do
        if x < Width then
        begin
          C := GetPx(InBuf, Width, x, y);
          if Luma(C) < 128 then bt := bt or Byte(1 shl (x and 7));   // dark -> set bit
        end;
      AppS(Result, Len, AnsiString(Format('0x%.2x', [bt])));
      Inc(idx);
      if idx < total then AppS(Result, Len, ',');
      if (idx mod 12) = 0 then AppS(Result, Len, #10' ');
    end;
  AppS(Result, Len, #10'};'#10);
  SetLength(Result, Len);
end;

end.
