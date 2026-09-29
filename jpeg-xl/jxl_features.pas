{$mode delphi}
unit jxl_features;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// Frame features and blending, ported from libjxl 0.11.2:
//   * blending.cc / alpha.cc      PerformBlending (frames and patches)
//   * dec_patch_dictionary.cc     patch dictionary decode and rendering
//   * dec_noise.cc, stage_noise.cc  noise synthesis (Xorshift128+ noise,
//                                   5x5 high-pass, intensity-dependent add)

interface

uses
  SysUtils, Math, jxl_types, jxl_bits, jxl_ans;

const
  // PatchBlendMode
  PBM_NONE = 0;
  PBM_REPLACE = 1;
  PBM_ADD = 2;
  PBM_MUL = 3;
  PBM_BLEND_ABOVE = 4;
  PBM_BLEND_BELOW = 5;
  PBM_AWADD_ABOVE = 6;
  PBM_AWADD_BELOW = 7;

type
  TPatchBlending = record
    Mode: Integer;
    AlphaChannel: Integer;
    Clamp: Boolean;
  end;
  TPatchBlendingArray = array of TPatchBlending;

  // Channel info needed by blending: which extra channel is alpha and whether
  // it is premultiplied.
  TBlendChannelInfo = record
    IsAlpha: Boolean;
    AlphaAssociated: Boolean;
  end;
  TBlendChannelInfos = array of TBlendChannelInfo;

  TPlaneArray = array of TFloat32Plane;

  // A frame kept for referencing (patches, blending).
  TJxlRefFrame = record
    Valid: Boolean;
    XSize, YSize: Integer;
    Planes: TPlaneArray;          // 3 colour + extra channels
    IbIsInXYB: Boolean;
  end;
  PJxlRefFrame = ^TJxlRefFrame;
  TJxlRefFrames = array[0..3] of TJxlRefFrame;

  TPatchRefPos = record
    Ref, X0, Y0, XSize, YSize: Integer;
  end;
  TPatchPos = record
    X, Y, RefPosIdx: Integer;
  end;

  TPatchDictionary = record
    RefPositions: array of TPatchRefPos;
    Positions: array of TPatchPos;
    Blendings: TPatchBlendingArray;   // (numEC + 1) per position
    BlendingsStride: Integer;
  end;

  TNoiseParams = record
    Lut: array[0..7] of Single;
  end;

// Blends one row segment: out[c][x] for x in [0, xsize); bg/fg/out point at
// the first sample of the segment of each channel (3 colour + extra).
procedure PerformBlending(const bg, fg, outp: array of PSingle; xsize: Integer;
                          const colorBlending: TPatchBlending;
                          const ecBlending: array of TPatchBlending;
                          const ecInfo: TBlendChannelInfos);

procedure DecodePatches(br: TBitReader; var pd: TPatchDictionary;
                        xsize, ysize, numEC: Integer;
                        const refs: TJxlRefFrames);
procedure ApplyPatches(const pd: TPatchDictionary; var planes: TPlaneArray;
                       const refs: TJxlRefFrames; const ecInfo: TBlendChannelInfos);

procedure DecodeNoise(br: TBitReader; var np: TNoiseParams);
function NoiseHasAny(const np: TNoiseParams): Boolean;

// Generates the three random planes (xsize x ysize, upsampled frame size)
// exactly as libjxl's PrepareNoiseInput does per group.
procedure GenerateNoisePlanes(var noise: array of TFloat32Plane;
                              xsize, ysize, groupDim, upsampling,
                              xsizeGroups, ysizeGroups: Integer;
                              visibleIdx, nonvisibleIdx: Cardinal);
procedure ConvolveNoise(var noise: array of TFloat32Plane);
procedure AddNoise(var planes: array of TFloat32Plane;
                   const noise: array of TFloat32Plane;
                   const np: TNoiseParams; ytox, ytob: Single);

implementation

const
  kNumRefPatchContext = 0;
  kReferenceFrameContext = 1;
  kPatchSizeContext = 2;
  kPatchReferencePositionContext = 3;
  kPatchPositionContext = 4;
  kPatchBlendModeContext = 5;
  kPatchOffsetContext = 6;
  kPatchCountContext = 7;
  kPatchAlphaChannelContext = 8;
  kPatchClampContext = 9;
  kNumPatchDictionaryContexts = 10;

function Clamp01(x: Single): Single; inline;
begin
  if x > 1 then Result := 1
  else if x < 0 then Result := 0
  else Result := x;
end;

function UsesAlpha(mode: Integer): Boolean; inline;
begin
  Result := mode in [PBM_BLEND_ABOVE, PBM_BLEND_BELOW, PBM_AWADD_ABOVE, PBM_AWADD_BELOW];
end;

function UsesClamp(mode: Integer): Boolean; inline;
begin
  Result := UsesAlpha(mode) or (mode = PBM_MUL);
end;

function UnpackSignedI(v: Cardinal): Int64; inline;
begin
  if (v and 1) <> 0 then Result := -((Int64(v) + 1) shr 1)
  else Result := Int64(v) shr 1;
end;

// ---------------------------------------------------------------------------
// alpha.cc
// ---------------------------------------------------------------------------
// Single-channel variant; note libjxl's inverted clamp test here.
procedure AlphaBlend1(bg, bga, fg, fga, outp: PSingle; n: Integer;
                      premul, clamp: Boolean);
var
  x: Integer;
  fa, newA, rnewA: Single;
begin
  if (bg = bga) and (fg = fga) then
  begin
    for x := 0 to n - 1 do
    begin
      if clamp then fa := fga[x] else fa := Clamp01(fga[x]);
      outp[x] := 1 - (1 - fa) * (1 - bga[x]);
    end;
  end
  else if premul then
  begin
    for x := 0 to n - 1 do
    begin
      if clamp then fa := fga[x] else fa := Clamp01(fga[x]);
      outp[x] := fg[x] + bg[x] * (1 - fa);
    end;
  end
  else
    for x := 0 to n - 1 do
    begin
      if clamp then fa := fga[x] else fa := Clamp01(fga[x]);
      newA := 1 - (1 - fa) * (1 - bga[x]);
      if newA > 0 then rnewA := 1 / newA else rnewA := 0;
      outp[x] := (fg[x] * fa + bg[x] * bga[x] * (1 - fa)) * rnewA;
    end;
end;

// RGBA variant (bg/fg/out: r, g, b, a).
procedure AlphaBlend4(const bg, fg, outp: array of PSingle; n: Integer;
                      premul, clamp: Boolean);
var
  x, c: Integer;
  fga, newA, rnewA: Single;
begin
  for x := 0 to n - 1 do
  begin
    if clamp then fga := Clamp01(fg[3][x]) else fga := fg[3][x];
    if premul then
    begin
      for c := 0 to 2 do outp[c][x] := fg[c][x] + bg[c][x] * (1 - fga);
      outp[3][x] := 1 - (1 - fga) * (1 - bg[3][x]);
    end
    else
    begin
      newA := 1 - (1 - fga) * (1 - bg[3][x]);
      if newA > 0 then rnewA := 1 / newA else rnewA := 0;
      for c := 0 to 2 do
        outp[c][x] := (fg[c][x] * fga + bg[c][x] * bg[3][x] * (1 - fga)) * rnewA;
      outp[3][x] := newA;
    end;
  end;
end;

procedure AlphaWeightedAdd(bg, fg, fga, outp: PSingle; n: Integer; clamp: Boolean);
var x: Integer;
begin
  if fg = fga then
    Move(bg^, outp^, n * SizeOf(Single))
  else if clamp then
    for x := 0 to n - 1 do outp[x] := bg[x] + fg[x] * Clamp01(fga[x])
  else
    for x := 0 to n - 1 do outp[x] := bg[x] + fg[x] * fga[x];
end;

procedure MulBlend(bg, fg, outp: PSingle; n: Integer; clamp: Boolean);
var x: Integer;
begin
  if clamp then
    for x := 0 to n - 1 do outp[x] := bg[x] * Clamp01(fg[x])
  else
    for x := 0 to n - 1 do outp[x] := bg[x] * fg[x];
end;

procedure PerformBlending(const bg, fg, outp: array of PSingle; xsize: Integer;
                          const colorBlending: TPatchBlending;
                          const ecBlending: array of TPatchBlending;
                          const ecInfo: TBlendChannelInfos);
var
  numEC, i, c, alpha, x: Integer;
  hasAlpha: Boolean;
  tmp: array of array of Single;
  t: array of PSingle;
  b4, f4, o4: array[0..3] of PSingle;

  procedure Copy3(const src: array of PSingle);
  var p: Integer;
  begin
    for p := 0 to 2 do Move(src[p]^, t[p]^, xsize * SizeOf(Single));
  end;

  procedure Add3;
  var p, xx: Integer;
  begin
    for p := 0 to 2 do
      for xx := 0 to xsize - 1 do t[p][xx] := bg[p][xx] + fg[p][xx];
  end;

  procedure BlendWeighted(const bottom, top: array of PSingle);
  begin
    b4[0] := bottom[0]; b4[1] := bottom[1]; b4[2] := bottom[2]; b4[3] := bottom[3 + alpha];
    f4[0] := top[0]; f4[1] := top[1]; f4[2] := top[2]; f4[3] := top[3 + alpha];
    o4[0] := t[0]; o4[1] := t[1]; o4[2] := t[2]; o4[3] := t[3 + alpha];
    AlphaBlend4(b4, f4, o4, xsize, ecInfo[alpha].AlphaAssociated, colorBlending.Clamp);
  end;

  procedure AddWeighted(const bottom, top: array of PSingle);
  var p: Integer;
  begin
    for p := 0 to 2 do
      AlphaWeightedAdd(bottom[p], top[p], top[3 + alpha], t[p], xsize, colorBlending.Clamp);
  end;

begin
  if xsize <= 0 then Exit;
  numEC := Length(ecInfo);
  hasAlpha := False;
  for i := 0 to numEC - 1 do
    if ecInfo[i].IsAlpha then begin hasAlpha := True; Break; end;
  SetLength(tmp, 3 + numEC);
  SetLength(t, 3 + numEC);
  for i := 0 to 2 + numEC do
  begin
    SetLength(tmp[i], xsize);
    t[i] := @tmp[i][0];
  end;
  for i := 0 to numEC - 1 do
  begin
    c := 3 + i;
    case ecBlending[i].Mode of
      PBM_ADD:
        for x := 0 to xsize - 1 do t[c][x] := bg[c][x] + fg[c][x];
      PBM_BLEND_ABOVE:
        begin
          alpha := ecBlending[i].AlphaChannel;
          AlphaBlend1(bg[c], bg[3 + alpha], fg[c], fg[3 + alpha], t[c], xsize,
                      ecInfo[alpha].AlphaAssociated, ecBlending[i].Clamp);
        end;
      PBM_BLEND_BELOW:
        begin
          alpha := ecBlending[i].AlphaChannel;
          AlphaBlend1(fg[c], fg[3 + alpha], bg[c], bg[3 + alpha], t[c], xsize,
                      ecInfo[alpha].AlphaAssociated, ecBlending[i].Clamp);
        end;
      PBM_AWADD_ABOVE:
        begin
          alpha := ecBlending[i].AlphaChannel;
          AlphaWeightedAdd(bg[c], fg[c], fg[3 + alpha], t[c], xsize, ecBlending[i].Clamp);
        end;
      PBM_AWADD_BELOW:
        begin
          alpha := ecBlending[i].AlphaChannel;
          AlphaWeightedAdd(fg[c], bg[c], bg[3 + alpha], t[c], xsize, ecBlending[i].Clamp);
        end;
      PBM_MUL:
        MulBlend(bg[c], fg[c], t[c], xsize, ecBlending[i].Clamp);
      PBM_REPLACE:
        Move(fg[c]^, t[c]^, xsize * SizeOf(Single));
    else  // PBM_NONE
      Move(bg[c]^, t[c]^, xsize * SizeOf(Single));
    end;
  end;
  alpha := colorBlending.AlphaChannel;
  case colorBlending.Mode of
    PBM_ADD: Add3;
    PBM_AWADD_ABOVE: if hasAlpha then AddWeighted(bg, fg) else Add3;
    PBM_AWADD_BELOW: if hasAlpha then AddWeighted(fg, bg) else Add3;
    PBM_BLEND_ABOVE: if hasAlpha then BlendWeighted(bg, fg) else Copy3(fg);
    PBM_BLEND_BELOW: if hasAlpha then BlendWeighted(fg, bg) else Copy3(fg);
    PBM_MUL:
      for c := 0 to 2 do MulBlend(bg[c], fg[c], t[c], xsize, colorBlending.Clamp);
    PBM_REPLACE: Copy3(fg);
  else
    Copy3(bg);
  end;
  for i := 0 to 2 + numEC do
    Move(t[i]^, outp[i]^, xsize * SizeOf(Single));
end;

// ---------------------------------------------------------------------------
// Patches
// ---------------------------------------------------------------------------
procedure DecodePatches(br: TBitReader; var pd: TPatchDictionary;
                        xsize, ysize, numEC: Integer;
                        const refs: TJxlRefFrames);
var
  ans: TANSDecoder;
  numRefPatch, maxRefPatches, maxPatches, totalPatches, id, i, j, idCount,
    np: Integer;
  rp: TPatchRefPos;
  pos: TPatchPos;
  info: TPatchBlending;
  chooseAlpha: Boolean;
  dx, dy: Int64;

  function ReadNum(ctx: Integer): Integer;
  begin
    Result := Integer(ans.Decode(ctx, br));
  end;

begin
  SetLength(pd.RefPositions, 0);
  SetLength(pd.Positions, 0);
  SetLength(pd.Blendings, 0);
  pd.BlendingsStride := numEC + 1;
  ans := TANSDecoder.Create;
  try
    ans.Init(br, kNumPatchDictionaryContexts);
    numRefPatch := ReadNum(kNumRefPatchContext);
    maxRefPatches := 1024 + (Int64(xsize) * ysize) div 4;
    maxPatches := maxRefPatches * 4;
    if numRefPatch > maxRefPatches then
      raise EJxlError.Create('Too many patches in dictionary');
    totalPatches := 0;
    chooseAlpha := numEC > 1;
    for id := 0 to numRefPatch - 1 do
    begin
      rp.Ref := ReadNum(kReferenceFrameContext);
      if (rp.Ref >= 4) or not refs[rp.Ref].Valid then
        raise EJxlError.Create('Invalid reference frame ID');
      if not refs[rp.Ref].IbIsInXYB then
        raise EJxlError.Create('Patches cannot use frames saved post color transforms');
      rp.X0 := ReadNum(kPatchReferencePositionContext);
      rp.Y0 := ReadNum(kPatchReferencePositionContext);
      rp.XSize := ReadNum(kPatchSizeContext) + 1;
      rp.YSize := ReadNum(kPatchSizeContext) + 1;
      if (Int64(rp.X0) + rp.XSize > refs[rp.Ref].XSize) or
         (Int64(rp.Y0) + rp.YSize > refs[rp.Ref].YSize) then
        raise EJxlError.Create('Invalid position specified in reference frame');
      idCount := ReadNum(kPatchCountContext);
      if idCount > maxPatches then
        raise EJxlError.Create('Too many patches in dictionary');
      Inc(idCount);
      Inc(totalPatches, idCount);
      if totalPatches > maxPatches then
        raise EJxlError.Create('Too many patches in dictionary');
      for i := 0 to idCount - 1 do
      begin
        pos.RefPosIdx := Length(pd.RefPositions);
        if i = 0 then
        begin
          pos.X := ReadNum(kPatchPositionContext);
          pos.Y := ReadNum(kPatchPositionContext);
        end
        else
        begin
          np := Length(pd.Positions);
          dx := UnpackSignedI(Cardinal(ReadNum(kPatchOffsetContext)));
          if (dx < 0) and (-dx > pd.Positions[np - 1].X) then
            raise EJxlError.Create('Invalid patch: negative x coordinate');
          pos.X := pd.Positions[np - 1].X + dx;
          dy := UnpackSignedI(Cardinal(ReadNum(kPatchOffsetContext)));
          if (dy < 0) and (-dy > pd.Positions[np - 1].Y) then
            raise EJxlError.Create('Invalid patch: negative y coordinate');
          pos.Y := pd.Positions[np - 1].Y + dy;
        end;
        if (Int64(pos.X) + rp.XSize > xsize) or (Int64(pos.Y) + rp.YSize > ysize) then
          raise EJxlError.Create('Invalid patch position');
        for j := 0 to pd.BlendingsStride - 1 do
        begin
          info.Mode := ReadNum(kPatchBlendModeContext);
          if info.Mode >= 8 then
            raise EJxlError.Create('Invalid patch blend mode');
          if UsesAlpha(info.Mode) and chooseAlpha then
          begin
            info.AlphaChannel := ReadNum(kPatchAlphaChannelContext);
            if info.AlphaChannel >= numEC then
              raise EJxlError.Create('Invalid alpha channel for blending');
          end
          else
            info.AlphaChannel := 0;
          if UsesClamp(info.Mode) then
            info.Clamp := ReadNum(kPatchClampContext) <> 0
          else
            info.Clamp := False;
          np := Length(pd.Blendings);
          SetLength(pd.Blendings, np + 1);
          pd.Blendings[np] := info;
        end;
        np := Length(pd.Positions);
        SetLength(pd.Positions, np + 1);
        pd.Positions[np] := pos;
      end;
      np := Length(pd.RefPositions);
      SetLength(pd.RefPositions, np + 1);
      pd.RefPositions[np] := rp;
    end;
    if not ans.CheckFinalState then
      raise EJxlError.Create('Patches: ANS checksum failure');
  finally
    ans.Free;
  end;
end;

// Patches are applied in index order, row by row (AddOneRow applies the
// patches of a row sorted by index; doing each patch in turn is equivalent).
procedure ApplyPatches(const pd: TPatchDictionary; var planes: TPlaneArray;
                       const refs: TJxlRefFrames; const ecInfo: TBlendChannelInfos);
var
  pi, iy, c, nc, w, h, x1, ry: Integer;
  rp: TPatchRefPos;
  bg, fg: array of PSingle;
  ecb: array of TPatchBlending;
begin
  nc := Length(planes);
  if nc = 0 then Exit;
  w := planes[0].Width; h := planes[0].Height;
  SetLength(bg, nc); SetLength(fg, nc);
  SetLength(ecb, pd.BlendingsStride - 1);
  for pi := 0 to High(pd.Positions) do
  begin
    rp := pd.RefPositions[pd.Positions[pi].RefPosIdx];
    x1 := Min(pd.Positions[pi].X + rp.XSize, w);
    if x1 <= pd.Positions[pi].X then Continue;
    for c := 0 to High(ecb) do ecb[c] := pd.Blendings[pi * pd.BlendingsStride + 1 + c];
    for iy := 0 to rp.YSize - 1 do
    begin
      ry := pd.Positions[pi].Y + iy;
      if ry >= h then Break;
      for c := 0 to nc - 1 do
      begin
        bg[c] := @planes[c].Data[ry * planes[c].Stride + pd.Positions[pi].X];
        fg[c] := @refs[rp.Ref].Planes[c].Data[(rp.Y0 + iy) * refs[rp.Ref].Planes[c].Stride + rp.X0];
      end;
      PerformBlending(bg, fg, bg, x1 - pd.Positions[pi].X,
                      pd.Blendings[pi * pd.BlendingsStride], ecb, ecInfo);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Noise
// ---------------------------------------------------------------------------
procedure DecodeNoise(br: TBitReader; var np: TNoiseParams);
var i: Integer;
begin
  for i := 0 to 7 do
    np.Lut[i] := br.ReadBits(10) / 1024.0;
end;

function NoiseHasAny(const np: TNoiseParams): Boolean;
var i: Integer;
begin
  for i := 0 to 7 do
    if Abs(np.Lut[i]) > 1e-3 then Exit(True);
  Result := False;
end;

type
  TXorshift = record
    s0, s1: array[0..7] of UInt64;
  end;

function SplitMix64(z: UInt64): UInt64; inline;
begin
  z := (z xor (z shr 30)) * UInt64($BF58476D1CE4E5B9);
  z := (z xor (z shr 27)) * UInt64($94D049BB133111EB);
  Result := z xor (z shr 31);
end;

procedure XorshiftInit(var r: TXorshift; seed1, seed2, seed3, seed4: Cardinal);
var i: Integer;
begin
  r.s0[0] := SplitMix64(((UInt64(seed1) shl 32) + seed2) + UInt64($9E3779B97F4A7C15));
  r.s1[0] := SplitMix64(((UInt64(seed3) shl 32) + seed4) + UInt64($9E3779B97F4A7C15));
  for i := 1 to 7 do
  begin
    r.s0[i] := SplitMix64(r.s0[i - 1]);
    r.s1[i] := SplitMix64(r.s1[i - 1]);
  end;
end;

procedure XorshiftFill(var r: TXorshift; var bits: array of UInt64);
var
  i: Integer;
  a, b: UInt64;
begin
  for i := 0 to 7 do
  begin
    a := r.s0[i];
    b := r.s1[i];
    bits[i] := a + b;
    r.s0[i] := b;
    a := a xor (a shl 23);
    a := a xor (b xor (a shr 18) xor (b shr 5));
    r.s1[i] := a;
  end;
end;

procedure RandomRect(var r: TXorshift; var p: TFloat32Plane; x0, y0, xs, ys: Integer);
var
  batch: array[0..7] of UInt64;
  b32: PCardinal;
  x, y, i: Integer;
  row: PSingle;
  u: Cardinal;
begin
  b32 := @batch[0];
  for y := 0 to ys - 1 do
  begin
    row := @p.Data[(y0 + y) * p.Stride + x0];
    x := 0;
    while x + 16 < xs do
    begin
      XorshiftFill(r, batch);
      for i := 0 to 15 do
      begin
        u := (b32[i] shr 9) or $3F800000;
        row[x + i] := PSingle(@u)^;
      end;
      Inc(x, 16);
    end;
    XorshiftFill(r, batch);
    i := 0;
    while x < xs do
    begin
      u := (b32[i] shr 9) or $3F800000;
      row[x] := PSingle(@u)^;
      Inc(x); Inc(i);
    end;
  end;
end;

procedure GenerateNoisePlanes(var noise: array of TFloat32Plane;
                              xsize, ysize, groupDim, upsampling,
                              xsizeGroups, ysizeGroups: Integer;
                              visibleIdx, nonvisibleIdx: Cardinal);
var
  gx, gy, ix, iy, c, bx0, by0, bx1, by1, tx0, ty0, tx1, ty1: Integer;
  r: TXorshift;
begin
  for c := 0 to 2 do InitFloat32Plane(noise[c], xsize, ysize);
  for gy := 0 to ysizeGroups - 1 do
    for gx := 0 to xsizeGroups - 1 do
    begin
      // the group's buffer rect in upsampled coordinates
      bx0 := gx * groupDim * upsampling;
      by0 := gy * groupDim * upsampling;
      bx1 := Min(bx0 + groupDim * upsampling, xsize);
      by1 := Min(by0 + groupDim * upsampling, ysize);
      for iy := 0 to upsampling - 1 do
        for ix := 0 to upsampling - 1 do
        begin
          tx0 := bx0 + ix * groupDim;
          ty0 := by0 + iy * groupDim;
          tx1 := Min(tx0 + groupDim, bx1);
          ty1 := Min(ty0 + groupDim, by1);
          XorshiftInit(r, visibleIdx, nonvisibleIdx,
                       Cardinal((gx * upsampling + ix) * groupDim),
                       Cardinal((gy * upsampling + iy) * groupDim));
          if (tx1 <= tx0) or (ty1 <= ty0) then Continue;
          for c := 0 to 2 do
            RandomRect(r, noise[c], tx0, ty0, tx1 - tx0, ty1 - ty0);
        end;
    end;
end;

function MirrorI(x, size: Integer): Integer; inline;
var v: Integer;
begin
  v := x;
  while (v < 0) or (v >= size) do
    if v < 0 then v := -v - 1
    else v := 2 * size - 1 - v;
  Result := v;
end;

procedure ConvolveNoise(var noise: array of TFloat32Plane);
var
  c, x, y, w, h, i, j: Integer;
  src: array of Single;
  others: Single;
begin
  for c := 0 to 2 do
  begin
    w := noise[c].Width; h := noise[c].Height;
    if (w = 0) or (h = 0) then Continue;
    SetLength(src, w * h);
    Move(noise[c].Data[0], src[0], w * h * SizeOf(Single));
    for y := 0 to h - 1 do
      for x := 0 to w - 1 do
      begin
        others := 0;
        for i := -2 to 2 do
        begin
          others := others + src[MirrorI(y - 2, h) * w + MirrorI(x + i, w)];
          others := others + src[MirrorI(y - 1, h) * w + MirrorI(x + i, w)];
          others := others + src[MirrorI(y + 1, h) * w + MirrorI(x + i, w)];
          others := others + src[MirrorI(y + 2, h) * w + MirrorI(x + i, w)];
        end;
        for j := -2 to 2 do
          if j <> 0 then
            others := others + src[y * w + MirrorI(x + j, w)];
        noise[c].Data[y * w + x] := others * 0.16 + src[y * w + x] * -3.84;
      end;
  end;
end;

function NoiseStrength(const np: TNoiseParams; v: Single): Single;
var
  scaled, fl, frac, lo, hi: Single;
  idx: Integer;
begin
  scaled := v * 6;
  if scaled < 0 then scaled := 0;
  fl := Floor(scaled);
  frac := scaled - fl;
  if scaled >= 7 then begin fl := 6; frac := 1; end;
  idx := Trunc(fl);
  lo := np.Lut[idx];
  hi := np.Lut[idx + 1];
  Result := (hi - lo) * frac + lo;
  if Result > 1 then Result := 1;
  if Result < 0 then Result := 0;
end;

procedure AddNoise(var planes: array of TFloat32Plane;
                   const noise: array of TFloat32Plane;
                   const np: TNoiseParams; ytox, ytob: Single);
const
  kRGCorr = 0.9921875;
  kRGNCorr = 0.0078125;
  kNorm = 0.22;
var
  i, n: Integer;
  vx, vy, sg, sr, rr, rg, rc, redN, greenN, rgN: Single;
begin
  if not NoiseHasAny(np) then Exit;
  n := planes[0].Width * planes[0].Height;
  for i := 0 to n - 1 do
  begin
    vx := planes[0].Data[i];
    vy := planes[1].Data[i];
    sg := NoiseStrength(np, (vy - vx) * 0.5);
    sr := NoiseStrength(np, (vy + vx) * 0.5);
    rr := noise[0].Data[i] * kNorm;
    rg := noise[1].Data[i] * kNorm;
    rc := noise[2].Data[i] * kNorm;
    redN := sr * (kRGNCorr * rr + kRGCorr * rc);
    greenN := sg * (kRGNCorr * rg + kRGCorr * rc);
    rgN := redN + greenN;
    planes[0].Data[i] := ytox * rgN + (redN - greenN) + vx;
    planes[1].Data[i] := vy + rgN;
    planes[2].Data[i] := ytob * rgN + planes[2].Data[i];
  end;
end;

end.
