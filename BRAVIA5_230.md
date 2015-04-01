230氏からの情報によりますと、現バージョン（svn rev 34118）の mencoder には mp4 の処理にバグがあるっぽく、次のようにして GetTranscodeCommand 関数内で mencoder の代わりに ffmpeg を使うことで H264ToMpegTS = true としたときの処理がうまくいくとのことです。<br>
FFmpegは <a href='http://oss.netfarm.it/mplayer-win32.php'>http://oss.netfarm.it/mplayer-win32.php</a> で配布されている（もしくは <a href='http://sourceforge.net/projects/mplayer-win32/files/FFmpeg/'>http://sourceforge.net/projects/mplayer-win32/files/FFmpeg/</a> ） FFmpeg git rev N-32754-g936d4d4 を使われたとのことです。<br>
なお、FFMpeg.exe は  BMS.exe と同じフォルダに置いてください。<br>
H264ToMpegTS = true とすることも忘れないでください。<br>
<br>
※注意※ GetTranscodeCommand 関数の部分だけ掲載しています。他の部分はオリジナルのままで OK です。<br>
<br>
<pre><code><br>
function GetTranscodeCommand(fname, minfo)<br>
<br>
  local aspect = minfo.Video.DisplayAspectRatio<br>
  if aspect == "" then aspect = "1.333" end<br>
  --print("\r\nDEBUG: "..fname.." aspect="..aspect.."\r\n")<br>
  local w = minfo.Video.Width<br>
  local h = minfo.Video.Height<br>
<br>
  -- この機種ではHDサイズのものは正しく表示されない場合があるよう<br>
  -- なのでSDサイズに変換する。<br>
  if tonumber(w) &gt; 720 then<br>
    w = "720" h = "480"<br>
  end<br>
  -- この機種ではアスペクト比16/9以外のものに未対応のようなので<br>
  -- アスペクト比16/9以外のものは16/9に変換する。<br>
  local vfs = "scale="..w..":"..h..","<br>
  if aspect ~= "1.778" then<br>
    local sw = w<br>
    local sh = h<br>
    if tonumber(aspect) &lt; 1.778 then<br>
      sw = math.floor(w / 1.778 * aspect + 0.5)<br>
    else<br>
      sh = math.floor(h * 1.778 / aspect + 0.5)<br>
    end<br>
    vfs = "scale="..sw..":"..sh..",expand="..w..":"..h..","<br>
    aspect = "1.778"<br>
  end<br>
  <br>
  if minfo.General.Format == "ISO DVD" then<br>
<br>
    if minfo.DVD.ALANG.en and minfo.DVD.SLANG.ja then<br>
<br>
      -- 英語音声と日本語字幕がある場合<br>
<br>
      return [[<br>
<br>
       [$_name_$ (英語音声・日本語字幕)]<br>
       mencoder -dvd-device "$_in_$" dvd://$_longest_$<br>
       -o "$_out_$" -oac lavc -ovc lavc -of mpeg -mpegopts format=dvd:tsaf<br>
       -vf ]]..vfs..[[harddup -srate 48000 -af lavcresample=48000<br>
       -ofps 30000/1001 -alang en -slang ja -channels 6<br>
       -lavcopts vcodec=mpeg2video:vrc_buf_size=1835:vrc_maxrate=9800:vbitrate=5000:keyint=18:vstrict=0:acodec=ac3:abitrate=192:aspect=]]<br>
       ..aspect<br>
<br>
      ..[[<br>
<br>
       [$_name_$ (日本語音声)]<br>
       mencoder -dvd-device "$_in_$" dvd://$_longest_$<br>
       -o "$_out_$" -oac lavc -ovc lavc -of mpeg -mpegopts format=dvd:tsaf<br>
       -vf ]]..vfs..[[harddup -srate 48000 -af lavcresample=48000<br>
       -ofps 30000/1001 -alang ja -slang ja -forcedsubsonly -channels 6<br>
       -lavcopts vcodec=mpeg2video:vrc_buf_size=1835:vrc_maxrate=9800:vbitrate=5000:keyint=18:vstrict=0:acodec=ac3:abitrate=192:aspect=]]<br>
       ..aspect<br>
       <br>
      ..[[<br>
<br>
       [$_name_$ (英語音声)]<br>
       mencoder -dvd-device "$_in_$" dvd://$_longest_$<br>
       -o "$_out_$" -oac lavc -ovc lavc -of mpeg -mpegopts format=dvd:tsaf<br>
       -vf ]]..vfs..[[harddup -srate 48000 -af lavcresample=48000<br>
       -ofps 30000/1001 -alang en -slang en -forcedsubsonly -channels 6<br>
       -lavcopts vcodec=mpeg2video:vrc_buf_size=1835:vrc_maxrate=9800:vbitrate=5000:keyint=18:vstrict=0:acodec=ac3:abitrate=192:aspect=]]<br>
       ..aspect<br>
       <br>
    else<br>
<br>
      return [[<br>
<br>
       [$_name_$]<br>
       mencoder -dvd-device "$_in_$" dvd://$_longest_$<br>
       -o "$_out_$" -oac lavc -ovc lavc -of mpeg -mpegopts format=dvd:tsaf<br>
       -vf ]]..vfs..[[harddup -srate 48000 -af lavcresample=48000<br>
       -ofps 30000/1001 -forcedsubsonly -channels 6<br>
       -lavcopts vcodec=mpeg2video:vrc_buf_size=1835:vrc_maxrate=9800:vbitrate=5000:keyint=18:vstrict=0:acodec=ac3:abitrate=192:aspect=]]<br>
       ..aspect<br>
<br>
    end<br>
  end<br>
<br>
  if H264ToMpegTS and minfo.Video.Format == "AVC"<br>
   -- NTSC or 24p(not PAL)?<br>
   and  fr ~= "25" and fr ~= "50" and minfo.Video.Standard ~= "PAL"<br>
   -- CFR?<br>
   and minfo.Video.FrameRate_Mode ~= "VFR"<br>
   -- アスペクト比=16/9 ?<br>
   and minfo.Video.DisplayAspectRatio == "1.778" then<br>
<br>
    if minfo.Audio.Format == "AC-3" then<br>
      -- コンテナのみ替える<br>
      return [[<br>
<br>
       [$_name_$ (TRANSCODE to AVCHD)]<br>
       ffmpeg -i "$_in_$"<br>
       -vcodec copy -acodec copy -f mpegts -vbsf h264_mp4toannexb "$_out_$"<br>
       ]]<br>
    else<br>
      -- コンテナ替え＋音声を AC-3 に変換<br>
      return [[<br>
<br>
       [$_name_$ (TRANSCODE to AVCHD)]<br>
       ffmpeg -i "$_in_$"<br>
       -vcodec copy -acodec ac3 -ac 6 -ar 48000 -ab 192k -f mpegts -vbsf h264_mp4toannexb "$_out_$"<br>
       ]]<br>
<br>
      --[[<br>
      なお、KDL-40HX800 ではここを <br>
       ffmpeg -i "$_in_$"<br>
       -vcodec copy -acodec copy -f mpegts -vbsf h264_mp4toannexb "$_out_$"<br>
      としても AAC 音声を再生できるとのことです。<br>
      ]]<br>
    end<br>
  end<br>
<br>
  return [[<br>
<br>
   [$_name_$ (TRANSCODE to MPEG-PS)]<br>
   mencoder "$_in_$" -o "$_out_$"<br>
   -oac lavc -ovc lavc -of mpeg -mpegopts format=dvd:tsaf<br>
   -vf ]]..vfs..[[harddup -srate 48000 -af lavcresample=48000<br>
   -ofps 30000/1001 -channels 6<br>
   -lavcopts vcodec=mpeg2video:vrc_buf_size=1835:vrc_maxrate=9800:vbitrate=5000:keyint=18:vstrict=0:acodec=ac3:abitrate=192:aspect=]]<br>
   ..aspect<br>
<br>
end<br>
<br>
</code></pre>
<br>