// BPG decoder -- Free Pascal port of libbpg 0.9.8
// Reference-counted picture buffers, standing in for the parts of
// libavutil/frame.c and libavutil/buffer.c that the decoder uses.
//
// The reference goes through AVBufferRef/AVFrame with a buffer pool and the
// threading wrappers (ff_thread_get_buffer / ff_thread_release_buffer);
// libbpg is single-threaded, so plain reference counting is enough.
unit h265_frame;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  h265_common, h265_hevc_defs;

function av_buffer_alloc(Size: SizeInt): PBufRef;
function av_buffer_allocz(Size: SizeInt): PBufRef;
function av_buffer_ref(Buf: PBufRef): PBufRef;
procedure av_buffer_unref(var Buf: PBufRef);

function av_frame_alloc: PAVFrame;
procedure av_frame_free(var F: PAVFrame);
procedure av_frame_unref(F: PAVFrame);
function av_frame_ref(Dst, Src: PAVFrame): Integer;
procedure av_frame_move_ref(Dst, Src: PAVFrame);

// allocates the three 16-bit planes for the given chroma format
function frame_get_buffer(F: PAVFrame; Width, Height, ChromaFormatIdc: Integer): Integer;

implementation

const
  LINESIZE_ALIGN = 32;

function av_buffer_alloc(Size: SizeInt): PBufRef;
begin
  Result := av_mallocz(SizeOf(TBufRef));
  if Result = nil then Exit(nil);
  Result^.Data := av_malloc(Size + FF_INPUT_BUFFER_PADDING_SIZE);
  if Result^.Data = nil then
  begin
    FreeMem(Result);
    Exit(nil);
  end;
  Result^.Size := Size;
  Result^.RefCount := 1;
end;

function av_buffer_allocz(Size: SizeInt): PBufRef;
begin
  Result := av_buffer_alloc(Size);
  if Result <> nil then
    FillChar(Result^.Data^, Size + FF_INPUT_BUFFER_PADDING_SIZE, 0);
end;

function av_buffer_ref(Buf: PBufRef): PBufRef;
begin
  if Buf = nil then Exit(nil);
  Inc(Buf^.RefCount);
  Result := Buf;
end;

procedure av_buffer_unref(var Buf: PBufRef);
begin
  if Buf = nil then Exit;
  Dec(Buf^.RefCount);
  if Buf^.RefCount <= 0 then
  begin
    av_free(Buf^.Data);
    FreeMem(Buf);
  end;
  Buf := nil;
end;

function av_frame_alloc: PAVFrame;
begin
  Result := av_mallocz(SizeOf(TAVFrame));
end;

procedure av_frame_free(var F: PAVFrame);
begin
  if F = nil then Exit;
  av_frame_unref(F);
  av_free(F);
  F := nil;
end;

procedure av_frame_unref(F: PAVFrame);
var
  I: Integer;
begin
  if F = nil then Exit;
  for I := 0 to 2 do
  begin
    av_buffer_unref(F^.Buf[I]);
    F^.Data[I] := nil;
    F^.Linesize[I] := 0;
  end;
  F^.Width := 0;
  F^.Height := 0;
end;

function av_frame_ref(Dst, Src: PAVFrame): Integer;
var
  I: Integer;
begin
  av_frame_unref(Dst);
  Dst^.Width := Src^.Width;
  Dst^.Height := Src^.Height;
  Dst^.Format := Src^.Format;
  Dst^.KeyFrame := Src^.KeyFrame;
  Dst^.PictType := Src^.PictType;
  Dst^.Pts := Src^.Pts;
  for I := 0 to 2 do
  begin
    Dst^.Buf[I] := av_buffer_ref(Src^.Buf[I]);
    Dst^.Data[I] := Src^.Data[I];
    Dst^.Linesize[I] := Src^.Linesize[I];
  end;
  Result := 0;
end;

procedure av_frame_move_ref(Dst, Src: PAVFrame);
begin
  Dst^ := Src^;
  FillChar(Src^, SizeOf(TAVFrame), 0);
end;

function frame_get_buffer(F: PAVFrame; Width, Height, ChromaFormatIdc: Integer): Integer;
var
  I, PW, PH, HShift, VShift, LS: Integer;
  NumPlanes: Integer;
begin
  av_frame_unref(F);
  F^.Width := Width;
  F^.Height := Height;

  case ChromaFormatIdc of
    0: begin HShift := 0; VShift := 0; NumPlanes := 1; end;
    1: begin HShift := 1; VShift := 1; NumPlanes := 3; end;
    2: begin HShift := 1; VShift := 0; NumPlanes := 3; end;
  else
    begin HShift := 0; VShift := 0; NumPlanes := 3; end;
  end;

  for I := 0 to NumPlanes - 1 do
  begin
    if I = 0 then
    begin
      PW := Width;
      PH := Height;
    end
    else
    begin
      PW := (Width + (1 shl HShift) - 1) shr HShift;
      PH := (Height + (1 shl VShift) - 1) shr VShift;
    end;
    LS := PW * 2; // 16 bits per sample
    LS := (LS + LINESIZE_ALIGN - 1) and (not (LINESIZE_ALIGN - 1));
    F^.Buf[I] := av_buffer_allocz(SizeInt(LS) * PH);
    if F^.Buf[I] = nil then
    begin
      av_frame_unref(F);
      Exit(AVERROR_ENOMEM);
    end;
    F^.Data[I] := F^.Buf[I]^.Data;
    F^.Linesize[I] := LS;
  end;
  for I := NumPlanes to 2 do
  begin
    F^.Buf[I] := nil;
    F^.Data[I] := nil;
    F^.Linesize[I] := 0;
  end;
  Result := 0;
end;

end.
