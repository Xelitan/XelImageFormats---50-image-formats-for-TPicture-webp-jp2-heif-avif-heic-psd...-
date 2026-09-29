// JPEG 2000 based on JASPER 4.2.9
// License: JasPer-2.0 (similar to MIT )
// Author: www.xelitan.com
//
// JP2KWavelet - discrete wavelet transforms.
//
//    5/3 reversible (integer) - lossless path, matches ISO 15444-1 Annex F.
//    9/7 irreversible (float) - lossy path, Daubechies 9/7 lifting.
//
// Both are implemented as in-place lifting on a strided 1-D line, applied
// separably (rows then columns) and recursively on the LL quadrant to give a
// multi-level Mallat decomposition.  After each 1-D pass the coefficients are
// de-interleaved so that the low-pass band occupies the first half of the line
// (the standard subband layout).
//
// The forward/inverse pairs are exact mathematical inverses, so the 5/3 path
// round-trips losslessly and the 9/7 path round-trips to within floating-point
// precision.  Whole-sample symmetric extension is used at the boundaries.

unit JP2KWavelet;

{$mode delphi}
{$H+}

interface

uses
  JP2KCommon, JP2KMatrix;

// Multi-level 2-D transforms over a whole matrix (NumLevels resolution
// reductions).
procedure Fwd53(M: TIntMatrix; NumLevels: Integer);
procedure Inv53(M: TIntMatrix; NumLevels: Integer);
procedure Fwd97(M: TDblMatrix; NumLevels: Integer);
procedure Inv97(M: TDblMatrix; NumLevels: Integer);

// Origin/parity-aware inverse transforms (for tiles whose component coordinate
// origin is not the multiple of 2^level that the origin-0 versions assume).
// OX/OY are the tile-component's coordinate origin. These reduce *exactly* to
// Inv53/Inv97 when OX=OY=0.
procedure Inv53Org(M: TIntMatrix; NumLevels, OX, OY: Integer);
procedure Inv97Org(M: TDblMatrix; NumLevels, OX, OY: Integer);

implementation

const
  A97 = -1.586134342059924;
  B97 = -0.052980118572961;
  G97 =  0.882911075530934;
  D97 =  0.443506852043971;
  // JasPer's exact low-/high-pass gains (jpc_qmfb.c, WT_DOSCALE). Analysis
  // multiplies low by LGAIN and high by HGAIN; synthesis by the reciprocals.
  // Using these exact values makes the 9/7 transform match JasPer.
  LGAIN = 1.0 / 1.23017410558578;
  HGAIN = 1.0 / 1.62578613134411;

// Reflect index p into [0, n-1] using whole-sample symmetric extension
// (mirror about the endpoints, endpoints not duplicated).
function Reflect(p, n: Integer): Integer; inline;
var
  period: Integer;
begin
  if n = 1 then
    Exit(0);
  period := 2 * (n - 1);
  if p < 0 then p := -p;
  p := p mod period;
  if p >= n then
    p := period - p;
  Result := p;
end;

// ===================================================== 5/3 integer ======

procedure Fwd53Line(var D: TIntArray; Off, Stride, N: Integer);
var
  i: Integer;
  function GV(p: Integer): Integer; inline;
  begin
    Result := D[Off + Reflect(p, N) * Stride];
  end;
begin
  if N = 1 then Exit;
  // Predict (high/odd): d[i] -= floor((d[i-1]+d[i+1])/2).
  i := 1;
  while i < N do
  begin
    D[Off + i * Stride] := D[Off + i * Stride] - FloorDivPow2(GV(i - 1) + GV(i + 1), 1);
    Inc(i, 2);
  end;
  // Update (low/even): d[i] += floor((d[i-1]+d[i+1]+2)/4).
  i := 0;
  while i < N do
  begin
    D[Off + i * Stride] := D[Off + i * Stride] + FloorDivPow2(GV(i - 1) + GV(i + 1) + 2, 2);
    Inc(i, 2);
  end;
end;

procedure Inv53Line(var D: TIntArray; Off, Stride, N: Integer);
var
  i: Integer;
  function GV(p: Integer): Integer; inline;
  begin
    Result := D[Off + Reflect(p, N) * Stride];
  end;
begin
  if N = 1 then Exit;
  // Undo update (even).
  i := 0;
  while i < N do
  begin
    D[Off + i * Stride] := D[Off + i * Stride] - FloorDivPow2(GV(i - 1) + GV(i + 1) + 2, 2);
    Inc(i, 2);
  end;
  // Undo predict (odd).
  i := 1;
  while i < N do
  begin
    D[Off + i * Stride] := D[Off + i * Stride] + FloorDivPow2(GV(i - 1) + GV(i + 1), 1);
    Inc(i, 2);
  end;
end;

// Move low-pass (even) samples to the front, high-pass (odd) to the back.
procedure DeinterleaveI(var D: TIntArray; Off, Stride, N: Integer);
var
  tmp: TIntArray;
  i, lo, hi: Integer;
begin
  SetLength(tmp, N);
  lo := 0; hi := (N + 1) div 2;
  for i := 0 to N - 1 do
    if (i and 1) = 0 then begin tmp[lo] := D[Off + i * Stride]; Inc(lo); end
    else begin tmp[hi] := D[Off + i * Stride]; Inc(hi); end;
  for i := 0 to N - 1 do
    D[Off + i * Stride] := tmp[i];
end;

procedure InterleaveI(var D: TIntArray; Off, Stride, N: Integer);
var
  tmp: TIntArray;
  i, lo, hi: Integer;
begin
  SetLength(tmp, N);
  lo := 0; hi := (N + 1) div 2;
  for i := 0 to N - 1 do
    if (i and 1) = 0 then begin tmp[i] := D[Off + lo * Stride]; Inc(lo); end
    else begin tmp[i] := D[Off + hi * Stride]; Inc(hi); end;
  for i := 0 to N - 1 do
    D[Off + i * Stride] := tmp[i];
end;

procedure Fwd53(M: TIntMatrix; NumLevels: Integer);
var
  lvl, w, h, r, c: Integer;
begin
  w := M.Cols; h := M.Rows;
  for lvl := 0 to NumLevels - 1 do
  begin
    if (w <= 1) and (h <= 1) then Break;
    for c := 0 to w - 1 do            // columns first (matches JasPer)
      if h > 1 then
      begin
        Fwd53Line(M.Data, c, M.Cols, h);
        DeinterleaveI(M.Data, c, M.Cols, h);
      end;
    for r := 0 to h - 1 do            // then rows
      if w > 1 then
      begin
        Fwd53Line(M.Data, r * M.Cols, 1, w);
        DeinterleaveI(M.Data, r * M.Cols, 1, w);
      end;
    w := (w + 1) div 2;
    h := (h + 1) div 2;
  end;
end;

procedure Inv53(M: TIntMatrix; NumLevels: Integer);
var
  ws, hs: array of Integer;
  lvl, w, h, r, c, n: Integer;
begin
  // Recompute the band dimensions for each level (forward order).
  SetLength(ws, NumLevels + 1);
  SetLength(hs, NumLevels + 1);
  w := M.Cols; h := M.Rows;
  n := 0;
  ws[0] := w; hs[0] := h;
  for lvl := 0 to NumLevels - 1 do
  begin
    if (w <= 1) and (h <= 1) then Break;
    w := (w + 1) div 2; h := (h + 1) div 2;
    Inc(n);
    ws[n] := w; hs[n] := h;
  end;
  // Inverse in reverse level order.
  for lvl := n - 1 downto 0 do
  begin
    w := ws[lvl]; h := hs[lvl];
    for r := 0 to h - 1 do            // rows first
      if w > 1 then
      begin
        InterleaveI(M.Data, r * M.Cols, 1, w);
        Inv53Line(M.Data, r * M.Cols, 1, w);
      end;
    for c := 0 to w - 1 do            // then columns
      if h > 1 then
      begin
        InterleaveI(M.Data, c, M.Cols, h);
        Inv53Line(M.Data, c, M.Cols, h);
      end;
  end;
end;

// ===================================================== 9/7 float =======

procedure Fwd97Line(var D: array of Double; Off, Stride, N: Integer);
var
  i: Integer;
  function GV(p: Integer): Double; inline;
  begin
    Result := D[Off + Reflect(p, N) * Stride];
  end;
begin
  if N = 1 then
  begin
    D[Off] := D[Off];  // single sample: only scaling below would apply
  end;
  if N > 1 then
  begin
    i := 1;
    while i < N do
    begin
      D[Off + i * Stride] := D[Off + i * Stride] + A97 * (GV(i - 1) + GV(i + 1));
      Inc(i, 2);
    end;
    i := 0;
    while i < N do
    begin
      D[Off + i * Stride] := D[Off + i * Stride] + B97 * (GV(i - 1) + GV(i + 1));
      Inc(i, 2);
    end;
    i := 1;
    while i < N do
    begin
      D[Off + i * Stride] := D[Off + i * Stride] + G97 * (GV(i - 1) + GV(i + 1));
      Inc(i, 2);
    end;
    i := 0;
    while i < N do
    begin
      D[Off + i * Stride] := D[Off + i * Stride] + D97 * (GV(i - 1) + GV(i + 1));
      Inc(i, 2);
    end;
  end;
  // Scaling: low (even) *= LGAIN, high (odd) *= HGAIN (matches JasPer).
  i := 0;
  while i < N do
  begin
    D[Off + i * Stride] := D[Off + i * Stride] * LGAIN;
    Inc(i, 2);
  end;
  i := 1;
  while i < N do
  begin
    D[Off + i * Stride] := D[Off + i * Stride] * HGAIN;
    Inc(i, 2);
  end;
end;

procedure Inv97Line(var D: array of Double; Off, Stride, N: Integer);
var
  i: Integer;
  function GV(p: Integer): Double; inline;
  begin
    Result := D[Off + Reflect(p, N) * Stride];
  end;
begin
  // Undo scaling: low (even) /= LGAIN, high (odd) /= HGAIN (matches JasPer).
  i := 0;
  while i < N do
  begin
    D[Off + i * Stride] := D[Off + i * Stride] / LGAIN;
    Inc(i, 2);
  end;
  i := 1;
  while i < N do
  begin
    D[Off + i * Stride] := D[Off + i * Stride] / HGAIN;
    Inc(i, 2);
  end;
  if N > 1 then
  begin
    i := 0;
    while i < N do
    begin
      D[Off + i * Stride] := D[Off + i * Stride] - D97 * (GV(i - 1) + GV(i + 1));
      Inc(i, 2);
    end;
    i := 1;
    while i < N do
    begin
      D[Off + i * Stride] := D[Off + i * Stride] - G97 * (GV(i - 1) + GV(i + 1));
      Inc(i, 2);
    end;
    i := 0;
    while i < N do
    begin
      D[Off + i * Stride] := D[Off + i * Stride] - B97 * (GV(i - 1) + GV(i + 1));
      Inc(i, 2);
    end;
    i := 1;
    while i < N do
    begin
      D[Off + i * Stride] := D[Off + i * Stride] - A97 * (GV(i - 1) + GV(i + 1));
      Inc(i, 2);
    end;
  end;
end;

procedure DeinterleaveD(var D: array of Double; Off, Stride, N: Integer);
var
  tmp: array of Double;
  i, lo, hi: Integer;
begin
  SetLength(tmp, N);
  lo := 0; hi := (N + 1) div 2;
  for i := 0 to N - 1 do
    if (i and 1) = 0 then begin tmp[lo] := D[Off + i * Stride]; Inc(lo); end
    else begin tmp[hi] := D[Off + i * Stride]; Inc(hi); end;
  for i := 0 to N - 1 do
    D[Off + i * Stride] := tmp[i];
end;

procedure InterleaveD(var D: array of Double; Off, Stride, N: Integer);
var
  tmp: array of Double;
  i, lo, hi: Integer;
begin
  SetLength(tmp, N);
  lo := 0; hi := (N + 1) div 2;
  for i := 0 to N - 1 do
    if (i and 1) = 0 then begin tmp[i] := D[Off + lo * Stride]; Inc(lo); end
    else begin tmp[i] := D[Off + hi * Stride]; Inc(hi); end;
  for i := 0 to N - 1 do
    D[Off + i * Stride] := tmp[i];
end;

procedure Fwd97(M: TDblMatrix; NumLevels: Integer);
var
  lvl, w, h, r, c: Integer;
begin
  w := M.Cols; h := M.Rows;
  for lvl := 0 to NumLevels - 1 do
  begin
    if (w <= 1) and (h <= 1) then Break;
    for c := 0 to w - 1 do            // columns first (matches JasPer)
      if h > 1 then
      begin
        Fwd97Line(M.Data, c, M.Cols, h);
        DeinterleaveD(M.Data, c, M.Cols, h);
      end;
    for r := 0 to h - 1 do            // then rows
      if w > 1 then
      begin
        Fwd97Line(M.Data, r * M.Cols, 1, w);
        DeinterleaveD(M.Data, r * M.Cols, 1, w);
      end;
    w := (w + 1) div 2;
    h := (h + 1) div 2;
  end;
end;

procedure Inv97(M: TDblMatrix; NumLevels: Integer);
var
  ws, hs: array of Integer;
  lvl, w, h, r, c, n: Integer;
begin
  SetLength(ws, NumLevels + 1);
  SetLength(hs, NumLevels + 1);
  w := M.Cols; h := M.Rows;
  n := 0;
  ws[0] := w; hs[0] := h;
  for lvl := 0 to NumLevels - 1 do
  begin
    if (w <= 1) and (h <= 1) then Break;
    w := (w + 1) div 2; h := (h + 1) div 2;
    Inc(n);
    ws[n] := w; hs[n] := h;
  end;
  for lvl := n - 1 downto 0 do
  begin
    w := ws[lvl]; h := hs[lvl];
    for r := 0 to h - 1 do            // rows first (matches JasPer)
      if w > 1 then
      begin
        InterleaveD(M.Data, r * M.Cols, 1, w);
        Inv97Line(M.Data, r * M.Cols, 1, w);
      end;
    for c := 0 to w - 1 do            // then columns
      if h > 1 then
      begin
        InterleaveD(M.Data, c, M.Cols, h);
        Inv97Line(M.Data, c, M.Cols, h);
      end;
  end;
end;

// ===================================== origin/parity-aware inverse ======

// Interleave deinterleaved (low half | high half) -> natural order, where a
// natural index i is a low-pass sample iff (i mod 2) = P.
procedure InterleaveIP(var D: TIntArray; Off, Stride, N, P: Integer);
var
  tmp: TIntArray;
  i, lo, hi, nlow: Integer;
begin
  SetLength(tmp, N);
  nlow := (N + 1 - P) div 2;
  lo := 0; hi := nlow;
  for i := 0 to N - 1 do
    if (i mod 2) = P then begin tmp[i] := D[Off + lo * Stride]; Inc(lo); end
    else begin tmp[i] := D[Off + hi * Stride]; Inc(hi); end;
  for i := 0 to N - 1 do D[Off + i * Stride] := tmp[i];
end;

procedure InterleaveDP(var D: array of Double; Off, Stride, N, P: Integer);
var
  tmp: array of Double;
  i, lo, hi, nlow: Integer;
begin
  SetLength(tmp, N);
  nlow := (N + 1 - P) div 2;
  lo := 0; hi := nlow;
  for i := 0 to N - 1 do
    if (i mod 2) = P then begin tmp[i] := D[Off + lo * Stride]; Inc(lo); end
    else begin tmp[i] := D[Off + hi * Stride]; Inc(hi); end;
  for i := 0 to N - 1 do D[Off + i * Stride] := tmp[i];
end;

// Inverse 5/3 lifting on natural-order data; low samples at i mod 2 = P.
procedure Inv53LineP(var D: TIntArray; Off, Stride, N, P: Integer);
var
  i: Integer;
  function GV(p2: Integer): Integer; inline;
  begin Result := D[Off + Reflect(p2, N) * Stride]; end;
begin
  if N <= 1 then
  begin
    // single sample: a lone high-pass coefficient (parity 1) is halved
    // (jpc_ft_invlift_row, numcols=1 case); a low/LL sample passes through.
    if (N = 1) and (P = 1) then D[Off] := FloorDivPow2(D[Off], 1);
    Exit;
  end;
  i := P;                 // undo update on low
  while i < N do
  begin
    D[Off + i * Stride] := D[Off + i * Stride] - FloorDivPow2(GV(i - 1) + GV(i + 1) + 2, 2);
    Inc(i, 2);
  end;
  i := 1 - P;             // undo predict on high
  while i < N do
  begin
    D[Off + i * Stride] := D[Off + i * Stride] + FloorDivPow2(GV(i - 1) + GV(i + 1), 1);
    Inc(i, 2);
  end;
end;

procedure Inv97LineP(var D: array of Double; Off, Stride, N, P: Integer);
var
  i: Integer;
  function GV(p2: Integer): Double; inline;
  begin Result := D[Off + Reflect(p2, N) * Stride]; end;
begin
  if N <= 1 then Exit;   // 9/7: single sample passes through (no scaling)
  // undo scaling
  i := P;
  while i < N do begin D[Off + i * Stride] := D[Off + i * Stride] / LGAIN; Inc(i, 2); end;
  i := 1 - P;
  while i < N do begin D[Off + i * Stride] := D[Off + i * Stride] / HGAIN; Inc(i, 2); end;
  if N > 1 then
  begin
    i := P;                                  // undo update (delta) on low
    while i < N do begin D[Off + i * Stride] := D[Off + i * Stride] - D97 * (GV(i - 1) + GV(i + 1)); Inc(i, 2); end;
    i := 1 - P;                              // undo predict (gamma) on high
    while i < N do begin D[Off + i * Stride] := D[Off + i * Stride] - G97 * (GV(i - 1) + GV(i + 1)); Inc(i, 2); end;
    i := P;                                  // undo update (beta) on low
    while i < N do begin D[Off + i * Stride] := D[Off + i * Stride] - B97 * (GV(i - 1) + GV(i + 1)); Inc(i, 2); end;
    i := 1 - P;                              // undo predict (alpha) on high
    while i < N do begin D[Off + i * Stride] := D[Off + i * Stride] - A97 * (GV(i - 1) + GV(i + 1)); Inc(i, 2); end;
  end;
end;

procedure Inv53Org(M: TIntMatrix; NumLevels, OX, OY: Integer);
var
  ws, hs, px, py: array of Integer;
  lvl, w, h, r, c, cols: Integer;
begin
  cols := M.Cols;
  SetLength(ws, NumLevels + 1); SetLength(hs, NumLevels + 1);
  SetLength(px, NumLevels + 1); SetLength(py, NumLevels + 1);
  for lvl := 0 to NumLevels do
  begin
    ws[lvl] := CeilDivPow2(OX + M.Cols, lvl) - CeilDivPow2(OX, lvl);
    hs[lvl] := CeilDivPow2(OY + M.Rows, lvl) - CeilDivPow2(OY, lvl);
    px[lvl] := CeilDivPow2(OX, lvl) and 1;
    py[lvl] := CeilDivPow2(OY, lvl) and 1;
  end;
  for lvl := NumLevels - 1 downto 0 do
  begin
    w := ws[lvl]; h := hs[lvl];
    for r := 0 to h - 1 do
    begin
      if w > 1 then InterleaveIP(M.Data, r * cols, 1, w, px[lvl]);
      Inv53LineP(M.Data, r * cols, 1, w, px[lvl]);   // handles w=1 (parity halving)
    end;
    for c := 0 to w - 1 do
    begin
      if h > 1 then InterleaveIP(M.Data, c, cols, h, py[lvl]);
      Inv53LineP(M.Data, c, cols, h, py[lvl]);
    end;
  end;
end;

procedure Inv97Org(M: TDblMatrix; NumLevels, OX, OY: Integer);
var
  ws, hs, px, py: array of Integer;
  lvl, w, h, r, c, cols: Integer;
begin
  cols := M.Cols;
  SetLength(ws, NumLevels + 1); SetLength(hs, NumLevels + 1);
  SetLength(px, NumLevels + 1); SetLength(py, NumLevels + 1);
  for lvl := 0 to NumLevels do
  begin
    ws[lvl] := CeilDivPow2(OX + M.Cols, lvl) - CeilDivPow2(OX, lvl);
    hs[lvl] := CeilDivPow2(OY + M.Rows, lvl) - CeilDivPow2(OY, lvl);
    px[lvl] := CeilDivPow2(OX, lvl) and 1;
    py[lvl] := CeilDivPow2(OY, lvl) and 1;
  end;
  for lvl := NumLevels - 1 downto 0 do
  begin
    w := ws[lvl]; h := hs[lvl];
    for r := 0 to h - 1 do
      if w > 1 then
      begin
        InterleaveDP(M.Data, r * cols, 1, w, px[lvl]);
        Inv97LineP(M.Data, r * cols, 1, w, px[lvl]);
      end;
    for c := 0 to w - 1 do
      if h > 1 then
      begin
        InterleaveDP(M.Data, c, cols, h, py[lvl]);
        Inv97LineP(M.Data, c, cols, h, py[lvl]);
      end;
  end;
end;

end.
