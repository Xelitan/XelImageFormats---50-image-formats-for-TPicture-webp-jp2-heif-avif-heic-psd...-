unit JxrImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	JPEG XR / HD Photo TGraphic wrapper (VCL/LCL), read-only     //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// Registers .jxr/.wdp/.hdp (JPEG XR, formerly HD Photo / Windows Media Photo)
// and decodes them through XelJxr (a Free Pascal port of jxrlib).

interface

uses Classes, Graphics, SysUtils, XelJxr, XelImageBase;

type
  TJxrImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TJxrImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeJxr(Input, AW, AH);
end;

procedure TJxrImage.SaveToStream(Stream: TStream);
begin
  raise EJxrError.Create('JXR: writing is not supported');
end;

initialization
  TPicture.RegisterFileFormat('jxr','JPEG XR Image', TJxrImage);
  TPicture.RegisterFileFormat('wdp','HD Photo / JPEG XR', TJxrImage);
  TPicture.RegisterFileFormat('hdp','HD Photo / JPEG XR', TJxrImage);

finalization
  TPicture.UnregisterGraphicClass(TJxrImage);

end.
