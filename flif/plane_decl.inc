// Included several times from flif_image.pas with PLANECLASS / PIXELTYPE
// redefined; generates the concrete Plane<pixel_t> classes of image.hpp.

  PLANECLASS = class(TGeneralPlane)
  private
    FData: array of PIXELTYPE;
    FWidth, FHeight: SizeUInt;
    FS: Integer;
    FSR, FSC: SizeUInt;
  public
    constructor Create(W, H: SizeUInt; Color: ColorVal = 0; AScale: Integer = 0);
    procedure SetPix(R, C: SizeUInt; X: ColorVal); override;
    function GetPix(R, C: SizeUInt): ColorVal; override;
    procedure PrepareZoomlevel(Z: Integer); override;
    function GetFast(R, C: SizeUInt): ColorVal; override;
    procedure SetFast(R, C: SizeUInt; X: ColorVal); override;
    procedure SetPixZ(Z: Integer; R, C: SizeUInt; X: ColorVal); override;
    function GetPixZ(Z: Integer; R, C: SizeUInt): ColorVal; override;
    procedure NormalizeScale; override;
    function BytesPerPixel: Integer; override;
    function ComputeCRC32(Prev: Cardinal): Cardinal; override;
  end;
