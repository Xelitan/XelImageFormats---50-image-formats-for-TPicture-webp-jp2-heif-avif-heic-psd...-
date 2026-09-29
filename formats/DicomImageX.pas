unit DicomImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	DICOM TGraphic wrapper (VCL/LCL), read-only                  //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelDicom, XelImageBase;

  // TDicomImage - decode only (first frame).
type
  TDicomImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TDicomImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeDicom(Input, AW, AH);   // pure-Pascal decode -> RGBA8
end;

procedure TDicomImage.SaveToStream(Stream: TStream);
begin
  raise EDicomError.Create('DICOM: writing is not supported');
end;

initialization
  TPicture.RegisterFileFormat('dcm','DICOM Image', TDicomImage);
  TPicture.RegisterFileFormat('dicom','DICOM Image', TDicomImage);

finalization
  TPicture.UnregisterGraphicClass(TDicomImage);

end.
