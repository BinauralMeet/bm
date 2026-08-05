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
│   └── docs/                # このリポジトリ自身のdoc-toolツリー(下記参照)
├── bmMediasoupServer/      # シグナリング/mediasoupサーバー (main + media プロセス)
├── vrcss/                  # 別系統の軽量クライアント (mediasoup-client + MUI)
├── docs/                   # このディレクトリ。bm自体の運用ドキュメント
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

**ドキュメントの実体は各リポジトリ自身に置く。** 各リポジトリが自分の
`docs/bin/doc`(doc-tool)を導入すれば、そのリポジトリを単体でcloneしても
docsを読める。この `bm/docs/bin/doc` は一つ上の階層の `.gitmodules` を見て、
自分の `docs/CHANGELOG.md` を持つsubmoduleがあれば自動的にそのdocsも索引に
混ぜる(`binaural-meet/docs/` を今はこの方法で取り込んでいる。topic idは
`<submodule名>-<topic>` というフラットな形になる。例:
`binaural-meet-architecture`)。bmMediasoupServer/vrcssにはまだdocs自体が無いので
未導入。導入すれば自動的にここに混ざる(doc-tool側の変更は不要 — `ForHuman#workspace`
参照)。

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
- submoduleのCHANGELOGは `bm` 側の `doc log` には混ざらない。`doc check` の
  相互参照検証も集約されたdocには行わない(`ForHuman#workspace` の既知の制限
  参照)。どちらもそのsubmoduleに `cd` して確認する。

## 設計判断の記録

- **モノレポ化はしない**: 3リポジトリはそれぞれ別の公開先・別のリリースサイクルを
  持つため、無理に1つのビルドグラフにまとめるより、`bm/` はドキュメントと
  横断的な運用スクリプトだけを持つ薄い層にとどめる方針にした。
- **ドキュメントの集約方針を撤回した(2026-08-05)**: 以前は「ドキュメントは全て
  `bm` に集約する」方針だったが、これだと各リポジトリを単体でcloneした人が
  自分のコードの設計docsに一切アクセスできない、という問題があった。doc-tool
  自体にsubmodule集約機能(`ForHuman#workspace`)を実装し、各リポジトリが自分の
  docsを持ちつつ `bm` からは自動的に読みに行く形に変更した。
