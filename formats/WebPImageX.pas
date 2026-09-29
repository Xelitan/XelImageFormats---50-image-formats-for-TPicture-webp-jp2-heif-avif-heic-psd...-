unit WebPImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	WebP TGraphic wrapper (VCL/LCL)                               //
// Version:	0.2                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelWebp, XelImageBase;

  // TWebpImage - only the format-specific bits; the rest is in TXelGraphic.
type
  TWebpImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    // Encode the internal bitmap to WebP and write it to Str.
    //   IsLossless       : True = VP8L lossless; False = VP8 lossy.
    //   CompressionLevel : lossy quality 0..100 (higher = better quality).
    procedure EncodeToStream(Str: TStream; IsLossless: Boolean = False;
                             CompressionLevel: Integer = 75);
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

class procedure TWebpImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeWebp(Input, AW, AH);   // pure-Pascal decode -> RGBA8
end;

procedure TWebpImage.EncodeToStream(Str: TStream; IsLossless: Boolean = False;
                                    CompressionLevel: Integer = 75);
var
  W, H : Integer;
  RGBA : TBytes;
  Data : TBytes;
begin
  WriteRGBA(RGBA, W, H);   // gather FBmp -> RGBA8 (shared, in TXelGraphic)
  if (W <= 0) or (H <= 0) then Exit;

  Data := EncodeWebp(RGBA, W, H, IsLossless, CompressionLevel);
  if Length(Data) > 0 then
    Str.WriteBuffer(Data[0], Length(Data));
end;

procedure TWebpImage.SaveToStream(Stream: TStream);
begin
  // Default: lossy, quality 75. Use EncodeToStream for explicit control.
  EncodeToStream(Stream, False, 75);
end;

initialization
  TPicture.RegisterFileFormat('WebP','WebP Image', TWebpImage);

finalization
  TPicture.UnregisterGraphicClass(TWebpImage);

end.
