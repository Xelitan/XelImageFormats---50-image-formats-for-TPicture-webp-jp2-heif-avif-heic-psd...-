unit XelDicom;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	DICOM (medical imaging) decoder                               //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// A DICOM file is an optional 128-byte preamble + "DICM", a file-meta group
// (0002,xxxx, always Explicit VR Little Endian) whose (0002,0010) Transfer
// Syntax UID selects the encoding of the dataset that follows, then the dataset
// itself. This decoder handles the first frame of:
//   * Implicit / Explicit VR Little Endian and Explicit VR Big Endian, i.e.
//     UNCOMPRESSED pixel data - MONOCHROME1/2 (8/16-bit, signed/unsigned, with
//     rescale slope/intercept and window centre/width, else min/max) and RGB.
//   * Encapsulated pixel data: JPEG (via XelJpeg), JPEG 2000 (via the project's
//     J2K codec) and DICOM RLE.
// JPEG-LS and other transfer syntaxes are reported as unsupported. This gives a
// display image, not a diagnostic-grade rendering.

interface

uses
  SysUtils, Classes, Math, XelPng, XelJpeg, JP2KCommon, JP2KCodec, JP2KDecGen;

type
  EDicomError = class(Exception);

function DecodeDicom(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8

implementation

type
  TReader = record
    Data: TBytes;
    Pos: NativeUInt;
    Big: Boolean;      // big-endian numeric
    Explicit: Boolean; // explicit VR
  end;

function RU16(const D: TBytes; P: NativeUInt; Big: Boolean): Word; inline;
begin
  if Big then Result := (Word(D[P]) shl 8) or Word(D[P + 1])
  else Result := Word(D[P]) or (Word(D[P + 1]) shl 8);
end;

function RU32(const D: TBytes; P: NativeUInt; Big: Boolean): Cardinal; inline;
begin
  if Big then
    Result := (Cardinal(D[P]) shl 24) or (Cardinal(D[P + 1]) shl 16) or
              (Cardinal(D[P + 2]) shl 8) or Cardinal(D[P + 3])
  else
    Result := Cardinal(D[P]) or (Cardinal(D[P + 1]) shl 8) or
              (Cardinal(D[P + 2]) shl 16) or (Cardinal(D[P + 3]) shl 24);
end;

function ReadStr(const D: TBytes; P: NativeUInt; Len: NativeUInt): string;
var I: NativeUInt;
begin
  Result := '';
  for I := 0 to Len - 1 do Result := Result + Chr(D[P + I]);
  Result := Trim(Result);
end;

function DSFirst(const S: string): Double;
var T: string; I, Code: Integer; V: Double; FS: TFormatSettings;
begin
  T := S;
  I := Pos('\', T);
  if I > 0 then T := Copy(T, 1, I - 1);
  FS := DefaultFormatSettings; FS.DecimalSeparator := '.'; FS.ThousandSeparator := #0;
  Val(Trim(T), V, Code);
  if Code = 0 then Result := V else Result := 0;
end;

// Reads one element header. Returns tag group/element, value length and the
// offset of the value; advances r.Pos past the header. Undefined length is
// returned as $FFFFFFFF.
procedure ReadElementHeader(var r: TReader; out G, E: Word; out Len: Cardinal;
  out ValPos: NativeUInt);
var
  VR: string;
begin
  G := RU16(r.Data, r.Pos, r.Big);
  E := RU16(r.Data, r.Pos + 2, r.Big);
  Inc(r.Pos, 4);
  if r.Explicit then
  begin
    VR := Chr(r.Data[r.Pos]) + Chr(r.Data[r.Pos + 1]);
    Inc(r.Pos, 2);
    if (VR = 'OB') or (VR = 'OW') or (VR = 'OF') or (VR = 'SQ') or
       (VR = 'UT') or (VR = 'UN') then
    begin
      Inc(r.Pos, 2);                       // 2 reserved bytes
      Len := RU32(r.Data, r.Pos, r.Big);
      Inc(r.Pos, 4);
    end
    else
    begin
      Len := RU16(r.Data, r.Pos, r.Big);
      Inc(r.Pos, 2);
    end;
  end
  else
  begin
    Len := RU32(r.Data, r.Pos, r.Big);
    Inc(r.Pos, 4);
  end;
  ValPos := r.Pos;
end;

// Skips an undefined-length sequence starting right after its header, using the
// balanced item/sequence delimiter (FFFE,E0DD) scan.
procedure SkipUndefined(var r: TReader);
var
  N: NativeUInt;
  G, E: Word;
  Len: Cardinal;
  Depth: Integer;
begin
  N := NativeUInt(Length(r.Data));
  Depth := 1;
  while (r.Pos + 8 <= N) and (Depth > 0) do
  begin
    G := RU16(r.Data, r.Pos, r.Big);
    E := RU16(r.Data, r.Pos + 2, r.Big);
    Len := RU32(r.Data, r.Pos + 4, r.Big);
    Inc(r.Pos, 8);
    if (G = $FFFE) and (E = $E0DD) then Dec(Depth)
    else if Len = $FFFFFFFF then Inc(Depth)
    else Inc(r.Pos, Len);
  end;
end;

// ---- JPEG 2000 fragment -> RGBA8 ----
function J2kToRGBA(const Frag: TBytes; out W, H: Integer): TBytes;
var
  Img: TJp2kImage;
  x, y, idx, sh, r, g, b: Integer;
  Col: TRGBA;
begin
  SetLength(Result, 0); W := 0; H := 0;
  Img := DecodeGeneral(Frag);
  try
    W := Img.W; H := Img.H;
    if (W <= 0) or (H <= 0) then Exit;
    sh := Img.Prec - 8;
    SetLength(Result, NativeInt(W) * NativeInt(H) * 4);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        idx := y * W + x;
        if Img.NumComps >= 3 then
        begin r := Img.Comps[0][idx]; g := Img.Comps[1][idx]; b := Img.Comps[2][idx]; end
        else begin r := Img.Comps[0][idx]; g := r; b := r; end;
        if sh > 0 then begin r := r shr sh; g := g shr sh; b := b shr sh; end
        else if sh < 0 then begin r := r shl (-sh); g := g shl (-sh); b := b shl (-sh); end;
        if r < 0 then r := 0 else if r > 255 then r := 255;
        if g < 0 then g := 0 else if g > 255 then g := 255;
        if b < 0 then b := 0 else if b > 255 then b := 255;
        Col.R := r; Col.G := g; Col.B := b; Col.A := 255;
        SetPx(Result, W, x, y, Col);
      end;
  finally
    Img.Free;
  end;
end;

// ---- DICOM RLE (PackBits per segment) -> planar bytes for one frame ----
function DicomRLE(const D: TBytes; Ofs, Len: NativeUInt; PixelCount: NativeUInt;
  out Segments: Integer): TBytes;
var
  NumSeg, s, i: Integer;
  SegOfs: array[0..14] of Cardinal;
  SegStart, SegEnd, p, outp: NativeUInt;
  n: Integer;
  b: Byte;
begin
  NumSeg := Integer(RU32(D, Ofs, False));
  for i := 0 to 14 do SegOfs[i] := RU32(D, Ofs + 4 + NativeUInt(i) * 4, False);
  Segments := NumSeg;
  SetLength(Result, PixelCount * NativeUInt(NumSeg));
  for s := 0 to NumSeg - 1 do
  begin
    SegStart := Ofs + SegOfs[s];
    if s + 1 < NumSeg then SegEnd := Ofs + SegOfs[s + 1] else SegEnd := Ofs + Len;
    p := SegStart;
    outp := NativeUInt(s) * PixelCount;      // each segment fills one plane
    while (p < SegEnd) and (outp < NativeUInt(s + 1) * PixelCount) do
    begin
      n := ShortInt(D[p]); Inc(p);
      if n >= 0 then
      begin
        for i := 0 to n do
        begin
          if (p >= SegEnd) or (outp >= NativeUInt(Length(Result))) then Break;
          Result[outp] := D[p]; Inc(p); Inc(outp);
        end;
      end
      else if n <> -128 then
      begin
        if p >= SegEnd then Break;
        b := D[p]; Inc(p);
        for i := 0 to -n do
        begin
          if outp >= NativeUInt(Length(Result)) then Break;
          Result[outp] := b; Inc(outp);
        end;
      end;
    end;
  end;
end;

function DecodeDicom(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  N, MetaStart: NativeUInt;
  r: TReader;
  G, E: Word;
  Len: Cardinal;
  ValPos: NativeUInt;
  Tsyntax, Photo: string;
  Rows, Cols, Spp, BitsAlloc, BitsStored, PixRep, Planar: Integer;
  RescaleSlope, RescaleInt, WinC, WinW: Double;
  HaveWin: Boolean;
  PixOfs, PixLen: NativeUInt;
  Encapsulated: Boolean;
  Frag: TBytes;
  PixelCount: NativeUInt;
  x, y, idx: Integer;
  Col: TRGBA;
  gmin, gmax, val, lo, hi, span: Double;
  raw16signed: Boolean;
  RleSegs: Integer;
  Rle: TBytes;

  function StoredValue(PixelIdx: Integer): Double;
  var o: NativeUInt; u16: Word; s16: SmallInt;
  begin
    if BitsAlloc = 16 then
    begin
      o := PixOfs + NativeUInt(PixelIdx) * 2;
      u16 := RU16(InBuf, o, r.Big);
      if raw16signed then begin s16 := SmallInt(u16); Result := s16; end
      else Result := u16;
    end
    else
      Result := InBuf[PixOfs + NativeUInt(PixelIdx)];
    Result := Result * RescaleSlope + RescaleInt;
  end;

begin
  Width := 0; Height := 0;
  SetLength(Result, 0);
  N := NativeUInt(Length(InBuf));
  if N < 136 then raise EDicomError.Create('DICOM: file too short');

  // defaults
  Rows := 0; Cols := 0; Spp := 1; BitsAlloc := 16; BitsStored := 16;
  PixRep := 0; Planar := 0; Photo := 'MONOCHROME2'; Tsyntax := '';
  RescaleSlope := 1; RescaleInt := 0; WinC := 0; WinW := 0; HaveWin := False;
  PixOfs := 0; PixLen := 0;

  // preamble + DICM?
  if (InBuf[128] = Ord('D')) and (InBuf[129] = Ord('I')) and
     (InBuf[130] = Ord('C')) and (InBuf[131] = Ord('M')) then
    MetaStart := 132
  else
    MetaStart := 0;   // no preamble: assume implicit VR LE dataset from start

  r.Data := InBuf;

  if MetaStart = 132 then
  begin
    // file-meta group: always Explicit VR LE. Peek each element's group first so
    // that when we reach the dataset (group <> 0002) r.Pos still sits on its tag.
    r.Pos := MetaStart; r.Big := False; r.Explicit := True;
    while (r.Pos + 8 <= N) do
    begin
      if RU16(InBuf, r.Pos, False) <> $0002 then Break;   // dataset starts here
      ReadElementHeader(r, G, E, Len, ValPos);
      if (G = $0002) and (E = $0010) then Tsyntax := ReadStr(InBuf, ValPos, Len);
      r.Pos := ValPos + Len;
    end;
  end
  else
    r.Pos := 0;

  // pick dataset encoding from the transfer syntax
  r.Big := False; r.Explicit := True; Encapsulated := False;
  if (Tsyntax = '1.2.840.10008.1.2') then r.Explicit := False
  else if (Tsyntax = '1.2.840.10008.1.2.1') then r.Explicit := True
  else if (Tsyntax = '1.2.840.10008.1.2.2') then begin r.Explicit := True; r.Big := True; end
  else if (Tsyntax = '') then
  begin
    // no file-meta group: detect implicit vs explicit VR from the first element
    // (bytes 4..5 are two uppercase letters for an explicit VR, else implicit).
    if (r.Pos + 6 <= N) and
       (InBuf[r.Pos + 4] >= Ord('A')) and (InBuf[r.Pos + 4] <= Ord('Z')) and
       (InBuf[r.Pos + 5] >= Ord('A')) and (InBuf[r.Pos + 5] <= Ord('Z')) then
      r.Explicit := True
    else
      r.Explicit := False;
  end
  else Encapsulated := True;                          // .4.xx JPEG/J2K or .5 RLE

  // walk the dataset
  while (r.Pos + 8 <= N) do
  begin
    ReadElementHeader(r, G, E, Len, ValPos);
    if (G = $7FE0) and (E = $0010) then
    begin
      PixOfs := ValPos; PixLen := Len;
      Break;
    end;
    if Len = $FFFFFFFF then
    begin
      r.Pos := ValPos; SkipUndefined(r);
      Continue;
    end;
    case G of
      $0028:
        case E of
          $0002: Spp := Integer(RU16(InBuf, ValPos, r.Big));
          $0004: Photo := ReadStr(InBuf, ValPos, Len);
          $0006: Planar := Integer(RU16(InBuf, ValPos, r.Big));
          $0010: Rows := Integer(RU16(InBuf, ValPos, r.Big));
          $0011: Cols := Integer(RU16(InBuf, ValPos, r.Big));
          $0100: BitsAlloc := Integer(RU16(InBuf, ValPos, r.Big));
          $0101: BitsStored := Integer(RU16(InBuf, ValPos, r.Big));
          $0103: PixRep := Integer(RU16(InBuf, ValPos, r.Big));
          $1050: begin WinC := DSFirst(ReadStr(InBuf, ValPos, Len)); HaveWin := True; end;
          $1051: begin WinW := DSFirst(ReadStr(InBuf, ValPos, Len)); HaveWin := True; end;
          $1052: RescaleInt := DSFirst(ReadStr(InBuf, ValPos, Len));
          $1053: RescaleSlope := DSFirst(ReadStr(InBuf, ValPos, Len));
        end;
    end;
    r.Pos := ValPos + Len;
  end;

  if (Rows <= 0) or (Cols <= 0) then raise EDicomError.Create('DICOM: no image dimensions');
  if UInt64(Cols) * UInt64(Rows) * 4 > UInt64(High(NativeInt)) then
    raise EDicomError.Create('DICOM: image too large');
  if RescaleSlope = 0 then RescaleSlope := 1;
  Width := Cols; Height := Rows;
  PixelCount := NativeUInt(Cols) * NativeUInt(Rows);
  raw16signed := (PixRep = 1);

  // -------- encapsulated (compressed) transfer syntaxes --------
  if Encapsulated then
  begin
    if PixOfs = 0 then raise EDicomError.Create('DICOM: no pixel data');
    // first item = basic offset table, then the first fragment = frame 0
    r.Pos := PixOfs;
    // item 1 (offset table)
    if not ((RU16(InBuf, r.Pos, False) = $FFFE) and (RU16(InBuf, r.Pos + 2, False) = $E000)) then
      raise EDicomError.Create('DICOM: malformed encapsulated pixel data');
    Len := RU32(InBuf, r.Pos + 4, False);
    Inc(r.Pos, 8 + Len);
    // first fragment
    if not ((RU16(InBuf, r.Pos, False) = $FFFE) and (RU16(InBuf, r.Pos + 2, False) = $E000)) then
      raise EDicomError.Create('DICOM: missing pixel fragment');
    Len := RU32(InBuf, r.Pos + 4, False);
    Inc(r.Pos, 8);
    SetLength(Frag, Len);
    if Len > 0 then Move(InBuf[r.Pos], Frag[0], Len);

    if (Pos('1.2.840.10008.1.2.4.90', Tsyntax) = 1) or
       (Pos('1.2.840.10008.1.2.4.91', Tsyntax) = 1) then
    begin
      Result := J2kToRGBA(Frag, Width, Height);
      Exit;
    end
    else if (Pos('1.2.840.10008.1.2.4.5', Tsyntax) = 1) or
            (Pos('1.2.840.10008.1.2.4.70', Tsyntax) = 1) or
            (Pos('1.2.840.10008.1.2.4.57', Tsyntax) = 1) then
    begin
      Result := DecodeJpeg(Frag, Width, Height);   // baseline/extended; lossless will fail
      Exit;
    end
    else if Tsyntax = '1.2.840.10008.1.2.5' then
    begin
      Rle := DicomRLE(InBuf, r.Pos, Len, PixelCount, RleSegs);
      // RLE stores planar segments; assemble 8- or 16-bit samples
      SetLength(Result, NativeInt(PixelCount * 4));
      for y := 0 to Rows - 1 do
        for x := 0 to Cols - 1 do
        begin
          idx := y * Cols + x;
          if (Spp >= 3) and (RleSegs >= 3) then
          begin
            Col.R := Rle[NativeUInt(0) * PixelCount + NativeUInt(idx)];
            Col.G := Rle[NativeUInt(1) * PixelCount + NativeUInt(idx)];
            Col.B := Rle[NativeUInt(2) * PixelCount + NativeUInt(idx)];
          end
          else
          begin
            Col.R := Rle[NativeUInt(idx)]; Col.G := Col.R; Col.B := Col.R;
          end;
          Col.A := 255;
          SetPx(Result, Cols, x, y, Col);
        end;
      Exit;
    end
    else
      raise EDicomError.CreateFmt('DICOM: unsupported transfer syntax %s', [Tsyntax]);
  end;

  // -------- uncompressed --------
  if PixOfs = 0 then raise EDicomError.Create('DICOM: no pixel data');
  if not ((BitsAlloc = 8) or (BitsAlloc = 16)) then
    raise EDicomError.CreateFmt('DICOM: unsupported bits allocated %d', [BitsAlloc]);

  SetLength(Result, NativeInt(PixelCount * 4));

  if (Spp >= 3) and SameText(Copy(Photo, 1, 3), 'RGB') then
  begin
    // 8-bit RGB, interleaved (planar 0) or planar (planar 1)
    for y := 0 to Rows - 1 do
      for x := 0 to Cols - 1 do
      begin
        idx := y * Cols + x;
        if Planar = 0 then
        begin
          Col.R := InBuf[PixOfs + NativeUInt(idx) * 3 + 0];
          Col.G := InBuf[PixOfs + NativeUInt(idx) * 3 + 1];
          Col.B := InBuf[PixOfs + NativeUInt(idx) * 3 + 2];
        end
        else
        begin
          Col.R := InBuf[PixOfs + NativeUInt(idx)];
          Col.G := InBuf[PixOfs + PixelCount + NativeUInt(idx)];
          Col.B := InBuf[PixOfs + 2 * PixelCount + NativeUInt(idx)];
        end;
        Col.A := 255;
        SetPx(Result, Cols, x, y, Col);
      end;
    Exit;
  end;

  // MONOCHROME: window/level or min-max stretch to 8-bit
  if HaveWin and (WinW > 0) then
  begin
    lo := WinC - WinW / 2; hi := WinC + WinW / 2; span := hi - lo;
    if span <= 0 then span := 1;
  end
  else
  begin
    gmin := 1e308; gmax := -1e308;
    for idx := 0 to Integer(PixelCount) - 1 do
    begin
      val := StoredValue(idx);
      if val < gmin then gmin := val;
      if val > gmax then gmax := val;
    end;
    lo := gmin; span := gmax - gmin;
    if span <= 0 then span := 1;
  end;

  for y := 0 to Rows - 1 do
    for x := 0 to Cols - 1 do
    begin
      idx := y * Cols + x;
      val := (StoredValue(idx) - lo) / span * 255;
      if val < 0 then val := 0 else if val > 255 then val := 255;
      if SameText(Photo, 'MONOCHROME1') then val := 255 - val;   // 0 = white
      Col.R := Byte(Round(val)); Col.G := Col.R; Col.B := Col.R; Col.A := 255;
      SetPx(Result, Cols, x, y, Col);
    end;
end;

end.
