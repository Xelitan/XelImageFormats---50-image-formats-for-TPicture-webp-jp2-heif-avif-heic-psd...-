unit XelDpx;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	DPX (SMPTE 268M) decoder/encoder                              //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// DPX file layout (the part a viewer needs):
//   * offset 0   : magic "SDPX" (big-endian file) or "XPDS" (little-endian)
//   * offset 4   : U32 offset to image data (generic-header fallback)
//   * offset 768 : image information header
//       +0  U16 orientation
//       +2  U16 number of image elements
//       +4  U32 pixels per line (width)
//       +8  U32 lines per element (height)
//       +12 first image element (72 bytes each):
//             +20 U8  descriptor  (6=luma, 50=RGB, 51=RGBA)
//             +21 U8  transfer characteristic
//             +23 U8  bit size (8/10/12/16)
//             +24 U16 packing (0=packed, 1=method A)
//             +26 U16 encoding (0=none, 1=RLE)
//             +28 U32 offset to this element's data
//             +32 U32 end-of-line padding (bytes)
//
// Supported here: uncompressed (encoding 0), descriptors luma/RGB/RGBA,
// bit sizes 8 / 10 (method A, 3 samples per 32-bit word) / 12 (method A,
// one sample per 16-bit word, left-justified) / 16. RLE is rejected.
// Values are treated as display-linear; the log (film) case is XelCin's job.

interface

uses
  SysUtils, Classes, XelPng;

type
  EDpxError = class(Exception);

function DecodeDpx(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8
function EncodeDpx(InBuf: TBytes; Width, Height: Integer): TBytes;       // InBuf = RGBA8

implementation

type
  TRdU32 = function(const D: TBytes; P: NativeUInt): Cardinal;
  TRdU16 = function(const D: TBytes; P: NativeUInt): Word;

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

function BEU16(const D: TBytes; P: NativeUInt): Word;
begin
  Result := (Word(D[P]) shl 8) or Word(D[P + 1]);
end;

function LEU16(const D: TBytes; P: NativeUInt): Word;
begin
  Result := Word(D[P]) or (Word(D[P + 1]) shl 8);
end;

function DecodeDpx(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  N: NativeUInt;
  Big: Boolean;
  RdU32: TRdU32;
  RdU16: TRdU16;
  ImgHdr, Elem: NativeUInt;
  Descriptor, BitSize: Byte;
  Packing, Encoding: Word;
  DataOfs, EolPad: Cardinal;
  W, H, Spp, x, y: Integer;
  LineBytes: NativeUInt;
  Col: TRGBA;

  // Nth sample of a row (0-based), scaled to 8 bits. RowBase = byte offset of
  // the row's first sample.
  function Sample8(RowBase: NativeUInt; SampleInRow: Integer): Byte;
  var
    Ofs: NativeUInt;
    Word32, Raw: Cardinal;
    ShiftAmt, Idx, PosInWord: Integer;
  begin
    case BitSize of
      8:
        Result := InBuf[RowBase + NativeUInt(SampleInRow)];
      10:
        begin
          Idx := SampleInRow div 3;             // 3 samples per 32-bit word
          PosInWord := SampleInRow mod 3;
          Ofs := RowBase + NativeUInt(Idx) * 4;
          Word32 := RdU32(InBuf, Ofs);
          ShiftAmt := 22 - PosInWord * 10;      // bits 31..22, 21..12, 11..2
          Raw := (Word32 shr ShiftAmt) and $3FF;
          Result := Byte(Raw shr 2);
        end;
      12:
        begin
          Ofs := RowBase + NativeUInt(SampleInRow) * 2;
          Raw := (Cardinal(RdU16(InBuf, Ofs)) shr 4) and $FFF;  // method A: left-justified
          Result := Byte(Raw shr 4);
        end;
      16:
        begin
          Ofs := RowBase + NativeUInt(SampleInRow) * 2;
          Raw := RdU16(InBuf, Ofs);
          Result := Byte(Raw shr 8);
        end;
    else
      Result := 0;
    end;
  end;

begin
  Width := 0; Height := 0;
  SetLength(Result, 0);
  N := NativeUInt(Length(InBuf));
  if N < 780 + 44 then
    raise EDpxError.Create('DPX: file too short for headers');

  if (InBuf[0] = Ord('S')) and (InBuf[1] = Ord('D')) and
     (InBuf[2] = Ord('P')) and (InBuf[3] = Ord('X')) then
    Big := True
  else if (InBuf[0] = Ord('X')) and (InBuf[1] = Ord('P')) and
          (InBuf[2] = Ord('D')) and (InBuf[3] = Ord('S')) then
    Big := False
  else
    raise EDpxError.Create('DPX: bad magic (expected SDPX/XPDS)');

  if Big then begin RdU32 := @BEU32; RdU16 := @BEU16; end
  else begin RdU32 := @LEU32; RdU16 := @LEU16; end;

  ImgHdr := 768;
  W := Integer(RdU32(InBuf, ImgHdr + 4));
  H := Integer(RdU32(InBuf, ImgHdr + 8));
  if (W <= 0) or (H <= 0) then
    raise EDpxError.Create('DPX: invalid dimensions');
  if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then
    raise EDpxError.Create('DPX: image too large');

  Elem := ImgHdr + 12;                 // first image element
  Descriptor := InBuf[Elem + 20];
  BitSize    := InBuf[Elem + 23];
  Packing    := RdU16(InBuf, Elem + 24);
  Encoding   := RdU16(InBuf, Elem + 26);
  DataOfs    := RdU32(InBuf, Elem + 28);
  EolPad     := RdU32(InBuf, Elem + 32);

  if Encoding <> 0 then
    raise EDpxError.Create('DPX: RLE-encoded data is not supported');

  case Descriptor of
    6:      Spp := 1;                  // luminance
    50:     Spp := 3;                  // RGB
    51:     Spp := 4;                  // RGBA
  else
    raise EDpxError.CreateFmt('DPX: unsupported descriptor %d', [Descriptor]);
  end;

  if not (BitSize in [8, 10, 12, 16]) then
    raise EDpxError.CreateFmt('DPX: unsupported bit size %d', [BitSize]);
  if (BitSize in [10, 12]) and (Packing = 0) then
    raise EDpxError.Create('DPX: only packing method A supported for 10/12-bit');

  if (DataOfs = 0) or (DataOfs >= N) then
    DataOfs := RdU32(InBuf, 4);        // fall back to generic header field
  if (DataOfs = 0) or (DataOfs >= N) then
    raise EDpxError.Create('DPX: bad image data offset');

  // bytes per row, including any end-of-line padding
  case BitSize of
    8:  LineBytes := NativeUInt(W) * NativeUInt(Spp);
    10: LineBytes := ((NativeUInt(W) * NativeUInt(Spp) + 2) div 3) * 4;
    12: LineBytes := NativeUInt(W) * NativeUInt(Spp) * 2;
    16: LineBytes := NativeUInt(W) * NativeUInt(Spp) * 2;
  else
    LineBytes := 0;
  end;
  Inc(LineBytes, EolPad);

  if NativeUInt(DataOfs) + LineBytes * NativeUInt(H) > N then
    raise EDpxError.Create('DPX: truncated image data');

  Width := W;
  Height := H;
  SetLength(Result, NativeInt(NativeUInt(W) * NativeUInt(H) * 4));

  for y := 0 to H - 1 do
  begin
    for x := 0 to W - 1 do
    begin
      case Spp of
        1: begin
             Col.R := Sample8(NativeUInt(DataOfs) + NativeUInt(y) * LineBytes, x);
             Col.G := Col.R; Col.B := Col.R; Col.A := 255;
           end;
        3: begin
             Col.R := Sample8(NativeUInt(DataOfs) + NativeUInt(y) * LineBytes, x * 3 + 0);
             Col.G := Sample8(NativeUInt(DataOfs) + NativeUInt(y) * LineBytes, x * 3 + 1);
             Col.B := Sample8(NativeUInt(DataOfs) + NativeUInt(y) * LineBytes, x * 3 + 2);
             Col.A := 255;
           end;
      else
        begin
          Col.R := Sample8(NativeUInt(DataOfs) + NativeUInt(y) * LineBytes, x * 4 + 0);
          Col.G := Sample8(NativeUInt(DataOfs) + NativeUInt(y) * LineBytes, x * 4 + 1);
          Col.B := Sample8(NativeUInt(DataOfs) + NativeUInt(y) * LineBytes, x * 4 + 2);
          Col.A := Sample8(NativeUInt(DataOfs) + NativeUInt(y) * LineBytes, x * 4 + 3);
        end;
      end;
      SetPx(Result, W, x, y, Col);
    end;
  end;
end;

// --------------------------------- encoder ---------------------------------
// Writes a minimal big-endian 8-bit RGB uncompressed DPX (packing 0).

procedure PutBE32(var D: TBytes; P: NativeUInt; V: Cardinal);
begin
  D[P + 0] := Byte(V shr 24);
  D[P + 1] := Byte(V shr 16);
  D[P + 2] := Byte(V shr 8);
  D[P + 3] := Byte(V);
end;

procedure PutBE16(var D: TBytes; P: NativeUInt; V: Word);
begin
  D[P + 0] := Byte(V shr 8);
  D[P + 1] := Byte(V);
end;

procedure PutStr(var D: TBytes; P: NativeUInt; const S: AnsiString);
var
  I: Integer;
begin
  for I := 1 to Length(S) do D[P + NativeUInt(I - 1)] := Byte(S[I]);
end;

function EncodeDpx(InBuf: TBytes; Width, Height: Integer): TBytes;
const
  HdrSize = 2048;               // generic(768)+image(640)+orient(256)+film/tv rounded up
var
  DataOfs, RowBytes: NativeUInt;
  x, y: Integer;
  Col: TRGBA;
  Elem, P: NativeUInt;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then
    raise EDpxError.Create('DPX: zero image size');
  if NativeUInt(Length(InBuf)) < NativeUInt(Width) * NativeUInt(Height) * 4 then
    raise EDpxError.Create('DPX: RGBA8 buffer too small');

  DataOfs := HdrSize;
  RowBytes := NativeUInt(Width) * 3;
  SetLength(Result, NativeInt(DataOfs + RowBytes * NativeUInt(Height)));

  PutStr(Result, 0, 'SDPX');
  PutBE32(Result, 4, Cardinal(DataOfs));                 // offset to image data
  PutStr(Result, 8, 'V2.0');
  PutBE32(Result, 12, Cardinal(Length(Result)));         // total file size
  PutBE32(Result, 20, 1);                                // new-image (ditto key)
  PutBE32(Result, 24, HdrSize - 768);                    // generic section size

  // image information header at 768
  PutBE16(Result, 768 + 0, 0);                           // orientation: L-R, T-B
  PutBE16(Result, 768 + 2, 1);                           // one image element
  PutBE32(Result, 768 + 4, Cardinal(Width));
  PutBE32(Result, 768 + 8, Cardinal(Height));

  Elem := 768 + 12;
  PutBE32(Result, Elem + 0, 0);                          // data sign: unsigned
  Result[Elem + 20] := 50;                               // descriptor: RGB
  Result[Elem + 21] := 2;                                // transfer: linear
  Result[Elem + 22] := 2;                                // colorimetric: unspec
  Result[Elem + 23] := 8;                                // bit size
  PutBE16(Result, Elem + 24, 0);                         // packing: packed
  PutBE16(Result, Elem + 26, 0);                         // encoding: none
  PutBE32(Result, Elem + 28, Cardinal(DataOfs));         // data offset
  PutBE32(Result, Elem + 32, 0);                         // eol padding
  PutBE32(Result, Elem + 36, 0);                         // eoi padding

  for y := 0 to Height - 1 do
    for x := 0 to Width - 1 do
    begin
      Col := GetPx(InBuf, Width, x, y);
      P := DataOfs + NativeUInt(y) * RowBytes + NativeUInt(x) * 3;
      Result[P + 0] := Col.R;
      Result[P + 1] := Col.G;
      Result[P + 2] := Col.B;
    end;
end;

end.
