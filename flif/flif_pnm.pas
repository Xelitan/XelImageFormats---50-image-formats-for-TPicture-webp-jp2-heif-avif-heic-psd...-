// FLIF - Free Lossless Image Format -- Free Pascal port
// PNM (P4/P5/P6) and PAM (P7) loading/saving.
// Corresponds to: src/image/image-pnm.cpp, src/image/image-pam.cpp
unit flif_pnm;

{$mode Delphi}
{$H+}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, Classes, flif_types, flif_image;

function ImageLoadPNM(const FileName: string; Image: TImage): Boolean;
function ImageLoadPAM(const FileName: string; Image: TImage): Boolean;
function ImageSavePNM(const FileName: string; Image: TImage): Boolean;
function ImageSavePAM(const FileName: string; Image: TImage): Boolean;

// dispatch on extension; only PNM/PAM are supported by this port
function ImageLoad(const FileName: string; Image: TImage): Boolean;
function ImageSave(const FileName: string; Image: TImage): Boolean;

implementation

type
  TByteReader = class
  private
    FData: array of Byte;
    FPos: SizeInt;
  public
    constructor CreateFromFile(const FileName: string);
    function GetC: Integer;
    function ReadLine(out S: string): Boolean;
    function Eof: Boolean;
    property Pos: SizeInt read FPos write FPos;
  end;

constructor TByteReader.CreateFromFile(const FileName: string);
var
  FS: TFileStream;
begin
  inherited Create;
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(FData, FS.Size);
    if FS.Size > 0 then FS.ReadBuffer(FData[0], FS.Size);
  finally
    FS.Free;
  end;
  FPos := 0;
end;

function TByteReader.GetC: Integer;
begin
  if FPos >= Length(FData) then Exit(-1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TByteReader.Eof: Boolean;
begin
  Result := FPos >= Length(FData);
end;

// reads up to and including the next newline (like fgets with a big buffer)
function TByteReader.ReadLine(out S: string): Boolean;
var
  Start: SizeInt;
begin
  S := '';
  if FPos >= Length(FData) then Exit(False);
  Start := FPos;
  while (FPos < Length(FData)) and (FData[FPos] <> 10) do Inc(FPos);
  SetLength(S, FPos - Start);
  if FPos > Start then Move(FData[Start], S[1], FPos - Start);
  if FPos < Length(FData) then Inc(FPos);   // skip the newline
  Result := True;
end;

// Reads the next positive integer from the PNM header, skipping whitespace,
// comment lines and blank lines. Mirrors read_pnm_int().
function ReadPnmInt(Rdr: TByteReader; var Line: string; var LinePos: Integer): Cardinal;
var
  V: Int64;
  Ch: Char;
begin
  Result := 0;
  repeat
    // skip whitespace in the current line
    while (LinePos <= Length(Line)) and (Line[LinePos] in [' ', #9, #13]) do Inc(LinePos);
    if (LinePos <= Length(Line)) and (Line[LinePos] in ['0'..'9']) then
    begin
      V := 0;
      while (LinePos <= Length(Line)) and (Line[LinePos] in ['0'..'9']) do
      begin
        V := V * 10 + (Ord(Line[LinePos]) - Ord('0'));
        Inc(LinePos);
      end;
      if V > 0 then Exit(Cardinal(V));
    end;
    // fetch the next non-comment, non-empty line
    repeat
      if not Rdr.ReadLine(Line) then Exit(0);
    until (Length(Line) > 0) and (Line[1] <> '#');
    LinePos := 1;
    // a line that starts with a non-digit character is a parse error unless it
    // contains a number further on; the loop above handles that
    Ch := #0;
    if Length(Line) > 0 then Ch := Line[1];
    if not (Ch in ['0'..'9', ' ', #9]) then
    begin
      // give it one chance: find the first digit
      LinePos := 1;
      while (LinePos <= Length(Line)) and not (Line[LinePos] in ['0'..'9']) do Inc(LinePos);
      if LinePos > Length(Line) then Exit(0);
    end;
  until False;
end;

function LoadPAMFromReader(Rdr: TByteReader; Image: TImage): Boolean;
var
  Line: string;
  MaxLines: Integer;
  Width, Height, MaxVal, Depth: Cardinal;
  NbPlanes, C: Integer;
  X, Y: Cardinal;
  Msb, Lsb, Pixel: Integer;

  function TryKey(const Key: string; out V: Cardinal): Boolean;
  var
    S: string;
    Code: Integer;
    N: Int64;
  begin
    Result := False;
    V := 0;
    if Copy(Line, 1, Length(Key)) <> Key then Exit;
    S := Trim(Copy(Line, Length(Key) + 1, Length(Line)));
    Val(S, N, Code);
    if Code = 0 then
    begin
      V := Cardinal(N);
      Result := True;
    end;
  end;

var
  Tmp: Cardinal;
begin
  Width := 0; Height := 0; MaxVal := 0; Depth := 0;
  MaxLines := 100;
  repeat
    if not Rdr.ReadLine(Line) then Exit(True);
    Line := StringReplace(Line, #13, '', [rfReplaceAll]);
    if (Length(Line) = 0) or (Line[1] = '#') then Continue;
    if TryKey('WIDTH ', Tmp) then Width := Tmp;
    if TryKey('HEIGHT ', Tmp) then Height := Tmp;
    if TryKey('DEPTH ', Tmp) then Depth := Tmp;
    if TryKey('MAXVAL ', Tmp) then MaxVal := Tmp;
    Dec(MaxLines);
    if MaxLines < 1 then
    begin
      e_printf('Problem while parsing PAM header.'#10);
      Exit(False);
    end;
  until Copy(Line, 1, 6) = 'ENDHDR';

  if (Depth > 4) or (Depth < 1) or (Width < 1) or (Height < 1) or (MaxVal < 1) or
     (MaxVal > $FFFF) then
  begin
    e_printf('Couldn''t parse PAM header, or unsupported kind of PAM file.'#10);
    Exit(False);
  end;

  NbPlanes := Depth;
  Image.Init(Width, Height, 0, MaxVal, NbPlanes);
  if MaxVal > $FF then
  begin
    for Y := 0 to Height - 1 do
      for X := 0 to Width - 1 do
        for C := 0 to NbPlanes - 1 do
        begin
          Msb := Rdr.GetC;
          Lsb := Rdr.GetC;
          if (Msb < 0) or (Lsb < 0) then
          begin
            e_printf('PAM file has insufficient data.'#10);
            Exit(False);
          end;
          Pixel := (Msb shl 8) + Lsb;
          if Cardinal(Pixel) > MaxVal then Pixel := MaxVal;
          Image.SetVal(C, Y, X, Pixel);
        end;
  end
  else
  begin
    for Y := 0 to Height - 1 do
      for X := 0 to Width - 1 do
        for C := 0 to NbPlanes - 1 do
        begin
          Pixel := Rdr.GetC;
          if Pixel < 0 then
          begin
            e_printf('PAM file has insufficient data.'#10);
            Exit(False);
          end;
          if Cardinal(Pixel) > MaxVal then Pixel := MaxVal;
          Image.SetVal(C, Y, X, Pixel);
        end;
  end;
  Result := True;
end;

function ImageLoadPNM(const FileName: string; Image: TImage): Boolean;
var
  Rdr: TByteReader;
  Line: string;
  LinePos, PType, C: Integer;
  Width, Height, MaxVal, NbPlanes: Cardinal;
  X, Y: Cardinal;
  ByteVal, Pixel: Integer;
begin
  Result := False;
  if not FileExists(FileName) then
  begin
    e_printf(Format('Could not open file: %s'#10, [FileName]));
    Exit;
  end;
  Rdr := TByteReader.CreateFromFile(FileName);
  try
    repeat
      if not Rdr.ReadLine(Line) then Exit(False);
      Line := StringReplace(Line, #13, '', [rfReplaceAll]);
    until (Length(Line) > 0) and (Line[1] <> '#');

    PType := 0;
    if Copy(Line, 1, 2) = 'P4' then PType := 4;
    if Copy(Line, 1, 2) = 'P5' then PType := 5;
    if Copy(Line, 1, 2) = 'P6' then PType := 6;
    if Copy(Line, 1, 2) = 'P7' then
    begin
      Result := LoadPAMFromReader(Rdr, Image);
      Exit;
    end;
    if PType = 0 then
    begin
      if (Length(Line) > 0) and (Line[1] = 'P') then
        e_printf('PNM file is not of type P4, P5, P6 or P7, cannot read other types.'#10)
      else
        e_printf('This does not look like a PNM file.'#10);
      Exit(False);
    end;

    LinePos := 3;
    Width := ReadPnmInt(Rdr, Line, LinePos);
    if Width = 0 then Exit(False);
    Height := ReadPnmInt(Rdr, Line, LinePos);
    if Height = 0 then Exit(False);
    if PType > 4 then
    begin
      MaxVal := ReadPnmInt(Rdr, Line, LinePos);
      if MaxVal = 0 then Exit(False);
      if MaxVal > $FFFF then
      begin
        e_printf('Invalid PNM file (more than 16-bit?)'#10);
        Exit(False);
      end;
      // the binary data starts right after the newline that ends the maxval line
      while (LinePos <= Length(Line)) and (Line[LinePos] in [' ', #9, #13]) do Inc(LinePos);
    end
    else
      MaxVal := 1;

    if PType = 6 then NbPlanes := 3 else NbPlanes := 1;
    Image.Init(Width, Height, 0, MaxVal, NbPlanes);

    if PType = 4 then
    begin
      ByteVal := 0;
      for Y := 0 to Height - 1 do
        for X := 0 to Width - 1 do
        begin
          if X mod 8 = 0 then ByteVal := Rdr.GetC;
          if (ByteVal and (128 shr (X mod 8))) <> 0 then
            Image.SetVal(0, Y, X, 0)
          else
            Image.SetVal(0, Y, X, 1);
        end;
    end
    else if MaxVal > $FF then
    begin
      for Y := 0 to Height - 1 do
        for X := 0 to Width - 1 do
          for C := 0 to NbPlanes - 1 do
          begin
            Pixel := (Rdr.GetC shl 8);
            Pixel := Pixel + Rdr.GetC;
            if Cardinal(Pixel) > MaxVal then
            begin
              e_printf(Format('Invalid PNM file: value %d is larger than declared maxval %u'#10,
                [Pixel, MaxVal]));
              Exit(False);
            end;
            Image.SetVal(C, Y, X, Pixel);
          end;
    end
    else
    begin
      for Y := 0 to Height - 1 do
        for X := 0 to Width - 1 do
          for C := 0 to NbPlanes - 1 do
            Image.SetVal(C, Y, X, Rdr.GetC);
    end;
    Result := True;
  finally
    Rdr.Free;
  end;
end;

function ImageLoadPAM(const FileName: string; Image: TImage): Boolean;
var
  Rdr: TByteReader;
  Line: string;
begin
  Result := False;
  if not FileExists(FileName) then Exit;
  Rdr := TByteReader.CreateFromFile(FileName);
  try
    if not Rdr.ReadLine(Line) then Exit(False);
    Line := StringReplace(Line, #13, '', [rfReplaceAll]);
    if Copy(Line, 1, 2) = 'P7' then
      Result := LoadPAMFromReader(Rdr, Image)
    else if (Copy(Line, 1, 2) = 'P4') or (Copy(Line, 1, 2) = 'P5') or
            (Copy(Line, 1, 2) = 'P6') then
    begin
      Rdr.Free;
      Rdr := nil;
      Result := ImageLoadPNM(FileName, Image);
    end
    else
    begin
      e_printf('PAM file is not of type P7, cannot read other types.'#10);
      Result := False;
    end;
  finally
    Rdr.Free;
  end;
end;

function ImageSavePNM(const FileName: string; Image: TImage): Boolean;
var
  FS: TFileStream;
  MaxV: ColorVal;
  Header: AnsiString;
  Buf: array of Byte;
  N: SizeInt;
  X, Y: Cardinal;
  P, NPlanes: Integer;
  V: ColorVal;
begin
  if Image.NumPlanes >= 3 then NPlanes := 3
  else if Image.NumPlanes = 1 then NPlanes := 1
  else
  begin
    e_printf('Cannot store as PNM.'#10);
    Exit(False);
  end;
  MaxV := Image.MaxVal(0);
  if MaxV > $FFFF then
  begin
    e_printf('Cannot store as PNM.'#10);
    Exit(False);
  end;
  if (Image.NumPlanes = 4) and Image.UsesAlpha then
    v_printf(1, 'WARNING: image has an alpha channel, saving to flat PPM! Use .pam to keep it.'#10);

  FS := TFileStream.Create(FileName, fmCreate);
  try
    if NPlanes = 3 then
      Header := AnsiString(Format('P6'#10'%u %u'#10'%d'#10, [Image.Cols, Image.Rows, MaxV]))
    else
      Header := AnsiString(Format('P5'#10'%u %u'#10'%d'#10, [Image.Cols, Image.Rows, MaxV]));
    FS.WriteBuffer(Header[1], Length(Header));

    if MaxV > $FF then N := 2 else N := 1;
    SetLength(Buf, SizeInt(Image.Cols) * NPlanes * N);
    for Y := 0 to Image.Rows - 1 do
    begin
      N := 0;
      for X := 0 to Image.Cols - 1 do
        for P := 0 to NPlanes - 1 do
        begin
          V := Image.GetVal(P, Y, X);
          if MaxV > $FF then
          begin
            Buf[N] := Byte(V shr 8);
            Inc(N);
          end;
          Buf[N] := Byte(V and $FF);
          Inc(N);
        end;
      FS.WriteBuffer(Buf[0], N);
    end;
    Result := True;
  finally
    FS.Free;
  end;
end;

function ImageSavePAM(const FileName: string; Image: TImage): Boolean;
var
  FS: TFileStream;
  MaxV: ColorVal;
  Header: AnsiString;
  Buf: array of Byte;
  N: SizeInt;
  X, Y: Cardinal;
  P: Integer;
  V: ColorVal;
begin
  if Image.NumPlanes < 4 then Exit(ImageSavePNM(FileName, Image));
  MaxV := Image.MaxVal(0);
  if MaxV > $FFFF then
  begin
    e_printf('Cannot store as PAM.'#10);
    Exit(False);
  end;
  FS := TFileStream.Create(FileName, fmCreate);
  try
    Header := AnsiString(Format('P7'#10'WIDTH %u'#10'HEIGHT %u'#10'DEPTH 4'#10 +
      'MAXVAL %d'#10'TUPLTYPE RGB_ALPHA'#10'ENDHDR'#10, [Image.Cols, Image.Rows, MaxV]));
    FS.WriteBuffer(Header[1], Length(Header));
    if MaxV > $FF then N := 2 else N := 1;
    SetLength(Buf, SizeInt(Image.Cols) * 4 * N);
    for Y := 0 to Image.Rows - 1 do
    begin
      N := 0;
      for X := 0 to Image.Cols - 1 do
        for P := 0 to 3 do
        begin
          V := Image.GetVal(P, Y, X);
          if MaxV > $FF then
          begin
            Buf[N] := Byte(V shr 8);
            Inc(N);
          end;
          Buf[N] := Byte(V and $FF);
          Inc(N);
        end;
      FS.WriteBuffer(Buf[0], N);
    end;
    Result := True;
  finally
    FS.Free;
  end;
end;

function ImageLoad(const FileName: string; Image: TImage): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  if (Ext = '.pnm') or (Ext = '.pbm') or (Ext = '.pgm') or (Ext = '.ppm') then
    Result := ImageLoadPNM(FileName, Image)
  else if Ext = '.pam' then
    Result := ImageLoadPAM(FileName, Image)
  else
  begin
    // try PNM/PAM sniffing anyway
    Result := ImageLoadPNM(FileName, Image);
    if not Result then
      e_printf(Format('ERROR: unsupported input file type: %s (this port reads PNM/PAM only)'#10,
        [Ext]));
  end;
end;

function ImageSave(const FileName: string; Image: TImage): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  if (Ext = '.pnm') or (Ext = '.pgm') or (Ext = '.ppm') then
    Result := ImageSavePNM(FileName, Image)
  else if Ext = '.pam' then
    Result := ImageSavePAM(FileName, Image)
  else
  begin
    e_printf(Format('ERROR: unsupported output file type: %s (this port writes PNM/PAM only)'#10,
      [Ext]));
    Result := False;
  end;
end;

end.
