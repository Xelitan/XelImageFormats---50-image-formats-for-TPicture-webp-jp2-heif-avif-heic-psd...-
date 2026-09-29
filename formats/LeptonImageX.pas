unit LeptonImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description: Lepton (JPEG re-compression) TGraphic wrapper (VCL/LCL)       //
// Version:	0.2                                                           //
// Date:	27-SEP-2026                                                   //
// License:     Apache-2.0                                                    //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelLepton, XelImageBase
     {$IFDEF FPC}, IntfGraphics, GraphType{$ENDIF};

  // TLeptonImage - only the format-specific bits; the rest is in TXelGraphic.
  // .lep is a re-compressed JPEG bitstream: loading restores the JPEG and
  // decodes it; saving encodes the bitmap as JPEG and compresses that to .lep.
type
  TLeptonImage = class(TXelGraphic)
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
  public
    // Encode the internal bitmap as a JPEG of quality CompressionLevel
    // (1..100) and write it to Str as .lep.
    procedure EncodeToStream(Str: TStream; CompressionLevel: Integer = 75);
    procedure SaveToStream(Stream: TStream); override;
    {$IFDEF FPC}
    // Thread-safe decode at reduced size: the picture is shrunk by the largest
    // factor (2, 4, 8) that still covers AMaxW x AMaxH - smaller for
    // thumbnails. No widgetset. Caller owns the result (nil on failure).
    // ToIntfImage(Str) decodes full size.
    class function ToIntfImage(Str: TStream; AMaxW: Integer;
      AMaxH: Integer = 0): TLazIntfImage; reintroduce; overload;
    class function ToIntfImage(Str: TStream): TLazIntfImage; overload; override;
    {$ENDIF}
  end;

implementation

class procedure TLeptonImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeLepton(Input, AW, AH);   // .lep -> JPEG -> RGBA8
end;

procedure TLeptonImage.EncodeToStream(Str: TStream; CompressionLevel: Integer = 75);
var
  W, H : Integer;
  RGBA : TBytes;
  Data : TBytes;
begin
  WriteRGBA(RGBA, W, H);   // gather FBmp -> RGBA8 (shared, in TXelGraphic)
  if (W <= 0) or (H <= 0) then Exit;

  Data := EncodeLepton(RGBA, W, H, CompressionLevel);
  if Length(Data) > 0 then
    Str.WriteBuffer(Data[0], Length(Data));
end;

procedure TLeptonImage.SaveToStream(Stream: TStream);
begin
  // Default: JPEG quality 75. Use EncodeToStream for explicit control.
  EncodeToStream(Stream, 75);
end;

{$IFDEF FPC}
class function TLeptonImage.ToIntfImage(Str: TStream; AMaxW: Integer;
  AMaxH: Integer = 0): TLazIntfImage;
var
  Input, RGBA: TBytes;
  Size : NativeInt;
  W, H, x, y: Integer;
  Desc : TRawImageDescription;
  Dst  : PByte;
  BPL  : PtrInt;
  P    : NativeInt;
begin
  Result := nil;
  Size := Str.Size - Str.Position;
  if Size <= 0 then Exit;
  SetLength(Input, Size);
  Str.ReadBuffer(Input[0], Size);
  try
    RGBA := DecodeLeptonScaled(Input, AMaxW, AMaxH, W, H);   // pure Pascal
  except
    Exit;                                  // nil on any decode failure
  end;
  Desc.Init_BPP32_B8G8R8A8_BIO_TTB(W, H);
  Result := TLazIntfImage.Create(0, 0);
  Result.DataDescription := Desc;
  Result.SetSize(W, H);
  Dst := PByte(Result.PixelData);
  BPL := Result.DataDescription.BytesPerLine;
  P := 0;
  for y := 0 to H - 1 do
  begin
    for x := 0 to W - 1 do
    begin
      Dst[x * 4 + 0] := RGBA[P + 2]; // B
      Dst[x * 4 + 1] := RGBA[P + 1]; // G
      Dst[x * 4 + 2] := RGBA[P + 0]; // R
      Dst[x * 4 + 3] := RGBA[P + 3]; // A
      Inc(P, 4);
    end;
    Inc(Dst, BPL);
  end;
end;

class function TLeptonImage.ToIntfImage(Str: TStream): TLazIntfImage;
begin
  Result := inherited ToIntfImage(Str);
end;
{$ENDIF}

initialization
  TPicture.RegisterFileFormat('Lep', 'Lepton JPEG', TLeptonImage);

finalization
  TPicture.UnregisterGraphicClass(TLeptonImage);

end.
