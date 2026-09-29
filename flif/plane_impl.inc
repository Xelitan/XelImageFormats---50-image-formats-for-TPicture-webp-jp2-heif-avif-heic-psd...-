// Method bodies for the concrete plane classes; see plane_decl.inc.

constructor PLANECLASS.Create(W, H: SizeUInt; Color: ColorVal; AScale: Integer);
var
  I, N: SizeUInt;
begin
  inherited Create;
  FS := AScale;
  FWidth := SCALED(W, AScale);
  FHeight := SCALED(H, AScale);
  N := FWidth * FHeight;
  SetLength(FData, N);
  if Color <> 0 then
    for I := 0 to N - 1 do
      FData[I] := PIXELTYPE(Color);
end;

procedure PLANECLASS.SetPix(R, C: SizeUInt; X: ColorVal);
begin
  FData[R * FWidth + C] := PIXELTYPE(X);
end;

function PLANECLASS.GetPix(R, C: SizeUInt): ColorVal;
begin
  Result := FData[R * FWidth + C];
end;

procedure PLANECLASS.PrepareZoomlevel(Z: Integer);
begin
  FSR := (ZoomRowPixelSize(Z) shr FS) * FWidth;
  FSC := ZoomColPixelSize(Z) shr FS;
end;

function PLANECLASS.GetFast(R, C: SizeUInt): ColorVal;
begin
  Result := FData[R * FSR + C * FSC];
end;

procedure PLANECLASS.SetFast(R, C: SizeUInt; X: ColorVal);
begin
  FData[R * FSR + C * FSC] := PIXELTYPE(X);
end;

procedure PLANECLASS.SetPixZ(Z: Integer; R, C: SizeUInt; X: ColorVal);
begin
  FData[((R * ZoomRowPixelSize(Z)) shr FS) * FWidth + ((C * ZoomColPixelSize(Z)) shr FS)] := PIXELTYPE(X);
end;

function PLANECLASS.GetPixZ(Z: Integer; R, C: SizeUInt): ColorVal;
begin
  Result := FData[((R * ZoomRowPixelSize(Z)) shr FS) * FWidth + ((C * ZoomColPixelSize(Z)) shr FS)];
end;

procedure PLANECLASS.NormalizeScale;
begin
  FS := 0;
end;

function PLANECLASS.BytesPerPixel: Integer;
begin
  Result := SizeOf(PIXELTYPE);
end;

function PLANECLASS.ComputeCRC32(Prev: Cardinal): Cardinal;
begin
  if Length(FData) = 0 then
    Result := crc32_fast(nil, 0, Prev)
  else
    Result := crc32_fast(@FData[0], FWidth * FHeight * SizeOf(PIXELTYPE), Prev);
end;
