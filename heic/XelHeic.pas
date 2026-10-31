unit XelHeic;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	HEIC / HEIF / AVIF codec -> RGBA8 (wraps Heif.* in this folder)//
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     LGPL                                                          //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, Heif.Container, Heif.Decode, Heif.Encode;

type
  EHeicError = class(Exception);

// Decodes the primary image of a HEIC / HEIF / AVIF file to RGBA8 (colour
// matrix, range and rotation applied).
function DecodeHeic(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8

// Encodes RGBA8 to HEIC (HEVC, 4:2:0; alpha is not stored).
//   IsLossless : the encoder has no transform bypass, so this means the
//                highest quality (QP 0).
//   Quality    : 0..100 (higher = better).
function EncodeHeic(InBuf: TBytes; Width, Height: Integer;                // InBuf = RGBA8
                    IsLossless: Boolean = False; Quality: Integer = 75): TBytes;

implementation

uses AvifAnimated;

function DecodeHeic(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  C  : THeifContainer;
  Img: THeifImage;
  ok : Boolean;
  Frames: TAvifRGBAFrames;
  loop: Integer;
begin
  Result := nil;
  Width := 0;
  Height := 0;
  if Length(InBuf) = 0 then
    raise EHeicError.Create('HEIC: empty stream');
  C := THeifContainer.Create;
  try
    try
      C.LoadFromBytes(InBuf);
      ok := DecodeHeifPrimary(C, Img);
    except
      // an AVIF image sequence may carry no (usable) primary still item
      if not IsAvifSequence(InBuf) then raise;
      ok := False;
    end;
    if ok then
      // Packed RGBA8, top-down; colour matrix/range and rotation already applied.
      HeifImageToRGBA(Img, Result, Width, Height)
    else if IsAvifSequence(InBuf) then
    begin
      // first frame of the sequence
      Frames := DecodeAvifSequence(InBuf, 1, Width, Height, loop);
      Result := Frames[0].Pixels;
    end
    else
      raise EHeicError.Create('HEIC decode failed');
  finally
    C.Free;
  end;
  if (Width <= 0) or (Height <= 0) or
     (NativeInt(Length(Result)) < NativeInt(Width) * NativeInt(Height) * 4) then
    raise EHeicError.Create('HEIC decode produced no pixels');
end;

function EncodeHeic(InBuf: TBytes; Width, Height: Integer;
                    IsLossless: Boolean = False; Quality: Integer = 75): TBytes;
var
  RGB : TBytes;
  I, N: NativeInt;
  Q   : Integer;
begin
  Result := nil;
  N := NativeInt(Width) * NativeInt(Height);
  if (Width <= 0) or (Height <= 0) or (NativeInt(Length(InBuf)) < N * 4) then
    raise EHeicError.Create('HEIC encode: empty image');

  // The encoder takes packed RGB8.
  SetLength(RGB, N * 3);
  for I := 0 to N - 1 do
  begin
    RGB[I * 3 + 0] := InBuf[I * 4 + 0];
    RGB[I * 3 + 1] := InBuf[I * 4 + 1];
    RGB[I * 3 + 2] := InBuf[I * 4 + 2];
  end;

  // Quality 0..100 (higher = better). The current encoder path has no
  // transform bypass, so "lossless" maps to maximum quality (QP 0).
  if IsLossless then Q := 100 else Q := Quality;
  if Q < 0 then Q := 0 else if Q > 100 then Q := 100;
  // 4:2:0 chroma (the common HEIC case).
  Result := EncodeHeifFromRGB(RGB, Width, Height, Q, 1);
end;

end.
