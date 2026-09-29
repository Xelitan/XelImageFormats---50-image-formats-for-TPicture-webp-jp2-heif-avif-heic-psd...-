// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//
//  JPEG marker codes as defined in `jpeg/jpeg_code.rs`.
// 
//  This unit defines constants corresponding to various JPEG marker codes
//  used throughout the JPEG and Lepton codebase.  They represent
//  segments such as Start of Frame, Define Huffman Table, Start of Image,
//  End of Image, Start of Scan, Define Quantization Table, and Define
//  Restart Interval.  These values originate from the JPEG specification
//  and are used to parse and construct JPEG headers and segments.

unit JpegCodes;

{$mode delphi}

interface

const
  // Start of Frame (size information), coding process: baseline DCT
  JPEG_SOF0 = Byte($C0);
  // Start of Frame (size information), coding process: extended sequential DCT
  JPEG_SOF1 = Byte($C1);
  // Start of Frame (size information), coding process: progressive DCT
  JPEG_SOF2 = Byte($C2);
  // Define Huffman Table
  JPEG_DHT  = Byte($C4);
  // Restart 0 segment
  JPEG_RST0 = Byte($D0);
  // Start of Image
  JPEG_SOI  = Byte($D8);
  // End of Image or End of File
  JPEG_EOI  = Byte($D9);
  // Start of Scan
  JPEG_SOS  = Byte($DA);
  // Define Quantization Table
  JPEG_DQT  = Byte($DB);
  // Define Restart Interval
  JPEG_DRI  = Byte($DD);

implementation

end.