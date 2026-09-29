unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, XelImageFormats;

type

  { TForm1 }

  TForm1 = class(TForm)
    Image1: TImage;
    procedure FormDropFiles(Sender: TObject; const FileNames: array of string);
  private

  public

  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

{ TForm1 }

procedure TForm1.FormDropFiles(Sender: TObject; const FileNames: array of string
  );
begin
  Image1.Picture.LoadFromFile(FileNames[0]);
end;

end.

