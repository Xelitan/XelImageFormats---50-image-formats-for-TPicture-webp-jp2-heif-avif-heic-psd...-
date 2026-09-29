// JPEG 2000 based on JASPER 4.2.9
// License: JasPer-2.0 (similar to MIT )
// Author: www.xelitan.com
//
// JP2KT2 - Tier-2 packet coding (port of jpc_t2enc.c / jpc_t2dec.c)
//
// Codes packet headers using tag trees (code-block inclusion + number of
// leading insignificant bit-planes), the comma code for the Lblock adjustment,
// and the special number-of-new-passes code, followed by code-block byte
// lengths.  The packet body is the concatenation of the included code-blocks'
// tier-1 byte streams.
//
// Simplifications for the "simple" codec:
//   * single quality layer, single precinct per resolution level;
//   * each code-block forms one segment (only the last pass terminated), so a
//     packet carries exactly one length field per included code-block;
//   * no SOP/EPH markers, no packed packet headers (PPM/PPT).
//
// One packet (TT2Packet) carries all bands of one resolution level.

unit JP2KT2;

{$mode delphi}
{$H+}

interface

uses
  SysUtils, JP2KCommon, JP2KBS, JP2KTagTree;

type
  TT2Cblk = record
    NumPasses: Integer;     // coding passes (0 = not included this packet)
    NumImsbs: Integer;      // leading insignificant (all-zero) bit-planes
    DataBytes: TBytes;      // tier-1 coded bytes (encode in; decode out)
  end;

  TT2Band = record
    Present: Boolean;       // band carries data
    CblksW, CblksH: Integer;// code-block grid dimensions
    Cblks: array of TT2Cblk;// row-major, length CblksW*CblksH
  end;

  TT2Packet = record
    Bands: array of TT2Band;
  end;

// Encode one packet (header + body) to Outp.
procedure T2EncodePacket(Outp: TMemStream; const Pkt: TT2Packet);

// Decode one packet from Inp. The caller must have populated, for every band,
// Present and the code-block grid (CblksW/CblksH and the Cblks array length).
// Fills each included code-block's NumPasses, NumImsbs and DataBytes.
procedure T2DecodePacket(Inp: TMemStream; var Pkt: TT2Packet);

implementation

// ---- variable-length codes (exactly as in JasPer) ----

function PutCommaCode(bs: TBitStream; n: Integer): Integer;
begin
  while n > 0 do
  begin
    if bs.PutBit(1) = JP2K_EOF then Exit(-1);
    Dec(n);
  end;
  if bs.PutBit(0) = JP2K_EOF then Exit(-1);
  Result := 0;
end;

function GetCommaCode(bs: TBitStream): Integer;
var
  n, v: Integer;
begin
  n := 0;
  while True do
  begin
    v := bs.GetBit;
    if v < 0 then Exit(-1);
    if v = 0 then Break;
    Inc(n);
  end;
  Result := n;
end;

function PutNumNewPasses(bs: TBitStream; n: Integer): Integer;
var
  ret: Integer;
begin
  if n <= 0 then Exit(-1)
  else if n = 1 then ret := bs.PutBit(0)
  else if n = 2 then ret := bs.PutBits(2, 2)
  else if n <= 5 then ret := bs.PutBits(4, $c or (n - 3))
  else if n <= 36 then ret := bs.PutBits(9, $1e0 or (n - 6))
  else if n <= 164 then ret := bs.PutBits(16, $ff80 or (n - 37))
  else Exit(-1);
  if ret = JP2K_EOF then Result := -1 else Result := 0;
end;

function GetNumNewPasses(bs: TBitStream): Integer;
var
  n: Integer;
begin
  n := bs.GetBit;
  if n > 0 then
  begin
    n := bs.GetBit;
    if n > 0 then
    begin
      n := bs.GetBits(2);
      if n = 3 then
      begin
        n := bs.GetBits(5);
        if n = 31 then
        begin
          n := bs.GetBits(7);
          if n >= 0 then n := n + 36 + 1;
        end
        else if n >= 0 then n := n + 5 + 1;
      end
      else if n >= 0 then n := n + 2 + 1;
    end
    else if n = 0 then n := n + 2;
  end
  else if n = 0 then n := n + 1;
  Result := n;
end;

// ---- packet coding ----

procedure T2EncodePacket(Outp: TMemStream; const Pkt: TT2Packet);
var
  bs: TBitStream;
  bandno, ci, ncblks, i, numnew, datalen, adjust, lenbitsval: Integer;
  band: TT2Band;
  incltree, imsbtree: TTagTree;
  numlenbits: TIntArray;
begin
  bs := TBitStream.Create(Outp, True);
  bs.PutBit(1);                       // packet present

  for bandno := 0 to High(Pkt.Bands) do
  begin
    band := Pkt.Bands[bandno];
    if not band.Present then Continue;
    ncblks := band.CblksW * band.CblksH;
    incltree := TTagTree.Create(band.CblksW, band.CblksH);
    imsbtree := TTagTree.Create(band.CblksW, band.CblksH);
    SetLength(numlenbits, ncblks);
    for ci := 0 to ncblks - 1 do numlenbits[ci] := 3;  // Lblock initial value (ISO 15444-1)
    try
      // Seed the tag trees.
      for ci := 0 to ncblks - 1 do
        imsbtree.SetValue(imsbtree.GetLeaf(ci), band.Cblks[ci].NumImsbs);
      for ci := 0 to ncblks - 1 do
        if band.Cblks[ci].NumPasses > 0 then
          incltree.SetValue(incltree.GetLeaf(ci), 0);

      for ci := 0 to ncblks - 1 do
      begin
        incltree.Encode(incltree.GetLeaf(ci), 1, bs);     // inclusion at layer 0
        if band.Cblks[ci].NumPasses <= 0 then Continue;

        // number of leading insignificant bit-planes (incremental).
        i := 1;
        while imsbtree.Encode(imsbtree.GetLeaf(ci), i, bs) = 0 do
          Inc(i);

        numnew := band.Cblks[ci].NumPasses;
        PutNumNewPasses(bs, numnew);

        datalen := Length(band.Cblks[ci].DataBytes);
        lenbitsval := numlenbits[ci] + Integer(FloorLog2(numnew));
        adjust := IntFirstOne(datalen) + 1 - lenbitsval;
        if adjust < 0 then adjust := 0;
        PutCommaCode(bs, adjust);
        numlenbits[ci] := numlenbits[ci] + adjust;

        bs.PutBits(numlenbits[ci] + Integer(FloorLog2(numnew)), datalen);
      end;
    finally
      incltree.Free;
      imsbtree.Free;
    end;
  end;

  bs.OutAlign(0);
  bs.CloseBs;
  bs.Free;

  // Packet body: concatenated code-block byte streams.
  for bandno := 0 to High(Pkt.Bands) do
  begin
    band := Pkt.Bands[bandno];
    if not band.Present then Continue;
    ncblks := band.CblksW * band.CblksH;
    for ci := 0 to ncblks - 1 do
      if band.Cblks[ci].NumPasses > 0 then
        Outp.Write(band.Cblks[ci].DataBytes[0], Length(band.Cblks[ci].DataBytes));
  end;
end;

procedure T2DecodePacket(Inp: TMemStream; var Pkt: TT2Packet);
var
  bs: TBitStream;
  bandno, ci, ncblks, i, included, numnew, m, len, present: Integer;
  incltree, imsbtree: TTagTree;
  numlenbits: TIntArray;
  lens: array of TIntArray;     // decoded body length per band/cblk
  buf: TBytes;
begin
  SetLength(lens, Length(Pkt.Bands));

  bs := TBitStream.Create(Inp, False);
  present := bs.GetBit;
  if present > 0 then
  begin
    for bandno := 0 to High(Pkt.Bands) do
    begin
      if not Pkt.Bands[bandno].Present then Continue;
      ncblks := Pkt.Bands[bandno].CblksW * Pkt.Bands[bandno].CblksH;
      incltree := TTagTree.Create(Pkt.Bands[bandno].CblksW, Pkt.Bands[bandno].CblksH);
      imsbtree := TTagTree.Create(Pkt.Bands[bandno].CblksW, Pkt.Bands[bandno].CblksH);
      SetLength(numlenbits, ncblks);
      for ci := 0 to ncblks - 1 do numlenbits[ci] := 3;  // Lblock initial value
      SetLength(lens[bandno], ncblks);
      try
        for ci := 0 to ncblks - 1 do
        begin
          included := incltree.Decode(incltree.GetLeaf(ci), 1, bs);
          if included <= 0 then
          begin
            Pkt.Bands[bandno].Cblks[ci].NumPasses := 0;
            Continue;
          end;
          // leading insignificant bit-planes.
          i := 1;
          while imsbtree.Decode(imsbtree.GetLeaf(ci), i, bs) = 0 do
            Inc(i);
          Pkt.Bands[bandno].Cblks[ci].NumImsbs := i - 1;

          numnew := GetNumNewPasses(bs);
          Pkt.Bands[bandno].Cblks[ci].NumPasses := numnew;

          m := GetCommaCode(bs);
          numlenbits[ci] := numlenbits[ci] + m;
          len := bs.GetBits(numlenbits[ci] + Integer(FloorLog2(numnew)));
          lens[bandno][ci] := len;
        end;
      finally
        incltree.Free;
        imsbtree.Free;
      end;
    end;
    bs.InAlign(0, 0);
  end
  else
    bs.InAlign($7f, 0);
  bs.CloseBs;
  bs.Free;

  if present <= 0 then Exit;

  // Packet body.
  for bandno := 0 to High(Pkt.Bands) do
  begin
    if not Pkt.Bands[bandno].Present then Continue;
    ncblks := Pkt.Bands[bandno].CblksW * Pkt.Bands[bandno].CblksH;
    for ci := 0 to ncblks - 1 do
      if Pkt.Bands[bandno].Cblks[ci].NumPasses > 0 then
      begin
        len := lens[bandno][ci];
        SetLength(buf, len);
        if len > 0 then
          Inp.Read(buf[0], len);
        Pkt.Bands[bandno].Cblks[ci].DataBytes := Copy(buf, 0, len);
      end;
  end;
end;

end.
