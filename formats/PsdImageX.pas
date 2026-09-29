unit PsdImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	PSD TGraphic wrapper (VCL/LCL), layer access                  //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelPsd, XelImageBase;

  // TPsdImage - keeps the raw file so any layer can be read; the rest is in TXelGraphic.
type
  TPsdImage = class(TXelGraphic)
  private
    FData: TBytes;   // whole PSD file, kept so individual layers can be read
  protected
    // Decode hook (composite) used by the shared ToIntfImage.
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
    // Overridden to keep the raw bytes (for LayerCount / GetLayer) then fill FBmp.
    procedure DecodeFromStream(Str: TStream); override;
  public
    // Encode the internal (flattened) bitmap to PSD and write it to Str.
    procedure EncodeToStream(Str: TStream);
    // Number of layers in the currently loaded PSD (0 if none loaded / no layers).
    function LayerCount: Integer;
    // Decode layer Index (0-based) into a freshly created TBitmap sized to the
    // layer rectangle. The caller owns the result; nil for an empty layer.
    function GetLayer(Index: Integer): TBitmap;
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TPsdImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodePsd(Input, AW, AH);   // pure-Pascal decode -> RGBA8 (composite)
end;

procedure TPsdImage.DecodeFromStream(Str: TStream);
var
  Pixels : TBytes;
  W, H   : Integer;
  Size   : NativeInt;
begin
  Size := Str.Size - Str.Position;
  SetLength(FData, 0);
  if Size <= 0 then Exit;
  SetLength(FData, Size);
  Str.ReadBuffer(FData[0], Size);

  Pixels := DecodePsd(FData, W, H);
  ReadRGBA(Pixels, W, H);   // fill FBmp (shared, in TXelGraphic)
end;

function TPsdImage.LayerCount: Integer;
begin
  if Length(FData) = 0 then Result := 0
  else Result := PsdLayerCount(FData);
end;

function TPsdImage.GetLayer(Index: Integer): TBitmap;
var
  Pixels : TBytes;
  W, H   : Integer;
begin
  Result := nil;
  if Length(FData) = 0 then Exit;
  Pixels := DecodePsdLayer(FData, Index, W, H);
  if (W <= 0) or (H <= 0) or
     (NativeInt(Length(Pixels)) < NativeInt(W) * NativeInt(H) * 4) then Exit;
  Result := TBitmap.Create;
  try
    RGBAToBitmap(Pixels, W, H, Result);   // shared, in TXelGraphic
  except
    Result.Free;
    raise;
  end;
end;

procedure TPsdImage.EncodeToStream(Str: TStream);
var
  W, H : Integer;
  RGBA : TBytes;
  Data : TBytes;
begin
  WriteRGBA(RGBA, W, H);   // gather FBmp -> RGBA8 (shared, in TXelGraphic)
  if (W <= 0) or (H <= 0) then Exit;

  Data := EncodePsd(RGBA, W, H);
  if Length(Data) > 0 then
    Str.WriteBuffer(Data[0], Length(Data));
end;

procedure TPsdImage.SaveToStream(Stream: TStream);
begin
  EncodeToStream(Stream);
end;

initialization
  TPicture.RegisterFileFormat('psd','PSD Image', TPsdImage);

finalization
  TPicture.UnregisterGraphicClass(TPsdImage);

end.
