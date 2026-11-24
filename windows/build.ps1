# Builds KBSwitch for Windows into windows\dist\KBSwitch\ and windows\dist\KBSwitch-Windows.zip.
# Needs: Visual Studio Build Tools ("Desktop development with C++") and CMake.
# Most people don't need this: download KBSwitch-Windows.zip from the GitHub Releases page instead.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$out = "dist\KBSwitch"
New-Item -ItemType Directory -Force "$out\dict" | Out-Null

# Dictionaries (LibreOffice): English and Ukrainian, used by Hunspell.
$base = "https://raw.githubusercontent.com/LibreOffice/dictionaries/master"
foreach ($f in @("en/en_US.aff", "en/en_US.dic", "uk_UA/uk_UA.aff", "uk_UA/uk_UA.dic")) {
    $target = Join-Path "$out\dict" (Split-Path $f -Leaf)
    if (-not (Test-Path $target)) {
        Write-Host "-> Downloading $f"
        Invoke-WebRequest "$base/$f" -OutFile $target
    }
}

Write-Host "-> Compiling"
cmake -S . -B build -A x64 | Out-Host
cmake --build build --config Release | Out-Host
Copy-Item build\Release\KBSwitch.exe $out -Force
Copy-Item ..\hunspell\LICENSE.MPL "$out\LICENSE-hunspell.txt" -Force

Compress-Archive -Force -Path $out -DestinationPath dist\KBSwitch-Windows.zip
Write-Host "Done: windows\dist\KBSwitch-Windows.zip  (unzip anywhere and run KBSwitch.exe: it installs itself)"
