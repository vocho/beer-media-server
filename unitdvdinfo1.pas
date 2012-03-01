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
    procedure FormDropFiles(Sender: TObject; const FileNames: array of String);
  private
    { private declarations }
    execpath, FileName: string;
    procedure DoCommand(const fname:string; no: integer);
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
  if ParamCount > 0 then DoCommand(ParamStrUTF8(1), 1);
end;

procedure TForm1.FormDropFiles(Sender: TObject; const FileNames: array of String
  );
begin
  DoCommand(FileNames[0], 1);
  Button1.Enabled:= True;
end;

function DeleteEscapeSequence(const s: string): string;
var
  i: Integer;
begin
  Result:= '';
  i:= 1;
  while i <= Length(s) do begin
    if s[i] = #$1B then begin
      while (s[i] <> 'm') and (i <= Length(s)) do Inc(i);
    end else
      Result:= Result + s[i];
    Inc(i);
  end;
end;

procedure TForm1.DoCommand(const fname:string; no: integer);
var
  cmd: string;
  ostream: TStringStream;
begin
  FileName:= fname;
  Label1.Caption:= FileName;
  Memo1.Lines.BeginUpdate;
  try
    Memo1.Clear;
    ostream:= TStringStream.Create('');
    try
      cmd:= '"' + ExecPath + 'mplayer.exe"' +
       ' -speed 100 -vo null -ao null -frames 1 -identify' +
       ' -dvd-device "' + FileName + '" dvd://' + IntToStr(no);
      ExecCommand(cmd, nil, ostream, nil);
      //Memo1.Lines.Text:= DeleteEscapeSequence(ostream.DataString);
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
  DoCommand(FileName, SpinEdit1.Value);
end;

end.

