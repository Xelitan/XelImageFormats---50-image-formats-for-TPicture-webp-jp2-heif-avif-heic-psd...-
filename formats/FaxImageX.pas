unit FaxImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	GFI FAX TGraphic wrapper (VCL/LCL), multi-page                //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Copyright:	(c) 2026 Xelitan.com. All rights reserved.                    //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelFax, XelImageBase;

type
  TFaxImage = class(TXelGraphic)
  private
    FData: TBytes;
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
    procedure DecodeFromStream(Str: TStream); override;
  public
    // Number of fax pages in the loaded file.
    function PageCount: Integer;
    // Decode page Index (0-based) into a freshly created TBitmap (caller owns).
    function GetPage(Index: Integer): TBitmap;
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TFaxImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
  out AW, AH: Integer);
var Input: TBytes; Size: NativeInt;
begin
  ARGBA := nil; AW := 0; AH := 0;
  Size := Str.Size - Str.Position;
  if Size <= 0 then Exit;
  SetLength(Input, Size);
  Str.ReadBuffer(Input[0], Size);
  ARGBA := DecodeFax(Input, AW, AH);
end;

procedure TFaxImage.DecodeFromStream(Str: TStream);
var Pixels: TBytes; W, H: Integer; Size: NativeInt;
begin
  Size := Str.Size - Str.Position;
  SetLength(FData, 0);
  if Size <= 0 then Exit;
  SetLength(FData, Size);
  Str.ReadBuffer(FData[0], Size);
  Pixels := DecodeFax(FData, W, H);
  ReadRGBA(Pixels, W, H);
end;

function TFaxImage.PageCount: Integer;
begin
  if Length(FData) = 0 then Result := 0 else Result := FaxPageCount(FData);
end;

function TFaxImage.GetPage(Index: Integer): TBitmap;
var Pixels: TBytes; W, H: Integer;
begin
  Result := nil;
  if Length(FData) = 0 then Exit;
  Pixels := DecodeFaxPage(FData, Index, W, H);
  if (W <= 0) or (H <= 0) or (NativeInt(Length(Pixels)) < NativeInt(W) * NativeInt(H) * 4) then Exit;
  Result := TBitmap.Create;
  try RGBAToBitmap(Pixels, W, H, Result); except Result.Free; raise; end;
end;

procedure TFaxImage.SaveToStream(Stream: TStream);
begin
  raise EFaxError.Create('FAX encoding is not supported');
end;

initialization
  TPicture.RegisterFileFormat('fax', 'GFI Fax Image', TFaxImage);
  TPicture.RegisterFileFormat('g3', 'Group 3 Fax Image', TFaxImage);

finalization
  TPicture.UnregisterGraphicClass(TFaxImage);

end.
