
configuration ConfigSFCI
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$svcCreds,

        [Parameter(Mandatory)]
        [String]$ClusterName,

        [Parameter(Mandatory)]
        [String]$SQLClusterName,

        [Parameter(Mandatory)]
        [String]$vmNamePrefix,

        [Parameter(Mandatory)]
        [Int]$vmCount,

        [Parameter(Mandatory)]
        [Int]$vmDiskSize,

        [Parameter(Mandatory)]
        [String]$witnessStorageName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$witnessStorageKey,

        [Parameter(Mandatory)]
        [String]$clusterIP,

        [String]$DomainNetbiosName = (Get-NetBIOSName -DomainName $DomainName),

        [Int]$RetryCount = 40,
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
        [string]$SQLUserDBDir = "${datadriveLetter}:\${datadrivelabel}",
        [string]$SQLUserDBLogDir = "${logdriveLetter}:\${logdrivelabel}",
        [string]$SQLTempDBDir = "${tempdbdriveLetter}:\${tempdbdrivelabel}",
        [string]$SQLTempDBLogDir = "${tempdbdriveLetter}:\${tempdbdrivelabel}",
        [string]$SQLBackupDir = "${datadriveLetter}:\BACKUP"
    )

    Import-DscResource -ModuleName xComputerManagement, xFailOverCluster, xActiveDirectory, xSOFS, xSQLServer, xPendingReboot, xNetworking
 
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$DomainFQDNCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    [string[]]$AdminUserNames = "${DomainNetbiosName}\Domain Admins"
    
    [System.Management.Automation.PSCredential]$ServiceCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($svcCreds.UserName)", $svcCreds.Password)
    [System.Management.Automation.PSCredential]$ServiceFQDNCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($svcCreds.UserName)", $svcCreds.Password)
    
    [System.Collections.ArrayList]$Nodes = @()
    For ($count = 0; $count -lt $vmCount; $count++) {
        $Nodes.Add($vmNamePrefix + $Count.ToString())
    }

    Node localhost
    {

        # Set LCM to reboot if needed
        LocalConfigurationManager {
            DebugMode          = "ForceModuleImport"
            RebootNodeIfNeeded = $true
        }
        
        WindowsFeature FC {
            Name   = "Failover-Clustering"
            Ensure = "Present"
        }

        WindowsFeature FailoverClusterTools { 
            Ensure    = "Present" 
            Name      = "RSAT-Clustering-Mgmt"
            DependsOn = "[WindowsFeature]FC"
        } 

        WindowsFeature FCPS {
            Name   = "RSAT-Clustering-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature ADPS {
            Name   = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature FS {
            Name   = "FS-FileServer"
            Ensure = "Present"
        }

        xWaitForADDomain DscForestWait 
        { 
            DomainName       = $DomainName 
            DomainUserCredential= $DomainCreds
            RetryCount       = $RetryCount 
            RetryIntervalSec = $RetryIntervalSec 
            DependsOn        = "[WindowsFeature]ADPS"
        }
        
        xComputer DomainJoin
        {
            Name       = $env:COMPUTERNAME
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn  = "[xWaitForADDomain]DscForestWait"
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
            DomainAdministratorCredential = $DomainCreds
            Nodes                         = $Nodes
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

        # Likelely redundant
        Script MoveClusterGroups1 {
            SetScript  = 'try {Get-ClusterGroup -ErrorAction SilentlyContinue | Move-ClusterGroup -Node $env:COMPUTERNAME -ErrorAction SilentlyContinue} catch {}'
            TestScript = 'return $false'
            GetScript  = '@{Result = "Moved Cluster Group"}'
            DependsOn  = "[Script]IncreaseClusterTimeouts"
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
            DependsOn  = "[Script]MoveClusterGroups1"
        }

        Script CleanSQL {
            SetScript  = 'C:\SQLServerFull\Setup.exe /Action=Uninstall /FEATURES=SQL,AS,RS,IS /INSTANCENAME=MSSQLSERVER /Q'
            TestScript = '(test-path -Path "C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\master.mdf") -eq $false'
            GetScript  = '@{Ensure = if ((test-path -Path "C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\master.mdf") -eq $false) {"Present"} Else {"Absent"}}'
            DependsOn  = "[Script]EnableS2D"
        }

        xPendingReboot Reboot1
        { 
            Name      = 'Reboot1'
            DependsOn = "[Script]CleanSQL"
        }

        Script MoveClusterGroups2 {
            SetScript  = 'try {Get-ClusterGroup -ErrorAction SilentlyContinue | Move-ClusterGroup -Node $env:COMPUTERNAME -ErrorAction SilentlyContinue} catch {}'
            TestScript = 'return $false'
            GetScript  = '@{Result = "Moved Cluster Group"}'
            DependsOn  = "[xPendingReboot]Reboot1"
        }

        xSQLServerFailoverClusterSetup PrepareMSSQLSERVER
        {
            DependsOn                  = "[Script]MoveClusterGroups2"
            Action                     = "Prepare"
            SourcePath                 = "C:\"
            SourceFolder               = "SQLServerFull"
            UpdateSource               = ""
            SetupCredential            = $DomainCreds
            Features                   = $SQLFeatures
            InstanceName               = $SQLInstance
            FailoverClusterNetworkName = $SQLClusterName
            SQLSvcAccount              = $ServiceCreds
            PSDSCRunAsCredential       = $DomainCreds
        }

        xFirewall SQLFirewall
        {
            Name        = "SQL Firewall Rule"
            DisplayName = "SQL Firewall Rule"
            Ensure      = "Present"
            Enabled     = "True"
            Profile     = ("Domain", "Private", "Public")
            Direction   = "Inbound"
            RemotePort  = "Any"
            LocalPort   = ("445", "1433", "37000", "37001")
            Protocol    = "TCP"
            Description = "Firewall Rule for SQL"
            DependsOn   = "[xSQLServerFailoverClusterSetup]PrepareMSSQLSERVER"
        }

        xPendingReboot Reboot2
        { 
            Name      = 'Reboot2'
            DependsOn = "[xFirewall]SQLFirewall"
        }

        Script MoveClusterGroups3 {
            SetScript  = 'try {Get-ClusterGroup -ErrorAction SilentlyContinue | Move-ClusterGroup -Node $env:COMPUTERNAME -ErrorAction SilentlyContinue} catch {}'
            TestScript = 'return $false'
            GetScript  = '@{Result = "Moved Cluster Group"}'
            DependsOn  = "[xPendingReboot]Reboot2"
        }

        xSQLServerFailoverClusterSetup CompleteMSSQLSERVER
        {
            DependsOn                  = "[Script]MoveClusterGroups3"
            Action                     = "Complete"
            SourcePath                 = "C:\"
            SourceFolder               = "SQLServerFull"
            UpdateSource               = ""
            SetupCredential            = $DomainCreds
            Features                   = $SQLFeatures
            InstanceName               = $SQLInstance
            FailoverClusterNetworkName = $SQLClusterName
            InstallSQLDataDir          = $InstallSQLDataDir 
            SQLUserDBDir               = $SQLUserDBDir
            SQLUserDBLogDir            = $SQLUserDBLogDir
            SQLTempDBDir               = $SQLTempDBDir
            SQLTempDBLogDir            = $SQLTempDBLogDir
            SQLBackupDir               = $SQLBackupDir
            FailoverClusterIPAddress   = $clusterIP
            SQLSvcAccount              = $ServiceCreds
            SQLSysAdminAccounts        = $AdminUserNames
            ASSysAdminAccounts         = $AdminUserNames
            PsDscRunAsCredential       = $DomainCreds
        }

        Script FixProbe {
            SetScript  = "Get-ClusterResource -Name 'SQL IP*' | Set-ClusterParameter -Multiple @{Address=${clusterIP};ProbePort=${ProbePort};SubnetMask='255.255.255.255';Network='Cluster Network 1';EnableDhcp=0} -ErrorAction SilentlyContinue | out-null;Get-ClusterGroup -Name 'SQL Server*' -ErrorAction SilentlyContinue | Move-ClusterGroup -ErrorAction SilentlyContinue"
            TestScript = "(Get-ClusterResource -name 'SQL IP*' | Get-ClusterParameter -Name ProbePort).Value -eq  ${probePort}"
            GetScript  = '@{Result = "Moved Cluster Group"}'
            DependsOn  = "[xSQLServerFailoverClusterSetup]CompleteMSSQLSERVER"
        }
    }
}

function Get-NetBIOSName { 
    [OutputType([string])]
    param(
        [string]$DomainName
    )

    if ($DomainName.Contains('.')) {
        $length = $DomainName.IndexOf('.')
        if ( $length -ge 16) {
            $length = 15
        }
        return $DomainName.Substring(0, $length)
    }
    else {
        if ($DomainName.Length -gt 15) {
            return $DomainName.Substring(0, 15)
        }
        else {
            return $DomainName
        }
    }
}

