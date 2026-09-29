unit LeptonBranch;

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//

{$mode delphi}
{$H+}
{$R-}
{$Q-}
{$modeswitch advancedrecords}

interface

type
  TLeptonBranch = record
  private
    FCounts: Word; // high byte = false count, low byte = true count
  public
    class function Create: TLeptonBranch; static;
    procedure Reset;
    function Counts: Word; inline;
    procedure SetCounts(Value: Word); inline;
    function Probability: Byte; inline;
    function DebugU64: QWord; inline;
    procedure RecordAndUpdateBit(Bit: Boolean); inline;
  end;

function BranchProbabilityFromCounts(Counts: Word): Byte; inline;

implementation

function RotL16(V: Word; Bits: Byte): Word; inline;
begin
  Bits := Bits and 15;
  if Bits = 0 then
    Result := V
  else
    Result := Word(((V shl Bits) or (V shr (16 - Bits))) and $FFFF);
end;

function BranchProbabilityFromCounts(Counts: Word): Byte;
var
  F, T: LongWord;
begin
  F := Counts shr 8;
  T := Counts and $FF;
  if (F = 0) or (T = 0) then
    Result := 0
  else
    Result := Byte((F shl 8) div (F + T));
end;

class function TLeptonBranch.Create: TLeptonBranch;
begin
  Result.FCounts := $0101;
end;

procedure TLeptonBranch.Reset;
begin
  FCounts := $0101;
end;

function TLeptonBranch.Counts: Word;
begin
  Result := FCounts;
end;

procedure TLeptonBranch.SetCounts(Value: Word);
begin
  FCounts := Value;
end;

function TLeptonBranch.Probability: Byte;
begin
  Result := BranchProbabilityFromCounts(FCounts);
end;

function TLeptonBranch.DebugU64: QWord;
begin
  Result := (QWord(Probability) shl 16) + FCounts;
end;

procedure TLeptonBranch.RecordAndUpdateBit(Bit: Boolean);
var
  Orig, Sum, Mask: Word;
  Rot: Byte;
begin
  if Bit then
    Rot := 8
  else
    Rot := 0;

  Orig := RotL16(FCounts, Rot);
  Sum := Word(Orig + $0100);

  // Rust: overflowing_add(0x100) on u16. Overflow occurs iff high byte was $FF.
  if Orig >= $FF00 then
  begin
    if Orig = $FF01 then
      Mask := $FF00
    else
      Mask := $8100;
    Sum := Word((((LongWord(Sum) + 1) shr 1) or Mask) and $FFFF);
  end;

  FCounts := RotL16(Sum, Rot);
end;

end.
