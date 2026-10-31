# ==============================================================================
# Application : WinTable - Classic Bootable Windows USB Creator
# Environment : Pure PowerShell (No XAML, No C#, No WinForms, No Python)
# Style       : Classic White Background | 5:4 Aspect Ratio
# ==============================================================================

$ErrorActionPreference = 'SilentlyContinue'

# Ensure Administrator Privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Please run WinTable as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

# Configure Classic White Theme & 5:4 Aspect Ratio (80x64)
function Initialize-WinTableConsole {
    $Host.UI.RawUI.WindowTitle = "WinTable - Bootable Windows USB Creator"
    $Host.UI.RawUI.BackgroundColor = "White"
    $Host.UI.RawUI.ForegroundColor = "Black"
    
    try {
        $bufferSize = $Host.UI.RawUI.BufferSize
        $bufferSize.Width = 80
        $bufferSize.Height = 300
        $Host.UI.RawUI.BufferSize = $bufferSize

        $winSize = $Host.UI.RawUI.WindowSize
        $winSize.Width = 80
        $winSize.Height = 64
        $Host.UI.RawUI.WindowSize = $winSize
    } catch {
        # Fallback if terminal emulator restricts resizing
        mode con: cols=80 lines=64 | Out-Null
    }
    Clear-Host
}

# Global Application State
$Global:State = @{
    IsoPath          = "Not Selected"
    DetectedOS       = "None"
    ImageFile        = ""
    Editions         = @()
    SelectedEdition  = "None"
    SelectedIndex    = 1
    UsbDisks         = @()
    SelectedUsb      = $null
    BootableName     = "WINTABLE_USB"
    BypassEnabled    = $false
}

# Allowed Windows Versions
$AllowedOSPatterns = @(
    "Windows 11",
    "Windows 10",
    "Windows 8.1",
    "Windows 8",
    "Windows 7",
    "Windows Vista"
)

function Draw-Line {
    Write-Host ("=" * 78) -ForegroundColor DarkGray
}

function Draw-Header {
    Clear-Host
    Draw-Line
    Write-Host "                         W I N T A B L E   v 1 . 0                            " -ForegroundColor Blue
    Write-Host "                 Classic Windows Bootable USB Installation Tool               " -ForegroundColor DarkGray
    Draw-Line
    Write-Host ""
}

# Auto-Detect Attached USB Flash Drives and Brand Names
function Update-UsbDevices {
    $Global:State.UsbDisks = @()
    $disks = Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.OperationalStatus -eq 'Online' }
    
    foreach ($d in $disks) {
        $sizeGB = [math]::Round($d.Size / 1GB, 2)
        $brand  = ($d.Manufacturer + " " + $d.FriendlyName).Trim()
        if ([string]::IsNullOrWhiteSpace($brand)) {
            $brand = $d.FriendlyName
        }
        $Global:State.UsbDisks += [PSCustomObject]@{
            DiskNumber = $d.Number
            Brand      = $brand
            SizeGB     = $sizeGB
            RawDisk    = $d
        }
    }

    if ($Global:State.UsbDisks.Count -gt 0 -and $null -eq $Global:State.SelectedUsb) {
        $Global:State.SelectedUsb = $Global:State.UsbDisks[0]
    } elseif ($Global:State.UsbDisks.Count -eq 0) {
        $Global:State.SelectedUsb = $null
    }
}

# Mount ISO and Auto-Detect Allowed Windows OS & Editions
function Select-And-DetectIso {
    Write-Host ""
    Write-Host "Enter full path to Windows ISO file (e.g., C:\ISO\Win11.iso):" -ForegroundColor Blue
    $inputPath = (Read-Host "ISO Path").Trim('"')

    if (-not (Test-Path -Path $inputPath -PathType Leaf) -or ($inputPath -notmatch "\.iso$")) {
        Write-Host "Invalid ISO path. Please verify the file exists and ends with .iso" -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    Write-Host "Mounting ISO and auto-detecting Windows OS..." -ForegroundColor DarkCyan
    $mount = Mount-DiskImage -ImagePath $inputPath -PassThru
    $vol   = $mount | Get-Volume
    $driveLetter = "$($vol.DriveLetter):"

    $wimPath = Join-Path $driveLetter "sources\install.wim"
    $esdPath = Join-Path $driveLetter "sources\install.esd"
    $imgPath = ""

    if (Test-Path $wimPath) { $imgPath = $wimPath }
    elseif (Test-Path $esdPath) { $imgPath = $esdPath }

    if ([string]::IsNullOrEmpty($imgPath)) {
        Dismount-DiskImage -ImagePath $inputPath | Out-Null
        Write-Host "No valid Windows installation image (install.wim/esd) found inside ISO." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    $images = Get-WindowsImage -ImagePath $imgPath
    $matchedOS = $null

    foreach ($img in $images) {
        foreach ($os in $AllowedOSPatterns) {
            if ($img.ImageName -match [regex]::Escape($os) -or $img.ImageDescription -match [regex]::Escape($os)) {
                $matchedOS = $os
                break
            }
        }
        if ($null -ne $matchedOS) { break }
    }

    if ($null -eq $matchedOS) {
        Dismount-DiskImage -ImagePath $inputPath | Out-Null
        Write-Host "Unsupported OS detected. WinTable only supports:" -ForegroundColor Red
        Write-Host "Windows 11, Windows 10, Windows 8.1, Windows 8, Windows 7, Windows Vista." -ForegroundColor Red
        Start-Sleep -Seconds 3
        return
    }

    $Global:State.IsoPath         = $inputPath
    $Global:State.DetectedOS      = $matchedOS
    $Global:State.Editions        = @()

    foreach ($img in $images) {
        $Global:State.Editions += [PSCustomObject]@{
            Index = $img.ImageIndex
            Name  = $img.ImageName
        }
    }

    $Global:State.SelectedEdition = $Global:State.Editions[0].Name
    $Global:State.SelectedIndex   = $Global:State.Editions[0].Index

    Dismount-DiskImage -ImagePath $inputPath | Out-Null
}

# Select Windows Edition Variant
function Select-WindowsEdition {
    if ($Global:State.Editions.Count -eq 0) {
        Write-Host "Please upload/select a valid Windows ISO first." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ""
    Write-Host "Available Windows Variant Editions in ISO:" -ForegroundColor Blue
    for ($i = 0; $i -lt $Global:State.Editions.Count; $i++) {
        $ed = $Global:State.Editions[$i]
        Write-Host ("  [{0}] {1} (Index: {2})" -f ($i + 1), $ed.Name, $ed.Index)
    }

    $choice = Read-Host "Select Edition Number (1-$($Global:State.Editions.Count))"
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx)) {
        if ($idx -ge 1 -and $idx -le $Global:State.Editions.Count) {
            $selected = $Global:State.Editions[$idx - 1]
            $Global:State.SelectedEdition = $selected.Name
            $Global:State.SelectedIndex   = $selected.Index
        }
    }
}

# Select USB Flash Drive
function Select-UsbDevice {
    Update-UsbDevices
    if ($Global:State.UsbDisks.Count -eq 0) {
        Write-Host "No USB Flash Drive detected. Please insert a USB drive and try again." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ""
    Write-Host "Detected USB Flash Drives:" -ForegroundColor Blue
    for ($i = 0; $i -lt $Global:State.UsbDisks.Count; $i++) {
        $u = $Global:State.UsbDisks[$i]
        Write-Host ("  [{0}] Disk #{1} | Brand: {2} | Capacity: {3} GB" -f ($i + 1), $u.DiskNumber, $u.Brand, $u.SizeGB)
    }

    $choice = Read-Host "Select USB Number (1-$($Global:State.UsbDisks.Count))"
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx)) {
        if ($idx -ge 1 -and $idx -le $Global:State.UsbDisks.Count) {
            $Global:State.SelectedUsb = $Global:State.UsbDisks[$idx - 1]
        }
    }
}

# Apply Registry Bypass (Host + Target USB Autounattend & .reg Script)
function Set-WindowsBypassConfiguration {
    param([string]$UsbRootPath, [string]$EditionName)

    # 1. Apply directly to local system registry (LabConfig) with value 00000001
    $regPath = "HKLM:\SYSTEM\Setup\LabConfig"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    New-ItemProperty -Path $regPath -Name "BypassTPMCheck" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $regPath -Name "BypassSecureBootCheck" -Value 1 -PropertyType DWord -Force | Out-Null

    # 2. Create a .reg file on the USB drive for manual/repair accessibility
    $regContent = @"
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\LabConfig]
"BypassTPMCheck"=dword:00000001
"BypassSecureBootCheck"=dword:00000001
"@
    $regFilePath = Join-Path $UsbRootPath "WinTable_Bypass.reg"
    Set-Content -Path $regFilePath -Value $regContent -Encoding ASCII

    # 3. Create Autounattend.xml on the USB root to automatically apply the 00000001 registry values
    #    and pre-select the chosen Windows Edition Variant during Windows Setup
    $xmlContent = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                    <Order>1</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 00000001 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                    <Order>2</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 00000001 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
            <ImageInstall>
                <OSImage>
                    <InstallFrom>
                        <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                            <Key>/IMAGE/NAME</Key>
                            <Value>$EditionName</Value>
                        </MetaData>
                    </InstallFrom>
                </OSImage>
            </ImageInstall>
        </component>
    </settings>
</unattend>
"@
    $xmlFilePath = Join-Path $UsbRootPath "autounattend.xml"
    Set-Content -Path $xmlFilePath -Value $xmlContent -Encoding UTF8

    # 4. Configure ei.cfg in \sources so the chosen Windows Edition is unlocked
    $sourcesDir = Join-Path $UsbRootPath "sources"
    if (Test-Path $sourcesDir) {
        $eiCfg = @"
[Channel]
_Default
[VL]
0
"@
        Set-Content -Path (Join-Path $sourcesDir "ei.cfg") -Value $eiCfg -Encoding ASCII
    }
}

# Build the Bootable USB Flash Drive
function New-WinTableBootableUsb {
    if ($Global:State.IsoPath -eq "Not Selected" -or $Global:State.DetectedOS -eq "None") {
        Write-Host "Please select a valid Windows ISO file before creating the bootable USB." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    if ($null -eq $Global:State.SelectedUsb) {
        Write-Host "No USB Flash Drive selected. Please plug in and select a USB drive." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ""
    Draw-Line
    Write-Host "PREPARING TO CREATE BOOTABLE USB" -ForegroundColor Blue
    Write-Host "Target USB   : Disk #$($Global:State.SelectedUsb.DiskNumber) - $($Global:State.SelectedUsb.Brand) ($($Global:State.SelectedUsb.SizeGB) GB)"
    Write-Host "Windows OS   : $($Global:State.DetectedOS)"
    Write-Host "Edition      : $($Global:State.SelectedEdition)"
    Write-Host "Volume Label : $($Global:State.BootableName)"
    Write-Host "Bypass Check : $($Global:State.BypassEnabled) (TPM & SecureBoot = 00000001)"
    Draw-Line
    $confirm = Read-Host "Type 'YES' to format the USB drive and create the bootable installer"
    if ($confirm -ne "YES") {
        Write-Host "Operation cancelled by user." -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
        return
    }

    $diskNum = $Global:State.SelectedUsb.DiskNumber

    Write-Host "[1/5] Formatting and partitioning USB Drive (Disk #$diskNum)..." -ForegroundColor DarkCyan
    Clear-Disk -Number $diskNum -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $diskNum -PartitionStyle MBR

    $partition = New-Partition -DiskNumber $diskNum -UseMaximumSize -IsActive -AssignDriveLetter
    $usbDriveLetter = $partition.DriveLetter
    Format-Volume -DriveLetter $usbDriveLetter -FileSystem NTFS -NewFileSystemLabel $Global:State.BootableName -Confirm:$false | Out-Null

    $usbRoot = "$($usbDriveLetter):\"

    Write-Host "[2/5] Mounting Windows ISO image..." -ForegroundColor DarkCyan
    $mount = Mount-DiskImage -ImagePath $Global:State.IsoPath -PassThru
    $isoVol = $mount | Get-Volume
    $isoRoot = "$($isoVol.DriveLetter):\"

    Write-Host "[3/5] Making USB bootable and copying Windows installation files..." -ForegroundColor DarkCyan
    $bootsectPath = Join-Path $isoRoot "boot\bootsect.exe"
    if (Test-Path $bootsectPath) {
        & $bootsectPath /nt60 "$($usbDriveLetter):" /mbr | Out-Null
    }

    # Copy all files from ISO to USB
    robocopy $isoRoot $usbRoot /E /ZB /R:0 /W:0 /NFL /NDL /NJH /NJS | Out-Null

    Write-Host "[4/5] Applying Edition & Registry Bypass configurations..." -ForegroundColor DarkCyan
    if ($Global:State.BypassEnabled) {
        Set-WindowsBypassConfiguration -UsbRootPath $usbRoot -EditionName $Global:State.SelectedEdition
    }

    Write-Host "[5/5] Finalizing and dismounting ISO..." -ForegroundColor DarkCyan
    Dismount-DiskImage -ImagePath $Global:State.IsoPath | Out-Null

    # Success Screen & Automatic Restart into BIOS/UEFI
    Clear-Host
    Draw-Line
    Write-Host "                                S U C C E S S !                               " -ForegroundColor DarkGreen
    Draw-Line
    Write-Host ""
    Write-Host "Bootable USB '$($Global:State.BootableName)' has been created on $($Global:State.SelectedUsb.Brand) ($usbRoot)." -ForegroundColor Black
    Write-Host "Selected Edition: $($Global:State.SelectedEdition)" -ForegroundColor Black
    if ($Global:State.BypassEnabled) {
        Write-Host "Registry Bypass Applied: BypassTPMCheck = 00000001 | BypassSecureBootCheck = 00000001" -ForegroundColor DarkGreen
    }
    Write-Host ""
    Draw-Line
    Write-Host "IMPORTANT - BIOS / BOOT INSTRUCTIONS:" -ForegroundColor Blue
    Write-Host "  1. Your PC must now restart and enter the BIOS / UEFI Setup."
    Write-Host "  2. In the BIOS Boot Menu, select your USB Flash Drive: $($Global:State.SelectedUsb.Brand)."
    Write-Host "  3. Click Save or press F10, then press Enter to boot from the USB."
    Write-Host "  4. Follow the screen to install $($Global:State.SelectedEdition)."
    Draw-Line
    Write-Host ""
    
    $restartConfirm = Read-Host "Press ENTER to automatically restart PC into BIOS now (or type 'WAIT' to stay in WinTable)"
    if ($restartConfirm -ne "WAIT") {
        Write-Host "Restarting computer into BIOS/UEFI firmware in 3 seconds..." -ForegroundColor Blue
        Start-Sleep -Seconds 3
        # Attempt direct UEFI firmware reboot; fall back to standard reboot if legacy BIOS
        & shutdown.exe /r /fw /t 0
        if ($LASTEXITCODE -ne 0) {
            Restart-Computer -Force
        }
    }
}

# Main Interactive Loop (Never Auto-Closes)
Initialize-WinTableConsole
Update-UsbDevices

while ($true) {
    Draw-Header

    $usbDisplay = if ($null -ne $Global:State.SelectedUsb) {
        "Disk #$($Global:State.SelectedUsb.DiskNumber) | $($Global:State.SelectedUsb.Brand) ($($Global:State.SelectedUsb.SizeGB) GB)"
    } else {
        "No USB Flash Drive Detected (Insert USB and press 4)"
    }

    $bypassCheckMark = if ($Global:State.BypassEnabled) { "[X] Enabled (00000001)" } else { "[ ] Disabled" }

    Write-Host " CURRENT CONFIGURATION" -ForegroundColor Blue
    Write-Host " ----------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  ISO File          : {0}" -f $Global:State.IsoPath)
    Write-Host ("  Auto-Detected OS  : {0}" -f $Global:State.DetectedOS)
    Write-Host ("  Windows Variant   : {0} (Index #{1})" -f $Global:State.SelectedEdition, $Global:State.SelectedIndex)
    Write-Host ("  Bootable Name     : {0}" -f $Global:State.BootableName)
    Write-Host ("  USB Flash Drive   : {0}" -f $usbDisplay)
    Write-Host ("  Bypass Regedit    : {0}" -f $bypassCheckMark)
    Write-Host "                      (BypassTPMCheck = 00000001 & BypassSecureBootCheck = 00000001)" -ForegroundColor DarkGray
    Write-Host " ----------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host " WINTABLE CONTROLS" -ForegroundColor Blue
    Write-Host "  [1] Upload / Select Windows ISO File (Auto-Detect OS & Editions)"
    Write-Host "  [2] Choose Windows Variant Edition"
    Write-Host "  [3] Set Bootable USB Name (Volume Label)"
    Write-Host "  [4] Auto-Detect / Select USB Flash Drive & Brand"
    Write-Host "  [5] Toggle 'Bypass' Checkbox (TPM & SecureBoot Regedit = 00000001)"
    Write-Host "  [6] CREATE BOOTABLE USB" -ForegroundColor DarkGreen
    Write-Host "  [0] Exit WinTable"
    Write-Host ""
    Draw-Line

    $action = Read-Host "Select Option (0-6)"

    switch ($action) {
        "1" { Select-And-DetectIso }
        "2" { Select-WindowsEdition }
        "3" {
            $newName = Read-Host "Enter new Bootable USB Name (max 32 chars)"
            if (-not [string]::IsNullOrWhiteSpace($newName)) {
                $Global:State.BootableName = $newName.Trim()
            }
        }
        "4" { Select-UsbDevice }
        "5" { $Global:State.BypassEnabled = -not $Global:State.BypassEnabled }
        "6" { New-WinTableBootableUsb }
        "0" {
            Write-Host "Exiting WinTable..." -ForegroundColor DarkGray
            Read-Host "Press Enter to close window"
            break
        }
    }
}
