#!/usr/bin/env bash
# Records the three simulators with market-recorder, replays the recording with
# market-replay, and checks both replay paths:
#
#   1. HTTP: GET /replay returns every recorded line of each series.
#   2. Websocket: a second market-recorder, pointed at the replay server instead of the
#      simulators, receives every recorded data frame through the venue clients'
#      Live_feeds and normalizes them into events.
#
#   scripts/e2e-replay.sh [RECORD_SECONDS] [REPLAY_SECONDS]   (defaults 60 and 15)
#
# Run from the repo inside the multi-repo dune workspace (or set WORKSPACE to another
# workspace root holding the simulators, market-recorder and this repo). Exits 1 when a
# check fails.
set -euo pipefail

record_seconds=${1:-60}
replay_seconds=${2:-15}
here=$(cd "$(dirname "$0")/.." && pwd)
root=${WORKSPACE:-$(cd "$here/.." && pwd)}
build=${DUNE_BUILD_DIR:-$root/_build}
out=/tmp/market-replay-e2e
replay_port=3640
ports=(3610 3620 3630 "$replay_port" 9940 9941)

for p in "${ports[@]}"; do
  if lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $p is busy" >&2
    exit 1
  fi
done

(cd "$root" && opam exec --switch 5.2.0+ox -- dune build --root . \
  ./hl-sim/bin/main.exe ./binance-sim/bin/main.exe ./bybit-sim/bin/main.exe \
  ./market-recorder/bin/main.exe ./market-replay/bin/main.exe)
recorder=$build/default/market-recorder/bin/main.exe
replay=$build/default/market-replay/bin/main.exe

rm -rf "$out"
mkdir -p "$out/logs"
pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT

problems=()
problem() {
  echo "PROBLEM: $*" >&2
  problems+=("$*")
}

venues=(hyperliquid binance bybit)
symbol_of() { if [[ $1 == hyperliquid ]]; then echo BTC; else echo BTCUSDT; fi; }

# Writes a recorder config for the three venues; $3 is "sims" or "replay".
write_config() {
  local file=$1 data=$2 mode=$3 http_port=$4
  endpoint() {
    if [[ $mode == sims ]]; then
      echo "(Local (port $2))"
    else
      echo "(Custom (base_url http://localhost:$replay_port) (ws_url ws://localhost:$replay_port/ws/$1))"
    fi
  }
  cat >"$file" <<CONFIG
((data_dir $data)
 (http_port $http_port)
 (venues
  (((venue Hyperliquid) (symbols (BTC)) (streams (Trades Bbo L2))
    (config $(endpoint hyperliquid 3610)))
   ((venue Binance) (symbols (BTCUSDT)) (streams (Trades Bbo L2 Funding))
    (config $(endpoint binance 3620)))
   ((venue Bybit) (symbols (BTCUSDT)) (streams (Trades Bbo L2 Funding))
    (config $(endpoint bybit 3630))))))
CONFIG
}

# Data frames (no acks, pongs or REST bodies) in a recorded series.
data_frames() {
  local venue=$1 dir=$2
  [[ -d $dir ]] || {
    echo 0
    return
  }
  local pattern
  case $venue in
    hyperliquid) pattern='"channel":"(trades|l2Book|activeAssetCtx)"' ;;
    binance) pattern='^[^ ]+ \{"stream":' ;;
    bybit) pattern='"topic":' ;;
  esac
  find "$dir" -name '*.ndjson*' | sort | while read -r f; do
    if [[ $f == *.zst ]]; then zstd -dc "$f"; else cat "$f"; fi
  done | { grep -cE "$pattern" || true; }
}

echo "== recording the simulators for ${record_seconds}s"
"$build/default/hl-sim/bin/main.exe" -port 3610 >"$out/logs/hl-sim.log" 2>&1 &
pids+=($!)
"$build/default/binance-sim/bin/main.exe" -port 3620 >"$out/logs/binance-sim.log" 2>&1 &
pids+=($!)
"$build/default/bybit-sim/bin/main.exe" -port 3630 >"$out/logs/bybit-sim.log" 2>&1 &
pids+=($!)
sleep 3
write_config "$out/record.sexp" "$out/recorded" sims 9940
"$recorder" run -config "$out/record.sexp" 2>"$out/logs/recorder.log" &
rec_pid=$!
pids+=("$rec_pid")
sleep "$record_seconds"
kill -TERM "$rec_pid"
wait "$rec_pid" || problem "recorder exited with $?"
kill "${pids[@]:0:3}" 2>/dev/null || true

first=$(find "$out/recorded/raw" -name '*.ndjson*' | sed -E 's#.*/([0-9]{4})/([0-9]{2})/([0-9]{2})/([0-9]{2})-([0-9]{2})\.ndjson.*#\1-\2-\3T\4:\5:00Z#' | sort | head -1)
[[ -n $first ]] || {
  echo "nothing recorded" >&2
  exit 1
}
echo "== replaying from $first"
"$replay" -port "$replay_port" -data-dir "$out/recorded" -from "$first" -speed 0 \
  2>"$out/logs/replay.log" &
pids+=($!)
sleep 1

echo "== HTTP /replay"
for venue in "${venues[@]}"; do
  symbol=$(symbol_of "$venue")
  for dir in "$out/recorded/raw/$venue"/*/"$symbol"; do
    stream=$(basename "$(dirname "$dir")")
    expected=$(find "$dir" -name '*.ndjson*' | sort | while read -r f; do
      if [[ $f == *.zst ]]; then zstd -dc "$f"; else cat "$f"; fi
    done | wc -l | tr -d ' ')
    got=$(curl -sf "localhost:$replay_port/replay?venue=$venue&symbol=$symbol&streams=$stream&from=$first&to=2100-01-01" | wc -l | tr -d ' ')
    echo "$venue $stream: recorded $expected lines, served $got"
    [[ $got == "$expected" && $got != 0 ]] || problem "$venue $stream: served $got of $expected lines"
  done
done

echo "== websocket replay into a second recorder for ${replay_seconds}s"
write_config "$out/rerecord.sexp" "$out/rerecorded" replay 9941
"$recorder" run -config "$out/rerecord.sexp" 2>"$out/logs/rerecorder.log" &
rerec_pid=$!
pids+=("$rerec_pid")
sleep "$replay_seconds"
curl -s "localhost:9941/metrics" >"$out/rerecorder-metrics.txt" || true
curl -s "localhost:$replay_port/metrics" >"$out/replay-metrics.txt" || true
kill -TERM "$rerec_pid"
wait "$rerec_pid" || problem "second recorder exited with $?"

for venue in "${venues[@]}"; do
  symbol=$(symbol_of "$venue")
  for dir in "$out/recorded/raw/$venue"/*/"$symbol"; do
    stream=$(basename "$(dirname "$dir")")
    expected=$(data_frames "$venue" "$dir")
    got=$(data_frames "$venue" "$out/rerecorded/raw/$venue/$stream/$symbol")
    echo "$venue $stream: recorded $expected data frames, received $got"
    [[ $got == "$expected" && $got != 0 ]] || problem "$venue $stream: received $got of $expected data frames"
  done
done

echo "== events normalized by the clients"
grep '^market_recorder_events_total{' "$out/rerecorder-metrics.txt" || problem "no events in the second recorder's metrics"
while read -r line; do
  [[ -z $line ]] && continue
  [[ ${line##* } != 0 ]] || problem "no events: ${line% *}"
done <<<"$(grep '^market_recorder_events_total{' "$out/rerecorder-metrics.txt" || true)"
while read -r line; do
  [[ -z $line ]] && continue
  [[ ${line##* } == 0 ]] || problem "parse errors: $line"
done <<<"$(grep '^market_recorder_parse_errors_total{' "$out/rerecorder-metrics.txt" || true)"

echo "== replay server metrics"
grep -v '^#' "$out/replay-metrics.txt" || true

if ((${#problems[@]} > 0)); then
  echo "== FAILED: ${#problems[@]} problem(s)" >&2
  exit 1
fi
echo "== OK"
