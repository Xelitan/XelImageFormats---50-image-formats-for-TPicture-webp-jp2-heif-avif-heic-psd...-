unit CurImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	CUR (cursor) TGraphic wrapper (VCL/LCL), multi-image          //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Copyright:	(c) 2026 Xelitan.com. All rights reserved.                    //
//                                                                            //
// CUR shares the ICO layout (type=2, entry planes/bits hold the hotspot).     //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelIco, XelImageBase;

  // TCurImage - Windows cursor; same container as ICO.
type
  TCurImage = class(TXelGraphic)
  private
    FData: TBytes;
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
    procedure DecodeFromStream(Str: TStream); override;
  public
    function ImageCount: Integer;
    function GetImage(Index: Integer): TBitmap;
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TCurImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
  out AW, AH: Integer);
var Input: TBytes; Size: NativeInt;
begin
  ARGBA := nil; AW := 0; AH := 0;
  Size := Str.Size - Str.Position;
  if Size <= 0 then Exit;
  SetLength(Input, Size);
  Str.ReadBuffer(Input[0], Size);
  ARGBA := DecodeIco(Input, AW, AH);
end;

procedure TCurImage.DecodeFromStream(Str: TStream);
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

function TCurImage.ImageCount: Integer;
begin
  if Length(FData) = 0 then Result := 0 else Result := IcoImageCount(FData);
end;

function TCurImage.GetImage(Index: Integer): TBitmap;
var Pixels: TBytes; W, H: Integer;
begin
  Result := nil;
  if Length(FData) = 0 then Exit;
  Pixels := DecodeIcoImage(FData, Index, W, H);
  if (W <= 0) or (H <= 0) or (NativeInt(Length(Pixels)) < NativeInt(W) * NativeInt(H) * 4) then Exit;
  Result := TBitmap.Create;
  try RGBAToBitmap(Pixels, W, H, Result); except Result.Free; raise; end;
end;

procedure TCurImage.SaveToStream(Stream: TStream);
begin
  raise EIcoError.Create('CUR encoding is not supported');
end;

initialization
  TPicture.RegisterFileFormat('cur', 'CUR Cursor', TCurImage);

finalization
  TPicture.UnregisterGraphicClass(TCurImage);

end.
