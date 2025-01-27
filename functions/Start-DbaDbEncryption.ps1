function Start-DbaDbEncryption {
    <#
    .SYNOPSIS
        Combo command that encrypts all instances on a database and backs up all keys and certs

    .DESCRIPTION
        Combo command that encrypts all instances on a database and backs up all keys and certs

        * Ensures a database master key exists in the master database and backs it up
        * Ensures a database certificate or asymmetric key exists in the master database and backs it up
        * Creates a database master key in the target database and backs it up
        * Creates a database certificate or asymmetric key in the target database and backs it up
        * Creates a database encryption key in the target database and backs it up
        * Enables database encryption on the target database and backs it up

    .PARAMETER SqlInstance
        The target SQL Server instance or instances.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Accepts PowerShell credentials (Get-Credential).

        Windows Authentication, SQL Server Authentication, Active Directory - Password, and Active Directory - Integrated are all supported.

        For MFA support, please use Connect-DbaInstance.

    .PARAMETER Database
        The database or databases that will be encrypted

    .PARAMETER ExcludeDatabase
        The database or databases that will not be encrypted

    .PARAMETER EncryptorName
        The name of the encryptor (Certificate or Asymmetric Key) in master that will be used. Tries to find one if one is not specified.

        In order to encrypt the database encryption key with an asymmetric key, you must use an asymmetric key that resides on an extensible key management provider.

    .PARAMETER EncryptorType
        Type of Encryptor - either Asymmetric or Certificate

    .PARAMETER MasterKeySecurePassword
        A master service key will be created and backed up if one does not exist

        MasterKeySecurePassword is the secure string (password) used to create the key

        This parameter is required even if no master keys are made, as we won't know if master key creation will be required until each server is processed

    .PARAMETER BackupSecurePassword
        This command will perform backups of all maskter keys and certificates. Use this parameter to set the backup password

    .PARAMETER BackupPath
        The path (accessible by and relative to the SQL Server) where master keys and certificates are backed up

    .PARAMETER AllUserDatabases
        Run command against all user databases

        This was added to emphasize that all user databases will be encrypted

    .PARAMETER CertificateSubject
        Optional subject that will be used when creating all certificates

    .PARAMETER CertificateStartDate
        Optional start date that will be used when creating all certificates

        By default, certs will start immediately

    .PARAMETER CertificateExpirationDate
        Optional expiration that will be used when creating all certificates

        By default, certs will last 5 years

    .PARAMETER CertificateActiveForServiceBrokerDialog
        Microsoft has not provided a description so we can only assume the cert is active for service broker dialog

    .PARAMETER InputObject
        Enables piping from Get-DbaDatabase

    .PARAMETER WhatIf
        Shows what would happen if the command were to run. No actions are actually performed.

    .PARAMETER Confirm
        Prompts you for confirmation before executing any changing operations within the command.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: Certificate, Security
        Author: Chrissy LeMaire (@cl), netnerds.net

        Website: https://dbatools.io
        Copyright: (c) 2022 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .LINK
        https://dbatools.io/Start-DbaDbEncryption

    .EXAMPLE
        PS C:\> $masterkeypass = (Get-Credential justneedpassword).Password
        PS C:\> $certbackuppass = (Get-Credential justneedpassword).Password
        PS C:\> $params = @{
        >>      SqlInstance             = "sql01"
        >>      AllUserDatabases        = $true
        >>      MasterKeySecurePassword = $masterkeypass
        >>      BackupSecurePassword    = $certbackuppass
        >>      BackupPath              = "C:\temp"
        >>      EnableException         = $true
        >>  }
        PS C:\> Start-DbaDbEncryption @params

        Prompts for two passwords (the username doesn't matter, this is just an easy & secure way to get a secure password)

        Then encrypts all user databases on sql01, creating master keys and certificates as needed, and backing all of them up to C:\temp, securing them with the password set in $certbackuppass

    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
    param (
        [DbaInstanceParameter[]]$SqlInstance,
        [PSCredential]$SqlCredential,
        [string]$EncryptorName,
        [ValidateSet("AsymmetricKey", "Certificate")]
        [string]$EncryptorType = "Certificate",
        [string[]]$Database,
        [Parameter(Mandatory)]
        [string]$BackupPath,
        [Parameter(Mandatory)]
        [Security.SecureString]$MasterKeySecurePassword,
        [string]$CertificateSubject,
        [datetime]$CertificateStartDate = (Get-Date),
        [datetime]$CertificateExpirationDate = (Get-Date).AddYears(5),
        [switch]$CertificateActiveForServiceBrokerDialog,
        [Parameter(Mandatory)]
        [Security.SecureString]$BackupSecurePassword,
        [parameter(ValueFromPipeline)]
        [Microsoft.SqlServer.Management.Smo.Database[]]$InputObject,
        [switch]$AllUserDatabases,
        [switch]$EnableException
    )
    process {
        if (-not $SqlInstance -and -not $InputObject) {
            Stop-Function -Message "You must specify either SqlInstance or pipe in an InputObject from Get-DbaDatabase"
            return
        }

        if ($SqlInstance) {
            if (-not $Database -and -not $ExcludeDatabase -and -not $AllUserDatabases) {
                Stop-Function -Message "You must specify Database, ExcludeDatabase or AllUserDatabases when using SqlInstance"
                return
            }
            # all does not need to be addressed in the code because it gets all the dbs if $databases is empty
            $param = @{
                SqlInstance     = $SqlInstance
                SqlCredential   = $SqlCredential
                Database        = $Database
                ExcludeDatabase = $ExcludeDatabase
            }
            $InputObject += Get-DbaDatabase @param | Where-Object Name -NotIn 'master', 'model', 'tempdb', 'msdb', 'resource'
        }

        $PSDefaultParameterValues["Connect-DbaInstance:Verbose"] = $false
        foreach ($db in $InputObject) {
            try {
                # Just in case they use inputobject + exclude
                if ($db.Name -in $ExcludeDatabase) { continue }
                $server = $db.Parent
                # refresh in case we have a stale database
                $null = $db.Refresh()
                $null = $server.Refresh()
                $servername = $server.Name
                $dbname = $db.Name

                if ($db.EncryptionEnabled) {
                    Write-Message -Level Warning -Message "Database $($db.Name) on $($server.Name) is already encrypted"
                    continue
                }

                # before doing anything, see if the master cert is in order
                if ($EncryptorName) {
                    $mastercert = Get-DbaDbCertificate -SqlInstance $server -Database master | Where-Object Name -eq $EncryptorName
                } else {
                    $mastercert = Get-DbaDbCertificate -SqlInstance $server -Database master | Where-Object Name -NotMatch "##"
                }

                if ($EncryptorName -and -not $mastercert) {
                    Stop-Function -Message "EncryptorName specified but no matching certificate found on $($server.Name)" -Continue
                }

                if ($mastercert.Count -gt 1) {
                    Stop-Function -Message "More than one certificate found on $($server.Name), please specify an EncryptorName" -Continue
                }

                $stepCounter = 0
                Write-ProgressHelper -StepNumber ($stepCounter++) -Message "Processing $($db.Name)"
            } catch {
                Stop-Function -Message "Failure" -ErrorRecord $_ -Continue
            }

            try {
                # Ensure a database master key exists in the master database
                Write-Message -Level Verbose -Message "Ensure a database master key exists in the master database for $($server.Name)"
                Write-ProgressHelper -StepNumber ($stepCounter++) -Message "Ensure a database master key exists in the master database for $($server.Name)"
                $masterkey = Get-DbaDbMasterKey -SqlInstance $server -Database master

                if (-not $masterkey) {
                    Write-Message -Level Verbose -Message "master key not found, creating one"
                    $params = @{
                        SqlInstance     = $server
                        SecurePassword  = $MasterKeySecurePassword
                        EnableException = $true
                    }
                    $masterkey = New-DbaServiceMasterKey @params
                }

                $null = $db.Refresh()
                $null = $server.Refresh()

                $dbmasterkeytest = Get-DbaFile -SqlInstance $server -Path $BackupPath | Where-Object FileName -match "$servername-master"
                if (-not $dbmasterkeytest) {
                    # has to be repeated in the event databases are piped in
                    $params = @{
                        SqlInstance     = $server
                        Database        = "master"
                        Path            = $BackupPath
                        EnableException = $true
                        SecurePassword  = $BackupSecurePassword
                    }
                    $null = $server.Databases["master"].Refresh()
                    Write-Message -Level Verbose -Message "Backing up master key on $($server.Name)"
                    $null = Backup-DbaDbMasterKey @params
                }
            } catch {
                Stop-Function -Message "Failure" -ErrorRecord $_ -Continue
            }

            try {
                Write-ProgressHelper -StepNumber ($stepCounter++) -Message "Processing EncryptorType for $($db.Name) on $($server.Name)"
                if ($EncryptorType -eq "Certificate") {
                    if (-not $mastercert) {
                        Write-Message -Level Verbose -Message "master cert not found, creating one"
                        $params = @{
                            SqlInstance                  = $server
                            Database                     = "master"
                            StartDate                    = $CertificateStartDate
                            ExpirationDate               = $CertificateExpirationDate
                            ActiveForServiceBrokerDialog = $CertificateActiveForServiceBrokerDialog
                            EnableException              = $true
                        }
                        if ($CertificateSubject) {
                            $params.Subject = $CertificateSubject
                        }
                        $mastercert = New-DbaDbCertificate @params
                    } else {
                        Write-Message -Level Verbose -Message "master cert found on $($server.Name)"
                    }

                    $null = $db.Refresh()
                    $null = $server.Refresh()

                    $mastercerttest = Get-DbaFile -SqlInstance $server -Path $BackupPath | Where-Object FileName -match "$($mastercert.Name).cer"
                    if (-not $mastercerttest) {
                        # Back up certificate
                        $null = $server.Databases["master"].Refresh()
                        $params = @{
                            SqlInstance        = $server
                            Database           = "master"
                            Certificate        = $mastercert.Name
                            Path               = $BackupPath
                            EnableException    = $true
                            EncryptionPassword = $BackupSecurePassword
                        }
                        Write-Message -Level Verbose -Message "Backing up master certificate on $($server.Name)"
                        $null = Backup-DbaDbCertificate @params
                    }

                    if (-not $EncryptorName) {
                        Write-Message -Level Verbose -Message "Getting EncryptorName from master cert on $($server.Name)"
                        $EncryptorName = $mastercert.Name
                    }
                } else {
                    $masterasym = Get-DbaDbAsymmetricKey -SqlInstance $server -Database master

                    if (-not $masterasym) {
                        Write-Message -Level Verbose -Message "Asymmetric key not found, creating one for master on $($server.Name)"
                        $params = @{
                            SqlInstance     = $server
                            Database        = "master"
                            EnableException = $true
                        }
                        $masterasym = New-DbaDbAsymmetricKey @params
                        $null = $server.Refresh()
                        $null = $server.Databases["master"].Refresh()
                    } else {
                        Write-Message -Level Verbose -Message "master asymmetric key found on $($server.Name)"
                    }

                    if (-not $EncryptorName) {
                        Write-Message -Level Verbose -Message "Getting EncryptorName from master asymmetric key"
                        $EncryptorName = $masterasym.Name
                    }
                }
            } catch {
                Stop-Function -Message "Failure" -ErrorRecord $_ -Continue
            }

            try {
                Write-Message -Level Verbose -Message "Using EncryptorName '$EncryptorName'"
                # Create a database master key in the target database
                Write-ProgressHelper -StepNumber ($stepCounter++) -Message "Creating database master key for $($db.Name) on $($server.Name)"

                $null = $server.Databases["master"].Refresh()
                $dbmasterkey = $db | Get-DbaDbMasterKey

                if (-not $dbmasterkey) {
                    $params = @{
                        SqlInstance     = $server
                        Database        = $db.Name
                        SecurePassword  = $MasterKeySecurePassword
                        EnableException = $true
                    }

                    Write-Message -Level Verbose -Message "Creating master key in $($db.Name) on $($server.Name)"
                    $dbmasterkey = New-DbaDbMasterKey @params
                    $null = $db.Refresh()
                } else {
                    Write-Message -Level Verbose -Message "master key found in $($db.Name) on $($server.Name)"
                }

                $null = $db.Refresh()
                $null = $server.Refresh()

                $dbmasterkeytest = Get-DbaFile -SqlInstance $server -Path $BackupPath | Where-Object FileName -match "$servername-$dbname"
                if (-not $dbmasterkeytest) {
                    # Back up master key
                    $params = @{
                        SqlInstance     = $server
                        Database        = $db.Name
                        Path            = $BackupPath
                        EnableException = $true
                        SecurePassword  = $BackupSecurePassword
                    }
                    Write-Message -Level Verbose -Message "Backing up master key for $($db.Name) on $($server.Name)"
                    $null = Backup-DbaDbMasterKey @params
                }
            } catch {
                Stop-Function -Message "Failure" -ErrorRecord $_ -Continue
            }

            try {
                # Create a database certificate or asymmetric key in the target database
                Write-ProgressHelper -StepNumber ($stepCounter++) -Message "Creating a database certificate or asymmetric key in $($db.Name) on $($server.Name)"
                if ($EncryptorType -eq "Certificate") {
                    $dbcert = Get-DbaDbCertificate -SqlInstance $server -Database $db.Name

                    if (-not $dbcert) {
                        Write-Message -Level Verbose -Message "Cert not found for $($db.Name) on $($server.Name), creating one"
                        $params = @{
                            SqlInstance                  = $server
                            Database                     = $db.Name
                            StartDate                    = $CertificateStartDate
                            ExpirationDate               = $CertificateExpirationDate
                            ActiveForServiceBrokerDialog = $CertificateActiveForServiceBrokerDialog
                            EnableException              = $true
                        }

                        if ($CertificateSubject) {
                            $params.Subject = $CertificateSubject
                        }
                        $dbcert = New-DbaDbCertificate @params
                    } else {
                        Write-Message -Level Verbose -Message "Cert '$($dbcert.Name)' found in $($db.Name) on $($server.Name)"
                    }

                    # Back up certificate
                    $null = $db.Refresh()
                    $null = $server.Refresh()
                    $dbcerttest = Get-DbaFile -SqlInstance $server -Path $BackupPath | Where-Object FileName -match "$($dbcert.Name).cer"
                    if (-not $dbcerttest) {
                        $params = @{
                            SqlInstance        = $server
                            Database           = $db.Name
                            Certificate        = $dbcert.Name
                            Path               = $BackupPath
                            EnableException    = $true
                            EncryptionPassword = $BackupSecurePassword
                        }
                        Write-Message -Level Verbose -Message "Backing up certificate for $($db.Name) on $($server.Name)"
                        $null = Backup-DbaDbCertificate @params
                    }
                } else {
                    $dbasymkey = Get-DbaDbAsymmetricKey -SqlInstance $server -Database $db.Name

                    if (-not $dbasymkey) {
                        Write-Message -Level Verbose -Message "Asymmetric key not found for $($db.Name) on $($server.Name),creating one"
                        $params = @{
                            SqlInstance     = $server
                            Database        = $db.Name
                            EnableException = $true
                        }
                        $dbasymkey = New-DbaDbAsymmetricKey @params
                        $null = $db.Refresh()
                    }
                }
                $null = $db.Refresh()
            } catch {
                Stop-Function -Message "Failure" -ErrorRecord $_ -Continue
            }

            try {
                # Create a database encryption key in the target database
                # Enable database encryption on the target database
                Write-ProgressHelper -StepNumber ($stepCounter++) -Message "Creating database encryption key in $($db.Name) on $($server.Name)"
                if ($db.HasDatabaseEncryptionKey) {
                    Write-Message -Level Verbose -Message "$($db.Name) on $($db.Parent.Name) already has a database encryption key"
                } else {
                    Write-Message -Level Verbose -Message "Creating new encryption key for $($db.Name) on $($server.Name) with EncryptorName $EncryptorName"
                    $null = $db | New-DbaDbEncryptionKey -EncryptorName $EncryptorName -EnableException
                }

                Write-ProgressHelper -StepNumber ($stepCounter++) -Message "Enabling database encryption in $($db.Name) on $($server.Name)"
                Write-Message -Level Verbose -Message "Enabling encryption for $($db.Name) on $($server.Name) using $EncryptorType $EncryptorName"
                $db | Enable-DbaDbEncryption -EncryptorName $EncryptorName
            } catch {
                Stop-Function -Message "Failure" -ErrorRecord $_ -Continue
            }
        }
    }
}