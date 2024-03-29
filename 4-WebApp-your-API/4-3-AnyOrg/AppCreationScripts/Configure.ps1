 
[CmdletBinding()]
param(
    [Parameter(Mandatory=$False, HelpMessage='Tenant ID (This is a GUID which represents the "Directory ID" of the AzureAD tenant into which you want to create the apps')]
    [string] $tenantId,
    [Parameter(Mandatory=$False, HelpMessage='Azure environment to use while running the script. Default = Global')]
    [string] $azureEnvironmentName
)

<#
 This script creates the Azure AD applications needed for this sample and updates the configuration files
 for the visual Studio projects from the data in the Azure AD applications.

 In case you don't have Microsoft.Graph.Applications already installed, the script will automatically install it for the current user
 
 There are two ways to run this script. For more information, read the AppCreationScripts.md file in the same folder as this script.
#>

# Create an application key
# See https://www.sabin.io/blog/adding-an-azure-active-directory-application-and-key-using-powershell/
Function CreateAppKey([DateTime] $fromDate, [double] $durationInMonths)
{
    $key = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphPasswordCredential

    $key.StartDateTime = $fromDate
    $key.EndDateTime = $fromDate.AddMonths($durationInMonths)
    $key.KeyId = (New-Guid).ToString()
    $key.DisplayName = "app secret"

    return $key
}

# Adds the requiredAccesses (expressed as a pipe separated string) to the requiredAccess structure
# The exposed permissions are in the $exposedPermissions collection, and the type of permission (Scope | Role) is 
# described in $permissionType
Function AddResourcePermission($requiredAccess, `
                               $exposedPermissions, [string]$requiredAccesses, [string]$permissionType)
{
    foreach($permission in $requiredAccesses.Trim().Split("|"))
    {
        foreach($exposedPermission in $exposedPermissions)
        {
            if ($exposedPermission.Value -eq $permission)
                {
                $resourceAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess
                $resourceAccess.Type = $permissionType # Scope = Delegated permissions | Role = Application permissions
                $resourceAccess.Id = $exposedPermission.Id # Read directory data
                $requiredAccess.ResourceAccess += $resourceAccess
                }
        }
    }
}

#
# Example: GetRequiredPermissions "Microsoft Graph"  "Graph.Read|User.Read"
# See also: http://stackoverflow.com/questions/42164581/how-to-configure-a-new-azure-ad-application-through-powershell
Function GetRequiredPermissions([string] $applicationDisplayName, [string] $requiredDelegatedPermissions, [string]$requiredApplicationPermissions, $servicePrincipal)
{
    # If we are passed the service principal we use it directly, otherwise we find it from the display name (which might not be unique)
    if ($servicePrincipal)
    {
        $sp = $servicePrincipal
    }
    else
    {
        $sp = Get-MgServicePrincipal -Filter "DisplayName eq '$applicationDisplayName'"
    }
    $appid = $sp.AppId
    $requiredAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess
    $requiredAccess.ResourceAppId = $appid 
    $requiredAccess.ResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess]

    # $sp.Oauth2Permissions | Select Id,AdminConsentDisplayName,Value: To see the list of all the Delegated permissions for the application:
    if ($requiredDelegatedPermissions)
    {
        AddResourcePermission $requiredAccess -exposedPermissions $sp.Oauth2PermissionScopes -requiredAccesses $requiredDelegatedPermissions -permissionType "Scope"
    }
    
    # $sp.AppRoles | Select Id,AdminConsentDisplayName,Value: To see the list of all the Application permissions for the application
    if ($requiredApplicationPermissions)
    {
        AddResourcePermission $requiredAccess -exposedPermissions $sp.AppRoles -requiredAccesses $requiredApplicationPermissions -permissionType "Role"
    }
    return $requiredAccess
}


<#.Description
   This function takes a string input as a single line, matches a key value and replaces with the replacement value
#> 
Function UpdateLine([string] $line, [string] $value)
{
    $index = $line.IndexOf(':')
    $lineEnd = ''

    if($line[$line.Length - 1] -eq ','){   $lineEnd = ',' }
    
    if ($index -ige 0)
    {
        $line = $line.Substring(0, $index+1) + " " + '"' + $value+ '"' + $lineEnd
    }
    return $line
}

<#.Description
   This function takes a dictionary of keys to search and their replacements and replaces the placeholders in a text file
#> 
Function UpdateTextFile([string] $configFilePath, [System.Collections.HashTable] $dictionary)
{
    $lines = Get-Content $configFilePath
    $index = 0
    while($index -lt $lines.Length)
    {
        $line = $lines[$index]
        foreach($key in $dictionary.Keys)
        {
            if ($line.Contains($key))
            {
                $lines[$index] = UpdateLine $line $dictionary[$key]
            }
        }
        $index++
    }

    Set-Content -Path $configFilePath -Value $lines -Force
}
<#.Description
   This function creates a new Azure AD scope (OAuth2Permission) with default and provided values
#>  
Function CreateScope( [string] $value, [string] $userConsentDisplayName, [string] $userConsentDescription, [string] $adminConsentDisplayName, [string] $adminConsentDescription)
{
    $scope = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphPermissionScope
    $scope.Id = New-Guid
    $scope.Value = $value
    $scope.UserConsentDisplayName = $userConsentDisplayName
    $scope.UserConsentDescription = $userConsentDescription
    $scope.AdminConsentDisplayName = $adminConsentDisplayName
    $scope.AdminConsentDescription = $adminConsentDescription
    $scope.IsEnabled = $true
    $scope.Type = "User"
    return $scope
}

<#.Description
   This function creates a new Azure AD AppRole with default and provided values
#>  
Function CreateAppRole([string] $types, [string] $name, [string] $description)
{
    $appRole = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphAppRole
    $appRole.AllowedMemberTypes = New-Object System.Collections.Generic.List[string]
    $typesArr = $types.Split(',')
    foreach($type in $typesArr)
    {
        $appRole.AllowedMemberTypes += $type;
    }
    $appRole.DisplayName = $name
    $appRole.Id = New-Guid
    $appRole.IsEnabled = $true
    $appRole.Description = $description
    $appRole.Value = $name;
    return $appRole
}

<#.Description
   This function takes a string as input and creates an instance of an Optional claim object
#> 
Function CreateOptionalClaim([string] $name)
{
    <#.Description
    This function creates a new Azure AD optional claims  with default and provided values
    #>  

    $appClaim = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphOptionalClaim
    $appClaim.AdditionalProperties =  New-Object System.Collections.Generic.List[string]
    $appClaim.Source =  $null
    $appClaim.Essential = $false
    $appClaim.Name = $name
    return $appClaim
}

<#.Description
   Primary entry method to create and configure app registrations
#> 
Function ConfigureApplications
{
    $isOpenSSl = 'N' #temporary disable open certificate creation 

    <#.Description
       This function creates the Azure AD applications for the sample in the provided Azure AD tenant and updates the
       configuration files in the client and service project  of the visual studio solution (App.Config and Web.Config)
       so that they are consistent with the Applications parameters
    #> 
    
    if (!$azureEnvironmentName)
    {
        $azureEnvironmentName = "Global" # as opposed to USGov
    }

    # Connect to the Microsoft Graph API, non-interactive is not supported for the moment (Oct 2021)
    Write-Host "Connecting to Microsoft Graph"
    if ($tenantId -eq "") {
        Connect-MgGraph -Scopes "User.Read.All Organization.Read.All Application.ReadWrite.All" -Environment $azureEnvironmentName
    }
    else {
        Connect-MgGraph -TenantId $tenantId -Scopes "User.Read.All Organization.Read.All Application.ReadWrite.All" -Environment $azureEnvironmentName
    }
    
    $context = Get-MgContext
    $tenantId = $context.TenantId

    # Get the user running the script
    $me = Invoke-MgGraphRequest -Method GET https://graph.microsoft.com/v1.0/me
    $currentUserPrincipalName = $me.userPrincipalName
    $user = Get-MgUser -Filter "UserPrincipalName eq '$($currentUserPrincipalName)'"

    # get the tenant we signed in to
    $Tenant = Get-MgOrganization
    $tenantName = $Tenant.DisplayName
    
    $verifiedDomain = $Tenant.VerifiedDomains | where {$_.Isdefault -eq $true}
    $verifiedDomainName = $verifiedDomain.Name
    $tenantId = $Tenant.Id

    Write-Host ("Connected to Tenant {0} ({1}) as account '{2}'. Domain is '{3}'" -f  $Tenant.DisplayName, $Tenant.Id, $currentUserPrincipalName, $verifiedDomainName)

   # Create the service AAD application
   Write-Host "Creating the AAD application (WebApi_MultiTenant_v2)"
   # Get a 6 months application key for the service Application
   $fromDate = [DateTime]::Now;
   $key = CreateAppKey -fromDate $fromDate -durationInMonths 6
   
   # create the application 
   $serviceAadApplication = New-MgApplication -DisplayName "WebApi_MultiTenant_v2" `
                                                       -Web `
                                                       @{ `
                                                           RedirectUris = "https://localhost:44351/api/Home"; `
                                                           HomePageUrl = "https://localhost:44351/"; `
                                                         } `
                                                         -Api `
                                                         @{ `
                                                            RequestedAccessTokenVersion = 2 `
                                                         } `
                                                        -SignInAudience AzureADMultipleOrgs `
                                                       #end of command

    #add a secret to the application
    $pwdCredential = Add-MgApplicationPassword -ApplicationId $serviceAadApplication.Id -PasswordCredential $key
    $serviceAppKey = $pwdCredential.SecretText

    $currentAppId = $serviceAadApplication.AppId
    $currentAppObjectId = $serviceAadApplication.Id

    $serviceIdentifierUri = 'api://'+$currentAppId
    Update-MgApplication -ApplicationId $currentAppObjectId -IdentifierUris @($serviceIdentifierUri)
    
    # create the service principal of the newly created application     
    $serviceServicePrincipal = New-MgServicePrincipal -AppId $currentAppId -Tags {WindowsAzureActiveDirectoryIntegratedApp}

    # add the user running the script as an app owner if needed
    $owner = Get-MgApplicationOwner -ApplicationId $currentAppObjectId
    if ($owner -eq $null)
    { 
        New-MgApplicationOwnerByRef -ApplicationId $currentAppObjectId  -BodyParameter @{"@odata.id" = "htps://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)"}
        Write-Host "'$($user.UserPrincipalName)' added as an application owner to app '$($serviceServicePrincipal.DisplayName)'"
    }

    # Add Claims

    $optionalClaims = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphOptionalClaims
    $optionalClaims.AccessToken = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphOptionalClaim]
    $optionalClaims.IdToken = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphOptionalClaim]
    $optionalClaims.Saml2Token = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphOptionalClaim]

    # Add Optional Claims

    $newClaim =  CreateOptionalClaim  -name "idtyp" 
    $optionalClaims.AccessToken += ($newClaim)
    Update-MgApplication -ApplicationId $currentAppObjectId -OptionalClaims $optionalClaims
    
    # Publish Application Permissions
    $appRoles = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphAppRole]
    $newRole = CreateAppRole -types "Application" -name "ToDoList.Read.All" -description "Allow the app to read every user's ToDo list using the 'WebApi_MultiTenant_v2'"
    $appRoles.Add($newRole)
    $newRole = CreateAppRole -types "Application" -name "ToDoList.ReadWrite.All" -description "Allow the app to read every user's ToDo list using the 'WebApi_MultiTenant_v2'"
    $appRoles.Add($newRole)
    Update-MgApplication -ApplicationId $currentAppObjectId -AppRoles $appRoles
    
    # rename the user_impersonation scope if it exists to match the readme steps or add a new scope
       
    # delete default scope i.e. User_impersonation
    $scopes = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphPermissionScope]
    $scope = $serviceAadApplication.Api.Oauth2PermissionScopes | Where-Object { $_.Value -eq "User_impersonation" }
    
    if($scope -ne $null)
    {    
        # disable the scope
        $scope.IsEnabled = $false
        $scopes.Add($scope)
        Update-MgApplication -ApplicationId $currentAppObjectId -Api @{Oauth2PermissionScopes = @($scopes)}

        # clear the scope
        Update-MgApplication -ApplicationId $currentAppObjectId -Api @{Oauth2PermissionScopes = @()}
    }

    $scopes = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphPermissionScope]
    $scope = CreateScope -value ToDoList.Read  `
        -userConsentDisplayName "Read users ToDo list using the 'WebApi_MultiTenant_v2'"  `
        -userConsentDescription "Allow the app to read your ToDo list items via the 'WebApi_MultiTenant_v2'"  `
        -adminConsentDisplayName "Read users ToDo list using the 'WebApi_MultiTenant_v2'"  `
        -adminConsentDescription "Allow the app to read the user's ToDo list using the 'WebApi_MultiTenant_v2'"
            
    $scopes.Add($scope)
    $scope = CreateScope -value ToDoList.ReadWrite  `
        -userConsentDisplayName "Read and Write user's ToDo list using the 'WebApi_MultiTenant_v2'"  `
        -userConsentDescription "Allow the app to read and write your ToDo list items via the 'WebApi_MultiTenant_v2'"  `
        -adminConsentDisplayName "Read and Write user's ToDo list using the 'WebApi_MultiTenant_v2'"  `
        -adminConsentDescription "Allow the app to read and write user's ToDo list using the 'WebApi_MultiTenant_v2'"
            
    $scopes.Add($scope)
    
    # add/update scopes
    Update-MgApplication -ApplicationId $currentAppObjectId -Api @{Oauth2PermissionScopes = @($scopes)}
    Write-Host "Done creating the service application (WebApi_MultiTenant_v2)"

    # URL of the AAD application in the Azure portal
    # Future? $servicePortalUrl = "https://portal.azure.com/#@"+$tenantName+"/blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/"+$currentAppId+"/objectId/"+$currentAppObjectId+"/isMSAApp/"
    $servicePortalUrl = "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/"+$currentAppId+"/isMSAApp~/false"

    Add-Content -Value "<tr><td>service</td><td>$currentAppId</td><td><a href='$servicePortalUrl'>WebApi_MultiTenant_v2</a></td></tr>" -Path createdApps.html
    # Declare a list to hold RRA items    
    $requiredResourcesAccess = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess]

    # Add Required Resources Access (from 'service' to 'Microsoft Graph')
    Write-Host "Getting access from 'service' to 'Microsoft Graph'"
    $requiredPermission = GetRequiredPermissions -applicationDisplayName "Microsoft Graph"`
        -requiredDelegatedPermissions "User.Read.All"

    $requiredResourcesAccess.Add($requiredPermission)
    Write-Host "Added 'Microsoft Graph' to the RRA list."
    # Useful for RRA additions troubleshooting
    # $requiredResourcesAccess.Count
    # $requiredResourcesAccess
    
    Update-MgApplication -ApplicationId $currentAppObjectId -RequiredResourceAccess $requiredResourcesAccess
    Write-Host "Granted permissions."
    

    # print the registered app portal URL for any further navigation
    Write-Host "Successfully registered and configured that app registration for 'WebApi_MultiTenant_v2' at `n $servicePortalUrl" -ForegroundColor Green 
   # Create the client AAD application
   Write-Host "Creating the AAD application (WebApp_MultiTenant_v2)"
   # Get a 6 months application key for the client Application
   $fromDate = [DateTime]::Now;
   $key = CreateAppKey -fromDate $fromDate -durationInMonths 6
   
   # create the application 
   $clientAadApplication = New-MgApplication -DisplayName "WebApp_MultiTenant_v2" `
                                                      -Web `
                                                      @{ `
                                                          RedirectUris = "https://localhost:44321/", "https://localhost:44321/signin-oidc"; `
                                                          HomePageUrl = "https://localhost:44321/"; `
                                                          LogoutUrl = "https://localhost:44321/signout-callback-oidc"; `
                                                        } `
                                                       -SignInAudience AzureADMultipleOrgs `
                                                      #end of command

    #add a secret to the application
    $pwdCredential = Add-MgApplicationPassword -ApplicationId $clientAadApplication.Id -PasswordCredential $key
    $clientAppKey = $pwdCredential.SecretText

    $currentAppId = $clientAadApplication.AppId
    $currentAppObjectId = $clientAadApplication.Id

    $tenantName = (Get-MgApplication -ApplicationId $currentAppObjectId).PublisherDomain
    #Update-MgApplication -ApplicationId $currentAppObjectId -IdentifierUris @("https://$tenantName/WebApp_MultiTenant_v2")
        # Generate a certificate
        Write-Host "Creating the client application (WebApp_MultiTenant_v2)"

        $certificateName = 'WebApp_MultiTenant_v2'

        # temporarily disable the option and procees to certificate creation
        #$isOpenSSL = Read-Host ' By default certificate is generated using New-SelfSignedCertificate. Do you want to generate cert using OpenSSL(Y/N)?'
        $isOpenSSl = 'N'
        if($isOpenSSL -eq 'Y')
        {
            $certificate=openssl req -x509 -newkey rsa:2048 -days 365 -keyout "$certificateName.key" -out "$certificateName.cer" -subj "/CN=$certificateName.com" -nodes
            openssl pkcs12 -export -out "$certificateName.pfx" -inkey $certificateName.key -in "$certificateName.cer"
        }
        else
        {
            $certificate=New-SelfSignedCertificate -Subject $certificateName `
                                                    -CertStoreLocation "Cert:\CurrentUser\My" `
                                                    -KeyExportPolicy Exportable `
                                                    -KeySpec Signature

            $thumbprint = $certificate.Thumbprint
            $certificatePassword = Read-Host -Prompt "Enter password for your certificate (Please remember the password, you will need it when uploading to KeyVault): " -AsSecureString
            Write-Host "Exporting certificate as a PFX file"
            Export-PfxCertificate -Cert "Cert:\Currentuser\My\$thumbprint" -FilePath "$pwd\$certificateName.pfx" -ChainOption EndEntityCertOnly -NoProperties -Password $certificatePassword
            Write-Host "PFX written to:"
            Write-Host "$pwd\$certificateName.pfx"

            # Add a Azure Key Credentials from the certificate for the application
            $clientKeyCredentials = Update-MgApplication -ApplicationId $currentAppObjectId `
                -KeyCredentials @(@{Type = "AsymmetricX509Cert"; Usage = "Verify"; Key= $certificate.RawData; StartDateTime = $certificate.NotBefore; EndDateTime = $certificate.NotAfter;})       
       
        }  
    
    # create the service principal of the newly created application     
    $clientServicePrincipal = New-MgServicePrincipal -AppId $currentAppId -Tags {WindowsAzureActiveDirectoryIntegratedApp}

    # add the user running the script as an app owner if needed
    $owner = Get-MgApplicationOwner -ApplicationId $currentAppObjectId
    if ($owner -eq $null)
    { 
        New-MgApplicationOwnerByRef -ApplicationId $currentAppObjectId  -BodyParameter @{"@odata.id" = "htps://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)"}
        Write-Host "'$($user.UserPrincipalName)' added as an application owner to app '$($clientServicePrincipal.DisplayName)'"
    }

    # Add Claims

    $optionalClaims = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphOptionalClaims
    $optionalClaims.AccessToken = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphOptionalClaim]
    $optionalClaims.IdToken = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphOptionalClaim]
    $optionalClaims.Saml2Token = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphOptionalClaim]

    # Add Optional Claims

    $newClaim =  CreateOptionalClaim  -name "acct" 
    $optionalClaims.IdToken += ($newClaim)
    Update-MgApplication -ApplicationId $currentAppObjectId -OptionalClaims $optionalClaims
    Write-Host "Done creating the client application (WebApp_MultiTenant_v2)"

    # URL of the AAD application in the Azure portal
    # Future? $clientPortalUrl = "https://portal.azure.com/#@"+$tenantName+"/blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/"+$currentAppId+"/objectId/"+$currentAppObjectId+"/isMSAApp/"
    $clientPortalUrl = "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/"+$currentAppId+"/isMSAApp~/false"

    Add-Content -Value "<tr><td>client</td><td>$currentAppId</td><td><a href='$clientPortalUrl'>WebApp_MultiTenant_v2</a></td></tr>" -Path createdApps.html
    # Declare a list to hold RRA items    
    $requiredResourcesAccess = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess]

    # Add Required Resources Access (from 'client' to 'service')
    Write-Host "Getting access from 'client' to 'service'"
    $requiredPermission = GetRequiredPermissions -applicationDisplayName "WebApi_MultiTenant_v2"`
        -requiredDelegatedPermissions "ToDoList.Read|ToDoList.ReadWrite"

    $requiredResourcesAccess.Add($requiredPermission)
    Write-Host "Added 'service' to the RRA list."
    # Useful for RRA additions troubleshooting
    # $requiredResourcesAccess.Count
    # $requiredResourcesAccess
    
    Update-MgApplication -ApplicationId $currentAppObjectId -RequiredResourceAccess $requiredResourcesAccess
    Write-Host "Granted permissions."
    

    # print the registered app portal URL for any further navigation
    Write-Host "Successfully registered and configured that app registration for 'WebApp_MultiTenant_v2' at `n $clientPortalUrl" -ForegroundColor Green 

    # Configure known client applications for service 
    Write-Host "Configure known client applications for the 'service'"
    $knownApplications = New-Object System.Collections.Generic.List[System.String]
    $knownApplications.Add($clientAadApplication.AppId)
    Update-MgApplication -ApplicationId $serviceAadApplication.Id -Api @{KnownClientApplications = $knownApplications}
    Write-Host "knownclientapplication setting configured."

    
    # Update config file for 'service'
    # $configFile = $pwd.Path + "\..\ToDoListService\appsettings.json"
    $configFile = $(Resolve-Path ($pwd.Path + "\..\ToDoListService\appsettings.json"))
    
    $dictionary = @{ "Domain" = $tenantName;"TenantId" = 'common';"ClientId" = $serviceAadApplication.AppId;"ClientSecret" = $serviceAppKey };

    Write-Host "Updating the sample config '$configFile' with the following config values:" -ForegroundColor Yellow 
    $dictionary
    Write-Host "-----------------"

    UpdateTextFile -configFilePath $configFile -dictionary $dictionary
    
    # Update config file for 'client'
    # $configFile = $pwd.Path + "\..\ToDoListClient\appsettings.json"
    $configFile = $(Resolve-Path ($pwd.Path + "\..\ToDoListClient\appsettings.json"))
    
    $dictionary = @{ "ClientId" = $clientAadApplication.AppId;"TenantId" = 'common';"Domain" = $tenantName;"ClientSecret" = $clientAppKey;"RedirectUri" = $clientAadApplication.Web.HomePageUrl;"TodoListServiceScope" = ("api://"+$serviceAadApplication.AppId+"/.default");"TodoListServiceAppId" = $serviceAadApplication.AppId;"TodoListBaseAddress" = $serviceAadApplication.Web.HomePageUrl;"AdminConsentRedirectApi" = $serviceAadApplication.Web.RedirectUris };

    Write-Host "Updating the sample config '$configFile' with the following config values:" -ForegroundColor Yellow 
    $dictionary
    Write-Host "-----------------"

    UpdateTextFile -configFilePath $configFile -dictionary $dictionary
    Write-Host -ForegroundColor Green "------------------------------------------------------------------------------------------------" 
    Write-Host "IMPORTANT: Please follow the instructions below to complete a few manual step(s) in the Azure portal":
    Write-Host "- For service"
    Write-Host "  - Navigate to $servicePortalUrl"
    Write-Host "  - Navigate to the API Permissions page and select 'Grant admin consent for (your tenant)' to User.Read.All permission for Graph API" -ForegroundColor Red 
    Write-Host "  - Open the service project's appsettings.json and update 'AllowedTenants' with your tenant id." -ForegroundColor Red 
    Write-Host "  - Application 'service' publishes application permissions. Do remember to navigate to any client app(s) registration in the app portal and consent for those, (if required)" -ForegroundColor Red 
    Write-Host -ForegroundColor Green "------------------------------------------------------------------------------------------------" 
   
    if($isOpenSSL -eq 'Y')
    {
        Write-Host -ForegroundColor Green "------------------------------------------------------------------------------------------------" 
        Write-Host "You have generated certificate using OpenSSL so follow below steps: "
        Write-Host "Install the certificate on your system from current folder."
        Write-Host -ForegroundColor Green "------------------------------------------------------------------------------------------------" 
    }
    Add-Content -Value "</tbody></table></body></html>" -Path createdApps.html  
} # end of ConfigureApplications function

# Pre-requisites

if ($null -eq (Get-Module -ListAvailable -Name "Microsoft.Graph")) {
    Install-Module "Microsoft.Graph" -Scope CurrentUser 
}

#Import-Module Microsoft.Graph

if ($null -eq (Get-Module -ListAvailable -Name "Microsoft.Graph.Authentication")) {
    Install-Module "Microsoft.Graph.Authentication" -Scope CurrentUser 
}

Import-Module Microsoft.Graph.Authentication

if ($null -eq (Get-Module -ListAvailable -Name "Microsoft.Graph.Identity.DirectoryManagement")) {
    Install-Module "Microsoft.Graph.Identity.DirectoryManagement" -Scope CurrentUser 
}

Import-Module Microsoft.Graph.Identity.DirectoryManagement

if ($null -eq (Get-Module -ListAvailable -Name "Microsoft.Graph.Applications")) {
    Install-Module "Microsoft.Graph.Applications" -Scope CurrentUser 
}

Import-Module Microsoft.Graph.Applications

if ($null -eq (Get-Module -ListAvailable -Name "Microsoft.Graph.Groups")) {
    Install-Module "Microsoft.Graph.Groups" -Scope CurrentUser 
}

Import-Module Microsoft.Graph.Groups

if ($null -eq (Get-Module -ListAvailable -Name "Microsoft.Graph.Users")) {
    Install-Module "Microsoft.Graph.Users" -Scope CurrentUser 
}

Import-Module Microsoft.Graph.Users

Set-Content -Value "<html><body><table>" -Path createdApps.html
Add-Content -Value "<thead><tr><th>Application</th><th>AppId</th><th>Url in the Azure portal</th></tr></thead><tbody>" -Path createdApps.html

$ErrorActionPreference = "Stop"

# Run interactively (will ask you for the tenant ID)

try
{
    ConfigureApplications -tenantId $tenantId -environment $azureEnvironmentName
}
catch
{
    $_.Exception.ToString() | out-host
    $message = $_
    Write-Warning $Error[0]    
    Write-Host "Unable to register apps. Error is $message." -ForegroundColor White -BackgroundColor Red
}
Write-Host "Disconnecting from tenant"
Disconnect-MgGraph