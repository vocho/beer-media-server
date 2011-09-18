unit unitdvdinfo1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, StdCtrls,
  Spin;

type

  { TForm1 }

  TForm1 = class(TForm)
    Button1: TButton;
    Label1: TLabel;
    Label2: TLabel;
    Memo1: TMemo;
    SpinEdit1: TSpinEdit;
    procedure Button1Click(Sender: TObject);
    procedure FormCreate(Sender: TObject);
  private
    { private declarations }
    execpath: string;
    procedure doCommand(no: integer);
  public
    { public declarations }
  end; 

var
  Form1: TForm1; 

implementation
uses
  unit2;

{$R *.lfm}

{ TForm1 }

procedure TForm1.FormCreate(Sender: TObject);
begin
  ExecPath:= ExtractFilePath(ParamStrUTF8(0));
  SpinEdit1.Value:= 1;
  Button1.Enabled:= ParamCount > 0;
  if ParamCount > 0 then DoCommand(1);
end;

procedure TForm1.doCommand(no: integer);
var
  cmd: string;
  ostream: TMemoryStream;
begin
  Label1.Caption:= ParamStrUTF8(1);
  Memo1.Lines.BeginUpdate;
  try
    Memo1.Clear;
    ostream:= TMemoryStream.Create;
    try
      cmd:= '"' + ExecPath + 'mplayer.exe"' +
       ' -speed 100 -vo null -ao null -frames 1 -identify' +
       ' -dvd-device "' + ParamStrUTF8(1) + '" dvd://' + IntToStr(no);
      ExecCommand(cmd, nil, ostream, nil);
      Memo1.Lines.LoadFromStream(ostream);
    finally
      ostream.Free;
    end;
  finally
    Memo1.Lines.EndUpdate;
  end;
end;

procedure TForm1.Button1Click(Sender: TObject);
begin
  DoCommand(SpinEdit1.Value);
end;

end.

