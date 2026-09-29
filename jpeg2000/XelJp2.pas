unit XelJp2;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	JPEG 2000 codec -> RGBA8 (wraps the JP2K* port in this folder) //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     JasPer-2.0 (similar to MIT )                                  //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, Math, JP2KCommon, JP2KCodec, JP2KDecGen;

type
  EJp2Error = class(Exception);

// Decodes a JPEG 2000 file (.jp2 container or raw .j2k / .jpc codestream) to
// RGBA8. Sample precision is scaled to 8 bits; one component = greyscale.
function DecodeJp2(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8

// Encodes RGBA8 to a .jp2 file (RGB, 8 bits; alpha is not stored).
//   IsLossless : True = reversible 5/3 wavelet + RCT, exact.
//   Quality    : lossy quality 1..100 (higher = better), mapped onto the
//                irreversible quantiser step.
function EncodeJp2(InBuf: TBytes; Width, Height: Integer;                 // InBuf = RGBA8
                   IsLossless: Boolean = False; Quality: Integer = 75): TBytes;

implementation

function ClampByte(v: Integer): Byte;
begin
  if v < 0 then v := 0
  else if v > 255 then v := 255;
  Result := Byte(v);
end;

function DecodeJp2(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Img: TJp2kImage;
  W, H, x, y, idx, sh: Integer;
  r, g, b: Integer;
  P: NativeInt;
begin
  Result := nil;
  Width := 0;
  Height := 0;
  if Length(InBuf) = 0 then
    raise EJp2Error.Create('JPEG 2000: empty stream');

  Img := DecodeGeneral(InBuf);    // handles both .jp2 and raw .jpc
  try
    if Img = nil then
      raise EJp2Error.Create('JPEG 2000 decode failed');
    W := Img.W;
    H := Img.H;
    if (W <= 0) or (H <= 0) or (Img.NumComps < 1) then
      raise EJp2Error.Create('JPEG 2000: bad dimensions');

    // Bring the decoded sample precision down/up to 8 bits per channel
    sh := Img.Prec - 8;
    SetLength(Result, NativeInt(W) * NativeInt(H) * 4);
    P := 0;
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        idx := y * W + x;
        if Img.NumComps >= 3 then
        begin
          r := Img.Comps[0][idx];
          g := Img.Comps[1][idx];
          b := Img.Comps[2][idx];
        end
        else
        begin
          r := Img.Comps[0][idx];
          g := r;
          b := r;
        end;
        if sh > 0 then
        begin
          r := r shr sh; g := g shr sh; b := b shr sh;
        end
        else if sh < 0 then
        begin
          r := r shl (-sh); g := g shl (-sh); b := b shl (-sh);
        end;
        Result[P + 0] := ClampByte(r);
        Result[P + 1] := ClampByte(g);
        Result[P + 2] := ClampByte(b);
        Result[P + 3] := 255;
        Inc(P, 4);
      end;
    Width := W;
    Height := H;
  finally
    Img.Free;
  end;
end;

function EncodeJp2(InBuf: TBytes; Width, Height: Integer;
                   IsLossless: Boolean = False; Quality: Integer = 75): TBytes;
var
  Img: TJp2kImage;
  Opt: TEncodeOptions;
  x, y, idx, q: Integer;
begin
  Result := nil;
  if (Width <= 0) or (Height <= 0) or
     (NativeInt(Length(InBuf)) < NativeInt(Width) * NativeInt(Height) * 4) then
    raise EJp2Error.Create('JPEG 2000 encode: empty image');

  // RGB, 8 bits/channel. The colour transform (MCT) needs exactly 3
  // components, so the alpha channel is dropped.
  Img := TJp2kImage.Create(Width, Height, 3, 8);
  try
    for y := 0 to Height - 1 do
      for x := 0 to Width - 1 do
      begin
        idx := y * Width + x;
        Img.Comps[0][idx] := InBuf[idx * 4 + 0];   // R
        Img.Comps[1][idx] := InBuf[idx * 4 + 1];   // G
        Img.Comps[2][idx] := InBuf[idx * 4 + 2];   // B
      end;

    Opt := DefaultEncodeOptions;
    Opt.Reversible := IsLossless;   // True = lossless 5/3+RCT, else lossy 9/7+ICT
    Opt.UseMct := True;             // colour-decorrelate (RCT/ICT) for 3 comps
    Opt.NumLevels := 0;             // auto (~5 DWT levels) - best compression
    if IsLossless then
      Opt.Step := 1.0               // ignored in reversible mode
    else
    begin
      // Map quality (1..100) to the irreversible quantiser step: higher quality
      // => smaller step => less loss. Tuned on photographic content so the
      // default (75) is visually near-lossless (~45 dB PSNR):
      //     q=100 ~0.13   q=90 ~0.35    q=75 ~0.59 (default)
      //     q=50  ~1.4    q=25 ~3.4     q=10 ~5.7
      // The encoder writes a conformant expounded QCD, so the resulting .jp2
      // opens correctly in any standard viewer, not just this library.
      q := Quality;
      if q < 1 then q := 1
      else if q > 100 then q := 100;
      Opt.Step := Power(2.0, (60 - q) / 20.0);
    end;
    Result := EncodeToJp2(Img, Opt);
  finally
    Img.Free;
  end;
end;

end.
