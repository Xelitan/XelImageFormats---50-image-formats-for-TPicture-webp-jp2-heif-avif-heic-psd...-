unit LeptonConsts;

{$mode delphi}

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//

interface

type
  // JPEG decode status used in some decode flows. Kept for future porting.
  TJpegDecodeStatus = (
    jdsDecodeInProgress,
    jdsRestartIntervalExpired,
    jdsScanCompleted
  );

  // JPEG type as defined by the header parsing.
  TJpegType = (
    jtUnknown,
    jtSequential,
    jtProgressive
  );

const
  // Number of block types per colour channel (Y, Cb, Cr).
  COLOR_CHANNEL_NUM_BLOCK_TYPES = 3;

  // Mapping from raster order to zig‑zag order for an 8×8 block.
  RasterToZigZag: array[0..63] of Byte = (
    0, 1, 5, 6, 14, 15, 27, 28, 2, 4, 7, 13, 16, 26, 29, 42,
    3, 8, 12, 17, 25, 30, 41, 43, 9, 11, 18, 24, 31, 40, 44, 53,
    10, 19, 23, 32, 39, 45, 52, 54, 20, 22, 33, 38, 46, 51, 55, 60,
    21, 34, 37, 47, 50, 56, 59, 61, 35, 36, 48, 49, 57, 58, 62, 63
  );

  // Mapping from zig‑zag order to a transposed 8×8 block.
  ZigZagToTransposed: array[0..63] of Byte = (
    0, 8, 1, 2, 9, 16, 24, 17, 10, 3, 4, 11, 18, 25, 32, 40,
    33, 26, 19, 12, 5, 6, 13, 20, 27, 34, 41, 48, 56, 49, 42, 35,
    28, 21, 14, 7, 15, 22, 29, 36, 43, 50, 57, 58, 51, 44, 37, 30,
    23, 31, 38, 45, 52, 59, 60, 53, 46, 39, 47, 54, 61, 62, 55, 63
  );

  // Unzigzag positions for the first 49 AC coefficients in a transposed block.
  Unzigzag49Tr: array[0..48] of Byte = (
    9, 17, 10, 11, 18, 25, 33, 26, 19, 12, 13, 20, 27, 34, 41,
    49, 42, 35, 28, 21, 14, 15, 22, 29, 36, 43, 50, 57, 58, 51,
    44, 37, 30, 23, 31, 38, 45, 52, 59, 60, 53, 46, 39, 47, 54,
    61, 62, 55, 63
  );

  // Precalculated cosine values scaled by 8192 for IDCT. DC coefficient is zeroed.
  IcosBased8192Scaled: array[0..7] of Integer = (
    0, 11363, 10703, 9633, 8192, 6436, 4433, 2260
  );

  // Same as above but alternating sign.
  IcosBased8192ScaledPm: array[0..7] of Integer = (
    8192, -11363, 10703, -9633, 8192, -6436, 4433, -2260
  );

  // Maximum frequencies used by the arithmetic model.
  FreqMax: array[0..13] of Word = (
    931, 985, 968, 1020, 968, 1020, 1020, 932, 985, 967, 1020, 969, 1020, 1020
  );

  // Predictor mapping based on the number of non‑zero AC coefficients.
  NonZeroToBin: array[0..25] of Byte = (
    0, 1, 2, 3, 4, 4, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7,
    7, 7, 7, 7, 7, 8, 8, 8, 8, 8
  );

  // Predictor mapping based on the number of remaining non‑zero AC coefficients in a 7×7 block.
  NonZeroToBin7x7: array[0..49] of Byte = (
    0, 0, 1, 2, 3, 3, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6,
    6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8
  );

  // Residual noise floor used in the model.
  ResidualNoiseFloor = 7;

  // Lepton codec version. Compatible with the C++ reference.
  LeptonVersion: Byte = 1;

  // Small file threshold per encoding thread. Files below this size may use fewer partitions.
  SmallFileBytesPerEncodingThread: Cardinal = 125000;

  // Maximum number of threads supported by the Lepton file format.
  MaxThreadsSupportedByLeptonFormat: Cardinal = 16;

  // JPEG code constants used in markers.
  JpegCodeEOI = Byte($D9);
  JpegCodeSOI = Byte($D8);

  // End of Image (EOI) marker.
  EOI: array[0..1] of Byte = ($FF, JpegCodeEOI);
  // Start of Image (SOI) marker.
  SOI: array[0..1] of Byte = ($FF, JpegCodeSOI);

  // Lepton file header prefix (tau lepton symbol in UTF‑8).
  LeptonFileHeader: array[0..1] of Byte = ($CF, $84);

  // JPEG type markers used in the Lepton header.
  LeptonHeaderBaselineJpegType: Byte = Ord('Z');
  LeptonHeaderProgressiveJpegType: Byte = Ord('X');

  // Markers used inside the compressed Lepton header. All are ASCII.
  LeptonHeaderMarker: array[0..2] of Byte = (Ord('H'), Ord('D'), Ord('R'));
  LeptonHeaderPadMarker: array[0..2] of Byte = (Ord('P'), Ord('0'), Ord('D'));
  LeptonHeaderJpgRestartsMarker: array[0..2] of Byte = (Ord('C'), Ord('R'), Ord('S'));
  LeptonHeaderJpgRestartErrorsMarker: array[0..2] of Byte = (Ord('F'), Ord('R'), Ord('S'));
  LeptonHeaderLumaSplitMarker: array[0..1] of Byte = (Ord('H'), Ord('H'));
  LeptonHeaderEarlyEofMarker: array[0..2] of Byte = (Ord('E'), Ord('E'), Ord('E'));
  LeptonHeaderPrefixGarbageMarker: array[0..2] of Byte = (Ord('P'), Ord('G'), Ord('R'));
  LeptonHeaderGarbageMarker: array[0..2] of Byte = (Ord('G'), Ord('R'), Ord('B'));
  LeptonHeaderCompletionMarker: array[0..2] of Byte = (Ord('C'), Ord('M'), Ord('P'));

  // ------------------------------------------------------------------------
  //  UPPER_SNAKE_CASE aliases matching the Rust constant names. Some existing
  //  units reference these forms, and the ported core uses them as well. The
  //  array literals are duplicated because Pascal cannot alias an array
  //  constant with `=`.

  RASTER_TO_ZIGZAG: array[0..63] of Byte = (
    0, 1, 5, 6, 14, 15, 27, 28, 2, 4, 7, 13, 16, 26, 29, 42,
    3, 8, 12, 17, 25, 30, 41, 43, 9, 11, 18, 24, 31, 40, 44, 53,
    10, 19, 23, 32, 39, 45, 52, 54, 20, 22, 33, 38, 46, 51, 55, 60,
    21, 34, 37, 47, 50, 56, 59, 61, 35, 36, 48, 49, 57, 58, 62, 63
  );

  ZIGZAG_TO_TRANSPOSED: array[0..63] of Byte = (
    0, 8, 1, 2, 9, 16, 24, 17, 10, 3, 4, 11, 18, 25, 32, 40,
    33, 26, 19, 12, 5, 6, 13, 20, 27, 34, 41, 48, 56, 49, 42, 35,
    28, 21, 14, 7, 15, 22, 29, 36, 43, 50, 57, 58, 51, 44, 37, 30,
    23, 31, 38, 45, 52, 59, 60, 53, 46, 39, 47, 54, 61, 62, 55, 63
  );

  UNZIGZAG_49_TR: array[0..48] of Byte = (
    9, 17, 10, 11, 18, 25, 33, 26, 19, 12, 13, 20, 27, 34, 41,
    49, 42, 35, 28, 21, 14, 15, 22, 29, 36, 43, 50, 57, 58, 51,
    44, 37, 30, 23, 31, 38, 45, 52, 59, 60, 53, 46, 39, 47, 54,
    61, 62, 55, 63
  );

  ICOS_BASED_8192_SCALED: array[0..7] of Integer = (
    0, 11363, 10703, 9633, 8192, 6436, 4433, 2260
  );

  ICOS_BASED_8192_SCALED_PM: array[0..7] of Integer = (
    8192, -11363, 10703, -9633, 8192, -6436, 4433, -2260
  );

  FREQ_MAX: array[0..13] of Word = (
    931, 985, 968, 1020, 968, 1020, 1020, 932, 985, 967, 1020, 969, 1020, 1020
  );

  NON_ZERO_TO_BIN: array[0..25] of Byte = (
    0, 1, 2, 3, 4, 4, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7,
    7, 7, 7, 7, 7, 8, 8, 8, 8, 8
  );

  NON_ZERO_TO_BIN_7X7: array[0..49] of Byte = (
    0, 0, 1, 2, 3, 3, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6,
    6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8
  );

  RESIDUAL_NOISE_FLOOR = 7;

implementation

end.