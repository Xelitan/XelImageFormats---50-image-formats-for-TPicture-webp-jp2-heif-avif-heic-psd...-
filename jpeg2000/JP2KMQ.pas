// JPEG 2000 based on JASPER 4.2.9
// License: JasPer-2.0 (similar to MIT )
// Author: www.xelitan.com
//
// JP2KMQ - MQ arithmetic coder (encoder + decoder).
//
// Free Pascal port of JasPer's jpc_mqcod.c (state table), jpc_mqenc.c
// (encoder) and jpc_mqdec.c (decoder).
//
// The C implementation links state-table entries with pointers; here the links
// are stored as array indices (NMps/NLps) into MqStates.  The per-context
// state arrays hold the index of the current state for each context.

unit JP2KMQ;

{$mode delphi}
{$H+}
{$Q-}   // no overflow checking: registers wrap mod 2^32 like uint32 in C
{$R-}

interface

uses
  JP2KCommon;

const
  JPC_MQENC_DEFTERM = 0;   // default termination
  JPC_MQENC_PTERM   = 1;   // predictable termination

type
  // An MQ state-table entry.
  TMqState = record
    QEval: Word;       // Qe value
    Mps: Byte;         // the MPS symbol (0/1)
    NMps: Integer;     // index of next state on MPS
    NLps: Integer;     // index of next state on LPS
  end;

  // Per-context initialisation info.
  TMqCtx = record
    Mps: Byte;
    Ind: ShortInt;
  end;
  TMqCtxArray = array of TMqCtx;

  // MQ arithmetic encoder.
  TMqEnc = class
  private
    FCReg, FAReg, FCTReg: Cardinal;
    FCtxs: TIntArray;       // state index per context
    FCurCtx: Integer;       // current context number
    FOut: TMemStream;
    FOutBuf: Integer;
    FLastByte: Integer;
    FErr: Boolean;
    procedure ByteOut2;
    procedure ByteOut;
    procedure Renorme;
    procedure CodeMps2;     // completion of CODEMPS (areg already decremented)
    procedure CodeLps;      // full CODELPS
    procedure SetBits;
  public
    constructor Create(AMaxCtxs: Integer; AOut: TMemStream);
    procedure Init;
    procedure SetCtxs(const ACtxs: TMqCtxArray);
    procedure SetCurCtx(ACtxNo: Integer); inline;
    procedure PutBit(Bit: Integer);
    function Flush(TermMode: Integer): Integer;
    property Error: Boolean read FErr;
  end;

  // MQ arithmetic decoder.
  TMqDec = class
  private
    FCReg, FAReg, FCTReg: Cardinal;
    FCtxs: TIntArray;
    FCurCtx: Integer;
    FIn: TMemStream;
    FInBuffer: Byte;
    FEof: Boolean;
    procedure ByteIn;
    procedure Renormd;
    function MpsExchRenormd: Integer;
    function LpsExchRenormd: Integer;
  public
    constructor Create(AMaxCtxs: Integer; AIn: TMemStream);
    procedure SetInput(AIn: TMemStream);
    procedure Init;
    procedure SetCtxs(const ACtxs: TMqCtxArray);
    procedure SetCurCtx(ACtxNo: Integer); inline;
    function GetBit: Integer;
  end;

const
  // The MQ coder per-state information (ITU-T T.88 / ISO 15444-1, Table C-2).
  MqStates: array[0..93] of TMqState = (
    (QEval: $5601; Mps: 0; NMps:  2; NLps:  3),
    (QEval: $5601; Mps: 1; NMps:  3; NLps:  2),
    (QEval: $3401; Mps: 0; NMps:  4; NLps: 12),
    (QEval: $3401; Mps: 1; NMps:  5; NLps: 13),
    (QEval: $1801; Mps: 0; NMps:  6; NLps: 18),
    (QEval: $1801; Mps: 1; NMps:  7; NLps: 19),
    (QEval: $0ac1; Mps: 0; NMps:  8; NLps: 24),
    (QEval: $0ac1; Mps: 1; NMps:  9; NLps: 25),
    (QEval: $0521; Mps: 0; NMps: 10; NLps: 58),
    (QEval: $0521; Mps: 1; NMps: 11; NLps: 59),
    (QEval: $0221; Mps: 0; NMps: 76; NLps: 66),
    (QEval: $0221; Mps: 1; NMps: 77; NLps: 67),
    (QEval: $5601; Mps: 0; NMps: 14; NLps: 13),
    (QEval: $5601; Mps: 1; NMps: 15; NLps: 12),
    (QEval: $5401; Mps: 0; NMps: 16; NLps: 28),
    (QEval: $5401; Mps: 1; NMps: 17; NLps: 29),
    (QEval: $4801; Mps: 0; NMps: 18; NLps: 28),
    (QEval: $4801; Mps: 1; NMps: 19; NLps: 29),
    (QEval: $3801; Mps: 0; NMps: 20; NLps: 28),
    (QEval: $3801; Mps: 1; NMps: 21; NLps: 29),
    (QEval: $3001; Mps: 0; NMps: 22; NLps: 34),
    (QEval: $3001; Mps: 1; NMps: 23; NLps: 35),
    (QEval: $2401; Mps: 0; NMps: 24; NLps: 36),
    (QEval: $2401; Mps: 1; NMps: 25; NLps: 37),
    (QEval: $1c01; Mps: 0; NMps: 26; NLps: 40),
    (QEval: $1c01; Mps: 1; NMps: 27; NLps: 41),
    (QEval: $1601; Mps: 0; NMps: 58; NLps: 42),
    (QEval: $1601; Mps: 1; NMps: 59; NLps: 43),
    (QEval: $5601; Mps: 0; NMps: 30; NLps: 29),
    (QEval: $5601; Mps: 1; NMps: 31; NLps: 28),
    (QEval: $5401; Mps: 0; NMps: 32; NLps: 28),
    (QEval: $5401; Mps: 1; NMps: 33; NLps: 29),
    (QEval: $5101; Mps: 0; NMps: 34; NLps: 30),
    (QEval: $5101; Mps: 1; NMps: 35; NLps: 31),
    (QEval: $4801; Mps: 0; NMps: 36; NLps: 32),
    (QEval: $4801; Mps: 1; NMps: 37; NLps: 33),
    (QEval: $3801; Mps: 0; NMps: 38; NLps: 34),
    (QEval: $3801; Mps: 1; NMps: 39; NLps: 35),
    (QEval: $3401; Mps: 0; NMps: 40; NLps: 36),
    (QEval: $3401; Mps: 1; NMps: 41; NLps: 37),
    (QEval: $3001; Mps: 0; NMps: 42; NLps: 38),
    (QEval: $3001; Mps: 1; NMps: 43; NLps: 39),
    (QEval: $2801; Mps: 0; NMps: 44; NLps: 38),
    (QEval: $2801; Mps: 1; NMps: 45; NLps: 39),
    (QEval: $2401; Mps: 0; NMps: 46; NLps: 40),
    (QEval: $2401; Mps: 1; NMps: 47; NLps: 41),
    (QEval: $2201; Mps: 0; NMps: 48; NLps: 42),
    (QEval: $2201; Mps: 1; NMps: 49; NLps: 43),
    (QEval: $1c01; Mps: 0; NMps: 50; NLps: 44),
    (QEval: $1c01; Mps: 1; NMps: 51; NLps: 45),
    (QEval: $1801; Mps: 0; NMps: 52; NLps: 46),
    (QEval: $1801; Mps: 1; NMps: 53; NLps: 47),
    (QEval: $1601; Mps: 0; NMps: 54; NLps: 48),
    (QEval: $1601; Mps: 1; NMps: 55; NLps: 49),
    (QEval: $1401; Mps: 0; NMps: 56; NLps: 50),
    (QEval: $1401; Mps: 1; NMps: 57; NLps: 51),
    (QEval: $1201; Mps: 0; NMps: 58; NLps: 52),
    (QEval: $1201; Mps: 1; NMps: 59; NLps: 53),
    (QEval: $1101; Mps: 0; NMps: 60; NLps: 54),
    (QEval: $1101; Mps: 1; NMps: 61; NLps: 55),
    (QEval: $0ac1; Mps: 0; NMps: 62; NLps: 56),
    (QEval: $0ac1; Mps: 1; NMps: 63; NLps: 57),
    (QEval: $09c1; Mps: 0; NMps: 64; NLps: 58),
    (QEval: $09c1; Mps: 1; NMps: 65; NLps: 59),
    (QEval: $08a1; Mps: 0; NMps: 66; NLps: 60),
    (QEval: $08a1; Mps: 1; NMps: 67; NLps: 61),
    (QEval: $0521; Mps: 0; NMps: 68; NLps: 62),
    (QEval: $0521; Mps: 1; NMps: 69; NLps: 63),
    (QEval: $0441; Mps: 0; NMps: 70; NLps: 64),
    (QEval: $0441; Mps: 1; NMps: 71; NLps: 65),
    (QEval: $02a1; Mps: 0; NMps: 72; NLps: 66),
    (QEval: $02a1; Mps: 1; NMps: 73; NLps: 67),
    (QEval: $0221; Mps: 0; NMps: 74; NLps: 68),
    (QEval: $0221; Mps: 1; NMps: 75; NLps: 69),
    (QEval: $0141; Mps: 0; NMps: 76; NLps: 70),
    (QEval: $0141; Mps: 1; NMps: 77; NLps: 71),
    (QEval: $0111; Mps: 0; NMps: 78; NLps: 72),
    (QEval: $0111; Mps: 1; NMps: 79; NLps: 73),
    (QEval: $0085; Mps: 0; NMps: 80; NLps: 74),
    (QEval: $0085; Mps: 1; NMps: 81; NLps: 75),
    (QEval: $0049; Mps: 0; NMps: 82; NLps: 76),
    (QEval: $0049; Mps: 1; NMps: 83; NLps: 77),
    (QEval: $0025; Mps: 0; NMps: 84; NLps: 78),
    (QEval: $0025; Mps: 1; NMps: 85; NLps: 79),
    (QEval: $0015; Mps: 0; NMps: 86; NLps: 80),
    (QEval: $0015; Mps: 1; NMps: 87; NLps: 81),
    (QEval: $0009; Mps: 0; NMps: 88; NLps: 82),
    (QEval: $0009; Mps: 1; NMps: 89; NLps: 83),
    (QEval: $0005; Mps: 0; NMps: 90; NLps: 84),
    (QEval: $0005; Mps: 1; NMps: 91; NLps: 85),
    (QEval: $0001; Mps: 0; NMps: 90; NLps: 86),
    (QEval: $0001; Mps: 1; NMps: 91; NLps: 87),
    (QEval: $5601; Mps: 0; NMps: 92; NLps: 92),
    (QEval: $5601; Mps: 1; NMps: 93; NLps: 93)
  );

implementation

// =========================================================== encoder ====

constructor TMqEnc.Create(AMaxCtxs: Integer; AOut: TMemStream);
begin
  inherited Create;
  FOut := AOut;
  SetLength(FCtxs, AMaxCtxs);
  FCurCtx := 0;
  Init;
  // Initialise per-context info to state 0.
  SetCtxs(nil);
end;

procedure TMqEnc.Init;
begin
  FAReg := $8000;
  FOutBuf := -1;
  FCReg := 0;
  FCTReg := 12;
  FLastByte := -1;
  FErr := False;
end;

procedure TMqEnc.SetCtxs(const ACtxs: TMqCtxArray);
var
  i, n: Integer;
begin
  n := Length(ACtxs);
  if n > Length(FCtxs) then
    n := Length(FCtxs);
  for i := 0 to n - 1 do
    FCtxs[i] := 2 * ACtxs[i].Ind + ACtxs[i].Mps;
  for i := n to Length(FCtxs) - 1 do
    FCtxs[i] := 0;
end;

procedure TMqEnc.SetCurCtx(ACtxNo: Integer);
begin
  FCurCtx := ACtxNo;
end;

procedure TMqEnc.ByteOut2;
begin
  if FOutBuf >= 0 then
    if FOut.PutC(Byte(FOutBuf)) = JP2K_EOF then
      FErr := True;
  FLastByte := FOutBuf;
end;

procedure TMqEnc.ByteOut;
begin
  if FOutBuf <> $ff then
  begin
    if (FCReg and $8000000) <> 0 then
    begin
      Inc(FOutBuf);
      if FOutBuf = $ff then
      begin
        FCReg := FCReg and $7ffffff;
        ByteOut2;
        FOutBuf := (FCReg shr 20) and $ff;
        FCReg := FCReg and $fffff;
        FCTReg := 7;
      end
      else
      begin
        ByteOut2;
        FOutBuf := (FCReg shr 19) and $ff;
        FCReg := FCReg and $7ffff;
        FCTReg := 8;
      end;
    end
    else
    begin
      ByteOut2;
      FOutBuf := (FCReg shr 19) and $ff;
      FCReg := FCReg and $7ffff;
      FCTReg := 8;
    end;
  end
  else
  begin
    ByteOut2;
    FOutBuf := (FCReg shr 20) and $ff;
    FCReg := FCReg and $fffff;
    FCTReg := 7;
  end;
end;

procedure TMqEnc.Renorme;
begin
  repeat
    FAReg := FAReg shl 1;
    FCReg := FCReg shl 1;
    Dec(FCTReg);
    if FCTReg = 0 then
      ByteOut;
  until (FAReg and $8000) <> 0;
end;

procedure TMqEnc.CodeMps2;
var
  st: TMqState;
begin
  st := MqStates[FCtxs[FCurCtx]];
  if FAReg < st.QEval then
    FAReg := st.QEval
  else
    FCReg := FCReg + st.QEval;
  FCtxs[FCurCtx] := st.NMps;
  Renorme;
end;

procedure TMqEnc.CodeLps;
var
  st: TMqState;
begin
  st := MqStates[FCtxs[FCurCtx]];
  FAReg := FAReg - st.QEval;
  if FAReg < st.QEval then
    FCReg := FCReg + st.QEval
  else
    FAReg := st.QEval;
  FCtxs[FCurCtx] := st.NLps;
  Renorme;
end;

procedure TMqEnc.PutBit(Bit: Integer);
var
  st: TMqState;
begin
  st := MqStates[FCtxs[FCurCtx]];
  if st.Mps = Bit then
  begin
    FAReg := FAReg - st.QEval;
    if (FAReg and $8000) = 0 then
      CodeMps2
    else
      FCReg := FCReg + st.QEval;
  end
  else
    CodeLps;
end;

procedure TMqEnc.SetBits;
var
  Tmp: Cardinal;
begin
  Tmp := FCReg + FAReg;
  FCReg := FCReg or $ffff;
  if FCReg >= Tmp then
    FCReg := FCReg - $8000;
end;

function TMqEnc.Flush(TermMode: Integer): Integer;
var
  k: Integer;
begin
  case TermMode of
    JPC_MQENC_PTERM:
      begin
        k := 11 - Integer(FCTReg) + 1;
        while k > 0 do
        begin
          FCReg := FCReg shl FCTReg;
          FCTReg := 0;
          ByteOut;
          k := k - Integer(FCTReg);
        end;
        if FOutBuf <> $ff then
          ByteOut;
      end;
    JPC_MQENC_DEFTERM:
      begin
        SetBits;
        FCReg := FCReg shl FCTReg;
        ByteOut;
        FCReg := FCReg shl FCTReg;
        ByteOut;
        if FOutBuf <> $ff then
          ByteOut;
      end;
  end;
  Result := 0;
end;

// =========================================================== decoder ====

constructor TMqDec.Create(AMaxCtxs: Integer; AIn: TMemStream);
begin
  inherited Create;
  FIn := AIn;
  SetLength(FCtxs, AMaxCtxs);
  FCurCtx := 0;
  if FIn <> nil then
    Init;
  SetCtxs(nil);
end;

procedure TMqDec.SetInput(AIn: TMemStream);
begin
  FIn := AIn;
end;

procedure TMqDec.Init;
var
  c: Integer;
begin
  FEof := False;
  FCReg := 0;
  c := FIn.GetC;
  if c = JP2K_EOF then
  begin
    c := $ff;
    FEof := True;
  end;
  FInBuffer := c;
  FCReg := FCReg + (Cardinal(FInBuffer) shl 16);
  ByteIn;
  FCReg := FCReg shl 7;
  FCTReg := FCTReg - 7;
  FAReg := $8000;
end;

procedure TMqDec.SetCtxs(const ACtxs: TMqCtxArray);
var
  i, n: Integer;
begin
  n := Length(ACtxs);
  if n > Length(FCtxs) then
    n := Length(FCtxs);
  for i := 0 to n - 1 do
    FCtxs[i] := 2 * ACtxs[i].Ind + ACtxs[i].Mps;
  for i := n to Length(FCtxs) - 1 do
    FCtxs[i] := 0;
end;

procedure TMqDec.SetCurCtx(ACtxNo: Integer);
begin
  FCurCtx := ACtxNo;
end;

procedure TMqDec.ByteIn;
var
  c: Integer;
  PrevBuf: Byte;
begin
  if not FEof then
  begin
    c := FIn.GetC;
    if c = JP2K_EOF then
    begin
      FEof := True;
      c := $ff;
    end;
    PrevBuf := FInBuffer;
    FInBuffer := c;
    if PrevBuf = $ff then
    begin
      if c > $8f then
      begin
        FCReg := FCReg + $ff00;
        FCTReg := 8;
      end
      else
      begin
        FCReg := FCReg + (Cardinal(c) shl 9);
        FCTReg := 7;
      end;
    end
    else
    begin
      FCReg := FCReg + (Cardinal(c) shl 8);
      FCTReg := 8;
    end;
  end
  else
  begin
    FCReg := FCReg + $ff00;
    FCTReg := 8;
  end;
end;

procedure TMqDec.Renormd;
begin
  repeat
    if FCTReg = 0 then
      ByteIn;
    FAReg := FAReg shl 1;
    FCReg := FCReg shl 1;
    Dec(FCTReg);
  until (FAReg and $8000) <> 0;
end;

function TMqDec.MpsExchRenormd: Integer;
var
  st: TMqState;
begin
  st := MqStates[FCtxs[FCurCtx]];
  if FAReg < st.QEval then
  begin
    FCtxs[FCurCtx] := st.NLps;
    Result := 1 - st.Mps;
  end
  else
  begin
    FCtxs[FCurCtx] := st.NMps;
    Result := st.Mps;
  end;
  Renormd;
end;

function TMqDec.LpsExchRenormd: Integer;
var
  st: TMqState;
begin
  st := MqStates[FCtxs[FCurCtx]];
  if FAReg >= st.QEval then
  begin
    FAReg := st.QEval;
    FCtxs[FCurCtx] := st.NLps;
    Result := 1 - st.Mps;
  end
  else
  begin
    FAReg := st.QEval;
    FCtxs[FCurCtx] := st.NMps;
    Result := st.Mps;
  end;
  Renormd;
end;

function TMqDec.GetBit: Integer;
var
  st: TMqState;
begin
  st := MqStates[FCtxs[FCurCtx]];
  FAReg := FAReg - st.QEval;
  if FCReg >= (Cardinal(st.QEval) shl 16) then
  begin
    FCReg := FCReg - (Cardinal(st.QEval) shl 16);
    if (FAReg and $8000) <> 0 then
      Result := st.Mps
    else
      Result := MpsExchRenormd;
  end
  else
    Result := LpsExchRenormd;
end;

end.
