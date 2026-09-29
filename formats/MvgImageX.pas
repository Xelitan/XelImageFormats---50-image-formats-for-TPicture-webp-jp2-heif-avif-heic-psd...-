unit MvgImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	MVG (Magick Vector Graphics) TGraphic wrapper (VCL/LCL)       //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// Read-only TGraphic for .mvg files. The MVG drawing script is translated to
// SVG (XelMvg) and rasterised by SimpleSVG. SimpleSVG draws shapes (rect,
// circle, ellipse, line, polygon/polyline and path incl. arcs) and <text>,
// so MVG text labels are rendered too.

interface

uses Classes, Graphics, SysUtils, Types,
     {$IFDEF FPC}IntfGraphics, FPImage, GraphType,{$ENDIF}
     XelMvg, SimpleSVG;

type
  TMvgImage = class(TGraphic)
  private
    FBmp: TBitmap;
    FUserW, FUserH: Integer;
    procedure DecodeFromStream(Str: TStream);
  protected
    procedure Draw(ACanvas: TCanvas; const Rect: TRect); override;
    function GetEmpty: Boolean; override;
    function GetHeight: Integer; override;
    function GetTransparent: Boolean; override;
    function GetWidth: Integer; override;
    procedure SetHeight(Value: Integer); override;
    procedure SetTransparent(Value: Boolean); override;
    procedure SetWidth(Value: Integer); override;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Assign(Source: TPersistent); override;
    procedure LoadFromStream(Stream: TStream); override;
    procedure SaveToStream(Stream: TStream); override;
    function ToBitmap: TBitmap;
  end;

implementation

procedure TMvgImage.DecodeFromStream(Str: TStream);
var
  N: Int64;
  Bytes: TBytes;
  MvgText, SvgText: AnsiString;
  W, H: Integer;
begin
  N := Str.Size - Str.Position;
  if N <= 0 then raise EInvalidGraphic.Create('MVG: empty stream');
  SetLength(Bytes, N);
  Str.ReadBuffer(Bytes[0], N);
  SetLength(MvgText, N);
  Move(Bytes[0], MvgText[1], N);

  SvgText := AnsiString(MvgToSvg(string(MvgText)));

  W := FUserW; if W < 0 then W := 0;
  H := FUserH; if H < 0 then H := 0;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(W, H);

  if not RenderSimpleSVGToBitmap(string(SvgText), FBmp) then
    raise EInvalidGraphic.Create('MVG render failed');
end;

procedure TMvgImage.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TMvgImage.GetEmpty: Boolean;
begin
  Result := (FBmp = nil) or (FBmp.Width = 0) or (FBmp.Height = 0);
end;

function TMvgImage.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TMvgImage.GetTransparent: Boolean;
begin
  Result := False;
end;

function TMvgImage.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure TMvgImage.SetHeight(Value: Integer);
begin
  FUserH := Value; FBmp.Height := Value;
end;

procedure TMvgImage.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TMvgImage.SetWidth(Value: Integer);
begin
  FUserW := Value; FBmp.Width := Value;
end;

procedure TMvgImage.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if Source is TGraphic then
  begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0, 0, Src);
  end;
end;

procedure TMvgImage.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure TMvgImage.SaveToStream(Stream: TStream);
begin
  raise EInvalidGraphic.Create('MVG: encoding not supported');
end;

constructor TMvgImage.Create;
begin
  inherited Create;
  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1, 1);
  FUserW := 0; FUserH := 0;
end;

destructor TMvgImage.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TMvgImage.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

initialization
  TPicture.RegisterFileFormat('mvg', 'Magick Vector Graphics', TMvgImage);

finalization
  TPicture.UnregisterGraphicClass(TMvgImage);

end.
