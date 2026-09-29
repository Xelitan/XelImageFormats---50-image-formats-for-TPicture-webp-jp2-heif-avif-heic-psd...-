unit Av1.Bits;

// AV1 bitstream reader.
//
// AV1 uses an MSB-first bit reader with several descriptor types defined in the
// spec (section 4): f(n) fixed bits, uvlc, le(n) little-endian bytes, leb128,
// su(n) signed, ns(n) non-symmetric unsigned. This wraps a byte buffer and
// tracks a bit position; leb128/le operate on byte-aligned positions.
//
// Reference: AV1 spec (aomedia) section 4 "Descriptors".

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  EAv1 = class(Exception);

  TAv1Bits = class
  private
    FData: PByte;
    FSize: NativeInt;      // in bytes
    FBitPos: Int64;        // absolute bit position
  public
    constructor Create(AData: PByte; ASize: NativeInt);

    function ReadBit: LongWord;
    function f(N: Integer): LongWord;          // f(n): n<=32 fixed-width bits
    function f64(N: Integer): UInt64;          // for n up to 64
    function uvlc: LongWord;
    function su(N: Integer): LongInt;          // signed: value then sign bit
    function ns(N: Integer): LongWord;         // non-symmetric unsigned in [0,N)
    function leb128: UInt64;                    // byte-aligned varint
    function le(N: Integer): UInt64;            // N little-endian bytes (aligned)

    procedure ByteAlign;
    function BytePos: NativeInt;                // current byte position (after align semantics)
    function BitPosition: Int64;
    procedure SetBitPosition(APos: Int64);
    function BitsLeft: Int64;
    function ByteAligned: Boolean;
  end;

// FloorLog2 helper (spec 4.7).
function FloorLog2(X: UInt64): Integer;

implementation

function FloorLog2(X: UInt64): Integer;
begin
  Result := 0;
  while X > 1 do
  begin
    X := X shr 1;
    Inc(Result);
  end;
end;

constructor TAv1Bits.Create(AData: PByte; ASize: NativeInt);
begin
  inherited Create;
  FData := AData;
  FSize := ASize;
  FBitPos := 0;
end;

function TAv1Bits.ReadBit: LongWord;
var
  BytePos: NativeInt;
  BitIdx: Integer;
begin
  BytePos := FBitPos shr 3;
  if BytePos >= FSize then
    raise EAv1.Create('AV1 bit reader: read past end');
  BitIdx := 7 - (FBitPos and 7);
  Result := (FData[BytePos] shr BitIdx) and 1;
  Inc(FBitPos);
end;

function TAv1Bits.f(N: Integer): LongWord;
var
  I: Integer;
begin
  if (N < 0) or (N > 32) then
    raise EAv1.CreateFmt('f(%d) out of range', [N]);
  Result := 0;
  for I := 0 to N - 1 do
    Result := (Result shl 1) or ReadBit;
end;

function TAv1Bits.f64(N: Integer): UInt64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to N - 1 do
    Result := (Result shl 1) or UInt64(ReadBit);
end;

function TAv1Bits.uvlc: LongWord;
var
  LeadingZeros: Integer;
  Value: LongWord;
begin
  LeadingZeros := 0;
  while True do
  begin
    if ReadBit = 1 then Break;
    Inc(LeadingZeros);
    if LeadingZeros >= 32 then Exit($FFFFFFFF);
  end;
  if LeadingZeros >= 32 then
    Exit($FFFFFFFF);
  Value := f(LeadingZeros);
  Result := Value + (LongWord(1) shl LeadingZeros) - 1;
end;

function TAv1Bits.su(N: Integer): LongInt;
// AV1 su(1+N): read N+1 bits MSB-first as two's complement (sign is the MSB).
// Callers pass N matching the spec's su(1+N) notation.
var
  Value: LongInt;
  SignMask: LongInt;
begin
  Value := LongInt(f(N + 1));
  SignMask := 1 shl N;
  if (Value and SignMask) <> 0 then
    Value := Value - (SignMask shl 1);
  Result := Value;
end;

function TAv1Bits.ns(N: Integer): LongWord;
var
  W, M, V, ExtraBit: Integer;
begin
  W := FloorLog2(N) + 1;
  M := (1 shl W) - N;
  V := f(W - 1);
  if V < M then
    Exit(LongWord(V));
  ExtraBit := f(1);
  Result := LongWord((V shl 1) - M + ExtraBit);
end;

function TAv1Bits.leb128: UInt64;
var
  I: Integer;
  B: LongWord;
begin
  Result := 0;
  for I := 0 to 7 do
  begin
    B := f(8);
    Result := Result or (UInt64(B and $7F) shl (I * 7));
    if (B and $80) = 0 then
      Break;
  end;
end;

function TAv1Bits.le(N: Integer): UInt64;
var
  I: Integer;
  B: LongWord;
begin
  Result := 0;
  for I := 0 to N - 1 do
  begin
    B := f(8);
    Result := Result or (UInt64(B) shl (I * 8));
  end;
end;

procedure TAv1Bits.ByteAlign;
begin
  while (FBitPos and 7) <> 0 do
    Inc(FBitPos);
end;

function TAv1Bits.BytePos: NativeInt;
begin
  Result := FBitPos shr 3;
end;

function TAv1Bits.BitPosition: Int64;
begin
  Result := FBitPos;
end;

procedure TAv1Bits.SetBitPosition(APos: Int64);
begin
  FBitPos := APos;
end;

function TAv1Bits.BitsLeft: Int64;
begin
  Result := Int64(FSize) * 8 - FBitPos;
end;

function TAv1Bits.ByteAligned: Boolean;
begin
  Result := (FBitPos and 7) = 0;
end;

end.
