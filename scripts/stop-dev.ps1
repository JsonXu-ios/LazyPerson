$ErrorActionPreference = "SilentlyContinue"

$workspace = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ports = @(5175, 8018)

function Get-ProtectedProcessIds {
    $ids = New-Object System.Collections.Generic.HashSet[int]
    $currentId = $PID
    while ($currentId -gt 0 -and -not $ids.Contains($currentId)) {
        [void]$ids.Add($currentId)
        $process = Get-CimInstance Win32_Process -Filter "ProcessId = $currentId"
        if (-not $process) {
            break
        }
        $currentId = [int]$process.ParentProcessId
    }
    return $ids
}

$protectedProcessIds = Get-ProtectedProcessIds

function Stop-ByProcessId {
    param([int[]]$Ids)

    foreach ($processId in ($Ids | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
        if ($protectedProcessIds.Contains($processId)) {
            continue
        }
        & taskkill.exe /PID $processId /T /F | Out-Null
    }
}

function Get-DevProcessIds {
    $escapedWorkspace = [regex]::Escape($workspace)
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -and
            $_.CommandLine -match $escapedWorkspace -and
            (
                $_.CommandLine -match "npm run dev:backend" -or
                $_.CommandLine -match "npm run dev:frontend" -or
                $_.CommandLine -match "uvicorn backend\.app\.main:app" -or
                $_.CommandLine -match "npm --prefix frontend run dev"
            )
        } |
        Select-Object -ExpandProperty ProcessId -Unique
}

function Get-PortProcessIds {
    Get-NetTCPConnection -LocalPort $ports -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
}

for ($attempt = 1; $attempt -le 4; $attempt += 1) {
    Stop-ByProcessId -Ids @(Get-DevProcessIds)
    Stop-ByProcessId -Ids @(Get-PortProcessIds)
    Start-Sleep -Milliseconds 700
}

$remaining = Get-NetTCPConnection -LocalPort $ports -State Listen -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, OwningProcess

if ($remaining) {
    Write-Host "Remaining listeners:"
    $remaining | Format-Table -AutoSize
} else {
    Write-Host "Dev ports 5175 and 8018 are free."
}
