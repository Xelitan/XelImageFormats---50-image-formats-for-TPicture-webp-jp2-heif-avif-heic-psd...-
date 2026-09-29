unit ExrImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	OpenEXR TGraphic wrapper (VCL/LCL), read-only                //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelExr, XelImageBase;

  // TExrImage - decode only (scanline NONE/ZIP/ZIPS).
type
  TExrImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TExrImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeExr(Input, AW, AH);   // pure-Pascal decode -> RGBA8
end;

procedure TExrImage.SaveToStream(Stream: TStream);
begin
  raise EExrError.Create('EXR: writing is not supported');
end;

initialization
  TPicture.RegisterFileFormat('exr','OpenEXR Image', TExrImage);

finalization
  TPicture.UnregisterGraphicClass(TExrImage);

end.
