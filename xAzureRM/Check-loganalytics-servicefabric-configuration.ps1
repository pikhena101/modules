<#

    Verify Service Fabric and OMS configuration

    1. Read Service Fabric diagnostics configuration
    2. Check for data being written into the tables
    3. Verify OMS is configured to read from the tables

    Supported tables:
    WADServiceFabricReliableActorEventTable
    WADServiceFabricReliableServiceEventTable
    WADServiceFabricSystemEventTable
    WADETWEventTable

    Script will write a warning for every misconfiguration detected
    To see items that are correctly configured set $VerbosePreference="Continue"
#>
Param
(
    [Parameter(Mandatory=$true,
    ValueFromPipeline=$true,
    Position=1)]
    [string]$workspaceName
)

$WADtables = @("WADServiceFabricReliableActorEventTable", 
               "WADServiceFabricReliableServiceEventTable",
               "WADServiceFabricSystemEventTable",
               "WADETWEventTable"
               )

<#
    Check if OMS Log Analytics is configured to index service fabric events from the specified table
#>

function Check-OMSLogAnalyticsConfiguration {
    param(
    [psobject]$workspace,
    [psobject]$storageAccount,
    [string]$id
    )

    $existingInsights = Get-AzureRmOperationalInsightsStorageInsight -ResourceGroupName $workspace.ResourceGroupName -WorkspaceName $workspace.Name 

    if ($existingInsights)
    {
        $currentStorageAccountInsight = $existingInsights.Where({$_.StorageAccountResourceId -eq $storageAccount.ResourceId})
        
        if ("WADServiceFabric*EventTable" -in $currentStorageAccountInsight.Tables)
        {
            Write-Verbose ("OMS Log Analytics workspace " + $workspace.Name + " is configured to index service fabric actor, service and operational events from " + $storageAccount.Name)
        } else
        {
            Write-Warning ("OMS Log Analytics workspace " + $workspace.Name + " is not configured to index service fabric actor, service and operational events from " + $storageAccount.Name)
        }
        if ("WADETWEventTable" -in $currentStorageAccountInsight.Tables)
        {
            Write-Verbose ("OMS Log Analytics workspace " + $workspace.Name + " is configured to index service fabric application events from " + $storageAccount.Name)
        } else
        {
            Write-Warning ("OMS Log Analytics workspace " + $workspace.Name + " is not configured to index service fabric application events from " + $storageAccount.Name)
        }
    } else
    {
        Write-Warning ("OMS Log Analytics workspace " + $workspace.Name + "is not configured to read service fabric events from " + $storageAccount.Name)
    }    
}

<#
    Check Azure table storage to confirm there is recent data written by Service Fabric
#>

function Check-TablesForData {
    param(
    [psobject]$storageAccount
    )

    $ctx = (Get-AzureRmStorageAccount -ResourceGroupName $storageAccount.ResourceGroupName -Name $storageAccount.ResourceName).Context

    $createdTables = Get-AzureStorageTable -Context $ctx

    $recently = Get-Date -Format s ((Get-Date).AddMinutes(-20).ToUniversalTime())
    $recently = $recently + "Z" 

    foreach ($table in $WADtables)
    {
        if ($table -in $createdTables.Name)
        {
            $tbl = Get-AzureStorageTable -Name $table -Context $ctx

            $query = New-Object Microsoft.WindowsAzure.Storage.Table.TableQuery

            $list = New-Object System.Collections.Generic.List[string]
            $list.Add("RowKey")
            $list.Add("ProviderName")
            $list.Add("Timestamp")


            $query.FilterString = "Timestamp gt datetime'$recently'"
            $query.SelectColumns = $list
            $query.TakeCount = 20

            $entities = $tbl.CloudTable.ExecuteQuery($query)

            Write-Debug $entities
            
            if ($entities.Count -gt 0)
            {
                Write-Verbose ("Data was written to $table in " + $storageAccount.ResourceName + "after $recently")
            } else
            {
                Write-Warning ("No data after $recently is in  $table in " + $storageAccount.ResourceName)
            }
        } else
        {
            Write-Warning ("$table does not exist in storage account " + $storageAccount.ResourceName)
        }
    }
}

<#
    Check if ETW provider is configured to log events to the expected table storage
#>
function Check-ETWProviderLogging {
    param(
    [string]$id,
    [string]$provider,
    [string]$expectedTable,
    [string]$table
    )      
        Write-Debug ("ID: $id Provider: $provider ExpectedTable $expectedTable ActualTable $table")
        if ( ($table -eq $null) -or ($table -eq "")) 
        {
            Write-Warning ("$id No configuration found for $provider. Configure Azure diagnostics to write to $expectedTable.")
        } 
        elseif ( $table -ne $expectedTable )
        {
            Write-Warning ("$id $provider events are being written to $table instead of WAD$expectedTable. Events will not be collected by OMS")
        } 
        else
        {
            Write-Verbose "$id $provider events are being written to WAD$expectedTable (Correct configuration.)"
        }
}

<#
    Check Azure Diagnostics Configuration for a Service Fabric cluster
#>
function Check-ServiceFabricVMDiagnostics {
    param(
    [array]$serviceFabricVMs
    )

    $storageAccountsFound = @()

    foreach($vm in $serviceFabricVMs) 
    {
        $id = $cluster.Name + "\" + $vm.Name
        Write-Verbose ("Checking $id")
        $sfReliableActorTable = $null
        $sfReliableServiceTable = $null
        $sfOperationalTable = $null

        $DiagnosticSettings = (Get-AzureRmVMDiagnosticsExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.ResourceName)

        if ( $DiagnosticSettings.PublicSettings ) 
        {
            Write-Debug ("Diagnostics version: " + $DiagnosticSettings.TypeHandlerVersion)

            $publicSettings = ConvertFrom-Json -InputObject $DiagnosticSettings.PublicSettings

            Write-Debug $publicSettings

            $serviceFabricProviderList = ""
            $etwManifestProviderList = ""
    
            if ( $publicSettings.xmlCfg ) 
            {
                Write-Debug ("Found XMLcfg")

                $xmlCfg = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($publicSettings.xmlCfg))

                Write-Debug $xmlCfg

                $etwProviders = Select-Xml -Content $xmlCfg -XPath "//EtwProviders"                

                $serviceFabricProviderList = $etwProviders.Node.EtwEventSourceProviderConfiguration
                $etwManifestProviderList = $etwProviders.Node.EtwManifestProviderConfiguration
            } elseif ($publicSettings.WadCfg ) 
            {
                Write-Debug ("Found WADcfg")
            
                Write-Debug $publicSettings.WadCfg

                $serviceFabricProviderList = $publicSettings.WadCfg.DiagnosticMonitorConfiguration.EtwProviders.EtwEventSourceProviderConfiguration
                $etwManifestProviderList = $publicSettings.WadCfg.DiagnosticMonitorConfiguration.EtwProviders.EtwManifestProviderConfiguration                                             
            } else
            {
                Write-Error "Unable to parse Azure Diagnostics setting for $id"
            }

            foreach ($provider in $serviceFabricProviderList) 
            {
                Write-Debug ("Event Source Provider: " + $provider.Provider + " Destination: " + $provider.DefaultEvents.eventDestination)
                if ($provider.Provider -eq "Microsoft-ServiceFabric-Actors")
                {
                    $sfReliableActorTable = $provider.DefaultEvents.eventDestination 
                } elseif ($provider.Provider -eq "Microsoft-ServiceFabric-Services") 
                { 
                    $sfReliableServiceTable = $provider.DefaultEvents.eventDestination 
                } else 
                {
                    Check-ETWProviderLogging $id $provider.Provider "ETWEventTable" $provider.DefaultEvents.eventDestination
                }
            }
            foreach ($provider in $etwManifestProviderList)
            {
                Write-Debug ("Manifest Provider: " + $provider.Provider + " Destination: " + $provider.DefaultEvents.eventDestination)
                if ($provider.Provider -eq "cbd93bc2-71e5-4566-b3a7-595d8eeca6e8")
                {
                    $sfOperationalTable = $provider.DefaultEvents.eventDestination 
                } else 
                {
                    Check-ETWProviderLogging $id $provider.Provider "ETWEventTable" $provider.DefaultEvents.eventDestination
                }
            }
            
            Check-ETWProviderLogging $id "Microsoft-ServiceFabric-Actors" "ServiceFabricReliableActorEventTable" $sfReliableActorTable
            Check-ETWProviderLogging $id "Microsoft-ServiceFabric-Services" "ServiceFabricReliableServiceEventTable" $sfReliableServiceTable
            Check-ETWProviderLogging $id "cbd93bc2-71e5-4566-b3a7-595d8eeca6e8 (System events)" "ServiceFabricSystemEventTable" $sfOperationalTable
            
            Write-Verbose ("StorageAccount: " + $publicSettings.StorageAccount)

            $storageAccountsFound += ($publicSettings.StorageAccount)

        } else {
            Write-Warning ("$id does not have diagnostics enabled")
        }
    }
    return ($storageAccountsFound)
}

# This script uses Get-AzureRmVMDiagnosticsExtension and needs a version where -Name is not a required parameter
Import-Module AzureRM.Compute -MinimumVersion 1.2.2

try
{
    Get-AzureRmContext
}
catch [System.Management.Automation.PSInvalidOperationException]
{
    Login-AzureRmAccount
}

$allResources = Get-AzureRmResource

$OMSworkspace = $allResources.Where({($_.ResourceType -eq "Microsoft.OperationalInsights/workspaces") -and ($_.ResourceName -eq $workspaceName)})

if ($OMSworkspace.Name -ne $workspaceName) 
{
    Write-Error ("Unable to find OMS Workspace " + $workspaceName)
}

$serviceFabricClusters = $allResources.Where({$_.ResourceType -eq "Microsoft.ServiceFabric/clusters"})

$storageAccountList = @()

foreach($cluster in $serviceFabricClusters) {
    Write-Verbose ("Checking cluster: " + $cluster.Name)
    $serviceFabricVMs = ($allResources.Where({($_.ResourceType -eq "Microsoft.Compute/virtualMachines") -and ($_.ResourceGroupName -eq $cluster.ResourceGroupName)}))

    $storageAccountList += (Check-ServiceFabricVMDiagnostics $serviceFabricVMs)
}

$storageAccountList = $storageAccountList | Sort-Object | Get-Unique

$storageAccountsToCheck = ($allResources.Where({($_.ResourceType -eq "Microsoft.Storage/storageAccounts") -and ($_.ResourceName -in $storageAccountList)}))

foreach($storageAccount in $storageAccountsToCheck)
{
    Check-TablesForData $storageAccount
    Check-OMSLogAnalyticsConfiguration $OMSworkspace $storageAccount
}
