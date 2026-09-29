unit XelFits;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	FITS (Flexible Image Transport System) decoder/encoder        //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// FITS layout (only the parts an image loader needs):
//   * The file is a sequence of 2880-byte blocks. The primary header is made of
//     80-byte "cards" ("KEYWORD = value / comment"), packed into whole blocks,
//     ending with a bare "END" card. Data follows, again padded to 2880.
//   * BITPIX gives the sample type: 8 (unsigned byte), 16/32/64 (signed BE int),
//     -32/-64 (IEEE BE float/double). Physical = BZERO + BSCALE * stored.
//   * NAXIS1 = width, NAXIS2 = height. A third axis of length 3 is treated as
//     R,G,B planes (plane-separated); otherwise the image is grayscale.
//   * Rows run bottom-to-top (origin lower-left), so we flip vertically.
//   * For display we min/max stretch the physical values to 0..255.

interface

uses
  SysUtils, Classes, XelPng;

type
  EFitsError = class(Exception);

// Decodes the primary image HDU of a FITS file to RGBA8 (alpha = 255).
function DecodeFits(InBuf: TBytes; out Width, Height: Integer): TBytes;

// Writes a minimal FITS: BITPIX=8, a 3-plane (R,G,B) image, BZERO=0/BSCALE=1.
// InBuf = RGBA8; alpha is dropped.
function EncodeFits(InBuf: TBytes; Width, Height: Integer): TBytes;

implementation

const
  CardSize  = 80;
  BlockSize = 2880;

// ----------------------------- big-endian reads ----------------------------

function BEU16(const D: TBytes; P: NativeUInt): Word; inline;
begin
  Result := (Word(D[P]) shl 8) or Word(D[P + 1]);
end;

function BEU32(const D: TBytes; P: NativeUInt): Cardinal; inline;
begin
  Result := (Cardinal(D[P]) shl 24) or (Cardinal(D[P + 1]) shl 16) or
            (Cardinal(D[P + 2]) shl 8) or Cardinal(D[P + 3]);
end;

function BEU64(const D: TBytes; P: NativeUInt): UInt64; inline;
begin
  Result := (UInt64(BEU32(D, P)) shl 32) or UInt64(BEU32(D, P + 4));
end;

// ------------------------------ header parsing -----------------------------

function CardKeyword(const D: TBytes; CardOfs: NativeUInt): string;
var
  I: Integer;
  Ch: Byte;
begin
  Result := '';
  for I := 0 to 7 do
  begin
    Ch := D[CardOfs + NativeUInt(I)];
    if Ch = 32 then Break;
    Result := Result + Chr(Ch);
  end;
end;

// Value field of a fixed-format card: characters 11..80, up to a '/' comment.
function CardValue(const D: TBytes; CardOfs: NativeUInt): string;
var
  I: Integer;
  Ch: Byte;
begin
  Result := '';
  for I := 10 to CardSize - 1 do
  begin
    Ch := D[CardOfs + NativeUInt(I)];
    if Ch = Ord('/') then Break;
    Result := Result + Chr(Ch);
  end;
  Result := Trim(Result);
end;

function ValToInt(const S: string; Def: Int64): Int64;
var
  Code: Integer;
  V: Int64;
begin
  Val(Trim(S), V, Code);
  if Code = 0 then Result := V else Result := Def;
end;

function ValToFloat(const S: string; Def: Double): Double;
var
  FS: TFormatSettings;
  V: Double;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  if TryStrToFloat(Trim(S), V, FS) then Result := V else Result := Def;
end;

function DecodeFits(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  N, CardOfs: NativeUInt;
  Kw: string;
  BitPix, NAxis, N1, N2, N3, Planes: Integer;
  BZero, BScale: Double;
  HeaderCards: NativeUInt;
  DataStart, BytesPer, Idx, TotalSamples: NativeUInt;
  SampleOfs: NativeUInt;
  GMin, GMax, V, Span: Double;
  p, r, c: Integer;
  YTop: Integer;
  U: Cardinal;
  U64: UInt64;
  F32: Single;
  F64: Double;
  Col: TRGBA;
  GrayB: Byte;
  Vals: array of Double;

  function ReadSample(SIndex: NativeUInt): Double;
  var
    Ofs: NativeUInt;
    i16: SmallInt;
    i32: LongInt;
    i64: Int64;
  begin
    Ofs := DataStart + SIndex * BytesPer;
    case BitPix of
      8:  Result := InBuf[Ofs];
      16: begin
            i16 := SmallInt(BEU16(InBuf, Ofs));
            Result := i16;
          end;
      32: begin
            i32 := LongInt(BEU32(InBuf, Ofs));
            Result := i32;
          end;
      64: begin
            i64 := Int64(BEU64(InBuf, Ofs));
            Result := i64;
          end;
      -32: begin
             U := BEU32(InBuf, Ofs);
             Move(U, F32, 4);
             Result := F32;
           end;
      -64: begin
             U64 := BEU64(InBuf, Ofs);
             Move(U64, F64, 8);
             Result := F64;
           end;
    else
      Result := 0;
    end;
    Result := BZero + BScale * Result;
  end;

begin
  Width := 0;
  Height := 0;
  SetLength(Result, 0);

  N := NativeUInt(Length(InBuf));
  if N < BlockSize then
    raise EFitsError.Create('FITS: file shorter than one header block');
  if (InBuf[0] <> Ord('S')) or (InBuf[1] <> Ord('I')) or
     (InBuf[2] <> Ord('M')) or (InBuf[3] <> Ord('P')) then
    raise EFitsError.Create('FITS: missing SIMPLE keyword');

  BitPix := 0; NAxis := 0; N1 := 0; N2 := 0; N3 := 1;
  BZero := 0; BScale := 1;

  CardOfs := 0;
  HeaderCards := 0;
  while CardOfs + CardSize <= N do
  begin
    Kw := CardKeyword(InBuf, CardOfs);
    Inc(HeaderCards);
    if Kw = 'END' then Break;
    if Kw = 'BITPIX' then BitPix := Integer(ValToInt(CardValue(InBuf, CardOfs), 0))
    else if Kw = 'NAXIS' then NAxis := Integer(ValToInt(CardValue(InBuf, CardOfs), 0))
    else if Kw = 'NAXIS1' then N1 := Integer(ValToInt(CardValue(InBuf, CardOfs), 0))
    else if Kw = 'NAXIS2' then N2 := Integer(ValToInt(CardValue(InBuf, CardOfs), 0))
    else if Kw = 'NAXIS3' then N3 := Integer(ValToInt(CardValue(InBuf, CardOfs), 0))
    else if Kw = 'BZERO' then BZero := ValToFloat(CardValue(InBuf, CardOfs), 0)
    else if Kw = 'BSCALE' then BScale := ValToFloat(CardValue(InBuf, CardOfs), 1);
    Inc(CardOfs, CardSize);
  end;

  if (BitPix = 0) then
    raise EFitsError.Create('FITS: missing/invalid BITPIX');
  if (NAxis < 2) or (N1 <= 0) or (N2 <= 0) then
    raise EFitsError.Create('FITS: primary HDU is not a 2-D image');
  if (BScale = 0) then BScale := 1;

  if (NAxis >= 3) and (N3 = 3) then Planes := 3 else Planes := 1;

  BytesPer := NativeUInt(Abs(BitPix)) div 8;
  // header size rounded up to a whole 2880 block
  DataStart := ((HeaderCards * CardSize + (BlockSize - 1)) div BlockSize) * BlockSize;

  TotalSamples := NativeUInt(N1) * NativeUInt(N2) * NativeUInt(Planes);
  if DataStart + TotalSamples * BytesPer > N then
    raise EFitsError.Create('FITS: truncated data segment');
  if UInt64(N1) * UInt64(N2) * 4 > UInt64(High(NativeInt)) then
    raise EFitsError.Create('FITS: image too large');

  // gather physical values and find min/max for a linear display stretch
  SetLength(Vals, TotalSamples);
  GMin := 1e308; GMax := -1e308;
  for Idx := 0 to TotalSamples - 1 do
  begin
    V := ReadSample(Idx);
    Vals[Idx] := V;
    if V < GMin then GMin := V;
    if V > GMax then GMax := V;
  end;
  Span := GMax - GMin;
  if Span <= 0 then Span := 1;

  Width := N1;
  Height := N2;
  SetLength(Result, NativeInt(NativeUInt(N1) * NativeUInt(N2) * 4));

  for r := 0 to N2 - 1 do
  begin
    YTop := N2 - 1 - r;          // file row 0 = bottom of the image
    for c := 0 to N1 - 1 do
    begin
      if Planes = 3 then
      begin
        Col.R := Byte(Round((Vals[0 * NativeUInt(N1) * NativeUInt(N2) +
                    NativeUInt(r) * NativeUInt(N1) + NativeUInt(c)] - GMin) / Span * 255));
        Col.G := Byte(Round((Vals[1 * NativeUInt(N1) * NativeUInt(N2) +
                    NativeUInt(r) * NativeUInt(N1) + NativeUInt(c)] - GMin) / Span * 255));
        Col.B := Byte(Round((Vals[2 * NativeUInt(N1) * NativeUInt(N2) +
                    NativeUInt(r) * NativeUInt(N1) + NativeUInt(c)] - GMin) / Span * 255));
      end
      else
      begin
        GrayB := Byte(Round((Vals[NativeUInt(r) * NativeUInt(N1) + NativeUInt(c)] - GMin)
                   / Span * 255));
        Col.R := GrayB; Col.G := GrayB; Col.B := GrayB;
      end;
      Col.A := 255;
      SetPx(Result, N1, c, YTop, Col);
    end;
  end;
  // silence "assigned and never used" style hints for p in the grayscale path
  p := Planes;
  if p < 0 then Exit;
end;

// --------------------------------- encoder ---------------------------------

procedure AppendCard(var D: TBytes; const S: AnsiString);
var
  M: NativeInt;
  Card: AnsiString;
begin
  Card := S;
  while Length(Card) < CardSize do Card := Card + ' ';
  if Length(Card) > CardSize then SetLength(Card, CardSize);
  M := Length(D);
  SetLength(D, M + CardSize);
  Move(Card[1], D[M], CardSize);
end;

function EncodeFits(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  Header: TBytes;
  Pad, r, c, YTop, plane: Integer;
  Col: TRGBA;
  DataStart: NativeInt;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then
    raise EFitsError.Create('FITS: zero image size');
  if NativeUInt(Length(InBuf)) < NativeUInt(Width) * NativeUInt(Height) * 4 then
    raise EFitsError.Create('FITS: RGBA8 buffer too small');

  SetLength(Header, 0);
  AppendCard(Header, 'SIMPLE  =                    T');
  AppendCard(Header, 'BITPIX  =                    8');
  AppendCard(Header, 'NAXIS   =                    3');
  AppendCard(Header, 'NAXIS1  = ' + AnsiString(IntToStr(Width)));
  AppendCard(Header, 'NAXIS2  = ' + AnsiString(IntToStr(Height)));
  AppendCard(Header, 'NAXIS3  =                    3');
  AppendCard(Header, 'BZERO   =                    0');
  AppendCard(Header, 'BSCALE  =                    1');
  AppendCard(Header, 'END');

  // pad header to a whole 2880 block
  Pad := (BlockSize - (Length(Header) mod BlockSize)) mod BlockSize;
  if Pad > 0 then
  begin
    DataStart := Length(Header);
    SetLength(Header, DataStart + Pad);
    FillChar(Header[DataStart], Pad, 32);   // header padding is spaces
  end;

  DataStart := Length(Header);
  Result := Copy(Header, 0, Length(Header));
  SetLength(Result, DataStart + NativeInt(Width) * NativeInt(Height) * 3);

  // three planes (R, then G, then B), rows bottom-to-top
  for plane := 0 to 2 do
    for r := 0 to Height - 1 do
    begin
      YTop := Height - 1 - r;
      for c := 0 to Width - 1 do
      begin
        Col := GetPx(InBuf, Width, c, YTop);
        case plane of
          0: Result[DataStart + (NativeInt(plane) * Height * Width) +
                    (NativeInt(r) * Width + c)] := Col.R;
          1: Result[DataStart + (NativeInt(plane) * Height * Width) +
                    (NativeInt(r) * Width + c)] := Col.G;
        else
          Result[DataStart + (NativeInt(plane) * Height * Width) +
                 (NativeInt(r) * Width + c)] := Col.B;
        end;
      end;
    end;

  // pad data to a whole 2880 block
  Pad := (BlockSize - (Length(Result) mod BlockSize)) mod BlockSize;
  if Pad > 0 then
  begin
    DataStart := Length(Result);
    SetLength(Result, DataStart + Pad);
    FillChar(Result[DataStart], Pad, 0);
  end;
end;

end.
