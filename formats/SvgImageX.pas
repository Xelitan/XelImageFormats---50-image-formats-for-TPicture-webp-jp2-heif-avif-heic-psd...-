unit SvgImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description: SVG TPicture binding (read-only, rasterizes through           //
//              SimpleSVG.RenderSimpleSVGToBitmap)                            //
// Target:      Lazarus / Free Pascal, any LCL widget set                     //
// License:     MIT                                                           //
// Copyright:   (c) 2026 Xelitan.com.                                         //
//              All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, Types,
     {$IFDEF FPC}IntfGraphics, FPImage, GraphType,{$ENDIF}
     SimpleSVG;

type
  { TSvgImage }
  // Read-only TGraphic for .svg files. Renders the document onto an internal
  // bitmap at the size declared by the SVG (width/height/viewBox); SetSize
  // before loading to force a target rasterization size.
  TSvgImage = class(TGraphic)
  private
    FBmp: TBitmap;
    FUserW, FUserH: Integer; // 0 = use SVG's own size
    procedure DecodeFromStream(Str: TStream);
  protected
    procedure Draw(ACanvas: TCanvas; const Rect: TRect); override;
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

{ TSvgImage }

procedure TSvgImage.DecodeFromStream(Str: TStream);
var
  N: Int64;
  Bytes: TBytes;
  SvgText: AnsiString;
  W, H: Integer;
begin
  N := Str.Size - Str.Position;
  if N <= 0 then
    raise EInvalidGraphic.Create('SVG: empty stream');

  SetLength(Bytes, N);
  Str.ReadBuffer(Bytes[0], N);

  // SimpleSVG parses through XMLRead, which handles UTF-8/UTF-16 declarations
  // itself, so passing the raw bytes as an AnsiString is safe.
  SetLength(SvgText, N);
  Move(Bytes[0], SvgText[1], N);

  // 0 lets SimpleSVG fall back to the document's own width/height.
  W := FUserW; if W < 0 then W := 0;
  H := FUserH; if H < 0 then H := 0;

  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(W, H);

  if not RenderSimpleSVGToBitmap(string(SvgText), FBmp) then
    raise EInvalidGraphic.Create('SVG render failed');
end;

procedure TSvgImage.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TSvgImage.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TSvgImage.GetTransparent: Boolean;
begin
  Result := False;
end;

function TSvgImage.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure TSvgImage.SetHeight(Value: Integer);
begin
  FUserH := Value;
  FBmp.Height := Value;
end;

procedure TSvgImage.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TSvgImage.SetWidth(Value: Integer);
begin
  FUserW := Value;
  FBmp.Width := Value;
end;

procedure TSvgImage.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if Source is TGraphic then begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0, 0, Src);
  end;
end;

procedure TSvgImage.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure TSvgImage.SaveToStream(Stream: TStream);
begin
  // SVG writing is not supported.
  raise EInvalidGraphic.Create('SVG: encoding not supported');
end;

constructor TSvgImage.Create;
begin
  inherited Create;
  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1, 1);
  FUserW := 0;
  FUserH := 0;
end;

destructor TSvgImage.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TSvgImage.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

initialization
  TPicture.RegisterFileFormat('Svg', 'SVG Image', TSvgImage);

finalization
  TPicture.UnregisterGraphicClass(TSvgImage);

end.
