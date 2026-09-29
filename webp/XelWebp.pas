unit XelWebp;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	WebP codec -> RGBA8 (wraps WebPDec / WebPEnc in this folder)   //
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
  SysUtils, Classes, WebPDec, WebPEnc;

type
  EWebpError = class(Exception);

// Decodes a WebP file (lossy VP8 or lossless VP8L, with alpha) to RGBA8.
function DecodeWebp(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8

// Encodes RGBA8 to WebP.
//   IsLossless : True = VP8L lossless (keeps alpha); False = VP8 lossy.
//   Quality    : lossy quality 0..100 (higher = better).
function EncodeWebp(InBuf: TBytes; Width, Height: Integer;                // InBuf = RGBA8
                    IsLossless: Boolean = False; Quality: Integer = 75): TBytes;

implementation

function DecodeWebp(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Pixels: PByte;
  W, H  : Integer;
begin
  Result := nil;
  Width := 0;
  Height := 0;
  if Length(InBuf) = 0 then
    raise EWebpError.Create('WebP: empty stream');
  Pixels := WebPDecodeRGBA(@InBuf[0], Length(InBuf), W, H);
  if Pixels = nil then
    raise EWebpError.Create('WebP decode failed');
  try
    if (W <= 0) or (H <= 0) then
      raise EWebpError.Create('WebP: bad dimensions');
    SetLength(Result, NativeInt(W) * NativeInt(H) * 4);
    Move(Pixels^, Result[0], Length(Result));
    Width := W;
    Height := H;
  finally
    FreeMem(Pixels);
  end;
end;

function EncodeWebp(InBuf: TBytes; Width, Height: Integer;
                    IsLossless: Boolean = False; Quality: Integer = 75): TBytes;
var
  q      : Integer;
  encData: PByte;
  encSize: Integer;
  ok     : Boolean;
begin
  Result := nil;
  if (Width <= 0) or (Height <= 0) or
     (NativeInt(Length(InBuf)) < NativeInt(Width) * NativeInt(Height) * 4) then
    raise EWebpError.Create('WebP encode: empty image');

  encData := nil;
  encSize := 0;
  if IsLossless then
    ok := WebPEncodeLosslessRGBA(@InBuf[0], Width, Height, Width * 4, encData, encSize)
  else
  begin
    q := Quality;
    if q < 0   then q := 0;
    if q > 100 then q := 100;
    ok := WebPEncodeRGBA(@InBuf[0], Width, Height, Width * 4, q, encData, encSize);
  end;
  if (not ok) or (encData = nil) or (encSize <= 0) then
  begin
    if encData <> nil then FreeMem(encData);
    raise EWebpError.Create('WebP encode failed');
  end;
  try
    SetLength(Result, encSize);
    Move(encData^, Result[0], encSize);
  finally
    FreeMem(encData);
  end;
end;

end.
