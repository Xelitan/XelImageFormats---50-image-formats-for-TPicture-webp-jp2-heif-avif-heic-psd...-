// FLIF - Free Lossless Image Format -- Free Pascal port
// Decoder.
// Corresponds to: src/flif-dec.cpp
//
// Not ported: the progressive-callback/partial-image machinery of the C API
// and the "!<arch>" wrapper.  Partial decoding via -q/-s and truncated-file
// interpolation are supported.
unit flif_dec;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, flif_types, flif_io, flif_rac, flif_chance, flif_symbol, flif_image,
  flif_colorrange, flif_maniac, flif_common, flif_transform;

type
  TFlifInfo = record
    Width, Height: Cardinal;
    Channels: Byte;
    BitDepth: Byte;
    NumImages: SizeInt;
    Valid: Boolean;
  end;

function FlifDecode(IO: TFlifIO; var Imgs: TImages; var Options: TFlifOptions;
  const MD: TMetadataOptions; PInfo: PPointer = nil): Boolean;

function FlifDecodeEx(IO: TFlifIO; var Imgs: TImages; var Options: TFlifOptions;
  const MD: TMetadataOptions; WantInfo: Boolean; out Info: TFlifInfo): Boolean;

implementation

type
  TTransformArray = array of TTransform;

function ReadName(Rac: TRacIn; out Nb: Integer): string;
var
  Coder: TUniformSymbolCoder;
begin
  Coder := TUniformSymbolCoder.Create(Rac, nil);
  try
    Nb := Coder.ReadInt(0, MAX_TRANSFORM);
    if Nb > MAX_TRANSFORM then Nb := MAX_TRANSFORM;
    Result := TransformNames[Nb];
  finally
    Coder.Free;
  end;
end;

function ReadBigEndianVarint(IO: TFlifIO): QWord;
var
  Result_: QWord;
  BytesRead, Number: Integer;
begin
  Result_ := 0;
  BytesRead := 0;
  while BytesRead < 10 do
  begin
    Inc(BytesRead);
    Number := IO.GetC;
    if Number < 0 then Break;
    if Number < 128 then Exit(Result_ + QWord(Number));
    Number := Number - 128;
    Result_ := Result_ + QWord(Number);
    Result_ := Result_ shl 7;
  end;
  e_printf('Invalid number encountered!'#10);
  Result := 0;
end;

// 0 = read next chunk, 1 = final chunk, negative = error
function ReadChunk(IO: TFlifIO; var M: TMetaData): Integer;
var
  Buf: array[0..4] of AnsiChar;
  C: Integer;
  I: SizeInt;
begin
  C := IO.GetC;
  if C < 32 then
  begin
    if C > 0 then
    begin
      e_printf('This is not a FLIF16 image, but a more recent FLIF file.'#10);
      Exit(-2);
    end;
    Exit(1);
  end;
  Buf[0] := AnsiChar(C);
  if not IO.Gets(@Buf[1], 4) then Exit(-1);
  M.Name := string(AnsiString(PAnsiChar(@Buf[0])));
  if (M.Name <> 'iCCP') and (M.Name <> 'eXif') and (M.Name <> 'eXmp') then
  begin
    if Buf[0] > 'Z' then
      v_printf(1, Format('Warning: Encountered unknown chunk: %s'#10, [M.Name]))
    else
    begin
      e_printf(Format('Error: Encountered unknown critical chunk: %s'#10, [M.Name]));
      Exit(-1);
    end;
  end;
  M.Length := SizeInt(ReadBigEndianVarint(IO));
  SetLength(M.Contents, M.Length);
  for I := 0 to M.Length - 1 do
    M.Contents[I] := Byte(IO.GetC);
  Result := 0;
end;

// ------------------------------------------------------------------
// scanline decoding
// ------------------------------------------------------------------

procedure FlifDecodeScanlinePlane(Plane: TGeneralPlane; Coder: TPropCoderBase;
  const Imgs: TImages; R: TColorRanges; Alpha: TGeneralPlane; var Props: Properties;
  P, Fr: Integer; Row: Cardinal; Grey, MinP: ColorVal; AlphaZero, FRA: Boolean);
var
  MinV, MaxV, Guess, Curr: ColorVal;
  Img: TImage;
  RBegin, REnd, C: Cardinal;
begin
  Img := Imgs[Fr];
  RBegin := 0;
  REnd := Img.Cols;

  // if this is a duplicate frame, copy the row from the frame being duplicated
  if Img.SeenBefore >= 0 then
  begin
    Plane.CopyRowRange(Imgs[Img.SeenBefore].GetPlane(P), Row, 0, Img.Cols, 1);
    Exit;
  end;
  // fill the beginning of the row before the actual pixel data
  if Fr > 0 then
  begin
    RBegin := Img.ColBegin[Row];
    REnd := Img.ColEnd[Row];
    if AlphaZero and (P < 3) then
    begin
      for C := 0 to RBegin - 1 do
        if Alpha.GetPix(Row, C) = 0 then
          Plane.SetPix(Row, C, PredictScanlinesPlane(Plane, Row, C, Grey))
        else
          Img.SetVal(P, Row, C, Imgs[Fr - 1].GetVal(P, Row, C));
    end
    else if P <> 4 then
      Plane.CopyRowRange(Imgs[Fr - 1].GetPlane(P), Row, 0, RBegin, 1);
  end;

  C := RBegin;
  while C < REnd do
  begin
    if AlphaZero and (P < 3) and (Alpha.GetPix(Row, C) = 0) then
    begin
      Plane.SetPix(Row, C, PredictScanlinesPlane(Plane, Row, C, Grey));
      Inc(C);
      Continue;
    end;
    if FRA and (P < 4) and (Img.GetFRA(Row, C) > 0) then
    begin
      Plane.SetPix(Row, C, Imgs[Fr - Img.GetFRA(Row, C)].GetVal(P, Row, C));
      Inc(C);
      Continue;
    end;
    Guess := PredictAndCalcPropsScanlinesPlane(Props, R, Img, Plane, P, Row, C, MinV, MaxV, MinP);
    if FRA and (P = 4) and (MaxV > Fr) then MaxV := Fr;
    Curr := Coder.ReadInt(Props, MinV - Guess, MaxV - Guess) + Guess;
    Plane.SetPix(Row, C, Curr);
    Inc(C);
  end;

  // fill the end of the row after the actual pixel data
  if Fr > 0 then
  begin
    if AlphaZero and (P < 3) then
    begin
      for C := REnd to Img.Cols - 1 do
        if Alpha.GetPix(Row, C) = 0 then
          Plane.SetPix(Row, C, PredictScanlinesPlane(Plane, Row, C, Grey))
        else
          Img.SetVal(P, Row, C, Imgs[Fr - 1].GetVal(P, Row, C));
    end
    else if P <> 4 then
      Plane.CopyRowRange(Imgs[Fr - 1].GetPlane(P), Row, REnd, Img.Cols, 1);
  end;
end;

function FlifDecodeScanlinesInner(IO: TFlifIO; const Coders: TPropCoderArray;
  const Imgs: TImages; R: TColorRanges; var Options: TFlifOptions;
  var Progress: TProgress): Boolean;
var
  Nump, K, P, I, Fr: Integer;
  AlphaZero, FRA: Boolean;
  Greys: TColorValArray;
  Props: Properties;
  MinP: ColorVal;
  Row: Cardinal;
  Img: TImage;
  Plane, Alpha: TGeneralPlane;
  NullAlpha: TConstantPlane;
begin
  Nump := Imgs[0].NumPlanes;
  AlphaZero := Imgs[0].AlphaZeroSpecial;
  FRA := Nump = 5;
  Greys := ComputeGreys(R);
  // partial decoding: start from a neutral grey so that undecoded areas look sane
  if Options.quality < 100 then
    for P := 0 to Nump - 1 do
      if R.MinV(P) < R.MaxV(P) then
        for Fr := 0 to High(Imgs) do
          for Row := 0 to Imgs[Fr].Rows - 1 do
            for K := 0 to Integer(Imgs[Fr].Cols) - 1 do
              Imgs[Fr].SetVal(P, Row, K, (R.MinV(P) + R.MaxV(P)) div 2);
  NullAlpha := TConstantPlane.Create(1);
  try
    I := 0;
    for K := 0 to 4 do
    begin
      P := PLANE_ORDERING[K];
      if P >= Nump then Continue;
      Inc(I);
      if Nump > 3 then SetLength(Props, NB_PROPERTIES_scanlinesA[P])
      else SetLength(Props, NB_PROPERTIES_scanlines[P]);
      if 100 * Progress.pixels_done > Int64(Options.quality) * Progress.pixels_todo then
        Exit(False);
      if R.MinV(P) < R.MaxV(P) then
      begin
        MinP := R.MinV(P);
        Progress.pixels_done := Progress.pixels_done + Int64(Imgs[0].Cols) * Int64(Imgs[0].Rows);
        for Row := 0 to Imgs[0].Rows - 1 do
        begin
          if Imgs[0].Cols = 0 then Exit(False);
          for Fr := 0 to High(Imgs) do
          begin
            Img := Imgs[Fr];
            Plane := Img.GetPlane(P);
            if Nump > 3 then Alpha := Img.GetPlane(3) else Alpha := NullAlpha;
            FlifDecodeScanlinePlane(Plane, Coders[P], Imgs, R, Alpha, Props, P, Fr,
              Row, Greys[P], MinP, AlphaZero, FRA);
          end;
        end;
      end;
    end;
    Result := True;
  finally
    NullAlpha.Free;
  end;
end;

function FlifDecodeScanlinesPass(IO: TFlifIO; Rac: TRacIn; const Imgs: TImages;
  R: TColorRanges; const Forest: TTreeArray; var Options: TFlifOptions;
  var Progress: TProgress; Bits: Integer): Boolean;
var
  Coders: TPropCoderArray;
  PropRanges: Ranges;
  P: Integer;
begin
  SetLength(Coders, Imgs[0].NumPlanes);
  for P := 0 to Imgs[0].NumPlanes - 1 do
  begin
    InitPropRangesScanlines(PropRanges, R, P);
    Coders[P] := TFinalPropertySymbolCoder.Create(Rac, nil, PropRanges, Forest[P],
      0, Options.cutoff, Options.alpha, Bits);
  end;
  try
    Result := FlifDecodeScanlinesInner(IO, Coders, Imgs, R, Options, Progress);
  finally
    for P := 0 to High(Coders) do Coders[P].Free;
  end;
end;

// ------------------------------------------------------------------
// interlaced decoding
// ------------------------------------------------------------------

function UndoPalette(const Imgs: TImages; Scale: Integer; var Transforms: TTransformArray;
  var Zoomlevels: TIntegerArray; R: TColorRanges): TColorRanges;
begin
  Result := R;
  if Imgs[0].Palette and (Scale = 1) then
  begin
    while Imgs[0].Palette and (Length(Transforms) > 0) do
    begin
      Transforms[High(Transforms)].InvData(Imgs);
      SetLength(Transforms, Length(Transforms) - 1);
      Result := Result.Previous;
    end;
    Zoomlevels[0] := Zoomlevels[1];
    Zoomlevels[2] := Zoomlevels[1];
    if Length(Zoomlevels) > 3 then Zoomlevels[3] := Zoomlevels[1];
  end;
end;

procedure FlifDecodeFLIF2InnerInterpol(const Imgs: TImages; R: TColorRanges;
  PP, EndZL: Integer; RR: Int32; Scale: Integer; var Zoomlevels: TIntegerArray;
  var Transforms: TTransformArray);
var
  Z, P, I: Integer;
  Row, C, Rows_, Cols_: Cardinal;
  Img: TImage;
  Plane: TGeneralPlane;
begin
  // finish the zoomlevel we were working on
  if RR >= 0 then
  begin
    Z := Zoomlevels[PP];
    P := PP;
    if Z >= EndZL then Dec(Zoomlevels[PP]);
    if (Z and 1) = 0 then
    begin
      Row := Cardinal(RR);
      while Row < Imgs[0].RowsZ(Z) do
      begin
        for I := 0 to High(Imgs) do
        begin
          Img := Imgs[I];
          if not Img.Palette then
          begin
            for C := 0 to Img.ColsZ(Z) - 1 do
              Img.SetValZ(P, Z, Row, C, Predict(Img, Z, P, Row, C, 0));
          end
          else
            for C := 0 to Img.ColsZ(Z) - 1 do
              Img.SetValZ(P, Z, Row, C, Img.GetValZ(P, Z, Row - 1, C));
        end;
        Inc(Row, 2);
      end;
    end
    else
    begin
      Row := Cardinal(RR);
      while Row < Imgs[0].RowsZ(Z) do
      begin
        for I := 0 to High(Imgs) do
        begin
          Img := Imgs[I];
          C := 1;
          while C < Img.ColsZ(Z) do
          begin
            if not Img.Palette then
              Img.SetValZ(P, Z, Row, C, Predict(Img, Z, P, Row, C, 0))
            else
              Img.SetValZ(P, Z, Row, C, Img.GetValZ(P, Z, Row, C - 1));
            Inc(C, 2);
          end;
        end;
        Inc(Row);
      end;
    end;
  end;

  R := UndoPalette(Imgs, Scale, Transforms, Zoomlevels, R);

  // interpolate the next zoomlevels
  P := 0;
  while P < R.NumPlanes do
  begin
    Z := Zoomlevels[P];
    if Z < EndZL then
    begin
      Inc(P);
      Continue;
    end;
    Dec(Zoomlevels[P]);
    if P = 4 then Continue;
    if R.MinV(P) >= R.MaxV(P) then Continue;
    if (1 shl (Z div 2)) < Scale then Continue;

    if (Z and 1) = 0 then
    begin
      for I := 0 to High(Imgs) do
      begin
        Img := Imgs[I];
        Plane := Img.GetPlane(P);
        Rows_ := Img.RowsZ(Z);
        Cols_ := Img.ColsZ(Z);
        Row := 1;
        while Row < Rows_ do
        begin
          for C := 0 to Cols_ - 1 do
            Plane.SetPixZ(Z, Row, C, PredictPlaneHorizontal(Plane, Z, P, Row, C, Rows_, 0));
          Inc(Row, 2);
        end;
      end;
    end
    else
    begin
      for I := 0 to High(Imgs) do
      begin
        Img := Imgs[I];
        Plane := Img.GetPlane(P);
        Rows_ := Img.RowsZ(Z);
        Cols_ := Img.ColsZ(Z);
        for Row := 0 to Rows_ - 1 do
        begin
          C := 1;
          while C < Cols_ do
          begin
            Plane.SetPixZ(Z, Row, C, PredictPlaneVertical(Plane, Z, P, Row, C, Cols_, 0));
            Inc(C, 2);
          end;
        end;
      end;
    end;
  end;
end;

procedure FlifDecodePlaneZoomlevelHorizontal(Plane: TGeneralPlane; Coder: TPropCoderBase;
  const Imgs: TImages; R: TColorRanges; Alpha, PlaneY: TGeneralPlane;
  var Props: Properties; Z, P, Fr: Integer; Row: Cardinal;
  AlphaZero, FRA: Boolean; Predictor, InvisiblePredictor: Integer);
var
  MinV, MaxV, Guess, Curr: ColorVal;
  Img: TImage;
  RBegin, REnd, C, Cs, Rs: Cardinal;
begin
  Img := Imgs[Fr];
  RBegin := 0;
  REnd := Img.ColsZ(Z);

  if Img.SeenBefore >= 0 then
  begin
    Cs := ZoomColPixelSize(Z) shr Img.GetScale;
    Rs := ZoomRowPixelSize(Z) shr Img.GetScale;
    Plane.CopyRowRange(Imgs[Img.SeenBefore].GetPlane(P), Rs * Row, 0, Cs * Img.ColsZ(Z), Cs);
    Exit;
  end;
  if Fr > 0 then
  begin
    RBegin := Img.ColBegin[Row * ZoomRowPixelSize(Z)] div ZoomColPixelSize(Z);
    REnd := 1 + (Img.ColEnd[Row * ZoomRowPixelSize(Z)] - 1) div ZoomColPixelSize(Z);
    if AlphaZero and (P < 3) then
    begin
      for C := 0 to RBegin - 1 do
        if Alpha.GetPixZ(Z, Row, C) = 0 then
          Plane.SetPixZ(Z, Row, C, PredictPlaneHorizontal(Plane, Z, P, Row, C,
            Img.RowsZ(Z), InvisiblePredictor))
        else
          Img.SetValZ(P, Z, Row, C, Imgs[Fr - 1].GetValZ(P, Z, Row, C));
    end
    else if P <> 4 then
    begin
      Cs := ZoomColPixelSize(Z) shr Img.GetScale;
      Rs := ZoomRowPixelSize(Z) shr Img.GetScale;
      Plane.CopyRowRange(Imgs[Fr - 1].GetPlane(P), Rs * Row, 0, Cs * RBegin, Cs);
      Plane.CopyRowRange(Imgs[Fr - 1].GetPlane(P), Rs * Row, Cs * REnd, Cs * Img.ColsZ(Z), Cs);
    end;
  end;

  C := RBegin;
  while C < REnd do
  begin
    if AlphaZero and (P < 3) and (Alpha.GetFast(Row, C) = 0) then
    begin
      Plane.SetFast(Row, C, PredictPlaneHorizontal(Plane, Z, P, Row, C, Img.RowsZ(Z),
        InvisiblePredictor));
      Inc(C);
      Continue;
    end;
    if FRA and (P < 4) and (Img.GetFRAZ(Z, Row, C) > 0) then
    begin
      Plane.SetFast(Row, C, Imgs[Fr - Img.GetFRAZ(Z, Row, C)].GetValZ(P, Z, Row, C));
      Inc(C);
      Continue;
    end;
    Guess := PredictAndCalcPropsPlane(Props, R, Img, Plane, PlaneY, True, P, Z, Row, C,
      MinV, MaxV, Predictor);
    if FRA then
    begin
      if (P = 4) and (MaxV > Fr) then MaxV := Fr;
      if (Guess > MaxV) or (Guess < MinV) then Guess := MinV;
    end;
    Curr := Coder.ReadInt(Props, MinV - Guess, MaxV - Guess) + Guess;
    Plane.SetFast(Row, C, Curr);
    Inc(C);
  end;

  if (Fr > 0) and AlphaZero and (P < 3) then
    for C := REnd to Img.ColsZ(Z) - 1 do
      if Alpha.GetPixZ(Z, Row, C) = 0 then
        Plane.SetPixZ(Z, Row, C, PredictPlaneHorizontal(Plane, Z, P, Row, C,
          Img.RowsZ(Z), InvisiblePredictor))
      else
        Img.SetValZ(P, Z, Row, C, Imgs[Fr - 1].GetValZ(P, Z, Row, C));
end;

procedure FlifDecodePlaneZoomlevelVertical(Plane: TGeneralPlane; Coder: TPropCoderBase;
  const Imgs: TImages; R: TColorRanges; Alpha, PlaneY: TGeneralPlane;
  var Props: Properties; Z, P, Fr: Integer; Row: Cardinal;
  AlphaZero, FRA: Boolean; Predictor, InvisiblePredictor: Integer);
var
  MinV, MaxV, Guess, Curr: ColorVal;
  Img: TImage;
  RBegin, REnd, C, Cs, Rs: Cardinal;
begin
  Img := Imgs[Fr];
  RBegin := 1;
  REnd := Img.ColsZ(Z);

  if Img.SeenBefore >= 0 then
  begin
    Cs := ZoomColPixelSize(Z) shr Img.GetScale;
    Rs := ZoomRowPixelSize(Z) shr Img.GetScale;
    Plane.CopyRowRange(Imgs[Img.SeenBefore].GetPlane(P), Rs * Row, Cs * 1,
      Cs * Img.ColsZ(Z), Cs * 2);
    Exit;
  end;
  if Fr > 0 then
  begin
    RBegin := Img.ColBegin[Row * ZoomRowPixelSize(Z)] div ZoomColPixelSize(Z);
    REnd := (1 + (Img.ColEnd[Row * ZoomRowPixelSize(Z)] - 1) div ZoomColPixelSize(Z)) or 1;
    if (RBegin > 1) and ((RBegin and 1) = 0) then Dec(RBegin);
    if RBegin = 0 then RBegin := 1;
    if AlphaZero and (P < 3) then
    begin
      C := 1;
      while C < RBegin do
      begin
        if Alpha.GetPixZ(Z, Row, C) = 0 then
          Plane.SetPixZ(Z, Row, C, PredictPlaneVertical(Plane, Z, P, Row, C,
            Img.ColsZ(Z), InvisiblePredictor))
        else
          Img.SetValZ(P, Z, Row, C, Imgs[Fr - 1].GetValZ(P, Z, Row, C));
        Inc(C, 2);
      end;
    end
    else if P <> 4 then
    begin
      Cs := ZoomColPixelSize(Z) shr Img.GetScale;
      Rs := ZoomRowPixelSize(Z) shr Img.GetScale;
      Plane.CopyRowRange(Imgs[Fr - 1].GetPlane(P), Rs * Row, Cs * 1, Cs * RBegin, Cs * 2);
      Plane.CopyRowRange(Imgs[Fr - 1].GetPlane(P), Rs * Row, Cs * REnd,
        Cs * Img.ColsZ(Z), Cs * 2);
    end;
  end;

  C := RBegin;
  while C < REnd do
  begin
    if AlphaZero and (P < 3) and (Alpha.GetFast(Row, C) = 0) then
    begin
      Plane.SetFast(Row, C, PredictPlaneVertical(Plane, Z, P, Row, C, Img.ColsZ(Z),
        InvisiblePredictor));
      Inc(C, 2);
      Continue;
    end;
    if FRA and (P < 4) and (Img.GetFRAZ(Z, Row, C) > 0) then
    begin
      Plane.SetFast(Row, C, Imgs[Fr - Img.GetFRAZ(Z, Row, C)].GetValZ(P, Z, Row, C));
      Inc(C, 2);
      Continue;
    end;
    Guess := PredictAndCalcPropsPlane(Props, R, Img, Plane, PlaneY, False, P, Z, Row, C,
      MinV, MaxV, Predictor);
    if FRA then
    begin
      if (P = 4) and (MaxV > Fr) then MaxV := Fr;
      if (Guess > MaxV) or (Guess < MinV) then Guess := MinV;
    end;
    Curr := Coder.ReadInt(Props, MinV - Guess, MaxV - Guess) + Guess;
    Plane.SetFast(Row, C, Curr);
    Inc(C, 2);
  end;

  if (Fr > 0) and AlphaZero and (P < 3) then
  begin
    C := REnd;
    while C < Img.ColsZ(Z) do
    begin
      if Alpha.GetPixZ(Z, Row, C) = 0 then
        Plane.SetPixZ(Z, Row, C, PredictPlaneVertical(Plane, Z, P, Row, C,
          Img.ColsZ(Z), InvisiblePredictor))
      else
        Img.SetValZ(P, Z, Row, C, Imgs[Fr - 1].GetValZ(P, Z, Row, C));
      Inc(C, 2);
    end;
  end;
end;

function FlifDecodeFLIF2Inner(IO: TFlifIO; Rac: TRacIn; const Coders: TPropCoderArray;
  const Imgs: TImages; R: TColorRanges; BeginZL, EndZL: Integer;
  var Options: TFlifOptions; var Transforms: TTransformArray;
  var Progress: TProgress): Boolean;
var
  Nump, Quality, Scale, I, P, Z, Fr, Predictor, Breakpoints: Integer;
  AlphaZero, FRA, DefaultOrder: Boolean;
  MetaCoder: TUniformSymbolCoder;
  Zoomlevels: TIntegerArray;
  ThePredictor: array[0..4] of Integer;
  Props: Properties;
  Row: Cardinal;
  Img: TImage;
  Plane, Alpha, PlaneY: TGeneralPlane;
  Pz, Pzl: Integer;
begin
  Nump := Imgs[0].NumPlanes;
  Quality := Options.quality;
  Scale := Options.scale;
  AlphaZero := Imgs[0].AlphaZeroSpecial;
  FRA := Nump = 5;
  MetaCoder := TUniformSymbolCoder.Create(Rac, nil);
  try
    SetLength(Zoomlevels, Nump);
    for I := 0 to Nump - 1 do Zoomlevels[I] := BeginZL;
    DefaultOrder := MetaCoder.ReadInt(0, 1) <> 0;
    for I := 0 to 4 do ThePredictor[I] := 0;
    Breakpoints := Options.show_breakpoints;
    for P := 0 to Nump - 1 do
      ThePredictor[P] := MetaCoder.ReadInt(-1, MAX_PREDICTOR + 1);

    for I := 0 to PlaneZoomlevels(Imgs[0], BeginZL, EndZL) - 1 do
    begin
      if DefaultOrder then
      begin
        PlaneZoomlevel(Imgs[0], BeginZL, EndZL, I, R, Pz, Pzl);
        P := Pz;
      end
      else
      begin
        P := MetaCoder.ReadInt(0, Nump - 1);
        if (Nump > 3) and Imgs[0].AlphaZeroSpecial and (P < 3) and
           (Zoomlevels[P] <= Zoomlevels[3]) then
        begin
          e_printf('Corrupt file: non-alpha encoded before alpha.'#10);
          Exit(False);
        end;
        if (Nump > 4) and (P < 4) and (Zoomlevels[P] <= Zoomlevels[4]) then
        begin
          e_printf('Corrupt file: pixels encoded before frame lookback.'#10);
          Exit(False);
        end;
      end;
      Z := Zoomlevels[P];
      if Z < 0 then
      begin
        e_printf('Corrupt file: invalid plane/zoomlevel'#10);
        Exit(False);
      end;
      if (100 * Progress.pixels_done > Int64(Quality) * Progress.pixels_todo) and (EndZL = 0) then
      begin
        FlifDecodeFLIF2InnerInterpol(Imgs, R, P, EndZL, -1, Scale, Zoomlevels, Transforms);
        Exit(False);
      end;
      if R.MinV(P) < R.MaxV(P) then
      begin
        if ThePredictor[P] < 0 then Predictor := MetaCoder.ReadInt(0, MAX_PREDICTOR)
        else Predictor := ThePredictor[P];
        if (1 shl (Z div 2)) < Breakpoints then
        begin
          v_printf(1, Format('1:%d scale: %d bytes'#10, [Breakpoints, IO.FTell]));
          Breakpoints := Breakpoints div 2;
          Options.show_breakpoints := Breakpoints;
          if (Options.no_full_decode <> 0) and (Breakpoints < 2) then Exit(False);
        end;
        if (1 shl (Z div 2)) < Scale then
        begin
          FlifDecodeFLIF2InnerInterpol(Imgs, R, P, EndZL, -1, Scale, Zoomlevels, Transforms);
          Exit(False);
        end;
        for Fr := 0 to High(Imgs) do
        begin
          Imgs[Fr].GetPlane(P).PrepareZoomlevel(Z);
          if P > 0 then Imgs[Fr].GetPlane(0).PrepareZoomlevel(Z);
          if (P < 3) and (Nump > 3) then Imgs[Fr].GetPlane(3).PrepareZoomlevel(Z);
        end;

        if Nump > 3 then SetLength(Props, NB_PROPERTIESA[P])
        else SetLength(Props, NB_PROPERTIES[P]);

        if (Z and 1) = 0 then
        begin
          Row := 1;
          while Row < Imgs[0].RowsZ(Z) do
          begin
            if Imgs[0].Cols = 0 then Exit(False);
            Progress.pixels_done := Progress.pixels_done + Int64(Imgs[0].ColsZ(Z));
            if IO.IsEOF then
            begin
              v_printf(1, Format('Row %d: Unexpected file end. Interpolation from now on.'#10, [Row]));
              if Row > 1 then
                FlifDecodeFLIF2InnerInterpol(Imgs, R, P, EndZL, Int32(Row) - 2, Scale, Zoomlevels, Transforms)
              else
                FlifDecodeFLIF2InnerInterpol(Imgs, R, P, EndZL, Int32(Row), Scale, Zoomlevels, Transforms);
              Exit(False);
            end;
            for Fr := 0 to High(Imgs) do
            begin
              Img := Imgs[Fr];
              Plane := Img.GetPlane(P);
              PlaneY := Img.GetPlane(0);
              if (Nump > 3) and (not Img.GetPlane(3).IsConstant) then Alpha := Img.GetPlane(3)
              else Alpha := PlaneY;
              FlifDecodePlaneZoomlevelHorizontal(Plane, Coders[P], Imgs, R, Alpha, PlaneY,
                Props, Z, P, Fr, Row, AlphaZero, FRA, Predictor, Options.invisible_predictor);
            end;
            Inc(Row, 2);
          end;
        end
        else
        begin
          for Row := 0 to Imgs[0].RowsZ(Z) - 1 do
          begin
            if Imgs[0].Cols = 0 then Exit(False);
            Progress.pixels_done := Progress.pixels_done + Int64(Imgs[0].ColsZ(Z)) div 2;
            if IO.IsEOF then
            begin
              v_printf(1, Format('Row %d: Unexpected file end. Interpolation from now on.'#10, [Row]));
              if Row > 0 then
                FlifDecodeFLIF2InnerInterpol(Imgs, R, P, EndZL, Int32(Row) - 1, Scale, Zoomlevels, Transforms)
              else
                FlifDecodeFLIF2InnerInterpol(Imgs, R, P, EndZL, Int32(Row), Scale, Zoomlevels, Transforms);
              Exit(False);
            end;
            for Fr := 0 to High(Imgs) do
            begin
              Img := Imgs[Fr];
              Plane := Img.GetPlane(P);
              PlaneY := Img.GetPlane(0);
              if (Nump > 3) and (not Img.GetPlane(3).IsConstant) then Alpha := Img.GetPlane(3)
              else Alpha := PlaneY;
              FlifDecodePlaneZoomlevelVertical(Plane, Coders[P], Imgs, R, Alpha, PlaneY,
                Props, Z, P, Fr, Row, AlphaZero, FRA, Predictor, Options.invisible_predictor);
            end;
          end;
        end;
        Dec(Zoomlevels[P]);
      end
      else
        Dec(Zoomlevels[P]);
    end;
    Result := True;
  finally
    MetaCoder.Free;
  end;
end;

function FlifDecodeFLIF2Pass(IO: TFlifIO; Rac: TRacIn; const Imgs: TImages;
  R: TColorRanges; const Forest: TTreeArray; BeginZL, EndZL: Integer;
  var Options: TFlifOptions; var Transforms: TTransformArray;
  var Progress: TProgress; Bits: Integer): Boolean;
var
  Coders: TPropCoderArray;
  PropRanges: Ranges;
  P, Fr, MinR: Integer;
  MetaCoder: TUniformSymbolCoder;
begin
  SetLength(Coders, Imgs[0].NumPlanes);
  for P := 0 to Imgs[0].NumPlanes - 1 do
  begin
    InitPropRanges(PropRanges, R, P);
    Coders[P] := TFinalPropertySymbolCoder.Create(Rac, nil, PropRanges, Forest[P],
      0, Options.cutoff, Options.alpha, Bits);
  end;
  try
    if (BeginZL = Imgs[0].Zooms) and (EndZL > 0) then
    begin
      MetaCoder := TUniformSymbolCoder.Create(Rac, nil);
      try
        for P := 0 to Imgs[0].NumPlanes - 1 do
          if R.MinV(P) < R.MaxV(P) then
          begin
            MinR := R.MinV(P);
            for Fr := 0 to High(Imgs) do
              Imgs[Fr].SetValZ(P, 0, 0, 0, MetaCoder.ReadInt(MinR, R.MaxV(P) - MinR));
            Inc(Progress.pixels_done);
          end;
      finally
        MetaCoder.Free;
      end;
    end;
    Result := FlifDecodeFLIF2Inner(IO, Rac, Coders, Imgs, R, BeginZL, EndZL, Options,
      Transforms, Progress);
  finally
    for P := 0 to High(Coders) do Coders[P].Free;
  end;
end;

function FlifDecodeTree(Rac: TRacIn; R: TColorRanges; const Forest: TTreeArray;
  Encoding: TFlifEncoding): Boolean;
var
  P: Integer;
  PropRanges: Ranges;
  MetaCoder: TMetaPropertySymbolCoder;
begin
  for P := 0 to R.NumPlanes - 1 do
  begin
    if Encoding = feNonInterlaced then InitPropRangesScanlines(PropRanges, R, P)
    else InitPropRanges(PropRanges, R, P);
    MetaCoder := TMetaPropertySymbolCoder.Create(Rac, nil, PropRanges);
    try
      if R.MinV(P) < R.MaxV(P) then
        if not MetaCoder.ReadTree(Forest[P]) then Exit(False);
    finally
      MetaCoder.Free;
    end;
  end;
  Result := True;
end;

function FlifDecodeMain(Rac: TRacIn; IO: TFlifIO; const Imgs: TImages; R: TColorRanges;
  var Transforms: TTransformArray; var Options: TFlifOptions;
  var Progress: TProgress; Bits: Integer): Boolean;
var
  Scale, RoughZL, I: Integer;
  Forest: TTreeArray;
  MetaCoder: TUniformSymbolCoder;
  Zoomlevels: TIntegerArray;
begin
  Scale := Options.scale;
  SetLength(Forest, R.NumPlanes);
  for I := 0 to R.NumPlanes - 1 do Forest[I] := TTree.Create;
  try
    RoughZL := 0;
    if Options.method = feInterlaced then
    begin
      MetaCoder := TUniformSymbolCoder.Create(Rac, nil);
      try
        RoughZL := MetaCoder.ReadInt(0, Imgs[0].Zooms);
      finally
        MetaCoder.Free;
      end;
      if not FlifDecodeFLIF2Pass(IO, Rac, Imgs, R, Forest, Imgs[0].Zooms, RoughZL + 1,
        Options, Transforms, Progress, Bits) then
      begin
        SetLength(Zoomlevels, R.NumPlanes);
        for I := 0 to R.NumPlanes - 1 do Zoomlevels[I] := RoughZL;
        FlifDecodeFLIF2InnerInterpol(Imgs, R, 0, 0, -1, Scale, Zoomlevels, Transforms);
        Exit(False);
      end;
    end;
    if (Options.method = feInterlaced) and
       ((Options.quality <= 0) or (Progress.pixels_done >= Progress.pixels_todo)) and
       (Progress.pixels_todo > 1) then
    begin
      SetLength(Zoomlevels, R.NumPlanes);
      for I := 0 to R.NumPlanes - 1 do Zoomlevels[I] := RoughZL;
      FlifDecodeFLIF2InnerInterpol(Imgs, R, 0, 0, -1, Scale, Zoomlevels, Transforms);
      Exit(Progress.pixels_done >= Progress.pixels_todo);
    end
    else
    begin
      v_printf(3, 'Decoded header + rough data. Decoding MANIAC tree.'#10);
      if not FlifDecodeTree(Rac, R, Forest, Options.method) then
      begin
        if Options.method = feInterlaced then
        begin
          v_printf(1, 'File probably truncated in the middle of the MANIAC tree. Interpolating.'#10);
          SetLength(Zoomlevels, R.NumPlanes);
          for I := 0 to R.NumPlanes - 1 do Zoomlevels[I] := RoughZL;
          FlifDecodeFLIF2InnerInterpol(Imgs, R, 0, 0, -1, Scale, Zoomlevels, Transforms);
        end;
        Exit(False);
      end;
    end;

    case Options.method of
      feNonInterlaced:
        Result := FlifDecodeScanlinesPass(IO, Rac, Imgs, R, Forest, Options, Progress, Bits);
      feInterlaced:
        Result := FlifDecodeFLIF2Pass(IO, Rac, Imgs, R, Forest, RoughZL, 0, Options,
          Transforms, Progress, Bits);
    else
      Result := False;
    end;
  finally
    for I := 0 to High(Forest) do Forest[I].Free;
  end;
end;

// ------------------------------------------------------------------

procedure Downsample(Width, Height, TargetW, TargetH: Integer; var Imgs: TImages);
var
  N: Integer;
  Tmp: TImage;
begin
  if TargetW > Width then TargetW := Width;
  if TargetH > Height then TargetH := Height;
  if TargetW <= 0 then TargetW := TargetH * Width div Height;
  if TargetH <= 0 then TargetH := TargetW * Height div Width;
  if (TargetW <> Integer(Imgs[0].Cols)) or (TargetH <> Integer(Imgs[0].Rows)) then
  begin
    v_printf(3, Format('Downscaling to %dx%d'#10, [TargetW, TargetH]));
    for N := 0 to High(Imgs) do
    begin
      Tmp := Imgs[N].CloneDownsampled(TargetW, TargetH);
      Imgs[N].Free;
      Imgs[N] := Tmp;
    end;
  end;
end;

function FlifDecodeEx(IO: TFlifIO; var Imgs: TImages; var Options: TFlifOptions;
  const MD: TMetadataOptions; WantInfo: Boolean; out Info: TFlifInfo): Boolean;
var
  Quality, Scale, RW, RH, TargetW, TargetH: Integer;
  Fit, JustIdentify, JustMetadata: Boolean;
  Buff: array[0..5] of AnsiChar;
  Magic: string;
  C, NumFrames, NumPlanes, Width, Height, MaxMax, MaxV: Integer;
  Encoding: TFlifEncoding;
  Metadata: TMetaDataArray;
  Chunk: TMetaData;
  ResultCode, P, Fr, I, MBits, NBits, Bits, ScaleShift: Integer;
  Rac: TRacIn;
  MetaCoder: TUniformSymbolCoder;
  AlphaZero: Boolean;
  RangesList: array of TColorRanges;
  AllTransforms: TTransformArray;
  ActiveTransforms: TTransformArray;
  Trans: TTransform;
  PreviousRange, R, NewRanges: TColorRanges;
  Desc: string;
  Tnb, Tpnb, TCount: Integer;
  RealNumPlanes: Integer;
  Progress: TProgress;
  FullyDecoded, SmallerBuffer, ContainsChecksum: Boolean;
  Checksum, Checksum2: Cardinal;
  BytesPerPixel, EstimatedBufferSize: QWord;
  PaletteImgs: TImages;
  RP: TColorRanges;
  PalImage: TImage;
begin
  Info.Valid := False;
  Result := False;
  Quality := Options.quality;
  Scale := Options.scale;
  RW := Options.resize_width;
  RH := Options.resize_height;
  Fit := Options.fit <> 0;
  JustIdentify := False;
  JustMetadata := False;
  if Scale = -1 then JustIdentify := True
  else if Scale = -2 then JustMetadata := True
  else if not ((Scale = 1) or (Scale = 2) or (Scale = 4) or (Scale = 8) or
               (Scale = 16) or (Scale = 32) or (Scale = 64) or (Scale = 128)) then
  begin
    e_printf(Format('Invalid scale down factor: %d'#10, [Scale]));
    Exit(False);
  end;

  if not IO.Gets(@Buff[0], 5) then
  begin
    e_printf(Format('Could not read header from file: %s'#10, [IO.GetName]));
    Exit(False);
  end;
  Magic := string(AnsiString(PAnsiChar(@Buff[0])));
  if Magic <> 'FLIF' then
  begin
    e_printf(Format('%s is not a FLIF file'#10, [IO.GetName]));
    Exit(False);
  end;

  C := IO.GetC;
  if C < 0 then Exit(False);
  if (C < 32) or (C > 32 + 32 + 15 + 32) then
  begin
    e_printf('Invalid or unknown FLIF format byte'#10);
    Exit(False);
  end;
  C := C - 32;
  NumFrames := 1;
  if C > 47 then
  begin
    C := C - 32;
    NumFrames := 2;
  end;
  if C div 16 = 1 then Encoding := feNonInterlaced
  else if C div 16 = 2 then Encoding := feInterlaced
  else
  begin
    e_printf('Invalid or unknown FLIF encoding method'#10);
    Exit(False);
  end;
  Options.method := Encoding;
  if (Encoding = feNonInterlaced) and (Options.show_breakpoints <> 0) then
  begin
    e_printf('Non-interlaced FLIF file, no breakpoints to report.'#10);
    Exit(False);
  end;
  if (Scale <> 1) and (Encoding = feNonInterlaced) and (not JustIdentify) then
  begin
    e_printf('Cannot decode non-interlaced FLIF file at lower scale!'#10);
    Exit(False);
  end;
  NumPlanes := C mod 16;
  if (NumPlanes < 1) or (NumPlanes > 4) or (NumPlanes = 2) then
  begin
    e_printf('Invalid FLIF header (unsupported colour channels)'#10);
    Exit(False);
  end;
  C := IO.GetC;
  if C < 0 then Exit(False);
  if (C < Ord('0')) or (C > Ord('2')) then
  begin
    e_printf('Invalid FLIF header (unsupported colour depth)'#10);
    Exit(False);
  end;

  Width := Integer(ReadBigEndianVarint(IO)) + 1;
  Height := Integer(ReadBigEndianVarint(IO)) + 1;
  if (Width < 1) or (Height < 1) then
  begin
    e_printf('Invalid FLIF header'#10);
    Exit(False);
  end;
  if NumFrames > 1 then NumFrames := Integer(ReadBigEndianVarint(IO)) + 2;
  if NumFrames < 0 then Exit(False);

  SetLength(Metadata, 0);
  repeat
    ResultCode := ReadChunk(IO, Chunk);
    if ResultCode <> 0 then Break;
    if (not MD.icc) and (Chunk.Name = 'iCCP') then Continue;
    if (not MD.exif) and (Chunk.Name = 'eXif') then Continue;
    if (not MD.xmp) and (Chunk.Name = 'eXmp') then Continue;
    v_printf(3, Format('Read metadata chunk: %s'#10, [Chunk.Name]));
    SetLength(Metadata, Length(Metadata) + 1);
    Metadata[High(Metadata)] := Chunk;
  until False;
  if ResultCode <> 1 then
  begin
    e_printf('Invalid FLIF file.'#10);
    Exit(False);
  end;

  if JustMetadata then
  begin
    SetLength(Imgs, 1);
    Imgs[0] := TImage.Create(0);
    Imgs[0].Metadata := Metadata;
    Exit(True);
  end;

  Rac := TRacIn.Create(IO);
  MetaCoder := TUniformSymbolCoder.Create(Rac, nil);
  RangesList := nil;
  AllTransforms := nil;
  ActiveTransforms := nil;
  try
    v_printf(3, Format('Decoding %dx%d image, channels:', [Width, Height]));
    MaxMax := 0;
    for P := 0 to NumPlanes - 1 do
    begin
      MaxV := 255;
      if C = Ord('2') then MaxV := 65535
      else if C = Ord('0') then MaxV := (1 shl MetaCoder.ReadInt(1, 15)) - 1;
      if MaxV > MaxMax then MaxMax := MaxV;
    end;
    if C = Ord('1') then v_printf(3, Format(' %d, depth: 8 bit', [NumPlanes]))
    else if C = Ord('2') then v_printf(3, Format(' %d, depth: 16 bit', [NumPlanes]));
    if NumFrames > 1 then v_printf(3, Format(', frames: %d', [NumFrames]));
    AlphaZero := False;
    if NumPlanes > 3 then
    begin
      AlphaZero := MetaCoder.ReadInt(0, 1) <> 0;
      if not AlphaZero then v_printf(3, ', store RGB at A=0');
    end;
    v_printf(3, #10);

    if JustIdentify or WantInfo then
    begin
      Info.Width := Width;
      Info.Height := Height;
      Info.Channels := NumPlanes;
      if C = Ord('1') then Info.BitDepth := 8
      else if C = Ord('2') then Info.BitDepth := 16
      else Info.BitDepth := ilog2(Cardinal(MaxMax + 1));
      Info.NumImages := NumFrames;
      Info.Valid := True;
      if JustIdentify then
      begin
        v_printf(1, Format('%s: ', [IO.GetName]));
        if NumFrames = 1 then v_printf(1, 'FLIF image')
        else v_printf(1, Format('FLIF animation, %d frames', [NumFrames]));
        v_printf(1, Format(', %ux%u, %d-bit ', [Width, Height, Info.BitDepth]));
        if NumPlanes = 1 then v_printf(1, 'grayscale')
        else if NumPlanes = 3 then v_printf(1, 'RGB')
        else if NumPlanes = 4 then v_printf(1, 'RGBA');
        if Encoding = feNonInterlaced then v_printf(1, ', non-interlaced'#10)
        else v_printf(1, ', interlaced'#10);
      end;
      Exit(True);
    end;

    if NumFrames > 1 then
      MetaCoder.ReadInt(0, 100);   // repeats, ignored

    if (RW < 0) or (RH < 0) then Exit(False);
    TargetW := RW;
    TargetH := RH;
    if Fit then
    begin
      if (RW <= 0) and (RH <= 0) then Exit(False);
      RW := RW * 2 - 1;
      RH := RH * 2 - 1;
    end;
    if (RW <> 0) or (RH <> 0) then
    begin
      Scale := 1;
      while ((RW > 0) and (((Width - 1) div Scale) + 1 > RW)) or
            ((RH > 0) and (((Height - 1) div Scale) + 1 > RH)) do
        Scale := Scale * 2;
      Options.scale := Scale;
    end;
    if (Scale <> 1) and (Encoding = feNonInterlaced) then Scale := 1;

    ScaleShift := ilog2(Cardinal(Scale));
    if ScaleShift > 0 then
      v_printf(3, Format('Decoding downscaled image at scale 1:%d'#10, [Scale]));
    if MaxMax > 255 then BytesPerPixel := 2 else BytesPerPixel := 1;
    if NumPlanes > 1 then BytesPerPixel := BytesPerPixel * QWord(NumPlanes + 2)
    else BytesPerPixel := BytesPerPixel * QWord(NumPlanes);
    EstimatedBufferSize := QWord(((Width - 1) div Scale) + 1) * QWord(((Height - 1) div Scale) + 1) *
      QWord(NumFrames) * QWord(NumPlanes) * BytesPerPixel;
    if EstimatedBufferSize > QWord(MAX_IMAGE_BUFFER_SIZE) then
    begin
      e_printf('This is going to take too much memory. Aborting.'#10);
      Exit(False);
    end;
    if NumFrames > MAX_FRAMES then
    begin
      e_printf('Too many frames. Aborting.'#10);
      Exit(False);
    end;

    SetLength(Imgs, NumFrames);
    for I := 0 to NumFrames - 1 do
    begin
      Imgs[I] := TImage.Create(ScaleShift);
      if not Imgs[I].SemiInit(Width, Height, 0, MaxMax, NumPlanes) then Exit(False);
      Imgs[I].AlphaZeroSpecial := AlphaZero;
      Imgs[I].Metadata := Metadata;
      if NumFrames > 1 then Imgs[I].FrameDelay := MetaCoder.ReadInt(0, 60000);
    end;

    Options.cutoff := 2;
    Options.alpha := Cardinal($FFFFFFFF) div 19;
    if MetaCoder.ReadInt(0, 1) <> 0 then
    begin
      Options.cutoff := MetaCoder.ReadInt(1, 127);
      Options.alpha := Cardinal($FFFFFFFF) div Cardinal(MetaCoder.ReadInt(2, 126));
      if MetaCoder.ReadInt(0, 1) <> 0 then
      begin
        e_printf('Not yet implemented: non-default bitchance initialization'#10);
        Exit(False);
      end;
    end;

    SetLength(RangesList, 1);
    RangesList[0] := GetRanges(Imgs[0]);
    v_printf(4, 'Transforms: ');
    TCount := 0;
    Tnb := 0;
    Tpnb := -1;
    while Rac.ReadBit do
    begin
      if IO.IsEOF then
      begin
        e_printf('Unexpected file end while reading header. Aborting.'#10);
        Exit(False);
      end;
      Desc := ReadName(Rac, Tnb);
      if Tnb <= Tpnb then
      begin
        e_printf(Format(#10'Transformation ''%s'' is invalid given the previous transformations.'#10, [Desc]));
        Exit(False);
      end;
      Tpnb := Tnb;
      Trans := CreateTransform(Desc);
      PreviousRange := RangesList[High(RangesList)];
      if Trans = nil then
      begin
        e_printf(Format(#10'Unknown transformation ''%s'''#10, [Desc]));
        Exit(False);
      end;
      SetLength(AllTransforms, Length(AllTransforms) + 1);
      AllTransforms[High(AllTransforms)] := Trans;
      if not Trans.Init(PreviousRange) then
      begin
        e_printf(Format('Transformation ''%s'' failed'#10, [Desc]));
        Exit(False);
      end;
      if TCount > 0 then v_printf(4, ', ');
      Inc(TCount);
      v_printf(4, Desc);
      if Desc = 'Frame_Lookback' then
      begin
        if Length(Imgs) < 2 then Exit(False);
        Trans.Configure(Length(Imgs));
      end;
      if Desc = 'Frame_Shape' then
      begin
        if Length(Imgs) < 2 then Exit(False);
        I := Length(Imgs) - 1;
        for Fr := 0 to High(Imgs) do
          if Imgs[Fr].SeenBefore >= 0 then Dec(I);
        if I < 1 then Exit(False);
        Trans.Configure(I * Integer(Imgs[0].Rows));
        Trans.Configure(Integer(Imgs[0].Cols));
      end;
      if Desc = 'Duplicate_Frame' then
      begin
        if Length(Imgs) < 2 then Exit(False);
        Trans.Configure(Length(Imgs));
      end;
      if Desc = 'Palette_Alpha' then Trans.Configure(Ord(Imgs[0].AlphaZeroSpecial));
      if not Trans.Load(PreviousRange, Rac) then Exit(False);
      NewRanges := Trans.Meta(Imgs, PreviousRange);
      if NewRanges = nil then Exit(False);
      SetLength(RangesList, Length(RangesList) + 1);
      RangesList[High(RangesList)] := NewRanges;
    end;
    ActiveTransforms := Copy(AllTransforms);
    if TCount = 0 then v_printf(4, 'none'#10) else v_printf(4, #10);
    R := RangesList[High(RangesList)];

    Options.invisible_predictor := 0;
    if AlphaZero and (R.NumPlanes > 3) and (R.MinV(3) <= 0) and (Encoding = feInterlaced) then
      Options.invisible_predictor := MetaCoder.ReadInt(0, MAX_PREDICTOR);

    RealNumPlanes := 0;
    for I := 0 to R.NumPlanes - 1 do
      if R.MinV(I) < R.MaxV(I) then Inc(RealNumPlanes);
    InitProgress(Progress);
    Progress.pixels_todo := Int64(Width) * Int64(Height) * RealNumPlanes div Scale div Scale;
    Progress.pixels_done := 0;
    if Progress.pixels_todo = 0 then
    begin
      Progress.pixels_todo := 1;
      Progress.pixels_done := 1;
    end;

    for P := 0 to R.NumPlanes - 1 do
      if R.MinV(P) >= R.MaxV(P) then
      begin
        v_printf(6, Format('Constant plane %d at colour value %d'#10, [P, R.MinV(P)]));
        for Fr := 0 to NumFrames - 1 do
          Imgs[Fr].MakeConstantPlane(P, R.MinV(P));
      end;

    SmallerBuffer := False;
    if Imgs[0].Palette and (R.MaxV(1) < 256) and (Options.keep_palette <> 0) and
       ((R.NumPlanes < 4) or (R.MinV(3) = R.MaxV(3))) then SmallerBuffer := True;
    if not SmallerBuffer then
      for Fr := 0 to NumFrames - 1 do Imgs[Fr].UndoMakeConstantPlane(0);
    for Fr := 0 to NumFrames - 1 do
      if not Imgs[Fr].RealInit(SmallerBuffer) then Exit(False);

    if (R.NumPlanes > 3) and (R.MinV(3) > 0) then
      for Fr := 0 to NumFrames - 1 do Imgs[Fr].AlphaZeroSpecial := False;
    if (R.NumPlanes > 3) and (R.MaxV(3) = 0) then
      for Fr := 0 to NumFrames - 1 do Imgs[Fr].AlphaZeroSpecial := False;

    MBits := 0;
    for P := 0 to R.NumPlanes - 1 do
      if R.MaxV(P) > R.MinV(P) then
      begin
        NBits := ilog2(Cardinal((R.MaxV(P) - R.MinV(P)) * 2 - 1)) + 1;
        if NBits > MBits then MBits := NBits;
      end;
    Bits := 10;
    if MBits > 10 then Bits := 18;
    if MBits > Bits then
    begin
      e_printf('FLIF cannot decode >16 bit per channel.'#10);
      Exit(False);
    end;

    FullyDecoded := FlifDecodeMain(Rac, IO, Imgs, R, ActiveTransforms, Options,
      Progress, Bits);

    ContainsChecksum := MetaCoder.ReadInt(0, 1) <> 0;

    for Fr := 0 to High(Imgs) do
    begin
      Imgs[Fr].NormalizeScale;
      if FullyDecoded and (Quality >= 100) and (Scale = 1) then
        Imgs[Fr].FullyDecoded := True;
    end;

    if (not SmallerBuffer) or (not Imgs[0].Palette) then
    begin
      while Length(ActiveTransforms) > 0 do
      begin
        ActiveTransforms[High(ActiveTransforms)].InvData(Imgs);
        SetLength(ActiveTransforms, Length(ActiveTransforms) - 1);
      end;
    end
    else
    begin
      while (Length(ActiveTransforms) > 0) and
            (not ActiveTransforms[High(ActiveTransforms)].IsPaletteTransform) do
      begin
        ActiveTransforms[High(ActiveTransforms)].InvData(Imgs);
        SetLength(ActiveTransforms, Length(ActiveTransforms) - 1);
        RangesList[High(RangesList)].Free;
        SetLength(RangesList, Length(RangesList) - 1);
      end;
      if Length(ActiveTransforms) > 0 then
      begin
        RP := RangesList[High(RangesList)];
        SetLength(PaletteImgs, 1);
        PaletteImgs[0] := TImage.Create(Cardinal(RP.MaxV(1) + 1), 1, 0, MaxMax, RP.NumPlanes);
        for I := 0 to RP.MaxV(1) do
          PaletteImgs[0].SetVal(1, 0, I, I);
        while Length(ActiveTransforms) > 0 do
        begin
          ActiveTransforms[High(ActiveTransforms)].InvData(PaletteImgs);
          SetLength(ActiveTransforms, Length(ActiveTransforms) - 1);
        end;
        PalImage := PaletteImgs[0];
        for Fr := 0 to High(Imgs) do
          Imgs[Fr].PaletteImage := PalImage.Clone;
        FreeImages(PaletteImgs);
      end;
    end;

    if Options.crc_check = 0 then
      v_printf(3, 'Not checking checksum, as requested.'#10)
    else if Imgs[0].PaletteImage <> nil then
      v_printf(2, 'Not checking checksum, palette image not decoded to full RGBA.'#10)
    else if (Quality >= 100) and (Scale = 1) and FullyDecoded then
    begin
      if ContainsChecksum then
      begin
        if AlphaZero then
          for Fr := 0 to High(Imgs) do Imgs[Fr].MakeInvisibleRgbBlack;
        Checksum := Imgs[0].Checksum;
        Checksum2 := Cardinal(MetaCoder.ReadIntBits(16));
        Checksum2 := Checksum2 * $10000;
        Checksum2 := Checksum2 + Cardinal(MetaCoder.ReadIntBits(16));
        if Checksum <> Checksum2 then
          v_printf(1, Format(#10'CORRUPTION DETECTED: checksums don''t match (computed: %x vs read: %x)!'#10#10,
            [Checksum, Checksum2]))
        else
          v_printf(3, 'Checksum verified.'#10);
      end
      else
        v_printf(3, 'Image does not contain a checksum.'#10);
    end
    else if (Quality < 100) or (Scale > 1) then
      v_printf(3, 'Not checking checksum, lossy partial decoding was chosen.'#10)
    else if Options.no_full_decode <> 0 then
      v_printf(4, 'Image not fully decoded.'#10)
    else
      v_printf(1, 'File ended prematurely or decoding was interrupted.'#10);

    if Fit then
      Downsample(Width, Height, TargetW, TargetH, Imgs);

    if Options.metadata <> 0 then
      Imgs[0].Metadata := Metadata;

    Result := True;
  finally
    MetaCoder.Free;
    Rac.Free;
    for I := 0 to High(AllTransforms) do AllTransforms[I].Free;
    for I := High(RangesList) downto 0 do RangesList[I].Free;
  end;
end;

function FlifDecode(IO: TFlifIO; var Imgs: TImages; var Options: TFlifOptions;
  const MD: TMetadataOptions; PInfo: PPointer): Boolean;
var
  Info: TFlifInfo;
begin
  Result := FlifDecodeEx(IO, Imgs, Options, MD, False, Info);
end;

end.
