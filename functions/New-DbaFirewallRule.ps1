function New-DbaFirewallRule {
    <#
    .SYNOPSIS
        Creates a new inbound firewall rule for a SQL Server instance and adds the rule to the target computer.

    .DESCRIPTION
        Creates a new inbound firewall rule for a SQL Server instance and adds the rule to the target computer.

        This is basically a wrapper around New-NetFirewallRule executed at the target computer.
        So this only works if New-NetFirewallRule works on the target computer.

        Both DisplayName and Name are set to the same value, since DisplayName is required
        but only Name uniquely defines the rule, thus avoiding duplicate rules with different settings.
        The names and the group for all rules are fixed to be able to get them back with Get-DbaFirewallRule.

        The functionality is currently limited. Help to extend the functionality is welcome.

        As long as you can read this note here, there may be breaking changes in future versions.
        So please review your scripts using this command after updating dbatools.

        The firewall rule for the instance itself will have the following configuration (parameters for New-NetFirewallRule):
            DisplayName = 'SQL Server default instance' or 'SQL Server instance <InstanceName>'
            Name        = 'SQL Server default instance' or 'SQL Server instance <InstanceName>'
            Group       = 'SQL Server'
            Enabled     = 'True'
            Direction   = 'Inbound'
            Protocol    = 'TCP'
            LocalPort   = '<Port>' (for instances with static port)
            Program     = '<Path ending with MSSQL\Binn\sqlservr.exe>' (for instances with dynamic port)

        The firewall rule for the SQL Server Browser will have the following configuration (parameters for New-NetFirewallRule):
            DisplayName = 'SQL Server Browser'
            Name        = 'SQL Server Browser'
            Group       = 'SQL Server'
            Enabled     = 'True'
            Direction   = 'Inbound'
            Protocol    = 'UPD'
            LocalPort   = '1434'

    .PARAMETER SqlInstance
        The target SQL Server instance or instances.

    .PARAMETER Credential
        Credential object used to connect to the Computer as a different user.

    .PARAMETER Type
        Creates firewall rules for the given type(s).
        Valid values are:
            Engine - for the SQL Server instance
            Browser - for the SQL Server Browser
        If this parameter is not used, the firewall rule for the SQL Server instance will be created
        and in case the instance is listening on a port other than 1433,
        also the firewall rule for the SQL Server Browser will be created if not already in place.

    .PARAMETER Configuration
        A hashtable with custom configuration parameters that are used when calling New-NetFirewallRule.
        These will override the default settings.
        Parameters Name, DisplayName and Group are not allowed here and will be silently ignored.

        https://docs.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallrule

    .PARAMETER Force
        If the rule to be created already exists, a warning is displayed.
        If this switch is enabled, the rule will be deleted and created again.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .PARAMETER WhatIf
        If this switch is enabled, no actions are performed but informational messages will be displayed that explain what would happen if the command were to run.

    .PARAMETER Confirm
        If this switch is enabled, you will be prompted for confirmation before executing any operations that change state.

    .NOTES
        Tags: Network, Connection, Firewall
        Author: Andreas Jordan (@JordanOrdix), ordix.de

        Website: https://dbatools.io
        Copyright: (c) 2021 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .LINK
        https://dbatools.io/New-DbaFirewallRule

    .EXAMPLE
        PS C:\> New-DbaFirewallRule -SqlInstance SRV1, SRV1\TEST

        Automatically configures the needed firewall rules for both the default instance and the instance named TEST on SRV1.

    .EXAMPLE
        PS C:\> New-DbaFirewallRule -SqlInstance SRV1, SRV1\TEST -Configuration @{ Profile = 'Domain' }

        Automatically configures the needed firewall rules for both the default instance and the instance named TEST on SRV1,
        but configures the firewall rule for the domain profile only.

    .EXAMPLE
        PS C:\> New-DbaFirewallRule -SqlInstance SRV1\TEST -Type Engine -Force -Confirm:$false

        Creates or recreates the firewall rule for the instance TEST on SRV1. Does not prompt for confirmation.

    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
    param (
        [parameter(Mandatory, ValueFromPipeline)]
        [DbaInstanceParameter[]]$SqlInstance,
        [PSCredential]$Credential,
        [ValidateSet('Engine', 'Browser')]
        [string[]]$Type,
        [hashtable]$Configuration,
        [switch]$Force,
        [switch]$EnableException
    )

    begin {
        if ($Configuration) {
            foreach ($notAllowedKey in 'Name', 'DisplayName', 'Group') {
                if ($notAllowedKey -in $Configuration.Keys) {
                    Write-Message -Level Verbose -Message "Key $notAllowedKey is not allowed in Configuration and will be removed."
                    $Configuration.Remove($notAllowedKey)
                }
            }
        }

        $cmdScriptBlock = {
            # This scriptblock will be processed by Invoke-Command2.
            $firewallRuleParameters = $args[0]
            $force = $args[1]

            try {
                if (-not (Get-Command -Name New-NetFirewallRule -ErrorAction SilentlyContinue)) {
                    throw 'The module NetSecurity with the command New-NetFirewallRule is missing on the target computer, so New-DbaFirewallRule is not supported.'
                }
                $successful = $true
                if ($force) {
                    $null = Remove-NetFirewallRule -Name $firewallRuleParameters.Name -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                }
                $cimInstance = New-NetFirewallRule @firewallRuleParameters -WarningVariable warn -ErrorVariable err -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if ($warn.Count -gt 0) {
                    $successful = $false
                } else {
                    # Change from an empty System.Collections.ArrayList to $null for better readability
                    $warn = $null
                }
                if ($err.Count -gt 0) {
                    $successful = $false
                } else {
                    # Change from an empty System.Collections.ArrayList to $null for better readability
                    $err = $null
                }
                [PSCustomObject]@{
                    Successful  = $successful
                    CimInstance = $cimInstance
                    Warning     = $warn
                    Error       = $err
                    Exception   = $null
                }
            } catch {
                [PSCustomObject]@{
                    Successful  = $false
                    CimInstance = $null
                    Warning     = $null
                    Error       = $null
                    Exception   = $_
                }
            }
        }
    }

    process {
        foreach ($instance in $SqlInstance) {
            $rules = @( )
            $programNeeded = $false
            $browserNeeded = $false
            if ($PSBoundParameters.Type) {
                $browserOptional = $false
            } else {
                $browserOptional = $true
            }

            # Create rule for instance
            if (-not $PSBoundParameters.Type -or 'Engine' -in $PSBoundParameters.Type) {
                # Apply the defaults
                $rule = @{
                    Type         = 'Engine'
                    InstanceName = $instance.InstanceName
                    Config       = @{
                        Group     = 'SQL Server'
                        Enabled   = 'True'
                        Direction = 'Inbound'
                        Protocol  = 'TCP'
                    }
                }

                # Test for default or named instance
                if ($instance.InstanceName -eq 'MSSQLSERVER') {
                    $rule.Config.DisplayName = 'SQL Server default instance'
                    $rule.Config.Name = 'SQL Server default instance'
                    $rule.SqlInstance = $instance.ComputerName
                } else {
                    $rule.Config.DisplayName = "SQL Server instance $($instance.InstanceName)"
                    $rule.Config.Name = "SQL Server instance $($instance.InstanceName)"
                    $rule.SqlInstance = $instance.ComputerName + '\' + $instance.InstanceName
                    $browserNeeded = $true
                }

                # Get information about IP addresses for LocalPort
                try {
                    $tcpIpAddresses = Get-DbaNetworkConfiguration -SqlInstance $instance -Credential $Credential -OutputType TcpIpAddresses -EnableException
                } catch {
                    Stop-Function -Message "Failed." -Target $instance -ErrorRecord $_ -Continue
                }

                if ($tcpIpAddresses.Count -gt 1) {
                    # I would have to test this, so I better not support this in the first version.
                    # As LocalPort is [<String[]>], $tcpIpAddresses.TcpPort will probably just work with the current implementation.
                    Stop-Function -Message "SQL Server instance $instance listens on more than one IP addresses. This is currently not supported by this command." -Continue
                }

                if ($tcpIpAddresses.TcpPort -ne '') {
                    $rule.Config.LocalPort = $tcpIpAddresses.TcpPort
                    if ($tcpIpAddresses.TcpPort -ne '1433') {
                        $browserNeeded = $true
                    }
                } else {
                    $programNeeded = $true
                }

                if ($programNeeded) {
                    # Get information about service for Program
                    try {
                        $service = Get-DbaService -ComputerName $instance.ComputerName -InstanceName $instance.InstanceName -Credential $Credential -Type Engine -EnableException
                    } catch {
                        Stop-Function -Message "Failed." -Target $instance -ErrorRecord $_ -Continue
                    }
                    $rule.Config.Program = $service.BinaryPath -replace '^"?(.*sqlservr.exe).*$', '$1'
                }

                $rules += $rule
            }

            # Create rule for Browser
            if ((-not $PSBoundParameters.Type -and $browserNeeded) -or 'Browser' -in $PSBoundParameters.Type) {
                # Apply the defaults
                $rule = @{
                    Type         = 'Browser'
                    InstanceName = $null
                    SqlInstance  = $null
                    Config       = @{
                        DisplayName = 'SQL Server Browser'
                        Name        = 'SQL Server Browser'
                        Group       = 'SQL Server'
                        Enabled     = 'True'
                        Direction   = 'Inbound'
                        Protocol    = 'UDP'
                        LocalPort   = '1434'
                    }
                }

                $rules += $rule
            }

            foreach ($rule in $rules) {
                # Apply the given configuration
                if ($Configuration) {
                    foreach ($param in $Configuration.Keys) {
                        $rule.Config.$param = $Configuration.$param
                    }
                }

                # Run the command for the instance
                if ($PSCmdlet.ShouldProcess($instance, "Creating firewall rule for instance $($instance.InstanceName) on $($instance.ComputerName)")) {
                    try {
                        $commandResult = Invoke-Command2 -ComputerName $instance.ComputerName -Credential $Credential -ScriptBlock $cmdScriptBlock -ArgumentList $rule.Config, $Force
                    } catch {
                        Stop-Function -Message "Failed to execute command on $($instance.ComputerName) for instance $($instance.InstanceName)." -Target $instance -ErrorRecord $_ -Continue
                    }

                    if ($commandResult.Error.Count -eq 1 -and $commandResult.Error[0] -match 'Cannot create a file when that file already exists') {
                        $status = 'The desired rule already exists. Use -Force to remove and recreate the rule.'
                        $commandResult.Error = $null
                        if ($rule.Type -eq 'Browser' -and $browserOptional) {
                            $commandResult.Successful = $true
                        }
                    } elseif ($commandResult.CimInstance.Status -match 'The rule was parsed successfully from the store') {
                        $status = 'The rule was successfully created.'
                    } else {
                        $status = $commandResult.CimInstance.Status
                    }

                    if ($commandResult.Warning) {
                        Write-Message -Level Verbose -Message "commandResult.Warning: $($commandResult.Warning)."
                        $status += " Warning: $($commandResult.Warning)."
                    }
                    if ($commandResult.Error) {
                        Write-Message -Level Verbose -Message "commandResult.Error: $($commandResult.Error)."
                        $status += " Error: $($commandResult.Error)."
                    }
                    if ($commandResult.Exception) {
                        Write-Message -Level Verbose -Message "commandResult.Exception: $($commandResult.Exception)."
                        $status += " Exception: $($commandResult.Exception)."
                    }

                    # Output information
                    [PSCustomObject]@{
                        ComputerName = $instance.ComputerName
                        InstanceName = $rule.InstanceName
                        SqlInstance  = $rule.SqlInstance
                        DisplayName  = $rule.Config.DisplayName
                        Name         = $rule.Config.Name
                        Type         = $rule.Type
                        Protocol     = $rule.Config.Protocol
                        LocalPort    = $rule.Config.LocalPort
                        Program      = $rule.Config.Program
                        RuleConfig   = $rule.Config
                        Successful   = $commandResult.Successful
                        Status       = $status
                        Details      = $commandResult
                    } | Select-DefaultView -Property ComputerName, InstanceName, SqlInstance, DisplayName, Type, Successful, Status, Protocol, LocalPort, Program
                }
            }
        }
    }
}