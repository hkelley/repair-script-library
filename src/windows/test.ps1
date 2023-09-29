Param([Parameter(Mandatory=$false)][string]$gen='1')

# Initialize script
. .\src\windows\common\setup\init.ps1
#. .\src\windows\common\helpers\Get-Disk-Partitions.ps1

# Declare variables
$scriptStartTime = get-date -f yyyyMMddHHmmss
$scriptPath = split-path -path $MyInvocation.MyCommand.Path -parent
$scriptName = (split-path -path $MyInvocation.MyCommand.Path -leaf).Split('.')[0]
$guestHyperVVirtualMachine = Get-VM
$guestHyperVVirtualMachineName = $guestHyperVVirtualMachine.VMName

Log-Output "START: Running script $scriptName on $guestHyperVVirtualMachineName "

return $STATUS_SUCCESS
