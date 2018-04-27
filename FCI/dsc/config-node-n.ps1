configuration ConfigNodeN
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$domainuserCreds,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$svcCreds,      
        [Parameter(Mandatory)]
        [String]$ClusterName,
        [Parameter(Mandatory)]
        [String]$SQLClusterName,
        [Parameter(Mandatory)]
        [String]$witnessStorageName,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$witnessStorageKey,
        [Parameter(Mandatory)]
        [String]$clusterIP,
        
        [Int]$RetryCount = 20,
        [Int]$RetryIntervalSec = 30,
        [Int]$probePort = 37000, 

        [string]$datadriveLetter,
        [string]$datadrivelabel,
        [string]$datadriveSize,
        [string]$logdriveLetter,
        [string]$logdrivelabel,
        [string]$logdriveSize,
        [string]$tempdbdriveLetter,
        [string]$tempdbdrivelabel,
        [string]$tempdbdriveSize,
        [string]$SQLFeatures,
        [string]$SQLInstance,
        [string]$InstallSQLDataDir,
        [string]$InstanceDir ="G:\",
        [string]$SQLUserDBDir = "G:\MSSQL",
        [string]$SQLUserDBLogDir = "L:\MSSQL",
        [string]$SQLTempDBDir = "T:\TEMPDB",
        [string]$SQLTempDBLogDir = "T:\TEMPDB",
        [string]$SQLBackupDir = "G:\BACKUP"
    )

    Import-DscResource -ModuleName xComputerManagement, xActiveDirectory, SQLServerDSC, xPendingReboot, xNetworking,xFailoverCluster

    Node localhost
    {
        # Set LCM to reboot if needed
        LocalConfigurationManager {
            DebugMode = "ForceModuleImport"
            RebootNodeIfNeeded = $true
        }

        WindowsFeature FC 
        {
            Name = "Failover-Clustering"
            Ensure = "Present"
        }
        
        WindowsFeature FailoverClusterTools { 
            Ensure    = "Present" 
            Name      = "RSAT-Clustering-Mgmt"
            DependsOn = "[WindowsFeature]FC"
        } 

        WindowsFeature FCPS 
        {
            Name = "RSAT-Clustering-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature ADPS 
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature FS
        {
            Name = "FS-FileServer"
            Ensure = "Present"
        }

        xWaitForADDomain DscForestWait
        { 
            DomainName = $DomainName 
            DomainUserCredential = $domainuserCreds
            RetryCount = $RetryCount 
            RetryIntervalSec = $RetryIntervalSec 
            DependsOn = "[WindowsFeature]ADPS"
        }

        xComputer DomainJoin
        {
            Name = $env:COMPUTERNAME
            DomainName = $DomainName
            Credential = $domainuserCreds
            DependsOn = "[xWaitForADDomain]DscForestWait"
        }
        
        Script MoveClusterGroups0 {
            SetScript  = 'try {Get-ClusterGroup -ErrorAction SilentlyContinue | Move-ClusterGroup -Node $env:COMPUTERNAME -ErrorAction SilentlyContinue} catch {}'
            TestScript = 'return $false'
            GetScript  = '@{Result = "Moved Cluster Group"}'
            DependsOn  = "[xComputer]DomainJoin"
        }

        xCluster FailoverCluster
        {
            Name                          = $ClusterName
            StaticIPAddress = '10.40.4.102'
            DomainAdministratorCredential = $domainuserCreds
            DependsOn                     = "[Script]MoveClusterGroups0"
        }

        Script CloudWitness {
            SetScript  = "Set-ClusterQuorum -CloudWitness -AccountName ${witnessStorageName} -AccessKey $($witnessStorageKey.GetNetworkCredential().Password)"
            TestScript = "(Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness'"
            GetScript  = "@{Ensure = if ((Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness') {'Present'} else {'Absent'}}"
            DependsOn  = "[xCluster]FailoverCluster"
        }

        Script IncreaseClusterTimeouts {
            SetScript  = "(Get-Cluster).SameSubnetDelay = 2000; (Get-Cluster).SameSubnetThreshold = 15; (Get-Cluster).CrossSubnetDelay = 3000; (Get-Cluster).CrossSubnetThreshold = 15"
            TestScript = "(Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15"
            GetScript  = "@{Ensure = if ((Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]CloudWitness"
        }

        Script EnableS2D {
            #SetScript  = "Enable-ClusterS2D -Confirm:0; New-Volume -StoragePoolFriendlyName S2D* -FriendlyName VDisk01 -FileSystem NTFS -DriveLetter ${driveLetter} -UseMaximumSize"
            #SetScript = Enable-ClusterS2D -Confirm:0;New-Volume -StoragePoolFriendlyName S2D* -FriendlyName ${datadrivelable} -FileSystem NTFS -AllocationUnitSize 65536 -DriveLetter ${datadriveLetter} -size ${datadriveSize};
            #latest Run Changes to include all three drives
            SetScript  = 
@"
                            Enable-ClusterS2D -Confirm:0; 
                            New-Volume -StoragePoolFriendlyName S2D* -FriendlyName ${datadrivelabel} -FileSystem NTFS -AllocationUnitSize 65536 -DriveLetter ${datadriveLetter} -size ${datadriveSize};
                            New-Volume -StoragePoolFriendlyName S2D* -FriendlyName ${logdrivelabel} -FileSystem NTFS -AllocationUnitSize 65536 -DriveLetter ${logdriveLetter} -size ${logdriveSize};
                            New-Volume -StoragePoolFriendlyName S2D* -FriendlyName ${tempdbdrivelabel} -FileSystem NTFS -AllocationUnitSize 65536 -DriveLetter ${tempdbdriveLetter} -size ${tempdbdriveSize};
"@
            TestScript = "(Get-StoragePool -FriendlyName S2D*).OperationalStatus -eq 'OK'"
            GetScript  = "@{Ensure = if ((Get-StoragePool -FriendlyName S2D*).OperationalStatus -eq 'OK') {'Present'} Else {'Absent'}}"
            DependsOn  = "[Script]CloudWitness"
        }
        Script CleanSQL
        {
            SetScript = 'C:\SQLServerFull\Setup.exe /Action=Uninstall /FEATURES=SQL,AS,IS,RS /INSTANCENAME=MSSQLSERVER /Q'
            TestScript = '(test-path -Path "C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\master.mdf") -eq $false'
            GetScript = '@{Ensure = if ((test-path -Path "C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\master.mdf") -eq $false) {"Present"} Else {"Absent"}}'
        }

        xPendingReboot Reboot1
        { 
            Name = "Reboot1"
            DependsOn = "[Script]CleanSQL"
        }
    }
}
