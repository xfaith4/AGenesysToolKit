##### Configure Security Protocols to use for TLS/SSL Web Requests
[Net.ServicePointManager]::SecurityProtocol = "Tls, Tls11, Tls12"


##### Get an access token for a user account (token implicit)
##### uses usw2.pure.cloud and the Developer Tools - Token Implicit by default (XAML Form)
function Get-GenesysCloudAccessToken {
    <#
    .SYNOPSIS
        Get-GenesysCloudAccessToken is used to return an Authentication Access Token
    .DESCRIPTION
        Get-GenesysCloudAccessToken is used to return an Authentication Access Token

        This can be used to obtaina a new Authentication Access Token against a
        different user account, a different org, a different environment, or to
        refresh the current token
    .PARAMETER clientID
        The clientID parameter is a string type, and must be the client ID of an
        integration configured to use token-based authentication.  The default for
        this parameter is the SCA integration defined as Developer Tools OAuth
        Application : 3e1ae9f9-9dc6-4f06-bf60-c6f8badd46a1
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.com.  The default is usw2.pure.cloud
    .EXAMPLE
        Get-GenesysCloudAccessToken
        The above example shows how to update the current access token, which will be saved
        to the $ClientAccessToken global variable.
    .EXAMPLE
        Get-GenesysCloudAccessToken -clientID 12a34b56-c78d-e90f-f09e-d87c65b43a21 -InstanceName inindca
        The above example shows how to get an authorization access token using a specific
        clientID and accessing the ININDCA environment.  The new token will be saved to
        the $ClientAccessToken global variable.
    #>
    Param(
        [string]$clientID = "3e1ae9f9-9dc6-4f06-bf60-c6f8badd46a1",
        [string]$InstanceName = "usw2.pure.cloud"
    )
    $authURI = "https://login.$InstanceName/oauth/authorize"

    #Load WPF assembly
    Add-Type -AssemblyName PresentationFramework

    [scriptblock]$OnDocumentCompleted = {
        if($WebBrowser.Source.AbsoluteUri -match "access_token=([^&]*)") {
            Set-Variable -Name ClientAccessToken -Value $Matches[1] -Scope Global
            $AuthWindow.Close()
            }
        elseif($WebBrowser.Source.AbsoluteUri -match "error=") {
            $AuthWindow.Close()
            }
        }

#Create WPF Window object
    [xml]$xaml = @"
        <Window
            xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
            Title="GenesysCloud Developer API - Authentication" WindowStartupLocation="CenterScreen" Width="900" Height="700" ShowInTaskbar="True">
            <WebBrowser Name="WebBrowser"></WebBrowser>
        </Window>
"@
    $reader=(New-Object System.Xml.XmlNodeReader $xaml)

    #Build WPF window object
    $AuthWindow=[Windows.Markup.XamlReader]::Load($reader)
    $AuthWindow.Topmost = $true
    $AuthWindow.Add_SourceInitialized({
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]"0:0:0.999"
        $timer.Add_Tick({
            $OnDocumentCompleted.Invoke()
            })
        $timer.Start()
        })

    #Load web browser into WPF window object and navigat to auth page
    $WebBrowser = $AuthWindow.FindName("WebBrowser")
    $WebBrowser.Navigate("$authURI`?response_type=token&client_id=$clientID")

    #Present WPF window object to user
    $async = $AuthWindow.Dispatcher.InvokeAsync({
        $AuthWindow.ShowDialog() | Out-Null
    })
    $async.Wait() | Out-Null
    $reader.Close()
    $ClientAccessToken
}


##### Get an access token for programmatic access (client creds.)
##### uses usw2.pure.cloud and the Developer Tools - Client Credentials
function Get-GenesysCloudPSAccessToken {
<#
.SYNOPSIS
    Get-GenesysCloudPSAccessToken is used to return an Authentication Access Token
.DESCRIPTION
    Get-GenesysCloudPSAccessToken is used to return an Authentication Access Token

    This can be used to obtaina a new Authentication Access Token against a
    different user account, a different org, a different environment, or to
    refresh the current token
.PARAMETER clientID
    The clientID parameter is a string type, and must be the client ID of an
    integration configured to use token-based authentication.  The default for
    this parameter is the SCA integration defined as Developer Tools - Client
    Credentials : 6bdb6f6c-817c-4fcf-bf41-7c877b5c4cdd
.PARAMETER clientSecret
    The clientSecret parameter is a string type, and must be the client secret
    of an integration configured to use client credential authentication.  There
    is no default for this parameter, and this parameter is required.
.PARAMETER InstanceName
    The InstanceName parameter is a string type, and is the name of the GenesysCloud
    environemt, e.g.: usw2.pure.cloud or inindca.com.  The default is usw2.pure.cloud
.EXAMPLE
    Get-GenesysCloudPSAccessToken

    The above example shows how to update the current access token using the default
    parameters.  The new token will be saved to the $ClientAccessToken global
    variable.
.EXAMPLE
    Get-GenesysCloudAccessToken -clientID 12a34b56-c78d-e90f-f09e-d87c65b43a21 -InstanceName
      inindca -clientSecret "_sxwSzwWMcCbi4cMLYd1234567890WMRDZxuK3kXChs"

    The above example shows how to get an authorization access token using a specific
    clientID, a specific clientSecret, and accessing the ININDCA environment.  The new
    token will be saved to the $ClientAccessToken global variable.
#>

Param(
    [string]$clientID = "6bdb6f6c-817c-4fcf-bf41-7c877b5c4cdd",
    [string]$clientSecret,
    [string]$InstanceName = "usw2.pure.cloud"
)
$redirectUri = "https://developer.$InstanceName/developer-tools/"
$tokenUri = "https://login.$InstanceName/oauth/token"
$authBody = @{
    "client_id" = $clientId
    "client_secret" = $clientSecret
    "grant_type" = "client_credentials"
    "redirect_uri" = $redirectUri
    }
$ClientAccessToken = (Invoke-RestMethod -Method Post -Uri $tokenUri -ContentType "application/x-www-form-urlencoded" -Body $authBody).access_token

$ClientAccessToken
}


##### Get user based on user's display name, email address, login ID, or userId
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudUser {
    <#
    .SYNOPSIS
        Get-GenesysCloudUser is used to return a user object or list of user objects
    .DESCRIPTION
        Get-GenesysCloudUser is used to return a user object or list of user objects

        This can be used to search for a specific user by the user's GenesysCloud userId,
        name, login ID, or email address.  This can also be used to search for all users,
        or a set of users matching the ID search string.

        GenesysCloud will be searched for a user object (or multiple user objects) based on
        what is typed for the ID parameter

        The ID parameter can be the user's userId, the user's name, the user's login ID,
        or the user's email address.
    .PARAMETER ID
        The ID parameter is a string type, and can be the user's userId, the user's name,
        the user's login ID, or the user's email address
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.com.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    .PARAMETER Me
        The Me parameter is a switch type, and is used to flag the API request to output
        the currently authenticated user's object
    .PARAMETER CallForwarding
        The CallForwarding parameter is a switch type, and is used to flag the API request
        to also output the Call-forwarding configuration for the user object
    .PARAMETER Voicemail
        The Voicemail parameter is a switch type, and is used to flag the API request to
        also output the Voicemail Policy configuration for the user object
    .PARAMETER DefaultPhone
        The DefaultPhone parameter is a switch type, and is used to flag the API request
        to also output the user's default phone object if one is assigned
    .PARAMETER Relationships
        The Relationships parameter is a string type, and is used to flag the API request
        to output the user's direct reports or the user's direct and distant reports. This
        paramter uses the validateSet() function and the valuse passed must be either
        DirectAndDistant or DirectOnly
    .EXAMPLE
        Get-GenesysCloudUser -ID "Parker, Peter"

        The above example shows how to get the user object for Peter Parker, using his
        GenesysCloud display name.  It is enclosed in double-quotes, as there is a space in
        the user's display name.
    .EXAMPLE
        Get-GenesysCloudUser -ID bruce.wayne -Voicemail

        The above example shows how to get the user object and the configured Voicemail
        Policy for Bruce Wayne.  The API is searched based on his GenesysCloud login ID.
    .EXAMPLE
        Get-GenesysCloudUser -ID 12a34b56-c78d-e90f-f09e-d87c65b43a21 -Voicemail -CallForwarding -Roles

        The above example shows how to get the user object, the configured Voicemail Policy,
        the Call-forwarding information, and the assigned Roles for Bruce Wayne.  The API
        is searched based on his GenesysCloud userId.
    .EXAMPLE
        Get-GenesysCloudUser -Me

        The above example shows how to get the the currently authenticated user's object.
    .EXAMPLE
        Get-GenesysCloudUser -ID clark.kent -DefaultPhone

        The above example shows how to get the user object and the default phone for Clark
        Kent.  If a default phone is not configured, the output indicates no default phone.
    .EXAMPLE
        Get-GenesysCloudUser -ID tony.stark -Relationships DirectAndDistant

        The above example shows how to get the user object and all reports, both direct and
        distant, for Tony Stark.  If the user has no direct reports, then only the user will
        be returned.
    #>
    Param(
        $ID = $null,
        [switch]$Me,
        [switch]$CallForwarding,
        [switch]$Voicemail,
        [switch]$DefaultPhone,
        [string][ValidateSet("DirectOnly","DirectAndDistant")]$Relationships,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving user information, the maximum value for the -pageSize parameter is 500."
        Write-Warning "Setting the -pageSize parameter from $pageSize to 500."
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortOrder="ASC"
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    if (!$Me) {
        if (!$ID) {
            # Get all users
            $tokenurl = "https://api.$InstanceName/api/v2/users?expand=station%2Cauthorization%2CprofileSkills%2Clocations%2Cgroups%2Cskills%2Clanguages"
            $ID = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            $ID
        }
        else {
            # Get the user based on the $ID entered
            if ($ID.Length -eq 36) {
                $tokenurl = "https://api.$InstanceName/api/v2/users/$($ID)?expand=station%2Cauthorization%2CprofileSkills%2Clocations%2Cgroups%2Cskills%2Clanguages"
                $ID = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
            }
            else {
                $tokenurl = "https://api.$InstanceName/api/v2/users/search"
                $Body = @"
                    {
                        "expand": [
                            "station",
                            "authorization",
                            "profileSkills",
                            "locations",
                            "groups",
                            "skills",
                            "languages"
                        ],
                        "query": [{
                            "value" : "$ID",
                            "fields" : ["name","email","username"],
                            "type" : "CONTAINS"
                        }],
                        "pageSize": $pageSize,
                        "pageNumber": $pageNumber
                    }
"@
                $ID = (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Post).results
            }

            # get the user's reports, if any exist and the -Relationship parameter is set
            switch ($Relationships) {
                "DirectOnly" {
                    $reports = $ID
                    $tokenurl = "https://api.$InstanceName/api/v2/users/$($ID.id)/directreports"
                    $reports += Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
                    foreach ($report in $reports) { $report }
                }
                "DirectAndDistant" {
                    $ID
                    $tokenurl = "https://api.$InstanceName/api/v2/users/$($ID.id)/directreports"
                    $reports += Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
                    foreach ($report1 in $reports) {
                        $report1
                        $tokenurl = "https://api.$InstanceName/api/v2/users/$($report1.id)/directreports"
                        $reports2 = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
                        foreach ($report2 in $reports2) {
                            $report2
                            $tokenurl = "https://api.$InstanceName/api/v2/users/$($report2.id)/directreports"
                            $reports3 = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
                            foreach ($report3 in $reports3) {
                                $report3
                                $tokenurl = "https://api.$InstanceName/api/v2/users/$($report3.id)/directreports"
                                $reports4 = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
                                foreach ($report4 in $reports4) {
                                    $report4
                                    $tokenurl = "https://api.$InstanceName/api/v2/users/$($report4.id)/directreports"
                                    $reports5 = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
                                    foreach ($report5 in $reports5) {
                                        $report5
                                        $tokenurl = "https://api.$InstanceName/api/v2/users/$($report5.id)/directreports"
                                        $reports6 = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
                                        foreach ($report6 in $reports6) {
                                            $report6
                                            $tokenurl = "https://api.$InstanceName/api/v2/users/$($report6.id)/directreports"
                                            $reports7 = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
                                            foreach ($report7 in $reports7) {
                                                $report7
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                default {
                    $ID
                }
            }
        }
    }
    else {
        # Get me (current user's info)
        $tokenurl = "https://api.$InstanceName/api/v2/users/me?expand=station%2Cauthorization%2CprofileSkills%2Clocations%2Cgroups%2Cskills%2Clanguages"
        $ID = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
        $ID
    }

    if ($CallForwarding) {
        # Get the call-forwarding info
        if ($ID.count -gt 1) {
            Write-Warning "Call-forwarding info for multiple users is unavailable.  Please refine your search to get Call-Forwarding info"
        }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/users/"+$ID.id+"/callforwarding"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
        }
    }

    if ($Voicemail) {
        # Get the voicemail info
        if ($ID.count -gt 1) {
            Write-Warning "Voicemail Policy info for multiple users is unavailable.  Please refine your search to get Voicemail info"
        }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/voicemail/userpolicies/"+$ID.id
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
        }
    }

    if ($DefaultPhone) {
        # Get the user's default phone
        if (($ID.count -gt 1) -or (($ID.entities).Count -gt 1)) {
            Write-Warning "Default Phone for multiple users is unavailable.  Please refine your search to get Default Phone info"
        }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phones?lines.defaultForUser.id="+$ID.id
            $Phone = (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get).entities
            if ($Phone) { $Phone }
            else { Write-Output "There was no Default Phone found for : $($ID.name)" }
        }
    }
}


##### Get user profile info based on user's userId
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudUserProfile {

    Param(
        $ID = $null,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    if (!$ID) {
        # ID not entered
        Write-Error "A valid ID was not entered.  Please try the command again uing a valid GUID with the -ID parameter."
    }
    else {
        # Get the user profile based on the $ID entered
        if ([guid]$ID) {
            $tokenurl = "https://api.$InstanceName/api/v2/users/$ID/profile?fl=*"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
        }
        else {
            # ID not entered appropriately
            Write-Error "A valid ID was not entered.  Please try the command again uing a valid GUID with the -ID parameter."
        }
    }
}


##### Get user's utilization settings
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudUtilization {
    <#
    .SYNOPSIS
        Get-GenesysCloudUtilization is used to return a user's utilization configuration
        settings
    .DESCRIPTION
        Get-GenesysCloudUtilization is used to return a user's utilization configuration
        settings
    .PARAMETER userId
        The userId parameter is a string type and should be the user's userId or blank
        to return the org utilization settings
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.com.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    Param(
        [string]$userId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the user utilization info
    if ($userId) {
        $tokenurl = "https://api.$InstanceName/api/v2/routing/users/$($userId)/utilization"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
    }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/routing/utilization"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
    }
}


##### Update user's utilization settings
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Set-GenesysCloudUtilization {
    <#
    .SYNOPSIS
        Set-GenesysCloudUtilization is used to update a user's utilization configuration
        settings
    .DESCRIPTION
        Set-GenesysCloudUtilization is used to update a user's utilization configuration
        settings
    .PARAMETER userId
        The userId parameter is a string type and should be the user's userId
    .PARAMETER utilization
        (object, required): Map of media type to utilization settings. Valid media types
        include call, callback, chat, email, and message.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.com.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory)][string]$userId,
        [parameter(Mandatory)][object]$utilization,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    $Body = $utilization | ConvertTo-Json -Depth 20

    # set the user utilization info
    $tokenurl = "https://api.$InstanceName/api/v2/routing/users/$($userId)/utilization"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method PUT
}


##### Set user info based on user's display name, email address, login ID, or userId
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Set-GenesysCloudUser {
<#
.SYNOPSIS
    Set-GenesysCloudUser is used to update a user object
.DESCRIPTION
    Set-GenesysCloudUser is used to update a user object

    This can be used to update a user's Name, Phone Number, Contact Address, Login
    name, Email Address, Title, and a handful of other things.
.PARAMETER ID
    The ID parameter is a string type, and must be a valid ID object for user.  See
    Get-GenesysCloudUser for a list of valid ID object types.
.PARAMETER InstanceName
    The InstanceName parameter is a string type, and is the name of the GenesysCloud
    environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
.PARAMETER AccessToken
    The AccessToken parameter is a string type, and will be automatically acquired
    if the function detects that it is missing.  This can also be manually acquired
    and saved to a custom variable, then passed into the AccessToken parameter
.PARAMETER Name
    The Name parameter is used to set the user's display name.
.PARAMETER Email
    The Email parameter is used to set the user's email address.  The format of this
    parameter should be a valid email address
.PARAMETER LoginName
    The LoginName paramter is used to set the user's login name.  This usually
    matches the Email address, but can be different.  The format of this paramter
    should be a valid email address.
.PARAMETER CallForwardingStatus
    The CallForwardingStatus paramter is used to define whether or not the call
    forwarding should be enabled or disabled.  If set to "Enable", a call forwarding
    number must be passed to the CallForwardingNumber parameter.  If set to "Disable",
    the call forwarding options will be disabled on the user account.  If unset, the
    call forwarding settings will remain unchanged.
.PARAMETER CallForwardingNumber
    The CallForwardingNumber parameter is used to define the phone number to which
    calls should be forwarded.  This is required to be defined if enabling the call
    forwarding option using the CallForwardingStatus parameter.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)]$ID,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [string]$Name,
        [string]$Email,
        [string]$LoginName,
        [ValidateSet("Enable","Disable")][string]$CallForwardingStatus,
        [string]$CallForwardingNumber
    )

    # Check to see if an access token has been acquired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

    $User = Get-GenesysCloudUser -ID $ID -InstanceName $InstanceName -Accesstoken $Accesstoken
    $changeCount = 0

    if (!$User) {
        Write-Error "There was a problem setting the user info for userId : $ID"
    }
    else {
        $Body = $null
        if ($Name) {
            $Body += @{name=$Name}
            $changeCount ++
        }
        if ($Email) {
            $Body += @{email=$Email}
            $changeCount ++
        }
        if ($LoginName) {
            $Body +=@{username=$LoginName}
            $changeCount ++
        }
        if ($Body) {
            $Body += @{version=$User.version}
            $Body = $Body | ConvertTo-Json -Depth 10
        }

        $Headers = @{
            authorization = "Bearer "+$Accesstoken
            "Content-Type" = "application/json; charset=UTF-8"
        }

        # Set the user's info
        if ($changeCount -ge 1) {
            $tokenurl = "https://api.$InstanceName/api/v2/users/$($User.id)"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Patch
        }

        # Set the user's call forwarding
        if ($CallForwardingStatus -eq "Enable") {
            if ($CallForwardingNumber) {
                $Body = @{
                    enabled=$True
                    phoneNumber=$CallForwardingNumber
                    }
                $Body = $Body | ConvertTo-Json -Depth 10
                $tokenurl = "https://api.$InstanceName/api/v2/users/$($User.id)/callforwarding"
                Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Put
                }
            else {
                Write-Error "To set a user's call forwarding, a phone number must be provided using the -CallForwardingNumber parameter"
            }
        }
        if ($CallForwardingStatus -eq "Disable") {
            $Body = @{enabled=$false}
            $Body = $Body | ConvertTo-Json -Depth 10
            $tokenurl = "https://api.$InstanceName/api/v2/users/$($User.id)/callforwarding"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Put
        }
    }
}


##### Get phone based on phone object Id or by line name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudPhone {
<#
.SYNOPSIS
    Get-GenesysCloudPhone is used to return a phone object or list of phone objects
.DESCRIPTION
    Get-GenesysCloudPhone is used to return a phone object or list of phone objects

    This can be used to search for a specific phone by the phone's GenesysCloud phoneId
    or name.  This can also be used to search for all phones or a set of phones
    matching the ID search string.

    GenesysCloud will be searched for a phone object (or multiple phone objects) based on
    what is typed for the ID parameter.

    The ID parameter can be the phone's phoneId or the phone's name.
.PARAMETER ID
    The ID parameter is a string type, and can be the phone's phoneId or the
    phone's name.
.PARAMETER InstanceName
    The InstanceName parameter is a string type, and is the name of the GenesysCloud
    environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
.PARAMETER AccessToken
    The AccessToken parameter is a string type, and will be automatically acquired
    if the function detects that it is missing.  This can also be manually acquired
    and saved to a custom variable, then passed into the AccessToken parameter
.PARAMETER pageSize
    The pageSize parameter is an integer type, and is used to determine how many API
    objects are returned from the API request.  The default is 25
.PARAMETER pageNumber
    The pageNumber parameter is an integer type, and is used to determine what page of
    data is returned from the API request.  The default is 1
.PARAMETER WebRTC
    The WebRTC parameter is a switch type, and is used to flag the API request to
    only display WebRTC phone types.

    You can pass a user object ID in the -ID parameter with the WebRTC parameter to
    search for a user's specific WebRTC phone
.PARAMETER DefaultPhoneUserID
    The DefaultPhoneUserID parameter is a string type, and is used to flag the API
    request to search for the default phone for the matching userId
.PARAMETER phoneBaseSettingsID
    The phoneBaseSettingsID parameter is a string type, and is used to flag the API
    request search for all phones matching the base settings object ID.
.EXAMPLE
    Get-GenesysCloudPhone -ID "JohnWayneIP335"
    The above example shows how to get the phone object JohnWayneIP335 using it's
    GenesysCloud display name.
.EXAMPLE
    Get-GenesysCloudPhone -ID "12a34b56-c78d-e90f-f09e-d87c65b43a21"
    The above example shows how to get the phone object using it's GenesysCloud object
    ID.
.EXAMPLE
    Get-GenesysCloudPhone -WebRTC
    The above example shows how to get all WebRTC phone objects.
.EXAMPLE
    Get-GenesysCloudPhone -ID "12a34b56-c78d-e90f-f09e-d87c65b43a21" -WebRTC
    The above example shows how to get the WebRTC phone that is assigned to the user
    ID 12a34b56-c78d-e90f-f09e-d87c65b43a21.
.EXAMPLE
    Get-GenesysCloudPhone -phoneBaseSettingsID "12a34b56-c78d-e90f-f09e-d87c65b43a21"
    The above example shows how to get all phone objects matching the phone base
    setting ID of 12a34b56-c78d-e90f-f09e-d87c65b43a21.
#>
    Param(
        $ID = $null,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1,
        [switch]$WebRTC,
        [string]$hardwareAddress,
        [string]$DefaultPhoneUserID,
        [string]$phoneBaseSettingsID
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

    # Check to see if the pageSize parameter exceeds a value of 100
    if ($pageSize -gt 100) {
        Write-Warning "When retreiving phone information, the maximum value for the pageSize parameter is 100."
        Write-Warning "Setting the pageSize parameter from $pageSize to 100."
        $pageSize = 100
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
        sortOrder="ASC"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the phone info
    if (!$phoneBaseSettingsID) {
        if (!$DefaultPhoneUserID) {
            if (!$WebRTC) {
                if (!$hardwareAddress) {
                    if (!$ID) {
                        #good
                        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phones?expand=status,phonebasesettings"
                        $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
                    }
                    else {
                        #good
                        try {
                            [guid]$ID | Out-Null
                            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phones/$ID"
                            $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Method Get
                        }
                        #good
                        catch {
                            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phones?lines.name=*$ID*"
                            $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Method Get -Body $Body
                        }
                    }
                }
                else {
                    #good
                    if ($ID) {
                        Write-Warning -Message "The ID parameter was defined, but will be ignored: hardwareAddress parameter takes precedence."
                    }
                    $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phones?phone_hardwareId=$hardwareAddress"
                    $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Method Get -Body $Body
                }
            }
            else {
                #good
                try {
                    [guid]$ID | Out-Null
                    $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phones?webRtcUser.id=$ID"
                    $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Method Get
                }
                #good
                catch {
                    $phoneBaseSettingsID = (Get-GenesysCloudPhoneBase -baseId "*WebRTC*" -InstanceName $InstanceName -Accesstoken $Accesstoken).id
                    if ($phoneBaseSettingsID.count -eq 1) {
                        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phones?phoneBaseSettings.id="+$phoneBaseSettingsID+"&fields=webRtcUser"
                        $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
                    }
                    else {
                        Write-Error -Message "A valid WebRTC phone base settings object was not found" -RecommendedAction "Run the command again and ensure that a valid WebRTC phone base exists in the org." -ErrorAction Stop
                    }
                }
            }
        }
        else {
            try {
                [guid]$DefaultPhoneUserID | Out-Null
                $ID = Get-GenesysCloudUser -InstanceName $InstanceName -Accesstoken $Accesstoken -ID $DefaultPhoneUserID
                $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phones?lines.defaultForUser.id="+$ID.id
                $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Method Get
                try {
                    ($response.Content | ConvertFrom-Json).entities.Count -GT 0 | Out-Null
                }
                catch {
                    Write-Error -Message "There was no Default Phone found for : $($ID.name)" -ErrorAction Stop
                }
            }
            catch {
                Write-Error "The DefaultPhoneUserID parameter requires the user's valid GenesysCloud userId GUID." -RecommendedAction "Please try again with a valid user's GUID using : Get-GenesysCloudPhone -DefaultPhoneUserID <GenesysCloud_userId>" -ErrorAction Stop
            }
        }
    }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phones?phoneBaseSettings.id=$phoneBaseSettingsID"
        $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
    }
    Set-Variable -Name responseHeaders -Value $response.Headers -Scope Global
    $response.Content | ConvertFrom-Json
}


##### create new phone
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudPhone {
    <#
    .SYNOPSIS
        New-GenesysCloudPhone is used to create a new phone object
    .DESCRIPTION
        New-GenesysCloudPhone is used to create a new phone object
    .PARAMETER name
        (string, required): The name of the entity.
    .PARAMETER description
        (string, optional): The resource's description.
    .PARAMETER version
        (integer, optional): The current version of the resource.
    .PARAMETER siteId
        (string, required): The site ID associated to the phone.
    .PARAMETER phoneBaseSettingsId
        (string, required): Phone Base Settings ID
    .PARAMETER lineBaseSettingsId
        (string, optional): Line Base Settings ID
    .PARAMETER phoneMetaBaseId
        (string, optional): Phone Metabase ID
    .PARAMETER lineNames
        (array, required): Line names
    .PARAMETER phoneHardwareId
        (string, required): Hardware ID or MAC of the phone
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .EXAMPLE
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(mandatory)][string]$name,
        [string]$description,
        [int]$version,
        [parameter(mandatory)][string]$siteId,
        [parameter(mandatory)][string]$phoneBaseSettingsId,
        [string]$lineBaseSettingsId,
        [string]$phoneMetaBaseId,
        [parameter(mandatory)][array]$lineNames,
        [parameter(mandatory)][string]$phoneHardwareId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [switch]$debugBody
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization  = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    $Body = @{
        name = $name
        description = $description
        version = $version
        site = @{
            id = $siteId
        }
        phoneBaseSettings = @{
            id = $phoneBaseSettingsId
        }
        lineBaseSettings = @{
            id = $lineBaseSettingsId
        }
        phoneMetaBase = @{
            id = $phoneMetaBaseId
        }
        lines = @(
            $lineNames | ForEach-Object {
                @{
                    name = $_
                    properties = @{
                        station_lineLabel = @{
                            value = @{
                                instance = $_
                            }
                        }
                        station_lineKeyPosition = @{
                            value = @{
                                instance = 0
                            }
                        }
                    }
                    template = @{
                        id = $lineBaseSettingsId
                    }
                    site = @{
                        id = $siteId
                    }
                    lineBaseSettings = @{
                        id = $lineBaseSettingsId
                    }
                }
            }
        )
        properties = @{
            phone_hardwareId = @{
                value = @{
                    instance = $phoneHardwareId
                }
            }
        }
    }

    try {
        if ($debugBody) {
            $Body
        }
        else {
            $Body = $Body | ConvertTo-Json -Depth 20
            $tokenurl = "https://api.$($InstanceName)/api/v2/telephony/providers/edges/phones"
            $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method Post -ErrorAction Stop
            Set-Variable -Name responseHeaders -Value $response.Headers -Scope Global
            $response.Content | ConvertFrom-Json
        }
    }
    catch {
        Write-Error -Message "There was an error creating the new phone: $($Error[0])"
    }
}


##### Get phone based on phone object Id or by line name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Set-GenesysCloudPhone {
    <#
    .SYNOPSIS
        Set-GenesysCloudPhone is used to modify a phone object
    .DESCRIPTION
        Set-GenesysCloudPhone is used to modify a phone object
    .PARAMETER ID
        The ID parameter is a string type, and must be the phone's object ID
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER newName
        The newName parameter is a string type, and is used to flag the API request to
        rename the phone object to the passed string
    .EXAMPLE
        Set-GenesysCloudPhone -ID "12a34b56-c78d-e90f-f09e-d87c65b43a21" -newName "JohnWayneRemote"
        The above example shows how to rename a phone object to JohnWayneRemote
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        $ID = $null,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [string]$newName
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

    $Headers = @{
        authorization  = "Bearer " + $Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the phone info
    $attrCount = 0
    $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phones/$($ID)"

    try {
        $phoneObject = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
        if ($phoneObject.count -le 1) {
            if ($newName) {
                $attrCount = 1
                $phoneObject.name = $newName
            }
        }
    }
    catch {
        Write-Error -Message "There was an error finding the phone object.  Please verify that you provided a valid phone object ID : $($ID)"
    }
    if ($attrCount -ge 1) {
        try {
            $Body = $phoneObject | ConvertTo-Json -Depth 30
            $req = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Put -Body $Body
        }
        catch {
            Write-Error -Message "There was an error updating the phone object.  Last error: $($req)"
        }
    }
    else {
        Write-Warning -Message "No attributes were changed on the phone object"
    }
}


##### Get phone based on phone object Id or by line name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudStation {
Param(
    $ID = $null,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [int]$pageSize = 25,
    [int]$pageNumber = 1
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

# Check to see if the pageSize parameter exceeds a value of 100
if ($pageSize -gt 500) {
    Write-Warning "When retreiving station information, the maximum value for the pageSize parameter is 500. Setting the pageSize parameter from $pageSize to 500."
    $pageSize = 500
    }

$Body = @{
    pageSize=$pageSize
    pageNumber=$pageNumber
    sortOrder="ASC"
    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

# Get the phone info
if (!$ID) {
    $tokenurl = "https://api.$InstanceName/api/v2/stations"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
    }
else {
    if ($ID.Length -eq 36) {
        $tokenurl = "https://api.$InstanceName/api/v2/stations/$ID"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
        }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/stations?name=$ID"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get).entities
        }
    }
}


##### get a list of roles #####
function Get-GenesysCloudRole {
    Param(
        $RoleID = $null,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1,
        [switch]$Users
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving role information, the maximum value for the pageSize parameter is 500.  Setting the pageSize parameter from $pageSize to 500."
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortOrder="ASC"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the Role info
    if (!$RoleID) {
        $tokenurl = "https://api.$InstanceName/api/v2/authorization/roles"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get)
    }
    else {
        if ($RoleID.Length -eq 36) {
            if ($Users) {
                $tokenurl = "https://api.$InstanceName/api/v2/authorization/roles/$RoleID/users"
                Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get -Body $Body
            }
            else {
                $tokenurl = "https://api.$InstanceName/api/v2/authorization/roles/$RoleID"
                Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
            }
        }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/authorization/roles?name=$($RoleId)"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
    }
}


##### Create a new role by passing name and description
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudRole {
    <#
    .SYNOPSIS
        New-GenesysCloudRole creates a new GenesysCloud role
    .DESCRIPTION
        New-GenesysCloudRole creates a new GenesysCloud role and optionally assigns permissions
        to the new role
    .PARAMETER roleName
        The roleName parameter is a string type and is required.  It should be the
        name of the new role
    .PARAMETER roleDescription
        The roleDescription parameter is a string type and is optional.  It should
        be the description of the new role
    .PARAMETER rolePermissions
        The rolePermissions parameter is an array type and is optional.  It should
        be an array of permissions to assign to the new role
    .PARAMETER rolePermissionPolicies
        The rolePermissionPolicies parameter is an object type and is optional.  It
        should be an object containing the permission policies to assign to the new role
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .EXAMPLE
        New-GenesysCloudRole -roleName "Ninja Students"
        The above example shows how to create a new role with the name of Ninja Students
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)]$roleName,
        [string]$roleDescription,
        [array]$rolePermissions,
        [object]$rolePermissionPolicies,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Create the new role
    $Body = @{
        name = $roleName
    }
    if ($roleDescription) {$Body.Add("description",$roleDescription)}
    if ($rolePermissions) {$Body.Add("permissions",@($rolePermissions))}
    if ($rolePermissionPolicies) {$Body.Add("permissionPolicies",@($rolePermissionPolicies))}
    $Body = $Body | ConvertTo-Json -Depth 20

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    $tokenurl = "https://api.$InstanceName/api/v2/authorization/roles"

    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Post
}


##### Update a GenesysCloud role
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Set-GenesysCloudRole {
    <#
    .SYNOPSIS
        Set-GenesysCloudRole updates a GenesysCloud role
    .DESCRIPTION
        Set-GenesysCloudRole updates a GenesysCloud role based on a modified role object
    .PARAMETER roleId
        The roleId parameter is a string type and is required.  It should be the
        object ID of the role to be updated
    .PARAMETER roleObject
        The roleObject parameter is an object type and is required.  It should be
        the role object with the updated or modified properties that are to be
        updated.
        A role object can be retreived by using the Get-GenesysCloudRole command.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .EXAMPLE
        $modifiedRoleObject = Get-GenesysCloudRole "04c04115-1bed-4d32-b213-75fb6803c2a9"

        $modifiedRoleObject.permissions = "user_manager","unified_communications",
        "group_administration"

        Set-GenesysCloudRole -roleId  "04c04115-1bed-4d32-b213-75fb6803c2a9" -roleObject
        $modifiedRoleObject

        The above example shows how to set the permissions of a role with the object ID
        of 04c04115-1bed-4d32-b213-75fb6803c2a9 using an updated role object.

        The role opbect is retreived using the Get-GenesysCloudRole command, and then
        the permissions are added to the object.

        The updated object is then passed to the -roleObject parameter to save the new
        permissions to the role.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)]$roleId,
        [Parameter(Mandatory=$True)]$roleObject,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # update the role
    $roleObject.PSObject.Properties.Remove("id")
    $roleObject.PSObject.Properties.Remove("selfUri")
    $roleObject.PSObject.Properties.Remove("userCount")
    $Body = $roleObject | ConvertTo-Json -Depth 30

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    $tokenurl = "https://api.$InstanceName/api/v2/authorization/roles/$roleId"

    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Put
}


##### Add new member object to a division
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudRoleMember {
    <#
    .SYNOPSIS
        Get-GenesysCloudRoleMember gets the divisions for which the subject has a grant
    .DESCRIPTION
        Get-GenesysCloudRoleMember gets the divisions for which the subject has a grant
    .PARAMETER roleId
        (string, required): The division ID
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]Param(
        [Parameter(Mandatory=$True)][string]$roleId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    $Body = @{
        pageSize = $pageSize
        pageNumber = $pageNumber
    }

    $tokenurl = "https://api.$InstanceName/api/v2/authorization/roles/$($roleId)/subjectgrants"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET
}


##### Add new member object to a division
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Add-GenesysCloudRoleMember {
    <#
    .SYNOPSIS
        Add-GenesysCloudRoleMember assigns a new member object to a role
    .DESCRIPTION
        Add-GenesysCloudRoleMember assigns a new member object to a role
    .PARAMETER roleId
        (string, required): The division ID to add members to
    .PARAMETER memberType
        (string, required): what the type of the subjects are (PC_GROUP, PC_USER
        or PC_OAUTH_CLIENT)
    .PARAMETER memberIds
        (array, required): An array of object IDs to be added to the role
    .PARAMETER divisionIds
        (array, required): An array of division IDs to be added to the respective
        subject's role
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]Param(
        [Parameter(Mandatory=$True)][string]$roleId,
        [Parameter(Mandatory=$True)][string][ValidateSet("PC_GROUP","PC_USER","PC_OAUTH_CLIENT")]$memberType,
        [Parameter(Mandatory=$True)][array]$memberIds,
        [Parameter(Mandatory=$True)][array]$divisionIds,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [switch]$debugBody
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    for ($i = 0; $i -lt $memberIds.count; $i += 100) {
        $memberIdChunks += ,@($memberIds[$i..($i + 99)]);
    }

    # iterate through chunks
    for ($i = 0; $i -lt $memberIdChunks.count; $i ++) {
        # build the request body
        $Body = @{
            subjectIds = @($memberIdChunks[$i])
            divisionIds = @($divisionIds)
        }

        # send the request
        if ($debugBody) {
            $Body
        }
        else {
            $Body = $Body | ConvertTo-Json -Depth 20
            $tokenurl = "https://api.$InstanceName/api/v2/authorization/roles/$($roleId)?subjectType=$($memberType)"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Post
        }

        # increment group version
        $version ++
        Start-Sleep -Seconds 1
    }
}


##### add a user to a role #####
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Add-GenesysCloudUserToRole {
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$RoleID,
        [Parameter(Mandatory=$True)][array]$UserIDs,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    $tokenurl = "https://api.$InstanceName/api/v2/authorization/roles/$RoleID/users/add"

    # Add the user to the Role
    $Body = $UserIDs | ConvertTo-Json -AsArray
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Put -Body $Body
}


##### remove a user from a role
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Remove-GenesysCloudUserFromRole {
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)]$RoleID,
        [Parameter(Mandatory=$True)]$UserID,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    $tokenurl = "https://api.$InstanceName/api/v2/authorization/roles/$RoleID/users/remove"

    # remove the user to the Role
    if ($RoleID.Length -ge 36) {
        $Body = @()
        foreach ($GUID in $UserID) {
            $Body = @"
            [
                "$GUID"
            ]
"@
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Put -Body $Body
        }
    }
    else {
        Write-Error -Message "The RoleID parameter requires that you pass the GenesysCloud Role id." -RecommendedAction "Please try again using : Remove-GenesysCloudUserFromRole -RoleID <GenesysCloud_roleId> -UserID <GenesysCloud_userId>"
    }
}


##### Get Location based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudLocation {
    Param(
        $ID = $null,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        $pageSize = 500,
        $pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Body = @{
        pageSize = $pageSize
        pageNumber = $pageNumber
        sortOrder = "ASC"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the location info
    if (!$ID) {
        $tokenurl = "https://api.$InstanceName/api/v2/locations"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
    }
    else {
        if ($ID.Replace(" ","").Length -eq 36) {
            $tokenurl = "https://api.$InstanceName/api/v2/locations/$($ID)?expand=images%2CaddressVerificationDetails"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
        }
        else {
            $Body = @{
                query = @(
                    @{
                        value = $ID
                        fields = @(
                            "name"
                            "id"
                        )
                        type = "CONTAINS"
                    }
                )
            } | ConvertTo-Json -Depth 20
            $tokenurl = "https://api.$InstanceName/api/v2/locations/search"
            (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Post).results
        }
    }
}


##### Create new GenesysCloud Location
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudLocation {
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)]$locationName,
        $locationParent,
        $locationNotes,
        $contactUser,
        $emergencyNumber,
        $addressCity,
        $addressCountry,
        $addressCountryName,
        $addressState,
        $addressStreet1,
        $addressStreet2,
        $addressZip,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    $Body = @{name = $locationName}
    if ($locationParent) {$Body.Add("path", @($locationParent))}
    if ($locationNotes) {$Body.Add("notes", $locationNotes)}
    if ($contactUser) {$Body.Add("contactUser", $contactUser)}
    if ($emergencyNumber) {$Body.Add("emergencyNumber", @{e164 = $emergencyNumber})}
    if ($addressCity -or $addressCountry -or $addressCountryName -or $addressState -or $addressStreet1 -or $addressZip) {
        $Body.Add("address", @{
            city = $addressCity
            country = $addressCountry
            countryName = $addressCountryName
            state = $addressState
            street1 = $addressStreet1
            zipcode = $addressZip
        })
    }
    if ($addressStreet2) {$Body.address.Add("street2",$addressStreet2)}

    $Body = $Body | ConvertTo-Json -Depth 20
    $Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $tokenurl = "https://api.$InstanceName/api/v2/locations"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST

}


##### Update an existing GenesysCloud Location
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Set-GenesysCloudLocation {
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$locationId,
        [string]$locationName,
        [Parameter(Mandatory=$True)][int]$version,
        $locationParent,
        $locationNotes,
        $contactUser,
        $emergencyNumber,
        $addressCity,
        $addressCountry,
        $addressCountryName,
        $addressState,
        $addressStreet1,
        $addressStreet2,
        $addressZip,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    $Body = @{
        version = $version
    }
    if ($locationName) {$Body.Add("name", @($locationName))}
    if ($locationParent) {$Body.Add("path", @($locationParent))}
    if ($locationNotes) {$Body.Add("notes", $locationNotes)}
    if ($contactUser) {$Body.Add("contactUser", $contactUser)}
    if ($emergencyNumber) {$Body.Add("emergencyNumber", @{
        e164 = $emergencyNumber
        number = $emergencyNumber
        type = "default"
    })}
    if ($addressCity -or $addressCountry -or $addressCountryName -or $addressState -or $addressStreet1 -or $addressZip) {
        $Body.Add("address", @{
            city = $addressCity
            country = $addressCountry
            countryName = $addressCountryName
            state = $addressState
            street1 = $addressStreet1
            zipcode = $addressZip
        })
    }
    if ($addressStreet2) {$Body.address.Add("street2",$addressStreet2)}

    # Update the location
    $Body = $Body | ConvertTo-Json -Depth 20

    $tokenurl = "https://api.$InstanceName/api/v2/locations/$($locationId)"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method PATCH

}


##### Get DID or DID List based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudDID {
<#
.SYNOPSIS
    Get-GenesysCloudDID is used to retreive a DID phone number object or a DID
    phone number pool object
.DESCRIPTION
    Get-GenesysCloudDID is used to retreive a DID phone number object or a DID
    phone number pool object
.PARAMETER ID
    The ID parameter is a string type and is optional.  If defined, it should be
    the DID phone number object ID, the DID phone number E.164 formatted number, or
    the DID pool object ID
.PARAMETER InstanceName
    The InstanceName parameter is a string type, and is the name of the GenesysCloud
    environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
.PARAMETER AccessToken
    The AccessToken parameter is a string type, and will be automatically acquired
    if the function detects that it is missing.  This can also be manually acquired
    and saved to a custom variable, then passed into the AccessToken parameter
.PARAMETER Pool
    The Pool parameter is a switch type, and is used to flag the API request to
    search for DID pools
.EXAMPLE
    Get-GenesysCloudDID -ID "12a34b56-c78d-e90f-f09e-d87c65b43a21"
    The above example shows how to retreive a DID phone number with an objectID of
    12a34b56-c78d-e90f-f09e-d87c65b43a21
.EXAMPLE
    Get-GenesysCloudDID -ID +13172222222
    The above example shows how to retreive a DID phone number with the phoneNumber
    attribute set to the E.164 formatted number of +13172222222
#>
Param(
    $ID = $null,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [int]$pageSize = 25,
    [int]$pageNumber = 1,
    [switch]$Pool
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

# Check to see if the pageSize parameter exceeds a value of 100
if ($pageSize -gt 100) {
    Write-Warning "When retreiving DID information, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
    $pageSize = 100
    }

$Body = @{
    pageSize=$pageSize
    pageNumber=$pageNumber
    sortOrder="ASC"
    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

if ($Pool) {
    # Get the DID Pool info
    if (!$ID) {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/didpools"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
    else {
        if ($ID.Length -eq 36) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/didpools/$ID"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
        else {
            Write-Warning "Getting a DID pool requires the DID pool's objectId. Please refine your query to a specific DID Pool id."
            }
        }
    }
else {
    if (!$ID) {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/dids"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
    else {
        if ($ID.Length -eq 36) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/dids/$ID"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
        elseif ($ID -like "+*") {
            $idUri = [uri]::EscapeDataString($ID)
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/dids?phoneNumber=$idUri"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
        else {
            Write-Warning "Getting a DID requires either the DID's objectId or the full E.164 formatted number. Please refine your query to a specific DID id or E.164 number."
            }
        }
    }
}


##### Create a new DID pool
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudDIDPool {
    <#
    .SYNOPSIS
        New-GenesysCloudDIDPool is used to create a DID phone number pool
    .DESCRIPTION
        New-GenesysCloudDIDPool is used to create a DID phone number pool
    .PARAMETER name
        (string, required): The name of the entity.
    .PARAMETER description
        (string, optional): The resource's description.
    .PARAMETER startPhoneNumber
        (string, required): The starting phone number for the range of this DID pool.
        Must be in E.164 format
    .PARAMETER endPhoneNumber
        (string, required): The ending phone number for the range of this DID pool.
        Must be in E.164 format
    .PARAMETER comments
        (string, optional): comments about the DID pool
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .EXAMPLE
        New-GenesysCloudDIDPool -name "Karate Class DIDs" -description "DIDs used for the
        karate class" -startPhoneNumber "+17088591210" -endPhoneNumber "+17088591219"

        The above example shows how to create a DID phone number pool for the Karate
        Class
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory=$true)][string]$name,
        [string]$description,
        [parameter(Mandatory=$true)][string]$startPhoneNumber,
        [parameter(Mandatory=$true)][string]$endPhoneNumber,
        [string]$comments,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+ $Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    $Body = @{
        name = $name
        startPhoneNumber = $startPhoneNumber
        endPhoneNumber = $endPhoneNumber
    }
    if ($description) {$Body.Add("description",$description)}
    if ($comments) {$Body.Add("comments",$comments)}
    $Body = $Body | ConvertTo-Json -Depth 20

    $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/didpools"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
}


##### Create a new extension pool
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudExtensionPool {
    <#
    .SYNOPSIS
        New-GenesysCloudExtensionPool is used to create a phone number extension pool
    .DESCRIPTION
        New-GenesysCloudExtensionPool is used to create a phone number extension pool
    .PARAMETER name
        (string, required): The name of the entity.
    .PARAMETER description
        (string, optional): The resource's description.
    .PARAMETER startNumber
        (string, required): The starting phone number for the range of this DID pool.
        Must be in E.164 format
    .PARAMETER endNumber
        (string, required): The ending phone number for the range of this DID pool.
        Must be in E.164 format
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .EXAMPLE
        New-GenesysCloudExtensionPool -name "Sumo Student Extensions" -description "Used
        for the Sumo Class" -startNumber "591210" -endNumber "591219"

        The above example shows how to create a phone number extension pool for the
        Sumo Students
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory=$true)][string]$name,
        [string]$description,
        [parameter(Mandatory=$true)][string]$startNumber,
        [parameter(Mandatory=$true)][string]$endNumber,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    $Body = @{
        name = $name
        description = if ($description) {$description} else {""}
        startNumber = $startNumber
        endNumber = $endNumber
    } | ConvertTo-Json -Depth 20

    $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/extensionpools"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
}


##### Get group based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudGroup {
    <#
    .SYNOPSIS
        Get-GenesysCloudGroup is used to retreive agroup
    .DESCRIPTION
        Get-GenesysCloudGroup is used to retreive agroup
    .PARAMETER ID
        The ID parameter is a string type and is optional.  If defined, it should be
        the group object ID or the group name
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER Members
        The Members parameter is a switch type, and is used to flag the API request to
        return the members of the group
    #>
    Param(
        [string]$ID,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1,
        [switch]$Members
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving group information, the maximum value for the pageSize parameter is 500. Setting the pageSize parameter from $pageSize to 500."
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the group info
    if (!$Members) {
        if (!$ID) {
            $tokenurl = "https://api.$InstanceName/api/v2/groups"
            $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
        else {
            try {
                [guid]$ID | Out-Null
                $tokenurl = "https://api.$InstanceName/api/v2/groups/$ID"
                $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Method Get
            }
            catch {
                if ($pageSize -gt 100) {
                    Write-Warning "When searching for groups by name, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
                    $pageSize = 100
                }
                $Body = @{
                    pageSize = $pageSize
                    pageNumber = $pageNumber
                    query = @(@{
                        value = $ID
                        fields = @("name","id")
                        type = "CONTAINS"
                    })
                } | ConvertTo-Json -Depth 20
                $tokenurl = "https://api.$InstanceName/api/v2/groups/search"
                $Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
                $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
            }
        }
    }
    else {
        if (!$ID) {
            Write-Error -Message "The ID parameter was not specified." -RecommendedAction "To retrieve the members of a group, a valid GUID must be specified. Try again and specify a valid group GUID for the -ID parameter" -ErrorAction Stop
        }
        else {
            try {
                [guid]$ID | Out-Null
                $tokenurl = "https://api.$InstanceName/api/v2/groups/$ID/members"
                $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
            catch {
                Write-Error -Message "A valid group GUID was not specified." -RecommendedAction "To retrieve the members of a group, a valid GUID must be specified. Try again and specify a valid group GUID for the -ID parameter" -ErrorAction Stop
            }
        }
    }
    Set-Variable -Name responseHeaders -Value $response.Headers -Scope Global
    $response.Content | ConvertFrom-Json
}


##### Get group based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudGroupProfile {
    <#
    .SYNOPSIS
        Get-GenesysCloudGroupProfile is used to retreive a group profile
    .DESCRIPTION
        Get-GenesysCloudGroupProfile is used to retreive a group profile
    .PARAMETER groupId
        The groupId parameter is a string type and is reguired.  It should be the
        group object ID
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    Param(
        [parameter(Mandatory)][string]$groupId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the group profile info
    $tokenurl = "https://api.$InstanceName/api/v2/groups/$groupId/profile?fields=*"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get

}


##### Update a GenesysCloud group
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Set-GenesysCloudGroup {
    <#
    .SYNOPSIS
        Set-GenesysCloudGroup updates a GenesysCloud group based on a modified group object
    .DESCRIPTION
        Set-GenesysCloudGroup updates a GenesysCloud group based on a modified group object
    .PARAMETER groupId
        The groupId parameter is a string type and is required.  It should be the
        object ID of the group to be updated
    .PARAMETER groupObject
        The groupObject parameter is an object type and is required.  It should be
        the group object with the updated or modified properties that are to be
        updated.
        A group object can be retreived by using the Get-GenesysCloudGroup command.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .EXAMPLE
        $modifiedGroupObject = Get-GenesysCloudGroup "04c04115-1bed-4d32-b213-75fb6803c2a9"

        $modifiedGroupObject.ownerIds += "8bec872a-2e19-4587-9075-c74e91c78a9b"

        Set-GenesysCloudGroup -groupId "04c04115-1bed-4d32-b213-75fb6803c2a9" -groupObject
        $modifiedRoleObject

        The above example shows how to add an owner to a group with the object ID
        of 04c04115-1bed-4d32-b213-75fb6803c2a9 using an updated group object.

        The group object is retreived using the Get-GenesysCloudGroup command, and then
        the new owner is added to the object's ownerIds property.

        The updated object is then passed to the -groupObject parameter to save the new
        owner to the group.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$groupId,
        [Parameter(Mandatory=$True)]$groupObject,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [switch]$debugBody
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # update the group
    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    if ($debugBody) {
        $groupObject
    }
    else {
        $Body = $groupObject | ConvertTo-Json -Depth 30
        $Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $tokenurl = "https://api.$InstanceName/api/v2/groups/$($groupId)"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Put
    }
}


##### create a new GenesysCloud group
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudGroup {
    <#
    .SYNOPSIS
        New-GenesysCloudGroup creates a GenesysCloud group
    .DESCRIPTION
        New-GenesysCloudGroup creates a GenesysCloud group
    .PARAMETER name
        (string, required): The group name.
    .PARAMETER description
        (string, optional): the description of the group
    .PARAMETER type
        (string, required): Type of group. Valid Values: official, social
    .PARAMETER images
        (array, optional): array of objects including image resolution and image uri
    .PARAMETER addresses
        (object, optional): Phone number, phone extension, phone type for the group
    .PARAMETER rulesVisible
        (boolean, required): Are membership rules visible to the person requesting to
        view the group
    .PARAMETER visibility
        (string, required): Who can view this group Valid Values: public, owners, members
    .PARAMETER ownerIds
        (array, optional): Owner IDs of the group
    .PARAMETER copyGroup
        (switch, optional): flag to copy group from source group object
    .PARAMETER sourceGroup
        (object, required if copyGroup defined): source group object to copy
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .EXAMPLE
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [string]$name,
        [string]$description,
        [ValidateSet("official","social")]$type,
        [array]$images,
        [object]$addresses,
        [boolean]$rulesVisible,
        [string][ValidateSet("public","owners","members")]$visibility,
        [array]$ownerIds,
        [switch]$copyGroup,
        $sourceGroup,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [switch]$debugBody
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # create the group
    if ($copyGroup) {
        if ($sourceGroup) {
            $Body = $sourceGroup
        }
        else {
            Write-Error -Message "The sourceGroup was not defined." -RecommendedAction "The sourceGroup parameter must be specified when using the copyGroup switch."
            exit
        }
    }
    else {
        if (!($name) -or !($type) -or !($rulesVisible) -or !($visibility)){
            Write-Error -Message "One or more required parameters (name, type, rulesVisible, or visibility) were not defined." -RecommendedAction "Run the command and define the required parameters: name, type, rulesVisible, and visibility"
            exit
        }
            else {
            $groupObject = @{
                name = $name
                type = $type
                rulesVisible = $rulesVisible
                visibility = $visibility
            }
            if ($description) {$groupObject.Add("description",$description)}
            if ($images) {$groupObject.Add("images",@($images))}
            if ($addresses) {$groupObject.Add("addresses",@($addresses))}
            if ($ownerIds) {$groupObject.Add("ownerIds",@($ownerIds))}
            $Body = $groupObject
        }
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }
    if ($debugBody) {
        $Body
    }
    else {
        $Body = $Body | ConvertTo-Json -Depth 30
        $Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $tokenurl = "https://api.$InstanceName/api/v2/groups"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    }
}


##### Adds a user to a GenesysCloud group based on user and group object Id/name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Add-GenesysCloudGroupMember {
    <#
    .SYNOPSIS
        Add-GenesysCloudGroupMember adds users to a GenesysCloud group as new members
    .DESCRIPTION
        Add-GenesysCloudGroupMember adds users to a GenesysCloud group as new members
    .PARAMETER groupId
        (string, required): The group object ID
    .PARAMETER memberIds
        (array, required): A list of the ids of the members to add.
    .PARAMETER version
        (integer, required): A list of the ids of the members to add.
    .PARAMETER bulkAdd
        The bulkAdd parameter is a switch type, and is intended to be used to flag the
        command to add multiple users to the group specified by the groupId parameter.
        When used, an array of userIds should be passed to the memberId paramter
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER memberIds
        (array, required): A list of the ids of the members to add.
    .PARAMETER bulkAdd
        The bulkAdd parameter is a switch type, and is intended to be used to flag the
        command to add multiple users to the group specified by the groupId parameter.
        When used, an array of userIds should be passed to the memberId paramter
    .EXAMPLE
        Add-GenesysCloudGroupMember -groupId "Martial Arts" -memberId "jackie@kungfu.org"
        The above example shows how to add the user tied to jackie@kunfu.org to the
        Martial Arts GenesysCloud group.
    #>
    Param(
        [parameter(mandatory)][string]$groupId,
        [parameter(mandatory)][array]$memberIds,
        [parameter(mandatory)][int]$version,
        [switch]$bulkAdd,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # setup request headers
    $Headers = @{
        authorization  = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # get member info

    if ($bulkAdd) {
        # split up the list of members into 50 count chunks
        if ($memberIds.Count -gt 50) {
            for ($i = 0; $i -lt $memberIds.count; $i += 50) {
                $memberIdChunks += ,@($memberIds[$i..($i + 49)]);
            }

            # iterate through chunks
            for ($i = 0; $i -lt $memberIdChunks.count; $i ++) {
                # build the request body
                $Body = @{
                    "memberIds" = @($memberIdChunks[$i])
                    "version"   = $version
                } | ConvertTo-Json -Depth 20

                # send the request
                $tokenurl = "https://api.$InstanceName/api/v2/groups/$($groupId)/members"
                Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST

                # increment group version
                $version ++
                Start-Sleep -Seconds 1
            }
        }
        else {
            # build the request body
            $Body = @{
                "memberIds" = @($memberIds)
                "version"   = $version
            } | ConvertTo-Json -Depth 20

            # send the request
            $tokenurl = "https://api.$InstanceName/api/v2/groups/$($groupId)/members"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
        }
    }
    else {
        # build the request body
        $Body = @{
            "memberIds" = @($memberIds)
            "version"   = $version
        } | ConvertTo-Json -Depth 20

        # send the request
        $tokenurl = "https://api.$InstanceName/api/v2/groups/$($groupId)/members"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    }
}


##### Adds a user to a GenesysCloud group based on user and group object Id/name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Remove-GenesysCloudGroupMember {
    <#
    .SYNOPSIS
        Remove-GenesysCloudGroupMember adds users to a GenesysCloud group as new members
    .DESCRIPTION
        Remove-GenesysCloudGroupMember adds users to a GenesysCloud group as new members
    .PARAMETER groupId
        The groupId parameter is a string type and is required.  It should be the
        group name or group object ID
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER memberId
        The memberId parameter is a string type and is required.  It should be the
        user's email address or objet ID.  If removing multiple users, this should be a
        list of user email addresses or user object IDs.
    .EXAMPLE
        Remove-GenesysCloudGroupMember -groupId "Martial Arts" -memberId "jackie@kungfu.org"
        The above example shows how to remove the user tied to jackie@kunfu.org from the
        Martial Arts GenesysCloud group.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [string]$groupId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [string]$memberId
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

    # setup request headers
    $Headers = @{
        authorization  = "Bearer " + $Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the group info
    if (!$groupId) {
        Write-Error "Parameter 'groupId' not specified"
        exit
    }
    else {
        $groupInfo = Get-GenesysCloudGroup $groupId
    }

    # get member info
    if (!$memberId) {
        Write-Error "Parameter 'memberId' not specified"
        exit
    }
    else {
        # get list of  members to remove
        $memberInfo = @()
        foreach ($member in $memberId) {
            $memberInfo += (Get-GenesysCloudUser $member).id
            Start-Sleep -Milliseconds 500
        }

        # send the request
        $tokenurl = "https://api.$InstanceName/api/v2/groups/$($groupInfo.id)/members?ids=$($memberInfo -join ",")"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method DELETE

    }
}


##### Set user based on user's userId attribute
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Set-GenesysCloudUserContact {
<#
.SYNOPSIS
    Set-GenesysCloudUserContact is used to update or configure a user object
.DESCRIPTION
    Set-GenesysCloudUserContact is used to update or configure a user object

    The ID parameter must be the user's userId object attribute.
.PARAMETER ID
    The ID parameter is a string type, and must be the user's userId
.PARAMETER InstanceName
    The InstanceName parameter is a string type, and is the name of the GenesysCloud
    environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
.PARAMETER AccessToken
    The AccessToken parameter is a string type, and will be automatically acquired
    if the function detects that it is missing.  This can also be manually acquired
    and saved to a custom variable, then passed into the AccessToken parameter
#>
[CmdletBinding(SupportsShouldProcess = $true)]
Param(
    [Parameter(Mandatory=$True)]$ID,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [Parameter(Mandatory=$True)][string]$Address,
    [Parameter(Mandatory=$True)][ValidateSet('PHONE','EMAIL','SMS')][string]$Type,
    [Parameter(Mandatory=$True)][ValidateSet('PRIMARY','WORK','WORK2','WORK3','WORK4','HOME','MOBILE','MAIN')][string]$Field
    )

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

$UserInfo = Get-GenesysCloudUser -ID $ID -InstanceName $InstanceName -Accesstoken $Accesstoken
$UpdateVersion = $UserInfo.version ++

$Body = @"
    {
    "addresses": [{
        "address": "$Address",
        "mediaType": "$Type",
        "type": "$Field"
        }],
    "version": "$UpdateVersion"
    }
"@

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

$tokenurl = "https://api.$InstanceName/api/v2/users/$ID"
Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Patch

}


##### Get site based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudSite {
Param(
    $ID = $null,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [int]$pageSize = 25,
    [int]$pageNumber = 1,
    [switch]$NumberPlans,
    [switch]$Rebalance
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

# Check to see if the pageSize parameter exceeds a value of 100
if ($pageSize -gt 100) {
    Write-Warning "When retreiving Location information, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
    $pageSize = 100
    }

$Body = @{
    pageSize=$pageSize
    pageNumber=$pageNumber
    sortBy="name"
    sortOrder="ASC"
    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

# Get the site info
if (!$ID) {
    $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/sites"
    (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
    if ($Rebalance) {
        Write-Warning "To rebalance a site or group of sites, please specify a siteId or siteName and try again."
        }
    if ($NumberPlans) {
        Write-Warning "To get number plans for a site or group of sites, please specify a siteId or siteName and try again."
        }
    }
else {
    if ($ID.Length -eq 36) {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/sites/$ID"
        $Sites = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/sites?name=*$ID*"
        $Sites = (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    foreach ($Site in $Sites) {
        $Site
        $SiteId = $Site.id
        if ($Rebalance) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/sites/$SiteId/rebalance"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Post
            Write-Output "The following site has been rebalanced : $($Site.name)"
            }
        if ($NumberPlans) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/sites/$ID/numberplans"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
        }
    }
}


##### Create a new site
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudSite {
    <#
    .SYNOPSIS
        New-GenesysCloudSite creates a new site
    .DESCRIPTION
        New-GenesysCloudSite creates a new site
    .PARAMETER siteName
        (string, required): The name of the site
    .PARAMETER description
        (string, optional): The resource's description.
    .PARAMETER primarySites
        (array, optional):
    .PARAMETER secondarySites
        (array, optional):
    .PARAMETER primaryEdges
        (array, optional):
    .PARAMETER secondaryEdges
        (array, optional):
    .PARAMETER addresses
        (array, optional):
    .PARAMETER edges
        (array, optional):
    .PARAMETER edgeAutoUpdateConfig
        (object, optional): Recurrance rule, time zone, and start/end settings for automatic
        edge updates for this site
    .PARAMETER mediaRegionsUseLatencyBased
        (boolean, optional):
    .PARAMETER location
        (object, required): Location to associate to the site
    .PARAMETER managed
        (boolean, optional):
    .PARAMETER ntpSettings
        (#/definitions/NTPSettings, optional): Network Time Protocol settings for the site
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.com.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory)][string]$siteName,
        [string]$description,
        [array]$primarySites,
        [array]$secondarySites,
        [array]$primaryEdges,
        [array]$secondaryEdges,
        [array]$addresses,
        [array]$edges,
        [object]$edgeAutoUpdateConfig,
        [string]$mediaRegionsUseLatencyBased,
        [parameter(Mandatory)][object]$location,
        [string]$managed,
        [object]$ntpSettings,
        [switch]$debugBody,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the site
    $Body = @{
        name = $siteName
        location = $location
    }
    if ($description) {$Body.Add("description",$description)}
    if ($primarySites) {$Body.Add("primarySites",@($primarySites))}
    if ($secondarySites) {$Body.Add("secondarySites",@($secondarySites))}
    if ($primaryEdges) {$Body.Add("primaryEdges",@($primaryEdges))}
    if ($secondaryEdges) {$Body.Add("secondaryEdges",@($secondaryEdges))}
    if ($addresses) {$Body.Add("addresses",@($addresses))}
    if ($edges) {$Body.Add("edges",@($edges))}
    if ($edgeAutoUpdateConfig) {$Body.Add("edgeAutoUpdateConfig",$edgeAutoUpdateConfig)}
    if ($mediaRegionsUseLatencyBased) {$Body.Add("mediaRegionsUseLatencyBased",$mediaRegionsUseLatencyBased)}
    if ($managed) {$Body.Add("managed",$managed)}
    if ($ntpSettings) {$Body.Add("ntpSettings",$ntpSettings)}
    if ($debugBody) {$Body}
    else {
        $Body = $Body | ConvertTo-Json -Depth 30

        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/sites"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    }
}


##### Get trunk base based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudTrunkBase {
Param(
    $ID = $null,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [int]$pageSize = 25,
    [int]$pageNumber = 1,
    [switch]$Metabases
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

# Check to see if the pageSize parameter exceeds a value of 100
if ($pageSize -gt 100) {
    Write-Warning "When retreiving Location information, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
    $pageSize = 100
    }

$Body = @{
    pageSize=$pageSize
    pageNumber=$pageNumber
    sortBy="name"
    sortOrder="ASC"
    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

# Get the site info
if (!$Metabases) {
    if (!$ID) {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/trunkbasesettings"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    else {
        if ($ID.Length -eq 36) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/trunkbasesettings/$ID"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/trunkbasesettings?name=*$ID*"
            (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
            }
        }
    }
else {
    if (!$ID) {
    $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/trunkbasesettings/availablemetabases"
    (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/trunkbasesettings/template?trunkMetabaseId=$ID"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
    }
}


##### Get phone base based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudPhoneBase {
    <#
    .SYNOPSIS
        Get-GenesysCloudPhoneBase retreives a phone base object or list of phone
        base objects
    .DESCRIPTION
        Get-GenesysCloudPhoneBase retreives a phone base object or list of phone
        base objects
    .PARAMETER baseId
        (string, optional): The phone base ID or name
    .PARAMETER metabases
        (switch, optional): switch to search for phone base metabases
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    Param(
        [string]$baseId = $null,
        [switch]$Metabases,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 100
    if ($pageSize -gt 100) {
        Write-Warning "When retreiving phone base information, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
        $pageSize = 100
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
        sortOrder="ASC"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the site info
    if (!$Metabases) {
        if (!$baseId) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phonebasesettings?expand=properties%2C%20lines"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
        else {
            if ($baseId.Length -eq 36) {
                $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phonebasesettings/$baseId"
                Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
            }
            else {
                $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phonebasesettings?name=$baseId"
                (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
            }
        }
    }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/phonebasesettings/availablemetabases"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
    }
}


##### Get line base based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudLineBase {
Param(
    $ID = $null,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [int]$pageSize = 25,
    [int]$pageNumber = 1
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

# Check to see if the pageSize parameter exceeds a value of 100
if ($pageSize -gt 100) {
    Write-Warning "When retreiving line base information, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
    $pageSize = 100
    }

$Body = @{
    pageSize=$pageSize
    pageNumber=$pageNumber
    sortBy="name"
    sortOrder="ASC"
    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

# Get the line base settings info
if (!$ID) {
    $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/linebasesettings"
    (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
    }
else {
    if ($ID.Length -eq 36) {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/linebasesettings/$ID"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/linebasesettings?name=*$ID*"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    }
}


##### Get line base based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudLine {
Param(
    $ID = $null,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [int]$pageSize = 25,
    [int]$pageNumber = 1,
    [switch]$BaseSettings
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

# Check to see if the pageSize parameter exceeds a value of 100
if ($pageSize -gt 100) {
    Write-Warning "When retreiving line base information, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
    $pageSize = 100
    }

$Body = @{
    pageSize=$pageSize
    pageNumber=$pageNumber
    sortBy="name"
    sortOrder="ASC"
    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

# Get the line base settings info
if (!$BaseSettings) {
    if (!$ID) {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/lines"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    else {
        if ($ID.Length -eq 36) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/lines/$ID"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/lines?name=*$ID*"
            (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
            }
        }
    }
else {
    if (!$ID) {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/linebasesettings"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    else {
        if ($ID.Length -eq 36) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/linebasesettings/$ID"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/linebasesettings?name=*$ID*"
            (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
            }
        }
    }
}


##### Get number pool based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudNumberPool {
    <#
    .SYNOPSIS
        Get-GenesysCloudNumberPool is used to return a phone number pool or extension pool
    .DESCRIPTION
        Get-GenesysCloudNumberPool is used to return a phone number pool or extension pool
    .PARAMETER ID
        The ID parameter is a string type and is optional.  It can be the number pool
        Id or can be left blank to return all number pools
    .PARAMETER DIDPool
        The DIDPool parameter is a switch type and is optional to return DID pool
        information
    .PARAMETER ExtensionPool
        The ExtensionPool parameter is a switch type to return extension pool
        information
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    Param(
        [string]$ID = $null,
        [switch]$DIDPool,
        [switch]$ExtensionPool,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 100
    if ($pageSize -gt 100) {
        Write-Warning "When retreiving number pool information, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
        $pageSize = 100
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="startNumber"
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the number pool info
    if ($DIDPool) {
        if (!$ID) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/didpools"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
        else {
            if ($ID.Length -eq 36) {
                $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/didpools/$ID"
                Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
            }
            else {
                $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/didpools?name=$ID"
                (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
            }
        }
    }
    elseif ($ExtensionPool) {
        if (!$ID) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/extensionpools"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
        else {
            if ($ID.Length -eq 36) {
                $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/extensionpools/$ID"
                Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
            }
            else {
                $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/extensionpools?name=$ID"
                (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
            }
        }
    }
    else {
        Write-Error -Message "You must specify either a DID pool or an Extension pool to search." -RecommendedAction "Please try again using either the '-DIDPool' or '-ExtensionPool' switch."
    }
}


##### Get outbound routes based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudOutboundRoute {
Param(
    $ID = $null,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [int]$pageSize = 25,
    [int]$pageNumber = 1,
    $SiteID
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

# Check to see if the pageSize parameter exceeds a value of 100
if ($pageSize -gt 100) {
    Write-Warning "When retreiving route information, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
    $pageSize = 100
    }

$Body = @{
    pageSize=$pageSize
    pageNumber=$pageNumber
    sortBy="startNumber"
    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

# Get the line base settings info

if (!$SiteID) {
    if (!$ID) {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/outboundroutes"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    else {
        if ($ID.Length -eq 36) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/outboundroutes/$ID"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/outboundroutes?name=*$ID*"
            (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
            }
        }
    }
else {
    $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/outboundroutes?site.id=$SiteID"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
    }
}


##### Get edge based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudEdge {
Param(
    $ID = $null,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [int]$pageSize = 25,
    [int]$pageNumber = 1
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

# Check to see if the pageSize parameter exceeds a value of 100
if ($pageSize -gt 100) {
    Write-Warning "When retreiving edge, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
    $pageSize = 100
    }

$Body = @{
    pageSize=$pageSize
    pageNumber=$pageNumber
    sortBy="name"
    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

# Get the line base settings info

if (!$ID) {
    $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges"
    (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
    }
else {
    if ($ID.Length -eq 36) {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/$ID"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges?name=*$ID*"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    }
}


##### Get wrapup code based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudWrapupCode {
    <#
    .SYNOPSIS
        Get-GenesysCloudWrapupCode is used to get a list of GenesysCloud Wrapup Codes
    .DESCRIPTION
        Get-GenesysCloudWrapupCode is used to get a list of GenesysCloud Wrapup Codes
    .PARAMETER ID
        The ID parameter is a string type, and can be the wrapup code's ID, the
        code's name, or can be empty to display all wrapup codes
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER Accesstoken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    Param(
        $ID = $null,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 100
    if ($pageSize -gt 100) {
        Write-Warning "When retreiving wrapup information, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
        $pageSize = 100
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the wrapup code info
    if (!$ID) {
        $tokenurl = "https://api.$InstanceName/api/v2/routing/wrapupcodes"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
    }
    else {
        if ($ID.Length -eq 36) {
            $tokenurl = "https://api.$InstanceName/api/v2/routing/wrapupcodes/$ID"
            $Codes = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/routing/wrapupcodes?name=$ID"
            $Codes = (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
        foreach ($Code in $Codes) {
            $Code
        }
    }
}


##### Create new wrapup code
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudWrapupCode {
    <#
    .SYNOPSIS
        New-GenesysCloudWrapupCode is used to create a new GenesysCloud Wrapup Code
    .DESCRIPTION
        New-GenesysCloudWrapupCode is used to create a new GenesysCloud Wrapup Code
    .PARAMETER wrapupCodeName
        (string, required): The wrap-up code name.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER Accesstoken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(mandatory=$true)]$wrapupCodeName,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Create the new wrapup code
    if ($wrapupCodeName) {
        $Body = @{
            name = $wrapupCodeName
        } | ConvertTo-Json -Depth 20
        $tokenurl = "https://api.$InstanceName/api/v2/routing/wrapupcodes"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    }
    else {
        Write-Error -Message "A wrapup code name was not specified." -RecommendedAction "Please run the command and specify the -wrapupCodeName parameter"
    }
}


##### Update a wrapup code
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Set-GenesysCloudWrapupCode {
    <#
    .SYNOPSIS
        Set-GenesysCloudWrapupCode is used to update an existing GenesysCloud Wrapup Code
    .DESCRIPTION
        Set-GenesysCloudWrapupCode is used to update an existing GenesysCloud Wrapup Code
    .PARAMETER wrapupCodeId
        (string, required): The wrap-up code ID.
    .PARAMETER wrapupCodeName
        (string, required): The wrap-up code name.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER Accesstoken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(mandatory=$true)]$wrapupCodeId,
        [parameter(mandatory=$true)]$wrapupCodeName,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # update the wrapup code
    if ($wrapupCodeName) {
        if ($wrapupCodeId) {
            $Body = @{
                name = $wrapupCodeName
            } | ConvertTo-Json -Depth 20
            $tokenurl = "https://api.$InstanceName/api/v2/routing/wrapupcodes/$wrapupCodeId"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method PUT
        }
        else {
            Write-Error -Message "A wrapup code ID was not specified." -RecommendedAction "Please run the command and specify the -wrapupCodeId parameter"
        }
    }
    else {
        Write-Error -Message "A wrapup code name was not specified." -RecommendedAction "Please run the command and specify the -wrapupCodeName parameter"
    }
}


##### Remove a wrapup code
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Remove-GenesysCloudWrapupCode {
    <#
    .SYNOPSIS
        Remove-GenesysCloudWrapupCode is used to remove an existing GenesysCloud Wrapup Code
    .DESCRIPTION
        Remove-GenesysCloudWrapupCode is used to remove an existing GenesysCloud Wrapup Code
    .PARAMETER wrapupCodeId
        (string, required): The wrap-up code ID.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER Accesstoken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(mandatory=$true)]$wrapupCodeId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # update the wrapup code
    if ($wrapupCodeId) {
        $tokenurl = "https://api.$InstanceName/api/v2/routing/wrapupcodes/$wrapupCodeId"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method DELETE
    }
    else {
        Write-Error -Message "A wrapup code ID was not specified." -RecommendedAction "Please run the command and specify the -wrapupCodeId parameter"
    }
}


##### Get wrapup code assignment for a queue
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudWrapupCodeAssignment {
    <#
    .SYNOPSIS
        Get-GenesysCloudWrapupCodeAssignment is used to get a list of GenesysCloud Wrapup Codes
        that are assigned to a GenesysCloud Queue
    .DESCRIPTION
        Get-GenesysCloudWrapupCodeAssignment is used to get a list of GenesysCloud Wrapup Codes
        that are assigned to a GenesysCloud Queue
    .PARAMETER queueId
        The queueId parameter is a string type and is required.  This should be the queue
        ID to which the wrapup codes are assigned
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER Accesstoken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    Param(
        [Parameter(Mandatory=$true)][string]$queueId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 100
    if ($pageSize -gt 100) {
        Write-Warning "When retreiving wrapup information, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
        $pageSize = 100
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the wrapup code info
    if ($queueId) {
        $tokenurl = "https://api.$InstanceName/api/v2/routing/queues/$queueId/wrapupcodes"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
    }
    else {
        Write-Error -Message "A queue ID was not specified." -RecommendedAction "Run the command again and specify the -queueId parameter"
    }
}


##### Add wrapup code assignment to a queue
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Add-GenesysCloudWrapupCodeAssignment {
    <#
    .SYNOPSIS
        Add-GenesysCloudWrapupCodeAssignment is used to assign a new GenesysCloud Wrapup Code to
        a GenesysCloud Queue
    .DESCRIPTION
        Add-GenesysCloudWrapupCodeAssignment is used to assign a new GenesysCloud Wrapup Code to
        a GenesysCloud Queue
    .PARAMETER queueId
        The queueId parameter is a string type and is required.  This should be the queue
        ID to which the wrapup codes will be assigned
    .PARAMETER wrapupCodeId
        The wrapupCodeId parameter is an array type and is required.  This should be the
        wrapup code ID or an array of wrapup code IDs to be assigned to the queue
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER Accesstoken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$true)][string]$queueId,
        [Parameter(Mandatory=$true)][array]$wrapupCodeId,
        [switch]$debugBody,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # add the wrapup code assignment to the queue
    $Body = $wrapupCodeId | ForEach-Object { @{id = $_} }

    if ($debugBody) {
        $Body
    }
    else {
        $Body = $Body | ConvertTo-Json -Depth 20 -AsArray
        $tokenurl = "https://api.$InstanceName/api/v2/routing/queues/$queueId/wrapupcodes"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    }
}


##### Remove wrapup code assignment from a queue
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Remove-GenesysCloudWrapupCodeAssignment {
    <#
    .SYNOPSIS
        Remove-GenesysCloudWrapupCodeAssignment is used to remove a GenesysCloud Wrapup Code
        from a GenesysCloud Queue
    .DESCRIPTION
        Remove-GenesysCloudWrapupCodeAssignment is used to remove a GenesysCloud Wrapup Code
        from a GenesysCloud Queue
    .PARAMETER queueId
        The queueId parameter is a string type and is required.  This should be the queue
        ID to which the wrapup codes will be removed
    .PARAMETER wrapupCodeId
        The wrapupCodeId parameter is a string type and is required.  This should be the
        wrapup code ID to be removed from the queue
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER Accesstoken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$true)][string]$queueId,
        [Parameter(Mandatory=$true)][string]$wrapupCodeId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # remove the wrapup code assignment from the queue
    if ($queueId) {
        if ($wrapupCodeId) {
            $tokenurl = "https://api.$InstanceName/api/v2/routing/queues/$queueId/wrapupcodes/$wrapupCodeId"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method DELETE
        }
        else {
            Write-Error -Message "A wrapup code ID was not specified." -RecommendedAction "Run the command again and specify the -wrapupCodeId parameter"
        }
    }
    else {
        Write-Error -Message "A queue ID was not specified." -RecommendedAction "Run the command again and specify the -queueId parameter"
    }
}


##### Get script based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudScript {
    Param(
        [string]$scriptId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving script information, the maximum value for the pageSize parameter is 500. Setting the pageSize parameter from $pageSize to 500."
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the script info
    if (!$scriptId) {
        $tokenurl = "https://api.$InstanceName/api/v2/scripts"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
    }
    else {
        try {
            [guid]$scriptId | Out-Null
            $tokenurl = "https://api.$InstanceName/api/v2/scripts/$scriptId"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
        }
        catch {
            $tokenurl = "https://api.$InstanceName/api/v2/scripts?name=$scriptId"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
    }
}


##### Get data table based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudDataTable {
    Param(
        [string]$datatableId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving table information, the maximum value for the pageSize parameter is 500. Setting the pageSize parameter from $pageSize to 500."
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
        sortOrder="ascending"
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the table info
    if (!$datatableId) {
        $tokenurl = "https://api.$InstanceName/api/v2/flows/datatables?expand=schema"
        $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        $response.Content | ConvertFrom-Json
    }
    else {
        try {
            [guid]$datatableId | Out-Null
            $tokenurl = "https://api.$InstanceName/api/v2/flows/datatables/$($datatableId)?expand=schema"
            $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Method Get
            $response.Content | ConvertFrom-Json
        }
        catch {
            $tokenurl = "https://api.$InstanceName/api/v2/flows/datatables?expand=schema"
            $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            $response.Content | ConvertFrom-Json | Select-Object -ExpandProperty entities | Where-Object name -Like $datatableId
        }
    }
    Set-Variable -Name responseHeaders -Value $response.Headers -Scope Global
}


##### Get data table row based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudDataTableRow {
    <#
    .SYNOPSIS
        Get-GenesysCloudDataTableRow gets a row or all rows from a data table
    .DESCRIPTION
        Get-GenesysCloudDataTableRow gets a row or all rows from a data table
    .PARAMETER dataTableId
        (string, required): the object ID of the data table
    .PARAMETER dataRowId
        (string, optional): the key ID of the data table row
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER Accesstoken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    Param(
        [parameter(Mandatory)][string]$datatableId,
        [string]$datarowId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving table row information, the maximum value for the pageSize parameter is 500. Setting the pageSize parameter from $pageSize to 500."
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the table row info
    try {
        [guid]$datatableId | Out-Null
    }
    catch {
        Write-Error -Message "The data table ID is not a valid UUID formatted string" -RecommendedAction "Try the command again and enter a valid UUID string for the -dataTableId parameter." -ErrorAction Stop
    }

    if ($datarowId) {
        $tokenurl = "https://api.$InstanceName/api/v2/flows/datatables/$($datatableId)/rows/$($dataRowId)?showbrief=false"
        $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Method Get -Body $Body
    }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/flows/datatables/$($datatableId)/rows?showbrief=false"
        $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
    }
    Set-Variable -Name responseHeaders -Value $response.Headers -Scope Global
    $response.Content | ConvertFrom-Json
}


##### create new data table
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudDataTable {
    <#
    .SYNOPSIS
        New-GenesysCloudDataTable creates a new data table
    .DESCRIPTION
        New-GenesysCloudDataTable creates a new data table
    .PARAMETER tableName
        (string, optional): the name of the new table
    .PARAMETER description
        (string, optional): The description from the JSON schema (equates to the Description
        field.)
    .PARAMETER schema
        (object, optional): the schema object as stored in the system.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER Accesstoken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$true)][string]$tableName,
        [string]$description,
        [object]$schema,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the table
    $Body = @{
        name = $tableName
    }
    if ($description) {$Body.Add("description",$description)}
    if ($schema) {$Body.Add("schema",$schema)}
    $Body = $Body | ConvertTo-Json -Depth 20

    $tokenurl = "https://api.$InstanceName/api/v2/flows/datatables"
    $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    Set-Variable -Name responseHeaders -Value $response.Headers -Scope Global
    $response.Content | ConvertFrom-Json
}


##### create new data table row
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudDataTableRow {
    <#
    .SYNOPSIS
        New-GenesysCloudDataTable creates a new data table row
    .DESCRIPTION
        New-GenesysCloudDataTable creates a new data table row
    .PARAMETER dataTableId
        (string, required): the object ID of the data table
    .PARAMETER rowData
        (object, required): The key value pair data object to be added to the table
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER Accesstoken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$true)][string]$dataTableId,
        [Parameter(Mandatory=$true)][object]$rowData,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the table row
    $Body = $rowData | ConvertTo-Json -Depth 20

    $tokenurl = "https://api.$InstanceName/api/v2/flows/datatables/$($dataTableId)/rows"
    $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    Set-Variable -Name responseHeaders -Value $response.Headers -Scope Global
    $response.Content | ConvertFrom-Json
}


##### Get skill based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudSkill {
Param(
    $ID = $null,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [int]$pageSize = 25,
    [int]$pageNumber = 1
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

# Check to see if the pageSize parameter exceeds a value of 500
if ($pageSize -gt 500) {
    Write-Warning "When retreiving skill information, the maximum value for the pageSize parameter is 500. Setting the pageSize parameter from $pageSize to 500."
    $pageSize = 500
    }

$Body = @{
    pageSize=$pageSize
    pageNumber=$pageNumber
    sortBy="name"
    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

# Get the skill info

if (!$ID) {
    $tokenurl = "https://api.$InstanceName/api/v2/routing/skills"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
    }
else {
    if ($ID.Length -eq 36) {
        $tokenurl = "https://api.$InstanceName/api/v2/routing/skills/$ID"
        $Skills = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/routing/skills?name=$ID"
        $Skills = (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    foreach ($Skill in $Skills) {
        $Skill
        }
    }
}


##### Create a new skill
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudSkill {
    <#
    .SYNOPSIS
        New-GenesysCloudSkill is used to create a new GenesysCloud skill
    .DESCRIPTION
        New-GenesysCloudSkill is used to create a new GenesysCloud skill
    .PARAMETER skillName
        The skillName parameter is a string type and is required.  It shuold be the name
        of the new skill.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$skillName,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the new skill
    $Body = @{name = $skillName} | ConvertTo-Json -Depth 20
    $tokenurl = "https://api.$InstanceName/api/v2/routing/skills"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
}


##### Get skills assigned to a user
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudSkillAssignment {
    <#
    .SYNOPSIS
        Get-GenesysCloudSkillAssignment is used to get a list of skills that are
        assigned to a user
    .DESCRIPTION
        Get-GenesysCloudSkillAssignment is used to get a list of skills that are
        assigned to a user
    .PARAMETER userId
        The userId parameter is a string type and is required.  It should be the ID of
        the user and can be retreived by using the Get-GenesysCloudUser command.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$userId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving assigned skill information, the maximum value for the pageSize parameter is 500. Setting the pageSize parameter from $pageSize to 500."
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # get the list of skill assignments
    $tokenurl = "https://api.$InstanceName/api/v2/users/$userId/routingskills"
    (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET).entities
}


##### Assign skills to user
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Add-GenesysCloudSkillAssignment {
    <#
    .SYNOPSIS
        Add-GenesysCloudSkillAssignment is used to assign a GenesysCloud skill to a user
    .DESCRIPTION
        Add-GenesysCloudSkillAssignment is used to assign a GenesysCloud skill to a user
    .PARAMETER userId
        The userId parameter is a string type and is required.  It should be the ID of
        the user and can be retreived by using the Get-GenesysCloudUser command.
    .PARAMETER skillId
        The skillId parameter is a string type and is required.  It should be the ID
        of the skill, and can be retreived by using the Get-GenesysCloudSkill command.
    .PARAMETER skillProficiency
        The skillProficiency parameter is an integer type and is required.  It should be
        a value between 0.0 to 5.0 and is based on how competent an agent is for the
        particular skill.
    .PARAMETER bulkAdd
        The bulkAdd parameter is a switch type and is optional.
    .PARAMETER bulkReplace
        The bulkReplace parameter is a switch type and is optional.
    .PARAMETER bulkSkills
        The bulkSkills parameter is an array type and is required if either the bulkAdd
        or the bulkReplace parameters are set.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$userId,
        [string]$skillId,
        [int]$skillProficiency,
        [switch]$bulkAdd,
        [switch]$bulkReplace,
        [array]$bulkSkills,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [switch]$debugBody
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # assign the new skill
    if ($bulkAdd) {
        if ($bulkSkills) {
            for ($i = 0; $i -lt $bulkSkills.count; $i += 50) {
                $bulkSkillsChunks += ,@($bulkSkills[$i..($i + 49)]);
            }

            # iterate through chunks
            for ($i = 0; $i -lt $bulkSkillsChunks.count; $i ++) {
                # build the request body
                $Body = @($bulkSkillsChunks[$i])

                # send the request
                if ($debugBody) {
                    $Body
                }
                else {
                    $Body = $Body | ConvertTo-Json -Depth 20 -AsArray
                    $tokenurl = "https://api.$InstanceName/api/v2/users/$userId/routingskills/bulk"
                    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method PATCH
                }

                # increment group version
                $version ++
                Start-Sleep -Seconds 1
            }
        }
        else {
            Write-Error "There were no skills defined to add to the user." -RecommendedAction "Run the command again and specify the -bulkSkills parameter."
        }
    }
    elseif ($bulkReplace) {
        if ($bulkSkills) {
            for ($i = 0; $i -lt $bulkSkills.count; $i += 50) {
                $bulkSkillsChunks += ,@($bulkSkills[$i..($i + 49)]);
            }

            # iterate through chunks
            for ($i = 0; $i -lt $bulkSkillsChunks.count; $i ++) {
                # build the request body
                $Body = @($bulkSkillsChunks[$i])

                # send the request
                if ($debugBody) {
                    $Body
                }
                else {
                    $Body = $Body | ConvertTo-Json -Depth 20 -AsArray
                    $tokenurl = "https://api.$InstanceName/api/v2/users/$userId/routingskills/bulk"
                    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method PUT
                }

                # increment group version
                $version ++
                Start-Sleep -Seconds 1
            }
        }
        else {
            Write-Error "There were no skills defined to replace on the user." -RecommendedAction "Run the command again and specify the -bulkSkills parameter."
        }
    }
    else {
        if ($skillId -and $skillProficiency) {
            $Body = @{
                id = $skillId
                proficiency = $skillProficiency
            }

            if ($debugBody) {
                $Body
            }
            else {
                $Body = $Body | ConvertTo-Json -Depth 20 -AsArray
                $tokenurl = "https://api.$InstanceName/api/v2/users/$userId/routingskills"
               Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
            }
        }
        else {
            Write-Error "Either the skill ID or the skill proficiency were not defined." -RecommendedAction "Run the command again and specify both the -skillId and the -skillProficiency parameters."
        }
    }
}


##### Remove skills from user
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Remove-GenesysCloudSkillAssignment {
    <#
    .SYNOPSIS
        Remove-GenesysCloudSkillAssignment is used to remove a GenesysCloud skill from a user
    .DESCRIPTION
        Remove-GenesysCloudSkillAssignment is used to remove a GenesysCloud skill from a user
    .PARAMETER userId
        The userId parameter is a string type and is required.  It should be the ID of
        the user and can be retreived by using the Get-GenesysCloudUser command.
    .PARAMETER skillId
        The skillId parameter is a string type and is required.  It should be the ID
        of the skill, and can be retreived by using the Get-GenesysCloudSkill command.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$userId,
        [Parameter(Mandatory=$True)][string]$skillId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # remove the skill
    $tokenurl = "https://api.$InstanceName/api/v2/users/$userId/routingskills/$skillId"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method DELETE
}


##### Get Language based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudLanguage {
Param(
    $ID = $null,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [int]$pageSize = 25,
    [int]$pageNumber = 1
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

# Check to see if the pageSize parameter exceeds a value of 500
if ($pageSize -gt 500) {
    Write-Warning "When retreiving Language information, the maximum value for the pageSize parameter is 500. Setting the pageSize parameter from $pageSize to 500."
    $pageSize = 500
    }

$Body = @{
    pageSize=$pageSize
    pageNumber=$pageNumber
    sortBy="name"
    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

# Get the Language info

if (!$ID) {
    $tokenurl = "https://api.$InstanceName/api/v2/routing/Languages"
    (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
    }
else {
    if ($ID.Length -eq 36) {
        $tokenurl = "https://api.$InstanceName/api/v2/routing/Languages/$ID"
        $Languages = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/routing/Languages?name=*$ID*"
        $Languages = (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    foreach ($Language in $Languages) {
        $Language
        }
    }
}


##### Create a new language
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudLanguage{
    <#
    .SYNOPSIS
        New-GenesysCloudLanguage is used to create a new GenesysCloud language
    .DESCRIPTION
        New-GenesysCloudLanguage is used to create a new GenesysCloud language
    .PARAMETER languageName
        The languageName parameter is a string type and is required.  It should be the
        name of the new language.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$languageName,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the new language
    $Body = @{name = $languageName} | ConvertTo-Json -Depth 20
    $tokenurl = "https://api.$InstanceName/api/v2/routing/languages"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
}



##### Get languages assigned to a user
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudLanguageAssignment {
    <#
    .SYNOPSIS
        Get-GenesysCloudLanguageAssignment is used to get a list of languages that are
        assigned to a user
    .DESCRIPTION
        Get-GenesysCloudLanguageAssignment is used to get a list of languages that are
        assigned to a user
    .PARAMETER userId
        The userId parameter is a string type and is required.  It should be the ID of
        the user and can be retreived by using the Get-GenesysCloudUser command.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$userId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving assigned skill information, the maximum value for the pageSize parameter is 500. Setting the pageSize parameter from $pageSize to 500."
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # get the list of language assignments
    $tokenurl = "https://api.$InstanceName/api/v2/users/$userId/routinglanguages"
    (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET).entities
}


##### Assign language to user
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Add-GenesysCloudLanguageAssignment {
    <#
    .SYNOPSIS
        Add-GenesysCloudLanguageAssignment is used to assign a GenesysCloud language to a user
    .DESCRIPTION
        Add-GenesysCloudLanguageAssignment is used to assign a GenesysCloud language to a user
    .PARAMETER userId
        The userId parameter is a string type and is required.  It should be the ID of
        the user and can be retreived by using the Get-GenesysCloudUser command.
    .PARAMETER languageId
        The languageId parameter is a string type and is required.  It should be the ID
        of the language, and can be retreived by using the Get-GenesysCloudLanguage command.
    .PARAMETER languageProficiency
        The languageProficiency parameter is an integer type and is required.  It should be
        a value between 0.0 to 5.0 and is based on how competent an agent is for the
        particular language.
    .PARAMETER bulkAdd
        The bulkAdd parameter is a switch type and is optional.
    .PARAMETER bulkReplace
        The bulkReplace parameter is a switch type and is optional.
    .PARAMETER bulkLanguages
        The bulkLanguages parameter is an array type and is required if either the bulkAdd
        or the bulkReplace parameters are set.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$userId,
        [string]$languageId,
        [string]$languageProficiency,
        [switch]$bulkAdd,
        [switch]$bulkReplace,
        [array]$bulkLanguages,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [switch]$debugBody
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # assign the new skill
    if ($bulkAdd) {
        if ($bulkLanguages) {
            for ($i = 0; $i -lt $bulkLanguages.count; $i += 50) {
                $bulkLanguageChunks += ,@($bulkLanguages[$i..($i + 49)]);
            }

            # iterate through chunks
            for ($i = 0; $i -lt $bulkLanguageChunks.count; $i ++) {
                # build the request body
                $Body = @($bulkLanguageChunks[$i])

                # send the request
                if ($debugBody) {
                    $Body
                }
                else {
                    $Body = $Body | ConvertTo-Json -Depth 20 -AsArray
                    $tokenurl = "https://api.$InstanceName/api/v2/users/$userId/routingskills/bulk"
                    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method PATCH
                }

                # increment group version
                $version ++
                Start-Sleep -Seconds 1
            }
        }
        else {
            Write-Error "There were no skills defined to add to the user." -RecommendedAction "Run the command again and specify the -bulkSkills parameter."
        }
    }
    elseif ($bulkReplace) {
        if ($bulkLanguages) {
            for ($i = 0; $i -lt $bulkLanguages.count; $i += 50) {
                $bulkLanguageChunks += ,@($bulkLanguages[$i..($i + 49)]);
            }

            # iterate through chunks
            for ($i = 0; $i -lt $bulkLanguageChunks.count; $i ++) {
                # build the request body
                $Body = @($bulkLanguageChunks[$i])

                # send the request
                if ($debugBody) {
                    $Body
                }
                else {
                    $Body = $Body | ConvertTo-Json -Depth 20 -AsArray
                    $tokenurl = "https://api.$InstanceName/api/v2/users/$userId/routingskills/bulk"
                    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method PUT
                }

                # increment group version
                $version ++
                Start-Sleep -Seconds 1
            }
        }
        else {
            Write-Error "There were no skills defined to replace on the user." -RecommendedAction "Run the command again and specify the -bulkSkills parameter."
        }
    }
    else {
        if ($languageId -and $languageProficiency) {
            $Body = @{
                id = $languageId
                proficiency = $languageProficiency
            }

            if ($debugBody) {
                $Body
            }
            else {
                $Body = $Body | ConvertTo-Json -Depth 20 -AsArray
                $tokenurl = "https://api.$InstanceName/api/v2/users/$userId/routingskills"
               Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
            }
        }
        else {
            Write-Error "Either the skill ID or the skill proficiency were not defined." -RecommendedAction "Run the command again and specify both the -skillId and the -skillProficiency parameters."
        }
    }
}


##### Remove language from user
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Remove-GenesysCloudLanguageAssignment {
    <#
    .SYNOPSIS
        Remove-GenesysCloudLanguageAssignment is used to remove a GenesysCloud language
        assignment from a user
    .DESCRIPTION
        Remove-GenesysCloudLanguageAssignment is used to remove a GenesysCloud language
        assignment from a user
    .PARAMETER userId
        The userId parameter is a string type and is required.  It should be the ID of
        the user and can be retreived by using the Get-GenesysCloudUser command.
    .PARAMETER languageId
        The languageId parameter is a string type and is required.  It should be the ID
        of the language, and can be retreived by using the Get-GenesysCloudLanguage command.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$userId,
        [Parameter(Mandatory=$True)][string]$languageId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # remove the language assignment
    $tokenurl = "https://api.$InstanceName/api/v2/users/$userId/routinglanguages/$languageId"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method DELETE
}


##### Get number or extension on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudNumber {
Param(
    $ID = $null,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [int]$pageSize = 25,
    [int]$pageNumber = 1,
    [switch]$DID,
    [switch]$Extension
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

# Check to see if the pageSize parameter exceeds a value of 100
if ($pageSize -gt 100) {
    Write-Warning "When retreiving number information, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
    $pageSize = 100
    }

$Body = @{
    pageSize=$pageSize
    pageNumber=$pageNumber
    sortBy="number"
    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

# Get the number info
if ($DID) {
    if (!$ID) {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/dids"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    else {
        if ($ID.Length -eq 36) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/dids/$ID"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/dids?phoneNumber=*$ID*"
            (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
            }
        }
    }
if ($Extension) {
    if (!$ID) {
        $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/extensions"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    else {
        if ($ID.Length -eq 36) {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/extensions/$ID"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/telephony/providers/edges/extensions?number=*$ID*"
            (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
            }
        }
    }
if ((!$DID) -and (!$Extension)) {
    Write-Error -Message "You must specify either a DID or an Extension to search." -RecommendedAction "Please try again using either the '-DID' or '-Extension' switch."
    }
}


##### Get person info based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudPerson {
Param(
    [Parameter(Mandatory=$True)]$ID,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken,
    [switch]$SkillTags
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

# Get the person info
$tokenurl = "https://apps.$InstanceName/api/v2/people/$ID"+"?fl=*"
$person = (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get).res
if ($SkillTags) {
    $person.skills.skills.value
    }
else {
    $person
    }
}


##### Set person info based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Set-GenesysCloudPerson {
    <#
    .SYNOPSIS
        Set-GenesysCloudPerson is used to update or configure a person object
    .DESCRIPTION
        Set-GenesysCloudPerson is used to update or configure a person object with a
        location, phone number, skills, etc.  These attributes are shown on the
        respective user's contact page.
    .PARAMETER PersonID
        The PersonID parameter must be the user's personId object attribute.

        This can be retreived by running the Get-GenesysCloudUser command against the
        respective user object.

        The PersonID parameter is the first part of the jabberId before the '@' symbol,
        which can be found in the 'chat' field.
    .PARAMETER LocationID
        The LocationID parameter must be the ID of a single location object.

        This can be retreived by running the Get-GenesysCloudLocation command and referencing
        the value of the '_id' field.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory = $True)]$PersonID,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [string]$LocationID
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

    $Headers = @{
        authorization  = "Bearer " + $Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    if ($LocationID) {
        # Get the person info
        $person = Get-GenesysCloudPerson -ID $PersonID -InstanceName $InstanceName -Accesstoken $Accesstoken

        # Build the request body
        $Body = '{"labelKey":"location_office","value":{"locationId":"' + $($locationID) + '","notes":""}}'

        # Send the request
        $tokenurl = "https://apps.$InstanceName/directory/api/v2/people/$($person._id)/$($person.version)/field/location.location"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Post
    }
}


##### Upload a new photo based on photo URL
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Import-GenesysCloudImage {
Param(
    [Parameter(Mandatory=$True)]$ImageURL,
    [string]$InstanceName = "usw2.pure.cloud",
    [string]$Accesstoken = $ClientAccessToken
)

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

$Body = @"
{"imageUrl": "$ImageURL"}
"@

# upload the image
$tokenurl = "https://apps.$InstanceName/directory/api/v2/images"
Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Post
}


##### Set a photo to a person info based on image Id and person Id
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Set-GenesysCloudPersonImage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)]$ImageID,
        [Parameter(Mandatory=$True)]$PersonID,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

# Check to see if an access token has been aqcuired
if (!($AccessToken)) {
    $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

$Headers = @{
    authorization = "Bearer "+$Accesstoken
    "Content-Type" = "application/json; charset=UTF-8"
    }

$Body = @"
{
"labelKey": ""
}
"@

# assign the image to the person's profile
$tokenurl = "https://apps.$InstanceName/directory/api/v2/images/$ImageID/link/person/$PersonID/uploads.images"
$assignedImage = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Post
$assignedImageId = $assignedImage.res._id

# set the image as primary
$person = Get-GenesysCloudPerson -ID $PersonID -InstanceName $InstanceName -Accesstoken $Accesstoken
$personVersion = $person.version
$ImageBody = ($person.uploads.images | Where-Object _id -Like $assignedImageId).value | ConvertTo-Json -Depth 10

$Body = @"
{
"images": {
  "profile": [{
    "ref": $ImageBody,
    "value": {
      "fieldId": "$assignedImageId",
      "fieldPath": "uploads.images"
      }
    }]
  },
"version": $personVersion
}
"@

$tokenurl = "https://apps.$InstanceName/api/v2/people/$personId"
Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Post
}


##### Get chat group info based on object Id
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudChatGroup {
    Param(
        [Parameter(Mandatory=$True)]$ID,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $AccessToken = Get-GenesysCloudAccessToken -InstanceName $InstanceName

    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the person info
    $tokenurl = "https://apps.$InstanceName/api/v2/groups/$ID"+"?fl=*"
    $group = (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get)
    $group
}


##### Get queue based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudQueue {
    Param(
        $ID = $null,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1,
        [switch]$WrapupCodes
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 100
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving queue information, the maximum value for the pageSize parameter is 500. Setting the pageSize parameter from $pageSize to 500."
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the queue info
    if (!$ID) {
        if ($WrapupCodes) {
            Write-Error -message "The ID paramter was not defined." -RecommendedAction "To get wrapup codes for a queue, please specify ID paramter."
        }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/routing/queues"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
    }
    else {
        if ($ID.Length -eq 36) {
            if ($WrapupCodes) {
                $tokenurl = "https://api.$InstanceName/api/v2/routing/queues/$($ID)/wrapupcodes"
                (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
            }
            else {
                $tokenurl = "https://api.$InstanceName/api/v2/routing/queues/$($ID)"
                Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
        }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/routing/queues?name=$($ID)"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
    }
}


##### Create a new queue
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudQueue {
    <#
    .SYNOPSIS
        New-GenesysCloudQueue creates a new GenesysCloud Queue
    .DESCRIPTION
        New-GenesysCloudQueue creates a new GenesysCloud Queue
    .PARAMETER queueName
        (string, required): The queue name
    .PARAMETER divisionId
        (string, optional): The division ID to which this entity belongs. The division
        ID can be retreived by running the Get-GenesysCloudDivision command.
    .PARAMETER skillEvaluationMethod
        (string, optional): The skill evaluation method to use when routing
        conversations. Valid Values: NONE, BEST, ALL
    .PARAMETER sourceQueueId
        (string, optional): The id of an existing queue to copy the settings from when
        creating a new queue.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$queueName,
        [string]$divisionId,
        [string]$skillEvaluationMethod,
        [string]$sourceQueueId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Create the new queue
    $Body = @{
        name = $queueName
    }
    if ($divisionId) { $Body.Add("division", @{id = $divisionId}) }
    if ($skillEvaluationMethod) { $Body.Add("skillEvaluationMethod", $skillEvaluationMethod) }
    if ($sourceQueueId) { $Body.Add("sourceQueueId", $sourceQueueId) }
    $Body = $Body | ConvertTo-Json -Depth 20
    $Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $tokenurl = "https://api.$InstanceName/api/v2/routing/queues"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
}


##### Copy the settings from one queue to a new queue
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Copy-GenesysCloudQueue {
    <#
    .SYNOPSIS
        Copy-GenesysCloudQueue creates a new GenesysCloud Queue from the settings of
        another queue
    .DESCRIPTION
        Copy-GenesysCloudQueue creates a new GenesysCloud Queue from the settings of
        another queue.  The settings can be passed in as an object or can be pulled
        from an existing queue in the same GenesysCloud org.
    .PARAMETER queueName
        (string, required): The new queue name
    .PARAMETER divisionId
        (string, optional): The division ID to which this entity belongs. The division
        ID can be retreived by running the Get-GenesysCloudDivision command.
    .PARAMETER sourceQueueId
        (string, optional): The id of an existing queue to copy the settings from.
    .PARAMETER sourceQueueObject
        (object, optional): An existing queue object to copy the settings from.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$queueName,
        [string]$divisionId,
        [string]$sourceQueueId,
        [object]$sourceQueueObject,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Create the new queue
    if ($sourceQueueId) {
        $Body = @{
            name = $queueName
            sourceQueueId = $sourceQueueId
        }
        if ($divisionId) { $Body.Add("division", @{id = $divisionId}) }
        $Body = $Body | ConvertTo-Json -Depth 20
    }
    else {
        if ($sourceQueueObject) {
            $sourceQueueObject.PSObject.Properties.Remove("id")
            $sourceQueueObject.PSObject.Properties.Remove("modifiedBy")
            $sourceQueueObject.PSObject.Properties.Remove("dateModified")
            $sourceQueueObject.PSObject.Properties.Remove("dateCreated")
            $sourceQueueObject.PSObject.Properties.Remove("createdBy")
            $sourceQueueObject.PSObject.Properties.Remove("memberCount")
            $sourceQueueObject.PSObject.Properties.Remove("selfUri")
            if ($divisionId) { $sourceQueueObject.division = @{ id = $divisionId } }
            else { $sourceQueueObject.division = @{ name = $sourceQueueObject.division.name } }
            $sourceQueueObject.name = $queueName
            $Body = $sourceQueueObject | ConvertTo-Json -Depth 20
        }
        else {
            Write-Error -Message "No source queue information was specified." -RecommendedAction "Please try again and specify either the -sourceQueueId or the -sourceQueueObject parameter."
            exit
        }
    }
    $Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $tokenurl = "https://api.$InstanceName/api/v2/routing/queues"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
}


##### Get queue members based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudQueueMember {
    Param(
        [parameter(mandatory)][string]$ID,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 100
    if ($pageSize -gt 100) {
        Write-Warning "When retreiving queue member information, the maximum value for the pageSize parameter is 100. Setting the pageSize parameter from $pageSize to 100."
        $pageSize = 100
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the queue member info
    try {
        [guid]$ID | Out-Null
    }
    catch {
        Write-Error "The value for the sourceResponseId parameter is not a valid UUID." -RecommendedAction "Run the command again with a valid UUID formatted value for the -sourceResponseId parameter."
        exit
    }
    $tokenurl = "https://api.$InstanceName/api/v2/routing/queues/$ID/users"
    $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
    Set-Variable -Name responseHeaders -Value $response.Headers -Scope Global
    $response.Content | ConvertFrom-Json
}


##### Add a user to a GenesysCloud queue
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Add-GenesysCloudQueueMember {
    <#
    .SYNOPSIS
        Add-GenesysCloudQueueMember adds a user to a GenesysCloud Queue.
    .DESCRIPTION
        Add-GenesysCloudQueueMember adds a user to a GenesysCloud Queue.
    .PARAMETER queueId
        (string, required): The ID of the queue
    .PARAMETER userIds
        (array, required): The ID of the user or users to be added
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$queueId,
        [Parameter(Mandatory=$True)][array]$userIds,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [switch]$debugBody
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # add the user to the queue
    for ($i = 0; $i -lt $userIds.count; $i += 100) {
        $userIdChunks += ,@($userIds[$i..($i + 99)]);
    }

    # iterate through chunks
    for ($i = 0; $i -lt $userIdChunks.count; $i ++) {
        $Body = @($userIdChunks[$i] | ForEach-Object {
            @{id = $_}
        })

        if ($debugBody) {
            $Body
        }
        else {
            $Body = $Body | ConvertTo-Json -Depth 20 -AsArray
            $tokenurl = "https://api.$InstanceName/api/v2/routing/queues/$queueId/users"
            $response = Invoke-WebRequest -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
            Set-Variable -Name responseHeaders -Value $response.Headers -Scope Global
            $response.Content | ConvertFrom-Json
        }
        Start-Sleep -Seconds 1
    }
}


##### Remove a user from a GenesysCloud queue
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Remove-GenesysCloudQueueMember {
    <#
    .SYNOPSIS
        Remove-GenesysCloudQueueMember removes a user from a GenesysCloud Queue.
    .DESCRIPTION
        Remove-GenesysCloudQueueMember removes a user from a GenesysCloud Queue.
    .PARAMETER queueId
        (string, required): The ID of the queue
    .PARAMETER userId
        (string, required): The ID of the user to be removed
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or inindca.  The default is usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)]$queueId,
        [Parameter(Mandatory=$True)]$userId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # remove the user from the queue
    if ($userId.Count -gt 100) {
        $Body = @()
        foreach ($uId in $userId) {
            $Body += @{id = $uId}
        }

        $Body = $Body | ConvertTo-Json -Depth 20
        $tokenurl = "https://api.$InstanceName/api/v2/routing/queues/$queueId/users?delete=true"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    }
}


##### Get division based on object Id or by object name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudDivision {
    Param(
        $ID = $null,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving skill information, the maximum value for the pageSize parameter is 500.  Setting the pageSize parameter from $pageSize to 500"
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the division info
    if (!$ID) {
        $tokenurl = "https://api.$InstanceName/api/v2/authorization/divisions"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
    }
    else {
        if ($ID.Length -eq 36) {
            $tokenurl = "https://api.$InstanceName/api/v2/authorization/divisions/$ID"
            $divisions = Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/authorization/divisions?name=$ID"
            $divisions = (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
        foreach ($division in $divisions) {
            $division
        }
    }
}


##### Add new member object to a division
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Add-GenesysCloudDivisionMember {
    <#
    .SYNOPSIS
        Add-GenesysCloudDivisionMember assigns a new member object to a division
    .DESCRIPTION
        Add-GenesysCloudDivisionMember assigns a new member object or list of members
        objects to a division. The objects must all be of the same type, one of:
        CAMPAIGN, MANAGEMENTUNIT, FLOW, QUEUE, or USER. The body of the request is
        an array of object IDs, which are expected to be GUIDs, e.g.:
        ["206ce31f-61ec-40ed-a8b1-be6f06303998",
        "250a754e-f5e4-4f51-800f-a92f09d3bf8c"]
    .PARAMETER divisionId
        (string, required): The division ID to add members to
    .PARAMETER memberType
        (string, required): The type of the objects. Must be one of the valid object
        types.
        Valid values: QUEUE, CAMPAIGN, CONTACTLIST, DNCLIST, MESSAGINGCAMPAIGN,
        MANAGEMENTUNIT, BUSINESSUNIT, FLOW, USER
    .PARAMETER memberIds
        (array, required): An array of object IDs to be added to the division
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)][string]$divisionId,
        [Parameter(Mandatory=$True)][string][ValidateSet(
            "QUEUE","CAMPAIGN","CONTACTLIST","DNCLIST","MESSAGINGCAMPAIGN","MANAGEMENTUNIT","BUSINESSUNIT","FLOW","USER"
        )]$memberType,
        [Parameter(Mandatory=$True)][array]$memberIds,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Add the members to the division
    for ($i = 0; $i -lt $memberIds.count; $i += 50) {
        $memberIdChunks += ,@($memberIds[$i..($i + 49)]);
    }

    # iterate through chunks
    for ($i = 0; $i -lt $memberIdChunks.count; $i ++) {
        $Body = $memberIdChunks[$i] | ConvertTo-Json -AsArray

        $tokenurl = "https://api.$InstanceName/api/v2/authorization/divisions/$($divisionId)/objects/$($memberType)"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Post

        # increment group version
        $version ++
        Start-Sleep -Seconds 1
    }
}


##### Create a new division by passing name and description
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudDivision {
    <#
    .SYNOPSIS
        New-GenesysCloudDivision creates a new GenesysCloud division
    .DESCRIPTION
        New-GenesysCloudDivision creates a new GenesysCloud division
    .PARAMETER divisionName
        The divisionName parameter is a string type and is required.  It should be the
        name of the new division
    .PARAMETER divisionDescription
        The divisionDescription parameter is a string type and is optional.  It should
        be the description of the new division
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .EXAMPLE
        New-GenesysCloudDivision -divisionName "Ninja Masters"
        The above example shows how to create a new division with the name of Ninja Masters
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory=$True)]$divisionName,
        $divisionDescription,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Create the new division
    $Body = @{
        name = $divisionName
        description = $divisionDescription
    } | ConvertTo-Json -Depth 20

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    $tokenurl = "https://api.$InstanceName/api/v2/authorization/divisions"

    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Post
}


##### Get email domain based on id or name
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudEmailDomain {
    <#
    .SYNOPSIS
        Get-GenesysCloudEmailDomain is used to get a list of email routing domains
    .DESCRIPTION
        Get-GenesysCloudEmailDomain is used to get a list of email routing domains
    .PARAMETER domainId
        The domainId parameter is a string type and is optional.  It should be the
        name of the email routing domain, or should be left empty to list all email
        routing domains
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [string]$domainId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving email routing domain information, the maximum value for the pageSize parameter is 500.  Setting the pageSize parameter from $pageSize to 500"
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the email routing domain info
    if (!$domainId) {
        $tokenurl = "https://api.$InstanceName/api/v2/routing/email/domains"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
    }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/routing/email/domains/$domainId"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
    }
}


##### create email routing domain
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudEmailDomain {
    <#
    .SYNOPSIS
        New-GenesysCloudEmailDomain is used to create a new email routing domain
    .DESCRIPTION
        New-GenesysCloudEmailDomain is used to create a new email routing domain
    .PARAMETER domainId
        (string, required): Unique Id of the domain such as: example.com
    .PARAMETER mxRecordStatus
        (string, optional): Mx Record Status Valid Values: VALID, INVALID, NOT_AVAILABLE
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory=$true)][string]$domainId,
        [string]$mxRecordStatus,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the email routing domain
    if ($domainId) {
        $Body = @{
            id = $domainId
            mxRecordStatus = if ($mxRecordStatus) { $mxRecordStatus } else { "NOT_AVAILABLE" }
            subDomain = if ($domainId -match $InstanceName) { $true } else { $false }
        } | ConvertTo-Json -Depth 20
        $Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $tokenurl = "https://api.$InstanceName/api/v2/routing/email/domains"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    }
    else {
        Write-Error -Message "A domainId was not defined." -RecommendedAction "Please run the command and specify the -domainId parameter."
    }
}


##### Get route for an email domain based on id or pattern
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudEmailRoute {
    <#
    .SYNOPSIS
        Get-GenesysCloudEmailRoute is used to get a route or a list of routes for an email
        routing domain
    .DESCRIPTION
        Get-GenesysCloudEmailRoute is used to get a route or a list of routes for an email
        routing domain
    .PARAMETER domainId
        The domainId parameter is a string type and is required.  It should be the
        name of the email routing domain.
    .PARAMETER routeId
        The routeId parameter is a string type and is optional.  It should be the ID of
        the route in the email routing domain, the pattern (name) of the route in the
        email routing domain, or should be left empty to list all routes for the emai
        routing domain.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [string]$domainId,
        [string]$routeId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($AccessToken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving route information for an email routing domain, the maximum value for the pageSize parameter is 500.  Setting the pageSize parameter from $pageSize to 500"
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the email route info
    if ($domainId) {
        if ($routeId) {
            if ($routeId.Length -eq 36) {
                $tokenurl = "https://api.$InstanceName/api/v2/routing/email/domains/$domainId/routes/$routeId"
                Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
            }
            else {
                $tokenurl = "https://api.$InstanceName/api/v2/routing/email/domains/$domainId/routes?pattern=$routeId"
                (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
            }
        }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/routing/email/domains/$domainId/routes"
            (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
        }
    }
    else {
        Write-Error -Message "The domainId paramter was not specified" -RecommendedAction "Run the command again and specify the -domainId parameter."
    }
}


##### Create new route for an email routing domain
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudEmailRoute {
    <#
    .SYNOPSIS
        New-GenesysCloudEmailRoute is used to create a route for an email routing domain
    .DESCRIPTION
        New-GenesysCloudEmailRoute is used to create a route for an email routing domain
    .PARAMETER domainId
        (string, required): The domain name of the email routing domain.
    .PARAMETER pattern
        (string, required): The search pattern that the mailbox name should match.
    .PARAMETER queueId
        (string, optional): The queue ID to route the emails to.  The queue ID can be
        retreived by running the Get-GenesysCloudQueue command
    .PARAMETER priority
        (integer, optional): The priority to use for routing.
    .PARAMETER skillIds
        (array, optional): The skill IDs to use for routing.
    .PARAMETER languageId
        (string, optional): The language ID to use for routing.
    .PARAMETER fromName
        (string, required): The sender name to use for outgoing replies.
    .PARAMETER fromEmail
        (string, required): The sender email to use for outgoing replies.
    .PARAMETER flowId
        (string, optional): The flow ID to use for processing the email.
    .PARAMETER autoBcc
        (array, optional): The recipient email addresses that should be automatically
        blind copied on outbound emails associated with this InboundRoute.
    .PARAMETER spamFlowId
        (string, optional): The flow ID to use for processing inbound emails that have
        been marked as spam.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory=$true)][string]$domainId,
        [parameter(Mandatory=$true)][string]$pattern,
        [string]$queueId,
        [int]$priority,
        [array]$skillIds,
        [string]$languageId,
        [parameter(Mandatory=$true)][string]$fromName,
        [parameter(Mandatory=$true)][string]$fromEmail,
        [string]$flowId,
        [array]$autoBcc,
        [string]$spamFlowId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [switch]$debugBody
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the email route
    $Body = @{pattern = $pattern}
    if ($queueId) {$Body.Add("queue", @{id = $queueId})}
    if ($priority) {$Body.Add("priority", $priority)}
    if ($skillIds) {$Body.Add("skills", @(foreach ($id in $skillIds) {@{id = $id}}))}
    if ($languageId) {$Body.Add("language", @{id = $languageId})}
    $Body.Add("fromName", $fromName)
    $Body.Add("fromEmail", $fromEmail)
    if ($flowId) {$Body.Add("flow", @{id = $flowId})}
    if ($autoBcc) {$Body.Add("autoBcc", @(foreach ($email in $autoBcc) {@{email = $email}}))}
    if ($spamFlowId) {$Body.Add("spamFlow", @{id = $spamFlowId})}

    if ($debugBody) {
        $Body
    }
    else {
        $Body = $Body | ConvertTo-Json -Depth 20
        $tokenurl = "https://api.$InstanceName/api/v2/routing/email/domains/$domainId/routes"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    }
}


##### Get canned response library
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudCannedResponseLibrary {
    <#
    .SYNOPSIS
        Get-GenesysCloudCannedResponseLibrary is used to get a canned response library or
        a list of canned response libraries
    .DESCRIPTION
        Get-GenesysCloudCannedResponseLibrary is used to get a canned response library or
        a list of canned response libraries
    .PARAMETER libraryId
        The libraryId parameter is a string type and is optional.  It should be the
        ID of the canned response library, or can be left blank to retreive all canned
        response libraries.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [string]$libraryId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving library information for canned responses, the maximum value for the pageSize parameter is 500.  Setting the pageSize parameter from $pageSize to 500"
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the canned response library info
    if ($libraryId) {
        $tokenurl = "https://api.$InstanceName/api/v2/responsemanagement/libraries/$libraryId"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method Get
    }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/responsemanagement/libraries"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
    }
}


##### create a canned response library
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudCannedResponseLibrary {
    <#
    .SYNOPSIS
        New-GenesysCloudCannedResponseLibrary is used to create a canned response library
    .DESCRIPTION
        New-GenesysCloudCannedResponseLibrary is used to create a canned response library
    .PARAMETER libraryName
        The libraryName parameter is a string type and is required.  It should be the
        name of the new canned response library.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory=$true)][string]$libraryName,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the canned response library
    if ($libraryName) {
        $Body = @{name = $libraryName} | ConvertTo-Json -Depth 20
        $tokenurl = "https://api.$InstanceName/api/v2/responsemanagement/libraries"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    }
    else {
        Write-Error "The libraryName parameter was not set" -RecommendedAction "Please run the command again using the -libraryName parameter"
    }
}


##### remove a canned response library
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Remove-GenesysCloudCannedResponseLibrary {
    <#
    .SYNOPSIS
        Remove-GenesysCloudCannedResponseLibrary is used to remove a canned response library
    .DESCRIPTION
        Remove-GenesysCloudCannedResponseLibrary is used to remove a canned response library
    .PARAMETER libraryId
        The libraryId parameter is a string type and is required.  It should be the
        ID of the canned response library to remove.  The library ID can be retreived by
        running the Get-GenesysCloudCannedResponseLibrary command
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory=$true)][string]$libraryId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # remove the canned response library
    if ($libraryId) {
        $tokenurl = "https://api.$InstanceName/api/v2/responsemanagement/libraries/$libraryId"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method DELETE
    }
    else {
        Write-Error "The libraryName parameter was not set" -RecommendedAction "Please run the command again using the -libraryName parameter"
    }
}


##### Get canned response
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudCannedResponse {
    <#
    .SYNOPSIS
        Get-GenesysCloudCannedResponse is used to get a canned response or a list of
        canned responses for a specific canned response library
    .DESCRIPTION
        Get-GenesysCloudCannedResponse is used to get a canned response or a list of
        canned responses for a specific canned response library
    .PARAMETER libraryId
        The libraryId parameter is a string type and is optional.  It should be the
        ID of the canned response library.
    .PARAMETER responseId
        The responseId parameter is a string type and is optoinal.  It should be the
        ID of the canned response, the name of the canned response, or can left blank
        to retreive all responses.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [string]$libraryId,
        [string]$responseId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving information for canned responses, the maximum value for the pageSize parameter is 500.  Setting the pageSize parameter from $pageSize to 500"
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the canned response info
    if ($libraryId) {
        $tokenurl = "https://api.$InstanceName/api/v2/responsemanagement/responses?libraryId=$libraryId&expand=substitutionsSchema"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get).entities
    }
    else {
        try {
            [guid]$responseId | Out-Null
            $tokenurl = "https://api.$InstanceName/api/v2/responsemanagement/responses/$responseId?expand=substitutionsSchema"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method Get
        }
        catch {
            $Body = @{
                pageSize = $pageSize
                queryPhrase = $responseId
            } | ConvertTo-Json -Depth 20
            $tokenurl = "https://api.$InstanceName/api/v2/responsemanagement/responses/query"
            (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST).results.entities
        }
    }
}


##### create new canned response
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudCannedResponse {
    <#
    .SYNOPSIS
        New-GenesysCloudCannedResponse is used to create a canned response for a
        specific canned response library
    .DESCRIPTION
        New-GenesysCloudCannedResponse is used to create a canned response for a
        specific canned response library
    .PARAMETER responseName
        (string, required): The responseName parameter is the name of the canned
        response.
    .PARAMETER libraries
        (array, required): One or more library IDs that the response should be
        associated with
    .PARAMETER texts
        (array, required): One or more texts associated with the response.
    .PARAMETER interactionType
        (string, optional): The interaction type for this response. Valid Values: chat,
        email, twitter
    .PARAMETER substitutions
        (array, optional): Details about any text substitutions used in the texts for
        this response.
    .PARAMETER substitutionsSchema
        (object, optional): Metadata about the text substitutions schema
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory=$true)][string]$responseName,
        [parameter(Mandatory=$true)][array]$libraries,
        [parameter(Mandatory=$true)][array]$texts,
        [string]$interactionType,
        [array]$substitutions,
        [object]$substitutionsSchema,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [switch]$debugBody
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the new canned response info
    $Body = @{
        name = $responseName
        version = 1
        libraries = @(
            foreach ($library in $libraries) {
                @{
                    id = $library
                }
            }
        )
        texts = @(
            foreach ($text in $texts) {
                @{
                    content = $text.content
                    contentType = $text.contentType
                }
            }
        )
    }
    if ($interactionType) {$Body.Add("interactionType", $interactionType)}
    if ($substitutions) {$Body.Add("substitutions", @($substitutions))}
    if ($substitutionsSchema) {$Body.Add("substitutionsSchema", $substitutionsSchema)}

    if ($debugBody) {
        $Body
    }
    else {
        $Body = $Body | ConvertTo-Json -Depth 30 -EscapeHandling EscapeHtml
        $Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $tokenurl = "https://api.$InstanceName/api/v2/responsemanagement/responses"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    }
}


##### create a copy of a canned response
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Copy-GenesysCloudCannedResponse {
    <#
    .SYNOPSIS
        Copy-GenesysCloudCannedResponse is used to create a copy of a canned response
        for a specific canned response library
    .DESCRIPTION
        Copy-GenesysCloudCannedResponse is used to create a copy of a canned response
        for a specific canned response library
    .PARAMETER responseName
        (string, required): The new name of the canned response.
    .PARAMETER libraries
        (array, optional): One or more library IDs that the response should be
        associated with.
    .PARAMETER sourceResponseId
        (string, required): The source response ID from which to copy the settings.
    .PARAMETER sourceResponseObject
        (object, required): The source response object from which to copy the settings.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory=$true)][string]$responseName,
        [array]$libraries,
        [string]$sourceResponseId,
        [object]$sourceResponseObject,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the new canned response info
    if ($sourceResponseId) {
        if ($sourceResponseObject) {
            Write-Error -Message "Both the sourceResponseId and sourceResponseObject parameters are selected." -RecommendedAction "Run the command again and select either the -sourceResponseId parameter or the -sourceResponseObject parameter."
            exit
        }
        else {
            try {
                [guid]$sourceResponseId | Out-Null
                $sourceResponseObject = Get-GenesysCloudCannedResponse -responseId $sourceResponseId
            }
            catch {
                Write-Error "The value for the sourceResponseId parameter is not a valid UUID." -RecommendedAction "Run the command again with a valid UUID formatted value for the -sourceResponseId parameter."
                exit
            }
        }
    }
    if ($sourceResponseObject) {
        $sourceResponseObject.PSObject.Properties.Remove("id")
        $sourceResponseObject.PSObject.Properties.Remove("version")
        $sourceResponseObject.PSObject.Properties.Remove("createdBy")
        $sourceResponseObject.PSObject.Properties.Remove("dateCreated")
        $sourceResponseObject.PSObject.Properties.Remove("selfUri")
        $sourceResponseObject.name = $responseName
        if ($libraries) {$sourceResponseObject.libraries = @(foreach ($library in $libraries) {
            @{
                id = $library
            }
        })}
    }
    else {
        Write-Error -Message "Neither the sourceResponseId parameter nor the sourceResponseObject paramter are selected." -RecommendedAction "Run the command again and select either the -sourceResponseId parameter or the -sourceResponseObject parameter."
        exit
    }
    $Body = $sourceResponseObject | ConvertTo-Json -Depth 20
    $Body

    $tokenurl = "https://api.$InstanceName/api/v2/responsemanagement/responses"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST

}


##### remove a canned response
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Remove-GenesysCloudCannedResponse {
    <#
    .SYNOPSIS
        Remove-GenesysCloudCannedResponse is used to remove a canned response from a
        specific canned response library
    .DESCRIPTION
        Remove-GenesysCloudCannedResponse is used to remove a canned response from a
        specific canned response library
    .PARAMETER responseId
        (string, required): The ID of the canned response.
    .PARAMETER force
        (switch, optional): override the removal warning prompt
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory=$true)][string]$responseId,
        [switch]$force,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # remove the canned response
    if ($responseId) {
        try {
            [guid]$responseId | Out-Null
            $responseObject = Get-GenesysCloudCannedResponse -responseId $responseId -InstanceName $InstanceName -Accesstoken $Accesstoken
            if ($responseObject) {
                if ($force) {
                    Write-Warning -Message "The following Canned Response has been removed:"
                    Write-Host "Name : $($responseObject.name)"`n"ID : $($responseObject.id)" -ForegroundColor Cyan
                }
                else {
                    Write-Warning -Message "The following Canned Response will be removed:"
                    Write-Host "Name : $($responseObject.name)"`n"ID : $($responseObject.id)" -ForegroundColor Cyan
                    $answer = Read-Host -Prompt "Do you want to continue?  Please enter (Y)es to remove the Canned Response, or any other key to cancel "
                    if ($answer.ToLower() -ne "y") {
                        Write-Warning -Message "The action was cancelled, and the Canned Response will not be removed"
                        exit
                    }
                }
                $tokenurl = "https://api.$InstanceName/api/v2/responsemanagement/responses/$responseId"
                Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method DELETE
            }
            else {
                Write-Error -Message "A canned response was not found with the ID of $responseId" -RecommendedAction "Run the command again with a valid value for the -responseId parameter."
                exit
            }
        }
        catch {
            Write-Error "The value for the responseId parameter is not a valid UUID." -RecommendedAction "Run the command again with a valid UUID formatted value for the -responseId parameter."
            exit
        }
    }
    else {
        Write-Error -Message "The responseId parameter was not selected." -RecommendedAction "Run the command again and select either the -responseId."
        exit
    }
}


##### Get architect flow
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudFlow {
    <#
    .SYNOPSIS
        Get-GenesysCloudFlow is used to get a GenesysCloud interaction flow
    .DESCRIPTION
        Get-GenesysCloudFlow is used to get a GenesysCloud interaction flow
    .PARAMETER flowId
        The flowId parameter is a string type and is optional.  It should be the ID
        of the flow, the name of the flow, or left blank to retreive all flows.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [string]$flowId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving information for flows, the maximum value for the pageSize parameter is 500.  Setting the pageSize parameter from $pageSize to 500"
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the flow info
    if ($flowId) {
        try {
            [guid]$flowId | Out-Null
            $tokenurl = "https://api.$InstanceName/api/v2/flows/$($flowId)"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method GET
        }
        catch {
            $tokenurl = "https://api.$InstanceName/api/v2/flows?name=$($flowId)&includeSchemas=true"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET
        }
    }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/flows?includeSchemas=true"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET)
    }
}


##### create an architect flow
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudFlow {
    <#
    .SYNOPSIS
        New-GenesysCloudFlow is used to create a new GenesysCloud interaction flow
    .DESCRIPTION
        New-GenesysCloudFlow is used to create a new GenesysCloud interaction flow
    .PARAMETER flowName
        (string, required): The flow name
    .PARAMETER division
        (string, required): The division ID to which to assign the flow
    .PARAMETER description
        (string, required): The description of the flow
    .PARAMETER type
        (string, optional): Valid Values: COMMONMODULE, INBOUNDCALL, INBOUNDCHAT,
        INBOUNDEMAIL, INBOUNDSHORTMESSAGE, INQUEUECALL, OUTBOUNDCALL, SECURECALL,
        SPEECH, SURVEYINVITE, WORKFLOW
    .PARAMETER active
        (boolean, optional): the active status of the flow
    .PARAMETER system
        (boolean, optional): the system status of the flow
    .PARAMETER deleted
        (boolean, optional): the deleted status of the flow
    .PARAMETER inputSchema
        (object, optional): schema describing the inputs for the flow
    .PARAMETER outputSchema
        (object, optional): schema describing the outputs for the flow
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory=$true)][string]$flowName,
        [parameter(Mandatory=$true)][string]$division,
        [string]$description,
        [string]$type,
        [boolean]$active,
        [boolean]$system,
        [boolean]$deleted,
        [object]$inputSchema,
        [object]$outputSchema,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the new flow
    $Body = @{
        name = $flowName
        division = @{
            id = $division
        }
    }
    if ($description) {$Body.Add("description", $description)}
    if ($type) {$Body.Add("type", $type)}
    if ($active) {$Body.Add("active", $active)}
    if ($system) {$Body.Add("system", $system)}
    if ($deleted) {$Body.Add("deleted", $deleted)}
    if ($inputSchema) {$Body.Add("inputSchema", $inputSchema)}
    if ($outputSchema) {$Body.Add("outputSchema", $outputSchema)}
    $Body = $Body | ConvertTo-Json -Depth 20

    $tokenurl = "https://api.$InstanceName/api/v2/flows"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
}


##### Get architect flow version
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudFlowVersion {
    <#
    .SYNOPSIS
        Get-GenesysCloudFlowVersion is used to get a GenesysCloud interaction flow version
    .DESCRIPTION
        Get-GenesysCloudFlowVersion is used to get a GenesysCloud interaction flow version
    .PARAMETER flowId
        The flowId parameter is a string type and is required.  It should be the ID
        of the flow.
    .PARAMETER versionId
        The versionId parameter is a string type and is optional.  It should be the ID
        of the flow version.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(mandatory=$true)][string]$flowId,
        [string]$versionId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving information for flows, the maximum value for the pageSize parameter is 500.  Setting the pageSize parameter from $pageSize to 500"
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the flow version info
    try {
        [guid]$flowId | Out-Null
        if ($versionId) {
            $tokenurl = "https://api.$InstanceName/api/v2/flows/$($flowId)/versions/$($versionId)"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method GET
        }
        else {
            $tokenurl = "https://api.$InstanceName/api/v2/flows/$($flowId)/versions"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method GET -Body $Body
        }
    }
    catch {
        Write-Error -Message "The flowId paramter is not a valid UUID" -RecommendedAction "Run the command again and pass a valid UUID string to the -flowId paramter"
    }
}


##### create new architect flow version
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudFlowVersion {
    <#
    .SYNOPSIS
        New-GenesysCloudFlowVersion is used to create a GenesysCloud interaction flow version
    .DESCRIPTION
        New-GenesysCloudFlowVersion is used to create a GenesysCloud interaction flow version
    .PARAMETER flowId
        The flowId parameter is a string type and is required.  It should be the ID
        of the flow.
    .PARAMETER flowVersion
        The flowVersion parameter is an object type and is required.  It should be the
        object to pass as the new flow version.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(mandatory=$true)][string]$flowId,
        [parameter(mandatory=$true)][object]$flowVersion,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the flow version
    try{
        [guid]$flowId | Out-Null
    }
    catch {
        Write-Error -Message "The flowId paramter is not a valid UUID formatted ID."
        exit
    }

    $Body = $flowVersion | ConvertTo-Json -Depth 20

    $tokenurl = "https://api.$InstanceName/api/v2/flows/$($flowId)/versions"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
}


##### Get architect flow version configuration
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudFlowVersionConfiguration {
    <#
    .SYNOPSIS
        Get-GenesysCloudFlowVersionConfiguration is used to get a GenesysCloud interaction
        flow version configuration
    .DESCRIPTION
        Get-GenesysCloudFlowVersionConfiguration is used to get a GenesysCloud interaction
        flow version configuration
    .PARAMETER flowId
        The flowId parameter is a string type and is required.  It should be the ID
        of the flow.
    .PARAMETER versionId
        The versionId parameter is a string type and is required.  It should be the ID
        of the flow version.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(mandatory=$true)][string]$flowId,
        [parameter(mandatory=$true)][string]$versionId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the flow version configuration info
    try {
        [guid]$flowId | Out-Null
        $tokenurl = "https://api.$InstanceName/api/v2/flows/$($flowId)/versions/$($versionId)/configuration"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method GET
    }
    catch {
        Write-Error -Message "The flowId paramter is not a valid UUID" -RecommendedAction "Run the command again and pass a valid UUID string to the -flowId paramter"
    }
}


##### Get architect user prompt
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudUserPrompt {
    <#
    .SYNOPSIS
        Get-GenesysCloudUserPrompt is used to get a GenesysCloud Architect user prompt
    .DESCRIPTION
        Get-GenesysCloudUserPrompt is used to get a GenesysCloud Architect user prompt
    .PARAMETER promptId
        The promptId parameter is a string type and is optional.  It should be the
        ID of the prompt, the name of the prompt, or left blank to retreive all
        prompts.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [string]$promptId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving information for prompts, the maximum value for the pageSize parameter is 500.  Setting the pageSize parameter from $pageSize to 500"
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the prompt info
    if ($promptId) {
        try {
            [guid]$promptId | Out-Null
            $tokenurl = "https://api.$InstanceName/api/v2/architect/prompts/$promptId"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET
        }
        catch {
            $tokenurl = "https://api.$InstanceName/api/v2/architect/prompts?nameOrDescription=$promptId"
            (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET)
        }
    }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/architect/prompts"
        (Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET)
    }
}


##### Copy architect user prompt
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Copy-GenesysCloudUserPrompt {
    <#
    .SYNOPSIS
        Copy-GenesysCloudUserPrompt is used to create a copy of a GenesysCloud Architect
        user prompt
    .DESCRIPTION
        Copy-GenesysCloudUserPrompt is used to create a copy of a GenesysCloud Architect
        user prompt
    .PARAMETER sourcePrompt
        The sourcePrompt parameter is an object type and is required.  It should be the
        object of the source prompt.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory=$true)][object]$sourcePrompt,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer "+$Accesstoken
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the prompt
    $sourcePrompt.PSObject.Properties.Remove("currentOperation")
    $sourcePrompt.PSObject.Properties.Remove("selfUri")

    $Body = $sourcePrompt | ConvertTo-Json -Depth 20

    $tokenurl = "https://api.$InstanceName/api/v2/architect/prompts"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
}


##### Get architect schedule group
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudScheduleGroup {
    <#
    .SYNOPSIS
        Get-GenesysCloudUserScheduleGroup is used to get a GenesysCloud schedule group
    .DESCRIPTION
        Get-GenesysCloudUserScheduleGroup is used to get a GenesysCloud schedule group
    .PARAMETER scheduleGroupId
        Name or ID of the Schedule Group to filter by
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [string]$scheduleGroupId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving information for schedule groups, the maximum value for the pageSize parameter is 500.  Setting the pageSize parameter from $pageSize to 500"
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the schedule group info
    if ($scheduleGroupId) {
        try {
            [guid]$scheduleGroupId | Out-Null
            $tokenurl = "https://api.$InstanceName/api/v2/architect/schedulegroups/$($scheduleGroupId)"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method GET
        }
        catch {
            $tokenurl = "https://api.$InstanceName/api/v2/architect/schedulegroups?name=$($scheduleGroupId)"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET
        }
    }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/architect/schedulegroups"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET
    }
}


##### Get architect schedule
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudSchedule {
    <#
    .SYNOPSIS
        Get-GenesysCloudSchedule is used to get a GenesysCloud schedule
    .DESCRIPTION
        Get-GenesysCloudSchedule is used to get a GenesysCloud schedule
    .PARAMETER scheduleId
        Name or ID of the Schedule to filter by
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [string]$scheduleId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving information for schedule groups, the maximum value for the pageSize parameter is 500.  Setting the pageSize parameter from $pageSize to 500"
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the schedule group info
    if ($scheduleId) {
        try {
            [guid]$scheduleId | Out-Null
            $tokenurl = "https://api.$InstanceName/api/v2/architect/schedules/$($scheduleId)"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method GET
        }
        catch {
            $tokenurl = "https://api.$InstanceName/api/v2/architect/schedules?name=$($scheduleId)"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET
        }
    }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/architect/schedules"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET
    }
}


##### New architect schedule group
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudScheduleGroup {
    <#
    .SYNOPSIS
        New-GenesysCloudUserScheduleGroup is used to get a GenesysCloud schedule group
    .DESCRIPTION
        New-GenesysCloudUserScheduleGroup is used to get a GenesysCloud schedule group
    .PARAMETER scheduleGroupName
        (string, required): The name of the entity.
    .PARAMETER description
        (string, optional): The resource's description.
    .PARAMETER timeZone
        (string, optional): The timezone the schedules are a part of. This is not a
        schedule property to allow a schedule to be used in multiple timezones.
    .PARAMETER openSchedules
        (array of schedule objects, optional): The schedules defining the hours an
        organization is open.
    .PARAMETER closedSchedules
        (array of schedule objects, optional): The schedules defining the hours an
        organization is closed.
    .PARAMETER holidaySchedules
        (array of schedule objects, optional): The schedules defining the hours an
        organization is closed for the holidays.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory)][string]$scheduleGroupName,
        [string]$description,
        [string]$timeZone,
        [array]$openSchedules,
        [array]$closedSchedules,
        [array]$holidaySchedules,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the schedule group
    $Body = @{name = $scheduleGroupName}
    if ($description) {$Body.Add("description",$description)}
    if ($timeZone) {$Body.Add("timeZone",$timeZone)}
    if ($openSchedules) {$Body.Add("openSchedules",@($openSchedules))}
    if ($closedSchedules) {$Body.Add("closedSchedules",@($closedSchedules))}
    if ($holidaySchedules) {$Body.Add("holidaySchedules",@($holidaySchedules))}
    $Body = $Body | ConvertTo-Json -Depth 30

    $tokenurl = "https://api.$InstanceName/api/v2/architect/schedulegroups"
    Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
}


##### New architect schedule
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function New-GenesysCloudSchedule {
    <#
    .SYNOPSIS
        New-GenesysCloudSchedule is used to create a new GenesysCloud schedule
    .DESCRIPTION
        New-GenesysCloudSchedule is used to create a new GenesysCloud schedule
    .PARAMETER scheduleName
        (string, required): The name of the schedule.
    .PARAMETER description
        (string, optional): The schedule's description.
    .PARAMETER start
        (string, required): Date time is represented as an ISO-8601 string without
        a timezone. For example: yyyy-MM-ddTHH:mm:ss.SSS
    .PARAMETER end
        (string, required): Date time is represented as an ISO-8601 string without
        a timezone. For example: yyyy-MM-ddTHH:mm:ss.SSS
    .PARAMETER rrule
        (string, required): An iCal Recurrence Rule (RRULE) string.
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [parameter(Mandatory)][string]$scheduleName,
        [string]$description,
        [parameter(Mandatory)][string]$start,
        [parameter(Mandatory)][string]$end,
        [string]$rrule,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [switch]$debugBody
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # create the new schedule
    $Body = @{
        name = $scheduleName
        start = $start
        end = $end
    }
    if ($description) {$Body.Add("description",$description)}
    if ($rrule) {$Body.Add("rrule",$rrule)}

    if ($debugBody) {
        $Body
    }
    else {
        $Body = $Body | ConvertTo-Json -Depth 20
        $tokenurl = "https://api.$InstanceName/api/v2/architect/schedules"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method POST
    }
}


##### Get integration
##### uses usw2.pure.cloud and the Developer Tools OAuth Application by default
function Get-GenesysCloudIntegration {
    <#
    .SYNOPSIS
        Get-GenesysCloudIntegration is used to get a GenesysCloud integration
    .DESCRIPTION
        Get-GenesysCloudIntegration is used to get a GenesysCloud integration
    .PARAMETER integrationId
        Name or ID of the integration to filter by
    .PARAMETER InstanceName
        The InstanceName parameter is a string type, and is the name of the GenesysCloud
        environemt, e.g.: usw2.pure.cloud or usw2.pure.cloud.  The default is
        usw2.pure.cloud
    .PARAMETER AccessToken
        The AccessToken parameter is a string type, and will be automatically acquired
        if the function detects that it is missing.  This can also be manually acquired
        and saved to a custom variable, then passed into the AccessToken parameter
    .PARAMETER pageSize
        The pageSize parameter is an integer type, and is used to determine how many API
        objects are returned from the API request.  The default is 25
    .PARAMETER pageNumber
        The pageNumber parameter is an integer type, and is used to determine what page of
        data is returned from the API request.  The default is 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [string]$integrationId,
        [string]$InstanceName = "usw2.pure.cloud",
        [string]$Accesstoken = $ClientAccessToken,
        [int]$pageSize = 25,
        [int]$pageNumber = 1
    )

    # Check to see if an access token has been aqcuired
    if (!($Accesstoken)) {
        $Accesstoken = Get-GenesysCloudAccessToken -InstanceName $InstanceName
    }

    # Check to see if the pageSize parameter exceeds a value of 500
    if ($pageSize -gt 500) {
        Write-Warning "When retreiving information for integrations, the maximum value for the pageSize parameter is 500.  Setting the pageSize parameter from $pageSize to 500"
        $pageSize = 500
    }

    $Body = @{
        pageSize=$pageSize
        pageNumber=$pageNumber
        sortBy="name"
    }

    $Headers = @{
        authorization = "Bearer $Accesstoken"
        "Content-Type" = "application/json; charset=UTF-8"
    }

    # Get the integration info
    if ($integrationId) {
        try {
            [guid]$integrationId | Out-Null
            $tokenurl = "https://api.$InstanceName/api/v2/integrations/$($integrationId)"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Method GET
        }
        catch {
            $tokenurl = "https://api.$InstanceName/api/v2/integrations/$($integrationId)"
            Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET
        }
    }
    else {
        $tokenurl = "https://api.$InstanceName/api/v2/integrations"
        Invoke-RestMethod -Uri $tokenurl -Headers $Headers -Body $Body -Method GET
    }
}


















################################################################################################################################################
################################################################################################################################################
################################################################################################################################################
##### Create aliases for functions: *GenesysCloud* --> *GenesysCloud* #####
(Get-Module -ListAvailable -Name GenesysCloud).ExportedFunctions.Values | ForEach-Object {
    if ($_.Name -like "*GenesysCloud*") {
        $aliasName = $_.Name.Replace("GenesysCloud","GenesysCloud")
        $commandName = $_.Name
        try {
            Get-Alias $aliasName -ErrorAction Stop
        }
        catch {
            New-Alias -Name $aliasName -Value $commandName
        }
    }
}
