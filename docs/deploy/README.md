# deploy — 本番(main/media1/media2/binaural.me)へのデプロイ

**いつ読むか**: 本番へコードを反映する(ブランチ追従・ビルド・pm2 restart) /
`deploy-prod.sh` を使う・直す / config.js・public/config.jsを本番で
上書きしてしまわないか不安なとき / 本番4台の役割・アクセス経路を確認する

## 使い方 {#usage}

```sh
./deploy-prod.sh server-all <bmMediasoupServerのコミット>   # main media1 media2 の順(ssh)
./deploy-prod.sh server <main|media1|media2> <コミット>     # 1台だけ(ssh)
./deploy-prod.sh client <binaural-meetのコミット>           # binaural.me(このホスト、sshなし)
./deploy-prod.sh --dry-run ...                              # server系はssh内容の表示のみ、
                                                              # clientは実際にビルドまで行い
                                                              # 配信ディレクトリへのコピー以降だけ省略
```

- 各リポジトリの**既定ブランチの先端**(`binaural-meet`は`master`、
  `bmMediasoupServer`は`main`)へ進めることを想定している。コミットは
  `git merge --ff-only` で先端に一致するもの、かつpush済みのものを指定する。
- **`vrc.jp`とは無関係。** このホスト(`ai1`)には`vrc.jp`という、ソースは同じ
  3リポジトリを共有するが**全く別のデプロイ**(`/root/webapp/`一式)が同居している。
  `deploy-prod.sh`が触るのは`main`/`media1`/`media2`(titech.binaural.me)と
  `binaural.me`だけで、`/root/webapp/`配下やvrc.jp用のpm2プロセスには一切触れない。

## 構成 {#arch}

対象は4台、担当リポジトリが違う:

| ホスト | リポジトリ | 作業 | 再起動 |
|---|---|---|---|
| `main` | bmMediasoupServer(`/root/bmMediasoupServer`) | pull→`npm run build`(`npx tsc`)→`pm2 restart bm` | 要 |
| `media1` / `media2` | bmMediasoupServer(`/root/bmMediasoupServer`) | 同上→`pm2 restart bmm` | 要 |
| `binaural.me` | binaural-meet | `bm/binaural-meet`から`git worktree`で対象コミットをビルド→`/var/www/binaural.me`へ配置 | 不要(静的) |

- `main`/`media1`/`media2`は`~/.ssh/config`の`main`/`media1`/`media2`エイリアス
  (`main.titech.binaural.me`等、`aiops`ユーザー)。`/root/bmMediasoupServer`は
  `root`所有なので、sshログイン後は`aiops`の**NOPASSWD sudo**でrootに昇格して操作する
  (`run_remote`が`ssh ... sudo -n bash -s`で流す)。pm2プロセス名は`main`が`bm`、
  `media1`/`media2`が`bmm`——実機で確認済み(`#ops`)。
- `binaural.me`は**このホスト自身(`ai1`)**。DNS上`binaural.me`/`ai1.binaural.me`/
  `ai1.haselab.net`はすべて同じIPを指す。sshは不要で、`deploy-prod.sh`をこのホストで
  直接実行する。

## 構成ファイル一覧 {#files}

| ファイル | 役割 |
|---|---|
| `deploy-prod.sh`(`bm/`直下) | 本体。`server`/`server-all`/`client`サブコマンド、`--dry-run` |

## セキュリティ上の要点 {#security}

- **`config.js`(bmMediasoupServer)/`public/config.js`(binaural-meet)は
  本番固有の値が入っており、リポジトリのコミット内容に関わらず上書きしてはいけない。**
  `deploy-prod.sh`はpullの前に実機の値を`cp`で退避し、build前に**退避したファイルを
  working treeへcpし直す**(`git checkout <ref> -- config.js`のような「gitに戻す」
  方向の操作は使わない——向きを間違えると本番の値を消す。2026-09-26に実際に
  事故が起きた経緯は`#design`)。
- gitは`fetch`+`merge --ff-only`のみ。`reset --hard`や`checkout .`は使わない
  (config.js以外の作業ツリーの変更も保持するため)。
- pull後にHEADが指定コミットと一致するか検証してからのみビルドへ進む
  (fast-forwardできない=3台のコミットが揃っていない場合はここで止まる)。
- `client`はビルド後、生成された`dist/config.js`が`configTitech`を使っているかを
  文字列チェックしてから配信ディレクトリへコピーする。一致しなければ中断する。

## 運用 {#ops}

- 実行前に対象コミットが各リポジトリのpush済み先端であることを確認する
  (`git log --oneline -1 <ブランチ>`)。
- 2026-09-26、`server-all`で本番3台(main/media1/media2)・`client`で
  `binaural.me`への実デプロイを実施し、いずれも成功(`CHANGELOG#deploy-script-and-doc`)。
  pm2プロセス名`bm`/`bmm`、`sudo -n`昇格、`binaural.me`のworktreeビルドは
  いずれも実機で確認済み。
- 3台の`bmMediasoupServer`は`main`ブランチの別々のコミットで止まっていたことが
  過去にある(`stt-translation#todo`)。`server-all`はmain→media1→media2の順に
  1台ずつ進めるので、途中で失敗したら残りは実行されない
  (`&&`ではなく`|| exit 1`で止める)。
- 失敗時の切り戻し: `server`系は`/root/.config.js.deploy-backup.<timestamp>`
  (対象ホストの`/root`直下)、`client`は`/root/binaural.me-backup-<timestamp>`
  に配信ディレクトリ全体のバックアップが残る。

## 既知の制限 {#limits}

- `main`/`media1`/`media2`への`ssh`は、このホストの自動モード分類器が
  「本番への操作」として一律ブロックする場合がある(読み取りのみのコマンドも含む、
  Auto Mode下で発生)。マニュアルモードでは通る(2026-09-26に実機確認)。

## 設計判断の記録 {#design}

- **config.jsは「上書きしない」ではなく「退避して戻す」方式にした**:
  2026-09-26のデプロイ依頼で`binaural-meet`の対象コミット(`33bbd9a`→`6809bb5`)
  を調べたところ、`public/config.js`の末尾(有効化する設定を選ぶ行)が
  `configTitech`(本番)から`configLocal`(この開発サンドボックスの
  `wss://ai1.haselab.net/sandbox/port3100/`)に変わっていた——ローカル動作確認用の
  変更が別のコミットに混入してpushされたもの。`binaural-meet`側は
  `18e13ae`で修正・push済み。この一件があったため、コミット側が何を変えていようと
  実機の値を勝たせる設計にした。
- **git resetではなくff-only mergeにした**: 本番の作業ツリーには
  `config.js`のような手動編集が残っている前提(`bmMediasoupServer-architecture`の
  `install_servers.sh`も手動編集を指示している)。`reset --hard`/`checkout .`は
  それを含め作業ツリー全体を巻き戻すため、対象範囲の外の変更まで壊しうる。
  `merge --ff-only`なら、対象コミットが変更しないファイルには一切触れない。
- **2026-09-26の事故と教訓**: 初版の`deploy_server`には「pullでconfig.jsが
  動いていたら実機の値へ戻す」つもりで`git checkout HEAD -- config.js`を
  入れていたが、これは**gitの側を勝たせる**コマンドで意図と逆だった。
  main/media1/media2の3台で実行し、STT/translationのbackends設定と
  `main`のリッスンアドレス(`0.0.0.0:443`→コメントアウトされた`localhost:3100`
  相当)が約19分間、本番に存在しない汎用値へ書き換わった
  (退避してあったバックアップから復元・再ビルド・pm2 restartで復旧、
  `CHANGELOG#deploy-script-and-doc`)。**教訓: 「実機の値を勝たせる」処理は
  必ず`cp <退避先> <実ファイル>`の向きで書き、`git checkout`/`git reset`系を
  「戻す」目的で使わない。** どちらの方向へコピーするコマンドか、レビュー時に
  必ず矢印の向きを声に出して確認する。
