unit CdrImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	CorelDRAW (.cdr) TGraphic wrapper (LCL), read-only           //
// Version:	0.1                                                           //
// Date:	03-OCT-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// CorelDRAW drawings (.cdr, version 6 and later) are converted to SVG by XelCdr
// and rasterised by SimpleSVG. The natural size is the first page at 96 dpi;
// setting Width / Height before loading renders at that size instead. AsSvg
// returns the intermediate SVG document.

interface

uses Classes, Graphics, SysUtils, Types,
     XelCdr, SimpleSVG;

type
  TCdrImage = class(TGraphic)
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

procedure TCdrImage.DecodeFromStream(Str: TStream);
var
  N: Int64;
  Bytes: TBytes;
  W, H: Integer;
begin
  N := Str.Size - Str.Position;
  if N <= 0 then raise EInvalidGraphic.Create('CDR: empty stream');
  SetLength(Bytes, N);
  Str.ReadBuffer(Bytes[0], N);

  try
    FSvg := CdrToSvg(Bytes, W, H);
  except
    on E: EInvalidGraphic do raise;
    on E: Exception do raise EInvalidGraphic.Create(E.Message);
  end;

  if FUserW > 0 then W := FUserW;
  if FUserH > 0 then H := FUserH;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(W, H);

  if not RenderSimpleSVGToBitmap(FSvg, FBmp) then
    raise EInvalidGraphic.Create('CDR: SVG render failed');
end;

procedure TCdrImage.Draw(ACanvas: TCanvas; const Rect: TRect);
begin
  ACanvas.StretchDraw(Rect, FBmp);
end;

function TCdrImage.GetEmpty: Boolean;
begin
  Result := (FBmp = nil) or (FBmp.Width = 0) or (FBmp.Height = 0);
end;

function TCdrImage.GetHeight: Integer;
begin
  Result := FBmp.Height;
end;

function TCdrImage.GetTransparent: Boolean;
begin
  Result := False;
end;

function TCdrImage.GetWidth: Integer;
begin
  Result := FBmp.Width;
end;

procedure TCdrImage.SetHeight(Value: Integer);
begin
  FUserH := Value; FBmp.Height := Value;
end;

procedure TCdrImage.SetTransparent(Value: Boolean);
begin
  //
end;

procedure TCdrImage.SetWidth(Value: Integer);
begin
  FUserW := Value; FBmp.Width := Value;
end;

procedure TCdrImage.Assign(Source: TPersistent);
var Src: TGraphic;
begin
  if Source is TGraphic then
  begin
    Src := Source as TGraphic;
    FBmp.SetSize(Src.Width, Src.Height);
    FBmp.Canvas.Draw(0, 0, Src);
  end;
end;

procedure TCdrImage.LoadFromStream(Stream: TStream);
begin
  DecodeFromStream(Stream);
end;

procedure TCdrImage.SaveToStream(Stream: TStream);
begin
  raise EInvalidGraphic.Create('CDR: encoding not supported');
end;

constructor TCdrImage.Create;
begin
  inherited Create;
  FBmp := TBitmap.Create;
  FBmp.PixelFormat := pf32bit;
  FBmp.SetSize(1, 1);
  FUserW := 0; FUserH := 0;
end;

destructor TCdrImage.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TCdrImage.ToBitmap: TBitmap;
begin
  Result := FBmp;
end;

initialization
  TPicture.RegisterFileFormat('cdr', 'CorelDRAW Drawing', TCdrImage);

finalization
  TPicture.UnregisterGraphicClass(TCdrImage);

end.
