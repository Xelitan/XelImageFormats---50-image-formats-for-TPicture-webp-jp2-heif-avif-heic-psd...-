unit JpegBitStream;

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
  Classes, SysUtils, LeptonErrors, LeptonHelpers, JpegCodes;

type
  TJpegBitWriter = class
  private
    FData: TBytes;
    FLen: SizeInt;
    FFillRegister: QWord;
    FCurrentBit: LongWord;
    procedure EnsureCapacity(Needed: SizeInt);
    procedure AppendByte(B: Byte); inline;
    procedure AppendEscapedByte(B: Byte); inline;
    procedure AppendBigEndian64Escaped(V: QWord);
    procedure FlushWholeBytes;
  public
    constructor Create;
    procedure Clear;
    procedure WriteByteUnescaped(B: Byte);
    procedure WriteBits(Val: LongWord; NewBits: LongWord);
    procedure Pad(FillBit: Byte);
    function DetachBuffer: TBytes;
    procedure EnsureSpace(Amount: SizeInt);
    procedure ResetFromOverhangByteAndNumBits(OverhangByte: Byte; NumBits: LongWord);
    function HasNoRemainder: Boolean; inline;
    function AmountBuffered: SizeInt; inline;
  end;

  TJpegBitReader = class
  private
    FStream: TStream;
    FOwnsStream: Boolean;
    FBits: QWord;
    FBitsLeft: LongWord;
    FCPos: LongWord;
    FEOF: Boolean;
    FTruncatedFF: Boolean;
    function ReadOneByte(out B: Byte): Boolean;
    procedure FillRegisterSlow(BitsToRead: LongWord);
    procedure UndoReadAhead; inline;
  public
    constructor Create(AStream: TStream; AOwnsStream: Boolean = False);
    destructor Destroy; override;
    function StreamPosition: Int64;
    function ReadBits(BitsToRead: LongWord): Word;
    procedure Peek(out Code: Byte; out BitsAvailable: LongWord);
    procedure Advance(Bits: LongWord); inline;
    procedure FillRegister(BitsToRead: LongWord);
    function IsEOF: Boolean; inline;
    // PadBit: -1 = unknown, 0 = zero-fill, $FF = one-fill.
    procedure ReadAndVerifyFillBits(var PadBit: Integer);
    procedure VerifyResetCode;
    procedure Overhang(out BitsAlreadyRead: Byte; out ByteBeingRead: Byte);
  end;

implementation

constructor TJpegBitWriter.Create;
begin
  inherited Create;
  FCurrentBit := 64;
  FFillRegister := 0;
  FLen := 0;
  SetLength(FData, 0);
end;

procedure TJpegBitWriter.EnsureCapacity(Needed: SizeInt);
var
  NewCap: SizeInt;
begin
  if Length(FData) >= Needed then
    Exit;
  NewCap := Length(FData);
  if NewCap < 256 then
    NewCap := 256;
  while NewCap < Needed do
    NewCap := NewCap * 2;
  SetLength(FData, NewCap);
end;

procedure TJpegBitWriter.AppendByte(B: Byte);
begin
  EnsureCapacity(FLen + 1);
  FData[FLen] := B;
  Inc(FLen);
end;

procedure TJpegBitWriter.AppendEscapedByte(B: Byte);
begin
  if B <> $FF then
    AppendByte(B)
  else
  begin
    AppendByte($FF);
    AppendByte($00);
  end;
end;

procedure TJpegBitWriter.AppendBigEndian64Escaped(V: QWord);
var
  I: Integer;
begin
  for I := 7 downto 0 do
    AppendEscapedByte(Byte((V shr (I * 8)) and $FF));
end;

procedure TJpegBitWriter.FlushWholeBytes;
var
  B: Byte;
begin
  while FCurrentBit <= 56 do
  begin
    B := Byte((FFillRegister shr 56) and $FF);
    AppendEscapedByte(B);
    FFillRegister := FFillRegister shl 8;
    Inc(FCurrentBit, 8);
  end;
end;

procedure TJpegBitWriter.Clear;
begin
  FLen := 0;
  FFillRegister := 0;
  FCurrentBit := 64;
end;

procedure TJpegBitWriter.WriteByteUnescaped(B: Byte);
begin
  if FCurrentBit <> 64 then
    LeptonFail(lecAssertionFailure, 'WriteByteUnescaped requires byte alignment');
  AppendByte(B);
end;

procedure TJpegBitWriter.WriteBits(Val: LongWord; NewBits: LongWord);
var
  Fill: QWord;
  LeftoverNewBits: LongWord;
  LeftoverVal: LongWord;
begin
  if NewBits = 0 then
    Exit;

  if (NewBits < 32) and (Val >= (LongWord(1) shl NewBits)) then
    LeptonFail(lecAssertionFailure, Format('value %u does not fit in %u bits', [Val, NewBits]));

  if NewBits <= FCurrentBit then
  begin
    FFillRegister := FFillRegister or (QWord(Val) shl (FCurrentBit - NewBits));
    Dec(FCurrentBit, NewBits);
  end
  else
  begin
    Fill := FFillRegister or (QWord(Val) shr (NewBits - FCurrentBit));
    LeftoverNewBits := NewBits - FCurrentBit;
    if LeftoverNewBits = 32 then
      LeftoverVal := Val
    else
      LeftoverVal := Val and ((LongWord(1) shl LeftoverNewBits) - 1);

    AppendBigEndian64Escaped(Fill);

    FFillRegister := QWord(LeftoverVal) shl (64 - LeftoverNewBits);
    FCurrentBit := 64 - LeftoverNewBits;
  end;
end;

procedure TJpegBitWriter.Pad(FillBit: Byte);
var
  Offset: Byte;
begin
  Offset := 1;
  while (FCurrentBit and 7) <> 0 do
  begin
    if (FillBit and Offset) <> 0 then
      WriteBits(1, 1)
    else
      WriteBits(0, 1);
    Offset := Offset shl 1;
  end;

  FlushWholeBytes;

  if FCurrentBit <> 64 then
    LeptonFail(lecAssertionFailure, 'there should be no remainder after padding');
end;

function TJpegBitWriter.DetachBuffer: TBytes;
begin
  FlushWholeBytes;
  SetLength(Result, FLen);
  if FLen > 0 then
    Move(FData[0], Result[0], FLen);
  FLen := 0;
end;

procedure TJpegBitWriter.EnsureSpace(Amount: SizeInt);
begin
  EnsureCapacity(Amount);
end;

procedure TJpegBitWriter.ResetFromOverhangByteAndNumBits(OverhangByte: Byte; NumBits: LongWord);
begin
  FLen := 0;
  FFillRegister := QWord(OverhangByte) shl 56;
  FCurrentBit := 64 - NumBits;
end;

function TJpegBitWriter.HasNoRemainder: Boolean;
begin
  Result := FCurrentBit = 64;
end;

function TJpegBitWriter.AmountBuffered: SizeInt;
begin
  Result := FLen;
end;

constructor TJpegBitReader.Create(AStream: TStream; AOwnsStream: Boolean);
begin
  inherited Create;
  FStream := AStream;
  FOwnsStream := AOwnsStream;
  FBits := 0;
  FBitsLeft := 0;
  FCPos := 0;
  FEOF := False;
  FTruncatedFF := False;
end;

destructor TJpegBitReader.Destroy;
begin
  if FOwnsStream then
    FStream.Free;
  inherited Destroy;
end;

function TJpegBitReader.ReadOneByte(out B: Byte): Boolean;
begin
  Result := FStream.Read(B, 1) = 1;
end;

function TJpegBitReader.StreamPosition: Int64;
begin
  UndoReadAhead;
  Result := FStream.Position;
  if (FBitsLeft > 0) and (not FEOF) then
  begin
    if (Byte(FBits and $FF) = $FF) and (not FTruncatedFF) then
      Dec(Result, 2)
    else
      Dec(Result, 1);
  end;
end;

function TJpegBitReader.ReadBits(BitsToRead: LongWord): Word;
begin
  if BitsToRead = 0 then
    Exit(0);
  if FBitsLeft < BitsToRead then
    FillRegister(BitsToRead);
  Result := Word((FBits shr (FBitsLeft - BitsToRead)) and ((QWord(1) shl BitsToRead) - 1));
  Dec(FBitsLeft, BitsToRead);
end;

procedure TJpegBitReader.Peek(out Code: Byte; out BitsAvailable: LongWord);
var
  Shifted: QWord;
begin
  if FBitsLeft = 0 then
    Code := 0
  else
  begin
    Shifted := FBits shl (64 - FBitsLeft);
    Code := Byte((Shifted shr 56) and $FF);
  end;
  BitsAvailable := FBitsLeft;
end;

procedure TJpegBitReader.Advance(Bits: LongWord);
begin
  Dec(FBitsLeft, Bits);
end;

procedure TJpegBitReader.FillRegister(BitsToRead: LongWord);
begin
  FillRegisterSlow(BitsToRead);
end;

procedure TJpegBitReader.FillRegisterSlow(BitsToRead: LongWord);
var
  B, Esc: Byte;
begin
  repeat
    if ReadOneByte(B) then
    begin
      if B = $FF then
      begin
        if not ReadOneByte(Esc) then
        begin
          FBits := (FBits shl 8) or $FF;
          Inc(FBitsLeft, 8);
          FTruncatedFF := True;
        end
        else if Esc = 0 then
        begin
          FBits := (FBits shl 8) or $FF;
          Inc(FBitsLeft, 8);
        end
        else
          LeptonFail(lecInvalidResetCode, Format('invalid reset ff %.2x code found in stream', [Esc]));
      end
      else
      begin
        FBits := (FBits shl 8) or B;
        Inc(FBitsLeft, 8);
      end;
    end
    else
    begin
      FEOF := True;
      Inc(FBitsLeft, 8);
      FBits := FBits shl 8;
    end;
  until FBitsLeft >= BitsToRead;
end;

function TJpegBitReader.IsEOF: Boolean;
begin
  Result := FEOF;
end;

procedure TJpegBitReader.ReadAndVerifyFillBits(var PadBit: Integer);
var
  NumBitsToRead: LongWord;
  Actual, AllOne, Expected: Word;
begin
  UndoReadAhead;
  if (FBitsLeft > 0) and (not FEOF) then
  begin
    NumBitsToRead := FBitsLeft;
    Actual := ReadBits(NumBitsToRead);
    AllOne := Word((QWord(1) shl NumBitsToRead) - 1);
    if PadBit < 0 then
    begin
      if Actual = 0 then
        PadBit := 0
      else if Actual = AllOne then
        PadBit := $FF
      else
        LeptonFail(lecInvalidPadding, Format('inconsistent pad bits num_bits=%u pattern=%x', [NumBitsToRead, Actual]));
    end
    else
    begin
      Expected := Word(PadBit and AllOne);
      if Actual <> Expected then
        LeptonFail(lecInvalidPadding, Format('padding of %u bits mismatch actual=%x expected=%x', [NumBitsToRead, Actual, Expected]));
    end;
  end;
end;

procedure TJpegBitReader.VerifyResetCode;
var
  H0, H1: Byte;
begin
  UndoReadAhead;
  if (not ReadOneByte(H0)) or (not ReadOneByte(H1)) then
    LeptonFail(lecInvalidResetCode, 'truncated reset code found in stream');
  if (H0 <> $FF) or (H1 <> (JPEG_RST0 + (FCPos and 7))) then
    LeptonFail(lecInvalidResetCode, Format('invalid reset code %.2x %.2x found in stream', [H0, H1]));
  Inc(FCPos);
  FBits := 0;
  FBitsLeft := 0;
end;

procedure TJpegBitReader.Overhang(out BitsAlreadyRead: Byte; out ByteBeingRead: Byte);
var
  Mask: Byte;
begin
  UndoReadAhead;
  BitsAlreadyRead := Byte((64 - FBitsLeft) and 7);
  if BitsAlreadyRead = 0 then
    Mask := 0
  else
    Mask := Byte(((1 shl BitsAlreadyRead) - 1) shl (8 - BitsAlreadyRead));
  ByteBeingRead := Byte(FBits and $FF) and Mask;
end;

procedure TJpegBitReader.UndoReadAhead;
begin
  // This Pascal reader uses a conservative slow path and never prefetches ahead.
end;

end.
