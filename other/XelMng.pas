unit XelMng;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	MNG (Multiple-image Network Graphics) decoder -> RGBA8       //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Clean-room implementation of the commonly used MNG subset: MHDR canvas,     //
// embedded PNG (IHDR..IEND, global PLTE/tRNS) and JNG (JHDR..IEND) images,   //
// DEFI objects (id, do_not_show, location), SHOW and MOVE, mandatory BACK,    //
// FRAM framing modes 1-4 with inter-frame delays (a zero delay merges        //
// subframes into one visible frame). Delta-PNG (DHDR), LOOP repetition and   //
// the remaining object chunks (CLON, PAST, ...) are not interpreted.          //
// Frames are produced by replaying the stream; object images are decoded     //
// lazily and cached.                                                          //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes, XelPng, XelJng;

type
  EMngError = class(Exception);

function MngFrameCount(InBuf: TBytes): Integer;
function DecodeMngFrame(InBuf: TBytes; Index: Integer; out Width, Height: Integer): TBytes;
function DecodeMng(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8, frame 0

implementation

type
  TMngObj = record
    Id: Integer;
    Src: TBytes;          // standalone PNG, or nil for JNG
    JngOff: NativeUInt;   // offset of JHDR when IsJng
    IsJng: Boolean;
    Img: TBytes;
    IW, IH: Integer;
    Decoded: Boolean;
    X, Y: Integer;
    Visible: Boolean;
  end;

function RB32(const D: TBytes; P: NativeUInt): Cardinal; inline;
begin
  Result := (Cardinal(D[P]) shl 24) or (Cardinal(D[P + 1]) shl 16) or
            (Cardinal(D[P + 2]) shl 8) or Cardinal(D[P + 3]);
end;

function RB16(const D: TBytes; P: NativeUInt): Integer; inline;
begin
  Result := (Integer(D[P]) shl 8) or D[P + 1];
end;

function IsType(const D: TBytes; P: NativeUInt; const T: AnsiString): Boolean; inline;
begin
  Result := (D[P] = Byte(T[1])) and (D[P + 1] = Byte(T[2])) and
            (D[P + 2] = Byte(T[3])) and (D[P + 3] = Byte(T[4]));
end;

procedure AppendRaw(var Dest: TBytes; const Src: TBytes; Off, Len: NativeUInt);
var
  p: NativeUInt;
begin
  if Len = 0 then Exit;
  p := Length(Dest);
  SetLength(Dest, p + Len);
  Move(Src[Off], Dest[p], Len);
end;

// Composite Img (IW x IH, straight alpha) onto Canvas (CW x CH) at (X, Y).
procedure Blend(var Canvas: TBytes; CW, CH: Integer; const Img: TBytes; IW, IH, X, Y: Integer);
var
  ix, iy, cx, cy, s, d, a, ia, oa: Integer;
begin
  if Length(Img) < IW * IH * 4 then Exit;
  for iy := 0 to IH - 1 do
  begin
    cy := Y + iy;
    if (cy < 0) or (cy >= CH) then Continue;
    for ix := 0 to IW - 1 do
    begin
      cx := X + ix;
      if (cx < 0) or (cx >= CW) then Continue;
      s := (iy * IW + ix) * 4;
      d := (cy * CW + cx) * 4;
      a := Img[s + 3];
      if a = 255 then
      begin
        Canvas[d] := Img[s]; Canvas[d + 1] := Img[s + 1]; Canvas[d + 2] := Img[s + 2]; Canvas[d + 3] := 255;
      end
      else if a > 0 then
      begin
        ia := 255 - a;
        oa := a + (Canvas[d + 3] * ia + 127) div 255;       // resulting alpha
        if oa > 0 then
        begin
          Canvas[d]     := Byte((Img[s] * a * 255 + Canvas[d] * Canvas[d + 3] * ia + oa * 127) div (oa * 255));
          Canvas[d + 1] := Byte((Img[s + 1] * a * 255 + Canvas[d + 1] * Canvas[d + 3] * ia + oa * 127) div (oa * 255));
          Canvas[d + 2] := Byte((Img[s + 2] * a * 255 + Canvas[d + 2] * Canvas[d + 3] * ia + oa * 127) div (oa * 255));
        end;
        Canvas[d + 3] := Byte(oa);
      end;
    end;
  end;
end;

// Replays the stream. With StopAt >= 0 returns the canvas of that frame; with
// StopAt < 0 images are not decoded and only frames are counted.
function Play(const D: TBytes; StopAt: Integer; out Frames, CW, CH: Integer): TBytes;
var
  N, pos, len, dat, endOff, p2: NativeUInt;
  Canvas, GlobalPLTE, GlobalTRNS, Png: TBytes;
  Bg: array[0..2] of Byte;
  Objs: array of TMngObj;
  Cur: TMngObj;
  Mode, Layers, CurId, CurX, CurY, DefaultDelay, NextDelay, i, k, first, last, smode: Integer;
  CurHidden, HasPLTE, HasTRNS, BgSet, Counting, Done: Boolean;
  ColorType: Byte;

  procedure ClearCanvas;
  var j: Integer;
  begin
    if Counting then Exit;
    j := 0;
    while j < Length(Canvas) do
    begin
      if BgSet then begin Canvas[j] := Bg[0]; Canvas[j + 1] := Bg[1]; Canvas[j + 2] := Bg[2]; Canvas[j + 3] := 255; end
      else begin Canvas[j] := 0; Canvas[j + 1] := 0; Canvas[j + 2] := 0; Canvas[j + 3] := 0; end;
      Inc(j, 4);
    end;
  end;

  function FindObj(Id: Integer): Integer;
  var j: Integer;
  begin
    for j := 0 to High(Objs) do if Objs[j].Id = Id then Exit(j);
    Result := -1;
  end;

  procedure EnsureDecoded(var O: TMngObj);
  var e: NativeUInt;
  begin
    if O.Decoded or Counting then Exit;
    O.Decoded := True;
    try
      if O.IsJng then O.Img := DecodeJngChunks(D, O.JngOff, O.IW, O.IH, e)
      else O.Img := DecodePng(O.Src, O.IW, O.IH);
    except
      O.Img := nil; O.IW := 0; O.IH := 0;
    end;
    O.Src := nil;
  end;

  // frame boundary: returns True when the requested frame is complete
  function EmitFrame: Boolean;
  begin
    Inc(Frames);
    Layers := 0;
    NextDelay := -1;
    Result := (StopAt >= 0) and (Frames - 1 = StopAt);
  end;

  function CurrentDelay: Integer;
  begin
    if NextDelay >= 0 then Result := NextDelay else Result := DefaultDelay;
  end;

  // display one object as a foreground layer
  function DisplayLayer(var O: TMngObj): Boolean;
  begin
    Result := False;
    if Mode = 3 then ClearCanvas;
    if not Counting then
    begin
      EnsureDecoded(O);
      Blend(Canvas, CW, CH, O.Img, O.IW, O.IH, O.X, O.Y);
    end;
    Inc(Layers);
    // modes 1 and 3: the inter-frame delay follows every layer; a zero delay
    // merges the layer into the next visible frame
    if ((Mode = 1) or (Mode = 3)) and (CurrentDelay > 0) then Result := EmitFrame;
  end;

  // read an embedded image starting at pos; fills Cur and advances pos
  procedure ReadImage(IsJng: Boolean);
  begin
    Cur.Id := CurId; Cur.X := CurX; Cur.Y := CurY; Cur.Visible := not CurHidden;
    Cur.Img := nil; Cur.IW := 0; Cur.IH := 0; Cur.Decoded := False;
    Cur.IsJng := IsJng; Cur.JngOff := pos; Cur.Src := nil;
    if not IsJng then
    begin
      ColorType := D[pos + 8 + 9];
      HasPLTE := False; HasTRNS := False;
      Png := nil;
      if not Counting then
      begin
        SetLength(Png, 8);
        Png[0] := $89; Png[1] := Ord('P'); Png[2] := Ord('N'); Png[3] := Ord('G');
        Png[4] := 13; Png[5] := 10; Png[6] := 26; Png[7] := 10;
      end;
    end;
    while pos + 12 <= N do
    begin
      len := RB32(D, pos);
      if pos + 12 + len > N then begin pos := N; Break; end;
      if not (IsJng or Counting) then
      begin
        if IsType(D, pos + 4, 'PLTE') then
        begin
          if len > 0 then begin HasPLTE := True; AppendRaw(Png, D, pos, len + 12); end;
        end
        else if IsType(D, pos + 4, 'tRNS') then
        begin
          if len > 0 then begin HasTRNS := True; AppendRaw(Png, D, pos, len + 12); end;
        end
        else
        begin
          if IsType(D, pos + 4, 'IDAT') and (ColorType = 3) and not HasPLTE and (Length(GlobalPLTE) > 0) then
          begin
            AppendRaw(Png, GlobalPLTE, 0, Length(GlobalPLTE)); HasPLTE := True;
            if (not HasTRNS) and (Length(GlobalTRNS) > 0) then
            begin AppendRaw(Png, GlobalTRNS, 0, Length(GlobalTRNS)); HasTRNS := True; end;
          end;
          AppendRaw(Png, D, pos, len + 12);
        end;
      end;
      p2 := pos;
      pos := pos + 12 + len;
      if IsType(D, p2 + 4, 'IEND') then Break;
    end;
    Cur.Src := Png;
  end;

begin
  Result := nil; Frames := 0; CW := 0; CH := 0;
  N := NativeUInt(Length(D));
  if (N < 8) or (D[0] <> $8A) or (D[1] <> Ord('M')) or (D[2] <> Ord('N')) or (D[3] <> Ord('G')) then
    raise EMngError.Create('MNG: bad signature');
  Counting := StopAt < 0;
  pos := 8;
  Mode := 1; Layers := 0; DefaultDelay := 1; NextDelay := -1;
  CurId := 0; CurX := 0; CurY := 0; CurHidden := False; BgSet := False;
  GlobalPLTE := nil; GlobalTRNS := nil;
  SetLength(Objs, 0);
  Done := False;

  while (pos + 12 <= N) and not Done do
  begin
    len := RB32(D, pos);
    dat := pos + 8;
    if dat + len + 4 > N then Break;

    if IsType(D, pos + 4, 'MHDR') then
    begin
      CW := Integer(RB32(D, dat)); CH := Integer(RB32(D, dat + 4));
      if (CW <= 0) or (CH <= 0) or (CW > 32768) or (CH > 32768) then raise EMngError.Create('MNG: invalid frame size');
      if not Counting then begin SetLength(Canvas, NativeInt(CW) * CH * 4); ClearCanvas; end;
    end
    else if IsType(D, pos + 4, 'BACK') and (len >= 6) then
    begin
      // only a mandatory background is painted; an advisory one (the default)
      // leaves the canvas transparent for the host application to fill
      Bg[0] := D[dat]; Bg[1] := D[dat + 2]; Bg[2] := D[dat + 4];    // high bytes of 16-bit samples
      BgSet := (len >= 7) and ((D[dat + 6] and 1) = 1);
      if (Frames = 0) and (Layers = 0) then ClearCanvas;
    end
    else if IsType(D, pos + 4, 'DEFI') and (len >= 2) then
    begin
      CurId := RB16(D, dat);
      CurHidden := (len >= 3) and (D[dat + 2] = 1);
      if len >= 12 then begin CurX := Integer(RB32(D, dat + 4)); CurY := Integer(RB32(D, dat + 8)); end
      else begin CurX := 0; CurY := 0; end;
    end
    else if IsType(D, pos + 4, 'FRAM') then
    begin
      // modes 2/4: the layers since the previous FRAM form one frame
      if ((Mode = 2) or (Mode = 4)) and (Layers > 0) and (CurrentDelay > 0) then
        if EmitFrame then begin Result := Canvas; Exit; end;
      if (len >= 1) and (D[dat] >= 1) and (D[dat] <= 4) then Mode := D[dat];
      if len > 1 then
      begin
        // skip the subframe name up to its NUL separator, then the change flags
        k := 1;
        while (NativeUInt(k) < len) and (D[dat + NativeUInt(k)] <> 0) do Inc(k);
        Inc(k);                                   // separator
        if NativeUInt(k) + 4 <= len then
        begin
          i := D[dat + NativeUInt(k)];            // change_interframe_delay
          if (i <> 0) and (NativeUInt(k) + 8 <= len) then
          begin
            if i = 2 then DefaultDelay := Integer(RB32(D, dat + NativeUInt(k) + 4))
            else NextDelay := Integer(RB32(D, dat + NativeUInt(k) + 4));
          end;
        end;
      end;
      if Mode = 4 then ClearCanvas;
    end
    else if IsType(D, pos + 4, 'SHOW') then
    begin
      if len >= 2 then first := RB16(D, dat) else first := 1;
      if len >= 4 then last := RB16(D, dat + 2) else last := first;
      if len >= 5 then smode := D[dat + 4] else smode := 0;
      if last < first then begin k := first; first := last; last := k; end;
      for k := 0 to High(Objs) do
        if (Objs[k].Id >= first) and (Objs[k].Id <= last) then
        begin
          case smode of
            1: Objs[k].Visible := False;
            2, 3, 4, 5: ;                                   // keep visibility
          else Objs[k].Visible := True;
          end;
          if Objs[k].Visible and (smode <> 1) then
            if DisplayLayer(Objs[k]) then begin Result := Canvas; Exit; end;
        end;
    end
    else if IsType(D, pos + 4, 'MOVE') and (len >= 13) then
    begin
      first := RB16(D, dat); last := RB16(D, dat + 2);
      for k := 0 to High(Objs) do
        if (Objs[k].Id >= first) and (Objs[k].Id <= last) then
          if D[dat + 4] = 0 then
          begin
            Objs[k].X := Integer(RB32(D, dat + 5)); Objs[k].Y := Integer(RB32(D, dat + 9));
          end
          else
          begin
            Inc(Objs[k].X, Integer(RB32(D, dat + 5))); Inc(Objs[k].Y, Integer(RB32(D, dat + 9)));
          end;
    end
    else if IsType(D, pos + 4, 'PLTE') and (len > 0) then
    begin
      GlobalPLTE := nil; AppendRaw(GlobalPLTE, D, pos, len + 12);
    end
    else if IsType(D, pos + 4, 'tRNS') and (len > 0) then
    begin
      GlobalTRNS := nil; AppendRaw(GlobalTRNS, D, pos, len + 12);
    end
    else if IsType(D, pos + 4, 'IHDR') or IsType(D, pos + 4, 'JHDR') then
    begin
      ReadImage(IsType(D, pos + 4, 'JHDR'));
      if Cur.Id <> 0 then
      begin
        k := FindObj(Cur.Id);
        if k < 0 then begin k := Length(Objs); SetLength(Objs, k + 1); end;
        Objs[k] := Cur;
        if Cur.Visible then
          if DisplayLayer(Objs[k]) then begin Result := Canvas; Exit; end;
      end
      else if Cur.Visible then
        if DisplayLayer(Cur) then begin Result := Canvas; Exit; end;
      Continue;
    end
    else if IsType(D, pos + 4, 'DHDR') then
    begin
      // delta-PNG: not supported, skip to its IEND
      while pos + 12 <= N do
      begin
        len := RB32(D, pos);
        p2 := pos;
        pos := pos + 12 + len;
        if IsType(D, p2 + 4, 'IEND') then Break;
      end;
      Continue;
    end
    else if IsType(D, pos + 4, 'MEND') then
      Done := True;

    pos := dat + len + 4;
  end;

  // flush the last, still open frame
  if Layers > 0 then
    if EmitFrame then begin Result := Canvas; Exit; end;
  Result := nil;
  if StopAt >= 0 then raise EMngError.Create('MNG: frame index out of range');
end;

function MngFrameCount(InBuf: TBytes): Integer;
var
  W, H: Integer;
begin
  try
    Play(InBuf, -1, Result, W, H);
  except
    Result := 0;
  end;
end;

function DecodeMngFrame(InBuf: TBytes; Index: Integer; out Width, Height: Integer): TBytes;
var
  F: Integer;
begin
  if Index < 0 then raise EMngError.Create('MNG: frame index out of range');
  Result := Play(InBuf, Index, F, Width, Height);
end;

function DecodeMng(InBuf: TBytes; out Width, Height: Integer): TBytes;
begin
  Result := DecodeMngFrame(InBuf, 0, Width, Height);
end;

end.
