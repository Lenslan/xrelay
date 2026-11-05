#!/usr/bin/env bash
# ============================================================================
#  xrelay.sh  v1.0.0  (2026-11-05)
#
#  中转机 + 落地机 一键部署脚本  (Xray VLESS-Vision-Reality)
#
#    landing : 在【落地机】部署 Reality 节点, 并生成中转所需的全部参数
#    relay   : 在【中转机】部署中转, 单端口同时提供两个节点:
#              "中转节点"(流量走落地机出口) 与 "直连节点"(流量从本机出口)
#    realm   : 中转替代方案, 纯 TCP 转发(兼容任意 TCP 落地协议, UDP 需自测)
#    info    : 查看已部署信息      uninstall: 卸载
#    help    : 参数与用法说明      menu: 交互菜单(默认)
#
#  用法示例:
#    bash xrelay.sh landing LPORT=443 LSNI=aws.amazon.com NAME=落地
#    bash xrelay.sh relay LADDR=1.2.3.4 LPORT=443 LUUID=xxx LSNI=xxx LPBK=xxx LSID=xxx
#    bash xrelay.sh realm LADDR=1.2.3.4 LPORT=443 RPORT=8443
# ============================================================================
set -u

[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]] || { echo "需要 bash 4.0 及以上版本"; exit 1; }

VERSION="1.0.0"
DEFAULT_SNI="aws.amazon.com"

C_RESET=$'\033[0m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_CYAN=$'\033[36m'
C_BOLD=$'\033[1m'

log()  { printf '%s\n' "$*"; }
info() { printf '%s[信息]%s %s\n' "$C_CYAN"   "$C_RESET" "$*"; }
ok()   { printf '%s[完成]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf '%s[错误]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
banner(){ log ""; log "${C_CYAN}${C_BOLD}xrelay.sh v${VERSION}${C_RESET}  ${C_BOLD}$1${C_RESET}"; log ""; }

# ------------------------------- 运行环境 -----------------------------------
dry() { [[ -n ${DRYRUN:-} ]]; }
runq() { if dry; then printf '  [DRYRUN] %s\n' "$*"; else "$@"; fi; }
have_bin() { command -v "$1" >/dev/null 2>&1; }

XRAY_BIN=${XRAY_BIN:-xray}
XRAY_CONFIG=/usr/local/etc/xray/config.json
REALM_BIN=/usr/local/bin/realm
REALM_CONFIG=/etc/realm/config.toml
REALM_UNIT=/etc/systemd/system/realm.service
NODES_FILE=/root/xrelay-nodes.txt
DRYDIR=${DRYDIR:-/tmp/xrelay-dry}
TESTLOG="${DRYDIR}/xray-test.log"

PRIVATE_CIDRS='["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","::1/128","fc00::/7","fe80::/10"]'

xrel_dir()      { if dry; then printf '%s' "$DRYDIR/xrelay";           else printf '%s' "/etc/xrelay"; fi; }
xray_cfg_path() { if dry; then printf '%s' "$DRYDIR/xray/config.json"; else printf '%s' "$XRAY_CONFIG"; fi; }
realm_cfg_path(){ if dry; then printf '%s' "$DRYDIR/realm/config.toml"; else printf '%s' "$REALM_CONFIG"; fi; }
nodes_file()    { if dry; then printf '%s' "$DRYDIR/xrelay-nodes.txt"; else printf '%s' "$NODES_FILE"; fi; }
_new_cfg_path() {
  if dry; then
    local p; p=$(xray_cfg_path); mkdir -p "$(dirname "$p")"; printf '%s' "$p"
  else
    mktemp /tmp/xrelay-cfg.XXXXXX.json
  fi
}

ensure_root() { dry && return 0; [[ $(id -u 2>/dev/null) == 0 ]] || die "请以 root 运行 (先执行 sudo -i)"; }
have_xray() { have_bin "$XRAY_BIN" 2>/dev/null || [[ -x $XRAY_BIN ]]; }

ensure_deps() {
  local miss=() p
  for p in curl unzip tar; do have_bin "$p" || miss+=("$p"); done
  ((${#miss[@]})) || return 0
  if dry; then printf '  [DRYRUN] 安装依赖: %s\n' "${miss[*]}"; return 0; fi
  if have_bin apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${miss[@]}" >/dev/null 2>&1 || true
  elif have_bin dnf; then
    dnf install -y -q "${miss[@]}" >/dev/null 2>&1 || true
  elif have_bin yum; then
    yum install -y -q "${miss[@]}" >/dev/null 2>&1 || true
  fi
  for p in "${miss[@]}"; do have_bin "$p" || die "缺少依赖 $p, 请手动安装后重试"; done
}

# ------------------------------- 基础工具 -----------------------------------
get_public_ip() {
  local ip u
  for u in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
    ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]') || true
    [[ ${ip:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$ip"; return 0; }
  done
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
  [[ -n ${ip:-} ]] && printf '%s' "$ip"
}
resolve_addr() {
  if [[ -n ${ADDR:-} ]]; then printf '%s' "$ADDR"; return 0; fi
  local a; a=$(get_public_ip)
  if [[ -z $a ]]; then
    warn "无法探测本机公网IP, 暂用占位 203.0.113.10 (可用 ADDR=你的IP 指定)"
    a=203.0.113.10
  fi
  printf '%s' "$a"
}

port_busy() { # 端口被占用则输出监听行并返回0
  local p=$1 out
  dry && return 1
  if have_bin ss; then
    out=$(ss -lntp 2>/dev/null | awk -v pat=":$p\$" '$4 ~ pat') || true
  elif have_bin netstat; then
    out=$(netstat -lntp 2>/dev/null | awk -v pat=":$p\$" '$4 ~ pat') || true
  else
    return 1
  fi
  [[ -n $out ]] && { printf '%s\n' "$out"; return 0; }
  return 1
}
ensure_port_free() {
  local p=$1 name=$2 line
  if line=$(port_busy "$p"); then
    grep -qiE 'xray|realm' <<<"$line" && return 0
    printf '%s\n' "$line"
    die "端口 $p ($name) 已被占用, 请更换端口或停止占用进程后再试"
  fi
}

open_fw() {
  local p=$1
  if dry; then printf '  [DRYRUN] 放行防火墙端口 %s/tcp\n' "$p"; return 0; fi
  if have_bin ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$p/tcp" >/dev/null 2>&1 && ok "ufw 已放行 $p/tcp"
  elif have_bin firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p/tcp" >/dev/null 2>&1 \
      && firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已放行 $p/tcp"
  else
    info "未检测到启用中的 ufw/firewalld, 跳过本机防火墙配置"
  fi
}
fw_hint() { info "别忘了在 VPS 商家控制台的【安全组/防火墙】放行 TCP $1 端口"; }

enable_bbr() {
  [[ ${BBR:-} == n ]] && return 0
  if dry; then printf '  [DRYRUN] 检查/启用 BBR\n'; return 0; fi
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    info "BBR 已启用, 跳过"
    return 0
  fi
  modprobe tcp_bbr 2>/dev/null || true
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-xrelay-bbr.conf 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    ok "已启用 BBR 加速"
  else
    warn "当前内核不支持 BBR, 已跳过(不影响使用)"
  fi
}

kv() { printf "%s='%s'\n" "$1" "$2"; }
save_env_file() {
  local f=$1; shift
  mkdir -p "$(dirname "$f")"
  { printf '# xrelay %s\n' "$(date '+%F %T')"
    local l; for l in "$@"; do printf '%s\n' "$l"; done
  } > "$f"
  chmod 600 "$f" 2>/dev/null || true
}
load_env_file() { # 读取已保存参数; 环境变量已给出的值优先(空串视为未给出)
  local f=$1 line k v
  [[ -f $f ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in ''|'#'*) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    if [[ $v == \'*\' ]]; then v=${v#\'}; v=${v%\'}; fi
    if [[ -z ${!k+x} || -z ${!k} ]]; then printf -v "$k" '%s' "$v"; fi
  done < "$f"
}

# ------------------------------- 参数生成 -----------------------------------
gen_uuid() {
  local u=""
  have_xray && u=$("$XRAY_BIN" uuid 2>/dev/null || true)
  if [[ -z $u && -r /proc/sys/kernel/random/uuid ]]; then u=$(cat /proc/sys/kernel/random/uuid); fi
  if [[ -z $u ]]; then
    u=$(od -A n -t x1 -N 16 /dev/urandom | tr -d ' \n')
    u="${u:0:8}-${u:8:4}-${u:12:4}-${u:16:4}-${u:20:12}"
  fi
  printf '%s' "$u"
}
gen_sid() { od -A n -t x1 -N 8 /dev/urandom | tr -d ' \n'; }
gen_keys() { # 生成 Reality 密钥对 -> G_PRIV / G_PUB
  local out=""
  have_xray && out=$("$XRAY_BIN" x25519 2>/dev/null || true)
  G_PRIV=$(printf '%s\n' "$out" | awk -F': ' '/[Pp]rivate ?[Kk]ey/{print $2}' | head -n1 | tr -d '\r')
  G_PUB=$(printf '%s\n' "$out" | awk -F': ' '/[Pp]ublic ?[Kk]ey|[Pp]assword/{print $2}'  | head -n1 | tr -d '\r')
  if [[ -z ${G_PRIV:-} || -z ${G_PUB:-} ]]; then
    if dry; then
      warn "DRYRUN: 未找到可用的 xray, 使用随机占位密钥"
      G_PRIV=$(od -A n -t x1 -N 32 /dev/urandom | tr -d ' \n')
      G_PUB=$(od -A n -t x1 -N 32 /dev/urandom | tr -d ' \n')
    else
      die "Reality 密钥生成失败, 请检查 xray 是否安装正常"
    fi
  fi
}

urlesc() { # 仅处理 base64 可能出现的三个字符, 保证分享链接可被客户端正确解析
  local s=$1
  s=${s//+/%2B}; s=${s//\//%2F}; s=${s//=/%3D}
  printf '%s' "$s"
}
build_link() { # uuid host port sni pbk sid name
  local uuid=$1 host=$2 port=$3 sni=$4 pbk=$5 sid=$6 name=$7 h=$2
  [[ $h == *:* ]] && h="[$h]"
  name=${name// /%20}
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
    "$uuid" "$h" "$port" "$sni" "$(urlesc "$pbk")" "$sid" "$name"
}

validate_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )) || die "端口无效: $1"; }
validate_sni()  { [[ $1 =~ ^[A-Za-z0-9.-]+$ ]] || die "SNI 域名无效: $1"; }
validate_uuid() { [[ $1 =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "UUID 格式异常: $1"; }

askv() { # 变量名 提示文字 默认值; 已有值则跳过; 非交互且缺失则报错
  local __v=$1 text=$2 def=$3 cur a
  cur=${!__v:-}
  [[ -n $cur ]] && return 0
  [[ -t 0 ]] || die "缺少参数 ${__v} (当前为非交互模式, 请参考 help 通过命令行传入)"
  printf '  %s [%s]: ' "$text" "$def"
  read -r a || a=""
  printf -v "$__v" '%s' "${a:-$def}"
}

# ------------------------------- Xray 安装 ----------------------------------
install_xray() {
  if dry; then
    printf '  [DRYRUN] 跳过 Xray 安装 (测试用 XRAY_BIN=%s)\n' "$XRAY_BIN"
    return 0
  fi
  if have_bin xray; then
    info "已安装 Xray: $(xray version 2>/dev/null | head -n1)"
  fi
  info "安装/更新 Xray 官方核心 ..."
  bash -c "$(curl -fsSL --retry 2 --connect-timeout 10 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
    || die "Xray 安装失败, 请检查 VPS 到 GitHub 的网络连通性"
  have_bin xray || die "Xray 安装异常: 未找到 xray 命令"
  ok "Xray 就绪: $(xray version 2>/dev/null | head -n1)"
}

test_config() { # 用真实核心校验配置; 兼容新旧命令行写法
  local f=$1
  "$XRAY_BIN" run -test -config "$f" >"$TESTLOG" 2>&1 && return 0
  "$XRAY_BIN" -test -config "$f" >>"$TESTLOG" 2>&1 && return 0
  return 1
}

# ------------------------------- 配置模板 -----------------------------------
write_landing_config() {
  local variant=$1 cfg=$2
  cat > "$cfg" <<EOF
{
  "log": { "loglevel": "warning", "access": "none" },
  "inbounds": [
    {
      "tag": "in-landing",
      "listen": "0.0.0.0",
      "port": ${LPORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${LUUID}", "flow": "xtls-rprx-vision", "email": "landing@xrelay" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "${variant}": "${LSNI}:443",
          "serverNames": [ "${LSNI}" ],
          "privateKey": "${PRIV}",
          "shortIds": [ "${SID}" ]
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "ip": ${PRIVATE_CIDRS}, "outboundTag": "block" }
    ]
  }
}
EOF
}

write_relay_config() {
  local variant=$1 cfg=$2 out_user
  if [[ -n ${LFLOW:-} && $LFLOW != none ]]; then
    out_user="{\"id\": \"${LUUID}\", \"encryption\": \"none\", \"flow\": \"${LFLOW}\"}"
  else
    out_user="{\"id\": \"${LUUID}\", \"encryption\": \"none\"}"
  fi
  cat > "$cfg" <<EOF
{
  "log": { "loglevel": "warning", "access": "none" },
  "inbounds": [
    {
      "tag": "in-relay",
      "listen": "0.0.0.0",
      "port": ${RPORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${RUUID}", "flow": "xtls-rprx-vision", "email": "relay@xrelay" },
          { "id": "${DUUID}", "flow": "xtls-rprx-vision", "email": "direct@xrelay" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "${variant}": "${RSNI}:443",
          "serverNames": [ "${RSNI}" ],
          "privateKey": "${RPRIV}",
          "shortIds": [ "${RSID}" ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "to-landing",
      "protocol": "vless",
      "settings": {
        "vnext": [
          { "address": "${LADDR}", "port": ${LPORT}, "users": [ ${out_user} ] }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${LSNI}",
          "fingerprint": "chrome",
          "publicKey": "${LPBK}",
          "shortId": "${LSID}",
          "spiderX": "/"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "ip": ${PRIVATE_CIDRS}, "outboundTag": "block" },
      { "user": [ "direct@xrelay" ], "outboundTag": "direct" },
      { "network": "tcp,udp", "outboundTag": "to-landing" }
    ]
  }
}
EOF
}

write_and_test() { # 写入配置并用真实核心校验; 兼容 target/dest 字段差异
  local writer=$1 cfg=$2 variant=target
  "$writer" "$variant" "$cfg"
  if ! have_xray; then warn "未找到 xray 可执行文件, 跳过配置校验"; return 0; fi
  if test_config "$cfg"; then ok "配置校验通过"; return 0; fi
  if grep -qE 'unknown field.*(target|dest)|(target|dest).*unknown field' "$TESTLOG" 2>/dev/null; then
    variant=dest
    "$writer" "$variant" "$cfg"
    if test_config "$cfg"; then ok "配置校验通过 (兼容旧版字段: dest)"; return 0; fi
  fi
  log "----- Xray 配置校验输出 -----"
  tail -n 15 "$TESTLOG" 2>/dev/null || true
  die "配置校验未通过, 请把上方输出反馈"
}

apply_xray_config() {
  local src=$1 real=$XRAY_CONFIG
  if dry; then printf '  [DRYRUN] 跳过安装配置与重启服务 (配置已生成于 %s)\n' "$src"; return 0; fi
  mkdir -p "$(dirname "$real")"
  if [[ -s $real ]] && ! grep -q 'xrelay' "$real"; then
    local bak="${real}.bak.$(date +%s)"
    cp -a "$real" "$bak"
    warn "检测到其他脚本的 xray 配置, 已备份到 $bak"
  fi
  if getent group xray >/dev/null 2>&1; then
    install -m 640 -o root -g xray "$src" "$real"
  else
    install -m 644 -o root -g root "$src" "$real"
  fi
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 1
  if ! systemctl is-active --quiet xray; then
    log "----- journalctl -u xray (最后 25 行) -----"
    journalctl -u xray -n 25 --no-pager 2>/dev/null || true
    die "xray 启动失败, 请查看上方日志"
  fi
  ok "xray 服务已重启并运行中"
}

# ------------------------------- 落地机模式 ---------------------------------
show_landing_summary() {
  local link url
  link=$(build_link "$LUUID" "$ADDR" "$LPORT" "$LSNI" "$PUB" "$SID" "$NAME")
  url=${SCRIPT_URL:-'<你的脚本地址>'}
  log ""
  log "${C_GREEN}${C_BOLD}========== 落地机部署完成 ==========${C_RESET}"
  log " 节点名称 : $NAME"
  log " 监听端口 : $LPORT    伪装SNI: $LSNI"
  log ""
  log " 【落地直连节点】(备用, 线路好时也可直接用):"
  log "    $link"
  log ""
  log "${C_BOLD} 【中转机需要的 6 个参数】${C_RESET}"
  log " LADDR=$ADDR LPORT=$LPORT LUUID=$LUUID LSNI=$LSNI LPBK=$PUB LSID=$SID"
  log ""
  log "${C_BOLD} 在中转机上执行 (推荐, Xray 链式):${C_RESET}"
  log " bash <(curl -Ls $url) relay LADDR=$ADDR LPORT=$LPORT LUUID=$LUUID LSNI=$LSNI LPBK=$PUB LSID=$SID NAME=中转"
  log ""
  log "${C_BOLD} 或在中转机上执行 (realm 纯转发, 中转机不能同端口兼作节点):${C_RESET}"
  log " bash <(curl -Ls $url) realm LADDR=$ADDR LPORT=$LPORT RPORT=443"
  log ""
  info "以上参数已保存到 $(xrel_dir)/landing.env, 可用 xrelay info 随时查看"
  info "安全建议: 中转机部署完成后, 可把落地机防火墙收紧为只放行中转机IP, 例如:"
  info "  ufw delete allow $LPORT/tcp && ufw allow from <中转机IP> to any port $LPORT proto tcp"
}

do_landing() {
  local NEWCFG
  banner "模式: 落地机 (landing)"
  ensure_root
  [[ ${RESET:-} == y ]] || load_env_file "$(xrel_dir)/landing.env"
  if [[ ${RESET:-} == y ]]; then
    warn "RESET=y: 将重新生成 UUID 与 Reality 密钥, 部署后需要重新部署中转机"
    unset LUUID PRIV PUB SID
  fi
  LPORT=${LPORT:-443}
  LSNI=${LSNI:-$DEFAULT_SNI}
  NAME=${NAME:-落地}
  [[ -n ${UUID:-} ]] && LUUID=$UUID
  validate_port "$LPORT"
  validate_sni "$LSNI"
  ensure_deps
  install_xray
  [[ -n ${LUUID:-} ]] || LUUID=$(gen_uuid)
  validate_uuid "$LUUID"
  if [[ -z ${PRIV:-} || -z ${PUB:-} || -z ${SID:-} ]]; then
    gen_keys; PRIV=$G_PRIV; PUB=$G_PUB; SID=$(gen_sid)
  fi
  ensure_port_free "$LPORT" "落地节点"
  ADDR=$(resolve_addr)
  NEWCFG=$(_new_cfg_path)
  write_and_test write_landing_config "$NEWCFG"
  apply_xray_config "$NEWCFG"
  open_fw "$LPORT"
  fw_hint "$LPORT"
  enable_bbr
  save_env_file "$(xrel_dir)/landing.env" \
    "$(kv DATE "$(date '+%F %T')")" \
    "$(kv LUUID "$LUUID")" "$(kv LPORT "$LPORT")" "$(kv LSNI "$LSNI")" \
    "$(kv PRIV "$PRIV")" "$(kv PUB "$PUB")" "$(kv SID "$SID")" \
    "$(kv NAME "$NAME")" "$(kv ADDR "$ADDR")"
  show_landing_summary
}

# ------------------------------- 中转机模式 ---------------------------------
landing_params_hint() {
  log "  ${C_YELLOW}缺少落地机参数。请先在落地机运行 landing 模式, 它会输出${C_RESET}"
  log "  ${C_YELLOW}LADDR LPORT LUUID LSNI LPBK LSID 六个参数; 也可从现成${C_RESET}"
  log "  ${C_YELLOW}VLESS-Reality 落地节点的分享链接中找到对应值(pbk= / sid= / sni=)。${C_RESET}"
}
require_landing_params() {
  askv LADDR "落地机 IP/域名" ""
  askv LPORT "落地机端口" "443"
  askv LUUID "落地机 UUID" ""
  askv LSNI  "落地机 Reality SNI" ""
  askv LPBK  "落地机公钥 pbk" ""
  askv LSID  "落地机 shortId sid" ""
  local missing=0 v
  for v in LADDR LPORT LUUID LSNI LPBK LSID; do
    [[ -z ${!v:-} ]] && { warn "缺少 $v"; missing=1; }
  done
  ((missing)) && { landing_params_hint; die "落地机参数不完整"; }
  validate_port "$LPORT"
  validate_sni "$LSNI"
  validate_uuid "$LUUID"
  [[ $LSID =~ ^[0-9a-fA-F]{0,16}$ ]] || die "LSID 应为不超过 16 位的十六进制字符: $LSID"
  [[ $LPBK =~ ^[A-Za-z0-9_+/=-]+$ ]] || die "LPBK 格式异常: $LPBK"
}

show_relay_summary() {
  local l1 l2 l3 nf
  l1=$(build_link "$RUUID" "$ADDR" "$RPORT" "$RSNI" "$RPUB" "$RSID" "$NAME")
  l2=$(build_link "$DUUID" "$ADDR" "$RPORT" "$RSNI" "$RPUB" "$RSID" "$DNAME")
  l3=$(build_link "$LUUID" "$LADDR" "$LPORT" "$LSNI" "$LPBK" "$LSID" "落地直连")
  nf=$(nodes_file)
  mkdir -p "$(dirname "$nf")"
  {
    printf '# xrelay 节点信息 %s\n\n' "$(date '+%F %T')"
    printf '# 1) 中转节点: 出口 = 落地机 (%s)\n%s\n\n' "$LADDR" "$l1"
    printf '# 2) 直连节点: 出口 = 中转机\n%s\n\n' "$l2"
    printf '# 3) 落地直连: 备用, 中转线路不好时才用\n%s\n' "$l3"
  } > "$nf"
  chmod 600 "$nf" 2>/dev/null || true
  log ""
  log "${C_GREEN}${C_BOLD}========== 中转机部署完成 ==========${C_RESET}"
  log " 落地参数 : LADDR=$LADDR LPORT=$LPORT (SNI: $LSNI)"
  log ""
  log "${C_BOLD} 【节点1 中转】出口=落地机($LADDR), 需要干净IP/流媒体/AI时用:${C_RESET}"
  log "    $l1"
  log ""
  log "${C_BOLD} 【节点2 直连】出口=中转机($ADDR), 游戏/低延时场景用:${C_RESET}"
  log "    $l2"
  log ""
  info "节点信息已保存到 $nf"
  info "验证: 用【节点1】访问 https://ip.sb 应显示落地机 IP; 用【节点2】应显示中转机 IP"
  info "建议在客户端按需分流: 流媒体/AI 走节点1, 游戏/低延时 走节点2"
}

do_relay() {
  local NEWCFG
  banner "模式: 中转机 (relay)"
  ensure_root
  [[ ${RESET:-} == y ]] || load_env_file "$(xrel_dir)/relay.env"
  if [[ ${RESET:-} == y ]]; then
    warn "RESET=y: 将重新生成中转机自身的 UUID/密钥"
    unset RUUID DUUID RPRIV RPUB RSID
  fi
  LFLOW=${LFLOW:-xtls-rprx-vision}
  RPORT=${RPORT:-443}
  RSNI=${RSNI:-$DEFAULT_SNI}
  NAME=${NAME:-中转}
  DNAME=${DNAME:-直连}
  require_landing_params
  [[ -n ${UUID:-} ]] && RUUID=$UUID
  validate_port "$RPORT"
  validate_sni "$RSNI"
  ensure_deps
  install_xray
  [[ -n ${RUUID:-} ]] || RUUID=$(gen_uuid)
  [[ -n ${DUUID:-} ]] || DUUID=$(gen_uuid)
  validate_uuid "$RUUID"
  validate_uuid "$DUUID"
  if [[ -z ${RPRIV:-} || -z ${RPUB:-} || -z ${RSID:-} ]]; then
    gen_keys; RPRIV=$G_PRIV; RPUB=$G_PUB; RSID=$(gen_sid)
  fi
  ensure_port_free "$RPORT" "中转节点"
  ADDR=$(resolve_addr)
  if [[ $LADDR == "$ADDR" ]]; then warn "LADDR 与本机公网IP相同, 请确认没填错"; fi
  NEWCFG=$(_new_cfg_path)
  write_and_test write_relay_config "$NEWCFG"
  apply_xray_config "$NEWCFG"
  open_fw "$RPORT"
  fw_hint "$RPORT"
  enable_bbr
  save_env_file "$(xrel_dir)/relay.env" \
    "$(kv DATE "$(date '+%F %T')")" \
    "$(kv LADDR "$LADDR")" "$(kv LPORT "$LPORT")" "$(kv LUUID "$LUUID")" \
    "$(kv LSNI "$LSNI")" "$(kv LPBK "$LPBK")" "$(kv LSID "$LSID")" "$(kv LFLOW "$LFLOW")" \
    "$(kv RPORT "$RPORT")" "$(kv RSNI "$RSNI")" \
    "$(kv RUUID "$RUUID")" "$(kv DUUID "$DUUID")" \
    "$(kv RPRIV "$RPRIV")" "$(kv RPUB "$RPUB")" "$(kv RSID "$RSID")" \
    "$(kv NAME "$NAME")" "$(kv DNAME "$DNAME")" "$(kv ADDR "$ADDR")"
  show_relay_summary
}

# ------------------------------- realm 模式 ---------------------------------
install_realm() {
  if dry; then printf '  [DRYRUN] 跳过 realm 安装 (目标: %s)\n' "$REALM_BIN"; return 0; fi
  if [[ -x $REALM_BIN ]]; then
    ok "realm 已安装: $($REALM_BIN -v 2>/dev/null | head -n1)"
    return 0
  fi
  local ra tmp url bin
  case "$(uname -m)" in
    x86_64|amd64)  ra="realm-x86_64-unknown-linux-musl.tar.gz" ;;
    aarch64|arm64) ra="realm-aarch64-unknown-linux-musl.tar.gz" ;;
    armv7l)        ra="realm-armv7-unknown-linux-musleabihf.tar.gz" ;;
    *) die "realm 不支持当前架构 $(uname -m), 请改用 relay 模式" ;;
  esac
  url="https://github.com/zhboner/realm/releases/latest/download/${ra}"
  tmp=$(mktemp -d)
  info "下载 realm ..."
  curl -fsSL --retry 2 --connect-timeout 10 -o "$tmp/realm.tgz" "$url" || die "realm 下载失败: $url"
  tar -xzf "$tmp/realm.tgz" -C "$tmp" || die "realm 解压失败"
  bin=$(find "$tmp" -maxdepth 3 -type f -name 'realm*' ! -name '*.tgz' | head -n1)
  [[ -n $bin ]] || die "realm 解压后未找到可执行文件"
  install -m 755 "$bin" "$REALM_BIN"
  rm -rf "$tmp"
  ok "realm 已安装: $($REALM_BIN -v 2>/dev/null | head -n1)"
}

write_realm_config() {
  local cfg=$1 remote listen udp
  remote="$LADDR:$LPORT"
  [[ $LADDR == *:* ]] && remote="[$LADDR]:$LPORT"
  listen="0.0.0.0:$RPORT"
  [[ ${UDP:-n} == y ]] && udp=true || udp=false
  mkdir -p "$(dirname "$cfg")"
  cat > "$cfg" <<EOF
[log]
level = "warn"

[network]
no_tcp = false
use_udp = ${udp}

[[endpoints]]
listen = "${listen}"
remote = "${remote}"
EOF
}

start_realm() {
  if dry; then printf '  [DRYRUN] 写入 %s 并启动 realm 服务\n' "$REALM_UNIT"; return 0; fi
  cat > "$REALM_UNIT" <<EOF
[Unit]
Description=Realm TCP/UDP Relay (xrelay)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c ${REALM_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable realm >/dev/null 2>&1 || true
  systemctl restart realm
  sleep 1
  if ! systemctl is-active --quiet realm; then
    log "----- journalctl -u realm (最后 20 行) -----"
    journalctl -u realm -n 20 --no-pager 2>/dev/null || true
    die "realm 启动失败, 请查看上方日志"
  fi
  ok "realm 服务运行中"
}

show_realm_summary() {
  local l1
  log ""
  log "${C_GREEN}${C_BOLD}========== realm 转发部署完成 ==========${C_RESET}"
  log " 转发规则 : 本机 0.0.0.0:$RPORT  ->  $LADDR:$LPORT (TCP)"
  [[ ${UDP:-n} == y ]] && log " UDP 转发 : 已开启(建议实际测一下落地协议是否可用)"
  log ""
  if [[ -n ${LUUID:-} && -n ${LSNI:-} && -n ${LPBK:-} && -n ${LSID:-} ]]; then
    l1=$(build_link "$LUUID" "$ADDR" "$RPORT" "$LSNI" "$LPBK" "$LSID" "$NAME")
    log " 【中转节点】下面这条链接可直接导入客户端(参数与落地一致, 地址已换成中转机):"
    log "    $l1"
  else
    info "客户端用法: 把【落地节点】的服务器地址改成 $ADDR, 端口改成 $RPORT 即可"
    info "(其他参数保持落地节点原样不变)"
  fi
  log ""
  info "realm 只做纯转发: 任何 TCP 落地协议都兼容, 但不支持 UDP(除 UDP=y 自测)"
  info "如需中转机同时当节点: 在中转机再运行一次 landing 模式(会占用一个新端口)"
  info "中转机IP被墙或需要CDN时, realm/relay 都不适用, 需另想办法(如换IP)"
}

do_realm() {
  banner "模式: 中转机 (realm 纯转发)"
  ensure_root
  [[ ${RESET:-} == y ]] || load_env_file "$(xrel_dir)/realm.env"
  RPORT=${RPORT:-443}
  UDP=${UDP:-n}
  NAME=${NAME:-中转-realm}
  askv LADDR "落地机 IP/域名" ""
  askv LPORT "落地机端口" "443"
  if [[ -z ${LADDR:-} || -z ${LPORT:-} ]]; then
    landing_params_hint
    die "缺少落地机地址或端口"
  fi
  validate_port "$LPORT"
  validate_port "$RPORT"
  ensure_deps
  ADDR=$(resolve_addr)
  write_realm_config "$(realm_cfg_path)"
  if dry; then
    printf '  [DRYRUN] realm 配置:\n'
    sed 's/^/    /' "$(realm_cfg_path)"
  else
    install_realm
    ensure_port_free "$RPORT" "realm 转发"
    start_realm
    open_fw "$RPORT"
    fw_hint "$RPORT"
    enable_bbr
  fi
  save_env_file "$(xrel_dir)/realm.env" \
    "$(kv DATE "$(date '+%F %T')")" \
    "$(kv LADDR "$LADDR")" "$(kv LPORT "$LPORT")" "$(kv RPORT "$RPORT")" \
    "$(kv UDP "$UDP")" "$(kv NAME "$NAME")" "$(kv ADDR "$ADDR")" \
    "$(kv LUUID "${LUUID:-}")" "$(kv LSNI "${LSNI:-}")" \
    "$(kv LPBK "${LPBK:-}")" "$(kv LSID "${LSID:-}")"
  show_realm_summary
}

# ------------------------------- 信息 / 卸载 --------------------------------
do_info() {
  banner "已部署信息"
  local d f role found=0
  d=$(xrel_dir)
  for role in landing relay realm; do
    f="$d/$role.env"
    [[ -f $f ]] || continue
    found=1
    log "${C_BOLD}---- $role ----${C_RESET}"
    (
      unset DATE LUUID LPORT LSNI PRIV PUB SID NAME ADDR LADDR LPBK LSID LFLOW RPORT RSNI RUUID DUUID RPRIV RPUB RSID DNAME UDP
      load_env_file "$f"
      case $role in
        landing)
          log "  端口 $LPORT, SNI=$LSNI, 名称=$NAME, 公网=$ADDR"
          log "  $(build_link "$LUUID" "$ADDR" "$LPORT" "$LSNI" "$PUB" "$SID" "$NAME")"
          ;;
        relay)
          log "  落地参数: LADDR=$LADDR LPORT=$LPORT LSNI=$LSNI"
          log "  中转节点: $(build_link "$RUUID" "$ADDR" "$RPORT" "$RSNI" "$RPUB" "$RSID" "$NAME")"
          log "  直连节点: $(build_link "$DUUID" "$ADDR" "$RPORT" "$RSNI" "$RPUB" "$RSID" "$DNAME")"
          ;;
        realm)
          log "  转发: 0.0.0.0:$RPORT -> $LADDR:$LPORT (UDP=${UDP:-n})"
          ;;
      esac
    )
    log ""
  done
  ((found)) || info "未发现本脚本的部署记录 (landing / relay / realm)"
  if ! dry && have_bin systemctl; then
    local s st
    for s in xray realm; do
      if systemctl list-unit-files 2>/dev/null | grep -q "^$s.service"; then
        st=$(systemctl is-active "$s" 2>/dev/null) || true
        log "  服务 $s: ${st:-unknown}"
      fi
    done
  fi
  if [[ -f $(nodes_file) ]]; then
    log ""
    log "${C_BOLD}---- 节点信息文件 $(nodes_file) ----${C_RESET}"
    cat "$(nodes_file)"
  fi
}

do_uninstall() {
  banner "卸载"
  ensure_root
  local ans=no r
  if [[ ${FORCE:-} == y ]]; then
    ans=yes
  elif [[ -t 0 ]]; then
    printf ' 将停止并清理本脚本部署的 xray 配置与 realm 服务(不会动其他脚本的数据), 继续? [y/N]: '
    read -r r || r=""
    [[ $r == [yY] ]] && ans=yes
  fi
  [[ $ans == yes ]] || die "已取消 (非交互模式可加 FORCE=y 确认执行)"
  if ! dry; then
    if [[ -f $XRAY_CONFIG ]] && grep -q 'xrelay' "$XRAY_CONFIG"; then
      systemctl stop xray 2>/dev/null || true
      systemctl disable xray 2>/dev/null || true
      mv "$XRAY_CONFIG" "${XRAY_CONFIG}.removed.$(date +%s)"
      ok "已停止 xray 服务并移除本脚本生成的配置"
    elif [[ -f $XRAY_CONFIG ]]; then
      warn "当前 xray 配置不是本脚本生成的, 未改动"
    fi
    if [[ -f $REALM_UNIT ]]; then
      systemctl stop realm 2>/dev/null || true
      systemctl disable realm 2>/dev/null || true
      rm -f "$REALM_UNIT"
      systemctl daemon-reload 2>/dev/null || true
      ok "已停止并移除 realm 服务"
    fi
  else
    printf '  [DRYRUN] 停止服务 / 移除配置\n'
  fi
  rm -rf "$(xrel_dir)" "$(nodes_file)"
  if ! dry && [[ -d /etc/realm ]]; then rm -rf /etc/realm; fi
  if [[ ${PURGE:-} == y ]] && ! dry; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove >/dev/null 2>&1 || true
    rm -f "$REALM_BIN"
    ok "已卸载 xray 与 realm 可执行文件"
  fi
  ok "卸载完成"
}

# ------------------------------- 帮助 / 菜单 --------------------------------
do_help() {
  cat <<'EOF'
xrelay.sh  中转机 + 落地机 一键部署脚本

用法:
  bash xrelay.sh <模式> [KEY=VAL ...]

模式:
  landing    在落地机部署 VLESS-Vision-Reality 节点, 输出中转机所需的 6 个参数
  relay      在中转机部署: 单端口提供 "中转节点(走落地)" + "直连节点(本机出口)"
  realm      在中转机部署纯 TCP 转发(替代方案, 兼容任意 TCP 协议落地)
  info       查看已部署信息和节点链接
  uninstall  卸载本脚本部署的内容 (FORCE=y 免确认, PURGE=y 连内核一起删)
  menu       交互菜单 (默认模式)
  help       显示本帮助

通用参数:
  ADDR=1.2.3.4       指定本机公网IP(默认自动探测)
  BBR=n              不自动启用 BBR 加速
  RESET=y            重新生成 UUID/密钥等身份参数
  DRYRUN=1           演练模式: 只生成配置, 不安装不重启
  FORCE=y            卸载时免确认
  PURGE=y            卸载时连 xray/realm 可执行文件一起删除

landing 模式参数:
  LPORT=443           监听端口
  LSNI=aws.amazon.com Reality 伪装域名(需支持 TLS1.3+H2)
  UUID=...            自定义 UUID(默认随机生成)
  NAME=落地           节点名称

relay 模式参数:
  LADDR / LPORT               落地机 IP / 端口                    [必填]
  LUUID / LSNI / LPBK / LSID  落地机 UUID / SNI / 公钥 / shortId  [必填]
  RPORT=443                   中转机监听端口
  RSNI=aws.amazon.com         中转机 Reality 伪装域名
  LFLOW=xtls-rprx-vision      与落地之间链路的 flow(不匹配时可改 none)
  UUID=...                    中转节点 UUID(默认随机); DUUID=... 直连节点 UUID
  NAME=中转  DNAME=直连       两个节点的名称

realm 模式参数:
  LADDR / LPORT   落地机地址 / 端口  [必填]
  RPORT=443       中转机监听端口
  UDP=y           同时转发 UDP(默认 n)
  LUUID/LSNI/LPBK/LSID  可选, 填了会自动生成中转节点分享链接

示例:
  落地机:  bash xrelay.sh landing LPORT=443 LSNI=aws.amazon.com NAME=落地
  中转机:  bash xrelay.sh relay LADDR=1.2.3.4 LPORT=443 LUUID=xx LSNI=xx LPBK=xx LSID=xx
  中转机:  bash xrelay.sh realm LADDR=1.2.3.4 LPORT=443 RPORT=8443

说明:
  - relay 模式: 客户端用同一个 地址:端口, 靠两个不同 UUID 区分节点;
    "中转节点"出口=落地机; "直连节点"出口=中转机(低延时, 应对落地链路远)
  - LPBK 就是落地节点分享链接里的 pbk=..., LSID 就是 sid=..., LSNI 就是 sni=...
  - 所有参数会保存在 /etc/xrelay/*.env, 随时可用 xrelay info 查看
EOF
}

do_menu() {
  [[ -t 0 ]] || die "交互菜单需要终端; 请直接使用命令行模式, 参考: bash xrelay.sh help"
  banner "交互菜单"
  log " 1) 部署【落地机】  (生成落地节点 + 中转需要的参数)"
  log " 2) 部署【中转机】  (Xray 链式, 单端口双节点, 推荐)"
  log " 3) 部署【中转机】  (realm 纯转发, 备用方案)"
  log " 4) 查看已部署信息 / 节点链接"
  log " 5) 卸载"
  log " 0) 退出"
  log ""
  printf ' 请选择 [0-5]: '
  local c; read -r c || c=""
  case $c in
    1) do_landing ;;
    2) do_menu_relay ;;
    3) do_menu_realm ;;
    4) do_info ;;
    5) do_uninstall ;;
    0|"") log "再见" ;;
    *) warn "无效选择"; do_menu ;;
  esac
}
do_menu_relay() {
  log " 请粘贴【落地机】输出的中转参数:"
  require_landing_params
  askv RPORT "中转机监听端口" "443"
  askv RSNI  "中转机 Reality 伪装域名" "$DEFAULT_SNI"
  askv NAME  "中转节点名称" "中转"
  askv DNAME "直连节点名称" "直连"
  do_relay
}
do_menu_realm() {
  log " 请填写【落地机】的地址信息:"
  askv LADDR "落地机 IP/域名" ""
  askv LPORT "落地机端口" "443"
  askv RPORT "中转机监听端口" "443"
  askv UDP   "同时转发 UDP? 落地是 UDP 类协议才需要 (y/n)" "n"
  do_realm
}

# ------------------------------- 入口 ---------------------------------------
self_install() {
  [[ ${XRELAY_SELF_INSTALLED:-} == 1 ]] && return 0
  export XRELAY_SELF_INSTALLED=1
  dry && return 0
  [[ -f $0 && $0 != /dev/fd/* && $0 != /proc/* ]] || return 0
  if [[ ! -x /usr/local/bin/xrelay ]] || ! cmp -s "$0" /usr/local/bin/xrelay 2>/dev/null; then
    if install -m 755 "$0" /usr/local/bin/xrelay 2>/dev/null; then
      info "已安装快捷命令: 以后可直接运行  xrelay info / xrelay menu"
    fi
  fi
  return 0
}

main() {
  local MODE=${1:-menu} a
  shift 2>/dev/null || true
  for a in "$@"; do case $a in *=*) export "$a" ;; esac; done
  case "$MODE" in -h|--help) MODE=help ;; esac
  dry && mkdir -p "$DRYDIR"
  case "$MODE" in
    landing)   self_install; do_landing ;;
    relay)     self_install; do_relay ;;
    realm)     self_install; do_realm ;;
    info)      self_install; do_info ;;
    uninstall) self_install; do_uninstall ;;
    help)      do_help ;;
    menu)      self_install; do_menu ;;
    *) die "未知命令: $MODE  (可用: landing / relay / realm / info / uninstall / help / menu)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
