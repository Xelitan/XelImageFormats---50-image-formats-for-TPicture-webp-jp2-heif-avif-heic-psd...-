unit WebPAnimated;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	WEBP animation decoder                                        //
// Version:	0.1                                                           //
// Date:	10-JUN-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Decodes animated WebP (RIFF / VP8X / ANIM / ANMF) by:                      //
//   * parsing the container and enumerating the ANMF frames,                 //
//   * decoding each frame's still bitstream with WebPDec (the Pascal port),  //
//   * compositing each frame onto a persistent canvas honouring the WebP     //
//     blending and disposal rules,                                           //
//   * exposing the finished full-canvas frames as TBitmaps + durations.      //
//                                                                            //
// Usage:                                                                      //
//   Anim := TWebPAnimation.Create;                                           //
//   Anim.LoadFromFile('anim.webp');                                          //
//   for i := 0 to Anim.FrameCount-1 do begin                                 //
//     Canvas.Draw(0, 0, Anim.Frames[i]);                                     //
//     Sleep(Anim.Durations[i]);                                              //
//   end;                                                                      //
//   Anim.Free;                                                                //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, SysUtils, Graphics,
     AnimationCommon, WebPDec, BitmapEveryX;

type
  { One composited animation frame: a full-canvas bitmap and its display time. }
  TWebPFrame = record
    Bitmap:   TBitmap;   // full canvas, 32-bit BGRA
    Duration: Integer;   // milliseconds this frame is shown
  end;

  { TWebPAnimation }
  TWebPAnimation = class(TCustomAnimation)
  private
    FFrames:    array of TWebPFrame;
    FWidth:     Integer;
    FHeight:    Integer;
    FLoopCount: Integer;   // 0 = loop forever
    FBgColor:   Cardinal;  // ANIM background colour (BGRA, informational)
    procedure ClearFrames;
    function  GetFrameCount: Integer;
    function  GetFrame(Index: Integer): TBitmap;
    function  GetDuration(Index: Integer): Integer;
    procedure DecodeAnimation(Data: PByte; Size: NativeUInt);
  public
    constructor Create;
    destructor  Destroy; override;
    procedure LoadFromStream(Stream: TStream);
    procedure LoadFromFile(const FileName: String);
    // Total duration of one loop, in milliseconds.
    function TotalDuration: Integer;
    property Width:      Integer read FWidth;
    property Height:     Integer read FHeight;
    property LoopCount:  Integer read FLoopCount;
    property BgColor:    Cardinal read FBgColor;
    property FrameCount: Integer read GetFrameCount;
    property Frames[Index: Integer]:    TBitmap read GetFrame;     default;
    property Durations[Index: Integer]: Integer read GetDuration;
  end;

implementation

// =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
// Little-endian readers (POINTERMATH makes p[i] / p+n valid)
// =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

function GetLE16(p: PByte): Cardinal; inline;
begin
  Result := p[0] or (Cardinal(p[1]) shl 8);
end;

function GetLE24(p: PByte): Cardinal; inline;
begin
  Result := p[0] or (Cardinal(p[1]) shl 8) or (Cardinal(p[2]) shl 16);
end;

function GetLE32(p: PByte): Cardinal; inline;
begin
  Result := p[0] or (Cardinal(p[1]) shl 8) or
            (Cardinal(p[2]) shl 16) or (Cardinal(p[3]) shl 24);
end;

function FourCC(const Tag: AnsiString): Cardinal; inline;
var
  I: Integer;
begin
  if Length(Tag) <> 4 then
    raise Exception.Create('FourCC tag must be exactly 4 characters');

  Result := 0;

  for I := 1 to 4 do
    Result := Result or (Cardinal(Byte(Tag[I])) shl ((I - 1) * 8));
end;

// =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
// Build a stand-alone single-image WebP around a frame bitstream
// =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
// An ANMF payload is just a sequence of chunks (optional ALPH then
// VP8 / VP8L) WITHOUT the RIFF/WEBP wrapper. WebPDec decodes a full
// container, so we synthesise a minimal one around the payload. A VP8X
// header is added only when a lossy frame carries a separate ALPH chunk
// (so WebPDec's RIFF parser flags the alpha and applies it).
// =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

function HasAlphChunk(Sub: PByte; SubSize: NativeUInt): Boolean;
var
  p: PByte;
  left: NativeUInt;
  sz: Cardinal;
begin
  Result := False;
  p := Sub;
  left := SubSize;
  while left >= 8 do
  begin
    sz := GetLE32(p + 4);
    if GetLE32(p) = FourCC('ALPH') then Exit(True);
    sz := (sz + 1) and (not Cardinal(1));   // 2-byte alignment
    if NativeUInt(8 + sz) > left then Break;
    Inc(p, 8 + sz);
    Dec(left, 8 + sz);
  end;
end;

procedure PutLE32(var Buf: array of Byte; Ofs: Integer; V: Cardinal);
begin
  Buf[Ofs]   := Byte(V);
  Buf[Ofs+1] := Byte(V shr 8);
  Buf[Ofs+2] := Byte(V shr 16);
  Buf[Ofs+3] := Byte(V shr 24);
end;

function BuildContainer(Sub: PByte; SubSize: NativeUInt;
  FrameW, FrameH: Integer; out Container: TBytes): NativeUInt;
var
  needVP8X: Boolean;
  hdrLen, total: NativeUInt;
  o: Integer;
begin
  needVP8X := HasAlphChunk(Sub, SubSize);

  // "WEBP" + [VP8X: 8 + 10] + payload
  hdrLen := 4;
  if needVP8X then Inc(hdrLen, 8 + 10);
  total := 8 + hdrLen + SubSize;          // "RIFF" + size field + body

  SetLength(Container, total);
  // RIFF header
  PutLE32(Container, 0, FourCC('RIFF'));
  PutLE32(Container, 4, Cardinal(hdrLen + SubSize));   // size after this field
  PutLE32(Container, 8, FourCC('WEBP'));
  o := 12;

  if needVP8X then
  begin
    PutLE32(Container, o,   FourCC('VP8X')); Inc(o, 4);
    PutLE32(Container, o,   10);             Inc(o, 4);   // chunk size
    Container[o]   := $10;                                // flags: alpha
    Container[o+1] := 0; Container[o+2] := 0; Container[o+3] := 0;
    // canvas width-1 / height-1, 24-bit LE
    Container[o+4] := Byte((FrameW-1));
    Container[o+5] := Byte((FrameW-1) shr 8);
    Container[o+6] := Byte((FrameW-1) shr 16);
    Container[o+7] := Byte((FrameH-1));
    Container[o+8] := Byte((FrameH-1) shr 8);
    Container[o+9] := Byte((FrameH-1) shr 16);
    Inc(o, 10);
  end;

  if SubSize > 0 then
    Move(Sub^, Container[o], SubSize);

  Result := total;
end;

// =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
// Per-pixel "source over destination" (non-premultiplied alpha)
// =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

procedure BlendOver(Dst, Src: PByte); inline;
var
  sa, da, sa1, oa255, c: Integer;
begin
  sa := Src[3];
  if sa = 255 then
  begin
    Dst[0] := Src[0]; Dst[1] := Src[1]; Dst[2] := Src[2]; Dst[3] := 255;
    Exit;
  end;
  if sa = 0 then Exit;                 // fully transparent source: keep dst

  da   := Dst[3];
  sa1  := 255 - sa;
  oa255 := sa * 255 + da * sa1;        // = out_alpha * 255
  if oa255 = 0 then
  begin
    Dst[0] := 0; Dst[1] := 0; Dst[2] := 0; Dst[3] := 0;
    Exit;
  end;
  for c := 0 to 2 do
    Dst[c] := Byte((Src[c]*sa*255 + Dst[c]*da*sa1 + oa255 div 2) div oa255);
  Dst[3] := Byte((oa255 + 127) div 255);
end;

// =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
// TWebPAnimation
// =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

constructor TWebPAnimation.Create;
begin
  inherited Create;
  FWidth := 0; FHeight := 0; FLoopCount := 0; FBgColor := 0;
end;

destructor TWebPAnimation.Destroy;
begin
  ClearFrames;
  inherited Destroy;
end;

procedure TWebPAnimation.ClearFrames;
var i: Integer;
begin
  for i := 0 to High(FFrames) do
    FFrames[i].Bitmap.Free;
  SetLength(FFrames, 0);
end;

function TWebPAnimation.GetFrameCount: Integer;
begin
  Result := Length(FFrames);
end;

function TWebPAnimation.GetFrame(Index: Integer): TBitmap;
begin
  if (Index < 0) or (Index > High(FFrames)) then
    raise EListError.CreateFmt('WebPAnimation: frame index %d out of range', [Index]);
  Result := FFrames[Index].Bitmap;
end;

function TWebPAnimation.GetDuration(Index: Integer): Integer;
begin
  if (Index < 0) or (Index > High(FFrames)) then
    raise EListError.CreateFmt('WebPAnimation: frame index %d out of range', [Index]);
  Result := FFrames[Index].Duration;
end;

function TWebPAnimation.TotalDuration: Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to High(FFrames) do Inc(Result, FFrames[i].Duration);
end;

procedure TWebPAnimation.LoadFromStream(Stream: TStream);
var
  Data: TBytes;
  Size: NativeUInt;
begin
  Size := NativeUInt(Stream.Size - Stream.Position);
  if Size < 12 then
    raise EInvalidGraphic.Create('WebP: stream too small');
  SetLength(Data, Size);
  Stream.ReadBuffer(Data[0], Size);
  DecodeAnimation(@Data[0], Size);
end;

procedure TWebPAnimation.LoadFromFile(const FileName: String);
var fs: TFileStream;
begin
  fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    LoadFromStream(fs);
  finally
    fs.Free;
  end;
end;

// Decode a single frame bitstream (ANMF payload) into a freshly allocated
// BGRA buffer of size FrameW*FrameH. Returns nil on failure.
function DecodeFrameBitstream(Sub: PByte; SubSize: NativeUInt;
  FrameW, FrameH: Integer): PByte;
var
  Container: TBytes;
  total: NativeUInt;
  w, h: Integer;
begin
  Result := nil;
  total := BuildContainer(Sub, SubSize, FrameW, FrameH, Container);
  if total = 0 then Exit;
  Result := WebPDecodeBGRA(@Container[0], total, w, h);
  // Honour the declared frame geometry if the codec disagrees (shouldn't).
  if (Result <> nil) and ((w <> FrameW) or (h <> FrameH)) then
  begin
    FreeMem(Result);
    Result := nil;
  end;
end;

procedure TWebPAnimation.DecodeAnimation(Data: PByte; Size: NativeUInt);
var
  p, inner, sub, framePix: PByte;
  left: NativeUInt;
  cc, sz, vp8xFlags: Cardinal;
  hasAnim: Boolean;
  // Frame fields
  fbase: PByte;
  fx, fy, fw, fh, fdur: Integer;
  fflags: Cardinal;
  doNotBlend, disposeBg: Boolean;
  // Canvas
  canvas: PByte;
  canvasBytes: NativeUInt;
  row, col, cx, cy: Integer;
  dst, src: PByte;
  bmp: TBitmap;
  n: Integer;
  singlePix: PByte;
  sw, sh: Integer;
begin
  ClearFrames;
  FWidth := 0; 
  FHeight := 0; 
  FLoopCount := 0; 
  FBgColor := 0;

  if Size < 12 then
    raise EInvalidGraphic.Create('WebP: data too small');
  if (GetLE32(Data) <> FourCC('RIFF')) or (GetLE32(Data + 8) <> FourCC('WEBP')) then
    raise EInvalidGraphic.Create('WebP: not a RIFF/WEBP file');

  inner := Data + 12;
  left  := Size - 12;
  hasAnim := False;

  // First pass: read VP8X (canvas size, ANIM flag) and ANIM (loop/bg)
  p := inner;
  while left >= 8 do
  begin
    cc := GetLE32(p);
    sz := GetLE32(p + 4);
    if (cc = FourCC('VP8X')) and (sz >= 10) then
    begin
      vp8xFlags := GetLE32(p + 8);
      hasAnim   := (vp8xFlags and 2) <> 0;
      FWidth    := Integer(GetLE24(p + 8 + 4)) + 1;
      FHeight   := Integer(GetLE24(p + 8 + 7)) + 1;
    end
    else if (cc = FourCC('ANIM')) and (sz >= 6) then
    begin
      FBgColor   := GetLE32(p + 8);          //BGRA bytes as stored
      FLoopCount := Integer(GetLE16(p + 8 + 4));
    end;
    sz := (sz + 1) and (not Cardinal(1));
    if NativeUInt(8 + sz) > left then Break;
    Inc(p, 8 + sz);
    Dec(left, 8 + sz);
  end;

  // =-=- Not an animation? Decode as a single still image. =-=-
  if not hasAnim then
  begin
    singlePix := WebPDecodeBGRA(Data, Size, sw, sh);
    if singlePix = nil then
      raise EInvalidGraphic.Create('WebP decode failed');
    try
      bmp := Bitmap_Every(singlePix, sw, sh);
    finally
      FreeMem(singlePix);
    end;
    SetLength(FFrames, 1);
    FFrames[0].Bitmap   := bmp;
    FFrames[0].Duration := 0;
    if FWidth  = 0 then FWidth  := sw;
    if FHeight = 0 then FHeight := sh;
    Exit;
  end;

  if (FWidth <= 0) or (FHeight <= 0) then
    raise EInvalidGraphic.Create('WebP: invalid canvas size');

  // =-=- Persistent canvas (BGRA), cleared to transparent. =-=-
  // Like libwebp's animation decoder we composite over transparency and treat
  // "dispose to background" as clearing the rectangle to transparent.

  canvasBytes := NativeUInt(FWidth) * NativeUInt(FHeight) * 4;
  GetMem(canvas, canvasBytes);
  try
    FillChar(canvas^, canvasBytes, 0);

    // Second pass: walk the ANMF frames in order
    p := inner;
    left := Size - 12;
    while left >= 8 do
    begin
      cc := GetLE32(p);
      sz := GetLE32(p + 4);

      if (cc = FourCC('ANMF')) and (sz >= 16) then
      begin
        fbase  := p + 8;
        fx     := Integer(GetLE24(fbase + 0)) * 2;
        fy     := Integer(GetLE24(fbase + 3)) * 2;
        fw     := Integer(GetLE24(fbase + 6)) + 1;
        fh     := Integer(GetLE24(fbase + 9)) + 1;
        fdur   := Integer(GetLE24(fbase + 12));
        fflags := fbase[15];
        doNotBlend := (fflags and 2) <> 0;   // bit1: 1 = do not blend (overwrite)
        disposeBg  := (fflags and 1) <> 0;   // bit0: 1 = dispose to background

        sub     := fbase + 16;
        framePix := DecodeFrameBitstream(sub, NativeUInt(sz) - 16, fw, fh);

        if framePix <> nil then
        begin
          try
            // Composite the frame onto the canvas within its rectangle.
            for row := 0 to fh - 1 do
            begin
              cy := fy + row;
              if (cy < 0) or (cy >= FHeight) then continue;
              for col := 0 to fw - 1 do
              begin
                cx := fx + col;
                if (cx < 0) or (cx >= FWidth) then Continue;
                src := framePix + (NativeUInt(row) * fw + col) * 4;
                dst := canvas   + (NativeUInt(cy) * FWidth + cx) * 4;
                if doNotBlend then
                begin
                  dst[0] := src[0]; dst[1] := src[1];
                  dst[2] := src[2]; dst[3] := src[3];
                end
                else
                  BlendOver(dst, src);
              end;
            end;
          finally
            FreeMem(framePix);
          end;

          // Snapshot the canvas as this frame's displayed image.
          bmp := Bitmap_Every(canvas, FWidth, FHeight);
          n := Length(FFrames);
          SetLength(FFrames, n + 1);
          FFrames[n].Bitmap   := bmp;
          FFrames[n].Duration := fdur;

          // Apply this frame's disposal to prepare the canvas for the next.
          if disposeBg then
            for row := 0 to fh - 1 do
            begin
              cy := fy + row;
              if (cy < 0) or (cy >= FHeight) then Continue;
              for col := 0 to fw - 1 do
              begin
                cx := fx + col;
                if (cx < 0) or (cx >= FWidth) then Continue;
                dst := canvas + (NativeUInt(cy) * FWidth + cx) * 4;
                dst[0] := 0; dst[1] := 0; dst[2] := 0; dst[3] := 0;
              end;
            end;
        end;
      end;

      sz := (sz + 1) and (not Cardinal(1));
      if NativeUInt(8 + sz) > left then break;
      Inc(p, 8 + sz);
      Dec(left, 8 + sz);
    end;
  finally
    FreeMem(canvas);
  end;

  if Length(FFrames) = 0 then
    raise EInvalidGraphic.Create('WebP: no animation frames decoded');
end;

end.
