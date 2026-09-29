// BPG decoder -- Free Pascal port of libbpg 0.9.8
// SEI message parsing (only the picture hash and BPG's frame-duration message
// are interpreted; everything else is skipped).
// Corresponds to: libavcodec/hevc_sei.c
unit bpg_hevc_sei;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  bpg_common, bpg_bits, bpg_hevc_defs;

function ff_hevc_decode_nal_sei(S: PHEVCContext): Integer;

implementation

procedure decode_nal_sei_decoded_picture_hash(S: PHEVCContext);
var
  cIdx, I: Integer;
  hash_type: Byte;
  GB: PGetBitContext;
begin
  GB := @S^.HEVClc^.gb;
  hash_type := Byte(get_bits(GB^, 8));
  for cIdx := 0 to 2 do
  begin
    if hash_type = 0 then
    begin
      // USE_MD5 is off: the hash is parsed but not checked
      for I := 0 to 15 do
        get_bits(GB^, 8);
    end
    else if hash_type = 1 then
      skip_bits(GB^, 16)
    else if hash_type = 2 then
      skip_bits(GB^, 32);
  end;
end;

function decode_nal_sei_message(S: PHEVCContext): Integer;
var
  GB: PGetBitContext;
  payload_type, payload_size, B: Integer;
begin
  GB := @S^.HEVClc^.gb;
  payload_type := 0;
  payload_size := 0;
  B := $FF;
  while B = $FF do
  begin
    B := Integer(get_bits(GB^, 8));
    payload_type := payload_type + B;
  end;
  B := $FF;
  while B = $FF do
  begin
    B := Integer(get_bits(GB^, 8));
    payload_size := payload_size + B;
  end;
  if S^.nal_unit_type = NAL_SEI_PREFIX then
  begin
    if payload_type = 256 then
      decode_nal_sei_decoded_picture_hash(S)
    else if payload_type = 257 then
      // USE_FRAME_DURATION_SEI: BPG stores the animation frame duration here
      S^.frame_duration := Word(get_bits(GB^, 16))
    else
      skip_bits(GB^, 8 * payload_size);
  end
  else
  begin
    if payload_type = 132 then
      decode_nal_sei_decoded_picture_hash(S)
    else
      skip_bits(GB^, 8 * payload_size);
  end;
  Result := 1;
end;

function more_rbsp_data(GB: PGetBitContext): Boolean;
begin
  Result := (get_bits_left(GB^) > 0) and (show_bits(GB^, 8) <> $80);
end;

function ff_hevc_decode_nal_sei(S: PHEVCContext): Integer;
var
  Ret: Integer;
begin
  repeat
    Ret := decode_nal_sei_message(S);
    if Ret < 0 then Exit(AVERROR_ENOMEM);
  until not more_rbsp_data(@S^.HEVClc^.gb);
  Result := 1;
end;

end.
