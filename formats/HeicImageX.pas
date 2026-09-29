unit HeicImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	HEIC / HEIF / AVIF TGraphic wrapper (VCL/LCL)                 //
// Version:	0.2                                                           //
// Date:	27-SEP-2026                                                   //
// License:     LGPL                                                          //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelHeic, XelImageBase;

  // THeicImage - only the format-specific bits; the rest is in TXelGraphic.
type
  THeicImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    // Encode the internal bitmap to HEIC and write it to Str.
    //   IsLossless       : highest quality (the encoder has no lossless mode).
    //   CompressionLevel : quality 0..100 (higher = better quality).
    procedure EncodeToStream(Str: TStream; IsLossless: Boolean = False;
                             CompressionLevel: Integer = 75);
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure THeicImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
  out AW, AH: Integer);
var
  Input: TBytes;
  Size : NativeInt;
begin
  ARGBA := nil;
  AW := 0;
  AH := 0;
  Size := Str.Size - Str.Position;
  if Size <= 0 then Exit;
  SetLength(Input, Size);
  Str.ReadBuffer(Input[0], Size);
  ARGBA := DecodeHeic(Input, AW, AH);   // pure-Pascal decode -> RGBA8
end;

procedure THeicImage.EncodeToStream(Str: TStream; IsLossless: Boolean = False;
                                    CompressionLevel: Integer = 75);
var
  W, H : Integer;
  RGBA : TBytes;
  Data : TBytes;
begin
  WriteRGBA(RGBA, W, H);   // gather FBmp -> RGBA8 (shared, in TXelGraphic)
  if (W <= 0) or (H <= 0) then Exit;

  Data := EncodeHeic(RGBA, W, H, IsLossless, CompressionLevel);
  if Length(Data) > 0 then
    Str.WriteBuffer(Data[0], Length(Data));
end;

procedure THeicImage.SaveToStream(Stream: TStream);
begin
  // Default: lossy, quality 75. Use EncodeToStream for explicit control.
  EncodeToStream(Stream, False, 75);
end;

initialization
  TPicture.RegisterFileFormat('Heic','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('Heif','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('Heifs','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('Heics','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('Avci','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('Avcs','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('hif','Heic Image', THeicImage);
  TPicture.RegisterFileFormat('Avif','Heic Image', THeicImage);

finalization
  TPicture.UnregisterGraphicClass(THeicImage);

end.
