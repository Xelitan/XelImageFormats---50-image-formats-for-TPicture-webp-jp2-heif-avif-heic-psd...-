unit LeptonSimple;

{$mode delphi}
{$H+}

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//
// Simple high-level interface for JPEG <-> LEPTON compression.
//
// Functions returning Integer return 0 on success and -1 on error
// (exceptions are caught internally).
//
// The Lepton/UnLepton functions operate on an AnsiString treated as a raw
// byte buffer; on error they return an empty string ('').

interface

uses
  Classes;

// Streams: compress/decompress the entire Infile into Outfile.
function LeptonCompressStreams(Infile, Outfile: TStream): Integer;
function LeptonDecompressStreams(Infile, Outfile: TStream): Integer;

// Files: opens Infilename, creates Outfilename.
function LeptonCompressFile(const Infilename, Outfilename: String): Integer;
function LeptonDecompressFile(const Infilename, Outfilename: String): Integer;

// In-memory buffers (AnsiString = raw bytes).
function Lepton(JpegBody: AnsiString): AnsiString;
function UnLepton(LeptonBody: AnsiString): AnsiString;

implementation

uses
  SysUtils, LeptonFeatures, LeptonFile;

function LeptonCompressStreams(Infile, Outfile: TStream): Integer;
begin
  try
    EncodeLepton(Infile, Outfile, TEnabledFeatures.CompatLeptonVectorWrite);
    Result := 0;
  except
    Result := -1;
  end;
end;

function LeptonDecompressStreams(Infile, Outfile: TStream): Integer;
begin
  try
    DecodeLepton(Infile, Outfile, TEnabledFeatures.CompatLeptonVectorRead);
    Result := 0;
  except
    Result := -1;
  end;
end;

function LeptonCompressFile(const Infilename, Outfilename: String): Integer;
var
  InS, OutS: TFileStream;
begin
  Result := -1;
  InS := nil;
  OutS := nil;
  try
    InS := TFileStream.Create(Infilename, fmOpenRead or fmShareDenyWrite);
    OutS := TFileStream.Create(Outfilename, fmCreate);
    EncodeLepton(InS, OutS, TEnabledFeatures.CompatLeptonVectorWrite);
    Result := 0;
  except
    Result := -1;
  end;
  if Assigned(OutS) then OutS.Free;
  if Assigned(InS) then InS.Free;
end;

function LeptonDecompressFile(const Infilename, Outfilename: String): Integer;
var
  InS, OutS: TFileStream;
begin
  Result := -1;
  InS := nil;
  OutS := nil;
  try
    InS := TFileStream.Create(Infilename, fmOpenRead or fmShareDenyWrite);
    OutS := TFileStream.Create(Outfilename, fmCreate);
    DecodeLepton(InS, OutS, TEnabledFeatures.CompatLeptonVectorRead);
    Result := 0;
  except
    Result := -1;
  end;
  if Assigned(OutS) then OutS.Free;
  if Assigned(InS) then InS.Free;
end;

function Lepton(JpegBody: AnsiString): AnsiString;
var
  InS, OutS: TMemoryStream;
begin
  Result := '';
  InS := TMemoryStream.Create;
  OutS := TMemoryStream.Create;
  try
    try
      if Length(JpegBody) > 0 then
        InS.WriteBuffer(JpegBody[1], Length(JpegBody));
      InS.Position := 0;
      EncodeLepton(InS, OutS, TEnabledFeatures.CompatLeptonVectorWrite);
      SetLength(Result, OutS.Size);
      if OutS.Size > 0 then
      begin
        OutS.Position := 0;
        OutS.ReadBuffer(Result[1], OutS.Size);
      end;
    except
      Result := '';
    end;
  finally
    InS.Free;
    OutS.Free;
  end;
end;

function UnLepton(LeptonBody: AnsiString): AnsiString;
var
  InS, OutS: TMemoryStream;
begin
  Result := '';
  InS := TMemoryStream.Create;
  OutS := TMemoryStream.Create;
  try
    try
      if Length(LeptonBody) > 0 then
        InS.WriteBuffer(LeptonBody[1], Length(LeptonBody));
      InS.Position := 0;
      DecodeLepton(InS, OutS, TEnabledFeatures.CompatLeptonVectorRead);
      SetLength(Result, OutS.Size);
      if OutS.Size > 0 then
      begin
        OutS.Position := 0;
        OutS.ReadBuffer(Result[1], OutS.Size);
      end;
    except
      Result := '';
    end;
  finally
    InS.Free;
    OutS.Free;
  end;
end;

end.
