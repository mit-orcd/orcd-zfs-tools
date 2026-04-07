#!/bin/bash
# ZFS Group Object Quota Assignment Script - With Safety Buffer Logic

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

# 1. q(n) — recalculated object quota (manual override, or base + safety buffer)
if [[ -n "$QUOTA_INPUT" ]]; then
    QN=$QUOTA_INPUT
    echo "Using manual override (q(n)): $QN"
else
    # Fetch storage quota in bytes
    BYTES_QUOTA=$(zfs get -H -p -o value quota "$DATASET")
    if [[ "$BYTES_QUOTA" == "none" || "$BYTES_QUOTA" -eq 0 ]]; then
        echo "Error: No storage quota found on $DATASET. Set a storage quota first."
        exit 1
    fi

    ONE_TB_BYTES=1099511627776
    ROUNDED_TB=$(( (BYTES_QUOTA + ONE_TB_BYTES - 1) / ONE_TB_BYTES ))

    CALC_QUOTA=$(( 1000000 + (ROUNDED_TB * 100000) ))

    # 2. Safety Check: Current Usage
    # Fetch 'objused' for the specific group
    CURRENT_USAGE=$(zfs groupspace -H -p -o name,objused "$DATASET" | grep -w "^$GROUP_NAME" | awk '{print $2}')

    # Default to 0 if no objects are used yet
    CURRENT_USAGE=${CURRENT_USAGE:-0}

    if [[ "$CURRENT_USAGE" -gt "$CALC_QUOTA" ]]; then
        # Apply 10% buffer to current usage
        echo "Warning: Current usage ($CURRENT_USAGE) exceeds calculated quota ($CALC_QUOTA)."
        QN=$(( CURRENT_USAGE * 110 / 100 ))
        echo "Applying Safety Buffer: Current Usage + 10% = $QN (q(n))"
    else
        QN=$CALC_QUOTA
        echo "Applying Standard Quota (q(n)): $QN"
    fi
fi

# 3. q(e) — existing groupobjquota; reconcile with q(n)
QE_RAW=$(zfs get -H -p -o value "groupobjquota@${GROUP_NAME}" "$DATASET" 2>/dev/null || true)
if [[ -z "$QE_RAW" || "$QE_RAW" == "-" || "$QE_RAW" == "none" ]]; then
    QE=0
else
    QE=$QE_RAW
fi

# q(e) >= q(n)*1.1 -> keep q(e); q(e) <= q(n)*0.9 -> q(n); else q(e)*1.1
# Integer-safe: 10*QE >= 11*QN; 10*QE <= 9*QN
if (( QE * 10 >= QN * 11 )); then
    FINAL_OBJ_QUOTA=$QE
    echo "Existing q(e)=$QE >= q(n)*1.1 ($(( QN * 11 / 10 ))); keeping q(e)."
elif (( QE * 10 <= QN * 9 )); then
    FINAL_OBJ_QUOTA=$QN
    echo "Existing q(e)=$QE <= q(n)*0.9 ($(( QN * 9 / 10 ))); using q(n)=$QN."
else
    FINAL_OBJ_QUOTA=$(( QE * 11 / 10 ))
    echo "q(e)=$QE within band around q(n)=$QN; quota = q(e)*1.1 -> $FINAL_OBJ_QUOTA."
fi

# 4. Apply Quota
echo "Setting groupobjquota@$GROUP_NAME on $DATASET..."
zfs set groupobjquota@"$GROUP_NAME"="$FINAL_OBJ_QUOTA" "$DATASET"

if [ $? -eq 0 ]; then
    echo "Success: groupobjquota set to $FINAL_OBJ_QUOTA for '$GROUP_NAME' on $DATASET."
else
    echo "Error: ZFS command failed."
    exit 1
fi
