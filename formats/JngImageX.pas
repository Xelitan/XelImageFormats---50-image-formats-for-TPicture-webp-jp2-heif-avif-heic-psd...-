unit JngImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	JNG TGraphic wrapper (VCL/LCL)                              //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelJng, XelImageBase;

  // TJngImage - only the format-specific bits; the rest is in TXelGraphic.
type
  TJngImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    // Encode the internal bitmap to JNG and write it to Str.
    // Jng is decode-only.
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TJngImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeJng(Input, AW, AH);   // pure-Pascal decode -> RGBA8
end;



procedure TJngImage.SaveToStream(Stream: TStream);
begin
  raise Exception.Create('JNG encoding is not supported');
end;

initialization
  TPicture.RegisterFileFormat('jng','JNG Image', TJngImage);

finalization
  TPicture.UnregisterGraphicClass(TJngImage);

end.
