# Streaming Silicon Bench

A repeatable procedure and toolset for measuring the sliding-window streaming
engine (`transcribe::sliding_window`, unified alignment rearchitecture in
[#716](https://github.com/peteonrails/voxtype/pull/716)) across whisper.cpp and
OpenVINO, on whatever CPU/GPU/NPU combination a given machine actually has.

Point another agent (or a human) at this directory and `reference.wav` and it
can reproduce the exact same test — same audio in, same metrics out, on any
machine — without re-deriving any of the setup steps below. Everything here was
built and debugged against a live 3-machine run (Tiger Lake, Raptor Lake, Lunar
Lake); the fixes noted inline are for real bugs hit and fixed during that run,
not speculative.

## What's in this directory

| File | Purpose |
|---|---|
| `run-one.sh` | Executes one backend/device run end-to-end and appends one row to a results CSV |
| `wer.py` | Word Error Rate, no dependencies (pure Python, Levenshtein on words) |
| `reference.wav` | 16kHz mono, ~25s, the fixed test utterance — same file everywhere |
| `reference.txt` | Hand-typed ground truth transcript of `reference.wav` (WER's reference, never an engine's own output) |

## 1. Build

```bash
git clone https://github.com/peteonrails/voxtype.git
cd voxtype
git fetch origin pull/716/head:pr-716 && git checkout pr-716

# One binary covers whisper.cpp AND OpenVINO CPU/GPU/NPU — openvino-whisper
# is additive, it doesn't remove default whisper.cpp support. Don't build a
# separate CPU-only variant.
cargo build --release --bin voxtype --features openvino-whisper
```

Build deps: `rustup default stable`, `cmake`, `clang`/`gcc`, `pkgconf`. None of
these are on a stock Omarchy/Arch install — `pacman -S --needed rustup cmake`
covers the two commonly missing ones.

## 2. OpenVINO runtime (skip if only testing whisper.cpp)

```bash
# Arch: core runtime + device plugin for whatever you have
sudo pacman -S --needed openvino openvino-intel-gpu-plugin level-zero-loader intel-compute-runtime   # GPU
sudo pacman -S --needed openvino openvino-intel-npu-plugin intel-npu-driver                           # NPU (needs /dev/accel/accel0)
```

**The GenAI C/C++ SDK is not in pacman, the AUR, or the `openvino-genai` pip
wheel** (the wheel explicitly excludes the C API) — it has to be downloaded
separately, version-matched to whatever `pacman -Q openvino` reports. Intel's
own directory listing at `storage.openvinotoolkit.org` is JS-rendered and
returns nothing to `curl`; pull the bucket's `filetree.json` instead:

```bash
OV_VERSION=$(pacman -Q openvino | awk '{print $2}' | cut -d- -f1)   # e.g. 2026.3.0
MAJOR_MINOR=$(echo "$OV_VERSION" | cut -d. -f1,2)                    # e.g. 2026.3

curl -s https://storage.openvinotoolkit.org/filetree.json -o /tmp/filetree.json
python3 -c "
import json
data = json.load(open('/tmp/filetree.json'))
def walk(node, path=''):
    p = path + '/' + node.get('name','')
    if node.get('type') == 'file' and f'/openvino_genai/packages/$MAJOR_MINOR/linux/openvino_genai_ubuntu22_$OV_VERSION' in p:
        print(p)
    for c in node.get('children') or []: walk(c, p)
walk(data)
"
# download whichever path that prints, e.g.:
curl -L -o sdk.tar.gz "https://storage.openvinotoolkit.org<path from above>"
mkdir -p ~/.local/share/openvino-genai-sdk
tar xzf sdk.tar.gz -C ~/.local/share/openvino-genai-sdk --strip-components=1
```

Set `openvino_dir = "~/.local/share/openvino-genai-sdk"` (expanded) in
`[openvino]` in `config.toml`, and export
`LD_LIBRARY_PATH=<openvino_dir>/runtime/lib/intel64` in every shell that
launches the daemon for an OpenVINO run.

**Known gap**: none of `voxtype setup gpu`, `setup npu --status`, or any other
CLI subcommand checks for this SDK. A user (or agent) can pass every automated
check and still have the daemon fail to start because this one file is
missing. Verify manually: `ls $OPENVINO_DIR/runtime/lib/intel64/libopenvino_genai_c.so`.

## 3. Models

```bash
./target/release/voxtype setup --download --model base.en --activate        # whisper.cpp ggml
./target/release/voxtype setup --download --model base.en-int8 --activate   # OpenVINO IR
```

Each `--activate` flips `engine` in `config.toml` — that's fine, you'll be
flipping it between runs anyway (see §5).

## 4. Reference audio, once, everywhere

Don't record a fresh clip per machine — wording, pacing, and pauses drift
between takes and pollute latency/WER comparisons. Use `reference.wav` and
`reference.txt` from this directory on every machine, identical byte-for-byte
(verify with `md5sum`).

To route it into voxtype without a physical mic, create a null sink and make
it the **system default source** — voxtype's own audio backend only enumerates
`pipewire`/`default` as device names, it does not accept a named PipeWire
monitor string (e.g. `"voxbench.monitor"`) in `config.toml`'s `[audio] device`
field directly, even though `pactl` happily lists it. `run-one.sh` handles the
default-source swap and restore itself (via a trap), so this is a one-time
setup step, not per-run:

```bash
pactl load-module module-null-sink sink_name=voxbench sink_properties=device.description=voxbench
```

Leave `[audio] device = "default"` in `config.toml` — do not point it at
`voxbench.monitor` directly, it will fail to start with `Audio device not
found: 'voxbench.monitor'`.

## 5. Monitoring stack

**CPU counters**: [Intel PCM](https://github.com/intel/pcm), built from
source (`cmake .. && cmake --build . --parallel && sudo cmake --install .`),
run as a systemd service:

```
[Unit]
Description=Intel PCM Exporter
[Service]
ExecStart=/usr/local/sbin/pcm-sensor-server -p 9738
Restart=always
[Install]
WantedBy=multi-user.target
```
Needs `msr` kernel module loaded (`/etc/modules-load.d/pcm.conf`) and
`kernel.nmi_watchdog=0`.

**Package power (RAPL)**: read directly from the kernel's own powercap
interface, *not* `pcm-power` —
`/sys/class/powercap/intel-rapl:N/energy_uj` where
`/sys/class/powercap/intel-rapl:N/name` is `package-0`. **`pcm-power` hardcodes
a per-CPU-model whitelist and silently produces empty output on models it
doesn't recognize** — confirmed failing on Tiger Lake
(`Unsupported processor model (0x68c)`) even though the kernel's own RAPL
driver works fine there. `run-one.sh` reads `energy_uj` before/after the
recording window and computes watts from the delta — this is what actually
works across all three machines tested; don't reintroduce `pcm-power` for
this.

**GPU/NPU utilization**: raw sysfs, the same paths
[omarchy-system-monitor](https://github.com/tslove923/omarchy-system-monitor)
reads — used directly here since the benchmark needs scriptable sampling, not
a bar widget:
```
/sys/class/drm/card0/device/tile0/gt0/gtidle/idle_residency_ms   # GPU
/sys/class/accel/accel0/device/npu_busy_time_us                  # NPU
```
The `tile0/gt0` nesting is the newer Xe-driver layout (confirmed on Lunar
Lake). Older i915-driver machines may expose this without the `tile0` level —
`run-one.sh` auto-discovers the path with `find`, but verify it actually found
something (`GPU_PATH` non-empty) before trusting `gpu_pct_avg`.

**Battery draw** (laptops only, whole-system cross-check against RAPL, which
only sees package/DRAM and misses disk/VRM/display losses):
```
upower -i /org/freedesktop/UPower/devices/battery_BAT0 | grep energy-rate
```
Expect this noisy — it's total system draw, not workload-isolated. On one
already-tested machine it swung 7-32W across runs of the *same* backend/device
combo; treat it as a sanity band, not a precise measurement.

## 6. Running the matrix

```bash
bash run-one.sh <path-to-binary> <engine> <device> <model> <run_n> <results.csv>
# e.g.:
bash run-one.sh ./target/release/voxtype whisper CPU base.en 1 results.csv
bash run-one.sh ./target/release/voxtype openvino GPU base.en-int8 1 results.csv
```

Set `engine` (and `[openvino] device`) in `config.toml` to match before each
call — the script doesn't do this for you, since it's shared across whatever
combos a given machine supports. Run every combo 3x; discard run 1's numbers
when reporting (pays one-time cold-start/graph-compile cost — OpenVINO
GPU/NPU compiles the IR graph on first load, seconds for a small int8 model,
confirmed up to ~15 minutes for large models on some hardware, cached
afterward).

Between runs, if you hit `Failed to acquire lock: another voxtype instance is
already running`, that's a startup race the script already waits out (up to
10s) — if it still happens, `rm -f /run/user/$(id -u)/voxtype/voxtype.lock`
and retry that one run.

If a run's final transcript is empty or nonsense (WER near 1.0), audio routing
broke — check `pactl get-default-source` actually resolved to
`voxbench.monitor` during the run (the script's trap restores your real
default source on exit either way, so this fails safe, it just produces a
garbage row).

## 7. Results schema

One row per run, written by `run-one.sh`:

```
machine,backend,device,model,run_n,cold_start_s,avg_tick_infer_ms,avg_rtf,revise_events,backspace_chars_total,wer,gpu_pct_avg,npu_pct_avg,pkg_power_w_avg,battery_power_w_avg,peak_rss_mb,final_text
```

- `avg_rtf` — inference time / audio-seconds represented per tick; must stay
  `< 1.0` to keep up with live speech.
- `revise_events` / `backspace_chars_total` — how much the sliding-window
  engine backspaces-and-retypes before text settles. This is the metric that
  actually tests PR #716's stated premise (fixing "stalling/correction bugs")
  — a regression here would be the headline finding, not raw speed.
- `wer` — against `reference.txt`, includes punctuation mismatches (colon vs.
  comma etc.), so read it as "usable text similarity," not strict ASR
  accuracy.
- `pkg_power_w_avg` — RAPL package domain, which on at least one integrated
  SoC tested covers CPU cores *and* the iGPU together — don't assume shifting
  compute from CPU to GPU necessarily lowers this number, since the work may
  just move to a different execution unit under the same power domain.

## Contributing more machines

Send back the raw CSV — same schema, one row per run, `machine` column self-identifying
— and it folds directly into a cross-machine comparison. No need to touch this
doc's prose to add a data point.
