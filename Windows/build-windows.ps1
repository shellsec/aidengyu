$ErrorActionPreference = "Stop"

$WindowsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $WindowsDir
$OutputDir = Join-Path $ProjectDir "dist-windows"
$ExeName = "aidengyu.exe"
$ExePath = Join-Path $OutputDir $ExeName
$ZipPath = Join-Path $OutputDir "aidengyu-Windows-x64.zip"
$StageDir = Join-Path $OutputDir "aidengyu-Windows-x64"
$IconPath = Join-Path $WindowsDir "assets\app.ico"
$SysoPath = Join-Path $WindowsDir "cmd\signal\rsrc_windows_amd64.syso"

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw "Go toolchain is required. Install Go 1.22+ from https://go.dev/dl/"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Set-Location $WindowsDir

if (-not (Test-Path $IconPath)) {
    throw "Missing icon: $IconPath (commit Windows/assets/app.ico)"
}

$Rsrc = Join-Path $env:USERPROFILE "go\bin\rsrc.exe"
if (-not (Test-Path $Rsrc)) {
    Write-Host "Installing rsrc..."
    go install github.com/akavel/rsrc@v0.10.2
}
if (-not (Test-Path $Rsrc)) {
    throw "rsrc not found at $Rsrc"
}

Write-Host "Embedding icon resources..."
& $Rsrc -arch amd64 -ico $IconPath -o $SysoPath

Write-Host "Running Go tests..."
go test ./internal/core/ -count=1

Write-Host "Building release Windows exe (GUI subsystem)..."
$env:CGO_ENABLED = "0"
$env:GOOS = "windows"
$env:GOARCH = "amd64"
# -H windowsgui: no console window on double-click; hooks still get piped stdin/stdout.
go build -trimpath -ldflags="-H windowsgui -s -w" -o $ExePath .\cmd\signal\
if ($LASTEXITCODE -ne 0) {
    throw "go build failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path $ExePath)) {
    throw "Build failed: $ExePath was not created"
}

if (Test-Path $StageDir) {
    Remove-Item $StageDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
Copy-Item $ExePath (Join-Path $StageDir $ExeName) -Force
Copy-Item (Join-Path $WindowsDir "README.md") (Join-Path $StageDir "README-Windows.md") -Force

if (Test-Path $ZipPath) {
    Remove-Item $ZipPath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $StageDir,
    $ZipPath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $true
)

$ExeInfo = Get-Item $ExePath
$ZipInfo = Get-Item $ZipPath
Write-Output "EXE=$($ExeInfo.FullName) BYTES=$($ExeInfo.Length)"
Write-Output "ZIP=$($ZipInfo.FullName) BYTES=$($ZipInfo.Length)"
