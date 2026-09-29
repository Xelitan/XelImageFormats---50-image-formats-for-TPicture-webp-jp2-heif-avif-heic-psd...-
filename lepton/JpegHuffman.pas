unit JpegHuffman;

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

uses
  SysUtils, LeptonErrors, LeptonHelpers;

type
  THuffCodeValues = array[0..255] of Word;
  THuffCodeLengths = array[0..255] of Word;
  THuffLenPlusS = array[0..255] of Byte;
  THuffValShiftS = array[0..511] of LongWord;
  THuffNodeTable = array[0..255, 0..1] of Word;
  THuffPeekTable = array[0..255] of Byte;

  THuffCodes = record
    CVal: THuffCodeValues;
    CLen: THuffCodeLengths;
    CLenPlusS: THuffLenPlusS;
    CValShiftS: THuffValShiftS;
    MaxEOBRun: Word;
    class function Default: THuffCodes; static;
    class function ConstructFromSegment(const Segment: TBytes; SegmentOffset: SizeInt): THuffCodes; static;
    procedure PostInitialize;
  end;

  THuffTree = record
    Node: THuffNodeTable;
    PeekSymbol: THuffPeekTable;
    PeekLength: THuffPeekTable;
    class function Default: THuffTree; static;
    class function ConstructHuffTree(const HC: THuffCodes; AcceptInvalidDHT: Boolean): THuffTree; static;
  end;

procedure EnsureSegmentSpace(const Segment: TBytes; HPos, Amount: SizeInt; const WhereMsg: string = 'JPEG segment too small');

implementation

procedure EnsureSegmentSpace(const Segment: TBytes; HPos, Amount: SizeInt; const WhereMsg: string);
begin
  if (HPos < 0) or (Amount < 0) or (HPos + Amount > Length(Segment)) then
    LeptonFail(lecUnsupportedJpeg, WhereMsg);
end;

class function THuffCodes.Default: THuffCodes;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

class function THuffCodes.ConstructFromSegment(const Segment: TBytes; SegmentOffset: SizeInt): THuffCodes;
var
  K, I, J: SizeInt;
  Code, Len: Word;
  Symbol: Byte;
begin
  Result := THuffCodes.Default;
  K := 0;
  Code := 0;

  for I := 0 to 15 do
  begin
    EnsureSegmentSpace(Segment, SegmentOffset, I + 1, 'DHT length table too short');

    J := 0;
    while J < Segment[SegmentOffset + I] do
    begin
      EnsureSegmentSpace(Segment, SegmentOffset + 16, K + 1, 'DHT value table too short');

      Len := Word(I + 1);
      if LongWord(Code) >= (LongWord(1) shl Len) then
        LeptonFail(lecUnsupportedJpeg, 'invalid huffman code layout, too many codes for a given length');

      Symbol := Segment[SegmentOffset + 16 + K];
      Result.CLen[Symbol] := Len;
      Result.CVal[Symbol] := Code;

      if Code = High(Word) then
        LeptonFail(lecUnsupportedJpeg, 'huffman code too large');

      Inc(K);
      Inc(Code);
      Inc(J);
    end;

    Code := Word(Code shl 1);
  end;

  Result.PostInitialize;
end;

procedure THuffCodes.PostInitialize;
var
  I, S: SizeInt;
  P: LongWord;
begin
  for I := 0 to 255 do
  begin
    S := I and $0F;
    CLenPlusS[I] := Byte(CLen[I] + Word(S));
    CValShiftS[I] := LongWord(CVal[I]) shl S;

    if S = 0 then
      P := 0
    else
      P := (LongWord(1) shl S) - 1;
    CValShiftS[I + 256] := (LongWord(CVal[I]) shl S) or P;
  end;

  MaxEOBRun := 0;
  for I := 14 downto 0 do
  begin
    if CLen[(I shl 4) and $FF] > 0 then
    begin
      MaxEOBRun := Word((2 shl I) - 1);
      Break;
    end;
  end;
end;

class function THuffTree.Default: THuffTree;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

class function THuffTree.ConstructHuffTree(const HC: THuffCodes; AcceptInvalidDHT: Boolean): THuffTree;
var
  NextFree: Word;
  I: SizeInt;
  J: Word;
  CurrentNode: Word;
  PeekByte: SizeInt;
  NodeValue: Word;
  Len: Byte;
  BitIndex: SizeInt;
begin
  Result := THuffTree.Default;

  NextFree := 1;
  for I := 0 to 255 do
  begin
    CurrentNode := 0;
    if HC.CLen[I] > 0 then
    begin
      J := HC.CLen[I] - 1;
      while J > 0 do
      begin
        if CurrentNode <= $FF then
        begin
          if BitN(HC.CVal[I], J) = 1 then
          begin
            if Result.Node[CurrentNode, 1] = 0 then
            begin
              Result.Node[CurrentNode, 1] := NextFree;
              Inc(NextFree);
            end;
            CurrentNode := Result.Node[CurrentNode, 1];
          end
          else
          begin
            if Result.Node[CurrentNode, 0] = 0 then
            begin
              Result.Node[CurrentNode, 0] := NextFree;
              Inc(NextFree);
            end;
            CurrentNode := Result.Node[CurrentNode, 0];
          end;
        end
        else if not AcceptInvalidDHT then
          LeptonFail(lecUnsupportedJpeg, 'Huffman table out of space');

        Dec(J);
      end;
    end;

    if CurrentNode <= $FF then
    begin
      if HC.CLen[I] > 0 then
      begin
        if BitN(HC.CVal[I], 0) = 1 then
          Result.Node[CurrentNode, 1] := Word(I + 256)
        else
          Result.Node[CurrentNode, 0] := Word(I + 256);
      end;
    end
    else if not AcceptInvalidDHT then
      LeptonFail(lecUnsupportedJpeg, 'Huffman table out of space');
  end;

  for I := 0 to 255 do
  begin
    if Result.Node[I, 0] = 0 then
      Result.Node[I, 0] := $FFFF;
    if Result.Node[I, 1] = 0 then
      Result.Node[I, 1] := $FFFF;
  end;

  for PeekByte := 0 to 255 do
  begin
    NodeValue := 0;
    Len := 0;
    while (NodeValue < 256) and (Len <= 7) do
    begin
      BitIndex := (PeekByte shr (7 - Len)) and 1;
      NodeValue := Result.Node[NodeValue, BitIndex];
      Inc(Len);
    end;

    if (NodeValue = $FFFF) or (NodeValue < 256) then
    begin
      Result.PeekSymbol[PeekByte] := 0;
      Result.PeekLength[PeekByte] := $FF;
    end
    else
    begin
      Result.PeekSymbol[PeekByte] := Byte(NodeValue - 256);
      Result.PeekLength[PeekByte] := Len;
    end;
  end;
end;

end.
