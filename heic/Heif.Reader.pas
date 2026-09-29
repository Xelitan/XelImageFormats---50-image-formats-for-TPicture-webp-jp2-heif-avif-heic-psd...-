unit Heif.Reader;

// Big-endian byte reader and MSB-first bit reader over an in-memory buffer.
// Used by the ISOBMFF/HEIF container parser and, later, the HEVC bitstream
// parser. Pure Pascal, no dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  EHeifRead = class(Exception);

  TBytes = array of Byte;

  // TByteReader: sequential big-endian reader over a byte buffer.
  // The buffer is borrowed (not owned) unless created via CreateOwned.
  TByteReader = class
  private
    FData: PByte;
    FSize: NativeInt;
    FPos: NativeInt;
    FOwned: TBytes; // holds memory when we own it
    function GetRemaining: NativeInt;
  public
    constructor Create(AData: PByte; ASize: NativeInt); overload;
    constructor CreateOwned(const ABytes: TBytes); overload;

    procedure CheckAvail(ACount: NativeInt);

    function ReadU8: Byte;
    function ReadU16: Word;
    function ReadU24: LongWord;
    function ReadU32: LongWord;
    function ReadU64: UInt64;
    function ReadS32: LongInt;

    // Reads N bytes as an unsigned big-endian integer (N in 1..8).
    function ReadUInt(NBytes: Integer): UInt64;

    // Reads a NUL-terminated UTF-8 string (advances past the NUL).
    function ReadCString: string;

    // Reads a 4-character box type as a string.
    function ReadFourCC: string;

    // Copies ACount bytes out into a fresh dynamic array.
    function ReadBytes(ACount: NativeInt): TBytes;

    // Returns a pointer to the current position without copying.
    function CurrentPtr: PByte;

    procedure Skip(ACount: NativeInt);
    procedure Seek(APos: NativeInt);

    property Position: NativeInt read FPos;
    property Size: NativeInt read FSize;
    property Remaining: NativeInt read GetRemaining;
    property Data: PByte read FData;
  end;

  // TBitReader: MSB-first bit reader, for NAL unit / slice header parsing.
  // Operates over a borrowed byte buffer.
  TBitReader = class
  private
    FData: PByte;
    FSize: NativeInt;
    FBytePos: NativeInt;
    FBitPos: Integer; // 0..7, next bit to read (0 = MSB of current byte)
  public
    constructor Create(AData: PByte; ASize: NativeInt);

    function ReadBit: LongWord;
    function ReadBits(N: Integer): LongWord;      // N in 0..32
    function ReadBits64(N: Integer): UInt64;      // N in 0..64
    function ReadUE: LongWord;                     // Exp-Golomb unsigned
    function ReadSE: LongInt;                       // Exp-Golomb signed

    function ByteAligned: Boolean;
    procedure ByteAlign;
    function MoreRbspData: Boolean;

    // Total bits already consumed.
    function BitsRead: Int64;

    property BytePos: NativeInt read FBytePos;
  end;

  // TBitWriter: MSB-first bit writer into a growable byte buffer, with
  // Exp-Golomb support. Used to synthesize parameter-set NAL payloads.
  TBitWriter = class
  private
    FBuf: TBytes;
    FCount: NativeInt;       // bytes fully written
    FCur: Byte;             // current partial byte
    FBitPos: Integer;        // bits filled in FCur (0..7)
    procedure Ensure(ACount: NativeInt);
  public
    constructor Create;
    procedure WriteBit(ABit: LongWord);
    procedure WriteBits(AValue: LongWord; N: Integer); // N in 0..32
    procedure WriteUE(AValue: LongWord);
    procedure WriteSE(AValue: LongInt);
    procedure ByteAlign;    // pad with zero bits to next byte boundary
    // Returns the written bytes (flushing any partial byte with zero padding).
    function ToBytes: TBytes;
  end;

// Utility: big-endian reads from a raw pointer.
function BE16(P: PByte): Word;
function BE32(P: PByte): LongWord;

implementation

// TBitWriter

constructor TBitWriter.Create;
begin
  inherited Create;
  FCount := 0;
  FCur := 0;
  FBitPos := 0;
end;

procedure TBitWriter.Ensure(ACount: NativeInt);
begin
  if FCount + ACount > Length(FBuf) then
    SetLength(FBuf, (FCount + ACount) * 2 + 16);
end;

procedure TBitWriter.WriteBit(ABit: LongWord);
begin
  FCur := (FCur shl 1) or (ABit and 1);
  Inc(FBitPos);
  if FBitPos = 8 then
  begin
    Ensure(1);
    FBuf[FCount] := FCur;
    Inc(FCount);
    FCur := 0;
    FBitPos := 0;
  end;
end;

procedure TBitWriter.WriteBits(AValue: LongWord; N: Integer);
var
  I: Integer;
begin
  for I := N - 1 downto 0 do
    WriteBit((AValue shr I) and 1);
end;

procedure TBitWriter.WriteUE(AValue: LongWord);
var
  NumBits: Integer;
  V: LongWord;
begin
  // code = value + 1, written as (leadingZeros) zeros + binary(code)
  V := AValue + 1;
  NumBits := 0;
  while (V shr NumBits) > 1 do
    Inc(NumBits);
  // NumBits = floor(log2(V)); write NumBits zeros then the NumBits+1 bit value.
  WriteBits(0, NumBits);
  WriteBits(V, NumBits + 1);
end;

procedure TBitWriter.WriteSE(AValue: LongInt);
var
  K: LongWord;
begin
  if AValue <= 0 then
    K := LongWord(-2 * AValue)
  else
    K := LongWord(2 * AValue - 1);
  WriteUE(K);
end;

procedure TBitWriter.ByteAlign;
begin
  while FBitPos <> 0 do
    WriteBit(0);
end;

function TBitWriter.ToBytes: TBytes;
begin
  if FBitPos <> 0 then
    ByteAlign;
  SetLength(Result, FCount);
  if FCount > 0 then
    Move(FBuf[0], Result[0], FCount);
end;

function BE16(P: PByte): Word;
begin
  Result := (Word(P[0]) shl 8) or Word(P[1]);
end;

function BE32(P: PByte): LongWord;
begin
  Result := (LongWord(P[0]) shl 24) or (LongWord(P[1]) shl 16) or
            (LongWord(P[2]) shl 8) or LongWord(P[3]);
end;

// TByteReader

constructor TByteReader.Create(AData: PByte; ASize: NativeInt);
begin
  inherited Create;
  FData := AData;
  FSize := ASize;
  FPos := 0;
end;

constructor TByteReader.CreateOwned(const ABytes: TBytes);
begin
  inherited Create;
  FOwned := ABytes;
  if Length(ABytes) > 0 then
    FData := @FOwned[0]
  else
    FData := nil;
  FSize := Length(ABytes);
  FPos := 0;
end;

function TByteReader.GetRemaining: NativeInt;
begin
  Result := FSize - FPos;
end;

procedure TByteReader.CheckAvail(ACount: NativeInt);
begin
  if (ACount < 0) or (FPos + ACount > FSize) then
    raise EHeifRead.CreateFmt('Read past end of buffer at pos %d (+%d, size %d)',
      [FPos, ACount, FSize]);
end;

function TByteReader.ReadU8: Byte;
begin
  CheckAvail(1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TByteReader.ReadU16: Word;
begin
  CheckAvail(2);
  Result := (Word(FData[FPos]) shl 8) or Word(FData[FPos + 1]);
  Inc(FPos, 2);
end;

function TByteReader.ReadU24: LongWord;
begin
  CheckAvail(3);
  Result := (LongWord(FData[FPos]) shl 16) or (LongWord(FData[FPos + 1]) shl 8) or
            LongWord(FData[FPos + 2]);
  Inc(FPos, 3);
end;

function TByteReader.ReadU32: LongWord;
begin
  CheckAvail(4);
  Result := (LongWord(FData[FPos]) shl 24) or (LongWord(FData[FPos + 1]) shl 16) or
            (LongWord(FData[FPos + 2]) shl 8) or LongWord(FData[FPos + 3]);
  Inc(FPos, 4);
end;

function TByteReader.ReadU64: UInt64;
var
  Hi, Lo: LongWord;
begin
  Hi := ReadU32;
  Lo := ReadU32;
  Result := (UInt64(Hi) shl 32) or UInt64(Lo);
end;

function TByteReader.ReadS32: LongInt;
begin
  Result := LongInt(ReadU32);
end;

function TByteReader.ReadUInt(NBytes: Integer): UInt64;
var
  I: Integer;
begin
  if (NBytes < 0) or (NBytes > 8) then
    raise EHeifRead.CreateFmt('ReadUInt: invalid byte count %d', [NBytes]);
  CheckAvail(NBytes);
  Result := 0;
  for I := 0 to NBytes - 1 do
  begin
    Result := (Result shl 8) or UInt64(FData[FPos]);
    Inc(FPos);
  end;
end;

function TByteReader.ReadCString: string;
var
  StartPos: NativeInt;
  Len: NativeInt;
begin
  StartPos := FPos;
  while (FPos < FSize) and (FData[FPos] <> 0) do
    Inc(FPos);
  Len := FPos - StartPos;
  SetLength(Result, Len);
  if Len > 0 then
    Move(FData[StartPos], Result[1], Len);
  if FPos < FSize then
    Inc(FPos); // skip the NUL
end;

function TByteReader.ReadFourCC: string;
var
  I: Integer;
begin
  CheckAvail(4);
  SetLength(Result, 4);
  for I := 1 to 4 do
  begin
    Result[I] := Chr(FData[FPos]);
    Inc(FPos);
  end;
end;

function TByteReader.ReadBytes(ACount: NativeInt): TBytes;
begin
  CheckAvail(ACount);
  SetLength(Result, ACount);
  if ACount > 0 then
    Move(FData[FPos], Result[0], ACount);
  Inc(FPos, ACount);
end;

function TByteReader.CurrentPtr: PByte;
begin
  Result := @FData[FPos];
end;

procedure TByteReader.Skip(ACount: NativeInt);
begin
  CheckAvail(ACount);
  Inc(FPos, ACount);
end;

procedure TByteReader.Seek(APos: NativeInt);
begin
  if (APos < 0) or (APos > FSize) then
    raise EHeifRead.CreateFmt('Seek out of range: %d (size %d)', [APos, FSize]);
  FPos := APos;
end;

// TBitReader

constructor TBitReader.Create(AData: PByte; ASize: NativeInt);
begin
  inherited Create;
  FData := AData;
  FSize := ASize;
  FBytePos := 0;
  FBitPos := 0;
end;

function TBitReader.ReadBit: LongWord;
begin
  if FBytePos >= FSize then
    raise EHeifRead.Create('BitReader: read past end');
  Result := (FData[FBytePos] shr (7 - FBitPos)) and 1;
  Inc(FBitPos);
  if FBitPos = 8 then
  begin
    FBitPos := 0;
    Inc(FBytePos);
  end;
end;

function TBitReader.ReadBits(N: Integer): LongWord;
var
  I: Integer;
begin
  if (N < 0) or (N > 32) then
    raise EHeifRead.CreateFmt('ReadBits: invalid count %d', [N]);
  Result := 0;
  for I := 1 to N do
    Result := (Result shl 1) or ReadBit;
end;

function TBitReader.ReadBits64(N: Integer): UInt64;
var
  I: Integer;
begin
  if (N < 0) or (N > 64) then
    raise EHeifRead.CreateFmt('ReadBits64: invalid count %d', [N]);
  Result := 0;
  for I := 1 to N do
    Result := (Result shl 1) or UInt64(ReadBit);
end;

function TBitReader.ReadUE: LongWord;
var
  LeadingZeros: Integer;
begin
  LeadingZeros := 0;
  while (ReadBit = 0) and (LeadingZeros < 32) do
    Inc(LeadingZeros);
  if LeadingZeros = 0 then
    Result := 0
  else
    Result := ((LongWord(1) shl LeadingZeros) - 1) + ReadBits(LeadingZeros);
end;

function TBitReader.ReadSE: LongInt;
var
  K: LongWord;
begin
  K := ReadUE;
  // Mapping: 0->0, 1->1, 2->-1, 3->2, 4->-2, ...
  if (K and 1) = 1 then
    Result := LongInt((K + 1) shr 1)
  else
    Result := -LongInt(K shr 1);
end;

function TBitReader.ByteAligned: Boolean;
begin
  Result := FBitPos = 0;
end;

procedure TBitReader.ByteAlign;
begin
  if FBitPos <> 0 then
  begin
    FBitPos := 0;
    Inc(FBytePos);
  end;
end;

function TBitReader.MoreRbspData: Boolean;
var
  P: NativeInt;
  B: Integer;
  LastByte: Byte;
begin
  // True if there is more RBSP data before the rbsp_stop_one_bit.
  if FBytePos >= FSize then
    Exit(False);
  // If not on the last byte, there is definitely more data.
  if FBytePos < FSize - 1 then
    Exit(True);
  // On the last byte: check whether a stop bit + trailing zeros remain.
  LastByte := FData[FSize - 1];
  // find position of the last set bit
  B := 0;
  while (B < 8) and (((LastByte shr B) and 1) = 0) do
    Inc(B);
  // stop bit is at bit index (7 - (7 - B)) ... compute absolute bit index of stop bit
  P := (FSize - 1) * 8 + (7 - B);
  Result := BitsRead < P;
end;

function TBitReader.BitsRead: Int64;
begin
  Result := Int64(FBytePos) * 8 + FBitPos;
end;

end.
