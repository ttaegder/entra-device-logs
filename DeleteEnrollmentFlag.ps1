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
