unit SimpleSVG;

//Renders SVG images on a TBitmap
//Cross-platform - draws through LCLIntf, so it runs on any LCL widget set
//(Win32/Win64, GTK2/3, Qt4/5, Cocoa).
//Supports rect, circle, ellipse, line, polyline, polygon, path, g/svg with
//transforms, and <text>/<tspan> (font, size, weight, style, decoration,
//text-anchor, dominant-baseline, per-character x/y lists, rotation).
//An explicit fill-rule="nonzero" selects winding fill; without the attribute
//compound shapes are filled even-odd as before.
//Also: opacity / fill-opacity / stroke-opacity on shapes and text (alpha-blended),
//stroke-linecap / stroke-linejoin,
//clip-path with <clipPath> (clip-rule), stroke-dasharray /
//stroke-dashoffset at any width, and fill="url(#pattern)" (<pattern> with
//userSpaceOnUse or objectBoundingBox units, transparent where not painted).
//Author: www.xelitan.com
//License: MIT

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, DOM, XMLRead,
  // Windows unit declares TBitmap = BITMAP (a GDI record). It MUST come before
  // Graphics so that TBitmap ends up meaning the LCL class, not the WinAPI
  // struct - otherwise Bmp.Canvas / Bmp.Width stop resolving.
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  Types, LCLType, LCLIntf, Graphics, IntfGraphics, FPImage;

function RenderSimpleSVGToBitmap(const ASVGText: string; ABitmap: TBitmap): Boolean;

implementation

var
  CSSClassStyles: TStringList = nil;

type
  TMatrix2D = record
    A, B, C, D, E, F: Double; // SVG matrix(a,b,c,d,e,f): x'=A*x+C*y+E  y'=B*x+D*y+F
  end;

  TRenderState = record
    ViewX, ViewY, ViewW, ViewH: Double;
    BitmapW, BitmapH: Integer;
    CTM: TMatrix2D;
  end;

  // A flattened shape: pixel polylines, closed or open.
  TSvgSubPath = record
    Pts: array of TPoint;
    Closed: Boolean;
  end;
  TSvgOutline = array of TSvgSubPath;
  PSvgOutline = ^TSvgOutline;
  TSvgDoubles = array of Double;

function IdentityMatrix: TMatrix2D;
begin
  Result.A := 1; Result.B := 0;
  Result.C := 0; Result.D := 1;
  Result.E := 0; Result.F := 0;
end;

// Compose: result = M1 * M2  (M2 applied first, then M1)
function MatMul(const M1, M2: TMatrix2D): TMatrix2D;
begin
  Result.A := M1.A * M2.A + M1.C * M2.B;
  Result.B := M1.B * M2.A + M1.D * M2.B;
  Result.C := M1.A * M2.C + M1.C * M2.D;
  Result.D := M1.B * M2.C + M1.D * M2.D;
  Result.E := M1.A * M2.E + M1.C * M2.F + M1.E;
  Result.F := M1.B * M2.E + M1.D * M2.F + M1.F;
end;

// Tiny TPoint constructor — keeps the call sites short and avoids the
// Types.Point vs Classes.Point overload pick.
function MakePt(AX, AY: Integer): TPoint;
begin
  Result.X := AX;
  Result.Y := AY;
end;

function GetAttr(ANode: TDOMNode; const AName: string; const ADefault: string = ''): string;
var
  Attr: TDOMNode;
begin
  Result := ADefault;
  if (ANode = nil) or (ANode.Attributes = nil) then
    Exit;
  Attr := ANode.Attributes.GetNamedItem(AName);
  if Attr <> nil then
    Result := Attr.NodeValue;
end;

function TrimUnit(const S: string): string;
var
  I: Integer;
begin
  Result := Trim(S);
  I := Length(Result);
  while (I > 0) and (Result[I] in ['a'..'z', 'A'..'Z', '%']) do
  begin
    Delete(Result, I, 1);
    Dec(I);
  end;
end;

function StrToFloatSafe(const S: string; const ADefault: Double = 0.0): Double;
var
  FS: TFormatSettings;
  T: string;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  T := TrimUnit(Trim(S));
  T := StringReplace(T, ',', '.', [rfReplaceAll]);
  Result := ADefault;
  if T = '' then Exit;
  try
    Result := StrToFloat(T, FS);
  except
    Result := ADefault;
  end;
end;

function ParseIntSafe(const S: string; const ADefault: Integer = 0): Integer;
begin
  Result := Round(StrToFloatSafe(S, ADefault));
end;

function ClampByte(Value: Integer): Byte;
begin
  if Value < 0 then Exit(0);
  if Value > 255 then Exit(255);
  Result := Value;
end;

function SplitNumbers(const S: string): TStringList;
var
  T: string;
begin
  Result := TStringList.Create;
  T := Trim(S);
  T := StringReplace(T, #13, ' ', [rfReplaceAll]);
  T := StringReplace(T, #10, ' ', [rfReplaceAll]);
  T := StringReplace(T, #9,  ' ', [rfReplaceAll]);
  T := StringReplace(T, ',', ' ', [rfReplaceAll]);
  while Pos('  ', T) > 0 do
    T := StringReplace(T, '  ', ' ', [rfReplaceAll]);

  Result.Delimiter := ' ';
  Result.StrictDelimiter := False;
  Result.DelimitedText := T;
end;

function ParseSVGColor(const S: string; const ADefault: TColor): TColor;
var
  T: string;
  R, G, B: Integer;
  Parts: TStringList;
begin
  T := LowerCase(Trim(S));

  if (T = '') or (T = 'none') then
    Exit(clNone);

  if T[1] = '#' then
  begin
    if Length(T) = 7 then
    begin
      R := StrToIntDef('$' + Copy(T, 2, 2), 0);
      G := StrToIntDef('$' + Copy(T, 4, 2), 0);
      B := StrToIntDef('$' + Copy(T, 6, 2), 0);
      Exit(RGBToColor(R, G, B));
    end
    else if Length(T) = 4 then
    begin
      R := StrToIntDef('$' + Copy(T, 2, 1) + Copy(T, 2, 1), 0);
      G := StrToIntDef('$' + Copy(T, 3, 1) + Copy(T, 3, 1), 0);
      B := StrToIntDef('$' + Copy(T, 4, 1) + Copy(T, 4, 1), 0);
      Exit(RGBToColor(R, G, B));
    end;
  end;

  if Pos('rgb(', T) = 1 then
  begin
    T := Copy(T, 5, Length(T) - 4);
    if (Length(T) > 0) and (T[Length(T)] = ')') then
      Delete(T, Length(T), 1);

    Parts := TStringList.Create;
    try
      Parts.Delimiter := ',';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := T;
      if Parts.Count >= 3 then
      begin
        R := ClampByte(ParseIntSafe(Trim(Parts[0]), 0));
        G := ClampByte(ParseIntSafe(Trim(Parts[1]), 0));
        B := ClampByte(ParseIntSafe(Trim(Parts[2]), 0));
        Exit(RGBToColor(R, G, B));
      end;
    finally
      Parts.Free;
    end;
  end;

  if T = 'black'   then Exit(clBlack);
  if T = 'white'   then Exit(clWhite);
  if T = 'red'     then Exit(clRed);
  if T = 'green'   then Exit(clGreen);
  if T = 'blue'    then Exit(clBlue);
  if T = 'yellow'  then Exit(clYellow);
  if T = 'gray'    then Exit(clGray);
  if T = 'grey'    then Exit(clGray);
  if T = 'silver'  then Exit(clSilver);
  if T = 'maroon'  then Exit(clMaroon);
  if T = 'navy'    then Exit(clNavy);
  if T = 'lime'    then Exit(clLime);
  if T = 'fuchsia' then Exit(clFuchsia);
  if T = 'aqua'    then Exit(clAqua);
  if T = 'teal'    then Exit(clTeal);
  if T = 'purple'  then Exit(clPurple);
  if T = 'olive'   then Exit(clOlive);
  if T = 'orange'  then Exit(RGBToColor(255, 165, 0));

  Result := ADefault;
end;

function GetStyleProp(const StyleText, PropName: string): string;
var
  Parts: TStringList;
  I, P: Integer;
  S, K, V: string;
begin
  Result := '';
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := False;
    Parts.DelimitedText := StyleText;

    for I := 0 to Parts.Count - 1 do
    begin
      S := Trim(Parts[I]);
      P := Pos(':', S);
      if P > 0 then
      begin
        K := LowerCase(Trim(Copy(S, 1, P - 1)));
        V := Trim(Copy(S, P + 1, MaxInt));
        if K = LowerCase(PropName) then
          Exit(V);
      end;
    end;
  finally
    Parts.Free;
  end;
end;


function CollapseCSSWhitespace(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if Result[I] in [#9, #10, #13] then
      Result[I] := ' ';
  while Pos('  ', Result) > 0 do
    Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
  Result := Trim(Result);
end;

procedure ParseCSSStyleText(const CSS: string);
var
  T, Selector, Body, ClassName: string;
  P, OpenBrace, CloseBrace, DotPos, I, J: Integer;
  Selectors: TStringList;
begin
  if CSSClassStyles = nil then
  begin
    CSSClassStyles := TStringList.Create;
    CSSClassStyles.CaseSensitive := False;
    CSSClassStyles.NameValueSeparator := '=';
  end;

  T := CollapseCSSWhitespace(CSS);
  P := 1;
  while P <= Length(T) do
  begin
    OpenBrace := Pos('{', Copy(T, P, MaxInt));
    if OpenBrace = 0 then Break;
    OpenBrace := P + OpenBrace - 1;

    CloseBrace := Pos('}', Copy(T, OpenBrace + 1, MaxInt));
    if CloseBrace = 0 then Break;
    CloseBrace := OpenBrace + CloseBrace;

    Selector := Trim(Copy(T, P, OpenBrace - P));
    Body := Trim(Copy(T, OpenBrace + 1, CloseBrace - OpenBrace - 1));

    Selectors := TStringList.Create;
    try
      Selectors.Delimiter := ',';
      Selectors.StrictDelimiter := True;
      Selectors.DelimitedText := Selector;
      for I := 0 to Selectors.Count - 1 do
      begin
        Selector := Trim(Selectors[I]);
        DotPos := Pos('.', Selector);
        if DotPos > 0 then
        begin
          ClassName := Copy(Selector, DotPos + 1, MaxInt);
          J := 1;
          while (J <= Length(ClassName)) and (ClassName[J] in
            ['a'..'z','A'..'Z','0'..'9','_','-']) do
            Inc(J);
          ClassName := Copy(ClassName, 1, J - 1);

          if ClassName <> '' then
            CSSClassStyles.Values[LowerCase(ClassName)] := Body;
        end;
      end;
    finally
      Selectors.Free;
    end;

    P := CloseBrace + 1;
  end;
end;

procedure CollectCSSStyles(ANode: TDOMNode);
var
  Child: TDOMNode;
  CSS: string;
begin
  if ANode = nil then Exit;

  if (ANode is TDOMElement) and (LowerCase(ANode.NodeName) = 'style') then
  begin
    CSS := '';
    Child := ANode.FirstChild;
    while Child <> nil do
    begin
      CSS := CSS + Child.NodeValue;
      Child := Child.NextSibling;
    end;
    ParseCSSStyleText(CSS);
    Exit;
  end;

  Child := ANode.FirstChild;
  while Child <> nil do
  begin
    CollectCSSStyles(Child);
    Child := Child.NextSibling;
  end;
end;

function GetClassStyleProp(ANode: TDOMNode; const PropName: string): string;
var
  Classes, ClassName, StyleText, V: string;
  I: Integer;
  Parts: TStringList;
begin
  Result := '';
  if CSSClassStyles = nil then Exit;

  Classes := Trim(GetAttr(ANode, 'class', ''));
  if Classes = '' then Exit;

  Parts := TStringList.Create;
  try
    Classes := StringReplace(Classes, #9, ' ', [rfReplaceAll]);
    Classes := StringReplace(Classes, #10, ' ', [rfReplaceAll]);
    Classes := StringReplace(Classes, #13, ' ', [rfReplaceAll]);
    while Pos('  ', Classes) > 0 do
      Classes := StringReplace(Classes, '  ', ' ', [rfReplaceAll]);

    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Classes;

    for I := 0 to Parts.Count - 1 do
    begin
      ClassName := LowerCase(Trim(Parts[I]));
      if ClassName = '' then Continue;

      StyleText := CSSClassStyles.Values[ClassName];
      if StyleText <> '' then
      begin
        V := GetStyleProp(StyleText, PropName);
        if V <> '' then
          Exit(V);
      end;
    end;
  finally
    Parts.Free;
  end;
end;

function GetAttrOrStyle(ANode: TDOMNode; const AName, ADefault: string): string;
var
  V, StyleText: string;
  N: TDOMNode;
begin
  // CSS cascade order used here:
  // 1) inline style="..."  2) CSS class from <style>  3) presentation attribute.
  // Paint properties (fill/stroke/stroke-width) inherit in SVG, so walk up
  // through the ancestor groups before falling back to the default.
  N := ANode;
  while (N <> nil) and (N is TDOMElement) do
  begin
    StyleText := GetAttr(N, 'style', '');
    if StyleText <> '' then
    begin
      V := GetStyleProp(StyleText, AName);
      if V <> '' then
        Exit(V);
    end;

    V := GetClassStyleProp(N, AName);
    if V <> '' then
      Exit(V);

    V := GetAttr(N, AName, '');
    if V <> '' then
      Exit(V);

    N := N.ParentNode;
  end;

  Result := ADefault;
end;

procedure ApplyStyle(ANode: TDOMNode; ACanvas: TCanvas; const State: TRenderState);
var
  FillColor, StrokeColor: TColor;
  StrokeWidth, CTMScale, ViewScale, PixelWidth: Double;
  Cap: string;
begin
  FillColor := ParseSVGColor(GetAttrOrStyle(ANode, 'fill', 'black'), clBlack);
  StrokeColor := ParseSVGColor(GetAttrOrStyle(ANode, 'stroke', 'none'), clNone);
  StrokeWidth := StrToFloatSafe(GetAttrOrStyle(ANode, 'stroke-width', '1'), 1.0);

  if FillColor = clNone then
    ACanvas.Brush.Style := bsClear
  else
  begin
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := FillColor;
  end;

  if StrokeColor = clNone then
    ACanvas.Pen.Style := psClear
  else
  begin
    // Scale stroke-width from SVG user units to bitmap pixels.
    // CTMScale = sqrt(|det(CTM)|) gives the linear scale factor of the transform.
    // ViewScale maps SVG viewport units to bitmap pixels.
    CTMScale  := Sqrt(Abs(State.CTM.A * State.CTM.D - State.CTM.B * State.CTM.C));
    ViewScale := Sqrt((State.BitmapW / Math.Max(State.ViewW, 1e-12)) *
                      (State.BitmapH / Math.Max(State.ViewH, 1e-12)));
    PixelWidth := StrokeWidth * CTMScale * ViewScale;
    ACanvas.Pen.Style := psSolid;
    ACanvas.Pen.Color := StrokeColor;
    ACanvas.Pen.Width := Max(1, Round(PixelWidth));
    // stroke-linecap / stroke-linejoin (when absent: round, as before)
    Cap := LowerCase(Trim(GetAttrOrStyle(ANode, 'stroke-linecap', '')));
    if Cap = 'butt' then ACanvas.Pen.EndCap := pecFlat
    else if Cap = 'square' then ACanvas.Pen.EndCap := pecSquare
    else ACanvas.Pen.EndCap := pecRound;
    Cap := LowerCase(Trim(GetAttrOrStyle(ANode, 'stroke-linejoin', '')));
    if Cap = 'miter' then ACanvas.Pen.JoinStyle := pjsMiter
    else if Cap = 'bevel' then ACanvas.Pen.JoinStyle := pjsBevel
    else ACanvas.Pen.JoinStyle := pjsRound;
  end;
end;

procedure MapPoint(SX, SY: Double; const S: TRenderState; out PX, PY: Integer);
var
  TX, TY: Double;
begin
  TX := S.CTM.A * SX + S.CTM.C * SY + S.CTM.E;
  TY := S.CTM.B * SX + S.CTM.D * SY + S.CTM.F;

  if Abs(S.ViewW) < 1e-12 then
    PX := Round(TX)
  else
    PX := Round((TX - S.ViewX) * S.BitmapW / S.ViewW);

  if Abs(S.ViewH) < 1e-12 then
    PY := Round(TY)
  else
    PY := Round((TY - S.ViewY) * S.BitmapH / S.ViewH);
end;

procedure ParseViewBox(const S: string; out VX, VY, VW, VH: Double);
var
  Parts: TStringList;
begin
  VX := 0; VY := 0; VW := 0; VH := 0;
  Parts := SplitNumbers(S);
  try
    if Parts.Count >= 4 then
    begin
      VX := StrToFloatSafe(Parts[0], 0);
      VY := StrToFloatSafe(Parts[1], 0);
      VW := StrToFloatSafe(Parts[2], 0);
      VH := StrToFloatSafe(Parts[3], 0);
    end;
  finally
    Parts.Free;
  end;
end;

// Extract content inside first matching parentheses starting at Pos P in S (1-based).
// Returns the inner string and advances P past the closing ')'.
function ExtractParens(const S: string; var P: Integer): string;
var
  Start, Depth: Integer;
begin
  Result := '';
  while (P <= Length(S)) and (S[P] <> '(') do Inc(P);
  if P > Length(S) then Exit;
  Inc(P); // skip '('
  Start := P;
  Depth := 1;
  while (P <= Length(S)) and (Depth > 0) do
  begin
    if S[P] = '(' then Inc(Depth)
    else if S[P] = ')' then Dec(Depth);
    Inc(P);
  end;
  Result := Copy(S, Start, P - Start - 1);
end;

function ParseTransform(const TransformText: string): TMatrix2D;
var
  T: string;
  P, FuncEnd: Integer;
  FuncName, Inside: string;
  Parts: TStringList;
  M: TMatrix2D;
  Angle, CX, CY, Rad, Cos_A, Sin_A: Double;
begin
  Result := IdentityMatrix;
  T := LowerCase(Trim(TransformText));
  P := 1;

  while P <= Length(T) do
  begin
    // Skip whitespace
    while (P <= Length(T)) and (T[P] <= ' ') do Inc(P);
    if P > Length(T) then Break;

    // Read function name (until '(' or end)
    FuncEnd := P;
    while (FuncEnd <= Length(T)) and (T[FuncEnd] <> '(') do Inc(FuncEnd);
    FuncName := Trim(Copy(T, P, FuncEnd - P));
    P := FuncEnd;

    // Extract parenthesised arguments
    Inside := ExtractParens(T, P);
    Parts := SplitNumbers(Inside);
    try
      M := IdentityMatrix;

      if FuncName = 'matrix' then
      begin
        if Parts.Count >= 6 then
        begin
          M.A := StrToFloatSafe(Parts[0], 1);
          M.B := StrToFloatSafe(Parts[1], 0);
          M.C := StrToFloatSafe(Parts[2], 0);
          M.D := StrToFloatSafe(Parts[3], 1);
          M.E := StrToFloatSafe(Parts[4], 0);
          M.F := StrToFloatSafe(Parts[5], 0);
        end;
      end
      else if FuncName = 'translate' then
      begin
        M.E := StrToFloatSafe(Parts[0], 0);
        if Parts.Count >= 2 then
          M.F := StrToFloatSafe(Parts[1], 0)
        else
          M.F := 0;
      end
      else if FuncName = 'scale' then
      begin
        M.A := StrToFloatSafe(Parts[0], 1);
        if Parts.Count >= 2 then
          M.D := StrToFloatSafe(Parts[1], 1)
        else
          M.D := M.A;
      end
      else if FuncName = 'rotate' then
      begin
        Angle := StrToFloatSafe(Parts[0], 0);
        Rad   := DegToRad(Angle);
        Cos_A := Cos(Rad);
        Sin_A := Sin(Rad);
        if Parts.Count >= 3 then
        begin
          CX := StrToFloatSafe(Parts[1], 0);
          CY := StrToFloatSafe(Parts[2], 0);
          // rotate around (CX,CY): translate(-CX,-CY), rotate, translate(CX,CY)
          M.A :=  Cos_A; M.B := Sin_A;
          M.C := -Sin_A; M.D := Cos_A;
          M.E := CX - Cos_A * CX + Sin_A * CY;
          M.F := CY - Sin_A * CX - Cos_A * CY;
        end
        else
        begin
          M.A :=  Cos_A; M.B := Sin_A;
          M.C := -Sin_A; M.D := Cos_A;
        end;
      end
      else if FuncName = 'skewx' then
      begin
        M.C := Tan(DegToRad(StrToFloatSafe(Parts[0], 0)));
      end
      else if FuncName = 'skewy' then
      begin
        M.B := Tan(DegToRad(StrToFloatSafe(Parts[0], 0)));
      end;

      // Compose: result = result * M  (M applied after current result)
      Result := MatMul(Result, M);
    finally
      Parts.Free;
    end;

    // Skip optional comma between transforms
    while (P <= Length(T)) and ((T[P] <= ' ') or (T[P] = ',')) do Inc(P);
  end;
end;

function TokenizePathData(const S: string): TStringList;
var
  I, L: Integer;
  C: Char;
  Tok: string;
  SeenDot: Boolean;

  function IsCmd(Ch: Char): Boolean;
  begin
    Result := Ch in ['M','m','L','l','H','h','V','v',
                     'C','c','S','s',
                     'Q','q','T','t',
                     'A','a','Z','z'];
  end;

begin
  Result := TStringList.Create;
  I := 1;
  L := Length(S);

  while I <= L do
  begin
    C := S[I];

    if (C <= ' ') or (C = ',') then
    begin
      Inc(I);
      Continue;
    end;

    if IsCmd(C) then
    begin
      Result.Add(C);
      Inc(I);
      Continue;
    end;

    if C in ['+','-','0'..'9','.'] then
    begin
      Tok := '';
      SeenDot := False;

      if C in ['+','-'] then
      begin
        Tok := Tok + C;
        Inc(I);
      end;

      while (I <= L) and (S[I] in ['0'..'9','.']) do
      begin
        if S[I] = '.' then
        begin
          // SVG shorthand: a second '.' starts a new number ("9.5.5" = 9.5, .5)
          if SeenDot then Break;
          SeenDot := True;
        end;
        Tok := Tok + S[I];
        Inc(I);
      end;

      if (I <= L) and (S[I] in ['e','E']) then
      begin
        Tok := Tok + S[I];
        Inc(I);

        if (I <= L) and (S[I] in ['+','-']) then
        begin
          Tok := Tok + S[I];
          Inc(I);
        end;

        while (I <= L) and (S[I] in ['0'..'9']) do
        begin
          Tok := Tok + S[I];
          Inc(I);
        end;
      end;

      if Tok <> '' then
        Result.Add(Tok);

      Continue;
    end;

    Inc(I);
  end;
end;

function IsPathCommand(const S: string): Boolean;
begin
  Result :=
    (Length(S) = 1) and
    (S[1] in ['M','m','L','l','H','h','V','v',
              'C','c','S','s',
              'Q','q','T','t',
              'A','a','Z','z']);
end;

procedure CubicBezierPoint(
  T, X0, Y0, X1, Y1, X2, Y2, X3, Y3: Double;
  out X, Y: Double);
var
  MT, MT2, T2: Double;
begin
  MT := 1.0 - T;
  MT2 := MT * MT;
  T2 := T * T;

  X :=
    MT2 * MT * X0 +
    3.0 * MT2 * T * X1 +
    3.0 * MT * T2 * X2 +
    T2 * T * X3;

  Y :=
    MT2 * MT * Y0 +
    3.0 * MT2 * T * Y1 +
    3.0 * MT * T2 * Y2 +
    T2 * T * Y3;
end;

procedure QuadraticBezierPoint(
  T, X0, Y0, X1, Y1, X2, Y2: Double;
  out X, Y: Double);
var
  MT: Double;
begin
  MT := 1.0 - T;

  X :=
    MT * MT * X0 +
    2.0 * MT * T * X1 +
    T * T * X2;

  Y :=
    MT * MT * Y0 +
    2.0 * MT * T * Y1 +
    T * T * Y2;
end;

function VectorAngle(const UX, UY, VX, VY: Double): Double;
var
  DotV, LenP, A: Double;
begin
  LenP := Hypot(UX, UY) * Hypot(VX, VY);
  if LenP < 1e-20 then
    Exit(0);

  DotV := UX * VX + UY * VY;
  A := DotV / LenP;
  if A < -1 then A := -1;
  if A > 1 then A := 1;

  Result := ArcCos(A);
  if (UX * VY - UY * VX) < 0 then
    Result := -Result;
end;

procedure DrawPolylineOrPolygon(ANode: TDOMNode; ACanvas: TCanvas;
  const State: TRenderState; Closed: Boolean);
var
  Parts: TStringList;
  Pts: array of TPoint;
  I, Cnt, PX, PY: Integer;
  X, Y: Double;
begin
  Parts := SplitNumbers(GetAttr(ANode, 'points', ''));
  try
    Cnt := Parts.Count div 2;
    if Cnt <= 0 then Exit;

    SetLength(Pts, Cnt);
    for I := 0 to Cnt - 1 do
    begin
      X := StrToFloatSafe(Parts[I * 2], 0);
      Y := StrToFloatSafe(Parts[I * 2 + 1], 0);
      MapPoint(X, Y, State, PX, PY);
      Pts[I] := MakePt(PX, PY);
    end;

    ApplyStyle(ANode, ACanvas, State);

    if Closed then
      ACanvas.Polygon(Pts, LowerCase(Trim(GetAttrOrStyle(ANode, 'fill-rule', ''))) = 'nonzero')
    else
      ACanvas.Polyline(Pts);
  finally
    Parts.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Clipping, dashing and pattern fills.
//
// Shapes are handled as outlines: lists of pixel polylines ("sub-paths").
// * clip-path="url(#id)" builds a GDI clip region from the <clipPath>'s shapes
//   (clip-rule honoured) and intersects it with the clip already in force.
// * stroke-dasharray / stroke-dashoffset are applied by walking the outline and
//   drawing only the "on" pieces, so dashes work at any line width.
// * fill="url(#id)" pointing at a <pattern> renders one tile into a bitmap and
//   draws it repeatedly inside the shape (clipped to it); tile pixels that the
//   pattern content leaves untouched stay transparent.
// ---------------------------------------------------------------------------

var
  SvgIds: TStringList = nil;           // id -> element, rebuilt for every render

procedure RenderNode(ANode: TDOMNode; ACanvas: TCanvas; const ParentState: TRenderState); forward;

procedure SvgCollectIds(ANode: TDOMNode);
var C: TDOMNode; Id: string;
begin
  if ANode = nil then Exit;
  if ANode is TDOMElement then
  begin
    Id := GetAttr(ANode, 'id', '');
    if (Id <> '') and (SvgIds.IndexOf(Id) < 0) then SvgIds.AddObject(Id, ANode);
  end;
  C := ANode.FirstChild;
  while C <> nil do
  begin
    SvgCollectIds(C);
    C := C.NextSibling;
  end;
end;

// Resolves "url(#id)", "url('#id')" or "#id".
function SvgFindById(const Ref: string): TDOMNode;
var S: string; I, P: Integer;
begin
  Result := nil;
  if SvgIds = nil then Exit;
  S := Trim(Ref);
  if LowerCase(Copy(S, 1, 4)) = 'url(' then
  begin
    P := Pos(')', S);
    if P = 0 then P := Length(S) + 1;
    S := Trim(Copy(S, 5, P - 5));
    if (S <> '') and (S[1] in ['''', '"']) then S := Copy(S, 2, Length(S) - 2);
  end;
  if (S = '') or (S[1] <> '#') then Exit;
  I := SvgIds.IndexOf(Copy(S, 2, MaxInt));
  if I >= 0 then Result := TDOMNode(SvgIds.Objects[I]);
end;

function SvgPatternRef(ANode: TDOMNode): TDOMNode;
var V: string;
begin
  Result := nil;
  V := Trim(GetAttrOrStyle(ANode, 'fill', ''));
  if LowerCase(Copy(V, 1, 4)) <> 'url(' then Exit;
  Result := SvgFindById(V);
  if (Result <> nil) and (LowerCase(Result.NodeName) <> 'pattern') then Result := nil;
end;

// Pixels per user unit for the current transform and viewport.
function SvgPixelScale(const State: TRenderState): Double;
begin
  Result := Sqrt(Abs(State.CTM.A * State.CTM.D - State.CTM.B * State.CTM.C)) *
            Sqrt((State.BitmapW / Math.Max(State.ViewW, 1e-12)) *
                 (State.BitmapH / Math.Max(State.ViewH, 1e-12)));
end;

// Dash pattern in pixels; False when the stroke is solid.
function SvgDashArray(ANode: TDOMNode; const State: TRenderState;
  out Dashes: TSvgDoubles; out Offset: Double): Boolean;
var
  Parts: TStringList;
  I, N: Integer;
  Scale, Total, V: Double;
  S: string;
begin
  Result := False;
  Dashes := nil;
  Offset := 0;
  S := Trim(GetAttrOrStyle(ANode, 'stroke-dasharray', ''));
  if (S = '') or (LowerCase(S) = 'none') then Exit;
  Parts := SplitNumbers(S);
  try
    N := Parts.Count;
    if N = 0 then Exit;
    Scale := SvgPixelScale(State);
    // an odd list is repeated to make it even (SVG rule)
    if Odd(N) then SetLength(Dashes, N * 2) else SetLength(Dashes, N);
    Total := 0;
    for I := 0 to High(Dashes) do
    begin
      V := StrToFloatSafe(Parts[I mod N], 0);
      if V < 0 then Exit;                     // invalid: draw solid
      Dashes[I] := V * Scale;
      Total := Total + Dashes[I];
    end;
    if Total < 0.5 then Exit;
    Offset := StrToFloatSafe(GetAttrOrStyle(ANode, 'stroke-dashoffset', '0'), 0) * Scale;
    Result := True;
  finally
    Parts.Free;
  end;
end;

// Draws the "on" parts of a dash pattern along a pixel polyline.
procedure SvgDashStroke(ACanvas: TCanvas; const Pts: array of TPoint; Closed: Boolean;
  const Dashes: TSvgDoubles; Offset: Double);
var
  Seg: array of TPoint;
  SegN, I, N, K: Integer;
  Total, Left, SegLen, T, X0, Y0, X1, Y1, Used: Double;
  On: Boolean;
  SavedCap: TPenEndCap;

  procedure AddPt(X, Y: Double);
  var P: TPoint;
  begin
    P := MakePt(Round(X), Round(Y));
    if (SegN > 0) and (Seg[SegN - 1].X = P.X) and (Seg[SegN - 1].Y = P.Y) then Exit;
    if SegN >= Length(Seg) then SetLength(Seg, SegN * 2 + 8);
    Seg[SegN] := P;
    Inc(SegN);
  end;

  procedure Flush;
  begin
    if SegN >= 2 then ACanvas.Polyline(Copy(Seg, 0, SegN))
    else if SegN = 1 then ACanvas.Polyline([Seg[0], Seg[0]]);
    SegN := 0;
  end;

begin
  N := Length(Pts);
  if N < 2 then Exit;
  Total := 0;
  for I := 0 to High(Dashes) do Total := Total + Dashes[I];
  // position inside the pattern at the start of the line
  T := Offset - Total * Floor(Offset / Total);
  K := 0;
  while T >= Dashes[K] do
  begin
    T := T - Dashes[K];
    K := (K + 1) mod Length(Dashes);
  end;
  Left := Dashes[K] - T;          // what remains of the current dash / gap
  On := not Odd(K);

  SavedCap := ACanvas.Pen.EndCap;
  ACanvas.Pen.EndCap := pecFlat;  // SVG default is butt
  SegN := 0;
  if On then AddPt(Pts[0].X, Pts[0].Y);
  for I := 0 to N - 1 + Ord(Closed) do
  begin
    if I + 1 > N - 1 + Ord(Closed) then Break;
    X0 := Pts[I mod N].X; Y0 := Pts[I mod N].Y;
    X1 := Pts[(I + 1) mod N].X; Y1 := Pts[(I + 1) mod N].Y;
    SegLen := Hypot(X1 - X0, Y1 - Y0);
    Used := 0;
    while SegLen - Used > Left do
    begin
      Used := Used + Left;
      if On then
      begin
        AddPt(X0 + (X1 - X0) * Used / SegLen, Y0 + (Y1 - Y0) * Used / SegLen);
        Flush;
      end;
      K := (K + 1) mod Length(Dashes);
      Left := Dashes[K];
      On := not Odd(K);
      if On then AddPt(X0 + (X1 - X0) * Used / SegLen, Y0 + (Y1 - Y0) * Used / SegLen);
    end;
    Left := Left - (SegLen - Used);
    if On then AddPt(X1, Y1);
  end;
  if On then Flush;
  ACanvas.Pen.EndCap := SavedCap;
end;

// GDI region of an outline; even-odd XORs the sub-paths, non-zero unites them.
function SvgOutlineRegion(const O: TSvgOutline; NonZero: Boolean): HRGN;
var I: Integer; R: HRGN;
begin
  Result := CreateRectRgn(0, 0, 0, 0);
  for I := 0 to High(O) do
    if Length(O[I].Pts) >= 3 then
    begin
      if NonZero then R := CreatePolygonRgn(@O[I].Pts[0], Length(O[I].Pts), WINDING)
      else R := CreatePolygonRgn(@O[I].Pts[0], Length(O[I].Pts), ALTERNATE);
      if NonZero then CombineRgn(Result, Result, R, RGN_OR)
      else CombineRgn(Result, Result, R, RGN_XOR);
      DeleteObject(R);
    end;
end;

// Intersects NewRgn with the current clip and selects it. Returns the previous
// clip (0 = none) for SvgPopClip. NewRgn is consumed.
function SvgPushClip(ACanvas: TCanvas; NewRgn: HRGN): HRGN;
begin
  Result := CreateRectRgn(0, 0, 0, 0);
  if GetClipRGN(ACanvas.Handle, Result) = 1 then
    CombineRgn(NewRgn, NewRgn, Result, RGN_AND)
  else
  begin
    DeleteObject(Result);
    Result := 0;
  end;
  SelectClipRGN(ACanvas.Handle, NewRgn);
  DeleteObject(NewRgn);
end;

procedure SvgPopClip(ACanvas: TCanvas; Saved: HRGN);
begin
  SelectClipRGN(ACanvas.Handle, Saved);
  if Saved <> 0 then DeleteObject(Saved);
end;

function SvgOutlineBounds(const O: TSvgOutline; out R: TRect): Boolean;
var I, J: Integer;
begin
  Result := False;
  R := Rect(MaxInt, MaxInt, -MaxInt, -MaxInt);
  for I := 0 to High(O) do
    for J := 0 to High(O[I].Pts) do
    begin
      if O[I].Pts[J].X < R.Left then R.Left := O[I].Pts[J].X;
      if O[I].Pts[J].Y < R.Top then R.Top := O[I].Pts[J].Y;
      if O[I].Pts[J].X > R.Right then R.Right := O[I].Pts[J].X;
      if O[I].Pts[J].Y > R.Bottom then R.Bottom := O[I].Pts[J].Y;
      Result := True;
    end;
  Inc(R.Right); Inc(R.Bottom);
end;

// Fills an outline with a <pattern>.
procedure SvgPatternFill(ANode: TDOMNode; ACanvas: TCanvas; const State: TRenderState;
  const O: TSvgOutline; NonZero: Boolean);
const
  KEY = $00030201;                      // "untouched" colour of the tile
var
  Pat, C: TDOMNode;
  BB: TRect;
  Scale, PX, PY, PW, PH, SX, SY, OX, OY: Double;
  TB, TH, K, BigW, BigH, I, J, X, Y, IPX, IPY: Integer;
  UserUnits: Boolean;
  Tile: TBitmap;
  TS: TRenderState;
  M: TMatrix2D;
  Saved: HRGN;
begin
  Pat := SvgPatternRef(ANode);
  if (Pat = nil) or not SvgOutlineBounds(O, BB) then Exit;
  Scale := SvgPixelScale(State);
  UserUnits := LowerCase(GetAttr(Pat, 'patternUnits', 'objectBoundingBox')) = 'userspaceonuse';
  PX := StrToFloatSafe(GetAttr(Pat, 'x', '0'), 0);
  PY := StrToFloatSafe(GetAttr(Pat, 'y', '0'), 0);
  PW := StrToFloatSafe(GetAttr(Pat, 'width', '0'), 0);
  PH := StrToFloatSafe(GetAttr(Pat, 'height', '0'), 0);
  if (PW <= 0) or (PH <= 0) then Exit;
  if UserUnits then
  begin
    MapPoint(PX, PY, State, IPX, IPY);
    OX := IPX; OY := IPY;
    PW := PW * Scale; PH := PH * Scale;
  end
  else
  begin
    // fractions of the shape's bounding box
    OX := BB.Left + PX * (BB.Right - BB.Left);
    OY := BB.Top + PY * (BB.Bottom - BB.Top);
    PW := PW * (BB.Right - BB.Left); PH := PH * (BB.Bottom - BB.Top);
  end;
  TB := Max(1, Round(PW)); TH := Max(1, Round(PH));
  // several copies per bitmap so that small tiles do not need many blits
  K := Max(1, Min(64 div Max(TB, TH) + 1, 256 div Max(TB, TH) + 1));
  BigW := TB * K; BigH := TH * K;
  SX := TB / Math.Max(StrToFloatSafe(GetAttr(Pat, 'width', '1'), 1), 1e-12);
  SY := TH / Math.Max(StrToFloatSafe(GetAttr(Pat, 'height', '1'), 1), 1e-12);
  if not UserUnits then
  begin
    SX := Scale; SY := Scale;      // content still in user units
  end;

  Tile := TBitmap.Create;
  try
    Tile.PixelFormat := pf24bit;
    Tile.SetSize(BigW, BigH);
    Tile.Canvas.Brush.Style := bsSolid;
    Tile.Canvas.Brush.Color := TColor(KEY);
    Tile.Canvas.FillRect(Rect(0, 0, BigW, BigH));
    TS.ViewX := 0; TS.ViewY := 0; TS.ViewW := BigW; TS.ViewH := BigH;
    TS.BitmapW := BigW; TS.BitmapH := BigH;
    for J := 0 to K - 1 do
      for I := 0 to K - 1 do
      begin
        M := IdentityMatrix;
        M.A := SX; M.D := SY; M.E := I * TB; M.F := J * TH;
        TS.CTM := MatMul(M, ParseTransform(GetAttr(Pat, 'patternTransform', '')));
        C := Pat.FirstChild;
        while C <> nil do
        begin
          if C is TDOMElement then RenderNode(C, Tile.Canvas, TS);
          C := C.NextSibling;
        end;
      end;
    Tile.TransparentColor := TColor(KEY);
    Tile.TransparentMode := tmFixed;
    Tile.Transparent := True;

    Saved := SvgPushClip(ACanvas, SvgOutlineRegion(O, NonZero));
    try
      X := Round(OX) - Ceil((OX - BB.Left) / BigW) * BigW;
      while X < BB.Right do
      begin
        Y := Round(OY) - Ceil((OY - BB.Top) / BigH) * BigH;
        while Y < BB.Bottom do
        begin
          ACanvas.Draw(X, Y, Tile);
          Inc(Y, BigH);
        end;
        Inc(X, BigW);
      end;
    finally
      SvgPopClip(ACanvas, Saved);
    end;
  finally
    Tile.Free;
  end;
end;

// Collect <> nil: only build the outline (no drawing, ACanvas may be nil).
procedure DrawPath(ANode: TDOMNode; ACanvas: TCanvas; const State: TRenderState;
  Collect: PSvgOutline = nil);
const
  MAX_BEZIER_STEPS = 10;
  MAX_ARC_SEGMENTS_PER_PI = 10;
  CURVE_PIXELS_PER_SEGMENT = 8.0;
type
  TSubPath = TSvgSubPath;
var
  D, Cmd: string;
  Tokens: TStringList;
  I: Integer;
  CurX, CurY: Double;
  StartX, StartY: Double;
  X, Y: Double;
  HasFill, HasStroke: Boolean;
  SavedFillColor: TColor;
  SavedPenStyle: TPenStyle;
  SavedPenColor: TColor;
  SavedPenWidth: Integer;

  LastC2X, LastC2Y: Double;
  LastQ1X, LastQ1Y: Double;
  PrevCmd: Char;

  // Current sub-path being built
  // PtsCount/PtsCapacity avoid SetLength for every single point.
  Pts: array of TPoint;
  PtsCount, PtsCapacity: Integer;

  // All completed sub-paths for this path element
  SubPaths: array of TSubPath;
  SubPathCount, SubPathCapacity: Integer;

  // Scratch variables for the fill/stroke render passes
  AllPts: array of TPoint;
  Counts: array of LongInt;
  TotalPts, FJ, FK, SJ: Integer;

  procedure EnsurePtsCapacity(Needed: Integer);
  begin
    if Needed <= PtsCapacity then Exit;
    if PtsCapacity < 64 then
      PtsCapacity := 64;
    while PtsCapacity < Needed do
      PtsCapacity := PtsCapacity * 2;
    SetLength(Pts, PtsCapacity);
  end;

  procedure EnsureSubPathCapacity(Needed: Integer);
  begin
    if Needed <= SubPathCapacity then Exit;
    if SubPathCapacity < 8 then
      SubPathCapacity := 8;
    while SubPathCapacity < Needed do
      SubPathCapacity := SubPathCapacity * 2;
    SetLength(SubPaths, SubPathCapacity);
  end;

  procedure AddPoint(AX, AY: Double);
  var
    PX, PY: Integer;
  begin
    MapPoint(AX, AY, State, PX, PY);

    // Po transformacji wiele próbek krzywej trafia w ten sam piksel.
    // Ich pomijanie mocno przyspiesza duże SVG z potrace/Inkscape.
    if (PtsCount > 0) and (Pts[PtsCount - 1].X = PX) and (Pts[PtsCount - 1].Y = PY) then
      Exit;

    EnsurePtsCapacity(PtsCount + 1);
    Pts[PtsCount] := MakePt(PX, PY);
    Inc(PtsCount);
  end;

  function ScreenDist(AX, AY, BX, BY: Double): Double;
  var
    PX1, PY1, PX2, PY2: Integer;
  begin
    MapPoint(AX, AY, State, PX1, PY1);
    MapPoint(BX, BY, State, PX2, PY2);
    Result := Hypot(PX2 - PX1, PY2 - PY1);
  end;

  function CurveStepCount(ApproxPixelLen: Double): Integer;
  begin
    Result := Ceil(ApproxPixelLen / CURVE_PIXELS_PER_SEGMENT);
    if Result < 2 then Result := 2;
    if Result > MAX_BEZIER_STEPS then Result := MAX_BEZIER_STEPS;
  end;

  // Commit the current sub-path to the SubPaths list.
  procedure CommitSubPath(Closed: Boolean);
  begin
    if PtsCount >= 2 then
    begin
      EnsureSubPathCapacity(SubPathCount + 1);
      SetLength(SubPaths[SubPathCount].Pts, PtsCount);
      Move(Pts[0], SubPaths[SubPathCount].Pts[0], PtsCount * SizeOf(TPoint));
      SubPaths[SubPathCount].Closed := Closed;
      Inc(SubPathCount);
    end;
    PtsCount := 0;
  end;

  procedure BeginSubPath(AX, AY: Double);
  begin
    CommitSubPath(False);
    AddPoint(AX, AY);
    StartX := AX;
    StartY := AY;
    CurX := AX;
    CurY := AY;
  end;

  procedure AddCubicBezier(X1, Y1, X2, Y2, X3, Y3: Double);
  var
    Step, Steps: Integer;
    T, BX, BY, Len: Double;
  begin
    // Adaptacyjnie: liczba segmentów zależy od długości w pikselach,
    // zamiast stałych 24 próbek dla każdej, nawet mikroskopijnej krzywej.
    Len := ScreenDist(CurX, CurY, X1, Y1) + ScreenDist(X1, Y1, X2, Y2) + ScreenDist(X2, Y2, X3, Y3);
    Steps := CurveStepCount(Len);

    for Step := 1 to Steps do
    begin
      T := Step / Steps;
      CubicBezierPoint(T, CurX, CurY, X1, Y1, X2, Y2, X3, Y3, BX, BY);
      AddPoint(BX, BY);
    end;

    CurX := X3;
    CurY := Y3;
    LastC2X := X2;
    LastC2Y := Y2;
  end;

  procedure AddQuadraticBezier(X1, Y1, X2, Y2: Double);
  var
    Step, Steps: Integer;
    T, BX, BY, Len: Double;
  begin
    Len := ScreenDist(CurX, CurY, X1, Y1) + ScreenDist(X1, Y1, X2, Y2);
    Steps := CurveStepCount(Len);

    for Step := 1 to Steps do
    begin
      T := Step / Steps;
      QuadraticBezierPoint(T, CurX, CurY, X1, Y1, X2, Y2, BX, BY);
      AddPoint(BX, BY);
    end;

    CurX := X2;
    CurY := Y2;
    LastQ1X := X1;
    LastQ1Y := Y1;
  end;

  procedure AddArc(RX, RY, XAxisRotation: Double; LargeArcFlag, SweepFlag: Integer; X2, Y2: Double);
  var
    X1, Y1: Double;
    Phi, CosPhi, SinPhi: Double;
    DX2, DY2: Double;
    X1p, Y1p: Double;
    RXa, RYa: Double;
    Lambda: Double;
    Num, Den, Factor: Double;
    CXp, CYp: Double;
    CX, CY: Double;
    Theta1, DeltaTheta: Double;
    Ux, Uy, Vx, Vy: Double;
    Segments, Step: Integer;
    TAng, PX, PY: Double;
  begin
    X1 := CurX;
    Y1 := CurY;

    if (Abs(X1 - X2) < 1e-12) and (Abs(Y1 - Y2) < 1e-12) then
      Exit;

    RXa := Abs(RX);
    RYa := Abs(RY);

    if (RXa < 1e-12) or (RYa < 1e-12) then
    begin
      CurX := X2;
      CurY := Y2;
      AddPoint(CurX, CurY);
      Exit;
    end;

    Phi := DegToRad(XAxisRotation);
    CosPhi := Cos(Phi);
    SinPhi := Sin(Phi);

    DX2 := (X1 - X2) / 2.0;
    DY2 := (Y1 - Y2) / 2.0;

    X1p := CosPhi * DX2 + SinPhi * DY2;
    Y1p := -SinPhi * DX2 + CosPhi * DY2;

    Lambda := Sqr(X1p) / Sqr(RXa) + Sqr(Y1p) / Sqr(RYa);
    if Lambda > 1.0 then
    begin
      Lambda := Sqrt(Lambda);
      RXa := RXa * Lambda;
      RYa := RYa * Lambda;
    end;

    Num := Sqr(RXa) * Sqr(RYa) - Sqr(RXa) * Sqr(Y1p) - Sqr(RYa) * Sqr(X1p);
    Den := Sqr(RXa) * Sqr(Y1p) + Sqr(RYa) * Sqr(X1p);

    if Abs(Den) < 1e-20 then
      Factor := 0
    else
    begin
      Factor := Num / Den;
      if Factor < 0 then
        Factor := 0;
      Factor := Sqrt(Factor);
    end;

    if LargeArcFlag = SweepFlag then
      Factor := -Factor;

    CXp := Factor * (RXa * Y1p / RYa);
    CYp := Factor * (-RYa * X1p / RXa);

    CX := CosPhi * CXp - SinPhi * CYp + (X1 + X2) / 2.0;
    CY := SinPhi * CXp + CosPhi * CYp + (Y1 + Y2) / 2.0;

    Ux := (X1p - CXp) / RXa;
    Uy := (Y1p - CYp) / RYa;
    Vx := (-X1p - CXp) / RXa;
    Vy := (-Y1p - CYp) / RYa;

    Theta1 := VectorAngle(1, 0, Ux, Uy);
    DeltaTheta := VectorAngle(Ux, Uy, Vx, Vy);

    if (SweepFlag = 0) and (DeltaTheta > 0) then
      DeltaTheta := DeltaTheta - 2 * Pi
    else if (SweepFlag <> 0) and (DeltaTheta < 0) then
      DeltaTheta := DeltaTheta + 2 * Pi;

    Segments := Ceil(Abs(DeltaTheta) / Pi * MAX_ARC_SEGMENTS_PER_PI);
    if Segments < 1 then
      Segments := 1;

    for Step := 1 to Segments do
    begin
      TAng := Theta1 + DeltaTheta * (Step / Segments);

      PX := CX + CosPhi * RXa * Cos(TAng) - SinPhi * RYa * Sin(TAng);
      PY := CY + SinPhi * RXa * Cos(TAng) + CosPhi * RYa * Sin(TAng);

      AddPoint(PX, PY);
    end;

    CurX := X2;
    CurY := Y2;
  end;

  function NextIsNumber: Boolean;
  begin
    Result := (I < Tokens.Count) and (not IsPathCommand(Tokens[I]));
  end;

var
  X1, Y1, X2, Y2, X3, Y3: Double;
  RX1, RY1: Double;
  ARX, ARY, AXRot: Double;
  ALarge, ASweep: Integer;
  GuardI: Integer;
  DashList: TSvgDoubles;
  DashOff: Double;
begin
  HasFill := False; HasStroke := False;
  if Collect = nil then
  begin
    ApplyStyle(ANode, ACanvas, State);
    HasFill   := ACanvas.Brush.Style <> bsClear;
    HasStroke := ACanvas.Pen.Style   <> psClear;
    SavedFillColor := ACanvas.Brush.Color;
    SavedPenStyle  := ACanvas.Pen.Style;
    SavedPenColor  := ACanvas.Pen.Color;
    SavedPenWidth  := ACanvas.Pen.Width;
  end;

  D := GetAttr(ANode, 'd', '');
  if D = '' then Exit;

  SubPathCount := 0;
  SubPathCapacity := 0;

  Tokens := TokenizePathData(D);
  try
    I := 0;
    Cmd := '';
    CurX := 0;
    CurY := 0;
    StartX := 0;
    StartY := 0;

    LastC2X := 0;
    LastC2Y := 0;
    LastQ1X := 0;
    LastQ1Y := 0;

    PrevCmd := #0;
    PtsCount := 0;
    PtsCapacity := 0;
    SetLength(Pts, 0);

    while I < Tokens.Count do
    begin
      if IsPathCommand(Tokens[I]) then
      begin
        Cmd := Tokens[I];
        Inc(I);

        if (Cmd = 'Z') or (Cmd = 'z') then
        begin
          AddPoint(StartX, StartY);
          CommitSubPath(True);
          CurX := StartX;
          CurY := StartY;
          PrevCmd := Cmd[1];
        end;

        Continue;
      end;

      if Cmd = '' then
      begin
        Inc(I);
        Continue;
      end;

      GuardI := I;

      case Cmd[1] of
        'M':
          begin
            if I + 1 >= Tokens.Count then Break;
            X := StrToFloatSafe(Tokens[I], 0);
            Y := StrToFloatSafe(Tokens[I + 1], 0);
            BeginSubPath(X, Y);
            Inc(I, 2);
            Cmd := 'L';
            PrevCmd := 'M';
          end;

        'm':
          begin
            if I + 1 >= Tokens.Count then Break;
            X := CurX + StrToFloatSafe(Tokens[I], 0);
            Y := CurY + StrToFloatSafe(Tokens[I + 1], 0);
            BeginSubPath(X, Y);
            Inc(I, 2);
            Cmd := 'l';
            PrevCmd := 'm';
          end;

        'L':
          begin
            while (I + 1 < Tokens.Count) and NextIsNumber do
            begin
              X := StrToFloatSafe(Tokens[I], 0);
              Y := StrToFloatSafe(Tokens[I + 1], 0);
              CurX := X;
              CurY := Y;
              AddPoint(CurX, CurY);
              Inc(I, 2);
              PrevCmd := 'L';
              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'l':
          begin
            while (I + 1 < Tokens.Count) and NextIsNumber do
            begin
              CurX := CurX + StrToFloatSafe(Tokens[I], 0);
              CurY := CurY + StrToFloatSafe(Tokens[I + 1], 0);
              AddPoint(CurX, CurY);
              Inc(I, 2);
              PrevCmd := 'l';
              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'H':
          begin
            while (I < Tokens.Count) and NextIsNumber do
            begin
              CurX := StrToFloatSafe(Tokens[I], 0);
              AddPoint(CurX, CurY);
              Inc(I);
              PrevCmd := 'H';
              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'h':
          begin
            while (I < Tokens.Count) and NextIsNumber do
            begin
              CurX := CurX + StrToFloatSafe(Tokens[I], 0);
              AddPoint(CurX, CurY);
              Inc(I);
              PrevCmd := 'h';
              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'V':
          begin
            while (I < Tokens.Count) and NextIsNumber do
            begin
              CurY := StrToFloatSafe(Tokens[I], 0);
              AddPoint(CurX, CurY);
              Inc(I);
              PrevCmd := 'V';
              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'v':
          begin
            while (I < Tokens.Count) and NextIsNumber do
            begin
              CurY := CurY + StrToFloatSafe(Tokens[I], 0);
              AddPoint(CurX, CurY);
              Inc(I);
              PrevCmd := 'v';
              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'C':
          begin
            while (I + 5 < Tokens.Count) and NextIsNumber do
            begin
              X1 := StrToFloatSafe(Tokens[I + 0], 0);
              Y1 := StrToFloatSafe(Tokens[I + 1], 0);
              X2 := StrToFloatSafe(Tokens[I + 2], 0);
              Y2 := StrToFloatSafe(Tokens[I + 3], 0);
              X3 := StrToFloatSafe(Tokens[I + 4], 0);
              Y3 := StrToFloatSafe(Tokens[I + 5], 0);

              AddCubicBezier(X1, Y1, X2, Y2, X3, Y3);
              Inc(I, 6);
              PrevCmd := 'C';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'c':
          begin
            while (I + 5 < Tokens.Count) and NextIsNumber do
            begin
              X1 := CurX + StrToFloatSafe(Tokens[I + 0], 0);
              Y1 := CurY + StrToFloatSafe(Tokens[I + 1], 0);
              X2 := CurX + StrToFloatSafe(Tokens[I + 2], 0);
              Y2 := CurY + StrToFloatSafe(Tokens[I + 3], 0);
              X3 := CurX + StrToFloatSafe(Tokens[I + 4], 0);
              Y3 := CurY + StrToFloatSafe(Tokens[I + 5], 0);

              AddCubicBezier(X1, Y1, X2, Y2, X3, Y3);
              Inc(I, 6);
              PrevCmd := 'c';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'S':
          begin
            while (I + 3 < Tokens.Count) and NextIsNumber do
            begin
              if PrevCmd in ['C', 'c', 'S', 's'] then
              begin
                RX1 := 2 * CurX - LastC2X;
                RY1 := 2 * CurY - LastC2Y;
              end
              else
              begin
                RX1 := CurX;
                RY1 := CurY;
              end;

              X2 := StrToFloatSafe(Tokens[I + 0], 0);
              Y2 := StrToFloatSafe(Tokens[I + 1], 0);
              X3 := StrToFloatSafe(Tokens[I + 2], 0);
              Y3 := StrToFloatSafe(Tokens[I + 3], 0);

              AddCubicBezier(RX1, RY1, X2, Y2, X3, Y3);
              Inc(I, 4);
              PrevCmd := 'S';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        's':
          begin
            while (I + 3 < Tokens.Count) and NextIsNumber do
            begin
              if PrevCmd in ['C', 'c', 'S', 's'] then
              begin
                RX1 := 2 * CurX - LastC2X;
                RY1 := 2 * CurY - LastC2Y;
              end
              else
              begin
                RX1 := CurX;
                RY1 := CurY;
              end;

              X2 := CurX + StrToFloatSafe(Tokens[I + 0], 0);
              Y2 := CurY + StrToFloatSafe(Tokens[I + 1], 0);
              X3 := CurX + StrToFloatSafe(Tokens[I + 2], 0);
              Y3 := CurY + StrToFloatSafe(Tokens[I + 3], 0);

              AddCubicBezier(RX1, RY1, X2, Y2, X3, Y3);
              Inc(I, 4);
              PrevCmd := 's';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'Q':
          begin
            while (I + 3 < Tokens.Count) and NextIsNumber do
            begin
              X1 := StrToFloatSafe(Tokens[I + 0], 0);
              Y1 := StrToFloatSafe(Tokens[I + 1], 0);
              X2 := StrToFloatSafe(Tokens[I + 2], 0);
              Y2 := StrToFloatSafe(Tokens[I + 3], 0);

              AddQuadraticBezier(X1, Y1, X2, Y2);
              Inc(I, 4);
              PrevCmd := 'Q';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'q':
          begin
            while (I + 3 < Tokens.Count) and NextIsNumber do
            begin
              X1 := CurX + StrToFloatSafe(Tokens[I + 0], 0);
              Y1 := CurY + StrToFloatSafe(Tokens[I + 1], 0);
              X2 := CurX + StrToFloatSafe(Tokens[I + 2], 0);
              Y2 := CurY + StrToFloatSafe(Tokens[I + 3], 0);

              AddQuadraticBezier(X1, Y1, X2, Y2);
              Inc(I, 4);
              PrevCmd := 'q';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'T':
          begin
            while (I + 1 < Tokens.Count) and NextIsNumber do
            begin
              if PrevCmd in ['Q', 'q', 'T', 't'] then
              begin
                RX1 := 2 * CurX - LastQ1X;
                RY1 := 2 * CurY - LastQ1Y;
              end
              else
              begin
                RX1 := CurX;
                RY1 := CurY;
              end;

              X2 := StrToFloatSafe(Tokens[I + 0], 0);
              Y2 := StrToFloatSafe(Tokens[I + 1], 0);

              AddQuadraticBezier(RX1, RY1, X2, Y2);
              Inc(I, 2);
              PrevCmd := 'T';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        't':
          begin
            while (I + 1 < Tokens.Count) and NextIsNumber do
            begin
              if PrevCmd in ['Q', 'q', 'T', 't'] then
              begin
                RX1 := 2 * CurX - LastQ1X;
                RY1 := 2 * CurY - LastQ1Y;
              end
              else
              begin
                RX1 := CurX;
                RY1 := CurY;
              end;

              X2 := CurX + StrToFloatSafe(Tokens[I + 0], 0);
              Y2 := CurY + StrToFloatSafe(Tokens[I + 1], 0);

              AddQuadraticBezier(RX1, RY1, X2, Y2);
              Inc(I, 2);
              PrevCmd := 't';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'A':
          begin
            while (I + 6 < Tokens.Count) and NextIsNumber do
            begin
              ARX := StrToFloatSafe(Tokens[I + 0], 0);
              ARY := StrToFloatSafe(Tokens[I + 1], 0);
              AXRot := StrToFloatSafe(Tokens[I + 2], 0);
              ALarge := ParseIntSafe(Tokens[I + 3], 0);
              ASweep := ParseIntSafe(Tokens[I + 4], 0);
              X2 := StrToFloatSafe(Tokens[I + 5], 0);
              Y2 := StrToFloatSafe(Tokens[I + 6], 0);

              AddArc(ARX, ARY, AXRot, ALarge, ASweep, X2, Y2);
              Inc(I, 7);
              PrevCmd := 'A';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'a':
          begin
            while (I + 6 < Tokens.Count) and NextIsNumber do
            begin
              ARX := StrToFloatSafe(Tokens[I + 0], 0);
              ARY := StrToFloatSafe(Tokens[I + 1], 0);
              AXRot := StrToFloatSafe(Tokens[I + 2], 0);
              ALarge := ParseIntSafe(Tokens[I + 3], 0);
              ASweep := ParseIntSafe(Tokens[I + 4], 0);
              X2 := CurX + StrToFloatSafe(Tokens[I + 5], 0);
              Y2 := CurY + StrToFloatSafe(Tokens[I + 6], 0);

              AddArc(ARX, ARY, AXRot, ALarge, ASweep, X2, Y2);
              Inc(I, 7);
              PrevCmd := 'a';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

      else
        Inc(I);
      end;

      // A command block that consumed nothing (e.g. too few numbers left for
      // the command) would loop forever - skip the stray token instead.
      if I = GuardI then
        Inc(I);
    end;

    CommitSubPath(False); // commit any trailing open sub-path
  finally
    Tokens.Free;
  end;

  if SubPathCount = 0 then Exit;

  if Collect <> nil then
  begin
    SetLength(Collect^, SubPathCount);
    for FJ := 0 to SubPathCount - 1 do Collect^[FJ] := SubPaths[FJ];
    Exit;
  end;

  // --- Pattern fill: tiles clipped to the path ---
  if HasFill and (SvgPatternRef(ANode) <> nil) then
  begin
    SvgPatternFill(ANode, ACanvas, State, Copy(SubPaths, 0, SubPathCount),
      LowerCase(Trim(GetAttrOrStyle(ANode, 'fill-rule', ''))) = 'nonzero');
    HasFill := False;
  end;

  // --- Fill pass: all sub-paths together with even-odd rule ---
  // Even-odd (ALTERNATE) creates holes where sub-paths overlap,
  // which is required for potrace/compound SVG paths.
  if HasFill then
  begin
    TotalPts := 0;
    SetLength(Counts, SubPathCount);
    for FJ := 0 to SubPathCount - 1 do
    begin
      Counts[FJ] := Length(SubPaths[FJ].Pts);
      Inc(TotalPts, Counts[FJ]);
    end;
    SetLength(AllPts, TotalPts);
    FK := 0;
    for FJ := 0 to SubPathCount - 1 do
    begin
      Move(SubPaths[FJ].Pts[0], AllPts[FK], Counts[FJ] * SizeOf(TPoint));
      Inc(FK, Counts[FJ]);
    end;

    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := SavedFillColor;
    ACanvas.Pen.Style   := psClear;

    // Even-odd (ALTERNATE) is what we want so that overlapping sub-paths
    // punch holes - that's how compound SVG paths from potrace/Inkscape work.
    // Only Windows exposes a real PolyPolygon + SetPolyFillMode here, so on
    // every other LCL backend we fall back to drawing each sub-path on its
    // own. That loses cross-subpath even-odd fill (compound holes will be
    // filled solid) but everything renders.
    {$IFDEF MSWINDOWS}
    if LowerCase(Trim(GetAttrOrStyle(ANode, 'fill-rule', ''))) = 'nonzero' then
      Windows.SetPolyFillMode(ACanvas.Handle, WINDING)
    else
      Windows.SetPolyFillMode(ACanvas.Handle, ALTERNATE);
    Windows.PolyPolygon(ACanvas.Handle, AllPts[0], Counts[0], SubPathCount);
    {$ELSE}
    for FJ := 0 to SubPathCount - 1 do
      ACanvas.Polygon(SubPaths[FJ].Pts);
    {$ENDIF}
  end;

  // --- Stroke pass: each sub-path drawn as outline individually ---
  if HasStroke then
  begin
    ACanvas.Brush.Style := bsClear;
    ACanvas.Pen.Style   := SavedPenStyle;
    ACanvas.Pen.Color   := SavedPenColor;
    ACanvas.Pen.Width   := SavedPenWidth;
    if SvgDashArray(ANode, State, DashList, DashOff) then
    begin
      for SJ := 0 to SubPathCount - 1 do
        SvgDashStroke(ACanvas, SubPaths[SJ].Pts, SubPaths[SJ].Closed, DashList, DashOff);
    end
    else
    for SJ := 0 to SubPathCount - 1 do
    begin
      if SubPaths[SJ].Closed then
        ACanvas.Polygon(SubPaths[SJ].Pts)
      else
        ACanvas.Polyline(SubPaths[SJ].Pts);
    end;
  end;
end;

// Pixel outline of a basic shape (rect, circle, ellipse, line, polyline,
// polygon, path). Transforms, including rotation, are applied point by point.
function SvgElementOutline(ANode: TDOMNode; const State: TRenderState; out O: TSvgOutline): Boolean;
var
  N: string;
  X, Y, W, H, CX, CY, RX, RY, T, Circ: Double;
  I, Cnt, PX, PY: Integer;
  Parts: TStringList;

  procedure Add1(Closed: Boolean);
  begin
    SetLength(O, 1);
    O[0].Closed := Closed;
    O[0].Pts := nil;
  end;

  procedure AddPt(AX, AY: Double);
  begin
    MapPoint(AX, AY, State, PX, PY);
    SetLength(O[0].Pts, Length(O[0].Pts) + 1);
    O[0].Pts[High(O[0].Pts)] := MakePt(PX, PY);
  end;

begin
  O := nil;
  N := LowerCase(ANode.NodeName);
  if N = 'rect' then
  begin
    X := StrToFloatSafe(GetAttr(ANode, 'x', '0'), 0);
    Y := StrToFloatSafe(GetAttr(ANode, 'y', '0'), 0);
    W := StrToFloatSafe(GetAttr(ANode, 'width', '0'), 0);
    H := StrToFloatSafe(GetAttr(ANode, 'height', '0'), 0);
    Add1(True);
    AddPt(X, Y); AddPt(X + W, Y); AddPt(X + W, Y + H); AddPt(X, Y + H);
  end
  else if (N = 'circle') or (N = 'ellipse') then
  begin
    CX := StrToFloatSafe(GetAttr(ANode, 'cx', '0'), 0);
    CY := StrToFloatSafe(GetAttr(ANode, 'cy', '0'), 0);
    if N = 'circle' then
    begin
      RX := StrToFloatSafe(GetAttr(ANode, 'r', '0'), 0); RY := RX;
    end
    else
    begin
      RX := StrToFloatSafe(GetAttr(ANode, 'rx', '0'), 0);
      RY := StrToFloatSafe(GetAttr(ANode, 'ry', '0'), 0);
    end;
    Circ := 2 * Pi * Math.Max(RX, RY) * SvgPixelScale(State);
    Cnt := EnsureRange(Round(Circ / 3), 24, 720);
    Add1(True);
    for I := 0 to Cnt - 1 do
    begin
      T := 2 * Pi * I / Cnt;
      AddPt(CX + RX * Cos(T), CY + RY * Sin(T));
    end;
  end
  else if N = 'line' then
  begin
    Add1(False);
    AddPt(StrToFloatSafe(GetAttr(ANode, 'x1', '0'), 0), StrToFloatSafe(GetAttr(ANode, 'y1', '0'), 0));
    AddPt(StrToFloatSafe(GetAttr(ANode, 'x2', '0'), 0), StrToFloatSafe(GetAttr(ANode, 'y2', '0'), 0));
  end
  else if (N = 'polyline') or (N = 'polygon') then
  begin
    Parts := SplitNumbers(GetAttr(ANode, 'points', ''));
    try
      Add1(N = 'polygon');
      for I := 0 to Parts.Count div 2 - 1 do
        AddPt(StrToFloatSafe(Parts[I * 2], 0), StrToFloatSafe(Parts[I * 2 + 1], 0));
    finally
      Parts.Free;
    end;
  end
  else if N = 'path' then
    DrawPath(ANode, nil, State, @O);
  Result := Length(O) > 0;
end;

// Clip region of a <clipPath> for an element drawn with State.
function SvgClipRegion(ClipNode: TDOMNode; const State: TRenderState): HRGN;
var
  C: TDOMNode;
  CS: TRenderState;
  O: TSvgOutline;
  R: HRGN;
  Rule: string;
begin
  Result := CreateRectRgn(0, 0, 0, 0);
  C := ClipNode.FirstChild;
  while C <> nil do
  begin
    if C is TDOMElement then
    begin
      CS := State;
      CS.CTM := MatMul(MatMul(State.CTM, ParseTransform(GetAttr(ClipNode, 'transform', ''))),
                       ParseTransform(GetAttr(C, 'transform', '')));
      if SvgElementOutline(C, CS, O) then
      begin
        Rule := LowerCase(Trim(GetAttrOrStyle(C, 'clip-rule', 'nonzero')));
        R := SvgOutlineRegion(O, Rule <> 'evenodd');
        CombineRgn(Result, Result, R, RGN_OR);
        DeleteObject(R);
      end;
    end;
    C := C.NextSibling;
  end;
end;

// Does this shape need the outline painter (pattern fill or dashed stroke)?
function SvgNeedsAdvanced(ANode: TDOMNode; const State: TRenderState): Boolean;
var Dashes: TSvgDoubles; Off: Double;
begin
  Result := (SvgPatternRef(ANode) <> nil) or
    ((LowerCase(Trim(GetAttrOrStyle(ANode, 'stroke', 'none'))) <> 'none') and
     SvgDashArray(ANode, State, Dashes, Off));
end;

// Paints a basic shape through its outline: solid or pattern fill, solid or
// dashed stroke.
procedure SvgPaintElement(ANode: TDOMNode; ACanvas: TCanvas; const State: TRenderState);
var
  O: TSvgOutline;
  BB: TRect;
  Dashes: TSvgDoubles;
  Off: Double;
  I: Integer;
  NonZero, HasFill, HasStroke, Dashed: Boolean;
  FillColor: TColor;
  Saved: HRGN;
begin
  if not SvgElementOutline(ANode, State, O) then Exit;
  ApplyStyle(ANode, ACanvas, State);
  HasFill := (ACanvas.Brush.Style <> bsClear) and (LowerCase(ANode.NodeName) <> 'line') and
             (LowerCase(ANode.NodeName) <> 'polyline');
  HasStroke := ACanvas.Pen.Style <> psClear;
  FillColor := ACanvas.Brush.Color;
  NonZero := LowerCase(Trim(GetAttrOrStyle(ANode, 'fill-rule', 'nonzero'))) <> 'evenodd';

  if HasFill then
  begin
    if SvgPatternRef(ANode) <> nil then
      SvgPatternFill(ANode, ACanvas, State, O, NonZero)
    else if SvgOutlineBounds(O, BB) then
    begin
      Saved := SvgPushClip(ACanvas, SvgOutlineRegion(O, NonZero));
      try
        ACanvas.Brush.Style := bsSolid;
        ACanvas.Brush.Color := FillColor;
        ACanvas.FillRect(BB);
      finally
        SvgPopClip(ACanvas, Saved);
      end;
    end;
  end;

  if HasStroke then
  begin
    Dashed := SvgDashArray(ANode, State, Dashes, Off);
    ACanvas.Brush.Style := bsClear;
    for I := 0 to High(O) do
      if Dashed then SvgDashStroke(ACanvas, O[I].Pts, O[I].Closed, Dashes, Off)
      else if O[I].Closed then ACanvas.Polygon(O[I].Pts)
      else ACanvas.Polyline(O[I].Pts);
  end;
end;


// ---------------------------------------------------------------------------
// <text> / <tspan>
//
// A text element is split into runs: its own character data and each <tspan>.
// A run that sets x or y starts a new "chunk" (SVG text chunk); text-anchor is
// applied per chunk. A list of x (and y) values positions the characters one
// by one, which is how per-glyph spacing (e.g. from GDI metafiles) is kept.
// Positions are tracked in bitmap pixels along the (possibly rotated) baseline.
// ---------------------------------------------------------------------------

type
  TTextRun = record
    Text: string;          // UTF-8
    Node: TDOMNode;        // element whose style applies (text or tspan)
    HasX, HasY: Boolean;
    X, Y: Double;          // user units of Node's coordinate system
  end;

function SvgFontFamily(const S: string): string;
var
  T: string;
  P: Integer;
begin
  T := Trim(S);
  P := Pos(',', T);
  if P > 0 then T := Trim(Copy(T, 1, P - 1));
  if (Length(T) >= 2) and (T[1] in ['''', '"']) then T := Copy(T, 2, Length(T) - 2);
  T := Trim(T);
  case LowerCase(T) of
    '', 'sans-serif': Result := 'Arial';
    'serif':          Result := 'Times New Roman';
    'monospace':      Result := 'Courier New';
    'cursive':        Result := 'Comic Sans MS';
    'fantasy':        Result := 'Impact';
  else
    Result := T;
  end;
end;

// Collapses whitespace the way SVG does without xml:space="preserve".
function SvgCollapseText(const S: string; Preserve: Boolean): string;
var
  I: Integer;
  C: Char;
  LastSpace: Boolean;
begin
  if Preserve then
  begin
    Result := StringReplace(S, #13#10, ' ', [rfReplaceAll]);
    Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
    Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
    Result := StringReplace(Result, #9, ' ', [rfReplaceAll]);
    Exit;
  end;
  Result := '';
  LastSpace := False;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C in [#9, #10, #13, ' '] then
    begin
      if not LastSpace then Result := Result + ' ';
      LastSpace := True;
    end
    else
    begin
      Result := Result + C;
      LastSpace := False;
    end;
  end;
end;

function SvgPreserveSpace(ANode: TDOMNode): Boolean;
var
  N: TDOMNode;
  V: string;
begin
  Result := False;
  N := ANode;
  while (N <> nil) and (N is TDOMElement) do
  begin
    V := GetAttr(N, 'xml:space', '');
    if V <> '' then Exit(V = 'preserve');
    N := N.ParentNode;
  end;
end;

// Number of UTF-8 characters and the byte range of character K (1-based).
function Utf8CharCount(const S: string): Integer;
var I: Integer;
begin
  Result := 0;
  for I := 1 to Length(S) do
    if (Ord(S[I]) and $C0) <> $80 then Inc(Result);
end;

function Utf8CharAt(const S: string; K: Integer): string;
var I, N, Start: Integer;
begin
  Result := '';
  N := 0; Start := 0;
  for I := 1 to Length(S) do
    if (Ord(S[I]) and $C0) <> $80 then
    begin
      Inc(N);
      if N = K then Start := I
      else if N = K + 1 then Exit(Copy(S, Start, I - Start));
    end;
  if Start > 0 then Result := Copy(S, Start, Length(S) - Start + 1);
end;

// Selects the run's font on the canvas. Returns False if the fill is none.
function SvgApplyFont(ANode: TDOMNode; ACanvas: TCanvas; const State: TRenderState;
  out AngleRad: Double): Boolean;
var
  Size, CTMScale, ViewScale: Double;
  W, Deco, St: string;
  FillColor: TColor;
  Styles: TFontStyles;
begin
  FillColor := ParseSVGColor(GetAttrOrStyle(ANode, 'fill', 'black'), clBlack);
  Result := FillColor <> clNone;

  Size := StrToFloatSafe(GetAttrOrStyle(ANode, 'font-size', '16'), 16);
  CTMScale  := Sqrt(Abs(State.CTM.A * State.CTM.D - State.CTM.B * State.CTM.C));
  ViewScale := Sqrt((State.BitmapW / Math.Max(State.ViewW, 1e-12)) *
                    (State.BitmapH / Math.Max(State.ViewH, 1e-12)));
  Size := Size * CTMScale * ViewScale;

  ACanvas.Font.Name := SvgFontFamily(GetAttrOrStyle(ANode, 'font-family', 'sans-serif'));
  ACanvas.Font.Height := -Max(1, Round(Size));    // negative = em size, like SVG
  ACanvas.Font.Color := FillColor;

  Styles := [];
  W := LowerCase(Trim(GetAttrOrStyle(ANode, 'font-weight', 'normal')));
  if (W = 'bold') or (W = 'bolder') or (StrToIntDef(W, 400) >= 600) then Include(Styles, fsBold);
  St := LowerCase(Trim(GetAttrOrStyle(ANode, 'font-style', 'normal')));
  if (St = 'italic') or (St = 'oblique') then Include(Styles, fsItalic);
  Deco := LowerCase(GetAttrOrStyle(ANode, 'text-decoration', ''));
  if Pos('underline', Deco) > 0 then Include(Styles, fsUnderline);
  if Pos('line-through', Deco) > 0 then Include(Styles, fsStrikeOut);
  ACanvas.Font.Style := Styles;

  // SVG y points down, so a positive angle turns clockwise on screen;
  // LCL's Orientation (tenths of a degree) turns counter-clockwise.
  AngleRad := ArcTan2(State.CTM.B, State.CTM.A);
  ACanvas.Font.Orientation := -Round(RadToDeg(AngleRad) * 10);
end;

procedure DrawTextElement(ANode: TDOMNode; ACanvas: TCanvas; const State: TRenderState);
var
  Runs: array of TTextRun;
  Preserve: Boolean;

  procedure AddRun(const S: string; N: TDOMNode; HX, HY: Boolean; X, Y: Double);
  begin
    if (S = '') and not (HX or HY) then Exit;
    SetLength(Runs, Length(Runs) + 1);
    Runs[High(Runs)].Text := S;
    Runs[High(Runs)].Node := N;
    Runs[High(Runs)].HasX := HX; Runs[High(Runs)].HasY := HY;
    Runs[High(Runs)].X := X; Runs[High(Runs)].Y := Y;
  end;

  // Splits the character data of Owner (text or tspan) into runs, honouring
  // x/y lists (one position per character).
  procedure AddPositioned(const S: string; Owner: TDOMNode; First: Boolean);
  var
    XL, YL: TStringList;
    K, NC: Integer;
    HX, HY: Boolean;
    X, Y: Double;
  begin
    XL := SplitNumbers(GetAttr(Owner, 'x', ''));
    YL := SplitNumbers(GetAttr(Owner, 'y', ''));
    try
      if not First then
      begin
        AddRun(S, Owner, False, False, 0, 0);
        Exit;
      end;
      NC := Utf8CharCount(S);
      if (XL.Count <= 1) and (YL.Count <= 1) then
      begin
        HX := XL.Count = 1; HY := YL.Count = 1;
        if HX then X := StrToFloatSafe(XL[0], 0) else X := 0;
        if HY then Y := StrToFloatSafe(YL[0], 0) else Y := 0;
        AddRun(S, Owner, HX, HY, X, Y);
        Exit;
      end;
      // per-character positions; characters past the lists continue the chunk
      for K := 1 to NC do
      begin
        HX := K <= XL.Count; HY := K <= YL.Count;
        if HX then X := StrToFloatSafe(XL[K - 1], 0) else X := 0;
        if HY then Y := StrToFloatSafe(YL[K - 1], 0) else Y := 0;
        AddRun(Utf8CharAt(S, K), Owner, HX, HY, X, Y);
      end;
    finally
      XL.Free; YL.Free;
    end;
  end;

  procedure Collect(Owner: TDOMNode);
  var
    C: TDOMNode;
    FirstData: Boolean;
    S: string;
  begin
    FirstData := True;
    C := Owner.FirstChild;
    while C <> nil do
    begin
      if (C.NodeType = TEXT_NODE) or (C.NodeType = CDATA_SECTION_NODE) then
      begin
        S := SvgCollapseText(UTF8Encode(C.NodeValue), Preserve);
        if S <> '' then
        begin
          AddPositioned(S, Owner, FirstData);
          FirstData := False;
        end;
      end
      else if (C is TDOMElement) and (LowerCase(C.NodeName) = 'tspan') then
      begin
        Collect(C);
        FirstData := False;
      end;
      C := C.NextSibling;
    end;
  end;

var
  I, J, ChunkEnd, PX, PY: Integer;
  UPenX, UPenY, Width, Angle, UX, UY, DX, DY, Base, PxPerUnit, ViewScale: Double;
  Anchor, BaseLine: string;
  TM: TLCLTextMetric;
begin
  Runs := nil;
  Preserve := SvgPreserveSpace(ANode);
  Collect(ANode);
  if Length(Runs) = 0 then Exit;
  // leading / trailing blanks of the whole element are dropped (SVG rule)
  if not Preserve then
  begin
    Runs[0].Text := TrimLeft(Runs[0].Text);
    Runs[High(Runs)].Text := TrimRight(Runs[High(Runs)].Text);
  end;

  // pen position is kept in the element's user units (tspans share its
  // transform), text advances are measured in pixels and converted back
  ViewScale := Sqrt((State.BitmapW / Math.Max(State.ViewW, 1e-12)) *
                    (State.BitmapH / Math.Max(State.ViewH, 1e-12)));
  PxPerUnit := Sqrt(Abs(State.CTM.A * State.CTM.D - State.CTM.B * State.CTM.C)) * ViewScale;
  if PxPerUnit < 1e-12 then Exit;

  ACanvas.Brush.Style := bsClear;
  UPenX := 0; UPenY := 0;
  I := 0;
  while I <= High(Runs) do
  begin
    // a chunk: this run plus following runs without their own position
    ChunkEnd := I;
    while (ChunkEnd < High(Runs)) and not (Runs[ChunkEnd + 1].HasX or Runs[ChunkEnd + 1].HasY) do
      Inc(ChunkEnd);
    if Runs[I].HasX then UPenX := Runs[I].X;       // an absent coordinate keeps
    if Runs[I].HasY then UPenY := Runs[I].Y;       // the current pen position

    // measure the chunk for text-anchor
    Width := 0;
    Angle := 0;
    for J := I to ChunkEnd do
    begin
      SvgApplyFont(Runs[J].Node, ACanvas, State, Angle);
      Width := Width + ACanvas.TextWidth(Runs[J].Text);
    end;
    Anchor := LowerCase(Trim(GetAttrOrStyle(Runs[I].Node, 'text-anchor', 'start')));
    if Anchor = 'middle' then UPenX := UPenX - Width / 2 / PxPerUnit
    else if Anchor = 'end' then UPenX := UPenX - Width / PxPerUnit;

    for J := I to ChunkEnd do
    begin
      if SvgApplyFont(Runs[J].Node, ACanvas, State, Angle) and (Runs[J].Text <> '') then
      begin
        if not ACanvas.GetTextMetrics(TM) then
        begin
          TM.Ascender := ACanvas.TextHeight('Ag') * 4 div 5;
          TM.Descender := ACanvas.TextHeight('Ag') - TM.Ascender;
        end;
        // distance from the reference point down to the top of the text cell
        BaseLine := LowerCase(Trim(GetAttrOrStyle(Runs[J].Node, 'dominant-baseline', '')));
        if (BaseLine = 'hanging') or (BaseLine = 'text-before-edge') then Base := 0
        else if (BaseLine = 'text-after-edge') or (BaseLine = 'ideographic') then
          Base := TM.Ascender + TM.Descender
        else if (BaseLine = 'central') or (BaseLine = 'middle') then
          Base := (TM.Ascender + TM.Descender) / 2
        else
          Base := TM.Ascender;                    // alphabetic baseline
        MapPoint(UPenX, UPenY, State, PX, PY);
        UX := Cos(Angle); UY := Sin(Angle);       // baseline direction (y down)
        DX := -UY; DY := UX;                      // "down", across the baseline
        ACanvas.TextOut(Round(PX - DX * Base), Round(PY - DY * Base), Runs[J].Text);
      end;
      UPenX := UPenX + ACanvas.TextWidth(Runs[J].Text) / PxPerUnit;
    end;
    I := ChunkEnd + 1;
  end;
  ACanvas.Font.Orientation := 0;
end;

procedure RenderNodeInner(ANode: TDOMNode; ACanvas: TCanvas; const ParentState: TRenderState);
var
  N: string;
  X, Y, W, H: Double;
  CX, CY, R, RX, RY: Double;
  X1, Y1, X2, Y2: Double;
  Child: TDOMNode;
  State: TRenderState;
  LocalM: TMatrix2D;
  PX1, PY1, PX2, PY2: Integer;
begin
  if ANode = nil then Exit;

  State := ParentState;

  // Compose parent CTM with this node's local transform
  LocalM := ParseTransform(GetAttr(ANode, 'transform', ''));
  State.CTM := MatMul(ParentState.CTM, LocalM);

  N := LowerCase(ANode.NodeName);

  if ((N = 'rect') or (N = 'circle') or (N = 'ellipse') or (N = 'line') or
      (N = 'polyline') or (N = 'polygon')) and SvgNeedsAdvanced(ANode, State) then
  begin
    SvgPaintElement(ANode, ACanvas, State);
  end
  else if N = 'rect' then
  begin
    ApplyStyle(ANode, ACanvas, State);
    X := StrToFloatSafe(GetAttr(ANode, 'x', '0'), 0);
    Y := StrToFloatSafe(GetAttr(ANode, 'y', '0'), 0);
    W := StrToFloatSafe(GetAttr(ANode, 'width', '0'), 0);
    H := StrToFloatSafe(GetAttr(ANode, 'height', '0'), 0);

    MapPoint(X,     Y,     State, PX1, PY1);
    MapPoint(X + W, Y + H, State, PX2, PY2);
    ACanvas.Rectangle(
      Min(PX1, PX2), Min(PY1, PY2),
      Max(PX1, PX2), Max(PY1, PY2)
    );
  end
  else if N = 'circle' then
  begin
    ApplyStyle(ANode, ACanvas, State);
    CX := StrToFloatSafe(GetAttr(ANode, 'cx', '0'), 0);
    CY := StrToFloatSafe(GetAttr(ANode, 'cy', '0'), 0);
    R  := StrToFloatSafe(GetAttr(ANode, 'r', '0'), 0);

    MapPoint(CX - R, CY - R, State, PX1, PY1);
    MapPoint(CX + R, CY + R, State, PX2, PY2);
    ACanvas.Ellipse(
      Min(PX1, PX2), Min(PY1, PY2),
      Max(PX1, PX2), Max(PY1, PY2)
    );
  end
  else if N = 'ellipse' then
  begin
    ApplyStyle(ANode, ACanvas, State);
    CX := StrToFloatSafe(GetAttr(ANode, 'cx', '0'), 0);
    CY := StrToFloatSafe(GetAttr(ANode, 'cy', '0'), 0);
    RX := StrToFloatSafe(GetAttr(ANode, 'rx', '0'), 0);
    RY := StrToFloatSafe(GetAttr(ANode, 'ry', '0'), 0);

    MapPoint(CX - RX, CY - RY, State, PX1, PY1);
    MapPoint(CX + RX, CY + RY, State, PX2, PY2);
    ACanvas.Ellipse(
      Min(PX1, PX2), Min(PY1, PY2),
      Max(PX1, PX2), Max(PY1, PY2)
    );
  end
  else if N = 'line' then
  begin
    ApplyStyle(ANode, ACanvas, State);
    X1 := StrToFloatSafe(GetAttr(ANode, 'x1', '0'), 0);
    Y1 := StrToFloatSafe(GetAttr(ANode, 'y1', '0'), 0);
    X2 := StrToFloatSafe(GetAttr(ANode, 'x2', '0'), 0);
    Y2 := StrToFloatSafe(GetAttr(ANode, 'y2', '0'), 0);

    MapPoint(X1, Y1, State, PX1, PY1);
    MapPoint(X2, Y2, State, PX2, PY2);
    ACanvas.Line(PX1, PY1, PX2, PY2);
  end
  else if N = 'polyline' then
  begin
    DrawPolylineOrPolygon(ANode, ACanvas, State, False);
  end
  else if N = 'polygon' then
  begin
    DrawPolylineOrPolygon(ANode, ACanvas, State, True);
  end
  else if N = 'path' then
  begin
    DrawPath(ANode, ACanvas, State);
  end
  else if N = 'text' then
  begin
    DrawTextElement(ANode, ACanvas, State);
  end
  else if (N = 'svg') or (N = 'g') then
  begin
    Child := ANode.FirstChild;
    while Child <> nil do
    begin
      if Child is TDOMElement then
        RenderNode(Child, ACanvas, State);
      Child := Child.NextSibling;
    end;
  end;
end;

// Opacity of a shape: opacity x fill-opacity (filled) or x stroke-opacity.
function SvgShapeAlpha(ANode: TDOMNode): Double;
var Op, Sub: Double; Fill: string;
begin
  Op := StrToFloatSafe(GetAttr(ANode, 'opacity', ''), 1);
  if GetStyleProp(GetAttr(ANode, 'style', ''), 'opacity') <> '' then
    Op := StrToFloatSafe(GetStyleProp(GetAttr(ANode, 'style', ''), 'opacity'), 1);
  Fill := LowerCase(Trim(GetAttrOrStyle(ANode, 'fill', 'black')));
  if (Fill <> 'none') and (LowerCase(ANode.NodeName) <> 'line') and (LowerCase(ANode.NodeName) <> 'polyline') then
    Sub := StrToFloatSafe(GetAttrOrStyle(ANode, 'fill-opacity', '1'), 1)
  else
    Sub := StrToFloatSafe(GetAttrOrStyle(ANode, 'stroke-opacity', '1'), 1);
  Result := EnsureRange(Op, 0, 1) * EnsureRange(Sub, 0, 1);
end;

// Draws a translucent shape: snapshot, draw opaque, blend the change back.
procedure SvgRenderBlended(ANode: TDOMNode; ACanvas: TCanvas; const ParentState: TRenderState;
  Alpha: Double);
var
  CS: TRenderState;
  O: TSvgOutline;
  BB: TRect;
  Margin, X, Y: Integer;
  Before, After: TBitmap;
  IB, IA: TLazIntfImage;
  CB, CA: TFPColor;
  A16: Integer;
begin
  CS := ParentState;
  CS.CTM := MatMul(ParentState.CTM, ParseTransform(GetAttr(ANode, 'transform', '')));
  if not (SvgElementOutline(ANode, CS, O) and SvgOutlineBounds(O, BB)) then
  begin
    if LowerCase(ANode.NodeName) <> 'text' then
    begin
      RenderNodeInner(ANode, ACanvas, ParentState);
      Exit;
    end;
    BB := Rect(0, 0, CS.BitmapW, CS.BitmapH);   // text: no outline, blend the whole picture
  end;
  Margin := 2 + Ceil(StrToFloatSafe(GetAttrOrStyle(ANode, 'stroke-width', '1'), 1) * SvgPixelScale(CS));
  BB.Left := Max(0, BB.Left - Margin); BB.Top := Max(0, BB.Top - Margin);
  BB.Right := Min(CS.BitmapW, BB.Right + Margin); BB.Bottom := Min(CS.BitmapH, BB.Bottom + Margin);
  if (BB.Right <= BB.Left) or (BB.Bottom <= BB.Top) then Exit;
  Before := TBitmap.Create; After := TBitmap.Create;
  IB := nil; IA := nil;
  try
    Before.PixelFormat := pf24bit; Before.SetSize(BB.Right - BB.Left, BB.Bottom - BB.Top);
    Before.Canvas.CopyRect(Rect(0, 0, Before.Width, Before.Height), ACanvas, BB);
    RenderNodeInner(ANode, ACanvas, ParentState);
    After.PixelFormat := pf24bit; After.SetSize(Before.Width, Before.Height);
    After.Canvas.CopyRect(Rect(0, 0, After.Width, After.Height), ACanvas, BB);
    IB := Before.CreateIntfImage; IA := After.CreateIntfImage;
    A16 := Round(Alpha * 65536);
    for Y := 0 to IA.Height - 1 do
      for X := 0 to IA.Width - 1 do
      begin
        CB := IB.Colors[X, Y]; CA := IA.Colors[X, Y];
        if (CA.Red <> CB.Red) or (CA.Green <> CB.Green) or (CA.Blue <> CB.Blue) then
        begin
          CA.Red := CB.Red + Integer((Int64(CA.Red) - CB.Red) * A16 div 65536);
          CA.Green := CB.Green + Integer((Int64(CA.Green) - CB.Green) * A16 div 65536);
          CA.Blue := CB.Blue + Integer((Int64(CA.Blue) - CB.Blue) * A16 div 65536);
          IA.Colors[X, Y] := CA;
        end;
      end;
    After.LoadFromIntfImage(IA);
    ACanvas.Draw(BB.Left, BB.Top, After);
  finally
    IB.Free; IA.Free;
    Before.Free; After.Free;
  end;
end;

// clip-path and opacity wrapper around RenderNodeInner
procedure RenderNode(ANode: TDOMNode; ACanvas: TCanvas; const ParentState: TRenderState);
var
  ClipRef, N: string;
  ClipNode: TDOMNode;
  CS: TRenderState;
  Saved: HRGN;
  Alpha: Double;
begin
  if ANode = nil then Exit;
  N := LowerCase(ANode.NodeName);
  Alpha := 1;
  if (N = 'rect') or (N = 'circle') or (N = 'ellipse') or (N = 'line') or (N = 'polyline') or
     (N = 'polygon') or (N = 'path') or (N = 'text') then
  begin
    Alpha := SvgShapeAlpha(ANode);
    if Alpha <= 0.002 then Exit;               // fully transparent
  end;
  ClipRef := GetAttr(ANode, 'clip-path', '');
  if ClipRef = '' then ClipRef := GetStyleProp(GetAttr(ANode, 'style', ''), 'clip-path');
  ClipNode := nil;
  if (ClipRef <> '') and (LowerCase(ClipRef) <> 'none') then
  begin
    ClipNode := SvgFindById(ClipRef);
    if (ClipNode <> nil) and (LowerCase(ClipNode.NodeName) <> 'clippath') then ClipNode := nil;
  end;
  Saved := 0;
  if ClipNode <> nil then
  begin
    CS := ParentState;
    CS.CTM := MatMul(ParentState.CTM, ParseTransform(GetAttr(ANode, 'transform', '')));
    Saved := SvgPushClip(ACanvas, SvgClipRegion(ClipNode, CS));
  end;
  try
    if Alpha < 0.998 then SvgRenderBlended(ANode, ACanvas, ParentState, Alpha)
    else RenderNodeInner(ANode, ACanvas, ParentState);
  finally
    if ClipNode <> nil then SvgPopClip(ACanvas, Saved);
  end;
end;

function RenderSimpleSVGToBitmap(const ASVGText: string; ABitmap: TBitmap): Boolean;
var
  SS: TStringStream;
  Doc: TXMLDocument;
  Root: TDOMNode;
  Parser: TDOMParser;
  Src: TXMLInputSource;
  State: TRenderState;
  W, H: Integer;
begin
  Result := False;
  if ABitmap = nil then Exit;

  SS := TStringStream.Create(ASVGText);
  Doc := nil;
  try
    // Keep whitespace-only text nodes: in <text> they separate words
    // (e.g. the space between two <tspan>s).
    Parser := TDOMParser.Create;
    Src := TXMLInputSource.Create(SS);
    try
      Parser.Options.PreserveWhitespace := True;
      Parser.Parse(Src, Doc);
    finally
      Src.Free;
      Parser.Free;
    end;
    if Doc = nil then Exit;

    Root := Doc.DocumentElement;
    if (Root = nil) or (LowerCase(Root.NodeName) <> 'svg') then
      Exit;

    W := ParseIntSafe(GetAttr(Root, 'width', '0'), 0);
    H := ParseIntSafe(GetAttr(Root, 'height', '0'), 0);

    if GetAttr(Root, 'viewBox', '') <> '' then
      ParseViewBox(GetAttr(Root, 'viewBox', ''), State.ViewX, State.ViewY, State.ViewW, State.ViewH)
    else
    begin
      State.ViewX := 0;
      State.ViewY := 0;
      State.ViewW := W;
      State.ViewH := H;
    end;

    if ABitmap.Width <= 0 then
      ABitmap.Width := Max(W, 1);
    if ABitmap.Height <= 0 then
      ABitmap.Height := Max(H, 1);

    if State.ViewW <= 0 then State.ViewW := ABitmap.Width;
    if State.ViewH <= 0 then State.ViewH := ABitmap.Height;

    State.BitmapW := ABitmap.Width;
    State.BitmapH := ABitmap.Height;
    State.CTM := IdentityMatrix;

    ABitmap.Canvas.Brush.Style := bsSolid;
    ABitmap.Canvas.Brush.Color := clWhite;
    ABitmap.Canvas.FillRect(Rect(0, 0, ABitmap.Width, ABitmap.Height));

    if CSSClassStyles <> nil then
      CSSClassStyles.Clear;
    CollectCSSStyles(Root);

    if SvgIds = nil then SvgIds := TStringList.Create;
    SvgIds.Clear;
    SvgCollectIds(Root);

    RenderNode(Root, ABitmap.Canvas, State);
    Result := True;
  finally
    Doc.Free;
    SS.Free;
  end;
end;


finalization
  CSSClassStyles.Free;
  SvgIds.Free;

end.
