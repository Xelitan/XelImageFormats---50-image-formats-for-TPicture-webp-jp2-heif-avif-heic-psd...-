unit XelBpg;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$POINTERMATH ON}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	BPG codec -> RGBA8 (wraps the bpg_* port in this folder)       //
// Version:	0.1                                                           //
// Date:	27-SEP-2026                                                   //
// License:     LGPL                                                          //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  SysUtils, Classes,
  bpg_common, bpg_putbits, bpg_hevc_defs, bpg_container,
  bpg_frame, bpg_output, bpg_enc, bpg_enc_rd;

type
  EBpgError = class(Exception);

// Decodes a BPG file to RGBA8 (whatever its bit depth and chroma format).
function DecodeBpg(InBuf: TBytes; out Width, Height: Integer): TBytes;    // RGBA8

// Encodes RGBA8 to BPG (alpha is not stored).
//   IsLossless : True = exact reconstruction (4:4:4 RGB, no quantiser).
//   Quality    : lossy quality 0..100 (higher = better), mapped onto the
//                format's quantiser 51..0.
function EncodeBpg(InBuf: TBytes; Width, Height: Integer;                 // InBuf = RGBA8
                   IsLossless: Boolean = False; Quality: Integer = 75): TBytes;

implementation

function DecodeBpg(InBuf: TBytes; out Width, Height: Integer): TBytes;
var
  Img : PBPGDecoderContext;
  Info: TBPGImageInfo;
  Y   : Integer;
begin
  Result := nil;
  Width := 0;
  Height := 0;
  if Length(InBuf) = 0 then
    raise EBpgError.Create('BPG: empty stream');

  Img := bpg_decoder_open;
  if Img = nil then
    raise EBpgError.Create('BPG: out of memory');
  try
    if bpg_decoder_decode(Img, @InBuf[0], Length(InBuf)) < 0 then
      raise EBpgError.Create('BPG decode failed');
    if bpg_decoder_get_info(Img, @Info) < 0 then
      raise EBpgError.Create('BPG: no image information');
    if (Integer(Info.width) <= 0) or (Integer(Info.height) <= 0) then
      raise EBpgError.Create('BPG: bad dimensions');

    // Always ask for 8-bit RGBA; the decoder converts depth and chroma.
    if bpg_decoder_start(Img, BPG_OUTPUT_FORMAT_RGBA32) < 0 then
      raise EBpgError.Create('BPG: unsupported output format');

    SetLength(Result, NativeInt(Info.width) * NativeInt(Info.height) * 4);
    for Y := 0 to Integer(Info.height) - 1 do
      if bpg_decoder_get_line(Img, @Result[NativeInt(Y) * NativeInt(Info.width) * 4]) < 0 then
        raise EBpgError.Create('BPG: truncated image');
    Width := Integer(Info.width);
    Height := Integer(Info.height);
  finally
    bpg_decoder_close(Img);
  end;
end;

function EncodeBpg(InBuf: TBytes; Width, Height: Integer;
                   IsLossless: Boolean = False; Quality: Integer = 75): TBytes;
var
  Enc: TBpgEncoder;
  Out_: TByteBuf;
  CW, CH, X, Y, SX, SY, Qp, q, P: Integer;
  flags1, flags2: Integer;
  R, G, Bl, Yv, Cb, Cr: Integer;
  CbF, CrF: array of Integer;

  procedure PlanePut(CIdx, PX, PY, V: Integer); inline;
  begin
    (PWord(Enc.Src^.Data[CIdx] + PY * Enc.Src^.Linesize[CIdx]) + PX)^ := Word(V);
  end;

begin
  Result := nil;
  if (Width <= 0) or (Height <= 0) or
     (NativeInt(Length(InBuf)) < NativeInt(Width) * NativeInt(Height) * 4) then
    raise EBpgError.Create('BPG encode: empty image');

  // Quality and quantiser run in opposite directions: 100 -> qp 0, 0 -> qp 51.
  q := Quality;
  if q < 0   then q := 0;
  if q > 100 then q := 100;
  Qp := 51 - Round(q * 51 / 100);

  bpg_enc_rd_enable(True);
  bpg_enc_lossless(IsLossless);

  // 4:4:4 codes the three planes as G, B, R with no colour conversion, which
  // is the only way a lossless file can be exact. Lossy uses 4:2:0.
  if IsLossless then
  begin
    if bpg_enc_init(Enc, Width, Height, 3, 8, Qp) < 0 then
      raise EBpgError.Create('BPG encode: init failed');
  end
  else
    if bpg_enc_init(Enc, Width, Height, 1, 8, Qp) < 0 then
      raise EBpgError.Create('BPG encode: init failed');

  try
    // The coded picture is rounded up to a whole minimum coding block; the true
    // size travels in the header and the decoder crops to it. The pad repeats
    // the edge pixels so it costs almost nothing to code.
    CW := Enc.Ctx.sps^.width;
    CH := Enc.Ctx.sps^.height;

    if IsLossless then
    begin
      for Y := 0 to CH - 1 do
      begin
        SY := Y; if SY >= Height then SY := Height - 1;
        for X := 0 to CW - 1 do
        begin
          SX := X; if SX >= Width then SX := Width - 1;
          P := (SY * Width + SX) * 4;            // R,G,B,A; the planes are G, B, R
          PlanePut(0, X, Y, InBuf[P + 1]);
          PlanePut(1, X, Y, InBuf[P + 2]);
          PlanePut(2, X, Y, InBuf[P + 0]);
        end;
      end;
    end
    else
    begin
      // BT.601 full range, the inverse of the decoder's ycc_to_rgb24 with
      // k_r = 0.299 and k_b = 0.114. Chroma is box averaged over the 2x2 luma
      // samples it covers, which is where 4:2:0 places it.
      SetLength(CbF, CW * CH);
      SetLength(CrF, CW * CH);
      for Y := 0 to CH - 1 do
      begin
        SY := Y; if SY >= Height then SY := Height - 1;
        for X := 0 to CW - 1 do
        begin
          SX := X; if SX >= Width then SX := Width - 1;
          P := (SY * Width + SX) * 4;
          R  := InBuf[P + 0];
          G  := InBuf[P + 1];
          Bl := InBuf[P + 2];
          Yv := Round(0.299 * R + 0.587 * G + 0.114 * Bl);
          CbF[Y * CW + X] := Round((Bl - Yv) / 1.772) + 128;
          CrF[Y * CW + X] := Round((R - Yv) / 1.402) + 128;
          PlanePut(0, X, Y, av_clip_c(Yv, 0, 255));
        end;
      end;
      for Y := 0 to (CH div 2) - 1 do
        for X := 0 to (CW div 2) - 1 do
        begin
          Cb := (CbF[(2 * Y) * CW + 2 * X] + CbF[(2 * Y) * CW + 2 * X + 1] +
                 CbF[(2 * Y + 1) * CW + 2 * X] + CbF[(2 * Y + 1) * CW + 2 * X + 1] + 2) div 4;
          Cr := (CrF[(2 * Y) * CW + 2 * X] + CrF[(2 * Y) * CW + 2 * X + 1] +
                 CrF[(2 * Y + 1) * CW + 2 * X] + CrF[(2 * Y + 1) * CW + 2 * X + 1] + 2) div 4;
          PlanePut(1, X, Y, av_clip_c(Cb, 0, 255));
          PlanePut(2, X, Y, av_clip_c(Cr, 0, 255));
        end;
    end;

    if bpg_enc_picture(Enc) < 0 then
      raise EBpgError.Create('BPG encode failed');

    buf_init(Out_);
    try
      buf_put_byte(Out_, $42);
      buf_put_byte(Out_, $50);
      buf_put_byte(Out_, $47);
      buf_put_byte(Out_, $FB);
      // format in the top three bits, no alpha, bit_depth - 8 in the low nibble
      if IsLossless then flags1 := BPG_FORMAT_444 shl 5
      else flags1 := BPG_FORMAT_420 shl 5;
      buf_put_byte(Out_, Byte(flags1));
      // colour space, no extension, not premultiplied, full range, not animated
      if IsLossless then flags2 := (BPG_CS_RGB shl 4)
      else flags2 := (BPG_CS_YCbCr shl 4);
      buf_put_byte(Out_, Byte(flags2));
      put_ue_var(Out_, Cardinal(Width));
      put_ue_var(Out_, Cardinal(Height));
      // hevc_data_len 0 means "to the end of the file"
      put_ue_var(Out_, 0);

      put_ue_var(Out_, Cardinal(Enc.MspsTail.Len));
      buf_put(Out_, Enc.MspsTail.Buf, Enc.MspsTail.Len);

      // the first NAL carries no start code, the rest do
      put_nal_no_startcode(Out_, NAL_PPS, Enc.PpsRbsp.Buf, Enc.PpsRbsp.Len);
      put_nal(Out_, NAL_IDR_W_RADL, 1, Enc.SliceRbsp.Buf, Enc.SliceRbsp.Len);

      SetLength(Result, Out_.Len);
      if Out_.Len > 0 then Move(Out_.Buf^, Result[0], Out_.Len);
    finally
      buf_free(Out_);
    end;
  finally
    bpg_enc_free(Enc);
  end;
end;

end.
