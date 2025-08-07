# Deploy VS Code Server via Chrome downloads and SSH
param(
    [Parameter(Mandatory=$true)][string]$RemoteHost,
    [Parameter(Mandatory=$true)][string]$RemoteUser,
    [string]$RemotePath = "~",
    [string]$CommitHash = ""
)

function Get-VSCodeCommitHash {
    $paths = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\resources\app\product.json",
        "$env:PROGRAMFILES\Microsoft VS Code\resources\app\product.json",
        "$env:PROGRAMFILES(X86)\Microsoft VS Code\resources\app\product.json"
    )
    
    foreach ($path in $paths) {
        if (Test-Path $path) {
            try {
                return (Get-Content $path | ConvertFrom-Json).commit
            } catch { continue }
        }
    }
    
    try {
        $output = & code --version 2>$null
        if ($output -and $output.Count -ge 2) { return $output[1] }
    } catch {}
    
    return $null
}

# Setup SSH key authentication (one-time password entry)
function Setup-SSHKey {
    $keyPath = "$env:USERPROFILE\.ssh\id_rsa"
    
    if (-not (Test-Path $keyPath)) {
        Write-Host "[+] Generating SSH key..." -ForegroundColor Yellow
        ssh-keygen -t rsa -b 2048 -f $keyPath -N '""' -q
    }
    
    Write-Host "[+] Setting up passwordless SSH..." -ForegroundColor Green
    Write-Host "    Enter password one last time:" -ForegroundColor Cyan
    
    # Copy public key to remote server
    $pubKey = Get-Content "$keyPath.pub"
    ssh "${RemoteUser}@${RemoteHost}" "mkdir -p ~/.ssh && echo '$pubKey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[+] SSH key authentication enabled!" -ForegroundColor Green
        return $true
    }
    return $false
}

# Test SSH connection
Write-Host "[+] Testing SSH to ${RemoteUser}@${RemoteHost}..." -ForegroundColor Green
$testResult = ssh -o ConnectTimeout=10 -o BatchMode=yes "${RemoteUser}@${RemoteHost}" "echo 'OK'" 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "    Password authentication required" -ForegroundColor Yellow
    if (Setup-SSHKey) {
        Write-Host "[+] SSH key setup complete!" -ForegroundColor Green
    } else {
        Write-Host "    Continuing with password authentication..." -ForegroundColor Yellow
    }
} else {
    Write-Host "[+] SSH key authentication already working!" -ForegroundColor Green
}

# Get VS Code commit hash
if (-not $CommitHash) {
    Write-Host "[+] Getting VS Code commit hash..." -ForegroundColor Green
    $CommitHash = Get-VSCodeCommitHash
    if (-not $CommitHash) { Write-Error "Commit hash not found"; exit 1 }
}
Write-Host "[+] Using commit: $CommitHash" -ForegroundColor Cyan

# Prepare download URLs
$ServerUrl = "https://update.code.visualstudio.com/commit:$CommitHash/server-linux-x64/stable"
$CLIUrl = "https://update.code.visualstudio.com/commit:$CommitHash/cli-alpine-x64/stable"

try {
    function Download-WithChrome($Url, $OutputFile) {
        $fileName = Split-Path $OutputFile -Leaf
        $downloadPath = "$env:USERPROFILE\Downloads\$fileName"
        
        # Find Chrome
        $chrome = @(
            "${env:PROGRAMFILES}\Google\Chrome\Application\chrome.exe",
            "${env:PROGRAMFILES(X86)}\Google\Chrome\Application\chrome.exe",
            "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        
        if (-not $chrome) { throw "Chrome not found" }
        
        Write-Host "    Opening in Chrome: $fileName" -ForegroundColor Yellow
        Start-Process -FilePath $chrome -ArgumentList $Url
        
        # Auto-detect download completion
        Write-Host "    Waiting for download..." -ForegroundColor Cyan
        $timeout = 300  # 5 minutes
        $elapsed = 0
        
        while ($elapsed -lt $timeout) {
            if (Test-Path $downloadPath) {
                # Wait a bit more to ensure download is complete
                Start-Sleep -Seconds 2
                if ((Get-Item $downloadPath).Length -gt 1MB) {
                    Move-Item $downloadPath $OutputFile
                    Write-Host "    Downloaded: $OutputFile" -ForegroundColor Green
                    return
                }
            }
            Start-Sleep -Seconds 2
            $elapsed += 2
            Write-Host "." -NoNewline -ForegroundColor Gray
        }
        
        # Fallback to manual confirmation
        Write-Host "`n    Auto-detection timeout. Press Enter when download completes..." -ForegroundColor Yellow
        Read-Host
        
        if (Test-Path $downloadPath) {
            Move-Item $downloadPath $OutputFile
            Write-Host "    File ready: $OutputFile" -ForegroundColor Green
        } else {
            throw "File not found in Downloads folder"
        }
    }
    
    # Download files via Chrome
    Write-Host "[+] Downloading VS Code Server..." -ForegroundColor Green
    $ServerFile = ".\vscode-server-linux-x64.tar.gz"
    Download-WithChrome $ServerUrl $ServerFile
    
    Write-Host "[+] Downloading VS Code CLI..." -ForegroundColor Green
    $CLIFile = ".\vscode_cli_alpine_x64_cli.tar.gz"
    Download-WithChrome $CLIUrl $CLIFile
    
    # Upload and deploy
    Write-Host "[+] Uploading to remote server..." -ForegroundColor Green
    scp $ServerFile $CLIFile "deploy-local-vscode-server.sh" "${RemoteUser}@${RemoteHost}:${RemotePath}/"
    
    Write-Host "[+] Running remote setup..." -ForegroundColor Green
    ssh "${RemoteUser}@${RemoteHost}" "cd ${RemotePath} && chmod +x deploy-local-vscode-server.sh && ./deploy-local-vscode-server.sh"
    
    Write-Host "[+] Deployment complete!" -ForegroundColor Green
    
} catch {
    Write-Error "Deployment failed: $_"
} finally {
    # Cleanup
    Write-Host "[+] Cleaning up..." -ForegroundColor Yellow
    Remove-Item -Force "vscode-server-linux-x64.tar.gz", "vscode_cli_alpine_x64_cli.tar.gz" -ErrorAction SilentlyContinue
}

Write-Host "[+] Done! You can now connect to your remote VS Code Server." -ForegroundColor Green
Write-Host "Usage: ssh -L 8080:localhost:8080 ${RemoteUser}@${RemoteHost}" -ForegroundColor Cyan