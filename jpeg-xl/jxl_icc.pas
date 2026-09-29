{$mode delphi}
unit jxl_icc;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// Embedded ICC profile stream (libjxl icc_codec.cc ICCReader): the encoded
// profile is an entropy-coded byte stream with 41 contexts chosen from the
// two previous bytes. Decoding it is needed to reach the frames that follow;
// the bytes returned are the *encoded* profile (before libjxl's
// UnpredictICC), which is all this decoder needs.

interface

uses
  SysUtils, jxl_types, jxl_bits, jxl_ans;

function ReadEncodedICC(br: TBitReader): TBytes;

implementation

const
  kNumICCContexts = 41;

function ByteKind1(b: Byte): Integer;
begin
  if ((b >= Ord('a')) and (b <= Ord('z'))) or ((b >= Ord('A')) and (b <= Ord('Z'))) then Exit(0);
  if ((b >= Ord('0')) and (b <= Ord('9'))) or (b = Ord('.')) or (b = Ord(',')) then Exit(1);
  if b = 0 then Exit(2);
  if b = 1 then Exit(3);
  if b < 16 then Exit(4);
  if b = 255 then Exit(6);
  if b > 240 then Exit(5);
  Result := 7;
end;

function ByteKind2(b: Byte): Integer;
begin
  if ((b >= Ord('a')) and (b <= Ord('z'))) or ((b >= Ord('A')) and (b <= Ord('Z'))) then Exit(0);
  if ((b >= Ord('0')) and (b <= Ord('9'))) or (b = Ord('.')) or (b = Ord(',')) then Exit(1);
  if b < 16 then Exit(2);
  if b > 240 then Exit(3);
  Result := 4;
end;

function ICCANSContext(i: Int64; b1, b2: Byte): Integer;
begin
  if i <= 128 then Exit(0);
  Result := 1 + ByteKind1(b1) + ByteKind2(b2) * 8;
end;

function ReadEncodedICC(br: TBitReader): TBytes;
var
  encSize: UInt64;
  ans: TANSDecoder;
  i: Int64;
  b1, b2: Byte;
begin
  Result := nil;
  encSize := br.ReadU64;
  if encSize > 268435456 then
    raise EJxlError.Create('Too large encoded ICC profile');
  SetLength(Result, encSize);
  ans := TANSDecoder.Create;
  try
    ans.Init(br, kNumICCContexts);
    for i := 0 to Int64(encSize) - 1 do
    begin
      if i > 0 then b1 := Result[i - 1] else b1 := 0;
      if i > 1 then b2 := Result[i - 2] else b2 := 0;
      Result[i] := Byte(ans.Decode(ICCANSContext(i, b1, b2), br));
    end;
    if not ans.CheckFinalState then
      raise EJxlError.Create('Corrupted ICC profile');
  finally
    ans.Free;
  end;
end;

end.
