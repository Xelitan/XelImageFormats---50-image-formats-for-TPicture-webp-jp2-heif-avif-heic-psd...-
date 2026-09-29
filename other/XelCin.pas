unit XelCin;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Kodak Cineon (.cin) decoder/encoder                           //
// Version:	0.2                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// Cineon file layout (the part a viewer needs):
//   * offset 0   : magic 0x802A5FD7 (big-endian file) or reversed (little-endian)
//   * offset 4   : U32 offset to image data
//   * offset 200 : image information header
//       +0 U8 orientation
//       +1 U8 number of channels
//       +2 first channel descriptor (28 bytes each):
//             +2  U8  bits per pixel (usually 10)
//             +4  U32 pixels per line (width)
//             +8  U32 lines per image (height)
//
// Cineon almost always stores 10-bit RGB in "method A" packing: three 10-bit
// samples MSB-justified in a 32-bit word (bits 31..22, 21..12, 11..2), one word
// per RGB pixel. 8-bit (one byte per sample) and 12/16-bit (one 16-bit word per
// sample) files also exist; their values are the same log codes scaled to the
// sample range, so they are rescaled to 10-bit codes first. The layout is taken
// from the data size (the packing byte @681 is often wrong), with the
// end-of-line padding @684 honoured. Sample values are *printing density*
// (log), so we run them through a Kodak-style log->linear curve and then
// sRGB-ish display gamma. This is an approximate but standard viewing
// transform, not a colour-managed one.

interface

uses
  SysUtils, Classes, Math, XelPng;

type
  ECinError = class(Exception);

function DecodeCin(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8
function EncodeCin(InBuf: TBytes; Width, Height: Integer): TBytes;       // InBuf = RGBA8

implementation

const
  RefBlack = 95;
  RefWhite = 685;
  FilmGamma = 0.6;
  DispGamma = 2.2;

var
  LogToDisp: array[0..1023] of Byte;    // 10-bit code -> 8-bit display
  DispToLog: array[0..255] of Word;     // 8-bit display -> 10-bit code (encode)
  TablesReady: Boolean = False;

procedure BuildTables;
var
  cv, v: Integer;
  dens, lin, disp: Double;
begin
  if TablesReady then Exit;
  for cv := 0 to 1023 do
  begin
    dens := (cv - RefWhite) * 0.002;             // code step = 0.002 density
    lin := Power(10.0, dens / FilmGamma);        // -> relative scene linear
    if lin < 0 then lin := 0;
    if lin > 1 then lin := 1;
    disp := Power(lin, 1.0 / DispGamma) * 255.0; // display gamma encode
    v := Round(disp);
    if v < 0 then v := 0;
    if v > 255 then v := 255;
    LogToDisp[cv] := Byte(v);
  end;

  for v := 0 to 255 do
  begin
    lin := Power(v / 255.0, DispGamma);
    if lin < 1e-6 then lin := 1e-6;
    dens := FilmGamma * Log10(lin);
    cv := Round(RefWhite + dens / 0.002);
    if cv < 0 then cv := 0;
    if cv > 1023 then cv := 1023;
    DispToLog[v] := Word(cv);
  end;
  TablesReady := True;
end;

function BEU32(const D: TBytes; P: NativeUInt): Cardinal;
begin
  Result := (Cardinal(D[P]) shl 24) or (Cardinal(D[P + 1]) shl 16) or
            (Cardinal(D[P + 2]) shl 8) or Cardinal(D[P + 3]);
end;

function LEU32(const D: TBytes; P: NativeUInt): Cardinal;
begin
  Result := Cardinal(D[P]) or (Cardinal(D[P + 1]) shl 8) or
            (Cardinal(D[P + 2]) shl 16) or (Cardinal(D[P + 3]) shl 24);
end;

function DecodeCin(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  N: NativeUInt;
  Big: Boolean;
  DataOfs, W32: Cardinal;
  Channels, Bpp: Byte;
  W, H, x, y, Spp, Sidx, WordIdx, PosInWord, ShiftAmt: Integer;
  LineWords, LineBytes, EolPad: NativeUInt;
  RowBase, Ofs: NativeUInt;
  Left12: Boolean;
  Col: TRGBA;

  function Rd32(P: NativeUInt): Cardinal; inline;
  begin
    if Big then Result := BEU32(InBuf, P) else Result := LEU32(InBuf, P);
  end;

  function Sample10(SampleInRow: Integer): Byte;
  var v: Cardinal;
  begin
    case Bpp of
      8:
        Result := LogToDisp[(Cardinal(InBuf[RowBase + NativeUInt(SampleInRow)]) * 1023 + 127) div 255];
      12, 16:
        begin
          Ofs := RowBase + NativeUInt(SampleInRow) * 2;
          if Big then v := (Cardinal(InBuf[Ofs]) shl 8) or InBuf[Ofs + 1]
          else v := (Cardinal(InBuf[Ofs + 1]) shl 8) or InBuf[Ofs];
          if Bpp = 12 then
          begin
            if Left12 then v := v shr 4 else v := v and $FFF;
            Result := LogToDisp[(v * 1023 + 2047) div 4095];
          end
          else
            Result := LogToDisp[(v * 1023 + 32767) div 65535];
        end;
    else
      begin
        WordIdx := SampleInRow div 3;
        PosInWord := SampleInRow mod 3;
        Ofs := RowBase + NativeUInt(WordIdx) * 4;
        W32 := Rd32(Ofs);
        ShiftAmt := 22 - PosInWord * 10;
        Result := LogToDisp[(W32 shr ShiftAmt) and $3FF];
      end;
    end;
  end;

begin
  Width := 0; Height := 0;
  SetLength(Result, 0);
  BuildTables;

  N := NativeUInt(Length(InBuf));
  if N < 2048 then
    raise ECinError.Create('Cineon: file too short for headers');

  if (InBuf[0] = $80) and (InBuf[1] = $2A) and (InBuf[2] = $5F) and (InBuf[3] = $D7) then
    Big := True
  else if (InBuf[0] = $D7) and (InBuf[1] = $5F) and (InBuf[2] = $2A) and (InBuf[3] = $80) then
    Big := False
  else
    raise ECinError.Create('Cineon: bad magic');

  // image information header: orientation @192, channels @193, then eight
  // 28-byte channel descriptors starting at 196 (bpp @+2, width @+4, height @+8).
  DataOfs := Rd32(4);
  Channels := InBuf[193];
  Bpp := InBuf[198];
  W := Integer(Rd32(200));
  H := Integer(Rd32(204));

  if Bpp = 0 then Bpp := 10;
  if not (Bpp in [8, 10, 12, 16]) then
    raise ECinError.CreateFmt('Cineon: unsupported bits per pixel %d', [Bpp]);
  // 12-bit samples sit in 16-bit words: packing 1/3/5 = left justified
  Left12 := InBuf[681] in [1, 3, 5];
  if (W <= 0) or (H <= 0) then
    raise ECinError.Create('Cineon: invalid dimensions');
  if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then
    raise ECinError.Create('Cineon: image too large');

  if Channels >= 3 then Spp := 3 else Spp := 1;

  case Bpp of
    8:      LineBytes := NativeUInt(W) * NativeUInt(Spp);
    12, 16: LineBytes := NativeUInt(W) * NativeUInt(Spp) * 2;
  else
    begin
      LineWords := (NativeUInt(W) * NativeUInt(Spp) + 2) div 3;
      LineBytes := LineWords * 4;
    end;
  end;
  // end-of-line padding (0xFFFFFFFF = undefined)
  EolPad := Rd32(684);
  if (EolPad = $FFFFFFFF) or (EolPad > 1 shl 20) then EolPad := 0;
  if (DataOfs = 0) or (NativeUInt(DataOfs) + (LineBytes + EolPad) * NativeUInt(H) > N) then
  begin
    EolPad := 0;
    if (DataOfs = 0) or (NativeUInt(DataOfs) + LineBytes * NativeUInt(H) > N) then
      raise ECinError.Create('Cineon: truncated / bad image data offset');
  end;

  Width := W; Height := H;
  SetLength(Result, NativeInt(NativeUInt(W) * NativeUInt(H) * 4));

  for y := 0 to H - 1 do
  begin
    RowBase := NativeUInt(DataOfs) + NativeUInt(y) * (LineBytes + EolPad);
    for x := 0 to W - 1 do
    begin
      if Spp = 3 then
      begin
        Sidx := x * 3;
        Col.R := Sample10(Sidx + 0);
        Col.G := Sample10(Sidx + 1);
        Col.B := Sample10(Sidx + 2);
      end
      else
      begin
        Col.R := Sample10(x);
        Col.G := Col.R; Col.B := Col.R;
      end;
      Col.A := 255;
      SetPx(Result, W, x, y, Col);
    end;
  end;
end;

// --------------------------------- encoder ---------------------------------
// Writes a big-endian 10-bit RGB Cineon (method A packing).

procedure PutBE32(var D: TBytes; P: NativeUInt; V: Cardinal);
begin
  D[P + 0] := Byte(V shr 24);
  D[P + 1] := Byte(V shr 16);
  D[P + 2] := Byte(V shr 8);
  D[P + 3] := Byte(V);
end;

procedure PutStr(var D: TBytes; P: NativeUInt; const S: AnsiString);
var I: Integer;
begin
  for I := 1 to Length(S) do D[P + NativeUInt(I - 1)] := Byte(S[I]);
end;

function EncodeCin(InBuf: TBytes; Width, Height: Integer): TBytes;
const
  HdrSize = 1024;
var
  DataOfs, LineWords, RowBase: NativeUInt;
  x, y, i: Integer;
  Base: NativeUInt;
  Col: TRGBA;
  W32: Cardinal;
  P: NativeUInt;
begin
  SetLength(Result, 0);
  BuildTables;
  if (Width <= 0) or (Height <= 0) then
    raise ECinError.Create('Cineon: zero image size');
  if NativeUInt(Length(InBuf)) < NativeUInt(Width) * NativeUInt(Height) * 4 then
    raise ECinError.Create('Cineon: RGBA8 buffer too small');

  DataOfs := HdrSize;
  LineWords := (NativeUInt(Width) * 3 + 2) div 3;   // = Width for RGB
  SetLength(Result, NativeInt(DataOfs + LineWords * 4 * NativeUInt(Height)));

  // file information header
  Result[0] := $80; Result[1] := $2A; Result[2] := $5F; Result[3] := $D7;
  PutBE32(Result, 4, Cardinal(DataOfs));
  PutBE32(Result, 8, HdrSize);                        // generic section length
  PutBE32(Result, 20, Cardinal(Length(Result)));      // total file size
  PutStr(Result, 24, 'V4.5');

  // image information header: orientation @192, channels @193, three 28-byte
  // channel descriptors from 196 (bpp @+2, width @+4, height @+8)
  Result[192] := 0;                                   // orientation
  Result[193] := 3;                                   // channels
  for i := 0 to 2 do
  begin
    Base := 196 + NativeUInt(i) * 28;
    Result[Base + 0] := 0;                            // designator 0
    Result[Base + 1] := Byte(1 + i);                  // designator 1 (channel)
    Result[Base + 2] := 10;                           // bits per pixel
    Result[Base + 3] := 0;
    PutBE32(Result, Base + 4, Cardinal(Width));
    PutBE32(Result, Base + 8, Cardinal(Height));
  end;

  for y := 0 to Height - 1 do
  begin
    RowBase := DataOfs + NativeUInt(y) * LineWords * 4;
    for x := 0 to Width - 1 do
    begin
      Col := GetPx(InBuf, Width, x, y);
      W32 := (Cardinal(DispToLog[Col.R]) shl 22) or
             (Cardinal(DispToLog[Col.G]) shl 12) or
             (Cardinal(DispToLog[Col.B]) shl 2);
      P := RowBase + NativeUInt(x) * 4;
      PutBE32(Result, P, W32);
    end;
  end;
end;

end.
