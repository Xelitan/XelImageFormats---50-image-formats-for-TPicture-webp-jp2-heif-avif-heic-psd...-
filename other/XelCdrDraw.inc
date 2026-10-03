// XelCdr: the page painter, the RIFF walk and the entry points.

type
  TCardArr = array of Cardinal;
  TChunkProc = procedure(const FourCC: AnsiString; const B: TBytes; Pos, Len, Level: Integer) of object;
  TListProc = procedure(const ListType: AnsiString; Level: Integer; Start: Boolean) of object;

  TClipEntry = record
    Level: Integer;
    Id: string;
    Container: string;          // the container's own drawing, written below its contents
  end;

  { TCdrPainter }

  TCdrPainter = class
  private
    FFS: TFormatSettings;
    Doc: TCdrDoc;
    Items: array of TOutItem;
    Defs: TStringBuilder;
    FSerial: Integer;
    FPatKeys: TStringList;
    // page state
    PageIndex: Integer;
    PageProps, IgnorePage, PageDone, DrawPage: Boolean;
    PageLevel, VectLevel: Integer;
    Spnd: Cardinal;
    Clips: array of TClipEntry;
    // object state
    ObjActive: Boolean;
    ObjLevel: Integer;
    Path: TPath;
    Fill: TCdrFill;
    Outl: TCdrOutl;
    StyleId: Cardinal;
    Trafo: TMats;
    Opacity: Double;
    HasBmp: Boolean;
    BmpId: Cardinal;
    BmpX1, BmpY1, BmpX2, BmpY2: Double;
    TextKind: Integer;          // 0 none, 1 artistic, 2 paragraph
    TextX, TextY, TextW, TextH: Double;
    TextId: Cardinal;
    IsPolygon, HasPolyTrafo, IsSpline: Boolean;
    PolyNum, PolyNext: Cardinal;
    PolyRx, PolyRy, PolyCx, PolyCy: Double;
    SplPts: array of Double;
    SplKnots: TCardArr;
    function N(v: Double): string;
    function Hex(c: Cardinal): string;
    function NewId(const Prefix: string): string;
    procedure AddItem(K: TOutKind; const S: string);
    // geometry
    procedure PMove(x, y: Double);
    procedure PLine(x, y: Double);
    procedure PCubic(x1, y1, x2, y2, x, y: Double);
    procedure PQuad(x1, y1, x, y: Double);
    procedure PClose;
    procedure ProcessPoints(const Pts: array of Double; const Types: TBytes);
    procedure ReadPoints(var R: TRd; Count: Integer);
    procedure ReadRectangle(var R: TRd);
    procedure ReadEllipse(var R: TRd);
    procedure ReadBitmapObj(var R: TRd);
    procedure ReadLoda(var R: TRd);
    procedure ReadTrfd(var R: TRd);
    procedure ReadOpacity(var R: TRd);
    procedure ReadPpdt(var R: TRd);
    procedure MakePolygon;
    procedure MakeSpline;
    procedure Apply(var x, y: Double);
    function Det: Double;
    procedure MapPt(x, y: Double; out ox, oy: Double);
    function BuildD(out Empty: Boolean; out MinX, MinY, MaxX, MaxY: Double): string;
    // painting
    function ColorAt(const F: TCdrFill; t: Double): Cardinal;
    function GradientElem(const D: string; const F: TCdrFill; MinX, MinY, MaxX, MaxY: Double): string;
    function PatternUrl(const F: TCdrFill; MinX, MinY, MaxX, MaxY: Double): string;
    function StrokeAttr: string;
    function BitmapElem(const D: string; DEmpty: Boolean): string;
    function TextElem: string;
    function ObjectElem: string;
    procedure ResetObject;
    procedure Flush;
  public
    SX: Double;                 // output pixels per inch
    PageW, PageH: Double;
    constructor Create(ADoc: TCdrDoc);
    destructor Destroy; override;
    procedure OnChunk(const FourCC: AnsiString; const B: TBytes; Pos, Len, Level: Integer);
    procedure OnList(const ListType: AnsiString; Level: Integer; Start: Boolean);
    function BuildSvg(W, H: Integer): string;
  end;

  { TCdrStylesPass }

  TCdrStylesPass = class
  public
    Doc: TCdrDoc;
    procedure OnChunk(const FourCC: AnsiString; const B: TBytes; Pos, Len, Level: Integer);
    procedure OnList(const ListType: AnsiString; Level: Integer; Start: Boolean);
  end;

function IfThenStr(Cond: Boolean; const A, B: string): string;
begin
  if Cond then Result := A else Result := B;
end;

function GetCdrVersion(c: Byte): Integer;
begin
  if c = $20 then Result := 300
  else if c < $31 then Result := 0
  else if c < $3A then Result := 100 * (c - $30)
  else if c < $41 then Result := 0
  else Result := 100 * (c - $37);
end;

function FourCCAt(const B: TBytes; p: Integer): AnsiString;
begin
  SetLength(Result, 4);
  if p + 4 <= Length(B) then
  begin
    Result[1] := AnsiChar(B[p]); Result[2] := AnsiChar(B[p + 1]);
    Result[3] := AnsiChar(B[p + 2]); Result[4] := AnsiChar(B[p + 3]);
  end
  else Result := '    ';
end;

// Walks the RIFF tree. Lengths of chunks inside compressed lists are indices
// into the list's block-length table.
procedure WalkRiff(Doc: TCdrDoc; const B: TBytes; P, E, Level: Integer; const Blocks: TCardArr;
  OnChunk: TChunkProc; OnList: TListProc);
var
  cc, lt: AnsiString;
  len, pos, cmprSize, here, k: Integer;
  ln: Cardinal;
  raw, blk: TBytes;
  bl: TCardArr;
begin
  if Level > MAX_LEVEL then Exit;
  if E > Length(B) then E := Length(B);
  while P + 8 <= E do
  begin
    if B[P] = 0 then begin Inc(P); Continue; end;
    cc := FourCCAt(B, P);
    ln := RdLE32(B, P + 4);
    if (Blocks <> nil) and (ln < Cardinal(Length(Blocks))) then ln := Blocks[ln];
    pos := P + 8;
    if ln > Cardinal(E - pos) then ln := Cardinal(Max(0, E - pos));
    len := ln;
    if (cc = 'RIFF') or (cc = 'LIST') then
    begin
      lt := FourCCAt(B, pos);
      if (cc = 'RIFF') and ((Copy(lt, 1, 3) = 'CDR') or (Copy(lt, 1, 3) = 'cdr')) then
        Doc.SetVersion(GetCdrVersion(Byte(lt[4])));
      if (lt = 'stlt') and (Doc.Version >= 700) then
        OnChunk('stlt', B, pos + 4, len - 4, Level)
      else if lt = 'cmpr' then
      begin
        // zlib-compressed list (CorelDRAW 7 .. X3)
        cmprSize := RdLE32(B, pos + 4);
        if (FourCCAt(B, pos + 20) = 'CPng') and (cmprSize > 0) and (pos + 28 + cmprSize <= pos + len) then
        begin
          // a damaged compressed list is skipped
          try
            raw := InflateZlib(@B[pos + 28], cmprSize);
            here := pos + 28 + cmprSize;
            blk := nil;
            if here < pos + len then blk := InflateZlib(@B[here], pos + len - here);
          except
            raw := nil; blk := nil;
          end;
          SetLength(bl, Length(blk) div 4);
          for k := 0 to High(bl) do bl[k] := RdLE32(blk, k * 4);
          OnList(lt, Level, True);
          WalkRiff(Doc, raw, 0, Length(raw), Level + 1, bl, OnChunk, OnList);
          OnList(lt, Level, False);
        end;
      end
      else
      begin
        OnList(lt, Level, True);
        WalkRiff(Doc, B, pos + 4, pos + len, Level + 1, Blocks, OnChunk, OnList);
        OnList(lt, Level, False);
      end;
    end
    else
      OnChunk(cc, B, pos, len, Level);
    P := pos + len;
  end;
end;

// ------------------------------ styles pass --------------------------------

procedure TCdrStylesPass.OnList(const ListType: AnsiString; Level: Integer; Start: Boolean);
var n: Integer;
begin
  if Start and (ListType = 'page') then
  begin
    n := Length(Doc.Pages);
    SetLength(Doc.Pages, n + 1);
    Doc.Pages[n].W := Doc.PageW;
    Doc.Pages[n].H := Doc.PageH;
  end;
end;

procedure TCdrStylesPass.OnChunk(const FourCC: AnsiString; const B: TBytes; Pos, Len, Level: Integer);
var
  R: TRd;
  w, h: Double;
  start, nargs, sargs, stypes, i: Integer;
  offs, types: TCardArr;
begin
  if not Doc.ChunkData(B, Pos, Len, R) then Exit;
  try
    if FourCC = 'vrsn' then Doc.SetVersion(R.U16)
    else if FourCC = 'fild' then Doc.ReadFild(R)
    else if FourCC = 'fill' then Doc.ReadFild(R)
    else if FourCC = 'outl' then Doc.ReadOutl(R)
    else if FourCC = 'bmp ' then Doc.ReadBmp(R, R.Left)
    else if FourCC = 'bmpf' then Doc.ReadBmpf(R, R.Left)
    else if FourCC = 'font' then Doc.ReadFont(R)
    else if FourCC = 'uidr' then Doc.ReadUidr(R)
    else if FourCC = 'stlt' then Doc.ReadStlt(R)
    else if FourCC = 'txsm' then Doc.ReadTxsm(R)
    else if FourCC = 'mcfg' then
    begin
      if Doc.Version >= 1300 then R.Skip(12)
      else if Doc.Version >= 900 then R.Skip(4)
      else if (Doc.Version < 700) and (Doc.Version >= 600) then R.Skip($1C);
      if Doc.Version < 400 then
      begin
        R.Skip(2);
        w := Doc.Coord(R); h := Doc.Coord(R);
        w := Abs(Doc.Coord(R) - w); h := Abs(Doc.Coord(R) - h);
      end
      else
      begin
        w := Doc.Coord(R); h := Doc.Coord(R);
      end;
      if (w > 0.01) and (h > 0.01) then
      begin
        Doc.PageW := w; Doc.PageH := h;
        if Length(Doc.Pages) > 0 then
        begin
          Doc.Pages[High(Doc.Pages)].W := w; Doc.Pages[High(Doc.Pages)].H := h;
        end;
      end;
    end
    else if (FourCC = 'loda') or (FourCC = 'lobj') then
    begin
      // page size arguments of the page's own layer records
      start := R.P;
      R.Skip(4);
      nargs := Doc.Uns(R); sargs := Doc.Uns(R); stypes := Doc.Uns(R);
      if (nargs <= 0) or (nargs > 4096) then Exit;
      SetLength(offs, nargs); SetLength(types, nargs);
      R.P := start + sargs;
      for i := 0 to nargs - 1 do offs[i] := Doc.Uns(R);
      R.P := start + stypes;
      for i := nargs - 1 downto 0 do types[i] := Doc.Uns(R);
      for i := 0 to nargs - 1 do
        if types[i] = $4ABA then
        begin
          R.P := start + Integer(offs[i]);
          w := Doc.Coord(R); h := Doc.Coord(R);
          if (w > 0.01) and (h > 0.01) and (Length(Doc.Pages) > 0) then
          begin
            Doc.Pages[High(Doc.Pages)].W := w; Doc.Pages[High(Doc.Pages)].H := h;
          end;
        end;
    end;
  except
    // a damaged record is skipped
  end;
end;

// ------------------------------ painter ------------------------------------

constructor TCdrPainter.Create(ADoc: TCdrDoc);
begin
  inherited Create;
  Doc := ADoc;
  FFS := DefaultFormatSettings;
  FFS.DecimalSeparator := '.';
  Defs := TStringBuilder.Create;
  FPatKeys := TStringList.Create;
  PageIndex := -1;
  SX := PX_PER_INCH;
  ResetObject;
end;

destructor TCdrPainter.Destroy;
begin
  Defs.Free;
  FPatKeys.Free;
  inherited Destroy;
end;

function TCdrPainter.N(v: Double): string;
var i: Integer;
begin
  if Abs(v) < 0.005 then Exit('0');
  v := EnsureRange(v, -1e7, 1e7);
  Result := FloatToStrF(v, ffFixed, 15, 2, FFS);
  if Pos('.', Result) > 0 then
  begin
    i := Length(Result);
    while Result[i] = '0' do Dec(i);
    if Result[i] = '.' then Dec(i);
    SetLength(Result, i);
  end;
end;

function TCdrPainter.Hex(c: Cardinal): string;
begin
  Result := '#' + IntToHex((c shr 16) and $FF, 2) + IntToHex((c shr 8) and $FF, 2) + IntToHex(c and $FF, 2);
end;

function TCdrPainter.NewId(const Prefix: string): string;
begin
  Inc(FSerial);
  Result := Prefix + IntToStr(FSerial);
end;

procedure TCdrPainter.AddItem(K: TOutKind; const S: string);
var n: Integer;
begin
  n := Length(Items);
  if n >= Length(Items) then SetLength(Items, n + 1);
  Items[n].Kind := K;
  Items[n].S := S;
end;

procedure TCdrPainter.ResetObject;
begin
  ObjActive := False;
  Path := nil;
  Fill := DefaultFill;
  Outl := DefaultOutl;
  StyleId := 0;
  Trafo := nil;
  Opacity := 1;
  HasBmp := False;
  TextKind := 0;
  IsPolygon := False; HasPolyTrafo := False; IsSpline := False;
  SplPts := nil; SplKnots := nil;
end;

// ---- path building (object coordinates, inches, y up) ----

procedure TCdrPainter.PMove(x, y: Double);
var n: Integer;
begin
  n := Length(Path); SetLength(Path, n + 1);
  Path[n].Cmd := 'M'; Path[n].X := x; Path[n].Y := y;
end;

procedure TCdrPainter.PLine(x, y: Double);
var n: Integer;
begin
  n := Length(Path); SetLength(Path, n + 1);
  Path[n].Cmd := 'L'; Path[n].X := x; Path[n].Y := y;
end;

procedure TCdrPainter.PCubic(x1, y1, x2, y2, x, y: Double);
var n: Integer;
begin
  n := Length(Path); SetLength(Path, n + 1);
  Path[n].Cmd := 'C';
  Path[n].X1 := x1; Path[n].Y1 := y1; Path[n].X2 := x2; Path[n].Y2 := y2;
  Path[n].X := x; Path[n].Y := y;
end;

procedure TCdrPainter.PQuad(x1, y1, x, y: Double);
var x0, y0: Double;
begin
  x0 := 0; y0 := 0;
  if Length(Path) > 0 then begin x0 := Path[High(Path)].X; y0 := Path[High(Path)].Y; end;
  PCubic(x0 + 2 / 3 * (x1 - x0), y0 + 2 / 3 * (y1 - y0), x + 2 / 3 * (x1 - x), y + 2 / 3 * (y1 - y), x, y);
end;

procedure TCdrPainter.PClose;
var n: Integer;
begin
  n := Length(Path); SetLength(Path, n + 1);
  Path[n].Cmd := 'Z';
  if n > 0 then begin Path[n].X := Path[n - 1].X; Path[n].Y := Path[n - 1].Y; end;
end;

// node types: $08 closes, $40/$80: 00 move, 40 line, 80 curve end, C0 control point
procedure TCdrPainter.ProcessPoints(const Pts: array of Double; const Types: TBytes);
var
  k, nt: Integer;
  t: Byte;
  closed: Boolean;
  tmp: array[0..3] of Double;
begin
  nt := 0;
  for k := 0 to High(Types) do
  begin
    if 2 * k + 1 > High(Pts) then Break;
    t := Types[k];
    closed := (t and $08) <> 0;
    if (t and $C0) = $00 then
    begin
      if closed then PClose;
      nt := 0;
      PMove(Pts[2 * k], Pts[2 * k + 1]);
    end
    else if (t and $C0) = $40 then
    begin
      nt := 0;
      PLine(Pts[2 * k], Pts[2 * k + 1]);
      if closed then PClose;
    end
    else if (t and $C0) = $80 then
    begin
      if nt >= 2 then PCubic(tmp[0], tmp[1], tmp[2], tmp[3], Pts[2 * k], Pts[2 * k + 1])
      else PLine(Pts[2 * k], Pts[2 * k + 1]);
      if closed then PClose;
      nt := 0;
    end
    else
    begin
      if nt < 2 then
      begin
        tmp[2 * nt] := Pts[2 * k]; tmp[2 * nt + 1] := Pts[2 * k + 1];
      end;
      Inc(nt);
    end;
  end;
end;

procedure TCdrPainter.ReadPoints(var R: TRd; Count: Integer);
var
  pts: array of Double;
  types: TBytes;
  i, ps: Integer;
begin
  if Doc.Prec32 then ps := 9 else ps := 5;
  if Count > R.Left div ps then Count := R.Left div ps;
  if Count <= 0 then Exit;
  SetLength(pts, 2 * Count);
  SetLength(types, Count);
  for i := 0 to Count - 1 do
  begin
    pts[2 * i] := Doc.Coord(R);
    pts[2 * i + 1] := Doc.Coord(R);
  end;
  for i := 0 to Count - 1 do types[i] := R.U8;
  ProcessPoints(pts, types);
end;

procedure TCdrPainter.ReadRectangle(var R: TRd);
var
  x0, y0, r0, r1, r2, r3, sx, sy, s, w, h, m: Double;
  corner, scaleWith: Integer;

  function RC: Double;
  begin
    if Doc.Version < 1500 then Result := Doc.Coord(R) else Result := R.F64 / 254000;
  end;

  procedure DoCorner(cx, cy, px, py, ex, ey: Double);
  begin
    // from the current point, around the corner (cx, cy) to (ex, ey)
    case corner of
      0: PQuad(cx, cy, ex, ey);
      1: PQuad(px, py, ex, ey);
    else
      PLine(ex, ey);
    end;
  end;

begin
  x0 := RC; y0 := RC;
  r0 := 0; r1 := 0; r2 := 0; r3 := 0;
  sx := 1; sy := 1;
  corner := 0;
  if Doc.Version < 1500 then
  begin
    r3 := RC;
    if Doc.Version < 900 then begin r2 := r3; r1 := r3; r0 := r3; end
    else begin r2 := RC; r1 := RC; r0 := RC; end;
  end
  else
  begin
    s := R.F64; if Abs(s) > 1e-9 then sx := s;
    s := R.F64; if Abs(s) > 1e-9 then sy := s;
    scaleWith := R.U8;
    R.Skip(7);
    if scaleWith = 0 then
    begin
      r3 := R.F64; corner := R.U8; R.Skip(15);
      r2 := R.F64; R.Skip(16);
      r1 := R.F64; R.Skip(16);
      r0 := R.F64;
      w := Abs(x0 * sx / 2); h := Abs(y0 * sy / 2);
      m := Min(w, h);
      r3 := r3 * m; r2 := r2 * m; r1 := r1 * m; r0 := r0 * m;
    end
    else
    begin
      r3 := RC; corner := R.U8; R.Skip(15);
      r2 := RC; R.Skip(16);
      r1 := RC; R.Skip(16);
      r0 := RC;
    end;
  end;
  if r0 > 0 then PMove(0, -r0 / sy) else PMove(0, 0);
  if r1 > 0 then
  begin
    PLine(0, y0 + r1 / sy);
    DoCorner(0, y0, r1 / sx, y0 + r1 / sy, r1 / sx, y0);
  end
  else PLine(0, y0);
  if r2 > 0 then
  begin
    PLine(x0 - r2 / sx, y0);
    DoCorner(x0, y0, x0 - r2 / sx, y0 + r2 / sy, x0, y0 + r2 / sy);
  end
  else PLine(x0, y0);
  if r3 > 0 then
  begin
    PLine(x0, -r3 / sy);
    DoCorner(x0, 0, x0 - r3 / sx, -r3 / sy, x0 - r3 / sx, 0);
  end
  else PLine(x0, 0);
  if r0 > 0 then
  begin
    PLine(r0 / sx, 0);
    DoCorner(0, 0, r0 / sx, -r0 / sy, 0, -r0 / sy);
  end
  else PLine(0, 0);
  PClose;
end;

procedure TCdrPainter.ReadEllipse(var R: TRd);
var
  x, y, a1, a2, cx, cy, rx, ry, d, k, t0, t1: Double;
  pie: Boolean;
  n, i: Integer;
  full: Boolean;
begin
  x := Doc.Coord(R); y := Doc.Coord(R);
  a1 := Doc.Ang(R); a2 := Doc.Ang(R);
  pie := Doc.Uns(R) <> 0;
  cx := x / 2; cy := y / 2; rx := Abs(cx); ry := Abs(cy);
  a1 := a1 - 2 * Pi * Floor(a1 / (2 * Pi));
  a2 := a2 - 2 * Pi * Floor(a2 / (2 * Pi));
  full := Abs(a1 - a2) < 1e-9;
  if full then a2 := a1 + 2 * Pi
  else if a2 < a1 then a2 := a2 + 2 * Pi;
  n := Max(1, Ceil((a2 - a1) / (Pi / 2) - 1e-9));
  d := (a2 - a1) / n;
  k := 4 / 3 * Tan(d / 4);
  PMove(cx + rx * Cos(a1), cy + ry * Sin(a1));
  for i := 0 to n - 1 do
  begin
    t0 := a1 + i * d; t1 := t0 + d;
    PCubic(cx + rx * Cos(t0) - k * rx * Sin(t0), cy + ry * Sin(t0) + k * ry * Cos(t0),
      cx + rx * Cos(t1) + k * rx * Sin(t1), cy + ry * Sin(t1) - k * ry * Cos(t1),
      cx + rx * Cos(t1), cy + ry * Sin(t1));
  end;
  if full then PClose
  else if pie then
  begin
    PLine(cx, cy);
    PClose;
  end;
end;

procedure TCdrPainter.ReadBitmapObj(var R: TRd);
var n: Integer;
begin
  if Doc.Version < 600 then
  begin
    BmpX1 := Doc.Coord(R); BmpY1 := Doc.Coord(R);
    BmpX2 := 0; BmpY2 := 0;
    if Doc.Version < 400 then R.Skip(2);
    R.Skip(8);
    BmpId := Doc.Uns(R);
  end
  else
  begin
    BmpX1 := Doc.Coord(R); BmpY1 := Doc.Coord(R);
    BmpX2 := Doc.Coord(R); BmpY2 := Doc.Coord(R);
    R.Skip(32);
    BmpId := Doc.Uns(R);
    if Doc.Version < 800 then R.Skip(8)
    else if Doc.Version < 900 then R.Skip(12)
    else R.Skip(20);
    n := R.U16;
    R.Skip(2);
    ReadPoints(R, n);
  end;
  HasBmp := True;
end;

procedure TCdrPainter.ReadLoda(var R: TRd);
var
  start, nargs, sargs, stypes, ctype, i, n: Integer;
  offs, types: TCardArr;
  id: Cardinal;
  F: TCdrFill;
  O: TCdrOutl;
begin
  start := R.P;
  R.Skip(4);
  nargs := Doc.Uns(R); sargs := Doc.Uns(R); stypes := Doc.Uns(R);
  ctype := Doc.Uns(R);
  if (nargs <= 0) or (nargs > 4096) then Exit;
  if ctype = $26 then IsSpline := True;
  SetLength(offs, nargs); SetLength(types, nargs);
  R.P := start + sargs;
  for i := 0 to nargs - 1 do offs[i] := Doc.Uns(R);
  R.P := start + stypes;
  for i := nargs - 1 downto 0 do types[i] := Doc.Uns(R);
  for i := 0 to nargs - 1 do
  begin
    R.P := start + Integer(offs[i]);
    case types[i] of
      $1E: begin
             if ((Doc.Version >= 400) and (ctype = 1)) or ((Doc.Version < 400) and (ctype = 0)) then ReadRectangle(R)
             else if ((Doc.Version >= 400) and (ctype = 2)) or ((Doc.Version < 400) and (ctype = 1)) then ReadEllipse(R)
             else if ((Doc.Version >= 400) and (ctype = 3)) or ((Doc.Version < 400) and (ctype = 2)) then
             begin
               n := R.U16; R.Skip(2);
               ReadPoints(R, n);
             end
             else if ctype = $25 then
             begin
               R.Skip(4);
               n := R.U16; n := n + R.U16;
               R.Skip(16);
               ReadPoints(R, n);
             end
             else if ((Doc.Version >= 400) and (ctype = 4)) or ((Doc.Version < 400) and (ctype = 3)) then
             begin
               TextKind := 1;
               TextX := Doc.Coord(R); TextY := Doc.Coord(R);
               // some versions leave no position here (the transform has it)
               if (Abs(TextX) > 500) or (Abs(TextY) > 500) then begin TextX := 0; TextY := 0; end;
               TextId := Spnd;
             end
             else if ((Doc.Version >= 400) and (ctype = 5)) or ((Doc.Version < 400) and (ctype = 4)) then
               ReadBitmapObj(R)
             else if ((Doc.Version >= 400) and (ctype = 6)) or ((Doc.Version < 400) and (ctype = 5)) then
             begin
               TextKind := 2;
               R.Skip(4);
               TextW := Doc.Coord(R); TextH := Doc.Coord(R);
               TextX := 0; TextY := 0;
               TextId := Spnd;
             end
             else if ctype = $14 then
             begin
               n := R.U16; R.Skip(2);
               ReadPoints(R, n);
               IsPolygon := True;
             end;
           end;
      $14: begin
             id := R.U32;
             if (id <> 0) and Doc.FindFill(id, F) then Fill := F;
           end;
      $0A: begin
             id := R.U32;
             if (id <> 0) and Doc.FindOutl(id, O) then Outl := O;
           end;
      $C8: begin
             id := Doc.Uns(R);
             if id <> 0 then StyleId := id;
           end;
      $2AF8: begin
               if Doc.Version < 1300 then R.Skip(4);
               PolyNum := R.U32;
               PolyNext := R.U32;
               if PolyNext <= 1 then PolyNext := R.U32 else R.Skip(4);
               if Doc.Version >= 1300 then R.Skip(4);
               PolyRx := R.F64; PolyRy := R.F64;
               PolyCx := Doc.Coord(R); PolyCy := Doc.Coord(R);
               HasPolyTrafo := True;
             end;
      $1F40: ReadOpacity(R);
    end;
  end;
end;

// Transparency. X3+ wraps it in a $514 block that holds the percentage as a
// double right after an $FFFFFFFF marker; older files keep a 1/1000 value.
procedure TCdrPainter.ReadOpacity(var R: TRd);
var
  st, len, q: Integer;
  v: Double;
  sub: TRd;
begin
  st := R.P;
  if (Doc.Version >= 1300) and (R.U32 = $514) then
  begin
    len := R.U32;
    q := R.P;
    while q + 12 <= Min(R.P + len, R.E) do
    begin
      if RdLE32(R.B, q) = $FFFFFFFF then
      begin
        sub.Init(R.B, q + 4, q + 12);
        v := sub.F64;
        if (v >= 0) and (v <= 100) and ((v > 0) or (RdLE32(R.B, q + 4) = 0)) then
        begin
          Opacity := EnsureRange(1 - v / 100, 0, 1);
          Exit;
        end;
      end;
      Inc(q);
    end;
    Exit;
  end;
  R.P := st;
  if Doc.Version < 1300 then R.Skip(10) else R.Skip(14);
  v := R.U16 / 1000;
  if (v > 0) and (v <= 1) then Opacity := v;
end;

procedure TCdrPainter.ReadTrfd(var R: TRd);
var
  start, nargs, sargs, i, t: Integer;
  offs: TCardArr;
  M: TMat;
begin
  start := R.P;
  R.Skip(4);
  nargs := Doc.Uns(R); sargs := Doc.Uns(R);
  if (nargs <= 0) or (nargs > 1024) then Exit;
  SetLength(offs, nargs);
  R.P := start + sargs;
  for i := 0 to nargs - 1 do offs[i] := Doc.Uns(R);
  Trafo := nil;
  for i := 0 to nargs - 1 do
  begin
    R.P := start + Integer(offs[i]);
    if Doc.Version >= 1300 then R.Skip(8);
    t := R.U16;
    if t = 8 then
    begin
      if Doc.Version >= 600 then R.Skip(6);
      if Doc.Version >= 500 then
      begin
        M.A := R.F64; M.B := R.F64; M.C := R.F64;
        M.D := R.F64; M.E := R.F64; M.F := R.F64;
        if Doc.Version < 600 then begin M.C := M.C / 1000; M.F := M.F / 1000; end
        else begin M.C := M.C / 254000; M.F := M.F / 254000; end;
      end
      else
      begin
        M.A := R.S32 / 65536; M.B := R.S32 / 65536; M.C := R.S32 / 1000;
        M.D := R.S32 / 65536; M.E := R.S32 / 65536; M.F := R.S32 / 1000;
      end;
      SetLength(Trafo, Length(Trafo) + 1);
      Trafo[High(Trafo)] := M;
    end;
  end;
end;

procedure TCdrPainter.ReadPpdt(var R: TRd);
var n, i, ps: Integer;
begin
  n := R.U16;
  if Doc.Prec32 then ps := 12 else ps := 8;
  if n > R.Left div ps then n := R.Left div ps;
  R.Skip(4);
  SetLength(SplPts, 2 * n);
  SetLength(SplKnots, n);
  for i := 0 to n - 1 do
  begin
    SplPts[2 * i] := Doc.Coord(R);
    SplPts[2 * i + 1] := Doc.Coord(R);
  end;
  for i := 0 to n - 1 do SplKnots[i] := R.U32;
end;

// a star / polygon: the stored path is one arm; copies are rotated around
procedure TCdrPainter.MakePolygon;
var
  src, res: TPath;
  step, ca, sa, ca1, sa1: Double;
  i, j, k, m: Integer;

  procedure Rot(var P: TPath; c, s: Double);
  var q: Integer; x, y: Double;
  begin
    for q := 0 to High(P) do
    begin
      x := P[q].X; y := P[q].Y;
      P[q].X := c * x + s * y; P[q].Y := -s * x + c * y;
      x := P[q].X1; y := P[q].Y1;
      P[q].X1 := c * x + s * y; P[q].Y1 := -s * x + c * y;
      x := P[q].X2; y := P[q].Y2;
      P[q].X2 := c * x + s * y; P[q].Y2 := -s * x + c * y;
    end;
  end;

  procedure Append(const P: TPath);
  var q, n0: Integer;
  begin
    n0 := Length(res);
    SetLength(res, n0 + Length(P));
    for q := 0 to High(P) do res[n0 + q] := P[q];
  end;

  procedure AppendClose;
  var n0: Integer;
  begin
    n0 := Length(res);
    SetLength(res, n0 + 1);
    res[n0].Cmd := 'Z';
  end;

begin
  if (PolyNum = 0) or (PolyNum > 1000) or (Length(Path) = 0) then Exit;
  src := Copy(Path);
  res := Copy(Path);
  step := 2 * Pi / PolyNum;
  ca := Cos(PolyNext * step); sa := Sin(PolyNext * step);
  if (PolyNext <> 0) and ((PolyNum mod PolyNext) <> 0) then
  begin
    for i := 1 to PolyNum - 1 do
    begin
      Rot(src, ca, sa);
      Append(src);
    end;
  end
  else
  begin
    ca1 := Cos(step); sa1 := Sin(step);
    if PolyNext = 0 then m := 1 else m := PolyNum div PolyNext;
    for i := 0 to Integer(PolyNext) - 1 do
    begin
      if i > 0 then
      begin
        Rot(src, ca1, sa1);
        Append(src);
      end;
      for j := 1 to m - 1 do
      begin
        Rot(src, ca, sa);
        Append(src);
      end;
      AppendClose;
    end;
  end;
  AppendClose;
  for k := 0 to High(res) do
  begin
    res[k].X := PolyRx * res[k].X + PolyCx; res[k].Y := PolyRy * res[k].Y + PolyCy;
    res[k].X1 := PolyRx * res[k].X1 + PolyCx; res[k].Y1 := PolyRy * res[k].Y1 + PolyCy;
    res[k].X2 := PolyRx * res[k].X2 + PolyCx; res[k].Y2 := PolyRy * res[k].Y2 + PolyCy;
  end;
  Path := res;
end;

// clamped uniform cubic B-spline (libcdr's knot vector), sampled by de Boor
procedure TCdrPainter.MakeSpline;
var
  n, i, j: Integer;
  seg: array of Double;

  procedure SplineTo(const P: array of Double; Cnt: Integer);
  var
    span, steps, s, r, k: Integer;
    t, tmax, alpha: Double;
    d: array[0..3, 0..1] of Double;

    function Knot(idx: Integer): Double;
    begin
      if idx < 3 then Result := 0
      else if idx > Cnt then Result := Cnt - 3
      else Result := idx - 3;
    end;

  begin
    tmax := Cnt - 3;
    steps := Max(8, (Cnt - 3) * 12);
    for s := 1 to steps do
    begin
      t := tmax * s / steps;
      span := 3;
      while (span < Cnt - 1) and (Knot(span + 1) <= t) do Inc(span);
      for k := 0 to 3 do
      begin
        d[k, 0] := P[2 * (span - 3 + k)];
        d[k, 1] := P[2 * (span - 3 + k) + 1];
      end;
      for r := 1 to 3 do
        for k := 3 downto r do
        begin
          if Knot(k + 1 + span - r) - Knot(k + span - 3) > 1e-12 then
            alpha := (t - Knot(k + span - 3)) / (Knot(k + 1 + span - r) - Knot(k + span - 3))
          else alpha := 0;
          d[k, 0] := (1 - alpha) * d[k - 1, 0] + alpha * d[k, 0];
          d[k, 1] := (1 - alpha) * d[k - 1, 1] + alpha * d[k, 1];
        end;
      PLine(d[3, 0], d[3, 1]);
    end;
  end;

  procedure Piece;
  var c: Integer;
  begin
    c := Length(seg) div 2;
    if c = 2 then PLine(seg[2], seg[3])
    else if c = 3 then PQuad(seg[2], seg[3], seg[4], seg[5])
    else if c > 3 then SplineTo(seg, c);
  end;

begin
  n := Min(Length(SplPts) div 2, Length(SplKnots));
  if n = 0 then Exit;
  Path := nil;
  PMove(SplPts[0], SplPts[1]);
  SetLength(seg, 2);
  seg[0] := SplPts[0]; seg[1] := SplPts[1];
  for i := 1 to n - 1 do
  begin
    j := Length(seg);
    SetLength(seg, j + 2);
    seg[j] := SplPts[2 * i]; seg[j + 1] := SplPts[2 * i + 1];
    if SplKnots[i] <> 0 then
    begin
      Piece;
      SetLength(seg, 2);
      seg[0] := SplPts[2 * i]; seg[1] := SplPts[2 * i + 1];
    end;
  end;
  if Length(seg) > 2 then Piece;
end;

procedure TCdrPainter.Apply(var x, y: Double);
var i: Integer; tx: Double;
begin
  for i := 0 to High(Trafo) do
  begin
    tx := Trafo[i].A * x + Trafo[i].B * y + Trafo[i].C;
    y := Trafo[i].D * x + Trafo[i].E * y + Trafo[i].F;
    x := tx;
  end;
end;

function TCdrPainter.Det: Double;
var x0, y0, x1, y1, x2, y2: Double;
begin
  x0 := 0; y0 := 0; Apply(x0, y0);
  x1 := 1; y1 := 0; Apply(x1, y1);
  x2 := 0; y2 := 1; Apply(x2, y2);
  Result := (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0);
end;

// object coordinates -> output pixels
procedure TCdrPainter.MapPt(x, y: Double; out ox, oy: Double);
begin
  Apply(x, y);
  ox := (x + PageW / 2) * SX;
  oy := (PageH / 2 - y) * SX;
end;

// SVG path data; sub-paths that end where they started are closed
function TCdrPainter.BuildD(out Empty: Boolean; out MinX, MinY, MaxX, MaxY: Double): string;
var
  sb: TStringBuilder;
  i: Integer;
  x, y, x1, y1, x2, y2, sx0, sy0, px, py: Double;
  open, any, lastZ: Boolean;

  procedure Track(a, b: Double);
  begin
    if a < MinX then MinX := a;
    if a > MaxX then MaxX := a;
    if b < MinY then MinY := b;
    if b > MaxY then MaxY := b;
  end;

  procedure CloseIfBack;
  begin
    if open and not lastZ and (Abs(px - sx0) < 1e-3) and (Abs(py - sy0) < 1e-3) then
    begin
      sb.Append('Z ');
      lastZ := True;
    end;
  end;

begin
  MinX := 1e300; MinY := 1e300; MaxX := -1e300; MaxY := -1e300;
  sb := TStringBuilder.Create;
  try
    open := False; any := False; lastZ := False;
    sx0 := 0; sy0 := 0; px := 0; py := 0;
    for i := 0 to High(Path) do
      case Path[i].Cmd of
        'M': begin
               MapPt(Path[i].X, Path[i].Y, x, y);
               if open and (Abs(x - px) < 1e-3) and (Abs(y - py) < 1e-3) then Continue;
               CloseIfBack;
               sb.Append('M').Append(N(x)).Append(' ').Append(N(y)).Append(' ');
               open := True; lastZ := False;
               sx0 := x; sy0 := y; px := x; py := y;
               Track(x, y);
             end;
        'L': begin
               MapPt(Path[i].X, Path[i].Y, x, y);
               if not open then
               begin
                 sb.Append('M').Append(N(px)).Append(' ').Append(N(py)).Append(' ');
                 open := True; sx0 := px; sy0 := py;
               end;
               sb.Append('L').Append(N(x)).Append(' ').Append(N(y)).Append(' ');
               px := x; py := y; any := True; lastZ := False;
               Track(x, y);
             end;
        'C': begin
               MapPt(Path[i].X1, Path[i].Y1, x1, y1);
               MapPt(Path[i].X2, Path[i].Y2, x2, y2);
               MapPt(Path[i].X, Path[i].Y, x, y);
               if not open then
               begin
                 sb.Append('M').Append(N(px)).Append(' ').Append(N(py)).Append(' ');
                 open := True; sx0 := px; sy0 := py;
               end;
               sb.Append('C').Append(N(x1)).Append(' ').Append(N(y1)).Append(' ').Append(N(x2)).Append(' ')
                 .Append(N(y2)).Append(' ').Append(N(x)).Append(' ').Append(N(y)).Append(' ');
               px := x; py := y; any := True; lastZ := False;
               Track(x1, y1); Track(x2, y2); Track(x, y);
             end;
        'Z': if open and not lastZ and any then
             begin
               sb.Append('Z ');
               lastZ := True;
               px := sx0; py := sy0;
             end;
      end;
    CloseIfBack;
    Empty := not any;
    Result := Trim(sb.ToString);
  finally
    sb.Free;
  end;
end;

// ---- fills ----

function TCdrPainter.ColorAt(const F: TCdrFill; t: Double): Cardinal;
var
  i: Integer;
  a, b: Cardinal;
  u, o0, o1: Double;
begin
  if Length(F.Stops) = 0 then Exit(Doc.Rgb(F.Color1));
  t := EnsureRange(t, 0, 1);
  if t <= F.Stops[0].Offset then Exit(Doc.Rgb(F.Stops[0].Color));
  for i := 0 to High(F.Stops) - 1 do
  begin
    o0 := F.Stops[i].Offset; o1 := F.Stops[i + 1].Offset;
    if t <= o1 then
    begin
      a := Doc.Rgb(F.Stops[i].Color); b := Doc.Rgb(F.Stops[i + 1].Color);
      if o1 - o0 > 1e-9 then u := (t - o0) / (o1 - o0) else u := 1;
      Exit((Cardinal(ClampB(((a shr 16) and $FF) * (1 - u) + ((b shr 16) and $FF) * u)) shl 16) or
        (Cardinal(ClampB(((a shr 8) and $FF) * (1 - u) + ((b shr 8) and $FF) * u)) shl 8) or
        Cardinal(ClampB((a and $FF) * (1 - u) + (b and $FF) * u)));
    end;
  end;
  Result := Doc.Rgb(F.Stops[High(F.Stops)].Color);
end;

// fountain fill: colour bands (or rings) inside a clip path of the shape
function TCdrPainter.GradientElem(const D: string; const F: TCdrFill; MinX, MinY, MaxX, MaxY: Double): string;
var
  id, op: string;
  sb: TStringBuilder;
  dx, dy, px, py, tmin, tmax, t, t0, t1, e, cx, cy, rad, rr, w, h, extra: Double;
  i, steps: Integer;
  c: Cardinal;
  corners: array[0..3, 0..1] of Double;

  function Edge(u: Double): Double;
  begin
    if e > 0 then u := (u - e / 2) / (1 - e);
    Result := EnsureRange(u, 0, 1);
  end;

begin
  id := NewId('gc');
  Defs.Append('<clipPath id="' + id + '"><path d="' + D + '" clip-rule="evenodd"/></clipPath>').Append(#10);
  sb := TStringBuilder.Create;
  try
    if Opacity < 1 then op := ' fill-opacity="' + N(Opacity) + '"' else op := '';
    sb.Append('<g clip-path="url(#' + id + ')">');
    e := EnsureRange(F.GEdge / 100, 0, 0.9);
    w := MaxX - MinX; h := MaxY - MinY;
    extra := 1;
    steps := GRAD_STEPS;
    if F.GType in [2, 4] then
    begin
      // radial / square: the first stop is at the outside
      cx := MinX + w * (0.5 + F.GCx / 200);
      cy := MinY + h * (0.5 - F.GCy / 200);
      rad := 0;
      corners[0, 0] := MinX; corners[0, 1] := MinY; corners[1, 0] := MaxX; corners[1, 1] := MinY;
      corners[2, 0] := MinX; corners[2, 1] := MaxY; corners[3, 0] := MaxX; corners[3, 1] := MaxY;
      for i := 0 to 3 do
        if F.GType = 2 then rad := Max(rad, Hypot(corners[i, 0] - cx, corners[i, 1] - cy))
        else rad := Max(rad, Max(Abs(corners[i, 0] - cx), Abs(corners[i, 1] - cy)));
      rad := rad + extra;
      for i := 0 to steps - 1 do
      begin
        rr := rad * (steps - i) / steps;
        t := Edge(i / steps);
        c := ColorAt(F, t);
        if F.GType = 2 then
          sb.Append('<path d="M' + N(cx + rr) + ' ' + N(cy) + ' A' + N(rr) + ' ' + N(rr) + ' 0 1 0 ' + N(cx - rr) + ' ' + N(cy) +
            ' A' + N(rr) + ' ' + N(rr) + ' 0 1 0 ' + N(cx + rr) + ' ' + N(cy) + ' Z" fill="' + Hex(c) + '"' + op + ' stroke="none"/>')
        else
          sb.Append('<path d="M' + N(cx - rr) + ' ' + N(cy - rr) + ' h' + N(2 * rr) + ' v' + N(2 * rr) + ' h' + N(-2 * rr) +
            ' Z" fill="' + Hex(c) + '"' + op + ' stroke="none"/>');
      end;
    end
    else
    begin
      // linear (and conical, drawn as linear): the first stop on the side
      // opposite to the angle
      dx := Cos(F.GAngle); dy := -Sin(F.GAngle);
      px := -dy; py := dx;
      tmin := 1e300; tmax := -1e300;
      corners[0, 0] := MinX; corners[0, 1] := MinY; corners[1, 0] := MaxX; corners[1, 1] := MinY;
      corners[2, 0] := MinX; corners[2, 1] := MaxY; corners[3, 0] := MaxX; corners[3, 1] := MaxY;
      for i := 0 to 3 do
      begin
        t := corners[i, 0] * dx + corners[i, 1] * dy;
        tmin := Min(tmin, t); tmax := Max(tmax, t);
      end;
      cx := (MinX + MaxX) / 2; cy := (MinY + MaxY) / 2;
      rad := Hypot(w, h) / 2 + extra;
      t := cx * dx + cy * dy;           // projection of the centre
      for i := 0 to steps - 1 do
      begin
        t0 := tmin + (tmax - tmin) * i / steps - t;
        t1 := tmin + (tmax - tmin) * (i + 1) / steps - t + (tmax - tmin) / steps * 0.5;
        if i = 0 then t0 := t0 - extra;
        if i = steps - 1 then t1 := t1 + extra;
        c := ColorAt(F, Edge((i + 0.5) / steps));
        sb.Append('<path d="M' + N(cx + dx * t0 + px * rad) + ' ' + N(cy + dy * t0 + py * rad) +
          ' L' + N(cx + dx * t1 + px * rad) + ' ' + N(cy + dy * t1 + py * rad) +
          ' L' + N(cx + dx * t1 - px * rad) + ' ' + N(cy + dy * t1 - py * rad) +
          ' L' + N(cx + dx * t0 - px * rad) + ' ' + N(cy + dy * t0 - py * rad) + ' Z" fill="' + Hex(c) + '"' + op + ' stroke="none"/>');
      end;
    end;
    sb.Append('</g>');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

// two-colour (bitmap pattern) and bitmap / texture fills as pattern tiles
function TCdrPainter.PatternUrl(const F: TCdrFill; MinX, MinY, MaxX, MaxY: Double): string;
var
  key, id, d: string;
  sb: TStringBuilder;
  tw, th, cw, ch, sc: Double;
  i, x, y, cols, rows, run, k: Integer;
  fg, bg, c: Cardinal;
  P: TCdrPattern;
  Img: TCdrImage;
  runs: TStringList;
  bit: Boolean;

  function Sample(ix, iy: Integer): Cardinal;
  begin
    Result := Img.Px[Min(Img.H - 1, (iy * Img.H) div rows) * Img.W + Min(Img.W - 1, (ix * Img.W) div cols)] and $FFFFFF;
  end;

  procedure AddRun(cc: Cardinal; x0, y0, w0: Double);
  var j: Integer; s: TStringBuilder;
  begin
    j := runs.IndexOf(IntToHex(cc, 6));
    if j < 0 then j := runs.AddObject(IntToHex(cc, 6), TStringBuilder.Create);
    s := TStringBuilder(runs.Objects[j]);
    s.Append('M').Append(N(x0)).Append(' ').Append(N(y0)).Append(' h').Append(N(w0)).Append(' v').Append(N(ch))
      .Append(' h').Append(N(-w0)).Append(' Z ');
  end;

begin
  Result := '';
  // tile size in output pixels
  if F.ImgRel then
  begin
    tw := (MaxX - MinX) * F.ImgW / 100; th := (MaxY - MinY) * F.ImgH / 100;
  end
  else
  begin
    sc := 1;
    if (F.ImgFlags and 4) <> 0 then sc := Sqrt(Abs(Det));
    tw := F.ImgW * SX * sc; th := F.ImgH * SX * sc;
  end;
  if (tw < 0.5) or (th < 0.5) then Exit;
  key := IntToStr(F.Kind) + '_' + IntToStr(F.ImgId) + '_' + N(tw) + '_' + N(th) + '_' +
    IntToHex(Doc.Rgb(F.Color1), 6) + IntToHex(Doc.Rgb(F.Color2), 6);
  i := FPatKeys.IndexOfName(key);
  if i >= 0 then Exit('url(#' + FPatKeys.ValueFromIndex[i] + ')');
  runs := TStringList.Create;
  sb := TStringBuilder.Create;
  try
    if F.Kind in [7, 8] then
    begin
      if not Doc.PatternIdx.TryGetValue(F.ImgId, k) then Exit;
      P := Doc.Patterns[k];
      cols := P.W; rows := P.H;
      fg := Doc.Rgb(F.Color1); bg := Doc.Rgb(F.Color2);
      cw := tw / cols; ch := th / rows;
      for y := 0 to rows - 1 do
      begin
        x := 0;
        while x < cols do
        begin
          k := y * ((P.W + 7) div 8) + x div 8;
          bit := (k < Length(P.Bits)) and ((P.Bits[k] and ($80 shr (x and 7))) <> 0);
          run := 1;
          while x + run < cols do
          begin
            k := y * ((P.W + 7) div 8) + (x + run) div 8;
            if ((k < Length(P.Bits)) and ((P.Bits[k] and ($80 shr ((x + run) and 7))) <> 0)) <> bit then Break;
            Inc(run);
          end;
          if bit then c := bg else c := fg;
          AddRun(c, x * cw, y * ch, run * cw);
          Inc(x, run);
        end;
      end;
    end
    else
    begin
      if not Doc.ImageIdx.TryGetValue(F.ImgId, k) then Exit;
      Img := Doc.Images[k];
      if (Img.W <= 0) or (Img.H <= 0) then Exit;
      cols := Min(Img.W, Max(1, Min(64, Round(tw))));
      rows := Min(Img.H, Max(1, Min(64, Round(th))));
      cw := tw / cols; ch := th / rows;
      for y := 0 to rows - 1 do
      begin
        x := 0;
        while x < cols do
        begin
          c := Sample(x, y);
          run := 1;
          while (x + run < cols) and (Sample(x + run, y) = c) do Inc(run);
          AddRun(c, x * cw, y * ch, run * cw);
          Inc(x, run);
        end;
      end;
    end;
    id := NewId('pat');
    sb.Append('<pattern id="' + id + '" patternUnits="userSpaceOnUse" x="' + N(MinX) + '" y="' + N(MaxY) +
      '" width="' + N(tw) + '" height="' + N(th) + '">');
    for i := 0 to runs.Count - 1 do
    begin
      d := Trim(TStringBuilder(runs.Objects[i]).ToString);
      sb.Append('<path d="' + d + '" fill="#' + runs[i] + '" stroke="none"/>');
    end;
    sb.Append('</pattern>');
    Defs.Append(sb.ToString).Append(#10);
    FPatKeys.Add(key + '=' + id);
    Result := 'url(#' + id + ')';
  finally
    for i := 0 to runs.Count - 1 do runs.Objects[i].Free;
    runs.Free;
    sb.Free;
  end;
end;

function TCdrPainter.StrokeAttr: string;
var
  O: TCdrOutl;
  w, sc, sx0, sy0, x0, y0, x1, y1: Double;
  i: Integer;
  dash: string;
begin
  O := Outl;
  if (O.LineType = -1) and (StyleId <> 0) then O := Doc.GetStyle(StyleId).Outl;
  if (O.LineType = -1) or ((O.LineType and 1) <> 0) then Exit(' stroke="none"');
  if (O.LineType and 6) = 0 then
    Exit(' stroke="#000000" stroke-width="0.5"');
  sc := 1;
  if (O.LineType and $20) <> 0 then
  begin
    x0 := 0; y0 := 0; Apply(x0, y0);
    x1 := 1; y1 := 0; Apply(x1, y1); sx0 := Abs(x1 - x0);
    x1 := 0; y1 := 1; Apply(x1, y1); sy0 := Abs(y1 - y0);
    sc := Max(sx0, sy0);
  end;
  if O.Stretch > 0 then sc := sc * O.Stretch;
  w := O.Width * sc * SX;
  if w < 0.35 then w := 0.35;
  Result := ' stroke="' + Hex(Doc.Rgb(O.Color)) + '" stroke-width="' + N(w) + '"';
  case O.Caps of
    1: Result := Result + ' stroke-linecap="round"';
    2: Result := Result + ' stroke-linecap="square"';
  end;
  case O.Join of
    1: Result := Result + ' stroke-linejoin="round"';
    2: Result := Result + ' stroke-linejoin="bevel"';
  end;
  if ((O.LineType and 4) <> 0) and (Length(O.Dash) >= 2) then
  begin
    dash := '';
    for i := 0 to High(O.Dash) do
    begin
      if i > 0 then dash := dash + ' ';
      dash := dash + N(Max(O.Dash[i], 0.1) * w);
    end;
    Result := Result + ' stroke-dasharray="' + dash + '"';
  end;
end;

// bitmap objects: runs of equal colour, each run a parallelogram under the
// object transform; cropped to the object's path
function TCdrPainter.BitmapElem(const D: string; DEmpty: Boolean): string;
var
  k, cols, rows, i, j, run: Integer;
  Img: TCdrImage;
  left, right, top, bottom, cw, ch, f, ax, ay, bx, by, cx, cy, ddx, ddy: Double;
  c, cc: Cardinal;
  runs: TDictionary<Cardinal, TStringBuilder>;
  order: array of Cardinal;
  sb, s: TStringBuilder;
  id: string;

  // alpha in four steps, kept in the top byte of the run key
  function Quant(v: Cardinal): Cardinal;
  var a: Cardinal;
  begin
    a := v shr 24;
    if a < 32 then Exit(0);
    a := (a + 32) div 64;
    if a > 4 then a := 4;
    if a = 0 then a := 1;
    Result := (v and $FFFFFF) or (a shl 24);
  end;

  function Sample(ix, iy: Integer): Cardinal;
  begin
    Result := Img.Px[Min(Img.H - 1, Trunc((iy + 0.5) * Img.H / rows)) * Img.W + Min(Img.W - 1, Trunc((ix + 0.5) * Img.W / cols))];
  end;

begin
  Result := '';
  if not Doc.ImageIdx.TryGetValue(BmpId, k) then Exit;
  Img := Doc.Images[k];
  if (Img.W <= 0) or (Img.H <= 0) then Exit;
  left := Min(BmpX1, BmpX2); right := Max(BmpX1, BmpX2);
  bottom := Min(BmpY1, BmpY2); top := Max(BmpY1, BmpY2);
  if (right - left < 1e-9) or (top - bottom < 1e-9) then Exit;
  // output size of the bitmap decides the sampling grid
  MapPt(left, top, ax, ay); MapPt(right, top, bx, by); MapPt(left, bottom, cx, cy);
  cols := Max(1, Min(Img.W, Ceil(Hypot(bx - ax, by - ay))));
  rows := Max(1, Min(Img.H, Ceil(Hypot(cx - ax, cy - ay))));
  if Int64(cols) * rows > MAX_BITMAP_CELLS then
  begin
    f := Sqrt(MAX_BITMAP_CELLS / (Int64(cols) * rows));
    cols := Max(1, Trunc(cols * f)); rows := Max(1, Trunc(rows * f));
  end;
  cw := (right - left) / cols; ch := (top - bottom) / rows;
  runs := TDictionary<Cardinal, TStringBuilder>.Create;
  order := nil;
  sb := TStringBuilder.Create;
  try
    for j := 0 to rows - 1 do
    begin
      i := 0;
      while i < cols do
      begin
        c := Quant(Sample(i, j));
        run := 1;
        while (i + run < cols) and (Quant(Sample(i + run, j)) = c) do Inc(run);
        if (c shr 24) <> 0 then
        begin
          cc := c;
          if not runs.TryGetValue(cc, s) then
          begin
            s := TStringBuilder.Create;
            runs.Add(cc, s);
            SetLength(order, Length(order) + 1);
            order[High(order)] := cc;
          end;
          // a slight overlap hides the seams between cells
          MapPt(left + i * cw, top - j * ch, ax, ay);
          MapPt(left + (i + run) * cw, top - j * ch, bx, by);
          MapPt(left + i * cw, top - (j + 1) * ch, cx, cy);
          ddx := (bx - ax) + (cx - ax); ddy := (by - ay) + (cy - ay);
          s.Append('M').Append(N(ax)).Append(' ').Append(N(ay)).Append(' l').Append(N(bx - ax)).Append(' ').Append(N(by - ay))
            .Append(' l').Append(N(cx - ax)).Append(' ').Append(N(cy - ay)).Append(' l').Append(N(ax - bx)).Append(' ')
            .Append(N(ay - by)).Append(' Z ');
        end;
        Inc(i, run);
      end;
    end;
    if not DEmpty and (D <> '') then
    begin
      id := NewId('bc');
      Defs.Append('<clipPath id="' + id + '"><path d="' + D + '"/></clipPath>').Append(#10);
      sb.Append('<g clip-path="url(#' + id + ')">');
    end;
    for k := 0 to High(order) do
      sb.Append('<path d="' + Trim(runs[order[k]].ToString) + '" fill="' + Hex(order[k] and $FFFFFF) + '" stroke="none"' +
        IfThenStr((Opacity < 1) or ((order[k] shr 24) < 4), ' fill-opacity="' + N(Opacity * (order[k] shr 24) / 4) + '"', '') + '/>');
    if not DEmpty and (D <> '') then sb.Append('</g>');
    Result := sb.ToString;
  finally
    for k := 0 to High(order) do runs[order[k]].Free;
    runs.Free;
    sb.Free;
  end;
end;

// artistic and paragraph text
function TCdrPainter.TextElem: string;
type
  TLineRun = record
    Text: string;
    Style: TCdrStyle;
  end;
  TLine = array of TLineRun;
var
  k, pIdx, ri, li, i, nn, ln, cut: Integer;
  wpart: UnicodeString;
  lines: array of TLine;
  cur: TLine;
  s, part, face, st, anchor: string;
  ks, ang, deg, lineH, maxSz, y, x, ox, oy, sz, width, cw, used: Double;
  c: Cardinal;
  x0, y0, x1, y1: Double;
  run: TLineRun;
  sb: TStringBuilder;

  procedure PushLine;
  var q: Integer;
  begin
    q := Length(lines);
    SetLength(lines, q + 1);
    lines[q] := cur;
    cur := nil;
  end;

  procedure AddToLine(const T: string; const S: TCdrStyle);
  var q: Integer;
  begin
    q := Length(cur);
    SetLength(cur, q + 1);
    cur[q].Text := T;
    cur[q].Style := S;
  end;

  function StyleSize(const S: TCdrStyle): Double;
  begin
    if S.Size > 1e-6 then Result := S.Size else Result := 12 / 72;
  end;

  function RunColor(const S: TCdrStyle): Cardinal;
  begin
    if S.Fill.Kind = 1 then Result := Doc.Rgb(S.Fill.Color1)
    else if (S.Fill.Kind = 2) and (Length(S.Fill.Stops) > 0) then Result := Doc.Rgb(S.Fill.Stops[0].Color)
    else Result := 0;
  end;

begin
  Result := '';
  if not Doc.TextIdx.TryGetValue(TextId, k) then Exit;
  // split the paragraphs into lines at CR / LF
  lines := nil; cur := nil;
  for pIdx := 0 to High(Doc.Texts[k].Paras) do
  begin
    for ri := 0 to High(Doc.Texts[k].Paras[pIdx]) do
    begin
      s := Doc.Texts[k].Paras[pIdx][ri].Text;
      while s <> '' do
      begin
        i := Pos(#13, s); nn := Pos(#10, s);
        if (nn > 0) and ((i = 0) or (nn < i)) then i := nn;
        if i = 0 then begin AddToLine(s, Doc.Texts[k].Paras[pIdx][ri].Style); Break; end;
        part := Copy(s, 1, i - 1);
        if part <> '' then AddToLine(part, Doc.Texts[k].Paras[pIdx][ri].Style);
        PushLine;
        // keep the style of an empty line for its height
        if Length(lines[High(lines)]) = 0 then
        begin
          SetLength(lines[High(lines)], 1);
          lines[High(lines)][0].Text := '';
          lines[High(lines)][0].Style := Doc.Texts[k].Paras[pIdx][ri].Style;
        end;
        if (i < Length(s)) and (s[i] = #13) and (s[i + 1] = #10) then Inc(i);
        Delete(s, 1, i);
      end;
    end;
    if Length(cur) > 0 then PushLine;
  end;
  if Length(lines) = 0 then Exit;
  // paragraph frames: wrap long lines by an estimated character width
  if (TextKind = 2) and (TextW > 0) then
  begin
    i := 0;
    while i <= High(lines) do
    begin
      width := 0;
      for ri := 0 to High(lines[i]) do
      begin
        cw := 0.52 * StyleSize(lines[i][ri].Style);
        width := width + Length(UTF8Decode(lines[i][ri].Text)) * cw;
      end;
      if (width > TextW) and (Length(lines[i]) = 1) then
      begin
        s := lines[i][0].Text;
        cw := 0.52 * StyleSize(lines[i][0].Style);
        nn := Max(1, Trunc(TextW / cw));
        wpart := UTF8Decode(s);
        cut := Min(nn, Length(wpart));
        while (cut > 1) and (wpart[cut] <> ' ') do Dec(cut);
        if cut <= 1 then cut := Min(nn, Length(wpart));
        run := lines[i][0];
        lines[i][0].Text := UTF8Encode(TrimRight(Copy(wpart, 1, cut)));
        SetLength(lines, Length(lines) + 1);
        for ln := High(lines) downto i + 2 do lines[ln] := lines[ln - 1];
        SetLength(lines[i + 1], 1);
        lines[i + 1][0] := run;
        lines[i + 1][0].Text := UTF8Encode(TrimLeft(Copy(wpart, cut + 1, MaxInt)));
      end;
      Inc(i);
    end;
  end;
  // direction and scale of the text from the transform
  x0 := 0; y0 := 0; Apply(x0, y0);
  x1 := 1; y1 := 0; Apply(x1, y1);
  ang := ArcTan2(y1 - y0, x1 - x0);
  deg := -RadToDeg(ang);
  ks := Sqrt(Abs(Det));
  if ks <= 1e-9 then ks := 1;
  sb := TStringBuilder.Create;
  try
    y := TextY;
    for li := 0 to High(lines) do
    begin
      maxSz := 0;
      for ri := 0 to High(lines[li]) do maxSz := Max(maxSz, StyleSize(lines[li][ri].Style));
      lineH := maxSz * 1.2;
      if TextKind = 2 then
      begin
        if li = 0 then y := TextY - maxSz else y := y - lineH;
        case lines[li][0].Style.Align of
          2: x := TextX + TextW / 2;
          3: x := TextX + TextW;
        else
          x := TextX;
        end;
      end
      else
      begin
        if li > 0 then y := y - lineH;
        x := TextX;
      end;
      // one <text> per run (SimpleSVG does not place <tspan> runs); with
      // several runs on a line their widths are estimated
      anchor := '';
      if Length(lines[li]) = 1 then
        case lines[li][0].Style.Align of
          2: anchor := ' text-anchor="middle"';
          3: anchor := ' text-anchor="end"';
        end
      else
      begin
        width := 0;
        for ri := 0 to High(lines[li]) do
          width := width + Length(UTF8Decode(lines[li][ri].Text)) * 0.52 * StyleSize(lines[li][ri].Style);
        case lines[li][0].Style.Align of
          2: x := x - width / 2;
          3: x := x - width;
        end;
      end;
      for ri := 0 to High(lines[li]) do
      begin
        run := lines[li][ri];
        if run.Text = '' then Continue;
        sz := StyleSize(run.Style) * SX * ks;
        face := run.Style.Font;
        if face = '' then face := 'Arial';
        c := RunColor(run.Style);
        MapPt(x, y, ox, oy);
        st := '<text x="' + N(ox) + '" y="' + N(oy) + '"' + anchor + ' font-family="' + XmlEscape(face) +
          '" font-size="' + N(EnsureRange(sz, 0.5, 1e5)) + '" fill="' + Hex(c) + '"';
        if Opacity < 1 then st := st + ' fill-opacity="' + N(Opacity) + '"';
        if Abs(deg) > 0.01 then
          st := st + ' transform="rotate(' + N(deg) + ' ' + N(ox) + ' ' + N(oy) + ')"';
        sb.Append(st + ' xml:space="preserve">' + XmlEscape(run.Text) + '</text>');
        x := x + Length(UTF8Decode(run.Text)) * 0.52 * StyleSize(run.Style);
      end;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function TCdrPainter.ObjectElem: string;
var
  D, fillA, op, strokeA, rule: string;
  empty: Boolean;
  mnx, mny, mxx, mxy: Double;
  F: TCdrFill;
  url: string;
begin
  Result := '';
  if IsPolygon and HasPolyTrafo then MakePolygon;
  if IsSpline and (Length(SplPts) > 0) then MakeSpline;
  D := BuildD(empty, mnx, mny, mxx, mxy);
  if HasBmp then
  begin
    Result := BitmapElem(D, empty);
    Exit;
  end;
  if (D <> '') and not empty then
  begin
    F := Fill;
    if (F.Kind = -1) and (StyleId <> 0) then F := Doc.GetStyle(StyleId).Fill;
    if Opacity < 1 then op := ' fill-opacity="' + N(Opacity) + '"' else op := '';
    fillA := ' fill="none"';
    case F.Kind of
      1: fillA := ' fill="' + Hex(Doc.Rgb(F.Color1)) + '"' + op;
      2: if Length(F.Stops) = 1 then fillA := ' fill="' + Hex(Doc.Rgb(F.Stops[0].Color)) + '"' + op
         else if Length(F.Stops) >= 2 then
         begin
           Result := GradientElem(D, F, mnx, mny, mxx, mxy);
           fillA := ' fill="none"';
         end;
      7, 8, 9, 11:
         begin
           url := PatternUrl(F, mnx, mny, mxx, mxy);
           if url <> '' then fillA := ' fill="' + url + '"' + op
           else if F.Kind in [7, 8] then fillA := ' fill="' + Hex(Doc.Rgb(F.Color2)) + '"' + op;
         end;
    end;
    strokeA := StrokeAttr;
    if (fillA = ' fill="none"') and (Pos('stroke="none"', strokeA) > 0) then
    else
    begin
      if IsPolygon then rule := 'nonzero' else rule := 'evenodd';
      Result := Result + '<path d="' + D + '"' + fillA + ' fill-rule="' + rule + '"' + strokeA + '/>';
    end;
  end;
  if TextKind <> 0 then Result := Result + TextElem;
end;

procedure TCdrPainter.Flush;
var s: string;
begin
  if not ObjActive then Exit;
  if DrawPage and not IgnorePage and (VectLevel = 0) then
  begin
    try
      s := ObjectElem;
    except
      s := '';
    end;
    if s <> '' then AddItem(okElem, s);
  end;
  ResetObject;
end;

procedure TCdrPainter.OnList(const ListType: AnsiString; Level: Integer; Start: Boolean);
var
  n: Integer;
  D, id, cont: string;
  empty: Boolean;
  a, b, c, d2: Double;
begin
  if Start then
  begin
    if ListType = 'page' then
    begin
      Flush;
      Inc(PageIndex);
      PageProps := True;
      IgnorePage := False;
      PageLevel := Level;
      DrawPage := not PageDone;
      if DrawPage and (PageIndex < Length(Doc.Pages)) then
      begin
        PageW := Doc.Pages[PageIndex].W; PageH := Doc.Pages[PageIndex].H;
      end;
    end
    else if ListType = 'obj ' then
    begin
      Flush;
      ObjActive := True;
      ObjLevel := Level;
    end
    else if ListType = 'vect' then
    begin
      Flush;
      if VectLevel = 0 then VectLevel := Level;
    end
    else if ListType = 'clpt' then
    begin
      // PowerClip: the contents are drawn clipped to the container (the
      // object that holds this list); the container itself goes below them
      cont := '';
      id := '';
      if ObjActive and DrawPage and not IgnorePage and (VectLevel = 0) then
      begin
        D := BuildD(empty, a, b, c, d2);
        if (D <> '') and not empty then
        begin
          id := NewId('pc');
          Defs.Append('<clipPath id="' + id + '"><path d="' + D + '"/></clipPath>').Append(#10);
        end;
        try
          cont := ObjectElem;
        except
          cont := '';
        end;
      end;
      ResetObject;
      n := Length(Clips);
      SetLength(Clips, n + 1);
      Clips[n].Level := Level;
      Clips[n].Id := id;
      Clips[n].Container := cont;
      if id <> '' then AddItem(okOpen, id);
    end;
  end
  else
  begin
    if ObjActive and (Level <= ObjLevel) then Flush;
    if (ListType = 'clpt') and (Length(Clips) > 0) and (Clips[High(Clips)].Level = Level) then
    begin
      Flush;
      if Clips[High(Clips)].Id <> '' then AddItem(okClose, Clips[High(Clips)].Id);
      if Clips[High(Clips)].Container <> '' then AddItem(okElem, Clips[High(Clips)].Container);
      SetLength(Clips, Length(Clips) - 1);
    end;
    if (VectLevel > 0) and (Level <= VectLevel) then VectLevel := 0;
    if (ListType = 'page') and (Level <= PageLevel) then
    begin
      Flush;
      if DrawPage and not IgnorePage and (Length(Items) > 0) then PageDone := True;
      DrawPage := False;
    end;
  end;
end;

procedure TCdrPainter.OnChunk(const FourCC: AnsiString; const B: TBytes; Pos, Len, Level: Integer);
var
  R: TRd;
  fl: Cardinal;
begin
  if not Doc.ChunkData(B, Pos, Len, R) then Exit;
  try
    if FourCC = 'vrsn' then Doc.SetVersion(R.U16)
    else if FourCC = 'flgs' then
    begin
      fl := R.U32;
      if PageProps then
      begin
        if ((fl and $00FF0000) <> 0) and (Doc.Version >= 400) then IgnorePage := True;
        PageProps := False;
      end;
    end
    else if FourCC = 'spnd' then Spnd := Doc.Uns(R)
    else if not ObjActive then Exit
    else if (FourCC = 'loda') or (FourCC = 'lobj') then ReadLoda(R)
    else if FourCC = 'trfd' then ReadTrfd(R)
    else if FourCC = 'ppdt' then ReadPpdt(R);
  except
    // a damaged record is skipped
  end;
end;

// Items are in file order (top-most object first): written in reverse, with
// the clip groups' ends swapped.
function TCdrPainter.BuildSvg(W, H: Integer): string;
var
  sb: TStringBuilder;
  i: Integer;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append('<?xml version="1.0" encoding="UTF-8"?>').Append(#10);
    sb.Append('<svg xmlns="http://www.w3.org/2000/svg" width="' + IntToStr(W) + '" height="' + IntToStr(H) +
      '" viewBox="0 0 ' + IntToStr(W) + ' ' + IntToStr(H) + '">').Append(#10);
    if Defs.Length > 0 then sb.Append('<defs>').Append(#10).Append(Defs.ToString).Append('</defs>').Append(#10);
    for i := High(Items) downto 0 do
      case Items[i].Kind of
        okElem: sb.Append(Items[i].S).Append(#10);
        okClose: sb.Append('<g clip-path="url(#' + Items[i].S + ')">').Append(#10);
        okOpen: sb.Append('</g>').Append(#10);
      end;
    sb.Append('</svg>').Append(#10);
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

// ------------------------------ entry points -------------------------------

function IsCdr(const Data: TBytes): Boolean;
var L: TZipEntries;
begin
  Result := False;
  if Length(Data) < 12 then Exit;
  if (Data[0] = Ord('R')) and (Data[1] = Ord('I')) and (Data[2] = Ord('F')) and (Data[3] = Ord('F')) then
    Exit(((Data[8] = Ord('C')) or (Data[8] = Ord('c'))) and ((Data[9] = Ord('D')) or (Data[9] = Ord('d'))) and
      ((Data[10] = Ord('R')) or (Data[10] = Ord('r'))));
  if (Data[0] = Ord('P')) and (Data[1] = Ord('K')) then
  begin
    L := ZipList(Data);
    Result := (ZipFind(L, 'content/root.dat') >= 0) or (ZipFind(L, 'content/riffData.cdr') >= 0);
  end;
end;

function CdrToSvg(const Data: TBytes; out Width, Height: Integer): string;
var
  Doc: TCdrDoc;
  SP: TCdrStylesPass;
  PP: TCdrPainter;
  L: TZipEntries;
  i, k, n: Integer;
  list: TBytes;
  names: TStringList;
  s: string;
  w, h, pw, ph: Double;
begin
  Width := 0; Height := 0; Result := '';
  if not IsCdr(Data) then raise ECdrError.Create('CDR: not a CorelDRAW file');
  Doc := TCdrDoc.Create;
  try
    if Data[0] = Ord('P') then
    begin
      L := ZipList(Data);
      i := ZipFind(L, 'content/root.dat');
      if i >= 0 then
      begin
        Doc.Root := ZipRead(Data, L[i]);
        k := ZipFind(L, 'content/dataFileList.dat');
        if k >= 0 then
        begin
          list := ZipRead(Data, L[k]);
          names := TStringList.Create;
          try
            names.Text := TEncoding.ANSI.GetString(list);
            SetLength(Doc.Streams, names.Count);
            n := 0;
            for k := 0 to names.Count - 1 do
            begin
              s := Trim(names[k]);
              if s = '' then Continue;
              i := ZipFind(L, 'content/data/' + s);
              if i >= 0 then Doc.Streams[n] := ZipRead(Data, L[i]) else Doc.Streams[n] := nil;
              Inc(n);
            end;
            SetLength(Doc.Streams, n);
          finally
            names.Free;
          end;
        end;
      end
      else
      begin
        i := ZipFind(L, 'content/riffData.cdr');
        if i >= 0 then Doc.Root := ZipRead(Data, L[i]);
      end;
    end
    else Doc.Root := Data;
    if (Length(Doc.Root) < 12) or (FourCCAt(Doc.Root, 0) <> 'RIFF') then
      raise ECdrError.Create('CDR: no drawing data');
    Doc.SetVersion(GetCdrVersion(Doc.Root[11]));
    if Doc.Version < 300 then raise ECdrError.Create('CDR: unsupported version');

    // pass 1: resources
    SP := TCdrStylesPass.Create;
    try
      SP.Doc := Doc;
      WalkRiff(Doc, Doc.Root, 0, Length(Doc.Root), 0, nil, SP.OnChunk, SP.OnList);
    finally
      SP.Free;
    end;
    Doc.SetVersion(GetCdrVersion(Doc.Root[11]));

    // the first page that is drawn (master pages are skipped by their flags)
    PP := TCdrPainter.Create(Doc);
    try
      pw := Doc.PageW; ph := Doc.PageH;
      if Length(Doc.Pages) > 0 then
      begin
        pw := Doc.Pages[0].W; ph := Doc.Pages[0].H;
      end;
      if (pw < 0.01) or (ph < 0.01) then begin pw := 8.5; ph := 11; end;
      // pages usually share one size; the drawn page's own size is used while painting
      w := pw * PX_PER_INCH; h := ph * PX_PER_INCH;
      if Max(w, h) > MAX_SIDE then
      begin
        PP.SX := PX_PER_INCH * MAX_SIDE / Max(w, h);
        w := pw * PP.SX; h := ph * PP.SX;
      end;
      PP.PageW := pw; PP.PageH := ph;
      WalkRiff(Doc, Doc.Root, 0, Length(Doc.Root), 0, nil, PP.OnChunk, PP.OnList);
      PP.Flush;
      Width := Max(1, Round(PP.PageW * PP.SX));
      Height := Max(1, Round(PP.PageH * PP.SX));
      Result := PP.BuildSvg(Width, Height);
    finally
      PP.Free;
    end;
  finally
    Doc.Free;
  end;
end;
