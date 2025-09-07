<# 
Imports APIM artifacts exported by Export-ApimArtifacts.ps1 using only Azure CLI.
- Creates/updates APIs from OpenAPI
- Applies per-API policy.xml (if present)
- Creates products, named values (no secret values), backends, loggers, diagnostics

Run:
  az login
  az account set --subscription "<TARGET_SUB_ID>"
  .\apim-import.ps1 -SubscriptionId "<TARGET_SUB_ID>" -ResourceGroup "<RG_TARGET>" -ApimName "<apim-target>" -InFolder ".\out\extract"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string]$SubscriptionId,
  [Parameter(Mandatory=$true)] [string]$ResourceGroup,
  [Parameter(Mandatory=$true)] [string]$ApimName,
  [Parameter(Mandatory=$true)] [string]$InFolder,
  [string]$ApiVersion = "2023-03-01-preview"
)

function Ensure-Folder { param([string]$Path) if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null } }
function Read-Json { param([string]$Path) if (Test-Path $Path) { Get-Content $Path -Raw | ConvertFrom-Json } else { $null } }
function Safe { param([string]$s) if (-not $s) { return $null } return ($s -replace '[^\w\.\-]+','-').ToLower() }

$base = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"

Write-Host ">> Target: $ApimName / $ResourceGroup  (sub $SubscriptionId)"
if (-not (Test-Path $InFolder)) { throw "Input folder not found: $InFolder" }

$apisRoot = Join-Path $InFolder "apis"
$metaRoot = Join-Path $InFolder "metadata"

# ---------- 1) APIs ----------
if (Test-Path $apisRoot) {
  $apiDirs = Get-ChildItem -Directory $apisRoot
  Write-Host ">> Importing $($apiDirs.Count) API(s)..."

  foreach ($apiDir in $apiDirs) {
    $openapi = Join-Path $apiDir.FullName "openapi.json"
    $policy  = Join-Path $apiDir.FullName "policy.xml"
    $entity  = Join-Path $apiDir.FullName "api-entity.json"

    if (-not (Test-Path $openapi)) { Write-Warning "Skip: no openapi.json in $($apiDir.Name)"; continue }

    $apiEntity = Read-Json $entity
    $apiId     = if ($apiEntity) { $apiEntity.name } else { $apiDir.Name }
    $apiPath   = if ($apiEntity) { $apiEntity.properties.path } else { $apiDir.Name }
    if (-not $apiId)   { $apiId = Safe $apiDir.Name }
    if (-not $apiPath) { $apiPath = $apiId }

    Write-Host "  - Upserting API id='$apiId' path='$apiPath'..."

    # Import/Upsert API from file
    # Newer CLI uses --specification-format/--specification-path. Older: --format/--path.
    $importOk = $true
    try {
      az apim api import `
        --resource-group $ResourceGroup `
        --service-name $ApimName `
        --api-id $apiId `
        --path $apiPath `
        --specification-format OpenApi `
        --specification-path $openapi | Out-Null
    } catch {
      $importOk = $false
    }

    if (-not $importOk) {
      # Fallback with ARM PUT (idempotent)
      $apiBody = @{
        properties = @{
          displayName = if ($apiEntity) { $apiEntity.properties.displayName } else { $apiId }
          path        = $apiPath
          protocols   = @("https")
          format      = "openapi+json"
          value       = (Get-Content $openapi -Raw)
        }
      } | ConvertTo-Json -Depth 20

      az rest --method put `
        --url "$base/apis/$apiId?api-version=$ApiVersion" `
        --headers "Content-Type=application/json" `
        --body $apiBody | Out-Null
    }

    # Apply API policy if present
    if (Test-Path $policy) {
      Write-Host "    > Applying policy.xml"
      $xml = Get-Content $policy -Raw
      $polBody = @{ properties = @{ format = "rawxml"; value = $xml } } | ConvertTo-Json -Depth 5
      az rest --method put `
        --url "$base/apis/$apiId/policies/policy?api-version=$ApiVersion" `
        --headers "Content-Type=application/json" `
        --body $polBody | Out-Null
    }
  }
} else {
  Write-Host ">> No 'apis' folder found — skipping APIs."
}

# ---------- 2) Products ----------
if (Test-Path (Join-Path $metaRoot "products.json")) {
  Write-Host ">> Importing products..."
  $products = Read-Json (Join-Path $metaRoot "products.json")
  foreach ($p in $products) {
    $pid = $p.name
    if (-not $pid) { continue }
    $body = @{ properties = $p.properties } | ConvertTo-Json -Depth 50
    az rest --method put `
      --url "$base/products/$pid?api-version=$ApiVersion" `
      --headers "Content-Type=application/json" `
      --body $body | Out-Null
  }
}

# ---------- 3) Named Values (no secret values travel; just metadata) ----------
if (Test-Path (Join-Path $metaRoot "named-values.json")) {
  Write-Host ">> Importing named values (metadata only; bind secrets to Key Vault later)..."
  $nvs = Read-Json (Join-Path $metaRoot "named-values.json")
  foreach ($nv in $nvs) {
    $name = $nv.name
    if (-not $name) { continue }
    # Build minimal payload: carry flags; leave .value empty if secret
    $props = @{
      displayName = $nv.properties.displayName
      keyVault    = $nv.properties.keyVault
      secret      = $nv.properties.secret
      tags        = $nv.properties.tags
      value       = if ($nv.properties.secret -eq $true) { $null } else { $nv.properties.value }
    }
    $body = @{ properties = $props } | ConvertTo-Json -Depth 50
    az rest --method put `
      --url "$base/namedValues/$name?api-version=$ApiVersion" `
      --headers "Content-Type=application/json" `
      --body $body | Out-Null
  }
}

# ---------- 4) Backends ----------
if (Test-Path (Join-Path $metaRoot "backends.json")) {
  Write-Host ">> Importing backends..."
  $bes = Read-Json (Join-Path $metaRoot "backends.json")
  foreach ($b in $bes) {
    $bid = $b.name
    if (-not $bid) { continue }
    $body = @{ properties = $b.properties } | ConvertTo-Json -Depth 50
    az rest --method put `
      --url "$base/backends/$bid?api-version=$ApiVersion" `
      --headers "Content-Type=application/json" `
      --body $body | Out-Null
  }
}

# ---------- 5) Loggers ----------
if (Test-Path (Join-Path $metaRoot "loggers.json")) {
  Write-Host ">> Importing loggers..."
  $lgs = Read-Json (Join-Path $metaRoot "loggers.json")
  foreach ($l in $lgs) {
    $id = $l.name
    if (-not $id) { continue }
    $body = @{ properties = $l.properties } | ConvertTo-Json -Depth 50
    az rest --method put `
      --url "$base/loggers/$id?api-version=$ApiVersion" `
      --headers "Content-Type=application/json" `
      --body $body | Out-Null
  }
}

# ---------- 6) Diagnostics ----------
if (Test-Path (Join-Path $metaRoot "diagnostics.json")) {
  Write-Host ">> Importing diagnostics..."
  $dgs = Read-Json (Join-Path $metaRoot "diagnostics.json")
  foreach ($d in $dgs) {
    $id = $d.name
    if (-not $id) { continue }
    $body = @{ properties = $d.properties } | ConvertTo-Json -Depth 50
    az rest --method put `
      --url "$base/diagnostics/$id?api-version=$ApiVersion" `
      --headers "Content-Type=application/json" `
      --body $body | Out-Null
  }
}

# ---------- 7) Authorization Servers ----------
if (Test-Path (Join-Path $metaRoot "authorization-servers.json")) {
  Write-Host ">> Importing authorization servers..."
  $auths = Read-Json (Join-Path $metaRoot "authorization-servers.json")
  foreach ($a in $auths) {
    $id = $a.name
    if (-not $id) { continue }
    $body = @{ properties = $a.properties } | ConvertTo-Json -Depth 50
    az rest --method put `
      --url "$base/authorizationServers/$id?api-version=$ApiVersion" `
      --headers "Content-Type=application/json" `
      --body $body | Out-Null
  }
}

Write-Host ">> Import complete."
