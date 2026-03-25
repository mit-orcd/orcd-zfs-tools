ZFS Group Object Quota ManagerA technical utility for High-Performance Computing (HPC) environments to automate groupobjquota assignments. This ensures that file count limits scale predictably with storage capacity, preventing metadata-heavy workloads from degrading pool performance.📖 PurposeIn large-scale ZFS deployments, managing disk capacity (bytes) is only one part of system health. Metadata exhaustion—caused by the creation of millions of small files—can lead to:Slowed zfs scrub and resilver operations.Increased latency in directory listings and backups.Inefficient snapshot management.This script enforces a "1 Million Objects per 1 Terabyte" policy, ensuring that as a group's storage allocation grows, their "inode" (object) allowance scales proportionally.⚙️ Logic BreakdownThe script fetches the exact byte count of the dataset quota and applies a ceiling-based calculation to ensure users have a generous buffer.Calculation RuleFor every $1\text{ TB}$ of storage allocated, the group receives $1,000,000$ objects. The script rounds up to the next whole Terabyte.Formula:$$\text{Object Limit} = \lceil \frac{\text{Storage Quota in Bytes}}{1,099,511,627,776} \rceil \times 1,000,000$$ExamplesStorage QuotaCalculation (Ceiling)Resulting Object Quota500 GB$1 \times 1,000,000$1,000,0001.0 TB$1 \times 1,000,000$1,000,0001.3 TB$2 \times 1,000,000$2,000,0005.1 TB$6 \times 1,000,000$6,000,000🚀 UsagePrerequisitesRoot Access: Required to modify ZFS properties.Dependencies: bc (calculator utility) and getent (to verify group existence).ZFS Dataset: The target dataset must have a hard quota set.ExecutionSave the script as set_zfs_group_quota.sh.Make it executable:Bashchmod +x set_zfs_group_quota.sh
Run the script:Bashsudo ./set_zfs_group_quota.sh <dataset_path> <group_name>
Command HelpAuto-calculate: sudo ./set_zfs_group_quota.sh data2/pool/zekai staffManual Override: sudo ./set_zfs_group_quota.sh data2/pool/zekai staff 5000000🔍 Verification & MonitoringAdministrators can monitor usage using native ZFS commands:Check assigned limit:Bashzfs get groupobjquota@<group_name> <dataset>
View usage report:Bashzfs groupspace -o name,objused,objquota <dataset>
🛠 The ScriptBash#!/bin/bash
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

