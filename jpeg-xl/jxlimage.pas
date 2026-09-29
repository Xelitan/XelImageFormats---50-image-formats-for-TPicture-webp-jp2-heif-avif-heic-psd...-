{$mode delphi}
unit jxlimage;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// Public API for the pure-Pascal JXL decoder.
//
// Usage:
//   dec := TJxlDecoder.Create;
//   try
//     dec.LoadFromFile('image.jxl');
//     // pixels are RGBA 8-bit, row-major
//     buf := dec.GetRGBA8;
//   finally
//     dec.Free;
//   end;

interface

uses
  SysUtils, Classes, Math,
  jxl_types, jxl_bits, jxl_header, jxl_frame, jxl_container, jxl_color,
  jxl_icc, jxl_features;

type
  TJxlDecoder = class
  private
    FMetadata:  TJxlImageMetadata;
    FImage:     TJxlImageF;
    FDecoded:   Boolean;
    FAlphaIdx:  Integer;    // index into FImage.ExtraPlanes, -1 = none

    procedure DecodeCodestream(data: PByte; size: NativeUInt);
    procedure SetOutput(const planes: TPlaneArray);

  public
    constructor Create;
    destructor  Destroy; override;

    // Load from various sources
    procedure LoadFromFile(const FileName: string);
    procedure LoadFromStream(Stream: TStream);
    procedure LoadFromMemory(Data: Pointer; Size: NativeUInt);

    // After loading, these are valid:
    property Width:    Integer read FImage.Width;
    property Height:   Integer read FImage.Height;
    property Decoded:  Boolean read FDecoded;
    property Metadata: TJxlImageMetadata read FMetadata;

    // Get pixels in various formats
    // Returns a newly-allocated array; caller must free with SetLength(…,0)
    function GetRGBA8:  TBytes;  // R,G,B,A per pixel (alpha=255 if no alpha)
    function GetRGB8:   TBytes;  // R,G,B per pixel
    function GetGray8:  TBytes;  // single-channel 8-bit
    function GetRGBA16: TBytes;  // R,G,B,A each as 16-bit little-endian word
  end;

// Convenience one-shot load
function JxlLoadRGBA8(const FileName: string;
                       out Width, Height: Integer): TBytes;

implementation

{$WARN 5092 off}  // suppress "function result variable ... not initialized" for TBytes returns

// ---------------------------------------------------------------------------
constructor TJxlDecoder.Create;
begin
  inherited;
  FDecoded := False;
  FAlphaIdx := -1;
  FillChar(FMetadata, SizeOf(FMetadata), 0);
  FillChar(FImage,    SizeOf(FImage),    0);
end;

destructor TJxlDecoder.Destroy;
var c: Integer;
begin
  for c := 0 to FImage.NumChannels - 1 do
    SetLength(FImage.Planes[c].Data, 0);
  inherited;
end;

// ---------------------------------------------------------------------------
// Output: the displayed frame, with the image orientation undone
// ---------------------------------------------------------------------------
procedure OrientPlane(var p: TFloat32Plane; orientation: Integer);
var
  o: TFloat32Plane;
  x, y, w, h, sx, sy: Integer;
begin
  if orientation <= 1 then Exit;
  w := p.Width; h := p.Height;
  if orientation >= 5 then InitFloat32Plane(o, h, w)
  else InitFloat32Plane(o, w, h);
  for y := 0 to o.Height - 1 do
    for x := 0 to o.Width - 1 do
    begin
      case orientation of
        2: begin sx := w - 1 - x; sy := y; end;
        3: begin sx := w - 1 - x; sy := h - 1 - y; end;
        4: begin sx := x; sy := h - 1 - y; end;
        5: begin sx := y; sy := x; end;
        6: begin sx := y; sy := h - 1 - x; end;
        7: begin sx := w - 1 - y; sy := h - 1 - x; end;
      else begin sx := w - 1 - y; sy := x; end;   // 8
      end;
      o.Data[y * o.Width + x] := p.Data[sy * p.Stride + sx];
    end;
  p := o;
end;

procedure TJxlDecoder.SetOutput(const planes: TPlaneArray);
var
  c, n: Integer;
begin
  FImage.NumChannels := 3;
  for c := 0 to 2 do
  begin
    FImage.Planes[c] := planes[c];
    OrientPlane(FImage.Planes[c], FMetadata.Orientation);
  end;
  n := Length(planes) - 3;
  SetLength(FImage.ExtraPlanes, n);
  FAlphaIdx := -1;
  for c := 0 to n - 1 do
  begin
    FImage.ExtraPlanes[c] := planes[3 + c];
    OrientPlane(FImage.ExtraPlanes[c], FMetadata.Orientation);
    if (FAlphaIdx < 0) and (FMetadata.ExtraChannels[c].ChanType = jectAlpha) then
      FAlphaIdx := c;
  end;
  FImage.Width := FImage.Planes[0].Width;
  FImage.Height := FImage.Planes[0].Height;
end;

// ---------------------------------------------------------------------------
// Main codestream decoder: headers, ICC, preview, frames until the first
// displayed one.
// ---------------------------------------------------------------------------
procedure TJxlDecoder.DecodeCodestream(data: PByte; size: NativeUInt);
var
  br:        TBitReader;
  sig1, sig2:Byte;
  st:        TJxlDecodeState;
  pos:       NativeUInt;
  hdr:       TFrameHeader;
  displayed: Boolean;
  output:    TPlaneArray;
begin
  st := nil;
  br := TBitReader.Create(data, size);
  try
    // Codestream signature
    sig1 := br.ReadBits(8);
    sig2 := br.ReadBits(8);
    if (sig1 <> $FF) or (sig2 <> $0A) then
      raise EJxlError.CreateFmt(
        'Invalid JXL codestream signature: $%02X $%02X', [sig1, sig2]);

    ReadSizeHeader(br, FMetadata);
    if (FMetadata.XSize = 0) or (FMetadata.YSize = 0) or
       (FMetadata.XSize > JXL_MAX_SIZE) or (FMetadata.YSize > JXL_MAX_SIZE) then
      raise EJxlError.CreateFmt(
        'Invalid JXL image dimensions: %dx%d',
        [FMetadata.XSize, FMetadata.YSize]);
    ReadImageMetadata(br, FMetadata);
    ReadCustomTransformData(br, FMetadata);
    if FMetadata.ColorEncoding.WantICC then
      FMetadata.ICCProfile := ReadEncodedICC(br);
    br.AlignToByte;
    pos := br.BitsRead div 8;
    if pos > size then raise EJxlError.Create('Truncated JPEG XL header');

    st := TJxlDecodeState.Create(FMetadata);
    if FMetadata.HavePreview then
      pos := DecodeJxlFrame(st, data, size, pos, True, True, hdr, displayed, output);
    repeat
      if pos >= size then raise EJxlError.Create('JPEG XL: no displayed frame');
      pos := DecodeJxlFrame(st, data, size, pos, False, False, hdr, displayed, output);
      if displayed then Break;
      if hdr.IsLast then raise EJxlError.Create('JPEG XL: no displayed frame');
    until False;
    SetOutput(output);
    FDecoded := True;
  finally
    st.Free;
    br.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Load from memory
// ---------------------------------------------------------------------------
procedure TJxlDecoder.LoadFromMemory(Data: Pointer; Size: NativeUInt);
var
  csData: TByteArray;
begin
  FDecoded := False;
  csData   := ExtractCodestream(PByte(Data), Int64(Size));
  if Length(csData) = 0 then
    raise EJxlError.Create('Empty codestream extracted from JXL data');
  DecodeCodestream(@csData[0], NativeUInt(Length(csData)));
end;

// ---------------------------------------------------------------------------
// Load from stream
// ---------------------------------------------------------------------------
procedure TJxlDecoder.LoadFromStream(Stream: TStream);
var
  buf: TBytes;
  sz:  Int64;
begin
  sz := Stream.Size - Stream.Position;
  if sz <= 0 then raise EJxlError.Create('Empty stream');
  SetLength(buf, sz);
  Stream.ReadBuffer(buf[0], sz);
  LoadFromMemory(@buf[0], NativeUInt(sz));
end;

// ---------------------------------------------------------------------------
// Load from file
// ---------------------------------------------------------------------------
procedure TJxlDecoder.LoadFromFile(const FileName: string);
var fs: TFileStream;
begin
  fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    LoadFromStream(fs);
  finally
    fs.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Pixel extraction helpers
// ---------------------------------------------------------------------------
function TJxlDecoder.GetRGBA8: TBytes;
var
  x, y, idx: Integer;
  r, g, b, a: Single;
  alphaPlane: PFloat32Plane;
  hasAlpha: Boolean;
begin
  Result := nil;
  if not FDecoded then raise EJxlError.Create('Image not decoded yet');
  SetLength(Result, FImage.Width * FImage.Height * 4);
  hasAlpha := FAlphaIdx >= 0;
  if hasAlpha then
    alphaPlane := @FImage.ExtraPlanes[FAlphaIdx]
  else
    alphaPlane := nil;

  for y := 0 to FImage.Height - 1 do
    for x := 0 to FImage.Width - 1 do begin
      idx := (y * FImage.Width + x) * 4;
      if FImage.NumChannels >= 3 then begin
        r := PlaneAt(FImage.Planes[0], x, y);
        g := PlaneAt(FImage.Planes[1], x, y);
        b := PlaneAt(FImage.Planes[2], x, y);
      end else if FImage.NumChannels = 1 then begin
        r := PlaneAt(FImage.Planes[0], x, y);
        g := r; b := r;
      end else begin
        r := 0; g := 0; b := 0;
      end;

      Result[idx]     := FloatToByte(r);
      Result[idx + 1] := FloatToByte(g);
      Result[idx + 2] := FloatToByte(b);
      if hasAlpha and (alphaPlane <> nil) then
        Result[idx + 3] := FloatToByte(PlaneAt(alphaPlane^, x, y))
      else
        Result[idx + 3] := 255;
    end;
end;

function TJxlDecoder.GetRGB8: TBytes;
var
  x, y, idx: Integer;
  r, g, b: Single;
begin
  Result := nil;
  if not FDecoded then raise EJxlError.Create('Image not decoded yet');
  SetLength(Result, FImage.Width * FImage.Height * 3);
  for y := 0 to FImage.Height - 1 do
    for x := 0 to FImage.Width - 1 do begin
      idx := (y * FImage.Width + x) * 3;
      if FImage.NumChannels >= 3 then begin
        r := PlaneAt(FImage.Planes[0], x, y);
        g := PlaneAt(FImage.Planes[1], x, y);
        b := PlaneAt(FImage.Planes[2], x, y);
      end else begin
        r := PlaneAt(FImage.Planes[0], x, y);
        g := r; b := r;
      end;
      Result[idx]     := FloatToByte(r);
      Result[idx + 1] := FloatToByte(g);
      Result[idx + 2] := FloatToByte(b);
    end;
end;

function TJxlDecoder.GetGray8: TBytes;
var
  x, y, idx: Integer;
  v: Single;
begin
  Result := nil;
  if not FDecoded then raise EJxlError.Create('Image not decoded yet');
  SetLength(Result, FImage.Width * FImage.Height);
  for y := 0 to FImage.Height - 1 do
    for x := 0 to FImage.Width - 1 do begin
      idx := y * FImage.Width + x;
      v := PlaneAt(FImage.Planes[0], x, y);
      if FImage.NumChannels >= 3 then begin
        // Luminance approximation
        v := 0.2126 * v
           + 0.7152 * PlaneAt(FImage.Planes[1], x, y)
           + 0.0722 * PlaneAt(FImage.Planes[2], x, y);
      end;
      Result[idx] := FloatToByte(v);
    end;
end;

function TJxlDecoder.GetRGBA16: TBytes;
var
  x, y, idx: Integer;
  r, g, b, a: Single;
  hasAlpha: Boolean;
  rw, gw, bw, aw: Word;
begin
  Result := nil;
  if not FDecoded then raise EJxlError.Create('Image not decoded yet');
  SetLength(Result, FImage.Width * FImage.Height * 8);
  hasAlpha := FAlphaIdx >= 0;
  for y := 0 to FImage.Height - 1 do
    for x := 0 to FImage.Width - 1 do begin
      idx := (y * FImage.Width + x) * 8;
      if FImage.NumChannels >= 3 then begin
        r := PlaneAt(FImage.Planes[0], x, y);
        g := PlaneAt(FImage.Planes[1], x, y);
        b := PlaneAt(FImage.Planes[2], x, y);
      end else begin
        r := PlaneAt(FImage.Planes[0], x, y);
        g := r; b := r;
      end;
      if hasAlpha then
        a := PlaneAt(FImage.ExtraPlanes[FAlphaIdx], x, y)
      else
        a := 1.0;
      rw := FloatToWord(r);
      gw := FloatToWord(g);
      bw := FloatToWord(b);
      aw := FloatToWord(a);
      // Little-endian 16-bit per channel
      Result[idx]     := rw and $FF; Result[idx + 1] := rw shr 8;
      Result[idx + 2] := gw and $FF; Result[idx + 3] := gw shr 8;
      Result[idx + 4] := bw and $FF; Result[idx + 5] := bw shr 8;
      Result[idx + 6] := aw and $FF; Result[idx + 7] := aw shr 8;
    end;
end;

// ---------------------------------------------------------------------------
function JxlLoadRGBA8(const FileName: string;
                       out Width, Height: Integer): TBytes;
var dec: TJxlDecoder;
begin
  dec := TJxlDecoder.Create;
  try
    dec.LoadFromFile(FileName);
    Width  := dec.Width;
    Height := dec.Height;
    Result := dec.GetRGBA8;
  finally
    dec.Free;
  end;
end;

end.
