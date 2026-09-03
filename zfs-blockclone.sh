#!/usr/bin/env bash
# zfs-blockclone.sh
#
# Move a dataset onto a newly provisioned ZFS pool, then optionally make extra
# working copies for lab tests (NFS/client I/O, scrub, resilver).
#
# IMPORTANT
#   OpenZFS block cloning (BRT / copy_file_range) cannot copy between servers
#   or between pools. Server-to-server migration is zfs send|recv or an NFS
#   rsync. Block cloning only makes extra copies ON THE DESTINATION POOL.
#
#   zfs send|recv and rsync both write unique blocks on the new pool — that is
#   the right seed for scrub/resilver timing. clone-tree afterwards shares
#   those blocks (USED stays small); it does not add resilver work. Use
#   copy-tree when you want a second unique copy that fills capacity.
#
# Typical flow on the NEW server (pool already created, e.g. via zfs-draid.sh):
#   1. zfs-blockclone.sh check --pool data1
#   2. Seed (pick one):
#        send pull:  zfs-blockclone.sh seed --src root@OLD:data1/proj --dst data1/lab/gold/proj
#        NFS rsync:  zfs-blockclone.sh seed --mode rsync --src /mnt/old/proj --dst data1/lab/gold/proj
#        send push:  (run on OLD) seed --src data1/proj --dst root@NEW:data1/lab/gold/proj
#   3. Unique working copy for scrub/resilver:
#        zfs-blockclone.sh prep-dst data1/lab/work/proj --like data1/lab/gold/proj
#        zfs-blockclone.sh copy-tree data1/lab/gold/proj data1/lab/work/proj
#   4. Optional cheap extra namespace (shared blocks):
#        zfs-blockclone.sh clone-tree data1/lab/gold/proj data1/lab/clone/proj
#   5. zfs-blockclone.sh verify data1/lab/gold/proj data1/lab/work/proj --sample 50
#   6. zfs-blockclone.sh stats data1
#
# Requires: bash 4+, zfs, python3. Optional: mbuffer, pv, rsync, sha256sum.
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
SSH_OPTS=(-q -o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR)

LOG_TS() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()  { printf '%s [%s] %s\n' "$(LOG_TS)" "$1" "${*:2}" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@"; }
die()  { err "$@"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

pybin() { echo "${ZFS_BCLONE_PYTHON:-python3}"; }

pool_of() {
  echo "${1%%/*}"
}

ds_mountpoint() {
  zfs get -H -o value mountpoint "$1"
}

ds_exists() {
  zfs list -H -o name "$1" >/dev/null 2>&1
}

ensure_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
}

# ZFS names: leading alnum, then alnum / _ / . / - / : / @ (snap) / /
valid_zfs_name() {
  local what=$1 name=$2
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.:@/-]*$ ]] || die "invalid $what name: $name"
}

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME <command> [options]

Commands:
  check [--pool POOL] [--ssh USER@HOST]
      Verify feature@block_cloning, module knobs, tools, and optional SSH.

  ssh-help
      Print passwordless SSH setup for send pull (NEW→OLD) and push (OLD→NEW).

  seed --src [USER@HOST:]DATASET --dst [USER@HOST:]DATASET
      [--mode send|rsync] [--snap NAME] [--raw] [--recursive]
      [--compressed|--no-compressed] [--properties|--no-properties]
      [--resume|--no-resume] [--force] [--mbuffer SIZE|0] [--dry-run]
      send (default): snapshot + zfs send | recv. Pull (remote --src, run on
      NEW) needs SSH NEW→OLD. Push (remote --dst, run on OLD) needs SSH OLD→NEW.
      rsync: copy files from a local path (NFS mount) into a local dataset.
      No SSH. Writes unique blocks — preferred for scrub/resilver load.

  prep-dst DATASET --like SRC_DATASET
      Create destination inheriting recordsize/compression/checksum/dnodesize.

  copy-tree SRC_DATASET DST_DATASET [--jobs N]
      Full file copy (cp --reflink=never). Unique blocks; used ≈ refer.
      Use this to grow allocated space for scrub/resilver tests.

  clone-tree SRC_DATASET DST_DATASET
      [--jobs N] [--sync|--no-sync] [--fallback copy|fail]
      Walk files and clone via copy_file_range (same pool only).
      Shared blocks: DST used << refer. Does not add resilver work.

  clone-file SRC_PATH DST_PATH
      Clone a single file with copy_file_range.

  snapshot-clone SRC_DATASET DST_DATASET
      Dataset-level zfs clone via snapshot (not BRT). Same-pool only.

  verify SRC_DATASET DST_DATASET [--sample N]
      Compare file counts, sizes, and checksums (sample or all).

  stats [POOL]
      BRT-related pool props, used vs refer, kstats if present.

  bench-copy SRC_DATASET DST_PARENT
      Time block-clone tree vs full copy vs snapshot-clone.

Environment:
  ZFS_BCLONE_PYTHON   python3 binary (default: python3)
  ZFS_RECV_OPTS       extra zfs recv options (send mode)
  ZFS_SSH_OPTS        extra ssh options, appended to BatchMode/ConnectTimeout
EOF
}

ssh_help_text() {
  cat <<'EOF'
Passwordless SSH is required only for:  seed --mode send  with a remote host.

NFS rsync needs no SSH:
  # on NEW, after mounting the old export
  mount -t nfs OLD:/export/proj /mnt/old-proj
  ./zfs-blockclone.sh seed --mode rsync --src /mnt/old-proj --dst data1/lab/gold/proj

-------------------------------------------------------------------------------
PULL (recommended) — run this script on the NEW server
  SSH direction: NEW → OLD   (destination logs into source and pulls zfs send)

  # on NEW as root, once
  [[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
  ssh-copy-id -i /root/.ssh/id_ed25519.pub root@OLD
  ssh -o BatchMode=yes root@OLD 'hostname; zfs list -H -o name | head'

  ./zfs-blockclone.sh check --pool data1 --ssh root@OLD
  ./zfs-blockclone.sh seed --src root@OLD:data1/proj --dst data1/lab/gold/proj

-------------------------------------------------------------------------------
PUSH — run this script on the OLD server
  SSH direction: OLD → NEW   (source pushes zfs send into zfs recv)

  # on OLD as root, once
  [[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
  ssh-copy-id -i /root/.ssh/id_ed25519.pub root@NEW
  ssh -o BatchMode=yes root@NEW 'hostname; zfs list -H -o name | head'

  ./zfs-blockclone.sh seed --src data1/proj --dst root@NEW:data1/lab/gold/proj

Root (or a user allowed to zfs send / zfs recv) is required on both sides.
BatchMode=yes is used so a missing key fails immediately instead of hanging
on a password prompt. If host keys are not yet in known_hosts:

  ssh-keyscan -H OLD >> /root/.ssh/known_hosts
EOF
}

# Split USER@HOST:DATASET (or path) into host + rest.
# Rest may be a dataset (send) or a filesystem path (rsync).
# IPv6 is not supported; hostnames/IPv4 only.
parse_endpoint() {
  local spec=$1
  _ep_host=""
  _ep_rest=$spec
  if [[ $spec == *:* && $spec != /* && $spec != ./* ]]; then
    _ep_host=${spec%%:*}
    _ep_rest=${spec#*:}
  fi
}

# Sets _ssh to: ssh <opts> USER@HOST
ssh_prefix() {
  local host=$1
  _ssh=(ssh "${SSH_OPTS[@]}")
  if [[ -n ${ZFS_SSH_OPTS:-} ]]; then
    # shellcheck disable=SC2206
    _ssh+=(${ZFS_SSH_OPTS})
  fi
  _ssh+=("$host")
}

remote_or_local() {
  # $1 = host or empty, remaining args run locally or via ssh
  local host=$1
  shift
  if [[ -n $host ]]; then
    ssh_prefix "$host"
    "${_ssh[@]}" "$@"
  else
    "$@"
  fi
}

ensure_mounted() {
  local ds=$1
  local mp
  mp=$(ds_mountpoint "$ds")
  if [[ $mp == none || $mp == legacy ]]; then
    info "setting mountpoint=/$ds on $ds (was $mp)"
    zfs set "mountpoint=/$ds" "$ds"
  fi
  local cm
  cm=$(zfs get -H -o value canmount "$ds")
  if [[ $cm != on ]]; then
    zfs set canmount=on "$ds"
  fi
  zfs mount "$ds" 2>/dev/null || true
  mp=$(ds_mountpoint "$ds")
  [[ -d $mp ]] || die "dataset not mounted: $ds (mountpoint=$mp)"
  printf '%s\n' "$mp"
}

replicate_dirs_and_links() {
  local src_mp=$1 dst_mp=$2
  local d rel l
  while IFS= read -r -d '' d; do
    rel=${d#"$src_mp"/}
    [[ $d == "$src_mp" ]] && continue
    mkdir -p "$dst_mp/$rel"
    if have_cmd chmod; then
      chmod --reference="$d" "$dst_mp/$rel" 2>/dev/null || true
    fi
  done < <(find "$src_mp" -xdev -type d -print0)

  while IFS= read -r -d '' l; do
    rel=${l#"$src_mp"/}
    mkdir -p "$(dirname "$dst_mp/$rel")"
    ln -sfn "$(readlink "$l")" "$dst_mp/$rel"
  done < <(find "$src_mp" -xdev -type l -print0)
}

cmd_check() {
  local pool="" ssh_target=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --pool|-o) pool=$2; shift 2 ;;
      --ssh) ssh_target=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown check option: $1" ;;
    esac
  done

  need_cmd zfs
  need_cmd zpool
  need_cmd "$(pybin)"

  info "OpenZFS tools:"
  zfs version 2>/dev/null || zpool version 2>/dev/null || true

  local knobs=(
    /sys/module/zfs/parameters/zfs_bclone_enabled
    /sys/module/zfs/parameters/zfs_bclone_wait_dirty
    /sys/module/zfs/parameters/zfs_dio_enabled
  )
  local k
  for k in "${knobs[@]}"; do
    if [[ -r $k ]]; then
      info "$(basename "$k")=$(<"$k")  ($k)"
    else
      warn "knob not present: $k"
    fi
  done

  if [[ -r /sys/module/zfs/parameters/zfs_bclone_enabled ]]; then
    local en
    en=$(</sys/module/zfs/parameters/zfs_bclone_enabled)
    if [[ $en != 1 ]]; then
      warn "zfs_bclone_enabled=$en — cloning will fall back to real copies"
      warn "enable with: echo 1 > /sys/module/zfs/parameters/zfs_bclone_enabled"
    fi
  fi

  "$(pybin)" - <<'PY'
import os, sys
ok = hasattr(os, "copy_file_range")
print("python copy_file_range:", ok)
sys.exit(0 if ok else 1)
PY

  if [[ -n $pool ]]; then
    ds_exists "$pool" || die "pool/dataset not found: $pool"
    zpool get feature@block_cloning,feature@block_cloning_endian,feature@allocation_classes,feature@draid,feature@large_blocks "$pool" || true
    local st
    st=$(zpool get -H -o value feature@block_cloning "$pool")
    info "feature@block_cloning=$st"
    [[ $st == enabled || $st == active ]] || warn "enable with: zpool set feature@block_cloning=enabled $pool"
  fi

  have_cmd mbuffer && info "mbuffer: present" || warn "mbuffer: not installed (optional for seed)"
  have_cmd pv && info "pv: present" || warn "pv: not installed (optional progress)"
  have_cmd rsync && info "rsync: present" || warn "rsync: not installed (required for --mode rsync)"

  if [[ -n $ssh_target ]]; then
    info "SSH BatchMode check: $ssh_target"
    ssh_prefix "$ssh_target"
    "${_ssh[@]}" 'hostname; id -un; zfs version 2>/dev/null | head -1; zfs list -H -o name | head'
    info "SSH OK: $ssh_target"
  fi
}

cmd_ssh_help() {
  ssh_help_text
}

cmd_seed() {
  local src="" dst="" snap="" mode=send
  local raw=0 compressed=1 props=1 resume=1 recursive=0 force=0 dry=0
  local mbuf="1G"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --src) src=$2; shift 2 ;;
      --dst) dst=$2; shift 2 ;;
      --snap) snap=$2; shift 2 ;;
      --mode) mode=$2; shift 2 ;;
      --raw) raw=1; shift ;;
      --recursive|-R) recursive=1; shift ;;
      --no-recursive) recursive=0; shift ;;
      --compressed) compressed=1; shift ;;
      --no-compressed) compressed=0; shift ;;
      --properties) props=1; shift ;;
      --no-properties) props=0; shift ;;
      --resume) resume=1; shift ;;
      --no-resume) resume=0; shift ;;
      --force) force=1; shift ;;
      --mbuffer) mbuf=$2; shift 2 ;;
      --dry-run) dry=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown seed option: $1" ;;
    esac
  done
  [[ -n $src && -n $dst ]] || die "seed requires --src and --dst"
  [[ $mode == send || $mode == rsync ]] || die "--mode must be send or rsync"
  [[ $dry -eq 1 ]] || ensure_root

  if [[ $mode == rsync ]]; then
    seed_rsync "$src" "$dst" "$dry"
    return
  fi

  parse_endpoint "$src"; local src_host=$_ep_host src_ds=$_ep_rest
  parse_endpoint "$dst"; local dst_host=$_ep_host dst_ds=$_ep_rest
  valid_zfs_name dataset "$src_ds"
  valid_zfs_name dataset "$dst_ds"
  if [[ -n $src_host && -n $dst_host ]]; then
    die "seed --mode send: only one of --src or --dst may be remote (pull vs push)"
  fi

  if [[ -z $snap ]]; then
    snap="lab-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  valid_zfs_name snapshot "$snap"

  if [[ $dry -eq 1 ]]; then
    local sf=()
    if [[ $raw -eq 1 ]]; then
      sf=(-w)
      [[ $recursive -eq 1 ]] && sf+=(-R)
    else
      sf=(-L -e)
      [[ $compressed -eq 1 ]] && sf+=(-c)
      [[ $props -eq 1 ]] && sf+=(-p)
      [[ $recursive -eq 1 ]] && sf+=(-R)
    fi
    if [[ $recursive -eq 1 ]]; then
      info "dry-run snapshot: zfs snapshot -r ${src_ds}@${snap}${src_host:+  (on $src_host)}"
    else
      info "dry-run snapshot: zfs snapshot ${src_ds}@${snap}${src_host:+  (on $src_host)}"
    fi
    info "dry-run send: zfs send ${sf[*]} ${src_ds}@${snap}${src_host:+  (via ssh $src_host)}"
    info "dry-run recv: zfs recv -u -s ${dst_ds}${dst_host:+  (via ssh $dst_host)}"
    if [[ -n $src_host ]]; then
      info "SSH needed: NEW→OLD pull ($src_host) — see $SCRIPT_NAME ssh-help"
    elif [[ -n $dst_host ]]; then
      info "SSH needed: OLD→NEW push ($dst_host) — see $SCRIPT_NAME ssh-help"
    else
      info "SSH needed: none (local send|recv)"
    fi
    return
  fi

  need_cmd zfs

  local token=""
  if [[ $resume -eq 1 ]]; then
    token=$(remote_or_local "$dst_host" zfs get -H -o value receive_resume_token "$dst_ds" 2>/dev/null || true)
    [[ $token == "-" ]] && token=""
  fi

  if [[ -z $token ]]; then
    if remote_or_local "$dst_host" zfs list -H -o name "$dst_ds" >/dev/null 2>&1; then
      if [[ $force -eq 1 ]]; then
        warn "destination exists: $dst_ds — recv will use -F"
      else
        die "destination exists: $dst_ds (interrupted recv: omit --no-resume; overwrite: --force)"
      fi
    fi
  fi

  local send_flags=() recv_flags=(-u)
  if [[ -n $token ]]; then
    send_flags=(-t "$token")
    info "resuming interrupted recv using receive_resume_token"
  else
    if [[ $raw -eq 1 ]]; then
      send_flags=(-w)
      [[ $recursive -eq 1 ]] && send_flags+=(-R)
    else
      send_flags=(-L -e)
      [[ $compressed -eq 1 ]] && send_flags+=(-c)
      [[ $props -eq 1 ]] && send_flags+=(-p)
      [[ $recursive -eq 1 ]] && send_flags+=(-R)
    fi
    info "creating snapshot ${src_host:+on $src_host: }${src_ds}@${snap}"
    if ! remote_or_local "$src_host" zfs list -H -o name "${src_ds}@${snap}" >/dev/null 2>&1; then
      if [[ $recursive -eq 1 ]]; then
        remote_or_local "$src_host" zfs snapshot -r "${src_ds}@${snap}"
      else
        remote_or_local "$src_host" zfs snapshot "${src_ds}@${snap}"
      fi
    fi
  fi

  [[ $resume -eq 1 ]] && recv_flags+=(-s)
  [[ $force -eq 1 && -z $token ]] && recv_flags+=(-F)
  local extra_recv=()
  # shellcheck disable=SC2206
  extra_recv=(${ZFS_RECV_OPTS:-})

  local parent=${dst_ds%/*}
  if [[ $parent != "$dst_ds" ]] && ! remote_or_local "$dst_host" zfs list -H -o name "$parent" >/dev/null 2>&1; then
    info "creating parent $parent"
    remote_or_local "$dst_host" zfs create -p "$parent"
  fi

  local send_cmd recv_cmd
  if [[ -n $src_host ]]; then
    ssh_prefix "$src_host"
    send_cmd=("${_ssh[@]}" zfs send "${send_flags[@]}")
  else
    send_cmd=(zfs send "${send_flags[@]}")
  fi
  [[ -z $token ]] && send_cmd+=("${src_ds}@${snap}")

  if [[ -n $dst_host ]]; then
    ssh_prefix "$dst_host"
    recv_cmd=("${_ssh[@]}" zfs recv "${recv_flags[@]}" "${extra_recv[@]}" "$dst_ds")
  else
    recv_cmd=(zfs recv "${recv_flags[@]}" "${extra_recv[@]}" "$dst_ds")
  fi

  if [[ -n $token ]]; then
    info "send (resume token) -> ${dst_host:+$dst_host:}$dst_ds"
  else
    info "send ${src_ds}@${snap} -> ${dst_host:+$dst_host:}$dst_ds"
  fi

  if have_cmd mbuffer && [[ -n $mbuf && $mbuf != 0 ]]; then
    if have_cmd pv; then
      "${send_cmd[@]}" | mbuffer -s 128k -m "$mbuf" | pv | "${recv_cmd[@]}"
    else
      "${send_cmd[@]}" | mbuffer -s 128k -m "$mbuf" | "${recv_cmd[@]}"
    fi
  else
    if have_cmd pv; then
      "${send_cmd[@]}" | pv | "${recv_cmd[@]}"
    else
      "${send_cmd[@]}" | "${recv_cmd[@]}"
    fi
  fi

  if [[ -z $dst_host ]]; then
    mount_dataset_tree "$dst_ds"
    info "seed complete: $dst_ds"
    zfs list -o name,used,refer,avail,recordsize,compression,encryption "$dst_ds"
  else
    info "seed complete: $dst_host:$dst_ds"
    remote_or_local "$dst_host" zfs list -o name,used,refer,avail,recordsize,compression,encryption "$dst_ds"
  fi
}

mount_dataset_tree() {
  local root=$1 ds
  while IFS= read -r ds; do
    [[ -n $ds ]] || continue
    zfs mount "$ds" 2>/dev/null || true
  done < <(zfs list -H -r -o name -t filesystem "$root" 2>/dev/null || true)
}

seed_rsync() {
  local src_path=$1 dst_ds=$2 dry=$3
  need_cmd rsync
  parse_endpoint "$dst_ds"
  [[ -z $_ep_host ]] || die "rsync mode: --dst must be a local dataset (NFS-mount the source instead)"
  valid_zfs_name dataset "$dst_ds"

  [[ -d $src_path ]] || die "rsync source is not a directory: $src_path"

  if [[ $dry -eq 1 ]]; then
    info "dry-run: rsync $src_path/ -> $dst_ds"
    if ds_exists "$dst_ds"; then
      rsync -aH --numeric-ids --info=flist0,name0,progress2 --dry-run "$src_path"/ "$(ds_mountpoint "$dst_ds")"/
    else
      info "dry-run: would zfs create -p $dst_ds, then rsync"
    fi
    return
  fi

  if ! ds_exists "$dst_ds"; then
    info "creating $dst_ds"
    zfs create -p "$dst_ds"
  fi
  local dst_mp
  dst_mp=$(ensure_mounted "$dst_ds")
  info "rsync $src_path/ -> $dst_mp/  (unique blocks on $(pool_of "$dst_ds"))"
  rsync -aH --numeric-ids --partial --info=stats2,progress2 "$src_path"/ "$dst_mp"/
  zpool sync "$(pool_of "$dst_ds")"
  info "seed complete: $dst_ds"
  zfs list -o name,used,refer,avail,recordsize,compression "$dst_ds"
}

cmd_prep_dst() {
  ensure_root
  local dst="" like=""
  dst=${1:-}; shift || die "prep-dst DATASET --like SRC_DATASET"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --like) like=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown prep-dst option: $1" ;;
    esac
  done
  [[ -n $dst && -n $like ]] || die "prep-dst requires DATASET --like SRC_DATASET"
  valid_zfs_name dataset "$dst"
  valid_zfs_name dataset "$like"
  ds_exists "$like" || die "source dataset missing: $like"

  local rs comp cksum enc dn
  rs=$(zfs get -H -o value recordsize "$like")
  comp=$(zfs get -H -o value compression "$like")
  cksum=$(zfs get -H -o value checksum "$like")
  enc=$(zfs get -H -o value encryption "$like")
  dn=$(zfs get -H -o value dnodesize "$like")

  if ds_exists "$dst"; then
    info "destination exists: $dst"
  else
    info "creating $dst recordsize=$rs compression=$comp checksum=$cksum"
    local args=(-o "recordsize=$rs" -o "compression=$comp" -o "checksum=$cksum")
    [[ $dn != "-" && $dn != "" ]] && args+=(-o "dnodesize=$dn")
    if [[ $enc != off && $enc != "-" ]]; then
      warn "source is encrypted ($enc). Block cloning across encryption roots usually falls back to a full copy."
      warn "Create the dest as a snapshot-clone of the encrypted dataset if you need true clones."
    fi
    zfs create -p "${args[@]}" "$dst"
  fi
  zfs list -o name,mountpoint,recordsize,compression,checksum,encryption "$dst"
}

clone_one_py() {
  local src=$1 dst=$2
  "$(pybin)" - "$src" "$dst" <<'PY'
import os, sys, stat
src, dst = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
sfd = os.open(src, os.O_RDONLY)
copied = 0
try:
    st = os.fstat(sfd)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    dfd = os.open(dst, flags, st.st_mode)
    try:
        if hasattr(os, "posix_fadvise"):
            os.posix_fadvise(sfd, 0, 0, os.POSIX_FADV_SEQUENTIAL)
        size = st.st_size
        while copied < size:
            n = os.copy_file_range(sfd, dfd, size - copied)
            if n == 0:
                remaining = size - copied
                os.lseek(sfd, copied, os.SEEK_SET)
                os.lseek(dfd, copied, os.SEEK_SET)
                buf = os.read(sfd, min(remaining, 1 << 20))
                if not buf:
                    break
                os.write(dfd, buf)
                n = len(buf)
            copied += n
        try:
            os.fsync(dfd)
        except OSError:
            pass
    finally:
        os.close(dfd)
    os.chmod(dst, stat.S_IMODE(st.st_mode))
    try:
        os.chown(dst, st.st_uid, st.st_gid)
    except OSError:
        pass
    os.utime(dst, ns=(st.st_atime_ns, st.st_mtime_ns))
finally:
    os.close(sfd)
print(copied)
PY
}

cmd_clone_file() {
  ensure_root
  local src=${1:-} dst=${2:-}
  [[ -n $src && -n $dst ]] || die "clone-file SRC_PATH DST_PATH"
  [[ -f $src ]] || die "not a file: $src"
  mkdir -p "$(dirname "$dst")"
  info "clone_file_range $src -> $dst"
  local n
  n=$(clone_one_py "$src" "$dst")
  info "bytes processed: $n"
}

cmd_clone_tree() {
  ensure_root
  need_cmd find
  local src_ds="" dst_ds="" jobs=4 do_sync=1 fallback=copy
  src_ds=${1:-}; shift || die "clone-tree SRC_DATASET DST_DATASET"
  dst_ds=${1:-}; shift || die "clone-tree SRC_DATASET DST_DATASET"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --jobs) jobs=$2; shift 2 ;;
      --sync) do_sync=1; shift ;;
      --no-sync) do_sync=0; shift ;;
      --fallback) fallback=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown clone-tree option: $1" ;;
    esac
  done
  [[ $fallback == copy || $fallback == fail ]] || die "--fallback must be copy or fail"

  local src_pool dst_pool src_mp dst_mp
  src_pool=$(pool_of "$src_ds")
  dst_pool=$(pool_of "$dst_ds")
  [[ $src_pool == "$dst_pool" ]] || die "block cloning cannot cross pools ($src_pool vs $dst_pool). Use seed/send-recv."

  local feat
  feat=$(zpool get -H -o value feature@block_cloning "$src_pool" 2>/dev/null || echo "")
  if [[ $feat != enabled && $feat != active ]]; then
    warn "feature@block_cloning=$feat — copies will not share blocks"
  fi

  ds_exists "$src_ds" || die "missing $src_ds"
  ds_exists "$dst_ds" || die "missing $dst_ds (run prep-dst first)"
  src_mp=$(ensure_mounted "$src_ds")
  dst_mp=$(ensure_mounted "$dst_ds")

  local srs drs
  srs=$(zfs get -H -o value recordsize "$src_ds")
  drs=$(zfs get -H -o value recordsize "$dst_ds")
  if [[ $srs != "$drs" ]]; then
    warn "recordsize mismatch $src_ds=$srs $dst_ds=$drs — clones will fall back to copies"
  fi

  if [[ $do_sync -eq 1 ]]; then
    info "zpool sync $src_pool (dirty blocks cannot be cloned)"
    zpool sync "$src_pool"
  fi

  info "replicating dirs/symlinks, then cloning files $src_mp -> $dst_mp (jobs=$jobs)"
  replicate_dirs_and_links "$src_mp" "$dst_mp"
  walk_files "$src_mp" "$dst_mp" "$jobs" clone "$fallback"
  zpool sync "$src_pool"
  zfs list -o name,used,refer,compressratio "$src_ds" "$dst_ds"
  info "If block cloning worked, DST used << refer (shared blocks via BRT)."
  info "That does NOT add unique data for scrub/resilver; use copy-tree for that."
}

cmd_copy_tree() {
  ensure_root
  need_cmd find
  local src_ds="" dst_ds="" jobs=4
  src_ds=${1:-}; shift || die "copy-tree SRC_DATASET DST_DATASET"
  dst_ds=${1:-}; shift || die "copy-tree SRC_DATASET DST_DATASET"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --jobs) jobs=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown copy-tree option: $1" ;;
    esac
  done

  local src_mp dst_mp
  ds_exists "$src_ds" || die "missing $src_ds"
  ds_exists "$dst_ds" || die "missing $dst_ds (run prep-dst first)"
  src_mp=$(ensure_mounted "$src_ds")
  dst_mp=$(ensure_mounted "$dst_ds")
  info "full copy (unique blocks) $src_mp -> $dst_mp (jobs=$jobs)"
  replicate_dirs_and_links "$src_mp" "$dst_mp"
  walk_files "$src_mp" "$dst_mp" "$jobs" copy fail
  zpool sync "$(pool_of "$dst_ds")"
  zfs list -o name,used,refer,compressratio "$src_ds" "$dst_ds"
  info "Unique copy: DST used should be close to refer (real allocated blocks for scrub/resilver)."
}

walk_files() {
  local src_mp=$1 dst_mp=$2 jobs=$3 mode=$4 fallback=$5
  local list start end elapsed files xrc
  list=$(mktemp)
  find "$src_mp" -xdev -type f -print0 > "$list"
  files=$(tr -cd '\0' <"$list" | wc -c)
  info "files to $mode: $files"
  export src_mp dst_mp fallback mode
  export -f clone_one_py log info warn err die pybin LOG_TS
  start=$(date +%s)
  have_cmd xargs || { rm -f "$list"; die "xargs required"; }
  set +e
  <"$list" xargs -0 -r -n 1 -P "$jobs" bash -c '
    src="$1"
    rel="${src#"$src_mp"/}"
    dst="$dst_mp/$rel"
    mkdir -p "$(dirname "$dst")"
    if [[ $mode == clone ]]; then
      if ! clone_one_py "$src" "$dst" >/dev/null; then
        if [[ $fallback == fail ]]; then
          echo "clone failed: $src" >&2
          exit 1
        fi
        cp -a --reflink=never "$src" "$dst"
      fi
    else
      cp -a --reflink=never "$src" "$dst"
    fi
  ' _
  xrc=$?
  set -e
  rm -f "$list"
  [[ $xrc -eq 0 ]] || die "file $mode failed (xargs exit $xrc)"
  end=$(date +%s)
  elapsed=$((end - start))
  info "$mode finished in ${elapsed}s"
}

cmd_snapshot_clone() {
  ensure_root
  local src=${1:-} dst=${2:-}
  [[ -n $src && -n $dst ]] || die "snapshot-clone SRC DST"
  valid_zfs_name dataset "$src"
  valid_zfs_name dataset "$dst"
  [[ $(pool_of "$src") == "$(pool_of "$dst")" ]] || die "zfs clone cannot cross pools"
  local snap="bclone-lab-$(date -u +%Y%m%dT%H%M%SZ)"
  info "zfs snapshot ${src}@${snap} && zfs clone ${src}@${snap} ${dst}"
  zfs snapshot "${src}@${snap}"
  zfs clone "${src}@${snap}" "$dst"
  zfs list -o name,origin,used,refer "$src" "$dst"
}

pick_hasher() {
  if have_cmd sha256sum; then
    echo sha256sum
  elif have_cmd md5sum; then
    echo md5sum
  else
    die "need sha256sum or md5sum for verify"
  fi
}

cmd_verify() {
  need_cmd find
  local src_ds=${1:-} dst_ds=${2:-}
  shift 2 || die "verify SRC DST"
  local sample=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --sample) sample=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown verify option: $1" ;;
    esac
  done
  ds_exists "$src_ds" || die "missing $src_ds"
  ds_exists "$dst_ds" || die "missing $dst_ds"
  local src_mp dst_mp
  src_mp=$(ds_mountpoint "$src_ds")
  dst_mp=$(ds_mountpoint "$dst_ds")
  [[ -d $src_mp && -d $dst_mp ]] || die "both datasets must be mounted"

  local sc dc
  sc=$(find "$src_mp" -xdev -type f | wc -l)
  dc=$(find "$dst_mp" -xdev -type f | wc -l)
  info "file count src=$sc dst=$dc"
  [[ $sc -eq $dc ]] || warn "file count mismatch"

  local hasher
  hasher=$(pick_hasher)

  info "checksum sample (0 means all files) sample=$sample hasher=$hasher"
  local n=0 mismatches=0 rel g hs hd f
  while IFS= read -r -d '' f; do
    rel="${f#"$src_mp"/}"
    g="$dst_mp/$rel"
    if [[ ! -f $g ]]; then
      warn "missing: $rel"
      mismatches=$((mismatches + 1))
      continue
    fi
    hs=$($hasher "$f" | awk '{print $1}')
    hd=$($hasher "$g" | awk '{print $1}')
    if [[ $hs != "$hd" ]]; then
      warn "checksum mismatch: $rel"
      mismatches=$((mismatches + 1))
    fi
    n=$((n + 1))
    if [[ $sample -gt 0 && $n -ge $sample ]]; then
      break
    fi
  done < <(find "$src_mp" -xdev -type f -print0)
  info "checked $n files, mismatches=$mismatches"
  [[ $mismatches -eq 0 ]]
}

cmd_stats() {
  local pool=${1:-}
  if [[ -z $pool ]]; then
    zpool list
    return
  fi
  echo "=== pool properties ==="
  zpool get feature@block_cloning,feature@block_cloning_endian,allocated,free,fragmentation,dedupratio "$pool" || true
  echo
  echo "=== datasets (used vs refer) ==="
  zfs list -r -o name,used,refer,avail,recordsize,compression "$pool"
  echo
  echo "=== BRT / ARC kstats (if present) ==="
  local f
  for f in /proc/spl/kstat/zfs/brtstats /proc/spl/kstat/zfs/*/brtstats; do
    [[ -e $f ]] && { echo "-- $f"; cat "$f"; }
  done 2>/dev/null || true
  if [[ -e /proc/spl/kstat/zfs/arcstats ]]; then
    awk '/^hits|^misses|^c /{print}' /proc/spl/kstat/zfs/arcstats
  fi
  echo
  echo "After a successful block-clone, destination USED stays small while REFER"
  echo "matches the source. After copy-tree / rsync / send-recv, USED ≈ REFER"
  echo "(unique blocks — this is the scrub/resilver workload)."
}

cmd_bench_copy() {
  ensure_root
  local src=${1:-} parent=${2:-}
  [[ -n $src && -n $parent ]] || die "bench-copy SRC_DATASET DST_PARENT"
  ds_exists "$src" || die "missing $src"
  ds_exists "$parent" || zfs create -p "$parent"
  local tag
  tag=$(date -u +%Y%m%dT%H%M%SZ)
  local a="${parent}/bclone-${tag}"
  local b="${parent}/fullcopy-${tag}"
  local c="${parent}/snapclone-${tag}"

  echo "========== A: block-clone tree =========="
  cmd_prep_dst "$a" --like "$src"
  local t0 t1
  t0=$(date +%s.%N)
  cmd_clone_tree "$src" "$a" --jobs 8
  t1=$(date +%s.%N)
  awk -v t0="$t0" -v t1="$t1" 'BEGIN{printf "elapsed_s=%.3f\n", t1-t0}'
  zfs list -o name,used,refer "$src" "$a"

  echo "========== B: full copy (no reflink) =========="
  cmd_prep_dst "$b" --like "$src"
  t0=$(date +%s.%N)
  cmd_copy_tree "$src" "$b" --jobs 8
  t1=$(date +%s.%N)
  awk -v t0="$t0" -v t1="$t1" 'BEGIN{printf "elapsed_s=%.3f\n", t1-t0}'
  zfs list -o name,used,refer "$src" "$b"

  echo "========== C: snapshot dataset clone =========="
  t0=$(date +%s.%N)
  cmd_snapshot_clone "$src" "$c"
  t1=$(date +%s.%N)
  awk -v t0="$t0" -v t1="$t1" 'BEGIN{printf "elapsed_s=%.3f\n", t1-t0}'
}

main() {
  local cmd=${1:-}
  [[ -n $cmd ]] || { usage; exit 1; }
  shift || true
  case $cmd in
    check) cmd_check "$@" ;;
    ssh-help) cmd_ssh_help "$@" ;;
    seed) cmd_seed "$@" ;;
    prep-dst) cmd_prep_dst "$@" ;;
    copy-tree) cmd_copy_tree "$@" ;;
    clone-tree) cmd_clone_tree "$@" ;;
    clone-file) cmd_clone_file "$@" ;;
    snapshot-clone) cmd_snapshot_clone "$@" ;;
    verify) cmd_verify "$@" ;;
    stats) cmd_stats "$@" ;;
    bench-copy) cmd_bench_copy "$@" ;;
    -h|--help|help) usage ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"
