#########################################################################################################
<#
# .SYNOPSIS
#   Disable Safe Mode if your Windows VM is booting in Safe Mode. Also activates Safe Mode
#   if you require it (e.g. to uninstall certain software).
#
# .DESCRIPTION
#   Azure VMs do not natively support Safe Mode because RDP access is disabled in Safe Mode. Some users
#   need to boot their VM in Safe Mode for specific reasons (e.g. uninstalling certain software). Other
#   users may find their VM booting into Safe Mode inadvertantly due to user error or misconfiguration,
#   which will disable RDP access until corrected. This script utilizes the az vm repair extension to
#   clone the VM into a Hyper-V environment using Nested Virtualization and toggle Safe Boot. The user
#   may then access their VM in Safe Mode via the Rescue VM or revert Safe Mode on their Azure VM. They
#   may then swap the disk using the `az vm repair restore` functionality.
#
#   Testing:
#       1. Copied scripts to newly created Windows Server 2019 Datacenter (Gen 1)
#       2. Ran win-enable-nested-hyperv once to install Hyper-V, restarted, and ran again to create new nested VM
#       3. Ran win-toggle-safe-mode.ps1, worked successfully in toggling Safe Mode
#       4. Set up new VM and ran the following from my local machine, worked successfully (~69 seconds):
#           az vm repair run -g sourcevm_group -n sourcevm --custom-script-file .\win-toggle-safe-mode.ps1 --verbose --run-on-repair
#       5. Tried on a WS 2016 Gen 2 Azure VM, but was unsuccessful, not compatible with Gen 2 right now
#       6. Tested on WS2012R2, WS2016 Datacenter, and WS2019 Datacenter (Gen 1)
#
#   https://docs.microsoft.com/en-us/cli/azure/ext/vm-repair/vm/repair?view=azure-cli-latest
#   https://docs.microsoft.com/en-us/troubleshoot/azure/virtual-machines/troubleshoot-rdp-safe-mode
#
# .PARAMETER safeModeSwitch
#   "On" to enable Safe Mode, "Off" to disable Safe Mode, no parameter to toggle whatever the current state is.
#
# .EXAMPLE
#   az vm repair run -g sourceRG -n sourceVM --run-id win-toggle-safe-mode --verbose --run-on-repair
#   az vm repair run -g sourceRG -n sourceVM --run-id win-toggle-safe-mode --parameters safeModeSwitch=on --verbose --run-on-repair
#   az vm repair run -g sourceRG -n sourceVM --run-id win-toggle-safe-mode --parameters safeModeSwitch=off --verbose --run-on-repair
#   az vm repair run -g sourceRG -n sourceVM --run-id win-toggle-safe-mode --parameters safeModeSwitch=off DC=$true --verbose --run-on-repair
#
# .NOTES
#   Author: Ryan McCallum
#
# .VERSION
    v0.3: [July 2023] - Detect if a Domain Controller from the attached OS drive's imported registry
#   v0.2: [Feb 2023] - run with the -DC switch to initiate DSRM (Directory Services Recovery Mode) for Domain Controllers
#   v0.1: Initial commit
#>
#########################################################################################################

# Set the Parameters for the script
Param(
    [Parameter(Mandatory = $false)][ValidateSet("On", "Off", IgnoreCase = $true)] [string]$safeModeSwitch = ''
#    ,  [Parameter(Mandatory = $false)][switch]$DC
)

# Initialize script
. .\src\windows\common\setup\init.ps1
. .\src\windows\common\helpers\Get-Disk-Partitions.ps1

# Declare variables
$scriptStartTime = get-date -f yyyyMMddHHmmss
$scriptPath = split-path -path $MyInvocation.MyCommand.Path -parent
$scriptName = (split-path -path $MyInvocation.MyCommand.Path -leaf).Split('.')[0]
$regLoaded = $false
$logFile = "$env:PUBLIC\Desktop\$($scriptName).log"
$scriptStartTime | Tee-Object -FilePath $logFile -Append

Log-Output "START: Running script win-toggle-safe-mode $(if ($DC) { 'on Domain Controller' })" | Tee-Object -FilePath $logFile -Append

try {

    # Make sure guest VM is shut down
    $guestHyperVVirtualMachine = Get-VM
    $guestHyperVVirtualMachineName = $guestHyperVVirtualMachine.VMName
    if ($guestHyperVVirtualMachine) {
        if ($guestHyperVVirtualMachine.State -eq 'Running') {
            Log-Output "#01 - Stopping nested guest VM $guestHyperVVirtualMachineName" | Tee-Object -FilePath $logFile -Append
            Stop-VM $guestHyperVVirtualMachine -ErrorAction Stop -Force
        }
    }
    else {
        Log-Output "#01 - No running nested guest VM, flipping safeboot switch anyways" | Tee-Object -FilePath $logFile -Append
    }

    # Make sure the disk is online
    Log-Output "#02 - Bringing disk online" | Tee-Object -FilePath $logFile -Append
    $disk = Get-Disk -ErrorAction Stop | where { $_.FriendlyName -eq 'Msft Virtual Disk' }
    $disk | Set-Disk -IsOffline $false -ErrorAction Stop

    # Handle disk partitions
    $partitionlist = Get-Disk-Partitions
    $partitionGroup = $partitionlist | Group-Object DiskNumber

    Log-Output '#03 - enumerate partitions for boot config' | Tee-Object -FilePath $logFile -Append

    forEach ( $partitionGroup in $partitionlist | group DiskNumber ) {
        # Reset paths for each part group (disk)
        $isBcdPath = $false
        $bcdPath = ''
        $isOsPath = $false
        $osPath = ''

        # Scan all partitions of a disk for bcd store and os file location
        ForEach ($drive in $partitionGroup.Group | select -ExpandProperty DriveLetter ) {

<#
            # Check if no bcd store was found on the previous partition already
            if ( -not $isBcdPath ) {
                $bcdPath = $drive + ':\boot\bcd'
                $isBcdPath = Test-Path $bcdPath

                # If no bcd was found yet at the default location look for the uefi location too
                if ( -not $isBcdPath ) {
                    $bcdPath = $drive + ':\efi\microsoft\boot\bcd'
                    $isBcdPath = Test-Path $bcdPath
                }
            }
#>
            # Check if os loader was found on the previous partition already
            if (-not $isOsPath) {
                $osPath = $drive + ':\windows\system32\winload.exe'
                $isOsPath = Test-Path $osPath
            }
        }

        # If both was found grab bcd store
#        if ( $isBcdPath -and $isOsPath ) {
        if ( $isOsPath ) {

            # Check if partition has Registry path
            $regPath = $drive + ':\Windows\System32\config\'
            $isRegPath = Test-Path $regPath
        
            # If Registry path found 
#            if ($isRegPath -and ($safeModeSwitch -ne "Off")) {
            if ($isRegPath ) {        
                Log-Output "Load requested Registry hive from $($drive)" | Tee-Object -FilePath $logFile -Append
        
                # Load hive into Rescue VM's registry from attached disk
                reg load "HKLM\BROKENSYSTEM" "$($drive):\Windows\System32\config\SYSTEM"
                $regLoaded = $true
        
                # Verify the active Control Set if using the System registry and if not already defined (1 is ControlSet001, 2 is ControlSet002)
                $controlSetText = "ControlSet00{0}" -f  (Get-ItemProperty -Path "HKLM:\BROKENSYSTEM\Select" -Name Current).Current
            }
            

            # Remove HKLM\SYSTEM\CrowdStrike\{9b03c1d9-3138-44ed-9fae-d9f4c034b88d}\{16e0423f-7058-48c9-a204-725362b67639}\Default\AG
            if($ag = Get-ItemProperty 'HKLM:\BROKENSYSTEM\CrowdStrike\{9b03c1d9-3138-44ed-9fae-d9f4c034b88d}\{16e0423f-7058-48c9-a204-725362b67639}\Default' -Name AG) {
                Log-Output "Removing AG property from $(ag.PSPath)" | Tee-Object -FilePath $logFile -Append
                $ag | Remove-ItemProperty
            }
            $ag = $null

            # Remove HKLM\SYSTEM\CurrentControlSet\Services\CSAgent\Sim\AG
            if($ag = Get-ItemProperty 'HKLM:\BROKENSYSTEM\$($controlSetText)\Services\CSAgent\Sim' -Name AG) {
                Log-Output "Removing AG property from $(ag.PSPath)" | Tee-Object -FilePath $logFile -Append
                $ag | Remove-ItemProperty
            }
            $ag = $null

            # Unload hive
            if ($regLoaded) {
                Log-Output "Unload attached disk registry hive on $($drive)" | Tee-Object -FilePath $logFile -Append
                [gc]::Collect()
                reg unload "HKLM\BROKENSYSTEM"
            }

            if ($guestHyperVVirtualMachine) {
                # Bring disk offline
                Log-Output "#06 - Bringing disk offline" | Tee-Object -FilePath $logFile -Append
                $disk | Set-Disk -IsOffline $true -ErrorAction Stop

                # Start Hyper-V VM
                Log-Output "#07 - Starting VM" | Tee-Object -FilePath $logFile -Append
                Start-VM $guestHyperVVirtualMachine -ErrorAction Stop
            }

            Log-Output "END: Please verify status of new CrowdStrike Falcon sensor for $guestHyperVVirtualMachineName" | Tee-Object -FilePath $logFile -Append
            return $STATUS_SUCCESS
        }
    }
}
catch {

    if ($guestHyperVVirtualMachine) {
        # Bring disk offline again
        Log-Output "#05 - Bringing disk offline to restart Hyper-V VM" | Tee-Object -FilePath $logFile -Append
        $disk | Set-Disk -IsOffline $true -ErrorAction Stop

        # Start Hyper-V VM again
        Log-Output "#06 - Starting VM" | Tee-Object -FilePath $logFile -Append
        Start-VM $guestHyperVVirtualMachine -ErrorAction Stop
    }

    # Log failure scenario
    Log-Error "END: could not reset AID or could not shut down nested Hyper-V VM" | Tee-Object -FilePath $logFile -Append
    throw $_
    return $STATUS_ERROR
}
