# ffi_exceptions.ps1 -Build <lua_fnmatch build dir> [-Fixtures <dir>]: the C++ exception
# experiment (ffi_exceptions.lua), every case in a process of its own, under the standalone
# luajit.exe and under a C++ host that calls the script without protection
# (ffi_exceptions_host.cpp, built here; needs cl on the PATH: a VS x64 developer prompt).
# Windows x64 only. Prints one line per (runner, case): what the script printed and the exit code.
param(
    [Parameter(Mandatory = $true)][string]$Build,
    [string]$Fixtures = (Join-Path $PSScriptRoot "fixtures")
)
$luajitDir = Join-Path $Build "lua_fnmatch\luajit\src"
$moduleDir = Join-Path $Build "lua_fnmatch"
$script = Join-Path $PSScriptRoot "ffi_exceptions.lua"
$work = Join-Path $Build "ffi_exceptions"
New-Item -ItemType Directory -Force $work | Out-Null
Copy-Item (Join-Path $luajitDir "lua51.dll") $work -Force
# two hosts: /EHsc (extern "C" functions such as lua_call are assumed not to throw) and /EHs
Push-Location $work
foreach ($eh in "EHsc", "EHs") {
    & cl /nologo "/$eh" /O1 "/I$luajitDir" (Join-Path $PSScriptRoot "ffi_exceptions_host.cpp") "/Fehost_$eh.exe" /link (Join-Path $luajitDir "lua51.lib") | Out-Null
}
Pop-Location
$env:PATH = "$luajitDir;$env:PATH"
foreach ($case in "interpreted", "compiled", "protected", "jit_off_function", "unprotected", "unprotected_compiled") {
    foreach ($runner in "luajit", "host_EHsc", "host_EHs") {
        $exe = if ($runner -eq "luajit") { Join-Path $luajitDir "luajit.exe" } else { Join-Path $work "$runner.exe" }
        $out = & $exe $script $case $Fixtures $moduleDir 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
        Write-Output ("{0,-22} {1,-7} exit {2,-12} {3}" -f $case, $runner, ("0x{0:X}" -f $code), (($out | Where-Object { $_ -ne "" }) -join " | "))
    }
}
