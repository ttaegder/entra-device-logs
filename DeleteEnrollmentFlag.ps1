# QUEST SOFTWARE INC. MAKES NO REPRESENTATIONS OR WARRANTIES
# ABOUT THE SUITABILITY OF THE SOFTWARE, EITHER EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED
# WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE, OR NON-INFRINGEMENT. QUEST SOFTWARE SHALL
# NOT BE LIABLE FOR ANY DAMAGES SUFFERED BY LICENSEE
# AS A RESULT OF USING, MODIFYING OR DISTRIBUTING
# THIS SOFTWARE OR ITS DERIVATIVES.

 #Requires -RunAsAdministrator 

# Script to delete the registry value HKLM\Software\Microsoft\Enrollments\MmpcEnrollmentFlag

$keyPath = "HKLM:\Software\Microsoft\Enrollments"
$valueName = "MmpcEnrollmentFlag"

if (Test-Path "$keyPath") {
    Remove-ItemProperty -Path $keyPath -Name $valueName -ErrorAction SilentlyContinue
    Write-Host "Registry value deleted successfully (if it existed)."
} else {
    Write-Host "Registry key does not exist."
}

