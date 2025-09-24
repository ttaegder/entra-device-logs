QUEST SOFTWARE INC. MAKES NO REPRESENTATIONS OR WARRANTIES
ABOUT THE SUITABILITY OF THE SOFTWARE, EITHER EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE, OR NON-INFRINGEMENT. QUEST SOFTWARE SHALL
NOT BE LIABLE FOR ANY DAMAGES SUFFERED BY LICENSEE
AS A RESULT OF USING, MODIFYING OR DISTRIBUTING
THIS SOFTWARE OR ITS DERIVATIVES.

# Summary
The purpose of the steps and scripts below are to gather logs pertaining to the Entra ID join process from an end-user device, upload the logs to an Azure File Share, then process the logs from a Migration Administrator workstation where they can be manually analyzed or sent to ChatGPT for AI analysis.

# Create Azure File Share

1. Create Azure Resource group
2. Create Storage account
3. In Storage account, create Data storage | File shares | + File share
4. In Storage account | Security + networking, create Shared access signature (SAS) key
5. We will need two keys:
	1. Write only key - This key will be included in the MDM Diagnostics and File Upload Script to be ran on end-user desktops. Will only allow writing to the File share.
	2. Admin key - Full rights can be used. This key will be used only by Migration Administrators to download and process logs.

Here are a couple of screenshots that can be used as guidance for creating the limited "Write Only" SAS key:

<img width="1223" height="921" alt="CreateSASwriteOnly" src="https://github.com/user-attachments/assets/df2c9ef7-7324-41e0-8486-44c2d5c4d1e3" />
<img width="1640" height="462" alt="SASwriteString" src="https://github.com/user-attachments/assets/8502d8a7-cbfa-468d-8c1d-e4938107d4d9" />

# MDM Diagnostics and File Upload Script (GetMDMLogs.ps1)

## Overview
This PowerShell script automates the collection of MDM diagnostics, registry data, and device status, compresses the collected files, and uploads them to an Azure File Share. It is designed to assist in gathering diagnostic information for Intune/Entra ID/Autopilot configurations, handling open files using Volume Shadow Copy, and cleaning up temporary files after execution.

## Functionality
1. **Creates Base Directories**: Ensures the base path (`C:\Program Files (x86)\Quest\On Demand Migration Active Directory Agent`) and Files subdirectory exist.
2. **MDM Diagnostics**: Runs `mdmdiagnosticstool.exe` to collect diagnostics for DeviceEnrollment, DeviceProvisioning, and Autopilot, saving output to a zip file (`MDMDiagRprt-MMddyy-HHmm.zip`) in the Files directory.
3. **Registry Export**: Exports specified registry keys related to Intune/Entra ID/Autopilot to a CSV file (`RegistryExportAfter-MMddyy-HHmm.csv`) in the Files directory. Optionally logs registry operations to `ExportLog.txt` (disabled by default).
4. **Device Status**: Runs `dsregcmd /status` and saves output to a text file (`dsregcmdoutput-MMddyy-HHmm.txt`) in the Files directory.
5. **AzCopy Installation**: Downloads and installs AzCopy to a temporary directory for file upload.
6. **File Compression**: Uses Volume Shadow Copy to handle open files, copies the Files directory contents to a temporary location, and compresses them into a zip file (`<ComputerName>-MMddyy-HHmm.zip`).
7. **Azure Upload**: Uploads the compressed zip file to a specified Azure File Share using AzCopy.
8. **Cleanup**: Deletes temporary files, directories, the MDM diagnostics zip, and the compressed zip (if upload succeeds), as well as the AzCopy installation.

## Settings
- **Azure File Share Destination**: Set the `$destination` variable at the top of the script with your Azure File Share URL, including the SAS token.
- **AzCopy Installation Path**: Defined as `$AzCopyInstallLoc` (`C:\Program Files (x86)\Quest\On Demand Migration Active Directory Agent\AzCopy`).
- **Registry Export Log**: Controlled by `$CreateExportLog` (default: `$false`, no log created).
- **File Paths**: All output files are stored in `$filesPath` (`C:\Program Files (x86)\Quest\On Demand Migration Active Directory Agent\Files`).

## How to Use
1. **Prerequisites**:
   - PowerShell 5.1 or later.
   - Administrative privileges (required for Volume Shadow Copy and registry access).
   - Internet access for downloading AzCopy.
   - `mdmdiagnosticstool.exe` must be available in the system PATH or accessible directory.
2. **Configure the Script**:
   - Edit the `$destination` variable with your Azure File Share URL and SAS token.
   - Optionally set `$CreateExportLog = $true` to enable registry export logging.
3. **Run the Script**:
   - Save the script (e.g., `MDMDiagAndUpload.ps1`).
   - Open PowerShell as Administrator.
   - Execute: `.\MDMDiagAndUpload.ps1`
4. **Expected Output**:
   - Console logs detailing each step (diagnostics, registry export, file compression, upload, and cleanup).
   - Files generated in the Files directory: `MDMDiagRprt-MMddyy-HHmm.zip`, `RegistryExportAfter-MMddyy-HHmm.csv`, `dsregcmdoutput-MMddyy-HHmm.txt`, and `ExportLog.txt` (if enabled).
   - A final zip file (`<ComputerName>-MMddyy-HHmm.zip`) uploaded to the Azure File Share.
   - All temporary files and directories (including zips) are deleted upon successful upload.

## Notes
- The script handles open files using Volume Shadow Copy to ensure reliable compression.
- If the Azure upload fails, the compressed zip file is retained for troubleshooting.
- The MDM diagnostics zip is always deleted during cleanup.
- Ensure the Azure SAS token has sufficient permissions for file upload.
- Run with elevated privileges to avoid permission errors.

For issues, review console output for error messages or enable `$CreateExportLog` for detailed registry operation logs.



# Azure File Share Log Processing Script (ProcessMDMLogs.ps1)

## Overview
This PowerShell script automates the processing of ZIP files containing Windows event logs, registry exports, and dsregcmd status outputs stored in an Azure File Share. It downloads, extracts, converts event logs to CSV, and optionally sends data to OpenAI's ChatGPT for analysis of Entra ID/Intune join failures. The script generates an HTML report for each processed ZIP and moves the ZIP to a "processed" folder in the Azure File Share.

## Functionality
1. **Download and Extract**: Downloads ZIP files from an Azure File Share, extracts them, and processes nested ZIPs (e.g., `MDMDiagRprt-*.zip`).
2. **Event Log Conversion**: Converts specified Windows Event Viewer logs (e.g., `microsoft-windows-provisioning-diagnostics-provider-admin.evtx`) to CSV.
3. **Optional AI Analysis**: Sends CSV event logs, registry exports (`RegistryExportAfter-*.csv`), and dsregcmd outputs (`dsregcmdoutput-*.txt`) to ChatGPT for analysis of Entra ID/Intune issues, if enabled.
4. **Report Generation**: Creates an HTML report per ZIP with analysis results (or a placeholder if AI is disabled).
5. **File Management**: Moves processed ZIPs to a "processed" folder in the Azure File Share.
6. **Logging**: Outputs detailed logs to both a `process_log.txt` file and the PowerShell console.

## Configuration Variables
- `$StorageAccountName`: Azure Storage Account name.
- `$FileShareName`: Azure File Share name.
- `$SasToken`: SAS token for Azure File Share access (starts with `?sv=`).
- `$LocalDownloadPath`: Local directory for processing (default: `C:\Temp\AzureFiles`).
- `$OpenAIAPIKey`: OpenAI API key for ChatGPT analysis.
- `$ChatGPTModel`: Model for analysis (e.g., `gpt-5-mini`).
- `$AI_Analysis`: `Enabled` or `Disabled` (default); controls ChatGPT analysis.
- `$IncludeDsRegCmdStatusData`: `Enabled` or `Disabled` (default); includes `dsregcmdoutput-*.txt` in AI analysis.
- `$IncludeRegistryData`: `Enabled` or `Disabled` (default); includes `RegistryExportAfter-*.csv` in AI analysis.

## Prerequisites
- PowerShell 5.1 or later.
- `Az.Storage` module (`Install-Module -Name Az.Storage`).
- Valid Azure Storage Account credentials and SAS token.
- OpenAI API key (if `$AI_Analysis` is `Enabled`).

## How to Use
1. **Set Variables**: Update the configuration variables at the top of the script with your Azure and OpenAI credentials.
2. **Run the Script**: Execute in PowerShell (e.g., `.\script.ps1`).
3. **Monitor Output**: Check the console and `process_log.txt` in `$LocalDownloadPath` for progress and errors.
4. **Review Reports**: Find HTML reports in subfolders of `$LocalDownloadPath` named after each ZIP (e.g., `summary_report_<DeviceName>.html`).

## Expected Output
- **Local Files**: Extracted files and CSVs in `$LocalDownloadPath\<ZIPName>\`, with an HTML report per ZIP.
- **Azure File Share**: Processed ZIPs moved to a "processed" folder.
- **Logs**: Detailed logs in `process_log.txt` and console, listing downloaded files, processing steps, and errors.
- **Analysis**: If `$AI_Analysis` is `Enabled`, reports contain ChatGPT analysis of event logs, registry, and dsregcmd data (based on `$IncludeDsRegCmdStatusData` and `$IncludeRegistryData`).

## Notes
- Ensure sufficient disk space in `$LocalDownloadPath`.
- Monitor OpenAI API rate limits if `$AI_Analysis` is enabled.
- Check `process_log.txt` for troubleshooting issues (e.g., missing files or API errors).
