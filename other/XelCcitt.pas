unit XelCcitt;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	CCITT bilevel decoder: T.4 (G3, 1D/2D), T.6 (G4), MH          //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Clean-room implementation from ITU-T Rec. T.4 / T.6. Output is one byte     //
// per pixel: 0 = "white" run, 1 = "black" run (the caller applies polarity).  //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes;

type
  ECcittError = class(Exception);

  TCcittKind = (
    ckMH,      // Modified Huffman (TIFF compression 2): 1D rows, no EOL, byte-aligned rows
    ckT4,      // T.4 / Group 3 (TIFF compression 3, raw .g3): EOL-delimited, 1D or 2D
    ckT6       // T.6 / Group 4 (TIFF compression 4): 2D rows, no EOL
  );

// Decodes a CCITT stream. Height < 0 means "until the data ends / RTC".
// Returns Width*Rows bytes (0/1); Rows = number of rows produced.
function CcittDecode(const Src: TBytes; Width, Height: Integer; Kind: TCcittKind;
  T4TwoD, ReverseBits: Boolean; out Rows: Integer): TBytes;

// As CcittDecode, also reporting how many rows had coding errors.
function CcittDecodeEx(const Src: TBytes; Width, Height: Integer; Kind: TCcittKind;
  T4TwoD, ReverseBits: Boolean; out Rows, ErrRows: Integer): TBytes;

// Decodes a raw (container-less) Group 3 fax stream. Width and 1D/2D coding are
// detected automatically. Returns RGBA8 (black on white).
function DecodeRawG3(const Src: TBytes; out Width, Height: Integer): TBytes;

// True if the data looks like a raw G3 stream (starts with an EOL).
function LooksLikeRawG3(const Src: TBytes): Boolean;

implementation

type
  TCode = record Run: SmallInt; Len: Byte; end;   // Run: >=0 run length, -1 invalid
  TTable = array[0..8191] of TCode;               // indexed by the next 13 bits

var
  WhiteTab, BlackTab: TTable;
  ModeTab: array[0..127] of ShortInt;             // indexed by the next 7 bits
  ModeLen: array[0..127] of Byte;
  TablesReady: Boolean = False;

const
  // 2D coding modes
  M_P = 0; M_H = 1; M_V0 = 2; M_VR1 = 3; M_VR2 = 4; M_VR3 = 5;
  M_VL1 = 6; M_VL2 = 7; M_VL3 = 8; M_EXT = 9; M_ZERO = 10;

  WhiteTerm: array[0..63] of AnsiString = (
    '00110101','000111','0111','1000','1011','1100','1110','1111',
    '10011','10100','00111','01000','001000','000011','110100','110101',
    '101010','101011','0100111','0001100','0001000','0010111','0000011','0000100',
    '0101000','0101011','0010011','0100100','0011000','00000010','00000011','00011010',
    '00011011','00010010','00010011','00010100','00010101','00010110','00010111','00101000',
    '00101001','00101010','00101011','00101100','00101101','00000100','00000101','00001010',
    '00001011','01010010','01010011','01010100','01010101','00100100','00100101','01011000',
    '01011001','01011010','01011011','01001010','01001011','00110010','00110011','00110100');
  WhiteMakeup: array[1..27] of AnsiString = (
    '11011','10010','010111','0110111','00110110','00110111','01100100','01100101',
    '01101000','01100111','011001100','011001101','011010010','011010011','011010100','011010101',
    '011010110','011010111','011011000','011011001','011011010','011011011','010011000','010011001',
    '010011010','011000','010011011');
  BlackTerm: array[0..63] of AnsiString = (
    '0000110111','010','11','10','011','0011','0010','00011',
    '000101','000100','0000100','0000101','0000111','00000100','00000111','000011000',
    '0000010111','0000011000','0000001000','00001100111','00001101000','00001101100','00000110111','00000101000',
    '00000010111','00000011000','000011001010','000011001011','000011001100','000011001101','000001101000','000001101001',
    '000001101010','000001101011','000011010010','000011010011','000011010100','000011010101','000011010110','000011010111',
    '000001101100','000001101101','000011011010','000011011011','000001010100','000001010101','000001010110','000001010111',
    '000001100100','000001100101','000001010010','000001010011','000000100100','000000110111','000000111000','000000100111',
    '000000101000','000001011000','000001011001','000000101011','000000101100','000001011010','000001100110','000001100111');
  BlackMakeup: array[1..27] of AnsiString = (
    '0000001111','000011001000','000011001001','000001011011','000000110011','000000110100','000000110101','0000001101100',
    '0000001101101','0000001001010','0000001001011','0000001001100','0000001001101','0000001110010','0000001110011','0000001110100',
    '0000001110101','0000001110110','0000001110111','0000001010010','0000001010011','0000001010100','0000001010101','0000001011010',
    '0000001011011','0000001100100','0000001100101');
  ExtMakeup: array[0..12] of AnsiString = (   // 1792..2560, shared by both colours
    '00000001000','00000001100','00000001101','000000010010','000000010011','000000010100',
    '000000010101','000000010110','000000010111','000000011100','000000011101','000000011110','000000011111');

procedure AddCode(var T: TTable; const Bits: AnsiString; Run: Integer);
var
  v, i, L, start, cnt: Integer;
begin
  L := Length(Bits);
  v := 0;
  for i := 1 to L do v := (v shl 1) or Ord(Bits[i] = '1');
  start := v shl (13 - L);
  cnt := 1 shl (13 - L);
  for i := start to start + cnt - 1 do
  begin
    T[i].Run := Run;
    T[i].Len := L;
  end;
end;

procedure AddMode(const Bits: AnsiString; Mode: Integer);
var
  v, i, L, start, cnt: Integer;
begin
  L := Length(Bits);
  v := 0;
  for i := 1 to L do v := (v shl 1) or Ord(Bits[i] = '1');
  start := v shl (7 - L);
  cnt := 1 shl (7 - L);
  for i := start to start + cnt - 1 do
  begin
    ModeTab[i] := Mode;
    ModeLen[i] := L;
  end;
end;

procedure InitTables;
var
  i: Integer;
begin
  if TablesReady then Exit;
  for i := 0 to 8191 do
  begin
    WhiteTab[i].Run := -1; WhiteTab[i].Len := 0;
    BlackTab[i].Run := -1; BlackTab[i].Len := 0;
  end;
  for i := 0 to 63 do
  begin
    AddCode(WhiteTab, WhiteTerm[i], i);
    AddCode(BlackTab, BlackTerm[i], i);
  end;
  for i := 1 to 27 do
  begin
    AddCode(WhiteTab, WhiteMakeup[i], i * 64);
    AddCode(BlackTab, BlackMakeup[i], i * 64);
  end;
  for i := 0 to 12 do
  begin
    AddCode(WhiteTab, ExtMakeup[i], 1792 + i * 64);
    AddCode(BlackTab, ExtMakeup[i], 1792 + i * 64);
  end;

  for i := 0 to 127 do begin ModeTab[i] := M_ZERO; ModeLen[i] := 7; end;
  AddMode('1', M_V0);
  AddMode('011', M_VR1);
  AddMode('010', M_VL1);
  AddMode('001', M_H);
  AddMode('0001', M_P);
  AddMode('000011', M_VR2);
  AddMode('000010', M_VL2);
  AddMode('0000011', M_VR3);
  AddMode('0000010', M_VL3);
  AddMode('0000001', M_EXT);
  TablesReady := True;
end;

// ------------------------------- bit reader --------------------------------

type
  TBits = record
    D: TBytes;
    Pos: NativeUInt;       // bit position
    Total: NativeUInt;     // total bits
  end;

function Peek(var B: TBits; N: Integer): Cardinal; inline;
var
  bytePos: NativeUInt;
  v: Cardinal;
  i: Integer;
begin
  bytePos := B.Pos shr 3;
  v := 0;
  for i := 0 to 3 do
  begin
    v := v shl 8;
    if bytePos + NativeUInt(i) < NativeUInt(Length(B.D)) then v := v or B.D[bytePos + NativeUInt(i)];
  end;
  v := v shl (B.Pos and 7);
  Result := v shr (32 - N);
end;

procedure Skip(var B: TBits; N: Integer); inline;
begin
  Inc(B.Pos, N);
end;

function AtEnd(const B: TBits): Boolean; inline;
begin
  Result := B.Pos >= B.Total;
end;

procedure AlignByte(var B: TBits); inline;
begin
  B.Pos := (B.Pos + 7) and not NativeUInt(7);
end;

// If an EOL (>= 11 zero bits followed by a one) starts here, consume it.
function SkipEOL(var B: TBits): Boolean;
var
  p: NativeUInt;
  zeros: Integer;
begin
  Result := False;
  p := B.Pos;
  zeros := 0;
  while (B.Pos < B.Total) and (Peek(B, 1) = 0) do begin Skip(B, 1); Inc(zeros); end;
  if (zeros >= 11) and (B.Pos < B.Total) then
  begin
    Skip(B, 1);                 // the terminating 1
    Result := True;
  end
  else if (zeros >= 11) then
    Result := True              // zeros up to the end of data
  else
    B.Pos := p;                 // not an EOL: rewind
end;

// Scan forward to just past the next EOL.
function SyncToEOL(var B: TBits): Boolean;
var
  zeros: Integer;
begin
  zeros := 0;
  while B.Pos < B.Total do
  begin
    if Peek(B, 1) = 0 then Inc(zeros)
    else
    begin
      if zeros >= 11 then begin Skip(B, 1); Exit(True); end;
      zeros := 0;
    end;
    Skip(B, 1);
  end;
  Result := False;
end;

// Read one colour run (makeup codes + terminating code). -1 on error.
function ReadRun(var B: TBits; Black: Boolean): Integer;
var
  c: TCode;
  total: Integer;
begin
  total := 0;
  repeat
    if AtEnd(B) then Exit(-1);
    if Black then c := BlackTab[Peek(B, 13)] else c := WhiteTab[Peek(B, 13)];
    if c.Run < 0 then Exit(-1);
    Skip(B, c.Len);
    Inc(total, c.Run);
  until c.Run < 64;
  Result := total;
end;

// ------------------------------ line decoding ------------------------------

type
  TChanges = array of Integer;   // positions where the colour flips; line starts white

// 1D line into Cur (Count entries). Returns False on a coding error.
function Decode1D(var B: TBits; Width: Integer; var Cur: TChanges; out Count: Integer): Boolean;
var
  pos, run: Integer;
  black: Boolean;
begin
  Count := 0;
  pos := 0;
  black := False;
  while pos < Width do
  begin
    run := ReadRun(B, black);
    if run < 0 then Exit(False);
    Inc(pos, run);
    if pos > Width then pos := Width;
    if Count >= Length(Cur) - 2 then SetLength(Cur, Length(Cur) * 2 + 16);
    Cur[Count] := pos; Inc(Count);
    black := not black;
  end;
  // a line may end with a colour change exactly at Width: drop it
  while (Count > 0) and (Cur[Count - 1] >= Width) do Dec(Count);
  Result := True;
end;

// 2D line relative to Ref (RefCount entries).
function Decode2D(var B: TBits; Width: Integer; const Ref: TChanges; RefCount: Integer;
  var Cur: TChanges; out Count: Integer): Boolean;
var
  a0, a1, a2, b1, b2, ri, mode, idx, r1, r2: Integer;
  black: Boolean;

  procedure Put(P: Integer);
  begin
    if Count >= Length(Cur) - 2 then SetLength(Cur, Length(Cur) * 2 + 16);
    Cur[Count] := P; Inc(Count);
  end;

  function RefAt(I: Integer): Integer; inline;
  begin
    if I < RefCount then Result := Ref[I] else Result := Width;
  end;

begin
  Count := 0;
  a0 := -1;
  black := False;
  ri := 0;
  while a0 < Width do
  begin
    // b1: first changing element on the reference line right of a0 whose new
    // colour is the opposite of the current colour. Changes at even indices
    // turn black, odd indices turn white.
    while (RefAt(ri) <= a0) and (ri < RefCount) do Inc(ri);
    if black then begin if (ri and 1) = 0 then Inc(ri); end
    else begin if (ri and 1) = 1 then Inc(ri); end;
    while (RefAt(ri) <= a0) and (ri < RefCount) do Inc(ri, 2);
    b1 := RefAt(ri);
    b2 := RefAt(ri + 1);

    if AtEnd(B) then Exit(False);
    idx := Peek(B, 7);
    mode := ModeTab[idx];
    if (mode = M_EXT) or (mode = M_ZERO) then Exit(False);
    Skip(B, ModeLen[idx]);

    case mode of
      M_P:
        a0 := b2;                           // colour unchanged
      M_H:
        begin
          if a0 < 0 then a0 := 0;
          r1 := ReadRun(B, black);
          if r1 < 0 then Exit(False);
          r2 := ReadRun(B, not black);
          if r2 < 0 then Exit(False);
          a1 := a0 + r1; if a1 > Width then a1 := Width;
          a2 := a1 + r2; if a2 > Width then a2 := Width;
          Put(a1); Put(a2);
          a0 := a2;
        end;
    else
      begin
        case mode of
          M_V0:  a1 := b1;
          M_VR1: a1 := b1 + 1;
          M_VR2: a1 := b1 + 2;
          M_VR3: a1 := b1 + 3;
          M_VL1: a1 := b1 - 1;
          M_VL2: a1 := b1 - 2;
        else     a1 := b1 - 3;
        end;
        if a1 > Width then a1 := Width;
        if a1 < 0 then a1 := 0;
        Put(a1);
        a0 := a1;
        black := not black;
      end;
    end;
    // keep the search index sensible for the next element
    if ri > 0 then Dec(ri);
    while (ri > 0) and (RefAt(ri - 1) > a0) do Dec(ri);
  end;
  while (Count > 0) and (Cur[Count - 1] >= Width) do Dec(Count);
  Result := True;
end;

procedure FillRow(var Dst: TBytes; RowOff: NativeInt; Width: Integer; const Ch: TChanges; Count: Integer);
var
  i, x, stop: Integer;
  v: Byte;
begin
  x := 0; v := 0;
  for i := 0 to Count do
  begin
    if i < Count then stop := Ch[i] else stop := Width;
    if stop > Width then stop := Width;
    while x < stop do begin Dst[RowOff + x] := v; Inc(x); end;
    v := v xor 1;
  end;
end;

function ReverseBitsBuf(const Src: TBytes): TBytes;
var
  i, k: Integer;
  b, r: Byte;
begin
  Result := nil;
  SetLength(Result, Length(Src));
  for i := 0 to High(Src) do
  begin
    b := Src[i]; r := 0;
    for k := 0 to 7 do begin r := (r shl 1) or (b and 1); b := b shr 1; end;
    Result[i] := r;
  end;
end;

function CcittDecodeEx(const Src: TBytes; Width, Height: Integer; Kind: TCcittKind;
  T4TwoD, ReverseBits: Boolean; out Rows, ErrRows: Integer): TBytes;
var
  B: TBits;
  Ref, Cur, Tmp: TChanges;
  RefCount, CurCount, cap, y, eolRun: Integer;
  ok, twoD, tagSeen, tag1D: Boolean;
begin
  Result := nil;
  InitTables;
  Rows := 0; ErrRows := 0;
  if Width <= 0 then raise ECcittError.Create('CCITT: invalid width');
  if ReverseBits then B.D := ReverseBitsBuf(Src) else B.D := Src;
  B.Pos := 0;
  B.Total := NativeUInt(Length(B.D)) * 8;

  if Height > 0 then cap := Height else cap := 256;
  SetLength(Result, NativeInt(Width) * cap);
  FillChar(Result[0], Length(Result), 0);
  SetLength(Ref, 64); SetLength(Cur, 64);
  RefCount := 0;                                  // imaginary all-white line

  y := 0;
  eolRun := 0;
  while (Height < 0) or (y < Height) do
  begin
    if AtEnd(B) then Break;
    twoD := Kind = ckT6;
    if Kind = ckT4 then
    begin
      // Consume EOLs (with any fill bits); in 2D coding each EOL carries a tag
      // bit. Two or more EOLs in a row (RTC) end the page.
      tagSeen := False; tag1D := True;
      while SkipEOL(B) do
      begin
        Inc(eolRun);
        if T4TwoD and not AtEnd(B) then
        begin
          tagSeen := True;
          tag1D := Peek(B, 1) = 1;                // tag: 1 = 1D line, 0 = 2D line
          Skip(B, 1);
        end;
        if eolRun >= 2 then Break;
      end;
      if (eolRun >= 2) or AtEnd(B) then Break;
      if T4TwoD and tagSeen then twoD := not tag1D;
    end;

    if twoD then ok := Decode2D(B, Width, Ref, RefCount, Cur, CurCount)
    else ok := Decode1D(B, Width, Cur, CurCount);

    if (Height < 0) and (y >= cap) then
    begin
      cap := cap * 2;
      SetLength(Result, NativeInt(Width) * cap);
      FillChar(Result[NativeInt(Width) * y], NativeInt(Width) * (cap - y), 0);
    end;

    if ok then
    begin
      eolRun := 0;
      FillRow(Result, NativeInt(y) * Width, Width, Cur, CurCount);
      Tmp := Ref; Ref := Cur; Cur := Tmp;
      RefCount := CurCount;
    end
    else
    begin
      // coding error: keep what a 1D line decoded so far (rest white), or repeat
      // the previous row for 2D lines; then resynchronise on the next EOL
      Inc(ErrRows);
      if (not twoD) and (CurCount > 0) then
        FillRow(Result, NativeInt(y) * Width, Width, Cur, CurCount)
      else if y > 0 then
        Move(Result[NativeInt(y - 1) * Width], Result[NativeInt(y) * Width], Width);
      if (Kind <> ckT4) or not SyncToEOL(B) then begin Inc(y); Break; end;
      B.Pos := B.Pos - 12;                        // let the loop see that EOL again
      eolRun := 0;
    end;
    Inc(y);
    if Kind = ckMH then AlignByte(B);
  end;

  Rows := y;
  SetLength(Result, NativeInt(Width) * Rows);
end;

function CcittDecode(const Src: TBytes; Width, Height: Integer; Kind: TCcittKind;
  T4TwoD, ReverseBits: Boolean; out Rows: Integer): TBytes;
var
  Errs: Integer;
begin
  Result := CcittDecodeEx(Src, Width, Height, Kind, T4TwoD, ReverseBits, Rows, Errs);
end;

// ------------------------------ raw G3 files -------------------------------

function LooksLikeRawG3(const Src: TBytes): Boolean;
var
  B: TBits;
begin
  InitTables;
  B.D := Src; B.Pos := 0; B.Total := NativeUInt(Length(Src)) * 8;
  Result := (Length(Src) > 16) and SkipEOL(B);
end;

// Most frequent coded line width over the first lines (1D lines only; in 2D
// streams only the lines tagged as 1D are measured). 0 if nothing usable.
function ProbeWidth(const Src: TBytes; TwoD: Boolean): Integer;
var
  B: TBits;
  run, total, lines, i, j, bestCnt, cnt: Integer;
  black, ok: Boolean;
  save: NativeUInt;
  Seen: array[0..63] of Integer;
  NSeen: Integer;
begin
  InitTables;
  Result := 0;
  B.D := Src; B.Pos := 0; B.Total := NativeUInt(Length(Src)) * 8;
  NSeen := 0; lines := 0;
  while (lines < 64) and (NSeen < 64) and not AtEnd(B) do
  begin
    if not SkipEOL(B) then
      if not SyncToEOL(B) then Break;
    while SkipEOL(B) do ;
    if AtEnd(B) then Break;
    Inc(lines);
    if TwoD then
    begin
      if Peek(B, 1) = 0 then Continue;          // 2D-coded line: cannot measure
      Skip(B, 1);
    end;
    total := 0; black := False; ok := True;
    while total < 20000 do
    begin
      save := B.Pos;
      if SkipEOL(B) then begin B.Pos := save; Break; end;
      run := ReadRun(B, black);
      if run < 0 then begin ok := False; Break; end;
      Inc(total, run);
      black := not black;
    end;
    if ok and (total >= 16) then begin Seen[NSeen] := total; Inc(NSeen); end;
  end;
  bestCnt := 0;
  for i := 0 to NSeen - 1 do
  begin
    cnt := 0;
    for j := 0 to NSeen - 1 do if Seen[j] = Seen[i] then Inc(cnt);
    if cnt > bestCnt then begin bestCnt := cnt; Result := Seen[i]; end;
  end;
end;

function DecodeRawG3(const Src: TBytes; out Width, Height: Integer): TBytes;
const
  StdWidths: array[0..4] of Integer = (1728, 2048, 2432, 1216, 864);
var
  Widths: array[0..6] of Integer;
  NW, i, j, m, x, y, W, Rows, Errs, bestW, bestRows: Integer;
  TwoD, bestTwoD, dup, isStd: Boolean;
  pass: Integer;
  Bits, BestBits: TBytes;
  rate, bestRate: Int64;
  C: Byte;
begin
  Result := nil;
  Width := 0; Height := 0;
  if not LooksLikeRawG3(Src) then raise ECcittError.Create('G3: no EOL at start of stream');

  // candidate widths: measured (1D and 2D probes) plus the standard fax widths
  NW := 0;
  for m := 0 to 1 do
  begin
    W := ProbeWidth(Src, m = 1);
    if W >= 16 then begin Widths[NW] := W; Inc(NW); end;
  end;
  for i := 0 to High(StdWidths) do
  begin
    dup := False;
    for j := 0 to NW - 1 do if Widths[j] = StdWidths[i] then dup := True;
    if not dup then begin Widths[NW] := StdWidths[i]; Inc(NW); end;
    if NW > High(Widths) then Break;
  end;

  // Trial-decode every candidate. A standard fax width that decodes with at
  // most 25% damaged rows is preferred; otherwise the lowest error rate wins
  // (1D and earlier candidates win ties).
  bestRate := High(Int64); bestW := 0; bestRows := 0; bestTwoD := False;
  for pass := 0 to 1 do
  begin
    for m := 0 to 1 do
    begin
      TwoD := m = 1;
      for i := 0 to NW - 1 do
      begin
        isStd := False;
        for j := 0 to High(StdWidths) do if Widths[i] = StdWidths[j] then isStd := True;
        if (pass = 0) and not isStd then Continue;
        try
          Bits := CcittDecodeEx(Src, Widths[i], -1, ckT4, TwoD, False, Rows, Errs);
        except
          Continue;
        end;
        if Rows <= 0 then Continue;
        rate := (Int64(Errs) * 100000) div Rows;
        if (pass = 0) and (rate > 25000) then Continue;
        if rate < bestRate then
        begin
          bestRate := rate; bestW := Widths[i]; bestRows := Rows; bestTwoD := TwoD;
          BestBits := Bits;
        end;
      end;
    end;
    if bestW > 0 then Break;          // a standard width qualified
  end;
  if (bestW = 0) or (bestRate >= 50000) then
    raise ECcittError.Create('G3: stream could not be decoded');

  W := bestW; Rows := bestRows;
  Width := W; Height := Rows;
  SetLength(Result, NativeInt(W) * Rows * 4);
  for y := 0 to Rows - 1 do
    for x := 0 to W - 1 do
    begin
      if BestBits[NativeInt(y) * W + x] = 0 then C := 255 else C := 0;
      Result[(NativeInt(y) * W + x) * 4 + 0] := C;
      Result[(NativeInt(y) * W + x) * 4 + 1] := C;
      Result[(NativeInt(y) * W + x) * 4 + 2] := C;
      Result[(NativeInt(y) * W + x) * 4 + 3] := 255;
    end;
  if bestTwoD then ;   // mode is informational only
end;

end.
