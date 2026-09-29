unit TiffImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	TIFF TGraphic wrapper (VCL/LCL), multi-page                   //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelTiff, XelImageBase;

  // TTiffImage - keeps the raw file so any page can be read; the rest is in TXelGraphic.
type
  TTiffImage = class(TXelGraphic)
  private
    FData: TBytes;   // whole TIFF file, kept so individual pages can be read
  protected
    // Decode hook (page 0) used by the shared ToIntfImage.
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
    // Overridden to keep the raw bytes (for PageCount / GetPage) then fill FBmp.
    procedure DecodeFromStream(Str: TStream); override;
  public
    // Encode the internal bitmap to a single-page LZW TIFF and write it to Str.
    procedure EncodeToStream(Str: TStream);
    // Number of pages (IFDs) in the currently loaded TIFF (0 if none loaded).
    function PageCount: Integer;
    // Decode page Index (0-based) into a freshly created TBitmap. The caller
    // owns the result; returns nil if the page cannot be decoded.
    function GetPage(Index: Integer): TBitmap;
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TTiffImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeTiff(Input, AW, AH);   // pure-Pascal decode -> RGBA8 (page 0)
end;

procedure TTiffImage.DecodeFromStream(Str: TStream);
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

  Pixels := DecodeTiffPage(FData, 0, W, H);
  ReadRGBA(Pixels, W, H);   // fill FBmp (shared, in TXelGraphic)
end;

function TTiffImage.PageCount: Integer;
begin
  if Length(FData) = 0 then Result := 0
  else Result := TiffPageCount(FData);
end;

function TTiffImage.GetPage(Index: Integer): TBitmap;
var
  Pixels : TBytes;
  W, H   : Integer;
begin
  Result := nil;
  if Length(FData) = 0 then Exit;
  Pixels := DecodeTiffPage(FData, Index, W, H);
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

procedure TTiffImage.EncodeToStream(Str: TStream);
var
  W, H : Integer;
  RGBA : TBytes;
  Data : TBytes;
begin
  WriteRGBA(RGBA, W, H);   // gather FBmp -> RGBA8 (shared, in TXelGraphic)
  if (W <= 0) or (H <= 0) then Exit;

  Data := EncodeTiff(RGBA, W, H);
  if Length(Data) > 0 then
    Str.WriteBuffer(Data[0], Length(Data));
end;

procedure TTiffImage.SaveToStream(Stream: TStream);
begin
  EncodeToStream(Stream);
end;

initialization
  TPicture.RegisterFileFormat('tif','TIFF Image', TTiffImage);

finalization
  TPicture.UnregisterGraphicClass(TTiffImage);

end.
