unit JpegRowSpec;

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//

{$mode delphi}
{$H+}
{$R-}
{$Q-}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, LeptonConsts, LeptonErrors, JpegBlockImage;

type
  TBlockBasedImageArray = array of TBlockBasedImage;
  TLongWordDynArray = array of LongWord;

  TRowSpec = record
    LumaY: LongWord;
    Component: SizeInt;
    CurrY: LongWord;
    MCURowIndex: LongWord;
    LastRowToCompleteMCU: Boolean;
    Skip: Boolean;
    Done: Boolean;
    class function GetRowSpecFromIndex(DecodeIndex: LongWord;
      const ImageData: TBlockBasedImageArray; MCUV: LongWord;
      const MaxCodedHeights: TLongWordDynArray): TRowSpec; static;
  end;

implementation

class function TRowSpec.GetRowSpecFromIndex(DecodeIndex: LongWord;
  const ImageData: TBlockBasedImageArray; MCUV: LongWord;
  const MaxCodedHeights: TLongWordDynArray): TRowSpec;
var
  NumCmp, I, J: SizeInt;
  Heights, ComponentMultiple: TLongWordDynArray;
  MCUMultiple, MCURow, MinRowLumaY, PlaceWithinScan: LongWord;
begin
  NumCmp := Length(ImageData);
  if NumCmp = 0 then
    LeptonFail(lecAssertionFailure, 'RowSpec requires at least one component');
  if NumCmp > COLOR_CHANNEL_NUM_BLOCK_TYPES then
    LeptonFail(lecAssertionFailure, 'image_data should match components count');
  if MCUV = 0 then
    LeptonFail(lecAssertionFailure, 'RowSpec requires non-zero MCUV');
  if Length(MaxCodedHeights) < NumCmp then
    LeptonFail(lecAssertionFailure, 'RowSpec requires one max-coded-height per component');

  SetLength(Heights, NumCmp);
  SetLength(ComponentMultiple, NumCmp);
  MCUMultiple := 0;

  for I := 0 to NumCmp - 1 do
  begin
    Heights[I] := ImageData[I].OriginalHeight;
    ComponentMultiple[I] := Heights[I] div MCUV;
    if ComponentMultiple[I] = 0 then
      LeptonFail(lecUnsupportedJpeg, 'component has zero rows per MCU');
    Inc(MCUMultiple, ComponentMultiple[I]);
  end;

  if MCUMultiple = 0 then
    LeptonFail(lecAssertionFailure, 'RowSpec internal zero mcu multiple');

  MCURow := DecodeIndex div MCUMultiple;
  MinRowLumaY := MCURow * ComponentMultiple[0];

  Result.Skip := False;
  Result.Done := False;
  Result.MCURowIndex := MCURow;
  Result.Component := NumCmp;
  Result.LumaY := MinRowLumaY;
  Result.CurrY := 0;
  Result.LastRowToCompleteMCU := False;

  PlaceWithinScan := DecodeIndex - (MCURow * MCUMultiple);

  I := NumCmp - 1;
  while True do
  begin
    if PlaceWithinScan < ComponentMultiple[I] then
    begin
      Result.Component := I;
      Result.CurrY := (MCURow * ComponentMultiple[I]) + PlaceWithinScan;
      Result.LastRowToCompleteMCU := (PlaceWithinScan + 1 = ComponentMultiple[I]) and (I = 0);

      if Result.CurrY >= MaxCodedHeights[I] then
      begin
        Result.Skip := True;
        Result.Done := True;
        if NumCmp > 1 then
          for J := 0 to NumCmp - 2 do
            if MCURow * ComponentMultiple[J] < MaxCodedHeights[J] then
              Result.Done := False;
      end;

      if I = 0 then
        Result.LumaY := Result.CurrY;
      Break;
    end
    else
      Dec(PlaceWithinScan, ComponentMultiple[I]);

    if I = 0 then
    begin
      Result.Skip := True;
      Result.Done := True;
      Break;
    end;

    Dec(I);
  end;
end;

end.
