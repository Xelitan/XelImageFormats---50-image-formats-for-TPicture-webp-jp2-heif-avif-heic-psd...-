unit Av1.LoopFilter;

// AV1 deblocking loop filter (loopfilter_tmpl.c loop_filter + lf LUT). 8-bit.
// The per-edge kernel filters a 4-sample run across a transform/block boundary;
// the caller iterates edges and supplies E/I/H (from the sharpness LUT) and the
// filter width.

{$mode delphi}{$H+}
{$RANGECHECKS OFF}{$OVERFLOWCHECKS OFF}

interface

type
  TLfLut = record e, i: array[0..63] of Integer; end;

procedure CalcEih(out Lut: TLfLut; sharp: Integer);
// Filter one 4-sample run. Dst points at q0 of the first sample; stridea steps
// along the edge (4 samples), strideb crosses it (p/q neighbours).
procedure LfEdge(Dst: PWord; E, Ilim, H, stridea, strideb, wd: Integer);

var
  LfMax: Integer = 255;      // (1 shl BitDepth)-1
  LfBdShift: Integer = 0;    // BitDepth-8
  LfFlatLim: Integer = 1;    // 1 shl (BitDepth-8) : flatness threshold

implementation

function IMin(a, b: Integer): Integer; inline; begin if a < b then Result := a else Result := b; end;
function IMax(a, b: Integer): Integer; inline; begin if a > b then Result := a else Result := b; end;
function ClipPx(v: Integer): Integer; inline;
begin if v < 0 then Result := 0 else if v > LfMax then Result := LfMax else Result := v; end;
function ClipDiff(v: Integer): Integer; inline;
var lo, hi: Integer;
begin lo := -(128 shl LfBdShift); hi := (128 shl LfBdShift) - 1;
  if v < lo then Result := lo else if v > hi then Result := hi else Result := v; end;

procedure CalcEih(out Lut: TLfLut; sharp: Integer);
var level, limit: Integer;
begin
  for level := 0 to 63 do
  begin
    limit := level;
    if sharp > 0 then
    begin
      limit := limit shr ((sharp + 3) shr 2);
      limit := IMin(limit, 9 - sharp);
    end;
    limit := IMax(limit, 1);
    Lut.i[level] := limit;
    Lut.e[level] := 2 * (level + 2) + limit;
  end;
end;

procedure LfEdge(Dst: PWord; E, Ilim, H, stridea, strideb, wd: Integer);
var
  i, p6,p5,p4,p3,p2,p1,p0,q0,q1,q2,q3,q4,q5,q6: Integer;
  fm, flat8out, flat8in, hev, f, f1, f2: Integer;
  d: PWord;
begin
  for i := 0 to 3 do
  begin
    d := Dst + i * stridea;
    p1 := d[strideb*(-2)]; p0 := d[strideb*(-1)];
    q0 := d[0]; q1 := d[strideb];
    fm := Ord((Abs(p1-p0) <= Ilim) and (Abs(q1-q0) <= Ilim) and
              (Abs(p0-q0)*2 + (Abs(p1-q1) shr 1) <= E));
    p2 := 0; q2 := 0; p3 := 0; q3 := 0;
    if wd > 4 then
    begin
      p2 := d[strideb*(-3)]; q2 := d[strideb*2];
      if (Abs(p2-p1) > Ilim) or (Abs(q2-q1) > Ilim) then fm := 0;
      if wd > 6 then
      begin
        p3 := d[strideb*(-4)]; q3 := d[strideb*3];
        if (Abs(p3-p2) > Ilim) or (Abs(q3-q2) > Ilim) then fm := 0;
      end;
    end;
    if fm = 0 then Continue;

    flat8out := 0; flat8in := 0;
    p6:=0;p5:=0;p4:=0;q4:=0;q5:=0;q6:=0;
    if wd >= 16 then
    begin
      p6 := d[strideb*(-7)]; p5 := d[strideb*(-6)]; p4 := d[strideb*(-5)];
      q4 := d[strideb*4]; q5 := d[strideb*5]; q6 := d[strideb*6];
      flat8out := Ord((Abs(p6-p0)<=LfFlatLim) and (Abs(p5-p0)<=LfFlatLim) and (Abs(p4-p0)<=LfFlatLim) and
                      (Abs(q4-q0)<=LfFlatLim) and (Abs(q5-q0)<=LfFlatLim) and (Abs(q6-q0)<=LfFlatLim));
    end;
    if wd >= 6 then
      flat8in := Ord((Abs(p2-p0)<=LfFlatLim) and (Abs(p1-p0)<=LfFlatLim) and (Abs(q1-q0)<=LfFlatLim) and (Abs(q2-q0)<=LfFlatLim));
    if wd >= 8 then
      if (Abs(p3-p0) > LfFlatLim) or (Abs(q3-q0) > LfFlatLim) then flat8in := 0;

    if (wd >= 16) and (flat8out <> 0) and (flat8in <> 0) then
    begin
      d[strideb*(-6)] := Word((p6*7+p5*2+p4*2+p3+p2+p1+p0+q0+8) shr 4);
      d[strideb*(-5)] := Word((p6*5+p5*2+p4*2+p3*2+p2+p1+p0+q0+q1+8) shr 4);
      d[strideb*(-4)] := Word((p6*4+p5+p4*2+p3*2+p2*2+p1+p0+q0+q1+q2+8) shr 4);
      d[strideb*(-3)] := Word((p6*3+p5+p4+p3*2+p2*2+p1*2+p0+q0+q1+q2+q3+8) shr 4);
      d[strideb*(-2)] := Word((p6*2+p5+p4+p3+p2*2+p1*2+p0*2+q0+q1+q2+q3+q4+8) shr 4);
      d[strideb*(-1)] := Word((p6+p5+p4+p3+p2+p1*2+p0*2+q0*2+q1+q2+q3+q4+q5+8) shr 4);
      d[0]            := Word((p5+p4+p3+p2+p1+p0*2+q0*2+q1*2+q2+q3+q4+q5+q6+8) shr 4);
      d[strideb*1]    := Word((p4+p3+p2+p1+p0+q0*2+q1*2+q2*2+q3+q4+q5+q6*2+8) shr 4);
      d[strideb*2]    := Word((p3+p2+p1+p0+q0+q1*2+q2*2+q3*2+q4+q5+q6*3+8) shr 4);
      d[strideb*3]    := Word((p2+p1+p0+q0+q1+q2*2+q3*2+q4*2+q5+q6*4+8) shr 4);
      d[strideb*4]    := Word((p1+p0+q0+q1+q2+q3*2+q4*2+q5*2+q6*5+8) shr 4);
      d[strideb*5]    := Word((p0+q0+q1+q2+q3+q4*2+q5*2+q6*6+8+q6) shr 4);
    end
    else if (wd >= 8) and (flat8in <> 0) then
    begin
      d[strideb*(-3)] := Word((p3*3+2*p2+p1+p0+q0+4) shr 3);
      d[strideb*(-2)] := Word((p3*2+p2+2*p1+p0+q0+q1+4) shr 3);
      d[strideb*(-1)] := Word((p3+p2+p1+2*p0+q0+q1+q2+4) shr 3);
      d[0]            := Word((p2+p1+p0+2*q0+q1+q2+q3+4) shr 3);
      d[strideb*1]    := Word((p1+p0+q0+2*q1+q2+q3*2+4) shr 3);
      d[strideb*2]    := Word((p0+q0+q1+2*q2+q3*3+4) shr 3);
    end
    else if (wd = 6) and (flat8in <> 0) then
    begin
      d[strideb*(-2)] := Word((p2*3+2*p1+2*p0+q0+4) shr 3);
      d[strideb*(-1)] := Word((p2+2*p1+2*p0+2*q0+q1+4) shr 3);
      d[0]            := Word((p1+2*p0+2*q0+2*q1+q2+4) shr 3);
      d[strideb*1]    := Word((p0+2*q0+2*q1+2*q2+q2+4) shr 3);
    end
    else
    begin
      hev := Ord((Abs(p1-p0) > H) or (Abs(q1-q0) > H));
      if hev <> 0 then
      begin
        f := ClipDiff(p1 - q1);
        f := ClipDiff(3*(q0-p0) + f);
        f1 := SarLongint(IMin(f+4, (128 shl LfBdShift)-1), 3);
        f2 := SarLongint(IMin(f+3, (128 shl LfBdShift)-1), 3);
        d[strideb*(-1)] := Word(ClipPx(p0 + f2));
        d[0]            := Word(ClipPx(q0 - f1));
      end
      else
      begin
        f := ClipDiff(3*(q0-p0));
        f1 := SarLongint(IMin(f+4, (128 shl LfBdShift)-1), 3);
        f2 := SarLongint(IMin(f+3, (128 shl LfBdShift)-1), 3);
        d[strideb*(-1)] := Word(ClipPx(p0 + f2));
        d[0]            := Word(ClipPx(q0 - f1));
        f := SarLongint(f1 + 1, 1);
        d[strideb*(-2)] := Word(ClipPx(p1 + f));
        d[strideb*1]    := Word(ClipPx(q1 - f));
      end;
    end;
  end;
end;

end.
