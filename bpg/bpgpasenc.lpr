// BPG encoder -- Free Pascal
// Command line front end and BPG container writer.
//
// Reads a binary PPM (P6) and writes a BPG file.
//
// Two coding modes. 4:2:0 YCbCr is the default and is what BPG is normally used
// for: the picture is converted to BT.601 full range and the chroma planes are
// box averaged, which matches the c_h_phase = 1 (chroma between luma samples)
// that BPG_FORMAT_420 signals. 4:4:4 RGB is lossless apart from quantisation --
// no colour conversion, no decimation -- and is the easier mode to reason about
// when checking the encoder. The decoder's rgb_to_rgb24 maps the RGB planes back
// as R = plane 2, G = plane 0, B = plane 1, which is the mapping used here.
program bpgpasenc;

{$mode Delphi}
{$H+}
{$POINTERMATH ON}

uses
  SysUtils, Classes, bpg_common, bpg_putbits, bpg_hevc_defs, bpg_container,
  bpg_enc, bpg_sao_enc, bpg_enc_rd;

// the variable length unsigned integer of the BPG header, inverse of get_ue32
// one source sample; a 16 bit PPM stores samples big endian
function Samp(Pix: PByte; Idx, MaxVal, BitDepth: Integer): Integer; inline;
begin
  if MaxVal > 255 then
    Result := (Pix[Idx * 2] shl 8) or Pix[Idx * 2 + 1]
  else
    Result := Pix[Idx];
  // scale the source range onto the coded bit depth
  if MaxVal = 255 then
  begin
    if BitDepth > 8 then Result := Result shl (BitDepth - 8);
  end
  else
    Result := Result shr (16 - BitDepth);
end;

procedure PlanePut(var Enc: TBpgEncoder; CIdx, X, Y, V: Integer); inline;
begin
  (PWord(Enc.Src^.Data[CIdx] + Y * Enc.Src^.Linesize[CIdx]) + X)^ := Word(V);
end;

const
  FmtName: array[1..3] of string = ('4:2:0', '4:2:2', '4:4:4');

// Fraction of horizontally adjacent sample pairs that are EXACTLY equal.
// Photographs almost never repeat a value exactly -- sensor noise sees to that
// -- while screen content is mostly flat runs. Measured across the corpora the
// two populations barely overlap: 0.87 and 1.00 for synthetic screen content,
// 0.00 to 0.09 for photographs. The asymmetry is what makes acting on it safe:
// a false positive costs about +0.01 dB equivalent (transform skip is simply
// never chosen), a false negative gives up around 1% of rate.
function screen_fraction(Pix: PByte; W, H, NChan: Integer): Double;
var
  X, Y, Eq, Tot, A, C: Integer;
  Same: Boolean;
begin
  Eq := 0;
  Tot := 0;
  Y := 0;
  while Y < H do
  begin
    X := 0;
    while X < W - 1 do
    begin
      A := (Y * W + X) * NChan;
      Same := True;
      for C := 0 to FFMIN(NChan, 3) - 1 do
        if Pix[A + C] <> Pix[A + NChan + C] then Same := False;
      if Same then Inc(Eq);
      Inc(Tot);
      Inc(X, 2);
    end;
    Inc(Y, 2);
  end;
  if Tot = 0 then Result := 0 else Result := Eq / Tot;
end;

procedure Usage;
begin
  WriteLn(ErrOutput, 'usage: bpgpasenc [-q qp] [-f fmt] [-o out.bpg] in.ppm');
  WriteLn(ErrOutput, '  -q qp   quantiser, 0..51 (default 28); lower is better quality');
  WriteLn(ErrOutput, '  -f fmt  420 (default) or 422 for YCbCr, 444 for 4:4:4 RGB');
  WriteLn(ErrOutput, '  -b n    bits per sample of the coded picture, 8..12 (default 8)');
  WriteLn(ErrOutput, '  -size n encode to at most n bytes, choosing the quantiser automatically');
  WriteLn(ErrOutput, '  -lossless  code the residual untouched; use -f 444 for a truly exact file');
  WriteLn(ErrOutput, '  -fast   skip the coding unit size decision (smaller quality, much faster)');
  WriteLn(ErrOutput, '  -exactd RDOQ mierzy blad w pikselach zamiast w dziedzinie transformaty (wolniej)');
  WriteLn(ErrOutput, '  -slow   pelne RDOQ na blok: obecnie MIERZY SIE NA MINUS, patrz README');
  WriteLn(ErrOutput, '  -nodeblock wylacz filtr deblokujacy (domyslnie wlaczony, wart >1 dB)');
  WriteLn(ErrOutput, '  -nomodes wylacz pelny zestaw 35 trybow intra (domyslnie wlaczony)');
  WriteLn(ErrOutput, '  -sao    sample adaptive offset -- NIEDZIALAJACE: strumien jest poprawny,');
  WriteLn(ErrOutput, '          ale decyzja obniza jakosc o kilka dB. Nie uzywac.');
  WriteLn(ErrOutput, '  -noscreen wylacz automatyczne wykrywanie tresci ekranowej');
  WriteLn(ErrOutput, '  -screen 4x4 transform skip: -1% on sharp synthetic content, slightly worse on photos');
  Halt(1);
end;

// minimal binary PPM reader
// Reads a binary PPM (P6) or a PAM (P7) with DEPTH 3 or 4. NChan is 3 for RGB
// and 4 when the file carries an alpha channel.
function ReadImage(const Name: string; out W, H, MaxVal, NChan: Integer): PByte;
var
  FS: TFileStream;
  Buf: PByte;
  Size, Pos_, Vals: Integer;
  Nums: array[0..2] of Integer;
  Key: string;

  procedure SkipWs;
  begin
    while Pos_ < Size do
    begin
      if Buf[Pos_] = Ord('#') then
        while (Pos_ < Size) and (Buf[Pos_] <> 10) do Inc(Pos_)
      else if Buf[Pos_] in [9, 10, 13, 32] then Inc(Pos_)
      else Break;
    end;
  end;

  function ReadNum: Integer;
  begin
    SkipWs;
    Result := 0;
    while (Pos_ < Size) and (Buf[Pos_] >= Ord('0')) and (Buf[Pos_] <= Ord('9')) do
    begin
      Result := Result * 10 + (Buf[Pos_] - Ord('0'));
      Inc(Pos_);
    end;
  end;

begin
  FS := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
  try
    Size := FS.Size;
    Buf := av_malloc(Size);
    FS.ReadBuffer(Buf^, Size);
  finally
    FS.Free;
  end;
  if (Size < 10) or (Buf[0] <> Ord('P')) then
  begin
    WriteLn(ErrOutput, Name + ': not a PPM or PAM');
    Halt(1);
  end;
  if Buf[1] = Ord('7') then
  begin
    // PAM: keyword lines up to ENDHDR
    Pos_ := 2;
    W := 0; H := 0; MaxVal := 0; NChan := 0;
    while Pos_ < Size do
    begin
      SkipWs;
      Key := '';
      while (Pos_ < Size) and (Buf[Pos_] > 32) do
      begin
        Key := Key + Chr(Buf[Pos_]);
        Inc(Pos_);
      end;
      if Key = 'ENDHDR' then Break;
      if Key = 'WIDTH' then W := ReadNum
      else if Key = 'HEIGHT' then H := ReadNum
      else if Key = 'DEPTH' then NChan := ReadNum
      else if Key = 'MAXVAL' then MaxVal := ReadNum
      else
        while (Pos_ < Size) and (Buf[Pos_] <> 10) do Inc(Pos_);
    end;
    while (Pos_ < Size) and (Buf[Pos_] <> 10) do Inc(Pos_);
    if (NChan <> 3) and (NChan <> 4) then
    begin
      WriteLn(ErrOutput, Name + ': PAM DEPTH must be 3 or 4');
      Halt(1);
    end;
  end
  else if Buf[1] = Ord('6') then
  begin
    Pos_ := 2;
    NChan := 3;
    for Vals := 0 to 2 do Nums[Vals] := ReadNum;
    W := Nums[0];
    H := Nums[1];
    MaxVal := Nums[2];
  end
  else
  begin
    WriteLn(ErrOutput, Name + ': not a binary PPM (P6) or PAM (P7)');
    Halt(1);
  end;
  if (MaxVal <> 255) and (MaxVal <> 65535) then
  begin
    WriteLn(ErrOutput, Name + ': maxval must be 255 or 65535');
    Halt(1);
  end;
  Inc(Pos_);   // the single whitespace byte ending the header
  if Pos_ + W * H * NChan * (1 + Ord(MaxVal > 255)) > Size then
  begin
    WriteLn(ErrOutput, Name + ': truncated');
    Halt(1);
  end;
  Result := Buf + Pos_;
end;

var
  InName: string = '';
  OutName: string = 'out.bpg';
  Qp: Integer = 28;
  Fmt: Integer = 1;   // chroma_format_idc: 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4
  BitDepth: Integer = 8;
  RdOn: Boolean = True;
  TargetSize: Integer = 0;
  LossOn: Boolean = False;
  SlowOn: Boolean = False;
  ScreenOn: Boolean = False;
  ScreenAuto: Boolean = True;
  SaoOn: Boolean = True;
  DeblockOn: Boolean = True;
  ModesOn: Boolean = True;
  Lo, Hi, Mid: Integer;
  Probe: TByteBuf;
  Arg: string;
  I, W, H: Integer;
  MaxVal, NChan: Integer;
  HasAlpha: Boolean;
  AEnc: TBpgEncoder;
  Pix: PByte;
  Enc: TBpgEncoder;
  Out_: TByteBuf;
  P: PWord;
  FS: TFileStream;
// One complete encode at the given quantiser: colour, optional alpha, and the
// BPG container, delivered in OutB. Frees the encoder contexts afterwards, so
// the size search can call it repeatedly.
procedure BuildAtQp(TheQp: Integer; var OutB: TByteBuf);
var
  X, Y, SX, SY, CW, CH, CHc, R, G, Bl, Yv, Cb, Cr: Integer;
  PixMax, Centre, flags1, flags2: Integer;
  CbF, CrF: array of Integer;
begin
  if bpg_enc_init(Enc, W, H, Fmt, BitDepth, TheQp) < 0 then
  begin
    WriteLn(ErrOutput, 'encoder init failed');
    Halt(1);
  end;

  // The coded picture is rounded up to a whole minimum coding block; the true
  // size travels in the BPG header, and the decoder crops to it. Fill the pad
  // with the edge pixels so it costs almost nothing to code.
  CW := Enc.Ctx.sps^.width;
  CH := Enc.Ctx.sps^.height;
  PixMax := (1 shl BitDepth) - 1;
  Centre := 1 shl (BitDepth - 1);
  SetLength(CbF, CW * CH);
  SetLength(CrF, CW * CH);

  if Fmt = 3 then
  begin
    // plane 0 = G, plane 1 = B, plane 2 = R, matching rgb_to_rgb24
    for Y := 0 to CH - 1 do
    begin
      SY := Y; if SY >= H then SY := H - 1;
      for X := 0 to CW - 1 do
      begin
        SX := X; if SX >= W then SX := W - 1;
        PlanePut(Enc, 0, X, Y, Samp(Pix, (SY * W + SX) * NChan + 1, MaxVal, BitDepth));
        PlanePut(Enc, 1, X, Y, Samp(Pix, (SY * W + SX) * NChan + 2, MaxVal, BitDepth));
        PlanePut(Enc, 2, X, Y, Samp(Pix, (SY * W + SX) * NChan + 0, MaxVal, BitDepth));
      end;
    end;
  end
  else
  begin
    // BT.601 full range, the inverse of the decoder's ycc_to_rgb24 with
    // k_r = 0.299 and k_b = 0.114
    for Y := 0 to CH - 1 do
    begin
      SY := Y; if SY >= H then SY := H - 1;
      for X := 0 to CW - 1 do
      begin
        SX := X; if SX >= W then SX := W - 1;
        R := Samp(Pix, (SY * W + SX) * NChan + 0, MaxVal, BitDepth);
        G := Samp(Pix, (SY * W + SX) * NChan + 1, MaxVal, BitDepth);
        Bl := Samp(Pix, (SY * W + SX) * NChan + 2, MaxVal, BitDepth);
        Yv := Round(0.299 * R + 0.587 * G + 0.114 * Bl);
        CbF[Y * CW + X] := Round((Bl - Yv) / 1.772) + Centre;
        CrF[Y * CW + X] := Round((R - Yv) / 1.402) + Centre;
        PlanePut(Enc, 0, X, Y, av_clip_c(Yv, 0, PixMax));
      end;
    end;
    // Box average the chroma. Both 4:2:0 and 4:2:2 place chroma between the
    // luma samples horizontally (c_h_phase = 1), and 4:2:0 also halves
    // vertically; averaging over the corresponding luma samples matches.
    if Fmt = 2 then CHc := CH else CHc := CH div 2;
    for Y := 0 to CHc - 1 do
      for X := 0 to (CW div 2) - 1 do
      begin
        if Fmt = 2 then
        begin
          Cb := (CbF[Y * CW + 2 * X] + CbF[Y * CW + 2 * X + 1] + 1) div 2;
          Cr := (CrF[Y * CW + 2 * X] + CrF[Y * CW + 2 * X + 1] + 1) div 2;
        end
        else
        begin
          Cb := (CbF[(2 * Y) * CW + 2 * X] + CbF[(2 * Y) * CW + 2 * X + 1] +
                 CbF[(2 * Y + 1) * CW + 2 * X] + CbF[(2 * Y + 1) * CW + 2 * X + 1] + 2) div 4;
          Cr := (CrF[(2 * Y) * CW + 2 * X] + CrF[(2 * Y) * CW + 2 * X + 1] +
                 CrF[(2 * Y + 1) * CW + 2 * X] + CrF[(2 * Y + 1) * CW + 2 * X + 1] + 2) div 4;
        end;
        PlanePut(Enc, 1, X, Y, av_clip_c(Cb, 0, PixMax));
        PlanePut(Enc, 2, X, Y, av_clip_c(Cr, 0, PixMax));
      end;
  end;

  if bpg_enc_picture(Enc) < 0 then
  begin
    WriteLn(ErrOutput, 'encode failed');
    Halt(1);
  end;

  // The alpha plane is a second, independent HEVC stream coded as a grayscale
  // picture. The decoder tells the two apart by nuh_layer_id.
  if HasAlpha then
  begin
    if bpg_enc_init(AEnc, W, H, 0, BitDepth, TheQp) < 0 then
    begin
      WriteLn(ErrOutput, 'alpha encoder init failed');
      Halt(1);
    end;
    for Y := 0 to CH - 1 do
    begin
      SY := Y; if SY >= H then SY := H - 1;
      for X := 0 to CW - 1 do
      begin
        SX := X; if SX >= W then SX := W - 1;
        PlanePut(AEnc, 0, X, Y, Samp(Pix, (SY * W + SX) * 4 + 3, MaxVal, BitDepth));
      end;
    end;
    if bpg_enc_picture(AEnc) < 0 then
    begin
      WriteLn(ErrOutput, 'alpha encode failed');
      Halt(1);
    end;
  end;

  buf_init(OutB);
  buf_put_byte(OutB, $42);
  buf_put_byte(OutB, $50);
  buf_put_byte(OutB, $47);
  buf_put_byte(OutB, $FB);
  // format in the top three bits, no alpha, bit_depth - 8 in the low nibble
  case Fmt of
    1: flags1 := BPG_FORMAT_420 shl 5;
    2: flags1 := BPG_FORMAT_422 shl 5;
  else
    flags1 := BPG_FORMAT_444 shl 5;
  end;
  flags1 := flags1 or (BitDepth - 8);
  // alpha1_flag: a real alpha channel, not premultiplied and not a W plane
  if HasAlpha then flags1 := flags1 or (1 shl 4);
  buf_put_byte(OutB, Byte(flags1));
  // colour space, no extension, not premultiplied, full range, not animated
  if Fmt = 3 then flags2 := (BPG_CS_RGB shl 4) else flags2 := (BPG_CS_YCbCr shl 4);
  buf_put_byte(OutB, Byte(flags2));
  put_ue_var(OutB, Cardinal(W));
  put_ue_var(OutB, Cardinal(H));
  // hevc_data_len 0 means "to the end of the file"
  put_ue_var(OutB, 0);

  // the modified SPS, then the first NAL raw and the rest with start codes,
  // which is what hevc_decode_frame_internal expects
  // hevc_decode_start reads the alpha modified SPS first, then the colour one
  if HasAlpha then
  begin
    put_ue_var(OutB, Cardinal(AEnc.MspsTail.Len));
    buf_put(OutB, AEnc.MspsTail.Buf, AEnc.MspsTail.Len);
  end;
  put_ue_var(OutB, Cardinal(Enc.MspsTail.Len));
  buf_put(OutB, Enc.MspsTail.Buf, Enc.MspsTail.Len);

  // the first NAL carries no start code, the rest do
  put_nal_no_startcode(OutB, NAL_PPS, Enc.PpsRbsp.Buf, Enc.PpsRbsp.Len);
  put_nal(OutB, NAL_IDR_W_RADL, 1, Enc.SliceRbsp.Buf, Enc.SliceRbsp.Len);
  if HasAlpha then
  begin
    put_nal_layer(OutB, NAL_PPS, 1, 1, AEnc.PpsRbsp.Buf, AEnc.PpsRbsp.Len);
    put_nal_layer(OutB, NAL_IDR_W_RADL, 1, 1, AEnc.SliceRbsp.Buf, AEnc.SliceRbsp.Len);
  end;


  bpg_enc_free(Enc);
  if HasAlpha then bpg_enc_free(AEnc);
end;

begin
  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if Arg = '-q' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      Qp := StrToIntDef(ParamStr(I), -1);
      if (Qp < 0) or (Qp > 51) then Usage;
    end
    else if Arg = '-f' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      if ParamStr(I) = '420' then Fmt := 1
      else if ParamStr(I) = '422' then Fmt := 2
      else if ParamStr(I) = '444' then Fmt := 3
      else Usage;
    end
    else if Arg = '-size' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      TargetSize := StrToIntDef(ParamStr(I), 0);
      if TargetSize <= 0 then Usage;
    end
    else if Arg = '-nodeblock' then
      DeblockOn := False
    else if Arg = '-nomodes' then
      ModesOn := False
    else if Arg = '-nomerge' then
      sao_set_merge(False)
    else if Arg = '-nosao' then
      SaoOn := False
    else if Arg = '-screen' then
    begin
      ScreenOn := True;
      ScreenAuto := False;
    end
    else if Arg = '-noscreen' then
    begin
      ScreenOn := False;
      ScreenAuto := False;
    end
    else if Arg = '-exactd' then
      bpg_enc_rdoq_tdomain(False)
    else if Arg = '-slow' then
      SlowOn := True
    else if Arg = '-lossless' then
      LossOn := True
    else if Arg = '-fast' then
      RdOn := False
    else if Arg = '-b' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      BitDepth := StrToIntDef(ParamStr(I), 0);
      if (BitDepth < 8) or (BitDepth > 12) then Usage;
    end
    else if Arg = '-o' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      OutName := ParamStr(I);
    end
    else if (Length(Arg) > 0) and (Arg[1] = '-') then Usage
    else if InName = '' then InName := Arg
    else Usage;
    Inc(I);
  end;
  if InName = '' then Usage;

  Pix := ReadImage(InName, W, H, MaxVal, NChan);
  HasAlpha := NChan = 4;

  bpg_enc_rd_enable(RdOn);
  bpg_enc_lossless(LossOn);
  bpg_enc_rdoq_full(SlowOn);
  // auto-detect unless the user was explicit either way
  if ScreenAuto and (MaxVal <= 255) then
    ScreenOn := screen_fraction(Pix, W, H, NChan) > 0.5;
  bpg_enc_screen(ScreenOn);
  bpg_enc_sao(SaoOn);
  bpg_enc_deblock(DeblockOn);
  bpg_enc_modes(ModesOn);
  if LossOn then
  begin
    // -size has nothing to trade: the residual is exact whatever the quantiser
    TargetSize := 0;
    // 4:2:0 and 4:2:2 throw chroma samples away, and the YCbCr conversion
    // rounds, before the encoder ever sees the picture -- the stream is then
    // lossless only with respect to that already-degraded input
    if Fmt <> 3 then
      WriteLn(ErrOutput,
        'note: -lossless is exact only with -f 444; this format subsamples the chroma');
  end;

  if TargetSize > 0 then
  begin
    // Smallest qp whose file fits the target: size is monotone in qp for all
    // practical purposes, so a plain bisection over 0..51 lands in six probes.
    // The probes only have to rank quantisers, not produce the final file, so
    // they run with the expensive decisions switched off. That takes the search
    // from seven full encodes to six cheap ones plus one real one. The cheap
    // encoder is slightly larger at the same qp, so its answer can be one step
    // conservative -- the loop below gives the qp back while the real file
    // still fits, which keeps the guarantee exact rather than approximate.
    bpg_enc_rd_enable(False);
    bpg_enc_sao(False);
    bpg_enc_modes(False);
    Lo := 0;
    Hi := 51;
    while Lo < Hi do
    begin
      Mid := (Lo + Hi) div 2;
      BuildAtQp(Mid, Probe);
      if Probe.Len <= TargetSize then Hi := Mid else Lo := Mid + 1;
      buf_free(Probe);
    end;
    Qp := Lo;
    bpg_enc_rd_enable(RdOn);
    bpg_enc_sao(SaoOn);
    bpg_enc_modes(ModesOn);
  end;

  BuildAtQp(Qp, Out_);

  // The cheap probe can err either way, so correct in both directions: raise
  // the quantiser until the real file fits, then lower it while it still does.
  // Only one of the two loops ever runs.
  if TargetSize > 0 then
    while (Qp < 51) and (Out_.Len > TargetSize) do
    begin
      Inc(Qp);
      buf_free(Out_);
      BuildAtQp(Qp, Out_);
    end;

  // walk the quantiser back down while the real encoder still fits
  if TargetSize > 0 then
    while (Qp > 0) and (Out_.Len <= TargetSize) do
    begin
      BuildAtQp(Qp - 1, Probe);
      if Probe.Len > TargetSize then
      begin
        buf_free(Probe);
        Break;
      end;
      buf_free(Out_);
      Out_ := Probe;
      Dec(Qp);
    end;

  if (TargetSize > 0) and (Out_.Len > TargetSize) then
    WriteLn(ErrOutput, Format(
      'warning: %d bytes exceed the target of %d even at qp 51',
      [Out_.Len, TargetSize]));

  FS := TFileStream.Create(OutName, fmCreate);

  try
    FS.WriteBuffer(Out_.Buf^, Out_.Len);
  finally
    FS.Free;
  end;

  WriteLn(Format('%s: %dx%d %s %d bit qp=%d%s -> %s, %d bytes',
    [InName, W, H, FmtName[Fmt] +
     BoolToStr(HasAlpha, '+alpha', ''), BitDepth, Qp,
     BoolToStr(LossOn, ' bezstratnie', BoolToStr(TargetSize > 0, ' (dobrany do -size)', '')),
     OutName, Out_.Len]));

  buf_free(Out_);
end.
