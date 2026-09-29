unit XelHdr;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Radiance HDR (RGBE, .hdr/.pic) codec -> RGBA8                 //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Clean-room implementation from the public Radiance RGBE format.             //
// HDR floats are clamped to [0,1] and scaled to 0..255 for 8-bit output.      //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, Math, XelPng;

type
  EHdrError = class(Exception);

// Dekoduje Radiance RGBE: naglowek tekstowy + "-Y H +X W" + dane (flat lub
// nowy RLE). Wartosci HDR obcinane do [0,1], skala do 0..255 (alfa=255).
function DecodeHdr(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8

// Zapisuje Radiance RGBE (flat, bez RLE). InBuf = RGBA8, R/G/B dzielone przez 255.
function EncodeHdr(InBuf: TBytes; Width, Height: Integer): TBytes;         // InBuf = RGBA8

implementation

function FloatToByte(F: Single): Byte; inline;
begin
  if F > 1 then Result := 255
  else if F > 0 then Result := Byte(Round(F * 255))
  else Result := 0;
end;

procedure RgbeToRgb(R, G, B, E: Byte; out fr, fg, fb: Single); inline;
var
  f: Single;
begin
  if E = 0 then begin fr := 0; fg := 0; fb := 0; end
  else
  begin
    f := Ldexp(1.0, Integer(E) - (128 + 8));   // classic Radiance conversion
    fr := R * f; fg := G * f; fb := B * f;
  end;
end;

// Read one text line (up to LF) starting at Pos; returns it without CR/LF.
function ReadLine(const D: TBytes; var Pos: NativeUInt): AnsiString;
var
  N, Start: NativeUInt;
begin
  N := NativeUInt(Length(D));
  Start := Pos;
  while (Pos < N) and (D[Pos] <> 10) do Inc(Pos);
  SetLength(Result, Pos - Start);
  if Length(Result) > 0 then Move(D[Start], Result[1], Length(Result));
  if (Pos < N) and (D[Pos] = 10) then Inc(Pos);
  // strip trailing CR
  if (Length(Result) > 0) and (Result[Length(Result)] = #13) then
    SetLength(Result, Length(Result) - 1);
end;

function DecodeHdr(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Pos, N: NativeUInt;
  Line, Res: AnsiString;
  W, H, x, y, i, c: Integer;
  tokY, tokX: AnsiString;
  sp1, sp2, sp3: Integer;
  scan: TBytes;              // 4*W RGBE for one scanline
  b0, b1, b2, b3: Byte;
  cnt, run: Integer;
  fr, fg, fb: Single;
  Px: TRGBA;
  useNewRle: Boolean;
begin
  Width := 0; Height := 0; SetLength(Result, 0);
  N := NativeUInt(Length(InBuf));
  Pos := 0;

  Line := ReadLine(InBuf, Pos);
  if (Pos = 0) or ((Copy(Line, 1, 2) <> '#?')) then
    raise EHdrError.Create('HDR: not a Radiance file');
  // header lines until an empty line
  repeat
    Line := ReadLine(InBuf, Pos);
  until (Line = '') or (Pos >= N);

  Res := ReadLine(InBuf, Pos);   // resolution line, e.g. "-Y 32 +X 48"
  // parse two axis tokens; support the common "-Y H +X W"
  Res := Trim(Res);
  H := 0; W := 0;
  // split into 4 whitespace-separated tokens: axis1 val1 axis2 val2
  begin
    sp1 := 1;
    while (sp1 <= Length(Res)) and (Res[sp1] = ' ') do Inc(sp1);
    sp2 := sp1; while (sp2 <= Length(Res)) and (Res[sp2] <> ' ') do Inc(sp2);   // axis1
    tokY := Copy(Res, sp1, sp2 - sp1);
    sp1 := sp2; while (sp1 <= Length(Res)) and (Res[sp1] = ' ') do Inc(sp1);
    sp3 := sp1; while (sp3 <= Length(Res)) and (Res[sp3] <> ' ') do Inc(sp3);   // value1
    H := StrToIntDef(string(Copy(Res, sp1, sp3 - sp1)), 0);
    sp1 := sp3; while (sp1 <= Length(Res)) and (Res[sp1] = ' ') do Inc(sp1);
    sp2 := sp1; while (sp2 <= Length(Res)) and (Res[sp2] <> ' ') do Inc(sp2);   // axis2
    tokX := Copy(Res, sp1, sp2 - sp1);
    sp1 := sp2; while (sp1 <= Length(Res)) and (Res[sp1] = ' ') do Inc(sp1);
    sp3 := sp1; while (sp3 <= Length(Res)) and (Res[sp3] <> ' ') do Inc(sp3);   // value2
    W := StrToIntDef(string(Copy(Res, sp1, sp3 - sp1)), 0);
  end;
  if (UpperCase(string(Copy(tokY,2,1))) <> 'Y') or (UpperCase(string(Copy(tokX,2,1))) <> 'X') then
    raise EHdrError.Create('HDR: unsupported resolution orientation');
  if (W <= 0) or (H <= 0) then raise EHdrError.Create('HDR: invalid dimensions');

  Width := W; Height := H;
  SetLength(Result, NativeInt(W) * H * 4);
  SetLength(scan, W * 4);

  for y := 0 to H - 1 do
  begin
    useNewRle := False;
    if (Pos + 4 <= N) then
    begin
      b0 := InBuf[Pos]; b1 := InBuf[Pos + 1]; b2 := InBuf[Pos + 2]; b3 := InBuf[Pos + 3];
      if (b0 = 2) and (b1 = 2) and (((Integer(b2) shl 8) or b3) = W) and (W >= 8) and (W <= 32767) then
        useNewRle := True;
    end;

    if useNewRle then
    begin
      Inc(Pos, 4);
      for c := 0 to 3 do
      begin
        x := 0;
        while x < W do
        begin
          if Pos >= N then raise EHdrError.Create('HDR: truncated RLE scanline');
          cnt := InBuf[Pos]; Inc(Pos);
          if cnt > 128 then
          begin
            run := cnt - 128;
            if Pos >= N then raise EHdrError.Create('HDR: truncated RLE run');
            b0 := InBuf[Pos]; Inc(Pos);
            for i := 0 to run - 1 do
            begin
              if x >= W then Break;
              scan[x * 4 + c] := b0; Inc(x);
            end;
          end
          else
          begin
            for i := 0 to cnt - 1 do
            begin
              if (x >= W) or (Pos >= N) then Break;
              scan[x * 4 + c] := InBuf[Pos]; Inc(Pos); Inc(x);
            end;
          end;
        end;
      end;
    end
    else
    begin
      // flat: W RGBE quadruples
      if Pos + NativeUInt(W) * 4 > N then raise EHdrError.Create('HDR: truncated flat scanline');
      for x := 0 to W - 1 do
      begin
        scan[x * 4 + 0] := InBuf[Pos + 0];
        scan[x * 4 + 1] := InBuf[Pos + 1];
        scan[x * 4 + 2] := InBuf[Pos + 2];
        scan[x * 4 + 3] := InBuf[Pos + 3];
        Inc(Pos, 4);
      end;
    end;

    for x := 0 to W - 1 do
    begin
      RgbeToRgb(scan[x*4+0], scan[x*4+1], scan[x*4+2], scan[x*4+3], fr, fg, fb);
      Px.R := FloatToByte(fr); Px.G := FloatToByte(fg); Px.B := FloatToByte(fb); Px.A := 255;
      SetPx(Result, W, x, y, Px);
    end;
  end;
end;

procedure RgbToRgbe(fr, fg, fb: Single; out R, G, B, E: Byte); inline;
var
  d, m: Double;
  ex: LongInt;
begin
  d := fr;
  if fg > d then d := fg;
  if fb > d then d := fb;
  if d <= 1e-32 then begin R := 0; G := 0; B := 0; E := 0; end
  else
  begin
    Frexp(d, m, ex);                   // d = m * 2^ex, m in [0.5,1)
    m := m * 256.0 / d;
    R := Byte(Trunc(fr * m));
    G := Byte(Trunc(fg * m));
    B := Byte(Trunc(fb * m));
    E := Byte(ex + 128);
  end;
end;

procedure AppS(var D: TBytes; var Len: NativeInt; const S: AnsiString);
var i: Integer;
begin
  for i := 1 to Length(S) do
  begin
    if Len >= Length(D) then SetLength(D, Length(D) * 2 + 256);
    D[Len] := Byte(S[i]); Inc(Len);
  end;
end;

function EncodeHdr(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  Len: NativeInt;
  x, y: Integer;
  Px: TRGBA;
  R, G, B, E: Byte;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then raise EHdrError.Create('HDR: zero image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EHdrError.Create('HDR: RGBA8 buffer size does not match Width*Height*4');

  Len := 0;
  SetLength(Result, 256);
  AppS(Result, Len, '#?RADIANCE'#10);
  AppS(Result, Len, 'FORMAT=32-bit_rle_rgbe'#10#10);
  AppS(Result, Len, AnsiString(Format('-Y %d +X %d'#10, [Height, Width])));

  SetLength(Result, Len + NativeInt(Width) * Height * 4);
  for y := 0 to Height - 1 do
    for x := 0 to Width - 1 do
    begin
      Px := GetPx(InBuf, Width, x, y);
      RgbToRgbe(Px.R / 255, Px.G / 255, Px.B / 255, R, G, B, E);
      Result[Len + 0] := R; Result[Len + 1] := G;
      Result[Len + 2] := B; Result[Len + 3] := E;
      Inc(Len, 4);
    end;
  SetLength(Result, Len);
end;

end.
