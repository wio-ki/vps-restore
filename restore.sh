#!/bin/bash
# restore.sh - 迁移后一键复机脚本
#
# 使用方式（在新 VPS 上）：
#   mkdir -p /data_back
#   cd /data_back
#   # 将 backup.tar.gz / crontab.md / backup.log / cron.log 放入此目录
#   tar -xzf backup.tar.gz scripts/restore.sh   # 仅提取此脚本
#   bash scripts/restore.sh
#
# 系统要求：Debian 12，root 身份运行

BASE_DIR="/data_back"
LOG="$BASE_DIR/restore.log"
SSH_PORT=61392
ACME_EMAIL="admin@vvkoi.com"   # 若邮箱不对，修改此处后重跑 Step 5

RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ── 工具函数 ────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
info() { log "✓ $*"; }
warn() { log "⚠ $*"; }
die()  { log "✗ FATAL: $*"; exit 1; }

step() {
  log ""
  log "════════════════════════════════════════"
  log "  $*"
  log "════════════════════════════════════════"
}

# ── Step 0: 预检 ─────────────────────────────────────────
step "Step 0: 预检"

[ "$(id -u)" = "0" ] || die "必须以 root 身份运行：sudo bash scripts/restore.sh"
[ -f "$BASE_DIR/backup.tar.gz" ]  || die "找不到 $BASE_DIR/backup.tar.gz，请先将四个备份文件放入该目录"
[ -f "$BASE_DIR/crontab.md" ]     || die "找不到 $BASE_DIR/crontab.md，请先将四个备份文件放入该目录"

info "预检通过，日志输出到 $LOG"
info "开始复机..."

# ── Step 1: 安装基础软件包 ───────────────────────────────
step "Step 1: 安装基础软件包"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl wget tar gzip jq python3 python3-pip nginx socat cron 2>&1 | tee -a "$LOG"
info "基础软件包安装完成"

# ── Step 2: 系统基础配置 ─────────────────────────────────
step "Step 2: 系统基础配置（SSH / 时区 / BBR / IPv6 / Swap）"

# 2.1 SSH 端口
sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
systemctl restart sshd
info "SSH 端口已设为 $SSH_PORT（请立即在安全组开放此端口！）"

# 2.2 时区
timedatectl set-timezone Asia/Shanghai
info "时区已设为 Asia/Shanghai"

# 2.3 BBR + fq
cat > /etc/sysctl.d/99-bbr.conf <<'SYSCTL_BBR'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL_BBR
sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null
info "BBR + fq 已启用：$(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"

# 2.4 禁用 IPv6（与原 VPS 保持一致）
cat > /etc/sysctl.d/50-IPv6.conf <<'SYSCTL_IPV6'
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.default.autoconf = 0
SYSCTL_IPV6
sysctl -p /etc/sysctl.d/50-IPv6.conf >/dev/null
info "IPv6 RA/autoconf 已禁用"

# 2.5 内核调优参数
cat > /etc/sysctl.d/99-sysctl.conf <<'SYSCTL_TUNE'
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
kernel.watchdog_thresh = 20
SYSCTL_TUNE
sysctl -p /etc/sysctl.d/99-sysctl.conf >/dev/null
info "内核调优参数已设置（swappiness=10 / dirty_ratio=10）"

# 2.6 动态 Swap
if swapon --show --noheadings 2>/dev/null | grep -q .; then
  warn "Swap 已存在，跳过：$(swapon --show --noheadings | head -1)"
else
  MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
  if [ "$MEM_MB" -lt 1024 ]; then
    SWAP_MB=$((MEM_MB * 2))
    log "内存 ${MEM_MB}MB < 1GB → 开启 2 倍 Swap = ${SWAP_MB}MB"
  else
    SWAP_MB=$MEM_MB
    log "内存 ${MEM_MB}MB >= 1GB → 开启 1 倍 Swap = ${SWAP_MB}MB"
  fi
  fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null || \
    dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  info "Swap 已创建并持久化：${SWAP_MB}MB"
fi

# ── Step 3: 安装 Docker ──────────────────────────────────
step "Step 3: 安装 Docker"

if command -v docker &>/dev/null; then
  warn "Docker 已安装 ($(docker --version))，跳过"
else
  curl -fsSL https://get.docker.com | sh 2>&1 | tee -a "$LOG"
  systemctl enable --now docker
  info "Docker 安装完成"
fi

# ── Step 4: 安装 code-server ─────────────────────────────
step "Step 4: 安装 code-server"

if command -v code-server &>/dev/null; then
  warn "code-server 已安装 ($(code-server --version 2>/dev/null | head -1))，跳过"
else
  curl -fsSL https://code-server.dev/install.sh | sh 2>&1 | tee -a "$LOG"
  info "code-server 安装完成"
fi

# ── Step 5: 安装 acme.sh ─────────────────────────────────
step "Step 5: 安装 acme.sh（SSL 证书管理）"

if [ -f "/root/.acme.sh/acme.sh" ]; then
  warn "acme.sh 已安装，跳过"
else
  curl -fsSL https://get.acme.sh | sh -s "email=${ACME_EMAIL}" 2>&1 | tee -a "$LOG"
  info "acme.sh 安装完成（证书申请为手动步骤，见最后红字提醒）"
fi

# ── Step 6: 解压备份 ─────────────────────────────────────
step "Step 6: 解压备份 backup.tar.gz"

cd "$BASE_DIR"
tar -xzf "$BASE_DIR/backup.tar.gz" -C "$BASE_DIR" 2>&1 | tee -a "$LOG"
info "解压完成"
ls -la "$BASE_DIR" | tee -a "$LOG"

# ── Step 7: 创建必要目录 ─────────────────────────────────
step "Step 7: 创建必要目录"

mkdir -p "$BASE_DIR/nginx/logs"
mkdir -p /root/.config/code-server
mkdir -p /root/.local/share
# $BASE_DIR 即 agents-a2b7ddaa7a，是 link.md 里所有路径使用的固定基础目录（真实目录，无需软链接）
info "必要目录创建完成（$BASE_DIR）"

# ── Step 8: 建立软链接（从 link.md 读取） ────────────────
step "Step 8: 建立软链接（读取 tab/link.md）"

LINK_MD="$BASE_DIR/tab/link.md"
if [ ! -f "$LINK_MD" ]; then
  warn "找不到 $LINK_MD，跳过 link.md 软链接"
else
  info "读取 $LINK_MD，逐条创建软链接..."
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" == ln\ -sf\ * ]] || continue

    TARGET=$(echo "$line" | awk '{print $3}')
    LINK=$(echo "$line" | awk '{print $4}')
    [ -z "$TARGET" ] || [ -z "$LINK" ] && continue

    if [ ! -e "$TARGET" ]; then
      warn "目标不存在，跳过: $TARGET"
      warn "  ↳ 软链接未创建: $LINK"
      continue
    fi

    mkdir -p "$(dirname "$LINK")"
    rm -rf "$LINK"
    ln -sf "$TARGET" "$LINK"
    info "软链接: $LINK → $TARGET"
  done < "$LINK_MD"
fi

# 关键软链接兜底：/etc/nginx/nginx.conf（link.md 路径有误时自动修复）
if { [ ! -L /etc/nginx/nginx.conf ] || [ ! -e /etc/nginx/nginx.conf ]; } && \
   [ -f "$BASE_DIR/nginx/nginx.conf" ]; then
  ln -sf "$BASE_DIR/nginx/nginx.conf" /etc/nginx/nginx.conf
  warn "link.md 中 nginx.conf 路径有误，已用正确路径兜底修复"
  warn "  建议修正 link.md 中第5条: $BASE_DIR/nginx/nginx.conf → /etc/nginx/nginx.conf"
fi

# ── Step 9: 配置 nginx ───────────────────────────────────
step "Step 9: 配置 nginx"

if nginx -t 2>&1 | tee -a "$LOG"; then
  systemctl enable nginx
  systemctl start nginx 2>/dev/null || systemctl reload nginx 2>/dev/null || true
  info "nginx 已启动"
else
  warn "nginx 配置测试失败，请手动检查后执行：nginx -t && systemctl reload nginx"
fi

# ── Step 10: 创建 Docker 网络 ────────────────────────────
step "Step 10: 创建 Docker 网络"

for net in ai-shared-net emby-stack lobe-internal om-internal; do
  if docker network ls --format '{{.Name}}' | grep -q "^${net}$"; then
    warn "网络 $net 已存在，跳过"
  else
    docker network create "$net" && info "已创建网络: $net" || warn "创建网络 $net 失败"
  fi
done

# ── Step 11: 启动 Docker 容器 ────────────────────────────
step "Step 11: 启动 Docker 容器（按依赖顺序）"

start_compose() {
  local dir="$1"
  local name="${2:-$(basename "$dir")}"

  if [ ! -f "$dir/docker-compose.yml" ] && [ ! -f "$dir/docker-compose.yaml" ]; then
    warn "$name: 无 docker-compose.yml，跳过"
    return 0
  fi

  log "→ 启动 $name ($dir)"
  (cd "$dir" && docker compose up -d 2>&1 | tee -a "$LOG") \
    && info "$name 启动成功" \
    || warn "$name 启动失败（手动：cd $dir && docker compose up -d）"
}

COMPOSE="$BASE_DIR/compose"

# 第一优先级：数据库（其他服务依赖 ai-shared-net 等网络）
start_compose "$COMPOSE/SQL" "PostgreSQL+Redis"

# 动态发现并启动其余所有 compose 服务（watchtower 留最后）
mapfile -t AUTO_DIRS < <(
  find "$COMPOSE" "$BASE_DIR/code-server" -maxdepth 2 -name "docker-compose.yml" \
  | while read -r f; do dirname "$f"; done \
  | sort -u \
  | grep -v "^${COMPOSE}/SQL$" \
  | grep -vE ".*/watchtower$"
)
for dir in "${AUTO_DIRS[@]}"; do
  start_compose "$dir"
done

# 最后启动：Watchtower（等所有容器就绪后再开始监控）
start_compose "$COMPOSE/watchtower" "Watchtower"

# ── Step 12: 启动 code-server ────────────────────────────
step "Step 12: 启动 code-server"

# code-server deb 包自带 code-server@<user> 模板服务，直接启用 @root
if systemctl is-enabled --quiet "code-server@root" 2>/dev/null; then
  warn "code-server@root 已启用，仅重启"
  systemctl restart "code-server@root" \
    && info "code-server@root 重启成功" \
    || warn "code-server@root 重启失败：journalctl -u code-server@root -n 50"
else
  systemctl enable --now "code-server@root" \
    && info "code-server@root 已启用并启动" \
    || warn "code-server@root 启动失败：journalctl -u code-server@root -n 50"
fi

# ── Step 13: 恢复 crontab ────────────────────────────────
step "Step 13: 恢复 crontab"

CRON_CONTENT=$(awk '/^```$/{found=!found; next} found{print}' "$BASE_DIR/crontab.md")

if [ -z "$CRON_CONTENT" ] || echo "$CRON_CONTENT" | grep -q "^(空："; then
  warn "crontab 为空，跳过"
else
  echo "$CRON_CONTENT" | crontab -
  info "crontab 恢复成功，当前任务如下："
  crontab -l | tee -a "$LOG"
fi

# ── Step 14: 状态汇报 ────────────────────────────────────
step "Step 14: 复机完成 - 状态汇报"

log ""
log "=== Docker 容器状态 ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>&1 | tee -a "$LOG"

log ""
log "=== 软链接验证 ==="
ls -la /root/.claude /root/.claude.json /etc/nginx/nginx.conf \
  /root/.config/code-server/config.yaml /root/.local/share/code-server 2>/dev/null | tee -a "$LOG"

log ""
log "=== nginx 状态 ==="
systemctl status nginx --no-pager 2>&1 | tail -5 | tee -a "$LOG"

log ""
log "=== code-server 状态 ==="
systemctl status code-server@root --no-pager 2>&1 | tail -5 | tee -a "$LOG"

log ""
log "=== Swap 状态 ==="
free -h | tee -a "$LOG"
swapon --show | tee -a "$LOG"

log "  ✓ 复机完成！日志已保存至 $LOG"

# ── 红字手动提醒 ─────────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║  ⚠  以下事项需要手动完成（脚本无法自动处理）            ║${NC}"
echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"

echo ""
echo -e "${RED}${BOLD}【1】确认 SSH 端口（最高优先级，防止失联）${NC}"
echo -e "${RED}  SSH 已改为端口 $SSH_PORT${NC}"
echo -e "${RED}  ① 在云服务商控制台 → 安全组 → 开放 TCP $SSH_PORT${NC}"
echo -e "${RED}  ② 另开终端验证：ssh -p $SSH_PORT root@<新IP>${NC}"
echo -e "${RED}  ③ 确认登录成功后，再关闭本会话！${NC}"

echo ""
echo -e "${RED}${BOLD}【2】SSL 证书重新申请（acme.sh 已安装）${NC}"
echo -e "${RED}  备份中的旧证书可临时使用，但到期后需重新申请：${NC}"
echo -e "${RED}  /root/.acme.sh/acme.sh --register-account -m ${ACME_EMAIL}${NC}"
echo -e "${RED}  /root/.acme.sh/acme.sh --issue --dns dns_xxx \\${NC}"
echo -e "${RED}    -d '*.vvkoi.com' -d 'vvkoi.com' --keylength ec-256${NC}"
echo -e "${RED}  /root/.acme.sh/acme.sh --install-cert -d '*.vvkoi.com' \\${NC}"
echo -e "${RED}    --fullchain-file $BASE_DIR/nginx/ssl/vvkoi.com.fullchain.pem \\${NC}"
echo -e "${RED}    --key-file $BASE_DIR/nginx/ssl/vvkoi.com.key.pem \\${NC}"
echo -e "${RED}    --reloadcmd 'systemctl reload nginx'${NC}"

echo ""
echo -e "${RED}${BOLD}【3】CloudDrive2 重新挂载 115网盘${NC}"
echo -e "${RED}  访问 https://cd2.vvkoi.com → 重新登录 115 账号${NC}"
echo -e "${RED}  → 挂载到 $BASE_DIR/compose/emby-stack/CloudNAS/${NC}"

echo ""
echo -e "${RED}${BOLD}【4】MoviePilot / Emby 等服务账号${NC}"
echo -e "${RED}  - MoviePilot: https://moviepilot.vvkoi.com（PT站账号、TMDB Key 等）${NC}"
echo -e "${RED}  - Emby: https://emby.vvkoi.com（License 激活、媒体库扫描）${NC}"
echo -e "${RED}  - FastEmby: https://fastemby.vvkoi.com（License Key 填入）${NC}"

echo ""
echo -e "${RED}${BOLD}【5】哪吒监控 Agent（nezha-agent）${NC}"
echo -e "${RED}  在哪吒控制面板 → 新建服务器 → 按指引安装 nezha-agent${NC}"

echo ""
echo -e "${RED}${BOLD}【6】code-server 密码确认${NC}"
echo -e "${RED}  cat /root/.config/code-server/config.yaml${NC}"
echo -e "${RED}  如显示 changeme_please，请修改后重启：${NC}"
echo -e "${RED}  systemctl restart code-server@root${NC}"

echo ""
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
