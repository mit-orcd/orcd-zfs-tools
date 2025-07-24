#!/bin/bash
set -euo pipefail

usage="Usage: $(basename "$0") PiKerbName"

if [[ $# -ne 1 ]]; then
    echo "$usage"
    exit 1
fi

USR="$1"

RED="\033[31m"
GRN="\033[0;32m"
YLO="\033[0;33m"
NCL="\033[0m"

LDAPS=("ldap001")  # LDAP servers; add more if needed
SESRV="admin001"    # Admin server
hstors=("hstor013-n1" "hstor013-n2" "hstor012-n2")  # ZFS pool servers; add more as needed
DZSRV=""

echo -e "\nChecking prerequisites for the shared pool storage ...\n"

# Check if shared pool already exists on any server
for STOR in "${hstors[@]}"; do
    if ssh "$STOR" zfs list | grep -q "${USR}_shared"; then
        echo -e "${YLO} Exiting - User's requested [${USR}_shared] pool already exists on ${STOR} ${NCL}"
        exit 1
    fi
done

# Find if PI has a personal pool on any server; if yes, use that server
has_personal=false
for STOR in "${hstors[@]}"; do
    if ssh "$STOR" zfs list | grep -q "$USR"; then
        if $has_personal; then
            echo -e "${RED} Error: PI has personal pools on multiple servers ${NCL}"
            exit 1
        fi
        DZSRV="$STOR"
        has_personal=true
    fi
done

# If no personal pool, pick a random server
if ! $has_personal; then
    random_index=$((RANDOM % ${#hstors[@]}))
    DZSRV="${hstors[$random_index]}"
fi

echo "Will attempt to create shared pool on server ${DZSRV}"

# Lookup shared group GID in ldap.mit.edu
GID=$(ldapsearch -LLL -x -h ldap.mit.edu -b "ou=lists,ou=moira,dc=mit,dc=edu" "cn=orcd_rg_shared_pi_${USR}" gidNumber | grep '^gidNumber' | awk '{print $2}')

if [[ -z "$GID" ]]; then
    echo -e "${RED} Exiting - shared group orcd_rg_shared_pi_${USR} doesn't exist in ldap.mit.edu ${NCL}"
    exit 1
fi

GROUP="orcd_rg_shared_pi_${USR}"

# Check if group is in moira (local LDAP)
if ! getent group "$GROUP" &>/dev/null; then
    echo -e "${GRN} Shared group $GROUP not yet added to moira, attempting to add please wait ... ${NCL}"
    for LDP in "${LDAPS[@]}"; do
        ssh "$SESRV" ssh "$LDP" /root/ldap-by-hand/add-group-moira "$GROUP"
        ssh "$SESRV" ssh "$LDP" /root/ldap-by-hand/add-user-to-group-moira "$GROUP"
    done
    echo "Validating the group is now visible..."
    MGD=$(getent group "$GROUP")
    if [[ "$MGD" =~ ^.+/$ ]]; then
        echo -e "${RED} Exiting - there was an issue adding the group - please add manually and re-run this script ${NCL}"
        exit 1
    else
        echo -e "${GRN} Shared group has been added - $MGD ${NCL}"
    fi
else
    echo -e "${GRN} Great - group $GROUP already in moira - proceeding ${NCL}"
fi

echo -e "${YLO} - passed the checks"
echo -e "${GRN} Creating shared pool storage for PI ${USR} ...${NCL}\n"

# Get the pool mountpoint
POOL=$(ssh "$DZSRV" zfs list | grep "pool " | awk '{print $5}')
ZFSP=$(echo "$POOL" | awk -F "/" '{print $2"/"$3}')

# Create the shared dataset
ssh "$DZSRV" zfs create "${ZFSP}/${USR}_shared"
ssh "$DZSRV" zfs set quota=5T "${ZFSP}/${USR}_shared"
ssh "$DZSRV" chmod 2770 "${POOL}/${USR}_shared"
ssh "$DZSRV" chown "root:${GROUP}" "${POOL}/${USR}_shared"

echo "New shared pool storage ${POOL}/${USR}_shared for PI ${USR} has been created on ${DZSRV} -- owner [root]:[${GROUP}]"
