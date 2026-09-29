unit XelJxl;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	JPEG XL codec -> RGBA8 (wraps jxlimage / jxl_encoder here)     //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, jxl_encoder, jxlimage;

type
  EJxlError = class(Exception);

// Decodes a JPEG XL file (codestream or container) to RGBA8.
function DecodeJxl(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8

// Encodes RGBA8 to JPEG XL (modular; alpha is kept).
//   IsLossless : True = exact.
//   Quality    : 1..100 (higher = better; 97..100 is lossless).
function EncodeJxl(InBuf: TBytes; Width, Height: Integer;                 // InBuf = RGBA8
                   IsLossless: Boolean = False; Quality: Integer = 75): TBytes;

implementation

function DecodeJxl(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Dec: TJxlDecoder;
begin
  Result := nil;
  Width := 0;
  Height := 0;
  if Length(InBuf) = 0 then
    raise EJxlError.Create('JXL: empty stream');
  Dec := TJxlDecoder.Create;
  try
    Dec.LoadFromMemory(@InBuf[0], Length(InBuf));
    Result := Dec.GetRGBA8;                // straight RGBA8
    if (Dec.Width <= 0) or (Dec.Height <= 0) or
       (NativeInt(Length(Result)) < NativeInt(Dec.Width) * NativeInt(Dec.Height) * 4) then
    begin
      Result := nil;
      raise EJxlError.Create('JXL decode failed');
    end;
    Width := Dec.Width;
    Height := Dec.Height;
  finally
    Dec.Free;
  end;
end;

function EncodeJxl(InBuf: TBytes; Width, Height: Integer;
                   IsLossless: Boolean = False; Quality: Integer = 75): TBytes;
var
  Q, Step: Integer;
begin
  if (Width <= 0) or (Height <= 0) or
     (NativeUInt(Width) * NativeUInt(Height) > NativeUInt(MaxInt div 4)) or
     (NativeInt(Length(InBuf)) < NativeInt(Width) * NativeInt(Height) * 4) then
    raise EJxlError.Create('JXL encode: empty image');

  // JxlEncodeRGBA8 takes the modular quantiser step (1 = lossless), not a
  // quality. Odd steps only: steps of 2 mod 4 compress worse than their
  // neighbours. On a photo: 3 ~47 dB, 5 ~43 dB, 7 ~40 dB (quality 75),
  // 13 ~35 dB, 25 ~30 dB.
  if IsLossless then
    Step := 1
  else
  begin
    Q := Quality;
    if Q < 1 then Q := 1
    else if Q > 100 then Q := 100;
    Step := 2 * ((100 - Q + 4) div 8) + 1;   // 97..100 -> 1, 89..96 -> 3, ...
  end;

  Result := JxlEncodeRGBA8(InBuf, Width, Height, Step);
  if Length(Result) = 0 then
    raise EJxlError.Create('JXL encode failed');
end;

end.
