#!/bin/bash
# windows_scan.sh — Mount C$ and run NoseyParker
TARGET=$1
USER=$2
PASS=$3
MOUNT="/mnt/win_${TARGET//./_}"
STORE="./np_$(date +%s)_$TARGET"

echo "[*] Mounting C$ from $TARGET..."
sudo mkdir -p "$MOUNT"
sudo mount -t cifs //$TARGET/C$ "$MOUNT" \
    -o username=$USER,password=$PASS,vers=3.0,ro

echo "[*] Running NoseyParker..."
noseyparker scan "$MOUNT" \
    --datastore "$STORE" \
    --ignore "$MOUNT/Windows" \
    --ignore "$MOUNT/Program Files" \
    --ignore "$MOUNT/Program Files (x86)"

echo "[*] Generating report..."
noseyparker report --datastore "$STORE" --format human > "${STORE}_report.txt"
noseyparker report --datastore "$STORE" --format json  > "${STORE}_report.json"

echo "[*] Unmounting..."
sudo umount "$MOUNT"

echo "[+] Done. Report: ${STORE}_report.txt"
