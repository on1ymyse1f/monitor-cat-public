param(
    [string]$Python = "python",
    [switch]$SkipInstall,
    [switch]$SkipSelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "AIMonitor's Windows package must be built on Windows."
}

$architecture = ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture).ToString()
if ($architecture -ne "X64") {
    throw "This script produces AIMonitor-Windows-x64.zip and requires an x64 host; detected $architecture."
}

$WindowsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $WindowsRoot
$Requirements = Join-Path $WindowsRoot "requirements-build.txt"
$IconScript = Join-Path $WindowsRoot "generate_icon.py"
$SpecFile = Join-Path $WindowsRoot "AIMonitor.spec"
$EntryPoint = Join-Path $WindowsRoot "monitor_cat.py"
$ResourceRoot = Join-Path $RepositoryRoot "Sources\aimonitor-app\Resources"
$BuildRoot = Join-Path $WindowsRoot "build"
$PyInstallerWork = Join-Path $BuildRoot "pyinstaller"
$IconPath = Join-Path $BuildRoot "AIMonitor.ico"
$DistRoot = Join-Path $WindowsRoot "dist"
$OnedirPath = Join-Path $DistRoot "AIMonitor"
$ExecutablePath = Join-Path $OnedirPath "AIMonitor.exe"
$ZipPath = Join-Path $DistRoot "AIMonitor-Windows-x64.zip"

function Invoke-PythonChecked {
    param([string[]]$Arguments)

    & $Python @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed with exit code ${LASTEXITCODE}: $Python $($Arguments -join ' ')"
    }
}

foreach ($RequiredPath in @($Requirements, $IconScript, $SpecFile, $EntryPoint, $ResourceRoot)) {
    if (-not (Test-Path -LiteralPath $RequiredPath)) {
        throw "Required build input does not exist: $RequiredPath"
    }
}

if (-not $SkipInstall) {
    Invoke-PythonChecked -Arguments @("-m", "pip", "install", "-r", $Requirements)
}

# These two directories contain generated output only. Keeping them inside the
# Windows packaging directory makes the destructive cleanup narrow and obvious.
foreach ($GeneratedPath in @($PyInstallerWork, $DistRoot)) {
    if (Test-Path -LiteralPath $GeneratedPath) {
        Remove-Item -LiteralPath $GeneratedPath -Recurse -Force
    }
}
New-Item -ItemType Directory -Force -Path $BuildRoot, $DistRoot | Out-Null

Invoke-PythonChecked -Arguments @(
    $IconScript,
    "--source", (Join-Path $ResourceRoot "menubar-cat.png"),
    "--output", $IconPath
)

Invoke-PythonChecked -Arguments @(
    "-m", "PyInstaller",
    "--noconfirm",
    "--clean",
    "--distpath", $DistRoot,
    "--workpath", $PyInstallerWork,
    $SpecFile
)

if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
    throw "PyInstaller completed without producing the expected executable: $ExecutablePath"
}

if (-not $SkipSelfTest) {
    $SelfTest = Start-Process -FilePath $ExecutablePath -ArgumentList @("--self-test") -Wait -PassThru
    if ($SelfTest.ExitCode -ne 0) {
        throw "AIMonitor.exe --self-test failed with exit code $($SelfTest.ExitCode)."
    }
}

if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}
Compress-Archive -LiteralPath $OnedirPath -DestinationPath $ZipPath -CompressionLevel Optimal
if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
    throw "Compress-Archive completed without producing the expected ZIP: $ZipPath"
}

Write-Host "Windows onedir package: $OnedirPath"
Write-Host "Windows ZIP artifact:   $ZipPath"
