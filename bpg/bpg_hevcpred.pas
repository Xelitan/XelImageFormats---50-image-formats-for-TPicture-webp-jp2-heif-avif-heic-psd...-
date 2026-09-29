// BPG decoder -- Free Pascal port of libbpg 0.9.8
// Intra prediction: reference sample construction/filtering plus the
// planar, DC and angular predictors.
// Corresponds to: libavcodec/hevcpred.c + hevcpred_template.c
//                 (single instantiation, samples are always 16-bit)
//
// The reference builds 4 samples at a time through a 64-bit union (the EXTEND
// macros); Extend16 below reproduces that block-of-four behaviour exactly,
// including the writes past `Len` when Len is not a multiple of 4.
unit bpg_hevcpred;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  bpg_common, bpg_bits, bpg_cabac, bpg_hevc_defs;

procedure intra_pred(S: PHEVCContext; X0, Y0, Log2Size, CIdx: Integer);

implementation

const
  intra_pred_angle: array[0..32] of Int8 = (
     32, 26, 21, 17, 13, 9, 5, 2, 0, -2, -5, -9, -13, -17, -21, -26, -32,
    -26, -21, -17, -13, -9, -5, -2, 0, 2, 5, 9, 13, 17, 21, 26, 32
  );
  inv_angle: array[0..14] of Int16 = (
    -4096, -1638, -910, -630, -482, -390, -315, -256, -315, -390, -482,
    -630, -910, -1638, -4096
  );

// EXTEND(ptr, val, len): fills in blocks of four samples
procedure Extend16(P: PWord; Val: Word; Len: Integer); inline;
var
  I: Integer;
begin
  I := 0;
  while I < Len do
  begin
    P[I] := Val;
    P[I + 1] := Val;
    P[I + 2] := Val;
    P[I + 3] := Val;
    Inc(I, 4);
  end;
end;

// IS_INTRA(x, y): pred_flag of the min-PU covering (x,y) is PF_INTRA
function IsIntraPU(S: PHEVCContext; XPu, YPu, MinPuWidth: Integer): Boolean; inline;
begin
  Result := S^.ref^.tab_mvf[XPu + YPu * MinPuWidth].pred_flag = PF_INTRA;
end;

procedure pred_planar_var(Src: PWord; Top, Left: PWord; Stride: PtrInt;
  TrafoSize: Integer);
var
  X, Y, Size: Integer;
begin
  Size := 1 shl TrafoSize;
  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
      Src[X + Stride * Y] :=
        Word(((Size - 1 - X) * Left[Y] + (X + 1) * Top[Size] +
              (Size - 1 - Y) * Top[X] + (Y + 1) * Left[Size] + Size) shr (TrafoSize + 1));
end;

procedure pred_dc_var(Src: PWord; Top, Left: PWord; Stride: PtrInt;
  Log2Size, CIdx: Integer);
var
  I, J, X, Y, Size, DC: Integer;
begin
  Size := 1 shl Log2Size;
  DC := Size;
  for I := 0 to Size - 1 do
    DC := DC + Left[I] + Top[I];
  DC := DC shr (Log2Size + 1);
  for I := 0 to Size - 1 do
  begin
    J := 0;
    while J < Size do
    begin
      Src[J + Stride * I] := Word(DC);
      Src[J + 1 + Stride * I] := Word(DC);
      Src[J + 2 + Stride * I] := Word(DC);
      Src[J + 3 + Stride * I] := Word(DC);
      Inc(J, 4);
    end;
  end;
  if (CIdx = 0) and (Size < 32) then
  begin
    Src[0] := Word((Left[0] + 2 * DC + Top[0] + 2) shr 2);
    for X := 1 to Size - 1 do
      Src[X] := Word((Top[X] + 3 * DC + 2) shr 2);
    for Y := 1 to Size - 1 do
      Src[Stride * Y] := Word((Left[Y] + 3 * DC + 2) shr 2);
  end;
end;

procedure pred_angular_var(Src: PWord; Top, Left: PWord; Stride: PtrInt;
  CIdx, Mode, Size, DisableIntraBoundaryFilter, BitDepth: Integer);
var
  X, Y, Angle, Last, Idx, Fact: Integer;
  ref_array: array[0 .. 3 * 32 + 4 - 1] of Word;
  ref_tmp: PWord;
  Ref: PWord;
begin
  Angle := intra_pred_angle[Mode - 2];
  ref_tmp := PWord(@ref_array[0]) + Size;
  // Angle is negative for modes 11..25, so this must be an arithmetic shift
  Last := SAR(Size * Angle, 5);

  if Mode >= 18 then
  begin
    Ref := Top - 1;
    if (Angle < 0) and (Last < -1) then
    begin
      X := 0;
      while X <= Size do
      begin
        ref_tmp[X] := Top[X - 1];
        ref_tmp[X + 1] := Top[X];
        ref_tmp[X + 2] := Top[X + 1];
        ref_tmp[X + 3] := Top[X + 2];
        Inc(X, 4);
      end;
      for X := Last to -1 do
        ref_tmp[X] := Left[-1 + SAR(X * inv_angle[Mode - 11] + 128, 8)];
      Ref := ref_tmp;
    end;
    for Y := 0 to Size - 1 do
    begin
      Idx := SAR((Y + 1) * Angle, 5);
      Fact := ((Y + 1) * Angle) and 31;
      if Fact <> 0 then
      begin
        X := 0;
        while X < Size do
        begin
          Src[X + Stride * Y] := Word(((32 - Fact) * Ref[X + Idx + 1] +
            Fact * Ref[X + Idx + 2] + 16) shr 5);
          Src[X + 1 + Stride * Y] := Word(((32 - Fact) * Ref[X + 1 + Idx + 1] +
            Fact * Ref[X + 1 + Idx + 2] + 16) shr 5);
          Src[X + 2 + Stride * Y] := Word(((32 - Fact) * Ref[X + 2 + Idx + 1] +
            Fact * Ref[X + 2 + Idx + 2] + 16) shr 5);
          Src[X + 3 + Stride * Y] := Word(((32 - Fact) * Ref[X + 3 + Idx + 1] +
            Fact * Ref[X + 3 + Idx + 2] + 16) shr 5);
          Inc(X, 4);
        end;
      end
      else
      begin
        X := 0;
        while X < Size do
        begin
          Src[X + Stride * Y] := Ref[X + Idx + 1];
          Src[X + 1 + Stride * Y] := Ref[X + 1 + Idx + 1];
          Src[X + 2 + Stride * Y] := Ref[X + 2 + Idx + 1];
          Src[X + 3 + Stride * Y] := Ref[X + 3 + Idx + 1];
          Inc(X, 4);
        end;
      end;
    end;
    if (Mode = 26) and (CIdx = 0) and (Size < 32) and (DisableIntraBoundaryFilter = 0) then
      for Y := 0 to Size - 1 do
        Src[Stride * Y] := Word(av_clip_uintp2(Top[0] + SAR(Integer(Left[Y]) - Integer(Left[-1]), 1), BitDepth));
  end
  else
  begin
    Ref := Left - 1;
    if (Angle < 0) and (Last < -1) then
    begin
      X := 0;
      while X <= Size do
      begin
        ref_tmp[X] := Left[X - 1];
        ref_tmp[X + 1] := Left[X];
        ref_tmp[X + 2] := Left[X + 1];
        ref_tmp[X + 3] := Left[X + 2];
        Inc(X, 4);
      end;
      for X := Last to -1 do
        ref_tmp[X] := Top[-1 + SAR(X * inv_angle[Mode - 11] + 128, 8)];
      Ref := ref_tmp;
    end;
    for X := 0 to Size - 1 do
    begin
      Idx := SAR((X + 1) * Angle, 5);
      Fact := ((X + 1) * Angle) and 31;
      if Fact <> 0 then
      begin
        for Y := 0 to Size - 1 do
          Src[X + Stride * Y] := Word(((32 - Fact) * Ref[Y + Idx + 1] +
            Fact * Ref[Y + Idx + 2] + 16) shr 5);
      end
      else
      begin
        for Y := 0 to Size - 1 do
          Src[X + Stride * Y] := Ref[Y + Idx + 1];
      end;
    end;
    if (Mode = 10) and (CIdx = 0) and (Size < 32) and (DisableIntraBoundaryFilter = 0) then
    begin
      X := 0;
      while X < Size do
      begin
        Src[X] := Word(av_clip_uintp2(Left[0] + SAR(Integer(Top[X]) - Integer(Top[-1]), 1), BitDepth));
        Src[X + 1] := Word(av_clip_uintp2(Left[0] + SAR(Integer(Top[X + 1]) - Integer(Top[-1]), 1), BitDepth));
        Src[X + 2] := Word(av_clip_uintp2(Left[0] + SAR(Integer(Top[X + 2]) - Integer(Top[-1]), 1), BitDepth));
        Src[X + 3] := Word(av_clip_uintp2(Left[0] + SAR(Integer(Top[X + 3]) - Integer(Top[-1]), 1), BitDepth));
        Inc(X, 4);
      end;
    end;
  end;
end;

procedure intra_pred(S: PHEVCContext; X0, Y0, Log2Size, CIdx: Integer);
var
  LC: PHEVCLocalContext;
  BitDepth, I, J: Integer;
  HShift, VShift, Size: Integer;
  size_in_luma_h, size_in_tbs_h, size_in_luma_v, size_in_tbs_v: Integer;
  X, Y, x_tb, y_tb, cur_tb_addr: Integer;
  Stride: PtrInt;
  Src: PWord;
  min_pu_width: Integer;
  Mode: Integer;
  A: Word;
  left_array, filtered_left_array, top_array, filtered_top_array: array[0 .. 2 * 32 + 1 - 1] of Word;
  Left, Top, filtered_left, filtered_top: PWord;
  cand_bottom_left, cand_left, cand_up_left, cand_up, cand_up_right: Integer;
  bottom_left_size, top_right_size: Integer;
  disable_intra_boundary_filter: Integer;
  tb_mask2: Integer;
  size_in_luma_pu_v, size_in_luma_pu_h: Integer;
  on_pu_edge_x, on_pu_edge_y: Integer;
  x_left_pu, y_bottom_pu, y_left_pu, y_top_pu, x_top_pu, x_right_pu, MaxN: Integer;
  size_max_x, size_max_y: Integer;
  intra_hor_ver_dist_thresh: array[0..2] of Integer;
  min_dist_vert_hor, threshold: Integer;
  log2_min_pu_size: Integer;
begin
  LC := S^.HEVClc;
  BitDepth := S^.sps^.bit_depth;
  HShift := S^.sps^.hshift[CIdx];
  VShift := S^.sps^.vshift[CIdx];
  Size := 1 shl Log2Size;
  size_in_luma_h := Size shl HShift;
  size_in_tbs_h := size_in_luma_h shr S^.sps^.log2_min_tb_size;
  size_in_luma_v := Size shl VShift;
  size_in_tbs_v := size_in_luma_v shr S^.sps^.log2_min_tb_size;
  X := X0 shr HShift;
  Y := Y0 shr VShift;
  x_tb := (X0 shr S^.sps^.log2_min_tb_size) and S^.sps^.tb_mask;
  y_tb := (Y0 shr S^.sps^.log2_min_tb_size) and S^.sps^.tb_mask;
  tb_mask2 := S^.sps^.tb_mask + 2;
  cur_tb_addr := S^.pps^.min_tb_addr_zs[y_tb * tb_mask2 + x_tb];

  Stride := S^.frame^.Linesize[CIdx] div SizeOf(Word);
  Src := PWord(S^.frame^.Data[CIdx]) + X + Y * Stride;
  min_pu_width := S^.sps^.min_pu_width;
  log2_min_pu_size := S^.sps^.log2_min_pu_size;

  if CIdx <> 0 then Mode := LC^.tu.intra_pred_mode_c else Mode := LC^.tu.intra_pred_mode;

  Left := PWord(@left_array[0]) + 1;
  Top := PWord(@top_array[0]) + 1;
  filtered_left := PWord(@filtered_left_array[0]) + 1;
  filtered_top := PWord(@filtered_top_array[0]) + 1;

  cand_bottom_left := Ord((LC^.na.cand_bottom_left <> 0) and
    (cur_tb_addr > S^.pps^.min_tb_addr_zs[((y_tb + size_in_tbs_v) and S^.sps^.tb_mask) * tb_mask2 + (x_tb - 1)]));
  cand_left := LC^.na.cand_left;
  cand_up_left := LC^.na.cand_up_left;
  cand_up := LC^.na.cand_up;
  cand_up_right := Ord((LC^.na.cand_up_right <> 0) and
    (cur_tb_addr > S^.pps^.min_tb_addr_zs[(y_tb - 1) * tb_mask2 + ((x_tb + size_in_tbs_h) and S^.sps^.tb_mask)]));

  // the difference goes negative near the bottom edge -- arithmetic shift
  bottom_left_size := SAR(FFMIN(Y0 + 2 * size_in_luma_v, S^.sps^.height) - (Y0 + size_in_luma_v), VShift);
  top_right_size := SAR(FFMIN(X0 + 2 * size_in_luma_h, S^.sps^.width) - (X0 + size_in_luma_h), HShift);

  if S^.pps^.constrained_intra_pred_flag = 1 then
  begin
    size_in_luma_pu_v := size_in_luma_v shr log2_min_pu_size;
    size_in_luma_pu_h := size_in_luma_h shr log2_min_pu_size;
    on_pu_edge_x := Ord((X0 and ((1 shl log2_min_pu_size) - 1)) = 0);
    on_pu_edge_y := Ord((Y0 and ((1 shl log2_min_pu_size) - 1)) = 0);
    if size_in_luma_pu_h = 0 then Inc(size_in_luma_pu_h);

    if (cand_bottom_left = 1) and (on_pu_edge_x <> 0) then
    begin
      x_left_pu := SAR(X0 - 1, log2_min_pu_size);
      y_bottom_pu := (Y0 + size_in_luma_v) shr log2_min_pu_size;
      MaxN := FFMIN(size_in_luma_pu_v, S^.sps^.min_pu_height - y_bottom_pu);
      cand_bottom_left := 0;
      I := 0;
      while I < MaxN do
      begin
        cand_bottom_left := cand_bottom_left or Ord(IsIntraPU(S, x_left_pu, y_bottom_pu + I, min_pu_width));
        Inc(I, 2);
      end;
    end;
    if (cand_left = 1) and (on_pu_edge_x <> 0) then
    begin
      x_left_pu := SAR(X0 - 1, log2_min_pu_size);
      y_left_pu := Y0 shr log2_min_pu_size;
      MaxN := FFMIN(size_in_luma_pu_v, S^.sps^.min_pu_height - y_left_pu);
      cand_left := 0;
      I := 0;
      while I < MaxN do
      begin
        cand_left := cand_left or Ord(IsIntraPU(S, x_left_pu, y_left_pu + I, min_pu_width));
        Inc(I, 2);
      end;
    end;
    if cand_up_left = 1 then
    begin
      x_left_pu := SAR(X0 - 1, log2_min_pu_size);
      y_top_pu := SAR(Y0 - 1, log2_min_pu_size);
      cand_up_left := Ord(IsIntraPU(S, x_left_pu, y_top_pu, min_pu_width));
    end;
    if (cand_up = 1) and (on_pu_edge_y <> 0) then
    begin
      x_top_pu := X0 shr log2_min_pu_size;
      y_top_pu := SAR(Y0 - 1, log2_min_pu_size);
      MaxN := FFMIN(size_in_luma_pu_h, S^.sps^.min_pu_width - x_top_pu);
      cand_up := 0;
      I := 0;
      while I < MaxN do
      begin
        cand_up := cand_up or Ord(IsIntraPU(S, x_top_pu + I, y_top_pu, min_pu_width));
        Inc(I, 2);
      end;
    end;
    if (cand_up_right = 1) and (on_pu_edge_y <> 0) then
    begin
      y_top_pu := SAR(Y0 - 1, log2_min_pu_size);
      x_right_pu := (X0 + size_in_luma_h) shr log2_min_pu_size;
      MaxN := FFMIN(size_in_luma_pu_h, S^.sps^.min_pu_width - x_right_pu);
      cand_up_right := 0;
      I := 0;
      while I < MaxN do
      begin
        cand_up_right := cand_up_right or Ord(IsIntraPU(S, x_right_pu + I, y_top_pu, min_pu_width));
        Inc(I, 2);
      end;
    end;
    FillChar(Left^, 2 * 32 * SizeOf(Word), 128);
    FillChar(Top^, 2 * 32 * SizeOf(Word), 128);
    Top[-1] := 128;
  end;

  if cand_up_left <> 0 then
  begin
    Left[-1] := Src[-1 - Stride];
    Top[-1] := Left[-1];
  end;
  if cand_up <> 0 then
    Move((Src - Stride)^, Top^, Size * SizeOf(Word));
  if cand_up_right <> 0 then
  begin
    Move((Src - Stride + Size)^, (Top + Size)^, Size * SizeOf(Word));
    Extend16(Top + Size + top_right_size, Src[Size + top_right_size - 1 - Stride],
      Size - top_right_size);
  end;
  if cand_left <> 0 then
    for I := 0 to Size - 1 do
      Left[I] := Src[-1 + Stride * I];
  if cand_bottom_left <> 0 then
  begin
    for I := Size to Size + bottom_left_size - 1 do
      Left[I] := Src[-1 + Stride * I];
    Extend16(Left + Size + bottom_left_size, Src[-1 + Stride * (Size + bottom_left_size - 1)],
      Size - bottom_left_size);
  end;

  if S^.pps^.constrained_intra_pred_flag = 1 then
  begin
    if (cand_bottom_left <> 0) or (cand_left <> 0) or (cand_up_left <> 0) or
       (cand_up <> 0) or (cand_up_right <> 0) then
    begin
      if X0 + ((2 * Size) shl HShift) < S^.sps^.width then
        size_max_x := 2 * Size
      else
        size_max_x := (S^.sps^.width - X0) shr HShift;
      if Y0 + ((2 * Size) shl VShift) < S^.sps^.height then
        size_max_y := 2 * Size
      else
        size_max_y := (S^.sps^.height - Y0) shr VShift;
      J := Size - 1;
      if cand_bottom_left <> 0 then J := J + bottom_left_size;
      if cand_up_right = 0 then
      begin
        if X0 + (Size shl HShift) < S^.sps^.width then
          size_max_x := Size
        else
          size_max_x := (S^.sps^.width - X0) shr HShift;
      end;
      if cand_bottom_left = 0 then
      begin
        if Y0 + (Size shl VShift) < S^.sps^.height then
          size_max_y := Size
        else
          size_max_y := (S^.sps^.height - Y0) shr VShift;
      end;

      if (cand_bottom_left <> 0) or (cand_left <> 0) or (cand_up_left <> 0) then
      begin
        while (J > -1) and
              (not IsIntraPU(S, SAR(X0 + (-1 shl HShift), log2_min_pu_size),
                                (Y0 + (J shl VShift)) shr log2_min_pu_size, min_pu_width)) do
          Dec(J);
        if not IsIntraPU(S, SAR(X0 + (-1 shl HShift), log2_min_pu_size),
                            (Y0 + (J shl VShift)) shr log2_min_pu_size, min_pu_width) then
        begin
          J := 0;
          while (J < size_max_x) and
                (not IsIntraPU(S, (X0 + (J shl HShift)) shr log2_min_pu_size,
                                  SAR(Y0 + (-1 shl VShift), log2_min_pu_size), min_pu_width)) do
            Inc(J);
          for I := J downto 0 do
            if not IsIntraPU(S, SAR(X0 + ((I - 1) shl HShift), log2_min_pu_size),
                                SAR(Y0 + (-1 shl VShift), log2_min_pu_size), min_pu_width) then
              Top[I - 1] := Top[I];
          Left[-1] := Top[-1];
        end;
      end
      else
      begin
        J := 0;
        while (J < size_max_x) and
              (not IsIntraPU(S, (X0 + (J shl HShift)) shr log2_min_pu_size,
                                SAR(Y0 + (-1 shl VShift), log2_min_pu_size), min_pu_width)) do
          Inc(J);
        if J > 0 then
        begin
          if X0 > 0 then
          begin
            for I := J downto 0 do
              if not IsIntraPU(S, SAR(X0 + ((I - 1) shl HShift), log2_min_pu_size),
                                  SAR(Y0 + (-1 shl VShift), log2_min_pu_size), min_pu_width) then
                Top[I - 1] := Top[I];
          end
          else
          begin
            for I := J downto 1 do
              if not IsIntraPU(S, SAR(X0 + ((I - 1) shl HShift), log2_min_pu_size),
                                  SAR(Y0 + (-1 shl VShift), log2_min_pu_size), min_pu_width) then
                Top[I - 1] := Top[I];
            Top[-1] := Top[0];
          end;
        end;
        Left[-1] := Top[-1];
      end;
      Left[-1] := Top[-1];

      if (cand_bottom_left <> 0) or (cand_left <> 0) then
      begin
        A := Left[-1];
        I := 0;
        while I < size_max_y do
        begin
          if not IsIntraPU(S, SAR(X0 + (-1 shl HShift), log2_min_pu_size),
                              (Y0 + (I shl VShift)) shr log2_min_pu_size, min_pu_width) then
          begin
            Left[I] := A; Left[I + 1] := A; Left[I + 2] := A; Left[I + 3] := A;
          end
          else
            A := Left[I + 3];
          Inc(I, 4);
        end;
      end;
      if cand_left = 0 then Extend16(Left, Left[-1], Size);
      if cand_bottom_left = 0 then Extend16(Left + Size, Left[Size - 1], Size);

      if (X0 <> 0) and (Y0 <> 0) then
      begin
        A := Left[size_max_y - 1];
        I := size_max_y - 1;
        while I > size_max_y - 1 - size_max_y do
        begin
          if not IsIntraPU(S, SAR(X0 + (-1 shl HShift), log2_min_pu_size),
                              SAR(Y0 + ((I - 3) shl VShift), log2_min_pu_size), min_pu_width) then
          begin
            Left[I - 3] := A; Left[I - 2] := A; Left[I - 1] := A; Left[I] := A;
          end
          else
            A := Left[I - 3];
          Dec(I, 4);
        end;
        if not IsIntraPU(S, SAR(X0 + (-1 shl HShift), log2_min_pu_size),
                            SAR(Y0 + (-1 shl VShift), log2_min_pu_size), min_pu_width) then
          Left[-1] := Left[0];
      end
      else if X0 = 0 then
        Extend16(Left, 0, size_max_y)
      else
      begin
        A := Left[size_max_y - 1];
        I := size_max_y - 1;
        while I > size_max_y - 1 - size_max_y do
        begin
          if not IsIntraPU(S, SAR(X0 + (-1 shl HShift), log2_min_pu_size),
                              SAR(Y0 + ((I - 3) shl VShift), log2_min_pu_size), min_pu_width) then
          begin
            Left[I - 3] := A; Left[I - 2] := A; Left[I - 1] := A; Left[I] := A;
          end
          else
            A := Left[I - 3];
          Dec(I, 4);
        end;
      end;
      Top[-1] := Left[-1];

      if Y0 <> 0 then
      begin
        A := Left[-1];
        I := 0;
        while I < size_max_x do
        begin
          if not IsIntraPU(S, (X0 + (I shl HShift)) shr log2_min_pu_size,
                              SAR(Y0 + (-1 shl VShift), log2_min_pu_size), min_pu_width) then
          begin
            Top[I] := A; Top[I + 1] := A; Top[I + 2] := A; Top[I + 3] := A;
          end
          else
            A := Top[I + 3];
          Inc(I, 4);
        end;
      end;
    end;
  end;

  if cand_bottom_left = 0 then
  begin
    if cand_left <> 0 then
      Extend16(Left + Size, Left[Size - 1], Size)
    else if cand_up_left <> 0 then
    begin
      Extend16(Left, Left[-1], 2 * Size);
      cand_left := 1;
    end
    else if cand_up <> 0 then
    begin
      Left[-1] := Top[0];
      Extend16(Left, Left[-1], 2 * Size);
      cand_up_left := 1;
      cand_left := 1;
    end
    else if cand_up_right <> 0 then
    begin
      Extend16(Top, Top[Size], Size);
      Left[-1] := Top[Size];
      Extend16(Left, Left[-1], 2 * Size);
      cand_up := 1;
      cand_up_left := 1;
      cand_left := 1;
    end
    else
    begin
      Left[-1] := Word(1 shl (BitDepth - 1));
      Extend16(Top, Left[-1], 2 * Size);
      Extend16(Left, Left[-1], 2 * Size);
    end;
  end;

  if cand_left = 0 then Extend16(Left, Left[Size], Size);
  if cand_up_left = 0 then Left[-1] := Left[0];
  if cand_up = 0 then Extend16(Top, Left[-1], Size);
  if cand_up_right = 0 then Extend16(Top + Size, Top[Size - 1], Size);
  Top[-1] := Left[-1];

  if (S^.sps^.intra_smoothing_disabled_flag = 0) and
     ((CIdx = 0) or (S^.sps^.chroma_format_idc = 3)) then
  begin
    if (Mode <> INTRA_DC) and (Size <> 4) then
    begin
      intra_hor_ver_dist_thresh[0] := 7;
      intra_hor_ver_dist_thresh[1] := 1;
      intra_hor_ver_dist_thresh[2] := 0;
      min_dist_vert_hor := FFMIN(FFABS(Mode - 26), FFABS(Mode - 10));
      if min_dist_vert_hor > intra_hor_ver_dist_thresh[Log2Size - 3] then
      begin
        threshold := 1 shl (BitDepth - 5);
        if (S^.sps^.sps_strong_intra_smoothing_enable_flag <> 0) and (CIdx = 0) and
           (Log2Size = 5) and
           (FFABS(Top[-1] + Top[63] - 2 * Top[31]) < threshold) and
           (FFABS(Left[-1] + Left[63] - 2 * Left[31]) < threshold) then
        begin
          filtered_top[-1] := Top[-1];
          filtered_top[63] := Top[63];
          for I := 0 to 62 do
            filtered_top[I] := Word(((64 - (I + 1)) * Top[-1] + (I + 1) * Top[63] + 32) shr 6);
          for I := 0 to 62 do
            Left[I] := Word(((64 - (I + 1)) * Left[-1] + (I + 1) * Left[63] + 32) shr 6);
          Top := filtered_top;
        end
        else
        begin
          filtered_left[2 * Size - 1] := Left[2 * Size - 1];
          filtered_top[2 * Size - 1] := Top[2 * Size - 1];
          for I := 2 * Size - 2 downto 0 do
            filtered_left[I] := Word((Left[I + 1] + 2 * Left[I] + Left[I - 1] + 2) shr 2);
          filtered_left[-1] := Word((Left[0] + 2 * Left[-1] + Top[0] + 2) shr 2);
          filtered_top[-1] := filtered_left[-1];
          for I := 2 * Size - 2 downto 0 do
            filtered_top[I] := Word((Top[I + 1] + 2 * Top[I] + Top[I - 1] + 2) shr 2);
          Left := filtered_left;
          Top := filtered_top;
        end;
      end;
    end;
  end;

  case Mode of
    INTRA_PLANAR:
      pred_planar_var(Src, Top, Left, Stride, Log2Size);
    INTRA_DC:
      pred_dc_var(Src, Top, Left, Stride, Log2Size, CIdx);
  else
    disable_intra_boundary_filter :=
      Ord((S^.sps^.implicit_rdpcm_enabled_flag <> 0) and (LC^.cu.cu_transquant_bypass_flag <> 0));
    pred_angular_var(Src, Top, Left, Stride, CIdx, Mode, 1 shl Log2Size,
      disable_intra_boundary_filter, BitDepth);
  end;
end;

end.
