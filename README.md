# ZFS Group Object Quota Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Storage: OpenZFS](https://img.shields.io/badge/Storage-OpenZFS-blue.svg)](https://openzfs.org/)

Utility for HPC-style environments to set **per-group inode (object) quotas** on a ZFS dataset. The script ties a group’s **object limit** to the dataset’s **space** `quota` using a **base + incremental** model, optionally bumps the target when current usage is high, then **reconciles** with the **existing** `groupobjquota` so routine runs do not thrash the limit.

The implementation lives in [`zfs-set-group-quota.sh`](zfs-set-group-quota.sh).

This repository also holds the ORCD storage-server tooling: [shared pool provisioning](#shared-pool-provisioning) (`zfs-make-share-pool.sh`) and [new-server dRAID pool creation with a special vdev](#new-storage-server-draid-pool-with-a-special-vdev) (`zfs-draid.sh`).

---

## Purpose

Large file counts can stress metadata and hurt performance. This script sets **`groupobjquota@<group>`** (object count cap for that POSIX group on the dataset), derived from configured **storage** quota—not a substitute for space quotas, but a coordinated limit on objects (files, directories, etc.).

---

## Usage

```bash
sudo ./zfs-set-group-quota.sh <dataset> <groupname> [optional_object_limit]
```

| Argument | Required | Meaning |
|----------|----------|---------|
| `dataset` | Yes | ZFS dataset path. |
| `groupname` | Yes | Group name; must exist (`getent group`). |
| `optional_object_limit` | No | If set, used as **q(n)** (see below), skipping automatic calculation. |

Example:

```bash
sudo ./zfs-set-group-quota.sh tank/project/data mygroup
```

---

## Prerequisites

- **Root** (script checks `EUID`).
- **`zfs`** on the host; dataset must exist and have a non-zero **`quota`** when using automatic mode.
- **`getent`** for group lookup.
- Automatic mode uses **`zfs groupspace`** to read **`objused`** for the named group (safety buffer path).

---

## How the value is computed

Processing is in two phases: first **q(n)** (the recalculated target), then **reconciliation** against **q(e)** (what is already set).

### Phase A — q(n)

**1. Manual mode** (third argument present)

- **q(n)** = that integer.

**2. Automatic mode**

1. Read dataset **`quota`** in bytes (`zfs get -p`). If `none` or zero, the script exits with an error.
2. **Ceiling TiB**: round storage up to whole **tebibytes** using 1 TiB = `1,099,511,627,776` bytes (same integer ceiling as the script).
3. **Calculated cap (before usage check):**

   `CALC_QUOTA = 1,000,000 + (rounded_TiB × 100,000)`

   So every allocation gets a **1,000,000** object floor, plus **100,000** objects per tebibyte of quota.

4. **Safety buffer:** `zfs groupspace` is queried for **`objused`** for `groupname` on that dataset. If **`objused` > `CALC_QUOTA`**, then:

   **q(n) = floor(objused × 110 / 100)** (10% headroom over current usage, integer arithmetic).

   Otherwise **q(n) = CALC_QUOTA**.

If the group has no row yet, usage is treated as **0**.

### Phase B — q(e) and final quota

**q(e)** is the current **`groupobjquota@<groupname>`** on the dataset. Unset, `-`, or `none` is treated as **0**.

| Condition | Final `groupobjquota` |
|-----------|------------------------|
| **q(e) ≥ q(n) × 1.1** | **q(e)** (keep existing). |
| **q(e) ≤ q(n) × 0.9** | **q(n)**. |
| Otherwise | **q(e) × 1.1**, truncated toward zero (`q(e) * 11 / 10` in bash). |

Equivalently: `10×q(e) ≥ 11×q(n)` → keep **q(e)**; `10×q(e) ≤ 9×q(n)` → **q(n)**; else the third branch.

The script prints which branch ran, then runs **`zfs set groupobjquota@…`**.

---

## Reference table (CALC_QUOTA only, no safety override)

These are **q(n)** when usage is **not** above `CALC_QUOTA` and no manual override is used.

| Storage quota (ceiling TiB) | CALC_QUOTA (objects) |
|----------------------------|----------------------|
| 1 TiB | 1,100,000 |
| 10 TiB | 2,000,000 |
| **20 TiB** | **3,000,000** |
| **40 TiB** | **5,000,000** |

In this environment, **new or extended allocations are often at least 20 TiB**, so a typical first **q(n)** from the formula alone is **3,000,000** objects at 20 TiB—unless the safety buffer raises it because **`objused` > CALC_QUOTA**.

---

## Worked examples (hysteresis, 20 TiB–style sizes)

Assume automatic mode, usage **below** `CALC_QUOTA` so **q(n)** equals the table above (no safety bump).

1. **First run, no quota set yet**  
   **20 TiB** quota → **q(n) = 3,000,000**. **q(e) = 0** → second branch → final **3,000,000**.

2. **Quota grows 20 → 40 TiB**  
   **q(n) = 5,000,000**; **q(e) = 3,000,000**.  
   3,000,000 ≤ 0.9 × 5,000,000 = 4,500,000 → final **5,000,000**.

3. **Existing quota already ≥ 10% above q(n)**  
   **q(n) = 3,000,000**; **q(e) = 4,000,000**.  
   1.1 × q(n) = 3,300,000 → keep **4,000,000**.

4. **Middle band**  
   **q(n) = q(e) = 3,000,000**.  
   Between 2,700,000 and 3,300,000 → third branch → **3,000,000 × 11 / 10 = 3,300,000**.

---

## Verification

```bash
zfs groupspace <dataset>
zfs get groupobjquota@<group_name> <dataset>
zfs groupspace -o name,objused,objquota <dataset>
```

---

## Shared pool provisioning

[`zfs-make-share-pool.sh`](zfs-make-share-pool.sh) creates a **5 TiB shared ZFS dataset** for a PI on the ORCD storage cluster, ensures the Moira group is visible locally, and applies inode quotas via [`zfs-set-group-quota.sh`](zfs-set-group-quota.sh).

### Where to run it

The script is installed on **`mgmt001`** at:

```text
/root/bin/zfs-make-share-pool.sh
```

**Run it from `mgmt001`** (SSH to that host first). It SSHes to storage hosts and reaches LDAP helpers via `admin001`; it is not intended to be copied elsewhere or run from a laptop without equivalent access.

### Usage

```bash
/root/bin/zfs-make-share-pool.sh <PiKerbName>
```

| Argument | Required | Meaning |
|----------|----------|---------|
| `PiKerbName` | Yes | PI Kerberos username (no `pi_` prefix). |

Example:

```bash
/root/bin/zfs-make-share-pool.sh jdoe
```

This provisions dataset `<pool>/<PiKerbName>_shared` with group `orcd_rg_shared_pi_<PiKerbName>`.

### Prerequisites

- Run on **`mgmt001`** as a user that can:
  - SSH to configured storage hosts (`hstor013-n2`, `hstor012-n2`, … — see script `hstors` array).
  - SSH to **`admin001`**, which in turn reaches **`ldap001`** for Moira LDAP helpers.
  - Query **`ldap.mit.edu`** for the shared group `orcd_rg_shared_pi_<PiKerbName>` (group must already exist in Moira before the script runs).
- The PI must **not** already have a `<PiKerbName>_shared` dataset on any configured host.
- If the PI has a personal pool on one host, that host is chosen; otherwise a host is picked at random from `hstors`.

### What the script does

1. Verifies `<PiKerbName>_shared` does not already exist.
2. Selects the target storage server (`DZSRV`).
3. Confirms `orcd_rg_shared_pi_<PiKerbName>` exists in `ldap.mit.edu`.
4. Adds the group to local Moira LDAP on `ldap001` if `getent group` does not yet see it.
5. Creates the ZFS dataset, sets **5T** space quota, `chmod 2770`, and `chown root:orcd_rg_shared_pi_<PiKerbName>`.
6. Runs **`zfs-set-group-quota.sh`** on the storage host for inode limits.

---

## New storage server: dRAID pool with a special vdev

[`zfs-draid.sh`](zfs-draid.sh) is run **on a new ZFS storage server** (RHEL, OpenZFS ≥ 2.1, `device-mapper-multipath`). It has two modes:

1. **Assessment** (no arguments) — read-only. Inventories multipath HDDs and NVMe, checks which special-vdev layouts fit, and prints ranked, copy/paste deployment commands. It never changes host configuration.
2. **Create** (`<vendor_pattern> [total_hdd_count]`) — builds the `zpool create` command, shows the full layout, asks for confirmation, creates the pool, then applies the ORCD follow-ups (encrypted `<pool>/orcd` dataset if a key exists, monthly scrub timer, backup of script + key).

The priority is a **dRAID data pool with a mirrored NVMe special vdev** (metadata / small blocks). Without it metadata lives on HDD and directory-heavy HPC workloads suffer.

### Where to run it

Copy the script to the storage host and run it there **as root** (device sizes, `blkid` probing and `multipath` queries need root):

```bash
scp zfs-draid.sh hstor0NN-n1:/root/
ssh hstor0NN-n1
cd /root && chmod +x zfs-draid.sh
```

The pool name is derived from the hostname: a name ending in `n1-mgmt` → `data1`, `n2-mgmt` → `data2` (e.g. `hstor004-n1-mgmt` → `data1`); **any other hostname → `data1`**. Set `POOL=` to override. Create and dry-run runs **always ask you to verify the name** before touching anything:

```text
Pool name:         data1   (source: hostname 'hstor004-n1-mgmt' ends with n1-mgmt)
Verify pool name — press Enter to keep 'data1', or type another name:
```

Enter keeps it, typing a name replaces it (validated as a legal pool name), and a name that already exists in `zpool list` is refused. `SKIP_CONFIRM=1` or a non-interactive stdin accepts the default silently.

### Step 1 — assess

```bash
./zfs-draid.sh            # or: ./zfs-draid.sh --assess
```

The report (also saved to `/tmp/zfs-orcd-assess-<host>-<ts>.log`) shows existing pools, an HDD table (vendor / product / size / total / free), NVMe split into *unused* and *in use*, which special layouts fit, and a ranked list such as:

```text
[1] RECOMMENDED — dRAID3 + special mirror10
    Data:     78× 18.19 TiB SEAGATE  →  3 × draid3:9d:26c:2s
    Aux:      2× NVMe SLOG mirror + 2× NVMe L2ARC
    Special:  mirror10 — 10× mirror (20 NVMe)  (69.86 TiB usable)
    Usable:   ~982 TiB data
    Create:   POOL=data1 ./zfs-draid.sh --special=mirror10 SEAGATE 78
    Dry-run:  POOL=data1 DRY_RUN=1 ./zfs-draid.sh --special=mirror10 SEAGATE 78

[2] RECOMMENDED (extra redundancy) — dRAID3 + special mirror3x6+2spare
    Special:  6× 3-way mirror (18 NVMe) + 2 pool hot spares  (41.92 TiB usable)
    Create:   POOL=data1 ./zfs-draid.sh --special=mirror3x6+2spare SEAGATE 78
```

A disk counts as *unused* only if it has no filesystem, no partition table, no ZFS label, no mount and no LVM/md/LUKS holder — so the OS NVMe is never offered as SLOG/special.

### Step 2 — dry run

Paste the `Dry-run:` line. It performs the full discovery, prints every device per vdev and the exact shell-quoted `zpool create`, writes the log preamble, and exits **without** touching multipath configuration or creating anything. Check the layout, especially that the special mirror pairs are the intended NVMe model.

### Step 3 — create

Drop `DRY_RUN=1`:

```bash
POOL=data1 ./zfs-draid.sh --special=mirror10 SEAGATE 78
```

The script applies `mpathconf --enable --user_friendly_names n`, restarts `multipathd` and reloads the maps (`multipath -r`) so every map is WWID-named (skip with `SKIP_MPATH_MPATHCONF=1`), refuses to continue if any selected data disk looks in use (list is printed; `ZPOOL_FORCE=1` overrides and adds `-f`), shows the layout, and asks `Confirm to run this zpool create? [y/N]` (`SKIP_CONFIRM=1` for automation). The full session log lands in `/var/log/zfs-orcd/` (falls back to `/tmp`).

### Multipath naming — WWIDs, never `mpathX`

The HDDs sit behind multipath, and the pool is always built on the **multipath maps addressed by WWID**, i.e. `/dev/mapper/35000c500f3d79da3` — the same names the hand-built command produces:

```bash
multipath -l | grep SEAGATE | sort -t '-' -k 2 -n | awk '{print $1 " \\"}'
```

The script matches that in three ways: it forces `user_friendly_names n` (so map names are WWIDs, not `mpatha`…), it hands `zpool create` the **bare WWID** (`35000c500d84e2553`, no `/dev/mapper/` prefix) so `zpool status` shows exactly that, and it orders members by dm number (`MPATH_SORT=dm`, same as `sort -t '-' -k 2 -n`), so vdev membership is identical to the manual layout. Single-path `wwn-0x…`/`scsi-…` links are never used.

NVMe members (log, cache, special, spares) are named `nvme-<Model>_<SN>` — the udev by-id link, e.g. `nvme-MTFDLAL7T6THG-1BP1DFCYY_112611AE997D` for the disk `nvme list` shows as model `MTFDLAL7T6THG-1BP1DFCYY`, SN `112611AE997D`. The duplicate `nvme-eui.…` and `nvme-<Model>_<SN>_1` links for the same disk are never chosen. OpenZFS resolves these short names through `/dev/mapper` and `/dev/disk/by-id` itself; `ZPOOL_DEV_NAMES=full` switches back to absolute paths. Discovery and the in-use checks always work on the resolved full paths, which the layout printout shows in parentheses.

If maps are still aliased when the create command runs (e.g. in `DRY_RUN=1`, which does not change host config), the script stops and prints the fix:

```bash
mpathconf --enable --user_friendly_names n && systemctl restart multipathd && multipath -r
# if aliases persist: multipath -F && multipath -r  (or reboot; see /etc/multipath/bindings)
```

The assessment report shows the current naming mode (`Map naming: WWID` or `mpathX aliases on N maps`).

### What gets created

| Part | Default |
|------|---------|
| Data | `total_hdd_count / DISKS_PER_VDEV` dRAID vdevs (default 26 wide). Layout auto-computed per vdev: parity `DRAID_PARITY` (3), profile `balanced` (≥2 redundancy groups, D≈8) and **at least 1 distributed spare** (`DRAID_MIN_SPARES`). 78 disks → `3 × draid3:9d:26c:2s`. Fix a literal with `DRAID_VDEV_SPEC=draid3:9d:26c:2s`. |
| Log / cache | 4 smallest unused NVMe: 2× SLOG mirror + 2× L2ARC. `SKIP_LOG_CACHE=1` to omit. |
| Special | Largest unused NVMe after log/cache; layouts via `--special=<layout>` (`--help-special`). Two recommended choices: `mirror10` (default; 10 mirror pairs, max special capacity) and `mirror3x6+2spare` (6× **3-way mirrors** + 2 hot spares — each mirror survives 2 NVMe failures; preferred when extra redundancy matters more than capacity). Others: `mirror9+2spare`, `mirror8`, `mirror5`, and raidz variants (not recommended). `SPECIAL_PATTERN=7600` restricts to one model. |
| Pool props | `ashift=12 autoexpand=on autoreplace=on autotrim=on`, `acltype=posixacl xattr=sa dnodesize=auto atime=off compression=lz4 dedup=off` (`ZFS_ATIME=on` to change). |

**About `zpool create -f`:** OpenZFS refuses a pool whose top-level vdevs differ in redundancy — *mismatched replication level: draid and mirror vdevs with different redundancy, 3 vs. 1* — unless `-f` is given. dRAID3 data plus a 2-way-mirrored NVMe special vdev is exactly that (and the intended design), so the script adds `-f` automatically whenever the special layout's redundancy is below the dRAID parity and prints a note saying so. This does not weaken safety: the script's own in-use check on every selected device runs before `zpool create`. Log devices are exempt from the check; `raidz3x20` or `DRAID_PARITY=2` with `mirror3x6+2spare` need no `-f`.

After creation, turn on small-block placement per dataset only when measured: `zfs set special_small_blocks=16K data1/<dataset>`.

### Reading the dRAID notation

`draid3:9d:26c:2s` is OpenZFS's `draid<P>:<D>d:<C>c:<S>s`:

| Field | Meaning | In `draid3:9d:26c:2s` |
|-------|---------|------------------------|
| `draid<P>` | parity per redundancy group (like raidz*P*) | 3 — each group survives 3 simultaneous failures |
| `<D>d` | **data** disks per redundancy group; a stripe spans D + P disks | 9 data + 3 parity = 12-disk stripes |
| `<C>c` | **children**: physical disks in this vdev | 26 |
| `<S>s` | **distributed spares**: spare capacity spread over all children for fast in-place rebuild | 2 |

Constraint: `(C − S)` must be a multiple of `(D + P)`; here (26 − 2) / 12 = 2 groups per vdev, so a 26-disk vdev holds 18 data-disk equivalents. The assessment chooses the vdev width (8…`DRAID_MAX_WIDTH`, default 40) that gives the most usable capacity, then prefers ~8-disk data stripes, two groups per vdev, and the proven 26 width; leftover HDDs are proposed as pool hot spares (`HDD_SPARE_COUNT`). Example: 106 HDDs → `4 × draid3:9d:26c:2s` + 2 hot spares. It never proposes one huge vdev (e.g. `draid3:32d:106c:1s`, whose 32-wide stripes waste space on small blocks and leave a single spare for 106 disks).

### Options and environment

| Setting | Meaning |
|---------|---------|
| `-A, --assess` | Force the read-only report. |
| `-S, --special[=layout]` / `SPECIAL=Y\|layout` | Enable the special vdev (default `mirror10`). |
| `DATA_DISK_SOURCE=mpath\|nvme` | Multipath HDDs (default) or all-flash NVMe data disks (no special vdev in that mode). |
| `DRAID_PARITY=2\|3` | dRAID parity (default 3). |
| `DRAID_PROFILE=balanced\|capacity` | Layout scoring; `capacity` maximises data disks with one wide group. |
| `DRAID_MIN_SPARES=0..2` | Minimum distributed spares per vdev (default 1; 0 only for pure capacity). |
| `DISKS_PER_VDEV=N` | Children per dRAID vdev (default 26; the assessment prints it when it differs). |
| `HDD_SPARE_COUNT=N` | Extra matched HDDs (taken after the data disks) added as pool hot spares. |
| `DRAID_MAX_WIDTH=N` | Widest vdev the assessment will propose (default 40). |
| `DRY_RUN=1` | Discovery + command + log only. |
| `POOL=name` | Pool name (default from hostname rule above; always verified interactively). |
| `SKIP_CONFIRM=1` | No interactive prompts (pool-name verification and the final zpool create confirmation). |
| `ZPOOL_FORCE=1` | Pass `-f` after the in-use pre-check warns. |
| `MPATH_SORT=dm\|wwid` | Member order: by dm number (default, matches `sort -t '-' -k 2 -n`) or by WWID. |
| `ZPOOL_DEV_NAMES=short\|full` | Member names passed to zpool: bare WWID / `nvme-<Model>_<SN>` (default) or absolute paths. |
| `MPATH_DEV_DIR=/dev/mapper` | Directory used to resolve and verify multipath members. |
| `SKIP_MPATH_MPATHCONF=1`, `MPATH_USER_FRIENDLY_NAMES=1` | Leave multipath config alone / tolerate `mpathX` aliases (not recommended; members then go via `dm-uuid-mpath-<WWID>`). |
| `POOL_SETUP_LOG=path`, `ORCD_BACKUP_DEST=host:/path/` | Log file; rsync target for script + key (empty string disables). |

### Adding a special vdev to an existing pool

If a pool already exists without a special vdev and ≥10 NVMe are unused, the assessment prints a ready `zpool add <pool> special mirror …` line. Preview with `zpool add -n` first. Remember that **losing an entire special vdev loses the pool** — always use mirrors in production.

---

## Other tools

- [`zfs-make-pool.sh`](zfs-make-pool.sh) — generic personal/group pool provisioning (storage host, size, and PI supplied as arguments).

---

## License

See [LICENSE](LICENSE).
