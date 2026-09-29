unit XelPFM;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, XelPng;

type
  EPfmError = class(Exception);

// Dekoduje PFM (Portable Float Map) do RGBA8. 'PF' = kolor (RGB, 3 x float32),
// 'Pf' = skala szarosci (1 x float32). Wiersze zapisane od dolu do gory; znak
// skali <0 = little-endian, >0 = big-endian. Wartosci HDR sa obcinane do [0,1]
// i skalowane do 0..255 (alfa = 255).
function DecodePfm(InBuf: TBytes; out Width, Height: Integer): TBytes;     // RGBA8

// Zapisuje PFM kolorowy ('PF', little-endian, skala -1.0). InBuf = RGBA8;
// kanaly R,G,B dzielone przez 255 -> float 0..1, alfa pomijana.
function EncodePfm(InBuf: TBytes; Width, Height: Integer): TBytes;         // InBuf = RGBA8

implementation

function IsWS(B: Byte): Boolean; inline;
begin
  Result := (B = 9) or (B = 10) or (B = 11) or (B = 12) or (B = 13) or (B = 32);
end;

function NextToken(const Data: TBytes; var Pos: NativeUInt): AnsiString;
var
  Start, N: NativeUInt;
begin
  Result := '';
  N := NativeUInt(Length(Data));
  while (Pos < N) and IsWS(Data[Pos]) do Inc(Pos);
  if Pos >= N then
    raise EPfmError.Create('PFM: unexpected end of header');
  Start := Pos;
  while (Pos < N) and (not IsWS(Data[Pos])) do Inc(Pos);
  SetLength(Result, Pos - Start);
  if Length(Result) <> 0 then
    Move(Data[Start], Result[1], Length(Result));
end;

procedure ConsumeSeparator(const Data: TBytes; var Pos: NativeUInt);
var
  N: NativeUInt;
begin
  N := NativeUInt(Length(Data));
  if (Pos >= N) or (not IsWS(Data[Pos])) then
    raise EPfmError.Create('PFM: missing whitespace before raster');
  if (Data[Pos] = 13) and (Pos + 1 < N) and (Data[Pos + 1] = 10) then
    Inc(Pos, 2)
  else
    Inc(Pos);
end;

function ParseUIntToken(const S: AnsiString; const What: string): UInt64;
var
  I: Integer;
  D: Byte;
begin
  if Length(S) = 0 then raise EPfmError.Create('PFM: missing ' + What);
  Result := 0;
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] < '0') or (S[I] > '9') then
      raise EPfmError.Create('PFM: invalid ' + What);
    D := Ord(S[I]) - Ord('0');
    if Result > (High(UInt64) - D) div 10 then
      raise EPfmError.Create('PFM: numeric overflow in ' + What);
    Result := Result * 10 + D;
    Inc(I);
  end;
end;

function ParseScale(const S: AnsiString): Single;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  try
    Result := StrToFloat(string(S), FS);
  except
    raise EPfmError.Create('PFM: invalid scale value');
  end;
  if Result = 0 then
    raise EPfmError.Create('PFM: scale must be non-zero');
end;

function BytesToSingle(const Data: TBytes; Pos: NativeUInt; Little: Boolean): Single;
var
  U: Cardinal;
begin
  if Little then
    U := Cardinal(Data[Pos]) or (Cardinal(Data[Pos + 1]) shl 8) or
         (Cardinal(Data[Pos + 2]) shl 16) or (Cardinal(Data[Pos + 3]) shl 24)
  else
    U := Cardinal(Data[Pos + 3]) or (Cardinal(Data[Pos + 2]) shl 8) or
         (Cardinal(Data[Pos + 1]) shl 16) or (Cardinal(Data[Pos]) shl 24);
  Move(U, Result, 4);   // reinterpretacja bitow jako Single (natywnie LE, cel x86)
end;

function FloatToByte(F: Single): Byte; inline;
begin
  // NaN nie spelnia zadnego porownania -> trafia do galezi 0
  if F > 1 then Result := 255
  else if F > 0 then Result := Byte(Round(F * 255))
  else Result := 0;
end;

function DecodePfm(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Pos, N, X, FileRow: NativeUInt;
  ImgY: Integer;
  Magic: AnsiString;
  W64, H64: UInt64;
  W, H, Channels: Cardinal;
  Scale: Single;
  Little: Boolean;
  NeedBytes: UInt64;
  R, G, B: Byte;
  C: TRGBA;
begin
  Width := 0;
  Height := 0;
  SetLength(Result, 0);

  Pos := 0;
  Magic := NextToken(InBuf, Pos);
  if Magic = 'PF' then Channels := 3
  else if Magic = 'Pf' then Channels := 1
  else
    raise EPfmError.Create('PFM: invalid magic (expected PF or Pf)');

  W64 := ParseUIntToken(NextToken(InBuf, Pos), 'width');
  H64 := ParseUIntToken(NextToken(InBuf, Pos), 'height');
  if (W64 = 0) or (H64 = 0) or (W64 > UInt64(High(Integer))) or
     (H64 > UInt64(High(Integer))) then
    raise EPfmError.Create('PFM: invalid image dimensions');
  W := Cardinal(W64);
  H := Cardinal(H64);

  Scale := ParseScale(NextToken(InBuf, Pos));
  Little := Scale < 0;

  ConsumeSeparator(InBuf, Pos);

  NeedBytes := UInt64(W) * UInt64(H) * UInt64(Channels) * 4;
  N := NativeUInt(Length(InBuf));
  if (Pos > N) or (NeedBytes > UInt64(N) - UInt64(Pos)) then
    raise EPfmError.Create('PFM: truncated float raster');
  if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then
    raise EPfmError.Create('PFM: image too large');

  Width := Integer(W);
  Height := Integer(H);
  SetLength(Result, NativeInt(UInt64(W) * UInt64(H) * 4));

  // plik przechowuje wiersze od dolu do gory: pierwszy wiersz w pliku = dol obrazu
  FileRow := 0;
  while FileRow < H do
  begin
    ImgY := Integer(H) - 1 - Integer(FileRow);
    X := 0;
    while X < W do
    begin
      if Channels = 3 then
      begin
        R := FloatToByte(BytesToSingle(InBuf, Pos, Little));
        G := FloatToByte(BytesToSingle(InBuf, Pos + 4, Little));
        B := FloatToByte(BytesToSingle(InBuf, Pos + 8, Little));
        Inc(Pos, 12);
      end
      else
      begin
        R := FloatToByte(BytesToSingle(InBuf, Pos, Little));
        G := R;
        B := R;
        Inc(Pos, 4);
      end;
      C.R := R; C.G := G; C.B := B; C.A := 255;
      SetPx(Result, Integer(W), Integer(X), ImgY, C);
      Inc(X);
    end;
    Inc(FileRow);
  end;
end;

procedure AppendAnsi(var D: TBytes; const S: AnsiString);
var
  M, L: NativeInt;
begin
  L := Length(S);
  if L = 0 then Exit;
  M := Length(D);
  SetLength(D, M + L);
  Move(S[1], D[M], L);
end;

procedure PutSingleLE(var D: TBytes; DPos: NativeUInt; F: Single); inline;
var
  U: Cardinal;
begin
  Move(F, U, 4);   // natywne bity Single (cel x86 = LE)
  D[DPos + 0] := Byte(U);
  D[DPos + 1] := Byte(U shr 8);
  D[DPos + 2] := Byte(U shr 16);
  D[DPos + 3] := Byte(U shr 24);
end;

function EncodePfm(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  Header: AnsiString;
  Base, DPos: NativeUInt;
  X, FileRow: NativeUInt;
  ImgY: Integer;
  C: TRGBA;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then
    raise EPfmError.Create('PFM: zero image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EPfmError.Create('PFM: RGBA8 buffer size does not match Width*Height*4');
  if UInt64(Width) * UInt64(Height) * 12 > UInt64(High(NativeInt)) then
    raise EPfmError.Create('PFM: image too large');

  // 'PF' = kolor, little-endian (skala -1.0)
  Header := 'PF'#10 + AnsiString(IntToStr(Width)) + ' ' +
            AnsiString(IntToStr(Height)) + #10 + '-1.0'#10;
  AppendAnsi(Result, Header);

  Base := Length(Result);
  SetLength(Result, NativeInt(Base + UInt64(Width) * UInt64(Height) * 12));

  // wiersze od dolu do gory
  FileRow := 0;
  while FileRow < Height do
  begin
    ImgY := Height - 1 - Integer(FileRow);
    X := 0;
    while X < Width do
    begin
      C := GetPx(InBuf, Width, Integer(X), ImgY);
      DPos := Base + (FileRow * NativeUInt(Width) + X) * 12;
      PutSingleLE(Result, DPos + 0, C.R / 255);
      PutSingleLE(Result, DPos + 4, C.G / 255);
      PutSingleLE(Result, DPos + 8, C.B / 255);
      Inc(X);
    end;
    Inc(FileRow);
  end;
end;

end.
