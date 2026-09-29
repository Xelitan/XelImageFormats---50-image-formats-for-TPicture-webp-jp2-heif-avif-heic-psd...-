unit XelInflate;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Pure-Pascal DEFLATE / zlib inflate                            //
// Version:	0.1                                                           //
// Date:	25-JUN-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// A small self-contained RFC1951 (raw DEFLATE) decompressor with an RFC1950  //
// (zlib) unwrapper. Used by the PNG/APNG decoder to inflate IDAT / fdAT data //
// without depending on an external zlib. Canonical-Huffman decoding follows  //
// the well-known "puff" reference structure.                                 //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses SysUtils;

// Inflate a raw DEFLATE bitstream (no zlib header/trailer).
function InflateRaw(Src: PByte; SrcLen: NativeUInt): TBytes;
// Inflate a zlib-wrapped stream (2-byte header skipped, Adler-32 trailer ignored).
function InflateZlib(Src: PByte; SrcLen: NativeUInt): TBytes;

implementation

type
  THuff = record
    Count:  array[0..15] of Word;   // number of codes of each bit length
    Symbol: array of Integer;       // symbols ordered by code
  end;

  TInflater = class
  private
    FSrc:    PByte;
    FSrcLen: NativeUInt;
    FInPos:  NativeUInt;
    FBitBuf: Cardinal;
    FBitCnt: Integer;
    FOverrun: Integer;   // zero bits handed out past the end of the input
    FOut:    TBytes;
    FOutLen: NativeUInt;
    function  GetBit: Integer;
    function  GetBits(n: Integer): Integer;
    procedure PutByte(b: Byte);
    procedure BuildHuff(var h: THuff; const Lengths: array of Integer; n: Integer);
    function  Decode(const h: THuff): Integer;
    procedure Codes(const lh, dh: THuff);
    procedure InflateStored;
    procedure InflateFixed;
    procedure InflateDynamic;
  public
    function Run(ASrc: PByte; ASrcLen: NativeUInt; AStartPos: NativeUInt): TBytes;
  end;

const
  LBase: array[0..28] of Word =
    (3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258);
  LExt: array[0..28] of Byte =
    (0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0);
  DBase: array[0..29] of Word =
    (1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,
     1025,1537,2049,3073,4097,6145,8193,12289,16385,24577);
  DExt: array[0..29] of Byte =
    (0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13);
  CLOrder: array[0..18] of Byte =
    (16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15);

function TInflater.GetBit: Integer;
begin
  if FBitCnt = 0 then
  begin
    if FInPos >= FSrcLen then
    begin
      // Out of data: hand out a few zero bits so a stream cut right at its
      // end-code still finishes. A truncated stream can decode zero bits as
      // literals forever (dynamic Huffman), so give up after a few bytes.
      Inc(FOverrun);
      if FOverrun > 64 then
        raise Exception.Create('Inflate: unexpected end of compressed data');
      Result := 0;
      Exit;
    end;
    FBitBuf := FSrc[FInPos];
    Inc(FInPos);
    FBitCnt := 8;
  end;
  Result := FBitBuf and 1;
  FBitBuf := FBitBuf shr 1;
  Dec(FBitCnt);
end;

function TInflater.GetBits(n: Integer): Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to n - 1 do
    Result := Result or (GetBit shl i);
end;

procedure TInflater.PutByte(b: Byte);
begin
  if FOutLen >= NativeUInt(Length(FOut)) then
    SetLength(FOut, (Length(FOut) * 2) + 4096);
  FOut[FOutLen] := b;
  Inc(FOutLen);
end;

procedure TInflater.BuildHuff(var h: THuff; const Lengths: array of Integer; n: Integer);
var
  i, len: Integer;
  offs: array[0..16] of Integer;
begin
  for len := 0 to 15 do h.Count[len] := 0;
  for i := 0 to n - 1 do
    Inc(h.Count[Lengths[i]]);
  // Symbols of length 0 are not part of any code.
  offs[1] := 0;
  for len := 1 to 15 do
    offs[len + 1] := offs[len] + h.Count[len];
  SetLength(h.Symbol, n);
  for i := 0 to n - 1 do
    if Lengths[i] <> 0 then
    begin
      h.Symbol[offs[Lengths[i]]] := i;
      Inc(offs[Lengths[i]]);
    end;
end;

function TInflater.Decode(const h: THuff): Integer;
var
  len, code, first, count, index: Integer;
begin
  code := 0; first := 0; index := 0;
  for len := 1 to 15 do
  begin
    code := code or GetBit;
    count := h.Count[len];
    if (code - first) < count then
      Exit(h.Symbol[index + (code - first)]);
    index := index + count;
    first := (first + count) shl 1;
    code  := code shl 1;
  end;
  Result := -1;   // invalid code
end;

procedure TInflater.Codes(const lh, dh: THuff);
var
  sym, len, dist, i: Integer;
begin
  repeat
    sym := Decode(lh);
    if sym < 0 then
      raise Exception.Create('Inflate: bad literal/length code');
    if sym = 256 then Break;          // end of block
    if sym < 256 then
      PutByte(Byte(sym))
    else
    begin
      sym := sym - 257;
      if sym >= 29 then
        raise Exception.Create('Inflate: invalid length symbol');
      len := LBase[sym] + GetBits(LExt[sym]);
      sym := Decode(dh);
      if (sym < 0) or (sym >= 30) then
        raise Exception.Create('Inflate: invalid distance symbol');
      dist := DBase[sym] + GetBits(DExt[sym]);
      if NativeUInt(dist) > FOutLen then
        raise Exception.Create('Inflate: distance too far back');
      for i := 0 to len - 1 do
        PutByte(FOut[FOutLen - NativeUInt(dist)]);
    end;
  until False;
end;

procedure TInflater.InflateStored;
var
  len, i: Integer;
begin
  // Skip to the next byte boundary.
  FBitCnt := 0;
  FBitBuf := 0;
  if FInPos + 4 > FSrcLen then
    raise Exception.Create('Inflate: truncated stored block');
  len := FSrc[FInPos] or (Integer(FSrc[FInPos + 1]) shl 8);
  Inc(FInPos, 4);   // LEN(2) + NLEN(2)
  if FInPos + NativeUInt(len) > FSrcLen then
    raise Exception.Create('Inflate: stored block overruns input');
  for i := 0 to len - 1 do
  begin
    PutByte(FSrc[FInPos]);
    Inc(FInPos);
  end;
end;

procedure TInflater.InflateFixed;
var
  lh, dh: THuff;
  lengths: array[0..287] of Integer;
  dlen:    array[0..29]  of Integer;
  i: Integer;
begin
  for i := 0   to 143 do lengths[i] := 8;
  for i := 144 to 255 do lengths[i] := 9;
  for i := 256 to 279 do lengths[i] := 7;
  for i := 280 to 287 do lengths[i] := 8;
  for i := 0   to 29  do dlen[i] := 5;
  BuildHuff(lh, lengths, 288);
  BuildHuff(dh, dlen, 30);
  Codes(lh, dh);
end;

procedure TInflater.InflateDynamic;
var
  hlit, hdist, hclen, i, sym, prev, rep: Integer;
  clen:    array[0..18]  of Integer;
  lengths: array[0..319] of Integer;   // hlit + hdist combined (<= 286+32)
  ch, lh, dh: THuff;
  litLen:  array[0..287] of Integer;
  distLen: array[0..31]  of Integer;
begin
  hlit  := GetBits(5) + 257;
  hdist := GetBits(5) + 1;
  hclen := GetBits(4) + 4;
  if (hlit > 286) or (hdist > 30) then
    raise Exception.Create('Inflate: bad dynamic header counts');

  for i := 0 to 18 do clen[i] := 0;
  for i := 0 to hclen - 1 do
    clen[CLOrder[i]] := GetBits(3);
  BuildHuff(ch, clen, 19);

  i := 0;
  prev := 0;
  while i < hlit + hdist do
  begin
    sym := Decode(ch);
    if sym < 0 then
      raise Exception.Create('Inflate: bad code-length code');
    if sym < 16 then
    begin
      lengths[i] := sym;
      prev := sym;
      Inc(i);
    end
    else if sym = 16 then
    begin
      rep := 3 + GetBits(2);
      while (rep > 0) and (i < hlit + hdist) do
      begin
        lengths[i] := prev; Inc(i); Dec(rep);
      end;
    end
    else if sym = 17 then
    begin
      rep := 3 + GetBits(3);
      while (rep > 0) and (i < hlit + hdist) do
      begin
        lengths[i] := 0; Inc(i); Dec(rep);
      end;
      prev := 0;
    end
    else // sym = 18
    begin
      rep := 11 + GetBits(7);
      while (rep > 0) and (i < hlit + hdist) do
      begin
        lengths[i] := 0; Inc(i); Dec(rep);
      end;
      prev := 0;
    end;
  end;

  for i := 0 to hlit - 1 do  litLen[i]  := lengths[i];
  for i := 0 to hdist - 1 do distLen[i] := lengths[hlit + i];
  BuildHuff(lh, litLen, hlit);
  BuildHuff(dh, distLen, hdist);
  Codes(lh, dh);
end;

function TInflater.Run(ASrc: PByte; ASrcLen: NativeUInt; AStartPos: NativeUInt): TBytes;
var
  bfinal, btype: Integer;
begin
  FSrc    := ASrc;
  FSrcLen := ASrcLen;
  FInPos  := AStartPos;
  FBitBuf := 0;
  FBitCnt := 0;
  FOverrun := 0;
  FOutLen := 0;
  SetLength(FOut, 0);

  repeat
    bfinal := GetBit;
    btype  := GetBits(2);
    case btype of
      0: InflateStored;
      1: InflateFixed;
      2: InflateDynamic;
    else
      raise Exception.Create('Inflate: invalid block type');
    end;
  until bfinal = 1;

  SetLength(FOut, FOutLen);
  Result := FOut;
end;

function InflateRaw(Src: PByte; SrcLen: NativeUInt): TBytes;
var inf: TInflater;
begin
  inf := TInflater.Create;
  try
    Result := inf.Run(Src, SrcLen, 0);
  finally
    inf.Free;
  end;
end;

function InflateZlib(Src: PByte; SrcLen: NativeUInt): TBytes;
var inf: TInflater;
begin
  if SrcLen < 2 then
    raise Exception.Create('Inflate: zlib stream too small');
  inf := TInflater.Create;
  try
    // Skip 2-byte zlib header (CMF, FLG); ignore the 4-byte Adler-32 trailer.
    Result := inf.Run(Src, SrcLen, 2);
  finally
    inf.Free;
  end;
end;

end.
