unit XelSgi;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	SGI image codec (.sgi/.rgb/.rgba/.bw) -> RGBA8                //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Clean-room implementation from the public SGI image file format spec.       //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelPng;

type
  ESgiError = class(Exception);

// Dekoduje SGI (magic 474): verbatim lub RLE, 8/16 bit na kanal, 1..4 kanaly
// (gray / gray+alpha / RGB / RGBA). Wiersze zapisane od dolu do gory, planarnie.
function DecodeSgi(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8

// Zapisuje SGI: verbatim, 8 bit/kanal, 4 kanaly (RGBA). InBuf = RGBA8.
function EncodeSgi(InBuf: TBytes; Width, Height: Integer): TBytes;         // InBuf = RGBA8

implementation

function RU16(const D: TBytes; P: NativeUInt): Word; inline;
begin
  Result := (Word(D[P]) shl 8) or Word(D[P + 1]);
end;

function RU32(const D: TBytes; P: NativeUInt): Cardinal; inline;
begin
  Result := (Cardinal(D[P]) shl 24) or (Cardinal(D[P + 1]) shl 16) or
            (Cardinal(D[P + 2]) shl 8) or Cardinal(D[P + 3]);
end;

// Round a 16-bit sample down to 8-bit.
function To8(V16: Word): Byte; inline;
begin
  Result := Byte((Cardinal(V16) * 255 + 32767) div 65535);
end;

function DecodeSgi(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  N: NativeUInt;
  Storage, Bpc: Byte;
  Dimension, XSize, YSize, ZSize: Word;
  W, H, Chan: Integer;
  Planes: array of TBytes;   // Chan planes, each W*H bytes (top-down)
  StartTab, LenTab: array of Cardinal;
  TabCount, i, c, row, imgY, x: Integer;
  Px: TRGBA;
  P: NativeInt;
  base, so_, sl, sampleBytes: NativeUInt;

  procedure DecodeRleScanline(SrcOff, SrcLen: NativeUInt; Plane: NativeInt;
    RowTopDown: Integer);
  var
    pos, endp: NativeUInt;
    cnt: Integer;
    v: Byte;
    w16: Word;
    dstBase: NativeInt;
    written: Integer;
  begin
    dstBase := NativeInt(RowTopDown) * W;
    written := 0;
    pos := SrcOff;
    endp := SrcOff + SrcLen;
    if Bpc = 1 then
    begin
      while (pos < endp) and (pos < N) do
      begin
        cnt := InBuf[pos] and $7F;
        if (InBuf[pos] and $80) <> 0 then
        begin
          Inc(pos);
          while (cnt > 0) and (written < W) and (pos < N) do
          begin
            Planes[Plane][dstBase + written] := InBuf[pos];
            Inc(pos); Inc(written); Dec(cnt);
          end;
        end
        else
        begin
          Inc(pos);
          if cnt = 0 then Break;
          if pos >= N then Break;
          v := InBuf[pos]; Inc(pos);
          while (cnt > 0) and (written < W) do
          begin
            Planes[Plane][dstBase + written] := v; Inc(written); Dec(cnt);
          end;
        end;
      end;
    end
    else // Bpc = 2: 16-bit big-endian samples, downscale to 8-bit (take high byte)
    begin
      while (pos + 1 < endp) and (pos + 1 < N) do
      begin
        w16 := RU16(InBuf, pos);
        cnt := w16 and $7F;
        if (w16 and $80) <> 0 then
        begin
          Inc(pos, 2);
          while (cnt > 0) and (written < W) and (pos + 1 < N) do
          begin
            Planes[Plane][dstBase + written] := To8(RU16(InBuf, pos));
            Inc(pos, 2); Inc(written); Dec(cnt);
          end;
        end
        else
        begin
          Inc(pos, 2);
          if cnt = 0 then Break;
          if pos + 1 >= N then Break;
          v := To8(RU16(InBuf, pos)); Inc(pos, 2);   // repeated word
          while (cnt > 0) and (written < W) do
          begin
            Planes[Plane][dstBase + written] := v; Inc(written); Dec(cnt);
          end;
        end;
      end;
    end;
  end;

begin
  Width := 0; Height := 0; SetLength(Result, 0);
  N := NativeUInt(Length(InBuf));
  if N < 512 then raise ESgiError.Create('SGI: file too small');
  if RU16(InBuf, 0) <> 474 then raise ESgiError.Create('SGI: bad magic');

  Storage := InBuf[2];
  Bpc := InBuf[3];
  Dimension := RU16(InBuf, 4);
  XSize := RU16(InBuf, 6);
  YSize := RU16(InBuf, 8);
  ZSize := RU16(InBuf, 10);

  if (Bpc <> 1) and (Bpc <> 2) then raise ESgiError.CreateFmt('SGI: unsupported bytes/channel %d', [Bpc]);
  if Dimension = 1 then begin YSize := 1; ZSize := 1; end
  else if Dimension = 2 then ZSize := 1;
  if (XSize = 0) or (YSize = 0) or (ZSize = 0) then raise ESgiError.Create('SGI: invalid dimensions');
  if ZSize > 4 then raise ESgiError.CreateFmt('SGI: unsupported channel count %d', [ZSize]);

  W := XSize; H := YSize; Chan := ZSize;
  if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then raise ESgiError.Create('SGI: image too large');

  SetLength(Planes, Chan);
  for c := 0 to Chan - 1 do SetLength(Planes[c], NativeInt(W) * H);

  if Storage = 1 then
  begin
    TabCount := H * Chan;
    SetLength(StartTab, TabCount);
    SetLength(LenTab, TabCount);
    base := 512;
    if base + NativeUInt(TabCount) * 8 > N then raise ESgiError.Create('SGI: truncated RLE tables');
    for i := 0 to TabCount - 1 do StartTab[i] := RU32(InBuf, base + NativeUInt(i) * 4);
    for i := 0 to TabCount - 1 do LenTab[i] := RU32(InBuf, base + NativeUInt(TabCount) * 4 + NativeUInt(i) * 4);
    for c := 0 to Chan - 1 do
      for row := 0 to H - 1 do
      begin
        imgY := H - 1 - row;              // file rows are bottom-to-top
        so_ := StartTab[c * H + row];
        sl := LenTab[c * H + row];
        if (so_ = 0) or (so_ >= N) then Continue;
        DecodeRleScanline(so_, sl, c, imgY);
      end;
  end
  else // verbatim
  begin
    if Bpc = 1 then sampleBytes := 1 else sampleBytes := 2;
    base := 512;
    for c := 0 to Chan - 1 do
      for row := 0 to H - 1 do
      begin
        imgY := H - 1 - row;
        for x := 0 to W - 1 do
        begin
          if base + sampleBytes > N then Break;
          if Bpc = 1 then Planes[c][NativeInt(imgY) * W + x] := InBuf[base]
          else Planes[c][NativeInt(imgY) * W + x] := To8(RU16(InBuf, base));
          Inc(base, sampleBytes);
        end;
      end;
  end;

  Width := W; Height := H;
  SetLength(Result, NativeInt(W) * H * 4);
  for imgY := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      P := NativeInt(imgY) * W + x;
      case Chan of
        1: begin Px.R := Planes[0][P]; Px.G := Px.R; Px.B := Px.R; Px.A := 255; end;
        2: begin Px.R := Planes[0][P]; Px.G := Px.R; Px.B := Px.R; Px.A := Planes[1][P]; end;
        3: begin Px.R := Planes[0][P]; Px.G := Planes[1][P]; Px.B := Planes[2][P]; Px.A := 255; end;
      else
        begin Px.R := Planes[0][P]; Px.G := Planes[1][P]; Px.B := Planes[2][P]; Px.A := Planes[3][P]; end;
      end;
      SetPx(Result, W, x, imgY, Px);
    end;
end;

procedure PutU16(var D: TBytes; P: NativeUInt; V: Word); inline;
begin
  D[P] := Byte(V shr 8); D[P + 1] := Byte(V);
end;

function EncodeSgi(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  HdrLen, P: NativeInt;
  c, x, y, imgY: Integer;
  Px: TRGBA;
  v: Byte;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then raise ESgiError.Create('SGI: zero image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise ESgiError.Create('SGI: RGBA8 buffer size does not match Width*Height*4');

  HdrLen := 512;
  SetLength(Result, HdrLen + NativeInt(Width) * Height * 4);  // verbatim, 4 chan, 8-bit
  FillChar(Result[0], Length(Result), 0);

  PutU16(Result, 0, 474);       // magic
  Result[2] := 0;               // storage = verbatim
  Result[3] := 1;               // bpc = 1
  PutU16(Result, 4, 3);         // dimension = 3
  PutU16(Result, 6, Word(Width));
  PutU16(Result, 8, Word(Height));
  PutU16(Result, 10, 4);        // zsize = RGBA
  Result[19] := 255;            // pixmax = 255

  P := HdrLen;
  for c := 0 to 3 do
    for y := 0 to Height - 1 do
    begin
      imgY := Height - 1 - y;    // store bottom-to-top
      for x := 0 to Width - 1 do
      begin
        Px := GetPx(InBuf, Width, x, imgY);
        case c of
          0: v := Px.R;
          1: v := Px.G;
          2: v := Px.B;
        else v := Px.A;
        end;
        Result[P] := v; Inc(P);
      end;
    end;
end;

end.
