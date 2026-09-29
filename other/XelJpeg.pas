unit XelJpeg;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, Math, XelPng;

type
  EJpegError = class(Exception);

function DecodeJpeg(InBuf: TBytes; out Width, Height: Integer): TBytes; // RGBA8
function EncodeJpeg(InBuf: TBytes; Width, Height: Integer; Quality: Integer = 90): TBytes; // InBuf = RGBA8, Quality 1..100

implementation

const
  M_SOI  = $D8;
  M_EOI  = $D9;
  M_SOS  = $DA;
  M_DQT  = $DB;
  M_DHT  = $C4;
  M_DRI  = $DD;
  M_SOF0 = $C0;
  M_SOF2 = $C2;
  M_APP0 = $E0;
  M_APP14 = $EE;

  ZigZag: array[0..63] of Byte = (
     0, 1, 8,16, 9, 2, 3,10,
    17,24,32,25,18,11, 4, 5,
    12,19,26,33,40,48,41,34,
    27,20,13, 6, 7,14,21,28,
    35,42,49,56,57,50,43,36,
    29,22,15,23,30,37,44,51,
    58,59,52,45,38,31,39,46,
    53,60,61,54,47,55,62,63
  );

  StdLumQ: array[0..63] of Byte = (
    16,11,10,16,24,40,51,61,
    12,12,14,19,26,58,60,55,
    14,13,16,24,40,57,69,56,
    14,17,22,29,51,87,80,62,
    18,22,37,56,68,109,103,77,
    24,35,55,64,81,104,113,92,
    49,64,78,87,103,121,120,101,
    72,92,95,98,112,100,103,99
  );

  StdChrQ: array[0..63] of Byte = (
    17,18,24,47,99,99,99,99,
    18,21,26,66,99,99,99,99,
    24,26,56,99,99,99,99,99,
    47,66,99,99,99,99,99,99,
    99,99,99,99,99,99,99,99,
    99,99,99,99,99,99,99,99,
    99,99,99,99,99,99,99,99,
    99,99,99,99,99,99,99,99
  );

  BitsDcLum: array[0..15] of Byte =
    (0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0);
  ValDcLum: array[0..11] of Byte =
    (0,1,2,3,4,5,6,7,8,9,10,11);

  BitsDcChr: array[0..15] of Byte =
    (0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0);
  ValDcChr: array[0..11] of Byte =
    (0,1,2,3,4,5,6,7,8,9,10,11);

  BitsAcLum: array[0..15] of Byte =
    (0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,$7D);
  ValAcLum: array[0..161] of Byte = (
    $01,$02,$03,$00,$04,$11,$05,$12,$21,$31,$41,$06,$13,$51,$61,$07,
    $22,$71,$14,$32,$81,$91,$A1,$08,$23,$42,$B1,$C1,$15,$52,$D1,$F0,
    $24,$33,$62,$72,$82,$09,$0A,$16,$17,$18,$19,$1A,$25,$26,$27,$28,
    $29,$2A,$34,$35,$36,$37,$38,$39,$3A,$43,$44,$45,$46,$47,$48,$49,
    $4A,$53,$54,$55,$56,$57,$58,$59,$5A,$63,$64,$65,$66,$67,$68,$69,
    $6A,$73,$74,$75,$76,$77,$78,$79,$7A,$83,$84,$85,$86,$87,$88,$89,
    $8A,$92,$93,$94,$95,$96,$97,$98,$99,$9A,$A2,$A3,$A4,$A5,$A6,$A7,
    $A8,$A9,$AA,$B2,$B3,$B4,$B5,$B6,$B7,$B8,$B9,$BA,$C2,$C3,$C4,$C5,
    $C6,$C7,$C8,$C9,$CA,$D2,$D3,$D4,$D5,$D6,$D7,$D8,$D9,$DA,$E1,$E2,
    $E3,$E4,$E5,$E6,$E7,$E8,$E9,$EA,$F1,$F2,$F3,$F4,$F5,$F6,$F7,$F8,
    $F9,$FA
  );

  BitsAcChr: array[0..15] of Byte =
    (0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,$77);
  ValAcChr: array[0..161] of Byte = (
    $00,$01,$02,$03,$11,$04,$05,$21,$31,$06,$12,$41,$51,$07,$61,$71,
    $13,$22,$32,$81,$08,$14,$42,$91,$A1,$B1,$C1,$09,$23,$33,$52,$F0,
    $15,$62,$72,$D1,$0A,$16,$24,$34,$E1,$25,$F1,$17,$18,$19,$1A,$26,
    $27,$28,$29,$2A,$35,$36,$37,$38,$39,$3A,$43,$44,$45,$46,$47,$48,
    $49,$4A,$53,$54,$55,$56,$57,$58,$59,$5A,$63,$64,$65,$66,$67,$68,
    $69,$6A,$73,$74,$75,$76,$77,$78,$79,$7A,$82,$83,$84,$85,$86,$87,
    $88,$89,$8A,$92,$93,$94,$95,$96,$97,$98,$99,$9A,$A2,$A3,$A4,$A5,
    $A6,$A7,$A8,$A9,$AA,$B2,$B3,$B4,$B5,$B6,$B7,$B8,$B9,$BA,$C2,$C3,
    $C4,$C5,$C6,$C7,$C8,$C9,$CA,$D2,$D3,$D4,$D5,$D6,$D7,$D8,$D9,$DA,
    $E2,$E3,$E4,$E5,$E6,$E7,$E8,$E9,$EA,$F2,$F3,$F4,$F5,$F6,$F7,$F8,
    $F9,$FA
  );

type
  TQuantTable = array[0..63] of Word;
  TCoeffBlock = array[0..63] of Integer;
  TCoeffBlocks = array of TCoeffBlock;
  TSampleBlock = array[0..63] of Byte;
  TFloatBlock = array[0..63] of Double;

  TJpegComponent = record
    Id: Byte;
    H, V: Byte;
    QTable: Byte;
    DCTable: Byte;
    ACTable: Byte;
    DCPred: Integer;
  end;

  THuffDec = record
    Valid: Boolean;
    MinCode: array[1..16] of Integer;
    MaxCode: array[1..16] of Integer;
    ValPtr: array[1..16] of Integer;
    Values: array[0..255] of Byte;
    ValueCount: Integer;
  end;

  THuffEnc = record
    Code: array[0..255] of Word;
    Size: array[0..255] of Byte;
  end;

  TBitReader = record
    Pos: NativeUInt;
    Cur: Byte;
    BitsLeft: Integer;
    Hit: Boolean;      // reached a marker or the end: zero bits from here on
  end;

  TBitWriter = record
    Cur: Byte;
    BitsUsed: Integer;
  end;

var
  CosTable: array[0..7,0..7] of Double;
  CosReady: Boolean = False;

procedure InitCosTable;
var
  U, X: Integer;
begin
  if CosReady then Exit;
  U := 0;
  while U < 8 do
  begin
    X := 0;
    while X < 8 do
    begin
      CosTable[U,X] := Cos((2.0 * X + 1.0) * U * Pi / 16.0);
      Inc(X);
    end;
    Inc(U);
  end;
  CosReady := True;
end;

function ClampByte(V: Integer): Byte; inline;
begin
  if V < 0 then Result := 0
  else if V > 255 then Result := 255
  else Result := Byte(V);
end;

function ReadBE16(const Data: TBytes; Pos: NativeUInt): Word; inline;
begin
  if (Pos + 2 > NativeUInt(Length(Data))) then
    raise EJpegError.Create('JPEG: truncated file');
  Result := (Word(Data[Pos]) shl 8) or Word(Data[Pos + 1]);
end;

procedure Need(const Data: TBytes; Pos, Count: NativeUInt); inline;
var
  L: NativeUInt;
begin
  L := NativeUInt(Length(Data));
  if (Pos > L) or (Count > L - Pos) then
    raise EJpegError.Create('JPEG: truncated file');
end;

procedure AppendByte(var A: TBytes; B: Byte); inline;
var
  N: NativeUInt;
begin
  N := NativeUInt(Length(A));
  SetLength(A, N + 1);
  A[N] := B;
end;

procedure AppendBE16(var A: TBytes; V: Word); inline;
begin
  AppendByte(A, Byte(V shr 8));
  AppendByte(A, Byte(V));
end;

procedure AppendMarker(var A: TBytes; Marker: Byte); inline;
begin
  AppendByte(A, $FF);
  AppendByte(A, Marker);
end;

// Next marker at or after Pos; False at the end of the data.
function FindMarker(const Data: TBytes; var Pos: NativeUInt; out Marker: Byte): Boolean;
var
  L: NativeUInt;
begin
  Result := False;
  Marker := 0;
  L := NativeUInt(Length(Data));
  while True do
  begin
    while (Pos < L) and (Data[Pos] <> $FF) do Inc(Pos);
    while (Pos < L) and (Data[Pos] = $FF) do Inc(Pos);
    if Pos >= L then Exit;
    if Data[Pos] <> $00 then Break;       // FF00 is a stuffed byte, not a marker
    Inc(Pos);
  end;
  Marker := Data[Pos];
  Inc(Pos);
  Result := True;
end;

function NextMarker(const Data: TBytes; var Pos: NativeUInt): Byte;
var
  L: NativeUInt;
begin
  L := NativeUInt(Length(Data));
  while (Pos < L) and (Data[Pos] <> $FF) do Inc(Pos);
  if Pos >= L then raise EJpegError.Create('JPEG: marker expected');
  while (Pos < L) and (Data[Pos] = $FF) do Inc(Pos);
  if Pos >= L then raise EJpegError.Create('JPEG: truncated marker');
  Result := Data[Pos];
  Inc(Pos);
end;

function FindComponent(const C: array of TJpegComponent; Count: Integer;
  Id: Byte): Integer;
var
  I: Integer;
begin
  I := 0;
  while I < Count do
  begin
    if C[I].Id = Id then
    begin
      Result := I;
      Exit;
    end;
    Inc(I);
  end;
  Result := -1;
end;

procedure BuildHuffDec(var T: THuffDec; const Counts: array of Byte;
  const Values: array of Byte);
var
  Len, I, K, Code, Cnt: Integer;
begin
  FillChar(T, SizeOf(T), 0);
  Code := 0;
  K := 0;
  Len := 1;
  while Len <= 16 do
  begin
    Cnt := Counts[Len - 1];
    if Cnt <> 0 then
    begin
      T.MinCode[Len] := Code;
      T.MaxCode[Len] := Code + Cnt - 1;
      T.ValPtr[Len] := K;
      Code := Code + Cnt;
      K := K + Cnt;
    end
    else
    begin
      T.MinCode[Len] := -1;
      T.MaxCode[Len] := -1;
      T.ValPtr[Len] := K;
    end;
    Code := Code shl 1;
    Inc(Len);
  end;
  if K > Length(Values) then
    raise EJpegError.Create('JPEG: invalid Huffman table');
  I := 0;
  while I < K do
  begin
    T.Values[I] := Values[I];
    Inc(I);
  end;
  T.ValueCount := K;
  T.Valid := True;
end;

procedure BuildHuffEnc(var T: THuffEnc; const Counts: array of Byte;
  const Values: array of Byte);
var
  Len, J, K: Integer;
  Code: Cardinal;
  Sym: Byte;
begin
  FillChar(T, SizeOf(T), 0);
  Code := 0;
  K := 0;
  Len := 1;
  while Len <= 16 do
  begin
    J := 0;
    while J < Counts[Len - 1] do
    begin
      if K >= Length(Values) then
        raise EJpegError.Create('JPEG: invalid standard Huffman table');
      Sym := Values[K];
      T.Code[Sym] := Word(Code);
      T.Size[Sym] := Byte(Len);
      Inc(Code);
      Inc(K);
      Inc(J);
    end;
    Code := Code shl 1;
    Inc(Len);
  end;
end;

// Next byte of entropy-coded data. Like libjpeg, a marker or the end of the
// data does not stop decoding: the reader stays in front of the marker and
// supplies zero bits, so a truncated or damaged scan still yields a picture
// (the missing part flat) and the marker is left for the caller.
function ReadEntropyByte(const Data: TBytes; var BR: TBitReader): Byte;
var
  B: Byte;
  L, P: NativeUInt;
begin
  Result := 0;
  if BR.Hit then Exit;
  L := NativeUInt(Length(Data));
  if BR.Pos >= L then
  begin
    BR.Hit := True;
    Exit;
  end;
  B := Data[BR.Pos];
  if B <> $FF then
  begin
    Inc(BR.Pos);
    Result := B;
    Exit;
  end;
  P := BR.Pos + 1;
  if (P < L) and (Data[P] = $00) then
  begin
    BR.Pos := P + 1;                     // stuffed FF00
    Result := $FF;
    Exit;
  end;
  BR.Hit := True;                        // a marker (or FF at the end)
end;

function ReadBit(const Data: TBytes; var BR: TBitReader): Integer; inline;
begin
  if BR.BitsLeft = 0 then
  begin
    BR.Cur := ReadEntropyByte(Data, BR);
    BR.BitsLeft := 8;
  end;
  Dec(BR.BitsLeft);
  Result := (BR.Cur shr BR.BitsLeft) and 1;
end;

function ReadBits(const Data: TBytes; var BR: TBitReader; N: Integer): Cardinal;
var
  I: Integer;
begin
  Result := 0;
  I := 0;
  while I < N do
  begin
    Result := (Result shl 1) or Cardinal(ReadBit(Data, BR));
    Inc(I);
  end;
end;

function DecodeHuff(const Data: TBytes; var BR: TBitReader;
  const T: THuffDec): Byte;
var
  Len, Code, Idx: Integer;
begin
  if not T.Valid then raise EJpegError.Create('JPEG: missing Huffman table');
  Code := 0;
  Len := 1;
  while Len <= 16 do
  begin
    Code := (Code shl 1) or ReadBit(Data, BR);
    if (T.MaxCode[Len] >= 0) and (Code >= T.MinCode[Len]) and
       (Code <= T.MaxCode[Len]) then
    begin
      Idx := T.ValPtr[Len] + Code - T.MinCode[Len];
      if (Idx < 0) or (Idx >= T.ValueCount) then
        raise EJpegError.Create('JPEG: invalid Huffman code');
      Result := T.Values[Idx];
      Exit;
    end;
    Inc(Len);
  end;
  raise EJpegError.Create('JPEG: invalid Huffman code');
end;

function ReceiveExtend(const Data: TBytes; var BR: TBitReader; N: Integer): Integer;
var
  V, Limit: Integer;
begin
  if N = 0 then
  begin
    Result := 0;
    Exit;
  end;
  V := Integer(ReadBits(Data, BR, N));
  Limit := 1 shl (N - 1);
  if V < Limit then V := V - ((1 shl N) - 1);
  Result := V;
end;

// Reads the restart marker RST(Expected) at the end of a restart interval,
// resynchronising like libjpeg's jpeg_resync_to_restart when the data is
// damaged: stray bytes before the marker are skipped, an older RST is dropped
// and the search goes on, a following RST (1 or 2 ahead) or any other marker
// is left in place (the missing intervals decode as zeros). The "data ran
// out" state is cleared only when a restart marker is really consumed.
procedure ConsumeRestart(const Data: TBytes; var BR: TBitReader;
  Expected: Integer);
var
  L, P, Q: NativeUInt;
  M: Byte;
  Dist: Integer;
begin
  BR.BitsLeft := 0;
  L := NativeUInt(Length(Data));
  while True do
  begin
    // the next marker from BR.Pos (FF00 inside skipped data is not one)
    P := BR.Pos;
    while True do
    begin
      while (P < L) and (Data[P] <> $FF) do Inc(P);
      Q := P + 1;
      while (Q < L) and (Data[Q] = $FF) do Inc(Q);
      if Q >= L then
      begin
        BR.Pos := L;                     // no more markers: zeros from here
        Exit;
      end;
      if Data[Q] <> $00 then Break;
      P := Q + 1;
    end;
    M := Data[Q];
    if M = Byte($D0 + (Expected and 7)) then
    begin
      BR.Pos := Q + 1;                   // the expected RST
      BR.Hit := False;
      Exit;
    end;
    if (M < $D0) or (M > $D7) then
    begin
      BR.Pos := P;                       // another marker: leave it
      Exit;
    end;
    Dist := (Integer(M) - $D0 - Expected) and 7;
    if Dist in [1, 2] then
    begin
      BR.Pos := P;                       // a later RST: data went missing
      Exit;
    end;
    BR.Pos := Q + 1;                     // an earlier or far-off RST: drop it
    if Dist in [3, 4, 5] then            // (far-off: treat it as ours)
    begin
      BR.Hit := False;
      Exit;
    end;
  end;
end;

procedure InverseDCT(const Coeff: TCoeffBlock; var OutBlock: TSampleBlock);
var
  Temp: TFloatBlock;
  X, Y, U, V: Integer;
  S, CU, CV: Double;
  IV: Integer;
begin
  InitCosTable;

  Y := 0;
  while Y < 8 do
  begin
    U := 0;
    while U < 8 do
    begin
      S := 0.0;
      V := 0;
      while V < 8 do
      begin
        if V = 0 then CV := 0.7071067811865475244 else CV := 1.0;
        S := S + CV * Coeff[V * 8 + U] * CosTable[V,Y];
        Inc(V);
      end;
      Temp[Y * 8 + U] := S;
      Inc(U);
    end;
    Inc(Y);
  end;

  Y := 0;
  while Y < 8 do
  begin
    X := 0;
    while X < 8 do
    begin
      S := 0.0;
      U := 0;
      while U < 8 do
      begin
        if U = 0 then CU := 0.7071067811865475244 else CU := 1.0;
        S := S + CU * Temp[Y * 8 + U] * CosTable[U,X];
        Inc(U);
      end;
      IV := Round(0.25 * S) + 128;
      OutBlock[Y * 8 + X] := ClampByte(IV);
      Inc(X);
    end;
    Inc(Y);
  end;
end;

procedure ForwardDCT(const Samples: TSampleBlock; const Q: TQuantTable;
  var Quantized: TCoeffBlock);
var
  Temp, Freq: TFloatBlock;
  X, Y, U, V: Integer;
  S, CU, CV: Double;
begin
  InitCosTable;

  Y := 0;
  while Y < 8 do
  begin
    U := 0;
    while U < 8 do
    begin
      S := 0.0;
      X := 0;
      while X < 8 do
      begin
        S := S + (Integer(Samples[Y * 8 + X]) - 128) * CosTable[U,X];
        Inc(X);
      end;
      Temp[Y * 8 + U] := S;
      Inc(U);
    end;
    Inc(Y);
  end;

  V := 0;
  while V < 8 do
  begin
    U := 0;
    while U < 8 do
    begin
      S := 0.0;
      Y := 0;
      while Y < 8 do
      begin
        S := S + Temp[Y * 8 + U] * CosTable[V,Y];
        Inc(Y);
      end;
      if U = 0 then CU := 0.7071067811865475244 else CU := 1.0;
      if V = 0 then CV := 0.7071067811865475244 else CV := 1.0;
      Freq[V * 8 + U] := 0.25 * CU * CV * S;
      if Q[V * 8 + U] = 0 then
        raise EJpegError.Create('JPEG: zero quantizer');
      Quantized[V * 8 + U] := Round(Freq[V * 8 + U] / Q[V * 8 + U]);
      Inc(U);
    end;
    Inc(V);
  end;
end;

procedure DecodeSequentialCoeffBlock(const Data: TBytes; var BR: TBitReader;
  var Comp: TJpegComponent; const HDc, HAc: THuffDec; var C: TCoeffBlock);
var
  T, K, R, S, Sym, V: Integer;
begin
  FillChar(C, SizeOf(C), 0);

  T := DecodeHuff(Data, BR, HDc);
  if T > 16 then raise EJpegError.Create('JPEG: invalid DC coefficient size');
  V := ReceiveExtend(Data, BR, T);
  Comp.DCPred := Comp.DCPred + V;
  C[0] := Comp.DCPred;

  K := 1;
  while K < 64 do
  begin
    Sym := DecodeHuff(Data, BR, HAc);
    R := Sym shr 4;
    S := Sym and $0F;
    if S = 0 then
    begin
      if R = 15 then
      begin
        Inc(K, 16);                     // a ZRL past the end just ends the block
        Continue;
      end;
      Break;
    end;
    Inc(K, R);
    V := ReceiveExtend(Data, BR, S);
    // corrupt data can run past the block: like libjpeg (whose zig-zag table
    // is padded with 63s) the value lands in the last coefficient
    if K > 63 then K := 63;
    C[ZigZag[K]] := V;
    Inc(K);
  end;
end;

procedure DecodeProgressiveDC(const Data: TBytes; var BR: TBitReader;
  var Comp: TJpegComponent; const HDc: THuffDec; Ah, Al: Integer;
  var C: TCoeffBlock);
var
  T, Diff, DC, Bit: Integer;
begin
  if Ah = 0 then
  begin
    T := DecodeHuff(Data, BR, HDc);
    if T > 16 then raise EJpegError.Create('JPEG: invalid progressive DC size');
    Diff := ReceiveExtend(Data, BR, T);
    DC := Comp.DCPred + Diff;
    Comp.DCPred := DC;
    C[0] := DC * (1 shl Al);
  end
  else
  begin
    Bit := 1 shl Al;
    // The DC refinement bit is a bit of the two's-complement value.
    if ReadBit(Data, BR) <> 0 then C[0] := C[0] or Bit;
  end;
end;

procedure RefineCoefficient(const Data: TBytes; var BR: TBitReader;
  var V: Integer; Bit: Integer); inline;
begin
  if V = 0 then Exit;
  if ReadBit(Data, BR) = 0 then Exit;
  if (V and Bit) <> 0 then Exit;
  if V >= 0 then Inc(V, Bit) else Dec(V, Bit);
end;

procedure DecodeProgressiveAC(const Data: TBytes; var BR: TBitReader;
  const HAc: THuffDec; Ss, Se, Ah, Al: Integer; var EOBRun: Integer;
  var C: TCoeffBlock);
var
  K, R, S, Sym, Idx, V, Bit, NewValue: Integer;
begin
  if Ss = 0 then raise EJpegError.Create('JPEG: invalid progressive AC scan');

  // First AC scan for this spectral band.
  if Ah = 0 then
  begin
    if EOBRun <> 0 then
    begin
      Dec(EOBRun);
      Exit;
    end;

    K := Ss;
    while K <= Se do
    begin
      Sym := DecodeHuff(Data, BR, HAc);
      R := Sym shr 4;
      S := Sym and $0F;
      if S = 0 then
      begin
        if R < 15 then
        begin
          EOBRun := 1 shl R;
          if R <> 0 then Inc(EOBRun, Integer(ReadBits(Data, BR, R)));
          Dec(EOBRun); // current block is part of the run
          Break;
        end;
        Inc(K, 16); // ZRL (past the band end it just ends the block)
      end
      else
      begin
        Inc(K, R);
        if K > 63 then K := 63;         // corrupt run: as libjpeg
        V := ReceiveExtend(Data, BR, S);
        C[ZigZag[K]] := V * (1 shl Al);
        Inc(K);
      end;
    end;
    Exit;
  end;

  // Successive-approximation AC refinement.
  Bit := 1 shl Al;
  if EOBRun <> 0 then
  begin
    Dec(EOBRun);
    K := Ss;
    while K <= Se do
    begin
      Idx := ZigZag[K];
      if C[Idx] <> 0 then RefineCoefficient(Data, BR, C[Idx], Bit);
      Inc(K);
    end;
    Exit;
  end;

  K := Ss;
  while K <= Se do
  begin
    Sym := DecodeHuff(Data, BR, HAc);
    R := Sym shr 4;
    S := Sym and $0F;
    NewValue := 0;

    if S = 0 then
    begin
      if R < 15 then
      begin
        // EOBr = 2^R + appended bits.  Store future blocks only; the
        // current block is refined below.
        EOBRun := (1 shl R) - 1;
        if R <> 0 then Inc(EOBRun, Integer(ReadBits(Data, BR, R)));
        R := 64; // force traversal/refinement to end of this band
      end;
    end
    else
    begin
      // S must be 1; libjpeg warns and carries on as if it were
      if ReadBit(Data, BR) <> 0 then NewValue := Bit else NewValue := -Bit;
    end;

    while K <= Se do
    begin
      Idx := ZigZag[K];
      if C[Idx] <> 0 then
        RefineCoefficient(Data, BR, C[Idx], Bit)
      else
      begin
        if R = 0 then
        begin
          C[Idx] := NewValue;
          Inc(K);
          Break;
        end;
        Dec(R);
      end;
      Inc(K);
    end;
  end;
end;

procedure PutBlockInPlane(var Plane: TBytes; PlaneW: Integer;
  BX, BY: Integer; const B: TSampleBlock);
var
  X, Y, Dst: Integer;
begin
  Y := 0;
  while Y < 8 do
  begin
    X := 0;
    Dst := (BY * 8 + Y) * PlaneW + BX * 8;
    while X < 8 do
    begin
      Plane[Dst + X] := B[Y * 8 + X];
      Inc(X);
    end;
    Inc(Y);
  end;
end;

procedure YCbCrToRGB(Yv, Cbv, Crv: Integer; var C: TRGBA); inline;
var
  R, G, B: Integer;
begin
  R := Round(Yv + 1.40200 * (Crv - 128));
  G := Round(Yv - 0.344136 * (Cbv - 128) - 0.714136 * (Crv - 128));
  B := Round(Yv + 1.77200 * (Cbv - 128));
  C.R := ClampByte(R);
  C.G := ClampByte(G);
  C.B := ClampByte(B);
  C.A := 255;
end;

function Mul255(A, B: Integer): Byte; inline;
var
  T: Integer;
begin
  T := A * B + 128;
  Result := Byte((T + (T shr 8)) shr 8);
end;

function DecodeJpeg(InBuf: TBytes; out Width, Height: Integer): TBytes;
type
  TCoeffState = array[0..3,0..63] of ShortInt;
var
  Pos, SegEnd, SegLen, P, I: NativeUInt;
  Marker, Info, Tq, Pq, Tc, Th: Byte;
  QTables: array[0..3] of TQuantTable;
  QValid: array[0..3] of Boolean;
  CompQ: array[0..3] of TQuantTable;
  CompQValid: array[0..3] of Boolean;
  HDc: array[0..3] of THuffDec;
  HAc: array[0..3] of THuffDec;
  Counts: array[0..15] of Byte;
  Values: array[0..255] of Byte;
  ValCount, NComp, ScanComp, Idx: Integer;
  Comps: array[0..3] of TJpegComponent;
  JpegWidth, JpegHeight: Word;
  Precision, HMax, VMax: Byte;
  RestartInterval: Word;
  AdobeTransform: Integer;
  FrameSeen, ScanSeen, Progressive: Boolean;
  ScanOrder: array[0..3] of Integer;
  Ss, Se, Ah, Al: Integer;
  FrameMCUCols, FrameMCURows: Integer;
  CoeffW, CoeffH, ActualBW, ActualBH: array[0..3] of Integer;
  Coeffs: array[0..3] of TCoeffBlocks;
  CoeffState: TCoeffState;
  BaselineSeen: array[0..3] of Boolean;
  ScanCount: Integer;

  procedure AllocateFrameStorage;
  var
    CI: Integer;
    Count64: Int64;
  begin
    FrameMCUCols := (Integer(JpegWidth) + Integer(HMax) * 8 - 1) div (Integer(HMax) * 8);
    FrameMCURows := (Integer(JpegHeight) + Integer(VMax) * 8 - 1) div (Integer(VMax) * 8);
    CI := 0;
    while CI < NComp do
    begin
      CoeffW[CI] := FrameMCUCols * Integer(Comps[CI].H);
      CoeffH[CI] := FrameMCURows * Integer(Comps[CI].V);
      ActualBW[CI] := (Integer(JpegWidth) * Integer(Comps[CI].H) + Integer(HMax) * 8 - 1) div
                      (Integer(HMax) * 8);
      ActualBH[CI] := (Integer(JpegHeight) * Integer(Comps[CI].V) + Integer(VMax) * 8 - 1) div
                      (Integer(VMax) * 8);
      Count64 := Int64(CoeffW[CI]) * Int64(CoeffH[CI]);
      if (Count64 <= 0) or (Count64 > MaxInt) then
        raise EJpegError.Create('JPEG: coefficient storage too large');
      SetLength(Coeffs[CI], NativeInt(Count64));
      Inc(CI);
    end;
  end;

  procedure ResetPredictors;
  var
    CI: Integer;
  begin
    CI := 0;
    while CI < NComp do
    begin
      Comps[CI].DCPred := 0;
      Inc(CI);
    end;
  end;

  procedure SnapshotQuant(CI: Integer);
  begin
    if Comps[CI].QTable > 3 then
      raise EJpegError.Create('JPEG: invalid quantization selector');
    if not QValid[Comps[CI].QTable] then
      raise EJpegError.Create('JPEG: missing quantization table');
    if not CompQValid[CI] then
    begin
      CompQ[CI] := QTables[Comps[CI].QTable];
      CompQValid[CI] := True;
    end;
  end;

  procedure ValidateProgressiveScan;
  var
    SI, CI, K: Integer;
  begin
    if (Ss < 0) or (Ss > 63) or (Se < Ss) or (Se > 63) or
       (Ah < 0) or (Ah > 13) or (Al < 0) or (Al > 13) then
      raise EJpegError.Create('JPEG: invalid progressive scan parameters');
    if Ss = 0 then
    begin
      if Se <> 0 then raise EJpegError.Create('JPEG: progressive DC scan must have Se=0');
    end
    else if ScanComp <> 1 then
      raise EJpegError.Create('JPEG: progressive AC scan must contain one component');
    if (Ah <> 0) and (Ah <> Al + 1) then
      raise EJpegError.Create('JPEG: invalid progressive successive approximation');

    SI := 0;
    while SI < ScanComp do
    begin
      CI := ScanOrder[SI];
      K := Ss;
      while K <= Se do
      begin
        if Ah = 0 then
        begin
          if CoeffState[CI,K] <> -1 then
            raise EJpegError.Create('JPEG: duplicate progressive first scan');
        end
        else if CoeffState[CI,K] <> Ah then
          raise EJpegError.Create('JPEG: invalid progressive refinement order');
        Inc(K);
      end;
      Inc(SI);
    end;
  end;

  procedure CommitProgressiveState;
  var
    SI, CI, K: Integer;
  begin
    SI := 0;
    while SI < ScanComp do
    begin
      CI := ScanOrder[SI];
      K := Ss;
      while K <= Se do
      begin
        CoeffState[CI,K] := ShortInt(Al);
        Inc(K);
      end;
      Inc(SI);
    end;
  end;

  procedure DecodeScan(var EntropyPos: NativeUInt);
  var
    BR: TBitReader;
    MX, MY, SI, CI, BX, BY, BW, BH, BlockX, BlockY: Integer;
    MCUCount, TotalMCUs, RstExpected, EOBRun, BlockIndex: Integer;
    SkipMCU: Boolean;

    procedure DecodeOneBlock(ACI, ABX, ABY: Integer);
    begin
      if (ABX < 0) or (ABY < 0) or (ABX >= CoeffW[ACI]) or (ABY >= CoeffH[ACI]) then
        raise EJpegError.Create('JPEG: coefficient block index out of range');
      // like libjpeg: once the data ran out (or hit a marker) the MCUs up to
      // the next restart are not decoded - sequential blocks stay zero,
      // progressive ones keep what the earlier scans gave them
      if SkipMCU then Exit;
      BlockIndex := ABY * CoeffW[ACI] + ABX;
      if not Progressive then
        DecodeSequentialCoeffBlock(InBuf, BR, Comps[ACI],
          HDc[Comps[ACI].DCTable], HAc[Comps[ACI].ACTable], Coeffs[ACI][BlockIndex])
      else if Ss = 0 then
        DecodeProgressiveDC(InBuf, BR, Comps[ACI], HDc[Comps[ACI].DCTable],
          Ah, Al, Coeffs[ACI][BlockIndex])
      else
        DecodeProgressiveAC(InBuf, BR, HAc[Comps[ACI].ACTable], Ss, Se, Ah, Al,
          EOBRun, Coeffs[ACI][BlockIndex]);
    end;

    procedure FinishMCU;
    begin
      Inc(MCUCount);
      if (RestartInterval <> 0) and
         ((MCUCount mod Integer(RestartInterval)) = 0) and
         (MCUCount < TotalMCUs) then
      begin
        ConsumeRestart(InBuf, BR, RstExpected);
        Inc(RstExpected);
        ResetPredictors;
        EOBRun := 0;
      end;
    end;

  begin
    if not Progressive then
    begin
      // sequential scans always cover the whole block; libjpeg ignores
      // whatever these fields hold
      Ss := 0; Se := 63; Ah := 0; Al := 0;
    end
    else
      ValidateProgressiveScan;

    SI := 0;
    while SI < ScanComp do
    begin
      CI := ScanOrder[SI];
      SnapshotQuant(CI);
      if not Progressive then
      begin
        if not HDc[Comps[CI].DCTable].Valid then raise EJpegError.Create('JPEG: missing DC Huffman table');
        if not HAc[Comps[CI].ACTable].Valid then raise EJpegError.Create('JPEG: missing AC Huffman table');
        if BaselineSeen[CI] then raise EJpegError.Create('JPEG: duplicate sequential component scan');
      end
      else if Ss = 0 then
      begin
        if (Ah = 0) and (not HDc[Comps[CI].DCTable].Valid) then
          raise EJpegError.Create('JPEG: missing DC Huffman table');
      end
      else if not HAc[Comps[CI].ACTable].Valid then
        raise EJpegError.Create('JPEG: missing AC Huffman table');
      Inc(SI);
    end;

    BR.Pos := EntropyPos;
    BR.Cur := 0;
    BR.BitsLeft := 0;
    BR.Hit := False;
    ResetPredictors;
    EOBRun := 0;
    MCUCount := 0;
    RstExpected := 0;

    if ScanComp = 1 then
    begin
      CI := ScanOrder[0];
      BW := ActualBW[CI];
      BH := ActualBH[CI];
      TotalMCUs := BW * BH;
      BlockY := 0;
      while BlockY < BH do
      begin
        BlockX := 0;
        while BlockX < BW do
        begin
          SkipMCU := BR.Hit;
          DecodeOneBlock(CI, BlockX, BlockY);
          FinishMCU;
          Inc(BlockX);
        end;
        Inc(BlockY);
      end;
    end
    else
    begin
      TotalMCUs := FrameMCUCols * FrameMCURows;
      MY := 0;
      while MY < FrameMCURows do
      begin
        MX := 0;
        while MX < FrameMCUCols do
        begin
          SkipMCU := BR.Hit;
          SI := 0;
          while SI < ScanComp do
          begin
            CI := ScanOrder[SI];
            BY := 0;
            while BY < Comps[CI].V do
            begin
              BX := 0;
              while BX < Comps[CI].H do
              begin
                DecodeOneBlock(CI, MX * Integer(Comps[CI].H) + BX,
                  MY * Integer(Comps[CI].V) + BY);
                Inc(BX);
              end;
              Inc(BY);
            end;
            Inc(SI);
          end;
          FinishMCU;
          Inc(MX);
        end;
        Inc(MY);
      end;
    end;

    BR.BitsLeft := 0;
    EntropyPos := BR.Pos;

    if Progressive then
      CommitProgressiveState
    else
    begin
      SI := 0;
      while SI < ScanComp do
      begin
        BaselineSeen[ScanOrder[SI]] := True;
        Inc(SI);
      end;
    end;
    ScanSeen := True;
  end;

  procedure RenderImage;
  var
    Planes: array[0..3] of TBytes;
    PlaneW, PlaneH: array[0..3] of Integer;
    CI, BX, BY, BI, K, X, Y: Integer;
    Deq: TCoeffBlock;
    Block: TSampleBlock;
    C: TRGBA;
    C0, C1, C2, C3: Integer;
    CIdx, MIdx, YInkIdx, KIdx, RIdx, GIdx, BIdx, YIdx, CbIdx, CrIdx: Integer;
    RGBDirect: Boolean;
    Temp: TRGBA;
    ScaleH, ScaleV: array[0..3] of Integer;

    function SampleAt(ACI, AX, AY: Integer): Integer;
    var
      ASX, ASY: Integer;
    begin
      ASX := (AX * ScaleH[ACI]) div Integer(HMax);
      ASY := (AY * ScaleV[ACI]) div Integer(VMax);
      if ASX < 0 then ASX := 0 else if ASX >= PlaneW[ACI] then ASX := PlaneW[ACI] - 1;
      if ASY < 0 then ASY := 0 else if ASY >= PlaneH[ACI] then ASY := PlaneH[ACI] - 1;
      Result := Planes[ACI][ASY * PlaneW[ACI] + ASX];
    end;

    // libjpeg-turbo jdsample.c "fancy" upsampling (triangle filter) for the
    // 2x1, 1x2 and 2x2 ratios, with its rounding biases and edge handling:
    // samples beyond the downsampled size replicate the last real ones.
    // Other ratios keep plain replication (int_upsample), as libjpeg does.
    procedure FancyUpsample(ACI: Integer);
    var
      DW, DH, IW, OW, OH, X, Y, R, V, Nr, Bias: Integer;
      Hx, Vx: Boolean;
      Src, Dst: TBytes;
      ColSum: array of Integer;

      function In_(AX, AY: Integer): Integer; inline;
      begin
        Result := Src[AY * IW + AX];
      end;

    begin
      Hx := (Integer(Comps[ACI].H) * 2 = Integer(HMax)) and
            ((Integer(Comps[ACI].V) = Integer(VMax)) or (Integer(Comps[ACI].V) * 2 = Integer(VMax)));
      Vx := (Integer(Comps[ACI].V) * 2 = Integer(VMax)) and
            ((Integer(Comps[ACI].H) = Integer(HMax)) or (Integer(Comps[ACI].H) * 2 = Integer(HMax)));
      if not (Hx or Vx) then Exit;
      // downsampled_width / _height
      DW := (Integer(JpegWidth) * Integer(Comps[ACI].H) + Integer(HMax) - 1) div Integer(HMax);
      DH := (Integer(JpegHeight) * Integer(Comps[ACI].V) + Integer(VMax) - 1) div Integer(VMax);
      if Hx and (DW <= 2) then Exit;   // libjpeg: fancy only when width > 2
      Src := Planes[ACI];
      IW := PlaneW[ACI];
      if Hx then OW := DW * 2 else OW := PlaneW[ACI];
      if Vx then OH := DH * 2 else OH := PlaneH[ACI];
      SetLength(Dst, OW * OH);
      SetLength(ColSum, IW);
      if Hx and not Vx then
      begin
        // h2v1_fancy_upsample
        for Y := 0 to OH - 1 do
        begin
          R := Y * OW;
          Dst[R] := In_(0, Y);
          Dst[R + 1] := (In_(0, Y) * 3 + In_(1, Y) + 2) shr 2;
          for X := 1 to DW - 2 do
          begin
            Dst[R + 2 * X] := (In_(X, Y) * 3 + In_(X - 1, Y) + 1) shr 2;
            Dst[R + 2 * X + 1] := (In_(X, Y) * 3 + In_(X + 1, Y) + 2) shr 2;
          end;
          X := DW - 1;
          Dst[R + 2 * X] := (In_(X, Y) * 3 + In_(X - 1, Y) + 1) shr 2;
          Dst[R + 2 * X + 1] := In_(X, Y);
        end;
      end
      else
        for Y := 0 to DH - 1 do
          for V := 0 to 1 do
          begin
            // context row: above for the upper output row, below for the lower
            if V = 0 then Nr := Max(0, Y - 1) else Nr := Min(DH - 1, Y + 1);
            R := (2 * Y + V) * OW;
            if not Hx then
            begin
              // h1v2_fancy_upsample (libjpeg-turbo)
              if V = 0 then Bias := 1 else Bias := 2;
              for X := 0 to OW - 1 do
                Dst[R + X] := (In_(X, Y) * 3 + In_(X, Nr) + Bias) shr 2;
            end
            else
            begin
              // h2v2_fancy_upsample
              for X := 0 to DW - 1 do
                ColSum[X] := In_(X, Y) * 3 + In_(X, Nr);
              Dst[R] := (ColSum[0] * 4 + 8) shr 4;
              Dst[R + 1] := (ColSum[0] * 3 + ColSum[1] + 7) shr 4;
              for X := 1 to DW - 2 do
              begin
                Dst[R + 2 * X] := (ColSum[X] * 3 + ColSum[X - 1] + 8) shr 4;
                Dst[R + 2 * X + 1] := (ColSum[X] * 3 + ColSum[X + 1] + 7) shr 4;
              end;
              X := DW - 1;
              Dst[R + 2 * X] := (ColSum[X] * 3 + ColSum[X - 1] + 8) shr 4;
              Dst[R + 2 * X + 1] := (ColSum[X] * 4 + 7) shr 4;
            end;
          end;
      Planes[ACI] := Dst;
      PlaneW[ACI] := OW;
      PlaneH[ACI] := OH;
      if Hx then ScaleH[ACI] := Integer(HMax);
      if Vx then ScaleV[ACI] := Integer(VMax);
    end;

  begin
    if not ScanSeen then raise EJpegError.Create('JPEG: no image scan found');
    CI := 0;
    while CI < NComp do
    begin
      if not CompQValid[CI] then raise EJpegError.Create('JPEG: component has no quantization table');
      // a component whose scan is missing (truncated file) stays flat grey,
      // as libjpeg shows it

      PlaneW[CI] := CoeffW[CI] * 8;
      PlaneH[CI] := CoeffH[CI] * 8;
      if Int64(PlaneW[CI]) * Int64(PlaneH[CI]) > MaxInt then
        raise EJpegError.Create('JPEG: sample plane too large');
      SetLength(Planes[CI], PlaneW[CI] * PlaneH[CI]);
      BY := 0;
      while BY < CoeffH[CI] do
      begin
        BX := 0;
        while BX < CoeffW[CI] do
        begin
          BI := BY * CoeffW[CI] + BX;
          K := 0;
          while K < 64 do
          begin
            Deq[K] := Coeffs[CI][BI][K] * Integer(CompQ[CI][K]);
            Inc(K);
          end;
          InverseDCT(Deq, Block);
          PutBlockInPlane(Planes[CI], PlaneW[CI], BX, BY, Block);
          Inc(BX);
        end;
        Inc(BY);
      end;
      ScaleH[CI] := Comps[CI].H;
      ScaleV[CI] := Comps[CI].V;
      FancyUpsample(CI);
      Inc(CI);
    end;

    Width := Integer(JpegWidth);
    Height := Integer(JpegHeight);
    if UInt64(JpegWidth) * UInt64(JpegHeight) * 4 > UInt64(High(NativeInt)) then
      raise EJpegError.Create('JPEG: image too large');
    SetLength(Result, NativeInt(UInt64(JpegWidth) * UInt64(JpegHeight) * 4));

    RIdx := 0; GIdx := 1; BIdx := 2;
    YIdx := 0; CbIdx := 1; CrIdx := 2;
    CIdx := 0; MIdx := 1; YInkIdx := 2; KIdx := 3;
    RGBDirect := False;

    if NComp = 3 then
    begin
      if AdobeTransform = 0 then RGBDirect := True;
      if (Comps[0].Id = Ord('R')) and (Comps[1].Id = Ord('G')) and
         (Comps[2].Id = Ord('B')) then RGBDirect := True;
      Idx := FindComponent(Comps, NComp, Ord('R')); if Idx >= 0 then RIdx := Idx;
      Idx := FindComponent(Comps, NComp, Ord('G')); if Idx >= 0 then GIdx := Idx;
      Idx := FindComponent(Comps, NComp, Ord('B')); if Idx >= 0 then BIdx := Idx;
      // Y, Cb, Cr are the components in frame order, whatever their ids
      // (libjpeg does the same; ids 0,1,2 are common)
    end
    else if NComp = 4 then
    begin
      Idx := FindComponent(Comps, NComp, Ord('C')); if Idx >= 0 then CIdx := Idx;
      Idx := FindComponent(Comps, NComp, Ord('M')); if Idx >= 0 then MIdx := Idx;
      Idx := FindComponent(Comps, NComp, Ord('Y')); if Idx >= 0 then YInkIdx := Idx;
      Idx := FindComponent(Comps, NComp, Ord('K')); if Idx >= 0 then KIdx := Idx;
      // YCCK: Y, Cb, Cr, K in frame order, whatever their ids
    end;

    Y := 0;
    while Y < Integer(JpegHeight) do
    begin
      X := 0;
      while X < Integer(JpegWidth) do
      begin
        if NComp = 1 then
        begin
          C0 := SampleAt(0, X, Y);
          C.R := Byte(C0); C.G := Byte(C0); C.B := Byte(C0); C.A := 255;
        end
        else if NComp = 3 then
        begin
          if RGBDirect then
          begin
            C.R := Byte(SampleAt(RIdx, X, Y));
            C.G := Byte(SampleAt(GIdx, X, Y));
            C.B := Byte(SampleAt(BIdx, X, Y));
            C.A := 255;
          end
          else
          begin
            C0 := SampleAt(YIdx, X, Y);
            C1 := SampleAt(CbIdx, X, Y);
            C2 := SampleAt(CrIdx, X, Y);
            YCbCrToRGB(C0, C1, C2, C);
          end;
        end
        else
        begin
          if AdobeTransform = 2 then
          begin
            C0 := SampleAt(YIdx, X, Y);
            C1 := SampleAt(CbIdx, X, Y);
            C2 := SampleAt(CrIdx, X, Y);
            C3 := SampleAt(KIdx, X, Y);
            YCbCrToRGB(C0, C1, C2, Temp);
            // Adobe YCCK (libjpeg ycck_cmyk_convert): the stored CMYK is
            // inverted, as for transform 0; YCbCr gives R' with
            // C_stored = 255 - R', and K is stored inverted too. So
            // RGB = C_stored * K_stored / 255 = (255 - R') * K / 255.
            C.R := Mul255(255 - Integer(Temp.R), C3);
            C.G := Mul255(255 - Integer(Temp.G), C3);
            C.B := Mul255(255 - Integer(Temp.B), C3);
            C.A := 255;
          end
          else if AdobeTransform = 0 then
          begin
            C0 := SampleAt(CIdx, X, Y);
            C1 := SampleAt(MIdx, X, Y);
            C2 := SampleAt(YInkIdx, X, Y);
            C3 := SampleAt(KIdx, X, Y);
            // Adobe CMYK stores inverted C/M/Y/K samples.
            C.R := Mul255(C0, C3);
            C.G := Mul255(C1, C3);
            C.B := Mul255(C2, C3);
            C.A := 255;
          end
          else if AdobeTransform < 0 then
          begin
            C0 := SampleAt(CIdx, X, Y);
            C1 := SampleAt(MIdx, X, Y);
            C2 := SampleAt(YInkIdx, X, Y);
            C3 := SampleAt(KIdx, X, Y);
            // Fallback for non-Adobe device CMYK (0 = no ink, 255 = full ink).
            C.R := Mul255(255 - C0, 255 - C3);
            C.G := Mul255(255 - C1, 255 - C3);
            C.B := Mul255(255 - C2, 255 - C3);
            C.A := 255;
          end
          else
            raise EJpegError.CreateFmt('JPEG: unsupported Adobe color transform %d', [AdobeTransform]);
        end;
        SetPx(Result, Integer(JpegWidth), X, Y, C);
        Inc(X);
      end;
      Inc(Y);
    end;
  end;

begin
  Width := 0;
  Height := 0;
  SetLength(Result, 0);
  FillChar(QValid, SizeOf(QValid), 0);
  FillChar(CompQValid, SizeOf(CompQValid), 0);
  FillChar(HDc, SizeOf(HDc), 0);
  FillChar(HAc, SizeOf(HAc), 0);
  FillChar(Comps, SizeOf(Comps), 0);
  FillChar(BaselineSeen, SizeOf(BaselineSeen), 0);
  FillChar(CoeffState, SizeOf(CoeffState), $FF);
  JpegWidth := 0;
  JpegHeight := 0;
  NComp := 0;
  HMax := 0;
  VMax := 0;
  RestartInterval := 0;
  AdobeTransform := -1;
  FrameSeen := False;
  ScanSeen := False;
  Progressive := False;
  FrameMCUCols := 0;
  FrameMCURows := 0;
  ScanCount := 0;

  if Length(InBuf) < 4 then raise EJpegError.Create('JPEG: file too short');
  if (InBuf[0] <> $FF) or (InBuf[1] <> M_SOI) then
    raise EJpegError.Create('JPEG: SOI marker not found');
  Pos := 2;

  while Pos < NativeUInt(Length(InBuf)) do
  begin
    if ScanSeen then
    begin
      // after image data a missing EOI or a truncated tail ends the image
      if not FindMarker(InBuf, Pos, Marker) then Break;
    end
    else
      Marker := NextMarker(InBuf, Pos);
    if Marker = M_EOI then Break;
    if Marker = M_SOI then Continue;
    if (Marker >= $D0) and (Marker <= $D7) then Continue;
    if Marker = $01 then Continue;

    if ScanSeen and (Pos + 2 > NativeUInt(Length(InBuf))) then Break;
    SegLen := ReadBE16(InBuf, Pos);
    if SegLen < 2 then raise EJpegError.Create('JPEG: invalid segment length');
    Inc(Pos, 2);
    SegEnd := Pos + SegLen - 2;
    if SegEnd > NativeUInt(Length(InBuf)) then
    begin
      if ScanSeen then Break;
      raise EJpegError.Create('JPEG: truncated segment');
    end;

    case Marker of
      M_APP14:
        begin
          if (SegEnd - Pos >= 12) and
             (InBuf[Pos] = Ord('A')) and (InBuf[Pos+1] = Ord('d')) and
             (InBuf[Pos+2] = Ord('o')) and (InBuf[Pos+3] = Ord('b')) and
             (InBuf[Pos+4] = Ord('e')) then
            AdobeTransform := InBuf[Pos + 11];
        end;

      M_DQT:
        begin
          P := Pos;
          while P < SegEnd do
          begin
            Info := InBuf[P];
            Inc(P);
            Pq := Info shr 4;
            Tq := Info and $0F;
            if Tq > 3 then raise EJpegError.Create('JPEG: invalid quantization table id');
            if (Pq <> 0) and (Pq <> 1) then
              raise EJpegError.Create('JPEG: unsupported quantization precision');
            I := 0;
            while I < 64 do
            begin
              if Pq = 0 then
              begin
                Need(InBuf, P, 1);
                QTables[Tq][ZigZag[I]] := InBuf[P];
                Inc(P);
              end
              else
              begin
                Need(InBuf, P, 2);
                QTables[Tq][ZigZag[I]] := ReadBE16(InBuf, P);
                Inc(P, 2);
              end;
              Inc(I);
            end;
            QValid[Tq] := True;
          end;
          if P <> SegEnd then raise EJpegError.Create('JPEG: malformed DQT segment');
        end;

      M_DHT:
        begin
          P := Pos;
          while P < SegEnd do
          begin
            Info := InBuf[P];
            Inc(P);
            Tc := Info shr 4;
            Th := Info and $0F;
            if (Tc > 1) or (Th > 3) then raise EJpegError.Create('JPEG: invalid Huffman table id');
            ValCount := 0;
            I := 0;
            while I < 16 do
            begin
              if P >= SegEnd then raise EJpegError.Create('JPEG: truncated DHT');
              Counts[I] := InBuf[P];
              Inc(P);
              Inc(ValCount, Counts[I]);
              Inc(I);
            end;
            if ValCount > 256 then raise EJpegError.Create('JPEG: invalid DHT symbol count');
            if P + NativeUInt(ValCount) > SegEnd then raise EJpegError.Create('JPEG: truncated DHT symbols');
            I := 0;
            while I < NativeUInt(ValCount) do
            begin
              Values[I] := InBuf[P + I];
              Inc(I);
            end;
            Inc(P, ValCount);
            if Tc = 0 then BuildHuffDec(HDc[Th], Counts, Values)
            else BuildHuffDec(HAc[Th], Counts, Values);
          end;
          if P <> SegEnd then raise EJpegError.Create('JPEG: malformed DHT segment');
        end;

      M_DRI:
        begin
          if SegEnd - Pos <> 2 then raise EJpegError.Create('JPEG: malformed DRI');
          RestartInterval := ReadBE16(InBuf, Pos);
        end;

      M_SOF0, M_SOF2:
        begin
          if FrameSeen then raise EJpegError.Create('JPEG: multiple frames are not supported');
          if SegEnd - Pos < 6 then raise EJpegError.Create('JPEG: truncated SOF');
          Progressive := Marker = M_SOF2;
          Precision := InBuf[Pos];
          JpegHeight := ReadBE16(InBuf, Pos + 1);
          JpegWidth := ReadBE16(InBuf, Pos + 3);
          NComp := InBuf[Pos + 5];
          if Precision <> 8 then raise EJpegError.Create('JPEG: only 8-bit sample precision is supported');
          if (JpegWidth = 0) or (JpegHeight = 0) then raise EJpegError.Create('JPEG: invalid image size');
          if (NComp <> 1) and (NComp <> 3) and (NComp <> 4) then
            raise EJpegError.CreateFmt('JPEG: unsupported component count %d', [NComp]);
          if SegEnd - (Pos + 6) <> NativeUInt(NComp * 3) then
            raise EJpegError.Create('JPEG: malformed SOF');
          HMax := 0;
          VMax := 0;
          I := 0;
          P := Pos + 6;
          while I < NativeUInt(NComp) do
          begin
            if FindComponent(Comps, Integer(I), InBuf[P]) >= 0 then
              raise EJpegError.Create('JPEG: duplicate component id');
            Comps[I].Id := InBuf[P];
            Info := InBuf[P + 1];
            Comps[I].H := Info shr 4;
            Comps[I].V := Info and $0F;
            Comps[I].QTable := InBuf[P + 2];
            if (Comps[I].H = 0) or (Comps[I].V = 0) or
               (Comps[I].H > 4) or (Comps[I].V > 4) then
              raise EJpegError.Create('JPEG: invalid sampling factor');
            if Comps[I].H > HMax then HMax := Comps[I].H;
            if Comps[I].V > VMax then VMax := Comps[I].V;
            Inc(P, 3);
            Inc(I);
          end;
          if (HMax = 0) or (VMax = 0) then raise EJpegError.Create('JPEG: invalid sampling factors');
          FrameSeen := True;
          AllocateFrameStorage;
        end;

      M_SOS:
        begin
          if not FrameSeen then raise EJpegError.Create('JPEG: SOS before SOF');
          Inc(ScanCount);
          if ScanCount > 1024 then raise EJpegError.Create('JPEG: too many scans');
          if Pos >= SegEnd then raise EJpegError.Create('JPEG: truncated SOS');
          ScanComp := InBuf[Pos];
          Inc(Pos);
          if (ScanComp < 1) or (ScanComp > NComp) then raise EJpegError.Create('JPEG: invalid scan component count');
          if Pos + NativeUInt(ScanComp * 2 + 3) <> SegEnd then
            raise EJpegError.Create('JPEG: malformed SOS');
          I := 0;
          while I < NativeUInt(ScanComp) do
          begin
            Idx := FindComponent(Comps, NComp, InBuf[Pos]);
            if Idx < 0 then raise EJpegError.Create('JPEG: SOS references unknown component');
            P := 0;
            while P < I do
            begin
              if ScanOrder[P] = Idx then raise EJpegError.Create('JPEG: duplicate scan component');
              Inc(P);
            end;
            ScanOrder[I] := Idx;
            Info := InBuf[Pos + 1];
            Comps[Idx].DCTable := Info shr 4;
            Comps[Idx].ACTable := Info and $0F;
            if (Comps[Idx].DCTable > 3) or (Comps[Idx].ACTable > 3) then
              raise EJpegError.Create('JPEG: invalid Huffman selector');
            Inc(Pos, 2);
            Inc(I);
          end;
          Ss := InBuf[Pos];
          Se := InBuf[Pos + 1];
          Ah := InBuf[Pos + 2] shr 4;
          Al := InBuf[Pos + 2] and $0F;
          Inc(Pos, 3);
          if Pos <> SegEnd then raise EJpegError.Create('JPEG: malformed SOS');
          Pos := SegEnd;
          DecodeScan(Pos);
          Continue;
        end;
    end;

    Pos := SegEnd;
  end;

  if not FrameSeen then raise EJpegError.Create('JPEG: frame header not found');
  RenderImage;
end;

procedure WriteStuffedByte(var OutData: TBytes; B: Byte); inline;
begin
  AppendByte(OutData, B);
  if B = $FF then AppendByte(OutData, $00);
end;

procedure PutBit(var OutData: TBytes; var BW: TBitWriter; B: Integer); inline;
begin
  BW.Cur := Byte((BW.Cur shl 1) or (B and 1));
  Inc(BW.BitsUsed);
  if BW.BitsUsed = 8 then
  begin
    WriteStuffedByte(OutData, BW.Cur);
    BW.Cur := 0;
    BW.BitsUsed := 0;
  end;
end;

procedure PutBits(var OutData: TBytes; var BW: TBitWriter; V: Cardinal; N: Integer);
var
  I: Integer;
begin
  I := N - 1;
  while I >= 0 do
  begin
    PutBit(OutData, BW, (V shr I) and 1);
    Dec(I);
  end;
end;

procedure FlushBits(var OutData: TBytes; var BW: TBitWriter);
begin
  while BW.BitsUsed <> 0 do PutBit(OutData, BW, 1);
end;

procedure EmitHuff(var OutData: TBytes; var BW: TBitWriter;
  const H: THuffEnc; Symbol: Byte);
begin
  if H.Size[Symbol] = 0 then raise EJpegError.Create('JPEG: no Huffman code for symbol');
  PutBits(OutData, BW, H.Code[Symbol], H.Size[Symbol]);
end;

function MagnitudeCategory(V: Integer): Integer;
var
  A: Cardinal;
begin
  if V = 0 then
  begin
    Result := 0;
    Exit;
  end;
  if V < 0 then A := Cardinal(-Int64(V)) else A := Cardinal(V);
  Result := 0;
  while A <> 0 do
  begin
    Inc(Result);
    A := A shr 1;
  end;
end;

function MagnitudeBits(V, N: Integer): Cardinal;
begin
  if N = 0 then Result := 0
  else if V >= 0 then Result := Cardinal(V)
  else Result := Cardinal(V + (1 shl N) - 1);
end;

procedure EncodeBlock(var OutData: TBytes; var BW: TBitWriter;
  const Samples: TSampleBlock; const Q: TQuantTable; var PrevDC: Integer;
  const HDc, HAc: THuffEnc);
var
  C: TCoeffBlock;
  Diff, Cat, K, Run, V: Integer;
  Sym: Byte;
begin
  ForwardDCT(Samples, Q, C);

  Diff := C[0] - PrevDC;
  PrevDC := C[0];
  Cat := MagnitudeCategory(Diff);
  EmitHuff(OutData, BW, HDc, Byte(Cat));
  if Cat <> 0 then PutBits(OutData, BW, MagnitudeBits(Diff, Cat), Cat);

  Run := 0;
  K := 1;
  while K < 64 do
  begin
    V := C[ZigZag[K]];
    if V = 0 then
    begin
      Inc(Run);
    end
    else
    begin
      while Run >= 16 do
      begin
        EmitHuff(OutData, BW, HAc, $F0);
        Dec(Run, 16);
      end;
      Cat := MagnitudeCategory(V);
      if Cat > 10 then
        raise EJpegError.Create('JPEG: AC coefficient outside baseline Huffman range');
      Sym := Byte((Run shl 4) or Cat);
      EmitHuff(OutData, BW, HAc, Sym);
      PutBits(OutData, BW, MagnitudeBits(V, Cat), Cat);
      Run := 0;
    end;
    Inc(K);
  end;
  if Run <> 0 then EmitHuff(OutData, BW, HAc, $00);
end;

procedure RGBToYCbCr(const C: TRGBA; var Yv, Cb, Cr: Byte); inline;
var
  YY, BB, RR: Integer;
begin
  YY := Round(0.29900 * C.R + 0.58700 * C.G + 0.11400 * C.B);
  BB := Round(-0.168736 * C.R - 0.331264 * C.G + 0.50000 * C.B + 128.0);
  RR := Round(0.50000 * C.R - 0.418688 * C.G - 0.081312 * C.B + 128.0);
  Yv := ClampByte(YY);
  Cb := ClampByte(BB);
  Cr := ClampByte(RR);
end;

function PixelClamped(const InBuf: TBytes; Width, Height, X, Y: Integer): TRGBA; inline;
begin
  if X < 0 then X := 0;
  if Y < 0 then Y := 0;
  if X >= Width then X := Width - 1;
  if Y >= Height then Y := Height - 1;
  Result := GetPx(InBuf, Width, X, Y);
end;

procedure Make444Blocks(const InBuf: TBytes; Width, Height, BaseX, BaseY: Integer;
  var YB, CbB, CrB: TSampleBlock);
var
  X, Y, P: Integer;
  C: TRGBA;
  Yv, Cb, Cr: Byte;
begin
  Y := 0;
  while Y < 8 do
  begin
    X := 0;
    while X < 8 do
    begin
      C := PixelClamped(InBuf, Width, Height, BaseX + X, BaseY + Y);
      RGBToYCbCr(C, Yv, Cb, Cr);
      P := Y * 8 + X;
      YB[P] := Yv;
      CbB[P] := Cb;
      CrB[P] := Cr;
      Inc(X);
    end;
    Inc(Y);
  end;
end;

procedure Make420YBlock(const InBuf: TBytes; Width, Height, BaseX, BaseY, BlockX, BlockY: Integer;
  var YB: TSampleBlock);
var
  X, Y, P: Integer;
  C: TRGBA;
  Yv, Cb, Cr: Byte;
begin
  Y := 0;
  while Y < 8 do
  begin
    X := 0;
    while X < 8 do
    begin
      C := PixelClamped(InBuf, Width, Height, BaseX + BlockX * 8 + X, BaseY + BlockY * 8 + Y);
      RGBToYCbCr(C, Yv, Cb, Cr);
      P := Y * 8 + X;
      YB[P] := Yv;
      Inc(X);
    end;
    Inc(Y);
  end;
end;

procedure Make420ChromaBlocks(const InBuf: TBytes; Width, Height, BaseX, BaseY: Integer;
  var CbB, CrB: TSampleBlock);
var
  X, Y, DX, DY, SumCb, SumCr, P: Integer;
  C: TRGBA;
  Yv, Cb, Cr: Byte;
begin
  Y := 0;
  while Y < 8 do
  begin
    X := 0;
    while X < 8 do
    begin
      SumCb := 0;
      SumCr := 0;
      DY := 0;
      while DY < 2 do
      begin
        DX := 0;
        while DX < 2 do
        begin
          C := PixelClamped(InBuf, Width, Height, BaseX + X * 2 + DX, BaseY + Y * 2 + DY);
          RGBToYCbCr(C, Yv, Cb, Cr);
          Inc(SumCb, Cb);
          Inc(SumCr, Cr);
          Inc(DX);
        end;
        Inc(DY);
      end;
      P := Y * 8 + X;
      CbB[P] := Byte((SumCb + 2) div 4);
      CrB[P] := Byte((SumCr + 2) div 4);
      Inc(X);
    end;
    Inc(Y);
  end;
end;

procedure MakeQuantTables(Quality: Integer; var LQ, CQ: TQuantTable);
var
  Scale, I, V: Integer;
begin
  if Quality < 1 then Quality := 1;
  if Quality > 100 then Quality := 100;
  if Quality < 50 then Scale := 5000 div Quality
  else Scale := 200 - Quality * 2;
  I := 0;
  while I < 64 do
  begin
    V := (Integer(StdLumQ[I]) * Scale + 50) div 100;
    if V < 1 then V := 1 else if V > 255 then V := 255;
    LQ[I] := V;
    V := (Integer(StdChrQ[I]) * Scale + 50) div 100;
    if V < 1 then V := 1 else if V > 255 then V := 255;
    CQ[I] := V;
    Inc(I);
  end;
end;

procedure WriteAPP0(var A: TBytes);
begin
  AppendMarker(A, M_APP0);
  AppendBE16(A, 16);
  AppendByte(A, Ord('J')); AppendByte(A, Ord('F')); AppendByte(A, Ord('I'));
  AppendByte(A, Ord('F')); AppendByte(A, 0);
  AppendByte(A, 1); AppendByte(A, 1);
  AppendByte(A, 0);
  AppendBE16(A, 1); AppendBE16(A, 1);
  AppendByte(A, 0); AppendByte(A, 0);
end;

procedure WriteDQT(var A: TBytes; const LQ, CQ: TQuantTable);
var
  I: Integer;
begin
  AppendMarker(A, M_DQT);
  AppendBE16(A, 132);
  AppendByte(A, 0);
  I := 0;
  while I < 64 do
  begin
    AppendByte(A, Byte(LQ[ZigZag[I]]));
    Inc(I);
  end;
  AppendByte(A, 1);
  I := 0;
  while I < 64 do
  begin
    AppendByte(A, Byte(CQ[ZigZag[I]]));
    Inc(I);
  end;
end;

procedure WriteSOF0(var A: TBytes; W, H: Word; Subsample420: Boolean);
begin
  AppendMarker(A, M_SOF0);
  AppendBE16(A, 17);
  AppendByte(A, 8);
  AppendBE16(A, H);
  AppendBE16(A, W);
  AppendByte(A, 3);
  AppendByte(A, 1);
  if Subsample420 then AppendByte(A, $22) else AppendByte(A, $11);
  AppendByte(A, 0);
  AppendByte(A, 2); AppendByte(A, $11); AppendByte(A, 1);
  AppendByte(A, 3); AppendByte(A, $11); AppendByte(A, 1);
end;

procedure WriteDHTTable(var A: TBytes; ClassId, TableId: Byte;
  const Counts: array of Byte; const Values: array of Byte);
var
  I, N: Integer;
begin
  N := 0;
  I := 0;
  while I < 16 do
  begin
    Inc(N, Counts[I]);
    Inc(I);
  end;
  AppendMarker(A, M_DHT);
  AppendBE16(A, Word(2 + 1 + 16 + N));
  AppendByte(A, Byte((ClassId shl 4) or TableId));
  I := 0;
  while I < 16 do
  begin
    AppendByte(A, Counts[I]);
    Inc(I);
  end;
  I := 0;
  while I < N do
  begin
    AppendByte(A, Values[I]);
    Inc(I);
  end;
end;

procedure WriteSOS(var A: TBytes);
begin
  AppendMarker(A, M_SOS);
  AppendBE16(A, 12);
  AppendByte(A, 3);
  AppendByte(A, 1); AppendByte(A, $00);
  AppendByte(A, 2); AppendByte(A, $11);
  AppendByte(A, 3); AppendByte(A, $11);
  AppendByte(A, 0); AppendByte(A, 63); AppendByte(A, 0);
end;

function EncodeJpeg(InBuf: TBytes; Width, Height: Integer; Quality: Integer): TBytes;
const
  Subsample420 = True;
var
  LQ, CQ: TQuantTable;
  EDcL, EAcL, EDcC, EAcC: THuffEnc;
  BW: TBitWriter;
  PrevY, PrevCb, PrevCr: Integer;
  YB, CbB, CrB: TSampleBlock;
  MX, MY, MCUCols, MCURows, BaseX, BaseY, BX, BY: Integer;
  MCUSize: Integer;
begin
  SetLength(Result, 0);
  if Quality <= 0 then Quality := 90;
  if (Width <= 0) or (Height <= 0) then
    raise EJpegError.Create('JPEG: empty image');
  if (Width > 65535) or (Height > 65535) then
    raise EJpegError.Create('JPEG: baseline dimensions exceed 65535');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EJpegError.Create('JPEG: RGBA8 buffer size does not match Width*Height*4');
  MakeQuantTables(Quality, LQ, CQ);
  BuildHuffEnc(EDcL, BitsDcLum, ValDcLum);
  BuildHuffEnc(EAcL, BitsAcLum, ValAcLum);
  BuildHuffEnc(EDcC, BitsDcChr, ValDcChr);
  BuildHuffEnc(EAcC, BitsAcChr, ValAcChr);

  AppendMarker(Result, M_SOI);
  WriteAPP0(Result);
  WriteDQT(Result, LQ, CQ);
  WriteSOF0(Result, Word(Width), Word(Height), Subsample420);
  WriteDHTTable(Result, 0, 0, BitsDcLum, ValDcLum);
  WriteDHTTable(Result, 1, 0, BitsAcLum, ValAcLum);
  WriteDHTTable(Result, 0, 1, BitsDcChr, ValDcChr);
  WriteDHTTable(Result, 1, 1, BitsAcChr, ValAcChr);
  WriteSOS(Result);

  BW.Cur := 0;
  BW.BitsUsed := 0;
  PrevY := 0;
  PrevCb := 0;
  PrevCr := 0;

  if Subsample420 then MCUSize := 16 else MCUSize := 8;
  MCUCols := (Integer(Width) + MCUSize - 1) div MCUSize;
  MCURows := (Integer(Height) + MCUSize - 1) div MCUSize;

  MY := 0;
  while MY < MCURows do
  begin
    MX := 0;
    while MX < MCUCols do
    begin
      BaseX := MX * MCUSize;
      BaseY := MY * MCUSize;
      if Subsample420 then
      begin
        BY := 0;
        while BY < 2 do
        begin
          BX := 0;
          while BX < 2 do
          begin
            Make420YBlock(InBuf, Width, Height, BaseX, BaseY, BX, BY, YB);
            EncodeBlock(Result, BW, YB, LQ, PrevY, EDcL, EAcL);
            Inc(BX);
          end;
          Inc(BY);
        end;
        Make420ChromaBlocks(InBuf, Width, Height, BaseX, BaseY, CbB, CrB);
        EncodeBlock(Result, BW, CbB, CQ, PrevCb, EDcC, EAcC);
        EncodeBlock(Result, BW, CrB, CQ, PrevCr, EDcC, EAcC);
      end
      else
      begin
        Make444Blocks(InBuf, Width, Height, BaseX, BaseY, YB, CbB, CrB);
        EncodeBlock(Result, BW, YB, LQ, PrevY, EDcL, EAcL);
        EncodeBlock(Result, BW, CbB, CQ, PrevCb, EDcC, EAcC);
        EncodeBlock(Result, BW, CrB, CQ, PrevCr, EDcC, EAcC);
      end;
      Inc(MX);
    end;
    Inc(MY);
  end;

  FlushBits(Result, BW);
  AppendMarker(Result, M_EOI);
end;

end.
