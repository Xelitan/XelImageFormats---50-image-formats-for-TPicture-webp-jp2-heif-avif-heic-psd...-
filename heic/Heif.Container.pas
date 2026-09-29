unit Heif.Container;

// Pure-Pascal ISOBMFF / HEIF container reader.
//
// Parses the box structure of a HEIF/HEIC file and builds an item model:
// items, their types, their properties (from iprp/ipco + ipma), the primary
// item, and the byte extents (from iloc) needed to assemble each item's coded
// data. This is the codec-independent layer shared by decode and encode.
//
// All parsing works in absolute offsets into a single in-memory FBuffer.
//
// Reference: ISO/IEC 14496-12 (ISOBMFF) and ISO/IEC 23008-12 (HEIF).

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Heif.Reader;

type
  EHeifContainer = class(Exception);

  // A single 'ipco' property box, kept as raw payload plus its type so the codec
  // layer can decode the ones it understands (hvcC, ispe, colr, pixi, ...).
  THeifProperty = class
  public
    BoxType: string;
    Data: TBytes;       // property box payload (after the size+type header)
    Essential: Boolean; // from ipma
    function AsReader: TByteReader; // caller frees; borrows Data
  end;

  // An iloc extent: a (offset,length) slice relative to the item's base.
  THeifExtent = record
    Offset: UInt64;
    Length: UInt64;
  end;

  THeifItem = class
  public
    ID: LongWord;
    ItemType: string;            // 'hvc1', 'grid', 'Exif', 'mime', ...
    ContentType: string;         // for 'mime' items
    ConstructionMethod: Integer; // 0=file offset, 1=idat, 2=item
    BaseOffset: UInt64;
    Extents: array of THeifExtent;
    Properties: TObjectList<THeifProperty>; // borrowed refs into container
    constructor Create;
    destructor Destroy; override;
    function FindProperty(const AType: string): THeifProperty;
  end;

  THeifRef = record
    RefType: string;
    FromID: LongWord;
    ToIDs: array of LongWord;
  end;

  THeifContainer = class
  private
    FBuffer: TBytes;
    FItems: TObjectList<THeifItem>;
    FRefs: array of THeifRef;
    FPrimaryItemID: LongWord;
    FMajorBrand: string;
    FIdatStart: NativeInt;   // absolute offset of 'idat' payload, or -1
    FIdatEnd: NativeInt;

    // Property boxes collected in order from ipco; ipma indexes are 1-based.
    FPropBoxes: TObjectList<THeifProperty>;

    // Iterator: reads the box at APos (advanced in-place to the next box).
    // Returns False at end of range. Outputs box type and content range.
    function NextBox(var APos: NativeInt; ALimit: NativeInt; out AType: string;
      out AContentStart, AContentEnd: NativeInt): Boolean;

    procedure ParseTopLevel;
    procedure ParseFtyp(AStart, AEnd: NativeInt);
    procedure ParseMeta(AStart, AEnd: NativeInt);
    procedure ParsePitm(AStart, AEnd: NativeInt);
    procedure ParseIinf(AStart, AEnd: NativeInt);
    procedure ParseInfeList(AStart, AEnd: NativeInt);
    procedure ParseInfe(AStart, AEnd: NativeInt);
    procedure ParseIloc(AStart, AEnd: NativeInt);
    procedure ParseIprp(AStart, AEnd: NativeInt);
    procedure ParseIpco(AStart, AEnd: NativeInt);
    procedure ParseIpma(AStart, AEnd: NativeInt);
    procedure ParseIref(AStart, AEnd: NativeInt);

    function FindItem(AID: LongWord): THeifItem;
  public
    constructor Create;
    destructor Destroy; override;

    procedure LoadFromFile(const AFileName: string);
    procedure LoadFromBytes(const ABytes: TBytes);

    // Assemble the raw coded data of an item from its iloc extents.
    function GetItemData(AID: LongWord): TBytes;

    function PrimaryItem: THeifItem;
    function GetReferences(AFromID: LongWord; const AType: string): TArray<LongWord>;

    // Metadata passthrough. Return empty when absent.
    function GetExifData: TBytes;    // raw TIFF/Exif payload
    function GetIccProfile: TBytes;  // ICC profile from a 'prof'/'rICC' colr box

    property Items: TObjectList<THeifItem> read FItems;
    property PrimaryItemID: LongWord read FPrimaryItemID;
    property MajorBrand: string read FMajorBrand;
    property Buffer: TBytes read FBuffer;
  end;

implementation

// THeifProperty

function THeifProperty.AsReader: TByteReader;
begin
  Result := TByteReader.CreateOwned(Data);
end;

// THeifItem

constructor THeifItem.Create;
begin
  inherited Create;
  Properties := TObjectList<THeifProperty>.Create(False); // borrowed refs
  ConstructionMethod := 0;
end;

destructor THeifItem.Destroy;
begin
  Properties.Free;
  inherited Destroy;
end;

function THeifItem.FindProperty(const AType: string): THeifProperty;
var
  P: THeifProperty;
begin
  for P in Properties do
    if P.BoxType = AType then
      Exit(P);
  Result := nil;
end;

// THeifContainer

constructor THeifContainer.Create;
begin
  inherited Create;
  FItems := TObjectList<THeifItem>.Create(True);
  FPropBoxes := TObjectList<THeifProperty>.Create(True);
  FPrimaryItemID := 0;
  FIdatStart := -1;
  FIdatEnd := 0;
end;

destructor THeifContainer.Destroy;
begin
  FItems.Free;
  FPropBoxes.Free;
  inherited Destroy;
end;

procedure THeifContainer.LoadFromFile(const AFileName: string);
var
  FS: TFileStream;
  Len: Int64;
  Buf: TBytes;
begin
  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    Len := FS.Size;
    SetLength(Buf, Len);
    if Len > 0 then
      FS.ReadBuffer(Buf[0], Len);
  finally
    FS.Free;
  end;
  LoadFromBytes(Buf);
end;

procedure THeifContainer.LoadFromBytes(const ABytes: TBytes);
begin
  FBuffer := ABytes;
  FItems.Clear;
  FPropBoxes.Clear;
  SetLength(FRefs, 0);
  FPrimaryItemID := 0;
  FIdatStart := -1;
  if Length(FBuffer) = 0 then
    raise EHeifContainer.Create('Empty file');
  ParseTopLevel;
end;

function THeifContainer.NextBox(var APos: NativeInt; ALimit: NativeInt;
  out AType: string; out AContentStart, AContentEnd: NativeInt): Boolean;
var
  P: PByte;
  Size32: LongWord;
  Size: UInt64;
  HeaderLen: NativeInt;
  BoxStart: NativeInt;
begin
  if ALimit - APos < 8 then
    Exit(False);
  BoxStart := APos;
  P := @FBuffer[BoxStart];
  Size32 := BE32(P);
  SetLength(AType, 4);
  AType[1] := Chr(P[4]); AType[2] := Chr(P[5]);
  AType[3] := Chr(P[6]); AType[4] := Chr(P[7]);
  HeaderLen := 8;
  if Size32 = 1 then
  begin
    if ALimit - BoxStart < 16 then
      Exit(False);
    Size := (UInt64(BE32(@FBuffer[BoxStart + 8])) shl 32) or
             UInt64(BE32(@FBuffer[BoxStart + 12]));
    HeaderLen := 16;
  end
  else if Size32 = 0 then
    Size := UInt64(ALimit - BoxStart)
  else
    Size := Size32;

  if (Size < UInt64(HeaderLen)) or (UInt64(BoxStart) + Size > UInt64(ALimit)) then
    Size := UInt64(ALimit - BoxStart); // tolerate truncation / to-EOF

  AContentStart := BoxStart + HeaderLen;
  AContentEnd := BoxStart + NativeInt(Size);
  APos := AContentEnd;
  if APos <= BoxStart then
    APos := ALimit; // guard against zero-size loop
  Result := True;
end;

procedure THeifContainer.ParseTopLevel;
var
  Pos, CS, CE: NativeInt;
  BoxType: string;
begin
  Pos := 0;
  while NextBox(Pos, Length(FBuffer), BoxType, CS, CE) do
  begin
    if BoxType = 'ftyp' then
      ParseFtyp(CS, CE)
    else if BoxType = 'meta' then
      ParseMeta(CS, CE);
  end;
end;

procedure THeifContainer.ParseFtyp(AStart, AEnd: NativeInt);
begin
  if AEnd - AStart >= 4 then
  begin
    SetLength(FMajorBrand, 4);
    FMajorBrand[1] := Chr(FBuffer[AStart]);
    FMajorBrand[2] := Chr(FBuffer[AStart + 1]);
    FMajorBrand[3] := Chr(FBuffer[AStart + 2]);
    FMajorBrand[4] := Chr(FBuffer[AStart + 3]);
  end;
end;

procedure THeifContainer.ParseMeta(AStart, AEnd: NativeInt);
var
  Pos, CS, CE: NativeInt;
  BoxType: string;
begin
  // meta is a FullBox: skip 4 bytes of version+flags, then child boxes.
  Pos := AStart + 4;
  while NextBox(Pos, AEnd, BoxType, CS, CE) do
  begin
    if BoxType = 'pitm' then
      ParsePitm(CS, CE)
    else if BoxType = 'iinf' then
      ParseIinf(CS, CE)
    else if BoxType = 'iloc' then
      ParseIloc(CS, CE)
    else if BoxType = 'iprp' then
      ParseIprp(CS, CE)
    else if BoxType = 'iref' then
      ParseIref(CS, CE)
    else if BoxType = 'idat' then
    begin
      FIdatStart := CS;
      FIdatEnd := CE;
    end;
  end;
end;

procedure THeifContainer.ParsePitm(AStart, AEnd: NativeInt);
var
  R: TByteReader;
  Version: Byte;
begin
  R := TByteReader.Create(@FBuffer[AStart], AEnd - AStart);
  try
    Version := R.ReadU8;
    R.Skip(3); // flags
    if Version = 0 then
      FPrimaryItemID := R.ReadU16
    else
      FPrimaryItemID := R.ReadU32;
  finally
    R.Free;
  end;
end;

procedure THeifContainer.ParseIinf(AStart, AEnd: NativeInt);
var
  Version: Byte;
  ChildStart: NativeInt;
begin
  Version := FBuffer[AStart];
  // FullBox header (4) + entry_count (2 if v0, else 4), then child infe boxes.
  if Version = 0 then
    ChildStart := AStart + 4 + 2
  else
    ChildStart := AStart + 4 + 4;
  ParseInfeList(ChildStart, AEnd);
end;

procedure THeifContainer.ParseInfeList(AStart, AEnd: NativeInt);
var
  Pos, CS, CE: NativeInt;
  BoxType: string;
begin
  Pos := AStart;
  while NextBox(Pos, AEnd, BoxType, CS, CE) do
    if BoxType = 'infe' then
      ParseInfe(CS, CE);
end;

procedure THeifContainer.ParseInfe(AStart, AEnd: NativeInt);
var
  R: TByteReader;
  Version: Byte;
  Item: THeifItem;
  ID: LongWord;
begin
  R := TByteReader.Create(@FBuffer[AStart], AEnd - AStart);
  try
    Version := R.ReadU8;
    R.Skip(3);
    if Version >= 2 then
    begin
      if Version = 2 then
        ID := R.ReadU16
      else
        ID := R.ReadU32;
      R.ReadU16; // protection_index
      // iloc may have created a stub item already; reuse it so extents and
      // properties stay attached to a single THeifItem per ID.
      Item := FindItem(ID);
      if Item = nil then
      begin
        Item := THeifItem.Create;
        Item.ID := ID;
        FItems.Add(Item);
      end;
      Item.ItemType := R.ReadFourCC;
      // item_name (cstring)
      R.ReadCString;
      if Item.ItemType = 'mime' then
        Item.ContentType := R.ReadCString;
    end;
    // Version 0/1 (offset/length based) not used by HEIC image items; skipped.
  finally
    R.Free;
  end;
end;

procedure THeifContainer.ParseIloc(AStart, AEnd: NativeInt);
var
  R: TByteReader;
  Version: Byte;
  Flags: LongWord;
  B: Byte;
  OffsetSize, LengthSize, BaseOffsetSize, IndexSize: Integer;
  ItemCount, I, J, ExtentCount: Integer;
  ID: LongWord;
  ConstrMethod: Integer;
  Item: THeifItem;
begin
  R := TByteReader.Create(@FBuffer[AStart], AEnd - AStart);
  try
    Version := R.ReadU8;
    Flags := R.ReadU24;
    B := R.ReadU8;
    OffsetSize := B shr 4;
    LengthSize := B and $0F;
    B := R.ReadU8;
    BaseOffsetSize := B shr 4;
    IndexSize := B and $0F; // versions 1&2 only
    if Version < 2 then
      ItemCount := R.ReadU16
    else
      ItemCount := R.ReadU32;

    for I := 0 to ItemCount - 1 do
    begin
      if Version < 2 then
        ID := R.ReadU16
      else
        ID := R.ReadU32;

      ConstrMethod := 0;
      if Version >= 1 then
      begin
        ConstrMethod := R.ReadU16 and $0F;
      end;

      R.ReadU16; // data_reference_index
      Item := FindItem(ID);
      if Item = nil then
      begin
        // iloc may precede iinf; create a stub.
        Item := THeifItem.Create;
        Item.ID := ID;
        FItems.Add(Item);
      end;
      Item.ConstructionMethod := ConstrMethod;
      if BaseOffsetSize > 0 then
        Item.BaseOffset := R.ReadUInt(BaseOffsetSize)
      else
        Item.BaseOffset := 0;

      ExtentCount := R.ReadU16;
      SetLength(Item.Extents, ExtentCount);
      for J := 0 to ExtentCount - 1 do
      begin
        if (Version >= 1) and (IndexSize > 0) then
          R.ReadUInt(IndexSize); // extent_index, ignored
        Item.Extents[J].Offset := R.ReadUInt(OffsetSize);
        Item.Extents[J].Length := R.ReadUInt(LengthSize);
      end;
    end;
  finally
    R.Free;
  end;
end;

procedure THeifContainer.ParseIprp(AStart, AEnd: NativeInt);
var
  Pos, CS, CE: NativeInt;
  BoxType: string;
begin
  // ipco must be parsed before ipma (ipma references ipco indices).
  Pos := AStart;
  while NextBox(Pos, AEnd, BoxType, CS, CE) do
    if BoxType = 'ipco' then
      ParseIpco(CS, CE);
  Pos := AStart;
  while NextBox(Pos, AEnd, BoxType, CS, CE) do
    if BoxType = 'ipma' then
      ParseIpma(CS, CE);
end;

procedure THeifContainer.ParseIpco(AStart, AEnd: NativeInt);
var
  Pos, CS, CE: NativeInt;
  BoxType: string;
  Prop: THeifProperty;
begin
  // Each child is a property box; store payload + type in ipco order.
  Pos := AStart;
  while NextBox(Pos, AEnd, BoxType, CS, CE) do
  begin
    Prop := THeifProperty.Create;
    Prop.BoxType := BoxType;
    SetLength(Prop.Data, CE - CS);
    if CE > CS then
      Move(FBuffer[CS], Prop.Data[0], CE - CS);
    FPropBoxes.Add(Prop);
  end;
end;

procedure THeifContainer.ParseIpma(AStart, AEnd: NativeInt);
var
  R: TByteReader;
  Version: Byte;
  Flags: LongWord;
  EntryCount, E: Integer;
  ItemID: LongWord;
  AssocCount, A: Integer;
  B0: Byte;
  Essential: Boolean;
  PropIndex: Integer;
  Item: THeifItem;
  Prop: THeifProperty;
begin
  R := TByteReader.Create(@FBuffer[AStart], AEnd - AStart);
  try
    Version := R.ReadU8;
    Flags := R.ReadU24;
    EntryCount := R.ReadU32;
    for E := 0 to EntryCount - 1 do
    begin
      if Version < 1 then
        ItemID := R.ReadU16
      else
        ItemID := R.ReadU32;
      AssocCount := R.ReadU8;
      Item := FindItem(ItemID);
      for A := 0 to AssocCount - 1 do
      begin
        if (Flags and 1) = 1 then
        begin
          // 15-bit property index
          B0 := R.ReadU8;
          Essential := (B0 and $80) <> 0;
          PropIndex := ((B0 and $7F) shl 8) or R.ReadU8;
        end
        else
        begin
          B0 := R.ReadU8;
          Essential := (B0 and $80) <> 0;
          PropIndex := B0 and $7F;
        end;
        if (Item <> nil) and (PropIndex >= 1) and (PropIndex <= FPropBoxes.Count) then
        begin
          Prop := FPropBoxes[PropIndex - 1];
          Prop.Essential := Prop.Essential or Essential;
          Item.Properties.Add(Prop);
        end;
      end;
    end;
  finally
    R.Free;
  end;
end;

procedure THeifContainer.ParseIref(AStart, AEnd: NativeInt);
var
  Version: Byte;
  Pos, CS, CE: NativeInt;
  BoxType: string;
  R: TByteReader;
  Ref: THeifRef;
  Cnt, K, N: Integer;
begin
  Version := FBuffer[AStart];
  // FullBox header (4 bytes) then a series of single-item reference boxes.
  Pos := AStart + 4;
  while NextBox(Pos, AEnd, BoxType, CS, CE) do
  begin
    R := TByteReader.Create(@FBuffer[CS], CE - CS);
    try
      Ref.RefType := BoxType;
      if Version = 0 then
      begin
        Ref.FromID := R.ReadU16;
        Cnt := R.ReadU16;
        SetLength(Ref.ToIDs, Cnt);
        for K := 0 to Cnt - 1 do
          Ref.ToIDs[K] := R.ReadU16;
      end
      else
      begin
        Ref.FromID := R.ReadU32;
        Cnt := R.ReadU16;
        SetLength(Ref.ToIDs, Cnt);
        for K := 0 to Cnt - 1 do
          Ref.ToIDs[K] := R.ReadU32;
      end;
      N := Length(FRefs);
      SetLength(FRefs, N + 1);
      FRefs[N] := Ref;
    finally
      R.Free;
    end;
  end;
end;

function THeifContainer.FindItem(AID: LongWord): THeifItem;
var
  It: THeifItem;
begin
  for It in FItems do
    if It.ID = AID then
      Exit(It);
  Result := nil;
end;

function THeifContainer.PrimaryItem: THeifItem;
begin
  Result := FindItem(FPrimaryItemID);
end;

function THeifContainer.GetReferences(AFromID: LongWord; const AType: string): TArray<LongWord>;
var
  I: Integer;
begin
  for I := 0 to High(FRefs) do
    if (FRefs[I].FromID = AFromID) and (FRefs[I].RefType = AType) then
      Exit(Copy(FRefs[I].ToIDs));
  Result := nil;
end;

function THeifContainer.GetExifData: TBytes;
var
  It, ExifItem: THeifItem;
  Refs: TArray<LongWord>;
  Raw: TBytes;
  Ofs: NativeInt;
  TiffStart: NativeInt;
begin
  Result := nil;
  // Prefer the Exif item the primary describes via 'cdsc'; else the first one.
  ExifItem := nil;
  Refs := GetReferences(FPrimaryItemID, 'cdsc');
  for It in FItems do
    if It.ItemType = 'Exif' then
    begin
      if ExifItem = nil then ExifItem := It;
      if (Length(Refs) > 0) and (It.ID = Refs[0]) then
      begin
        ExifItem := It;
        Break;
      end;
    end;
  if ExifItem = nil then Exit;

  Raw := GetItemData(ExifItem.ID);
  // ExifDataBlock: u32 exif_tiff_header_offset, then payload; TIFF starts at 4+offset.
  if Length(Raw) < 4 then Exit;
  Ofs := (NativeInt(Raw[0]) shl 24) or (NativeInt(Raw[1]) shl 16) or
         (NativeInt(Raw[2]) shl 8) or NativeInt(Raw[3]);
  TiffStart := 4 + Ofs;
  if (TiffStart < 0) or (TiffStart >= Length(Raw)) then Exit;
  SetLength(Result, Length(Raw) - TiffStart);
  Move(Raw[TiffStart], Result[0], Length(Result));
end;

function THeifContainer.GetIccProfile: TBytes;
var
  Item: THeifItem;
  Prop: THeifProperty;
  CType: string;
begin
  Result := nil;
  Item := PrimaryItem;
  if Item = nil then Exit;
  Prop := Item.FindProperty('colr');
  if (Prop = nil) or (Length(Prop.Data) < 4) then Exit;
  CType := Chr(Prop.Data[0]) + Chr(Prop.Data[1]) + Chr(Prop.Data[2]) + Chr(Prop.Data[3]);
  if (CType = 'prof') or (CType = 'rICC') then
  begin
    SetLength(Result, Length(Prop.Data) - 4);
    if Length(Result) > 0 then
      Move(Prop.Data[4], Result[0], Length(Result));
  end;
end;

function THeifContainer.GetItemData(AID: LongWord): TBytes;
var
  Item: THeifItem;
  I: Integer;
  Total: NativeInt;
  Dest: NativeInt;
  Src: NativeInt;
  Ext: THeifExtent;
begin
  Item := FindItem(AID);
  if Item = nil then
    raise EHeifContainer.CreateFmt('Item %d not found', [AID]);

  Total := 0;
  for I := 0 to High(Item.Extents) do
    Inc(Total, NativeInt(Item.Extents[I].Length));
  SetLength(Result, Total);

  Dest := 0;
  for I := 0 to High(Item.Extents) do
  begin
    Ext := Item.Extents[I];
    case Item.ConstructionMethod of
      0: // absolute file offset
        Src := NativeInt(Item.BaseOffset + Ext.Offset);
      1: // relative to idat payload
        begin
          if FIdatStart < 0 then
            raise EHeifContainer.Create('idat construction but no idat box');
          Src := FIdatStart + NativeInt(Item.BaseOffset + Ext.Offset);
        end;
    else
      raise EHeifContainer.CreateFmt('Unsupported construction method %d',
        [Item.ConstructionMethod]);
    end;
    if (Src < 0) or (Src + NativeInt(Ext.Length) > Length(FBuffer)) then
      raise EHeifContainer.CreateFmt('Extent out of range (src %d len %d)',
        [Src, Ext.Length]);
    if Ext.Length > 0 then
      Move(FBuffer[Src], Result[Dest], NativeInt(Ext.Length));
    Inc(Dest, NativeInt(Ext.Length));
  end;
end;

end.
