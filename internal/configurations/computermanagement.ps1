﻿<#
This is designed for all things that control how anything that caches acts
#>

# Sets the default timeout on bad connections
Set-DbaConfig -Name 'ComputerManagement.BadConnectionTimeout' -Value (New-TimeSpan -Minutes 15) -Default -DisableHandler -Description 'The timeout used on bad computer management connections. When a connection using a protocol fails, it will not be reattempted for this timespan.'

# Disable the management cache entire
Set-DbaConfig -Name 'ComputerManagement.Cache.Disable.All' -Value $false -Default -DisableHandler -Description 'Globally disables all caching done by the Computer Management functions'

# Disables the caching of bad credentials, which is kept in order to avoid reusing them
Set-DbaConfig -Name 'ComputerManagement.Cache.Disable.BadCredentialList' -Value $false -Default -DisableHandler -Description 'Disables the caching of bad credentials. dbatools caches bad logon credentials for wmi/cim and will not reuse them.'

# Disables reuse of CIM Sessions
Set-DbaConfig -Name 'ComputerManagement.Cache.Disable.CimPersistence' -Value $false -Default -DisableHandler -Description 'Disables the reuse of Cim Sessions. Setting this config to "true" will hurt Computer Management Performance, but may be necessary in some rare cases'

# Disables automatic caching of working credentials
Set-DbaConfig -Name 'ComputerManagement.Cache.Disable.CredentialAutoRegister' -Value $false -Default -DisableHandler -Description 'Disables the automatic registration of working credentials. dbatools will caches the last working credential when connecting using wmi/cim and will use those rather than using known bad credentials'

# Enables automatic failover of credentials. If enabled, CM will use known-to-work credentials in case of non-working credentials
Set-DbaConfig -Name 'ComputerManagement.Cache.Enable.CredentialFailover' -Value $false -Default -DisableHandler -Description 'Enables automatically failing over to known to work credentials, when specified credentials will not work.'

# Force-Overrides explicit credentials with cached-as-working credentials
Set-DbaConfig -Name 'ComputerManagement.Cache.Force.OverrideExplicitCredential' -Value $false -Default -DisableHandler -Description 'Enabling this will force the use of the last credentials known to work, rather than even trying explicit credentials.'

# Disables or enables globally which Remote Management channels can be used
Set-DbaConfig -Name 'ComputerManagement.Type.Disable.CimRM' -Value $false -Default -DisableHandler -Description 'Globally disables all connections using Cim over WinRM'
Set-DbaConfig -Name 'ComputerManagement.Type.Disable.CimDCOM' -Value $false -Default -DisableHandler -Description 'Globally disables all connections using Cim over DCOM'
Set-DbaConfig -Name 'ComputerManagement.Type.Disable.WMI' -Value $true -Default -DisableHandler -Description 'Globally disables all connections using WMI'
Set-DbaConfig -Name 'ComputerManagement.Type.Disable.PowerShellRemoting' -Value $true -Default -DisableHandler -Description 'Globally disables all connections using PowerShell Remoting'
#TODO: Implement Handler for type validation