# 追加情報 #

  * 次の理由から Mencoder は最新ビルドではなく、mencoder.exe (rev33883) と mencoder2.exe(rev35224) を配布しております。<br>なお、CSS 解除機能を有するソフトウェアの配布は法律で禁止されているため、配布している mencoder.exe、mencoder2.exe には CSS の解除機能がありません。<br>
<ol><li>Mencoder の最新ビルド（2012/12/12現在）では、当方で試す限り、mpg(mpeg2+AC3) へのエンコード時に音ずれが発生する場合があります。rev33883 ではその症状は発生しません。<br>なお、-vf オプションから harddup を外すか、fixpts を加える（-vf fixpts,harddup とする）か、pullup を加える（-vf pullup,harddup とする）か、あるいは -ofps 24000/1001 とすると最新ビルドでも音ずれは少なくなるようです。どうにもバグくさいですし、副作用が怖いのでそれらの設定をデフォルトにするのは見送っています。<br>
</li><li>Mencoder の最新ビルドでは、当方で試す限り、mpg(mpeg2+AC3) へのエンコード時に音声がただのノイズになるという症状が発生する場合があります。Paehl Build rev35224 や Subjunk Build 46 や Panasony Build(from PMS for VIERA 1.63.0) であればその症状は発生しません。<br>なお、ノイズにより再生機器や視聴者に障害が生じる恐れがありますので mencoder.exe を入れ替える方は注意してください。<br>なお、-lavcopts 内の acodec=ac3 という部分を acodec=ac3_fixed とすれば少しましになりますが・・・<br>
</li><li>Subjunk Build 46 や Panasony Build(from PMS for VIERA 1.63.0) では、当方で試す限り、mp4 へのエンコード時に音ずれが発生する場合があります。Paehl Build rev35224 ではその症状は発生しません。</li></ol></li></ul>

<ul><li>204氏によりますと、ブラビア EX700 では、DLNA.ORG_PN=AVC_TS_HD_60_AC3_ISO の指定で、AC-3 音声以外も再生できるとのことです。<br>
</li></ul><blockquote>同じ機種の方は、BRAVIA-KDL-JP5.lua 内の<br>
<pre><code>        if minfo.Video.Format == "AVC" and minfo.Audio.Format == "AC-3" then<br>
</code></pre>
という箇所（１箇所しかないはずです）を<br>
<pre><code>        if minfo.Video.Format == "AVC" then<br>
</code></pre>
に変更してお試しください。もっとも、AAC 音声の場合は、DLNA.ORG_PN=AVC_TS_JP_AAC_T を使う方がよいのかもしれません。なにせ資料が不足していますのでいろいろ試してみていただけると助かります。</blockquote>

<ul><li><a href='BRAVIA5_230.md'>BRAVIA5_230</a> - BRAVIA-KDL-JP5.lua で、H264ToMpegTS = true としてもうまくいかない方は参照してください。</li></ul>

<ul><li>DNS での名前解決に時間がかかる環境で、BMS の反応速度が著しく低下するという症状を確認しました。最新版で対策済みです。うちでは Windows 7 にするとそのような症状になりました。</li></ul>

<ul><li>Windows7 において、Windows の起動から一定時間（1分ぐらい？）経過しないと、ネットワーク通信の一部の機能が正常動作しないためか、BMS が無反応になってしまうという症状が出る場合があるようです。最新版で対策を入れてみましたのでお試しください。</li></ul>

<ul><li><a href='MP4.md'>MP4</a> - MP4 のストリーミング再生について。</li></ul>

<ul><li>ビットレートが高い動画をカクカクさせずに再生させるためには、当然それなりのPC環境が必要になります。例えば 20Mbのビットレートの動画をストリーミング再生するためには、1秒間に20Mb以上読み込めるHDDと、1秒間に20Mb以上の速度で転送できるネットワーク環境が必要であるのは当然です。仮に平時にはその要件が満たされていたとしても、裏でウィルスチェックソフトや自動バックアップソフトなどが動作したために、それらの要件が確保できなくなる可能性もあります。特に、同一のHDDに頻繁にアクセスするソフトが競合すると、速度低下が顕著になるようです（動画再生の際にBMSがファイルをロックするようにすると若干読み出し速度が上がる可能性があるのですが、そうすると逆に他のソフトからのアクセスが遅くなる可能性があるためロックしないようにしています）。なお、動画のビットレートは付属の MI.exe で調査できます。