unit MngImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	MNG TGraphic wrapper (VCL/LCL), multi-frame        //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Copyright:	(c) 2026 Xelitan.com. All rights reserved.                    //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelMng, XelImageBase;

  // TMngImage - animated MNG; frames are rendered on demand.
type
  TMngImage = class(TXelGraphic)
  private
    FData: TBytes;
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
    procedure DecodeFromStream(Str: TStream); override;
  public
    // Number of animation frames.
    function FrameCount: Integer;
    // Decode frame Index (0-based) into a freshly created TBitmap (caller owns).
    function GetFrame(Index: Integer): TBitmap;
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TMngImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
  out AW, AH: Integer);
var Input: TBytes; Size: NativeInt;
begin
  ARGBA := nil; AW := 0; AH := 0;
  Size := Str.Size - Str.Position;
  if Size <= 0 then Exit;
  SetLength(Input, Size);
  Str.ReadBuffer(Input[0], Size);
  ARGBA := DecodeMng(Input, AW, AH);   // first frame
end;

procedure TMngImage.DecodeFromStream(Str: TStream);
var Pixels: TBytes; W, H: Integer; Size: NativeInt;
begin
  Size := Str.Size - Str.Position;
  SetLength(FData, 0);
  if Size <= 0 then Exit;
  SetLength(FData, Size);
  Str.ReadBuffer(FData[0], Size);
  Pixels := DecodeMng(FData, W, H);
  ReadRGBA(Pixels, W, H);
end;

function TMngImage.FrameCount: Integer;
begin
  if Length(FData) = 0 then Result := 0 else Result := MngFrameCount(FData);
end;

function TMngImage.GetFrame(Index: Integer): TBitmap;
var Pixels: TBytes; W, H: Integer;
begin
  Result := nil;
  if Length(FData) = 0 then Exit;
  Pixels := DecodeMngFrame(FData, Index, W, H);
  if (W <= 0) or (H <= 0) or (NativeInt(Length(Pixels)) < NativeInt(W) * NativeInt(H) * 4) then Exit;
  Result := TBitmap.Create;
  try RGBAToBitmap(Pixels, W, H, Result); except Result.Free; raise; end;
end;

procedure TMngImage.SaveToStream(Stream: TStream);
begin
  raise EMngError.Create('MNG encoding is not supported');
end;

initialization
  TPicture.RegisterFileFormat('mng', 'MNG Image', TMngImage);

finalization
  TPicture.UnregisterGraphicClass(TMngImage);

end.
