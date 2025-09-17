<# 
  tnc-check-csv.ps1  (compatible con Windows PowerShell 5.1)
  CSV columns: Host,Port[,Name,Type]
  Uso:
    .\tnc-check-csv.ps1 -CsvPath .\targets.csv
    .\tnc-check-csv.ps1 -CsvPath .\targets.csv -OutCsv .\results.csv
    .\tnc-check-csv.ps1 -CsvPath .\targets.csv -UseTnc
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$CsvPath,

  [string]$OutCsv,

  [int]$TimeoutMs = 3000,

  [switch]$UseTnc   # usa Test-NetConnection; si no, TcpClient (más rápido)
)

if (-not (Test-Path $CsvPath)) {
  Write-Error "File not found: $CsvPath"
  exit 1
}

function Get-FirstNonEmpty {
  param(
    [Parameter(Mandatory=$true)][object]$Obj,
    [Parameter(Mandatory=$true)][string[]]$Names
  )
  foreach ($n in $Names) {
    if ($Obj.PSObject.Properties.Match($n).Count -gt 0) {
      $v = $Obj.$n
      if ($null -ne $v -and "$v".Trim() -ne '') { return "$v" }
    }
  }
  return $null
}

function Map-Row {
  param($r)
  $host = Get-FirstNonEmpty -Obj $r -Names @('Host','IP','Address','Target')
  $port = Get-FirstNonEmpty -Obj $r -Names @('Port')
  $name = Get-FirstNonEmpty -Obj $r -Names @('Name','ResourceName','Alias')
  $type = Get-FirstNonEmpty -Obj $r -Names @('Type','ResourceType','Kind')

  if (-not $host -or -not $port -or -not ($port -as [int])) { return $null }
  if (-not $name) { $name = $host }

  return [pscustomobject]@{
    Host = "$host"
    Port = [int]$port
    Name = "$name"
    Type = $(if ($type) { "$type" } else { $null })
  }
}

function Test-TcpPortDotNet {
  param([string]$Host, [int]$Port, [int]$TimeoutMs, [string]$Name, [string]$Type)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect($Host, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
      $client.Close()
      return [pscustomobject]@{ Type=$Type; Name=$Name; Host=$Host; Port=$Port; Result='FAIL'; LatencyMs=$null; Error='Timeout' }
    }
    $client.EndConnect($iar) | Out-Null
    $sw.Stop()
    return [pscustomobject]@{ Type=$Type; Name=$Name; Host=$Host; Port=$Port; Result='PASS'; LatencyMs=[int]$sw.ElapsedMilliseconds; Error=$null }
  } catch {
    $sw.Stop()
    return [pscustomobject]@{ Type=$Type; Name=$Name; Host=$Host; Port=$Port; Result='FAIL'; LatencyMs=$null; Error=$_.Exception.Message }
  } finally {
    if ($client.Connected) { $client.Close() }
    if ($iar) { $iar.AsyncWaitHandle.Close() }
  }
}

function Test-TcpPortTnc {
  param([string]$Host, [int]$Port, [int]$TimeoutMs, [string]$Name, [string]$Type)
  try {
    $r = Test-NetConnection -ComputerName $Host -Port $Port -WarningAction SilentlyContinue
    $ok = $false
    if ($null -ne $r -and $r.PSObject.Properties.Name -contains 'TcpTestSucceeded') {
      $ok = [bool]$r.TcpTestSucceeded
    }
    return [pscustomobject]@{ Type=$Type; Name=$Name; Host=$Host; Port=$Port; Result=($ok -eq $true ? 'PASS' : 'FAIL'); LatencyMs=$null; Error=($ok -eq $true ? $null : 'No TCP handshake') }
  } catch {
    return [pscustomobject]@{ Type=$Type; Name=$Name; Host=$Host; Port=$Port; Result='FAIL'; LatencyMs=$null; Error=$_.Exception.Message }
  }
}

# ---- main ----
$rows = Import-Csv -Path $CsvPath
$targets = @()
foreach ($r in $rows) {
  $mapped = Map-Row $r
  if ($mapped) { $targets += $mapped } else { Write-Warning "Skipping row (need Host & numeric Port): $($r | ConvertTo-Json -Compress)" }
}
if ($targets.Count -eq 0) { Write-Error "No valid rows in CSV."; exit 1 }

$results = foreach ($t in $targets) {
  if ($UseTnc) {
    Test-TcpPortTnc -Host $t.Host -Port $t.Port -TimeoutMs $TimeoutMs -Name $t.Name -Type $t.Type
  } else {
    Test-TcpPortDotNet -Host $t.Host -Port $t.Port -TimeoutMs $TimeoutMs -Name $t.Name -Type $t.Type
  }
}

$results |
  Sort-Object @{Expression={ if ($_.Result -eq 'FAIL') {0} else {1} }}, Type, Name, Host, Port |
  Format-Table Type, Name, Host, Port, Result, LatencyMs, Error -AutoSize

if ($OutCsv) {
  $results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutCsv
  Write-Host "Saved results to $OutCsv"
}
