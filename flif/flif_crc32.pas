// FLIF - Free Lossless Image Format -- Free Pascal port
// CRC-32 (zlib polynomial), used for the optional image checksum.
// Corresponds to: src/image/crc32k.cpp (slicing-by-16 there; the plain
// table-driven version below produces identical results).
unit flif_crc32;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

const
  CRC_POLYNOMIAL = $EDB88320;

function crc32_fast(Data: Pointer; Length: SizeUInt; PreviousCrc32: Cardinal = 0): Cardinal;

implementation

var
  Crc32Lookup: array[0..255] of Cardinal;

procedure InitTable;
var
  I, J: Integer;
  C: Cardinal;
begin
  for I := 0 to 255 do
  begin
    C := Cardinal(I);
    for J := 0 to 7 do
      if (C and 1) <> 0 then
        C := (C shr 1) xor CRC_POLYNOMIAL
      else
        C := C shr 1;
    Crc32Lookup[I] := C;
  end;
end;

function crc32_fast(Data: Pointer; Length: SizeUInt; PreviousCrc32: Cardinal): Cardinal;
var
  Crc: Cardinal;
  Cur: PByte;
begin
  Crc := not PreviousCrc32;
  Cur := PByte(Data);
  while Length > 0 do
  begin
    Crc := (Crc shr 8) xor Crc32Lookup[(Crc and $FF) xor Cur^];
    Inc(Cur);
    Dec(Length);
  end;
  Result := not Crc;
end;

initialization
  InitTable;

end.
