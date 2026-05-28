Import-Module WebAdministration

class DeploySlot {
    [string]$IISWebsiteName
    [string]$WebRootDirectory
    [string]$Port
    [string]$FarmServerName
}

function New-DeploySlot {
    param (
        [string]$IISWebsiteName,
        [string]$WebRootDirectory,
        [string]$Port,
        [string]$FarmServerName
    )

    $slot = [DeploySlot]::new()
    $slot.IISWebsiteName = $IISWebsiteName
    $slot.WebRootDirectory = $WebRootDirectory
    $slot.Port = $Port
    $slot.FarmServerName = $FarmServerName  

    return $slot
}

function Ensure-HostFileEntry {
    param(
        [string]$DesiredIP = "127.0.0.1",
        [Parameter(Mandatory=$true)]
        [string]$Hostname,
        [string] $Comment = $null,
        [Parameter(Mandatory=$false)]
	    [bool]$CheckHostnameOnly = $false
    )
    #Requires -RunAsAdministrator
    # SOURCE: https://github.com/TomChantler/EditHosts, but edited to include an optional comment on the host record
    
    $hostsFilePath = "$($Env:WinDir)\system32\Drivers\etc\hosts"
    $hostsFileText = Get-Content $hostsFilePath

    Write-Host "About to add $desiredIP for $Hostname to hosts file" -ForegroundColor Gray

    $escapedHostname = [Regex]::Escape($Hostname)
    $patternToMatch = If ($CheckHostnameOnly) { ".*\s+$escapedHostname.*" } Else { ".*$DesiredIP\s+$escapedHostname.*" }
    If (($hostsFileText) -match $patternToMatch)  {
        Write-Host $desiredIP.PadRight(20," ") "$Hostname - not adding; already in hosts file" -ForegroundColor DarkYellow
    } 
    Else {
        $newEntry = "$DesiredIP".PadRight(20, " ") + "$Hostname" + ($Comment ? " # $Comment" : "")
        Write-Host "Adding to hosts file... $newEntry" -ForegroundColor Yellow -NoNewline
        Add-Content -Encoding UTF8  $hostsFilePath $newEntry
        Write-Host " done"
    }
}

function Remove-HostFileEntry {
    # SOURCE: Tom Chantler - https://tomssl.com/2019/04/30/a-better-way-to-add-and-remove-windows-hosts-file-entries/
    param(
        [Parameter(Mandatory=$true)]
        [string]$Hostname
    )
    # Remove entry from hosts file. Removes all entries that match the hostname (i.e. both IPv4 and IPv6).
    #Requires -RunAsAdministrator
    
    $hostsFilePath = "$($Env:WinDir)\system32\Drivers\etc\hosts"
    $hostsFile = Get-Content $hostsFilePath
    Write-Host "About to remove $Hostname from hosts file" -ForegroundColor Gray
    $escapedHostname = [Regex]::Escape($Hostname)
    If (($hostsFile) -match ".*\s+$escapedHostname.*")  {
        Write-Host "$Hostname - removing from hosts file... " -ForegroundColor Yellow -NoNewline
        $hostsFile -notmatch ".*\s+$escapedHostname.*" | Out-File $hostsFilePath 
        Write-Host " done"
    } 
    Else {
        Write-Host "$Hostname - not in hosts file (perhaps already removed); nothing to do" -ForegroundColor DarkYellow
    }
}

function Ensure-WebFarmServer {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FarmName,
        [Parameter(Mandatory=$true)]
        [string]$OutboundAddress,
        [Parameter(Mandatory=$false)]
        [int]$OutboundPort
    )
    Write-Host "Ensuring Web Farm Server for slot"
    if (-Not (Get-WebConfiguration -Filter "webFarms/webFarm[@name='$FarmName']/server[@address='$OutboundAddress']" -ErrorAction SilentlyContinue)) {
        $serverProperties = @{address=$OutboundAddress; enabled='true'; }
        if ($OutboundPort) {
            $serverProperties["applicationRequestRouting"] = @{httpPort = $OutboundPort}
        }
        Add-WebConfiguration -Filter "webFarms/webFarm[@name='$FarmName']" -Value $serverProperties
        Write-Host "Created Web Farm Server: $OutboundAddress in farm: $FarmName"
    }
    else {
        Write-Host "Web Farm Server: $OutboundAddress already exists in farm: $FarmName"
    }
}

function Set-WebFarmServerEnabledState {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FarmName,
        [Parameter(Mandatory=$true)]
        [string]$ServerAddress,
        [Parameter(Mandatory=$true)]
        [bool]$Enabled
    )
    Write-Host "Setting enabled state of Web Farm Server for slot to: $Enabled"
    Set-WebConfigurationProperty -Filter "webFarms/webFarm[@name='$FarmName']/server[@address='$ServerAddress']" -Name "enabled" -Value ($Enabled.ToString().ToLower())
}

function Get-WebFarmServerEnabledState {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FarmName,
        [Parameter(Mandatory=$true)]
        [string]$ServerAddress
    )
    $configRecord = (Get-WebConfigurationProperty -Filter "webFarms/webFarm[@name='$FarmName']/server[@address='$ServerAddress']" -Name 'enabled')
    return [System.Convert]::ToBoolean($configRecord.Value)
}

function Enable-WebFarmServer {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FarmName,
        [Parameter(Mandatory=$true)]
        [string]$ServerAddress
    )
    Set-WebFarmServerEnabledState -FarmName $FarmName -ServerAddress $ServerAddress -Enabled $true
}

function Disable-WebFarmServer {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FarmName,
        [Parameter(Mandatory=$true)]
        [string]$ServerAddress
    )
    Set-WebFarmServerEnabledState -FarmName $FarmName -ServerAddress $ServerAddress -Enabled $false
}

function Ensure-Website {
    param (
        [Parameter(Mandatory=$true)]
        [string]$WebsiteName,
        [Parameter(Mandatory=$true)]
        [string]$WebRootDirectory,
        [Parameter(Mandatory=$true)][int]$Port
    )
    
    # IMPORTANT: The version of IIS we have on our webserver does not consistently handle forward slashes in paths. 
    #            The website will look fine in the IIS explorer, but will refuse to serve if the PhysicalPath has forward slashes instead of backslashes
    Write-Host "Ensuring iis directory: $($WebRootDirectory)"
    New-Item -ItemType Directory -Force -Path $WebRootDirectory 

    $normalizedPath = (Resolve-Path $WebRootDirectory).Path
    Write-Host "Ensuring website for slot: $($WebsiteName) with web root: $($normalizedPath) on port: $($Port)"
    
    Write-Host "Ensuring IIS application pool: $($WebsiteName)"
    if (-Not (Get-WebAppPoolState -Name $WebsiteName -ErrorAction SilentlyContinue)) {
        New-WebAppPool -Name $WebsiteName 
        Write-Host "Created IIS application pool: $($WebsiteName)"
    } else {
        Write-Host "IIS application pool: $($WebsiteName) already exists"
    }

    Write-Host "Ensuring IIS website: $($WebsiteName) with web root: $($normalizedPath) on port: $($Port)"
    if (-Not (Get-Website $WebsiteName )) {
        New-WebSite -Name $WebsiteName -Port $Port -PhysicalPath $normalizedPath -ApplicationPool $WebsiteName 
        Write-Host "Created IIS website: $($WebsiteName) on port: $($Port)"
    } else {
        Set-WebConfigurationProperty -Filter "system.applicationHost/sites/site[@name='$($WebsiteName)']" -Name "physicalPath" -Value $normalizedPath | Out-Null
        Set-WebConfigurationProperty -Filter "system.applicationHost/sites/site[@name='$($WebsiteName)']" -Name "bindings/binding[@protocol='http' and @bindingInformation='*:$($Port):']" -Value "*:$($Port):" | Out-Null
        Write-Host "IIS website: $($WebsiteName) already exists; updated physical path and port"
    }
}

function Has-Direct-Acl {
    param(
        [string] $Path,
        [System.Security.AccessControl.FileSystemRights] $Access,
        [string] $UserId
        )
    # WARNING: this won't be 100% accurate.
    #       It doesn't account for how different rule overlap.
    #       It also doesn't resolve user groups. So if a user has access through a group it won't show
    #       Sadly, there doesn't appear to be any built-in way for checking if a user has a permission
    $acl = (Get-Acl $Path)

    $matching = $acl.Access | Where-Object { 
        ($_.IdentityReference.Value -ieq $UserId) -and ($_.FileSystemRights.HasFlag($access)) -and ($_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow) 
    }

    if($matching){
        return $true
    }
    else{
        return $false
    }
}

function Add-Acl {
    param(
        [string] $Path,
        [System.Security.AccessControl.FileSystemRights] $Access,
        [string] $UserId,
        [switch] $Inherit
    )
    Write-Host "Adding ACL for UserId: $($UserId); Access: $($Access); Path: $($Path)"
    $acl = Get-Acl $Path
    
    $inheritance = $Inherit ? ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit + [System.Security.AccessControl.InheritanceFlags]::ObjectInherit) : [System.Security.AccessControl.InheritanceFlags]::None
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $accessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($UserId, $Access, $inheritance, $propagation, "Allow")
    $acl.AddAccessRule($accessRule)
    Set-Acl $Path $acl

    Write-Host "Created ACL for UserId: $($UserId); Access: $($Access); Path: $($Path)"
}

function Ensure-Acl {
    param(
        [string] $Path,
        [System.Security.AccessControl.FileSystemRights] $Access,
        [string] $UserId,
        [switch] $Inherit
    )
    if(Has-Direct-Acl -Path $Path -Access $Access -UserId $UserId){
        Write-Host "ACL access already exists for UserId: $($UserId); Access: $($Access); Path: $($Path)"
    }
    else{
        Add-Acl -Path $Path -Access $Access -UserId $UserId -Inherit $Inherit
    }
}

function Remove-Website-BlueGreen {
    param (
        [Parameter(Mandatory=$true)]
        [string]$WebsiteName,
        [Parameter(Mandatory=$true)]
        [string]$WebRootDirectory
    )

    Write-Host "Removing website for slot: $($WebsiteName)"
    if (Get-Website $WebsiteName -ErrorAction SilentlyContinue) {
        Remove-WebSite -Name $WebsiteName 
        Write-Host "Removed IIS website: $($WebsiteName)"
    } else {
        Write-Host "IIS website: $($WebsiteName) does not exist; nothing to remove"
    }

    if (Get-WebAppPoolState -Name $WebsiteName -ErrorAction SilentlyContinue) {
        Remove-WebAppPool -Name $WebsiteName 
        Write-Host "Removed IIS application pool: $($WebsiteName)"
    } else {
        Write-Host "IIS application pool: $($WebsiteName) does not exist; nothing to remove"
    }

    Remove-Item -Path $WebRootDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed web root directory: $($WebRootDirectory)"
}

function Ensure-DeploySlot {
    param (
        [Parameter(Mandatory=$true)]
        [DeploySlot]$Slot,
        [Parameter(Mandatory=$true)]
        [string]$WebFarmName
    )

    Write-Host "Initializing deployment slot: $($Slot.IISWebsiteName) with web root: $($Slot.WebRootDirectory) on port: $($Slot.Port)"

    Ensure-Website -WebsiteName $Slot.IISWebsiteName -WebRootDirectory $Slot.WebRootDirectory -Port $Slot.Port

    Write-Host "Ensuring file access for the app pool identity:"
    $appPoolUser = "IIS AppPool\$($Slot.IISWebsiteName)"
    Ensure-Acl -Path $Slot.WebRootDirectory -UserId $appPoolUser -Access ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute) -Inherit
    Ensure-Acl -Path $Slot.WebRootDirectory -UserId $appPoolUser -Access ([System.Security.AccessControl.FileSystemRights]::Write) -Inherit
    
    Ensure-HostFileEntry -DesiredIP "127.0.0.1" -Hostname $Slot.FarmServerName -Comment "Mapping for $($Slot.FarmServerName) deployment slot" -CheckHostnameOnly $true

    Ensure-WebFarmServer -FarmName $WebFarmName -OutboundAddress $Slot.FarmServerName -OutboundPort $Slot.Port
}

function Remove-DeploySlot {
    param (
        [Parameter(Mandatory=$true)]
        [DeploySlot]$Slot
    )

    Write-Host "Removing deployment slot: $($Slot.IISWebsiteName) with web root: $($Slot.WebRootDirectory) on port: $($Slot.Port)"

    Remove-HostFileEntry -Hostname $Slot.FarmServerName
    Remove-Website-BlueGreen -WebsiteName $Slot.IISWebsiteName -WebRootDirectory $Slot.WebRootDirectory
}

function Ensure-WebFarm {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FarmName
    )
    Write-Host "Ensuring Web Farm Server for slot"
    if (-Not (Get-WebConfiguration -Filter "webFarms/webFarm[@name='$FarmName']" -ErrorAction SilentlyContinue)) {
        Add-WebConfiguration -Filter "webFarms" -Value @{name=$FarmName; enabled='true'} 
        Write-Host "Created Web Farm Server: $FarmName"
    }
    else {
        Write-Host "Web Farm Server: $FarmName already exists"
    }
}

function Remove-WebFarm {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FarmName
    )
    if (Get-WebConfiguration -Filter "webFarms/webFarm[@name='$FarmName']" -ErrorAction SilentlyContinue) {
        Clear-WebConfiguration -Filter "webFarms/webFarm[@name='$FarmName']"
        Write-Host "Removed Web Farm Server: $FarmName"
    }
    else {
        Write-Host "Web Farm Server: $FarmName does not exist; nothing to remove"
    }
}

function Ensure-RedirectToWebfarm {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FarmName,
        [Parameter(Mandatory=$true)]
        [string]$InboundHostName
    )
    $ruleName = "WebFarmRedirect_$FarmName"
    if (-Not(Get-WebConfiguration -Filter "system.webServer/rewrite/globalRules/rule[@name='$ruleName']" -ErrorAction SilentlyContinue)) {
        Add-WebConfigurationProperty -Filter 'system.webServer/rewrite/globalRules' -Name '.' -Value @{
            name = $ruleName; 
            enabled='false'; 
            stopProcessing='True'; 
            match = @{url = '.*'}; 
            action= @{type='Rewrite'; url = "http://$FarmName/{R:0}"}; 
        }
        Add-WebConfiguration -Filter "system.webServer/rewrite/globalRules/rule[@name='$ruleName']/conditions" -Value @{input='{HTTP_HOST}'; pattern="^$InboundHostName$"}

        Add-WebConfiguration -Filter "system.webServer/rewrite/globalRules/rule[@name='$ruleName']/conditions" -Value @{input='{SERVER_PORT}'; pattern='^80$'}

        Write-Host "Created redirect rule for Web Farm: $FarmName with inbound host name condition: $InboundHostName"
    }
    else {
        Write-Host "Redirect rule for Web Farm: $FarmName already exists"
    }
}

function Remove-RedirectToWebfarm {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FarmName
    )
    $ruleName = "WebFarmRedirect_$FarmName"
    if (Get-WebConfiguration -Filter "system.webServer/rewrite/globalRules/rule[@name='$ruleName']" -ErrorAction SilentlyContinue) {
        Clear-WebConfiguration -Filter "system.webServer/rewrite/globalRules/rule[@name='$ruleName']"
        Write-Host "Removed redirect rule for Web Farm: $FarmName"
    }
    else{
        Write-Host "Redirect rule for Web Farm: $FarmName does not exist; nothing to remove"
    }

}

function Ensure-BlueGreen-Environment {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FarmName,
        [Parameter(Mandatory=$true)]
        [string]$HostName,
        [Parameter(Mandatory=$true)]
        [DeploySlot]$BlueSlot,
        [Parameter(Mandatory=$true)]
        [DeploySlot]$GreenSlot,
        [Parameter(Mandatory=$false)]
        [TimeSpan]$ProxyTimeoutSeconds,
        [Parameter(Mandatory=$false)]
        [int]$MaxRequestBodySizeBytes
    )

    Write-Host @"
     Initializing blue-green deployment environment with the following configuration:
        FarmName: $FarmName;
        HostName: $HostName; 
        BlueSlot: $($BlueSlot.IISWebsiteName), $($BlueSlot.WebRootDirectory), $($BlueSlot.Port), $($BlueSlot.FarmServerName);
        GreenSlot: $($GreenSlot.IISWebsiteName), $($GreenSlot.WebRootDirectory), $($GreenSlot.Port), $($GreenSlot.FarmServerName);
        ProxyTimeoutSeconds: $ProxyTimeoutSeconds;
        MaxRequestBodySizeBytes: $MaxRequestBodySizeBytes
"@

    Ensure-WebFarm -FarmName $FarmName

    Ensure-DeploySlot -Slot $BlueSlot -WebFarmName $FarmName
    Ensure-DeploySlot -Slot $GreenSlot -WebFarmName $FarmName

    Ensure-RedirectToWebfarm -FarmName $FarmName -InboundHostName $HostName

    if($ProxyTimeoutSeconds) {
        Write-Host "Setting proxy timeout to: $ProxyTimeoutSeconds seconds"
        Set-WebConfiguration -Filter "webFarms/webFarm[@name='$FarmName']/applicationRequestRouting/protocol" -Value @{timeout=$ProxyTimeoutSeconds.ToString()}
        Set-WebConfigurationProperty -Filter "system.webServer/proxy" -Name "proxyTimeout" -Value $ProxyTimeoutSeconds.TotalSeconds
    }

    if($MaxRequestBodySizeBytes){
        Set-WebConfigurationProperty -Filter "system.webServer/security/requestFiltering/requestLimits" -Name maxAllowedContentLength -Value $MaxRequestBodySizeBytes
    }
}

function Remove-BlueGreen-Environment{
    param (
        [Parameter(Mandatory=$true)]
        [string]$FarmName,
        [Parameter(Mandatory=$true)]
        [DeploySlot]$BlueSlot,
        [Parameter(Mandatory=$true)]
        [DeploySlot]$GreenSlot
    )

    Write-Host "Removing blue-green deployment environment for farm: $FarmName and host name: $HostName"

    Remove-RedirectToWebfarm -FarmName $FarmName
    Remove-WebFarm -FarmName $FarmName

    Remove-DeploySlot -Slot $BlueSlot
    Remove-DeploySlot -Slot $GreenSlot
}

function Clean-Directory {
    param (
        [Parameter(Position = 0, Mandatory, ValueFromPipeline)]
        [string] $targetDir,
        [Parameter(Mandatory=$false)]
        [string] $Exclude = $null
    )
    
    if($Exclude){
        $filesToRemove = Get-ChildItem $targetDir -Exclude $Exclude
    }
    else {
        $filesToRemove = Get-ChildItem $targetDir
    }
    
    ## NOTE: Web01 is on a windows version where Remove-Item -Recurse is unreliable
    ##       SOURCE: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/remove-item?view=powershell-7.5#example-4-delete-files-in-subfolders-recursively
    $filesToRemove | Get-ChildItem -Recurse | Sort-Object {$_.FullName.Length} -Descending | Remove-Item -Force
}

class SlotActivation{
    [DeploySlot]$ActiveSlot
    [DeploySlot]$InactiveSlot
}

function Get-SlotActivation {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FarmName,
        [Parameter(Mandatory=$true)]
        [DeploySlot]$BlueSlot,
        [Parameter(Mandatory=$true)]
        [DeploySlot]$GreenSlot
    )
    $slotActivation = [SlotActivation]::new()
    if(Get-WebFarmServerEnabledState -FarmName $FarmName -ServerAddress $BlueSlot.FarmServerName){

        $slotActivation.ActiveSlot = $BlueSlot 
        $slotActivation.InactiveSlot = $GreenSlot
    }
    else{
        $slotActivation.ActiveSlot = $GreenSlot 
        $slotActivation.InactiveSlot = $BlueSlot
    }
    return $slotActivation
}

function Deploy-Prepare-Offslot {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ArtifactPath,
        [Parameter(Mandatory=$true)]
        [string]$FarmName,
        [Parameter(Mandatory=$true)]
        [DeploySlot]$BlueSlot,
        [Parameter(Mandatory=$true)]
        [DeploySlot]$GreenSlot
    )

    $slotActivation = Get-SlotActivation -FarmName $FarmName -BlueSlot $BlueSlot -GreenSlot $GreenSlot
    $targetSlot = $slotActivation.InactiveSlot
    
    Write-Host "Deploying to $($targetSlot.IISWebsiteName)"
    
    Write-Host "Stopping target site: $($targetSlot.IISWebsiteName)"
    Stop-Website $targetSlot.IISWebsiteName
    
    Write-Host "Stopping target app pool: $($targetSlot.IISWebsiteName)"
    if ((Get-WebAppPoolState $targetSlot.IISWebsiteName).Value -ne 'Stopped') {
        Stop-WebAppPool $targetSlot.IISWebsiteName
    }

    Write-Host "Clearing target directory/web root: $($targetSlot.WebRootDirectory)"
    Clean-Directory $targetSlot.WebRootDirectory

    Write-Host "Copying files to web root: ArtifactDir: $($ArtifactPath); WebRoot: $($targetSlot.WebRootDirectory)"
    Copy-Item (Join-Path "$ArtifactPath" "*") $targetSlot.WebRootDirectory -Force -Recurse
    $BlueSlot.FarmServerName | Out-File (Join-Path $targetSlot.WebRootDirectory "slotId.html")

    Write-Host "Restarting target slot"
    Start-Website $targetSlot.IISWebsiteName
    Start-WebAppPool $targetSlot.IISWebsiteName
}

function Warm-Website{
    param(
        [Parameter(Mandatory=$true)]
        [DeploySlot]$Slot
    )
        
    $warmingUrl = "http://localhost:$($Slot.Port)"
    Write-Host "Warming slot: $($warmingUrl)"
    Invoke-Webrequest $warmingUrl -ErrorAction Stop
}

function Deploy-SwapActiveSlot {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$FarmName,
        [Parameter(Mandatory=$true)]
        [DeploySlot]$BlueSlot,
        [Parameter(Mandatory=$true)]
        [DeploySlot]$GreenSlot
    )
    $slotActivation = Get-SlotActivation -FarmName $FarmName -BlueSlot $BlueSlot -GreenSlot $GreenSlot
    $targetSlot = $slotActivation.InactiveSlot
    $outgoingSlot = $slotActivation.ActiveSlot
    Write-Host "Swapping active slot from $($outgoingSlot.FarmServerName) to $($targetSlot.FarmServerName)"
    Start-Website $targetSlot.IISWebsiteName
    Enable-WebFarmServer -FarmName $FarmName -ServerAddress $targetSlot.FarmServerName 
    Disable-WebFarmServer -FarmName $FarmName -ServerAddress $outgoingSlot.FarmServerName
    Stop-Website $outgoingSlot.IISWebsiteName
}

function Deploy-BlueGreen {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ArtifactPath,
        [Parameter(Mandatory=$true)]
        [string]$FarmName,
        [Parameter(Mandatory=$true)]
        [DeploySlot]$BlueSlot,
        [Parameter(Mandatory=$true)]
        [DeploySlot]$GreenSlot
    )

    Deploy-Prepare-Offslot -ArtifactPath $ArtifactPath -FarmName $FarmName -BlueSlot $BlueSlot -GreenSlot $GreenSlot -ErrorAction Stop
    $slotToWarm = (Get-SlotActivation -FarmName $FarmName -BlueSlot $BlueSlot -GreenSlot $GreenSlot).InactiveSlot
    Warm-Website -Slot $slotToWarm
    Deploy-SwapActiveSlot -FarmName $FarmName -BlueSlot $BlueSlot -GreenSlot $GreenSlot
}