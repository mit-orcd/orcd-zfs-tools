#!/bin/bash
# zfs-healthcheck.sh - read-only regression check for the hstor ZFS/NFS servers
#
# Verifies the fixes applied in Nov 2026 have not regressed:
#   tuned profile + every sysctl in it (runtime vs tuned.conf, conflicts with sysctl.d),
#   NFS/RPC debug flags, ZFS module tunables, dm-multipath policy and path health,
#   SAS links, pool / md-raid health, ARC size, live reclaim rate, fragmentation,
#   recordsize/primarycache policy, kernel-log errors, kernel/ZFS version changes.
#
# Changes nothing on the system (only writes its own report + baseline files).
# Every WARN/FAIL gets a tag ([F1], [W2], ...). The report file printed at the end has,
# per tag, the exact command output that triggered it and a suggested fix.
#
# Usage:  zfs-healthcheck.sh [-q] [--rebaseline]
#   -q            print only the summary and WARN/FAIL lines
#   --rebaseline  accept current multipath map/path and HBA link counts as the new baseline
# Exit:   0 = OK, 1 = WARN, 2 = FAIL
#
# Host-specific expectations: overrides in /etc/zfs-healthcheck.conf (sourced; path can be
# changed with ZHC_CONF=...). Any EXP_* left empty is skipped, e.g.  EXP_SHRINKER_LIMIT=""

set -u
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ---------------- expected values (defaults = hstor014) ----------------
TUNED_PROFILE=zfs-storage
TUNED_CONF=""                        # auto: /etc/tuned/$TUNED_PROFILE/tuned.conf or /etc/tuned/profiles/...
EXP_WATERMARK_BOOST=0
EXP_COMPACTION_PROACTIVENESS=60
EXP_PRINTK="3 4 1 3"
EXP_PREFETCH_DISABLE=0
EXP_SHRINKER_LIMIT=10000
EXP_ARC_MAX=auto                     # auto = ARC_MAX_PCT of MemTotal, whole GiB (zfs-pool-setup.sh policy)
EXP_ARC_MIN=auto                     # auto = ARC_MIN_PCT of MemTotal; set bytes in $CONF to pin a host
ARC_MAX_PCT=60
ARC_MIN_PCT=25
MAX_ENC_RECORDSIZE=524288            # report encrypted datasets with recordsize above this (512K)
RS_ALLOW=""                          # datasets exempt from the recordsize report
PC_ALLOW="data1/orcd data2/orcd"     # datasets allowed primarycache != all
SAMPLE_SECS=60                       # live sampling window for reclaim / read rates
ALLOCSTALL_WARN=500;  ALLOCSTALL_FAIL=5000     # direct-reclaim stalls per minute
DIRECT_WARN=2000;     DIRECT_FAIL=20000        # ARC direct shrinks per minute
POOL_CAP_WARN=80;     POOL_CAP_FAIL=90         # pool capacity %
LOG_WINDOW="3 days ago"                        # kernel-log lookback
STATE_DIR=/var/lib/zfs-healthcheck
LOG_DIR=/var/log/zfs-healthcheck
MAILTO=""                                      # mail the report here when status != OK
CONF=${ZHC_CONF:-/etc/zfs-healthcheck.conf}
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

MEM_B=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) * 1024 ))
arc_auto() { echo $(( MEM_B * $1 / 100 / 1073741824 * 1073741824 )); }
[ "$EXP_ARC_MAX" = auto ] && EXP_ARC_MAX=$(arc_auto "$ARC_MAX_PCT")
[ "$EXP_ARC_MIN" = auto ] && EXP_ARC_MIN=$(arc_auto "$ARC_MIN_PCT")

QUIET=0; REBASE=0
for a in "$@"; do
  case "$a" in
    -q) QUIET=1 ;;
    --rebaseline) REBASE=1 ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 2; }

if [ -z "$TUNED_CONF" ]; then
  for c in "/etc/tuned/$TUNED_PROFILE/tuned.conf" "/etc/tuned/profiles/$TUNED_PROFILE/tuned.conf"; do
    [ -r "$c" ] && { TUNED_CONF=$c; break; }
  done
  [ -z "$TUNED_CONF" ] && TUNED_CONF="/etc/tuned/$TUNED_PROFILE/tuned.conf"
fi

mkdir -p "$STATE_DIR" "$LOG_DIR"
TS=$(date +%F_%H%M%S)
LOGF="$LOG_DIR/$TS.txt"

# ---------------- report helpers ----------------
# warn/fail "message" ["fix hint"] ["evidence command"]
RC=0; NW=0; NF=0; REPORT=""; EVIDENCE=""
out()  { REPORT+="$1"$'\n'; }
sec()  { out ""; out "== $*"; }
ok()   { out "  OK    $*"; }
info() { out "  INFO  $*"; }
add_evidence() {
  local tag=$1 msg=$2 fix=$3 cmd=$4
  EVIDENCE+=$'\n'"---- [$tag] $msg"$'\n'
  [ -n "$fix" ] && EVIDENCE+="fix:  $fix"$'\n'
  if [ -n "$cmd" ]; then
    EVIDENCE+="\$ $cmd"$'\n'
    EVIDENCE+="$(timeout 30 bash -c "$cmd" 2>&1 | head -40)"$'\n'
  fi
}
warn() { NW=$((NW+1)); [ "$RC" -lt 1 ] && RC=1; out "  WARN  [W$NW] $1"; add_evidence "W$NW" "$1" "${2:-}" "${3:-}"; }
fail() { NF=$((NF+1)); RC=2;                  out "  FAIL  [F$NF] $1"; add_evidence "F$NF" "$1" "${2:-}" "${3:-}"; }

norm()   { echo "$*" | tr -s ' \t' ' ' | sed 's/^ //; s/ $//'; }
zparam() { cat "/sys/module/zfs/parameters/$1" 2>/dev/null || echo "n/a"; }
persist_zfs() { grep -hqE "^[[:space:]]*options[[:space:]]+zfs[[:space:]].*\b$1=$2\b" /etc/modprobe.d/*.conf 2>/dev/null; }
arcstat()  { awk -v k="$1" '$1==k{print $3}' /proc/spl/kstat/zfs/arcstats 2>/dev/null; }
vmstat_v() { awk -v k="$1" '$1==k{print $2}' /proc/vmstat; }

# all "key<TAB>value" pairs from the [sysctl] section of the tuned profile
tuned_sysctls() {
  [ -r "$TUNED_CONF" ] || return
  awk '
    /^[[:space:]]*\[/ { s = ($0 ~ /^[[:space:]]*\[sysctl\]/); next }
    s {
      line=$0; sub(/^[[:space:]]+/, "", line)
      if (line ~ /^[#;]/ || index(line, "=") == 0) next
      k=substr(line, 1, index(line, "=")-1); v=substr(line, index(line, "=")+1)
      sub(/[[:space:]]+#.*$/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/\//, ".", k)
      print k "\t" v
    }' "$TUNED_CONF"
}
tuned_val() { tuned_sysctls | awk -F'\t' -v k="$1" '$1==k{v=$2} END{if (v!="") print v}'; }
# "file:value" for every admin sysctl file that sets the key (sysctl.conf + sysctl.d)
sysctld_vals() {
  local k=$1 f
  for f in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
    [ -r "$f" ] || continue
    awk -v k="$k" -v f="$f" '
      { line=$0; sub(/^[[:space:]]*-?/, "", line)
        if (line ~ /^[#;]/ || index(line, "=") == 0) next
        key=substr(line, 1, index(line, "=")-1); v=substr(line, index(line, "=")+1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/\//, ".", key)
        if (key==k) print f ":" v }' "$f"
  done
}
reapply_sysctl() {   # tuned re-applies /etc/sysctl.d after the profile (sysctl.d wins) unless disabled
  grep -qiE '^[[:space:]]*reapply_sysctl[[:space:]]*=[[:space:]]*(0|false|no)' /etc/tuned/tuned-main.conf 2>/dev/null && echo 0 || echo 1
}

chk_zparam() {   # name expected
  local p=$1 exp=$2 cur
  [ -z "$exp" ] && return
  cur=$(zparam "$p")
  if [ "$cur" = "$exp" ]; then
    if persist_zfs "$p" "$exp"; then ok "$p=$cur (persistent)"
    else warn "$p=$cur but NOT persistent in /etc/modprobe.d" \
              "add 'options zfs $p=$exp' to /etc/modprobe.d/zfs.conf (dracut -f if zfs is in the initramfs)" \
              "grep -n '$p' /etc/modprobe.d/*.conf"; fi
  else
    fail "$p=$cur (expected $exp)" \
         "runtime: echo $exp > /sys/module/zfs/parameters/$p ; persistent: options zfs $p=$exp in /etc/modprobe.d/zfs.conf" \
         "cat /sys/module/zfs/parameters/$p; grep -n '$p' /etc/modprobe.d/*.conf"
  fi
}

chk_sysctl() {   # key expected   - runtime value + where it is made persistent
  local k=$1 exp cur tv sd
  exp=$(norm "$2"); [ -z "$exp" ] && return
  cur=$(norm "$(sysctl -n "$k" 2>/dev/null)")
  tv=$(norm "$(tuned_val "$k")")
  sd=$(sysctld_vals "$k")
  if [ -n "$tv" ] && [ "$tv" != "$exp" ]; then
    fail "$k: tuned.conf sets '$tv' but the ZFS tuning requires '$exp'" \
         "edit $TUNED_CONF [sysctl]: '$k = $exp', then: tuned-adm profile $TUNED_PROFILE" \
         "sysctl $k; grep -n '$k' $TUNED_CONF /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null"
  elif [ "$tv" = "$exp" ]; then
    if [ "$cur" = "$exp" ]; then ok "$k='$cur' (tuned profile)"
    else info "$k runtime='$cur' differs from tuned.conf - reported in the tuned section above"; fi
  elif [ "$cur" != "$exp" ]; then
    fail "$k='$cur' (expected '$exp') and not set in the tuned profile" \
         "add '$k = $exp' to $TUNED_CONF [sysctl], then: tuned-adm profile $TUNED_PROFILE" \
         "sysctl $k; grep -n '$k' $TUNED_CONF /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null; tuned-adm active"
  elif [ -n "$sd" ] && echo "$sd" | awk -F: '{print $NF}' | while read -r v; do [ "$(norm "$v")" = "$exp" ] && echo y; done | grep -q y; then
    warn "$k='$cur' persisted in sysctl.d, not in the tuned profile" \
         "move it into $TUNED_CONF [sysctl] so all ZFS tuning lives in one place" \
         "grep -n '$k' $TUNED_CONF /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null"
  else
    warn "$k='$cur' is correct now but NOT persistent (lost on reboot)" \
         "add '$k = $exp' to $TUNED_CONF [sysctl], then: tuned-adm profile $TUNED_PROFILE" \
         "grep -n '$k' $TUNED_CONF /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null"
  fi
}

STATE="$STATE_DIR/baseline"
B_KERNEL=""; B_ZFSVER=""; B_MP_MAPS=""; B_MP_PATHS=""; B_HBA_12G=""
# shellcheck disable=SC1090
[ -r "$STATE" ] && . "$STATE"

HOST=$(hostname -s)
KERNEL=$(uname -r)
ZFSVER=$(cat /sys/module/zfs/version 2>/dev/null || echo n/a)

# ======================================================================
sec "Versions"
info "host=$HOST kernel=$KERNEL zfs=$ZFSVER uptime=$(uptime -p 2>/dev/null)"
if [ -n "$B_KERNEL" ] && { [ "$B_KERNEL" != "$KERNEL" ] || [ "$B_ZFSVER" != "$ZFSVER" ]; }; then
  warn "kernel/ZFS changed since last run ($B_KERNEL / $B_ZFSVER -> $KERNEL / $ZFSVER)" \
       "re-verify tunables, multipath and the encrypted-read reclaim behaviour after the upgrade" \
       "rpm -q kernel zfs kmod-zfs 2>/dev/null | tail -6; cat /sys/module/zfs/version"
fi

# ======================================================================
sec "tuned profile ($TUNED_PROFILE)"
if command -v tuned-adm >/dev/null 2>&1; then
  if [ "$(systemctl is-active tuned 2>/dev/null)" = active ]; then ok "tuned active"
  else fail "tuned NOT active: profile sysctls are not (re)applied" \
            "systemctl enable --now tuned" "systemctl status tuned --no-pager | head -15"; fi
  [ "$(systemctl is-enabled tuned 2>/dev/null)" = enabled ] || \
    warn "tuned not enabled at boot" "systemctl enable tuned" "systemctl is-enabled tuned"
  act=$(tuned-adm active 2>/dev/null | sed -n 's/^Current active profile: *//p')
  if [ "$act" = "$TUNED_PROFILE" ]; then ok "active profile: $act"
  else fail "active tuned profile is '${act:-none}', expected '$TUNED_PROFILE'" \
            "tuned-adm profile $TUNED_PROFILE" "tuned-adm active; tuned-adm list | grep -iE 'zfs|throughput|current'"; fi
  if [ "$act" = "$TUNED_PROFILE" ]; then
    if tuned-adm verify --ignore-missing >/dev/null 2>&1; then ok "tuned-adm verify: system matches profile"
    else warn "tuned-adm verify reports differences from the profile" \
              "tuned-adm profile $TUNED_PROFILE to re-apply; details in /var/log/tuned/tuned.log" \
              "tuned-adm verify --ignore-missing; grep -iE 'verify|fail|differ' /var/log/tuned/tuned.log | tail -15"; fi
  fi
else
  warn "tuned-adm not installed" "dnf install tuned; systemctl enable --now tuned" ""
fi

if [ -r "$TUNED_CONF" ]; then
  ok "profile file: $TUNED_CONF"
  TS_LIST=$(tuned_sysctls)
  n_tot=0; n_ok=0; RA=$(reapply_sysctl)
  while IFS=$'\t' read -r k v; do
    [ -z "$k" ] && continue
    n_tot=$((n_tot+1))
    if [[ "$v" == *'${'* ]]; then info "$k = $v (uses tuned variables - not compared)"; continue; fi
    cur=$(sysctl -n "$k" 2>/dev/null) || { warn "$k in tuned.conf is not a valid sysctl on this kernel" \
                                                 "remove or fix the key in $TUNED_CONF" "sysctl $k; grep -n '$k' $TUNED_CONF"; continue; }
    if [ "$(norm "$cur")" = "$(norm "$v")" ]; then
      n_ok=$((n_ok+1))
    else
      fail "$k runtime='$(norm "$cur")' but tuned.conf='$(norm "$v")'" \
           "re-apply with: tuned-adm profile $TUNED_PROFILE ; if it reverts again, find what overrides it (sysctl.d, scripts, other daemons)" \
           "sysctl $k; grep -n '$k' $TUNED_CONF /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf 2>/dev/null; grep -i reapply_sysctl /etc/tuned/tuned-main.conf"
    fi
    # same key also set by an admin sysctl file with a different value?
    while IFS= read -r fv; do
      [ -z "$fv" ] && continue
      f=${fv%%:*}; sv=${fv#*:}
      if [ "$(norm "$sv")" != "$(norm "$v")" ]; then
        if [ "$RA" = 1 ]; then who="$f wins at boot (tuned reapply_sysctl=1)"; else who="tuned wins (reapply_sysctl=0)"; fi
        warn "$k conflict: tuned.conf='$(norm "$v")' vs $f='$(norm "$sv")' - $who" \
             "keep the value only in $TUNED_CONF and remove it from $f" \
             "grep -n '$k' $TUNED_CONF $f; grep -i reapply_sysctl /etc/tuned/tuned-main.conf"
      fi
    done <<< "$(sysctld_vals "$k")"
  done <<< "$TS_LIST"
  info "$n_ok/$n_tot sysctls in tuned.conf match the running system"
else
  fail "tuned profile file not found: $TUNED_CONF" \
       "restore the profile (or set TUNED_CONF in $CONF)" "ls -l /etc/tuned/ /etc/tuned/profiles/ 2>/dev/null"
fi

sec "Required ZFS-related sysctls"
chk_sysctl vm.watermark_boost_factor   "$EXP_WATERMARK_BOOST"
chk_sysctl vm.compaction_proactiveness "$EXP_COMPACTION_PROACTIVENESS"
chk_sysctl kernel.printk               "$EXP_PRINTK"

# ======================================================================
sec "NFS/RPC debug flags"
for f in nfsd rpc nfs nlm; do
  v=$(cat /proc/sys/sunrpc/${f}_debug 2>/dev/null || echo n/a)
  case "$v" in
    0x0000|0|n/a) ok "${f}_debug=$v" ;;
    *) fail "${f}_debug=$v (debug logging ON: floods console, pr/ttyS0 at 100% CPU)" \
            "rpcdebug -m $f -c all ; then find what enabled it" \
            "rpcdebug -m $f; grep -rsnE 'rpcdebug|${f}_debug' /etc/sysctl.d /etc/tuned /etc/modprobe.d /etc/rc.d /etc/systemd/system | head" ;;
  esac
done

# ======================================================================
sec "ZFS module tunables"
chk_zparam zfs_prefetch_disable   "$EXP_PREFETCH_DISABLE"
chk_zparam zfs_arc_shrinker_limit "$EXP_SHRINKER_LIMIT"
info "ARC expectations: max=$((EXP_ARC_MAX>>30))GiB min=$((EXP_ARC_MIN>>30))GiB (RAM $((MEM_B>>30))GiB; auto = ${ARC_MAX_PCT}%/${ARC_MIN_PCT}%, override in $CONF)"
chk_zparam zfs_arc_max            "$EXP_ARC_MAX"
chk_zparam zfs_arc_min            "$EXP_ARC_MIN"

# ======================================================================
sec "dm-multipath"
MP_MAPS=""; MP_PATHS=""
if command -v multipath >/dev/null 2>&1; then
  if [ "$(systemctl is-active multipathd 2>/dev/null)" = active ]; then ok "multipathd active"
  else fail "multipathd NOT active (no path monitoring/failover)" \
            "check config: multipath -t >/dev/null; then systemctl restart multipathd" \
            "systemctl status multipathd --no-pager | head -15; journalctl -u multipathd -n 20 --no-pager"; fi
  [ "$(systemctl is-enabled multipathd 2>/dev/null)" = enabled ] && ok "multipathd enabled at boot" || \
    warn "multipathd not enabled at boot" "systemctl enable multipathd" "systemctl is-enabled multipathd"

  MP=$(multipath -ll 2>/dev/null)
  if [ -n "$MP" ]; then
    PERMAP=$(echo "$MP" | awk '
      / dm-[0-9]+ /{ if (m!="") print m, n; m=$1; n=0; next }
      /[0-9]+:[0-9]+:[0-9]+:[0-9]+/ && /active ready/ { n++ }
      END{ if (m!="") print m, n }')
    MP_MAPS=$(echo "$PERMAP" | grep -c .)
    MP_PATHS=$(echo "$PERMAP" | awk '{s+=$2} END{print s+0}')
    pmin=$(echo "$PERMAP" | awk 'NR==1||$2<m{m=$2} END{print m+0}')
    pmax=$(echo "$PERMAP" | awk '$2>m{m=$2} END{print m+0}')
    info "$MP_MAPS maps, $MP_PATHS healthy paths (per map: min $pmin, max $pmax)"
    if [ "$pmin" -lt "$pmax" ]; then
      short=$(echo "$PERMAP" | awk -v M="$pmax" '$2<M{print $1}' | head -5 | paste -sd' ' -)
      warn "some maps have fewer healthy paths than others (e.g. $short)" \
           "check cabling/expander for those disks; multipath -ll <wwid>; dmesg for link errors" \
           "for m in $short; do multipath -ll \$m; done"
    fi
    n=$(echo "$MP" | grep -c 'status=enabled')
    [ "$n" -eq 0 ] && ok "no idle path groups (multibus in effect)" || \
      fail "$n idle path groups (status=enabled): failover policy is back - only 1 path per disk carries I/O" \
           "set path_grouping_policy multibus in /etc/multipath.conf (defaults AND any devices section), then: multipathd reconfigure" \
           "multipath -ll | grep -B4 'status=enabled' | head -20; grep -nE 'path_grouping|path_selector|no_path_retry' /etc/multipath.conf"
    n=$(echo "$MP" | grep -c 'queue_if_no_path')
    [ "$n" -eq 0 ] && ok "no maps with queue_if_no_path" || \
      warn "$n maps with queue_if_no_path (I/O hangs instead of failing on total path loss)" \
           "no_path_retry fail in /etc/multipath.conf, remove features queue_if_no_path, multipathd reconfigure" \
           "multipath -ll | grep -B1 queue_if_no_path | head -10; grep -nE 'no_path_retry|features' /etc/multipath.conf"
    n=$(echo "$MP" | grep -cE 'failed|faulty|offline|shaky')
    [ "$n" -eq 0 ] && ok "no failed/faulty paths" || \
      fail "$n failed/faulty/offline paths" \
           "identify the disk/HBA/expander from the HCTL; check cables, dmesg, smartctl -x on the sd device" \
           "multipath -ll | grep -B6 -E 'failed|faulty|offline|shaky' | head -30"
    HB=$(echo "$MP" | grep 'active ready' | grep -oE '\b[0-9]+:[0-9]+:[0-9]+:[0-9]+\b' | cut -d: -f1 | sort -n | uniq -c)
    info "paths per HBA host: $(echo "$HB" | awk '{printf "host%s=%s ", $2, $1}')"
    hmin=$(echo "$HB" | awk 'NR==1||$1<m{m=$1} END{print m+0}')
    hmax=$(echo "$HB" | awk '$1>m{m=$1} END{print m+0}')
    if [ "$(echo "$HB" | grep -c .)" -gt 1 ] && [ $((hmax - hmin)) -gt $((hmax / 5)) ]; then
      warn "path counts unbalanced across HBAs (min $hmin, max $hmax)" \
           "one HBA/expander path is degraded - check SAS cables and the HBA link section" \
           "multipath -ll | grep 'active ready' | grep -oE '\\b[0-9]+:[0-9]+:[0-9]+:[0-9]+\\b' | cut -d: -f1 | sort -n | uniq -c"
    fi
  else
    warn "multipath -ll returned nothing" "check multipathd and /etc/multipath.conf" "multipath -ll 2>&1 | head; systemctl status multipathd --no-pager | head"
  fi

  if grep -qE '^[^#]*path_grouping_policy[[:space:]]+"?failover' /etc/multipath.conf 2>/dev/null; then
    fail "/etc/multipath.conf contains path_grouping_policy failover" \
         "change to multibus (with path_selector \"service-time 0\") and multipathd reconfigure" \
         "grep -nE 'path_grouping|path_selector|no_path_retry|features' /etc/multipath.conf"
  elif grep -qE '^[^#]*path_grouping_policy[[:space:]]+"?multibus' /etc/multipath.conf 2>/dev/null; then
    ok "/etc/multipath.conf: multibus"
  else
    warn "/etc/multipath.conf sets no path_grouping_policy (built-in default is failover)" \
         "add path_grouping_policy multibus + path_selector \"service-time 0\" to defaults" "cat /etc/multipath.conf"
  fi
  grep -qE '^[^#]*no_path_retry[[:space:]]+"?queue' /etc/multipath.conf 2>/dev/null && \
    warn "/etc/multipath.conf: no_path_retry queue" "use no_path_retry fail (or a small count)" "grep -n no_path_retry /etc/multipath.conf"

  if [ -n "$B_MP_MAPS" ] && [ -n "$MP_MAPS" ]; then
    [ "$MP_MAPS" -lt "$B_MP_MAPS" ] && fail "multipath maps dropped: $MP_MAPS (baseline $B_MP_MAPS)" \
         "a disk disappeared - check zpool status, dmesg, enclosure; --rebaseline only after intended changes" \
         "zpool status -x; journalctl -k --since '$LOG_WINDOW' --no-pager | grep -iE 'remov|offline|dev_loss' | tail -10"
    [ "$MP_PATHS" -lt "$B_MP_PATHS" ] && fail "healthy paths dropped: $MP_PATHS (baseline $B_MP_PATHS)" \
         "a path/cable/expander is down - see per-HBA path counts and SAS link section" \
         "multipath -ll | grep -vE 'active ready running' | grep -E '[0-9]+:[0-9]+:[0-9]+:[0-9]+' | head -20"
  fi
else
  info "multipath not installed - skipped"
fi

# ======================================================================
sec "SAS HBA links"
HBA_12G=0
for h in /sys/class/sas_host/host*; do
  [ -e "$h" ] || continue
  hn=${h##*host}; up=0; tot=0
  for p in /sys/class/sas_phy/phy-"$hn":*; do
    [[ "${p##*/}" =~ ^phy-$hn:[0-9]+$ ]] || continue
    tot=$((tot+1))
    grep -q '12.0 Gbit' "$p/negotiated_linkrate" 2>/dev/null && up=$((up+1))
  done
  [ "$tot" -gt 0 ] && info "host$hn: $up/$tot phys at 12G"
  HBA_12G=$((HBA_12G+up))
done
if [ -n "$B_HBA_12G" ] && [ "$HBA_12G" -lt "$B_HBA_12G" ]; then
  warn "HBA phys at 12G dropped: $HBA_12G (baseline $B_HBA_12G)" \
       "reseat/replace the SAS cable on the listed phy's port; check JBOD connector" \
       "for p in /sys/class/sas_phy/phy-*; do n=\${p##*/}; [[ \$n =~ ^phy-[0-9]+:[0-9]+\$ ]] && echo \"\$n \$(cat \$p/negotiated_linkrate)\"; done | grep -v '12.0' "
fi

# ======================================================================
sec "Storage health"
zs=$(zpool status -x 2>&1)
if [ "$zs" = "all pools are healthy" ]; then ok "zpool status: all pools are healthy"
else fail "zpool status -x reports a problem" \
          "identify the faulted/degraded vdev; check the disk (smartctl -x), replace/online as needed" \
          "zpool status -x -v | head -40"; fi
while read -r name cap frag; do
  [ -z "$name" ] && continue
  if   [ "$cap" -ge "$POOL_CAP_FAIL" ]; then fail "$name ${cap}% full (frag $frag%)" "free space or expand the pool; >90% badly hurts allocation" "zpool list -v $name | head -15"
  elif [ "$cap" -ge "$POOL_CAP_WARN" ]; then warn "$name ${cap}% full (frag $frag%)" "plan capacity; consider quotas" "zfs list -o name,used,avail,quota,refquota -d1 $name"
  else ok "$name ${cap}% full (frag $frag%)"; fi
done < <(zpool list -Hp -o name,capacity,fragmentation 2>/dev/null)

if grep -q '^md' /proc/mdstat 2>/dev/null; then
  if grep -qE '\[[U_]*_[U_]*\]|\(F\)' /proc/mdstat; then
    fail "md RAID degraded (boot mirror)" \
         "replace the failed SSD, copy the GPT from the good disk (sgdisk -R), mdadm --add, re-create ESP + efibootmgr entry" \
         "cat /proc/mdstat; for m in /dev/md[0-9]*; do mdadm --detail \$m | grep -E 'State|Devices|/dev/'; done; lsblk -o NAME,MODEL,SERIAL,SIZE | grep -iE 'micron|sata'"
  else ok "md RAID arrays all [UU]"; fi
  systemctl is-active -q mdmonitor 2>/dev/null && ok "mdmonitor active" || \
    warn "mdmonitor not active (degraded arrays will not alert)" \
         "set MAILADDR in /etc/mdadm.conf; systemctl enable --now mdmonitor" "grep -E '^MAILADDR|^PROGRAM' /etc/mdadm.conf; systemctl status mdmonitor --no-pager | head -5"
fi

# ======================================================================
# live sample first: the ARC floor check needs to know whether the ARC is being shrunk right now
objsnap() {
  for f in /proc/spl/kstat/zfs/*/objset-*; do
    [ -e "$f" ] && awk '/dataset_name/{n=$3} /^nread/{r=$3} END{print n, r}' "$f"
  done | sort
}
s1=$(vmstat_v allocstall_normal); d1=$(arcstat memory_direct_count); i1=$(arcstat memory_indirect_count); k1=$(vmstat_v pgscan_kswapd)
o1=$(objsnap)
sleep "$SAMPLE_SECS"
s2=$(vmstat_v allocstall_normal); d2=$(arcstat memory_direct_count); i2=$(arcstat memory_indirect_count); k2=$(vmstat_v pgscan_kswapd)
o2=$(objsnap)
pm() { echo $(( ($2 - $1) * 60 / SAMPLE_SECS )); }
r_stall=$(pm "${s1:-0}" "${s2:-0}"); r_dir=$(pm "${d1:-0}" "${d2:-0}"); r_ind=$(pm "${i1:-0}" "${i2:-0}"); r_scan=$(pm "${k1:-0}" "${k2:-0}")
top=$(join <(echo "$o1") <(echo "$o2") 2>/dev/null | awk -v t="$SAMPLE_SECS" '{r=($3-$2)/t/1e6; if (r>=1) printf "%s %.0fMB/s\n", $1, r}' | sort -t' ' -k2 -rn | head -3 | paste -sd, -)
SAMPLE_TXT="sample ${SAMPLE_SECS}s: allocstall_normal $s1->$s2, memory_direct_count $d1->$d2, memory_indirect_count $i1->$i2, pgscan_kswapd $k1->$k2; top readers: ${top:-none}"
RECLAIM_FIX="1) top readers + bpftrace order histogram (see ARC fix) to find the dataset/allocation order; 2) echo 1 > /proc/sys/vm/compact_memory for immediate relief; 3) hot encrypted 1M-recordsize datasets: zfs set recordsize=256K + migrate old data"
RECLAIM_CMD="echo '$SAMPLE_TXT'; cat /proc/buddyinfo; grep -E '^(size|c_min|memory_direct_count|memory_indirect_count) ' /proc/spl/kstat/zfs/arcstats"

sec "ARC"
a_size=$(arcstat size); a_c=$(arcstat c); a_min=$(arcstat c_min); a_max=$(arcstat c_max)
a_ng=$(arcstat arc_no_grow); a_dir=$(arcstat memory_direct_count); a_ind=$(arcstat memory_indirect_count)
if [ -n "$a_size" ]; then
  info "size=$((a_size>>30))GiB c=$((a_c>>30))GiB c_min=$((a_min>>30))GiB c_max=$((a_max>>30))GiB ($(( a_size * 100 / a_max ))% of max)"
  if [ "$a_size" -gt $(( a_min + a_min / 20 )) ]; then ok "ARC above floor"
  elif [ "$r_dir" -gt 0 ] || [ "$r_ind" -gt 0 ] || [ "${a_ng:-0}" = 1 ]; then
    warn "ARC is at its floor (c_min) and memory pressure is shrinking it (direct $r_dir/min, indirect $r_ind/min, arc_no_grow=${a_ng:-?})" \
         "see the reclaim section; find the allocation order: bpftrace -e 'tracepoint:vmscan:mm_vmscan_wakeup_kswapd { @[args->order, comm] = count(); } interval:s:30 { exit(); }'" \
         "grep -E '^(size|c|c_min|c_max|memory_direct_count|memory_indirect_count|arc_no_grow|memory_available_bytes) ' /proc/spl/kstat/zfs/arcstats; free -g; cat /proc/buddyinfo"
  else
    info "ARC at/below c_min but not shrinking (no shrinks in ${SAMPLE_SECS}s, arc_no_grow=0; since module load direct=${a_dir:-0} indirect=${a_ind:-0}): still filling after boot or light load"
  fi
fi

sec "Live reclaim and read rates (${SAMPLE_SECS}s sample)"
info "per minute: allocstall=$r_stall arc_direct=$r_dir arc_indirect=$r_ind kswapd_scan=$((r_scan*4/1024))MiB"
if   [ "$r_stall" -ge "$ALLOCSTALL_FAIL" ]; then fail "direct-reclaim stalls $r_stall/min (>= $ALLOCSTALL_FAIL)" "$RECLAIM_FIX" "$RECLAIM_CMD"
elif [ "$r_stall" -ge "$ALLOCSTALL_WARN" ]; then warn "direct-reclaim stalls $r_stall/min (>= $ALLOCSTALL_WARN)" "$RECLAIM_FIX" "$RECLAIM_CMD"
else ok "direct-reclaim stalls $r_stall/min"; fi
if   [ "$r_dir" -ge "$DIRECT_FAIL" ]; then fail "ARC direct shrinks $r_dir/min (>= $DIRECT_FAIL)" "$RECLAIM_FIX" "$RECLAIM_CMD"
elif [ "$r_dir" -ge "$DIRECT_WARN" ]; then warn "ARC direct shrinks $r_dir/min (>= $DIRECT_WARN)" "$RECLAIM_FIX" "$RECLAIM_CMD"
else ok "ARC direct shrinks $r_dir/min"; fi
info "top readers during sample: ${top:-none above 1 MB/s} (low load = reclaim numbers are optimistic)"

sec "Memory fragmentation (free blocks of order >= 8, Normal zones)"
frag=$(awk '$4=="Normal"{printf "node%s=%d ", $2+0, $13+$14+$15}' /proc/buddyinfo)
info "$frag"
echo "$frag" | grep -qE '=[1-9]' || info "no order>=8 blocks on any node: 1M encrypted reads will trigger reclaim"

# ======================================================================
sec "Dataset policy"
DS=$(zfs get -Hp -t filesystem -o name,property,value recordsize,encryption,primarycache 2>/dev/null | awk '
  {v[$1,$2]=$3; n[$1]=1}
  END{for (d in n) print d, v[d,"recordsize"], v[d,"encryption"], v[d,"primarycache"]}' | sort)
big=""; pc=""
while read -r d rs enc pcache; do
  [ -z "$d" ] && continue
  if [ "$enc" != "off" ] && [ "${rs:-0}" -gt "$MAX_ENC_RECORDSIZE" ] && [[ " $RS_ALLOW " != *" $d "* ]]; then big+="$d($((rs>>10))K) "; fi
  if [ "$pcache" != "all" ] && [[ " $PC_ALLOW " != *" $d "* ]]; then pc+="$d($pcache) "; fi
done <<< "$DS"
[ -z "$big" ] && ok "no encrypted datasets above $((MAX_ENC_RECORDSIZE>>10))K recordsize" \
              || info "encrypted datasets above $((MAX_ENC_RECORDSIZE>>10))K (watch if they become read-heavy): $big"
[ -z "$pc" ]  && ok "primarycache=all everywhere (allowlist: ${PC_ALLOW:-none})" \
              || warn "primarycache != all (disables prefetch for those datasets): $pc" \
                      "zfs set primarycache=all <dataset> (or add to PC_ALLOW in $CONF if intended)" \
                      "zfs get -t filesystem -s local,inherited primarycache | grep -v ' all '"

# ======================================================================
sec "Kernel log since $LOG_WINDOW"
if command -v journalctl >/dev/null 2>&1; then KCMD="journalctl -k --since '$LOG_WINDOW' --no-pager -q"
else KCMD="dmesg -T"; fi
KL=$(bash -c "$KCMD" 2>/dev/null)
kchk() {  # level pattern okmsg msg fix
  local lvl=$1 pat=$2 okm=$3 msg=$4 fix=$5 c
  c=$(echo "$KL" | grep -cE "$pat")
  if [ "$c" -eq 0 ]; then ok "$okm"
  elif [ "$lvl" = fail ]; then fail "$c $msg" "$fix" "$KCMD | grep -E '$pat' | tail -15"
  elif [ "$lvl" = warn ]; then warn "$c $msg" "$fix" "$KCMD | grep -E '$pat' | tail -15"
  else info "$c $msg"; fi
}
kchk fail 'I/O error|blk_update_request|critical medium error|Medium Error' "no block I/O errors" \
     "block I/O error lines" "map the sd/dm device to its WWN (multipath -ll / ls -l /dev/disk/by-id), smartctl -x, zpool status -v"
kchk warn 'ata[0-9.]+: (exception|failed command|hard resetting|disable device)' "no SATA errors" \
     "SATA error lines (boot SSDs)" "check /proc/mdstat and smartctl -x on the boot SSD named in the lines"
kchk warn 'mpt3sas.*(fault|reset)|task abort|device reset occurred' "no SAS resets/aborts" \
     "SAS reset/abort lines (also logged at boot-time discovery)" "ignore if from a reboot; otherwise check the disk/expander in the lines"
kchk warn 'device-mapper: multipath.*[Ff]ailing path|remaining active paths: 0' "no multipath path failures" \
     "multipath path-failure lines" "check cable/expander for the failing paths; multipath -ll"
kchk warn 'blocked for more than|hung_task' "no hung tasks" \
     "hung-task lines" "look at the stack in the lines (txg_sync, nfsd, z_*) and pool/disk latency (zpool iostat -vl)"
kchk info 'WC error' "no RDMA WC errors" "RDMA WC error lines (known mlx5 'remote access error' issue)" ""

# ======================================================================
if [ "$REBASE" -eq 1 ] || [ -z "$B_MP_MAPS" ]; then
  B_MP_MAPS=$MP_MAPS; B_MP_PATHS=$MP_PATHS; B_HBA_12G=$HBA_12G
  info "baseline recorded: maps=$MP_MAPS paths=$MP_PATHS hba_12g=$HBA_12G"
fi
cat > "$STATE" <<EOF
B_KERNEL="$KERNEL"
B_ZFSVER="$ZFSVER"
B_MP_MAPS="$B_MP_MAPS"
B_MP_PATHS="$B_MP_PATHS"
B_HBA_12G="$B_HBA_12G"
EOF

# ======================================================================
case $RC in 0) ST=OK ;; 1) ST=WARN ;; *) ST=FAIL ;; esac
HEAD="zfs-healthcheck $HOST $(date '+%F %T'): $ST ($NF fail, $NW warn)"
{
  echo "$HEAD"
  echo "$REPORT"
  if [ -n "$EVIDENCE" ]; then
    echo "== Evidence and suggested fix per tag"
    echo "$EVIDENCE"
  fi
} > "$LOGF"
find "$LOG_DIR" -name '*.txt' -mtime +90 -delete 2>/dev/null

echo "$HEAD"
if [ "$QUIET" -eq 1 ]; then
  echo "$REPORT" | awk '/^== /{h=$0; next} /  (WARN|FAIL) /{if (h) {print ""; print h; h=""} print}'
else
  echo "$REPORT"
fi
if [ "$RC" -gt 0 ]; then
  echo ""
  echo "Evidence (command output) and suggested fix for each [F#]/[W#]:"
  echo "  $LOGF      e.g.  sed -n '/^---- \\[F1\\]/,/^---- /p' $LOGF"
fi
logger -t zfs-healthcheck "$HEAD (report: $LOGF)" 2>/dev/null
if [ "$RC" -gt 0 ] && [ -n "$MAILTO" ] && command -v mail >/dev/null 2>&1; then
  mail -s "$HEAD" "$MAILTO" < "$LOGF"
fi
exit "$RC"
