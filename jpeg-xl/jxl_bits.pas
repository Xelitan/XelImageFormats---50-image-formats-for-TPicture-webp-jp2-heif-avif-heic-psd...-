{$mode delphi}
unit jxl_bits;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// Bit reader for JPEG XL. Bits are read LSB-first.
// The internal buffer holds up to 64 bits; it is refilled by reading bytes
// from the source array.

interface

uses SysUtils;

type
  TBitReader = class
  private
    FData:       PByte;
    FSize:       NativeUInt;
    FPos:        NativeUInt;   // next byte to read
    FBuf:        UInt64;       // bit buffer (LSB = next bit)
    FBitsInBuf:  Integer;      // valid bits in FBuf

    procedure Refill; inline;
  public
    constructor Create(AData: PByte; ASize: NativeUInt);

    // Read n bits (0..32), return as Cardinal
    function ReadBits(n: Integer): Cardinal;
    function ReadBit: Boolean; inline;
    function PeekBits(n: Integer): Cardinal; inline;  // no advance
    procedure SkipBits(n: Integer); inline;

    // Aligned reads (will refill as needed)
    function ReadByte: Byte;

    // JXL-specific multi-case integer reads
    // U32(d0,n0, d1,n1, d2,n2, d3,n3):
    //   sel = ReadBits(2); return d_sel + ReadBits(n_sel)
    function ReadU32(d0: Cardinal; n0: Integer;
                     d1: Cardinal; n1: Integer;
                     d2: Cardinal; n2: Integer;
                     d3: Cardinal; n3: Integer): Cardinal;

    // JXL U64 variable-length encoding
    function ReadU64: UInt64;

    // 16-bit float -> 32-bit float (JXL uses this for some metadata)
    function ReadF16: Single;

    // Align to next byte boundary (discard partial byte bits)
    procedure AlignToByte;

    // Skip forward n bytes (must be byte-aligned when called)
    procedure SkipBytes(n: NativeUInt);

    // Total bits consumed so far
    function BitsRead: UInt64;

    // True when more bits were consumed than the source holds.
    function OverRead: Boolean;

    // Bytes remaining in source (approximate)
    function BytesLeft: Int64;

    property BytePos: NativeUInt read FPos;
    property BitsInBuf: Integer read FBitsInBuf;
    // Underlying codestream buffer — used to spawn per-section sub-readers.
    property Data: PByte read FData;
    property TotalSize: NativeUInt read FSize;
  end;

implementation

constructor TBitReader.Create(AData: PByte; ASize: NativeUInt);
begin
  FData      := AData;
  FSize      := ASize;
  FPos       := 0;
  FBuf       := 0;
  FBitsInBuf := 0;
end;

procedure TBitReader.Refill;
begin
  // Fill up to 64 bits from source bytes; past the end the stream reads as
  // zeros (as libjxl's BitReader does).
  while FBitsInBuf <= 56 do
  begin
    if FPos < FSize then
      FBuf := FBuf or (UInt64(FData[FPos]) shl FBitsInBuf);
    Inc(FPos);
    Inc(FBitsInBuf, 8);
  end;
end;

function TBitReader.ReadBits(n: Integer): Cardinal;
var mask: UInt64;
begin
  if n = 0 then begin Result := 0; Exit; end;
  Refill;
  if n = 64 then
    mask := UInt64($FFFFFFFFFFFFFFFF)
  else
    mask := (UInt64(1) shl n) - 1;
  Result     := Cardinal(FBuf and mask);
  FBuf       := FBuf shr n;
  Dec(FBitsInBuf, n);
end;

function TBitReader.ReadBit: Boolean;
begin
  Refill;
  Result   := (FBuf and 1) <> 0;
  FBuf     := FBuf shr 1;
  Dec(FBitsInBuf);
end;

function TBitReader.PeekBits(n: Integer): Cardinal;
var mask: UInt64;
begin
  Refill;
  if n = 0 then begin Result := 0; Exit; end;
  mask   := (UInt64(1) shl n) - 1;
  Result := Cardinal(FBuf and mask);
end;

procedure TBitReader.SkipBits(n: Integer);
begin
  Refill;
  FBuf       := FBuf shr n;
  Dec(FBitsInBuf, n);
end;

function TBitReader.ReadByte: Byte;
begin
  Result := ReadBits(8);
end;

function TBitReader.ReadU32(d0: Cardinal; n0: Integer;
                             d1: Cardinal; n1: Integer;
                             d2: Cardinal; n2: Integer;
                             d3: Cardinal; n3: Integer): Cardinal;
var sel: Integer;
begin
  sel := ReadBits(2);
  case sel of
    0: Result := d0 + ReadBits(n0);
    1: Result := d1 + ReadBits(n1);
    2: Result := d2 + ReadBits(n2);
  else Result := d3 + ReadBits(n3);
  end;
end;

function TBitReader.ReadU64: UInt64;
var sel, bits, shift: Integer; v: UInt64;
begin
  sel := ReadBits(2);
  case sel of
    0: Result := 0;
    1: Result := 1 + ReadBits(4);
    2: Result := 17 + ReadBits(8);
    3: begin
         v     := ReadBits(12);
         shift := 12;
         while ReadBit do
         begin
           if shift = 60 then begin
             v := v or (UInt64(ReadBits(4)) shl 60);
             Break;
           end;
           bits := ReadBits(8);
           v    := v or (UInt64(bits) shl shift);
           Inc(shift, 8);
         end;
         Result := v;
       end;
  else Result := 0;
  end;
end;

// IEEE 754 half-precision → single-precision
function TBitReader.ReadF16: Single;
var h, sign, exponent, mantissa: Cardinal; f: Single; bits: Single absolute f;
    i: LongInt absolute bits;
begin
  h        := ReadBits(16);
  sign     := (h shr 15) and 1;
  exponent := (h shr 10) and $1F;
  mantissa := h and $3FF;
  if exponent = 0 then begin
    if mantissa = 0 then
      f := 0.0
    else begin
      // Subnormal
      f := mantissa * (1.0 / (1 shl 24));
      if sign <> 0 then f := -f;
    end;
  end else if exponent = 31 then begin
    // Inf or NaN
    i := (sign shl 31) or $7F800000 or (mantissa shl 13);
  end else begin
    i := (sign shl 31) or ((exponent + 112) shl 23) or (mantissa shl 13);
  end;
  Result := f;
end;

procedure TBitReader.AlignToByte;
var rem: Integer;
begin
  rem := FBitsInBuf mod 8;
  if rem > 0 then begin
    FBuf       := FBuf shr rem;
    Dec(FBitsInBuf, rem);
  end;
end;

procedure TBitReader.SkipBytes(n: NativeUInt);
var bufferedBytes: Integer;
begin
  // Must be byte-aligned; caller should call AlignToByte first
  // Consume any already-buffered bytes
  bufferedBytes := FBitsInBuf div 8;
  while (n > 0) and (bufferedBytes > 0) do begin
    FBuf       := FBuf shr 8;
    Dec(FBitsInBuf, 8);
    Dec(bufferedBytes);
    Dec(n);
  end;
  // Skip the rest directly in the source array
  if n > 0 then Inc(FPos, n);
end;

function TBitReader.BitsRead: UInt64;
begin
  Result := UInt64(FPos) * 8 - FBitsInBuf;
end;

function TBitReader.OverRead: Boolean;
begin
  Result := BitsRead > UInt64(FSize) * 8;
end;

function TBitReader.BytesLeft: Int64;
begin
  Result := Int64(FSize) - Int64(FPos) + (FBitsInBuf div 8);
end;

end.
