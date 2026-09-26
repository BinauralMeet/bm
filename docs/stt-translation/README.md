# stt-translation — サーバー側音声認識と翻訳字幕

**いつ読むか**: 発話の文字起こし・翻訳字幕機能を実装する / `MediaServer`のSTTセッションや
`DataServer`の翻訳ハンドラに触る / 字幕が出ない・訳文が来ない原因を切り分ける /
STTエンジンや翻訳バックエンドを差し替える / rtx5070tiをBMの認識バックエンドとして使う

実装済み・**実機で音声から字幕まで一本通してある**(2026-09-25、
`CHANGELOG#2026-09-25-stt-e2e`)。既定ではオフで、`config.js`にバックエンドを
書いた環境でだけ動く。決定に至る経緯と却下した案は `#design`、
何がどこまで通っているかは `#phases`。

## 構成 {#arch}

音声認識は**サーバー側**で行う。クライアントは認識も翻訳もせず、
「自分のマイクProducerをSTT対象にしてくれ」と頼んで、降ってきたテキストを表示するだけ。

```
[話者のブラウザ]
  マイク → mediasoup producer (既存の経路をそのまま使う。追加の送信は無い)
  sttStart{producers:[micProducerId], lang} ──> main.ts ──(中継)──> media.ts

[media.ts (mediasoup worker)]
  SttSession(Producerごと)
    PlainTransport + Consumer → UDP → ffmpeg(opus→16kHz/mono/s16le) → stdout
      → VAD(発話区間の切り出し)
      → 発話中は約1.5秒ごとに「伸びていく窓」を再認識 → 途中結果
      → 無音で区間確定 → 最終認識 → 確定結果
    sttResult{peer, sid, text, lang, final} ──> main.ts

[main.ts (ゲートウェイ + DataServer が同一プロセス)]
  sttIngest: 認識結果を発話者からのメッセージとして部屋へ注入
    ├─ SPEECH_INTERIM / SPEECH_TEXT を全員へ即中継
    └─ 確定分のみ翻訳 → SPEECH_TRANSLATION を全員へ

[各参加者のブラウザ]
  DataSync.onBmMessage → Transcript ストア(sid で原文と訳文を束ねる)
    ├─ アバター脇の吹き出し
    ├─ 左バーのチャット欄
    └─ Recorder(recordable) → 再生時の字幕 / テキスト書き出し
```

要点は4つ。

1. **音声はクライアントから追加送信しない。** サーバーは既にmediasoupで受けている
   Producerをrouter内でconsumeするだけなので、話者の上り帯域は1バイトも増えない。
   同時に「BMが実際に送っているトラック」そのものを認識するので、
   ブラウザのSTT APIにありがちな「別のマイクを聞いてしまう」問題が原理的に起きない。
2. **ブラウザを選ばない。** Firefox・Safariでも同じように動く。
3. **原文は即時、翻訳は後追い。** 両者は `sid`(発話ID)で結び付き、
   後から届いた訳文が同じ吹き出し・同じチャット行を更新する。
   翻訳バックエンドが落ちても原文字幕は出続ける。
4. **途中結果は翻訳しない。** 確定した発話だけを翻訳する。

### 音声の取り出し (media.ts) {#audio-tap}

`MediaServer/streaming.ts`(RTSP配信)が既にやっている
「ProducerのRTPをPlainTransportへconsumeしてffmpegに渡す」をそのまま流用する。
違いはffmpegの出力先だけで、RTSPへpushする代わりに生PCMを標準出力へ吐かせ、Nodeが読む。

```
ffmpeg -protocol_whitelist pipe,udp,rtp -f sdp -i pipe:0 \
       -vn -f s16le -ar 16000 -ac 1 pipe:1
```

流用にあたって既存コードとずれる点:

- `sdp.ts` の `createSdpText()` は `video!` を無条件に参照するので**音声のみのSDPを作れない**。
  `createAudioSdpText()` を別に足す(既存関数は触らない)。
- `ffmpeg.ts` の `_commandArgs` はRTSP出力専用。`SttFFmpeg` として別クラスにする
  (`FFmpeg`/`GStreamer` と同じ `_observer` の形は踏襲し、`process-close` でセッションを畳む)。
- `streaming.ts` はキーフレーム要求のために3秒ごとにconsumerを`resume()`している。
  音声にキーフレームは無いので、STT側は `consumer.resume()` を最初に1回だけ呼ぶ。
- `port.ts` の `getPort()`(20000-30000)をRTSP配信と共有する。
  同時STTセッション数の上限(`config.stt.maxSessions`、既定8)を設けて枯渇を防ぐ
  (ポート枯渇で未処理のPromise rejectionが出ると`media.ts`ごと落ちる。
  `CHANGELOG#2026-08-02-port-exhaustion-fix` と同じ事故を繰り返さないこと)。

### 発話区間の切り出しと途中結果 {#vad}

ffmpegからのPCMをリングバッファに溜め、20msフレーム単位でVADにかける。

- **VADは既定でエネルギー方式**(適応ノイズフロア + hangover 500ms)。純粋関数として
  `MediaServer/SttVadLogic.ts` に切り出し、シングルトン非依存でテストする
  (`binaural-meet`側の`DataConnectionQueueLogic.ts`と同じ流儀)。
- 発話区間が開いている間、**約1.5秒ごとに区間の先頭から現時点までを丸ごと再認識**して
  途中結果を出す(伸びていく窓の再デコード)。出すのは常に最新の仮説そのもので、
  前の仮説との突き合わせはしない(`#design`)。
- 認識は**1区間につき常に1本だけ**走らせる。遅いバックエンドに対して古い仮説の
  行列ができ、発話が終わった後に届くのを防ぐ。確定結果に追い越された途中結果は捨てる。
- 無音がhangoverを超えたら区間を閉じ、最後にもう一度全体を認識して確定結果とする。
- 1区間の上限は30秒。超えたらそこで一旦確定し、次の区間として続ける
  (長い独演で訳文がいつまでも出ない状態を避ける)。

### 認識バックエンド {#stt-backend}

`SttBackend` インターフェース1つで抽象化する。渡すのは
16kHz/mono/s16leのバッファと言語ヒント、返るのはテキスト。

```ts
export interface SttBackend{
  //  pcm: 16kHz mono s16le。lang: 'ja'|'en'|...|'auto'
  transcribe(pcm:Buffer, lang:string): Promise<{text:string, lang:string}>
}
```

すべて同じインターフェースの上に乗る。サービスごとの差(パス・multipart/生body・言語
パラメータ名)は`config.js`のエントリで吸収する(`upload`/`langParam`/`langAuto`)。

| バックエンド | 中身 | 位置付け |
|---|---|---|
| `gpuWhisper` | rtx5070ti上のfaster-whisper large-v3-turbo(CUDA)。`bm/stt-sidecars/gpu_whisper_server.py`、`control_api.py`の`gpuwhisper`モード | **第1候補。** 11秒の音声を約0.3秒(実測)、句読点付きの文として返る。`WHISPER_PROMPT`でその場の用語(カタカナ語)を渡せる。**プロキシパスが無いのでSSHトンネル経由**(`start-dev.sh`が開く) |
| `cpuWhisper` | このホストのCPU・faster-whisper small | 縮退先。1秒の音声に1.2〜2.4秒かかるので途中結果は出ないが、GPUが使えない間も字幕は出る |
| `sensevoice` | 同じrtx5070ti上の既存SenseVoice(`POST /transcribe`、multipart、`language`) | 速さは同等(11秒を約0.4秒)だが、**言語モデルを持たずホットワード指定もできないためカタカナ語に弱く**、文が断片化する。`gpuWhisper`を入れた今は使っていない(`config.js`にコメントで残してある) |

**同じGPU上の複数バックエンドに`gpuMode`を設定してはいけない。** 互いに自分のモードへ
切り替え合って、発話ごとにGPUを取り合う。優先する1つにだけ付ける。

### バックエンドの選択とフォールバック {#fallback}

GPU機は他の用途と共有されている。**BMはGPUロックを取らない。**
使えるときだけ使い、使えなければ黙って縮退する。

`config.js` の `stt.backends` は**優先順に並べた配列**で、`SttBackendSelector` が
先頭から順に生きているものを使う。

```js
stt: {
  backends: [
    {kind:'sensevoice', endpoint:'https://.../SENSEVOICE', gpuStatus:'https://.../SWITCH5070TI'},
    {kind:'cpuWhisper', endpoint:'http://localhost:8190'},
  ],
  ...
}
```

選択規則:

- **ロックは取得しない。** GPUバックエンドを使う前にロック状態だけを読み
  (`GET <gpuStatus>/lock/status`)、**誰かが保持していれば即座に次の候補へ落ちる**。
  自分では取らないので、こちらが他の利用者を締め出すことはない。
- **ロックが空いていれば、モードの切り替えは試みる**(`gpuMode`を設定したバックエンドのみ)。
  `GET <gpuStatus>/status`の`active_modes`に自分のモードが無ければ
  `POST <gpuStatus>/activate/<gpuMode>`を投げる。**これはそのGPUで動いていた他のモードを
  止める**ので、`gpuMode`は「止めてよい」と合意できているGPUにだけ設定する。
  切り替えはサービス再起動+モデルロードを伴い発話1つ分の待ち時間には到底収まらないので、
  **その発話は次の候補へ落とし**、切り替えの恩恵は後続の発話が受ける。
  空振りを繰り返さないよう、同じバックエンドからの切り替え要求は3分に1回まで。
  **元のモードへ戻すことはしない**(こちらの持ち物ではない)。
- **ロックされている間は何もしない。** モードも見に行かず、即座に次の候補へ落ちる。
- 呼び出しが失敗・タイムアウト(既定3秒)したら、その発話は**次の候補で1回だけ再試行**する。
  途中結果は捨てて確定結果だけ拾う(縮退中に途中結果まで追いかけると遅延が積み上がる)。
- 連続3回失敗した候補は60秒間スキップする(サーキットブレーカー)。60秒後に
  次の発話区間で自動的に再試行するので、**GPUが空けば会議の途中でも自動的に復帰する**。
- 全候補が使えないときはSTTだけが静かに止まる。通話・共有コンテンツ・チャットには
  一切影響させない。クライアントには状態を返し、UIで「今は使えない」と示す。

### 認識結果の注入と翻訳 (main.ts) {#ingest}

`media.ts` は結果を `sttResult` メッセージでmainへ返す。mainは
`MainServer`(mediasoupシグナリング中継)と`DataServer`を**同一プロセスで抱えている**ので、
そのまま部屋へ注入できる。

- **peer idはDataServerの参加者idと同一**。`Conference.enter()` が
  `rtcTransports.connect()` の返す `peer` をそのまま `dataConnection.connect(room, peer)` に
  渡しているため、mediasoup側のpeerとDataServer側のparticipantは1対1に対応する。
  この一致に依存するので、どちらかのid採番を変えるときはここも壊れる。
- 注入は `DataServer/sttIngest.ts` が担当し、`{t:'stt_t', p:peer, v:...}` という
  通常のメッセージを組み立てて `instantMessageHandler` と同じ経路で配る。
  クライアントから見ると「話者が送ってきたメッセージ」と区別が付かない。
- `sttStart`/`sttStop` は `MainServer/handlers.ts` の `setRelayHandlers()` に2行足すだけで
  workerへ中継される(`streamingStart`/`streamingStop`と同じ)。
  worker→mainの `sttResult` だけは中継せず、main.tsが `sttIngest` に渡す。

翻訳は確定結果のときだけ走る(`DataServer/translation.ts`)。

1. 翻訳先言語の集合を作る。部屋の各参加者の `storedMessages.get('p_lang')` を読み、
   `show` を集めて重複排除し、話者の言語を除く。**空なら何もしない**
   (全員が同じ言語なら翻訳は1回も走らない)。新しいサーバー状態は増やさない。
2. LRUキャッシュ(キー `${src}:${dst}:${text}`、プロセス全体で共有)を引く。
   相槌や定型の挨拶がよく繰り返されるので効きが良い。
3. 未ヒットぶんだけバックエンドを呼ぶ。同時実行数(既定4)と部屋ごとのレートを制限し、
   超過ぶんは捨てる(**遅れて出る字幕より出ない方がまし**)。
4. `SPEECH_TRANSLATION` を部屋の全員へ配る。`instantMessageHandler` と違い
   **話者自身にも送る**(話者の字幕表示言語が自分の発話言語と違うことがあるため)。

翻訳バックエンドは**優先順に並べた`translation.endpoints`**で、各エンドポイントには
**まだ埋まっていない言語だけ**を聞く。1つのモデルで全部を賄うより、得意なものを前に置く方が
質が上がるため: ja↔enは専用モデルのFuguMTが多言語モデルより明確に良く、FuguMTが知らない
zh/koはその後ろの多言語モデルが答える。落ちているエンドポイントは、それしか出せない言語だけを
失わせる。

| 実装 | 担当 | 備考 |
|---|---|---|
| FuguMT(CTranslate2、CPU) | **ja↔en** | `bm/stt-sidecars/translate_server.py`。このホストのCPUで常時動く |
| M2M-100 418M(CTranslate2、GPU) | **上記以外**(zh/ko等) | `gpu_whisper_server.py`の`/translate`。認識と同じプロセス・同じモード・同じ経路 |

**M2M-100(MIT)を既定にした理由**: NLLB-200の方が訳は良いが**CC-BY-NC(非商用)**で、
BinauralMeetは公開サービスなので**ライセンスがサービス全体に付いて回る**。
`MULTI_KIND=nllb`で切り替えられるようにはしてある。

翻訳を認識と同じプロセスに同居させたのは、モデルが認識器に比べて小さく、同じGPU・同じモード・
同じ経路に乗るため。GPUを取られれば両方止まるが、その時はCPU側のFuguMTがja↔enを拾う。

翻訳先言語の集合計算は `DataServer/TranslationTargets.ts` に純粋関数として切り出す。

### メッセージ型 {#messages}

`binaural-meet/src/models/conference/DataMessageType.ts` に追加する。このファイルは
`getSourceFromBM.sh` で bmMediasoupServer と vrcss にコピーされる生成元なので、
**追加後に必ず再生成する**。`DataServer` は `InstantMessageType`/`StoredMessageType` を
for-in で自動登録するので、中継だけならサーバーのコード変更は要らない
(翻訳と注入のために `SPEECH_TEXT` のハンドラだけ上書きする)。

| 型 | 値 | 分類 | merge | recordable | 向き |
|---|---|---|---|---|---|
| `SPEECH_INTERIM` | `stt_i` | Instant | `overwrite` | × | サーバー → 全員 |
| `SPEECH_TEXT` | `stt_t` | Instant | `instant` | ○ | サーバー → 全員 |
| `SPEECH_TRANSLATION` | `stt_tr` | Instant | `instant` | ○ | サーバー → 全員 |
| `PARTICIPANT_STT_LANG` | `p_lang` | Stored | `overwrite` | ○ | 各自 → 全員(+サーバーが保持) |

`merge` の選択理由: 途中結果は「最新の1件だけ意味がある」ので `overwrite`
(`findQueueSlot()` が同じ (type, peer, dest) のキュー済みメッセージを上書きするため、
送信が詰まっても古い途中結果は自然に捨てられる)。確定結果と訳文は履歴なので `instant`
(`CHAT_MESSAGE` と同じ。まとめて潰すと発話が消える)。

`PARTICIPANT_STT_LANG` を Stored にするのは、後から入室した人にも各参加者の希望言語が
届くようにするため。サーバーはこれを翻訳先集合の計算に使う。

**認識するかどうかは部屋のプロパティ**(`ROOM_PROP`の`stt`、`'true'`/`'false'`)。
DataServerは`room.properties`を保持していて`REQUEST_ALL`で新規参加者へ再送するので、
**後から入室した人も自動的に同じ状態になる**。個々の参加者が持つのは「自分が字幕を見るか」
(ローカル設定)と「話す言語・読む言語」だけ。

**送るのは`DataSync.sendAllAboutMe()`**(接続時と`REQUEST_ALL`/`REQUEST_TO`で
ローカル参加者の状態をまとめて publish する場所)。設定変更を監視する`autorun`だけに
任せてはいけない: 字幕言語はlocalStorageから**入室前に**復元されるので、戻ってきた
利用者は設定を一度も変更せず、接続状態はobservableでないため`autorun`は再実行されない。
結果として誰も翻訳先言語を申告せず、翻訳が一度も走らなくなる
(`CHANGELOG#2026-09-24-stt-lang-on-join`)。

```ts
export interface SpeechText{ sid:string, text:string, lang:string, ts:number }
export interface SpeechInterim{ sid:string, text:string, lang:string }
export interface SpeechTranslation{ sid:string, pid:string, texts:{[lang:string]:string} }
export interface SttLangInfo{ speak:string, show:string }   //  話す言語 / 字幕を読みたい言語
```

`sid` は `${pid}-${seq}`。途中結果・確定結果・訳文がこれで1つの発話に束ねられる。

### クライアント {#client}

`architecture#arch` のレイヤー規約(`stores/`は`@models/conference`をimportしない)を守る。

- `stores/room/Transcript.ts` — 発話の保持だけ。conferenceを知らない。
- `models/stt/SttClient.ts` — `sttStart`/`sttStop` の送信と、設定・ミュート状態の監視。
  `models/recorder/`と同じ位置付けで、conferenceとstoresの両方をimportしてよい。
- `components/` — 表示のみ。

`SttClient` は以下を `autorun` で監視し、`sttStart`/`sttStop` を送る:
`settings.stt.enabled` / マイクProducerの有無 / ミュート状態。
**ミュート時は必ず `sttStop` を送る**(サーバー側でもProducerのpauseを見て止めるが、
二重に止める)。送信は `RtcConnection` に `sttStart(producers, lang)` を足すだけで、
既存の `streamingStart()` と同じ形になる。

受信は `DataSync.registerMessageTypes()` に3行足す:

```ts
registerMessageType(MessageType.SPEECH_INTERIM, {merge:'overwrite',
  onReceive:(v, from)=>transcript.onInterim(from, v)})
registerMessageType(MessageType.SPEECH_TEXT, {merge:'instant', recordable:true,
  onReceive:(v, from)=>transcript.onFinal(from, v)})
registerMessageType(MessageType.SPEECH_TRANSLATION, {merge:'instant', recordable:true,
  onReceive:(v)=>transcript.onTranslation(v)})
```

`Transcript` ストアは `Utterance`(sid/pid/lang/text/final/translations/開始・終了時刻)を
最大1000件保持し(`Chat`と同じ上限方式)、`sid`と`pid`の索引を持つ。
表示側は `transcript.textFor(u, settings.stt.show)`(訳文があれば訳文、無ければ原文)を読む。

| 表示先 | 実装 |
|---|---|
| アバター脇の吹き出し | `settings.showSubtitles`がONのときだけ描く。`components/map/Participant/SpeechBubble.tsx`。`Participant.tsx`/`LocalParticipant.tsx` が名前ラベルの上に描く。**話し続けている間は発話がつながって伸び**、読み終わるだけの時間を置いてから消える(`#bubble`)。**聞こえる範囲の参加者だけ**に限定する(`participants.audibleArea()`) |
| 左バーのチャット欄 | `showSubtitles`がOFFなら`type:'stt'`の行は出さない(吹き出しだけ消えてチャットには流れ続ける、という中途半端を避ける)。確定時に `ChatMessage`(`type:'stt'`)を push し、`utterance` 参照を持たせる。`ChatLine` が `textFor()` を読むので、後から届いた訳文で行が自動更新される。既存のタイムライン・色・アバター表示をそのまま再利用 |
| 録画 | `recordable:true` により `Recorder.recordMessage()` が自動で拾う(`getRecordableTypes()`経由)。再生は `Player` に `onPlayback` を3型ぶん登録して同じ `Transcript` に流す |
| 書き出し | `Transcript.toText()` / `toVTT()` を `RecorderDialog` のボタンから呼ぶ。原文のみ/訳文のみ/併記を選べる |

### 吹き出しの見せ方 {#bubble}

字幕は「読める」ことが要件なので、表示時間と切れ目を発話の中身で決める。

- **表示時間は文字数に比例**(`bubbleDurationMs()`: 2.5秒 + 1文字あたり0.14秒、上限25秒)。
  固定秒数だと長い文が読み切れず、短い相槌はいつまでも残る。
- **話し続けている間は1つの吹き出しにつながって伸びる。** 直前の発話が終わってから
  次が始まるまでの無音が2.5秒以内なら同じ「ひと続き」とみなす。息継ぎでVADが切った
  ぶん(hangoverは0.5秒)まで別々の吹き出しにすると読みづらいため。
- **つながりの判定は「発話の時刻」で行い、到着時刻では行わない。** 認識は発話に
  数秒遅れ、その遅れも一定ではないので、到着間隔からは「話し続けている」のか
  「間が空いた」のか分からない。サーバーが`SpeechText`に載せる`ts`(発話が終わった
  時刻)と`durationMs`(その発話の長さ)から、無音の長さを直接計算する。
  一方**消えるまでの時間はローカル時計で測る** — 視聴者が見始めた時刻が基準だから。
  (この2つを混ぜると、サーバーとクライアントの時計のズレぶんだけ表示時間が狂う。)
- ひと続きが長くなりすぎたら(140文字目安)、**古い発話から落として**新しい方を残す。

UIはフッターのマイクボタン隣の字幕ボタン。**ボタン本体は「自分が字幕を見るか」**の切り替えで、
**部屋全体の認識ON/OFFはその「…」メニュー**に置く(言語の選択も同じメニュー)。
設定は `stores/room/Settings.ts`(localStorageへ永続化)の
`{showSubtitles, sttSpeak, sttShow}`。`showSubtitles`の既定はON——部屋が認識していない間は
どのみち何も出ないので、「部屋がONになった瞬間から見える」方が素直。

ボタンの見た目は3状態を区別する: 部屋が認識していない / しているが自分は見ていない /
見ている。サーバーが要求を拒否したときは理由をツールチップに出すが、**部屋のスイッチは
勝手に戻さない**——それは全員のもので、拒否は全員に等しく起きているため。

## 構成ファイル一覧 {#files}

| リポジトリ / ファイル | 役割 |
|---|---|
| `binaural-meet/src/models/conference/DataMessageType.ts` | 上記4型を追加(**3リポジトリへの再生成が必要**) |
| `binaural-meet/src/models/conference/DataMessagePayloads.ts` | 4型のペイロード定義 |
| `binaural-meet/src/models/conference/MediaMessages.ts` | `sttStart`/`sttStop`/`sttResult` のワイヤーフォーマット |
| `binaural-meet/src/models/conference/RtcConnection.ts` | `sttStart()`/`sttStop()` 送信(既存 `streamingStart()` と同型) |
| `binaural-meet/src/models/conference/DataSync.ts` | 3型の `registerMessageType` |
| `binaural-meet/src/models/stt/SttClient.ts` | 有効化・ミュート・言語設定の監視と送信 |
| `binaural-meet/src/stores/room/Transcript.ts` | `Utterance` の保持・索引・言語解決 |
| `binaural-meet/src/components/map/Participant/SpeechBubble.tsx` | アバター脇の字幕 |
| `binaural-meet/src/components/leftBar/Chat.tsx` | `type:'stt'` の行を扱えるように |
| `binaural-meet/src/components/footer/SttButton.tsx` | ON/OFFと言語選択 |
| `binaural-meet/src/models/recorder/Player.ts` | 3型の `onPlayback` 登録 |
| `bmMediasoupServer/src/MediaServer/stt.ts` | `SttSession`(PlainTransport + Consumer + ffmpeg + VAD + 再認識ループ) |
| `bmMediasoupServer/src/MediaServer/SttVadLogic.ts` | 発話区間判定の純粋ロジック(テスト対象) |
| `bmMediasoupServer/src/MediaServer/SttBackend.ts` | `SenseVoice`/`Whisper`/`CpuWhisper` の3実装と `SttBackendSelector`(`#fallback`) |
| `bmMediasoupServer/src/MediaServer/sdp.ts` | `createAudioSdpText()` を追加(既存関数は変更しない) |
| `bmMediasoupServer/src/MediaServer/ffmpeg.ts` | `SttFFmpeg`(生PCMを標準出力へ)を追加 |
| `bmMediasoupServer/src/MainServer/handlers.ts` | `sttStart`/`sttStop` の中継、`sttResult` の受け口 |
| `bmMediasoupServer/src/DataServer/sttIngest.ts` | 認識結果を部屋のメッセージとして注入 |
| `bmMediasoupServer/src/DataServer/translation.ts` | 翻訳先集合の算出・キャッシュ・バックエンド呼び出し |
| `bmMediasoupServer/src/DataServer/TranslationTargets.ts` | 翻訳先集合の純粋ロジック(テスト対象) |
| `bmMediasoupServer/config.js` | `stt.{backends[],maxSessions,interimIntervalMs,timeoutMs}`・`translation.{backend,endpoint}` |
| (別リポジトリ) STT/翻訳サイドカー | PCM→テキスト / テキスト→訳文 のHTTPサービス。BMのリポジトリには入れない |

## 実装状況 {#phases}

| 部分 | 状態 |
|---|---|
| 音声取り出し(PlainTransport + ffmpeg + VAD + 再認識ループ) | 実装済み・**実機確認済み**(実音声→字幕) |
| 認識バックエンドの選択とフォールバック | 実装済み。ロジックは単体テスト、`cpuWhisper`は実機確認済み。`sensevoice`への疎通のみ未確認(`#hostwork`)だが、**GPUからCPUへの縮退が実運用で働くことは確認済み** |
| 認識結果の注入・配信(`sttIngest`) | 実装済み・実機確認済み |
| `Transcript`ストア・吹き出し・チャット欄・設定UI | 実装済み・実機確認済み |
| 翻訳(`translation.ts`) | 実装済み・実機確認済み。ja↔enはFuguMT(CPU)、zh/koはGPUのM2M-100(2026-09-25にen→zhを実機確認) |
| Recorder/Playerへの登録 | 実装済み(`recordable`・`onPlayback`)・未検証 |
| テキスト/VTT書き出し | **未実装** |

残っているのは**書き出し**(未実装)と、**Recorder/Playerでの再生時の字幕**(実装済み・未検証)。
それ以外は実音声で一本通っている。本番で動かすのに要るホスト作業は`#todo`。

## ホスト側で必要な準備 {#hostwork}

**このコンテナの中からはできない作業**をここに集約する。BMのコードは全て実装済みなので、
音声から字幕までを一本で通せるかどうかは、以下が揃うかどうかだけで決まる。

### 残っているホスト作業 {#todo}

**本番は `main` + `media1` + `media2` + `binaural.me`(クライアント配信)**という構成で、
このワークスペースのdev環境とも`vrc-jp`のvrc.jpとも別マシン。

**役割ごとに要るものが違う**——この機能はmainとmediaの両方に跨っているため:

| マシン | 何をする | 要るもの |
|---|---|---|
| `media1` / `media2` | 音声を取り出して認識する(`stt.ts`) | **`ffmpeg`**、`config.js`の**`stt`ブロック**、`LM_HASELAB_API_KEY` |
| `main` | 認識結果を部屋へ配り、翻訳を呼ぶ(`sttIngest`/`translation.ts`) | `config.js`の**`translation`ブロック**、`LM_HASELAB_API_KEY`。**ffmpegは不要** |
| `binaural.me` | クライアントを配る | 新しいビルド(**これが無いとSTTのUI自体が無い**) |

CPUサイドカー(8190/8191)はこのホストのループバックにしか無く、本番のどのマシンからも
届かない。GPUサービスは`lm.haselab.net`経由なら届き、**認識と翻訳が同じサービス(8192)
なのでパスを1本通せばmediaもmainも賄える**。

| # | やること | どこに | 確認方法 |
|---|---|---|---|
| 1 | **`lm.haselab.net` にGPUサービスへのパス**(例 `/GPUWHISPER/` → `192.168.91.101:8192`) | プロキシ | `curl -H "Authorization: Bearer <key>" .../GPUWHISPER/health` が `{"model":"large-v3-turbo",...,"translator":"m2m100"}`。**素のHTTP**(POST 1往復、WebSocketではない)。ボディ上限1MB以上、読み取りタイムアウト20秒超 |
| 2 | **`ffmpeg`** | media1, media2 | `ffmpeg -version`。無いと`sttStart`がspawnで失敗し字幕が一切出ない(通話は無事)。RTSP配信と同じ依存 |
| 3 | **`LM_HASELAB_API_KEY`** | media1, media2, main | キーはこのホストの`/opt/lm-tool/lm-tool.env`。未設定だと無認証で弾かれ、**「GPUが塞がっている」のと区別の付かない失敗**になる |
| 4 | **既定ブランチ(`binaural-meet`は`master`、`bmMediasoupServer`は`main`)をビルド・配置** | 全マシン + binaural.me | `config.js`は各マシン固有の値が入っているのでpullで上書きせず、該当ブロックだけ足す |
| 5 | **(選択)CPUサイドカーを本番にも置く** | media*(認識)、main(翻訳) | `BinauralMeet/stt-sidecars`(公開リポジトリ)はCPUのみでGPU不要。**入れると**GPUが塞がっている間も字幕が出て、ja↔enの訳がFuguMTになり質が上がる。**入れないと**その時間は字幕が止まり、ja↔enもM2M-100が訳す |
| 6 | (任意)`lm-tool`のヘルプとdocを更新 | このホスト | rtx5070tiに`gpuwhisper`モードが増えた。パッチは受け渡し済み |

`media1`/`media2`の`config.js`:

```js
stt: {
  backends: [
    {kind: 'gpuWhisper', endpoint: 'https://lm.haselab.net/GPUWHISPER/asr',
      gpuStatus: 'https://lm.haselab.net/SWITCH5070TI', gpuMode: 'gpuwhisper',
      apiKeyEnv: 'LM_HASELAB_API_KEY', timeoutMs: 20000},
  ],
  maxSessions: 8,           //  ワーカーごと。media1とmedia2で合計16
  interimIntervalMs: 900, hangoverMs: 600,
},
```

`main`の`config.js`:

```js
translation: {
  endpoints: [
    {endpoint: 'https://lm.haselab.net/GPUWHISPER/translate',
      apiKeyEnv: 'LM_HASELAB_API_KEY', timeoutMs: 8000},
  ],
  timeoutMs: 5000, maxConcurrent: 4, cacheSize: 2000,
},
```

**GPUサービスは全ワーカーで共有される。** `WHISPER_WORKERS`(既定2)が同時に捌ける本数なので、
media1とmedia2で同時に喋る人が増えると待ち行列ができる。増やすときはVRAMと相談
(large-v3-turbo fp16が1本あたり約1.5GB)。

**途中で止めても壊れない**: 1が未了なら`stt.backends`を空のままにしておけば、STTを
有効にしたクライアントに拒否が返るだけ。通話・共有コンテンツには一切影響しない。

**本番で動き出すと、GPUが空いているときにBMが自分でrtx5070tiを`gpuwhisper`モードへ
切り替える**(=ComfyUIが止まる)。ロックを取っている間は手を出さない(`#fallback`)。

### 済んでいるもの {#done}

4点とも揃い、`config.js`の`stt.backends`/`translation.endpoint`に配線済み
(`CHANGELOG#stt-hostwork-sidecars`)。

| # | 用意したもの | 状態 |
|---|---|---|
| 1 | 認識サービスへのHTTPパス(rtx5070tiのSenseVoice、マシン上のport 8189) | **既に用意されていた**。`lm.haselab.net`の`/SENSEVOICE/`(`lm-tool#arch`のGPU切り替え対象、BMとは別の目的で先に公開済み)がそのまま使える(`config.js`の`stt.backends[0].endpoint`は`https://lm.haselab.net/SENSEVOICE/asr`)。疎通は未確認(`#todo`の2) |
| 2 | 上記パスのロック状態の読み取り | **既に用意されていた**。`https://lm.haselab.net/SWITCH5070TI/lock/status`が実機確認済み(`GET`→`{"locked":false}`、2026-09-24) |
| 3 | 翻訳サービス(CTranslate2 + FuguMT)のHTTPパス | 新設。`bm/stt-sidecars`(別リポジトリ、bmワークスペースの兄弟ディレクトリ)が`8191/translate`をこのホストのCPUで提供、systemd管理。ja→en/en→jaで実機確認済み。詳細・なぜHelsinki-NLPのen->jap系を採らずFuguMTにしたかは`bm/stt-sidecars/README.md` |
| 4 | 縮退用の `cpuWhisper` サイドカー(faster-whisper small、CPU) | 新設。同じく`bm/stt-sidecars`が`8190/asr`で提供、systemd管理。実音声で実機確認済み |
| 5 | `ffmpeg` | ホスト・sandboxコンテナの両方に導入済み(5.1.9)。コンテナ内でも`ffmpeg -version`が通り、実際に音声取り出しが動作した |
| 6 | `gpuWhisper`(rtx5070ti、`192.168.91.101:8192`) | 配備済み。`C:\Home\work\gpuwhisper\`に専用venv、`control_api.py`に`gpuwhisper`モードを追加(`hidream`/`sensevoice`/`irodori`と同じ扱い、`WHISPER_PROMPT`もそこで渡す)。待受は`sensevoice`(8189)と同じく`0.0.0.0`——**プロキシは別マシンにあるのでループバックのままでは公開できない**。開発チェックアウトは`start-dev.sh`のSSHトンネル経由、本番は`#todo`の1で生やすパス経由。Windows特有のCUDA DLL問題とcuBLASのバージョン固定は`bm/stt-sidecars/README.md#gpu` |
| 7 | サイドカーのコンテナからの到達性 | 両サイドカーを`127.0.0.1`に加え`172.17.0.1`(docker0)にも待受けさせ、`ufw allow in on docker0 to any port 8190/8191 proto tcp`で範囲を同ホストのコンテナ限定に絞って開放。`config.js`の両エンドポイントも`localhost`→`172.17.0.1`に更新。コンテナ内(`docker exec devbox-hase curl http://172.17.0.1:8190(/8191)/health`)から200を実機確認済み(`CHANGELOG#stt-sidecar-docker0-expose`)。**認証なしで同ホストの全sandboxコンテナから到達可能になったことは受け入れたトレードオフ**(`bm/stt-sidecars/README.md#known-limits`) |
| 8 | ai4に`cpuWhisper`(faster-whisper medium)を追加、CPU3段構成に | ai1と同一構成の予備機ai4(ほぼ無負荷)に`bm/stt-sidecars`一式を配備、`stt-cpu-whisper.service`を`CPU_WHISPER_MODEL=medium`で起動。ai1→ai4はポートフォワード専用に制限した専用SSH鍵(`permitopen`でai4のループバックのみ)を使う`ai4-stt-tunnel.service`(ai1側systemd常駐)経由、`config.js`は`172.17.0.1:8193`。`stt.backends`内の順序は`gpuWhisper` → ai4の`cpuWhisper`(medium、この行) → ローカルの`cpuWhisper`(small、常時利用可能な最終フォールバック)。11秒の音声で実時間比0.45倍(smallは0.24倍)、実機確認済み(`CHANGELOG#ai4-cpu-whisper-medium`) |
| 9 | `lm-tool`のヘルプ更新(`gpuwhisper`モード分) | コンテナ内で用意されていたパッチ(`activate-hidream`等の「stops sensevoice/irodori」表記に`gpuwhisper`を追加、`activate-gpuwhisper`サブコマンド新設)を、ホスト側`root`が`/opt/lm-tool/lm_tool.py`に適用(コンテナからは書き込めない共有ファイルのため)。適用前に`patch --dry-run`・適用後に構文チェックと`lm-tool activate-gpuwhisper --help`で実機確認済み(2026-09-26) |

BM側はどれも「エンドポイントURLを `config.js` に書くだけ」で繋がる形にしてあり、
サービスの実装・配置・認証方式には依存しない。

## セキュリティ上の要点 {#security}

- **`sttStart` の送信元がそのProducerの所有者か検証する。** 他人のProducer idを
  指定して他人の発話を文字起こしできてはならない。既存の `streamingStart` は
  この検証をしていない(`bmMediasoupServer-rtsp-streaming#security`)が、
  STTは同じ穴を開けない。
- **音声は保存しない。** ffmpegの出力はメモリ上のリングバッファだけを通り、
  ファイルにも外部ストレージにも書かない。認識サイドカーへ送るのは発話区間のPCMのみで、
  サイドカー側にも保存させない。
- **認識結果は部屋の全員に配信される。** 個人宛ではない。
- **認識のON/OFFは部屋単位で、誰か1人が入れると全員の発話が文字になる。**
  既定はOFF。自分の発話を認識させたくない参加者に残されているのはミュートだけなので、
  「この部屋は今それをしている」と分かる表示(参加者ごとのインジケータ)と、
  管理者による禁止(下の`sttPolicy`)は**まだ実装されていない宿題**。
- 部屋ポリシー `sttPolicy`(`'allow'|'deny'`、`ROOM_PROP` 経由、`RoomPropertyName` を拡張)で
  管理者が部屋ごとに禁止できる。`deny` のときは**サーバー側で `sttStart` を拒否する**
  (クライアントのUIも無効化するが、クライアントの実装を信用しない)。
- 認識バックエンドがGPU機にある場合、発話音声はそのマシンへ送られる。
  部屋の参加者に対して「音声がどこまで出て行くか」を説明できる状態を保つこと。

## 運用 {#ops}

### GPUバックエンドとの付き合い方

- **BMはGPUを取りにいかない。** ロックは読むだけで取得せず、モードの切り替えもしない
  (`#fallback`)。GPUが他の用途で塞がっている間は `cpuWhisper` へ落ちて動き続け、
  空けば次の発話区間で自動的に戻る。**BMのために他の作業を止める必要は無い。**
- 逆に言えば、GPUの認識品質が欲しい会議の前には、rtx5070tiが認識用モードで
  動いていてロックされていない状態にしておく必要がある(詳細はホストの
  `lm-tool` ドキュメント)。BM側からその状態を作りにはいかない。
- ホスト側で用意が要るものは `#hostwork` に集約してある。何も無い状態でも
  `cpuWhisper` だけで一通り動く。

### 開発中の確認

- `media.ts` のSTTセッションは `streamingStart` と同じくメッセージ駆動なので、
  クライアントを立ち上げずに `sttStart` を手で送れば単体で試せる。
- **認識結果から字幕までの経路は、workerのふりをして `sttResult` を直接送れば
  ffmpegも認識サイドカーも無しで確認できる**。`workerAdd` でmainに登録し、
  直後に `workerUpdate` で巨大な `load` を報告してから送ること
  (報告しないと `getVacantWorker()` が本物のpeerをこちらへ回してしまう)。
  実際の手順は `CHANGELOG#2026-09-24-stt-translation-implemented` に記録がある。
- 純粋ロジック(`SttVadLogic`・`SttBackend`・`TranslationTargets`・`Transcript`)は
  単体テストで押さえる。それ以外は `vitest`+`tsc --noEmit` では足りず、
  CDP経由の実機確認が要る。
- **バックエンドとのやりとりは`vitest`に含めない手動スクリプトで確認する**
  (実サービスが要るため)。どちらもエンドポイントを引数で差し替えられるので、
  モックにも実サイドカーにも同じものを向けられる:

  ```sh
  cd bmMediasoupServer
  npx ts-node src/MediaServer/__tests__/sttBackendLive.ts  <asr-url> [<gpu-status-url>]
  npx ts-node src/DataServer/__tests__/translationLive.ts  [<translate-url>]
  ```

  サイドカーに届かない環境では、`stt-sidecars`と同じ契約(`lang`が言語コードでなければ
  500、未対応ペアはキーごと省略)を実装したモックを立てて同じスクリプトを向ければよい。

### 容量の目安

同時に喋る人数ぶんだけ認識が走る。`stt.maxSessions`(既定8)を超える要求は拒否し、
クライアントには「今は使えない」と返す(黙って無視しない)。
GPU1枚で捌ける同時話者数は**未計測**。Phase 1 で実測してここに書く。

## 既知の制限 {#limits}

- **途中結果は、認識が発話区間より速いバックエンドでないと一度も表示されない。**
  `cpuWhisper`(faster-whisper small、CPU)は1秒の音声に1.2〜2.4秒かかる実測で、
  1.5秒ごとの再認識が返る頃には区間が閉じており、`segment.closed`で捨てられる。
  30秒間400ms間隔で監視して未確定の発話は0件だった(`CHANGELOG#2026-09-25-stt-e2e`)。
  **`interimIntervalMs`はGPUバックエンドが繋がるまで実質無効**で、字幕は確定単位で出る。
- **VADは無音0.5秒で区間を切るので、字幕が文の途中で切れる。** `hangoverMs`を伸ばせば
  まとまるが、そのぶん字幕が出るまでの待ちが伸びる。
- **`ffmpeg`が要る。** `media.ts`を動かすマシン(開発ではsandboxコンテナ、本番ではホスト)の
  両方に必要。RTSP配信(`bmMediasoupServer-rtsp-streaming`)も同じ前提。

- **途中結果の遅延はブラウザ内認識より大きい。** RTP→ffmpeg→VAD→認識→DataServerの
  ポーリング配信を通るため、話者自身の字幕も往復してから出る。
  自分の発話をローカルで先出しすることはできない(サーバーしか認識結果を持たない)。
- **VADが既定でエネルギー方式**なので、背景騒音の大きい環境では無音区間を発話と誤検出する。
  精度を上げるならSilero VAD(onnxruntime-node)への差し替えが必要で、
  サーバーにネイティブ依存が増える。
- **GPUバックエンドが使えるかは会議のたびに変わる。** ロックを取らない以上、
  他の利用者がGPUを使い始めれば会議の途中でCPU縮退に落ちる。落ちたこと自体は
  参加者には見えず、**認識精度だけが静かに変わる**(日本語の短発話で顕著)。
  切り替わりは `media` のログに残す。
- **話者が言語を切り替えてから追従するまで30秒前後かかる**(実測33〜40秒、発話間隔による)。
  その間の発話は前の言語として扱われ、翻訳の向きもそのままになる。すぐ切り替えたいときは
  メニューで話す言語を明示すればよい(そちらは即反映)。
- `streaming.ts` と同じく、**対象Producerが載っているworker上でしかSTTは動かない**
  (`media.ts` の `producers` マップを直接参照するため)。複数worker構成では
  話者ごとに別workerでSTTが走ることになる。
- 翻訳は確定発話単位なので、長い一続きの発話では訳文が出るまで数秒空く。
- ここに書いた速度・遅延の数値は**いずれも見積もりで、実測ではない**。Phase 1 で測って置き換える。

## 設計判断の記録 {#design}

- **STTをサーバー側にした(2026-09-24、方針変更)**: 当初はChromeのWeb Speech APIを
  既定にする設計だったが、同APIは`MediaStreamTrack`を受け取れず**OS既定の入力デバイスを
  勝手に掴む**ため、BMで別のマイクを選んでいるとSTTだけ違う音を聞く。API側に
  デバイス指定手段が無く回避不能で、これがそのまま「字幕が出ない・他人の声を拾う」
  という説明しづらい不具合になる。サーバー側で**BMが実際に送っているProducerそのもの**を
  認識すれば、この不一致は原理的に起きない。Chrome限定という制約も同時に消える。
  代償として、GPU(または縮退のCPU)というサーバー資源と、その運用が新たに必要になる。
- **音声の取り出しにRTSP配信の仕組みを流用した**: `PlainTransport`でconsumeして
  ffmpegに渡す経路は `streaming.ts` で実績がある。新規に書くのは出力形式
  (RTSP push → 生PCM)とSDPの音声のみ対応だけで済み、既存関数は壊さず別途足す形にした。
- **翻訳をサーバー側にした**: 同じ発話を参加者N人がそれぞれ翻訳すると同じ計算をN回行う。
  ローカルモデル(=有限の計算資源)を使う前提と噛み合わないため、サーバーで1回だけ翻訳して
  多言語ペイロードを配る。代償として、DataServerがこれまで持っていなかった
  「外部サービスを呼ぶ」責務を持つ。
- **多言語ペイロードを全員に配り、宛先ごとに配り分けない**: 部屋の言語数は実際には2〜3で、
  全言語を1通に入れても帯域はたかが知れている。配り分けをやめることで、
  参加者が途中で字幕言語を変えても過去の発話をその場で表示し直せる、
  録画に全言語が残る、という利点が付いてくる。
- **原文と訳文を別メッセージにした**: 翻訳の遅延が原文字幕の表示を遅らせないため。
  1通にまとめると、翻訳が遅い/落ちているときに字幕そのものが出なくなる。
- **途中結果を翻訳しない**: 途中結果は1発話あたり十数回更新される。翻訳すると計算量が
  桁で増え、しかも訳文が目まぐるしく書き換わって読めない。
- **GPUロックを取らず、失敗したら縮退する形にした(2026-09-24、ユーザーの指示)**:
  会議は数十分続くので、その間ロックを保持するとGPUを長時間占有してしまう。
  BMは「空いていれば使う、塞がっていれば諦める」側に回り、品質の変動を受け入れる。
  **ただしロックが空いていればモードの切り替えは試みる(2026-09-25、ユーザーの指示)**:
  当初は「他人の作業を止めてまで奪わない」として切り替えもしない設計だったが、
  それだと誰かが手でsensevoiceモードにしている時しかGPUを使えず、実際には
  ほぼ常にCPUへ落ちていた。ロックは「今この GPU で作業中」の意思表示なので、
  **ロックされていない=空いている**とみなして切り替える方に倒した。
  これにより、認識バックエンドの可用性がBMの可用性に影響しなくなる
  (最悪でもCPU縮退で字幕は出続ける)という副次的な利点もある。
  代償として、同じ会議の中で認識精度が変動しうる。
- **翻訳の既定をCPUで完結するモデルにした**: GPU機は排他切り替え・ロック制で、
  会議中ずっと押さえられる保証が無い。認識でGPUを使う以上、翻訳まで同じGPUに
  依存させると片方の都合で両方止まる。翻訳は小さいモデルでも実用になるので、
  CPU側に逃がして依存を1つに減らした。
- **認識結果を「話者からのメッセージ」として注入する形にした**: クライアントから見ると
  `stt_t` は他の参加者メッセージと同じ形で届き、`MessageTypeRegistry` に登録するだけで
  受信・録画・再生の3経路に自動的に乗る。サーバー発であることをクライアントに
  意識させない方が、既存の仕組みへの追加が最小になる。
- **既存の `InstantMessageType`/`StoredMessageType` に型を載せた**: DataServerは
  両カテゴリを for-in で自動登録するため、中継だけならサーバーは無改修で動く。
  翻訳という追加処理が要る `SPEECH_TEXT` だけをハンドラ上書きで特別扱いする。
- **途中結果の安定化(LocalAgreement)を入れなかった**: 「前回の仮説と先頭から
  一致する部分までを確定扱いにする」手法は、確定部分と未確定部分を別々に描ける
  UIでこそ効く。ここでは字幕は1本の文字列として出すので、結局は最新の仮説を
  丸ごと表示することになり、実装しても表示は1文字も変わらない。
  代わりに「常に最新の仮説を出す」とだけ決めてある(Chromeの音声認識APIと同じ挙動)。
- **言語判定は時間で減衰させる(2026-09-26、ユーザーの指示)**: 当初は「一度決めたら戻さない」
  設計にしていた——1文の聞き間違いで判定が飛ぶ方が、話者が言語を変えるより多いと考えたため。
  実際には**話者は言語を切り替える**というので、証拠を半減期20秒で減衰させる形にした。
  古い発話は時間とともに効かなくなるので、切り替えて話し続ければ30秒前後で追従し、
  1文だけ違う言語に聞こえても揺れない。判定は**話者ごと**に独立していて、
  同じ部屋に別々の言語の話者が混ざっていても互いに影響しない。
- **認識は部屋単位、表示は各自(2026-09-26、ユーザーの指示)**: 当初は参加者ごとのON/OFFに
  していたが、字幕は会話の場の性質であって個人の設定ではない——自分だけONにしても
  自分の声しか字幕にならず、会議の役に立たない。認識するかどうかは部屋が決め、
  各自が決めるのは「見るか」と「どの言語で読むか」だけにした。
- **ミュート時はクライアント・サーバーの両方で止める**: 「ミュートしたのに字幕が出る」は
  プライバシー事故であり、片側の実装ミスで起きてはならない不変条件として二重化する。
