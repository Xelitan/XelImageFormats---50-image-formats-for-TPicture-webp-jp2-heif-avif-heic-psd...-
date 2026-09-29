unit RawImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Camera RAW TGraphic wrapper (VCL/LCL), read-only             //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// Registers the camera-raw extensions and develops them to a full-resolution
// image through XelRaw. Digital Negative (.dng), including lossless-JPEG-
// compressed and tiled CFA files, is fully developed (linearise, white balance,
// demosaic, colour-matrix to sRGB). TIFF/EP raws from other vendors are handled
// where their CFA is uncompressed or lossless-JPEG; vendor-proprietary codecs
// (e.g. Kodak DCR, Foveon X3F, Fuji RAF, Canon CRW/CR3) raise a clear error.

interface

uses Classes, Graphics, SysUtils, XelRaw, XelImageBase;

  // TRawImage - decode only; developing a raw is a one-way operation.
type
  TRawImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TRawImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeRaw(Input, AW, AH);   // pure-Pascal develop -> RGBA8
end;

procedure TRawImage.SaveToStream(Stream: TStream);
begin
  raise ERawError.Create('RAW: writing is not supported');
end;

initialization
  TPicture.RegisterFileFormat('dng','Digital Negative', TRawImage);
  TPicture.RegisterFileFormat('cr2','Canon RAW', TRawImage);
  TPicture.RegisterFileFormat('cr3','Canon RAW', TRawImage);
  TPicture.RegisterFileFormat('crw','Canon RAW', TRawImage);
  TPicture.RegisterFileFormat('dcr','Kodak RAW', TRawImage);
  TPicture.RegisterFileFormat('mrw','Minolta RAW', TRawImage);
  TPicture.RegisterFileFormat('nef','Nikon RAW', TRawImage);
  TPicture.RegisterFileFormat('orf','Olympus RAW', TRawImage);
  TPicture.RegisterFileFormat('pef','Pentax RAW', TRawImage);
  TPicture.RegisterFileFormat('raf','Fuji RAW', TRawImage);
  TPicture.RegisterFileFormat('srf','Sony RAW', TRawImage);
  TPicture.RegisterFileFormat('x3f','Sigma RAW', TRawImage);

finalization
  TPicture.UnregisterGraphicClass(TRawImage);

end.
