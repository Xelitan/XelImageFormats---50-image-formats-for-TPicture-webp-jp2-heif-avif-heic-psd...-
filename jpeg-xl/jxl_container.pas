{$mode delphi}
unit jxl_container;

// JPEG XL encoder/decoder in pure Pascal
// Author: www.xelitan.com
// License: MIT
//
// JPEG XL container (ISO Base Media File Format / ISOBMFF) parser.
// Extracts the raw codestream from the 'jxlc' or 'jxlp' boxes,
// or detects a bare codestream (no container) directly.

interface

uses
  SysUtils, Classes, jxl_types, SimpleBrotli;

const
  BOX_FTYP = $66747970;  // 'ftyp'
  BOX_JXLC = $6A786C63;  // 'jxlc' – full codestream
  BOX_JXLP = $6A786C70;  // 'jxlp' – partial codestream chunk
  BOX_BROB = $62726F62;  // 'brob' – Brotli-compressed metadata box

  JXL_SIG_BYTE0 = $FF;
  JXL_SIG_BYTE1 = $0A;

  JXL_CONTAINER_SIG: array[0..11] of Byte = (
    $00,$00,$00,$0C, $4A,$58,$4C,$20, $0D,$0A,$87,$0A
  );

type
  TByteArray = array of Byte;

  // A metadata box recovered from the container. For 'brob' boxes the content
  // has been Brotli-decompressed; InnerType is the wrapped box type (e.g.
  // 'Exif', 'xml ', 'jumb').
  TJxlMetaBox = record
    InnerType: Cardinal;
    Data:      TByteArray;
  end;
  TJxlMetaBoxArray = array of TJxlMetaBox;

function  IsJxlContainer(data: PByte; size: Int64): Boolean;
function  IsJxlCodestream(data: PByte; size: Int64): Boolean;

// Extract the JXL codestream from either a bare codestream or an ISOBMFF container.
// The caller owns the returned TByteArray.
function ExtractCodestream(srcData: PByte; srcSize: Int64): TByteArray;

// Metadata boxes collected during the most recent ExtractCodestream call
// ('brob' boxes are Brotli-decompressed via the bundled Brotli library).
function GetMetadataBoxes: TJxlMetaBoxArray;

implementation

{$WARN 5092 off}

var
  GMetaBoxes: TJxlMetaBoxArray;

function GetMetadataBoxes: TJxlMetaBoxArray;
begin
  Result := GMetaBoxes;
end;

function IsJxlContainer(data: PByte; size: Int64): Boolean;
var i: Integer;
begin
  if size < 12 then begin Result := False; Exit; end;
  for i := 0 to 11 do
    if data[i] <> JXL_CONTAINER_SIG[i] then begin Result := False; Exit; end;
  Result := True;
end;

function IsJxlCodestream(data: PByte; size: Int64): Boolean;
begin
  Result := (size >= 2) and (data[0] = JXL_SIG_BYTE0) and (data[1] = JXL_SIG_BYTE1);
end;

function ReadBE32(data: PByte; offset: Int64): Cardinal; inline;
begin
  Result := (Cardinal(data[offset])     shl 24)
          or(Cardinal(data[offset + 1]) shl 16)
          or(Cardinal(data[offset + 2]) shl  8)
           or Cardinal(data[offset + 3]);
end;

function ReadBE64(data: PByte; offset: Int64): UInt64; inline;
begin
  Result := (UInt64(ReadBE32(data, offset)) shl 32) or ReadBE32(data, offset + 4);
end;

// Decompress a 'brob' box payload (4-byte inner box type followed by a
// Brotli stream) using the bundled Brotli library (SimpleBrotli).
function DecompressBrob(srcData: PByte; dataStart, dataLen: Int64;
                        out innerType: Cardinal): TByteArray;
var
  inStr, outStr: TBytesStream;
  src: TBytes;
  rc: Integer;
begin
  Result    := nil;
  innerType := 0;
  if dataLen < 4 then Exit;
  innerType := ReadBE32(srcData, dataStart);
  SetLength(src, dataLen - 4);
  if Length(src) > 0 then
    Move(srcData[dataStart + 4], src[0], Length(src));
  inStr  := TBytesStream.Create(src);
  outStr := TBytesStream.Create;
  try
    rc := BrotliDecompressStreams(inStr, outStr);
    if rc = BROTLI_OK then begin
      SetLength(Result, outStr.Size);
      if outStr.Size > 0 then
        Move(outStr.Bytes[0], Result[0], outStr.Size);
    end;
  finally
    inStr.Free;
    outStr.Free;
  end;
end;

function ExtractCodestream(srcData: PByte; srcSize: Int64): TByteArray;
var
  pos, dataStart, dataLen, partSize, tmpSize: Int64;
  boxSize: UInt64;
  boxType, seqNum, innerType: Cardinal;
  partBuf, tmpBuf, brobData: TByteArray;
  n: Integer;
begin
  Result   := nil;
  partBuf  := nil;
  tmpBuf   := nil;
  SetLength(GMetaBoxes, 0);

  if IsJxlCodestream(srcData, srcSize) then begin
    n := Integer(srcSize);
    SetLength(Result, n);
    Move(srcData[0], Result[0], n);
    Exit;
  end;

  if not IsJxlContainer(srcData, srcSize) then
    raise EJxlError.Create('Not a valid JXL file (unknown signature)');

  SetLength(partBuf, 0);
  partSize := 0;
  pos      := 0;

  while pos < srcSize do begin
    if pos + 8 > srcSize then Break;

    boxSize   := ReadBE32(srcData, pos);
    boxType   := ReadBE32(srcData, pos + 4);
    dataStart := pos + 8;

    if boxSize = 0 then begin
      boxSize := UInt64(srcSize - pos);
    end else if boxSize = 1 then begin
      if pos + 16 > srcSize then Break;
      boxSize   := ReadBE64(srcData, pos + 8);
      dataStart := pos + 16;
    end;

    dataLen := Int64(boxSize) - (dataStart - pos);
    if dataLen < 0 then dataLen := 0;

    case boxType of
      BOX_JXLC: begin
        n := Integer(dataLen);
        SetLength(Result, n);
        if n > 0 then Move(srcData[dataStart], Result[0], n);
        Exit;
      end;
      BOX_JXLP: begin
        if dataLen < 4 then begin pos := pos + Int64(boxSize); Continue; end;
        seqNum  := ReadBE32(srcData, dataStart);
        tmpSize := dataLen - 4;
        // Append this chunk to partBuf
        SetLength(tmpBuf, partSize + tmpSize);
        if partSize > 0 then Move(partBuf[0], tmpBuf[0], Integer(partSize));
        if tmpSize > 0  then Move(srcData[dataStart + 4], tmpBuf[partSize], Integer(tmpSize));
        partBuf  := tmpBuf;
        SetLength(tmpBuf, 0);
        partSize := partSize + tmpSize;
        // Last chunk has high bit set in sequence number
        if (seqNum and $80000000) <> 0 then begin
          n := Integer(partSize);
          SetLength(Result, n);
          if n > 0 then Move(partBuf[0], Result[0], n);
          Exit;
        end;
      end;
      BOX_BROB: begin
        // Brotli-compressed metadata box: decompress with the bundled library
        // and keep it as a metadata box (does not contain the codestream).
        brobData := DecompressBrob(srcData, dataStart, dataLen, innerType);
        SetLength(GMetaBoxes, Length(GMetaBoxes) + 1);
        GMetaBoxes[High(GMetaBoxes)].InnerType := innerType;
        GMetaBoxes[High(GMetaBoxes)].Data      := brobData;
      end;
    end;

    pos := pos + Int64(boxSize);
  end;

  if partSize > 0 then begin
    n := Integer(partSize);
    SetLength(Result, n);
    if n > 0 then Move(partBuf[0], Result[0], n);
  end else
    raise EJxlError.Create('JXL container has no codestream box (jxlc/jxlp)');
end;

end.
