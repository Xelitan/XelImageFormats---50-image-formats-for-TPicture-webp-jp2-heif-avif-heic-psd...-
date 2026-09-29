unit BitmapEveryX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	TBitmap for Delphi/Laz on Win/Lin/Mact                        //
// Version:	0.1                                                           //
// Date:	09-JUN-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

{$IFDEF MSWINDOWS}
uses SysUtils, Classes, Graphics; //Windows, both Delphi and Lazarus
{$ENDIF}

{$IFNDEF DELPHI}{$IFNDEF MSWINDOWS}
uses SysUtils, Classes, Graphics, IntfGraphics, GraphType; //Lazarus
{$ENDIF}{$ENDIF}

{$IFDEF DELPHI}{$IFNDEF MSWINDOWS}
uses System.SysUtils, System.Classes, System.UITypes, FMX.Types, FMX.Graphics; //Delphi, Linux or MacOS
{$ENDIF}{$ENDIF}


//converts BGRA pixels to a TBitmap
function Bitmap_Every(Pixels: PByte; Wid, Hei: Integer): TBitmap;

//Move operation would be faster but less obvious and this unit needs to be upgradeable easily

implementation

function CheckBitmap(Pixels: PByte; Wid, Hei: Integer): Boolean;
begin
  if Pixels = nil then Exit(False);
  if (Wid <= 0) or (Hei <= 0) then Exit(False);

  Result := True;
end;

{$IFDEF MSWINDOWS}
function Bitmap_ScanLine(Pixels: PByte; Wid, Hei: Integer): TBitmap;
type
  PBGR32 = ^TBGR32;
  TBGR32 = packed record
    B,G,R,A: Byte;
  end;
var
  X, Y: Integer;
  Src: PByte;
  Dst: PBGR32;
  DstLine: PByte;
begin
  if not CheckBitmap(Pixels, Wid, Hei) then
    raise Exception.Create('Invalid Pixels');

  Result := TBitmap.Create;
  try
    Result.PixelFormat := pf32bit;
    Result.SetSize(Wid, Hei);

    Src := Pixels;

    for Y := 0 to Hei - 1 do
    begin
      DstLine := Result.ScanLine[Y];
      Dst := PBGR32(DstLine);

      for X := 0 to Wid - 1 do
      begin
        // in&out: BGRA
        Dst^.B := Src[0];
        Dst^.G := Src[1];
        Dst^.R := Src[2];
        Dst^.A := Src[3];

        Inc(Src, 4);
        Inc(Dst);
      end;
    end;

  except
    Result.Free;
    raise;
  end;
end;
{$ENDIF}

{$IFNDEF DELPHI}{$IFNDEF MSWINDOWS}
function Bitmap_Lazarus(Pixels: PByte; Wid, Hei: Integer): TBitmap;
type
  PBGRA32 = ^TBGRA32;
  TBGRA32 = packed record
    B,G,R,A: Byte;
  end;

var
  Img: TLazIntfImage;
  Desc: TRawImageDescription;
  X, Y: Integer;
  Src: PByte;
  DstLine: PByte;
  Dst: PBGRA32;
  BytesPerLine: Integer;
begin
  if not CheckBitmap(Pixels, Wid, Hei) then
    raise Exception.Create('Invalid Pixels');

  Result := TBitmap.Create;
  Img := nil;

  try
    Desc.Init_BPP32_B8G8R8A8_BIO_TTB(Wid, Hei);

    Img := TLazIntfImage.Create(0, 0);
    Img.DataDescription := Desc;

    Img.SetSize(Wid, Hei);

    if Img.PixelData = nil then
      raise Exception.Create('TLazIntfImage.PixelData is nil');

    BytesPerLine := Img.DataDescription.BytesPerLine;

    Src := Pixels;

    for Y := 0 to Hei - 1 do
    begin
      DstLine := PByte(Img.PixelData) + NativeInt(Y) * BytesPerLine;
      Dst := PBGRA32(DstLine);

      for X := 0 to Wid - 1 do
      begin
        // in&out: BGRA
        Dst^.B := Src[0];
        Dst^.G := Src[1];
        Dst^.R := Src[2];
        Dst^.A := Src[3];

        Inc(Src, 4);
        Inc(Dst);
      end;
    end;

    Result.LoadFromIntfImage(Img);

  except
    Result.Free;
    raise;
  end;

  Img.Free;
end;
{$ENDIF}{$ENDIF}

{$IFDEF DELPHI}{$IFNDEF MSWINDOWS}
function Bitmap_FMX(Pixels: PByte; Wid, Hei: Integer): TBitmap;
var
  Data: TBitmapData;
  X, Y: Integer;
  Src: PByte;
  DstLine: PByte;
  Dst: PByte;
begin
  if not CheckBitmap(Pixels, Wid, Hei) then
    raise Exception.Create('Invalid Pixels');

  Result := TBitmap.Create(Wid, Hei);

  try
    if not Result.Map(TMapAccess.Write, Data) then
      raise Exception.Create('Cannot map TBitmapData');

    try
      if not (Data.PixelFormat in [TPixelFormat.BGRA, TPixelFormat.RGBA]) then
      raise Exception.Create('Unsupported PixelFormat');

      Src := Pixels;

      for Y := 0 to Hei - 1 do
      begin
        DstLine := PByte(Data.Data) + NativeInt(Y) * Data.Pitch;
        Dst := DstLine;

        for X := 0 to Wid - 1 do
        begin
          case Data.PixelFormat of
            TPixelFormat.BGRA:
              begin
                Dst[0] := Src[0];
                Dst[1] := Src[1];
                Dst[2] := Src[2];
                Dst[3] := Src[3];
              end;

            TPixelFormat.RGBA:
              begin
                Dst[0] := Src[2];
                Dst[1] := Src[1];
                Dst[2] := Src[0];
                Dst[3] := Src[3];
              end;
          end;

          Inc(Src, 4);
          Inc(Dst, 4);
        end;
      end;

    finally
      Result.Unmap(Data);
    end;

  except
    Result.Free;
    raise;
  end;
end;
{$ENDIF}{$ENDIF}

function Bitmap_Every(Pixels: PByte; Wid, Hei: Integer): TBitmap;
begin
  {$IFDEF MSWINDOWS}
    //Windows, both Delphi and Lazarus
    Result := Bitmap_ScanLine(Pixels, Wid, Hei);
  {$ENDIF}

  {$IFDEF DELPHI}
    //Delphi, Linux or MacOS
    {$IFNDEF MSWINDOWS}
      Result := Bitmap_FMX(Pixels, Wid, Hei);
    {$ENDIF}
  {$ENDIF}

  {$IFNDEF DELPHI}
    //Lazarus, Linux or MacOS
    {$IFNDEF MSWINDOWS}
      Result := Bitmap_Lazarus(Pixels, Wid, Hei);
    {$ENDIF}
  {$ENDIF}
end;

end.
