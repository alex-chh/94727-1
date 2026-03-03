param(
  [Parameter(Mandatory=$true)]
  [string]$TargetComputer,
  [Parameter(Mandatory=$true)]
  [string]$FakeComputer
)
Import-Module ActiveDirectory
Write-Host "[*] Cleanup starting..." -ForegroundColor Cyan
try {
  Set-ADComputer -Identity $TargetComputer -Clear "msDS-AllowedToActOnBehalfOfOtherIdentity"
  Write-Host "[+] Cleared RBCD attribute on $TargetComputer" -ForegroundColor Green
} catch {
  Write-Error "Failed to clear RBCD on $TargetComputer: $_"
}
try {
  $pc = if ($FakeComputer.EndsWith('$')) { $FakeComputer } else { "$FakeComputer$" }
  Remove-ADComputer -Identity $pc -Confirm:$false
  Write-Host "[+] Deleted computer $pc" -ForegroundColor Green
} catch {
  Write-Error "Failed to delete $pc: $_"
}
Write-Host "[*] Cleanup complete." -ForegroundColor Cyan
