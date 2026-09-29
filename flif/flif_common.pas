// FLIF - Free Lossless Image Format -- Free Pascal port
// Pixel predictors and MANIAC context properties.
// Corresponds to: src/common.hpp, src/common.cpp
//
// The C++ version instantiates predict_and_calcProps_plane() for every
// (plane type, direction, border/no-border, plane index) combination purely for
// speed; the "no border cases" variants compute exactly the same values as the
// general one, so only the general one is ported here.
unit flif_common;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  flif_types, flif_image, flif_colorrange;

procedure InitPropRangesScanlines(out PropRanges: Ranges; R: TColorRanges; P: Integer);
procedure InitPropRanges(out PropRanges: Ranges; R: TColorRanges; P: Integer);

function PredictAndCalcPropsScanlinesPlane(var Props: Properties; R: TColorRanges;
  Image: TImage; Plane: TGeneralPlane; P: Integer; Row, Col: Cardinal;
  out MinV, MaxV: ColorVal; Fallback: ColorVal): ColorVal;
function PredictAndCalcPropsScanlines(var Props: Properties; R: TColorRanges;
  Image: TImage; P: Integer; Row, Col: Cardinal;
  out MinV, MaxV: ColorVal; Fallback: ColorVal): ColorVal;

function PredictScanlinesPlane(Plane: TGeneralPlane; Row, Col: Cardinal;
  Grey: ColorVal): ColorVal;
function PredictScanlines(Image: TImage; P: Integer; Row, Col: Cardinal;
  Grey: ColorVal): ColorVal;

function PredictPlaneHorizontal(Plane: TGeneralPlane; Z, P: Integer;
  Row, Col, Rows: Cardinal; Predictor: Integer): ColorVal;
function PredictPlaneVertical(Plane: TGeneralPlane; Z, P: Integer;
  Row, Col, Cols: Cardinal; Predictor: Integer): ColorVal;
function Predict(Image: TImage; Z, P: Integer; Row, Col: Cardinal;
  Predictor: Integer): ColorVal;

function PredictAndCalcPropsPlane(var Props: Properties; R: TColorRanges;
  Image: TImage; Plane, PlaneY: TGeneralPlane; Horizontal: Boolean; P: Integer;
  Z: Integer; Row, Col: Cardinal; out MinV, MaxV: ColorVal;
  Predictor: Integer): ColorVal;
function PredictAndCalcProps(var Props: Properties; R: TColorRanges;
  Image: TImage; Z, P: Integer; Row, Col: Cardinal; out MinV, MaxV: ColorVal;
  Predictor: Integer): ColorVal;

function PlaneZoomlevels(Image: TImage; BeginZL, EndZL: Integer): Integer;
procedure PlaneZoomlevel(Image: TImage; BeginZL, EndZL, I: Integer;
  R: TColorRanges; out P, ZL: Integer);

implementation

procedure AddRange(var PropRanges: Ranges; A, B: ColorVal); inline;
var
  N: Integer;
begin
  N := Length(PropRanges);
  SetLength(PropRanges, N + 1);
  PropRanges[N].First := A;
  PropRanges[N].Second := B;
end;

procedure InitPropRangesScanlines(out PropRanges: Ranges; R: TColorRanges; P: Integer);
var
  MinV, MaxV, MinD, MaxD: ColorVal;
  PP: Integer;
begin
  SetLength(PropRanges, 0);
  MinV := R.MinV(P);
  MaxV := R.MaxV(P);
  MinD := MinV - MaxV;
  MaxD := MaxV - MinV;

  if P < 3 then
  begin
    for PP := 0 to P - 1 do
      AddRange(PropRanges, R.MinV(PP), R.MaxV(PP));   // pixels on previous planes
    if R.NumPlanes > 3 then
      AddRange(PropRanges, R.MinV(3), R.MaxV(3));     // pixel on alpha plane
  end;
  AddRange(PropRanges, MinV, MaxV);   // guess (median of 3)
  AddRange(PropRanges, 0, 2);         // which predictor was it
  AddRange(PropRanges, MinD, MaxD);
  AddRange(PropRanges, MinD, MaxD);
  AddRange(PropRanges, MinD, MaxD);
  AddRange(PropRanges, MinD, MaxD);
  AddRange(PropRanges, MinD, MaxD);
end;

procedure InitPropRanges(out PropRanges: Ranges; R: TColorRanges; P: Integer);
var
  MinV, MaxV, MinD, MaxD: ColorVal;
  PP: Integer;
begin
  SetLength(PropRanges, 0);
  MinV := R.MinV(P);
  MaxV := R.MaxV(P);
  MinD := MinV - MaxV;
  MaxD := MaxV - MinV;

  if P < 3 then
  begin
    for PP := 0 to P - 1 do
      AddRange(PropRanges, R.MinV(PP), R.MaxV(PP));
    if R.NumPlanes > 3 then
      AddRange(PropRanges, R.MinV(3), R.MaxV(3));
  end;

  AddRange(PropRanges, 0, 2);   // median predictor: which of the three values is the median?

  if (P = 1) or (P = 2) then
    AddRange(PropRanges, R.MinV(0) - R.MaxV(0), R.MaxV(0) - R.MinV(0)); // luma prediction miss
  AddRange(PropRanges, MinD, MaxD);   // neighbour A - neighbour B
  AddRange(PropRanges, MinD, MaxD);   // top/left prediction miss
  AddRange(PropRanges, MinD, MaxD);   // left/top prediction miss
  AddRange(PropRanges, MinD, MaxD);   // bottom/right prediction miss
  AddRange(PropRanges, MinV, MaxV);   // guess

  if P <> 2 then
  begin
    AddRange(PropRanges, MinD, MaxD); // toptop - top
    AddRange(PropRanges, MinD, MaxD); // leftleft - left
  end;
end;

function PredictAndCalcPropsScanlinesPlane(var Props: Properties; R: TColorRanges;
  Image: TImage; Plane: TGeneralPlane; P: Integer; Row, Col: Cardinal;
  out MinV, MaxV: ColorVal; Fallback: ColorVal): ColorVal;
var
  Guess, Left, Top, TopLeft, GradientTL: ColorVal;
  Which, Index, PP: Integer;
begin
  Which := 0;
  Index := 0;
  if P < 3 then
  begin
    for PP := 0 to P - 1 do
    begin
      Props[Index] := Image.GetVal(PP, Row, Col);
      Inc(Index);
    end;
    if Image.NumPlanes > 3 then
    begin
      Props[Index] := Image.GetVal(3, Row, Col);
      Inc(Index);
    end;
  end;

  if Col > 0 then
    Left := Plane.GetPix(Row, Col - 1)
  else if Row > 0 then
    Left := Plane.GetPix(Row - 1, Col)
  else
    Left := Fallback;

  if Row > 0 then Top := Plane.GetPix(Row - 1, Col) else Top := Left;

  if (Row > 0) and (Col > 0) then
    TopLeft := Plane.GetPix(Row - 1, Col - 1)
  else if Row > 0 then
    TopLeft := Top
  else
    TopLeft := Left;

  GradientTL := Left + Top - TopLeft;
  Guess := median3(GradientTL, Left, Top);
  R.Snap(P, Props, MinV, MaxV, Guess);
  if Guess = GradientTL then Which := 0
  else if Guess = Left then Which := 1
  else if Guess = Top then Which := 2;

  Props[Index] := Guess; Inc(Index);
  Props[Index] := Which; Inc(Index);

  if (Col > 0) and (Row > 0) then
  begin
    Props[Index] := Left - TopLeft; Inc(Index);
    Props[Index] := TopLeft - Top; Inc(Index);
  end
  else
  begin
    Props[Index] := 0; Inc(Index);
    Props[Index] := 0; Inc(Index);
  end;

  if (Col + 1 < Image.Cols) and (Row > 0) then
    Props[Index] := Top - Plane.GetPix(Row - 1, Col + 1)   // top - topright
  else
    Props[Index] := 0;
  Inc(Index);

  if Row > 1 then
    Props[Index] := Plane.GetPix(Row - 2, Col) - Top       // toptop - top
  else
    Props[Index] := 0;
  Inc(Index);

  if Col > 1 then
    Props[Index] := Plane.GetPix(Row, Col - 2) - Left      // leftleft - left
  else
    Props[Index] := 0;
  Inc(Index);

  Result := Guess;
end;

function PredictAndCalcPropsScanlines(var Props: Properties; R: TColorRanges;
  Image: TImage; P: Integer; Row, Col: Cardinal;
  out MinV, MaxV: ColorVal; Fallback: ColorVal): ColorVal;
begin
  Result := PredictAndCalcPropsScanlinesPlane(Props, R, Image, Image.GetPlane(P),
    P, Row, Col, MinV, MaxV, Fallback);
end;

function PredictScanlinesPlane(Plane: TGeneralPlane; Row, Col: Cardinal;
  Grey: ColorVal): ColorVal;
var
  Left, Top, TopLeft, GradientTL: ColorVal;
begin
  if Col > 0 then
    Left := Plane.GetPix(Row, Col - 1)
  else if Row > 0 then
    Left := Plane.GetPix(Row - 1, Col)
  else
    Left := Grey;
  if Row > 0 then Top := Plane.GetPix(Row - 1, Col) else Top := Left;
  if (Row > 0) and (Col > 0) then TopLeft := Plane.GetPix(Row - 1, Col - 1) else TopLeft := Top;
  GradientTL := Left + Top - TopLeft;
  Result := median3(GradientTL, Left, Top);
end;

function PredictScanlines(Image: TImage; P: Integer; Row, Col: Cardinal;
  Grey: ColorVal): ColorVal;
begin
  Result := PredictScanlinesPlane(Image.GetPlane(P), Row, Col, Grey);
end;

function PredictPlaneHorizontal(Plane: TGeneralPlane; Z, P: Integer;
  Row, Col, Rows: Cardinal; Predictor: Integer): ColorVal;
var
  Top, Bottom, Avg, Left, TopLeft, BottomLeft: ColorVal;
begin
  if P = 4 then Exit(0);
  Top := Plane.GetPixZ(Z, Row - 1, Col);
  if Row + 1 < Rows then Bottom := Plane.GetPixZ(Z, Row + 1, Col) else Bottom := Top;
  if Predictor = 0 then
  begin
    Result := Sar1(Top + Bottom);
  end
  else if Predictor = 1 then
  begin
    Avg := Sar1(Top + Bottom);
    if Col > 0 then Left := Plane.GetPixZ(Z, Row, Col - 1) else Left := Top;
    if Col > 0 then TopLeft := Plane.GetPixZ(Z, Row - 1, Col - 1) else TopLeft := Top;
    if (Col > 0) and (Row + 1 < Rows) then
      BottomLeft := Plane.GetPixZ(Z, Row + 1, Col - 1)
    else
      BottomLeft := Left;
    Result := median3(Avg, Left + Top - TopLeft, Left + Bottom - BottomLeft);
  end
  else
  begin
    if Col > 0 then Left := Plane.GetPixZ(Z, Row, Col - 1) else Left := Top;
    Result := median3(Top, Bottom, Left);
  end;
end;

function PredictPlaneVertical(Plane: TGeneralPlane; Z, P: Integer;
  Row, Col, Cols: Cardinal; Predictor: Integer): ColorVal;
var
  Left, Right, Avg, Top, TopLeft, TopRight: ColorVal;
begin
  if P = 4 then Exit(0);
  Left := Plane.GetPixZ(Z, Row, Col - 1);
  if Col + 1 < Cols then Right := Plane.GetPixZ(Z, Row, Col + 1) else Right := Left;
  if Predictor = 0 then
  begin
    Result := Sar1(Left + Right);
  end
  else if Predictor = 1 then
  begin
    Avg := Sar1(Left + Right);
    if Row > 0 then Top := Plane.GetPixZ(Z, Row - 1, Col) else Top := Left;
    if Row > 0 then TopLeft := Plane.GetPixZ(Z, Row - 1, Col - 1) else TopLeft := Left;
    if (Row > 0) and (Col + 1 < Cols) then
      TopRight := Plane.GetPixZ(Z, Row - 1, Col + 1)
    else
      TopRight := Top;
    Result := median3(Avg, Left + Top - TopLeft, Right + Top - TopRight);
  end
  else
  begin
    if Row > 0 then Top := Plane.GetPixZ(Z, Row - 1, Col) else Top := Left;
    Result := median3(Top, Left, Right);
  end;
end;

function Predict(Image: TImage; Z, P: Integer; Row, Col: Cardinal;
  Predictor: Integer): ColorVal;
begin
  if P = 4 then Exit(0);
  if (Z and 1) = 0 then
    Result := PredictPlaneHorizontal(Image.GetPlane(P), Z, P, Row, Col, Image.RowsZ(Z), Predictor)
  else
    Result := PredictPlaneVertical(Image.GetPlane(P), Z, P, Row, Col, Image.ColsZ(Z), Predictor);
end;

function PredictAndCalcPropsPlane(var Props: Properties; R: TColorRanges;
  Image: TImage; Plane, PlaneY: TGeneralPlane; Horizontal: Boolean; P: Integer;
  Z: Integer; Row, Col: Cardinal; out MinV, MaxV: ColorVal;
  Predictor: Integer): ColorVal;
var
  Guess, Left, Top, TopLeft, TopRight, BottomLeft, Bottom, Right: ColorVal;
  Avg, TopLeftGradient, Median, BottomRight: ColorVal;
  Index, Which: Integer;
  BottomPresent, RightPresent: Boolean;
  R2: Cardinal;
begin
  Index := 0;

  if P < 3 then
  begin
    if P > 0 then
    begin
      Props[Index] := PlaneY.GetFast(Row, Col);
      Inc(Index);
    end;
    if P > 1 then
    begin
      Props[Index] := Image.GetValZ(1, Z, Row, Col);
      Inc(Index);
    end;
    if Image.NumPlanes > 3 then
    begin
      Props[Index] := Image.GetValZ(3, Z, Row, Col);
      Inc(Index);
    end;
  end;

  BottomPresent := Row + 1 < Image.RowsZ(Z);
  RightPresent := Col + 1 < Image.ColsZ(Z);

  if Horizontal then
  begin
    Top := Plane.GetFast(Row - 1, Col);
    if Col > 0 then Left := Plane.GetFast(Row, Col - 1) else Left := Top;
    if Col > 0 then TopLeft := Plane.GetFast(Row - 1, Col - 1) else TopLeft := Top;
    if RightPresent then TopRight := Plane.GetFast(Row - 1, Col + 1) else TopRight := Top;
    if BottomPresent and (Col > 0) then
      BottomLeft := Plane.GetFast(Row + 1, Col - 1)
    else
      BottomLeft := Left;
    if BottomPresent then Bottom := Plane.GetFast(Row + 1, Col) else Bottom := Left;
    Avg := Sar1(Top + Bottom);
    TopLeftGradient := Left + Top - TopLeft;
    Median := median3(Avg, TopLeftGradient, Left + Bottom - BottomLeft);
    Which := 2;
    if Median = Avg then Which := 0
    else if Median = TopLeftGradient then Which := 1;
    Props[Index] := Which; Inc(Index);
    if (P = 1) or (P = 2) then
    begin
      if BottomPresent then R2 := Row + 1 else R2 := Row - 1;
      Props[Index] := PlaneY.GetFast(Row, Col) -
        Sar1(PlaneY.GetFast(Row - 1, Col) + PlaneY.GetFast(R2, Col));
      Inc(Index);
    end;
    if Predictor = 0 then Guess := Avg
    else if Predictor = 1 then Guess := Median
    else Guess := median3(Top, Bottom, Left);
    R.Snap(P, Props, MinV, MaxV, Guess);
    Props[Index] := Top - Bottom; Inc(Index);
    Props[Index] := Top - Sar1(TopLeft + TopRight); Inc(Index);
    Props[Index] := Left - Sar1(BottomLeft + TopLeft); Inc(Index);
    if RightPresent and BottomPresent then
      BottomRight := Plane.GetFast(Row + 1, Col + 1)
    else
      BottomRight := Bottom;
    Props[Index] := Bottom - Sar1(BottomLeft + BottomRight); Inc(Index);
  end
  else
  begin
    Left := Plane.GetFast(Row, Col - 1);
    if Row > 0 then Top := Plane.GetFast(Row - 1, Col) else Top := Left;
    if Row > 0 then TopLeft := Plane.GetFast(Row - 1, Col - 1) else TopLeft := Left;
    if (Row > 0) and RightPresent then
      TopRight := Plane.GetFast(Row - 1, Col + 1)
    else
      TopRight := Top;
    if BottomPresent then
      BottomLeft := Plane.GetFast(Row + 1, Col - 1)
    else
      BottomLeft := Left;
    if RightPresent then Right := Plane.GetFast(Row, Col + 1) else Right := Top;
    Avg := Sar1(Left + Right);
    TopLeftGradient := Left + Top - TopLeft;
    Median := median3(Avg, TopLeftGradient, Right + Top - TopRight);
    Which := 2;
    if Median = Avg then Which := 0
    else if Median = TopLeftGradient then Which := 1;
    Props[Index] := Which; Inc(Index);
    if (P = 1) or (P = 2) then
    begin
      if RightPresent then R2 := Col + 1 else R2 := Col - 1;
      Props[Index] := PlaneY.GetFast(Row, Col) -
        Sar1(PlaneY.GetFast(Row, Col - 1) + PlaneY.GetFast(Row, R2));
      Inc(Index);
    end;
    if Predictor = 0 then Guess := Avg
    else if Predictor = 1 then Guess := Median
    else Guess := median3(Top, Left, Right);
    R.Snap(P, Props, MinV, MaxV, Guess);
    Props[Index] := Left - Right; Inc(Index);
    Props[Index] := Left - Sar1(BottomLeft + TopLeft); Inc(Index);
    Props[Index] := Top - Sar1(TopLeft + TopRight); Inc(Index);
    if RightPresent and BottomPresent then
      BottomRight := Plane.GetFast(Row + 1, Col + 1)
    else
      BottomRight := Right;
    Props[Index] := Right - Sar1(BottomRight + TopRight); Inc(Index);
  end;

  Props[Index] := Guess; Inc(Index);

  if P <> 2 then
  begin
    if Row > 1 then
      Props[Index] := Plane.GetFast(Row - 2, Col) - Top    // toptop - top
    else
      Props[Index] := 0;
    Inc(Index);
    if Col > 1 then
      Props[Index] := Plane.GetFast(Row, Col - 2) - Left   // leftleft - left
    else
      Props[Index] := 0;
    Inc(Index);
  end;

  Result := Guess;
end;

function PredictAndCalcProps(var Props: Properties; R: TColorRanges;
  Image: TImage; Z, P: Integer; Row, Col: Cardinal; out MinV, MaxV: ColorVal;
  Predictor: Integer): ColorVal;
begin
  Image.GetPlane(0).PrepareZoomlevel(Z);
  Image.GetPlane(P).PrepareZoomlevel(Z);
  Result := PredictAndCalcPropsPlane(Props, R, Image, Image.GetPlane(P),
    Image.GetPlane(0), (Z and 1) = 0, P, Z, Row, Col, MinV, MaxV, Predictor);
end;

function PlaneZoomlevels(Image: TImage; BeginZL, EndZL: Integer): Integer;
begin
  Result := Image.NumPlanes * (BeginZL - EndZL + 1);
end;

procedure PlaneZoomlevel(Image: TImage; BeginZL, EndZL, I: Integer;
  R: TColorRanges; out P, ZL: Integer);
var
  MaxBehind: array[0..4] of Integer;
  NP, HighestPriorityPlane, NextP, Q: Integer;
  Czl: array of Integer;
begin
  // give priority to more important plane(s)
  MaxBehind[0] := 0; MaxBehind[1] := 2; MaxBehind[2] := 4;
  MaxBehind[3] := 0; MaxBehind[4] := 0;

  // if there is no info in the luma plane, there's no reason to lag chroma behind
  if R.MinV(0) >= R.MaxV(0) then
  begin
    MaxBehind[1] := 0;
    MaxBehind[2] := 1;
  end;
  NP := Image.NumPlanes;
  if NP > 5 then
  begin
    P := I mod NP;
    ZL := BeginZL - (I div NP);
    Exit;
  end;
  SetLength(Czl, NP);
  for Q := 0 to NP - 1 do Czl[Q] := BeginZL + 1;
  HighestPriorityPlane := 0;
  if NP >= 4 then HighestPriorityPlane := 3;   // alpha first
  if NP >= 5 then HighestPriorityPlane := 4;   // lookbacks first
  NextP := HighestPriorityPlane;
  while I >= 0 do
  begin
    Dec(Czl[NextP]);
    Dec(I);
    if I < 0 then Break;
    NextP := HighestPriorityPlane;
    for Q := 0 to NP - 1 do
      if Czl[Q] > Czl[HighestPriorityPlane] + MaxBehind[Q] then
        NextP := Q;
    // ensure that nextp is not at the most detailed zoomlevel yet
    while Czl[NextP] <= EndZL do
      NextP := (NextP + 1) mod NP;
  end;
  P := NextP;
  ZL := Czl[P];
end;

end.
