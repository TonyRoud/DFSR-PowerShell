# Grab replicated folders and the local folder paths
$ReplicatedFolder = Get-Dfsreplicatedfolder | Get-DfsrMembership | Where-Object { $_.computername -eq "$env:computername" } | Select-Object foldername, contentpath
Function Get-DfsStagingQuotaEstimate {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]$ReplicatedFolder
    )
    Foreach ($folder in $ReplicatedFolder) {

        Write-Verbose "`nChecking Folder: $($folder.foldername)"
        $Top32 = Get-ChildItem $folder.contentpath -recurse | Sort-Object length -descending | select-object -first 32

        Write-Verbose "Top 32 files in directory $($folder.contentpath)"
        Write-Verbose "`n $Top32 | ft name,length -wrap –auto"

        $Top32Sum = ($Top32 | Measure-Object 'length' -sum).sum
        $Top32GB = ([math]::truncate($Top32Sum / 1MB))
        Write-Output "`n`nTotal recommended staging quota size for $($folder.foldername) is $Top32GB MB"
    }
}

$healthy = @(
    'PROVISIONING'
    'CUSTOMIZING'
    'DELETING'
    'MAINTENANCE'
    'PROVISIONED'
    'CONNECTED'
    'ISCONNECTED'
    'AVAILABLE'
    'DISCONNECTED'
)