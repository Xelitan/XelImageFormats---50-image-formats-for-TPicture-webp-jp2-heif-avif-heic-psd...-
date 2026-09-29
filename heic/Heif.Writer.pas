unit Heif.Writer;

// Minimal HEIF/ISOBMFF container writer for a single still image (hvc1).
//
// Produces a complete .heic byte buffer given an hvcC configuration record and
// the coded item data (length-prefixed HEVC NAL units). The layout mirrors what
// Heif.Container reads back.
//
// Reference: ISO/IEC 14496-12 (ISOBMFF) and ISO/IEC 23008-12 (HEIF).

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Heif.Reader;

type
  // A growable big-endian byte buffer with ISOBMFF box helpers.
  TBoxWriter = class
  private
    FBuf: TBytes;
    FLen: Integer;
    procedure Ensure(ACount: Integer);
  public
    constructor Create;
    procedure U8(V: Byte);
    procedure U16(V: Word);
    procedure U24(V: LongWord);
    procedure U32(V: LongWord);
    procedure FourCC(const S: string);
    procedure Bytes(const B: TBytes);
    // Begins a box; returns the byte offset of its size field (to patch later).
    function BeginBox(const AType: string): Integer;
    function BeginFullBox(const AType: string; AVersion: Byte; AFlags: LongWord): Integer;
    procedure EndBox(ASizeOffset: Integer);
    // Patches a previously written u32 at AOffset.
    procedure PatchU32(AOffset: Integer; V: LongWord);
    function Length_: Integer;
    function ToBytes: TBytes;
    property Position: Integer read FLen;
  end;

type
  TNclxColor = record
    Primaries: Word;
    Transfer: Word;
    Matrix: Word;
    FullRange: Boolean;
  end;

// Builds a complete single-image HEIC file.
//   AHvcC        - hvcC box payload (from Heif.H265.Emit.BuildHvcC)
//   AItemData    - coded item data: length-prefixed NAL units (goes in mdat)
//   ADisplayW/H  - image display dimensions (for ispe)
//   AColor       - nclx colour signalling (written as a 'colr' property)
//   AExif        - optional raw TIFF/Exif payload (adds an 'Exif' item + cdsc)
//   AIcc         - optional ICC profile (adds a 'colr'/'prof' property)
function BuildHeifFile(const AHvcC, AItemData: TBytes;
  ADisplayW, ADisplayH: Integer; const AColor: TNclxColor;
  const AExif, AIcc: TBytes): TBytes; overload;
function BuildHeifFile(const AHvcC, AItemData: TBytes;
  ADisplayW, ADisplayH: Integer; const AColor: TNclxColor): TBytes; overload;
// As above, with a clean aperture: when ACropW x ACropH is smaller than the
// coded ADisplayW x ADisplayH (ispe), a 'clap' property crops the image to
// its top-left ACropW x ACropH. Used for odd sizes with 4:2:0 / 4:2:2 chroma,
// whose coded size must be even.
function BuildHeifFileCropped(const AHvcC, AItemData: TBytes;
  ADisplayW, ADisplayH, ACropW, ACropH: Integer; const AColor: TNclxColor;
  const AExif, AIcc: TBytes): TBytes;

implementation

// TBoxWriter

constructor TBoxWriter.Create;
begin
  inherited Create;
  FLen := 0;
end;

procedure TBoxWriter.Ensure(ACount: Integer);
begin
  if FLen + ACount > System.Length(FBuf) then
    SetLength(FBuf, (FLen + ACount) * 2 + 64);
end;

procedure TBoxWriter.U8(V: Byte);
begin
  Ensure(1);
  FBuf[FLen] := V; Inc(FLen);
end;

procedure TBoxWriter.U16(V: Word);
begin
  U8((V shr 8) and $FF); U8(V and $FF);
end;

procedure TBoxWriter.U24(V: LongWord);
begin
  U8((V shr 16) and $FF); U8((V shr 8) and $FF); U8(V and $FF);
end;

procedure TBoxWriter.U32(V: LongWord);
begin
  U8((V shr 24) and $FF); U8((V shr 16) and $FF);
  U8((V shr 8) and $FF); U8(V and $FF);
end;

procedure TBoxWriter.FourCC(const S: string);
var
  I: Integer;
begin
  for I := 1 to 4 do
    U8(Byte(S[I]));
end;

procedure TBoxWriter.Bytes(const B: TBytes);
begin
  if System.Length(B) > 0 then
  begin
    Ensure(System.Length(B));
    Move(B[0], FBuf[FLen], System.Length(B));
    Inc(FLen, System.Length(B));
  end;
end;

function TBoxWriter.BeginBox(const AType: string): Integer;
begin
  Result := FLen;
  U32(0);          // size placeholder
  FourCC(AType);
end;

function TBoxWriter.BeginFullBox(const AType: string; AVersion: Byte;
  AFlags: LongWord): Integer;
begin
  Result := BeginBox(AType);
  U8(AVersion);
  U24(AFlags);
end;

procedure TBoxWriter.EndBox(ASizeOffset: Integer);
begin
  PatchU32(ASizeOffset, LongWord(FLen - ASizeOffset));
end;

procedure TBoxWriter.PatchU32(AOffset: Integer; V: LongWord);
begin
  FBuf[AOffset] := (V shr 24) and $FF;
  FBuf[AOffset+1] := (V shr 16) and $FF;
  FBuf[AOffset+2] := (V shr 8) and $FF;
  FBuf[AOffset+3] := V and $FF;
end;

function TBoxWriter.Length_: Integer;
begin
  Result := FLen;
end;

function TBoxWriter.ToBytes: TBytes;
begin
  SetLength(Result, FLen);
  if FLen > 0 then
    Move(FBuf[0], Result[0], FLen);
end;

function BuildHeifFileCropped(const AHvcC, AItemData: TBytes;
  ADisplayW, ADisplayH, ACropW, ACropH: Integer; const AColor: TNclxColor;
  const AExif, AIcc: TBytes): TBytes;
const
  IMG_ID = 1;
  EXIF_ID = 2;
var
  W: TBoxWriter;
  b, meta, iinf, infe, iprp, ipco, ipma, iloc: Integer;
  imgOffPos, exifOffPos: Integer;
  imgAbsOffset, exifAbsOffset: Integer;
  hasExif, hasIcc: Boolean;
  nProps, assocCount: Integer;
  itemCount: Integer;
  ExifItemData: TBytes;
  I: Integer;
  hasClap: Boolean;
begin
  hasExif := Length(AExif) > 0;
  hasIcc := Length(AIcc) > 0;
  if (ACropW <= 0) or (ACropW > ADisplayW) then ACropW := ADisplayW;
  if (ACropH <= 0) or (ACropH > ADisplayH) then ACropH := ADisplayH;
  hasClap := (ACropW < ADisplayW) or (ACropH < ADisplayH);
  nProps := 3;                    // hvcC, ispe, colr(nclx)
  if hasIcc then Inc(nProps);     // + colr(prof)
  if hasClap then Inc(nProps);    // + clap (transformative, listed last)
  itemCount := 1;
  if hasExif then Inc(itemCount);

  // Exif item payload: u32 exif_tiff_header_offset (0) + the TIFF data.
  if hasExif then
  begin
    SetLength(ExifItemData, 4 + Length(AExif));
    ExifItemData[0] := 0; ExifItemData[1] := 0; ExifItemData[2] := 0; ExifItemData[3] := 0;
    Move(AExif[0], ExifItemData[4], Length(AExif));
  end;

  W := TBoxWriter.Create;
  try
    // ---- ftyp ----
    b := W.BeginBox('ftyp');
    W.FourCC('heic'); W.U32(0); W.FourCC('mif1'); W.FourCC('heic');
    W.EndBox(b);

    // ---- meta ----
    meta := W.BeginFullBox('meta', 0, 0);

    b := W.BeginFullBox('hdlr', 0, 0);
    W.U32(0); W.FourCC('pict'); W.U32(0); W.U32(0); W.U32(0); W.U8(0);
    W.EndBox(b);

    b := W.BeginFullBox('pitm', 0, 0);
    W.U16(IMG_ID);
    W.EndBox(b);

    // iinf -> infe entries
    iinf := W.BeginFullBox('iinf', 0, 0);
    W.U16(itemCount);
    infe := W.BeginFullBox('infe', 2, 0);  // flags 0: a visible image item
    W.U16(IMG_ID); W.U16(0); W.FourCC('hvc1'); W.U8(0);
    W.EndBox(infe);
    if hasExif then
    begin
      infe := W.BeginFullBox('infe', 2, 1); // flags 1: hidden (metadata item)
      W.U16(EXIF_ID); W.U16(0); W.FourCC('Exif'); W.U8(0);
      W.EndBox(infe);
    end;
    W.EndBox(iinf);

    // iref (v0): a 'cdsc' single-item reference from the Exif item to the image.
    if hasExif then
    begin
      b := W.BeginFullBox('iref', 0, 0);
      iinf := W.BeginBox('cdsc'); // reuse iinf var as scratch
      W.U16(EXIF_ID);   // from_item_ID (the metadata item)
      W.U16(1);         // reference_count
      W.U16(IMG_ID);    // to_item_ID (the image it describes)
      W.EndBox(iinf);
      W.EndBox(b);
    end;

    // iprp -> ipco + ipma
    iprp := W.BeginBox('iprp');
    ipco := W.BeginBox('ipco');
    b := W.BeginBox('hvcC'); W.Bytes(AHvcC); W.EndBox(b);            // 1
    b := W.BeginFullBox('ispe', 0, 0);                               // 2
    W.U32(LongWord(ADisplayW)); W.U32(LongWord(ADisplayH));
    W.EndBox(b);
    b := W.BeginBox('colr');                                         // 3 nclx
    W.FourCC('nclx');
    W.U16(AColor.Primaries); W.U16(AColor.Transfer); W.U16(AColor.Matrix);
    if AColor.FullRange then W.U8($80) else W.U8($00);
    W.EndBox(b);
    if hasIcc then
    begin
      b := W.BeginBox('colr');                                       // 4 prof
      W.FourCC('prof');
      W.Bytes(AIcc);
      W.EndBox(b);
    end;
    if hasClap then
    begin
      // Clean aperture, ISO/IEC 14496-12: the aperture is centred on the
      // image and shifted by (horizOff, vertOff); a top-left crop of a
      // W x H image to CW x CH has offset ((CW - W) / 2, (CH - H) / 2).
      b := W.BeginBox('clap');
      W.U32(LongWord(ACropW)); W.U32(1);                       // cleanApertureWidth
      W.U32(LongWord(ACropH)); W.U32(1);                       // cleanApertureHeight
      W.U32(LongWord(ACropW - ADisplayW)); W.U32(2);           // horizOff (signed)
      W.U32(LongWord(ACropH - ADisplayH)); W.U32(2);           // vertOff (signed)
      W.EndBox(b);
    end;
    W.EndBox(ipco);

    ipma := W.BeginFullBox('ipma', 0, 0);
    W.U32(1);
    W.U16(IMG_ID);
    assocCount := nProps;
    W.U8(assocCount);
    W.U8($81);                    // hvcC essential, index 1
    for I := 2 to nProps do
      if hasClap and (I = nProps) then
        W.U8($80 or Byte(I))      // clap: transformative, essential
      else
        W.U8(Byte(I));            // ispe, colr(s) non-essential
    W.EndBox(ipma);
    W.EndBox(iprp);

    // iloc v1: one or two items.
    iloc := W.BeginFullBox('iloc', 1, 0);
    W.U8((4 shl 4) or 4);   // offset_size=4, length_size=4
    W.U8((0 shl 4) or 0);   // base_offset_size=0, index_size=0
    W.U16(itemCount);
    // image item
    W.U16(IMG_ID); W.U16(0); W.U16(0); W.U16(1);
    imgOffPos := W.Position; W.U32(0); W.U32(LongWord(System.Length(AItemData)));
    // exif item
    if hasExif then
    begin
      W.U16(EXIF_ID); W.U16(0); W.U16(0); W.U16(1);
      exifOffPos := W.Position; W.U32(0); W.U32(LongWord(System.Length(ExifItemData)));
    end
    else
      exifOffPos := 0;
    W.EndBox(iloc);

    W.EndBox(meta);

    // ---- mdat ----
    b := W.BeginBox('mdat');
    imgAbsOffset := W.Position;
    W.Bytes(AItemData);
    if hasExif then
    begin
      exifAbsOffset := W.Position;
      W.Bytes(ExifItemData);
    end
    else
      exifAbsOffset := 0;
    W.EndBox(b);

    W.PatchU32(imgOffPos, LongWord(imgAbsOffset));
    if hasExif then
      W.PatchU32(exifOffPos, LongWord(exifAbsOffset));

    Result := W.ToBytes;
  finally
    W.Free;
  end;
end;

function BuildHeifFile(const AHvcC, AItemData: TBytes;
  ADisplayW, ADisplayH: Integer; const AColor: TNclxColor;
  const AExif, AIcc: TBytes): TBytes;
begin
  Result := BuildHeifFileCropped(AHvcC, AItemData, ADisplayW, ADisplayH,
    ADisplayW, ADisplayH, AColor, AExif, AIcc);
end;

function BuildHeifFile(const AHvcC, AItemData: TBytes;
  ADisplayW, ADisplayH: Integer; const AColor: TNclxColor): TBytes;
begin
  Result := BuildHeifFile(AHvcC, AItemData, ADisplayW, ADisplayH, AColor, nil, nil);
end;

end.
