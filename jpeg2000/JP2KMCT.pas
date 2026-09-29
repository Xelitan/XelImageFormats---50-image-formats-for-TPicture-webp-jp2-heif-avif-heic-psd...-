// JPEG 2000 based on JASPER 4.2.9
// License: JasPer-2.0 (similar to MIT )
// Author: www.xelitan.com
//
// JP2KMCT - Multiple component (colour) transforms (port of jpc_mct.c).
//
//    RCT  / IRCT : reversible colour transform (integer, used with 5/3).
//    ICT  / IICT : irreversible colour transform (YCbCr, used with 9/7).
//
// The reversible pair operates on integer grids; the irreversible pair on
// floating-point grids (the 9/7 path is inherently lossy).  All three
// component grids must have identical dimensions.

unit JP2KMCT;

{$mode delphi}
{$H+}

interface

uses
  JP2KCommon, JP2KMatrix;

// Forward / inverse reversible colour transform (RGB <-> YUV, integer).
procedure RCT(C0, C1, C2: TIntMatrix);
procedure IRCT(C0, C1, C2: TIntMatrix);

// Forward / inverse irreversible colour transform (RGB <-> YCbCr, float).
procedure ICT(C0, C1, C2: TDblMatrix);
procedure IICT(C0, C1, C2: TDblMatrix);

implementation

procedure RCT(C0, C1, C2: TIntMatrix);
var
  i, n: Integer;
  r, g, b: Integer;
begin
  n := Length(C0.Data);
  for i := 0 to n - 1 do
  begin
    r := C0.Data[i];
    g := C1.Data[i];
    b := C2.Data[i];
    C0.Data[i] := FloorDivPow2(r + (g shl 1) + b, 2);  // Y
    C1.Data[i] := b - g;                                // U
    C2.Data[i] := r - g;                                // V
  end;
end;

procedure IRCT(C0, C1, C2: TIntMatrix);
var
  i, n: Integer;
  r, g, b, y, u, v: Integer;
begin
  n := Length(C0.Data);
  for i := 0 to n - 1 do
  begin
    y := C0.Data[i];
    u := C1.Data[i];
    v := C2.Data[i];
    g := y - FloorDivPow2(u + v, 2);
    r := v + g;
    b := u + g;
    C0.Data[i] := r;
    C1.Data[i] := g;
    C2.Data[i] := b;
  end;
end;

procedure ICT(C0, C1, C2: TDblMatrix);
var
  i, n: Integer;
  r, g, b: Double;
begin
  n := Length(C0.Data);
  for i := 0 to n - 1 do
  begin
    r := C0.Data[i];
    g := C1.Data[i];
    b := C2.Data[i];
    C0.Data[i] :=  0.29900 * r + 0.58700 * g + 0.11400 * b;  // Y
    C1.Data[i] := -0.16875 * r - 0.33126 * g + 0.50000 * b;  // Cb
    C2.Data[i] :=  0.50000 * r - 0.41869 * g - 0.08131 * b;  // Cr
  end;
end;

procedure IICT(C0, C1, C2: TDblMatrix);
var
  i, n: Integer;
  y, u, v: Double;
begin
  n := Length(C0.Data);
  for i := 0 to n - 1 do
  begin
    y := C0.Data[i];
    u := C1.Data[i];
    v := C2.Data[i];
    C0.Data[i] := y + 1.40200 * v;                    // R
    C1.Data[i] := y - 0.34413 * u - 0.71414 * v;      // G
    C2.Data[i] := y + 1.77200 * u;                    // B
  end;
end;

end.
