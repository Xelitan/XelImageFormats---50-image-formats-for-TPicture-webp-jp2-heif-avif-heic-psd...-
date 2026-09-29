// FLIF - Free Lossless Image Format -- Free Pascal port
// Colour range interface.
// Corresponds to: src/image/color_range.hpp, src/image/color_range.cpp
unit flif_colorrange;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  flif_types, flif_image;

type
  PrevPlanes = array of ColorVal;

  TColorRanges = class
  public
    function NumPlanes: Integer; virtual; abstract;
    function MinV(P: Integer): ColorVal; virtual; abstract;
    function MaxV(P: Integer): ColorVal; virtual; abstract;
    procedure MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal); virtual;
    procedure Snap(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal;
      var V: ColorVal); virtual;
    function IsStatic: Boolean; virtual;
    function Previous: TColorRanges; virtual;
  end;

  TStaticColorRanges = class(TColorRanges)
  protected
    FRanges: Ranges;
  public
    constructor Create(const R: Ranges);
    function NumPlanes: Integer; override;
    function MinV(P: Integer): ColorVal; override;
    function MaxV(P: Integer): ColorVal; override;
  end;

  TDupColorRanges = class(TColorRanges)
  protected
    FRanges: TColorRanges;
  public
    constructor Create(ARanges: TColorRanges);
    function NumPlanes: Integer; override;
    function MinV(P: Integer): ColorVal; override;
    function MaxV(P: Integer): ColorVal; override;
    procedure MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal); override;
    procedure Snap(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal;
      var V: ColorVal); override;
    function IsStatic: Boolean; override;
    function Previous: TColorRanges; override;
  end;

function GetRanges(Image: TImage): TColorRanges;
function ComputeGreys(R: TColorRanges): TColorValArray;

implementation

// TColorRanges

procedure TColorRanges.MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal);
begin
  MinV_ := MinV(P);
  MaxV_ := MaxV(P);
end;

procedure TColorRanges.Snap(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal;
  var V: ColorVal);
begin
  MinMax(P, PP, MinV_, MaxV_);
  if MinV_ > MaxV_ then
    MaxV_ := MinV_;      // only on malicious/corrupt input
  if V > MaxV_ then V := MaxV_;
  if V < MinV_ then V := MinV_;
end;

function TColorRanges.IsStatic: Boolean;
begin
  Result := True;
end;

function TColorRanges.Previous: TColorRanges;
begin
  Result := nil;
end;

// TStaticColorRanges

constructor TStaticColorRanges.Create(const R: Ranges);
begin
  inherited Create;
  FRanges := Copy(R);
end;

function TStaticColorRanges.NumPlanes: Integer;
begin
  Result := Length(FRanges);
end;

function TStaticColorRanges.MinV(P: Integer): ColorVal;
begin
  if P >= Length(FRanges) then Exit(0);
  Result := FRanges[P].First;
end;

function TStaticColorRanges.MaxV(P: Integer): ColorVal;
begin
  if P >= Length(FRanges) then Exit(0);
  Result := FRanges[P].Second;
end;

// TDupColorRanges

constructor TDupColorRanges.Create(ARanges: TColorRanges);
begin
  inherited Create;
  FRanges := ARanges;
end;

function TDupColorRanges.NumPlanes: Integer;
begin
  Result := FRanges.NumPlanes;
end;

function TDupColorRanges.MinV(P: Integer): ColorVal;
begin
  Result := FRanges.MinV(P);
end;

function TDupColorRanges.MaxV(P: Integer): ColorVal;
begin
  Result := FRanges.MaxV(P);
end;

procedure TDupColorRanges.MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal);
begin
  FRanges.MinMax(P, PP, MinV_, MaxV_);
end;

procedure TDupColorRanges.Snap(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal;
  var V: ColorVal);
begin
  FRanges.Snap(P, PP, MinV_, MaxV_, V);
end;

function TDupColorRanges.IsStatic: Boolean;
begin
  Result := FRanges.IsStatic;
end;

function TDupColorRanges.Previous: TColorRanges;
begin
  Result := FRanges;
end;

// helpers

function GetRanges(Image: TImage): TColorRanges;
var
  R: Ranges;
  P: Integer;
begin
  SetLength(R, Image.NumPlanes);
  for P := 0 to Image.NumPlanes - 1 do
    R[P] := MakeRange(Image.MinVal(P), Image.MaxVal(P));
  Result := TStaticColorRanges.Create(R);
end;

function ComputeGreys(R: TColorRanges): TColorValArray;
var
  P: Integer;
begin
  SetLength(Result, R.NumPlanes);
  for P := 0 to R.NumPlanes - 1 do
    Result[P] := (R.MinV(P) + R.MaxV(P)) div 2;
end;

end.
