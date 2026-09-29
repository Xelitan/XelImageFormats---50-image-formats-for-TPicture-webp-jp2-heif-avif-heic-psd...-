unit FLIFImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	FLIF TGraphic wrapper (VCL/LCL)                               //
// Version:	0.2                                                           //
// Date:	27-SEP-2026                                                   //
// License:     Apache 2/LGPL                                                 //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelFlif, XelImageBase;

  // TFLIFImage - only the format-specific bits; the rest is in TXelGraphic.
type
  TFLIFImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    // Encode the internal bitmap to FLIF and write it to Str.
    //   IsLossless       : True = exact.
    //   CompressionLevel : lossy quality 0..100 (higher = better quality).
    procedure EncodeToStream(Str: TStream; IsLossless: Boolean = True;
                             CompressionLevel: Integer = 75);
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TFLIFImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeFlif(Input, AW, AH);   // pure-Pascal decode -> RGBA8
end;

procedure TFLIFImage.EncodeToStream(Str: TStream; IsLossless: Boolean = True;
                                    CompressionLevel: Integer = 75);
var
  W, H : Integer;
  RGBA : TBytes;
  Data : TBytes;
begin
  WriteRGBA(RGBA, W, H);   // gather FBmp -> RGBA8 (shared, in TXelGraphic)
  if (W <= 0) or (H <= 0) then Exit;

  Data := EncodeFlif(RGBA, W, H, IsLossless, CompressionLevel);
  if Length(Data) > 0 then
    Str.WriteBuffer(Data[0], Length(Data));
end;

procedure TFLIFImage.SaveToStream(Stream: TStream);
begin
  // Default: lossless. Use EncodeToStream for explicit control.
  EncodeToStream(Stream, True, 75);
end;

initialization
  TPicture.RegisterFileFormat('FLIF','FLIF Image', TFLIFImage);

finalization
  TPicture.UnregisterGraphicClass(TFLIFImage);

end.
