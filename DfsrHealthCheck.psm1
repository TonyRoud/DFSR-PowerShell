<#
    Module Name : DFSRHealthCheck
    Author      : Tony Roud
    Version     : 1.0

    To Do:
    Add a 'reset' parameter for Get-DfsrCriticalEvents to ignore anything before a specific time.
    Add 'exclude' parameter for Replicated folders that don't need to me monitored
    Add support for more than one DFSRDestination server
    Include replicated folder status WMI info in each folder check
#>

# Region monitoring functions
# Check for critical replication events in DFSR log (replication stopped on folder)
# Threshold is set in hours (default 1)
function Get-DfsrCriticalEvents {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]$threshold = 1
    )

    [System.String]$status = '0'
    $message = "No critical events found in DFSR log in the last $threshold hours."

    Write-Verbose "Checking for critical events in the DFSR log within the last $threshold hours"
    $startDate = ((Get-Date).addhours(-$threshold))
    $event = Get-WinEvent -Filterhashtable @{LogName='DFS Replication';StartTime=$startDate;Level=2,1;ID='2104','4004'} -erroraction Silentlycontinue | Select-Object -first 1

    if ($event)
    {
        [System.String]$status = '2'
        $message = "Warning - Critical DFSR replication events found in the last $threshold hours. Replication may have stopped for one or more replicated folders"
        Write-Warning 'Warning - Critical DFSR replication events found in the last 60 mins. Replication may have stopped for one or more replicated folders'
    }

    [PSCustomObject]@{
        'status'    = $status
        'message'   = $message
        'checkname' = 'DfsrCriticalEvents'
    }
}

# Basic health checks to see if WinRM and DFSR Services are running
function Get-DfsrServiceStatus {
    [CmdletBinding()]
    Param()

    [System.String]$status = '0'
    $message = 'DFSR Service is running'

    Write-Verbose 'Checking status of DFSR service'
    if (!((Get-Service -Name DFSR).Status -eq 'Running')) {
        [System.String]$status = '2'
        $message = 'Warning. DFSR Service is stopped. Check DFSR service urgently.'
        Write-Warning 'Warning. DFSR Service is stopped. Check DFSR service urgently.'
    }
    else
    {
        Write-Verbose 'DFSR Service is running'
    }
    [PSCustomObject]@{
        'message'   = $message
        'checkname' = 'DfsrServiceStatus'
        'status'    = $status
    }
}

function Get-WinRMServiceStatus {
    [CmdletBinding()]
    Param()

    [System.String]$status = '0'
    $message = 'WinRM Service is running'

    Write-Verbose 'Checking status of WinRM Service'
    if (!((Get-Service -Name WinRm).Status -eq 'Running')) {
        [System.String]$status = '1'
        $message = 'Warning. WinRM Service is stopped. This may cause alerts for DFSR backlog checks.'
        Write-Warning 'Warning. WinRM Service is stopped. This may cause alerts for DFSR backlog checks.'
    }
    else
    {
        Write-Verbose 'WinRM service is running'
    }
    [PSCustomObject]@{
        'message'   = $message
        'status'    = $status
        'Checkname' = 'WinRMServiceStatus'
    }
}
# Function to query WMI and return replication status code for replicated folder
function Get-ReplicatedFolderState {
    [CmdletBinding()]
    [String[]]$warningFolders = @()
    [System.String]$status = '1'
    [System.String]$message = 'Unable to determine status for DFS replicated folders using WMI. Check DFSR health manually.'

    Write-Verbose "Checking replicated folder status via WMI"
    $replicatedfolders = Get-WmiObject -Namespace "root\Microsoft\Windows\DFSR" -Class msft_dfsrreplicatedfolderinfo | Select-Object replicatedfoldername,state
    Foreach ($replicatedFolder in $replicatedfolders)
    {
        If ($replicatedfolder.state -ne '4'){$warningFolders += $($replicatedfolder.name)}
    }
    if ($warningFolders.count -ge 1)
    {
        Write-Warning "Found one or more DFS replicated folders in abnormal state. Investigate DFSR replication health."
        [System.String]$badfolders = $warningFolders | foreach-object {$_ + ','}
        [System.String]$message = "Found one or more DFS replicated folders in abnormal state. Investigate DFSR replication health for folder(s): $badfolders"
        $status = '2'
    }
    elseif ($warningFolders.count -lt 1)
    {
        Write-Verbose "WMI shows all DFS replicated folders are healthy."
        $status = '0'
        $message = 'All DFS replicated folders are healthy.'
    }
    [PSCustomObject]@{
        'status'  = $status
        'message' = $message
    }
}
# Get a count of replication groups and replicated folders
function Get-DfsrFolderInformation {
    [CmdletBinding()]
        Param(
            [Parameter(Mandatory=$true)]$replicatedFolder
        )

    $connectionWarning = $false
    $dfsrFolderInfo = Get-DfsReplicatedFolder -FolderName $replicatedFolder -Verbose

    try
    {
        Write-Verbose "Checking DFSR Connection info for $replicatedFolder"
        $dfsrConnections = Get-DfsrConnection -GroupName $($dfsrFolderInfo.Groupname) | Where-Object { $_.SourceComputerName -eq $env:COMPUTERNAME }
    }
    catch
    {
        $connectionWarning = $true
        Write-Warning "Unable to get DFSR connection info for $replicatedFolder. Check DFSR health"
    }

    [PSCustomObject]@{
        'DfsrGroup'               = $dfsrFolderInfo.Groupname
        'ReplicatedFolder'        = $replicatedFolder
        'DfsrSourceComputer'      = $dfsrConnections.SourceComputerName
        'DfsrDestinationComputer' = $dfsrConnections.DestinationComputerName
        'ConnectionWarning'       = $connectionWarning
    }
}
# Get DFSR Backlog count
function Get-DfsrBacklogCount {
    [CmdletBinding()]
        Param (
            [Parameter(Mandatory=$true)]$dfsrGroup,
            [Parameter(Mandatory=$true)]$replicatedFolder,
            [Parameter(Mandatory=$true)]$dfsrSourceComputer,
            [Parameter(Mandatory=$true)]$dfsrDestinationComputer
        )

    [Bool]$errorStatus = $false
    $backlogCount = "N/A"

    try
    {
        $backlogmsg = $( $null = Get-DfsrBacklog -GroupName $dfsrGroup -FolderName $replicatedFolder -SourceComputerName $dfsrSourceComputer -DestinationComputerName $dfsrDestinationComputer -Verbose -erroraction stop ) 4>&1
    }
    catch
    {
        Write-Warning 'Unable to calculate backlog information, check DFSR Services are running'
        $errorStatus = $true
    }

    if (!$errorStatus)
    {
        if ($backlogmsg -match 'No backlog for the replicated folder')
        {
            $backlogCount = 0
        }
        else
        {
            try
            {
                $backlogCount = [int]$($backlogmsg -replace "The replicated folder has a backlog of files. Replicated folder: `"$replicatedFolder`". Count: (\d+)",'$1')
            }
            Catch
            {
                Write-Warning "Unable to extract backlog count from Get-DfsrBacklog output. Manually check the command is returning data for $replicatedFolder."
                $errorStatus = $true
            }
        }
    }

    [PSCustomObject]@{
        'BacklogCount'= $backlogCount
        'ErrorStatus' = $errorStatus
        'Checkname'   = "DFSRRepl_$replicatedFolder"
    }
}
# End region monitoring functions

# Region DFSR Healthcheck functions
# These will call the monitoring functions and parse the values to generate the final output
function Get-DfsrHealthCheck {
    [CmdletBinding()]
        Param (
            [Parameter(Mandatory=$true)]$folder,
            [Parameter(Mandatory=$true)]$WarnThreshold,
            [Parameter(Mandatory=$true)]$CritThreshold
        )

    $checkName = "DFSRRepl_$replicatedFolder"
    $dfsrReplicatedFolderInfo = Get-DfsrFolderInformation -replicatedFolder $folder

    if ($dfsrReplicatedFolderInfo.ConnectionWarning)
    {
        [System.String]$status = '2'
        $message = "Unable to confirm connection details for folder $folder on $env:COMPUTERNAME. Check DFSR services are started."
        Write-Warning "Unable to confirm connection details for folder $folder on $env:COMPUTERNAME. Check DFSR services are started."
    }
    else
    {
        Write-Verbose "Checking for backlog for replicated folder $folder"
        $backlogCheck = Get-DfsrBacklogCount -replicatedFolder $folder -dfsrGroup $($dfsrReplicatedFolderInfo.DfsrGroup) -dfsrSourceComputer $($dfsrReplicatedFolderInfo.DfsrSourceComputer) -dfsrDestinationComputer $($dfsrReplicatedFolderInfo.DfsrDestinationComputer) -Verbose

        if ($backlogCheck.ErrorStatus)
        {
            [System.String]$status = '2'
            $message = "Unable to calculate backlog for folder $folder on $env:COMPUTERNAME. Check DFSR services are started."
            Write-Warning "Unable to calculate backlog for folder $folder on $env:COMPUTERNAME. Check DFSR services are started."
        }
        elseif ( $backlogCheck.backlogCount -ge $critthreshold )
        {
            [System.String]$status = '2'
            $message = "Backlog count for folder `"$folder`" in replication group `"$($dfsrReplicatedFolderInfo.DfsrGroup)`" is $($backlogCheck.backlogCount). Check DFSR replication health urgently."
            Write-warning "Backlog count for folder `"$folder`" in replication group `"$($dfsrReplicatedFolderInfo.DfsrGroup)`" is $($backlogCheck.backlogCount). Check DFSR replication health urgently."
        }
        elseif ( $backlogCheck.backlogCount -ge $warnThreshold )
        {
            [System.String]$status = '1'
            $message = "Backlog count for folder `"$folder`" in replication group `"$($dfsrReplicatedFolderInfo.DfsrGroup)`" is $($backlogCheck.backlogCount). Check DFSR replication health."
            Write-Warning "Backlog count for folder `"$folder`" in replication group `"$($dfsrReplicatedFolderInfo.DfsrGroup)`" is $($backlogCheck.backlogCount). Check DFSR replication health."
        }
        elseif ( $backlogCheck.backlogCount -gt 0 )
        {
            [System.String]$status = '0'
            $message = "Backlog count for folder `"$folder`" in replication group `"$($dfsrReplicatedFolderInfo.DfsrGroup)`" is $($backlogCheck.backlogCount)."
        }
        elseif ( $backlogCheck.backlogCount -eq 0 )
        {
            [System.String]$status = '0'
            $message = "Backlog count for folder `"$folder`" in replication group `"$($dfsrReplicatedFolderInfo.DfsrGroup)`" is 0."
        }
    }
    [PSCustomObject]@{
        'status'    = $status
        'message'   = $message
        'Checkname' = $backlogCheck.checkName
    }
}
# End region DFSR Healthcheck functions