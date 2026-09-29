// Color_Buckets transform -- included from flif_transform.pas.
// Corresponds to: src/transform/colorbuckets.hpp

const
  MAX_PER_BUCKET_0 = 255;
  MAX_PER_BUCKET_1 = 510;
  MAX_PER_BUCKET_2 = 5;
  MAX_PER_BUCKET_3 = 255;
  MaxPerColorBucket: array[0..3] of Integer =
    (MAX_PER_BUCKET_0, MAX_PER_BUCKET_1, MAX_PER_BUCKET_2, MAX_PER_BUCKET_3);
  CB0a = 1;
  CB0b = 1;
  CB1 = 4;

type
  ColorValCB = Int16;
  TColorValCBArray = array of ColorValCB;

  TColorBucket = record
    SnapValues: TColorValCBArray;
    Values: TColorValCBArray;
    Min, Max: ColorValCB;
    Discrete: Boolean;
  end;
  PColorBucket = ^TColorBucket;
  TColorBucketArray = array of TColorBucket;
  TColorBucketMatrix = array of TColorBucketArray;

var
  TotalDiscreteColors: Integer = 0;
  TotalContinuousBuckets: Integer = 0;

procedure BucketInit(var B: TColorBucket);
begin
  SetLength(B.SnapValues, 0);
  SetLength(B.Values, 0);
  B.Min := 10000;
  B.Max := -10000;
  B.Discrete := True;
end;

procedure BucketAddColor(var B: TColorBucket; C: ColorVal; MaxPerBucket: Integer);
var
  Pos, N: Integer;
begin
  if C < B.Min then B.Min := C;
  if C > B.Max then B.Max := C;
  if B.Discrete then
  begin
    Pos := 0;
    while Pos < Length(B.Values) do
    begin
      if C = B.Values[Pos] then Exit;
      if B.Values[Pos] > C then Break;
      Inc(Pos);
    end;
    if Length(B.Values) < MaxPerBucket then
    begin
      N := Length(B.Values);
      SetLength(B.Values, N + 1);
      if N > Pos then
        Move(B.Values[Pos], B.Values[Pos + 1], (N - Pos) * SizeOf(ColorValCB));
      B.Values[Pos] := C;
      Inc(TotalDiscreteColors);
    end
    else
    begin
      Dec(TotalDiscreteColors, MaxPerBucket);
      SetLength(B.Values, 0);
      B.Discrete := False;
      Inc(TotalContinuousBuckets);
    end;
  end;
end;

function BucketRemoveColor(var B: TColorBucket; C: ColorVal): Boolean;
var
  Pos, N: Integer;
  X: ColorVal;
begin
  if B.Discrete then
  begin
    Pos := 0;
    while Pos < Length(B.Values) do
    begin
      if C = B.Values[Pos] then
      begin
        N := Length(B.Values);
        if Pos < N - 1 then
          Move(B.Values[Pos + 1], B.Values[Pos], (N - 1 - Pos) * SizeOf(ColorValCB));
        SetLength(B.Values, N - 1);
        Break;
      end;
      Inc(Pos);
    end;
    if Length(B.Values) = 0 then
    begin
      B.Min := 10000;
      B.Max := -10000;
      Exit(True);
    end;
    if C = B.Min then B.Min := B.Values[0];
    if C = B.Max then B.Max := B.Values[Length(B.Values) - 1];
  end
  else
  begin
    if C = B.Min then Inc(B.Min);
    if C = B.Max then Dec(B.Max);
    if C > B.Max then Exit(True);
    if C < B.Min then Exit(True);
    B.Discrete := True;
    SetLength(B.Values, 0);
    X := B.Min;
    while X <= B.Max do
    begin
      if X <> C then
      begin
        SetLength(B.Values, Length(B.Values) + 1);
        B.Values[High(B.Values)] := X;
      end;
      Inc(X);
    end;
  end;
  Result := True;
end;

function BucketEmpty(const B: TColorBucket): Boolean; inline;
begin
  Result := B.Min > B.Max;
end;

function BucketSnapColorSlow(const B: TColorBucket; C: ColorVal): ColorVal;
var
  MinDiff, Diff: ColorVal;
  Best, I: Integer;
begin
  if C <= B.Min then Exit(B.Min);
  if C >= B.Max then Exit(B.Max);
  if B.Discrete then
  begin
    MinDiff := Abs(C - B.Min);
    Best := 0;
    for I := 1 to Length(B.Values) - 1 do
    begin
      if C = B.Values[I] then Exit(C);
      Diff := Abs(C - B.Values[I]);
      if Diff < MinDiff then begin Best := I; MinDiff := Diff; end;
      if B.Values[I] > C then Break;
    end;
    Exit(B.Values[Best]);
  end;
  Result := C;
end;

procedure BucketPrepareSnapValues(var B: TColorBucket);
var
  C: ColorVal;
  N: Integer;
begin
  if B.Discrete then
  begin
    SetLength(B.SnapValues, 0);
    N := 0;
    C := B.Min;
    while C < B.Max do
    begin
      SetLength(B.SnapValues, N + 1);
      B.SnapValues[N] := BucketSnapColorSlow(B, C);
      Inc(N);
      Inc(C);
    end;
  end;
end;

procedure BucketSimplifyLossless(var B: TColorBucket);
begin
  if B.Discrete then
    if Length(B.Values) = B.Max - B.Min + 1 then
    begin
      B.Discrete := False;
      Dec(TotalDiscreteColors, Length(B.Values));
      Inc(TotalContinuousBuckets);
      SetLength(B.Values, 0);
    end;
end;

procedure BucketSimplify(var B: TColorBucket; Percent: Integer);
begin
  if BucketEmpty(B) then Exit;
  BucketSimplifyLossless(B);
  if B.Discrete then
    if Length(B.Values) - 2 > (B.Max - B.Min - 1) * Percent div 100 then
    begin
      B.Discrete := False;
      Dec(TotalDiscreteColors, Length(B.Values));
      Inc(TotalContinuousBuckets);
      SetLength(B.Values, 0);
    end;
end;

function BucketSnapColor(const B: TColorBucket; C: ColorVal): ColorVal; inline;
begin
  if C <= B.Min then Exit(B.Min);
  if C >= B.Max then Exit(B.Max);
  if B.Discrete then Exit(B.SnapValues[C - B.Min]);
  Result := C;
end;

type
  TColorBuckets = class
  public
    Bucket0: TColorBucket;
    Min0, Min1: Integer;
    Bucket1: TColorBucketArray;
    Bucket2: TColorBucketMatrix;
    Bucket3: TColorBucket;
    EmptyBucket: TColorBucket;
    Ranges: TColorRanges;
    constructor Create(R: TColorRanges);
    function FindBucket(P: Integer; const PP: PrevPlanes): PColorBucket;
    function FindBucketChecked(P: Integer; const PP: PrevPlanes): PColorBucket;
    procedure AddColor(const Pixel: PrevPlanes; NPlanes: Integer);
    function Exists(P: Integer; const PP: PrevPlanes): Boolean;
    function ExistsRange(P: Integer; const Lower, Upper: PrevPlanes): Boolean;
  end;

constructor TColorBuckets.Create(R: TColorRanges);
var
  I, J: Integer;
begin
  inherited Create;
  Ranges := R;
  BucketInit(Bucket0);
  BucketInit(Bucket3);
  BucketInit(EmptyBucket);
  Min0 := R.MinV(0);
  Min1 := R.MinV(1);
  SetLength(Bucket1, (R.MaxV(0) - Min0) div CB0a + 1);
  for I := 0 to High(Bucket1) do BucketInit(Bucket1[I]);
  SetLength(Bucket2, (R.MaxV(0) - Min0) div CB0b + 1);
  for I := 0 to High(Bucket2) do
  begin
    SetLength(Bucket2[I], (R.MaxV(1) - Min1) div CB1 + 1);
    for J := 0 to High(Bucket2[I]) do BucketInit(Bucket2[I][J]);
  end;
end;

function TColorBuckets.FindBucket(P: Integer; const PP: PrevPlanes): PColorBucket;
begin
  if P = 0 then Exit(@Bucket0);
  if P = 1 then Exit(@Bucket1[(PP[0] - Min0) div CB0a]);
  if P = 2 then Exit(@Bucket2[(PP[0] - Min0) div CB0b][(PP[1] - Min1) div CB1]);
  Result := @Bucket3;
end;

function TColorBuckets.FindBucketChecked(P: Integer; const PP: PrevPlanes): PColorBucket;
var
  I, J: Integer;
begin
  if P = 0 then Exit(@Bucket0);
  if P = 1 then
  begin
    I := (PP[0] - Min0) div CB0a;
    if (I >= 0) and (I < Length(Bucket1)) then Exit(@Bucket1[I]) else Exit(@EmptyBucket);
  end;
  if P = 2 then
  begin
    I := (PP[0] - Min0) div CB0b;
    J := (PP[1] - Min1) div CB1;
    if (I >= 0) and (I < Length(Bucket2)) and (J >= 0) and (J < Length(Bucket2[I])) then
      Exit(@Bucket2[I][J])
    else
      Exit(@EmptyBucket);
  end;
  Result := @Bucket3;
end;

procedure TColorBuckets.AddColor(const Pixel: PrevPlanes; NPlanes: Integer);
var
  P: Integer;
begin
  for P := 0 to NPlanes - 1 do
    BucketAddColor(FindBucket(P, Pixel)^, Pixel[P], MaxPerColorBucket[P]);
end;

function TColorBuckets.Exists(P: Integer; const PP: PrevPlanes): Boolean;
var
  RMin, RMax, V: ColorVal;
  B: PColorBucket;
  Tmp: PrevPlanes;
begin
  if (P > 0) and ((PP[0] < Min0) or (PP[0] > Ranges.MaxV(0))) then Exit(False);
  if (P > 1) and ((PP[1] < Min1) or (PP[1] > Ranges.MaxV(1))) then Exit(False);
  V := PP[P];
  Tmp := PP;
  Ranges.Snap(P, Tmp, RMin, RMax, V);
  if V <> PP[P] then Exit(False);
  B := FindBucketChecked(P, PP);
  if BucketSnapColorSlow(B^, PP[P]) <> PP[P] then Exit(False);
  Result := True;
end;

function TColorBuckets.ExistsRange(P: Integer; const Lower, Upper: PrevPlanes): Boolean;
var
  Pixel: PrevPlanes;
begin
  Pixel := Copy(Lower);
  if P = 0 then
  begin
    Pixel[0] := Lower[0];
    while Pixel[0] <= Upper[0] do
    begin
      if Exists(P, Pixel) then Exit(True);
      Inc(Pixel[0]);
    end;
  end;
  if P = 1 then
  begin
    Pixel[0] := Lower[0];
    while Pixel[0] <= Upper[0] do
    begin
      Pixel[1] := Lower[1];
      while Pixel[1] <= Upper[1] do
      begin
        if Exists(P, Pixel) then Exit(True);
        Inc(Pixel[1]);
      end;
      Inc(Pixel[0]);
    end;
  end;
  Result := False;
end;

type
  TColorRangesCB = class(TColorRanges)
  protected
    FRanges: TColorRanges;
    FBuckets: TColorBuckets;
  public
    constructor Create(ARanges: TColorRanges; CB: TColorBuckets);
    destructor Destroy; override;
    function IsStatic: Boolean; override;
    function NumPlanes: Integer; override;
    function MinV(P: Integer): ColorVal; override;
    function MaxV(P: Integer): ColorVal; override;
    procedure Snap(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal;
      var V: ColorVal); override;
    procedure MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal); override;
  end;

constructor TColorRangesCB.Create(ARanges: TColorRanges; CB: TColorBuckets);
begin
  inherited Create;
  FRanges := ARanges;
  FBuckets := CB;
end;

destructor TColorRangesCB.Destroy;
begin
  FBuckets.Free;
  inherited Destroy;
end;

function TColorRangesCB.IsStatic: Boolean;
begin
  Result := False;
end;

function TColorRangesCB.NumPlanes: Integer;
begin
  Result := FRanges.NumPlanes;
end;

function TColorRangesCB.MinV(P: Integer): ColorVal;
begin
  Result := FRanges.MinV(P);
end;

function TColorRangesCB.MaxV(P: Integer): ColorVal;
begin
  Result := FRanges.MaxV(P);
end;

procedure TColorRangesCB.Snap(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal;
  var V: ColorVal);
var
  B: PColorBucket;
begin
  B := FBuckets.FindBucketChecked(P, PP);
  MinV_ := B^.Min;
  MaxV_ := B^.Max;
  if B^.Min > B^.Max then
  begin
    e_printf('Corruption detected!'#10);
    MinV_ := MinV(P);
    V := MinV(P);
    MaxV_ := MaxV(P);
    Exit;
  end;
  V := BucketSnapColor(B^, V);
end;

procedure TColorRangesCB.MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal);
var
  B: PColorBucket;
begin
  B := FBuckets.FindBucketChecked(P, PP);
  MinV_ := B^.Min;
  MaxV_ := B^.Max;
  if B^.Min > B^.Max then
  begin
    e_printf('Corruption detected!'#10);
    MinV_ := MinV(P);
    MaxV_ := MaxV(P);
  end;
end;

type
  TCoderArray6 = array[0..5] of TSimpleSymbolCoder;

  TTransformCB = class(TTransform)
  protected
    FCB: TColorBuckets;
    FReallyUsed: Boolean;
    function LoadBucket(var Coder: TCoderArray6; SrcRanges: TColorRanges;
      Plane: Integer; const PixelL, PixelU: PrevPlanes): TColorBucket;
    procedure SaveBucket(const B: TColorBucket; var Coder: TCoderArray6;
      SrcRanges: TColorRanges; Plane: Integer; const PixelL, PixelU: PrevPlanes);
  public
    constructor Create;
    destructor Destroy; override;
    function UndoRedoDuringDecode: Boolean; override;
    function Init(SrcRanges: TColorRanges): Boolean; override;
    function Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges; override;
    function Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean; override;
    procedure Save(SrcRanges: TColorRanges; Rac: TRacOut); override;
    function Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean; override;
  end;

constructor TTransformCB.Create;
begin
  inherited Create;
  FCB := nil;
  FReallyUsed := False;
end;

destructor TTransformCB.Destroy;
begin
  if not FReallyUsed then FCB.Free;
  inherited Destroy;
end;

function TTransformCB.UndoRedoDuringDecode: Boolean;
begin
  Result := False;
end;

function TTransformCB.Init(SrcRanges: TColorRanges): Boolean;
begin
  FCB := nil;
  FReallyUsed := False;
  if SrcRanges.NumPlanes < 3 then Exit(False);
  if (SrcRanges.MinV(1) = SrcRanges.MaxV(1)) and (SrcRanges.MinV(2) = SrcRanges.MaxV(2)) then Exit(False);
  if (SrcRanges.MinV(0) = 0) and (SrcRanges.MaxV(0) = 0) and
     (SrcRanges.MinV(2) = 0) and (SrcRanges.MaxV(2) = 0) then Exit(False);
  if (SrcRanges.MinV(0) = SrcRanges.MaxV(0)) and (SrcRanges.MinV(1) = SrcRanges.MaxV(1)) and
     (SrcRanges.MinV(2) = SrcRanges.MaxV(2)) then Exit(False);
  if SrcRanges.MaxV(0) - SrcRanges.MinV(0) > 1023 then Exit(False);
  if SrcRanges.MaxV(1) - SrcRanges.MinV(1) > 1023 then Exit(False);
  if SrcRanges.MaxV(2) - SrcRanges.MinV(2) > 1023 then Exit(False);
  if SrcRanges.MinV(1) = SrcRanges.MaxV(1) then Exit(False);
  FCB := TColorBuckets.Create(SrcRanges);
  Result := True;
end;

function TTransformCB.Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges;
var
  PixelL, PixelU: PrevPlanes;
  I, J: Integer;
  C: ColorVal;
begin
  // in the I buckets, some discrete buckets may have become continuous;
  // this means some Q buckets are empty, so some I values can be eliminated
  if SrcRanges.MinV(2) < SrcRanges.MaxV(2) then
  begin
    SetLength(PixelL, 2);
    SetLength(PixelU, 2);
    PixelL[0] := FCB.Min0;
    PixelU[0] := FCB.Min0 + CB0b - 1;
    PixelL[1] := FCB.Min1;
    PixelU[1] := FCB.Min1 + CB1 - 1;
    for I := 0 to High(FCB.Bucket2) do
    begin
      PixelL[1] := FCB.Min1;
      PixelU[1] := FCB.Min1 + CB1 - 1;
      for J := 0 to High(FCB.Bucket2[I]) do
      begin
        if BucketEmpty(FCB.Bucket2[I][J]) then
        begin
          C := PixelL[1];
          while C <= PixelU[1] do
          begin
            if not BucketRemoveColor(FCB.FindBucket(1, PixelL)^, C) then Exit(nil);
            if not BucketRemoveColor(FCB.FindBucket(1, PixelU)^, C) then Exit(nil);
            Inc(C);
          end;
        end;
        Inc(PixelL[1], CB1);
        Inc(PixelU[1], CB1);
      end;
      Inc(PixelL[0], CB0b);
      Inc(PixelU[0], CB0b);
    end;
  end;
  BucketPrepareSnapValues(FCB.Bucket0);
  BucketPrepareSnapValues(FCB.Bucket3);
  for I := 0 to High(FCB.Bucket1) do BucketPrepareSnapValues(FCB.Bucket1[I]);
  for I := 0 to High(FCB.Bucket2) do
    for J := 0 to High(FCB.Bucket2[I]) do BucketPrepareSnapValues(FCB.Bucket2[I][J]);
  FReallyUsed := True;
  Result := TColorRangesCB.Create(SrcRanges, FCB);
end;

procedure CBMinMax(SrcRanges: TColorRanges; P: Integer; const Lower, Upper: PrevPlanes;
  out SMin, SMax: ColorVal);
var
  RMin, RMax: ColorVal;
  Pixel: PrevPlanes;
begin
  SMin := 10000;
  SMax := -10000;
  Pixel := Copy(Lower);
  if P = 0 then
    SrcRanges.MinMax(P, Pixel, SMin, SMax)
  else if P = 1 then
  begin
    Pixel[0] := Lower[0];
    while Pixel[0] <= Upper[0] do
    begin
      SrcRanges.MinMax(P, Pixel, RMin, RMax);
      if RMin < SMin then SMin := RMin;
      if RMax > SMax then SMax := RMax;
      Inc(Pixel[0]);
    end;
  end
  else if P = 2 then
  begin
    Pixel[0] := Lower[0];
    while Pixel[0] <= Upper[0] do
    begin
      Pixel[1] := Lower[1];
      while Pixel[1] <= Upper[1] do
      begin
        SrcRanges.MinMax(P, Pixel, RMin, RMax);
        if RMin < SMin then SMin := RMin;
        if RMax > SMax then SMax := RMax;
        Inc(Pixel[1]);
      end;
      Inc(Pixel[0]);
    end;
  end
  else if P = 3 then
    SrcRanges.MinMax(P, Pixel, SMin, SMax);
end;

function TTransformCB.LoadBucket(var Coder: TCoderArray6; SrcRanges: TColorRanges;
  Plane: Integer; const PixelL, PixelU: PrevPlanes): TColorBucket;
var
  B: TColorBucket;
  P, ExistsFlag, Nb, N: Integer;
  SMin, SMax, V: ColorVal;
begin
  BucketInit(B);
  if Plane < 3 then
    for P := 0 to Plane - 1 do
      if not FCB.ExistsRange(P, PixelL, PixelU) then Exit(B);

  CBMinMax(SrcRanges, Plane, PixelL, PixelU, SMin, SMax);

  ExistsFlag := Coder[0].ReadInt2(0, 1);
  if ExistsFlag = 0 then Exit(B);
  if SMin = SMax then
  begin
    B.Min := SMin;
    B.Max := SMin;
    B.Discrete := False;
    Exit(B);
  end;
  B.Min := Coder[1].ReadInt2(SMin, SMax);
  B.Max := Coder[2].ReadInt2(B.Min, SMax);
  if B.Min = B.Max then begin B.Discrete := False; Exit(B); end;
  if B.Min + 1 = B.Max then begin B.Discrete := False; Exit(B); end;
  B.Discrete := Coder[3].ReadInt2(0, 1) <> 0;
  if B.Discrete then
  begin
    Nb := Coder[4].ReadInt2(2, MinI(MaxPerColorBucket[Plane], B.Max - B.Min));
    SetLength(B.Values, 1);
    B.Values[0] := B.Min;
    V := B.Min;
    for P := 1 to Nb - 2 do
    begin
      N := Length(B.Values);
      SetLength(B.Values, N + 1);
      B.Values[N] := Coder[5].ReadInt2(V + 1, B.Max + 1 - Nb + P);
      V := B.Values[P];
    end;
    if B.Min < B.Max then
    begin
      N := Length(B.Values);
      SetLength(B.Values, N + 1);
      B.Values[N] := B.Max;
    end;
  end;
  Result := B;
end;

procedure TTransformCB.SaveBucket(const B: TColorBucket; var Coder: TCoderArray6;
  SrcRanges: TColorRanges; Plane: Integer; const PixelL, PixelU: PrevPlanes);
var
  P, Nb: Integer;
  SMin, SMax, V: ColorVal;
begin
  if Plane < 3 then
    for P := 0 to Plane - 1 do
      if not FCB.ExistsRange(P, PixelL, PixelU) then Exit;

  CBMinMax(SrcRanges, Plane, PixelL, PixelU, SMin, SMax);

  if B.Min > B.Max then
  begin
    Coder[0].WriteInt2(0, 1, 0);   // empty bucket
    Exit;
  end
  else
    Coder[0].WriteInt2(0, 1, 1);   // non-empty bucket
  if SMin = SMax then Exit;

  Coder[1].WriteInt2(SMin, SMax, B.Min);
  Coder[2].WriteInt2(B.Min, SMax, B.Max);
  if B.Min = B.Max then Exit;
  if B.Min + 1 = B.Max then Exit;
  Coder[3].WriteInt2(0, 1, Ord(B.Discrete));
  if B.Discrete then
  begin
    Coder[4].WriteInt2(2, MinI(MaxPerColorBucket[Plane], B.Max - B.Min), Length(B.Values));
    V := B.Min;
    Nb := Length(B.Values);
    for P := 1 to Nb - 2 do
    begin
      Coder[5].WriteInt2(V + 1, B.Max + 1 - Nb + P, B.Values[P]);
      V := B.Values[P];
    end;
  end;
end;

function TTransformCB.Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean;
var
  Coders: TCoderArray6;
  PixelL, PixelU: PrevPlanes;
  I, J: Integer;
begin
  for I := 0 to 5 do Coders[I] := TSimpleSymbolCoder.Create(Rac, nil, 18);
  try
    SetLength(PixelL, 0);
    SetLength(PixelU, 0);
    FCB.Bucket0 := LoadBucket(Coders, SrcRanges, 0, PixelL, PixelU);
    SetLength(PixelL, 1); SetLength(PixelU, 1);
    PixelL[0] := FCB.Min0;
    PixelU[0] := FCB.Min0 + CB0a - 1;
    for I := 0 to High(FCB.Bucket1) do
    begin
      FCB.Bucket1[I] := LoadBucket(Coders, SrcRanges, 1, PixelL, PixelU);
      Inc(PixelL[0], CB0a);
      Inc(PixelU[0], CB0a);
    end;
    if SrcRanges.MinV(2) < SrcRanges.MaxV(2) then
    begin
      PixelL[0] := FCB.Min0;
      PixelU[0] := FCB.Min0 + CB0b - 1;
      SetLength(PixelL, 2); SetLength(PixelU, 2);
      PixelL[1] := FCB.Min1;
      PixelU[1] := FCB.Min1 + CB1 - 1;
      for I := 0 to High(FCB.Bucket2) do
      begin
        PixelL[1] := FCB.Min1;
        PixelU[1] := FCB.Min1 + CB1 - 1;
        for J := 0 to High(FCB.Bucket2[I]) do
        begin
          FCB.Bucket2[I][J] := LoadBucket(Coders, SrcRanges, 2, PixelL, PixelU);
          Inc(PixelL[1], CB1);
          Inc(PixelU[1], CB1);
        end;
        Inc(PixelL[0], CB0b);
        Inc(PixelU[0], CB0b);
      end;
    end;
    if SrcRanges.NumPlanes > 3 then
      FCB.Bucket3 := LoadBucket(Coders, SrcRanges, 3, PixelL, PixelU);
    Result := True;
  finally
    for I := 0 to 5 do Coders[I].Free;
  end;
end;

procedure TTransformCB.Save(SrcRanges: TColorRanges; Rac: TRacOut);
var
  Coders: TCoderArray6;
  PixelL, PixelU: PrevPlanes;
  I, J: Integer;
begin
  for I := 0 to 5 do Coders[I] := TSimpleSymbolCoder.Create(nil, Rac, 18);
  try
    SetLength(PixelL, 0);
    SetLength(PixelU, 0);
    SaveBucket(FCB.Bucket0, Coders, SrcRanges, 0, PixelL, PixelU);
    SetLength(PixelL, 1); SetLength(PixelU, 1);
    PixelL[0] := FCB.Min0;
    PixelU[0] := FCB.Min0 + CB0a - 1;
    for I := 0 to High(FCB.Bucket1) do
    begin
      SaveBucket(FCB.Bucket1[I], Coders, SrcRanges, 1, PixelL, PixelU);
      Inc(PixelL[0], CB0a);
      Inc(PixelU[0], CB0a);
    end;
    if SrcRanges.MinV(2) < SrcRanges.MaxV(2) then
    begin
      PixelL[0] := FCB.Min0;
      PixelU[0] := FCB.Min0 + CB0b - 1;
      SetLength(PixelL, 2); SetLength(PixelU, 2);
      PixelL[1] := FCB.Min1;
      PixelU[1] := FCB.Min1 + CB1 - 1;
      for I := 0 to High(FCB.Bucket2) do
      begin
        PixelL[1] := FCB.Min1;
        PixelU[1] := FCB.Min1 + CB1 - 1;
        for J := 0 to High(FCB.Bucket2[I]) do
        begin
          SaveBucket(FCB.Bucket2[I][J], Coders, SrcRanges, 2, PixelL, PixelU);
          Inc(PixelL[1], CB1);
          Inc(PixelU[1], CB1);
        end;
        Inc(PixelL[0], CB0b);
        Inc(PixelU[0], CB0b);
      end;
    end;
    if SrcRanges.NumPlanes > 3 then
      SaveBucket(FCB.Bucket3, Coders, SrcRanges, 3, PixelL, PixelU);
  finally
    for I := 0 to 5 do Coders[I].Free;
  end;
end;

function TTransformCB.Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean;
var
  Pixel: PrevPlanes;
  I, P, Factor: Integer;
  R, C: Cardinal;
  Img: TImage;
  TotalPixels: Int64;
  J: Integer;
begin
  SetLength(Pixel, Imgs[0].NumPlanes);
  for I := 0 to High(Imgs) do
  begin
    Img := Imgs[I];
    for R := 0 to Img.Rows - 1 do
      for C := 0 to Img.Cols - 1 do
      begin
        for P := 0 to Img.NumPlanes - 1 do
          Pixel[P] := Img.GetVal(P, R, C);
        if Img.AlphaZeroSpecial and (Img.NumPlanes > 3) and (Pixel[3] = 0) then
        begin
          BucketAddColor(FCB.FindBucket(3, Pixel)^, 0, MaxPerColorBucket[3]);
          Continue;
        end;
        FCB.AddColor(Pixel, Img.NumPlanes);
      end;
  end;

  BucketSimplifyLossless(FCB.Bucket0);
  BucketSimplifyLossless(FCB.Bucket3);
  for I := 0 to High(FCB.Bucket1) do BucketSimplifyLossless(FCB.Bucket1[I]);
  for I := 0 to High(FCB.Bucket2) do
    for J := 0 to High(FCB.Bucket2[I]) do BucketSimplifyLossless(FCB.Bucket2[I][J]);

  TotalPixels := Int64(Length(Imgs)) * Int64(Imgs[0].Rows) * Int64(Imgs[0].Cols);
  v_printf(7, Format(', [D=%d,C=%d,P=%d]',
    [TotalDiscreteColors, TotalContinuousBuckets, Integer(TotalPixels div 100)]));
  if TotalPixels > 5000000 then TotalPixels := 5000000;
  if (TotalDiscreteColors < TotalPixels div 200) and (TotalContinuousBuckets < TotalPixels div 50) then Exit(True);
  if (TotalDiscreteColors < TotalPixels div 100) and (TotalContinuousBuckets < TotalPixels div 200) then Exit(True);
  if (TotalDiscreteColors < TotalPixels div 40) and (TotalContinuousBuckets < TotalPixels div 500) then Exit(True);

  Factor := 95;
  while Factor >= 35 do
  begin
    for I := 0 to High(FCB.Bucket1) do BucketSimplify(FCB.Bucket1[I], Factor);
    for I := 0 to High(FCB.Bucket2) do
      for J := 0 to High(FCB.Bucket2[I]) do BucketSimplify(FCB.Bucket2[I][J], Factor - 20);
    v_printf(8, Format('->[D=%d,C=%d]', [TotalDiscreteColors, TotalContinuousBuckets]));
    if (TotalDiscreteColors < TotalPixels div 200) and (TotalContinuousBuckets < TotalPixels div 100) then Exit(True);
    Dec(Factor, 10);
  end;
  Result := False;
end;
