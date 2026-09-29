unit XpsImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	XPS / OpenXPS TGraphic wrapper (VCL/LCL), read-only          //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// Registers .xps/.oxps and shows the first page's rendered preview: the page
// thumbnail when present, otherwise the largest embedded page image (decoded
// with the project's JPEG/PNG/TIFF decoders). Full vector/glyph page rendering
// is not performed.

interface

uses Classes, Graphics, SysUtils, XelXps, XelImageBase;

type
  TXpsImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TXpsImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeXps(Input, AW, AH);
end;

procedure TXpsImage.SaveToStream(Stream: TStream);
begin
  raise EXpsError.Create('XPS: writing is not supported');
end;

initialization
  TPicture.RegisterFileFormat('xps','XPS Document', TXpsImage);
  TPicture.RegisterFileFormat('oxps','OpenXPS Document', TXpsImage);

finalization
  TPicture.UnregisterGraphicClass(TXpsImage);

end.
