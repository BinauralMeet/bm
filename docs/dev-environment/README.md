# dev-environment — sandboxでの開発・動作確認

**いつ読むか**: このワークスペースを sandbox コンテナ上で動かす / vite の変更が
反映されない / mediasoup の音声・映像が繋がらない / `skipEntrance` を使ったのに
入室しない / headful debug Chrome が起動しない / アバター一覧が空になる

## 構成

`start-dev.sh`(このリポジトリ直下)が4つのプロセスを起動し、`logs/<name>.log`
とpidfileを1つずつ作る。

| 部分 | ポート | 備考 |
|---|---|---|
| `main`(bmMediasoupServer) | 3100 | 平文HTTP(`useHttp: true`)。TLSはsandboxのリバースプロキシが終端 |
| `media`(mediasoup) | UDP 42000-42049 | `package.json` の `media` スクリプトはWindows専用なので、`ts-node-dev` を直接起動 |
| `client`(vite) | 3000 | `--base=/sandbox/port3000/` |
| `portfwd` | — | mediasoupのUDPポートリースを6時間ごとに更新 |

人間が触るURL: sandboxのリバースプロキシ経由(`https://<このホスト>/sandbox/port3000/`。
外部からはGoogleログイン、コンテナ内(docker0)からのアクセスはそれをバイパスする)。

## 構成ファイル一覧

| ファイル | 役割 |
|---|---|
| `binaural-meet/config.js` 相当(vite設定) | `--base=/sandbox/port3000/` を指定 |
| `bmMediasoupServer/config.js` | `rtcMinPort`/`rtcMaxPort` をポートリースの払い出し範囲に合わせる |
| `bmMediasoupServer/portfwd-lease-id.txt` / `portfwd-renew.sh` | 現在のリースを維持 |
| `smoke.mjs`(ワークスペース直下) | 実際に入室ダイアログを操作して部屋に入り、状態をスクリーンショット |

## 運用

- **すべてsandboxコンテナの中で動かす。** `/sandbox/port<N>/` はコンテナの
  docker0 IPにリバースプロキシするので、ホスト側で起動したサーバーは外から
  見えない。
- **Node ≥20.19 が必須**(vite8/vitest4/jsdom29の`engines`)。Debian bookwormの
  `nodejs` は18で `node:util` の `styleText` エクスポート不足エラーになる。
- vite dev-server はモジュールキャッシュが再起動をまたいで不安定なことがある。
  編集後の1回のテスト結果を信用せず、疑わしいときは `kill` + `rm -rf
  node_modules/.vite` + 再起動をする。
- `vitest run` + `tsc --noEmit` は速い正誤チェック。RTC/音声/コンテンツ同期の
  データパスに触れた変更は、これに加えて手動のCDPスモークテストが必要。
- **mediasoupのUDPポートはTTL付きリース**(仕組みの詳細はホストの
  `sandbox-portfwd` ドキュメント。ここでは「切れると media が静かに壊れる」
  ことだけ知っていればよい)。切れたら新しいリースを取り、`config.js` の
  `rtcMinPort`/`rtcMaxPort` を払い出された範囲に合わせて `media` を再起動する。
- **`?skipEntrance=true` は入室しない。** 入室ダイアログを消すだけで、実際の
  `conference.enter()` はそのダイアログの `onClose`(または `?testBot=` モード
  の `enterRoomAsTestBot`)から呼ばれる。`skipEntrance` だけのページは
  最終的に「メディア接続に失敗しました」を表示し、サーバー障害に見えてしまう。
  `smoke.mjs` は本物のダイアログ("Enter the venue")を操作する。
- headful debug Chromeのプロファイルは、ロックしたホスト名を刻んだ
  `SingletonLock` シンボリックリンクを持つ(仕組みはホストの `headful-chrome`
  ドキュメント)。
- **VRMアバター一覧は別オリジンから配信される。** アバターindexと`.vrm`本体を
  配信するホストと、このワークスペースが動くホストが異なる場合、CORSヘッダーが
  必要(配信側 nginx に `Access-Control-Allow-Origin`)。クライアントはヘッダーが
  無いときCORSプロキシにフォールバックするが、そちらは許可オリジンのホワイト
  リスト制なので万能ではない。
- `main` のログはほぼノイズ(`startObserveConfigOnGoogleDrive()` がJWTを署名
  できない旨、`ENOENT /var/log/pm2/...`)。実際のシグナリング活動は
  `addWorker <id>` として出る。

## 既知の制限

- コンテナに procps が無い(`ps`/`pkill` が使えない)。プロセス管理は
  pidfile ベース。
- ホスト名がリネームされると、ホスト名を刻んだ状態(Chromeプロファイルの
  ロックファイルなど)は追従しない。手動で気づいて直す必要がある。

## 設計判断の記録

- **`?skipEntrance` を入室扱いにしなかった**: テストの都合で入室ダイアログを
  スキップしても実接続まで自動化すると、実際のユーザーが通る経路(ダイアログの
  `onClose`)をテストが検証しなくなる。`smoke.mjs`にダイアログ操作を持たせる方を
  選んだ。
