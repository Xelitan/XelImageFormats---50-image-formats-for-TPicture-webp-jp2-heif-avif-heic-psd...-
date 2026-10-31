unit Avif.Sequence;

// AVIF image sequence container (ISO/IEC 23000-22 'avis' brand on top of
// ISOBMFF / HEIF): reading the 'moov' sample tables of the colour track and of
// an optional alpha auxiliary track, and writing a complete image sequence
// file (with a primary still item for players that only read the first frame).
//
// Reading collects, per track: the AV1 codec configuration (av1C config OBUs),
// sample byte ranges, per-sample durations, sync samples and the edit list
// repeat flag (loop). Writing takes already-encoded AV1 temporal units.

{$mode delphi}{$H+}
{$RANGECHECKS OFF}{$OVERFLOWCHECKS OFF}

interface

uses SysUtils, Classes;

type
  EAvifSequence = class(Exception);

  TAvifTrack = record
    TrackId: LongWord;
    Handler: string;                 // 'pict' (colour) or 'auxv' (alpha) ...
    Width, Height: Integer;          // from tkhd (pixels)
    Timescale: LongWord;
    MediaDuration: UInt64;
    TrackDuration: UInt64;           // tkhd duration (movie timescale)
    MovieTimescale: LongWord;
    ConfigObus: TBytes;              // av1C configOBUs (usually the sequence header)
    HasAv1: Boolean;
    SampleOffset: array of Int64;
    SampleSize: array of LongWord;
    SampleDuration: array of LongWord;   // in Timescale units
    IsSync: array of Boolean;
    AuxlFor: LongWord;               // tref 'auxl' target track id (0 = none)
    IsAlpha: Boolean;
    Repeating: Boolean;              // elst flags & 1
    SegmentDuration: UInt64;         // first elst segment duration (movie timescale)
  end;

  TAvifSequenceReader = class
  private
    FData: TBytes;
    FTracks: array of TAvifTrack;
    FMovieTimescale: LongWord;
    FColor, FAlpha: Integer;
    procedure ParseMoov(S, E: NativeInt);
    procedure ParseTrak(S, E: NativeInt);
    function GetTrack(I: Integer): TAvifTrack;
  public
    // Returns False when the data has no usable AV1 image sequence track.
    function Load(const Data: TBytes): Boolean;
    function SampleData(Track, Index: Integer): TBytes;
    function TrackCount: Integer;
    // -1 when absent.
    property ColorTrack: Integer read FColor;
    property AlphaTrack: Integer read FAlpha;
    property Tracks[I: Integer]: TAvifTrack read GetTrack;
    // Loop count in TCustomAnimation convention: 0 = forever, n = play n times.
    function LoopCount: Integer;
  end;

  TAvifSeqWriterFrame = record
    Data: TBytes;          // one AV1 temporal unit
    Alpha: TBytes;         // alpha plane temporal unit (empty = no alpha)
    DurationMs: Integer;
    Sync: Boolean;
  end;

  TAvifSequenceWriter = class
  public
    Width, Height: Integer;
    BitDepth: Integer;               // 8/10/12
    ChromaSubX, ChromaSubY: Integer; // 1,1 = 4:2:0; 0,0 = 4:4:4; 1,0 = 4:2:2
    Monochrome: Boolean;
    SeqProfile, SeqLevelIdx0, SeqTier: Integer;
    ColorConfigObus: TBytes;         // sequence header OBU for av1C
    AlphaConfigObus: TBytes;
    AlphaProfile, AlphaLevel: Integer;
    FullRange: Boolean;
    MatrixCoefficients, ColourPrimaries, TransferCharacteristics: Integer;
    LoopCount: Integer;              // 0 = forever
    Frames: array of TAvifSeqWriterFrame;
    procedure AddFrame(const Data, Alpha: TBytes; DurationMs: Integer; Sync: Boolean);
    function Build: TBytes;
  end;

implementation

// ---------------------------------------------------------------- reading

function BE16(P: PByte): LongWord; inline;
begin Result := (LongWord(P[0]) shl 8) or P[1]; end;
function BE32(P: PByte): LongWord; inline;
begin Result := (LongWord(P[0]) shl 24) or (LongWord(P[1]) shl 16) or (LongWord(P[2]) shl 8) or P[3]; end;
function BE64(P: PByte): UInt64; inline;
begin Result := (UInt64(BE32(P)) shl 32) or BE32(P + 4); end;

function NextBox(const D: TBytes; var Pos: NativeInt; Limit: NativeInt; out Typ: string;
  out CS, CE: NativeInt): Boolean;
var sz: UInt64; hl: NativeInt; p: PByte;
begin
  Result := False;
  if Limit - Pos < 8 then Exit;
  p := @D[Pos];
  sz := BE32(p);
  SetString(Typ, PAnsiChar(p + 4), 4);
  hl := 8;
  if sz = 1 then
  begin
    if Limit - Pos < 16 then Exit;
    sz := BE64(p + 8);
    hl := 16;
  end
  else if sz = 0 then sz := Limit - Pos;
  if (sz < UInt64(hl)) or (UInt64(Pos) + sz > UInt64(Limit)) then sz := Limit - Pos;
  CS := Pos + hl;
  CE := Pos + NativeInt(sz);
  Pos := CE;
  Result := CE > CS - hl;
end;

function TAvifSequenceReader.GetTrack(I: Integer): TAvifTrack;
begin Result := FTracks[I]; end;

function TAvifSequenceReader.TrackCount: Integer;
begin Result := Length(FTracks); end;

procedure TAvifSequenceReader.ParseTrak(S, E: NativeInt);
var
  T: TAvifTrack;
  stsz, stco, co64, stsc, stts, stss: NativeInt;
  stszE, stcoE, stscE, sttsE, stssE: NativeInt;

  procedure Walk(S2, E2: NativeInt; Depth: Integer);
  var pos, cs, ce, q, q2, cs2, ce2, cs3, ce3: NativeInt; typ: string; ver: Byte; n, i: LongWord; p: PByte;
  begin
    pos := S2;
    while NextBox(FData, pos, E2, typ, cs, ce) do
    begin
      if (typ = 'mdia') or (typ = 'minf') or (typ = 'stbl') or (typ = 'edts') or (typ = 'dinf') then
        Walk(cs, ce, Depth + 1)
      else if typ = 'tkhd' then
      begin
        p := @FData[cs];
        ver := p[0];
        if ver = 1 then
        begin
          T.TrackId := BE32(p + 4 + 16);
          T.TrackDuration := BE64(p + 4 + 24);
          T.Width := BE32(p + 4 + 32 + 52) shr 16;
          T.Height := BE32(p + 4 + 32 + 56) shr 16;
        end
        else
        begin
          T.TrackId := BE32(p + 4 + 8);
          T.TrackDuration := BE32(p + 4 + 16);
          if T.TrackDuration = $FFFFFFFF then T.TrackDuration := High(UInt64);
          T.Width := BE32(p + 4 + 20 + 52) shr 16;
          T.Height := BE32(p + 4 + 20 + 56) shr 16;
        end;
      end
      else if typ = 'mdhd' then
      begin
        p := @FData[cs];
        if p[0] = 1 then
        begin
          T.Timescale := BE32(p + 4 + 16);
          T.MediaDuration := BE64(p + 4 + 20);
        end
        else
        begin
          T.Timescale := BE32(p + 4 + 8);
          T.MediaDuration := BE32(p + 4 + 12);
        end;
      end
      else if typ = 'hdlr' then
        SetString(T.Handler, PAnsiChar(@FData[cs + 8]), 4)
      else if typ = 'elst' then
      begin
        p := @FData[cs];
        T.Repeating := (BE32(p) and 1) <> 0;
        n := BE32(p + 4);
        if n > 0 then
        begin
          if p[0] = 1 then T.SegmentDuration := BE64(p + 8)
          else T.SegmentDuration := BE32(p + 8);
        end;
      end
      else if typ = 'tref' then
      begin
        // child reference type boxes
        i := 0;
        q := cs;
        while NextBox(FData, q, ce, typ, cs2, ce2) do
        begin
          if (typ = 'auxl') and (ce2 - cs2 >= 4) then T.AuxlFor := BE32(@FData[cs2]);
          Inc(i);
          if i > 16 then Break;
        end;
      end
      else if typ = 'stsd' then
      begin
        // stsd: FullBox + entry_count, then sample entries
        q := cs + 8;
        while NextBox(FData, q, ce, typ, cs2, ce2) do
          if typ = 'av01' then
          begin
            T.HasAv1 := True;
            // VisualSampleEntry: 78 bytes before child boxes
            q2 := cs2 + 78;
            while NextBox(FData, q2, ce2, typ, cs3, ce3) do
              if (typ = 'av1C') and (ce3 - cs3 >= 4) then
                T.ConfigObus := Copy(FData, cs3 + 4, ce3 - cs3 - 4)
              else if typ = 'auxi' then
                T.IsAlpha := True;
            Break;
          end;
      end
      else if typ = 'stsz' then begin stsz := cs; stszE := ce; end
      else if typ = 'stz2' then raise EAvifSequence.Create('AVIF: compact sample sizes (stz2) are not supported')
      else if typ = 'stco' then begin stco := cs; stcoE := ce; end
      else if typ = 'co64' then begin co64 := cs; stcoE := ce; end
      else if typ = 'stsc' then begin stsc := cs; stscE := ce; end
      else if typ = 'stts' then begin stts := cs; sttsE := ce; end
      else if typ = 'stss' then begin stss := cs; stssE := ce; end;
    end;
  end;

var
  i, j, k, nSamples, nChunks, nStsc, sIdx, chunk, firstChunk, nextFirst, perChunk: Integer;
  defSize, cnt, delta: LongWord;
  chunkOffs: array of Int64;
  off: Int64;
begin
  FillChar(T, SizeOf(T), 0);
  T.ConfigObus := nil;
  stsz := -1; stco := -1; co64 := -1; stsc := -1; stts := -1; stss := -1;
  stszE := 0; stcoE := 0; stscE := 0; sttsE := 0; stssE := 0;
  Walk(S, E, 0);
  if (not T.HasAv1) or (stsz < 0) or ((stco < 0) and (co64 < 0)) or (stsc < 0) then Exit;

  // sample sizes
  defSize := BE32(@FData[stsz + 4]);
  nSamples := BE32(@FData[stsz + 8]);
  SetLength(T.SampleSize, nSamples);
  for i := 0 to nSamples - 1 do
    if defSize <> 0 then T.SampleSize[i] := defSize
    else T.SampleSize[i] := BE32(@FData[stsz + 12 + i * 4]);

  // chunk offsets
  if stco >= 0 then
  begin
    nChunks := BE32(@FData[stco + 4]);
    SetLength(chunkOffs, nChunks);
    for i := 0 to nChunks - 1 do chunkOffs[i] := BE32(@FData[stco + 8 + i * 4]);
  end
  else
  begin
    nChunks := BE32(@FData[co64 + 4]);
    SetLength(chunkOffs, nChunks);
    for i := 0 to nChunks - 1 do chunkOffs[i] := BE64(@FData[co64 + 8 + i * 8]);
  end;

  // sample-to-chunk
  SetLength(T.SampleOffset, nSamples);
  nStsc := BE32(@FData[stsc + 4]);
  sIdx := 0;
  for i := 0 to nStsc - 1 do
  begin
    firstChunk := BE32(@FData[stsc + 8 + i * 12]) - 1;
    perChunk := BE32(@FData[stsc + 8 + i * 12 + 4]);
    if i + 1 < nStsc then nextFirst := BE32(@FData[stsc + 8 + (i + 1) * 12]) - 1
    else nextFirst := nChunks;
    for chunk := firstChunk to nextFirst - 1 do
    begin
      if chunk >= nChunks then Break;
      off := chunkOffs[chunk];
      for k := 0 to perChunk - 1 do
      begin
        if sIdx >= nSamples then Break;
        T.SampleOffset[sIdx] := off;
        Inc(off, T.SampleSize[sIdx]);
        Inc(sIdx);
      end;
    end;
  end;
  if sIdx < nSamples then SetLength(T.SampleOffset, sIdx);
  nSamples := Length(T.SampleOffset);
  SetLength(T.SampleSize, nSamples);

  // durations
  SetLength(T.SampleDuration, nSamples);
  if stts >= 0 then
  begin
    j := 0;
    for i := 0 to Integer(BE32(@FData[stts + 4])) - 1 do
    begin
      cnt := BE32(@FData[stts + 8 + i * 8]);
      delta := BE32(@FData[stts + 8 + i * 8 + 4]);
      while (cnt > 0) and (j < nSamples) do
      begin
        T.SampleDuration[j] := delta;
        Inc(j); Dec(cnt);
      end;
    end;
  end;

  // sync samples (absent = all sync)
  SetLength(T.IsSync, nSamples);
  for i := 0 to nSamples - 1 do T.IsSync[i] := stss < 0;
  if stss >= 0 then
    for i := 0 to Integer(BE32(@FData[stss + 4])) - 1 do
    begin
      j := Integer(BE32(@FData[stss + 8 + i * 4])) - 1;
      if (j >= 0) and (j < nSamples) then T.IsSync[j] := True;
    end;

  for i := 0 to nSamples - 1 do
    if (T.SampleOffset[i] < 0) or (T.SampleOffset[i] + T.SampleSize[i] > Length(FData)) then
      raise EAvifSequence.Create('AVIF: sample outside of file');

  T.MovieTimescale := FMovieTimescale;
  if (T.Handler = 'auxv') or (T.AuxlFor <> 0) then T.IsAlpha := True;
  SetLength(FTracks, Length(FTracks) + 1);
  FTracks[High(FTracks)] := T;
  if sttsE + stssE + stszE + stcoE + stscE = 0 then ;
end;

procedure TAvifSequenceReader.ParseMoov(S, E: NativeInt);
var pos, cs, ce: NativeInt; typ: string; p: PByte;
begin
  pos := S;
  while NextBox(FData, pos, E, typ, cs, ce) do
    if typ = 'mvhd' then
    begin
      p := @FData[cs];
      if p[0] = 1 then FMovieTimescale := BE32(p + 4 + 16)
      else FMovieTimescale := BE32(p + 4 + 8);
    end
    else if typ = 'trak' then
      ParseTrak(cs, ce);
end;

function TAvifSequenceReader.Load(const Data: TBytes): Boolean;
var pos, cs, ce: NativeInt; typ: string; i, j: Integer;
begin
  FData := Data;
  SetLength(FTracks, 0);
  FColor := -1; FAlpha := -1;
  FMovieTimescale := 1000;
  pos := 0;
  while NextBox(FData, pos, Length(FData), typ, cs, ce) do
    if typ = 'moov' then ParseMoov(cs, ce);
  for i := 0 to High(FTracks) do
    if (not FTracks[i].IsAlpha) and (FColor < 0) and (Length(FTracks[i].SampleSize) > 0) then
      FColor := i;
  if FColor >= 0 then
    for j := 0 to High(FTracks) do
      if FTracks[j].IsAlpha and ((FTracks[j].AuxlFor = 0) or (FTracks[j].AuxlFor = FTracks[FColor].TrackId)) and
         (Length(FTracks[j].SampleSize) = Length(FTracks[FColor].SampleSize)) then
      begin
        FAlpha := j;
        Break;
      end;
  Result := FColor >= 0;
end;

function TAvifSequenceReader.SampleData(Track, Index: Integer): TBytes;
begin
  with FTracks[Track] do
    Result := Copy(FData, SampleOffset[Index], SampleSize[Index]);
end;

function TAvifSequenceReader.LoopCount: Integer;
var T: TAvifTrack; reps: UInt64;
begin
  if FColor < 0 then Exit(1);
  T := FTracks[FColor];
  if not T.Repeating then Exit(1);
  if (T.TrackDuration = High(UInt64)) or (T.SegmentDuration = 0) then Exit(0);
  reps := T.TrackDuration div T.SegmentDuration;
  if (T.TrackDuration mod T.SegmentDuration) <> 0 then Inc(reps);
  if reps > 1000000 then Exit(0);
  Result := Integer(reps);
  if Result < 1 then Result := 1;
end;

// ---------------------------------------------------------------- writing

type
  TBoxWriter = class
  private
    FBuf: TBytes;
    FLen: Integer;
    FStack: array of Integer;
    procedure Ensure(N: Integer);
  public
    procedure U8(V: Byte);
    procedure U16(V: LongWord);
    procedure U32(V: LongWord);
    procedure U64(V: UInt64);
    procedure Bytes(const B: TBytes); overload;
    procedure Bytes(P: PByte; N: Integer); overload;
    procedure Str4(const S: AnsiString);
    procedure Zeros(N: Integer);
    procedure StartBox(const Typ: AnsiString);
    procedure StartFull(const Typ: AnsiString; Ver: Byte; Flags: LongWord);
    procedure EndBox;
    procedure PatchU32(At: Integer; V: LongWord);
    function Data: TBytes;
    property Len: Integer read FLen;
  end;

procedure TBoxWriter.Ensure(N: Integer);
begin
  if FLen + N > Length(FBuf) then SetLength(FBuf, (FLen + N) * 2 + 256);
end;
procedure TBoxWriter.U8(V: Byte); begin Ensure(1); FBuf[FLen] := V; Inc(FLen); end;
procedure TBoxWriter.U16(V: LongWord); begin U8(V shr 8); U8(V); end;
procedure TBoxWriter.U32(V: LongWord); begin U8(V shr 24); U8(V shr 16); U8(V shr 8); U8(V); end;
procedure TBoxWriter.U64(V: UInt64); begin U32(V shr 32); U32(LongWord(V)); end;
procedure TBoxWriter.Bytes(const B: TBytes); begin if Length(B) > 0 then Bytes(@B[0], Length(B)); end;
procedure TBoxWriter.Bytes(P: PByte; N: Integer);
begin if N <= 0 then Exit; Ensure(N); Move(P^, FBuf[FLen], N); Inc(FLen, N); end;
procedure TBoxWriter.Str4(const S: AnsiString); begin Bytes(PByte(PAnsiChar(S)), 4); end;
procedure TBoxWriter.Zeros(N: Integer); var i: Integer; begin for i := 1 to N do U8(0); end;
procedure TBoxWriter.StartBox(const Typ: AnsiString);
begin
  SetLength(FStack, Length(FStack) + 1);
  FStack[High(FStack)] := FLen;
  U32(0); Str4(Typ);
end;
procedure TBoxWriter.StartFull(const Typ: AnsiString; Ver: Byte; Flags: LongWord);
begin StartBox(Typ); U8(Ver); U8(Flags shr 16); U8(Flags shr 8); U8(Flags); end;
procedure TBoxWriter.EndBox;
var st: Integer;
begin
  st := FStack[High(FStack)];
  SetLength(FStack, Length(FStack) - 1);
  PatchU32(st, FLen - st);
end;
procedure TBoxWriter.PatchU32(At: Integer; V: LongWord);
begin
  FBuf[At] := V shr 24; FBuf[At + 1] := V shr 16; FBuf[At + 2] := V shr 8; FBuf[At + 3] := V;
end;
function TBoxWriter.Data: TBytes; begin Result := Copy(FBuf, 0, FLen); end;

procedure TAvifSequenceWriter.AddFrame(const Data, Alpha: TBytes; DurationMs: Integer; Sync: Boolean);
var n: Integer;
begin
  n := Length(Frames);
  SetLength(Frames, n + 1);
  Frames[n].Data := Data;
  Frames[n].Alpha := Alpha;
  Frames[n].DurationMs := DurationMs;
  Frames[n].Sync := Sync;
end;

function TAvifSequenceWriter.Build: TBytes;
const
  TIMESCALE = 1000;
  AlphaUrn: AnsiString = 'urn:mpeg:mpegB:cicp:systems:auxiliary:alpha';
var
  W: TBoxWriter;
  hasAlpha: Boolean;
  i, nTracks, mdatStart, mdatPayload: Integer;
  total, segDur, trackDur: UInt64;
  colorOffsAt, alphaOffsAt, itemColorOffAt, itemAlphaOffAt: Integer;
  colorPos, alphaPos: array of Int64;

  procedure WriteAv1C(Profile, Level, Tier: Integer; Mono: Boolean; const Cfg: TBytes);
  var hb: Integer;
  begin
    W.StartBox('av1C');
    W.U8($81);   // marker + version 1
    W.U8((Profile shl 5) or (Level and 31));
    hb := 0;
    if BitDepth > 8 then hb := 1;
    W.U8((Tier shl 7) or (hb shl 6) or (Ord(BitDepth = 12) shl 5) or (Ord(Mono) shl 4) or
         (ChromaSubX shl 3) or (ChromaSubY shl 2));
    W.U8(0);     // no initial presentation delay
    W.Bytes(Cfg);
    W.EndBox;
  end;

  procedure WriteColr;
  begin
    W.StartBox('colr');
    W.Str4('nclx');
    W.U16(ColourPrimaries); W.U16(TransferCharacteristics); W.U16(MatrixCoefficients);
    W.U8(Ord(FullRange) shl 7);
    W.EndBox;
  end;

  procedure WriteTrack(TrackId: Integer; Alpha: Boolean; var OffsAt: Integer);
  var j, runStart, nRuns: Integer; mono: Boolean; dur: LongWord; nSync: Integer;
  begin
    W.StartBox('trak');
      W.StartFull('tkhd', 1, 3);   // enabled | in movie
        W.U64(0); W.U64(0); W.U32(TrackId); W.U32(0);
        W.U64(trackDur);
        W.Zeros(8); W.U16(0); W.U16(0); W.U16(0); W.U16(0);
        W.U32($00010000); W.U32(0); W.U32(0);
        W.U32(0); W.U32($00010000); W.U32(0);
        W.U32(0); W.U32(0); W.U32($40000000);
        W.U32(LongWord(Width) shl 16); W.U32(LongWord(Height) shl 16);
      W.EndBox;
      if Alpha then
      begin
        W.StartBox('tref');
          W.StartBox('auxl'); W.U32(1); W.EndBox;
        W.EndBox;
      end;
      W.StartBox('edts');
        W.StartFull('elst', 1, Ord(LoopCount <> 1));
          W.U32(1);
          W.U64(segDur); W.U64(0);
          W.U16(1); W.U16(0);
        W.EndBox;
      W.EndBox;
      W.StartBox('mdia');
        W.StartFull('mdhd', 1, 0);
          W.U64(0); W.U64(0); W.U32(TIMESCALE); W.U64(segDur);
          W.U16($55C4); W.U16(0);   // language 'und'
        W.EndBox;
        W.StartFull('hdlr', 0, 0);
          W.U32(0);
          if Alpha then W.Str4('auxv') else W.Str4('pict');
          W.Zeros(12); W.U8(0);
        W.EndBox;
        W.StartBox('minf');
          W.StartFull('vmhd', 0, 1); W.Zeros(8); W.EndBox;
          W.StartBox('dinf');
            W.StartFull('dref', 0, 0); W.U32(1);
              W.StartFull('url ', 0, 1); W.EndBox;
            W.EndBox;
          W.EndBox;
          W.StartBox('stbl');
            W.StartFull('stsd', 0, 0); W.U32(1);
              W.StartBox('av01');
                W.Zeros(6); W.U16(1);          // reserved, data_reference_index
                W.Zeros(16);
                W.U16(Width); W.U16(Height);
                W.U32($00480000); W.U32($00480000); W.U32(0); W.U16(1);
                W.U8(10); W.Bytes(PByte(PAnsiChar(AnsiString('AOM Coding'))), 10); W.Zeros(21);
                W.U16($18); W.U16($FFFF);
                if Alpha then
                begin
                  mono := True;
                  WriteAv1C(AlphaProfile, AlphaLevel, 0, mono, AlphaConfigObus);
                  W.StartFull('auxi', 0, 0);
                    W.Bytes(PByte(PAnsiChar(AlphaUrn)), Length(AlphaUrn)); W.U8(0);
                  W.EndBox;
                end
                else
                begin
                  WriteAv1C(SeqProfile, SeqLevelIdx0, SeqTier, Monochrome, ColorConfigObus);
                  WriteColr;
                end;
                // ccst: all samples may reference any prior sample
                W.StartFull('ccst', 0, 0); W.U32($7C000000); W.EndBox;
              W.EndBox;
            W.EndBox;
            // stts (run-length of equal durations)
            nRuns := 0; runStart := 0;
            while runStart < Length(Frames) do
            begin
              j := runStart;
              while (j < Length(Frames)) and (Frames[j].DurationMs = Frames[runStart].DurationMs) do Inc(j);
              Inc(nRuns); runStart := j;
            end;
            W.StartFull('stts', 0, 0);
              W.U32(nRuns);
              runStart := 0;
              while runStart < Length(Frames) do
              begin
                dur := Frames[runStart].DurationMs;
                j := runStart;
                while (j < Length(Frames)) and (LongWord(Frames[j].DurationMs) = dur) do Inc(j);
                W.U32(j - runStart); W.U32(dur);
                runStart := j;
              end;
            W.EndBox;
            W.StartFull('stsc', 0, 0); W.U32(1); W.U32(1); W.U32(1); W.U32(1); W.EndBox;
            W.StartFull('stsz', 0, 0); W.U32(0); W.U32(Length(Frames));
              for j := 0 to High(Frames) do
                if Alpha then W.U32(Length(Frames[j].Alpha)) else W.U32(Length(Frames[j].Data));
            W.EndBox;
            W.StartFull('stco', 0, 0); W.U32(Length(Frames));
              OffsAt := W.Len;
              for j := 0 to High(Frames) do W.U32(0);
            W.EndBox;
            nSync := 0;
            for j := 0 to High(Frames) do if Frames[j].Sync then Inc(nSync);
            if nSync < Length(Frames) then
            begin
              W.StartFull('stss', 0, 0); W.U32(nSync);
                for j := 0 to High(Frames) do if Frames[j].Sync then W.U32(j + 1);
              W.EndBox;
            end;
          W.EndBox;
        W.EndBox;
      W.EndBox;
    W.EndBox;
  end;

begin
  if Length(Frames) = 0 then raise EAvifSequence.Create('AVIF: no frames');
  hasAlpha := Length(Frames[0].Alpha) > 0;
  total := 0;
  for i := 0 to High(Frames) do
  begin
    if Frames[i].DurationMs <= 0 then Frames[i].DurationMs := 100;
    Inc(total, Frames[i].DurationMs);
  end;
  segDur := total;
  if LoopCount = 1 then trackDur := total
  else if LoopCount <= 0 then trackDur := High(UInt64)
  else trackDur := total * UInt64(LoopCount);

  W := TBoxWriter.Create;
  try
    W.StartBox('ftyp');
      W.Str4('avis'); W.U32(0);
      W.Str4('avif'); W.Str4('avis'); W.Str4('msf1'); W.Str4('iso8'); W.Str4('mif1'); W.Str4('miaf');
      if BitDepth <= 10 then W.Str4('MA1B');
    W.EndBox;

    // meta: primary still item = first frame (and its alpha)
    W.StartFull('meta', 0, 0);
      W.StartFull('hdlr', 0, 0); W.U32(0); W.Str4('pict'); W.Zeros(12); W.U8(0); W.EndBox;
      W.StartFull('pitm', 0, 0); W.U16(1); W.EndBox;
      W.StartFull('iloc', 0, 0);
        W.U8($44); W.U8($00);   // offset_size 4, length_size 4, base_offset_size 0
        W.U16(1 + Ord(hasAlpha));
        W.U16(1); W.U16(0); W.U16(1);
        itemColorOffAt := W.Len; W.U32(0); W.U32(Length(Frames[0].Data));
        if hasAlpha then
        begin
          W.U16(2); W.U16(0); W.U16(1);
          itemAlphaOffAt := W.Len; W.U32(0); W.U32(Length(Frames[0].Alpha));
        end
        else itemAlphaOffAt := -1;
      W.EndBox;
      W.StartFull('iinf', 0, 0); W.U16(1 + Ord(hasAlpha));
        W.StartFull('infe', 2, 0); W.U16(1); W.U16(0); W.Str4('av01'); W.Bytes(PByte(PAnsiChar(AnsiString('Color'))), 5); W.U8(0); W.EndBox;
        if hasAlpha then
        begin
          W.StartFull('infe', 2, 1); W.U16(2); W.U16(0); W.Str4('av01'); W.Bytes(PByte(PAnsiChar(AnsiString('Alpha'))), 5); W.U8(0); W.EndBox;
        end;
      W.EndBox;
      if hasAlpha then
      begin
        W.StartFull('iref', 0, 0);
          W.StartBox('auxl'); W.U16(2); W.U16(1); W.U16(1); W.EndBox;
        W.EndBox;
      end;
      W.StartBox('iprp');
        W.StartBox('ipco');
          W.StartFull('ispe', 0, 0); W.U32(Width); W.U32(Height); W.EndBox;                           // 1
          W.StartFull('pixi', 0, 0);                                                                     // 2
            if Monochrome then begin W.U8(1); W.U8(BitDepth); end
            else begin W.U8(3); W.U8(BitDepth); W.U8(BitDepth); W.U8(BitDepth); end;
          W.EndBox;
          WriteAv1C(SeqProfile, SeqLevelIdx0, SeqTier, Monochrome, ColorConfigObus);                  // 3
          WriteColr;                                                                                     // 4
          if hasAlpha then
          begin
            W.StartFull('pixi', 0, 0); W.U8(1); W.U8(BitDepth); W.EndBox;                              // 5
            WriteAv1C(AlphaProfile, AlphaLevel, 0, True, AlphaConfigObus);                               // 6
            W.StartFull('auxC', 0, 0); W.Bytes(PByte(PAnsiChar(AlphaUrn)), Length(AlphaUrn)); W.U8(0); W.EndBox; // 7
          end;
        W.EndBox;
        W.StartFull('ipma', 0, 0); W.U32(1 + Ord(hasAlpha));
          W.U16(1); W.U8(4); W.U8(1); W.U8(2); W.U8($83); W.U8($84);
          if hasAlpha then
          begin
            W.U16(2); W.U8(4); W.U8(1); W.U8(5); W.U8($86); W.U8($87);
          end;
        W.EndBox;
      W.EndBox;
    W.EndBox;

    // moov
    W.StartBox('moov');
      W.StartFull('mvhd', 1, 0);
        W.U64(0); W.U64(0); W.U32(TIMESCALE);
        W.U64(trackDur);
        W.U32($00010000); W.U16($0100); W.Zeros(10);
        W.U32($00010000); W.U32(0); W.U32(0);
        W.U32(0); W.U32($00010000); W.U32(0);
        W.U32(0); W.U32(0); W.U32($40000000);
        W.Zeros(24);
        nTracks := 1 + Ord(hasAlpha);
        W.U32(nTracks + 1);
      W.EndBox;
      WriteTrack(1, False, colorOffsAt);
      alphaOffsAt := -1;
      if hasAlpha then WriteTrack(2, True, alphaOffsAt);
    W.EndBox;

    // mdat
    mdatPayload := 0;
    for i := 0 to High(Frames) do Inc(mdatPayload, Length(Frames[i].Data) + Length(Frames[i].Alpha));
    mdatStart := W.Len;
    W.U32(8 + mdatPayload); W.Str4('mdat');
    SetLength(colorPos, Length(Frames)); SetLength(alphaPos, Length(Frames));
    for i := 0 to High(Frames) do
    begin
      colorPos[i] := W.Len; W.Bytes(Frames[i].Data);
      if hasAlpha then begin alphaPos[i] := W.Len; W.Bytes(Frames[i].Alpha); end;
    end;
    // patch offsets
    for i := 0 to High(Frames) do
    begin
      W.PatchU32(colorOffsAt + i * 4, colorPos[i]);
      if hasAlpha then W.PatchU32(alphaOffsAt + i * 4, alphaPos[i]);
    end;
    W.PatchU32(itemColorOffAt, colorPos[0]);
    if hasAlpha then W.PatchU32(itemAlphaOffAt, alphaPos[0]);
    Result := W.Data;
  finally
    W.Free;
  end;
end;

end.
