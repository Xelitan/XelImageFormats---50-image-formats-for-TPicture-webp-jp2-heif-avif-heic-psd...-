// JPEG 2000 based on JASPER 4.2.9
// License: JasPer-2.0 (similar to MIT )
// Author: www.xelitan.com
//
// JP2KMatrix - simple 2D sample grids (analogue of jas_matrix_t).
//
// TIntMatrix is used for the reversible (lossless 5/3) data path and for
// tier-1, which always operates on integer sample magnitudes.
// TDblMatrix is used for the irreversible (lossy 9/7) data path before
// quantisation to integers.

unit JP2KMatrix;

{$mode delphi}
{$H+}

interface

uses
  JP2KCommon;

type
  TIntMatrix = class
  public
    Rows, Cols: Integer;
    Data: TIntArray;          // row-major, length Rows*Cols
    constructor Create(ARows, ACols: Integer);
    function Get(R, C: Integer): Integer; inline;
    procedure SetVal(R, C, V: Integer); inline;
    function Idx(R, C: Integer): Integer; inline;
    procedure Clear;
  end;

  TDblMatrix = class
  public
    Rows, Cols: Integer;
    Data: array of Double;    // row-major
    constructor Create(ARows, ACols: Integer);
    function Get(R, C: Integer): Double; inline;
    procedure SetVal(R, C: Integer; V: Double); inline;
    function Idx(R, C: Integer): Integer; inline;
    procedure Clear;
  end;

implementation

constructor TIntMatrix.Create(ARows, ACols: Integer);
begin
  inherited Create;
  Rows := ARows;
  Cols := ACols;
  SetLength(Data, ARows * ACols);
end;

function TIntMatrix.Idx(R, C: Integer): Integer;
begin
  Result := R * Cols + C;
end;

function TIntMatrix.Get(R, C: Integer): Integer;
begin
  Result := Data[R * Cols + C];
end;

procedure TIntMatrix.SetVal(R, C, V: Integer);
begin
  Data[R * Cols + C] := V;
end;

procedure TIntMatrix.Clear;
var
  i: Integer;
begin
  for i := 0 to Length(Data) - 1 do
    Data[i] := 0;
end;

constructor TDblMatrix.Create(ARows, ACols: Integer);
begin
  inherited Create;
  Rows := ARows;
  Cols := ACols;
  SetLength(Data, ARows * ACols);
end;

function TDblMatrix.Idx(R, C: Integer): Integer;
begin
  Result := R * Cols + C;
end;

function TDblMatrix.Get(R, C: Integer): Double;
begin
  Result := Data[R * Cols + C];
end;

procedure TDblMatrix.SetVal(R, C: Integer; V: Double);
begin
  Data[R * Cols + C] := V;
end;

procedure TDblMatrix.Clear;
var
  i: Integer;
begin
  for i := 0 to Length(Data) - 1 do
    Data[i] := 0;
end;

end.
