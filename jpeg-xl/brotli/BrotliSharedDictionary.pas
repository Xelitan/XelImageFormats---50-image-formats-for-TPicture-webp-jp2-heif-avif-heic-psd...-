unit BrotliSharedDictionary;

// Author: www.xelitan.com
// License: MIT

{$mode Delphi}
{$H+}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses SysUtils, BrotliBase, BrotliTransforms;

type
  TBrotliSharedDictionaryType = (
    BROTLI_SHARED_DICTIONARY_RAW = 0,
    BROTLI_SHARED_DICTIONARY_SERIALIZED = 1
  );

  TBrotliSharedDictionary = record
    Data: PByte;
    Size: size_t;
    DictionaryType: TBrotliSharedDictionaryType;
    Transforms: PBrotliTransforms;
  end;
  PBrotliSharedDictionary = ^TBrotliSharedDictionary;

procedure BrotliSharedDictionaryInit(out dict: TBrotliSharedDictionary);
procedure BrotliSharedDictionaryAttachRaw(var dict: TBrotliSharedDictionary; data: PByte; size: size_t; transforms: PBrotliTransforms);
function BrotliSharedDictionaryIsAttached(const dict: TBrotliSharedDictionary): Boolean; inline;

implementation

procedure BrotliSharedDictionaryInit(out dict: TBrotliSharedDictionary);
begin
  FillChar(dict, SizeOf(dict), 0);
  dict.DictionaryType := BROTLI_SHARED_DICTIONARY_RAW;
end;

procedure BrotliSharedDictionaryAttachRaw(var dict: TBrotliSharedDictionary; data: PByte; size: size_t; transforms: PBrotliTransforms);
begin
  dict.Data := data;
  dict.Size := size;
  dict.DictionaryType := BROTLI_SHARED_DICTIONARY_RAW;
  dict.Transforms := transforms;
end;

function BrotliSharedDictionaryIsAttached(const dict: TBrotliSharedDictionary): Boolean; inline;
begin
  Result := (dict.Data <> nil) and (dict.Size > 0);
end;

end.
