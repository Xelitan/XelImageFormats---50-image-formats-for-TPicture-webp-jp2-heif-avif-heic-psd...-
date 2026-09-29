unit XelAni;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	ANI (animated cursor, RIFF ACON) codec -> RGBA8              //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Clean-room RIFF parser: collects the "icon" chunks (each a full ICO/CUR)    //
// and decodes them with XelIco.                                               //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelIco;

type
  EAniError = class(Exception);

// Liczba klatek (chunki "icon") w pliku ANI.
function AniFrameCount(InBuf: TBytes): Integer;
// Dekoduje wskazana klatke (0-based) do RGBA8.
function DecodeAniFrame(InBuf: TBytes; Index: Integer; out Width, Height: Integer): TBytes;
// Dekoduje pierwsza klatke (kompatybilnosc).
function DecodeAni(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8

implementation

function RL32(const D: TBytes; P: NativeUInt): Cardinal; inline;
begin
  Result := Cardinal(D[P]) or (Cardinal(D[P + 1]) shl 8) or
            (Cardinal(D[P + 2]) shl 16) or (Cardinal(D[P + 3]) shl 24);
end;

function Tag(const D: TBytes; P: NativeUInt; const T: AnsiString): Boolean; inline;
begin
  Result := (D[P] = Byte(T[1])) and (D[P + 1] = Byte(T[2])) and
            (D[P + 2] = Byte(T[3])) and (D[P + 3] = Byte(T[4]));
end;

type
  TOffs = array of NativeUInt;

function GatherIconOffsets(const D: TBytes): TOffs;
var
  N, pos, dataOff, sz, subEnd, sub, subData, subSz: NativeUInt;
  res: TOffs;
  n2: Integer;

  procedure Add(O: NativeUInt);
  begin
    SetLength(res, Length(res) + 1);
    res[High(res)] := O;
  end;

begin
  SetLength(res, 0);
  N := NativeUInt(Length(D));
  if (N < 12) or (not Tag(D, 0, 'RIFF')) or (not Tag(D, 8, 'ACON')) then
    raise EAniError.Create('ANI: not a RIFF ACON file');

  pos := 12;
  while pos + 8 <= N do
  begin
    sz := RL32(D, pos + 4);
    dataOff := pos + 8;
    if dataOff + sz > N then sz := N - dataOff;   // clamp

    if Tag(D, pos, 'LIST') and (sz >= 4) and Tag(D, dataOff, 'fram') then
    begin
      sub := dataOff + 4;
      subEnd := dataOff + sz;
      while sub + 8 <= subEnd do
      begin
        subSz := RL32(D, sub + 4);
        subData := sub + 8;
        if subData + subSz > N then subSz := N - subData;
        if Tag(D, sub, 'icon') then Add(subData);
        Inc(sub, 8 + subSz + (subSz and 1));   // chunks are word-aligned
      end;
    end;

    Inc(pos, 8 + sz + (sz and 1));
  end;

  n2 := Length(res);
  if n2 = 0 then raise EAniError.Create('ANI: no frames found');
  Result := res;
end;

function AniFrameCount(InBuf: TBytes): Integer;
begin
  try
    Result := Length(GatherIconOffsets(InBuf));
  except
    Result := 0;
  end;
end;

function DecodeAniFrame(InBuf: TBytes; Index: Integer; out Width, Height: Integer): TBytes;
var
  Offs: TOffs;
begin
  Width := 0; Height := 0; SetLength(Result, 0);
  Offs := GatherIconOffsets(InBuf);
  if (Index < 0) or (Index >= Length(Offs)) then raise EAniError.Create('ANI: frame index out of range');
  // each frame is a full ICO/CUR starting at Offs[Index]; take its first image
  Result := DecodeIcoDir(InBuf, Offs[Index], 0, Width, Height);
end;

function DecodeAni(InBuf: TBytes; out Width, Height: Integer): TBytes;
begin
  Result := DecodeAniFrame(InBuf, 0, Width, Height);
end;

end.
