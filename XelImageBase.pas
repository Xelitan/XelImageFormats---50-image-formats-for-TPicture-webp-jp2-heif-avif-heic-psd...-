unit XelImageBase;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Ancestor class (VCL/LCL)                                      //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, Math, Types, Dialogs
     {$IFDEF FPC}, IntfGraphics, FPImage, GraphType{$ENDIF};
type
  // Common ancestor for the format wrappers. Owns the backing bitmap FBmp and
  // all the code shared between formats: the RGBA8 <-> bitmap conversions, the
  // standard TGraphic plumbing (Draw / size / transparency / Assign), stream
  // loading and TLazIntfImage export. A concrete format only has to override
  // DecodeStreamToRGBA (its one Decode<Fmt> call) and provide EncodeToStream /
  // SaveToStream.
  TXelGraphic = class(TGraphic)
  protected
    FBmp: TBitmap;
    // Decode a format stream (from its current position to the end) to a
    // top-down, tightly packed RGBA8 buffer (R,G,B,A). The single per-format
    // hook every shared method builds on.
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); virtual; abstract;
    // Paint a packed, top-down RGBA8 buffer (R,G,B,A) into Bmp as pf32bit,
    // sizing it to W x H. No-op if the buffer is too small or W/H <= 0.
    class procedure RGBAToBitmap(const Pixels: TBytes; W, H: Integer; Bmp: TBitmap);
    // Load a packed RGBA8 buffer into the internal bitmap FBmp.
    procedure ReadRGBA(const Pixels: TBytes; W, H: Integer);
    // Gather FBmp into a packed, top-down RGBA8 buffer; W,H = bitmap size.
    procedure WriteRGBA(out Pixels: TBytes; out W, H: Integer);
    // Default stream decode: DecodeStreamToRGBA -> ReadRGBA (fills FBmp).
    // Formats that keep the raw bytes (multi-page/-layer) override this.
    procedure DecodeFromStream(Str: TStream); virtual;
    // Standard TGraphic plumbing, all backed by FBmp.
    procedure Draw(ACanvas: TCanvas; const Rect: TRect); override;
    function GetEmpty: Boolean; override;
    function GetHeight: Integer; override;
    function GetWidth: Integer; override;
    function GetTransparent: Boolean; override;
    procedure SetHeight(Value: Integer); override;
    procedure SetWidth(Value: Integer); override;
    procedure SetTransparent(Value: Boolean); override;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Assign(Source: TPersistent); override;
    procedure LoadFromStream(Stream: TStream); override;
    function ToBitmap: TBitmap;
    {$IFDEF FPC}
    // Thread-safe decode: stream -> TLazIntfImage, no widgetset. Caller owns
    // the returned image (nil on failure). Uses DecodeStreamToRGBA.
    class function ToIntfImage(Str: TStream): TLazIntfImage; virtual;
    {$ENDIF}
  end;

implementation

constructor TXelGraphic.Create;
begin
  inherited Create;
  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1, 1);
end;

destructor TXelGraphic.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

class procedure TXelGraphic.RGBAToBitmap(const Pixels: TBytes; W, H: Integer;
  Bmp: TBitmap);
var
  x, y     : Integer;
  SrcIndex : NativeInt;
{$IFDEF FPC}
  Intf : TLazIntfImage;
  Col  : TFPColor;
{$ELSE}
  Row  : PByte;
{$ENDIF}
begin
  if (W <= 0) or (H <= 0) or
     (NativeInt(Length(Pixels)) < NativeInt(W) * NativeInt(H) * 4) then Exit;

  Bmp.PixelFormat := pf32bit;
  Bmp.SetSize(W, H);
  SrcIndex := 0;
{$IFDEF FPC}
  Intf := Bmp.CreateIntfImage;
  try
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        Col.Red   := Pixels[SrcIndex + 0] * 257;   // 8-bit -> 16-bit
        Col.Green := Pixels[SrcIndex + 1] * 257;
        Col.Blue  := Pixels[SrcIndex + 2] * 257;
        Col.Alpha := Pixels[SrcIndex + 3] * 257;
        Intf.Colors[x, y] := Col;
        Inc(SrcIndex, 4);
      end;
    Bmp.LoadFromIntfImage(Intf);
  finally
    Intf.Free;
  end;
{$ELSE}
  for y := 0 to H - 1 do
  begin
    Row := PByte(Bmp.ScanLine[y]);     // pf32bit is B,G,R,A
    for x := 0 to W - 1 do
    begin
      Row[x * 4 + 0] := Pixels[SrcIndex + 2]; // B
      Row[x * 4 + 1] := Pixels[SrcIndex + 1]; // G
      Row[x * 4 + 2] := Pixels[SrcIndex + 0]; // R
      Row[x * 4 + 3] := Pixels[SrcIndex + 3]; // A
      Inc(SrcIndex, 4);
    end;
  end;
{$ENDIF}
end;

procedure TXelGraphic.ReadRGBA(const Pixels: TBytes; W, H: Integer);
begin
  RGBAToBitmap(Pixels, W, H, FBmp);
end;

procedure TXelGraphic.WriteRGBA(out Pixels: TBytes; out W, H: Integer);
var
  x, y     : Integer;
  DstIndex : NativeInt;
{$IFDEF FPC}
  Intf : TLazIntfImage;
  Col  : TFPColor;
{$ELSE}
  Row  : PByte;
{$ENDIF}
begin
  Pixels := nil;
  W := FBmp.Width;
  H := FBmp.Height;
  if (W <= 0) or (H <= 0) then Exit;
  FBmp.PixelFormat := pf32bit;

  // Gather the bitmap as packed, top-down RGBA8 for an encoder.
  SetLength(Pixels, NativeInt(W) * NativeInt(H) * 4);
  DstIndex := 0;
{$IFDEF FPC}
  Intf := FBmp.CreateIntfImage;
  try
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        Col := Intf.Colors[x, y];       // channels are 16-bit (0..$FFFF)
        Pixels[DstIndex + 0] := Col.Red   shr 8;
        Pixels[DstIndex + 1] := Col.Green shr 8;
        Pixels[DstIndex + 2] := Col.Blue  shr 8;
        Pixels[DstIndex + 3] := Col.Alpha shr 8;
        Inc(DstIndex, 4);
      end;
  finally
    Intf.Free;
  end;
{$ELSE}
  for y := 0 to H - 1 do
  begin
    Row := PByte(FBmp.ScanLine[y]);     // pf32bit is B,G,R,A
    for x := 0 to W - 1 do
    begin
      Pixels[DstIndex + 0] := Row[x * 4 + 2]; // R
      Pixels[DstIndex + 1] := Row[x * 4 + 1]; // G
      Pixels[DstIndex + 2] := Row[x * 4 + 0]; // B
      Pixels[DstIndex + 3] := Row[x * 4 + 3]; // A
      Inc(DstIndex, 4);
    end;
  end;
{$ENDIF}
end;

procedure TXelGraphic.DecodeFromStream(Str: TStream);
var
  Pixels : TBytes;
  W, H   : Integer;
begin
  DecodeStreamToRGBA(Str, Pixels, W, H);
  ReadRGBA(Pixels, W, H);
end;

procedure TXelGraphic.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TXelGraphic.GetEmpty: Boolean;
begin
  Result := (FBmp = nil) or (FBmp.Width = 0) or (FBmp.Height = 0);
end;

function TXelGraphic.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TXelGraphic.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

function TXelGraphic.GetTransparent: Boolean;
begin
  Result := False;
end;

procedure TXelGraphic.SetHeight(Value: Integer);
begin
  FBmp.Height := Value;
end;

procedure TXelGraphic.SetWidth(Value: Integer);
begin
  FBmp.Width := Value;
end;

procedure TXelGraphic.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TXelGraphic.Assign(Source: TPersistent);
var
  Src: TGraphic;
begin
  if Source is TGraphic then
  begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0, 0, Src);
  end;
end;

procedure TXelGraphic.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

function TXelGraphic.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

{$IFDEF FPC}
class function TXelGraphic.ToIntfImage(Str: TStream): TLazIntfImage;
var
  Pixels      : TBytes;
  W, H, x, y  : Integer;
  RequiredSize: NativeUInt;
  SrcIndex    : NativeInt;
  Desc        : TRawImageDescription;
  Dst         : PByte;
  BPL         : PtrInt;
begin
  Result := nil;
  try
    DecodeStreamToRGBA(Str, Pixels, W, H); // pure-Pascal decode -> RGBA8
  except
    Exit;                                  // nil on any decode failure
  end;
  RequiredSize := NativeUInt(W) * NativeUInt(H) * 4;
  if (W <= 0) or (H <= 0) or
     (NativeUInt(Length(Pixels)) < RequiredSize) then Exit;

  Desc.Init_BPP32_B8G8R8A8_BIO_TTB(W, H);
  Result := TLazIntfImage.Create(0, 0);
  Result.DataDescription := Desc;
  Result.SetSize(W, H);
  Dst := PByte(Result.PixelData);
  BPL := Result.DataDescription.BytesPerLine;
  SrcIndex := 0;
  for y := 0 to H - 1 do
  begin
    for x := 0 to W - 1 do
    begin
      Dst[x * 4 + 0] := Pixels[SrcIndex + 2]; // B
      Dst[x * 4 + 1] := Pixels[SrcIndex + 1]; // G
      Dst[x * 4 + 2] := Pixels[SrcIndex + 0]; // R
      Dst[x * 4 + 3] := Pixels[SrcIndex + 3]; // A
      Inc(SrcIndex, 4);
    end;
    Inc(Dst, BPL);
  end;
end;
{$ENDIF}

end.
