# ZFS Group Object Quota Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Storage: OpenZFS](https://img.shields.io/badge/Storage-OpenZFS-blue.svg)](https://openzfs.org/)

An automated utility for High-Performance Computing (HPC) environments to manage file count limits. This script implements a "Base + Incremental" scaling model to ensure storage systems remain performant while providing users with a high floor for metadata-intensive workloads.

---

## 📖 Purpose

To prevent **metadata exhaustion** (performance degradation caused by millions of small files), this script links a group's object count to their disk space allocation. 

Unlike a linear scale, this model provides a substantial baseline allowance for every group, with incremental increases as their storage needs grow.

## ⚙️ Logic & Calculation

The script utilizes **Ceiling-based rounding** for storage and a two-tier calculation:

1.  **Base Allowance**: 1,000,000 objects.
2.  **Incremental Scaler**: 100,000 objects for every 1 TB of storage.

### The Formula

$$\text{Object Limit} = 1,000,000 + (\lceil \frac{\text{Storage Quota in Bytes}}{1,099,511,627,776} \rceil \times 100,000)$$

### Examples

| Storage Quota | Logic (Rounded TB) | Resulting Object Limit |
| :--- | :--- | :--- |
| **500 GB** | 1 TB | **1,100,000** |
| **1.0 TB** | 1 TB | **1,100,000** |
| **2.5 TB** | 3 TB | **1,300,000** |
| **10.0 TB** | 10 TB | **2,000,000** |

---

## 🚀 Usage Guide

### Prerequisites
* **Permissions**: Root/Sudo access is required.
* **Dependencies**: `getent` (standard on Linux).
* **Requirements**: Target dataset must have a hard `quota` property defined.

### Execution
```bash
sudo ./set_zfs_group_quota.sh <dataset_path> <group_name>

🔍 Monitoring
Check assigned limit:
Bash

## 🔍 Verification

To verify the applied quota and monitor current usage, use the following native ZFS commands:


zfs groupspace <dataset>
OR
zfs get groupobjquota@<group_name> <dataset>
View usage report:

Bash

zfs groupspace -o name,objused,objquota <dataset>
---


Bash
zfs groupspace -o name,objused,objquota <dataset>
🛠 Script Source
<details>
<summary>Click to view the full Bash script</summary>

Bash
#!/bin/bash
# ZFS Group Object Quota Assignment Script - Base + Incremental Logic

if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

DATASET=$1
GROUP_NAME=$2
QUOTA_INPUT=$3

if [[ -z "$DATASET" || -z "$GROUP_NAME" ]]; then
    echo "Usage: $0 <dataset> <groupname> [optional_object_limit]"
    exit 1
fi

# Verify Dataset and Group
if ! zfs list "$DATASET" > /dev/null 2>&1; then
    echo "Error: Dataset '$DATASET' does not exist."
    exit 1
fi

if ! getent group "$GROUP_NAME" > /dev/null 2>&1; then
    echo "Error: Group '$GROUP_NAME' does not exist."
    exit 1
fi

# Logic Calculation
if [[ -n "$QUOTA_INPUT" ]]; then
    FINAL_OBJ_QUOTA=$QUOTA_INPUT
    echo "Using manual override: $FINAL_OBJ_QUOTA objects."
else
    BYTES_QUOTA=$(zfs get -H -p -o value quota "$DATASET")
    if [[ "$BYTES_QUOTA" == "none" || "$BYTES_QUOTA" -eq 0 ]]; then
        echo "Error: No storage quota found on $DATASET. Set a storage quota first."
        exit 1
    fi

    ONE_TB_BYTES=1099511627776

    # Round up storage to nearest TB
    ROUNDED_TB=$(( (BYTES_QUOTA + ONE_TB_BYTES - 1) / ONE_TB_BYTES ))

    # NEW LOGIC: 1M base + (100k * Rounded TB)
    BASE_ALLOWANCE=1000000
    INCREMENTAL_ALLOWANCE=$(( ROUNDED_TB * 100000 ))
    FINAL_OBJ_QUOTA=$(( BASE_ALLOWANCE + INCREMENTAL_ALLOWANCE ))

    echo "Detected storage quota: $(zfs get -H -o value quota $DATASET)"
    echo "Calculation: 1,000,000 (base) + ($ROUNDED_TB TB * 100,000) = $FINAL_OBJ_QUOTA"
fi

echo "Applying groupobjquota@$GROUP_NAME=$FINAL_OBJ_QUOTA on $DATASET..."
zfs set groupobjquota@"$GROUP_NAME"="$FINAL_OBJ_QUOTA" "$DATASET"

if [ $? -eq 0 ]; then
    echo "Success: Quota applied."
else
    echo "Error: ZFS command failed."
    exit 1
fi
