unit SgiImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	SGI TGraphic wrapper (VCL/LCL)                              //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelSgi, XelImageBase;

  // TSgiImage - only the format-specific bits; the rest is in TXelGraphic.
type
  TSgiImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    // Encode the internal bitmap to SGI and write it to Str.
    procedure EncodeToStream(Str: TStream);
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TSgiImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeSgi(Input, AW, AH);   // pure-Pascal decode -> RGBA8
end;

procedure TSgiImage.EncodeToStream(Str: TStream);
var
  W, H : Integer;
  RGBA : TBytes;
  Data : TBytes;
begin
  WriteRGBA(RGBA, W, H);   // gather FBmp -> RGBA8 (shared, in TXelGraphic)
  if (W <= 0) or (H <= 0) then Exit;

  Data := EncodeSgi(RGBA, W, H);
  if Length(Data) > 0 then
    Str.WriteBuffer(Data[0], Length(Data));
end;

procedure TSgiImage.SaveToStream(Stream: TStream);
begin
  EncodeToStream(Stream);
end;

initialization
  TPicture.RegisterFileFormat('sgi','SGI Image', TSgiImage);
  TPicture.RegisterFileFormat('rgb','SGI Image', TSgiImage);
  TPicture.RegisterFileFormat('rgba','SGI Image', TSgiImage);
  TPicture.RegisterFileFormat('bw','SGI Image', TSgiImage);

finalization
  TPicture.UnregisterGraphicClass(TSgiImage);

end.
