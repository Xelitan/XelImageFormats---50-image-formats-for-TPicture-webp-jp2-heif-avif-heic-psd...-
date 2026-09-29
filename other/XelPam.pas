unit XelPAM;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, XelPng;

type
  EPamError = class(Exception);

// Dekoduje PAM (P7, Netpbm) do RGBA8. DEPTH 1=gray, 2=gray+alpha, 3=RGB,
// 4=RGBA; MAXVAL 1..65535 (8- lub 16-bit probki, big-endian).
function DecodePam(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8

// Zapisuje PAM: DEPTH 4 (RGB_ALPHA), MAXVAL 255, dane binarne. InBuf = RGBA8.
function EncodePam(InBuf: TBytes; Width, Height: Integer): TBytes;         // InBuf = RGBA8

implementation

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
    if IsWS(Data[Pos]) then begin Inc(Pos); Continue; end;
    if Data[Pos] = Ord('#') then
    begin
      Inc(Pos);
      while (Pos < N) and (Data[Pos] <> 10) and (Data[Pos] <> 13) do Inc(Pos);
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
    raise EPamError.Create('PAM: unexpected end of header');
  Start := Pos;
  while (Pos < N) and (not IsWS(Data[Pos])) and (Data[Pos] <> Ord('#')) do
    Inc(Pos);
  if Pos = Start then
    raise EPamError.Create('PAM: expected token');
  SetLength(Result, Pos - Start);
  if Length(Result) <> 0 then
    Move(Data[Start], Result[1], Length(Result));
end;

procedure SkipRestOfLine(const Data: TBytes; var Pos: NativeUInt);
var
  N: NativeUInt;
begin
  N := NativeUInt(Length(Data));
  while (Pos < N) and (Data[Pos] <> 10) do Inc(Pos);
end;

function ParseUIntToken(const S: AnsiString; const What: string): UInt64;
var
  I: Integer;
  D: Byte;
begin
  if Length(S) = 0 then
    raise EPamError.Create('PAM: missing ' + What);
  Result := 0;
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] < '0') or (S[I] > '9') then
      raise EPamError.Create('PAM: invalid ' + What);
    D := Ord(S[I]) - Ord('0');
    if Result > (High(UInt64) - D) div 10 then
      raise EPamError.Create('PAM: numeric overflow in ' + What);
    Result := Result * 10 + D;
    Inc(I);
  end;
end;

function ScaleTo8(V, MaxVal: Cardinal): Byte; inline;
begin
  if MaxVal = 0 then Exit(0);
  Result := Byte((UInt64(V) * 255 + (MaxVal div 2)) div MaxVal);
end;

function ReadSample(const Data: TBytes; var Pos: NativeUInt;
  MaxVal: Cardinal): Cardinal; inline;
var
  N: NativeUInt;
begin
  N := NativeUInt(Length(Data));
  if MaxVal < 256 then
  begin
    if Pos >= N then raise EPamError.Create('PAM: truncated raster');
    Result := Data[Pos];
    Inc(Pos);
  end
  else
  begin
    if (Pos > N) or (N - Pos < 2) then
      raise EPamError.Create('PAM: truncated 16-bit raster');
    Result := (Cardinal(Data[Pos]) shl 8) or Cardinal(Data[Pos + 1]);
    Inc(Pos, 2);
  end;
  if Result > MaxVal then
    raise EPamError.Create('PAM: sample exceeds MaxVal');
end;

function DecodePam(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Pos, N, X, Y: NativeUInt;
  Magic, Key: AnsiString;
  W64, H64, D64, M64: UInt64;
  W, H, Depth, MaxVal: Cardinal;
  HaveW, HaveH, HaveD, HaveM: Boolean;
  S0, S1, S2, S3: Cardinal;
  C: TRGBA;
begin
  Width := 0;
  Height := 0;
  SetLength(Result, 0);

  Pos := 0;
  Magic := NextToken(InBuf, Pos);
  if Magic <> 'P7' then
    raise EPamError.Create('PAM: invalid magic (expected P7)');

  W := 0; H := 0; Depth := 0; MaxVal := 0;
  HaveW := False; HaveH := False; HaveD := False; HaveM := False;

  // naglowek: pary KLUCZ WARTOSC, zakonczone linia ENDHDR
  while True do
  begin
    Key := NextToken(InBuf, Pos);
    if Key = 'ENDHDR' then Break
    else if Key = 'WIDTH' then
    begin
      W64 := ParseUIntToken(NextToken(InBuf, Pos), 'WIDTH');
      if (W64 = 0) or (W64 > UInt64(High(Integer))) then
        raise EPamError.Create('PAM: invalid WIDTH');
      W := Cardinal(W64); HaveW := True;
    end
    else if Key = 'HEIGHT' then
    begin
      H64 := ParseUIntToken(NextToken(InBuf, Pos), 'HEIGHT');
      if (H64 = 0) or (H64 > UInt64(High(Integer))) then
        raise EPamError.Create('PAM: invalid HEIGHT');
      H := Cardinal(H64); HaveH := True;
    end
    else if Key = 'DEPTH' then
    begin
      D64 := ParseUIntToken(NextToken(InBuf, Pos), 'DEPTH');
      if (D64 < 1) or (D64 > 4) then
        raise EPamError.Create('PAM: unsupported DEPTH (1..4 supported)');
      Depth := Cardinal(D64); HaveD := True;
    end
    else if Key = 'MAXVAL' then
    begin
      M64 := ParseUIntToken(NextToken(InBuf, Pos), 'MAXVAL');
      if (M64 = 0) or (M64 > 65535) then
        raise EPamError.Create('PAM: MAXVAL must be 1..65535');
      MaxVal := Cardinal(M64); HaveM := True;
    end
    else if Key = 'TUPLTYPE' then
      SkipRestOfLine(InBuf, Pos)     // informacyjne - pomijamy
    else
      SkipRestOfLine(InBuf, Pos);    // nieznany klucz - tolerujemy
  end;

  if not (HaveW and HaveH and HaveD and HaveM) then
    raise EPamError.Create('PAM: incomplete header');

  // po ENDHDR nastepuje dokladnie jeden znak nowej linii, potem raster
  N := NativeUInt(Length(InBuf));
  while (Pos < N) and (InBuf[Pos] <> 10) do Inc(Pos);
  if Pos < N then Inc(Pos);

  if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then
    raise EPamError.Create('PAM: image too large');
  Width := Integer(W);
  Height := Integer(H);
  SetLength(Result, NativeInt(UInt64(W) * UInt64(H) * 4));

  Y := 0;
  while Y < H do
  begin
    X := 0;
    while X < W do
    begin
      S0 := ReadSample(InBuf, Pos, MaxVal);
      case Depth of
        1:
          begin
            C.R := ScaleTo8(S0, MaxVal); C.G := C.R; C.B := C.R; C.A := 255;
          end;
        2:
          begin
            S1 := ReadSample(InBuf, Pos, MaxVal);
            C.R := ScaleTo8(S0, MaxVal); C.G := C.R; C.B := C.R;
            C.A := ScaleTo8(S1, MaxVal);
          end;
        3:
          begin
            S1 := ReadSample(InBuf, Pos, MaxVal);
            S2 := ReadSample(InBuf, Pos, MaxVal);
            C.R := ScaleTo8(S0, MaxVal); C.G := ScaleTo8(S1, MaxVal);
            C.B := ScaleTo8(S2, MaxVal); C.A := 255;
          end;
      else // 4
        begin
          S1 := ReadSample(InBuf, Pos, MaxVal);
          S2 := ReadSample(InBuf, Pos, MaxVal);
          S3 := ReadSample(InBuf, Pos, MaxVal);
          C.R := ScaleTo8(S0, MaxVal); C.G := ScaleTo8(S1, MaxVal);
          C.B := ScaleTo8(S2, MaxVal); C.A := ScaleTo8(S3, MaxVal);
        end;
      end;
      SetPx(Result, Integer(W), Integer(X), Integer(Y), C);
      Inc(X);
    end;
    Inc(Y);
  end;
end;

procedure AppendByte(var D: TBytes; B: Byte); inline;
var
  M: NativeInt;
begin
  M := Length(D);
  SetLength(D, M + 1);
  D[M] := B;
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

function EncodePam(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  X, Y: NativeUInt;
  C: TRGBA;
  Header: AnsiString;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then
    raise EPamError.Create('PAM: zero image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EPamError.Create('PAM: RGBA8 buffer size does not match Width*Height*4');

  Header := 'P7'#10 +
            'WIDTH ' + AnsiString(IntToStr(Width)) + #10 +
            'HEIGHT ' + AnsiString(IntToStr(Height)) + #10 +
            'DEPTH 4'#10 +
            'MAXVAL 255'#10 +
            'TUPLTYPE RGB_ALPHA'#10 +
            'ENDHDR'#10;
  AppendAnsi(Result, Header);

  Y := 0;
  while Y < Height do
  begin
    X := 0;
    while X < Width do
    begin
      C := GetPx(InBuf, Width, Integer(X), Integer(Y));
      AppendByte(Result, C.R);
      AppendByte(Result, C.G);
      AppendByte(Result, C.B);
      AppendByte(Result, C.A);
      Inc(X);
    end;
    Inc(Y);
  end;
end;

end.
