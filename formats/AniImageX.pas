unit AniImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	ANI (animated cursor) TGraphic wrapper (VCL/LCL), multi-frame //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Copyright:	(c) 2026 Xelitan.com. All rights reserved.                    //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelAni, XelImageBase;

  // TAniImage - animated cursor; each frame is an ICO/CUR.
type
  TAniImage = class(TXelGraphic)
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

class procedure TAniImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
  out AW, AH: Integer);
var Input: TBytes; Size: NativeInt;
begin
  ARGBA := nil; AW := 0; AH := 0;
  Size := Str.Size - Str.Position;
  if Size <= 0 then Exit;
  SetLength(Input, Size);
  Str.ReadBuffer(Input[0], Size);
  ARGBA := DecodeAni(Input, AW, AH);   // first frame
end;

procedure TAniImage.DecodeFromStream(Str: TStream);
var Pixels: TBytes; W, H: Integer; Size: NativeInt;
begin
  Size := Str.Size - Str.Position;
  SetLength(FData, 0);
  if Size <= 0 then Exit;
  SetLength(FData, Size);
  Str.ReadBuffer(FData[0], Size);
  Pixels := DecodeAni(FData, W, H);
  ReadRGBA(Pixels, W, H);
end;

function TAniImage.FrameCount: Integer;
begin
  if Length(FData) = 0 then Result := 0 else Result := AniFrameCount(FData);
end;

function TAniImage.GetFrame(Index: Integer): TBitmap;
var Pixels: TBytes; W, H: Integer;
begin
  Result := nil;
  if Length(FData) = 0 then Exit;
  Pixels := DecodeAniFrame(FData, Index, W, H);
  if (W <= 0) or (H <= 0) or (NativeInt(Length(Pixels)) < NativeInt(W) * NativeInt(H) * 4) then Exit;
  Result := TBitmap.Create;
  try RGBAToBitmap(Pixels, W, H, Result); except Result.Free; raise; end;
end;

procedure TAniImage.SaveToStream(Stream: TStream);
begin
  raise EAniError.Create('ANI encoding is not supported');
end;

initialization
  TPicture.RegisterFileFormat('ani', 'ANI Cursor', TAniImage);

finalization
  TPicture.UnregisterGraphicClass(TAniImage);

end.
