
$STATUS_SUCCESS = '[STATUS]::SUCCESS'
$STATUS_ERROR = '[STATUS]::ERROR'

$item = Get-Item .

Write-Output "[Output $(Get-Date)]  Running from $item on $env:computername"

return $STATUS_SUCCESS
