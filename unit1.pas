{
TODO
  起動時直後の通信
}
unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, ExtCtrls,
  StdCtrls, Menus, Buttons, SynMemo;

const
  APP_NAME = 'BEER Media Server';
  SHORT_APP_NAME = 'BMS';
  APP_VERSION = '1.2.120121';
  SHORT_APP_VERSION = '1.2';

type

  { TForm1 }

  TForm1 = class(TForm)
    BitBtn1: TBitBtn;
    BitBtn2: TBitBtn;
    CheckBoxLog: TCheckBox;
    MemoLog: TSynMemo;
    procedure BitBtn2Click(Sender: TObject);
    procedure CheckBoxLogChange(Sender: TObject);
    procedure FormCreate(Sender: TObject);
  private
    { private declarations }
    procedure AsyncFromCreate({%H-}Data: PtrInt);
  public
    { public declarations }
  end; 

var
  Form1: TForm1; 
  TrayIcon: TTrayIcon;

procedure InitAfterApplicationInitialize;

implementation
uses
  LCLIntf, blcksock, synsock, synautil, {synacode,}
  DOM, XMLWrite, XMLRead, MediaInfoDll,
  Lua, lualib, lauxlib,
  {$IFDEF Win32}
  interfacebase, win32int, windows, // for Hook SUSPEND EVENT
  {$ENDIF}
  lazutf8classes, inifiles, comobj, contnrs, process, utf8process, SynRegExpr,
  unit2;


{$R *.lfm}

const
  HTTP_HEAD_SERVER = 'OS/1.0, UPnP/1.0, ' + SHORT_APP_NAME + '/' + SHORT_APP_VERSION;
  INI_SEC_SYSTEM = 'SYSTEM';
  MAX_ONMEM_LOG = 500;

type

  { TMyApp }

  TMyApp = class
  public
    Log: TStringListUTF8;
    LogFile: TFileStreamUTF8;
    PopupMenu: TPopupMenu;
    constructor Create;
    destructor Destroy; override;
    procedure OnTrayIconClick(Sender: TObject);
    procedure OnMenuShowClick(Sender: TObject);
    procedure OnMenuQuitClick(Sender: TObject);
    procedure AddLog(const line: string);
    procedure WMPowerBoadcast(var msg: TMessage);
  end;

  { THttpDaemon }

  THttpDaemon = class(TThread)
  private
    Sock: TTCPBlockSocket;
    line: string;
    th_list: TObjectList;
    procedure AddLog;
  public
    SendAliveFlag: boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Execute; override;
  end;

  { THttpThrd }

  TClientInfo = class;

  THttpThrd = class(TThread)
  private
    Sock: TTCPBlockSocket;
    line: string;
    L_S: Plua_State;
    ClientInfo: TClientInfo;
    procedure AddLog;
    function DoGetTranscodeCommand(const fname: string): string;
    function DoPlay(const fname, request: string): boolean;
    function DoPlayTranscode(sno: integer; const fname, request: string): boolean;
    function DoBrowse(docr, docw: TXMLDocument): boolean;
    function SendRaw(buf: Pointer; len: integer): boolean; overload;
    function SendRaw(const buf: string): boolean; overload;
  public
    Done: boolean;
    Headers: TStringListUTF8;
    InputData, OutputData: TMemoryStream;
    UniOutput: boolean;
    InHeader: string;
    constructor Create(hsock: TSocket);
    destructor Destroy; override;
    procedure Execute; override;
    function ProcessHttpRequest(const Request, URI: string): integer;
  end;

  { TSSDPDaemon }

  TSSDPDaemon = class(TThread)
  private
    Sock: TUDPBlockSocket;
    line: string;
    procedure AddLog;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Execute; override;
  end;

  { TGetMediaInfo }
  TGetMediaInfo = class(TStringListUTF8)
  public
    FileName, AccTime, MimeType: string;
    FileSize: Int64;
    IsTemp: boolean;
    constructor Create(const fname: string; mi: Cardinal);
    destructor Destroy; override;
    function GetMimeType(L: PLua_State; const scname: string; get_new: boolean = False): string;
  end;

  { TMediaInfoCollector }

  TMediaInfoCollector = class(TThread)
  private
    miHandle: Cardinal;
    mi_list, mi_ac_list: TStringListUTF8;
    MaxMediaInfo: integer;
  public
    cs_list, cs_ac_list, cs_pr_list, cs_get_mi: TCriticalSection;
    PriorityList: TStringListUTF8;
    constructor Create;
    destructor Destroy; override;
    procedure Execute; override;
    function GetMediaInfo(const fname: string): TGetMediaInfo;
    procedure ClearMediaInfo;
  end;

  { TClientInfo }

  TClientInfo = class
  public
    CurId, CurDir: string;
    FullInfoCount: integer;
    CurFileList: TStringList;
    LastAccTime: TDateTime;
    ScriptFileName: string;
    constructor Create;
    destructor Destroy; override;
  end;

var
  iniFile: TIniFile;
  ExecPath, TempPath, UUID, DAEMON_PORT: string;
  MAX_REQUEST_COUNT: integer;
  MyApp: TMyApp;
  thHttpDaemon: THttpDaemon;
  thSSDPDAemon: TSSDPDaemon;
  thMIC: TMediaInfoCollector;
  MediaDirs: TStringList;
  ClientInfoList: TStringList;
  MyIPAddr: string;

function Alloc({%H-}ud, ptr: Pointer; {%H-}osize, nsize: size_t) : Pointer; cdecl;
begin
  try
    Result:= ptr;
    ReallocMem(Result, nSize);
  except
    Result:= nil;
  end;
end;

function print_func(L : Plua_State) : Integer; cdecl;
var
  i, c: integer;
  s: string;
begin
  Result := 0;
  if not Assigned(MyApp) then Exit;
  c:= lua_gettop(L);
  s:= '';
  for i:= 1 to c do s:= s + lua_tostring(L, i);
  MyApp.AddLog(s);
end;

function tonumberDef_func(L : Plua_State) : Integer; cdecl;
var
  s: string;
  n: lua_Number;
begin
  s:= lua_tostring(L, 1);
  n:= lua_tonumber(L, 2);
  lua_pushnumber(L, StrToFloatDef(s, n));
  Result := 1;
end;

function regexpr_matches_func(L : Plua_State) : Integer; cdecl;
var
  s1, s2: string;
begin
  s1:= lua_tostring(L, 1);
  s2:= lua_tostring(L, 2);
  try
    lua_pushboolean(L, ExecRegExpr(s2, s1));
  except
    on E: Exception do begin
      luaL_error(L, PChar(E.Message), []);
    end;
  end;
  Result := 1;
end;

function ScriptFileExists_func(L : Plua_State) : Integer; cdecl;
var
  s: string;
  b: boolean;
begin
  s:= lua_tostring(L, 1);
  b:= FileExistsUTF8(ExecPath + 'script/' + s + '.lua') or
   FileExistsUTF8(ExecPath + 'script_user/' + s + '.lua');
  lua_pushboolean(L, b);
  Result := 1;
end;

procedure InitLua(L: Plua_State);
begin
  luaL_openlibs(L);
  lua_register(L, 'print', @print_func);
  lua_register(L, 'tonumberDef', @tonumberDef_func);
  lua_register(L, 'ScriptFileExists', @ScriptFileExists_func);
  lua_newtable(L);
  lua_pushstring(L, 'matches');
  lua_pushcfunction(L, @regexpr_matches_func);
  lua_settable(L, -3);
  lua_setglobal(L, 'regexpr');
end;

procedure LoadLua(L: Plua_State; const fname: string; const module: string = '');
var
  sl: TStringListUTF8;
  s: string;
begin
  sl:= TStringListUTF8.Create;
  try
    s:= fname;
    if ExtractFilePath(fname) = '' then begin
      s:= ExecPath + 'script_user/' + fname + '.lua';
      if not FileExistsUTF8(s) then s:= ExecPath + 'script/' + fname + '.lua';
    end;
    sl.LoadFromFile(s);
    if (sl.Count > 0) and (Length(sl[0]) >= 3) and
     (sl[0][1] = #$EF) and (sl[0][2] = #$BB) and (sl[0][3] = #$BF) then begin
      // BOM を削除
      sl[0]:= Copy(sl[0], 4, MaxInt);
    end;
    if module <> '' then begin
      sl.Insert(0, 'module("' + module + '", package.seeall)');
    end;
    if luaL_loadbuffer(L, PChar(sl.Text), Length(sl.Text), PChar(fname)) <> 0 then
      Raise Exception.Create(fname + '.lua Compile Error(' + lua_tostring(L, -1)+')');
  finally
    sl.Free;
  end;
end;

procedure CallLua(L: Plua_State; nargs, nresults: Integer);
begin
  if lua_pcall(L, nargs, nresults, 0) <> 0 then
    Raise Exception.Create('Lua Runtime Error('+lua_tostring(L, -1)+')');
end;

procedure SendAlive;
var
  sock: TUDPBlockSocket;
  s: string;
begin
  // Sends an advertisement "alive" message on multicast
  sock:= TUDPBlockSocket.Create;
  try
    Sock.Family:= SF_IP4;
    sock.CreateSocket();
    sock.Bind('0.0.0.0', '0');
    sock.MulticastTTL:= 1;
    sock.Connect('239.255.255.250', '1900'{SSDP});
    if sock.LastError = 0 then begin
      if MyIPAddr = '' then MyIPAddr:= Sock.ResolveName(Sock.LocalName);

      //{
      s:=
       'NOTIFY * HTTP/1.1' + CRLF +
       'HOST: 239.255.255.250:1900'+ CRLF +
       'CACHE-CONTROL: max-age=2100'+ CRLF +
       'LOCATION: http://' + MyIPAddr + ':' + DAEMON_PORT +
         '/desc.xml' + CRLF +
       'NT: upnp:rootdevice'+ CRLF +
       'NTS: ssdp:alive'+ CRLF +
       'SERVER: ' + HTTP_HEAD_SERVER + CRLF +
       'USN: uuid:' + UUID + '::upnp:rootdevice' +
       CRLF + CRLF;

      sock.SendString(s);

      s:=
       'NOTIFY * HTTP/1.1' + CRLF +
       'HOST: 239.255.255.250:1900'+ CRLF +
       'CACHE-CONTROL: max-age=2100'+ CRLF +
       'LOCATION: http://' + MyIPAddr + ':' + DAEMON_PORT +
         '/desc.xml' + CRLF +
       'NT: uuid:' + UUID + CRLF +
       'NTS: ssdp:alive'+ CRLF +
       'SERVER: ' + HTTP_HEAD_SERVER + CRLF +
       'USN: uuid:' + UUID +
       CRLF + CRLF;

      sock.SendString(s);
      //}

      s:=
       'NOTIFY * HTTP/1.1' + CRLF +
       'HOST: 239.255.255.250:1900'+ CRLF +
       'CACHE-CONTROL: max-age=2100'+ CRLF +
       'LOCATION: http://' + MyIPAddr + ':' + DAEMON_PORT +
         '/desc.xml' + CRLF +
       'NT: urn:schemas-upnp-org:device:MediaServer:1' + CRLF +
       'NTS: ssdp:alive'+ CRLF +
       'SERVER: ' + HTTP_HEAD_SERVER + CRLF +
       'USN: uuid:' + UUID + '::urn:schemas-upnp-org:device:MediaServer:1' +
       CRLF + CRLF;

      sock.SendString(s);

      //{
      s:=
       'NOTIFY * HTTP/1.1' + CRLF +
       'HOST: 239.255.255.250:1900'+ CRLF +
       'CACHE-CONTROL: max-age=2100'+ CRLF +
       'LOCATION: http://' + MyIPAddr + ':' + DAEMON_PORT +
         '/desc.xml' + CRLF +
       'NT: urn:schemas-upnp-org:service:ContentDirectory:1' + CRLF +
       'NTS: ssdp:alive'+ CRLF +
       'SERVER: ' + HTTP_HEAD_SERVER + CRLF +
       'USN: uuid:' + UUID + '::urn:schemas-upnp-org:service:ContentDirectory:1' +
       CRLF + CRLF;

      sock.SendString(s);

      s:=
       'NOTIFY * HTTP/1.1' + CRLF +
       'HOST: 239.255.255.250:1900'+ CRLF +
       'CACHE-CONTROL: max-age=2100'+ CRLF +
       'LOCATION: http://' + MyIPAddr + ':' + DAEMON_PORT +
         '/desc.xml' + CRLF +
       'NT: urn:schemas-upnp-org:service:ConnectionManager:1' + CRLF +
       'NTS: ssdp:alive'+ CRLF +
       'SERVER: ' + HTTP_HEAD_SERVER + CRLF +
       'USN: uuid:' + UUID + '::urn:schemas-upnp-org:service:ConnectionManager:1' +
       CRLF + CRLF;

      sock.SendString(s);
      //}
    end;
  finally
    sock.Free;
  end;
end;

procedure SendByebye;
var
  sock: TUDPBlockSocket;
  s: string;
begin
  // Sends an advertisement "byebye" message on multicast
  sock:= TUDPBlockSocket.Create;
  try
    Sock.Family:= SF_IP4;
    sock.CreateSocket();
    sock.Bind('0.0.0.0', '0');
    sock.MulticastTTL:= 1;
    sock.Connect('239.255.255.250', '1900'{SSDP});
    if sock.LastError = 0 then begin
      //{
      s:=
       'NOTIFY * HTTP/1.1' + CRLF +
       'HOST: 239.255.255.250:1900'+ CRLF +
       'NT: upnp:rootdevice'+ CRLF +
       'NTS: ssdp:byebye'+ CRLF +
       'USN: uuid:' + UUID + '::upnp:rootdevice' +
       CRLF + CRLF;

      sock.SendString(s);
      //}

      s:=
       'NOTIFY * HTTP/1.1' + CRLF +
       'HOST: 239.255.255.250:1900'+ CRLF +
       'NT: urn:schemas-upnp-org:device:MediaServer:1' + CRLF +
       'NTS: ssdp:byebye'+ CRLF +
       'USN: uuid:' + UUID + '::urn:schemas-upnp-org:device:MediaServer:1' +
       CRLF + CRLF;

      sock.SendString(s);

      //{
      s:=
       'NOTIFY * HTTP/1.1' + CRLF +
       'HOST: 239.255.255.250:1900'+ CRLF +
       'NT: urn:schemas-upnp-org:service:ContentDirectory:1' + CRLF +
       'NTS: ssdp:byebye'+ CRLF +
       'USN: uuid:' + UUID + '::urn:schemas-upnp-org:service:ContentDirectory:1' +
       CRLF + CRLF;

      sock.SendString(s);

      s:=
       'NOTIFY * HTTP/1.1' + CRLF +
       'HOST: 239.255.255.250:1900'+ CRLF +
       'NT: urn:schemas-upnp-org:service:ConnectionManager:1' + CRLF +
       'NTS: ssdp:byebye'+ CRLF +
       'USN: uuid:' + UUID + '::urn:schemas-upnp-org:service:ConnectionManager:1' +
       CRLF + CRLF;

      sock.SendString(s);
      //}
    end;
  finally
    sock.Free;
  end;
end;

procedure MIValue2LuaTable(L: PLua_State; const val: string);
var
  s, ss: string;
  isnill: boolean;
begin
  s:= val;
  ss:= Fetch(s, ';');
  if s = '' then begin
    lua_pushstring(L, Fetch(ss, '='));
    lua_pushstring(L, ss);
    lua_settable(L, -3);
  end else begin
    lua_pushstring(L, ss);
    lua_gettable(L, -2);
    isnill:= lua_isnil(L, -1);
    if isnill then begin
      lua_pop(L, 1);
      lua_pushstring(L, ss);
      lua_newtable(L);
    end;
    MIValue2LuaTable(L, s);
    if isnill then begin
      lua_settable(L, -3);
    end else begin
      lua_pop(L, 1);
    end;
  end;
end;

function GetLineHeader: string;
begin
  Result:=  '*** ' + FormatDateTime('mm/dd hh:nn:ss ', Now);
end;

var
  PrevWndProc: WNDPROC;

{$IFDEF Win32}
function WndCallback(Ahwnd: HWND; uMsg: UINT; wParam: WParam; lParam: LParam):LRESULT; stdcall;
var
  msg: TMessage;
begin
  case uMsg of
    WM_POWERBROADCAST: begin
      msg.Result:= Windows.DefWindowProc(Ahwnd, uMsg, WParam, LParam);  //not sure about this one
      msg.msg:= uMsg;
      msg.wParam:= wParam;
      msg.lParam:= lParam;
      MyApp.WMPowerBoadcast(msg);
      Result:= msg.Result;
      Exit;
    end;
    WM_ENDSESSION: begin
      SendByebye;
    end;
  end;
  result:=CallWindowProc(PrevWndProc,Ahwnd, uMsg, WParam, LParam);
end;
{$ENDIF}

procedure InitAfterApplicationInitialize;
begin
  {$IFDEF Win32}
  PrevWndProc:= {%H-}Windows.WNDPROC(SetWindowLong(Widgetset.AppHandle, GWL_WNDPROC,{%H-}PtrInt(@WndCallback)));
  {$ENDIF}
end;

{ TMyApp }

constructor TMyApp.Create;
var
  mi: TMenuItem;
  i: integer;
  sl: TStringList;
begin
  UUID:= '';
  if FileExistsUTF8(ExecPath + 'UUID') then begin
    sl:= TStringListUTF8.Create;
    try
      sl.LoadFromFile(ExecPath + 'UUID');
      if sl.Count > 0 then UUID:= sl[0];
    finally
      sl.Free;
    end;
  end;

  if UUID = '' then begin
    UUID:= iniFile.ReadString(INI_SEC_SYSTEM, 'UUID', ''); // 旧版からUUIDを移行
    if UUID = '' then
      UUID:= Copy(CreateClassID, 2, 36) // 新しいUUIDを作成
    else
      iniFile.WriteString(INI_SEC_SYSTEM, 'UUID', ''); // 旧版からUUIDを移行
    sl:= TStringListUTF8.Create;
    try
      sl.Add(UUID);
      sl.SaveToFile(ExecPath + 'UUID');
    finally
      sl.Free;
    end;
  end;

  DAEMON_PORT:= iniFile.ReadString(INI_SEC_SYSTEM, 'HTTP_PORT', '5008');
  Log:= TStringListUTF8.Create;

  MAX_REQUEST_COUNT:= iniFile.ReadInteger(INI_SEC_SYSTEM, 'MAX_REQUEST_COUNT', 0);

  MediaDirs:= TStringListUTF8.Create;
  iniFile.ReadSectionValues('MediaDirs', MediaDirs);
  i:= 0;
  while i < MediaDirs.Count do begin
    if (MediaDirs.Names[i] = '') or (MediaDirs.ValueFromIndex[i] = '') or
     (Trim(MediaDirs[i])[1] = ';') then begin
      MediaDirs.Delete(i);
    end else
      Inc(i);
  end;
  if MediaDirs.Count = 0 then begin
    TrayIcon.BalloonHint:= '[MediaDirs]が未設定です。';
    TrayIcon.ShowBalloonHint;
  end;

  if not DirectoryExistsUTF8(TempPath) then
    ForceDirectoriesUTF8(TempPath);

  ClientInfoList:= TStringListUTF8_mod.Create;
  ClientInfoList.Sorted:= True;

  thMIC:= TMediaInfoCollector.Create;

  // Run HTTP Daemon
  thHttpDaemon:= THttpDaemon.Create;
  Sleep(1000); // 念のため
  // Run SSDP Daemon
  thSSDPDaemon:= TSSDPDaemon.Create;

  PopupMenu:= TPopupMenu.Create(nil);
  mi:= TMenuItem.Create(nil);
  mi.Caption:= '&Show';
  mi.OnClick:= @OnMenuShowClick;
  PopupMenu.Items.Add(mi);
  mi:= TMenuItem.Create(nil);
  mi.Caption:= '-';
  PopupMenu.Items.Add(mi);
  mi:= TMenuItem.Create(nil);
  mi.Caption:= '&Quit';
  mi.OnClick:= @OnMenuQuitClick;
  PopupMenu.Items.Add(mi);

  TrayIcon.PopUpMenu := PopupMenu;
  TrayIcon.OnClick:= @MyApp.OnTrayIconClick;

  SendAlive;
end;

destructor TMyApp.Destroy;
var
  i: Integer;
begin
  SendByebye;
  if Assigned(thSSDPDaemon) then begin
    thSSDPDaemon.Terminate;
    thSSDPDaemon.Sock.CloseSocket;
    thSSDPDaemon.WaitFor;
    FreeAndNil(thSSDPDaemon);
  end;
  if Assigned(thHttpDaemon) then begin
    thHttpDaemon.Terminate;
    thHTTPDaemon.Sock.CloseSocket;
    thHttpDaemon.WaitFor;
    FreeAndNil(thHttpDaemon);
  end;
  if Assigned(thMIC) then begin
    tHMIC.Suspended:= False;
    thMIC.Terminate;
    thMIC.WaitFor;
    FreeAndNil(thMIC);
  end;
  for i:= 0 to ClientInfoList.Count-1 do ClientInfoList.Objects[i].Free;
  ClientInfoList.Free;
  Log.Free;
  LogFile.Free;
  MediaDirs.Free;
  while PopupMenu.Items.Count > 0 do begin
    PopupMenu.Items[0].Free;
    //PopupMenu.Items.Delete(0);
  end;
  PopupMenu.Free;
  inherited Destroy;
end;

procedure TMyApp.OnTrayIconClick(Sender: TObject);
begin
  if Assigned(Form1) then begin
    Form1.Show;
    Form1.WindowState:= wsNormal;
  end else begin
    Application.CreateForm(TForm1, Form1);
    try
      //TrayIcon.PopupMenu.Items[1].Visible:= False;
      if Form1.ShowModal = mrClose then begin
        Application.Terminate;
        Exit;
      end;
      //TrayIcon.PopupMenu.Items[1].Visible:= True;
    finally
      FreeAndNil(Form1);
    end;
  end;
end;

procedure TMyApp.OnMenuShowClick(Sender: TObject);
begin
  OnTrayIconClick(nil);
end;

procedure TMyApp.OnMenuQuitClick(Sender: TObject);
begin
  Application.Terminate;
end;

procedure TMyApp.AddLog(const line: string);
var
  s: string;
begin
  Log.Add(line);
  while Log.Count > MAX_ONMEM_LOG do Log.Delete(0);
  if Assigned(LogFile) then begin
    s:= line + CRLF;
    LogFile.Write(s[1], Length(s));
  end;
end;

procedure TMyApp.WMPowerBoadcast(var msg: TMessage);
begin
  case msg.WParam of
    $0004{PBT_APMSUSPEND}, $0005{PBT_APMSTANDBY}: begin
      MyApp.AddLog(GetLineHeader + ' GO TO SLEEP...' + CRLF + CRLF);
      SendByebye();
    end;
    // $0007{PBT_APMRESUMESUSPEND}, $0008{PBT_APMRESUMESTANDBY}: begin
    $0012{PBT_APMRESUMEAUTOMATIC}: begin
      MyApp.AddLog(GetLineHeader + ' WAKE UP!!!' + CRLF + CRLF);
      SendAlive; // alive
      thHTTPDaemon.SendAliveFlag:= True;
    end;
  end;
end;

{ TForm1 }

procedure TForm1.FormCreate(Sender: TObject);
begin
  Caption:= APP_NAME + ' ' + APP_VERSION;
  MemoLog.Text:= MyApp.Log.Text;
  MemoLog.CaretX:= 0;
  MemoLog.CaretY:= MemoLog.Lines.Count+10;
  //MemoLog.EnsureCursorPosVisible;
  Application.QueueAsyncCall(@AsyncFromCreate, 0);
  CheckBoxLog.OnChange:= nil;
  CheckBoxLog.Checked:= Assigned(MyApp.LogFile);
  CheckBoxLog.OnChange:= @CheckBoxLogChange;
end;

procedure TForm1.AsyncFromCreate(Data: PtrInt);
begin
  MemoLog.EnsureCursorPosVisible;
end;

procedure TForm1.CheckBoxLogChange(Sender: TObject);
var
  fn: string;
begin
  fn:= ExecPath + FormatDateTime('yyyy-mm-dd-hh-mm-ss', Now) + '.log';
  if CheckBoxLog.Checked then begin
    MyApp.Log.SaveToFile(fn);
    MyApp.LogFile:= TFileStreamUTF8.Create(fn, fmOpenReadWrite or fmShareExclusive);
    MyApp.LogFile.Seek(0, soEnd);
  end else begin
    FreeAndNil(MyApp.LogFile);
  end;
end;

procedure TForm1.BitBtn2Click(Sender: TObject);
begin
  MemoLog.Lines.BeginUpdate;
  try
    MemoLog.Text:= MyApp.Log.Text;
    MemoLog.CaretX:= 0;
    MemoLog.CaretY:= MemoLog.Lines.Count;
    MemoLog.EnsureCursorPosVisible;
  finally
    MemoLog.Lines.EndUpdate;
  end;
end;

{ TTCPHttpDaemon }

procedure THttpDaemon.AddLog;
begin
  if not Assigned(MyApp) then Exit;
  MyApp.AddLog(line);
  line:= '';
end;

constructor THttpDaemon.Create;
begin
  th_list:= TObjectList.Create(False);
  FreeOnTerminate:= False;
  inherited Create(False);
end;

destructor THttpDaemon.Destroy;
var
  th: THttpThrd;
  i: integer;
begin
  for i:= 0 to th_list.Count-1 do begin
    th:= THttpThrd(th_list[i]);
    th.Terminate;
    if Assigned(th.Sock) then th.Sock.CloseSocket;
    th.WaitFor;
    th.Free;
  end;
  th_list.Free;
  Sock.Free;
  inherited Destroy;
end;

procedure THttpDaemon.Execute;

  procedure InitSocket;
  begin
    Sock.Family:= SF_IP4;
    Sock.CreateSocket();
    if Sock.LastError <> 0 then raise Exception.Create(Sock.LastErrorDesc);
    Sock.SetLinger(True, 10000);
    //Sock.EnableReuse(True);
    Sock.Bind('0.0.0.0', DAEMON_PORT); // ソケット登録
    if Sock.LastError <> 0 then raise Exception.Create(Sock.LastErrorDesc);
    Sock.Listen; // 接続準備
    if Sock.LastError <> 0 then raise Exception.Create(Sock.LastErrorDesc);
  end;

  procedure CleanThreadList;
  var
    th: THttpThrd;
    i: integer;
  begin
    i:= 0;
    while i < th_list.Count do begin
      th:= THttpThrd(th_list[i]);
      if th.Done then begin
        th.Terminate; // 念のため
        th.WaitFor; // 念のため
        th.Free;
        th_list.Delete(i);
      end else
        Inc(i);
    end;
  end;

var
  th: THttpThrd;
  ci: TClientInfo;
  i, c, no_res_count: integer;
  s: string;
begin
  try
    Sock:= TTCPBlockSocket.Create;
    InitSocket;
    SendAliveFlag:= True;
    c:= 0;
    no_res_count:= 0;
    while not Terminated do begin
      if SendAliveFlag then begin
        Inc(c);
        if c mod 5 = 0 then SendAlive; // 5秒毎に創出
        if c >= 300 then begin // 5分間が限度
          c:= 0;
          SendAliveFlag:= False;
        end;
      end;

      if Sock.CanRead(1000) then begin
        no_res_count:= 0;
        if Sock.LastError = 0 then begin
          th:= THttpThrd.Create(Sock.Accept); // 接続待機
          th_list.Add(th);

          if SendAliveFlag then begin
            if MyIPAddr = '' then MyIPAddr:= Sock.ResolveName(Sock.LocalName);
            s:= Sock.GetRemoteSinIP;
            if (MyIPAddr <> s) and (s <> '127.0.0.1') then begin
              SendAlive; // 念のため
              c:= 0;
              SendAliveFlag:= False;
            end;
          end;
        end;
      end else begin
        Inc(no_res_count);
        if no_res_count >= 60 then begin
          no_res_count:= 0;
          CleanThreadList;
          if th_list.Count = 0 then begin
            // 60秒間応答がなければソケットを初期化
            Sock.Free;
            Sock:= TTCPBlockSocket.Create;
            InitSocket;
          end;
        end;
      end;

      if th_list.Count > 10 then CleanThreadList; // ごみ処理

      if ClientInfoList.Count > 10 then begin
        // ごみ処理
        i:= 0;
        while i < ClientInfoList.Count do begin
          ci:= TClientInfo(ClientInfoList.Objects[i]);
          if Now - ci.LastAccTime > EncodeTime(6, 0, 0, 0) then begin
            ClientInfoList.Objects[i].Free;
            ClientInfoList.Delete(i);
          end else
            Inc(i);
        end;
      end;
    end;

  except
    on e: Exception do begin
      line:= '*** ERROR HTTPD : ' + e.Message + CRLF + CRLF;
      Synchronize(@AddLog);
    end;
  end;
end;

{ TTCPHttpThrd }

procedure THttpThrd.AddLog;
begin
  if not Assigned(MyApp) then Exit;
  MyApp.AddLog(line);
  line:= '';
end;

constructor THttpThrd.Create(HSock: TSocket);
begin
  Sock:= TTCPBlockSocket.Create;
  Sock.Family:= SF_IP4;
  Sock.Socket:= HSock;
  FreeOnTerminate:= False;
  Priority:= tpNormal;
  inherited Create(False);
end;

destructor THttpThrd.Destroy;
begin
  Sock.Free;
  inherited Destroy;
end;

procedure THttpThrd.Execute;
const
  TIMEOUT = 10 * 60 * 1000;
var
  s, rcv, cIP: string;
  method, uri, protocol: string;
  size: int64;
  x, i, cPort: integer;
  resultcode: integer;
  close: boolean;
begin
  Sock.SetSendTimeout(TIMEOUT);
  try
    Done:= False;
    L_S:= lua_newstate(@alloc, nil);
    Headers:= TStringListUTF8_mod.Create;
    InputData:= TMemoryStream.Create;
    OutputData:= TMemoryStream.Create;
    try
      cIP:= Sock.GetRemoteSinIP;
      cPort:= Sock.GetRemoteSinPort;
      line:= GetLineHeader + Format('%s:%d Connected. (ID=%d)',
       [cIP, cPort, Self.FThreadID]) + CRLF + CRLF;

      i:= ClientInfoList.IndexOf(cIP);
      if i < 0 then begin
        ClientInfo:= TClientInfo.Create;
        ClientInfoList.AddObject(cIP, ClientInfo);
      end else
        ClientInfo:= TClientInfo(ClientInfoList.Objects[i]);
      ClientInfo.LastAccTime:= Now;

      InitLua(L_S);
      LoadLua(L_S, 'common');
      CallLua(L_S, 0, 0);

      repeat
        if Terminated then Break;
        try
          //read request header
          line:= line + GetLineHeader + Format('%s:%d Read Request.',
           [cIP, cPort]) + CRLF + CRLF;
          rcv:= '';
          size := -1;
          close := false;
          repeat
            s:= Sock.RecvString(TIMEOUT);
            if Sock.LastError <> 0 then Exit;
            if (s = '') or not (s[1] in [' ', #$09]) then
              rcv:= rcv + s + CR
            else
              rcv:= Copy(rcv, 1, Length(rcv)-1) + TrimLeft(s) + CR;

            if Pos('CONTENT-LENGTH:', Uppercase(s)) = 1 then
              size:= StrToInt64Def(SeparateRight(s, ' '), -1);
            if Pos('CONNECTION: CLOSE', Uppercase(s)) = 1 then
              close:= true;
            line:= line + s + CRLF;
          until s = '';

          InHeader:= rcv;
          method:= fetch(InHeader, ' ');
          if (InHeader = '') or (method = '') then Exit;
          uri:= fetch(InHeader, ' ');
          if uri = '' then Exit;
          protocol:= fetch(InHeader, CR);
          if Pos('HTTP/', protocol) <> 1 then Exit;
          if Pos('HTTP/1.1', protocol) <> 1 then close := true;

          if (uri = '/desc.xml') or (ClientInfo.ScriptFileName = '') then begin
            lua_getfield(L_S, LUA_GLOBALSINDEX, 'GetScriptFileName');
            lua_pushstring(L_S, InHeader);
            lua_pushstring(L_S, Sock.GetRemoteSinIP);
            lua_pushstring(L_S, uri);
            CallLua(L_S, 3, 1);
            ClientInfo.ScriptFileName:= lua_tostring(L_S, -1);
            lua_pop(L_S, 1);

            if ClientInfo.ScriptFileName <> '' then
              line:= line + '*** ScriptName = ' + ClientInfo.ScriptFileName + CRLF + CRLF;
          end;

          if ClientInfo.ScriptFileName <> '' then begin
            LoadLua(L_S, ClientInfo.ScriptFileName);
            CallLua(L_S, 0, 0);
          end;

          //recv document...
          InputData.Clear;
          if size >= 0 then begin
            if Terminated then Break;
            InputData.SetSize(Size);
            x:= Sock.RecvBufferEx(InputData.Memory, size, TIMEOUT);
            InputData.SetSize(x);
            if Sock.LastError <> 0 then Exit;

            SetLength(s, x);
            strlcopy(PChar(s), InputData.Memory, x);
            line:= line + s + CRLF + CRLF;
          end;

          if Terminated then Break;

          line:= line + GetLineHeader + Format('%s:%d Sent Response.',
           [cIP, cPort]) + CRLF + CRLF;

          UniOutput:= False;
          Headers.Clear;
          OutputData.Clear;
          ResultCode:= ProcessHttpRequest(method, uri);
          if UniOutput = False then begin
            s:= protocol + ' ' + IntTostr(ResultCode);
            case ResultCode of
              200: s:= s + ' OK';
              404: s:= s + ' Not Found';
              406: s:= s + ' Not Acceptable';
              //500: s:= s + ' Internal Server Error';
            end;

            s:= s + CRLF;
            if Terminated then Break;
            sock.SendString(s);
            if Sock.LastError <> 0 then Exit;
            line:= line + s;
            if protocol <> '' then begin
              if close then
                Headers.Add('Connection: close')
              else
                Headers.Add('Connection: Keep-Alive');
              Headers.Add('Content-Length: ' + IntTostr(OutputData.Size));
              Headers.Add('Date: ' + Rfc822DateTime(now));
              Headers.Add('Server: ' + HTTP_HEAD_SERVER);
              Headers.Add('');
              for i:= 0 to Headers.Count - 1 do begin
                if Terminated then Break;
                Sock.SendString(Headers[i] + CRLF);
                if Sock.LastError <> 0 then Exit;
                line:= line + Headers[i] + CRLF;
              end;
              if UpperCase(protocol) = 'HEAD' then OutputData.Clear;
            end;

            if Terminated then Break;
            Sock.SendBuffer(OutputData.Memory, OutputData.Size);
          end;

          if close then Break;
        finally
          if line <> '' then Synchronize(@AddLog);
        end;
      until Sock.LastError <> 0;
    finally
      s:= '';
      if Sock.LastError <> 0 then s:= ', ' + Sock.LastErrorDesc;
      line:= GetLineHeader + Format('%s:%d Disconnected. (ID=%d%s)',
       [cIP, cPort, Self.FThreadID, s]) + CRLF + CRLF;
      Synchronize(@AddLog);

      lua_close(L_S);
      FreeAndNil(Sock); //
      Headers.Free;
      InputData.Free;
      OutputData.Free;
      line:= '';
      InHeader:= '';
      Done:= True;
    end;
  except
    on e: Exception do begin
      line:= line + '*** ERROR HTTPT: ' + e.Message + CRLF + CRLF;
      Synchronize(@AddLog);
    end;
  end;
end;

function THttpThrd.ProcessHttpRequest(const request, uri: string): integer;
var
  doc, doc2: TXMLDocument;
  parent, item, val: TDOMNode;
  s: string;
  i, c: integer;
begin
  Result:= 404;
  if (request = 'GET') or (request = 'HEAD') then begin
    if uri = '/desc.xml' then begin
      Headers.Clear;
      Headers.Add('Content-Type: text/xml; charset="utf-8"');
      Headers.Add('Cache-Control: no-cache');
      //Headers.Add('Expires: 0');
      Headers.Add('Accept-Ranges: bytes');

      s:= ExecPath + 'data_user/desc.xml';
      if not FileExistsUTF8(s) then s:= ExecPath + 'data/desc.xml';
      readXMLFile(doc, {UTF8FILENAME}UTF8ToSys(s));
      try
        item:= doc.DocumentElement.FindNode('URLBase');
        if item = nil then Exit;
        item.TextContent:= 'http://' +  MyIPAddr + ':' + DAEMON_PORT + '/';

        item:= doc.DocumentElement.FindNode('device');
        if item = nil then Exit;
        val:= item.FindNode('friendlyName');
        if val = nil then Exit;
        s:= iniFile.ReadString(INI_SEC_SYSTEM, 'SERVER_NAME', SHORT_APP_NAME + ' : %LOCALNAME%');
        s:= StringReplace(s, '%LOCALNAME%', Sock.LocalName, [rfReplaceAll, rfIgnoreCase]);
        val.TextContent:= UTF8Decode(s);

        val:= item.FindNode('UDN');
        if val = nil then Exit;
        val.TextContent:= 'uuid:' + UUID;

        {
        val:= item.FindNode('presentationURL');
        if val = nil then Exit;
        val.TextContent:= 'http://' + MyIPAddr + ':' + DAEMON_PORT + '/index.html';
        }

        writeXMLFile(doc, OutputData);
      finally
        doc.Free;
      end;

      Result:= 200;

    end else if (uri = '/UPnP_AV_ContentDirectory_1.0.xml') or
     (uri = '/UPnP_AV_ConnectionManager_1.0.xml') then begin
      Headers.Clear;
      Headers.Add('Content-Type: text/xml; charset="utf-8"');
      Headers.Add('Cache-Control: no-cache');
      //Headers.Add('Expires: 0');
      Headers.Add('Accept-Ranges: bytes');

      s:= ExecPath + 'data_user' + uri;
      if not FileExistsUTF8(s) then s:= ExecPath + 'data' + uri;
      readXMLFile(doc, {UTF8FILENAME}UTF8ToSys(s));
      try
        writeXMLFile(doc, OutputData);
      finally
        doc.Free;
      end;

      Result:= 200;

    end else if (uri = '/images/icon-256.png') then begin
      Headers.Clear;
      Headers.Add('Content-Type: image/png');
      Headers.Add('Accept-Ranges: bytes');
      //Headers.Add('Expires: 0');

      try
        OutputData.LoadFromFile({UTF8FILENAME}UTF8ToSys(ExecPath + 'data/' +
         iniFile.ReadString(INI_SEC_SYSTEM, 'ICON_IMAGE', 'icon.png')));
        Result:= 200;
      except
        OutputData.LoadFromFile({UTF8FILENAME}UTF8ToSys(ExecPath + 'DATA/icon.png'));
        Result:= 200;
      end;
    end else if Copy(uri, 1, 11) = '/playmedia/' then begin
      if ClientInfo.ScriptFileName = '' then Exit;
      Headers.Clear;

      //s:= DecodeTriplet(Copy(uri, 12, Length(uri)), '%');
      s:= DecodeX(Copy(uri, 12, Length(uri)));
      if not FileExistsUTF8(s) then Exit;
      if not DoPlay(s, request) then Exit;

      Result:= 200;
    end else if Copy(uri, 1, 12) = '/playmedia2/' then begin
      if ClientInfo.ScriptFileName = '' then Exit;
      Headers.Clear;

      //s:= DecodeTriplet(Copy(uri, 13, Length(uri)), '%');
      s:= DecodeX(Copy(uri, 13, Length(uri)));
      i:= StrToInt(Fetch(s, #$09));
      if not FileExistsUTF8(s) then Exit;
      if not DoPlayTranscode(i, s, request) then Exit;

      Result:= 200;
    end;

  end else if request = 'POST' then begin
    if ClientInfo.ScriptFileName = '' then Exit;
    if uri = '/upnp/control/content_directory' then begin
      Headers.Clear;
      Headers.Add('Content-Type: text/xml; charset="utf-8"');

      doc:= TXMLDocument.Create;
      readXMLFile(doc2, InputData);
      try
        //doc.Encoding:= 'utf-8';
        item:= doc.CreateElement('s:Envelope');
        TDOMElement(item).SetAttribute(
         'xmlns:s', 'http://schemas.xmlsoap.org/soap/envelope/');
        TDOMElement(item).SetAttribute(
         's:encodingStyle', 'http://schemas.xmlsoap.org/soap/encoding/');
        doc.AppendChild(item);

        parent:= item; // >
        item:= doc.CreateElement('s:Body');
        parent.AppendChild(item);

        val:= doc2.DocumentElement.FindNode('s:Body');
        if val = nil then Exit;
        s:= val.ChildNodes.Item[0].NodeName;

        if s = 'u:GetSortCapabilities' then begin
          parent:= item; // >
          item:= doc.CreateElement('u:GetSortCapabilitiesResponse');
          TDOMElement(item).SetAttribute(
           'xmlns:u', 'urn:schemas-upnp-org:service:ContentDirectory:1');
          parent.AppendChild(item);

          parent:= item; // >
          item:= doc.CreateElement('SortCaps');
          parent.AppendChild(item);

        end else if s = 'u:Browse' then begin
          DoBrowse(doc2, doc);
        end;

        writeXMLFile(doc, OutputData);
      finally
        doc.Free;
        doc2.Free;
      end;
      Result:= 200;

    end else if uri = '/upnp/control/connection_manager' then begin
      Headers.Clear;
      Headers.Add('Content-Type: text/xml; charset="utf-8"');

      doc:= TXMLDocument.Create;
      try
        //doc.Encoding:= 'utf-8';
        item:= doc.CreateElement('s:Envelope');
        TDOMElement(item).SetAttribute(
         'xmlns:s', 'http://schemas.xmlsoap.org/soap/envelope/');
        TDOMElement(item).SetAttribute(
         's:encodingStyle', 'http://schemas.xmlsoap.org/soap/encoding/');
        doc.AppendChild(item);

        parent:= item; // >
        item:= doc.CreateElement('s:Body');
        parent.AppendChild(item);

        parent:= item; // >
        item:= doc.CreateElement('u:GetProtocolInfoResponse');
        TDOMElement(item).SetAttribute(
         'xmlns:u', 'urn:schemas-upnp-org:service:ConnectionManager:1');
        parent.AppendChild(item);

        parent:= item; // >
        item:= doc.CreateElement('Source');
        parent.AppendChild(item);

        lua_getfield(L_S, LUA_GLOBALSINDEX, 'SUPPORT_MEDIA_LIST');
        c:= lua_objlen(L_S, -1);
        s:= '';
        for i:= 1 to c do begin
          lua_pushnumber(L_S, i);
          lua_gettable(L_S, -2);
          if s <> '' then s:= s + ',';
          s:= s + 'http-get:*:' + lua_tostring(L_S, -1);
          lua_pop(L_S, 1);
        end;
        val:= doc.CreateTextNode(s);
        item.AppendChild(val);

        item:= doc.CreateElement('Sink');
        parent.AppendChild(item);

        writeXMLFile(doc, OutputData);
      finally
        doc.Free;
      end;

      Result:= 200;

    end;
  end;
end;

function THttpThrd.DoGetTranscodeCommand(const fname: string): string;

  procedure sub(L: Plua_State);
  var
    mi: TGetMediaInfo;
    i: integer;
  begin
    lua_pushstring(L, fname); // fname
    mi:= thMIC.GetMediaInfo(fname);
    try
      lua_newtable(L);             // minfo
      for i:= 0 to mi.Count-1 do begin
        MIValue2LuaTable(L, mi[i]);
      end;
      lua_pushstring(L, ClientInfo.ScriptFileName); // ScriptFileName
      CallLua(L, 3, 1);
    finally
      if mi.IsTemp then mi.Free;
    end;
  end;

var
  b: boolean;
begin
  if FileExistsUTF8(fname + '.lua') then begin
    LoadLua(L_S, fname + '.lua', '$$__file_module__$$');
    CallLua(L_S, 0, 0);
  end;
  if FileExistsUTF8(ExtractFilePath(fname) + '$.lua') then begin
    LoadLua(L_S, ExtractFilePath(fname) + '$.lua', '$$__dir_module__$$');
    CallLua(L_S, 0, 0);
  end;

  lua_getfield(L_S, LUA_GLOBALSINDEX, '$$__file_module__$$');
  b:= lua_isnil(L_S, -1);
  if not b then begin
    lua_getfield(L_S, -1, 'GetTranscodeCommand');
    b:= lua_isnil(L_S, -1);
    if not b then begin
      sub(L_S);
      b:= lua_isnil(L_S, -1);
      if not b then Result:= lua_tostring(L_S, -1);
      lua_pop(L_S, 1);
    end else
      lua_pop(L_S, 1);
  end;
  lua_pop(L_S, 1);

  if b then begin
    lua_getfield(L_S, LUA_GLOBALSINDEX, '$$__dir_module__$$');
    b:= lua_isnil(L_S, -1);
    if not b then begin
      lua_getfield(L_S, -1, 'GetTranscodeCommand');
      b:= lua_isnil(L_S, -1);
      if not b then begin
        sub(L_S);
        b:= lua_isnil(L_S, -1);
        if not b then Result:= lua_tostring(L_S, -1);
        lua_pop(L_S, 1);
      end else
        lua_pop(L_S, 1);
    end;
    lua_pop(L_S, 1);
  end;

  if b then begin
    lua_getfield(L_S, LUA_GLOBALSINDEX, 'GetTranscodeCommand');
    sub(L_S);
    Result:= lua_tostring(L_S, -1);
    lua_pop(L_S, 2);
  end;
end;

function THttpThrd.DoBrowse(docr, docw: TXMLDocument): boolean;
var
  si, rc: integer;

  procedure GetFileList(const dir: string; sl: TStringList);
  var
    info: TSearchRec;
    sl2: TStringListUTF8;
    s, s2: string;
    i: integer;
    b: boolean;
  begin
    sl.Clear;
    if FileExistsUTF8(dir) then begin
      s:= LowerCase(ExtractFileExt(dir));
      if (s = '.m3u') or (s = '.m3u8') then begin
        // m3u
        sl.Sorted:= False;
        sl2:= TStringListUTF8_mod.Create;
        try
          sl2.LoadFromFile(dir);
          b:= (sl.Count > 0) and (Length(sl[0]) >= 3) and
            (sl[0][1] = #$EF) and (sl[0][2] = #$BB) and (sl[0][3] = #$BF);
          if b then sl2[0]:= Copy(sl2[0], 4, MaxInt);
          b:= b or (s = '.m3u8');
          SetCurrentDirUTF8(ExtractFilePath(dir));
          for i:= 0 to sl2.Count-1 do begin
            s2:= Trim(sl2[i]);
            if (s2 <> '') and (s2 <> '#EXTM3U') and
             (Pos('#EXTINF:', s2) = 0) then begin

              if b then
                s2:= ExpandFileNameUTF8(s2)
              else
                s2:= AnsiToUTF8(ExpandFileName(s2));

              if DirectoryExistsUTF8(s2) then begin
                sl.Add(#2 + IncludeTrailingPathDelimiter(s2));
              end else begin
                s:= LowerCase(ExtractFileExt(s2));
                if (s = '.m3u') or (s = '.m3u8') then begin
                  sl.Add(#3 + s2);
                end else begin
                  sl.Add(#$F + s2);
                end;
              end;
            end;
          end;
        finally
          sl2.Free;
        end;
      end;
    end else begin
      sl.Sorted:= True;
      sl.Duplicates:= dupAccept;
      if FindFirstUTF8(dir+'*', faAnyFile, info) = 0 then
        try
          repeat
            if (info.Name <> '.') and (info.Name <> '..') and
             (info.Attr and faHidden = 0) then begin
              if info.Attr and faDirectory <> 0 then begin
                sl.Add(#2 + dir + info.Name + DirectorySeparator);
              end else begin
                s:= LowerCase(ExtractFileExt(info.Name));
                if (s = '.m3u') or (s = '.m3u8') then begin
                  sl.Add(#3 + dir + info.Name);
                end else if (s <> '.lua') and (s <> '.txt') then begin
                  sl.Add(#$F + dir + info.Name);
                end;
              end;
            end;
          until FindNextUTF8(info) <> 0;
        finally
          FindCloseUTF8(Info);
        end;
    end;
  end;

  procedure GetListInTrans(const dir: string; sl: TStringList);
  var
    ini: TIniFile;
    sl2, sl3: TStringListUTF8;
    i: integer;
    s: string;
    stream: TStringStream;
  begin
    sl.Clear;
    if FileExistsUTF8(dir) then begin
      // TRANSCODE
      sl.Sorted:= False;
      try
        stream:= TStringStream.Create(DoGetTranscodeCommand(dir));
      except
        Exit;
      end;
      try
        ini:= TIniFile.Create(stream);
        sl2:= TStringListUTF8_mod.Create;
        try
          ini.ReadSections(sl2);
          for i:= 0 to sl2.Count-1 do begin
            s:= StringReplace(sl2[i], '$_name_$',
             ChangeFileExt(ExtractFileName(dir), ''), [rfReplaceAll]);
            sl3:= TStringListUTF8_mod.Create;
            try
              ini.ReadSectionRaw(sl2[i], sl3);
              sl.Add(#5 + StringReplace(sl3.Text, CRLF, ' ', [rfReplaceAll]) +
               #9 + s + #$09 + IntToStr(i) + #$09 + dir);
            finally
              sl3.Free;
            end;
          end;
        finally
          sl2.Free;
          ini.Free;
        end;
      finally
        stream.Free;
      end;
    end;
  end;

  procedure CleanMediaList(sl: TStringList; IsTrans: integer);
  var
    i, c, cc: integer;
    mi: TGetMediaInfo;
    s: String;
    b: boolean;
  begin
    if isTrans >= 0 then begin
      cc:= sl.Count;
      i:= 0;
    end else begin
      cc:= sl.Count;
      if cc > rc then cc:= rc;
      if (MAX_REQUEST_COUNT > 0) and (cc > MAX_REQUEST_COUNT) then cc:= MAX_REQUEST_COUNT;
      i:= si;
      if i > ClientInfo.FullInfoCount then i:= ClientInfo.FullInfoCount;
    end;

    c:= 0;
    while (c < cc) and (i < sl.Count) do begin
      if (sl[i][1] = #$F) and (i >= ClientInfo.FullInfoCount) then begin
        mi:= thMIC.GetMediaInfo(Copy(sl[i], 2, MaxInt));
        try
          s:= mi.GetMimeType(L_S, ClientInfo.ScriptFileName, True);
          if s <> '' then begin
            if Pos(':::TRANS:::', s) > 0 then begin
              if sl.Sorted then begin
                s:= sl[i];
                sl.Delete(i);
                sl.Add(s + '?');
              end else begin
                sl[i]:= sl[i] + '?';
              end;
            end;
          end else begin
            b:= i = sl.Count - 1;
            sl.Delete(i);
            if b then i:= sl.Count;
            Continue;
          end;
        finally
          if mi.IsTemp then mi.Free;
        end;
      end;

      if i = IsTrans then begin
        GetListInTrans(Copy(sl[i], 2, Length(sl[i])-2), sl);
        ClientInfo.FullInfoCount:= sl.Count;
        Exit;
      end;

      if i >= si then Inc(c);
      Inc(i);
    end;

    if IsTrans >= 0 then begin
      // ERROR
      sl.Clear;
    end else begin
      if i > ClientInfo.FullInfoCount then ClientInfo.FullInfoCount:= i;
    end;
  end;

var
  parent, item, val: TDOMNode;
  mlist: TStringList;
  i, j, c, IsTransDir: integer;
  i64: int64;
  r, s, s1, fn, m, mt, id, param, cmd, dur: String;
  mi: TGetMediaInfo;
begin
  { <ObjectID>0</ObjectID>
   <BrowseFlag>BrowseDirectChildren</BrowseFlag>
   <Filter>
    dc:title,
    av:mediaClass,
    dc:date,
    @childCount,
    res,
    upnp:class,
    res@resolution,upnp:album,upnp:albumArtURI,upnp:albumArtURI@dlna:profileID,dc:creator,res@size,res@duration,res@bitrate,res@protocolInfo
    </Filter>
    <StartingIndex>0</StartingIndex>
    <RequestedCount>10</RequestedCount>
    <SortCriteria></SortCriteria>
  }

  Result:= False;

  item:= docr.DocumentElement.FindNode('s:Body');
  if item = nil then Exit;
  item:= item.FindNode('u:Browse');
  if item = nil then Exit;
  val:= item.FindNode('ObjectID');
  if val = nil then Exit;
  id:= val.TextContent;
  val:= item.FindNode('StartingIndex');
  if val = nil then Exit;
  si:= StrToIntDef(val.TextContent, 0);
  val:= item.FindNode('RequestedCount');
  if val = nil then Exit;
  rc:= StrToIntDef(val.TextContent, MaxInt);

  parent:= docw.DocumentElement.FindNode('s:Body');
  item:= docw.CreateElement('u:BrowseResponse');
  TDOMElement(item).SetAttribute(
   'xmlns:u', 'urn:schemas-upnp-org:service:ContentDirectory:1');
  parent.AppendChild(item);

  parent:= item; // >
  item:= docw.CreateElement('Result');
  parent.AppendChild(item);

  ClientInfo:= TClientInfo(ClientInfoList.Objects[
   ClientInfoList.IndexOf(Sock.GetRemoteSinIP)]);
  mlist:= ClientInfo.CurFileList;
  if id = '0' then begin
    ClientInfo.CurId:= id; ClientInfo.CurDir:= '';
    mlist.Clear;
    mlist.Sorted:= False;
    if MediaDirs.Count = 0 then begin
      mlist.Add(#1 + SHORT_APP_NAME + 'からのお知らせ: [MediaDirs]が未設定です');
    //end else if (thMIC.mi_list.Count < 100) and not thMIC.Suspended then begin
    //  for i:= 0 to MediaDirs.Count-1 do begin
    //    mlist.Add(#1 + 'メディア情報を収集中です。少しお待ちください');
    //  end;
    end else begin
      for i:= 0 to MediaDirs.Count-1 do begin
        mlist.Add(#1 + MediaDirs.Names[i]);
      end;
    end;
  end else begin
    IsTransDir:= -1;
    if ClientInfo.CurId <> id then begin
      s:= id;
      Fetch(s, '$');
      if s = '' then Exit;
      i:= StrToInt(Fetch(s, '$'));
      s1:= IncludeTrailingPathDelimiter(MediaDirs.ValueFromIndex[i]);
      GetFileList(s1, mlist);
      while s <> '' do begin
        i:= StrToInt(Fetch(s, '$'));
        if i >= mlist.Count then begin
          // ERROR
          mlist.Clear;
          Break;
        end;
        if mlist[i][1] = #$F then begin
          IsTransDir:= i;
          Break;
        end;
        s1:= Copy(mlist[i], 2, MaxInt);
        GetFileList(s1, mlist);
      end;
      ClientInfo.CurId:= id; ClientInfo.CurDir:= s1; ClientInfo.FullInfoCount:= 0;
    end;
    CleanMediaList(mlist, IsTransDir);
  end;

  c:= mlist.Count;
  if c > rc then c:= rc;
  if (MAX_REQUEST_COUNT > 0) and (c > MAX_REQUEST_COUNT) then c:= MAX_REQUEST_COUNT;
  if si + c > mlist.Count then c:= mlist.Count - si;

  r:= '<DIDL-Lite'+
  ' xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"'+
  ' xmlns:dc="http://purl.org/dc/elements/1.1/"'+
  ' xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">';

  for i:= si to si+c-1 do begin
    fn:= mlist[i];
    case fn[1] of
      #1, #2, #3: begin
        s:= Copy(fn, 2, MaxInt);
        if fn[1] <> #1 then
          s:= ExtractFileName(ExcludeTrailingPathDelimiter(s));
        s:= StringReplace(s, '&', '&amp;', [rfReplaceAll]);
        s:= '&lt; ' + s + ' &gt;';
        r:= r +
         '<container id="' + id + '$' + IntToStr(i) + '" childCount="0"' +
         ' parentID="' + id + '" restricted="true">' +
         '<dc:title>' + s + '</dc:title><dc:date>0000-00-00T00:00:00</dc:date>'+
         '<upnp:class>object.container.storageFolder</upnp:class>'+
         '</container>';
      end;

      #5: begin
        param:= Copy(fn, 2, MaxInt);
        cmd:= Fetch(param, #$09);
        s1:= Fetch(param, #$09);
        fn:= param;
        Fetch(fn, #$09);
        mi:= thMIC.GetMediaInfo(fn);
        try
          mt:= mi.GetMimeType(L_S, ClientInfo.ScriptFileName);
          mt:= Fetch(mt, ':::');

          m:= ' protocolInfo="http-get:*:' + mt + '"';

          dur:= '';
          if mi.Values['General;Format'] = 'ISO DVD' then begin
            j:= Pos('dvd://', cmd);
            if j > 0 then begin
              s:= Copy(cmd, j+6, MaxInt);
              s:= Fetch(s, ' ');
              if s = '$_longest_$' then begin
                s:= mi.Values['DVD;LONGEST'];
              end;
              s:= mi.Values['DVD;LENGTH' + IntToStr(StrToInt(s))];
              if s <> '' then dur:= SeekTimeNum2Str(SeekTimeStr2Num(s));
            end;
          end else
            dur:= mi.Values['General;Duration'];

          if dur <> '' then
            m:= m + ' duration="' + dur + '"';

          r:= r +
           '<item id="' + id + '$' + IntToStr(i) + '"' +
           ' parentID="' + id + '" restricted="true">' +
           '<dc:title>' + StringReplace(s1, '&', '&amp;', [rfReplaceAll]) + '</dc:title>' +
           '<res xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/"'+
           m + '>' +
           'http://' + MyIPAddr + ':' + DAEMON_PORT + '/playmedia2/' +
           //EncodeTriplet(param, '%', URLSpecialChar + URLFullSpecialChar) +
           EncodeX(param) +
           '</res>';

          s:= mi.Values['General;File_Created_Date_Local'];
          if s <> '' then begin
            r:= r + '<dc:date>' + Fetch(s, ' ') + 'T' + Copy(s, 1, 8) + '</dc:date>';
          end else
            r:= r + '<dc:date>0000-00-00T00:00:00</dc:date>';

          s:= mt;
          s:= Fetch(s, '/');
          if s = 'audio' then begin
            r:= r + '<upnp:class>object.item.audioItem.musicTrack</upnp:class>';
          end else if s = 'image' then begin
            r:= r + '<upnp:class>object.item.imageItem.photo</upnp:class>';
          end else begin
            r:= r + '<upnp:class>object.item.videoItem</upnp:class>';
          end;
          r:= r + '</item>';
        finally
          if mi.IsTemp then mi.Free;
        end;
      end;

      else begin
        fn:= Copy(fn, 2, MaxInt);
        if fn[Length(fn)] = '?' then begin
          // TRANSCODE
          s:= Copy(fn, 1, Length(fn)-1);
          s:= ExtractFileName(ExcludeTrailingPathDelimiter(s));
          s:= StringReplace(s, '&', '&amp;', [rfReplaceAll]);
          s:= '/ ' + s;
          r:= r +
           '<container id="' + id + '$' + IntToStr(i) + '" childCount="0"' +
           ' parentID="' + id + '" restricted="true">' +
           '<dc:title>' + s + '</dc:title><dc:date>0000-00-00T00:00:00</dc:date>'+
           '<upnp:class>object.container.storageFolder</upnp:class>'+
           '</container>';
        end else begin

          mi:= thMIC.GetMediaInfo(fn);
          try
            mt:= mi.GetMimeType(L_S, ClientInfo.ScriptFileName);
            mt:= Fetch(mt, ':::');

            m:= ' protocolInfo="http-get:*:';
            if mt <> '' then
              m:= m + mt
            else
              m:= m + 'text/plain:*';
            m:= m + '"';

            i64:= mi.FileSize;
            if i64 > 0 then
              m:= m + ' size="' + IntToStr(i64) + '"';

            s:= mi.Values['General;Duration'];
            if s <> '' then
              m:= m + ' duration="' + s + '"';

            s:= mi.Values['Video;Width'];
            if s <> '' then
              m:= m + ' resolution="' + s + 'x' + mi.Values['Video;Height'] + '"';

            s:= mi.Values['Audio;Channels'];
            if s <> '' then
              m:= m + ' nrAudioChannels="' + s + '"';

            s:= mi.Values['Audio;BitRate'];
            if s <> '' then
              m:= m + ' bitrate="' + s + '"';

            s:= mi.Values['Audio;SamplingRate'];
            if s <> '' then
              m:= m + ' sampleFrequency="' + s + '"';

            s:= ExtractFileName(fn);
            s:= StringReplace(s, '&', '&amp;', [rfReplaceAll]);
            if mi.Values['General;Format'] = 'NowRecording' then begin
              s:= '* ' + s;
            end;
            r:= r +
             '<item id="' + id + '$' + IntToStr(i) + '"' +
             ' parentID="' + id + '" restricted="true">' +
             '<dc:title>' + s + '</dc:title>' +
             '<res xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/"'+
             m + '>' +
             'http://' + MyIPAddr + ':' + DAEMON_PORT + '/playmedia/' +
             //EncodeTriplet(fn, '%', URLSpecialChar + URLFullSpecialChar) +
             EncodeX(fn) +
             '</res>';

            s:= mi.Values['General;File_Created_Date_Local'];
            if s <> '' then begin
              r:= r + '<dc:date>' + Fetch(s, ' ') + 'T' + Copy(s, 1, 8) + '</dc:date>';
            end else
              r:= r + '<dc:date>0000-00-00T00:00:00</dc:date>';

            s:= mt;
            s:= Fetch(s, '/');
            if s = 'audio' then begin
              r:= r + '<upnp:class>object.item.audioItem.musicTrack</upnp:class>';
            end else if s = 'image' then begin
              r:= r + '<upnp:class>object.item.imageItem.photo</upnp:class>';
            end else begin
              r:= r + '<upnp:class>object.item.videoItem</upnp:class>';
              //r:= r+'<av:mediaClass xmlns:av="urn:schemas-sony-com:av">V</av:mediaClass>';
            end;
            r:= r + '</item>';
          finally
            if mi.IsTemp then mi.Free;
          end;
        end;
      end;
    end;
  end;
  r := r + '</DIDL-Lite>';

  val:= docw.CreateTextNode(UTF8Decode(r));
  item.AppendChild(val);

  item:= docw.CreateElement('NumberReturned');
  parent.AppendChild(item);
  val:= docw.CreateTextNode(IntToStr(c));
  item.AppendChild(val);

  item:= docw.CreateElement('TotalMatches');
  parent.AppendChild(item);
  val:= docw.CreateTextNode(IntToStr(mlist.Count));
  item.AppendChild(val);

  item:= docw.CreateElement('UpdateID');
  parent.AppendChild(item);
  val:= docw.CreateTextNode('1');
  item.AppendChild(val);

  Result:= True;
end;

function THttpThrd.SendRaw(buf: Pointer; len: integer): boolean;
var
  x, r: Integer;
begin
  Result:= False;
  x:= 0;
  while not Terminated and (x < len) do begin
    r:= synsock.Send(Sock.Socket, PByte(buf)+x, len-x, MSG_NOSIGNAL);
    Sock.SockCheck(r);
    case Sock.LastError of
      0: Inc(x, r);
      else Exit;
    end;
  end;
  Result:= True;
end;

function THttpThrd.SendRaw(const buf: string): boolean;
begin
  Result:= SendRaw(@buf[1], Length(buf));
end;

function THttpThrd.DoPlay(const fname, request: string): boolean;
const
  OKKAKE_SPACE = 100 * 1024 * 1024;
var
  mi: TGetMediaInfo;
  ct, cf, s, seek1, seek2, dur, ts_range, range: string;
  fs: TFileStreamUTF8;
  h: TStringListUTF8;
  i, buf_size, s_wait: integer;
  nseek1, nseek2, ndur: double;
  iseek1, isize, fsize, range1, range2: Int64;
  buf: PByte;
  now_rec, bTimeSeek, bRange: boolean;
  time1, time2: LongWord;
begin
  Result:= False;
  UniOutput:= True;
  h:= TStringListUTF8.Create;
  mi:= thMIC.GetMediaInfo(fname);
  try
    cf:= mi.GetMimeType(L_S, ClientInfo.ScriptFileName);
    ct:= Fetch(cf, ':');
    cf:= Fetch(cf, ':::');

    now_rec:= mi.Values['General;Format'] = 'NowRecording';
    if now_rec then
      fs:= TFileStreamUTF8.Create(fname, fmOpenRead or fmShareDenyNone)
    else
      fs:= TFileStreamUTF8.Create(fname, fmOpenRead or fmShareDenyWrite);
    try
      fsize:= unit2.GetFileSize(fname){fs.Size};
      iseek1:= 0; isize:= fsize;
      nseek1:= 0; nseek2:= 0;
      dur:= mi.Values['General;Duration'];
      if now_rec then begin
        dur:= '20:00:00.000'; // 20時間のファイルと仮定する
        isize:= 200 * 1024 * 1024 * 1024; // 200GBのファイルと仮定
      end;
      ndur:= SeekTimeStr2Num(dur);
      i:= Pos('TIMESEEKRANGE.DLNA.ORG:', UpperCase(InHeader));
      bTimeSeek:= i > 0;
      if bTimeSeek then begin
        if ndur = 0 then begin
          // TIMESEEKRANGEは使えませんと答える
          // (DLNA Interoperability Guidelines v1.0 - 7.8.22.7)
          Sock.SendString('HTTP/1.1 406 Not Acceptable' + CRLF + CRLF);
          Exit;
        end;
        s:= Copy(InHeader, i+23, Length(InHeader));
        s:= Trim(Fetch(s, CR));
        Fetch(s, '=');
        seek2:= Trim(s);
        seek1:= Fetch(seek2, '-');
        nseek1:= SeekTimeStr2Num(seek1);
        nseek2:= SeekTimeStr2Num(seek2);
        if (nseek1 <> 0) or (nseek2 <> 0) then begin
          if now_rec then begin
            // 録画中のファイルは20Mbpsであると仮定
            iseek1:= Trunc(nseek1 / 1000 * 20 * 1024 * 1024 / 8);
            if nseek2 >= nseek1 then begin
              isize:= Trunc(nseek2 / 1000 * 20 * 1024 * 1024 / 8) - iseek1 + 1;
              if iseek1 + isize + OKKAKE_SPACE > fsize then begin
                iseek1:= fsize - OKKAKE_SPACE - isize;
              end;
            end else begin
              if iseek1 + OKKAKE_SPACE >= fsize then iseek1:= fsize - OKKAKE_SPACE;
            end;
            if iseek1 < 0 then iseek1:= 0;
          end else begin
            iseek1:= Trunc(fsize / ndur * nseek1);
            if nseek2 >= nseek1 then begin
              isize:= Trunc(fsize / ndur * nseek2) - iseek1 + 1;
            end else begin
              isize:= fsize - iseek1;
            end;
          end;
        end;
      end;

      range1:= 0; range2:= fsize - 1;
      i:= Pos('RANGE:', UpperCase(InHeader));
      bRange:= i > 0;
      if bRange then begin
        s:= Copy(InHeader, i+6, Length(InHeader));
        Fetch(s, '=');
        range1:= StrToInt64Def(Fetch(s, '-'), 0);
        iseek1:= range1;
        if now_rec then begin
          if iseek1 + OKKAKE_SPACE >= fsize then iseek1:= fsize - OKKAKE_SPACE;
        end;
        range2:= StrToInt64Def(Fetch(s, CR), fsize-1);
        isize:= range2 - range1 + 1;
      end;

      h.Add('HTTP/1.1 200 OK');
      h.Add('TransferMode.DLNA.ORG: Streaming');
      h.Add('Content-Type: ' + ct);
      h.Add('ContentFeatures.DLNA.ORG: ' + cf);
      h.Add('Accept-Ranges: bytes');
      h.Add('Connection: keep-alive');
      h.Add('Server: ' + HTTP_HEAD_SERVER);
      if now_rec then
        h.Add('Transfer-Encoding: chunked')
      else
        h.Add('Content-length: ' + IntToStr(isize));

      if nseek2 > 0 then
        s:= SeekTimeNum2Str(nseek2)
      else
        s:= SeekTimeNum2Str(ndur);
      ts_range:= SeekTimeNum2Str(nseek1) + '-' + s + '/' + dur;
      range:= Format('%d-%d/%d', [range1, range2, fsize]);
      if bTimeSeek then begin
        //s:= 'npt=' + ts_range + ' bytes=' + range;
        s:= 'npt=' + ts_range;
        h.Add('TimeSeekRange.dlna.org: ' + s);
        h.Add('X-Seek-Range: ' + s);
      end else if bRange then begin
        h.Add('Content-Range: bytes ' + range);
      end;
      h.Add('');
      for i:= 0 to h.Count - 1 do begin
        Sock.SendString(h[i] + CRLF);
        if Sock.LastError <> 0 then Exit;
        Line:= Line + h[i] + CRLF;
      end;
      Line:= Line + CRLF;

      if UpperCase(request) <> 'HEAD' then begin
        Line:= line + GetLineHeader + 'STREAM sent' + CRLF + fname + CRLF + CRLF;
        Synchronize(@AddLog);

        if now_rec then begin
          // 余白分が溜まるまで待つ
          while not Terminated and Sock.CanWrite(1*60*1000) do begin
            fsize:= unit2.GetFileSize(fname);
            if fsize > OKKAKE_SPACE then Break;
            SleepThread(Handle, 100);
          end;
        end;

        s_wait:= iniFile.ReadInteger(INI_SEC_SYSTEM, 'STREAM_WAIT', 0);
        lua_getfield(L_S, LUA_GLOBALSINDEX, 'STREAM_WAIT');
        if lua_isnumber(L_S, -1) then s_wait:= lua_tointeger(L_S, -1);
        lua_pop(L_S, 1);
        if (s_wait < 0) or (s_wait > 10000) then s_wait:= 0;

        time1:= LCLIntf.GetTickCount;
        buf_size:= iniFile.ReadInteger(INI_SEC_SYSTEM, 'STREAM_BUFFER_SIZE', 10);
        if buf_size < 1 then buf_size:= 1;
        if buf_size > 1800 then buf_size:= 1800;
        buf_size:= buf_size * 1024 * 1024;
        buf:= GetMem(buf_size);
        try
          fs.Position:= iseek1;
          while (isize > 0) and not Terminated do begin
            if isize < buf_size then buf_size:= isize;
            i:= fs.Read(buf^, buf_size);
            if i = 0 then begin
              if now_rec then begin
                SleepThread(Handle, 5000);
                i:= fs.Read(buf^, buf_size);
                if i = 0 then begin
                  //Sock.SendString('0' + CRLF + CRLF);
                  SendRaw('0' + CRLF + CRLF);
                  Break; // 5秒待っても増えないのでたぶん録画終了
                end;
              end else
                Break;
            end;
            if now_rec then SendRaw(LowerCase(IntToHex(i, 1)) + CRLF);
            //Sock.SendBuffer(buf, i);
            SendRaw(buf, i);
            if now_rec then SendRaw(CRLF);
            if Sock.LastError <> 0 then Exit;
            time2:= LCLIntf.GetTickCount;
            if (s_wait > 0) and (time2 - time1 < s_wait) then
              SleepThread(Handle, s_wait - (time2 - time1));
            time1:= time2;
            Dec(isize, i);
          end;
        finally
          FreeMem(buf);
        end;

        Line:= GetLineHeader + 'STREAM fin' + CRLF +
         fname + CRLF + CRLF;
      end;
    finally
      fs.Free;
    end;
  finally
    h.Free;
    if mi.IsTemp then mi.Free;
  end;
  Result:= True;
end;

function THttpThrd.DoPlayTranscode(sno: integer; const fname, request: string): boolean;
var
  mi: TGetMediaInfo;
  cmd, exec, tmp_fname, ct, cf, s, seek1, seek2, dur, ts_range, range: string;
  fs: TFileStreamUTF8;
  h, sl: TStringListUTF8;
  i, buf_size, errc, s_wait: integer;
  nseek1, nseek2, ndur: double;
  buf: PByte;
  proc: TProcessUTF8;
  ini: TIniFile;
  stream: TStringStream;
  bTimeSeek, bRange, KeepModeSendOnly: boolean;
  KeepMode: integer;
  range1, range2: Int64;
  time1, time2: LongWord;
  tck_path, tck_ini: string;
begin
  Result:= False;
  UniOutput:= True;
  h:= TStringListUTF8_mod.Create;
  mi:= thMIC.GetMediaInfo(fname);
  try
    sl:= TStringListUTF8_mod.Create;
    try
      stream:= TStringStream.Create(DoGetTranscodeCommand(fname));
      ini:= TIniFile.Create(stream);
      try
        ini.ReadSections(sl);
        ini.ReadSectionRaw(sl[sno], sl); // List index (sno) out of bounds エラーとなる可能性あり
        cmd:= StringReplace(sl.Text, CRLF, ' ', [rfReplaceAll]);
        exec:= Trim(LowerCase(Fetch(cmd, ' ')));
        KeepMode:= 0;
        if (exec <> '') and (exec[1] = '*') then begin
          exec:= Copy(exec, 2, MaxInt);
          if exec = 'keep' then begin
            KeepMode:= 1;
          end else if exec = 'clear' then begin
            KeepMode:= 100;
          end;
          exec:= Trim(LowerCase(Fetch(cmd, ' ')));
        end else begin
          if exec = '' then begin
            // トランスコードをせず通常のストリーミング再生をする
            Result:= DoPlay(fname, request);
            Exit;
          end;
        end;
      finally
        ini.Free;
        stream.Free;
      end;
    finally
      sl.Free;
    end;

    cf:= mi.GetMimeType(L_S, ClientInfo.ScriptFileName);
    ct:= Fetch(cf, ':');
    cf:= Fetch(cf, ':::');
    nseek1:= 0; nseek2:= 0;
    dur:= '';
    if mi.Values['General;Format'] = 'ISO DVD' then begin
      i:= Pos('dvd://', cmd);
      if i > 0 then begin
        s:= Copy(cmd, i+6, MaxInt);
        s:= Fetch(s, ' ');
        if s = '$_longest_$' then begin
          s:= mi.Values['DVD;LONGEST'];
          cmd:= StringReplace(cmd, '$_longest_$', s, [rfReplaceAll]);
        end;
        s:= mi.Values['DVD;LENGTH' + IntToStr(StrToInt(s))];
        if s <> '' then dur:= SeekTimeNum2Str(SeekTimeStr2Num(s));
      end;
    end else begin
      dur:= mi.Values['General;Duration'];
    end;
    if dur = '' then dur:= '20:00:00.000'; // 20時間のファイルと仮定する
    ndur:= SeekTimeStr2Num(dur);
    i:= Pos('TIMESEEKRANGE.DLNA.ORG:', UpperCase(InHeader));
    bTimeSeek:= i > 0;
    if bTimeSeek then begin
      s:= Copy(InHeader, i+23, Length(InHeader));
      s:= Trim(Fetch(s, CR));
      Fetch(s, '=');
      seek2:= Trim(s);
      seek1:= Fetch(seek2, '-');
      nseek1:= SeekTimeStr2Num(seek1);
      nseek2:= SeekTimeStr2Num(seek2);
    end;

    range1:= 0; range2:= -1;
    i:= Pos('RANGE:', UpperCase(InHeader));
    bRange:= i > 0;
    if bRange then begin
      s:= Copy(InHeader, i+6, Length(InHeader));
      Fetch(s, '=');
      range1:= StrToInt64Def(Fetch(s, '-'), 0);
      range2:= StrToInt64Def(Fetch(s, CR), -1);
    end;

    h.Add('HTTP/1.1 200 OK');
    h.Add('TransferMode.DLNA.ORG: Streaming');
    h.Add('Content-Type: ' + ct);
    h.Add('ContentFeatures.DLNA.ORG: ' + cf);
    h.Add('Accept-Ranges: bytes');
    h.Add('Connection: keep-alive');
    h.Add('Server: ' + HTTP_HEAD_SERVER);
    h.Add('Transfer-Encoding: chunked');
    if nseek2 > 0 then
      s:= SeekTimeNum2Str(nseek2)
    else
      s:= SeekTimeNum2Str(ndur);
    ts_range:= SeekTimeNum2Str(nseek1) + '-' + s + '/' + dur;
    if range2 >= 0 then
      range:= Format('%d-%d/*', [range1, range2])
    else
      range:= Format('%d-/*', [range1]);
    if bTimeSeek then begin
      //s:= 'npt=' + ts_range + ' bytes=' + range;
      s:= 'npt=' + ts_range;
      h.Add('TimeSeekRange.dlna.org: ' + s);
      h.Add('X-Seek-Range: ' + s);
    end else if bRange then begin
      h.Add('Content-Range: bytes ' + range);
    end;
    h.Add('');
    for i:= 0 to h.Count - 1 do begin
      Sock.SendString(h[i] + CRLF);
      if Sock.LastError <> 0 then Exit;
      Line:= Line + h[i] + CRLF;
    end;
    Line:= Line + CRLF;

    if UpperCase(request) <> 'HEAD' then begin
      Line:= line + GetLineHeader + 'STREAM sent' + CRLF + fname + CRLF + CRLF;
      Synchronize(@AddLog);

      s_wait:= iniFile.ReadInteger(INI_SEC_SYSTEM, 'STREAM_WAIT', 0);
      lua_getfield(L_S, LUA_GLOBALSINDEX, 'STREAM_WAIT');
      if lua_isnumber(L_S, -1) then s_wait:= lua_tointeger(L_S, -1);
      lua_pop(L_S, 1);
      if (s_wait < 0) or (s_wait > 10000) then s_wait:= 0;

      time1:= LCLIntf.GetTickCount;
      buf_size:= iniFile.ReadInteger(INI_SEC_SYSTEM, 'STREAM_BUFFER_SIZE', 10);
      if buf_size < 1 then buf_size:= 1;
      if buf_size > 1800 then buf_size:= 1800;
      buf_size:= buf_size * 1024 * 1024;
      buf:= GetMem(buf_size);
      try
        tmp_fname:= FileUtil.GetTempFileName(TempPath, '$BMS_TRANS');
        KeepModeSendOnly:= False;
        if KeepMode <> 0 then begin
          tmp_fname:= '';
          tck_path:= iniFile.ReadString(INI_SEC_SYSTEM, 'KEEP_DIR', '');
          if tck_path = '' then tck_path:= ExecPath + 'keep';
          tck_path:= IncludeTrailingPathDelimiter(tck_path);
          if not DirectoryExistsUTF8(tck_path) then
            ForceDirectoriesUTF8(tck_path);
          sl:= TStringListUTF8.Create;
          try
            tck_ini:= tck_path + ExtractFileName(fname) +
             '_' + IntToStr(unit2.GetFileSize(fname)) + '.ini';
            if FileExistsUTF8(tck_ini) then begin
              sl.LoadFromFile(tck_ini);
              i:= 0;
              while i < sl.Count do begin
                if KeepMode = 100 then begin
                  // トランスコファイルの消去
                  DeleteFileUTF8(tck_path + sl[i+1]);
                  if not FileExistsUTF8(tck_path + sl[i+1]) then begin
                    sl.Delete(i);
                    sl.Delete(i);
                    sl.Delete(i);
                  end else
                    Inc(i, 3); // ファイル使用中のため消去できなかった
                end else begin
                  if sl[i] = exec + ' ' + cmd then begin
                    tmp_fname:= tck_path + sl[i+1];
                    KeepModeSendOnly:= unit2.GetFileSize(tmp_fname) > 0;
                    Break;
                  end;
                  Inc(i, 3);
                end;
              end;
            end;

            if KeepMode = 100 then begin
              if sl.Count = 0 then
                DeleteFileUTF8(tck_ini)
              else
                sl.SaveToFile(tck_ini); // ファイル使用中のため消去できなかった
              KeepModeSendOnly:= True;
            end else begin
              if not KeepModeSendOnly and (tmp_fname = '') then begin
                tmp_fname:= FileUtil.GetTempFileName(tck_path,
                 ExtractFileName(fname) + '_' + IntToStr(unit2.GetFileSize(fname)) + '_');
                sl.Add(exec + ' ' + cmd);
                sl.Add(ExtractFileName(tmp_fname));
                sl.Add('');
                sl.SaveToFile(tck_ini);
              end;
            end;
          finally
            sl.Free;
          end;
        end;

        if not KeepModeSendOnly then begin
          proc:= TProcessUTF8.Create(nil);
          try
            cmd:= StringReplace(cmd, '$_in_$', ExtractShortPathNameUTF8(fname), [rfReplaceAll]);
            cmd:= StringReplace(cmd, '$_out_$', tmp_fname, [rfReplaceAll]);
            cmd:= '"' + ExecPath + exec + '" ' + cmd;
            if exec = 'mencoder' then begin
              if bTimeSeek then begin
                if nseek1 <> 0 then begin
                  cmd := cmd + ' -ss ' + SeekTimeNum2Str(nseek1);
                end;
                if (nseek2 > nseek1) then begin
                  cmd := cmd + ' -endpos ' + SeekTimeNum2Str(nseek2-nseek1);
                end;
              end else if bRange then begin
                cmd := cmd + ' -sb ' + IntToStr(range1);
                if range2 >= 0 then begin
                  cmd := cmd + ' -endpos ' + IntToStr(range2-range1+1) + 'b';
                end;
              end;
              cmd:= cmd + ' -quiet';
            end else if exec = 'ffmpeg' then begin
              if bTimeSeek then begin
                if nseek1 <> 0 then begin
                  cmd := cmd + ' -ss ' + SeekTimeNum2Str(nseek1);
                end;
                if (nseek2 > nseek1) then begin
                  cmd := cmd + ' -t ' + SeekTimeNum2Str(nseek2-nseek1);
                end;
              end else if bRange then begin
                // ffmpeg では -sb にあたるのがないので Range Seek　はできなそう
                //cmd := cmd + ' -sb ' + IntToStr(range1);
                //if range2 >= 0 then begin
                //  cmd := cmd + ' -fs ' + IntToStr(range2-range1+1);
                //end;
              end;
              //cmd:= cmd + ' -quiet';
            end;

            Line:= GetLineHeader + 'TRANSCODE ' + exec + CRLF + cmd + CRLF + CRLF;
            Synchronize(@AddLog);

            proc.CommandLine:= cmd;
            proc.Options:= [poNoConsole];
            proc.Execute;
            while proc.Running and not FileExistsUTF8(tmp_fname) do begin
              SleepThread(Handle, 100);
            end;

            if not FileExistsUTF8(tmp_fname) then begin
              // エラーメッセージを取得するためもう一度実行
              proc.Options:= [poUsePipes, poNoConsole];
              proc.Execute;
              while proc.Running do begin
                i:= proc.Output.Read(buf^, 1024);
                if i > 0 then begin
                  buf[i]:= 0;
                  line := line + StrPas(PChar(buf));
                  if Length(line) > 1024 then Synchronize(@AddLog);
                end else begin
                  SleepThread(Handle, 100);
                end;
              end;
              while True do begin
                i:= proc.Output.Read(buf^, 1024);
                if i <= 0 then Break;
                buf[i]:= 0;
                line := StrPas(PChar(buf));
                Synchronize(@AddLog);
              end;
              Exit;
            end;

            fs:= TFileStreamUTF8.Create(tmp_fname, fmOpenRead or fmShareDenyNone);
            try
              errc:= 0;
              while proc.Running do begin
                i:= fs.Read(buf^, buf_size);
                if i <= 0 then begin
                  SleepThread(Handle, 1);
                  Inc(errc);
                end else begin
                  errc:= 0;
                  //Sock.SendString(LowerCase(IntToHex(i, 1)) + CRLF);
                  //Sock.SendBuffer(buf, i);
                  //Sock.SendString(CRLF);
                  SendRaw(LowerCase(IntToHex(i, 1)) + CRLF);
                  SendRaw(buf, i);
                  SendRaw(CRLF);
                  time2:= LCLIntf.GetTickCount;
                  if (s_wait > 0) and (time2 - time1 < s_wait) then
                    SleepThread(Handle, s_wait - (time2 - time1));
                  time1:= time2;
                end;
                if (Sock.LastError <> 0) or (errc > 10000) or Terminated then begin
                  proc.Terminate(-1);
                end;
                if KeepMode = 1 then begin
                  // 送信の優先度は低いので休みながらにして、変換作業を急がせる
                  SleepThread(Handle, 1000);
                end;
              end;
              if not proc.Running then begin
                if KeepMode = 0 then begin
                  while not Terminated do begin
                    i:= fs.Read(buf^, buf_size);
                    if i <= 0 then begin
                      //Sock.SendString('0' + CRLF + CRLF);
                      SendRaw('0' + CRLF + CRLF);
                      Break;
                    end;
                    //Sock.SendString(LowerCase(IntToHex(i, 1)) + CRLF);
                    //Sock.SendBuffer(buf, i);
                    //Sock.SendString(CRLF);
                    SendRaw(LowerCase(IntToHex(i, 1)) + CRLF);
                    SendRaw(buf, i);
                    SendRaw(CRLF);
                    if Sock.LastError <> 0 then Break;
                    time2:= LCLIntf.GetTickCount;
                    if (s_wait > 0) and (time2 - time1 < s_wait) then
                      SleepThread(Handle, s_wait - (time2 - time1));
                    time1:= time2;
                  end;
                end else begin
                  // KeepMode では、トランスコ終了で転送も強制終了
                  SendRaw('0' + CRLF + CRLF);
                end;
              end;
            finally
              fs.Free;
            end;
          finally
            if proc.Running then proc.Terminate(-1);
            proc.Free;
            if (KeepMode = 0) or (Sock.LastError <> 0) then begin
              for i:= 1 to 6 do begin
                if DeleteFileUTF8(tmp_fname) then
                  Break
                else
                  SleepThread(Handle, 10000);
              end;
            end;
            if (KeepMode <> 0) and (Sock.LastError <> 0) then begin
              fs:= TFileStreamUTF8.Create(tmp_fname, fmCreate);  // サイズを0に
              fs.Free;
            end;
          end;
        end else begin
          // KeepModeSendOnly
          if KeepMode = 100 then begin
            s:= 'mpg';
            if ct = 'video/mp4' then s:= 'mp4';
            fs:= TFileStreamUTF8.Create(ExecPath + 'data/clear_fin.' + s, fmOpenRead or fmShareDenyWrite);
          end else
            fs:= TFileStreamUTF8.Create(tmp_fname, fmOpenRead or fmShareDenyWrite);
          try
            while not Terminated do begin
              i:= fs.Read(buf^, buf_size);
              if i <= 0 then begin
                SendRaw('0' + CRLF + CRLF);
                Break;
              end;
              SendRaw(LowerCase(IntToHex(i, 1)) + CRLF);
              SendRaw(buf, i);
              SendRaw(CRLF);
              time2:= LCLIntf.GetTickCount;
              if (s_wait > 0) and (time2 - time1 < s_wait) then
                SleepThread(Handle, s_wait - (time2 - time1));
              time1:= time2;
              if (Sock.LastError <> 0) then Break;
            end;
          finally
            fs.Free;
          end;
        end;
      finally
        FreeMem(buf);
      end;

      Line:= GetLineHeader + 'STREAM fin' + CRLF + fname + CRLF + CRLF;
    end;
  finally
    h.Free;
    if mi.IsTemp then mi.Free;
  end;
  Result:= True;
end;

{ TSSDPDaemon }

constructor TSSDPDaemon.Create;
begin
  Sock:= TUDPBlockSocket.Create;
  Sock.Family:= SF_IP4;
  FreeOnTerminate:= False;
  inherited Create(False);
end;

destructor TSSDPDaemon.Destroy;
begin
  Sock.Free;
  inherited Destroy;
end;

procedure TSSDPDaemon.AddLog;
begin
  if not Assigned(MyApp) then Exit;
  MyApp.AddLog(line);
  line:= '';
end;

procedure TSSDPDaemon.Execute;
var
  sendSock: TUDPBlockSocket;
  s, addr: String;
  L: Plua_State;
begin
  try
    Sock.CreateSocket();
    Sock.EnableReuse(True);
    Sock.Bind('0.0.0.0', '1900'{SSDP});
    if Sock.LastError <> 0 then Raise Exception.Create(Sock.LastErrorDesc);
    Sock.AddMulticast('239.255.255.250');
    if Sock.LastError <> 0 then Raise Exception.Create(Sock.LastErrorDesc);
    if MyIPAddr = '' then MyIPAddr:= Sock.ResolveName(Sock.LocalName);
    L:= lua_newstate(@alloc, nil);
    try
      InitLua(L);
      while not Terminated do begin
        s:= Sock.RecvPacket(1000);
        if Sock.LastError = 0 then  begin
          if Pos('M-SEARCH', s) = 1 then begin
            sendSock:= TUDPBlockSocket.Create;
            try
              try
                sendSock.Family:= SF_IP4;
                sendSock.CreateSocket();
                if sendSock.LastError <> 0 then Raise Exception.Create(sendSock.LastErrorDesc);
                sendSock.Bind('0.0.0.0', '0');
                if sendSock.LastError <> 0 then Raise Exception.Create(sendSock.LastErrorDesc);
                addr:= Sock.GetRemoteSinIP;
                if addr <> MyIPAddr then begin
                  sendSock.Connect(addr, IntToStr(Sock.GetRemoteSinPort));
                  if sendSock.LastError <> 0 then Raise Exception.Create(sendSock.LastErrorDesc);
                  s:=
                   'HTTP/1.1 200 OK' + CRLF +
                   'CACHE-CONTROL: max-age=2100' + CRLF +
                   'DATE: ' + Rfc822DateTime(now) + CRLF +
                   'LOCATION: http://' + MyIPAddr + ':' + DAEMON_PORT +
                     '/desc.xml' + CRLF +
                   'SERVER: ' + HTTP_HEAD_SERVER + CRLF +
                   //'ST: upnp:rootdevice'+ CRLF +
                   'ST: urn:schemas-upnp-org:device:MediaServer:1' + CRLF +
                   'EXT: '+ CRLF +
                   //'USN: uuid:' + clsid + '::upnp:rootdevice' + CRLF +
                   'USN: uuid:' + UUID + '::urn:schemas-upnp-org:device:MediaServer:1' + CRLF +
                   'Content-Length: 0' +
                   CRLF + CRLF;

                  sendSock.SendString(s);
                  if sendSock.LastError <> 0 then Raise Exception.Create(sendSock.LastErrorDesc);
                  line:= GetLineHeader + addr + '  SSDP Sent for M-SEARCH' + CRLF + CRLF;
                  Synchronize(@AddLog);
                end;
              except
                on e: Exception do begin
                  line:= '*** ERROR SSDP Sent: ' + e.Message + CRLF + CRLF;
                  Synchronize(@AddLog);
                end;
              end;
            finally
              sendSock.Free;
            end;
          end;
        end else begin
          if Sock.LastError <> WSAETIMEDOUT then begin
            line:= '*** ERROR SSDP Recv : ' + Sock.LastErrorDesc + CRLF + CRLF;
            Synchronize(@AddLog);
          end;
        end;
      end;
    finally
      lua_close(L);
    end;
  except
    on e: Exception do begin
      line:= '*** ERROR SSDP : ' + e.Message + CRLF + CRLF;
      Synchronize(@AddLog);
    end;
  end;
end;

constructor TMediaInfoCollector.Create;
begin
  mi_list:= TStringListUTF8_mod.Create;
  mi_list.Sorted:= True;
  mi_ac_list:= TStringListUTF8_mod.Create;
  mi_ac_list.Sorted:= True;
  PriorityList:= TStringListUTF8_mod.Create;
  FreeOnTerminate:= False;
  MaxMediaInfo:= iniFile.ReadInteger(INI_SEC_SYSTEM, 'MAX_MEDIAINFO', 500);
  InitCriticalSection(CS_list);
  InitCriticalSection(CS_ac_list);
  InitCriticalSection(CS_pr_list);
  InitCriticalSection(CS_get_mi);
  inherited Create(False);
end;

destructor TMediaInfoCollector.Destroy;
var
  i: Integer;
begin
  for i:= 0 to mi_list.Count-1 do mi_list.Objects[i].Free;
  mi_list.Free;
  mi_ac_list.Free;
  PriorityList.Free;
  DoneCriticalSection(CS_list);
  DoneCriticalSection(CS_ac_list);
  DoneCriticalSection(CS_pr_list);
  DoneCriticalSection(CS_get_mi);
  inherited Destroy;
end;

procedure TMediaInfoCollector.Execute;

  procedure GetFileList(const dir: string; depth: integer; prior:boolean = False);
  var
    info: TSearchRec;
    mi: TGetMediaInfo;
  begin
    if not prior and (mi_list.Count >= MAXMEDIAINFO) then Exit;
    if FindFirstUTF8(dir+'*', faAnyFile, info) = 0 then
      try
        repeat
          if Terminated or (not prior and (PriorityList.Count > 0)) then Break;
          if (info.Name <> '.') and (info.Name <> '..') then begin
            if info.Attr and faDirectory <> 0 then begin
              if depth > 0 then begin
                Dec(depth);
                GetFileList(dir + info.Name + DirectorySeparator, depth);
              end;
            end else begin
              if mi_list.IndexOf(dir + info.Name) < 0 then begin
                EnterCriticalSection(CS_get_mi);
                try
                  mi:= TGetMediaInfo.Create(dir + info.Name, miHandle);
                finally
                  LeaveCriticalSection(CS_get_mi);
                end;
                if mi.Count > 0 then begin
                  EnterCriticalSection(CS_list);
                  try
                    mi_list.AddObject(dir + info.Name, mi);
                    mi.AccTime:= FormatDateTime('yymmddhhnnss', Now);
                    EnterCriticalSection(CS_ac_list);
                    try
                      mi_ac_list.Add(mi.AccTime + dir + info.Name);
                    finally
                      LeaveCriticalSection(CS_ac_list);
                    end;
                  finally
                    LeaveCriticalSection(CS_list);
                  end;
                  if not prior and (mi_list.Count >= MAXMEDIAINFO) then Break;
                end else
                  mi.Free;
              end;
            end;
          end;
        until FindNextUTF8(info) <> 0;
      finally
        FindCloseUTF8(Info);
      end;
  end;

var
  depth, i: Integer;
begin
  while not Terminated do begin
    miHandle:= MediaInfo_New;
    try
      while not Terminated and (PriorityList.Count > 0) do begin
        try
          if PriorityList[0] <> '' then
            GetFileList(PriorityList[0], 0, True);
        finally
          EnterCriticalSection(CS_pr_list);
          try
            PriorityList.Delete(0);
          finally
            LeaveCriticalSection(CS_pr_list);
          end;
        end;
      end;

      // 浅い階層の分を先に収集
      for depth:= 0 to 2 do begin
        for i:= 0 to MediaDirs.Count-1 do begin
          if Terminated or (PriorityList.Count > 0) then Break;
          GetFileList(IncludeTrailingPathDelimiter(MediaDirs.ValueFromIndex[i]), depth);
        end;
      end;
      // 全階層分を収集
      for i:= 0 to MediaDirs.Count-1 do begin
        if Terminated or (PriorityList.Count > 0) then Break;
        GetFileList(IncludeTrailingPathDelimiter(MediaDirs.ValueFromIndex[i]), MaxInt);
      end;
    finally
      MediaInfo_Delete(miHandle);
    end;

    // 古い情報を削除
    while not Terminated and (mi_list.Count > MAXMEDIAINFO) do begin
      EnterCriticalSection(CS_list);
      try
        i:= mi_list.IndexOf(Copy(mi_ac_list[0], 13, MaxInt));
        mi_list.Objects[i].Free;
        mi_list.Delete(i);
      finally
        LeaveCriticalSection(CS_list);
      end;
      EnterCriticalSection(CS_ac_list);
      try
        mi_ac_list.Delete(0);
      finally
        LeaveCriticalSection(CS_ac_list);
      end;
    end;

    // 待機
    if not Terminated and (PriorityList.Count = 0) then Suspended:= True;
    //while not Terminated and (PriorityList.Count = 0) do Sleep(1000); // Best for Linux?
  end;
end;

// 注：他のスレッドからしか呼ばれることはないメソッド
function TMediaInfoCollector.GetMediaInfo(const fname: string): TGetMediaInfo;
var
  i, mi: Integer;
begin
  Result:= nil;

  EnterCriticalSection(CS_list);
  try
    i:= mi_list.IndexOf(fname);
    if i >= 0 then begin
      Result:= TGetMediaInfo(mi_list.Objects[i]);
      if Assigned(Result) and (Result.Count > 0) and
       (Result.Values['General;Format'] <> 'NowRecording') and
       (Result.FileSize = unit2.GetFileSize(fname)) then begin
        EnterCriticalSection(CS_ac_list);
        try
          i:= mi_ac_list.IndexOf(Result.AccTime+fname);
          if i >= 0 then mi_ac_list.Delete(i);
          Result.AccTime:= FormatDateTime('yymmddhhnnss', Now);
          mi_ac_list.Add(Result.AccTime + fname);
        finally
          LeaveCriticalSection(CS_ac_list);
        end;
        Exit;
      end;
    end;
  finally
    LeaveCriticalSection(CS_list);
  end;

  mi:= MediaInfo_New;
  try
    EnterCriticalSection(CS_get_mi);
    try
      Result:= TGetMediaInfo.Create(fname, mi);
    finally
      LeaveCriticalSection(CS_get_mi);
    end;
    Result.IsTemp:= True;
    EnterCriticalSection(CS_pr_list);
    try
      PriorityList.Add(IncludeTrailingPathDelimiter(ExtractFilePath(fname)));
    finally
      LeaveCriticalSection(CS_pr_list);
    end;
    Suspended:= False;
  finally
    MediaInfo_Delete(mi);
  end;
end;

procedure TMediaInfoCollector.ClearMediaInfo;
var
  i: Integer;
begin
  EnterCriticalSection(CS_list);
  try
    for i:= 0 to mi_list.Count-1 do mi_list.Objects[i].Free;
    mi_list.Clear;
  finally
    LeaveCriticalSection(CS_list);
  end;

  EnterCriticalSection(CS_ac_list);
  try
    mi_ac_list.Clear;
  finally
    LeaveCriticalSection(CS_ac_list);
  end;

  EnterCriticalSection(CS_pr_list);
  try
    PriorityList.Add('');
  finally
    LeaveCriticalSection(CS_pr_list);
  end;
  Suspended:= False;
end;

constructor TGetMediaInfo.Create(const fname: string; mi: Cardinal);
begin
  FileName:= fname;
  FileSize:= unit2.GetFileSize(fname);
  GetMediaInfo(fname, mi, Self, ExecPath);
end;

destructor TGetMediaInfo.Destroy;
begin
  inherited Destroy;
end;

function TGetMediaInfo.GetMimeType(L: PLua_State; const scname: string;
  get_new: boolean): string;

  procedure sub(L: PLua_State);
  var
    i: Integer;
  begin
    lua_getfield(L, LUA_GLOBALSINDEX, 'GetMimeType');
    if lua_isnil(L, -1) then Exit;
    lua_pushstring(L, FileName); // fname
    lua_newtable(L);             // minfo
    for i:= 0 to Count-1 do begin
      MIValue2LuaTable(L, Self.Strings[i]);
    end;
    lua_pushstring(L, scname);   // cname
    CallLua(L, 3, 1);
  end;

var
  L2: PLua_State;
  isnil: boolean;
begin
  if not get_new and (MimeType <> '') then begin
    Result:= MimeType;
    Exit;
  end;

  Result:= '';
  if Self.Count = 0 then Exit;

  isnil:= True;
  if FileExistsUTF8(FileName + '.lua') then begin
    L2:= lua_newstate(@alloc, nil);
    try
      InitLua(L2);
      LoadLua(L2, FileName + '.lua');
      CallLua(L2, 0, 0);
      sub(L2);
      isnil:= lua_isnil(L2, -1);
      if not isnil then Result:= lua_tostring(L2, -1);
      lua_pop(L2, 1);
    finally
      lua_close(L2);
    end;
  end;

  if isnil and FileExistsUTF8(ExtractFilePath(FileName) + '$.lua') then begin
    L2:= lua_newstate(@alloc, nil);
    try
      InitLua(L2);
      LoadLua(L2, ExtractFilePath(FileName) + '$.lua');
      CallLua(L2, 0, 0);
      sub(L2);
      isnil:= lua_isnil(L2, -1);
      if not isnil then Result:= lua_tostring(L2, -1);
      lua_pop(L2, 1);
    finally
      lua_close(L2);
    end;
  end;

  if isnil then begin
    sub(L);
    Result:= lua_tostring(L, -1);
    lua_pop(L, 1);
  end;

  MimeType:= Result;
end;

{ TClientInfo }

constructor TClientInfo.Create;
begin
  CurFileList:= TStringListUTF8_mod.Create;
end;

destructor TClientInfo.Destroy;
begin
  CurFileList.Free;
  inherited Destroy;
end;

procedure InitTrayIcon;
var
  p: TPicture;
begin
  p:= TPicture.Create;
  try
    p.LoadFromFile(ExecPath + 'DATA/' +
     iniFile.ReadString(INI_SEC_SYSTEM, 'ICON_IMAGE', 'icon.png'));
    TrayIcon.Icon.Assign(p.Graphic);
    TrayIcon.Show;
  finally
    p.Free;
  end;

  TrayIcon.Hint:= APP_NAME + ' ' + SHORT_APP_VERSION;
  TrayIcon.BalloonTimeout:= MaxInt;
end;

initialization
  ExecPath:= ExtractFilePath(ParamStrUTF8(0));
  iniFile:= TIniFile.Create({UTF8FILENAME}UTF8ToSys(ExecPath + 'bms.ini'));
  TempPath:= iniFile.ReadString(INI_SEC_SYSTEM, 'TEMP_DIR', '');
  if TempPath = '' then TempPath:= ExecPath + 'temp';
  TempPath:= IncludeTrailingPathDelimiter(TempPath);
  MyIPAddr:= '';
  TrayIcon:= TTrayIcon.Create(nil);
  InitTrayIcon;
  MyApp:= TMyApp.Create;
  Application.Title:= APP_NAME + ' ' + APP_VERSION;
finalization
  TrayIcon.OnClick:= nil;
  TrayIcon.PopUpMenu:= nil;
  TrayIcon.BalloonHint:= 'SAYONARA ...';
  TrayIcon.ShowBalloonHint;
  MyApp.Free;
  iniFile.Free;
  TrayIcon.Free;
end.

