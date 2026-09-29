unit JpegImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	JPEG TGraphic wrapper (VCL/LCL)                              //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelJpeg, XelImageBase;

  // TJpegImage - only the format-specific bits; the rest is in TXelGraphic.
type
  TJpegImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    // Encode the internal bitmap to JPEG and write it to Str.
    procedure EncodeToStream(Str: TStream; Quality: Integer = 90);
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TJpegImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeJpeg(Input, AW, AH);   // pure-Pascal decode -> RGBA8
end;

procedure TJpegImage.EncodeToStream(Str: TStream; Quality: Integer = 90);
var
  W, H : Integer;
  RGBA : TBytes;
  Data : TBytes;
begin
  WriteRGBA(RGBA, W, H);   // gather FBmp -> RGBA8 (shared, in TXelGraphic)
  if (W <= 0) or (H <= 0) then Exit;

  Data := EncodeJpeg(RGBA, W, H, Quality);
  if Length(Data) > 0 then
    Str.WriteBuffer(Data[0], Length(Data));
end;

procedure TJpegImage.SaveToStream(Stream: TStream);
begin
  // Default: quality 90. Use EncodeToStream for explicit control.
  EncodeToStream(Stream, 90);
end;

initialization
  TPicture.RegisterFileFormat('jpg','JPEG Image', TJpegImage);

finalization
  TPicture.UnregisterGraphicClass(TJpegImage);

end.
