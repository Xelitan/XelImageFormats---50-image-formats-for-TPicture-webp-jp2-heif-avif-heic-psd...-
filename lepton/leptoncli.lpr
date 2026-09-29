program leptoncli;

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//

{$mode delphi}
{$H+}

uses
  SysUtils, Classes,
  LeptonErrors, LeptonFeatures, LeptonFile;

procedure Usage;
begin
  Writeln('Lepton JPEG <-> LEPTON coder/decoder');
  Writeln;
  Writeln('Usage:');
  Writeln('  leptoncli c  <in.jpg> <out.lep>  - compress JPEG -> LEPTON (+ round-trip verification)');
  Writeln('  leptoncli cf <in.jpg> <out.lep>  - compress with no verification (faster)');
  Writeln('  leptoncli d  <in.lep> <out.jpg> [-scalar|-no16dc]');
  Writeln('               - decompress LEPTON -> JPEG; -scalar / -no16dc select');
  Writeln('                 compat flags for old C++ scalar-build files');
end;

procedure RunEncode(const InName, OutName: string; Verify: Boolean);
var
  InS, OutS: TFileStream;
  Features: TEnabledFeatures;
  T0: TDateTime;
begin
  Features := TEnabledFeatures.CompatLeptonVectorWrite;
  InS := TFileStream.Create(InName, fmOpenRead or fmShareDenyWrite);
  try
    OutS := TFileStream.Create(OutName, fmCreate);
    try
      T0 := Now;
      if Verify then
        EncodeLeptonVerify(InS, OutS, Features)
      else
        EncodeLepton(InS, OutS, Features);
      Writeln(Format('OK: %s (%d B) -> %s (%d B)  [%.0f%% of size, %d ms]',
        [InName, InS.Size, OutName, OutS.Size,
         100.0 * OutS.Size / InS.Size, Round((Now - T0) * 86400000)]));
    finally
      OutS.Free;
    end;
  finally
    InS.Free;
  end;
end;

procedure RunDecode(const InName, OutName, Opt: string);
var
  InS, OutS: TFileStream;
  Features: TEnabledFeatures;
  T0: TDateTime;
begin
  // Old C++ lepton files don't carry the SIMD-flavor flags, so files written
  // by a scalar build need the flags supplied by the caller (mirrors the
  // compat_lepton_*_read distinction in the Rust implementation).
  if Opt = '-scalar' then
    Features := TEnabledFeatures.CompatLeptonScalarRead
  else
  begin
    Features := TEnabledFeatures.CompatLeptonVectorRead;
    if Opt = '-no16dc' then
      Features.Use16BitDcEstimate := False;
  end;
  InS := TFileStream.Create(InName, fmOpenRead or fmShareDenyWrite);
  try
    OutS := TFileStream.Create(OutName, fmCreate);
    try
      T0 := Now;
      DecodeLepton(InS, OutS, Features);
      Writeln(Format('OK: %s (%d B) -> %s (%d B)  [%d ms]',
        [InName, InS.Size, OutName, OutS.Size, Round((Now - T0) * 86400000)]));
    finally
      OutS.Free;
    end;
  finally
    InS.Free;
  end;
end;

var
  Mode: string;
begin
  if ParamCount < 3 then
  begin
    Usage;
    Halt(1);
  end;

  try
    Mode := LowerCase(ParamStr(1));
    if (Mode = 'c') or (Mode = 'e') or (Mode = 'encode') or (Mode = 'compress') then
      RunEncode(ParamStr(2), ParamStr(3), True)
    else if (Mode = 'cf') or (Mode = 'compress-fast') then
      RunEncode(ParamStr(2), ParamStr(3), False)
    else if (Mode = 'd') or (Mode = 'decode') or (Mode = 'decompress') then
      RunDecode(ParamStr(2), ParamStr(3), LowerCase(ParamStr(4)))
    else
    begin
      Usage;
      Halt(1);
    end;
  except
    on E: ELeptonError do
    begin
      Writeln(ErrOutput, Format('Lepton ERROR (code %d): %s', [Ord(E.Code), E.Message]));
      Halt(2);
    end;
    on E: Exception do
    begin
      Writeln(ErrOutput, Format('ERROR (%s): %s', [E.ClassName, E.Message]));
      Halt(2);
    end;
  end;
end.
