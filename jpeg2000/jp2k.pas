// JPEG 2000 based on JASPER 4.2.9
// License: JasPer-2.0 (similar to MIT )
// Author: www.xelitan.com
//
// =========================================================================
//  jp2k - command-line front end for the Free Pascal JPEG 2000 codec
//
//  Usage:
//    jp2k enc [options] <in.pgm|in.ppm> <out.jpc>
//    jp2k dec <in.jpc> <out.pgm|out.ppm>
//    jp2k gen <w> <h> <comps> <out.pgm|out.ppm>     (synthetic test image)
//
//  enc options:
//    -lossy            use the irreversible 9/7 path (default: lossless 5/3)
//    -step <f>         quantiser step for -lossy (default 1.0)
//    -levels <n>       DWT decomposition levels (default: auto)
//    -nomct            disable the colour transform for 3-component images
// =========================================================================
program jp2k;

{$mode delphi}
{$H+}

uses
  SysUtils, Classes, JP2KCommon, JP2KCodec, JP2KDecGen;

//  PNM (PGM/PPM) binary I/O 

function PnmReadToken(s: TStream): string;
var
  c: Byte;
  inComment: Boolean;
begin
  Result := '';
  inComment := False;
  // skip leading whitespace / comments 
  while s.Read(c, 1) = 1 do
  begin
    if inComment then
    begin
      if (c = 10) or (c = 13) then inComment := False;
      Continue;
    end;
    if c = Ord('#') then begin inComment := True; Continue; end;
    if (c = 32) or (c = 9) or (c = 10) or (c = 13) then Continue;
    Break;
  end;
  // accumulate token 
  repeat
    if (c = 32) or (c = 9) or (c = 10) or (c = 13) or (c = Ord('#')) then Break;
    Result := Result + Chr(c);
  until s.Read(c, 1) <> 1;
end;

function LoadPnm(const fn: string): TJp2kImage;
var
  fs: TFileStream;
  magic: string;
  w, h, mv, nc, i, c: Integer;
  raw: TBytes;
begin
  fs := TFileStream.Create(fn, fmOpenRead);
  try
    magic := PnmReadToken(fs);
    if magic = 'P5' then nc := 1
    else if magic = 'P6' then nc := 3
    else raise EJp2kError.Create('not a binary PGM/PPM file');
    w := StrToInt(PnmReadToken(fs));
    h := StrToInt(PnmReadToken(fs));
    mv := StrToInt(PnmReadToken(fs));
    if mv <> 255 then raise EJp2kError.Create('only 8-bit PNM supported');
    SetLength(raw, w * h * nc);
    fs.ReadBuffer(raw[0], w * h * nc);
  finally
    fs.Free;
  end;
  Result := TJp2kImage.Create(w, h, nc, 8);
  for i := 0 to w * h - 1 do
    for c := 0 to nc - 1 do
      Result.Comps[c][i] := raw[i * nc + c];
end;

procedure SavePnm(img: TJp2kImage; const fn: string);
var
  fs: TFileStream;
  hdr: AnsiString;
  raw: TBytes;
  i, c: Integer;
begin
  SetLength(raw, img.W * img.H * img.NumComps);
  for i := 0 to img.W * img.H - 1 do
    for c := 0 to img.NumComps - 1 do
      raw[i * img.NumComps + c] := img.Comps[c][i];
  fs := TFileStream.Create(fn, fmCreate);
  try
    if img.NumComps = 1 then hdr := 'P5' else hdr := 'P6';
    hdr := hdr + Format(#10'%d %d'#10'255'#10, [img.W, img.H]);
    fs.WriteBuffer(hdr[1], Length(hdr));
    fs.WriteBuffer(raw[0], Length(raw));
  finally
    fs.Free;
  end;
end;

function LoadBytes(const fn: string): TBytes;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(fn, fmOpenRead);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

procedure SaveBytes(const fn: string; const b: TBytes);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(fn, fmCreate);
  try
    if Length(b) > 0 then fs.WriteBuffer(b[0], Length(b));
  finally
    fs.Free;
  end;
end;

//  commands 

procedure DoEnc;
var
  i: Integer;
  opt: TEncodeOptions;
  inf, outf: string;
  img: TJp2kImage;
  bytes: TBytes;
begin
  opt := DefaultEncodeOptions;
  inf := ''; outf := '';
  i := 2;
  while i <= ParamCount do
  begin
    if ParamStr(i) = '-lossy' then opt.Reversible := False
    else if ParamStr(i) = '-nomct' then opt.UseMct := False
    else if ParamStr(i) = '-step' then begin Inc(i); opt.Step := StrToFloat(ParamStr(i)); end
    else if ParamStr(i) = '-levels' then begin Inc(i); opt.NumLevels := StrToInt(ParamStr(i)); end
    else if inf = '' then inf := ParamStr(i)
    else outf := ParamStr(i);
    Inc(i);
  end;
  if (inf = '') or (outf = '') then
  begin
    Writeln('usage: jp2k enc [options] <in.pgm|in.ppm> <out.jpc>');
    Halt(2);
  end;
  img := LoadPnm(inf);
  if LowerCase(ExtractFileExt(outf)) = '.jp2' then
    bytes := EncodeToJp2(img, opt)
  else
    bytes := EncodeToJpc(img, opt);
  SaveBytes(outf, bytes);
  Writeln(Format('encoded %dx%d x%d -> %s, %d bytes (%s)',
    [img.W, img.H, img.NumComps, ExtractFileExt(outf), Length(bytes),
     BoolToStr(opt.Reversible, 'lossless', 'lossy')]));
  img.Free;
end;

procedure DoDec;
var
  inf, outf: string;
  img: TJp2kImage;
begin
  inf := ParamStr(2); outf := ParamStr(3);
  if (inf = '') or (outf = '') then
  begin
    Writeln('usage: jp2k dec <in.jp2|in.jpc> <out.pgm|out.ppm>');
    Halt(2);
  end;
  img := DecodeGeneral(LoadBytes(inf));   // general: layers/precincts/progressions/ROI, .jp2 or .jpc
  SavePnm(img, outf);
  Writeln(Format('decoded %dx%d x%d', [img.W, img.H, img.NumComps]));
  img.Free;
end;

procedure DoDecStd;
var
  inf, outf: string;
  img: TJp2kImage;
begin
  inf := ParamStr(2); outf := ParamStr(3);
  img := DecodeJpcStandard(LoadBytes(inf));
  SavePnm(img, outf);
  Writeln(Format('decoded (standard) %dx%d x%d', [img.W, img.H, img.NumComps]));
  img.Free;
end;

procedure DoPsnr;
var
  a, b: TJp2kImage;
  c, i: Integer;
  se: Double;
  n, maxd, d: Integer;
begin
  a := LoadPnm(ParamStr(2));
  b := LoadPnm(ParamStr(3));
  if (a.W <> b.W) or (a.H <> b.H) or (a.NumComps <> b.NumComps) then
  begin
    Writeln('dimension mismatch'); Halt(1);
  end;
  se := 0; n := 0; maxd := 0;
  for c := 0 to a.NumComps - 1 do
    for i := 0 to a.W * a.H - 1 do
    begin
      d := Abs(a.Comps[c][i] - b.Comps[c][i]);
      if d > maxd then maxd := d;
      se := se + d * d; Inc(n);
    end;
  if se = 0 then Writeln('identical (PSNR = inf), maxdiff=0')
  else Writeln(Format('PSNR = %.2f dB, maxdiff = %d', [10 * Ln(255.0*255.0/(se/n))/Ln(10), maxd]));
  a.Free; b.Free;
end;

procedure DoGen;
var
  w, h, nc, x, y, c, v: Integer;
  img: TJp2kImage;
begin
  w := StrToInt(ParamStr(2)); h := StrToInt(ParamStr(3));
  nc := StrToInt(ParamStr(4));
  img := TJp2kImage.Create(w, h, nc, 8);
  for c := 0 to nc - 1 do
    for y := 0 to h - 1 do
      for x := 0 to w - 1 do
      begin
        v := ((x * 255) div w + (y * 255) div h) div 2;
        if c = 1 then v := 255 - v;
        if c = 2 then v := (v + 80) mod 256;
        if ((x div 11 + y div 7) and 1) = 0 then v := v xor 48;
        img.Comps[c][y * w + x] := v and $ff;
      end;
  SavePnm(img, ParamStr(5));
  Writeln(Format('wrote %dx%d x%d to %s', [w, h, nc, ParamStr(5)]));
  img.Free;
end;

begin
  if ParamCount < 1 then
  begin
    Writeln('jp2k - Free Pascal JPEG 2000 codec');
    Writeln('  jp2k enc [options] <in.pgm|in.ppm> <out.jpc>');
    Writeln('  jp2k dec <in.jpc> <out.pgm|out.ppm>');
    Writeln('  jp2k gen <w> <h> <comps> <out.pgm|out.ppm>');
    Halt(1);
  end;
  try
    if ParamStr(1) = 'enc' then DoEnc
    else if ParamStr(1) = 'dec' then DoDec
    else if ParamStr(1) = 'decstd' then DoDecStd
    else if ParamStr(1) = 'psnr' then DoPsnr
    else if ParamStr(1) = 'gen' then DoGen
    else begin Writeln('unknown command: ', ParamStr(1)); Halt(1); end;
  except
    on e: Exception do
    begin
      Writeln('error: ', e.Message);
      Halt(1);
    end;
  end;
end.
