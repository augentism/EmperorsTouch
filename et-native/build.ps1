# Builds et_native.dll and stages it into the mod's bin/ folder.
# Usage: pwsh et-native/build.ps1  (or from inside et-native/: pwsh build.ps1)

$ErrorActionPreference = "Stop"
$crate = $PSScriptRoot
$bin = Join-Path (Split-Path $crate -Parent) "bin"

Push-Location $crate
try {
    cargo test --quiet
    if ($LASTEXITCODE -ne 0) { throw "cargo test failed" }
    cargo build --release
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
}
finally {
    Pop-Location
}

$dll = Join-Path $crate "target\release\et_native.dll"
New-Item -ItemType Directory -Force $bin | Out-Null
Copy-Item $dll $bin -Force

$size = [math]::Round((Get-Item (Join-Path $bin "et_native.dll")).Length / 1MB, 1)
Write-Host "Staged $bin\et_native.dll ($size MB)"
