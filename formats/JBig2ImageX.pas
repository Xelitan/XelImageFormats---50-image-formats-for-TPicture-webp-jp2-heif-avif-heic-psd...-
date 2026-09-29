unit JBig2ImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	JBIG2 TGraphic wrapper (VCL/LCL), decode only                 //
// Version:	0.2                                                           //
// Date:	27-SEP-2026                                                   //
// License:     Apache-2.0                                                    //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelJbig2, XelImageBase
     {$IFDEF FPC}, IntfGraphics, GraphType{$ENDIF};

  // TJBig2Image - only the format-specific bits; the rest is in TXelGraphic.
type
  TJBig2Image = class(TXelGraphic)
  private
    FGlobals: TBytes;
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
    // Uses the globals set with SetGlobals.
    procedure DecodeFromStream(Str: TStream); override;
  public
    // Supply the /JBIG2Globals stream bytes before LoadFromStream (optional).
    procedure SetGlobals(const Globals: TBytes);
    // Decode straight from byte buffers (the form the PDF reader uses).
    procedure LoadFromBytes(const Data, Globals: TBytes);
    // Encoding is not supported: raises an exception.
    procedure SaveToStream(Stream: TStream); override;
    {$IFDEF FPC}
    // Thread-safe decode with globals: stream -> TLazIntfImage, no widgetset.
    // Caller owns the returned image (nil on failure).
    class function ToIntfImage(Str: TStream; const Globals: TBytes): TLazIntfImage; reintroduce; overload;
    class function ToIntfImage(Str: TStream): TLazIntfImage; overload; override;
    {$ENDIF}
  end;

// Decode a JBIG2 image to 8-bit grayscale, 1 byte per pixel, row-major,
// 0 = black and 255 = white. Globals may be empty. (Kept here for callers
// that used it from this unit; it lives in XelJbig2.)
function DecodeJBig2ToGray(const Data, Globals: TBytes; out W, H: Integer;
  out Gray: TBytes): Boolean;

implementation

function DecodeJBig2ToGray(const Data, Globals: TBytes; out W, H: Integer;
  out Gray: TBytes): Boolean;
begin
  Result := XelJbig2.DecodeJBig2ToGray(Data, Globals, W, H, Gray);
end;

class procedure TJBig2Image.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
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
  ARGBA := DecodeJbig2(Input, AW, AH);   // pure-Pascal decode -> RGBA8
end;

procedure TJBig2Image.DecodeFromStream(Str: TStream);
var
  Input: TBytes;
  Size : NativeInt;
begin
  Size := Str.Size - Str.Position;
  if Size <= 0 then Exit;
  SetLength(Input, Size);
  Str.ReadBuffer(Input[0], Size);
  LoadFromBytes(Input, FGlobals);
end;

procedure TJBig2Image.SetGlobals(const Globals: TBytes);
begin
  FGlobals := Globals;
end;

procedure TJBig2Image.LoadFromBytes(const Data, Globals: TBytes);
var
  RGBA: TBytes;
  W, H: Integer;
begin
  FGlobals := Globals;
  RGBA := DecodeJbig2Globals(Data, Globals, W, H);
  ReadRGBA(RGBA, W, H);
end;

procedure TJBig2Image.SaveToStream(Stream: TStream);
begin
  raise EJbig2Error.Create('JBIG2: encoding is not supported');
end;

{$IFDEF FPC}
class function TJBig2Image.ToIntfImage(Str: TStream; const Globals: TBytes): TLazIntfImage;
var
  Input, Gray: TBytes;
  Size : NativeInt;
  W, H, x, y: Integer;
  Desc : TRawImageDescription;
  Dst  : PByte;
  BPL  : PtrInt;
  v    : Byte;
begin
  Result := nil;
  Size := Str.Size - Str.Position;
  if Size <= 0 then Exit;
  SetLength(Input, Size);
  Str.ReadBuffer(Input[0], Size);
  if not XelJbig2.DecodeJBig2ToGray(Input, Globals, W, H, Gray) then Exit;  // pure Pascal
  if (W <= 0) or (H <= 0) or (NativeInt(Length(Gray)) < NativeInt(W) * H) then Exit;

  Desc.Init_BPP32_B8G8R8A8_BIO_TTB(W, H);
  Result := TLazIntfImage.Create(0, 0);
  Result.DataDescription := Desc;
  Result.SetSize(W, H);
  Dst := PByte(Result.PixelData);
  BPL := Result.DataDescription.BytesPerLine;
  for y := 0 to H - 1 do
  begin
    for x := 0 to W - 1 do
    begin
      v := Gray[y * W + x];   // 0 = black, 255 = white
      Dst[x * 4 + 0] := v;
      Dst[x * 4 + 1] := v;
      Dst[x * 4 + 2] := v;
      Dst[x * 4 + 3] := 255;
    end;
    Inc(Dst, BPL);
  end;
end;

class function TJBig2Image.ToIntfImage(Str: TStream): TLazIntfImage;
begin
  Result := inherited ToIntfImage(Str);
end;
{$ENDIF}

initialization
  TPicture.RegisterFileFormat('Jb2','JBIG2 Image', TJBig2Image);

finalization
  TPicture.UnregisterGraphicClass(TJBig2Image);

end.
