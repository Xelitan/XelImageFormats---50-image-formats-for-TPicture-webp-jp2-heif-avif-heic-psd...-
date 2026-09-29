unit XelXpm;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, XelPng;

type
  EXpmError = class(Exception);

function DecodeXpm(InBuf: TBytes; out Width, Height: Integer): TBytes; // RGBA8
function EncodeXpm(InBuf: TBytes; Width, Height: Integer): TBytes;      // InBuf = RGBA8

implementation

type
  TXpmPaletteEntry = record
    Key: AnsiString;
    Color: TRGBA;
  end;
  TXpmPalette = array of TXpmPaletteEntry;
  TStringArray = array of AnsiString;
  TXpmIndexHolder = class
    Value: Integer;
    constructor Create(AValue: Integer);
  end;

constructor TXpmIndexHolder.Create(AValue: Integer);
begin
  inherited Create;
  Value := AValue;
end;

const
  XPM_ALPHABET: AnsiString =
    '!#$%&''()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_`abcdefghijklmnopqrstuvwxyz{|}~';

function IsSpace(C: AnsiChar): Boolean; inline;
begin
  Result := (C = ' ') or (C = #9) or (C = #10) or (C = #11) or
            (C = #12) or (C = #13);
end;

function HexVal(C: AnsiChar): Integer; inline;
begin
  if (C >= '0') and (C <= '9') then Result := Ord(C) - Ord('0')
  else if (C >= 'a') and (C <= 'f') then Result := Ord(C) - Ord('a') + 10
  else if (C >= 'A') and (C <= 'F') then Result := Ord(C) - Ord('A') + 10
  else Result := -1;
end;

function ParseHexN(const S: AnsiString; StartPos, Count: Integer; out V: Cardinal): Boolean;
var
  I, H: Integer;
begin
  V := 0;
  if (Count <= 0) or (StartPos < 1) or (StartPos + Count - 1 > Length(S)) then
    Exit(False);
  I := 0;
  while I < Count do
  begin
    H := HexVal(S[StartPos + I]);
    if H < 0 then Exit(False);
    V := (V shl 4) or Cardinal(H);
    Inc(I);
  end;
  Result := True;
end;

function HexDigitsTo8(V: Cardinal; Digits: Integer): Byte;
var
  MaxV: UInt64;
begin
  MaxV := (UInt64(1) shl (Digits * 4)) - 1;
  Result := Byte((UInt64(V) * 255 + (MaxV div 2)) div MaxV);
end;

function LowerNoSpace(const S: AnsiString): AnsiString;
var
  I, N: Integer;
  C: AnsiChar;
begin
  SetLength(Result, Length(S));
  N := 0;
  I := 1;
  while I <= Length(S) do
  begin
    C := S[I];
    if not IsSpace(C) then
    begin
      Inc(N);
      if (C >= 'A') and (C <= 'Z') then C := AnsiChar(Ord(C) + 32);
      Result[N] := C;
    end;
    Inc(I);
  end;
  SetLength(Result, N);
end;

procedure SetColor(var C: TRGBA; R, G, B, A: Byte); inline;
begin
  C.R := R; C.G := G; C.B := B; C.A := A;
end;

function ParseGrayPercent(const N: AnsiString; out C: TRGBA): Boolean;
var
  P, I: Integer;
  V: Integer;
begin
  Result := False;
  if Copy(N, 1, 4) = 'gray' then I := 5
  else if Copy(N, 1, 4) = 'grey' then I := 5
  else Exit;
  if I > Length(N) then Exit;
  V := 0;
  while I <= Length(N) do
  begin
    if (N[I] < '0') or (N[I] > '9') then Exit;
    V := V * 10 + Ord(N[I]) - Ord('0');
    if V > 100 then Exit;
    Inc(I);
  end;
  P := (V * 255 + 50) div 100;
  SetColor(C, P, P, P, 255);
  Result := True;
end;

function ParseNamedColor(const S: AnsiString; out C: TRGBA): Boolean;
var
  N: AnsiString;
begin
  N := LowerNoSpace(S);
  if N = 'none' then begin SetColor(C, 0,0,0,0); Exit(True); end;
  if ParseGrayPercent(N, C) then Exit(True);

  Result := True;
  if N = 'black' then SetColor(C,0,0,0,255)
  else if N = 'white' then SetColor(C,255,255,255,255)
  else if N = 'red' then SetColor(C,255,0,0,255)
  else if N = 'green' then SetColor(C,0,128,0,255)
  else if N = 'lime' then SetColor(C,0,255,0,255)
  else if N = 'blue' then SetColor(C,0,0,255,255)
  else if N = 'yellow' then SetColor(C,255,255,0,255)
  else if N = 'cyan' then SetColor(C,0,255,255,255)
  else if N = 'aqua' then SetColor(C,0,255,255,255)
  else if N = 'magenta' then SetColor(C,255,0,255,255)
  else if N = 'fuchsia' then SetColor(C,255,0,255,255)
  else if N = 'gray' then SetColor(C,190,190,190,255)
  else if N = 'grey' then SetColor(C,190,190,190,255)
  else if N = 'darkgray' then SetColor(C,169,169,169,255)
  else if N = 'darkgrey' then SetColor(C,169,169,169,255)
  else if N = 'lightgray' then SetColor(C,211,211,211,255)
  else if N = 'lightgrey' then SetColor(C,211,211,211,255)
  else if N = 'silver' then SetColor(C,192,192,192,255)
  else if N = 'maroon' then SetColor(C,128,0,0,255)
  else if N = 'olive' then SetColor(C,128,128,0,255)
  else if N = 'navy' then SetColor(C,0,0,128,255)
  else if N = 'teal' then SetColor(C,0,128,128,255)
  else if N = 'purple' then SetColor(C,128,0,128,255)
  else if N = 'orange' then SetColor(C,255,165,0,255)
  else if N = 'pink' then SetColor(C,255,192,203,255)
  else if N = 'brown' then SetColor(C,165,42,42,255)
  else if N = 'violet' then SetColor(C,238,130,238,255)
  else if N = 'gold' then SetColor(C,255,215,0,255)
  else if N = 'beige' then SetColor(C,245,245,220,255)
  else if N = 'khaki' then SetColor(C,240,230,140,255)
  else if N = 'coral' then SetColor(C,255,127,80,255)
  else if N = 'salmon' then SetColor(C,250,128,114,255)
  else if N = 'turquoise' then SetColor(C,64,224,208,255)
  else if N = 'indigo' then SetColor(C,75,0,130,255)
  else Result := False;
end;

function ParseXpmColor(const S: AnsiString; out C: TRGBA): Boolean;
var
  T, A, B, D: AnsiString;
  Digits, Slash1, Slash2: Integer;
  V1, V2, V3: Cardinal;
begin
  T := S;
  while (Length(T) > 0) and IsSpace(T[1]) do Delete(T, 1, 1);
  while (Length(T) > 0) and IsSpace(T[Length(T)]) do Delete(T, Length(T), 1);
  if T = '' then Exit(False);
  if T[1] = '#' then
  begin
    if ((Length(T) - 1) mod 3) <> 0 then Exit(False);
    Digits := (Length(T) - 1) div 3;
    if (Digits < 1) or (Digits > 4) then Exit(False);
    if not ParseHexN(T, 2, Digits, V1) then Exit(False);
    if not ParseHexN(T, 2 + Digits, Digits, V2) then Exit(False);
    if not ParseHexN(T, 2 + Digits * 2, Digits, V3) then Exit(False);
    SetColor(C, HexDigitsTo8(V1, Digits), HexDigitsTo8(V2, Digits),
      HexDigitsTo8(V3, Digits), 255);
    Exit(True);
  end;

  if LowerCase(Copy(string(T), 1, 4)) = 'rgb:' then
  begin
    A := Copy(T, 5, Length(T));
    Slash1 := Pos('/', string(A));
    if Slash1 <= 1 then Exit(False);
    B := Copy(A, Slash1 + 1, Length(A));
    Slash2 := Pos('/', string(B));
    if Slash2 <= 1 then Exit(False);
    D := Copy(B, Slash2 + 1, Length(B));
    B := Copy(B, 1, Slash2 - 1);
    A := Copy(A, 1, Slash1 - 1);
    if (Length(A) < 1) or (Length(A) > 4) or
       (Length(B) < 1) or (Length(B) > 4) or
       (Length(D) < 1) or (Length(D) > 4) then Exit(False);
    if not ParseHexN(A, 1, Length(A), V1) then Exit(False);
    if not ParseHexN(B, 1, Length(B), V2) then Exit(False);
    if not ParseHexN(D, 1, Length(D), V3) then Exit(False);
    SetColor(C, HexDigitsTo8(V1, Length(A)), HexDigitsTo8(V2, Length(B)),
      HexDigitsTo8(V3, Length(D)), 255);
    Exit(True);
  end;

  Result := ParseNamedColor(T, C);
end;

function DecodeCEscape(const S: AnsiString; var I: Integer): AnsiChar;
var
  V, Count, H: Integer;
  C: AnsiChar;
begin
  if I > Length(S) then Exit(#0);
  C := S[I];
  Inc(I);
  case C of
    'n': Result := #10;
    'r': Result := #13;
    't': Result := #9;
    'b': Result := #8;
    'f': Result := #12;
    'v': Result := #11;
    'a': Result := #7;
    '\': Result := '\';
    '"': Result := '"';
    '''': Result := '''';
    'x':
      begin
        V := 0; Count := 0;
        while (I <= Length(S)) and (Count < 2) do
        begin
          H := HexVal(S[I]);
          if H < 0 then Break;
          V := (V shl 4) or H;
          Inc(I); Inc(Count);
        end;
        Result := AnsiChar(V and $FF);
      end;
    '0'..'7':
      begin
        V := Ord(C) - Ord('0'); Count := 1;
        while (I <= Length(S)) and (Count < 3) and
              (S[I] >= '0') and (S[I] <= '7') do
        begin
          V := (V shl 3) or (Ord(S[I]) - Ord('0'));
          Inc(I); Inc(Count);
        end;
        Result := AnsiChar(V and $FF);
      end;
  else
    Result := C;
  end;
end;

function ExtractQuotedStrings(const Text: AnsiString): TStringArray;
var
  I, N, L: Integer;
  S: AnsiString;
  C: AnsiChar;
begin
  SetLength(Result, 0);
  I := 1;
  while I <= Length(Text) do
  begin
    if Text[I] <> '"' then begin Inc(I); Continue; end;
    Inc(I);
    S := '';
    while I <= Length(Text) do
    begin
      C := Text[I];
      Inc(I);
      if C = '"' then Break;
      if C = '\' then
      begin
        C := DecodeCEscape(Text, I);
        L := Length(S); SetLength(S, L + 1); S[L + 1] := C;
      end
      else
      begin
        L := Length(S); SetLength(S, L + 1); S[L + 1] := C;
      end;
    end;
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N] := S;
  end;
end;

function SplitXpm2Lines(const Text: AnsiString): TStringArray;
var
  I, Start, N: Integer;
  L: AnsiString;
begin
  SetLength(Result, 0);
  I := 1;
  while I <= Length(Text) do
  begin
    Start := I;
    while (I <= Length(Text)) and (Text[I] <> #10) and (Text[I] <> #13) do Inc(I);
    L := Copy(Text, Start, I - Start);
    while (Length(L) > 0) and IsSpace(L[1]) do Delete(L, 1, 1);
    while (Length(L) > 0) and IsSpace(L[Length(L)]) do Delete(L, Length(L), 1);
    if (L <> '') and (Copy(L, 1, 1) <> '!') then
    begin
      N := Length(Result); SetLength(Result, N + 1); Result[N] := L;
    end;
    if (I <= Length(Text)) and (Text[I] = #13) then Inc(I);
    if (I <= Length(Text)) and (Text[I] = #10) then Inc(I);
  end;
end;

function NextWord(const S: AnsiString; var Posn: Integer): AnsiString;
var
  Start: Integer;
begin
  while (Posn <= Length(S)) and IsSpace(S[Posn]) do Inc(Posn);
  Start := Posn;
  while (Posn <= Length(S)) and (not IsSpace(S[Posn])) do Inc(Posn);
  Result := Copy(S, Start, Posn - Start);
end;

function ParsePositiveInt(const S, What: AnsiString): Cardinal;
var
  I: Integer;
  V: UInt64;
begin
  if S = '' then raise EXpmError.Create('XPM: missing ' + string(What));
  V := 0;
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] < '0') or (S[I] > '9') then
      raise EXpmError.Create('XPM: invalid ' + string(What));
    V := V * 10 + Cardinal(Ord(S[I]) - Ord('0'));
    if V > High(Cardinal) then
      raise EXpmError.Create('XPM: ' + string(What) + ' too large');
    Inc(I);
  end;
  if V = 0 then raise EXpmError.Create('XPM: ' + string(What) + ' must be positive');
  Result := Cardinal(V);
end;

function IsFieldKey(const S: AnsiString): Boolean; inline;
begin
  Result := (S = 'c') or (S = 'g') or (S = 'g4') or (S = 'm') or (S = 's');
end;

function ColorSpecFromLine(const Line: AnsiString; Cpp: Integer): AnsiString;
var
  P, N: Integer;
  Tok, Field, Value, BestC, BestG, BestG4, BestM: AnsiString;
begin
  Result := '';
  BestC := ''; BestG := ''; BestG4 := ''; BestM := '';
  P := Cpp + 1;
  while P <= Length(Line) do
  begin
    Tok := NextWord(Line, P);
    if Tok = '' then Break;
    Field := Tok;
    if not IsFieldKey(Field) then Continue;
    Value := '';
    while P <= Length(Line) do
    begin
      N := P;
      Tok := NextWord(Line, N);
      if (Tok = '') or IsFieldKey(Tok) then Break;
      P := N;
      if Value <> '' then Value := Value + ' ';
      Value := Value + Tok;
    end;
    if Field = 'c' then BestC := Value
    else if Field = 'g' then BestG := Value
    else if Field = 'g4' then BestG4 := Value
    else if Field = 'm' then BestM := Value;
  end;
  if BestC <> '' then Result := BestC
  else if BestG <> '' then Result := BestG
  else if BestG4 <> '' then Result := BestG4
  else Result := BestM;
end;

function BytesToAnsi(const B: TBytes): AnsiString;
begin
  SetLength(Result, Length(B));
  if Length(B) > 0 then Move(B[0], Result[1], Length(B));
end;

function DecodeXpm(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Text: AnsiString;
  Lines: TStringArray;
  Header, Tok: AnsiString;
  P, I, Cpp: Integer;
  W, H, NColors: Cardinal;
  Pal: TXpmPalette;
  Map: TStringList;
  Spec, Key: AnsiString;
  X, Y: NativeUInt;
  Idx: Integer;
begin
  Width := 0;
  Height := 0;
  SetLength(Result, 0);
  Text := BytesToAnsi(InBuf);
  Lines := ExtractQuotedStrings(Text);
  if Length(Lines) = 0 then
    Lines := SplitXpm2Lines(Text);
  if Length(Lines) = 0 then
    raise EXpmError.Create('XPM: no image data strings found');

  Header := Lines[0];
  P := 1;
  W := ParsePositiveInt(NextWord(Header, P), 'width');
  H := ParsePositiveInt(NextWord(Header, P), 'height');
  NColors := ParsePositiveInt(NextWord(Header, P), 'number of colors');
  Tok := NextWord(Header, P);
  Cpp := Integer(ParsePositiveInt(Tok, 'chars-per-pixel'));
  if Cpp > 32 then
    raise EXpmError.Create('XPM: unreasonable chars-per-pixel');
  if UInt64(NColors) + UInt64(H) + 1 > UInt64(Length(Lines)) then
    raise EXpmError.Create('XPM: truncated palette or pixel rows');
  if (UInt64(W) > UInt64(High(Integer))) or (UInt64(H) > UInt64(High(Integer))) then
    raise EXpmError.Create('XPM: image dimensions are too large');

  SetLength(Pal, NColors);
  Map := TStringList.Create;
  try
    Map.Sorted := True;
    Map.Duplicates := dupError;
    I := 0;
    while I < Integer(NColors) do
    begin
      if Length(Lines[I + 1]) < Cpp then
        raise EXpmError.Create('XPM: palette key shorter than chars-per-pixel');
      Key := Copy(Lines[I + 1], 1, Cpp);
      Spec := ColorSpecFromLine(Lines[I + 1], Cpp);
      if Spec = '' then
        raise EXpmError.Create('XPM: palette entry has no usable color field');
      Pal[I].Key := Key;
      if not ParseXpmColor(Spec, Pal[I].Color) then
        raise EXpmError.Create('XPM: unsupported color specification: ' + string(Spec));
      Map.AddObject(string(Key), TXpmIndexHolder.Create(I));
      Inc(I);
    end;

    if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then
      raise EXpmError.Create('XPM: image too large');
    Width := Integer(W);
    Height := Integer(H);
    SetLength(Result, NativeInt(UInt64(W) * UInt64(H) * 4));
    Y := 0;
    while Y < H do
    begin
      if UInt64(Length(Lines[1 + NColors + Y])) < UInt64(W) * UInt64(Cpp) then
        raise EXpmError.Create('XPM: pixel row is too short');
      X := 0;
      while X < W do
      begin
        Key := Copy(Lines[1 + NColors + Y], Integer(X) * Cpp + 1, Cpp);
        if not Map.Find(string(Key), Idx) then
          raise EXpmError.Create('XPM: unknown pixel key');
        I := TXpmIndexHolder(Map.Objects[Idx]).Value;
        SetPx(Result, Integer(W), Integer(X), Integer(Y), Pal[I].Color);
        Inc(X);
      end;
      Inc(Y);
    end;
  finally
    I := 0;
    while I < Map.Count do
    begin
      Map.Objects[I].Free;
      Inc(I);
    end;
    Map.Free;
  end;
end;

function HexDigit(V: Byte): AnsiChar; inline;
begin
  if V < 10 then Result := AnsiChar(Ord('0') + V)
  else Result := AnsiChar(Ord('A') + V - 10);
end;

function ColorKey(const C: TRGBA; AlphaThreshold: Byte): AnsiString;
begin
  if C.A < AlphaThreshold then
  begin
    Result := 'T';
    Exit;
  end;
  SetLength(Result, 7);
  Result[1] := 'C';
  Result[2] := HexDigit(C.R shr 4);
  Result[3] := HexDigit(C.R and $0F);
  Result[4] := HexDigit(C.G shr 4);
  Result[5] := HexDigit(C.G and $0F);
  Result[6] := HexDigit(C.B shr 4);
  Result[7] := HexDigit(C.B and $0F);
end;

function MakePixelKey(Index, Cpp: Integer): AnsiString;
var
  I, Base: Integer;
begin
  Base := Length(XPM_ALPHABET);
  SetLength(Result, Cpp);
  I := Cpp;
  while I >= 1 do
  begin
    Result[I] := XPM_ALPHABET[(Index mod Base) + 1];
    Index := Index div Base;
    Dec(I);
  end;
end;

function SanitizeCIdent(const S: AnsiString): AnsiString;
var
  I: Integer;
  C: AnsiChar;
begin
  if S = '' then Exit('image_xpm');
  SetLength(Result, Length(S));
  I := 1;
  while I <= Length(S) do
  begin
    C := S[I];
    if not (((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
            ((C >= '0') and (C <= '9')) or (C = '_')) then C := '_';
    Result[I] := C;
    Inc(I);
  end;
  if (Result[1] >= '0') and (Result[1] <= '9') then Result := '_' + Result;
end;

function EscapeCString(const S: AnsiString): AnsiString;
var
  I, N: Integer;
  C: AnsiChar;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    C := S[I];
    if (C = '"') or (C = '\') then
    begin
      N := Length(Result); SetLength(Result, N + 2);
      Result[N + 1] := '\'; Result[N + 2] := C;
    end
    else
    begin
      N := Length(Result); SetLength(Result, N + 1); Result[N + 1] := C;
    end;
    Inc(I);
  end;
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

function EncodeXpm(InBuf: TBytes; Width, Height: Integer): TBytes;
const
  VariableName: AnsiString = 'image_xpm';
  AlphaThreshold: Byte = 128;
var
  Colors: TStringList;
  X, Y: NativeUInt;
  K, PixelKey, Row, Spec, Ident: AnsiString;
  Cpp, Base, Capacity, I, Idx: Integer;
  C: TRGBA;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then
    raise EXpmError.Create('XPM: zero image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EXpmError.Create('XPM: RGBA8 buffer size does not match Width*Height*4');
  Colors := TStringList.Create;
  try
    Colors.Sorted := True;
    Colors.Duplicates := dupIgnore;
    Y := 0;
    while Y < Height do
    begin
      X := 0;
      while X < Width do
      begin
        K := ColorKey(GetPx(InBuf, Width, Integer(X), Integer(Y)), AlphaThreshold);
        Colors.Add(string(K));
        Inc(X);
      end;
      Inc(Y);
    end;
    if Colors.Count = 0 then
      raise EXpmError.Create('XPM: no colors');

    Base := Length(XPM_ALPHABET);
    Cpp := 1;
    Capacity := Base;
    while Capacity < Colors.Count do
    begin
      Inc(Cpp);
      if Capacity > High(Integer) div Base then
        raise EXpmError.Create('XPM: too many colors');
      Capacity := Capacity * Base;
    end;

    Ident := SanitizeCIdent(VariableName);
    AppendAnsi(Result, '/* XPM */'#10'static const char *' + Ident + '[] = {'#10);
    AppendAnsi(Result, '"' + AnsiString(IntToStr(Width)) + ' ' +
      AnsiString(IntToStr(Height)) + ' ' + AnsiString(IntToStr(Colors.Count)) +
      ' ' + AnsiString(IntToStr(Cpp)) + '",'#10);

    I := 0;
    while I < Colors.Count do
    begin
      PixelKey := MakePixelKey(I, Cpp);
      K := AnsiString(Colors[I]);
      if K = 'T' then Spec := 'None'
      else Spec := '#' + Copy(K, 2, 6);
      AppendAnsi(Result, '"' + EscapeCString(PixelKey) + ' c ' + Spec + '",'#10);
      Inc(I);
    end;

    Y := 0;
    while Y < Height do
    begin
      Row := '';
      X := 0;
      while X < Width do
      begin
        C := GetPx(InBuf, Width, Integer(X), Integer(Y));
        K := ColorKey(C, AlphaThreshold);
        if not Colors.Find(string(K), Idx) then
          raise EXpmError.Create('XPM: internal palette lookup failure');
        Row := Row + MakePixelKey(Idx, Cpp);
        Inc(X);
      end;
      AppendAnsi(Result, '"' + EscapeCString(Row) + '"');
      if Y + 1 < Height then AppendAnsi(Result, ',');
      AppendAnsi(Result, #10);
      Inc(Y);
    end;
    AppendAnsi(Result, '};'#10);
  finally
    Colors.Free;
  end;
end;

end.
