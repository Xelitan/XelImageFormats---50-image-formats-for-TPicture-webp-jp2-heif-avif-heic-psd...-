# JPEG 2000 encoder/decoder ported from JASPER

# Usage
```
uses Jp2ImageX;

Image1.Picture.LoadFromFile('test.jp2');
```

# Saving to jp2

```
var Jp2: TJp2Image;
    Bmp: TBitmap;
begin
  Bmp := TBitmap.Create;
  Bmp.LoadFromFile('test.bmp');

  Jp2 := TJp2Image.Create;
  Jp2.Assign(Bmp);
  Bmp.Free;

  Jp2.SaveToFile('out.Jp2');
  Jp2.free;
```

# Usage of command-line program:
```
  jp2k - command-line front end for the Free Pascal JPEG 2000 codec

  Usage:
    jp2k enc [options] <in.pgm|in.ppm> <out.jpc>
    jp2k dec <in.jpc> <out.pgm|out.ppm>
    jp2k gen <w> <h> <comps> <out.pgm|out.ppm>     (synthetic test image)

  enc options:
    -lossy            use the irreversible 9/7 path (default: lossless 5/3)
    -step <f>         quantiser step for -lossy (default 1.0)
    -levels <n>       DWT decomposition levels (default: auto)
    -nomct            disable the colour transform for 3-component images
```
