unit XelPcd;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Kodak Photo CD (PCD) decoder -> RGBA8                         //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Decodes the three uncompressed resolutions stored in every image pack:      //
//   level 0 = Base/16 (192x128) at sector 4                                   //
//   level 1 = Base/4  (384x256) at sector 23                                  //
//   level 2 = Base    (768x512) at sector 96                                  //
// Data per two rows: Y row, Y row, C1 row (half width), C2 row (half width). //
// 4Base/16Base need Kodak's Huffman residuals and are not decoded.            //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelPng;

type
  EPcdError = class(Exception);

// Dekoduje obraz Base (768x512, z uwzglednieniem orientacji).
function DecodePcd(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8
// Dekoduje wybrana rozdzielczosc: 0 = Base/16, 1 = Base/4, 2 = Base.
function DecodePcdLevel(InBuf: TBytes; Level: Integer; out Width, Height: Integer): TBytes;

implementation

const
  SECTOR = $800;

function ClampB(V: Double): Byte; inline;
begin
  if V <= 0 then Result := 0
  else if V >= 255 then Result := 255
  else Result := Byte(Round(V));
end;

// 2x bilinear upsampling of a (CW x CH) chroma plane to (2CW x 2CH).
function Upsample(const Src: TBytes; CW, CH: Integer): TBytes;
var
  x, y, sx, sy, sx1, sy1, W: Integer;
  a, b, c, d: Integer;
begin
  W := CW * 2;
  SetLength(Result, W * CH * 2);
  for y := 0 to CH * 2 - 1 do
  begin
    sy := y shr 1; sy1 := sy + (y and 1); if sy1 >= CH then sy1 := CH - 1;
    for x := 0 to W - 1 do
    begin
      sx := x shr 1; sx1 := sx + (x and 1); if sx1 >= CW then sx1 := CW - 1;
      a := Src[sy * CW + sx];  b := Src[sy * CW + sx1];
      c := Src[sy1 * CW + sx]; d := Src[sy1 * CW + sx1];
      Result[y * W + x] := Byte((a + b + c + d + 2) shr 2);
    end;
  end;
end;

function DecodePcdLevel(InBuf: TBytes; Level: Integer; out Width, Height: Integer): TBytes;
var
  N, Off: NativeUInt;
  W, H, CW, CH, pair, x, y, OW, OH, ox, oy, Rot: Integer;
  Yp, C1, C2, C1u, C2u: TBytes;
  yy, c1f, c2f: Double;
  C: TRGBA;
  SecNo: Integer;
begin
  Width := 0; Height := 0; SetLength(Result, 0);
  N := NativeUInt(Length(InBuf));
  if N < 3 * SECTOR then raise EPcdError.Create('PCD: file too small');
  if (InBuf[0] = Ord('P')) and (InBuf[1] = Ord('C')) and (InBuf[2] = Ord('D')) and
     (InBuf[3] = Ord('_')) and (InBuf[4] = Ord('O')) then
    raise EPcdError.Create('PCD: overview (PCD_OPA) files are not supported');
  if not ((InBuf[SECTOR] = Ord('P')) and (InBuf[SECTOR + 1] = Ord('C')) and (InBuf[SECTOR + 2] = Ord('D'))) then
    raise EPcdError.Create('PCD: not a Photo CD image pack');

  if Level < 0 then Level := 0;
  if Level > 2 then Level := 2;
  case Level of
    0: SecNo := 4;
    1: SecNo := 23;
  else SecNo := 96;
  end;
  W := 192 shl Level;
  H := 128 shl Level;
  CW := W div 2; CH := H div 2;

  Off := NativeUInt(SecNo) * SECTOR;
  if Off + NativeUInt(W) * NativeUInt(H) * 3 div 2 > N then
    raise EPcdError.Create('PCD: truncated image data');

  SetLength(Yp, W * H);
  SetLength(C1, CW * CH);
  SetLength(C2, CW * CH);
  for pair := 0 to CH - 1 do
  begin
    Move(InBuf[Off], Yp[(pair * 2) * W], W);      Inc(Off, W);
    Move(InBuf[Off], Yp[(pair * 2 + 1) * W], W);  Inc(Off, W);
    Move(InBuf[Off], C1[pair * CW], CW);          Inc(Off, CW);
    Move(InBuf[Off], C2[pair * CW], CW);          Inc(Off, CW);
  end;
  C1u := Upsample(C1, CW, CH);
  C2u := Upsample(C2, CW, CH);

  // orientation: 0 = none, 1 = 90 CCW, 2 = 180, 3 = 90 CW
  Rot := InBuf[$0E02] and 3;
  if (Rot = 1) or (Rot = 3) then begin OW := H; OH := W; end
  else begin OW := W; OH := H; end;

  Width := OW; Height := OH;
  SetLength(Result, NativeInt(OW) * OH * 4);
  C.A := 255;
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      // Kodak PhotoYCC -> RGB. PhotoYCC keeps highlights above reference white
      // (luma up to ~1.36x), so instead of applying the 1.3584 luma gain and
      // clipping, the whole transform is normalised by 1/1.3584: the full coded
      // range maps onto 0..255 and highlight detail is preserved.
      yy  := Yp[y * W + x];
      c1f := Integer(C1u[y * W + x]) - 156;
      c2f := Integer(C2u[y * W + x]) - 137;
      C.R := ClampB(yy + 1.3409 * c2f);
      C.G := ClampB(yy - 0.3168 * c1f - 0.6825 * c2f);
      C.B := ClampB(yy + 1.6327 * c1f);
      case Rot of
        1: begin ox := y;         oy := W - 1 - x; end;   // 90 CCW
        2: begin ox := W - 1 - x; oy := H - 1 - y; end;   // 180
        3: begin ox := H - 1 - y; oy := x;         end;   // 90 CW
      else
        begin ox := x; oy := y; end;
      end;
      SetPx(Result, OW, ox, oy, C);
    end;
end;

function DecodePcd(InBuf: TBytes; out Width, Height: Integer): TBytes;
begin
  Result := DecodePcdLevel(InBuf, 2, Width, Height);
end;

end.
