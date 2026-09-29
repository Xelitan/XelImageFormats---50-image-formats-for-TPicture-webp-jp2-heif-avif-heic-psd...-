// JPEG 2000 based on JASPER 4.2.9
// License: JasPer-2.0 (similar to MIT )
// Author: www.xelitan.com
//
// JP2KTagTree - Tag tree coder (port of jpc_tagtree.c).
//
// Tag trees are used by tier-2 to code, in a hierarchical/embedded fashion,
// the inclusion information and zero-bit-plane counts of code-blocks within a
// precinct.  Parent links are stored as array indices (-1 = root)

unit JP2KTagTree;

{$mode delphi}
{$H+}

interface

uses
  JP2KCommon, JP2KBS;

const
  JPC_TAGTREE_MAXDEPTH = 32;

type
  TTagTreeNode = record
    Parent: Integer;   // index of parent node, or -1 for the root
    Value: Integer;
    Low: Integer;
    Known: Integer;
  end;

  TTagTree = class
  private
    FNumLeafsH: Integer;
    FNumLeafsV: Integer;
    FNumNodes: Integer;
    FNodes: array of TTagTreeNode;
  public
    constructor Create(ANumLeafsH, ANumLeafsV: Integer);
    procedure Reset;
    procedure CopyFrom(const Src: TTagTree);
    procedure SetValue(Leaf, Value: Integer);
    function GetLeaf(N: Integer): Integer; inline;   // returns node index

    function Encode(Leaf, Threshold: Integer; Out_: TBitStream): Integer;
    function Decode(Leaf, Threshold: Integer; In_: TBitStream): Integer;

    function NodeValue(N: Integer): Integer; inline;

    property NumLeafsH: Integer read FNumLeafsH;
    property NumLeafsV: Integer read FNumLeafsV;
  end;

implementation

constructor TTagTree.Create(ANumLeafsH, ANumLeafsV: Integer);
var
  nplh, nplv: array[0..JPC_TAGTREE_MAXDEPTH] of Integer;
  numlvls, n: Integer;
  i, j, k: Integer;
  node, parentnode, parentnode0: Integer;
begin
  inherited Create;
  FNumLeafsH := ANumLeafsH;
  FNumLeafsV := ANumLeafsV;
  FNumNodes := 0;

  numlvls := 0;
  nplh[0] := ANumLeafsH;
  nplv[0] := ANumLeafsV;
  repeat
    n := nplh[numlvls] * nplv[numlvls];
    nplh[numlvls + 1] := (nplh[numlvls] + 1) div 2;
    nplv[numlvls + 1] := (nplv[numlvls] + 1) div 2;
    FNumNodes := FNumNodes + n;
    Inc(numlvls);
  until n <= 1;

  SetLength(FNodes, FNumNodes);

  // Initialise the parent links.
  node := 0;
  parentnode := FNumLeafsH * FNumLeafsV;
  parentnode0 := parentnode;

  for i := 0 to numlvls - 2 do
  begin
    for j := 0 to nplv[i] - 1 do
    begin
      k := nplh[i];
      while True do
      begin
        Dec(k);
        if k < 0 then Break;
        FNodes[node].Parent := parentnode; Inc(node);
        Dec(k);
        if k >= 0 then
        begin
          FNodes[node].Parent := parentnode; Inc(node);
        end;
        Inc(parentnode);
      end;
      if ((j and 1) <> 0) or (j = nplv[i] - 1) then
        parentnode0 := parentnode
      else
      begin
        parentnode := parentnode0;
        parentnode0 := parentnode0 + nplh[i];
      end;
    end;
  end;
  FNodes[node].Parent := -1;

  Reset;
end;

procedure TTagTree.Reset;
var
  i: Integer;
begin
  for i := 0 to FNumNodes - 1 do
  begin
    FNodes[i].Value := MaxInt;
    FNodes[i].Low := 0;
    FNodes[i].Known := 0;
  end;
end;

procedure TTagTree.CopyFrom(const Src: TTagTree);
var
  i: Integer;
begin
  for i := 0 to FNumNodes - 1 do
  begin
    FNodes[i].Value := Src.FNodes[i].Value;
    FNodes[i].Low := Src.FNodes[i].Low;
    FNodes[i].Known := Src.FNodes[i].Known;
  end;
end;

procedure TTagTree.SetValue(Leaf, Value: Integer);
var
  node: Integer;
begin
  node := Leaf;
  while (node >= 0) and (FNodes[node].Value > Value) do
  begin
    FNodes[node].Value := Value;
    node := FNodes[node].Parent;
  end;
end;

function TTagTree.GetLeaf(N: Integer): Integer;
begin
  Result := N;
end;

function TTagTree.NodeValue(N: Integer): Integer;
begin
  Result := FNodes[N].Value;
end;

function TTagTree.Encode(Leaf, Threshold: Integer; Out_: TBitStream): Integer;
var
  stk: array[0..JPC_TAGTREE_MAXDEPTH - 2] of Integer;
  sp, node, low: Integer;
begin
  sp := 0;
  node := Leaf;
  while FNodes[node].Parent >= 0 do
  begin
    stk[sp] := node; Inc(sp);
    node := FNodes[node].Parent;
  end;

  low := 0;
  while True do
  begin
    if low > FNodes[node].Low then
      FNodes[node].Low := low
    else
      low := FNodes[node].Low;

    while low < Threshold do
    begin
      if low >= FNodes[node].Value then
      begin
        if FNodes[node].Known = 0 then
        begin
          if Out_.PutBit(1) = JP2K_EOF then Exit(-1);
          FNodes[node].Known := 1;
        end;
        Break;
      end;
      if Out_.PutBit(0) = JP2K_EOF then Exit(-1);
      Inc(low);
    end;
    FNodes[node].Low := low;
    if sp = 0 then Break;
    Dec(sp); node := stk[sp];
  end;

  if FNodes[Leaf].Low < Threshold then Result := 1 else Result := 0;
end;

function TTagTree.Decode(Leaf, Threshold: Integer; In_: TBitStream): Integer;
var
  stk: array[0..JPC_TAGTREE_MAXDEPTH - 2] of Integer;
  sp, node, low, ret: Integer;
begin
  sp := 0;
  node := Leaf;
  while FNodes[node].Parent >= 0 do
  begin
    stk[sp] := node; Inc(sp);
    node := FNodes[node].Parent;
  end;

  low := 0;
  while True do
  begin
    if low > FNodes[node].Low then
      FNodes[node].Low := low
    else
      low := FNodes[node].Low;
    while (low < Threshold) and (low < FNodes[node].Value) do
    begin
      ret := In_.GetBit;
      if ret < 0 then Exit(-1);
      if ret <> 0 then
        FNodes[node].Value := low
      else
        Inc(low);
    end;
    FNodes[node].Low := low;
    if sp = 0 then Break;
    Dec(sp); node := stk[sp];
  end;

  if FNodes[node].Value < Threshold then Result := 1 else Result := 0;
end;

end.
