#!/usr/bin/env bash
set -u

mkdir -p logs
LOG="./logs/df_nvme0_$(date +%Y%m%d_%H%M%S).log"

while true; do
  echo "===== $(date '+%F %T') ====="

  TARGET=$(findmnt -rn -S /dev/nvme0n1 -o TARGET 2>/dev/null | head -n1 || true)

  if [[ -n "$TARGET" ]]; then
    echo "[mounted] /dev/nvme0n1 -> $TARGET"
    df -h "$TARGET"
    findmnt -T "$TARGET" -o SOURCE,TARGET,FSTYPE,OPTIONS
  else
    echo "[not mounted] /dev/nvme0n1 is not mounted yet"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS /dev/nvme0n1 2>/dev/null || true
  fi

  echo
  sleep 10
done | tee -a "$LOG"
