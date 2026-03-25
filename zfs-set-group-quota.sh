#!/bin/bash

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root."
   exit 1
fi

DATASET=$1
GROUP_NAME=$2
QUOTA_INPUT=$3

if [[ -z "$DATASET" || -z "$GROUP_NAME" ]]; then
    echo "Usage: $0 <dataset> <groupname> [optional_object_limit]"
    echo "Example: $0 data2/pool/zekai staff"
    exit 1
fi

# 1. Verify Dataset and Group
if ! zfs list "$DATASET" > /dev/null 2>&1; then
    echo "Error: Dataset '$DATASET' does not exist."
    exit 1
fi

if ! getent group "$GROUP_NAME" > /dev/null 2>&1; then
    echo "Error: Group '$GROUP_NAME' does not exist on this system."
    exit 1
fi

# 2. Determine Object Quota
if [[ -n "$QUOTA_INPUT" ]]; then
    FINAL_OBJ_QUOTA=$QUOTA_INPUT
    echo "Using manually provided limit: $FINAL_OBJ_QUOTA"
else
    # Fetch storage quota in exact bytes
    BYTES_QUOTA=$(zfs get -H -p -o value quota "$DATASET")

    if [[ "$BYTES_QUOTA" == "none" || "$BYTES_QUOTA" -eq 0 ]]; then
        echo "Error: No storage quota found on $DATASET. Cannot calculate automatic limit."
        exit 1
    fi

    # 1 TiB in bytes
    ONE_TB_BYTES=1099511627776

    # CALCULATE ROUNDED UP TB
    # Formula for ceiling division: (a + b - 1) / b
    ROUNDED_TB=$(( (BYTES_QUOTA + ONE_TB_BYTES - 1) / ONE_TB_BYTES ))

    # 1,000,000 objects per TB
    FINAL_OBJ_QUOTA=$(( ROUNDED_TB * 1000000 ))

    echo "Detected storage quota: $(zfs get -H -o value quota $DATASET) ($BYTES_QUOTA bytes)"
    echo "Rounded to nearest TB: $ROUNDED_TB TB"
    echo "Calculated group object limit: $FINAL_OBJ_QUOTA"
fi

# 3. Apply the groupobjquota
echo "Setting groupobjquota@$GROUP_NAME on $DATASET..."
zfs set groupobjquota@"$GROUP_NAME"="$FINAL_OBJ_QUOTA" "$DATASET"

if [ $? -eq 0 ]; then
    echo "Success: groupobjquota set to $FINAL_OBJ_QUOTA for group '$GROUP_NAME'."
else
    echo "Error: Failed to apply quota."
    exit 1
fi
