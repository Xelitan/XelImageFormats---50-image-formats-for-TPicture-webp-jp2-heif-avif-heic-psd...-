unit JpegRead;

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//

{$mode delphi}
{$H+}
{$R-}
{$Q-}

interface

uses
  Classes, SysUtils,
  LeptonConsts, LeptonErrors, LeptonFeatures, JpegCodes, JpegHeader, JpegBlockImage, JpegScanDecoder;

function PrepareToDecodeNextScan(JpegHeader: TJpegHeader; var RInfo: TReconstructionInfo;
  Stream: TStream; const EnabledFeatures: TEnabledFeatures): Boolean;

function ReadJpegHeaderFromStream(Stream: TStream; JpegHeader: TJpegHeader;
  var RInfo: TReconstructionInfo; const EnabledFeatures: TEnabledFeatures): Boolean;

function ReadJpegCoefficientsFromStream(Stream: TStream; JpegHeader: TJpegHeader;
  var RInfo: TReconstructionInfo; const EnabledFeatures: TEnabledFeatures;
  out ImageData: TBlockBasedImageArray; out Partitions: TRestartPartitionArray;
  out EndScanPosition: Int64): Boolean;

implementation

procedure ReadExact(Stream: TStream; var Buffer; Count: SizeInt);
var
  Got: SizeInt;
begin
  Got := Stream.Read(Buffer, Count);
  if Got <> Count then
    LeptonFail(lecUnsupportedJpeg, 'unexpected end of JPEG file');
end;

function MaxLW(A, B: LongWord): LongWord; inline;
begin
  if A > B then
    Result := A
  else
    Result := B;
end;

function PrepareToDecodeNextScan(JpegHeader: TJpegHeader; var RInfo: TReconstructionInfo;
  Stream: TStream; const EnabledFeatures: TEnabledFeatures): Boolean;
var
  I: SizeInt;
  SA: Byte;
begin
  Result := ParseJpegHeader(Stream, EnabledFeatures, JpegHeader, RInfo);
  if not Result then
    Exit;

  RInfo.MaxBPos := MaxLW(RInfo.MaxBPos, JpegHeader.CSTo);
  if JpegHeader.CSSAL > JpegHeader.CSSAH then
    SA := JpegHeader.CSSAL
  else
    SA := JpegHeader.CSSAH;
  if SA > RInfo.MaxSAH then
    RInfo.MaxSAH := SA;

  for I := 0 to JpegHeader.CSCmpC - 1 do
    RInfo.MaxCmp := MaxLW(RInfo.MaxCmp, JpegHeader.CSCmp[I]);
end;

function ReadJpegHeaderFromStream(Stream: TStream; JpegHeader: TJpegHeader;
  var RInfo: TReconstructionInfo; const EnabledFeatures: TEnabledFeatures): Boolean;
var
  StartHeader: array[0..1] of Byte;
begin
  if JpegHeader = nil then
    LeptonFail(lecAssertionFailure, 'ReadJpegHeaderFromStream requires a header object');

  ReadExact(Stream, StartHeader, SizeOf(StartHeader));
  if (StartHeader[0] <> $FF) or (StartHeader[1] <> JPEG_SOI) then
    LeptonFail(lecUnsupportedJpeg, 'jpeg must start with with 0xff 0xd8');

  Result := PrepareToDecodeNextScan(JpegHeader, RInfo, Stream, EnabledFeatures);
  if not Result then
    LeptonFail(lecUnsupportedJpeg, 'Jpeg does not contain scans');
end;


function ReadJpegCoefficientsFromStream(Stream: TStream; JpegHeader: TJpegHeader;
  var RInfo: TReconstructionInfo; const EnabledFeatures: TEnabledFeatures;
  out ImageData: TBlockBasedImageArray; out Partitions: TRestartPartitionArray;
  out EndScanPosition: Int64): Boolean;
var
  StartHeader: array[0..1] of Byte;
  I: SizeInt;
  StartScanPosition: Int64;
begin
  if JpegHeader = nil then
    LeptonFail(lecAssertionFailure, 'ReadJpegCoefficientsFromStream requires a header object');

  SetLength(ImageData, 0);
  SetLength(Partitions, 0);
  EndScanPosition := 0;

  ReadExact(Stream, StartHeader, SizeOf(StartHeader));
  if (StartHeader[0] <> $FF) or (StartHeader[1] <> JPEG_SOI) then
    LeptonFail(lecUnsupportedJpeg, 'jpeg must start with with 0xff 0xd8');

  if not PrepareToDecodeNextScan(JpegHeader, RInfo, Stream, EnabledFeatures) then
    LeptonFail(lecUnsupportedJpeg, 'Jpeg does not contain scans');

  if (not EnabledFeatures.Progressive) and (not JpegHeader.IsSingleScan) then
    LeptonFail(lecUnsupportedJpeg, 'file is progressive or contains multiple scans, but this is disabled');

  if JpegHeader.CmpC > COLOR_CHANNEL_NUM_BLOCK_TYPES then
    LeptonFail(lecUnsupportedJpeg, 'doesn''t support 4 color channels');

  SetLength(ImageData, JpegHeader.CmpC);
  for I := 0 to JpegHeader.CmpC - 1 do
    ImageData[I] := TBlockBasedImage.CreateForComponent(
      JpegHeader.CmpInfo[I].BCH,
      JpegHeader.CmpInfo[I].BCV,
      JpegHeader.CmpInfo[0].BCV,
      0,
      JpegHeader.CmpInfo[0].BCV);

  StartScanPosition := Stream.Position;
  ReadFirstScan(JpegHeader, Stream, Partitions, ImageData, RInfo);
  EndScanPosition := Stream.Position;

  if StartScanPosition + 2 > EndScanPosition then
    LeptonFail(lecUnsupportedJpeg, 'no scan data found in JPEG file');
  if Length(Partitions) = 0 then
    LeptonFail(lecUnsupportedJpeg, 'no scan information found in JPEG file');

  if not JpegHeader.IsSingleScan then
  begin
    // progressive / multi-scan: keep reading scan headers + scans until EOI
    while PrepareToDecodeNextScan(JpegHeader, RInfo, Stream, EnabledFeatures) do
      ReadProgressiveScan(JpegHeader, Stream, ImageData, RInfo);
    EndScanPosition := Stream.Position;
  end;

  Result := True;
end;

end.
