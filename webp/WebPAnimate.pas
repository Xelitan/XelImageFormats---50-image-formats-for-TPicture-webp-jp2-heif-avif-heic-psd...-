unit WebPAnimate;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Visual component that plays animated WebP files               //
// Version:	0.1                                                           //
// Date:	10-JUN-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Drop a TWebPAnimate on a form, set FileName (or call LoadFromFile /        //
// LoadFromStream at run time) and it decodes and plays the animation,        //
// honouring per-frame durations and the loop count.                          //
//                                                                            //
//   WebPAnimate1.LoadFromFile('anim.webp');   // AutoPlay starts it          //
//   WebPAnimate1.Play;  WebPAnimate1.Stop;  WebPAnimate1.Pause;              //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses
  Classes, SysUtils, Graphics, Controls, ExtCtrls,
  WebPAnimated;

type
  { TWebPAnimate }
  TWebPAnimate = class(TGraphicControl)
  private
    FAnim:        TWebPAnimation;
    FTimer:       TTimer;
    FFrameIndex:  Integer;
    FPlaying:     Boolean;
    FAutoPlay:    Boolean;
    FStretch:     Boolean;
    FCenter:      Boolean;
    FLoopsDone:   Integer;
    FFileName:    String;
    FOnFrame:     TNotifyEvent;
    FOnComplete:  TNotifyEvent;
    procedure TimerTick(Sender: TObject);
    procedure SetFileName(const Value: String);
    procedure SetFrameIndex(Value: Integer);
    procedure SetStretch(Value: Boolean);
    procedure SetCenter(Value: Boolean);
    function  GetFrameCount: Integer;
    procedure ScheduleNext;
    procedure SizeToFrame;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    procedure LoadFromFile(const AFileName: String);
    procedure LoadFromStream(Stream: TStream);
    procedure Clear;
    procedure Play;       // start / resume playback from the current frame
    procedure Stop;       // stop and rewind to the first frame
    procedure Pause;      // stop where it is
    property Animation:  TWebPAnimation read FAnim;
    property FrameCount: Integer read GetFrameCount;
    property Playing:    Boolean read FPlaying;
    property FrameIndex: Integer read FFrameIndex write SetFrameIndex;
  published
    property FileName:  String  read FFileName  write SetFileName;
    property AutoPlay:  Boolean read FAutoPlay  write FAutoPlay  default True;
    property Stretch:   Boolean read FStretch   write SetStretch default False;
    property Center:    Boolean read FCenter    write SetCenter  default True;
    // Fired after each frame is shown / when one full loop finishes.
    property OnFrame:    TNotifyEvent read FOnFrame    write FOnFrame;
    property OnComplete: TNotifyEvent read FOnComplete write FOnComplete;
    // Standard TControl properties so it behaves on a form.
    property Align;
    property Anchors;
    property BorderSpacing;
    property Enabled;
    property Hint;
    property ShowHint;
    property PopupMenu;
    property Visible;
    property OnClick;
    property OnDblClick;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
    property OnResize;
  end;

procedure Register;

implementation

const
  DEFAULT_FRAME_MS = 100;   // used when a frame declares 0 ms

constructor TWebPAnimate.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAnim       := TWebPAnimation.Create;
  FTimer      := TTimer.Create(Self);
  FTimer.Enabled  := False;
  FTimer.OnTimer  := TimerTick;
  FFrameIndex := 0;
  FPlaying    := False;
  FAutoPlay   := True;
  FStretch    := False;
  FCenter     := True;
  FLoopsDone  := 0;
  SetInitialBounds(0, 0, 100, 100);   // sensible design-time default size
end;

destructor TWebPAnimate.Destroy;
begin
  FTimer.Enabled := False;
  FAnim.Free;
  inherited Destroy;
end;

function TWebPAnimate.GetFrameCount: Integer;
begin
  Result := FAnim.FrameCount;
end;

procedure TWebPAnimate.SizeToFrame;
begin
  // When not stretching, match the control to the animation canvas.
  if (not FStretch) and (FAnim.Width > 0) and (FAnim.Height > 0) then
    SetBounds(Left, Top, FAnim.Width, FAnim.Height);
end;

procedure TWebPAnimate.Clear;
begin
  FTimer.Enabled := False;
  FPlaying    := False;
  FFrameIndex := 0;
  FLoopsDone  := 0;
  FFileName   := '';
  Invalidate;
end;

procedure TWebPAnimate.LoadFromStream(Stream: TStream);
begin
  FTimer.Enabled := False;
  FAnim.LoadFromStream(Stream);
  FFrameIndex := 0;
  FLoopsDone  := 0;
  FPlaying    := False;
  SizeToFrame;
  Invalidate;
  if FAutoPlay and (FAnim.FrameCount > 1) then
    Play;
end;

procedure TWebPAnimate.LoadFromFile(const AFileName: String);
var fs: TFileStream;
begin
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    LoadFromStream(fs);
  finally
    fs.Free;
  end;
  FFileName := AFileName;
end;

procedure TWebPAnimate.SetFileName(const Value: String);
begin
  FFileName := Value;
  // Only attempt a real load at run time with an existing file
  if (Value <> '') and (not (csDesigning in ComponentState))
     and FileExists(Value) then
    LoadFromFile(Value);
end;

procedure TWebPAnimate.SetFrameIndex(Value: Integer);
begin
  if FAnim.FrameCount = 0 then Exit;
  if Value < 0 then Value := 0;
  if Value > FAnim.FrameCount - 1 then Value := FAnim.FrameCount - 1;
  if Value <> FFrameIndex then
  begin
    FFrameIndex := Value;
    Invalidate;
  end;
end;

procedure TWebPAnimate.SetStretch(Value: Boolean);
begin
  if Value <> FStretch then
  begin
    FStretch := Value;
    if not FStretch then SizeToFrame;
    Invalidate;
  end;
end;

procedure TWebPAnimate.SetCenter(Value: Boolean);
begin
  if Value <> FCenter then
  begin
    FCenter := Value;
    Invalidate;
  end;
end;

procedure TWebPAnimate.ScheduleNext;
var ms: Integer;
begin
  if FAnim.FrameCount = 0 then Exit;
  ms := FAnim.Durations[FFrameIndex];
  if ms <= 0 then ms := DEFAULT_FRAME_MS;
  FTimer.Interval := ms;
  FTimer.Enabled  := True;
end;

procedure TWebPAnimate.Play;
begin
  if FAnim.FrameCount = 0 then Exit;
  if FAnim.FrameCount = 1 then
  begin
    // Single frame: nothing to animate, just show it
    FFrameIndex := 0;
    Invalidate;
    Exit;
  end;
  FPlaying := True;
  Invalidate;
  ScheduleNext;
end;

procedure TWebPAnimate.Pause;
begin
  FTimer.Enabled := False;
  FPlaying := False;
end;

procedure TWebPAnimate.Stop;
begin
  FTimer.Enabled := False;
  FPlaying    := False;
  FFrameIndex := 0;
  FLoopsDone  := 0;
  Invalidate;
end;

procedure TWebPAnimate.TimerTick(Sender: TObject);
begin
  FTimer.Enabled := False;
  if FAnim.FrameCount = 0 then Exit;

  if FFrameIndex >= FAnim.FrameCount - 1 then
  begin
    // Reached the last frame: one loop is complete.
    Inc(FLoopsDone);
    if Assigned(FOnComplete) then FOnComplete(Self);
    // LoopCount = 0 means loop forever; otherwise stop after that many loops.
    if (FAnim.LoopCount > 0) and (FLoopsDone >= FAnim.LoopCount) then
    begin
      FPlaying := False;
      Exit;
    end;
    FFrameIndex := 0;
  end
  else
    Inc(FFrameIndex);

  Invalidate;
  if Assigned(FOnFrame) then FOnFrame(Self);
  ScheduleNext;
end;

procedure TWebPAnimate.Paint;
var
  bmp: TBitmap;
  dx, dy: Integer;
  r: TRect;
begin
  if (FAnim.FrameCount > 0) and (FFrameIndex < FAnim.FrameCount) then
  begin
    bmp := FAnim.Frames[FFrameIndex];
    if FStretch then
      Canvas.StretchDraw(ClientRect, bmp)
    else
    begin
      if FCenter then
      begin
        dx := (ClientWidth  - bmp.Width)  div 2;
        dy := (ClientHeight - bmp.Height) div 2;
      end
      else
      begin
        dx := 0; dy := 0;
      end;
      Canvas.Draw(dx, dy, bmp);
    end;
  end
  else
  begin
    // Design-time / empty placeholder.
    Canvas.Brush.Color := clBtnFace;
    Canvas.FillRect(ClientRect);
    Canvas.Pen.Color := clGray;
    r := ClientRect;
    Canvas.Rectangle(r);
    Canvas.TextOut(4, 4, 'WebPAnimate');
  end;
end;

procedure Register;
begin
  RegisterComponents('Xelitan', [TWebPAnimate]);
end;

end.
