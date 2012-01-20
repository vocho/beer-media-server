unit unit2;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, lazutf8classes;

type

  { TStringListUTF8_mod }

  TStringListUTF8_mod = class(TStringListUTF8)
  protected
    function DoCompareText(const s1,s2 : string) : PtrInt; override;
  public
  end;

procedure SleepThread(h: THandle; ms: integer);
function DecodeX(const s: string): string;
function EncodeX(const s: string): string;
function GetFileSize(const fname: string): Int64;
function SeekTimeStr2Num(const seek: string): double;
function SeekTimeNum2Str(seek: double): string;
procedure CopyDirPerfect(dir, dest: string);
function ExecCommand(const CommandLine: string;
 StdIn, StdOut, ErrOut: TStream; ShowConsole: boolean = False): longword;
procedure GetMediaInfo(const fname: string; mi: Cardinal; sl: TStringList;
 const exec_path: string);


implementation
uses
{$IFDEF Win32}
  Windows,
{$ENDIF}
{$IFNDEF Win32}
  process, utf8process,
{$ENDIF}
  MediaInfoDll,
  fileutil, synautil;

{ TStringListUTF8_mod }

function TStringListUTF8_mod.DoCompareText(const s1, s2: string): PtrInt;
begin
  if CaseSensitive then
    Result:= CompareStr(s1, s2)
  else
    Result:= CompareText(s1, s2);
end;

procedure SleepThread(h: THandle; ms: integer);
begin
{$IFDEF Win32}
  WaitForSingleObject(h, ms);
{$ELSE}
  Sleep(ms);
{$ENDIF}
end;

function EncodeX(const s: string): string;
var
  i, l: Integer;
begin
  Result:= '';
  i:= 1; l:= Length(s);
  while i <= l do begin
    if s[i] in ['0'..'9', 'A'..'J', 'a'..'z', '.', '-', '!', '$', '(', ')'] then
      Result:= Result + s[i]
    else
      Result:= Result +
       Char(Byte('K')+Byte(s[i]) shr 4) + Char(Byte('K')+Byte(s[i]) and $0F);
    Inc(i);
  end;
end;

function DecodeX(const s: string): string;
var
  i, l: Integer;
begin
  Result:= '';
  i:= 1; l:= Length(s);
  while i <= l do begin
    if (s[i] in ['K'..'Z']) and (i < l) then begin
      Result:= Result +
       Char((Byte(s[i])-Byte('K')) shl 4 + Byte(s[i+1])-Byte('K'));
      Inc(i);
    end else
      Result:= Result + s[i];
    Inc(i);
  end;
end;

function GetFileSize(const fname: string): Int64;
var
  info: TSearchRec;
begin
  Result:= 0;
  if FindFirstUTF8(fname, faAnyFile, info) = 0 then
    try
      Result:= info.Size;
    finally
      FindCloseUTF8(Info);
    end;
end;

function SeekTimeStr2Num(const seek: string): double;
var
  s, n1, n2, n3: string;
begin
  s:= seek;
  n1:= Fetch(s, ':');
  if s = '' then begin
    s:= Fetch(n1, '.');
    n1:= n1 + '000';
    n1:= Copy(n1, 1, 3);
    Result:= StrToIntDef(s, 0) * 1000 + StrToIntDef(n1, 0);
    Exit;
  end;
  n2:= Fetch(s, ':');
  if s = '' then begin
    s:= Fetch(n2, '.');
    n2:= n2 + '000';
    n2:= Copy(n2, 1, 3);
    Result:= StrToIntDef(n1, 0) * 60.0 * 1000 +
     StrToIntDef(s, 0) * 1000 + StrToIntDef(n2, 0);
    Exit;
  end;
  n3:= s;
  s:= Fetch(n3, '.');
  n3:= n3 + '000';
  n3:= Copy(n3, 1, 3);
  Result:= StrToIntDef(n1, 0) * 60 * 60 * 1000 +
   StrToIntDef(n2, 0) * 60 * 1000 +
   StrToIntDef(s, 0) * 1000 + StrToIntDef(n3, 0);
end;

function SeekTimeNum2Str(seek: double): string;
var
  i: integer;
begin
  if seek >= 60.0*60.0*1000.0 then begin
    i:= Trunc(seek / (60.0*60.0*1000.0));
    Result:= Format('%2.2d:', [i]);
    seek:= seek - (60.0*60.0*1000.0*i);
  end else
    Result:= '00:';
  if seek >= 60.0*1000.0 then begin
    i:= Trunc(seek / (60.0*1000.0));
    Result:= Result + Format('%2.2d:', [i]);
    seek:= seek - 60.0 * 1000.0 * i;
  end else
    Result:= Result + '00:';
  if seek >= 1000.0 then begin
    i:= Trunc(seek / 1000.0);
    Result:= Result + Format('%2.2d', [i]);
    seek:= seek - 1000.0 * i;
  end else
    Result:= Result + '00';
  Result:= Result + '.' + Format('%3.3d', [Trunc(seek)]);
end;

procedure CopyDirPerfect(dir, dest: string);
var
  info: TSearchRec;
begin
  if ForceDirectoriesUTF8(dest) then begin
    dir:= IncludeTrailingPathDelimiter(dir);
    dest:= IncludeTrailingPathDelimiter(dest);
    if FindFirstUTF8(dir+'*', faAnyFile, info) = 0 then
      try
        repeat
          if (info.Name <> '.') and (info.Name <> '..') and
           (info.Attr and faHidden = 0) then begin
            if info.Attr and faDirectory <> 0 then begin
              CopyDirPerfect(dir+info.Name, dest+info.Name);
            end else begin
              CopyFile(dir + info.Name, dest + info.Name);
            end;
          end;
        until FindNextUTF8(info) <> 0;
      finally
        FindCloseUTF8(Info);
      end;
  end;
end;

function ExecCommand(const CommandLine: string;
 StdIn, StdOut, ErrOut: TStream; ShowConsole: boolean = False): longword;
{$IFDEF Win32}
// Current TProcess with pipe is BUGGY so...
var
  hReadPipe, hWritePipe: THandle;
  hStdInReadPipe, hStdInWritePipe, hStdInWritePipeDup: THandle;
  hErrReadPipe, hErrWritePipe: THandle;
  sa: TSecurityAttributes;
  SD: TSecurityDescriptor;
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  bufStdOut, bufErrOut, bufStdIn: array[0..8192] of char;
  dwStdOut, dwErrOut, dwRet: DWord;
  StreamBufferSize, nWritten: DWord;
begin
  Result:= longword(-1);

  with sa do begin
    nLength        := SizeOf( TSecurityAttributes );
    bInheritHandle := True;
    if Win32Platform = VER_PLATFORM_WIN32_NT then
      begin
        InitializeSecurityDescriptor(
            @SD,
            SECURITY_DESCRIPTOR_REVISION
        );
        SetSecurityDescriptorDacl( @SD, True, nil, False );
        lpSecurityDescriptor := @SD;
      end
    else lpSecurityDescriptor := nil;
  end;{with SA do}

  hReadPipe := 0; hWritePipe := 0;
  hErrReadPipe := 0; hErrWritePipe := 0;

  if Assigned(StdIn) then StdIn.Position := 0;
  //if Assigned(StdOut) then StdOut.Clear;
  //if Assigned(ErrOut) then ErrOut.Clear;

  CreatePipe(hStdInReadPipe{%H-}, hStdInWritePipe{%H-}, @sa, 8192);
  DuplicateHandle(GetCurrentProcess(), hStdInWritePipe, GetCurrentProcess(),
                  @hStdInWritePipeDup, 0, false, DUPLICATE_SAME_ACCESS);
  CloseHandle(hStdInWritePipe);

  CreatePipe(hReadPipe, hWritePipe, @sa, 8192);
  try
    CreatePipe(hErrReadPipe, hErrWritePipe, @sa, 8192);
    try
      ZeroMemory(@StartupInfo, sizeof(TStartupInfo));
      with StartupInfo do
      begin
        cb:= sizeof(TStartupInfo);
        dwFlags:= STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
        if ShowConsole then begin
          wShowWindow:= SW_SHOW;
        end else
          wShowWindow:= SW_HIDE;
        // 標準 IO にパイプの端っこを指定してやる
        hStdInput:= hStdInReadPipe;
        hStdOutput:= hWritePipe;
        hStdError:= hErrWritePipe;
      end;

      ZeroMemory(@ProcessInfo, sizeof(TProcessInformation));

      // コンソールアプリ起動
      //if CreateProcess(nil, PChar(UTF8ToSys(CommandLine)), @sa, nil, true,
      if CreateProcessW(nil, PWideChar(UTF8Decode(CommandLine)), @sa, nil, true,
       CREATE_DEFAULT_ERROR_MODE{DETACHED_PROCESS},
       nil, nil, StartupInfo, ProcessInfo) = true then
      begin
        if Assigned(StdIn) then begin
          // 入力待ちになるまで待ってから，
          WaitForInputIdle(ProcessInfo.hProcess, 1000);
          StreamBufferSize:= 8192;
          while StreamBufferSize = 8192 do
          begin
            // 入力を与える
            StreamBufferSize := StdIn.Read(bufStdIn{%H-}, 8192);
            WriteFile(hStdInWritePipeDup, bufStdIn, StreamBufferSize, nWritten{%H-}, nil);
          end;
        end;
        // 入力を与え終わった
        CloseHandle(hStdInWritePipeDup);

        try
          repeat

            Sleep(50);

            if Assigned(StdOut) then begin
              // 標準出力パイプの内容を調べる
              PeekNamedPipe(hReadPipe, nil, 0, nil, @dwStdOut, nil);
              if (dwStdOut > 0) then
              begin
                // 内容が存在すれば、読み取る
                ReadFile(hReadPipe, bufStdOut{%H-}, Length(bufStdOut) - 1, dwStdOut, nil);
                StdOut.Write(bufStdOut, dwStdOut);
              end;
            end;

            if Assigned(ErrOut) then begin
              // 同様にエラー出力の処理
              PeekNamedPipe(hErrReadPipe, nil, 0, nil, @dwErrOut, nil);
              if (dwErrOut > 0) then
              begin
                ReadFile(hErrReadPipe, bufErrOut{%H-}, Length(bufErrOut) - 1, dwErrOut, nil);
                ErrOut.Write(bufErrOut, dwErrOut);
              end;
            end;

            dwRet := WaitForSingleObject(ProcessInfo.hProcess, 0);
          until (dwRet = WAIT_OBJECT_0);        // コンソールアプリのプロセスが存在している間

          if Assigned(StdOut) then StdOut.Position := 0;
          if Assigned(ErrOut) then ErrOut.Position := 0;

          GetExitCodeProcess(ProcessInfo.hProcess, Result);
        finally
          CloseHandle(ProcessInfo.hProcess);
          CloseHandle(ProcessInfo.hThread);
          CloseHandle(hStdInReadPipe);
        end;
      end;
    finally
      CloseHandle(hErrReadPipe);
      CloseHandle(hErrWritePipe);
    end;
  finally
    CloseHandle(hReadPipe);
    CloseHandle(hWritePipe);
  end;
{$ELSE}
var
  buf1, buf2: string;
  i, j: integer;
  proc: TProcessUTF8;
begin
  proc:= TProcessUTF8.Create(nil);
  try
    proc.CommandLine:= CommandLine;
    proc.Options:= [];
    if not ShowConsole then proc.Options:= proc.Options + [poNoConsole];
    if Assigned(Stdin) or Assigned(StdOut) or Assigned(ErrOut) then
      proc.Options:= proc.Options + [poUsePipes];
    if not Assigned(StdOut) and not Assigned(ErrOut) then
      proc.Options:= proc.Options + [poWaitOnExit];

    if Assigned(Stdin) then proc.Input.CopyFrom(StdIn, Stdin.Size);

    proc.Execute;

    if Assigned(StdOut) or Assigned(ErrOut) then begin
      SetLength(buf1, 1024);
      SetLength(buf2, 1024);
      while proc.Running do begin
        i:= proc.Output.Read(buf1[1], 1024);
        j:= proc.Stderr.Read(buf2[1], 1024);
        if (i > 0) or (j > 0) then begin
          if Assigned(StdOut) then StdOut.WriteBuffer(buf1[1], i);
          if Assigned(ErrOut) then ErrOut.WriteBuffer(buf2[1], j);
        end else begin
          Sleep(100);
        end;
      end;
      while True do begin
        i:= proc.Output.Read(buf1[1], 1024);
        j:= proc.Stderr.Read(buf2[1], 1024);
        if (i <= 0) and (j <= 0) then Break;
        if Assigned(StdOut) then StdOut.WriteBuffer(buf1[1], i);
        if Assigned(ErrOut) then ErrOut.WriteBuffer(buf2[1], j);
      end;

      if Assigned(StdOut) then begin
        //StdOut.CopyFrom(proc.Output, proc.Output.Size);
        StdOut.Position := 0;
      end;
      if Assigned(ErrOut) then begin
        //ErrOut.CopyFrom(proc.Stderr, proc.Stderr.Size);
        ErrOut.Position := 0;
      end;
    end;

    Result:= proc.ExitStatus;
  finally
    proc.Free;
  end;
{$ENDIF}
end;

procedure GetMediaInfo(const fname: string; mi: Cardinal; sl: TStringList;
 const exec_path: string);

  function GetInfo(mi: Cardinal; const para: string): string;
  begin
    MediaInfoA_Option(mi, 'Inform', PChar(para));
    Result:= StrPas(MediaInfoA_Inform(mi, 0));
  end;

  function GetInfo2(mi: Cardinal; sk: TMIStreamKind; sn: Integer;
   const para: string): string;
  begin
    Result:= StrPas(MediaInfoA_Get(mi, sk, sn, PChar(para), Info_Text, Info_Name));
  end;

  function DoMPlayer(no: integer): string;
  var
    o: TStringStream;
  begin
    o:= TStringStream.Create('');
    try
      ExecCommand('"' + exec_path + 'mplayer.exe"' +
       ' -speed 100 -vo null -ao null -frames 1 -identify' +
       ' -dvd-device "' + ExtractShortPathNameUTF8(fname) + '" dvd://' + IntToStr(no), nil, o, nil);
      Result:= o.DataString;
    finally
      o.Free;
    end;
  end;

var
  gf, buf, res, s: string;
  fs: TFileStreamUTF8;
  i, c, cc, main_v, dur, w: integer;
  max_dur, max_w: Int64;
  d, md: double;
begin
  try
    if (fname = '') or not FileExistsUTF8(fname) then Exit;
    s:= LowerCase(ExtractFileExt(fname));
    if (s = '.lua') or (s = '.txt') or  (s = '.m3u') or  (s = '.m3u8') then Exit;
    if GetFileSize(fname) <= 0 then Exit;
    try
      // 書き込み中のファイルかを調べるため、fmShareDenyWriteで開いてみる
      fs:= TFileStreamUTF8.Create(fname, fmOpenRead or fmShareDenyWrite);
    except
      sl.Add('General;Format=NowRecording');
      Exit;
    end;
    try
      //mi:= MediaInfo_New;
      //try
        if MediaInfo_Open(mi, PWideChar(UTF8Decode(fname))) <> 1 then Exit;
        try
          gf:= GetInfo(mi, 'General;%Format%');
          sl.Add('General;Format=' + gf);
          if gf = '' then Exit;
          sl.Add('General;Duration=' + GetInfo(mi, 'General;%Duration/String3%'));
          sl.Add('General;File_Created_Date_Local=' + GetInfo(mi, 'General;%File_Created_Date_Local%'));

          c:= StrToIntDef(GetInfo(mi, 'General;%VideoCount%'), 1);
          main_v:= 0;
          if c > 1 then begin
            max_dur:= 0; max_w:= 0;
            for i:= 0 to c-1 do begin
              dur:= StrToIntDef(GetInfo2(mi, Stream_Video, i, 'Duration'), 0);
              w:= StrToIntDef(GetInfo2(mi, Stream_Video, i, 'Width'), 0);
              if (gf = 'MPEG-TS') or (gf = 'BDAV') then begin
                if ((w > 320{=1SEG}) and (dur > max_dur)) or (w > max_w) then begin
                  main_v:= i;
                  max_dur:= dur;
                  max_w:= w;
                end;
              end else begin
                if (dur > max_dur) or (w > max_w) then begin
                  main_v:= i;
                  max_dur:= dur;
                  max_w:= w;
                end;
              end;
            end;
          end;
          s:= GetInfo2(mi, Stream_Video, main_v, 'Format');
          sl.Add('Video;Format=' + s);
          if s <> '' then begin
            sl.Add('Video;Format_Profile=' + GetInfo2(mi, Stream_Video, main_v, 'Format_Profile'));
            sl.Add('Video;Width=' + GetInfo2(mi, Stream_Video, main_v, 'Width'));
            sl.Add('Video;Height=' + GetInfo2(mi, Stream_Video, main_v, 'Height'));
            sl.Add('Video;Duration=' + GetInfo2(mi, Stream_Video, main_v, 'Duration/String3'));
            sl.Add('Video;BitRate=' + GetInfo2(mi, Stream_Video, main_v, 'BitRate'));
            sl.Add('Video;FrameRate=' + GetInfo2(mi, Stream_Video, main_v, 'FrameRate'));
            sl.Add('Video;FrameRate_Mode=' + GetInfo2(mi, Stream_Video, main_v, 'FrameRate_Mode'));
            sl.Add('Video;Standard=' + GetInfo2(mi, Stream_Video, main_v, 'Standard'));
            sl.Add('Video;CodecID=' + GetInfo2(mi, Stream_Video, main_v, 'CodecID'));
            sl.Add('Video;DisplayAspectRatio=' + GetInfo2(mi, Stream_Video, main_v, 'DisplayAspectRatio'));
            sl.Add('Video;ID=' + GetInfo2(mi, Stream_Video, main_v, 'ID'));
            sl.Add('Video;ScanType=' + GetInfo2(mi, Stream_Video, main_v, 'ScanType'));

            if SeekTimeStr2Num(sl.Values['General;Duration'])
             < SeekTimeStr2Num(sl.Values['Video;Duration']) then begin
              // 矛盾を修正。 MediaInfo.DLL のバグ?
              sl.Values['General;Duration']:= sl.Values['Video;Duration'];
            end;
          end;

          s:= GetInfo2(mi, Stream_Audio, main_v, 'Format');
          sl.Add('Audio;Format=' + s);
          if s <> '' then begin
            sl.Add('Audio;Channels=' + GetInfo2(mi, Stream_Audio, main_v, 'Channel(s)'));
            sl.Add('Audio;BitRate=' + GetInfo2(mi, Stream_Audio, main_v, 'BitRate'));
            sl.Add('Audio;SamplingRate=' + GetInfo2(mi, Stream_Audio, main_v, 'SamplingRate'));
            sl.Add('Audio;ID=' + GetInfo2(mi, Stream_Audio, main_v, 'ID'));
          end;

          {
          if (gf = 'MPEG-TS') or (gf = 'BDAV') then begin
            SetLength(buf, 192 * 6);
            fs.ReadBuffer(buf[1], 192 * 6);
            if ((buf[1] = #$47) and (buf[192+1] = #$47) and (buf[192*2+1] = #$47)) or
             ((buf[5] = #$47) and (buf[192+5] = #$47) and (buf[192*2+5] = #$47)) then begin
              Add('Video;Timed=1');
            end;
          end else
          }
          if gf = 'ISO 9660' then begin
            res:= DoMPlayer(1);
            if Pos('ID_DVD_VOLUME_ID=', res) > 0 then begin
              sl.Values['General;Format']:= 'ISO DVD';
              sl.Values['Video;Format']:= 'ISO DVD Video';
              sl.Values['Audio;Format']:= 'ISO DVD Audio';
              md:= 0; max_dur := 0;
              buf:= res;
              while True do begin
                c:= Pos('ID_DVD_TITLE_', buf);
                if c <= 0 then Break;
                buf:= Copy(buf, c+Length('ID_DVD_TITLE_'), MaxInt);
                c:= Pos('_', buf);
                if Copy(buf, c+1, 6) = 'LENGTH' then begin
                  s:= Copy(buf, c+8, MaxInt);
                  s:= Fetch(s, #$0d);
                  d:= StrToFloatDef(s, 0);
                  if d > 30 then begin
                    sl.Add('DVD;LENGTH' + Copy(buf, 1, c-1) + '=' + s);
                    if d > md then begin
                      md:= d;
                      max_dur:= StrToInt(Copy(buf, 1, c-1));
                    end;
                  end;
                end;
              end;
              sl.Add('DVD;LONGEST=' + IntToStr(max_dur));

              if max_dur > 1 then res:= DoMPlayer(max_dur);

              cc:= 0;
              buf:= res;
              while True do begin
                c:= Pos('ID_AID_', buf);
                if c <= 0 then Break;
                buf:= Copy(buf, c+Length('ID_AID_'), MaxInt);
                c:= Pos('_', buf);
                if Copy(buf, c, 6) = '_LANG=' then begin
                  s:= Copy(buf, c+6, MaxInt);
                  s:= Fetch(s, #$0d);
                  if sl.Values['DVD;ALANG;' + s] = '' then begin
                    sl.Add('DVD;ALANG;' + s + '=1');
                    Inc(cc);
                  end;
                end;
              end;
              sl.Add('DVD;ALANG;Count=' + IntToStr(cc));

              cc:= 0;
              buf:= res;
              while True do begin
                c:= Pos('ID_SID_', buf);
                if c <= 0 then Break;
                buf:= Copy(buf, c+Length('ID_SID_'), MaxInt);
                c:= Pos('_', buf);
                if Copy(buf, c, 6) = '_LANG=' then begin
                  s:= Copy(buf, c+6, MaxInt);
                  s:= Fetch(s, #$0d);
                  if sl.Values['DVD;SLANG;' + s] = '' then begin
                    sl.Add('DVD;SLANG;' + s + '=1');
                    Inc(cc);
                  end;
                end;
              end;
              sl.Add('DVD;SLANG;Count=' + IntToStr(cc));

              c:= Pos('ID_VIDEO_BITRATE=', res);
              if c > 0 then begin
                buf:= Copy(res, c+Length('ID_VIDEO_BITRATE='), MaxInt);
                sl.Values['Video;BitRate']:= Fetch(buf, #$0d);
              end;

              c:= Pos('ID_VIDEO_WIDTH=', res);
              if c > 0 then begin
                buf:= Copy(res, c+Length('ID_VIDEO_WIDTH='), MaxInt);
                sl.Values['Video;Width']:= Fetch(buf, #$0d);
              end;

              c:= Pos('ID_VIDEO_HEIGHT=', res);
              if c > 0 then begin
                buf:= Copy(res, c+Length('ID_VIDEO_HEIGHT='), MaxInt);
                sl.Values['Video;Height']:= Fetch(buf, #$0d);
              end;

              c:= Pos('ID_VIDEO_FPS=', res);
              if c > 0 then begin
                buf:= Copy(res, c+Length('ID_VIDEO_FPS='), MaxInt);
                sl.Values['Video;FrameRate']:= Fetch(buf, #$0d);
              end;

              c:= Pos('Opening audio decoder:', res);
              if c > 0 then begin
                buf:= Copy(res, c, MaxInt);
                c:= Pos('ID_AUDIO_BITRATE=', buf);
                if c > 0 then begin
                  buf:= Copy(buf, c+Length('ID_AUDIO_BITRATE='), MaxInt);
                  sl.Values['Audio;BitRate']:= Fetch(buf, #$0d);
                end;
                c:= Pos('ID_AUDIO_RATE=', buf);
                if c > 0 then begin
                  buf:= Copy(buf, c+Length('ID_AUDIO_RATE='), MaxInt);
                  sl.Values['Audio;SamplingRate']:= Fetch(buf, #$0d);
                end;
                c:= Pos('ID_AUDIO_NCH=', buf);
                if c > 0 then begin
                  buf:= Copy(buf, c+Length('ID_AUDIO_NCH='), MaxInt);
                  sl.Values['Audio;Channels']:= Fetch(buf, #$0d);
                end;
              end;

              c:= Pos('Movie-Aspect is', res);
              if c > 0 then begin
                buf:= Copy(res, c, MaxInt);
                c:= Pos('ID_VIDEO_ASPECT=', buf);
                if c > 0 then begin
                  buf:= Copy(buf, c+Length('ID_VIDEO_ASPECT='), MaxInt);
                  s:= Fetch(buf, #$0d);
                  s:= Format('%1.3f', [StrToFloatDef(s, 0)+0.0005]);
                  sl.Values['Video;DisplayAspectRatio'] := s;
                end;
              end;
            end;
          end;
        finally
          MediaInfo_Close(mi);
        end;
      //finally
      //  MediaInfo_Delete(mi);
      //end;
    finally
      fs.Free;
    end;
  except
  end;
end;

end.

