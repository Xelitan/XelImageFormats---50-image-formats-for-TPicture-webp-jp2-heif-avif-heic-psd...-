unit XelRaw;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Camera RAW (TIFF/EP + DNG)                                    //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, Math, XelPng;

type
  ERawError = class(Exception);

// Returns a human-readable dump of the raw IFD tags this decoder picked - used
// during development to verify tag extraction against real files.
function ProbeRaw(InBuf: TBytes): string;
function ProbeAll(InBuf: TBytes): string;

// Full develop of the CFA raw to RGBA8.
function DecodeRaw(InBuf: TBytes; out Width, Height: Integer): TBytes;

implementation

type
  TIFDInfo = record
    ImageWidth, ImageLength: Cardinal;
    BitsPerSample, Compression, Photometric, SamplesPerPixel: Cardinal;
    RowsPerStrip: Cardinal;
    NewSubfileType: Cardinal;
    StripOffsets, StripByteCounts: array of Cardinal;
    TileWidth, TileLength: Cardinal;
    TileOffsets, TileByteCounts: array of Cardinal;
    CFARepeatRows, CFARepeatCols: Cardinal;
    CFAPattern: array of Byte;             // 0=R 1=G 2=B
    BlackLevel: array of Double;
    WhiteLevel: Cardinal;
    AsShotNeutral: array of Double;
    ColorMatrix: array of Double;          // XYZ->cam, 3x3 (row major)
    HasColorMatrix, HasAsShot, IsCFA, IsLinearRaw: Boolean;
    ActiveTop, ActiveLeft, ActiveBottom, ActiveRight: Cardinal;
    HasActive: Boolean;
    IFDOffset: Cardinal;
  end;

var
  gBE: Boolean;

function RU16(const D: TBytes; P: NativeUInt): Word; inline;
begin
  if gBE then Result := (Word(D[P]) shl 8) or Word(D[P + 1])
  else Result := Word(D[P]) or (Word(D[P + 1]) shl 8);
end;

function RU32(const D: TBytes; P: NativeUInt): Cardinal; inline;
begin
  if gBE then
    Result := (Cardinal(D[P]) shl 24) or (Cardinal(D[P + 1]) shl 16) or
              (Cardinal(D[P + 2]) shl 8) or Cardinal(D[P + 3])
  else
    Result := Cardinal(D[P]) or (Cardinal(D[P + 1]) shl 8) or
              (Cardinal(D[P + 2]) shl 16) or (Cardinal(D[P + 3]) shl 24);
end;

const
  TypeSize: array[1..12] of Byte = (1,1,2,4,8,1,1,2,4,8,4,8);

function ValueOffset(const D: TBytes; Entry: NativeUInt; Cnt, Typ: Cardinal): NativeUInt;
var Total: Cardinal;
begin
  if (Typ >= 1) and (Typ <= 12) then Total := Cnt * TypeSize[Typ] else Total := Cnt;
  if Total <= 4 then Result := Entry + 8
  else Result := RU32(D, Entry + 8);
end;

// Reads an unsigned integer tag value (SHORT/LONG) at index Idx.
function ReadUInt(const D: TBytes; VOfs: NativeUInt; Typ: Cardinal; Idx: Cardinal): Cardinal;
begin
  case Typ of
    3: Result := RU16(D, VOfs + Idx * 2);
    4: Result := RU32(D, VOfs + Idx * 4);
    1: Result := D[VOfs + Idx];
  else
    Result := RU16(D, VOfs + Idx * 2);
  end;
end;

// Reads an unsigned RATIONAL (type 5) as Double.
function ReadRational(const D: TBytes; VOfs: NativeUInt; Idx: Cardinal): Double;
var num, den: Cardinal;
begin
  num := RU32(D, VOfs + Idx * 8);
  den := RU32(D, VOfs + Idx * 8 + 4);
  if den = 0 then Result := 0 else Result := num / den;
end;

// Reads a signed SRATIONAL (type 10) as Double.
function ReadSRational(const D: TBytes; VOfs: NativeUInt; Idx: Cardinal): Double;
var num, den: LongInt;
begin
  num := LongInt(RU32(D, VOfs + Idx * 8));
  den := LongInt(RU32(D, VOfs + Idx * 8 + 4));
  if den = 0 then Result := 0 else Result := num / den;
end;

procedure ParseIFD(const D: TBytes; IFD: NativeUInt; var Info: TIFDInfo;
  var SubIFDs: array of Cardinal; var NumSub: Integer; out NextIFD: Cardinal);
var
  N, I, K: Integer;
  Entry, VOfs: NativeUInt;
  Tag, Typ: Word;
  Cnt: Cardinal;
begin
  FillChar(Info, SizeOf(Info), 0);
  Info.SamplesPerPixel := 1;
  Info.IFDOffset := IFD;
  NextIFD := 0;
  if IFD + 2 > NativeUInt(Length(D)) then Exit;
  N := RU16(D, IFD);
  for I := 0 to N - 1 do
  begin
    Entry := IFD + 2 + NativeUInt(I) * 12;
    if Entry + 12 > NativeUInt(Length(D)) then Break;
    Tag := RU16(D, Entry);
    Typ := RU16(D, Entry + 2);
    Cnt := RU32(D, Entry + 4);
    VOfs := ValueOffset(D, Entry, Cnt, Typ);
    case Tag of
      254: Info.NewSubfileType := ReadUInt(D, VOfs, Typ, 0);
      256: Info.ImageWidth := ReadUInt(D, VOfs, Typ, 0);
      257: Info.ImageLength := ReadUInt(D, VOfs, Typ, 0);
      258: Info.BitsPerSample := ReadUInt(D, VOfs, Typ, 0);
      259: Info.Compression := ReadUInt(D, VOfs, Typ, 0);
      262: begin Info.Photometric := ReadUInt(D, VOfs, Typ, 0);
                 Info.IsCFA := Info.Photometric = 32803;
                 Info.IsLinearRaw := Info.Photometric = 34892; end;
      277: Info.SamplesPerPixel := ReadUInt(D, VOfs, Typ, 0);
      278: Info.RowsPerStrip := ReadUInt(D, VOfs, Typ, 0);
      273: begin SetLength(Info.StripOffsets, Cnt);
                 for K := 0 to Integer(Cnt) - 1 do Info.StripOffsets[K] := ReadUInt(D, VOfs, Typ, K); end;
      279: begin SetLength(Info.StripByteCounts, Cnt);
                 for K := 0 to Integer(Cnt) - 1 do Info.StripByteCounts[K] := ReadUInt(D, VOfs, Typ, K); end;
      322: Info.TileWidth := ReadUInt(D, VOfs, Typ, 0);
      323: Info.TileLength := ReadUInt(D, VOfs, Typ, 0);
      324: begin SetLength(Info.TileOffsets, Cnt);
                 for K := 0 to Integer(Cnt) - 1 do Info.TileOffsets[K] := ReadUInt(D, VOfs, Typ, K); end;
      325: begin SetLength(Info.TileByteCounts, Cnt);
                 for K := 0 to Integer(Cnt) - 1 do Info.TileByteCounts[K] := ReadUInt(D, VOfs, Typ, K); end;
      330: begin NumSub := Min(Length(SubIFDs), Integer(Cnt));
                 for K := 0 to NumSub - 1 do SubIFDs[K] := ReadUInt(D, VOfs, Typ, K); end;
      33421: begin Info.CFARepeatRows := ReadUInt(D, VOfs, Typ, 0);
                   Info.CFARepeatCols := ReadUInt(D, VOfs, Typ, 1); end;
      33422: begin SetLength(Info.CFAPattern, Cnt);
                   for K := 0 to Integer(Cnt) - 1 do Info.CFAPattern[K] := D[VOfs + NativeUInt(K)]; end;
      50714: begin SetLength(Info.BlackLevel, Cnt);
                   for K := 0 to Integer(Cnt) - 1 do
                     if Typ = 5 then Info.BlackLevel[K] := ReadRational(D, VOfs, K)
                     else Info.BlackLevel[K] := ReadUInt(D, VOfs, Typ, K); end;
      50717: Info.WhiteLevel := ReadUInt(D, VOfs, Typ, 0);
      50728: begin SetLength(Info.AsShotNeutral, Cnt); Info.HasAsShot := Cnt >= 3;
                   for K := 0 to Integer(Cnt) - 1 do
                     if Typ = 5 then Info.AsShotNeutral[K] := ReadRational(D, VOfs, K)
                     else Info.AsShotNeutral[K] := ReadUInt(D, VOfs, Typ, K); end;
      50721, 50722: begin        // ColorMatrix1 / ColorMatrix2 (SRATIONAL, prefer last seen)
                   SetLength(Info.ColorMatrix, Cnt); Info.HasColorMatrix := Cnt >= 9;
                   for K := 0 to Integer(Cnt) - 1 do Info.ColorMatrix[K] := ReadSRational(D, VOfs, K); end;
      50829: if Cnt >= 4 then
             begin
               Info.ActiveTop := ReadUInt(D, VOfs, Typ, 0);
               Info.ActiveLeft := ReadUInt(D, VOfs, Typ, 1);
               Info.ActiveBottom := ReadUInt(D, VOfs, Typ, 2);
               Info.ActiveRight := ReadUInt(D, VOfs, Typ, 3);
               Info.HasActive := True;
             end;
    end;
  end;
  NextIFD := RU32(D, IFD + 2 + NativeUInt(N) * 12);
end;

// Walks IFD0, its SubIFDs and the IFD chain; returns the largest CFA image and
// merges the colour metadata (ColorMatrix / AsShotNeutral usually live in IFD0,
// the CFA geometry in a SubIFD).
function FindRawIFD(const D: TBytes; out Info: TIFDInfo): Boolean;
var
  Info0, Cur, Best: TIFDInfo;
  Subs, Subs2: array[0..31] of Cardinal;
  NumSub, NumSub2, Guard: Integer;
  Next, IFD0: Cardinal;
  I: Integer;
  BestArea: UInt64;

  procedure Consider(const C: TIFDInfo);
  var A: UInt64; cand: Boolean;
  begin
    // a CFA raw is either explicitly tagged (Photometric 32803) or a large,
    // single-sample, deep, un-tiled-preview plane (e.g. Olympus stores its raw
    // in IFD0 as Photometric=1)
    cand := C.IsCFA or C.IsLinearRaw or
            ((C.SamplesPerPixel = 1) and (C.BitsPerSample >= 12) and
             (C.ImageWidth >= 1000) and (C.ImageLength >= 1000) and
             ((C.Compression = 1) or (C.Compression = 7)));
    if cand and (C.ImageWidth > 0) and (C.ImageLength > 0) then
    begin
      A := UInt64(C.ImageWidth) * UInt64(C.ImageLength);
      if A > BestArea then begin BestArea := A; Best := C; end;
    end;
  end;

begin
  Result := False; BestArea := 0;
  FillChar(Best, SizeOf(Best), 0);
  IFD0 := RU32(D, 4);

  NumSub := 0;
  ParseIFD(D, IFD0, Info0, Subs, NumSub, Next);
  Consider(Info0);
  for I := 0 to NumSub - 1 do
  begin
    NumSub2 := 0;
    ParseIFD(D, Subs[I], Cur, Subs2, NumSub2, IFD0);
    Consider(Cur);
  end;

  // follow the IFD chain (IFD1, ...) and their sub-IFDs too
  Guard := 0;
  while (Next <> 0) and (Next < Cardinal(Length(D))) and (Guard < 32) do
  begin
    NumSub2 := 0;
    ParseIFD(D, Next, Cur, Subs2, NumSub2, Next);
    Consider(Cur);
    for I := 0 to NumSub2 - 1 do
    begin
      NumSub := 0;
      ParseIFD(D, Subs2[I], Cur, Subs, NumSub, IFD0);
      Consider(Cur);
    end;
    Inc(Guard);
  end;

  if BestArea = 0 then Exit;

  // merge colour metadata from IFD0 when the CFA IFD lacks it
  if (not Best.HasColorMatrix) and Info0.HasColorMatrix then
  begin Best.ColorMatrix := Info0.ColorMatrix; Best.HasColorMatrix := True; end;
  if (not Best.HasAsShot) and Info0.HasAsShot then
  begin Best.AsShotNeutral := Info0.AsShotNeutral; Best.HasAsShot := True; end;
  if (Length(Best.BlackLevel) = 0) and (Length(Info0.BlackLevel) > 0) then
    Best.BlackLevel := Info0.BlackLevel;
  if (Best.WhiteLevel = 0) and (Info0.WhiteLevel > 0) then
    Best.WhiteLevel := Info0.WhiteLevel;

  Info := Best; Result := True;
end;

// Lists every top-level IFD and its SubIFDs (diagnostic for non-DNG layouts).
function ProbeAll(InBuf: TBytes): string;
var
  Cur: TIFDInfo;
  Subs: array[0..31] of Cardinal;
  Subs2: array[0..31] of Cardinal;
  NumSub, NumSub2, Guard, I: Integer;
  Next, Dummy: Cardinal;

  function Line(const C: TIFDInfo; const Tag: string): string;
  begin
    Line := Format('%s @%d: %dx%d comp=%d photo=%d spp=%d bps=%d strips=%d(bytes0=%d) tiles=%d'#10,
      [Tag, C.IFDOffset, C.ImageWidth, C.ImageLength, C.Compression, C.Photometric,
       C.SamplesPerPixel, C.BitsPerSample, Length(C.StripOffsets),
       IfThen(Length(C.StripByteCounts) > 0, Integer(C.StripByteCounts[0]), 0),
       Length(C.TileOffsets)]);
  end;

begin
  Result := '';
  if Length(InBuf) < 8 then Exit;
  if not (((InBuf[0] = Ord('I')) and (InBuf[1] = Ord('I'))) or
          ((InBuf[0] = Ord('M')) and (InBuf[1] = Ord('M')))) then
    begin Result := 'not a TIFF-based raw'; Exit; end;
  gBE := (InBuf[0] = Ord('M'));
  Next := RU32(InBuf, 4);
  Guard := 0;
  while (Next <> 0) and (Next < Cardinal(Length(InBuf))) and (Guard < 32) do
  begin
    NumSub := 0;
    ParseIFD(InBuf, Next, Cur, Subs, NumSub, Next);
    Result := Result + Line(Cur, 'IFD');
    for I := 0 to NumSub - 1 do
    begin
      NumSub2 := 0;
      ParseIFD(InBuf, Subs[I], Cur, Subs2, NumSub2, Dummy);
      Result := Result + Line(Cur, '  SubIFD');
    end;
    Inc(Guard);
  end;
end;

function ProbeRaw(InBuf: TBytes): string;
var Info: TIFDInfo; I: Integer; s: string;
begin
  Result := '';
  if Length(InBuf) < 8 then Exit;
  gBE := (InBuf[0] = Ord('M'));
  if not FindRawIFD(InBuf, Info) then begin Result := 'no CFA IFD found'; Exit; end;
  Result := Format('CFA %dx%d bps=%d comp=%d photo=%d spp=%d'#10,
    [Info.ImageWidth, Info.ImageLength, Info.BitsPerSample, Info.Compression,
     Info.Photometric, Info.SamplesPerPixel]);
  s := ''; for I := 0 to Length(Info.CFAPattern) - 1 do s := s + IntToStr(Info.CFAPattern[I]) + ' ';
  Result := Result + Format('CFArepeat=%dx%d pattern=[%s] white=%d'#10,
    [Info.CFARepeatCols, Info.CFARepeatRows, s, Info.WhiteLevel]);
  s := ''; for I := 0 to Length(Info.BlackLevel) - 1 do s := s + Format('%.1f ', [Info.BlackLevel[I]]);
  Result := Result + 'black=[' + s + ']'#10;
  s := ''; for I := 0 to Length(Info.AsShotNeutral) - 1 do s := s + Format('%.4f ', [Info.AsShotNeutral[I]]);
  Result := Result + 'asShotNeutral=[' + s + ']'#10;
  s := ''; for I := 0 to Length(Info.ColorMatrix) - 1 do s := s + Format('%.4f ', [Info.ColorMatrix[I]]);
  Result := Result + 'colorMatrix=[' + s + ']'#10;
  Result := Result + Format('strips=%d tiles=%d tileW=%d tileL=%d active=%d,%d,%d,%d'#10,
    [Length(Info.StripOffsets), Length(Info.TileOffsets), Info.TileWidth, Info.TileLength,
     Info.ActiveTop, Info.ActiveLeft, Info.ActiveBottom, Info.ActiveRight]);
end;

// ========================= lossless JPEG (SOF3) =========================

type
  TWordArr = array of Word;
  THuff = record
    Counts: array[0..16] of Integer;      // number of codes of each length 1..16
    Vals: array[0..255] of Byte;
    MinCode: array[0..16] of Integer;
    MaxCode: array[0..16] of Integer;     // -1 if no codes of that length
    ValPtr: array[0..16] of Integer;
    Valid: Boolean;
  end;
  TBitR = record
    D: PByte; Size, Pos: NativeInt;
    CurByte, Cnt: Integer;
    EOFB: Boolean;
  end;

procedure BuildHuff(var H: THuff);
var l, i, code, k, p0: Integer;
begin
  code := 0; k := 0;
  for l := 1 to 16 do
  begin
    if H.Counts[l] = 0 then begin H.MaxCode[l] := -1; H.MinCode[l] := 0; H.ValPtr[l] := 0; end
    else
    begin
      H.ValPtr[l] := k;
      H.MinCode[l] := code;
      H.MaxCode[l] := code + H.Counts[l] - 1;
      Inc(k, H.Counts[l]);
      Inc(code, H.Counts[l]);
    end;
    code := code shl 1;
  end;
  H.Valid := True;
  p0 := 0; // silence hint
  if p0 <> 0 then Exit;
end;

// next raw byte of the entropy stream, unstuffing 0xFF00 and stopping at a marker
function JNextByte(var br: TBitR): Integer;
var b, b2: Integer;
begin
  if br.EOFB or (br.Pos >= br.Size) then begin Result := 0; br.EOFB := True; Exit; end;
  b := br.D[br.Pos]; Inc(br.Pos);
  if b = $FF then
  begin
    if br.Pos < br.Size then
    begin
      b2 := br.D[br.Pos];
      if b2 = 0 then Inc(br.Pos)             // stuffed literal 0xFF
      else begin br.EOFB := True; Result := 0; Exit; end;   // marker
    end
    else begin br.EOFB := True; Result := 0; Exit; end;
  end;
  Result := b;
end;

function JGetBit(var br: TBitR): Integer;
begin
  if br.Cnt = 0 then begin br.CurByte := JNextByte(br); br.Cnt := 8; end;
  Dec(br.Cnt);
  Result := (br.CurByte shr br.Cnt) and 1;
end;

function JGetBits(var br: TBitR; n: Integer): Integer;
var i: Integer;
begin
  Result := 0;
  for i := 1 to n do Result := (Result shl 1) or JGetBit(br);
end;

function JDecodeHuff(var br: TBitR; const H: THuff): Integer;
var code, l: Integer;
begin
  code := JGetBit(br); l := 1;
  while (l <= 16) and ((H.MaxCode[l] < 0) or (code > H.MaxCode[l])) do
  begin
    code := (code shl 1) or JGetBit(br);
    Inc(l);
    if l > 16 then begin Result := 0; Exit; end;
  end;
  Result := H.Vals[H.ValPtr[l] + (code - H.MinCode[l])];
end;

function JExtend(v, n: Integer): Integer; inline;
begin
  if n = 0 then Result := 0
  else if v < (1 shl (n - 1)) then Result := v - (1 shl n) + 1
  else Result := v;
end;

function RB16(const D: TBytes; P: NativeUInt): Integer; inline;
begin Result := (Integer(D[P]) shl 8) or Integer(D[P + 1]); end;

// Decodes one lossless-JPEG stream to interleaved samples (row length = Wide*Clrs).
function LJpegDecode(const D: TBytes; Ofs, Len: NativeUInt;
  out Samples: TWordArr; out Wide, High, Clrs, Prec: Integer): Boolean;
var
  Huff: array[0..3] of THuff;
  br: TBitR;
  P, JH, JW, Nf, Ns, Pred, Pt: Integer;
  TdOf: array[0..3] of Integer;
  p2, mp, mlen: NativeUInt;
  marker, i, r, x, c, s, diff, prv: Integer;
  RowLen, cnt, th, li: Integer;
  Ra, Rb, Rc, pv: Integer;
begin
  Result := False;
  Samples := nil; Wide := 0; High := 0; Clrs := 0; Prec := 0;
  FillChar(Huff, SizeOf(Huff), 0);
  P := 0; JH := 0; JW := 0; Nf := 0; Ns := 0; Pred := 1; Pt := 0;
  for i := 0 to 3 do TdOf[i] := 0;

  p2 := Ofs;
  mp := Ofs + Len;
  if (p2 + 2 > mp) or (D[p2] <> $FF) or (D[p2 + 1] <> $D8) then Exit;   // SOI
  Inc(p2, 2);

  while p2 + 4 <= mp do
  begin
    if D[p2] <> $FF then begin Inc(p2); Continue; end;
    marker := D[p2 + 1]; Inc(p2, 2);
    if marker = $D9 then Break;                        // EOI
    if (marker = $01) or ((marker >= $D0) and (marker <= $D7)) then Continue;
    mlen := RB16(D, p2);
    if mlen < 2 then Break;
    case marker of
      $C3:                                             // SOF3 lossless
        begin
          P := D[p2 + 2];
          JH := RB16(D, p2 + 3);
          JW := RB16(D, p2 + 5);
          Nf := D[p2 + 7];
          if Nf > 4 then Nf := 4;
        end;
      $C4:                                             // DHT
        begin
          li := Integer(p2 + 2); cnt := Integer(p2 + mlen);
          while li < cnt do
          begin
            th := D[li] and 3; Inc(li);
            s := 0;
            for i := 1 to 16 do begin Huff[th].Counts[i] := D[li + i - 1]; Inc(s, D[li + i - 1]); end;
            Inc(li, 16);
            for i := 0 to s - 1 do Huff[th].Vals[i] := D[li + i];
            Inc(li, s);
            BuildHuff(Huff[th]);
          end;
        end;
      $DA:                                             // SOS - decode
        begin
          Ns := D[p2 + 2];
          for i := 0 to Ns - 1 do
            TdOf[i] := (D[p2 + 3 + i * 2 + 1] shr 4) and 3;   // Td selector
          Pred := D[p2 + 3 + Ns * 2];
          Pt := D[p2 + 3 + Ns * 2 + 2] and 15;
          br.D := @D[p2 + mlen]; br.Size := NativeInt(mp - (p2 + mlen));
          br.Pos := 0; br.CurByte := 0; br.Cnt := 0; br.EOFB := False;

          if (JW <= 0) or (JH <= 0) or (Nf <= 0) then Exit;
          Clrs := Nf; Wide := JW; High := JH; Prec := P;
          RowLen := JW * Nf;
          SetLength(Samples, NativeInt(JH) * RowLen);

          for r := 0 to JH - 1 do
            for x := 0 to JW - 1 do
              for c := 0 to Nf - 1 do
              begin
                s := JDecodeHuff(br, Huff[TdOf[c]]);
                if s = 16 then diff := 1 shl P
                else diff := JExtend(JGetBits(br, s), s);
                if x = 0 then
                begin
                  if r = 0 then pv := 1 shl (P - 1)
                  else pv := Samples[(r - 1) * RowLen + 0 * Nf + c];   // Rb
                end
                else
                begin
                  Ra := Samples[r * RowLen + (x - 1) * Nf + c];
                  if r = 0 then pv := Ra
                  else
                  begin
                    Rb := Samples[(r - 1) * RowLen + x * Nf + c];
                    Rc := Samples[(r - 1) * RowLen + (x - 1) * Nf + c];
                    case Pred of
                      1: pv := Ra;
                      2: pv := Rb;
                      3: pv := Rc;
                      4: pv := Ra + Rb - Rc;
                      5: pv := Ra + ((Rb - Rc) div 2);
                      6: pv := Rb + ((Ra - Rc) div 2);
                      7: pv := (Ra + Rb) div 2;
                    else pv := Ra;
                    end;
                  end;
                end;
                prv := (pv + diff) and ((1 shl P) - 1);
                Samples[r * RowLen + x * Nf + c] := Word(prv);
              end;
          Result := True;
          Exit;
        end;
    end;
    Inc(p2, mlen);
  end;
end;

// =============================== develop ===============================

function Inv3(const m: array of Double; var inv: array of Double): Boolean;
var det: Double;
begin
  det := m[0]*(m[4]*m[8]-m[5]*m[7]) - m[1]*(m[3]*m[8]-m[5]*m[6]) + m[2]*(m[3]*m[7]-m[4]*m[6]);
  if Abs(det) < 1e-12 then Exit(False);
  inv[0]:=(m[4]*m[8]-m[5]*m[7])/det; inv[1]:=(m[2]*m[7]-m[1]*m[8])/det; inv[2]:=(m[1]*m[5]-m[2]*m[4])/det;
  inv[3]:=(m[5]*m[6]-m[3]*m[8])/det; inv[4]:=(m[0]*m[8]-m[2]*m[6])/det; inv[5]:=(m[2]*m[3]-m[0]*m[5])/det;
  inv[6]:=(m[3]*m[7]-m[4]*m[6])/det; inv[7]:=(m[1]*m[6]-m[0]*m[7])/det; inv[8]:=(m[0]*m[4]-m[1]*m[3])/det;
  Result := True;
end;

function SRGBGamma(c: Double): Byte; inline;
begin
  if c <= 0 then Result := 0
  else if c >= 1 then Result := 255
  else if c <= 0.0031308 then Result := Byte(Round(c * 12.92 * 255))
  else Result := Byte(Round((1.055 * Power(c, 1/2.4) - 0.055) * 255));
end;

// ==================== Olympus ORF lossless codec =======================
// Olympus stores "uncompressed" (Compression=1) ORF raw with a predictive
// variable-length code: a per-parity carry drives an adaptive bit count, a
// 12-bit look-ahead Huffman symbol supplies the high bits, and a median-style
// 2-D predictor reconstructs each 12-bit CFA sample. Independent Pascal
// implementation of the scheme dcraw calls olympus_load_raw.

type
  TOBits = record
    D: PByte; Size, Pos: NativeInt;
    Buf: UInt64; VBits: Integer;
  end;

procedure OBFill(var b: TOBits; Need: Integer); inline;
var by: Cardinal;
begin
  while b.VBits < Need do
  begin
    if b.Pos < b.Size then begin by := b.D[b.Pos]; Inc(b.Pos); end else by := 0;
    b.Buf := (b.Buf shl 8) or UInt64(by);
    Inc(b.VBits, 8);
  end;
end;

function OGetBits(var b: TOBits; n: Integer): Cardinal;
begin
  if n <= 0 then begin Result := 0; Exit; end;
  OBFill(b, n);
  Result := Cardinal((b.Buf shr (b.VBits - n)) and ((UInt64(1) shl n) - 1));
  Dec(b.VBits, n);
end;

function OAsr(v, n: Integer): Integer; inline;   // arithmetic shift right
begin
  if v >= 0 then Result := v shr n
  else Result := -(((-v) + (1 shl n) - 1) shr n);
end;

function OlympusDecode(const D: TBytes; DataOfs, DataLen: NativeUInt;
  W, H, RawW, CFAw: Integer; var cfa: TWordArr): Boolean;
var
  Huff: array[0..4095] of Word;
  b: TOBits;
  n, i, cc, row, col, ci: Integer;
  nbits, s3, sign, low, high, pred, diff, val: Integer;
  w2, n2, nw, code: Integer;
  carry0, carry1, carry2: array[0..1] of Integer;
begin
  Result := False;
  if DataLen < 16 then Exit;
  Huff[0] := (12 shl 8) or 12;
  n := 0;
  for i := 11 downto 0 do
    for cc := 0 to (2048 shr i) - 1 do
    begin Inc(n); Huff[n] := ((i + 1) shl 8) or i; end;

  b.D := @D[DataOfs + 7]; b.Size := NativeInt(DataLen) - 7;   // skip 7-byte header
  b.Pos := 0; b.Buf := 0; b.VBits := 0;

  for row := 0 to H - 1 do
  begin
    carry0[0] := 0; carry0[1] := 0; carry1[0] := 0; carry1[1] := 0;
    carry2[0] := 0; carry2[1] := 0;
    for col := 0 to RawW - 1 do
    begin
      ci := col and 1;
      i := 2 * Ord(carry2[ci] < 3);
      nbits := 2 + i;
      while (Word(carry0[ci]) shr (nbits + i)) <> 0 do Inc(nbits);
      s3 := Integer(OGetBits(b, 3));
      low := s3 and 3;
      if (s3 and 4) <> 0 then sign := -1 else sign := 0;
      OBFill(b, 12);
      code := Huff[(b.Buf shr (b.VBits - 12)) and $FFF];
      Dec(b.VBits, code shr 8);
      high := code and $FF;
      if high = 12 then high := Integer(OGetBits(b, 16 - nbits)) shr 1;
      carry0[ci] := (high shl nbits) or Integer(OGetBits(b, nbits));
      diff := (carry0[ci] xor sign) + carry1[ci];
      carry1[ci] := OAsr(diff * 3 + carry1[ci], 5);
      if carry0[ci] > 16 then carry2[ci] := 0 else carry2[ci] := carry2[ci] + 1;
      if col >= W then Continue;
      if (row < 2) and (col < 2) then pred := 0
      else if row < 2 then pred := cfa[row * CFAw + (col - 2)]
      else if col < 2 then pred := cfa[(row - 2) * CFAw + col]
      else
      begin
        w2 := cfa[row * CFAw + (col - 2)];
        n2 := cfa[(row - 2) * CFAw + col];
        nw := cfa[(row - 2) * CFAw + (col - 2)];
        if ((w2 < nw) and (nw < n2)) or ((n2 < nw) and (nw < w2)) then
        begin
          if (Abs(w2 - nw) > 32) or (Abs(n2 - nw) > 32) then pred := w2 + n2 - nw
          else pred := (w2 + n2) shr 1;
        end
        else if Abs(w2 - nw) > Abs(n2 - nw) then pred := w2
        else pred := n2;
      end;
      val := pred + ((diff shl 2) or low);
      if val < 0 then val := 0;
      cfa[row * CFAw + col] := Word(val and $FFFF);
    end;
  end;
  Result := True;
end;

function DecodeRaw(InBuf: TBytes; out Width, Height: Integer): TBytes;
const
  XYZ_RGB: array[0..8] of Double = (      // sRGB(D65) -> XYZ
    0.4124564, 0.3575761, 0.1804375,
    0.2126729, 0.7151522, 0.0721750,
    0.0193339, 0.1191920, 0.9503041);
var
  Info: TIFDInfo;
  cfa: TWordArr;
  CFAw, CFAh, RR, RC: Integer;
  Pattern: array[0..3] of Byte;
  BlackArr: array[0..3] of Double;
  White: Double;
  wb: array[0..2] of Double;
  camrgb, rgbcam: array[0..8] of Double;
  premul: array[0..2] of Double;
  aTop, aLeft, aBottom, aRight, OutW, OutH: Integer;
  x, y, c, k, tilesAcross, t: Integer;
  Samples: TWordArr;
  jwide, jhigh, clrs, prec: Integer;
  tileCol, tileRow, ty, tx, outRow, outCol: Integer;
  camR, camG, camB, rr2, gg, bb, sum: Double;
  Col: TRGBA;
  di, di2: NativeInt;
  ExpScale, vg, expScaleTmp: Double;
  hist: array[0..1023] of Integer;
  total, acc, bin, thr, maxc: Integer;
  sbc: NativeUInt;
  cfacol, v: Integer;
  k2: NativeInt;
  sumR, sumG, sumB, avgR, avgG, avgB: Double;
  cntR, cntG, cntB: Integer;

  function ColorAt(px, py: Integer): Integer; inline;
  begin
    Result := Pattern[(py mod RR) * RC + (px mod RC)];
  end;

  function GetLin(px, py: Integer): Double; inline;
  var raw: Integer; cc: Integer; b, wmb: Double;
  begin
    if px < 0 then px := 0 else if px >= CFAw then px := CFAw - 1;
    if py < 0 then py := 0 else if py >= CFAh then py := CFAh - 1;
    cc := ColorAt(px, py);
    raw := cfa[py * CFAw + px];
    b := BlackArr[(py mod RR) * RC + (px mod RC)];
    wmb := White - b; if wmb <= 0 then wmb := 1;
    Result := (raw - b) / wmb;
    if Result < 0 then Result := 0;
    Result := Result * wb[cc];
  end;

  // camera R,G,B at (px,py) by averaging same-colour neighbours in the 3x3
  procedure Demosaic(px, py: Integer; out cr, cg, cb: Double);
  var dx, dy, col, nR, nG, nB: Integer; sR, sG, sB, v: Double;
  begin
    sR := 0; sG := 0; sB := 0; nR := 0; nG := 0; nB := 0;
    for dy := -1 to 1 do
      for dx := -1 to 1 do
      begin
        if (px + dx < 0) or (px + dx >= CFAw) or (py + dy < 0) or (py + dy >= CFAh) then Continue;
        col := ColorAt(px + dx, py + dy);
        v := GetLin(px + dx, py + dy);
        case col of
          0: begin sR := sR + v; Inc(nR); end;
          1: begin sG := sG + v; Inc(nG); end;
          2: begin sB := sB + v; Inc(nB); end;
        end;
      end;
    if nR > 0 then cr := sR / nR else cr := 0;
    if nG > 0 then cg := sG / nG else cg := 0;
    if nB > 0 then cb := sB / nB else cb := 0;
  end;

begin
  Width := 0; Height := 0; SetLength(Result, 0);
  if Length(InBuf) < 16 then raise ERawError.Create('RAW: too small');
  if not (((InBuf[0] = Ord('I')) and (InBuf[1] = Ord('I'))) or
          ((InBuf[0] = Ord('M')) and (InBuf[1] = Ord('M')))) then
    raise ERawError.Create('RAW: not a TIFF/EP-based raw - this container ' +
      '(e.g. Foveon X3F, Fuji RAF, Canon CRW/CR3) is not supported');
  gBE := (InBuf[0] = Ord('M'));
  if not FindRawIFD(InBuf, Info) then
    raise ERawError.Create('RAW: no CFA image found (unsupported raw layout)');

  CFAw := Integer(Info.ImageWidth); CFAh := Integer(Info.ImageLength);
  if (CFAw <= 0) or (CFAh <= 0) then raise ERawError.Create('RAW: bad CFA dimensions');
  if UInt64(CFAw) * UInt64(CFAh) * 4 > UInt64(High(NativeInt)) then
    raise ERawError.Create('RAW: image too large');

  // CFA pattern (default RGGB)
  RR := Integer(Info.CFARepeatRows); RC := Integer(Info.CFARepeatCols);
  if RR <> 2 then RR := 2; if RC <> 2 then RC := 2;
  if Length(Info.CFAPattern) >= 4 then
    for k := 0 to 3 do Pattern[k] := Info.CFAPattern[k]
  else begin Pattern[0]:=0; Pattern[1]:=1; Pattern[2]:=1; Pattern[3]:=2; end;

  // black / white
  for k := 0 to 3 do BlackArr[k] := 0;
  if Length(Info.BlackLevel) = 1 then
    for k := 0 to 3 do BlackArr[k] := Info.BlackLevel[0]
  else if Length(Info.BlackLevel) >= 4 then
    for k := 0 to 3 do BlackArr[k] := Info.BlackLevel[k];
  if Info.WhiteLevel > 0 then White := Info.WhiteLevel
  else White := (1 shl 16) - 1;

  // white balance from AsShotNeutral (neutral in camera space)
  if Info.HasAsShot and (Length(Info.AsShotNeutral) >= 3) and
     (Info.AsShotNeutral[0] > 0) and (Info.AsShotNeutral[1] > 0) and (Info.AsShotNeutral[2] > 0) then
    for c := 0 to 2 do wb[c] := 1.0 / Info.AsShotNeutral[c]
  else begin wb[0]:=1; wb[1]:=1; wb[2]:=1; end;
  // normalise so green = 1
  if wb[1] > 0 then for c := 0 to 2 do wb[c] := wb[c] / wb[1];

  // colour matrix cam<-XYZ -> build cam->sRGB (dcraw style)
  if Info.HasColorMatrix and (Length(Info.ColorMatrix) >= 9) then
  begin
    for y := 0 to 2 do
      for x := 0 to 2 do
      begin
        sum := 0;
        for k := 0 to 2 do sum := sum + Info.ColorMatrix[y*3+k] * XYZ_RGB[k*3+x];
        camrgb[y*3+x] := sum;
      end;
    for y := 0 to 2 do
    begin
      sum := 0; for x := 0 to 2 do sum := sum + camrgb[y*3+x];
      if sum = 0 then sum := 1;
      premul[y] := 1 / sum;
      for x := 0 to 2 do camrgb[y*3+x] := camrgb[y*3+x] / sum;
    end;
    if not Inv3(camrgb, rgbcam) then
      for k := 0 to 8 do rgbcam[k] := 0;
  end
  else
  begin
    for k := 0 to 8 do rgbcam[k] := 0;
    rgbcam[0] := 1; rgbcam[4] := 1; rgbcam[8] := 1;
  end;

  {$IFDEF XELRAWDBG}
  writeln(ErrOutput, Format('wb=%.3f %.3f %.3f  white=%.0f black=%.1f %.1f %.1f %.1f',
    [wb[0],wb[1],wb[2],White,BlackArr[0],BlackArr[1],BlackArr[2],BlackArr[3]]));
  writeln(ErrOutput, Format('rgbcam=[%.3f %.3f %.3f / %.3f %.3f %.3f / %.3f %.3f %.3f]',
    [rgbcam[0],rgbcam[1],rgbcam[2],rgbcam[3],rgbcam[4],rgbcam[5],rgbcam[6],rgbcam[7],rgbcam[8]]));
  writeln(ErrOutput, Format('pattern=%d %d %d %d comp=%d bps=%d',
    [Pattern[0],Pattern[1],Pattern[2],Pattern[3],Info.Compression,Info.BitsPerSample]));
  {$ENDIF}

  // ---- LinearRaw (already demosaiced RGB, e.g. photo=34892): no demosaic ----
  if Info.IsLinearRaw then
  begin
    if (Info.SamplesPerPixel < 3) or (Info.BitsPerSample <> 16) or
       (Length(Info.StripOffsets) = 0) then
      raise ERawError.Create('RAW: unsupported LinearRaw layout');
    di := NativeInt(Info.StripOffsets[0]);
    if di + NativeInt(CFAw) * CFAh * 6 > Length(InBuf) then
      raise ERawError.Create('RAW: truncated LinearRaw data');
    if Info.WhiteLevel = 0 then
    begin
      maxc := 0;
      for y := 0 to CFAh - 1 do
        for x := 0 to CFAw * 3 - 1 do
        begin
          bin := RU16(InBuf, di + NativeInt(y) * CFAw * 6 + NativeInt(x) * 2);
          if bin > maxc then maxc := bin;
        end;
      if maxc > 0 then White := maxc;
    end;
    if White - BlackArr[0] <= 0 then White := BlackArr[0] + 1;
    Width := CFAw; Height := CFAh;
    SetLength(Result, NativeInt(CFAw) * CFAh * 4);
    for y := 0 to CFAh - 1 do
      for x := 0 to CFAw - 1 do
      begin
        acc := di + (NativeInt(y) * CFAw + x) * 6;
        camR := (RU16(InBuf, acc + 0) - BlackArr[0]) / (White - BlackArr[0]) * wb[0];
        camG := (RU16(InBuf, acc + 2) - BlackArr[0]) / (White - BlackArr[0]) * wb[1];
        camB := (RU16(InBuf, acc + 4) - BlackArr[0]) / (White - BlackArr[0]) * wb[2];
        if camR < 0 then camR := 0; if camG < 0 then camG := 0; if camB < 0 then camB := 0;
        rr2 := rgbcam[0]*camR + rgbcam[1]*camG + rgbcam[2]*camB;
        gg  := rgbcam[3]*camR + rgbcam[4]*camG + rgbcam[5]*camB;
        bb  := rgbcam[6]*camR + rgbcam[7]*camG + rgbcam[8]*camB;
        di2 := (NativeInt(y) * CFAw + x) * 4;
        Result[di2 + 0] := SRGBGamma(rr2);
        Result[di2 + 1] := SRGBGamma(gg);
        Result[di2 + 2] := SRGBGamma(bb);
        Result[di2 + 3] := 255;
      end;
    Exit;
  end;

  // ---- unpack CFA ----
  SetLength(cfa, NativeInt(CFAw) * CFAh);
  if Info.Compression = 7 then
  begin
    if Length(Info.TileOffsets) > 0 then
    begin
      tilesAcross := (CFAw + Integer(Info.TileWidth) - 1) div Integer(Info.TileWidth);
      for t := 0 to High(Info.TileOffsets) do
      begin
        if t >= Length(Info.TileByteCounts) then Break;
        if not LJpegDecode(InBuf, Info.TileOffsets[t], Info.TileByteCounts[t],
                           Samples, jwide, jhigh, clrs, prec) then Continue;
        tileCol := t mod tilesAcross; tileRow := t div tilesAcross;
        for ty := 0 to jhigh - 1 do
        begin
          outRow := tileRow * Integer(Info.TileLength) + ty;
          if outRow >= CFAh then Break;
          for tx := 0 to jwide * clrs - 1 do
          begin
            outCol := tileCol * Integer(Info.TileWidth) + tx;
            if outCol >= CFAw then Break;
            cfa[outRow * CFAw + outCol] := Samples[ty * jwide * clrs + tx];
          end;
        end;
      end;
    end
    else if Length(Info.StripOffsets) > 0 then
    begin
      if LJpegDecode(InBuf, Info.StripOffsets[0], Info.StripByteCounts[0],
                     Samples, jwide, jhigh, clrs, prec) then
        for ty := 0 to Min(jhigh, CFAh) - 1 do
          for tx := 0 to Min(jwide * clrs, CFAw) - 1 do
            cfa[ty * CFAw + tx] := Samples[ty * jwide * clrs + tx];
    end;
  end
  else if Info.Compression = 1 then
  begin
    if (Info.SamplesPerPixel <> 1) or (Length(Info.StripOffsets) = 0) then
      raise ERawError.Create('RAW: unsupported uncompressed layout');
    di := NativeInt(Info.StripOffsets[0]);
    if Length(Info.StripByteCounts) > 0 then sbc := Info.StripByteCounts[0] else sbc := 0;

    if sbc >= NativeUInt(CFAw) * NativeUInt(CFAh) * 2 then
    begin
      // one sample per 16-bit word
      if di + NativeInt(CFAw) * CFAh * 2 > Length(InBuf) then
        raise ERawError.Create('RAW: truncated CFA');
      k2 := di;
      for y := 0 to CFAh - 1 do
        for x := 0 to CFAw - 1 do
        begin cfa[y * CFAw + x] := RU16(InBuf, k2); Inc(k2, 2); end;
    end
    else
      // strip is smaller than 16-bit/pixel: try the Olympus ORF predictive codec
      // (Olympus stores its lossless raw as Compression=1).
      if not OlympusDecode(InBuf, NativeUInt(di), sbc, CFAw, CFAh, CFAw, CFAw, cfa) then
        raise ERawError.Create('RAW: CFA is vendor-packed/compressed ' +
          '(unsupported vendor codec)');
  end
  else
    raise ERawError.CreateFmt('RAW: unsupported compression %d', [Info.Compression]);

  // gray-world auto white balance when the file has no AsShotNeutral (vendor
  // raws without DNG colour tags): equalise the average of each CFA colour
  if not Info.HasAsShot then
  begin
    sumR := 0; sumG := 0; sumB := 0; cntR := 0; cntG := 0; cntB := 0;
    y := 0;
    while y < CFAh do
    begin
      x := 0;
      while x < CFAw do
      begin
        cfacol := ColorAt(x, y); v := cfa[y * CFAw + x];
        case cfacol of
          0: begin sumR := sumR + v; Inc(cntR); end;
          1: begin sumG := sumG + v; Inc(cntG); end;
          2: begin sumB := sumB + v; Inc(cntB); end;
        end;
        Inc(x, 2);
      end;
      Inc(y, 2);
    end;
    if (cntR > 0) and (cntG > 0) and (cntB > 0) then
    begin
      avgR := sumR / cntR; avgG := sumG / cntG; avgB := sumB / cntB;
      if avgR > 0 then wb[0] := avgG / avgR;
      wb[1] := 1;
      if avgB > 0 then wb[2] := avgG / avgB;
      for c := 0 to 2 do
      begin
        if wb[c] < 0.2 then wb[c] := 0.2;
        if wb[c] > 8 then wb[c] := 8;
      end;
    end;
  end;

  // white-level fallback (vendor raws without a WhiteLevel tag): use the peak
  // sample so the normalisation and auto-brightness have a sane range
  if Info.WhiteLevel = 0 then
  begin
    maxc := 0;
    for di := 0 to NativeInt(CFAw) * CFAh - 1 do
      if cfa[di] > maxc then maxc := cfa[di];
    if maxc > 0 then White := maxc;
  end;

  // ---- auto-brightness: scale so the 99th-percentile green reaches ~0.8 ----
  // (raw developers apply this; without it linear raw looks very dark)
  for bin := 0 to 1023 do hist[bin] := 0;
  total := 0;
  y := 0;
  while y < CFAh do
  begin
    x := 0;
    while x < CFAw do
    begin
      if ColorAt(x, y) = 1 then
      begin
        vg := GetLin(x, y);                   // black/white + wb (green wb=1)
        if vg > 1 then vg := 1;
        bin := Trunc(vg * 1023);
        if bin < 0 then bin := 0 else if bin > 1023 then bin := 1023;
        Inc(hist[bin]); Inc(total);
      end;
      Inc(x);
    end;
    Inc(y, 4);                                // sample every 4th row for speed
  end;
  ExpScale := 1;
  if total > 0 then
  begin
    thr := Round(total * 0.99);
    acc := 0; bin := 0;
    while (bin < 1023) and (acc < thr) do begin Inc(acc, hist[bin]); Inc(bin); end;
    vg := (bin + 0.5) / 1024;
    if vg > 0.001 then expScaleTmp := 0.8 / vg else expScaleTmp := 8;
    if expScaleTmp < 1 then expScaleTmp := 1;
    if expScaleTmp > 32 then expScaleTmp := 32;
    ExpScale := expScaleTmp;
  end;

  // ---- active-area crop ----
  if Info.HasActive then
  begin
    aTop := Integer(Info.ActiveTop); aLeft := Integer(Info.ActiveLeft);
    aBottom := Integer(Info.ActiveBottom); aRight := Integer(Info.ActiveRight);
  end
  else begin aTop := 0; aLeft := 0; aBottom := CFAh; aRight := CFAw; end;
  if (aBottom <= aTop) or (aRight <= aLeft) or (aBottom > CFAh) or (aRight > CFAw) then
  begin aTop := 0; aLeft := 0; aBottom := CFAh; aRight := CFAw; end;
  OutW := aRight - aLeft; OutH := aBottom - aTop;

  Width := OutW; Height := OutH;
  SetLength(Result, NativeInt(OutW) * OutH * 4);

  for y := aTop to aBottom - 1 do
    for x := aLeft to aRight - 1 do
    begin
      {$IFDEF XELRAWGRAY}
      camR := GetLin(x, y) * ExpScale; camG := camR; camB := camR;
      Col.R := SRGBGamma(camR); Col.G := Col.R; Col.B := Col.R; Col.A := 255;
      di2 := (NativeInt(y - aTop) * OutW + (x - aLeft)) * 4;
      Result[di2 + 0] := Col.R; Result[di2 + 1] := Col.G;
      Result[di2 + 2] := Col.B; Result[di2 + 3] := 255;
      Continue;
      {$ENDIF}
      Demosaic(x, y, camR, camG, camB);
      camR := camR * ExpScale; camG := camG * ExpScale; camB := camB * ExpScale;
      rr2 := rgbcam[0]*camR + rgbcam[1]*camG + rgbcam[2]*camB;
      gg  := rgbcam[3]*camR + rgbcam[4]*camG + rgbcam[5]*camB;
      bb  := rgbcam[6]*camR + rgbcam[7]*camG + rgbcam[8]*camB;
      Col.R := SRGBGamma(rr2);
      Col.G := SRGBGamma(gg);
      Col.B := SRGBGamma(bb);
      Col.A := 255;
      di := (NativeInt(y - aTop) * OutW + (x - aLeft)) * 4;
      Result[di + 0] := Col.R; Result[di + 1] := Col.G;
      Result[di + 2] := Col.B; Result[di + 3] := Col.A;
    end;
end;

end.
