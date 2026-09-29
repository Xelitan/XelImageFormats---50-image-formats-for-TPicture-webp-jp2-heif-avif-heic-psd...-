//JBIG2 decoder in Pascal
//Author: www.xelitan.com
//License: Apache 2.0
type
  TJBSegmentHeader = class;
  TJBPage = class;
  TJBDocument = class;
  TJBProfiles = class;
  TJBRefinementRegion = class;
  TJBPatternDictionary = class;
  TJBSymbolDictionary = class;
  TJBTextRegion = class;
  TJBHalftoneRegion = class;

  TJBProfiles = class(TJBSegmentData)
  public
    procedure Init(header: TJBObject; sis: TJBReader); override;
  end;

  TJBSegmentHeader = class(TJBObject)
  public
    document: TJBDocument;
    subInputStream: TJBReader;
    segmentNr: Integer;
    segmentType: Integer;
    pageAssociation: Integer;
    pageAssociationFieldSize: Integer;
    rtSegments: array of TJBSegmentHeader;
    segmentDataLength: Int64;
    segmentDataStartOffset: Int64;
    cachedData: TJBSegmentData;
    constructor CreateAndParse(adoc: TJBDocument; sis: TJBReader; offset: Int64; organisationType: Integer);
    procedure Parse(adoc: TJBDocument; sis: TJBReader; offset: Int64; organisationType: Integer);
    function GetDataInputStream: TJBReader;
    function GetSegmentData: TJBSegmentData;
  end;

  TSegHeaderArray = array of TJBSegmentHeader;

  TJBPage = class(TJBObject)
  public
    segments: TSegHeaderArray;
    segCount: Integer;
    pageNumber: Integer;
    pageBitmap: TJBBitmap;
    finalHeight: Integer;
    finalWidth: Integer;
    document: TJBDocument;
    constructor CreateWith(adoc: TJBDocument; apage: Integer);
    procedure Add(segment: TJBSegmentHeader);
    procedure SortSegments;
    function GetSegment(number: Integer): TJBSegmentHeader;
    function GetPageInformationSegment: TJBSegmentHeader;
    function GetBitmap: TJBBitmap;
    procedure ComposePageBitmap;
    procedure CreatePage(pi: TJBPageInfo);
    procedure CreateNormalPage(pi: TJBPageInfo);
    procedure CreateStripedPage(pi: TJBPageInfo);
    function FitsPage(pi: TJBPageInfo; regionBitmap: TJBBitmap): Boolean;
    function CountRegions: Integer;
    function GetCombinationOperator(pi: TJBPageInfo; newOp: Integer): Integer;
  end;

  TJBDocument = class(TJBObject)
  public
    mainReader: TJBReader;
    globalsReader: TJBReader;
    pages: array of TJBPage;
    pageCount: Integer;
    globalKeys: TIntArray;
    globalVals: TSegHeaderArray;
    globalCount: Integer;
    gbUseExtTemplate: Boolean;
    constructor Create(const data, globals: TBytes);
    function GetGlobalSegment(segmentNr: Integer): TJBSegmentHeader;
    procedure AddGlobalSegment(segmentNr: Integer; seg: TJBSegmentHeader);
    function GetPage(pageNumber: Integer): TJBPage;
    function GetOrCreatePage(pageNumber: Integer): TJBPage;
    procedure MapStream(reader: TJBReader; isGlobals: Boolean);
    function ReachedEndOfStream(reader: TJBReader; offset: Int64): Boolean;
    function IsFileHeaderPresent(reader: TJBReader): Boolean;
    function ParseFileHeader(reader: TJBReader): Integer; // returns header length
  end;

  TJBRefinementRegion = class(TJBRegion)
  public
    subInputStream: TJBReader;
    segmentHeader: TJBSegmentHeader;
    regionInfo: TJBRegionInfo;
    isTPGROn: Boolean;
    templateID: Integer;
    grAtX, grAtY: TIntArray;
    referenceBitmap: TJBBitmap;
    referenceDX, referenceDY: Integer;
    arithDecoder: TJBArith;
    cx: TJBCx;
    pageBitmap: TJBBitmap;
    procedure ParseHeader;
    procedure ReadAtPixels;
    function GetRegionBitmap: TJBBitmap; override;
    function GetRegionInfo: TJBRegionInfo; override;
    procedure SetPageBitmap(apage: TJBBitmap);
    function GetGrReference: TJBBitmap;
    procedure Init(header: TJBObject; sis: TJBReader); override;
  end;

  TJBPatternDictionary = class(TJBDictionary)
  public
    subInputStream: TJBReader;
    dataOffset: Int64;
    dataLength: Int64;
    gbAtX, gbAtY: TIntArray;
    isMMREncoded: Boolean;
    hdTemplate: Integer;
    hdpWidth: Integer;
    hdpHeight: Integer;
    patterns: TBitmapList;
    grayMax: Integer;
    procedure ParseHeader;
    procedure ComputeSegmentDataStructure;
    procedure SetGbAtPixels;
    function GetDictionary: TBitmapList; override;
    procedure Init(header: TJBObject; sis: TJBReader); override;
  end;

  TJBSymbolDictionary = class(TJBDictionary)
  public
    subInputStream: TJBReader;
    sdrTemplate: Integer;
    sdTemplate: Integer;
    isCodingContextRetained: Boolean;
    isCodingContextUsed: Boolean;
    sdHuffAggInstanceSelection: Integer;
    sdHuffBMSizeSelection: Integer;
    sdHuffDecodeWidthSelection: Integer;
    sdHuffDecodeHeightSelection: Integer;
    useRefinementAggregation: Boolean;
    isHuffmanEncoded: Boolean;
    sdATX, sdATY: TIntArray;
    sdrATX, sdrATY: TIntArray;
    amountOfExportSymbolss: Integer;
    amountOfNewSymbols: Integer;
    segmentHeader: TJBSegmentHeader;
    amountOfImportedSymbols: Integer;
    importSymbols: TBitmapList;
    amountOfDecodedSymbols: Integer;
    newSymbols: array of TJBBitmap;
    dhTable, dwTable, bmSizeTable, aggInstTable: TJBHuffmanTable;
    exportSymbols: TBitmapList;
    sbSymbols: TBitmapList;
    arithmeticDecoder: TJBArith;
    iDecoder: TJBIntDecoder;
    textRegion: TJBTextRegion;
    genericRegion: TJBGenericRegion;
    cx: TJBCx;
    cxIADH, cxIADW, cxIAAI, cxIAEX, cxIARDX, cxIARDY, cxIADT: TJBCx;
    cxIAID: TJBCx;
    sbSymCodeLen: Integer;
    lastSymbolDictionary: TJBSymbolDictionary;

    procedure ParseHeader;
    procedure ReadRegionFlags;
    procedure SetAtPixels;
    procedure SetRefinementAtPixels;
    procedure ReadAtPixels(amount: Integer);
    procedure ReadRefinementAtPixels(amount: Integer);
    procedure SetInSyms;
    procedure CheckInput;
    function GetDictionary: TBitmapList; override;
    procedure ResetIntegerCoderStatistics;
    procedure DecodeHeightClassBitmap(collective: TJBBitmap; firstSym, hcHeight: Integer; widths: TIntArray);
    procedure DecodeAggregate(symbolWidth, hcHeight: Integer);
    function HuffDecodeRefAggNInst: Int64;
    procedure DecodeThroughTextRegion(symbolWidth, hcHeight: Integer; nInstances: Int64);
    procedure DecodeRefinedSymbol(symbolWidth, hcHeight: Integer);
    procedure DecodeNewSymbols(symWidth, hcHeight: Integer; ibo: TJBBitmap; rdx, rdy: Integer);
    procedure DecodeDirectlyThroughGenericRegion(symWidth, hcHeight: Integer);
    procedure AddSymbol(region: TJBRegion);
    function DecodeDifferenceWidth: Int64;
    function DecodeHeightClassDeltaHeight: Int64;
    function DecodeHeightClassCollectiveBitmap(bmSize: Int64; hcHeight, totalWidth: Integer): TJBBitmap;
    procedure SetExportedSymbols(toExportFlags: TIntArray);
    function GetToExportFlags: TIntArray;
    function HuffDecodeBmSize: Int64;
    function GetSbSymCodeLen: Integer;
    procedure SetSymbolsArray;
    procedure RetrieveImportSymbols;
    function GetUserTable(tablePosition: Integer): TJBHuffmanTable;
    procedure Init(header: TJBObject; sis: TJBReader); override;
  end;

  TJBTextRegion = class(TJBRegion)
  public
    subInputStream: TJBReader;
    regionInfo: TJBRegionInfo;
    sbrTemplate: Integer;
    sbdsOffset: Integer;
    defaultPixel: Integer;
    combinationOperator: Integer;
    isTransposed: Integer;
    referenceCorner: Integer;
    logSBStrips: Integer;
    useRefinement: Boolean;
    isHuffmanEncoded: Boolean;
    sbHuffRSize, sbHuffRDY, sbHuffRDX, sbHuffRDHeight, sbHuffRDWidth: Integer;
    sbHuffDT, sbHuffDS, sbHuffFS: Integer;
    sbrATX, sbrATY: TIntArray;
    amountOfSymbolInstances: Int64;
    currentS: Int64;
    sbStrips: Integer;
    amountOfSymbols: Integer;
    regionBitmap: TJBBitmap;
    symbols: TBitmapList;
    arithmeticDecoder: TJBArith;
    integerDecoder: TJBIntDecoder;
    cxIADT, cxIAFS, cxIADS, cxIAIT, cxIARI, cxIARDW, cxIARDH, cxIAID, cxIARDX, cxIARDY, cx: TJBCx;
    symbolCodeLength: Integer;
    symbolCodeTable: TJBHuffmanTable;
    segmentHeader: TJBSegmentHeader;
    fsTable, dsTable, table_, rdwTable, rdhTable, rdxTable, rdyTable, rSizeTable: TJBHuffmanTable;

    constructor CreateWith(sub: TJBReader; header: TJBSegmentHeader);
    procedure ParseHeader;
    procedure ReadRegionFlags;
    procedure ReadHuffmanFlags;
    procedure ReadUseRefinement;
    procedure ReadAmountOfSymbolInstances;
    procedure GetSymbols;
    procedure ComputeSymbolCodeLength;
    procedure CheckInput;
    function GetRegionBitmap: TJBBitmap; override;
    procedure SetCodingStatistics;
    procedure CreateRegionBitmap;
    function DecodeStripT: Int64;
    procedure DecodeSymbolInstances;
    function DecodeDT: Int64;
    function DecodeDfS: Int64;
    function DecodeIdS: Int64;
    function DecodeCurrentT: Int64;
    function DecodeID: Int64;
    function DecodeRI: Int64;
    function DecodeIb(r, id: Int64): TJBBitmap;
    function DecodeRdw: Int64;
    function DecodeRdh: Int64;
    function DecodeRdx: Int64;
    function DecodeRdy: Int64;
    function DecodeSymInRefSize: Int64;
    procedure BlitSym(ib: TJBBitmap; t: Int64);
    procedure InitSymbols;
    function GetUserTable(tablePosition: Integer): TJBHuffmanTable;
    procedure SymbolIDCodeLengths;
    procedure Init(header: TJBObject; sis: TJBReader); override;
    procedure SetContexts(acx, aIADT, aIAFS, aIADS, aIAIT, aIAID, aIARDW, aIARDH, aIARDX, aIARDY: TJBCx);
    procedure SetParameters(aArith: TJBArith; aIDec: TJBIntDecoder; aIsHuffman, aRefine: Boolean;
      sbw, sbh: Integer; sbNumInstances: Int64; aSbStrips, sbNumSyms, aDefaultPixel, aCombOp,
      aTransposed, aRefCorner, aSbdsOffset, aHuffFS, aHuffDS, aHuffDT, aHuffRDWidth, aHuffRDHeight,
      aHuffRDX, aHuffRDY, aHuffRSize, aSbrTemplate: Integer; aSbrATX, aSbrATY: TIntArray;
      aSbSyms: TBitmapList; aSbSymCodeLen: Integer);
    function GetRegionInfo: TJBRegionInfo; override;
  end;

  TJBHalftoneRegion = class(TJBRegion)
  public
    subInputStream: TJBReader;
    segmentHeader: TJBSegmentHeader;
    dataOffset: Int64;
    dataLength: Int64;
    regionInfo: TJBRegionInfo;
    hDefaultPixel: Integer;
    hCombinationOperator: Integer;
    hSkipEnabled: Boolean;
    hTemplate: Integer;
    isMMREncoded: Boolean;
    hGridWidth, hGridHeight, hGridX, hGridY: Integer;
    hRegionX, hRegionY: Integer;
    halftoneRegionBitmap: TJBBitmap;
    patterns: TBitmapList;
    procedure ParseHeader;
    procedure ComputeSegmentDataStructure;
    function GetRegionBitmap: TJBBitmap; override;
    procedure RenderPattern(const grayScaleValues: array of TIntArray);
    function GetPatterns: TBitmapList;
    function GrayScaleDecoding(bitsPerValue: Integer; hSkip: TJBBitmap): TIntArray; // flat [y*w + x]
    function ComputeX(m, n: Integer): Integer;
    function ComputeY(m, n: Integer): Integer;
    function ComputeHSkip(hpw, hph: Integer): TJBBitmap;
    function GetRegionInfo: TJBRegionInfo; override;
    procedure Init(header: TJBObject; sis: TJBReader); override;
  end;

// PdfJbig2Seg.inc -- segment object model: symbol dictionary, text region,
// pattern dictionary, halftone region, refinement region segment, segment
// header, page and document. Ported from Apache PDFBox JBIG2 (ASL 2.0).
// Included into the implementation section of PdfJbig2.pas.

procedure TJBProfiles.Init(header: TJBObject; sis: TJBReader);
begin
end;

//----------------------------------------------------------------------------
// Generic refinement region SEGMENT (7.4.7).
//----------------------------------------------------------------------------
procedure TJBRefinementRegion.ReadAtPixels;
begin
  SetLength(grAtX, 2);
  SetLength(grAtY, 2);
  grAtX[0] := subInputStream.ReadByteSigned;
  grAtY[0] := subInputStream.ReadByteSigned;
  grAtX[1] := subInputStream.ReadByteSigned;
  grAtY[1] := subInputStream.ReadByteSigned;
end;

procedure TJBRefinementRegion.ParseHeader;
begin
  regionInfo.ParseHeader;
  subInputStream.ReadBits(6); // bit 2-7 dirty
  if subInputStream.ReadBit = 1 then isTPGROn := True;
  templateID := subInputStream.ReadBit;
  if templateID = 0 then ReadAtPixels;
end;

function TJBRefinementRegion.GetGrReference: TJBBitmap;
var segs: TSegHeaderArray; region: TJBRegion;
begin
  segs := segmentHeader.rtSegments;
  if (segs = nil) or (System.Length(segs) = 0) then
  begin
    if regionInfo.combinationOperator <> COMB_REPLACE then
      raise EJBig2.Create('REPLACE combination operator expected');
    Result := JBExtract(regionInfo.xLocation, regionInfo.yLocation,
      regionInfo.bitmapWidth, regionInfo.bitmapHeight, pageBitmap);
    Exit;
  end;
  region := TJBRegion(segs[0].GetSegmentData);
  Result := region.GetRegionBitmap;
end;

function TJBRefinementRegion.GetRegionBitmap: TJBBitmap;
begin
  if referenceBitmap = nil then referenceBitmap := GetGrReference;
  if arithDecoder = nil then arithDecoder := TJBArith.Create(subInputStream);
  if cx = nil then cx := TJBCx.Create(8192, 1);
  Result := TJBRefinement.Decode(arithDecoder, cx, regionInfo.bitmapWidth,
    regionInfo.bitmapHeight, templateID, isTPGROn, referenceBitmap,
    referenceDX, referenceDY, grAtX, grAtY);
end;

function TJBRefinementRegion.GetRegionInfo: TJBRegionInfo;
begin
  Result := regionInfo;
end;

procedure TJBRefinementRegion.SetPageBitmap(apage: TJBBitmap);
begin
  pageBitmap := apage;
end;

procedure TJBRefinementRegion.Init(header: TJBObject; sis: TJBReader);
begin
  segmentHeader := TJBSegmentHeader(header);
  subInputStream := sis;
  regionInfo := TJBRegionInfo.CreateWith(subInputStream);
  ParseHeader;
end;

//----------------------------------------------------------------------------
// Pattern dictionary (7.4.4).
//----------------------------------------------------------------------------
procedure TJBPatternDictionary.ComputeSegmentDataStructure;
begin
  dataOffset := subInputStream.StreamPosition;
  dataLength := subInputStream.Length_ - dataOffset;
end;

procedure TJBPatternDictionary.ParseHeader;
begin
  subInputStream.ReadBits(5); // bit 3-7 dirty
  hdTemplate := Integer(subInputStream.ReadBits(2));
  if subInputStream.ReadBit = 1 then isMMREncoded := True;
  hdpWidth := subInputStream.ReadUByte and $FF;
  hdpHeight := subInputStream.ReadUByte and $FF;
  grayMax := subInputStream.ReadBits32(32);
  ComputeSegmentDataStructure;
  if (hdpHeight < 1) or (hdpWidth < 1) then
    raise EJBig2.Create('Pattern width/height must be greater than zero.');
end;

procedure TJBPatternDictionary.SetGbAtPixels;
begin
  if hdTemplate = 0 then
  begin
    SetLength(gbAtX, 4); SetLength(gbAtY, 4);
    gbAtX[0] := -hdpWidth; gbAtY[0] := 0;
    gbAtX[1] := -3; gbAtY[1] := -1;
    gbAtX[2] := 2; gbAtY[2] := -2;
    gbAtX[3] := -2; gbAtY[3] := -2;
  end
  else
  begin
    SetLength(gbAtX, 1); SetLength(gbAtY, 1);
    gbAtX[0] := -hdpWidth; gbAtY[0] := 0;
  end;
end;

function TJBPatternDictionary.GetDictionary: TBitmapList;
var genericRegion: TJBGenericRegion; collective: TJBBitmap; gray: Integer; pat: TJBBitmap;
begin
  if patterns = nil then
  begin
    if not isMMREncoded then SetGbAtPixels;
    genericRegion := TJBGenericRegion.CreateWith(subInputStream);
    genericRegion.SetParamsFull(isMMREncoded, dataOffset, dataLength, hdpHeight,
      (grayMax + 1) * hdpWidth, hdTemplate, False, False, nil, gbAtX, gbAtY);
    collective := genericRegion.GetRegionBitmap;
    patterns := TBitmapList.Create;
    gray := 0;
    while gray <= grayMax do
    begin
      pat := JBExtract(hdpWidth * gray, 0, hdpWidth, hdpHeight, collective);
      patterns.Add(pat);
      Inc(gray);
    end;
  end;
  Result := patterns;
end;

procedure TJBPatternDictionary.Init(header: TJBObject; sis: TJBReader);
begin
  subInputStream := sis;
  ParseHeader;
end;

//----------------------------------------------------------------------------
// Symbol dictionary (7.4.2 / 6.5).
//----------------------------------------------------------------------------
procedure TJBSymbolDictionary.ReadRegionFlags;
begin
  subInputStream.ReadBits(3); // bit 13-15 dirty
  sdrTemplate := subInputStream.ReadBit;
  sdTemplate := Integer(subInputStream.ReadBits(2) and $F);
  if subInputStream.ReadBit = 1 then isCodingContextRetained := True;
  if subInputStream.ReadBit = 1 then isCodingContextUsed := True;
  sdHuffAggInstanceSelection := subInputStream.ReadBit;
  sdHuffBMSizeSelection := subInputStream.ReadBit;
  sdHuffDecodeWidthSelection := Integer(subInputStream.ReadBits(2) and $F);
  sdHuffDecodeHeightSelection := Integer(subInputStream.ReadBits(2) and $F);
  if subInputStream.ReadBit = 1 then useRefinementAggregation := True;
  if subInputStream.ReadBit = 1 then isHuffmanEncoded := True;
end;

procedure TJBSymbolDictionary.ReadAtPixels(amount: Integer);
var i: Integer;
begin
  SetLength(sdATX, amount); SetLength(sdATY, amount);
  for i := 0 to amount - 1 do
  begin
    sdATX[i] := subInputStream.ReadByteSigned;
    sdATY[i] := subInputStream.ReadByteSigned;
  end;
end;

procedure TJBSymbolDictionary.ReadRefinementAtPixels(amount: Integer);
var i: Integer;
begin
  SetLength(sdrATX, amount); SetLength(sdrATY, amount);
  for i := 0 to amount - 1 do
  begin
    sdrATX[i] := subInputStream.ReadByteSigned;
    sdrATY[i] := subInputStream.ReadByteSigned;
  end;
end;

procedure TJBSymbolDictionary.SetAtPixels;
begin
  if not isHuffmanEncoded then
  begin
    if sdTemplate = 0 then ReadAtPixels(4) else ReadAtPixels(1);
  end;
end;

procedure TJBSymbolDictionary.SetRefinementAtPixels;
begin
  if useRefinementAggregation and (sdrTemplate = 0) then ReadRefinementAtPixels(2);
end;

procedure TJBSymbolDictionary.SetInSyms;
begin
  if segmentHeader.rtSegments <> nil then RetrieveImportSymbols
  else importSymbols := TBitmapList.Create;
end;

procedure TJBSymbolDictionary.CheckInput;
begin
  if isHuffmanEncoded then
  begin
    if sdTemplate <> 0 then sdTemplate := 0;
    if not useRefinementAggregation then
    begin
      if isCodingContextRetained then isCodingContextRetained := False;
      if isCodingContextUsed then isCodingContextUsed := False;
    end;
  end
  else
  begin
    if sdHuffBMSizeSelection <> 0 then sdHuffBMSizeSelection := 0;
    if sdHuffDecodeWidthSelection <> 0 then sdHuffDecodeWidthSelection := 0;
    if sdHuffDecodeHeightSelection <> 0 then sdHuffDecodeHeightSelection := 0;
  end;
  if not useRefinementAggregation then
    if sdrTemplate <> 0 then sdrTemplate := 0;
  if (not isHuffmanEncoded) or (not useRefinementAggregation) then
    if sdHuffAggInstanceSelection <> 0 then sdHuffAggInstanceSelection := 0;
end;

procedure TJBSymbolDictionary.ParseHeader;
var rtSegs: TSegHeaderArray; i: Integer; isContextAdopted: Boolean;
begin
  ReadRegionFlags;
  SetAtPixels;
  SetRefinementAtPixels;
  amountOfExportSymbolss := subInputStream.ReadBits32(32);
  amountOfNewSymbols := subInputStream.ReadBits32(32);
  SetInSyms;

  isContextAdopted := False;
  rtSegs := segmentHeader.rtSegments;
  if rtSegs <> nil then
    for i := System.Length(rtSegs) - 1 downto 0 do
      if rtSegs[i].segmentType = 0 then
      begin
        lastSymbolDictionary := TJBSymbolDictionary(rtSegs[i].GetSegmentData);
        if isCodingContextUsed and lastSymbolDictionary.isCodingContextRetained then
          isContextAdopted := True;
        Break;
      end;
  if isCodingContextUsed and not isContextAdopted then
    raise EJBig2.Create('Coding context reuse requested but unavailable');
  CheckInput;
end;

procedure TJBSymbolDictionary.ResetIntegerCoderStatistics;
begin
  cxIADT := TJBCx.Create(512, 1);
  cxIADH := TJBCx.Create(512, 1);
  cxIADW := TJBCx.Create(512, 1);
  cxIAAI := TJBCx.Create(512, 1);
  cxIAEX := TJBCx.Create(512, 1);
  if useRefinementAggregation then
  begin
    cxIAID := TJBCx.Create(1 shl sbSymCodeLen, 1);
    cxIARDX := TJBCx.Create(512, 1);
    cxIARDY := TJBCx.Create(512, 1);
  end;
  arithmeticDecoder := TJBArith.Create(subInputStream);
  iDecoder := TJBIntDecoder.Create(arithmeticDecoder);
end;

function TJBSymbolDictionary.GetDictionary: TBitmapList;
var
  newSymbolsWidths: TIntArray;
  heightClassHeight, symbolWidth, totalWidth, heightClassFirstSymbolIndex: Integer;
  differenceWidth, bmSize: Int64;
  collective: TJBBitmap;
  exFlags: TIntArray;
begin
  if exportSymbols = nil then
  begin
    if useRefinementAggregation then sbSymCodeLen := GetSbSymCodeLen;
    SetSymbolsArray;

    if (not isHuffmanEncoded) or useRefinementAggregation then
    begin
      if isCodingContextUsed and (lastSymbolDictionary <> nil) then
        cx := lastSymbolDictionary.cx.Copy
      else
        cx := TJBCx.Create(65536, 1);
    end;
    if not isHuffmanEncoded then ResetIntegerCoderStatistics;

    SetLength(newSymbols, amountOfNewSymbols);
    newSymbolsWidths := nil;
    if isHuffmanEncoded and not useRefinementAggregation then
      SetLength(newSymbolsWidths, amountOfNewSymbols);

    heightClassHeight := 0;
    amountOfDecodedSymbols := 0;

    while amountOfDecodedSymbols < amountOfNewSymbols do
    begin
      heightClassHeight := heightClassHeight + DecodeHeightClassDeltaHeight;
      symbolWidth := 0;
      totalWidth := 0;
      heightClassFirstSymbolIndex := amountOfDecodedSymbols;

      while True do
      begin
        differenceWidth := DecodeDifferenceWidth;
        if (differenceWidth = OOB) or (amountOfDecodedSymbols >= amountOfNewSymbols) then
          Break;
        symbolWidth := symbolWidth + Integer(differenceWidth);
        totalWidth := totalWidth + symbolWidth;
        if (not isHuffmanEncoded) or useRefinementAggregation then
        begin
          if not useRefinementAggregation then
            DecodeDirectlyThroughGenericRegion(symbolWidth, heightClassHeight)
          else
            DecodeAggregate(symbolWidth, heightClassHeight);
        end
        else if isHuffmanEncoded and not useRefinementAggregation then
          newSymbolsWidths[amountOfDecodedSymbols] := symbolWidth;
        Inc(amountOfDecodedSymbols);
      end;

      if isHuffmanEncoded and not useRefinementAggregation then
      begin
        if sdHuffBMSizeSelection = 0 then
          bmSize := GetStandardTable(1).Decode(subInputStream)
        else
          bmSize := HuffDecodeBmSize;
        subInputStream.SkipBits;
        collective := DecodeHeightClassCollectiveBitmap(bmSize, heightClassHeight, totalWidth);
        subInputStream.SkipBits;
        DecodeHeightClassBitmap(collective, heightClassFirstSymbolIndex, heightClassHeight, newSymbolsWidths);
      end;
    end;

    exFlags := GetToExportFlags;
    SetExportedSymbols(exFlags);
  end;
  Result := exportSymbols;
end;

procedure TJBSymbolDictionary.DecodeHeightClassBitmap(collective: TJBBitmap; firstSym, hcHeight: Integer; widths: TIntArray);
var i, j, startColumn: Integer; sym: TJBBitmap;
begin
  for i := firstSym to amountOfDecodedSymbols - 1 do
  begin
    startColumn := 0;
    for j := firstSym to i - 1 do
      startColumn := startColumn + widths[j];
    sym := JBExtract(startColumn, 0, widths[i], hcHeight, collective);
    newSymbols[i] := sym;
    sbSymbols.Add(sym);
  end;
end;

function TJBSymbolDictionary.HuffDecodeRefAggNInst: Int64;
var aggNr: Integer;
begin
  if sdHuffAggInstanceSelection = 0 then
    Result := GetStandardTable(1).Decode(subInputStream)
  else if sdHuffAggInstanceSelection = 1 then
  begin
    if aggInstTable = nil then
    begin
      aggNr := 0;
      if sdHuffDecodeHeightSelection = 3 then Inc(aggNr);
      if sdHuffDecodeWidthSelection = 3 then Inc(aggNr);
      if sdHuffBMSizeSelection = 3 then Inc(aggNr);
      aggInstTable := GetUserTable(aggNr);
    end;
    Result := aggInstTable.Decode(subInputStream);
  end
  else
    Result := 0;
end;

procedure TJBSymbolDictionary.DecodeAggregate(symbolWidth, hcHeight: Integer);
var nInstances: Int64;
begin
  if isHuffmanEncoded then nInstances := HuffDecodeRefAggNInst
  else nInstances := iDecoder.Decode(cxIAAI);
  if nInstances > 1 then
    DecodeThroughTextRegion(symbolWidth, hcHeight, nInstances)
  else if nInstances = 1 then
    DecodeRefinedSymbol(symbolWidth, hcHeight);
end;

procedure TJBSymbolDictionary.DecodeThroughTextRegion(symbolWidth, hcHeight: Integer; nInstances: Int64);
begin
  if textRegion = nil then
  begin
    textRegion := TJBTextRegion.CreateWith(subInputStream, nil);
    textRegion.SetContexts(cx, TJBCx.Create(512, 1), TJBCx.Create(512, 1),
      TJBCx.Create(512, 1), TJBCx.Create(512, 1), cxIAID, TJBCx.Create(512, 1),
      TJBCx.Create(512, 1), TJBCx.Create(512, 1), TJBCx.Create(512, 1));
  end;
  SetSymbolsArray;
  textRegion.SetParameters(arithmeticDecoder, iDecoder, isHuffmanEncoded, True, symbolWidth,
    hcHeight, nInstances, 1, amountOfImportedSymbols + amountOfDecodedSymbols, 0, 0, 0, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, sdrTemplate, sdrATX, sdrATY, sbSymbols, sbSymCodeLen);
  AddSymbol(textRegion);
end;

procedure TJBSymbolDictionary.DecodeRefinedSymbol(symbolWidth, hcHeight: Integer);
var id, rdx, rdy: Integer; symInRefSize, streamPosition0: Int64; ibo: TJBBitmap;
begin
  symInRefSize := 0; streamPosition0 := 0;
  if isHuffmanEncoded then
  begin
    id := subInputStream.ReadBits32(sbSymCodeLen);
    rdx := Integer(GetStandardTable(15).Decode(subInputStream));
    rdy := Integer(GetStandardTable(15).Decode(subInputStream));
    symInRefSize := GetStandardTable(1).Decode(subInputStream);
    subInputStream.SkipBits;
    streamPosition0 := subInputStream.StreamPosition;
    arithmeticDecoder := TJBArith.Create(subInputStream);
  end
  else
  begin
    id := iDecoder.DecodeIAID(cxIAID, sbSymCodeLen);
    rdx := Integer(iDecoder.Decode(cxIARDX));
    rdy := Integer(iDecoder.Decode(cxIARDY));
  end;
  SetSymbolsArray;
  ibo := sbSymbols.Get(id);
  DecodeNewSymbols(symbolWidth, hcHeight, ibo, rdx, rdy);
  if isHuffmanEncoded then
    subInputStream.Seek(streamPosition0 + symInRefSize);
end;

procedure TJBSymbolDictionary.DecodeNewSymbols(symWidth, hcHeight: Integer; ibo: TJBBitmap; rdx, rdy: Integer);
var symbol: TJBBitmap;
begin
  symbol := TJBRefinement.Decode(arithmeticDecoder, cx, symWidth, hcHeight,
    sdrTemplate, False, ibo, rdx, rdy, sdrATX, sdrATY);
  newSymbols[amountOfDecodedSymbols] := symbol;
  sbSymbols.Add(symbol);
end;

procedure TJBSymbolDictionary.DecodeDirectlyThroughGenericRegion(symWidth, hcHeight: Integer);
begin
  if genericRegion = nil then genericRegion := TJBGenericRegion.CreateWith(subInputStream);
  genericRegion.SetParamsSym(False, sdTemplate, False, False, sdATX, sdATY, symWidth,
    hcHeight, cx, arithmeticDecoder);
  AddSymbol(genericRegion);
end;

procedure TJBSymbolDictionary.AddSymbol(region: TJBRegion);
var symbol: TJBBitmap;
begin
  symbol := region.GetRegionBitmap;
  newSymbols[amountOfDecodedSymbols] := symbol;
  sbSymbols.Add(symbol);
end;

function TJBSymbolDictionary.DecodeDifferenceWidth: Int64;
var dwNr: Integer;
begin
  if isHuffmanEncoded then
  begin
    case sdHuffDecodeWidthSelection of
      0: Result := GetStandardTable(2).Decode(subInputStream);
      1: Result := GetStandardTable(3).Decode(subInputStream);
      3:
        begin
          if dwTable = nil then
          begin
            dwNr := 0;
            if sdHuffDecodeHeightSelection = 3 then Inc(dwNr);
            dwTable := GetUserTable(dwNr);
          end;
          Result := dwTable.Decode(subInputStream);
        end;
    else
      Result := 0;
    end;
  end
  else
    Result := iDecoder.Decode(cxIADW);
end;

function TJBSymbolDictionary.DecodeHeightClassDeltaHeight: Int64;
begin
  if isHuffmanEncoded then
  begin
    case sdHuffDecodeHeightSelection of
      0: Result := GetStandardTable(4).Decode(subInputStream);
      1: Result := GetStandardTable(5).Decode(subInputStream);
      3:
        begin
          if dhTable = nil then dhTable := GetUserTable(0);
          Result := dhTable.Decode(subInputStream);
        end;
    else
      Result := 0;
    end;
  end
  else
    Result := iDecoder.Decode(cxIADH);
end;

function TJBSymbolDictionary.DecodeHeightClassCollectiveBitmap(bmSize: Int64; hcHeight, totalWidth: Integer): TJBBitmap;
var bmp: TJBBitmap; i: Integer;
begin
  if bmSize = 0 then
  begin
    bmp := TJBBitmap.Create(totalWidth, hcHeight);
    for i := 0 to bmp.GetLength - 1 do
      bmp.SetByte(i, subInputStream.ReadUByte);
    Result := bmp;
  end
  else
  begin
    if genericRegion = nil then genericRegion := TJBGenericRegion.CreateWith(subInputStream);
    genericRegion.SetParamsCollective(True, subInputStream.StreamPosition, bmSize, hcHeight, totalWidth);
    Result := genericRegion.GetRegionBitmap;
    // In PDFBox the parent stream advances as a side effect of the buffered read
    // when the MMR decompressor is constructed; here the MMR uses a private copy,
    // so step the stream past the bmSize-byte collective block explicitly.
    subInputStream.Seek(subInputStream.StreamPosition + bmSize);
  end;
end;

procedure TJBSymbolDictionary.SetExportedSymbols(toExportFlags: TIntArray);
var i: Integer;
begin
  exportSymbols := TBitmapList.Create;
  for i := 0 to amountOfImportedSymbols + amountOfNewSymbols - 1 do
    if toExportFlags[i] = 1 then
    begin
      if i < amountOfImportedSymbols then
        exportSymbols.Add(importSymbols.Get(i))
      else
        exportSymbols.Add(newSymbols[i - amountOfImportedSymbols]);
    end;
end;

function TJBSymbolDictionary.GetToExportFlags: TIntArray;
var exIndex, curExFlag, total, i: Integer; exRunLength: Int64;
begin
  Result := nil;
  total := amountOfImportedSymbols + amountOfNewSymbols;
  if (amountOfImportedSymbols < 0) or (amountOfNewSymbols < 0) then
    raise EJBig2.Create('Invalid number of symbols');
  exIndex := 0; curExFlag := 0;
  SetLength(Result, total);
  while exIndex < total do
  begin
    if isHuffmanEncoded then exRunLength := GetStandardTable(1).Decode(subInputStream)
    else exRunLength := iDecoder.Decode(cxIAEX);
    if (exRunLength < 0) or (exRunLength > total - exIndex) then
      raise EJBig2.Create('Invalid EXRUNLENGTH: ' + IntToStr(exRunLength));
    for i := exIndex to exIndex + Integer(exRunLength) - 1 do
      Result[i] := curExFlag;
    exIndex := exIndex + Integer(exRunLength);
    if curExFlag = 0 then curExFlag := 1 else curExFlag := 0;
  end;
end;

function TJBSymbolDictionary.HuffDecodeBmSize: Int64;
var bmNr: Integer;
begin
  if bmSizeTable = nil then
  begin
    bmNr := 0;
    if sdHuffDecodeHeightSelection = 3 then Inc(bmNr);
    if sdHuffDecodeWidthSelection = 3 then Inc(bmNr);
    bmSizeTable := GetUserTable(bmNr);
  end;
  Result := bmSizeTable.Decode(subInputStream);
end;

function TJBSymbolDictionary.GetSbSymCodeLen: Integer;
var v: Integer;
begin
  v := CeilLog2(amountOfImportedSymbols + amountOfNewSymbols);
  if isHuffmanEncoded then
  begin
    if v > 1 then Result := v else Result := 1;
  end
  else
    Result := v;
end;

procedure TJBSymbolDictionary.SetSymbolsArray;
begin
  if importSymbols = nil then RetrieveImportSymbols;
  if sbSymbols = nil then
  begin
    sbSymbols := TBitmapList.Create;
    sbSymbols.AddList(importSymbols);
  end;
end;

procedure TJBSymbolDictionary.RetrieveImportSymbols;
var i: Integer; sd: TJBSymbolDictionary; seg: TJBSegmentHeader;
begin
  importSymbols := TBitmapList.Create;
  for i := 0 to System.Length(segmentHeader.rtSegments) - 1 do
  begin
    seg := segmentHeader.rtSegments[i];
    if seg.segmentType = 0 then
    begin
      sd := TJBSymbolDictionary(seg.GetSegmentData);
      importSymbols.AddList(sd.GetDictionary);
      amountOfImportedSymbols := amountOfImportedSymbols + sd.amountOfExportSymbolss;
    end;
  end;
end;

function TJBSymbolDictionary.GetUserTable(tablePosition: Integer): TJBHuffmanTable;
var tableCounter, i: Integer; seg: TJBSegmentHeader;
begin
  tableCounter := 0;
  for i := 0 to System.Length(segmentHeader.rtSegments) - 1 do
  begin
    seg := segmentHeader.rtSegments[i];
    if seg.segmentType = 53 then
    begin
      if tableCounter = tablePosition then
      begin
        Result := BuildEncodedTable(TJBTable(seg.GetSegmentData));
        Exit;
      end
      else
        Inc(tableCounter);
    end;
  end;
  Result := nil;
end;

procedure TJBSymbolDictionary.Init(header: TJBObject; sis: TJBReader);
begin
  subInputStream := sis;
  segmentHeader := TJBSegmentHeader(header);
  ParseHeader;
end;

//----------------------------------------------------------------------------
// Text region (7.4.3 / 6.4).
//----------------------------------------------------------------------------
constructor TJBTextRegion.CreateWith(sub: TJBReader; header: TJBSegmentHeader);
begin
  inherited Create;
  subInputStream := sub;
  regionInfo := TJBRegionInfo.CreateWith(sub);
  segmentHeader := TJBSegmentHeader(header);
  symbols := TBitmapList.Create;
end;

procedure TJBTextRegion.ReadRegionFlags;
begin
  sbrTemplate := subInputStream.ReadBit;
  sbdsOffset := Integer(subInputStream.ReadBits(5));
  if sbdsOffset > $0F then sbdsOffset := sbdsOffset - $20;
  defaultPixel := subInputStream.ReadBit;
  combinationOperator := TranslateCombOp(Integer(subInputStream.ReadBits(2) and $3));
  isTransposed := subInputStream.ReadBit;
  referenceCorner := Integer(subInputStream.ReadBits(2) and $3);
  logSBStrips := Integer(subInputStream.ReadBits(2) and $3);
  sbStrips := 1 shl logSBStrips;
  if subInputStream.ReadBit = 1 then useRefinement := True;
  if subInputStream.ReadBit = 1 then isHuffmanEncoded := True;
end;

procedure TJBTextRegion.ReadHuffmanFlags;
begin
  subInputStream.ReadBit; // bit 15 dirty
  sbHuffRSize := subInputStream.ReadBit;
  sbHuffRDY := Integer(subInputStream.ReadBits(2) and $F);
  sbHuffRDX := Integer(subInputStream.ReadBits(2) and $F);
  sbHuffRDHeight := Integer(subInputStream.ReadBits(2) and $F);
  sbHuffRDWidth := Integer(subInputStream.ReadBits(2) and $F);
  sbHuffDT := Integer(subInputStream.ReadBits(2) and $F);
  sbHuffDS := Integer(subInputStream.ReadBits(2) and $F);
  sbHuffFS := Integer(subInputStream.ReadBits(2) and $F);
end;

procedure TJBTextRegion.ReadUseRefinement;
begin
  if useRefinement and (sbrTemplate = 0) then
  begin
    SetLength(sbrATX, 2); SetLength(sbrATY, 2);
    sbrATX[0] := subInputStream.ReadByteSigned;
    sbrATY[0] := subInputStream.ReadByteSigned;
    sbrATX[1] := subInputStream.ReadByteSigned;
    sbrATY[1] := subInputStream.ReadByteSigned;
  end;
end;

procedure TJBTextRegion.ReadAmountOfSymbolInstances;
var pixels: Int64;
begin
  amountOfSymbolInstances := subInputStream.ReadBits(32) and $FFFFFFFF;
  pixels := Int64(regionInfo.bitmapWidth) * Int64(regionInfo.bitmapHeight);
  if pixels < amountOfSymbolInstances then amountOfSymbolInstances := pixels;
end;

procedure TJBTextRegion.GetSymbols;
begin
  if segmentHeader.rtSegments <> nil then InitSymbols;
end;

procedure TJBTextRegion.ComputeSymbolCodeLength;
begin
  if isHuffmanEncoded then SymbolIDCodeLengths
  else symbolCodeLength := CeilLog2(amountOfSymbols);
end;

procedure TJBTextRegion.CheckInput;
begin
  if not useRefinement then
    if sbrTemplate <> 0 then sbrTemplate := 0;
  if (sbHuffFS = 2) or (sbHuffRDWidth = 2) or (sbHuffRDHeight = 2) or (sbHuffRDX = 2) or (sbHuffRDY = 2) then
    raise EJBig2.Create('Huffman flag value of text region segment is not permitted');
  if not useRefinement then
  begin
    if sbHuffRSize <> 0 then sbHuffRSize := 0;
    if sbHuffRDY <> 0 then sbHuffRDY := 0;
    if sbHuffRDX <> 0 then sbHuffRDX := 0;
    if sbHuffRDWidth <> 0 then sbHuffRDWidth := 0;
    if sbHuffRDHeight <> 0 then sbHuffRDHeight := 0;
  end;
end;

procedure TJBTextRegion.ParseHeader;
begin
  regionInfo.ParseHeader;
  ReadRegionFlags;
  if isHuffmanEncoded then ReadHuffmanFlags;
  ReadUseRefinement;
  ReadAmountOfSymbolInstances;
  GetSymbols;
  ComputeSymbolCodeLength;
  CheckInput;
end;

procedure TJBTextRegion.SetCodingStatistics;
begin
  if cxIADT = nil then cxIADT := TJBCx.Create(512, 1);
  if cxIAFS = nil then cxIAFS := TJBCx.Create(512, 1);
  if cxIADS = nil then cxIADS := TJBCx.Create(512, 1);
  if cxIAIT = nil then cxIAIT := TJBCx.Create(512, 1);
  if cxIARI = nil then cxIARI := TJBCx.Create(512, 1);
  if cxIARDW = nil then cxIARDW := TJBCx.Create(512, 1);
  if cxIARDH = nil then cxIARDH := TJBCx.Create(512, 1);
  if cxIAID = nil then cxIAID := TJBCx.Create(1 shl symbolCodeLength, 1);
  if cxIARDX = nil then cxIARDX := TJBCx.Create(512, 1);
  if cxIARDY = nil then cxIARDY := TJBCx.Create(512, 1);
  if arithmeticDecoder = nil then arithmeticDecoder := TJBArith.Create(subInputStream);
  if integerDecoder = nil then integerDecoder := TJBIntDecoder.Create(arithmeticDecoder);
end;

procedure TJBTextRegion.CreateRegionBitmap;
begin
  regionBitmap := TJBBitmap.Create(regionInfo.bitmapWidth, regionInfo.bitmapHeight);
  if defaultPixel <> 0 then regionBitmap.FillBitmap($FF);
end;

function TJBTextRegion.GetRegionBitmap: TJBBitmap;
begin
  if not isHuffmanEncoded then SetCodingStatistics;
  CreateRegionBitmap;
  DecodeSymbolInstances;
  Result := regionBitmap;
end;

function TJBTextRegion.DecodeStripT: Int64;
var stripT: Int64; dtNr: Integer;
begin
  stripT := 0;
  if isHuffmanEncoded then
  begin
    if sbHuffDT = 3 then
    begin
      if table_ = nil then
      begin
        dtNr := 0;
        if sbHuffFS = 3 then Inc(dtNr);
        if sbHuffDS = 3 then Inc(dtNr);
        table_ := GetUserTable(dtNr);
      end;
      stripT := table_.Decode(subInputStream);
    end
    else
      stripT := GetStandardTable(11 + sbHuffDT).Decode(subInputStream);
  end
  else
    stripT := integerDecoder.Decode(cxIADT);
  Result := stripT * (-sbStrips);
end;

procedure TJBTextRegion.DecodeSymbolInstances;
var stripT, firstS, instanceCounter, dT, dfS, idS, currentT, t, id, r: Int64; first: Boolean; ib: TJBBitmap;
begin
  stripT := DecodeStripT;
  firstS := 0;
  instanceCounter := 0;
  while instanceCounter < amountOfSymbolInstances do
  begin
    dT := DecodeDT;
    stripT := stripT + dT;
    dfS := 0;
    first := True;
    currentS := 0;
    while True do
    begin
      if first then
      begin
        dfS := DecodeDfS;
        firstS := firstS + dfS;
        currentS := firstS;
        first := False;
      end
      else
      begin
        idS := DecodeIdS;
        if (idS = OOB) or (instanceCounter >= amountOfSymbolInstances) then Break;
        currentS := currentS + (idS + sbdsOffset);
      end;
      currentT := DecodeCurrentT;
      t := stripT + currentT;
      id := DecodeID;
      r := DecodeRI;
      ib := DecodeIb(r, id);
      BlitSym(ib, t);
      Inc(instanceCounter);
    end;
  end;
end;

function TJBTextRegion.DecodeDT: Int64;
var dT: Int64;
begin
  if isHuffmanEncoded then
  begin
    if sbHuffDT = 3 then dT := table_.Decode(subInputStream)
    else dT := GetStandardTable(11 + sbHuffDT).Decode(subInputStream);
  end
  else
    dT := integerDecoder.Decode(cxIADT);
  Result := dT * sbStrips;
end;

function TJBTextRegion.DecodeDfS: Int64;
begin
  if isHuffmanEncoded then
  begin
    if sbHuffFS = 3 then
    begin
      if fsTable = nil then fsTable := GetUserTable(0);
      Result := fsTable.Decode(subInputStream);
    end
    else
      Result := GetStandardTable(6 + sbHuffFS).Decode(subInputStream);
  end
  else
    Result := integerDecoder.Decode(cxIAFS);
end;

function TJBTextRegion.DecodeIdS: Int64;
var dsNr: Integer;
begin
  if isHuffmanEncoded then
  begin
    if sbHuffDS = 3 then
    begin
      if dsTable = nil then
      begin
        dsNr := 0;
        if sbHuffFS = 3 then Inc(dsNr);
        dsTable := GetUserTable(dsNr);
      end;
      Result := dsTable.Decode(subInputStream);
    end
    else
      Result := GetStandardTable(8 + sbHuffDS).Decode(subInputStream);
  end
  else
    Result := integerDecoder.Decode(cxIADS);
end;

function TJBTextRegion.DecodeCurrentT: Int64;
begin
  if sbStrips <> 1 then
  begin
    if isHuffmanEncoded then Result := subInputStream.ReadBits(logSBStrips)
    else Result := integerDecoder.Decode(cxIAIT);
  end
  else
    Result := 0;
end;

function TJBTextRegion.DecodeID: Int64;
begin
  if isHuffmanEncoded then
  begin
    if symbolCodeTable = nil then Result := subInputStream.ReadBits(symbolCodeLength)
    else Result := symbolCodeTable.Decode(subInputStream);
  end
  else
    Result := integerDecoder.DecodeIAID(cxIAID, symbolCodeLength);
end;

function TJBTextRegion.DecodeRI: Int64;
begin
  if useRefinement then
  begin
    if isHuffmanEncoded then Result := subInputStream.ReadBit
    else Result := integerDecoder.Decode(cxIARI);
  end
  else
    Result := 0;
end;

function TJBTextRegion.DecodeIb(r, id: Int64): TJBBitmap;
var rdw, rdh, rdx, rdy, symInRefSize, streamPosition0: Int64; ibo: TJBBitmap;
    wo, ho, grx, gry: Integer;
begin
  if r = 0 then
    Result := symbols.Get(Integer(id))
  else
  begin
    rdw := DecodeRdw;
    rdh := DecodeRdh;
    rdx := DecodeRdx;
    rdy := DecodeRdy;
    symInRefSize := 0;
    if isHuffmanEncoded then
    begin
      symInRefSize := DecodeSymInRefSize;
      subInputStream.SkipBits;
    end;
    streamPosition0 := subInputStream.StreamPosition;
    ibo := symbols.Get(Integer(id));
    wo := ibo.Width;
    ho := ibo.Height;
    grx := Integer((rdw shr 1) + rdx);
    gry := Integer((rdh shr 1) + rdy);
    if arithmeticDecoder = nil then arithmeticDecoder := TJBArith.Create(subInputStream);
    if cx = nil then cx := TJBCx.Create(65536, 1);
    Result := TJBRefinement.Decode(arithmeticDecoder, cx, Integer(wo + rdw), Integer(ho + rdh),
      sbrTemplate, False, ibo, grx, gry, sbrATX, sbrATY);
    if isHuffmanEncoded then
      subInputStream.Seek(streamPosition0 + symInRefSize);
  end;
end;

function TJBTextRegion.DecodeRdw: Int64;
var nr: Integer;
begin
  if isHuffmanEncoded then
  begin
    if sbHuffRDWidth = 3 then
    begin
      if rdwTable = nil then
      begin
        nr := 0;
        if sbHuffFS = 3 then Inc(nr);
        if sbHuffDS = 3 then Inc(nr);
        if sbHuffDT = 3 then Inc(nr);
        rdwTable := GetUserTable(nr);
      end;
      Result := rdwTable.Decode(subInputStream);
    end
    else
      Result := GetStandardTable(14 + sbHuffRDWidth).Decode(subInputStream);
  end
  else
    Result := integerDecoder.Decode(cxIARDW);
end;

function TJBTextRegion.DecodeRdh: Int64;
var nr: Integer;
begin
  if isHuffmanEncoded then
  begin
    if sbHuffRDHeight = 3 then
    begin
      if rdhTable = nil then
      begin
        nr := 0;
        if sbHuffFS = 3 then Inc(nr);
        if sbHuffDS = 3 then Inc(nr);
        if sbHuffDT = 3 then Inc(nr);
        if sbHuffRDWidth = 3 then Inc(nr);
        rdhTable := GetUserTable(nr);
      end;
      Result := rdhTable.Decode(subInputStream);
    end
    else
      Result := GetStandardTable(14 + sbHuffRDHeight).Decode(subInputStream);
  end
  else
    Result := integerDecoder.Decode(cxIARDH);
end;

function TJBTextRegion.DecodeRdx: Int64;
var nr: Integer;
begin
  if isHuffmanEncoded then
  begin
    if sbHuffRDX = 3 then
    begin
      if rdxTable = nil then
      begin
        nr := 0;
        if sbHuffFS = 3 then Inc(nr);
        if sbHuffDS = 3 then Inc(nr);
        if sbHuffDT = 3 then Inc(nr);
        if sbHuffRDWidth = 3 then Inc(nr);
        if sbHuffRDHeight = 3 then Inc(nr);
        rdxTable := GetUserTable(nr);
      end;
      Result := rdxTable.Decode(subInputStream);
    end
    else
      Result := GetStandardTable(14 + sbHuffRDX).Decode(subInputStream);
  end
  else
    Result := integerDecoder.Decode(cxIARDX);
end;

function TJBTextRegion.DecodeRdy: Int64;
var nr: Integer;
begin
  if isHuffmanEncoded then
  begin
    if sbHuffRDY = 3 then
    begin
      if rdyTable = nil then
      begin
        nr := 0;
        if sbHuffFS = 3 then Inc(nr);
        if sbHuffDS = 3 then Inc(nr);
        if sbHuffDT = 3 then Inc(nr);
        if sbHuffRDWidth = 3 then Inc(nr);
        if sbHuffRDHeight = 3 then Inc(nr);
        if sbHuffRDX = 3 then Inc(nr);
        rdyTable := GetUserTable(nr);
      end;
      Result := rdyTable.Decode(subInputStream);
    end
    else
      Result := GetStandardTable(14 + sbHuffRDY).Decode(subInputStream);
  end
  else
    Result := integerDecoder.Decode(cxIARDY);
end;

function TJBTextRegion.DecodeSymInRefSize: Int64;
var nr: Integer;
begin
  if sbHuffRSize = 0 then
    Result := GetStandardTable(1).Decode(subInputStream)
  else
  begin
    if rSizeTable = nil then
    begin
      nr := 0;
      if sbHuffFS = 3 then Inc(nr);
      if sbHuffDS = 3 then Inc(nr);
      if sbHuffDT = 3 then Inc(nr);
      if sbHuffRDWidth = 3 then Inc(nr);
      if sbHuffRDHeight = 3 then Inc(nr);
      if sbHuffRDX = 3 then Inc(nr);
      if sbHuffRDY = 3 then Inc(nr);
      rSizeTable := GetUserTable(nr);
    end;
    Result := rSizeTable.Decode(subInputStream);
  end;
end;

procedure TJBTextRegion.BlitSym(ib: TJBBitmap; t: Int64);
var s, swap: Int64;
begin
  if (isTransposed = 0) and ((referenceCorner = 2) or (referenceCorner = 3)) then
    currentS := currentS + ib.Width - 1
  else if (isTransposed = 1) and ((referenceCorner = 0) or (referenceCorner = 2)) then
    currentS := currentS + ib.Height - 1;

  s := currentS;

  if isTransposed = 1 then
  begin
    swap := t; t := s; s := swap;
  end;

  if referenceCorner <> 1 then
  begin
    case referenceCorner of
      0: t := t - (ib.Height - 1);
      2: begin t := t - (ib.Height - 1); s := s - (ib.Width - 1); end;
      3: s := s - (ib.Width - 1);
    end;
  end;

  JBBlit(ib, regionBitmap, Integer(s), Integer(t), combinationOperator);

  if (isTransposed = 0) and ((referenceCorner = 0) or (referenceCorner = 1)) then
    currentS := currentS + ib.Width - 1;
  if (isTransposed = 1) and ((referenceCorner = 1) or (referenceCorner = 3)) then
    currentS := currentS + ib.Height - 1;
end;

procedure TJBTextRegion.InitSymbols;
var i: Integer; sd: TJBSymbolDictionary; seg: TJBSegmentHeader;
begin
  for i := 0 to System.Length(segmentHeader.rtSegments) - 1 do
  begin
    seg := segmentHeader.rtSegments[i];
    if seg.segmentType = 0 then
    begin
      sd := TJBSymbolDictionary(seg.GetSegmentData);
      sd.cxIAID := cxIAID;
      symbols.AddList(sd.GetDictionary);
    end;
  end;
  amountOfSymbols := symbols.Count;
end;

function TJBTextRegion.GetUserTable(tablePosition: Integer): TJBHuffmanTable;
var tableCounter, i: Integer; seg: TJBSegmentHeader;
begin
  tableCounter := 0;
  for i := 0 to System.Length(segmentHeader.rtSegments) - 1 do
  begin
    seg := segmentHeader.rtSegments[i];
    if seg.segmentType = 53 then
    begin
      if tableCounter = tablePosition then
      begin
        Result := BuildEncodedTable(TJBTable(seg.GetSegmentData));
        Exit;
      end
      else
        Inc(tableCounter);
    end;
  end;
  Result := nil;
end;

procedure TJBTextRegion.SymbolIDCodeLengths;
var
  runCodeTable: TJBCodeArray;
  rcCount, i, prefLen: Integer;
  ht: TJBHuffmanTable;
  previousCodeLength, code, runLength, currCodeLength: Int64;
  counter, j: Integer;
  sbSymCodes: TJBCodeArray;
  scCount: Integer;

  procedure AddRC(const c: TJBCode);
  begin
    if rcCount >= System.Length(runCodeTable) then SetLength(runCodeTable, (rcCount + 8) * 2);
    runCodeTable[rcCount] := c; Inc(rcCount);
  end;
  procedure AddSC(const c: TJBCode);
  begin
    if scCount >= System.Length(sbSymCodes) then SetLength(sbSymCodes, (scCount + 8) * 2);
    sbSymCodes[scCount] := c; Inc(scCount);
  end;

begin
  rcCount := 0; SetLength(runCodeTable, 35);
  for i := 0 to 34 do
  begin
    prefLen := Integer(subInputStream.ReadBits(4) and $F);
    if prefLen > 0 then
      AddRC(MakeCode(prefLen, 0, i, False));
  end;
  SetLength(runCodeTable, rcCount);
  ht := TJBHuffmanTable.Create;
  ht.InitTree(runCodeTable);

  previousCodeLength := 0;
  counter := 0;
  scCount := 0; SetLength(sbSymCodes, 16);
  while counter < amountOfSymbols do
  begin
    code := ht.Decode(subInputStream);
    if code < 32 then
    begin
      if code > 0 then
        AddSC(MakeCode(Integer(code), 0, counter, False));
      previousCodeLength := code;
      Inc(counter);
    end
    else
    begin
      runLength := 0; currCodeLength := 0;
      if code = 32 then
      begin
        runLength := 3 + subInputStream.ReadBits(2);
        if counter > 0 then currCodeLength := previousCodeLength;
      end
      else if code = 33 then
        runLength := 3 + subInputStream.ReadBits(3)
      else if code = 34 then
        runLength := 11 + subInputStream.ReadBits(7);
      for j := 0 to Integer(runLength) - 1 do
      begin
        if currCodeLength > 0 then
          AddSC(MakeCode(Integer(currCodeLength), 0, counter, False));
        Inc(counter);
      end;
    end;
  end;

  subInputStream.SkipBits;
  SetLength(sbSymCodes, scCount);
  symbolCodeTable := TJBHuffmanTable.Create;
  symbolCodeTable.InitTree(sbSymCodes);
end;

procedure TJBTextRegion.Init(header: TJBObject; sis: TJBReader);
begin
  segmentHeader := TJBSegmentHeader(header);
  subInputStream := sis;
  regionInfo := TJBRegionInfo.CreateWith(subInputStream);
  if symbols = nil then symbols := TBitmapList.Create;
  ParseHeader;
end;

procedure TJBTextRegion.SetContexts(acx, aIADT, aIAFS, aIADS, aIAIT, aIAID, aIARDW, aIARDH, aIARDX, aIARDY: TJBCx);
begin
  cx := acx;
  cxIADT := aIADT; cxIAFS := aIAFS; cxIADS := aIADS; cxIAIT := aIAIT;
  cxIAID := aIAID;
  cxIARDW := aIARDW; cxIARDH := aIARDH; cxIARDX := aIARDX; cxIARDY := aIARDY;
end;

procedure TJBTextRegion.SetParameters(aArith: TJBArith; aIDec: TJBIntDecoder; aIsHuffman, aRefine: Boolean;
  sbw, sbh: Integer; sbNumInstances: Int64; aSbStrips, sbNumSyms, aDefaultPixel, aCombOp,
  aTransposed, aRefCorner, aSbdsOffset, aHuffFS, aHuffDS, aHuffDT, aHuffRDWidth, aHuffRDHeight,
  aHuffRDX, aHuffRDY, aHuffRSize, aSbrTemplate: Integer; aSbrATX, aSbrATY: TIntArray;
  aSbSyms: TBitmapList; aSbSymCodeLen: Integer);
begin
  arithmeticDecoder := aArith;
  integerDecoder := aIDec;
  isHuffmanEncoded := aIsHuffman;
  useRefinement := aRefine;
  regionInfo.bitmapWidth := sbw;
  regionInfo.bitmapHeight := sbh;
  amountOfSymbolInstances := sbNumInstances;
  sbStrips := aSbStrips;
  amountOfSymbols := sbNumSyms;
  defaultPixel := aDefaultPixel;
  combinationOperator := TranslateCombOp(aCombOp);
  isTransposed := aTransposed;
  referenceCorner := aRefCorner;
  sbdsOffset := aSbdsOffset;
  sbHuffFS := aHuffFS; sbHuffDS := aHuffDS; sbHuffDT := aHuffDT;
  sbHuffRDWidth := aHuffRDWidth; sbHuffRDHeight := aHuffRDHeight;
  sbHuffRDX := aHuffRDX; sbHuffRDY := aHuffRDY; sbHuffRSize := aHuffRSize;
  sbrTemplate := aSbrTemplate;
  sbrATX := aSbrATX; sbrATY := aSbrATY;
  symbols := aSbSyms;
  symbolCodeLength := aSbSymCodeLen;
end;

function TJBTextRegion.GetRegionInfo: TJBRegionInfo;
begin
  Result := regionInfo;
end;

//----------------------------------------------------------------------------
// Halftone region (7.4.5 / 6.6).
//----------------------------------------------------------------------------
procedure TJBHalftoneRegion.ComputeSegmentDataStructure;
begin
  dataOffset := subInputStream.StreamPosition;
  dataLength := subInputStream.Length_ - dataOffset;
end;

procedure TJBHalftoneRegion.ParseHeader;
begin
  regionInfo.ParseHeader;
  hDefaultPixel := subInputStream.ReadBit;
  hCombinationOperator := TranslateCombOp(Integer(subInputStream.ReadBits(3) and $F));
  if subInputStream.ReadBit = 1 then hSkipEnabled := True;
  hTemplate := Integer(subInputStream.ReadBits(2) and $F);
  if subInputStream.ReadBit = 1 then isMMREncoded := True;
  hGridWidth := subInputStream.ReadBits32(32);
  hGridHeight := subInputStream.ReadBits32(32);
  hGridX := subInputStream.ReadBits32(32);
  hGridY := subInputStream.ReadBits32(32);
  hRegionX := Integer(subInputStream.ReadBits(16) and $FFFF);
  hRegionY := Integer(subInputStream.ReadBits(16) and $FFFF);
  ComputeSegmentDataStructure;
end;

function TJBHalftoneRegion.ComputeX(m, n: Integer): Integer;
begin
  Result := ASR8(hGridX + m * hRegionY + n * hRegionX);
end;

function TJBHalftoneRegion.ComputeY(m, n: Integer): Integer;
begin
  Result := ASR8(hGridY + m * hRegionX - n * hRegionY);
end;

function TJBHalftoneRegion.ComputeHSkip(hpw, hph: Integer): TJBBitmap;
var bmp: TJBBitmap; m, n, x, y: Integer;
begin
  bmp := TJBBitmap.Create(hGridWidth, hGridHeight);
  for m := 0 to hGridHeight - 1 do
    for n := 0 to hGridWidth - 1 do
    begin
      x := ComputeX(m, n);
      y := ComputeY(m, n);
      if (x + hpw <= 0) or (x >= halftoneRegionBitmap.Width) or
         (y + hph <= 0) or (y >= halftoneRegionBitmap.Height) then
        bmp.SetPixel(n, m, 1);
    end;
  Result := bmp;
end;

function TJBHalftoneRegion.GetPatterns: TBitmapList;
var i: Integer; pd: TJBPatternDictionary;
begin
  Result := TBitmapList.Create;
  for i := 0 to System.Length(segmentHeader.rtSegments) - 1 do
  begin
    pd := TJBPatternDictionary(segmentHeader.rtSegments[i].GetSegmentData);
    Result.AddList(pd.GetDictionary);
  end;
end;

function TJBHalftoneRegion.GrayScaleDecoding(bitsPerValue: Integer; hSkip: TJBBitmap): TIntArray;
var
  gbAtX, gbAtY: TIntArray;
  grayScalePlanes: array of TJBBitmap;
  genericRegion: TJBGenericRegion;
  j, y, x, minorWidth, minorX, byteIndex, i, k, newV, oldV: Integer;
begin
  Result := nil;
  if not isMMREncoded then
  begin
    SetLength(gbAtX, 4); SetLength(gbAtY, 4);
    if hTemplate <= 1 then gbAtX[0] := 3 else gbAtX[0] := 2;
    gbAtY[0] := -1;
    gbAtX[1] := -3; gbAtY[1] := -1;
    gbAtX[2] := 2; gbAtY[2] := -2;
    gbAtX[3] := -2; gbAtY[3] := -2;
  end;

  SetLength(grayScalePlanes, bitsPerValue);
  genericRegion := TJBGenericRegion.CreateWith(subInputStream);
  genericRegion.SetParamsFull(isMMREncoded, dataOffset, dataLength, hGridHeight, hGridWidth,
    hTemplate, False, hSkipEnabled, hSkip, gbAtX, gbAtY);

  j := bitsPerValue - 1;
  grayScalePlanes[j] := genericRegion.GetRegionBitmap;
  while j > 0 do
  begin
    Dec(j);
    genericRegion.ResetBitmap;
    grayScalePlanes[j] := genericRegion.GetRegionBitmap;
    // combine plane j with j+1 via XOR (byte-wise)
    byteIndex := 0;
    for y := 0 to grayScalePlanes[j].Height - 1 do
    begin
      x := 0;
      while x < grayScalePlanes[j].Width do
      begin
        newV := grayScalePlanes[j + 1].GetByte(byteIndex);
        oldV := grayScalePlanes[j].GetByte(byteIndex);
        grayScalePlanes[j].SetByte(byteIndex, oldV xor newV);
        Inc(byteIndex);
        x := x + 8;
      end;
    end;
  end;

  // compute gray-scale values (flat array, y*hGridWidth + x)
  SetLength(Result, hGridHeight * hGridWidth);
  for y := 0 to hGridHeight - 1 do
  begin
    x := 0;
    while x < hGridWidth do
    begin
      if hGridWidth - x > 8 then minorWidth := 8 else minorWidth := hGridWidth - x;
      byteIndex := grayScalePlanes[0].GetByteIndex(x, y);
      for minorX := 0 to minorWidth - 1 do
      begin
        i := minorX + x;
        newV := 0;
        for k := 0 to bitsPerValue - 1 do
          newV := newV + ((grayScalePlanes[k].GetByte(byteIndex) shr ((7 - i) and 7)) and 1) * (1 shl k);
        Result[y * hGridWidth + i] := newV;
      end;
      x := x + 8;
    end;
  end;
end;

procedure TJBHalftoneRegion.RenderPattern(const grayScaleValues: array of TIntArray);
begin
  // Unused overload placeholder (kept for signature symmetry).
end;

function TJBHalftoneRegion.GetRegionBitmap: TJBBitmap;
var
  hSkip: TJBBitmap;
  hpw, hph, bitsPerValue, m, n, x, y, gv: Integer;
  grayScaleValues: TIntArray;
  patternBitmap: TJBBitmap;
begin
  if halftoneRegionBitmap = nil then
  begin
    halftoneRegionBitmap := TJBBitmap.Create(regionInfo.bitmapWidth, regionInfo.bitmapHeight);
    if patterns = nil then patterns := GetPatterns;
    if hDefaultPixel = 1 then halftoneRegionBitmap.FillBitmap($FF);

    hSkip := nil;
    if hSkipEnabled then
    begin
      hph := patterns.Get(0).Height;
      hpw := patterns.Get(0).Width;
      hSkip := ComputeHSkip(hpw, hph);
    end;

    bitsPerValue := CeilLog2(patterns.Count);
    grayScaleValues := GrayScaleDecoding(bitsPerValue, hSkip);

    for m := 0 to hGridHeight - 1 do
      for n := 0 to hGridWidth - 1 do
      begin
        x := ComputeX(m, n);
        y := ComputeY(m, n);
        gv := grayScaleValues[m * hGridWidth + n];
        patternBitmap := patterns.Get(gv);
        JBBlit(patternBitmap, halftoneRegionBitmap, x, y, hCombinationOperator);
      end;
  end;
  Result := halftoneRegionBitmap;
end;

function TJBHalftoneRegion.GetRegionInfo: TJBRegionInfo;
begin
  Result := regionInfo;
end;

procedure TJBHalftoneRegion.Init(header: TJBObject; sis: TJBReader);
begin
  segmentHeader := TJBSegmentHeader(header);
  subInputStream := sis;
  regionInfo := TJBRegionInfo.CreateWith(subInputStream);
  ParseHeader;
end;

//----------------------------------------------------------------------------
// Segment factory.
//----------------------------------------------------------------------------
function CreateSegmentData(segType: Integer): TJBSegmentData;
begin
  case segType of
    0: Result := TJBSymbolDictionary.Create;
    4, 6, 7: Result := TJBTextRegion.Create;
    16: Result := TJBPatternDictionary.Create;
    20, 22, 23: Result := TJBHalftoneRegion.Create;
    36, 38, 39: Result := TJBGenericRegion.Create;
    40, 42, 43: Result := TJBRefinementRegion.Create;
    48: Result := TJBPageInfo.Create;
    50: Result := TJBEndOfStripe.Create;
    52: Result := TJBProfiles.Create;
    53: Result := TJBTable.Create;
  else
    raise EJBig2.Create('No segment class for type ' + IntToStr(segType));
  end;
end;

//----------------------------------------------------------------------------
// SegmentHeader implementation.
//----------------------------------------------------------------------------
constructor TJBSegmentHeader.CreateAndParse(adoc: TJBDocument; sis: TJBReader; offset: Int64; organisationType: Integer);
begin
  inherited Create;
  subInputStream := sis;
  Parse(adoc, sis, offset, organisationType);
end;

procedure TJBSegmentHeader.Parse(adoc: TJBDocument; sis: TJBReader; offset: Int64; organisationType: Integer);
var
  retainFlag, countOfRTS, arrayLength, i, rtsSize: Integer;
  rtsNumbers: TIntArray;
  page: TJBPage;
begin
  document := adoc;
  sis.Seek(offset);
  segmentNr := sis.ReadBits32(32);

  retainFlag := sis.ReadBit;
  if retainFlag <> 0 then ; // ignored
  pageAssociationFieldSize := sis.ReadBit;
  segmentType := Integer(sis.ReadBits(6) and $FF);

  countOfRTS := Integer(sis.ReadBits(3) and $F);
  if countOfRTS <= 4 then
  begin
    for i := 0 to 4 do sis.ReadBit;
  end
  else
  begin
    countOfRTS := Integer(sis.ReadBits(29) and $FFFFFFFF);
    arrayLength := (countOfRTS + 8) shr 3;
    arrayLength := arrayLength shl 3;
    for i := 0 to arrayLength - 1 do sis.ReadBit;
  end;

  SetLength(rtsNumbers, countOfRTS);
  if countOfRTS > 0 then
  begin
    rtsSize := 1;
    if segmentNr > 256 then
    begin
      rtsSize := 2;
      if segmentNr > 65536 then rtsSize := 4;
    end;
    SetLength(rtSegments, countOfRTS);
    for i := 0 to countOfRTS - 1 do
      rtsNumbers[i] := Integer(sis.ReadBits(rtsSize shl 3) and $FFFFFFFF);
  end;

  if pageAssociationFieldSize = 0 then
    pageAssociation := Integer(sis.ReadBits(8) and $FF)
  else
    pageAssociation := Integer(sis.ReadBits(32) and $FFFFFFFF);

  if countOfRTS > 0 then
  begin
    page := document.GetPage(pageAssociation);
    for i := 0 to countOfRTS - 1 do
      if page <> nil then rtSegments[i] := page.GetSegment(rtsNumbers[i])
      else rtSegments[i] := document.GetGlobalSegment(rtsNumbers[i]);
  end;

  segmentDataLength := sis.ReadBits(32) and $FFFFFFFF;
  if organisationType = ORG_SEQUENTIAL then
    segmentDataStartOffset := sis.StreamPosition;
end;

function TJBSegmentHeader.GetDataInputStream: TJBReader;
begin
  Result := subInputStream.NewWindow(segmentDataStartOffset, segmentDataLength);
end;

function TJBSegmentHeader.GetSegmentData: TJBSegmentData;
begin
  if cachedData = nil then
  begin
    cachedData := CreateSegmentData(segmentType);
    cachedData.Init(Self, GetDataInputStream);
  end;
  Result := cachedData;
end;

//----------------------------------------------------------------------------
// Page implementation.
//----------------------------------------------------------------------------
constructor TJBPage.CreateWith(adoc: TJBDocument; apage: Integer);
begin
  inherited Create;
  document := adoc;
  pageNumber := apage;
end;

procedure TJBPage.Add(segment: TJBSegmentHeader);
begin
  if segCount >= System.Length(segments) then
    SetLength(segments, (segCount + 8) * 2);
  segments[segCount] := segment;
  Inc(segCount);
end;

procedure TJBPage.SortSegments;
var i, j: Integer; tmp: TJBSegmentHeader;
begin
  // insertion sort by segmentNr (segment counts are small)
  for i := 1 to segCount - 1 do
  begin
    tmp := segments[i];
    j := i - 1;
    while (j >= 0) and (segments[j].segmentNr > tmp.segmentNr) do
    begin
      segments[j + 1] := segments[j];
      Dec(j);
    end;
    segments[j + 1] := tmp;
  end;
end;

function TJBPage.GetSegment(number: Integer): TJBSegmentHeader;
var i: Integer;
begin
  for i := 0 to segCount - 1 do
    if segments[i].segmentNr = number then Exit(segments[i]);
  if document <> nil then Exit(document.GetGlobalSegment(number));
  Result := nil;
end;

function TJBPage.GetPageInformationSegment: TJBSegmentHeader;
var i: Integer;
begin
  for i := 0 to segCount - 1 do
    if segments[i].segmentType = 48 then Exit(segments[i]);
  Result := nil;
end;

function TJBPage.CountRegions: Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to segCount - 1 do
    case segments[i].segmentType of
      6, 7, 22, 23, 38, 39, 42, 43: Inc(Result);
    end;
end;

function TJBPage.GetCombinationOperator(pi: TJBPageInfo; newOp: Integer): Integer;
begin
  if pi.combinationOperatorOverrideAllowed then Result := newOp
  else Result := pi.combinationOperator;
end;

function TJBPage.FitsPage(pi: TJBPageInfo; regionBitmap: TJBBitmap): Boolean;
begin
  Result := (CountRegions = 1) and (pi.defaultPixelValue = 0)
    and (pi.bitmapWidth = regionBitmap.Width) and (pi.bitmapHeight = regionBitmap.Height);
end;

procedure TJBPage.CreateNormalPage(pi: TJBPageInfo);
var i, op: Integer; r: TJBRegion; regionBitmap: TJBBitmap; ri: TJBRegionInfo;
begin
  pageBitmap := TJBBitmap.Create(pi.bitmapWidth, pi.bitmapHeight);
  if pi.defaultPixelValue <> 0 then pageBitmap.FillBitmap($FF);

  for i := 0 to segCount - 1 do
  begin
    case segments[i].segmentType of
      6, 7, 22, 23, 38, 39, 42, 43:
        begin
          r := TJBRegion(segments[i].GetSegmentData);
          if r is TJBRefinementRegion then
            TJBRefinementRegion(r).SetPageBitmap(pageBitmap);
          regionBitmap := r.GetRegionBitmap;
          if FitsPage(pi, regionBitmap) then
            pageBitmap := regionBitmap
          else
          begin
            ri := r.GetRegionInfo;
            op := GetCombinationOperator(pi, ri.combinationOperator);
            JBBlit(regionBitmap, pageBitmap, ri.xLocation, ri.yLocation, op);
          end;
        end;
    end;
  end;
end;

procedure TJBPage.CreateStripedPage(pi: TJBPageInfo);
var
  i, op, startLine: Integer;
  r: TJBRegion; ri: TJBRegionInfo;
  eos: TJBEndOfStripe;
  sd: TJBSegmentData;
  stripes: array of TJBSegmentData;
  stripeCount: Integer;
begin
  // collect page stripes and compute finalHeight
  stripeCount := 0;
  SetLength(stripes, segCount);
  for i := 0 to segCount - 1 do
  begin
    case segments[i].segmentType of
      6, 7, 22, 23, 38, 39, 42, 43:
        begin
          stripes[stripeCount] := segments[i].GetSegmentData;
          Inc(stripeCount);
        end;
      50:
        begin
          eos := TJBEndOfStripe(segments[i].GetSegmentData);
          stripes[stripeCount] := eos;
          Inc(stripeCount);
          finalHeight := eos.lineNumber + 1;
        end;
    end;
  end;

  pageBitmap := TJBBitmap.Create(pi.bitmapWidth, finalHeight);
  startLine := 0;
  for i := 0 to stripeCount - 1 do
  begin
    sd := stripes[i];
    if sd is TJBEndOfStripe then
      startLine := TJBEndOfStripe(sd).lineNumber + 1
    else
    begin
      r := TJBRegion(sd);
      ri := r.GetRegionInfo;
      op := GetCombinationOperator(pi, ri.combinationOperator);
      JBBlit(r.GetRegionBitmap, pageBitmap, ri.xLocation, startLine, op);
    end;
  end;
end;

procedure TJBPage.CreatePage(pi: TJBPageInfo);
begin
  if (not pi.isStriped) or (pi.bitmapHeight <> -1) then
    CreateNormalPage(pi)
  else
    CreateStripedPage(pi);
end;

procedure TJBPage.ComposePageBitmap;
var pis: TJBSegmentHeader; pi: TJBPageInfo;
begin
  if pageNumber > 0 then
  begin
    pis := GetPageInformationSegment;
    if pis = nil then Exit;
    pi := TJBPageInfo(pis.GetSegmentData);
    CreatePage(pi);
  end;
end;

function TJBPage.GetBitmap: TJBBitmap;
begin
  if pageBitmap = nil then
  begin
    SortSegments;
    ComposePageBitmap;
  end;
  Result := pageBitmap;
end;

//----------------------------------------------------------------------------
// Document implementation.
//----------------------------------------------------------------------------
constructor TJBDocument.Create(const data, globals: TBytes);
begin
  inherited Create;
  mainReader := TJBReader.Create(data, 0, System.Length(data));
  if System.Length(globals) > 0 then
  begin
    globalsReader := TJBReader.Create(globals, 0, System.Length(globals));
    MapStream(globalsReader, True);
  end;
  MapStream(mainReader, False);
end;

function TJBDocument.GetGlobalSegment(segmentNr: Integer): TJBSegmentHeader;
var i: Integer;
begin
  for i := 0 to globalCount - 1 do
    if globalKeys[i] = segmentNr then Exit(globalVals[i]);
  Result := nil;
end;

procedure TJBDocument.AddGlobalSegment(segmentNr: Integer; seg: TJBSegmentHeader);
begin
  if globalCount >= System.Length(globalKeys) then
  begin
    SetLength(globalKeys, (globalCount + 8) * 2);
    SetLength(globalVals, (globalCount + 8) * 2);
  end;
  globalKeys[globalCount] := segmentNr;
  globalVals[globalCount] := seg;
  Inc(globalCount);
end;

function TJBDocument.GetPage(pageNumber: Integer): TJBPage;
var i: Integer;
begin
  for i := 0 to pageCount - 1 do
    if pages[i].pageNumber = pageNumber then Exit(pages[i]);
  Result := nil;
end;

function TJBDocument.GetOrCreatePage(pageNumber: Integer): TJBPage;
begin
  Result := GetPage(pageNumber);
  if Result = nil then
  begin
    Result := TJBPage.CreateWith(Self, pageNumber);
    if pageCount >= System.Length(pages) then SetLength(pages, (pageCount + 4) * 2);
    pages[pageCount] := Result;
    Inc(pageCount);
  end;
end;

function TJBDocument.IsFileHeaderPresent(reader: TJBReader): Boolean;
const MAGIC: array[0..7] of Integer = ($97, $4A, $42, $32, $0D, $0A, $1A, $0A);
var i, b: Integer;
begin
  reader.Mark;
  Result := True;
  for i := 0 to 7 do
  begin
    b := reader.ReadUByte;
    if b <> MAGIC[i] then
    begin
      Result := False;
      Break;
    end;
  end;
  reader.Reset_;
end;

function TJBDocument.ParseFileHeader(reader: TJBReader): Integer;
var amountUnknown: Boolean;
begin
  reader.Seek(0);
  reader.FPos := 8; // skip ID string
  reader.FBitOffset := 0;
  reader.ReadBits(5); // reserved
  if reader.ReadBit = 1 then gbUseExtTemplate := True;
  amountUnknown := reader.ReadBit = 1;  // bit1: 1 => amount of pages unknown
  reader.ReadBit; // organisation type (sequential assumed)
  if not amountUnknown then
  begin
    reader.ReadBits(32); // amount of pages
    Result := 13;
  end
  else
    Result := 9;
end;

function TJBDocument.ReachedEndOfStream(reader: TJBReader; offset: Int64): Boolean;
begin
  Result := offset + 4 > System.Length(reader.FData);
end;

procedure TJBDocument.MapStream(reader: TJBReader; isGlobals: Boolean);
var
  offset: Int64;
  segmentType, associatedPage: Integer;
  seg: TJBSegmentHeader;
  page: TJBPage;
begin
  offset := 0;
  segmentType := 0;
  if IsFileHeaderPresent(reader) then
    offset := ParseFileHeader(reader);

  while (segmentType <> 51) and not ReachedEndOfStream(reader, offset) do
  begin
    seg := TJBSegmentHeader.CreateAndParse(Self, reader, offset, ORG_SEQUENTIAL);
    associatedPage := seg.pageAssociation;
    segmentType := seg.segmentType;

    if isGlobals then
      AddGlobalSegment(seg.segmentNr, seg)
    else if associatedPage <> 0 then
    begin
      page := GetOrCreatePage(associatedPage);
      page.Add(seg);
    end
    else
      AddGlobalSegment(seg.segmentNr, seg);

    offset := reader.StreamPosition;
    offset := offset + seg.segmentDataLength;
  end;
end;
