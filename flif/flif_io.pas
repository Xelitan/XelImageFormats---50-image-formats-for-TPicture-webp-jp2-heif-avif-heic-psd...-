// FLIF - Free Lossless Image Format -- Free Pascal port
// Byte-level I/O abstraction.
// Corresponds to: src/fileio.hpp
//
// Both the file and the in-memory backend keep the whole stream in RAM; this
// keeps ftell/isEOF/fseek trivially correct and is much faster than per-byte
// stdio calls, which the range coder does millions of times.
unit flif_io;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, Classes;

const
  FLIF_SEEK_SET = 0;
  FLIF_SEEK_CUR = 1;
  FLIF_SEEK_END = 2;

type
  TFlifIO = class
  protected
    FData: PByte;
    FCapacity: SizeInt;
    FBytesUsed: SizeInt;
    FSeekPos: SizeInt;
    FReadEOS: Boolean;
    FName: string;
    procedure Grow(NecessarySize: SizeInt);
  public
    constructor Create;
    destructor Destroy; override;

    function GetC: Integer; inline;
    // Reads N-1 bytes into Buf and NUL-terminates. Returns False if the stream
    // ended before N-1 bytes could be read (mirrors fgets returning NULL).
    function Gets(Buf: PAnsiChar; N: Integer): Boolean;
    function FPutC(C: Integer): Integer; inline;
    procedure FPutS(const S: string);
    function FTell: SizeInt; inline;
    procedure FSeek(Offset: SizeInt; Where: Integer);
    procedure Flush; virtual;
    function IsEOF: Boolean; inline;
    function GetName: string;

    property Data: PByte read FData;
    property BytesUsed: SizeInt read FBytesUsed;
  end;

  // In-memory stream. Create empty for writing, or from a buffer for reading.
  TBlobIO = class(TFlifIO)
  public
    constructor CreateFromBuffer(ABuf: PByte; ASize: SizeInt; const AName: string = 'BlobReader');
  end;

  // File-backed stream. Mode 'r' loads the file, mode 'w' writes it out on
  // Flush/Destroy.
  TFileIO = class(TFlifIO)
  private
    FWriting: Boolean;
    FFileName: string;
    FDirty: Boolean;
  public
    constructor CreateRead(const AFileName: string);
    constructor CreateWrite(const AFileName: string);
    procedure Flush; override;
    destructor Destroy; override;
    class function FileExistsCI(const AFileName: string): Boolean;
  end;

implementation

// TFlifIO

constructor TFlifIO.Create;
begin
  inherited Create;
  FData := nil;
  FCapacity := 0;
  FBytesUsed := 0;
  FSeekPos := 0;
  FReadEOS := False;
  FName := '';
end;

destructor TFlifIO.Destroy;
begin
  if FData <> nil then
    FreeMem(FData);
  inherited Destroy;
end;

procedure TFlifIO.Grow(NecessarySize: SizeInt);
var
  NewSize: SizeInt;
  NewData: PByte;
begin
  FReadEOS := False;
  if NecessarySize < FCapacity then
    Exit;
  NewSize := NecessarySize;
  if NewSize < 4096 then
    NewSize := 4096;
  if NewSize < FCapacity * 3 div 2 then
    NewSize := FCapacity * 3 div 2;
  GetMem(NewData, NewSize);
  if FBytesUsed > 0 then
    Move(FData^, NewData^, FBytesUsed);
  if FSeekPos > FBytesUsed then
    FillChar(NewData[FBytesUsed], FSeekPos - FBytesUsed, 0);
  if FData <> nil then
    FreeMem(FData);
  FData := NewData;
  FCapacity := NewSize;
end;

function TFlifIO.GetC: Integer;
begin
  if FSeekPos >= FBytesUsed then
  begin
    FReadEOS := True;
    Result := -1;
    Exit;
  end;
  Result := FData[FSeekPos];
  Inc(FSeekPos);
end;

function TFlifIO.Gets(Buf: PAnsiChar; N: Integer): Boolean;
var
  I, MaxWrite: Integer;
begin
  I := 0;
  MaxWrite := N - 1;
  while (FSeekPos < FBytesUsed) and (I < MaxWrite) do
  begin
    Buf[I] := AnsiChar(FData[FSeekPos]);
    Inc(I);
    Inc(FSeekPos);
  end;
  Buf[N - 1] := #0;
  if I < MaxWrite then
  begin
    FReadEOS := True;
    Result := False;
  end
  else
    Result := True;
end;

function TFlifIO.FPutC(C: Integer): Integer;
begin
  Grow(FSeekPos + 1);
  FData[FSeekPos] := Byte(C);
  Inc(FSeekPos);
  if FBytesUsed < FSeekPos then
    FBytesUsed := FSeekPos;
  Result := C;
end;

procedure TFlifIO.FPutS(const S: string);
var
  I: Integer;
begin
  for I := 1 to Length(S) do
    FPutC(Ord(S[I]));
end;

function TFlifIO.FTell: SizeInt;
begin
  Result := FSeekPos;
end;

procedure TFlifIO.FSeek(Offset: SizeInt; Where: Integer);
begin
  FReadEOS := False;
  case Where of
    FLIF_SEEK_SET: FSeekPos := Offset;
    FLIF_SEEK_CUR: FSeekPos := FSeekPos + Offset;
    FLIF_SEEK_END: FSeekPos := FBytesUsed + Offset;
  end;
  if FSeekPos < 0 then FSeekPos := 0;
end;

procedure TFlifIO.Flush;
begin
  // nothing to do for the in-memory backend
end;

function TFlifIO.IsEOF: Boolean;
begin
  Result := FReadEOS;
end;

function TFlifIO.GetName: string;
begin
  Result := FName;
end;

// TBlobIO

constructor TBlobIO.CreateFromBuffer(ABuf: PByte; ASize: SizeInt; const AName: string);
begin
  inherited Create;
  FName := AName;
  if ASize > 0 then
  begin
    GetMem(FData, ASize);
    Move(ABuf^, FData^, ASize);
    FCapacity := ASize;
    FBytesUsed := ASize;
  end;
end;

// TFileIO

constructor TFileIO.CreateRead(const AFileName: string);
var
  FS: TFileStream;
begin
  inherited Create;
  FName := AFileName;
  FFileName := AFileName;
  FWriting := False;
  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    FCapacity := FS.Size;
    FBytesUsed := FCapacity;
    if FCapacity > 0 then
    begin
      GetMem(FData, FCapacity);
      FS.ReadBuffer(FData^, FCapacity);
    end;
  finally
    FS.Free;
  end;
end;

constructor TFileIO.CreateWrite(const AFileName: string);
begin
  inherited Create;
  FName := AFileName;
  FFileName := AFileName;
  FWriting := True;
  FDirty := True;
end;

procedure TFileIO.Flush;
var
  FS: TFileStream;
begin
  if not FWriting then Exit;
  if not FDirty then Exit;
  FS := TFileStream.Create(FFileName, fmCreate);
  try
    if FBytesUsed > 0 then
      FS.WriteBuffer(FData^, FBytesUsed);
  finally
    FS.Free;
  end;
  FDirty := False;
end;

destructor TFileIO.Destroy;
begin
  if FWriting and FDirty then
  try
    Flush;
  except
  end;
  inherited Destroy;
end;

class function TFileIO.FileExistsCI(const AFileName: string): Boolean;
begin
  Result := FileExists(AFileName);
end;

end.
