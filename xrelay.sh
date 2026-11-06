#!/usr/bin/env bash
# ============================================================================
#  xrelay.sh  v1.3.2  (2026-11-06)
#
#  中转机 + 落地机 一键部署脚本  (Xray VLESS-Vision-Reality)
#
#    landing : 在【落地机】部署 Reality 节点, 并生成中转所需的全部参数
#    relay   : 在【中转机】部署中转, 单端口同时提供两个节点:
#              "中转节点"(流量走落地机出口) 与 "直连节点"(流量从本机出口)
#    realm   : 中转替代方案, 纯 TCP 转发(兼容任意 TCP 落地协议, UDP 需自测)
#    mirror  : 跟随落地机订阅, 把落地节点批量镜像到本机并更新本机订阅(推荐)
#    rules   : 用内置或外部订阅(如机场配置)的规则段补充本机订阅的分流规则, 并修正国内域名的 DNS 解析
#    info    : 查看已部署信息      uninstall: 卸载
#    help    : 参数与用法说明      menu: 交互菜单(默认)
#
#  用法示例:
#    bash xrelay.sh landing LPORT=443 LSNI=aws.amazon.com NAME=落地
#    bash xrelay.sh relay LADDR=1.2.3.4 LPORT=443 LUUID=xxx LSNI=xxx LPBK=xxx LSID=xxx
#    bash xrelay.sh realm LADDR=1.2.3.4 LPORT=443 RPORT=8443
#    bash xrelay.sh mirror SUBURL=http://1.2.3.4:35948/123
#    bash xrelay.sh rules
# ============================================================================
set -u

[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]] || { echo "需要 bash 4.0 及以上版本"; exit 1; }

VERSION="1.3.2"
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
REALM_BIN=${REALM_BIN:-/usr/local/bin/realm}
REALM_CONFIG=${REALM_CONFIG:-/etc/realm/config.toml}
REALM_UNIT=${REALM_UNIT:-/etc/systemd/system/realm.service}
REALM_INIT=${REALM_INIT:-/etc/init.d/realm}
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
  elif have_bin apk; then
    apk add --no-cache "${miss[@]}" >/dev/null 2>&1 || true
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
  mkdir -p /etc/sysctl.d 2>/dev/null || true
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-xrelay-bbr.conf 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-xrelay-bbr.conf >/dev/null 2>&1 || true
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
  if [[ ! -d /run/systemd/system ]] || ! have_bin systemctl; then
    die "landing/relay 模式依赖 Xray 官方安装脚本, 需要 systemd 系统; Alpine 等系统请使用 realm/mirror 模式"
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
  mkdir -p "$(dirname "$TESTLOG")" 2>/dev/null || true
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
  if [[ -s $real ]] && ! grep -q 'xrelay' "$real" && grep -qE '"(inbounds|outbounds)"' "$real"; then
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
  if dry; then printf '  [DRYRUN] 启动 realm 服务\n'; return 0; fi
  if [[ -d /run/systemd/system ]] && have_bin systemctl; then
    cat > "$REALM_UNIT" <<EOF
[Unit]
Description=Realm TCP/UDP Relay (xrelay)
After=network.target

[Service]
Type=simple
ExecStart=${REALM_BIN} -c ${REALM_CONFIG}
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
    ok "realm 服务运行中 (systemd)"
  elif have_bin rc-service && have_bin rc-update; then
    cat > "$REALM_INIT" <<EOF
#!/sbin/openrc-run
description="Realm TCP/UDP Relay (xrelay)"
command="${REALM_BIN}"
command_args="-c ${REALM_CONFIG}"
command_background=true
pidfile="/run/realm.pid"
output_log="/var/log/realm.log"
error_log="/var/log/realm.log"
EOF
    chmod 755 "$REALM_INIT"
    rc-update add realm default >/dev/null 2>&1 || true
    rc-service realm restart >/dev/null 2>&1 || true
    sleep 1
    if ! rc-service realm status >/dev/null 2>&1; then
      log "----- /var/log/realm.log (最后 20 行) -----"
      tail -n 20 /var/log/realm.log 2>/dev/null || true
      die "realm 启动失败(OpenRC), 请查看上方日志"
    fi
    ok "realm 服务运行中 (OpenRC)"
  else
    pkill -f "realm -c" >/dev/null 2>&1 || true
    nohup "$REALM_BIN" -c "$REALM_CONFIG" >>/var/log/realm.log 2>&1 &
    sleep 1
    if ! pgrep -f "realm -c" >/dev/null 2>&1; then
      log "----- /var/log/realm.log (最后 20 行) -----"
      tail -n 20 /var/log/realm.log 2>/dev/null || true
      die "realm 启动失败, 请查看上方日志"
    fi
    rm -f /tmp/xrelay-cron.tmp
    { crontab -l 2>/dev/null | grep -v 'xrelay-realm' || true; } > /tmp/xrelay-cron.tmp 2>/dev/null || true
    echo "@reboot sleep 10 && $REALM_BIN -c $REALM_CONFIG >>/var/log/realm.log 2>&1 # xrelay-realm" >> /tmp/xrelay-cron.tmp
    if crontab /tmp/xrelay-cron.tmp 2>/dev/null; then
      ok "realm 已启动 (无服务管理器模式, crontab 开机自启已配置)"
    else
      warn "realm 已启动, 但 crontab 不可用; 重启机器后需手动运行: $REALM_BIN -c $REALM_CONFIG &"
    fi
    rm -f /tmp/xrelay-cron.tmp
  fi
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
# ------------------------------- mirror 模式 ---------------------------------
# 跟随落地机订阅镜像: 把落地机(argosbx 部署)订阅里的节点批量镜像到本机(中转机)
#   - 用 realm 纯转发, 不动两侧现有的 xray / argosbx 服务
#   - 落地订阅每个节点在本机分配一个端口, 逐个转发
#   - 本机 clmi.yaml / jhsub.txt / sbox.json 订阅自动追加镜像节点

CLMI_BEGIN='# >>> xrelay-mirror >>>'
CLMI_END='# <<< xrelay-mirror <<<'

b64dec() { local s=$1; while (( ${#s} % 4 )); do s+='='; done; printf '%s' "$s" | base64 -d 2>/dev/null; }
b64enc() { base64 | tr -d '\n'; }
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

mirror_fetch() { curl -fsSL --retry 2 --connect-timeout 8 --max-time 30 "$1" 2>/dev/null; }

clmi_split_blocks() { # 抽出 clmi.yaml 的 proxies 段, 每个条目块后跟一行 @@XRL_BLK@@
  awk '
    /^proxies:[[:space:]]*$/ { inp=1; next }
    /^proxy-groups:[[:space:]]*$/ { inp=0 }
    inp && /^[[:space:]]*-[[:space:]]*name:/ {
      if (buf != "") { print buf; print "@@XRL_BLK@@" }
      buf = $0; next
    }
    inp && buf != "" { buf = buf "\n" $0 }
    END { if (buf != "") { print buf; print "@@XRL_BLK@@" } }
  ' "$1"
}

blk_field() { # $1=条目块 $2=字段名 -> 第一个匹配行的值
  printf '%s\n' "$1" | sed -nE "s/^[[:space:]]*-?[[:space:]]*$2:[[:space:]]*//p" | head -n1
}

mirror_transform_block() { # $1=块 $2=新名 $3=新server $4=新port -> 改写后的块
  printf '%s\n' "$1" | awk -v nn="$2" -v ns="$3" -v np="$4" '
    !dn && /^[[:space:]]*-?[[:space:]]*name:/ { sub(/name:.*/, "name: \"" nn "\""); dn=1 }
    !ds && /^[[:space:]]*server:/ { sub(/server:.*/, "server: \"" ns "\""); ds=1 }
    !dp && /^[[:space:]]*port:/ { sub(/port:.*/, "port: " np); dp=1 }
    { print }
  '
}

mirror_link_name() { # $1=分享链接 -> 节点名(尽力而为)
  local l=$1 m
  case $l in
    vmess://*) m=$(b64dec "${l#vmess://}"); printf '%s' "$m" | sed -nE 's/.*"ps"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1 ;;
    *'#'*) printf '%s' "${l#*#}" ;;
    *) printf '' ;;
  esac
}

mirror_link_key() { # $1=分享链接 -> host:port (小写host), 失败返回1
  local l=$1 m dec hp host port
  case $l in
    vmess://*)
      dec=$(b64dec "${l#vmess://}")
      host=$(printf '%s' "$dec" | sed -nE 's/.*"add"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)
      port=$(printf '%s' "$dec" | sed -nE 's/.*"port"[[:space:]]*:[[:space:]]*"?([0-9]+)"?.*/\1/p' | head -n1)
      ;;
    ss://*)
      m=${l#ss://}; m=${m%%#*}
      if [[ $m == *@* ]]; then hp=${m##*@}; else dec=$(b64dec "$m"); hp=${dec##*@}; fi
      if [[ $hp == \[*\]* ]]; then host=${hp#[}; host=${host%%]*}; else host=${hp%:*}; fi
      port=${hp##*:}
      ;;
    *://*)
      m=${l#*://}; m=${m%%#*}; m=${m%%\?*}; hp=${m##*@}
      if [[ $hp == \[*\]* ]]; then host=${hp#[}; host=${host%%]*}; else host=${hp%:*}; fi
      port=${hp##*:}
      ;;
    *) return 1 ;;
  esac
  [[ -n ${host:-} && ${port:-} =~ ^[0-9]+$ ]] || return 1
  printf '%s:%s' "$(printf '%s' "$host" | tr 'A-Z' 'a-z')" "$port"
}

mirror_link_rewrite() { # $1=链接 $2=新host $3=新port -> 改写后的链接
  local link=$1 nh=$2 np=$3 scheme m frag q ui hp host port newhp dec
  case $link in
    vmess://*)
      dec=$(b64dec "${link#vmess://}")
      [[ -n $dec ]] || { printf '%s' "$link"; return 0; }
      dec=$(printf '%s' "$dec" | sed -E "s|(\"add\"[[:space:]]*:[[:space:]]*\")[^\"]*|\1${nh}|; s|(\"port\"[[:space:]]*:[[:space:]]*\"?)[0-9]+|\1${np}|; s|(\"ps\"[[:space:]]*:[[:space:]]*\")|\1${PREFIX}|")
      printf 'vmess://%s' "$(printf '%s' "$dec" | b64enc)"
      return 0
      ;;
    ss://*)
      m=${link#ss://}; frag=""
      case $m in *'#'*) frag="#${PREFIX}${m#*#}"; m=${m%%#*} ;; esac
      newhp=$nh; [[ $nh == *:* ]] && newhp="[$nh]"
      if [[ $m == *@* ]]; then
        ui=${m%@*}
        printf 'ss://%s@%s:%s%s' "$ui" "$newhp" "$np" "$frag"
      else
        dec=$(b64dec "$m")
        if [[ -z $dec || $dec != *@* ]]; then printf '%s' "$link"; return 0; fi
        ui=${dec%@*}
        printf 'ss://%s%s' "$(printf '%s' "$ui@$newhp:$np" | b64enc)" "$frag"
      fi
      return 0
      ;;
    *://*)
      scheme=${link%%://*}
      m=${link#*://}; frag=""
      case $m in *'#'*) frag="#${PREFIX}${m#*#}"; m=${m%%#*} ;; esac
      q=""
      case $m in *'?'*) q="?${m#*\?}"; m=${m%%\?*} ;; esac
      [[ $m == *@* ]] || { printf '%s' "$link"; return 0; }
      ui=${m%@*}; hp=${m##*@}
      newhp=$nh; [[ $nh == *:* ]] && newhp="[$nh]"
      printf '%s://%s@%s:%s%s%s' "$scheme" "$ui" "$newhp" "$np" "$q" "$frag"
      return 0
      ;;
    *) printf '%s' "$link" ;;
  esac
}

mirror_load_ports() { # $1=ports文件; 加载到 MKEYS/MPORTS 数组
  MKEYS=(); MPORTS=()
  [[ -f $1 ]] || return 0
  local k p
  while IFS='|' read -r k p; do
    [[ -n ${k:-} && ${p:-} =~ ^[0-9]+$ ]] || continue
    MKEYS+=("$k"); MPORTS+=("$p")
  done < "$1"
}
mirror_alloc() { # $1=key -> 端口放全局 MIRROR_PORT(命令替换会丢数组修改, 不能echo)
  local i n=${#MKEYS[@]} p used
  for ((i=0; i<n; i++)); do
    if [[ ${MKEYS[i]} == "$1" ]]; then
      TOUCHED["$1"]=1
      MIRROR_PORT=${MPORTS[i]}
      return 0
    fi
  done
  p=${BASE:-42000}
  used=" ${MPORTS[*]:-} "
  while :; do
    case $used in *" $p "*) p=$((p+1)); continue ;; esac
    if port_busy "$p" >/dev/null 2>&1; then p=$((p+1)); continue; fi
    break
  done
  MKEYS+=("$1"); MPORTS+=("$p"); TOUCHED["$1"]=1
  MIRROR_PORT=$p
  return 0
}
mirror_prune_ports() { # 仅保留本次出现过的 key
  local i out_k=() out_p=()
  for ((i=0; i<${#MKEYS[@]}; i++)); do
    [[ -n ${TOUCHED[${MKEYS[i]}]:-} ]] || continue
    out_k+=("${MKEYS[i]}"); out_p+=("${MPORTS[i]}")
  done
  if ((${#out_k[@]})); then MKEYS=("${out_k[@]}"); MPORTS=("${out_p[@]}"); else MKEYS=(); MPORTS=(); fi
}
mirror_save_ports() { local f=$1 i; mkdir -p "$(dirname "$f")"; { for ((i=0; i<${#MKEYS[@]}; i++)); do printf '%s|%s\n' "${MKEYS[i]}" "${MPORTS[i]}"; done; } > "$f"; }

mirror_clean_clmi() { # 删除 clmi.yaml 中带标记的镜像块
  local f=$1 tmp
  [[ -f $f ]] || return 0
  grep -q 'xrelay-mirror' "$f" || return 0
  tmp=$(mktemp)
  sed -e '/# >>> xrelay-mirror >>>/,/# <<< xrelay-mirror <<</d' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}
mirror_insert_clmi() { # $1=clmi $2=代理块文件 $3=名字块文件
  local f=$1 tmp
  tmp=$(mktemp)
  awk -v pfile="$2" -v nfile="$3" '
    /^proxy-groups:[[:space:]]*$/ { while ((getline l < pfile) > 0) print l; close(pfile) }
    { print }
    /^  proxies:[[:space:]]*$/ { while ((getline l < nfile) > 0) print l; close(nfile) }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

mirror_update_jhsub() { # $1=jhsub $2=新链接文件 $3=旧链接文件
  local f=$1 nf=$2 of=$3 tmp
  [[ -f $f ]] || { warn "未找到 $f, 跳过 jhsub.txt 更新"; return 0; }
  tmp=$(mktemp)
  if [[ -s $of ]]; then grep -vxF -f "$of" "$f" > "$tmp" || true; else cat "$f" > "$tmp"; fi
  cat "$tmp" > "$f"; rm -f "$tmp"
  [[ -s $nf ]] && cat "$nf" >> "$f"
  return 0
}

find_python() {
  local c
  for c in ${PYTHON:-} python3 python /usr/bin/python3 /usr/bin/python; do
    [[ -n $c ]] || continue
    if "$c" -c 'import json' >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

mirror_update_sbox() { # $1=本机sbox $2=落地sbox $3=ports文件
  local target=$1 landing=$2 mapf=$3 py
  [[ -f $target && -s $landing ]] || { warn "sbox.json 缺失, 跳过更新"; return 0; }
  if ! py=$(find_python); then warn "未找到可用的 python, 跳过 sbox.json 更新"; return 1; fi
  if ! "$py" - "$target" "$landing" "$mapf" "$ADDR" "$PREFIX" <<'PYEOF'
import json, sys
target, landing, mapf, addr, prefix = sys.argv[1:6]
mapping = {}
for line in open(mapf, encoding='utf-8'):
    line = line.strip()
    if not line or '|' not in line:
        continue
    k, p = line.rsplit('|', 1)
    try:
        mapping[k.lower()] = int(p)
    except ValueError:
        continue
land = json.load(open(landing, encoding='utf-8'))
new_outs, new_tags = [], []
for ob in land.get('outbounds', []):
    if not isinstance(ob, dict):
        continue
    srv, prt = ob.get('server'), ob.get('server_port')
    if not srv or prt is None:
        continue
    try:
        key = f"{srv.lower()}:{int(prt)}"
    except (ValueError, TypeError):
        continue
    if key not in mapping:
        continue
    ob = json.loads(json.dumps(ob))
    ob['server'] = addr
    ob['server_port'] = mapping[key]
    tag = prefix + str(ob.get('tag', 'node'))
    ob['tag'] = tag
    new_outs.append(ob)
    new_tags.append(tag)
d = json.load(open(target, encoding='utf-8'))
outs = [o for o in d.get('outbounds', []) if not str(o.get('tag', '')).startswith(prefix)]
outs.extend(new_outs)
d['outbounds'] = outs
for o in outs:
    if o.get('type') in ('selector', 'urltest') and isinstance(o.get('outbounds'), list):
        o['outbounds'] = [x for x in o['outbounds'] if not str(x).startswith(prefix)] + new_tags
json.dump(d, open(target, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"sbox.json 已写入 {len(new_tags)} 个镜像节点")
PYEOF
  then
    warn "sbox.json 更新失败(请检查 python 环境)"
    return 1
  fi
}

mirror_clean_subfiles() { # 卸载用: $1=AGS目录 $2=前缀 $3=xrelay目录
  local d=$1 prefix=$2 xd=$3 py
  if [[ -f "$d/clmi.yaml" ]] && grep -q 'xrelay-mirror' "$d/clmi.yaml"; then
    mirror_clean_clmi "$d/clmi.yaml"
    ok "已清理 $d/clmi.yaml 中的镜像节点"
  fi
  if [[ -f "$d/jhsub.txt" && -s "$xd/mirror.links" ]]; then
    grep -vxF -f "$xd/mirror.links" "$d/jhsub.txt" > "$d/jhsub.txt.tmp" || true
    cat "$d/jhsub.txt.tmp" > "$d/jhsub.txt"; rm -f "$d/jhsub.txt.tmp"
    ok "已清理 $d/jhsub.txt 中的镜像节点"
  fi
  if [[ -f "$d/sbox.json" ]] && py=$(find_python); then
    "$py" - "$d/sbox.json" "$prefix" <<'PYEOF'
import json, sys
p, prefix = sys.argv[1:3]
d = json.load(open(p, encoding='utf-8'))
outs = [o for o in d.get('outbounds', []) if not str(o.get('tag', '')).startswith(prefix)]
for o in outs:
    if o.get('type') in ('selector', 'urltest') and isinstance(o.get('outbounds'), list):
        o['outbounds'] = [x for x in o['outbounds'] if not str(x).startswith(prefix)]
d['outbounds'] = outs
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PYEOF
    ok "已清理 $d/sbox.json 中的镜像节点"
  fi
  if [[ -f "$d/clmi.yaml" ]] && grep -q 'xrelay-ruleproviders' "$d/clmi.yaml"; then
    local ctmp
    ctmp=$(mktemp)
    sed -e '/# >>> xrelay-ruleproviders >>>/,/# <<< xrelay-ruleproviders <<</d' "$d/clmi.yaml" > "$ctmp" && cat "$ctmp" > "$d/clmi.yaml"
    rm -f "$ctmp"
    ok "已清理 $d/clmi.yaml 中的 rule-providers 插入块"
  fi
  if [[ -f "$d/clmi.yaml" ]] && grep -q '# >>> xrelay-dns >>>' "$d/clmi.yaml"; then
    local dtmp
    dtmp=$(mktemp)
    sed -e '/# >>> xrelay-dns >>>/,/# <<< xrelay-dns <<</d' "$d/clmi.yaml" > "$dtmp" && cat "$dtmp" > "$d/clmi.yaml"
    rm -f "$dtmp"
    ok "已清理 $d/clmi.yaml 中的 DNS 修正块"
  fi
  if [[ -f "$d/clmi.yaml.rules-orig" && -f "$d/clmi.yaml" ]]; then
    local rtmp
    rtmp=$(mktemp)
    { awk '/^rules:/{exit} {print}' "$d/clmi.yaml"; cat "$d/clmi.yaml.rules-orig"; } > "$rtmp" && cat "$rtmp" > "$d/clmi.yaml"
    rm -f "$rtmp" "$d/clmi.yaml.rules-orig"
    ok "已恢复 $d/clmi.yaml 的原始分流规则"
  fi
}

write_mirror_realm_config() { # $1=配置路径 $2=true/false(udp) $3=端点表文件(port|host|port)
  local cfg=$1 udpv=$2 efile=$3 p h pt remote
  mkdir -p "$(dirname "$cfg")"
  {
    printf '# xrelay-mirror 自动生成 %s, 请勿手改\n\n' "$(date '+%F %T')"
    printf '[log]\nlevel = "warn"\n\n'
    printf '[network]\nno_tcp = false\nuse_udp = %s\n\n' "$udpv"
    while IFS='|' read -r p h pt; do
      [[ -n ${p:-} ]] || continue
      remote="$h:$pt"
      [[ $h == *:* ]] && remote="[$h]:$pt"
      printf '[[endpoints]]\nlisten = "0.0.0.0:%s"\nremote = "%s"\n\n' "$p" "$remote"
    done < "$efile"
  } > "$cfg"
}

open_fw_range() { # $1=起始端口 $2=结束端口 $3=y/n 是否含UDP
  local s=$1 e=$2 udp=$3
  if dry; then printf '  [DRYRUN] 放行防火墙 %s-%s/tcp%s\n' "$s" "$e" "$([[ $udp == y ]] && printf ' 和 /udp')"; return 0; fi
  if have_bin ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$s:$e/tcp" >/dev/null 2>&1 && ok "ufw 已放行 $s:$e/tcp"
    if [[ $udp == y ]]; then ufw allow "$s:$e/udp" >/dev/null 2>&1 && ok "ufw 已放行 $s:$e/udp"; fi
  elif have_bin firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$s-$e/tcp" >/dev/null 2>&1
    if [[ $udp == y ]]; then firewall-cmd --permanent --add-port="$s-$e/udp" >/dev/null 2>&1; fi
    firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已放行 $s-$e"
  else
    info "未检测到启用中的 ufw/firewalld, 跳过本机防火墙配置"
  fi
  if [[ $udp == y ]]; then
    info "请确认 VPS 安全组放行 TCP $s-$e 和 UDP $s-$e"
  else
    info "请确认 VPS 安全组放行 TCP $s-$e"
  fi
}

show_mirror_summary() { # 需要 MIRROR_ROWS / AGS_DIR / ADDR
  local row nm np key sp st
  log ""
  log "${C_GREEN}${C_BOLD}========== 镜像部署完成 ==========${C_RESET}"
  log " 落地订阅 : $SUBURL"
  log " 镜像节点 : 共 ${#MIRROR_ROWS[@]} 个 (名称前缀 ${PREFIX})"
  log ""
  for row in "${MIRROR_ROWS[@]}"; do
    nm=${row%%|*}; row=${row#*|}; np=${row%%|*}; key=${row#*|}
    log "   $nm -> 本机端口 $np -> $key"
  done
  log ""
  if [[ -n ${_MIRROR_JH_OK:-} || -n ${_MIRROR_CLMI_OK:-} || -n ${_MIRROR_SBOX_OK:-} ]]; then
    log " 本机订阅已更新, 客户端重新拉取订阅即可看到镜像节点"
  else
    warn "未找到本机 argosbx 订阅文件, 仅部署了转发; 订阅可在部署 argosbx 后重跑本模式"
  fi
  sp=$(cat "$AGS_DIR/subport.log" 2>/dev/null); st=$(cat "$AGS_DIR/subtoken.log" 2>/dev/null)
  if [[ -n $sp && -n $st ]]; then
    log ""
    log " 本机订阅地址(与原来相同):"
    log "   http://$ADDR:$sp/$st/clmi.yaml"
    log "   http://$ADDR:$sp/$st/jhsub.txt"
    log "   http://$ADDR:$sp/$st/sbox.json"
  fi
  log ""
  info "镜像节点与落地节点共用同一套参数, 仅地址/端口不同, 出口均为落地机"
  info "落地机重跑 argosbx 之后, 需在本机重跑一次 mirror 模式刷新订阅"
  info "验证: 客户端用任一镜像节点访问 https://ip.sb 应显示落地机 IP"
}

do_mirror() {
  banner "模式: 跟随落地订阅镜像 (mirror)"
  ensure_root
  [[ ${RESET:-} == y ]] || load_env_file "$(xrel_dir)/mirror.env"
  askv SUBURL "落地机订阅地址(粘贴 clmi.yaml / jhsub.txt / sbox.json 任意一条)" ""
  [[ -n ${SUBURL:-} ]] || die "缺少落地机订阅地址 SUBURL"
  local prev_sub
  prev_sub=$(sed -n "s/^SUBURL='\(.*\)'$/\1/p" "$(xrel_dir)/mirror.env" 2>/dev/null | head -n1)
  if [[ -n $prev_sub && $prev_sub != "$SUBURL" ]]; then
    info "检测到更换落地订阅(原: $prev_sub), 将按新落地重新分配镜像"
  fi
  local subbase=${SUBURL%/}
  case $subbase in
    */clmi.yaml|*/sbox.json|*/jhsub.txt) subbase=${subbase%/*} ;;
  esac
  BASE=${BASE:-42000}
  UDP=${UDP:-y}
  PREFIX=${PREFIX:-中转-}
  INCLUDE=${INCLUDE:-}
  AGS_DIR=${AGS_DIR:-$HOME/agsbx}
  validate_port "$BASE"
  ensure_deps
  ADDR=$(resolve_addr)
  [[ $ADDR == 203.0.113.10 ]] && warn "未能探测公网IP, 镜像地址可能不对, 请用 ADDR= 指定"
  if dry; then
    if [[ -d $AGS_DIR ]]; then
      rm -rf "$DRYDIR/agsbx-sim"
      cp -a "$AGS_DIR" "$DRYDIR/agsbx-sim"
      AGS_DIR="$DRYDIR/agsbx-sim"
      info "DRYRUN: 订阅文件操作在副本上进行: $AGS_DIR"
    fi
  fi

  # ---- 拉取落地订阅 ----
  local tmpd; tmpd=$(mktemp -d)
  info "拉取落地机订阅: $subbase/clmi.yaml"
  mirror_fetch "$subbase/clmi.yaml" > "$tmpd/land_clmi.yaml" || true
  [[ -s "$tmpd/land_clmi.yaml" ]] || die "无法获取落地机 clmi.yaml, 请检查订阅地址是否可访问"
  mirror_fetch "$subbase/jhsub.txt" > "$tmpd/land_jhsub.txt" || true
  mirror_fetch "$subbase/sbox.json" > "$tmpd/land_sbox.json" || true

  # ---- 分配端口并生成镜像条目 ----
  local -a MKEYS=() MPORTS=() MIRROR_ROWS=() PROXY_BLOCKS=() PROXY_KEYS=() PROXY_NAMES=() LINK_KEYS=() LINK_LINES=()
  local -A TOUCHED=() USED_N=()
  mirror_load_ports "$(xrel_dir)/mirror.ports"
  [[ -f "$AGS_DIR/clmi.yaml" ]] && mirror_clean_clmi "$AGS_DIR/clmi.yaml"
  if [[ -f "$AGS_DIR/clmi.yaml" ]]; then
    while IFS= read -r nm; do [[ -n $nm ]] && USED_N["$nm"]=1; done < <(sed -nE 's/^[[:space:]]*-?[[:space:]]*name:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' "$AGS_DIR/clmi.yaml")
  fi
  local proxies_out="$tmpd/proxies.block" names_out="$tmpd/names.block"
  : > "$proxies_out"; : > "$names_out"

  collect_block() { # 收集阶段: 过滤并保存条目, 暂不分配端口
    local blk=$1 nm srv prt key
    nm=$(trim "$(blk_field "$blk" name)")
    if [[ $nm == '"'*'"' ]]; then nm=${nm:1:${#nm}-2}; fi
    nm=$(trim "$nm")
    srv=$(trim "$(blk_field "$blk" server)")
    if [[ $srv == '"'*'"' ]]; then srv=${srv:1:${#srv}-2}; fi
    srv=$(trim "$srv")
    [[ $srv == \[*\] ]] && srv=${srv#[} && srv=${srv%]}
    prt=$(trim "$(blk_field "$blk" port)")
    if [[ -z $nm || -z $srv || ! ${prt:-} =~ ^[0-9]+$ ]]; then
      warn "跳过无法解析的条目: ${nm:-未知}"
      return 0
    fi
    if [[ -n $INCLUDE ]] && ! printf '%s' "$nm" | grep -qE "$INCLUDE"; then return 0; fi
    if [[ $UDP != y ]] && printf '%s\n' "$blk" | grep -qE 'type:[[:space:]]*(hysteria2|tuic)|alpn:[[:space:]]*\[h3\]|^[[:space:]]*-[[:space:]]*h3[[:space:]]*$'; then
      warn "UDP=n, 跳过 UDP 类节点: $nm"
      return 0
    fi
    key="$(printf '%s' "$srv" | tr 'A-Z' 'a-z'):$prt"
    PROXY_BLOCKS+=("$blk"); PROXY_KEYS+=("$key"); PROXY_NAMES+=("$nm")
    return 0
  }

  local blk="" line
  while IFS= read -r line; do
    if [[ $line == '@@XRL_BLK@@' ]]; then
      [[ -n $blk ]] && collect_block "$blk"
      blk=""
    else
      blk+="$line"$'\n'
    fi
  done < <(clmi_split_blocks "$tmpd/land_clmi.yaml")

  local links_new="$tmpd/links.new"; : > "$links_new"
  local jh_fetched=0
  if [[ -s "$tmpd/land_jhsub.txt" ]]; then
    jh_fetched=1
    local lk lname lkey
    while IFS= read -r lk; do
      lk=$(trim "$lk")
      [[ -n $lk ]] || continue
      lname=$(mirror_link_name "$lk")
      if [[ -n $INCLUDE && -n $lname ]] && ! printf '%s' "$lname" | grep -qE "$INCLUDE"; then continue; fi
      if [[ $UDP != y ]]; then
        case $lk in
          hysteria2://*|hy2://*|tuic://*) warn "UDP=n, 跳过 UDP 节点链接: ${lname:-link}"; continue ;;
        esac
        if printf '%s' "$lk" | grep -q 'alpn=h3'; then warn "UDP=n, 跳过 QUIC(h3) 节点链接: ${lname:-link}"; continue; fi
      fi
      lkey=$(mirror_link_key "$lk") || { warn "无法解析链接(缺服务器地址或格式不支持), 跳过: ${lk:0:70}"; continue; }
      LINK_KEYS+=("$lkey"); LINK_LINES+=("$lk")
    done < "$tmpd/land_jhsub.txt"
  fi

  # ---- 回收废弃端口: 端口映射只保留新落地订阅里仍然存在的 key ----
  local -A NEWSET=()
  local k
  if ((${#PROXY_KEYS[@]})); then for k in "${PROXY_KEYS[@]}"; do NEWSET["$k"]=1; done; fi
  if ((${#LINK_KEYS[@]})); then for k in "${LINK_KEYS[@]}"; do NEWSET["$k"]=1; done; fi
  local i out_k=() out_p=()
  for ((i=0; i<${#MKEYS[@]}; i++)); do
    [[ -n ${NEWSET[${MKEYS[i]}]:-} ]] || continue
    out_k+=("${MKEYS[i]}"); out_p+=("${MPORTS[i]}")
  done
  if ((${#out_k[@]})); then MKEYS=("${out_k[@]}"); MPORTS=("${out_p[@]}"); else MKEYS=(); MPORTS=(); fi

  # ---- 生成阶段: 统一分配端口并输出镜像条目 ----
  local np name2 base j
  for ((i=0; i<${#PROXY_BLOCKS[@]}; i++)); do
    k=${PROXY_KEYS[i]}
    mirror_alloc "$k"; np=$MIRROR_PORT
    name2="${PREFIX}${PROXY_NAMES[i]}"
    base=$name2; j=2
    while [[ -n ${USED_N[$name2]:-} ]]; do name2="$base-$j"; j=$((j+1)); done
    USED_N["$name2"]=1
    mirror_transform_block "${PROXY_BLOCKS[i]}" "$name2" "$ADDR" "$np" >> "$proxies_out"
    printf '\n' >> "$proxies_out"
    printf '    - "%s"\n' "$name2" >> "$names_out"
    MIRROR_ROWS+=("$name2|$np|$k")
  done
  local n=${#MIRROR_ROWS[@]}
  ((n)) || die "没有解析到任何可镜像的节点(可检查 INCLUDE 过滤条件)"
  for ((i=0; i<${#LINK_LINES[@]}; i++)); do
    mirror_alloc "${LINK_KEYS[i]}"; np=$MIRROR_PORT
    { mirror_link_rewrite "${LINK_LINES[i]}" "$ADDR" "$np"; printf '\n'; } >> "$links_new"
  done

  # ---- 保存端口映射(仅保留本次出现过的节点) ----
  mirror_prune_ports
  mirror_save_ports "$(xrel_dir)/mirror.ports"
  local efile="$tmpd/endpoints.list" i
  : > "$efile"
  for ((i=0; i<${#MKEYS[@]}; i++)); do
    key=${MKEYS[i]}
    printf '%s|%s|%s\n' "${MPORTS[i]}" "${key%:*}" "${key##*:}" >> "$efile"
  done
  sort -t'|' -k1,1n "$efile" -o "$efile"
  if [[ -n $(awk -F'|' '{print $1}' "$efile" | sort | uniq -d) ]]; then
    die "端口分配异常(出现重复监听端口), 请用 BASE= 指定其他起始端口后重试"
  fi

  # ---- realm 配置与服务 ----
  local udpv=false; [[ $UDP == y ]] && udpv=true
  if dry; then
    write_mirror_realm_config "$(realm_cfg_path)" "$udpv" "$efile"
    printf '  [DRYRUN] realm 配置已生成: %s\n' "$(realm_cfg_path)"
  else
    install_realm
    if [[ -s $REALM_CONFIG ]] && ! head -n1 "$REALM_CONFIG" | grep -q 'xrelay-mirror'; then
      cp -a "$REALM_CONFIG" "${REALM_CONFIG}.bak.$(date +%s)"
      warn "已备份原有 realm 配置"
    fi
    write_mirror_realm_config "$REALM_CONFIG" "$udpv" "$efile"
    start_realm
  fi

  # ---- 更新本机订阅文件 ----
  _MIRROR_CLMI_OK=""; _MIRROR_JH_OK=""; _MIRROR_SBOX_OK=""
  if [[ -f "$AGS_DIR/clmi.yaml" ]]; then
    [[ -f "$AGS_DIR/clmi.yaml.xrelay-orig" ]] || cp -a "$AGS_DIR/clmi.yaml" "$AGS_DIR/clmi.yaml.xrelay-orig"
    { printf '%s\n' "$CLMI_BEGIN"; cat "$proxies_out"; printf '%s\n' "$CLMI_END"; } > "$tmpd/proxies.mk"
    { printf '%s\n' "$CLMI_BEGIN"; cat "$names_out"; printf '%s\n' "$CLMI_END"; } > "$tmpd/names.mk"
    mirror_insert_clmi "$AGS_DIR/clmi.yaml" "$tmpd/proxies.mk" "$tmpd/names.mk"
    _MIRROR_CLMI_OK=1
    ok "clmi.yaml 已追加 $n 个镜像节点"
  else
    warn "未找到 $AGS_DIR/clmi.yaml, 跳过 Clash 订阅更新(可设置 AGS_DIR=)"
  fi
  if [[ -f "$AGS_DIR/jhsub.txt" && $jh_fetched == 1 ]]; then
    [[ -f "$AGS_DIR/jhsub.txt.xrelay-orig" ]] || cp -a "$AGS_DIR/jhsub.txt" "$AGS_DIR/jhsub.txt.xrelay-orig"
    mirror_update_jhsub "$AGS_DIR/jhsub.txt" "$links_new" "$(xrel_dir)/mirror.links"
    cp "$links_new" "$(xrel_dir)/mirror.links"
    _MIRROR_JH_OK=1
    ok "jhsub.txt 已追加镜像链接 ($(grep -c . "$links_new" 2>/dev/null || echo 0) 条)"
  fi
  if [[ -f "$AGS_DIR/sbox.json" && -s "$tmpd/land_sbox.json" ]]; then
    [[ -f "$AGS_DIR/sbox.json.xrelay-orig" ]] || cp -a "$AGS_DIR/sbox.json" "$AGS_DIR/sbox.json.xrelay-orig"
    if mirror_update_sbox "$AGS_DIR/sbox.json" "$tmpd/land_sbox.json" "$(xrel_dir)/mirror.ports"; then
      _MIRROR_SBOX_OK=1
    fi
  fi

  # ---- 防火墙 / 保存状态 / 总结 ----
  if [[ ${#MPORTS[@]} -gt 0 ]]; then
    local pmin pmax
    pmin=$(printf '%s\n' "${MPORTS[@]}" | sort -n | head -n1)
    pmax=$(printf '%s\n' "${MPORTS[@]}" | sort -n | tail -n1)
    open_fw_range "$pmin" "$pmax" "$UDP"
  fi
  enable_bbr
  save_env_file "$(xrel_dir)/mirror.env" \
    "$(kv DATE "$(date '+%F %T')")" \
    "$(kv SUBURL "$SUBURL")" "$(kv BASE "$BASE")" "$(kv UDP "$UDP")" \
    "$(kv PREFIX "$PREFIX")" "$(kv INCLUDE "$INCLUDE")" "$(kv AGS_DIR "$AGS_DIR")" \
    "$(kv ADDR "$ADDR")"
  rm -rf "$tmpd"
  show_mirror_summary
}

do_menu_mirror() {
  log " 请填写落地机订阅信息(落地机需用 argosbx 部署并开启了订阅):"
  askv SUBURL "落地机订阅地址(clmi.yaml/jhsub.txt/sbox.json 任意一条)" ""
  askv BASE   "本机镜像端口起始值" "42000"
  askv UDP    "同时镜像 UDP 类节点? hy2/tuic 需要 (y/n)" "y"
  do_mirror
}

# ------------------------------- rules 模式 ---------------------------------
# 用内置规则集或外部订阅(如机场配置 yaml)的 rules 段补充/替换本机 clmi.yaml 的分流规则

# ------------------------------- 内置规则集 ---------------------------------
# 来源: 糖果云订阅的 rules 段, 已内置到脚本; 运行时把其策略组目标映射到 GROUP,
# DIRECT/REJECT/no-resolve 原样保留
rules_builtin() {
  cat <<'XRL_BUILTIN_RULES_EOF'
    - 'DOMAIN,127.0.0.1:7010,DIRECT'
    - 'DOMAIN-SUFFIX,services.googleapis.cn,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,xn--ngstr-lra8j.com,Candytally（糖果云）'
    - 'DOMAIN,safebrowsing.urlsec.qq.com,DIRECT'
    - 'DOMAIN,safebrowsing.googleapis.com,DIRECT'
    - 'DOMAIN,developer.apple.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,digicert.com,Candytally（糖果云）'
    - 'DOMAIN,ocsp.apple.com,Candytally（糖果云）'
    - 'DOMAIN,ocsp.comodoca.com,Candytally（糖果云）'
    - 'DOMAIN,ocsp.usertrust.com,Candytally（糖果云）'
    - 'DOMAIN,ocsp.sectigo.com,Candytally（糖果云）'
    - 'DOMAIN,ocsp.verisign.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,apple-dns.net,Candytally（糖果云）'
    - 'DOMAIN,testflight.apple.com,Candytally（糖果云）'
    - 'DOMAIN,sandbox.itunes.apple.com,Candytally（糖果云）'
    - 'DOMAIN,itunes.apple.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,apps.apple.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,blobstore.apple.com,Candytally（糖果云）'
    - 'DOMAIN,cvws.icloud-content.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,alpine,DIRECT'
    - 'DOMAIN-SUFFIX,mzstatic.com,DIRECT'
    - 'DOMAIN-SUFFIX,itunes.apple.com,DIRECT'
    - 'DOMAIN-SUFFIX,icloud.com,DIRECT'
    - 'DOMAIN-SUFFIX,icloud-content.com,DIRECT'
    - 'DOMAIN-SUFFIX,me.com,DIRECT'
    - 'DOMAIN-SUFFIX,aaplimg.com,DIRECT'
    - 'DOMAIN-SUFFIX,cdn20.com,DIRECT'
    - 'DOMAIN-SUFFIX,cdn-apple.com,DIRECT'
    - 'DOMAIN-SUFFIX,akadns.net,DIRECT'
    - 'DOMAIN-SUFFIX,akamaiedge.net,DIRECT'
    - 'DOMAIN-SUFFIX,edgekey.net,DIRECT'
    - 'DOMAIN-SUFFIX,mwcloudcdn.com,DIRECT'
    - 'DOMAIN-SUFFIX,mwcname.com,DIRECT'
    - 'DOMAIN-SUFFIX,apple.com,DIRECT'
    - 'DOMAIN-SUFFIX,apple-cloudkit.com,DIRECT'
    - 'DOMAIN-SUFFIX,apple-mapkit.com,DIRECT'
    - 'DOMAIN-SUFFIX,126.com,DIRECT'
    - 'DOMAIN-SUFFIX,126.net,DIRECT'
    - 'DOMAIN-SUFFIX,127.net,DIRECT'
    - 'DOMAIN-SUFFIX,163.com,DIRECT'
    - 'DOMAIN-SUFFIX,360buyimg.com,DIRECT'
    - 'DOMAIN-SUFFIX,36kr.com,DIRECT'
    - 'DOMAIN-SUFFIX,acfun.tv,DIRECT'
    - 'DOMAIN-SUFFIX,air-matters.com,DIRECT'
    - 'DOMAIN-SUFFIX,aixifan.com,DIRECT'
    - 'DOMAIN-KEYWORD,alicdn,DIRECT'
    - 'DOMAIN-KEYWORD,alipay,DIRECT'
    - 'DOMAIN-KEYWORD,taobao,DIRECT'
    - 'DOMAIN-SUFFIX,amap.com,DIRECT'
    - 'DOMAIN-SUFFIX,autonavi.com,DIRECT'
    - 'DOMAIN-KEYWORD,baidu,DIRECT'
    - 'DOMAIN-SUFFIX,bdimg.com,DIRECT'
    - 'DOMAIN-SUFFIX,bdstatic.com,DIRECT'
    - 'DOMAIN-SUFFIX,bilibili.com,DIRECT'
    - 'DOMAIN-SUFFIX,bilivideo.com,DIRECT'
    - 'DOMAIN-SUFFIX,caiyunapp.com,DIRECT'
    - 'DOMAIN-SUFFIX,clouddn.com,DIRECT'
    - 'DOMAIN-SUFFIX,cnbeta.com,DIRECT'
    - 'DOMAIN-SUFFIX,cnbetacdn.com,DIRECT'
    - 'DOMAIN-SUFFIX,cootekservice.com,DIRECT'
    - 'DOMAIN-SUFFIX,csdn.net,DIRECT'
    - 'DOMAIN-SUFFIX,ctrip.com,DIRECT'
    - 'DOMAIN-SUFFIX,dgtle.com,DIRECT'
    - 'DOMAIN-SUFFIX,dianping.com,DIRECT'
    - 'DOMAIN-SUFFIX,douban.com,DIRECT'
    - 'DOMAIN-SUFFIX,doubanio.com,DIRECT'
    - 'DOMAIN-SUFFIX,duokan.com,DIRECT'
    - 'DOMAIN-SUFFIX,easou.com,DIRECT'
    - 'DOMAIN-SUFFIX,ele.me,DIRECT'
    - 'DOMAIN-SUFFIX,feng.com,DIRECT'
    - 'DOMAIN-SUFFIX,fir.im,DIRECT'
    - 'DOMAIN-SUFFIX,frdic.com,DIRECT'
    - 'DOMAIN-SUFFIX,g-cores.com,DIRECT'
    - 'DOMAIN-SUFFIX,godic.net,DIRECT'
    - 'DOMAIN-SUFFIX,gtimg.com,DIRECT'
    - 'DOMAIN,cdn.hockeyapp.net,DIRECT'
    - 'DOMAIN-SUFFIX,hongxiu.com,DIRECT'
    - 'DOMAIN-SUFFIX,hxcdn.net,DIRECT'
    - 'DOMAIN-SUFFIX,iciba.com,DIRECT'
    - 'DOMAIN-SUFFIX,ifeng.com,DIRECT'
    - 'DOMAIN-SUFFIX,ifengimg.com,DIRECT'
    - 'DOMAIN-SUFFIX,ipip.net,DIRECT'
    - 'DOMAIN-SUFFIX,iqiyi.com,DIRECT'
    - 'DOMAIN-SUFFIX,jd.com,DIRECT'
    - 'DOMAIN-SUFFIX,jianshu.com,DIRECT'
    - 'DOMAIN-SUFFIX,knewone.com,DIRECT'
    - 'DOMAIN-SUFFIX,le.com,DIRECT'
    - 'DOMAIN-SUFFIX,lecloud.com,DIRECT'
    - 'DOMAIN-SUFFIX,lemicp.com,DIRECT'
    - 'DOMAIN-SUFFIX,licdn.com,DIRECT'
    - 'DOMAIN-SUFFIX,luoo.net,DIRECT'
    - 'DOMAIN-SUFFIX,meituan.com,DIRECT'
    - 'DOMAIN-SUFFIX,meituan.net,DIRECT'
    - 'DOMAIN-SUFFIX,mi.com,DIRECT'
    - 'DOMAIN-SUFFIX,miaopai.com,DIRECT'
    - 'DOMAIN-SUFFIX,microsoft.com,DIRECT'
    - 'DOMAIN-SUFFIX,microsoftonline.com,DIRECT'
    - 'DOMAIN-SUFFIX,miui.com,DIRECT'
    - 'DOMAIN-SUFFIX,miwifi.com,DIRECT'
    - 'DOMAIN-SUFFIX,mob.com,DIRECT'
    - 'DOMAIN-SUFFIX,netease.com,DIRECT'
    - 'DOMAIN-SUFFIX,office.com,DIRECT'
    - 'DOMAIN-SUFFIX,office365.com,DIRECT'
    - 'DOMAIN-KEYWORD,officecdn,DIRECT'
    - 'DOMAIN-SUFFIX,oschina.net,DIRECT'
    - 'DOMAIN-SUFFIX,ppsimg.com,DIRECT'
    - 'DOMAIN-SUFFIX,pstatp.com,DIRECT'
    - 'DOMAIN-SUFFIX,qcloud.com,DIRECT'
    - 'DOMAIN-SUFFIX,qdaily.com,DIRECT'
    - 'DOMAIN-SUFFIX,qdmm.com,DIRECT'
    - 'DOMAIN-SUFFIX,qhimg.com,DIRECT'
    - 'DOMAIN-SUFFIX,qhres.com,DIRECT'
    - 'DOMAIN-SUFFIX,qidian.com,DIRECT'
    - 'DOMAIN-SUFFIX,qihucdn.com,DIRECT'
    - 'DOMAIN-SUFFIX,qiniu.com,DIRECT'
    - 'DOMAIN-SUFFIX,qiniucdn.com,DIRECT'
    - 'DOMAIN-SUFFIX,qiyipic.com,DIRECT'
    - 'DOMAIN-SUFFIX,qq.com,DIRECT'
    - 'DOMAIN-SUFFIX,qqurl.com,DIRECT'
    - 'DOMAIN-SUFFIX,rarbg.to,DIRECT'
    - 'DOMAIN-SUFFIX,ruguoapp.com,DIRECT'
    - 'DOMAIN-SUFFIX,segmentfault.com,DIRECT'
    - 'DOMAIN-SUFFIX,sinaapp.com,DIRECT'
    - 'DOMAIN-SUFFIX,smzdm.com,DIRECT'
    - 'DOMAIN-SUFFIX,snapdrop.net,DIRECT'
    - 'DOMAIN-SUFFIX,sogou.com,DIRECT'
    - 'DOMAIN-SUFFIX,sogoucdn.com,DIRECT'
    - 'DOMAIN-SUFFIX,sohu.com,DIRECT'
    - 'DOMAIN-SUFFIX,soku.com,DIRECT'
    - 'DOMAIN-SUFFIX,speedtest.net,DIRECT'
    - 'DOMAIN-SUFFIX,sspai.com,DIRECT'
    - 'DOMAIN-SUFFIX,suning.com,DIRECT'
    - 'DOMAIN-SUFFIX,taobao.com,DIRECT'
    - 'DOMAIN-SUFFIX,tencent.com,DIRECT'
    - 'DOMAIN-SUFFIX,tenpay.com,DIRECT'
    - 'DOMAIN-SUFFIX,tianyancha.com,DIRECT'
    - 'DOMAIN-SUFFIX,tmall.com,DIRECT'
    - 'DOMAIN-SUFFIX,tudou.com,DIRECT'
    - 'DOMAIN-SUFFIX,umetrip.com,DIRECT'
    - 'DOMAIN-SUFFIX,upaiyun.com,DIRECT'
    - 'DOMAIN-SUFFIX,upyun.com,DIRECT'
    - 'DOMAIN-SUFFIX,veryzhun.com,DIRECT'
    - 'DOMAIN-SUFFIX,weather.com,DIRECT'
    - 'DOMAIN-SUFFIX,weibo.com,DIRECT'
    - 'DOMAIN-SUFFIX,xiami.com,DIRECT'
    - 'DOMAIN-SUFFIX,xiami.net,DIRECT'
    - 'DOMAIN-SUFFIX,xiaomicp.com,DIRECT'
    - 'DOMAIN-SUFFIX,ximalaya.com,DIRECT'
    - 'DOMAIN-SUFFIX,xmcdn.com,DIRECT'
    - 'DOMAIN-SUFFIX,xunlei.com,DIRECT'
    - 'DOMAIN-SUFFIX,yhd.com,DIRECT'
    - 'DOMAIN-SUFFIX,yihaodianimg.com,DIRECT'
    - 'DOMAIN-SUFFIX,yinxiang.com,DIRECT'
    - 'DOMAIN-SUFFIX,ykimg.com,DIRECT'
    - 'DOMAIN-SUFFIX,youdao.com,DIRECT'
    - 'DOMAIN-SUFFIX,youku.com,DIRECT'
    - 'DOMAIN-SUFFIX,zealer.com,DIRECT'
    - 'DOMAIN-SUFFIX,zhihu.com,DIRECT'
    - 'DOMAIN-SUFFIX,zhimg.com,DIRECT'
    - 'DOMAIN-SUFFIX,zimuzu.tv,DIRECT'
    - 'DOMAIN-SUFFIX,zoho.com,DIRECT'
    - 'DOMAIN-KEYWORD,amazon,Candytally（糖果云）'
    - 'DOMAIN-KEYWORD,google,Candytally（糖果云）'
    - 'DOMAIN-KEYWORD,gmail,Candytally（糖果云）'
    - 'DOMAIN-KEYWORD,youtube,Candytally（糖果云）'
    - 'DOMAIN-KEYWORD,facebook,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,fb.me,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,fbcdn.net,Candytally（糖果云）'
    - 'DOMAIN-KEYWORD,twitter,Candytally（糖果云）'
    - 'DOMAIN-KEYWORD,instagram,Candytally（糖果云）'
    - 'DOMAIN-KEYWORD,dropbox,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,twimg.com,Candytally（糖果云）'
    - 'DOMAIN-KEYWORD,blogspot,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,youtu.be,Candytally（糖果云）'
    - 'DOMAIN-KEYWORD,whatsapp,Candytally（糖果云）'
    - 'DOMAIN-KEYWORD,admarvel,REJECT'
    - 'DOMAIN-KEYWORD,admaster,REJECT'
    - 'DOMAIN-KEYWORD,adsage,REJECT'
    - 'DOMAIN-KEYWORD,adsmogo,REJECT'
    - 'DOMAIN-KEYWORD,adsrvmedia,REJECT'
    - 'DOMAIN-KEYWORD,adwords,REJECT'
    - 'DOMAIN-KEYWORD,adservice,REJECT'
    - 'DOMAIN-SUFFIX,appsflyer.com,REJECT'
    - 'DOMAIN-KEYWORD,domob,REJECT'
    - 'DOMAIN-SUFFIX,doubleclick.net,REJECT'
    - 'DOMAIN-KEYWORD,duomeng,REJECT'
    - 'DOMAIN-KEYWORD,dwtrack,REJECT'
    - 'DOMAIN-KEYWORD,guanggao,REJECT'
    - 'DOMAIN-KEYWORD,lianmeng,REJECT'
    - 'DOMAIN-SUFFIX,mmstat.com,REJECT'
    - 'DOMAIN-KEYWORD,mopub,REJECT'
    - 'DOMAIN-KEYWORD,omgmta,REJECT'
    - 'DOMAIN-KEYWORD,openx,REJECT'
    - 'DOMAIN-KEYWORD,partnerad,REJECT'
    - 'DOMAIN-KEYWORD,pingfore,REJECT'
    - 'DOMAIN-KEYWORD,supersonicads,REJECT'
    - 'DOMAIN-KEYWORD,uedas,REJECT'
    - 'DOMAIN-KEYWORD,umeng,REJECT'
    - 'DOMAIN-KEYWORD,usage,REJECT'
    - 'DOMAIN-SUFFIX,vungle.com,REJECT'
    - 'DOMAIN-KEYWORD,wlmonitor,REJECT'
    - 'DOMAIN-KEYWORD,zjtoolbar,REJECT'
    - 'DOMAIN-SUFFIX,9to5mac.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,abpchina.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,adblockplus.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,adobe.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,akamaized.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,alfredapp.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,amplitude.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ampproject.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,android.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,angularjs.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,aolcdn.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,apkpure.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,appledaily.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,appshopper.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,appspot.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,arcgis.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,archive.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,armorgames.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,aspnetcdn.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,att.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,awsstatic.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,azureedge.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,azurewebsites.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,bing.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,bintray.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,bit.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,bit.ly,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,bitbucket.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,bjango.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,bkrtx.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,blog.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,blogcdn.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,blogger.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,blogsmithmedia.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,blogspot.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,blogspot.hk,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,bloomberg.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,box.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,box.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,cachefly.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,chromium.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,cl.ly,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,cloudflare.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,cloudfront.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,cloudmagic.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,cmail19.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,cnet.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,cocoapods.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,comodoca.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,crashlytics.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,culturedcode.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,d.pr,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,danilo.to,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,dayone.me,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,db.tt,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,deskconnect.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,disq.us,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,disqus.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,disquscdn.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,dnsimple.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,docker.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,dribbble.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,droplr.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,duckduckgo.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,dueapp.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,dytt8.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,edgecastcdn.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,edgekey.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,edgesuite.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,engadget.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,entrust.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,eurekavpt.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,evernote.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,fabric.io,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,fast.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,fastly.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,fc2.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,feedburner.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,feedly.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,feedsportal.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,fiftythree.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,firebaseio.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,flexibits.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,flickr.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,flipboard.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,g.co,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,gabia.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,geni.us,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,gfx.ms,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ggpht.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ghostnoteapp.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,git.io,Candytally（糖果云）'
    - 'DOMAIN-KEYWORD,github,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,globalsign.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,gmodules.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,godaddy.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,golang.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,gongm.in,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,goo.gl,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,goodreaders.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,goodreads.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,gravatar.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,gstatic.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,gvt0.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,hockeyapp.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,hotmail.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,icons8.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ifixit.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ift.tt,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ifttt.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,iherb.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,imageshack.us,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,img.ly,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,imgur.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,imore.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,instapaper.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ipn.li,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,is.gd,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,issuu.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,itgonglun.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,itun.es,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ixquick.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,j.mp,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,js.revsci.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,jshint.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,jtvnw.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,justgetflux.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,kat.cr,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,klip.me,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,libsyn.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,linkedin.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,line-apps.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,linode.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,lithium.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,littlehj.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,live.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,live.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,livefilestore.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,llnwd.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,macid.co,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,macromedia.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,macrumors.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,mashable.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,mathjax.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,medium.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,mega.co.nz,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,mega.nz,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,megaupload.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,microsofttranslator.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,mindnode.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,mobile01.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,modmyi.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,msedge.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,myfontastic.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,name.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,nextmedia.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,nsstatic.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,nssurge.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,nyt.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,nytimes.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,omnigroup.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,onedrive.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,onenote.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ooyala.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,openvpn.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,openwrt.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,orkut.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,osxdaily.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,outlook.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ow.ly,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,paddleapi.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,parallels.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,parse.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,pdfexpert.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,periscope.tv,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,pinboard.in,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,pinterest.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,pixelmator.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,pixiv.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,playpcesor.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,playstation.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,playstation.com.hk,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,playstation.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,playstationnetwork.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,pushwoosh.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,rime.im,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,servebom.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,sfx.ms,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,shadowsocks.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,sharethis.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,shazam.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,skype.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,smartdnsproxy.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,smartmailcloud.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,sndcdn.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,sony.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,soundcloud.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,sourceforge.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,spotify.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,squarespace.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,sstatic.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,st.luluku.pw,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,stackoverflow.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,startpage.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,staticflickr.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,steamcommunity.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,symauth.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,symcb.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,symcd.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,tapbots.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,tapbots.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,tdesktop.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,techcrunch.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,techsmith.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,thepiratebay.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,theverge.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,time.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,timeinc.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,tiny.cc,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,tinypic.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,tmblr.co,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,todoist.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,trello.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,trustasiassl.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,tumblr.co,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,tumblr.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,tweetdeck.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,tweetmarker.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,twitch.tv,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,txmblr.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,typekit.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ubertags.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ublock.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ubnt.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ulyssesapp.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,urchin.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,usertrust.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,v.gd,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,v2ex.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,vimeo.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,vimeocdn.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,vine.co,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,vivaldi.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,vox-cdn.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,vsco.co,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,vultr.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,w.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,w3schools.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,webtype.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,wikiwand.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,wikileaks.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,wikimedia.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,wikipedia.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,wikipedia.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,windows.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,windows.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,wire.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,wordpress.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,workflowy.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,wp.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,wsj.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,wsj.net,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,xda-developers.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,xeeno.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,xiti.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,yahoo.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,yimg.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ying.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,yoyo.org,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,ytimg.com,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,telegra.ph,Candytally（糖果云）'
    - 'DOMAIN-SUFFIX,telegram.org,Candytally（糖果云）'
    - 'IP-CIDR,91.108.4.0/22,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,91.108.8.0/21,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,91.108.16.0/22,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,91.108.56.0/22,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,149.154.160.0/20,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR6,2001:67c:4e8::/48,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR6,2001:b28:f23d::/48,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR6,2001:b28:f23f::/48,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,120.232.181.162/32,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,120.241.147.226/32,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,120.253.253.226/32,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,120.253.255.162/32,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,120.253.255.34/32,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,120.253.255.98/32,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,180.163.150.162/32,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,180.163.150.34/32,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,180.163.151.162/32,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,180.163.151.34/32,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,203.208.39.0/24,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,203.208.40.0/24,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,203.208.41.0/24,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,203.208.43.0/24,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,203.208.50.0/24,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,220.181.174.162/32,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,220.181.174.226/32,Candytally（糖果云）,no-resolve'
    - 'IP-CIDR,220.181.174.34/32,Candytally（糖果云）,no-resolve'
    - 'DOMAIN,injections.adguard.org,DIRECT'
    - 'DOMAIN,local.adguard.org,DIRECT'
    - 'DOMAIN-SUFFIX,local,DIRECT'
    - 'IP-CIDR,127.0.0.0/8,DIRECT'
    - 'IP-CIDR,172.16.0.0/12,DIRECT'
    - 'IP-CIDR,192.168.0.0/16,DIRECT'
    - 'IP-CIDR,10.0.0.0/8,DIRECT'
    - 'IP-CIDR,17.0.0.0/8,DIRECT'
    - 'IP-CIDR,100.64.0.0/10,DIRECT'
    - 'IP-CIDR,224.0.0.0/4,DIRECT'
    - 'IP-CIDR6,fe80::/10,DIRECT'
    - 'DOMAIN-SUFFIX,cn,DIRECT'
    - 'DOMAIN-KEYWORD,-cn,DIRECT'
    - 'GEOIP,CN,DIRECT'
    - 'MATCH,Candytally（糖果云）'
XRL_BUILTIN_RULES_EOF
}

rules_extract_key() { # $1=yaml文件 $2=顶层键名 -> 输出该顶层键的完整段
  awk -v key="$2" '
    $0 ~ "^" key ":" { inp=1; print; next }
    inp && /^[A-Za-z][A-Za-z0-9_-]*:/ { exit }
    inp { print }
  ' "$1"
}

rules_transform() { # $1=代理流量目标组名; stdin=原始规则行 -> stdout=重映射后的规则行
  awk -v grp="$1" -v q="'" '
    {
      s=$0
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      sub(/^- /, "", s)
      if (substr(s,1,1)==q && substr(s,length(s),1)==q) s=substr(s,2,length(s)-2)
      if (s == "") next
      n=split(s, p, ",")
      last=p[n]; gsub(/^[ \t]+|[ \t]+$/, "", last)
      tail=""
      if (tolower(last)=="no-resolve") { tgt=p[n-1]; tail=",no-resolve"; ti=n-1 } else { tgt=last; ti=n }
      gsub(/^[ \t]+|[ \t]+$/, "", tgt)
      u=toupper(tgt)
      if (u!="DIRECT" && u!="REJECT" && u!="REJECT-DROP" && u!="COMPATIBLE" && u!="PASS" && u!="GLOBAL") tgt=grp
      out=""
      for (i=1;i<ti;i++) out=out p[i] ","
      out=out tgt tail
      print "  - " q out q
    }
  '
}

# 国内 DoH, 与 argosbx 自带的 proxy-server-nameserver 相同
RULES_CN_DNS=("https://223.5.5.5/dns-query" "https://doh.pub/dns-query")

rules_patch_dns() { # $1=clmi.yaml; 在 dns 段末尾插入/刷新 xrelay-dns 标记块
  # 背景: argosbx 的 dns 只配了境外 DoH(1.1.1.1/8.8.8.8)且 respect-rules: true, DNS 查询本身走代理出海,
  # 国内域名会被解析到落地机附近的海外 CDN 节点, 规则虽判定直连, 实际却跨境直连海外节点 -> 国内网站/图片极慢或加载失败.
  # 修正: geosite:cn 与内网域名改用国内 DNS(nameserver-policy); 走 DIRECT 的连接一律用国内 DNS 解析(direct-nameserver)
  local f=$1 tmp ind has_policy has_direct blk s
  if grep -q '# >>> xrelay-dns >>>' "$f"; then
    tmp=$(mktemp)
    sed -e '/# >>> xrelay-dns >>>/,/# <<< xrelay-dns <<</d' "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
  fi
  grep -q '^dns:[[:space:]]*$' "$f" || { warn "$f 中没有(块格式的) dns 段, 跳过 DNS 修正"; return 1; }
  # 沿用 dns 段原有缩进, 避免缩进混用导致 YAML 解析错误
  ind=$(awk '/^dns:[[:space:]]*$/{p=1;next} p&&/^[^[:space:]#]/{exit}
             p&&/^[[:space:]]+[^[:space:]#]/{match($0,/^[[:space:]]+/); print substr($0,1,RLENGTH); exit}' "$f")
  [[ -n $ind ]] || ind="  "
  has_policy=$(awk -v k="${ind}nameserver-policy:" '/^dns:/{p=1;next} p&&/^[^[:space:]#]/{exit} p&&index($0,k)==1{print "y";exit}' "$f")
  has_direct=$(awk -v k="${ind}direct-nameserver:" '/^dns:/{p=1;next} p&&/^[^[:space:]#]/{exit} p&&index($0,k)==1{print "y";exit}' "$f")
  [[ -n $has_policy ]] && warn "dns 段已有 nameserver-policy, 未自动添加 geosite:cn 国内解析(请自行确认国内域名用国内 DNS)"
  [[ -n $has_direct ]] && warn "dns 段已有 direct-nameserver, 保留原设置"
  [[ -n $has_policy && -n $has_direct ]] && return 1
  blk=$(mktemp)
  {
    printf '%s# >>> xrelay-dns >>>\n' "$ind"
    if [[ -z $has_policy ]]; then
      printf '%snameserver-policy:\n%s%s"geosite:cn,private":\n' "$ind" "$ind" "$ind"
      for s in "${RULES_CN_DNS[@]}"; do printf '%s%s%s- "%s"\n' "$ind" "$ind" "$ind" "$s"; done
    fi
    if [[ -z $has_direct ]]; then
      printf '%sdirect-nameserver:\n' "$ind"
      for s in "${RULES_CN_DNS[@]}"; do printf '%s%s- "%s"\n' "$ind" "$ind" "$s"; done
    fi
    printf '%s# <<< xrelay-dns <<<\n' "$ind"
  } > "$blk"
  tmp=$(mktemp)
  awk -v blk="$blk" '
    function dump(  l){ while ((getline l < blk) > 0) print l; close(blk) }
    !done && /^dns:[[:space:]]*$/ { indns=1; print; next }
    indns {
      if ($0 ~ /^[[:space:]]*$/) { pend = pend $0 "\n"; next }   # dns 段尾部空行留到块后面
      if ($0 ~ /^[^[:space:]#]/) { dump(); printf "%s", pend; pend=""; indns=0; done=1; print; next }
      if (pend != "") { printf "%s", pend; pend="" }
      print; next
    }
    { print }
    END { if (indns) { dump(); printf "%s", pend } }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp" "$blk"
  return 0
}

do_rules() {
  banner "模式: 补充分流规则 (rules)"
  ensure_root
  [[ ${RESET:-} == y ]] || load_env_file "$(xrel_dir)/rules.env"
  if [[ -z ${RULESFILE:-} && -t 0 ]]; then
    printf '  规则来源文件(路径或URL, 直接回车使用内置规则集): '
    read -r RULESFILE || RULESFILE=""
  fi
  GROUP=${GROUP:-🌍选择代理节点}
  AGS_DIR=${AGS_DIR:-$HOME/agsbx}
  local tmpd; tmpd=$(mktemp -d)
  if dry && [[ -d $AGS_DIR ]]; then
    rm -rf "$DRYDIR/agsbx-sim"
    cp -a "$AGS_DIR" "$DRYDIR/agsbx-sim"
    AGS_DIR="$DRYDIR/agsbx-sim"
    info "DRYRUN: 订阅文件操作在副本上进行: $AGS_DIR"
  fi
  local target="$AGS_DIR/clmi.yaml"
  [[ -f $target ]] || die "未找到 $target (先部署 argosbx 并开启订阅, 或用 AGS_DIR= 指定)"
  local src="" src_label="内置规则集"
  if [[ -n ${RULESFILE:-} ]]; then
    src="$tmpd/src.yaml"; src_label="$RULESFILE"
    case $RULESFILE in
      http://*|https://*|file://*) mirror_fetch "$RULESFILE" > "$src" || true ;;
      *) if [[ -f $RULESFILE ]]; then cp "$RULESFILE" "$src"; else die "规则文件不存在: $RULESFILE"; fi ;;
    esac
    [[ -s $src ]] || die "无法读取规则来源: $RULESFILE"
    sed -i 's/\r$//' "$src" 2>/dev/null || true
    rules_extract_key "$src" rules > "$tmpd/rules.raw0"
    tail -n +2 "$tmpd/rules.raw0" > "$tmpd/rules.raw"
  else
    info "使用内置规则集"
    rules_builtin > "$tmpd/rules.raw"
  fi
  local n; n=$(grep -c . "$tmpd/rules.raw" || true)
  ((n)) || die "规则来源里没有找到 rules 内容"
  rules_transform "$GROUP" < "$tmpd/rules.raw" > "$tmpd/rules.new"
  local n2; n2=$(grep -c . "$tmpd/rules.new" || true)
  ((n2)) || die "规则转换结果为空, 请检查规则文件格式"
  [[ -f $target.xrelay-orig ]] || cp -a "$target" "$target.xrelay-orig"
  if [[ ! -f $target.rules-orig ]]; then
    rules_extract_key "$target" rules > "$target.rules-orig"
  fi
  # 清理上一次插入的 rule-providers / sub-rules 块
  if grep -q 'xrelay-ruleproviders' "$target"; then
    local ctmp; ctmp=$(mktemp)
    sed -e '/# >>> xrelay-ruleproviders >>>/,/# <<< xrelay-ruleproviders <<</d' "$target" > "$ctmp" && cat "$ctmp" > "$target"
    rm -f "$ctmp"
  fi
  local dnsfix=""
  rules_patch_dns "$target" && dnsfix=y
  {
    awk '/^rules:/{exit} {print}' "$target"
    local prov="" subr=""
    if [[ -n $src ]]; then
      prov=$(rules_extract_key "$src" rule-providers)
      subr=$(rules_extract_key "$src" sub-rules)
    fi
    if [[ -n $prov ]]; then
      printf '# >>> xrelay-ruleproviders >>>\n'
      printf '%s\n' "$prov"
      printf '# <<< xrelay-ruleproviders <<<\n'
    fi
    if [[ -n $subr ]]; then
      printf '# >>> xrelay-ruleproviders >>>\n'
      printf '%s\n' "$subr"
      printf '# <<< xrelay-ruleproviders <<<\n'
    fi
    printf 'rules:\n'
    # 首条若是需要 IP 的规则(无 no-resolve), 每个域名都要先等本地 DNS 才能继续匹配, 拖慢所有新连接;
    # 内网"域名"由规则集末尾的私有网段 IP-CIDR 兜底
    printf "  - 'GEOIP,LAN,DIRECT,no-resolve'\n"
    printf "  - 'GEOSITE,CN,DIRECT'\n"
    printf '  # >>> xrelay-rules >>>\n'
    cat "$tmpd/rules.new"
    printf '  # <<< xrelay-rules <<<\n'
  } > "$tmpd/newclmi"
  cat "$tmpd/newclmi" > "$target"
  local cnt_proxy cnt_direct cnt_reject
  cnt_proxy=$(grep -cF ",$GROUP'" "$tmpd/rules.new" || true)
  cnt_direct=$(grep -cF ",DIRECT'" "$tmpd/rules.new" || true)
  cnt_reject=$(grep -cF ",REJECT'" "$tmpd/rules.new" || true)
  cnt_reject=$((cnt_reject + $(grep -cF ",REJECT-DROP'" "$tmpd/rules.new" || true)))
  ok "已应用 $n2 条规则($src_label)到 $target"
  log "  走代理组($GROUP): $cnt_proxy 条   直连: $cnt_direct 条   拒绝: $cnt_reject 条"
  [[ -n $prov ]] && log "  已附带 rule-providers 规则集"
  [[ -n $dnsfix ]] && ok "已修正 DNS: 国内域名与直连流量改用国内 DNS 解析(${RULES_CN_DNS[*]}), 避免被解析到海外 CDN 节点"
  info "客户端重新拉取订阅即可生效"
  save_env_file "$(xrel_dir)/rules.env" \
    "$(kv DATE "$(date '+%F %T')")" \
    "$(kv RULESFILE "$RULESFILE")" "$(kv GROUP "$GROUP")" "$(kv AGS_DIR "$AGS_DIR")"
  rm -rf "$tmpd"
  ok "原始规则已备份到 $target.rules-orig, 卸载时会自动恢复"
}

do_menu_rules() {
  log " 用内置或外部订阅的规则段, 补充/替换本机订阅的分流规则:"
  askv GROUP "规则里代理流量的目标组名(需是本机订阅已有的组)" "🌍选择代理节点"
  do_rules
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
  if [[ -f "$d/mirror.env" ]]; then
    found=1
    log "${C_BOLD}---- mirror (跟随落地订阅) ----${C_RESET}"
    (
      unset DATE SUBURL BASE UDP PREFIX INCLUDE AGS_DIR
      load_env_file "$d/mirror.env"
      log "  落地订阅 : ${SUBURL:-?}"
      log "  端口基数 : ${BASE:-42000}   UDP镜像: ${UDP:-y}   前缀: ${PREFIX:-中转-}"
      if [[ -f "$d/mirror.ports" ]]; then
        while IFS='|' read -r k p; do
          [[ -n ${k:-} ]] && log "    本机端口 $p  ->  $k"
        done < "$d/mirror.ports"
      fi
    )
    log ""
  fi
  if [[ -f "$d/rules.env" ]]; then
    found=1
    log "${C_BOLD}---- rules (补充规则) ----${C_RESET}"
    (
      unset DATE RULESFILE GROUP AGS_DIR
      load_env_file "$d/rules.env"
      log "  规则来源 : ${RULESFILE:-?}"
      log "  代理组   : ${GROUP:-🌍选择代理节点}"
    )
    log ""
  fi
  ((found)) || info "未发现本脚本的部署记录 (landing / relay / realm / mirror / rules)"
  if ! dry; then
    local s st
    if have_bin systemctl; then
      for s in xray realm; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^$s.service"; then
          st=$(systemctl is-active "$s" 2>/dev/null) || true
          log "  服务 $s: ${st:-unknown}"
        fi
      done
    fi
    if have_bin rc-service && [[ -f $REALM_INIT ]]; then
      st=$(rc-service realm status 2>&1 | head -n1) || true
      log "  服务 realm(OpenRC): ${st:-unknown}"
    fi
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
    if [[ -f $REALM_INIT ]]; then
      rc-service realm stop >/dev/null 2>&1 || true
      rc-update del realm default >/dev/null 2>&1 || true
      rm -f "$REALM_INIT"
      ok "已停止并移除 realm 服务 (OpenRC)"
    fi
    if [[ -f $REALM_UNIT ]]; then
      systemctl stop realm 2>/dev/null || true
      systemctl disable realm 2>/dev/null || true
      rm -f "$REALM_UNIT"
      systemctl daemon-reload 2>/dev/null || true
      ok "已停止并移除 realm 服务 (systemd)"
    fi
    pkill -f 'realm -c' >/dev/null 2>&1 || true
    if have_bin crontab && crontab -l 2>/dev/null | grep -q 'xrelay-realm'; then
      { crontab -l 2>/dev/null | grep -v 'xrelay-realm' || true; } | crontab - 2>/dev/null || true
      ok "已清理 realm 开机自启 (crontab)"
    fi
  else
    printf '  [DRYRUN] 停止服务 / 移除配置\n'
  fi
  if ! dry; then
    (
      unset AGS_DIR PREFIX
      [[ -f "$(xrel_dir)/mirror.env" ]] && load_env_file "$(xrel_dir)/mirror.env"
      [[ -f "$(xrel_dir)/rules.env" ]] && load_env_file "$(xrel_dir)/rules.env"
      mirror_clean_subfiles "${AGS_DIR:-$HOME/agsbx}" "${PREFIX:-中转-}" "$(xrel_dir)"
    ) || true
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
  mirror     跟随落地机订阅, 把落地节点批量镜像到本机并更新本机订阅
  rules      用内置或外部订阅的规则段, 补充/替换本机订阅的分流规则
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

mirror 模式参数 (落地机用 argosbx 部署并开了订阅时使用):
  SUBURL=...        落地机订阅地址, 粘贴 clmi.yaml / jhsub.txt / sbox.json 任意一条  [必填]
  BASE=42000        本机镜像端口起始值(从该值向后自动分配)
  UDP=y             同时镜像 hy2 / tuic 等 UDP 节点(默认 y, 纯 TCP 环境可设 n)
  PREFIX=中转-      镜像节点名前缀
  INCLUDE=reality   只镜像名称匹配该正则的节点(可选)
  AGS_DIR=/root/agsbx   argosbx 目录(默认自动检测)
  PYTHON=python3    指定 python 解释器(更新 sbox.json 用, 可选)

rules 模式参数 (用其他订阅的规则段强化本机订阅):
  RULESFILE=...     规则来源, 支持本机路径或 URL; 不填则使用脚本内置的增强规则集
  GROUP=🌍选择代理节点  规则里原本指向机场代理组的流量, 改指向本机订阅里的这个组
  AGS_DIR=/root/agsbx   argosbx 目录(默认自动检测)
  (同时会修正订阅的 DNS: 国内域名/直连流量改用国内 DNS 解析, 解决国内网站/图片慢或加载不出)

示例:
  落地机:  bash xrelay.sh landing LPORT=443 LSNI=aws.amazon.com NAME=落地
  中转机:  bash xrelay.sh relay LADDR=1.2.3.4 LPORT=443 LUUID=xx LSNI=xx LPBK=xx LSID=xx
  中转机:  bash xrelay.sh realm LADDR=1.2.3.4 LPORT=443 RPORT=8443
  中转机:  bash xrelay.sh mirror SUBURL=http://1.2.3.4:35948/123
  中转机:  bash xrelay.sh rules     (零参数使用内置规则集; 也可 RULESFILE=路径或URL)

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
  log " 4) 跟随落地订阅镜像  (argosbx 双机用户推荐, 批量中转)"
  log " 5) 补充分流规则  (用机场等现成配置的 rules 段强化订阅)"
  log " 6) 查看已部署信息 / 节点链接"
  log " 7) 卸载"
  log " 0) 退出"
  log ""
  printf ' 请选择 [0-7]: '
  local c; read -r c || c=""
  case $c in
    1) do_landing ;;
    2) do_menu_relay ;;
    3) do_menu_realm ;;
    4) do_menu_mirror ;;
    5) do_menu_rules ;;
    6) do_info ;;
    7) do_uninstall ;;
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
  mkdir -p "$DRYDIR" 2>/dev/null || true
  case "$MODE" in
    landing)   self_install; do_landing ;;
    relay)     self_install; do_relay ;;
    realm)     self_install; do_realm ;;
    mirror)    self_install; do_mirror ;;
    rules)     self_install; do_rules ;;
    info)      self_install; do_info ;;
    uninstall) self_install; do_uninstall ;;
    help)      do_help ;;
    menu)      self_install; do_menu ;;
    *) die "未知命令: $MODE  (可用: landing / relay / realm / mirror / rules / info / uninstall / help / menu)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
