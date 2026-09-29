unit XelXps;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	XPS / OpenXPS page-preview decoder                            //
// Version:	0.1                                                           //
// Date:	26-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// XPS/OXPS is an OPC (ZIP) package of FixedPage XAML plus fonts and images.
// Rendering the vector/glyph page markup would require a full XAML + OpenType
// renderer, which is out of scope. Instead this reads the ZIP directory and
// decodes the best available *rendered* raster - the page thumbnail if present
// (docProps/thumbnail.jpeg, *Thumbnail*.jpg), otherwise the largest embedded
// page image - via the project's JPEG / PNG / TIFF decoders. That yields a real
// preview of the first page (often lower resolution than the vector original).

interface

uses
  SysUtils, Classes, XelInflate, XelJpeg, XelPng, XelTiff;

type
  EXpsError = class(Exception);

function DecodeXps(InBuf: TBytes; out Width, Height: Integer): TBytes;   // RGBA8

implementation

function U16(const D: TBytes; P: NativeUInt): Word; inline;
begin Result := Word(D[P]) or (Word(D[P+1]) shl 8); end;

function U32(const D: TBytes; P: NativeUInt): Cardinal; inline;
begin
  Result := Cardinal(D[P]) or (Cardinal(D[P+1]) shl 8) or
            (Cardinal(D[P+2]) shl 16) or (Cardinal(D[P+3]) shl 24);
end;

// Extracts one ZIP entry (stored or deflated) given its central-directory record.
function ExtractEntry(const D: TBytes; Method: Word; CompSize, LocalOfs: Cardinal): TBytes;
var
  fnLen, exLen: Word;
  dataOfs: NativeUInt;
begin
  Result := nil;
  if (LocalOfs + 30 > Cardinal(Length(D))) or (U32(D, LocalOfs) <> $04034B50) then Exit;
  fnLen := U16(D, LocalOfs + 26);
  exLen := U16(D, LocalOfs + 28);
  dataOfs := LocalOfs + 30 + fnLen + exLen;
  if dataOfs + CompSize > Cardinal(Length(D)) then Exit;
  if Method = 0 then
  begin
    SetLength(Result, CompSize);
    if CompSize > 0 then Move(D[dataOfs], Result[0], CompSize);
  end
  else if Method = 8 then
    Result := InflateRaw(@D[dataOfs], CompSize)
  else
    Result := nil;
end;

// Decodes a JPEG/PNG/TIFF blob by magic.
function DecodeImageBlob(const Blob: TBytes; out W, H: Integer): TBytes;
begin
  Result := nil; W := 0; H := 0;
  if Length(Blob) < 4 then Exit;
  if (Blob[0] = $FF) and (Blob[1] = $D8) then Result := DecodeJpeg(Blob, W, H)
  else if (Blob[0] = $89) and (Blob[1] = $50) and (Blob[2] = $4E) and (Blob[3] = $47) then
    Result := DecodePng(Blob, W, H)
  else if ((Blob[0] = $49) and (Blob[1] = $49)) or ((Blob[0] = $4D) and (Blob[1] = $4D)) then
    Result := DecodeTiff(Blob, W, H);
end;

function LowerExtIs(const Name: string; const Exts: array of string): Boolean;
var e, lo: string; i: Integer;
begin
  Result := False; lo := LowerCase(Name);
  for i := 0 to High(Exts) do
  begin
    e := Exts[i];
    if (Length(lo) >= Length(e)) and (Copy(lo, Length(lo) - Length(e) + 1, Length(e)) = e) then
      Exit(True);
  end;
end;

function DecodeXps(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  N, eocd, cdOfs, p: NativeUInt;
  cnt, i: Integer;
  method: Word;
  compSize, localOfs, fnLen, exLen, cmLen: Cardinal;
  fname, lname: string;
  Blob: TBytes;
  k: Integer;
  bestThumbIdx, bestImgIdx: Integer;
  bestThumbSize, bestImgSize: Cardinal;
  // parallel arrays of candidate entries
  cMethod: array of Word;
  cComp, cLocal: array of Cardinal;
  cName: array of string;
begin
  Width := 0; Height := 0; SetLength(Result, 0);
  N := NativeUInt(Length(InBuf));
  if (N < 22) or (InBuf[0] <> $50) or (InBuf[1] <> $4B) then
    raise EXpsError.Create('XPS: not a ZIP/OPC package');

  // locate End Of Central Directory (scan back over up to 64K comment)
  eocd := 0;
  p := N - 22;
  while True do
  begin
    if U32(InBuf, p) = $06054B50 then begin eocd := p; Break; end;
    if (p = 0) or (N - p > 65558) then Break;
    Dec(p);
  end;
  if eocd = 0 then raise EXpsError.Create('XPS: no ZIP central directory');

  cnt := U16(InBuf, eocd + 10);
  cdOfs := U32(InBuf, eocd + 16);
  if cdOfs >= N then raise EXpsError.Create('XPS: bad central directory offset');

  // walk the central directory, collecting image/thumbnail entries
  p := cdOfs;
  for i := 0 to cnt - 1 do
  begin
    if (p + 46 > N) or (U32(InBuf, p) <> $02014B50) then Break;
    method   := U16(InBuf, p + 10);
    compSize := U32(InBuf, p + 20);
    fnLen    := U16(InBuf, p + 28);
    exLen    := U16(InBuf, p + 30);
    cmLen    := U16(InBuf, p + 32);
    localOfs := U32(InBuf, p + 42);
    SetLength(fname, fnLen);
    for k := 0 to Integer(fnLen) - 1 do fname[k + 1] := Chr(InBuf[p + 46 + NativeUInt(k)]);

    if LowerExtIs(fname, ['.jpg', '.jpeg', '.png', '.tif', '.tiff']) then
    begin
      SetLength(cMethod, Length(cMethod) + 1); cMethod[High(cMethod)] := method;
      SetLength(cComp, Length(cComp) + 1);     cComp[High(cComp)] := compSize;
      SetLength(cLocal, Length(cLocal) + 1);   cLocal[High(cLocal)] := localOfs;
      SetLength(cName, Length(cName) + 1);     cName[High(cName)] := fname;
    end;
    p := p + 46 + fnLen + exLen + cmLen;
  end;

  // prefer a page thumbnail (a real rendered preview), else the largest image
  bestThumbIdx := -1; bestImgIdx := -1; bestThumbSize := 0; bestImgSize := 0;
  for i := 0 to High(cName) do
  begin
    lname := LowerCase(cName[i]);
    if Pos('thumbnail', lname) > 0 then
    begin
      if cComp[i] >= bestThumbSize then begin bestThumbSize := cComp[i]; bestThumbIdx := i; end;
    end
    else if cComp[i] >= bestImgSize then begin bestImgSize := cComp[i]; bestImgIdx := i; end;
  end;

  k := bestThumbIdx;
  if k < 0 then k := bestImgIdx;
  if k < 0 then
    raise EXpsError.Create('XPS: no decodable page image found ' +
      '(vector/text-only page; a full XAML renderer would be required)');

  Blob := ExtractEntry(InBuf, cMethod[k], cComp[k], cLocal[k]);
  if Length(Blob) = 0 then raise EXpsError.Create('XPS: failed to extract page image');

  Result := DecodeImageBlob(Blob, Width, Height);

  // if the chosen image failed but it was a thumbnail, fall back to the largest image
  if (Length(Result) = 0) and (bestThumbIdx >= 0) and (bestImgIdx >= 0) then
  begin
    Blob := ExtractEntry(InBuf, cMethod[bestImgIdx], cComp[bestImgIdx], cLocal[bestImgIdx]);
    if Length(Blob) > 0 then Result := DecodeImageBlob(Blob, Width, Height);
  end;

  if (Length(Result) = 0) or (Width <= 0) or (Height <= 0) then
    raise EXpsError.Create('XPS: page image could not be decoded');
end;

end.
