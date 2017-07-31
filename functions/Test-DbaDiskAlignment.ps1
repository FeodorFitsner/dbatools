function Test-DbaDiskAlignment
{
<#
    .SYNOPSIS
        Verifies that your non-dynamic disks are aligned according to physical constraints.
    
    .DESCRIPTION
        Returns $true or $false by default for one server. Returns Server name and IsBestPractice for more than one server.
        
        Specify -Detailed for additional information which returns some additional optional "best practice" columns, which may show false even though you pass the alignment test.
        This is because your offset is not one of the "expected" values that Windows uses, but your disk is still physically aligned.
        
        Please refer to your storage vendor best practices before following any advice below.
        By default issues with disk alignment should be resolved by a new installation of Windows Server 2008, Windows Vista, or later operating systems, but verifying disk alignment continues to be recommended as a best practice.
        While some versions of Windows use different starting alignments, if you are starting anew 1MB is generally the best practice offset for current operating systems (because it ensures that the partition offset % common stripe unit sizes == 0 )
        
        Caveats:
        Dynamic drives (or those provisioned via third party software) may or may not have accurate results when polled by any of the built in tools, see your vendor for details.
        Windows does not have a reliable way to determine stripe unit Sizes. These values are obtained from vendor disk management software or from your SAN administrator.
        System drives in versions previous to Windows Server 2008 cannot be aligned, but it is generally not recommended to place SQL Server databases on system drives.
    
    .PARAMETER ComputerName
        The SQL Server(s) you would like to connect to and check disk alignment.
    
    .PARAMETER Detailed
        DEPRECATED: This parameter will be removed on version 1.0.0.0
        This parameter used to show additional disk details such as offset calculations and IsOffsetBestPractice, which returns false if you do not have one of the offsets described by Microsoft. Returning false does not mean you are not phyiscally aligned.
    
    .PARAMETER Credential
        An alternate domain/username when enumerating the drives on the SQL Server(s), if needed password will be requested when queries run. May require Administrator privileges.
    
    .PARAMETER SQLCredential
        An alternate SqlCredential object when connecting to and verifying the location of the SQL Server databases on the target SQL Server(s).
    
    .PARAMETER NoSqlCheck
        Skip checking for the presence of SQL Server and simply check all disks for alignment. This can be useful if SQL Server is not yet installed or is dormant.
    
    .PARAMETER Silent
        Use this switch to disable any kind of verbose messages.
        Setting this will cause the function to throw exceptions when something breaks, which can then be caught by the caller.
    
    .EXAMPLE
        Test-DbaDiskAlignment -ComputerName sqlserver2014a
        
        Tests the disk alignment of a single server named sqlserver2014a
    
    .EXAMPLE
        Test-DbaDiskAlignment -ComputerName sqlserver2014a, sqlserver2014b, sqlserver2014c
        
        Tests the disk alignment of mulitiple servers
    
    .NOTES
        Tags: Storage
        The preferred way to determine if your disks are aligned (or not) is to calculate:
        1. Partition offset - stripe unit size
        2. Stripe unit size - File allocation unit size
        
        References:
        Disk Partition Alignment Best Practices for SQL Server - https://technet.microsoft.com/en-us/library/dd758814(v=sql.100).aspx
        A great article and behind most of this code.
        
        Getting Partition Offset information with Powershell - http://sqlblog.com/blogs/jonathan_kehayias/archive/2010/03/01/getting-partition-Offset-information-with-powershell.aspx
        Thanks to Jonathan Kehayias!
        
        Decree: Set your partition Offset and block Size and make SQL Server faster - http://www.midnightdba.com/Jen/2014/04/decree-set-your-partition-Offset-and-block-Size-make-sql-server-faster/
        Thanks to Jen McCown!
        
        Disk Performance Hands On - http://www.kendalvandyke.com/2009/02/disk-performance-hands-on-series-recap.html
        Thanks to Kendal Van Dyke!
        
        Get WMI Disk Information - http://powershell.com/cs/media/p/7937.aspx
        Thanks to jbruns2010!
        
        Original Author: Constantine Kokkinos (https://constantinekokkinos.com, @mobileck)
        
        dbatools PowerShell module (https://dbatools.io, clemaire@gmail.com,)
        Copyright (C) 2016 Chrissy Lemaire
        
        This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
        
        This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
        
        You should have received a copy of the GNU General Public License along with this program.  If not, see <http://www.gnu.org/licenses/>.
    
    .LINK
        https://dbatools.io/Test-DbaDiskAlignment
#>    
    Param (
        [parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Alias("ServerInstance", "SqlServer", "SqlInstance")]
        [DbaInstanceParameter[]]$ComputerName,
        
        [switch]
        $Detailed,
        
        [System.Management.Automation.PSCredential]
        $Credential,
        
        [System.Management.Automation.PSCredential]
        $SqlCredential,
        
        [switch]
        $NoSqlCheck,
        
        [switch]
        $Silent
    )
    BEGIN
    {
        Test-DbaDeprecation -DeprecatedOn "1.0.0.0" -Parameter 'Detailed' 
        
        $sessionoption = New-CimSessionOption -Protocol DCom
        
        Function Get-DiskAlignment
        {
            [CmdletBinding()]
            Param (
                $CimSession,
                
                [string]
                $FunctionName = (Get-PSCallStack)[0].Command,
                
                [bool]
                $NoSqlCheck,
                
                [string]
                $ComputerName,
                
                [System.Management.Automation.PSCredential]
                $SqlCredential,
                
                [bool]
                $Silent = $Silent
            )
            
            $SqlInstances = @()
            $offsets = @()
            
            #region Retrieving partition/disk Information
            try
            {
                Write-Message -Level Verbose -Message "Gathering information about first partition on each disk for $ComputerName" -FunctionName $FunctionName
                
                try
                {
                    $partitions = Get-CimInstance -CimSession $CimSession -ClassName Win32_DiskPartition -Namespace "root\cimv2" -ErrorAction Stop
                }
                catch
                {
                    if ($_.Exception -match "namespace")
                    {
                        Stop-Function -Message "Can't get disk alignment info for $ComputerName. Unsupported operating system." -InnerErrorRecord $_ -Target $ComputerName -FunctionName $FunctionName
                        return
                    }
                    else
                    {
                        Stop-Function -Message "Can't get disk alignment info for $ComputerName. Check logs for more details." -InnerErrorRecord $_ -Target $ComputerName -FunctionName $FunctionName
                        return
                    }
                }
                
                
                $disks = @()
                $disks += $($partitions | ForEach-Object {
                        Get-CimInstance -CimSession $CimSession -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=""$($_.DeviceID.Replace("\", "\\"))""} WHERE AssocClass = Win32_LogicalDiskToPartition" |
                        Add-Member -Force -MemberType noteproperty -Name BlockSize -Value $_.BlockSize -PassThru |
                        Add-Member -Force -MemberType noteproperty -Name BootPartition -Value $_.BootPartition -PassThru |
                        Add-Member -Force -MemberType noteproperty -Name DiskIndex -Value $_.DiskIndex -PassThru |
                        Add-Member -Force -MemberType noteproperty -Name Index -Value $_.Index -PassThru |
                        Add-Member -Force -MemberType noteproperty -Name NumberOfBlocks -Value $_.NumberOfBlocks -PassThru |
                        Add-Member -Force -MemberType noteproperty -Name StartingOffset -Value $_.StartingOffset -PassThru |
                        Add-Member -Force -MemberType noteproperty -Name Type -Value $_.Type -PassThru
                    } |
                    Select-Object BlockSize, BootPartition, Description, DiskIndex, Index, Name, NumberOfBlocks, Size, StartingOffset, Type
                )
                Write-Message -Level Verbose -Message "Gathered CIM information." -FunctionName $FunctionName
            }
            catch
            {
                Stop-Function -Message "Can't connect to CIM on $ComputerName" -FunctionName $FunctionName -InnerErrorRecord $_
                return
            }
            #endregion Retrieving partition Information
            
            #region Retrieving Instances
            if (-not $NoSqlCheck)
            {
                Write-Message -Level Verbose -Message "Checking for SQL Services" -FunctionName $FunctionName
                $sqlservices = Get-CimInstance -ClassName Win32_Service -CimSession $CimSession | Where-Object DisplayName -like 'SQL Server (*'
                foreach ($service in $sqlservices)
                {
                    $instance = $service.DisplayName.Replace('SQL Server (', '')
                    $instance = $instance.TrimEnd(')')
                    
                    $instancename = $instance.Replace("MSSQLSERVER", "Default")
                    Write-Message -Level Verbose -Message "Found instance $instancename" -FunctionName $FunctionName
                    if ($instance -eq 'MSSQLSERVER')
                    {
                        $SqlInstances += $ComputerName
                    }
                    else
                    {
                        $SqlInstances += "$ComputerName\$instance"
                    }
                }
                $sqlcount = $SqlInstances.Count
                Write-Message -Level Verbose -Message "$sqlcount instance(s) found" -FunctionName $FunctionName
            }
            #endregion Retrieving Instances
            
            #region Offsets
            foreach ($disk in $disks)
            {
                if (!$disk.name.StartsWith("\\"))
                {
                    $diskname = $disk.Name
                    if ($NoSqlCheck -eq $false)
                    {
                        $sqldisk = $false
                        
                        foreach ($SqlInstance in $SqlInstances)
                        {
                            Write-Message -Level Verbose -Message "Connecting to SQL instance ($SqlInstance)" -FunctionName $FunctionName
                            try
                            {
                                if ($SqlCredential -ne $null)
                                {
                                    $smoserver = Connect-SqlInstance -SqlInstance $SqlInstance -SqlCredential $SqlCredential
                                }
                                else
                                {
                                    $smoserver = Connect-SqlInstance -SqlInstance $SqlInstance # win auth
                                }
                                $sql = "Select count(*) as Count from sys.master_files where physical_name like '$diskname%'"
                                Write-Message -Level Verbose -Message "Query is: $sql" -FunctionName $FunctionName
                                Write-Message -Level Verbose -Message "SQL Server is: $SqlInstance" -FunctionName $FunctionName
                                $sqlcount = $smoserver.Databases['master'].ExecuteWithResults($sql).Tables[0].Count
                                if ($sqlcount -gt 0)
                                {
                                    $sqldisk = $true
                                    break
                                }
                            }
                            catch
                            {
                                Stop-Function -Message "Can't connect to $ComputerName ($SqlInstance)" -FunctionName $FunctionName -InnerErrorRecord $_
                                return
                            }
                        }
                    }
                    
                    if ($NoSqlCheck -eq $false)
                    {
                        if ($sqldisk -eq $true)
                        {
                            $offsets += $disk
                        }
                    }
                    else
                    {
                        $offsets += $disk
                    }
                }
            }
            #endregion Offsets
            
            #region Processing results
            Write-Message -Level Verbose -Message "Checking $($offsets.count) partitions." -FunctionName $FunctionName
            
            $allpartitions = @()
            foreach ($partition in $offsets)
            {
                # Unfortunately "Windows does not have a reliable way to determine stripe unit Sizes. These values are obtained from vendor disk management software or from your SAN administrator."
                # And this is the #1 most impactful issue with disk alignment :D
                # What we can do is test common stripe unit Sizes against the Offset we have and give advice if the Offset they chose would work in those scenarios               
                $offset = $partition.StartingOffset/1kb
                $type = $partition.Type
                $stripe_units = @(64, 128, 256, 512, 1024) # still wish I had a better way to verify this or someone to pat my back and say its alright.            
                
                # testing dynamic disks, everyone states that info from dynamic disks is not to be trusted, so throw a warning.
                Write-Message -Level Verbose -Message "Testing for dynamic disks" -FunctionName $FunctionName
                if ($type -eq "Logical Disk Manager")
                {
                    $IsDynamicDisk = $true
                    Write-Message -Level Warning -Message "Disk is dynamic, all Offset calculations should be suspect, please refer to your vendor to determine actuall Offset calculations." -FunctionName $FunctionName
                }
                else
                {
                    $IsDynamicDisk = $false
                }
                
                Write-Message -Level Verbose -Message "Checking for best practices offsets" -FunctionName $FunctionName
                
                if ($offset -ne 64 -and $offset -ne 128 -and $offset -ne 256 -and $offset -ne 512 -and $offset -ne 1024)
                {
                    $IsOffsetBestPractice = $false
                }
                else
                {
                    $IsOffsetBestPractice = $true
                }
                
                # as we cant tell the actual size of the file strip unit, just check all the sizes I know about                       
                foreach ($size in $stripe_units)
                {
                    if ($offset % $size -eq 0) # for proper alignment we really only need to know that your offset divided by your stripe unit size has a remainer of 0 
                    {
                        $OffsetModuloKB = "$($offset % $size)"
                        $isBestPractice = $true
                    }
                    else
                    {
                        $OffsetModuloKB = "$($offset % $size)"
                        $isBestPractice = $false
                    }
                    
                    $output = [PSCustomObject]@{
                        Server = $ComputerName
                        Name = "$($partition.Name)"
                        PartitonSizeInMB = $($partition.Size/ 1MB)
                        PartitionType = $partition.Type
                        TestingStripeSizeKB = $size
                        OffsetModuluCalculationKB = $OffsetModuloKB
                        StartingOffsetKB = $offset
                        IsOffsetBestPractice = $IsOffsetBestPractice
                        IsBestPractice = $isBestPractice
                        NumberOfBlocks = $partition.NumberOfBlocks
                        BootPartition = $partition.BootPartition
                        PartitionBlockSize = $partition.BlockSize
                        IsDynamicDisk = $IsDynamicDisk
                    }
                    $allpartitions += $output
                }
            }
            #endregion Processing results
            return $allpartitions
        }
    }
    
    PROCESS
    {
        foreach ($computer in $ComputerName)
        {
            Write-Message -Level VeryVerbose -Message "Processing: $computer"
            
            $computer = Resolve-DbaNetworkName -ComputerName $computer -Credential $credential
            $ipaddr = $computer.IpAddress
            $Computer = $computer.ComputerName
            
            if (!$Computer)
            {
                Stop-Function -Message "Couldn't resolve hostname. Skipping." -Continue
            }
            
            #region Connecting to server via Cim
            Write-Message -Level Verbose -Message "Creating CimSession on $computer over WSMan"
            
            if (!$Credential)
            {
                $cimsession = New-CimSession -ComputerName $Computer -ErrorAction Ignore
            }
            else
            {
                $cimsession = New-CimSession -ComputerName $Computer -ErrorAction Ignore -Credential $Credential
            }
            
            if ($null -eq $cimsession.id)
            {
                Write-Message -Level Verbose -Message "Creating CimSession on $computer over WSMan failed. Creating CimSession on $computer over DCom"
                
                if (!$Credential)
                {
                    $cimsession = New-CimSession -ComputerName $Computer -SessionOption $sessionoption -ErrorAction Ignore -Credential $Credential
                }
                else
                {
                    $cimsession = New-CimSession -ComputerName $Computer -SessionOption $sessionoption -ErrorAction Ignore
                }
            }
            
            if ($null -eq $cimsession.id)
            {
                Stop-Function -Message "Can't create CimSession on $computer" -Target $Computer -Continue
            }
            #endregion Connecting to server via Cim
            
            Write-Message -Level Verbose -Message "Getting Power Plan information from $Computer"
            
            
            try { $data = Get-DiskAlignment -CimSession $cimsession -NoSqlCheck $NoSqlCheck -ComputerName $Computer -ErrorAction Stop }
            catch
            {
                Stop-Function -Message "Failed to process $($Computer): $($_.Exception.Message)" -Continue -InnerErrorRecord $_ -Target $Computer
            }
            
            if ($data.Server -eq $null)
            {
                Stop-Function -Message "CIM query to $Computer failed." -Continue -Target $computer
            }
            
            if ($data.Count -gt 1)
            {
                $data.GetEnumerator()
            }
            else
            {
                $data
            }
        }
    }
}
