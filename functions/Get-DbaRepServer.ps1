function Get-DbaRepServer {
    <#
    .SYNOPSIS
        Gets a replication server object

    .DESCRIPTION
        Gets a replication server object

        All replication commands need SQL Server Management Studio installed and are therefore currently not supported.
        Have a look at this issue to get more information: https://github.com/dataplat/dbatools/issues/7428

    .PARAMETER SqlInstance
        The target SQL Server instance or instances

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Accepts PowerShell credentials (Get-Credential).

        Windows Authentication, SQL Server Authentication, Active Directory - Password, and Active Directory - Integrated are all supported.

        For MFA support, please use Connect-DbaInstance.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: Replication
        Author: Chrissy LeMaire (@cl), netnerds.net

        Website: https://dbatools.io
        Copyright: (c) 2018 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .LINK
        https://dbatools.io/Get-DbaRepServer

    .EXAMPLE
        PS C:\> Get-DbaRepServer -SqlInstance sql2016

        Gets the replication server object for sql2016 using Windows authentication

    .EXAMPLE
        PS C:\> Get-DbaRepServer -SqlInstance sql2016 -SqlCredential repadmin

        Gets the replication server object for sql2016 using SQL authentication

    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [DbaInstanceParameter[]]$SqlInstance,
        [PSCredential]$SqlCredential,
        [switch]$EnableException
    )
    begin {
        if ($PSVersionTable.PSEdition -eq "Core") {
            Stop-Function -Message "This command is not yet supported in PowerShell Core"
            return
        }
        try {
            Add-Type -Path "$script:PSModuleRoot\bin\smo\Microsoft.SqlServer.Replication.dll" -ErrorAction Stop
            Add-Type -Path "$script:PSModuleRoot\bin\smo\Microsoft.SqlServer.Rmo.dll" -ErrorAction Stop
        } catch {
            $repdll = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Replication")
            $rmodll = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Rmo")

            if ($null -eq $repdll -or $null -eq $rmodll) {
                Write-Message -Level Warning -Message 'All replication commands need SQL Server Management Studio installed and are therefore currently not supported.'
                Stop-Function -Message "Could not load replication libraries"
                return
            }
        }
    }
    process {
        if (Test-FunctionInterrupt) { return }
        foreach ($instance in $SqlInstance) {
            try {
                # use System.Data instead of Microsoft.Data
                $sqlconn = New-SqlConnection -SqlInstance $instance -SqlCredential $SqlCredential
                New-Object Microsoft.SqlServer.Replication.ReplicationServer $sqlconn
            } catch {
                Stop-Function -Message "Error occurred while establishing connection to $instance" -Category ConnectionError -ErrorRecord $_ -Target $instance -Continue
            }
        }
    }
}