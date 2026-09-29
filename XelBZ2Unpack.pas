unit XelBZ2Unpack;

// Self-contained bzip2 decompressor for Free Pascal (mode Delphi).
// Author: xelitan.com
// License: MIT
{$mode delphi}
{$R-}{$Q-}

interface

uses
  Classes, SysUtils;

type
  EBZ2Error = class(Exception);

procedure BZ2Decompress(InStream, OutStream: TStream);
function  BZ2DecompressBytes(const Data: TBytes): TBytes;
procedure BZ2DecompressFile(const InName, OutName: string);

implementation

const
  BlockMagicHi = $314159;   // pi
  BlockMagicLo = $265359;
  EndMagicHi   = $177245;   // sqrt(pi)
  EndMagicLo   = $385090;

  MaxGroups    = 6;         // at most 6 Huffman tables per block
  MinGroups    = 2;
  GroupSize    = 50;        // symbols coded with one table before switching
  MaxAlpha     = 258;       // 256 MTF values + RUNA/RUNB - 1 + EOB
  MaxCodeLen   = 20;
  MaxSelectors = 18002;     // enough for a 900k block (900000 / 50 + slack)

  SymRunA = 0;
  SymRunB = 1;

  InBufSize  = 64 * 1024;
  OutBufSize = 64 * 1024;

  // Table used by the (long obsolete) "randomised block" mode.
  RandNums: array[0..511] of Word = (
    619, 720, 127, 481, 931, 816, 813, 233, 566, 247,
    985, 724, 205, 454, 863, 491, 741, 242, 949, 214,
    733, 859, 335, 708, 621, 574,  73, 654, 730, 472,
    419, 436, 278, 496, 867, 210, 399, 680, 480,  51,
    878, 465, 811, 169, 869, 675, 611, 697, 867, 561,
    862, 687, 507, 283, 482, 129, 807, 591, 733, 623,
    150, 238,  59, 379, 684, 877, 625, 169, 643, 105,
    170, 607, 520, 932, 727, 476, 693, 425, 174, 647,
     73, 122, 335, 530, 442, 853, 695, 249, 445, 515,
    909, 545, 703, 919, 874, 474, 882, 500, 594, 612,
    641, 801, 220, 162, 819, 984, 589, 513, 495, 799,
    161, 604, 958, 533, 221, 400, 386, 867, 600, 782,
    382, 596, 414, 171, 516, 375, 682, 485, 911, 276,
     98, 553, 163, 354, 666, 933, 424, 341, 533, 870,
    227, 730, 475, 186, 263, 647, 537, 686, 600, 224,
    469,  68, 770, 919, 190, 373, 294, 822, 808, 206,
    184, 943, 795, 384, 383, 461, 404, 758, 839, 887,
    715,  67, 618, 276, 204, 918, 873, 777, 604, 560,
    951, 160, 578, 722,  79, 804,  96, 409, 713, 940,
    652, 934, 970, 447, 318, 353, 859, 672, 112, 785,
    645, 863, 803, 350, 139,  93, 354,  99, 820, 908,
    609, 772, 154, 274, 580, 184,  79, 626, 630, 742,
    653, 282, 762, 623, 680,  81, 927, 626, 789, 125,
    411, 521, 938, 300, 821,  78, 343, 175, 128, 250,
    170, 774, 972, 275, 999, 639, 495,  78, 352, 126,
    857, 956, 358, 619, 580, 124, 737, 594, 701, 612,
    669, 112, 134, 694, 363, 992, 809, 743, 168, 974,
    944, 375, 748,  52, 600, 747, 642, 182, 862,  81,
    344, 805, 988, 739, 511, 655, 814, 334, 249, 515,
    897, 955, 664, 981, 649, 113, 974, 459, 893, 228,
    433, 837, 553, 268, 926, 240, 102, 654, 459,  51,
    686, 754, 806, 760, 493, 403, 415, 394, 687, 700,
    946, 670, 656, 610, 738, 392, 760, 799, 887, 653,
    978, 321, 576, 617, 626, 502, 894, 679, 243, 440,
    680, 879, 194, 572, 640, 724, 926,  56, 204, 700,
    707, 151, 457, 449, 797, 195, 791, 558, 945, 679,
    297,  59,  87, 824, 713, 663, 412, 693, 342, 606,
    134, 108, 571, 364, 631, 212, 174, 643, 304, 329,
    343,  97, 430, 751, 497, 314, 983, 374, 822, 928,
    140, 206,  73, 263, 980, 736, 876, 478, 430, 305,
    170, 514, 364, 692, 829,  82, 855, 953, 676, 246,
    369, 970, 294, 750, 807, 827, 150, 790, 288, 923,
    804, 378, 215, 828, 592, 281, 565, 555, 710,  82,
    896, 831, 547, 261, 524, 462, 293, 465, 502,  56,
    661, 821, 976, 991, 658, 869, 905, 758, 745, 193,
    768, 550, 608, 933, 378, 286, 215, 979, 792, 961,
     61, 688, 793, 644, 986, 403, 106, 366, 905, 644,
    372, 567, 466, 434, 645, 210, 389, 550, 919, 135,
    780, 773, 635, 389, 707, 100, 626, 958, 165, 504,
    920, 176, 193, 713, 857, 265, 203,  50, 668, 108,
    645, 990, 626, 197, 510, 357, 358, 850, 858, 364,
    936, 638);

type
  // Canonical Huffman decoding table for one coding group.
  // Codes of length L occupy the numeric range [First[L], Limit[L]) and map to
  // Symbols[Offset[L] + (code - First[L])].
  THuffTable = record
    MinLen, MaxLen: Integer;
    First : array[0..MaxCodeLen] of Integer;
    Limit : array[0..MaxCodeLen] of Integer;
    Offset: array[0..MaxCodeLen] of Integer;
    Symbols: array[0..MaxAlpha - 1] of Word;
  end;

  TBZ2Decoder = class
  private
    // --- input / bit reader ---
    FIn: TStream;
    FInBuf: array[0..InBufSize - 1] of Byte;
    FInPos, FInLen: Integer;
    FInEof: Boolean;
    FBitBuf: UInt64;      // pending bits, right-aligned
    FBitCnt: Integer;     // number of valid bits in FBitBuf (incl. padding)
    FPadBits: Integer;    // zero bits appended after real EOF

    // --- output ---
    FOut: TStream;
    FOutBuf: array[0..OutBufSize - 1] of Byte;
    FOutLen: Integer;

    // --- per-stream / per-block state ---
    FBlockMax: Integer;               // max bytes in a BWT block
    FTT: array of UInt32;             // BWT block, later linked list
    FByteCount: array[0..255] of Integer;
    FBlockCRC: UInt32;

    function  FillByte(out B: Byte): Boolean;
    procedure Need(N: Integer); inline;
    function  GetBits(N: Integer): UInt32;
    function  GetBit: Boolean; inline;
    procedure CheckOverrun; inline;
    procedure AlignToByte;
    function  MoreInput: Boolean;

    procedure Flush;
    procedure PutByte(B: Byte); inline;

    procedure ReadHuffTable(var T: THuffTable; AlphaSize: Integer);
    function  DecodeSymbol(const T: THuffTable): Integer;
    function  ReadBlock(out OrigPtr: Integer; out Randomised: Boolean): Integer;
    procedure EmitBlock(Count, OrigPtr: Integer; Randomised: Boolean);
    function  DecodeStream: Boolean;
  public
    constructor Create(AIn, AOut: TStream);
    procedure Run;
  end;

var
  CRCTable: array[0..255] of UInt32;

procedure BuildCRCTable;
var
  I, K: Integer;
  C: UInt32;
begin
  // bzip2 uses the MSB-first ("big endian") CRC-32, polynomial 04C11DB7.
  for I := 0 to 255 do
  begin
    C := UInt32(I) shl 24;
    for K := 1 to 8 do
      if (C and $80000000) <> 0 then
        C := (C shl 1) xor $04C11DB7
      else
        C := C shl 1;
    CRCTable[I] := C;
  end;
end;

procedure Fail(const Msg: string);
begin
  raise EBZ2Error.Create('bzip2: ' + Msg);
end;

// TBZ2Decoder

constructor TBZ2Decoder.Create(AIn, AOut: TStream);
begin
  inherited Create;
  FIn := AIn;
  FOut := AOut;
end;

// ---------------------------------------------------------------------------
// Bit reader
// ---------------------------------------------------------------------------

function TBZ2Decoder.FillByte(out B: Byte): Boolean;
begin
  if FInPos >= FInLen then
  begin
    if FInEof then
      Exit(False);
    FInLen := FIn.Read(FInBuf[0], InBufSize);
    FInPos := 0;
    if FInLen <= 0 then
    begin
      FInLen := 0;
      FInEof := True;
      Exit(False);
    end;
  end;
  B := FInBuf[FInPos];
  Inc(FInPos);
  Result := True;
end;

// Make sure at least N (<= 32) bits are buffered. Past the end of input we
// append zero bits and remember how many, so that peeking near the end works;
// actually consuming such bits is detected by CheckOverrun.
procedure TBZ2Decoder.Need(N: Integer);
var
  B: Byte;
begin
  while FBitCnt < N do
  begin
    if not FillByte(B) then
    begin
      B := 0;
      Inc(FPadBits, 8);
    end;
    FBitBuf := (FBitBuf shl 8) or B;
    Inc(FBitCnt, 8);
  end;
end;

procedure TBZ2Decoder.CheckOverrun;
begin
  if FBitCnt < FPadBits then
    Fail('unexpected end of compressed data');
end;

function TBZ2Decoder.GetBits(N: Integer): UInt32;
begin
  Need(N);
  Dec(FBitCnt, N);
  Result := UInt32(FBitBuf shr FBitCnt) and UInt32((UInt64(1) shl N) - 1);
  CheckOverrun;
end;

function TBZ2Decoder.GetBit: Boolean;
begin
  Result := GetBits(1) <> 0;
end;

// Streams end on a byte boundary; drop the partial byte left in the buffer.
procedure TBZ2Decoder.AlignToByte;
begin
  FBitCnt := FBitCnt - (FBitCnt mod 8);
end;

// True when any real (non-padding) input remains after the current position.
function TBZ2Decoder.MoreInput: Boolean;
var
  B: Byte;
begin
  if FBitCnt > FPadBits then
    Exit(True);
  if FPadBits > 0 then
    Exit(False);
  Result := FillByte(B);
  if Result then
  begin
    FBitBuf := (FBitBuf shl 8) or B;
    Inc(FBitCnt, 8);
  end;
end;

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

procedure TBZ2Decoder.Flush;
begin
  if FOutLen > 0 then
  begin
    FOut.WriteBuffer(FOutBuf[0], FOutLen);
    FOutLen := 0;
  end;
end;

procedure TBZ2Decoder.PutByte(B: Byte);
begin
  FBlockCRC := (FBlockCRC shl 8) xor CRCTable[(FBlockCRC shr 24) xor B];
  FOutBuf[FOutLen] := B;
  Inc(FOutLen);
  if FOutLen = OutBufSize then
    Flush;
end;

// ---------------------------------------------------------------------------
// Huffman tables
// ---------------------------------------------------------------------------

// Code lengths are delta coded: start with a 5-bit value, then for every
// symbol read "1x" pairs (x=0: +1, x=1: -1) until a single "0" ends it.
procedure TBZ2Decoder.ReadHuffTable(var T: THuffTable; AlphaSize: Integer);
var
  Lens: array[0..MaxAlpha - 1] of Byte;
  Count: array[0..MaxCodeLen] of Integer;
  S, L, Cur, Code, Idx: Integer;
begin
  Cur := GetBits(5);
  for S := 0 to AlphaSize - 1 do
  begin
    repeat
      if (Cur < 1) or (Cur > MaxCodeLen) then
        Fail('invalid Huffman code length');
      if not GetBit then
        Break;
      if GetBit then
        Dec(Cur)
      else
        Inc(Cur);
    until False;
    Lens[S] := Cur;
  end;

  FillChar(Count, SizeOf(Count), 0);
  T.MinLen := MaxCodeLen;
  T.MaxLen := 0;
  for S := 0 to AlphaSize - 1 do
  begin
    Inc(Count[Lens[S]]);
    if Lens[S] < T.MinLen then T.MinLen := Lens[S];
    if Lens[S] > T.MaxLen then T.MaxLen := Lens[S];
  end;

  // Canonical assignment: shorter codes first, within a length by symbol order.
  Code := 0;
  Idx := 0;
  for L := 1 to MaxCodeLen do
  begin
    T.First[L] := Code;
    T.Limit[L] := Code + Count[L];
    T.Offset[L] := Idx;
    Inc(Idx, Count[L]);
    Code := (Code + Count[L]) shl 1;
  end;

  Idx := 0;
  for L := T.MinLen to T.MaxLen do
    for S := 0 to AlphaSize - 1 do
      if Lens[S] = L then
      begin
        T.Symbols[Idx] := S;
        Inc(Idx);
      end;
end;

function TBZ2Decoder.DecodeSymbol(const T: THuffTable): Integer;
var
  Bits: UInt32;
  L, Code: Integer;
begin
  Need(T.MaxLen);
  Bits := UInt32(FBitBuf shr (FBitCnt - T.MaxLen)) and ((UInt32(1) shl T.MaxLen) - 1);
  for L := T.MinLen to T.MaxLen do
  begin
    Code := Bits shr (T.MaxLen - L);
    if Code < T.Limit[L] then
    begin
      Dec(FBitCnt, L);
      CheckOverrun;
      Exit(T.Symbols[T.Offset[L] + Code - T.First[L]]);
    end;
  end;
  Fail('invalid Huffman code');
  Result := 0;
end;

// ---------------------------------------------------------------------------
// Block decoding: Huffman -> RUNA/RUNB -> MTF, filling FTT with raw BWT bytes
// ---------------------------------------------------------------------------

function TBZ2Decoder.ReadBlock(out OrigPtr: Integer; out Randomised: Boolean): Integer;
var
  InUse16: UInt32;
  SeqToByte: array[0..255] of Byte;
  MTF: array[0..255] of Byte;
  Selectors: array of Byte;
  Tables: array[0..MaxGroups - 1] of THuffTable;
  I, J, NInUse, AlphaSize, EOB, NGroups, NSelectors, SelCount: Integer;
  GroupIdx, GroupLeft, Sym, N: Integer;
  RunLen, RunWeight: Int64;
  Tmp, B: Byte;
  Table: ^THuffTable;
begin
  Randomised := GetBit;
  OrigPtr := GetBits(24);

  // Symbol map: 16 bits say which 16-byte ranges occur, then 16 bits per range.
  NInUse := 0;
  InUse16 := GetBits(16);
  for I := 0 to 15 do
    if (InUse16 and ($8000 shr I)) <> 0 then
    begin
      J := GetBits(16);
      for N := 0 to 15 do
        if (J and ($8000 shr N)) <> 0 then
        begin
          SeqToByte[NInUse] := I * 16 + N;
          Inc(NInUse);
        end;
    end;
  if NInUse = 0 then
    Fail('block uses no symbols');
  AlphaSize := NInUse + 2;   // RUNA, RUNB, MTF values 1..NInUse-1, EOB
  EOB := AlphaSize - 1;

  NGroups := GetBits(3);
  if (NGroups < MinGroups) or (NGroups > MaxGroups) then
    Fail('invalid number of Huffman tables');

  // Selectors choose a table for each 50-symbol group; they are MTF coded,
  // each MTF index stored in unary.
  NSelectors := GetBits(15);
  if NSelectors < 1 then
    Fail('invalid number of selectors');
  SelCount := NSelectors;
  if SelCount > MaxSelectors then
    SelCount := MaxSelectors;     // extra ones can never be used; skip them
  SetLength(Selectors, SelCount);
  for I := 0 to NGroups - 1 do
    MTF[I] := I;
  for I := 0 to NSelectors - 1 do
  begin
    J := 0;
    while GetBit do
    begin
      Inc(J);
      if J >= NGroups then
        Fail('invalid selector');
    end;
    if I < SelCount then
    begin
      Tmp := MTF[J];
      while J > 0 do
      begin
        MTF[J] := MTF[J - 1];
        Dec(J);
      end;
      MTF[0] := Tmp;
      Selectors[I] := Tmp;
    end;
  end;

  for I := 0 to NGroups - 1 do
    ReadHuffTable(Tables[I], AlphaSize);

  // Main symbol loop.
  for I := 0 to 255 do
    MTF[I] := I;
  FillChar(FByteCount, SizeOf(FByteCount), 0);
  N := 0;
  GroupIdx := -1;
  GroupLeft := 0;
  RunLen := 0;
  RunWeight := 1;
  Table := nil;

  repeat
    if GroupLeft = 0 then
    begin
      Inc(GroupIdx);
      if GroupIdx >= SelCount then
        Fail('ran out of selectors');
      Table := @Tables[Selectors[GroupIdx]];
      GroupLeft := GroupSize;
    end;
    Dec(GroupLeft);
    Sym := DecodeSymbol(Table^);

    if Sym <= SymRunB then
    begin
      // Run length in bijective base 2: RUNA adds 1*w, RUNB adds 2*w, w doubles.
      if RunWeight > (1 shl 21) then
        Fail('run too long');
      Inc(RunLen, (Sym + 1) * RunWeight);
      RunWeight := RunWeight shl 1;
      Continue;
    end;

    if RunLen > 0 then
    begin
      // A run always repeats the front of the MTF list.
      if N + RunLen > FBlockMax then
        Fail('block too large');
      B := SeqToByte[MTF[0]];
      Inc(FByteCount[B], RunLen);
      for I := 1 to RunLen do
      begin
        FTT[N] := B;
        Inc(N);
      end;
      RunLen := 0;
      RunWeight := 1;
    end;

    if Sym = EOB then
      Break;

    // Symbol k (2..EOB-1) means MTF position k-1.
    if N >= FBlockMax then
      Fail('block too large');
    J := Sym - 1;
    Tmp := MTF[J];
    Move(MTF[0], MTF[1], J);
    MTF[0] := Tmp;
    B := SeqToByte[Tmp];
    Inc(FByteCount[B]);
    FTT[N] := B;
    Inc(N);
  until False;

  if (OrigPtr < 0) or (OrigPtr >= N) then
    Fail('invalid BWT origin pointer');
  Result := N;
end;

// ---------------------------------------------------------------------------
// Inverse BWT + de-randomisation + initial RLE, streaming bytes to output
// ---------------------------------------------------------------------------

procedure TBZ2Decoder.EmitBlock(Count, OrigPtr: Integer; Randomised: Boolean);
var
  Start: array[0..255] of Integer;
  I, Sum, Pos, Last, Same, RandIdx, RandLeft: Integer;
  B: Byte;
  Entry: UInt32;
begin
  // Start[b] = index of the first row in the sorted BWT matrix starting with b.
  Sum := 0;
  for I := 0 to 255 do
  begin
    Start[I] := Sum;
    Inc(Sum, FByteCount[I]);
  end;

  // Build the "next row" links in the upper 24 bits of each entry, keeping
  // the byte in the low 8 bits. Walking the links from OrigPtr yields the
  // original text in forward order.
  for I := 0 to Count - 1 do
  begin
    B := FTT[I] and $FF;
    FTT[Start[B]] := FTT[Start[B]] or (UInt32(I) shl 8);
    Inc(Start[B]);
  end;

  Pos := FTT[OrigPtr] shr 8;
  Last := -1;
  Same := 0;
  RandIdx := 0;
  RandLeft := 0;
  FBlockCRC := $FFFFFFFF;

  for I := 1 to Count do
  begin
    Entry := FTT[Pos];
    B := Entry and $FF;
    Pos := Entry shr 8;

    if Randomised then
    begin
      if RandLeft = 0 then
      begin
        RandLeft := RandNums[RandIdx];
        RandIdx := (RandIdx + 1) and 511;
      end;
      Dec(RandLeft);
      if RandLeft = 1 then
        B := B xor 1;
    end;

    // Undo the initial run-length step: after four equal bytes the next
    // byte is a count of further copies.
    if Same = 4 then
    begin
      while B > 0 do
      begin
        PutByte(Byte(Last));
        Dec(B);
      end;
      Same := 0;
      Last := -1;
      Continue;
    end;

    if B = Last then
      Inc(Same)
    else
    begin
      Last := B;
      Same := 1;
    end;
    PutByte(B);
  end;

  FBlockCRC := not FBlockCRC;
end;

// ---------------------------------------------------------------------------
// Stream level
// ---------------------------------------------------------------------------

// Decodes one "BZh" stream. Returns False if the data at the current position
// is not a bzip2 header (only allowed after at least one stream).
function TBZ2Decoder.DecodeStream: Boolean;
var
  Level, Hi, Lo, Count, OrigPtr: Integer;
  StoredCRC, CombinedCRC: UInt32;
  Randomised: Boolean;
begin
  if GetBits(8) <> Ord('B') then Exit(False);
  if GetBits(8) <> Ord('Z') then Exit(False);
  if GetBits(8) <> Ord('h') then Exit(False);
  Level := Integer(GetBits(8)) - Ord('0');
  if (Level < 1) or (Level > 9) then
    Exit(False);

  FBlockMax := Level * 100000;
  if Length(FTT) < FBlockMax then
    SetLength(FTT, FBlockMax);

  CombinedCRC := 0;
  repeat
    Hi := GetBits(24);
    Lo := GetBits(24);
    StoredCRC := GetBits(32);

    if (Hi = EndMagicHi) and (Lo = EndMagicLo) then
    begin
      if StoredCRC <> CombinedCRC then
        Fail('stream CRC mismatch');
      AlignToByte;
      Exit(True);
    end;

    if (Hi <> BlockMagicHi) or (Lo <> BlockMagicLo) then
      Fail('bad block header');

    Count := ReadBlock(OrigPtr, Randomised);
    EmitBlock(Count, OrigPtr, Randomised);
    if FBlockCRC <> StoredCRC then
      Fail('block CRC mismatch');
    CombinedCRC := ((CombinedCRC shl 1) or (CombinedCRC shr 31)) xor FBlockCRC;
  until False;
end;

procedure TBZ2Decoder.Run;
begin
  try
    if not DecodeStream then
      Fail('not a bzip2 stream');
    // Concatenated streams; anything that is not a new header is trailing
    // garbage and is ignored (same as the reference tool).
    while MoreInput do
      if not DecodeStream then
        Break;
  finally
    Flush;
  end;
end;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

procedure BZ2Decompress(InStream, OutStream: TStream);
var
  D: TBZ2Decoder;
begin
  D := TBZ2Decoder.Create(InStream, OutStream);
  try
    D.Run;
  finally
    D.Free;
  end;
end;

function BZ2DecompressBytes(const Data: TBytes): TBytes;
var
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Src := TBytesStream.Create(Data);
  Dst := TMemoryStream.Create;
  try
    BZ2Decompress(Src, Dst);
    SetLength(Result, Dst.Size);
    if Dst.Size > 0 then
      Move(Dst.Memory^, Result[0], Dst.Size);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure BZ2DecompressFile(const InName, OutName: string);
var
  Src, Dst: TFileStream;
begin
  Src := TFileStream.Create(InName, fmOpenRead or fmShareDenyWrite);
  try
    Dst := TFileStream.Create(OutName, fmCreate);
    try
      BZ2Decompress(Src, Dst);
    finally
      Dst.Free;
    end;
  finally
    Src.Free;
  end;
end;

initialization
  BuildCRCTable;
end.
