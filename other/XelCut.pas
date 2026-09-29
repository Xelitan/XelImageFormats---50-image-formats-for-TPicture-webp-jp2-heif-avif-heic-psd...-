unit XelCut;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Dr. Halo CUT image + PAL palette decoder -> RGBA8             //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// CUT: u16 width, u16 height, u16 reserved, then per row: u16 byte count and  //
// RLE bytes (0 = end of row; high bit clear = N literal bytes; high bit set = //
// repeat next byte N and 7F times). Colours come from a separate .PAL file:   //
// 40-byte "AH" header (MaxIndex at +12, MaxRed/Green/Blue at +14/+16/+18),    //
// then 16-bit R,G,B entries packed into 512-byte blocks (an entry never       //
// crosses a block boundary). Without a palette a gray ramp is used.           //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelPng;

type
  ECutError = class(Exception);

// Dekoduje CUT bez palety (skala szarosci dopasowana do zakresu indeksow).
function DecodeCut(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8
// Dekoduje CUT z paleta z pliku .PAL (PalBuf moze byc pusty).
function DecodeCutPal(InBuf, PalBuf: TBytes; out Width, Height: Integer): TBytes;

implementation

function RL16(const D: TBytes; P: NativeUInt): Word; inline;
begin
  Result := Word(D[P]) or (Word(D[P + 1]) shl 8);
end;

type
  TPal = array[0..255] of TRGBA;

function ParseHaloPal(const P: TBytes; out Pal: TPal): Boolean;
var
  N, pos: NativeUInt;
  MaxIdx, i: Integer;
  MaxR, MaxG, MaxB: Integer;

  function Scale(V, M: Integer): Byte;
  begin
    if (M <= 0) or (M = 255) then
    begin
      if V > 255 then V := 255;
      Result := Byte(V);
    end
    else
    begin
      if V > M then V := M;
      Result := Byte((V * 255 + M div 2) div M);
    end;
  end;

begin
  Result := False;
  N := NativeUInt(Length(P));
  if (N < 40) or (P[0] <> Ord('A')) or (P[1] <> Ord('H')) then Exit;
  MaxIdx := RL16(P, 12);
  MaxR := RL16(P, 14); MaxG := RL16(P, 16); MaxB := RL16(P, 18);
  if MaxIdx > 255 then MaxIdx := 255;
  for i := 0 to 255 do
  begin
    Pal[i].R := 0; Pal[i].G := 0; Pal[i].B := 0; Pal[i].A := 255;
  end;
  pos := 40;
  for i := 0 to MaxIdx do
  begin
    if (pos mod 512) > 506 then pos := (pos div 512 + 1) * 512;
    if pos + 6 > N then Break;
    Pal[i].R := Scale(RL16(P, pos), MaxR);
    Pal[i].G := Scale(RL16(P, pos + 2), MaxG);
    Pal[i].B := Scale(RL16(P, pos + 4), MaxB);
    Inc(pos, 6);
  end;
  Result := True;
end;

// Unpack one RLE row starting at Pos (after the u16 count) into Row; returns bytes produced.
function UnpackRow(const D: TBytes; Pos, LineEnd: NativeUInt; var Row: TBytes): Integer;
var
  cnt, k: Integer;
  b, v: Byte;
begin
  Result := 0;
  while Pos < LineEnd do
  begin
    b := D[Pos]; Inc(Pos);
    if b = 0 then Break;
    cnt := b and $7F;
    if (b and $80) = 0 then
      for k := 1 to cnt do
      begin
        if Pos >= LineEnd then Break;
        if Result < Length(Row) then Row[Result] := D[Pos];
        Inc(Pos); Inc(Result);
      end
    else
    begin
      if Pos >= LineEnd then Break;
      v := D[Pos]; Inc(Pos);
      for k := 1 to cnt do
      begin
        if Result < Length(Row) then Row[Result] := v;
        Inc(Result);
      end;
    end;
  end;
end;

function DecodeCutPal(InBuf, PalBuf: TBytes; out Width, Height: Integer): TBytes;
var
  N, Pos, LineEnd: NativeUInt;
  W, H, x, y, i, Got, Bits, MaxIdx: Integer;
  Idx, Row: TBytes;
  v: Byte;
  Pal: TPal;
begin
  Width := 0; Height := 0; SetLength(Result, 0);
  N := NativeUInt(Length(InBuf));
  if N < 8 then raise ECutError.Create('CUT: file too small');
  W := RL16(InBuf, 0);
  H := RL16(InBuf, 2);
  if (W <= 0) or (H <= 0) then raise ECutError.Create('CUT: invalid dimensions');

  // Bits per pixel is inferred from how many bytes the first row expands to:
  // W -> 8 bit, W/2 -> 4 bit (packed nibbles), W/8 -> 1 bit (packed bits).
  SetLength(Row, W + 16);
  LineEnd := 8 + RL16(InBuf, 6);
  if LineEnd > N then LineEnd := N;
  Got := UnpackRow(InBuf, 8, LineEnd, Row);
  if Got * 8 = W then Bits := 1
  else if Got * 2 = W then Bits := 4
  else Bits := 8;

  SetLength(Idx, W * H);
  FillChar(Idx[0], Length(Idx), 0);
  Pos := 6;
  for y := 0 to H - 1 do
  begin
    if Pos + 2 > N then Break;
    LineEnd := Pos + 2 + RL16(InBuf, Pos);
    if LineEnd > N then LineEnd := N;
    FillChar(Row[0], Length(Row), 0);
    UnpackRow(InBuf, Pos + 2, LineEnd, Row);
    for x := 0 to W - 1 do
      case Bits of
        1: Idx[y * W + x] := (Row[x shr 3] shr (7 - (x and 7))) and 1;
        4: if (x and 1) = 0 then Idx[y * W + x] := Row[x shr 1] shr 4
           else Idx[y * W + x] := Row[x shr 1] and $0F;
      else
        Idx[y * W + x] := Row[x];
      end;
    Pos := LineEnd;
  end;

  if not ParseHaloPal(PalBuf, Pal) then
  begin
    // No palette: the index is used as the gray level; a two-colour image
    // (indices 0/1 only) is shown black/white.
    MaxIdx := 0;
    for i := 0 to High(Idx) do if Idx[i] > MaxIdx then MaxIdx := Idx[i];
    for i := 0 to 255 do
    begin
      v := Byte(i);
      if (MaxIdx <= 1) and (i = 1) then v := 255;
      Pal[i].R := v; Pal[i].G := v; Pal[i].B := v; Pal[i].A := 255;
    end;
  end;

  Width := W; Height := H;
  SetLength(Result, NativeInt(W) * H * 4);
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
      SetPx(Result, W, x, y, Pal[Idx[y * W + x]]);
end;

function DecodeCut(InBuf: TBytes; out Width, Height: Integer): TBytes;
begin
  Result := DecodeCutPal(InBuf, nil, Width, Height);
end;

end.
