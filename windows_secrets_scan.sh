#!/bin/bash
# windows_scan.sh — Mount C$ and run NoseyParker
TARGET=$1
USER=$2
PASS=$3
MOUNT="/mnt/win_${TARGET//./_}"
STORE="./np_$(date +%s)_$TARGET"

echo "[*] Mounting C$ from $TARGET..."
sudo mkdir -p "$MOUNT"
if ! sudo mount -t cifs //$TARGET/C$ "$MOUNT" \
    -o username=$USER,password=$PASS,vers=3.0,ro; then
    echo "[-] Mount failed. Check that $USER is a local admin on $TARGET."
    sudo rmdir "$MOUNT" 2>/dev/null
    exit 1
fi

echo "[*] Running NoseyParker..."
IGNORE_ARGS=()
for dir in "Windows" "Program Files" "Program Files (x86)"; do
    [[ -d "$MOUNT/$dir" ]] && IGNORE_ARGS+=(--ignore "$MOUNT/$dir")
done
noseyparker scan "$MOUNT" --datastore "$STORE" "${IGNORE_ARGS[@]}"

echo "[*] Generating report..."
noseyparker report --datastore "$STORE" --format human > "${STORE}_report.txt"
noseyparker report --datastore "$STORE" --format json  > "${STORE}_report.json"

echo "[*] Unmounting..."
sudo umount "$MOUNT"

echo "[+] Done. Report: ${STORE}_report.txt"
