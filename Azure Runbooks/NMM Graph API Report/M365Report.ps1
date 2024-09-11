<#
Version: 0.1
Author: Jan Scholte | Nerdio

Todo:
- Add more reports
- Create function for authentication support managed identity and interactive login
- Try to automatically configure the managed identity on th automation account and set the needed graph permissions on the managed identity
#>

#$TenantId = $EnvironmentalVars.TenantId #Tenant ID of the Azure AD
$TenantId = '9f563539-3e60-4e96-aff7-915a7b66fb7a'

# Define the parameters for splatting
$params = @{
    Scopes   = @(
        "Reports.Read.All",
        "ReportSettings.Read.All",
        "User.Read.All",
        "Group.Read.All",
        "Mail.Read",
        "Mail.Send",
        "Calendars.Read",
        "Sites.Read.All",
        "Directory.Read.All"
        "RoleManagement.Read.Directory"
        "AuditLog.Read.All"
        "Organization.Read.All"
    )
    TenantId = $TenantId
}


try {
    #Connect to MS Graph
    Connect-MgGraph @params
}
catch {
    $_.Exception.Message
}

#Start of Report Functions
############################################################################################################

function Get-LicenseDetails {
    [CmdletBinding(DefaultParameterSetName = 'LicenseID')]
    param (
        [Parameter(ParameterSetName = 'LicenseID', Mandatory = $true)]
        [string[]]$LicenseId,

        [Parameter(ParameterSetName = 'All', Mandatory = $true)]
        [switch]$All
    )

    # Fetch all licenses once
    $AllLicenses = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/subscribedSkus/" -OutputType PSObject).Value

    if ($PSCmdlet.ParameterSetName -eq 'LicenseID') {
        # List to store selected license names
        $licenseList = [System.Collections.Generic.List[Object]]::new()

        foreach ($license in $LicenseId) {
            # Find the matching license by skuId
            $MatchskuID = $AllLicenses | Where-Object { $_.skuId -eq $license }
            if ($MatchskuID) {
                # Get friendly license name using the LicenseConversionTable function
                $FriendlyLicName = LicenseConversionTable -LicenseId $MatchskuID.skuId
                $licenseList.Add($FriendlyLicName)
            }
            else {
                Write-Warning "License ID $license not found in AllLicenses"
            }
        }

        return $licenseList
    }

    if ($PSCmdlet.ParameterSetName -eq 'All') {
        # Return all licenses
        return $AllLicenses
    }
}
function LicenseConversionTable {
    param (
        [Parameter(ValueFromPipeline = $true)]
        [string]$LicenseId
    )
    
    begin {
        try {
            # Define repository details
            $repoOwner = "Get-Nerdio"
            $repoName = "NMM-SE"
            $filePath = "Azure Runbooks/NMM Graph API Report/LicenseConversionTable.csv"
            $apiUrl = "https://api.github.com/repos/$repoOwner/$repoName/contents/$filePath"
        
            # Send request to GitHub API and store the content in the begin block
            $response = Invoke-RestMethod -Uri $apiUrl -Headers @{Accept = "application/vnd.github.v3+json" }
        
            # Decode the base64-encoded content
            $encodedContent = $response.content
            $decodedContent = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encodedContent))
        
            # Convert the CSV content into a PowerShell object
            $allConvertedLicense = $decodedContent | ConvertFrom-Csv
        }
        catch {
            Write-Error "Error fetching or decoding the CSV file: $_"
        }
    }

    process {
        try {
            # Find the matching GUID in the table for the current LicenseId
            $matchedLicense = $allConvertedLicense | Where-Object { $_.GUID -eq $LicenseId } | Select-Object -First 1

            # Output the matching license
            return $matchedLicense.Product_Display_Name
        }
        catch {
            Write-Error "Error processing LicenseId $LicenseId : $_"
        }
    }
}
function Get-AssignedRoleMembers {
    
    try {
        # Report on all users and their roles
        $roles = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/directoryRoles"

        # Create a hashtable to store the user-role assignments
        $userRoles = @{}

        # Iterate over each role and get its members
        foreach ($role in $roles.value) {
            $roleId = $role.id
            $roleName = $role.displayName
 
            # Retrieve the members of the role
            $members = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/directoryRoles/$roleId/members" -OutputType PSObject
 
            # Iterate through the members
            foreach ($member in $members.value) {
                $userPrincipalName = $member.userPrincipalName
                $displayName = $member.displayName
                $id = $member.id

                # If the user is already in the hashtable, append the role using .Add()
                if ($userRoles.ContainsKey($userPrincipalName)) {
                    $userRoles[$userPrincipalName].Roles.Add($roleName)
                }
                else {
                    # Create a new user object with their roles (using List for Roles)
                    $userRoles[$userPrincipalName] = [PSCustomObject]@{
                        UserPrincipalName = $userPrincipalName
                        DisplayName       = $displayName
                        Id                = $id
                        Roles             = [System.Collections.Generic.List[string]]::new()
                    }
                    $userRoles[$userPrincipalName].Roles.Add($roleName)
                }
            }
        }

        # Convert hashtable values to a list and format roles as a comma-separated string
        $roleAssignments = $userRoles.Values | ForEach-Object {
            [PSCustomObject]@{
                UserPrincipalName = $_.UserPrincipalName
                DisplayName       = $_.DisplayName
                Id                = $_.Id
                Roles             = ($_.Roles -join ", ")  # Convert list to a comma-separated string
            }
        }

        # Output the results
        return $roleAssignments
    }
    catch {
        $_.Exception.Message
    }
}
function Get-InactiveUsers {
    param(
        [int]$DaysInactive = 30
    )

    try {
        # Get the date 30 days ago in UTC format and format it as required
        $cutoffDate = (Get-Date).AddDays(-$DaysInactive).ToUniversalTime()
        $cutoffDateFormatted = $cutoffDate.ToString("yyyy-MM-ddTHH:mm:ssZ")

        # Get users whose last sign-in is before the cutoff date
        $signIns = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/users?`$filter=signInActivity/lastSuccessfulSignInDateTime le $cutoffDateFormatted" -OutputType PSObject).value

        if ($null -eq $signIns) {
            return "No inactive users found"
        }
        else {
            # Process the results to identify inactive users
            $inactiveUsers = [System.Collections.Generic.List[Object]]::new()

            foreach ($user in $signIns) {
                $inactiveUser = [PSCustomObject]@{
                    DisplayName       = $user.displayName
                    UserPrincipalName = $user.userPrincipalName
                    Id                = $user.id
                    #LastSignIn        = $user.signInActivity.lastSuccessfulSignInDateTime
                    AssignedLicenses  = (GetLicenseDetails -LicenseId $user.assignedLicenses.skuId).Split(",")
                    UsageLocation     = $user.usageLocation
                    AccountEnabled    = $user.accountEnabled
                }

                # Add to the inactive users list
                $inactiveUsers.Add($inactiveUser)
            }

            # Return the list of inactive users
            if ($inactiveUsers.Count -eq 0) {
                return [PSCustomObject]@{
                    Info = "No inactive users found"
                }
            }
            else {
                return $inactiveUsers
            }
        }
        
    }
    catch {
        $_.Exception.Message
    }
}
function Get-UnusedLicenses {
    # Retrieve all licenses
    $AllLicenses = Get-LicenseDetails -All

    # List to store the results
    $UnusedLicensesList = [System.Collections.Generic.List[Object]]::new()

    # Loop through each license
    foreach ($license in $AllLicenses) {
        # Calculate unused licenses
        $prepaidEnabled = $license.prepaidUnits.enabled
        $consumedUnits = $license.consumedUnits
        $unusedUnits = $prepaidEnabled - $consumedUnits

        # Only process if there are unused units
        if ($unusedUnits -gt 0) {
            # Get the friendly license name using LicenseConversionTable
            $friendlyName = LicenseConversionTable -LicenseId $license.skuId

            # Create a PSCustomObject for each license with unused units
            $licenseObject = [PSCustomObject]@{
                AccountName   = $license.accountName
                AccountId     = $license.accountId
                SkuPartNumber = $license.skuPartNumber
                SkuId         = $license.skuId
                FriendlyName  = $friendlyName
                PrepaidUnits  = $prepaidEnabled
                ConsumedUnits = $consumedUnits
                UnusedUnits   = $unusedUnits
                AppliesTo     = $license.appliesTo
            }

            # Add to the result list
            $UnusedLicensesList.add($licenseObject)
        }
    }

    # Return the list of unused licenses
    return $UnusedLicensesList
}
function Get-RecentEnterpriseAppsAndRegistrations {
    try {
        # Calculate the date for 30 days ago
        $dateThreshold = (Get-Date).AddDays(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")

        # Get enterprise applications (service principals)
        $enterpriseApps = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -OutputType PSObject
        $recentEnterpriseApps = $enterpriseApps.value | Where-Object { $_.createdDateTime -ge $dateThreshold }

        # Get app registrations (applications)
        $appRegistrations = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/applications" -OutputType PSObject
        $recentAppRegistrations = $appRegistrations.value | Where-Object { $_.createdDateTime -ge $dateThreshold }

        # Combine results into a single list
        $recentApps = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($app in $recentEnterpriseApps) {
            $recentApps.Add([PSCustomObject]@{
                    AppType         = "Enterprise Application"
                    AppId           = $app.appId
                    DisplayName     = $app.displayName
                    CreatedDateTime = $app.createdDateTime
                })
        }

        foreach ($app in $recentAppRegistrations) {
            $recentApps.Add([PSCustomObject]@{
                    AppType         = "App Registration"
                    AppId           = $app.appId
                    DisplayName     = $app.displayName
                    CreatedDateTime = $app.createdDateTime
                })
        }

        # Return the list of recent apps
        return $recentApps
    }
    catch {
        $_.Exception.Message
    }
}
function Get-RecentGroupsAndAddedMembers {
    try {
        # Calculate the date for 30 days ago
        $dateThreshold = (Get-Date).AddDays(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")

        # Get groups created in the last 30 days
        $groups = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/groups" -OutputType PSObject
        $recentGroups = $groups.value | Where-Object { $_.createdDateTime -ge $dateThreshold }

        # Get all "Add member to group" actions from audit logs in the last 30 days
        $auditLogs = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?`$filter=activityDisplayName eq 'Add member to group' and activityDateTime ge $dateThreshold and result eq 'success'&`$orderby=activityDateTime desc" -OutputType PSObject

        # Create a list to store the group details and recent members
        $groupDetails = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($group in $recentGroups) {
            $groupId = $group.id
            $groupName = $group.displayName

            # Create a list to store recent members
            $recentMembers = [System.Collections.Generic.List[string]]::new()

            foreach ($log in $auditLogs.value) {
                
                $groupObjectId = ($log.targetResources.modifiedProperties | Where-Object { $_.displayName -eq "Group.ObjectID" } | Select-Object -ExpandProperty newValue) -replace '"', ''

                if ($groupObjectId -eq $groupId) {
                    # Extract the userPrincipalName for the user added to the group
                    $user = $log.targetResources | Where-Object { $_.type -eq "User" }
                    if ($user) {
                        $recentMembers.Add($user.userPrincipalName)
                    }
                }
            }

            # Prepare a comma-separated string of recent members' names
            $recentMemberNames = $recentMembers -join ", "

            # Add group details with recent members to the list
            $groupDetails.Add([PSCustomObject]@{
                    GroupName       = $groupName
                    GroupId         = $groupId
                    CreatedDateTime = $group.createdDateTime
                    RecentMembers   = if ($recentMemberNames) { $recentMemberNames } else { "No recent members" }
                })
        }

        # Output the results
        return $groupDetails
    }
    catch {
        $_.Exception.Message
    }
}
function ConvertTo-ObjectToHtmlTable {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[Object]]$Objects
    )

    $sb = New-Object System.Text.StringBuilder
    # Start the HTML table with modernized styling
    [void]$sb.Append('<table style="border-collapse: collapse; width: 100%; font-family: Inter; margin-bottom: 20px;">')
    [void]$sb.Append('<thead><tr style="background-color: #13BA7C; color: white;">')

    # Add column headers based on the properties of the first object
    $Objects[0].PSObject.Properties.Name | ForEach-Object {
        [void]$sb.Append("<th style='border: 1px solid #ddd; padding: 12px; text-align: left;'>$_</th>")
    }

    [void]$sb.Append('</tr></thead><tbody>')

    # Add table rows with alternating row colors
    $rowIndex = 0
    foreach ($obj in $Objects) {
        $rowColor = if ($rowIndex % 2 -eq 0) { "background-color: #f9f9f9;" } else { "background-color: #ffffff;" }
        $rowIndex++

        [void]$sb.Append("<tr style='$rowColor border: 1px solid #ddd;'>")
        foreach ($prop in $obj.PSObject.Properties.Name) {
            [void]$sb.Append("<td style='border: 1px solid #ddd; padding: 12px;'>$($obj.$prop)</td>")
        }
        [void]$sb.Append('</tr>')
    }

    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}
function Get-RecentDevices {
    try {
        # Calculate the date for 30 days ago
        $dateThreshold = (Get-Date).AddDays(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")

        # Get devices added in the last 30 days
        $devices = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/devices" -OutputType PSObject
        $recentDevices = $devices.value | Where-Object { $_.createdDateTime -ge $dateThreshold }

        # Create a list to store the recent devices
        $deviceDetails = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($device in $recentDevices) {
            # Add device details to the list
            $deviceDetails.Add([PSCustomObject]@{
                    DisplayName      = $device.displayName    
                    DeviceId         = $device.id
                    OperatingSystem  = "$($device.operatingSystem) - $($device.operatingSystemVersion)"
                    CreatedDateTime  = $device.createdDateTime
                    TrustType        = $device.deviceTrustType
                    RegistrationDate = $device.registeredDateTime
                })
        }

        # Output the results
        return $deviceDetails
    }
    catch {
        Write-Error "Error retrieving devices: $_"
    }
}
function Generate-Report {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable]$DataSets, # Accepts multiple datasets, each with a title

        [Parameter(Mandatory = $false)]
        [switch]$Json,

        [Parameter(Mandatory = $false)]
        [switch]$PsObject,

        [Parameter(Mandatory = $false)]
        [switch]$RawHTML,

        [Parameter(Mandatory = $false)]
        [switch]$Html,

        [Parameter(Mandatory = $false)]
        [string]$HtmlOutputPath = "Report.html",

        [Parameter(Mandatory = $false)]
        [string]$LogoUrl = "https://github.com/Get-Nerdio/NMM-SE/assets/52416805/5c8dd05e-84a7-49f9-8218-64412fdaffaf",

        [Parameter(Mandatory = $false)]
        [string]$SummaryText = "This report shows information about your Microsoft 365 environment.",

        [Parameter(Mandatory = $false)]
        [string]$FontFamily = "Inter"  # Allow user to specify a custom font family
    )

    begin {
        # Initialize a string builder for HTML content
        $htmlContent = New-Object System.Text.StringBuilder
    }

    process {
        # Create a header section with the logo, summary, and font for HTML output
        if ($Html -or $RawHTML) {
            [void]$htmlContent.Append("<html><head><title>Report</title>")

            # Inline CSS for font-family and overall modern styling
            [void]$htmlContent.Append("<style>")
            [void]$htmlContent.Append("body { font-family: '$FontFamily'; background-color: #f4f7f6; margin: 0; padding: 0; }")
            [void]$htmlContent.Append("h2 { color: #FFFFFF; }")
            [void]$htmlContent.Append("h3 { color: #151515; margin-top: 20px; }")
            [void]$htmlContent.Append(".report-header { background-color: #13BA7C; color: white; padding: 20px 0; text-align: center; }")
            [void]$htmlContent.Append(".content { padding: 20px; }")
            [void]$htmlContent.Append("</style>")

            [void]$htmlContent.Append("</head><body>")

            # Add a header section with a logo and summary text
            [void]$htmlContent.Append("<div class='report-header'>")
            [void]$htmlContent.Append("<img src='$LogoUrl' style='width: 150px; height: auto;' alt='Logo' /><br/>")
            [void]$htmlContent.Append("<h2>Microsoft 365 Tenant Report</h2>")
            [void]$htmlContent.Append("<p>$SummaryText</p>")
            [void]$htmlContent.Append("</div>")

            [void]$htmlContent.Append("<div class='content'>")
        }

        # Iterate through the datasets in the hashtable
        foreach ($key in $DataSets.Keys) {
            $sectionTitle = $key   # The title for the section is the hashtable key
            $data = $DataSets[$key]  # The data for this section is the hashtable value

            if ($Html -or $RawHTML) {
                [void]$htmlContent.Append("<h3>$sectionTitle</h3>")  # Add a section title
                [void]$htmlContent.Append((ConvertTo-ObjectToHtmlTable -Objects $data))  # Convert the data to an HTML table
            }
        }

        # HTML Output: Close the content section and body
        if ($Html) {
            [void]$htmlContent.Append("</div></body></html>")
            $htmlContentString = $htmlContent.ToString()
            Set-Content -Path $HtmlOutputPath -Value $htmlContentString
            Write-Host "HTML report generated at: $HtmlOutputPath"
        }

        # Raw HTML Output
        if ($RawHTML) {
            [void]$htmlContent.Append("</div></body></html>")
            $htmlContentString = $htmlContent.ToString()
            return $htmlContentString
        }

        # JSON Output
        if ($Json) {
            return $DataSets | ConvertTo-Json
        }

        # PSObject Output
        if ($PsObject) {
            return $DataSets
        }
    }
}
function Send-EmailWithGraphAPI {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Recipient, # The recipient's email address

        [Parameter(Mandatory = $true)]
        [string]$Subject, # The subject of the email

        [Parameter(Mandatory = $true)]
        [string]$HtmlBody, # The HTML content to send

        [Parameter(Mandatory = $false)]
        [switch]$Attachment, # Switch to attach the HTML content as a file

        [Parameter(Mandatory = $false)]
        [string]$Sender = "me"  # Use "me" for the authenticated user, or specify another sender
    )

    try {
        # Create the email payload with correct emailAddress structure
        $emailPayload = @{
            message         = @{
                subject      = $Subject
                body         = @{
                    contentType = "HTML"
                    content     = $HtmlBody
                }
                toRecipients = @(@{
                        emailAddress = @{
                            address = $Recipient
                        }
                    })
            }
            saveToSentItems = "true"
        }

        # If the -Attachment parameter is set, attach the HTML content as a file
        if ($Attachment) {
            # Convert the HTML body content to base64
            $htmlFileBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($HtmlBody))

            # Add the attachment to the email payload
            $emailPayload.message.attachments = @(@{
                    '@odata.type' = "#microsoft.graph.fileAttachment"
                    name          = "Report.html"
                    contentType   = "text/html"
                    contentBytes  = $htmlFileBase64
                })
        }

        # Convert the payload to JSON with increased depth
        $jsonPayload = $emailPayload | ConvertTo-Json -Depth 10

        # Send the email using Microsoft Graph API
        Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/$Sender/sendMail" `
            -Method POST `
            -Body $jsonPayload `
            -ContentType "application/json"
                              
        Write-Host "Email sent successfully to $Recipient"
    }
    catch {
        Write-Error "Error sending email: $_"
    }
}

#End of Report Functions
############################################################################################################

# Save Data in Vars
$unusedLicenses = Get-UnusedLicenses
$AssignedRoles = Get-AssignedRoleMembers
$inactiveUsers = Get-InactiveUsers
$AppsAndRegistrations = Get-RecentEnterpriseAppsAndRegistrations
$GroupsAndMembers = Get-RecentGroupsAndAddedMembers
$recentDevices = Get-RecentDevices 


# Create a hashtable where the keys are the section titles and the values are the datasets
$dataSets = @{
    "Unused Licenses"              = $unusedLicenses
    "AssignedRoles"                = $AssignedRoles
    "Inactive Users"               = $inactiveUsers
    "Enterprise App Registrations" = $AppsAndRegistrations
    "Recent Groups and Members"    = $GroupsAndMembers
    "Recent Devices"               = $recentDevices
}

# Generate the HTML report and send it via email
$htmlcontent = Generate-Report -DataSets $dataSets -RawHTML -Html -HtmlOutputPath ".\M365Report.html"

Send-EmailWithGraphAPI -Recipient "test@msp.com" -Subject "M365 Report - $(Get-Date -Format "yyyy-MM-dd")" -HtmlBody $htmlContent -Attachment




