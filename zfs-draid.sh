#!/usr/bin/env bash
# Create a ZFS pool with dRAID vdevs (parity 2 or 3), optional mirrored log (SLOG), L2ARC cache,
# and optional mirrored (or raidz) special vdev for metadata / small blocks.
#
# Data disks:
#   DATA_DISK_SOURCE=mpath  Multipath SAS/SATA backends (default; original behavior).
#   DATA_DISK_SOURCE=nvme  Whole-disk NVMe by-id paths: take the largest TOTAL_DISKS drives matching
#                          DISK_PATTERN; next four smallest unused NVMe matches become log+cache (e.g. 20×
#                          7.68TB + 4× 800GB on Micron NVMe front bays; OS stays on rear SATA).
#
# Usage:
#   zfs-draid.sh                         # read-only assessment: inventory + recommended pool layouts
#   zfs-draid.sh [options] <disk_vendor_grep_pattern> [total_hdd_count]
#
# Examples:
#   zfs-draid.sh                           # report hardware and rank deployments (special vdev first)
#   zfs-draid.sh SEAGATE                   # 78 disks → 3×26 dRAID vdevs (mpath; layout auto from DRAID_PARITY)
#   zfs-draid.sh SEAGATE 52                # 52 disks → 2×26
#   DRAID_VDEV_SPEC=draid3:9d:26c:2s zfs-draid.sh SEAGATE 78   # restore fixed 26-disk dRAID3 tuple from older script
#   SPECIAL=Y DRY_RUN=1 zfs-draid.sh SEAGATE 78                # + default special vdev (10× mirror, 20 NVMe)
#   zfs-draid.sh --special=mirror5 SEAGATE 78                  # conservative special vdev (5× mirror, 10 NVMe)
#   zfs-draid.sh --special=mirror9+2spare SEAGATE 78           # 9× mirror special + 2 pool hot spares
#   zfs-draid.sh --special=raidz2-18+2spare SEAGATE 78         # raidz2×18 special + 2 pool hot spares
#   DATA_DISK_SOURCE=nvme DRAID_PARITY=2 DRY_RUN=1 zfs-draid.sh MICRON 20
#
# Environment overrides:
#   POOL             Pool name (default: hostname-based data1/data2 when script is named zfs-draid*;
#                    otherwise script basename before first dot)
#   DATA_DISK_SOURCE  mpath | nvme (default: mpath)
#   DRAID_PARITY     2 or 3 (default: 3). dRAID layout (D,S) is computed per vdev child count.
#   DRAID_PROFILE    balanced (default) | capacity — balanced prefers ≥2 redundancy groups and D≈8;
#                    capacity maximizes data disks (may use a single very wide group).
#   DRAID_VDEV_SPEC  If set (e.g. draid3:9d:26c:2s), use this literal for every dRAID child vdev instead of auto layout.
#   DISKS_PER_VDEV   Disks per dRAID child vdev (mpath default: 26; nvme default: total_hdd_count)
#   SPECIAL          Y | layout name — enable special vdev (default layout: mirror10). N/no/0 disables.
#   SPECIAL_VDEV     Same as SPECIAL when set to a layout name; overrides SPECIAL=Y default.
#   SPECIAL_PATTERN  Optional substring filter for NVMe chosen as special (default: largest unused after log/cache).
#   DRY_RUN=1        Print discovery, layout, command, and log preamble only (no mpathconf / zpool create)
#   MPATH_SORT_CMD   Optional sort pipeline for multipath WWIDs (default: sort -u). Example: "sort -t- -k2 -n"
#   POOL_SETUP_LOG   Log file path (default: /tmp/zfs-orcd-<pool>-<timestamp>.log)
#   SKIP_CONFIRM=1   Skip the interactive confirmation before zpool create (non-interactive / automation)
#
# Multipath / HDD discovery (default: WWID-first maps, friendly names off):
#   SKIP_MPATH_MPATHCONF=1   Do not run mpathconf or restart multipathd (use existing host config)
#   MPATH_USER_FRIENDLY_NAMES=1  Assume friendly names (mpathX) may be on: skip mpathconf and use broader
#                                multipath -l parsing (WWID from mpath line or WWID+dm- line)
#
# Special vdev (mpath pools only): four smallest unused NVMe → log+cache; largest remainder → special.
#   Run with --help-special for layout choices. Losing the entire special vdev loses the pool — use mirrors in prod.
#
set -euo pipefail

DEFAULT_TOTAL_DISKS=78
DATA_DISK_SOURCE="${DATA_DISK_SOURCE:-mpath}"
DRAID_PARITY="${DRAID_PARITY:-3}"
DRAID_PROFILE="${DRAID_PROFILE:-balanced}"
DRAID_VDEV_SPEC="${DRAID_VDEV_SPEC:-}"
DRY_RUN="${DRY_RUN:-0}"
MPATH_SORT_CMD="${MPATH_SORT_CMD:-sort -u}"
# 0 = default layout: user_friendly_names n (WWID leads map lines); 1 = allow mpath alias headers
MPATH_USER_FRIENDLY_NAMES="${MPATH_USER_FRIENDLY_NAMES:-0}"
SPECIAL="${SPECIAL:-}"
SPECIAL_VDEV="${SPECIAL_VDEV:-}"
SPECIAL_PATTERN="${SPECIAL_PATTERN:-}"
SPECIAL_ENABLED=0
SPECIAL_LAYOUT=""
ASSESS_ONLY="${ASSESS_ONLY:-0}"
NVME_SPECIAL=()
NVME_POOL_SPARE=()
CLI_POSITIONAL=()

SCRIPT_PATH="${BASH_SOURCE[0]}"
fn=$(basename "$0")

default_pool_name_from_host() {
  local h
  h=$(hostname -s 2>/dev/null || hostname)
  h="${h%%.*}"
  case "$h" in
    *-n1 | *_n1) echo data1 ;;
    *-n2 | *_n2) echo data2 ;;
    *) echo "$h" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_' ;;
  esac
}

if [[ -z "${POOL:-}" ]]; then
  _pool_from_fn=$(echo "$fn" | cut -d'.' -f1)
  if [[ "$_pool_from_fn" == zfs-draid* ]]; then
    POOL=$(default_pool_name_from_host)
  else
    POOL="$_pool_from_fn"
  fi
  unset _pool_from_fn
fi

special_layout_help() {
  cat <<'EOF'
Special vdev layouts (enable with SPECIAL=Y, --special[=layout], or SPECIAL_VDEV=layout):

  Layout       NVMe disks   zpool fragment (conceptual)     Notes
  ---------    ----------   -----------------------------     -----
  mirror10     20           special + 10× mirror pairs       DEFAULT / recommended (metadata + moderate
               (default)                                      special_small_blocks). ~5% of a ~1.4 PB pool.

  mirror5      10           special + 5× mirror pairs        Conservative metadata-only; leaves 10 NVMe free
                                                                for later "zpool add special mirror …".

  mirror8      16           special + 8× mirror pairs        Staged rollout; add more mirror pairs later.

  raidz2x10    20           special + raidz2×10 + raidz2×10  Higher special capacity; worse latency/rebuild
                                                                than mirrors — not recommended for production.

  raidz3x20    20           special + raidz3×20              Parity-matched to dRAID3; still prefer mirrors.

  mirror9+2spare  20        special + 9× mirror + spare ×2   18 NVMe in special (9 pairs); 2 pool hot spares.
                               (18+2)                         Good balance of mirror latency + hot spares.

  raidz2-18+2spare 20       special raidz2×18 + spare ×2     18 NVMe raidz2 (~16× capacity); 2 pool hot spares.
                               (18+2)                         More special TB; tolerates 2 failures in special vdev.

Discovery (DATA_DISK_SOURCE=mpath):
  - 4 smallest unused whole-disk NVMe by-id paths → 2× SLOG mirror + 2× L2ARC cache
  - Largest remaining NVMe (optionally filtered by SPECIAL_PATTERN) → special vdev (+ pool spares if layout includes +2spare)
  - Requires 4 + (layout NVMe total) unused NVMe (e.g. 24 for mirror10 or mirror9+2spare on R284: 4×7500 + 20×7600)

Aliases: default, recommended → mirror10; conservative → mirror5; staged → mirror8;
          raidz2 → raidz2x10; raidz3 → raidz3x20; mirror9 → mirror9+2spare; raidz2-18 → raidz2-18+2spare

After pool create, enable small blocks per dataset only when measured (e.g. zfs set special_small_blocks=16K pool/dataset).
EOF
}

usage() {
  echo "Usage: $0 [options] [<disk_vendor_pattern> [total_hdd_count]]"
  echo
  echo "With no disk vendor pattern, print a read-only assessment of this server"
  echo "(inventory + ranked pool layouts). Priority is a dRAID data pool WITH a special vdev."
  echo
  echo "Options:"
  echo "  -h, --help              Show this help"
  echo "      --help-special      Show special vdev layout choices"
  echo "  -A, --assess            Force assessment report (also the default when no pattern is given)"
  echo "  -S, --special[=layout]  Enable special vdev (layout defaults to mirror10 when omitted or SPECIAL=Y)"
  echo
  echo "  disk_vendor_pattern  Case-insensitive substring matched against:"
  echo "                         - multipath maps (DATA_DISK_SOURCE=mpath, default), or"
  echo "                         - /dev/disk/by-id/nvme-* paths (DATA_DISK_SOURCE=nvme)"
  echo "  total_hdd_count      Data disks for the dRAID vdev(s) (default: ${DEFAULT_TOTAL_DISKS} for mpath;"
  echo "                         for nvme use the large-capacity count, e.g. 20). Must be a multiple of DISKS_PER_VDEV."
  echo
  echo "Key env: DATA_DISK_SOURCE=mpath|nvme  DRAID_PARITY=2|3  DRAID_PROFILE=balanced|capacity"
  echo "         SPECIAL=Y|layout  SPECIAL_VDEV=layout  SPECIAL_PATTERN=substring  DRY_RUN=1"
  echo "By default a create run applies: mpathconf --enable --user_friendly_names n (unless"
  echo "SKIP_MPATH_MPATHCONF=1 or MPATH_USER_FRIENDLY_NAMES=1; skipped for nvme data)."
  echo "Assessment mode never changes host config."
  echo
  echo "Special vdev: SPECIAL=Y or --special for default mirror10; --help-special for all layouts."
  exit "${1:-0}"
}

normalize_special_layout() {
  case "${1,,}" in
    default | recommended | mirror10) echo "mirror10" ;;
    conservative | mirror5) echo "mirror5" ;;
    staged | mirror8) echo "mirror8" ;;
    raidz2 | raidz2x10) echo "raidz2x10" ;;
    raidz3 | raidz3x20) echo "raidz3x20" ;;
    mirror9 | mirror9x2spare | mirror9+2spare) echo "mirror9+2spare" ;;
    raidz2-18 | raidz2x18 | raidz2x18+2spare | raidz2-18+2spare) echo "raidz2-18+2spare" ;;
    mirror10 | mirror5 | mirror8 | raidz2x10 | raidz3x20 | mirror9+2spare | raidz2-18+2spare) echo "${1,,}" ;;
    *)
      echo "Error: unknown special vdev layout '${1}' (try --help-special)." >&2
      return 1
      ;;
  esac
}

special_layout_special_disk_count() {
  case "$1" in
    mirror10) echo 20 ;;
    mirror5) echo 10 ;;
    mirror8) echo 16 ;;
    raidz2x10) echo 20 ;;
    raidz3x20) echo 20 ;;
    mirror9+2spare) echo 18 ;;
    raidz2-18+2spare) echo 18 ;;
    *)
      echo "Error: unknown special vdev layout '${1}'." >&2
      return 1
      ;;
  esac
}

special_layout_pool_spare_count() {
  case "$1" in
    mirror9+2spare | raidz2-18+2spare) echo 2 ;;
    mirror10 | mirror5 | mirror8 | raidz2x10 | raidz3x20) echo 0 ;;
    *)
      echo "Error: unknown special vdev layout '${1}'." >&2
      return 1
      ;;
  esac
}

special_layout_nvme_total() {
  local special spares
  special=$(special_layout_special_disk_count "$1") || return 1
  spares=$(special_layout_pool_spare_count "$1") || return 1
  echo $((special + spares))
}

special_layout_disk_count() {
  special_layout_special_disk_count "$1"
}

special_layout_summary() {
  case "$1" in
    mirror10) echo "10× mirror (20 NVMe) — recommended default" ;;
    mirror5) echo "5× mirror (10 NVMe) — conservative metadata-only" ;;
    mirror8) echo "8× mirror (16 NVMe) — staged / expandable" ;;
    raidz2x10) echo "2× raidz2×10 (20 NVMe) — capacity-biased, not recommended" ;;
    raidz3x20) echo "1× raidz3×20 (20 NVMe) — parity-matched, not recommended" ;;
    mirror9+2spare) echo "9× mirror (18 NVMe) + 2 pool hot spares" ;;
    raidz2-18+2spare) echo "raidz2×18 (18 NVMe) + 2 pool hot spares" ;;
    *) echo "$1" ;;
  esac
}

resolve_special_config() {
  SPECIAL_ENABLED=0
  SPECIAL_LAYOUT=""
  local raw="${SPECIAL_VDEV:-${SPECIAL:-}}"
  case "${raw,,}" in
    "" | n | no | 0 | false) return 0 ;;
    y | yes | 1 | true)
      SPECIAL_ENABLED=1
      SPECIAL_LAYOUT=$(normalize_special_layout mirror10) || exit 1
      ;;
    *)
      SPECIAL_ENABLED=1
      SPECIAL_LAYOUT=$(normalize_special_layout "$raw") || exit 1
      ;;
  esac
}

parse_cli_args() {
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage 0
        ;;
      --help-special)
        special_layout_help
        exit 0
        ;;
      -A | --assess)
        ASSESS_ONLY=1
        shift
        ;;
      --special)
        if [[ -n "${2:-}" && "$2" != --* && "$2" != -* ]] && normalize_special_layout "$2" >/dev/null 2>&1; then
          SPECIAL="$2"
          shift 2
        else
          SPECIAL=Y
          shift
        fi
        ;;
      --special=*)
        SPECIAL="${1#*=}"
        shift
        ;;
      -S)
        if [[ -n "${2:-}" && "$2" != --* && "$2" != -* ]] && normalize_special_layout "$2" >/dev/null 2>&1; then
          SPECIAL="$2"
          shift 2
        else
          SPECIAL=Y
          shift
        fi
        ;;
      -S*)
        SPECIAL="${1#-S}"
        shift
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        echo "Error: unknown option '${1}'." >&2
        usage 1
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done
  if ((${#positional[@]} > 0)); then
    CLI_POSITIONAL=("${positional[@]}")
  else
    CLI_POSITIONAL=()
  fi
}

parse_cli_args "$@"
if ((${#CLI_POSITIONAL[@]} > 0)); then
  set -- "${CLI_POSITIONAL[@]}"
else
  set --
fi

if ((BASH_VERSINFO[0] < 4)); then
  echo "Error: this script requires bash 4+ (found ${BASH_VERSION}). On RHEL use /bin/bash." >&2
  exit 1
fi

if [[ "$ASSESS_ONLY" == "1" ]] || [[ $# -lt 1 ]]; then
  ASSESS_ONLY=1
  DISKS_PER_VDEV="${DISKS_PER_VDEV:-26}"
  resolve_special_config
else
  DISK_PATTERN="$1"
  TOTAL_DISKS="${2:-$DEFAULT_TOTAL_DISKS}"

  resolve_special_config

  if (( SPECIAL_ENABLED )) && [[ "$DATA_DISK_SOURCE" == nvme ]]; then
    echo "Error: special vdev is not supported with DATA_DISK_SOURCE=nvme (local NVMe are used for dRAID data)." >&2
    exit 1
  fi

  if [[ "$DATA_DISK_SOURCE" == nvme ]]; then
    DISKS_PER_VDEV="${DISKS_PER_VDEV:-$TOTAL_DISKS}"
  fi
  DISKS_PER_VDEV="${DISKS_PER_VDEV:-26}"

  if [[ "$DRAID_PARITY" != 2 && "$DRAID_PARITY" != 3 ]]; then
    echo "Error: DRAID_PARITY must be 2 or 3 (got '${DRAID_PARITY}')." >&2
    exit 1
  fi

  if ! [[ "$TOTAL_DISKS" =~ ^[0-9]+$ ]] || (( TOTAL_DISKS < DISKS_PER_VDEV )); then
    echo "Error: total_hdd_count must be an integer >= ${DISKS_PER_VDEV}." >&2
    exit 1
  fi

  if (( TOTAL_DISKS % DISKS_PER_VDEV != 0 )); then
    echo "Error: total_hdd_count (${TOTAL_DISKS}) must be a multiple of DISKS_PER_VDEV (${DISKS_PER_VDEV})." >&2
    exit 1
  fi

  NUM_VDEVS=$((TOTAL_DISKS / DISKS_PER_VDEV))

  if [[ "$DATA_DISK_SOURCE" == mpath ]]; then
    if ! command -v multipath >/dev/null 2>&1; then
      echo "Error: multipath not found in PATH (install device-mapper-multipath)." >&2
      exit 1
    fi
  fi
fi

# --- Default multipath: friendly names off (WWID-first map lines), unless opted out ---
apply_multipath_user_friendly_names_off() {
  if [[ "${DATA_DISK_SOURCE:-mpath}" == nvme ]]; then
    echo "Note: DATA_DISK_SOURCE=nvme — skipping mpathconf / multipathd (data disks are local NVMe)."
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "Note: DRY_RUN=1 — not running mpathconf or restarting multipathd (no host changes)."
    return 0
  fi
  if [[ "${SKIP_MPATH_MPATHCONF:-0}" == "1" ]]; then
    echo "Note: SKIP_MPATH_MPATHCONF=1 — not running mpathconf or restarting multipathd."
    return 0
  fi
  if [[ "${MPATH_USER_FRIENDLY_NAMES:-0}" == "1" ]]; then
    echo "Note: MPATH_USER_FRIENDLY_NAMES=1 — not forcing mpathconf --user_friendly_names n."
    return 0
  fi
  if ! command -v mpathconf >/dev/null 2>&1; then
    echo "Warning: mpathconf not in PATH; cannot apply --user_friendly_names n (install multipath-tools)." >&2
    return 0
  fi
  echo "Applying multipath defaults: mpathconf --enable --user_friendly_names n"
  if ! mpathconf --enable --user_friendly_names n; then
    echo "Warning: mpathconf failed (root required?). Continuing with existing multipath configuration." >&2
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl try-restart multipathd 2>/dev/null || systemctl restart multipathd 2>/dev/null || true
  fi
  return 0
}

# --- HDD discovery: prefer multipathd WWID list, then multipath -l stanza walk ---
# With user_friendly_names n, map headers look like: <WWID> dm-N VENDOR,PRODUCT
extract_wwid_from_mpath_header() {
  local line=$1
  if [[ "${MPATH_USER_FRIENDLY_NAMES:-0}" != "1" ]]; then
    if [[ "$line" =~ ^([0-9A-Fa-f]{8,})\ +dm-[0-9]+ ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
    return 0
  fi
  if [[ "$line" =~ ^mpath[a-zA-Z0-9_]+\ +\(([0-9A-Fa-f]+)\) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^([0-9A-Fa-f]{8,})\ +dm- ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$line" =~ \(([0-9A-Fa-f]{8,})\) ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

# Primary: ask multipathd for WWIDs, then filter maps whose "multipath -l <wwid>" text matches the pattern.
collect_multipath_wwids_via_mpathd() {
  local pat_lc wwid
  pat_lc=$(echo "$DISK_PATTERN" | tr '[:upper:]' '[:lower:]')
  command -v multipathd >/dev/null 2>&1 || return 1
  multipathd show daemon >/dev/null 2>&1 || return 1
  multipathd show maps format "%w" 2>/dev/null |
    while IFS= read -r wwid; do
      [[ -z "$wwid" ]] && continue
      [[ "$wwid" =~ ^[0-9A-Fa-f]+$ ]] || continue
      if multipath -l "$wwid" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qF -- "$pat_lc"; then
        echo "$wwid"
      fi
    done
}

# Fallback: full multipath -l parse (stanza matches pattern; header yields WWID per extract_wwid rules).
collect_multipath_wwids_multipath_l() {
  local pat_lc stanza line ll wwid
  pat_lc=$(echo "$DISK_PATTERN" | tr '[:upper:]' '[:lower:]')
  stanza=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ dm-[0-9]+ ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
      if [[ -n "$stanza" ]]; then
        ll=$(echo "$stanza" | tr '[:upper:]' '[:lower:]')
        if [[ "$ll" == *"${pat_lc}"* ]]; then
          wwid=$(extract_wwid_from_mpath_header "$(echo "$stanza" | head -n1)")
          [[ -n "$wwid" ]] && echo "$wwid"
        fi
      fi
      stanza="$line"
    else
      stanza+=$'\n'"$line"
    fi
  done < <(multipath -l 2>/dev/null || true)
  if [[ -n "$stanza" ]]; then
    ll=$(echo "$stanza" | tr '[:upper:]' '[:lower:]')
    if [[ "$ll" == *"${pat_lc}"* ]]; then
      wwid=$(extract_wwid_from_mpath_header "$(echo "$stanza" | head -n1)")
      [[ -n "$wwid" ]] && echo "$wwid"
    fi
  fi
}

collect_multipath_wwids_all() {
  local via_mpathd
  via_mpathd=$(collect_multipath_wwids_via_mpathd 2>/dev/null | sort -u || true)
  if [[ -n "$via_mpathd" ]]; then
    echo "$via_mpathd"
    return 0
  fi
  echo "Note: multipathd WWID discovery unavailable or empty — falling back to multipath -l stanza scan." >&2
  collect_multipath_wwids_multipath_l
}

# Resolve a multipath WWID to a stable path for zpool
resolve_mpath_device() {
  local wwid=$1
  local p
  for p in \
    "/dev/disk/by-id/dm-uuid-mpath-${wwid}" \
    "/dev/disk/by-id/wwn-0x${wwid}"; do
    if [[ -b "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  for p in /dev/disk/by-id/scsi-*"${wwid}"*; do
    if [[ -b "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  if [[ -b "/dev/mapper/${wwid}" ]]; then
    echo "/dev/mapper/${wwid}"
    return 0
  fi
  echo "Error: could not resolve multipath WWID ${wwid} to a block device under /dev/disk/by-id or /dev/mapper." >&2
  return 1
}

# --- NVMe: unused whole-disk by-id paths, size from blockdev ---
nvme_by_id_candidates() {
  local f
  for f in /dev/disk/by-id/nvme-*; do
    [[ -e "$f" ]] || continue
    [[ "$f" == *-part* ]] && continue
    [[ -b "$f" ]] || continue
    echo "$f"
  done
}

is_nvme_unused_for_zfs() {
  local dev=$1
  local mp type fstype btype
  btype=$(lsblk -dn -o TYPE "$dev" 2>/dev/null || true)
  if [[ "${btype:-}" != disk ]]; then
    return 1
  fi
  mp=$(lsblk -dn -o MOUNTPOINT "$dev" 2>/dev/null || true)
  if [[ -n "${mp:-}" ]]; then
    return 1
  fi
  fstype=$(lsblk -dn -o FSTYPE "$dev" 2>/dev/null || true)
  if [[ "${fstype:-}" == swap ]]; then
    return 1
  fi
  type=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
  if [[ "${type:-}" == zfs_member ]]; then
    return 1
  fi
  return 0
}

# Pick one stable by-id symlink per backing device (nvme-* and nvme-eui.* often duplicate the same disk).
pick_unique_nvme_by_id_paths() {
  declare -A best_id_for_real=()
  local f real best
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_nvme_unused_for_zfs "$f" || continue
    real=$(readlink -f "$f" 2>/dev/null || true)
    [[ -n "$real" && -b "$real" ]] || continue
    best="${best_id_for_real[$real]:-}"
    if [[ -z "$best" || "$f" < "$best" ]]; then
      best_id_for_real[$real]="$f"
    fi
  done < <(nvme_by_id_candidates | sort -u)
  for real in "${!best_id_for_real[@]}"; do
    echo "${best_id_for_real[$real]}"
  done
}

# NVMe by-id path matches DISK_PATTERN (case-insensitive substring).
nvme_path_matches_pattern() {
  local f=$1 pat_lc
  pat_lc=$(echo "$DISK_PATTERN" | tr '[:upper:]' '[:lower:]')
  [[ "$(echo "$f" | tr '[:upper:]' '[:lower:]')" == *"${pat_lc}"* ]]
}

nvme_path_matches_special_pattern() {
  local f=$1
  if [[ -z "${SPECIAL_PATTERN:-}" ]]; then
    return 0
  fi
  local pat_lc
  pat_lc=$(echo "$SPECIAL_PATTERN" | tr '[:upper:]' '[:lower:]')
  [[ "$(echo "$f" | tr '[:upper:]' '[:lower:]')" == *"${pat_lc}"* ]]
}

# Four smallest unused NVMe → SLOG mirror + L2ARC cache; optional largest remainder → special (+ pool spares).
discover_nvme_aux_vdevs() {
  local -a rows=() sorted_asc=() tier_rows=() special_rows=() spare_rows=()
  local f sz special_count=0 spare_count=0 nvme_total=0 need n i
  local s0 s1 s2 s3 p0 p1 p2 p3

  NVME_SPECIAL=()
  NVME_POOL_SPARE=()

  if (( SPECIAL_ENABLED )); then
    special_count=$(special_layout_special_disk_count "$SPECIAL_LAYOUT") || exit 1
    spare_count=$(special_layout_pool_spare_count "$SPECIAL_LAYOUT") || exit 1
    nvme_total=$(special_layout_nvme_total "$SPECIAL_LAYOUT") || exit 1
  fi

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_nvme_unused_for_zfs "$f" || continue
    if ! sz=$(blockdev --getsize64 "$f" 2>/dev/null); then
      continue
    fi
    rows+=("${sz} ${f}")
  done < <(pick_unique_nvme_by_id_paths | sort)

  mapfile -t sorted_asc < <(printf '%s\n' "${rows[@]}" | sort -k1,1n)
  n=${#sorted_asc[@]}
  need=$((4 + nvme_total))

  if (( nvme_total == 0 )); then
    if (( n < 4 )); then
      echo "Error: need at least 4 unused whole-disk NVMe devices for log+cache; found ${n} unique disk(s) after by-id dedupe." >&2
      if (( n > 0 )); then
        printf '  %s\n' "${sorted_asc[@]}" >&2
      fi
      if command -v nvme >/dev/null 2>&1; then
        echo "nvme list (for reference):" >&2
        nvme list 2>/dev/null >&2 || true
      fi
      exit 1
    fi
    if (( n > 4 )); then
      echo "Note: ${n} unused NVMe found — using 4 smallest for log+cache. Re-run with --special (or SPECIAL=Y) to put remaining NVMe in a special vdev (recommended)." >&2
    fi
  elif (( n < need )); then
    echo "Error: need at least ${need} unused whole-disk NVMe (${n} found): 4 for log+cache + ${nvme_total} for special layout ${SPECIAL_LAYOUT} (${special_count} special + ${spare_count} pool spare)." >&2
    if (( n > 0 )); then
      printf '  %s\n' "${sorted_asc[@]}" >&2
    fi
    exit 1
  fi

  read -r s0 p0 <<<"${sorted_asc[0]}"
  read -r s1 p1 <<<"${sorted_asc[1]}"
  read -r s2 p2 <<<"${sorted_asc[2]}"
  read -r s3 p3 <<<"${sorted_asc[3]}"
  NVME_LOG=("$p0" "$p1")
  NVME_CACHE=("$p2" "$p3")

  if (( nvme_total == 0 )); then
    return 0
  fi

  if (( n > need )); then
    echo "Note: ${n} NVMe available — 4 smallest for log+cache, ${nvme_total} largest eligible for special tier (${SPECIAL_LAYOUT}: ${special_count} special + ${spare_count} pool spare)." >&2
  fi

  mapfile -t tier_rows < <(
    printf '%s\n' "${sorted_asc[@]:4}" |
      while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        read -r sz path <<<"$row"
        nvme_path_matches_special_pattern "$path" || continue
        echo "$row"
      done |
      sort -k1,1nr |
      head -n "$nvme_total" |
      sort -k2
  )

  if ((${#tier_rows[@]} != nvme_total)); then
    echo "Error: special layout ${SPECIAL_LAYOUT} needs ${nvme_total} NVMe after log/cache; matched ${#tier_rows[@]}." >&2
    if [[ -n "${SPECIAL_PATTERN:-}" ]]; then
      echo "  SPECIAL_PATTERN='${SPECIAL_PATTERN}' may be too restrictive." >&2
    fi
    exit 1
  fi

  if (( spare_count > 0 )); then
    mapfile -t spare_rows < <(printf '%s\n' "${tier_rows[@]:special_count:spare_count}")
    mapfile -t special_rows < <(printf '%s\n' "${tier_rows[@]:0:special_count}")
  else
    special_rows=("${tier_rows[@]}")
  fi

  for row in "${special_rows[@]}"; do
    read -r sz f <<<"$row"
    NVME_SPECIAL+=("$f")
  done
  for row in "${spare_rows[@]}"; do
    read -r sz f <<<"$row"
    NVME_POOL_SPARE+=("$f")
  done
}

append_special_vdev_to_zpool_cmd() {
  local layout=$1
  local -a disks=("${@:2}")
  local need i

  need=$(special_layout_special_disk_count "$layout") || return 1
  if ((${#disks[@]} != need)); then
    echo "Error: special layout ${layout} needs ${need} special disk(s), got ${#disks[@]}." >&2
    return 1
  fi

  _zpool_cmd+=(special)
  case "$layout" in
    mirror10 | mirror5 | mirror8 | mirror9+2spare)
      for ((i = 0; i < need; i += 2)); do
        _zpool_cmd+=(mirror "${disks[i]}" "${disks[i + 1]}")
      done
      ;;
    raidz2x10)
      _zpool_cmd+=(raidz2 "${disks[@]:0:10}")
      _zpool_cmd+=(raidz2 "${disks[@]:10:10}")
      ;;
    raidz3x20)
      _zpool_cmd+=(raidz3 "${disks[@]}")
      ;;
    raidz2-18+2spare)
      _zpool_cmd+=(raidz2 "${disks[@]}")
      ;;
    *)
      echo "Error: unsupported special layout '${layout}'." >&2
      return 1
      ;;
  esac
}

# OpenZFS dRAID: (children - spares) must be a multiple of (data + parity); see dRAID Howto.
# Balanced profile prefers at least two internal redundancy groups when possible, then D≈8, then spare count.
compute_best_draid_spec() {
  local C=$1 P=$2 profile=$3
  local D S w r g data pen key best="" best_key=-2147483648
  local found_multi=0 eff_min dd

  for ((S = 0; S <= 2; S++)); do
    (( C > S + P + 1 )) || continue
    for ((D = C - S - P; D >= 1; D--)); do
      w=$((D + P))
      r=$(( (C - S) % w ))
      (( r != 0 )) && continue
      g=$(( (C - S) / w ))
      (( g >= 2 )) && found_multi=1
    done
  done

  if [[ "$profile" == capacity ]]; then
    eff_min=1
  else
    eff_min=2
    (( found_multi == 0 )) && eff_min=1
  fi

  for ((S = 0; S <= 2; S++)); do
    (( C > S + P + 1 )) || continue
    for ((D = C - S - P; D >= 1; D--)); do
      w=$((D + P))
      r=$(( (C - S) % w ))
      (( r != 0 )) && continue
      g=$(( (C - S) / w ))
      (( g < eff_min )) && continue
      data=$((D * g))
      pen=0
      if [[ "$profile" == balanced ]]; then
        dd=$((D - 8))
        [[ $dd -lt 0 ]] && dd=$((0 - dd))
        pen=$((dd * 25))
      fi
      key=$((data * 10000 - pen + S * 5))
      if [[ -z "$best" || $key -gt $best_key ]]; then
        best="draid${P}:${D}d:${C}c:${S}s"
        best_key=$key
      fi
    done
  done

  if [[ -z "$best" ]]; then
    echo "Error: no valid dRAID layout for children=${C} parity=${P} profile=${profile} (need (children-spares) % (data+parity)==0)." >&2
    return 1
  fi
  printf '%s' "$best"
}

# Largest TOTAL_DISKS unused NVMe matches → dRAID data; four smallest of the remainder → mirrored log + L2ARC.
discover_nvme_data_and_four_aux() {
  local -a rows=() sorted_desc=() tail_sorted=()
  local f sz need i n
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    nvme_path_matches_pattern "$f" || continue
    is_nvme_unused_for_zfs "$f" || continue
    if ! sz=$(blockdev --getsize64 "$f" 2>/dev/null); then
      continue
    fi
    rows+=("${sz} ${f}")
  done < <(pick_unique_nvme_by_id_paths | sort)

  mapfile -t sorted_desc < <(printf '%s\n' "${rows[@]}" | sort -k1,1nr)
  n=${#sorted_desc[@]}
  need=$((TOTAL_DISKS + 4))
  if ((n < need)); then
    echo "Error: need at least ${need} unused whole-disk NVMe devices matching '${DISK_PATTERN}' (found ${n})." >&2
    if ((n > 0)); then
      printf '  %s\n' "${sorted_desc[@]}" >&2
    fi
    exit 1
  fi
  if ((n > need)); then
    echo "Note: ${n} NVMe matches — using ${TOTAL_DISKS} largest for dRAID data and the 4 smallest of the remainder for log+cache." >&2
  fi

  ALL_HDD_PATHS=()
  for ((i = 0; i < TOTAL_DISKS; i++)); do
    read -r sz f <<<"${sorted_desc[i]}"
    ALL_HDD_PATHS+=("$f")
  done

  declare -a tail=("${sorted_desc[@]:TOTAL_DISKS}")
  mapfile -t tail_sorted < <(printf '%s\n' "${tail[@]}" | sort -k1,1n | head -n 4)
  if ((${#tail_sorted[@]} != 4)); then
    echo "Error: internal NVMe tail selection failed (expected 4 auxiliary disks)." >&2
    exit 1
  fi

  local s0 s1 s2 s3 p0 p1 p2 p3
  read -r s0 p0 <<<"${tail_sorted[0]}"
  read -r s1 p1 <<<"${tail_sorted[1]}"
  read -r s2 p2 <<<"${tail_sorted[2]}"
  read -r s3 p3 <<<"${tail_sorted[3]}"
  # Smallest two → SLOG; next two → L2ARC (same-size disks split 2+2).
  NVME_LOG=("$p0" "$p1")
  NVME_CACHE=("$p2" "$p3")
}

# --- Print / log helpers (full command + layout for validation) ---
format_shell_quoted_cmd() {
  local out="" a
  for a in "$@"; do
    out+=$(printf '%q ' "$a")
  done
  printf '%s\n' "${out% }"
}

print_visual_pool_layout() {
  local i d n v
  local -a paths=()
  echo "================ POOL LAYOUT (validation) ================"
  echo "Host:              $(hostname)"
  echo "Date:              $(date -Is 2>/dev/null || date)"
  echo "Pool:              $POOL"
  echo "HDD pattern:       $DISK_PATTERN"
  echo "Data source:       ${DATA_DISK_SOURCE}"
  echo "Total data disks:  $TOTAL_DISKS (${NUM_VDEVS} × ${DISKS_PER_VDEV} children; ${ONE_DRAID_SPEC})"
  echo
  for ((v = 0; v < ${#VDEV_DISKS_ARRAYS[@]}; v++)); do
    # shellcheck disable=SC2206
    paths=(${VDEV_DISKS_ARRAYS[$v]})
    echo "--- dRAID${DRAID_PARITY} vdev $((v + 1)) (${#paths[@]} disks) — ${ONE_DRAID_SPEC} ---"
    n=0
    for d in "${paths[@]}"; do
      ((++n))
      printf '  [%2d] %s\n' "$n" "$d"
    done
    echo
  done
  echo "--- log mirror (SLOG) ---"
  i=0
  for d in "${NVME_LOG[@]}"; do
    ((++i))
    printf '  [%d] %s\n' "$i" "$d"
  done
  echo
  echo "--- cache (L2ARC) ---"
  i=0
  for d in "${NVME_CACHE[@]}"; do
    ((++i))
    printf '  [%d] %s\n' "$i" "$d"
  done
  echo
  if (( SPECIAL_ENABLED )); then
    echo "--- special (${SPECIAL_LAYOUT}: $(special_layout_summary "$SPECIAL_LAYOUT")) ---"
    i=0
    for d in "${NVME_SPECIAL[@]}"; do
      ((++i))
      printf '  [%2d] %s\n' "$i" "$d"
    done
    echo
  fi
  if ((${#NVME_POOL_SPARE[@]} > 0)); then
    echo "--- pool hot spares (NVMe) ---"
    i=0
    for d in "${NVME_POOL_SPARE[@]}"; do
      ((++i))
      printf '  [%d] %s\n' "$i" "$d"
    done
    echo
  fi
  echo "=========================================================="
}

write_pool_setup_log_preamble() {
  local logf=$1
  shift
  {
    echo "zfs-orcd-setup pool create log"
    echo "==============================="
    echo "host:     $(hostname)"
    echo "time:     $(date -Is 2>/dev/null || date)"
    echo "script:   $SCRIPT_PATH"
    echo "argv:     $*"
    echo "POOL:     $POOL"
    echo "pattern:  $DISK_PATTERN"
    echo "HDDs:     $TOTAL_DISKS"
    echo "dRAID:    ${ONE_DRAID_SPEC} (parity=${DRAID_PARITY}, profile=${DRAID_PROFILE})"
    if (( SPECIAL_ENABLED )); then
      echo "special:  ${SPECIAL_LAYOUT} ($(special_layout_summary "$SPECIAL_LAYOUT"))"
    else
      echo "special:  (disabled)"
    fi
    echo
    print_visual_pool_layout
    echo "--- zpool create (shell-quoted, one line) ---"
    format_shell_quoted_cmd "${_zpool_cmd[@]}"
    echo "--------------------------------------------"
    echo
  } >>"$logf"
}

prompt_confirm_zpool_create() {
  if [[ "${SKIP_CONFIRM:-0}" == "1" ]]; then
    echo "SKIP_CONFIRM=1 — proceeding without interactive confirmation."
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: stdin is not a terminal; refusing to destroy ambiguity around zpool create." >&2
    echo "Re-run from an interactive shell, or set SKIP_CONFIRM=1 for non-interactive use." >&2
    exit 1
  fi
  local r
  read -r -p "Confirm to run this zpool create? [y/N] " r || true
  case "${r,,}" in
    y | yes) return 0 ;;
    *)
      echo "Aborted (no pool created)." >&2
      exit 2
      ;;
  esac
}

append_post_create_to_log() {
  local logf=$1
  {
    echo
    echo "=== Post-create: $(date -Is 2>/dev/null || date) ==="
    echo "--- zpool status ---"
    zpool status "$POOL" 2>&1 || true
    echo
    echo "--- zpool list ---"
    zpool list "$POOL" 2>&1 || true
    echo
    echo "--- zfs list (pool) ---"
    zfs list -r "$POOL" 2>&1 || true
    echo
    echo "--- zpool get (selected) ---"
    zpool get size,free,allocated,health,ashift,autoexpand,autoreplace "$POOL" 2>&1 || true
    echo
    echo "--- zpool history (last 20) ---"
    zpool history "$POOL" 2>&1 | tail -n 20 || true
    echo
  } >>"$logf"
}

discover_four_nvme_log_and_cache() {
  discover_nvme_aux_vdevs
}

# --- Read-only assessment (./zfs-draid.sh with no vendor pattern) ---
human_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b >= 1125899906842624) printf "%.2f PiB", b/1125899906842624
    else if (b >= 1099511627776) printf "%.2f TiB", b/1099511627776
    else if (b >= 1073741824) printf "%.2f GiB", b/1073741824
    else if (b >= 1048576) printf "%.2f MiB", b/1048576
    else printf "%d B", b
  }'
}

assess_extract_wwid() {
  local line=$1
  if [[ "$line" =~ ^([0-9A-Fa-f]{8,})[[:space:]]+dm-[0-9]+ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^mpath[a-zA-Z0-9_]+[[:space:]]+\(([0-9A-Fa-f]+)\) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$line" =~ \(([0-9A-Fa-f]{8,})\) ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

assess_block_status() {
  local dev=$1
  local btype mp fstype type
  [[ -b "$dev" ]] || { echo "unresolved"; return; }
  btype=$(lsblk -dn -o TYPE "$dev" 2>/dev/null || true)
  if [[ -n "${btype:-}" && "$btype" != disk && "$btype" != mpath ]]; then
    echo "not-disk:${btype}"
    return
  fi
  mp=$(lsblk -dn -o MOUNTPOINT "$dev" 2>/dev/null || true)
  if [[ -n "${mp:-}" ]]; then
    echo "mounted:${mp}"
    return
  fi
  fstype=$(lsblk -dn -o FSTYPE "$dev" 2>/dev/null || true)
  if [[ "${fstype:-}" == swap ]]; then
    echo "swap"
    return
  fi
  if [[ "${fstype:-}" == zfs_member ]]; then
    echo "zfs_member"
    return
  fi
  type=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
  if [[ "${type:-}" == zfs_member ]]; then
    echo "zfs_member"
    return
  fi
  if [[ -n "${fstype:-}" ]]; then
    echo "fstype:${fstype}"
    return
  fi
  echo "unused"
}

assess_nvme_model() {
  local f=$1 m
  m=$(lsblk -dn -o MODEL "$f" 2>/dev/null || true)
  m="${m## }"
  m="${m%% }"
  if [[ -z "$m" ]]; then
    m=$(basename "$f")
  fi
  echo "$m"
}

assess_nvme_vendor_pattern() {
  local f=$1 b
  b=$(basename "$f")
  b="${b#nvme-}"
  if [[ "$b" == eui.* || "$b" == nvme.* ]]; then
    echo "NVME"
    return
  fi
  b="${b%%_*}"
  b="${b%%-*}"
  echo "$b" | tr '[:lower:]' '[:upper:]'
}

pick_all_nvme_by_id_paths() {
  declare -A best_id_for_real=()
  local f real best
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    real=$(readlink -f "$f" 2>/dev/null || true)
    [[ -n "$real" && -b "$real" ]] || continue
    best="${best_id_for_real[$real]:-}"
    if [[ -z "$best" || "$f" < "$best" ]]; then
      best_id_for_real[$real]="$f"
    fi
  done < <(nvme_by_id_candidates | sort -u)
  for real in "${!best_id_for_real[@]}"; do
    echo "${best_id_for_real[$real]}"
  done
}

assess_draid_usable_bytes() {
  local spec=$1 disk_b=$2 nvdev=$3
  local P D C S w g
  if [[ "$spec" =~ ^draid([0-9]+):([0-9]+)d:([0-9]+)c:([0-9]+)s$ ]]; then
    P="${BASH_REMATCH[1]}"
    D="${BASH_REMATCH[2]}"
    C="${BASH_REMATCH[3]}"
    S="${BASH_REMATCH[4]}"
  else
    echo 0
    return
  fi
  w=$((D + P))
  (( w > 0 && nvdev > 0 )) || { echo 0; return; }
  g=$(( (C - S) / w ))
  echo $((D * g * nvdev * disk_b))
}

assess_special_usable_bytes() {
  local layout=$1 disk_b=$2 n
  n=$(special_layout_special_disk_count "$layout") || { echo 0; return; }
  case "$layout" in
    mirror10 | mirror5 | mirror8 | mirror9+2spare) echo $(( (n / 2) * disk_b )) ;;
    raidz2x10) echo $((16 * disk_b)) ;;
    raidz3x20) echo $((17 * disk_b)) ;;
    raidz2-18+2spare) echo $((16 * disk_b)) ;;
    *) echo 0 ;;
  esac
}

assess_pick_width() {
  local total=$1 w
  if (( total >= 26 && total % 26 == 0 )); then
    echo 26
    return
  fi
  for w in 24 20 16 13 12 18 10 8; do
    if (( total >= w && total % w == 0 )) && compute_best_draid_spec "$w" 3 balanced >/dev/null 2>&1; then
      echo "$w"
      return
    fi
  done
  echo "$total"
}

assess_zpool_has_section() {
  local pool=$1 section=$2
  command -v zpool >/dev/null 2>&1 || return 1
  zpool status "$pool" 2>/dev/null | awk -v s="$section" '$1 == s { found = 1 } END { exit found ? 0 : 1 }'
}

assess_print_special_feasibility() {
  local unused=$1 special_fit=$2 small_n=$3 large_n=$4 large_sz=$5
  local need layout nvme_n
  echo "--- Special vdev feasibility (priority) ---"
  echo "  Losing an entire special vdev loses the pool — prefer mirrored special in production."
  echo "  Sizing: ~0.2–2% of data capacity for metadata; up to ~5% if using special_small_blocks."
  echo
  if (( unused < 4 )); then
    echo "  Log + L2ARC: NO  (need 4 unused NVMe, found ${unused})"
  else
    echo "  Log + L2ARC: YES (4 smallest unused NVMe)"
  fi
  if (( special_fit == 0 )); then
    echo "  Special vdev: NO named layout fits after reserving 4 NVMe for log+cache."
    echo "    Minimum script layout is mirror5 (10 NVMe special + 4 log/cache = 14 NVMe)."
    echo "    Add 10–20 same-size NVMe (typically 7.68T class) for a special vdev."
  else
    echo "  Special layouts that fit (largest unused NVMe tier, after 4 for log+cache):"
    for layout in mirror10 mirror9+2spare mirror8 mirror5 raidz2-18+2spare raidz2x10 raidz3x20; do
      nvme_n=$(special_layout_nvme_total "$layout") || continue
      if (( nvme_n <= special_fit )); then
        need=$((4 + nvme_n))
        printf '    %-18s %2d NVMe special/spare  (need %2d unused NVMe total)  %s\n' \
          "$layout" "$nvme_n" "$need" "$(special_layout_summary "$layout")"
      fi
    done
  fi
  if (( small_n > 0 && small_n < 4 && large_n >= 10 )); then
    echo
    echo "  Hardware gap: ${small_n} small NVMe is not enough for dedicated SLOG/L2ARC."
    echo "    Adding $((4 - small_n)) smaller NVMe would keep all ${large_n} large ($(human_bytes "$large_sz")) disks for special."
  fi
  echo
}

assess_print_create_option() {
  local tag=$1 parity=$2 width=$3 ndisks=$4 vendor=$5 layout=$6 disk_b=$7 spec=$8 nvme_sz=$9
  local nvdev usable spec_u ratio cmd extra
  nvdev=$((ndisks / width))
  usable=$(assess_draid_usable_bytes "$spec" "$disk_b" "$nvdev")
  ((++ASSESS_RANK))
  echo "[${ASSESS_RANK}] ${tag}"
  echo "    Data:     ${ndisks}× $(human_bytes "$disk_b") ${vendor}  →  ${nvdev} × ${spec}"
  extra="    Aux:      2× NVMe SLOG mirror + 2× NVMe L2ARC"
  if [[ -n "$layout" ]]; then
    spec_u=$(assess_special_usable_bytes "$layout" "$nvme_sz")
    extra+=$'\n'"    Special:  ${layout} — $(special_layout_summary "$layout")  ($(human_bytes "$spec_u") usable)"
    if (( usable > 0 && spec_u > 0 )); then
      ratio=$(awk -v s="$spec_u" -v d="$usable" 'BEGIN { printf "%.2f", (s/d)*100 }')
      extra+=$'\n'"    Ratio:    special is ${ratio}% of data capacity"
    fi
    cmd="./$(basename "$SCRIPT_PATH") --special=${layout} ${vendor} ${ndisks}"
  else
    extra+=$'\n'"    Special:  (none — metadata stays on HDD; not preferred)"
    cmd="./$(basename "$SCRIPT_PATH") ${vendor} ${ndisks}"
  fi
  echo "$extra"
  echo "    Usable:   ~$(human_bytes "$usable") data"
  if [[ "$parity" != 3 ]]; then
    echo "    Create:   POOL=${POOL} DRAID_PARITY=${parity} ${cmd}"
    echo "    Dry-run:  POOL=${POOL} DRAID_PARITY=${parity} DRY_RUN=1 ${cmd}"
  else
    echo "    Create:   POOL=${POOL} ${cmd}"
    echo "    Dry-run:  POOL=${POOL} DRY_RUN=1 ${cmd}"
  fi
  echo
}

run_storage_assessment() {
  local logf
  logf="${ASSESS_LOG:-/tmp/zfs-orcd-assess-$(hostname -s 2>/dev/null || hostname)-$(date +%Y%m%d-%H%M%S).log}"
  if ! : >"$logf" 2>/dev/null; then
    logf="/tmp/zfs-orcd-assess.log"
    : >"$logf" 2>/dev/null || logf="/dev/null"
  fi

  {
    host=$(hostname)
    ASSESS_SELF="./$(basename "$SCRIPT_PATH")"
    layout_order=(mirror10 mirror9+2spare mirror8 mirror5 raidz2-18+2spare raidz2x10 raidz3x20)
    ASSESS_RANK=0
    mpath_rows=()
    nvme_rows=()
    unused_nvme=()
    pools=()
    unused_nvme_n=0
    small_sz=0
    large_sz=0
    small_n=0
    large_n=0
    special_fit=0
    declare -A grp_count=() grp_unused=() grp_vendor=() grp_product=() grp_size=()
    declare -A nvme_sz_unused=()
    echo "================ STORAGE SERVER ASSESSMENT ================"
    echo "Host:              $host"
    echo "Date:              $(date -Is 2>/dev/null || date)"
    echo "Suggested pool:    $POOL"
    echo "Script:            $SCRIPT_PATH"
    echo "Mode:              read-only (no mpathconf, no zpool create)"
    if command -v zfs >/dev/null 2>&1; then
      zfsver=$(zfs version 2>/dev/null | head -n1 || true)
      echo "ZFS:               ${zfsver:-installed (version unknown)}"
    else
      echo "ZFS:               not found in PATH"
    fi
    echo
    echo "Priority: deploy a dRAID data pool WITH a special vdev (mirrored NVMe for"
    echo "metadata / small blocks). Log (SLOG) + L2ARC stay on the 4 smallest unused NVMe."
    echo "A special vdev is not optional on this hardware class if enough NVMe exist —"
    echo "without it, metadata lives on HDD and directory-heavy workloads suffer."
    echo

    echo "--- Existing ZFS pools ---"
    if command -v zpool >/dev/null 2>&1 && mapfile -t pools < <(zpool list -H -o name 2>/dev/null); then
      if ((${#pools[@]} == 0)) || [[ -z "${pools[0]:-}" ]]; then
        echo "  (none)"
      else
        zpool list 2>/dev/null || true
        echo
        for p in "${pools[@]}"; do
          [[ -z "$p" ]] && continue
          printf '  %s:' "$p"
          assess_zpool_has_section "$p" special && printf ' special' || printf ' no-special'
          assess_zpool_has_section "$p" logs && printf ' logs' || printf ' no-logs'
          assess_zpool_has_section "$p" cache && printf ' cache' || printf ' no-cache'
          echo
        done
      fi
    else
      echo "  (zpool not available)"
    fi
    echo

    echo "--- Multipath / HDD inventory ---"
    if ! command -v multipath >/dev/null 2>&1; then
      echo "  (multipath not in PATH — HDD/JBOD discovery skipped)"
    else
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ dm-[0-9]+ ]] || continue
        [[ "$line" =~ ^[[:space:]] ]] && continue
        wwid=$(assess_extract_wwid "$line")
        [[ -n "$wwid" ]] || continue
        vendor="UNKNOWN"
        product="UNKNOWN"
        if [[ "$line" =~ dm-[0-9]+[[:space:]]+([^,[:space:]]+),([^[:space:]]+) ]]; then
          vendor="${BASH_REMATCH[1]}"
          product="${BASH_REMATCH[2]}"
        fi
        path=$(resolve_mpath_device "$wwid" 2>/dev/null || true)
        sz=0
        status="unresolved"
        if [[ -n "$path" ]]; then
          sz=$(blockdev --getsize64 "$path" 2>/dev/null || echo 0)
          status=$(assess_block_status "$path")
        fi
        mpath_rows+=("${vendor}|${product}|${sz}|${wwid}|${path}|${status}")
        key="${vendor}|${sz}"
        grp_vendor["$key"]="$vendor"
        grp_product["$key"]="$product"
        grp_size["$key"]="$sz"
        grp_count["$key"]=$((${grp_count[$key]:-0} + 1))
        if [[ "$status" == unused ]]; then
          grp_unused["$key"]=$((${grp_unused[$key]:-0} + 1))
        fi
      done < <(multipath -l 2>/dev/null || true)

      if ((${#mpath_rows[@]} == 0)); then
        echo "  (no multipath maps found)"
      else
        printf '  %-10s %-18s %10s %5s %6s  notes\n' "VENDOR" "PRODUCT" "SIZE" "TOTAL" "FREE"
        while IFS= read -r key; do
          [[ -z "$key" ]] && continue
          if (( ${grp_unused[$key]:-0} == ${grp_count[$key]} )); then
            status="unused"
          else
            status="some in use / in pool"
          fi
          printf '  %-10s %-18s %10s %5d %6d  %s\n' \
            "${grp_vendor[$key]}" \
            "${grp_product[$key]}" \
            "$(human_bytes "${grp_size[$key]}")" \
            "${grp_count[$key]}" \
            "${grp_unused[$key]:-0}" \
            "$status"
        done < <(printf '%s\n' "${!grp_count[@]}" | sort)
      fi
    fi
    echo

    echo "--- NVMe inventory ---"
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      sz=$(blockdev --getsize64 "$path" 2>/dev/null || echo 0)
      status=$(assess_block_status "$path")
      nvme_rows+=("${sz}|${path}|$(assess_nvme_model "$path")|${status}|$(assess_nvme_vendor_pattern "$path")")
      if [[ "$status" == unused ]]; then
        unused_nvme+=("${sz} ${path}")
        nvme_sz_unused["$sz"]=$((${nvme_sz_unused[$sz]:-0} + 1))
        unused_nvme_n=$((unused_nvme_n + 1))
      fi
    done < <(pick_all_nvme_by_id_paths | sort)

    if ((${#nvme_rows[@]} == 0)); then
      echo "  (no whole-disk NVMe by-id paths found)"
    else
      echo "  Unused:"
      printed_unused=0
      for row in "${nvme_rows[@]}"; do
        IFS='|' read -r sz path model status vpat <<<"$row"
        [[ "$status" == unused ]] || continue
        printf '    %10s  %s  (%s)\n' "$(human_bytes "$sz")" "$path" "$model"
        printed_unused=1
      done
      (( printed_unused == 1 )) || echo "    (none)"
      echo "  In use:"
      printed_used=0
      for row in "${nvme_rows[@]}"; do
        IFS='|' read -r sz path model status vpat <<<"$row"
        [[ "$status" == unused ]] && continue
        printf '    %10s  %s  [%s]  (%s)\n' "$(human_bytes "$sz")" "$path" "$status" "$model"
        printed_used=1
      done
      (( printed_used == 1 )) || echo "    (none)"
    fi
    echo

    if ((${#nvme_sz_unused[@]} > 0)); then
      small_sz=$(printf '%s\n' "${!nvme_sz_unused[@]}" | sort -n | head -n1)
      large_sz=$(printf '%s\n' "${!nvme_sz_unused[@]}" | sort -n | tail -n1)
      small_n=${nvme_sz_unused[$small_sz]:-0}
      large_n=${nvme_sz_unused[$large_sz]:-0}
    fi

    # After 4 smallest for log+cache, remaining largest-tier disks for special.
    if (( unused_nvme_n >= 4 )); then
      if (( large_sz != small_sz )); then
        special_fit=$large_n
        if (( small_n < 4 )); then
          special_fit=$((unused_nvme_n - 4))
        fi
      else
        special_fit=$((unused_nvme_n - 4))
      fi
    else
      special_fit=0
    fi

    assess_print_special_feasibility "$unused_nvme_n" "$special_fit" "$small_n" "$large_n" "$large_sz"

    echo "======== RECOMMENDED DEPLOYMENTS (special vdev first) ========"
    echo "Commands below are copy/paste. Dry-run first, then drop DRY_RUN=1 to create."
    if (( SPECIAL_ENABLED )); then
      echo "Note: special layout '${SPECIAL_LAYOUT}' was requested on the CLI; recommended remains the"
      echo "      highest-ranked special vdev that fits, with your layout listed among the alternatives."
    fi
    echo

    have_hdd_option=0
    hdd_unused_keys=()
    if ((${#grp_unused[@]} > 0)); then
      mapfile -t hdd_unused_keys < <(printf '%s\n' "${!grp_unused[@]}" | sort)
    fi
    for key in ${hdd_unused_keys[@]+"${hdd_unused_keys[@]}"}; do
      ndisks=${grp_unused[$key]:-0}
      (( ndisks >= 8 )) || continue
      vendor=${grp_vendor[$key]}
      disk_b=${grp_size[$key]}
      width=$(assess_pick_width "$ndisks")
      if (( ndisks % width != 0 )); then
        ndisks=$((ndisks - ndisks % width))
      fi
      (( ndisks >= width && width >= 8 )) || continue
      have_hdd_option=1

      best_layout=""
      for layout in "${layout_order[@]}"; do
        nvme_n=$(special_layout_nvme_total "$layout") || continue
        if (( nvme_n <= special_fit )); then
          best_layout=$layout
          break
        fi
      done

      # dRAID3 + each fitting special layout (recommended first)
      spec=$(compute_best_draid_spec "$width" 3 balanced 2>/dev/null || true)
      if [[ -n "$spec" && -n "$best_layout" ]]; then
        assess_print_create_option \
          "RECOMMENDED — dRAID3 + special ${best_layout}" \
          3 "$width" "$ndisks" "$vendor" "$best_layout" "$disk_b" "$spec" "${large_sz:-0}"
        for layout in "${layout_order[@]}"; do
          [[ "$layout" == "$best_layout" ]] && continue
          nvme_n=$(special_layout_nvme_total "$layout") || continue
          (( nvme_n <= special_fit )) || continue
          case "$layout" in
            raidz2x10 | raidz3x20 | raidz2-18+2spare)
              assess_print_create_option \
                "ALTERNATIVE (capacity special, not preferred) — dRAID3 + ${layout}" \
                3 "$width" "$ndisks" "$vendor" "$layout" "$disk_b" "$spec" "${large_sz:-0}"
              ;;
            *)
              assess_print_create_option \
                "ALTERNATIVE — dRAID3 + special ${layout}" \
                3 "$width" "$ndisks" "$vendor" "$layout" "$disk_b" "$spec" "${large_sz:-0}"
              ;;
          esac
        done
      elif [[ -n "$spec" ]]; then
        echo "No special vdev layout fits this host. dRAID3 without special is listed last."
        echo
      fi

      spec=$(compute_best_draid_spec "$width" 2 balanced 2>/dev/null || true)
      if [[ -n "$spec" && -n "$best_layout" ]]; then
        assess_print_create_option \
          "ALTERNATIVE — dRAID2 + special ${best_layout} (more capacity, less parity)" \
          2 "$width" "$ndisks" "$vendor" "$best_layout" "$disk_b" "$spec" "${large_sz:-0}"
      fi
    done

    # NVMe-as-data only when there is no HDD group, or a large unused NVMe cohort exists
    # beyond log+special (typical front-bay 20× large + 4× small all-flash node).
    nvme_data_n=0
    nvme_pat="NVME"
    if (( large_n >= 8 )) && (( have_hdd_option == 0 )); then
      nvme_data_n=$large_n
      for row in "${nvme_rows[@]}"; do
        IFS='|' read -r sz path model status vpat <<<"$row"
        if [[ "$status" == unused && "$sz" == "$large_sz" ]]; then
          nvme_pat=$vpat
          break
        fi
      done
      spec=$(compute_best_draid_spec "$nvme_data_n" 3 balanced 2>/dev/null || true)
      ((++ASSESS_RANK))
      echo "[${ASSESS_RANK}] ALL-FLASH — NVMe dRAID data (special vdev NOT available: same NVMe are the data disks)"
      echo "    Data:     ${nvme_data_n}× $(human_bytes "$large_sz")  →  1 × ${spec:-draid3}"
      echo "    Aux:      4 remaining smaller/other NVMe → log + cache"
      echo "    Special:  not supported with DATA_DISK_SOURCE=nvme"
      echo "    Create:   POOL=${POOL} DATA_DISK_SOURCE=nvme ${ASSESS_SELF} ${nvme_pat} ${nvme_data_n}"
      echo "    Dry-run:  POOL=${POOL} DATA_DISK_SOURCE=nvme DRY_RUN=1 ${ASSESS_SELF} ${nvme_pat} ${nvme_data_n}"
      echo
    fi

    # No-special HDD options only when a special vdev cannot be formed
    if (( special_fit == 0 )); then
      for key in ${hdd_unused_keys[@]+"${hdd_unused_keys[@]}"}; do
        ndisks=${grp_unused[$key]:-0}
        (( ndisks >= 8 )) || continue
        vendor=${grp_vendor[$key]}
        disk_b=${grp_size[$key]}
        width=$(assess_pick_width "$ndisks")
        if (( ndisks % width != 0 )); then
          ndisks=$((ndisks - ndisks % width))
        fi
        (( ndisks >= width && width >= 8 )) || continue
        spec=$(compute_best_draid_spec "$width" 3 balanced 2>/dev/null || true)
        [[ -n "$spec" ]] || continue
        assess_print_create_option \
          "LAST RESORT — dRAID3 WITHOUT special vdev (metadata on HDD)" \
          3 "$width" "$ndisks" "$vendor" "" "$disk_b" "$spec" 0
      done
    fi

    if (( ASSESS_RANK == 0 )); then
      echo "No deployable dRAID combination found."
      echo "  Need unused multipath HDDs (typically 26/52/78) and/or unused NVMe."
      echo "  Run this script on the storage server (RHEL + multipath + NVMe)."
      echo
    fi

    echo "--- Existing pool enhancement (no recreate; special vdev add) ---"
    enhanced=0
    if ((${#pools[@]} > 0)) && [[ -n "${pools[0]:-}" ]] && (( unused_nvme_n >= 10 )); then
      nv_sorted=()
      spec_paths=()
      mapfile -t nv_sorted < <(printf '%s\n' "${unused_nvme[@]+"${unused_nvme[@]}"}" | sort -k1,1nr)
      for p in "${pools[@]}"; do
        [[ -z "$p" ]] && continue
        if assess_zpool_has_section "$p" special; then
          echo "  Pool '${p}' already has a special vdev."
          continue
        fi
        add_layout=""
        add_n=0
        for layout in "${layout_order[@]}"; do
          add_n=$(special_layout_special_disk_count "$layout") || continue
          spare_n=$(special_layout_pool_spare_count "$layout") || continue
          if (( add_n + spare_n <= unused_nvme_n )); then
            add_layout=$layout
            break
          fi
        done
        if [[ -z "$add_layout" ]]; then
          continue
        fi
        add_n=$(special_layout_special_disk_count "$add_layout")
        spec_paths=()
        for ((i = 0; i < add_n && i < ${#nv_sorted[@]}; i++)); do
          read -r row_sz row_path <<<"${nv_sorted[i]}"
          spec_paths+=("$row_path")
        done
        ((++ASSESS_RANK))
        enhanced=1
        echo "  Pool '${p}' has no special vdev — ${add_layout} fits on unused NVMe."
        echo "  WARNING: adding special is pool-critical (loss of special = loss of pool)."
        _zpool_cmd=(zpool add "$p")
        if append_special_vdev_to_zpool_cmd "$add_layout" "${spec_paths[@]}" 2>/dev/null; then
          echo "  Dry-run add:"
          echo "    zpool add -n ${p} special ...   # preview, then:"
          printf '    '
          format_shell_quoted_cmd "${_zpool_cmd[@]}"
        fi
        if ! assess_zpool_has_section "$p" logs && (( unused_nvme_n >= add_n + 4 )); then
          echo "  Pool has no SLOG — after special add, 4 leftover smaller NVMe can become log+cache:"
          echo "    zpool add ${p} log mirror <nvme-a> <nvme-b>"
          echo "    zpool add ${p} cache <nvme-c> <nvme-d>"
        fi
        echo
      done
    fi
    if (( enhanced == 0 )); then
      echo "  No existing pool is missing a special vdev with enough unused NVMe to add one."
      echo "  (Requires an imported pool without special, plus ≥10 unused NVMe for mirror5.)"
      echo
    fi

    echo "--- Notes ---"
    echo "  After create, enable small blocks per dataset only when measured, e.g.:"
    echo "    zfs set special_small_blocks=16K ${POOL}/dataset"
    echo "  Layout details: ${ASSESS_SELF} --help-special"
    echo "=============================================================="
  } | tee "$logf"

  echo
  echo "Assessment log: $logf"
}

# --- Build HDD list ---
if [[ "$ASSESS_ONLY" == "1" ]]; then
  run_storage_assessment
  exit 0
fi

# shellcheck disable=SC2086,SC2046
apply_multipath_user_friendly_names_off

ALL_HDD_PATHS=()

if [[ "$DATA_DISK_SOURCE" == nvme ]]; then
  discover_nvme_data_and_four_aux
else
  mapfile -t _WWIDS < <(collect_multipath_wwids_all | eval "$MPATH_SORT_CMD")
  if (( ${#_WWIDS[@]} < TOTAL_DISKS )); then
    echo "Error: multipath matched ${#_WWIDS[@]} disk(s) for pattern '${DISK_PATTERN}', need ${TOTAL_DISKS}." >&2
    exit 1
  fi

  if (( ${#_WWIDS[@]} > TOTAL_DISKS )); then
    echo "Note: using first ${TOTAL_DISKS} of ${#_WWIDS[@]} matched disks (sorted unique WWID)." >&2
    _WWIDS=("${_WWIDS[@]:0:TOTAL_DISKS}")
  fi

  local_wwid=
  for local_wwid in "${_WWIDS[@]}"; do
    ALL_HDD_PATHS+=("$(resolve_mpath_device "$local_wwid")")
  done

  discover_four_nvme_log_and_cache
fi

# Split into vdevs of DISKS_PER_VDEV
VDEV_DISKS_ARRAYS=()
local_i=0
local_v=0
local_chunk=()
for local_i in "${!ALL_HDD_PATHS[@]}"; do
  local_chunk+=("${ALL_HDD_PATHS[$local_i]}")
  if (( ${#local_chunk[@]} == DISKS_PER_VDEV )); then
    VDEV_DISKS_ARRAYS+=("${local_chunk[*]}")
    local_chunk=()
    ((++local_v))
  fi
done

if (( local_v != NUM_VDEVS )); then
  echo "Error: internal split mismatch (expected ${NUM_VDEVS} vdevs, got ${local_v})." >&2
  exit 1
fi

if [[ -n "${DRAID_VDEV_SPEC}" ]]; then
  ONE_DRAID_SPEC="$DRAID_VDEV_SPEC"
else
  ONE_DRAID_SPEC=$(compute_best_draid_spec "$DISKS_PER_VDEV" "$DRAID_PARITY" "$DRAID_PROFILE") || exit 1
fi

_zpool_cmd=(zpool create "$POOL"
  -o ashift=12
  -o autoexpand=on
  -o autoreplace=on
  -O acltype=posixacl
  -O xattr=sa
  -O compression=lz4
  -O dedup=off
)

local_vdev_idx=0
for local_vdev_idx in "${!VDEV_DISKS_ARRAYS[@]}"; do
  # shellcheck disable=SC2206
  local_vdev_paths=(${VDEV_DISKS_ARRAYS[$local_vdev_idx]})
  if ((${#local_vdev_paths[@]} != DISKS_PER_VDEV)); then
    echo "Error: vdev $((local_vdev_idx + 1)) has ${#local_vdev_paths[@]} disks, expected ${DISKS_PER_VDEV}." >&2
    exit 1
  fi
  _zpool_cmd+=("$ONE_DRAID_SPEC" "${local_vdev_paths[@]}")
done

_zpool_cmd+=(log mirror "${NVME_LOG[@]}")
_zpool_cmd+=(cache "${NVME_CACHE[@]}")

if (( SPECIAL_ENABLED )); then
  append_special_vdev_to_zpool_cmd "$SPECIAL_LAYOUT" "${NVME_SPECIAL[@]}" || exit 1
fi
if ((${#NVME_POOL_SPARE[@]} > 0)); then
  _zpool_cmd+=(spare "${NVME_POOL_SPARE[@]}")
fi

POOL_SETUP_LOG="${POOL_SETUP_LOG:-/tmp/zfs-orcd-${POOL}-$(date +%Y%m%d-%H%M%S).log}"
if ! : >"$POOL_SETUP_LOG" 2>/dev/null; then
  POOL_SETUP_LOG="/tmp/zfs-orcd-${POOL}-pool.log"
  : >"$POOL_SETUP_LOG" || {
    echo "Error: cannot write log under /tmp." >&2
    exit 1
  }
fi
write_pool_setup_log_preamble "$POOL_SETUP_LOG" "$0" "$@"

print_visual_pool_layout
echo
echo "Log file:          $POOL_SETUP_LOG"
echo "--- zpool create (shell-quoted, copy/paste) ---"
format_shell_quoted_cmd "${_zpool_cmd[@]}"
echo "--------------------------------------------"

if [[ "$DRY_RUN" == "1" ]]; then
  {
    echo
    echo "DRY_RUN=1 — zpool create was NOT executed."
  } | tee -a "$POOL_SETUP_LOG"
  echo "DRY_RUN=1 — not creating pool."
  exit 0
fi

prompt_confirm_zpool_create

{
  echo "Confirmed: zpool create will run at $(date -Is 2>/dev/null || date)"
  if [[ "${SKIP_CONFIRM:-0}" == "1" ]]; then
    echo "(SKIP_CONFIRM=1 was set)"
  fi
  echo
  echo "=== zpool create stdout/stderr: $(date -Is 2>/dev/null || date) ==="
} >>"$POOL_SETUP_LOG"

echo "Creating pool $POOL with ${ONE_DRAID_SPEC} + log + cache${SPECIAL_ENABLED:+ + special ${SPECIAL_LAYOUT}}${NVME_POOL_SPARE[0]:+ + ${#NVME_POOL_SPARE[@]} hot spare(s)} + optimization flags..."

if "${_zpool_cmd[@]}" 2>&1 | tee -a "$POOL_SETUP_LOG"; then
  echo "------------------------------------------------"
  echo "Pool '$POOL' created successfully."
  echo "Full session log: $POOL_SETUP_LOG"
  echo "------------------------------------------------"
  zpool status "$POOL"
  echo "------------------------------------------------"
  zfs get compression,atime,xattr,acltype,dedup "$POOL"
  append_post_create_to_log "$POOL_SETUP_LOG"
else
  echo "Pool creation failed (see log: $POOL_SETUP_LOG)." >&2
  exit 1
fi

{
  echo
  echo "=== zfs dataset / follow-up: $(date -Is 2>/dev/null || date) ==="
} >>"$POOL_SETUP_LOG"

_orcd_key="/etc/zfs/keys/${POOL}.key"
_orcd_dest="hstor001:/data2/backup/systems/001/$(hostname)/"
if [[ -f "$_orcd_key" ]]; then
  zfs create -o encryption=aes-256-gcm -o "keylocation=file://${_orcd_key}" -o keyformat=hex "${POOL}/orcd" 2>&1 | tee -a "$POOL_SETUP_LOG" || echo "Warning: encrypted ${POOL}/orcd create failed." | tee -a "$POOL_SETUP_LOG"
  zfs set quota=20T "${POOL}/orcd" 2>&1 | tee -a "$POOL_SETUP_LOG" || true
  zfs get encryption "${POOL}/orcd" 2>&1 | tee -a "$POOL_SETUP_LOG" || true
else
  echo "Skipping encrypted ${POOL}/orcd: missing ${_orcd_key}" | tee -a "$POOL_SETUP_LOG"
fi

zfs list 2>&1 | tee -a "$POOL_SETUP_LOG" || true

systemctl enable "zfs-scrub-monthly@${POOL}.timer" --now 2>&1 | tee -a "$POOL_SETUP_LOG" || echo "Warning: could not enable zfs-scrub-monthly@${POOL}.timer" | tee -a "$POOL_SETUP_LOG"

if command -v rsync >/dev/null 2>&1; then
  if [[ -f "/root/${POOL}.sh" ]]; then
    rsync -av "/root/${POOL}.sh" "$_orcd_dest" 2>&1 | tee -a "$POOL_SETUP_LOG" || echo "Warning: rsync of /root/${POOL}.sh failed." | tee -a "$POOL_SETUP_LOG"
  elif [[ -f "$SCRIPT_PATH" ]]; then
    rsync -av "$SCRIPT_PATH" "$_orcd_dest" 2>&1 | tee -a "$POOL_SETUP_LOG" || echo "Warning: rsync of script failed." | tee -a "$POOL_SETUP_LOG"
  fi
  if [[ -f "$_orcd_key" ]]; then
    rsync -av "$_orcd_key" "$_orcd_dest" 2>&1 | tee -a "$POOL_SETUP_LOG" || echo "Warning: rsync of pool key failed." | tee -a "$POOL_SETUP_LOG"
  fi
fi
unset _orcd_key _orcd_dest
