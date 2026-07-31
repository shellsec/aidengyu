$ErrorActionPreference = "Stop"

$WindowsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $WindowsDir
$OutputDir = Join-Path $ProjectDir "dist-windows"
$PackageDir = Join-Path $OutputDir "Codex Claude Signal-win32-x64"
$ZipPath = Join-Path $OutputDir "CodexClaudeSignal-Windows-x64.zip"

Set-Location $WindowsDir
npm ci
npm test
npm run make-icon
npm run pack:win

Copy-Item (Join-Path $WindowsDir "README.md") (Join-Path $PackageDir "README-Windows.md") -Force
if (Test-Path $ZipPath) {
    Remove-Item $ZipPath
}
Compress-Archive -Path $PackageDir -DestinationPath $ZipPath
Write-Output $ZipPath
