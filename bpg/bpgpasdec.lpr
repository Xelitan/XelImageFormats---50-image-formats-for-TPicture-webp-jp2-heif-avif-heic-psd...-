// BPG decoder -- Free Pascal port of libbpg 0.9.8
// Command line front end.
//
// The default output is the same P6 PPM that `bpgdec -o out.ppm` writes, byte
// for byte, so the two can be diffed directly. PAM (P7) is offered on top of
// that for alpha, and both formats can be written with 16 bits per sample.
program bpgpasdec;

{$mode Delphi}
{$H+}
{$POINTERMATH ON}

uses
  SysUtils, Classes, bpg_common, bpg_container, bpg_output;

type
  TOutFormat = (ofPPM, ofPGM, ofPAM);

var
  OutName: string = 'out.ppm';
  InName: string = '';
  OutFmt: TOutFormat = ofPPM;
  OutFmtSet: Boolean = False;
  Bits: Integer = 8;
  InfoOnly: Boolean = False;
  AllFrames: Boolean = False;

procedure Usage;
begin
  WriteLn(ErrOutput, 'usage: bpgpasdec [options] infile.bpg');
  WriteLn(ErrOutput, 'options:');
  WriteLn(ErrOutput, '  -o outfile   output file (default out.ppm);');
  WriteLn(ErrOutput, '               .ppm / .pgm / .pam pick the format unless -f is given');
  WriteLn(ErrOutput, '  -f fmt       force output format: ppm, pgm or pam');
  WriteLn(ErrOutput, '  -b n         bits per sample: 8 (default) or 16');
  WriteLn(ErrOutput, '  -i           print image information and exit');
  WriteLn(ErrOutput, '  -m           animation: write every frame, numbering the output');
  Halt(1);
end;

function LoadFile(const Name: string; out Size: Integer): PByte;
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
  try
    Size := FS.Size;
    Result := av_malloc(Size);
    if Result = nil then
    begin
      WriteLn(ErrOutput, 'out of memory');
      Halt(1);
    end;
    FS.ReadBuffer(Result^, Size);
  finally
    FS.Free;
  end;
end;

procedure WriteStr(FS: TStream; const S: string);
begin
  if Length(S) > 0 then FS.WriteBuffer(S[1], Length(S));
end;

// swap a 16-bit sample line to big endian, as PNM requires
procedure ToBigEndian(P: PWord; Count: Integer);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    P[I] := (P[I] shr 8) or (P[I] shl 8);
end;

procedure FormatName(const Info: TBPGImageInfo; out S: string);
begin
  case Info.format of
    BPG_FORMAT_GRAY: S := 'grayscale';
    BPG_FORMAT_420:  S := '4:2:0';
    BPG_FORMAT_422:  S := '4:2:2';
    BPG_FORMAT_444:  S := '4:4:4';
  else
    S := '?';
  end;
end;

var
  I, Size, W, H, Y, NComp, SampleBytes, LineBytes, Ret: Integer;
  Buf: PByte;
  Img: PBPGDecoderContext;
  Info: TBPGImageInfo;
  Line: PByte;
  FS: TFileStream;
  Arg, Ext, FmtStr, ThisName: string;
  FrameNo: Integer;
  out_fmt: Integer;
  MaxVal: Integer;
begin
  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if Arg = '-o' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      OutName := ParamStr(I);
    end
    else if Arg = '-f' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      FmtStr := LowerCase(ParamStr(I));
      if FmtStr = 'ppm' then OutFmt := ofPPM
      else if FmtStr = 'pgm' then OutFmt := ofPGM
      else if FmtStr = 'pam' then OutFmt := ofPAM
      else Usage;
      OutFmtSet := True;
    end
    else if Arg = '-b' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      Bits := StrToIntDef(ParamStr(I), 0);
      if (Bits <> 8) and (Bits <> 16) then Usage;
    end
    else if Arg = '-i' then
      InfoOnly := True
    else if Arg = '-m' then
      AllFrames := True
    else if (Length(Arg) > 0) and (Arg[1] = '-') then
      Usage
    else if InName = '' then
      InName := Arg
    else
      Usage;
    Inc(I);
  end;
  if InName = '' then Usage;

  if not OutFmtSet then
  begin
    Ext := LowerCase(ExtractFileExt(OutName));
    if Ext = '.pgm' then OutFmt := ofPGM
    else if Ext = '.pam' then OutFmt := ofPAM
    else OutFmt := ofPPM;
  end;

  Buf := LoadFile(InName, Size);

  Img := bpg_decoder_open;
  if Img = nil then
  begin
    WriteLn(ErrOutput, 'out of memory');
    Halt(1);
  end;

  if bpg_decoder_decode(Img, Buf, Size) < 0 then
  begin
    WriteLn(ErrOutput, InName + ': not a valid BPG image');
    Halt(1);
  end;
  av_free(Buf);

  if bpg_decoder_get_info(Img, @Info) < 0 then
  begin
    WriteLn(ErrOutput, InName + ': cannot read image information');
    Halt(1);
  end;

  if InfoOnly then
  begin
    FormatName(Info, FmtStr);
    Arg := Format('%dx%d %s %d bpp', [Info.width, Info.height, FmtStr, Info.bit_depth]);
    if Info.has_alpha <> 0 then Arg := Arg + ' alpha';
    if Info.premultiplied_alpha <> 0 then Arg := Arg + ' premultiplied';
    if Info.has_w_plane <> 0 then Arg := Arg + ' w-plane';
    if Info.limited_range <> 0 then Arg := Arg + ' limited-range';
    if Info.has_animation <> 0 then
      Arg := Arg + Format(' animated loop=%d', [Info.loop_count]);
    WriteLn(Arg);
    Halt(0);
  end;

  W := Integer(Info.width);
  H := Integer(Info.height);

  // PGM only makes sense for a grayscale image without alpha
  if (OutFmt = ofPGM) and ((Info.format <> BPG_FORMAT_GRAY) or (Info.has_alpha <> 0)) then
  begin
    WriteLn(ErrOutput, 'pgm output requires a grayscale image without alpha');
    Halt(1);
  end;

  if OutFmt = ofPAM then
  begin
    if Info.has_alpha <> 0 then NComp := 4 else NComp := 3;
    if Bits = 16 then
      if NComp = 4 then out_fmt := BPG_OUTPUT_FORMAT_RGBA64
                   else out_fmt := BPG_OUTPUT_FORMAT_RGB48
    else
      if NComp = 4 then out_fmt := BPG_OUTPUT_FORMAT_RGBA32
                   else out_fmt := BPG_OUTPUT_FORMAT_RGB24;
  end
  else
  begin
    // PPM and PGM both go through the RGB path; PGM takes the red channel,
    // which for a grayscale source equals the luma
    NComp := 3;
    if Bits = 16 then out_fmt := BPG_OUTPUT_FORMAT_RGB48
                 else out_fmt := BPG_OUTPUT_FORMAT_RGB24;
  end;

  SampleBytes := Bits div 8;
  LineBytes := W * NComp * SampleBytes;
  Line := av_malloc(LineBytes);
  if Line = nil then
  begin
    WriteLn(ErrOutput, 'out of memory');
    Halt(1);
  end;

  if Bits = 16 then MaxVal := 65535 else MaxVal := 255;

  FrameNo := 0;
  repeat
  if AllFrames then
    ThisName := ChangeFileExt(OutName, '') + Format('-%d', [FrameNo]) + ExtractFileExt(OutName)
  else
    ThisName := OutName;
  FS := TFileStream.Create(ThisName, fmCreate);
  try
    case OutFmt of
      ofPPM: WriteStr(FS, Format('P6'#10'%d %d'#10'%d'#10, [W, H, MaxVal]));
      ofPGM: WriteStr(FS, Format('P5'#10'%d %d'#10'%d'#10, [W, H, MaxVal]));
      ofPAM:
        begin
          WriteStr(FS, 'P7'#10);
          WriteStr(FS, Format('WIDTH %d'#10, [W]));
          WriteStr(FS, Format('HEIGHT %d'#10, [H]));
          WriteStr(FS, Format('DEPTH %d'#10, [NComp]));
          WriteStr(FS, Format('MAXVAL %d'#10, [MaxVal]));
          if NComp = 4 then
            WriteStr(FS, 'TUPLTYPE RGB_ALPHA'#10)
          else
            WriteStr(FS, 'TUPLTYPE RGB'#10);
          WriteStr(FS, 'ENDHDR'#10);
        end;
    end;

    Ret := bpg_decoder_start(Img, out_fmt);
    if Ret < 0 then
    begin
      if FrameNo > 0 then
      begin
        // the animation ended between frames
        FreeAndNil(FS);
        DeleteFile(ThisName);
        Break;
      end;
      WriteLn(ErrOutput, InName + ': cannot start decoding');
      Halt(1);
    end;

    for Y := 0 to H - 1 do
    begin
      if bpg_decoder_get_line(Img, Line) < 0 then
      begin
        WriteLn(ErrOutput, InName + ': truncated image');
        Halt(1);
      end;
      if OutFmt = ofPGM then
      begin
        // keep only the first of the three identical components
        if Bits = 16 then
        begin
          for I := 0 to W - 1 do
            PWord(Line)[I] := PWord(Line)[I * 3];
          ToBigEndian(PWord(Line), W);
          FS.WriteBuffer(Line^, W * 2);
        end
        else
        begin
          for I := 0 to W - 1 do
            Line[I] := Line[I * 3];
          FS.WriteBuffer(Line^, W);
        end;
      end
      else
      begin
        if Bits = 16 then ToBigEndian(PWord(Line), W * NComp);
        FS.WriteBuffer(Line^, LineBytes);
      end;
    end;
  finally
    FS.Free;
  end;
  Inc(FrameNo);
  until (not AllFrames) or (Info.has_animation = 0);

  if AllFrames then
    WriteLn(Format('%d frame(s) written', [FrameNo]));

  av_free(Line);
  bpg_decoder_output_end(Img);
  bpg_decoder_close(Img);
end.
