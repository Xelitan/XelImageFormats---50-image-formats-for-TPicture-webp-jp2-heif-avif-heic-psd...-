unit IcoImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	ICO TGraphic wrapper (VCL/LCL), multi-image                   //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Copyright:	(c) 2026 Xelitan.com. All rights reserved.                    //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelIco, XelImageBase;

  // TIcoImage - keeps the raw file so any icon size can be read.
type
  TIcoImage = class(TXelGraphic)
  private
    FData: TBytes;
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
    procedure DecodeFromStream(Str: TStream); override;
  public
    // Number of icon images stored in the file.
    function ImageCount: Integer;
    // Decode image Index (0-based) into a freshly created TBitmap (caller owns).
    function GetImage(Index: Integer): TBitmap;
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TIcoImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
  out AW, AH: Integer);
var Input: TBytes; Size: NativeInt;
begin
  ARGBA := nil; AW := 0; AH := 0;
  Size := Str.Size - Str.Position;
  if Size <= 0 then Exit;
  SetLength(Input, Size);
  Str.ReadBuffer(Input[0], Size);
  ARGBA := DecodeIco(Input, AW, AH);   // largest image
end;

procedure TIcoImage.DecodeFromStream(Str: TStream);
var Pixels: TBytes; W, H: Integer; Size: NativeInt;
begin
  Size := Str.Size - Str.Position;
  SetLength(FData, 0);
  if Size <= 0 then Exit;
  SetLength(FData, Size);
  Str.ReadBuffer(FData[0], Size);
  Pixels := DecodeIco(FData, W, H);
  ReadRGBA(Pixels, W, H);
end;

function TIcoImage.ImageCount: Integer;
begin
  if Length(FData) = 0 then Result := 0 else Result := IcoImageCount(FData);
end;

function TIcoImage.GetImage(Index: Integer): TBitmap;
var Pixels: TBytes; W, H: Integer;
begin
  Result := nil;
  if Length(FData) = 0 then Exit;
  Pixels := DecodeIcoImage(FData, Index, W, H);
  if (W <= 0) or (H <= 0) or (NativeInt(Length(Pixels)) < NativeInt(W) * NativeInt(H) * 4) then Exit;
  Result := TBitmap.Create;
  try RGBAToBitmap(Pixels, W, H, Result); except Result.Free; raise; end;
end;

procedure TIcoImage.SaveToStream(Stream: TStream);
begin
  raise EIcoError.Create('ICO encoding is not supported');
end;

initialization
  TPicture.RegisterFileFormat('ico', 'ICO Image', TIcoImage);

finalization
  TPicture.UnregisterGraphicClass(TIcoImage);

end.
