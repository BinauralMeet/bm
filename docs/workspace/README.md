# workspace — bm/ 全体の構成

**いつ読むか**: このワークスペースで初めて作業する / `start-dev.sh`・`smoke.mjs`
が何をするものか知りたい / 3つのリポジトリの関係を確認したい / どこに何を書けば
いいか(このリポジトリ vs binaural-meet vs bmMediasoupServer)迷ったとき

## 構成

`bm/` は3つの独立した git リポジトリを束ねる作業フォルダで、モノレポではない
(共通のビルド・依存関係管理はない)。

```
bm/                        # このリポジトリ。運用ドキュメントとdevスクリプトのみ
├── binaural-meet/          # クライアント (React + MobX + mediasoup-client)
├── bmMediasoupServer/      # シグナリング/mediasoupサーバー (main + media プロセス)
├── vrcss/                  # 別系統の軽量クライアント (mediasoup-client + MUI)
├── docs/                   # このディレクトリ。3リポジトリ分のドキュメントもここに集約
│   └── binaural-meet/      # 旧 binaural-meet/docs/ の内容(下記参照)
├── logs/                   # start-dev.sh / smoke.mjs の実行時出力 (git管理外)
├── start-dev.sh
├── smoke.mjs
└── repro-avatar.mjs
```

- **binaural-meet** — remote: `https://github.com/BinauralMeet/binaural-meet.git`
- **bmMediasoupServer** — remote: `https://github.com/BinauralMeet/bmMediasoupServer.git`
- **vrcss** — remote: `https://github.com/BinauralMeet/vrcss.git`。mediasoup-client
  ベースの別クライアント。このワークスペースでの作業はまだ binaural-meet /
  bmMediasoupServer 側に偏っており、vrcss はほぼ未調査。

**ドキュメントは(コード自体とは違い)すべてこのリポジトリに集約する。**
各リポジトリのコード自体は当然そのリポジトリに残るが、Markdownドキュメントは
`docs/bin/doc` で索引・検索できるようこのツリー配下に置く
(`docs/binaural-meet/` が旧 `binaural-meet/docs/` の内容。bmMediasoupServer/vrcss
はまだ移していない)。各リポジトリの `README.md` は「そのコードを単体で
clone した人向けの最小限の案内」だけに留める。

## 構成ファイル一覧

| ファイル | 役割 |
|---|---|
| `start-dev.sh` | main/media/client の3プロセス + portfwdリース更新を起動・停止する。詳細は `dev-environment#ops` |
| `smoke.mjs` | headful debug Chrome 経由で実際に部屋に入り、ステータスダイアログをスクリーンショット。動作確認の主手段 |
| `repro-avatar.mjs` | 3Dアバター関連の2バグ(`CHANGELOG#2026-08-02-vrm-cors-fix` 参照)の再現・回帰確認用スクリプト |

## 運用

- 新しい調査や修正を始める前に `docs/bin/doc` で索引を見てから、必要な topic
  だけ `docs/bin/doc show <topic>#<節ID>` で開く。
- 3リポジトリはそれぞれ別のPR/コミット履歴を持つ。ある変更がクライアント/
  サーバーどちらに属するかで、コミットは対応するリポジトリで作る。

## 既知の制限

- モノレポツールが無いので、3リポジトリ間でバージョンや依存関係を揃える仕組みは
  無い。手動で追従する。

## 設計判断の記録

- **モノレポ化はしない**: 3リポジトリはそれぞれ別の公開先・別のリリースサイクルを
  持つため、無理に1つのビルドグラフにまとめるより、`bm/` はドキュメントと
  横断的な運用スクリプトだけを持つ薄い層にとどめる方針にした。
