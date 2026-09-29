unit JpegPositionState;

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
  SysUtils,
  LeptonConsts, LeptonErrors, JpegHeader, JpegHuffman, JpegComponentInfo;

type
  TJpegPositionState = record
  private
    FCmp: SizeInt;
    FMCU: LongWord;
    FCSC: SizeInt;
    FSub: LongWord;
    FDPos: LongWord;
    FRSTW: LongWord;
    function NextMCUPosNonInterleaved(JF: TJpegHeader): TJpegDecodeStatus;
  public
    EOBRun: Word;
    PrevEOBRun: Word;

    class function Init(JF: TJpegHeader; MCU: LongWord): TJpegPositionState; static;
    function GetMCU: LongWord; inline;
    function GetDPos: LongWord; inline;
    function GetCmp: SizeInt; inline;
    function GetRSTW: LongWord; inline;
    function GetCumulativeResetMarkers(JF: TJpegHeader): LongWord;
    procedure ResetRSTW(JF: TJpegHeader);
    function NextMCUPos(JF: TJpegHeader): TJpegDecodeStatus;
    function SkipEOBRun(JF: TJpegHeader): TJpegDecodeStatus;
    procedure CheckOptimalEOBRun(IsCurrentBlockEmpty: Boolean; const HC: THuffCodes);
  end;

implementation

function CheckedAddLW(A, B: LongWord; const WhereMsg: string): LongWord; inline;
begin
  if QWord(A) + QWord(B) > High(LongWord) then
    LeptonFail(lecUnsupportedJpeg, WhereMsg);
  Result := A + B;
end;

class function TJpegPositionState.Init(JF: TJpegHeader; MCU: LongWord): TJpegPositionState;
var
  Cmp: SizeInt;
  MCUMul: LongWord;
begin
  if JF = nil then
    LeptonFail(lecAssertionFailure, 'JpegPositionState.Init requires a JPEG header');
  if JF.CSCmpC = 0 then
    LeptonFail(lecAssertionFailure, 'JpegPositionState.Init requires a current scan');

  Cmp := JF.CSCmp[0];
  MCUMul := JF.CmpInfo[Cmp].SFV * JF.CmpInfo[Cmp].SFH;

  Result.FCmp := Cmp;
  Result.FMCU := MCU;
  Result.FCSC := 0;
  Result.FSub := 0;
  Result.FDPos := MCU * MCUMul;

  if JF.RSTI <> 0 then
    Result.FRSTW := JF.RSTI - (MCU mod JF.RSTI)
  else
    Result.FRSTW := 0;

  Result.EOBRun := 0;
  Result.PrevEOBRun := 0;
end;

function TJpegPositionState.GetMCU: LongWord;
begin
  Result := FMCU;
end;

function TJpegPositionState.GetDPos: LongWord;
begin
  Result := FDPos;
end;

function TJpegPositionState.GetCmp: SizeInt;
begin
  Result := FCmp;
end;

function TJpegPositionState.GetRSTW: LongWord;
begin
  Result := FRSTW;
end;

function TJpegPositionState.GetCumulativeResetMarkers(JF: TJpegHeader): LongWord;
begin
  if FRSTW <> 0 then
    Result := FMCU div JF.RSTI
  else
    Result := 0;
end;

procedure TJpegPositionState.ResetRSTW(JF: TJpegHeader);
begin
  if JF = nil then
    LeptonFail(lecAssertionFailure, 'ResetRSTW requires a JPEG header');
  FRSTW := JF.RSTI;

  // EOB runs never span restart intervals.
  PrevEOBRun := 0;
end;

function TJpegPositionState.NextMCUPosNonInterleaved(JF: TJpegHeader): TJpegDecodeStatus;
var
  CI: TComponentInfo;
begin
  FDPos := CheckedAddLW(FDPos, 1, 'next_mcu_pos_noninterleaved: integer overflow');

  CI := JF.CmpInfo[FCmp];

  // Fix for non-interleaved MCU: horizontal padding blocks.
  if (CI.BCH <> CI.NCH) and ((FDPos mod CI.BCH) = CI.NCH) then
    FDPos := CheckedAddLW(FDPos, CI.BCH - CI.NCH, 'next_mcu_pos_noninterleaved: horizontal overflow');

  // Fix for non-interleaved MCU: vertical padding blocks.
  if (CI.BCV <> CI.NCV) and ((FDPos div CI.BCH) = CI.NCV) then
    FDPos := CI.BC;

  if JF.JpegType = jtSequential then
    FMCU := FDPos div (CI.SFV * CI.SFH);

  if FDPos >= CI.BC then
    Result := jdsScanCompleted
  else if JF.RSTI > 0 then
  begin
    Dec(FRSTW);
    if FRSTW = 0 then
      Result := jdsRestartIntervalExpired
    else
      Result := jdsDecodeInProgress;
  end
  else
    Result := jdsDecodeInProgress;
end;

function TJpegPositionState.NextMCUPos(JF: TJpegHeader): TJpegDecodeStatus;
var
  LocalMCUH, LocalMCU, LocalSub: LongWord;
  LocalCmp: SizeInt;
  SFH, SFV: LongWord;
  MCUOverMCUH, SubOverSFV, MCUModMCUH, SubModSFV, LocalDPos: LongWord;
begin
  if JF = nil then
    LeptonFail(lecAssertionFailure, 'NextMCUPos requires a JPEG header');

  if JF.CSCmpC = 1 then
    Exit(NextMCUPosNonInterleaved(JF));

  Result := jdsDecodeInProgress;
  LocalMCUH := JF.MCUH;
  LocalMCU := FMCU;
  LocalCmp := FCmp;

  Inc(FSub);
  LocalSub := FSub;
  if LocalSub >= JF.CmpInfo[LocalCmp].MBS then
  begin
    FSub := 0;
    LocalSub := 0;

    Inc(FCSC);
    if FCSC >= JF.CSCmpC then
    begin
      FCSC := 0;
      FCmp := JF.CSCmp[0];
      LocalCmp := FCmp;

      Inc(FMCU);
      LocalMCU := FMCU;

      if LocalMCU >= JF.MCUC then
        Result := jdsScanCompleted
      else if JF.RSTI > 0 then
      begin
        Dec(FRSTW);
        if FRSTW = 0 then
          Result := jdsRestartIntervalExpired;
      end;
    end
    else
    begin
      FCmp := JF.CSCmp[FCSC];
      LocalCmp := FCmp;
    end;
  end;

  SFH := JF.CmpInfo[LocalCmp].SFH;
  SFV := JF.CmpInfo[LocalCmp].SFV;

  if SFH > 1 then
  begin
    MCUOverMCUH := LocalMCU div LocalMCUH;
    SubOverSFV := LocalSub div SFV;
    MCUModMCUH := LocalMCU - (MCUOverMCUH * LocalMCUH);
    SubModSFV := LocalSub - (SubOverSFV * SFV);
    LocalDPos := (MCUOverMCUH * SFH) + SubOverSFV;

    LocalDPos := LocalDPos * JF.CmpInfo[LocalCmp].BCH;
    LocalDPos := LocalDPos + (MCUModMCUH * SFV) + SubModSFV;

    FDPos := LocalDPos;
  end
  else if SFV > 1 then
    FDPos := (LocalMCU * JF.CmpInfo[LocalCmp].MBS) + LocalSub
  else
    FDPos := FMCU;
end;

function TJpegPositionState.SkipEOBRun(JF: TJpegHeader): TJpegDecodeStatus;
var
  CI: TComponentInfo;
  AddAmount: LongWord;
begin
  if JF = nil then
    LeptonFail(lecAssertionFailure, 'SkipEOBRun requires a JPEG header');
  if JF.CSCmpC <> 1 then
    LeptonFail(lecAssertionFailure, 'SkipEOBRun only works for non-interleaved scans');

  if EOBRun = 0 then
    Exit(jdsDecodeInProgress);

  if JF.RSTI > 0 then
  begin
    if LongWord(EOBRun) > FRSTW then
      LeptonFail(lecUnsupportedJpeg, 'skip_eobrun: eob run extends past end of reset interval')
    else
      Dec(FRSTW, EOBRun);
  end;

  CI := JF.CmpInfo[FCmp];

  if CI.BCH <> CI.NCH then
  begin
    AddAmount := (((FDPos mod CI.BCH) + LongWord(EOBRun)) div CI.NCH) * (CI.BCH - CI.NCH);
    FDPos := CheckedAddLW(FDPos, AddAmount, 'skip_eobrun: horizontal integer overflow');
  end;

  if (CI.BCV <> CI.NCV) and ((FDPos div CI.BCH) >= CI.NCV) then
    FDPos := CheckedAddLW(FDPos, (CI.BCV - CI.NCV) * CI.BCH, 'skip_eobrun: vertical integer overflow');

  FDPos := CheckedAddLW(FDPos, EOBRun, 'skip_eobrun: integer overflow');
  EOBRun := 0;

  if FDPos = CI.BC then
    Result := jdsScanCompleted
  else if FDPos > CI.BC then
    LeptonFail(lecUnsupportedJpeg, 'skip_eobrun: position extended past block count')
  else if (JF.RSTI > 0) and (FRSTW = 0) then
    Result := jdsRestartIntervalExpired
  else
    Result := jdsDecodeInProgress;
end;

procedure TJpegPositionState.CheckOptimalEOBRun(IsCurrentBlockEmpty: Boolean; const HC: THuffCodes);
begin
  if IsCurrentBlockEmpty then
  begin
    if (PrevEOBRun > 0) and (PrevEOBRun < HC.MaxEOBRun - 1) then
      LeptonFail(lecUnsupportedJpeg,
        Format('non optimal eobruns not supported (could have encoded up to %d zero runs in a row, but only did %d followed by %d',
          [HC.MaxEOBRun, PrevEOBRun + 1, EOBRun + 1]));
  end;

  PrevEOBRun := EOBRun;
end;

end.
