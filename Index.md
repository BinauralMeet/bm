# /home/hase/sandhome/bm/docs — 全ツリー索引

binaural-meet-architecture                 architecture — binaural-meetのレイヤー規約  [44L]
                                             → `stores/` 配下に新しいimportを足す / `conference` と
                                               `sharedContent`(または他のstore)の間で依存を追加しようか迷う / 循環依存の
                                               警告やバンドルの問題に遭遇した
binaural-meet-auto-load-adjustment-design  自動負荷調整機能  [267L]
                                             → 自動負荷調整機能(クライアント側の負荷検出・購読数自動調整)を触る /
                                               `LoadAdjuster`/`LoadAdjusterLogic`の閾値・上限テーブルを調整する /
                                               この機能の 設計判断・見送った案を確認する
binaural-meet-conference                   conference — 通話・シグナリングのオーケストレーション層  [116L]
                                             → `src/models/conference/` に触る / `Conference`/`RtcTransports`/
                                               `DataConnection`のどれに何を書けばいいか迷う /
                                               入室・退室・再接続のフローを確認する
binaural-meet-developmentguide             Development Guide  [76L]
                                             → binaural-meetの開発環境を初めてセットアップする /
                                               利用可能なyarnスクリプトを確認したい
binaural-meet-refactoring-plan-done        リファクタリング計画(完了・記録として保持)  [379L]
                                             → `refactor/architecture-cleanup`
                                               ロードマップの各フェーズで何を判断したか調べる /
                                               当時なぜその設計を選んだか(採らなかった案も含め)確認する
binaural-meet-sharedcontents               Shared contents  [51L]
                                             → sharedContent周りのstore(ContentStore/ContentSyncService/ContentTrackStore/PlaybackStore)に触る
                                               / コンテンツの同期・zorder・RTCトラックの扱いを確認する
binaural-meet-testingguide                 Testing Guide (test.binaural.me)  [114L]
                                             → このホスト上でBinaural Meetを動かして手動・CDP経由でテストする
bmMediasoupServer-architecture             architecture — main/mediaサーバー構成とクライアントプロトコル  [105L]
                                             → `src/MainServer/`・`src/MediaServer/`・`src/DataServer/`のどこに
                                               何を書けばいいか迷う / `main.ts`と`media.ts`の関係を確認する /
                                               クライアント (binaural-meet/vrcss)との通信プロトコルを確認する
bmMediasoupServer-rtsp-streaming           rtsp-streaming — mediasoupトラックをRTSPへ変換して配信する機能  [60L]
                                             → `MediaServer/streaming.ts`/`ffmpeg.ts`/`sdp.ts`/`port.ts`に触る /
                                               RTSP配信が始まらない・映像が出ない原因を調べる /
                                               `vrcss`(VRChatへの画面共有)が 何を前提にこのサーバーを使っているか確認する
dev-environment                            sandboxでの開発・動作確認  [77L]
                                             → このワークスペースを sandbox コンテナ上で動かす / vite の変更が
                                               反映されない / mediasoup の音声・映像が繋がらない / `skipEntrance`
                                               を使ったのに 入室しない / headful debug Chrome が起動しない /
                                               アバター一覧が空になる
stt-translation                            サーバー側音声認識と翻訳字幕  [506L]
                                             → 発話の文字起こし・翻訳字幕機能を実装する / `MediaServer`のSTTセッションや
                                               `DataServer`の翻訳ハンドラに触る /
                                               字幕が出ない・訳文が来ない原因を切り分ける /
                                               STTエンジンや翻訳バックエンドを差し替える /
                                               rtx5070tiをBMの認識バックエンドとして使う
vrcss-screen-sharing                       screen-sharing — VRChatのビデオプレイヤー向けRTSP画面共有  [84L]
                                             → `src/App.tsx`/`src/Preview.tsx`/`src/getDisplayMedia.ts`に触る /
                                               配信URLがVRChat側で映らない原因を調べる /
                                               このツールが何を前提に動いているか 確認する
workspace                                  bm/ 全体の構成  [75L]
                                             → このワークスペースで初めて作業する / `start-dev.sh`・`smoke.mjs`
                                               が何をするものか知りたい / 3つのリポジトリの関係を確認したい /
                                               どこに何を書けば いいか(このリポジトリ vs binaural-meet vs
                                               bmMediasoupServer)迷ったとき
rules                                      このツリーの書き方  [61L]
ForHuman                                   doc ツールの説明（人間向け）  [107L]
                                             → doc ツールが何なのか知りたい / 全コマンドを知りたい / 規約がその形である
                                               理由を知りたい / 消した内容を git から戻したい（Claude
                                               は通常不要。書くときの規約は `rules` に全部ある）
CHANGELOG                                  bm/ ワークスペースの変更履歴  [366L]
                                             → いつ・なぜ今の状態になったか調べる / 過去の動作確認の記録を探す /
                                               変更を加えたので追記する
