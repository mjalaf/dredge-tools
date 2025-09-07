#Requires -Version 5.1
<#
.SYNOPSIS
    Script simplificado para exportar recursos de Azure API Management.

.DESCRIPTION
    Exporta APIs, Productos, Named Values, Suscripciones, Backends y Políticas 
    de una instancia de Azure API Management de forma simple y directa.

.PARAMETER SubscriptionId
    ID de la suscripción de Azure.

.PARAMETER ResourceGroup
    Nombre del grupo de recursos.

.PARAMETER ApimName
    Nombre de la instancia de APIM.

.PARAMETER OutFolder
    Carpeta de salida para los archivos exportados.

.PARAMETER ApiNames
    Lista opcional de nombres específicos de APIs a exportar. Si está vacío, exporta todas.

.PARAMETER IncludeSecrets
    Incluir valores secretos de Named Values.

.EXAMPLE
    .\apim-export-simple.ps1 -SubscriptionId "xxx" -ResourceGroup "rg-apim" -ApimName "my-apim" -OutFolder "c:\temp\export"

.EXAMPLE
    .\apim-export-simple.ps1 -SubscriptionId "xxx" -ResourceGroup "rg-apim" -ApimName "my-apim" -OutFolder "c:\temp\export" -ApiNames @("api1", "api2") -Verbose
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory = $true)]
    [string]$ApimName,
    
    [Parameter(Mandatory = $true)]
    [string]$OutFolder,
    
    [Parameter(Mandatory = $false)]
    [string[]]$ApiNames = @(),
    
    [Parameter(Mandatory = $false)]
    [switch]$IncludeSecrets
)

# Variables
$ApiVersion = "2023-03-01-preview"
$baseUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"

# Inicio
Write-Host "=== EXPORTACION APIM SIMPLIFICADA ===" -ForegroundColor Green
Write-Host "APIM: $ApimName" -ForegroundColor White
Write-Host "Grupo: $ResourceGroup" -ForegroundColor White
Write-Host "Salida: $OutFolder" -ForegroundColor White
if ($ApiNames.Count -gt 0) {
    Write-Host "APIs específicas: $($ApiNames -join ', ')" -ForegroundColor Cyan
}
Write-Host ""

# Crear directorios
mkdir $OutFolder -Force | Out-Null
mkdir "$OutFolder\global" -Force | Out-Null
mkdir "$OutFolder\apis" -Force | Out-Null

# Verificar conectividad
Write-Host "Verificando conectividad..." -ForegroundColor Yellow
$testUri = "$baseUri" + "?api-version=$ApiVersion"
$testResult = az rest --uri $testUri | ConvertFrom-Json
Write-Host "✓ Conectado a APIM: $($testResult.name)" -ForegroundColor Green

# 1. Política global
Write-Host "1. Exportando política global..." -ForegroundColor Yellow
$policyUri = "$baseUri/policies/policy" + "?api-version=$ApiVersion"
$policyResult = az rest --uri $policyUri 2>$null
if ($policyResult) {
    $policyData = $policyResult | ConvertFrom-Json
    if ($policyData.properties.value) {
        $policyData.properties.value | Out-File "$OutFolder\global\policy.xml" -Encoding UTF8
        Write-Host "   ✓ Política global exportada" -ForegroundColor Green
    }
} else {
    Write-Host "   ! Sin política global" -ForegroundColor Yellow
}

# 2. Productos
Write-Host "2. Exportando productos..." -ForegroundColor Yellow
$productsUri = "$baseUri/products" + "?api-version=$ApiVersion"
az rest --uri $productsUri | Out-File "$OutFolder\global\products.json" -Encoding UTF8
$productsData = Get-Content "$OutFolder\global\products.json" | ConvertFrom-Json
Write-Host "   ✓ $($productsData.value.Count) productos exportados" -ForegroundColor Green

# 3. Named Values
Write-Host "3. Exportando named values..." -ForegroundColor Yellow
$namedValuesUri = "$baseUri/namedValues" + "?api-version=$ApiVersion"
az rest --uri $namedValuesUri | Out-File "$OutFolder\global\namedValues.json" -Encoding UTF8
$namedValuesData = Get-Content "$OutFolder\global\namedValues.json" | ConvertFrom-Json
Write-Host "   ✓ $($namedValuesData.value.Count) named values exportados" -ForegroundColor Green

# 4. Suscripciones
Write-Host "4. Exportando suscripciones..." -ForegroundColor Yellow
$subscriptionsUri = "$baseUri/subscriptions" + "?api-version=$ApiVersion"
az rest --uri $subscriptionsUri | Out-File "$OutFolder\global\subscriptions.json" -Encoding UTF8
$subscriptionsData = Get-Content "$OutFolder\global\subscriptions.json" | ConvertFrom-Json
Write-Host "   ✓ $($subscriptionsData.value.Count) suscripciones exportadas" -ForegroundColor Green

# 5. Backends
Write-Host "5. Exportando backends..." -ForegroundColor Yellow
$backendsUri = "$baseUri/backends" + "?api-version=$ApiVersion"
az rest --uri $backendsUri | Out-File "$OutFolder\global\backends.json" -Encoding UTF8
$backendsData = Get-Content "$OutFolder\global\backends.json" | ConvertFrom-Json
Write-Host "   ✓ $($backendsData.value.Count) backends exportados" -ForegroundColor Green

# 6. APIs
Write-Host "6. Exportando APIs..." -ForegroundColor Yellow
$apisUri = "$baseUri/apis" + "?api-version=$ApiVersion"
$apisResult = az rest --uri $apisUri | ConvertFrom-Json

# Filtrar APIs si se especificaron
$apisToExport = $apisResult.value
if ($ApiNames.Count -gt 0) {
    $apisToExport = $apisResult.value | Where-Object { $_.name -in $ApiNames }
    Write-Host "   Filtrando APIs específicas..." -ForegroundColor Cyan
}

Write-Host "   ✓ Encontradas $($apisToExport.Count) APIs para exportar" -ForegroundColor Green

# Exportar cada API
foreach ($api in $apisToExport) {
    $apiName = $api.name
    $apiFolder = "$OutFolder\apis\$apiName"
    mkdir $apiFolder -Force | Out-Null
    
    Write-Host "     → Exportando API: $apiName" -ForegroundColor Cyan
    
    # Metadatos de API
    $api | ConvertTo-Json -Depth 10 | Out-File "$apiFolder\api.json" -Encoding UTF8
    
    # Política de API
    $apiPolicyUri = "$baseUri/apis/$apiName/policies/policy" + "?api-version=$ApiVersion"
    $apiPolicyResult = az rest --uri $apiPolicyUri 2>$null
    if ($apiPolicyResult) {
        $apiPolicyData = $apiPolicyResult | ConvertFrom-Json
        if ($apiPolicyData.properties.value) {
            $apiPolicyData.properties.value | Out-File "$apiFolder\policy.xml" -Encoding UTF8
        }
    }
    
    # Operaciones
    $operationsUri = "$baseUri/apis/$apiName/operations" + "?api-version=$ApiVersion"
    az rest --uri $operationsUri | Out-File "$apiFolder\operations.json" -Encoding UTF8
    
    # Esquemas
    $schemasUri = "$baseUri/apis/$apiName/schemas" + "?api-version=$ApiVersion"
    $schemasResult = az rest --uri $schemasUri 2>$null
    if ($schemasResult) {
        $schemasData = $schemasResult | ConvertFrom-Json
        if ($schemasData.value.Count -gt 0) {
            $schemasResult | Out-File "$apiFolder\schemas.json" -Encoding UTF8
        }
    }
}

# Crear manifest
$manifest = @{
    exportDate = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    apimName = $ApimName
    resourceGroup = $ResourceGroup
    subscriptionId = $SubscriptionId
    totalApis = $apisToExport.Count
    specificApis = $ApiNames
    includeSecrets = $IncludeSecrets.IsPresent
}
$manifest | ConvertTo-Json | Out-File "$OutFolder\manifest.json" -Encoding UTF8

Write-Host ""
Write-Host "=== EXPORTACION COMPLETADA ===" -ForegroundColor Green
Write-Host "APIs exportadas: $($apisToExport.Count)" -ForegroundColor White
Write-Host "Archivos guardados en: $OutFolder" -ForegroundColor White
