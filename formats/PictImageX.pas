unit PictImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	PICT TGraphic wrapper (VCL/LCL)                              //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelPict, XelImageBase;

  // TPictImage - only the format-specific bits; the rest is in TXelGraphic.
type
  TPictImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    // Encode the internal bitmap to PICT and write it to Str.
    // Pict is decode-only.
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TPictImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodePict(Input, AW, AH);   // pure-Pascal decode -> RGBA8
end;



procedure TPictImage.SaveToStream(Stream: TStream);
begin
  raise Exception.Create('PICT encoding is not supported');
end;

initialization
  TPicture.RegisterFileFormat('pict','PICT Image', TPictImage);
  TPicture.RegisterFileFormat('pct','PICT Image', TPictImage);

finalization
  TPicture.UnregisterGraphicClass(TPictImage);

end.
