// Animation transforms -- included from flif_transform.pas.
// Corresponds to: src/transform/framedup.hpp, frameshape.hpp, framecombine.hpp

type
  TTransformFrameDup = class(TTransform)
  protected
    FSeenBefore: TIntArray;
    FNb: Cardinal;
  public
    function UndoRedoDuringDecode: Boolean; override;
    function Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges; override;
    procedure Configure(Setting: Integer); override;
    function Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean; override;
    procedure Save(SrcRanges: TColorRanges; Rac: TRacOut); override;
    function Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean; override;
  end;

function TTransformFrameDup.UndoRedoDuringDecode: Boolean;
begin
  Result := False;
end;

function TTransformFrameDup.Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges;
var
  Fr: Integer;
begin
  for Fr := 0 to High(Imgs) do
    Imgs[Fr].SeenBefore := FSeenBefore[Fr];
  Result := TDupColorRanges.Create(SrcRanges);
end;

procedure TTransformFrameDup.Configure(Setting: Integer);
begin
  FNb := Setting;
end;

function TTransformFrameDup.Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean;
var
  Coder: TSimpleSymbolCoder;
  I, Cnt: Integer;
begin
  Coder := TSimpleSymbolCoder.Create(Rac, nil, 18);
  try
    SetLength(FSeenBefore, 1);
    FSeenBefore[0] := -1;
    for I := 1 to Integer(FNb) - 1 do
    begin
      SetLength(FSeenBefore, I + 1);
      FSeenBefore[I] := Coder.ReadInt(-1, I - 1);
    end;
    Cnt := 0;
    for I := 0 to High(FSeenBefore) do if FSeenBefore[I] >= 0 then Inc(Cnt);
    v_printf(5, Format('[%d]', [Cnt]));
    Result := True;
  finally
    Coder.Free;
  end;
end;

procedure TTransformFrameDup.Save(SrcRanges: TColorRanges; Rac: TRacOut);
var
  Coder: TSimpleSymbolCoder;
  I, Cnt: Integer;
begin
  Coder := TSimpleSymbolCoder.Create(nil, Rac, 18);
  try
    for I := 1 to High(FSeenBefore) do
      Coder.WriteInt(-1, I - 1, FSeenBefore[I]);
    Cnt := 0;
    for I := 0 to High(FSeenBefore) do if FSeenBefore[I] >= 0 then Inc(Cnt);
    v_printf(5, Format('[%d]', [Cnt]));
  finally
    Coder.Free;
  end;
end;

function TTransformFrameDup.Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean;
var
  Np, Fr, Ofr, P, I: Integer;
  DupesFound, Identical: Boolean;
  R, C: Cardinal;
  Img, OImg: TImage;
begin
  Np := SrcRanges.NumPlanes;
  FNb := Length(Imgs);
  SetLength(FSeenBefore, FNb);
  for I := 0 to High(FSeenBefore) do FSeenBefore[I] := -1;
  DupesFound := False;
  for Fr := 1 to High(Imgs) do
  begin
    Img := Imgs[Fr];
    for Ofr := 0 to Fr - 1 do
    begin
      OImg := Imgs[Ofr];
      Identical := True;
      for R := 0 to Img.Rows - 1 do
      begin
        for C := 0 to Img.Cols - 1 do
        begin
          for P := 0 to Np - 1 do
            if Img.GetVal(P, R, C) <> OImg.GetVal(P, R, C) then
            begin
              Identical := False;
              Break;
            end;
          if not Identical then Break;
        end;
        if not Identical then Break;
      end;
      if Identical then
      begin
        FSeenBefore[Fr] := Ofr;
        DupesFound := True;
        Break;
      end;
    end;
  end;
  Result := DupesFound;
end;

type
  TCardinalArray = array of Cardinal;

  TTransformFrameShape = class(TTransform)
  protected
    FB: TCardinalArray;
    FE: TCardinalArray;
    FCols: Cardinal;
    FNb: Cardinal;
  public
    function UndoRedoDuringDecode: Boolean; override;
    function Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges; override;
    procedure Configure(Setting: Integer); override;
    function Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean; override;
    procedure Save(SrcRanges: TColorRanges; Rac: TRacOut); override;
    function Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean; override;
  end;

function TTransformFrameShape.UndoRedoDuringDecode: Boolean;
begin
  Result := False;
end;

function TTransformFrameShape.Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges;
var
  Pos: Cardinal;
  Fr: Integer;
  R: Cardinal;
  Img: TImage;
begin
  Pos := 0;
  for Fr := 1 to High(Imgs) do
  begin
    Img := Imgs[Fr];
    if Img.SeenBefore >= 0 then Continue;
    for R := 0 to Img.Rows - 1 do
    begin
      if Pos >= FNb then Break;
      Img.ColBegin[R] := FB[Pos];
      Img.ColEnd[R] := FE[Pos];
      Inc(Pos);
    end;
  end;
  Result := TDupColorRanges.Create(SrcRanges);
end;

procedure TTransformFrameShape.Configure(Setting: Integer);
begin
  if FNb = 0 then FNb := Setting else FCols := Setting;
end;

function TTransformFrameShape.Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean;
var
  Coder: TSimpleSymbolCoder;
  I: Integer;
begin
  Coder := TSimpleSymbolCoder.Create(Rac, nil, 18);
  try
    SetLength(FB, FNb);
    SetLength(FE, FNb);
    for I := 0 to Integer(FNb) - 1 do
      FB[I] := Coder.ReadInt(0, FCols);
    for I := 0 to Integer(FNb) - 1 do
    begin
      FE[I] := FCols - Cardinal(Coder.ReadInt(0, FCols - FB[I]));
      if (FE[I] > FCols) or (FE[I] < FB[I]) or (FE[I] <= 0) then
      begin
        e_printf(#10'Error: FRS transform: invalid end column'#10);
        Exit(False);
      end;
    end;
    Result := True;
  finally
    Coder.Free;
  end;
end;

procedure TTransformFrameShape.Save(SrcRanges: TColorRanges; Rac: TRacOut);
var
  Coder: TSimpleSymbolCoder;
  I: Integer;
begin
  Coder := TSimpleSymbolCoder.Create(nil, Rac, 18);
  try
    for I := 0 to Integer(FNb) - 1 do Coder.WriteInt(0, FCols, FB[I]);
    for I := 0 to Integer(FNb) - 1 do Coder.WriteInt(0, FCols - FB[I], FCols - FE[I]);
  finally
    Coder.Free;
  end;
end;

function TTransformFrameShape.Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean;
var
  Np, Fr, P, N: Integer;
  R, C: Cardinal;
  Img, Prev: TImage;
  BeginFound, EndFound: Boolean;
begin
  if Length(Imgs) < 2 then Exit(False);
  Np := SrcRanges.NumPlanes;
  FNb := 0;
  FCols := Imgs[0].Cols;
  SetLength(FB, 0);
  SetLength(FE, 0);
  for Fr := 1 to High(Imgs) do
  begin
    Img := Imgs[Fr];
    Prev := Imgs[Fr - 1];
    if Img.SeenBefore >= 0 then Continue;
    Inc(FNb, Img.Rows);
    for R := 0 to Img.Rows - 1 do
    begin
      BeginFound := False;
      for C := 0 to Img.Cols - 1 do
      begin
        if Img.AlphaZeroSpecial and (Np > 3) and (Img.GetVal(3, R, C) = 0) and
           (Prev.GetVal(3, R, C) = 0) then Continue;
        for P := 0 to Np - 1 do
          if Img.GetVal(P, R, C) <> Prev.GetVal(P, R, C) then
          begin
            BeginFound := True;
            Break;
          end;
        if BeginFound then
        begin
          N := Length(FB); SetLength(FB, N + 1); FB[N] := C;
          Break;
        end;
      end;
      if not BeginFound then
      begin
        N := Length(FB); SetLength(FB, N + 1); FB[N] := Img.Cols;
        N := Length(FE); SetLength(FE, N + 1); FE[N] := Img.Cols;
        Continue;
      end;
      EndFound := False;
      C := Img.Cols - 1;
      while C >= FB[High(FB)] do
      begin
        if not (Img.AlphaZeroSpecial and (Np > 3) and (Img.GetVal(3, R, C) = 0) and
                (Prev.GetVal(3, R, C) = 0)) then
        begin
          for P := 0 to Np - 1 do
            if Img.GetVal(P, R, C) <> Prev.GetVal(P, R, C) then
            begin
              EndFound := True;
              Break;
            end;
          if EndFound then
          begin
            N := Length(FE); SetLength(FE, N + 1); FE[N] := C + 1;
            Break;
          end;
        end;
        if C = 0 then Break;
        Dec(C);
      end;
      if not EndFound then
      begin
        N := Length(FE); SetLength(FE, N + 1); FE[N] := 0;
      end;
    end;
  end;
  Result := True;
end;

type
  TColorRangesFC = class(TColorRanges)
  protected
    FNumPrevFrames: ColorVal;
    FAlphaMin: ColorVal;
    FAlphaMax: ColorVal;
    FRanges: TColorRanges;
  public
    constructor Create(Pf, AMin, AMax: ColorVal; ARanges: TColorRanges);
    function IsStatic: Boolean; override;
    function NumPlanes: Integer; override;
    function MinV(P: Integer): ColorVal; override;
    function MaxV(P: Integer): ColorVal; override;
    procedure MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal); override;
    procedure Snap(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal;
      var V: ColorVal); override;
    function Previous: TColorRanges; override;
  end;

constructor TColorRangesFC.Create(Pf, AMin, AMax: ColorVal; ARanges: TColorRanges);
begin
  inherited Create;
  FNumPrevFrames := Pf;
  FAlphaMin := AMin;
  FAlphaMax := AMax;
  FRanges := ARanges;
end;

function TColorRangesFC.IsStatic: Boolean;
begin
  Result := False;
end;

function TColorRangesFC.NumPlanes: Integer;
begin
  Result := 5;
end;

function TColorRangesFC.MinV(P: Integer): ColorVal;
begin
  if P < 3 then Result := FRanges.MinV(P)
  else if P = 3 then Result := FAlphaMin
  else Result := 0;
end;

function TColorRangesFC.MaxV(P: Integer): ColorVal;
begin
  if P < 3 then Result := FRanges.MaxV(P)
  else if P = 3 then Result := FAlphaMax
  else Result := FNumPrevFrames;
end;

procedure TColorRangesFC.MinMax(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal);
begin
  if P >= 3 then
  begin
    MinV_ := MinV(P);
    MaxV_ := MaxV(P);
  end
  else
    FRanges.MinMax(P, PP, MinV_, MaxV_);
end;

procedure TColorRangesFC.Snap(P: Integer; const PP: PrevPlanes; out MinV_, MaxV_: ColorVal;
  var V: ColorVal);
begin
  if P >= 3 then
    inherited Snap(P, PP, MinV_, MaxV_, V)
  else
    FRanges.Snap(P, PP, MinV_, MaxV_, V);
end;

function TColorRangesFC.Previous: TColorRanges;
begin
  Result := FRanges;
end;

type
  TTransformFrameCombine = class(TTransform)
  protected
    FWasFlat: Boolean;
    FWasGrayscale: Boolean;
    FMaxLookback: Integer;
    FUserMaxLookback: Integer;
    FNbFrames: Integer;
  public
    function UndoRedoDuringDecode: Boolean; override;
    function Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges; override;
    function Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean; override;
    procedure Save(SrcRanges: TColorRanges; Rac: TRacOut); override;
    function Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean; override;
    procedure Data(const Imgs: TImages); override;
    procedure Configure(Setting: Integer); override;
    procedure InvData(const Imgs: TImages; StrideCol: Cardinal = 1;
      StrideRow: Cardinal = 1); override;
  end;

function TTransformFrameCombine.UndoRedoDuringDecode: Boolean;
begin
  Result := True;
end;

function TTransformFrameCombine.Meta(const Imgs: TImages; SrcRanges: TColorRanges): TColorRanges;
var
  Fr, Lookback: Integer;
  AMin, AMax: ColorVal;
begin
  FWasGrayscale := SrcRanges.NumPlanes < 2;
  FWasFlat := SrcRanges.NumPlanes < 4;
  for Fr := 0 to High(Imgs) do
    Imgs[Fr].EnsureFrameLookbacks;
  Lookback := Length(Imgs) - 1;
  if Lookback > FMaxLookback then Lookback := FMaxLookback;
  if SrcRanges.NumPlanes = 4 then
  begin
    AMin := SrcRanges.MinV(3);
    AMax := SrcRanges.MaxV(3);
  end
  else
  begin
    AMin := 1;
    AMax := 1;
  end;
  Result := TColorRangesFC.Create(Lookback, AMin, AMax, SrcRanges);
end;

function TTransformFrameCombine.Load(SrcRanges: TColorRanges; Rac: TRacIn): Boolean;
var
  Coder: TSimpleSymbolCoder;
begin
  if SrcRanges.NumPlanes > 4 then Exit(False);
  Coder := TSimpleSymbolCoder.Create(Rac, nil, 18);
  try
    FMaxLookback := Coder.ReadInt2(1, FNbFrames - 1);
    v_printf(5, Format('[%d]', [FMaxLookback]));
    Result := True;
  finally
    Coder.Free;
  end;
end;

procedure TTransformFrameCombine.Save(SrcRanges: TColorRanges; Rac: TRacOut);
var
  Coder: TSimpleSymbolCoder;
begin
  Coder := TSimpleSymbolCoder.Create(nil, Rac, 18);
  try
    Coder.WriteInt2(1, FNbFrames - 1, FMaxLookback);
  finally
    Coder.Free;
  end;
end;

function TTransformFrameCombine.Process(SrcRanges: TColorRanges; const Imgs: TImages): Boolean;
var
  NumP, P, Fr, Prev, I: Integer;
  PixelCost: Int64;
  FoundPixels: array of QWord;
  NewPixels: QWord;
  R, C: Cardinal;
  Img: TImage;
  Identical: Boolean;
begin
  if Length(Imgs) < 2 then Exit(False);
  NumP := Imgs[0].NumPlanes;
  FNbFrames := Length(Imgs);
  PixelCost := 1;
  for P := 0 to NumP - 1 do
    PixelCost := PixelCost * (1 + SrcRanges.MaxV(P) - SrcRanges.MinV(P));
  if PixelCost < 16 then
  begin
    v_printf(7, Format(', no_FRA[pixels_too_cheap:%d]', [PixelCost]));
    Exit(False);
  end;
  SetLength(FoundPixels, Length(Imgs));
  for I := 0 to High(FoundPixels) do FoundPixels[I] := 0;
  NewPixels := 0;
  FMaxLookback := 1;
  if FUserMaxLookback = -1 then FUserMaxLookback := Length(Imgs) - 1;
  for Fr := 1 to High(Imgs) do
  begin
    Img := Imgs[Fr];
    for R := 0 to Img.Rows - 1 do
    begin
      C := Img.ColBegin[R];
      while C < Img.ColEnd[R] do
      begin
        Inc(NewPixels);
        for Prev := 1 to Fr do
        begin
          if Prev > FUserMaxLookback then Break;
          Identical := True;
          if Img.AlphaZeroSpecial and (NumP > 3) and (Img.GetVal(3, R, C) = 0) and
             (Imgs[Fr - Prev].GetVal(3, R, C) = 0) then
            Identical := True
          else
            for P := 0 to NumP - 1 do
              if Img.GetVal(P, R, C) <> Imgs[Fr - Prev].GetVal(P, R, C) then
              begin
                Identical := False;
                Break;
              end;
          if Identical then
          begin
            Inc(FoundPixels[Prev]);
            Dec(NewPixels);
            if Prev > FMaxLookback then FMaxLookback := Prev;
            Break;
          end;
        end;
        Inc(C);
      end;
    end;
  end;
  if FMaxLookback > 256 then FMaxLookback := 256;
  for I := 1 to FMaxLookback do
  begin
    if (FoundPixels[I] <= NewPixels div 200) or (I > PixelCost) then
    begin
      FMaxLookback := I - 1;
      Break;
    end;
    FoundPixels[0] := FoundPixels[0] + FoundPixels[I];
  end;
  for I := FMaxLookback + 1 to Length(Imgs) - 1 do
  begin
    if (FoundPixels[I] > NewPixels div 200) and (I < PixelCost) then
    begin
      FMaxLookback := I;
      FoundPixels[0] := FoundPixels[0] + FoundPixels[I];
    end
    else
      NewPixels := NewPixels + FoundPixels[I];
  end;
  Result := FoundPixels[0] * QWord(PixelCost) > NewPixels * QWord(2 + FMaxLookback);
end;

procedure TTransformFrameCombine.Data(const Imgs: TImages);
var
  Fr, Prev, P: Integer;
  R, C: Cardinal;
  Img: TImage;
  Identical: Boolean;
begin
  for Fr := 1 to High(Imgs) do
  begin
    Img := Imgs[Fr];
    for R := 0 to Img.Rows - 1 do
    begin
      C := Img.ColBegin[R];
      while C < Img.ColEnd[R] do
      begin
        for Prev := 1 to Fr do
        begin
          if Prev > FMaxLookback then Break;
          Identical := True;
          if Img.AlphaZeroSpecial and (Img.GetVal(3, R, C) = 0) and
             (Imgs[Fr - Prev].GetVal(3, R, C) = 0) then
            Identical := True
          else
            for P := 0 to 3 do
              if Img.GetVal(P, R, C) <> Imgs[Fr - Prev].GetVal(P, R, C) then
              begin
                Identical := False;
                Break;
              end;
          if Identical then
          begin
            Img.SetVal(4, R, C, Prev);
            Break;
          end;
        end;
        Inc(C);
      end;
    end;
  end;
end;

procedure TTransformFrameCombine.Configure(Setting: Integer);
begin
  FUserMaxLookback := Setting;
  FNbFrames := Setting;
end;

procedure TTransformFrameCombine.InvData(const Imgs: TImages; StrideCol: Cardinal;
  StrideRow: Cardinal);
var
  I: Integer;
begin
  for I := 0 to High(Imgs) do Imgs[I].DropFrameLookbacks;
  if FWasFlat then for I := 0 to High(Imgs) do Imgs[I].DropAlpha;
  if FWasGrayscale then for I := 0 to High(Imgs) do Imgs[I].DropColor;
end;
