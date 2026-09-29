// JPEG 2000 based on JASPER 4.2.9
// License: JasPer-2.0 (similar to MIT )
// Author: www.xelitan.com
//
// JP2KBS - Bit stream with bit stuffing (port of jpc_bs.c).
//
// This is the raw bit stream used for JPEG 2000 packet headers and tag trees.
// It performs the mandatory bit stuffing: after a 0xFF byte only 7 bits are
// packed into the following byte (a stuffed 0 in the MSB position)

unit JP2KBS;

{$mode delphi}
{$H+}
{$Q-}
{$R-}

interface

uses
  JP2KCommon;

const
  JPC_BITSTREAM_NOCLOSE = $01;
  JPC_BITSTREAM_EOF     = $02;
  JPC_BITSTREAM_ERR     = $04;

  BS_MODE_READ  = $01;
  BS_MODE_WRITE = $02;

type
  TBitStream = class
  private
    FFlags: Integer;
    FBuf: Cardinal;     // input/output buffer (16 bits used)
    FCnt: Integer;      // bits remaining in the byte being read/written
    FStream: TMemStream;
    FOpenMode: Integer;
    function FillBuf: Integer;
    function GetEofFlag: Boolean;
  public
    // Open a bit stream over a byte stream. AWrite selects write vs read.
    constructor Create(AStream: TMemStream; AWrite: Boolean);

    function GetBit: Integer;
    function PutBit(B: Integer): Integer;
    function GetBits(N: Integer): Integer;
    function PutBits(N: Integer; V: Integer): Integer;

    function Align: Integer;
    function InAlign(FillMask, FillData: Integer): Integer;
    function OutAlign(FillData: Integer): Integer;
    function NeedAlign: Integer;
    function Pending: Integer;

    // Flush (align) and detach. Does not free the underlying stream.
    function CloseBs: Integer;

    property EofReached: Boolean read GetEofFlag;
  end;

implementation

constructor TBitStream.Create(AStream: TMemStream; AWrite: Boolean);
begin
  inherited Create;
  FFlags := JPC_BITSTREAM_NOCLOSE;
  FStream := AStream;
  if AWrite then
    FOpenMode := BS_MODE_WRITE
  else
    FOpenMode := BS_MODE_READ;
  if FOpenMode = BS_MODE_READ then
    FCnt := 0
  else
    FCnt := 8;
  FBuf := 0;
end;

function TBitStream.GetEofFlag: Boolean;
begin
  Result := (FFlags and JPC_BITSTREAM_EOF) <> 0;
end;

function TBitStream.FillBuf: Integer;
var
  c: Integer;
begin
  if (FFlags and JPC_BITSTREAM_ERR) <> 0 then
  begin
    FCnt := 0;
    Exit(-1);
  end;
  if (FFlags and JPC_BITSTREAM_EOF) <> 0 then
  begin
    FBuf := $7f;
    FCnt := 7;
    Exit(1);
  end;
  FBuf := (FBuf shl 8) and $ffff;
  c := FStream.GetC;
  if c = JP2K_EOF then
  begin
    FFlags := FFlags or JPC_BITSTREAM_EOF;
    Exit(1);
  end;
  if FBuf = $ff00 then FCnt := 6 else FCnt := 7;
  FBuf := FBuf or (Cardinal(c) and ((Cardinal(1) shl (FCnt + 1)) - 1));
  Result := (FBuf shr FCnt) and 1;
end;

function TBitStream.GetBit: Integer;
begin
  Dec(FCnt);
  if FCnt >= 0 then
    Result := (FBuf shr FCnt) and 1
  else
    Result := FillBuf;
end;

function TBitStream.PutBit(B: Integer): Integer;
begin
  Dec(FCnt);
  if FCnt < 0 then
  begin
    FBuf := (FBuf shl 8) and $ffff;
    if FBuf = $ff00 then FCnt := 6 else FCnt := 7;
    FBuf := FBuf or (Cardinal(B and 1) shl FCnt);
    if FStream.PutC((FBuf shr 8) and $ff) = JP2K_EOF then
      Result := JP2K_EOF
    else
      Result := B and 1;
  end
  else
  begin
    FBuf := FBuf or (Cardinal(B and 1) shl FCnt);
    Result := B and 1;
  end;
end;

function TBitStream.GetBits(N: Integer): Integer;
var
  v, u: Integer;
begin
  if (N < 0) or (N >= 32) then
    Exit(-1);
  v := 0;
  while N > 0 do
  begin
    Dec(N);
    u := GetBit;
    if u < 0 then
      Exit(-1);
    v := (v shl 1) or u;
  end;
  Result := v;
end;

function TBitStream.PutBits(N: Integer; V: Integer): Integer;
var
  m: Integer;
begin
  if (N < 0) or (N >= 32) then
    Exit(JP2K_EOF);
  m := N - 1;
  while N > 0 do
  begin
    Dec(N);
    if PutBit((V shr m) and 1) = JP2K_EOF then
      Exit(JP2K_EOF);
    V := V shl 1;
  end;
  Result := 0;
end;

function TBitStream.NeedAlign: Integer;
begin
  if (FOpenMode and BS_MODE_READ) <> 0 then
  begin
    if ((FCnt < 8) and (FCnt > 0)) or (((FBuf shr 8) and $ff) = $ff) then
      Exit(1);
  end
  else if (FOpenMode and BS_MODE_WRITE) <> 0 then
  begin
    if ((FCnt < 8) and (FCnt >= 0)) or (((FBuf shr 8) and $ff) = $ff) then
      Exit(1);
  end
  else
    Exit(-1);
  Result := 0;
end;

function TBitStream.Pending: Integer;
begin
  if (FOpenMode and BS_MODE_WRITE) <> 0 then
  begin
    if FCnt < 8 then
      Exit(1);
    Result := 0;
  end
  else
    Result := -1;
end;

function TBitStream.Align: Integer;
begin
  if (FOpenMode and BS_MODE_READ) <> 0 then
    Result := InAlign(0, 0)
  else
    Result := OutAlign(0);
end;

function TBitStream.InAlign(FillMask, FillData: Integer): Integer;
var
  n, v, u, numfill, m: Integer;
begin
  numfill := 7;
  m := 0;
  v := 0;
  if FCnt > 0 then
    n := FCnt
  else if FCnt = 0 then
  begin
    if (FBuf and $ff) = $ff then n := 7 else n := 0;
  end
  else
    n := 0;
  if n > 0 then
  begin
    u := GetBits(n);
    if u < 0 then Exit(-1);
    m := m + n;
    v := (v shl n) or u;
  end;
  if (FBuf and $ff) = $ff then
  begin
    u := GetBits(7);
    if u < 0 then Exit(-1);
    v := (v shl 7) or u;
    m := m + 7;
  end;
  if m > numfill then
    v := v shr (m - numfill)
  else
  begin
    FillData := FillData shr (numfill - m);
    FillMask := FillMask shr (numfill - m);
  end;
  if ((not (v xor FillData)) and FillMask) <> FillMask then
    Exit(1);
  Result := 0;
end;

function TBitStream.OutAlign(FillData: Integer): Integer;
var
  n, v: Integer;
begin
  if FCnt = 0 then
  begin
    if (FBuf and $ff) = $ff then
    begin
      n := 7;
      v := FillData;
    end
    else
    begin
      n := 0;
      v := 0;
    end;
  end
  else if (FCnt > 0) and (FCnt < 8) then
  begin
    n := FCnt;
    v := FillData shr (7 - n);
  end
  else
  begin
    Exit(0);
  end;

  if n > 0 then
    if PutBits(n, v) <> 0 then
      Exit(-1);

  if FCnt < 8 then
  begin
    if FStream.PutC(FBuf and $ff) = JP2K_EOF then
      Exit(-1);
    FCnt := 8;
    FBuf := (FBuf shl 8) and $ffff;
  end;
  Result := 0;
end;

function TBitStream.CloseBs: Integer;
begin
  Result := 0;
  if Align <> 0 then
    Result := -1;
end;

end.
