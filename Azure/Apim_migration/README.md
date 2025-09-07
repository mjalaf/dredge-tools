# Dredge Tools --- APIM Export/Import Scripts

This folder contains two PowerShell scripts to **export** and **import**
Azure API Management (APIM) artifacts using only the **Azure CLI**
(`az`) and `az rest`.\
No extra builds, no NuGet packages --- just works in restricted
environments.

------------------------------------------------------------------------

## 📦 Scripts

### 1. apim-export-simplified.ps1 ⭐ **RECOMMENDED**

**NEW**: Simplified script for exporting essential APIM resources with clean, maintainable code.

**Exports:** 
- APIs (metadata, policies, operations, schemas)
- Products (with policies)
- Named Values
- Subscriptions
- Backends
- Global policies

**Features:**
- Support for specific APIs or all APIs
- PowerShell 5.1+ compatible
- Simple parameter structure
- Organized file output
- Verbose logging

**Usage:**

``` powershell
# Export all APIs
.\apim-export-simplified.ps1 `
  -SubscriptionId "<SUBSCRIPTION_ID>" `
  -ResourceGroup "<APIM_RESOURCE_GROUP>" `
  -ApimName "<APIM_NAME>" `
  -OutFolder ".\export" `
  -Verbose

# Export specific APIs
.\apim-export-simplified.ps1 `
  -SubscriptionId "<SUBSCRIPTION_ID>" `
  -ResourceGroup "<APIM_RESOURCE_GROUP>" `
  -ApimName "<APIM_NAME>" `
  -OutFolder ".\export" `
  -ApiNames @("api1", "api2") `
  -Verbose
```

See `README-Simplified.md` for detailed documentation.

------------------------------------------------------------------------

### 2. apim-export-individual-list.ps1 (Advanced)

Full-featured export script with advanced capabilities including concurrency, retry logic, and comprehensive resource coverage.

**Note**: This is the original complex script. Use `apim-export-simplified.ps1` for most scenarios.

------------------------------------------------------------------------

### 3. apim-export.ps1 (Legacy)

Original basic export script.

**Exports:** - APIs (OpenAPI specs + policy XML + metadata JSON) -
Products - Named Values (metadata only, secret values are not
included) - Backends - Loggers - Diagnostics - Authorization Servers -
Tags

**Usage:**

``` powershell
az login
az account set --subscription "<SUBSCRIPTION_ID>"

.pim-export.ps1 `
  -SubscriptionId "<SUBSCRIPTION_ID>" `
  -ResourceGroup "<APIM_RESOURCE_GROUP>" `
  -ApimName "<APIM_NAME>" `
  -OutFolder ".\out\extract"
```

The output folder will look like:

    out\extract\
      apis\
        <api-name>\openapi.json
        <api-name>\policy.xml
        <api-name>\api-entity.json
      metadata\
        products.json
        named-values.json
        backends.json
        loggers.json
        diagnostics.json
        authorization-servers.json
        tags.json

------------------------------------------------------------------------

### 2. apim-import.ps1

Imports artifacts exported by `apim-export.ps1` into a target APIM
instance.

**Imports:** - APIs (OpenAPI + policy) - Products - Named Values
(metadata only, secrets must be re-bound, e.g. via Key Vault) -
Backends - Loggers - Diagnostics - Authorization Servers

**Usage:**

``` powershell
az login
az account set --subscription "<TARGET_SUBSCRIPTION_ID>"

.pim-import.ps1 `
  -SubscriptionId "<TARGET_SUBSCRIPTION_ID>" `
  -ResourceGroup "<TARGET_RG>" `
  -ApimName "<TARGET_APIM_NAME>" `
  -InFolder ".\out\extract"
```

------------------------------------------------------------------------

## ⚠️ Notes & Limitations

-   **Secrets**: Secret values in Named Values are **not exported** for
    security reasons. Reconfigure them manually or via Key Vault
    references in the target APIM.
-   **Subscriptions & Users**: API subscriptions and user accounts are
    not exported/imported. Handle them separately if needed.
-   **API ↔ Product links**: Currently not wired automatically. You can
    extend the import script to link APIs to products if required.
-   **API version**: Scripts use `2023-03-01-preview`. Adjust if your
    tenant enforces a different API version.

------------------------------------------------------------------------

## ✅ Requirements

-   [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
    installed
-   PowerShell 7+ (`pwsh`) recommended
-   Sufficient RBAC rights: **API Management Service Contributor** on
    the APIM resource

------------------------------------------------------------------------

## 🔗 References

-   [Azure CLI --- az apim](https://learn.microsoft.com/cli/azure/apim)
-   [Azure REST API for API
    Management](https://learn.microsoft.com/rest/api/apimanagement/)
