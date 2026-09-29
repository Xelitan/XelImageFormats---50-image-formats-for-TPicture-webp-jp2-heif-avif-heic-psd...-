# This is a pure Pascal version of Lepton written in RUST by Microsoft
# which was based on Dropbox's Lepton written in C++

Based on version 0.5.3.

It can loslessly compress JPEGs into 50-80% of their size

# CLI Usage - leptoncli.lpr

```
  leptoncli c  <in.jpg> <out.lep>  - compress JPEG -> LEPTON (+ round-trip verification)
  leptoncli cf <in.jpg> <out.lep>  - compress with no verification (faster)
  leptoncli d  <in.lep> <out.jpg>  - decompresss LEPTON -> JPEG
```

# Usage in code:
```
uses LeptonSimple;

// Streams: compress/decompress the entire Infile into Outfile.
function LeptonCompressStreams(Infile, Outfile: TStream): Integer;
function LeptonDecompressStreams(Infile, Outfile: TStream): Integer;

// Files: opens Infilename, creates Outfilename.
function LeptonCompressFile(const Infilename, Outfilename: String): Integer;
function LeptonDecompressFile(const Infilename, Outfilename: String): Integer;

// In-memory buffers (AnsiString = raw bytes).
function Lepton(JpegBody: AnsiString): AnsiString;
function UnLepton(LeptonBody: AnsiString): AnsiString;
```
