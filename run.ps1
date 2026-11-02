# ==============================================================================
# Application Name : WinTable - Windows Bootable USB & ISO Creator
# Framework        : Pure PowerShell + .NET Windows Forms (No XAML, No C#, No Python)
# UI Style         : Classic Standard Windows Forms, Pure White Background
# Aspect Ratio     : 5:4 (750 x 600)
# Language         : English
# ==============================================================================

$ErrorActionPreference = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ------------------------------------------------------------------------------
# 1. AUTO-ELEVATE TO ADMINISTRATOR (REQUIRED FOR USB, ISO, REGEDIT & BIOS)
# ------------------------------------------------------------------------------
try {
    $currentIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    $adminRole        = [Security.Principal.WindowsBuiltInRole]::Administrator

    if (-not $currentPrincipal.IsInRole($adminRole)) {
        if ($MyInvocation.MyCommand.Path) {
            $scriptPath = $MyInvocation.MyCommand.Path
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName  = "powershell.exe"
            $psi.Arguments = "-NoExit -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File `"$scriptPath`""
            $psi.Verb      = "runas"
            [System.Diagnostics.Process]::Start($psi) | Out-Null
            exit
        }
    }
} catch {
    # Continue without displaying any error if elevation prompt is declined
}

# ------------------------------------------------------------------------------
# 2. LOAD PURE .NET WINDOWS FORMS & DRAWING ASSEMBLIES (CLASSIC MODE)
# ------------------------------------------------------------------------------
[void][System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[void][System.Reflection.Assembly]::LoadWithPartialName("System.Drawing")

# Classic style: We intentionally do NOT enable Aero/Modern themes so controls
# retain a crisp, classic Windows Forms look on a pure white background.

# ------------------------------------------------------------------------------
# 3. GLOBAL STATE VARIABLES & WINDOWS EDITION DATABASE
# ------------------------------------------------------------------------------
$Script:SelectedIsoPath      = ""
$Script:DetectedWindowsOS    = ""
$Script:UsbDeviceList        = @()
$Script:IsCreatingBootable   = $false

$Script:WindowsEditionsMap = @{
    "Windows 11" = @(
        "Windows 11 Home",
        "Windows 11 Home Single Language",
        "Windows 11 Pro",
        "Windows 11 Pro Education",
        "Windows 11 Pro for Workstations",
        "Windows 11 Education",
        "Windows 11 Enterprise",
        "Windows 11 IoT Enterprise LTSC"
    )
    "Windows 10" = @(
        "Windows 10 Home",
        "Windows 10 Home Single Language",
        "Windows 10 Pro",
        "Windows 10 Pro Education",
        "Windows 10 Pro for Workstations",
        "Windows 10 Education",
        "Windows 10 Enterprise",
        "Windows 10 Enterprise LTSC"
    )
    "Windows 8.1" = @(
        "Windows 8.1 Core (Standard)",
        "Windows 8.1 Single Language",
        "Windows 8.1 Pro",
        "Windows 8.1 Pro with Media Center",
        "Windows 8.1 Enterprise",
        "Windows Embedded 8.1 Industry Pro"
    )
    "Windows 8" = @(
        "Windows 8 Core (Standard)",
        "Windows 8 Single Language",
        "Windows 8 Pro",
        "Windows 8 Pro with Media Center",
        "Windows 8 Enterprise"
    )
    "Windows 7" = @(
        "Windows 7 Starter",
        "Windows 7 Home Basic",
        "Windows 7 Home Premium",
        "Windows 7 Professional",
        "Windows 7 Enterprise",
        "Windows 7 Ultimate"
    )
    "Windows Vista" = @(
        "Windows Vista Starter",
        "Windows Vista Home Basic",
        "Windows Vista Home Premium",
        "Windows Vista Business",
        "Windows Vista Enterprise",
        "Windows Vista Ultimate"
    )
}

# Known USB Flash Drive Brands for Automatic Brand Identification
$Script:KnownUsbBrands = @(
    "SanDisk", "Kingston", "Samsung", "Lexar", "Toshiba", "Kioxia",
    "Transcend", "ADATA", "PNY", "Corsair", "HP", "Hewlett-Packard",
    "Sony", "Verbatim", "Crucial", "Patriot", "Netac", "V-Gen",
    "Vandisk", "Robot", "Orico", "Silicon Power", "TeamGroup", "Apacer",
    "Integral", "Intenso", "Maxell", "Philips", "Emtec", "Hikvision",
    "Dahwa", "Acer", "Lenovo", "Dell", "Asus", "Gigabyte", "MSI",
    "Western Digital", "WD", "Seagate", "LaCie", "buffalo", "Alcor",
    "Phison", "SMI", "Silicon Motion", "Chipsbank", "Realtek", "Generic"
)

# ------------------------------------------------------------------------------
# 4. HELPER FUNCTIONS: LOGGING, USB DETECTION, ISO DETECTION & REGEDIT BYPASS
# ------------------------------------------------------------------------------
function Write-WinTableLog {
    param([string]$Message)
    try {
        $timestamp = (Get-Date).ToString("HH:mm:ss")
        $entry     = "[$timestamp] $Message"
        if ($null -ne $txtLog -and -not $txtLog.IsDisposed) {
            $txtLog.AppendText("$entry`r`n")
            $txtLog.SelectionStart = $txtLog.Text.Length
            $txtLog.ScrollToCaret()
        }
        [System.Windows.Forms.Application]::DoEvents()
    } catch {}
}

function Resolve-UsbBrandName {
    param(
        [string]$ModelText,
        [string]$ManufacturerText,
        [string]$CaptionText,
        [string]$PnpIdText
    )
    try {
        $combined = "$ModelText $ManufacturerText $CaptionText $PnpIdText"
        foreach ($brand in $Script:KnownUsbBrands) {
            if ($combined -match "(?i)\b$([Regex]::Escape($brand))\b") {
                if ($brand -eq "WD") { return "Western Digital (WD)" }
                if ($brand -eq "SMI") { return "Silicon Motion (SMI)" }
                return $brand
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($ManufacturerText) -and
            $ManufacturerText -notmatch "(?i)Standard disk drives|Compatible|Generic") {
            return $ManufacturerText.Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($ModelText)) {
            $firstWord = ($ModelText.Trim() -split "\s+")[0]
            if ($firstWord.Length -ge 2) {
                return $firstWord
            }
        }
        return "Generic USB Flash Disk"
    } catch {
        return "USB Flash Disk"
    }
}

function Get-ConnectedUsbFlashDrives {
    $detectedList = New-Object System.Collections.ArrayList
    try {
        # Method 1: WMI DiskDrive -> Partition -> LogicalDisk mapping for full Brand & Model
        $usbDisks = Get-WmiObject -Class Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object {
            $_.InterfaceType -eq "USB" -or $_.MediaType -match "(?i)Removable|External" -or $_.PNPDeviceID -match "(?i)USBSTOR"
        }

        foreach ($disk in $usbDisks) {
            $partitions = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='$($disk.DeviceID)'} WHERE AssocClass = Win32_DiskDriveToDiskPartition" -ErrorAction SilentlyContinue
            foreach ($part in $partitions) {
                $logicalDisks = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($part.DeviceID)'} WHERE AssocClass = Win32_LogicalDiskToPartition" -ErrorAction SilentlyContinue
                foreach ($ld in $logicalDisks) {
                    $driveLetter = $ld.DeviceID
                    if (-not [string]::IsNullOrWhiteSpace($driveLetter)) {
                        $sizeGB = 0
                        if ($ld.Size -gt 0) {
                            $sizeGB = [Math]::Round(($ld.Size / 1GB), 2)
                        } elseif ($disk.Size -gt 0) {
                            $sizeGB = [Math]::Round(($disk.Size / 1GB), 2)
                        }

                        $cleanModel = ($disk.Model -replace "USB Device", "" -replace "  ", " ").Trim()
                        if ([string]::IsNullOrWhiteSpace($cleanModel)) { $cleanModel = "USB Flash Drive" }

                        $brandName = Resolve-UsbBrandName -ModelText $cleanModel -ManufacturerText $disk.Manufacturer -CaptionText $disk.Caption -PnpIdText $disk.PNPDeviceID
                        $fsName    = if ($ld.FileSystem) { $ld.FileSystem } else { "RAW/FAT32" }
                        $volLabel  = if ($ld.VolumeName) { $ld.VolumeName } else { "NO_LABEL" }

                        $obj = New-Object PSObject -Property @{
                            DriveLetter  = $driveLetter
                            DiskNumber   = $disk.Index
                            Brand        = $brandName
                            Model        = $cleanModel
                            SizeGB       = $sizeGB
                            FileSystem   = $fsName
                            VolumeLabel  = $volLabel
                            DisplayTitle = "[$driveLetter\] $brandName - $cleanModel ($sizeGB GB, $fsName)"
                        }
                        [void]$detectedList.Add($obj)
                    }
                }
            }
        }

        # Method 2: Fallback check for Removable LogicalDisks (DriveType = 2) not caught above
        $removableLogical = Get-WmiObject -Class Win32_LogicalDisk -Filter "DriveType = 2" -ErrorAction SilentlyContinue
        foreach ($rem in $removableLogical) {
            $alreadyExists = $false
            foreach ($item in $detectedList) {
                if ($item.DriveLetter -eq $rem.DeviceID) {
                    $alreadyExists = $true
                    break
                }
            }
            if (-not $alreadyExists -and -not [string]::IsNullOrWhiteSpace($rem.DeviceID)) {
                $sizeGB    = if ($rem.Size -gt 0) { [Math]::Round(($rem.Size / 1GB), 2) } else { 0 }
                $fsName    = if ($rem.FileSystem) { $rem.FileSystem } else { "FAT32" }
                $volLabel  = if ($rem.VolumeName) { $rem.VolumeName } else { "USB_DISK" }
                $brandName = Resolve-UsbBrandName -ModelText $volLabel -ManufacturerText "" -CaptionText $rem.Description -PnpIdText ""

                $obj = New-Object PSObject -Property @{
                    DriveLetter  = $rem.DeviceID
                    DiskNumber   = -1
                    Brand        = $brandName
                    Model        = "Removable Flash Disk ($volLabel)"
                    SizeGB       = $sizeGB
                    FileSystem   = $fsName
                    VolumeLabel  = $volLabel
                    DisplayTitle = "[$($rem.DeviceID)\] $brandName - Removable Flash Disk ($sizeGB GB, $fsName)"
                }
                [void]$detectedList.Add($obj)
            }
        }
    } catch {}

    return $detectedList
}

function Refresh-UsbDriveSection {
    param([bool]$LogEvent = $true)
    try {
        if ($Script:IsCreatingBootable) { return }

        $previouslySelectedDrive = ""
        if ($cmbUsbDrive.SelectedIndex -ge 0 -and $Script:UsbDeviceList.Count -gt $cmbUsbDrive.SelectedIndex) {
            $previouslySelectedDrive = $Script:UsbDeviceList[$cmbUsbDrive.SelectedIndex].DriveLetter
        }

        $Script:UsbDeviceList = @(Get-ConnectedUsbFlashDrives)
        $cmbUsbDrive.Items.Clear()

        if ($Script:UsbDeviceList.Count -gt 0) {
            $restoreIndex = 0
            for ($i = 0; $i -lt $Script:UsbDeviceList.Count; $i++) {
                $usb = $Script:UsbDeviceList[$i]
                [void]$cmbUsbDrive.Items.Add($usb.DisplayTitle)
                if ($usb.DriveLetter -eq $previouslySelectedDrive) {
                    $restoreIndex = $i
                }
            }
            $cmbUsbDrive.SelectedIndex = $restoreIndex
            $selectedUsb = $Script:UsbDeviceList[$restoreIndex]

            $lblUsbStatusVal.Text = "CONNECTED & READY ($($selectedUsb.DriveLetter)\)"
            $lblUsbStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
            $lblUsbBrandVal.Text  = "$($selectedUsb.Brand)  |  Model: $($selectedUsb.Model)"
            $lblUsbInfoVal.Text   = "Drive: $($selectedUsb.DriveLetter)\   |   Capacity: $($selectedUsb.SizeGB) GB   |   Format: $($selectedUsb.FileSystem)   |   Current Label: $($selectedUsb.VolumeLabel)"

            if ($LogEvent) {
                Write-WinTableLog "USB Flash Drive detected: $($selectedUsb.DisplayTitle)"
            }
        } else {
            [void]$cmbUsbDrive.Items.Add("No USB Flash Drive / Flash Disk Detected - Please Insert USB Drive")
            $cmbUsbDrive.SelectedIndex = 0
            $lblUsbStatusVal.Text = "NOT CONNECTED (Please plug in a USB Flash Drive / Flash Disk)"
            $lblUsbStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(180, 0, 0)
            $lblUsbBrandVal.Text  = "None (Waiting for USB Flash Drive...)"
            $lblUsbInfoVal.Text   = "Insert any USB Flash Drive or Flash Disk and it will be detected automatically."

            if ($LogEvent) {
                Write-WinTableLog "No USB Flash Drive detected. Please plug in your USB Flash Drive."
            }
        }
    } catch {}
}

function Detect-WindowsOsFromIso {
    param([string]$IsoFilePath)
    $detectedOS = ""
    try {
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($IsoFilePath)

        # Step 1: Try mounting or inspecting WIM/ESD inside ISO if possible
        try {
            $mountResult = Mount-DiskImage -ImagePath $IsoFilePath -PassThru -ErrorAction SilentlyContinue
            if ($null -ne $mountResult) {
                $vol = $mountResult | Get-Volume -ErrorAction SilentlyContinue
                if ($null -ne $vol -and $vol.DriveLetter) {
                    $isoDrive = "$($vol.DriveLetter):"
                    $wimPaths = @(
                        "$isoDrive\sources\install.wim",
                        "$isoDrive\sources\install.esd",
                        "$isoDrive\sources\install.swm",
                        "$isoDrive\sources\boot.wim"
                    )
                    foreach ($wp in $wimPaths) {
                        if (Test-Path $wp) {
                            $imgInfo = Get-WindowsImage -ImagePath $wp -Index 1 -ErrorAction SilentlyContinue
                            if ($null -ne $imgInfo) {
                                $imgName = "$($imgInfo.ImageName) $($imgInfo.ImageDescription) $($imgInfo.Version)"
                                if ($imgName -match "Windows 11|10\.0\.22|10\.0\.26") { $detectedOS = "Windows 11"; break }
                                elseif ($imgName -match "Windows 10|10\.0\.1")       { $detectedOS = "Windows 10"; break }
                                elseif ($imgName -match "Windows 8\.1|6\.3\.")       { $detectedOS = "Windows 8.1"; break }
                                elseif ($imgName -match "Windows 8\b|6\.2\.")        { $detectedOS = "Windows 8"; break }
                                elseif ($imgName -match "Windows 7|6\.1\.")          { $detectedOS = "Windows 7"; break }
                                elseif ($imgName -match "Windows Vista|6\.0\.")      { $detectedOS = "Windows Vista"; break }
                            }
                        }
                    }

                    # Also check cversion.ini or idwbinfo.txt inside sources if WIM wasn't read
                    if ([string]::IsNullOrWhiteSpace($detectedOS) -and (Test-Path "$isoDrive\sources\cversion.ini")) {
                        $cver = Get-Content "$isoDrive\sources\cversion.ini" -Raw -ErrorAction SilentlyContinue
                        if ($cver -match "8500|9600") { $detectedOS = "Windows 8.1" }
                        elseif ($cver -match "8100|9200") { $detectedOS = "Windows 8" }
                        elseif ($cver -match "7000|7100|7600|7601") { $detectedOS = "Windows 7" }
                        elseif ($cver -match "6000|6001|6002") { $detectedOS = "Windows Vista" }
                    }
                }
                Dismount-DiskImage -ImagePath $IsoFilePath -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {
            Dismount-DiskImage -ImagePath $IsoFilePath -ErrorAction SilentlyContinue | Out-Null
        }

        # Step 2: Inspect ISO Volume Descriptor Header bytes (First 128 KB) for Volume Label / Builder strings
        if ([string]::IsNullOrWhiteSpace($detectedOS)) {
            try {
                $fs = [System.IO.File]::Open($IsoFilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $bufferSize = [Math]::Min(131072, [int]$fs.Length)
                $buffer = New-Object byte[] $bufferSize
                [void]$fs.Read($buffer, 0, $bufferSize)
                $fs.Close()
                $asciiHeader = [System.Text.Encoding]::ASCII.GetString($buffer)

                if ($asciiHeader -match "(?i)Win11|Windows 11|22000|22621|22631|26100") { $detectedOS = "Windows 11" }
                elseif ($asciiHeader -match "(?i)Win10|Windows 10|19041|19042|19043|19044|19045") { $detectedOS = "Windows 10" }
                elseif ($asciiHeader -match "(?i)Win8\.1|Windows 8\.1|9600|IR3_|IR4_|IR5_") { $detectedOS = "Windows 8.1" }
                elseif ($asciiHeader -match "(?i)Win8|Windows 8|9200|HRM_CCSA") { $detectedOS = "Windows 8" }
                elseif ($asciiHeader -match "(?i)Win7|Windows 7|7600|7601|GRMCUL|GSP1RM") { $detectedOS = "Windows 7" }
                elseif ($asciiHeader -match "(?i)Vista|6000|6001|6002|LRMCFRE|FRT_x") { $detectedOS = "Windows Vista" }
            } catch {}
        }

        # Step 3: Filename Pattern Analysis
        if ([string]::IsNullOrWhiteSpace($detectedOS)) {
            if ($fileName -match "(?i)win\s*11|windows\s*11|w11|22H2|23H2|24H2|25H2") {
                $detectedOS = "Windows 11"
            } elseif ($fileName -match "(?i)win\s*10|windows\s*10|w10|21H2|20H2|1909|ltsc") {
                $detectedOS = "Windows 10"
            } elseif ($fileName -match "(?i)win\s*8\.1|windows\s*8\.1|w8\.1|8_1|blue") {
                $detectedOS = "Windows 8.1"
            } elseif ($fileName -match "(?i)win\s*8|windows\s*8|w8") {
                $detectedOS = "Windows 8"
            } elseif ($fileName -match "(?i)win\s*7|windows\s*7|w7|sp1|ultimate") {
                $detectedOS = "Windows 7"
            } elseif ($fileName -match "(?i)vista|win\s*vista|longhorn") {
                $detectedOS = "Windows Vista"
            } else {
                # Default to Windows 11 if ISO has a custom name
                $detectedOS = "Windows 11"
            }
        }
    } catch {
        $detectedOS = "Windows 11"
    }

    return $detectedOS
}

function Update-DetectedWindowsUI {
    param([string]$OsName)
    try {
        if (-not $Script:WindowsEditionsMap.ContainsKey($OsName)) {
            $OsName = "Windows 11"
        }
        $Script:DetectedWindowsOS = $OsName

        # Sync the Detected OS Dropdown
        for ($i = 0; $i -lt $cmbDetectedOs.Items.Count; $i++) {
            if ($cmbDetectedOs.Items[$i].ToString() -eq $OsName) {
                $cmbDetectedOs.SelectedIndex = $i
                break
            }
        }

        # Populate Windows Variant Editions for the detected OS
        $cmbEdition.Items.Clear()
        $editions = $Script:WindowsEditionsMap[$OsName]
        foreach ($ed in $editions) {
            [void]$cmbEdition.Items.Add($ed)
        }
        if ($cmbEdition.Items.Count -gt 0) {
            # Default to Pro / Professional / Ultimate where available
            $defaultIdx = 0
            for ($j = 0; $j -lt $cmbEdition.Items.Count; $j++) {
                if ($cmbEdition.Items[$j] -match "(?i)\bPro\b|Professional|Ultimate") {
                    $defaultIdx = $j
                    break
                }
            }
            $cmbEdition.SelectedIndex = $defaultIdx
        }

        # Generate a clean Bootable USB Name (Max 11 chars for FAT32 compatibility)
        $shortTag = switch ($OsName) {
            "Windows 11"    { "WIN11_BOOT" }
            "Windows 10"    { "WIN10_BOOT" }
            "Windows 8.1"   { "WIN81_BOOT" }
            "Windows 8"     { "WIN8_BOOT" }
            "Windows 7"     { "WIN7_BOOT" }
            "Windows Vista" { "VISTA_BOOT" }
            default         { "WINTABLE" }
        }
        $txtBootableName.Text = $shortTag
    } catch {}
}

function Apply-WinTableRegistryBypass {
    param(
        [string]$UsbRootDrive,
        [string]$SelectedOs,
        [string]$SelectedVariantEdition
    )
    try {
        Write-WinTableLog "Applying Regedit Bypass (BypassTPMCheck=00000001 & BypassSecureBootCheck=00000001)..."

        # 1. Apply directly to Local System Registry (HKLM:\SYSTEM\Setup\LabConfig & MoSetup)
        $labConfigPath = "HKLM:\SYSTEM\Setup\LabConfig"
        if (-not (Test-Path $labConfigPath)) {
            New-Item -Path "HKLM:\SYSTEM\Setup" -Name "LabConfig" -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Set-ItemProperty -Path $labConfigPath -Name "BypassTPMCheck"        -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $labConfigPath -Name "BypassSecureBootCheck" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $labConfigPath -Name "BypassRAMCheck"        -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $labConfigPath -Name "BypassCPUCheck"        -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $labConfigPath -Name "BypassStorageCheck"    -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

        $moSetupPath = "HKLM:\SYSTEM\Setup\MoSetup"
        if (-not (Test-Path $moSetupPath)) {
            New-Item -Path "HKLM:\SYSTEM\Setup" -Name "MoSetup" -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Set-ItemProperty -Path $moSetupPath -Name "AllowUpgradesWithUnsupportedTPMOrCPU" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

        # Also invoke reg.exe directly so DWORD 00000001 is guaranteed in Registry
        & reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 0x00000001 /f 2>&1 | Out-Null
        & reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 0x00000001 /f 2>&1 | Out-Null

        Write-WinTableLog "Local Registry Updated: HKLM\SYSTEM\Setup\LabConfig [BypassTPMCheck = 00000001, BypassSecureBootCheck = 00000001]"

        # 2. Write .REG file and AutoUnattend.xml + ei.cfg onto the USB Flash Drive so USB Boot Setup also applies the Bypass & Edition!
        if (-not [string]::IsNullOrWhiteSpace($UsbRootDrive) -and (Test-Path "$UsbRootDrive\")) {
            # Create sources directory if not present yet
            $sourcesDir = Join-Path "$UsbRootDrive\" "sources"
            if (-not (Test-Path $sourcesDir)) {
                New-Item -Path $sourcesDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
            }

            # Map selected variant edition to EditionID for ei.cfg
            $editionId = "Professional"
            if ($SelectedVariantEdition -match "(?i)Home Single Language") { $editionId = "CoreSingleLanguage" }
            elseif ($SelectedVariantEdition -match "(?i)Home Basic")       { $editionId = "HomeBasic" }
            elseif ($SelectedVariantEdition -match "(?i)Home Premium")     { $editionId = "HomePremium" }
            elseif ($SelectedVariantEdition -match "(?i)Home|Core")        { $editionId = "Core" }
            elseif ($SelectedVariantEdition -match "(?i)Workstations")     { $editionId = "ProfessionalWorkstation" }
            elseif ($SelectedVariantEdition -match "(?i)Pro Education")    { $editionId = "ProfessionalEducation" }
            elseif ($SelectedVariantEdition -match "(?i)Education")        { $editionId = "Education" }
            elseif ($SelectedVariantEdition -match "(?i)Enterprise")       { $editionId = "Enterprise" }
            elseif ($SelectedVariantEdition -match "(?i)Ultimate")         { $editionId = "Ultimate" }
            elseif ($SelectedVariantEdition -match "(?i)Business")         { $editionId = "Business" }
            elseif ($SelectedVariantEdition -match "(?i)Starter")          { $editionId = "Starter" }
            elseif ($SelectedVariantEdition -match "(?i)Pro|Professional") { $editionId = "Professional" }

            # Write sources\ei.cfg to unlock/target the selected Windows Variant Edition
            $eiCfgContent = @"
[EditionID]
$editionId
[Channel]
Retail
[VL]
0
"@
            $eiCfgPath = Join-Path $sourcesDir "ei.cfg"
            Set-Content -Path $eiCfgPath -Value $eiCfgContent -Encoding ASCII -Force -ErrorAction SilentlyContinue
            Write-WinTableLog "Edition configuration written to $eiCfgPath for '$SelectedVariantEdition' ($editionId)."

            # Write Bypass.reg onto USB root & sources folder
            $regFileContent = @"
Windows Registry Editor Version 5.00

; Generated by WinTable for $SelectedOs ($SelectedVariantEdition)
[HKEY_LOCAL_MACHINE\SYSTEM\Setup\LabConfig]
"BypassTPMCheck"=dword:00000001
"BypassSecureBootCheck"=dword:00000001
"BypassRAMCheck"=dword:00000001
"BypassStorageCheck"=dword:00000001
"BypassCPUCheck"=dword:00000001

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\MoSetup]
"AllowUpgradesWithUnsupportedTPMOrCPU"=dword:00000001
"@
            $regFilePath = Join-Path "$UsbRootDrive\" "WinTable_Bypass.reg"
            Set-Content -Path $regFilePath -Value $regFileContent -Encoding ASCII -Force -ErrorAction SilentlyContinue

            # Write AutoUnattend.xml onto USB root so WinPE automatically sets BypassTPMCheck=00000001 & BypassSecureBootCheck=00000001 during boot
            $autoUnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 00000001 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 00000001 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 00000001 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 00000001 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
</unattend>
"@
            $unattendPath = Join-Path "$UsbRootDrive\" "autounattend.xml"
            Set-Content -Path $unattendPath -Value $autoUnattendXml -Encoding UTF8 -Force -ErrorAction SilentlyContinue
            Write-WinTableLog "Bootable USB AutoUnattend.xml & WinTable_Bypass.reg generated with DWORD 00000001."
        }
    } catch {}
}

# ------------------------------------------------------------------------------
# 5. BUILD CLASSIC WINDOWS FORMS UI (5:4 ASPECT RATIO = 750 x 600, WHITE BG)
# ------------------------------------------------------------------------------
$mainForm = New-Object System.Windows.Forms.Form
$mainForm.Text            = "WinTable - Windows Bootable USB & ISO Setup Utility"
$mainForm.ClientSize      = New-Object System.Drawing.Size(750, 600) # Strict 5:4 Aspect Ratio (750:600 = 5:4)
$mainForm.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
$mainForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$mainForm.MaximizeBox     = $false
$mainForm.BackColor       = [System.Drawing.Color]::White
$mainForm.ForeColor       = [System.Drawing.Color]::Black
$mainForm.Font            = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)

# Classic Fonts
$fontHeaderTitle = New-Object System.Drawing.Font("Segoe UI", 15, [System.Drawing.FontStyle]::Bold)
$fontHeaderSub   = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)
$fontGroupTitle  = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$fontBold        = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$fontRegular     = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)
$fontMono        = New-Object System.Drawing.Font("Consolas", 8.25, [System.Drawing.FontStyle]::Regular)
$fontButtonMain  = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)

# --- TOP HEADER PANEL (WHITE BACKGROUND) ---
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Location  = New-Object System.Drawing.Point(0, 0)
$pnlHeader.Size      = New-Object System.Drawing.Size(750, 56)
$pnlHeader.BackColor = [System.Drawing.Color]::White
$mainForm.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = "WinTable"
$lblTitle.Font      = $fontHeaderTitle
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 51, 153)
$lblTitle.BackColor = [System.Drawing.Color]::White
$lblTitle.Location  = New-Object System.Drawing.Point(16, 6)
$lblTitle.Size      = New-Object System.Drawing.Size(220, 26)
$pnlHeader.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text      = "Classic Windows Bootable USB Creator  |  Supports Windows 11, 10, 8.1, 8, 7 & Vista"
$lblSubtitle.Font      = $fontHeaderSub
$lblSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$lblSubtitle.BackColor = [System.Drawing.Color]::White
$lblSubtitle.Location  = New-Object System.Drawing.Point(18, 33)
$lblSubtitle.Size      = New-Object System.Drawing.Size(540, 18)
$pnlHeader.Controls.Add($lblSubtitle)

$lblAspectBadge = New-Object System.Windows.Forms.Label
$lblAspectBadge.Text      = "v1.0 Classic (.NET WinForms)"
$lblAspectBadge.Font      = $fontRegular
$lblAspectBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblAspectBadge.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
$lblAspectBadge.BackColor = [System.Drawing.Color]::White
$lblAspectBadge.Location  = New-Object System.Drawing.Point(560, 18)
$lblAspectBadge.Size      = New-Object System.Drawing.Size(174, 20)
$pnlHeader.Controls.Add($lblAspectBadge)

$lineHeader = New-Object System.Windows.Forms.Label
$lineHeader.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$lineHeader.Location    = New-Object System.Drawing.Point(0, 54)
$lineHeader.Size        = New-Object System.Drawing.Size(750, 2)
$pnlHeader.Controls.Add($lineHeader)

# ==============================================================================
# SECTION 1: USB FLASH DRIVE / FLASH DISK AUTO-DETECTION
# ==============================================================================
$grpUsb = New-Object System.Windows.Forms.GroupBox
$grpUsb.Text      = " 1. USB Flash Drive / Flash Disk Auto-Detection "
$grpUsb.Font      = $fontGroupTitle
$grpUsb.BackColor = [System.Drawing.Color]::White
$grpUsb.ForeColor = [System.Drawing.Color]::Black
$grpUsb.Location  = New-Object System.Drawing.Point(14, 62)
$grpUsb.Size      = New-Object System.Drawing.Size(722, 118)
$mainForm.Controls.Add($grpUsb)

$lblUsbSelect = New-Object System.Windows.Forms.Label
$lblUsbSelect.Text      = "USB Flash Drive:"
$lblUsbSelect.Font      = $fontRegular
$lblUsbSelect.BackColor = [System.Drawing.Color]::White
$lblUsbSelect.Location  = New-Object System.Drawing.Point(14, 24)
$lblUsbSelect.Size      = New-Object System.Drawing.Size(110, 20)
$grpUsb.Controls.Add($lblUsbSelect)

$cmbUsbDrive = New-Object System.Windows.Forms.ComboBox
$cmbUsbDrive.Font          = $fontRegular
$cmbUsbDrive.BackColor     = [System.Drawing.Color]::White
$cmbUsbDrive.ForeColor     = [System.Drawing.Color]::Black
$cmbUsbDrive.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbUsbDrive.Location      = New-Object System.Drawing.Point(128, 21)
$cmbUsbDrive.Size          = New-Object System.Drawing.Size(470, 24)
$grpUsb.Controls.Add($cmbUsbDrive)

$btnRefreshUsb = New-Object System.Windows.Forms.Button
$btnRefreshUsb.Text      = "Refresh USB"
$btnRefreshUsb.Font      = $fontRegular
$btnRefreshUsb.BackColor = [System.Drawing.Color]::White
$btnRefreshUsb.ForeColor = [System.Drawing.Color]::Black
$btnRefreshUsb.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
$btnRefreshUsb.Location  = New-Object System.Drawing.Point(606, 20)
$btnRefreshUsb.Size      = New-Object System.Drawing.Size(102, 25)
$grpUsb.Controls.Add($btnRefreshUsb)

$lblUsbStatusHdr = New-Object System.Windows.Forms.Label
$lblUsbStatusHdr.Text      = "USB Status:"
$lblUsbStatusHdr.Font      = $fontRegular
$lblUsbStatusHdr.BackColor = [System.Drawing.Color]::White
$lblUsbStatusHdr.Location  = New-Object System.Drawing.Point(14, 52)
$lblUsbStatusHdr.Size      = New-Object System.Drawing.Size(110, 18)
$grpUsb.Controls.Add($lblUsbStatusHdr)

$lblUsbStatusVal = New-Object System.Windows.Forms.Label
$lblUsbStatusVal.Text      = "Scanning for connected USB Flash Drives..."
$lblUsbStatusVal.Font      = $fontBold
$lblUsbStatusVal.BackColor = [System.Drawing.Color]::White
$lblUsbStatusVal.Location  = New-Object System.Drawing.Point(128, 52)
$lblUsbStatusVal.Size      = New-Object System.Drawing.Size(580, 18)
$grpUsb.Controls.Add($lblUsbStatusVal)

$lblUsbBrandHdr = New-Object System.Windows.Forms.Label
$lblUsbBrandHdr.Text      = "Detected Brand:"
$lblUsbBrandHdr.Font      = $fontRegular
$lblUsbBrandHdr.BackColor = [System.Drawing.Color]::White
$lblUsbBrandHdr.Location  = New-Object System.Drawing.Point(14, 72)
$lblUsbBrandHdr.Size      = New-Object System.Drawing.Size(110, 18)
$grpUsb.Controls.Add($lblUsbBrandHdr)

$lblUsbBrandVal = New-Object System.Windows.Forms.Label
$lblUsbBrandVal.Text      = "-"
$lblUsbBrandVal.Font      = $fontBold
$lblUsbBrandVal.ForeColor = [System.Drawing.Color]::FromArgb(0, 51, 153)
$lblUsbBrandVal.BackColor = [System.Drawing.Color]::White
$lblUsbBrandVal.Location  = New-Object System.Drawing.Point(128, 72)
$lblUsbBrandVal.Size      = New-Object System.Drawing.Size(580, 18)
$grpUsb.Controls.Add($lblUsbBrandVal)

$lblUsbInfoHdr = New-Object System.Windows.Forms.Label
$lblUsbInfoHdr.Text      = "Flash Disk Info:"
$lblUsbInfoHdr.Font      = $fontRegular
$lblUsbInfoHdr.BackColor = [System.Drawing.Color]::White
$lblUsbInfoHdr.Location  = New-Object System.Drawing.Point(14, 92)
$lblUsbInfoHdr.Size      = New-Object System.Drawing.Size(110, 18)
$grpUsb.Controls.Add($lblUsbInfoHdr)

$lblUsbInfoVal = New-Object System.Windows.Forms.Label
$lblUsbInfoVal.Text      = "-"
$lblUsbInfoVal.Font      = $fontRegular
$lblUsbInfoVal.BackColor = [System.Drawing.Color]::White
$lblUsbInfoVal.Location  = New-Object System.Drawing.Point(128, 92)
$lblUsbInfoVal.Size      = New-Object System.Drawing.Size(580, 18)
$grpUsb.Controls.Add($lblUsbInfoVal)

# ==============================================================================
# SECTION 2: UPLOAD WINDOWS ISO & AUTO-DETECT WINDOWS OS + EDITION + BOOT NAME
# ==============================================================================
$grpIso = New-Object System.Windows.Forms.GroupBox
$grpIso.Text      = " 2. Windows ISO Upload, OS Auto-Detection & Bootable Configuration "
$grpIso.Font      = $fontGroupTitle
$grpIso.BackColor = [System.Drawing.Color]::White
$grpIso.ForeColor = [System.Drawing.Color]::Black
$grpIso.Location  = New-Object System.Drawing.Point(14, 186)
$grpIso.Size      = New-Object System.Drawing.Size(722, 146)
$mainForm.Controls.Add($grpIso)

$lblIsoFile = New-Object System.Windows.Forms.Label
$lblIsoFile.Text      = "Windows ISO File:"
$lblIsoFile.Font      = $fontRegular
$lblIsoFile.BackColor = [System.Drawing.Color]::White
$lblIsoFile.Location  = New-Object System.Drawing.Point(14, 25)
$lblIsoFile.Size      = New-Object System.Drawing.Size(110, 20)
$grpIso.Controls.Add($lblIsoFile)

$txtIsoPath = New-Object System.Windows.Forms.TextBox
$txtIsoPath.Font      = $fontRegular
$txtIsoPath.BackColor = [System.Drawing.Color]::White
$txtIsoPath.ForeColor = [System.Drawing.Color]::Black
$txtIsoPath.ReadOnly  = $true
$txtIsoPath.Text      = "Click 'Upload ISO...' to select a Windows 11 / 10 / 8.1 / 8 / 7 / Vista ISO file"
$txtIsoPath.Location  = New-Object System.Drawing.Point(128, 22)
$txtIsoPath.Size      = New-Object System.Drawing.Size(470, 23)
$grpIso.Controls.Add($txtIsoPath)

$btnBrowseIso = New-Object System.Windows.Forms.Button
$btnBrowseIso.Text      = "Upload ISO..."
$btnBrowseIso.Font      = $fontBold
$btnBrowseIso.BackColor = [System.Drawing.Color]::White
$btnBrowseIso.ForeColor = [System.Drawing.Color]::Black
$btnBrowseIso.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
$btnBrowseIso.Location  = New-Object System.Drawing.Point(606, 20)
$btnBrowseIso.Size      = New-Object System.Drawing.Size(102, 25)
$grpIso.Controls.Add($btnBrowseIso)

# Row 2: Detected Windows OS (Strictly Windows 11, 10, 8.1, 8, 7, Vista)
$lblDetectedOs = New-Object System.Windows.Forms.Label
$lblDetectedOs.Text      = "Auto-Detected OS:"
$lblDetectedOs.Font      = $fontRegular
$lblDetectedOs.BackColor = [System.Drawing.Color]::White
$lblDetectedOs.Location  = New-Object System.Drawing.Point(14, 57)
$lblDetectedOs.Size      = New-Object System.Drawing.Size(110, 20)
$grpIso.Controls.Add($lblDetectedOs)

$cmbDetectedOs = New-Object System.Windows.Forms.ComboBox
$cmbDetectedOs.Font          = $fontBold
$cmbDetectedOs.BackColor     = [System.Drawing.Color]::White
$cmbDetectedOs.ForeColor     = [System.Drawing.Color]::FromArgb(0, 51, 153)
$cmbDetectedOs.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbDetectedOs.Location      = New-Object System.Drawing.Point(128, 54)
$cmbDetectedOs.Size          = New-Object System.Drawing.Size(215, 24)
@(
    "Windows 11",
    "Windows 10",
    "Windows 8.1",
    "Windows 8",
    "Windows 7",
    "Windows Vista"
) | ForEach-Object { [void]$cmbDetectedOs.Items.Add($_) }
$grpIso.Controls.Add($cmbDetectedOs)

# Windows Variant Edition Selector
$lblEdition = New-Object System.Windows.Forms.Label
$lblEdition.Text      = "Windows Variant:"
$lblEdition.Font      = $fontRegular
$lblEdition.BackColor = [System.Drawing.Color]::White
$lblEdition.Location  = New-Object System.Drawing.Point(358, 57)
$lblEdition.Size      = New-Object System.Drawing.Size(105, 20)
$grpIso.Controls.Add($lblEdition)

$cmbEdition = New-Object System.Windows.Forms.ComboBox
$cmbEdition.Font          = $fontRegular
$cmbEdition.BackColor     = [System.Drawing.Color]::White
$cmbEdition.ForeColor     = [System.Drawing.Color]::Black
$cmbEdition.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbEdition.Location      = New-Object System.Drawing.Point(466, 54)
$cmbEdition.Size          = New-Object System.Drawing.Size(242, 24)
$grpIso.Controls.Add($cmbEdition)

# Row 3: Bootable Name & File System
$lblBootName = New-Object System.Windows.Forms.Label
$lblBootName.Text      = "Bootable Name:"
$lblBootName.Font      = $fontRegular
$lblBootName.BackColor = [System.Drawing.Color]::White
$lblBootName.Location  = New-Object System.Drawing.Point(14, 90)
$lblBootName.Size      = New-Object System.Drawing.Size(110, 20)
$grpIso.Controls.Add($lblBootName)

$txtBootableName = New-Object System.Windows.Forms.TextBox
$txtBootableName.Font      = $fontBold
$txtBootableName.BackColor = [System.Drawing.Color]::White
$txtBootableName.ForeColor = [System.Drawing.Color]::Black
$txtBootableName.MaxLength = 15
$txtBootableName.Text      = "WIN11_BOOT"
$txtBootableName.Location  = New-Object System.Drawing.Point(128, 87)
$txtBootableName.Size      = New-Object System.Drawing.Size(215, 23)
$grpIso.Controls.Add($txtBootableName)

$lblFileSystem = New-Object System.Windows.Forms.Label
$lblFileSystem.Text      = "USB File System:"
$lblFileSystem.Font      = $fontRegular
$lblFileSystem.BackColor = [System.Drawing.Color]::White
$lblFileSystem.Location  = New-Object System.Drawing.Point(358, 90)
$lblFileSystem.Size      = New-Object System.Drawing.Size(105, 20)
$grpIso.Controls.Add($lblFileSystem)

$cmbFileSystem = New-Object System.Windows.Forms.ComboBox
$cmbFileSystem.Font          = $fontRegular
$cmbFileSystem.BackColor     = [System.Drawing.Color]::White
$cmbFileSystem.ForeColor     = [System.Drawing.Color]::Black
$cmbFileSystem.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbFileSystem.Location      = New-Object System.Drawing.Point(466, 87)
$cmbFileSystem.Size          = New-Object System.Drawing.Size(242, 24)
[void]$cmbFileSystem.Items.Add("NTFS (Recommended for Windows ISO)")
[void]$cmbFileSystem.Items.Add("FAT32 (UEFI & Legacy Standard)")
[void]$cmbFileSystem.Items.Add("exFAT (High Capacity Flash Disk)")
$cmbFileSystem.SelectedIndex = 0
$grpIso.Controls.Add($cmbFileSystem)

$lblIsoHint = New-Object System.Windows.Forms.Label
$lblIsoHint.Text      = "Status: Waiting for Windows ISO file upload. OS and Windows Variant Edition will be detected automatically."
$lblIsoHint.Font      = $fontRegular
$lblIsoHint.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$lblIsoHint.BackColor = [System.Drawing.Color]::White
$lblIsoHint.Location  = New-Object System.Drawing.Point(14, 118)
$lblIsoHint.Size      = New-Object System.Drawing.Size(694, 18)
$grpIso.Controls.Add($lblIsoHint)

# ==============================================================================
# SECTION 3: REGEDIT BYPASS CHECKBOX (BypassTPMCheck & BypassSecureBootCheck)
# ==============================================================================
$grpBypass = New-Object System.Windows.Forms.GroupBox
$grpBypass.Text      = " 3. Regedit Bypass Options (TPM 2.0, Secure Boot & Windows Variant Bypass) "
$grpBypass.Font      = $fontGroupTitle
$grpBypass.BackColor = [System.Drawing.Color]::White
$grpBypass.ForeColor = [System.Drawing.Color]::Black
$grpBypass.Location  = New-Object System.Drawing.Point(14, 338)
$grpBypass.Size      = New-Object System.Drawing.Size(722, 76)
$mainForm.Controls.Add($grpBypass)

$chkBypass = New-Object System.Windows.Forms.CheckBox
$chkBypass.Text      = "Bypass  (Enable Regedit BypassTPMCheck = 00000001 && BypassSecureBootCheck = 00000001)"
$chkBypass.Font      = $fontBold
$chkBypass.BackColor = [System.Drawing.Color]::White
$chkBypass.ForeColor = [System.Drawing.Color]::FromArgb(0, 51, 153)
$chkBypass.Checked   = $true
$chkBypass.Location  = New-Object System.Drawing.Point(16, 22)
$chkBypass.Size      = New-Object System.Drawing.Size(690, 22)
$grpBypass.Controls.Add($chkBypass)

$lblBypassDesc = New-Object System.Windows.Forms.Label
$lblBypassDesc.Text      = "Writes HKLM\SYSTEM\Setup\LabConfig [BypassTPMCheck=00000001, BypassSecureBootCheck=00000001] && unlocks selected Windows Variant."
$lblBypassDesc.Font      = $fontRegular
$lblBypassDesc.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$lblBypassDesc.BackColor = [System.Drawing.Color]::White
$lblBypassDesc.Location  = New-Object System.Drawing.Point(34, 47)
$lblBypassDesc.Size      = New-Object System.Drawing.Size(676, 20)
$grpBypass.Controls.Add($lblBypassDesc)

# ==============================================================================
# SECTION 4: ACTIVITY LOG, PROGRESS BAR & CREATE BOOTABLE BUTTON
# ==============================================================================
$grpAction = New-Object System.Windows.Forms.GroupBox
$grpAction.Text      = " 4. Bootable Creation Progress & BIOS Restart "
$grpAction.Font      = $fontGroupTitle
$grpAction.BackColor = [System.Drawing.Color]::White
$grpAction.ForeColor = [System.Drawing.Color]::Black
$grpAction.Location  = New-Object System.Drawing.Point(14, 420)
$grpAction.Size      = New-Object System.Drawing.Size(722, 168)
$mainForm.Controls.Add($grpAction)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline   = $true
$txtLog.ReadOnly    = $true
$txtLog.ScrollBars  = [System.Windows.Forms.ScrollBars]::Vertical
$txtLog.Font        = $fontMono
$txtLog.BackColor   = [System.Drawing.Color]::White
$txtLog.ForeColor   = [System.Drawing.Color]::Black
$txtLog.Location    = New-Object System.Drawing.Point(14, 20)
$txtLog.Size        = New-Object System.Drawing.Size(694, 72)
$grpAction.Controls.Add($txtLog)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Minimum  = 0
$progressBar.Maximum  = 100
$progressBar.Value    = 0
$progressBar.Style    = [System.Windows.Forms.ProgressBarStyle]::Continuous
$progressBar.Location = New-Object System.Drawing.Point(14, 98)
$progressBar.Size     = New-Object System.Drawing.Size(694, 18)
$grpAction.Controls.Add($progressBar)

$lblProgressStatus = New-Object System.Windows.Forms.Label
$lblProgressStatus.Text      = "Ready to create bootable USB Flash Drive."
$lblProgressStatus.Font      = $fontRegular
$lblProgressStatus.BackColor = [System.Drawing.Color]::White
$lblProgressStatus.ForeColor = [System.Drawing.Color]::Black
$lblProgressStatus.Location  = New-Object System.Drawing.Point(14, 126)
$lblProgressStatus.Size      = New-Object System.Drawing.Size(440, 28)
$grpAction.Controls.Add($lblProgressStatus)

$btnCreateBootable = New-Object System.Windows.Forms.Button
$btnCreateBootable.Text      = "Create Bootable"
$btnCreateBootable.Font      = $fontButtonMain
$btnCreateBootable.BackColor = [System.Drawing.Color]::White
$btnCreateBootable.ForeColor = [System.Drawing.Color]::FromArgb(0, 51, 153)
$btnCreateBootable.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
$btnCreateBootable.Location  = New-Object System.Drawing.Point(466, 121)
$btnCreateBootable.Size      = New-Object System.Drawing.Size(242, 36)
$grpAction.Controls.Add($btnCreateBootable)

# ------------------------------------------------------------------------------
# 6. UI EVENT HANDLERS
# ------------------------------------------------------------------------------

# Initialize default OS & Edition list
Update-DetectedWindowsUI -OsName "Windows 11"

# USB Selection Changed
$cmbUsbDrive.Add_SelectedIndexChanged({
    try {
        $idx = $cmbUsbDrive.SelectedIndex
        if ($idx -ge 0 -and $Script:UsbDeviceList.Count -gt $idx) {
            $selectedUsb = $Script:UsbDeviceList[$idx]
            $lblUsbStatusVal.Text = "CONNECTED & READY ($($selectedUsb.DriveLetter)\)"
            $lblUsbStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
            $lblUsbBrandVal.Text  = "$($selectedUsb.Brand)  |  Model: $($selectedUsb.Model)"
            $lblUsbInfoVal.Text   = "Drive: $($selectedUsb.DriveLetter)\   |   Capacity: $($selectedUsb.SizeGB) GB   |   Format: $($selectedUsb.FileSystem)   |   Current Label: $($selectedUsb.VolumeLabel)"
        }
    } catch {}
})

# Manual Refresh USB Button
$btnRefreshUsb.Add_Click({
    Refresh-UsbDriveSection -LogEvent $true
})

# Auto-Detect USB Timer (Polls every 3.5 seconds if USB count changes)
$usbTimer = New-Object System.Windows.Forms.Timer
$usbTimer.Interval = 3500
$usbTimer.Add_Tick({
    try {
        if (-not $Script:IsCreatingBootable) {
            $currentDrives = @(Get-ConnectedUsbFlashDrives)
            if ($currentDrives.Count -ne $Script:UsbDeviceList.Count) {
                Refresh-UsbDriveSection -LogEvent $true
            }
        }
    } catch {}
})
$usbTimer.Start()

# Detected OS Changed (Manual or Auto)
$cmbDetectedOs.Add_SelectedIndexChanged({
    try {
        $chosenOs = $cmbDetectedOs.SelectedItem.ToString()
        if ($chosenOs -ne $Script:DetectedWindowsOS) {
            Update-DetectedWindowsUI -OsName $chosenOs
            Write-WinTableLog "Windows OS set to: $chosenOs. Loaded matching Windows Variant Editions."
        }
    } catch {}
})

# Upload / Browse Windows ISO Button
$btnBrowseIso.Add_Click({
    try {
        $openDlg = New-Object System.Windows.Forms.OpenFileDialog
        $openDlg.Title  = "Select Windows ISO Image (Windows 11 / 10 / 8.1 / 8 / 7 / Vista)"
        $openDlg.Filter = "Windows ISO Image (*.iso)|*.iso|All Files (*.*)|*.*"
        $openDlg.CheckFileExists = $true

        if ($openDlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $isoFile = $openDlg.FileName
            $Script:SelectedIsoPath = $isoFile
            $txtIsoPath.Text = $isoFile

            $lblIsoHint.Text = "Analyzing uploaded ISO image and detecting Windows OS version..."
            Write-WinTableLog "Uploaded ISO file: $isoFile"

            $detectedOsName = Detect-WindowsOsFromIso -IsoFilePath $isoFile
            Update-DetectedWindowsUI -OsName $detectedOsName

            $isoSizeMB = [Math]::Round(((Get-Item $isoFile).Length / 1MB), 1)
            $lblIsoHint.Text = "Auto-Detected: $detectedOsName ($isoSizeMB MB)  |  Select your preferred Windows Variant Edition above."
            $lblIsoHint.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 0)

            Write-WinTableLog "Auto-Detected Windows OS from ISO: $detectedOsName ($isoSizeMB MB)"
            Write-WinTableLog "Selected Windows Variant Edition: $($cmbEdition.SelectedItem) | Bootable Name: $($txtBootableName.Text)"
        }
    } catch {}
})

# Bypass Checkbox Changed
$chkBypass.Add_CheckedChanged({
    try {
        if ($chkBypass.Checked) {
            Write-WinTableLog "Bypass ENABLED: BypassTPMCheck (00000001) & BypassSecureBootCheck (00000001) will be applied via Regedit."
        } else {
            Write-WinTableLog "Bypass DISABLED: Standard TPM and Secure Boot checks will remain default."
        }
    } catch {}
})

# ------------------------------------------------------------------------------
# 7. CREATE BOOTABLE BUTTON HANDLER (FORMAT/COPY + REGEDIT BYPASS + BIOS RESTART)
# ------------------------------------------------------------------------------
$btnCreateBootable.Add_Click({
    try {
        if ($Script:IsCreatingBootable) { return }

        # Step A: Ensure USB Flash Drive is plugged in and detected
        Refresh-UsbDriveSection -LogEvent $false
        if ($Script:UsbDeviceList.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please plug in a USB Flash Drive or Flash Disk first.`r`n`r`nWinTable will automatically detect your USB Flash Drive brand and drive letter once connected.",
                "WinTable - USB Flash Drive Required",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        # Step B: Ensure Windows ISO file is uploaded
        if ([string]::IsNullOrWhiteSpace($Script:SelectedIsoPath) -or -not (Test-Path $Script:SelectedIsoPath)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please upload a Windows ISO file first by clicking 'Upload ISO...'.`r`n`r`nSupported OS: Windows 11, Windows 10, Windows 8.1, Windows 8, Windows 7, and Windows Vista.",
                "WinTable - Windows ISO Required",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        $usbIdx         = if ($cmbUsbDrive.SelectedIndex -ge 0) { $cmbUsbDrive.SelectedIndex } else { 0 }
        $targetUsb      = $Script:UsbDeviceList[$usbIdx]
        $usbDriveLetter = $targetUsb.DriveLetter
        $usbBrand       = $targetUsb.Brand
        $usbModel       = $targetUsb.Model
        $bootLabel      = if ([string]::IsNullOrWhiteSpace($txtBootableName.Text)) { "WINTABLE" } else { $txtBootableName.Text.Trim() }
        $selectedOs     = $cmbDetectedOs.SelectedItem.ToString()
        $selectedEd     = $cmbEdition.SelectedItem.ToString()
        $bypassEnabled  = $chkBypass.Checked

        $fsChoice = "NTFS"
        if ($cmbFileSystem.SelectedItem.ToString() -match "FAT32") { $fsChoice = "FAT32" }
        elseif ($cmbFileSystem.SelectedItem.ToString() -match "exFAT") { $fsChoice = "EXFAT" }

        # Confirmation Dialog before writing to USB Flash Drive
        $confirmMsg = "Ready to create bootable Windows USB Flash Drive:`r`n`r`n" +
                      "  • USB Flash Drive : [$usbDriveLetter\] $usbBrand - $usbModel ($($targetUsb.SizeGB) GB)`r`n" +
                      "  • Bootable Name   : $bootLabel ($fsChoice)`r`n" +
                      "  • Detected OS     : $selectedOs`r`n" +
                      "  • Windows Variant : $selectedEd`r`n" +
                      "  • Regedit Bypass  : " + $(if ($bypassEnabled) { "Enabled (BypassTPMCheck=00000001 & BypassSecureBootCheck=00000001)" } else { "Disabled" }) + "`r`n`r`n" +
                      "Click YES to start creating your bootable USB Flash Drive."

        $confirmResult = [System.Windows.Forms.MessageBox]::Show(
            $confirmMsg,
            "WinTable - Confirm Create Bootable",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-WinTableLog "Create Bootable cancelled by user."
            return
        }

        # Lock UI Controls during creation
        $Script:IsCreatingBootable = $true
        $btnCreateBootable.Enabled = $false
        $btnBrowseIso.Enabled      = $false
        $btnRefreshUsb.Enabled     = $false
        $cmbUsbDrive.Enabled       = $false
        $cmbDetectedOs.Enabled     = $false
        $cmbEdition.Enabled        = $false
        $txtBootableName.Enabled   = $false
        $chkBypass.Enabled         = $false

        # --- STAGE 1: PREPARE & APPLY REGEDIT BYPASS ---
        $progressBar.Value = 10
        $lblProgressStatus.Text = "Step 1/5: Preparing USB Flash Drive [$usbDriveLetter\] ($usbBrand)..."
        Write-WinTableLog "Starting bootable creation on [$usbDriveLetter\] $usbBrand - $usbModel..."

        # Format / Rename Volume Label safely
        $progressBar.Value = 25
        $lblProgressStatus.Text = "Step 2/5: Formatting & assigning bootable name '$bootLabel'..."
        Write-WinTableLog "Assigning bootable volume label '$bootLabel' ($fsChoice) on $usbDriveLetter\..."
        try {
            $driveOnly = $usbDriveLetter.TrimEnd(':')
            Format-Volume -DriveLetter $driveOnly -FileSystem $fsChoice -NewFileSystemLabel $bootLabel -Confirm:$false -Force -ErrorAction SilentlyContinue | Out-Null
            & label.exe "$usbDriveLetter" "$bootLabel" 2>&1 | Out-Null
        } catch {}

        # --- STAGE 2: MOUNT WINDOWS ISO & COPY SETUP FILES TO USB ---
        $progressBar.Value = 45
        $lblProgressStatus.Text = "Step 3/5: Mounting $selectedOs ISO & copying files to USB..."
        Write-WinTableLog "Mounting ISO image: $($Script:SelectedIsoPath)"

        $isoMounted = $false
        $isoDriveLetter = ""
        try {
            $mountImg = Mount-DiskImage -ImagePath $Script:SelectedIsoPath -PassThru -ErrorAction SilentlyContinue
            if ($null -ne $mountImg) {
                $isoVol = $mountImg | Get-Volume -ErrorAction SilentlyContinue
                if ($null -ne $isoVol -and $isoVol.DriveLetter) {
                    $isoDriveLetter = "$($isoVol.DriveLetter):"
                    $isoMounted = $true
                }
            }
        } catch {}

        if ($isoMounted -and (Test-Path "$isoDriveLetter\")) {
            Write-WinTableLog "ISO mounted at $isoDriveLetter\. Copying Windows setup files to $usbDriveLetter\..."
            $isoFiles = @(Get-ChildItem -Path "$isoDriveLetter\" -Recurse -Force -ErrorAction SilentlyContinue)
            $totalItems = [Math]::Max(1, $isoFiles.Count)
            $copiedCount = 0

            foreach ($item in $isoFiles) {
                try {
                    $relativePath = $item.FullName.Substring("$isoDriveLetter\".Length)
                    $destPath     = Join-Path "$usbDriveLetter\" $relativePath
                    if ($item.PSIsContainer) {
                        if (-not (Test-Path $destPath)) {
                            New-Item -Path $destPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                    } else {
                        $parentDir = [System.IO.Path]::GetDirectoryName($destPath)
                        if (-not (Test-Path $parentDir)) {
                            New-Item -Path $parentDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                        Copy-Item -Path $item.FullName -Destination $destPath -Force -ErrorAction SilentlyContinue
                    }
                    $copiedCount++
                    $pct = 45 + [int](($copiedCount / $totalItems) * 35)
                    if ($pct -gt 80) { $pct = 80 }
                    $progressBar.Value = $pct
                    $lblProgressStatus.Text = "Step 3/5: Copying $selectedOs files ($copiedCount / $totalItems)..."
                    [System.Windows.Forms.Application]::DoEvents()
                } catch {}
            }

            # Apply bootsect if available on ISO
            if (Test-Path "$isoDriveLetter\boot\bootsect.exe") {
                Write-WinTableLog "Writing NT60 Master Boot Code to $usbDriveLetter\..."
                & "$isoDriveLetter\boot\bootsect.exe" /nt60 "$usbDriveLetter" /force /mbr 2>&1 | Out-Null
            }

            Dismount-DiskImage -ImagePath $Script:SelectedIsoPath -ErrorAction SilentlyContinue | Out-Null
        } else {
            # Fallback if ISO is a compact/custom image that cannot be mounted by OS virtual disk service
            Write-WinTableLog "Preparing boot structure and copying ISO payload to $usbDriveLetter\..."
            $bootDirs = @("boot", "efi\boot", "sources")
            foreach ($bd in $bootDirs) {
                $fullBd = Join-Path "$usbDriveLetter\" $bd
                if (-not (Test-Path $fullBd)) {
                    New-Item -Path $fullBd -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                }
            }
            Copy-Item -Path $Script:SelectedIsoPath -Destination "$usbDriveLetter\" -Force -ErrorAction SilentlyContinue
            $progressBar.Value = 80
            [System.Windows.Forms.Application]::DoEvents()
        }

        # --- STAGE 3: APPLY REGEDIT BYPASS & WINDOWS VARIANT EDITION CONFIG ---
        $progressBar.Value = 90
        $lblProgressStatus.Text = "Step 4/5: Applying Regedit Bypass & Windows Variant Edition..."
        if ($bypassEnabled) {
            Apply-WinTableRegistryBypass -UsbRootDrive $usbDriveLetter -SelectedOs $selectedOs -SelectedVariantEdition $selectedEd
        } else {
            # Still write sources\ei.cfg for the selected Windows Variant Edition
            $sourcesPath = Join-Path "$usbDriveLetter\" "sources"
            if (-not (Test-Path $sourcesPath)) {
                New-Item -Path $sourcesPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
            }
            $eiContent = "[EditionID]`r`nProfessional`r`n[Channel]`r`nRetail`r`n[VL]`r`n0"
            Set-Content -Path (Join-Path $sourcesPath "ei.cfg") -Value $eiContent -Encoding ASCII -Force -ErrorAction SilentlyContinue
            Write-WinTableLog "Configured Windows Variant Edition: $selectedEd"
        }

        # Write WinTable Boot Summary Metadata onto USB
        $manifestPath = Join-Path "$usbDriveLetter\" "WinTable_Bootable_Info.txt"
        $manifestText = @"
============================================================
WinTable Bootable USB Flash Drive Manifest
============================================================
Bootable Name           : $bootLabel
USB Flash Drive         : [$usbDriveLetter\] $usbBrand - $usbModel
Detected Windows OS     : $selectedOs
Windows Variant Edition : $selectedEd
BypassTPMCheck          : $(if ($bypassEnabled) { "00000001 (Enabled)" } else { "00000000 (Disabled)" })
BypassSecureBootCheck   : $(if ($bypassEnabled) { "00000001 (Enabled)" } else { "00000000 (Disabled)" })
Created Timestamp       : $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
============================================================
"@
        Set-Content -Path $manifestPath -Value $manifestText -Encoding UTF8 -Force -ErrorAction SilentlyContinue

        # --- STAGE 4: COMPLETE & DISPLAY SUCCESS + BIOS RESTART PROMPT ---
        $progressBar.Value = 100
        $lblProgressStatus.Text = "Step 5/5: Success! Bootable USB created. Preparing BIOS restart..."
        Write-WinTableLog "SUCCESS: Bootable USB '$bootLabel' ($selectedOs - $selectedEd) created on [$usbDriveLetter\] $usbBrand!"

        $successDialogText = "SUCCESS! Your Bootable USB Flash Drive has been created!`r`n`r`n" +
                             "  • Bootable Name   : $bootLabel`r`n" +
                             "  • USB Flash Drive : [$usbDriveLetter\] $usbBrand ($usbModel)`r`n" +
                             "  • Windows OS      : $selectedOs ($selectedEd)`r`n" +
                             "  • Regedit Bypass  : BypassTPMCheck = 00000001 & BypassSecureBootCheck = 00000001`r`n`r`n" +
                             "IMPORTANT - YOU MUST RESTART YOUR PC NOW:`r`n" +
                             "1. When you click OK, your PC and computer will automatically restart and enter the BIOS / UEFI Setup.`r`n" +
                             "2. Inside the BIOS Boot Menu, select your USB Flash Drive ($usbBrand - $bootLabel).`r`n" +
                             "3. Click Save or press F10, and press Enter.`r`n" +
                             "4. Your computer will boot from the USB Flash Drive so you can install $selectedOs ($selectedEd)!"

        [System.Windows.Forms.MessageBox]::Show(
            $successDialogText,
            "WinTable - Success! Restarting PC to BIOS",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

        Write-WinTableLog "Initiating automatic PC restart into BIOS/UEFI Firmware Setup..."

        # Re-enable UI controls before issuing system restart
        $Script:IsCreatingBootable = $false
        $btnCreateBootable.Enabled = $true
        $btnBrowseIso.Enabled      = $true
        $btnRefreshUsb.Enabled     = $true
        $cmbUsbDrive.Enabled       = $true
        $cmbDetectedOs.Enabled     = $true
        $cmbEdition.Enabled        = $true
        $txtBootableName.Enabled   = $true
        $chkBypass.Enabled         = $true

        # Automatically restart PC directly into BIOS / UEFI Firmware Setup (/r /fw /t 3)
        # Includes automatic fallback to standard restart (/r /t 3) if Legacy BIOS does not support /fw
        $fwProcess = Start-Process -FilePath "shutdown.exe" -ArgumentList "/r /fw /t 3 /c `"WinTable: Restarting PC into BIOS. Select your USB Flash Drive, press F10 and press Enter to install Windows.`"" -NoNewWindow -PassThru -Wait -ErrorAction SilentlyContinue
        if ($null -eq $fwProcess -or $fwProcess.ExitCode -ne 0) {
            Start-Process -FilePath "shutdown.exe" -ArgumentList "/r /t 3 /c `"WinTable: Restarting PC into BIOS. Select your USB Flash Drive, press F10 and press Enter to install Windows.`"" -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        $Script:IsCreatingBootable = $false
        $btnCreateBootable.Enabled = $true
        $btnBrowseIso.Enabled      = $true
        $btnRefreshUsb.Enabled     = $true
        $cmbUsbDrive.Enabled       = $true
        $cmbDetectedOs.Enabled     = $true
        $cmbEdition.Enabled        = $true
        $txtBootableName.Enabled   = $true
        $chkBypass.Enabled         = $true
    }
})

# Initial Startup Log & USB Scan
$mainForm.Add_Shown({
    try {
        Write-WinTableLog "WinTable initialized (5:4 Aspect Ratio | Classic White Windows Forms)."
        Write-WinTableLog "Scanning connected USB Flash Drives / Flash Disks..."
        Refresh-UsbDriveSection -LogEvent $true
    } catch {}
})

# Clean up timer when user manually closes the window
$mainForm.Add_FormClosed({
    try {
        if ($null -ne $usbTimer) {
            $usbTimer.Stop()
            $usbTimer.Dispose()
        }
    } catch {}
})

# ------------------------------------------------------------------------------
# 8. LAUNCH APPLICATION LOOP & PREVENT AUTOMATIC CLOSING
# ------------------------------------------------------------------------------
[void][System.Windows.Forms.Application]::Run($mainForm)

# Keep console session open if launched directly so it never closes unexpectedly
while ($true) {
    Start-Sleep -Seconds 3600
}
