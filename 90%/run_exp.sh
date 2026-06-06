#!/usr/bin/env bash
set -Eeuo pipefail

# Strict GC-pressure discard on/off experiment for a dedicated NVMe device.
#
# Default target:
#   DEVICE=/dev/nvme0n1
#   MNT=/nvme/media
#
# Usage:
#   sudo ./run_exp.sh <on|off> [runtime_sec]
#
# First-time setup on an empty NVMe namespace:
#   sudo INIT_DEVICE=1 CONFIRM_DEVICE=/dev/nvme0n1 ./run_exp.sh off 900
#
# After the device is mounted:
#   sudo ./run_exp.sh off 900
#   sudo ./run_exp.sh on  900
#
# This script intentionally writes a lot of real data. It is designed to create
# high-occupancy pressure on the NVMe device so that device-side GC is very
# likely during the measurement phase.
#
# It does NOT run nvme read.
# It does NOT delete experiment data at the end.
# It restores the mount option to nodiscard on exit by default.

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <on|off> [runtime_sec]" >&2
  exit 1
fi

DISCARD_STATE="$1"
case "$DISCARD_STATE" in
  on)  MOUNT_OPT="discard";   MODE="online_discard" ;;
  off) MOUNT_OPT="nodiscard"; MODE="nodiscard" ;;
  *) echo "[-] Error: use only 'on' or 'off'." >&2; exit 1 ;;
esac

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TS=$(date +%Y%m%d_%H%M%S)

# ---------------------------------------------------------------------------
# Target device and mount point.
# ---------------------------------------------------------------------------
DEVICE=${DEVICE:-/dev/nvme0n1}
REQUIRED_SOURCE=${REQUIRED_SOURCE:-$DEVICE}
MNT=${MNT:-/nvme/media}

# Formatting is allowed only when both are explicitly set.
INIT_DEVICE=${INIT_DEVICE:-0}
CONFIRM_DEVICE=${CONFIRM_DEVICE:-}
DO_BLKDISCARD=${DO_BLKDISCARD:-0}
ALLOW_PARTITIONED_DEVICE=${ALLOW_PARTITIONED_DEVICE:-0}
ALLOW_SOURCE_MISMATCH=${ALLOW_SOURCE_MISMATCH:-0}
ALLOW_NO_DISCARD=${ALLOW_NO_DISCARD:-0}

# ---------------------------------------------------------------------------
# Runtime and logs.
# ---------------------------------------------------------------------------
RUNTIME_SEC=${2:-${FILEBENCH_RUNTIME_SEC:-900}}
LOG_ROOT=${LOG_ROOT:-$BASE_DIR/logs}
LOG_DIR=${LOG_DIR:-$LOG_ROOT/${TS}_${MODE}_strict_gc}
WML_DIR="$LOG_DIR/wml"
META_LOG="$LOG_DIR/meta.log"
SETUP_LOG="$LOG_DIR/setup.log"
RUN_LOG="$LOG_DIR/filebench.log"
AGE_LOG="$LOG_DIR/age_create.log"
WK_CREATE_LOG="$LOG_DIR/work_create.log"
DEL_LOG="$LOG_DIR/delete.log"
CHECK_LOG="$LOG_DIR/check.log"
RESULT_LOG="$LOG_DIR/result.log"

# ---------------------------------------------------------------------------
# Data layout on NVMe.
# ---------------------------------------------------------------------------
DATA_ROOT=${DATA_ROOT:-$MNT/gc_exp}
AGE_DIR=${AGE_DIR:-$DATA_ROOT/age_filler}
DATA_DIR=${DATA_DIR:-$DATA_ROOT/${TS}_${MODE}_data}
FB_DIR=${FB_DIR:-$DATA_DIR/filebench}
WK_DIR=${WK_DIR:-$DATA_DIR/work}

# ---------------------------------------------------------------------------
# Safety and behavior.
# ---------------------------------------------------------------------------
RESTORE_NODISCARD_ON_EXIT=${RESTORE_NODISCARD_ON_EXIT:-1}
DISABLE_ASLR=${DISABLE_ASLR:-1}
REFUSE_EXISTING_DATA_DIR=${REFUSE_EXISTING_DATA_DIR:-1}
MIN_FREE_GIB_AFTER_RUN=${MIN_FREE_GIB_AFTER_RUN:-40}
WAIT_RUNNING_TIMEOUT_SEC=${WAIT_RUNNING_TIMEOUT_SEC:-10800}
RUNNING_POLL_LOG_SEC=${RUNNING_POLL_LOG_SEC:-10}

# ---------------------------------------------------------------------------
# Strict GC-pressure aging.
#
# The script fills AGE_DIR until expected free space at measurement phase is
# near GC_TARGET_FREE_GIB.
#
# Age target calculation:
#   desired_free_before_run =
#       GC_TARGET_FREE_GIB
#     + expected_filebench_prealloc
#     + WK_MIN_GIB
#     + RUN_HEADROOM_GIB
#
# Then filebench prealloc and work creation consume most of that space.
# ---------------------------------------------------------------------------
AGE_ENABLE=${AGE_ENABLE:-1}
GC_TARGET_FREE_GIB=${GC_TARGET_FREE_GIB:-430}
RUN_HEADROOM_GIB=${RUN_HEADROOM_GIB:-30}
MIN_AGE_CREATE_GIB=${MIN_AGE_CREATE_GIB:-1}
AGE_DIRS=${AGE_DIRS:-8}
AGE_SIZES=${AGE_SIZES:-1g}
AGE_WEIGHTS=${AGE_WEIGHTS:-1}
AGE_SEED=${AGE_SEED:-20260528}
AGE_PROGRESS_SEC=${AGE_PROGRESS_SEC:-30}

# ---------------------------------------------------------------------------
# Filebench foreground workload.
# Defaults are intentionally strong for a 1TB dedicated NVMe.
# ---------------------------------------------------------------------------
FB_LOGICAL_GIB=${FB_LOGICAL_GIB:-160}
FB_PREALLOC=${FB_PREALLOC:-80}
FB_MEANFILE_KIB=${FB_MEANFILE_KIB:-1024}
FB_SET_COUNT=${FB_SET_COUNT:-1}
FB_SET_ENTRIES=${FB_SET_ENTRIES:-auto}
FB_THREADS=${FB_THREADS:-16}
FB_DIRWIDTH=${FB_DIRWIDTH:-64}
FB_IOSIZE=${FB_IOSIZE:-1m}
FB_APPEND=${FB_APPEND:-16k}

# ---------------------------------------------------------------------------
# Work files.
#
# They are created concurrently with filebench preallocation. To make GC pressure
# predictable, the script guarantees at least WK_MIN_GIB before measurement.
# If filebench reaches Running... early, work creation continues until WK_MIN_GIB
# and then stops. It can continue up to WK_TARGET_GIB if preallocation is slow.
# ---------------------------------------------------------------------------
WK_TARGET_GIB=${WK_TARGET_GIB:-100}
WK_MIN_GIB=${WK_MIN_GIB:-100}
WK_DIRS=${WK_DIRS:-32}
WK_SIZES=${WK_SIZES:-1m,4m,16m}
WK_WEIGHTS=${WK_WEIGHTS:-5,3,1}
WK_SEED=${WK_SEED:-20260526}
WK_PROGRESS_SEC=${WK_PROGRESS_SEC:-10}
STRICT_WORK_MIN=${STRICT_WORK_MIN:-1}

# ---------------------------------------------------------------------------
# Delete worker.
# ---------------------------------------------------------------------------
DELETE_RATE_GIB_PER_MIN=${DELETE_RATE_GIB_PER_MIN:-6}
DELETE_TICK_SEC=${DELETE_TICK_SEC:-1}
DELETE_PROGRESS_SEC=${DELETE_PROGRESS_SEC:-10}
DEL_SEED=${DEL_SEED:-20260527}

WK_MANIFEST="$LOG_DIR/work.tsv"
WK_SUMMARY="$LOG_DIR/work.json"
WK_STOP_FILE="$LOG_DIR/work.stop"
AGE_MANIFEST="$LOG_DIR/age.tsv"
AGE_SUMMARY="$LOG_DIR/age.json"

FS_SOURCE=""
FS_TARGET=""
FS_FSTYPE=""
FS_OPTIONS=""
FILEBENCH_PID=""
WORK_CREATE_PID=""
DELETE_PID=""

FB_EXPECTED_PREALLOC_BYTES=0
WK_TARGET_BYTES=0
WK_MIN_BYTES=0

mkdir -p "$LOG_DIR" "$WML_DIR"
: > "$META_LOG"
: > "$SETUP_LOG"
: > "$RUN_LOG"
: > "$AGE_LOG"
: > "$WK_CREATE_LOG"
: > "$DEL_LOG"
: > "$CHECK_LOG"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$META_LOG"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "run as root: sudo $0 <on|off> [runtime_sec]" >&2; exit 1; }
}

canonical_dev() {
  readlink -f "$1"
}

path_under() {
  python3 - "$1" "$2" <<'PY'
import os, sys
base = os.path.realpath(os.path.abspath(sys.argv[1])).rstrip(os.sep)
path = os.path.realpath(os.path.abspath(sys.argv[2]))
print('yes' if path == base or path.startswith(base + os.sep) else 'no')
PY
}

cleanup_bg() {
  local pid
  for pid in "$DELETE_PID" "$WORK_CREATE_PID" "$FILEBENCH_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}

remount_nodiscard_for_cleanup() {
  [[ "$RESTORE_NODISCARD_ON_EXIT" == "1" ]] || return 0
  [[ -n "${FS_TARGET:-}" ]] || return 0
  log "restore mount option: mount -o remount,nodiscard $FS_TARGET"
  mount -o remount,nodiscard "$FS_TARGET" >> "$SETUP_LOG" 2>&1 || true
}

cleanup_all() {
  local rc=$?
  cleanup_bg
  remount_nodiscard_for_cleanup
  log "experiment data preserved under: $DATA_DIR"
  log "age filler preserved under: $AGE_DIR"
  log "logs preserved under: $LOG_DIR"
  exit "$rc"
}
trap cleanup_all EXIT

python_calc() {
  python3 - "$@" <<'PY'
import sys
kind = sys.argv[1]

def size_to_bytes(s: str) -> int:
    s = str(s).strip().lower()
    if s.endswith('k'):
        return int(float(s[:-1]) * 1024)
    if s.endswith('m'):
        return int(float(s[:-1]) * 1024**2)
    if s.endswith('g'):
        return int(float(s[:-1]) * 1024**3)
    return int(float(s))

if kind == 'human':
    n = int(sys.argv[2])
    if n >= 1024**3:
        print(f"{n / 1024**3:.2f}GiB")
    elif n >= 1024**2:
        print(f"{n / 1024**2:.2f}MiB")
    elif n >= 1024:
        print(f"{n / 1024:.2f}KiB")
    else:
        print(str(n))
elif kind == 'bytes_from_gib_raw':
    print(int(float(sys.argv[2]) * 1024**3))
elif kind == 'bytes_from_gib_floor':
    gib = float(sys.argv[2])
    unit = max(1, int(sys.argv[3]))
    raw = int(gib * 1024**3)
    print((raw // unit) * unit)
elif kind == 'smallest_size':
    vals = [size_to_bytes(x) for x in sys.argv[2].split(',') if x.strip()]
    print(min(vals))
elif kind == 'fb_entries':
    logical_gib = float(sys.argv[2])
    mean_kib = int(sys.argv[3])
    set_count = max(1, int(sys.argv[4]))
    logical_bytes = int(logical_gib * 1024**3)
    mean_bytes = max(1, mean_kib * 1024)
    print(max(1, round(logical_bytes / mean_bytes / set_count)))
elif kind == 'expected_prealloc':
    logical_gib = float(sys.argv[2])
    prealloc = int(sys.argv[3])
    print((int(logical_gib * 1024**3) * prealloc) // 100)
elif kind == 'rate_bytes':
    print(int(float(sys.argv[2]) * 1024**3))
else:
    raise SystemExit(f'unknown kind: {kind}')
PY
}

human_bytes() { python_calc human "$1"; }
bytes_gib() { python_calc bytes_from_gib_raw "$1"; }

fs_avail_bytes() {
  local blocks bsize
  read -r blocks bsize < <(stat -f -c '%a %S' "$MNT")
  echo $((blocks * bsize))
}

count_files() {
  local dir="${1:-}"
  [[ -n "$dir" && -d "$dir" ]] || { echo 0; return; }
  find "$dir" -type f 2>/dev/null | wc -l
}

count_bytes() {
  local dir="${1:-}"
  [[ -n "$dir" && -d "$dir" ]] || { echo 0; return; }
  du -sb "$dir" 2>/dev/null | awk '{print $1+0}'
}

manifest_bytes() {
  local manifest="$1"
  [[ -f "$manifest" ]] || { echo 0; return; }
  awk -F'\t' 'BEGIN{s=0} !/^#/ && NF>=2 {s+=$2} END{printf "%.0f\n", s}' "$manifest"
}

append_check() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$CHECK_LOG"
}

log_fs_state() {
  local tag="${1:-fs}" avail
  avail=$(fs_avail_bytes)
  append_check "$tag fs_source=$FS_SOURCE fs_target=$FS_TARGET fs_fstype=$FS_FSTYPE fs_avail=$avail fs_avail_human=$(human_bytes "$avail")"
  df -h "$MNT" >> "$CHECK_LOG" 2>&1 || true
  findmnt -T "$MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >> "$CHECK_LOG" 2>&1 || true
}

log_tree_state() {
  local tag="${1:-state}" avail
  avail=$(fs_avail_bytes)
  append_check "$tag data_dir=$DATA_DIR fb_files=$(count_files "$FB_DIR") fb_bytes=$(count_bytes "$FB_DIR") work_files=$(count_files "$WK_DIR") work_bytes=$(count_bytes "$WK_DIR") age_bytes=$(count_bytes "$AGE_DIR") fs_avail=$avail fs_avail_human=$(human_bytes "$avail")"
}

device_has_children() {
  local n
  n=$(lsblk -nro NAME "$DEVICE" | wc -l)
  [[ "$n" -gt 1 ]]
}

device_is_mounted_anywhere() {
  lsblk -nro MOUNTPOINTS "$DEVICE" | grep -qv '^$'
}

init_and_mount_device() {
  [[ "$INIT_DEVICE" == "1" ]] || {
    echo "$MNT is not mounted. To format and mount $DEVICE, rerun with:" >&2
    echo "  sudo INIT_DEVICE=1 CONFIRM_DEVICE=$DEVICE ./run_exp.sh $DISCARD_STATE $RUNTIME_SEC" >&2
    exit 1
  }
  [[ "$CONFIRM_DEVICE" == "$DEVICE" ]] || {
    echo "refuse to mkfs: CONFIRM_DEVICE must exactly match DEVICE=$DEVICE" >&2
    exit 1
  }
  [[ -b "$DEVICE" ]] || { echo "not a block device: $DEVICE" >&2; exit 1; }

  if device_has_children && [[ "$ALLOW_PARTITIONED_DEVICE" != "1" ]]; then
    echo "refuse: $DEVICE appears to have partitions/children" >&2
    echo "This script is intended for an empty whole NVMe namespace." >&2
    echo "If intentional, set ALLOW_PARTITIONED_DEVICE=1." >&2
    lsblk "$DEVICE" >&2 || true
    exit 1
  fi
  if device_is_mounted_anywhere; then
    echo "refuse: $DEVICE or one of its children is mounted" >&2
    lsblk "$DEVICE" >&2 || true
    exit 1
  fi

  mkdir -p "$MNT"
  log "wipefs preview for $DEVICE"
  wipefs -n "$DEVICE" >> "$SETUP_LOG" 2>&1 || true

  if [[ "$DO_BLKDISCARD" == "1" ]]; then
    log "blkdiscard -f $DEVICE"
    blkdiscard -f "$DEVICE" >> "$SETUP_LOG" 2>&1 || true
  fi

  log "mkfs.ext4 -F -m 0 $DEVICE"
  mkfs.ext4 -F -m 0 -E lazy_itable_init=0,lazy_journal_init=0 "$DEVICE" >> "$SETUP_LOG" 2>&1

  log "mount -t ext4 -o noatime,nodiratime,nodiscard $DEVICE $MNT"
  mount -t ext4 -o noatime,nodiratime,nodiscard "$DEVICE" "$MNT" >> "$SETUP_LOG" 2>&1
}

discover_fs() {
  if ! mountpoint -q "$MNT"; then
    init_and_mount_device
  fi

  FS_SOURCE=$(findmnt -n -o SOURCE -T "$MNT")
  FS_TARGET=$(findmnt -n -o TARGET -T "$MNT")
  FS_FSTYPE=$(findmnt -n -o FSTYPE -T "$MNT")
  FS_OPTIONS=$(findmnt -n -o OPTIONS -T "$MNT")

  [[ -n "$FS_SOURCE" && -n "$FS_TARGET" && -n "$FS_FSTYPE" ]] || {
    echo "cannot resolve filesystem for $MNT" >&2
    exit 1
  }
  [[ "$FS_FSTYPE" == "ext4" ]] || {
    echo "refuse: $MNT is on $FS_FSTYPE, not ext4" >&2
    exit 1
  }

  if [[ "$ALLOW_SOURCE_MISMATCH" != "1" ]]; then
    local real_src real_req
    real_src=$(canonical_dev "$FS_SOURCE")
    real_req=$(canonical_dev "$REQUIRED_SOURCE")
    if [[ "$real_src" != "$real_req" ]]; then
      echo "refuse: $MNT is on $FS_SOURCE ($real_src), expected $REQUIRED_SOURCE ($real_req)" >&2
      echo "set ALLOW_SOURCE_MISMATCH=1 only if this is intentional" >&2
      exit 1
    fi
  fi

  log "filesystem resolved: source=$FS_SOURCE target=$FS_TARGET fstype=$FS_FSTYPE"
  log "current mount options: $FS_OPTIONS"
}

refresh_fs_options() {
  FS_OPTIONS=$(findmnt -n -o OPTIONS -T "$MNT")
}

option_present() {
  local opt="$1" opts="$2"
  python3 - "$opt" "$opts" <<'PY'
import sys
opt = sys.argv[1]
opts = [x.strip() for x in sys.argv[2].split(',') if x.strip()]
raise SystemExit(0 if opt in opts else 1)
PY
}

check_discard_support() {
  [[ "$DISCARD_STATE" == "on" ]] || return 0
  local block path max
  block=$(basename "$(readlink -f "$FS_SOURCE")")
  path="/sys/class/block/$block/queue/discard_max_bytes"
  if [[ -r "$path" ]]; then
    max=$(cat "$path")
    log "discard_max_bytes($block)=$max"
    if [[ "$max" == "0" && "$ALLOW_NO_DISCARD" != "1" ]]; then
      echo "refuse: discard appears unsupported for $FS_SOURCE ($path=0)" >&2
      exit 1
    fi
  else
    log "warning: cannot read $path; skip discard capability check"
  fi
}

remount_for_state() {
  echo "[+] Remounting '$FS_TARGET' with '$MOUNT_OPT'"
  log "mount -o remount,noatime,nodiratime,$MOUNT_OPT $FS_TARGET"
  mount -o "remount,noatime,nodiratime,$MOUNT_OPT" "$FS_TARGET" >> "$SETUP_LOG" 2>&1
  refresh_fs_options
  echo "[+] Checking current mount options for '$FS_TARGET'"
  echo "$FS_OPTIONS" | tee -a "$SETUP_LOG"

  if [[ "$DISCARD_STATE" == "on" ]]; then
    option_present discard "$FS_OPTIONS" || { echo "remount failed: discard not found in options" >&2; exit 1; }
  else
    if option_present discard "$FS_OPTIONS"; then
      echo "remount failed: discard is still present in options" >&2
      exit 1
    fi
  fi
}

validate_paths() {
  [[ "$FB_DIR" != "$WK_DIR" ]] || { echo "FB_DIR and WK_DIR must differ" >&2; exit 1; }
  mkdir -p "$DATA_ROOT" "$AGE_DIR"
  [[ "$(path_under "$MNT" "$DATA_ROOT")" == "yes" ]] || { echo "refuse: DATA_ROOT=$DATA_ROOT is not under MNT=$MNT" >&2; exit 1; }
  [[ "$(path_under "$MNT" "$DATA_DIR")" == "yes" ]] || { echo "refuse: DATA_DIR=$DATA_DIR is not under MNT=$MNT" >&2; exit 1; }
  [[ "$(path_under "$MNT" "$AGE_DIR")" == "yes" ]] || { echo "refuse: AGE_DIR=$AGE_DIR is not under MNT=$MNT" >&2; exit 1; }
  if [[ "$REFUSE_EXISTING_DATA_DIR" == "1" && -e "$DATA_DIR" ]]; then
    echo "refuse: DATA_DIR already exists: $DATA_DIR" >&2
    exit 1
  fi
}

compute_sizes() {
  local wk_unit current min_free min_required
  if [[ "$FB_SET_ENTRIES" == "auto" ]]; then
    FB_SET_ENTRIES=$(python_calc fb_entries "$FB_LOGICAL_GIB" "$FB_MEANFILE_KIB" "$FB_SET_COUNT")
  fi
  wk_unit=$(python_calc smallest_size "$WK_SIZES")
  WK_TARGET_BYTES=$(python_calc bytes_from_gib_floor "$WK_TARGET_GIB" "$wk_unit")
  WK_MIN_BYTES=$(python_calc bytes_from_gib_floor "$WK_MIN_GIB" "$wk_unit")
  FB_EXPECTED_PREALLOC_BYTES=$(python_calc expected_prealloc "$FB_LOGICAL_GIB" "$FB_PREALLOC")

  current=$(fs_avail_bytes)
  min_free=$(bytes_gib "$MIN_FREE_GIB_AFTER_RUN")
  min_required=$((FB_EXPECTED_PREALLOC_BYTES + WK_MIN_BYTES + min_free))
  if (( current < min_required )); then
    echo "not enough free space for requested strict run" >&2
    echo "current=$(human_bytes "$current"), minimum_required=$(human_bytes "$min_required")" >&2
    echo "reduce FB_LOGICAL_GIB or WK_MIN_GIB" >&2
    exit 1
  fi
}

record_meta() {
  {
    echo "discard_state=$DISCARD_STATE"
    echo "mode=$MODE"
    echo "mount_opt=$MOUNT_OPT"
    echo "device=$DEVICE"
    echo "required_source=$REQUIRED_SOURCE"
    echo "fs_source=$FS_SOURCE"
    echo "fs_target=$FS_TARGET"
    echo "fs_fstype=$FS_FSTYPE"
    echo "fs_options=$FS_OPTIONS"
    echo "base_dir=$BASE_DIR"
    echo "mnt=$MNT"
    echo "data_root=$DATA_ROOT"
    echo "data_dir=$DATA_DIR"
    echo "age_dir=$AGE_DIR"
    echo "fb_dir=$FB_DIR"
    echo "wk_dir=$WK_DIR"
    echo "log_dir=$LOG_DIR"
    echo "runtime_sec=$RUNTIME_SEC"
    echo "age_enable=$AGE_ENABLE"
    echo "gc_target_free_gib=$GC_TARGET_FREE_GIB"
    echo "run_headroom_gib=$RUN_HEADROOM_GIB"
    echo "min_free_gib_after_run=$MIN_FREE_GIB_AFTER_RUN"
    echo "fb_logical_gib=$FB_LOGICAL_GIB"
    echo "fb_expected_prealloc_bytes=$FB_EXPECTED_PREALLOC_BYTES"
    echo "fb_expected_prealloc_human=$(human_bytes "$FB_EXPECTED_PREALLOC_BYTES")"
    echo "fb_prealloc=$FB_PREALLOC"
    echo "fb_meanfile_kib=$FB_MEANFILE_KIB"
    echo "fb_set_count=$FB_SET_COUNT"
    echo "fb_set_entries=$FB_SET_ENTRIES"
    echo "fb_threads=$FB_THREADS"
    echo "wk_target_gib=$WK_TARGET_GIB"
    echo "wk_target_bytes=$WK_TARGET_BYTES"
    echo "wk_target_human=$(human_bytes "$WK_TARGET_BYTES")"
    echo "wk_min_gib=$WK_MIN_GIB"
    echo "wk_min_bytes=$WK_MIN_BYTES"
    echo "wk_min_human=$(human_bytes "$WK_MIN_BYTES")"
    echo "strict_work_min=$STRICT_WORK_MIN"
    echo "delete_rate_gib_per_min=$DELETE_RATE_GIB_PER_MIN"
    echo "delete_tick_sec=$DELETE_TICK_SEC"
    echo "delete_progress_sec=$DELETE_PROGRESS_SEC"
    echo "preserve_data_on_exit=1"
  } >> "$META_LOG"
}

prepare_start_dirs() {
  mkdir -p "$DATA_DIR" "$FB_DIR" "$WK_DIR" "$AGE_DIR"
}

disable_aslr() {
  [[ "$DISABLE_ASLR" == "1" ]] || return 0
  echo "[+] Disabling address space randomization"
  echo 0 > /proc/sys/kernel/randomize_va_space
}

ensure_free_guard() {
  local tag="${1:-guard}" free min_free
  free=$(fs_avail_bytes)
  min_free=$(bytes_gib "$MIN_FREE_GIB_AFTER_RUN")
  if (( free < min_free )); then
    echo "free-space guard failed at $tag: avail=$(human_bytes "$free"), min=$(human_bytes "$min_free")" >&2
    exit 1
  fi
}

ensure_age_pressure() {
  [[ "$AGE_ENABLE" == "1" ]] || { log "age filler disabled"; return 0; }

  local free target_free headroom desired_before_run age_needed min_age unit age_run_dir
  free=$(fs_avail_bytes)
  target_free=$(bytes_gib "$GC_TARGET_FREE_GIB")
  headroom=$(bytes_gib "$RUN_HEADROOM_GIB")

  # Use WK_MIN_BYTES instead of WK_TARGET_BYTES to make the target realistic even
  # if work creation is stopped after the guaranteed minimum.
  desired_before_run=$((target_free + FB_EXPECTED_PREALLOC_BYTES + WK_MIN_BYTES + headroom))

  log "age planning: free=$(human_bytes "$free") desired_before_run=$(human_bytes "$desired_before_run") target_measurement_free=$(human_bytes "$target_free")"

  if (( free <= desired_before_run )); then
    log "skip age filler: current free space is already low enough"
    return 0
  fi

  age_needed=$((free - desired_before_run))
  min_age=$(bytes_gib "$MIN_AGE_CREATE_GIB")
  if (( age_needed < min_age )); then
    log "skip age filler: age_needed=$(human_bytes "$age_needed") < min_age=$(human_bytes "$min_age")"
    return 0
  fi

  unit=$(python_calc smallest_size "$AGE_SIZES")
  age_needed=$((age_needed / unit * unit))
  age_run_dir="$AGE_DIR/age_${TS}_${MODE}"

  log "create age filler $(human_bytes "$age_needed") under $age_run_dir"
  python3 "$BASE_DIR/mk_work.py" \
    --base-dir "$age_run_dir" \
    --manifest "$AGE_MANIFEST" \
    --summary "$AGE_SUMMARY" \
    --dir-count "$AGE_DIRS" \
    --seed "$AGE_SEED" \
    --target-bytes "$age_needed" \
    --sizes "$AGE_SIZES" \
    --weights "$AGE_WEIGHTS" \
    --log "$AGE_LOG" \
    --progress-sec "$AGE_PROGRESS_SEC"

  log_fs_state after_age
}

gen_wml() {
  log "generate filebench workload"
  python3 "$BASE_DIR/mk_wml.py" \
    --out-dir "$WML_DIR" \
    --fb-dir "$FB_DIR" \
    --set-count "$FB_SET_COUNT" \
    --entries-per-set "$FB_SET_ENTRIES" \
    --prealloc "$FB_PREALLOC" \
    --dirwidth "$FB_DIRWIDTH" \
    --mean-file-kib "$FB_MEANFILE_KIB" \
    --runtime-sec "$RUNTIME_SEC" \
    --iosize "$FB_IOSIZE" \
    --append-size "$FB_APPEND" \
    --threads-total "$FB_THREADS"
}

start_filebench() {
  log "start filebench: prealloc and runtime in one invocation"
  : > "$RUN_LOG"
  stdbuf -oL -eL filebench -f "$WML_DIR/run.f" > "$RUN_LOG" 2>&1 &
  FILEBENCH_PID=$!
}

start_work_creator() {
  log "start concurrent work-file creation target=$(human_bytes "$WK_TARGET_BYTES") min=$(human_bytes "$WK_MIN_BYTES")"
  rm -f "$WK_STOP_FILE"
  : > "$WK_CREATE_LOG"
  python3 "$BASE_DIR/mk_work.py" \
    --base-dir "$WK_DIR" \
    --manifest "$WK_MANIFEST" \
    --summary "$WK_SUMMARY" \
    --dir-count "$WK_DIRS" \
    --seed "$WK_SEED" \
    --target-bytes "$WK_TARGET_BYTES" \
    --sizes "$WK_SIZES" \
    --weights "$WK_WEIGHTS" \
    --stop-file "$WK_STOP_FILE" \
    --log "$WK_CREATE_LOG" \
    --progress-sec "$WK_PROGRESS_SEC" &
  WORK_CREATE_PID=$!
}

wait_for_filebench_running() {
  local timeout=${1:-1800}
  local waited=0 next_notice=$RUNNING_POLL_LOG_SEC
  while kill -0 "$FILEBENCH_PID" 2>/dev/null; do
    if grep -Fq 'Running...' "$RUN_LOG" 2>/dev/null; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
    if (( waited >= next_notice )); then
      log "waiting for filebench Running... (${waited}s elapsed; work_created=$(human_bytes "$(manifest_bytes "$WK_MANIFEST")"))"
      next_notice=$((next_notice + RUNNING_POLL_LOG_SEC))
    fi
    if (( waited >= timeout )); then
      return 1
    fi
  done
  return 1
}

wait_work_min_or_target_then_stop() {
  local created waited=0
  created=$(manifest_bytes "$WK_MANIFEST")

  if [[ "$STRICT_WORK_MIN" == "1" && "$created" -lt "$WK_MIN_BYTES" ]]; then
    log "filebench Running reached, but work_created=$(human_bytes "$created") < min=$(human_bytes "$WK_MIN_BYTES"); continue work creation until minimum"
  fi

  while [[ -n "$WORK_CREATE_PID" ]] && kill -0 "$WORK_CREATE_PID" 2>/dev/null; do
    created=$(manifest_bytes "$WK_MANIFEST")
    if (( created >= WK_MIN_BYTES )); then
      log "stop work-file creation: created=$(human_bytes "$created") reached min=$(human_bytes "$WK_MIN_BYTES")"
      : > "$WK_STOP_FILE"
      break
    fi
    if (( created >= WK_TARGET_BYTES )); then
      log "work-file creation reached target=$(human_bytes "$WK_TARGET_BYTES")"
      break
    fi
    sleep 1
    waited=$((waited + 1))
    if (( waited % RUNNING_POLL_LOG_SEC == 0 )); then
      log "waiting for work minimum... (${waited}s after Running; work_created=$(human_bytes "$created"))"
    fi
  done

  if [[ -n "$WORK_CREATE_PID" ]]; then
    wait "$WORK_CREATE_PID" || true
  fi
  WORK_CREATE_PID=""

  created=$(manifest_bytes "$WK_MANIFEST")
  log "work creation stopped created=$(human_bytes "$created") min=$(human_bytes "$WK_MIN_BYTES") target=$(human_bytes "$WK_TARGET_BYTES")"
  if (( created < WK_MIN_BYTES )); then
    echo "not enough work files created: created=$(human_bytes "$created"), min=$(human_bytes "$WK_MIN_BYTES")" >&2
    exit 1
  fi
  log_tree_state work_ready
  log_fs_state work_ready
}

start_delete() {
  local rate_bytes
  rate_bytes=$(python_calc rate_bytes "$DELETE_RATE_GIB_PER_MIN")
  log "start delete worker while filebench is running rate=$(human_bytes "$rate_bytes")/min progress_sec=$DELETE_PROGRESS_SEC"
  python3 "$BASE_DIR/del_work.py" \
    --manifest "$WK_MANIFEST" \
    --base-dir "$WK_DIR" \
    --tick-sec "$DELETE_TICK_SEC" \
    --progress-sec "$DELETE_PROGRESS_SEC" \
    --runtime-sec "$RUNTIME_SEC" \
    --rate-bytes-per-min "$rate_bytes" \
    --seed "$DEL_SEED" \
    --watch-pid "$FILEBENCH_PID" \
    --log "$DEL_LOG" &
  DELETE_PID=$!
}

write_result() {
  local verdict="$1" msg="$2"
  {
    echo "result=$verdict"
    echo "message=$msg"
    echo "device=$DEVICE"
    echo "mount=$MNT"
    echo "data_dir=$DATA_DIR"
    echo "age_dir=$AGE_DIR"
    echo "log_dir=$LOG_DIR"
    echo "fb_dir=$FB_DIR"
    echo "wk_dir=$WK_DIR"
  } > "$RESULT_LOG"
}

run_experiment() {
  ensure_age_pressure
  ensure_free_guard after_age

  gen_wml
  ensure_free_guard before_start

  # Phase 1: filebench preallocation and work-file creation begin together.
  start_filebench
  start_work_creator

  if ! wait_for_filebench_running "$WAIT_RUNNING_TIMEOUT_SEC"; then
    tail -n 120 "$RUN_LOG" >&2 || true
    write_result FAIL "filebench did not reach Running state"
    exit 1
  fi

  log "filebench reached Running state; preallocation phase is done"
  log_tree_state filebench_running
  log_fs_state filebench_running

  # Stronger behavior for GC pressure: guarantee WK_MIN_GIB of work files.
  wait_work_min_or_target_then_stop
  ensure_free_guard before_delete

  # Phase 2: filebench runtime and work-file deletion proceed together.
  log "measurement begins: filebench runtime + delete stream"
  append_check "measurement_begin mount_opt=$MOUNT_OPT discard_state=$DISCARD_STATE data_dir=$DATA_DIR"
  start_delete

  set +e
  wait "$FILEBENCH_PID"
  local fb_rc=$?
  set -e
  log "filebench exit rc=$fb_rc"

  [[ -z "$DELETE_PID" ]] || wait "$DELETE_PID" || true
  DELETE_PID=""

  log_tree_state after_run
  log_fs_state after_run
  ensure_free_guard after_run

  if [[ $fb_rc -eq 0 ]]; then
    write_result PASS "run completed; data preserved under DATA_DIR"
  else
    write_result FAIL "filebench rc=$fb_rc"
    exit "$fb_rc"
  fi
}

main() {
  require_root
  need_cmd python3
  need_cmd findmnt
  need_cmd mount
  need_cmd mountpoint
  need_cmd stat
  need_cmd df
  need_cmd du
  need_cmd awk
  need_cmd sync
  need_cmd stdbuf
  need_cmd filebench
  need_cmd lsblk
  need_cmd readlink
  need_cmd mkfs.ext4
  need_cmd wipefs

  discover_fs
  check_discard_support
  validate_paths
  compute_sizes
  record_meta
  disable_aslr
  prepare_start_dirs
  log_fs_state initial

  remount_for_state
  log_fs_state after_remount

  run_experiment
  log "done: $LOG_DIR"
  log "data left in: $DATA_DIR"
}

main "$@"

