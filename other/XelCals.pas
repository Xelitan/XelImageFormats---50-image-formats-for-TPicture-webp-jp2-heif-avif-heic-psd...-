unit XelCals;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	CALS Raster Type 1 decoder                                    //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// CALS Type 1 (MIL-PRF-28002) is a 2048-byte ASCII header made of 128-byte
// records ("rtype: 1", "rorient: 1,270", "rpelcnt: 1728,2200", ...) followed by
// a single bi-level raster encoded with CCITT Group 4 (T.6) - pel value 1 =
// black. Rather than re-implement Group 4, we wrap the raster in a minimal
// in-memory TIFF (Compression=4, Photometric=0/WhiteIsZero) and hand it to the
// project's existing, tested TIFF decoder. Orientation (rorient) is not applied;
// virtually all CALS files store the raster ready to display.

interface

uses
  SysUtils, Classes, XelTiff;

type
  ECalsError = class(Exception);

function DecodeCals(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8

implementation

const
  HeaderSize = 2048;
  RecordSize = 128;

// Reads a 128-byte record as text and, if its keyword matches Key, returns the
// text after the colon (trimmed). Returns '' otherwise.
function RecordValue(const InBuf: TBytes; RecOfs: NativeUInt; const Key: string): string;
var
  I, ColonAt: Integer;
  Rec: string;
begin
  Result := '';
  SetLength(Rec, RecordSize);
  for I := 1 to RecordSize do
    Rec[I] := Chr(InBuf[RecOfs + NativeUInt(I - 1)]);
  ColonAt := Pos(':', Rec);
  if ColonAt <= 0 then Exit;
  if LowerCase(Trim(Copy(Rec, 1, ColonAt - 1))) <> LowerCase(Key) then Exit;
  Result := Trim(Copy(Rec, ColonAt + 1, RecordSize - ColonAt));
end;

procedure ParsePelCount(const S: string; out W, H: Integer);
var
  CommaAt, Code: Integer;
  WS, HS: string;
  Wv, Hv: LongInt;
begin
  W := 0; H := 0;
  CommaAt := Pos(',', S);
  if CommaAt <= 0 then Exit;
  WS := Trim(Copy(S, 1, CommaAt - 1));
  HS := Trim(Copy(S, CommaAt + 1, Length(S)));
  Val(WS, Wv, Code); if Code = 0 then W := Wv;
  Val(HS, Hv, Code); if Code = 0 then H := Hv;
end;

// ------------------------- synthetic little-endian TIFF --------------------

procedure PutU16LE(var D: TBytes; P: NativeUInt; V: Word); inline;
begin
  D[P] := Byte(V); D[P + 1] := Byte(V shr 8);
end;

procedure PutU32LE(var D: TBytes; P: NativeUInt; V: Cardinal); inline;
begin
  D[P] := Byte(V); D[P + 1] := Byte(V shr 8);
  D[P + 2] := Byte(V shr 16); D[P + 3] := Byte(V shr 24);
end;

function DecodeCals(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  N, PayloadLen, DataOfs, IfdOfs, EntryPos: NativeUInt;
  W, H, RecIdx: Integer;
  Val0: string;
  Tiff: TBytes;

  procedure Entry(Tag, Typ: Word; Count, Value: Cardinal);
  begin
    PutU16LE(Tiff, EntryPos + 0, Tag);
    PutU16LE(Tiff, EntryPos + 2, Typ);
    PutU32LE(Tiff, EntryPos + 4, Count);
    PutU32LE(Tiff, EntryPos + 8, Value);   // SHORT count 1 -> value in low 2 bytes (LE)
    Inc(EntryPos, 12);
  end;

  // Wrap the Group 4 payload in a minimal TIFF of AW x AH and decode it. Returns
  // nil (never raises) if the scan-line width does not match the encoded runs.
  function TryDecode(AW, AH: Integer): TBytes;
  var OW, OH: Integer;
  begin
    Result := nil;
    IfdOfs := DataOfs + PayloadLen;
    if (IfdOfs and 1) <> 0 then Inc(IfdOfs);          // IFD must be word-aligned
    SetLength(Tiff, NativeInt(IfdOfs + 2 + 9 * 12 + 4));
    Tiff[0] := Ord('I'); Tiff[1] := Ord('I');
    PutU16LE(Tiff, 2, 42);
    PutU32LE(Tiff, 4, Cardinal(IfdOfs));
    Move(InBuf[HeaderSize], Tiff[DataOfs], PayloadLen);
    PutU16LE(Tiff, IfdOfs, 9);                        // 9 IFD entries, sorted by tag
    EntryPos := IfdOfs + 2;
    Entry(256, 4, 1, Cardinal(AW));                   // ImageWidth  (LONG)
    Entry(257, 4, 1, Cardinal(AH));                   // ImageLength (LONG)
    Entry(258, 3, 1, 1);                              // BitsPerSample = 1
    Entry(259, 3, 1, 4);                              // Compression = Group 4
    Entry(262, 3, 1, 0);                              // Photometric = WhiteIsZero
    Entry(273, 4, 1, Cardinal(DataOfs));              // StripOffsets
    Entry(277, 3, 1, 1);                              // SamplesPerPixel
    Entry(278, 4, 1, Cardinal(AH));                   // RowsPerStrip = whole image
    Entry(279, 4, 1, Cardinal(PayloadLen));           // StripByteCounts
    PutU32LE(Tiff, EntryPos, 0);                      // next IFD = none
    try
      Result := DecodeTiff(Tiff, OW, OH);
    except
      Result := nil;
    end;
    if (OW <= 0) or (OH <= 0) or (Length(Result) = 0) then Result := nil
    else begin Width := OW; Height := OH; end;
  end;

begin
  Width := 0; Height := 0;
  SetLength(Result, 0);

  N := NativeUInt(Length(InBuf));
  if N <= HeaderSize then
    raise ECalsError.Create('CALS: file shorter than header + raster');

  // scan the 16 header records for rpelcnt
  W := 0; H := 0;
  for RecIdx := 0 to (HeaderSize div RecordSize) - 1 do
  begin
    Val0 := RecordValue(InBuf, NativeUInt(RecIdx) * RecordSize, 'rpelcnt');
    if Val0 <> '' then
    begin
      ParsePelCount(Val0, W, H);
      Break;
    end;
  end;
  if (W <= 0) or (H <= 0) then
    raise ECalsError.Create('CALS: missing/invalid rpelcnt');
  if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then
    raise ECalsError.Create('CALS: image too large');

  // Wrap the Group 4 payload in a synthetic TIFF and decode. rpelcnt normally
  // gives the scan-line width first; some rotated orientations (rorient) swap it,
  // so fall back to the transposed dimensions if the first attempt fails.
  PayloadLen := N - HeaderSize;
  DataOfs := 8;

  Result := TryDecode(W, H);
  if Result = nil then Result := TryDecode(H, W);
  if Result = nil then
    raise ECalsError.Create('CALS: Group 4 raster decode failed');
end;

end.
