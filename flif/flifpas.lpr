// FLIF - Free Lossless Image Format -- Free Pascal port
// Command line tool.
// Corresponds to: src/flif.cpp (encode_flif / decode_flif driver logic)
//
// Usage:
//   flifpas [-e] [options] <input.pnm|pam> [<input2.pnm> ...] <output.flif>
//   flifpas  -d  [options] <input.flif> <output.pnm|pam>
//   flifpas  -i  <input.flif>
program flifpas;

{$mode Delphi}
{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

uses
  SysUtils, flif_types, flif_io, flif_image, flif_colorrange, flif_transform,
  flif_enc, flif_dec, flif_pnm;

type
  TStringArray = array of string;

procedure ShowHelp;
begin
  WriteLn('flifpas - Free Lossless Image Format (Free Pascal port of FLIF16)');
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  flifpas [-e] [options] <input.pnm|.pam> [<frame2> ...] <output.flif>');
  WriteLn('  flifpas  -d  [options] <input.flif> <output.pnm|.pam>');
  WriteLn('  flifpas  -i  <input.flif>              show image information');
  WriteLn;
  WriteLn('General options:');
  WriteLn('  -h, --help          this help');
  WriteLn('  -v, --verbose       increase verbosity (can be repeated)');
  WriteLn('  -o, --overwrite     overwrite the output file if it exists');
  WriteLn;
  WriteLn('Encode options:');
  WriteLn('  -I, --interlace     force interlaced encoding');
  WriteLn('  -N, --no-interlace  force non-interlaced (scanline) encoding');
  WriteLn('  -A, --acb           force colour buckets');
  WriteLn('  -B, --no-acb        disable colour buckets');
  WriteLn('  -P N, --palette=N   maximum palette size (0 disables the palette)');
  WriteLn('  -R N, --repeats=N   MANIAC learning iterations (default ', TREE_LEARN_REPEATS, ')');
  WriteLn('  -C, --no-crc        do not store a checksum');
  WriteLn('  -K, --keep-invisible-rgb   store RGB of fully transparent pixels');
  WriteLn;
  WriteLn('Decode options:');
  WriteLn('  -q N, --quality=N   lossy/partial decode at N% quality');
  WriteLn('  -s N, --scale=N     decode at scale 1:N (N = 1,2,4,8,...)');
  WriteLn;
  WriteLn('Note: this port reads and writes PNM (P4/P5/P6) and PAM (P7) images.');
end;

function IsFlifName(const S: string): Boolean;
begin
  Result := LowerCase(ExtractFileExt(S)) = '.flif';
end;

function EncodeFiles(const Inputs: TStringArray; const Output: string;
  var Options: TFlifOptions): Boolean;
var
  Imgs: TImages;
  I, P, FrameNb: Integer;
  Flat, Grayscale: Boolean;
  NbPixels: QWord;
  Desc: TStringArray;
  IO: TFileIO;

  procedure Add(const S: string);
  begin
    SetLength(Desc, Length(Desc) + 1);
    Desc[High(Desc)] := S;
  end;

begin
  Result := False;
  SetLength(Imgs, Length(Inputs));
  for I := 0 to High(Inputs) do
  begin
    Imgs[I] := TImage.Create(0);
    v_printf(2, Format('Loading input file: %s'#10, [Inputs[I]]));
    if not ImageLoad(Inputs[I], Imgs[I]) then
    begin
      FreeImages(Imgs);
      Exit(False);
    end;
  end;
  if Options.alpha_zero_special = 0 then
    for I := 0 to High(Imgs) do Imgs[I].AlphaZeroSpecial := False;

  FrameNb := 0;
  for I := 0 to High(Imgs) do
  begin
    Imgs[I].FrameDelay := Options.frame_delay[FrameNb];
    if FrameNb + 1 < Length(Options.frame_delay) then Inc(FrameNb);
  end;

  Flat := True;
  for I := 0 to High(Imgs) do if Imgs[I].UsesAlpha then Flat := False;
  if Flat and (Imgs[0].NumPlanes = 4) then
  begin
    v_printf(2, 'Alpha channel not actually used, dropping it.'#10);
    for I := 0 to High(Imgs) do Imgs[I].DropAlpha;
  end;
  Grayscale := True;
  for I := 0 to High(Imgs) do if Imgs[I].UsesColor then Grayscale := False;
  if Grayscale and (Imgs[0].NumPlanes = 3) then
  begin
    v_printf(2, 'Chroma not actually used, dropping it.'#10);
    for I := 0 to High(Imgs) do Imgs[I].DropColor;
  end;

  NbPixels := QWord(Imgs[0].Rows) * QWord(Imgs[0].Cols);
  SetLength(Desc, 0);
  if NbPixels > 2 then
  begin
    if Options.plc <> 0 then Add('Channel_Compact');
    if Options.ycocg <> 0 then Add('YCoCg');
    Add('PermutePlanes');
    Add('Bounds');
  end;
  if Options.palette_size = -1 then
  begin
    Options.palette_size := DEFAULT_MAX_PALETTE_SIZE;
    if NbPixels * QWord(Length(Imgs)) div 3 < DEFAULT_MAX_PALETTE_SIZE then
      Options.palette_size := Integer(NbPixels * QWord(Length(Imgs)) div 3);
  end;
  if (Options.loss = 0) and (Options.palette_size <> 0) then
  begin
    Add('Palette_Alpha');
    Add('Palette');
  end;
  if Options.loss = 0 then
  begin
    if Options.acb = -1 then
    begin
      if NbPixels * QWord(Length(Imgs)) > 10000 then Add('Color_Buckets');
    end
    else if Options.acb <> 0 then
      Add('Color_Buckets');
  end;
  if Options.method = feUndefined then
  begin
    if NbPixels * QWord(Length(Imgs)) < 10000 then Options.method := feNonInterlaced
    else Options.method := feInterlaced;
  end;
  if Length(Imgs) > 1 then
  begin
    Add('Duplicate_Frame');
    if Options.loss = 0 then
    begin
      if Options.frs <> 0 then Add('Frame_Shape');
      if Options.lookback <> 0 then Add('Frame_Lookback');
    end;
  end;
  if Options.learn_repeats < 0 then
  begin
    Options.learn_repeats := TREE_LEARN_REPEATS;
    if Options.learn_repeats < 0 then Options.learn_repeats := 0;
  end;

  IO := TFileIO.CreateWrite(Output);
  try
    Result := FlifEncode(IO, Imgs, Desc, Options);
    if Result then IO.Flush;
  finally
    IO.Free;
    FreeImages(Imgs);
  end;
end;

function DecodeFile(const Input, Output: string; var Options: TFlifOptions): Boolean;
var
  Imgs: TImages;
  IO: TFileIO;
  MD: TMetadataOptions;
  I: Integer;
  Name: string;
begin
  Result := False;
  MD := DefaultMetadataOptions;
  SetLength(Imgs, 0);
  IO := TFileIO.CreateRead(Input);
  try
    if not FlifDecode(IO, Imgs, Options, MD) then
    begin
      if Length(Imgs) = 0 then Exit(False);
      v_printf(1, 'Decoding was not complete; writing what was decoded.'#10);
    end;
    if Length(Imgs) = 0 then Exit(False);
    if Length(Imgs) = 1 then
      Result := ImageSave(Output, Imgs[0])
    else
    begin
      Result := True;
      for I := 0 to High(Imgs) do
      begin
        Name := ChangeFileExt(Output, '') + Format('-%.3d', [I]) + ExtractFileExt(Output);
        if not ImageSave(Name, Imgs[I]) then Result := False;
      end;
    end;
  finally
    IO.Free;
    FreeImages(Imgs);
  end;
end;

function IdentifyFile(const Input: string; var Options: TFlifOptions): Boolean;
var
  Imgs: TImages;
  IO: TFileIO;
  MD: TMetadataOptions;
  Info: TFlifInfo;
begin
  MD := DefaultMetadataOptions;
  SetLength(Imgs, 0);
  Options.scale := -1;
  IO := TFileIO.CreateRead(Input);
  try
    increase_verbosity(0);
    Result := FlifDecodeEx(IO, Imgs, Options, MD, True, Info);
  finally
    IO.Free;
    FreeImages(Imgs);
  end;
end;

var
  Options: TFlifOptions;
  Args: TStringArray;
  Inputs: TStringArray;
  I, N: Integer;
  A, Next: string;
  Mode: Char;          // 'e', 'd', 'i', or #0 for auto
  Ok: Boolean;

function NextArg(var Idx: Integer): string;
begin
  Inc(Idx);
  if Idx <= ParamCount then Result := ParamStr(Idx) else Result := '';
end;

begin
  Options := DefaultOptions;
  Mode := #0;
  SetLength(Args, 0);
  I := 1;
  while I <= ParamCount do
  begin
    A := ParamStr(I);
    if (Length(A) > 1) and (A[1] = '-') and (A <> '-') then
    begin
      if (A = '-h') or (A = '--help') then begin ShowHelp; Halt(0); end
      else if (A = '-v') or (A = '--verbose') then increase_verbosity(1)
      else if (A = '-e') or (A = '--encode') then Mode := 'e'
      else if (A = '-d') or (A = '--decode') then Mode := 'd'
      else if (A = '-i') or (A = '--identify') then Mode := 'i'
      else if (A = '-o') or (A = '--overwrite') then Options.overwrite := 1
      else if (A = '-I') or (A = '--interlace') then Options.method := feInterlaced
      else if (A = '-N') or (A = '--no-interlace') then Options.method := feNonInterlaced
      else if (A = '-A') or (A = '--acb') then Options.acb := 1
      else if (A = '-B') or (A = '--no-acb') then Options.acb := 0
      else if (A = '-C') or (A = '--no-crc') then Options.crc_check := 0
      else if (A = '-K') or (A = '--keep-invisible-rgb') then Options.alpha_zero_special := 0
      else if A = '-P' then begin Next := NextArg(I); Options.palette_size := StrToIntDef(Next, -1); end
      else if Copy(A, 1, 10) = '--palette=' then Options.palette_size := StrToIntDef(Copy(A, 11, 99), -1)
      else if A = '-R' then begin Next := NextArg(I); Options.learn_repeats := StrToIntDef(Next, -1); end
      else if Copy(A, 1, 10) = '--repeats=' then Options.learn_repeats := StrToIntDef(Copy(A, 11, 99), -1)
      else if A = '-q' then begin Next := NextArg(I); Options.quality := StrToIntDef(Next, 100); end
      else if Copy(A, 1, 10) = '--quality=' then Options.quality := StrToIntDef(Copy(A, 11, 99), 100)
      else if A = '-s' then begin Next := NextArg(I); Options.scale := StrToIntDef(Next, 1); end
      else if Copy(A, 1, 8) = '--scale=' then Options.scale := StrToIntDef(Copy(A, 9, 99), 1)
      else
      begin
        e_printf(Format('Unknown option: %s'#10, [A]));
        Halt(1);
      end;
    end
    else
    begin
      SetLength(Args, Length(Args) + 1);
      Args[High(Args)] := A;
    end;
    Inc(I);
  end;

  if Length(Args) = 0 then
  begin
    ShowHelp;
    Halt(0);
  end;

  if Mode = #0 then
  begin
    if (Length(Args) = 1) and IsFlifName(Args[0]) then Mode := 'i'
    else if IsFlifName(Args[High(Args)]) then Mode := 'e'
    else if IsFlifName(Args[0]) then Mode := 'd'
    else
    begin
      e_printf('Cannot tell whether to encode or decode; use -e or -d.'#10);
      Halt(1);
    end;
  end;

  Ok := False;
  case Mode of
    'i':
      begin
        if Length(Args) < 1 then begin ShowHelp; Halt(1); end;
        Ok := IdentifyFile(Args[0], Options);
      end;
    'e':
      begin
        if Length(Args) < 2 then
        begin
          e_printf('Need at least one input file and one output file.'#10);
          Halt(1);
        end;
        N := Length(Args) - 1;
        SetLength(Inputs, N);
        for I := 0 to N - 1 do Inputs[I] := Args[I];
        if FileExists(Args[N]) and (Options.overwrite = 0) then
        begin
          e_printf(Format('Output file already exists: %s (use -o to overwrite)'#10, [Args[N]]));
          Halt(1);
        end;
        Ok := EncodeFiles(Inputs, Args[N], Options);
      end;
    'd':
      begin
        if Length(Args) < 2 then
        begin
          e_printf('Need an input file and an output file.'#10);
          Halt(1);
        end;
        if FileExists(Args[1]) and (Options.overwrite = 0) then
        begin
          e_printf(Format('Output file already exists: %s (use -o to overwrite)'#10, [Args[1]]));
          Halt(1);
        end;
        Ok := DecodeFile(Args[0], Args[1], Options);
      end;
  end;

  if Ok then Halt(0) else Halt(2);
end.
