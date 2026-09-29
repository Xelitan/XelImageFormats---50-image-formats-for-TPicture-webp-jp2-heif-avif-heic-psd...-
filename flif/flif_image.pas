// FLIF - Free Lossless Image Format -- Free Pascal port
// Pixel planes and the Image container.
// Corresponds to: src/image/image.hpp, src/image/image.cpp
//
// The C++ code uses Plane<pixel_t> templates plus a visitor to specialise the
// hot loops. Here the four concrete plane classes are generated from an include
// file and the hot loops go through virtual get_fast/set_fast instead; the
// produced bitstream is identical.
unit flif_image;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$MACRO ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, flif_types, flif_crc32;

type
  TMetaData = record
    Name: string;             // 4 ascii letters
    Length: SizeInt;          // length of the (deflate-compressed) contents
    Contents: array of Byte;
  end;
  TMetaDataArray = array of TMetaData;

  TGeneralPlane = class
  public
    procedure SetPix(R, C: SizeUInt; X: ColorVal); virtual; abstract;
    function GetPix(R, C: SizeUInt): ColorVal; virtual; abstract;
    procedure PrepareZoomlevel(Z: Integer); virtual;
    function GetFast(R, C: SizeUInt): ColorVal; virtual; abstract;
    procedure SetFast(R, C: SizeUInt; X: ColorVal); virtual; abstract;
    function IsConstant: Boolean; virtual;
    function BytesPerPixel: Integer; virtual;
    procedure SetPixZ(Z: Integer; R, C: SizeUInt; X: ColorVal); virtual; abstract;
    function GetPixZ(Z: Integer; R, C: SizeUInt): ColorVal; virtual; abstract;
    procedure NormalizeScale; virtual;
    function ComputeCRC32(Prev: Cardinal): Cardinal; virtual; abstract;
    // copy_row_range() from image.hpp
    procedure CopyRowRange(Src: TGeneralPlane; R, RBegin, REnd: SizeUInt; Stride: SizeUInt = 1);
  end;

function ZoomRowPixelSize(Zoomlevel: Integer): SizeUInt; inline;
function ZoomColPixelSize(Zoomlevel: Integer): SizeUInt; inline;
function SCALED(X: SizeUInt; Scale: Integer): SizeUInt; inline;

type
{$define PLANECLASS := TPlane8}
{$define PIXELTYPE := Byte}
{$i plane_decl.inc}

{$define PLANECLASS := TPlane16s}
{$define PIXELTYPE := Int16}
{$i plane_decl.inc}

{$define PLANECLASS := TPlane16u}
{$define PIXELTYPE := Word}
{$i plane_decl.inc}

{$define PLANECLASS := TPlane32s}
{$define PIXELTYPE := Int32}
{$i plane_decl.inc}

  TConstantPlane = class(TGeneralPlane)
  private
    FColor: ColorVal;
  public
    constructor Create(C: ColorVal);
    procedure SetPix(R, C: SizeUInt; X: ColorVal); override;
    function GetPix(R, C: SizeUInt): ColorVal; override;
    procedure PrepareZoomlevel(Z: Integer); override;
    function GetFast(R, C: SizeUInt): ColorVal; override;
    procedure SetFast(R, C: SizeUInt; X: ColorVal); override;
    function IsConstant: Boolean; override;
    procedure SetPixZ(Z: Integer; R, C: SizeUInt; X: ColorVal); override;
    function GetPixZ(Z: Integer; R, C: SizeUInt): ColorVal; override;
    function ComputeCRC32(Prev: Cardinal): Cardinal; override;
  end;

  TImage = class
  private
    FPlanes: array[0..4] of TGeneralPlane;
    FWidth, FHeight: SizeUInt;
    FMinval, FMaxval: ColorVal;
    FNum: Integer;
    FScale: Integer;
    FDepth: Integer;
    procedure AllocPlanes(SmallerBuffer: Boolean);
  public
    Palette: Boolean;
    PaletteImage: TImage;      // owned
    FrameDelay: Integer;
    AlphaZeroSpecial: Boolean;
    ColBegin: array of Cardinal;
    ColEnd: array of Cardinal;
    SeenBefore: Integer;
    FullyDecoded: Boolean;
    Metadata: TMetaDataArray;

    constructor Create(AScale: Integer = 0); overload;
    constructor Create(W, H: Cardinal; AMin, AMax: ColorVal; APlanes: Integer;
      AScale: Integer = 0); overload;
    destructor Destroy; override;

    function Init(W, H: Cardinal; AMin, AMax: ColorVal; P: Integer): Boolean;
    function SemiInit(W, H: Cardinal; AMin, AMax: ColorVal; P: Integer): Boolean;
    function RealInit(SmallerBuffer: Boolean): Boolean;

    procedure Clear;
    procedure Reset;
    procedure NormalizeScale;

    function Clone: TImage;
    function CloneDownsampled(NewW, NewH: Integer): TImage;
    // copy constructor with stride (used for progressive previews)
    function CloneStrided(const SkipInterpolate: array of Boolean;
      const Zoomlevels: array of Integer): TImage;

    function UsesAlpha: Boolean;
    function UsesColor: Boolean;
    procedure DropAlpha;
    procedure DropColor;
    procedure DropFrameLookbacks;
    procedure MakeInvisibleRgbBlack;
    procedure MakeConstantPlane(P: Integer; Val: ColorVal);
    procedure UndoMakeConstantPlane(P: Integer);
    procedure EnsureChroma;
    procedure EnsureAlpha;
    procedure EnsureFrameLookbacks;

    function GetVal(P: Integer; R, C: SizeUInt): ColorVal; inline;
    procedure SetVal(P: Integer; R, C: SizeUInt; X: ColorVal); inline;
    function GetValZ(P, Z: Integer; RZ, CZ: SizeUInt): ColorVal; inline;
    procedure SetValZ(P, Z: Integer; RZ, CZ: SizeUInt; X: ColorVal); inline;

    function NumPlanes: Integer; inline;
    function MinVal(P: Integer): ColorVal; inline;
    function MaxVal(P: Integer): ColorVal; inline;
    function Rows: SizeUInt; inline;
    function Cols: SizeUInt; inline;
    function GetScale: Integer; inline;
    function ScaledRows: SizeUInt; inline;
    function ScaledCols: SizeUInt; inline;
    function RowsZ(Zoomlevel: Integer): SizeUInt;
    function ColsZ(Zoomlevel: Integer): SizeUInt;
    function Zooms: Integer;
    function GetPlane(P: Integer): TGeneralPlane; inline;
    function GetFRA(R, C: SizeUInt): ColorVal; inline;
    function GetFRAZ(Z: Integer; R, C: SizeUInt): ColorVal; inline;
    function GetDepth: Integer; inline;
    function Checksum: Cardinal;
    procedure AbortDecoding;
    function HasMetadata(const ChunkName: string): Boolean;
  end;

  TImages = array of TImage;

procedure FreeImages(var Imgs: TImages);

implementation

function ZoomRowPixelSize(Zoomlevel: Integer): SizeUInt;
begin
  Result := SizeUInt(1) shl ((Zoomlevel + 1) div 2);
end;

function ZoomColPixelSize(Zoomlevel: Integer): SizeUInt;
begin
  Result := SizeUInt(1) shl (Zoomlevel div 2);
end;

function SCALED(X: SizeUInt; Scale: Integer): SizeUInt;
begin
  if X = 0 then
    Result := 0
  else
    Result := ((X - 1) shr Scale) + 1;
end;

// TGeneralPlane

procedure TGeneralPlane.PrepareZoomlevel(Z: Integer);
begin
end;

function TGeneralPlane.IsConstant: Boolean;
begin
  Result := False;
end;

function TGeneralPlane.BytesPerPixel: Integer;
begin
  Result := 0;
end;

procedure TGeneralPlane.NormalizeScale;
begin
end;

procedure TGeneralPlane.CopyRowRange(Src: TGeneralPlane; R, RBegin, REnd: SizeUInt;
  Stride: SizeUInt);
var
  C: SizeUInt;
begin
  if Stride = 0 then Stride := 1;
  C := RBegin;
  while C < REnd do
  begin
    SetPix(R, C, Src.GetPix(R, C));
    Inc(C, Stride);
  end;
end;

{$define PLANECLASS := TPlane8}
{$define PIXELTYPE := Byte}
{$i plane_impl.inc}

{$define PLANECLASS := TPlane16s}
{$define PIXELTYPE := Int16}
{$i plane_impl.inc}

{$define PLANECLASS := TPlane16u}
{$define PIXELTYPE := Word}
{$i plane_impl.inc}

{$define PLANECLASS := TPlane32s}
{$define PIXELTYPE := Int32}
{$i plane_impl.inc}

// TConstantPlane

constructor TConstantPlane.Create(C: ColorVal);
begin
  inherited Create;
  FColor := C;
end;

procedure TConstantPlane.SetPix(R, C: SizeUInt; X: ColorVal);
begin
end;

function TConstantPlane.GetPix(R, C: SizeUInt): ColorVal;
begin
  Result := FColor;
end;

procedure TConstantPlane.PrepareZoomlevel(Z: Integer);
begin
end;

function TConstantPlane.GetFast(R, C: SizeUInt): ColorVal;
begin
  Result := FColor;
end;

procedure TConstantPlane.SetFast(R, C: SizeUInt; X: ColorVal);
begin
end;

function TConstantPlane.IsConstant: Boolean;
begin
  Result := True;
end;

procedure TConstantPlane.SetPixZ(Z: Integer; R, C: SizeUInt; X: ColorVal);
begin
end;

function TConstantPlane.GetPixZ(Z: Integer; R, C: SizeUInt): ColorVal;
begin
  Result := FColor;
end;

function TConstantPlane.ComputeCRC32(Prev: Cardinal): Cardinal;
var
  OnePixel: Word;
begin
  OnePixel := Word(FColor);
  Result := crc32_fast(@OnePixel, 2, Prev);
end;

// TImage

constructor TImage.Create(AScale: Integer);
begin
  inherited Create;
  FScale := AScale;
  FWidth := 0;
  FHeight := 0;
  FMinval := 0;
  FMaxval := 0;
  FNum := 0;
  FrameDelay := 0;
  FullyDecoded := False;
  FDepth := 0;
  Palette := False;
  PaletteImage := nil;
  AlphaZeroSpecial := True;
  SeenBefore := 0;
end;

constructor TImage.Create(W, H: Cardinal; AMin, AMax: ColorVal; APlanes: Integer;
  AScale: Integer);
begin
  inherited Create;
  FScale := AScale;
  AlphaZeroSpecial := True;
  PaletteImage := nil;
  Init(W, H, AMin, AMax, APlanes);
end;

destructor TImage.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TImage.Clear;
var
  P: Integer;
begin
  for P := 0 to 4 do
    FreeAndNil(FPlanes[P]);
  FreeAndNil(PaletteImage);
end;

procedure TImage.Reset;
begin
  Clear;
  Init(0, 0, 0, 0, 0);
end;

function TImage.Init(W, H: Cardinal; AMin, AMax: ColorVal; P: Integer): Boolean;
begin
  if not SemiInit(W, H, AMin, AMax, P) then Exit(False);
  Result := RealInit(False);
end;

function TImage.SemiInit(W, H: Cardinal; AMin, AMax: ColorVal; P: Integer): Boolean;
var
  I: SizeUInt;
begin
  FWidth := W;
  FHeight := H;
  FMinval := AMin;
  if (AMax and (AMax + 1)) <> 0 then
  begin
    AMax := AMax or (AMax shr 1);
    AMax := AMax or (AMax shr 2);
    AMax := AMax or (AMax shr 4);
    AMax := AMax or (AMax shr 8);
  end;
  FMaxval := AMax;
  FNum := P;
  SeenBefore := -1;
  if AMax < 256 then FDepth := 8 else FDepth := 16;
  FrameDelay := 0;
  Palette := False;
  FreeAndNil(PaletteImage);
  AlphaZeroSpecial := True;
  FullyDecoded := False;

  Clear;
  SetLength(ColBegin, FHeight);
  SetLength(ColEnd, FHeight);
  for I := 0 to FHeight - 1 do
  begin
    ColBegin[I] := 0;
    ColEnd[I] := FWidth;
  end;
  Result := True;
end;

procedure TImage.AllocPlanes(SmallerBuffer: Boolean);
var
  P: Integer;
begin
  P := FNum;
  if FDepth <= 8 then
  begin
    if (P > 0) and (FPlanes[0] = nil) then FPlanes[0] := TPlane8.Create(FWidth, FHeight, 0, FScale);
    if (P > 1) and (FPlanes[1] = nil) then
    begin
      if SmallerBuffer then FPlanes[1] := TPlane8.Create(FWidth, FHeight, 0, FScale)
      else FPlanes[1] := TPlane16s.Create(FWidth, FHeight, 0, FScale);
    end;
    if (P > 2) and (FPlanes[2] = nil) then FPlanes[2] := TPlane16s.Create(FWidth, FHeight, 0, FScale);
    if (P > 3) and (FPlanes[3] = nil) then FPlanes[3] := TPlane8.Create(FWidth, FHeight, 0, FScale);
  end
  else
  begin
    if (P > 0) and (FPlanes[0] = nil) then FPlanes[0] := TPlane16u.Create(FWidth, FHeight, 0, FScale);
    if (P > 1) and (FPlanes[1] = nil) then FPlanes[1] := TPlane32s.Create(FWidth, FHeight, 0, FScale);
    if (P > 2) and (FPlanes[2] = nil) then FPlanes[2] := TPlane32s.Create(FWidth, FHeight, 0, FScale);
    if (P > 3) and (FPlanes[3] = nil) then FPlanes[3] := TPlane16u.Create(FWidth, FHeight, 0, FScale);
  end;
  if (P > 4) and (FPlanes[4] = nil) then FPlanes[4] := TPlane8.Create(FWidth, FHeight, 0, FScale);
end;

function TImage.RealInit(SmallerBuffer: Boolean): Boolean;
begin
  try
    AllocPlanes(SmallerBuffer);
  except
    on EOutOfMemory do
    begin
      e_printf('Error: could not allocate enough memory for image buffer.'#10);
      Exit(False);
    end;
  end;
  Result := True;
end;

function TImage.Clone: TImage;
var
  P: Integer;
  R, C: SizeUInt;
  SR, SC: SizeUInt;
begin
  Result := TImage.Create(FScale);
  Result.FWidth := FWidth;
  Result.FHeight := FHeight;
  Result.FMinval := FMinval;
  Result.FMaxval := FMaxval;
  Result.FNum := FNum;
  Result.FScale := FScale;
  Result.FDepth := FDepth;
  Result.Metadata := Copy(Metadata);
  Result.Palette := Palette;
  if PaletteImage <> nil then Result.PaletteImage := PaletteImage.Clone;
  Result.AlphaZeroSpecial := AlphaZeroSpecial;
  Result.FrameDelay := FrameDelay;
  Result.ColBegin := Copy(ColBegin);
  Result.ColEnd := Copy(ColEnd);
  Result.SeenBefore := SeenBefore;
  Result.FullyDecoded := FullyDecoded;
  Result.AllocPlanes(False);
  SR := SCALED(FHeight, FScale);
  SC := SCALED(FWidth, FScale);
  for P := 0 to FNum - 1 do
    for R := 0 to SR - 1 do
      for C := 0 to SC - 1 do
        Result.FPlanes[P].SetPix(R, C, FPlanes[P].GetPix(R, C));
end;

function TImage.CloneDownsampled(NewW, NewH: Integer): TImage;
var
  P: Integer;
  R, C: SizeUInt;
begin
  Result := TImage.Create(0);
  Result.Metadata := Copy(Metadata);
  Result.FWidth := NewW;
  Result.FHeight := NewH;
  Result.FMinval := FMinval;
  Result.FMaxval := FMaxval;
  Result.FNum := FNum;
  Result.FScale := 0;
  Result.FDepth := FDepth;
  Result.Palette := Palette;
  if PaletteImage <> nil then Result.PaletteImage := PaletteImage.Clone;
  Result.AlphaZeroSpecial := AlphaZeroSpecial;
  Result.FrameDelay := FrameDelay;
  SetLength(Result.ColBegin, NewH);
  SetLength(Result.ColEnd, NewH);
  for R := 0 to SizeUInt(NewH) - 1 do
  begin
    Result.ColBegin[R] := 0;
    Result.ColEnd[R] := NewW;
  end;
  Result.SeenBefore := SeenBefore;
  Result.FullyDecoded := FullyDecoded;
  Result.AllocPlanes(False);
  for P := 0 to FNum - 1 do
    for R := 0 to SizeUInt(NewH) - 1 do
      for C := 0 to SizeUInt(NewW) - 1 do
        Result.FPlanes[P].SetPix(R, C, FPlanes[P].GetPix(R * FHeight div SizeUInt(NewH),
          C * FWidth div SizeUInt(NewW)));
end;

function TImage.CloneStrided(const SkipInterpolate: array of Boolean;
  const Zoomlevels: array of Integer): TImage;
var
  P: Integer;
  R, C, ScaledH, ScaledW, StrideRow, StrideCol: SizeUInt;
  ZoomlevelScaled: Integer;
begin
  Result := TImage.Create(FScale);
  Result.Metadata := Copy(Metadata);
  Result.FWidth := FWidth;
  Result.FHeight := FHeight;
  Result.FMinval := FMinval;
  Result.FMaxval := FMaxval;
  Result.FNum := FNum;
  Result.FDepth := FDepth;
  Result.Palette := Palette;
  if PaletteImage <> nil then Result.PaletteImage := PaletteImage.Clone;
  Result.AlphaZeroSpecial := AlphaZeroSpecial;
  Result.FrameDelay := FrameDelay;
  Result.ColBegin := Copy(ColBegin);
  Result.ColEnd := Copy(ColEnd);
  Result.SeenBefore := SeenBefore;
  Result.FullyDecoded := FullyDecoded;
  Result.AllocPlanes(False);
  ScaledH := SCALED(FHeight, FScale);
  ScaledW := SCALED(FWidth, FScale);
  for P := 0 to FNum - 1 do
  begin
    ZoomlevelScaled := Zoomlevels[P] + 1 - 2 * FScale;
    if SkipInterpolate[P] then
    begin
      StrideRow := 1;
      StrideCol := 1;
    end
    else
    begin
      StrideRow := SizeUInt(1) shl ((ZoomlevelScaled + 1) div 2);
      StrideCol := SizeUInt(1) shl (ZoomlevelScaled div 2);
    end;
    R := 0;
    while R < ScaledH do
    begin
      C := 0;
      while C < ScaledW do
      begin
        Result.FPlanes[P].SetPix(R, C, FPlanes[P].GetPix(R, C));
        Inc(C, StrideCol);
      end;
      Inc(R, StrideRow);
    end;
  end;
end;

procedure TImage.NormalizeScale;
var
  P: Integer;
  I: SizeUInt;
begin
  FWidth := SCALED(FWidth, FScale);
  FHeight := SCALED(FHeight, FScale);
  FScale := 0;
  SetLength(ColBegin, FHeight);
  SetLength(ColEnd, FHeight);
  for I := 0 to FHeight - 1 do
  begin
    ColBegin[I] := 0;
    ColEnd[I] := FWidth;
  end;
  for P := 0 to FNum - 1 do
    FPlanes[P].NormalizeScale;
end;

function TImage.UsesAlpha: Boolean;
var
  R, C: SizeUInt;
begin
  if FNum < 4 then Exit(False);
  for R := 0 to FHeight - 1 do
    for C := 0 to FWidth - 1 do
      if GetVal(3, R, C) < (1 shl FDepth) - 1 then Exit(True);
  Result := False;
end;

function TImage.UsesColor: Boolean;
var
  R, C: SizeUInt;
begin
  if FNum < 3 then Exit(False);
  for R := 0 to FHeight - 1 do
    for C := 0 to FWidth - 1 do
      if (GetVal(0, R, C) <> GetVal(1, R, C)) or (GetVal(0, R, C) <> GetVal(2, R, C)) then
        Exit(True);
  Result := False;
end;

procedure TImage.DropAlpha;
begin
  if FNum < 4 then Exit;
  FreeAndNil(FPlanes[3]);
  FNum := 3;
end;

procedure TImage.DropColor;
begin
  if FNum < 2 then Exit;
  FreeAndNil(FPlanes[1]);
  FreeAndNil(FPlanes[2]);
  FNum := 1;
end;

procedure TImage.DropFrameLookbacks;
begin
  FreeAndNil(FPlanes[4]);
  FNum := 4;
end;

procedure TImage.MakeInvisibleRgbBlack;
var
  R, C: SizeUInt;
begin
  if FNum < 4 then Exit;
  UndoMakeConstantPlane(0);
  UndoMakeConstantPlane(1);
  UndoMakeConstantPlane(2);
  for R := 0 to FHeight - 1 do
    for C := 0 to FWidth - 1 do
      if GetVal(3, R, C) = 0 then
      begin
        SetVal(0, R, C, 0);
        SetVal(1, R, C, 0);
        SetVal(2, R, C, 0);
      end;
end;

procedure TImage.MakeConstantPlane(P: Integer; Val: ColorVal);
begin
  if (P > 3) or (P < 0) then Exit;
  FreeAndNil(FPlanes[P]);
  FPlanes[P] := TConstantPlane.Create(Val);
end;

procedure TImage.UndoMakeConstantPlane(P: Integer);
var
  NewP: TGeneralPlane;
  R, C, SR, SC: SizeUInt;
  Val: ColorVal;
begin
  if (P > 3) or (P < 0) or (FPlanes[P] = nil) then Exit;
  if (P = 1) and (FPlanes[P].BytesPerPixel = 1) then
  begin
    NewP := TPlane16s.Create(FWidth, FHeight, 0, FScale);
    SR := SCALED(FHeight, FScale);
    SC := SCALED(FWidth, FScale);
    for R := 0 to SR - 1 do
      for C := 0 to SC - 1 do
        NewP.SetPix(R, C, FPlanes[P].GetPix(R, C));
    FPlanes[P].Free;
    FPlanes[P] := NewP;
    Exit;
  end;
  if not FPlanes[P].IsConstant then Exit;
  Val := GetVal(P, 0, 0);
  FreeAndNil(FPlanes[P]);
  if FDepth <= 8 then
  begin
    if P = 0 then FPlanes[0] := TPlane8.Create(FWidth, FHeight, Val, FScale);
    if P = 1 then FPlanes[1] := TPlane16s.Create(FWidth, FHeight, Val, FScale);
    if P = 2 then FPlanes[2] := TPlane16s.Create(FWidth, FHeight, Val, FScale);
    if P = 3 then FPlanes[3] := TPlane8.Create(FWidth, FHeight, Val, FScale);
  end
  else
  begin
    if P = 0 then FPlanes[0] := TPlane16u.Create(FWidth, FHeight, Val, FScale);
    if P = 1 then FPlanes[1] := TPlane32s.Create(FWidth, FHeight, Val, FScale);
    if P = 2 then FPlanes[2] := TPlane32s.Create(FWidth, FHeight, Val, FScale);
    if P = 3 then FPlanes[3] := TPlane16u.Create(FWidth, FHeight, Val, FScale);
  end;
end;

procedure TImage.EnsureChroma;
begin
  case FNum of
    1:
      begin
        MakeConstantPlane(1, 0);
        MakeConstantPlane(2, 0);
        FNum := 3;
      end;
    2:
      begin
        MakeConstantPlane(2, 0);
        FNum := 3;
      end;
  end;
end;

procedure TImage.EnsureAlpha;
begin
  EnsureChroma;
  if FNum = 3 then
  begin
    MakeConstantPlane(3, 1);
    FNum := 4;
  end;
end;

procedure TImage.EnsureFrameLookbacks;
begin
  if FNum < 5 then
  begin
    EnsureAlpha;
    FPlanes[4] := TPlane8.Create(FWidth, FHeight, 0, FScale);
    FNum := 5;
  end;
end;

function TImage.GetVal(P: Integer; R, C: SizeUInt): ColorVal;
begin
  Result := FPlanes[P].GetPix(R, C);
end;

procedure TImage.SetVal(P: Integer; R, C: SizeUInt; X: ColorVal);
begin
  FPlanes[P].SetPix(R, C, X);
end;

function TImage.GetValZ(P, Z: Integer; RZ, CZ: SizeUInt): ColorVal;
begin
  Result := FPlanes[P].GetPixZ(Z, RZ, CZ);
end;

procedure TImage.SetValZ(P, Z: Integer; RZ, CZ: SizeUInt; X: ColorVal);
begin
  FPlanes[P].SetPixZ(Z, RZ, CZ, X);
end;

function TImage.NumPlanes: Integer;
begin
  Result := FNum;
end;

function TImage.MinVal(P: Integer): ColorVal;
begin
  Result := FMinval;
end;

function TImage.MaxVal(P: Integer): ColorVal;
begin
  Result := FMaxval;
end;

function TImage.Rows: SizeUInt;
begin
  Result := FHeight;
end;

function TImage.Cols: SizeUInt;
begin
  Result := FWidth;
end;

function TImage.GetScale: Integer;
begin
  Result := FScale;
end;

function TImage.ScaledRows: SizeUInt;
begin
  Result := SCALED(FHeight, FScale);
end;

function TImage.ScaledCols: SizeUInt;
begin
  Result := SCALED(FWidth, FScale);
end;

function TImage.RowsZ(Zoomlevel: Integer): SizeUInt;
begin
  if FHeight <= 0 then Exit(0);
  Result := 1 + (FHeight - 1) div ZoomRowPixelSize(Zoomlevel);
end;

function TImage.ColsZ(Zoomlevel: Integer): SizeUInt;
begin
  if FWidth <= 0 then Exit(0);
  Result := 1 + (FWidth - 1) div ZoomColPixelSize(Zoomlevel);
end;

function TImage.Zooms: Integer;
var
  Z: Integer;
begin
  Z := 0;
  while (ZoomRowPixelSize(Z) < FHeight) or (ZoomColPixelSize(Z) < FWidth) do
    Inc(Z);
  Result := Z;
end;

function TImage.GetPlane(P: Integer): TGeneralPlane;
begin
  Result := FPlanes[P];
end;

function TImage.GetFRA(R, C: SizeUInt): ColorVal;
begin
  Result := FPlanes[4].GetPix(R, C);
end;

function TImage.GetFRAZ(Z: Integer; R, C: SizeUInt): ColorVal;
begin
  Result := FPlanes[4].GetPixZ(Z, R, C);
end;

function TImage.GetDepth: Integer;
begin
  Result := FDepth;
end;

function TImage.Checksum: Cardinal;
var
  Crc: Cardinal;
  P: Integer;
begin
  Crc := Cardinal(FWidth shl 16) + Cardinal(FHeight);
  for P := 0 to FNum - 1 do
    Crc := FPlanes[P].ComputeCRC32(Crc);
  Result := Crc;
end;

procedure TImage.AbortDecoding;
begin
  FWidth := 0;
end;

function TImage.HasMetadata(const ChunkName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Metadata) do
    if Metadata[I].Name = ChunkName then Exit(True);
  Result := False;
end;

procedure FreeImages(var Imgs: TImages);
var
  I: Integer;
begin
  for I := 0 to High(Imgs) do
    Imgs[I].Free;
  SetLength(Imgs, 0);
end;

end.
