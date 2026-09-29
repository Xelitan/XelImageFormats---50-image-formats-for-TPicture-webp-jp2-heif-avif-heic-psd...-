unit LeptonErrors;

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//

{$mode delphi}
{$H+}

interface

uses
  SysUtils;

type
  TLeptonExitCode = (
    lecOk,
    lecAssertionFailure,
    lecBadLeptonFile,
    lecUnsupportedJpeg,
    lecUnsupportedJpegWithZeroIdct0,
    lecSamplingBeyondTwoUnsupported,
    lecInvalidResetCode,
    lecInvalidPadding,
    lecVerificationLengthMismatch,
    lecVerificationContentMismatch,
    lecStreamInconsistent,
    lecNotPorted
  );

  ELeptonError = class(Exception)
  private
    FCode: TLeptonExitCode;
  public
    constructor CreateCode(ACode: TLeptonExitCode; const AMsg: string);
    property Code: TLeptonExitCode read FCode;
  end;

procedure LeptonFail(ACode: TLeptonExitCode; const AMsg: string);

implementation

constructor ELeptonError.CreateCode(ACode: TLeptonExitCode; const AMsg: string);
begin
  inherited Create(AMsg);
  FCode := ACode;
end;

procedure LeptonFail(ACode: TLeptonExitCode; const AMsg: string);
begin
  raise ELeptonError.CreateCode(ACode, AMsg);
end;

end.
