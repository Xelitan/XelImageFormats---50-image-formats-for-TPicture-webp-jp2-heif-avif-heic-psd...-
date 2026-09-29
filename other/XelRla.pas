unit XelRla;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Alias/Wavefront RLA and RPF codec -> RGBA8                    //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// 740-byte big-endian header, per-scanline offset table, every channel of a   //
// scanline stored as <u16 length><RLE bytes>. RLE: signed count N>=0 repeats  //
// the next byte N+1 times, N<0 copies -N literal bytes. RPF uses the same     //
// layout with extra auxiliary channels (skipped).                             //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelPng;

type
  ERlaError = class(Exception);

function DecodeRla(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8
// Zapisuje RLA: 8 bit, RGB + 1 kanal matte (alfa), RLE. InBuf = RGBA8.
function EncodeRla(InBuf: TBytes; Width, Height: Integer): TBytes;         // InBuf = RGBA8

implementation

const
  RLA_HEADER = 740;

function RB16(const D: TBytes; P: NativeUInt): Word; inline;
begin
  Result := (Word(D[P]) shl 8) or Word(D[P + 1]);
end;

function RB32(const D: TBytes; P: NativeUInt): Cardinal; inline;
begin
  Result := (Cardinal(D[P]) shl 24) or (Cardinal(D[P + 1]) shl 16) or
            (Cardinal(D[P + 2]) shl 8) or Cardinal(D[P + 3]);
end;

// Decode one RLE strip of PackedLen bytes at Pos into Dest[0..Count-1].
procedure DecodeStrip(const D: TBytes; Pos, PackedLen: NativeUInt;
  var Dest: TBytes; Count: Integer);
var
  N, endp: NativeUInt;
  cnt, o, k: Integer;
  b: Byte;
begin
  FillChar(Dest[0], Count, 0);
  N := NativeUInt(Length(D));
  endp := Pos + PackedLen;
  if endp > N then endp := N;
  o := 0;
  while (Pos < endp) and (o < Count) do
  begin
    cnt := ShortInt(D[Pos]); Inc(Pos);
    if cnt >= 0 then
    begin
      if Pos >= endp then Break;
      b := D[Pos]; Inc(Pos);
      for k := 0 to cnt do
      begin
        if o >= Count then Break;
        Dest[o] := b; Inc(o);
      end;
    end
    else
    begin
      for k := 1 to -cnt do
      begin
        if (Pos >= endp) or (o >= Count) then Break;
        Dest[o] := D[Pos]; Inc(Pos); Inc(o);
      end;
    end;
  end;
end;

function DecodeRla(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  N, Pos, sl: NativeUInt;
  aLeft, aRight, aBottom, aTop: SmallInt;
  StorageType, NumChan, NumMatte, NumAux, ChanBits, MatteBits, AuxBits: Integer;
  W, H, y, imgY, x, ch, total, bps, cbps: Integer;
  BottomUp: Boolean;
  Strip: TBytes;
  Planes: array[0..3] of TBytes;
  Have: array[0..3] of Boolean;
  C: TRGBA;

  function PlaneByte(Idx, Col: Integer): Byte;
  begin
    // 16-bit samples are big-endian: take the high byte
    if bps = 2 then Result := Planes[Idx][Col * 2] else Result := Planes[Idx][Col];
  end;

begin
  Width := 0; Height := 0; SetLength(Result, 0);
  N := NativeUInt(Length(InBuf));
  if N < RLA_HEADER then raise ERlaError.Create('RLA: file too small');

  aLeft   := SmallInt(RB16(InBuf, 8));
  aRight  := SmallInt(RB16(InBuf, 10));
  aBottom := SmallInt(RB16(InBuf, 12));
  aTop    := SmallInt(RB16(InBuf, 14));
  StorageType := SmallInt(RB16(InBuf, 18));
  NumChan  := SmallInt(RB16(InBuf, 20));
  NumMatte := SmallInt(RB16(InBuf, 22));
  NumAux   := SmallInt(RB16(InBuf, 24));
  ChanBits  := SmallInt(RB16(InBuf, 658));
  MatteBits := SmallInt(RB16(InBuf, 662));
  AuxBits   := SmallInt(RB16(InBuf, 666));

  if StorageType <> 0 then raise ERlaError.Create('RLA: floating point channels are not supported');
  if (NumChan < 1) or (NumChan > 3) or (NumMatte < 0) or (NumAux < 0) then
    raise ERlaError.Create('RLA: unsupported channel layout');
  if ChanBits <= 0 then ChanBits := 8;
  if MatteBits <= 0 then MatteBits := ChanBits;
  if AuxBits <= 0 then AuxBits := 8;
  if (ChanBits > 16) or (MatteBits > 16) then raise ERlaError.Create('RLA: sample depth > 16 bits not supported');

  W := aRight - aLeft + 1;
  H := Abs(aTop - aBottom) + 1;
  BottomUp := aBottom < aTop;          // y axis points up: first scanline is the bottom row
  if (W <= 0) or (H <= 0) then raise ERlaError.Create('RLA: invalid dimensions');
  if RLA_HEADER + NativeUInt(H) * 4 > N then raise ERlaError.Create('RLA: truncated offset table');

  Width := W; Height := H;
  SetLength(Result, NativeInt(W) * H * 4);
  total := NumChan + NumMatte + NumAux;

  for y := 0 to H - 1 do
  begin
    Pos := RB32(InBuf, RLA_HEADER + NativeUInt(y) * 4);
    if BottomUp then imgY := H - 1 - y else imgY := y;
    for ch := 0 to 3 do Have[ch] := False;

    for ch := 0 to total - 1 do
    begin
      if Pos + 2 > N then Break;
      sl := RB16(InBuf, Pos); Inc(Pos, 2);
      if ch < NumChan then cbps := (ChanBits + 7) div 8
      else if ch < NumChan + NumMatte then cbps := (MatteBits + 7) div 8
      else cbps := (AuxBits + 7) div 8;

      if (ch < NumChan) or (ch = NumChan) then   // colour channels + first matte
      begin
        bps := cbps;
        SetLength(Strip, W * cbps);
        DecodeStrip(InBuf, Pos, sl, Strip, W * cbps);
        if ch < NumChan then begin Planes[ch] := Copy(Strip); Have[ch] := True; end
        else if NumMatte > 0 then begin Planes[3] := Copy(Strip); Have[3] := True; end;
      end;
      Inc(Pos, sl);
    end;

    for x := 0 to W - 1 do
    begin
      bps := (ChanBits + 7) div 8;
      if Have[0] then C.R := PlaneByte(0, x) else C.R := 0;
      if NumChan >= 3 then
      begin
        if Have[1] then C.G := PlaneByte(1, x) else C.G := 0;
        if Have[2] then C.B := PlaneByte(2, x) else C.B := 0;
      end
      else begin C.G := C.R; C.B := C.R; end;
      bps := (MatteBits + 7) div 8;
      if Have[3] then C.A := PlaneByte(3, x) else C.A := 255;
      SetPx(Result, W, x, imgY, C);
    end;
  end;
end;

// ---------------------------------- encoder ----------------------------------

procedure AppByte(var D: TBytes; var Len: NativeInt; B: Byte); inline;
begin
  if Len >= Length(D) then SetLength(D, Length(D) * 2 + 1024);
  D[Len] := B; Inc(Len);
end;

// RLE-encode Count bytes of Src into D (appending).
procedure EncodeStrip(const Src: TBytes; Count: Integer; var D: TBytes; var Len: NativeInt);
var
  i, run, lit, k: Integer;
begin
  i := 0;
  while i < Count do
  begin
    run := 1;
    while (i + run < Count) and (run < 128) and (Src[i + run] = Src[i]) do Inc(run);
    if run >= 3 then
    begin
      AppByte(D, Len, Byte(run - 1));      // N >= 0 : repeat N+1
      AppByte(D, Len, Src[i]);
      Inc(i, run);
    end
    else
    begin
      lit := 0;
      while (i + lit < Count) and (lit < 128) do
      begin
        run := 1;
        while (i + lit + run < Count) and (run < 3) and (Src[i + lit + run] = Src[i + lit]) do Inc(run);
        if run >= 3 then Break;
        Inc(lit);
      end;
      if lit = 0 then lit := 1;
      AppByte(D, Len, Byte(-lit));         // N < 0 : -N literal bytes
      for k := 0 to lit - 1 do AppByte(D, Len, Src[i + k]);
      Inc(i, lit);
    end;
  end;
end;

procedure PutB16(var D: TBytes; P: NativeUInt; V: Word); inline;
begin
  D[P] := Byte(V shr 8); D[P + 1] := Byte(V);
end;

procedure PutB32(var D: TBytes; P: NativeUInt; V: Cardinal); inline;
begin
  D[P] := Byte(V shr 24); D[P + 1] := Byte(V shr 16); D[P + 2] := Byte(V shr 8); D[P + 3] := Byte(V);
end;

procedure PutStr(var D: TBytes; P: NativeUInt; const S: AnsiString);
var i: Integer;
begin
  for i := 1 to Length(S) do D[P + NativeUInt(i) - 1] := Byte(S[i]);
end;

function EncodeRla(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  Len, LenPos: NativeInt;
  y, x, ch, imgY: Integer;
  Plane, Strip: TBytes;
  SLen: NativeInt;
  C: TRGBA;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) or (Width > 32767) or (Height > 32767) then
    raise ERlaError.Create('RLA: invalid image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise ERlaError.Create('RLA: RGBA8 buffer size does not match Width*Height*4');

  SetLength(Result, RLA_HEADER + Height * 4 + Width * Height * 5);
  FillChar(Result[0], Length(Result), 0);
  // window and active window: left, right, bottom, top
  PutB16(Result, 0, 0); PutB16(Result, 2, Word(Width - 1)); PutB16(Result, 4, 0); PutB16(Result, 6, Word(Height - 1));
  PutB16(Result, 8, 0); PutB16(Result, 10, Word(Width - 1)); PutB16(Result, 12, 0); PutB16(Result, 14, Word(Height - 1));
  PutB16(Result, 16, 1);        // frame
  PutB16(Result, 18, 0);        // storage: integer
  PutB16(Result, 20, 3);        // num_chan
  PutB16(Result, 22, 1);        // num_matte
  PutB16(Result, 24, 0);        // num_aux
  PutB16(Result, 26, $FFFE);    // revision
  PutStr(Result, 28, '2.2');
  PutStr(Result, 580, 'rgb');
  PutB16(Result, 658, 8);       // chan_bits
  PutB16(Result, 662, 8);       // matte_bits
  PutB16(Result, 666, 8);       // aux_bits

  Len := RLA_HEADER + Height * 4;
  SetLength(Plane, Width);
  SetLength(Strip, Width * 2 + 16);
  for y := 0 to Height - 1 do
  begin
    PutB32(Result, RLA_HEADER + NativeUInt(y) * 4, Cardinal(Len));
    imgY := Height - 1 - y;                 // bottom scanline first
    for ch := 0 to 3 do
    begin
      for x := 0 to Width - 1 do
      begin
        C := GetPx(InBuf, Width, x, imgY);
        case ch of 0: Plane[x] := C.R; 1: Plane[x] := C.G; 2: Plane[x] := C.B; else Plane[x] := C.A; end;
      end;
      LenPos := Len;
      AppByte(Result, Len, 0); AppByte(Result, Len, 0);      // length placeholder
      SLen := Len;
      EncodeStrip(Plane, Width, Result, Len);
      PutB16(Result, LenPos, Word(Len - SLen));
    end;
  end;
  SetLength(Result, Len);
end;

end.
