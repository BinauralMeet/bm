# CHANGELOG — bm/ ワークスペースの変更履歴

**いつ読むか**: いつ・なぜ今の状態になったか調べる / 過去の動作確認の記録を探す /
変更を加えたので追記する

日付が付く記録はここに。現在形の事実は各 topic README へ。

## 2026-09-25 — 実会議での不具合3件を修正、言語判定をセッション単位に {#2026-09-25-stt-live-fixes}

ユーザーが実際に話してテストしたところ**字幕が出なかった**。原因は3つあり、いずれも
ここまでの検証(注入音声・短い発話)では踏まなかった経路だった。

**1. 認識が自分自身を飢えさせていた。** 発話区間ごとの確定認識を並行に投げ、さらに
開いている区間を1.5秒ごとに再認識していたため、発話より少し速い程度のバックエンドでは
確定結果が8秒のタイムアウトで落ちていた——**話し続けるほど字幕が出なくなる**。
話者ごとに認識を直列化し、**発話より遅いと判明したバックエンドでは途中結果を自動的に
やめる**ようにした(どうせ確定に追い越されて捨てられるのに、確定が必要な処理能力を
食っていた)。`cpuWhisper`のタイムアウトも40秒に。

**2. SenseVoiceには一度も届いていなかった。** 実際のAPIは`POST /transcribe`・
multipart・パラメータ名`language`で、こちらは`/asr`に生WAVを`lang`付きで投げていたため
全て404。差分を`config.js`のエントリ(`upload`/`langParam`/`langAuto`)で吸収できるようにし、
SenseVoiceが混ぜてくるイベント絵文字(🎼など)も除去するようにした。

**3. GPUのモードを実際には見ていなかった。** `GET /status`が2秒でタイムアウトし、
旧コードは「読めない=判断材料なし→とりあえず使う」としていたため、モード比較に到達せず
**切り替え要求が一度も出ていなかった**。タイムアウトを6秒にし、statusが読めないときは
その候補を飛ばすようにした(投げて確かめると毎発話タイムアウト1回ぶん損をする)。

**あわせて言語判定をセッション単位にした**: 発話ごとの自動判定はブレが大きく、
翻訳先もそれに従うので**訳される発話とされない発話が混ざる**——ユーザーからは
「挙動が統一されていない」ように見える。2発話以上・重み付き情報量15以上・6割以上の
優勢が揃って初めて言語を確定し、以後は認識エンジンにも明示的に伝える(自動判定より
精度が上がる)。重みは文字種別(日本語1文字 ≒ 英語2.5文字ぶん)で、英文が長いだけで
英語に倒れないようにした。VADのhangoverも0.5→0.8秒に伸ばし、文中の息継ぎで切らない
ようにした(文脈が増えるほど誤認識は減る)。

字幕の出し方は**「原文を出してから訳文に差し替える」で統一**(ユーザーの選択)。

**結果**: SenseVoice経由で1秒の音声を82〜124ms(CPUの1.2〜2.4秒から10〜30倍速)、
字幕は発話の約2秒後、**途中結果も初めて表示されるようになった**。

## 2026-09-25 — カタカナ語の用語リストが英語の認識を壊していたのを修正 {#2026-09-25-stt-prompt-lang}

無人作業での最終確認中に発見。`WHISPER_PROMPT`(バイノーラル, ミュート, …)を全ての発話に
渡していたため、**英語の "Ask not" が「アースクリーン アースクリーン」になっていた**。
promptはデコーダの文脈そのものなので、日本語の語彙リストは英語の発話を日本語側へ引っ張る。

`WHISPER_PROMPT_LANG=ja`を足し、**その言語の発話にだけ**promptを渡すようにした。
自動判定中(ヒント無し)は渡さない——BM側はセッションで言語が確定してから
明示的に送るので、日本語の会議では2発話目以降に効く。修正後、英語は "Ask not!" に戻り、
中国語字幕も出ることを確認。

## 2026-09-25 — 本番デプロイに向けてホスト作業を整理、GPU認識をLANに公開 {#2026-09-25-stt-deploy-prep}

「本番のmediaから届かせるには`lm.haselab.net`を経由する必要がある。mediaへのインストールも
ホストに任せるので作業をまとめてほしい」。`stt-translation#todo`を本番デプロイ用に書き直し、
5項目(プロキシパス・ffmpeg・config.js・APIキー・lm-tool)にまとめた。

**プロキシは素のHTTPでよい**(ユーザーからの確認質問への回答): BMが叩くのは
`POST <base>/asr?lang=`(bodyは生WAV)の1往復だけで、WebSocketは使わない。
`/SENSEVOICE`と同じ形で足りる。設定上の注意は2点——ボディ上限を1MB以上
(30秒の発話ぶん)、読み取りタイムアウトをBM側の20秒より長く。

**rtx5070tiの待受を`127.0.0.1`から`0.0.0.0`に戻した**。SSHトンネル専用のつもりで
絞っていたが、プロキシは別マシン(LAN)にあるためループバックのままでは公開できない。
既存の`sensevoice`(8189)と同じ露出になる。

## 2026-09-25 — 複数人での遅延を詰め、再接続で字幕が止まる不具合を修正 {#2026-09-25-stt-latency}

「複数人で話すと遅延が苦しい」という指摘への対応。原因は**認識が1本しかないこと**で、
話者が増えるとその数だけ待ち行列ができていた。

- **GPU側で認識を2並列に**(`WhisperModel(num_workers=2)`、waitressのスレッドも合わせる)。
- **途中結果を900ms間隔に**(1500msから)、**VADのhangoverを600msに**(800msから)。
  どちらもCPU認識(発話より遅い)を前提にした値で、GPUでは詰められる。
- **どこで待たされたかをログに出すようにした**(`BM_STT_DEBUG=1`で
  `<sid> <音声長>ms audio, queued <待ち>ms, recognized in <認識>ms`)。
  「自分の前の発話待ち」と「認識が遅い」は外から区別が付かなかった。

ユーザー確認: 「いまは十分早いです」。

**あわせて修正**: メディアサーバー再起動やRTC再接続のあと、**字幕が黙って止まっていた**。
新しいProducerができてもクライアントは`sttStart`を送り直しておらず、しかも
`getLocalMicTrack()`はobservableでないので何も再評価されない——スイッチはONのまま、
字幕だけ出なくなる。5秒ごとに「認識させているProducer」と現在のProducerを比べて、
違っていれば送り直すようにした。

## 2026-09-25 — 中国語・韓国語の翻訳をGPUサイドカーに追加(未配備) {#2026-09-25-stt-multilingual}

「英語にはできたが中国語・韓国語にはできない」。原因はモデルで、CPU翻訳サイドカーは
FuguMT(ja↔enのみ)しか持っていないため、zh/koは応答から省かれ原文のまま残っていた。
認識側はWhisperがzh/koも判定できている。

GPUサイドカー(`gpu_whisper_server.py`)に多言語モデルの`/translate`を足した。
**M2M-100(MIT)を既定**とし、NLLB-200(CC-BY-NC)は`MULTI_KIND=nllb`で切り替え。
ユーザーからは「NLLBを公開で動かして問題なければそれで、ダメならM2Mをzh/ko用に」という
指示だったが、**BinauralMeetは公開サービスなのでNCライセンスはサービス全体に付いて回る**
と判断し、既定をM2Mにした。ja↔enは引き続きFuguMT(どちらより良い)。

**配備完了(同日)**: rtx5070tiで`facebook/m2m100_418M`をCTranslate2へ変換
(`C:\Home\work\gpuwhisper\models\m2m100-418m`、float16)。変換用のtorchはCPUホイールを
入れて終了後に削除、実行時に要るのは`transformers`+`sentencepiece`のみ。
`control_api.py`が`MULTI_MODEL`/`MULTI_KIND`を渡す。

`translation.ts`は**エンドポイントの配列**を順に試し、各エンドポイントには**まだ
埋まっていない言語だけ**を聞くようにした。ja↔enはFuguMT(CPU)、zh/koはGPUのM2M-100。

**動作確認**: 直接叩いて ja→zh/ko/en・en→ja/zh が正しく返ることを確認
(「これは翻訳のテストです。」→「这是翻译的测试。」「이것은 번역 테스트입니다.」)。
BMからのend-to-endでも、英語音声→**中国語字幕**が途中結果付きで出ることを確認。

## 2026-09-25 — GPU版Whisperをrtx5070tiに配備、カタカナ語対策 {#2026-09-25-stt-gpuwhisper-deployed}

「STTの語彙が足りない、カタカナ語がだめ」への対応。ユーザーから「プロキシパスは追加
できないがsshはできるので、5070ti側の修正はやってほしい」という指示があり、GPU機に
直接入って配備した。作業中は`lm-tool lock --machine rtx5070ti`でロックを取得
(BM本体はロックを取らない設計だが、これは保守作業なのでロックが正しい使い方)。

**rtx5070ti側(`C:\Home\work\gpuwhisper\`)**:

- 専用venv + `faster-whisper` large-v3-turbo(CUDA fp16)。スクリプトは
  `bm/stt-sidecars/gpu_whisper_server.py`と同一。
- `control_api.py`に`gpuwhisper`モードを追加(`hidream`/`sensevoice`/`irodori`と同じ扱い、
  `hidream`とだけ排他)。`WHISPER_PROMPT`(カタカナ語の用語リスト)と
  `WHISPER_HOST=127.0.0.1`もここで渡す。編集前に`.bak-<日時>`を作成。
- **ハマった点2つ**(`bm/stt-sidecars/README.md#gpu`に記録):
  (1) Windowsでは`nvidia-*-cu12`ホイールが置く`cublas64_12.dll`をCTranslate2が見つけられない。
  `os.add_dll_directory()`だけでは不十分で、**PATHにも足す**必要がある(素の名前でロードするため)。
  (2) cuBLAS 12.9ホイールだと**推論中にプロセスごとクラッシュ**し、リクエストが無反応のまま
  ぶら下がる。`nvidia-cublas-cu12==12.8.*`(このマシンのtorch cu128に合わせる)で安定。

**経路**: rtx5070tiにはプロキシパスが無いので(ユーザーが追加できないとのこと)、
`start-dev.sh`が**SSHトンネル**(`127.0.0.1:8192`)を張るようにした。鍵が無い環境では
警告だけ出して起動を続ける(その場合は`cpuWhisper`へ落ちる)。

**実測**: 11秒の音声を約0.3秒。SenseVoiceが断片(「ASK NOT!」「What your country can do」)
だったのに対し、**句読点付きの1文**("And so, my fellow Americans, ask not what your country
can do for you, ask what you can do for your country.")として返る。BMからのend-to-endでも
`using backend 'gpuWhisper'`・**途中結果あり**・訳文ありを確認。

`config.js`の`stt.backends`は`gpuWhisper`→`cpuWhisper`の順にした。SenseVoiceはコメントで
残してある。**同じGPU上の複数バックエンドに`gpuMode`を設定してはいけない**(互いに自分の
モードへ切り替え合う)ことも設定コメントに書いた。

## 2026-09-25 — カタカナ語対策としてGPU版Whisperのサイドカーを用意 {#2026-09-25-stt-gpu-whisper}

「STTの語彙が足りない、特にカタカナ語がだめ」という指摘。SenseVoice-smallは高速だが
言語モデルを持たずホットワード指定もできないため、外来語・固有名詞は構造的に弱い。

`bm/stt-sidecars/gpu_whisper_server.py`(faster-whisper large-v3-turbo、CUDA)を追加した。
`cpu_whisper_server.py`と同じ契約なので**BM側は`stt.backends`に1エントリ足すだけ**で切り替わる。
両whisperサイドカーは`initial_prompt`(環境変数`WHISPER_PROMPT`、またはリクエスト
パラメータ`prompt`)を受け付けるようにし、その場でよく出る用語を渡せるようにした。

**未配備**。GPU機側に(a)`control_api.py`のモード追加、(b)`lm.haselab.net`のプロキシパスが
要る(`stt-translation#todo`の1、手順は`bm/stt-sidecars/README.md#gpu`)。
それまでは`sensevoice`+`cpuWhisper`のまま動く。

## 2026-09-25 — 字幕を読める長さに、GPUは空いていれば切り替える {#2026-09-25-stt-bubble-gpu}

ユーザーの指示3点。

**1. 表示時間を文字数に比例させた**(`stt-translation#bubble`)。固定4秒では長い文を
読み切れなかった。2.5秒 + 1文字0.14秒(上限25秒)。

**2. 話し続けている間は吹き出しがつながって伸びるようにした。** 直前の発話の終わりから
次の始まりまでの無音が2.5秒以内なら同じひと続きとして連結し、140文字を超えたら古い方から
落とす。

ここで**バグを1つ見つけた**: 最初は到着時刻で「ひと続き」を判定していたが、
CPU認識は発話より2〜4秒遅れて届くため**常に「間が空いた」と判定され、連結が一度も
起きなかった**(実機で確認)。認識の遅れは発話の長さによって変わるので、到着間隔からは
話し続けているかどうかは原理的に分からない。サーバーが発話の終了時刻と長さを
`SpeechText.ts`/`durationMs`として載せるようにし(`MSSttResultMessage`も同様に拡張、
VADの`end`イベントが持っている値をそのまま流す)、無音の長さを直接計算する形に変えた。
**消えるまでの時間はローカル時計のまま**——視聴者が見始めた時刻が基準なので、
ここにサーバー時計を混ぜると時計ズレぶん表示時間が狂う。

**3. GPUがロックされていなければモード切り替えを試みるようにした**
(`stt-translation#fallback`)。`gpuMode`を設定したバックエンドは、`active_modes`に
自分のモードが無ければ`POST <gpuStatus>/activate/<gpuMode>`を投げる。切り替えは
発話1つ分では終わらないのでその発話は次の候補へ落とし、3分に1回までに制限、
元のモードへは戻さない。ロック中は今までどおり何もしない。
`config.js`の`sensevoice`に`gpuMode: 'sensevoice'`を設定済み——
**次にGPUが空いている状態で会議を始めると、rtx5070tiは`hidream`から`sensevoice`へ
切り替わる**(= ComfyUIは止まる)。当初の「他人の作業を止めない」設計からの方針変更。

**動作確認**: 実音声(`jfk.wav`ループ)で吹き出しが1→2→3→4発話と伸び、
話し終わると消えることを確認(`logs/stt-e2e-interim.png`、70文字で約12秒表示)。
GPU側は**実際の切り替えを起こさずに**読み取り経路だけ確認した——既に動作中の
`hidream`を`gpuMode`に指定して`sttBackendLive.ts`を実行し、
`/lock/status`と`/status`が正しく読めること・`active_modes`に含まれるモードでは
`/activate`を投げないこと・実行後もモードが`hidream`のままであることを確認。
切り替え自体のロジックは偽のGPU APIに対する単体テストで押さえた(server 48件)。

## 2026-09-25 — 音声から字幕まで実機で一本通した {#2026-09-25-stt-e2e}

コンテナにも`ffmpeg`が入り、最後の欠落が埋まった。**実際の音声を通話に流して、字幕と
訳文が出るところまで確認した**(これまでは`sttResult`を注入した半分だけの確認だった)。

**やり方**: headful Chromeの前に話す人はいないので、ページ内でWAV(whisper.cppの
`jfk.wav`、11秒の英語スピーチ)を`AudioContext`でループ再生して
`MediaStreamAudioDestinationNode`のトラックを作り、`conference.setLocalMicTrack()`で
マイクと差し替えた。`addOrReplaceLocalTrack()`は既存Producerを`replaceTrack`で使い回すので、
サーバーが見ているProducer idは変わらない。字幕言語は`ja`、話す言語は`auto`。

**結果**(英語音声 → 日本語字幕、`logs/stt-e2e-long.png`):

| 認識(en) | 訳文(ja) |
|---|---|
| And so, my fellow Americans. | そして、私の仲間のアメリカ人。 |
| ASK NOT! | 聞かないで! |
| What your country can do for you! | あなたの国があなたのために何ができるか! |

`media`のログで`stt: session started ... (lang auto)`→`stt: using backend 'cpuWhisper'`を確認。
**`sensevoice`(GPU)から`cpuWhisper`への縮退が実運用で働いている**——rtx5070tiが
`sensevoice`モードではないので、設計どおり黙って次の候補へ落ちている。

**分かった制限**: **途中結果(`SPEECH_INTERIM`)が利用者には一度も見えない。**
30秒間400ms間隔で監視しても未確定の発話は0件だった。CPUのfaster-whisper smallは
1秒の音声に1.2〜2.4秒かかり(実測)、1.5秒ごとの再認識が返る頃には区間が閉じていて、
`segment.closed`で捨てられるため。設計どおりの挙動ではあるが、
**`interimIntervalMs`はGPUバックエンドが繋がるまで実質無効**。
`stt-translation#limits`に記載した。

VADは無音0.5秒で切るので、字幕は文の途中でも切れる(上表の2行目・3行目)。
`hangoverMs`で調整できるが、長くすると字幕が出るまでの待ちが伸びる。

## 2026-09-24 — 実サイドカーで検証、残るはコンテナ内の`ffmpeg`だけ {#2026-09-24-stt-ffmpeg-container}

`stt-sidecar-docker0-expose`でサイドカーがコンテナから届くようになったので、モックを外して
**実物**に対してBM側のコードを通した。

**実サイドカーで確認できたこと**:

- `sttBackendLive.ts http://172.17.0.1:8190/asr`: `lang=auto`ではパラメータを送らず
  whisperの自動判定結果(`en`)が返る、`lang=ja`ではヒントが渡り`ja`が返る。
  **`lang=auto`修正(`#2026-09-24-stt-sidecar-contract`)が実物に対しても正しい**ことを確認。
  1秒の音声で1.2〜2.4秒かかる(CPU、faster-whisper small)。
- `translationLive.ts http://172.17.0.1:8191/translate`: 「これは翻訳のテストです。」→
  "This is a translation test."。同一文の2回目はキャッシュから1ms、ko→enは応答から省略、
  全員同じ言語の部屋では1回も呼ばない。
- CDP実機: 設定を保存→リロード→入室(以降設定に触れない)→`sttResult`(ja)を注入すると、
  **実翻訳がチャット欄と字幕に出る**。ページエラーなし。

**残った1点**: `ffmpeg`はホストには入っているが、**sandboxコンテナの中には無い**。
`media.ts`はコンテナ内で動くので、開発チェックアウトでは音声取り出しが動かない。
STTを有効にして実機で追ったところ、サーバーは要求を**受理**し(クライアントへの拒否なし)、
PlainTransport+Consumerまで作った上で`sttFFmpeg::error [error: spawn ffmpeg ENOENT]`で
失敗し、セッションを畳んで通話には影響しなかった——**欠けているのはffmpegだけ**と確定。
コンテナへの入れ方の選択肢は`stt-translation#todo`の1にまとめた。

## 2026-09-24 — 翻訳が一度も走らないバグを修正(字幕言語を入室時に通知していなかった) {#2026-09-24-stt-lang-on-join}

headful Chromeを再起動してもらいCDP確認を再開したところ、**翻訳が1件も走らない**ことが
分かった(モックへのリクエストがゼロ)。`d.conference.dataConnection.sendMessage('p_lang',
{speak:'ja',show:'en'})`をページから手で送ると翻訳される一方、`d.settings.sttShow`を
変えるだけでは送られない、という切り分けから原因を特定した。

**原因**: `SttClient`が`PARTICIPANT_STT_LANG`をMobXの`autorun`からしか送っておらず、
その`autorun`は`conference.dataConnection.isConnected()`が偽の間は早期returnしていた。
**接続状態はobservableではない**ため、`enter()`中の初回実行(まだ接続前)が最後の実行に
なる。字幕言語はlocalStorageから入室前に復元されるので、**戻ってきた利用者は設定を
一度も「変更」せず、結果として誰も翻訳先言語を申告しない**——サーバーから見ると
部屋の全員が翻訳不要に見える。

**修正**: `DataSync.sendAllAboutMe()`(接続時と`REQUEST_ALL`/`REQUEST_TO`で
ローカル参加者の状態を publish する既存の場所)から送るようにした。`autorun`は
会議中の変更用として残し、同じ値を再送しないようにした。
コミット`binaural-meet` `e376e18`。

**動作確認**: 設定を保存→リロード(=起動時にストレージから復元される状態)→入室、
以降**設定に一切触れず**に`sttResult`(ja)を送り、翻訳が届いて字幕が英語に
なることを確認(`logs/stt-translate-onjoin.png`)。モデルの無いko→enは
応答から省略され原文のまま残ることも同時に確認。ページエラーなし。

## 2026-09-24 — サイドカーとの契約を実機確認、`lang=auto`のバグを修正 {#2026-09-24-stt-sidecar-contract}

`stt-hostwork-sidecars`で用意されたサイドカーに対して、BM側のコードが本当に
その契約どおり喋るかを確認した。**両サイドカーはホストの`127.0.0.1`でのみ待受けており、
sandboxコンテナからは届かない**(`172.17.0.1:819x`も不可)ため、同じ契約を実装した
モックをコンテナ内に立てて`SttBackend`/`translation.ts`を実HTTPで通した。

**見つけて直したバグ**: `SttBackend.transcribe()`が`lang`をそのまま送っていたため、
BMの既定である`'auto'`が言語コードとしてサイドカーへ渡り、faster-whisperが
弾いて500になっていた(`cpu_whisper_server.py`の契約は「空なら自動判定」)。
**既定設定のままでは`cpuWhisper`が毎回失敗し、3回でサーキットブレーカーが開く**という
経路だった。`'auto'`はパラメータごと送らないように修正し、あわせて応答の`lang`
(自動判定の結果)を採用するようにした——これが無いと`collectTargetLangs()`が
「原文の言語が不明」と判断して翻訳が一切走らない。
モックへの`POST /asr?lang=auto`が実際に500、パラメータ無しが200になることも確認済み。

確認できたこと(`logs/mock-sidecars.log`):
WAVの組み立てが`RIFF`/16000Hz/1ch/16bit/44バイトヘッダで正しいこと、
`lang=ja`指定時だけパラメータが付くこと、翻訳が同一文で**2回目はキャッシュから返り
バックエンドを叩かない**こと、未対応ペア(ko→en)は応答からキーごと省略され
**何もブロードキャストされない**(字幕が原文のまま残る)こと、
全員が同じ言語の部屋では**バックエンドを1回も呼ばない**こと。

**`start-dev.sh`を修正**: `/opt/lm-tool/lm-tool.env`を読み込んでから`media`を起動する
ようにした。`LM_HASELAB_API_KEY`が環境変数として入っていないと`sensevoice`へ
無認証で投げて弾かれ、「GPUが塞がっている」のと区別が付かない失敗になるため。

**この日以降できなくなったこと**: headful Chromeの新しいタブが読み込み中に
クラッシュするようになり、CDP経由の実機確認が通らない。ホストの空きメモリが
16GB中2.9GB・swapなしまで落ちており(常駐サイドカーがモデルを抱えている)、
WebGL/VRMを使うBMクライアントのレンダラが確保できていないのが原因と見られる。

## 2026-09-24 — STT・翻訳字幕を実装 {#2026-09-24-stt-translation-implemented}

`stt-translation`の設計に沿って3リポジトリに実装した(書き出し機能を除く)。
コミットは`bm` `5acde08`(設計doc)、`bmMediasoupServer` `7ff08cf`、
`binaural-meet` `c551d55`。いずれも`feature/stt-translation`ブランチ。

**動作確認**: `ffmpeg`がこのコンテナに無いため音声取り出しは動かせない
(`stt-translation#limits`)。そこで**workerのふりをして`sttResult`を直接main serverへ
送り**、認識結果から字幕までを実機で確認した:

1. `start-dev.sh`で4プロセス起動、CDPで`?room=sttverify`に入室。
2. Nodeから`ws://localhost:3100`に接続し`workerAdd`で登録、直後に
   `workerUpdate`で`load: 1e9`を報告(これを忘れると`getVacantWorker()`が
   本物のpeerをこの偽workerへ回してしまう)。
3. `sttResult`を送って確認できたこと: 途中結果が吹き出しに出る →
   同じ`sid`の確定結果が**同じ発話を上書き**する(2件に増えない) →
   **連続した確定結果2件が両方届く**(`Stores.ts`のマージ除外が効いている) →
   後から来た訳文がチャット欄の既存行を**その場で書き換える** →
   バックエンド未設定で`sttStart`すると`stt is not configured on this server`が
   返りクライアント側のスイッチが自動でオフに戻る。ページエラーなし。
4. 発見して直したバグ1件: 吹き出しが1文字幅の縦棒になっていた。参加者のルートdivが
   0x0で、絶対配置の子が幅を解決できていなかった(`width: max-content`で修正)。
   スクリーンショット: `logs/stt-final.png`、`logs/stt-translated.png`。

未確認のまま残っているのは**音声取り出しと認識サイドカーとの疎通**で、これは
ホスト側の準備(`stt-translation#hostwork`)が要る。

## 2026-09-24 — STT・翻訳字幕の設計を新設(サーバー側認識に決定) {#2026-09-24-stt-translation-design}

BMに音声認識と翻訳を付けたいという要望から、3リポジトリに跨る設計を
`stt-translation` として新設した(実装はまだ無い)。

最初の案はChromeのWeb Speech APIをクライアントで使うものだった。このホストには
GPUが無く(16コアCPUのみ)、GPU機(rtx4090/rtx5070ti)は`lm-tool`の排他切り替え+
ロック制で会議中ずっとは押さえられないため、「無料・ローカル」の条件下では
CPUのWhisper smallよりWeb Speech APIの方が日本語の精度・遅延とも上、という判断だった。
**ユーザーの指示でサーバー側認識に変更**: Web Speech APIは`MediaStreamTrack`を
受け取れずOS既定のマイクを掴むため、BMで別デバイスを選んでいるとSTTだけ違う音を
聞く問題があり、これが回避不能だったのが決め手(`stt-translation#design`)。
rtx5070tiをバックエンドに使ってよい、という方針もここで決まった。

サーバー側認識の経路は`bmMediasoupServer-rtsp-streaming`のPlainTransport+ffmpegを
流用する。GPUの扱いもユーザーの指示で決めた: **ロックは取らず、塞がっていれば
諦めてCPUへ縮退する**(`stt-translation#fallback`)。会議は長く、その間GPUを
占有したくないため。ホスト側で用意が要るもの(認識・翻訳サービスのHTTPパス等)は
`stt-translation#hostwork` に集約した — 別途設定する。

## 2026-08-05 — bmMediasoupServer/vrcssにもdocsを新設 {#2026-08-05-bmms-vrcss-docs-added}

残っていた2リポジトリにも`docs/bin`(doc-tool)を導入し、実コードを読んで
`bmMediasoupServer-architecture`/`bmMediasoupServer-rtsp-streaming`/
`vrcss-screen-sharing`を新設(自動集約されるので`bm`側の変更は無し)。
これで3リポジトリ全てが同じ仕組みでdocsを持つ状態になった。

## 2026-08-05 — doc-toolにsubmodule集約を実装し、binaural-meetのdocsを本体に移動 {#2026-08-05-doc-tool-submodule-aggregation}

`docs/binaural-meet/` にあった6つのdocs(architecture / development-guide /
testing-guide / shared-contents / auto-load-adjustment-design /
refactoring-plan-done)を `binaural-meet/docs/` に移した。あわせて
`binaural-meet` にも `docs/bin`(doc-tool)を導入し、単体cloneでも
`docs/bin/doc` が使えるようにした。

`bm/docs/bin/doc` 側は `load_all()` を追加し、`.gitmodules` に載っている
submoduleが自分の `docs/CHANGELOG.md` を持っていれば自動的にそのdocsを索引に
混ぜるようにした(`ForHuman#workspace`)。topic idは移動前と同じ
`binaural-meet-architecture` 等のまま変わらない。詳細・撤回した旧方針の理由は
`workspace` の設計判断の記録を参照。

## 2026-07-28 — binaural-meet と bmMediasoupServer を bm/ に集約 {#2026-07-28-workspace-consolidation}

それまで `binaural-meet` 単独で `/home/hase/sandhome/binaural-meet` に、
`bmMediasoupServer` は Claude から触れない場所にあった。両方を `bm/` 直下に集約し、
以後は組み合わせワークスペースとして扱う方針にした。モノレポ化はしていない
(2リポジトリ+vrcssはそれぞれ独立した git リポジトリ・remoteのまま)。

## 2026-07-28 — ROOM_PROPのキューイング衝突バグ修正 {#2026-07-28-room-prop-fix}

`DataConnection.sendMessage()` が未送信メッセージを `(type, room, peer, dest)`
だけで一本化していたため、`ROOM_PROP`(名前の異なる複数プロパティを多重化する
唯一のメッセージ種別)で異なるプロパティを連続設定すると後者が前者を握り潰して
いた(例: AdminConfigForm の「Default」ボタンが `backgroundFill` の次に
`backgroundColor` をリセットすると片方が消える)。`ROOM_PROP` に限りプロパティ名
も一致条件に加えて修正(ワイヤーフォーマット変更なし)。CDPで実機検証済み。
コミット `fb280c4`(binaural-meet)。

## 2026-08-01 — ホスト名リネームと Node アップグレード {#2026-08-01-host-rename-node-upgrade}

開発用ホストの名前が変わった(旧名から `test.binaural.me` に改名)。コンテナの
Node は 20.20 で要件(vite8/vitest4/jsdom29 の `engines`、`≥20.19`)を満たすが、
ホスト自身は 22 にアップグレードした。ホスト名リネームの副作用として headful
debug Chrome のプロファイルが古いホスト名を刻んだ `SingletonLock` シンボリック
リンクを持っていたため起動しなくなり、`~/.chromedbg-profile/Singleton{Lock,Socket,Cookie}`
を削除して復旧(恒久的な注意点として dev-environment#limits にも記載)。

## 2026-08-02 — VRM アバター一覧のCORSブロックを修正 {#2026-08-02-vrm-cors-fix}

アバター配布元(`binaural.me` 上の `/public_packages/uploader/`)がこのワーク
スペースの動作先ホストと別オリジンになり、CORSでアバター一覧が空になっていた。
配布側 nginx に `Access-Control-Allow-Origin * always` を追加して解消。
クライアント側のCORSプロキシへのフォールバックは残っているが、そちらは
許可オリジンのホワイトリスト制なので、この nginx ヘッダーが本来の直し方。

## 2026-08-02 — mediasoup UDPポート枯渇によるクラッシュを修正 {#2026-08-02-port-exhaustion-fix}

未処理の Promise rejection がポート枯渇時に media サーバーをクラッシュさせて
いた。原因の一部は CDP テストスクリプト(smoke.mjs / repro-avatar.mjs)が失敗時
にタブを閉じずに残し、その WebRTC transport がUDPポートを保持し続けていたこと。
スクリプト側で前回タブのクリーンアップを追加し、サーバー側も unhandled rejection
でクラッシュしないよう修正。

## 2026-08-04 — docs/bin を doc-tool サブモジュールに切り替え {#2026-08-04-doc-tool-submodule}

`docs/bin/doc` はこれまで devsandbox ホストの `doc` スクリプトを手動でフォークして
このリポジトリに直接コミットしていた。配布元が `haselab-net/doc-tool` として独立
したため、`docs/bin` を git submodule(`https://github.com/haselab-net/doc-tool.git`)
に置き換えた。あわせてそのリポジトリの `USERMAN.md` を初回導入コピーとして
`docs/USERMAN.md` に追加(`docs/README.md` は既に手動フォーク版が存在し内容が
実質同等だったため上書きせず維持)。ツール本体の更新は
`git submodule update --remote docs/bin` で追従する。

## 2026-08-04 — doc-tool 更新に追従(USERMAN.md → ForHuman.md) {#2026-08-04-doc-tool-forhuman-rename}

`git submodule update --remote docs/bin` で doc-tool を追従(`USERMAN.md` を
`ForHuman.md` にリネームし配布元ナラティブを削った変更)。`doc` 本体の
`META_ORDER` がトピックid `ForHuman` を前提にしたため、`docs/USERMAN.md` を
`docs/ForHuman.md` にリネームして upstream 版で上書きし、`docs/README.md` の
`USERMAN` 参照も追従。

## 2026-09-24 — STT認識・翻訳サイドカーのホスト側準備4点を用意・`config.js`へ配線 {#stt-hostwork-sidecars}

`stt-translation#hostwork` の4点(認識サービス・ロック読み取り・翻訳サービス・
`cpuWhisper`縮退サイドカー)を調べたところ、1・2(SenseVoice `/SENSEVOICE/`・
`/SWITCH5070TI/lock/status`)はBMとは別の目的(`lm-tool`のGPU切り替え機能、
`CHANGELOG-006#lm-tool-gpu-lock`)で既に`lm.haselab.net`に公開済みだった。
3・4(翻訳・`cpuWhisper`)は未着手だったため新設した。

**3・4: `bm/stt-sidecars`(新しい兄弟リポジトリ、`binaural-meet`/`bmMediasoupServer`とは
別、`stt-translation#files`の「(別リポジトリ)STT/翻訳サイドカー」)**——コードは
`~/sandhome/bm/stt-sidecars`(git管理)、venvと変換済みモデルは`/opt/lm-tool`と同じ
考え方で`/opt/stt-sidecars/{venv,models,hf-cache}`(git管理外、`scripts/convert_models.sh`で
再現可能)。

- `cpu_whisper_server.py`: faster-whisper `small`(CPU int8)、`POST /asr?lang=<hint>`。
  実音声(whisper.cppのサンプル`jfk.wav`)で正しい書き起こしを確認。
- `translate_server.py`: CTranslate2 + `staka/fugumt-{ja-en,en-ja}`(HFの
  `Helsinki-NLP/opus-mt-en-jap`ではない——理由は`bm/stt-sidecars/README.md#models`、
  JW300学習で会話文だと無関係な訳文になることを実機で確認したため差し替えた)。
  `POST /translate {texts,src,dsts} -> {lang:[...]}`。
- 両方とも systemd ユニット(`stt-cpu-whisper.service`・`stt-translate.service`、
  `bm/stt-sidecars/systemd/`からこのホストの`/etc/systemd/system/`へコピー、
  `User=hase`、`127.0.0.1`のみ待受・認証なし)。共有ホストなので
  `Nice=10`・`CPUWeight=30`・`MemoryMax`(2G/1G)で他ユーザーの作業を圧迫しない設定。

```sh
# /opt/stt-sidecars/ セットアップ(bm/stt-sidecars/README.md の手順そのもの)
python3 -m venv /opt/stt-sidecars/venv
/opt/stt-sidecars/venv/bin/pip install -r requirements.txt
./scripts/convert_models.sh
/opt/stt-sidecars/venv/bin/pip uninstall -y transformers torch  # 変換専用、実行時は不要
cp systemd/stt-cpu-whisper.service systemd/stt-translate.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now stt-cpu-whisper stt-translate
```

`bmMediasoupServer/config.js`(このリポジトリの開発チェックアウト、feature/stt-translation
ブランチ。本番配置`/root/webapp/bmMediasoupServer`、`vrc-jp#files`、へは未反映・未デプロイ)
の`stt.backends`に`sensevoice`(既存の`/SENSEVOICE/`・`/SWITCH5070TI`)と`cpuWhisper`
(`http://localhost:8190/asr`)、`translation.endpoint`に`http://localhost:8191/translate`を追加。

**動作確認**: `curl`で`http://127.0.0.1:8190/health`・`8191/health`が200、
`POST 8190/asr`(`jfk.wav`)が正しい英文書き起こし、`POST 8191/translate`が
ja→en/en→jaとも自然な訳文を返すことを確認。`systemctl restart`後も同じ結果
(モデルは`/opt/stt-sidecars/hf-cache`・`models/`からのみロードされ、
`transformers`/`torch`をアンインストール後も影響しないことを確認)。
`sensevoice`(`https://lm.haselab.net/SENSEVOICE/asr`)は未検証——rtx5070tiの共有GPUを
`sensevoice`モードに切り替える必要があり、BMは自分ではモード切り替えをしない設計
(`stt-translation#fallback`)なので、他の用途(確認時点は`hidream`が使用中)を止めてまで
試していない。`cd bmMediasoupServer && npx vitest run`(既存40件)は無変更で全通過。

## 2026-09-24 — STTサイドカーをコンテナから到達可能にし、`config.js`を`localhost`から切り替え {#stt-sidecar-docker0-expose}

`stt-translation#hostwork`の残作業のうち「サイドカーをコンテナから届くようにする、または
開発中は使わないと決める」(判断が要ると明記されていた項目)、ユーザーに確認の上、
届くようにする方を選んだ。

**やったこと**:

- `bm/stt-sidecars/cpu_whisper_server.py`・`translate_server.py`: `waitress.serve(host=
  '127.0.0.1', ...)` を `serve(listen='127.0.0.1:PORT 172.17.0.1:PORT', ...)` に変更
  (waitress 3.0.2は`listen=`でスペース区切りの複数`host:port`を受け付ける)。`172.17.0.1`は
  docker0のホスト側アドレスで、ヘッドフルChromeのCDPプロキシと同じ経路
  (`headful-chrome#security`)。
- `ufw allow in on docker0 to any port 8190 proto tcp` / 同 `8191`(このホストの
  既存パターン、`CHANGELOG-001#chrome-per-user`・`CHANGELOG-002#portfwd`と同じ形)。
  公開インターフェースには開けず、docker0経由(=このホストの全sandboxコンテナ)限定。
- `bmMediasoupServer/config.js`: `stt.backends[1].endpoint`と`translation.endpoint`を
  `http://localhost:8190(8191)/...` から `http://172.17.0.1:8190(8191)/...` に変更。
  この開発チェックアウトは`start-dev.sh`によりsandboxコンテナ内で動くため、`localhost`では
  コンテナ自身を指してしまいホストのサイドカーに届かなかった(`172.17.0.1`はホストからも
  コンテナからも同じアドレスとして機能するため両対応)。
- 両systemdユニットを`systemctl restart`。

**動作確認**: `systemctl is-active`で両ユニットが`active`、`ss -ltnp`で`127.0.0.1`と
`172.17.0.1`の両方でLISTENしていることを確認。`docker exec devbox-hase curl
http://172.17.0.1:8190/health`・`:8191/health`がともに200(コンテナ内からの到達を実機確認)。

**トレードオフ**(ユーザー確認済み): この2ポートは認証が無いため、同ホストの全sandbox
コンテナ(全ユーザー)から無認証で叩ける状態になった。詳細・受け入れた理由は
`bm/stt-sidecars/README.md`「Known limits」。

## 2026-09-26 — ai4にfaster-whisper `medium`を追加、CPUフォールバックを2段構成に {#ai4-cpu-whisper-medium}

ユーザーから: 「ai1と同じ構成のPCがあと3台ある、活用できれば」「CPUでもう少し大きなSTT
モデルを動かせるか、動かせるならai4を使えるようにしてほしい」。ai1自体はメモリが逼迫
していて(swap使い切り、`earlyoom`がベンチ中のプロセスを実際にSIGTERM)大きいモデルを
乗せる余地が無いことを実機で確認、一方ai4は同一ハードウェア(i7-11800H)で
ほぼ無負荷(コンテナ無し、空きメモリ12GB超)だったため、ai4に専用の
`cpuWhisper`(faster-whisper `medium`)を立てて`stt.backends`に追加した。

**ベンチマーク**(`jfk.wav`、11秒、int8):

| モデル | マシン | スレッド数 | 実時間比 |
|---|---|---|---|
| small | ai1 | 4 | 0.24倍 |
| medium | ai4 | 8 | **0.45倍(採用)** |
| medium | ai4 | 16(HT込み) | 0.70倍(HTまで使うとむしろ悪化) |
| large-v3 | ai4 | 16 | 1.07倍(ほぼリアルタイム限界、今回は見送り) |

`medium`・8スレッド(物理コア数)を採用。smallより明確に精度が上がり、まだ実時間の
2倍以上速い。

**やったこと**:

- ai4: `python3-venv`導入、`/opt/stt-sidecars/{venv,hf-cache}`(`hase`所有)を作り
  `bm/stt-sidecars/cpu_whisper_server.py`をそのまま配置(コード変更なし、環境変数
  だけで`medium`を選択)。`stt-cpu-whisper.service`(`CPU_WHISPER_MODEL=medium`・
  `CPU_WHISPER_THREADS=8`)をsystemdで常駐、`127.0.0.1`・`172.17.0.1`双方で待受け
  (ai4自体はdocker0を使わないため後者は実質無害)。
- **ai1→ai4の到達経路はSSHトンネルのみ**(ai4のufwにはこのポート用の穴を一切開けて
  いない)。ai1の`root`に新しい専用鍵ペア(`id_ed25519_ai4-stt-tunnel`)を作り、
  ai4の`hase`アカウントの`authorized_keys`に
  `command="/bin/echo restricted: port-forwarding only",restrict,port-forwarding,
  permitopen="127.0.0.1:8190"`付きで登録——ポートフォワード以外(シェル実行・
  他ポートへの転送)は一切できない。**注意点**: `restrict,port-forwarding`だけでは
  対話シェルだけが防げず`ssh host cmd`のような非対話コマンド実行は素通りしてしまう
  ことに気づき、`command=`で強制コマンドを追加して塞いだ(実機で`ssh ... whoami`が
  素通りすることを確認してから修正、修正後は強制コマンドの出力だけが返ることを確認)。
  `permitopen`で指定ポート以外への転送も実際に中身が届かない(TCP接続はローカルで
  受け付けるが相手からのバイトが来ない)ことを実機確認。
- ai1: `ai4-stt-tunnel.service`(systemd、`Restart=always`)が`ssh -N`で
  `127.0.0.1:8193`・`172.17.0.1:8193`をai4の`127.0.0.1:8190`へ転送。
  `ufw allow in on docker0 to any port 8193 proto tcp`(このホストの既存パターン、
  `CHANGELOG-002#portfwd`等と同じ形)。
- `bmMediasoupServer/config.js`: `stt.backends`に`{kind:'cpuWhisper',
  endpoint:'http://172.17.0.1:8193/asr'}`を追加。並び順は
  `gpuWhisper`(GPU、最優先)→ ai4の`cpuWhisper`(medium、この行)→
  ローカルの`cpuWhisper`(small、常時利用可能な最終フォールバック)。**この並び順
  自体が挙動を決める**(先に見つかった到達可能なものが使われるため、smallを先に
  書くと常時到達可能なsmallが常に勝ってしまいmediumが使われなくなる)。

**動作確認**: `docker exec devbox-hase curl http://172.17.0.1:8193/health`が200、
同じくコンテナ内から`POST /asr`(`jfk.wav`)で正しい書き起こしを確認。
`node -e "require('config.js')"`で構文確認。既存の`cpuWhisper`(small)・
`translate`との共存(ポート番号の衝突)が無いことも確認済み——`config.js`には
並行して別セッションが`gpuWhisper`用に`127.0.0.1:8192`のトンネルを追加していたため、
ai4用のポートは最初8192で作ってしまい衝突に気づいて8193に変更した経緯あり。

**現在残っているもの**: ai2・ai3(ai4と同じ「予備機」)は未使用のまま。同じ手順で
複製可能。本番(`vrc-jp`)側の`stt.backends`にこの構成を含めるかは別判断
(`#hostwork`の`#todo`は現状GPU経路の生やし方のみを扱っている)。
