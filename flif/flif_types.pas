// FLIF - Free Lossless Image Format
//
// Basic types, compile-time configuration and message output.
// Corresponds to: src/config.h, src/flif_config.h, src/io.hpp, src/io.cpp
unit flif_types;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

const
  // --- options that change the bitstream (DANGER ZONE in config.h) ---
  NB_NOLEARN_ZOOMS = 12;
  FAST_BUT_WORSE_COMPRESSION = True;
  CONTEXT_TREE_MIN_COUNT = 1;
  CONTEXT_TREE_MAX_COUNT = 512;

  // --- default encoding parameters ---
  TREE_LEARN_REPEATS = 2;
  DEFAULT_MAX_PALETTE_SIZE = 512;
  CONTEXT_TREE_SPLIT_THRESHOLD = 5461 * 8 * 8;
  CONTEXT_TREE_COUNT_DIV = 30;
  CONTEXT_TREE_MIN_SUBTREE_SIZE = 50;

  // --- limits ---
  MAX_IMAGE_BUFFER_SIZE = Int64(1000) * Int64(1000000) * Int64(5);
  MAX_FRAMES = 50000;
  MAX_TRANSFORM = 13;
  MAX_PREDICTOR = 2;
  MAX_PALETTE_SIZE = 30000;

type
  // ColorVal is the type used for all colour computations.
  // The reference build defines SUPPORT_HDR, so this is 32 bit signed.
  ColorVal = Int32;
  PColorVal = ^ColorVal;

  TColorValArray = array of ColorVal;
  TIntegerArray = array of Integer;

  // maniac: Properties / Ranges
  Properties = array of ColorVal;

  TRangePair = record
    First: ColorVal;
    Second: ColorVal;
  end;

  Ranges = array of TRangePair;

  TFlifEncoding = (feUndefined = 0, feNonInterlaced = 1, feInterlaced = 2);

  TPredictorArray = array[0..4] of Integer;

  TFlifOptions = record
    // encoder
    learn_repeats: Integer;
    acb: Integer;
    frame_delay: array of Integer;
    palette_size: Integer;
    lookback: Integer;
    divisor: Integer;
    min_size: Integer;
    split_threshold: Integer;
    ycocg: Integer;
    subtract_green: Integer;
    plc: Integer;
    frs: Integer;
    alpha_zero_special: Integer;
    loss: Integer;
    adaptive: Integer;
    predictor: TPredictorArray;
    chroma_subsampling: Integer;
    // shared
    method: TFlifEncoding;
    invisible_predictor: Integer;
    alpha: Cardinal;
    cutoff: Integer;
    crc_check: Integer;
    metadata: Integer;
    color_profile: Integer;
    quality: Integer;
    scale: Integer;
    resize_width: Integer;
    resize_height: Integer;
    fit: Integer;
    overwrite: Integer;
    just_add_loss: Integer;
    show_breakpoints: Integer;
    no_full_decode: Integer;
    keep_palette: Integer;
  end;

  TMetadataOptions = record
    icc, exif, xmp: Boolean;
  end;

  TProgress = record
    pixels_todo: Int64;
    pixels_done: Int64;
    progressive_qual_target: Integer;
    progressive_qual_shown: Integer;
  end;

const
  // The order in which the planes are encoded:  FRA (lookback), A, Y, Co, Cg
  PLANE_ORDERING: array[0..4] of Integer = (4, 3, 0, 1, 2);

  // MANIAC property counts
  NB_PROPERTIES_scanlines: array[0..4] of Integer = (7, 8, 9, 7, 7);
  NB_PROPERTIES_scanlinesA: array[0..4] of Integer = (8, 9, 10, 7, 7);
  NB_PROPERTIES: array[0..4] of Integer = (8, 10, 9, 8, 8);
  NB_PROPERTIESA: array[0..4] of Integer = (9, 11, 10, 8, 8);

  // Names of the transformations, index == bitstream identifier
  TransformNames: array[0..MAX_TRANSFORM] of string = (
    'Channel_Compact', 'YCoCg', '?? YCbCr ??', 'PermutePlanes', 'Bounds',
    'Palette_Alpha', 'Palette', 'Color_Buckets',
    '?? DCT ??', '?? DWT ??',
    'Duplicate_Frame', 'Frame_Shape', 'Frame_Lookback',
    '?? Other ??');

function DefaultOptions: TFlifOptions;
function DefaultMetadataOptions: TMetadataOptions;
procedure InitProgress(out P: TProgress);
function ProgressQuality(const P: TProgress): Integer; inline;

// verbosity-controlled output, mirrors io.cpp
procedure e_printf(const S: string);
procedure v_printf(V: Integer; const S: string);
procedure v_printf_tty(V: Integer; const S: string);
procedure increase_verbosity(HowMuch: Integer = 1);
function get_verbosity: Integer;
procedure redirect_stdout_to_stderr;

// helpers
function ilog2(L: Cardinal): Integer; inline;
// arithmetic shift right by one == floor(x/2); Pascal's SHR is logical, but the
// reference relies on C++ >> being arithmetic on signed values
function Sar1(X: ColorVal): ColorVal; inline;
function median3(A, B, C: ColorVal): ColorVal; inline;
function MinI(A, B: Integer): Integer; inline;
function MaxI(A, B: Integer): Integer; inline;
function MakeRange(A, B: ColorVal): TRangePair; inline;

implementation

var
  Verbosity: Integer = 1;
  StdoutIsStderr: Boolean = False;

function DefaultOptions: TFlifOptions;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.learn_repeats := -1;
  Result.acb := -1;
  SetLength(Result.frame_delay, 1);
  Result.frame_delay[0] := 100;
  Result.palette_size := -1;
  Result.lookback := 1;
  Result.divisor := CONTEXT_TREE_COUNT_DIV;
  Result.min_size := CONTEXT_TREE_MIN_SUBTREE_SIZE;
  Result.split_threshold := CONTEXT_TREE_SPLIT_THRESHOLD;
  Result.ycocg := 1;
  Result.subtract_green := 1;
  Result.plc := 1;
  Result.frs := 1;
  Result.alpha_zero_special := 1;
  Result.loss := 0;
  Result.adaptive := 0;
  Result.predictor[0] := -2;
  Result.predictor[1] := -2;
  Result.predictor[2] := -2;
  Result.predictor[3] := -2;
  Result.predictor[4] := -2;
  Result.chroma_subsampling := 0;
  Result.method := feUndefined;
  Result.invisible_predictor := 2;
  Result.alpha := 19;
  Result.cutoff := 2;
  Result.crc_check := -1;
  Result.metadata := 1;
  Result.color_profile := 1;
  Result.quality := 100;
  Result.scale := 1;
  Result.resize_width := 0;
  Result.resize_height := 0;
  Result.fit := 0;
  Result.overwrite := 0;
  Result.just_add_loss := 0;
  Result.show_breakpoints := 0;
  Result.no_full_decode := 0;
  Result.keep_palette := 0;
end;

function DefaultMetadataOptions: TMetadataOptions;
begin
  Result.icc := True;
  Result.exif := True;
  Result.xmp := True;
end;

procedure InitProgress(out P: TProgress);
begin
  P.pixels_todo := 0;
  P.pixels_done := 0;
  P.progressive_qual_target := 0;
  P.progressive_qual_shown := -1;
end;

function ProgressQuality(const P: TProgress): Integer;
begin
  if P.pixels_todo = 0 then
    Result := 0
  else
    Result := Integer(10000 * P.pixels_done div P.pixels_todo);
end;

procedure e_printf(const S: string);
begin
  Write(StdErr, S);
  Flush(StdErr);
end;

procedure v_printf(V: Integer; const S: string);
begin
  if Verbosity < V then Exit;
  if StdoutIsStderr then
  begin
    Write(StdErr, S);
    Flush(StdErr);
  end
  else
  begin
    Write(Output, S);
    Flush(Output);
  end;
end;

procedure v_printf_tty(V: Integer; const S: string);
begin
  // the reference only writes this when stdout is a tty; we always write it
  // to the same stream v_printf uses -- purely cosmetic progress output
  v_printf(V, S);
end;

procedure increase_verbosity(HowMuch: Integer);
begin
  Inc(Verbosity, HowMuch);
end;

function get_verbosity: Integer;
begin
  Result := Verbosity;
end;

procedure redirect_stdout_to_stderr;
begin
  StdoutIsStderr := True;
end;

function ilog2(L: Cardinal): Integer;
begin
  if L = 0 then
    Result := 0
  else
    Result := BsrDWord(L);
end;

function Sar1(X: ColorVal): ColorVal;
begin
  Result := SarLongint(X, 1);
end;

function median3(A, B, C: ColorVal): ColorVal;
begin
  if A < B then
  begin
    if B < C then
      Result := B
    else if A < C then
      Result := C
    else
      Result := A;
  end
  else
  begin
    if A < C then
      Result := A
    else if B < C then
      Result := C
    else
      Result := B;
  end;
end;

function MinI(A, B: Integer): Integer;
begin
  if A < B then Result := A else Result := B;
end;

function MaxI(A, B: Integer): Integer;
begin
  if A > B then Result := A else Result := B;
end;

function MakeRange(A, B: ColorVal): TRangePair;
begin
  Result.First := A;
  Result.Second := B;
end;

end.
