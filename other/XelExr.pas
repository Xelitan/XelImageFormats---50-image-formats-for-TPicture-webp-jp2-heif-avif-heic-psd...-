unit XelExr;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	OpenEXR (High Dynamic Range) decoder                          //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// Decodes scanline OpenEXR images with NO_COMPRESSION, ZIP and ZIPS (the two
// zlib variants). Channels HALF / FLOAT / UINT are read; the R,G,B(,A) channels
// are converted from scene-linear to sRGB (clamped) for display. Tiled files and
// the PIZ / PXR24 / B44 / DWA compressions are reported as unsupported. HDR is
// tone-mapped only by clamp+gamma (no exposure metadata is applied).

interface

uses
  SysUtils, Classes, Math, XelPng, XelInflate;

type
  EExrError = class(Exception);

function DecodeExr(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8

implementation

type
  TExrChannel = record
    Name: string;
    PixType: Integer;      // 0=UINT, 1=HALF, 2=FLOAT
    Size: Integer;         // bytes: 4/2/4
  end;

function LEU32(const D: TBytes; P: NativeUInt): Cardinal; inline;
begin
  Result := Cardinal(D[P]) or (Cardinal(D[P+1]) shl 8) or
            (Cardinal(D[P+2]) shl 16) or (Cardinal(D[P+3]) shl 24);
end;

function LEI32(const D: TBytes; P: NativeUInt): Integer; inline;
begin
  Result := Integer(LEU32(D, P));
end;

function LEU64(const D: TBytes; P: NativeUInt): UInt64; inline;
begin
  Result := UInt64(LEU32(D, P)) or (UInt64(LEU32(D, P+4)) shl 32);
end;

function HalfToFloat(h: Word): Single;
var s, e, m, f: Cardinal;
begin
  s := (h shr 15) and 1; e := (h shr 10) and $1F; m := h and $3FF;
  if e = 0 then
  begin
    if m = 0 then f := s shl 31
    else
    begin
      while (m and $400) = 0 do begin m := m shl 1; e := e - 1; end;
      e := e + 1; m := m and (not Cardinal($400));
      e := e + (127 - 15);
      f := (s shl 31) or (e shl 23) or (m shl 13);
    end;
  end
  else if e = $1F then
    f := (s shl 31) or (Cardinal($FF) shl 23) or (m shl 13)
  else
  begin
    e := e + (127 - 15);
    f := (s shl 31) or (e shl 23) or (m shl 13);
  end;
  Move(f, Result, 4);
end;

function ReadString(const D: TBytes; var P: NativeUInt; N: NativeUInt): string;
begin
  Result := '';
  while (P < N) and (D[P] <> 0) do begin Result := Result + Chr(D[P]); Inc(P); end;
  Inc(P);   // skip null
end;

function SRGBB(c: Single): Byte; inline;
begin
  if c <= 0 then Result := 0
  else if c >= 1 then Result := 255
  else if c <= 0.0031308 then Result := Byte(Round(c * 12.92 * 255))
  else Result := Byte(Round((1.055 * Power(c, 1/2.4) - 0.055) * 255));
end;

// EXR ZIP post-process: predictor then de-interleave (in place -> Out).
procedure ExrReconstruct(const Src: TBytes; var Dst: TBytes; Len: NativeInt);
var
  Tmp: TBytes;
  i, half: NativeInt;
  t1, t2, s: NativeInt;
  d: Integer;
begin
  SetLength(Tmp, Len);
  if Len > 0 then Move(Src[0], Tmp[0], Len);
  // predictor
  for i := 1 to Len - 1 do
  begin
    d := Integer(Tmp[i-1]) + Integer(Tmp[i]) - 128;
    Tmp[i] := Byte(d);
  end;
  // de-interleave
  SetLength(Dst, Len);
  half := (Len + 1) div 2;
  t1 := 0; t2 := half; s := 0;
  while s < Len do
  begin
    Dst[s] := Tmp[t1]; Inc(t1); Inc(s);
    if s >= Len then Break;
    Dst[s] := Tmp[t2]; Inc(t2); Inc(s);
  end;
end;

function DecodeExr(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  N, P: NativeUInt;
  ver, flags: Cardinal;
  aName, aType: string;
  aSize: Cardinal;
  chans: array of TExrChannel;
  compression, lineOrder: Integer;
  xMin, yMin, xMax, yMax: Integer;
  W, H, linesPerBlock, numBlocks, bytesPerScan: Integer;
  idxR, idxG, idxB, idxA: Integer;
  i, c, blk, y, lines, ln, x: Integer;
  chOfsInScan: array of Integer;
  offTableP: NativeUInt;
  chunkOfs: UInt64;
  cp: NativeUInt;
  dataY, dataSize, rawSize: Integer;
  raw, dec2: TBytes;
  scanBase: NativeInt;
  fr, fg, fb, fa: Single;
  Col: TRGBA;

  function ReadSample(const Buf: TBytes; Ofs: NativeInt; PixType: Integer): Single;
  var u: Cardinal;
  begin
    case PixType of
      1: Result := HalfToFloat(Word(Buf[Ofs]) or (Word(Buf[Ofs+1]) shl 8));
      2: begin u := Cardinal(Buf[Ofs]) or (Cardinal(Buf[Ofs+1]) shl 8) or
                    (Cardinal(Buf[Ofs+2]) shl 16) or (Cardinal(Buf[Ofs+3]) shl 24);
              Move(u, Result, 4); end;
    else
      Result := (Cardinal(Buf[Ofs]) or (Cardinal(Buf[Ofs+1]) shl 8) or
                 (Cardinal(Buf[Ofs+2]) shl 16) or (Cardinal(Buf[Ofs+3]) shl 24)) / 65535.0;
    end;
  end;

begin
  Width := 0; Height := 0; SetLength(Result, 0);
  N := NativeUInt(Length(InBuf));
  if N < 12 then raise EExrError.Create('EXR: too small');
  if not ((InBuf[0] = $76) and (InBuf[1] = $2F) and (InBuf[2] = $31) and (InBuf[3] = $01)) then
    raise EExrError.Create('EXR: bad magic');
  ver := LEU32(InBuf, 4);
  flags := ver shr 8;
  if (flags and $2) <> 0 then raise EExrError.Create('EXR: tiled files not supported');
  if (flags and $10) <> 0 then raise EExrError.Create('EXR: multipart files not supported');

  P := 8;
  compression := 0; lineOrder := 0;
  xMin := 0; yMin := 0; xMax := -1; yMax := -1;
  SetLength(chans, 0);

  // attribute list until an empty name
  while P < N do
  begin
    aName := ReadString(InBuf, P, N);
    if aName = '' then Break;
    aType := ReadString(InBuf, P, N);
    aSize := LEU32(InBuf, P); Inc(P, 4);
    if aType = 'chlist' then
    begin
      // channels until empty name
      while (P < N) and (InBuf[P] <> 0) do
      begin
        SetLength(chans, Length(chans) + 1);
        chans[High(chans)].Name := ReadString(InBuf, P, N);
        chans[High(chans)].PixType := LEI32(InBuf, P); Inc(P, 4);
        Inc(P, 4);                    // pLinear + reserved
        Inc(P, 8);                    // xSampling + ySampling
        case chans[High(chans)].PixType of
          1: chans[High(chans)].Size := 2;
        else chans[High(chans)].Size := 4;
        end;
      end;
      Inc(P);                         // skip channel-list terminator
    end
    else if aType = 'compression' then begin compression := InBuf[P]; Inc(P, aSize); end
    else if aType = 'lineOrder' then begin lineOrder := InBuf[P]; Inc(P, aSize); end
    else if aType = 'box2i' then
    begin
      if aName = 'dataWindow' then
      begin
        xMin := LEI32(InBuf, P); yMin := LEI32(InBuf, P+4);
        xMax := LEI32(InBuf, P+8); yMax := LEI32(InBuf, P+12);
      end;
      Inc(P, aSize);
    end
    else
      Inc(P, aSize);
  end;

  if (xMax < xMin) or (yMax < yMin) then raise EExrError.Create('EXR: missing dataWindow');
  W := xMax - xMin + 1; H := yMax - yMin + 1;
  if (W <= 0) or (H <= 0) then raise EExrError.Create('EXR: bad dimensions');
  if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then
    raise EExrError.Create('EXR: image too large');

  case compression of
    0, 1, 2: linesPerBlock := 1;      // NONE, RLE, ZIPS
    3: linesPerBlock := 16;           // ZIP
  else
    raise EExrError.CreateFmt('EXR: compression %d not supported (only NONE/ZIP/ZIPS)', [compression]);
  end;
  if compression = 1 then
    raise EExrError.Create('EXR: RLE compression not supported');

  // channel byte offsets within a single scanline (channels are stored in the
  // order listed, which OpenEXR keeps sorted by name)
  SetLength(chOfsInScan, Length(chans));
  bytesPerScan := 0;
  idxR := -1; idxG := -1; idxB := -1; idxA := -1;
  for c := 0 to High(chans) do
  begin
    chOfsInScan[c] := bytesPerScan;
    bytesPerScan := bytesPerScan + W * chans[c].Size;
    if chans[c].Name = 'R' then idxR := c
    else if chans[c].Name = 'G' then idxG := c
    else if chans[c].Name = 'B' then idxB := c
    else if chans[c].Name = 'A' then idxA := c;
  end;

  numBlocks := (H + linesPerBlock - 1) div linesPerBlock;
  offTableP := P;
  if offTableP + NativeUInt(numBlocks) * 8 > N then
    raise EExrError.Create('EXR: truncated offset table');

  Width := W; Height := H;
  SetLength(Result, NativeInt(W) * H * 4);

  for blk := 0 to numBlocks - 1 do
  begin
    chunkOfs := LEU64(InBuf, offTableP + NativeUInt(blk) * 8);
    cp := NativeUInt(chunkOfs);
    if cp + 8 > N then Continue;
    dataY := LEI32(InBuf, cp);
    dataSize := LEI32(InBuf, cp + 4);
    Inc(cp, 8);
    if cp + NativeUInt(dataSize) > N then Continue;

    lines := linesPerBlock;
    if (dataY - yMin) + lines > H then lines := H - (dataY - yMin);
    if lines <= 0 then Continue;
    rawSize := lines * bytesPerScan;

    SetLength(raw, dataSize);
    if dataSize > 0 then Move(InBuf[cp], raw[0], dataSize);

    if compression = 0 then
      dec2 := raw
    else
    begin
      // ZIP/ZIPS: if stored compressed (smaller), inflate + reconstruct;
      // otherwise the block was stored raw
      if dataSize < rawSize then
      begin
        dec2 := InflateZlib(@raw[0], NativeUInt(dataSize));
        if Length(dec2) >= rawSize then ExrReconstruct(Copy(dec2, 0, rawSize), dec2, rawSize);
      end
      else
        dec2 := raw;
    end;
    if Length(dec2) < rawSize then Continue;

    for ln := 0 to lines - 1 do
    begin
      y := (dataY - yMin) + ln;
      if (y < 0) or (y >= H) then Continue;
      scanBase := NativeInt(ln) * bytesPerScan;
      for x := 0 to W - 1 do
      begin
        if idxR >= 0 then fr := ReadSample(dec2, scanBase + chOfsInScan[idxR] + x * chans[idxR].Size, chans[idxR].PixType) else fr := 0;
        if idxG >= 0 then fg := ReadSample(dec2, scanBase + chOfsInScan[idxG] + x * chans[idxG].Size, chans[idxG].PixType) else fg := fr;
        if idxB >= 0 then fb := ReadSample(dec2, scanBase + chOfsInScan[idxB] + x * chans[idxB].Size, chans[idxB].PixType) else fb := fr;
        if idxA >= 0 then fa := ReadSample(dec2, scanBase + chOfsInScan[idxA] + x * chans[idxA].Size, chans[idxA].PixType) else fa := 1;
        Col.R := SRGBB(fr); Col.G := SRGBB(fg); Col.B := SRGBB(fb);
        if fa < 0 then fa := 0 else if fa > 1 then fa := 1;
        Col.A := Byte(Round(fa * 255));
        SetPx(Result, W, x, y, Col);
      end;
    end;
  end;

  if lineOrder = 1 then
  begin
    // DECREASING_Y: rows were emitted bottom-to-top; our y already maps via
    // dataY so no extra flip is required.
  end;
  i := compression; if i < 0 then Exit;   // silence unused hint
end;

end.
