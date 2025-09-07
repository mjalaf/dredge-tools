<# 
.SYNOPSIS
  Export Azure API Management artifacts using only Azure CLI (az) + az rest.

.PARAMETER SubscriptionId
  Azure Subscription ID where the APIM instance lives.

.PARAMETER ResourceGroup
  Resource group name of the APIM instance.

.PARAMETER ApimName
  API Management service name.

.PARAMETER OutFolder
  Output folder (will be created).

.PARAMETER ApiVersion
  ARM api-version for ApiManagement (default = 2023-03-01-preview).

.EXAMPLE
  .\apim-export.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ResourceGroup "<APIM Resource Group>" -ApimName "<APIM Name>" -OutFolder ".\out\extract"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string]$SubscriptionId,
  [Parameter(Mandatory=$true)] [string]$ResourceGroup,
  [Parameter(Mandatory=$true)] [string]$ApimName,
  [Parameter(Mandatory=$true)] [string]$OutFolder,
  [string]$ApiVersion = "2023-03-01-preview"
)

# ---- Helpers ---------------------------------------------------------------

function Ensure-Folder {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
}

function Write-JsonToFile {
  param([object]$Json, [string]$Path)
  $dir = Split-Path -Path $Path -Parent
  Ensure-Folder $dir
  $Json | Out-File -FilePath $Path -Encoding UTF8
}

function Safe-Name {
  param([string]$Name)
  # API names can contain chars invalid for filenames; normalize
  return ($Name -replace '[^\w\.\-]+','_')
}

function Invoke-AzRestJson {
  param([string]$Url)
  $raw = az rest --method get --url $Url 2>$null
  if (-not $raw) { return $null }
  try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Get-Paged {
  <#
    Calls an ARM list endpoint and yields .value[] across pages.
  #>
  param([string]$Url)
  $next = $Url
  while ($true) {
    $page = Invoke-AzRestJson -Url $next
    if ($null -eq $page) { break }
    if ($page.value) { $page.value } elseif ($page.items) { $page.items }  # some endpoints return items
    if ($page.nextLink) { $next = $page.nextLink } else { break }
  }
}

# ---- Pre-checks ------------------------------------------------------------

Write-Host ">> Using subscription: $SubscriptionId"
az account set --subscription $SubscriptionId | Out-Null

# Base ARM URL for this APIM
$base = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
Ensure-Folder $OutFolder

# Subfolders
$apisFolder   = Join-Path $OutFolder "apis"
$metaFolder   = Join-Path $OutFolder "metadata"
Ensure-Folder $apisFolder
Ensure-Folder $metaFolder

# ---- 1) APIs: list, export OpenAPI, export policy per API ------------------

Write-Host ">> Listing APIs..."
$apisUrl = "$base/apis?api-version=$ApiVersion"
$apis = @( Get-Paged -Url $apisUrl )
Write-Host ">> Found $($apis.Count) API(s)."

foreach ($api in $apis) {
  $apiId = $api.name
  $apiNameSafe = Safe-Name $apiId
  $apiFolder = Join-Path $apisFolder $apiNameSafe
  Ensure-Folder $apiFolder

  Write-Host "  - Exporting API '$apiId'..."

  # 1.a OpenAPI via `az apim api export` (reliable across tenants)
  # Formats: OpenApiJson | OpenApi | Wadl | Wsdl | etc.
  try {
    $tmp = az apim api export `
      --resource-group $ResourceGroup `
      --service-name $ApimName `
      --api-id $apiId `
      --format OpenApiJson

    # `az apim api export` sometimes returns an object with `value` (content) or with `link` (URL).
    # Try to parse as JSON; if it fails, just write raw.
    try {
      $obj = $tmp | ConvertFrom-Json
      if ($obj.value) {
        $obj.value | Out-File -FilePath (Join-Path $apiFolder "openapi.json") -Encoding UTF8
      } elseif ($obj.link) {
        # Fallback: fetch from link (requires outbound internet)
        $content = Invoke-WebRequest -UseBasicParsing -Uri $obj.link
        $content.Content | Out-File -FilePath (Join-Path $apiFolder "openapi.json") -Encoding UTF8
      } else {
        # Raw content
        $tmp | Out-File -FilePath (Join-Path $apiFolder "openapi.json") -Encoding UTF8
      }
    } catch {
      # Not JSON → treat as raw string
      $tmp | Out-File -FilePath (Join-Path $apiFolder "openapi.json") -Encoding UTF8
    }
  } catch {
    Write-Warning "    ! OpenAPI export failed for '$apiId' (continuing)."
  }

  # 1.b API policy (raw XML)
  try {
    $polUrl = "$base/apis/$apiId/policies/policy?api-version=$ApiVersion&format=rawxml"
    $policyRaw = az rest --method get --url $polUrl 2>$null
    if ($policyRaw) {
      $policyRaw | Out-File -FilePath (Join-Path $apiFolder "policy.xml") -Encoding UTF8
    }
  } catch {
    Write-Warning "    ! Policy export failed for '$apiId' (continuing)."
  }

  # 1.c Save the API entity itself (metadata)
  try {
    $apiEntityUrl = "$base/apis/$apiId?api-version=$ApiVersion"
    $apiEntity = Invoke-AzRestJson -Url $apiEntityUrl
    if ($apiEntity) {
      ($apiEntity | ConvertTo-Json -Depth 100) | Out-File -FilePath (Join-Path $apiFolder "api-entity.json") -Encoding UTF8
    }
  } catch {
    Write-Warning "    ! API entity fetch failed for '$apiId' (continuing)."
  }
}

# ---- 2) Products -----------------------------------------------------------

Write-Host ">> Exporting products..."
try {
  $prodUrl = "$base/products?api-version=$ApiVersion"
  $products = @( Get-Paged -Url $prodUrl )
  ($products | ConvertTo-Json -Depth 100) | Out-File -FilePath (Join-Path $metaFolder "products.json") -Encoding UTF8
} catch { Write-Warning "  ! Products export failed (continuing)." }

# ---- 3) Named Values -------------------------------------------------------

Write-Host ">> Exporting named values (reference only; secret values are not revealed)..."
try {
  $nvUrl = "$base/namedValues?api-version=$ApiVersion"
  $named = @( Get-Paged -Url $nvUrl )
  ($named | ConvertTo-Json -Depth 100) | Out-File -FilePath (Join-Path $metaFolder "named-values.json") -Encoding UTF8
} catch { Write-Warning "  ! Named values export failed (continuing)." }

# ---- 4) Backends -----------------------------------------------------------

Write-Host ">> Exporting backends..."
try {
  $beUrl = "$base/backends?api-version=$ApiVersion"
  $backends = @( Get-Paged -Url $beUrl )
  ($backends | ConvertTo-Json -Depth 100) | Out-File -FilePath (Join-Path $metaFolder "backends.json") -Encoding UTF8
} catch { Write-Warning "  ! Backends export failed (continuing)." }

# ---- 5) Loggers ------------------------------------------------------------

Write-Host ">> Exporting loggers..."
try {
  $lgUrl = "$base/loggers?api-version=$ApiVersion"
  $loggers = @( Get-Paged -Url $lgUrl )
  ($loggers | ConvertTo-Json -Depth 100) | Out-File -FilePath (Join-Path $metaFolder "loggers.json") -Encoding UTF8
} catch { Write-Warning "  ! Loggers export failed (continuing)." }

# ---- 6) Diagnostics --------------------------------------------------------

Write-Host ">> Exporting diagnostics..."
try {
  $dgUrl = "$base/diagnostics?api-version=$ApiVersion"
  $diags = @( Get-Paged -Url $dgUrl )
  ($diags | ConvertTo-Json -Depth 100) | Out-File -FilePath (Join-Path $metaFolder "diagnostics.json") -Encoding UTF8
} catch { Write-Warning "  ! Diagnostics export failed (continuing)." }

# ---- 7) Authorization Servers ---------------------------------------------

Write-Host ">> Exporting authorization servers..."
try {
  $authUrl = "$base/authorizationServers?api-version=$ApiVersion"
  $authz = @( Get-Paged -Url $authUrl )
  ($authz | ConvertTo-Json -Depth 100) | Out-File -FilePath (Join-Path $metaFolder "authorization-servers.json") -Encoding UTF8
} catch { Write-Warning "  ! Authorization servers export failed (continuing)." }

# ---- 8) Tags ---------------------------------------------------------------

Write-Host ">> Exporting tags..."
try {
  $tagUrl = "$base/tags?api-version=$ApiVersion"
  $tags = @( Get-Paged -Url $tagUrl )
  ($tags | ConvertTo-Json -Depth 100) | Out-File -FilePath (Join-Path $metaFolder "tags.json") -Encoding UTF8
} catch { Write-Warning "  ! Tags export failed (continuing)." }


# ---------- 9) API <-> Product Links ----------
$mapFile = Join-Path $metaRoot "api-product-map.csv"
if (Test-Path $mapFile) {
  Write-Host ">> Linking APIs to Products (from api-product-map.csv)..."
  $mappings = Import-Csv $mapFile
  foreach ($m in $mappings) {
    $apiId = $m.apiId
    $prodId = $m.productId
    if (-not $apiId -or -not $prodId) { continue }

    Write-Host "  - Linking API '$apiId' to product '$prodId'"
    $url = "$base/products/$prodId/apis/$apiId?api-version=$ApiVersion"
    try {
      az rest --method put `
        --url $url `
        --headers "Content-Type=application/json" "If-Match=*" `
        --body "{}" | Out-Null
    } catch {
      Write-Warning "  ! Failed linking API '$apiId' to product '$prodId'"
    }
  }
}



Write-Host ">> Done. Output under: $OutFolder"
