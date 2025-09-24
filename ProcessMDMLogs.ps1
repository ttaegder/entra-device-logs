# QUEST SOFTWARE INC. MAKES NO REPRESENTATIONS OR WARRANTIES
# ABOUT THE SUITABILITY OF THE SOFTWARE, EITHER EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED
# WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE, OR NON-INFRINGEMENT. QUEST SOFTWARE SHALL
# NOT BE LIABLE FOR ANY DAMAGES SUFFERED BY LICENSEE
# AS A RESULT OF USING, MODIFYING OR DISTRIBUTING
# THIS SOFTWARE OR ITS DERIVATIVES.
 
 # Variables to configure
$StorageAccountName = ""  # Enter your Azure Storage Account name
$FileShareName = ""       # Enter your Azure File Share name
$SasToken = ""            # Enter the SAS token (starting with ?sv=...)
$LocalDownloadPath = "C:\Temp\AzureFiles"  # Local path to download and process files
$OpenAIAPIKey = ""        # Enter your OpenAI API key
[string]$ChatGPTModel = "gpt-5-mini"  # Options: gpt-5, gpt-5-mini, gpt-5-nano

$PartialPromptTemplate = @"
You are an expert in device migrations to Entra ID (Entra joined devices). Analyze the provided CSV event log exports for errors/warnings on Entra ID/Intune join failures. Research error codes, suggest fixes, and cite sources.

The CSVs are from these Windows Event Viewer logs:
- "microsoft-windows-provisioning-diagnostics-provider-admin.evtx" exported to "microsoft-windows-provisioning-diagnostics-provider-admin.csv"
- "microsoft-windows-user device registration-admin.evtx" exported to "microsoft-windows-user device registration-admin.csv"
- "microsoft-windows-devicemanagement-enterprise-diagnostics-provider-enrollment.evtx" exported to "microsoft-windows-devicemanagement-enterprise-diagnostics-provider-enrollment.csv"
- "microsoft-windows-devicemanagement-enterprise-diagnostics-provider-admin.evtx" exported to "microsoft-windows-devicemanagement-enterprise-diagnostics-provider-admin.csv"

Provided CSV data:
{0}
"@

$FinalPromptTemplate = @"
You are an expert in device migrations to Entra ID (Entra joined devices). Based on the following partial analyses of event logs, provide a comprehensive summary of errors/warnings about failures to join Entra ID or Intune, including researched error codes, suggestions on how to move forward, and citations to resources.

Partial analyses:
{0}

Additionally, evaluate the latest Windows registry output for evaluation:
{1}

And the latest dsregcmd status output for evaluation:
{2}
"@

# Ensure local path exists
if (-not (Test-Path $LocalDownloadPath)) {
    New-Item -Path $LocalDownloadPath -ItemType Directory | Out-Null
}

# Log file
$LogPath = Join-Path $LocalDownloadPath "process_log.txt"
$logMessage = "Script started at $(Get-Date)"
Write-Output $logMessage
Add-Content -Path $LogPath -Value $logMessage

# Import required module (assume Az.Storage is installed; if not, run Install-Module -Name Az.Storage)
Import-Module Az.Storage -ErrorAction SilentlyContinue

try {
    # Create storage context
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -SasToken $SasToken

    # Get ZIP files at root
    $zipFiles = Get-AzStorageFile -Context $ctx -ShareName $FileShareName | 
        Where-Object { -not $_.IsDirectory -and $_.Name -like "*.zip" }

    if ($zipFiles.Count -eq 0) {
        $logMessage = "No ZIP files found at the root of the share."
        Write-Output $logMessage
        Add-Content -Path $LogPath -Value $logMessage
    }

    # Track downloaded and processed files
    $downloadedFiles = @()
    $successfullyProcessed = @()

    foreach ($file in $zipFiles) {
        $zipName = $file.Name
        $logMessage = "Found ZIP: $zipName"
        Write-Output $logMessage
        Add-Content -Path $LogPath -Value $logMessage

        try {
            # Download ZIP locally
            $localZipPath = Join-Path $LocalDownloadPath $zipName
            Get-AzStorageFileContent -Context $ctx -ShareName $FileShareName -Path $zipName -Destination $localZipPath -Force
            $logMessage = "Downloaded: $zipName"
            Write-Output $logMessage
            Add-Content -Path $LogPath -Value $logMessage
            $downloadedFiles += $zipName

            # Expand ZIP
            $extractPath = Join-Path $LocalDownloadPath ($zipName -replace '\.zip$', '')
            Expand-Archive -Path $localZipPath -DestinationPath $extractPath -Force
            $logMessage = "Expanded: $zipName to $extractPath"
            Write-Output $logMessage
            Add-Content -Path $LogPath -Value $logMessage

            # Expand inner MDMDiagRprt ZIPs
            $innerZips = Get-ChildItem -Path $extractPath -Recurse -Filter "MDMDiagRprt-*.zip" | 
                Where-Object { $_.Name -match '^MDMDiagRprt-\d+-\d+\.zip$' }
            foreach ($innerZip in $innerZips) {
                Expand-Archive -Path $innerZip.FullName -DestinationPath $innerZip.DirectoryName -Force
                $logMessage = "Expanded inner ZIP: $($innerZip.Name)"
                Write-Output $logMessage
                Add-Content -Path $LogPath -Value $logMessage
            }

            # EVTX files to export
            $evtxNames = @(
                "microsoft-windows-devicemanagement-enterprise-diagnostics-provider-admin.evtx",
                #"microsoft-windows-devicemanagement-enterprise-diagnostics-provider-autopilot.evtx",
                #"microsoft-windows-devicemanagement-enterprise-diagnostics-provider-debug.evtx",
                "microsoft-windows-devicemanagement-enterprise-diagnostics-provider-enrollment.evtx",
                #"microsoft-windows-moderndeployment-diagnostics-provider-autopilot.evtx",
                #"microsoft-windows-moderndeployment-diagnostics-provider-diagnostics.evtx",
                "microsoft-windows-provisioning-diagnostics-provider-admin.evtx",
                "microsoft-windows-user device registration-admin.evtx"
            )

            $csvPaths = @()
            foreach ($evtxName in $evtxNames) {
                $evtxPath = Get-ChildItem -Path $extractPath -Recurse -Filter $evtxName -File | Select-Object -First 1
                if ($evtxPath) {
                    $csvPath = Join-Path $evtxPath.DirectoryName ($evtxName -replace '\.evtx$', '.csv')
                    Get-WinEvent -Path $evtxPath.FullName -ErrorAction SilentlyContinue | Export-Csv -Path $csvPath -NoTypeInformation
                    $logMessage = "Exported EVTX to CSV: $evtxName"
                    Write-Output $logMessage
                    Add-Content -Path $LogPath -Value $logMessage
                    $csvPaths += $csvPath
                }
            }

            # Find latest RegistryExportAfter CSV
            $registryFiles = Get-ChildItem -Path $extractPath -Recurse -Filter "RegistryExportAfter-*.csv" | Sort-Object Name -Descending
            $registryContent = ""
            if ($registryFiles.Count -gt 0) {
                $latestRegistry = $registryFiles[0]
                $registryContent = Get-Content -Path $latestRegistry.FullName | Out-String
                $logMessage = "Found latest registry file: $($latestRegistry.Name)"
                Write-Output $logMessage
                Add-Content -Path $LogPath -Value $logMessage
            } else {
                $logMessage = "No RegistryExportAfter CSV found."
                Write-Output $logMessage
                Add-Content -Path $LogPath -Value $logMessage
            }

            # Find latest dsregcmdoutput TXT
            $dsregFiles = Get-ChildItem -Path $extractPath -Recurse -Filter "dsregcmdoutput-*.txt" | Sort-Object Name -Descending
            $dsregContent = ""
            if ($dsregFiles.Count -gt 0) {
                $latestDsreg = $dsregFiles[0]
                $dsregContent = Get-Content -Path $latestDsreg.FullName | Out-String
                $logMessage = "Found latest dsregcmd file: $($latestDsreg.Name)"
                Write-Output $logMessage
                Add-Content -Path $LogPath -Value $logMessage
            } else {
                $logMessage = "No dsregcmdoutput TXT found."
                Write-Output $logMessage
                Add-Content -Path $LogPath -Value $logMessage
            }

            # Chunk CSVs to avoid token limits
            $partialAnalyses = @()
            $chunkSize = 1  # Adjusted to 1 CSV per chunk
            $uri = "https://api.openai.com/v1/chat/completions"
            $headers = @{
                "Authorization" = "Bearer $OpenAIAPIKey"
                "Content-Type" = "application/json"
            }
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

            for ($i = 0; $i -lt $csvPaths.Count; $i += $chunkSize) {
                $end = [math]::Min($i + $chunkSize - 1, $csvPaths.Count - 1)
                $chunk = $csvPaths[$i..$end]

                $chunkContents = ""
                foreach ($csv in $chunk) {
                    $csvData = Get-Content -Path $csv | Out-String
                    $chunkContents += "CSV File: $(Split-Path $csv -Leaf)`n$csvData`n`n"
                }

                # Partial prompt
                $prompt = $PartialPromptTemplate -f $chunkContents

                $body = @{
                    model = $ChatGPTModel
                    messages = @(
                        @{ role = "user"; content = $prompt }
                    )
                } | ConvertTo-Json -Depth 10

                try {
                    $apiResponse = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
                    $partial = $apiResponse.choices[0].message.content
                    $partialAnalyses += $partial
                    $logMessage = "Received partial analysis from ChatGPT for chunk starting at index $i"
                    Write-Output $logMessage
                    Add-Content -Path $LogPath -Value $logMessage
                } catch {
                    $logMessage = "Error in partial API call: $_"
                    Write-Output $logMessage
                    Add-Content -Path $LogPath -Value $logMessage
                    if ($_.Exception.Message -match "rate_limit_exceeded") {
                        Start-Sleep -Seconds 60  # Wait for rate limit reset
                        # Retry once
                        $apiResponse = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
                        $partial = $apiResponse.choices[0].message.content
                        $partialAnalyses += $partial
                    } else {
                        throw
                    }
                }
            }

            # Final summary prompt with partial analyses
            $finalPromptContents = $partialAnalyses -join "`n`n--- Partial Analysis Separator ---`n`n"

            $finalPrompt = $FinalPromptTemplate -f $finalPromptContents, $registryContent, $dsregContent

            $body = @{
                model = $ChatGPTModel
                messages = @(
                    @{ role = "user"; content = $finalPrompt }
                )
            } | ConvertTo-Json -Depth 10

            try {
                $apiResponse = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
                $analysis = $apiResponse.choices[0].message.content
                $logMessage = "Received final analysis from ChatGPT for $zipName"
                Write-Output $logMessage
                Add-Content -Path $LogPath -Value $logMessage
            } catch {
                $logMessage = "Error in final API call: $_"
                Write-Output $logMessage
                Add-Content -Path $LogPath -Value $logMessage
                if ($_.Exception.Message -match "rate_limit_exceeded") {
                    Start-Sleep -Seconds 60  # Wait for rate limit reset
                    # Retry once
                    $apiResponse = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
                    $analysis = $apiResponse.choices[0].message.content
                } else {
                    throw
                }
            }

            # Device name from beginning of folder name (assuming folder name starts with device name)
            $folderName = Split-Path $extractPath -Leaf
            $deviceName = $folderName.Split('_')[0]  # Adjust splitting logic if needed (e.g., by '-', etc.)

            # Create summary report as HTML
            $reportPath = Join-Path $extractPath "summary_report_$deviceName.html"
            $htmlContent = @"
<html>
<head><title>Summary Report for $deviceName</title></head>
<body>
<pre>$analysis</pre>
</body>
</html>
"@
            $htmlContent | Out-File -FilePath $reportPath -Encoding utf8
            $logMessage = "Created report: $reportPath"
            Write-Output $logMessage
            Add-Content -Path $LogPath -Value $logMessage

            # Mark as successful
            $successfullyProcessed += $zipName

            # Move ZIP to processed folder
            $processedPath = "processed"
            $processedDir = Get-AzStorageFile -Context $ctx -ShareName $FileShareName -Path $processedPath -ErrorAction SilentlyContinue
            if (-not $processedDir) {
                New-AzStorageDirectory -Context $ctx -ShareName $FileShareName -Path $processedPath
                $logMessage = "Created processed directory"
                Write-Output $logMessage
                Add-Content -Path $LogPath -Value $logMessage
            }
            $destPath = "$processedPath/$zipName"
            Start-AzStorageFileCopy -Context $ctx -SrcShareName $FileShareName -SrcFilePath $zipName -DestShareName $FileShareName -DestFilePath $destPath -Force
            Remove-AzStorageFile -Context $ctx -ShareName $FileShareName -Path $zipName
            $logMessage = "Moved $zipName to processed folder"
            Write-Output $logMessage
            Add-Content -Path $LogPath -Value $logMessage
        }
        catch {
            $logMessage = "Error processing ${zipName}: $_"
            Write-Output $logMessage
            Add-Content -Path $LogPath -Value $logMessage
        }
    }

    # Summary in log
    $logMessage = "Downloaded files: $($downloadedFiles -join ', ')"
    Write-Output $logMessage
    Add-Content -Path $LogPath -Value $logMessage
    $logMessage = "Successfully processed: $($successfullyProcessed -join ', ')"
    Write-Output $logMessage
    Add-Content -Path $LogPath -Value $logMessage
    $logMessage = "Script ended at $(Get-Date)"
    Write-Output $logMessage
    Add-Content -Path $LogPath -Value $logMessage
}
catch {
    $logMessage = "Global error: $_"
    Write-Output $logMessage
    Add-Content -Path $LogPath -Value $logMessage
    Write-Error "Global error: $_"
}

Write-Output "Script completed. Check log at $LogPath for details."
