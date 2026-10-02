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

## 2026-09-26 — 言語の切り替えに追従、サイドカーをBinauralMeet組織に公開、ブランチをマージ {#2026-09-26-stt-lang-switch}

ユーザーから3点。

**1. 「言語は切り替わります。1分以内に追従してほしい」**: 当初は「一度決めたら戻さない」
設計にしていた(1文の聞き間違いで判定が飛ぶ方が多いと考えた)。実際には話者は切り替えるので、
**証拠を半減期20秒で減衰**させる形にした。`bmMediasoupServer` `8f10cc5`。

**その直後にユーザーから訂正**: 「減衰は発話時間+5秒程度だけに起きるようにしてほしい。
そうしないと話を聞いている間にゼロになってしまう」。実時間で減らすと、**他人の話を
聞いている数分の間に証拠が消え**、次の一言が聞き間違いでもその人の言語を決めてしまう——
聞いていることは言語を変えた証拠ではない。減衰に数える時間を
`min(実経過, 発話長+5秒)`に変更。追従の基準も「実時間1分以内」ではなく
**「発話時間1分以内」で良い**との指示に変わったため、実時間を狙って足しかけた
連続発話ルールは外した(単純な減衰だけで満たせる)。

**実測**(発話3秒): 4秒おきなら発話時間24秒、10〜30秒おきなら発話時間12秒で追従。
実時間は話す頻度次第で32〜120秒と伸びるが、聞いている時間を数えない以上それが正しい。

**2. 「話す言語は話者ごとにも異なります」**: これは元から満たしている——`LanguageTally`は
`SttSession`のフィールドで、セッションは話者ごとに1つ。同じ部屋に別々の言語の話者が
混ざっても互いに影響しない。

**3. ブランチを既定ブランチへマージ**: `binaural-meet` `master`、`bmMediasoupServer` `main`、
`bm` `main`(いずれもfast-forward、テスト通過後にpush)。本番の手順書も
`feature/stt-translation`ではなく既定ブランチを指すよう直す必要がある。

**サイドカーのリポジトリを`BinauralMeet`組織に作成**:
`https://github.com/BinauralMeet/stt-sidecars`(他の3リポジトリと同じくpublic)。
APIキー等は含まない(環境変数から読む)が、`lm.haselab.net`や
rtx5070tiのLANアドレスへの言及はこのbmリポジトリのdocsと同様に含まれる。

**vrcssは対象外**: STTは使わない。`copySource.sh`でコピーしている
`MediaMessages.ts`/`Rtc*.ts`にはSTT関連の型が入るが、実害はないのでそのまま
(ユーザー確認済み)。

## 2026-09-26 — 認識は部屋単位、表示は各自に変更 {#2026-09-26-stt-room-switch}

ユーザーの指示: 「STTのONは部屋の利用者全体をONにするのが良い。ON/Offボタンは表示の
OnOffに。言語はユーザごとに選ぶのが良い」。

当初は参加者ごとのON/OFFだったが、**自分だけONにしても自分の声しか字幕にならず、
会議の役に立たない**——字幕は会話の場の性質であって個人の設定ではない。

- **認識のON/OFFは`ROOM_PROP`の`stt`**(`'true'`/`'false'`)。DataServerが`room.properties`を
  `REQUEST_ALL`で再送するので、**後から入室した人も自動で同じ状態**になる。
- **フッターのボタンは「自分が字幕を見るか」**(`settings.showSubtitles`、既定ON)。
  OFFにすると吹き出しもチャット欄の`stt`行も消えるが、**認識は続く**。
- **言語(話す/読む)は引き続き各自**。部屋のスイッチは同じボタンの「…」メニューに置いた。
- サーバーが拒否しても**部屋のスイッチは勝手に戻さない**(全員のものなので)。理由は
  ツールチップに出す。

**動作確認**(実音声を流したCDP): 部屋OFFでは音声が流れていても認識0件 → 部屋をONにすると
6秒後に1件・9秒後に2件と字幕が出る → 表示をOFFにすると吹き出しもチャット行も消えるが
**認識は進み続ける**(2件→3件)ことを確認(`logs/stt-room-hidden.png`)。

**宿題**: 誰か1人がONにすると全員の発話が文字になるので、参加者ごとの「今認識されている」
インジケータと、管理者による禁止(`sttPolicy`)はまだ無い。

## 2026-09-26 — 本番構成(main + media1 + media2 + binaural.me)に合わせて作業を分けた {#2026-09-26-stt-prod-topology}

本番は`main`・`media1`・`media2`・`binaural.me`(クライアント配信)という構成。
**この機能はmainとmediaの両方に跨っているので、マシンによって要るものが違う**:

- `media1`/`media2`: 音声を取り出して認識するので**`ffmpeg`**と`stt`ブロックとAPIキー
- `main`: 認識結果を部屋へ配って翻訳を呼ぶので`translation`ブロックとAPIキー(**ffmpegは不要**)
- `binaural.me`: 新しいクライアントビルド(無いとSTTのUI自体が無い)

`maxSessions`はワーカーごとなので、media2台で合計16。一方**GPUサービスは全ワーカーで
共有**され、同時に捌ける本数は`WHISPER_WORKERS`(既定2)。両mediaから同時に喋る人が
増えると待ち行列ができる。

## 2026-09-26 — 本番の所在を訂正(vrc.jpではなくtitech) {#2026-09-26-stt-prod-target}

`stt-translation#todo`を「本番はこのホスト上のvrc.jp(pm2)」という前提で書いていたが、
**ユーザーから訂正**: 本番は`main.titech.binaural.me`等の**別マシン**。
ホストのdocに`vrc-jp`(このホストでpm2稼働するbmMediasoupServer)があり、それを本番と
取り違えていた。

効いてくるのは**CPUサイドカーの所在**で、8190/8191はこのホストのループバックにしか無く、
本番からは届かない(認証も無いのでそのまま公開するものでもない)。一方GPUサービスは
`lm.haselab.net`経由なら本番から届き、**認識と翻訳が同じサービスなのでパス1本で両方賄える**。
本番の最小構成は「GPUパス + APIキー + ffmpeg」で、CPU側を本番マシンにも置くかは選択
(置けばGPUが塞がっている間も字幕が出て、ja↔enの訳も良くなる)。

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

## 2026-09-26(2) — 本番(main/media1/media2、titech.binaural.me)の下調べと、コード配置を伴わない2点を実施 {#prod-gpuwhisper-proxy-ffmpeg}

ユーザーから: 「本番はmedia1 media2 mainのtitech.binaural.meで動きます。これらの
本番対応はお願い」。それまで`vrc-jp`(vrc.jp)を本番だと思い込んでいたが、実際の
本番は別マシン(`/root/bmMediasoupServer`、`vrc-jp`が言う`/root/webapp/...`とは
別配置)と判明。`#todo`を本番の実態(main/media1/media2の役割分担、CPUサイドカーは
どのマシンからも届かないこと等)に合わせて書き直した。

**わかった前提**: 3台とも`main`ブランチの**互いに異なるコミット**で止まっており
(`main`:`a001714`、`media1`:`c39cb9e`、`media2`:`9de15a3`)、`feature/stt-translation`
(この機能そのもの)はどれにもマージされていない——`dist/src/media.js`に
`sttStart`/`SttBackend`が0件だったことで確認。したがって`config.js`に`stt`/
`translation`ブロックを足すだけでは何も起きない。ユーザーに確認したところ、
**コードのデプロイ(ブランチの追従・ビルド・`pm2 restart`)は保留**という判断。

**保留にせず実施した2点**(コード配置を伴わない、いつやっても損がないもの):

- `haselab.net`のApache vhost(`lm.haselab.net`、`/SENSEVOICE/`等と同じホスト)に
  `/GPUWHISPER/` → `rtx5070ti.local:8192`を追加(既存パスと同じ認証ゲート)。
  `apache2ctl configtest`→`reload`で反映、`curl .../GPUWHISPER/health`が
  `{"device":"cuda","model":"large-v3-turbo",...}`を実機確認。ホスト側の記録は
  `doc show CHANGELOG-013#bm-prod-gpuwhisper-proxy-ffmpeg`(ai1のCLAUDE.mdが指す
  `/usr/local/share/doc`側)。
- main・media1・media2の3台に`ffmpeg`を導入(`ffmpeg -version`で実機確認)。

**現在残っているもの**: `LM_HASELAB_API_KEY`の投入・`feature/stt-translation`の
本番デプロイ(3台のコミットをどう揃えるか含む)はユーザーの次の指示待ち。
`stt-translation#todo`に反映済み。

## 2026-09-26(3) — ai4へのSTT経路をsshトンネルに統一、専用アカウント`sttfwd`へ移行 {#stt-ai4-tunnel-sttfwd}

本番のmedia1/media2からai4のSTTサイドカー(8190)へ届かす方法を決めた。**ai4を公開IPで
待受けさせ、ファイアウォールを開け、共有シークレット`STT_API_KEY`を配る案を検討したが
採らなかった**——会議音声が平文でインターネットを渡る上、鍵の配布とローテーションが
増える。代わりにai1→ai4で既に動いていた**ポートフォワード専用の制限付きSSH鍵による
sshトンネル**を本番にも広げた。ai4側の変更はゼロ(`CPU_WHISPER_LISTEN`も`STT_API_KEY`も
不要、サイドカーはループバックのまま)。採らなかった案の理由は`stt-translation#todo`。

**接続アカウントを`hase`から専用アカウント`sttfwd`に変えた**(ユーザー指示)。シェルが
`nologin`なので**シェルもコマンド実行もアカウントレベルで拒否される**——`authorized_keys`の
`command=`制限より一段強い。ai1の既存トンネル(`ai4-stt-tunnel.service`)も`sttfwd`へ移し、
ai4の`hase`の`authorized_keys`から旧トンネル鍵の行を削除した。`permitopen`の範囲外への
転送が拒否されること(バナー無しで遮断)も確認済み。

**動作確認**: ai1の切り替え後と旧鍵削除後の再起動後、いずれもサンドボックスのコンテナ内から
`curl http://172.17.0.1:8193/health` → `{"model":"medium","status":"ok"}`。さらに
`POST /asr`に11秒のWAV(jfk)を投げて4.8秒で正しい全文が返った——`/health`だけでなく
**POSTボディもトンネルを通ること**を確認している。media1・media2は各ホスト上で
`curl 127.0.0.1:8190/health`が同じ応答を返し、**ユニット再起動後の復帰も確認済み**。

media側のトンネルは**ローカル側も8190**で張る(ai1が8193なのは自前の`small`サイドカーが
8190を使っているため。mediaには自前のサイドカーが無い)。これに伴いmediaの`config.js`の
`stt`エントリは`http://127.0.0.1:8190/asr`・`apiKeyEnv`なしになる(トンネルの内側なので
ai4は認証を要求しない。`SttBackend`は環境変数が未定義なら単にヘッダを付けないだけで、
書いても落ちはしないが意味が無い)。

**ホスト側でこの機能に必要な作業はこれで揃った。** 残りはBM側のデプロイのみ——
`LM_HASELAB_API_KEY`の投入、3台のコミットの揃え方、既定ブランチのビルド・配置、
`config.js`への`stt`/`translation`ブロック追記(`stt-translation#todo`)。

## 2026-09-26(4) — 部屋の認識スイッチを廃止、字幕を表示している人が1人でも居れば認識する {#stt-any-viewer-on}

ユーザーの指示:「STTのON/OFFスイッチを付けるのではなく、だれか一人でもSTTのUIをONにしている
人がいれば、ONになるように」。**スイッチが2つある構成をやめた**——字幕を見たい人が
「表示ON」に加えて「部屋の認識ON」も押す必要があり、押し忘れると何も出ないまま理由も
分からない。逆に「部屋ON・誰も見ていない」という、誰の役にも立たないのに認識器を回し続ける
状態も作れてしまっていた。

`ROOM_PROP`の`stt`(および`RoomInfo.stt`・`RoomPropertyName`の`'stt'`・メニューのスイッチ)を
削除し、判定を**各参加者が既に配っている`PARTICIPANT_STT_LANG`に`on`(自分が字幕を表示中か)を
足したもののOR**にした。部屋側に状態を持たないので入室・退室で勝手に整合する(最後の1人が
抜ければ認識も止まる)。Storedメッセージなので後から入室した人にもその状態が届く。
`on`が無いメッセージ——このフィールドより古いクライアント——は**ONとして読む**:
古いクライアントが1人居るだけで他の全員の字幕が黙って止まる方が悪い。

**`settings.showSubtitles`の既定をON→OFFにした。** 以前は部屋がOFFの間はどのみち何も
出なかったので既定ONが素直だったが、この変更後は既定ONのままだと**部屋を開いた瞬間から
全員が認識される**——読む人が1人も居なくても認識器の時間を使うことになる。

判定は`binaural-meet/src/models/stt/SttLogic.ts`の`anyoneWantsSubtitles()`に純粋関数として
切り出した(`SttVadLogic.ts`/`TranslationTargets.ts`と同じ分け方)。`SttClient`の`autorun`と
ボタンの見た目の両方がこれを読む。ボタンの3状態も**「自分が見ている / 見ていないが誰かが
見ている / 誰も見ていない」**に変わった——真ん中は「自分の声が文字になっている」状態なので、
黙っていてはいけない(`ttSttHiddenOthersOn`を追加、`ttSttRoomOff`と`sttRoomSwitch`を削除)。

サーバー側は`translation.ts`の`wantedLangs()`が`on:false`の参加者を翻訳先から外すようにした
(字幕を見ていない人のために訳す意味はない。`on`が無ければ従来どおり`show`を使う)。

**動作確認**: `tsc --noEmit`が両リポジトリで通り、テストは binaural-meet 162件・
bmMediasoupServer 62件すべて成功(`SttLogic.test.ts`を新規追加、`RoomInfo.test.ts`の
`stt`プロパティのテストは対象が消えたので削除)。実会議での確認はまだ。

## 2026-09-26(3) — デプロイ手順・スクリプトが無かったので新規作成、config.jsの混入バグを発見 {#deploy-script-and-doc}

ユーザーから「上の機能を本番(main/media1/media2/binaural.me)へ反映して」との依頼
(`binaural-meet` masterを`33bbd9a`→`6809bb5`、`bmMediasoupServer` mainを
`c018dcf`→`520cbcf`)。既存のデプロイ手順・スクリプトが無いか確認したところ
(`stt-translation#todo`に手順の説明はあったがスクリプトは無し)、ユーザーから
「無ければドキュメント化とスクリプト作成を」との指示。`deploy-prod.sh`(`bm/`直下)と
`docs/deploy`を新規作成した。詳細・設計判断は`deploy#design`参照。

**調査中に見つけた問題**:

- `binaural-meet`の対象コミット範囲が**`public/config.js`を変更していた**
  (`configTitech`→`configLocal`——このサンドボックスの開発用エンドポイントを指す)。
  ユーザーは「今回はconfig.js変更は不要」と認識していたが実際には混入していた。
  `deploy-prod.sh`は実機の値を退避・復元する設計にしたのでデプロイ自体への影響は
  避けられるが、**リポジトリ側にこの混入が残っている**ので、いずれ直す必要がある
  (別マシンで新規cloneした場合などに影響しうる)。
- `main`/`media1`/`media2`への`ssh`はこのホストの自動モード分類器が「本番への
  操作」として一律ブロックした——読み取り専用のコマンド(`whoami`、SSH到達確認)
  も含めて拒否("Production Reads")。そのため`deploy-prod.sh`は`--dry-run`での
  内容レビューのみで、実機実行はまだ検証できていない。
- `binaural.me`と`main.titech.binaural.me`はDNSが別のマシンを指しており、
  どちらも`~/.ssh/config`にエイリアスが無い。リポジトリの配置場所・配信ディレクトリも
  未確認(`deploy#limits`)。

**現在残っているもの**: 上記3点(config.jsの混入バグの修正、本番アクセスの許可、
binaural.meの接続情報)がユーザーへの確認待ち。実際のデプロイ実行はまだ。

## 2026-09-26(4) — 本番4台へ実デプロイ、途中でconfig.js誤破壊事故と復旧 {#deploy-executed-and-incident}

上の3点にユーザーが回答: 「1(config.js混入バグ)は直して」「2(本番sshの許可)は
マニュアルモードにするので実行して」「3(binaural.meの接続先)はai1のエイリアス、
dnsで見えないか」。

**1の修正**: `binaural-meet`の`public/config.js`末尾を`configLocal`→`configTitech`に
戻す1行修正を`master`へcommit・push(`18e13ae`)。デプロイ対象コミットは
`6809bb5`ではなく`18e13ae`に変更。

**3の調査**: `binaural.me`/`ai1.binaural.me`/`ai1.haselab.net`は全てこのホスト
(`ai1`)自身。ssh不要。調査の過程で`/root/webapp/`一式は
**vrc.jp用**(ユーザー確認: 「ソースは共有だが全く別アプリ」)であり、binaural.meの
ビルド元ではないと判明。正しい手順はホスト側CHANGELOG-004#binaural-me-rebuild
(2026-08-06)の前例通り、`bm/binaural-meet`(この開発チェックアウト)から
`git worktree`で対象コミットだけ分離してビルドすること——`deploy-prod.sh`の
`client`をこの方式に書き直した(SSHベースの案は撤回)。

**binaural.meへのデプロイ**(`client 18e13ae`): dry-runで実ビルド・config.js確認まで
通してから本番実行。`/var/www/binaural.me`を更新、`https://binaural.me/`が200・
`config.js`が`configTitech`のまま・`public_packages/`無変更を確認。
バックアップ`/root/binaural.me-backup-20260926-210110`。

**main/media1/media2へのデプロイ**(`server-all 520cbcf`)で事故発生:
`/root/bmMediasoupServer`が`root`所有・sshログインは`aiops`だったため、まず
git操作が"dubious ownership"で失敗 → `sudo -n`昇格に変更して解消(pm2名は
`main`=`bm`、`media1`/`media2`=`bmm`と実機で確認、事前の推定が正しかった)。

**そのすぐ後、`deploy_server`内の1行が本番のconfig.jsを破壊した。**
「pullでconfig.jsが動いていたら実機の値へ戻す」つもりで入れていた
`git checkout HEAD -- config.js`は、**gitの側(コミット済みの汎用値)を勝たせる**
コマンドで、意図(実機の値を勝たせる)と向きが逆だった。3台とも実行され、
STT/translationの`backends`/`endpoints`が空に、`main`のリッスンアドレスが
`https://0.0.0.0:443`から`https://localhost:3100`相当(外部到達不可)へ、
約19分間(21:04〜21:23)書き換わった。

**復旧**: 幸い直前に`cp -p config.js /root/.config.js.deploy-backup.<timestamp>`で
退避していたため、3台とも退避ファイルを`config.js`へcpし直し→`npm run build`→
`pm2 restart`で復旧。ログで`main`が`https://0.0.0.0:443`で待受け直したこと、
`media1`/`media2`が`workerId`登録に成功したことを確認。

**恒久修正**: `deploy-prod.sh`の`deploy_server`を、`client`と同じ
「`cp`で退避 → mergeの後に退避ファイルを実ファイルへcpし戻す」という
**向きが対称な**実装に直した(`git checkout`/`git reset`のような「gitへ戻す」
系のコマンドを「実機の値を守る」目的では使わない、という教訓を`deploy#design`に
明記)。

**動作確認**: `main`/`media1`/`media2`とも`git log -1`が`520cbcf`、`pm2 ls`で
`bm`/`bmm`が`online`、`config.js`が退避前バックアップと一致することを確認。
binaural.meは上記の通り200・configTitech確認済み。

## 2026-09-27 — 低信頼度の訳文を字幕と見分けられるようにした(実装のみ、未commit) {#untranslated-bubble}

ユーザーから: 「翻訳に`I can't translate it`のような、翻訳ではない警告のようなものが
混ざっているように思う。区別がつくならないなら表示を工夫したい」。調べたところ
**現状は区別する仕組みが無かった**——`translation.ts`の`callOne()`はバックエンドが返した
文字列が空でなければ無条件に正しい訳として採用しており、`Transcript.textFor()`も
「訳があればそれ、無ければ原文」の二択で、原文が「訳が来なかったから原文」なのか
「そもそも訳が要らない(読者の言語=話者の言語)」なのかを区別していなかった。
翻訳バックエンド自体はFuguMT/M2M-100(いずれもCTranslate2の専用NMTモデル、LLMではない)
なので、`I can't translate it`のような一見自然な文はモデルが短い/不明瞭な原文に対して
出す定型的な出力だろうという仮説のもと、ユーザーに実装方針を確認: (1)
怪しい訳をどう表示するか→**「元の発話だけを、色を変えて表示」**、(2)
具体例の有無→**無し、閾値は仮置きで進めてよい**。

**サーバー側(2つのsidecar、`stt-sidecars`)**: `translate_batch`に`return_scores=True`を
渡し、1トークンあたりの平均対数尤度が`TRANSLATE_MIN_SCORE`
(`translate_server.py`)/`MULTI_MIN_SCORE`(`gpu_whisper_server.py`、既定`-1.2`、
未測定の仮値)を下回ったら、そのdstを応答から**省く**(未対応言語ペアと同じ経路に
乗せるだけで、`bmMediasoupServer`側のワイヤ形式は変更不要)。1発話=1テキストの
バッチでのみ判定(現状の呼び出し方がこれしかないため。複数件のバッチでは
位置対応が壊れるので判定をスキップし、コメントで理由を明記)。

**クライアント側(`binaural-meet`)**: `Transcript`の`Bubble`に`untranslated`を追加
(`joinRun()`が発話ごとに「読者の言語≠発話言語なのに訳が無い」かどうかを判定、
runの中に1つでもあれば吹き出し全体に立てる)。`SpeechBubble.tsx`はこれを見て、
通常の白/グレーではなく琥珀色の背景・文字色で表示する(`provisional`との濃淡は
そのまま流用)。読者が発話言語自体を選んでいる場合(訳が要らない)はフラグが立たない
——「翻訳が無い」と「翻訳が要らない」を混同しない設計。

**動作確認**: `binaural-meet`は`tsc --noEmit`通過、`vitest run`が164件全て成功
(新規2件・既存2件更新)。sidecar側は`python3 -m py_compile`のみ(GPU/モデルが
このサンドボックスに無いため実データでの確認は未実施)。`stt-translation#ingest`・
`#bubble`に設計を追記。

**現在残っているもの**: `binaural-meet`・`stt-sidecars`とも**まだcommit/pushしていない**
——ユーザーへの確認待ち。しきい値`-1.2`は実測に基づかない仮値なので、本番投入後に
実際の(原文, 訳文, スコア)を見て調整が要る。

## 2026-09-27 — 上のデプロイを実施、rtx5070tiでの再起動の落とし穴を発見 {#untranslated-bubble-deployed}

ユーザー承認(「デプロイして、ログを見て閾値を詰めてください」)を受けて実施:

- `binaural-meet`(`d0db35a`)・`stt-sidecars`(`ab5715c`)ともcommit・push済み。
- `binaural-meet`は`binaural.me`へデプロイ(`deploy-prod.sh client`)、200・configTitech確認済み。
- `stt-sidecars`のFuguMT側(`translate_server.py`)は`stt-translate.service`(ai1、
  このワークスペースの`stt-sidecars/`から直接動く)を再起動して反映。ただし
  **本番`main`の`translation.endpoints`は現状GPUWHISPER(rtx5070ti)のみで、
  FuguMTは配線されていない**(`stt-translation#todo`項目3が未実施のまま)ため、
  実際の会議には影響しない。
- GPU側(`gpu_whisper_server.py`→rtx5070tiの`C:\Home\work\gpuwhisper\server.py`、
  実際に本番`main`が使っている方)は、ユーザーに実行中の会議の有無を確認
  (`/status`でgpuwhisperのみ稼働・`server.log`の直近タイムスタンプが数秒前=会議進行中と
  判明)。ユーザーから「今やってください」と明示の許可を得てから実施。

**rtx5070tiでの落とし穴**: そのホストは本リポジトリのcheckoutを持たず(ai4と同じ、
手動コピーの`server.py`)、**`sidecar_auth`の配線が無い**(このリポジトリのHEADには
ある)という既知の差分があったため、まるごと上書きせず**このリポジトリのHEADとの差分
だけを`patch`で当てて**アップロード(diffが無関係な箇所に触れないことを確認してから)。
さらに、**`POST /activate/gpuwhisper`は既に稼働中なら何もしない**(`control_api.py`が
`_is_running`なら起動処理をスキップする作り)ため、コード反映には
**`/activate/none`→`/activate/gpuwhisper`**の順で明示的に止めてから起動し直す必要があった
(`stt-sidecars`のREADMEに追記、`#gpu`)。反映は`/health`・`/status`・
`curl .../translate`の実リクエストで確認、その後もASR処理ログが途切れず再開したこと
(再起動の空白は数秒)を確認。バックアップは`server.py.bak-20260927-pre-confidence-filter`。

**残っているもの**: 実測での閾値調整——本番のgpuwhisperログに`translate: dropping
low-confidence hypothesis`が出るか、しばらく`server.log`を観察してから`-1.2`を見直す。

## 2026-09-27(2) — 実際の会議でログを見ながら閾値調整、3つの検出軸を追加・実機確認 {#confidence-filter-live-tuning}

ユーザーが実際の会議で「翻訳できない声」「明瞭な発話」の両方を発声し、その場で
`gpu_whisper_server.py`(rtx5070ti本番)のログをリアルタイムに監視しながら
イテレーションした。約2時間、200件超のログサンプルを実見して以下が判明・対応:

**1. 翻訳側スコア(`MULTI_MIN_SCORE`)は単独では機能しない。** 意味不明な発話
(「にゃにゃにゃ…」を数百回等)をM2M-100が翻訳した際、スコアは`-0.01`〜`-0.07`と
ほぼ最高の自信度だった——モデルは同じ内容を予測し続けるのが「簡単」なので confident
になる。翻訳が独立に反復ループへ暴走するケース(原文は正常なのに訳が
「No. No. No. No.」等に暴走)も複数確認。**対策**: 訳文自体の圧縮率
(`zlib`、faster-whisperの`compression_ratio`と同じ発想)を`MULTI_MAX_COMPRESSION_RATIO`
/`TRANSLATE_MAX_COMPRESSION_RATIO`(既定`2.4`)としてスコアに追加。

**2. ASR側(`avg_logprob`)の方が実際には有効な信号だった。** 意味不明な発話の
`avg_logprob`は明瞭な発話(目安`-0.3`〜`-0.8`)より明確に低く(`-1.5`〜`-4.6`程度)、
実測で閾値`-1.0`(`WHISPER_MIN_LOGPROB`)を設定。ただし**単発の反復ループには
無力**(「にゃにゃにゃ」が`avg_logprob=-0.07`)なので、ここにも
`compression_ratio > 2.4`(`WHISPER_MAX_COMPRESSION_RATIO`、faster-whisper自身の
既定値と同じ)を追加。ASR結果が抑制された場合は`text=''`を返す
(`bmMediasoupServer`の`stt.ts`が空文字列を「表示するものが無い」と扱う既存経路に
そのまま乗る、ワイヤ形式の変更不要)。

**3. `initial_prompt`自体がハルシネーションの原因になるケースをユーザーが発見。**
不明瞭な発話に対し「ウィンドウ, シェア, コンテンツ, シェア, コンテンツ, スクリーン」
という、`WHISPER_PROMPT`の語彙をそのままカンマ区切りで読み上げたような認識結果が
出現——`avg_logprob`(`-0.59`)も`compression_ratio`(`1.41`)も平常域で、上記2つの
検出をすり抜けていた。**対策**: 認識結果をプロンプトと同じ区切り(`,`/`、`)で分割し、
プロンプト語彙と一致する語の比率が`WHISPER_PROMPT_LEAK_RATIO`(既定`0.7`)以上なら
プロンプト漏れと判定して抑制。単語1つ(プロンプト語彙そのものでも)だけの発話は
対象外——「スクリーン」とだけ言うのは普通にあり得るため。

**4. クライアント側の`untranslated`表示(前回作業分)も同じ実会議で確認**: 訳が
無い箇所が琥珀色で表示されることを確認。

**すべて実機(main/media1/media2ではなくrtx5070ti側)で反映・動作確認済み**
(`server.py`はgitチェックアウトを持たない手動配置、`patch`で差分だけ当てて
`activate/none`→`activate/gpuwhisper`で再起動、の手順は`stt-sidecars`README`#gpu`参照)。

**残った既知の制限、ユーザー判断で「今回は見送り」**: 無音区間での定型文
ハルシネーション(`"Thank you."`/`"I'll see you next time."`等、Whisperが学習データの
動画終わりの決まり文句を無音時に読み上げる、broadly知られた挙動)が数秒間隔で
繰り返し出現し、`avg_logprob`が`-0.6`〜`-1.1`程度で閾値`-1.0`をまたぐため
半分程度しか抑制できていない。**ユーザーの判断**: 「ハルシネーションはとりあえず
諦めて、下手に抑制しない状態で運用する。正常な発話を異常と誤認する方が怖い」——
つまり**閾値をこれ以上厳しくしない**方針。単語1つの発話(「スクリーン」
「コンテンツ」等)が閾値`-1.0`の境界で`suppressed`が行ったり来たりする不安定さも
実見しており、これ以上厳しくすると本物の短い発話まで消える懸念と符合する。

**次に見送った改善候補**(ユーザーへの提案のみ、未実装):
- 無音時の決まり文句(`"Thank you."`等)をブロックリスト化する
- 短い発話は`avg_logprob`が本質的に不安定なので、発話の長さで閾値を変える
- 圧縮率の閾値をもう少し下げる(`"Oh"`×9回が`ratio=2.00`ですり抜けた実例あり)

いずれも**今回は実装しない**(ユーザー判断)。しきい値は全て現状維持
(`WHISPER_MIN_LOGPROB=-1.0`、`WHISPER_MAX_COMPRESSION_RATIO`/
`MULTI_MAX_COMPRESSION_RATIO`/`TRANSLATE_MAX_COMPRESSION_RATIO=2.4`、
`WHISPER_PROMPT_LEAK_RATIO=0.7`、`MULTI_MIN_SCORE`/`TRANSLATE_MIN_SCORE=-1.2`)。

## 2026-09-27(3) — 同名参加者が互いに見えない事故を調査、再接続時の二重ソケットを修正 {#dataconnection-reconnect-storm}

ユーザーから: 「今haselabに2人入っていますがお互いが見えません」。`main`の
`bm-out.log`を見ると、`長谷川_`という同一idの参加者が**数時間にわたって断続的に**
「同じidの古い参加者を除去→0人に→再度参加」を繰り返していた
(`main.titech.binaural.me`、2026-09-27 14:45〜20:39頃)。

**当初の仮説(同名衝突)は的外れだった。** 参加者idは表示名の先頭4文字
(`Conference.ts`の`enter()`、`name.substring(0,4)`)——ここまでは合っていたが、
「2人目には`_2`のような別idを振る仕組みがあった」というユーザーの記憶を手掛かりに
`bmMediasoupServer/src/MainServer/mainServer.ts`を調べたところ、**`makeUniqueId()`
という重複回避関数(356行目)は今もコードに存在し、`createPeer()`から呼ばれている**
ことを確認——単純に消えたわけではなかった。

**実際の原因は`binaural-meet`側の再接続処理にあった。**
`DataConnection.connect()`(`src/models/conference/DataConnection.ts`)は、
呼び出し時に古い`dataSocket`が残っていても`console.warn`するだけで、
**古いソケットを閉じずに単に上書きしていた**。この古いソケットには
`onClose`→`this.disconnect()`のリスナーがまだ付いたままなので、後から
(サーバー側の切断がようやく届く等で)閉じられると:

1. `disconnect()`が`'disconnect'`イベントを再度emitする——これが
   `Conference.ts`の`onDataDisconnect`/`onRtcDisconnect`をもう一度起動し、
   **再接続処理そのものが再接続の引き金を再生産する**フィードバックループになる。
2. `disconnect()`は`this.peer`/`this.room`を参照して`PARTICIPANT_LEFT`を送るが、
   この時点で`this.peer_`/`this.room_`は**新しい接続用に上書き済み**——
   古いソケットの後始末のつもりが、**今まさに確立しようとしている新しい参加者を
   自分で追い出す**結果になる。

**修正**: `connect()`は、既存の`dataSocket`があればそのリスナー
(`open`/`message`/`error`/`close`)を`removeEventListener`で外してから
`close()`する(`disconnect()`は通さない——上記の理由でそれ自体が問題を起こすため)。
リスナー参照は新しいフィールド`dataSocketListeners`に保持し、
`onFirstMessage`→`onMessage`の差し替え時にも追従させる。`binaural-meet`
リポジトリに`640ec49`としてcommit済み(**未push・未デプロイ**)。

**未確認の点**: 実機で再現させて直接確認したわけではない
(コードの読解から導いた修正)。`tsc --noEmit`・既存164件のテストは通過。
`DataConnection`自体の単体テストは無い(WebSocket・グローバル`config`・
`conference`シングルトンに強く依存しており、テスト基盤の追加は今回のスコープ外と
判断)。

## 2026-09-30 — 2台目のGPU機rtx5070ti2を追加し、空いている方を使う・両方空けば負荷分散する`pool`を実装 {#stt-gpu-pool}

ユーザー要望:「STTと翻訳を新しい5070ti2 にも入れて、空いている方を使う、両方空いているときは
負荷分散する仕組みを作ってください」。仕組みは`stt-translation#pool`、Apacheでやらなかった理由は
`stt-translation#design`。

**rtx5070ti2側**(Windows 11。ホスト側の記録はホストのCHANGELOG
`rtx5070ti2-gpuwhisper`):

- Python 3.11.9(ユーザースコープ)と、`control_api.py`用の`fastapi==0.141.1`・`uvicorn==0.52.2`
- `C:\Home\work\gpuwhisper\`: rtx5070tiの`server.py`をそのままコピー(このリポジトリの
  `gpu_whisper_server.py`ではない。`stt-sidecars/README.md#gpu`が言う手作業のコピーの方に揃えた)。
  venvはrtx5070tiの`pip freeze`(48パッケージ、`nvidia-cublas-cu12==12.8.5.5`を含む)で作成。
  `models/m2m100-418m`(928MB)もrtx5070tiからコピー。Whisper large-v3-turboは初回起動時に
  HFから取得
- `C:\Home\work\control_api.py`: rtx5070tiのものから`gpuwhisper`以外のモードを除いた縮小版
  (API・ロックの実装は同じ)。タスク`ControlAPIStart`(ログオン時、rtx5070tiと同じ設定)で起動。
  ファイアウォールで8100・8192の受信を許可

**bmMediasoupServer**:

- `src/MediaServer/GpuPool.ts`を新設: `groupIntoRungs`・`orderPool`(純粋関数)と、
  `GpuLockReader`(`HttpSttBackend`にあったロック読み取りを切り出したもの)
- `SttBackendSelector`: `pool`が同じエントリを1段にまとめ、空いているものの中から処理中の要求が
  少ないものを選ぶ。失敗したら同じ段のもう1台で再試行。`SttBackendConfig`に`name`・`pool`を追加
- `translation.ts`: エンドポイントにも`pool`・`gpuStatus`を追加。同じ選び方で、段の中で
  ロック中・ブレーカーが開いたものを避ける。テスト用に`callBackend`をexport
- **ロック読み取りの競合を修正**: 同時に来た2つ目の呼び出しが、1つ目の読み取りの最中に
  キャッシュの初期値(「ロックなし」)を返していた。元の`HttpSttBackend`にもあった。
  読み取り中は、後から来た呼び出しも同じ読み取りの結果を待つようにした。下のライブ確認で
  見つけた
- テスト: `GpuPool.test.ts`(8件)、`SttBackend.test.ts`にpoolの5件、
  `translationPool.test.ts`(4件)。手動確認用に`sttPoolLive.ts`
- 開発用の`config.js`(このチェックアウト、コミットしていない)を2台のpoolに変更

**動作確認**:
- `npm test`で`src/`の79件がすべて通過。`dist/`の6ファイルは古いビルド成果物をvitestが
  拾って失敗しているだけで、変更前から同じ
- `tsc --noEmit`が通過
- rtx5070ti2を直接叩いた結果: `/health`が`{"device":"cuda","model":"large-v3-turbo",...,"translator":"m2m100"}`。
  jfk.wav(11秒)の認識は、ウォームアップ後0.18秒(初回はCUDAの初期化で24秒)。
  ja→zh/ko/enの翻訳は0.17秒
- `sttPoolLive.ts`で実機2台に、haselab経由のsshトンネルでjfk.wavを投げた結果。どちらも
  すでに`gpuwhisper`モードだったので、何も切り替えていない:
  - 2台とも空いている: 8件、同時2本で、`{A: 4, B: 4}`と交互に振り分けられた
  - rtx5070ti2のロックを取った: 修正前は`{A: 3, B: 1}`(上の競合)、修正後は`{A: 6}`。
    確認後にロックは解放
  - rtx5070ti2に届かない: `{A: 6}`

**2026-10-01、本番に反映した**(ユーザーの承認による):

1. `lm.haselab.net`に`/GPUWHISPER2/`(→`rtx5070ti2`の8192)と`/SWITCH5070TI2/`(→同8100)を
   追加した。既存の`/GPUWHISPER/`・`/SWITCH5070TI/`と同じ認証ゲートを通す(ホスト側の記録は
   ホストのCHANGELOG`rtx5070ti2-gpuwhisper`)。キーありで200、なしで302になることを確認
2. bmMediasoupServerの`main`をpush(`9fae767`、別セッションのレビュー中に入った`88eb1b5`
   「vitestが`dist/`を拾わないように」も一緒に。以後`npm test`は8ファイル79件がすべて通る)
3. 本番3台の`config.js`を書き換えた。media1・media2は`stt.backends`のGPUエントリを
   `name`付きの2つにし、両方`pool: 'gpu'`・`gpuMode: 'gpuwhisper'`。mainは
   `translation.endpoints`を2つにし、両方`pool: 'gpu'`と各自の`gpuStatus`。書き換え前の
   ファイルは各機の`/root/.config.js.pool-backup.20261001`
4. `./deploy-prod.sh server-all 88eb1b5`。3台とも`520cbcf`からfast-forwardし、ビルドして
   `pm2 restart`した(`bm`/`bmm`とも`online`)。ビルド後の`dist/config.js`が上の内容で
   あることも確認

`gpuMode`を2台とも付けたのは、rtx5070ti2が`gpuwhisper`しか持たない専用機で、切り替えても
止まるものが無いため。rtx5070tiは以前と同じで、アイドルなら`gpuwhisper`へ切り替える
(そのときComfyUI等は止まる)。

デプロイ前に、別セッション(BM STT)がサンドボックスから、本番に書くURLをすべて叩いて
確かめた。`/GPUWHISPER2/asr`はjfk.wavを0.49秒、`/translate`はja→en/zh/koを0.15秒、
`/SWITCH5070TI2/status`・`/lock/status`も200。

**本番での確認**(2026-10-01 22:31〜22:36、ユーザーの許可を得て実施): 別セッション(BM STT)が
本番のbinaural.meにheadful Chromeで入った。部屋は実在しない`pooltest-20261001`・`…b`・`…c`、
字幕ON、表示言語ja。ページ内でマイクを差し替えてjfk.wavを約14秒間隔で4回流し、これを3回やった。
3回目は16発話がすべてfinalになり、すべてに日本語訳が付いた。並行して、こちらで2台の
`server.log`を見て、`asr:`の行(途中結果の再認識を含む)を数えた:

| 回 | rtx5070ti | rtx5070ti2 |
|---|---|---|
| 1 | 21 | 22 |
| 2 | 22 | 21 |
| 3 | 21 | 22 |

**ほぼ半々に振り分けられている。** 翻訳(`translate:`の行)は1回目にだけ出て、rtx5070tiに2件、
rtx5070ti2に3件。2回目以降は同じ文なので、mainのLRUキャッシュが答えている。
この部屋を受け持ったmedia2のpm2ログには、22:31:44に`stt: using backend 'pool gpu'`が
出ていた。media1には出ていない(この部屋を受け持っていない)。スクリーンショットは
`logs/prod-e2e-joined.png`・`logs/prod-e2e-subtitles.png`。

## 2026-10-02 — 13時の会議の切断を調査、再接続修正(640ec49)をデプロイ、STTのウォームアップを追加 {#meeting-1002-warmup}

ユーザーから2点。「1時からミーティングをしました。その際、RTCサーバーの切断が起きたりしていました」と、
「STTの初回のディレイが大きいことがありました。ウォームアップが必要なら、書き起こしONの会議が
始まった時点でするように」。

**切断の調査**(main・media1・media2のpm2ログ、13:00〜13:52):

- **サーバーは落ちていない。** `bm`・`bmm`とも前日のデプロイ以降に再起動しておらず、メモリ不足で
  落とされた記録も無い。media側に worker の異常は無い(`closetransport ... not found`は退出時の
  後片付けの重複で無害)。STTのセッションは入り直しのたびに止まって再開していて、原因ではなく結果
- mainのエラー扱いの切断は55件。RTCの websocket の閉じ方で分けると、1005が17件
  (ページを閉じる・再読み込みするときに`index.tsx`の`beforeunload`が`conference.leave()`で閉じたもの)、
  1001が16件(ページ遷移・再読み込み)、1006が8件(close が届かない=ネットワーク断。下山・湯本・QY・
  長谷川_)。サーバー側の60秒タイムアウトが3件(QYのData 2回、長谷川_のRTC 1回)。
  **約6割は参加者自身の再読み込み**で、なぜ再読み込みしたのかはサーバーのログからは分からない
- 同じ規模の会議と比べると再読み込みが多い(9/10: join 55・エラー切断26・1005が1件、
  9/27: 54・21・2件、今日: 68・55・17件)
- `#dataconnection-reconnect-storm`と同じ症状が出ていた: 同じ人に別IDの接続が同時に存在する
  (`下山尚也`・`下山尚也1`・`下山尚也2`、`長谷川_`・`長谷川_1`)、`Peer ... not found`の連発。
  一度ネットワークが切れた人がこのループに入って、何度も入り直した可能性が高い

**binaural-meet 640ec49をデプロイ**(ユーザーの指示): `./deploy-prod.sh client 640ec49`。
binaural.meが200、配信中のバンドルに修正のコードが入っていること、`config.js`が`configTitech`で
あることを確認。効いたかどうかは次の会議のログで分かる。

**STTのウォームアップ**(仕組みは`stt-translation#warmup`):

- 会議の時間帯のGPU側は最初から0.1〜0.6秒で返っていた(前日の確認でウォームアップ済みだったため)。
  rtx5070ti2でモードを再起動して測ると、`/health`が答えるまで14秒、初回の認識が1.6秒、2回目以降0.2秒。
  遅れの元は「GPUが別モード・未起動のときの切り替え待ち(その間はCPU)」と「起動直後の初回」
- stt-sidecars `642e7f1`: `gpu_whisper_server.py`に`warm_up()`。2台の`server.py`
  (手作業のコピー)にも同じ関数を足して入れ替え、モードを再起動した。再起動直後の初回の認識は
  rtx5070ti2で0.24秒、rtx5070tiで0.18秒。ウォームアップ自体は4.2秒・0.5秒
  (ホスト側の記録はホストのCHANGELOG`gpu-server-warmup`)
- bmMediasoupServer `15dbda7`: `HttpSttBackend.warmUp()`・`SttBackendSelector.warmUp()`と、
  `stt.ts`の`sttStart`で最初のセッションのときに呼ぶ処理。テストに5件追加して84件すべて通過。
  本番と同じhttpsの経路で2台のpoolに`warmUp()`を呼ぶと、2台に1件ずつ認識要求が届き(0.4〜0.5秒)、
  続けて呼んだ2回目は何も送らないことを実機で確認。BM STTからのレビューの指摘
  (`sttStart`は参加者ごとに来るので抑制が要る、ロック中の機械には投げない、バックエンドの
  インスタンスを経由して既存の抑制を効かせる)を反映した
- stt-sidecars `199d37a`(前日のREADMEの追記)は、push前にLANのIPを書かない形に直した
  (公開リポジトリで、それまでIPは書かれていなかったため)

**本番デプロイ**(ユーザーの指示): `./deploy-prod.sh server-all 15dbda7`。main・media1・media2とも
`15dbda7`で`online`、ビルド後の`dist/config.js`はデプロイ前と同じ(media: `gpuWhisper@rtx5070ti`・
`gpuWhisper@rtx5070ti2`・`cpuWhisper`、main: 翻訳のエンドポイント2つ)。会議の始めにウォームアップが
走ることの実会議での確認は、次の会議で(`BM_STT_DEBUG=1`でなければログには出ない。GPU機の
`server.log`に、会議の開始直後に1秒の`asr:`が1件ずつ出れば、それがウォームアップ)。

## 2026-10-02 — 画像を貼れない不具合: Driveのアップロード先が消えていたのを直し、Gyazoが使えないときはDriveに回すようにした {#image-paste-drive-folder}

ユーザーから「今日、画像を貼れないと言う不具合がありました」「Gyazoもだめでした」。

**原因**:
- **Drive**: アップロード先のフォルダIDが`GoogleServer.ts`に直接書かれていて、そのフォルダが削除されていた。
  13:05の6回のアップロードは、すべて`GaxiosError: File not found`(404)で失敗していた。
  サービスアカウント(`binaural-meet@binaural-meet.iam.gserviceaccount.com`)自体は正常で、
  同じ共有ドライブの`loginInfo.json`は読めた
- **Gyazo**: ブラウザから`upload.gyazo.com`へ直接送る作りだが、`upload.gyazo.com`はCORSを許可していない
  (preflightが405、`Access-Control-*`ヘッダー無し)。ブラウザではネットワークエラーとして止まる。
  加えて、コードに書かれたアクセストークンも無効になっていた(`/api/users/me`が401)。
  CORSで止まった場合は元からDriveに回る作りだったので、今日貼れなかった直接の原因はDriveの方

**直したこと**:
- アップロード先は、ユーザーの判断で昔からのフォルダ「BMUploadImage」(共有ドライブ、リンクを知っている人は
  閲覧のみ、サービスアカウントはfileOrganizer)。途中で別のフォルダ「bmUpload」(マイドライブ、リンクを
  知っている人が編集者)も試したが、使っていない
- bmMediasoupServer `c7f263c`: フォルダIDを`config.googleDriveUploadFolderId`から読む(このリポジトリは公開
  なので、IDはコードに書かない)。未設定なら理由をログに出して断る。失敗のログを1行にした。本番mainの
  `config.js`に設定を足して(元は`/root/.config.js.gdrive-backup.20261002`)`deploy-prod.sh server main c7f263c`。
  media1・media2はアップロードに関わらないので`15dbda7`のまま
- binaural-meet `2cae125`: Gyazoが理由を問わず失敗したらDriveに回す(以前はネットワークエラーのときだけ)。
  401など、URLの無い応答も失敗として扱う。Driveが断ったとき(サーバーの`'upload error'`、5MB超)も
  失敗として返す(以前はその文字列をファイルIDとして使っていた)。テスト164件通過。`deploy-prod.sh client`

**動作確認**:
- main上からサービスアカウントでBMUploadImageに1×1のPNGを上げ、ログインなしでサムネイルのURLが200・image/png
  になることを確認(ゴミ箱へ。共有ドライブではfileOrganizerは完全削除できず404になるため、`trashed: true`)
- 別セッション(BM STT)が本番のbinaural.meでテスト用の部屋`pastetest-20261002`に入り、18:19:31に画像を
  1枚貼った。コンソールにはGyazoがCORSで止まった記録と「uploading to Google Drive instead」が出て、画像は
  マップに表示された。サムネイルはログインなしで200。テスト画像はゴミ箱へ移した
- このとき、前日のSTTのE2Eで同じブラウザのプロファイルに残っていた`showSubtitles: true`のせいで、無音の
  マイクが書き起こされて「Thank you.」(Whisperの無音でのハルシネーション)が出た。BM STTがプロファイルを
  元に戻した。テスト用の部屋なので他の人への影響は無い

**残っているもの**: Gyazoをどうするか(ブラウザからは使えない。使うならサーバー経由にする必要がある)。
