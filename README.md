# ZFS Group Object Quota Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Storage: OpenZFS](https://img.shields.io/badge/Storage-OpenZFS-blue.svg)](https://openzfs.org/)

Utility for HPC-style environments to set **per-group inode (object) quotas** on a ZFS dataset. The script ties a group’s **object limit** to the dataset’s **space** `quota` using a **base + incremental** model, optionally bumps the target when current usage is high, then **reconciles** with the **existing** `groupobjquota` so routine runs do not thrash the limit.

The implementation lives in [`zfs-set-group-quota.sh`](zfs-set-group-quota.sh).

This repository also holds the ORCD storage-server tooling: [shared pool provisioning](#shared-pool-provisioning) (`zfs-make-share-pool.sh`), [new-server pool creation with a special vdev](#new-storage-server-zfs-pool-with-a-special-vdev) (`zfs-pool-setup.sh`; `zfs-draid.sh` is a symlink), and [seeding a new pool for lab tests](#seed-a-new-pool-for-lab-tests) (`zfs-blockclone.sh`).

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

## New storage server: ZFS pool with a special vdev

[`zfs-pool-setup.sh`](zfs-pool-setup.sh) is run **on a new ZFS storage server** (RHEL, OpenZFS ≥ 2.1 for dRAID, `device-mapper-multipath`). [`zfs-draid.sh`](zfs-draid.sh) is a compatibility symlink to the same script (create default remains dRAID). Two modes:

1. **Analyze** (no arguments, or `--analyze`; `--assess` is an alias) — read-only. Inventories multipath HDDs and NVMe, checks which special-vdev layouts fit, and prints ranked, copy/paste commands to create a new pool. It never changes host configuration.
2. **Create** (`[--raidz3|--raidz2|--draid] <vendor_pattern> [total_hdd_count]`) — builds the `zpool create` command, shows the full layout, asks for confirmation, creates the pool, then applies the ORCD follow-ups (encrypted `<pool>/orcd` dataset if a key exists, monthly scrub timer, backup of script + key).

The priority is **raidz3, then raidz2, then dRAID**, each **with a mirrored NVMe special vdev** (metadata / small blocks) when unused NVMe exist. Without a special vdev, metadata lives on HDD and directory-heavy HPC workloads suffer. 78 HDDs → `6 × raidz3` of 13 (classic) or `3 × draid3` of 26.

### Where to run it

Copy the script to the storage host and run it there **as root** (device sizes, `blkid` probing and `multipath` queries need root):

```bash
scp zfs-pool-setup.sh hstor0NN-n1:/root/
ssh hstor0NN-n1
cd /root && chmod +x zfs-pool-setup.sh
```

The pool name is derived from the hostname: a name ending in `n1-mgmt` → `data1`, `n2-mgmt` → `data2` (e.g. `hstor004-n1-mgmt` → `data1`); **any other hostname → `data1`**. Set `POOL=` to override. Create and dry-run runs **always ask you to verify the name** before touching anything:

```text
Pool name:         data1   (source: hostname 'hstor004-n1-mgmt' ends with n1-mgmt)
Verify pool name — press Enter to keep 'data1', or type another name:
```

Enter keeps it, typing a name replaces it (validated as a legal pool name). If a pool with that name already exists, the script offers to destroy and clean it up first (see below). `SKIP_CONFIRM=1` or a non-interactive stdin accepts the default silently.

### Step 1 — analyze

```bash
./zfs-pool-setup.sh            # or: ./zfs-pool-setup.sh --analyze
./zfs-draid.sh --analyze       # same script; --assess is an alias
```

The report (also saved to `/tmp/zfs-orcd-assess-<host>-<ts>.log`) shows existing pools, an HDD table (vendor / product / size / total / free), NVMe split into *unused* and *in use*, which special layouts fit, and a ranked list of **create-a-new-pool** options. **raidz3 and raidz2 with a special vdev are first**; dRAID follows as an alternative. Example:

```text
--- raidz3 (78 data disks → 6 × raidz3 of 13; leftover 0 spare) ---
[1] RECOMMENDED — raidz3 + special mirror5 (10 NVMe, 2-way mirrors) + L2ARC
    Data:     78× 18.19 TiB SEAGATE  →  6 × raidz3 of 13  (3 parity, 10 data per vdev)
    Aux:      2× NVMe SLOG mirror + 2× NVMe L2ARC
    Special:  mirror5 — 5× mirror pair (10 NVMe)
    Create:   POOL=data1 ./zfs-pool-setup.sh --raidz3 --special=mirror5 SEAGATE 78
    Dry-run:  POOL=data1 DRY_RUN=1 ./zfs-pool-setup.sh --raidz3 --special=mirror5 SEAGATE 78

--- raidz2 ---
[n] RECOMMENDED — raidz2 + special mirror5 …

--- dRAID (distributed parity; sequential rebuild) ---
[n] ALTERNATIVE — dRAID3 + special mirror5 …
    Data:     78× 18.19 TiB SEAGATE  →  3 × draid3:9d:26c:2s
    Create:   POOL=data1 ./zfs-pool-setup.sh --draid --special=mirror5 SEAGATE 78
    Dry-run:  POOL=data1 DRY_RUN=1 ./zfs-pool-setup.sh --draid --special=mirror5 SEAGATE 78
```

A disk counts as *unused* only if it has no filesystem, no partition table, no ZFS label, no mount and no LVM/md/LUKS holder — so the OS NVMe is never offered as SLOG/special. Multipath path slaves under a map are not treated as “in use”; those are the SAS paths, not a stacked filesystem.

### Is a second JBOD present?

On the storage host, as root. Count **unique maps**, not every `multipath` line, and do not treat two enclosure devices as two shelves:

```bash
multipath -l | awk '/dm-[0-9]+/ && /SEAGATE/ && !/^ / {c++} END {print c}'
lsscsi | awk '/disk/ && /SEAGATE/ {split($1,a,":"); gsub(/[[]/,"",a[1]); h[a[1]]++} END {for (i in h) print "host", i, h[i]}'
sg_inq /dev/sg11; sg_inq /dev/sg124
```

One `SP-34106` shelf is **106** unique HDD maps, seen on both SAS hosts (two paths into the same disks). Two enclosure LUNs with the same `sg_inq` serial are that dual path, not a second box. A second physical JBOD adds about another 106 unique maps. `sg_ses -p 0xa` does not show slot occupancy on this firmware — both a full shelf and an empty path list the same 106 indexes with `eiioe=0`. Analyze uses the unique map count for the `Second JBOD: YES/NO` verdict.

### Step 2 — dry run

Paste the `Dry-run:` line. It performs the full discovery, prints every device per vdev and the exact shell-quoted `zpool create`, writes the log preamble, and exits **without** touching multipath configuration or creating anything. Check the layout, especially that the special mirror pairs are the intended NVMe model.

### Step 3 — create

Drop `DRY_RUN=1`:

```bash
POOL=data1 ./zfs-pool-setup.sh --raidz3 --special=mirror5 SEAGATE 78
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

The analyze report shows the current naming mode (`Map naming: WWID` or `mpathX aliases on N maps`).

### What gets created

| Part | Default |
|------|---------|
| Data | `total_hdd_count / DISKS_PER_VDEV` dRAID vdevs (default 26 wide). Layout auto-computed per vdev: parity `DRAID_PARITY` (3), profile `balanced` (≥2 redundancy groups, D≈8) and **at least 1 distributed spare** (`DRAID_MIN_SPARES`). 78 disks → `3 × draid3:9d:26c:2s`. Fix a literal with `DRAID_VDEV_SPEC=draid3:9d:26c:2s`. |
| Log / cache | Smallest unused NVMe: 2× SLOG mirror (`SLOG=Y`, default) + 2× L2ARC (`CACHE=Y`, default). `CACHE=N` drops the L2ARC — often the right choice on a 250 GB-RAM node with a special vdev; the 2 NVMe stay free. `SKIP_LOG_CACHE=1` = both off. |
| Special | Largest unused NVMe after log/cache. **Default: `SPECIAL_NVME_COUNT=10` NVMe** as `SPECIAL_MIRROR_WAY=2`-way mirrors → `mirror5`; the other NVMe stay free for a later `zpool add`. Generic layout syntax for `--special=`: `mirror<G>` (G pairs), `mirror3x<G>` (G **3-way** mirrors), optional `+<S>spare` — e.g. `mirror3x3+1spare` (10 NVMe, extra redundancy), `mirror10` / `mirror3x6+2spare` (all 20). Raidz variants exist but are not recommended. `SPECIAL_PATTERN=7600` restricts to one model. |
| Pool props | `ashift=12 autoexpand=on autoreplace=on autotrim=on`, `acltype=posixacl xattr=sa dnodesize=auto atime=off compression=lz4 dedup=off` (`ZFS_ATIME=on` to change). |

**About `zpool create -f`:** OpenZFS refuses a pool whose top-level vdevs differ in redundancy — *mismatched replication level* — unless `-f` is given. raidz3 or dRAID3 data plus a 2-way-mirrored NVMe special vdev is exactly that (and the intended design), so the script adds `-f` automatically whenever the special layout's redundancy is below the data-vdev parity and prints a note saying so. This does not weaken safety: the script's own in-use check on every selected device runs before `zpool create`. Log devices are exempt from the check. A 3-way-mirror special (`mirror3x…`, redundancy 2) still needs `-f` next to raidz3/dRAID3 (3 vs 2) but not next to raidz2/dRAID2; `raidz3x20` is the only special layout that never needs it.

### ARC sizing

The analyze report prints an **ARC sizing** block computed from the host's `MemTotal`. After a successful create (or `--tune`), that proposal is written to `/etc/modprobe.d/zfs.conf` only when the file is **absent** or already matches. If the file already exists and its values differ, the script leaves it untouched, does not change live `/sys` parameters, and writes the proposal plus a line-by-line comparison (what changed, and why) under `$HOME` as `zfs.conf.proposed-<host>-<timestamp>`. If the existing file already has the proposed values, it is left as-is and those values are applied live.

| Parameter | Default | Rationale |
|-----------|---------|-----------|
| `zfs_arc_max` | 60% of RAM (`ZFS_ARC_MAX_PCT`) | A little above the OpenZFS default of 50%; the remaining ~40% covers OS/NFS daemons, dirty data, L2ARC headers (~70 B per cached record, held in ARC), resilver headroom and any co-located services. |
| `zfs_arc_min` | 25% of RAM (`ZFS_ARC_MIN_PCT`) | Floor so the ARC is not squeezed away under transient pressure, while leaving room for the OOM-safe worst case. |
| `zfs_dirty_data_max` | 8 GiB when RAM ≥ 128 GiB (`ZFS_DIRTY_DATA_MAX`) | Larger write buffer so big NFS writes land as fuller 12-disk dRAID stripes per transaction group. |

The same file also carries scrub / metadata-cache tuning (`ZFS_SCRUB_TUNE=1`), each line written and applied only if the running OpenZFS has the parameter:

| Parameter | Default | Why |
|-----------|---------|-----|
| `zfs_scan_vdev_limit` | 128 MiB (`ZFS_SCAN_VDEV_LIMIT`) | Scrub/resilver I/O in flight **per top-level vdev** (OpenZFS default 4 MiB on 2.1, 16 MiB on 2.2+). A 104-HDD pool built as 4 × 26-wide dRAID has only four top-level vdevs, so the default caps a scrub near 1 GB/s regardless of disk count. |
| `zfs_vdev_scrub_max_active` | 8 (`ZFS_SCRUB_MAX_ACTIVE`) | Per-disk scrub queue depth (default 3). |
| `zfs_arc_dnode_limit_percent` | 40 (`ZFS_ARC_DNODE_LIMIT_PCT`) | Dnode cache as % of `arc_max` (default 10). On file-heavy datasets — especially with `dnodesize=auto` — the 10 % limit is hit during scrubs and the `arc_prune` kernel thread spins at high CPU. |

To apply the ARC + scrub tuning to a host whose pool already exists, run `./zfs-pool-setup.sh --tune` (`DRY_RUN=1` shows the values first). It uses the same non-clobber policy as after create.

For a 250 GB node that is about `zfs_arc_max` ≈ 140 GiB and `zfs_arc_min` ≈ 58 GiB (values are rounded down to whole GiB from the actual `MemTotal`). `ZFS_ARC_TUNE=0` skips both the system file and the `$HOME` proposal. Run `dracut -f` afterwards only if you install a new `zfs.conf` and the zfs module is in the initramfs. Metadata sits on the special vdev, so leave `zfs_arc_meta_balance` at its default; check `arcstat` `l2hit%` after a few weeks and repurpose the L2ARC NVMe as hot spares if it stays in single digits.

After creation, turn on small-block placement per dataset only when measured: `zfs set special_small_blocks=16K data1/<dataset>`.

### Special vdev size and the L2ARC question

Not every NVMe needs to go into the special vdev: metadata for a ~1.3 PiB pool is a few TB, so 10 NVMe (5 mirror pairs ≈ 35 TiB, or 3 triple mirrors ≈ 21 TiB) is plenty and the rest can be added later with `zpool add <pool> special mirror …` once real usage is known. Analyze therefore recommends the 10-NVMe layouts first, in both mirror widths, and prints every recommendation **with and without L2ARC** (`CACHE=N`); with ~140 GiB of ARC and metadata on NVMe, L2ARC rarely earns its two devices. Example for this hardware:

```text
[1] RECOMMENDED — dRAID3 + special mirror5 (10 NVMe, 2-way mirrors) + L2ARC
[2] RECOMMENDED — dRAID3 + special mirror5 (10 NVMe, 2-way mirrors), no L2ARC
[3] RECOMMENDED (extra redundancy) — dRAID3 + special mirror3x3+1spare (10 NVMe, 3-way mirrors) + L2ARC
[4] RECOMMENDED (extra redundancy) — dRAID3 + special mirror3x3+1spare (10 NVMe, 3-way mirrors), no L2ARC
    Create:   POOL=data1 HDD_SPARE_COUNT=2 CACHE=N ./zfs-pool-setup.sh --draid --special=mirror3x3+1spare SEAGATE 104
[5]…[8] ALTERNATIVE — all 20 eligible NVMe: mirror10 / mirror3x6+2spare, each with and without L2ARC
```

### Re-creating: destroying an existing pool with the same name

If a pool with the chosen name already exists (imported, or exported but still labelled), create mode shows its `zpool status` / `zfs list`, warns that **all data on it will be deleted**, and asks twice — a `y/N` question, then typing the pool name exactly. On confirmation it runs `zpool destroy -f`, then `zpool labelclear -f` and `wipefs -a` on every former member device (HDDs, NVMe special/log/cache/spares), disables the pool's scrub timer, logs everything to `/var/log/zfs-orcd/zfs-orcd-<pool>-destroy-<ts>.log`, and continues straight into the new create. Any other answer keeps the pool and exits. `DRY_RUN=1` never destroys anything: it reports the existing pool, treats its members as free so the dry run can show the new layout, and reminds you a real run will ask. For automation, `DESTROY_EXISTING=1 SKIP_CONFIRM=1` destroys without prompting.

**NVMe are discarded, not just unlabelled.** `zpool labelclear` and `wipefs` only erase the ZFS labels and signatures; the flash still holds every block the old pool wrote (visible as `Usage` in `nvme list`, e.g. ~300 GB per former special-vdev member). The script therefore runs `blkdiscard` (whole-device TRIM) on every former SSD member after a destroy and on every NVMe member right before `zpool create` (`DISCARD_NVME=1`, default), so a new pool always starts on clean flash. HDDs have no discard support and are skipped. To clean up NVMe left behind by an earlier destroy, run the standalone mode, which lists every unused NVMe (never a partitioned/mounted/labelled one), asks `y/N` and then for the word `WIPE`, and shows `nvme list` before and after:

```bash
./zfs-pool-setup.sh --wipe-nvme
```

```bash
# test cycle: dRAID3 9d:26c:2s + 3-way-mirror special, then destroy and rebuild
POOL=data1 HDD_SPARE_COUNT=2 ./zfs-pool-setup.sh --draid --special=mirror3x6+2spare SEAGATE 104
POOL=data1 HDD_SPARE_COUNT=2 CACHE=N ./zfs-pool-setup.sh --draid --special=mirror3x3+1spare SEAGATE 104   # asks to destroy data1 first
```

### Reading the dRAID notation

`draid3:9d:26c:2s` is OpenZFS's `draid<P>:<D>d:<C>c:<S>s`:

| Field | Meaning | In `draid3:9d:26c:2s` |
|-------|---------|------------------------|
| `draid<P>` | parity per redundancy group (like raidz*P*) | 3 — each group survives 3 simultaneous failures |
| `<D>d` | **data** disks per redundancy group; a stripe spans D + P disks | 9 data + 3 parity = 12-disk stripes |
| `<C>c` | **children**: physical disks in this vdev | 26 |
| `<S>s` | **distributed spares**: spare capacity spread over all children for fast in-place rebuild | 2 |

Constraint: `(C − S)` must be a multiple of `(D + P)`; here (26 − 2) / 12 = 2 groups per vdev, so a 26-disk vdev holds 18 data-disk equivalents. Analyze chooses the vdev width (8…`DRAID_MAX_WIDTH`, default 40) that gives the most usable capacity, then prefers ~8-disk data stripes, two groups per vdev, and the proven 26 width; leftover HDDs are proposed as pool hot spares (`HDD_SPARE_COUNT`). Example: 106 HDDs → `4 × draid3:9d:26c:2s` + 2 hot spares. It never proposes one huge vdev (e.g. `draid3:32d:106c:1s`, whose 32-wide stripes waste space on small blocks and leave a single spare for 106 disks).

### Options and environment

| Setting | Meaning |
|---------|---------|
| `-A, --analyze` | Read-only report of free disks and ranked create commands. Also the default when no vendor pattern is given. `--assess` is an alias. |
| `-S, --special[=layout]` / `SPECIAL=Y\|layout` | Enable the special vdev (default: `SPECIAL_NVME_COUNT` NVMe as `SPECIAL_MIRROR_WAY`-way mirrors → `mirror5`). |
| `SPECIAL_NVME_COUNT=N`, `SPECIAL_MIRROR_WAY=2\|3` | Size/width of the default special layout (10 / 2). |
| `SLOG=Y\|N`, `CACHE=Y\|N` | SLOG mirror / L2ARC on the smallest NVMe (defaults Y; `CACHE=N` common). |
| `DESTROY_EXISTING=1` | With `SKIP_CONFIRM=1`: destroy an existing same-name pool without prompting. |
| `--wipe-nvme`, `DISCARD_NVME=1\|0` | Standalone TRIM of all unused NVMe; whether create/destroy discard NVMe members (default 1). |
| `DATA_DISK_SOURCE=mpath\|nvme` | Multipath HDDs (default) or all-flash NVMe data disks (no special vdev in that mode). |
| `--raidz3`, `--raidz2`, `--draid` / `RAID_TOPOLOGY=` | Data vdev topology (analyze lists all; create default is dRAID). raidz* default width 13 (78 HDDs → 6 vdevs). |
| `DRAID_PARITY=2\|3` | dRAID parity (default 3). Ignored for raidz*. |
| `DRAID_PROFILE=balanced\|capacity` | Layout scoring; `capacity` maximises data disks with one wide group. |
| `DRAID_MIN_SPARES=0..2` | Minimum distributed spares per vdev (default 1; 0 only for pure capacity). |
| `DISKS_PER_VDEV=N` | Children per data vdev (dRAID default 26; raidz default 13). Validated: raidz2 ≥ 4, raidz3 ≥ 5, dRAID ≥ parity+2; a warning is printed above the sanity limit (`DRAID_MAX_WIDTH` 40, `RAIDZ_MAX_WIDTH` 15, raidz2 capped at 13 in analyze). |
| `HDD_SPARE_COUNT=N` | Extra matched HDDs (taken after the data disks) added as pool hot spares. |
| `DRAID_MAX_WIDTH=N` | Widest vdev analyze will propose (default 40). |
| `ZFS_ARC_TUNE=1\|0`, `ZFS_ARC_MAX_PCT`, `ZFS_ARC_MIN_PCT`, `ZFS_DIRTY_DATA_MAX` | After create, write ARC sizing to `/etc/modprobe.d/zfs.conf` only if that file is absent (defaults 1 / 60 / 25 / 8 GiB). A differing existing file is left alone; the proposal and the comparison go to `$HOME/zfs.conf.proposed-<host>-<ts>`. |
| `--tune`, `ZFS_SCRUB_TUNE=1\|0`, `ZFS_SCAN_VDEV_LIMIT`, `ZFS_SCRUB_MAX_ACTIVE`, `ZFS_ARC_DNODE_LIMIT_PCT` | Scrub / dnode-cache tuning in the same file (128 MiB / 8 / 40); `--tune` applies ARC + scrub tunables on a running host using the same non-clobber policy. |
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

If a pool already exists without a special vdev and ≥10 NVMe are unused, analyze prints a ready `zpool add <pool> special mirror …` line. Preview with `zpool add -n` first. Remember that **losing an entire special vdev loses the pool** — always use mirrors in production.

---

## Seed a new pool for lab tests

[`zfs-blockclone.sh`](zfs-blockclone.sh) copies a dataset onto a newly provisioned pool (after [`zfs-pool-setup.sh`](zfs-pool-setup.sh)) so you can time NFS/client I/O, **scrub**, and **resilver**. It also has optional same-pool **block cloning** (OpenZFS BRT / `copy_file_range`) to make extra working copies without rewriting payload blocks.

Block cloning cannot copy between servers or between pools. Migration is `zfs send | zfs recv` or an NFS `rsync`. Both write **unique** blocks on the new pool — that is the seed you want for scrub/resilver. `clone-tree` afterwards **shares** those blocks (`USED` stays small) and does **not** add resilver work; use `copy-tree` for a second unique copy that fills capacity.

### Where to run it

Copy the script to the **new** storage host and run it there as root:

```bash
scp zfs-blockclone.sh hstor0NN-n1:/root/
ssh hstor0NN-n1
cd /root && chmod +x zfs-blockclone.sh
./zfs-blockclone.sh check --pool data1
```

### Seed without SSH (NFS already mounted)

If the old dataset is NFS-mounted on the new server:

```bash
./zfs-blockclone.sh seed --mode rsync --src /mnt/old/proj --dst data1/lab/gold/proj
```

### Seed with zfs send (faster, preserves properties)

**Pull** (run on NEW) needs passwordless SSH **NEW → OLD**, not the other way around:

```bash
# on NEW as root, once
[[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
ssh-copy-id -i /root/.ssh/id_ed25519.pub root@OLD
ssh -o BatchMode=yes root@OLD 'hostname; zfs list -H -o name | head'

./zfs-blockclone.sh check --pool data1 --ssh root@OLD
./zfs-blockclone.sh seed --src root@OLD:data1/proj --dst data1/lab/gold/proj
```

**Push** (run on OLD) needs SSH **OLD → NEW**:

```bash
./zfs-blockclone.sh seed --src data1/proj --dst root@NEW:data1/lab/gold/proj
```

Full SSH notes: `./zfs-blockclone.sh ssh-help`.

### Scrub / resilver vs extra namespaces

```bash
# unique working copy (USED ≈ REFER) — scrub/resilver load
./zfs-blockclone.sh prep-dst data1/lab/work/proj --like data1/lab/gold/proj
./zfs-blockclone.sh copy-tree data1/lab/gold/proj data1/lab/work/proj

# cheap extra namespace (USED << REFER) — not extra unique data
./zfs-blockclone.sh clone-tree data1/lab/gold/proj data1/lab/clone/proj

./zfs-blockclone.sh verify data1/lab/gold/proj data1/lab/work/proj --sample 50
./zfs-blockclone.sh stats data1
```

---

## Other tools

- [`zfs-make-pool.sh`](zfs-make-pool.sh) — generic personal/group pool provisioning (storage host, size, and PI supplied as arguments).

---

## License

See [LICENSE](LICENSE).
