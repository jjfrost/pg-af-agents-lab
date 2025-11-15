# ================== Inputs (Skillable tokens) ==================
$clientId             = "@lab.CloudSubscription.AppId"
$clientSecret         = "@lab.CloudSubscription.AppSecret"
$tenantId             = "@lab.CloudSubscription.TenantId"
$subscriptionId       = "@lab.CloudSubscription.Id"
$resourceGroupName    = "@lab.CloudResourceGroup(ResourceGroup1).Name"
$aadUserPrincipalName = "@lab.CloudPortalCredential(User1).Username"
$aadUserPassword      = "@lab.CloudPortalCredential(User1).Password"

# ================== Helper Functions ==================

function Wait-ArmOperation {
    param(
        [string]$StatusUri,
        [hashtable]$Headers,
        [string]$OperationName,
        [int]$TimeoutSeconds = 600,
        [int]$PollSeconds = 10
    )

    if (-not $StatusUri) {
        return
    }

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $PollSeconds
        $elapsed += $PollSeconds

        $statusResponse = Invoke-RestMethod -Uri $StatusUri -Method GET -Headers $Headers -ErrorAction Stop
        $state = $statusResponse.status
        if (-not $state) {
            $state = $statusResponse.properties.provisioningState
        }
        if (-not $state) {
            $state = $statusResponse.operationState
        }

        if (-not $state) {
            Write-Host "$OperationName status: (no state returned)"
            continue
        }

        Write-Host "$OperationName status: $state (${elapsed}s elapsed)"

        if ($state -in @("Succeeded", "Failed", "Canceled")) {
            if ($state -ne "Succeeded") {
                throw "$OperationName did not complete successfully (state: $state)"
            }
            return
        }
    }

    throw "$OperationName timed out after ${TimeoutSeconds}s"
}

function Invoke-ArmPutWithPolling {
    param(
        [string]$Uri,
        [string]$Body,
        [hashtable]$Headers,
        [string]$OperationName
    )

    $response = Invoke-WebRequest -Uri $Uri -Method PUT -Headers $Headers -Body $Body -UseBasicParsing -ErrorAction Stop

    $statusUri = $response.Headers['Azure-AsyncOperation']
    if (-not $statusUri) {
        $statusUri = $response.Headers.Location
    }

    if ($statusUri) {
        Wait-ArmOperation -StatusUri $statusUri -Headers $Headers -OperationName $OperationName
    }

    if ($response.Content -and $response.Content.Trim()) {
        try {
            return $response.Content | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return $response.Content
        }
    }

    return $null
}

Write-Host "Getting access token for Azure Management..."

# Get OAuth2 token for Azure Resource Manager
$tokenBody = @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSecret
    resource      = "https://management.azure.com/"
}

$tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/token" `
    -Method POST `
    -Body $tokenBody `
    -ContentType "application/x-www-form-urlencoded"

$token = $tokenResponse.access_token
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

Write-Host "Discovering PostgreSQL Flexible Server..."

# List PostgreSQL Flexible Servers in the resource group
$serversUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.DBforPostgreSQL/flexibleServers?api-version=2023-03-01-preview"

$serversResponse = Invoke-RestMethod -Uri $serversUri -Method GET -Headers $headers
$postgresServerName = $serversResponse.value[0].name

Write-Host "PostgreSQL Server: $postgresServerName"
Write-Host ""

# Set azure.extensions parameter
Write-Host "Setting azure.extensions parameter..."
$extensionsUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.DBforPostgreSQL/flexibleServers/$postgresServerName/configurations/azure.extensions?api-version=2023-03-01-preview"

$extensionsBody = @{
    properties = @{
        value  = "azure_ai,pg_diskann,vector,age,azure_storage"
        source = "user-override"
    }
} | ConvertTo-Json -Depth 4

Invoke-ArmPutWithPolling -Uri $extensionsUri -Headers $headers -Body $extensionsBody -OperationName "azure.extensions update"
Write-Host "azure.extensions parameter updated"
Write-Host ""

# Set shared_preload_libraries parameter
Write-Host "Setting shared_preload_libraries parameter..."
$preloadUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.DBforPostgreSQL/flexibleServers/$postgresServerName/configurations/shared_preload_libraries?api-version=2023-03-01-preview"

$preloadBody = @{
    properties = @{
        value  = "age,azure_storage,pg_cron,pg_stat_statements"
        source = "user-override"
    }
} | ConvertTo-Json -Depth 4

Invoke-ArmPutWithPolling -Uri $preloadUri -Headers $headers -Body $preloadBody -OperationName "shared_preload_libraries update"
Write-Host "shared_preload_libraries parameter updated"
Write-Host ""

# Restart the PostgreSQL server
Write-Host "Restarting PostgreSQL server (this will take 60-120 seconds)..."
$restartUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.DBforPostgreSQL/flexibleServers/$postgresServerName/restart?api-version=2023-03-01-preview"

$restartResponse = Invoke-WebRequest -Uri $restartUri -Method POST -Headers $headers -UseBasicParsing -ErrorAction Stop
$restartStatusUri = $restartResponse.Headers['Azure-AsyncOperation']
if (-not $restartStatusUri) {
    $restartStatusUri = $restartResponse.Headers.Location
}

if ($restartStatusUri) {
    Wait-ArmOperation -StatusUri $restartStatusUri -Headers $headers -OperationName "Server restart"
}
Write-Host "Server restart completed"

# Give the server a few seconds after ARM reports success
Write-Host "Waiting 15 seconds for server services to stabilize..."
Start-Sleep -Seconds 15

Write-Host ""

# Verify shared_preload_libraries configuration
Write-Host "Verifying shared_preload_libraries configuration..."
$verifyPreloadUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.DBforPostgreSQL/flexibleServers/$postgresServerName/configurations/shared_preload_libraries?api-version=2023-03-01-preview"

$preloadConfig = Invoke-RestMethod -Uri $verifyPreloadUri -Method GET -Headers $headers
$actualValue = $preloadConfig.properties.value
Write-Host "Configured shared_preload_libraries: $actualValue"

$expectedLibraries = @("age", "azure_storage", "pg_cron", "pg_stat_statements")
$allPresent = $true

foreach ($lib in $expectedLibraries) {
    if ($actualValue -like "*$lib*") {
        Write-Host "  $lib is present"
    }
    else {
        Write-Host "  $lib is MISSING"
        $allPresent = $false
    }
}

Write-Host ""

# Verify azure.extensions configuration
Write-Host "Verifying azure.extensions configuration..."
$verifyExtensionsUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.DBforPostgreSQL/flexibleServers/$postgresServerName/configurations/azure.extensions?api-version=2023-03-01-preview"

$extensionsConfig = Invoke-RestMethod -Uri $verifyExtensionsUri -Method GET -Headers $headers
$actualExtensions = $extensionsConfig.properties.value
Write-Host "Configured azure.extensions: $actualExtensions"

$expectedExtensions = @("azure_ai", "pg_diskann", "vector", "age", "azure_storage")

foreach ($ext in $expectedExtensions) {
    if ($actualExtensions -like "*$ext*") {
        Write-Host "  $ext is present"
    }
    else {
        Write-Host "  $ext is MISSING"
        $allPresent = $false
    }
}

Write-Host ""
if ($allPresent) {
    Write-Host "PostgreSQL server configuration complete!"
    Write-Host "The AGE extension and required libraries are now enabled."
}
else {
    Write-Host "WARNING: Some expected libraries or extensions are missing!"
    Write-Host "Please review the configuration above."
}