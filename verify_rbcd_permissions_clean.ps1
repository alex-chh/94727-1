param(
    [Parameter(Mandatory=$true)]
    [string]$TargetComputer,
    [Parameter(Mandatory=$true)]
    [string]$AttackerUser
)
$RBCD_GUID = "3f207c97-507b-4537-a623-41c4f1c71975"
Import-Module ActiveDirectory
Write-Host "[*] Verifying Permissions..." -ForegroundColor Cyan
$name = $TargetComputer
if ($name.Contains(".")) { $name = $name.Split(".")[0] }
$target = Get-ADComputer -Identity $name -Properties DistinguishedName,DNSHostName -ErrorAction SilentlyContinue
if (-not $target -and -not $name.EndsWith("$")) {
  $target = Get-ADComputer -Identity "$name$" -Properties DistinguishedName,DNSHostName -ErrorAction SilentlyContinue
}
if (-not $target) {
  $target = Get-ADComputer -Filter "DNSHostName -eq '$($TargetComputer)'" -Properties DistinguishedName,DNSHostName -ErrorAction SilentlyContinue
}
if (-not $target) { throw "Cannot find computer object '$TargetComputer'." }
$attacker = Get-ADUser -Identity $AttackerUser -Properties SID
Write-Host "[-] Target: $($target.Name) ($($target.DNSHostName))"
Write-Host "[-] Attacker: $($attacker.Name) ($($attacker.SID))"
$acl = Get-Acl -Path "AD:\$($target.DistinguishedName)"
$has = $false
$attSid = $attacker.SID.Value
foreach ($rule in $acl.Access) {
  $ruleSid = $null
  try { $ruleSid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch {}
  if (($ruleSid -eq $attSid) -or ($rule.IdentityReference -like "*$($attacker.Name)*")) {
    if ($rule.ActiveDirectoryRights -match "GenericAll" -or $rule.ActiveDirectoryRights -match "GenericWrite") {
      Write-Host "[!] FOUND: Generic Write/All Permission!" -ForegroundColor Green
      $has = $true
    }
    if ($rule.ActiveDirectoryRights -match "WriteProperty") {
      if ($rule.ObjectType -eq $RBCD_GUID) {
        Write-Host "[!] FOUND: WriteProperty on RBCD attribute!" -ForegroundColor Green
        $has = $true
      } elseif ($rule.ObjectType -eq "00000000-0000-0000-0000-000000000000") {
        Write-Host "[!] FOUND: WriteProperty on ALL attributes!" -ForegroundColor Green
        $has = $true
      }
    }
  }
}
if ($has) {
  Write-Host "`n[+] VERDICT: VULNERABLE" -ForegroundColor Green
  Write-Host "    User '$($attacker.Name)' CAN modify the attribute on '$($target.Name)'."
} else {
  Write-Host "`n[-] VERDICT: NOT VULNERABLE (or direct ACE not found)" -ForegroundColor Red
  Write-Host "    User '$($attacker.Name)' does not appear to have direct rights."
}
