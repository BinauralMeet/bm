# CHANGELOG — bm/ ワークスペースの変更履歴

**いつ読むか**: いつ・なぜ今の状態になったか調べる / 過去の動作確認の記録を探す /
変更を加えたので追記する

日付が付く記録はここに。現在形の事実は各 topic README へ。

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
