#!/bin/bash
# ZFS Group Object Quota Assignment Script - Bi-directional Scaling

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

# 1. Fetch current object usage (OBJUSED)
OBJUSED=$(zfs groupspace -H -p -o name,objused "$DATASET" | awk -v grp="$GROUP_NAME" '$1 == grp {print $2}')
OBJUSED=${OBJUSED:-0}

# 2. Determine q(n) - The new Target
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
    
    # SAFETY BUFFER LOGIC (Scale down protection)
    if (( OBJUSED > CALC_QUOTA )); then
        QN=$(( OBJUSED * 110 / 100 ))
        echo "Condition: Usage ($OBJUSED) is > Calculated Base ($CALC_QUOTA)."
        echo "Setting target q(n) to Usage + 10% -> $QN"
    else
        QN=$CALC_QUOTA
        echo "Condition: Calculated Base ($CALC_QUOTA) is >= Usage ($OBJUSED)."
        echo "Setting target q(n) to Calculated Base -> $QN"
    fi
fi

# 3. Fetch q(e) — Existing groupobjquota
QE_RAW=$(zfs get -H -p -o value "groupobjquota@${GROUP_NAME}" "$DATASET" 2>/dev/null || true)
if [[ -z "$QE_RAW" || "$QE_RAW" == "-" || "$QE_RAW" == "none" ]]; then
    QE=0
else
    QE=$QE_RAW
fi

echo "---"
echo "Current State: Target q(n) = $QN | Existing q(e) = $QE | Usage = $OBJUSED"
echo "---"

# 4. Apply Hysteresis Rules
UPPER_THRESHOLD=$(( QN * 110 / 100 ))
LOWER_THRESHOLD=$(( QN * 90 / 100 ))

if (( QE >= UPPER_THRESHOLD )); then
    # FIXED RULE 1: If old quota is way higher than new target, shrink it down.
    FINAL_OBJ_QUOTA=$QN
    echo "Rule Triggered: q(e) is >= 110% of q(n) (Storage likely scaled down)."
    echo "Action: Shrinking quota to q(n) -> $FINAL_OBJ_QUOTA"

elif (( QE <= LOWER_THRESHOLD )); then
    # Rule 2: If old quota is way lower than new target, grow it up.
    FINAL_OBJ_QUOTA=$QN
    echo "Rule Triggered: q(e) is <= 90% of q(n) (Storage likely scaled up)."
    echo "Action: Growing quota to q(n) -> $FINAL_OBJ_QUOTA"

else
    # Rule 3: Catch-all (within the +/- 10% deadzone)
    FINAL_OBJ_QUOTA=$(( QE * 110 / 100 ))
    echo "Rule Triggered: q(e) is within 10% of q(n)."
    echo "Action: Applying +10% buffer to q(e) -> $FINAL_OBJ_QUOTA"
fi

# 5. Absolute Floor Check: NEVER go below usage
if (( FINAL_OBJ_QUOTA < OBJUSED )); then
    FINAL_OBJ_QUOTA=$OBJUSED
    echo "Warning: Target fell below current usage ($OBJUSED)."
    echo "Action: Adjusting quota floor to match usage -> $FINAL_OBJ_QUOTA"
fi

echo "---"

# 6. Apply Quota
if [[ "$FINAL_OBJ_QUOTA" -eq "$QE" ]]; then
    echo "Status: groupobjquota@$GROUP_NAME is already exactly $FINAL_OBJ_QUOTA on $DATASET. Exiting."
    exit 0
fi

echo "Executing: zfs set groupobjquota@$GROUP_NAME=$FINAL_OBJ_QUOTA $DATASET"
zfs set groupobjquota@"$GROUP_NAME"="$FINAL_OBJ_QUOTA" "$DATASET"

if [ $? -eq 0 ]; then
    echo "Success: Quota updated."
else
    echo "Error: ZFS command failed."
    exit 1
fi
