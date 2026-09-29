# Webp for Delphi and Lazarus

Can encode and decode without any DLLs or other binaries.

## Usage

Add WebpImageX to your uses, then:
```
Image1.Picture.LoadFromFile('test.webp');
```

## Saving
```
var web: TWebpImage;
    Bmp: TBitmap;
begin
  Bmp := TBitmap.Create;
  Bmp.LoadFromFile('test.bmp');

  web := TWebpImage.Create;
  web.Assign(Bmp);
  Bmp.Free;

  web.SaveToFile('out.webp');
  web.free;
end;
```

## Playing animations

```
   uses WebPAnimate, ...;

  Player := TWebPAnimate.Create(Self);
  Player.Parent  := Self;
  Player.Align   := alClient;
  Player.Stretch := True;
  Player.AutoPlay := True;
  Player.LoadFromFile('anim.webp');
```
## Extracting frames from animations

```
   uses WebPAnimated;

   Anim := TWebPAnimation.Create;
   Anim.LoadFromFile('anim.webp');
   for i := 0 to Anim.FrameCount - 1 do
     Anim.Frames[i].SaveToFile('frame.bmp');
   Anim.Free;
```

## Compatibility

WebP decoding was tested and works:
- on Windows in Delphi/Lazarus 
- on Linux Mint in Lazarus.
