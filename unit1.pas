{
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
  APP_VERSION = '1.0.110919';
  SHORT_APP_VERSION = '1.0';

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
  blcksock, synsock, synautil, {synacode,}
  DOM, XMLWrite, XMLRead, MediaInfoDll,
  Lua, lualib, lauxlib,
  {$IFDEF Win32}
  interfacebase, win32int, windows, // for Hook SUSPEND EVENT
  {$ENDIF}
  inifiles, comobj, contnrs, process, utf8process, SynRegExpr,
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
    constructor Create;
    destructor Destroy; override;
    procedure Execute; override;
  end;

  { THttpThrd }

  THttpThrd = class(TThread)
  private
    Sock: TTCPBlockSocket;
    line: string;
    L_S: Plua_State;
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
    InHeader, ScriptFileName: string;
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
    FileName, AccTime: string;
    Locked: boolean;
    constructor Create(const fname: string; mi: Cardinal);
    destructor Destroy; override;
    function GetMimeType(L: PLua_State; const scname: string): string;
  end;

  { TMediaInfoCollector }

  TMediaInfoCollector = class(TThread)
  private
    miHandle: Cardinal;
    mi_list, mi_ac_list: TStringListUTF8;
    MaxMediaInfo: integer;
  public
    cs_list, cs_ac_list, cs_pr_list: TCriticalSection;
    PriorityList: TStringListUTF8;
    constructor Create;
    destructor Destroy; override;
    procedure Execute; override;
    function GetMediaInfo(const fname: string): TGetMediaInfo;
  end;

var
  iniFile: TIniFile;
  ExecPath, TempPath, UUID, DAEMON_PORT: string;
  MyApp: TMyApp;
  thHttpDaemon: THttpDaemon;
  thSSDPDAemon: TSSDPDaemon;
  thMIC: TMediaInfoCollector;
  MediaDirs: TStringListUTF8;

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

procedure InitLua(L: Plua_State);
begin
  luaL_openlibs(L);
  lua_register(L, 'print', @print_func);
  lua_register(L, 'tonumberDef', @tonumberDef_func);
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
  s, myip: string;
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
      myip:= Sock.ResolveName(Sock.LocalName);

      //{
      s:=
       'NOTIFY * HTTP/1.1' + CRLF +
       'HOST: 239.255.255.250:1900'+ CRLF +
       'CACHE-CONTROL: max-age=2100'+ CRLF +
       'LOCATION: http://' + myip + ':' + DAEMON_PORT +
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
       'LOCATION: http://' + myip + ':' + DAEMON_PORT +
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
       'LOCATION: http://' + myip + ':' + DAEMON_PORT +
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
       'LOCATION: http://' + myip + ':' + DAEMON_PORT +
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
       'LOCATION: http://' + myip + ':' + DAEMON_PORT +
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
begin
  UUID:= iniFile.ReadString(INI_SEC_SYSTEM, 'UUID', '');
  if UUID = '' then begin
    UUID:= Copy(CreateClassID, 2, 36);
    iniFile.WriteString(INI_SEC_SYSTEM, 'UUID', UUID);
  end;

  DAEMON_PORT:= iniFile.ReadString(INI_SEC_SYSTEM, 'HTTP_PORT', '5008');
  Log:= TStringListUTF8.Create;

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
  mi.Caption:= '&Quit';
  mi.OnClick:= @OnMenuQuitClick;
  PopupMenu.Items.Add(mi);

  TrayIcon.PopUpMenu := PopupMenu;
  TrayIcon.OnClick:= @MyApp.OnTrayIconClick;

  SendAlive;
end;

destructor TMyApp.Destroy;
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
  Log.Free;
  LogFile.Free;
  MediaDirs.Free;
  while PopupMenu.Items.Count > 0 do begin
    PopupMenu.Items[0].Free;
    PopupMenu.Items.Delete(0);
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
    $0004{PBT_APMSUSPEND}: begin
      MyApp.AddLog('*** GO TO SLEEP...'+CRLF+CRLF);
      SendByebye();
    end;
    $0007{PBT_APMRESUMESUSPEND}: begin
      MyApp.AddLog('*** WAKE UP!!!'+ CRLF+CRLF);
      SendAlive; // alive
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
  Sock:= TTCPBlockSocket.Create;
  Sock.Family:= SF_IP4;
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
var
  th: THttpThrd;
  i: integer;
begin
  try
    Sock.CreateSocket();
    Sock.SetLinger(True, 10000);
    //Sock.EnableReuse(True);
    Sock.Bind('0.0.0.0', DAEMON_PORT); // ソケット登録
    if Sock.LastError <> 0 then raise Exception.Create(Sock.LastErrorDesc);
    Sock.Listen; // 接続準備
    if Sock.LastError <> 0 then raise Exception.Create(Sock.LastErrorDesc);
    while not Terminated do begin
      if Sock.CanRead(1000) then begin
        if Sock.LastError = 0 then begin
          th:= THttpThrd.Create(Sock.Accept); // 接続待機
          th_list.Add(th);
        end;
      end;

      if th_list.Count > 10 then begin
        // ごみ処理
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
    end;
  except
    on e: Exception do begin
      line:= '*** ERROR HTTPD : ' + e.Message + CRLF;
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
    Headers:= TStringListUTF8.Create;
    InputData:= TMemoryStream.Create;
    OutputData:= TMemoryStream.Create;
    try
      cIP:= Sock.GetRemoteSinIP;
      cPort:= Sock.GetRemoteSinPort;
      line:= GetLineHeader + Format('%s:%d Connected. (ID=%d)',
       [cIP, cPort, Self.FThreadID]) + CRLF + CRLF;

      InitLua(L_S);
      LoadLua(L_S, 'common');
      CallLua(L_S, 0, 0);
      repeat
        if Terminated then Break;
        try
          //read request header
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

          lua_getfield(L_S, LUA_GLOBALSINDEX, 'GetScriptFileName');
          lua_pushstring(L_S, InHeader);
          lua_pushstring(L_S, Sock.GetRemoteSinIP);
          lua_pushstring(L_S, Sock.ResolveIPToName(Sock.GetRemoteSinIP));
          CallLua(L_S, 3, 1);
          ScriptFileName:= lua_tostring(L_S, -1);
          lua_pop(L_S, 1);

          if ScriptFileName <> '' then begin
            LoadLua(L_S, ScriptFileName);
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

          UniOutput:= False;
          Headers.Clear;
          OutputData.Clear;
          ResultCode:= ProcessHttpRequest(method, uri);
          if UniOutput = False then begin
            s:= protocol + ' ' + IntTostr(ResultCode);
            case ResultCode of
              200: s:= s + ' OK';
              404: s:= s + ' Not Found';
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
              for i:= 0 to Headers.count - 1 do begin
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
      ScriptFileName:= '';
      Done:= True;
    end;
  except
    on e: Exception do begin
      line:= line + '*** ERROR HTTPT: ' + e.Message + CRLF;
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
        item.TextContent:= 'http://' +
         Sock.ResolveName(Sock.LocalName) + ':' + DAEMON_PORT + '/';

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
        val.TextContent:= 'http://' +
         Sock.ResolveName(Sock.LocalName) + ':' + DAEMON_PORT + '/index.html';
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
      if ScriptFileName = '' then Exit;
      Headers.Clear;

      //s:= DecodeTriplet(Copy(uri, 12, Length(uri)), '%');
      s:= DecodeX(Copy(uri, 12, Length(uri)));
      if not FileExistsUTF8(s) then Exit;
      if not DoPlay(s, request) then Exit;

      Result:= 200;
    end else if Copy(uri, 1, 12) = '/playmedia2/' then begin
      if ScriptFileName = '' then Exit;
      Headers.Clear;

      //s:= DecodeTriplet(Copy(uri, 13, Length(uri)), '%');
      s:= DecodeX(Copy(uri, 13, Length(uri)));
      Fetch(s, #$09);
      if not DoPlayTranscode(StrToInt(Fetch(s, #$09)), s, request) then Exit;

      Result:= 200;
    end;

  end else if request = 'POST' then begin
    if ScriptFileName = '' then Exit;
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
    lua_newtable(L);             // minfo
    for i:= 0 to mi.Count-1 do begin
      MIValue2LuaTable(L, mi[i]);
    end;
    lua_pushstring(L, ScriptFileName); // ScriptFileName
    CallLua(L, 3, 1);
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

  procedure GetFileList(const dir: string; sl: TStringListUTF8; dirOnly: boolean);
  var
    info: TSearchRec;
    ini: TIniFile;
    sl2, sl3: TStringListUTF8;
    i: integer;
    s, s2: string;
    mi: TGetMediaInfo;
    stream: TStringStream;
    b: boolean;
  begin
    sl.Clear;
    if FileExistsUTF8(dir) then begin
      s:= LowerCase(ExtractFileExt(dir));
      if (s = '.m3u') or (s = '.m3u8') then begin
        // m3u
        sl.Sorted:= False;
        sl2:= TStringListUTF8.Create;
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
                  mi:= thMIC.GetMediaInfo(s2);
                  if Assigned(mi) then begin
                    s:= mi.GetMimeType(L_S, ScriptFileName);
                    if s <> '' then begin
                      if Pos(':::TRANS:::', s) > 0 then begin
                        sl.Add(#4 + s2);
                      end else
                        sl.Add(#$FF + s2);
                    end;
                  end;
                end;
              end;
            end;
          end;
        finally
          sl2.Free;
        end;
      end else begin
        // TRANSCODE
        sl.Sorted:= False;
        stream:= TStringStream.Create(DoGetTranscodeCommand(dir));
        ini:= TIniFile.Create(stream);
        sl2:= TStringListUTF8.Create;
        try
          ini.ReadSections(sl2);
          for i:= 0 to sl2.Count-1 do begin
            s:= StringReplace(sl2[i], '$_name_$',
             ChangeFileExt(ExtractFileName(dir), ''), [rfReplaceAll]);
            sl3:= TStringListUTF8.Create;
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
          stream.Free;
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
              end else if not DirOnly then begin
                s:= LowerCase(ExtractFileExt(info.Name));
                if (s = '.m3u') or (s = '.m3u8') then begin
                  sl.Add(#3 + dir + info.Name);
                end else begin
                  mi:= thMIC.GetMediaInfo(dir + info.Name);
                  if Assigned(mi) then begin
                    s:= mi.GetMimeType(L_S, ScriptFileName);
                    if s <> '' then begin
                      if Pos(':::TRANS:::', s) > 0 then begin
                        sl.Add(#4 + dir + info.Name);
                      end else
                        sl.Add(#$FF + dir + info.Name);
                    end;
                  end;
                end;
              end;
            end;
          until FindNextUTF8(info) <> 0;
        finally
          FindCloseUTF8(Info);
        end;
    end;
  end;

var
  parent, item, val: TDOMNode;
  mlist: TStringListUTF8;
  i, j, c, si, rc: integer;
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

  mlist:= TStringListUTF8.Create;
  try
    if id = '0' then begin
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
      s:= id;
      Fetch(s, '$');
      if s = '' then Exit;
      i:= StrToInt(Fetch(s, '$'));
      s1:= IncludeTrailingPathDelimiter(MediaDirs.ValueFromIndex[i]);
      GetFileList(s1, mlist, s <> '');
      while s <> '' do begin
        i:= StrToInt(Fetch(s, '$'));
        if i >= mlist.Count then begin
          // TRANSCODE ファイルもフォルダとして検索してみる
          GetFileList(s1, mlist, False);
          if i >= mlist.Count then Break;
        end;
        s1:= Copy(mlist[i], 2, MaxInt);
        GetFileList(s1, mlist, s <> '');
      end;
    end;

    c:= mlist.Count;
    if c > rc then c:= rc;
    if si + c > mlist.Count then c:= mlist.Count - si;

    r:= '<DIDL-Lite'+
    ' xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"'+
    ' xmlns:dc="http://purl.org/dc/elements/1.1/"'+
    ' xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">';

    for i:= si to si+c-1 do begin
      fn:= mlist[i];
      case fn[1] of
        #1, #2, #3, #4: begin
          s:= Copy(fn, 2, MaxInt);
          if fn[1] <> #1 then
            s:= ExtractFileName(ExcludeTrailingPathDelimiter(s));
          s:= StringReplace(s, '&', '&amp;', [rfReplaceAll]);
          if fn[1] <> #4 then s:= '&lt; ' + s + ' &gt;' else s:= '/ ' + s;
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
          fn:= param;
          s1:= Fetch(fn, #$09);
          Fetch(fn, #$09);
          mi:= thMIC.GetMediaInfo(fn);
          mt:= mi.GetMimeType(L_S, ScriptFileName);
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
           'http://' +
           Sock.ResolveName(Sock.LocalName) + ':' + DAEMON_PORT + '/playmedia2/' +
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
        end;

        else begin
          fn:= Copy(fn, 2, MaxInt);
          mi:= thMIC.GetMediaInfo(fn);
          mt:= mi.GetMimeType(L_S, ScriptFileName);
          mt:= Fetch(mt, ':::');

          m:= ' protocolInfo="http-get:*:' + mt + '"';

          i64:= GetFileSize(fn);
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
           'http://' +
           Sock.ResolveName(Sock.LocalName) + ':' + DAEMON_PORT + '/playmedia/' +
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
          end;
          r:= r + '</item>';
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

  finally
    mlist.Free;
  end;

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
  i, buf_size: integer;
  nseek1, nseek2, ndur: double;
  iseek1, isize, fsize, range1, range2: Int64;
  buf: PByte;
  now_rec: boolean;
begin
  Result:= False;
  h:= TStringListUTF8.Create;
  try
    mi:= thMIC.GetMediaInfo(fname);
    cf:= mi.GetMimeType(L_S, ScriptFileName);
    ct:= Fetch(cf, ':');
    cf:= Fetch(cf, ':::');
    try
      now_rec:= mi.Values['General;Format'] = 'NowRecording';
      if now_rec then
        fs:= TFileStreamUTF8.Create(fname, fmOpenRead or fmShareDenyNone)
      else
        fs:= TFileStreamUTF8.Create(fname, fmOpenRead or fmShareDenyWrite);
      try
        fsize:= GetFileSize(fname){fs.Size};
        iseek1:= 0; isize:= fsize;
        nseek1:= 0; nseek2:= 0;
        dur:= mi.Values['General;Duration'];
        if now_rec then begin
          dur:= '20:00:00.000'; // 20時間のファイルと仮定する
          isize:= 200 * 1024 * 1024 * 1024; // 200GBのファイルと仮定
        end;
        ndur:= SeekTimeStr2Num(dur);
        i:= Pos('TIMESEEKRANGE.DLNA.ORG:', UpperCase(InHeader));
        if (i > 0) and (ndur > 0) then begin
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

        range1:= 0; range2:= 0;
        i:= Pos('RANGE:', UpperCase(InHeader));
        if i > 0 then begin
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

        Sock.SendString('HTTP/1.1 200 OK' + CRLF);
        if Sock.LastError <> 0 then Exit;
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
        ts_range:= '';
        if (nseek1 <> 0) or (nseek2 <> 0) then begin
          s:= SeekTimeNum2Str(nseek2);
          if nseek2 = 0 then s:= SeekTimeNum2Str(ndur);
          ts_range:= SeekTimeNum2Str(nseek1) + '-' + s + '/' + dur;
          h.Add('TimeSeekRange.dlna.org: npt=' + ts_range);
          h.Add('X-Seek-Range: npt=' + ts_range);
        end;
        range:= '';
        if (range1 <> 0) or (range2 <> 0) then begin
          range:= Format('%d-%d/%d', [range1, range2, fsize]);
          h.Add('Content-Range: bytes ' + range);
        end;
        h.Add('');
        for i:= 0 to h.Count - 1 do begin
          Sock.SendString(h[i] + CRLF);
          if Sock.LastError <> 0 then Exit;
        end;

        if UpperCase(request) <> 'HEAD' then begin
          Line:= line + GetLineHeader + 'STREAM sent' + CRLF +
           fname + CRLF +
           'Content-Type: ' + ct + CRLF +
           'ContentFeatures.DLNA.ORG: ' + cf + CRLF;
          if ts_range <> '' then
           Line:= Line + 'TimeSeekRange.dlna.org: npt=' + ts_range + CRLF;
          if range <> '' then
           Line:= Line + 'Content-Range: bytes ' + range + CRLF;
          Line:= Line + CRLF;
          Synchronize(@AddLog);

          if now_rec then begin
            // 余白分が溜まるまで待つ
            while not Terminated and Sock.CanWrite(1*60*1000) do begin
              fsize:= GetFileSize(fname);
              if fsize > OKKAKE_SPACE then Break;
              Sleep(100);
            end;
          end;

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
                  Sleep(5000);
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

      UniOutput:= True;
      Result:= True;
    except
    end;
  finally
    h.Free;
  end;
end;

function THttpThrd.DoPlayTranscode(sno: integer; const fname, request: string): boolean;
var
  mi: TGetMediaInfo;
  cmd, exec, tmp_fname, ct, cf, s, seek1, seek2, dur, range: string;
  fs: TFileStreamUTF8;
  h, sl: TStringListUTF8;
  i, buf_size, errc: integer;
  nseek1, nseek2, ndur: double;
  buf: PByte;
  proc: TProcessUTF8;
  ini: TIniFile;
  stream: TStringStream;
begin
  Result:= False;
  h:= TStringListUTF8.Create;
  try
    sl:= TStringListUTF8.Create;
    try
      stream:= TStringStream.Create(DoGetTranscodeCommand(fname));
      ini:= TIniFile.Create(stream);
      try
        ini.ReadSections(sl);
        ini.ReadSectionRaw(sl[sno], sl);
        cmd:= StringReplace(sl.Text, CRLF, ' ', [rfReplaceAll]);
        exec:= LowerCase(Fetch(cmd, ' '));
      finally
        ini.Free;
        stream.Free;
      end;
    finally
      sl.Free;
    end;

    mi:= thMIC.GetMediaInfo(fname);
    cf:= mi.GetMimeType(L_S, ScriptFileName);
    ct:= Fetch(cf, ':');
    cf:= Fetch(cf, ':::');
    try
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
      if (i > 0) and (ndur > 0) then begin
        s:= Copy(InHeader, i+23, Length(InHeader));
        s:= Trim(Fetch(s, CR));
        Fetch(s, '=');
        seek2:= Trim(s);
        seek1:= Fetch(seek2, '-');
        nseek1:= SeekTimeStr2Num(seek1);
        nseek2:= SeekTimeStr2Num(seek2);
      end else begin
        i:= Pos('RANGE:', UpperCase(InHeader));
        if i > 0 then begin
          // RANGEは使えませんと答える
          // (DLNA Interoperability Guidelines v1.0 - 7.8.22.7)
          Sock.SendString('HTTP/1.1 406 Not Acceptable' + CRLF + CRLF);
          Exit;
        end;
      end;

      Sock.SendString('HTTP/1.1 200 OK' + CRLF);
      if Sock.LastError <> 0 then Exit;
      h.Add('TransferMode.DLNA.ORG: Streaming');
      h.Add('Content-Type: ' + ct);
      h.Add('ContentFeatures.DLNA.ORG: ' + cf);
      h.Add('Accept-Ranges: bytes');
      h.Add('Connection: keep-alive');
      h.Add('Server: ' + HTTP_HEAD_SERVER);
      h.Add('Transfer-Encoding: chunked');
      range:= '';
      if (nseek1 <> 0) or (nseek2 <> 0) then begin
        s:= SeekTimeNum2Str(nseek2);
        if nseek2 = 0 then s:= SeekTimeNum2Str(ndur);
        range:= SeekTimeNum2Str(nseek1) + '-' + s + '/*'{ + dur};
        h.Add('TimeSeekRange.dlna.org: npt=' + range);
        h.Add('X-Seek-Range: npt=' + range);
      end;
      h.Add('');
      for i:= 0 to h.Count - 1 do begin
        Sock.SendString(h[i] + CRLF);
        if Sock.LastError <> 0 then Exit;
      end;

      if UpperCase(request) <> 'HEAD' then begin
        Line:= line + GetLineHeader + 'STREAM sent' + CRLF +
         fname + CRLF +
         'Content-Type: ' + ct + CRLF +
         'ContentFeatures.DLNA.ORG: ' + cf + CRLF +
         'TimeSeekRange.dlna.org: npt=' + range +
         CRLF + CRLF;
        Synchronize(@AddLog);

        buf_size:= iniFile.ReadInteger(INI_SEC_SYSTEM, 'STREAM_BUFFER_SIZE', 10);
        if buf_size < 1 then buf_size:= 1;
        if buf_size > 1800 then buf_size:= 1800;
        buf_size:= buf_size * 1024 * 1024;
        buf:= GetMem(buf_size);
        try
          tmp_fname:= FileUtil.GetTempFileName(TempPath, '$BMS_TRANS');
          proc:= TProcessUTF8.Create(nil);
          try
            cmd:= StringReplace(cmd, '$_in_$', ExtractShortPathNameUTF8(fname), [rfReplaceAll]);
            cmd:= StringReplace(cmd, '$_out_$', tmp_fname, [rfReplaceAll]);
            cmd:= '"' + ExecPath + exec + '" ' + cmd;
            if exec = 'mencoder' then begin
              if nseek1 <> 0 then begin
                cmd := cmd + ' -ss ' + SeekTimeNum2Str(nseek1);
              end;
              if (nseek2 > nseek1) then begin
                cmd := cmd + ' -endpos ' + SeekTimeNum2Str(nseek2-nseek1);
              end;
              cmd:= cmd + ' -quiet';
            end else if exec = 'ffmpeg' then begin
              if nseek1 <> 0 then begin
                cmd := cmd + ' -ss ' + SeekTimeNum2Str(nseek1);
              end;
              if (nseek2 > nseek1) then begin
                cmd := cmd + ' -t ' + SeekTimeNum2Str(nseek2-nseek1);
              end;
              //cmd:= cmd + ' -quiet';
            end;

            Line:= GetLineHeader + 'TRANSCODE ' + exec + CRLF + cmd + CRLF + CRLF;
            Synchronize(@AddLog);

            proc.CommandLine:= cmd;
            proc.Options:= [poNoConsole];
            proc.Execute;
            while proc.Running and not FileExistsUTF8(tmp_fname) do begin
              Sleep(100);
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
                  Sleep(100);
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
                  Sleep(1);
                  Inc(errc);
                end else begin
                  errc:= 0;
                  //Sock.SendString(LowerCase(IntToHex(i, 1)) + CRLF);
                  //Sock.SendBuffer(buf, i);
                  //Sock.SendString(CRLF);
                  SendRaw(LowerCase(IntToHex(i, 1)) + CRLF);
                  SendRaw(buf, i);
                  SendRaw(CRLF);
                end;
                if (Sock.LastError <> 0) or (errc > 5000) or Terminated then begin
                  proc.Terminate(-1);
                end;
              end;
              if not proc.Running then begin
                while not Terminated do begin
                  i:= fs.Read(buf^, buf_size);
                  if i = 0 then begin
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
                end;
              end;
            finally
              fs.Free;
            end;
          finally
            if proc.Running then proc.Terminate(-1);
            proc.Free;
            for i:= 1 to 6 do begin
              if DeleteFileUTF8(tmp_fname) then
                Break
              else
                Sleep(10000);
            end;
          end;
        finally
          FreeMem(buf);
        end;

        Line:= GetLineHeader + 'STREAM fin' + CRLF +
         fname + CRLF + CRLF;
      end;

      UniOutput:= True;
      Result:= True;
    except
    end;
  finally
    h.Free;
  end;
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
  myip, s, addr: String;
  L: Plua_State;
begin
  try
    Sock.CreateSocket();
    Sock.EnableReuse(True);
    Sock.Bind('0.0.0.0', '1900'{SSDP});
    if Sock.LastError <> 0 then Raise Exception.Create(Sock.LastErrorDesc);
    Sock.AddMulticast('239.255.255.250');
    if Sock.LastError <> 0 then Raise Exception.Create(Sock.LastErrorDesc);
    myip:= Sock.ResolveName(Sock.LocalName);
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
                sendSock.CreateSocket();
                if sendSock.LastError <> 0 then Raise Exception.Create(sendSock.LastErrorDesc);
                sendSock.Bind('0.0.0.0', '0');
                if sendSock.LastError <> 0 then Raise Exception.Create(sendSock.LastErrorDesc);
                addr:= Sock.GetRemoteSinIP;
                if addr <> myip then begin
                  sendSock.Connect(addr, IntToStr(Sock.GetRemoteSinPort));
                  if sendSock.LastError <> 0 then Raise Exception.Create(sendSock.LastErrorDesc);
                  s:=
                   'HTTP/1.1 200 OK' + CRLF +
                   'CACHE-CONTROL: max-age=2100' + CRLF +
                   'DATE: ' + Rfc822DateTime(now) + CRLF +
                   'LOCATION: http://' + myip + ':' + DAEMON_PORT +
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
                  line:= GetLineHeader + addr + '  SSDP Sent for M-SEARCH' + CRLF{ + s + CRLF};
                  Synchronize(@AddLog);
                end;
              except
                on e: Exception do begin
                  line:= '*** ERROR SSDP Sent: ' + e.Message + CRLF;
                  Synchronize(@AddLog);
                end;
              end;
            finally
              sendSock.Free;
            end;
          end;
        end else begin
          if Sock.LastError <> WSAETIMEDOUT then begin
            line:= '*** ERROR SSDP Recv : ' + Sock.LastErrorDesc + CRLF;
            Synchronize(@AddLog);
          end;
        end;
      end;
    finally
      lua_close(L);
    end;
  except
    on e: Exception do begin
      line:= '*** ERROR SSDP : ' + e.Message + CRLF;
      Synchronize(@AddLog);
    end;
  end;
end;

constructor TMediaInfoCollector.Create;
begin
  mi_list:= TStringListUTF8.Create;
  mi_list.Sorted:= True;
  mi_ac_list:= TStringListUTF8.Create;
  mi_ac_list.Sorted:= True;
  PriorityList:= TStringListUTF8.Create;
  FreeOnTerminate:= False;
  MaxMediaInfo:= iniFile.ReadInteger(INI_SEC_SYSTEM, 'MAX_MEDIAINFO', 500);
  InitCriticalSection(CS_list);
  InitCriticalSection(CS_ac_list);
  InitCriticalSection(CS_pr_list);
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
  inherited Destroy;
end;

procedure TMediaInfoCollector.Execute;

  procedure GetFileList(const dir: string; depth: integer; over_ok:boolean = False);
  var
    info: TSearchRec;
    mi: TGetMediaInfo;
  begin
    if not over_ok and (mi_list.Count >= MAXMEDIAINFO) then Exit;
    if FindFirstUTF8(dir+'*', faAnyFile, info) = 0 then
      try
        repeat
          if Terminated or (PriorityList.Count > 0) then Break;
          if (info.Name <> '.') and (info.Name <> '..') then begin
            if info.Attr and faDirectory <> 0 then begin
              if depth > 0 then begin
                Dec(depth);
                GetFileList(dir + info.Name + DirectorySeparator, depth);
              end;
            end else begin
              if mi_list.IndexOf(dir + info.Name) < 0 then begin
                mi:= TGetMediaInfo.Create(dir + info.Name, miHandle);
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
                  if not over_ok and (mi_list.Count >= MAXMEDIAINFO) then Break;
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
  depth, i, j: Integer;
  s: string;
  mi: TGetMediaInfo;
  PriorityDirName: string;
begin
  PriorityDirName:= '';
  while not Terminated do begin
    miHandle:= MediaInfo_New;
    try
      if PriorityList.Count > 0 then begin
        try
          i:= mi_list.IndexOf(PriorityList[0]);
          if i < 0 then begin
            mi:= TGetMediaInfo.Create(PriorityList[0], miHandle);
            EnterCriticalSection(CS_list);
            try
              mi.Locked:= True;
              mi_list.AddObject(PriorityList[0], mi);
            finally
              LeaveCriticalSection(CS_list);
            end;
          end else begin
            mi:= TGetMediaInfo(mi_list.Objects[i]);
            if not mi.Locked then begin
              EnterCriticalSection(CS_list);
              try
                mi.Locked:= True;
                if (mi.Count = 0) or
                 (mi.Values['General;Format'] = 'NowRecording') then begin
                  s:= mi.AccTime;
                  mi.Free;
                  mi:= TGetMediaInfo.Create(PriorityList[0], miHandle);
                  mi.AccTime:= s;
                  mi_list.Objects[i]:= mi;
                end;
              finally
                LeaveCriticalSection(CS_list);
              end;
            end;
          end;

          PriorityDirName:=
           IncludeTrailingPathDelimiter(ExtractFilePath(PriorityList[0]));
        finally
          EnterCriticalSection(CS_pr_list);
          try
            PriorityList.Delete(0);
          finally
            LeaveCriticalSection(CS_pr_list);
          end;
        end;
      end;

      if PriorityDirName <> '' then begin
        GetFileList(PriorityDirName, 0, True);
        PriorityDirName:= '';
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
    i:= 0;
    while not Terminated and
     (mi_list.Count > MAXMEDIAINFO) and (i < mi_list.Count) do begin
      EnterCriticalSection(CS_list);
      try
        j:= mi_list.IndexOf(Copy(mi_ac_list[i], 13, MaxInt));
        mi:= TGetMediaInfo(mi_list.Objects[j]);
        if mi.Locked then begin
          Inc(i);
          Continue;
        end;
        mi.Free;
        mi_list.Delete(j);
      finally
        LeaveCriticalSection(CS_list);
      end;
      EnterCriticalSection(CS_ac_list);
      try
        mi_ac_list.Delete(i);
      finally
        LeaveCriticalSection(CS_ac_list);
      end;
    end;

    // 待機
    if not Terminated and (PriorityList.Count = 0) then Suspended:= True;
  end;
end;

// 注：他のスレッドからしか呼ばれることはないメソッド
function TMediaInfoCollector.GetMediaInfo(const fname: string): TGetMediaInfo;
var
  i: Integer;
begin
  Result:= nil;

  EnterCriticalSection(CS_list);
  try
    i:= mi_list.IndexOf(fname);
    if i >= 0 then begin
      Result:= TGetMediaInfo(mi_list.Objects[i]);
      Result.Locked:= True;
    end;
  finally
    LeaveCriticalSection(CS_list);
  end;

  if not Assigned(Result) or (Result.Count = 0) or
   (Result.Values['General;Format'] = 'NowRecording') then begin
    if Assigned(Result) then begin
      EnterCriticalSection(CS_list);
      try
        Result.Locked:= False;
      finally
        LeaveCriticalSection(CS_list);
      end;
    end;
    EnterCriticalSection(CS_pr_list);
    try
      PriorityList.Add(fname);
    finally
      LeaveCriticalSection(CS_pr_list);
    end;
    Suspended:= False;
    while True do begin
      EnterCriticalSection(CS_list);
      try
        i:= mi_list.IndexOf(fname);
        if i >= 0 then begin
          Result:= TGetMediaInfo(mi_list.Objects[i]);
          Break;
        end;
      finally
        LeaveCriticalSection(CS_list);
      end;
      Sleep(10);
    end;
  end;

  EnterCriticalSection(CS_ac_list);
  try
    i:= mi_ac_list.IndexOf(Result.AccTime+fname);
    if i >= 0 then mi_ac_list.Delete(i);
    Result.AccTime:= FormatDateTime('yymmddhhnnss', Now);
    mi_ac_list.Add(Result.AccTime + fname);
  finally
    LeaveCriticalSection(CS_ac_list);
  end;

  EnterCriticalSection(CS_list);
  try
    Result.Locked:= False;
  finally
    LeaveCriticalSection(CS_list);
  end;
end;

constructor TGetMediaInfo.Create(const fname: string; mi: Cardinal);
begin
  FileName:= fname;
  GetMediaInfo(fname, mi, Self, ExecPath);
end;

destructor TGetMediaInfo.Destroy;
begin
  inherited Destroy;
end;

function TGetMediaInfo.GetMimeType(L: PLua_State; const scname: string): string;

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

