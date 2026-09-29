# XelImageFormats - a package for Delphi/Lazarus/Free Pascal with 50+ image formats for TPicture

Also available in Lazarus Online Package Manager. Add this package to your project and you can just load all those formats like this:
```
Image1.Picture.LoadFromFile('test.webp');
```

## Getting 32bit TBitmap:
```
var Img: TXelGraphic;
    Bmp: TBitmap;
begin
  Img := Image1.Picture.Graphic as TXelGraphic;
  Bmp := Img.ToBitmap;
```
## Saving to a format:
```
var Bmp: TBitmap;
    Webp: TWebpImage;
begin
  Webp := TWebpImage.Create;
  Webp.Assign(Bmp);
  Webp.SaveToFile('test.webp');
  Webp.Free; 
```

## Reading layers in PSD or TIFF
```
 var
   Psd  : TPsdImage;
   Layer: TBitmap;
   Count: Integer;
 begin
   Psd := TPsdImage.Create;
   Psd.LoadFromFile(FileName);
   Count := Psd.LayerCount;
   Layer := Psd.GetLayer(5);
   Layer.Free;
   Psd.Free;
```
