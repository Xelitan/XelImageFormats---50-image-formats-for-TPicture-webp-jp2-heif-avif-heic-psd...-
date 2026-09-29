unit PngImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	PNG TGraphic wrapper (VCL/LCL)                              //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelPng, XelImageBase;

  // TPngImage - only the format-specific bits; the rest is in TXelGraphic.
type
  TPngImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    // Encode the internal bitmap to PNG and write it to Str.
    procedure EncodeToStream(Str: TStream; Level: Integer = 6);
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TPngImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodePng(Input, AW, AH);   // pure-Pascal decode -> RGBA8
end;

procedure TPngImage.EncodeToStream(Str: TStream; Level: Integer = 6);
var
  W, H : Integer;
  RGBA : TBytes;
  Data : TBytes;
begin
  WriteRGBA(RGBA, W, H);   // gather FBmp -> RGBA8 (shared, in TXelGraphic)
  if (W <= 0) or (H <= 0) then Exit;

  Data := EncodePng(RGBA, W, H, Level);
  if Length(Data) > 0 then
    Str.WriteBuffer(Data[0], Length(Data));
end;

procedure TPngImage.SaveToStream(Stream: TStream);
begin
  // Default: zlib level 6. Use EncodeToStream for explicit control.
  EncodeToStream(Stream, 6);
end;

initialization
  TPicture.RegisterFileFormat('png','PNG Image', TPngImage);

finalization
  TPicture.UnregisterGraphicClass(TPngImage);

end.
