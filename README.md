# ZFS Group Object Quota Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Storage: OpenZFS](https://img.shields.io/badge/Storage-OpenZFS-blue.svg)](https://openzfs.org/)

Utility for HPC-style environments to set **per-group inode (object) quotas** on a ZFS dataset. The script ties a group’s **object limit** to the dataset’s **space** `quota` using a **base + incremental** model, optionally bumps the target when current usage is high, then **reconciles** with the **existing** `groupobjquota` so routine runs do not thrash the limit.

The implementation lives in [`zfs-set-group-quota.sh`](zfs-set-group-quota.sh).

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

## Other tools

- [`zfs-make-share-pool.sh`](zfs-make-share-pool.sh) — shared pool provisioning across configured hosts (see script usage).

---

## License

See [LICENSE](LICENSE).
