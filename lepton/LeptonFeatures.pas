unit LeptonFeatures;

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//

{$mode delphi}
{$H+}
{$modeswitch advancedrecords}

interface

type
  TEnabledFeatures = record
    Progressive: Boolean;
    RejectDqtsWithZeros: Boolean;
    MaxJpegWidth: LongWord;
    MaxJpegHeight: LongWord;
    Use16BitDcEstimate: Boolean;
    Use16BitAdvPredict: Boolean;
    AcceptInvalidDht: Boolean;
    MaxPartitions: LongWord;
    MaxProcessorThreads: LongWord;
    MaxJpegFileSize: LongWord;
    StopReadingAtEoi: Boolean;
    class function CompatLeptonVectorWrite: TEnabledFeatures; static;
    class function CompatLeptonScalarRead: TEnabledFeatures; static;
    class function CompatLeptonVectorRead: TEnabledFeatures; static;
  end;

implementation

class function TEnabledFeatures.CompatLeptonVectorWrite: TEnabledFeatures;
begin
  Result.Progressive := True;
  Result.RejectDqtsWithZeros := True;
  Result.MaxJpegHeight := 16386;
  Result.MaxJpegWidth := 16386;
  Result.Use16BitDcEstimate := True;
  Result.Use16BitAdvPredict := True;
  Result.AcceptInvalidDht := False;
  Result.MaxPartitions := 8;
  Result.MaxProcessorThreads := 8;
  Result.MaxJpegFileSize := 128 * 1024 * 1024;
  Result.StopReadingAtEoi := False;
end;

class function TEnabledFeatures.CompatLeptonScalarRead: TEnabledFeatures;
begin
  Result.Progressive := True;
  Result.RejectDqtsWithZeros := False;
  Result.MaxJpegHeight := High(LongWord);
  Result.MaxJpegWidth := High(LongWord);
  Result.Use16BitDcEstimate := False;
  Result.Use16BitAdvPredict := False;
  Result.AcceptInvalidDht := True;
  Result.MaxPartitions := 8;
  Result.MaxProcessorThreads := 8;
  Result.MaxJpegFileSize := 128 * 1024 * 1024;
  Result.StopReadingAtEoi := False;
end;

class function TEnabledFeatures.CompatLeptonVectorRead: TEnabledFeatures;
begin
  Result.Progressive := True;
  Result.RejectDqtsWithZeros := False;
  Result.MaxJpegHeight := High(LongWord);
  Result.MaxJpegWidth := High(LongWord);
  Result.Use16BitDcEstimate := True;
  Result.Use16BitAdvPredict := True;
  Result.AcceptInvalidDht := True;
  Result.MaxPartitions := 8;
  Result.MaxProcessorThreads := 8;
  Result.MaxJpegFileSize := 128 * 1024 * 1024;
  Result.StopReadingAtEoi := False;
end;

end.
