unit CutImageX;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Dr. Halo CUT TGraphic wrapper (VCL/LCL)                       //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Copyright:	(c) 2026 Xelitan.com. All rights reserved.                    //
//                                                                            //
// The palette lives in a separate .PAL file with the same base name; it is    //
// picked up automatically by LoadFromFile, or can be set with PaletteData.    //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, Graphics, SysUtils, XelCut, XelImageBase;

type
  TCutImage = class(TXelGraphic)
  private
    FPal: TBytes;
  protected
    class procedure DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
                                       out AW, AH: Integer); override;
    procedure DecodeFromStream(Str: TStream); override;
  public
    // Raw contents of a Dr. Halo .PAL file used for the next load (may be empty).
    property PaletteData: TBytes read FPal write FPal;
    procedure LoadFromFile(const Filename: string); override;
    procedure SaveToStream(Stream: TStream); override;
  end;

implementation

function ReadAll(Str: TStream): TBytes;
var Size: NativeInt;
begin
  Result := nil;
  Size := Str.Size - Str.Position;
  if Size <= 0 then Exit;
  SetLength(Result, Size);
  Str.ReadBuffer(Result[0], Size);
end;

class procedure TCutImage.DecodeStreamToRGBA(Str: TStream; out ARGBA: TBytes;
  out AW, AH: Integer);
var Input: TBytes;
begin
  ARGBA := nil; AW := 0; AH := 0;
  Input := ReadAll(Str);
  if Length(Input) > 0 then ARGBA := DecodeCut(Input, AW, AH);
end;

procedure TCutImage.DecodeFromStream(Str: TStream);
var Input, Pixels: TBytes; W, H: Integer;
begin
  Input := ReadAll(Str);
  if Length(Input) = 0 then Exit;
  Pixels := DecodeCutPal(Input, FPal, W, H);
  ReadRGBA(Pixels, W, H);
end;

procedure TCutImage.LoadFromFile(const Filename: string);
var
  PalName: string;
  FS: TFileStream;
begin
  FPal := nil;
  PalName := ChangeFileExt(Filename, '.pal');
  if not FileExists(PalName) then PalName := ChangeFileExt(Filename, '.PAL');
  if FileExists(PalName) then
  begin
    FS := TFileStream.Create(PalName, fmOpenRead or fmShareDenyNone);
    try
      FPal := ReadAll(FS);
    finally
      FS.Free;
    end;
  end;
  inherited LoadFromFile(Filename);
end;

procedure TCutImage.SaveToStream(Stream: TStream);
begin
  raise ECutError.Create('CUT encoding is not supported');
end;

initialization
  TPicture.RegisterFileFormat('cut', 'Dr. Halo Image', TCutImage);

finalization
  TPicture.UnregisterGraphicClass(TCutImage);

end.
