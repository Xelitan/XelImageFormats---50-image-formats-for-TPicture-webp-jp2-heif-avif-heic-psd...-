unit PspImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Paint Shop Pro TGraphic wrapper (VCL/LCL), read-only          //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelPsp, XelImageBase;

  // TPspImage - only the format-specific bits; the rest is in TXelGraphic.
type
  TPspImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TPspImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodePsp(Input, AW, AH);   // pure-Pascal decode -> RGBA8
end;

procedure TPspImage.SaveToStream(Stream: TStream);
begin
  raise EPspError.Create('PSP: writing is not supported');
end;

initialization
  TPicture.RegisterFileFormat('psp','Paint Shop Pro Image', TPspImage);
  TPicture.RegisterFileFormat('pspimage','Paint Shop Pro Image', TPspImage);
  TPicture.RegisterFileFormat('tub','Paint Shop Pro Picture Tube', TPspImage);
  TPicture.RegisterFileFormat('psptube','Paint Shop Pro Picture Tube', TPspImage);
  TPicture.RegisterFileFormat('pfr','Paint Shop Pro Frame', TPspImage);
  TPicture.RegisterFileFormat('pspframe','Paint Shop Pro Frame', TPspImage);

finalization
  TPicture.UnregisterGraphicClass(TPspImage);

end.
