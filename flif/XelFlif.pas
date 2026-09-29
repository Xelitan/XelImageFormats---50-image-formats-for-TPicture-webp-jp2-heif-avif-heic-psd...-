unit XelFlif;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	FLIF codec -> RGBA8 (wraps the flif_* port in this folder)     //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     Apache 2/LGPL                                                 //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, Math,
  flif_types, flif_io, flif_image, flif_dec, flif_enc;

type
  EFlifError = class(Exception);

// Decodes a FLIF file to RGBA8. An animation gives its first frame; depths
// above 8 bits are shifted down.
function DecodeFlif(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8

// Encodes RGBA8 to FLIF (RGB; alpha is not stored).
//   IsLossless : True = exact.
//   Quality    : lossy quality 0..100 (higher = better), mapped onto FLIF's loss.
function EncodeFlif(InBuf: TBytes; Width, Height: Integer;                // InBuf = RGBA8
                    IsLossless: Boolean = True; Quality: Integer = 75): TBytes;

implementation

function DecodeFlif(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  IO      : TBlobIO;
  Imgs    : TImages;
  Options : TFlifOptions;
  MD      : TMetadataOptions;
  Img     : TImage;
  W, H, X, Y, NP, Shift, I: Integer;
  P       : NativeInt;
begin
  Result := nil;
  Width := 0;
  Height := 0;
  if Length(InBuf) = 0 then
    raise EFlifError.Create('FLIF: empty stream');

  Options := DefaultOptions;
  MD := DefaultMetadataOptions;
  SetLength(Imgs, 0);
  IO := TBlobIO.CreateFromBuffer(@InBuf[0], SizeInt(Length(InBuf)));
  try
    if not FlifDecode(IO, Imgs, Options, MD) then
      if Length(Imgs) = 0 then
        raise EFlifError.Create('FLIF decode failed');
    if Length(Imgs) = 0 then
      raise EFlifError.Create('FLIF: no frames');

    // An animation decodes to several frames; the first one is returned.
    Img := Imgs[0];
    W := Integer(Img.Cols);
    H := Integer(Img.Rows);
    if (W <= 0) or (H <= 0) then
      raise EFlifError.Create('FLIF: bad dimensions');

    NP := Img.NumPlanes;
    // FLIF carries its own bit depth; anything deeper than 8 is shifted down
    // rather than clipped, so highlights survive.
    if Img.GetDepth > 8 then Shift := Img.GetDepth - 8 else Shift := 0;

    SetLength(Result, NativeInt(W) * NativeInt(H) * 4);
    P := 0;
    for Y := 0 to H - 1 do
      for X := 0 to W - 1 do
      begin
        if NP >= 3 then
        begin
          Result[P + 0] := Byte(EnsureRange(Img.GetVal(0, Y, X) shr Shift, 0, 255));
          Result[P + 1] := Byte(EnsureRange(Img.GetVal(1, Y, X) shr Shift, 0, 255));
          Result[P + 2] := Byte(EnsureRange(Img.GetVal(2, Y, X) shr Shift, 0, 255));
        end
        else
        begin
          // greyscale: one plane feeds all three channels
          Result[P + 0] := Byte(EnsureRange(Img.GetVal(0, Y, X) shr Shift, 0, 255));
          Result[P + 1] := Result[P + 0];
          Result[P + 2] := Result[P + 0];
        end;
        if NP >= 4 then
          Result[P + 3] := Byte(EnsureRange(Img.GetVal(3, Y, X) shr Shift, 0, 255))
        else
          Result[P + 3] := 255;
        Inc(P, 4);
      end;
    Width := W;
    Height := H;
  finally
    for I := 0 to High(Imgs) do Imgs[I].Free;
    SetLength(Imgs, 0);
    IO.Free;
  end;
end;

function EncodeFlif(InBuf: TBytes; Width, Height: Integer;
                    IsLossless: Boolean = True; Quality: Integer = 75): TBytes;
var
  IO      : TFlifIO;
  Imgs    : TImages;
  Options : TFlifOptions;
  Img     : TImage;
  X, Y, q, I: Integer;
  P       : NativeInt;
  Desc    : array of string;
  NbPixels: QWord;

  procedure AddDesc(const D: string);
  begin
    SetLength(Desc, Length(Desc) + 1);
    Desc[High(Desc)] := D;
  end;

begin
  Result := nil;
  if (Width <= 0) or (Height <= 0) or
     (NativeInt(Length(InBuf)) < NativeInt(Width) * NativeInt(Height) * 4) then
    raise EFlifError.Create('FLIF encode: empty image');

  Options := DefaultOptions;
  if IsLossless then
    Options.loss := 0
  else
  begin
    // FLIF's loss runs the other way from a quality: 0 is lossless and larger
    // values throw more away.
    q := Quality;
    if q < 0   then q := 0;
    if q > 100 then q := 100;
    Options.loss := Round((100 - q) * 100 / 100);
  end;

  Img := TImage.Create(Cardinal(Width), Cardinal(Height), 0, 255, 3);
  try
    P := 0;
    for Y := 0 to Height - 1 do
      for X := 0 to Width - 1 do
      begin
        Img.SetVal(0, Y, X, InBuf[P + 0]);
        Img.SetVal(1, Y, X, InBuf[P + 1]);
        Img.SetVal(2, Y, X, InBuf[P + 2]);
        Inc(P, 4);
      end;

    SetLength(Imgs, 1);
    Imgs[0] := Img;

    // The preamble the reference encoder runs before FlifEncode. It is not
    // optional: Options.method starts as feUndefined, which the encoder
    // rejects outright, and palette_size and learn_repeats start at -1 meaning
    // "decide for me". The transform list and its ORDER belong to the format,
    // not to taste. Mirrored from flifpas.lpr.
    NbPixels := QWord(Height) * QWord(Width);
    SetLength(Desc, 0);
    if NbPixels > 2 then
    begin
      if Options.plc <> 0 then AddDesc('Channel_Compact');
      if Options.ycocg <> 0 then AddDesc('YCoCg');
      AddDesc('PermutePlanes');
      AddDesc('Bounds');
    end;
    if Options.palette_size = -1 then
    begin
      Options.palette_size := DEFAULT_MAX_PALETTE_SIZE;
      if NbPixels div 3 < DEFAULT_MAX_PALETTE_SIZE then
        Options.palette_size := Integer(NbPixels div 3);
    end;
    if (Options.loss = 0) and (Options.palette_size <> 0) then
    begin
      AddDesc('Palette_Alpha');
      AddDesc('Palette');
    end;
    if (Options.loss = 0) and (NbPixels > 10000) then
      AddDesc('Color_Buckets');
    if Options.method = feUndefined then
    begin
      if NbPixels < 10000 then Options.method := feNonInterlaced
      else Options.method := feInterlaced;
    end;
    if Options.learn_repeats < 0 then Options.learn_repeats := TREE_LEARN_REPEATS;

    IO := TFlifIO.Create;   // memory buffer
    try
      if not FlifEncode(IO, Imgs, Desc, Options) then
        raise EFlifError.Create('FLIF encode failed');
      IO.Flush;
      if IO.BytesUsed <= 0 then
        raise EFlifError.Create('FLIF encode produced nothing');
      SetLength(Result, IO.BytesUsed);
      Move(IO.Data^, Result[0], IO.BytesUsed);
    finally
      IO.Free;
    end;
  finally
    for I := 0 to High(Imgs) do
      if Imgs[I] <> nil then Imgs[I].Free;
    SetLength(Imgs, 0);
  end;
end;

end.
