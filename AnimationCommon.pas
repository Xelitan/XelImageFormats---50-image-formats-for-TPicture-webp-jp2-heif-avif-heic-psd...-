unit AnimationCommon;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Shared base class for animation decoders                       //
// Version:	0.1                                                           //
// Date:	25-JUN-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// TCustomAnimation is the common shape every format decoder exposes: a list  //
// of fully-composited BGRA frames, their per-frame durations, the canvas     //
// size and the loop count. The WebP, PNG/APNG and GIF decoders all descend   //
// from it so the visual TAnimation component can treat them uniformly.       //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, SysUtils, Graphics;

type
  { One composited animation frame: a full-canvas bitmap and its display time. }
  TAnimFrame = record
    Bitmap:   TBitmap;   // full canvas, 32-bit BGRA
    Duration: Integer;   // milliseconds this frame is shown
  end;

  { TCustomAnimation - abstract base for all format decoders. }
  TCustomAnimation = class
  protected
    FFrames:    array of TAnimFrame;
    FWidth:     Integer;
    FHeight:    Integer;
    FLoopCount: Integer;   // 0 = loop forever
    FBgColor:   Cardinal;  // background colour (BGRA), informational
    procedure ClearFrames;
    function  GetFrameCount: Integer;
    function  GetFrame(Index: Integer): TBitmap;
    function  GetDuration(Index: Integer): Integer;
    // Takes ownership of ABitmap and appends it as the next frame.
    procedure AddFrame(ABitmap: TBitmap; ADuration: Integer);
  public
    constructor Create; virtual;
    destructor  Destroy; override;
    // Each descendant decodes its own format here.
    procedure LoadFromStream(Stream: TStream); virtual; abstract;
    procedure LoadFromFile(const FileName: String);
    // Total duration of one loop, in milliseconds.
    function TotalDuration: Integer;
    property Width:      Integer read FWidth;
    property Height:     Integer read FHeight;
    property LoopCount:  Integer read FLoopCount;
    property BgColor:    Cardinal read FBgColor;
    property FrameCount: Integer read GetFrameCount;
    property Frames[Index: Integer]:    TBitmap read GetFrame;     default;
    property Durations[Index: Integer]: Integer read GetDuration;
  end;

implementation

constructor TCustomAnimation.Create;
begin
  inherited Create;
  FWidth := 0; FHeight := 0; FLoopCount := 0; FBgColor := 0;
end;

destructor TCustomAnimation.Destroy;
begin
  ClearFrames;
  inherited Destroy;
end;

procedure TCustomAnimation.ClearFrames;
var i: Integer;
begin
  for i := 0 to High(FFrames) do
    FFrames[i].Bitmap.Free;
  SetLength(FFrames, 0);
end;

procedure TCustomAnimation.AddFrame(ABitmap: TBitmap; ADuration: Integer);
var n: Integer;
begin
  n := Length(FFrames);
  SetLength(FFrames, n + 1);
  FFrames[n].Bitmap   := ABitmap;
  FFrames[n].Duration := ADuration;
end;

function TCustomAnimation.GetFrameCount: Integer;
begin
  Result := Length(FFrames);
end;

function TCustomAnimation.GetFrame(Index: Integer): TBitmap;
begin
  if (Index < 0) or (Index > High(FFrames)) then
    raise EListError.CreateFmt('Animation: frame index %d out of range', [Index]);
  Result := FFrames[Index].Bitmap;
end;

function TCustomAnimation.GetDuration(Index: Integer): Integer;
begin
  if (Index < 0) or (Index > High(FFrames)) then
    raise EListError.CreateFmt('Animation: frame index %d out of range', [Index]);
  Result := FFrames[Index].Duration;
end;

function TCustomAnimation.TotalDuration: Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to High(FFrames) do Inc(Result, FFrames[i].Duration);
end;

procedure TCustomAnimation.LoadFromFile(const FileName: String);
var fs: TFileStream;
begin
  fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    LoadFromStream(fs);
  finally
    fs.Free;
  end;
end;

end.
