<# 
  tnc-check-csv.ps1
  CSV-only TCP check with PASS/FAIL.
  Columns (required): Host,Port
  Optional columns:   Name,Type   (e.g., APIM, KeyVault, SQL)

  Examples:
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

  # Use Windows Test-NetConnection (slower, native TNC) instead of TcpClient
  [switch]$UseTnc
)

if (-not (Test-Path $CsvPath)) {
  Write-Error "File not found: $CsvPath"
  exit 1
}

function Map-Row {
  param($r)
  $host = $r.Host ?? $r.IP ?? $r.Address ?? $r.Target
  $port = $r.Port
  $name = $r.Name ?? $r.ResourceName ?? $r.Alias
  $type = $r.Type ?? $r.ResourceType ?? $r.Kind
  if (-not $host -or -not $port -or -not ($port -as [int])) { return $null }
  [pscustomobject]@{
    Host = "$host"
    Port = [int]$port
    Name = ($name ? "$name" : "$host")
    Type = ($type ? "$type" : $null)
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
    [pscustomobject]@{ Type=$Type; Name=$Name; Host=$Host; Port=$Port; Result='PASS'; LatencyMs=[int]$sw.ElapsedMilliseconds; Error=$null }
  } catch {
    $sw.Stop()
    [pscustomobject]@{ Type=$Type; Name=$Name; Host=$Host; Port=$Port; Result='FAIL'; LatencyMs=$null; Error=$_.Exception.Message }
  } finally {
    if ($client.Connected) { $client.Close() }
    if ($iar) { $iar.AsyncWaitHandle.Close() }
  }
}

function Test-TcpPortTnc {
  param([string]$Host, [int]$Port, [int]$TimeoutMs, [string]$Name, [string]$Type)
  try {
    $r = Test-NetConnection -ComputerName $Host -Port $Port -WarningAction SilentlyContinue
    $ok = ($null -ne $r -and $r.PSObject.Properties.Name -contains 'TcpTestSucceeded' -and $r.TcpTestSucceeded)
    [pscustomobject]@{ Type=$Type; Name=$Name; Host=$Host; Port=$Port; Result=($ok?'PASS':'FAIL'); LatencyMs=$null; Error=($ok?$null:'No TCP handshake') }
  } catch {
    [pscustomobject]@{ Type=$Type; Name=$Name; Host=$Host; Port=$Port; Result='FAIL'; LatencyMs=$null; Error=$_.Exception.Message }
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
  Sort-Object @{e='Result'; d={$args[0] -eq 'FAIL' ? 0 : 1}}, Type, Name, Host, Port |
  Format-Table Type, Name, Host, Port, Result, LatencyMs, Error -AutoSize

if ($OutCsv) {
  $results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutCsv
  Write-Host "Saved results to $OutCsv"
}
