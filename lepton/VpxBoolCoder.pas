unit VpxBoolCoder;

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//

{$mode delphi}
{$H+}
{$R-}
{$Q-}

interface

uses
  Classes, SysUtils, LeptonErrors, LeptonBranch;

type
  TVpxBoolWriter = class
  private
    FLowValue: QWord;
    FRange: LongWord;
    FWriter: TStream;
    FOwnsStream: Boolean;
    FBuffer: TBytes;
    FLen: SizeInt;
    procedure EnsureCapacity(Needed: SizeInt);
    procedure AppendByte(B: Byte); inline;
    procedure AppendSixBytesBE(V: QWord);
    procedure Carry;
  public
    constructor Create(AWriter: TStream; AOwnsStream: Boolean = False);
    destructor Destroy; override;
    procedure PutRaw(Bit: Boolean; var Branch: TLeptonBranch; var TmpValue: QWord; var TmpRange: LongWord);
    procedure PutBit(Bit: Boolean; var Branch: TLeptonBranch);
    procedure PutGrid(V: Byte; var Branches: array of TLeptonBranch; A: SizeInt);
    procedure PutNBits(Bits, NumBits: SizeInt; var Branches: array of TLeptonBranch);
    procedure PutUnaryEncoded(V: SizeInt; var Branches: array of TLeptonBranch);
    procedure FlushNonFinalData;
    procedure Finish;
    property BufferedBytes: SizeInt read FLen;
  end;

  TVpxBoolReader = class
  private
    FValue: QWord;
    FRange: QWord;
    FReader: TStream;
    FOwnsStream: Boolean;
    class function VpxReaderFill(TmpValue: QWord; UpstreamReader: TStream): QWord; static;
  public
    constructor Create(AReader: TStream; AOwnsStream: Boolean = False);
    destructor Destroy; override;
    function GetRaw(var Branch: TLeptonBranch; var TmpValue, TmpRange: QWord): Boolean;
    function GetBit(var Branch: TLeptonBranch): Boolean;
    function GetGrid(var Branches: array of TLeptonBranch; A: SizeInt): SizeInt;
    function GetUnaryEncoded(var Branches: array of TLeptonBranch): SizeInt;
    function GetNBits(N: SizeInt; var Branches: array of TLeptonBranch): SizeInt;
  end;

implementation

const
  BITS_IN_VALUE_MINUS_LAST_BYTE = 56;
  VALUE_MASK = (QWord(1) shl BITS_IN_VALUE_MINUS_LAST_BYTE) - 1;

function LeadingZeros8(V: Byte): LongWord; inline;
var
  I: Integer;
begin
  if V = 0 then
    Exit(8);
  Result := 0;
  for I := 7 downto 0 do
  begin
    if (V and (1 shl I)) <> 0 then
      Break;
    Inc(Result);
  end;
end;

function LeadingZeros64(V: QWord): LongWord; inline;
var
  I: Integer;
begin
  if V = 0 then
    Exit(64);
  Result := 0;
  for I := 63 downto 0 do
  begin
    if (V and (QWord(1) shl I)) <> 0 then
      Break;
    Inc(Result);
  end;
end;

function TrailingZeros64(V: QWord): LongWord; inline;
var
  I: Integer;
begin
  if V = 0 then
    Exit(64);
  Result := 0;
  for I := 0 to 63 do
  begin
    if (V and (QWord(1) shl I)) <> 0 then
      Break;
    Inc(Result);
  end;
end;

function RotL64(V: QWord; Bits: LongWord): QWord; inline;
begin
  Bits := Bits and 63;
  if Bits = 0 then
    Result := V
  else
    Result := (V shl Bits) or (V shr (64 - Bits));
end;

function IsPowerOfTwo(V: SizeInt): Boolean; inline;
begin
  Result := (V > 0) and ((V and (V - 1)) = 0);
end;

function ILog2PowerOfTwo(V: SizeInt): SizeInt; inline;
begin
  Result := 0;
  while V > 1 do
  begin
    V := V shr 1;
    Inc(Result);
  end;
end;

function MulProb(TmpRange, Probability: QWord): QWord; inline;
begin
  Result := (((((TmpRange - (QWord(1) shl BITS_IN_VALUE_MINUS_LAST_BYTE)) shr 8) * Probability)
    and (QWord($FF) shl BITS_IN_VALUE_MINUS_LAST_BYTE))
    + (QWord(1) shl BITS_IN_VALUE_MINUS_LAST_BYTE));
end;

// TVpxBoolWriter

constructor TVpxBoolWriter.Create(AWriter: TStream; AOwnsStream: Boolean);
var
  Dummy: TLeptonBranch;
begin
  inherited Create;
  FWriter := AWriter;
  FOwnsStream := AOwnsStream;
  FLowValue := QWord(1) shl 9; // divider/marker bit
  FRange := 255;
  FLen := 0;
  SetLength(FBuffer, 0);
  Dummy := TLeptonBranch.Create;
  PutBit(False, Dummy); // initial false bit prevents carry from escaping stream start
end;

destructor TVpxBoolWriter.Destroy;
begin
  if FOwnsStream then
    FWriter.Free;
  inherited Destroy;
end;

procedure TVpxBoolWriter.EnsureCapacity(Needed: SizeInt);
var
  NewCap: SizeInt;
begin
  if Length(FBuffer) >= Needed then
    Exit;
  NewCap := Length(FBuffer);
  if NewCap < 256 then
    NewCap := 256;
  while NewCap < Needed do
    NewCap := NewCap * 2;
  SetLength(FBuffer, NewCap);
end;

procedure TVpxBoolWriter.AppendByte(B: Byte);
begin
  EnsureCapacity(FLen + 1);
  FBuffer[FLen] := B;
  Inc(FLen);
end;

procedure TVpxBoolWriter.AppendSixBytesBE(V: QWord);
var
  I: Integer;
begin
  EnsureCapacity(FLen + 6);
  for I := 7 downto 2 do
    AppendByte(Byte((V shr (I * 8)) and $FF));
end;

procedure TVpxBoolWriter.Carry;
var
  X: SizeInt;
begin
  if FLen = 0 then
    LeptonFail(lecAssertionFailure, 'VPX carry on empty buffer');
  X := FLen - 1;
  while FBuffer[X] = $FF do
  begin
    FBuffer[X] := 0;
    if X = 0 then
      LeptonFail(lecAssertionFailure, 'VPX carry escaped stream start');
    Dec(X);
  end;
  Inc(FBuffer[X]);
end;

procedure TVpxBoolWriter.PutRaw(Bit: Boolean; var Branch: TLeptonBranch; var TmpValue: QWord; var TmpRange: LongWord);
var
  Probability, Split, Shift, LeftoverBits: LongWord;
  VAligned: QWord;
begin
  Probability := Branch.Probability;
  Split := 1 + (((TmpRange - 1) * Probability) shr 8);

  Branch.RecordAndUpdateBit(Bit);

  if Bit then
  begin
    Inc(TmpValue, Split);
    Dec(TmpRange, Split);
  end
  else
    TmpRange := Split;

  Shift := LeadingZeros8(Byte(TmpRange));
  TmpRange := TmpRange shl Shift;
  TmpValue := TmpValue shl Shift;

  if (TmpValue and (High(QWord) shl 57)) <> 0 then
  begin
    LeftoverBits := LeadingZeros64(TmpValue) + 2;
    VAligned := RotL64(TmpValue, LeftoverBits);
    if (VAligned and 1) <> 0 then
      Carry;
    AppendSixBytesBE(VAligned);
    TmpValue := ((VAligned and $FFFF) or $20000) shr LeftoverBits;
  end;
end;

procedure TVpxBoolWriter.PutBit(Bit: Boolean; var Branch: TLeptonBranch);
var
  TmpValue: QWord;
  TmpRange: LongWord;
begin
  TmpValue := FLowValue;
  TmpRange := FRange;
  PutRaw(Bit, Branch, TmpValue, TmpRange);
  FLowValue := TmpValue;
  FRange := TmpRange;
end;

procedure TVpxBoolWriter.PutGrid(V: Byte; var Branches: array of TLeptonBranch; A: SizeInt);
var
  TmpValue: QWord;
  TmpRange: LongWord;
  Index, Serialized: SizeInt;
  CurBit: Boolean;
begin
  if (not IsPowerOfTwo(A)) or (Length(Branches) < A) then
    LeptonFail(lecAssertionFailure, 'PutGrid: A must be a power of two and fit in Branches');

  TmpValue := FLowValue;
  TmpRange := FRange;
  Index := ILog2PowerOfTwo(A) - 1;
  Serialized := 1;

  while True do
  begin
    CurBit := (V and (1 shl Index)) <> 0;
    PutRaw(CurBit, Branches[Serialized], TmpValue, TmpRange);
    if Index = 0 then
      Break;
    Serialized := (Serialized shl 1) or Ord(CurBit);
    Dec(Index);
  end;

  FLowValue := TmpValue;
  FRange := TmpRange;
end;

procedure TVpxBoolWriter.PutNBits(Bits, NumBits: SizeInt; var Branches: array of TLeptonBranch);
var
  TmpValue: QWord;
  TmpRange: LongWord;
  I: SizeInt;
begin
  if (NumBits < 0) or (Length(Branches) < NumBits) then
    LeptonFail(lecAssertionFailure, 'PutNBits: invalid bit count');

  TmpValue := FLowValue;
  TmpRange := FRange;
  I := NumBits - 1;
  while I >= 0 do
  begin
    PutRaw((Bits and (SizeInt(1) shl I)) <> 0, Branches[I], TmpValue, TmpRange);
    Dec(I);
  end;

  FLowValue := TmpValue;
  FRange := TmpRange;
end;

procedure TVpxBoolWriter.PutUnaryEncoded(V: SizeInt; var Branches: array of TLeptonBranch);
var
  TmpValue: QWord;
  TmpRange: LongWord;
  I: SizeInt;
  CurBit: Boolean;
begin
  if (V < 0) or (V > Length(Branches)) then
    LeptonFail(lecAssertionFailure, 'PutUnaryEncoded: value out of range');

  TmpValue := FLowValue;
  TmpRange := FRange;
  for I := 0 to High(Branches) do
  begin
    CurBit := V <> I;
    PutRaw(CurBit, Branches[I], TmpValue, TmpRange);
    if not CurBit then
      Break;
  end;

  FLowValue := TmpValue;
  FRange := TmpRange;
end;

procedure TVpxBoolWriter.FlushNonFinalData;
var
  I, Count: SizeInt;
begin
  I := FLen;
  if I > 1 then
  begin
    Dec(I);
    while FBuffer[I] = $FF do
    begin
      if I = 0 then
        LeptonFail(lecAssertionFailure, 'FlushNonFinalData: all bytes are carry-protected');
      Dec(I);
    end;

    Count := I;
    if Count > 0 then
    begin
      FWriter.WriteBuffer(FBuffer[0], Count);
      System.Move(FBuffer[Count], FBuffer[0], FLen - Count);
      Dec(FLen, Count);
    end;
  end;
end;

procedure TVpxBoolWriter.Finish;
var
  TmpValue: QWord;
  StreamBits, StreamBytes, Shift: LongWord;
  I: LongWord;
begin
  TmpValue := FLowValue;
  StreamBits := 64 - LeadingZeros64(TmpValue) - 2;
  TmpValue := TmpValue shl (63 - StreamBits);
  if (TmpValue and (QWord(1) shl 63)) <> 0 then
    Carry;

  Shift := 63;
  StreamBytes := (StreamBits + 7) shr 3;
  for I := 0 to StreamBytes - 1 do
  begin
    Dec(Shift, 8);
    AppendByte(Byte((TmpValue shr Shift) and $FF));
  end;

  if FLen > 0 then
    FWriter.WriteBuffer(FBuffer[0], FLen);
  FLen := 0;
end;

// TVpxBoolReader

constructor TVpxBoolReader.Create(AReader: TStream; AOwnsStream: Boolean);
var
  Dummy: TLeptonBranch;
  Bit: Boolean;
begin
  inherited Create;
  FReader := AReader;
  FOwnsStream := AOwnsStream;
  FValue := QWord(1) shl 63; // guard bit
  FRange := QWord(255) shl BITS_IN_VALUE_MINUS_LAST_BYTE;
  Dummy := TLeptonBranch.Create;
  Bit := GetBit(Dummy); // initial false marker bit
  if Bit then
    LeptonFail(lecStreamInconsistent, 'VPX stream marker bit is inconsistent');
end;

destructor TVpxBoolReader.Destroy;
begin
  if FOwnsStream then
    FReader.Free;
  inherited Destroy;
end;

function TVpxBoolReader.GetRaw(var Branch: TLeptonBranch; var TmpValue, TmpRange: QWord): Boolean;
var
  Split: QWord;
  Shift: LongWord;
begin
  Split := MulProb(TmpRange, Branch.Probability);
  Result := TmpValue >= Split;
  Branch.RecordAndUpdateBit(Result);

  if Result then
  begin
    Dec(TmpRange, Split);
    Dec(TmpValue, Split);
  end
  else
    TmpRange := Split;

  Shift := LeadingZeros64(TmpRange);
  TmpValue := TmpValue shl Shift;
  TmpRange := TmpRange shl Shift;
end;

class function TVpxBoolReader.VpxReaderFill(TmpValue: QWord; UpstreamReader: TStream): QWord;
var
  Shift: Integer;
  B: Byte;
begin
  Result := TmpValue;
  if (Result and $FF) = 0 then
  begin
    Shift := Integer(TrailingZeros64(Result));
    Result := Result and (Result - 1); // unset old guard bit
    Result := Result or (QWord(1) shl (Shift and 7)); // set new guard bit
    Dec(Shift, 7);

    while Shift > 0 do
    begin
      if UpstreamReader.Read(B, 1) <> 1 then
        Break;
      Result := Result or (QWord(B) shl Shift);
      Dec(Shift, 8);
    end;
  end;
end;

function TVpxBoolReader.GetBit(var Branch: TLeptonBranch): Boolean;
var
  TmpValue, TmpRange: QWord;
begin
  TmpValue := FValue;
  TmpRange := FRange;
  if (TmpValue and VALUE_MASK) = 0 then
    TmpValue := VpxReaderFill(TmpValue, FReader);
  Result := GetRaw(Branch, TmpValue, TmpRange);
  FValue := TmpValue;
  FRange := TmpRange;
end;

function TVpxBoolReader.GetGrid(var Branches: array of TLeptonBranch; A: SizeInt): SizeInt;
var
  TmpValue, TmpRange: QWord;
  Decoded, I, CurBit: SizeInt;
begin
  if (not IsPowerOfTwo(A)) or (A > 128) or (Length(Branches) < A) then
    LeptonFail(lecAssertionFailure, 'GetGrid: A must be a supported power of two and fit in Branches');

  TmpValue := VpxReaderFill(FValue, FReader);
  TmpRange := FRange;
  Decoded := 1;

  for I := 0 to ILog2PowerOfTwo(A) - 1 do
  begin
    CurBit := Ord(GetRaw(Branches[Decoded], TmpValue, TmpRange));
    Decoded := (Decoded shl 1) or CurBit;
  end;

  Result := Decoded xor A;
  FValue := TmpValue;
  FRange := TmpRange;
end;

function TVpxBoolReader.GetUnaryEncoded(var Branches: array of TLeptonBranch): SizeInt;
var
  TmpValue, TmpRange, Split: QWord;
  Shift: LongWord;
  Value: SizeInt;
begin
  TmpValue := FValue;
  TmpRange := FRange;

  for Value := 0 to High(Branches) do
  begin
    Split := MulProb(TmpRange, Branches[Value].Probability);
    if (Value = 0) or (Value = 7) then
      TmpValue := VpxReaderFill(TmpValue, FReader);

    if TmpValue >= Split then
    begin
      Branches[Value].RecordAndUpdateBit(True);
      Dec(TmpRange, Split);
      Dec(TmpValue, Split);
      Shift := LeadingZeros64(TmpRange);
      TmpValue := TmpValue shl Shift;
      TmpRange := TmpRange shl Shift;
    end
    else
    begin
      Branches[Value].RecordAndUpdateBit(False);
      TmpRange := Split;
      Shift := LeadingZeros64(TmpRange);
      TmpValue := TmpValue shl Shift;
      TmpRange := TmpRange shl Shift;
      FValue := TmpValue;
      FRange := TmpRange;
      Exit(Value);
    end;
  end;

  FValue := TmpValue;
  FRange := TmpRange;
  Result := Length(Branches);
end;

function TVpxBoolReader.GetNBits(N: SizeInt; var Branches: array of TLeptonBranch): SizeInt;
var
  TmpValue, TmpRange: QWord;
  I: SizeInt;
begin
  if (N < 0) or (N > Length(Branches)) then
    LeptonFail(lecAssertionFailure, 'GetNBits: invalid bit count');

  TmpValue := FValue;
  TmpRange := FRange;
  Result := 0;
  I := N - 1;
  while I >= 0 do
  begin
    if (TmpValue and VALUE_MASK) = 0 then
      TmpValue := VpxReaderFill(TmpValue, FReader);
    if GetRaw(Branches[I], TmpValue, TmpRange) then
      Result := Result or (SizeInt(1) shl I);
    Dec(I);
  end;

  FValue := TmpValue;
  FRange := TmpRange;
end;

end.
