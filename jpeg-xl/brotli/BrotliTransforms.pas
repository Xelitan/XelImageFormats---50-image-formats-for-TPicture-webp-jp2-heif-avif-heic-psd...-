unit BrotliTransforms;

// Author: www.xelitan.com
// License: MIT

{$mode Delphi}
{$H+}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses SysUtils, BrotliBase;

const
  BROTLI_TRANSFORM_IDENTITY = 0;
  BROTLI_TRANSFORM_OMIT_LAST_1 = 1;
  BROTLI_TRANSFORM_OMIT_LAST_2 = 2;
  BROTLI_TRANSFORM_OMIT_LAST_3 = 3;
  BROTLI_TRANSFORM_OMIT_LAST_4 = 4;
  BROTLI_TRANSFORM_OMIT_LAST_5 = 5;
  BROTLI_TRANSFORM_OMIT_LAST_6 = 6;
  BROTLI_TRANSFORM_OMIT_LAST_7 = 7;
  BROTLI_TRANSFORM_OMIT_LAST_8 = 8;
  BROTLI_TRANSFORM_OMIT_LAST_9 = 9;
  BROTLI_TRANSFORM_UPPERCASE_FIRST = 10;
  BROTLI_TRANSFORM_UPPERCASE_ALL = 11;
  BROTLI_TRANSFORM_OMIT_FIRST_1 = 12;
  BROTLI_TRANSFORM_OMIT_FIRST_2 = 13;
  BROTLI_TRANSFORM_OMIT_FIRST_3 = 14;
  BROTLI_TRANSFORM_OMIT_FIRST_4 = 15;
  BROTLI_TRANSFORM_OMIT_FIRST_5 = 16;
  BROTLI_TRANSFORM_OMIT_FIRST_6 = 17;
  BROTLI_TRANSFORM_OMIT_FIRST_7 = 18;
  BROTLI_TRANSFORM_OMIT_FIRST_8 = 19;
  BROTLI_TRANSFORM_OMIT_FIRST_9 = 20;
  BROTLI_TRANSFORM_SHIFT_FIRST = 21;
  BROTLI_TRANSFORM_SHIFT_ALL = 22;
  BROTLI_NUM_TRANSFORM_TYPES = 23;
  BROTLI_TRANSFORMS_MAX_CUT_OFF = BROTLI_TRANSFORM_OMIT_LAST_9;

type
  TBrotliTransformCutOffArray = array[0..BROTLI_TRANSFORMS_MAX_CUT_OFF] of SmallInt;
  TBrotliTransforms = record
    prefix_suffix_size: uint16_t;
    prefix_suffix: PByte;
    prefix_suffix_map: PWord;
    num_transforms: uint32_t;
    transforms: PByte;
    params: PByte;
    cutOffTransforms: TBrotliTransformCutOffArray;
  end;
  PBrotliTransforms = ^TBrotliTransforms;

function BrotliGetTransforms: PBrotliTransforms;
function BrotliTransformPrefixId(transforms: PBrotliTransforms; idx: Integer): uint8_t; inline;
function BrotliTransformType(transforms: PBrotliTransforms; idx: Integer): uint8_t; inline;
function BrotliTransformSuffixId(transforms: PBrotliTransforms; idx: Integer): uint8_t; inline;
function BrotliTransformPrefix(transforms: PBrotliTransforms; idx: Integer): PByte; inline;
function BrotliTransformSuffix(transforms: PBrotliTransforms; idx: Integer): PByte; inline;
function BrotliTransformDictionaryWord(dst: PByte; word: PByte; len: Integer; transforms: PBrotliTransforms; transform_idx: Integer): Integer;

implementation

const
  kPrefixSuffix: array[0..216] of uint8_t = (
    $01, $20, $02, $2C, $20, $08, $20, $6F, $66, $20, $74, $68, $65, $20, $04, $20,
    $6F, $66, $20, $02, $73, $20, $01, $2E, $05, $20, $61, $6E, $64, $20, $04, $20,
    $69, $6E, $20, $01, $22, $04, $20, $74, $6F, $20, $02, $22, $3E, $01, $0A, $02,
    $2E, $20, $01, $5D, $05, $20, $66, $6F, $72, $20, $03, $20, $61, $20, $06, $20,
    $74, $68, $61, $74, $20, $01, $27, $06, $20, $77, $69, $74, $68, $20, $06, $20,
    $66, $72, $6F, $6D, $20, $04, $20, $62, $79, $20, $01, $28, $06, $2E, $20, $54,
    $68, $65, $20, $04, $20, $6F, $6E, $20, $04, $20, $61, $73, $20, $04, $20, $69,
    $73, $20, $04, $69, $6E, $67, $20, $02, $0A, $09, $01, $3A, $03, $65, $64, $20,
    $02, $3D, $22, $04, $20, $61, $74, $20, $03, $6C, $79, $20, $01, $2C, $02, $3D,
    $27, $05, $2E, $63, $6F, $6D, $2F, $07, $2E, $20, $54, $68, $69, $73, $20, $05,
    $20, $6E, $6F, $74, $20, $03, $65, $72, $20, $03, $61, $6C, $20, $04, $66, $75,
    $6C, $20, $04, $69, $76, $65, $20, $05, $6C, $65, $73, $73, $20, $04, $65, $73,
    $74, $20, $04, $69, $7A, $65, $20, $02, $C2, $A0, $04, $6F, $75, $73, $20, $05,
    $20, $74, $68, $65, $20, $02, $65, $20, $00
  );

  kPrefixSuffixMap: array[0..49] of uint16_t = (
    0, 2, 5, 14, 19, 22, 24, 30, 35, 37, 42, 45, 47, 50, 52, 58,
    62, 69, 71, 78, 85, 90, 92, 99, 104, 109, 114, 119, 122, 124, 128, 131,
    136, 140, 142, 145, 151, 159, 165, 169, 173, 178, 183, 189, 194, 199, 202, 207,
    213, 216
  );

  kTransformsData: array[0..362] of uint8_t = (
    $31, $00, $31, $31, $00, $00, $00, $00, $00, $31, $0C, $31, $31, $0A, $00,
    $31, $00, $2F, $00, $00, $31, $04, $00, $00, $31, $00, $03, $31, $0A, $31,
    $31, $00, $06, $31, $0D, $31, $31, $01, $31, $01, $00, $00, $31, $00, $01,
    $00, $0A, $00, $31, $00, $07, $31, $00, $09, $30, $00, $00, $31, $00, $08,
    $31, $00, $05, $31, $00, $0A, $31, $00, $0B, $31, $03, $31, $31, $00, $0D,
    $31, $00, $0E, $31, $0E, $31, $31, $02, $31, $31, $00, $0F, $31, $00, $10,
    $00, $0A, $31, $31, $00, $0C, $05, $00, $31, $00, $00, $01, $31, $0F, $31,
    $31, $00, $12, $31, $00, $11, $31, $00, $13, $31, $00, $14, $31, $10, $31,
    $31, $11, $31, $2F, $00, $31, $31, $04, $31, $31, $00, $16, $31, $0B, $31,
    $31, $00, $17, $31, $00, $18, $31, $00, $19, $31, $07, $31, $31, $01, $1A,
    $31, $00, $1B, $31, $00, $1C, $00, $00, $0C, $31, $00, $1D, $31, $14, $31,
    $31, $12, $31, $31, $06, $31, $31, $00, $15, $31, $0A, $01, $31, $08, $31,
    $31, $00, $1F, $31, $00, $20, $2F, $00, $03, $31, $05, $31, $31, $09, $31,
    $00, $0A, $01, $31, $0A, $08, $05, $00, $15, $31, $0B, $00, $31, $0A, $0A,
    $31, $00, $1E, $00, $00, $05, $23, $00, $31, $2F, $00, $02, $31, $0A, $11,
    $31, $00, $24, $31, $00, $21, $05, $00, $00, $31, $0A, $15, $31, $0A, $05,
    $31, $00, $25, $00, $00, $1E, $31, $00, $26, $00, $0B, $00, $31, $00, $27,
    $00, $0B, $31, $31, $00, $22, $31, $0B, $08, $31, $0A, $0C, $00, $00, $15,
    $31, $00, $28, $00, $0A, $0C, $31, $00, $29, $31, $00, $2A, $31, $0B, $11,
    $31, $00, $2B, $00, $0A, $05, $31, $0B, $0A, $00, $00, $22, $31, $0A, $21,
    $31, $00, $2C, $31, $0B, $05, $2D, $00, $31, $00, $00, $21, $31, $0A, $1E,
    $31, $0B, $1E, $31, $00, $2E, $31, $0B, $01, $31, $0A, $22, $00, $0A, $21,
    $00, $0B, $1E, $00, $0B, $01, $31, $0B, $21, $31, $0B, $15, $31, $0B, $0C,
    $00, $0B, $05, $31, $0B, $22, $00, $0B, $0C, $00, $0A, $1E, $00, $0B, $22,
    $00, $0A, $22
  );

  kCutOffTransforms: TBrotliTransformCutOffArray = (0, 12, 27, 23, 42, 63, 56, 48, 59, 64);

var
  kBrotliTransforms: TBrotliTransforms = (
    prefix_suffix_size: 217;
    prefix_suffix: @kPrefixSuffix[0];
    prefix_suffix_map: @kPrefixSuffixMap[0];
    num_transforms: 121;
    transforms: @kTransformsData[0];
    params: nil;
    cutOffTransforms: (0, 12, 27, 23, 42, 63, 56, 48, 59, 64)
  );

function BrotliGetTransforms: PBrotliTransforms;
begin
  Result := @kBrotliTransforms;
end;

function BrotliTransformPrefixId(transforms: PBrotliTransforms; idx: Integer): uint8_t; inline;
begin
  Result := transforms^.transforms[idx * 3];
end;

function BrotliTransformType(transforms: PBrotliTransforms; idx: Integer): uint8_t; inline;
begin
  Result := transforms^.transforms[idx * 3 + 1];
end;

function BrotliTransformSuffixId(transforms: PBrotliTransforms; idx: Integer): uint8_t; inline;
begin
  Result := transforms^.transforms[idx * 3 + 2];
end;

function BrotliTransformPrefix(transforms: PBrotliTransforms; idx: Integer): PByte; inline;
begin
  Result := transforms^.prefix_suffix + transforms^.prefix_suffix_map[BrotliTransformPrefixId(transforms, idx)];
end;

function BrotliTransformSuffix(transforms: PBrotliTransforms; idx: Integer): PByte; inline;
begin
  Result := transforms^.prefix_suffix + transforms^.prefix_suffix_map[BrotliTransformSuffixId(transforms, idx)];
end;

function ToUpperCase(p: PByte): Integer;
begin
  if p[0] < $C0 then begin
    if (p[0] >= Ord('a')) and (p[0] <= Ord('z')) then p[0] := p[0] xor 32;
    Result := 1;
  end else if p[0] < $E0 then begin
    p[1] := p[1] xor 32;
    Result := 2;
  end else begin
    p[2] := p[2] xor 5;
    Result := 3;
  end;
end;

function Shift(word: PByte; word_len: Integer; parameter: uint16_t): Integer;
var scalar: uint32_t;
begin
  scalar := (parameter and $7FFF) + ($1000000 - (parameter and $8000));
  if word[0] < $80 then begin
    scalar := scalar + word[0];
    word[0] := uint8_t(scalar and $7F);
    Result := 1;
  end else if word[0] < $C0 then begin
    Result := 1;
  end else if word[0] < $E0 then begin
    if word_len < 2 then Exit(1);
    scalar := scalar + ((word[1] and $3F) or ((word[0] and $1F) shl 6));
    word[0] := uint8_t($C0 or ((scalar shr 6) and $1F));
    word[1] := uint8_t((word[1] and $C0) or (scalar and $3F));
    Result := 2;
  end else if word[0] < $F0 then begin
    if word_len < 3 then Exit(word_len);
    scalar := scalar + ((word[2] and $3F) or ((word[1] and $3F) shl 6) or ((word[0] and $0F) shl 12));
    word[0] := uint8_t($E0 or ((scalar shr 12) and $0F));
    word[1] := uint8_t((word[1] and $C0) or ((scalar shr 6) and $3F));
    word[2] := uint8_t((word[2] and $C0) or (scalar and $3F));
    Result := 3;
  end else if word[0] < $F8 then begin
    if word_len < 4 then Exit(word_len);
    scalar := scalar + ((word[3] and $3F) or ((word[2] and $3F) shl 6) or ((word[1] and $3F) shl 12) or ((word[0] and $07) shl 18));
    word[0] := uint8_t($F0 or ((scalar shr 18) and $07));
    word[1] := uint8_t((word[1] and $C0) or ((scalar shr 12) and $3F));
    word[2] := uint8_t((word[2] and $C0) or ((scalar shr 6) and $3F));
    word[3] := uint8_t((word[3] and $C0) or (scalar and $3F));
    Result := 4;
  end else Result := 1;
end;

function BrotliTransformDictionaryWord(dst: PByte; word: PByte; len: Integer; transforms: PBrotliTransforms; transform_idx: Integer): Integer;
var
  idx, prefix_len, suffix_len, t, i, skip, step: Integer;
  prefix, suffix, uppercase, shiftp: PByte;
  typ: uint8_t;
  param: uint16_t;
begin
  idx := 0;
  prefix := BrotliTransformPrefix(transforms, transform_idx);
  typ := BrotliTransformType(transforms, transform_idx);
  suffix := BrotliTransformSuffix(transforms, transform_idx);

  prefix_len := prefix[0]; Inc(prefix);
  while prefix_len > 0 do begin dst[idx] := prefix[0]; Inc(idx); Inc(prefix); Dec(prefix_len); end;

  t := typ;
  i := 0;
  if t <= BROTLI_TRANSFORM_OMIT_LAST_9 then begin
    Dec(len, t);
  end else if (t >= BROTLI_TRANSFORM_OMIT_FIRST_1) and (t <= BROTLI_TRANSFORM_OMIT_FIRST_9) then begin
    skip := t - (BROTLI_TRANSFORM_OMIT_FIRST_1 - 1);
    Inc(word, skip);
    Dec(len, skip);
  end;
  if len < 0 then len := 0;
  while i < len do begin dst[idx] := word[i]; Inc(idx); Inc(i); end;

  if t = BROTLI_TRANSFORM_UPPERCASE_FIRST then begin
    ToUpperCase(dst + idx - len);
  end else if t = BROTLI_TRANSFORM_UPPERCASE_ALL then begin
    uppercase := dst + idx - len;
    while len > 0 do begin
      step := ToUpperCase(uppercase);
      Inc(uppercase, step);
      Dec(len, step);
    end;
  end else if (t = BROTLI_TRANSFORM_SHIFT_FIRST) and (transforms^.params <> nil) then begin
    param := transforms^.params[transform_idx * 2] + (uint16_t(transforms^.params[transform_idx * 2 + 1]) shl 8);
    Shift(dst + idx - len, len, param);
  end else if (t = BROTLI_TRANSFORM_SHIFT_ALL) and (transforms^.params <> nil) then begin
    param := transforms^.params[transform_idx * 2] + (uint16_t(transforms^.params[transform_idx * 2 + 1]) shl 8);
    shiftp := dst + idx - len;
    while len > 0 do begin
      step := Shift(shiftp, len, param);
      Inc(shiftp, step);
      Dec(len, step);
    end;
  end;

  suffix_len := suffix[0]; Inc(suffix);
  while suffix_len > 0 do begin dst[idx] := suffix[0]; Inc(idx); Inc(suffix); Dec(suffix_len); end;
  Result := idx;
end;

end.
