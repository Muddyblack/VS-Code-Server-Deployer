# Deploy VS Code Server to a remote Linux host via SSH.
# Downloads via Invoke-WebRequest by default (-Browser direct), or via a browser (-Browser chrome|edge|firefox|brave).
param(
    [Parameter(Mandatory=$true)][string]$RemoteHost,
    [Parameter(Mandatory=$true)][string]$RemoteUser,
    [string]$RemotePath = "~",
    [string]$CommitHash = "",
    [ValidateSet('direct','chrome','edge','firefox','brave')]
    [string]$Browser = 'direct'
)

$ErrorActionPreference = 'Stop'

function Invoke-External {
    param([scriptblock]$Action, [string]$What)
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed (exit code $LASTEXITCODE)"
    }
}

function Get-VSCodeCommitHash {
    $paths = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\resources\app\product.json",
        "$env:PROGRAMFILES\Microsoft VS Code\resources\app\product.json",
        "${env:PROGRAMFILES(X86)}\Microsoft VS Code\resources\app\product.json"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            try {
                return (Get-Content $path -Raw | ConvertFrom-Json).commit
            } catch { continue }
        }
    }

    try {
        $output = & code --version 2>$null
        if ($output -and $output.Count -ge 2) { return $output[1] }
    } catch {}

    return $null
}

function Get-BrowserPath {
    param([string]$Name)

    $candidates = switch ($Name.ToLower()) {
        'chrome'  { @(
            "${env:PROGRAMFILES}\Google\Chrome\Application\chrome.exe",
            "${env:PROGRAMFILES(X86)}\Google\Chrome\Application\chrome.exe",
            "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe"
        ) }
        'edge'    { @(
            "${env:PROGRAMFILES}\Microsoft\Edge\Application\msedge.exe",
            "${env:PROGRAMFILES(X86)}\Microsoft\Edge\Application\msedge.exe"
        ) }
        'firefox' { @(
            "${env:PROGRAMFILES}\Mozilla Firefox\firefox.exe",
            "${env:PROGRAMFILES(X86)}\Mozilla Firefox\firefox.exe"
        ) }
        'brave'   { @(
            "${env:PROGRAMFILES}\BraveSoftware\Brave-Browser\Application\brave.exe",
            "${env:PROGRAMFILES(X86)}\BraveSoftware\Brave-Browser\Application\brave.exe",
            "${env:LOCALAPPDATA}\BraveSoftware\Brave-Browser\Application\brave.exe"
        ) }
        default   { throw "Unsupported browser: $Name" }
    }

    $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $found) { throw "$Name not found in standard install locations" }
    return $found
}

function Download-Direct {
    param([string]$Url, [string]$OutputFile)

    Write-Host "    Downloading: $(Split-Path $OutputFile -Leaf)" -ForegroundColor Yellow
    $ProgressPreference = 'SilentlyContinue'  # much faster without progress bar
    Invoke-WebRequest -Uri $Url -OutFile $OutputFile -UseBasicParsing
    if (-not (Test-Path $OutputFile) -or (Get-Item $OutputFile).Length -eq 0) {
        throw "Download produced empty or missing file: $OutputFile"
    }
    Write-Host "    Downloaded: $OutputFile" -ForegroundColor Green
}

function Download-WithBrowser {
    param([string]$Url, [string]$OutputFile, [string]$BrowserExe)

    $fileName = Split-Path $OutputFile -Leaf
    $downloadPath = "$env:USERPROFILE\Downloads\$fileName"

    Remove-Item -Force $downloadPath -ErrorAction SilentlyContinue

    Write-Host "    Opening in $Browser : $fileName" -ForegroundColor Yellow
    Start-Process -FilePath $BrowserExe -ArgumentList $Url | Out-Null

    Write-Host "    Waiting for download..." -ForegroundColor Cyan
    $timeout = 300
    $elapsed = 0

    while ($elapsed -lt $timeout) {
        if ((Test-Path $downloadPath) -and -not (Test-Path "$downloadPath.crdownload") -and -not (Test-Path "$downloadPath.part")) {
            Start-Sleep -Seconds 2
            if ((Get-Item $downloadPath).Length -gt 1MB) {
                Move-Item $downloadPath $OutputFile -Force
                Write-Host "    Downloaded: $OutputFile" -ForegroundColor Green
                return
            }
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
        Write-Host "." -NoNewline -ForegroundColor Gray
    }

    Write-Host "`n    Auto-detection timeout. Press Enter when download completes..." -ForegroundColor Yellow
    Read-Host | Out-Null

    if (Test-Path $downloadPath) {
        Move-Item $downloadPath $OutputFile -Force
        Write-Host "    File ready: $OutputFile" -ForegroundColor Green
    } else {
        throw "File not found in Downloads folder: $downloadPath"
    }
}

function Download-File {
    param([string]$Url, [string]$OutputFile, [string]$BrowserExe)

    if ($Browser -eq 'direct') {
        Download-Direct -Url $Url -OutputFile $OutputFile
    } else {
        Download-WithBrowser -Url $Url -OutputFile $OutputFile -BrowserExe $BrowserExe
    }
}

function Setup-SSHKey {
    $keyPath = "$env:USERPROFILE\.ssh\id_rsa"

    if (-not (Test-Path $keyPath)) {
        Write-Host "[+] Generating SSH key..." -ForegroundColor Yellow
        & ssh-keygen -t rsa -b 2048 -f $keyPath -N '""' -q
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed" }
    }

    Write-Host "[+] Setting up passwordless SSH..." -ForegroundColor Green
    Write-Host "    Enter password one last time:" -ForegroundColor Cyan

    $pubKey = Get-Content "$keyPath.pub"
    & ssh "${RemoteUser}@${RemoteHost}" "mkdir -p ~/.ssh && echo '$pubKey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"

    return ($LASTEXITCODE -eq 0)
}

# --- SSH connectivity ---
Write-Host "[+] Testing SSH to ${RemoteUser}@${RemoteHost}..." -ForegroundColor Green
& ssh -o ConnectTimeout=10 -o BatchMode=yes "${RemoteUser}@${RemoteHost}" "echo OK" 2>$null | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "    Password authentication required" -ForegroundColor Yellow
    if (Setup-SSHKey) {
        Write-Host "[+] SSH key authentication enabled!" -ForegroundColor Green
    } else {
        Write-Host "    Continuing with password authentication..." -ForegroundColor Yellow
    }
} else {
    Write-Host "[+] SSH key authentication already working!" -ForegroundColor Green
}

# --- Locate browser early so we fail fast (skipped for direct mode) ---
$browserExe = $null
if ($Browser -ne 'direct') {
    $browserExe = Get-BrowserPath -Name $Browser
    Write-Host "[+] Using browser: $Browser ($browserExe)" -ForegroundColor Cyan
} else {
    Write-Host "[+] Using direct download (Invoke-WebRequest)" -ForegroundColor Cyan
}

# --- Commit hash ---
if (-not $CommitHash) {
    Write-Host "[+] Getting VS Code commit hash..." -ForegroundColor Green
    $CommitHash = Get-VSCodeCommitHash
    if (-not $CommitHash) { throw "Commit hash not found. Pass -CommitHash explicitly." }
}
Write-Host "[+] Using commit: $CommitHash" -ForegroundColor Cyan

$ServerUrl  = "https://update.code.visualstudio.com/commit:$CommitHash/server-linux-x64/stable"
$CLIUrl     = "https://update.code.visualstudio.com/commit:$CommitHash/cli-alpine-x64/stable"
$ServerFile = ".\vscode-server-linux-x64.tar.gz"
$CLIFile    = ".\vscode_cli_alpine_x64_cli.tar.gz"

try {
    Write-Host "[+] Downloading VS Code Server..." -ForegroundColor Green
    Download-File -Url $ServerUrl -OutputFile $ServerFile -BrowserExe $browserExe

    Write-Host "[+] Downloading VS Code CLI..." -ForegroundColor Green
    Download-File -Url $CLIUrl -OutputFile $CLIFile -BrowserExe $browserExe

    Write-Host "[+] Uploading to remote server..." -ForegroundColor Green
    Invoke-External -What "scp upload" -Action {
        & scp $ServerFile $CLIFile "deploy-local-vscode-server.sh" "${RemoteUser}@${RemoteHost}:${RemotePath}/"
    }

    # Strip CRLF in case the .sh was checked out / downloaded on Windows.
    Write-Host "[+] Normalizing line endings on remote..." -ForegroundColor Green
    Invoke-External -What "remote dos2unix" -Action {
        & ssh "${RemoteUser}@${RemoteHost}" "cd ${RemotePath} && sed -i 's/\r$//' deploy-local-vscode-server.sh && chmod +x deploy-local-vscode-server.sh"
    }

    Write-Host "[+] Running remote setup..." -ForegroundColor Green
    Invoke-External -What "remote deploy script" -Action {
        & ssh "${RemoteUser}@${RemoteHost}" "cd ${RemotePath} && ./deploy-local-vscode-server.sh"
    }

    Write-Host "[+] Deployment complete!" -ForegroundColor Green
}
catch {
    Write-Host "[!] Deployment failed: $_" -ForegroundColor Red
    exit 1
}
finally {
    Write-Host "[+] Cleaning up local archives..." -ForegroundColor Yellow
    Remove-Item -Force $ServerFile, $CLIFile -ErrorAction SilentlyContinue
}

Write-Host "[+] Done! You can now connect to your remote VS Code Server." -ForegroundColor Green
Write-Host "Usage: ssh -L 8080:localhost:8080 ${RemoteUser}@${RemoteHost}" -ForegroundColor Cyan
