// FLIF - Free Lossless Image Format -- Free Pascal port
// All bitstream transformations and the colour-range classes they introduce.
// Corresponds to: src/transform/*.hpp, src/transform/factory.cpp
unit flif_transform;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, flif_types, flif_image, flif_colorrange, flif_rac, flif_chance,
  flif_symbol;

type
  TTransform = class
  public
    function Init(SrcRanges: TColorRanges): Boolean; virtual;
    function UndoRedoDuringDecode: Boolean; virtual;
    procedure Configure(Setting: Integer); virtual;
    function Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean; virtual;
    function Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean; virtual;
    procedure Save(SrcRanges: TColorRanges; Rac: TRacOut); virtual;
    procedure Data(const Imgs: TImages); virtual;
    function Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges; virtual;
    procedure InvData(const Imgs: TImages; StrideCol: Cardinal = 1;
      StrideRow: Cardinal = 1); virtual;
    function IsPaletteTransform: Boolean; virtual;
  end;

  TTransformList = array of TTransform;

function CreateTransform(const Desc: string): TTransform;

implementation

// =====================================================================
// base class
// =====================================================================

function TTransform.Init(SrcRanges: TColorRanges): Boolean;
begin
  Result := True;
end;

function TTransform.UndoRedoDuringDecode: Boolean;
begin
  Result := True;
end;

procedure TTransform.Configure(Setting: Integer);
begin
end;

function TTransform.Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean;
begin
  Result := True;
end;

function TTransform.Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean;
begin
  Result := True;
end;

procedure TTransform.Save(SrcRanges: TColorRanges; Rac: TRacOut);
begin
end;

procedure TTransform.Data(const Imgs: TImages);
begin
end;

function TTransform.Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges;
begin
  Result := TDupColorRanges.Create(SrcRanges);
end;

procedure TTransform.InvData(const Imgs: TImages; StrideCol: Cardinal; StrideRow: Cardinal);
begin
end;

function TTransform.IsPaletteTransform: Boolean;
begin
  Result := False;
end;

// =====================================================================
// YCoCg
// =====================================================================

function GetMinY(Par: Integer): ColorVal; inline;
begin
  Result := 0;
end;

function GetMaxY(Par: Integer): ColorVal; inline;
begin
  Result := Par * 4 - 1;
end;

function GetMinCo(Par: Integer; Y: ColorVal): ColorVal;
begin
  if Y < Par - 1 then
    Result := -3 - 4 * Y
  else if Y >= 3 * Par then
    Result := 4 * (1 + Y - 4 * Par)
  else
    Result := -4 * Par + 1;
end;

function GetMaxCo(Par: Integer; Y: ColorVal): ColorVal;
begin
  if Y < Par - 1 then
    Result := 3 + 4 * Y
  else if Y >= 3 * Par then
    Result := 4 * Par - 4 * (1 + Y - 3 * Par)
  else
    Result := 4 * Par - 1;
end;

function GetMinCg(Par: Integer; Y, Co: ColorVal): ColorVal;
begin
  if Co < GetMinCo(Par, Y) then Exit(8 * Par);
  if Co > GetMaxCo(Par, Y) then Exit(8 * Par);
  if Y < Par - 1 then
    Result := -(2 * Y + 1)
  else if Y >= 3 * Par then
    Result := -(2 * (4 * Par - 1 - Y) - ((1 + Abs(Co)) div 2) * 2)
  else
    Result := -MinI(2 * Par - 1 + (Y - Par + 1) * 2,
                    2 * Par + (3 * Par - 1 - Y) * 2 - ((1 + Abs(Co)) div 2) * 2);
end;

function GetMaxCg(Par: Integer; Y, Co: ColorVal): ColorVal;
begin
  if Co < GetMinCo(Par, Y) then Exit(-8 * Par);
  if Co > GetMaxCo(Par, Y) then Exit(-8 * Par);
  if Y < Par - 1 then
    Result := 1 + 2 * Y - (Abs(Co) div 2) * 2
  else if Y >= 3 * Par then
    Result := 2 * (4 * Par - 1 - Y)
  else
    Result := -MaxI(-4 * Par + (1 + Y - 2 * Par) * 2,
                    -2 * Par - (Y - Par) * 2 - 1 + (Abs(Co) div 2) * 2);
end;

type
  TColorRangesYCoCg = class(TColorRanges)
  protected
    FPar: Integer;
    FRanges: TColorRanges;
  public
    constructor Create(APar: Integer; ARanges: TColorRanges);
    function IsStatic: Boolean; override;
    function NumPlanes: Integer; override;
    function MinV(P: Integer): ColorVal; override;
    function MaxV(P: Integer): ColorVal; override;
    procedure MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal); override;
  end;

constructor TColorRangesYCoCg.Create(APar: Integer; ARanges: TColorRanges);
begin
  inherited Create;
  FPar := APar;
  FRanges := ARanges;
end;

function TColorRangesYCoCg.IsStatic: Boolean;
begin
  Result := False;
end;

function TColorRangesYCoCg.NumPlanes: Integer;
begin
  Result := FRanges.NumPlanes;
end;

function TColorRangesYCoCg.MinV(P: Integer): ColorVal;
begin
  case P of
    0: Result := 0;
    1: Result := -4 * FPar + 1;
    2: Result := -4 * FPar + 1;
  else
    Result := FRanges.MinV(P);
  end;
end;

function TColorRangesYCoCg.MaxV(P: Integer): ColorVal;
begin
  case P of
    0: Result := 4 * FPar - 1;
    1: Result := 4 * FPar - 1;
    2: Result := 4 * FPar - 1;
  else
    Result := FRanges.MaxV(P);
  end;
end;

procedure TColorRangesYCoCg.MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal);
begin
  if P = 1 then
  begin
    MinV_ := GetMinCo(FPar, PP[0]);
    MaxV_ := GetMaxCo(FPar, PP[0]);
  end
  else if P = 2 then
  begin
    MinV_ := GetMinCg(FPar, PP[0], PP[1]);
    MaxV_ := GetMaxCg(FPar, PP[0], PP[1]);
  end
  else if P = 0 then
  begin
    MinV_ := 0;
    MaxV_ := GetMaxY(FPar);
  end
  else
    FRanges.MinMax(P, PP, MinV_, MaxV_);
end;

type
  TTransformYCoCg = class(TTransform)
  protected
    FPar: Integer;
    FRanges: TColorRanges;
  public
    function Init(SrcRanges: TColorRanges): Boolean; override;
    function Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges; override;
    function Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean; override;
    procedure Data(const Imgs: TImages); override;
    procedure InvData(const Imgs: TImages; StrideCol: Cardinal = 1;
      StrideRow: Cardinal = 1); override;
  end;

function TTransformYCoCg.Init(SrcRanges: TColorRanges): Boolean;
var
  M: Integer;
begin
  if SrcRanges.NumPlanes < 3 then Exit(False);
  if (SrcRanges.MinV(0) < 0) or (SrcRanges.MinV(1) < 0) or (SrcRanges.MinV(2) < 0) then Exit(False);
  if (SrcRanges.MinV(0) = SrcRanges.MaxV(0)) or (SrcRanges.MinV(1) = SrcRanges.MaxV(1)) or
     (SrcRanges.MinV(2) = SrcRanges.MaxV(2)) then Exit(False);
  M := MaxI(MaxI(SrcRanges.MaxV(0), SrcRanges.MaxV(1)), SrcRanges.MaxV(2));
  FPar := M div 4 + 1;
  FRanges := SrcRanges;
  Result := True;
end;

function TTransformYCoCg.Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges;
begin
  Result := TColorRangesYCoCg.Create(FPar, SrcRanges);
end;

function TTransformYCoCg.Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean;
begin
  if Imgs[0].Palette then Exit(False);
  Result := True;
end;

procedure TTransformYCoCg.Data(const Imgs: TImages);
var
  I: Integer;
  R, C: Cardinal;
  Rd, G, B, Y, Co, Cg: ColorVal;
  Img: TImage;
begin
  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    for R := 0 to Img.Rows - 1 do
      for C := 0 to Img.Cols - 1 do
      begin
        Rd := Img.GetVal(0, R, C);
        G := Img.GetVal(1, R, C);
        B := Img.GetVal(2, R, C);
        Y := (((Rd + B) shr 1) + G) shr 1;
        Co := Rd - B;
        Cg := G - ((Rd + B) shr 1);
        Img.SetVal(0, R, C, Y);
        Img.SetVal(1, R, C, Co);
        Img.SetVal(2, R, C, Cg);
      end;
  end;
end;

procedure TTransformYCoCg.InvData(const Imgs: TImages; StrideCol: Cardinal; StrideRow: Cardinal);
var
  I: Integer;
  R, C, ScaledRows, ScaledCols: Cardinal;
  Rd, G, B, Y, Co, Cg: ColorVal;
  MaxV: array[0..2] of ColorVal;
  Img: TImage;
begin
  MaxV[0] := FRanges.MaxV(0);
  MaxV[1] := FRanges.MaxV(1);
  MaxV[2] := FRanges.MaxV(2);
  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    Img.UndoMakeConstantPlane(0);
    Img.UndoMakeConstantPlane(1);
    Img.UndoMakeConstantPlane(2);
    ScaledRows := Img.ScaledRows;
    ScaledCols := Img.ScaledCols;
    R := 0;
    while R < ScaledRows do
    begin
      C := 0;
      while C < ScaledCols do
      begin
        Y := Img.GetVal(0, R, C);
        Co := Img.GetVal(1, R, C);
        Cg := Img.GetVal(2, R, C);
        G := Y - SarLongint(-Cg, 1);
        B := Y + SarLongint(1 - Cg, 1) - SarLongint(Co, 1);
        Rd := Co + B;
        if Rd < 0 then Rd := 0 else if Rd > MaxV[0] then Rd := MaxV[0];
        if G < 0 then G := 0 else if G > MaxV[1] then G := MaxV[1];
        if B < 0 then B := 0 else if B > MaxV[2] then B := MaxV[2];
        Img.SetVal(0, R, C, Rd);
        Img.SetVal(1, R, C, G);
        Img.SetVal(2, R, C, B);
        Inc(C, StrideCol);
      end;
      Inc(R, StrideRow);
    end;
  end;
end;

// =====================================================================
// Bounds
// =====================================================================

type
  TColorRangesBounds = class(TColorRanges)
  protected
    FBounds: Ranges;
    FRanges: TColorRanges;
  public
    constructor Create(const ABounds: Ranges; ARanges: TColorRanges);
    function IsStatic: Boolean; override;
    function NumPlanes: Integer; override;
    function MinV(P: Integer): ColorVal; override;
    function MaxV(P: Integer): ColorVal; override;
    procedure Snap(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal;
      var V: ColorVal); override;
    procedure MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal); override;
  end;

constructor TColorRangesBounds.Create(const ABounds: Ranges; ARanges: TColorRanges);
begin
  inherited Create;
  FBounds := Copy(ABounds);
  FRanges := ARanges;
end;

function TColorRangesBounds.IsStatic: Boolean;
begin
  Result := False;
end;

function TColorRangesBounds.NumPlanes: Integer;
begin
  Result := Length(FBounds);
end;

function TColorRangesBounds.MinV(P: Integer): ColorVal;
begin
  Result := MaxI(FRanges.MinV(P), FBounds[P].First);
end;

function TColorRangesBounds.MaxV(P: Integer): ColorVal;
begin
  Result := MinI(FRanges.MaxV(P), FBounds[P].Second);
end;

procedure TColorRangesBounds.Snap(P: Integer; const PP: PrevPlanes;
  out MinV_, MaxV_: ColorVal; var V: ColorVal);
begin
  if (P = 0) or (P = 3) then
  begin
    MinV_ := FBounds[P].First;
    MaxV_ := FBounds[P].Second;
  end
  else
  begin
    FRanges.Snap(P, PP, MinV_, MaxV_, V);
    if MinV_ < FBounds[P].First then MinV_ := FBounds[P].First;
    if MaxV_ > FBounds[P].Second then MaxV_ := FBounds[P].Second;
    if MinV_ > MaxV_ then
    begin
      MinV_ := FBounds[P].First;
      MaxV_ := FBounds[P].Second;
    end;
  end;
  if V > MaxV_ then V := MaxV_;
  if V < MinV_ then V := MinV_;
end;

procedure TColorRangesBounds.MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal);
begin
  if (P = 0) or (P = 3) then
  begin
    MinV_ := FBounds[P].First;
    MaxV_ := FBounds[P].Second;
    Exit;
  end;
  FRanges.MinMax(P, PP, MinV_, MaxV_);
  if MinV_ < FBounds[P].First then MinV_ := FBounds[P].First;
  if MaxV_ > FBounds[P].Second then MaxV_ := FBounds[P].Second;
  if MinV_ > MaxV_ then
  begin
    MinV_ := FBounds[P].First;
    MaxV_ := FBounds[P].Second;
  end;
end;

type
  TTransformBounds = class(TTransform)
  protected
    FBounds: Ranges;
  public
    function UndoRedoDuringDecode: Boolean; override;
    function Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges; override;
    function Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean; override;
    procedure Save(SrcRanges: TColorRanges; Rac: TRacOut); override;
    function Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean; override;
  end;

function TTransformBounds.UndoRedoDuringDecode: Boolean;
begin
  Result := False;
end;

function TTransformBounds.Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges;
begin
  if SrcRanges.IsStatic then
    Result := TStaticColorRanges.Create(FBounds)
  else
    Result := TColorRangesBounds.Create(FBounds, SrcRanges);
end;

function TTransformBounds.Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean;
var
  Coder: TSimpleSymbolCoder;
  P, N: Integer;
  MinV, MaxV: ColorVal;
begin
  if SrcRanges.NumPlanes > 4 then Exit(False);
  Coder := TSimpleSymbolCoder.Create(Rac, nil, 18);
  try
    SetLength(FBounds, 0);
    for P := 0 to SrcRanges.NumPlanes - 1 do
    begin
      MinV := Coder.ReadInt2(SrcRanges.MinV(P), SrcRanges.MaxV(P));
      MaxV := Coder.ReadInt2(MinV, SrcRanges.MaxV(P));
      if MinV > MaxV then Exit(False);
      if MinV < SrcRanges.MinV(P) then Exit(False);
      if MaxV > SrcRanges.MaxV(P) then Exit(False);
      N := Length(FBounds);
      SetLength(FBounds, N + 1);
      FBounds[N] := MakeRange(MinV, MaxV);
      v_printf(5, Format('[%d:%d..%d]', [P, MinV, MaxV]));
    end;
    Result := True;
  finally
    Coder.Free;
  end;
end;

procedure TTransformBounds.Save(SrcRanges: TColorRanges; Rac: TRacOut);
var
  Coder: TSimpleSymbolCoder;
  P: Integer;
  MinV, MaxV: ColorVal;
begin
  Coder := TSimpleSymbolCoder.Create(nil, Rac, 18);
  try
    for P := 0 to SrcRanges.NumPlanes - 1 do
    begin
      MinV := FBounds[P].First;
      MaxV := FBounds[P].Second;
      Coder.WriteInt2(SrcRanges.MinV(P), SrcRanges.MaxV(P), MinV);
      Coder.WriteInt2(MinV, SrcRanges.MaxV(P), MaxV);
      v_printf(5, Format('[%d:%d..%d]', [P, MinV, MaxV]));
    end;
  finally
    Coder.Free;
  end;
end;

function TTransformBounds.Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean;
var
  TrivialBounds: Boolean;
  NumP, P, I, N: Integer;
  MinV, MaxV, V: ColorVal;
  R, C: Cardinal;
  Img: TImage;
begin
  if Imgs[0].Palette then Exit(False);
  SetLength(FBounds, 0);
  TrivialBounds := True;
  NumP := SrcRanges.NumPlanes;
  for P := 0 to NumP - 1 do
  begin
    MinV := SrcRanges.MaxV(P);
    MaxV := SrcRanges.MinV(P);
    for I := 0 to High(Imgs) do
    begin
      Img := Imgs[I];
      for R := 0 to Img.Rows - 1 do
        for C := 0 to Img.Cols - 1 do
        begin
          if Img.AlphaZeroSpecial and (NumP > 3) and (P < 3) and (Img.GetVal(3, R, C) = 0) then
            Continue;
          V := Img.GetVal(P, R, C);
          if V < MinV then MinV := V;
          if V > MaxV then MaxV := V;
        end;
    end;
    if MinV > MaxV then
    begin
      MinV := (MinV + MaxV) div 2;
      MaxV := MinV;
    end;
    N := Length(FBounds);
    SetLength(FBounds, N + 1);
    FBounds[N] := MakeRange(MinV, MaxV);
    if MinV > SrcRanges.MinV(P) then TrivialBounds := False;
    if MaxV < SrcRanges.MaxV(P) then TrivialBounds := False;
  end;
  Result := not TrivialBounds;
end;

// =====================================================================
// PermutePlanes
// =====================================================================

type
  TIntArray = array of Integer;

  TColorRangesPermute = class(TColorRanges)
  protected
    FPermutation: TIntArray;
    FRanges: TColorRanges;
  public
    constructor Create(const Perm: TIntArray; ARanges: TColorRanges);
    function IsStatic: Boolean; override;
    function NumPlanes: Integer; override;
    function MinV(P: Integer): ColorVal; override;
    function MaxV(P: Integer): ColorVal; override;
  end;

  TColorRangesPermuteSubtract = class(TColorRanges)
  protected
    FPermutation: TIntArray;
    FRanges: TColorRanges;
  public
    constructor Create(const Perm: TIntArray; ARanges: TColorRanges);
    function IsStatic: Boolean; override;
    function NumPlanes: Integer; override;
    function MinV(P: Integer): ColorVal; override;
    function MaxV(P: Integer): ColorVal; override;
    procedure MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal); override;
  end;

constructor TColorRangesPermute.Create(const Perm: TIntArray; ARanges: TColorRanges);
begin
  inherited Create;
  FPermutation := Copy(Perm);
  FRanges := ARanges;
end;

function TColorRangesPermute.IsStatic: Boolean;
begin
  Result := False;
end;

function TColorRangesPermute.NumPlanes: Integer;
begin
  Result := FRanges.NumPlanes;
end;

function TColorRangesPermute.MinV(P: Integer): ColorVal;
begin
  Result := FRanges.MinV(FPermutation[P]);
end;

function TColorRangesPermute.MaxV(P: Integer): ColorVal;
begin
  Result := FRanges.MaxV(FPermutation[P]);
end;

constructor TColorRangesPermuteSubtract.Create(const Perm: TIntArray; ARanges: TColorRanges);
begin
  inherited Create;
  FPermutation := Copy(Perm);
  FRanges := ARanges;
end;

function TColorRangesPermuteSubtract.IsStatic: Boolean;
begin
  Result := False;
end;

function TColorRangesPermuteSubtract.NumPlanes: Integer;
begin
  Result := FRanges.NumPlanes;
end;

function TColorRangesPermuteSubtract.MinV(P: Integer): ColorVal;
begin
  if (P = 0) or (P > 2) then
    Result := FRanges.MinV(FPermutation[P])
  else
    Result := FRanges.MinV(FPermutation[P]) - FRanges.MaxV(FPermutation[0]);
end;

function TColorRangesPermuteSubtract.MaxV(P: Integer): ColorVal;
begin
  if (P = 0) or (P > 2) then
    Result := FRanges.MaxV(FPermutation[P])
  else
    Result := FRanges.MaxV(FPermutation[P]) - FRanges.MinV(FPermutation[0]);
end;

procedure TColorRangesPermuteSubtract.MinMax(P: Integer; const PP: PrevPlanes;
  out MinV_, MaxV_: ColorVal);
begin
  if (P = 0) or (P > 2) then
  begin
    MinV_ := MinV(P);
    MaxV_ := MaxV(P);
  end
  else
  begin
    MinV_ := FRanges.MinV(FPermutation[P]) - PP[0];
    MaxV_ := FRanges.MaxV(FPermutation[P]) - PP[0];
  end;
end;

type
  TTransformPermute = class(TTransform)
  protected
    FPermutation: TIntArray;
    FRanges: TColorRanges;
    FSubtract: Boolean;
  public
    function Init(SrcRanges: TColorRanges): Boolean; override;
    function Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges; override;
    procedure Configure(Setting: Integer); override;
    function Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean; override;
    procedure Data(const Imgs: TImages); override;
    procedure Save(SrcRanges: TColorRanges; Rac: TRacOut); override;
    function Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean; override;
    procedure InvData(const Imgs: TImages; StrideCol: Cardinal = 1;
      StrideRow: Cardinal = 1); override;
  end;

function TTransformPermute.Init(SrcRanges: TColorRanges): Boolean;
begin
  if SrcRanges.NumPlanes < 3 then Exit(False);
  if (SrcRanges.MinV(0) < 0) or (SrcRanges.MinV(1) < 0) or (SrcRanges.MinV(2) < 0) then Exit(False);
  SetLength(FPermutation, SrcRanges.NumPlanes);
  FRanges := SrcRanges;
  Result := True;
end;

function TTransformPermute.Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges;
begin
  if FSubtract then
    Result := TColorRangesPermuteSubtract.Create(FPermutation, SrcRanges)
  else
    Result := TColorRangesPermute.Create(FPermutation, SrcRanges);
end;

procedure TTransformPermute.Configure(Setting: Integer);
begin
  FSubtract := Setting <> 0;
end;

function TTransformPermute.Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean;
const
  Perm: array[0..4] of Integer = (1, 0, 2, 3, 4);
var
  P: Integer;
begin
  if Imgs[0].Palette then Exit(False);
  for P := 0 to SrcRanges.NumPlanes - 1 do
    FPermutation[P] := Perm[P];
  Result := True;
end;

procedure TTransformPermute.Data(const Imgs: TImages);
var
  Pixel: array[0..4] of ColorVal;
  I, P: Integer;
  R, C: Cardinal;
  Img: TImage;
begin
  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    for R := 0 to Img.Rows - 1 do
      for C := 0 to Img.Cols - 1 do
      begin
        for P := 0 to FRanges.NumPlanes - 1 do Pixel[P] := Img.GetVal(P, R, C);
        Img.SetVal(0, R, C, Pixel[FPermutation[0]]);
        if not FSubtract then
        begin
          for P := 1 to FRanges.NumPlanes - 1 do
            Img.SetVal(P, R, C, Pixel[FPermutation[P]]);
        end
        else
        begin
          for P := 1 to MinI(2, FRanges.NumPlanes - 1) do
            Img.SetVal(P, R, C, Pixel[FPermutation[P]] - Pixel[FPermutation[0]]);
          for P := 3 to FRanges.NumPlanes - 1 do
            Img.SetVal(P, R, C, Pixel[FPermutation[P]]);
        end;
      end;
  end;
end;

procedure TTransformPermute.Save(SrcRanges: TColorRanges; Rac: TRacOut);
var
  Coder: TSimpleSymbolCoder;
  P: Integer;
begin
  Coder := TSimpleSymbolCoder.Create(nil, Rac, 18);
  try
    Coder.WriteInt2(0, 1, Ord(FSubtract));
    if FSubtract then v_printf(4, 'Subtract');
    for P := 0 to SrcRanges.NumPlanes - 1 do
    begin
      Coder.WriteInt2(0, SrcRanges.NumPlanes - 1, FPermutation[P]);
      v_printf(5, Format('[%d->%d]', [P, FPermutation[P]]));
    end;
  finally
    Coder.Free;
  end;
end;

function TTransformPermute.Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean;
var
  Coder: TSimpleSymbolCoder;
  P: Integer;
  FromA, ToA: array[0..3] of Boolean;
begin
  Coder := TSimpleSymbolCoder.Create(Rac, nil, 18);
  try
    FSubtract := Coder.ReadInt2(0, 1) <> 0;
    if FSubtract then v_printf(4, 'Subtract');
    for P := 0 to 3 do begin FromA[P] := False; ToA[P] := False; end;
    for P := 0 to SrcRanges.NumPlanes - 1 do
    begin
      FPermutation[P] := Coder.ReadInt2(0, SrcRanges.NumPlanes - 1);
      v_printf(5, Format('[%d->%d]', [P, FPermutation[P]]));
      FromA[P] := True;
      ToA[FPermutation[P]] := True;
    end;
    for P := 0 to SrcRanges.NumPlanes - 1 do
      if (not FromA[P]) or (not ToA[P]) then
      begin
        e_printf(#10'Not a valid permutation!'#10);
        Exit(False);
      end;
    Result := True;
  finally
    Coder.Free;
  end;
end;

procedure TTransformPermute.InvData(const Imgs: TImages; StrideCol: Cardinal; StrideRow: Cardinal);
var
  Pixel: array[0..4] of ColorVal;
  I, P: Integer;
  R, C, ScaledRows, ScaledCols: Cardinal;
  V: ColorVal;
  Img: TImage;
begin
  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    ScaledRows := Img.ScaledRows;
    ScaledCols := Img.ScaledCols;
    for P := 0 to FRanges.NumPlanes - 1 do Img.UndoMakeConstantPlane(P);
    R := 0;
    while R < ScaledRows do
    begin
      C := 0;
      while C < ScaledCols do
      begin
        for P := 0 to FRanges.NumPlanes - 1 do Pixel[P] := Img.GetVal(P, R, C);
        for P := 0 to FRanges.NumPlanes - 1 do Img.SetVal(FPermutation[P], R, C, Pixel[P]);
        Img.SetVal(FPermutation[0], R, C, Pixel[0]);
        if not FSubtract then
        begin
          for P := 1 to FRanges.NumPlanes - 1 do
            Img.SetVal(FPermutation[P], R, C, Pixel[P]);
        end
        else
        begin
          for P := 1 to MinI(2, FRanges.NumPlanes - 1) do
          begin
            V := Pixel[P] + Pixel[0];
            if V > FRanges.MaxV(FPermutation[P]) then V := FRanges.MaxV(FPermutation[P])
            else if V < FRanges.MinV(FPermutation[P]) then V := FRanges.MinV(FPermutation[P]);
            Img.SetVal(FPermutation[P], R, C, V);
          end;
          for P := 3 to FRanges.NumPlanes - 1 do
            Img.SetVal(FPermutation[P], R, C, Pixel[P]);
        end;
        Inc(C, StrideCol);
      end;
      Inc(R, StrideRow);
    end;
  end;
end;

// =====================================================================
// Channel_Compact (palette_C)
// =====================================================================

type
  TColorRangesPaletteC = class(TColorRanges)
  protected
    FRanges: TColorRanges;
    FNbColors: array[0..3] of Integer;
  public
    constructor Create(ARanges: TColorRanges; const Nb: array of Integer);
    function IsStatic: Boolean; override;
    function NumPlanes: Integer; override;
    function MinV(P: Integer): ColorVal; override;
    function MaxV(P: Integer): ColorVal; override;
    procedure MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal); override;
  end;

constructor TColorRangesPaletteC.Create(ARanges: TColorRanges; const Nb: array of Integer);
var
  I: Integer;
begin
  inherited Create;
  FRanges := ARanges;
  for I := 0 to 3 do FNbColors[I] := Nb[I];
end;

function TColorRangesPaletteC.IsStatic: Boolean;
begin
  Result := True;
end;

function TColorRangesPaletteC.NumPlanes: Integer;
begin
  Result := FRanges.NumPlanes;
end;

function TColorRangesPaletteC.MinV(P: Integer): ColorVal;
begin
  Result := 0;
end;

function TColorRangesPaletteC.MaxV(P: Integer): ColorVal;
begin
  Result := FNbColors[P];
end;

procedure TColorRangesPaletteC.MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal);
begin
  MinV_ := 0;
  MaxV_ := FNbColors[P];
end;

type
  TTransformPaletteC = class(TTransform)
  protected
    FCPalette: array[0..3] of TColorValArray;
    FCPaletteInv: array[0..3] of TColorValArray;
  public
    function Init(SrcRanges: TColorRanges): Boolean; override;
    function Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges; override;
    procedure InvData(const Imgs: TImages; StrideCol: Cardinal = 1;
      StrideRow: Cardinal = 1); override;
    function Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean; override;
    procedure Data(const Imgs: TImages); override;
    procedure Save(SrcRanges: TColorRanges; Rac: TRacOut); override;
    function Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean; override;
  end;

function TTransformPaletteC.Init(SrcRanges: TColorRanges): Boolean;
begin
  if SrcRanges.NumPlanes > 4 then Exit(False);
  Result := True;
end;

function TTransformPaletteC.Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges;
var
  Nb: array[0..3] of Integer;
  I: Integer;
begin
  for I := 0 to 3 do Nb[I] := 0;
  v_printf(4, '[');
  for I := 0 to SrcRanges.NumPlanes - 1 do
  begin
    Nb[I] := Length(FCPalette[I]) - 1;
    if I > 0 then v_printf(4, ',');
    v_printf(4, IntToStr(Nb[I]));
  end;
  v_printf(4, ']');
  Result := TColorRangesPaletteC.Create(SrcRanges, Nb);
end;

procedure TTransformPaletteC.InvData(const Imgs: TImages; StrideCol: Cardinal; StrideRow: Cardinal);
var
  I, P, PaletteSize, PV: Integer;
  R, C, ScaledRows, ScaledCols: Cardinal;
  Img: TImage;
  Plane: TGeneralPlane;
begin
  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    ScaledRows := Img.ScaledRows;
    ScaledCols := Img.ScaledCols;
    for P := 0 to Img.NumPlanes - 1 do
    begin
      PaletteSize := Length(FCPalette[P]);
      Img.UndoMakeConstantPlane(P);
      Plane := Img.GetPlane(P);
      for R := 0 to ScaledRows - 1 do
        for C := 0 to ScaledCols - 1 do
        begin
          PV := Plane.GetPix(R, C);
          if (PV < 0) or (PV >= PaletteSize) then PV := 0;
          Plane.SetPix(R, C, FCPalette[P][PV]);
        end;
    end;
  end;
end;

function TTransformPaletteC.Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean;
var
  Present: array of Boolean;
  NonTrivial: Boolean;
  P, I, N, Cnt: Integer;
  R, C: Cardinal;
  Img: TImage;
  Prev, V: ColorVal;
begin
  if Imgs[0].Palette then Exit(False);
  NonTrivial := False;
  for P := 0 to SrcRanges.NumPlanes - 1 do
  begin
    SetLength(Present, SrcRanges.MaxV(P) + 2);
    for I := 0 to High(Present) do Present[I] := False;
    if P = 3 then Present[0] := True;   // ensure A=0 stays A=0
    for I := 0 to High(Imgs) do
    begin
      Img := Imgs[I];
      for R := 0 to Img.Rows - 1 do
        for C := 0 to Img.Cols - 1 do
          Present[Img.GetVal(P, R, C)] := True;
    end;
    Cnt := 0;
    for I := 0 to High(Present) do if Present[I] then Inc(Cnt);
    // if on all channels less than 10% of the range can be compacted away,
    // it's probably a bad idea to do the compaction
    if Cnt * 10 <= 9 * (SrcRanges.MaxV(P) - SrcRanges.MinV(P)) then NonTrivial := True;
    SetLength(FCPalette[P], 0);
    if Cnt < 10 then
    begin
      // add up to 10 shades of grey
      Prev := 0;
      for I := 0 to High(Present) do
        if Present[I] then
        begin
          V := I;
          if V > Prev + 1 then
          begin
            N := Length(FCPalette[P]);
            SetLength(FCPalette[P], N + 1);
            FCPalette[P][N] := (V + Prev) div 2;
          end;
          N := Length(FCPalette[P]);
          SetLength(FCPalette[P], N + 1);
          FCPalette[P][N] := V;
          Prev := V;
          NonTrivial := True;
        end;
    end
    else
    begin
      SetLength(FCPalette[P], Cnt);
      N := 0;
      for I := 0 to High(Present) do
        if Present[I] then
        begin
          FCPalette[P][N] := I;
          Inc(N);
        end;
    end;
    SetLength(FCPaletteInv[P], SrcRanges.MaxV(P) + 1);
    for I := 0 to Length(FCPalette[P]) - 1 do
      FCPaletteInv[P][FCPalette[P][I]] := I;
  end;
  Result := NonTrivial;
end;

procedure TTransformPaletteC.Data(const Imgs: TImages);
var
  I, P: Integer;
  R, C: Cardinal;
  Img: TImage;
begin
  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    for P := 0 to Img.NumPlanes - 1 do
      for R := 0 to Img.Rows - 1 do
        for C := 0 to Img.Cols - 1 do
          Img.SetVal(P, R, C, FCPaletteInv[P][Img.GetVal(P, R, C)]);
  end;
end;

procedure TTransformPaletteC.Save(SrcRanges: TColorRanges; Rac: TRacOut);
var
  Coder: TSimpleSymbolCoder;
  P, I, Remaining: Integer;
  MinV: ColorVal;
begin
  Coder := TSimpleSymbolCoder.Create(nil, Rac, 18);
  try
    for P := 0 to SrcRanges.NumPlanes - 1 do
    begin
      Coder.WriteInt(0, SrcRanges.MaxV(P) - SrcRanges.MinV(P), Length(FCPalette[P]) - 1);
      MinV := SrcRanges.MinV(P);
      Remaining := Length(FCPalette[P]) - 1;
      for I := 0 to Length(FCPalette[P]) - 1 do
      begin
        Coder.WriteInt(0, SrcRanges.MaxV(P) - MinV - Remaining, FCPalette[P][I] - MinV);
        MinV := FCPalette[P][I] + 1;
        Dec(Remaining);
      end;
    end;
  finally
    Coder.Free;
  end;
end;

function TTransformPaletteC.Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean;
var
  Coder: TSimpleSymbolCoder;
  P, I, Nb, Remaining: Integer;
  MinV: ColorVal;
begin
  Coder := TSimpleSymbolCoder.Create(Rac, nil, 18);
  try
    for P := 0 to SrcRanges.NumPlanes - 1 do
    begin
      Nb := Coder.ReadInt(0, SrcRanges.MaxV(P) - SrcRanges.MinV(P)) + 1;
      MinV := SrcRanges.MinV(P);
      Remaining := Nb - 1;
      SetLength(FCPalette[P], Nb);
      for I := 0 to Nb - 1 do
      begin
        FCPalette[P][I] := MinV + Coder.ReadInt(0, SrcRanges.MaxV(P) - MinV - Remaining);
        MinV := FCPalette[P][I] + 1;
        Dec(Remaining);
      end;
    end;
    Result := True;
  finally
    Coder.Free;
  end;
end;

// =====================================================================
// Palette  /  Palette_Alpha
// =====================================================================

type
  TColor4 = record
    A, B, C, D: ColorVal;   // Palette: (Y,I,Q,-) ; Palette_Alpha: (A,Y,I,Q)
  end;
  TColor4Array = array of TColor4;

function Color3Cmp(const X, Y: TColor4): Integer; inline;
begin
  if X.A <> Y.A then begin if X.A < Y.A then Exit(-1) else Exit(1); end;
  if X.B <> Y.B then begin if X.B < Y.B then Exit(-1) else Exit(1); end;
  if X.C <> Y.C then begin if X.C < Y.C then Exit(-1) else Exit(1); end;
  Result := 0;
end;

function Color4Cmp(const X, Y: TColor4): Integer; inline;
var
  R: Integer;
begin
  R := Color3Cmp(X, Y);
  if R <> 0 then Exit(R);
  if X.D <> Y.D then begin if X.D < Y.D then Exit(-1) else Exit(1); end;
  Result := 0;
end;

// sorted-set insert; returns False if the value was already present
function SortedInsert(var Arr: TColor4Array; const V: TColor4; Wide: Boolean): Boolean;
var
  Lo, Hi, Mid, Cmp, N: Integer;
begin
  Lo := 0;
  Hi := Length(Arr);
  while Lo < Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if Wide then Cmp := Color4Cmp(Arr[Mid], V) else Cmp := Color3Cmp(Arr[Mid], V);
    if Cmp = 0 then Exit(False)
    else if Cmp < 0 then Lo := Mid + 1
    else Hi := Mid;
  end;
  N := Length(Arr);
  SetLength(Arr, N + 1);
  if N > Lo then
    Move(Arr[Lo], Arr[Lo + 1], (N - Lo) * SizeOf(TColor4));
  Arr[Lo] := V;
  Result := True;
end;

// index of V, or Length(Arr) if absent -- matches the linear scan in C++
function SortedFind(const Arr: TColor4Array; const V: TColor4; Wide: Boolean): Integer;
var
  Lo, Hi, Mid, Cmp: Integer;
begin
  Lo := 0;
  Hi := Length(Arr);
  while Lo < Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if Wide then Cmp := Color4Cmp(Arr[Mid], V) else Cmp := Color3Cmp(Arr[Mid], V);
    if Cmp = 0 then Exit(Mid)
    else if Cmp < 0 then Lo := Mid + 1
    else Hi := Mid;
  end;
  Result := Length(Arr);
end;

function LinearFind(const Arr: TColor4Array; const V: TColor4; Wide: Boolean): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Arr) do
    if Wide then
    begin
      if Color4Cmp(Arr[I], V) = 0 then Exit(I);
    end
    else if Color3Cmp(Arr[I], V) = 0 then Exit(I);
  Result := Length(Arr);
end;

type
  TColorRangesPalette = class(TColorRanges)
  protected
    FRanges: TColorRanges;
    FNbColors: Integer;
  public
    constructor Create(ARanges: TColorRanges; Nb: Integer);
    function IsStatic: Boolean; override;
    function NumPlanes: Integer; override;
    function MinV(P: Integer): ColorVal; override;
    function MaxV(P: Integer): ColorVal; override;
    procedure MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal); override;
    function Previous: TColorRanges; override;
  end;

constructor TColorRangesPalette.Create(ARanges: TColorRanges; Nb: Integer);
begin
  inherited Create;
  FRanges := ARanges;
  FNbColors := Nb;
end;

function TColorRangesPalette.IsStatic: Boolean;
begin
  Result := False;
end;

function TColorRangesPalette.NumPlanes: Integer;
begin
  Result := FRanges.NumPlanes;
end;

function TColorRangesPalette.MinV(P: Integer): ColorVal;
begin
  if P < 3 then Result := 0 else Result := FRanges.MinV(P);
end;

function TColorRangesPalette.MaxV(P: Integer): ColorVal;
begin
  if P = 1 then Result := FNbColors - 1
  else if P < 3 then Result := 0
  else Result := FRanges.MaxV(P);
end;

procedure TColorRangesPalette.MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal);
begin
  if P = 1 then begin MinV_ := 0; MaxV_ := FNbColors - 1; end
  else if P < 3 then begin MinV_ := 0; MaxV_ := 0; end
  else FRanges.MinMax(P, PP, MinV_, MaxV_);
end;

function TColorRangesPalette.Previous: TColorRanges;
begin
  Result := FRanges;
end;

type
  TTransformPalette = class(TTransform)
  protected
    FPalette: TColor4Array;
    FMaxPaletteSize: Integer;
    FOrderedPalette: Boolean;
    FHasAlpha: Boolean;
  public
    function IsPaletteTransform: Boolean; override;
    procedure Configure(Setting: Integer); override;
    function Init(SrcRanges: TColorRanges): Boolean; override;
    function Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges; override;
    procedure InvData(const Imgs: TImages; StrideCol: Cardinal = 1;
      StrideRow: Cardinal = 1); override;
    function Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean; override;
    procedure Data(const Imgs: TImages); override;
    procedure Save(SrcRanges: TColorRanges; Rac: TRacOut); override;
    function Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean; override;
  end;

function TTransformPalette.IsPaletteTransform: Boolean;
begin
  Result := not FHasAlpha;
end;

procedure TTransformPalette.Configure(Setting: Integer);
begin
  if Setting > 0 then
  begin
    FOrderedPalette := True;
    FMaxPaletteSize := Setting;
  end
  else
  begin
    FOrderedPalette := False;
    FMaxPaletteSize := -Setting;
  end;
end;

function TTransformPalette.Init(SrcRanges: TColorRanges): Boolean;
begin
  if SrcRanges.NumPlanes < 3 then Exit(False);
  if (SrcRanges.MaxV(0) = 0) and (SrcRanges.MaxV(2) = 0) and (SrcRanges.NumPlanes > 3) and
     (SrcRanges.MinV(3) = 1) and (SrcRanges.MaxV(3) = 1) then Exit(False);   // already did PLA
  if (SrcRanges.MinV(1) = SrcRanges.MaxV(1)) and (SrcRanges.MinV(2) = SrcRanges.MaxV(2)) then
    Exit(False);   // probably grayscale/monochrome
  FHasAlpha := SrcRanges.NumPlanes > 3;
  Result := True;
end;

function TTransformPalette.Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges;
var
  I: Integer;
begin
  for I := 0 to High(Imgs) do Imgs[I].Palette := True;
  Result := TColorRangesPalette.Create(SrcRanges, Length(FPalette));
end;

procedure TTransformPalette.InvData(const Imgs: TImages; StrideCol: Cardinal; StrideRow: Cardinal);
var
  I, PV: Integer;
  R, C, ScaledRows, ScaledCols: Cardinal;
  Img: TImage;
begin
  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    Img.UndoMakeConstantPlane(0);
    Img.UndoMakeConstantPlane(1);
    Img.UndoMakeConstantPlane(2);
    ScaledRows := Img.ScaledRows;
    ScaledCols := Img.ScaledCols;
    R := 0;
    while R < ScaledRows do
    begin
      C := 0;
      while C < ScaledCols do
      begin
        PV := Img.GetVal(1, R, C);
        if (PV < 0) or (PV >= Length(FPalette)) then PV := 0;
        Img.SetVal(0, R, C, FPalette[PV].A);
        Img.SetVal(1, R, C, FPalette[PV].B);
        Img.SetVal(2, R, C, FPalette[PV].C);
        Inc(C, StrideCol);
      end;
      Inc(R, StrideRow);
    end;
    Img.Palette := False;
  end;
end;

function TTransformPalette.Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean;
var
  I, N: Integer;
  R, C: Cardinal;
  Img: TImage;
  Col: TColor4;
begin
  SetLength(FPalette, 0);
  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    for R := 0 to Img.Rows - 1 do
      for C := 0 to Img.Cols - 1 do
      begin
        if Img.AlphaZeroSpecial and (Img.NumPlanes > 3) and (Img.GetVal(3, R, C) = 0) then Continue;
        Col.A := Img.GetVal(0, R, C);
        Col.B := Img.GetVal(1, R, C);
        Col.C := Img.GetVal(2, R, C);
        Col.D := 0;
        if FOrderedPalette then
        begin
          SortedInsert(FPalette, Col, False);
          if Length(FPalette) > FMaxPaletteSize then Exit(False);
        end
        else
        begin
          if LinearFind(FPalette, Col, False) = Length(FPalette) then
          begin
            N := Length(FPalette);
            SetLength(FPalette, N + 1);
            FPalette[N] := Col;
            if Length(FPalette) > FMaxPaletteSize then Exit(False);
          end;
        end;
      end;
  end;
  Result := True;
end;

procedure TTransformPalette.Data(const Imgs: TImages);
var
  I, PV: Integer;
  R, C: Cardinal;
  Img: TImage;
  Col: TColor4;
begin
  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    for R := 0 to Img.Rows - 1 do
      for C := 0 to Img.Cols - 1 do
      begin
        Col.A := Img.GetVal(0, R, C);
        Col.B := Img.GetVal(1, R, C);
        Col.C := Img.GetVal(2, R, C);
        Col.D := 0;
        if FOrderedPalette then PV := SortedFind(FPalette, Col, False)
        else PV := LinearFind(FPalette, Col, False);
        Img.SetVal(0, R, C, 0);
        Img.SetVal(1, R, C, PV);
      end;
    Img.MakeConstantPlane(2, 0);
  end;
end;

procedure TTransformPalette.Save(SrcRanges: TColorRanges; Rac: TRacOut);
var
  Coder, CoderY, CoderI, CoderQ: TSimpleSymbolCoder;
  PP: PrevPlanes;
  Sorted, I: Integer;
  MinC, MaxC, Prev: TColor4;
  Y, Iv: ColorVal;
begin
  Coder := TSimpleSymbolCoder.Create(nil, Rac, 18);
  CoderY := TSimpleSymbolCoder.Create(nil, Rac, 18);
  CoderI := TSimpleSymbolCoder.Create(nil, Rac, 18);
  CoderQ := TSimpleSymbolCoder.Create(nil, Rac, 18);
  try
    Coder.WriteInt2(1, MAX_PALETTE_SIZE, Length(FPalette));
    SetLength(PP, 2);
    if FOrderedPalette then Sorted := 1 else Sorted := 0;
    Coder.WriteInt2(0, 1, Sorted);
    if Sorted <> 0 then
    begin
      MinC.A := SrcRanges.MinV(0); MinC.B := SrcRanges.MinV(1); MinC.C := SrcRanges.MinV(2);
      MaxC.A := SrcRanges.MaxV(0); MaxC.B := SrcRanges.MaxV(1); MaxC.C := SrcRanges.MaxV(2);
      Prev.A := -1; Prev.B := -1; Prev.C := -1;
      for I := 0 to High(FPalette) do
      begin
        Y := FPalette[I].A;
        CoderY.WriteInt2(MinC.A, MaxC.A, Y);
        PP[0] := Y; SrcRanges.MinMax(1, PP, MinC.B, MaxC.B);
        Iv := FPalette[I].B;
        if Prev.A = Y then
          CoderI.WriteInt2(Prev.B, MaxC.B, Iv)
        else
          CoderI.WriteInt2(MinC.B, MaxC.B, Iv);
        PP[1] := Iv; SrcRanges.MinMax(2, PP, MinC.C, MaxC.C);
        CoderQ.WriteInt2(MinC.C, MaxC.C, FPalette[I].C);
        MinC.A := FPalette[I].A;
        Prev := FPalette[I];
      end;
    end
    else
    begin
      for I := 0 to High(FPalette) do
      begin
        Y := FPalette[I].A;
        SrcRanges.MinMax(0, PP, MinC.A, MaxC.A);
        CoderY.WriteInt2(MinC.A, MaxC.A, Y);
        PP[0] := Y; SrcRanges.MinMax(1, PP, MinC.B, MaxC.B);
        Iv := FPalette[I].B;
        CoderI.WriteInt2(MinC.B, MaxC.B, Iv);
        PP[1] := Iv; SrcRanges.MinMax(2, PP, MinC.C, MaxC.C);
        CoderQ.WriteInt2(MinC.C, MaxC.C, FPalette[I].C);
      end;
    end;
    v_printf(5, Format('[%d]', [Length(FPalette)]));
    if not FOrderedPalette then v_printf(5, 'Unsorted');
  finally
    Coder.Free; CoderY.Free; CoderI.Free; CoderQ.Free;
  end;
end;

function TTransformPalette.Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean;
var
  Coder, CoderY, CoderI, CoderQ: TSimpleSymbolCoder;
  PP: PrevPlanes;
  Size, Sorted, P: Integer;
  MinC, MaxC, Prev, Col: TColor4;
  Y, Iv, Q: ColorVal;
begin
  Coder := TSimpleSymbolCoder.Create(Rac, nil, 18);
  CoderY := TSimpleSymbolCoder.Create(Rac, nil, 18);
  CoderI := TSimpleSymbolCoder.Create(Rac, nil, 18);
  CoderQ := TSimpleSymbolCoder.Create(Rac, nil, 18);
  try
    Size := Coder.ReadInt2(1, MAX_PALETTE_SIZE);
    SetLength(PP, 2);
    Sorted := Coder.ReadInt2(0, 1);
    SetLength(FPalette, 0);
    if Sorted <> 0 then
    begin
      MinC.A := SrcRanges.MinV(0); MinC.B := SrcRanges.MinV(1); MinC.C := SrcRanges.MinV(2);
      MaxC.A := SrcRanges.MaxV(0); MaxC.B := SrcRanges.MaxV(1); MaxC.C := SrcRanges.MaxV(2);
      Prev.A := -1; Prev.B := -1; Prev.C := -1;
      for P := 0 to Size - 1 do
      begin
        Y := CoderY.ReadInt2(MinC.A, MaxC.A);
        PP[0] := Y; SrcRanges.MinMax(1, PP, MinC.B, MaxC.B);
        if Prev.A = Y then
          Iv := CoderI.ReadInt2(Prev.B, MaxC.B)
        else
          Iv := CoderI.ReadInt2(MinC.B, MaxC.B);
        PP[1] := Iv; SrcRanges.MinMax(2, PP, MinC.C, MaxC.C);
        Q := CoderQ.ReadInt2(MinC.C, MaxC.C);
        Col.A := Y; Col.B := Iv; Col.C := Q; Col.D := 0;
        SetLength(FPalette, Length(FPalette) + 1);
        FPalette[High(FPalette)] := Col;
        MinC.A := Col.A;
        Prev := Col;
      end;
    end
    else
    begin
      for P := 0 to Size - 1 do
      begin
        SrcRanges.MinMax(0, PP, MinC.A, MaxC.A);
        Y := CoderY.ReadInt2(MinC.A, MaxC.A);
        PP[0] := Y; SrcRanges.MinMax(1, PP, MinC.B, MaxC.B);
        Iv := CoderI.ReadInt2(MinC.B, MaxC.B);
        PP[1] := Iv; SrcRanges.MinMax(2, PP, MinC.C, MaxC.C);
        Q := CoderQ.ReadInt2(MinC.C, MaxC.C);
        Col.A := Y; Col.B := Iv; Col.C := Q; Col.D := 0;
        SetLength(FPalette, Length(FPalette) + 1);
        FPalette[High(FPalette)] := Col;
      end;
    end;
    v_printf(5, Format('[%d]', [Length(FPalette)]));
    Result := True;
  finally
    Coder.Free; CoderY.Free; CoderI.Free; CoderQ.Free;
  end;
end;

// ---- Palette_Alpha ----

type
  TColorRangesPaletteA = class(TColorRanges)
  protected
    FRanges: TColorRanges;
    FNbColors: Integer;
  public
    constructor Create(ARanges: TColorRanges; Nb: Integer);
    function IsStatic: Boolean; override;
    function NumPlanes: Integer; override;
    function MinV(P: Integer): ColorVal; override;
    function MaxV(P: Integer): ColorVal; override;
    procedure MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal); override;
    function Previous: TColorRanges; override;
  end;

constructor TColorRangesPaletteA.Create(ARanges: TColorRanges; Nb: Integer);
begin
  inherited Create;
  FRanges := ARanges;
  FNbColors := Nb;
end;

function TColorRangesPaletteA.IsStatic: Boolean;
begin
  Result := False;
end;

function TColorRangesPaletteA.NumPlanes: Integer;
begin
  Result := FRanges.NumPlanes;
end;

function TColorRangesPaletteA.MinV(P: Integer): ColorVal;
begin
  if P < 3 then Result := 0
  else if P = 3 then Result := 1
  else Result := FRanges.MinV(P);
end;

function TColorRangesPaletteA.MaxV(P: Integer): ColorVal;
begin
  case P of
    0: Result := 0;
    1: Result := FNbColors - 1;
    2: Result := 0;
    3: Result := 1;
  else
    Result := FRanges.MaxV(P);
  end;
end;

procedure TColorRangesPaletteA.MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal);
begin
  if P = 1 then begin MinV_ := 0; MaxV_ := FNbColors - 1; end
  else if P < 3 then begin MinV_ := 0; MaxV_ := 0; end
  else if P = 3 then begin MinV_ := 1; MaxV_ := 1; end
  else FRanges.MinMax(P, PP, MinV_, MaxV_);
end;

function TColorRangesPaletteA.Previous: TColorRanges;
begin
  Result := FRanges;
end;

type
  TTransformPaletteA = class(TTransform)
  protected
    FPalette: TColor4Array;
    FMaxPaletteSize: Integer;
    FAlphaZeroSpecial: Boolean;
    FOrderedPalette: Boolean;
    FAlreadyHasPalette: Boolean;
  public
    function IsPaletteTransform: Boolean; override;
    procedure Configure(Setting: Integer); override;
    function Init(SrcRanges: TColorRanges): Boolean; override;
    function Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges; override;
    procedure InvData(const Imgs: TImages; StrideCol: Cardinal = 1;
      StrideRow: Cardinal = 1); override;
    function Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean; override;
    procedure Data(const Imgs: TImages); override;
    procedure Save(SrcRanges: TColorRanges; Rac: TRacOut); override;
    function Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean; override;
  end;

function TTransformPaletteA.IsPaletteTransform: Boolean;
begin
  Result := True;
end;

procedure TTransformPaletteA.Configure(Setting: Integer);
begin
  FAlphaZeroSpecial := Setting <> 0;
  if Setting > 0 then
  begin
    FOrderedPalette := True;
    FMaxPaletteSize := Setting;
  end
  else
  begin
    FOrderedPalette := False;
    FMaxPaletteSize := -Setting;
  end;
end;

function TTransformPaletteA.Init(SrcRanges: TColorRanges): Boolean;
begin
  if SrcRanges.NumPlanes < 4 then Exit(False);
  if SrcRanges.MinV(3) = SrcRanges.MaxV(3) then Exit(False);
  FAlreadyHasPalette := False;
  Result := True;
end;

function TTransformPaletteA.Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges;
var
  I: Integer;
begin
  for I := 0 to High(Imgs) do
  begin
    Imgs[I].Palette := True;
    Imgs[I].AlphaZeroSpecial := False;
  end;
  Result := TColorRangesPaletteA.Create(SrcRanges, Length(FPalette));
end;

procedure TTransformPaletteA.InvData(const Imgs: TImages; StrideCol: Cardinal; StrideRow: Cardinal);
var
  I, PV: Integer;
  R, C, ScaledRows, ScaledCols: Cardinal;
  Img: TImage;
begin
  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    Img.UndoMakeConstantPlane(0);
    Img.UndoMakeConstantPlane(1);
    Img.UndoMakeConstantPlane(2);
    Img.UndoMakeConstantPlane(3);
    ScaledRows := Img.ScaledRows;
    ScaledCols := Img.ScaledCols;
    R := 0;
    while R < ScaledRows do
    begin
      C := 0;
      while C < ScaledCols do
      begin
        PV := Img.GetVal(1, R, C);
        if (PV < 0) or (PV >= Length(FPalette)) then PV := 0;
        Img.SetVal(0, R, C, FPalette[PV].B);
        Img.SetVal(1, R, C, FPalette[PV].C);
        Img.SetVal(2, R, C, FPalette[PV].D);
        Img.SetVal(3, R, C, FPalette[PV].A);
        Inc(C, StrideCol);
      end;
      Inc(R, StrideRow);
    end;
    Img.Palette := False;
  end;
end;

function TTransformPaletteA.Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean;
var
  I, K, N: Integer;
  R, C: Cardinal;
  Img, PalImg, OtherPal: TImage;
  Col, Other: TColor4;
  MaxNbColors: QWord;
  P: Integer;
begin
  FAlphaZeroSpecial := Imgs[0].AlphaZeroSpecial;
  SetLength(FPalette, 0);
  if Imgs[0].Palette and (Imgs[0].PaletteImage <> nil) then
  begin
    PalImg := Imgs[0].PaletteImage;
    for I := 0 to Integer(PalImg.Cols) - 1 do
    begin
      Col.B := PalImg.GetVal(0, 0, I);
      Col.C := PalImg.GetVal(1, 0, I);
      Col.D := PalImg.GetVal(2, 0, I);
      Col.A := PalImg.GetVal(3, 0, I);
      if FAlphaZeroSpecial and (Col.A = 0) then begin Col.B := 0; Col.C := 0; Col.D := 0; end;
      N := Length(FPalette);
      SetLength(FPalette, N + 1);
      FPalette[N] := Col;
    end;
    for K := 1 to High(Imgs) do
    begin
      if (not Imgs[K].Palette) or (Imgs[K].PaletteImage = nil) then
      begin
        e_printf('Attempting to construct an animation with -k from frames with and without palettes.'#10);
        Exit(False);
      end;
      OtherPal := Imgs[K].PaletteImage;
      for I := 0 to Integer(PalImg.Cols) - 1 do
      begin
        Other.B := OtherPal.GetVal(0, 0, I);
        Other.C := OtherPal.GetVal(1, 0, I);
        Other.D := OtherPal.GetVal(2, 0, I);
        Other.A := OtherPal.GetVal(3, 0, I);
        if FAlphaZeroSpecial and (Other.A = 0) then begin Other.B := 0; Other.C := 0; Other.D := 0; end;
        if Color4Cmp(Other, FPalette[I]) = 0 then Continue;
        e_printf('Attempting to construct an animation with -k from frames with different palettes.'#10);
        Exit(False);
      end;
    end;
    FOrderedPalette := False;
    FAlreadyHasPalette := True;
    Exit(True);
  end;

  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    for R := 0 to Img.Rows - 1 do
      for C := 0 to Img.Cols - 1 do
      begin
        Col.B := Img.GetVal(0, R, C);
        Col.C := Img.GetVal(1, R, C);
        Col.D := Img.GetVal(2, R, C);
        Col.A := Img.GetVal(3, R, C);
        if FAlphaZeroSpecial and (Col.A = 0) then begin Col.B := 0; Col.C := 0; Col.D := 0; end;
        if FOrderedPalette then
        begin
          SortedInsert(FPalette, Col, True);
          if Length(FPalette) > FMaxPaletteSize then Exit(False);
        end
        else
        begin
          if LinearFind(FPalette, Col, True) = Length(FPalette) then
          begin
            N := Length(FPalette);
            SetLength(FPalette, N + 1);
            FPalette[N] := Col;
            if Length(FPalette) > FMaxPaletteSize then Exit(False);
          end;
        end;
      end;
  end;

  MaxNbColors := 1;
  for P := 0 to 3 do
  begin
    MaxNbColors := MaxNbColors * QWord(1 + SrcRanges.MaxV(P) - SrcRanges.MinV(P));
    if QWord(Length(FPalette)) < MaxNbColors then Exit(True);
  end;
  if QWord(Length(FPalette)) = MaxNbColors then Exit(False);
  Result := True;
end;

procedure TTransformPaletteA.Data(const Imgs: TImages);
var
  I, PV: Integer;
  R, C: Cardinal;
  Img: TImage;
  Col: TColor4;
begin
  if FAlreadyHasPalette then Exit;
  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    for R := 0 to Img.Rows - 1 do
      for C := 0 to Img.Cols - 1 do
      begin
        Col.A := Img.GetVal(3, R, C);
        Col.B := Img.GetVal(0, R, C);
        Col.C := Img.GetVal(1, R, C);
        Col.D := Img.GetVal(2, R, C);
        if FAlphaZeroSpecial and (Col.A = 0) then begin Col.B := 0; Col.C := 0; Col.D := 0; end;
        if FOrderedPalette then PV := SortedFind(FPalette, Col, True)
        else PV := LinearFind(FPalette, Col, True);
        Img.SetVal(0, R, C, 0);
        Img.SetVal(1, R, C, PV);
        Img.SetVal(3, R, C, 1);
      end;
    Img.MakeConstantPlane(2, 0);
    Img.MakeConstantPlane(3, 1);
  end;
end;

procedure TTransformPaletteA.Save(SrcRanges: TColorRanges; Rac: TRacOut);
var
  Coder, CoderY, CoderI, CoderQ, CoderA: TSimpleSymbolCoder;
  PP: PrevPlanes;
  Sorted, I: Integer;
  MinC, MaxC, Prev: TColor4;
  A, Y, Iv: ColorVal;
begin
  Coder := TSimpleSymbolCoder.Create(nil, Rac, 18);
  CoderY := TSimpleSymbolCoder.Create(nil, Rac, 18);
  CoderI := TSimpleSymbolCoder.Create(nil, Rac, 18);
  CoderQ := TSimpleSymbolCoder.Create(nil, Rac, 18);
  CoderA := TSimpleSymbolCoder.Create(nil, Rac, 18);
  try
    Coder.WriteInt2(1, MAX_PALETTE_SIZE, Length(FPalette));
    SetLength(PP, 2);
    if FOrderedPalette then Sorted := 1 else Sorted := 0;
    Coder.WriteInt2(0, 1, Sorted);
    if Sorted <> 0 then
    begin
      MinC.A := SrcRanges.MinV(3); MinC.B := SrcRanges.MinV(0);
      MinC.C := SrcRanges.MinV(1); MinC.D := SrcRanges.MinV(2);
      MaxC.A := SrcRanges.MaxV(3); MaxC.B := SrcRanges.MaxV(0);
      MaxC.C := SrcRanges.MaxV(1); MaxC.D := SrcRanges.MaxV(2);
      Prev.A := -1; Prev.B := -1; Prev.C := -1; Prev.D := -1;
      for I := 0 to High(FPalette) do
      begin
        A := FPalette[I].A;
        CoderA.WriteInt2(MinC.A, MaxC.A, A);
        if FAlphaZeroSpecial and (A = 0) then Continue;
        Y := FPalette[I].B;
        if Prev.A = A then
          CoderY.WriteInt2(Prev.B, MaxC.B, Y)
        else
          CoderY.WriteInt2(MinC.B, MaxC.B, Y);
        PP[0] := Y; SrcRanges.MinMax(1, PP, MinC.C, MaxC.C);
        Iv := FPalette[I].C;
        CoderI.WriteInt2(MinC.C, MaxC.C, Iv);
        PP[1] := Iv; SrcRanges.MinMax(2, PP, MinC.D, MaxC.D);
        CoderQ.WriteInt2(MinC.D, MaxC.D, FPalette[I].D);
        MinC.A := FPalette[I].A;
        Prev := FPalette[I];
      end;
    end
    else
    begin
      for I := 0 to High(FPalette) do
      begin
        A := FPalette[I].A;
        CoderA.WriteInt2(SrcRanges.MinV(3), SrcRanges.MaxV(3), A);
        if FAlphaZeroSpecial and (A = 0) then Continue;
        SrcRanges.MinMax(0, PP, MinC.B, MaxC.B);
        Y := FPalette[I].B;
        CoderY.WriteInt2(MinC.B, MaxC.B, Y);
        PP[0] := Y; SrcRanges.MinMax(1, PP, MinC.C, MaxC.C);
        Iv := FPalette[I].C;
        CoderI.WriteInt2(MinC.C, MaxC.C, Iv);
        PP[1] := Iv; SrcRanges.MinMax(2, PP, MinC.D, MaxC.D);
        CoderQ.WriteInt2(MinC.D, MaxC.D, FPalette[I].D);
      end;
    end;
    v_printf(5, Format('[%d]', [Length(FPalette)]));
    if not FOrderedPalette then v_printf(5, 'Unsorted');
  finally
    Coder.Free; CoderY.Free; CoderI.Free; CoderQ.Free; CoderA.Free;
  end;
end;

function TTransformPaletteA.Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean;
var
  Coder, CoderY, CoderI, CoderQ, CoderA: TSimpleSymbolCoder;
  PP: PrevPlanes;
  Size, Sorted, P, N: Integer;
  MinC, MaxC, Prev, Col: TColor4;
  A, Y, Iv, Q: ColorVal;
begin
  Coder := TSimpleSymbolCoder.Create(Rac, nil, 18);
  CoderY := TSimpleSymbolCoder.Create(Rac, nil, 18);
  CoderI := TSimpleSymbolCoder.Create(Rac, nil, 18);
  CoderQ := TSimpleSymbolCoder.Create(Rac, nil, 18);
  CoderA := TSimpleSymbolCoder.Create(Rac, nil, 18);
  try
    Size := Coder.ReadInt2(1, MAX_PALETTE_SIZE);
    SetLength(PP, 2);
    Sorted := Coder.ReadInt2(0, 1);
    SetLength(FPalette, 0);
    if Sorted <> 0 then
    begin
      MinC.A := SrcRanges.MinV(3); MinC.B := SrcRanges.MinV(0);
      MinC.C := SrcRanges.MinV(1); MinC.D := SrcRanges.MinV(2);
      MaxC.A := SrcRanges.MaxV(3); MaxC.B := SrcRanges.MaxV(0);
      MaxC.C := SrcRanges.MaxV(1); MaxC.D := SrcRanges.MaxV(2);
      Prev.A := -1; Prev.B := -1; Prev.C := -1; Prev.D := -1;
      for P := 0 to Size - 1 do
      begin
        A := CoderA.ReadInt2(MinC.A, MaxC.A);
        if FAlphaZeroSpecial and (A = 0) then
        begin
          N := Length(FPalette);
          SetLength(FPalette, N + 1);
          FPalette[N].A := 0; FPalette[N].B := 0; FPalette[N].C := 0; FPalette[N].D := 0;
          Continue;
        end;
        if Prev.A = A then
          Y := CoderY.ReadInt2(Prev.B, MaxC.B)
        else
          Y := CoderY.ReadInt2(MinC.B, MaxC.B);
        PP[0] := Y; SrcRanges.MinMax(1, PP, MinC.C, MaxC.C);
        Iv := CoderI.ReadInt2(MinC.C, MaxC.C);
        PP[1] := Iv; SrcRanges.MinMax(2, PP, MinC.D, MaxC.D);
        Q := CoderQ.ReadInt2(MinC.D, MaxC.D);
        Col.A := A; Col.B := Y; Col.C := Iv; Col.D := Q;
        N := Length(FPalette);
        SetLength(FPalette, N + 1);
        FPalette[N] := Col;
        MinC.A := Col.A;
        Prev := Col;
      end;
    end
    else
    begin
      for P := 0 to Size - 1 do
      begin
        A := CoderA.ReadInt2(SrcRanges.MinV(3), SrcRanges.MaxV(3));
        if FAlphaZeroSpecial and (A = 0) then
        begin
          N := Length(FPalette);
          SetLength(FPalette, N + 1);
          FPalette[N].A := 0; FPalette[N].B := 0; FPalette[N].C := 0; FPalette[N].D := 0;
          Continue;
        end;
        SrcRanges.MinMax(0, PP, MinC.B, MaxC.B);
        Y := CoderY.ReadInt2(MinC.B, MaxC.B);
        PP[0] := Y; SrcRanges.MinMax(1, PP, MinC.C, MaxC.C);
        Iv := CoderI.ReadInt2(MinC.C, MaxC.C);
        PP[1] := Iv; SrcRanges.MinMax(2, PP, MinC.D, MaxC.D);
        Q := CoderQ.ReadInt2(MinC.D, MaxC.D);
        Col.A := A; Col.B := Y; Col.C := Iv; Col.D := Q;
        N := Length(FPalette);
        SetLength(FPalette, N + 1);
        FPalette[N] := Col;
      end;
    end;
    v_printf(5, Format('[%d]', [Length(FPalette)]));
    Result := True;
  finally
    Coder.Free; CoderY.Free; CoderI.Free; CoderQ.Free; CoderA.Free;
  end;
end;

{$i transform_cb.inc}
{$i transform_frame.inc}

// =====================================================================
// factory
// =====================================================================

function CreateTransform(const Desc: string): TTransform;
begin
  if Desc = 'YCoCg' then Result := TTransformYCoCg.Create
  else if Desc = 'Bounds' then Result := TTransformBounds.Create
  else if Desc = 'PermutePlanes' then Result := TTransformPermute.Create
  else if Desc = 'Color_Buckets' then Result := TTransformCB.Create
  else if Desc = 'Palette' then Result := TTransformPalette.Create
  else if Desc = 'Palette_Alpha' then Result := TTransformPaletteA.Create
  else if Desc = 'Channel_Compact' then Result := TTransformPaletteC.Create
  else if Desc = 'Frame_Shape' then Result := TTransformFrameShape.Create
  else if Desc = 'Duplicate_Frame' then Result := TTransformFrameDup.Create
  else if Desc = 'Frame_Lookback' then Result := TTransformFrameCombine.Create
  else Result := nil;
end;

end.
