unit PdfJbig2;
{$mode delphi}{$H+}
{$Q-}{$R-}  // intentional 32-bit wrap-around in the MQ arithmetic decoder

//JBIG2 decoder in Pascal
//Author: www.xelitan.com
//License: Apache 2.0
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
//JBIG2 decoder for PDF JBIG2Decode streams.
//
//This is a faithful Free Pascal port of the Apache PDFBox JBIG2 library
//(org.apache.pdfbox.jbig2, ASL 2.0). It supports the embedded ("PDF") stream
//organisation: generic regions (arithmetic + MMR), symbol dictionaries, text
//regions, pattern dictionaries, halftone regions, generic refinement regions,
//Huffman-coded and MMR-coded data.
//
//Public entry point: DecodeJBIG2 takes the JBIG2Decode stream bytes plus the
//optional /JBIG2Globals stream bytes and returns 8-bit grayscale, 1 byte per
//pixel, row-major, 0 = black, 255 = white -- the same convention as PdfCcitt,
//so it feeds the renderer's DrawRawDeviceGray path directly.

interface

uses
  Classes, SysUtils;

// Decode an embedded-organisation JBIG2 image. Data is the JBIG2Decode stream;
// Globals is the (possibly empty) /JBIG2Globals stream. On success returns the
// composed page-1 bitmap as 8-bit grayscale (0=black, 255=white).
function DecodeJBIG2(const Data, Globals: TBytes; out OutW, OutH: Integer;
  out Gray: TBytes): Boolean;

// Lower-level: decode and return the packed 1-bpp page bitmap (MSB first,
// 1 = black, row stride = (w+7) div 8).
function DecodeJBIG2Packed(const Data, Globals: TBytes; out OutW, OutH: Integer;
  out Bits: TBytes): Boolean;

// Diagnostic message set when DecodeJBIG2/DecodeJBIG2Packed returns False.
// Threadvar so concurrent decodes each report their own error (and don't race
// on the string's reference count).
threadvar
  LastJBIG2Error: string;

implementation

const
  OOB = High(Int64);  // out-of-band marker (Java Long.MAX_VALUE)

  // JBIG2Document organisation types
  ORG_RANDOM = 0;
  ORG_SEQUENTIAL = 1;

  // CombinationOperator codes
  COMB_OR = 0;
  COMB_AND = 1;
  COMB_XOR = 2;
  COMB_XNOR = 3;
  COMB_REPLACE = 4;

type
  TByteArray = array of Byte;
  TIntArray = array of Integer;

  EJBig2 = class(Exception);

  // Object arena base: every TJBObject registers itself so a single decode run
  // can be torn down at once, sidestepping shared-bitmap ownership issues.
  TJBObject = class
  public
    constructor Create;
  end;

// Object arena for one decode run. It is a THREADVAR, not a plain global: each
// thread gets its own copy, so several .jb2 files can be decoded concurrently
// (e.g. by a multi-threaded thumbnailer) without racing on or freeing each
// other's arena. A single decode runs entirely on one thread, so per-thread
// isolation is all that's required - no locking. The cached Huffman/MMR tables
// (GStandardTables, GWhiteTable, GBlackTable, GModeTable) and LastJBIG2Error are
// threadvars for the same reason.
threadvar
  GArena: TList;

constructor TJBObject.Create;
begin
  inherited Create;
  if GArena <> nil then GArena.Add(Self);
end;

//============================================================================
// Helpers: arithmetic right shift (sign preserving) for halftone grid maths.
//============================================================================
function ASR8(v: Integer): Integer;
begin
  Result := v div 256;
  if (v < 0) and ((v and 255) <> 0) then Dec(Result);
end;

// ceil(log2(n)) as used in the spec (Math.ceil(log(n)/log(2))). Returns 0 for n<=1.
function CeilLog2(n: Integer): Integer;
var k: Integer;
begin
  if n <= 1 then Exit(0);
  k := 0;
  while (1 shl k) < n do Inc(k);
  Result := k;
end;

function CombinePixel(oldP, newP, op: Integer): Integer;
begin
  case op of
    COMB_OR:   Result := newP or oldP;
    COMB_AND:  Result := newP and oldP;
    COMB_XOR:  Result := newP xor oldP;
    COMB_XNOR: Result := not (oldP xor newP);
  else
    Result := newP; // REPLACE
  end;
  Result := Result and 1;
end;

function TranslateCombOp(code: Integer): Integer;
begin
  case code of
    0: Result := COMB_OR;
    1: Result := COMB_AND;
    2: Result := COMB_XOR;
    3: Result := COMB_XNOR;
  else
    Result := COMB_REPLACE;
  end;
end;

//============================================================================
// TJBReader: MSB-first bit reader over a shared byte buffer with a window
// [FBase, FBase+FLength). Models javax.imageio ImageInputStream + SubInputStream.
//============================================================================
type
  TJBReader = class(TJBObject)
  public
    FData: TBytes;
    FBase: Int64;
    FLength: Int64;
    FPos: Int64;
    FBitOffset: Integer;
    FMarkPos: Int64;
    FMarkBit: Integer;
    constructor Create(const AData: TBytes; ABase, ALength: Int64);
    function NewWindow(AOffset, ALength: Int64): TJBReader; // child relative to this
    function ReadBit: Integer;
    function ReadBits(n: Integer): Int64;
    function ReadBits32(n: Integer): Integer;
    function ReadUByte: Integer;       // Java read(): 0..255 or -1
    function ReadByteSigned: Integer;   // Java readByte(): -128..127
    procedure Seek(pos: Int64);
    function StreamPosition: Int64;
    function Length_: Int64;
    procedure SkipBits;
    procedure Mark;
    procedure Reset_;
  end;

constructor TJBReader.Create(const AData: TBytes; ABase, ALength: Int64);
begin
  inherited Create;
  FData := AData;
  FBase := ABase;
  FLength := ALength;
  FPos := 0;
  FBitOffset := 0;
end;

function TJBReader.NewWindow(AOffset, ALength: Int64): TJBReader;
begin
  Result := TJBReader.Create(FData, FBase + AOffset, ALength);
end;

function TJBReader.ReadBit: Integer;
var b: Integer;
begin
  if FBase + FPos < System.Length(FData) then
    b := FData[FBase + FPos]
  else
    b := 0;
  Result := (b shr (7 - FBitOffset)) and 1;
  Inc(FBitOffset);
  if FBitOffset = 8 then
  begin
    FBitOffset := 0;
    Inc(FPos);
  end;
end;

function TJBReader.ReadBits(n: Integer): Int64;
var i: Integer;
begin
  Result := 0;
  for i := 0 to n - 1 do
    Result := (Result shl 1) or ReadBit;
end;

function TJBReader.ReadBits32(n: Integer): Integer;
begin
  Result := Integer(ReadBits(n) and $FFFFFFFF);
end;

function TJBReader.ReadUByte: Integer;
begin
  if FPos >= FLength then
  begin
    Result := -1;
    Exit;
  end;
  if FBase + FPos < System.Length(FData) then
    Result := FData[FBase + FPos]
  else
    Result := 0;
  Inc(FPos);
  FBitOffset := 0;
end;

function TJBReader.ReadByteSigned: Integer;
var v: Integer;
begin
  v := ReadUByte;
  if v < 0 then v := 0;
  Result := ShortInt(v and $FF);
end;

procedure TJBReader.Seek(pos: Int64);
begin
  FPos := pos;
  FBitOffset := 0;
end;

function TJBReader.StreamPosition: Int64;
begin
  Result := FPos;
end;

function TJBReader.Length_: Int64;
begin
  Result := FLength;
end;

procedure TJBReader.SkipBits;
begin
  if FBitOffset <> 0 then
  begin
    FBitOffset := 0;
    if FPos < FLength then Inc(FPos);
  end;
end;

procedure TJBReader.Mark;
begin
  FMarkPos := FPos;
  FMarkBit := FBitOffset;
end;

procedure TJBReader.Reset_;
begin
  FPos := FMarkPos;
  FBitOffset := FMarkBit;
end;

//============================================================================
// TJBBitmap: bi-level bitmap, 8 pixels per byte, 0 = white, 1 = black.
//============================================================================
type
  TJBBitmap = class(TJBObject)
  public
    Width: Integer;
    Height: Integer;
    RowStride: Integer;
    Bytes: TBytes;
    constructor Create(AWidth, AHeight: Integer);
    function GetByteIndex(x, y: Integer): Integer;
    function GetPixel(x, y: Integer): Integer;
    function GetPixelSafe(x, y: Integer): Integer;
    procedure SetPixel(x, y, value: Integer);
    function GetByte(index: Integer): Integer;       // 0..255
    procedure SetByte(index, value: Integer);
    function GetLength: Integer;
    procedure FillBitmap(value: Integer);
  end;

  TBitmapList = class(TJBObject)
  public
    Items: array of TJBBitmap;
    Count: Integer;
    procedure Add(b: TJBBitmap);
    procedure AddList(other: TBitmapList);
    function Get(i: Integer): TJBBitmap;
  end;

constructor TJBBitmap.Create(AWidth, AHeight: Integer);
begin
  inherited Create;
  Width := AWidth;
  Height := AHeight;
  RowStride := (AWidth + 7) shr 3;
  SetLength(Bytes, Height * RowStride);
end;

function TJBBitmap.GetByteIndex(x, y: Integer): Integer;
begin
  Result := y * RowStride + (x shr 3);
end;

function TJBBitmap.GetPixel(x, y: Integer): Integer;
var idx, bitOff: Integer;
begin
  idx := GetByteIndex(x, y);
  bitOff := x and 7;
  Result := (Bytes[idx] shr (7 - bitOff)) and 1;
end;

function TJBBitmap.GetPixelSafe(x, y: Integer): Integer;
begin
  if (x < 0) or (y < 0) or (x >= Width) or (y >= Height) then
    Result := 0
  else
    Result := GetPixel(x, y);
end;

procedure TJBBitmap.SetPixel(x, y, value: Integer);
var idx, bitOff, shift, src: Integer;
begin
  idx := GetByteIndex(x, y);
  bitOff := x and 7;
  shift := 7 - bitOff;
  src := Bytes[idx];
  if (value and 1) = 1 then
    Bytes[idx] := Byte(src or (1 shl shift))
  else
    Bytes[idx] := Byte(src and (not (1 shl shift)));
end;

function TJBBitmap.GetByte(index: Integer): Integer;
begin
  Result := Bytes[index];
end;

procedure TJBBitmap.SetByte(index, value: Integer);
begin
  Bytes[index] := Byte(value and $FF);
end;

function TJBBitmap.GetLength: Integer;
begin
  Result := System.Length(Bytes);
end;

procedure TJBBitmap.FillBitmap(value: Integer);
var i: Integer;
begin
  for i := 0 to System.Length(Bytes) - 1 do
    Bytes[i] := Byte(value and $FF);
end;

procedure TBitmapList.Add(b: TJBBitmap);
begin
  if Count >= System.Length(Items) then
    SetLength(Items, (Count + 8) * 2);
  Items[Count] := b;
  Inc(Count);
end;

procedure TBitmapList.AddList(other: TBitmapList);
var i: Integer;
begin
  if other = nil then Exit;
  for i := 0 to other.Count - 1 do Add(other.Items[i]);
end;

function TBitmapList.Get(i: Integer): TJBBitmap;
begin
  Result := Items[i];
end;

// Bitmaps.extract -- copy a rectangle (out-of-bounds reads as 0).
function JBExtract(x0, y0, w, h: Integer; src: TJBBitmap): TJBBitmap;
var i, j: Integer;
begin
  Result := TJBBitmap.Create(w, h);
  for j := 0 to h - 1 do
    for i := 0 to w - 1 do
      if src.GetPixelSafe(x0 + i, y0 + j) <> 0 then
        Result.SetPixel(i, j, 1);
end;

// Bitmaps.blit -- combine src into dst at (x,y), clipped. Pixel-accurate port
// of blitByPixel, used for all cases.
procedure JBBlit(src, dst: TJBBitmap; x, y, op: Integer);
var i, j, r: Integer;
begin
  for j := 0 to src.Height - 1 do
  begin
    if y + j < 0 then Continue;
    if y + j >= dst.Height then Break;
    for i := 0 to src.Width - 1 do
    begin
      if x + i < 0 then Continue;
      if x + i >= dst.Width then Break;
      r := CombinePixel(dst.GetPixel(x + i, y + j), src.GetPixel(i, j), op);
      dst.SetPixel(x + i, y + j, r);
    end;
  end;
end;

//============================================================================
// MQ arithmetic decoder (ISO/IEC 14492 Annex E) and integer/IAID decoders.
//============================================================================
const
  QE: array[0..46, 0..3] of LongWord = (
    ($5601, 1, 1, 1), ($3401, 2, 6, 0), ($1801, 3, 9, 0), ($0AC1, 4, 12, 0),
    ($0521, 5, 29, 0), ($0221, 38, 33, 0), ($5601, 7, 6, 1), ($5401, 8, 14, 0),
    ($4801, 9, 14, 0), ($3801, 10, 14, 0), ($3001, 11, 17, 0), ($2401, 12, 18, 0),
    ($1C01, 13, 20, 0), ($1601, 29, 21, 0), ($5601, 15, 14, 1), ($5401, 16, 14, 0),
    ($5101, 17, 15, 0), ($4801, 18, 16, 0), ($3801, 19, 17, 0), ($3401, 20, 18, 0),
    ($3001, 21, 19, 0), ($2801, 22, 19, 0), ($2401, 23, 20, 0), ($2201, 24, 21, 0),
    ($1C01, 25, 22, 0), ($1801, 26, 23, 0), ($1601, 27, 24, 0), ($1401, 28, 25, 0),
    ($1201, 29, 26, 0), ($1101, 30, 27, 0), ($0AC1, 31, 28, 0), ($09C1, 32, 29, 0),
    ($08A1, 33, 30, 0), ($0521, 34, 31, 0), ($0441, 35, 32, 0), ($02A1, 36, 33, 0),
    ($0221, 37, 34, 0), ($0141, 38, 35, 0), ($0111, 39, 36, 0), ($0085, 40, 37, 0),
    ($0049, 41, 38, 0), ($0025, 42, 39, 0), ($0015, 43, 40, 0), ($0009, 44, 41, 0),
    ($0005, 45, 42, 0), ($0001, 45, 43, 0), ($5601, 46, 46, 0));

type
  TJBCx = class(TJBObject)
  public
    FIndex: Integer;
    FCx: TBytes;
    FMps: TBytes;
    constructor Create(size, index: Integer);
    function GetCx: Integer;
    procedure SetCx(value: Integer);
    function GetMps: Integer;
    procedure ToggleMps;
    procedure SetIndex(index: Integer);
    function Copy: TJBCx;
  end;

  TJBArith = class(TJBObject)
  public
    FData: TBytes;
    FBP: Int64;
    FEnd: Int64;
    A, C: LongWord;
    CT: Integer;
    constructor Create(reader: TJBReader);
    function GetB(i: Int64): Integer;
    procedure ByteIn;
    procedure Renorm;
    function MpsExchange(cx: TJBCx; icx: Integer): Integer;
    function LpsExchange(cx: TJBCx; icx: Integer; qeValue: LongWord): Integer;
    function Decode(cx: TJBCx): Integer;
  end;

  TJBIntDecoder = class(TJBObject)
  public
    Dec_: TJBArith;
    constructor Create(decoder: TJBArith);
    function SetPrev(prev, bit: Integer): Integer;
    function Decode(cx: TJBCx): Int64;
    function DecodeIAID(cx: TJBCx; symCodeLen: Integer): Integer;
  end;

constructor TJBCx.Create(size, index: Integer);
begin
  inherited Create;
  FIndex := index;
  SetLength(FCx, size);
  SetLength(FMps, size);
end;

function TJBCx.GetCx: Integer;
begin
  Result := FCx[FIndex] and $7F;
end;

procedure TJBCx.SetCx(value: Integer);
begin
  FCx[FIndex] := Byte(value and $7F);
end;

function TJBCx.GetMps: Integer;
begin
  Result := FMps[FIndex];
end;

procedure TJBCx.ToggleMps;
begin
  FMps[FIndex] := FMps[FIndex] xor 1;
end;

procedure TJBCx.SetIndex(index: Integer);
begin
  FIndex := index;
end;

function TJBCx.Copy: TJBCx;
var i: Integer;
begin
  Result := TJBCx.Create(System.Length(FCx), FIndex);
  for i := 0 to System.Length(FCx) - 1 do
  begin
    Result.FCx[i] := FCx[i];
    Result.FMps[i] := FMps[i];
  end;
end;

constructor TJBArith.Create(reader: TJBReader);
var b: Integer;
begin
  inherited Create;
  FData := reader.FData;
  FBP := reader.FBase + reader.FPos;
  FEnd := reader.FBase + reader.FLength;
  b := GetB(FBP);
  C := LongWord(b) shl 16;
  ByteIn;
  C := C shl 7;
  CT := CT - 7;
  A := $8000;
end;

function TJBArith.GetB(i: Int64): Integer;
begin
  if (i >= 0) and (i < FEnd) and (i < System.Length(FData)) then
    Result := FData[i]
  else
    Result := $FF;
end;

procedure TJBArith.ByteIn;
var b: Integer;
begin
  b := GetB(FBP);
  if b = $FF then
  begin
    if GetB(FBP + 1) > $8F then
    begin
      C := C + $FF00;
      CT := 8;
    end
    else
    begin
      Inc(FBP);
      C := C + LongWord(GetB(FBP) shl 9);
      CT := 7;
    end;
  end
  else
  begin
    Inc(FBP);
    C := C + LongWord(GetB(FBP) shl 8);
    CT := 8;
  end;
  C := C and $FFFFFFFF;
end;

procedure TJBArith.Renorm;
begin
  repeat
    if CT = 0 then ByteIn;
    A := A shl 1;
    C := C shl 1;
    Dec(CT);
  until (A and $8000) <> 0;
  C := C and $FFFFFFFF;
end;

function TJBArith.MpsExchange(cx: TJBCx; icx: Integer): Integer;
var mps: Integer;
begin
  mps := cx.GetMps;
  if A < QE[icx][0] then
  begin
    if QE[icx][3] = 1 then cx.ToggleMps;
    cx.SetCx(QE[icx][2]);
    Result := 1 - mps;
  end
  else
  begin
    cx.SetCx(QE[icx][1]);
    Result := mps;
  end;
end;

function TJBArith.LpsExchange(cx: TJBCx; icx: Integer; qeValue: LongWord): Integer;
var mps: Integer;
begin
  mps := cx.GetMps;
  if A < qeValue then
  begin
    cx.SetCx(QE[icx][1]);
    A := qeValue;
    Result := mps;
  end
  else
  begin
    if QE[icx][3] = 1 then cx.ToggleMps;
    cx.SetCx(QE[icx][2]);
    A := qeValue;
    Result := 1 - mps;
  end;
end;

function TJBArith.Decode(cx: TJBCx): Integer;
var qeValue: LongWord; icx, d: Integer;
begin
  icx := cx.GetCx;
  qeValue := QE[icx][0];
  A := A - qeValue;
  if (C shr 16) < qeValue then
  begin
    d := LpsExchange(cx, icx, qeValue);
    Renorm;
  end
  else
  begin
    C := C - (qeValue shl 16);
    if (A and $8000) = 0 then
    begin
      d := MpsExchange(cx, icx);
      Renorm;
    end
    else
    begin
      Result := cx.GetMps;
      Exit;
    end;
  end;
  Result := d;
end;

constructor TJBIntDecoder.Create(decoder: TJBArith);
begin
  inherited Create;
  Dec_ := decoder;
end;

function TJBIntDecoder.SetPrev(prev, bit: Integer): Integer;
begin
  if prev < 256 then
    Result := ((prev shl 1) or bit) and $1FF
  else
    Result := ((((prev shl 1) or bit) and 511) or 256) and $1FF;
end;

function TJBIntDecoder.Decode(cx: TJBCx): Int64;
var prev, v, d, s, bitsToRead, offset, i: Integer;
begin
  prev := 1;
  v := 0;

  cx.SetIndex(prev and $1FF);
  s := Dec_.Decode(cx);
  prev := SetPrev(prev, s);

  cx.SetIndex(prev and $1FF);
  d := Dec_.Decode(cx);
  prev := SetPrev(prev, d);

  if d = 1 then
  begin
    cx.SetIndex(prev and $1FF);
    d := Dec_.Decode(cx);
    prev := SetPrev(prev, d);
    if d = 1 then
    begin
      cx.SetIndex(prev and $1FF);
      d := Dec_.Decode(cx);
      prev := SetPrev(prev, d);
      if d = 1 then
      begin
        cx.SetIndex(prev and $1FF);
        d := Dec_.Decode(cx);
        prev := SetPrev(prev, d);
        if d = 1 then
        begin
          cx.SetIndex(prev and $1FF);
          d := Dec_.Decode(cx);
          prev := SetPrev(prev, d);
          if d = 1 then
          begin
            bitsToRead := 32;
            offset := 4436;
          end
          else
          begin
            bitsToRead := 12;
            offset := 340;
          end;
        end
        else
        begin
          bitsToRead := 8;
          offset := 84;
        end;
      end
      else
      begin
        bitsToRead := 6;
        offset := 20;
      end;
    end
    else
    begin
      bitsToRead := 4;
      offset := 4;
    end;
  end
  else
  begin
    bitsToRead := 2;
    offset := 0;
  end;

  for i := 0 to bitsToRead - 1 do
  begin
    cx.SetIndex(prev and $1FF);
    d := Dec_.Decode(cx);
    prev := SetPrev(prev, d);
    v := (v shl 1) or d;
  end;

  v := v + offset;

  if s = 0 then
    Result := v
  else if (s = 1) and (v > 0) then
    Result := -v
  else
    Result := OOB;
end;

function TJBIntDecoder.DecodeIAID(cx: TJBCx; symCodeLen: Integer): Integer;
var prev: Int64; mask: Int64; i: Integer;
begin
  prev := 1;
  mask := (Int64(1) shl symCodeLen) - 1;
  for i := 0 to symCodeLen - 1 do
  begin
    cx.SetIndex(Integer(prev and mask));
    prev := (prev shl 1) or Dec_.Decode(cx);
  end;
  Result := Integer(prev - (Int64(1) shl symCodeLen));
end;

//============================================================================
// Huffman tables (Annex B).
//============================================================================
type
  TJBCode = record
    prefixLength: Integer;
    rangeLength: Integer;
    rangeLow: Integer;
    isLowerRange: Boolean;
    code: Integer;
  end;
  TJBCodeArray = array of TJBCode;

  TJBNode = class(TJBObject)
  public
    function Decode(iis: TJBReader): Int64; virtual; abstract;
  end;

  TJBValueNode = class(TJBNode)
  public
    rangeLen, rangeLow: Integer;
    isLowerRange: Boolean;
    constructor Create(const c: TJBCode);
    function Decode(iis: TJBReader): Int64; override;
  end;

  TJBOOBNode = class(TJBNode)
  public
    function Decode(iis: TJBReader): Int64; override;
  end;

  TJBInternalNode = class(TJBNode)
  public
    depth: Integer;
    zero, one: TJBNode;
    constructor Create(adepth: Integer);
    procedure Append(const c: TJBCode);
    function Decode(iis: TJBReader): Int64; override;
  end;

  TJBHuffmanTable = class(TJBObject)
  public
    rootNode: TJBInternalNode;
    procedure InitTree(var codeTable: TJBCodeArray);
    function Decode(iis: TJBReader): Int64;
  end;

constructor TJBValueNode.Create(const c: TJBCode);
begin
  inherited Create;
  rangeLen := c.rangeLength;
  rangeLow := c.rangeLow;
  isLowerRange := c.isLowerRange;
end;

function TJBValueNode.Decode(iis: TJBReader): Int64;
begin
  if isLowerRange then
    Result := rangeLow - iis.ReadBits(rangeLen)
  else
    Result := rangeLow + iis.ReadBits(rangeLen);
end;

function TJBOOBNode.Decode(iis: TJBReader): Int64;
begin
  Result := OOB;
end;

constructor TJBInternalNode.Create(adepth: Integer);
begin
  inherited Create;
  depth := adepth;
end;

procedure TJBInternalNode.Append(const c: TJBCode);
var shift, bit: Integer;
begin
  if c.prefixLength = 0 then Exit;
  shift := c.prefixLength - 1 - depth;
  if shift < 0 then
    raise EJBig2.Create('Negative shifting is not possible.');
  bit := (c.code shr shift) and 1;
  if shift = 0 then
  begin
    if c.rangeLength = -1 then
    begin
      if bit = 1 then one := TJBOOBNode.Create
      else zero := TJBOOBNode.Create;
    end
    else
    begin
      if bit = 1 then one := TJBValueNode.Create(c)
      else zero := TJBValueNode.Create(c);
    end;
  end
  else
  begin
    if bit = 1 then
    begin
      if one = nil then one := TJBInternalNode.Create(depth + 1);
      TJBInternalNode(one).Append(c);
    end
    else
    begin
      if zero = nil then zero := TJBInternalNode.Create(depth + 1);
      TJBInternalNode(zero).Append(c);
    end;
  end;
end;

function TJBInternalNode.Decode(iis: TJBReader): Int64;
var b: Integer; n: TJBNode;
begin
  b := iis.ReadBit;
  if b = 0 then n := zero else n := one;
  Result := n.Decode(iis);
end;

procedure TJBHuffmanTable.InitTree(var codeTable: TJBCodeArray);
var
  maxPrefixLength, curLen, curCode, i: Integer;
  lenCount, firstCode: TIntArray;
begin
  // Annex B.3 preprocessCodes -- assign canonical codes.
  maxPrefixLength := 0;
  for i := 0 to System.Length(codeTable) - 1 do
    if codeTable[i].prefixLength > maxPrefixLength then
      maxPrefixLength := codeTable[i].prefixLength;

  SetLength(lenCount, maxPrefixLength + 1);
  for i := 0 to System.Length(codeTable) - 1 do
    Inc(lenCount[codeTable[i].prefixLength]);

  SetLength(firstCode, System.Length(lenCount) + 1);
  lenCount[0] := 0;

  for curLen := 1 to System.Length(lenCount) do
  begin
    firstCode[curLen] := (firstCode[curLen - 1] + lenCount[curLen - 1]) shl 1;
    curCode := firstCode[curLen];
    for i := 0 to System.Length(codeTable) - 1 do
      if codeTable[i].prefixLength = curLen then
      begin
        codeTable[i].code := curCode;
        Inc(curCode);
      end;
  end;

  rootNode := TJBInternalNode.Create(0);
  for i := 0 to System.Length(codeTable) - 1 do
    rootNode.Append(codeTable[i]);
end;

function TJBHuffmanTable.Decode(iis: TJBReader): Int64;
begin
  Result := rootNode.Decode(iis);
end;

function MakeCode(p, r, low: Integer; lower: Boolean): TJBCode;
begin
  Result.prefixLength := p;
  Result.rangeLength := r;
  Result.rangeLow := low;
  Result.isLowerRange := lower;
  Result.code := -1;
end;

//-- Standard Huffman tables B1..B15 -----------------------------------------
// prefix, rangeLen, rangeLow, lowerFlag(999). 999 in column 3 marks a lower
// range line (B.3).
type
  TStdLine = array[0..3] of Integer;

const
  STD_LOWER = 999;

  STD_B1: array[0..3] of TStdLine = ((1,4,0,0),(2,8,16,0),(3,16,272,0),(3,32,65808,0));
  STD_B2: array[0..6] of TStdLine = ((1,0,0,0),(2,0,1,0),(3,0,2,0),(4,3,3,0),(5,6,11,0),(6,32,75,0),(6,-1,0,0));
  STD_B3: array[0..8] of TStdLine = ((8,8,-256,0),(1,0,0,0),(2,0,1,0),(3,0,2,0),(4,3,3,0),(5,6,11,0),(8,32,-257,STD_LOWER),(7,32,75,0),(6,-1,0,0));
  STD_B4: array[0..5] of TStdLine = ((1,0,1,0),(2,0,2,0),(3,0,3,0),(4,3,4,0),(5,6,12,0),(5,32,76,0));
  STD_B5: array[0..7] of TStdLine = ((7,8,-255,0),(1,0,1,0),(2,0,2,0),(3,0,3,0),(4,3,4,0),(5,6,12,0),(7,32,-256,STD_LOWER),(6,32,76,0));
  STD_B6: array[0..13] of TStdLine = ((5,10,-2048,0),(4,9,-1024,0),(4,8,-512,0),(4,7,-256,0),(5,6,-128,0),(5,5,-64,0),(4,5,-32,0),(2,7,0,0),(3,7,128,0),(3,8,256,0),(4,9,512,0),(4,10,1024,0),(6,32,-2049,STD_LOWER),(6,32,2048,0));
  STD_B7: array[0..14] of TStdLine = ((4,9,-1024,0),(3,8,-512,0),(4,7,-256,0),(5,6,-128,0),(5,5,-64,0),(4,5,-32,0),(4,5,0,0),(5,5,32,0),(5,6,64,0),(4,7,128,0),(3,8,256,0),(3,9,512,0),(3,10,1024,0),(5,32,-1025,STD_LOWER),(5,32,2048,0));
  STD_B8: array[0..20] of TStdLine = ((8,3,-15,0),(9,1,-7,0),(8,1,-5,0),(9,0,-3,0),(7,0,-2,0),(4,0,-1,0),(2,1,0,0),(5,0,2,0),(6,0,3,0),(3,4,4,0),(6,1,20,0),(4,4,22,0),(4,5,38,0),(5,6,70,0),(5,7,134,0),(6,7,262,0),(7,8,390,0),(6,10,646,0),(9,32,-16,STD_LOWER),(9,32,1670,0),(2,-1,0,0));
  STD_B9: array[0..21] of TStdLine = ((8,4,-31,0),(9,2,-15,0),(8,2,-11,0),(9,1,-7,0),(7,1,-5,0),(4,1,-3,0),(3,1,-1,0),(3,1,1,0),(5,1,3,0),(6,1,5,0),(3,5,7,0),(6,2,39,0),(4,5,43,0),(4,6,75,0),(5,7,139,0),(5,8,267,0),(6,8,523,0),(7,9,779,0),(6,11,1291,0),(9,32,-32,STD_LOWER),(9,32,3339,0),(2,-1,0,0));
  STD_B10: array[0..20] of TStdLine = ((7,4,-21,0),(8,0,-5,0),(7,0,-4,0),(5,0,-3,0),(2,2,-2,0),(5,0,2,0),(6,0,3,0),(7,0,4,0),(8,0,5,0),(2,6,6,0),(5,5,70,0),(6,5,102,0),(6,6,134,0),(6,7,198,0),(6,8,326,0),(6,9,582,0),(6,10,1094,0),(7,11,2118,0),(8,32,-22,STD_LOWER),(8,32,4166,0),(2,-1,0,0));
  STD_B11: array[0..12] of TStdLine = ((1,0,1,0),(2,1,2,0),(4,0,4,0),(4,1,5,0),(5,1,7,0),(5,2,9,0),(6,2,13,0),(7,2,17,0),(7,3,21,0),(7,4,29,0),(7,5,45,0),(7,6,77,0),(7,32,141,0));
  STD_B12: array[0..12] of TStdLine = ((1,0,1,0),(2,0,2,0),(3,1,3,0),(5,0,5,0),(5,1,6,0),(6,1,8,0),(7,0,10,0),(7,1,11,0),(7,2,13,0),(7,3,17,0),(7,4,25,0),(8,5,41,0),(8,32,73,0));
  STD_B13: array[0..12] of TStdLine = ((1,0,1,0),(3,0,2,0),(4,0,3,0),(5,0,4,0),(4,1,5,0),(3,3,7,0),(6,1,15,0),(6,2,17,0),(6,3,21,0),(6,4,29,0),(6,5,45,0),(7,6,77,0),(7,32,141,0));
  STD_B14: array[0..4] of TStdLine = ((3,0,-2,0),(3,0,-1,0),(1,0,0,0),(3,0,1,0),(3,0,2,0));
  STD_B15: array[0..12] of TStdLine = ((7,4,-24,0),(6,2,-8,0),(5,1,-4,0),(4,0,-2,0),(3,0,-1,0),(1,0,0,0),(3,0,1,0),(4,0,2,0),(5,1,3,0),(6,2,5,0),(7,4,9,0),(7,32,-25,STD_LOWER),(7,32,25,0));

// Per-thread cache of the standard Huffman tables (see GArena). Cleared and
// rebuilt at the start of every decode, freed via the arena at its end.
threadvar
  GStandardTables: array[1..15] of TJBHuffmanTable;

function BuildStandardTable(const lines: array of TStdLine): TJBHuffmanTable;
var codes: TJBCodeArray; i: Integer;
begin
  SetLength(codes, System.Length(lines));
  for i := 0 to System.Length(lines) - 1 do
    codes[i] := MakeCode(lines[i][0], lines[i][1], lines[i][2], lines[i][3] = STD_LOWER);
  Result := TJBHuffmanTable.Create;
  Result.InitTree(codes);
end;

function GetStandardTable(number: Integer): TJBHuffmanTable;
begin
  if GStandardTables[number] = nil then
  begin
    case number of
      1: GStandardTables[1] := BuildStandardTable(STD_B1);
      2: GStandardTables[2] := BuildStandardTable(STD_B2);
      3: GStandardTables[3] := BuildStandardTable(STD_B3);
      4: GStandardTables[4] := BuildStandardTable(STD_B4);
      5: GStandardTables[5] := BuildStandardTable(STD_B5);
      6: GStandardTables[6] := BuildStandardTable(STD_B6);
      7: GStandardTables[7] := BuildStandardTable(STD_B7);
      8: GStandardTables[8] := BuildStandardTable(STD_B8);
      9: GStandardTables[9] := BuildStandardTable(STD_B9);
      10: GStandardTables[10] := BuildStandardTable(STD_B10);
      11: GStandardTables[11] := BuildStandardTable(STD_B11);
      12: GStandardTables[12] := BuildStandardTable(STD_B12);
      13: GStandardTables[13] := BuildStandardTable(STD_B13);
      14: GStandardTables[14] := BuildStandardTable(STD_B14);
      15: GStandardTables[15] := BuildStandardTable(STD_B15);
    end;
  end;
  Result := GStandardTables[number];
end;

//============================================================================
// Forward declarations for the segment object model.
//============================================================================
type
  TJBSegmentData = class;
  TJBRegionInfo = class;

  TJBSegmentData = class(TJBObject)
  public
    procedure Init(header: TJBObject; sis: TJBReader); virtual; abstract;
  end;

  TJBRegion = class(TJBSegmentData)
  public
    function GetRegionBitmap: TJBBitmap; virtual; abstract;
    function GetRegionInfo: TJBRegionInfo; virtual; abstract;
  end;

  TJBDictionary = class(TJBSegmentData)
  public
    function GetDictionary: TBitmapList; virtual; abstract;
  end;

//============================================================================
// Region segment information (7.4.1).
//============================================================================
  TJBRegionInfo = class(TJBSegmentData)
  public
    sub: TJBReader;
    bitmapWidth: Integer;
    bitmapHeight: Integer;
    xLocation: Integer;
    yLocation: Integer;
    combinationOperator: Integer;
    constructor CreateWith(subInputStream: TJBReader);
    constructor CreateEmpty;
    procedure ParseHeader;
    procedure Init(header: TJBObject; sis: TJBReader); override;
  end;

constructor TJBRegionInfo.CreateWith(subInputStream: TJBReader);
begin
  inherited Create;
  sub := subInputStream;
end;

constructor TJBRegionInfo.CreateEmpty;
begin
  inherited Create;
end;

procedure TJBRegionInfo.ParseHeader;
begin
  bitmapWidth := sub.ReadBits32(32);
  bitmapHeight := sub.ReadBits32(32);
  xLocation := sub.ReadBits32(32);
  yLocation := sub.ReadBits32(32);
  sub.ReadBits(5); // reserved
  combinationOperator := TranslateCombOp(Integer(sub.ReadBits(3) and $F));
end;

procedure TJBRegionInfo.Init(header: TJBObject; sis: TJBReader);
begin
end;

//============================================================================
// Page information (7.4.8).
//============================================================================
type
  TJBPageInfo = class(TJBSegmentData)
  public
    sub: TJBReader;
    bitmapWidth, bitmapHeight: Integer;
    resolutionX, resolutionY: Integer;
    combinationOperatorOverrideAllowed: Boolean;
    combinationOperator: Integer;
    requiresAuxiliaryBuffer: Boolean;
    defaultPixelValue: Integer;
    mightContainRefinements: Boolean;
    isLossless: Boolean;
    isStriped: Boolean;
    maxStripeSize: Integer;
    procedure Init(header: TJBObject; sis: TJBReader); override;
  end;

procedure TJBPageInfo.Init(header: TJBObject; sis: TJBReader);
begin
  sub := sis;
  bitmapWidth := sub.ReadBits32(32);
  bitmapHeight := sub.ReadBits32(32);
  resolutionX := sub.ReadBits32(32);
  resolutionY := sub.ReadBits32(32);
  sub.ReadBit; // bit 7 dirty read
  if sub.ReadBit = 1 then combinationOperatorOverrideAllowed := True;
  if sub.ReadBit = 1 then requiresAuxiliaryBuffer := True;
  combinationOperator := TranslateCombOp(Integer(sub.ReadBits(2) and $F));
  defaultPixelValue := sub.ReadBit;
  if sub.ReadBit = 1 then mightContainRefinements := True;
  if sub.ReadBit = 1 then isLossless := True;
  if sub.ReadBit = 1 then isStriped := True;
  maxStripeSize := Integer(sub.ReadBits(15) and $FFFF);
end;

//============================================================================
// End of stripe (7.4.9).
//============================================================================
type
  TJBEndOfStripe = class(TJBSegmentData)
  public
    lineNumber: Integer;
    procedure Init(header: TJBObject; sis: TJBReader); override;
  end;

procedure TJBEndOfStripe.Init(header: TJBObject; sis: TJBReader);
begin
  lineNumber := sis.ReadBits32(32);
end;

//============================================================================
// Table segment (Annex B) + EncodedTable.
//============================================================================
type
  TJBTable = class(TJBSegmentData)
  public
    sub: TJBReader;
    htOutOfBand: Integer;
    htPS: Integer;
    htRS: Integer;
    htLow: Integer;
    htHigh: Integer;
    procedure Init(header: TJBObject; sis: TJBReader); override;
  end;

procedure TJBTable.Init(header: TJBObject; sis: TJBReader);
var bit: Integer;
begin
  sub := sis;
  bit := sub.ReadBit;
  if bit = 1 then
    raise EJBig2.Create('B.2.1 Code table flags: Bit 7 must be zero');
  htRS := Integer((sub.ReadBits(3) + 1) and $F);
  htPS := Integer((sub.ReadBits(3) + 1) and $F);
  htOutOfBand := sub.ReadBit;
  htLow := sub.ReadBits32(32);
  htHigh := sub.ReadBits32(32);
end;

function BuildEncodedTable(table: TJBTable): TJBHuffmanTable;
var
  sis: TJBReader;
  codes: TJBCodeArray;
  n, prefLen, rangeLen, rangeLow, curRangeLow: Integer;

  procedure AddC(const c: TJBCode);
  begin
    if n >= System.Length(codes) then SetLength(codes, (n + 8) * 2);
    codes[n] := c;
    Inc(n);
  end;

begin
  sis := table.sub;
  sis.Seek(0);
  n := 0;
  SetLength(codes, 16);
  curRangeLow := table.htLow;

  while curRangeLow < table.htHigh do
  begin
    prefLen := Integer(sis.ReadBits(table.htPS));
    rangeLen := Integer(sis.ReadBits(table.htRS));
    rangeLow := curRangeLow;
    AddC(MakeCode(prefLen, rangeLen, rangeLow, False));
    curRangeLow := curRangeLow + (1 shl rangeLen);
  end;

  prefLen := Integer(sis.ReadBits(table.htPS));
  AddC(MakeCode(prefLen, 32, table.htLow - 1, True));

  prefLen := Integer(sis.ReadBits(table.htPS));
  AddC(MakeCode(prefLen, 32, table.htHigh, False));

  if table.htOutOfBand = 1 then
  begin
    prefLen := Integer(sis.ReadBits(table.htPS));
    AddC(MakeCode(prefLen, -1, -1, False));
  end;

  SetLength(codes, n);
  Result := TJBHuffmanTable.Create;
  Result.InitTree(codes);
end;

//============================================================================
// MMR decompressor (T.6).
//============================================================================
{$I PdfJbig2Mmr.inc}

//============================================================================
// Generic region (6.2.5) -- arithmetic + MMR. Also reused by symbol dict,
// pattern dict and halftone region.
//============================================================================
type
  TJBGenericRegion = class(TJBRegion)
  public
    subInputStream: TJBReader;
    dataOffset: Int64;
    dataLength: Int64;
    regionInfo: TJBRegionInfo;
    useExtTemplates: Boolean;
    isTPGDon: Boolean;
    gbTemplate: Integer;
    isMMREncoded: Boolean;
    gbAtX, gbAtY: TIntArray;
    gbAtOverride: array of Boolean;
    override_: Boolean;
    regionBitmap: TJBBitmap;
    arithDecoder: TJBArith;
    cx: TJBCx;
    useSkip: Boolean;
    hSkip: TJBBitmap;
    mmrSet: Boolean;

    constructor CreateWith(sub: TJBReader);
    procedure ParseHeader;
    procedure ReadGbAtPixels(amount: Integer);
    procedure ComputeSegmentDataStructure;
    function GetRegionBitmap: TJBBitmap; override;
    function GetRegionInfo: TJBRegionInfo; override;
    function DecodeSLTP: Integer;
    procedure DecodeLine(lineNumber, width, rowStride, paddedWidth: Integer);
    procedure CopyLineAbove(lineNumber: Integer);
    procedure DecodeTemplate0a(lineNumber, width, rowStride, paddedWidth, byteIndex, idx: Integer);
    procedure DecodeTemplate1(lineNumber, width, rowStride, paddedWidth, byteIndex, idx: Integer);
    procedure DecodeTemplate2(lineNumber, width, rowStride, paddedWidth, byteIndex, idx: Integer);
    procedure DecodeTemplate3(lineNumber, width, rowStride, paddedWidth, byteIndex, idx: Integer);
    procedure UpdateOverrideFlags;
    procedure SetOverrideFlag(index: Integer);
    function OverrideAtTemplate0a(context, x, y, result_, minorX, toShift: Integer): Integer;
    function OverrideAtTemplate1(context, x, y, result_, minorX: Integer): Integer;
    function OverrideAtTemplate2(context, x, y, result_, minorX: Integer): Integer;
    function OverrideAtTemplate3(context, x, y, result_, minorX: Integer): Integer;
    function GetPixelSafe(x, y: Integer): Integer;
    procedure SetParamsSym(aIsMMR: Boolean; sdTemplate: Integer; aIsTPGDon, aUseSkip: Boolean;
      sdATX, sdATY: TIntArray; symWidth, hcHeight: Integer; acx: TJBCx; aArith: TJBArith);
    procedure SetParamsCollective(aIsMMR: Boolean; aDataOffset, aDataLength: Int64; gbh, gbw: Integer);
    procedure SetParamsFull(aIsMMR: Boolean; aDataOffset, aDataLength: Int64; gbh, gbw, aTemplate: Integer;
      aIsTPGDon, aUseSkip: Boolean; aHSkip: TJBBitmap; aGbAtX, aGbAtY: TIntArray);
    procedure ResetBitmap;
    procedure Init(header: TJBObject; sis: TJBReader); override;
  end;

//============================================================================
// Generic refinement region decoding procedure (6.3.5.6).
//============================================================================
  TJBRefinement = class(TJBObject)
  public
    arithDecoder: TJBArith;
    cx: TJBCx;
    templateID: Integer;
    referenceBitmap: TJBBitmap;
    referenceDX, referenceDY: Integer;
    grAtX, grAtY: TIntArray;
    override_: Boolean;
    grAtOverride: array of Boolean;
    regionBitmap: TJBBitmap;
    class function Decode(aArith: TJBArith; aCx: TJBCx; width, height, grTemplate: Integer;
      isTPGROn: Boolean; refBmp: TJBBitmap; refDX, refDY: Integer;
      aGrAtX, aGrAtY: TIntArray): TJBBitmap;
    function Run(width, height, grTemplate: Integer; isTPGROn: Boolean; refBmp: TJBBitmap;
      refDX, refDY: Integer; aGrAtX, aGrAtY: TIntArray): TJBBitmap;
    function GetReferenceBit(x, y: Integer): Integer;
    function GetRegionBit(x, y: Integer): Integer;
    function BuildContextT1(x, y: Integer): Integer;
    function BuildContextT0(x, y: Integer): Integer;
    function DecodeSLTP: Integer;
    procedure DecodeLineExplicit(y, width: Integer);
    procedure DecodeLineTPGR(y, width: Integer);
    procedure UpdateOverride;
  end;

//----------------------------------------------------------------------------
// GenericRegion implementation
//----------------------------------------------------------------------------
constructor TJBGenericRegion.CreateWith(sub: TJBReader);
begin
  inherited Create;
  subInputStream := sub;
  regionInfo := TJBRegionInfo.CreateWith(sub);
end;

procedure TJBGenericRegion.ReadGbAtPixels(amount: Integer);
var i: Integer;
begin
  SetLength(gbAtX, amount);
  SetLength(gbAtY, amount);
  for i := 0 to amount - 1 do
  begin
    gbAtX[i] := subInputStream.ReadByteSigned;
    gbAtY[i] := subInputStream.ReadByteSigned;
  end;
end;

procedure TJBGenericRegion.ComputeSegmentDataStructure;
begin
  dataOffset := subInputStream.StreamPosition;
  dataLength := subInputStream.Length_ - dataOffset;
end;

procedure TJBGenericRegion.ParseHeader;
var amountOfGbAt: Integer;
begin
  regionInfo.ParseHeader;
  subInputStream.ReadBits(3); // bit 5-7 dirty
  if subInputStream.ReadBit = 1 then useExtTemplates := True;
  if subInputStream.ReadBit = 1 then isTPGDon := True;
  gbTemplate := Integer(subInputStream.ReadBits(2) and $F);
  if subInputStream.ReadBit = 1 then isMMREncoded := True;

  if not isMMREncoded then
  begin
    if gbTemplate = 0 then
    begin
      if useExtTemplates then amountOfGbAt := 12 else amountOfGbAt := 4;
    end
    else
      amountOfGbAt := 1;
    ReadGbAtPixels(amountOfGbAt);
  end;
  ComputeSegmentDataStructure;
end;

function TJBGenericRegion.GetPixelSafe(x, y: Integer): Integer;
begin
  if (x < 0) or (x >= regionBitmap.Width) or (y < 0) or (y >= regionBitmap.Height) then
    Result := 0
  else
    Result := regionBitmap.GetPixel(x, y);
end;

function TJBGenericRegion.DecodeSLTP: Integer;
begin
  case gbTemplate of
    0: cx.SetIndex($9B25);
    1: cx.SetIndex($795);
    2: cx.SetIndex($E5);
    3: cx.SetIndex($195);
  end;
  Result := arithDecoder.Decode(cx);
end;

procedure TJBGenericRegion.CopyLineAbove(lineNumber: Integer);
var targetByteIndex, sourceByteIndex, i: Integer;
begin
  targetByteIndex := lineNumber * regionBitmap.RowStride;
  sourceByteIndex := targetByteIndex - regionBitmap.RowStride;
  for i := 0 to regionBitmap.RowStride - 1 do
  begin
    regionBitmap.SetByte(targetByteIndex, regionBitmap.GetByte(sourceByteIndex));
    Inc(targetByteIndex);
    Inc(sourceByteIndex);
  end;
end;

procedure TJBGenericRegion.DecodeTemplate0a(lineNumber, width, rowStride, paddedWidth, byteIndex, idx: Integer);
var context, line1, line2, nextByte, x, minorWidth, minorX, toShift, bit, oc: Integer;
    result_: Integer;
begin
  line1 := 0; line2 := 0;
  if lineNumber >= 1 then line1 := regionBitmap.GetByte(idx);
  if lineNumber >= 2 then line2 := regionBitmap.GetByte(idx - rowStride) shl 6;
  context := (line1 and $F0) or (line2 and $3800);

  x := 0;
  while x < paddedWidth do
  begin
    result_ := 0;
    nextByte := x + 8;
    if width - x > 8 then minorWidth := 8 else minorWidth := width - x;
    if lineNumber > 0 then
    begin
      if nextByte < width then line1 := (line1 shl 8) or regionBitmap.GetByte(idx + 1)
      else line1 := line1 shl 8;
    end;
    if lineNumber > 1 then
    begin
      if nextByte < width then line2 := (line2 shl 8) or (regionBitmap.GetByte(idx - rowStride + 1) shl 6)
      else line2 := line2 shl 8;
    end;
    for minorX := 0 to minorWidth - 1 do
    begin
      toShift := 7 - minorX;
      if override_ then
      begin
        oc := OverrideAtTemplate0a(context, x + minorX, lineNumber, result_, minorX, toShift);
        cx.SetIndex(oc);
      end
      else
        cx.SetIndex(context);
      if useSkip and (hSkip.GetPixel(x + minorX, lineNumber) = 1) then bit := 0
      else bit := arithDecoder.Decode(cx);
      result_ := result_ or (bit shl toShift);
      context := ((context and $7BF7) shl 1) or bit or ((line1 shr toShift) and $10)
        or ((line2 shr toShift) and $800);
    end;
    regionBitmap.SetByte(byteIndex, result_);
    Inc(byteIndex);
    Inc(idx);
    x := nextByte;
  end;
end;

procedure TJBGenericRegion.DecodeTemplate1(lineNumber, width, rowStride, paddedWidth, byteIndex, idx: Integer);
var context, line1, line2, nextByte, x, minorWidth, minorX, toShift, bit, oc: Integer;
    result_: Integer;
begin
  line1 := 0; line2 := 0;
  if lineNumber >= 1 then line1 := regionBitmap.GetByte(idx);
  if lineNumber >= 2 then line2 := regionBitmap.GetByte(idx - rowStride) shl 5;
  context := ((line1 shr 1) and $1F8) or ((line2 shr 1) and $1E00);

  x := 0;
  while x < paddedWidth do
  begin
    result_ := 0;
    nextByte := x + 8;
    if width - x > 8 then minorWidth := 8 else minorWidth := width - x;
    if lineNumber >= 1 then
    begin
      if nextByte < width then line1 := (line1 shl 8) or regionBitmap.GetByte(idx + 1)
      else line1 := line1 shl 8;
    end;
    if lineNumber >= 2 then
    begin
      if nextByte < width then line2 := (line2 shl 8) or (regionBitmap.GetByte(idx - rowStride + 1) shl 5)
      else line2 := line2 shl 8;
    end;
    for minorX := 0 to minorWidth - 1 do
    begin
      if override_ then
      begin
        oc := OverrideAtTemplate1(context, x + minorX, lineNumber, result_, minorX);
        cx.SetIndex(oc);
      end
      else
        cx.SetIndex(context);
      if useSkip and (hSkip.GetPixel(x + minorX, lineNumber) = 1) then bit := 0
      else bit := arithDecoder.Decode(cx);
      result_ := result_ or (bit shl (7 - minorX));
      toShift := 8 - minorX;
      context := ((context and $EFB) shl 1) or bit or ((line1 shr toShift) and $8)
        or ((line2 shr toShift) and $200);
    end;
    regionBitmap.SetByte(byteIndex, result_);
    Inc(byteIndex);
    Inc(idx);
    x := nextByte;
  end;
end;

procedure TJBGenericRegion.DecodeTemplate2(lineNumber, width, rowStride, paddedWidth, byteIndex, idx: Integer);
var context, line1, line2, nextByte, x, minorWidth, minorX, toShift, bit, oc: Integer;
    result_: Integer;
begin
  line1 := 0; line2 := 0;
  if lineNumber >= 1 then line1 := regionBitmap.GetByte(idx);
  if lineNumber >= 2 then line2 := regionBitmap.GetByte(idx - rowStride) shl 4;
  context := ((line1 shr 3) and $7C) or ((line2 shr 3) and $380);

  x := 0;
  while x < paddedWidth do
  begin
    result_ := 0;
    nextByte := x + 8;
    if width - x > 8 then minorWidth := 8 else minorWidth := width - x;
    if lineNumber >= 1 then
    begin
      if nextByte < width then line1 := (line1 shl 8) or regionBitmap.GetByte(idx + 1)
      else line1 := line1 shl 8;
    end;
    if lineNumber >= 2 then
    begin
      if nextByte < width then line2 := (line2 shl 8) or (regionBitmap.GetByte(idx - rowStride + 1) shl 4)
      else line2 := line2 shl 8;
    end;
    for minorX := 0 to minorWidth - 1 do
    begin
      if override_ then
      begin
        oc := OverrideAtTemplate2(context, x + minorX, lineNumber, result_, minorX);
        cx.SetIndex(oc);
      end
      else
        cx.SetIndex(context);
      if useSkip and (hSkip.GetPixel(x + minorX, lineNumber) = 1) then bit := 0
      else bit := arithDecoder.Decode(cx);
      result_ := result_ or (bit shl (7 - minorX));
      toShift := 10 - minorX;
      context := ((context and $1BD) shl 1) or bit or ((line1 shr toShift) and $4)
        or ((line2 shr toShift) and $80);
    end;
    regionBitmap.SetByte(byteIndex, result_);
    Inc(byteIndex);
    Inc(idx);
    x := nextByte;
  end;
end;

procedure TJBGenericRegion.DecodeTemplate3(lineNumber, width, rowStride, paddedWidth, byteIndex, idx: Integer);
var context, line1, nextByte, x, minorWidth, minorX, bit, oc: Integer;
    result_: Integer;
begin
  line1 := 0;
  if lineNumber >= 1 then line1 := regionBitmap.GetByte(idx);
  context := (line1 shr 1) and $70;

  x := 0;
  while x < paddedWidth do
  begin
    result_ := 0;
    nextByte := x + 8;
    if width - x > 8 then minorWidth := 8 else minorWidth := width - x;
    if lineNumber >= 1 then
    begin
      if nextByte < width then line1 := (line1 shl 8) or regionBitmap.GetByte(idx + 1)
      else line1 := line1 shl 8;
    end;
    for minorX := 0 to minorWidth - 1 do
    begin
      if override_ then
      begin
        oc := OverrideAtTemplate3(context, x + minorX, lineNumber, result_, minorX);
        cx.SetIndex(oc);
      end
      else
        cx.SetIndex(context);
      if useSkip and (hSkip.GetPixel(x + minorX, lineNumber) = 1) then bit := 0
      else bit := arithDecoder.Decode(cx);
      result_ := result_ or (bit shl (7 - minorX));
      context := ((context and $1F7) shl 1) or bit or ((line1 shr (8 - minorX)) and $10);
    end;
    regionBitmap.SetByte(byteIndex, result_);
    Inc(byteIndex);
    Inc(idx);
    x := nextByte;
  end;
end;

procedure TJBGenericRegion.DecodeLine(lineNumber, width, rowStride, paddedWidth: Integer);
var byteIndex, idx: Integer;
begin
  byteIndex := regionBitmap.GetByteIndex(0, lineNumber);
  idx := byteIndex - rowStride;
  case gbTemplate of
    0: DecodeTemplate0a(lineNumber, width, rowStride, paddedWidth, byteIndex, idx);
    1: DecodeTemplate1(lineNumber, width, rowStride, paddedWidth, byteIndex, idx);
    2: DecodeTemplate2(lineNumber, width, rowStride, paddedWidth, byteIndex, idx);
    3: DecodeTemplate3(lineNumber, width, rowStride, paddedWidth, byteIndex, idx);
  end;
end;

procedure TJBGenericRegion.SetOverrideFlag(index: Integer);
begin
  gbAtOverride[index] := True;
  override_ := True;
end;

procedure TJBGenericRegion.UpdateOverrideFlags;
begin
  if (gbAtX = nil) or (gbAtY = nil) then Exit;
  if System.Length(gbAtX) <> System.Length(gbAtY) then Exit;
  SetLength(gbAtOverride, System.Length(gbAtX));
  case gbTemplate of
    0:
      if not useExtTemplates then
      begin
        if (gbAtX[0] <> 3) or (gbAtY[0] <> -1) then SetOverrideFlag(0);
        if (gbAtX[1] <> -3) or (gbAtY[1] <> -1) then SetOverrideFlag(1);
        if (gbAtX[2] <> 2) or (gbAtY[2] <> -2) then SetOverrideFlag(2);
        if (gbAtX[3] <> -2) or (gbAtY[3] <> -2) then SetOverrideFlag(3);
      end
      else
      begin
        if (gbAtX[0] <> -2) or (gbAtY[0] <> 0) then SetOverrideFlag(0);
        if (gbAtX[1] <> 0) or (gbAtY[1] <> -2) then SetOverrideFlag(1);
        if (gbAtX[2] <> -2) or (gbAtY[2] <> -1) then SetOverrideFlag(2);
        if (gbAtX[3] <> -1) or (gbAtY[3] <> -2) then SetOverrideFlag(3);
        if (gbAtX[4] <> 1) or (gbAtY[4] <> -2) then SetOverrideFlag(4);
        if (gbAtX[5] <> 2) or (gbAtY[5] <> -1) then SetOverrideFlag(5);
        if (gbAtX[6] <> -3) or (gbAtY[6] <> 0) then SetOverrideFlag(6);
        if (gbAtX[7] <> -4) or (gbAtY[7] <> 0) then SetOverrideFlag(7);
        if (gbAtX[8] <> 2) or (gbAtY[8] <> -2) then SetOverrideFlag(8);
        if (gbAtX[9] <> 3) or (gbAtY[9] <> -1) then SetOverrideFlag(9);
        if (gbAtX[10] <> -2) or (gbAtY[10] <> -2) then SetOverrideFlag(10);
        if (gbAtX[11] <> -3) or (gbAtY[11] <> -1) then SetOverrideFlag(11);
      end;
    1: if (gbAtX[0] <> 3) or (gbAtY[0] <> -1) then SetOverrideFlag(0);
    2: if (gbAtX[0] <> 2) or (gbAtY[0] <> -1) then SetOverrideFlag(0);
    3: if (gbAtX[0] <> 2) or (gbAtY[0] <> -1) then SetOverrideFlag(0);
  end;
end;

function TJBGenericRegion.OverrideAtTemplate0a(context, x, y, result_, minorX, toShift: Integer): Integer;
begin
  if gbAtOverride[0] then
  begin
    context := context and $FFEF;
    if (gbAtY[0] = 0) and (gbAtX[0] >= -minorX) then
      context := context or (((result_ shr (toShift - gbAtX[0])) and $1) shl 4)
    else
      context := context or (GetPixelSafe(x + gbAtX[0], y + gbAtY[0]) shl 4);
  end;
  if gbAtOverride[1] then
  begin
    context := context and $FBFF;
    if (gbAtY[1] = 0) and (gbAtX[1] >= -minorX) then
      context := context or (((result_ shr (toShift - gbAtX[1])) and $1) shl 10)
    else
      context := context or (GetPixelSafe(x + gbAtX[1], y + gbAtY[1]) shl 10);
  end;
  if gbAtOverride[2] then
  begin
    context := context and $F7FF;
    if (gbAtY[2] = 0) and (gbAtX[2] >= -minorX) then
      context := context or (((result_ shr (toShift - gbAtX[2])) and $1) shl 11)
    else
      context := context or (GetPixelSafe(x + gbAtX[2], y + gbAtY[2]) shl 11);
  end;
  if gbAtOverride[3] then
  begin
    context := context and $7FFF;
    if (gbAtY[3] = 0) and (gbAtX[3] >= -minorX) then
      context := context or (((result_ shr (toShift - gbAtX[3])) and $1) shl 15)
    else
      context := context or (GetPixelSafe(x + gbAtX[3], y + gbAtY[3]) shl 15);
  end;
  Result := context;
end;

function TJBGenericRegion.OverrideAtTemplate1(context, x, y, result_, minorX: Integer): Integer;
begin
  context := context and $1FF7;
  if (gbAtY[0] = 0) and (gbAtX[0] >= -minorX) then
    Result := context or (((result_ shr (7 - (minorX + gbAtX[0]))) and $1) shl 3)
  else
    Result := context or (GetPixelSafe(x + gbAtX[0], y + gbAtY[0]) shl 3);
end;

function TJBGenericRegion.OverrideAtTemplate2(context, x, y, result_, minorX: Integer): Integer;
begin
  context := context and $3FB;
  if (gbAtY[0] = 0) and (gbAtX[0] >= -minorX) then
    Result := context or (((result_ shr (7 - (minorX + gbAtX[0]))) and $1) shl 2)
  else
    Result := context or (GetPixelSafe(x + gbAtX[0], y + gbAtY[0]) shl 2);
end;

function TJBGenericRegion.OverrideAtTemplate3(context, x, y, result_, minorX: Integer): Integer;
begin
  context := context and $3EF;
  if (gbAtY[0] = 0) and (gbAtX[0] >= -minorX) then
    Result := context or (((result_ shr (7 - (minorX + gbAtX[0]))) and $1) shl 4)
  else
    Result := context or (GetPixelSafe(x + gbAtX[0], y + gbAtY[0]) shl 4);
end;

function TJBGenericRegion.GetRegionBitmap: TJBBitmap;
var ltp, line, paddedWidth: Integer;
    mmr: TJBMMRDecompressor;
    mmrReader: TJBReader;
begin
  if regionBitmap = nil then
  begin
    if isMMREncoded then
    begin
      mmrReader := subInputStream.NewWindow(dataOffset, dataLength);
      mmr := TJBMMRDecompressor.Create(regionInfo.bitmapWidth, regionInfo.bitmapHeight, mmrReader);
      regionBitmap := mmr.Uncompress;
    end
    else
    begin
      UpdateOverrideFlags;
      ltp := 0;
      if arithDecoder = nil then arithDecoder := TJBArith.Create(subInputStream);
      if cx = nil then cx := TJBCx.Create(65536, 1);
      regionBitmap := TJBBitmap.Create(regionInfo.bitmapWidth, regionInfo.bitmapHeight);
      paddedWidth := (regionBitmap.Width + 7) and (not 7);
      for line := 0 to regionBitmap.Height - 1 do
      begin
        if isTPGDon then ltp := ltp xor DecodeSLTP;
        if ltp = 1 then
        begin
          if line > 0 then CopyLineAbove(line);
        end
        else
          DecodeLine(line, regionBitmap.Width, regionBitmap.RowStride, paddedWidth);
      end;
    end;
  end;
  Result := regionBitmap;
end;

function TJBGenericRegion.GetRegionInfo: TJBRegionInfo;
begin
  Result := regionInfo;
end;

procedure TJBGenericRegion.SetParamsSym(aIsMMR: Boolean; sdTemplate: Integer; aIsTPGDon, aUseSkip: Boolean;
  sdATX, sdATY: TIntArray; symWidth, hcHeight: Integer; acx: TJBCx; aArith: TJBArith);
begin
  isMMREncoded := aIsMMR;
  gbTemplate := sdTemplate;
  isTPGDon := aIsTPGDon;
  gbAtX := sdATX;
  gbAtY := sdATY;
  regionInfo.bitmapWidth := symWidth;
  regionInfo.bitmapHeight := hcHeight;
  if acx <> nil then cx := acx;
  if aArith <> nil then arithDecoder := aArith;
  useSkip := aUseSkip;
  ResetBitmap;
end;

procedure TJBGenericRegion.SetParamsCollective(aIsMMR: Boolean; aDataOffset, aDataLength: Int64; gbh, gbw: Integer);
begin
  isMMREncoded := aIsMMR;
  dataOffset := aDataOffset;
  dataLength := aDataLength;
  regionInfo.bitmapHeight := gbh;
  regionInfo.bitmapWidth := gbw;
  ResetBitmap;
end;

procedure TJBGenericRegion.SetParamsFull(aIsMMR: Boolean; aDataOffset, aDataLength: Int64; gbh, gbw, aTemplate: Integer;
  aIsTPGDon, aUseSkip: Boolean; aHSkip: TJBBitmap; aGbAtX, aGbAtY: TIntArray);
begin
  dataOffset := aDataOffset;
  dataLength := aDataLength;
  regionInfo := TJBRegionInfo.CreateEmpty;
  regionInfo.bitmapHeight := gbh;
  regionInfo.bitmapWidth := gbw;
  gbTemplate := aTemplate;
  isMMREncoded := aIsMMR;
  isTPGDon := aIsTPGDon;
  gbAtX := aGbAtX;
  gbAtY := aGbAtY;
  useSkip := aUseSkip;
  hSkip := aHSkip;
end;

procedure TJBGenericRegion.ResetBitmap;
begin
  regionBitmap := nil;
end;

procedure TJBGenericRegion.Init(header: TJBObject; sis: TJBReader);
begin
  subInputStream := sis;
  regionInfo := TJBRegionInfo.CreateWith(subInputStream);
  ParseHeader;
end;

//----------------------------------------------------------------------------
// Generic refinement region implementation (pixel-based template 0 and 1).
//----------------------------------------------------------------------------
const
  SLTP_CONTEXT_T0 = $0100;
  SLTP_CONTEXT_T1 = $0008;

class function TJBRefinement.Decode(aArith: TJBArith; aCx: TJBCx; width, height, grTemplate: Integer;
  isTPGROn: Boolean; refBmp: TJBBitmap; refDX, refDY: Integer; aGrAtX, aGrAtY: TIntArray): TJBBitmap;
var inst: TJBRefinement;
begin
  inst := TJBRefinement.Create;
  inst.arithDecoder := aArith;
  inst.cx := aCx;
  Result := inst.Run(width, height, grTemplate, isTPGROn, refBmp, refDX, refDY, aGrAtX, aGrAtY);
end;

function TJBRefinement.GetReferenceBit(x, y: Integer): Integer;
begin
  Result := referenceBitmap.GetPixelSafe(x - referenceDX, y - referenceDY);
end;

function TJBRefinement.GetRegionBit(x, y: Integer): Integer;
begin
  Result := regionBitmap.GetPixelSafe(x, y);
end;

// Template 1 context (Figure 13), GRREG before GRREFERENCE.
function TJBRefinement.BuildContextT1(x, y: Integer): Integer;
begin
  Result := (GetRegionBit(x - 1, y - 1) shl 9)
    or (GetRegionBit(x, y - 1) shl 8)
    or (GetRegionBit(x + 1, y - 1) shl 7)
    or (GetRegionBit(x - 1, y) shl 6)
    or (GetReferenceBit(x, y - 1) shl 5)
    or (GetReferenceBit(x - 1, y) shl 4)
    or (GetReferenceBit(x, y) shl 3)
    or (GetReferenceBit(x + 1, y) shl 2)
    or (GetReferenceBit(x, y + 1) shl 1)
    or (GetReferenceBit(x + 1, y + 1));
end;

// Template 0 context (Figure 12) with AT pixels A1 (coding) and A2 (reference).
// The 13-bit bit->pixel layout is derived from PDFBox's optimised template-0
// context-update masks (decodeTypicalPredictedLineTemplate0 + overrideAtTemplate0),
// so the SLTP pseudo-pixel value is 0x0100 (reference centre pixel = 1) and the
// labels match the encoder.
//   bit 0      : GRREG (x-1,y)               [left neighbour, current line]
//   bits 1..3  : GRREG (x+1,y-1),(x,y-1),A1  [A1 default (x-1,y-1)]
//   bits 4..6  : GRREFERENCE (x+1,y+1),(x,y+1),(x-1,y+1)
//   bits 7..9  : GRREFERENCE (x+1,y),(x,y),(x-1,y)
//   bits 10..12: GRREFERENCE (x+1,y-1),(x,y-1),A2  [A2 default (x-1,y-1)]
function TJBRefinement.BuildContextT0(x, y: Integer): Integer;
var a1x, a1y, a2x, a2y: Integer;
begin
  a1x := -1; a1y := -1; a2x := -1; a2y := -1;
  if (grAtX <> nil) and (System.Length(grAtX) >= 2) then
  begin
    a1x := grAtX[0]; a1y := grAtY[0];
    a2x := grAtX[1]; a2y := grAtY[1];
  end;
  Result :=
      (GetRegionBit(x - 1, y))
    or (GetRegionBit(x + 1, y - 1) shl 1)
    or (GetRegionBit(x, y - 1) shl 2)
    or (GetRegionBit(x + a1x, y + a1y) shl 3)
    or (GetReferenceBit(x + 1, y + 1) shl 4)
    or (GetReferenceBit(x, y + 1) shl 5)
    or (GetReferenceBit(x - 1, y + 1) shl 6)
    or (GetReferenceBit(x + 1, y) shl 7)
    or (GetReferenceBit(x, y) shl 8)
    or (GetReferenceBit(x - 1, y) shl 9)
    or (GetReferenceBit(x + 1, y - 1) shl 10)
    or (GetReferenceBit(x, y - 1) shl 11)
    or (GetReferenceBit(x + a2x, y + a2y) shl 12);
end;

function TJBRefinement.DecodeSLTP: Integer;
begin
  if templateID = 0 then cx.SetIndex(SLTP_CONTEXT_T0)
  else cx.SetIndex(SLTP_CONTEXT_T1);
  Result := arithDecoder.Decode(cx);
end;

procedure TJBRefinement.DecodeLineExplicit(y, width: Integer);
var x: Integer;
begin
  for x := 0 to width - 1 do
  begin
    if templateID = 0 then cx.SetIndex(BuildContextT0(x, y))
    else cx.SetIndex(BuildContextT1(x, y));
    regionBitmap.SetPixel(x, y, arithDecoder.Decode(cx));
  end;
end;

procedure TJBRefinement.DecodeLineTPGR(y, width: Integer);
var x, center, dx, dy, bit: Integer; uniform: Boolean;
begin
  for x := 0 to width - 1 do
  begin
    center := GetReferenceBit(x, y);
    uniform := True;
    for dy := -1 to 1 do
    begin
      for dx := -1 to 1 do
        if GetReferenceBit(x + dx, y + dy) <> center then
        begin
          uniform := False;
          Break;
        end;
      if not uniform then Break;
    end;
    if uniform then bit := center
    else
    begin
      if templateID = 0 then cx.SetIndex(BuildContextT0(x, y))
      else cx.SetIndex(BuildContextT1(x, y));
      bit := arithDecoder.Decode(cx);
    end;
    regionBitmap.SetPixel(x, y, bit);
  end;
end;

procedure TJBRefinement.UpdateOverride;
begin
  if (grAtX = nil) or (grAtY = nil) then Exit;
  if System.Length(grAtX) <> System.Length(grAtY) then Exit;
  SetLength(grAtOverride, System.Length(grAtX));
end;

function TJBRefinement.Run(width, height, grTemplate: Integer; isTPGROn: Boolean; refBmp: TJBBitmap;
  refDX, refDY: Integer; aGrAtX, aGrAtY: TIntArray): TJBBitmap;
var ltp, y: Integer;
begin
  templateID := grTemplate;
  referenceBitmap := refBmp;
  referenceDX := refDX;
  referenceDY := refDY;
  grAtX := aGrAtX;
  grAtY := aGrAtY;
  override_ := False;

  regionBitmap := TJBBitmap.Create(width, height);
  if templateID = 0 then UpdateOverride;

  ltp := 0;
  for y := 0 to height - 1 do
  begin
    if isTPGROn then ltp := ltp xor DecodeSLTP;
    if ltp = 0 then DecodeLineExplicit(y, width)
    else DecodeLineTPGR(y, width);
  end;
  Result := regionBitmap;
end;

{$I PdfJbig2Seg.inc}

//============================================================================
// Public entry points.
//============================================================================
function DecodeJBIG2Packed(const Data, Globals: TBytes; out OutW, OutH: Integer;
  out Bits: TBytes): Boolean;
var
  doc: TJBDocument;
  page: TJBPage;
  bmp: TJBBitmap;
  i: Integer;
begin
  Result := False;
  OutW := 0; OutH := 0; Bits := nil;
  // GArena and the cached tables are threadvars, so this whole run works on
  // per-thread state - concurrent decodes on other threads don't interfere and
  // no lock is needed.
  GArena := TList.Create;
  // Cached tables live in the arena and are freed below; clear the (per-thread)
  // globals so they are rebuilt fresh inside this run's arena.
  FillChar(GStandardTables, SizeOf(GStandardTables), 0);
  GWhiteTable := nil; GBlackTable := nil; GModeTable := nil;
  try
    try
      doc := TJBDocument.Create(Data, Globals);
      page := doc.GetPage(1);
      if page = nil then
      begin
        LastJBIG2Error := Format('no page 1 (pages=%d, globals=%d)', [doc.pageCount, doc.globalCount]);
        Exit;
      end;
      bmp := page.GetBitmap;
      if bmp = nil then
      begin
        LastJBIG2Error := 'page bitmap is nil';
        Exit;
      end;
      OutW := bmp.Width;
      OutH := bmp.Height;
      SetLength(Bits, System.Length(bmp.Bytes));
      for i := 0 to System.Length(bmp.Bytes) - 1 do
        Bits[i] := bmp.Bytes[i];
      Result := True;
    except
      on E: Exception do
      begin
        LastJBIG2Error := E.ClassName + ': ' + E.Message;
        Result := False;
      end;
    end;
  finally
    for i := 0 to GArena.Count - 1 do
      TObject(GArena[i]).Free;
    GArena.Free;
    GArena := nil;
  end;
end;

function DecodeJBIG2(const Data, Globals: TBytes; out OutW, OutH: Integer;
  out Gray: TBytes): Boolean;
var
  packed_: TBytes;
  rowStride, x, y, bit: Integer;
begin
  Gray := nil;
  Result := DecodeJBIG2Packed(Data, Globals, OutW, OutH, packed_);
  if not Result then Exit;
  rowStride := (OutW + 7) shr 3;
  SetLength(Gray, OutW * OutH);
  for y := 0 to OutH - 1 do
    for x := 0 to OutW - 1 do
    begin
      bit := (packed_[y * rowStride + (x shr 3)] shr (7 - (x and 7))) and 1;
      if bit = 1 then Gray[y * OutW + x] := 0       // black
      else Gray[y * OutW + x] := 255;               // white
    end;
end;

// No initialization needed: GArena and the table caches are threadvars, zeroed
// per thread and (re)built inside each decode run.
end.
