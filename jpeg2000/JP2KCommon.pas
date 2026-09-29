// JPEG 2000 based on JASPER 4.2.9
// License: JasPer-2.0 (similar to MIT )
// Author: www.xelitan.com
//
// JP2KCommon - Foundation types, math helpers and a memory byte stream.
//
// Derived from the JasPer reference implementation
// (jpc_math.*, jpc_fix.*, jas_stream.*).
//
// This unit provides:
// * basic math helpers (ceil/floor division, log2, first-one bit)
// * a lightweight in-memory byte stream (TMemStream) that mirrors the small
//   subset of jas_stream_t used by the codec (getc/putc/read/write/seek).

unit JP2KCommon;

{$mode delphi}
{$H+}

interface

uses
  SysUtils;

const
  JP2K_EOF = -1;

  // Seek origins (match C SEEK_SET/CUR/END).
  SEEK_SET = 0;
  SEEK_CUR = 1;
  SEEK_END = 2;

type
  EJp2kError = class(Exception);

  TIntArray  = array of Integer;
  TByteArray = array of Byte;

  // In-memory byte stream. Supports both reading (from a supplied buffer) and
  //  writing (growable). Used as the byte backbone for the MQ coder, tier-1,
  //  tier-2 and codestream marker I/O.
  TMemStream = class
  private
    FData: TBytes;     // backing store
    FSize: Integer;    // number of valid bytes
    FPos: Integer;     // current cursor
    procedure EnsureCap(ANeeded: Integer);
  public
    // Create an empty, writable stream.
    constructor Create; overload;
    // Create a stream initialised with a copy of ASize bytes from AData,
    //  positioned at the start; still writable/appendable.
    constructor Create(const AData: TBytes; ASize: Integer); overload;

    // Read/write a single byte. GetC returns JP2K_EOF at end of data.
    function GetC: Integer;
    function PutC(B: Byte): Integer;

    function Read(var Buf; Count: Integer): Integer;
    function Write(const Buf; Count: Integer): Integer;

    procedure Seek(Offset: Integer; Origin: Integer);
    function Tell: Integer;

    // Snapshot of the valid bytes [0..Size-1].
    function ToBytes: TBytes;

    property Size: Integer read FSize;
    property Position: Integer read FPos;
  end;

// Floor of a/b for b>0 (true mathematical floor, unlike Pascal `div`).
function FloorDiv(A, B: Integer): Integer; inline;
// Ceiling of a/b for b>0.
function CeilDiv(A, B: Integer): Integer; inline;
// Floor of a / 2^n (arithmetic right shift).
function FloorDivPow2(A, N: Integer): Integer; inline;
// Ceiling of a / 2^n.
function CeilDivPow2(A, N: Integer): Integer; inline;

// floor(log2(x)) for x>0  (jpc_floorlog2).
function FloorLog2(X: Cardinal): Integer;
// Bit position of the first leading one in x>=0, or -1 if x=0
// (jpc_int_firstone).
function IntFirstOne(X: Integer): Integer;

function MinI(A, B: Integer): Integer; inline;
function MaxI(A, B: Integer): Integer; inline;

implementation

// ------------------------------------------------------------------ math

function FloorDiv(A, B: Integer): Integer;
var
  Q, R: Integer;
begin
  Q := A div B;
  R := A mod B;
  if (R <> 0) and (R < 0) then
    Dec(Q);
  Result := Q;
end;

function CeilDiv(A, B: Integer): Integer;
begin
  Result := FloorDiv(A + B - 1, B);
end;

function FloorDivPow2(A, N: Integer): Integer;
begin
  Result := FloorDiv(A, 1 shl N);
end;

function CeilDivPow2(A, N: Integer): Integer;
begin
  Result := FloorDiv(A + (1 shl N) - 1, 1 shl N);
end;

function FloorLog2(X: Cardinal): Integer;
begin
  Result := 0;
  while X > 1 do
  begin
    X := X shr 1;
    Inc(Result);
  end;
end;

function IntFirstOne(X: Integer): Integer;
begin
  Result := -1;
  while X > 0 do
  begin
    X := X shr 1;
    Inc(Result);
  end;
end;

function MinI(A, B: Integer): Integer;
begin
  if A < B then Result := A else Result := B;
end;

function MaxI(A, B: Integer): Integer;
begin
  if A > B then Result := A else Result := B;
end;

// ------------------------------------------------------------ TMemStream

constructor TMemStream.Create;
begin
  inherited Create;
  FData := nil;
  FSize := 0;
  FPos := 0;
end;

constructor TMemStream.Create(const AData: TBytes; ASize: Integer);
begin
  inherited Create;
  SetLength(FData, ASize);
  if ASize > 0 then
    Move(AData[0], FData[0], ASize);
  FSize := ASize;
  FPos := 0;
end;

procedure TMemStream.EnsureCap(ANeeded: Integer);
var
  NewCap: Integer;
begin
  if ANeeded <= Length(FData) then
    Exit;
  NewCap := Length(FData);
  if NewCap < 64 then
    NewCap := 64;
  while NewCap < ANeeded do
    NewCap := NewCap * 2;
  SetLength(FData, NewCap);
end;

function TMemStream.GetC: Integer;
begin
  if FPos >= FSize then
    Exit(JP2K_EOF);
  Result := FData[FPos];
  Inc(FPos);
end;

function TMemStream.PutC(B: Byte): Integer;
begin
  EnsureCap(FPos + 1);
  FData[FPos] := B;
  Inc(FPos);
  if FPos > FSize then
    FSize := FPos;
  Result := B;
end;

function TMemStream.Read(var Buf; Count: Integer): Integer;
var
  Avail: Integer;
begin
  Avail := FSize - FPos;
  if Count > Avail then
    Count := Avail;
  if Count <= 0 then
    Exit(0);
  Move(FData[FPos], Buf, Count);
  Inc(FPos, Count);
  Result := Count;
end;

function TMemStream.Write(const Buf; Count: Integer): Integer;
begin
  if Count <= 0 then
    Exit(0);
  EnsureCap(FPos + Count);
  Move(Buf, FData[FPos], Count);
  Inc(FPos, Count);
  if FPos > FSize then
    FSize := FPos;
  Result := Count;
end;

procedure TMemStream.Seek(Offset: Integer; Origin: Integer);
begin
  case Origin of
    SEEK_SET: FPos := Offset;
    SEEK_CUR: FPos := FPos + Offset;
    SEEK_END: FPos := FSize + Offset;
  else
    raise EJp2kError.Create('TMemStream.Seek: bad origin');
  end;
  if FPos < 0 then
    FPos := 0;
  if FPos > FSize then
  begin
    EnsureCap(FPos);
    // Growing the cursor past the end zero-fills the gap.
    FillChar(FData[FSize], FPos - FSize, 0);
    FSize := FPos;
  end;
end;

function TMemStream.Tell: Integer;
begin
  Result := FPos;
end;

function TMemStream.ToBytes: TBytes;
begin
  SetLength(Result, FSize);
  if FSize > 0 then
    Move(FData[0], Result[0], FSize);
end;

end.
