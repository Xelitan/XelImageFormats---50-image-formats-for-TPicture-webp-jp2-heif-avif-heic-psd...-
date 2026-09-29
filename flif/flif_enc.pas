// FLIF - Free Lossless Image Format -- Free Pascal port
// Encoder.
// Corresponds to: src/flif-enc.cpp
//
// Not ported: lossy encoding (-Q), the adaptive/saliency map, chroma
// subsampling and the progressive-callback machinery of the C API.
unit flif_enc;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, flif_types, flif_io, flif_rac, flif_chance, flif_symbol, flif_image,
  flif_colorrange, flif_maniac, flif_common, flif_transform;

function FlifEncode(IO: TFlifIO; var Imgs: TImages; const TransDesc: array of string;
  var Options: TFlifOptions): Boolean;

procedure WriteBigEndianVarint(IO: TFlifIO; Number: QWord; Done: Boolean = True);

implementation

procedure WriteName(Rac: TRacOut; const Desc: string);
var
  Nb: Integer;
  Coder: TUniformSymbolCoder;
begin
  Nb := 0;
  while Nb <= MAX_TRANSFORM do
  begin
    if TransformNames[Nb] = Desc then Break;
    Inc(Nb);
  end;
  if (Nb > MAX_TRANSFORM) or (TransformNames[Nb] <> Desc) then
  begin
    e_printf(Format('ERROR: Invalid transform: ''%s'''#10, [Desc]));
    Exit;
  end;
  Coder := TUniformSymbolCoder.Create(nil, Rac);
  try
    Coder.WriteInt(0, MAX_TRANSFORM, Nb);
  finally
    Coder.Free;
  end;
end;

procedure WriteBigEndianVarint(IO: TFlifIO; Number: QWord; Done: Boolean);
var
  Lsb: QWord;
begin
  if Number < 128 then
  begin
    if Done then IO.FPutC(Integer(Number))
    else IO.FPutC(Integer(Number) + 128);
  end
  else
  begin
    Lsb := Number and 127;
    Number := Number shr 7;
    WriteBigEndianVarint(IO, Number, False);
    WriteBigEndianVarint(IO, Lsb, Done);
  end;
end;

procedure WriteChunk(IO: TFlifIO; const M: TMetaData);
var
  I: SizeInt;
begin
  IO.FPutS(M.Name);
  WriteBigEndianVarint(IO, M.Length);
  for I := 0 to M.Length - 1 do
    IO.FPutC(M.Contents[I]);
end;

// ------------------------------------------------------------------
// scanline (non-interlaced) encoding
// ------------------------------------------------------------------

procedure FlifEncodeScanlinesInner(IO: TFlifIO; const Coders: TPropCoderArray;
  const Imgs: TImages; R: TColorRanges; var Progress: TProgress);
var
  MinV, MaxV, MinP, Guess, Curr: ColorVal;
  Nump, K, P, I, Fr: Integer;
  AlphaZero, FRA: Boolean;
  Props: Properties;
  Row, C, RBegin, REnd: Cardinal;
  Img: TImage;
begin
  Nump := Imgs[0].NumPlanes;
  AlphaZero := (Nump > 3) and Imgs[0].AlphaZeroSpecial;
  FRA := Nump = 5;
  I := 0;
  for K := 0 to 4 do
  begin
    P := PLANE_ORDERING[K];
    if P >= Nump then Continue;
    Inc(I);
    if R.MinV(P) >= R.MaxV(P) then Continue;
    MinP := R.MinV(P);
    if Nump > 3 then SetLength(Props, NB_PROPERTIES_scanlinesA[P])
    else SetLength(Props, NB_PROPERTIES_scanlines[P]);
    Progress.pixels_done := Progress.pixels_done + Int64(Imgs[0].Cols) * Int64(Imgs[0].Rows);
    for Row := 0 to Imgs[0].Rows - 1 do
      for Fr := 0 to High(Imgs) do
      begin
        Img := Imgs[Fr];
        if Img.SeenBefore >= 0 then Continue;
        RBegin := Img.ColBegin[Row];
        REnd := Img.ColEnd[Row];
        for C := RBegin to REnd - 1 do
        begin
          if AlphaZero and (P < 3) and (Img.GetVal(3, Row, C) = 0) then Continue;
          if FRA and (P < 4) and (Img.GetVal(4, Row, C) > 0) then Continue;
          Guess := PredictAndCalcPropsScanlines(Props, R, Img, P, Row, C, MinV, MaxV, MinP);
          Curr := Img.GetVal(P, Row, C);
          if FRA and (P = 4) and (MaxV > Fr) then MaxV := Fr;
          Coders[P].WriteInt(Props, MinV - Guess, MaxV - Guess, Curr - Guess);
        end;
      end;
  end;
end;

procedure FlifEncodeScanlinesPass(IO: TFlifIO; RacIn: TRacIn; RacOut: TRacOut;
  const Imgs: TImages; R: TColorRanges; const Forest: TTreeArray; Repeats: Integer;
  var Options: TFlifOptions; var Progress: TProgress; Final: Boolean; Bits: Integer);
var
  Coders: TPropCoderArray;
  PropRanges: Ranges;
  P: Integer;
begin
  SetLength(Coders, R.NumPlanes);
  for P := 0 to R.NumPlanes - 1 do
  begin
    InitPropRangesScanlines(PropRanges, R, P);
    if Final then
      Coders[P] := TFinalPropertySymbolCoder.Create(RacIn, RacOut, PropRanges, Forest[P],
        Options.split_threshold, Options.cutoff, Options.alpha, Bits)
    else
      Coders[P] := TPropertySymbolCoder.Create(RacIn, RacOut, PropRanges, Forest[P],
        Options.split_threshold, Options.cutoff, Options.alpha, Bits);
  end;
  try
    while Repeats > 0 do
    begin
      Dec(Repeats);
      FlifEncodeScanlinesInner(IO, Coders, Imgs, R, Progress);
    end;
    for P := 0 to R.NumPlanes - 1 do
      Coders[P].Simplify(Options.divisor, Options.min_size, P);
  finally
    for P := 0 to R.NumPlanes - 1 do Coders[P].Free;
  end;
end;

// ------------------------------------------------------------------
// interlaced encoding
// ------------------------------------------------------------------

function FindBestPredictor(const Imgs: TImages; R: TColorRanges; P, Z: Integer): Integer;
const
  ZeroBonus = 1;
var
  MinV, MaxV, Guess, Curr: ColorVal;
  Nump, Predictor, Fr, Best: Integer;
  AlphaZero, FRA: Boolean;
  Props: Properties;
  TotalSize: array[0..MAX_PREDICTOR] of QWord;
  Row, C, RBegin, REnd: Cardinal;
  Img: TImage;
begin
  Nump := Imgs[0].NumPlanes;
  AlphaZero := (Nump > 3) and Imgs[0].AlphaZeroSpecial;
  FRA := Nump = 5;
  if Nump > 3 then SetLength(Props, NB_PROPERTIESA[P])
  else SetLength(Props, NB_PROPERTIES[P]);
  for Predictor := 0 to MAX_PREDICTOR do TotalSize[Predictor] := 0;

  for Predictor := 0 to MAX_PREDICTOR do
  begin
    if (Z and 1) = 0 then
    begin
      Row := 1;
      while Row < Imgs[0].RowsZ(Z) do
      begin
        for Fr := 0 to High(Imgs) do
        begin
          Img := Imgs[Fr];
          if Img.SeenBefore >= 0 then Continue;
          RBegin := Img.ColBegin[Row * ZoomRowPixelSize(Z)] div ZoomColPixelSize(Z);
          REnd := 1 + (Img.ColEnd[Row * ZoomRowPixelSize(Z)] - 1) div ZoomColPixelSize(Z);
          for C := RBegin to REnd - 1 do
          begin
            if AlphaZero and (P < 3) and (Img.GetValZ(3, Z, Row, C) = 0) then Continue;
            if FRA and (P < 4) and (Img.GetValZ(4, Z, Row, C) > 0) then Continue;
            Guess := PredictAndCalcProps(Props, R, Img, Z, P, Row, C, MinV, MaxV, Predictor);
            Curr := Img.GetValZ(P, Z, Row, C);
            TotalSize[Predictor] := TotalSize[Predictor] + QWord(ilog2(Cardinal(Abs(Curr - Guess))));
            if Curr - Guess <> 0 then TotalSize[Predictor] := TotalSize[Predictor] + ZeroBonus;
          end;
        end;
        Inc(Row, 2);
      end;
    end
    else
    begin
      for Row := 0 to Imgs[0].RowsZ(Z) - 1 do
      begin
        for Fr := 0 to High(Imgs) do
        begin
          Img := Imgs[Fr];
          if Img.SeenBefore >= 0 then Continue;
          RBegin := Img.ColBegin[Row * ZoomRowPixelSize(Z)] div ZoomColPixelSize(Z);
          REnd := (1 + (Img.ColEnd[Row * ZoomRowPixelSize(Z)] - 1) div ZoomColPixelSize(Z)) or 1;
          if (RBegin > 1) and ((RBegin and 1) = 0) then Dec(RBegin);
          if RBegin = 0 then RBegin := 1;
          C := RBegin;
          while C < REnd do
          begin
            if AlphaZero and (P < 3) and (Img.GetValZ(3, Z, Row, C) = 0) then
            begin
              Inc(C, 2);
              Continue;
            end;
            if FRA and (P < 4) and (Img.GetValZ(4, Z, Row, C) > 0) then
            begin
              Inc(C, 2);
              Continue;
            end;
            Guess := PredictAndCalcProps(Props, R, Img, Z, P, Row, C, MinV, MaxV, Predictor);
            Curr := Img.GetValZ(P, Z, Row, C);
            TotalSize[Predictor] := TotalSize[Predictor] + QWord(ilog2(Cardinal(Abs(Curr - Guess))));
            if Curr - Guess <> 0 then TotalSize[Predictor] := TotalSize[Predictor] + ZeroBonus;
            Inc(C, 2);
          end;
        end;
      end;
    end;
  end;
  Best := 0;
  for Predictor := 0 to MAX_PREDICTOR do
    if TotalSize[Predictor] < TotalSize[Best] then Best := Predictor;
  Result := Best;
end;

procedure FlifEncodeFLIF2Inner(IO: TFlifIO; Rac: TRacOut; const Coders: TPropCoderArray;
  const Imgs: TImages; R: TColorRanges; BeginZL, EndZL: Integer;
  var Options: TFlifOptions; var Progress: TProgress);
var
  MinV, MaxV, Guess, Curr: ColorVal;
  Nump, I, P, Z, Fr, Predictor: Integer;
  AlphaZero, FRA, DefaultOrder: Boolean;
  Props: Properties;
  MetaCoder: TUniformSymbolCoder;
  Row, C, RBegin, REnd: Cardinal;
  Img: TImage;
begin
  Nump := Imgs[0].NumPlanes;
  AlphaZero := (Nump > 3) and Imgs[0].AlphaZeroSpecial;
  FRA := Nump = 5;
  MetaCoder := TUniformSymbolCoder.Create(nil, Rac);
  try
    DefaultOrder := Options.chroma_subsampling = 0;
    if DefaultOrder then MetaCoder.WriteInt(0, 1, 1) else MetaCoder.WriteInt(0, 1, 0);
    for P := 0 to Nump - 1 do
      MetaCoder.WriteInt(-1, MAX_PREDICTOR, Options.predictor[P]);

    for I := 0 to PlaneZoomlevels(Imgs[0], BeginZL, EndZL) - 1 do
    begin
      PlaneZoomlevel(Imgs[0], BeginZL, EndZL, I, R, P, Z);
      if (Options.chroma_subsampling <> 0) and (P > 0) and (P < 3) and (Z < 2) then Continue;
      if not DefaultOrder then MetaCoder.WriteInt(0, Nump - 1, P);
      if R.MinV(P) >= R.MaxV(P) then Continue;
      if Options.predictor[P] < 0 then
        Predictor := FindBestPredictor(Imgs, R, P, Z)
      else
        Predictor := Options.predictor[P];
      if Options.predictor[P] < 0 then MetaCoder.WriteInt(0, MAX_PREDICTOR, Predictor);
      if Nump > 3 then SetLength(Props, NB_PROPERTIESA[P])
      else SetLength(Props, NB_PROPERTIES[P]);

      if (Z and 1) = 0 then
      begin
        // horizontal: scan the odd rows
        Row := 1;
        while Row < Imgs[0].RowsZ(Z) do
        begin
          Progress.pixels_done := Progress.pixels_done + Int64(Imgs[0].ColsZ(Z));
          for Fr := 0 to High(Imgs) do
          begin
            Img := Imgs[Fr];
            if Img.SeenBefore >= 0 then Continue;
            RBegin := Img.ColBegin[Row * ZoomRowPixelSize(Z)] div ZoomColPixelSize(Z);
            REnd := 1 + (Img.ColEnd[Row * ZoomRowPixelSize(Z)] - 1) div ZoomColPixelSize(Z);
            for C := RBegin to REnd - 1 do
            begin
              if AlphaZero and (P < 3) and (Img.GetValZ(3, Z, Row, C) = 0) then Continue;
              if FRA and (P < 4) and (Img.GetValZ(4, Z, Row, C) > 0) then Continue;
              Guess := PredictAndCalcProps(Props, R, Img, Z, P, Row, C, MinV, MaxV, Predictor);
              Curr := Img.GetValZ(P, Z, Row, C);
              if FRA then
              begin
                if (P = 4) and (MaxV > Fr) then MaxV := Fr;
                if (Guess > MaxV) or (Guess < MinV) then Guess := MinV;
              end;
              Coders[P].WriteInt(Props, MinV - Guess, MaxV - Guess, Curr - Guess);
            end;
          end;
          Inc(Row, 2);
        end;
      end
      else
      begin
        // vertical: scan the odd columns
        for Row := 0 to Imgs[0].RowsZ(Z) - 1 do
        begin
          Progress.pixels_done := Progress.pixels_done + Int64(Imgs[0].ColsZ(Z)) div 2;
          for Fr := 0 to High(Imgs) do
          begin
            Img := Imgs[Fr];
            if Img.SeenBefore >= 0 then Continue;
            RBegin := Img.ColBegin[Row * ZoomRowPixelSize(Z)] div ZoomColPixelSize(Z);
            REnd := (1 + (Img.ColEnd[Row * ZoomRowPixelSize(Z)] - 1) div ZoomColPixelSize(Z)) or 1;
            if (RBegin > 1) and ((RBegin and 1) = 0) then Dec(RBegin);
            if RBegin = 0 then RBegin := 1;
            C := RBegin;
            while C < REnd do
            begin
              if AlphaZero and (P < 3) and (Img.GetValZ(3, Z, Row, C) = 0) then
              begin
                Inc(C, 2);
                Continue;
              end;
              if FRA and (P < 4) and (Img.GetValZ(4, Z, Row, C) > 0) then
              begin
                Inc(C, 2);
                Continue;
              end;
              Guess := PredictAndCalcProps(Props, R, Img, Z, P, Row, C, MinV, MaxV, Predictor);
              Curr := Img.GetValZ(P, Z, Row, C);
              if FRA then
              begin
                if (P = 4) and (MaxV > Fr) then MaxV := Fr;
                if (Guess > MaxV) or (Guess < MinV) then Guess := MinV;
              end;
              Coders[P].WriteInt(Props, MinV - Guess, MaxV - Guess, Curr - Guess);
              Inc(C, 2);
            end;
          end;
        end;
      end;
    end;
    if (Options.chroma_subsampling <> 0) and (Nump > 1) and (EndZL = 0) then
      MetaCoder.WriteInt(0, Nump - 1, 1);
  finally
    MetaCoder.Free;
  end;
end;

procedure FlifEncodeFLIF2Pass(IO: TFlifIO; Rac: TRacOut; const Imgs: TImages;
  R: TColorRanges; const Forest: TTreeArray; BeginZL, EndZL, Repeats: Integer;
  var Options: TFlifOptions; var Progress: TProgress; Final: Boolean; Bits: Integer);
var
  Coders: TPropCoderArray;
  PropRanges: Ranges;
  P, Fr: Integer;
  MetaCoder: TUniformSymbolCoder;
begin
  SetLength(Coders, R.NumPlanes);
  for P := 0 to R.NumPlanes - 1 do
  begin
    InitPropRanges(PropRanges, R, P);
    if Final then
      Coders[P] := TFinalPropertySymbolCoder.Create(nil, Rac, PropRanges, Forest[P],
        Options.split_threshold, Options.cutoff, Options.alpha, Bits)
    else
      Coders[P] := TPropertySymbolCoder.Create(nil, Rac, PropRanges, Forest[P],
        Options.split_threshold, Options.cutoff, Options.alpha, Bits);
  end;
  try
    if (BeginZL = Imgs[0].Zooms) and (EndZL > 0) then
    begin
      // special case: the very top left pixel must be written first
      MetaCoder := TUniformSymbolCoder.Create(nil, Rac);
      try
        for P := 0 to Imgs[0].NumPlanes - 1 do
          if R.MinV(P) < R.MaxV(P) then
          begin
            for Fr := 0 to High(Imgs) do
              MetaCoder.WriteInt(R.MinV(P), R.MaxV(P), Imgs[Fr].GetValZ(P, 0, 0, 0));
            Inc(Progress.pixels_done);
          end;
      finally
        MetaCoder.Free;
      end;
    end;
    while Repeats > 0 do
    begin
      Dec(Repeats);
      FlifEncodeFLIF2Inner(IO, Rac, Coders, Imgs, R, BeginZL, EndZL, Options, Progress);
    end;
    for P := 0 to Imgs[0].NumPlanes - 1 do
      Coders[P].Simplify(Options.divisor, Options.min_size, P);
  finally
    for P := 0 to R.NumPlanes - 1 do Coders[P].Free;
  end;
end;

procedure FlifEncodeFLIF2InterpolZeroAlpha(const Imgs: TImages; R: TColorRanges;
  BeginZL, EndZL, Predictor: Integer);
var
  Greys: TColorValArray;
  Fr, I, P, Z: Integer;
  Row, C: Cardinal;
  Img: TImage;
begin
  Greys := ComputeGreys(R);
  for Fr := 0 to High(Imgs) do
  begin
    Img := Imgs[Fr];
    if Img.GetVal(3, 0, 0) = 0 then
    begin
      Img.SetVal(0, 0, 0, Greys[0]);
      Img.SetVal(1, 0, 0, Greys[1]);
      Img.SetVal(2, 0, 0, Greys[2]);
    end;
    for I := 0 to PlaneZoomlevels(Img, BeginZL, EndZL) - 1 do
    begin
      PlaneZoomlevel(Img, BeginZL, EndZL, I, R, P, Z);
      if P >= 3 then Continue;
      if (Z and 1) = 0 then
      begin
        Row := 1;
        while Row < Img.RowsZ(Z) do
        begin
          for C := 0 to Img.ColsZ(Z) - 1 do
            if Img.GetValZ(3, Z, Row, C) = 0 then
              Img.SetValZ(P, Z, Row, C, Predict(Img, Z, P, Row, C, Predictor));
          Inc(Row, 2);
        end;
      end
      else
      begin
        for Row := 0 to Img.RowsZ(Z) - 1 do
        begin
          C := 1;
          while C < Img.ColsZ(Z) do
          begin
            if Img.GetValZ(3, Z, Row, C) = 0 then
              Img.SetValZ(P, Z, Row, C, Predict(Img, Z, P, Row, C, Predictor));
            Inc(C, 2);
          end;
        end;
      end;
    end;
  end;
end;

procedure FlifEncodeScanlinesInterpolZeroAlpha(const Imgs: TImages; R: TColorRanges);
var
  Greys: TColorValArray;
  Nump, Fr, P: Integer;
  Row, C: Cardinal;
  Img: TImage;
begin
  Greys := ComputeGreys(R);
  Nump := Imgs[0].NumPlanes;
  if Nump <= 3 then Exit;
  for Fr := 0 to High(Imgs) do
  begin
    Img := Imgs[Fr];
    for P := 0 to 2 do
      for Row := 0 to Img.Rows - 1 do
        for C := 0 to Img.Cols - 1 do
          if Img.GetVal(3, Row, C) = 0 then
            Img.SetVal(P, Row, C, PredictScanlines(Img, P, Row, C, Greys[P]));
  end;
end;

procedure FlifEncodeTree(Rac: TRacOut; R: TColorRanges; const Forest: TTreeArray;
  Encoding: TFlifEncoding);
var
  P: Integer;
  PropRanges: Ranges;
  MetaCoder: TMetaPropertySymbolCoder;
begin
  for P := 0 to R.NumPlanes - 1 do
  begin
    if Encoding = feNonInterlaced then InitPropRangesScanlines(PropRanges, R, P)
    else InitPropRanges(PropRanges, R, P);
    MetaCoder := TMetaPropertySymbolCoder.Create(nil, Rac, PropRanges);
    try
      if R.MinV(P) < R.MaxV(P) then
        MetaCoder.WriteTree(Forest[P]);
    finally
      MetaCoder.Free;
    end;
  end;
end;

procedure FlifEncodeMain(Rac: TRacOut; IO: TFlifIO; const Imgs: TImages;
  R: TColorRanges; var Options: TFlifOptions; Bits: Integer);
var
  Encoding: TFlifEncoding;
  LearnRepeats, I, RealNumPlanes, RoughZL, P: Integer;
  Progress: TProgress;
  Forest: TTreeArray;
  Dummy: TRacDummy;
  MetaCoder: TUniformSymbolCoder;
  Img: TImage;
begin
  Encoding := Options.method;
  LearnRepeats := Options.learn_repeats;
  Img := Imgs[0];
  RealNumPlanes := 0;
  for I := 0 to R.NumPlanes - 1 do
    if R.MinV(I) < R.MaxV(I) then Inc(RealNumPlanes);
  InitProgress(Progress);
  Progress.pixels_todo := Int64(Img.Rows) * Int64(Img.Cols) * RealNumPlanes * (LearnRepeats + 1);
  Progress.pixels_done := 0;
  if Progress.pixels_todo = 0 then
  begin
    Progress.pixels_todo := 1;
    Progress.pixels_done := 1;
  end;

  SetLength(Forest, R.NumPlanes);
  for I := 0 to R.NumPlanes - 1 do Forest[I] := TTree.Create;
  Dummy := TRacDummy.Create;
  try
    RoughZL := 0;
    if Encoding = feInterlaced then
    begin
      RoughZL := Img.Zooms - NB_NOLEARN_ZOOMS - 1;
      if RoughZL < 0 then RoughZL := 0;
      MetaCoder := TUniformSymbolCoder.Create(nil, Rac);
      try
        MetaCoder.WriteInt(0, Img.Zooms, RoughZL);
      finally
        MetaCoder.Free;
      end;
      FlifEncodeFLIF2Pass(IO, Rac, Imgs, R, Forest, Img.Zooms, RoughZL + 1, 1,
        Options, Progress, True, Bits);
    end;

    if LearnRepeats > 0 then
      v_printf(3, Format('Learning a MANIAC tree. Iterating %d time%s.'#10,
        [LearnRepeats, BoolToStr(LearnRepeats > 1, 's', '')]));
    case Encoding of
      feNonInterlaced:
        FlifEncodeScanlinesPass(IO, nil, Dummy, Imgs, R, Forest, LearnRepeats,
          Options, Progress, False, Bits);
      feInterlaced:
        FlifEncodeFLIF2Pass(IO, Dummy, Imgs, R, Forest, RoughZL, 0, LearnRepeats,
          Options, Progress, False, Bits);
    end;

    FlifEncodeTree(Rac, R, Forest, Encoding);

    Options.divisor := 0;
    Options.min_size := 0;
    Options.split_threshold := 0;

    case Encoding of
      feNonInterlaced:
        FlifEncodeScanlinesPass(IO, nil, Rac, Imgs, R, Forest, 1,
          Options, Progress, True, Bits);
      feInterlaced:
        FlifEncodeFLIF2Pass(IO, Rac, Imgs, R, Forest, RoughZL, 0, 1,
          Options, Progress, True, Bits);
    end;
  finally
    Dummy.Free;
    for I := 0 to High(Forest) do Forest[I].Free;
  end;
end;

// ------------------------------------------------------------------

function FlifEncode(IO: TFlifIO; var Imgs: TImages; const TransDesc: array of string;
  var Options: TFlifOptions): Boolean;
var
  Encoding: TFlifEncoding;
  NumPlanes, NumFrames, C, P, I, Fr, TCount, MBits, NBits, Bits: Integer;
  Img: TImage;
  Rac: TRacOut24;
  MetaCoder: TUniformSymbolCoder;
  AlphaZero: Integer;
  Checksum: Cardinal;
  RangesList: array of TColorRanges;
  Trans: TTransform;
  PreviousRange, R: TColorRanges;
  NewRanges: TColorRanges;
  SmallerBuffer: Boolean;
  WarnIncompat: Integer;
  Ok: Boolean;
begin
  Encoding := Options.method;
  NumPlanes := Imgs[0].NumPlanes;
  NumFrames := Length(Imgs);

  IO.FPutS('FLIF');
  // byte 5 encodes colour type, interlacing and animation
  C := Ord(' ') + 16 * Ord(Encoding) + NumPlanes;
  if NumFrames > 1 then Inc(C, 32);
  IO.FPutC(C);

  // byte 6 encodes the bit depth
  C := Ord('1');
  for P := 0 to NumPlanes - 1 do
    if Imgs[0].MaxVal(P) <> 255 then C := Ord('2');
  if C = Ord('2') then
    for P := 0 to NumPlanes - 1 do
      if Imgs[0].MaxVal(P) <> 65535 then C := Ord('0');
  IO.FPutC(C);

  Img := Imgs[0];

  WriteBigEndianVarint(IO, Img.Cols - 1);
  WriteBigEndianVarint(IO, Img.Rows - 1);
  if NumFrames > 1 then
    WriteBigEndianVarint(IO, NumFrames - 2);

  for I := 0 to High(Imgs[0].Metadata) do
  begin
    WriteChunk(IO, Imgs[0].Metadata[I]);
    v_printf(3, Format('Encoded metadata chunk: %s'#10, [Imgs[0].Metadata[I].Name]));
  end;

  // marker to indicate the FLIF version (0 aka FLIF16)
  IO.FPutC(0);

  Rac := TRacOut24.Create(IO);
  MetaCoder := TUniformSymbolCoder.Create(nil, Rac);
  RangesList := nil;
  Result := False;
  try
    v_printf(2, Format(' (%ux%u', [Img.Cols, Img.Rows]));
    if C = Ord('0') then
      for P := 0 to NumPlanes - 1 do
      begin
        MetaCoder.WriteInt(1, 16, ilog2(Cardinal(Img.MaxVal(P) + 1)));
        v_printf(3, Format(' [%d] %d bpp', [P, ilog2(Cardinal(Img.MaxVal(P) + 1))]));
      end;
    if C = Ord('1') then v_printf(3, Format(', %d channels, 8-bit', [NumPlanes]))
    else if C = Ord('2') then v_printf(3, Format(', %d channels, 16-bit', [NumPlanes]));
    if NumFrames > 1 then v_printf(3, Format(', %d frames', [NumFrames]));

    AlphaZero := 0;
    if NumPlanes > 3 then
    begin
      if Imgs[0].AlphaZeroSpecial then AlphaZero := 1;
      if AlphaZero <> 0 then MetaCoder.WriteInt(0, 1, 1)
      else MetaCoder.WriteInt(0, 1, 0);
      if AlphaZero = 0 then v_printf(3, ', keep RGB at A=0');
    end;
    v_printf(2, ')'#10);

    if NumFrames > 1 then
    begin
      MetaCoder.WriteInt(0, 100, 0);    // repeats (0 = infinite)
      for I := 0 to NumFrames - 1 do
        MetaCoder.WriteInt(0, 60000, Imgs[I].FrameDelay);
    end;

    if (Options.cutoff = 2) and (Options.alpha = 19) then
      MetaCoder.WriteInt(0, 1, 0)      // using default constants for cutoff/alpha
    else
    begin
      MetaCoder.WriteInt(0, 1, 1);
      MetaCoder.WriteInt(1, 128, Options.cutoff);
      MetaCoder.WriteInt(2, 128, Options.alpha);
      MetaCoder.WriteInt(0, 1, 0);     // default initial bitchances
    end;
    Options.alpha := Cardinal($FFFFFFFF) div Options.alpha;

    Checksum := 0;
    if Imgs[0].Palette then Options.crc_check := 0;
    if (Options.crc_check <> 0) and (Options.loss = 0) then
    begin
      if AlphaZero <> 0 then
        for I := 0 to High(Imgs) do Imgs[I].MakeInvisibleRgbBlack;
      Checksum := Img.Checksum;
    end;

    SetLength(RangesList, 1);
    RangesList[0] := GetRanges(Img);
    TCount := 0;
    WarnIncompat := 0;
    v_printf(3, 'Transforms: ');

    for I := 0 to High(TransDesc) do
    begin
      Trans := CreateTransform(TransDesc[I]);
      if Trans = nil then Continue;
      PreviousRange := RangesList[High(RangesList)];
      if (TransDesc[I] = 'Palette') or (TransDesc[I] = 'Palette_Alpha') then
        Trans.Configure(Options.palette_size);
      if TransDesc[I] = 'Frame_Lookback' then Trans.Configure(Options.lookback);
      if TransDesc[I] = 'PermutePlanes' then Trans.Configure(Options.subtract_green);
      Ok := Trans.Init(PreviousRange);
      if Ok then
      begin
        Ok := Trans.Process(PreviousRange, Imgs);
        if (not Ok) and (Options.acb = 1) and (TransDesc[I] = 'Color_Buckets') then
        begin
          v_printf(3, ', forced ');
          TCount := 0;
          Ok := True;
        end;
      end;
      if not Ok then
      begin
        if Imgs[0].Palette and (TransDesc[I] = 'Palette_Alpha') and (Options.keep_palette <> 0) then
        begin
          v_printf(2, 'Could not keep palette for some reason. Aborting.'#10);
          Trans.Free;
          Exit(False);
        end;
        Trans.Free;
      end
      else
      begin
        if TCount > 0 then v_printf(3, ', ');
        Inc(TCount);
        v_printf(3, TransDesc[I]);
        Rac.WriteBit(True);
        WriteName(Rac, TransDesc[I]);
        Trans.Save(PreviousRange, Rac);
        NewRanges := Trans.Meta(Imgs, PreviousRange);
        SetLength(RangesList, Length(RangesList) + 1);
        RangesList[High(RangesList)] := NewRanges;
        Trans.Data(Imgs);
        if TransDesc[I] = 'Color_Buckets' then WarnIncompat := 1;
        if (WarnIncompat <> 0) and ((TransDesc[I] = 'Frame_Lookback') or
           (TransDesc[I] = 'Duplicate_Frame') or (TransDesc[I] = 'Frame_Shape')) then
          WarnIncompat := 2;
        Trans.Free;
      end;
    end;
    if TCount = 0 then v_printf(3, 'none'#10) else v_printf(3, #10);
    if WarnIncompat > 1 then
      v_printf(1, 'WARNING: This animated FLIF will probably not be properly decoded by older FLIF decoders.'#10);
    Rac.WriteBit(False);
    R := RangesList[High(RangesList)];

    for P := 0 to R.NumPlanes - 1 do
      v_printf(7, Format('Plane %d: %d..%d'#10, [P, R.MinV(P), R.MaxV(P)]));

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
      e_printf('OOPS: this FLIF only supports up to 16-bit RGBA'#10);
      Exit(False);
    end;

    if (AlphaZero <> 0) and (R.NumPlanes > 3) and (R.MinV(3) <= 0) then
    begin
      v_printf(4, 'Replacing fully transparent subpixels with predicted subpixel values'#10);
      case Encoding of
        feNonInterlaced: FlifEncodeScanlinesInterpolZeroAlpha(Imgs, R);
        feInterlaced:
          begin
            v_printf(4, Format('Invisible pixel predictor: -H%d'#10, [Options.invisible_predictor]));
            MetaCoder.WriteInt(0, MAX_PREDICTOR, Options.invisible_predictor);
            FlifEncodeFLIF2InterpolZeroAlpha(Imgs, R, Img.Zooms, 0, Options.invisible_predictor);
          end;
      end;
    end;

    for P := 1 to R.NumPlanes - 1 do
      if R.MinV(P) >= R.MaxV(P) then
        for Fr := 0 to NumFrames - 1 do
          Imgs[Fr].MakeConstantPlane(P, R.MinV(P));

    SmallerBuffer := False;
    if Imgs[0].Palette and (R.MaxV(1) < 256) and (Options.keep_palette <> 0) and
       ((R.NumPlanes < 4) or (R.MinV(3) = R.MaxV(3))) then SmallerBuffer := True;
    if not SmallerBuffer then
      for Fr := 0 to NumFrames - 1 do Imgs[Fr].UndoMakeConstantPlane(0);

    if Encoding = feInterlaced then
    begin
      v_printf(3, 'Using pixel predictor method: -G');
      for P := 0 to R.NumPlanes - 1 do
        if Options.predictor[P] = -2 then
        begin
          if R.MinV(P) < R.MaxV(P) then
          begin
            Options.predictor[P] := FindBestPredictor(Imgs, R, P, 1);
            // predictor 0 is usually the safest choice
            if (Options.predictor[P] > 0) and (FindBestPredictor(Imgs, R, P, 0) <> Options.predictor[P]) then
              Options.predictor[P] := 0;
          end
          else
            Options.predictor[P] := 0;
        end;
      for P := 0 to R.NumPlanes - 1 do
        if Options.predictor[P] >= 0 then v_printf(3, IntToStr(Options.predictor[P]))
        else v_printf(3, 'X');
      v_printf(3, #10);
    end;

    FlifEncodeMain(Rac, IO, Imgs, R, Options, Bits);

    if (Options.crc_check <> 0) and (Options.loss = 0) and
       ((Options.crc_check > 0) or (IO.FTell > 100)) and (Options.chroma_subsampling = 0) then
    begin
      v_printf(2, Format('Writing checksum: %X'#10, [Checksum]));
      MetaCoder.WriteInt(0, 1, 1);
      MetaCoder.WriteIntBits(16, (Checksum shr 16) and $FFFF);
      MetaCoder.WriteIntBits(16, Checksum and $FFFF);
    end
    else
    begin
      v_printf(2, 'Not writing checksum'#10);
      MetaCoder.WriteInt(0, 1, 0);
    end;
    Rac.Flush;
    IO.Flush;

    if NumFrames = 1 then
      v_printf(2, Format('Wrote output FLIF file %s, %d bytes for %ux%u pixels (%.4f bpp)'#10,
        [IO.GetName, IO.FTell, Imgs[0].Cols, Imgs[0].Rows,
         8.0 * IO.FTell / Imgs[0].Rows / Imgs[0].Cols]))
    else
      v_printf(2, Format('Wrote output FLIF file %s, %d bytes for %d frames of %ux%u pixels'#10,
        [IO.GetName, IO.FTell, NumFrames, Imgs[0].Cols, Imgs[0].Rows]));

    Result := True;
  finally
    MetaCoder.Free;
    Rac.Free;
    for I := High(RangesList) downto 0 do RangesList[I].Free;
  end;
end;

end.
