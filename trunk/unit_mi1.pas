unit unit_mi1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, StdCtrls;

type

  { TForm1 }

  TForm1 = class(TForm)
    Label1: TLabel;
    Memo1: TMemo;
    procedure FormCreate(Sender: TObject);
  private
    { private declarations }
    execpath: string;
    procedure doCommand;
  public
    { public declarations }
  end; 

var
  Form1: TForm1; 

implementation
uses
  unit2, MediaInfoDll;

{$R *.lfm}

{ TForm1 }

procedure TForm1.FormCreate(Sender: TObject);
begin
  ExecPath:= ExtractFilePath(ParamStrUTF8(0));
  if ParamCount > 0 then DoCommand;
end;

procedure TForm1.doCommand;
var
  mi: integer;
  sl: TStringList;
  i: Integer;
begin
  Label1.Caption:= ParamStrUTF8(1);
  Memo1.Clear;
  Memo1.Lines.BeginUpdate;
  try
    mi:= MediaInfo_New;
    try
      sl:= TStringList.Create;
      try
        GetMediaInfo(ParamStrUTF8(1), mi, sl, ExecPath);
        for i:= 0 to sl.Count-1 do begin
          sl[i]:=
           StringReplace(sl.Names[i], ';', '.', [rfReplaceAll, rfIgnoreCase]) +
           ' = ' + sl.ValueFromIndex[i];
        end;
        Memo1.Lines.AddStrings(sl);
      finally
        sl.Free;
      end;
    finally
      MediaInfo_Delete(mi);
    end;
  finally
    Memo1.Lines.EndUpdate;
  end;
end;

end.

