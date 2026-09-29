unit CalsImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	CALS Type 1 TGraphic wrapper (VCL/LCL), read-only            //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelCals, XelImageBase;

  // TCalsImage - decode only; there is no Group 4 encoder in this library.
type
  TCalsImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TCalsImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeCals(Input, AW, AH);   // pure-Pascal decode (via TIFF G4) -> RGBA8
end;

procedure TCalsImage.SaveToStream(Stream: TStream);
begin
  raise ECalsError.Create('CALS: writing is not supported (no Group 4 encoder)');
end;

initialization
  TPicture.RegisterFileFormat('cal','CALS Image', TCalsImage);
  TPicture.RegisterFileFormat('cals','CALS Image', TCalsImage);
  TPicture.RegisterFileFormat('mil','CALS Image', TCalsImage);

finalization
  TPicture.UnregisterGraphicClass(TCalsImage);

end.
