unit XelJbig2;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	JBIG2 decoder -> RGBA8 (wraps PdfJbig2 in this folder)         //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     Apache-2.0                                                    //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, PdfJbig2;

type
  EJbig2Error = class(Exception);

// Decodes a JBIG2 image to RGBA8 (black / white as opaque grey levels).
function DecodeJbig2(InBuf: TBytes; out Width, Height: Integer): TBytes;  // RGBA8

// The same, with the /JBIG2Globals stream of a PDF (may be empty).
function DecodeJbig2Globals(InBuf, Globals: TBytes; out Width, Height: Integer): TBytes;  // RGBA8

// Decodes to 8-bit grayscale, 1 byte per pixel, row-major, 0 = black and
// 255 = white (the form a PDF renderer's DeviceGray path takes). Globals may
// be empty. False when the data cannot be decoded.
function DecodeJBig2ToGray(const Data, Globals: TBytes; out W, H: Integer;
  out Gray: TBytes): Boolean;

implementation

function DecodeJBig2ToGray(const Data, Globals: TBytes; out W, H: Integer;
  out Gray: TBytes): Boolean;
begin
  Result := PdfJbig2.DecodeJBIG2(Data, Globals, W, H, Gray);
end;

function DecodeJbig2Globals(InBuf, Globals: TBytes; out Width, Height: Integer): TBytes;
var
  Gray: TBytes;
  W, H: Integer;
  I, N: NativeInt;
begin
  Result := nil;
  Width := 0;
  Height := 0;
  if Length(InBuf) = 0 then
    raise EJbig2Error.Create('JBIG2: empty stream');
  if not PdfJbig2.DecodeJBIG2(InBuf, Globals, W, H, Gray) or (W <= 0) or (H <= 0) then
    raise EJbig2Error.Create('JBIG2 decode failed');
  N := NativeInt(W) * NativeInt(H);
  if NativeInt(Length(Gray)) < N then
    raise EJbig2Error.Create('JBIG2: truncated image');

  SetLength(Result, N * 4);
  for I := 0 to N - 1 do
  begin
    Result[I * 4 + 0] := Gray[I];         // 0 = black, 255 = white
    Result[I * 4 + 1] := Gray[I];
    Result[I * 4 + 2] := Gray[I];
    Result[I * 4 + 3] := 255;
  end;
  Width := W;
  Height := H;
end;

function DecodeJbig2(InBuf: TBytes; out Width, Height: Integer): TBytes;
begin
  Result := DecodeJbig2Globals(InBuf, nil, Width, Height);
end;

end.
