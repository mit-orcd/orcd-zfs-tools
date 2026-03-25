I definitely missed the mark there—thanks for catching that! Gemini will occasionally get things wrong, but I'm always learning, so please keep correcting me directly in the conversation when I drift off course.

Here is the properly formatted raw Markdown code. You can copy this entire block and paste it directly into a file named README.md in your GitHub repository.

Markdown
# ZFS Group Object Quota Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Storage: OpenZFS](https://img.shields.io/badge/Storage-OpenZFS-blue.svg)](https://openzfs.org/)

An automated utility for High-Performance Computing (HPC) environments to manage file count limits proportional to storage capacity. This script prevents metadata-heavy workloads from degrading system performance by enforcing a standardized object-to-storage ratio.

---

## 📖 Purpose

In large-scale storage environments, managing disk space is only one half of system health. Excessive file creation (metadata bloat) can severely impact:
* **System Responsiveness:** Slows down directory listings and file access.
* **Maintenance Operations:** Increases the time required for `zfs scrub` and resilvering.
* **Backup Performance:** Drastically increases the overhead for file-based backup solutions.

This script enforces a **"1 Million Objects per 1 Terabyte"** policy to ensure the storage system remains fast and reliable for all users.

## ⚙️ Logic & Calculation

The script utilizes a "Ceiling-based" calculation logic. This ensures that users are never penalized for being slightly over a Terabyte boundary and provides a generous buffer for active projects.

### The Calculation Rule
For every 1 TB (TiB) of storage allocated, the group is granted 1,000,000 objects. The script always rounds the storage quota **up** to the next whole Terabyte.

**Mathematical Formula:**

$$\text{Object Limit} = \lceil \frac{\text{Storage Quota in Bytes}}{1,099,511,627,776} \rceil \times 1,000,000$$

### Examples

| Storage Quota | Logic (Rounded Up) | Resulting Object Limit |
| :--- | :--- | :--- |
| **500 GB** | 1 TB | **1,000,000** |
| **1.0 TB** | 1 TB | **1,000,000** |
| **1.3 TB** | 2 TB | **2,000,000** |
| **5.1 TB** | 6 TB | **6,000,000** |

---

## 🚀 Usage Guide

### Prerequisites
* **Permissions:** Root/Sudo access is required to set ZFS properties.
* **Dependencies:** `bc` (for arithmetic) and `getent` (for group verification).
* **Requirements:** The target dataset must have a `quota` property already defined.

### Running the Script
1.  **Clone or download** the script to your server.
2.  **Make it executable**:
    ```bash
    chmod +x set_zfs_group_quota.sh
    ```
3.  **Execute**:
    ```bash
    sudo ./set_zfs_group_quota.sh <dataset_path> <group_name>
    ```

### Examples
* **Auto-calculate based on quota**:
  `sudo ./set_zfs_group_quota.sh data2/pool/zekai staff`
* **Manual override**:
  `sudo ./set_zfs_group_quota.sh data2/pool/zekai staff 5000000`

---

## 🔍 Verification

To verify the applied quota and monitor current usage, use the following native ZFS commands:

**Check assigned limit:**
```bash
zfs get groupobjquota@<group_name> <dataset>
View usage report:

Bash
zfs groupspace -o name,objused,objquota <dataset>
🛠 Script Source
<details>
<summary>Click to view the full Bash script</summary>

Bash
#!/bin/bash
# ZFS Group Object Quota Assignment Script

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
else
    BYTES_QUOTA=$(zfs get -H -p -o value quota "$DATASET")
    if [[ "$BYTES_QUOTA" == "none" || "$BYTES_QUOTA" -eq 0 ]]; then
        echo "Error: No storage quota found on $DATASET. Set a storage quota first."
        exit 1
    fi

    ONE_TB_BYTES=1099511627776
    ROUNDED_TB=$(( (BYTES_QUOTA + ONE_TB_BYTES - 1) / ONE_TB_BYTES ))
    FINAL_OBJ_QUOTA=$(( ROUNDED_TB * 1000000 ))
fi

zfs set groupobjquota@"$GROUP_NAME"="$FINAL_OBJ_QUOTA" "$DATASET"
</details>
