unit XelGif;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, XelPng;

type
  EGifError = class(Exception);

function DecodeGif(InBuf: TBytes; out Width, Height: Integer): TBytes; // RGBA8
function EncodeGif(InBuf: TBytes; Width, Height: Integer): TBytes;      // InBuf = RGBA8

implementation

type
  TRGBAPalette = array of TRGBA;

const
  GIF_MAX_CODE = 4095;
  GIF_HASH_SIZE = 8192; // power of two, comfortably larger than 4096 codes

procedure Need(const Data: TBytes; Pos, Count: NativeUInt); inline;
begin
  if (Pos > NativeUInt(Length(Data))) or
     (Count > NativeUInt(Length(Data)) - Pos) then
    raise EGifError.Create('GIF: unexpected end of file');
end;

function ReadLE16(const Data: TBytes; var Pos: NativeUInt): Word; inline;
begin
  Need(Data, Pos, 2);
  Result := Word(Data[Pos]) or (Word(Data[Pos + 1]) shl 8);
  Inc(Pos, 2);
end;

procedure AppendByte(var D: TBytes; B: Byte); inline;
var
  N: NativeInt;
begin
  N := Length(D);
  SetLength(D, N + 1);
  D[N] := B;
end;

procedure AppendLE16(var D: TBytes; W: Word); inline;
begin
  AppendByte(D, Byte(W));
  AppendByte(D, Byte(W shr 8));
end;

procedure AppendText(var D: TBytes; const S: AnsiString);
var
  N, L: NativeInt;
begin
  L := Length(S);
  if L = 0 then Exit;
  N := Length(D);
  SetLength(D, N + L);
  Move(S[1], D[N], L);
end;

function ReadColorTable(const Data: TBytes; var Pos: NativeUInt;
  Count: Integer): TRGBAPalette;
var
  I: Integer;
begin
  SetLength(Result, 0);
  if (Count < 2) or (Count > 256) then
    raise EGifError.Create('GIF: invalid color table size');
  Need(Data, Pos, NativeUInt(Count) * 3);
  SetLength(Result, Count);
  I := 0;
  while I < Count do
  begin
    Result[I].R := Data[Pos];
    Result[I].G := Data[Pos + 1];
    Result[I].B := Data[Pos + 2];
    Result[I].A := 255;
    Inc(Pos, 3);
    Inc(I);
  end;
end;

function ReadSubBlocks(const Data: TBytes; var Pos: NativeUInt): TBytes;
var
  N, Old: NativeInt;
begin
  SetLength(Result, 0);
  while True do
  begin
    Need(Data, Pos, 1);
    N := Data[Pos];
    Inc(Pos);
    if N = 0 then Break;
    Need(Data, Pos, N);
    Old := Length(Result);
    SetLength(Result, Old + N);
    Move(Data[Pos], Result[Old], N);
    Inc(Pos, N);
  end;
end;

procedure SkipSubBlocks(const Data: TBytes; var Pos: NativeUInt);
var
  N: NativeUInt;
begin
  while True do
  begin
    Need(Data, Pos, 1);
    N := Data[Pos];
    Inc(Pos);
    if N = 0 then Exit;
    Need(Data, Pos, N);
    Inc(Pos, N);
  end;
end;

function GifLZWDecode(const PackedData: TBytes; MinCodeSize: Byte;
  ExpectedCount: NativeUInt): TBytes;
var
  Prefix: array[0..GIF_MAX_CODE] of SmallInt;
  Suffix: array[0..GIF_MAX_CODE] of Byte;
  Stack: array[0..GIF_MAX_CODE] of Byte;
  ClearCode, EndCode, NextCode, CodeSize: Integer;
  OldCode, Code, InCode, FirstChar: Integer;
  StackTop: Integer;
  BitPos, TotalBits, OutPos: NativeUInt;

  procedure ResetTable;
  var
    K: Integer;
  begin
    K := 0;
    while K < ClearCode do
    begin
      Prefix[K] := -1;
      Suffix[K] := Byte(K);
      Inc(K);
    end;
    NextCode := EndCode + 1;
    CodeSize := MinCodeSize + 1;
    OldCode := -1;
  end;

  function ReadCode: Integer;
  var
    K: Integer;
    P: NativeUInt;
  begin
    if BitPos + NativeUInt(CodeSize) > TotalBits then
      Exit(-1);
    Result := 0;
    K := 0;
    while K < CodeSize do
    begin
      P := BitPos + NativeUInt(K);
      if (PackedData[P shr 3] and (Byte(1) shl (P and 7))) <> 0 then
        Result := Result or (1 shl K);
      Inc(K);
    end;
    Inc(BitPos, CodeSize);
  end;

  procedure Emit(B: Byte); inline;
  begin
    if OutPos >= ExpectedCount then
      raise EGifError.Create('GIF: LZW produced too much image data');
    Result[OutPos] := B;
    Inc(OutPos);
  end;

begin
  SetLength(Result, 0);
  if (MinCodeSize < 2) or (MinCodeSize > 8) then
    raise EGifError.CreateFmt('GIF: invalid LZW minimum code size %d', [MinCodeSize]);
  if ExpectedCount > NativeUInt(MaxInt) then
    raise EGifError.Create('GIF: image is too large');

  SetLength(Result, NativeInt(ExpectedCount));
  if ExpectedCount = 0 then Exit;

  ClearCode := 1 shl MinCodeSize;
  EndCode := ClearCode + 1;
  BitPos := 0;
  TotalBits := NativeUInt(Length(PackedData)) * 8;
  OutPos := 0;
  ResetTable;

  while True do
  begin
    Code := ReadCode;
    if Code < 0 then
      raise EGifError.Create('GIF: truncated LZW stream');

    if Code = ClearCode then
    begin
      ResetTable;
      Continue;
    end;
    if Code = EndCode then Break;

    if OldCode < 0 then
    begin
      if (Code < 0) or (Code >= ClearCode) then
        raise EGifError.Create('GIF: invalid first LZW code');
      FirstChar := Code;
      Emit(Byte(Code));
      OldCode := Code;
      Continue;
    end;

    InCode := Code;
    StackTop := 0;
    if Code = NextCode then
    begin
      if StackTop > GIF_MAX_CODE then
        raise EGifError.Create('GIF: LZW stack overflow');
      Stack[StackTop] := Byte(FirstChar);
      Inc(StackTop);
      Code := OldCode;
    end
    else if (Code < 0) or (Code > NextCode) then
      raise EGifError.Create('GIF: invalid LZW dictionary code');

    while Code >= ClearCode do
    begin
      if (Code > GIF_MAX_CODE) or (StackTop > GIF_MAX_CODE) then
        raise EGifError.Create('GIF: invalid LZW dictionary chain');
      Stack[StackTop] := Suffix[Code];
      Inc(StackTop);
      Code := Prefix[Code];
      if Code < 0 then
        raise EGifError.Create('GIF: broken LZW dictionary chain');
    end;

    if (Code < 0) or (Code >= ClearCode) then
      raise EGifError.Create('GIF: invalid LZW root code');
    FirstChar := Code;
    if StackTop > GIF_MAX_CODE then
      raise EGifError.Create('GIF: LZW stack overflow');
    Stack[StackTop] := Byte(FirstChar);
    Inc(StackTop);

    while StackTop > 0 do
    begin
      Dec(StackTop);
      Emit(Stack[StackTop]);
    end;

    if NextCode <= GIF_MAX_CODE then
    begin
      Prefix[NextCode] := OldCode;
      Suffix[NextCode] := Byte(FirstChar);
      Inc(NextCode);
      if (NextCode = (1 shl CodeSize)) and (CodeSize < 12) then
        Inc(CodeSize);
    end;
    OldCode := InCode;
  end;

  if OutPos <> ExpectedCount then
    raise EGifError.CreateFmt('GIF: LZW decoded %d pixels, expected %d',
      [UInt64(OutPos), UInt64(ExpectedCount)]);
end;

procedure InitPixels(var B: TBytes; W, H: Cardinal; const Fill: TRGBA);
var
  I, Count: NativeUInt;
begin
  if (UInt64(W) > UInt64(MaxInt)) or (UInt64(H) > UInt64(MaxInt)) or
     (UInt64(W) * UInt64(H) * 4 > UInt64(MaxInt)) then
    raise EGifError.Create('GIF: image dimensions are too large');
  Count := NativeUInt(W) * NativeUInt(H);
  SetLength(B, NativeInt(Count * 4));
  I := 0;
  while I < Count do
  begin
    B[I * 4] := Fill.R;
    B[I * 4 + 1] := Fill.G;
    B[I * 4 + 2] := Fill.B;
    B[I * 4 + 3] := Fill.A;
    Inc(I);
  end;
end;

procedure SetBufferAlpha(var B: TBytes; A: Byte);
var
  I: NativeInt;
begin
  I := 3;
  while I < Length(B) do
  begin
    B[I] := A;
    Inc(I, 4);
  end;
end;

procedure PaintGifImage(var Canvas: TBytes; CanvasW, CanvasH: Integer;
  Left, Top, W, H: Word; Interlaced: Boolean; const Palette: TRGBAPalette;
  const Indices: TBytes; HasTransparency: Boolean; TransparentIndex: Byte);
const
  StartRow: array[0..3] of Integer = (0, 4, 2, 1);
  RowStep: array[0..3] of Integer = (8, 8, 4, 2);
var
  P: NativeUInt;
  Row, Pass, Y: Integer;
  Idx: Byte;
  C: TRGBA;

  procedure PaintRow(DstY: Integer);
  var
    X: Integer;
  begin
    if DstY >= Integer(H) then Exit;
    X := 0;
    while X < Integer(W) do
    begin
      if P >= NativeUInt(Length(Indices)) then
        raise EGifError.Create('GIF: truncated decoded pixel data');
      Idx := Indices[P];
      Inc(P);
      if Integer(Idx) >= Length(Palette) then
        raise EGifError.Create('GIF: palette index out of range');
      if not (HasTransparency and (Idx = TransparentIndex)) then
      begin
        C := Palette[Idx];
        C.A := 255;
        SetPx(Canvas, CanvasW, Integer(Left) + X, Integer(Top) + DstY, C);
      end;
      Inc(X);
    end;
  end;

begin
  if (UInt64(Left) + UInt64(W) > UInt64(CanvasW)) or
     (UInt64(Top) + UInt64(H) > UInt64(CanvasH)) then
    raise EGifError.Create('GIF: image rectangle lies outside logical canvas');

  P := 0;
  if not Interlaced then
  begin
    Row := 0;
    while Row < Integer(H) do
    begin
      PaintRow(Row);
      Inc(Row);
    end;
  end
  else
  begin
    Pass := 0;
    while Pass <= 3 do
    begin
      Y := StartRow[Pass];
      while Y < Integer(H) do
      begin
        PaintRow(Y);
        Inc(Y, RowStep[Pass]);
      end;
      Inc(Pass);
    end;
  end;

  if P <> NativeUInt(Length(Indices)) then
    raise EGifError.Create('GIF: unexpected extra decoded pixel data');
end;

function DecodeGif(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Pos: NativeUInt;
  Header: AnsiString;
  ScreenW, ScreenH: Word;
  PackedField, BackgroundIndex: Byte;
  GCTSize, LCTSize: Integer;
  GlobalPalette, LocalPalette: TRGBAPalette;
  Fill: TRGBA;
  Marker, LabelByte, BlockSize, GcePacked, TransparentIndex: Byte;
  HasTransparency: Boolean;
  Left, Top, W, H: Word;
  Interlaced: Boolean;
  MinCodeSize: Byte;
  LZWInBuf, Indices: TBytes;
  Palette: TRGBAPalette;
begin
  Width := 0;
  Height := 0;
  SetLength(Result, 0);

  if Length(InBuf) < 13 then
    raise EGifError.Create('GIF: file too small');
  SetLength(Header, 6);
  Move(InBuf[0], Header[1], 6);
  if (Header <> 'GIF87a') and (Header <> 'GIF89a') then
    raise EGifError.Create('GIF: bad signature');

  Pos := 6;
  ScreenW := ReadLE16(InBuf, Pos);
  ScreenH := ReadLE16(InBuf, Pos);
  if (ScreenW = 0) or (ScreenH = 0) then
    raise EGifError.Create('GIF: zero logical screen size');
  Need(InBuf, Pos, 3);
  PackedField := InBuf[Pos];
  BackgroundIndex := InBuf[Pos + 1];
  Inc(Pos, 3); // packed, background index, pixel aspect ratio

  if (PackedField and $80) <> 0 then
  begin
    GCTSize := 1 shl ((PackedField and 7) + 1);
    GlobalPalette := ReadColorTable(InBuf, Pos, GCTSize);
  end;

  Fill.R := 0; Fill.G := 0; Fill.B := 0; Fill.A := 0;
  if (Length(GlobalPalette) <> 0) and (BackgroundIndex < Length(GlobalPalette)) then
  begin
    Fill := GlobalPalette[BackgroundIndex];
    Fill.A := 255;
  end;
  Width := Integer(ScreenW);
  Height := Integer(ScreenH);
  InitPixels(Result, ScreenW, ScreenH, Fill);

  HasTransparency := False;
  TransparentIndex := 0;

  while True do
  begin
    Need(InBuf, Pos, 1);
    Marker := InBuf[Pos];
    Inc(Pos);
    case Marker of
      $3B:
        raise EGifError.Create('GIF: no image frame found');

      $21:
        begin
          Need(InBuf, Pos, 1);
          LabelByte := InBuf[Pos];
          Inc(Pos);
          if LabelByte = $F9 then
          begin
            Need(InBuf, Pos, 1);
            BlockSize := InBuf[Pos];
            Inc(Pos);
            if BlockSize <> 4 then
              raise EGifError.Create('GIF: invalid graphic control extension');
            Need(InBuf, Pos, 5);
            GcePacked := InBuf[Pos];
            // delay is InBuf[Pos+1..2], intentionally ignored
            TransparentIndex := InBuf[Pos + 3];
            HasTransparency := (GcePacked and 1) <> 0;
            Inc(Pos, 4);
            if InBuf[Pos] <> 0 then
              raise EGifError.Create('GIF: invalid graphic control terminator');
            Inc(Pos);
          end
          else
          begin
            SkipSubBlocks(InBuf, Pos);
            // A GCE is consumed by a Plain Text Extension as well.
            if LabelByte = $01 then
            begin
              HasTransparency := False;
              TransparentIndex := 0;
            end;
          end;
        end;

      $2C:
        begin
          Left := ReadLE16(InBuf, Pos);
          Top := ReadLE16(InBuf, Pos);
          W := ReadLE16(InBuf, Pos);
          H := ReadLE16(InBuf, Pos);
          if (W = 0) or (H = 0) then
            raise EGifError.Create('GIF: zero image frame size');
          Need(InBuf, Pos, 1);
          PackedField := InBuf[Pos];
          Inc(Pos);
          Interlaced := (PackedField and $40) <> 0;

          if (PackedField and $80) <> 0 then
          begin
            LCTSize := 1 shl ((PackedField and 7) + 1);
            LocalPalette := ReadColorTable(InBuf, Pos, LCTSize);
            Palette := LocalPalette;
          end
          else
          begin
            if Length(GlobalPalette) = 0 then
              raise EGifError.Create('GIF: image has no color table');
            Palette := GlobalPalette;
          end;

          Need(InBuf, Pos, 1);
          MinCodeSize := InBuf[Pos];
          Inc(Pos);
          LZWInBuf := ReadSubBlocks(InBuf, Pos);
          Indices := GifLZWDecode(LZWInBuf, MinCodeSize,
            NativeUInt(W) * NativeUInt(H));
          if HasTransparency then
            SetBufferAlpha(Result, 0);
          PaintGifImage(Result, Width, Height, Left, Top, W, H, Interlaced, Palette, Indices,
            HasTransparency, TransparentIndex);
          Exit; // return the first frame
        end;
    else
      raise EGifError.CreateFmt('GIF: unexpected block marker $%.2x', [Marker]);
    end;
  end;
end;

function RGBKey(const C: TRGBA): Cardinal; inline;
begin
  Result := (Cardinal(C.R) shl 16) or (Cardinal(C.G) shl 8) or C.B;
end;

function ColorHash(Key: Cardinal): Cardinal; inline;
begin
  Result := (Key * Cardinal($9E3779B1)) and 1023;
end;

procedure BuildExactPalette(const InBuf: TBytes; Width, Height: Integer;
  AlphaThreshold: Byte; HasTransparency: Boolean; MaxOpaque: Integer;
  var Palette: TRGBAPalette;
  out Exact: Boolean);
var
  Slots: array[0..1023] of SmallInt;
  Slot: Cardinal;
  Key: Cardinal;
  Count, X, Y, I: Integer;
  C: TRGBA;
begin
  I := 0;
  while I <= High(Slots) do
  begin
    Slots[I] := -1;
    Inc(I);
  end;
  Count := 0;
  Exact := True;
  SetLength(Palette, 0);

  Y := 0;
  while Y < Height do
  begin
    X := 0;
    while X < Width do
    begin
      C := GetPx(InBuf, Width, X, Y);
      if C.A >= AlphaThreshold then
      begin
        Key := RGBKey(C);
        Slot := ColorHash(Key);
        while Slots[Slot] >= 0 do
        begin
          if RGBKey(Palette[Slots[Slot]]) = Key then Break;
          Slot := (Slot + 1) and 1023;
        end;
        if Slots[Slot] < 0 then
        begin
          if Count >= MaxOpaque then
          begin
            Exact := False;
            SetLength(Palette, 0);
            Exit;
          end;
          SetLength(Palette, Count + 1);
          Palette[Count] := C;
          Palette[Count].A := 255;
          Slots[Slot] := Count;
          Inc(Count);
        end;
      end;
      Inc(X);
    end;
    Inc(Y);
  end;
end;

procedure BuildQuantPalette(var Palette: TRGBAPalette; HasTransparency: Boolean);
var
  Offset, R, G, B, I: Integer;
begin
  if HasTransparency then Offset := 1 else Offset := 0;
  SetLength(Palette, Offset + 252); // 6 * 7 * 6
  if HasTransparency then
  begin
    Palette[0].R := 0; Palette[0].G := 0;
    Palette[0].B := 0; Palette[0].A := 0;
  end;
  I := Offset;
  R := 0;
  while R <= 5 do
  begin
    G := 0;
    while G <= 6 do
    begin
      B := 0;
      while B <= 5 do
      begin
        Palette[I].R := Byte((R * 255 + 2) div 5);
        Palette[I].G := Byte((G * 255 + 3) div 6);
        Palette[I].B := Byte((B * 255 + 2) div 5);
        Palette[I].A := 255;
        Inc(I);
        Inc(B);
      end;
      Inc(G);
    end;
    Inc(R);
  end;
end;

function PaletteBits(Count: Integer): Integer;
begin
  Result := 1;
  while (1 shl Result) < Count do Inc(Result);
  if Result > 8 then
    raise EGifError.Create('GIF: palette has more than 256 colors');
end;

function MakeIndexedPixels(const InBuf: TBytes; Width, Height: Integer;
  AlphaThreshold: Byte; HasTransparency, Exact: Boolean;
  const Palette: TRGBAPalette): TBytes;
var
  X, Y, P, Offset, Idx, I: Integer;
  C: TRGBA;
  RI, GI, BI: Integer;
  Key: Cardinal;
  Slots: array[0..1023] of SmallInt;
  Slot: Cardinal;
begin
  SetLength(Result, 0);
  if UInt64(Width) * UInt64(Height) > UInt64(MaxInt) then
    raise EGifError.Create('GIF: image is too large');
  SetLength(Result, NativeInt(UInt64(Width) * UInt64(Height)));
  if HasTransparency then Offset := 1 else Offset := 0;

  if Exact then
  begin
    I := 0;
    while I <= High(Slots) do
    begin
      Slots[I] := -1;
      Inc(I);
    end;
    I := Offset;
    while I <= High(Palette) do
    begin
      Key := RGBKey(Palette[I]);
      Slot := ColorHash(Key);
      while Slots[Slot] >= 0 do
        Slot := (Slot + 1) and 1023;
      Slots[Slot] := I;
      Inc(I);
    end;
  end;

  P := 0;
  Y := 0;
  while Y < Integer(Height) do
  begin
    X := 0;
    while X < Integer(Width) do
    begin
      C := GetPx(InBuf, Width, X, Y);
      if HasTransparency and (C.A < AlphaThreshold) then
        Idx := 0
      else if Exact then
      begin
        Key := RGBKey(C);
        Slot := ColorHash(Key);
        while (Slots[Slot] >= 0) and
              (RGBKey(Palette[Slots[Slot]]) <> Key) do
          Slot := (Slot + 1) and 1023;
        if Slots[Slot] < 0 then
          raise EGifError.Create('GIF: internal exact-palette lookup failure');
        Idx := Slots[Slot];
      end
      else
      begin
        RI := (Integer(C.R) * 5 + 127) div 255;
        GI := (Integer(C.G) * 6 + 127) div 255;
        BI := (Integer(C.B) * 5 + 127) div 255;
        Idx := Offset + RI * 42 + GI * 6 + BI;
      end;
      Result[P] := Byte(Idx);
      Inc(P);
      Inc(X);
    end;
    Inc(Y);
  end;
end;

function GifLZWEncode(const Indices: TBytes; MinCodeSize: Byte): TBytes;
var
  HashKey: array[0..GIF_HASH_SIZE - 1] of LongInt;
  HashCode: array[0..GIF_HASH_SIZE - 1] of SmallInt;
  ClearCode, EndCode, NextCode, CodeSize: Integer;
  PrefixCode, FoundCode, I: Integer;
  BitBuffer: Cardinal;
  BitCount: Integer;

  procedure ResetHash;
  var
    K: Integer;
  begin
    K := 0;
    while K < GIF_HASH_SIZE do
    begin
      HashCode[K] := -1;
      Inc(K);
    end;
    NextCode := EndCode + 1;
    CodeSize := MinCodeSize + 1;
  end;

  procedure WriteCode(Code: Integer);
  begin
    BitBuffer := BitBuffer or (Cardinal(Code) shl BitCount);
    Inc(BitCount, CodeSize);
    while BitCount >= 8 do
    begin
      AppendByte(Result, Byte(BitBuffer));
      BitBuffer := BitBuffer shr 8;
      Dec(BitCount, 8);
    end;
  end;

  function FindCode(APrefix: Integer; Suffix: Byte): Integer;
  var
    K: LongInt;
    H: Cardinal;
  begin
    K := (APrefix shl 8) or Suffix;
    H := (Cardinal(K) * Cardinal($9E3779B1)) and (GIF_HASH_SIZE - 1);
    while HashCode[H] >= 0 do
    begin
      if HashKey[H] = K then Exit(HashCode[H]);
      H := (H + 1) and (GIF_HASH_SIZE - 1);
    end;
    Result := -1;
  end;

  procedure AddCode(APrefix: Integer; Suffix: Byte);
  var
    K: LongInt;
    H: Cardinal;
  begin
    K := (APrefix shl 8) or Suffix;
    H := (Cardinal(K) * Cardinal($9E3779B1)) and (GIF_HASH_SIZE - 1);
    while HashCode[H] >= 0 do
      H := (H + 1) and (GIF_HASH_SIZE - 1);
    HashKey[H] := K;
    HashCode[H] := NextCode;
    Inc(NextCode);
    if (NextCode > (1 shl CodeSize)) and (CodeSize < 12) then
      Inc(CodeSize);
  end;

begin
  SetLength(Result, 0);
  if (MinCodeSize < 2) or (MinCodeSize > 8) then
    raise EGifError.Create('GIF: invalid encoder LZW code size');
  ClearCode := 1 shl MinCodeSize;
  EndCode := ClearCode + 1;
  BitBuffer := 0;
  BitCount := 0;
  ResetHash;
  WriteCode(ClearCode);

  if Length(Indices) <> 0 then
  begin
    PrefixCode := Indices[0];
    I := 1;
    while I < Length(Indices) do
    begin
      FoundCode := FindCode(PrefixCode, Indices[I]);
      if FoundCode >= 0 then
        PrefixCode := FoundCode
      else
      begin
        WriteCode(PrefixCode);
        if NextCode <= GIF_MAX_CODE then
          AddCode(PrefixCode, Indices[I])
        else
        begin
          WriteCode(ClearCode);
          ResetHash;
        end;
        PrefixCode := Indices[I];
      end;
      Inc(I);
    end;
    WriteCode(PrefixCode);
  end;
  WriteCode(EndCode);
  if BitCount > 0 then
    AppendByte(Result, Byte(BitBuffer));
end;

procedure AppendSubBlocks(var D: TBytes; const Payload: TBytes);
var
  P, N, I: Integer;
begin
  P := 0;
  while P < Length(Payload) do
  begin
    N := Length(Payload) - P;
    if N > 255 then N := 255;
    AppendByte(D, Byte(N));
    I := 0;
    while I < N do
    begin
      AppendByte(D, Payload[P + I]);
      Inc(I);
    end;
    Inc(P, N);
  end;
  AppendByte(D, 0);
end;

function EncodeGif(InBuf: TBytes; Width, Height: Integer): TBytes;
const
  AlphaThreshold: Byte = 128;
var
  X, Y, I, TableCount, Bits, MinCodeSize, MaxOpaque, Offset: Integer;
  HasTransparency, Exact: Boolean;
  Palette, OpaquePalette: TRGBAPalette;
  Indexed, PackedLZW: TBytes;
  C: TRGBA;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then
    raise EGifError.Create('GIF: zero image size');
  if (Width > 65535) or (Height > 65535) then
    raise EGifError.Create('GIF: dimensions exceed 65535 pixels');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EGifError.Create('GIF: RGBA8 buffer size does not match Width*Height*4');

  HasTransparency := False;
  Y := 0;
  while (Y < Integer(Height)) and not HasTransparency do
  begin
    X := 0;
    while X < Integer(Width) do
    begin
      if GetPx(InBuf, Width, X, Y).A < AlphaThreshold then
      begin
        HasTransparency := True;
        Break;
      end;
      Inc(X);
    end;
    Inc(Y);
  end;

  if HasTransparency then MaxOpaque := 255 else MaxOpaque := 256;
  BuildExactPalette(InBuf, Width, Height, AlphaThreshold, HasTransparency, MaxOpaque,
    OpaquePalette, Exact);

  if Exact then
  begin
    if HasTransparency then Offset := 1 else Offset := 0;
    SetLength(Palette, Length(OpaquePalette) + Offset);
    if HasTransparency then
    begin
      Palette[0].R := 0; Palette[0].G := 0;
      Palette[0].B := 0; Palette[0].A := 0;
    end;
    I := 0;
    while I <= High(OpaquePalette) do
    begin
      Palette[I + Offset] := OpaquePalette[I];
      Inc(I);
    end;
    // A fully transparent image still needs at least one logical palette color.
    if Length(Palette) = 0 then
    begin
      SetLength(Palette, 1);
      Palette[0].R := 0; Palette[0].G := 0;
      Palette[0].B := 0; Palette[0].A := 255;
    end;
  end
  else
    BuildQuantPalette(Palette, HasTransparency);

  Bits := PaletteBits(Length(Palette));
  TableCount := 1 shl Bits;
  if TableCount < 2 then TableCount := 2;
  MinCodeSize := Bits;
  if MinCodeSize < 2 then MinCodeSize := 2;

  Indexed := MakeIndexedPixels(InBuf, Width, Height, AlphaThreshold, HasTransparency, Exact, Palette);
  PackedLZW := GifLZWEncode(Indexed, Byte(MinCodeSize));

  AppendText(Result, 'GIF89a');
  AppendLE16(Result, Word(Width));
  AppendLE16(Result, Word(Height));
  // GCT flag | color resolution=8 bits | GCT size.
  AppendByte(Result, Byte($80 or $70 or (Bits - 1)));
  AppendByte(Result, 0); // background color index
  AppendByte(Result, 0); // pixel aspect ratio

  I := 0;
  while I < TableCount do
  begin
    if I < Length(Palette) then C := Palette[I]
    else begin C.R := 0; C.G := 0; C.B := 0; C.A := 255; end;
    AppendByte(Result, C.R);
    AppendByte(Result, C.G);
    AppendByte(Result, C.B);
    Inc(I);
  end;

  if HasTransparency then
  begin
    AppendByte(Result, $21); // extension introducer
    AppendByte(Result, $F9); // graphic control extension
    AppendByte(Result, 4);
    AppendByte(Result, 1);   // transparent color flag
    AppendLE16(Result, 0);   // delay
    AppendByte(Result, 0);   // transparent palette index
    AppendByte(Result, 0);   // terminator
  end;

  AppendByte(Result, $2C); // image separator
  AppendLE16(Result, 0);   // left
  AppendLE16(Result, 0);   // top
  AppendLE16(Result, Word(Width));
  AppendLE16(Result, Word(Height));
  AppendByte(Result, 0);   // no local table, not interlaced
  AppendByte(Result, Byte(MinCodeSize));
  AppendSubBlocks(Result, PackedLZW);
  AppendByte(Result, $3B); // trailer
end;

end.
