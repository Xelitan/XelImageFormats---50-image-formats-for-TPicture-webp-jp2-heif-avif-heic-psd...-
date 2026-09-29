//JBIG2 decoder in Pascal
//Author: www.xelitan.com
//License: Apache 2.0
//
//PdfJbig2Mmr.inc -- MMR (T.6) decompressor

type
  TMMRTriple = array[0..2] of Integer;  // { bitLength, codeWord, runLength }

const
  MMR_EOL = -1;
  MMR_INVALID = -2;
  MMR_EOF = -3;
  MMR_INCOMP = -4;

  MCODE_P = 0;
  MCODE_H = 1;
  MCODE_V0 = 2;
  MCODE_VR1 = 3;
  MCODE_VR2 = 4;
  MCODE_VR3 = 5;
  MCODE_VL1 = 6;
  MCODE_VL2 = 7;
  MCODE_VL3 = 8;
  MCODE_EXT2D = 9;
  MCODE_EXT1D = 10;

  MMR_FIRST_LEVEL_TABLE_SIZE = 8;
  MMR_FIRST_LEVEL_TABLE_MASK = (1 shl MMR_FIRST_LEVEL_TABLE_SIZE) - 1;
  MMR_SECOND_LEVEL_TABLE_SIZE = 5;
  MMR_SECOND_LEVEL_TABLE_MASK = (1 shl MMR_SECOND_LEVEL_TABLE_SIZE) - 1;
  MMR_CODE_OFFSET = 24;

  // { bitLength, codeWord, runLength }
  ModeCodes: array[0..11] of TMMRTriple = (
    (4, $1, MCODE_P), (3, $1, MCODE_H), (1, $1, MCODE_V0), (3, $3, MCODE_VR1),
    (6, $3, MCODE_VR2), (7, $3, MCODE_VR3), (3, $2, MCODE_VL1), (6, $2, MCODE_VL2),
    (7, $2, MCODE_VL3), (10, $f, MCODE_EXT2D), (12, $f, MCODE_EXT1D), (12, $1, MMR_EOL));

  WhiteCodes: array[0..108] of TMMRTriple = (
    (4, $07, 2), (4, $08, 3), (4, $0B, 4), (4, $0C, 5), (4, $0E, 6), (4, $0F, 7),
    (5, $12, 128), (5, $13, 8), (5, $14, 9), (5, $1B, 64), (5, $07, 10), (5, $08, 11),
    (6, $17, 192), (6, $18, 1664), (6, $2A, 16), (6, $2B, 17), (6, $03, 13), (6, $34, 14),
    (6, $35, 15), (6, $07, 1), (6, $08, 12), (7, $13, 26), (7, $17, 21), (7, $18, 28),
    (7, $24, 27), (7, $27, 18), (7, $28, 24), (7, $2B, 25), (7, $03, 22), (7, $37, 256),
    (7, $04, 23), (7, $08, 20), (7, $0C, 19), (8, $12, 33), (8, $13, 34), (8, $14, 35),
    (8, $15, 36), (8, $16, 37), (8, $17, 38), (8, $1A, 31), (8, $1B, 32), (8, $02, 29),
    (8, $24, 53), (8, $25, 54), (8, $28, 39), (8, $29, 40), (8, $2A, 41), (8, $2B, 42),
    (8, $2C, 43), (8, $2D, 44), (8, $03, 30), (8, $32, 61), (8, $33, 62), (8, $34, 63),
    (8, $35, 0), (8, $36, 320), (8, $37, 384), (8, $04, 45), (8, $4A, 59), (8, $4B, 60),
    (8, $05, 46), (8, $52, 49), (8, $53, 50), (8, $54, 51), (8, $55, 52), (8, $58, 55),
    (8, $59, 56), (8, $5A, 57), (8, $5B, 58), (8, $64, 448), (8, $65, 512), (8, $67, 640),
    (8, $68, 576), (8, $0A, 47), (8, $0B, 48), (9, $01, MMR_INVALID), (9, $98, 1472),
    (9, $99, 1536), (9, $9A, 1600), (9, $9B, 1728), (9, $CC, 704), (9, $CD, 768),
    (9, $D2, 832), (9, $D3, 896), (9, $D4, 960), (9, $D5, 1024), (9, $D6, 1088),
    (9, $D7, 1152), (9, $D8, 1216), (9, $D9, 1280), (9, $DA, 1344), (9, $DB, 1408),
    (10, $01, MMR_INVALID), (11, $01, MMR_INVALID), (11, $08, 1792), (11, $0C, 1856),
    (11, $0D, 1920), (12, $00, MMR_EOF), (12, $01, MMR_EOL), (12, $12, 1984),
    (12, $13, 2048), (12, $14, 2112), (12, $15, 2176), (12, $16, 2240), (12, $17, 2304),
    (12, $1C, 2368), (12, $1D, 2432), (12, $1E, 2496), (12, $1F, 2560));

  BlackCodes: array[0..108] of TMMRTriple = (
    (2, $02, 3), (2, $03, 2), (3, $02, 1), (3, $03, 4), (4, $02, 6), (4, $03, 5),
    (5, $03, 7), (6, $04, 9), (6, $05, 8), (7, $04, 10), (7, $05, 11), (7, $07, 12),
    (8, $04, 13), (8, $07, 14), (9, $01, MMR_INVALID), (9, $18, 15), (10, $01, MMR_INVALID),
    (10, $17, 16), (10, $18, 17), (10, $37, 0), (10, $08, 18), (10, $0F, 64),
    (11, $01, MMR_INVALID), (11, $17, 24), (11, $18, 25), (11, $28, 23), (11, $37, 22),
    (11, $67, 19), (11, $68, 20), (11, $6C, 21), (11, $08, 1792), (11, $0C, 1856),
    (11, $0D, 1920), (12, $00, MMR_EOF), (12, $01, MMR_EOL), (12, $12, 1984), (12, $13, 2048),
    (12, $14, 2112), (12, $15, 2176), (12, $16, 2240), (12, $17, 2304), (12, $1C, 2368),
    (12, $1D, 2432), (12, $1E, 2496), (12, $1F, 2560), (12, $24, 52), (12, $27, 55),
    (12, $28, 56), (12, $2B, 59), (12, $2C, 60), (12, $33, 320), (12, $34, 384),
    (12, $35, 448), (12, $37, 53), (12, $38, 54), (12, $52, 50), (12, $53, 51),
    (12, $54, 44), (12, $55, 45), (12, $56, 46), (12, $57, 47), (12, $58, 57),
    (12, $59, 58), (12, $5A, 61), (12, $5B, 256), (12, $64, 48), (12, $65, 49),
    (12, $66, 62), (12, $67, 63), (12, $68, 30), (12, $69, 31), (12, $6A, 32),
    (12, $6B, 33), (12, $6C, 40), (12, $6D, 41), (12, $C8, 128), (12, $C9, 192),
    (12, $CA, 26), (12, $CB, 27), (12, $CC, 28), (12, $CD, 29), (12, $D2, 34),
    (12, $D3, 35), (12, $D4, 36), (12, $D5, 37), (12, $D6, 38), (12, $D7, 39),
    (12, $DA, 42), (12, $DB, 43), (13, $4A, 640), (13, $4B, 704), (13, $4C, 768),
    (13, $4D, 832), (13, $52, 1280), (13, $53, 1344), (13, $54, 1408), (13, $55, 1472),
    (13, $5A, 1536), (13, $5B, 1600), (13, $64, 1664), (13, $65, 1728), (13, $6C, 512),
    (13, $6D, 576), (13, $72, 896), (13, $73, 960), (13, $74, 1024), (13, $75, 1088),
    (13, $76, 1152), (13, $77, 1216));

type
  TJBMMRCode = class(TJBObject)
  public
    subTable: array of TJBMMRCode;
    bitLength, codeWord, runLength: Integer;
    constructor Create(b, c, r: Integer);
  end;
  TJBMMRCodeTable = array of TJBMMRCode;

  TJBMMRDecompressor = class(TJBObject)
  public
    width, height: Integer;
    buf: TBytes;
    bufLen: Integer;
    offset: Integer;       // current bit offset
    constructor Create(awidth, aheight: Integer; reader: TJBReader);
    function GetBuf(i: Integer): Integer;
    function GetNextCode: Integer;
    function GetCode(table: TJBMMRCodeTable): TJBMMRCode;
    procedure Align;
    function Uncompress2D(referenceOffsets: TIntArray; refRunLength: Integer;
      runOffsets: TIntArray; awidth: Integer): Integer;
    function Uncompress1D(runOffsets: TIntArray; awidth: Integer): Integer;
    procedure FillBitmap(result_: TJBBitmap; line: Integer; currentOffsets: TIntArray; count: Integer);
    procedure DetectAndSkipEOL;
    function Uncompress: TJBBitmap;
  end;

var
  GWhiteTable: TJBMMRCodeTable = nil;
  GBlackTable: TJBMMRCodeTable = nil;
  GModeTable: TJBMMRCodeTable = nil;

constructor TJBMMRCode.Create(b, c, r: Integer);
begin
  inherited Create;
  bitLength := b;
  codeWord := c;
  runLength := r;
end;

function CreateLittleEndianTable(const codes: array of TMMRTriple; n: Integer): TJBMMRCodeTable;
var
  firstLevel: TJBMMRCodeTable;
  k, variantLength, baseWord, variant, idx, firstLevelIndex: Integer;
  code, firstLevelCode: TJBMMRCode;
  secondLevel: TJBMMRCodeTable;
begin
  SetLength(firstLevel, MMR_FIRST_LEVEL_TABLE_MASK + 1);
  for k := 0 to n - 1 do
  begin
    code := TJBMMRCode.Create(codes[k][0], codes[k][1], codes[k][2]);
    if code.bitLength <= MMR_FIRST_LEVEL_TABLE_SIZE then
    begin
      variantLength := MMR_FIRST_LEVEL_TABLE_SIZE - code.bitLength;
      baseWord := code.codeWord shl variantLength;
      for variant := (1 shl variantLength) - 1 downto 0 do
      begin
        idx := baseWord or variant;
        firstLevel[idx] := code;
      end;
    end
    else
    begin
      firstLevelIndex := code.codeWord shr (code.bitLength - MMR_FIRST_LEVEL_TABLE_SIZE);
      if firstLevel[firstLevelIndex] = nil then
      begin
        firstLevelCode := TJBMMRCode.Create(0, 0, 0);
        SetLength(firstLevelCode.subTable, MMR_SECOND_LEVEL_TABLE_MASK + 1);
        firstLevel[firstLevelIndex] := firstLevelCode;
      end;
      if code.bitLength <= MMR_FIRST_LEVEL_TABLE_SIZE + MMR_SECOND_LEVEL_TABLE_SIZE then
      begin
        secondLevel := firstLevel[firstLevelIndex].subTable;
        variantLength := MMR_FIRST_LEVEL_TABLE_SIZE + MMR_SECOND_LEVEL_TABLE_SIZE - code.bitLength;
        baseWord := (code.codeWord shl variantLength) and MMR_SECOND_LEVEL_TABLE_MASK;
        for variant := (1 shl variantLength) - 1 downto 0 do
          secondLevel[baseWord or variant] := code;
      end
      else
        raise EJBig2.Create('Code table overflow in MMRDecompressor');
    end;
  end;
  Result := firstLevel;
end;

procedure InitMMRTables;
begin
  if GWhiteTable = nil then
  begin
    GWhiteTable := CreateLittleEndianTable(WhiteCodes, System.Length(WhiteCodes));
    GBlackTable := CreateLittleEndianTable(BlackCodes, System.Length(BlackCodes));
    GModeTable := CreateLittleEndianTable(ModeCodes, System.Length(ModeCodes));
  end;
end;

constructor TJBMMRDecompressor.Create(awidth, aheight: Integer; reader: TJBReader);
var i, n: Integer;
begin
  inherited Create;
  width := awidth;
  height := aheight;
  // Copy the window bytes into a private buffer (zero-padded for over-reads).
  n := reader.Length_;
  if n < 0 then n := 0;
  bufLen := n;
  SetLength(buf, n + 4);
  for i := 0 to n - 1 do
    if reader.FBase + i < System.Length(reader.FData) then
      buf[i] := reader.FData[reader.FBase + i]
    else
      buf[i] := 0;
  offset := 0;
  InitMMRTables;
end;

function TJBMMRDecompressor.GetBuf(i: Integer): Integer;
begin
  if (i >= 0) and (i < bufLen) then Result := buf[i] else Result := 0;
end;

// Returns a 24-bit window of the bitstream, aligned so the bit at the current
// offset is the MSB (bit 23).
function TJBMMRDecompressor.GetNextCode: Integer;
var byteOffset, bitOffset, c: Integer;
begin
  byteOffset := offset shr 3;
  bitOffset := offset and 7;
  c := (GetBuf(byteOffset) shl 16) or (GetBuf(byteOffset + 1) shl 8) or GetBuf(byteOffset + 2);
  Result := (c shl bitOffset) and $FFFFFF;
end;

function TJBMMRDecompressor.GetCode(table: TJBMMRCodeTable): TJBMMRCode;
var code: Integer;
begin
  code := GetNextCode and $FFFFFF;
  Result := table[code shr (MMR_CODE_OFFSET - MMR_FIRST_LEVEL_TABLE_SIZE)];
  if (Result <> nil) and (Result.subTable <> nil) then
    Result := Result.subTable[(code shr (MMR_CODE_OFFSET - MMR_FIRST_LEVEL_TABLE_SIZE
      - MMR_SECOND_LEVEL_TABLE_SIZE)) and MMR_SECOND_LEVEL_TABLE_MASK];
end;

procedure TJBMMRDecompressor.Align;
begin
  offset := ((offset + 7) shr 3) shl 3;
end;

function TJBMMRDecompressor.Uncompress2D(referenceOffsets: TIntArray; refRunLength: Integer;
  runOffsets: TIntArray; awidth: Integer): Integer;
var
  referenceBufferOffset, currentBufferOffset, currentLineBitPosition: Integer;
  whiteRun, brokeDecodeLoop: Boolean;
  code: TJBMMRCode;
  firstHalfBitPos, retCode: Integer;
  table: TJBMMRCodeTable;
  done: Boolean;
begin
  referenceBufferOffset := 0;
  currentBufferOffset := 0;
  currentLineBitPosition := 0;
  whiteRun := True;
  code := nil;
  brokeDecodeLoop := False;

  referenceOffsets[refRunLength] := awidth;
  referenceOffsets[refRunLength + 1] := awidth;
  referenceOffsets[refRunLength + 2] := awidth + 1;
  referenceOffsets[refRunLength + 3] := awidth + 1;

  try
    while currentLineBitPosition < awidth do
    begin
      code := GetCode(GModeTable);
      if code = nil then
      begin
        Inc(offset);
        brokeDecodeLoop := True;
        Break;
      end;
      offset := offset + code.bitLength;

      case code.runLength of
        MCODE_V0:  currentLineBitPosition := referenceOffsets[referenceBufferOffset];
        MCODE_VR1: currentLineBitPosition := referenceOffsets[referenceBufferOffset] + 1;
        MCODE_VL1: currentLineBitPosition := referenceOffsets[referenceBufferOffset] - 1;
        MCODE_H:
          begin
            done := False;
            // first half-run
            while True do
            begin
              if whiteRun then table := GWhiteTable else table := GBlackTable;
              code := GetCode(table);
              if code = nil then begin brokeDecodeLoop := True; done := True; Break; end;
              offset := offset + code.bitLength;
              if code.runLength < 64 then
              begin
                if code.runLength < 0 then
                begin
                  runOffsets[currentBufferOffset] := currentLineBitPosition;
                  Inc(currentBufferOffset);
                  code := nil;
                  brokeDecodeLoop := True; done := True; Break;
                end;
                currentLineBitPosition := currentLineBitPosition + code.runLength;
                runOffsets[currentBufferOffset] := currentLineBitPosition;
                Inc(currentBufferOffset);
                Break;
              end;
              currentLineBitPosition := currentLineBitPosition + code.runLength;
            end;
            if done then Break;

            firstHalfBitPos := currentLineBitPosition;
            // second half-run (opposite colour)
            while True do
            begin
              if not whiteRun then table := GWhiteTable else table := GBlackTable;
              code := GetCode(table);
              if code = nil then begin brokeDecodeLoop := True; done := True; Break; end;
              offset := offset + code.bitLength;
              if code.runLength < 64 then
              begin
                if code.runLength < 0 then
                begin
                  runOffsets[currentBufferOffset] := currentLineBitPosition;
                  Inc(currentBufferOffset);
                  brokeDecodeLoop := True; done := True; Break;
                end;
                currentLineBitPosition := currentLineBitPosition + code.runLength;
                if (currentLineBitPosition < awidth) or (currentLineBitPosition <> firstHalfBitPos) then
                begin
                  runOffsets[currentBufferOffset] := currentLineBitPosition;
                  Inc(currentBufferOffset);
                end;
                Break;
              end;
              currentLineBitPosition := currentLineBitPosition + code.runLength;
            end;
            if done then Break;

            while (currentLineBitPosition < awidth)
              and (referenceOffsets[referenceBufferOffset] <= currentLineBitPosition) do
              referenceBufferOffset := referenceBufferOffset + 2;
            Continue;
          end;
        MCODE_P:
          begin
            Inc(referenceBufferOffset);
            currentLineBitPosition := referenceOffsets[referenceBufferOffset];
            Inc(referenceBufferOffset);
            Continue;
          end;
        MCODE_VR2: currentLineBitPosition := referenceOffsets[referenceBufferOffset] + 2;
        MCODE_VL2: currentLineBitPosition := referenceOffsets[referenceBufferOffset] - 2;
        MCODE_VR3: currentLineBitPosition := referenceOffsets[referenceBufferOffset] + 3;
        MCODE_VL3: currentLineBitPosition := referenceOffsets[referenceBufferOffset] - 3;
      else
        begin
          // EOL or unexpected. Possibly MMR-as-1D restart.
          if (offset = 12) and (code.runLength = MMR_EOL) then
          begin
            offset := 0;
            Uncompress1D(referenceOffsets, awidth);
            Inc(offset);
            Uncompress1D(runOffsets, awidth);
            retCode := Uncompress1D(referenceOffsets, awidth);
            Inc(offset);
            Result := retCode;
            Exit;
          end;
          currentLineBitPosition := awidth;
          Continue;
        end;
      end;

      // Only vertical modes reach here.
      if currentLineBitPosition <= awidth then
      begin
        whiteRun := not whiteRun;
        runOffsets[currentBufferOffset] := currentLineBitPosition;
        Inc(currentBufferOffset);
        if referenceBufferOffset > 0 then Dec(referenceBufferOffset)
        else Inc(referenceBufferOffset);
        while (currentLineBitPosition < awidth)
          and (referenceOffsets[referenceBufferOffset] <= currentLineBitPosition) do
          referenceBufferOffset := referenceBufferOffset + 2;
      end;
    end;
  except
    Result := MMR_EOF;
    Exit;
  end;

  if runOffsets[currentBufferOffset] <> awidth then
    runOffsets[currentBufferOffset] := awidth;

  if brokeDecodeLoop and (code = nil) then
  begin
    Result := MMR_EOL;
    Exit;
  end;
  Result := currentBufferOffset;
end;

function TJBMMRDecompressor.Uncompress1D(runOffsets: TIntArray; awidth: Integer): Integer;
var whiteRun: Boolean; iBitPos, refOffset: Integer; code: TJBMMRCode;
begin
  whiteRun := True;
  iBitPos := 0;
  code := nil;
  refOffset := 0;

  while iBitPos < awidth do
  begin
    while True do
    begin
      if whiteRun then code := GetCode(GWhiteTable)
      else code := GetCode(GBlackTable);
      offset := offset + code.bitLength;
      if code.runLength < 0 then Break;
      iBitPos := iBitPos + code.runLength;
      if code.runLength < 64 then
      begin
        whiteRun := not whiteRun;
        runOffsets[refOffset] := iBitPos;
        Inc(refOffset);
        Break;
      end;
    end;
    if code.runLength < 0 then Break;
  end;

  if runOffsets[refOffset] <> awidth then
    runOffsets[refOffset] := awidth;

  if (code <> nil) and (code.runLength <> MMR_EOL) then
    Result := refOffset
  else
    Result := MMR_EOL;
end;

procedure TJBMMRDecompressor.FillBitmap(result_: TJBBitmap; line: Integer;
  currentOffsets: TIntArray; count: Integer);
var x, targetByte, targetByteValue, index, ofs, value: Integer;
begin
  x := 0;
  targetByte := result_.GetByteIndex(0, line);
  targetByteValue := 0;
  for index := 0 to count - 1 do
  begin
    ofs := currentOffsets[index];
    if (index and 1) = 0 then value := 0 else value := 1;
    while x < ofs do
    begin
      targetByteValue := (targetByteValue shl 1) or value;
      Inc(x);
      if (x and 7) = 0 then
      begin
        result_.SetByte(targetByte, targetByteValue);
        Inc(targetByte);
        targetByteValue := 0;
      end;
    end;
  end;
  if (x and 7) <> 0 then
  begin
    targetByteValue := targetByteValue shl (8 - (x and 7));
    result_.SetByte(targetByte, targetByteValue);
  end;
end;

procedure TJBMMRDecompressor.DetectAndSkipEOL;
var code: TJBMMRCode;
begin
  while True do
  begin
    code := GetCode(GModeTable);
    if (code <> nil) and (code.runLength = MMR_EOL) then
      offset := offset + code.bitLength
    else
      Break;
  end;
end;

function TJBMMRDecompressor.Uncompress: TJBBitmap;
var
  result_: TJBBitmap;
  currentOffsets, referenceOffsets, tempOffsets: TIntArray;
  refRunLength, count, line: Integer;
begin
  result_ := TJBBitmap.Create(width, height);
  SetLength(currentOffsets, width + 5);
  SetLength(referenceOffsets, width + 5);
  referenceOffsets[0] := width;
  refRunLength := 1;

  for line := 0 to height - 1 do
  begin
    count := Uncompress2D(referenceOffsets, refRunLength, currentOffsets, width);
    if count = MMR_EOF then Break;
    if count > 0 then FillBitmap(result_, line, currentOffsets, count);
    tempOffsets := referenceOffsets;
    referenceOffsets := currentOffsets;
    currentOffsets := tempOffsets;
    refRunLength := count;
  end;

  DetectAndSkipEOL;
  Align;
  Result := result_;
end;
