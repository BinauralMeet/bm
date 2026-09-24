# CHANGELOG — bm/ ワークスペースの変更履歴

**いつ読むか**: いつ・なぜ今の状態になったか調べる / 過去の動作確認の記録を探す /
変更を加えたので追記する

日付が付く記録はここに。現在形の事実は各 topic README へ。

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
