<#
.Synopsis
    Use this script to install a SharePoint Hosted App
.Description
    It will install a SharePoint Provider Hosted App which was build using Visual Studio, the folder structure could look like this:
        Solutions2Share.MeetingManager.Solutions2Share.MeetingManager.app
        Solutions2Share.Solutions.MeetingManagerWeb.deploy-readme.txt
        Solutions2Share.Solutions.MeetingManagerWeb.deploy.cmd
        Solutions2Share.Solutions.MeetingManagerWeb.SetParameters.xml
        Solutions2Share.Solutions.MeetingManagerWeb.SourceManifest.xml
        Solutions2Share.Solutions.MeetingManagerWeb.zip
        Install-ProviderHostedApp-Config.xml
        Install-ProviderHostedApp.ps1
        ProviderHostedApp.pfx
        WebDeploy_2_10_amd64_en-US.msi
.Example
    .\Install-ProviderHostedApp.ps1 -InputFile "D:\ProviderHostedAppInstaller\Install-ProviderHostedApp-Config.xml"
.Parameter InputFile
    Defines the XML Configuration file which includes environment specific details such as SQL, Service Account. Please use the example provided with this script.
#>
[cmdletbinding()]
param
(
    [string]$InputFile = $(throw '- Need parameter input file (e.g. "C:\Install\MeetingManager.xml")')
)

Write-Host 'Read XML'
[xml]$Setup = (Get-Content $InputFile -ErrorAction Inquire)

# Installer for App
# Please specify your variables or App Name here
$appName = 'Meeting Manager'
$appInternalName = 'MeetingManager' #No spaces nor special characters, used for certificates
$AppFilename = 'Solutions2Share Meeting Manager'
$Solutions2Share = $true #Solutions2Share Meeting Manager specifics

# Will be populated automatically

#Variables
$SQLServer = $Setup.ProviderHostedApp.database.DBServer
$SQLPort = $Setup.ProviderHostedApp.database.DBServerPort
$DBPrefix = $Setup.ProviderHostedApp.database.DBPrefix

[string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]
$Serviceaccount = $Setup.ProviderHostedApp.general.ServiceAccount
$oAuth = $Setup.ProviderHostedApp.general.AllowOAuthoverHTTP

$FQDN = $Setup.ProviderHostedApp.general.FQDN
$PhysicalBasePath = $Setup.ProviderHostedApp.general.InstallationDirectory
$SPWeb = $Setup.ProviderHostedApp.sharepoint.SPSite
#Use ClientID or generate new one
If ($Setup.sharepoint.ClientID) {$clientID = $Setup.sharepoint.ClientID} else { $clientID = ([guid]::NewGuid()).guid }

#Hashtable
$DBs = @{}
#Get Databases from XML
foreach ($Database in $Setup.ProviderHostedApp.Database.Databasename)
{
    $DBs.$($Database.Type) = $Database.Name
}

Write-Host "`nDone" -ForegroundColor Green
Write-Host 'Import IIS Module'
Import-Module WebAdministration -ErrorAction Stop
Write-Verbose 'Load AssemblyName System.IO.Compression.FileSystem'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# SQL
# ====================================================================================
# Func: Add-SQLAlias
# Desc: Creates a local SQL alias (like using cliconfg.exe) so the real SQL server/name doesn't get hard-coded in SharePoint
#       if local database server is being used, then use Shared Memory protocol
# From: Bill Brockbank, SharePoint MVP (billb@navantis.com)
# Adapted for use in ProviderHostedAppInstaller by @Hobmaier
# ====================================================================================

Function Add-SQLAlias()
{
    <#
    .Synopsis
        Add a new SQL server Alias
    .Description
        Adds a new SQL server Alias with the provided parameters.
    .Example
                Add-SQLAlias -AliasName "MeetingManagerDB" -SQLInstance $env:COMPUTERNAME
    .Example
                Add-SQLAlias -AliasName "MeetingManagerDB" -SQLInstance $env:COMPUTERNAME -Port '1433'
    .Parameter AliasName
        The new alias Name.
    .Parameter SQLInstance
                The SQL server Name os Instance Name
    .Parameter Port
        Port number of SQL server instance. This is an optional parameter.
    #>
    [CmdletBinding(DefaultParameterSetName="BuildPath+SetupInfo")]
    param
    (
        [Parameter(Mandatory=$false, ParameterSetName="BuildPath+SetupInfo")][ValidateNotNullOrEmpty()]
        [String]$aliasName = "MeetingManagerDB",

        [Parameter(Mandatory=$false, ParameterSetName="BuildPath+SetupInfo")][ValidateNotNullOrEmpty()]
        [String]$SQLInstance = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false, ParameterSetName="BuildPath+SetupInfo")][ValidateNotNullOrEmpty()]
        [String]$port = ""
    )

    If ((MatchComputerName $SQLInstance $env:COMPUTERNAME) -or ($SQLInstance.StartsWith($env:ComputerName +"\"))) {
        $protocol = "dbmslpcn" # Shared Memory
        }
    else {
        $protocol = "DBMSSOCN" # TCP/IP
    }

    $serverAliasConnection="$protocol,$SQLInstance"
    If ($port -ne "")
    {
         $serverAliasConnection += ",$port"
    }
    $notExist = $true
    $client = Get-Item 'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client' -ErrorAction SilentlyContinue
    # Create the key in case it doesn't yet exist
    If (!$client) {$client = New-Item 'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client' -Force}
    $client.GetSubKeyNames() | ForEach-Object -Process { If ( $_ -eq 'ConnectTo') { $notExist=$false }}
    If ($notExist)
    {
        $data = New-Item 'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo'
    }
    # Add Alias
    $data = New-ItemProperty HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo -Name $aliasName -Value $serverAliasConnection -PropertyType "String" -Force -ErrorAction SilentlyContinue
}

# ====================================================================================
# Func: CheckSQLAccess
# Desc: Checks if the install account has the correct SQL database access and permissions
# By:   Sameer Dhoot (http://sharemypoint.in/about/sameerdhoot/)
# From: http://sharemypoint.in/2011/04/18/powershell-script-to-check-sql-server-connectivity-version-custering-status-user-permissions/
# Adapted for use in ProviderHostedAppInstaller by @Hobmaier
# ====================================================================================
Function CheckSQLAccess
{
    # Look for references to DB Servers, Aliases, etc. in the XML
    ForEach ($node in $Setup.SelectNodes("//*[DBServer]"))
    {
        $dbServer = (GetFromNode $node "DBServer")
        # If the DBServer has been specified, and we've asked to set up an alias, create one
        If (!([string]::IsNullOrEmpty($dbServer)) -and ($node.DBAlias.Create -eq $true))
        {
            $dbInstance = GetFromNode $node.DBAlias "DBInstance"
            $dbPort = GetFromNode $node.DBAlias "DBPort"
            # If no DBInstance has been specified, but Create="$true", set the Alias to the server value
            If (($dbInstance -eq $null) -and ($dbInstance -ne "")) {$dbInstance = $dbServer}
            If (($dbPort -ne $null) -and ($dbPort -ne ""))
            {
                Write-Host -ForegroundColor White " - Creating SQL alias `"$dbServer,$dbPort`"..."
                Add-SQLAlias -AliasName $dbServer -SQLInstance $dbInstance -Port $dbPort
            }
            Else # Create the alias without specifying the port (use default)
            {
                Write-Host -ForegroundColor White " - Creating SQL alias `"$dbServer`"..."
                Add-SQLAlias -AliasName $dbServer -SQLInstance $dbInstance
            }
        }
        $dbServers += @($dbServer)
    }

    $currentUser = "$env:USERDOMAIN\$env:USERNAME"
    $serverRolesToCheck = "dbcreator","securityadmin"

    ForEach ($sqlServer in ($dbServers | Select-Object -Unique))
    {
        If ($sqlServer) # Only check the SQL instance if it has a value
        {
            $objSQLConnection = New-Object System.Data.SqlClient.SqlConnection
            $objSQLCommand = New-Object System.Data.SqlClient.SqlCommand
            Try
            {
                $objSQLConnection.ConnectionString = "Server=$sqlServer,$($SQLPort);Integrated Security=SSPI;"
                Write-Host -ForegroundColor White " - Testing access to SQL server/instance/alias:Port $($sqlServer):$($SQLPort)"
                Write-Host -ForegroundColor White " - Trying to connect to `"$sqlServer`"..." -NoNewline
                $objSQLConnection.Open() | Out-Null
                Write-Host -ForegroundColor Black -BackgroundColor Green "Success"
                $strCmdSvrDetails = "SELECT SERVERPROPERTY('productversion') as Version"
                $strCmdSvrDetails += ",SERVERPROPERTY('IsClustered') as Clustering"
                $objSQLCommand.CommandText = $strCmdSvrDetails
                $objSQLCommand.Connection = $objSQLConnection
                $objSQLDataReader = $objSQLCommand.ExecuteReader()
                If ($objSQLDataReader.Read())
                {
                    Write-Host -ForegroundColor White (" - SQL Server version is: {0}" -f $objSQLDataReader.GetValue(0))
                    $SQLVersion = $objSQLDataReader.GetValue(0)
                    [int]$SQLMajorVersion,[int]$SQLMinorVersion,[int]$SQLBuild,$null = $SQLVersion -split "\."
                    # SharePoint needs minimum SQL 2008 10.0.2714.0 or SQL 2005 9.0.4220.0 per http://support.microsoft.com/kb/976215
                    If ((($SQLMajorVersion -eq 10) -and ($SQLMinorVersion -lt 5) -and ($SQLBuild -lt 2714)) -or (($SQLMajorVersion -eq 9) -and ($SQLBuild -lt 4220)))
                    {
                        Throw " - Unsupported SQL version!"
                    }
                    If ($objSQLDataReader.GetValue(1) -eq 1)
                    {
                        Write-Host -ForegroundColor White " - This instance of SQL Server is clustered"
                    }
                    Else
                    {
                        Write-Host -ForegroundColor White " - This instance of SQL Server is not clustered"
                    }
                }
                $objSQLDataReader.Close()
                ForEach($serverRole in $serverRolesToCheck)
                {
                    $objSQLCommand.CommandText = "SELECT IS_SRVROLEMEMBER('$serverRole')"
                    $objSQLCommand.Connection = $objSQLConnection
                    Write-Host -ForegroundColor White " - Check if $currentUser has $serverRole server role..." -NoNewline
                    $objSQLDataReader = $objSQLCommand.ExecuteReader()
                    If ($objSQLDataReader.Read() -and $objSQLDataReader.GetValue(0) -eq 1)
                    {
                        Write-Host -ForegroundColor Black -BackgroundColor Green "Pass"
                    }
                    ElseIf($objSQLDataReader.GetValue(0) -eq 0)
                    {
                        Throw " - $currentUser does not have `'$serverRole`' role!"
                    }
                    Else
                    {
                        Write-Host -ForegroundColor Red "Invalid Role"
                    }
                    $objSQLDataReader.Close()
                }
                $objSQLConnection.Close()
            }
            Catch
            {
                Write-Host -ForegroundColor Red " - Fail"
                $errText = $error[0].ToString()
                If ($errText.Contains("network-related"))
                {
                    Write-Warning "Connection Error. Check server name, port, firewall."
                    Throw "SQL Connectivity Error"
                }
                ElseIf ($errText.Contains("Login failed"))
                {
                    Throw " - Not able to login. SQL Server login not created."
                }
                ElseIf ($errText.Contains("Unsupported SQL version"))
                {
                    Throw " - SharePoint 2010 requires SQL 2005 SP3+CU3, SQL 2008 SP1+CU2, or SQL 2008 R2."
                }
                Else
                {
                    If (!([string]::IsNullOrEmpty($serverRole)))
                    {
                        Throw " - $currentUser does not have `'$serverRole`' role!"
                    }
                    Else {Throw " - $errText"}
                }
            }
        }
    }
}

#Create Database
Function CreateDatabase
{
    param(
        [string]$Databasename,
        [string]$Databaseowner
    )
    
    $objSQLConnection = New-Object System.Data.SqlClient.SqlConnection
    $objSQLCommand = New-Object System.Data.SqlClient.SqlCommand
    $objSQLCommand.CommandTimeout = 900
    $objSQLConnection.ConnectionString = "Server=$SQLServer,$($SQLPort);Integrated Security=SSPI;"
    Write-Debug -Message 'Now Connect to SQL'
    $objSQLConnection.Open() | Out-Null
    $strSQLcmd = "create Database [$Databasename]"
    $strSQLcmd2 = @"
USE [$Databasename]
EXEC dbo.sp_changedbowner @loginame = N'$Databaseowner', @map = false
"@
    $objSQLCommand.CommandText = $strSQLcmd
    $objSQLCommand.Connection = $objSQLConnection
    $objSQLCommand.ExecuteNonQuery()
    $objSQLCommand.CommandText = $strSQLcmd2
    $objSQLCommand.Connection = $objSQLConnection
    $objSQLCommand.ExecuteNonQuery()

    $objSQLConnection.Close()

}

Function CreateSQLLogin
{
    param(
    )
    
    $objSQLConnection = New-Object System.Data.SqlClient.SqlConnection
    $objSQLCommand = New-Object System.Data.SqlClient.SqlCommand
    $objSQLCommand.CommandTimeout = 900
    $objSQLConnection.ConnectionString = "Server=$SQLServer,$($SQLPort);Integrated Security=SSPI;"
    Write-Debug -Message 'Now Connect to SQL'
    $objSQLConnection.Open() | Out-Null
    $strSQLcmd = "CREATE LOGIN [$Serviceaccount] FROM WINDOWS WITH DEFAULT_DATABASE=[master]"
    $objSQLCommand.CommandText = $strSQLcmd
    $objSQLCommand.Connection = $objSQLConnection
    $objSQLCommand.ExecuteNonQuery()

    $objSQLConnection.Close()
}

function New-AppHighTrust
{
    param(
        [Parameter(Mandatory)][String] $CertPath = $(throw "Usage: HighTrustConfig-ForSingleApp.ps1 -CertPath <full path to .cer file> -CertName <name of certificate> [-SPAppClientID <client ID of SharePoint add-in>] [-TokenIssuerFriendlyName <friendly name>]"),
        [Parameter(Mandatory)][String] $CertName,
        [Parameter(Mandatory)][String] $SPAppClientID,
        [Parameter()][String] $TokenIssuerFriendlyName
    ) 
    # Stop if there's an error
    $ErrorActionPreference = "Stop"

    # Ensure friendly name is short enough
    if ($TokenIssuerFriendlyName.Length -gt 50)
    {
        throw "-TokenIssuerFriendlyName must be unique name of no more than 50 characters."
    } 

    # Get the certificate
    $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)

    # Make the certificate a trusted root authority in SharePoint
    New-SPTrustedRootAuthority -Name $CertName -Certificate $certificate 

    # Get the GUID of the authentication realm
    $realm = Get-SPAuthenticationRealm

    # Must use the client ID as the specific issuer ID. Must be lower-case!
    $specificIssuerId = New-Object System.String($SPAppClientID).ToLower()

    # Create full issuer ID in the required format
    $fullIssuerIdentifier = $specificIssuerId + '@' + $realm 

    # Create issuer name
    if ($TokenIssuerFriendlyName.Length -ne 0)
    {
        $tokenIssuerName = $TokenIssuerFriendlyName
    }
    else
    {
        $tokenIssuerName = $specificIssuerId 
    }


    # Register the token issuer
    New-SPTrustedSecurityTokenIssuer -Name $tokenIssuerName -Certificate $certificate -RegisteredIssuerName $fullIssuerIdentifier
}

function AllowOAuthoverHTTP
{
    $serviceConfig = Get-SPSecurityTokenServiceConfig
    $serviceConfig.AllowOAuthOverHttp = $true
    $serviceConfig.Update()
}

function Unzip
{
    param([string]$zipfile, [string]$outpath)

    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipfile, $outpath)
}

function Get-AppCatalog
{
    param(
        $WebAppUrl
    )
    
    $wa = Get-SPWebApplication $WebAppUrl
    $feature = $wa.Features[[Guid]::Parse("f8bea737-255e-4758-ab82-e34bb46f5828")]
    $site = Get-SPSite $feature.Properties["__AppCatSiteId"].Value
    
    return $site.Url
}

#region Validate Credentials
Function ValidateCredentials($Credentials)
{
    Write-Host -ForegroundColor White " - Validating user accounts and passwords..."
    If ($env:COMPUTERNAME -eq $env:USERDOMAIN)
    {
        Throw " - You are running this script under a local machine user account. You must be a domain user"
    }

    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($credentials.Password)
    $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)


    If (($PlainPassword -ne "") -and ($Credentials.username -ne ""))
    {
        $currentDomain = "LDAP://" + ([ADSI]"").distinguishedName
        Write-Host -ForegroundColor White " - Account "$Credentials.username" ..." -NoNewline
        $dom = New-Object System.DirectoryServices.DirectoryEntry($currentDomain,$Credentials.username,$PlainPassword)
        If ($dom.Path -eq $null)
        {
            Write-Host -BackgroundColor Red -ForegroundColor Black "Invalid!"
            $acctInvalid = $true
        }
        Else
        {
            Write-Host -ForegroundColor Black -BackgroundColor Green "Verified."
        }
    }
    $PlainPassword = $null
    If ($acctInvalid) {Throw " - At least one set of credentials is invalid.`n - Check usernames and password."}
}
#endregion

function UploadSPFile
{
    param (
        $SiteUrl,
        $LibraryName,
        $SourceFile
    )

    #Load SharePoint CSOM Assemblies
    [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SharePoint.Client") | Out-Null
    [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SharePoint.Client.Runtime") | Out-Null
     
    #Setup Credentials to connect
    $Credentials = [System.Net.CredentialCache]::DefaultCredentials  #Current User Credentials
    #connect using user account/password
    #$Credentials = New-Object System.Net.NetworkCredential($UserName, (ConvertTo-SecureString $Password -AsPlainText -Force))
    #For Office 365, Use:
    #$Credentials = New-Object Microsoft.SharePoint.Client.SharePointOnlineCredentials($UserName,(ConvertTo-SecureString $Password -AsPlainText -Force))
     
    #Set up the context
    $Context = New-Object Microsoft.SharePoint.Client.ClientContext($SiteUrl) 
    $Context.Credentials = $credentials
    $web = $Context.Web
     
    #Get the Library
    $List = $web.Lists.GetByTitle($LibraryName)
    $Context.Load($List)
    $Context.ExecuteQuery()
         
    #Get File Name from source file path
    $SourceFileName = Split-path $SourceFile -leaf
     
    #Get Source file contents
    $FileStream = ([System.IO.FileInfo] (Get-Item $SourceFile)).OpenRead()
     
    #Upload to SharePoint
    $FileCreationInfo = New-Object Microsoft.SharePoint.Client.FileCreationInformation
    $FileCreationInfo.Overwrite = $true
    $FileCreationInfo.ContentStream = $FileStream
    $FileCreationInfo.URL = $SourceFileName
    $FileUploaded = $List.RootFolder.Files.Add($FileCreationInfo)
    $Context.Load($FileUploaded)
    $Context.ExecuteQuery()
     
    #Set Metadata
    $properties = $FileUploaded.ListItemAllFields;
    $context.Load($properties)
    #$properties["Category"]="Reports"
    $properties.Update() 
    $context.ExecuteQuery()
      
    #Close file stream
    $FileStream.Close()
}

Function GetFromNode([System.Xml.XmlElement]$node, [string] $item)
{
    $value = $node.GetAttribute($item)
    If ($value -eq "")
    {
        $child = $node.SelectSingleNode($item);
        If ($child -ne $null)
        {
            Return $child.InnerText;
        }
    }
    Return $value;
}

#by @alexeymiasoedov http://purple-screen.com/?p=440
#Works with .app files but only when adding to existing ZIP file
function New-ZipFile {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory,ValueFromPipeline)]
        [string[]] $InputObject,
        [Parameter(Mandatory)]
        [string] $ZipFilePath,
        [ValidateSet('Optimal','Fastest','NoCompression')]
        [System.IO.Compression.CompressionLevel] $Compression = 'Optimal',
        [switch] $Append,
        [switch] $Force
    )
    Begin {
        if (-not (Split-Path $ZipFilePath)) { $ZipFilePath = Join-Path $Pwd $ZipFilePath }
        if (Test-Path $ZipFilePath) {
            if ($Append.IsPresent) {
                Write-Verbose 'Appending to the destination file'
                $Archive = [System.IO.Compression.ZipFile]::Open($ZipFilePath,'Update')
            } elseif ($Force.IsPresent) {
                Write-Verbose 'Removing the destination file'
                Remove-Item $ZipFilePath
                $Archive = [System.IO.Compression.ZipFile]::Open($ZipFilePath,'Create')
            } else {
                Write-Error 'Output file already exists. Specify -Force option to replace it or -Append to add/replace files in existing archive'
                break
            }
        } else {
            $Archive = [System.IO.Compression.ZipFile]::Open($ZipFilePath,'Create')
        }
    }
    Process {
        foreach ($Obj in $InputObject) {
            try {
                switch ((Get-Item $Obj -ea Stop).GetType().Name) {
                    FileInfo {
                        $EntryName = Split-Path $Obj -Leaf
                        $Entry = $Archive.Entries | ? FullName -eq $EntryName
                        if ($Entry) {
                            if ($Force.IsPresent) {
                                Write-Verbose "Removing $EntryName from the archive"
                                $Entry.Delete()
                            } else {
                                throw "File $EntryName already exists in the archive"
                            }
                        }
                        $Verbose = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive,$Obj,$EntryName,$Compression)
                        Write-Verbose $Verbose
                    }
                    DirectoryInfo {
                        Push-Location $Obj
                        (Get-ChildItem . -Recurse -File).FullName | % {
                            $EntryName = (Join-Path (Split-Path $Obj -Leaf) (Resolve-Path $_ -Relative).TrimStart('.\')) -replace '\\','/'
                            $Entry = $Archive.Entries | ? FullName -eq $EntryName 
                            if ($Entry) {
                                if ($Force.IsPresent) {
                                    Write-Verbose "Removing $EntryName from the archive"
                                    $Entry.Delete()
                                } else {
                                    throw "File $EntryName already exists in the archive"
                                }
                            }
                            $Verbose = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive,$_,$EntryName,$Compression)
                            Write-Verbose $Verbose
                        }
                        Pop-Location
                    }
                }
            } catch {
                Write-Error $_
                $Archive.Dispose()
                Pop-Location
                if ($_.CategoryInfo.TargetType -ne [string] -and -not $Append.IsPresent) {
                    Remove-Item $ZipFilePath
                }
                return
            }
        }
    }
    End {
        $Archive.Dispose()
        Get-Item $ZipFilePath
    }
}

# FUNCTIONS END

Write-Output 'Check SQL connectivity and permissions'
CheckSQLAccess

# Get Credentials for use later (IIS App Pool, Database) and check if user / pwd is correct
while ($cred -eq $null) {
    Write-Host 'Please provide credentials for Application Pool Account'
    $cred = Get-Credential -UserName $Serviceaccount -Message 'Application Pool Account'
    ValidateCredentials $cred
}

#Create Database(s) and assign the owner to service account
#According to DatabaseTypes
try {
    If ($DBs.Count -gt 0)
    {
        Write-Host 'Create SQL Login for Service Account'
        CreateSQLLogin
    }    
}
catch {
    $ErrorText = $error[0].ToString()
    If ($ErrorText.Contains("The server principal `'$Serviceaccount`' already exists."))
    {
        Write-Host 'SQL Login already exist for ' $Serviceaccount
        $err.clear
        $ErrorText = $null
    } else {
        Throw $ErrorText
    }
}

try {
    Write-Host 'Create SQL Databases'
    If ($DBs.General) { CreateDatabase -Databasename ($DBPrefix + $DBs.General) -Databaseowner $Serviceaccount }
    If ($DBs.MM) { CreateDatabase -Databasename ($DBPrefix + $DBs.MM) -Databaseowner $Serviceaccount }
    If ($DBs.MMHF) { CreateDatabase -Databasename ($DBPrefix + $DBs.MMHF) -Databaseowner $Serviceaccount }
    If ($DBs.IM) { CreateDatabase -Databasename ($DBPrefix + $DBs.IM) -Databaseowner $Serviceaccount }
    If ($DBs.IMHF) { CreateDatabase -Databasename ($DBPrefix + $DBs.IMHF) -Databaseowner $Serviceaccount }
}
catch {
    Write-Host = $error[0].ToString()
    Throw 'Error creating databases'
}

#Application Pool including Settings
try {
    #If State can't be retrieved, it throws an error so we will create one in catch block
    Get-webapppoolstate -name 'Meeting Manager Pool'
}
catch {
    $AppPool = New-WebAppPool -Name 'Meeting Manager Pool' -force -ErrorAction stop
    $appPool.processModel.userName = $cred.UserName
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
    $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR) 
    $appPool.processModel.password = $PlainPassword
    $PlainPassword = $null
    $appPool.processModel.identityType = "SpecificUser"
    $AppPool.processModel.loadUserProfile = $true
    $AppPool.startMode = 'AlwaysRunning'
    $appPool | Set-Item
    $err.clear    
}

If (!(Test-Path (Join-Path -path $PhysicalBasePath -childpath 'WebRoot'))) { mkdir (Join-Path -path $PhysicalBasePath -childpath 'WebRoot') }
If ($Solutions2Share -and !((Test-Path (Join-Path -path $PhysicalBasePath -childpath 'WebRoot'))))
{
    mkdir (Join-Path -path $PhysicalBasePath -childpath 'Web')
    mkdir (Join-Path -path $PhysicalBasePath -childpath 'InvitationManager')
    mkdir (Join-Path -path $PhysicalBasePath -childpath 'Outlook')
    mkdir (Join-path -path $PhysicalBasePath -ChildPath 'Log')
}
try {
    Write-Host 'Create IIS Website'
    #New IIS Website
    $Website = New-Website -Name $appName -Port 443 -Ssl -SslFlags 1 -PhysicalPath (Join-Path -path $PhysicalBasePath -childpath 'WebRoot') -HostHeader $FQDN -ApplicationPool $AppPool.name -Force -ErrorAction Stop

    If ($Solutions2Share)
    {
        #Subweb MM
        $WebAppMM = New-WebApplication -Name "Web" -Site $Website.name -PhysicalPath (Join-Path -path $PhysicalBasePath -childpath 'Web') -ApplicationPool $AppPool.name -Force -ErrorAction Stop

        #Subweb IM
        $WebAppIM = New-WebApplication -Name "InvitationManager" -Site $Website.name -PhysicalPath (Join-Path -path $PhysicalBasePath -childpath 'InvitationManager') -ApplicationPool $AppPool.name -Force -ErrorAction Stop

        #Subweb Outlook
        $WebAppOutlook = New-WebApplication -Name "Outlook" -Site $Website.name -PhysicalPath (Join-Path -path $PhysicalBasePath -childpath 'Outlook') -ApplicationPool $AppPool.name -Force
    }
    If($err) {Write-Host '.'; Throw}
}
catch {
    Write-Host 'Error occured creating IIS Website, AppPool, Binding...'
    break
}


# ======
# Run on SharePoint

#AppRegNew
Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction Stop
$SPAppWebweb = Get-SPWeb -identity $spweb
$realm = Get-SPAuthenticationRealm -ServiceContext $SPAppWebweb.Site.Url
$appIdentifier = $clientID  + '@' + $realm
Write-Verbose "SPAppWebweb $SPAppWebweb"
Write-Verbose "appIdentifier $appIdentifier"
Set-Content -path $PhysicalBasePath\appIdentifier.txt -Value $appIdentifier
Register-SPAppPrincipal -DisplayName $appName -NameIdentifier $appIdentifier -Site $SPAppWebweb.Site.Url -ErrorAction Stop

#Server-to-Server (S2S) Trust
#If creating the Certificate just through New-SelfSignedCertificate directly, it won't work. Therefore I've created
#a Self-Signed Certificate in IIS Manager UI, exported it and clone it now, hope it works.
#$certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2((Join-Path -Path $PSScriptRoot -ChildPath 'ProviderHostedApp.pfx'),"Solutions2Share")
#$SelfSignedCert = New-SelfSignedCertificate -CloneCert $certificate -DnsName $appInternalName -CertStoreLocation Cert:\LocalMachine\My -ErrorAction Stop

Write-Output 'Create Self-Signed Certificate'

# Different Way
# Source: https://gallery.technet.microsoft.com/scriptcenter/Self-signed-certificate-5920a7c6
# From: 9/11/2016 
. "$PSScriptRoot\New-SelfSignedCertificateEx.ps1"
$SelfSignedCert = New-SelfsignedCertificateEx -Subject "CN=$($appInternalName)" `
-EnhancedKeyUsage "Server Authentication" `
-KeyUsage "KeyEncipherment,DataEncipherment" `
-StoreLocation "LocalMachine" `
-Exportable `
-SignatureAlgorithm SHA1 `
-NotAfter $([datetime]::now.AddYears(5))`
-FriendlyName "$($appInternalName)"

#Export to prepare S2S Trust
# Wait, sometimes it's not ready immediately
Start-Sleep -Seconds 2
Export-Certificate -Cert Cert:\LocalMachine\my\$($SelfSignedCert.Thumbprint) -FilePath (Join-Path -Path $PhysicalBasePath -ChildPath 'Installer.cer') -ErrorAction Stop | Out-Null
Start-Sleep -Milliseconds 20
#Import into local Trusted Root CA
Import-Certificate -FilePath (Join-Path -Path $PhysicalBasePath -ChildPath 'Installer.cer') -CertStoreLocation Cert:\LocalMachine\Root
Start-Sleep -Milliseconds 20

Write-Host 'Create Server to Server Trust'
try {
    New-AppHighTrust -CertPath (Join-Path -Path $PhysicalBasePath -ChildPath 'Installer.cer') -CertName $appInternalName -SPAppClientID $clientID -TokenIssuerFriendlyName ($appName + ' S2S Trust')
    Write-Host -ForegroundColor White "Done!"
}
catch {
    throw "Failed $($error[0].ToString())"
}

If ($oAuth)
{
    Write-Host 'Allow OAuth over HTTP'
    AllowOAuthoverHTTP
}

try {
    foreach ($parameter in (Get-ChildItem (join-path -Path $PSScriptRoot -ChildPath '*.SetParameters.xml')))
    {
        Write-Host 'Modify .SetParameters.xml'
        switch ($parameter.Name) {
            'Solutions2Share.Solutions.MeetingManagerWeb.SetParameters.xml' {
                [xml]$NewParameter = (Get-Content $parameter.fullname -ErrorAction Inquire)
                Write-Host ' ' $parameter.Name
                foreach ($attribute in $NewParameter.parameters.setParameter)
                {
                    switch ($attribute.Name) {
                        'IIS Web Application Name' { 
                            $attribute.Value = $($Website.Name + '/' + $WebAppMM.name)
                        }
                        'MeetingManagerClientId' {
                            $attribute.Value = $clientID.ToString()
                        }
                        'MeetingManagerIssuerId' {
                            $attribute.Value = $clientID.ToString()
                        }
                        'MeetingManagerAppFrameworkConnectionString' {
                            $attribute.Value = $("Data Source=$($SQLServer),$($SQLPort);Initial Catalog=$($DBPrefix + $DBs.MM);Persist Security Info=True;Trusted_Connection=True;Pooling=False")
                        }
                        'MeetingManagerHangfireConnectionString' {
                            $attribute.Value = $("Data Source=$($SQLServer),$($SQLPort);Initial Catalog=$($DBPrefix + $DBs.MMHF);Persist Security Info=True;Trusted_Connection=True;Pooling=False")
                        }     
                        'MeetingManagerClientSigningCertificateSerialNumber' {
                            $CertificateSerialNumber = $SelfSignedCert.SerialNumber
                            $attribute.Value = $CertificateSerialNumber.ToString()
                        }
                        'OutlookAddInUrl'
                        {
                            $attribute.Value = "https://$($Website.Name + '/' + $WebAppMM.name)/Outlook"
                        }
                        Default {
                            Write-Host 'No mapping for ' $attribute.Name -ForegroundColor Yellow
                        }
                    }
                }
                $NewParameter.Save($parameter.fullname)
            }
            'Solutions2Share.Solutions.MeetingManagerInvitationsWeb.SetParameters.xml' {
                [xml]$NewParameter = (Get-Content $parameter.fullname -ErrorAction Inquire)
                Write-Host ' ' $parameter.Name
                $IMCred = Get-Credential -Message 'Please provide Farm account or Web Application Pool Account including Domain'
                foreach ($attribute in $NewParameter.parameters.setParameter)
                {
                    switch ($attribute.Name) {
                        'IIS Web Application Name' { 
                            $attribute.Value = $($Website.name + '/' + $WebAppIM.name)
                        }
                        'InvitationToolDefaultConnectionString' {
                            $attribute.Value = $("Data Source=$($SQLServer),$($SQLPort);Initial Catalog=$($DBPrefix + $DBs.IM);Persist Security Info=True;Trusted_Connection=True;Pooling=False")
                        }
                        'InvitationToolHangfireConnectionString' {
                            $attribute.Value = $("Data Source=$($SQLServer),$($SQLPort);Initial Catalog=$($DBPrefix + $DBs.IMHF);Persist Security Info=True;Trusted_Connection=True;Pooling=False")
                        }  
                        'InvitationToolSPUsername' {
                            
                            $attribute.Value = $($IMCred.UserName)
                        }
                        'InvitationToolSPPassword' {
                            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($IMCred.Password)
                            [string]$PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR) 
                            $attribute.Value = $PlainPassword
                            $PlainPassword = $null
                        }          
                        'InvitationToolLogPath' {
                            $IMLogPath = (Join-path -path $PhysicalBasePath -ChildPath 'Log\InvitationToolLog.log')
                            $attribute.Value = $IMLogPath.ToString()
                        }                                   
                        Default {
                            Write-Host 'No match found in Parameters.xml' -ForegroundColor Yellow
                        }
                    }
                }
                $NewParameter.Save($parameter.fullname)
            }
            'Solutions2Share.Solutions.MeetingManager.OutlookWeb.SetParameters.xml' {
                [xml]$NewParameter = (Get-Content $parameter.fullname -ErrorAction Inquire)
                Write-Host ' ' $parameter.Name
                foreach ($attribute in $NewParameter.parameters.setParameter)
                {
                    switch ($attribute.Name) {
                        'IIS Web Application Name' { 
                            $attribute.value = $($Website.Name + '/' + $WebAppOutlook.name)
                        }
                        Default {
                            Write-Host 'No match found in Parameters.xml' -ForegroundColor Yellow
                        }
                    }
                }
                $NewParameter.Save($parameter.fullname)
            }
            Default {
                Write-Host 'No .SetParameters.xml found in this directory'
            }
        }
    }
}
catch {
    $ErrorText = $Error[0].ToString()
    throw $ErrorText
}

Write-Host 'Install MSDeploy'
#Before running Deploy scripts, we need to install msdeploy
Start-Process -FilePath (Join-Path -Path $PSScriptRoot -ChildPath 'WebDeploy_2_10_amd64_en-US.msi') -ArgumentList '/passive /norestart' -Wait
foreach ($parameter in (Get-ChildItem (join-path -Path $PSScriptRoot -ChildPath '*.deploy.cmd')))
{
    Write-Host 'Run msdeploy'
    Start-Process -FilePath $parameter.FullName -ArgumentList '/y' -NoNewWindow -Wait
}
If ($Solutions2Share)
{
    Write-Host 'Change Application.config' -NoNewline
    try {
        Write-Verbose 'Create Backup of applicationHost.config'
        Copy-Item -Path "$($env:SystemRoot)\system32\inetsrv\config\applicationHost.config" -Destination "$PhysicalBasePath\applicationHost.config"
        [xml]$IISAppConfig = (Get-Content "$($env:SystemRoot)\system32\inetsrv\config\applicationHost.config" -ErrorAction Inquire)
        <#
        $i = 0
        Looks like these attributes are already set.
        foreach ($Site in $IISAppConfig.configuration.'system.applicationHost'.sites.site)
        {
            If ($Site.Name -eq $appName)
            {
                #Add attributes
                #<application path="/" applicationPool="InvitationsManager" serviceAutoStartEnabled="true" serviceAutoStartProvider="ApplicationPreload">
                $XMLAttr = $IISAppConfig.CreateAttribute('serviceAutoStartEnabled')
                $IISAppConfig.configuration.'system.applicationHost'.sites.site[$i].application.SetAttributeNode($XMLAttr)
                $IISAppConfig.configuration.'system.applicationHost'.sites.site[$i].application.SetAttribute('serviceAutoStartEnabled','true')
                $XMLAttr = $IISAppConfig.CreateAttribute('serviceAutoStartProvider')
                $IISAppConfig.configuration.'system.applicationHost'.sites.site[$i].application.SetAttributeNode($XMLAttr)
                $IISAppConfig.configuration.'system.applicationHost'.sites.site[$i].application.SetAttribute('serviceAutoStartProvider','ApplicationPreload')
            }
            $i++
        }
        #>
        $ServiceProviderFound = $false
        foreach ($ServiceProvider in $IISAppConfig.configuration.'system.applicationHost'.serviceAutoStartProviders.add)
        {
            #Check if already exist, otherwise create it
            If ($ServiceProvider.type -eq 'Solutions2Share.Solutions.MeetingManagerInvitationsWeb.ApplicationPreload,Solutions2Share.Solutions.MeetingManagerInvitationsWeb')
            {
                $ServiceProviderFound = $true
            }
        }
        #After closing <weblimits />    
        If (!$ServiceProviderFound)
        {
            [xml]$ServiceProvider = '<serviceAutoStartProviders>
                        <add name="ApplicationPreload" type="Solutions2Share.Solutions.MeetingManagerInvitationsWeb.ApplicationPreload,Solutions2Share.Solutions.MeetingManagerInvitationsWeb" />
            </serviceAutoStartProviders>'
            $ModifiedXML = $IISAppConfig.configuration.'system.applicationHost'.InnerXml
            $ModifiedXML = $ModifiedXML + $ServiceProvider.InnerXml
            $IISAppConfig.configuration.'system.applicationHost'.InnerXml = $ModifiedXML

            $IISAppConfig.Save("$($env:SystemRoot)\system32\inetsrv\config\applicationHost.config")
            Write-Host 'Done' -ForegroundColor Green
        } else {
            Write-Verbose 'Do not modify applicationHost.config - serviceAutoStartProviders found'
        }
    }
    catch {
        throw $error[0].ToString()
    }
}

If ($Solutions2Share)
{
    #This section may need customization based on the properties of your App Files.
    #TODO IIS Authentication
    # system.webServer/security/authentication/anonymousAuthentication
    # Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/windowsAuthentication" -Name Enabled -Value True -PSPath "IIS:\Sites\$SiteName\$AppName"
    Write-Host 'Adjust .app Manifest'
    Write-Verbose 'Copy .app'
    Copy-Item (Get-ChildItem "$PSScriptRoot\*.app") -Destination $PhysicalBasePath
    Write-Verbose 'Rename .app to .zip'
    Rename-Item -Path (Get-ChildItem "$PhysicalBasePath\*.app") -NewName "$appName.zip"
    Write-Verbose 'Unzip'
    Unzip (Get-ChildItem "$PhysicalBasePath\$appName.zip") "$PhysicalBasePath\App"


    [xml]$AppManifest = Get-Content "$PhysicalBasePath\App\AppManifest.xml" -ErrorAction Inquire

    foreach ($ElementsXML in (Get-ChildItem "$PhysicalBasePath\App\Elements*.xml"))
    {
        #Should be one, otherwise it gets overwritten by the last
        [xml]$AppElements = Get-Content $ElementsXML.FullName -ErrorAction Inquire
    }

    $AppManifest.App.Properties.StartPage = "https://$FQDN/Web/?{StandardTokens}&amp;TypeDisplay=FullScreen&amp;SPHostLogoUrl=Content/img/S2SLogo.png"
    $AppManifest.App.AppPrincipal.RemoteWebApplication.ClientId = $clientID.ToString()
    $AppManifest.Save("$PhysicalBasePath\App\AppManifest.xml")

    $AppElements.Elements.ClientWebPart.Content.Src = "https://$FQDN/Web/MeetingManagerAppPart?{StandardTokens}"
    #Now save it under its original name determined by Get-Content before
    $AppElements.Save($ElementsXML.FullName)

    Write-Verbose 'Create ZIP'
    #BUG ZIP function is not good and App Catalog cannot extract it
        #Zip "$PhysicalBasePath\App" "$PhysicalBasePath\$AppFilename.zip"
    #FIX: New ZIP Algorithm which should SharePoint able to read.
    New-ZipFile -InputObject ($ElementsXML.FullName) -ZipFilePath "$PhysicalBasePath\$appName.zip" -Append -Force
    New-ZipFile -InputObject ("$PhysicalBasePath\App\AppManifest.xml") -ZipFilePath "$PhysicalBasePath\$appName.zip" -Append -Force
    
    Write-Verbose 'Rename .ZIP to .app'
    Rename-Item -Path ("$PhysicalBasePath\$appName.zip") -NewName "$appName.app"

    Write-Output 'Determine App Catalog'
    Write-Verbose "SPWeb:($($SPWeb.split('/')[0])//$($SPWeb.split('/')[2])"
    #WebAppURL get it from Web by splitting / and then use protocol // webapp
    $SPAppCatalog = Get-AppCatalog -WebAppUrl (($SPWeb.split('/')[0]) + '//' + ($SPWeb.split('/')[2]))
    If ($SPAppCatalog)
    {
        Write-Output 'App Catalog URL ' $SPAppCatalog
        #Upload .app File to App Catalog
        Write-Output 'Upload App File to App Catalog'
        try {
            UploadSPFile -SiteUrl $SPAppCatalog -LibraryName 'Apps for SharePoint' -SourceFile ("$PhysicalBasePath\$appName.app")
        }
        catch {
            Write-Output 'Upload failed, please upload manually'
            Write-Output "Source File: $PhysicalBasePath\$appName.app" 
            Write-Output "To App Catalog: $SPAppCatalog"
            throw $error[0].ToString()
            break
        }
    } else {
        Write-Output 'No App Catalog found, please create one an upload .app file manually'
    }
} else {
    Write-Output 'Please adjust .app File manually and upload it to App Catalog'
}

Write-Output 'Done, please run "iisreset /noforce" on each SharePoint Server or wait 24 hours'