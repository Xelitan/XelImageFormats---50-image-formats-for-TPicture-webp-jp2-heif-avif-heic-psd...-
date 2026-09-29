program jbig2_cli;
//JBIG2 decoder in Pascal
//Author: www.xelitan.com
//License: Apache 2.0

{$mode delphi}{$H+}
uses
  SysUtils, Classes, FPImage, FPWritePNG, PdfJbig2;

function LoadFile(const fn: string): TBytes;
var fs: TFileStream;
begin
  fs := TFileStream.Create(fn, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

procedure SavePng(const fn: string; const gray: TBytes; w, h: Integer);
var img: TFPMemoryImage; wr: TFPWriterPNG; x, y, v: Integer; c: TFPColor;
begin
  img := TFPMemoryImage.Create(w, h);
  try
    for y := 0 to h - 1 do
      for x := 0 to w - 1 do
      begin
        v := gray[y * w + x];
        c.red := v shl 8 or v; c.green := c.red; c.blue := c.red; c.alpha := $FFFF;
        img.Colors[x, y] := c;
      end;
    wr := TFPWriterPNG.Create;
    try
      wr.Grayscale := True;
      img.SaveToFile(fn, wr);
    finally
      wr.Free;
    end;
  finally
    img.Free;
  end;
end;

var
  data, globals, gray: TBytes;
  w, h, i, black: Integer;
  inFn, outFn, globFn: string;
begin
  if ParamCount < 1 then
  begin
    Writeln('usage: jbig2_cli <file.jb2> [globals] [out.png]');
    Halt(1);
  end;
  inFn := ParamStr(1);
  globFn := '';
  if ParamCount >= 2 then globFn := ParamStr(2);
  if ParamCount >= 3 then outFn := ParamStr(3)
  else outFn := ChangeFileExt(inFn, '.png');

  data := LoadFile(inFn);
  if globFn <> '' then globals := LoadFile(globFn) else globals := nil;

  if not DecodeJBIG2(data, globals, w, h, gray) then
  begin
    Writeln('DECODE FAILED: ', LastJBIG2Error);
    Halt(2);
  end;

  black := 0;
  for i := 0 to Length(gray) - 1 do
    if gray[i] = 0 then Inc(black);

  Writeln(Format('OK  %dx%d  black=%d (%.1f%%)', [w, h, black, black * 100.0 / (w * h)]));
  SavePng(outFn, gray, w, h);
  Writeln('wrote ', outFn);
end.
