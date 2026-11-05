# xrelay.sh — 中转机 + 落地机 一键部署脚本

面向「**线路机线路好但 IP 差 + 落地机 IP 干净但线路差**」场景的一整套部署方案，基于 Xray 的
VLESS-Vision-Reality，一条命令部署，自动生成所有节点链接。

```
客户端 ──Reality──▶ 线路机(中转机) ──Reality──▶ 落地机 ──▶ 互联网
                       │                          (IP干净)
                       └──── 直连出口 ────▶ 互联网 (线路机自身IP)
```

中转机部署完成后会提供**两个节点，共用一个 地址:端口，靠不同 UUID 区分**：

| 节点 | 出口 | 适合 |
| --- | --- | --- |
| 节点1 中转 | 落地机（干净 IP） | 流媒体、AI 服务、需要干净 IP 的场景 |
| 节点2 直连 | 中转机本身 | 游戏、低延时场景（不想经过中转机到落地机这段远路） |

---

## 一、中转链路选型说明（为什么默认这么设计）

| 方案 | 原理 | 优点 | 缺点 |
| --- | --- | --- | --- |
| **Xray 链式**（本脚本 relay 模式，默认） | 中转机终结客户端的 Reality，再用一个 VLESS-Reality 出站连到落地机 | 一个端口同时提供"中转+直连"两个节点；链路本身加密且抗干扰；全部由 Xray 完成，无额外组件 | 中转机要做一次解包再封装（现代 VPS 无感）；要求落地是 VLESS-Vision-Reality |
| **realm 纯转发**（本脚本 realm 模式，备选） | 中转机把 TCP 字节流原样转发到落地机 | 零加解密、性能最好；兼容**任意** TCP 落地协议（换落地协议不用动中转）；配置极简 | 中转端口不能兼作直连节点（需另开端口跑 landing）；不支持 UDP（UDP=y 可尝试，需自测） |
| **SS / socks5 链**（未采用） | 中转机跑 SS/socks 服务端，再通过额外组件（sing-box/gost 等）链到落地 | SS2022 原生 UDP 效率较好 | 需要额外组件和两套协议配置；中转机到落地机是境外对境外链路，不需要靠 SS 来"抗封锁"；对个人使用没有实际优势 |

**结论**：默认用 Xray 链式，一个端口解决"中转 + 直连"两个需求；如果你的落地不是
VLESS-Vision-Reality（比如想换 Hysteria2、Trojan 等），用 realm 模式。
两台机器都已经用 argosbx 调通的，直接用第五节 mirror 模式，落地机完全不用动。

---

## 二、一键部署

### 第 1 步：在【落地机】上执行

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Lenslan/xrelay/main/xrelay.sh) landing LPORT=443 LSNI=aws.amazon.com NAME=luodi
```

- `LPORT` 监听端口，默认 443（Reality 建议就用 443，v26 核心对非 443 端口会提示风险）
- `LSNI` Reality 伪装域名，默认 `aws.amazon.com`（必须支持 TLS1.3 且启用 H2）。
  可选：`www.tesla.com`、`pypi.org`、`www.lovelive-anime.jp` 等。
  注意：Xray v26 会对 `www.microsoft.com`、`www.apple.com`、`icloud.com` 等
  "被滥用过多"的域名发出封禁风险警告，不建议再用。

执行完会输出 6 个参数和一条**中转机可直接复制执行的完整命令**。

### 第 2 步：把输出里的命令拿到【中转机】执行

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Lenslan/xrelay/main/xrelay.sh) relay \
  LADDR=落地机IP LPORT=443 LUUID=落地UUID LSNI=落地SNI LPBK=落地pbk LSID=落地sid \
  NAME=中转
```

执行完会得到两个节点链接（中转 / 直连），导入客户端即可。链接同时保存在
`/root/xrelay-nodes.txt`。

### 验证

- 用「中转节点」访问 `https://ip.sb`，应显示**落地机**的 IP
- 用「直连节点」访问，应显示**中转机**的 IP

---

## 三、命令与参数速查

```bash
bash xrelay.sh landing|relay|realm|info|uninstall|help|menu
```

不带参数直接运行进入交互菜单。也支持任意顺序的 `KEY=VAL` 参数前置（和常见脚本习惯一致）。

| 参数 | 用于 | 说明 |
| --- | --- | --- |
| `ADDR=1.2.3.4` | 通用 | 手动指定本机公网 IP（默认自动探测） |
| `BBR=n` | 通用 | 不自动开启 BBR 加速 |
| `RESET=y` | 通用 | 重新生成 UUID / 密钥等身份参数 |
| `DRYRUN=1` | 通用 | 演练模式：只生成配置，不安装不重启 |
| `LPORT` / `LSNI` / `UUID` / `NAME` | landing | 端口 / 伪装域名 / 自定义UUID / 节点名 |
| `LADDR LPORT LUUID LSNI LPBK LSID` | relay | 落地机六参数（landing 模式会输出） |
| `RPORT` / `RSNI` | relay, realm | 中转机监听端口 / 中转机伪装域名 |
| `LFLOW` | relay | 中转机到落地的 flow，默认 `xtls-rprx-vision`；落地不同配置时可设 `none` |
| `UUID` / `DUUID` | relay | 中转节点 UUID / 直连节点 UUID |
| `NAME` / `DNAME` | relay | 中转节点名 / 直连节点名 |
| `UDP=y` | realm | 同时转发 UDP（默认 n） |
| `SUBURL` / `BASE` / `UDP` / `PREFIX` | mirror | 落地订阅地址 / 端口起始值 / 是否镜像UDP节点 / 名称前缀 |
| `FORCE=y` / `PURGE=y` | uninstall | 免确认 / 连 xray、realm 可执行文件一起删除 |

`LPBK` 就是落地节点分享链接里的 `pbk=`，`LSID` 就是 `sid=`，`LSNI` 就是 `sni=`，
`LUUID` 就是链接里 `vless://` 后面的 UUID。**如果你已有一个现成的 VLESS-Reality 落地节点，
可以直接把分享链接里的这几个值填给 relay 模式，不用重新部署落地。**

---

## 四、realm 模式（备选）

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Lenslan/xrelay/main/xrelay.sh) realm LADDR=落地机IP LPORT=443 RPORT=443
```

- 客户端用法：把**落地节点**的服务器地址改成中转机 IP、端口改成 `RPORT`，其他参数不动
- 中转机要同时当节点：在中转机再跑一次 `landing` 模式即可（占用另一个端口，互不影响）
- 落地是 UDP 类协议（如 Hysteria2）时可尝试 `UDP=y`，实际可用性请自测

---

## 五、mirror 模式：跟随落地机订阅（argosbx 双机用户推荐）

两台机器都已经用 argosbx 部署、订阅正常使用时，推荐这个模式：**落地机完全不用动**，
在中转机上执行一次，把落地订阅里的所有节点批量镜像过来，并自动追加进中转机自己的
三个订阅文件里。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Lenslan/xrelay/main/xrelay.sh) mirror SUBURL=http://落地机IP:35948/你的subid
```

- `SUBURL` 粘贴落地机的任意一条订阅地址即可（clmi.yaml / jhsub.txt / sbox.json 都行）
- 执行后中转机的 clmi.yaml / jhsub.txt / sbox.json 都会多出一批 `中转-xxx` 节点
- hy2 / tuic 等 UDP 节点默认一并镜像；纯 TCP 环境或不需要时用 `UDP=n`
- 镜像转发端口从 `BASE`（默认 42000）向后自动分配，重跑端口保持不变；
  记得在 VPS 安全组放行对应的 TCP（及 UDP）端口范围
- **落地机重跑 argosbx 之后，在中转机重跑一次 mirror 即可刷新订阅**
- 说明：sbox.json 的更新需要机器上有 python3；订阅文件首次修改前会自动备份为
  `*.xrelay-orig`；`xrelay uninstall` 会把镜像节点从订阅里自动移除

什么时候用 mirror 而不是 relay/realm：mirror 不碰两侧任何现有服务，只在原订阅上
做叠加，适合"argosbx 已经调通、尽量不引入新变量"的场景；relay 的单端口双节点
方案则更适合从零开始部署。

---

## 六、常见问题

**Q: 端口被占用 / 连不上？**
脚本会自动放行 ufw/firewalld。还需确认 VPS 商家控制台的安全组放行了对应 TCP 端口。
连接不上时先看服务状态：`systemctl status xray` 和日志 `journalctl -u xray -n 50`。

**Q: 中转机 IP 被墙了怎么办？**
relay/realm 方案都要求客户端能直连中转机。换 IP、换端口、换 SNI 可以缓解；
如果 IP 已被彻底墙掉，本方案不适用（需要 CDN 类方案，可以继续用你原来的 argosbx 脚本）。

**Q: 会和现在用的 argosbx 冲突吗？**
不冲突。argosbx 全部文件在 `~/agsbx` 自己的目录里独立运行；本脚本用的是 Xray 官方
systemd 服务（配置在 `/usr/local/etc/xray/config.json`）。但如果同一台机器上已经有其他
脚本安装了官方版 Xray，本脚本写入前会**自动备份**旧配置为 `config.json.bak.时间戳`。
注意：本脚本的模式是互斥的（一台机器一个 xray 配置），不要在一台机器上同时部署
relay 和 landing（除非端口、服务分开处理）。

**Q: 中转节点延时比直连节点高多少？**
等于「中转机 → 落地机」这段的单程延时 ×2。这正是提供「直连节点」的原因：
游戏、低延时场景用直连；需要干净 IP 的场景才走中转。

**Q: 如何只允许中转机访问落地机？**
落地机部署完成后可以用 ufw 收紧，例如：
`ufw delete allow 443/tcp && ufw allow from <中转机IP> to any port 443 proto tcp`

**Q: 更新 / 卸载？**
重跑对应模式命令会自动更新 Xray 核心并保持原有 UUID/密钥不变（参数保存在
`/etc/xrelay/*.env`，`xrelay info` 可随时查看）。卸载：`bash xrelay.sh uninstall`。

---

## 七、部署后在机器上生成的文件

| 路径 | 说明 |
| --- | --- |
| `/usr/local/etc/xray/config.json` | Xray 配置（官方标准路径） |
| `/etc/xrelay/landing.env` 等 | 本脚本保存的参数（600 权限） |
| `/etc/xrelay/mirror.ports` | mirror 模式的端口映射（重跑保持稳定） |
| `/root/xrelay-nodes.txt` | 中转机生成的节点链接备份 |
| `/etc/realm/config.toml` | realm 模式配置 |
| `/etc/systemd/system/realm.service` | realm 服务 |
| `/usr/local/bin/xrelay` | 脚本自身的快捷命令（部署后可直接 `xrelay info`） |
