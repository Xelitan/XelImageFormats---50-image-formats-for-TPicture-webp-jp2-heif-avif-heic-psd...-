unit XelMvg;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	MVG (Magick Vector Graphics) -> SVG translator                //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// MVG is ImageMagick's textual drawing language (one command per line). Its
// drawing model - push/pop graphic-context, fill/stroke/stroke-width, affine
// transforms, and shapes whose "path" data is SVG-identical - maps directly to
// SVG. This unit converts an MVG document to an SVG document; the wrapper then
// rasterises that SVG with the project's SimpleSVG renderer.

interface

uses
  SysUtils, Classes, Math;

function MvgToSvg(const Mvg: string): string;

implementation

type
  TGState = record
    Fill, Stroke, StrokeWidth, FontSize, FillOpacity: string;
  end;

// Splits one MVG line into tokens: whitespace separates, single quotes group.
procedure TokenizeLine(const Line: string; Dest: TStringList);
var
  I, L: Integer;
  Cur: string;
  InQuote: Boolean;
begin
  Dest.Clear;
  I := 1; L := Length(Line); Cur := ''; InQuote := False;
  while I <= L do
  begin
    if InQuote then
    begin
      if Line[I] = '''' then begin Dest.Add(Cur); Cur := ''; InQuote := False; end
      else Cur := Cur + Line[I];
    end
    else if Line[I] = '''' then
      InQuote := True
    else if Line[I] in [' ', #9, #13, #10] then
    begin
      if Cur <> '' then begin Dest.Add(Cur); Cur := ''; end;
    end
    else
      Cur := Cur + Line[I];
    Inc(I);
  end;
  if Cur <> '' then Dest.Add(Cur);
end;

procedure SplitPair(const S: string; out X, Y: string);
var C: Integer;
begin
  C := Pos(',', S);
  if C > 0 then begin X := Copy(S, 1, C - 1); Y := Copy(S, C + 1, Length(S)); end
  else begin X := S; Y := '0'; end;
end;

function XmlEsc(const S: string): string;
var I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
    else Result := Result + S[I];
    end;
end;

function NumF(const S: string; Def: Double): Double;
var Code: Integer; V: Double; FS: TFormatSettings;
begin
  FS := DefaultFormatSettings; FS.DecimalSeparator := '.'; FS.ThousandSeparator := #0;
  Val(Trim(S), V, Code);
  if Code = 0 then Result := V else Result := Def;
end;

function MvgToSvg(const Mvg: string): string;
var
  Lines, Tk: TStringList;
  Li, Depth, GroupsOpen: Integer;
  GStack: array of TGState;
  GS: TGState;
  OpenCount: array of Integer;    // groups opened per push-context (for pop)
  Cmd, x1, y1, x2, y2, xs, ys: string;
  vbX, vbY, vbW, vbH: string;
  Body: string;
  HasVB: Boolean;
  j: Integer;

  function ShapeAttrs: string;
  begin
    Result := ' fill="' + XmlEsc(GS.Fill) + '" stroke="' + XmlEsc(GS.Stroke) +
              '" stroke-width="' + XmlEsc(GS.StrokeWidth) + '"';
    if GS.FillOpacity <> '' then Result := Result + ' fill-opacity="' + XmlEsc(GS.FillOpacity) + '"';
  end;

begin
  Lines := TStringList.Create;
  Tk := TStringList.Create;
  try
    Lines.Text := Mvg;
    // defaults
    GS.Fill := 'black'; GS.Stroke := 'none'; GS.StrokeWidth := '1';
    GS.FontSize := '16'; GS.FillOpacity := '';
    vbX := '0'; vbY := '0'; vbW := '0'; vbH := '0'; HasVB := False;
    Body := '';
    SetLength(GStack, 0); SetLength(OpenCount, 0);
    Depth := 0; GroupsOpen := 0;

    for Li := 0 to Lines.Count - 1 do
    begin
      TokenizeLine(Lines[Li], Tk);
      if Tk.Count = 0 then Continue;
      Cmd := LowerCase(Tk[0]);

      if Cmd = 'push' then
      begin
        SetLength(GStack, Length(GStack) + 1); GStack[High(GStack)] := GS;
        SetLength(OpenCount, Length(OpenCount) + 1); OpenCount[High(OpenCount)] := 1;
        Body := Body + '<g>';
        Inc(Depth); Inc(GroupsOpen);
      end
      else if Cmd = 'pop' then
      begin
        if Depth > 0 then
        begin
          while OpenCount[High(OpenCount)] > 0 do
          begin Body := Body + '</g>'; Dec(OpenCount[High(OpenCount)]); Dec(GroupsOpen); end;
          SetLength(OpenCount, Length(OpenCount) - 1);
          GS := GStack[High(GStack)]; SetLength(GStack, Length(GStack) - 1);
          Dec(Depth);
        end;
      end
      else if (Cmd = 'viewbox') and (Tk.Count >= 5) then
      begin
        vbX := Tk[1]; vbY := Tk[2]; vbW := Tk[3]; vbH := Tk[4]; HasVB := True;
      end
      else if (Cmd = 'affine') and (Tk.Count >= 7) then
      begin
        Body := Body + '<g transform="matrix(' + Tk[1] + ' ' + Tk[2] + ' ' +
                Tk[3] + ' ' + Tk[4] + ' ' + Tk[5] + ' ' + Tk[6] + ')">';
        if Length(OpenCount) > 0 then Inc(OpenCount[High(OpenCount)]);
        Inc(GroupsOpen);
      end
      else if (Cmd = 'translate') and (Tk.Count >= 3) then
      begin
        Body := Body + '<g transform="translate(' + Tk[1] + ' ' + Tk[2] + ')">';
        if Length(OpenCount) > 0 then Inc(OpenCount[High(OpenCount)]);
        Inc(GroupsOpen);
      end
      else if (Cmd = 'scale') and (Tk.Count >= 3) then
      begin
        Body := Body + '<g transform="scale(' + Tk[1] + ' ' + Tk[2] + ')">';
        if Length(OpenCount) > 0 then Inc(OpenCount[High(OpenCount)]);
        Inc(GroupsOpen);
      end
      else if (Cmd = 'rotate') and (Tk.Count >= 2) then
      begin
        Body := Body + '<g transform="rotate(' + Tk[1] + ')">';
        if Length(OpenCount) > 0 then Inc(OpenCount[High(OpenCount)]);
        Inc(GroupsOpen);
      end
      else if (Cmd = 'fill') and (Tk.Count >= 2) then GS.Fill := Tk[1]
      else if (Cmd = 'stroke') and (Tk.Count >= 2) then GS.Stroke := Tk[1]
      else if (Cmd = 'stroke-width') and (Tk.Count >= 2) then GS.StrokeWidth := Tk[1]
      else if (Cmd = 'font-size') and (Tk.Count >= 2) then GS.FontSize := Tk[1]
      else if (Cmd = 'fill-opacity') and (Tk.Count >= 2) then GS.FillOpacity := Tk[1]
      else if (Cmd = 'rectangle') and (Tk.Count >= 3) then
      begin
        SplitPair(Tk[1], x1, y1); SplitPair(Tk[2], x2, y2);
        Body := Body + Format('<rect x="%g" y="%g" width="%g" height="%g"%s/>',
          [Min(NumF(x1,0),NumF(x2,0)), Min(NumF(y1,0),NumF(y2,0)),
           Abs(NumF(x2,0)-NumF(x1,0)), Abs(NumF(y2,0)-NumF(y1,0)), ShapeAttrs]);
      end
      else if (Cmd = 'roundrectangle') and (Tk.Count >= 4) then
      begin
        SplitPair(Tk[1], x1, y1); SplitPair(Tk[2], x2, y2); SplitPair(Tk[3], xs, ys);
        Body := Body + Format('<rect x="%g" y="%g" width="%g" height="%g" rx="%g" ry="%g"%s/>',
          [Min(NumF(x1,0),NumF(x2,0)), Min(NumF(y1,0),NumF(y2,0)),
           Abs(NumF(x2,0)-NumF(x1,0)), Abs(NumF(y2,0)-NumF(y1,0)),
           NumF(xs,0), NumF(ys,0), ShapeAttrs]);
      end
      else if (Cmd = 'circle') and (Tk.Count >= 3) then
      begin
        SplitPair(Tk[1], x1, y1); SplitPair(Tk[2], x2, y2);
        Body := Body + Format('<circle cx="%g" cy="%g" r="%g"%s/>',
          [NumF(x1,0), NumF(y1,0),
           Sqrt(Sqr(NumF(x2,0)-NumF(x1,0)) + Sqr(NumF(y2,0)-NumF(y1,0))), ShapeAttrs]);
      end
      else if (Cmd = 'ellipse') and (Tk.Count >= 3) then
      begin
        SplitPair(Tk[1], x1, y1); SplitPair(Tk[2], x2, y2);
        Body := Body + Format('<ellipse cx="%g" cy="%g" rx="%g" ry="%g"%s/>',
          [NumF(x1,0), NumF(y1,0), NumF(x2,0), NumF(y2,0), ShapeAttrs]);
      end
      else if (Cmd = 'line') and (Tk.Count >= 3) then
      begin
        SplitPair(Tk[1], x1, y1); SplitPair(Tk[2], x2, y2);
        Body := Body + Format('<line x1="%g" y1="%g" x2="%g" y2="%g" stroke="%s" stroke-width="%s"/>',
          [NumF(x1,0), NumF(y1,0), NumF(x2,0), NumF(y2,0), XmlEsc(GS.Stroke), XmlEsc(GS.StrokeWidth)]);
      end
      else if (Cmd = 'path') and (Tk.Count >= 2) then
        Body := Body + '<path d="' + XmlEsc(Tk[1]) + '"' + ShapeAttrs + '/>'
      else if (Cmd = 'polygon') and (Tk.Count >= 2) then
      begin
        xs := ''; for j := 1 to Tk.Count - 1 do xs := xs + Tk[j] + ' ';
        Body := Body + '<polygon points="' + XmlEsc(Trim(xs)) + '"' + ShapeAttrs + '/>';
      end
      else if (Cmd = 'text') and (Tk.Count >= 3) then
      begin
        SplitPair(Tk[1], x1, y1);
        Body := Body + Format('<text x="%g" y="%g" font-size="%s" fill="%s">%s</text>',
          [NumF(x1,0), NumF(y1,0), XmlEsc(GS.FontSize), XmlEsc(GS.Fill), XmlEsc(Tk[2])]);
      end;
      // unknown commands are ignored
    end;

    // close any groups still open
    while GroupsOpen > 0 do begin Body := Body + '</g>'; Dec(GroupsOpen); end;

    if not HasVB then begin vbX := '0'; vbY := '0'; vbW := '1000'; vbH := '1000'; end;
    Result := '<?xml version="1.0" encoding="UTF-8"?>'#10 +
      Format('<svg xmlns="http://www.w3.org/2000/svg" width="%g" height="%g" viewBox="%g %g %g %g">',
        [NumF(vbW,1000), NumF(vbH,1000), NumF(vbX,0), NumF(vbY,0), NumF(vbW,1000), NumF(vbH,1000)]) +
      Body + '</svg>';
  finally
    Tk.Free; Lines.Free;
  end;
end;

end.
