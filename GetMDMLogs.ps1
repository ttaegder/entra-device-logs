# QUEST SOFTWARE INC. MAKES NO REPRESENTATIONS OR WARRANTIES
# ABOUT THE SUITABILITY OF THE SOFTWARE, EITHER EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED
# WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE, OR NON-INFRINGEMENT. QUEST SOFTWARE SHALL
# NOT BE LIABLE FOR ANY DAMAGES SUFFERED BY LICENSEE
# AS A RESULT OF USING, MODIFYING OR DISTRIBUTING
# THIS SOFTWARE OR ITS DERIVATIVES.
 
 # PowerShell script to run MDM diagnostics, registry export, dsregcmd export, install AzCopy, compress data staging folder, and upload to Azure File share. Script will clean up zip and remove azcopy after upload.

# Set the Azure File share destination with SAS token here
# Example: "https://yourstorageaccount.file.core.windows.net/yourshare/yourfolder?sv=...&sig=..."
$destination = "<Replace with your Azure File share URL including SAS token>"

# AzCopy installation location
$AzCopyInstallLoc = "C:\Program Files (x86)\Quest\On Demand Migration Active Directory Agent\AzCopy"

# Base path
$basePath = "C:\Program Files (x86)\Quest\On Demand Migration Active Directory Agent"
if (-Not (Test-Path $basePath)) {
    New-Item -Path $basePath -ItemType Directory -Force
}
$filesPath = "$basePath\Files"
if (-Not (Test-Path $filesPath)) {
    New-Item -Path $filesPath -ItemType Directory -Force
}

# Get date and time for MDM diagnostics
$date = Get-Date -Format "MMddyy"
$time = Get-Date -Format "HHmm"

# MDM diagnostics zip file name
$mdmZip = "$filesPath\MDMDiagRprt-$date-$time.zip"

# Run MDM diagnostics tool
Write-Output "Running MDM diagnostics tool..."
& mdmdiagnosticstool.exe -area "DeviceEnrollment;DeviceProvisioning;Autopilot" -zip $mdmZip

[string]$ExportFileName = "RegistryExportAfter-$date-$time.csv"
[string]$ExportPath = $filesPath
[string]$LogFileName = "ExportLog.txt"
[string]$LogPath = $filesPath
[bool]$CreateExportLog = $false
# Function to write to log file
function Write-Log {
    param (
        [string]$Message
    )
    if ($CreateExportLog) {
        $logFullPath = Join-Path $LogPath $LogFileName
        Add-Content -Path $logFullPath -Value $Message -Encoding UTF8
    }
}
# PowerShell script to export specified registry keys and their subkeys/values to CSV
# Columns: RegistryPath, ValueName, Value, ValueType
# Handles recursion for subkeys
# Skips paths that don't exist or can't be accessed
# Reduced to relevant PolicyManager subkeys for Intune/Entra ID/Autopilot
function Get-RegistryDataRecursive {
    param (
        [string]$RootPath,
        [System.Collections.ArrayList]$Results = (New-Object System.Collections.ArrayList),
        [int]$Depth = 0,
        [int]$MaxDepth = 5 # Limit recursion depth to prevent long runs on large trees
    )
    if ($Depth -gt $MaxDepth) {
        Write-Log "Skipping deep recursion at $RootPath (depth $Depth > $MaxDepth)"
        return
    }
    try {
        Write-Log "Processing: $RootPath"
        $key = Get-Item -Path $RootPath -ErrorAction Stop
        # Get values for the current key
        foreach ($valueName in $key.GetValueNames()) {
            $actualName = if ($valueName -eq '') { '(Default)' } else { $valueName }
            $value = $key.GetValue($valueName, $null, 'DoNotExpandEnvironmentNames')
            $kind = $key.GetValueKind($valueName)
            $valueStr = switch ($kind) {
                'MultiString' { $value -join "`n" }
                'Binary' { ($value | ForEach-Object { '{0:X2}' -f $_ }) -join '' }
                default { $value }
            }
            [void]$Results.Add([PSCustomObject]@{
                RegistryPath = $key.PSPath.Replace('Microsoft.PowerShell.Core\Registry::', '')
                ValueName = $actualName
                Value = $valueStr
                ValueType = $kind.ToString()
            })
        }
        # Recurse into subkeys
        foreach ($subkeyName in $key.GetSubKeyNames()) {
            $subPath = Join-Path $RootPath $subkeyName
            $null = Get-RegistryDataRecursive -RootPath $subPath -Results $Results -Depth ($Depth + 1) -MaxDepth $MaxDepth
        }
    } catch {
        Write-Log "Skipping ${RootPath}: $($_.Exception.Message)"
    }
    return $Results
}
# List of root registry paths to export (non-PolicyManager paths unchanged)
$paths = @(
    "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin",
    "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WorkplaceJoin",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WorkplaceJoin",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CDJ",
    "HKLM:\SOFTWARE\Microsoft\Enrollments",
    "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager",
    "HKLM:\SOFTWARE\Microsoft\Provisioning",
    "HKLM:\SOFTWARE\Microsoft\OnlineManagement",
    "HKCR:\Installer\Products\6985F0077D3EEB44AB6849B5D7913E95",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserOOBE",
    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon",
    "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\KeyExchangeAlgorithms\PKCS"
)
# Add relevant PolicyManager subkeys
$policyManagerBase = "HKLM:\SOFTWARE\Microsoft\PolicyManager"
$paths += "$policyManagerBase\AdmxInstalled"
$paths += "$policyManagerBase\current"
# Dynamically find Intune/MDM provider GUIDs from Enrollments and add their providers paths
$enrollmentPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
$mdmGUIDs = Get-ChildItem -Path $enrollmentPath -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' } |
    ForEach-Object {
        $guid = $_.PSChildName
        $prop = Get-ItemProperty -Path "$enrollmentPath\$guid" -ErrorAction SilentlyContinue
        if ($prop.ProviderID -eq 'MS DM Server') {
            $guid
        }
    }
if ($mdmGUIDs.Count -gt 0) {
    foreach ($guid in $mdmGUIDs) {
        $paths += "$policyManagerBase\providers\$guid"
    }
    Write-Log "Found $($mdmGUIDs.Count) Intune/MDM provider GUID(s): $($mdmGUIDs -join ', ')"
} else {
    Write-Log "No Intune/MDM enrollments found; skipping providers."
}
# Collect all results
$allResults = New-Object System.Collections.ArrayList
foreach ($path in $paths) {
    $results = Get-RegistryDataRecursive -RootPath $path
    if ($results.Count -gt 0) {
        $allResults.AddRange($results)
    }
}
# Sort for consistent ordering (helpful for line-by-line comparisons)
$exportFullPath = Join-Path $ExportPath $ExportFileName
$allResults | Sort-Object RegistryPath, ValueName | Export-Csv -Path $exportFullPath -NoTypeInformation -Encoding UTF8
Write-Log "Export completed to $exportFullPath"

# Run dsregcmd /status and export to file
$dsregFile = "$filesPath\dsregcmdoutput-$date-$time.txt"
& dsregcmd /status | Out-File -FilePath $dsregFile

# Install AzCopy
# =============================================================================
# Install AzCopy on Windows (PowerShell)
# https://docs.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10
# https://github.com/Azure/azure-storage-azcopy
# -----------------------------------------------------------------------------
# Developer.......: Andre Essing[](https://www.andre-essing.de/)
#[](https://github.com/aessing)
#[](https://twitter.com/aessing)
#[](https://www.linkedin.com/in/aessing/)
# -----------------------------------------------------------------------------
# THIS CODE AND INFORMATION ARE PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND,
# EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.
# =============================================================================
Write-Output "Installing AzCopy..."
Invoke-WebRequest -Uri "https://aka.ms/downloadazcopy-v10-windows" -OutFile AzCopy.zip -UseBasicParsing
Expand-Archive ./AzCopy.zip ./AzCopy -Force
# Move AzCopy
if (-Not (Test-Path -Path $AzCopyInstallLoc)) { New-Item $AzCopyInstallLoc -ItemType "Directory" }
Get-ChildItem -Path "./AzCopy/*/azcopy.exe" | Move-Item -Destination "$AzCopyInstallLoc" -Force
# Clean the kitchen
Remove-Item -Force AzCopy.zip
Remove-Item -Force -Recurse .\AzCopy\

# Get date and time for compression (in case time has passed)
$dateComp = Get-Date -Format "MMddyy"
$timeComp = Get-Date -Format "HHmm"

# Computer name
$computerName = $env:COMPUTERNAME

# Compressed zip file path
$compZip = "$basePath\$computerName-$dateComp-$timeComp.zip"

# Create Volume Shadow Copy to handle open files
Write-Output "Creating Volume Shadow Copy..."
$drive = "C:\"
$shadow = (Get-WmiObject -List Win32_ShadowCopy).Create($drive, "ClientAccessible")
if ($shadow.ReturnValue -ne 0) {
    Write-Error "Failed to create shadow copy. Return value: $($shadow.ReturnValue)"
    # Clean up AzCopy installation
    Remove-Item -Force -Recurse $AzCopyInstallLoc
    return
}
$shadowID = $shadow.ShadowID
Write-Output "Shadow copy created with ID: $shadowID"

$shadowCopy = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowID }
if (-not $shadowCopy) {
    Write-Error "Failed to retrieve shadow copy object."
    # Clean up AzCopy installation
    Remove-Item -Force -Recurse $AzCopyInstallLoc
    return
}

# Create symbolic link to shadow copy
$linkPath = "C:\ShadowLink"
if (Test-Path $linkPath) {
    cmd /c rmdir $linkPath
}
$deviceObject = $shadowCopy.DeviceObject + "\"
Write-Output "Creating symbolic link at $linkPath to $deviceObject"
cmd /c mklink /d $linkPath `"$deviceObject`"

# Shadow files path via link
$shadowFilesPath = $linkPath + $filesPath.Substring(2)

Write-Output "Shadow files path: $shadowFilesPath"
Write-Output "Testing access to shadow files path: $(Test-Path $shadowFilesPath)"

# Create temp directory for copying files
$tempDir = Join-Path $basePath "TempShadowFiles"
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
New-Item -Path $tempDir -ItemType Directory | Out-Null
Write-Output "Created temp directory: $tempDir"

$uploadSuccess = $false

try {
    # Copy files from shadow copy to temp directory
    Write-Output "Copying files from shadow copy to temp directory..."
    Copy-Item -Path "$shadowFilesPath\*" -Destination $tempDir -Recurse -Force -ErrorAction Stop

    # Compress the temp directory
    Write-Output "Compressing temp directory to $compZip..."
    Compress-Archive -Path "$tempDir\*" -DestinationPath $compZip -Force -ErrorAction Stop
    Write-Output "Compression successful."

    # Upload the zip file to Azure File share using AzCopy
    if (Test-Path $compZip) {
        Write-Output "Uploading $compZip to Azure..."
        & "$AzCopyInstallLoc\azcopy.exe" copy `"$compZip`" `"$destination`"
        if ($LASTEXITCODE -eq 0) {
            $uploadSuccess = $true
            Write-Output "Upload successful."
        } else {
            Write-Error "Upload failed with exit code $LASTEXITCODE"
        }
    } else {
        Write-Error "Compressed zip file not found: $compZip"
    }
} catch {
    Write-Error "Error during copy or compression: $_"
} finally {
    # Clean up temp directory
    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force
        Write-Output "Cleaned up temp directory."
    }
    
    # Remove symbolic link
    if (Test-Path $linkPath) {
        cmd /c rmdir $linkPath
        Write-Output "Removed symbolic link."
    }
    
    # Delete the shadow copy
    if ($shadowCopy) {
        $shadowCopy.Delete()
        Write-Output "Deleted shadow copy."
    }
    
    # Delete zip files if upload was successful
    if ($uploadSuccess) {
        if (Test-Path $compZip) {
            Remove-Item -Force $compZip
            Write-Output "Deleted compressed zip file: $compZip"
        }
    }
    
    # Always delete MDM zip file as part of cleanup
    if (Test-Path $mdmZip) {
        Remove-Item -Force $mdmZip
        Write-Output "Deleted MDM zip file: $mdmZip"
    }
    
    # Clean up AzCopy installation
    Remove-Item -Force -Recurse $AzCopyInstallLoc
    Write-Output "Cleaned up AzCopy installation."
}
