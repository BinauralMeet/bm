# CHANGELOG — bm/ ワークスペースの変更履歴

**いつ読むか**: いつ・なぜ今の状態になったか調べる / 過去の動作確認の記録を探す /
変更を加えたので追記する

日付が付く記録はここに。現在形の事実は各 topic README へ。

## 2026-07-28 — binaural-meet と bmMediasoupServer を bm/ に集約 {#2026-07-28-workspace-consolidation}

それまで `binaural-meet` 単独で `/home/hase/sandhome/binaural-meet` に、
`bmMediasoupServer` は Claude から触れない場所にあった。両方を `bm/` 直下に集約し、
以後は組み合わせワークスペースとして扱う方針にした。モノレポ化はしていない
(2リポジトリ+vrcssはそれぞれ独立した git リポジトリ・remoteのまま)。

## 2026-07-28 — binaural-meet アーキテクチャ整理ロードマップ完了 {#2026-07-28-refactor-roadmap}

`refactor/architecture-cleanup` ブランチで9フェーズの構造整理を実施(store群の
ドメイン再編、`SharedContents` ↔ `conference` の循環依存解消、`ISharedContent` の
discriminated union 化、`SharedContents` god-class の4ストア分割、
`StereoParameters` 命名衝突の解消、GDrive認証状態の集約)。詳細は binaural-meet
リポジトリの `docs/refactoring-plan-DONE.md`(完了記録として保持)とその
コミット履歴(`git log`、各 "Phase N: ..." コミット)を参照。PRはまだオープンして
いない。

## 2026-07-28 — ROOM_PROPのキューイング衝突バグ修正 {#2026-07-28-room-prop-fix}

`DataConnection.sendMessage()` が未送信メッセージを `(type, room, peer, dest)`
だけで一本化していたため、`ROOM_PROP`(名前の異なる複数プロパティを多重化する
唯一のメッセージ種別)で異なるプロパティを連続設定すると後者が前者を握り潰して
いた(例: AdminConfigForm の「Default」ボタンが `backgroundFill` の次に
`backgroundColor` をリセットすると片方が消える)。`ROOM_PROP` に限りプロパティ名
も一致条件に加えて修正(ワイヤーフォーマット変更なし)。CDPで実機検証済み。
コミット `fb280c4`(binaural-meet)。

## 2026-08-01 — ホスト名リネームと Node アップグレード {#2026-08-01-host-rename-node-upgrade}

ホストが `ai1.binaural.me` から `ai1.haselab.net` に改名された。コンテナの
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
