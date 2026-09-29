// FLIF - Free Lossless Image Format -- Free Pascal port
// 24-bit binary range coder.
// Corresponds to: src/maniac/rac.hpp, src/maniac/rac_enc.hpp
unit flif_rac;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  flif_io;

const
  RAC_MAX_RANGE_BITS = 24;
  RAC_MIN_RANGE_BITS = 16;
  RAC_MIN_RANGE = Cardinal(1) shl RAC_MIN_RANGE_BITS;
  RAC_BASE_RANGE = Cardinal(1) shl RAC_MAX_RANGE_BITS;

type
  // RacConfig24::chance_12bit_chance -- range is < 2^24, b12 < 2^12.
  // Computed the same way as the 32-bit branch of the reference (which is
  // bit-identical to the 64-bit branch).
  TRacIn = class
  private
    FIO: TFlifIO;
    FRange: Cardinal;
    FLow: Cardinal;
    function ReadCatchEOF: Cardinal; inline;
    procedure Input; inline;
    function Get(Chance: Cardinal): Boolean; inline;
  public
    constructor Create(AIO: TFlifIO);
    function Read12BitChance(B12: Word): Boolean; inline;
    function ReadBit: Boolean; inline;
  end;

  // Abstract output range coder so that the "dummy" coder used by the
  // tree-learning pass can be plugged in without templates.
  TRacOut = class
  public
    procedure Write12BitChance(B12: Word; Bit: Boolean); virtual; abstract;
    procedure WriteBit(Bit: Boolean); virtual; abstract;
    procedure Flush; virtual; abstract;
  end;

  TRacOut24 = class(TRacOut)
  private
    FIO: TFlifIO;
    FRange: Cardinal;
    FLow: Cardinal;
    FDelayedByte: Integer;
    FDelayedCount: Integer;
    procedure Output;
    procedure Put(Chance: Cardinal; Bit: Boolean); inline;
  public
    constructor Create(AIO: TFlifIO);
    procedure Write12BitChance(B12: Word; Bit: Boolean); override;
    procedure WriteBit(Bit: Boolean); override;
    procedure Flush; override;
  end;

  TRacDummy = class(TRacOut)
  public
    procedure Write12BitChance(B12: Word; Bit: Boolean); override;
    procedure WriteBit(Bit: Boolean); override;
    procedure Flush; override;
  end;

function Chance12BitChance(B12: Cardinal; Range: Cardinal): Cardinal; inline;

implementation

function Chance12BitChance(B12: Cardinal; Range: Cardinal): Cardinal;
begin
  Result := (((Range and $FFF) * B12 + $800) shr 12) + ((Range shr 12) * B12);
end;

// TRacIn

constructor TRacIn.Create(AIO: TFlifIO);
var
  R: Cardinal;
begin
  inherited Create;
  FIO := AIO;
  FRange := RAC_BASE_RANGE;
  FLow := 0;
  R := RAC_BASE_RANGE;
  while R > 1 do
  begin
    FLow := FLow shl 8;
    FLow := FLow or ReadCatchEOF;
    R := R shr 8;
  end;
end;

function TRacIn.ReadCatchEOF: Cardinal;
begin
  // no reason to branch here to catch end-of-stream: returning garbage on a
  // premature EOS is exactly what the reference does
  Result := Cardinal(FIO.GetC);
end;

procedure TRacIn.Input;
begin
  if FRange <= RAC_MIN_RANGE then
  begin
    FLow := FLow shl 8;
    FRange := FRange shl 8;
    FLow := FLow or ReadCatchEOF;
  end;
  if FRange <= RAC_MIN_RANGE then
  begin
    FLow := FLow shl 8;
    FRange := FRange shl 8;
    FLow := FLow or ReadCatchEOF;
  end;
end;

function TRacIn.Get(Chance: Cardinal): Boolean;
begin
  if FLow >= FRange - Chance then
  begin
    FLow := FLow - (FRange - Chance);
    FRange := Chance;
    Input;
    Result := True;
  end
  else
  begin
    FRange := FRange - Chance;
    Input;
    Result := False;
  end;
end;

function TRacIn.Read12BitChance(B12: Word): Boolean;
begin
  Result := Get(Chance12BitChance(B12, FRange));
end;

function TRacIn.ReadBit: Boolean;
begin
  Result := Get(FRange shr 1);
end;

// TRacOut24

constructor TRacOut24.Create(AIO: TFlifIO);
begin
  inherited Create;
  FIO := AIO;
  FRange := RAC_BASE_RANGE;
  FLow := 0;
  FDelayedByte := -1;
  FDelayedCount := 0;
end;

procedure TRacOut24.Output;
var
  B: Integer;
begin
  while FRange <= RAC_MIN_RANGE do
  begin
    B := Integer(FLow shr RAC_MIN_RANGE_BITS);
    if FDelayedByte < 0 then
      FDelayedByte := B
    else if ((FLow + FRange) shr 8) < RAC_MIN_RANGE then
    begin
      FIO.FPutC(FDelayedByte);
      while FDelayedCount > 0 do
      begin
        FIO.FPutC($FF);
        Dec(FDelayedCount);
      end;
      FDelayedByte := B;
    end
    else if (FLow shr 8) >= RAC_MIN_RANGE then
    begin
      FIO.FPutC(FDelayedByte + 1);
      while FDelayedCount > 0 do
      begin
        FIO.FPutC(0);
        Dec(FDelayedCount);
      end;
      FDelayedByte := B and $FF;
    end
    else
      Inc(FDelayedCount);
    FLow := (FLow and (RAC_MIN_RANGE - 1)) shl 8;
    FRange := FRange shl 8;
  end;
end;

procedure TRacOut24.Put(Chance: Cardinal; Bit: Boolean);
begin
  if Bit then
  begin
    FLow := FLow + (FRange - Chance);
    FRange := Chance;
  end
  else
    FRange := FRange - Chance;
  Output;
end;

procedure TRacOut24.Write12BitChance(B12: Word; Bit: Boolean);
begin
  Put(Chance12BitChance(B12, FRange), Bit);
end;

procedure TRacOut24.WriteBit(Bit: Boolean);
begin
  Put(FRange shr 1, Bit);
end;

procedure TRacOut24.Flush;
begin
  FLow := FLow + (RAC_MIN_RANGE - 1);
  FRange := RAC_MIN_RANGE - 1; Output;
  FRange := RAC_MIN_RANGE - 1; Output;
  FRange := RAC_MIN_RANGE - 1; Output;
  FRange := RAC_MIN_RANGE - 1; Output;
  FIO.Flush;
end;

// TRacDummy

procedure TRacDummy.Write12BitChance(B12: Word; Bit: Boolean);
begin
end;

procedure TRacDummy.WriteBit(Bit: Boolean);
begin
end;

procedure TRacDummy.Flush;
begin
end;

end.
