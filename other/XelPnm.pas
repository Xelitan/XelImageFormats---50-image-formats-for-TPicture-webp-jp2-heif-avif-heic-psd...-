unit XelPnm;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, XelPng;

type
  EPnmError = class(Exception);

function DecodePnm(InBuf: TBytes; out Width, Height: Integer): TBytes; // RGBA8
function EncodePnm(InBuf: TBytes; Width, Height: Integer): TBytes;      // InBuf = RGBA8

implementation

type
  TPnmKind = (pnmPBM, pnmPGM, pnmPPM);
  TPnmEncoding = (pnmAscii, pnmBinary);

function IsWS(B: Byte): Boolean; inline;
begin
  Result := (B = 9) or (B = 10) or (B = 11) or (B = 12) or (B = 13) or (B = 32);
end;

procedure SkipWSAndComments(const Data: TBytes; var Pos: NativeUInt);
var
  N: NativeUInt;
begin
  N := NativeUInt(Length(Data));
  while Pos < N do
  begin
    if IsWS(Data[Pos]) then
    begin
      Inc(Pos);
      Continue;
    end;
    if Data[Pos] = Ord('#') then
    begin
      Inc(Pos);
      while (Pos < N) and (Data[Pos] <> 10) and (Data[Pos] <> 13) do
        Inc(Pos);
      Continue;
    end;
    Break;
  end;
end;

function NextToken(const Data: TBytes; var Pos: NativeUInt): AnsiString;
var
  Start, N: NativeUInt;
begin
  Result := '';
  SkipWSAndComments(Data, Pos);
  N := NativeUInt(Length(Data));
  if Pos >= N then
    raise EPnmError.Create('PNM: unexpected end of header/data');
  Start := Pos;
  while (Pos < N) and (not IsWS(Data[Pos])) and (Data[Pos] <> Ord('#')) do
    Inc(Pos);
  if Pos = Start then
    raise EPnmError.Create('PNM: expected token');
  SetLength(Result, Pos - Start);
  if Length(Result) <> 0 then
    Move(Data[Start], Result[1], Length(Result));
end;

function ParseUIntToken(const S: AnsiString; const What: string): UInt64;
var
  I: Integer;
  D: Byte;
begin
  if Length(S) = 0 then
    raise EPnmError.Create('PNM: missing ' + What);
  Result := 0;
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] < '0') or (S[I] > '9') then
      raise EPnmError.Create('PNM: invalid ' + What);
    D := Ord(S[I]) - Ord('0');
    if Result > (High(UInt64) - D) div 10 then
      raise EPnmError.Create('PNM: numeric overflow in ' + What);
    Result := Result * 10 + D;
    Inc(I);
  end;
end;

procedure ConsumeBinarySeparator(const Data: TBytes; var Pos: NativeUInt);
var
  N: NativeUInt;
begin
  N := NativeUInt(Length(Data));
  if (Pos >= N) or (not IsWS(Data[Pos])) then
    raise EPnmError.Create('PNM: missing whitespace before binary raster');
  if (Data[Pos] = 13) and (Pos + 1 < N) and (Data[Pos + 1] = 10) then
    Inc(Pos, 2)
  else
    Inc(Pos);
end;

function ScaleTo8(V, MaxVal: Cardinal): Byte; inline;
begin
  Result := Byte((UInt64(V) * 255 + (MaxVal div 2)) div MaxVal);
end;

procedure SetGray(var C: TRGBA; V: Byte); inline;
begin
  C.R := V;
  C.G := V;
  C.B := V;
  C.A := 255;
end;

procedure SetRGB(var C: TRGBA; R, G, B: Byte); inline;
begin
  C.R := R;
  C.G := G;
  C.B := B;
  C.A := 255;
end;

function ReadBinarySample(const Data: TBytes; var Pos: NativeUInt;
  MaxVal: Cardinal): Cardinal; inline;
var
  N: NativeUInt;
begin
  N := NativeUInt(Length(Data));
  if MaxVal < 256 then
  begin
    if Pos >= N then
      raise EPnmError.Create('PNM: truncated binary raster');
    Result := Data[Pos];
    Inc(Pos);
  end
  else
  begin
    if (Pos > N) or (N - Pos < 2) then
      raise EPnmError.Create('PNM: truncated 16-bit binary raster');
    Result := (Cardinal(Data[Pos]) shl 8) or Cardinal(Data[Pos + 1]);
    Inc(Pos, 2);
  end;
  if Result > MaxVal then
    raise EPnmError.Create('PNM: sample exceeds MaxVal');
end;

function DecodePnm(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Pos, X, Y, RowBytes, BytePos: NativeUInt;
  Magic, Tok: AnsiString;
  W64, H64, M64: UInt64;
  W, H, MaxVal: Cardinal;
  Kind: TPnmKind;
  Enc: TPnmEncoding;
  V, R, G, B: Cardinal;
  Mask: Byte;
  C: TRGBA;
begin
  Width := 0;
  Height := 0;
  SetLength(Result, 0);
  Pos := 0;
  Magic := NextToken(InBuf, Pos);
  if Length(Magic) <> 2 then
    raise EPnmError.Create('PNM: invalid magic');

  if Magic = 'P1' then begin Kind := pnmPBM; Enc := pnmAscii; end
  else if Magic = 'P2' then begin Kind := pnmPGM; Enc := pnmAscii; end
  else if Magic = 'P3' then begin Kind := pnmPPM; Enc := pnmAscii; end
  else if Magic = 'P4' then begin Kind := pnmPBM; Enc := pnmBinary; end
  else if Magic = 'P5' then begin Kind := pnmPGM; Enc := pnmBinary; end
  else if Magic = 'P6' then begin Kind := pnmPPM; Enc := pnmBinary; end
  else
    raise EPnmError.Create('PNM: unsupported magic ' + string(Magic));

  W64 := ParseUIntToken(NextToken(InBuf, Pos), 'width');
  H64 := ParseUIntToken(NextToken(InBuf, Pos), 'height');
  if (W64 = 0) or (H64 = 0) or (W64 > UInt64(High(Integer))) or
     (H64 > UInt64(High(Integer))) then
    raise EPnmError.Create('PNM: invalid image dimensions');
  W := Cardinal(W64);
  H := Cardinal(H64);

  if Kind = pnmPBM then
    MaxVal := 1
  else
  begin
    M64 := ParseUIntToken(NextToken(InBuf, Pos), 'MaxVal');
    if (M64 = 0) or (M64 > 65535) then
      raise EPnmError.Create('PNM: MaxVal must be 1..65535');
    MaxVal := Cardinal(M64);
  end;

  if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then
    raise EPnmError.Create('PNM: image too large');
  Width := Integer(W);
  Height := Integer(H);
  SetLength(Result, NativeInt(UInt64(W) * UInt64(H) * 4));

  if Enc = pnmBinary then
    ConsumeBinarySeparator(InBuf, Pos);

  if (Kind = pnmPBM) and (Enc = pnmBinary) then
  begin
    RowBytes := (NativeUInt(W) + 7) div 8;
    if (NativeUInt(H) <> 0) and (RowBytes > High(NativeUInt) div NativeUInt(H)) then
      raise EPnmError.Create('PNM: image too large');
    if (Pos > NativeUInt(Length(InBuf))) or
       (RowBytes * NativeUInt(H) > NativeUInt(Length(InBuf)) - Pos) then
      raise EPnmError.Create('PNM: truncated PBM raster');
    Y := 0;
    while Y < H do
    begin
      X := 0;
      while X < W do
      begin
        BytePos := Pos + Y * RowBytes + (X shr 3);
        Mask := Byte($80 shr (X and 7));
        if (InBuf[BytePos] and Mask) <> 0 then
          begin SetGray(C, 0); SetPx(Result, Integer(W), Integer(X), Integer(Y), C); end
        else
          begin SetGray(C, 255); SetPx(Result, Integer(W), Integer(X), Integer(Y), C); end;
        Inc(X);
      end;
      Inc(Y);
    end;
    Exit;
  end;

  Y := 0;
  while Y < H do
  begin
    X := 0;
    while X < W do
    begin
      case Kind of
        pnmPBM:
          begin
            Tok := NextToken(InBuf, Pos);
            V := Cardinal(ParseUIntToken(Tok, 'PBM sample'));
            if V > 1 then
              raise EPnmError.Create('PNM: PBM sample must be 0 or 1');
            if V = 0 then begin SetGray(C, 255); SetPx(Result, Integer(W), Integer(X), Integer(Y), C); end
            else begin SetGray(C, 0); SetPx(Result, Integer(W), Integer(X), Integer(Y), C); end;
          end;
        pnmPGM:
          begin
            if Enc = pnmAscii then
              V := Cardinal(ParseUIntToken(NextToken(InBuf, Pos), 'PGM sample'))
            else
              V := ReadBinarySample(InBuf, Pos, MaxVal);
            if V > MaxVal then
              raise EPnmError.Create('PNM: sample exceeds MaxVal');
            SetGray(C, ScaleTo8(V, MaxVal));
            SetPx(Result, Integer(W), Integer(X), Integer(Y), C);
          end;
        pnmPPM:
          begin
            if Enc = pnmAscii then
            begin
              R := Cardinal(ParseUIntToken(NextToken(InBuf, Pos), 'PPM red sample'));
              G := Cardinal(ParseUIntToken(NextToken(InBuf, Pos), 'PPM green sample'));
              B := Cardinal(ParseUIntToken(NextToken(InBuf, Pos), 'PPM blue sample'));
              if (R > MaxVal) or (G > MaxVal) or (B > MaxVal) then
                raise EPnmError.Create('PNM: sample exceeds MaxVal');
            end
            else
            begin
              R := ReadBinarySample(InBuf, Pos, MaxVal);
              G := ReadBinarySample(InBuf, Pos, MaxVal);
              B := ReadBinarySample(InBuf, Pos, MaxVal);
            end;
            SetRGB(C, ScaleTo8(R, MaxVal), ScaleTo8(G, MaxVal), ScaleTo8(B, MaxVal));
            SetPx(Result, Integer(W), Integer(X), Integer(Y), C);
          end;
      end;
      Inc(X);
    end;
    Inc(Y);
  end;
end;

procedure AppendByte(var D: TBytes; B: Byte); inline;
var
  N: NativeInt;
begin
  N := Length(D);
  SetLength(D, N + 1);
  D[N] := B;
end;

procedure AppendAnsi(var D: TBytes; const S: AnsiString);
var
  N, L: NativeInt;
begin
  L := Length(S);
  if L = 0 then Exit;
  N := Length(D);
  SetLength(D, N + L);
  Move(S[1], D[N], L);
end;

procedure AppendSampleBinary(var D: TBytes; V, MaxVal: Cardinal); inline;
begin
  if MaxVal < 256 then
    AppendByte(D, Byte(V))
  else
  begin
    AppendByte(D, Byte(V shr 8));
    AppendByte(D, Byte(V));
  end;
end;

function Luma8(const C: TRGBA): Byte; inline;
begin
  Result := Byte((Cardinal(C.R) * 77 + Cardinal(C.G) * 150 +
                  Cardinal(C.B) * 29 + 128) shr 8);
end;

function ScaleFrom8(V: Byte; MaxVal: Cardinal): Cardinal; inline;
begin
  Result := Cardinal((UInt64(V) * MaxVal + 127) div 255);
end;

procedure AppendAsciiToken(var D: TBytes; const S: AnsiString; var LineLen: Integer);
begin
  if LineLen = 0 then
  begin
    AppendAnsi(D, S);
    LineLen := Length(S);
  end
  else if LineLen + 1 + Length(S) > 70 then
  begin
    AppendByte(D, 10);
    AppendAnsi(D, S);
    LineLen := Length(S);
  end
  else
  begin
    AppendByte(D, Ord(' '));
    AppendAnsi(D, S);
    Inc(LineLen, 1 + Length(S));
  end;
end;

function EncodePnm(InBuf: TBytes; Width, Height: Integer): TBytes;
const
  Kind = pnmPPM;
  Encoding = pnmBinary;
  MaxVal: Word = 255;
var
  Magic: AnsiString;
  X, Y, RowBytes, Base: NativeUInt;
  C: TRGBA;
  V, R, G, B: Cardinal;
  LineLen: Integer;
  Tok: AnsiString;
  BitMask: Byte;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then
    raise EPnmError.Create('PNM: zero image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EPnmError.Create('PNM: RGBA8 buffer size does not match Width*Height*4');
  if (Kind <> pnmPBM) and (MaxVal = 0) then
    raise EPnmError.Create('PNM: MaxVal must be 1..65535');

  case Kind of
    pnmPBM: if Encoding = pnmBinary then Magic := 'P4' else Magic := 'P1';
    pnmPGM: if Encoding = pnmBinary then Magic := 'P5' else Magic := 'P2';
  else
    if Encoding = pnmBinary then Magic := 'P6' else Magic := 'P3';
  end;

  AppendAnsi(Result, Magic + #10 + AnsiString(IntToStr(Width)) + ' ' +
    AnsiString(IntToStr(Height)) + #10);
  if Kind <> pnmPBM then
    AppendAnsi(Result, AnsiString(IntToStr(MaxVal)) + #10);

  if (Kind = pnmPBM) and (Encoding = pnmBinary) then
  begin
    RowBytes := (NativeUInt(Width) + 7) div 8;
    Base := Length(Result);
    if (NativeUInt(Height) <> 0) and
       (RowBytes > (NativeUInt(High(NativeInt)) - Base) div NativeUInt(Height)) then
      raise EPnmError.Create('PNM: output too large');
    SetLength(Result, NativeInt(Base + RowBytes * NativeUInt(Height)));
    if RowBytes * NativeUInt(Height) <> 0 then
      FillChar(Result[Base], RowBytes * NativeUInt(Height), 0);
    Y := 0;
    while Y < Height do
    begin
      X := 0;
      while X < Width do
      begin
        if Luma8(GetPx(InBuf, Width, Integer(X), Integer(Y))) < 128 then
        begin
          BitMask := Byte($80 shr (X and 7));
          Result[Base + Y * RowBytes + (X shr 3)] :=
            Result[Base + Y * RowBytes + (X shr 3)] or BitMask;
        end;
        Inc(X);
      end;
      Inc(Y);
    end;
    Exit;
  end;

  if Encoding = pnmBinary then
  begin
    Y := 0;
    while Y < Height do
    begin
      X := 0;
      while X < Width do
      begin
        C := GetPx(InBuf, Width, Integer(X), Integer(Y));
        case Kind of
          pnmPGM:
            begin
              V := ScaleFrom8(Luma8(C), MaxVal);
              AppendSampleBinary(Result, V, MaxVal);
            end;
          pnmPPM:
            begin
              R := ScaleFrom8(C.R, MaxVal);
              G := ScaleFrom8(C.G, MaxVal);
              B := ScaleFrom8(C.B, MaxVal);
              AppendSampleBinary(Result, R, MaxVal);
              AppendSampleBinary(Result, G, MaxVal);
              AppendSampleBinary(Result, B, MaxVal);
            end;
        end;
        Inc(X);
      end;
      Inc(Y);
    end;
  end
  else
  begin
    LineLen := 0;
    Y := 0;
    while Y < Height do
    begin
      X := 0;
      while X < Width do
      begin
        C := GetPx(InBuf, Width, Integer(X), Integer(Y));
        case Kind of
          pnmPBM:
            begin
              if Luma8(C) < 128 then Tok := '1' else Tok := '0';
              AppendAsciiToken(Result, Tok, LineLen);
            end;
          pnmPGM:
            begin
              V := ScaleFrom8(Luma8(C), MaxVal);
              AppendAsciiToken(Result, AnsiString(IntToStr(V)), LineLen);
            end;
          pnmPPM:
            begin
              R := ScaleFrom8(C.R, MaxVal);
              G := ScaleFrom8(C.G, MaxVal);
              B := ScaleFrom8(C.B, MaxVal);
              AppendAsciiToken(Result, AnsiString(IntToStr(R)), LineLen);
              AppendAsciiToken(Result, AnsiString(IntToStr(G)), LineLen);
              AppendAsciiToken(Result, AnsiString(IntToStr(B)), LineLen);
            end;
        end;
        Inc(X);
      end;
      Inc(Y);
    end;
    if LineLen <> 0 then
      AppendByte(Result, 10);
  end;
end;

end.
