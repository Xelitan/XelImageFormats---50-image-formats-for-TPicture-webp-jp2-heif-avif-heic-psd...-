unit XelMiff;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	MIFF (Magick Image File Format) decoder/encoder               //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// MIFF is an ASCII key=value header (brace blocks are comments and may hold
// spaces and colons) terminated by a colon immediately followed by Ctrl-Z
// (0x1A); the image data begins right after. Supported here:
//   * DirectClass: colorspace sRGB/RGB or Gray, depth 8/16, optional alpha.
//   * PseudoClass: a raw RGB colormap of `colors` entries followed by 1- or
//     2-byte palette indices (optional alpha), depth 8/16.
//   * compression None / RLE (a.k.a. RunlengthEncoded) / Zip (zlib) / BZip.
// CMYK is rejected. Alpha is read as straight alpha (modern MIFF convention).

interface

uses
  SysUtils, Classes, XelPng, XelInflate, XelBZ2Unpack;

type
  EMiffError = class(Exception);

function DecodeMiff(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8
function EncodeMiff(InBuf: TBytes; Width, Height: Integer): TBytes;       // InBuf = RGBA8

implementation

// Returns the value for Key (case-insensitive) from the header text. Skips
// brace comment blocks entirely and treats whitespace as the only separator.
function HeaderVal(const Hdr: string; const Key: string): string;
var
  I, L: Integer;
  K, V: string;
begin
  Result := '';
  L := Length(Hdr);
  I := 1;
  while I <= L do
  begin
    while (I <= L) and (Hdr[I] in [' ', #9, #10, #13, #12]) do Inc(I);
    if (I <= L) and (Hdr[I] = '{') then          // comment block - skip to close brace
    begin
      Inc(I);
      while (I <= L) and (Hdr[I] <> '}') do Inc(I);
      Inc(I);
      Continue;
    end;
    K := '';
    while (I <= L) and not (Hdr[I] in ['=', ' ', #9, #10, #13, #12, '{']) do
    begin K := K + Hdr[I]; Inc(I); end;
    if (I <= L) and (Hdr[I] = '=') then
    begin
      Inc(I);
      V := '';
      if (I <= L) and (Hdr[I] = '{') then
      begin
        Inc(I);
        while (I <= L) and (Hdr[I] <> '}') do begin V := V + Hdr[I]; Inc(I); end;
        Inc(I);
      end
      else
        while (I <= L) and not (Hdr[I] in [' ', #9, #10, #13, #12]) do
        begin V := V + Hdr[I]; Inc(I); end;
      if SameText(K, Key) then begin Result := Trim(V); Exit; end;
    end;
  end;
end;

function ToIntDef2(const S: string; Def: Integer): Integer;
var Code: Integer; V: LongInt;
begin
  Val(Trim(S), V, Code);
  if Code = 0 then Result := V else Result := Def;
end;

// Decompresses/collects PixelCount*Bpp interleaved bytes from InBuf[Start..] using
// the named compression, where one "pixel" is Bpp bytes.
// ImageMagick writes Zip/BZip pixel data as length-prefixed chunks: a 4-byte
// big-endian length before each piece of one continuous zlib/bzip2 stream
// (flushed per row). Joins the pieces back into the plain stream.
function JoinChunks(const InBuf: TBytes; Start, N: NativeUInt): TBytes;
var
  p, L, o: NativeUInt;
begin
  SetLength(Result, N - Start);
  o := 0; p := Start;
  while p + 4 <= N do
  begin
    L := (NativeUInt(InBuf[p]) shl 24) or (NativeUInt(InBuf[p + 1]) shl 16) or
         (NativeUInt(InBuf[p + 2]) shl 8) or InBuf[p + 3];
    if (L = 0) or (L > N - p - 4) then Break;
    Move(InBuf[p + 4], Result[o], L);
    Inc(o, L); Inc(p, 4 + L);
  end;
  SetLength(Result, o);
end;

// Some ImageMagick versions never write the Z_FINISH chunk, so the stream ends
// with a sync-flush marker (empty stored block 00 00 FF FF) and has no final
// block. Append an empty final stored block so the inflater terminates.
procedure CloseSyncFlushed(var Z: TBytes);
var L: Integer;
begin
  L := Length(Z);
  if (L >= 4) and (Z[L - 4] = $00) and (Z[L - 3] = $00) and
     (Z[L - 2] = $FF) and (Z[L - 1] = $FF) then
  begin
    SetLength(Z, L + 5);
    Z[L] := $01; Z[L + 1] := $00; Z[L + 2] := $00; Z[L + 3] := $FF; Z[L + 4] := $FF;
  end;
end;

// 16-bit sample -> 8 bit, rounded the way ImageMagick scales it
function To8(Hi, Lo: Byte): Byte; inline;
begin
  Result := ((Integer(Hi) shl 8 or Lo) + 128) div 257;
end;

function GetPixelBytes(const InBuf: TBytes; Start, N: NativeUInt; const CompS: string;
  PixelCount: NativeUInt; Bpp: Integer): TBytes;
var
  RawNeeded: NativeUInt;
  I: NativeUInt;
  Joined: TBytes;
  p, run, k: Integer;
begin
  RawNeeded := PixelCount * NativeUInt(Bpp);
  if (CompS = '') or SameText(CompS, 'None') then
  begin
    if Start + RawNeeded > N then raise EMiffError.Create('MIFF: truncated pixel data');
    SetLength(Result, RawNeeded);
    Move(InBuf[Start], Result[0], RawNeeded);
  end
  else if SameText(CompS, 'Zip') then
  begin
    if (Start < N) and (InBuf[Start] = $78) then            // plain zlib stream
      Result := InflateZlib(@InBuf[Start], N - Start)
    else
    begin
      Joined := JoinChunks(InBuf, Start, N);
      if Length(Joined) = 0 then raise EMiffError.Create('MIFF: empty Zip data');
      CloseSyncFlushed(Joined);
      Result := InflateZlib(@Joined[0], Length(Joined));
    end;
  end
  else if SameText(CompS, 'BZip') then
  begin
    if (Start + 3 <= N) and (InBuf[Start] = Ord('B')) and (InBuf[Start + 1] = Ord('Z')) and
       (InBuf[Start + 2] = Ord('h')) then                      // plain bzip2 stream
      Result := BZ2DecompressBytes(Copy(InBuf, Start, N - Start))
    else
      Result := BZ2DecompressBytes(JoinChunks(InBuf, Start, N));
  end
  else if SameText(CompS, 'RLE') or SameText(CompS, 'RunlengthEncoded') then
  begin
    SetLength(Result, RawNeeded);
    I := Start; p := 0;
    // each packet: one pixel (Bpp bytes) followed by a repeat count - 1
    while (NativeUInt(p) < PixelCount) and (I + NativeUInt(Bpp) < N) do
    begin
      run := InBuf[I + NativeUInt(Bpp)] + 1;
      while (run > 0) and (NativeUInt(p) < PixelCount) do
      begin
        for k := 0 to Bpp - 1 do Result[NativeUInt(p) * NativeUInt(Bpp) + NativeUInt(k)] := InBuf[I + NativeUInt(k)];
        Inc(p); Dec(run);
      end;
      Inc(I, NativeUInt(Bpp) + 1);
    end;
  end
  else
    raise EMiffError.CreateFmt('MIFF: unsupported compression "%s"', [CompS]);

  if NativeUInt(Length(Result)) < RawNeeded then
    raise EMiffError.Create('MIFF: decompressed data too small');
end;

function DecodeMiff(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  N, I, DataStart, PixDataStart: NativeUInt;
  Hdr: string;
  ClassS, ColorS, CompS, MatteS: string;
  Depth, W, H, Spp, DepthBytes, Bpp, IndexBytes, AlphaBytes, NumColors: Integer;
  IsGray, HasAlpha, IsPseudo, AlphaInv: Boolean;
  PixelCount: NativeUInt;
  Raw: TBytes;
  p, x, y, s, idx, Depth2: Integer;
  o, eo, HdrLen: NativeUInt;
  Col: TRGBA;
  PalR, PalG, PalB: array of Byte;

  function AlphaOf(V: Byte): Byte;
  begin
    if AlphaInv then Result := 255 - V else Result := V;
  end;

  function Samp(Base: NativeUInt; ByteIdx: Integer): Byte;   // depth-sized sample -> 8 bit
  var So: NativeUInt;
  begin
    So := Base + NativeUInt(ByteIdx);
    if So + NativeUInt(DepthBytes) > NativeUInt(Length(Raw)) then Result := 0
    else if DepthBytes = 2 then
      Result := To8(Raw[So], Raw[So + 1])
    else Result := Raw[So];
  end;

begin
  Width := 0; Height := 0;
  SetLength(Result, 0);
  N := NativeUInt(Length(InBuf));
  if N < 16 then raise EMiffError.Create('MIFF: file too short');

  // The header ends at the first colon that starts a token (i.e. follows
  // whitespace) outside a brace comment - keys like "date:create" and values
  // like timestamps contain colons too. Pixel data starts after that colon plus its trailing
  // separator (Ctrl-Z, formfeed, CR and/or LF).
  DataStart := 0; HdrLen := 0; Depth2 := 0; I := 0;
  while I < N do
  begin
    if InBuf[I] = Ord('{') then Inc(Depth2)
    else if InBuf[I] = Ord('}') then begin if Depth2 > 0 then Dec(Depth2); end
    else if (InBuf[I] = Ord(':')) and (Depth2 = 0) and
            ((I = 0) or (InBuf[I - 1] in [9, 10, 12, 13, 32])) then
    begin
      HdrLen := I;
      Inc(I);                                  // past the colon
      if (I < N) and (InBuf[I] = $1A) then Inc(I)   // standard Ctrl-Z terminator
      else
      begin                                     // or a single CR/LF newline
        if (I < N) and (InBuf[I] = $0D) then Inc(I);
        if (I < N) and (InBuf[I] = $0A) then Inc(I);
      end;
      DataStart := I;
      Break;
    end;
    Inc(I);
  end;
  if DataStart = 0 then raise EMiffError.Create('MIFF: header terminator not found');

  SetLength(Hdr, HdrLen);
  for p := 1 to Integer(HdrLen) do Hdr[p] := Chr(InBuf[NativeUInt(p - 1)]);

  ClassS := HeaderVal(Hdr, 'class'); if ClassS = '' then ClassS := 'DirectClass';
  ColorS := HeaderVal(Hdr, 'colorspace');
  CompS  := HeaderVal(Hdr, 'compression');
  MatteS := HeaderVal(Hdr, 'matte');
  Depth  := ToIntDef2(HeaderVal(Hdr, 'depth'), 8);
  W      := ToIntDef2(HeaderVal(Hdr, 'columns'), 0);
  H      := ToIntDef2(HeaderVal(Hdr, 'rows'), 0);
  NumColors := ToIntDef2(HeaderVal(Hdr, 'colors'), 0);

  // a montage image carries a NUL-terminated directory of tile names first
  if HeaderVal(Hdr, 'montage') <> '' then
  begin
    while (DataStart < N) and (InBuf[DataStart] <> 0) do Inc(DataStart);
    Inc(DataStart);
  end;
  // RLE packets store opacity (inverted alpha) instead of alpha
  AlphaInv := SameText(CompS, 'RLE') or SameText(CompS, 'RunlengthEncoded');

  if (W <= 0) or (H <= 0) then raise EMiffError.Create('MIFF: invalid dimensions');
  if not ((Depth = 8) or (Depth = 16)) then
    raise EMiffError.CreateFmt('MIFF: unsupported depth %d', [Depth]);
  if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then
    raise EMiffError.Create('MIFF: image too large');

  IsPseudo := SameText(ClassS, 'PseudoClass');
  HasAlpha := SameText(MatteS, 'True');
  DepthBytes := Depth div 8;
  PixelCount := NativeUInt(W) * NativeUInt(H);
  Width := W; Height := H;
  SetLength(Result, NativeInt(PixelCount * 4));

  if IsPseudo then
  begin
    if NumColors <= 0 then raise EMiffError.Create('MIFF: PseudoClass without colors');
    // raw RGB colormap right after the header
    SetLength(PalR, NumColors); SetLength(PalG, NumColors); SetLength(PalB, NumColors);
    for idx := 0 to NumColors - 1 do
    begin
      eo := DataStart + NativeUInt(idx) * 3 * NativeUInt(DepthBytes);
      if eo + 2 * NativeUInt(DepthBytes) >= N then Break;
      if DepthBytes = 2 then
      begin
        PalR[idx] := To8(InBuf[eo], InBuf[eo + 1]);
        PalG[idx] := To8(InBuf[eo + 2], InBuf[eo + 3]);
        PalB[idx] := To8(InBuf[eo + 4], InBuf[eo + 5]);
      end
      else
      begin
        PalR[idx] := InBuf[eo];
        PalG[idx] := InBuf[eo + 1];
        PalB[idx] := InBuf[eo + 2];
      end;
    end;
    PixDataStart := DataStart + NativeUInt(NumColors) * 3 * NativeUInt(DepthBytes);
    // indexes are depth-sized; ImageMagick switches to DirectClass when the
    // colour count does not fit the depth
    IndexBytes := DepthBytes;
    if HasAlpha then AlphaBytes := DepthBytes else AlphaBytes := 0;
    Bpp := IndexBytes + AlphaBytes;

    Raw := GetPixelBytes(InBuf, PixDataStart, N, CompS, PixelCount, Bpp);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        p := y * W + x;
        o := NativeUInt(p) * NativeUInt(Bpp);
        if IndexBytes = 1 then idx := Raw[o]
        else idx := (Integer(Raw[o]) shl 8) or Raw[o + 1];
        if idx >= NumColors then idx := NumColors - 1;
        if idx < 0 then idx := 0;
        Col.R := PalR[idx]; Col.G := PalG[idx]; Col.B := PalB[idx];
        if HasAlpha then Col.A := AlphaOf(Samp(o, IndexBytes)) else Col.A := 255;
        SetPx(Result, W, x, y, Col);
      end;
    Exit;
  end;

  // ---- DirectClass ----
  IsGray := SameText(ColorS, 'Gray') or SameText(ColorS, 'GRAY');
  if not (IsGray or SameText(ColorS, 'sRGB') or SameText(ColorS, 'RGB') or (ColorS = '')) then
    raise EMiffError.CreateFmt('MIFF: unsupported colorspace "%s"', [ColorS]);
  if IsGray then Spp := 1 else Spp := 3;
  if HasAlpha then Inc(Spp);
  Bpp := Spp * DepthBytes;

  Raw := GetPixelBytes(InBuf, DataStart, N, CompS, PixelCount, Bpp);
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      p := y * W + x;
      o := NativeUInt(p) * NativeUInt(Bpp);
      if IsGray then
      begin
        Col.R := Samp(o, 0); Col.G := Col.R; Col.B := Col.R;
        if HasAlpha then Col.A := AlphaOf(Samp(o, DepthBytes)) else Col.A := 255;
      end
      else
      begin
        Col.R := Samp(o, 0 * DepthBytes);
        Col.G := Samp(o, 1 * DepthBytes);
        Col.B := Samp(o, 2 * DepthBytes);
        if HasAlpha then Col.A := AlphaOf(Samp(o, 3 * DepthBytes)) else Col.A := 255;
      end;
      SetPx(Result, W, x, y, Col);
    end;
  s := Spp;   // keep referenced
  if s < 0 then Exit;
end;

// --------------------------------- encoder ---------------------------------
// Writes DirectClass sRGB, depth 8, matte True, compression None.

procedure AppendStr(var D: TBytes; const S: AnsiString);
var M, L: NativeInt;
begin
  L := Length(S);
  if L = 0 then Exit;
  M := Length(D);
  SetLength(D, M + L);
  Move(S[1], D[M], L);
end;

function EncodeMiff(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  Hdr: AnsiString;
  Base: NativeInt;
  x, y: Integer;
  Col: TRGBA;
  P: NativeInt;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then raise EMiffError.Create('MIFF: zero image size');
  if NativeUInt(Length(InBuf)) < NativeUInt(Width) * NativeUInt(Height) * 4 then
    raise EMiffError.Create('MIFF: RGBA8 buffer too small');

  Hdr := 'id=ImageMagick  version=1.0'#10 +
         'class=DirectClass  colorspace=sRGB  matte=True'#10 +
         'columns=' + AnsiString(IntToStr(Width)) + '  rows=' +
            AnsiString(IntToStr(Height)) + '  depth=8'#10 +
         'compression=None'#10 +
         #12#10':'#26;
  AppendStr(Result, Hdr);

  Base := Length(Result);
  SetLength(Result, Base + NativeInt(Width) * NativeInt(Height) * 4);
  for y := 0 to Height - 1 do
    for x := 0 to Width - 1 do
    begin
      Col := GetPx(InBuf, Width, x, y);
      P := Base + (NativeInt(y) * Width + x) * 4;
      Result[P + 0] := Col.R; Result[P + 1] := Col.G;
      Result[P + 2] := Col.B; Result[P + 3] := Col.A;
    end;
end;

end.
