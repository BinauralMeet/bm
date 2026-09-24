#!/bin/bash
#  Starts everything needed for a human to test BinauralMeet end-to-end from outside the
#  container: main server, media server (mediasoup), the client dev server, and the
#  sandbox-portfwd lease renewer that keeps mediasoup's UDP ports reachable.
#
#  Run INSIDE the sandbox container (`/sandbox/port<N>/` reverse-proxies to the container's
#  IP, so anything listening on the host instead is unreachable from outside):
#      sandbox exec -- bash /home/hase/sandhome/bm/start-dev.sh
#
#  The container has no procps (`ps`/`pkill` missing), so running processes are tracked by
#  pidfile in logs/ and stopped via the shell builtin `kill`.
set -u

BM=/home/hase/sandhome/bm
LOGS=$BM/logs
mkdir -p "$LOGS"

stop_one(){  #  $1 = name
  local pidfile=$LOGS/$1.pid
  [ -f "$pidfile" ] || return 0
  local pid; pid=$(cat "$pidfile")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null   #  setsid => pid is the process group
    echo "stopped $1 (pgid $pid)"
  fi
  rm -f "$pidfile"
}

start_one(){  #  $1 = name, $2 = workdir, rest = command
  local name=$1 dir=$2; shift 2
  stop_one "$name"
  ( cd "$dir" && nohup setsid "$@" >> "$LOGS/$name.log" 2>&1 & echo $! > "$LOGS/$name.pid" )
  echo "started $name -> $LOGS/$name.log (pid $(cat "$LOGS/$name.pid"))"
}

case "${1:-start}" in
  stop)
    for n in client media main portfwd; do stop_one "$n"; done
    exit 0
    ;;
  start) ;;
  *) echo "usage: $0 [start|stop]" >&2; exit 2 ;;
esac

#  Keeps the mediasoup UDP port lease alive. config.js's rtcMinPort/rtcMaxPort must match the
#  lease's port range -- the script logs a warning if a re-issued lease differs.
start_one portfwd "$BM/bmMediasoupServer" bash portfwd-renew.sh

#  Gateway for the media servers. Listens on 3100 (plain HTTP, useHttp: true in config.js --
#  TLS is terminated by the sandbox reverse proxy).
start_one main "$BM/bmMediasoupServer" npx ts-node-dev --respawn --inspect=8228 -- src/main.ts

#  The speech-to-text backends that sit behind lm.haselab.net authenticate with the shared key
#  (`config.js`'s `stt.backends[].apiKeyEnv`). It lives in a file, not the environment, so without
#  this the media server would send unauthenticated requests, get rejected, and quietly fall
#  through to the next backend -- looking like the GPU was busy. Absent file: nothing to do, the
#  local sidecars need no key.
if [ -r /opt/lm-tool/lm-tool.env ]; then
  set -a; . /opt/lm-tool/lm-tool.env; set +a
fi

#  mediasoup. package.json's `media` script is Windows-only (`set VAR=x&...`), so invoke
#  ts-node-dev directly. NODE_TLS_REJECT_UNAUTHORIZED is not needed while main is plain HTTP.
start_one media "$BM/bmMediasoupServer" npx ts-node-dev --respawn --inspect=8229 -- src/media.ts

#  Client. base=/sandbox/port3000/ matches the reverse-proxy path (the prefix is NOT stripped);
#  vite.config.ts already sets host: true + allowedHosts so the proxy can reach it.
start_one client "$BM/binaural-meet" npm run start:sandbox-proxy
