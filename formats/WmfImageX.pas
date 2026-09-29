unit WmfImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	WMF / EMF TGraphic wrapper (LCL), read-only                   //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// Windows metafiles (.wmf, .emf and their gzip forms .wmz, .emz) are converted
// to SVG by XelWmf and rasterised by SimpleSVG. The natural size is the
// metafile's picture size at 96 dpi; setting Width / Height before loading
// renders at that size instead. AsSvg returns the intermediate SVG document.

interface

uses Classes, Graphics, SysUtils, Types,
     XelWmf, SimpleSVG;

type
  TWmfImage = class(TGraphic)
  private
    FBmp: TBitmap;
    FSvg: string;
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
    property AsSvg: string read FSvg;
  end;

implementation

procedure TWmfImage.DecodeFromStream(Str: TStream);
var
  N: Int64;
  Bytes: TBytes;
  W, H: Integer;
begin
  N := Str.Size - Str.Position;
  if N <= 0 then raise EInvalidGraphic.Create('WMF: empty stream');
  SetLength(Bytes, N);
  Str.ReadBuffer(Bytes[0], N);

  FSvg := MetafileToSvg(Bytes, W, H);

  if FUserW > 0 then W := FUserW;
  if FUserH > 0 then H := FUserH;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(W, H);

  if not RenderSimpleSVGToBitmap(FSvg, FBmp) then
    raise EInvalidGraphic.Create('WMF: SVG render failed');
end;

procedure TWmfImage.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TWmfImage.GetEmpty: Boolean;
begin
  Result := (FBmp = nil) or (FBmp.Width = 0) or (FBmp.Height = 0);
end;

function TWmfImage.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TWmfImage.GetTransparent: Boolean;
begin
  Result := False;
end;

function TWmfImage.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure TWmfImage.SetHeight(Value: Integer);
begin
  FUserH := Value; FBmp.Height := Value;
end;

procedure TWmfImage.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TWmfImage.SetWidth(Value: Integer);
begin
  FUserW := Value; FBmp.Width := Value;
end;

procedure TWmfImage.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if Source is TGraphic then
  begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0, 0, Src);
  end;
end;

procedure TWmfImage.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure TWmfImage.SaveToStream(Stream: TStream);
begin
  raise EInvalidGraphic.Create('WMF/EMF: encoding not supported');
end;

constructor TWmfImage.Create;
begin
  inherited Create;
  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1, 1);
  FUserW := 0; FUserH := 0;
end;

destructor TWmfImage.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TWmfImage.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

initialization
  TPicture.RegisterFileFormat('wmf', 'Windows Metafile', TWmfImage);
  TPicture.RegisterFileFormat('emf', 'Enhanced Metafile', TWmfImage);
  TPicture.RegisterFileFormat('wmz', 'Compressed Windows Metafile', TWmfImage);
  TPicture.RegisterFileFormat('emz', 'Compressed Enhanced Metafile', TWmfImage);

finalization
  TPicture.UnregisterGraphicClass(TWmfImage);

end.
