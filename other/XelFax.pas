unit XelFax;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	GFI fax (.fax) decoder -> RGBA8 (multi-page)                  //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// GFI fax files are TIFF files (CCITT G3/G4 bilevel pages). The TIFF header   //
// is located first (a leading vendor header, if present, is skipped) and the  //
// pages are decoded by XelTiff. Raw Group 3 streams (.g3, no container) are   //
// decoded directly by XelCcitt as a single page.                              //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelTiff, XelCcitt;

type
  EFaxError = class(Exception);

function FaxPageCount(InBuf: TBytes): Integer;
function DecodeFaxPage(InBuf: TBytes; PageIndex: Integer; out Width, Height: Integer): TBytes;
function DecodeFax(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8 (page 0)

implementation

const
  SEARCH_LIMIT = 4096;

// Offset of the TIFF header ("II*\0" or "MM\0*") within the first bytes, or -1.
function TiffOffset(const D: TBytes): Integer;
var
  i, Lim: Integer;
begin
  Result := -1;
  Lim := Length(D) - 4;
  if Lim > SEARCH_LIMIT then Lim := SEARCH_LIMIT;
  for i := 0 to Lim do
    if ((D[i] = Ord('I')) and (D[i + 1] = Ord('I')) and (D[i + 2] = 42) and (D[i + 3] = 0)) or
       ((D[i] = Ord('M')) and (D[i + 1] = Ord('M')) and (D[i + 2] = 0) and (D[i + 3] = 42)) then
      Exit(i);
end;

// Return the bytes starting at the TIFF header.
function TiffPart(const D: TBytes): TBytes;
var
  i: Integer;
begin
  i := TiffOffset(D);
  if i < 0 then raise EFaxError.Create('FAX: no TIFF structure found');
  if i = 0 then Result := D else Result := Copy(D, i, Length(D) - i);
end;

function FaxPageCount(InBuf: TBytes): Integer;
begin
  if (TiffOffset(InBuf) < 0) and LooksLikeRawG3(InBuf) then Exit(1);
  try
    Result := TiffPageCount(TiffPart(InBuf));
  except
    Result := 0;
  end;
end;

function DecodeFaxPage(InBuf: TBytes; PageIndex: Integer; out Width, Height: Integer): TBytes;
begin
  if TiffOffset(InBuf) < 0 then
  begin
    if PageIndex <> 0 then raise EFaxError.Create('FAX: raw G3 stream has a single page');
    Result := DecodeRawG3(InBuf, Width, Height);
    Exit;
  end;
  Result := DecodeTiffPage(TiffPart(InBuf), PageIndex, Width, Height);
  if (Width <= 0) or (Height <= 0) then raise EFaxError.Create('FAX: page could not be decoded');
end;

function DecodeFax(InBuf: TBytes; out Width, Height: Integer): TBytes;
begin
  Result := DecodeFaxPage(InBuf, 0, Width, Height);
end;

end.
