#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads applications with winget and imports them into Configuration Manager.

.DESCRIPTION
    Each application is downloaded with "winget download", its details are read from the winget
    manifest and saved beside the content as wingot.json, and it is then copied to the content
    library and created in MCM as an Application (when it has a product code to detect) or a
    Package (when it does not).

    Downloading and importing can run on different machines: run -DownloadOnly where there is
    internet access, copy the Wingot_Downloads folder across, and run -MCMImportOnly on the site
    server. The import reads only wingot.json, which can be edited by hand first - for example to
    supply an install command Wingot could not work out.

.EXAMPLE
    .\wingot.ps1

    Downloads and imports every application in the configuration.

.EXAMPLE
    .\wingot.ps1 -DownloadOnly -AppId Notepad++.Notepad++

    Downloads one application for importing elsewhere.
#>
[CmdletBinding(DefaultParameterSetName = 'Full')]
param(
    [Parameter(ParameterSetName = 'DownloadOnly', Mandatory = $true, HelpMessage = "Only download applications without importing to MCM")]
    [switch]$DownloadOnly,

    [Parameter(ParameterSetName = 'ImportOnly', Mandatory = $true, HelpMessage = "Only import to MCM without downloading")]
    [switch]$MCMImportOnly,

    [Parameter(ParameterSetName = 'Full', HelpMessage = "Location to download applications")]
    [Parameter(ParameterSetName = 'DownloadOnly', HelpMessage = "Location to download applications")]
    [ValidateScript({Test-Path $_ -PathType Container})]
    [string]$DownloadLocation = $PWD,

    [Parameter(ParameterSetName = 'ImportOnly', HelpMessage = "Path to content for import")]
    [ValidateScript({Test-Path $_ -PathType Container})]
    [string]$ImportContentPath = (Join-Path $PWD "Wingot_Downloads"),

    [Parameter(ParameterSetName = 'Full', HelpMessage = "Create task sequence for applications")]
    [Parameter(ParameterSetName = 'ImportOnly', HelpMessage = "Create task sequence for applications")]
    [switch]$MakeTaskSequence,

    [Parameter(HelpMessage = "Winget package IDs to process, instead of the configured list")]
    [string[]]$AppId,

    [Parameter(HelpMessage = "Configuration file to use. Defaults to wingot.config.psd1 beside the script, if present")]
    [string]$ConfigPath,

    [Parameter(HelpMessage = "Installer architecture to download. Defaults to winget's choice for this machine")]
    [ValidateSet("x86", "x64", "arm64")]
    [string]$Architecture,

    [Parameter(HelpMessage = "Installer scope to download. MCM installs as SYSTEM, so machine is the default")]
    [ValidateSet("machine", "user", "any")]
    [string]$Scope = "machine",

    [Parameter(HelpMessage = "Transcript file. Defaults to a timestamped log in the current directory")]
    [string]$LogPath = (Join-Path $PWD "Wingot_$(Get-Date -Format 'yyyyMMdd_HHmmss').log")
)

#region Configuration
# Edit these, or put any of the same keys in wingot.config.psd1 beside the script to override them
# without touching the script itself.
$Config = @{
    MCMSiteCode = "CHQ"
    MCMPrimarySiteServer = "CM1.corp.contoso.com"
    MCMApplicationLibraryLocation = "\\localhost\c$\Packages\Apps"
    DPGroups = @("Corp DPs")
    MCMFolderName = "Wingot"
    TempFolderName = "Wingot_Downloads"
    Apps = @(
        "DominikReichl.KeePass",
        "Microsoft.VCRedist.2015+.x64",
        "Microsoft.VCRedist.2015+.x86",
        "Oracle.JavaRuntimeEnvironment",
        "Citrix.Workspace.LTSR"
    )
}

# Written beside each download; everything the import step needs.
$DetailsFileName = "wingot.json"
#endregion

#region Helper Functions
function Write-ColorOutput {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Type = "Info"
    )

    $colors = @{
        Info = "Blue"
        Success = "Green"
        Warning = "Yellow"
        Error = "Red"
    }

    Write-Host $Message -ForegroundColor $colors[$Type]
}

function Import-Configuration {
    $path = $ConfigPath
    if (-not $path -and $PSScriptRoot) {
        $path = Join-Path $PSScriptRoot "wingot.config.psd1"
        if (-not (Test-Path $path)) { $path = $null }
    }

    if ($path) {
        if (-not (Test-Path $path)) {
            throw "Configuration file not found: $path"
        }

        $overrides = Import-PowerShellDataFile -Path $path
        foreach ($key in $overrides.Keys) {
            if (-not $Config.ContainsKey($key)) {
                Write-ColorOutput "Ignoring unknown configuration key '$key' in $path" "Warning"
                continue
            }
            $Config[$key] = $overrides[$key]
        }
        Write-ColorOutput "Loaded configuration from: $path" "Success"
    }

    if ($AppId) {
        $Config.Apps = $AppId
    }
}

function Test-Prerequisites {
    if (-not $MCMImportOnly) {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) {
            Write-ColorOutput "winget was not found. Install App Installer from the Microsoft Store." "Error"
            return $false
        }

        # "winget download" arrived in winget 1.8.
        $versionText = (& winget --version) -replace '^v', '' -replace '[-+].*$', ''
        $version = $null
        if ([version]::TryParse($versionText, [ref]$version) -and $version -lt [version]"1.8") {
            Write-ColorOutput "winget $versionText is too old: 'winget download' needs 1.8 or later." "Error"
            return $false
        }
        Write-ColorOutput "Found winget $versionText" "Success"
    }

    if (-not $DownloadOnly) {
        # Test Configuration Manager module
        try {
            if (-not (Get-Module ConfigurationManager)) {
                $CMPath = "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
                if (-not (Test-Path $CMPath)) {
                    throw "Configuration Manager console not found"
                }
                Import-Module $CMPath -ErrorAction Stop
            }

            if (-not (Get-PSDrive -Name $Config.MCMSiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                New-PSDrive -Name $Config.MCMSiteCode -PSProvider CMSite -Root $Config.MCMPrimarySiteServer -ErrorAction Stop | Out-Null
            }

            Write-ColorOutput "Configuration Manager connection established" "Success"
        }
        catch {
            Write-ColorOutput "Unable to connect to Configuration Manager: $($_.Exception.Message)" "Error"
            return $false
        }
    }

    return $true
}

function Initialize-DownloadFolder {
    param([string]$Path)

    $downloadPath = Join-Path $Path $Config.TempFolderName

    if (-not (Test-Path $downloadPath)) {
        New-Item -Path $downloadPath -ItemType Directory | Out-Null
        Write-ColorOutput "Created download folder: $downloadPath" "Success"
    }

    return $downloadPath
}

function ConvertTo-SafePathSegment {
    param([string]$Name)

    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $safe = -join ($Name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { $_ } })
    return $safe.Trim().TrimEnd('.')
}
#endregion

#region Manifest Reader
# Winget manifests are generated YAML in a small, regular subset: block mappings, block sequences,
# plain or quoted scalars, and block scalars for long text. This reads that subset - all Wingot
# needs - so no YAML module has to ship alongside the script.
function ConvertFrom-WingetManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lines = foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $text = $raw.TrimEnd()
        $trimmed = $text.TrimStart()
        [pscustomobject]@{
            Indent = $text.Length - $trimmed.Length
            Text = $trimmed
            Raw = $text
            Skip = ($trimmed -eq '' -or $trimmed.StartsWith('#') -or $trimmed -eq '---')
        }
    }

    $state = @{ Lines = @($lines); Index = 0 }
    Skip-ManifestBlankLines $state
    if ($state.Index -ge $state.Lines.Count) {
        return @{}
    }
    return Read-ManifestNode $state $state.Lines[$state.Index].Indent
}

function Skip-ManifestBlankLines {
    param([hashtable]$State)

    while ($State.Index -lt $State.Lines.Count -and $State.Lines[$State.Index].Skip) {
        $State.Index++
    }
}

function Test-ManifestListItem {
    param([string]$Text)

    return ($Text -eq '-' -or $Text.StartsWith('- '))
}

function Read-ManifestNode {
    param([hashtable]$State, [int]$Indent)

    if (Test-ManifestListItem $State.Lines[$State.Index].Text) {
        return Read-ManifestList $State $Indent
    }
    return Read-ManifestMap $State $Indent
}

function Read-ManifestMap {
    param([hashtable]$State, [int]$Indent)

    $map = @{}
    while ($true) {
        Skip-ManifestBlankLines $State
        if ($State.Index -ge $State.Lines.Count) { break }

        $line = $State.Lines[$State.Index]
        if ($line.Indent -ne $Indent -or (Test-ManifestListItem $line.Text)) { break }

        if ($line.Text -notmatch '^(?<key>[^:]+?):(?:\s+(?<value>.*))?$') {
            throw "Unreadable manifest line $($State.Index + 1): $($line.Raw)"
        }
        $key = $Matches.key.Trim().Trim("'", '"')
        $value = $Matches.value

        $State.Index++
        $map[$key] = Read-ManifestValue $State $Indent $value
    }
    return $map
}

function Read-ManifestList {
    param([hashtable]$State, [int]$Indent)

    $list = New-Object System.Collections.Generic.List[object]
    while ($true) {
        Skip-ManifestBlankLines $State
        if ($State.Index -ge $State.Lines.Count) { break }

        $line = $State.Lines[$State.Index]
        if ($line.Indent -ne $Indent -or -not (Test-ManifestListItem $line.Text)) { break }

        $item = $line.Text.Substring(1)
        $content = $item.TrimStart()

        if ($content -eq '' -or $content.StartsWith('#')) {
            $State.Index++
            $list.Add((Read-ManifestValue $State $Indent ''))
        }
        elseif ($content -match '^[^:''"]+?:(\s|$)') {
            # "- Key: value" opens a mapping whose keys line up with "Key". Rewrite the line as
            # that first key, at its own column, and read the mapping from there.
            $keyIndent = $Indent + 1 + ($item.Length - $content.Length)
            $State.Lines[$State.Index] = [pscustomobject]@{ Indent = $keyIndent; Text = $content; Raw = $line.Raw; Skip = $false }
            $list.Add((Read-ManifestMap $State $keyIndent))
        }
        else {
            $State.Index++
            $list.Add((ConvertFrom-ManifestScalar $content))
        }
    }
    return ,$list.ToArray()
}

function Read-ManifestValue {
    param([hashtable]$State, [int]$ParentIndent, [string]$Value)

    # Nothing after the colon: the value is the indented block below, if there is one.
    if ([string]::IsNullOrEmpty($Value) -or $Value.StartsWith('#')) {
        Skip-ManifestBlankLines $State
        if ($State.Index -lt $State.Lines.Count) {
            $next = $State.Lines[$State.Index]
            if ($next.Indent -gt $ParentIndent -or ($next.Indent -eq $ParentIndent -and (Test-ManifestListItem $next.Text))) {
                return Read-ManifestNode $State $next.Indent
            }
        }
        return $null
    }

    # Block scalar (| or >): every following line indented deeper than the key, verbatim. Folding
    # is approximated by joining lines with spaces; Wingot reads no field that uses it.
    if ($Value -match '^[|>][+-]?[0-9]?\s*(#.*)?$') {
        $separator = if ($Value.StartsWith('>')) { ' ' } else { "`n" }
        $body = New-Object System.Collections.Generic.List[string]
        $blockIndent = $null
        while ($State.Index -lt $State.Lines.Count) {
            $line = $State.Lines[$State.Index]
            if ($line.Text -ne '' -and $line.Indent -le $ParentIndent) { break }
            if ($line.Text -eq '') {
                $body.Add('')
            }
            else {
                if ($null -eq $blockIndent) { $blockIndent = $line.Indent }
                $body.Add($line.Raw.Substring([Math]::Min($blockIndent, $line.Indent)))
            }
            $State.Index++
        }
        return ($body -join $separator).TrimEnd()
    }

    return ConvertFrom-ManifestScalar $Value
}

function ConvertFrom-ManifestScalar {
    param([string]$Text)

    $text = $Text.Trim()

    if ($text -match "^'((?:[^']|'')*)'") {
        return $Matches[1].Replace("''", "'")
    }
    if ($text -match '^"((?:[^"\\]|\\.)*)"') {
        return [regex]::Unescape($Matches[1])
    }

    # Plain scalars run to a " #" comment. Everything stays a string: "2.50" is a version, not 2.5.
    $text = $text -replace '\s+#.*$', ''
    if ($text -eq '~' -or $text -eq 'null') { return $null }
    if ($text -eq '{}') { return @{} }
    if ($text -match '^\[(.*)\]$') {
        $items = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { ConvertFrom-ManifestScalar $_ })
        return ,$items
    }
    return $text
}
#endregion

#region Application Details
function Get-InstallCommand {
    param(
        [string]$InstallerType,
        [string]$FileName,
        [hashtable]$Switches
    )

    $silent = $Switches.Silent
    if (-not $silent) { $silent = $Switches.SilentWithProgress }

    # When a manifest gives no silent switch, winget falls back to the installer technology's
    # standard one. Do the same, or the deployment runs interactively and hangs under SYSTEM.
    switch ($InstallerType) {
        { $_ -in "msi", "wix" } {
            if (-not $silent) { $silent = "/quiet /norestart" }
            $command = "msiexec.exe /i `"$FileName`" $silent"
        }
        "inno" {
            if (-not $silent) { $silent = "/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" }
            $command = "`"$FileName`" $silent"
        }
        "nullsoft" {
            if (-not $silent) { $silent = "/S" }
            $command = "`"$FileName`" $silent"
        }
        "burn" {
            if (-not $silent) { $silent = "/quiet /norestart" }
            $command = "`"$FileName`" $silent"
        }
        "exe" {
            if (-not $silent) {
                return @{ Command = $null; Problem = "the manifest gives no silent switch for this exe installer" }
            }
            $command = "`"$FileName`" $silent"
        }
        default {
            return @{ Command = $null; Problem = "installer type '$InstallerType' is not supported" }
        }
    }

    if ($Switches.Custom) {
        $command = "$command $($Switches.Custom)"
    }
    return @{ Command = $command.Trim(); Problem = $null }
}

function New-ApplicationDetails {
    param(
        [string]$AppName,
        [string]$AppPath
    )

    $manifestFile = Get-ChildItem -LiteralPath $AppPath -Filter "*.yaml" -File | Select-Object -First 1
    if (-not $manifestFile) {
        throw "No winget manifest found in $AppPath"
    }
    $manifest = ConvertFrom-WingetManifest -Path $manifestFile.FullName

    $installers = @($manifest.Installers | Where-Object { $_ })
    if ($installers.Count -eq 0) {
        throw "The manifest lists no installers"
    }

    $files = @(Get-ChildItem -LiteralPath $AppPath -File | Where-Object { $_.Extension -ne ".yaml" -and $_.Name -ne $DetailsFileName })
    if ($files.Count -eq 0) {
        throw "No installer was downloaded"
    }

    # The manifest can describe several installers (architectures, scopes, types). Its hash is
    # what identifies the one that was actually downloaded. One file can be listed under more
    # than one architecture; winget prefers the requested one, then the machine's own.
    $preferred = @($Architecture, $(if ([Environment]::Is64BitOperatingSystem) { "x64" }), "x86") | Where-Object { $_ }
    $installer = $null
    $file = $null
    foreach ($candidate in $files) {
        $hash = (Get-FileHash -LiteralPath $candidate.FullName -Algorithm SHA256).Hash
        $hits = @($installers | Where-Object { $_.InstallerSha256 -eq $hash })
        if ($hits.Count -eq 0) { continue }
        $installer = $hits | Sort-Object { $rank = [array]::IndexOf($preferred, $_.Architecture); if ($rank -lt 0) { 99 } else { $rank } } | Select-Object -First 1
        $file = $candidate
        break
    }
    if (-not $installer) {
        if ($installers.Count -eq 1 -and $files.Count -eq 1) {
            $installer = $installers[0]
            $file = $files[0]
        }
        else {
            throw "Could not tell which of the manifest's $($installers.Count) installers was downloaded"
        }
    }

    # Installer entries inherit anything they do not set from the top of the manifest.
    $effective = {
        param([string]$Name)
        if ($null -ne $installer[$Name]) { return $installer[$Name] }
        return $manifest[$Name]
    }

    $switches = @{}
    foreach ($source in @($manifest.InstallerSwitches, $installer.InstallerSwitches)) {
        if ($source -is [hashtable]) {
            foreach ($key in $source.Keys) { $switches[$key] = $source[$key] }
        }
    }

    $installerType = & $effective "InstallerType"
    if ($installerType -eq "zip") {
        $installerType = "zip ($(& $effective 'NestedInstallerType'))"
    }

    # Apps and Features entries record what the installed product reports to Windows, which is
    # what detection compares against. Its DisplayVersion often differs from the winget version.
    $arp = @(& $effective "AppsAndFeaturesEntries") | Where-Object { $_ -is [hashtable] } | Select-Object -First 1
    $productCode = & $effective "ProductCode"
    if (-not $productCode -and $arp) { $productCode = $arp.ProductCode }
    $detectionVersion = $manifest.PackageVersion
    if ($arp -and $arp.DisplayVersion) { $detectionVersion = $arp.DisplayVersion }

    $publisher = $manifest.Publisher
    if (-not $publisher) { $publisher = $manifest.Author }
    $name = $manifest.PackageName
    if (-not $name) { $name = $manifest.PackageIdentifier }

    $architecture = $installer.Architecture
    $install = Get-InstallCommand -InstallerType $installerType -FileName $file.Name -Switches $switches

    $details = [ordered]@{
        Id = $manifest.PackageIdentifier
        Name = $name
        Publisher = "$publisher".TrimEnd('.')
        Version = $manifest.PackageVersion
        DetectionVersion = $detectionVersion
        ProductCode = $productCode
        Architecture = $architecture
        # Which Uninstall key registry detection reads: 64-bit installers normally register in the
        # native view, 32-bit ones under WOW6432Node. Inferred from the manifest's architecture;
        # correct it here if a detection rule never matches. MSIs are detected by product code
        # instead, which does not depend on the view.
        Is64Bit = ($architecture -in "x64", "arm64")
        InstallerType = $installerType
        InstallContent = $file.Name
        InstallCommand = $install.Command
    }

    if ($install.Problem) {
        Write-ColorOutput "No install command for ${AppName}: $($install.Problem). Set InstallCommand in $(Join-Path $AppPath $DetailsFileName) and run again with -MCMImportOnly." "Warning"
    }

    return $details
}

function Get-ApplicationDetails {
    param(
        [string]$AppName,
        [string]$ContentPath
    )

    Write-ColorOutput "Extracting details for: $AppName" "Info"

    $appPath = Join-Path $ContentPath $AppName
    $detailsPath = Join-Path $appPath $DetailsFileName

    try {
        if (Test-Path $detailsPath) {
            # Saved at download time, and possibly edited since. It wins over the manifest.
            $saved = Get-Content -LiteralPath $detailsPath -Raw | ConvertFrom-Json
            $appDetails = @{}
            foreach ($property in $saved.PSObject.Properties) {
                $appDetails[$property.Name] = $property.Value
            }
        }
        else {
            $created = New-ApplicationDetails -AppName $AppName -AppPath $appPath
            $created | ConvertTo-Json | Set-Content -LiteralPath $detailsPath -Encoding UTF8
            $appDetails = @{}
            foreach ($key in $created.Keys) {
                $appDetails[$key] = $created[$key]
            }
        }

        Write-ColorOutput "Successfully extracted details for: $AppName" "Success"
        return $appDetails
    }
    catch {
        Write-ColorOutput "Failed to extract details for $AppName`: $($_.Exception.Message)" "Error"
        return $null
    }
}
#endregion

#region Core Functions
function Invoke-ApplicationDownload {
    param(
        [string]$AppName,
        [string]$DownloadPath
    )

    Write-ColorOutput "Starting download for: $AppName" "Info"

    $appDownloadPath = Join-Path $DownloadPath $AppName

    # Clean up existing download if present
    if (Test-Path $appDownloadPath) {
        Remove-Item $appDownloadPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-ColorOutput "Cleaned up previous download for: $AppName" "Warning"
    }

    # Create app-specific folder
    New-Item -Path $appDownloadPath -ItemType Directory | Out-Null

    # --exact so an ID never falls back to a name search, and the agreement and interactivity
    # flags so an unattended run cannot stop at a prompt.
    $wingetArgs = @(
        "download", "--id", $AppName, "--exact",
        "--download-directory", $appDownloadPath,
        "--accept-source-agreements", "--accept-package-agreements",
        "--disable-interactivity"
    )
    if ($Scope -ne "any") { $wingetArgs += @("--scope", $Scope) }
    if ($Architecture) { $wingetArgs += @("--architecture", $Architecture) }

    # Out-Host keeps winget's progress on screen without it becoming this function's return value.
    & winget @wingetArgs | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-ColorOutput ("Failed to download {0}: winget exited with 0x{1:X8}" -f $AppName, $LASTEXITCODE) "Error"
        return $false
    }

    Write-ColorOutput "Successfully downloaded: $AppName" "Success"
    return $true
}

function Get-LibraryPath {
    param([hashtable]$AppDetails)

    $libraryPath = Join-Path $Config.MCMApplicationLibraryLocation (ConvertTo-SafePathSegment $AppDetails.Publisher)
    $appLibraryPath = Join-Path $libraryPath (ConvertTo-SafePathSegment $AppDetails.Name)
    return Join-Path $appLibraryPath (ConvertTo-SafePathSegment $AppDetails.Version)
}

function Copy-ToLibrary {
    param(
        [string]$AppName,
        [string]$ContentPath,
        [string]$VersionPath
    )

    Write-ColorOutput "Copying $AppName to library" "Info"

    try {
        New-Item -Path $VersionPath -ItemType Directory -Force | Out-Null
        $sourcePath = Join-Path $ContentPath $AppName
        Copy-Item -Path "$sourcePath\*" -Destination $VersionPath -Recurse -Exclude "*.yaml", $DetailsFileName

        Write-ColorOutput "Successfully copied content to: $VersionPath" "Success"
        return $true
    }
    catch {
        Write-ColorOutput "Failed to copy to library: $($_.Exception.Message)" "Error"
        return $false
    }
}

function Invoke-MCMWork {
    param(
        [hashtable]$AppDetails,
        [string]$LibraryPath
    )

    $originalLocation = Get-Location

    try {
        Set-Location "$($Config.MCMSiteCode):\"

        $isApplication = -not [string]::IsNullOrEmpty($AppDetails.ProductCode)
        $objectName = "$($AppDetails.Name) $($AppDetails.Version)"

        if ($isApplication) {
            Write-ColorOutput "Creating MCM Application: $objectName" "Info"

            if ($AppDetails.InstallerType -in "msi", "wix" -and $AppDetails.ProductCode -match '^\{[0-9A-Fa-f-]{36}\}$') {
                $detection = New-CMDetectionClauseWindowsInstaller -ProductCode $AppDetails.ProductCode -Existence
            }
            else {
                $detection = New-CMDetectionClauseRegistryKeyValue -Hive LocalMachine -KeyName "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($AppDetails.ProductCode)" -Is64Bit:([bool]$AppDetails.Is64Bit) -PropertyType Version -ValueName "DisplayVersion" -Value -ExpectedValue $AppDetails.DetectionVersion -ExpressionOperator GreaterEquals
            }

            New-CMApplication -Name $objectName -Publisher $AppDetails.Publisher -SoftwareVersion $AppDetails.Version -AutoInstall $true | Out-Null

            Add-CMScriptDeploymentType -ApplicationName $objectName -DeploymentTypeName "Install $objectName" -InstallCommand $AppDetails.InstallCommand -AddDetectionClause $detection -ContentLocation $LibraryPath -InstallationBehaviorType InstallForSystem -LogonRequirementType WhetherOrNotUserLoggedOn | Out-Null

            $folderType = "Application"
        }
        else {
            Write-ColorOutput "Creating MCM Package: $objectName" "Info"

            New-CMPackage -Name $objectName -Manufacturer $AppDetails.Publisher -Version $AppDetails.Version -Path $LibraryPath | Out-Null

            New-CMProgram -StandardProgramName "Install $($AppDetails.Name)" -CommandLine $AppDetails.InstallCommand -PackageName $objectName -ProgramRunType WhetherOrNotUserIsLoggedOn -RunMode RunWithAdministrativeRights -RunType Hidden | Out-Null

            $folderType = "Package"
        }

        # Distribute content
        Write-ColorOutput "Starting distribution to: $($Config.DPGroups -join ', ')" "Info"
        if ($isApplication) {
            Start-CMContentDistribution -ApplicationName $objectName -DistributionPointGroupName $Config.DPGroups | Out-Null
        }
        else {
            Start-CMContentDistribution -PackageName $objectName -DistributionPointGroupName $Config.DPGroups | Out-Null
        }

        # Organize in folders
        $dateFolder = Get-Date -Format 'MM-yyyy'
        $folderPath = "$folderType\$($Config.MCMFolderName)\$dateFolder"

        New-MCMFolderStructure -FolderType $folderType -DateFolder $dateFolder

        if ($isApplication) {
            $object = Get-CMApplication -Name $objectName
        }
        else {
            $object = Get-CMPackage -Name $objectName -Fast
        }

        Move-CMObject -FolderPath $folderPath -InputObject $object | Out-Null
        Write-ColorOutput "Moved to: $folderPath" "Success"

        # Add to task sequence if requested
        if ($MakeTaskSequence) {
            Add-ToTaskSequence -AppDetails $AppDetails -IsApplication $isApplication -DateFolder $dateFolder
        }

        Write-ColorOutput "MCM work completed for: $($AppDetails.Name)" "Success"
        return $true
    }
    catch {
        Write-ColorOutput "MCM work failed: $($_.Exception.Message)" "Error"
        return $false
    }
    finally {
        Set-Location $originalLocation
    }
}

function New-MCMFolderStructure {
    param(
        [string]$FolderType,
        [string]$DateFolder
    )

    $mainFolderPath = "$FolderType\$($Config.MCMFolderName)"
    $dateFolderPath = "$mainFolderPath\$DateFolder"

    @(
        @{Path = $mainFolderPath; Name = $Config.MCMFolderName; Parent = $FolderType}
        @{Path = $dateFolderPath; Name = $DateFolder; Parent = $mainFolderPath}
    ) | ForEach-Object {
        if (-not (Get-CMFolder -Name $_.Name -ParentFolderPath $_.Parent -ErrorAction SilentlyContinue)) {
            New-CMFolder -ParentFolderPath $_.Parent -Name $_.Name | Out-Null
            Write-ColorOutput "Created folder: $($_.Path)" "Success"
        }
    }
}

function Add-ToTaskSequence {
    param(
        [hashtable]$AppDetails,
        [bool]$IsApplication,
        [string]$DateFolder
    )

    try {
        if (-not (Get-CMTaskSequence -Name $DateFolder -Fast)) {
            New-CMTaskSequence -CustomTaskSequence -Name $DateFolder | Out-Null
            Write-ColorOutput "Created task sequence: $DateFolder" "Success"
        }

        $objectName = "$($AppDetails.Name) $($AppDetails.Version)"
        $shortName = $AppDetails.Name.Substring(0, [Math]::Min(40, $AppDetails.Name.Length))

        if ($IsApplication) {
            $object = Get-CMApplication -Name $objectName
            $step = New-CMTSStepInstallApplication -Name "Install $shortName" -Application $object
        }
        else {
            $object = Get-CMProgram -PackageName $objectName -ProgramName "Install $($AppDetails.Name)"
            $step = New-CMTSStepInstallSoftware -Name "Install $shortName" -Program $object
        }

        $taskSequence = Get-CMTaskSequence -Name $DateFolder -Fast
        $taskSequence | Add-CMTaskSequenceStep -Step $step | Out-Null

        Write-ColorOutput "Added $objectName to task sequence" "Success"
    }
    catch {
        Write-ColorOutput "Failed to add to task sequence: $($_.Exception.Message)" "Error"
    }
}

function Remove-ImportedDownloads {
    param(
        [string]$DownloadPath,
        [string[]]$AppNames
    )

    # Only what was imported. A failed app's download stays for a retry with -MCMImportOnly.
    foreach ($app in $AppNames) {
        $appPath = Join-Path $DownloadPath $app
        if (Test-Path $appPath) {
            Remove-Item $appPath -Recurse -Force
        }
    }

    if ((Test-Path $DownloadPath) -and -not (Get-ChildItem -LiteralPath $DownloadPath -Force)) {
        Remove-Item $DownloadPath -Force
        Write-ColorOutput "Cleaned up temporary directory: $DownloadPath" "Success"
    }
}
#endregion

#region Main Execution
function Invoke-App {
    param([string]$App)

    if ($MCMImportOnly) {
        $contentPath = $ImportContentPath
    }
    else {
        $contentPath = Initialize-DownloadFolder -Path $DownloadLocation
        if (-not (Invoke-ApplicationDownload -AppName $App -DownloadPath $contentPath)) {
            return "Failed"
        }
    }

    # Read here even for -DownloadOnly, so wingot.json is written - and any problem reported - on
    # the machine that did the download.
    $appDetails = Get-ApplicationDetails -AppName $App -ContentPath $contentPath
    if (-not $appDetails) {
        return "Failed"
    }

    if ($DownloadOnly) {
        return "Succeeded"
    }

    if (-not $appDetails.InstallCommand) {
        Write-ColorOutput "Skipping ${App}: no install command. Set InstallCommand in $(Join-Path (Join-Path $contentPath $App) $DetailsFileName)." "Error"
        return "Failed"
    }

    $versionPath = Get-LibraryPath -AppDetails $appDetails
    if (Test-Path $versionPath) {
        Write-ColorOutput "Version $($appDetails.Version) of $($appDetails.Name) is already in the library; skipping" "Warning"
        return "Skipped"
    }

    if (-not (Copy-ToLibrary -AppName $App -ContentPath $contentPath -VersionPath $versionPath)) {
        return "Failed"
    }

    if (-not (Invoke-MCMWork -AppDetails $appDetails -LibraryPath $versionPath)) {
        return "Failed"
    }

    return "Succeeded"
}

function Main {
    Write-ColorOutput "Starting Wingot Application Deployment Script" "Info"

    Import-Configuration

    if (-not (Test-Prerequisites)) {
        Write-ColorOutput "Prerequisites check failed. Exiting." "Error"
        return $false
    }

    $originalLocation = Get-Location
    $results = [ordered]@{}

    try {
        foreach ($app in $Config.Apps) {
            Set-Location $originalLocation
            Write-ColorOutput "Processing: $app" "Info"

            $results[$app] = Invoke-App -App $app

            Write-ColorOutput "Completed processing: $app ($($results[$app]))" $(if ($results[$app] -eq "Failed") { "Error" } else { "Success" })
        }

        if (-not $DownloadOnly -and -not $MCMImportOnly) {
            $imported = @($results.Keys | Where-Object { $results[$_] -ne "Failed" })
            Remove-ImportedDownloads -DownloadPath (Join-Path $DownloadLocation $Config.TempFolderName) -AppNames $imported
        }
    }
    catch {
        Write-ColorOutput "Script execution failed: $($_.Exception.Message)" "Error"
        return $false
    }
    finally {
        Set-Location $originalLocation
    }

    Write-ColorOutput "`nSummary" "Info"
    foreach ($app in $results.Keys) {
        Write-ColorOutput ("  {0,-10} {1}" -f $results[$app], $app) $(if ($results[$app] -eq "Failed") { "Error" } else { "Success" })
    }

    $failed = @($results.Values | Where-Object { $_ -eq "Failed" }).Count
    if ($failed) {
        Write-ColorOutput "$failed of $($results.Count) applications failed" "Error"
        return $false
    }

    Write-ColorOutput "Script execution completed successfully" "Success"
    return $true
}

Start-Transcript -Path $LogPath | Out-Null
try {
    $succeeded = Main
}
finally {
    Stop-Transcript | Out-Null
}

# Non-zero on any failure, so a scheduled task or pipeline can tell.
if (-not $succeeded) { exit 1 }
#endregion
