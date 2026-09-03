#!/bin/bash
# run-one.sh <binary> <engine> <device> <model> <run_n> <results.csv>
# Executes one benchmark run per streaming-silicon-bench.html §06, appends one CSV row.
set -uo pipefail
BIN="$1"; ENGINE="$2"; DEVICE="$3"; MODEL="$4"; RUN_N="$5"; RESULTS="$6"
WORKDIR=~/voxbench
LOG="$WORKDIR/run-${ENGINE}-${DEVICE}-${RUN_N}.log"
HOST=$(hostname)
[ -d /sys/class/power_supply/BAT0 ] && HAS_BATTERY=1 || HAS_BATTERY=0
GPU_PATH=$(find /sys/class/drm/card0 -iname 'idle_residency_ms' 2>/dev/null | head -1)
NPU_PATH=/sys/class/accel/accel0/device/npu_busy_time_us
# Kernel RAPL powercap, not pcm-power: pcm-power hardcodes a per-CPU-model
# whitelist that misses some real chips (confirmed on Tiger Lake) even when
# the kernel's own intel-rapl driver works fine. package-0's energy_uj is
# universal wherever intel_rapl_common is loaded.
RAPL_PATH=$(for d in /sys/class/powercap/intel-rapl:*; do
  [ -f "$d/name" ] && [ "$(cat "$d/name" 2>/dev/null)" = "package-0" ] && echo "$d" && break
done)
RAPL_MAX=$([ -n "$RAPL_PATH" ] && sudo cat "$RAPL_PATH/max_energy_range_uj" 2>/dev/null)

pkill -f "$BIN.*daemon" 2>/dev/null
LOCK="/run/user/$(id -u)/voxtype/voxtype.lock"
for i in $(seq 1 20); do [ -f "$LOCK" ] || break; sleep 0.5; done
sleep 1

ORIG_DEFAULT_SOURCE=$(pactl get-default-source 2>/dev/null)
pactl set-default-source voxbench.monitor 2>&1
trap 'pactl set-default-source "$ORIG_DEFAULT_SOURCE" 2>/dev/null' EXIT

"$BIN" -vv daemon > "$LOG" 2>&1 &
DAEMON_PID=$!
for i in $(seq 1 30); do grep -qE "Listening for hotkey|Model loaded, ready|pipeline created in" "$LOG" 2>/dev/null && break; sleep 1; done
COLD_START=$(grep -oE "(Model loaded|pipeline created) in [0-9.]+s" "$LOG" | grep -oE "[0-9.]+" | tail -1)

# --- start samplers ---
SYSFS_LOG="$WORKDIR/sysfs-${ENGINE}-${DEVICE}-${RUN_N}.log"
: > "$SYSFS_LOG"
( for i in $(seq 1 20); do
    ts=$(date +%s.%N)
    g=$(cat "$GPU_PATH" 2>/dev/null || echo NA)
    n=$(cat "$NPU_PATH" 2>/dev/null || echo NA)
    echo "$ts $g $n" >> "$SYSFS_LOG"
    sleep 1
  done ) &
SYSFS_SAMPLER_PID=$!
BAT_LOG="$WORKDIR/battery-${ENGINE}-${DEVICE}-${RUN_N}.log"
: > "$BAT_LOG"
if [ "$HAS_BATTERY" = "1" ]; then
  ( for i in $(seq 1 20); do
      upower -i /org/freedesktop/UPower/devices/battery_BAT0 2>/dev/null | grep energy-rate >> "$BAT_LOG"
      sleep 1
    done ) &
  BAT_SAMPLER_PID=$!
fi

# --- record ---
REC_START=$(date +%s.%N)
[ -n "$RAPL_PATH" ] && RAPL_START=$(sudo cat "$RAPL_PATH/energy_uj" 2>/dev/null)
"$BIN" record start
pw-play --target=voxbench "$WORKDIR/reference.wav"
sleep 1
"$BIN" record stop
[ -n "$RAPL_PATH" ] && RAPL_END=$(sudo cat "$RAPL_PATH/energy_uj" 2>/dev/null)
REC_END=$(date +%s.%N)
sleep 1

# --- stop samplers ---
kill "$SYSFS_SAMPLER_PID" 2>/dev/null
[ -n "${BAT_SAMPLER_PID:-}" ] && kill "$BAT_SAMPLER_PID" 2>/dev/null
sleep 1

# --- extract metrics from daemon log ---
FIRST_TICK_TS=$(grep -m1 "\[sliding\] tick transcribe" "$LOG" | grep -oE '^[0-9T:.\-]+Z' | head -1)
AVG_INFER_MS=$(grep -oE '[0-9.]+s infer' "$LOG" | grep -oE '^[0-9.]+' | awk '{s+=$1;c++} END{if(c>0) printf "%.1f", (s/c)*1000; else print "NA"}')
AVG_RTF=$(grep -oE '\([0-9]+ samples, [0-9.]+s infer' "$LOG" | sed -E 's/\(([0-9]+) samples, ([0-9.]+)s infer/\1 \2/' | awk '{if($1>0) print $2/($1/16000)}' | awk '{s+=$1;c++} END{if(c>0) printf "%.3f", s/c; else print "NA"}')
REVISE_EVENTS=$(grep -c '\[sliding\] REVISE' "$LOG")
BACKSPACE_TOTAL=$(grep -oE 'backspace [0-9]+ chars' "$LOG" | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
FINAL_TEXT=$(grep '\[sliding\] tick transcribe' "$LOG" | tail -1 | sed -E 's/.*tick transcribe -> "(.*)" \([0-9]+ samples.*/\1/')
echo "$FINAL_TEXT" > "$WORKDIR/hyp-${ENGINE}-${DEVICE}-${RUN_N}.txt"
WER=$(python3 "$WORKDIR/wer.py" "$WORKDIR/reference.txt" "$WORKDIR/hyp-${ENGINE}-${DEVICE}-${RUN_N}.txt" 2>/dev/null || echo NA)

# --- resource metrics ---
CPU_PCT=NA  # derive from PCM core-counter export separately if needed; latency/RTF are primary CPU signal here
GPU_PCT=NA
if [ -n "$GPU_PATH" ]; then
  GPU_PCT=$(awk 'NR==1{i0=$2;t0=$1} END{if(NR>1){dt=$1-t0; di=$2-i0; if(dt>0) printf "%.1f", 100*(1-di/(dt*1000))}}' "$SYSFS_LOG" 2>/dev/null)
fi
NPU_PCT=NA
if [ -f "$NPU_PATH" ]; then
  NPU_PCT=$(awk 'NR==1{b0=$3;t0=$1} END{if(NR>1){dt=$1-t0; db=$3-b0; if(dt>0) printf "%.1f", 100*(db/1e6)/dt}}' "$SYSFS_LOG" 2>/dev/null)
fi
PKG_POWER=NA
if [ -n "$RAPL_PATH" ] && [ -n "${RAPL_START:-}" ] && [ -n "${RAPL_END:-}" ]; then
  PKG_POWER=$(awk -v s="$RAPL_START" -v e="$RAPL_END" -v max="${RAPL_MAX:-0}" -v t0="$REC_START" -v t1="$REC_END" \
    'BEGIN{d=e-s; if(d<0 && max>0) d+=max; dt=t1-t0; if(dt>0) printf "%.2f", (d/1e6)/dt; else print "NA"}')
fi
BAT_POWER=NA
if [ "$HAS_BATTERY" = "1" ]; then
  BAT_POWER=$(grep -oE '[0-9.]+ W' "$BAT_LOG" | awk '{s+=$1;c++} END{if(c>0) printf "%.2f", s/c; else print "NA"}')
fi
RSS_MB=$(ps -o rss= -p "$DAEMON_PID" 2>/dev/null | awk '{printf "%.1f", $1/1024}')

kill "$DAEMON_PID" 2>/dev/null

[ -f "$RESULTS" ] || echo "machine,backend,device,model,run_n,cold_start_s,avg_tick_infer_ms,avg_rtf,revise_events,backspace_chars_total,wer,gpu_pct_avg,npu_pct_avg,pkg_power_w_avg,battery_power_w_avg,peak_rss_mb,final_text" > "$RESULTS"
echo "$HOST,$ENGINE,$DEVICE,$MODEL,$RUN_N,${COLD_START:-NA},${AVG_INFER_MS:-NA},${AVG_RTF:-NA},${REVISE_EVENTS:-0},${BACKSPACE_TOTAL:-0},${WER:-NA},${GPU_PCT:-NA},${NPU_PCT:-NA},${PKG_POWER:-NA},${BAT_POWER:-NA},${RSS_MB:-NA},\"$FINAL_TEXT\"" >> "$RESULTS"
echo "=== $HOST $ENGINE/$DEVICE run $RUN_N done ==="
tail -1 "$RESULTS"
