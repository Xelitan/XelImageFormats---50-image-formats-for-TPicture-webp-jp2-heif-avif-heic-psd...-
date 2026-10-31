unit AvifAnimated;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	AVIF animation (image sequence) decoder and encoder           //
// Version:	0.1                                                           //
// Date:	31-OCT-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Loading: parses the 'avis' container (Avif.Sequence), decodes the colour   //
// track and the optional alpha auxiliary track with the pure-Pascal AV1      //
// decoder (Av1.Decoder), converts YUV to RGB with the sequence's colour      //
// signalling (Heif.Decode) and exposes full-canvas BGRA frames, per-frame    //
// durations (from the sample table) and the loop count (edit list).         //
//                                                                            //
// Saving: frames are converted to 8-bit BT.601 full-range 4:2:0 and coded    //
// with TAv1Encoder; an alpha track is added when any frame is translucent.   //
//                                                                            //
// Usage:                                                                      //
//   Anim := TAvifAnimation.Create;                                           //
//   Anim.LoadFromFile('anim.avif');                                          //
//   for i := 0 to Anim.FrameCount-1 do begin                                 //
//     Canvas.Draw(0, 0, Anim.Frames[i]);                                     //
//     Sleep(Anim.Durations[i]);                                              //
//   end;                                                                      //
//                                                                            //
//   Anim := TAvifAnimation.Create;                                           //
//   Anim.AppendFrame(Bmp1, 100); Anim.AppendFrame(Bmp2, 100);                //
//   Anim.SaveToFile('out.avifs', 70);                                        //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, SysUtils, Graphics, AnimationCommon, XelImageBase,
  Av1.Decoder, Av1.Headers, Av1.Obu, Avif.Sequence, Heif.Decode
  {$IFDEF FPC}, IntfGraphics, FPImage{$ENDIF};

type
  EAvifAnimation = class(Exception);

  TAvifAnimation = class(TCustomAnimation)
  public
    procedure LoadFromStream(Stream: TStream); override;
    // Appends a copy of ABitmap (all frames must have the first frame's size).
    procedure AppendFrame(ABitmap: TBitmap; ADuration: Integer);
    // Quality 1..100 (100 = best). Writes an AVIF image sequence.
    procedure SaveToStream(Stream: TStream; Quality: Integer = 75);
    procedure SaveToFile(const FileName: String; Quality: Integer = 75);
    // 0 = loop forever, n = play n times.
    property LoopCount: Integer read FLoopCount write FLoopCount;
  end;

type
  TAvifRGBAFrame = record
    Pixels: TBytes;      // packed top-down RGBA8
    Duration: Integer;   // milliseconds
  end;
  TAvifRGBAFrames = array of TAvifRGBAFrame;

// True when the data is an AVIF file holding an AV1 image sequence.
function IsAvifSequence(const Data: TBytes): Boolean;

// Decodes up to MaxFrames frames of an AVIF image sequence to RGBA8 (no
// widgetset needed). Loop: 0 = forever, n = play n times.
function DecodeAvifSequence(const Data: TBytes; MaxFrames: Integer;
  out W, H, Loop: Integer): TAvifRGBAFrames;

implementation

type
  TXelAccess = class(TXelGraphic);

function IsAvifSequence(const Data: TBytes): Boolean;
var R: TAvifSequenceReader;
begin
  R := TAvifSequenceReader.Create;
  try
    Result := R.Load(Data);
  finally
    R.Free;
  end;
end;

procedure CopyPlane(const Src: array of Word; var Dst: TSamplePlane);
begin
  SetLength(Dst, Length(Src));
  if Length(Src) > 0 then Move(Src[0], Dst[0], Length(Src) * SizeOf(Word));
end;

// Colour signalling from the sequence header in the av1C config OBUs (or in
// the first sample when the configuration carries none).
function FindSeqHdr(const Obus: TBytes; out S: TSeqHdr): Boolean;
var A: TObuArray; i: Integer;
begin
  Result := False;
  if Length(Obus) = 0 then Exit;
  A := SplitObus(@Obus[0], Length(Obus));
  for i := 0 to High(A) do
    if A[i].ObuType = OBU_SEQUENCE_HEADER then
    begin
      ParseSeqHdr(A[i].Payload, A[i].PayloadSize, S);
      Exit(True);
    end;
end;

function DecodeAvifSequence(const Data: TBytes; MaxFrames: Integer;
  out W, H, Loop: Integer): TAvifRGBAFrames;
var
  S: TBytes;
  R: TAvifSequenceReader;
  DC, DA: TAv1Decoder;
  Seq: TSeqHdr;
  HaveSeq: Boolean;
  ct, at, i, n, na, ow, oh, k: Integer;
  Fr, Fa: TAv1Frame;
  HaveAlpha: Boolean;
  Img: THeifImage;
  RGBA: TBytes;
  ts: LongWord;
  cum: UInt64;
  t0, t1: Int64;
begin
  Result := nil;
  W := 0; H := 0; Loop := 0;
  R := TAvifSequenceReader.Create;
  DC := TAv1Decoder.Create;
  DA := TAv1Decoder.Create;
  try
    if not R.Load(Data) then raise EAvifAnimation.Create('AVIF: no image sequence found');
    ct := R.ColorTrack; at := R.AlphaTrack;
    Loop := R.LoopCount;
    with R.Tracks[ct] do
      if Length(ConfigObus) > 0 then DC.SetConfigObus(@ConfigObus[0], Length(ConfigObus));
    if at >= 0 then
      with R.Tracks[at] do
        if Length(ConfigObus) > 0 then DA.SetConfigObus(@ConfigObus[0], Length(ConfigObus));
    HaveSeq := FindSeqHdr(R.Tracks[ct].ConfigObus, Seq);
    n := Length(R.Tracks[ct].SampleSize);
    if at >= 0 then na := Length(R.Tracks[at].SampleSize) else na := 0;
    ts := R.Tracks[ct].Timescale;
    if ts = 0 then ts := 1000;
    cum := 0;
    for i := 0 to n - 1 do
    begin
      if Length(Result) >= MaxFrames then Break;
      S := R.SampleData(ct, i);
      if not HaveSeq then HaveSeq := FindSeqHdr(S, Seq);
      t0 := (cum * 1000 + ts div 2) div ts;
      Inc(cum, R.Tracks[ct].SampleDuration[i]);
      t1 := (cum * 1000 + ts div 2) div ts;
      if Length(S) = 0 then Continue;
      if not DC.DecodeTemporalUnit(@S[0], Length(S), Fr) then Continue;
      HaveAlpha := False;
      if i < na then
      begin
        S := R.SampleData(at, i);
        if Length(S) > 0 then
          HaveAlpha := DA.DecodeTemporalUnit(@S[0], Length(S), Fa) and
            (Fa.Width = Fr.Width) and (Fa.Height = Fr.Height);
      end;

      Img := Default(THeifImage);
      Img.Width := Fr.Width; Img.Height := Fr.Height;
      Img.BitDepth := Fr.BitDepth;
      if Fr.NumPlanes = 1 then Img.ChromaFormat := 0
      else if (Fr.SsH = 1) and (Fr.SsV = 1) then Img.ChromaFormat := 1
      else if Fr.SsH = 1 then Img.ChromaFormat := 2
      else Img.ChromaFormat := 3;
      CopyPlane(Fr.Y, Img.Y);
      if Fr.NumPlanes = 3 then
      begin
        CopyPlane(Fr.U, Img.U); CopyPlane(Fr.V, Img.V);
        Img.ChromaWidth := Fr.ChromaW; Img.ChromaHeight := Fr.ChromaH;
      end;
      if HaveSeq then
      begin
        Img.HasNclx := True;
        Img.ColorPrimaries := Seq.Pri;
        Img.TransferCharacteristics := Seq.Trc;
        Img.MatrixCoefficients := Seq.Mtrx;
        Img.FullRange := Seq.ColorRange <> 0;
      end
      else
        Img.MatrixCoefficients := 6;
      if HaveAlpha then
      begin
        Img.HasAlpha := True;
        CopyPlane(Fa.Y, Img.Alpha);
        Img.AlphaBitDepth := Fa.BitDepth;
      end;
      HeifImageToRGBA(Img, RGBA, ow, oh);
      if W = 0 then begin W := ow; H := oh; end
      else if (ow <> W) or (oh <> H) then Continue;
      k := Length(Result);
      SetLength(Result, k + 1);
      Result[k].Pixels := RGBA;
      Result[k].Duration := Integer(t1 - t0);
    end;
    if Length(Result) = 0 then raise EAvifAnimation.Create('AVIF: no frames decoded');
  finally
    DA.Free;
    DC.Free;
    R.Free;
  end;
end;

procedure TAvifAnimation.LoadFromStream(Stream: TStream);
var
  Data: TBytes;
  F: TAvifRGBAFrames;
  i: Integer;
  Bmp: TBitmap;
begin
  ClearFrames;
  FWidth := 0; FHeight := 0; FLoopCount := 0; FBgColor := 0;
  SetLength(Data, Stream.Size - Stream.Position);
  if Length(Data) > 0 then Stream.ReadBuffer(Data[0], Length(Data));
  F := DecodeAvifSequence(Data, MaxInt, FWidth, FHeight, FLoopCount);
  Data := nil;
  for i := 0 to High(F) do
  begin
    Bmp := TBitmap.Create;
    try
      TXelAccess.RGBAToBitmap(F[i].Pixels, FWidth, FHeight, Bmp);
    except
      Bmp.Free;
      raise;
    end;
    F[i].Pixels := nil;
    AddFrame(Bmp, F[i].Duration);
  end;
end;

procedure TAvifAnimation.AppendFrame(ABitmap: TBitmap; ADuration: Integer);
var Bmp: TBitmap;
begin
  if FrameCount = 0 then
  begin
    FWidth := ABitmap.Width; FHeight := ABitmap.Height;
  end
  else if (ABitmap.Width <> FWidth) or (ABitmap.Height <> FHeight) then
    raise EAvifAnimation.Create('AVIF: all frames must have the same size');
  Bmp := TBitmap.Create;
  Bmp.Assign(ABitmap);
  AddFrame(Bmp, ADuration);
end;

// Packed top-down RGBA8 of a bitmap.
procedure BitmapToRGBA(Bmp: TBitmap; out Pixels: TBytes);
var
  x, y, W, H: Integer;
  d: NativeInt;
{$IFDEF FPC}
  Intf: TLazIntfImage;
  Col: TFPColor;
{$ELSE}
  Row: PByte;
{$ENDIF}
begin
  W := Bmp.Width; H := Bmp.Height;
  SetLength(Pixels, NativeInt(W) * H * 4);
  d := 0;
{$IFDEF FPC}
  Intf := Bmp.CreateIntfImage;
  try
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        Col := Intf.Colors[x, y];
        Pixels[d + 0] := Col.Red shr 8;
        Pixels[d + 1] := Col.Green shr 8;
        Pixels[d + 2] := Col.Blue shr 8;
        if Bmp.PixelFormat = pf32bit then Pixels[d + 3] := Col.Alpha shr 8
        else Pixels[d + 3] := 255;
        Inc(d, 4);
      end;
  finally
    Intf.Free;
  end;
{$ELSE}
  Bmp.PixelFormat := pf32bit;
  for y := 0 to H - 1 do
  begin
    Row := PByte(Bmp.ScanLine[y]);
    for x := 0 to W - 1 do
    begin
      Pixels[d + 0] := Row[x * 4 + 2];
      Pixels[d + 1] := Row[x * 4 + 1];
      Pixels[d + 2] := Row[x * 4 + 0];
      Pixels[d + 3] := Row[x * 4 + 3];
      Inc(d, 4);
    end;
  end;
{$ENDIF}
end;

// RGBA8 -> BT.601 full-range 4:2:0 (chroma from 2x2 box averages, centred
// siting, which is what Heif.Decode's upsampler assumes) plus the alpha plane.
// Returns True when any pixel is not fully opaque.
function RGBAToYuv420(const P: TBytes; W, H: Integer; out PY, PU, PV, PA: TBytes): Boolean;
var
  x, y, cw, ch, i, j, k, sx, sy, cnt: Integer;
  r, g, b, yy, sr, sg, sb: Double;

  function Clip8(D: Double): Byte;
  var t: Integer;
  begin
    t := Round(D);
    if t < 0 then t := 0 else if t > 255 then t := 255;
    Result := Byte(t);
  end;

begin
  cw := (W + 1) shr 1; ch := (H + 1) shr 1;
  SetLength(PY, W * H); SetLength(PA, W * H);
  SetLength(PU, cw * ch); SetLength(PV, cw * ch);
  Result := False;
  for i := 0 to W * H - 1 do
  begin
    r := P[i * 4]; g := P[i * 4 + 1]; b := P[i * 4 + 2];
    PY[i] := Clip8(0.299 * r + 0.587 * g + 0.114 * b);
    PA[i] := P[i * 4 + 3];
    if PA[i] <> 255 then Result := True;
  end;
  for y := 0 to ch - 1 do
    for x := 0 to cw - 1 do
    begin
      sr := 0; sg := 0; sb := 0; cnt := 0;
      for j := 0 to 1 do
        for k := 0 to 1 do
        begin
          sx := x * 2 + k; sy := y * 2 + j;
          if (sx >= W) or (sy >= H) then Continue;
          i := (sy * W + sx) * 4;
          sr := sr + P[i]; sg := sg + P[i + 1]; sb := sb + P[i + 2];
          Inc(cnt);
        end;
      sr := sr / cnt; sg := sg / cnt; sb := sb / cnt;
      yy := 0.299 * sr + 0.587 * sg + 0.114 * sb;
      PU[y * cw + x] := Clip8((sb - yy) / 1.772 + 128);
      PV[y * cw + x] := Clip8((sr - yy) / 1.402 + 128);
    end;
end;

procedure TAvifAnimation.SaveToStream(Stream: TStream; Quality: Integer);
var
  Cfg, ACfg: TAv1EncConfig;
  Enc, AEnc: TAv1Encoder;
  Wr: TAvifSequenceWriter;
  Px: array of TBytes;
  Y, U, V, Al, Tu, ATu, Outb: TBytes;
  i, q: Integer;
  anyAlpha, key, akey: Boolean;
begin
  if FrameCount = 0 then raise EAvifAnimation.Create('AVIF: no frames to save');
  if Quality < 1 then Quality := 1;
  if Quality > 100 then Quality := 100;
  q := Round((100 - Quality) * 2.55);
  if q < 1 then q := 1;

  // gather pixels first: the alpha track is written only when needed
  SetLength(Px, FrameCount);
  anyAlpha := False;
  for i := 0 to FrameCount - 1 do
  begin
    BitmapToRGBA(Frames[i], Px[i]);
    if RGBAToYuv420(Px[i], FWidth, FHeight, Y, U, V, Al) then anyAlpha := True;
  end;

  Cfg := Default(TAv1EncConfig);
  Cfg.Width := FWidth; Cfg.Height := FHeight;
  Cfg.Layout := 1;           // LAYOUT_I420
  Cfg.QIdx := q;
  Cfg.FullRange := True;
  Cfg.ColorPrimaries := 1; Cfg.TransferCharacteristics := 13; Cfg.MatrixCoefficients := 6;
  ACfg := Cfg;
  ACfg.Layout := 0;          // LAYOUT_I400
  ACfg.QIdx := (q + 1) div 2;
  if ACfg.QIdx < 1 then ACfg.QIdx := 1;
  ACfg.ColorPrimaries := 2; ACfg.TransferCharacteristics := 2; ACfg.MatrixCoefficients := 2;

  Enc := TAv1Encoder.Create(Cfg);
  AEnc := nil;
  Wr := TAvifSequenceWriter.Create;
  try
    if anyAlpha then AEnc := TAv1Encoder.Create(ACfg);
    Wr.Width := FWidth; Wr.Height := FHeight;
    Wr.BitDepth := 8; Wr.ChromaSubX := 1; Wr.ChromaSubY := 1; Wr.Monochrome := False;
    Wr.SeqProfile := 0; Wr.SeqLevelIdx0 := Enc.SeqLevelIdx; Wr.SeqTier := 0;
    Wr.ColorConfigObus := Enc.SequenceHeaderObu;
    if anyAlpha then
    begin
      Wr.AlphaConfigObus := AEnc.SequenceHeaderObu;
      Wr.AlphaProfile := 0; Wr.AlphaLevel := AEnc.SeqLevelIdx;
    end;
    Wr.FullRange := True;
    Wr.MatrixCoefficients := 6; Wr.ColourPrimaries := 1; Wr.TransferCharacteristics := 13;
    Wr.LoopCount := FLoopCount;
    for i := 0 to FrameCount - 1 do
    begin
      RGBAToYuv420(Px[i], FWidth, FHeight, Y, U, V, Al);
      Px[i] := nil;
      Tu := Enc.EncodeFrame(Y, U, V, False, key);
      ATu := nil;
      if anyAlpha then
        ATu := AEnc.EncodeFrame(Al, Al, Al, key, akey);
      Wr.AddFrame(Tu, ATu, Durations[i], key);
    end;
    Outb := Wr.Build;
    Stream.WriteBuffer(Outb[0], Length(Outb));
  finally
    Wr.Free;
    AEnc.Free;
    Enc.Free;
  end;
end;

procedure TAvifAnimation.SaveToFile(const FileName: String; Quality: Integer);
var fs: TFileStream;
begin
  fs := TFileStream.Create(FileName, fmCreate);
  try
    SaveToStream(fs, Quality);
  finally
    fs.Free;
  end;
end;

end.
