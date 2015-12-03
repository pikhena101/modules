<#
    This module contains functions toconfigure an Operations Management Suite workspace (aka Operational Insights workspace) to read 
    Windows Azure Diagnostics from Azure storage accounts.

    It will enable all supported data types (currently Windows Event Logs, Syslog, Service Fabric Events, ETW Events, IIS Logs, Network Security Groups).

    It supports both classic and ARM storage accounts.

    If you have more than one OMS workspace you will be prompted for the workspace to configure.
    
    If you have more than one storage account you will be prompted for which storage account to configure.

    This allows you to pull data from storage accounts in one Azure subscription to another Azure subscription
#>

$supportedResourceTypes = ("Microsoft.ClassicCompute/virtualMachines", "Microsoft.Compute/virtualMachines", "Microsoft.Network/networkSecurityGroups")
$supportedResourceTypes = ("Microsoft.Network/networkSecurityGroups")


function Set-AzureContext {
    param(
    [string]$desiredSubscriptionId
    )

    if ( $desiredSubscriptionId -ne ((Get-AzureRmContext).Subscription).SubscriptionId ) {
        Select-AzureRmSubscription -SubscriptionId $desiredSubscriptionId
    }
}

function Select-AzureOperationalInsightsWorkspaceUI {
    param(
    [array]$allOpInsightsWorkspaces
    )

    $workspace = ""

    switch ($allOpInsightsWorkspaces.Count) {
        0 {Write-Error "No Operations Management Suite workspaces found"}
        1 {return $allOpInsightsWorkspaces}
        default { 
            $uiPrompt = "Enter the number corresponding to the workspace you want to configure.`n"

            $count = 1
            foreach ($workspace in $allOpInsightsWorkspaces) {
                $uiPrompt += "$count. " + $workspace.Name + " (" + $workspace.Location + ")`n" 
                $count++
            }
            $answer = (Read-Host -Prompt $uiPrompt) - 1 
            $workspace = $allOpInsightsWorkspaces[$answer]
        }  
    }
    return $workspace 
}

function Get-AllAzureResources {
    param (
    [array]$allSubs
    )    

    $allAzureResources = @()

    foreach ($sub in $allSubs) {
        Select-AzureRmSubscription -SubscriptionId $sub

        $allAzureResources += (Get-AzureRmResource)
    }

    return $allAzureResources
}

function Get-AzureStorageAccountKey {
    param(
    [string] $storageAccountId, 
    [string] $storageProvider
    )

    if($storageProvider -eq  "Microsoft.ClassicStorage") {
        Write-Verbose "Storage is of type Microsoft.ClassicStorage"

        $storageKey = (Get-AzureStorageKey -StorageAccountName $storageAccount.Name).Primary

        Write-Verbose $storageKey
    } elsif ($storageProvider -eq  "Microsoft.Storage") {
        Write-Verbose "`Storage is of type Microsoft.Storage"
        
        $storageKey = (Get-AzureRMStorageAccountKey -ResourceGroupName $storageAccount.ResourceGroupName -Name $storageAccount.Name).Key1

    } else {
        Write-Error "Unknown storage account type: $storageProvider"
    }

    Write-Debug $storageKey

    return $storageKey
}

function connect-monitorableToWorkspace {
    Param(
    [hash] $monitorable,
    [psobject] $workspace
    )

    foreach($storageAccountId in $monitorable.keys) {

        [array]$storageAccountParts = $storageAccountId.Split("/");
        $storageProvider = $storageAccountParts[$storageAccountParts.Count - 3];
        $storageAccountName = $storageAccountParts[$storageAccountParts.Count - 1];

        $logsToCollect = $monitorable[$storageAccountId]

        Set-AzureContext $workspace.SubscriptionId

        # get existing config from workspace
        Write-Verbose "Getting existing configuration from workspace"
        $existingInsights = Get-AzureRmOperationalInsightsStorageInsight -WorkspaceName $workspace.ResourceName -ResourceGroupName $workspace.ResourceGroupName
        
        
        
    }


    if($existingInsights -and $existingInsights.Count -gt 0) {
        Write-Verbose "Storage account already being monitored.`n"

        [boolean]$dirty = $false;
        $insightsToSave = $existingInsights[0]
        [array]$containers = $insightsToSave.properties.containers

        foreach($feature in $featureContainers) {
            if($containers -notcontains $feature) {
                $containers += $feature
                $dirty = $true;
                Write-Verbose "Adding Feature: $feature";
            }else{
                write-verbose "Already Configured: $feature";
            }
        }

        if($dirty -eq $true) {
            $saveUrl = $insightsToSave.id + "?api-version=2015-03-20"
            $insightsToSave.properties.containers = $containers
            
            $saveContent = $insightsToSave | ConvertTo-Json
            
            write-verbose "`nSaving updated configuration:`r`n$saveContent`n`n"
        
            $existingInsights | ConvertTo-Json -Compress | armclient PUT $saveUrl

            write-verbose "`n`nAll done!"

        } else {
            write-verbose "`n`nNothing to connect"
        }
    } else {
        write-host "Storage account not being monitored.`n"
    
        $insightId = $workspace.id + "/storageInsightConfigs/" + $storageAccountName + $workspace.name
    
        Set-AzureContext $storageAccount.SubscriptionId

        write-host "Retrieving storage account keys`n"
       
        [string]$accountKey = Get-AzureStorageAccountKey $storageAccountId $storageProvider
        $accountKey = $accountKey.Trim()
        write-host "`tFoundKey:$accountKey"
        $storageAccountConfig = @{
            id = $storageAccountId
            key = $accountKey
        }

        $newInsightConfig = @{
            id = $insightId
            type = "Microsoft.OperationalInsights/storageinsightconfigs"
            name = $storageAccountName + $workspace.name
            properties = @{
                containers = $featureContainers
                tables = @()
                storageAccount = $storageAccountConfig
            }
        }

        $saveUrl = $insightId + "?api-version=2015-03-20"
        $saveContent = $newInsightConfig | ConvertTo-Json -Compress
        
        write-host "`nSaving Storage Insight Configuration to workspace:`n`n$saveContent`n`n"
       
        $newInsightConfig | ConvertTo-Json | armclient PUT $saveUrl

        write-host "`n`nAll done!"
    }
}

function Get-AzureDiagnosticsForResource {
    param($resource)
    
    $diagResourceId = $resource.ResourceId + "/providers/microsoft.insights/diagnosticSettings/service"
    Write-Debug "GET $diagResourceId"
    
    Set-AzureContext $resource.SubscriptionId

    $diagnosticConfig = (Get-AzureRmResource -ResourceId $diagResourceId).Properties
    Write-Debug $diagnosticConfig

    return $diagnosticConfig
}

function Get-AllAzureResourcesWithDiagnosticsEnabled {
    param(
    [array]$monitorableResources
    )

    $diagnostics = @();

    foreach ($resource in $monitorableResources) {
        Write-Verbose ("Looking for diagnostics configuration for " + $resource.ResourceName)

        $diagnosticConfig = Get-AzureDiagnosticsForResource $resource

        Write-Host $diagnosticConfig

        if ($diagnosticConfig.StorageAccountId) {
            $diagnostics += @{ resource = $resource; diagnostics = $diagnosticConfig }
        } else {
            Write-Verbose ($resource.Name + " does not have diagnostics enabled, skipping...")
        }
    }

    return $diagnostics
}

function Get-UniqueStorageDiagnostics {
    param(
    [array]$storageDiagnostics
    )

    $uniqueDiagnostics = @{}
    
    foreach($diagnostic in $storageDiagnostics) {

    Write-Host ($diagnostic.diagnostics.StorageAccountId)

        foreach($log in $diagnostic.diagnostics.Logs) {
            
            Write-Host "    $log"

            if($log.enabled) {
                $uniqueDiagnostics[$diagnostic.diagnostics.StorageAccountId] += "insights-logs-" + $log.category + "/resourceId=" + $diagnostic.resource.resourceId + ";"               
            }
        }
    }

    return $uniqueDiagnostics
}


function Set-AzureOperationalInsightsMonitoringConfiguration {
    [CmdletBinding()]
    param(
    [Parameter(Mandatory=$false,
    ValueFromPipeline=$true,
    Position=1)]
    [psobject[]]
    $Subscriptions,
    [Parameter(Mandatory=$false,
    ValueFromPipeline=$true,
    Position=2)]
    [psobject[]]$allResources,
    [Parameter(Mandatory=$false,
    ValueFromPipeline=$false)]
    [psobject]$workspace
    )

    Begin {
        if (! $Subscriptions) {
            $Subscriptions = Get-AzureRmSubscription        
        }

        if (! $Resources) {
            $Resources = Get-AllAzureResources $Subscriptions
        }

        if (! $workspace) {
            $workspace = Select-AzureOperationalInsightsWorkspaceUI ($Resources.Where({$_.ResourceType -eq "Microsoft.OperationalInsights/workspaces"}))
        }
    }

    
    $monitorableResources = Get-AllAzureResourcesWithDiagnosticsEnabled ($allResources.Where({$_.ResourceType -in $supportedResourceTypes}))

    $uniqueStorage = Get-UniqueStorageDiagnostics $monitorableResources

    connect-monitorableToWorkspace $uniqueStorage $workspace

}

Login-AzureRmAccount

Set-AzureOperationalInsightsMonitoringConfiguration

Export-ModuleMember -Function Select-AzureOperationalInsightsWorkspaceUI, Get-AllAzureResources, Get-AzureDiagnosticsForResource, Get-AllAzureResourcesWithDiagnosticsEnabled, Get-UniqueStorageDiagnostics    


