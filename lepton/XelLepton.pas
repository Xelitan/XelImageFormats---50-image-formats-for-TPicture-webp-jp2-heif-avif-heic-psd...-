unit XelLepton;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Lepton (.lep, recompressed JPEG) codec -> RGBA8                //
// Version:	0.2                                                           //
// Date:	27-SEP-2026                                                   //
// License:     Apache-2.0                                                    //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// A .lep file is a JPEG squeezed losslessly by the Lepton port in this folder.
// LeptonToJpeg / JpegToLepton convert between the two without touching the
// pixels. DecodeLepton / EncodeLepton go on to pixels through XelJpeg (pure
// Pascal, no widgetset, safe in threads).

interface

uses
  SysUtils, Classes, LeptonFeatures, LeptonFile, XelJpeg;

type
  ELeptonError = class(Exception);

// .lep -> the original JPEG file, byte for byte.
function LeptonToJpeg(InBuf: TBytes): TBytes;

// JPEG file -> .lep (lossless; the JPEG can be restored exactly).
function JpegToLepton(InBuf: TBytes): TBytes;

// Decodes a .lep file to RGBA8.
function DecodeLepton(InBuf: TBytes; out Width, Height: Integer): TBytes; // RGBA8

// Decodes a .lep file to RGBA8 reduced (box average) by the largest factor
// of 2, 4 or 8 that still covers MaxW x MaxH - for thumbnails. The result is
// ceil(W / factor) x ceil(H / factor); MaxW or MaxH <= 0 = full size.
function DecodeLeptonScaled(InBuf: TBytes; MaxW, MaxH: Integer;
                            out Width, Height: Integer): TBytes;          // RGBA8

// Encodes RGBA8 as a JPEG of the given quality (1..100) and packs it as .lep.
function EncodeLepton(InBuf: TBytes; Width, Height: Integer;              // InBuf = RGBA8
                      Quality: Integer = 75): TBytes;

implementation

function StreamBytes(S: TMemoryStream): TBytes;
begin
  SetLength(Result, S.Size);
  if S.Size > 0 then Move(S.Memory^, Result[0], S.Size);
end;

function LeptonToJpeg(InBuf: TBytes): TBytes;
var
  Src, Jpg: TMemoryStream;
begin
  if Length(InBuf) = 0 then
    raise ELeptonError.Create('Lepton: empty stream');
  Src := TMemoryStream.Create;
  Jpg := TMemoryStream.Create;
  try
    Src.WriteBuffer(InBuf[0], Length(InBuf));
    Src.Position := 0;
    try
      LeptonFile.DecodeLepton(Src, Jpg, TEnabledFeatures.CompatLeptonVectorRead);
    except
      on E: Exception do
        raise ELeptonError.Create('Lepton decode failed: ' + E.Message);
    end;
    if Jpg.Size <= 0 then
      raise ELeptonError.Create('Lepton decode produced empty JPEG');
    Result := StreamBytes(Jpg);
  finally
    Jpg.Free;
    Src.Free;
  end;
end;

function JpegToLepton(InBuf: TBytes): TBytes;
var
  Jpg, Dst: TMemoryStream;
begin
  if Length(InBuf) = 0 then
    raise ELeptonError.Create('Lepton encode: empty JPEG');
  Jpg := TMemoryStream.Create;
  Dst := TMemoryStream.Create;
  try
    Jpg.WriteBuffer(InBuf[0], Length(InBuf));
    Jpg.Position := 0;
    try
      LeptonFile.EncodeLepton(Jpg, Dst, TEnabledFeatures.CompatLeptonVectorWrite);
    except
      on E: Exception do
        raise ELeptonError.Create('Lepton encode failed: ' + E.Message);
    end;
    Result := StreamBytes(Dst);
  finally
    Dst.Free;
    Jpg.Free;
  end;
end;

function DecodeLepton(InBuf: TBytes; out Width, Height: Integer): TBytes;
begin
  Result := XelJpeg.DecodeJpeg(LeptonToJpeg(InBuf), Width, Height);
  if (Width <= 0) or (Height <= 0) then
    raise ELeptonError.Create('Lepton: embedded JPEG has no pixels');
end;

function DecodeLeptonScaled(InBuf: TBytes; MaxW, MaxH: Integer;
                            out Width, Height: Integer): TBytes;
var
  Full: TBytes;
  W, H, x, y, sx, sy, c, n, Factor: Integer;
  Sum: array[0..3] of Integer;
  P: NativeInt;
  ratio: Double;
begin
  Full := DecodeLepton(InBuf, W, H);
  Factor := 1;
  if (MaxW > 0) and (MaxH > 0) then
  begin
    ratio := W / MaxW;
    if H / MaxH > ratio then ratio := H / MaxH;
    if ratio >= 8 then Factor := 8
    else if ratio >= 4 then Factor := 4
    else if ratio >= 2 then Factor := 2;
  end;
  if Factor <= 1 then
  begin
    Width := W; Height := H;
    Exit(Full);
  end;
  Width := (W + Factor - 1) div Factor;
  Height := (H + Factor - 1) div Factor;
  SetLength(Result, NativeInt(Width) * NativeInt(Height) * 4);
  P := 0;
  for y := 0 to Height - 1 do
    for x := 0 to Width - 1 do
    begin
      FillChar(Sum, SizeOf(Sum), 0);
      n := 0;
      for sy := y * Factor to y * Factor + Factor - 1 do
        if sy < H then
          for sx := x * Factor to x * Factor + Factor - 1 do
            if sx < W then
            begin
              for c := 0 to 3 do
                Inc(Sum[c], Full[(NativeInt(sy) * W + sx) * 4 + c]);
              Inc(n);
            end;
      for c := 0 to 3 do
        Result[P + c] := (Sum[c] + n div 2) div n;
      Inc(P, 4);
    end;
end;

function EncodeLepton(InBuf: TBytes; Width, Height: Integer;
                      Quality: Integer = 75): TBytes;
var
  q: Integer;
begin
  if (Width <= 0) or (Height <= 0) or
     (NativeInt(Length(InBuf)) < NativeInt(Width) * NativeInt(Height) * 4) then
    raise ELeptonError.Create('Lepton encode: empty image');
  q := Quality;
  if q < 1 then q := 1
  else if q > 100 then q := 100;
  Result := JpegToLepton(XelJpeg.EncodeJpeg(InBuf, Width, Height, q));
end;

end.
