# Usage

```
uses JxlImageX;

Image1.Picture.LoadFromFile('test.jxl');
```

## Saving to JPEG XL
```
var jxl: TJxlImage;
    Bmp: TBitmap;
begin
  Bmp := TBitmap.Create;
  Bmp.LoadFromFile('test.bmp');

  jxl := TJxlImage.Create;
  jxl.Assign(Bmp);
  Bmp.Free;

  jxl.SaveToFile('out.jxl');
  jxl.free; 
```
