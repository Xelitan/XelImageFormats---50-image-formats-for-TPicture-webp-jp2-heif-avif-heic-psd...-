unit LeptonHelpers;

{$mode delphi}

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//

interface

uses SysUtils;

// Returns the bit length of a 16‑bit unsigned integer. The result is
//  the index of the highest set bit plus one, or zero if the value is zero.
//  Equivalent to Rust's `16 - v.leading_zeros()` for `u16`.
function U16BitLength(v: Word): Byte;

// Returns the bit length of a 32‑bit unsigned integer. The result is
//  the index of the highest set bit plus one, or zero if the value is zero.
//  Equivalent to Rust's `32 - v.leading_zeros()` for `u32`.
function U32BitLength(v: Cardinal): Byte;

// Tests whether the prefix of Buffer matches Marker.  Returns True if
//  `Length(Marker)` bytes at the start of Buffer equal Marker.  Buffer
//  must be at least as long as Marker.
function BufferPrefixMatchesMarker(const Buffer: array of Byte; const Marker: array of Byte): Boolean;

// Returns True if the 64‑bit integer contains the byte value $FF anywhere.
function HasFF(v: UInt64): Boolean;

// The `devli` function used in arithmetic coding.  Given a bit length `s`
//  and the raw value, reconstructs the signed value.
function Devli(s: Byte; value: Word): SmallInt;

// Combines two bytes into a 16‑bit value.  Equivalent to `(v1 << 8) + v2`.
function BShort(v1, v2: Byte): Word;

// Returns the n least significant bits of the byte c.  n must be between 0 and 8.
function RBits(c: Byte; n: Integer): Byte;

// Returns the n most significant bits of the byte c.  n must be between 0 and 8.
function LBits(c: Byte; n: Integer): Byte;

// Returns bit n of a 16‑bit value c.  n starts at 0 for the least significant bit.
function BitN(c: Word; n: Integer): Byte;

// Returns 0 if val = 0, 1 if val > 0 and 2 if val < 0. Used for sign contexts.
function CalcSignIndex(val: SmallInt): Integer;

implementation

function U16BitLength(v: Word): Byte;
begin
  if v = 0 then
    Result := 0
  else
  begin
    Result := 16;
    while (v and (1 shl (Result - 1))) = 0 do
      Dec(Result);
  end;
end;

function U32BitLength(v: Cardinal): Byte;
begin
  if v = 0 then
    Result := 0
  else
  begin
    Result := 32;
    while (v and (1 shl (Result - 1))) = 0 do
      Dec(Result);
  end;
end;

function BufferPrefixMatchesMarker(const Buffer: array of Byte; const Marker: array of Byte): Boolean;
var
  i: Integer;
begin
  if Length(Buffer) < Length(Marker) then
    Exit(False);
  for i := 0 to High(Marker) do
    if Buffer[i] <> Marker[i] then
      Exit(False);
  Result := True;
end;

function HasFF(v: UInt64): Boolean;
begin
  // Use the same bit trick as in Rust: detect if any byte in the 64‑bit
  //  value is equal to $FF.  The original implementation uses
  //    (v & 0x8080808080808080 & !v.wrapping_add(0x0101010101010101)) != 0
  //  which is equivalent to the check below.
  Result := ((v and $8080808080808080) and (not (v + $0101010101010101))) <> 0;
end;

function Devli(s: Byte; value: Word): SmallInt;
var
  shifted: Integer;
begin
  shifted := 1 shl s;
  if (value and (shifted shr 1)) <> 0 then
    Result := SmallInt(value)
  else
  begin
    // Rust: value.wrapping_add(2).wrapping_add(!shifted) == value - shifted + 1
    Result := SmallInt(Integer(value) - shifted + 1);
  end;
end;

function BShort(v1, v2: Byte): Word;
begin
  Result := (Word(v1) shl 8) or Word(v2);
end;

function RBits(c: Byte; n: Integer): Byte;
begin
  if n >= 8 then
    Result := c
  else if n <= 0 then
    Result := 0
  else
    Result := c and ($FF shr (8 - n));
end;

function LBits(c: Byte; n: Integer): Byte;
begin
  if n >= 8 then
    Result := c
  else if n <= 0 then
    Result := 0
  else
    Result := c shr (8 - n);
end;

function BitN(c: Word; n: Integer): Byte;
begin
  if n < 0 then
    Result := 0
  else
    Result := Byte((c shr n) and $1);
end;

function CalcSignIndex(val: SmallInt): Integer;
begin
  if val = 0 then
    Result := 0
  else if val > 0 then
    Result := 1
  else
    Result := 2;
end;

end.