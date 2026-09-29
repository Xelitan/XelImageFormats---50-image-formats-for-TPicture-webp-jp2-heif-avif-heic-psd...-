unit SimpleBrotli;

// Simple API for Brotli unpackers
// Author: www.xelitan.com
// License: MIT

{$mode Delphi}
{$H+}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}


//  Return conventions for Integer-returning functions:
//    0        = success (BROTLI_OK)
//    negative = error; BROTLI_ERR_* constants below, or a raw
//               TBrotliDecoderErrorCode cast to Integer.


interface

uses
  SysUtils, Classes,
  BrotliBase,   // size_t, uint8_t, BROTLI_BOOL...
  Decode1,      // TBrotliDecoderState, CreateInstance, DestroyInstance, GetErrorCode...
  Decode3,      // BrotliDecoderDecompressStream
  Decode2;      // arrays

const
  BROTLI_OK                          =  0;
  BROTLI_ERR_STREAM                  = -2;   // generic stream I/O error
  BROTLI_ERR_TRUNCATED_INPUT         = -3;   // decompressor needs more input but stream ended
  BROTLI_ERR_OUT_OF_MEMORY           = -4;

//  Compression  

//no compression in this version

//  Decompression   

function BrotliDecompressStreams(InStr, OutStr: TStream): Integer; overload;
function BrotliDecompressFile(const InFile, OutFile: String): Integer;

// Decompress Compressed string.  Returns empty string on error. 
function UnBrotli(const Compressed: AnsiString): AnsiString; overload;


implementation

//  Internal helpers  

const
  IN_CHUNK  = 65536;
  OUT_CHUNK = 65536;

// Core streaming decompressor.  Both InStr and OutStr must be non-nil. 
function DoUnBrotli(InStr, OutStr: TStream): Integer;
var
  s           : PBrotliDecoderState;
  in_buf      : PByte;
  out_buf     : PByte;
  avail_in    : size_t;
  avail_out   : size_t;
  total_out   : size_t;
  next_in     : PByte;
  next_out    : PByte;
  res         : TBrotliDecoderResult;
  n_read      : LongInt;
  n_written   : size_t;
  ppi         : PPByte;   // typed pointer-to-pointer helpers 
  ppo         : PPByte;
  psi         : PSizeT;
  pso         : PSizeT;
  pst         : PSizeT;
begin
  Result := BROTLI_OK;

  // Allocate decoder state 
  s := BrotliDecoderCreateInstance;
  if s = nil then begin Result := BROTLI_ERR_OUT_OF_MEMORY; Exit; end;

  // I/O buffers 
  GetMem(in_buf,  IN_CHUNK);
  GetMem(out_buf, OUT_CHUNK);
  avail_in  := 0;
  next_in   := in_buf;
  total_out := 0;

  try
    while True do begin

      //  Refill input when the previous chunk was fully consumed  
      if avail_in = 0 then begin
        n_read := InStr.Read(in_buf^, IN_CHUNK);
        if n_read < 0 then begin
          Result := BROTLI_ERR_STREAM;
          Break;
        end;
        avail_in := size_t(n_read);
        next_in  := in_buf;

        // Note: avail_in=0 here means EOF; we still call the decoder so it can
        //  flush its internal bit buffer and reach BROTLI_DECODER_RESULT_SUCCESS
        //  (or return an error if input was truncated). 
      end;

      //  Provide fresh output space  
      avail_out := OUT_CHUNK;
      next_out  := out_buf;

      //  Build typed-pointer arguments  
      psi := @avail_in;
      ppi := @next_in;
      pso := @avail_out;
      ppo := @next_out;
      pst := @total_out;

      res := BrotliDecoderDecompressStream(s, psi, ppi, pso, ppo, pst);

      //  Flush bytes the decoder produced  
      n_written := OUT_CHUNK - avail_out;
      if n_written > 0 then
        OutStr.WriteBuffer(out_buf^, n_written);

      //  Interpret result  
      case res of
        BROTLI_DECODER_RESULT_SUCCESS:
          Break;   // all done

        BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT:
          begin
            // avail_in is 0 — all bytes handed to the decoder.
            //  The next loop iteration will attempt to read more from InStr.
            //  If InStr is at EOF (n_read was 0 above), avail_in stays 0 and
            //  the decoder will eventually return RESULT_ERROR. 
          end;

        BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT:
          ; // output buffer was too small; loop immediately to flush

        BROTLI_DECODER_RESULT_ERROR:
          begin
            Result := Ord(BrotliDecoderGetErrorCode(s));
            if Result = 0 then Result := -1;  // should not happen, but guard 
            Break;
          end;
      else
        begin Result := -1; Break; end;
      end;

      // Prevent infinite loop on persistent EOF + NEEDS_MORE_INPUT
      if (res = BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT) and (avail_in = 0) then begin

        // We just tried to refill (avail_in was 0 at top) and the decoder still
        //  wants more.  If InStr was exhausted the Read above returned 0.
        //  The next iteration will call BrotliDecoderDecompressStream with
        //  avail_in=0 again.  The decoder will detect missing input and
        //  return RESULT_ERROR — so no busy-loop occurs. 
      end;

    end; 

  finally
    FreeMem(in_buf);
    FreeMem(out_buf);
    BrotliDecoderDestroyInstance(s);
  end;
end;

// =================================================================
// Public: Decompression  

function BrotliDecompressStreams(InStr, OutStr: TStream): Integer;
begin
  if (InStr = nil) or (OutStr = nil) then begin
    Result := BROTLI_ERR_STREAM;
    Exit;
  end;
  Result := DoUnBrotli(InStr, OutStr);
end;

function UnBrotli(const Compressed: AnsiString): AnsiString;
var
  InStr  : TBytesStream;
  OutStr : TBytesStream;
  src    : TBytes;
  res    : Integer;
begin
  Result := '';
  SetLength(src, Length(Compressed));
  if Length(Compressed) > 0 then
    Move(Compressed[1], src[0], Length(Compressed));

  InStr  := TBytesStream.Create(src);
  OutStr := TBytesStream.Create;
  try
    res := DoUnBrotli(InStr, OutStr);
    if res = BROTLI_OK then begin
      SetLength(Result, OutStr.Size);
      if OutStr.Size > 0 then
        Move(OutStr.Bytes[0], Result[1], OutStr.Size);
    end;
  finally
    InStr.Free;
    OutStr.Free;
  end;
end;

function BrotliDecompressFile(const InFile, OutFile: String): Integer;
var
  InStr  : TFileStream;
  OutStr : TFileStream;
begin
  try
    InStr := TFileStream.Create(InFile, fmOpenRead or fmShareDenyWrite);
  except
    Result := BROTLI_ERR_STREAM;
    Exit;
  end;
  try
    OutStr := TFileStream.Create(OutFile, fmCreate);
  except
    InStr.Free;
    Result := BROTLI_ERR_STREAM;
    Exit;
  end;
  try
    Result := DoUnBrotli(InStr, OutStr);
  finally
    OutStr.Free;
    InStr.Free;
  end;
end;

end.
