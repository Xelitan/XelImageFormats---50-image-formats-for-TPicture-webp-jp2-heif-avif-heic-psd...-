// Tiff - czysto-pascalowy dekoder TIFF -> RGBA8 (bez LCL).
// CCITT G3/G4/MH przez XelCcitt oraz uncompressed/LZW/deflate/PackBits.
// Jedna funkcja:  DecodeTiff(InBuf: TBytes; out Width, Height: Integer): TBytes  (RGBA8, R,G,B,A).
unit XelTiff;

{$mode objfpc}{$H+}

interface

uses SysUtils;

// Dekoduje pierwsza podstrone (kompatybilnosc wsteczna).
function DecodeTiff(InBuf: TBytes; out Width, Height: Integer): TBytes;
// Liczba podstron (IFD) w pliku TIFF.
function TiffPageCount(InBuf: TBytes): Integer;
// Dekoduje wskazana podstrone (0-based).
function DecodeTiffPage(InBuf: TBytes; PageIndex: Integer; out Width, Height: Integer): TBytes;
// Zapisuje pojedyncza strone TIFF (RGBA8, 4 kanaly, kompresja LZW). InBuf = RGBA8.
function EncodeTiff(InBuf: TBytes; Width, Height: Integer): TBytes;

implementation

uses XelInflate, XelCcitt;

type
  TU32Array = array of LongWord;

// ============================ helpery buforowe ============================

function RU16(const b: TBytes; pos: Integer; MM: Boolean): Word;
begin
  if MM then Result := (b[pos] shl 8) or b[pos+1]
  else Result := b[pos] or (b[pos+1] shl 8);
end;

function RU32(const b: TBytes; pos: Integer; MM: Boolean): LongWord;
begin
  if MM then Result := (LongWord(b[pos]) shl 24) or (LongWord(b[pos+1]) shl 16)
                    or (LongWord(b[pos+2]) shl 8) or b[pos+3]
  else Result := LongWord(b[pos]) or (LongWord(b[pos+1]) shl 8)
              or (LongWord(b[pos+2]) shl 16) or (LongWord(b[pos+3]) shl 24);
end;

// TIFF LZW (MSB-first, kod 9..12, Clear=256, EOI=257, early change)
function TiffLZW(src: PByte; srcLen: Integer): TBytes;
const CLEAR = 256; EOI = 257;
var
  dict: array of TBytes;
  nextCode, codeSize, bitBuf, bitCnt, oldCode, code: Integer;
  srcPos, outLen, outCap: Integer;
  entry, ne: TBytes;
  procedure ResetDict;
  var k: Integer;
  begin
    SetLength(dict, 4096);
    for k := 0 to 255 do begin SetLength(dict[k], 1); dict[k][0] := Byte(k); end;
    for k := 256 to 4095 do dict[k] := nil;
    nextCode := 258; codeSize := 9;
  end;
  function ReadCode: Integer;
  begin
    while (bitCnt < codeSize) and (srcPos < srcLen) do
    begin bitBuf := (bitBuf shl 8) or src[srcPos]; Inc(srcPos); Inc(bitCnt, 8); end;
    if bitCnt < codeSize then Exit(EOI);
    Result := (bitBuf shr (bitCnt - codeSize)) and ((1 shl codeSize) - 1);
    Dec(bitCnt, codeSize);
  end;
  procedure OutBytes(const arr: TBytes);
  var k: Integer;
  begin
    if outLen + Length(arr) > outCap then begin outCap := (outLen + Length(arr)) * 2 + 64; SetLength(Result, outCap); end;
    for k := 0 to High(arr) do begin Result[outLen] := arr[k]; Inc(outLen); end;
  end;
begin
  Result := nil; outLen := 0; outCap := 0; srcPos := 0; bitBuf := 0; bitCnt := 0; oldCode := -1;
  ResetDict;
  while True do
  begin
    code := ReadCode;
    if code = EOI then Break;
    if code = CLEAR then
    begin
      ResetDict; code := ReadCode;
      if code = EOI then Break;
      OutBytes(dict[code]); oldCode := code; Continue;
    end;
    if oldCode < 0 then begin OutBytes(dict[code]); oldCode := code; Continue; end;
    if (code < nextCode) and (dict[code] <> nil) then entry := dict[code]
    else begin entry := Copy(dict[oldCode]); SetLength(entry, Length(entry)+1); entry[High(entry)] := dict[oldCode][0]; end;
    OutBytes(entry);
    if nextCode < 4096 then
    begin ne := Copy(dict[oldCode]); SetLength(ne, Length(ne)+1); ne[High(ne)] := entry[0]; dict[nextCode] := ne; Inc(nextCode); end;
    oldCode := code;
    if (nextCode = (1 shl codeSize) - 1) and (codeSize < 12) then Inc(codeSize);
  end;
  SetLength(Result, outLen);
end;

// PackBits (RLE, tag 32773)
function PackBits(src: PByte; srcLen: Integer): TBytes;
var i, outLen, outCap, n, j: Integer; bb: Byte;
  procedure Put(v: Byte);
  begin
    if outLen >= outCap then begin outCap := outCap*2 + 256; SetLength(Result, outCap); end;
    Result[outLen] := v; Inc(outLen);
  end;
begin
  Result := nil; outLen := 0; outCap := 0; i := 0;
  while i < srcLen do
  begin
    n := Shortint(src[i]); Inc(i);
    if n >= 0 then
    begin for j := 0 to n do begin if i >= srcLen then Break; Put(src[i]); Inc(i); end; end
    else if n <> -128 then
    begin if i >= srcLen then Break; bb := src[i]; Inc(i); for j := 0 to -n do Put(bb); end;
  end;
  SetLength(Result, outLen);
end;

procedure Unpredict(var row: TBytes; rowStart, w, spp: Integer);
var x, c: Integer;
begin
  for x := 1 to w - 1 do
    for c := 0 to spp - 1 do
      row[rowStart + x*spp + c] := Byte(row[rowStart + x*spp + c] + row[rowStart + (x-1)*spp + c]);
end;

// Predictor=2 dla probek 16-bit (roznicowanie poziome na slowach 16-bit,
// z uwzglednieniem kolejnosci bajtow MM/II).
procedure Unpredict16(var row: TBytes; rowStart, w, spp: Integer; MM: Boolean);
var x, c, off, prevOff, v: Integer;
begin
  for x := 1 to w - 1 do
    for c := 0 to spp - 1 do
    begin
      off := rowStart + (x*spp + c) * 2;
      prevOff := rowStart + ((x-1)*spp + c) * 2;
      if off + 1 >= Length(row) then Exit;
      v := (RU16(row, off, MM) + RU16(row, prevOff, MM)) and $FFFF;
      if MM then begin row[off] := (v shr 8) and $FF; row[off+1] := v and $FF; end
      else begin row[off] := v and $FF; row[off+1] := (v shr 8) and $FF; end;
    end;
end;

// Pobiera probke o indeksie sampleIdx (piksel*spp+kanal) w wierszu rowBase,
// dla bps in {1,4,8} (pakowanie MSB-first, jak w TIFF).
function GetSampleBits(const d: TBytes; rowBase, sampleIdx, bps: Integer): Integer; inline;
var bytePos, shift: Integer;
begin
  Result := 0;
  case bps of
    1:
      begin
        bytePos := rowBase + (sampleIdx shr 3);
        if (bytePos < 0) or (bytePos >= Length(d)) then Exit;
        shift := 7 - (sampleIdx and 7);
        Result := (d[bytePos] shr shift) and 1;
      end;
    4:
      begin
        bytePos := rowBase + (sampleIdx shr 1);
        if (bytePos < 0) or (bytePos >= Length(d)) then Exit;
        if (sampleIdx and 1) = 0 then Result := (d[bytePos] shr 4) and $0F
        else Result := d[bytePos] and $0F;
      end;
  else  // 8
    begin
      bytePos := rowBase + sampleIdx;
      if (bytePos < 0) or (bytePos >= Length(d)) then Exit;
      Result := d[bytePos];
    end;
  end;
end;

function ReadTagArray(const buf: TBytes; MM: Boolean; ep: Integer): TU32Array;
var typ, k, cnt, vpos, esz: Integer;
begin
  typ := RU16(buf, ep+2, MM); cnt := Integer(RU32(buf, ep+4, MM));
  SetLength(Result, cnt);
  if typ = 3 then esz := 2 else esz := 4;
  if cnt * esz <= 4 then vpos := ep + 8 else vpos := Integer(RU32(buf, ep+8, MM));
  for k := 0 to cnt - 1 do
    if typ = 3 then Result[k] := RU16(buf, vpos + k*2, MM)
    else Result[k] := RU32(buf, vpos + k*4, MM);
end;

function TagVal1(const buf: TBytes; MM: Boolean; ep: Integer; def: LongWord): LongWord;
var typ, cnt, esz, vpos: Integer;
begin
  typ := RU16(buf, ep+2, MM); cnt := Integer(RU32(buf, ep+4, MM));
  if cnt < 1 then Exit(def);
  if typ = 3 then esz := 2 else esz := 4;
  if cnt * esz <= 4 then
  begin
    if typ = 3 then begin if MM then Result := RU32(buf, ep+8, MM) shr 16 else Result := RU16(buf, ep+8, MM); end
    else Result := RU32(buf, ep+8, MM);
  end
  else begin vpos := Integer(RU32(buf, ep+8, MM)); if typ = 3 then Result := RU16(buf, vpos, MM) else Result := RU32(buf, vpos, MM); end;
end;

// ============================ DecodeTiff ============================

function TiffHeader(const buf: TBytes; out MM: Boolean; out firstIFD: Integer): Boolean;
begin
  Result := False; MM := False; firstIFD := 0;
  if Length(buf) < 8 then Exit;
  MM := (buf[0] = Ord('M')) and (buf[1] = Ord('M'));
  if not (MM or ((buf[0] = Ord('I')) and (buf[1] = Ord('I')))) then Exit;
  if RU16(buf, 2, MM) <> 42 then Exit;
  firstIFD := Integer(RU32(buf, 4, MM));
  if (firstIFD <= 0) or (firstIFD + 2 > Length(buf)) then Exit;
  Result := True;
end;

// Offset kolejnego IFD (za tablica tagow) - 0 gdy brak.
function NextIFD(const buf: TBytes; MM: Boolean; ifd: Integer): Integer;
var nTags, p: Integer;
begin
  Result := 0;
  if (ifd <= 0) or (ifd + 2 > Length(buf)) then Exit;
  nTags := RU16(buf, ifd, MM);
  p := ifd + 2 + nTags * 12;
  if (p < 0) or (p + 4 > Length(buf)) then Exit;
  Result := Integer(RU32(buf, p, MM));
end;

// Dekoduje pojedyncza podstrone (IFD) spod offsetu ifd -> RGBA8.
function DecodeIFD(const buf: TBytes; MM: Boolean; ifd: Integer; out Width, Height: Integer): TBytes;
var
  nTags, i, entryPos, tagID, W, H: Integer;
  width_, height_, comp, photo, spp, rps, predictor, bps, fillOrder, t4opt: LongWord;
  offTagPos, cntTagPos, mapTagPos: Integer;
  stripOffs, stripCnts, colorMap: TU32Array;
  mapCount, rowBytes, strip, sOff, sCnt, rowsThis, rowY, srcRow, x, di, si: Integer;
  idx, maxv: Integer;
  raw, dec: TBytes; r, g, b, a: Integer;
  Row: Integer;
  kind: TCcittKind; got: Integer; isBlack: Boolean;
begin
  Result := nil; Width := 0; Height := 0;
  if (ifd <= 0) or (ifd + 2 > Length(buf)) then Exit;
  nTags := RU16(buf, ifd, MM);

  width_ := 0; height_ := 0; comp := 1; photo := 1; spp := 1; rps := $FFFFFFFF;
  predictor := 1; bps := 8; fillOrder := 1; t4opt := 0;
  offTagPos := -1; cntTagPos := -1; mapTagPos := -1;
  for i := 0 to nTags - 1 do
  begin
    entryPos := ifd + 2 + i*12;
    if entryPos + 12 > Length(buf) then Break;
    tagID := RU16(buf, entryPos, MM);
    case tagID of
      256: width_ := TagVal1(buf, MM, entryPos, 0);
      257: height_ := TagVal1(buf, MM, entryPos, 0);
      258: bps := TagVal1(buf, MM, entryPos, 8);
      259: comp := TagVal1(buf, MM, entryPos, 1);
      262: photo := TagVal1(buf, MM, entryPos, 1);
      266: fillOrder := TagVal1(buf, MM, entryPos, 1);
      273: offTagPos := entryPos;
      277: spp := TagVal1(buf, MM, entryPos, 1);
      278: rps := TagVal1(buf, MM, entryPos, $FFFFFFFF);
      279: cntTagPos := entryPos;
      292: t4opt := TagVal1(buf, MM, entryPos, 0);
      317: predictor := TagVal1(buf, MM, entryPos, 1);
      320: mapTagPos := entryPos;
    end;
  end;

  if (width_ = 0) or (height_ = 0) or (offTagPos < 0) or (cntTagPos < 0) then Exit;
  W := Integer(width_); H := Integer(height_);
  if rps = 0 then rps := height_;
  if rps > height_ then rps := height_;
  stripOffs := ReadTagArray(buf, MM, offTagPos);
  stripCnts := ReadTagArray(buf, MM, cntTagPos);
  if (Length(stripOffs) = 0) or (Length(stripCnts) = 0) then Exit;

  Width := W; Height := H;
  SetLength(Result, W * H * 4);

  if (comp = 2) or (comp = 3) or (comp = 4) then
  begin
    // CCITT bilevel data (XelCcitt). Runs decode as 0 = white run, 1 = black
    // run; PhotometricInterpretation then maps them to colours (0 = WhiteIsZero).
    FillChar(Result[0], Length(Result), 255);
    case comp of
      2: kind := ckMH;
      3: kind := ckT4;
    else kind := ckT6;
    end;
    Row := 0;
    for strip := 0 to High(stripOffs) do
    begin
      if Row >= H then Break;
      sOff := Integer(stripOffs[strip]);
      if strip < Length(stripCnts) then sCnt := Integer(stripCnts[strip]) else sCnt := 0;
      if (sCnt <= 0) or (sOff <= 0) or (sOff + sCnt > Length(buf)) then Continue;
      rowsThis := Integer(rps); if Row + rowsThis > H then rowsThis := H - Row;
      if rowsThis <= 0 then Break;
      raw := Copy(buf, sOff, sCnt);
      try
        dec := CcittDecode(raw, W, rowsThis, kind, (t4opt and 1) <> 0, fillOrder = 2, got);
      except
        got := 0;
      end;
      for srcRow := 0 to got - 1 do
        for x := 0 to W - 1 do
        begin
          isBlack := dec[srcRow * W + x] = 1;
          if photo = 1 then isBlack := not isBlack;
          di := ((Row + srcRow) * W + x) * 4;
          if isBlack then begin Result[di] := 0; Result[di+1] := 0; Result[di+2] := 0; end;
        end;
      Inc(Row, rowsThis);
    end;
  end
  else if (comp = 1) or (comp = 5) or (comp = 8) or (comp = 32773) then
  begin
    // obslugiwane glebie: 1/4/8 bitow na probke; RGB(spp>=3) tylko dla 8 bit
    if not ((bps = 1) or (bps = 4) or (bps = 8) or (bps = 16)) then
    begin Result := nil; Width := 0; Height := 0; Exit; end;
    if (spp >= 3) and not ((bps = 8) or (bps = 16)) then
    begin Result := nil; Width := 0; Height := 0; Exit; end;
    if (photo = 3) and (mapTagPos >= 0) then colorMap := ReadTagArray(buf, MM, mapTagPos)
    else SetLength(colorMap, 0);
    mapCount := Length(colorMap) div 3;
    maxv := (1 shl Integer(bps)) - 1;
    // wiersz w TIFF jest wyrownany do bajtu
    rowBytes := (W * Integer(spp) * Integer(bps) + 7) div 8;
    rowY := 0;
    for strip := 0 to High(stripOffs) do
    begin
      if rowY >= H then Break;
      sOff := Integer(stripOffs[strip]);
      if strip < Length(stripCnts) then sCnt := Integer(stripCnts[strip]) else sCnt := 0;
      if (sCnt <= 0) or (sOff <= 0) or (sOff + sCnt > Length(buf)) then Continue;
      SetLength(raw, sCnt); Move(buf[sOff], raw[0], sCnt);
      case comp of
        1: dec := raw;
        5: dec := TiffLZW(@raw[0], sCnt);
        8: dec := InflateZlib(@raw[0], NativeUInt(sCnt));
        32773: dec := PackBits(@raw[0], sCnt);
      end;
      rowsThis := Integer(rps); if rowY + rowsThis > H then rowsThis := H - rowY;
      for srcRow := 0 to rowsThis - 1 do
      begin
        si := srcRow * rowBytes;
        if si + rowBytes > Length(dec) then Break;
        if predictor = 2 then
        begin
          if bps = 8 then Unpredict(dec, si, W, Integer(spp))
          else if bps = 16 then Unpredict16(dec, si, W, Integer(spp), MM);
        end;
        for x := 0 to W - 1 do
        begin
          di := ((rowY + srcRow) * W + x) * 4;
          if spp >= 3 then
          begin
            if bps = 16 then
            begin
              r := RU16(dec, si + (x*Integer(spp) + 0)*2, MM) shr 8;
              g := RU16(dec, si + (x*Integer(spp) + 1)*2, MM) shr 8;
              b := RU16(dec, si + (x*Integer(spp) + 2)*2, MM) shr 8;
              if spp >= 4 then a := RU16(dec, si + (x*Integer(spp) + 3)*2, MM) shr 8 else a := 255;
            end
            else
            begin
              r := dec[si + x*Integer(spp) + 0]; g := dec[si + x*Integer(spp) + 1]; b := dec[si + x*Integer(spp) + 2];
              if spp >= 4 then a := dec[si + x*Integer(spp) + 3] else a := 255;
            end;
          end
          else
          begin
            if (photo = 3) and (mapCount > 0) and (bps <= 8) then
            begin
              idx := GetSampleBits(dec, si, x, Integer(bps));
              if idx >= mapCount then idx := mapCount - 1;
              r := colorMap[idx] shr 8;
              g := colorMap[mapCount + idx] shr 8;
              b := colorMap[2*mapCount + idx] shr 8;
            end
            else
            begin
              if bps = 16 then r := RU16(dec, si + x*2, MM) shr 8
              else
              begin
                idx := GetSampleBits(dec, si, x, Integer(bps));
                if maxv > 0 then r := idx * 255 div maxv else r := idx;
              end;
              if photo = 0 then r := 255 - r;   // WhiteIsZero
              g := r; b := r;
            end;
            a := 255;
          end;
          Result[di+0] := Byte(r); Result[di+1] := Byte(g); Result[di+2] := Byte(b); Result[di+3] := Byte(a);
        end;
      end;
      Inc(rowY, rowsThis);
    end;
  end
  else begin Result := nil; Width := 0; Height := 0; Exit; end;
end;

function DecodeTiff(InBuf: TBytes; out Width, Height: Integer): TBytes;
var MM: Boolean; ifd: Integer;
begin
  Result := nil; Width := 0; Height := 0;
  if not TiffHeader(InBuf, MM, ifd) then Exit;
  Result := DecodeIFD(InBuf, MM, ifd, Width, Height);
end;

function TiffPageCount(InBuf: TBytes): Integer;
var MM: Boolean; ifd, guard: Integer;
begin
  Result := 0;
  if not TiffHeader(InBuf, MM, ifd) then Exit;
  guard := 0;
  while (ifd > 0) and (ifd + 2 <= Length(InBuf)) and (guard < 100000) do
  begin
    Inc(Result);
    ifd := NextIFD(InBuf, MM, ifd);
    Inc(guard);
  end;
end;

function DecodeTiffPage(InBuf: TBytes; PageIndex: Integer; out Width, Height: Integer): TBytes;
var MM: Boolean; ifd, idx: Integer;
begin
  Result := nil; Width := 0; Height := 0;
  if not TiffHeader(InBuf, MM, ifd) then Exit;
  idx := 0;
  while (ifd > 0) and (idx < PageIndex) do
  begin ifd := NextIFD(InBuf, MM, ifd); Inc(idx); end;
  if (ifd <= 0) or (ifd + 2 > Length(InBuf)) then Exit;
  Result := DecodeIFD(InBuf, MM, ifd, Width, Height);
end;

// ============================ EncodeTiff ============================

// Koder TIFF LZW (MSB-first, kod 9..12, Clear=256, EOI=257, early change).
// Zwieksza szerokosc kodu gdy nextCode = (1 shl codeSize) - dokladnie odwrotnie
// niz dekoder TiffLZW (nextCode = (1 shl codeSize)-1), co daje zgodny strumien.
function TiffLZWEncode(const src: TBytes): TBytes;
const CLEAR = 256; EOI = 257;
var
  outLen, bitBuf, bitCnt, codeSize, nextCode, i, omega, k, key: Integer;
  table: array of Integer;
  procedure PutByte(v: Byte);
  begin
    if outLen >= Length(Result) then SetLength(Result, Length(Result) * 2 + 256);
    Result[outLen] := v; Inc(outLen);
  end;
  procedure PutBits(code, size: Integer);
  begin
    bitBuf := (bitBuf shl size) or (code and ((1 shl size) - 1));
    Inc(bitCnt, size);
    while bitCnt >= 8 do
    begin
      Dec(bitCnt, 8);
      PutByte(Byte((bitBuf shr bitCnt) and $FF));
    end;
    bitBuf := bitBuf and ((1 shl bitCnt) - 1);
  end;
begin
  Result := nil; outLen := 0; bitBuf := 0; bitCnt := 0;
  codeSize := 9; nextCode := 258;
  SetLength(table, 4096 * 256);
  for i := 0 to High(table) do table[i] := -1;

  PutBits(CLEAR, codeSize);
  if Length(src) = 0 then
  begin
    PutBits(EOI, codeSize);
    if bitCnt > 0 then PutByte(Byte((bitBuf shl (8 - bitCnt)) and $FF));
    SetLength(Result, outLen);
    Exit;
  end;

  omega := src[0];
  for i := 1 to High(src) do
  begin
    k := src[i];
    key := omega * 256 + k;
    if table[key] <> -1 then
      omega := table[key]
    else
    begin
      PutBits(omega, codeSize);
      if nextCode < 4096 then
      begin
        table[key] := nextCode;
        Inc(nextCode);
        if (nextCode = (1 shl codeSize)) and (codeSize < 12) then Inc(codeSize);
      end;
      omega := k;
    end;
  end;
  PutBits(omega, codeSize);
  PutBits(EOI, codeSize);
  if bitCnt > 0 then PutByte(Byte((bitBuf shl (8 - bitCnt)) and $FF));
  SetLength(Result, outLen);
end;

function EncodeTiff(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  comp: TBytes;
  bpsOff, ifdOff, dataOff, pos, nTags: Integer;

  procedure PutU16(p: Integer; v: Word);
  begin Result[p] := Byte(v); Result[p+1] := Byte(v shr 8); end;
  procedure PutU32(p: Integer; v: LongWord);
  begin
    Result[p] := Byte(v); Result[p+1] := Byte(v shr 8);
    Result[p+2] := Byte(v shr 16); Result[p+3] := Byte(v shr 24);
  end;
  procedure Entry(tag, typ: Word; count, value: LongWord);
  begin
    PutU16(pos, tag); PutU16(pos+2, typ);
    PutU32(pos+4, count); PutU32(pos+8, value);
    Inc(pos, 12);
  end;

begin
  Result := nil;
  if (Width <= 0) or (Height <= 0) then
    raise Exception.Create('TIFF: cannot encode an empty bitmap');
  if Int64(Length(InBuf)) <> Int64(Width) * Int64(Height) * 4 then
    raise Exception.Create('TIFF: RGBA8 buffer size does not match Width*Height*4');

  // RGBA8 jest juz gesto upakowane (R,G,B,A) top-down = dane probek strony.
  comp := TiffLZWEncode(InBuf);

  nTags := 10;
  dataOff := 8;
  ifdOff := 8 + Length(comp);
  if (ifdOff and 1) <> 0 then Inc(ifdOff);          // wyrownanie do slowa
  bpsOff := ifdOff + 2 + nTags * 12 + 4;            // BitsPerSample (4 x SHORT)

  SetLength(Result, bpsOff + 8);
  FillChar(Result[0], Length(Result), 0);

  // naglowek: little-endian (II), 42, offset pierwszego IFD
  Result[0] := Ord('I'); Result[1] := Ord('I');
  PutU16(2, 42);
  PutU32(4, LongWord(ifdOff));

  // dane obrazu (jeden strip)
  if Length(comp) > 0 then Move(comp[0], Result[dataOff], Length(comp));

  // IFD - tagi rosnaco
  pos := ifdOff;
  PutU16(pos, Word(nTags)); Inc(pos, 2);
  Entry(256, 4, 1, LongWord(Width));         // ImageWidth  (LONG)
  Entry(257, 4, 1, LongWord(Height));        // ImageLength (LONG)
  Entry(258, 3, 4, LongWord(bpsOff));        // BitsPerSample -> [8,8,8,8]
  Entry(259, 3, 1, 5);                       // Compression = LZW
  Entry(262, 3, 1, 2);                       // Photometric = RGB
  Entry(273, 4, 1, LongWord(dataOff));       // StripOffsets
  Entry(277, 3, 1, 4);                       // SamplesPerPixel = 4
  Entry(278, 4, 1, LongWord(Height));        // RowsPerStrip = Height (jeden strip)
  Entry(279, 4, 1, LongWord(Length(comp)));  // StripByteCounts
  Entry(338, 3, 1, 2);                       // ExtraSamples = 2 (unassociated alpha)
  PutU32(pos, 0); Inc(pos, 4);               // brak kolejnego IFD

  // tablica BitsPerSample: 8,8,8,8
  PutU16(bpsOff + 0, 8);
  PutU16(bpsOff + 2, 8);
  PutU16(bpsOff + 4, 8);
  PutU16(bpsOff + 6, 8);
end;

end.
