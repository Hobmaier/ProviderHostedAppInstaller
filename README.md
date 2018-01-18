# ProviderHostedAppInstaller
SharePoint Provider Hosted App Installer using PowerShell
It will install a SharePoint Provider Hosted App which was build using Visual Studio, the folder structure could look like this:

# Folder Structure
Meeting Manager Outlook Add-in.xml
Solutions2Share.MeetingManager.Solutions2Share.MeetingManager.app
Solutions2Share.Solutions.MeetingManager.OutlookWeb.deploy-readme.txt
Solutions2Share.Solutions.MeetingManager.OutlookWeb.deploy.cmd
Solutions2Share.Solutions.MeetingManager.OutlookWeb.SetParameters.xml
Solutions2Share.Solutions.MeetingManager.OutlookWeb.SourceManifest.xml
Solutions2Share.Solutions.MeetingManager.OutlookWeb.zip
Solutions2Share.Solutions.MeetingManagerInvitationsWeb.deploy-readme.txt
Solutions2Share.Solutions.MeetingManagerInvitationsWeb.deploy.cmd
Solutions2Share.Solutions.MeetingManagerInvitationsWeb.SetParameters.xml
Solutions2Share.Solutions.MeetingManagerInvitationsWeb.SourceManifest.xml
Solutions2Share.Solutions.MeetingManagerInvitationsWeb.zip
Solutions2Share.Solutions.MeetingManagerWeb.deploy-readme.txt
Solutions2Share.Solutions.MeetingManagerWeb.deploy.cmd
Solutions2Share.Solutions.MeetingManagerWeb.SetParameters.xml
Solutions2Share.Solutions.MeetingManagerWeb.SourceManifest.xml
Solutions2Share.Solutions.MeetingManagerWeb.zip

Just add this PowerShell to the same directory:
Install-ProviderHostedApp-Config.xml
Install-ProviderHostedApp.ps1
ProviderHostedApp.pfx
WebDeploy_2_10_amd64_en-US.msi

# Customize XML
Please customize the XML file which includes
- ServiceAccount, the account the app will run with. A domain account will be enough: contoso\meetingmanager 
- The FQDN DNS name where the App will be available later on. Make sure it has been already created: meetingmanager.contoso.com 
- InstallationDirectory: C:\Program Files\Solutions2Share\Meeting Manager
- AllowOAuthoverHTT =true
- SPSite: https://portal2016.contoso.com
- ClientID
- DBServer including instance: Contoso-SQL\SP2016
- DBServerPort and Port: 1433
- DBPrefix Database name prefix: PRD_App_
- Databasename Type Valid Type = Generic or for Solutions2Share MM, MMHF, IM, IMHF
- Databasename Name="MeetingManager" Type="MM"
- Databasename Name="MeetingManagerHangfire" Type="MMHF"
- Databasename Name="InvitationManagerConfig" Type="IM"
- Databasename Name="InvitationManagerHangfire" Type="IMHF"


# Run Installation
Use PowerShell with admin priviliges. Make sure that you've customized the XML in the previous step
PS D:\ProviderHostedAppInstaller\ .\Install-ProviderHostedApp.ps1 -InputFile "D:\ProviderHostedAppInstaller\Install-ProviderHostedApp-Config.xml"

# More
Please also see this: https://www.hobmaier.net/2018/01/sharepoint-provider-hosted-app-installer.html