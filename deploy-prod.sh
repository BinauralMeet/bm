#!/bin/bash
#  本番(main/media1/media2/binaural.me)へ bmMediasoupServer / binaural-meet の
#  既定ブランチを指定コミットまで進め、ビルドして反映する。詳細は docs/deploy を参照。
#
#  使い方:
#      ./deploy-prod.sh server <host> <commit>   # main / media1 / media2 いずれか1台 (ssh)
#      ./deploy-prod.sh client <commit>          # binaural.me (このホスト = ai1、ssh不要)
#      ./deploy-prod.sh server-all <commit>      # main media1 media2 をこの順で全部
#      --dry-run を先頭に付けると、server/server-allはsshで実行する内容の表示のみ、
#      clientはworktreeでのビルドまで行い配信ディレクトリへのコピー以降だけ省略する。
#
#  例:
#      ./deploy-prod.sh server-all 520cbcf
#      ./deploy-prod.sh client 18e13ae
#
#  安全設計:
#   - main/media1/media2 (bmMediasoupServer): config.js は必ず退避してから戻す。
#     git は fetch + `merge --ff-only` のみ (reset --hard/checkout . はしない)。
#     進めた後にHEADが指定コミットと一致するか検証してから初めてビルドする。
#   - binaural.me (このホスト自身 = ai1): 開発チェックアウト
#     (デフォルトでこのワークスペースの binaural-meet/) を直接ビルドしない。
#     未コミットのローカル開発設定(configLocal切り替え等)や進行中の作業を
#     本番ビルドに混ぜないよう、`git worktree` で指定コミットだけを別ディレクトリに
#     チェックアウトしてビルドする(2026-08-06の前例と同じ手順、ホスト側
#     CHANGELOG-004#binaural-me-rebuild 参照)。配信ディレクトリの中身は
#     このリポジトリ由来のファイルだけを消して置き換え、public_packages/ (別管理領域)
#     には一切触れない。
set -u

# ---- ホストごとの設定 (未確認の値は要確認とコメントしてある) --------------------
declare -A SERVER_REPO_DIR=( [main]=/root/bmMediasoupServer [media1]=/root/bmMediasoupServer [media2]=/root/bmMediasoupServer )
declare -A SERVER_BRANCH=(   [main]=main [media1]=main [media2]=main )
#  pm2のプロセス名。install_servers.shのコメント(main=bm, media=bmm)からの推定で未確認。
#  実際の名前は `ssh <host> pm2 ls` で確認してから埋めること。
declare -A SERVER_PM2_NAME=( [main]=bm [media1]=bmm [media2]=bmm )

#  binaural.me はこのホスト自身(ai1、DNSはbinaural.me/ai1.binaural.me/ai1.haselab.netとも
#  同じIP)。sshは使わずローカルでbuildする。
CLIENT_BRANCH=master
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${BINAURAL_REPO_DIR:=$SCRIPT_DIR/binaural-meet}"   # このワークスペースの開発チェックアウト
: "${BINAURAL_SERVE_DIR:=/var/www/binaural.me}"       # nginx sites-available/binaural.me の root
: "${BINAURAL_KEEP:=public_packages}"                 # このリポジトリ由来ではない、消してはいけない領域
: "${BINAURAL_BUILD_USER:=hase}"                      # 開発チェックアウトの所有者。worktree/installはこのユーザーで行う

DRY_RUN=0
if [ "${1:-}" = --dry-run ]; then DRY_RUN=1; shift; fi

run_remote(){  # $1 = host, $2 = remote script (stdin)
  local host=$1; shift
  if [ "$DRY_RUN" = 1 ]; then
    echo "===== dry-run: $host で実行する内容 ====="
    cat
    echo "===== ここまで ====="
    return 0
  fi
  #  /root/bmMediasoupServer はroot所有、sshのログインユーザーはaiops(NOPASSWD sudo)なので
  #  sudoでroot昇格してから流す。
  ssh -o BatchMode=yes "$host" sudo -n bash -s
}

deploy_server(){  # $1 = host (main|media1|media2), $2 = target commit
  local host=$1 target=$2
  local dir=${SERVER_REPO_DIR[$host]:-} branch=${SERVER_BRANCH[$host]:-} pm2name=${SERVER_PM2_NAME[$host]:-}
  if [ -z "$dir" ]; then echo "unknown server host: $host" >&2; return 1; fi
  echo "## bmMediasoupServer -> $host ($branch を $target まで, pm2 name=$pm2name)"
  run_remote "$host" <<REMOTE
set -eu
git(){ command git -c safe.directory='*' "\$@"; }   #  /root配下をaiopsで触るための一時例外(永続設定は変えない)
cd '$dir'
echo "-- git status --"; git status --porcelain
backup="/root/.config.js.deploy-backup.\$(date +%Y%m%d%H%M%S)"
cp -p config.js "\$backup"
git fetch origin
git checkout '$branch'
git merge --ff-only 'origin/$branch'
actual=\$(git rev-parse HEAD)
if [ "\$actual" != '$target' ] && [ "\${actual:0:${#target}}" != '$target' ]; then
  echo "HEAD (\$actual) が想定コミット($target)と一致しません。中断します。" >&2
  exit 1
fi
#  実機の値を必ず勝たせる(コミット側がconfig.jsを変えていても、変えていなくても)。
#  「変更なしのはず」であってもgit checkoutで戻す向きを間違えると本番設定を消しうる
#  (2026-09-26に実機で発生・復旧済み)ため、cpで退避したファイルを"上書き元"として使う。
cp -p "\$backup" config.js
npm run build
pm2 restart '$pm2name'
pm2 save
echo "OK: \$(git log -1 --oneline)"
REMOTE
}

deploy_client(){  # $1 = target commit
  local target=$1
  [ -n "$target" ] || { echo "usage: $0 client <commit>" >&2; return 1; }
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  local wt="/tmp/bm-build-$ts"
  local backup="/root/binaural.me-backup-$ts"

  echo "## binaural-meet -> binaural.me (このホスト, $CLIENT_BRANCH を $target まで)"
  echo "-- 事前確認: 対象コミットが $BINAURAL_REPO_DIR に存在し、fetch済みか --"
  git -C "$BINAURAL_REPO_DIR" -c safe.directory='*' cat-file -e "$target" 2>/dev/null \
    || sudo -u "$BINAURAL_BUILD_USER" git -C "$BINAURAL_REPO_DIR" fetch origin
  git -C "$BINAURAL_REPO_DIR" -c safe.directory='*' cat-file -e "$target" \
    || { echo "コミット $target が見つかりません" >&2; return 1; }

  echo "-- 配信ディレクトリを退避: $backup --"
  if [ "$DRY_RUN" != 1 ]; then
    mkdir -p "$backup"
    cp -a "$BINAURAL_SERVE_DIR/." "$backup/"
  else
    echo "(dry-run) mkdir -p '$backup' && cp -a '$BINAURAL_SERVE_DIR/.' '$backup/'"
  fi

  echo "-- git worktree で $target だけを $wt に分離してビルド --"
  echo "   (開発チェックアウト $BINAURAL_REPO_DIR 自体には触れない)"
  sudo -u "$BINAURAL_BUILD_USER" git -C "$BINAURAL_REPO_DIR" -c safe.directory='*' worktree add "$wt" "$target"
  sudo -u "$BINAURAL_BUILD_USER" bash -lc "cd '$wt' && corepack yarn install --frozen-lockfile && corepack yarn build"

  local tail; tail=$(tail -c 200 "$wt/dist/config.js")
  case "$tail" in
    *configTitech*) echo "-- ビルド結果の config.js: configTitech (OK) --" ;;
    *) echo "config.js が configTitech を使っていません。中断します:" >&2; echo "$tail" >&2
       sudo -u "$BINAURAL_BUILD_USER" git -C "$BINAURAL_REPO_DIR" -c safe.directory='*' worktree remove "$wt" --force
       return 1 ;;
  esac

  if [ "$DRY_RUN" = 1 ]; then
    echo "(dry-run) ここで $BINAURAL_SERVE_DIR へ '$wt/dist/' の内容をコピーする(${BINAURAL_KEEP}/は保持)"
  else
    echo "-- $BINAURAL_SERVE_DIR を更新 (${BINAURAL_KEEP}/ は保持) --"
    for entry in "$BINAURAL_SERVE_DIR"/*; do
      [ "$(basename "$entry")" = "$BINAURAL_KEEP" ] && continue
      rm -rf "$entry"
    done
    cp -a "$wt/dist/." "$BINAURAL_SERVE_DIR/"
    chown -R root:root "$BINAURAL_SERVE_DIR"
    find "$BINAURAL_SERVE_DIR" -mindepth 1 -maxdepth 1 -not -name "$BINAURAL_KEEP" -type d -exec chmod 755 {} \;
    find "$BINAURAL_SERVE_DIR" -mindepth 1 -maxdepth 1 -not -name "$BINAURAL_KEEP" -type f -exec chmod 644 {} \;
  fi

  echo "-- worktree を片付ける --"
  sudo -u "$BINAURAL_BUILD_USER" git -C "$BINAURAL_REPO_DIR" -c safe.directory='*' worktree remove "$wt"

  echo "OK: $target を $BINAURAL_SERVE_DIR へ反映。バックアップ: $backup"
  echo "切り戻す場合: 上のbackupの中身を $BINAURAL_SERVE_DIR へ cp -a し直す(${BINAURAL_KEEP}/以外)"
}

case "${1:-}" in
  server)
    deploy_server "$2" "$3"
    ;;
  server-all)
    for h in main media1 media2; do deploy_server "$h" "$2" || exit 1; done
    ;;
  client)
    deploy_client "$2"
    ;;
  *)
    echo "usage: $0 [--dry-run] {server <host> <commit> | server-all <commit> | client <commit>}" >&2
    exit 1
    ;;
esac
