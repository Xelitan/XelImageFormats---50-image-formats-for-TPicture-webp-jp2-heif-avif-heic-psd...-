// FLIF - Free Lossless Image Format -- Free Pascal port
// MANIAC: Meta-Adaptive Near-zero Integer Arithmetic Coding.
// Corresponds to: src/maniac/compound.hpp, src/maniac/compound_enc.hpp
unit flif_maniac;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  SysUtils, flif_types, flif_rac, flif_chance, flif_symbol;

type
  TPropertyDecisionNode = record
    Prop: Int8;          // -1 : leaf node, ChildID unused
    Count: Int16;
    Splitval: ColorVal;
    ChildID: Cardinal;
    LeafID: Cardinal;
  end;

  TTree = class
  public
    Nodes: array of TPropertyDecisionNode;
    constructor Create;
    function Count: Integer; inline;
    function Push: Integer;    // appends a default node, returns its index
    procedure Reset;
  end;

  TTreeArray = array of TTree;

  // Common ancestor so that the encoder/decoder can use the learning coder and
  // the final coder interchangeably (C++ uses a template parameter).
  TPropCoderBase = class
  public
    function ReadInt(const Props: Properties; Min, Max: Integer): Integer; virtual; abstract;
    function ReadIntBits(const Props: Properties; NBits: Integer): Integer; virtual; abstract;
    procedure WriteInt(const Props: Properties; Min, Max, Val: Integer); virtual; abstract;
    procedure WriteIntBits(const Props: Properties; NBits, Val: Integer); virtual; abstract;
    procedure Simplify(Divisor, MinSize, Plane: Integer); virtual; abstract;
  end;

  TPropCoderArray = array of TPropCoderBase;

  // ---------- decoding / final encoding pass ----------

  TFinalCompoundSymbolBitCoder = class(TSymbolBitCoder)
  private
    FTable: TBitChanceTable;
    FRacIn: TRacIn;
    FRacOut: TRacOut;
    FChances: PSymbolChance;
  public
    constructor Create(ATable: TBitChanceTable; ARacIn: TRacIn; ARacOut: TRacOut);
    procedure SetChances(C: PSymbolChance); inline;
    function Read(Typ: TSymbolChanceBitType; I: Integer): Boolean; override;
    procedure Write(Bit: Boolean; Typ: TSymbolChanceBitType; I: Integer); override;
  end;

  TFinalPropertySymbolCoder = class(TPropCoderBase)
  private
    FBitCoder: TFinalCompoundSymbolBitCoder;
    FTable: TBitChanceTable;
    FNbProperties: Integer;
    FLeafNode: array of TSymbolChance;
    FLeafCount: Integer;
    FTree: TTree;
    FBits: Integer;
    function FindLeaf(const Props: Properties): Integer;
  public
    constructor Create(ARacIn: TRacIn; ARacOut: TRacOut; const ARange: Ranges;
      ATree: TTree; ASplitThreshold: Integer; Cut: Integer; Alpha: Cardinal;
      ABits: Integer);
    destructor Destroy; override;
    function ReadInt(const Props: Properties; Min, Max: Integer): Integer; override;
    function ReadIntBits(const Props: Properties; NBits: Integer): Integer; override;
    procedure WriteInt(const Props: Properties; Min, Max, Val: Integer); override;
    procedure WriteIntBits(const Props: Properties; NBits, Val: Integer); override;
    procedure Simplify(Divisor, MinSize, Plane: Integer); override;
  end;

  // ---------- tree-learning pass ----------

  TVirtChancePair = record
    First: TSymbolChance;
    Second: TSymbolChance;
  end;

  TCompoundSymbolChances = record
    RealChances: TSymbolChance;
    VirtChances: array of TVirtChancePair;
    RealSize: QWord;
    VirtSize: array of QWord;
    VirtPropSum: array of Int64;
    Count: Int32;
    BestProperty: Int8;
  end;
  PCompoundSymbolChances = ^TCompoundSymbolChances;

  TSelection = array of Boolean;

  TCompoundSymbolBitCoder = class(TSymbolBitCoder)
  private
    FTable: TBitChanceTable;
    FRacIn: TRacIn;
    FRacOut: TRacOut;
    FChances: PCompoundSymbolChances;
    FSelect: ^TSelection;
    procedure UpdateChances(Typ: TSymbolChanceBitType; I: Integer; Bit: Boolean);
    function BestChance(Typ: TSymbolChanceBitType; I: Integer): PBitChance;
  public
    constructor Create(ATable: TBitChanceTable; ARacIn: TRacIn; ARacOut: TRacOut;
      ASelect: Pointer);
    procedure SetChances(C: PCompoundSymbolChances); inline;
    function Read(Typ: TSymbolChanceBitType; I: Integer): Boolean; override;
    procedure Write(Bit: Boolean; Typ: TSymbolChanceBitType; I: Integer); override;
  end;

  TPropertySymbolCoder = class(TPropCoderBase)
  private
    FBitCoder: TCompoundSymbolBitCoder;
    FTable: TBitChanceTable;
    FRange: Ranges;
    FCurrentRanges: Ranges;
    FNbProperties: Integer;
    FLeafNode: array of TCompoundSymbolChances;
    FLeafCount: Integer;
    FTree: TTree;
    FSelection: TSelection;
    FSplitThreshold: Integer;
    FBits: Integer;
    function FindLeaf(const Props: Properties): Integer;
    procedure SetSelectionAndUpdatePropertySums(const Props: Properties; Idx: Integer);
    function SimplifySubtree(Pos, Divisor, MinSize, Plane: Integer): Int64;
  public
    constructor Create(ARacIn: TRacIn; ARacOut: TRacOut; const ARange: Ranges;
      ATree: TTree; ASplitThreshold: Integer; Cut: Integer; Alpha: Cardinal;
      ABits: Integer);
    destructor Destroy; override;
    function ReadInt(const Props: Properties; Min, Max: Integer): Integer; override;
    function ReadIntBits(const Props: Properties; NBits: Integer): Integer; override;
    procedure WriteInt(const Props: Properties; Min, Max, Val: Integer); override;
    procedure WriteIntBits(const Props: Properties; NBits, Val: Integer); override;
    procedure Simplify(Divisor, MinSize, Plane: Integer); override;
  end;

  // ---------- tree (de)serialisation ----------

  TMetaPropertySymbolCoder = class
  private
    FCoder: array[0..2] of TSimpleSymbolCoder;
    FRange: Ranges;
    FNbProperties: Integer;
    function ReadSubtree(Pos: Integer; var Subrange: Ranges; Tree: TTree): Boolean;
    procedure WriteSubtree(Pos: Integer; var Subrange: Ranges; Tree: TTree);
  public
    constructor Create(ARacIn: TRacIn; ARacOut: TRacOut; const ARanges: Ranges;
      Cut: Integer = 2; Alpha: Cardinal = Cardinal($FFFFFFFF) div 19);
    destructor Destroy; override;
    function ReadTree(Tree: TTree): Boolean;
    procedure WriteTree(Tree: TTree);
  end;

implementation

// TTree

constructor TTree.Create;
begin
  inherited Create;
  Reset;
end;

procedure TTree.Reset;
begin
  SetLength(Nodes, 1);
  Nodes[0].Prop := -1;
  Nodes[0].Count := 0;
  Nodes[0].Splitval := 0;
  Nodes[0].ChildID := 0;
  Nodes[0].LeafID := 0;
end;

function TTree.Count: Integer;
begin
  Result := Length(Nodes);
end;

function TTree.Push: Integer;
begin
  Result := Length(Nodes);
  SetLength(Nodes, Result + 1);
  Nodes[Result].Prop := -1;
  Nodes[Result].Count := 0;
  Nodes[Result].Splitval := 0;
  Nodes[Result].ChildID := 0;
  Nodes[Result].LeafID := 0;
end;

// TFinalCompoundSymbolBitCoder

constructor TFinalCompoundSymbolBitCoder.Create(ATable: TBitChanceTable;
  ARacIn: TRacIn; ARacOut: TRacOut);
begin
  inherited Create;
  FTable := ATable;
  FRacIn := ARacIn;
  FRacOut := ARacOut;
end;

procedure TFinalCompoundSymbolBitCoder.SetChances(C: PSymbolChance);
begin
  FChances := C;
end;

function TFinalCompoundSymbolBitCoder.Read(Typ: TSymbolChanceBitType; I: Integer): Boolean;
var
  BC: PBitChance;
begin
  BC := SymbolChanceBit(FChances, Typ, I);
  Result := FRacIn.Read12BitChance(BC^);
  BitChancePut(BC^, Result, FTable);
end;

procedure TFinalCompoundSymbolBitCoder.Write(Bit: Boolean; Typ: TSymbolChanceBitType; I: Integer);
var
  BC: PBitChance;
begin
  BC := SymbolChanceBit(FChances, Typ, I);
  FRacOut.Write12BitChance(BC^, Bit);
  BitChancePut(BC^, Bit, FTable);
end;

// TFinalPropertySymbolCoder

constructor TFinalPropertySymbolCoder.Create(ARacIn: TRacIn; ARacOut: TRacOut;
  const ARange: Ranges; ATree: TTree; ASplitThreshold: Integer; Cut: Integer;
  Alpha: Cardinal; ABits: Integer);
begin
  inherited Create;
  FBits := ABits;
  FTable := GetBitChanceTable(Cut, Alpha);
  FBitCoder := TFinalCompoundSymbolBitCoder.Create(FTable, ARacIn, ARacOut);
  FNbProperties := Length(ARange);
  FTree := ATree;
  SetLength(FLeafNode, 16);
  FLeafCount := 1;
  InitSymbolChance(FLeafNode[0], ABits);
  FTree.Nodes[0].LeafID := 0;
end;

destructor TFinalPropertySymbolCoder.Destroy;
begin
  FBitCoder.Free;
  inherited Destroy;
end;

function TFinalPropertySymbolCoder.FindLeaf(const Props: Properties): Integer;
var
  Pos: Integer;
  OldLeaf, NewLeaf: Cardinal;
begin
  Pos := 0;
  while FTree.Nodes[Pos].Prop <> -1 do
  begin
    if FTree.Nodes[Pos].Count < 0 then
    begin
      if Props[FTree.Nodes[Pos].Prop] > FTree.Nodes[Pos].Splitval then
        Pos := FTree.Nodes[Pos].ChildID
      else
        Pos := FTree.Nodes[Pos].ChildID + 1;
    end
    else if FTree.Nodes[Pos].Count > 0 then
    begin
      Dec(FTree.Nodes[Pos].Count);
      Break;
    end
    else
    begin
      Dec(FTree.Nodes[Pos].Count);
      OldLeaf := FTree.Nodes[Pos].LeafID;
      NewLeaf := Cardinal(FLeafCount);
      if FLeafCount >= Length(FLeafNode) then
        SetLength(FLeafNode, Length(FLeafNode) * 2);
      FLeafNode[FLeafCount] := FLeafNode[OldLeaf];
      Inc(FLeafCount);
      FTree.Nodes[FTree.Nodes[Pos].ChildID].LeafID := OldLeaf;
      FTree.Nodes[FTree.Nodes[Pos].ChildID + 1].LeafID := NewLeaf;
      if Props[FTree.Nodes[Pos].Prop] > FTree.Nodes[Pos].Splitval then
        Exit(Integer(OldLeaf))
      else
        Exit(Integer(NewLeaf));
    end;
  end;
  Result := Integer(FTree.Nodes[Pos].LeafID);
end;

// NOTE: FindLeaf can grow (and therefore reallocate) FLeafNode, so its result
// must be stored before the element address is taken.
function TFinalPropertySymbolCoder.ReadInt(const Props: Properties; Min, Max: Integer): Integer;
var
  Idx: Integer;
begin
  if Min = Max then Exit(Min);
  Idx := FindLeaf(Props);
  FBitCoder.SetChances(@FLeafNode[Idx]);
  Result := ReaderMinMax(FBitCoder, Min, Max);
end;

function TFinalPropertySymbolCoder.ReadIntBits(const Props: Properties; NBits: Integer): Integer;
var
  Idx: Integer;
begin
  Idx := FindLeaf(Props);
  FBitCoder.SetChances(@FLeafNode[Idx]);
  Result := ReaderNBits(FBitCoder, NBits);
end;

procedure TFinalPropertySymbolCoder.WriteInt(const Props: Properties; Min, Max, Val: Integer);
var
  Idx: Integer;
begin
  if Min = Max then Exit;
  Idx := FindLeaf(Props);
  FBitCoder.SetChances(@FLeafNode[Idx]);
  WriterMinMax(FBitCoder, Min, Max, Val);
end;

procedure TFinalPropertySymbolCoder.WriteIntBits(const Props: Properties; NBits, Val: Integer);
var
  Idx: Integer;
begin
  Idx := FindLeaf(Props);
  FBitCoder.SetChances(@FLeafNode[Idx]);
  WriterNBits(FBitCoder, NBits, Val);
end;

procedure TFinalPropertySymbolCoder.Simplify(Divisor, MinSize, Plane: Integer);
begin
  // no-op, as in the reference
end;

// TCompoundSymbolBitCoder

constructor TCompoundSymbolBitCoder.Create(ATable: TBitChanceTable; ARacIn: TRacIn;
  ARacOut: TRacOut; ASelect: Pointer);
begin
  inherited Create;
  FTable := ATable;
  FRacIn := ARacIn;
  FRacOut := ARacOut;
  FSelect := ASelect;
end;

procedure TCompoundSymbolBitCoder.SetChances(C: PCompoundSymbolChances);
begin
  FChances := C;
end;

procedure TCompoundSymbolBitCoder.UpdateChances(Typ: TSymbolChanceBitType; I: Integer;
  Bit: Boolean);
var
  Real_: PBitChance;
  Virt: PBitChance;
  J: Integer;
  BestProperty: Int8;
  BestSize: QWord;
begin
  Real_ := SymbolChanceBit(@FChances^.RealChances, Typ, I);
  BitChanceEstim(Real_^, Bit, FChances^.RealSize);
  BitChancePut(Real_^, Bit, FTable);

  BestProperty := -1;
  BestSize := FChances^.RealSize;
  for J := 0 to Length(FChances^.VirtChances) - 1 do
  begin
    if FSelect^[J] then
      Virt := SymbolChanceBit(@FChances^.VirtChances[J].First, Typ, I)
    else
      Virt := SymbolChanceBit(@FChances^.VirtChances[J].Second, Typ, I);
    BitChanceEstim(Virt^, Bit, FChances^.VirtSize[J]);
    BitChancePut(Virt^, Bit, FTable);
    if FChances^.VirtSize[J] < BestSize then
    begin
      BestSize := FChances^.VirtSize[J];
      BestProperty := Int8(J);
    end;
  end;
  FChances^.BestProperty := BestProperty;
end;

function TCompoundSymbolBitCoder.BestChance(Typ: TSymbolChanceBitType; I: Integer): PBitChance;
var
  P: Integer;
begin
  P := FChances^.BestProperty;
  if P = -1 then
    Result := SymbolChanceBit(@FChances^.RealChances, Typ, I)
  else if FSelect^[P] then
    Result := SymbolChanceBit(@FChances^.VirtChances[P].First, Typ, I)
  else
    Result := SymbolChanceBit(@FChances^.VirtChances[P].Second, Typ, I);
end;

function TCompoundSymbolBitCoder.Read(Typ: TSymbolChanceBitType; I: Integer): Boolean;
var
  Ch: PBitChance;
begin
  Ch := BestChance(Typ, I);
  Result := FRacIn.Read12BitChance(Ch^);
  UpdateChances(Typ, I, Result);
end;

procedure TCompoundSymbolBitCoder.Write(Bit: Boolean; Typ: TSymbolChanceBitType; I: Integer);
var
  Ch: PBitChance;
begin
  Ch := BestChance(Typ, I);
  FRacOut.Write12BitChance(Ch^, Bit);
  UpdateChances(Typ, I, Bit);
end;

// TPropertySymbolCoder

procedure InitCompoundSymbolChances(var C: TCompoundSymbolChances; NProp, Bits: Integer);
var
  I: Integer;
begin
  InitSymbolChance(C.RealChances, Bits);
  SetLength(C.VirtChances, NProp);
  for I := 0 to NProp - 1 do
  begin
    InitSymbolChance(C.VirtChances[I].First, Bits);
    InitSymbolChance(C.VirtChances[I].Second, Bits);
  end;
  C.RealSize := 0;
  SetLength(C.VirtSize, NProp);
  SetLength(C.VirtPropSum, NProp);
  for I := 0 to NProp - 1 do
  begin
    C.VirtSize[I] := 0;
    C.VirtPropSum[I] := 0;
  end;
  C.Count := 0;
  C.BestProperty := -1;
end;

procedure CopyCompoundSymbolChances(const Src: TCompoundSymbolChances;
  var Dst: TCompoundSymbolChances);
begin
  Dst.RealChances := Src.RealChances;
  Dst.VirtChances := Copy(Src.VirtChances);
  Dst.RealSize := Src.RealSize;
  Dst.VirtSize := Copy(Src.VirtSize);
  Dst.VirtPropSum := Copy(Src.VirtPropSum);
  Dst.Count := Src.Count;
  Dst.BestProperty := Src.BestProperty;
end;

procedure ResetCounters(var C: TCompoundSymbolChances);
var
  I: Integer;
begin
  C.BestProperty := -1;
  C.RealSize := 0;
  C.Count := 0;
  for I := 0 to Length(C.VirtPropSum) - 1 do C.VirtPropSum[I] := 0;
  for I := 0 to Length(C.VirtSize) - 1 do C.VirtSize[I] := 0;
end;

function DivDown(Sum: Int64; Cnt: Int32): ColorVal; inline;
begin
  if Sum >= 0 then
    Result := ColorVal(Sum div Cnt)
  else
    Result := ColorVal(-((-Sum + Cnt - 1) div Cnt));
end;

constructor TPropertySymbolCoder.Create(ARacIn: TRacIn; ARacOut: TRacOut;
  const ARange: Ranges; ATree: TTree; ASplitThreshold: Integer; Cut: Integer;
  Alpha: Cardinal; ABits: Integer);
begin
  inherited Create;
  FBits := ABits;
  FTable := GetBitChanceTable(Cut, Alpha);
  FRange := Copy(ARange);
  SetLength(FCurrentRanges, Length(ARange));
  FNbProperties := Length(FRange);
  FTree := ATree;
  SetLength(FSelection, FNbProperties);
  FSplitThreshold := ASplitThreshold;
  FBitCoder := TCompoundSymbolBitCoder.Create(FTable, ARacIn, ARacOut, @FSelection);
  SetLength(FLeafNode, 16);
  FLeafCount := 1;
  InitCompoundSymbolChances(FLeafNode[0], FNbProperties, ABits);
end;

destructor TPropertySymbolCoder.Destroy;
begin
  FBitCoder.Free;
  inherited Destroy;
end;

function TPropertySymbolCoder.FindLeaf(const Props: Properties): Integer;
var
  Pos: Cardinal;
  I, P: Integer;
  Splitval: ColorVal;
  NewInner, NewLeaf, OldLeaf: Cardinal;
begin
  Pos := 0;
  for I := 0 to FNbProperties - 1 do
    FCurrentRanges[I] := FRange[I];
  while FTree.Nodes[Pos].Prop <> -1 do
  begin
    if Props[FTree.Nodes[Pos].Prop] > FTree.Nodes[Pos].Splitval then
    begin
      FCurrentRanges[FTree.Nodes[Pos].Prop].First := FTree.Nodes[Pos].Splitval + 1;
      Pos := FTree.Nodes[Pos].ChildID;
    end
    else
    begin
      FCurrentRanges[FTree.Nodes[Pos].Prop].Second := FTree.Nodes[Pos].Splitval;
      Pos := FTree.Nodes[Pos].ChildID + 1;
    end;
  end;
  Result := Integer(FTree.Nodes[Pos].LeafID);

  // split leaf node if some virtual context is performing significantly better
  if (FLeafNode[Result].BestProperty <> -1) and
     (FLeafNode[Result].RealSize > FLeafNode[Result].VirtSize[FLeafNode[Result].BestProperty]
        + QWord(FSplitThreshold)) and
     (FCurrentRanges[FLeafNode[Result].BestProperty].First <
      FCurrentRanges[FLeafNode[Result].BestProperty].Second) then
  begin
    P := FLeafNode[Result].BestProperty;
    Splitval := DivDown(FLeafNode[Result].VirtPropSum[P], FLeafNode[Result].Count);
    if Splitval >= FCurrentRanges[P].Second then
      Splitval := FCurrentRanges[P].Second - 1;

    NewInner := Cardinal(FTree.Count);
    SetLength(FTree.Nodes, FTree.Count + 2);
    FTree.Nodes[NewInner] := FTree.Nodes[Pos];
    FTree.Nodes[NewInner + 1] := FTree.Nodes[Pos];
    FTree.Nodes[Pos].Splitval := Splitval;
    FTree.Nodes[Pos].Prop := Int8(P);
    if FLeafNode[Result].Count < 32767 then
      FTree.Nodes[Pos].Count := Int16(FLeafNode[Result].Count)
    else
      FTree.Nodes[Pos].Count := 32767;
    NewLeaf := Cardinal(FLeafCount);
    ResetCounters(FLeafNode[Result]);
    if FLeafCount >= Length(FLeafNode) then
      SetLength(FLeafNode, Length(FLeafNode) * 2);
    CopyCompoundSymbolChances(FLeafNode[Result], FLeafNode[FLeafCount]);
    Inc(FLeafCount);
    OldLeaf := FTree.Nodes[Pos].LeafID;
    FTree.Nodes[Pos].ChildID := NewInner;
    FTree.Nodes[NewInner].LeafID := OldLeaf;
    FTree.Nodes[NewInner + 1].LeafID := NewLeaf;
    if Props[P] > FTree.Nodes[Pos].Splitval then
      Result := Integer(OldLeaf)
    else
      Result := Integer(NewLeaf);
  end;
end;

procedure TPropertySymbolCoder.SetSelectionAndUpdatePropertySums(const Props: Properties;
  Idx: Integer);
var
  I: Integer;
  Splitval: ColorVal;
begin
  Inc(FLeafNode[Idx].Count);
  for I := 0 to FNbProperties - 1 do
  begin
    FLeafNode[Idx].VirtPropSum[I] := FLeafNode[Idx].VirtPropSum[I] + Props[I];
    Splitval := DivDown(FLeafNode[Idx].VirtPropSum[I], FLeafNode[Idx].Count);
    FSelection[I] := Props[I] > Splitval;
  end;
end;

function TPropertySymbolCoder.ReadInt(const Props: Properties; Min, Max: Integer): Integer;
var
  Idx: Integer;
begin
  Idx := FindLeaf(Props);
  SetSelectionAndUpdatePropertySums(Props, Idx);
  Idx := FindLeaf(Props);
  if Min = Max then Exit(Min);
  FBitCoder.SetChances(@FLeafNode[Idx]);
  Result := ReaderMinMax(FBitCoder, Min, Max);
end;

function TPropertySymbolCoder.ReadIntBits(const Props: Properties; NBits: Integer): Integer;
var
  Idx: Integer;
begin
  Idx := FindLeaf(Props);
  SetSelectionAndUpdatePropertySums(Props, Idx);
  Idx := FindLeaf(Props);
  FBitCoder.SetChances(@FLeafNode[Idx]);
  Result := ReaderNBits(FBitCoder, NBits);
end;

procedure TPropertySymbolCoder.WriteInt(const Props: Properties; Min, Max, Val: Integer);
var
  Idx: Integer;
begin
  Idx := FindLeaf(Props);
  SetSelectionAndUpdatePropertySums(Props, Idx);
  Idx := FindLeaf(Props);
  if Min = Max then Exit;
  FBitCoder.SetChances(@FLeafNode[Idx]);
  WriterMinMax(FBitCoder, Min, Max, Val);
end;

procedure TPropertySymbolCoder.WriteIntBits(const Props: Properties; NBits, Val: Integer);
var
  Idx: Integer;
begin
  Idx := FindLeaf(Props);
  SetSelectionAndUpdatePropertySums(Props, Idx);
  Idx := FindLeaf(Props);
  FBitCoder.SetChances(@FLeafNode[Idx]);
  WriterNBits(FBitCoder, NBits, Val);
end;

function TPropertySymbolCoder.SimplifySubtree(Pos, Divisor, MinSize, Plane: Integer): Int64;
var
  SubtreeSize: Int64;
begin
  if FTree.Nodes[Pos].Prop = -1 then
  begin
    if FLeafNode[FTree.Nodes[Pos].LeafID].Count = 0 then Exit(-100);
    Result := FLeafNode[FTree.Nodes[Pos].LeafID].Count;
  end
  else
  begin
    SubtreeSize := 0;
    SubtreeSize := SubtreeSize + SimplifySubtree(FTree.Nodes[Pos].ChildID, Divisor, MinSize, Plane);
    SubtreeSize := SubtreeSize + SimplifySubtree(FTree.Nodes[Pos].ChildID + 1, Divisor, MinSize, Plane);
    if Divisor <> 0 then
      FTree.Nodes[Pos].Count := Int16(FTree.Nodes[Pos].Count div Divisor);
    if FTree.Nodes[Pos].Count > CONTEXT_TREE_MAX_COUNT then
      FTree.Nodes[Pos].Count := CONTEXT_TREE_MAX_COUNT;
    if FTree.Nodes[Pos].Count < CONTEXT_TREE_MIN_COUNT then
      FTree.Nodes[Pos].Count := CONTEXT_TREE_MIN_COUNT;
    if FTree.Nodes[Pos].Count > $F then
      FTree.Nodes[Pos].Count := Int16(FTree.Nodes[Pos].Count and $FFF8);
    if SubtreeSize < MinSize then
      FTree.Nodes[Pos].Prop := -1;
    Result := SubtreeSize;
  end;
end;

procedure TPropertySymbolCoder.Simplify(Divisor, MinSize, Plane: Integer);
begin
  SimplifySubtree(0, Divisor, MinSize, Plane);
end;

// TMetaPropertySymbolCoder

constructor TMetaPropertySymbolCoder.Create(ARacIn: TRacIn; ARacOut: TRacOut;
  const ARanges: Ranges; Cut: Integer; Alpha: Cardinal);
var
  I: Integer;
begin
  inherited Create;
  for I := 0 to 2 do
    FCoder[I] := TSimpleSymbolCoder.Create(ARacIn, ARacOut, 18, Cut, Alpha);
  FRange := Copy(ARanges);
  FNbProperties := Length(ARanges);
end;

destructor TMetaPropertySymbolCoder.Destroy;
var
  I: Integer;
begin
  for I := 0 to 2 do FCoder[I].Free;
  inherited Destroy;
end;

function TMetaPropertySymbolCoder.ReadSubtree(Pos: Integer; var Subrange: Ranges;
  Tree: TTree): Boolean;
var
  P, OldMin, OldMax, Splitval, ChildID: Integer;
begin
  P := FCoder[0].ReadInt2(0, FNbProperties) - 1;
  Tree.Nodes[Pos].Prop := Int8(P);
  if P <> -1 then
  begin
    if (P < 0) or (P >= FNbProperties) then
    begin
      e_printf('Invalid tree. Aborting tree decoding.'#10);
      Exit(False);
    end;
    OldMin := Subrange[P].First;
    OldMax := Subrange[P].Second;
    if OldMin >= OldMax then
    begin
      e_printf('Invalid tree. Aborting tree decoding.'#10);
      Exit(False);
    end;
    Tree.Nodes[Pos].Count := Int16(FCoder[1].ReadInt2(CONTEXT_TREE_MIN_COUNT, CONTEXT_TREE_MAX_COUNT));
    Splitval := FCoder[2].ReadInt2(OldMin, OldMax - 1);
    Tree.Nodes[Pos].Splitval := Splitval;
    ChildID := Tree.Count;
    Tree.Nodes[Pos].ChildID := Cardinal(ChildID);
    Tree.Push;
    Tree.Push;
    // > splitval
    Subrange[P].First := Splitval + 1;
    if not ReadSubtree(ChildID, Subrange, Tree) then Exit(False);
    // <= splitval
    Subrange[P].First := OldMin;
    Subrange[P].Second := Splitval;
    if not ReadSubtree(ChildID + 1, Subrange, Tree) then Exit(False);
    Subrange[P].Second := OldMax;
  end;
  Result := True;
end;

function TMetaPropertySymbolCoder.ReadTree(Tree: TTree): Boolean;
var
  RootRange: Ranges;
begin
  RootRange := Copy(FRange);
  Tree.Reset;
  Result := ReadSubtree(0, RootRange, Tree);
  if Result then
    v_printf(6, Format('Read MANIAC tree with %d inner nodes.'#10, [Tree.Count]));
end;

procedure TMetaPropertySymbolCoder.WriteSubtree(Pos: Integer; var Subrange: Ranges;
  Tree: TTree);
var
  P, OldMin, OldMax: Integer;
begin
  P := Tree.Nodes[Pos].Prop;
  FCoder[0].WriteInt2(0, FNbProperties, P + 1);
  if P <> -1 then
  begin
    FCoder[1].WriteInt2(CONTEXT_TREE_MIN_COUNT, CONTEXT_TREE_MAX_COUNT, Tree.Nodes[Pos].Count);
    OldMin := Subrange[P].First;
    OldMax := Subrange[P].Second;
    FCoder[2].WriteInt2(OldMin, OldMax - 1, Tree.Nodes[Pos].Splitval);
    Subrange[P].First := Tree.Nodes[Pos].Splitval + 1;
    WriteSubtree(Tree.Nodes[Pos].ChildID, Subrange, Tree);
    Subrange[P].First := OldMin;
    Subrange[P].Second := Tree.Nodes[Pos].Splitval;
    WriteSubtree(Tree.Nodes[Pos].ChildID + 1, Subrange, Tree);
    Subrange[P].Second := OldMax;
  end;
end;

procedure TMetaPropertySymbolCoder.WriteTree(Tree: TTree);
var
  RootRange: Ranges;
begin
  RootRange := Copy(FRange);
  WriteSubtree(0, RootRange, Tree);
end;

end.
