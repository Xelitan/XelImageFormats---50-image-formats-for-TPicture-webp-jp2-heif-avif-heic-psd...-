unit XelQoi;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	QOI (Quite OK Image)                                          //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Clean-room implementation from the public QOI spec. (qoiformat.org)        //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelPng;

type
  EQoiError = class(Exception);

function DecodeQoi(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8
function EncodeQoi(InBuf: TBytes; Width, Height: Integer): TBytes;        // InBuf = RGBA8

implementation

const
  QOI_OP_INDEX = $00;   // 00xxxxxx
  QOI_OP_DIFF  = $40;   // 01xxxxxx
  QOI_OP_LUMA  = $80;   // 10xxxxxx
  QOI_OP_RUN   = $C0;   // 11xxxxxx
  QOI_OP_RGB   = $FE;
  QOI_OP_RGBA  = $FF;
  QOI_MASK_2   = $C0;

function Hash(const C: TRGBA): Integer; inline;
begin
  Result := (Integer(C.R) * 3 + Integer(C.G) * 5 +
             Integer(C.B) * 7 + Integer(C.A) * 11) and 63;
end;

function SamePixel(const A, B: TRGBA): Boolean; inline;
begin
  Result := (A.R = B.R) and (A.G = B.G) and (A.B = B.B) and (A.A = B.A);
end;

function ReadBE32(const Data: TBytes; Pos: NativeUInt): Cardinal; inline;
begin
  Result := (Cardinal(Data[Pos]) shl 24) or (Cardinal(Data[Pos + 1]) shl 16) or
            (Cardinal(Data[Pos + 2]) shl 8) or Cardinal(Data[Pos + 3]);
end;

function DecodeQoi(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Pos, N, PixelCount, PxPos: NativeUInt;
  W, H: Cardinal;
  Channels: Byte;
  Index: array[0..63] of TRGBA;
  Px: TRGBA;
  Run, I: Integer;
  b1, b2: Byte;
  vg: Integer;
begin
  Width := 0;
  Height := 0;
  SetLength(Result, 0);

  N := NativeUInt(Length(InBuf));
  if N < 14 + 8 then
    raise EQoiError.Create('QOI: file too small');
  if (InBuf[0] <> Ord('q')) or (InBuf[1] <> Ord('o')) or
     (InBuf[2] <> Ord('i')) or (InBuf[3] <> Ord('f')) then
    raise EQoiError.Create('QOI: bad signature');

  W := ReadBE32(InBuf, 4);
  H := ReadBE32(InBuf, 8);
  Channels := InBuf[12];   // 3 or 4 (informational; output is always RGBA8)
  // InBuf[13] = colorspace (informational)
  if (W = 0) or (H = 0) then
    raise EQoiError.Create('QOI: zero image size');
  if (Channels <> 3) and (Channels <> 4) then
    raise EQoiError.Create('QOI: invalid channel count');
  if UInt64(W) * UInt64(H) * 4 > UInt64(High(NativeInt)) then
    raise EQoiError.Create('QOI: image too large');

  Width := Integer(W);
  Height := Integer(H);
  PixelCount := NativeUInt(W) * NativeUInt(H);
  SetLength(Result, NativeInt(PixelCount * 4));

  for I := 0 to 63 do
  begin
    Index[I].R := 0; Index[I].G := 0; Index[I].B := 0; Index[I].A := 0;
  end;
  Px.R := 0; Px.G := 0; Px.B := 0; Px.A := 255;
  Run := 0;
  Pos := 14;

  PxPos := 0;
  while PxPos < PixelCount do
  begin
    if Run > 0 then
      Dec(Run)
    else
    begin
      if Pos >= N then
        raise EQoiError.Create('QOI: truncated stream');
      b1 := InBuf[Pos]; Inc(Pos);

      if b1 = QOI_OP_RGB then
      begin
        if Pos + 3 > N then raise EQoiError.Create('QOI: truncated RGB chunk');
        Px.R := InBuf[Pos]; Px.G := InBuf[Pos + 1]; Px.B := InBuf[Pos + 2];
        Inc(Pos, 3);
      end
      else if b1 = QOI_OP_RGBA then
      begin
        if Pos + 4 > N then raise EQoiError.Create('QOI: truncated RGBA chunk');
        Px.R := InBuf[Pos]; Px.G := InBuf[Pos + 1];
        Px.B := InBuf[Pos + 2]; Px.A := InBuf[Pos + 3];
        Inc(Pos, 4);
      end
      else if (b1 and QOI_MASK_2) = QOI_OP_INDEX then
        Px := Index[b1 and 63]
      else if (b1 and QOI_MASK_2) = QOI_OP_DIFF then
      begin
        Px.R := Byte(Px.R + (((b1 shr 4) and 3) - 2));
        Px.G := Byte(Px.G + (((b1 shr 2) and 3) - 2));
        Px.B := Byte(Px.B + ( (b1        and 3) - 2));
      end
      else if (b1 and QOI_MASK_2) = QOI_OP_LUMA then
      begin
        if Pos >= N then raise EQoiError.Create('QOI: truncated LUMA chunk');
        b2 := InBuf[Pos]; Inc(Pos);
        vg := (b1 and 63) - 32;
        Px.R := Byte(Px.R + (vg - 8 + ((b2 shr 4) and 15)));
        Px.G := Byte(Px.G + vg);
        Px.B := Byte(Px.B + (vg - 8 + ( b2        and 15)));
      end
      else // QOI_OP_RUN
        Run := b1 and 63;   // run length - 1 additional pixels

      Index[Hash(Px)] := Px;
    end;

    SetPx(Result, Integer(W), Integer(PxPos mod W), Integer(PxPos div W), Px);
    Inc(PxPos);
  end;
end;

procedure AppendByte(var D: TBytes; var Len: NativeInt; B: Byte); inline;
begin
  if Len >= Length(D) then SetLength(D, Length(D) * 2 + 64);
  D[Len] := B; Inc(Len);
end;

function EncodeQoi(InBuf: TBytes; Width, Height: Integer): TBytes;
var
  Len: NativeInt;
  Index: array[0..63] of TRGBA;
  Px, Prev: TRGBA;
  Run, I, X, Y, IdxPos: Integer;
  vr, vg, vb, drdg, dbdg: Integer;
  IsLast: Boolean;
begin
  SetLength(Result, 0);
  if (Width <= 0) or (Height <= 0) then
    raise EQoiError.Create('QOI: zero image size');
  if UInt64(Length(InBuf)) <> UInt64(Width) * UInt64(Height) * 4 then
    raise EQoiError.Create('QOI: RGBA8 buffer size does not match Width*Height*4');

  SetLength(Result, 14 + 8);
  Len := 0;
  // header
  AppendByte(Result, Len, Ord('q')); AppendByte(Result, Len, Ord('o'));
  AppendByte(Result, Len, Ord('i')); AppendByte(Result, Len, Ord('f'));
  AppendByte(Result, Len, Byte(Cardinal(Width) shr 24));
  AppendByte(Result, Len, Byte(Cardinal(Width) shr 16));
  AppendByte(Result, Len, Byte(Cardinal(Width) shr 8));
  AppendByte(Result, Len, Byte(Cardinal(Width)));
  AppendByte(Result, Len, Byte(Cardinal(Height) shr 24));
  AppendByte(Result, Len, Byte(Cardinal(Height) shr 16));
  AppendByte(Result, Len, Byte(Cardinal(Height) shr 8));
  AppendByte(Result, Len, Byte(Cardinal(Height)));
  AppendByte(Result, Len, 4);   // channels = RGBA
  AppendByte(Result, Len, 0);   // colorspace = sRGB

  for I := 0 to 63 do
  begin
    Index[I].R := 0; Index[I].G := 0; Index[I].B := 0; Index[I].A := 0;
  end;
  Prev.R := 0; Prev.G := 0; Prev.B := 0; Prev.A := 255;
  Run := 0;

  for Y := 0 to Height - 1 do
    for X := 0 to Width - 1 do
    begin
      Px := GetPx(InBuf, Width, X, Y);
      IsLast := (Y = Height - 1) and (X = Width - 1);

      if SamePixel(Px, Prev) then
      begin
        Inc(Run);
        if (Run = 62) or IsLast then
        begin
          AppendByte(Result, Len, QOI_OP_RUN or (Run - 1));
          Run := 0;
        end;
      end
      else
      begin
        if Run > 0 then
        begin
          AppendByte(Result, Len, QOI_OP_RUN or (Run - 1));
          Run := 0;
        end;

        IdxPos := Hash(Px);
        if SamePixel(Index[IdxPos], Px) then
          AppendByte(Result, Len, QOI_OP_INDEX or IdxPos)
        else
        begin
          Index[IdxPos] := Px;
          if Px.A = Prev.A then
          begin
            // signed-char (wraparound) diffs, matching the QOI spec
            vr := ShortInt(Byte(Px.R - Prev.R));
            vg := ShortInt(Byte(Px.G - Prev.G));
            vb := ShortInt(Byte(Px.B - Prev.B));
            drdg := ShortInt(Byte(vr - vg));
            dbdg := ShortInt(Byte(vb - vg));
            if (vr >= -2) and (vr <= 1) and (vg >= -2) and (vg <= 1) and
               (vb >= -2) and (vb <= 1) then
              AppendByte(Result, Len,
                QOI_OP_DIFF or ((vr + 2) shl 4) or ((vg + 2) shl 2) or (vb + 2))
            else if (vg >= -32) and (vg <= 31) and (drdg >= -8) and (drdg <= 7) and
                    (dbdg >= -8) and (dbdg <= 7) then
            begin
              AppendByte(Result, Len, QOI_OP_LUMA or (vg + 32));
              AppendByte(Result, Len, ((drdg + 8) shl 4) or (dbdg + 8));
            end
            else
            begin
              AppendByte(Result, Len, QOI_OP_RGB);
              AppendByte(Result, Len, Px.R);
              AppendByte(Result, Len, Px.G);
              AppendByte(Result, Len, Px.B);
            end;
          end
          else
          begin
            AppendByte(Result, Len, QOI_OP_RGBA);
            AppendByte(Result, Len, Px.R);
            AppendByte(Result, Len, Px.G);
            AppendByte(Result, Len, Px.B);
            AppendByte(Result, Len, Px.A);
          end;
        end;
      end;

      Prev := Px;
    end;

  // 8-byte end marker
  for I := 0 to 6 do AppendByte(Result, Len, 0);
  AppendByte(Result, Len, 1);

  SetLength(Result, Len);
end;

end.
