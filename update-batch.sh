#!/bin/bash
set -e

# ================== 系统变量 ==================
STORAGE="a1sys"									# PVE 存储池名称
TEMPLATE_DIR="/a1sys/template/cache"					# PVE 模板目录
BACKUP_DIR="/a1sys/A0script/00lxc_backup"				# 配置文件备份目录

# ================== 容器分配 ==================
CORES="32"										# 分配线程
MEMORY="10240"										# 内存
SWAP="0"											# 缓存分配
ROOTFS="$STORAGE:1"									# 容器分配大小（因为lxc采用的是raw格式）

# ================== 配置变量 ==================
# 定义容器列表：ID|名称
CONTAINERS=(
    "130|30qbittorrent-bt"
    "131|31qbittorrent-bt"
)

IMAGE_NAME="lscr.io/linuxserver/qbittorrent:latest"
LOG_FILE="/var/log/qbittorrent-batch.log"              # 主日志文件

# ================== 日志函数 ==================
log_info() {
    echo "=== $1 ===" | tee -a "$LOG_FILE"
}

log_success() {
    echo "✓ $1" | tee -a "$LOG_FILE"
}

log_action() {
    echo "↓ $1..." | tee -a "$LOG_FILE"
}

log_error() {
    echo "✗ 错误: $1" | tee -a "$LOG_FILE" >&2
}

# ================== 检查镜像更新 ==================
check_image_update() {
    log_info "检查镜像更新: $IMAGE_NAME"

    # 获取本地镜像 Digest
    LOCAL_DIGEST=""
    if podman image exists "$IMAGE_NAME"; then
        LOCAL_DIGEST=$(podman image inspect "$IMAGE_NAME" --format '{{.Digest}}' 2>/dev/null || echo "")
    fi
    log_action "本地镜像Digest: ${LOCAL_DIGEST:0:19}..."

    # 拉取最新镜像
    podman pull "$IMAGE_NAME" || log_error "拉取镜像失败"

    # 获取新镜像 Digest
    NEW_DIGEST=$(podman image inspect "$IMAGE_NAME" --format '{{.Digest}}' 2>/dev/null || echo "")
    log_action "新镜像Digest: ${NEW_DIGEST:0:19}..."

    # 比较 Digest
    if [ -n "$LOCAL_DIGEST" ] && [ "$LOCAL_DIGEST" = "$NEW_DIGEST" ]; then
        log_success "镜像已是最新版本，无需更新"
        return 1  # 无需更新
    fi
    log_success "发现新版本，开始更新"
    return 0  # 需要更新
}

# ================== 导出模板 ==================
export_template() {
    log_info "导出镜像为 OCI 模板"
    mkdir -p "$TEMPLATE_DIR"

    TEMPLATE_NAME=$(echo "$IMAGE_NAME" | sed 's/\//_/g' | sed 's/:/_/g').tar
    TEMPLATE_PATH="$TEMPLATE_DIR/$TEMPLATE_NAME"

    # 如果模板已存在且今天创建过，跳过导出（复用）
    if [ -f "$TEMPLATE_PATH" ] && [ "$(date -r "$TEMPLATE_PATH" +%Y%m%d)" = "$(date +%Y%m%d)" ]; then
        log_success "模板已存在且是今天创建的，跳过导出: $TEMPLATE_PATH"
        return 0
    fi

    log_action "导出镜像到: $TEMPLATE_PATH"
    podman save --format=oci-archive -o "$TEMPLATE_PATH" "$IMAGE_NAME" || log_error "导出镜像失败"
    log_success "模板已导出（大小: $(du -h "$TEMPLATE_PATH" | cut -f1)）"
}

# ================== 更新单个容器 ==================
update_container() {
    local CT_ID=$1
    local CT_NAME=$2
    local TEMPLATE_PATH=$3
    local CONTAINER_LOG="/var/log/${CT_NAME}.log"

    log_info "开始更新容器: $CT_ID ($CT_NAME)"

    # 检查容器是否存在
    if ! pct status $CT_ID &>/dev/null; then
        log_error "容器 $CT_ID 不存在，跳过"
        return 1
    fi

    # ----- 备份配置 -----
    mkdir -p "$BACKUP_DIR"
    CONF_PATH="/etc/pve/lxc/${CT_ID}.conf"
    CONF_BAK="$BACKUP_DIR/${CT_ID}.conf.$(date +%Y%m%d_%H%M%S)"
    
    log_action "备份配置文件到: $CONF_BAK"
    cp "$CONF_PATH" "$CONF_BAK" || { log_error "备份配置文件失败"; return 1; }

    # ----- 停止并删除容器 -----
    log_action "停止容器 $CT_ID"
    pct stop $CT_ID 2>/dev/null || true
    sleep 3

    log_action "删除容器 $CT_ID"
    pct destroy $CT_ID 2>/dev/null || { log_error "删除容器失败"; return 1; }

    # ----- 重建容器 -----
    log_action "创建新容器 $CT_ID"
    pct create "$CT_ID" "$TEMPLATE_PATH" --cores $CORES --memory $MEMORY --swap $SWAP \
        --rootfs $ROOTFS --storage $STORAGE || { log_error "创建容器失败"; return 1; }

    log_action "恢复配置文件"
    cp "$CONF_BAK" "$CONF_PATH" || { log_error "恢复配置文件失败"; return 1; }

    log_action "启动容器 $CT_ID"
    pct start $CT_ID || { log_error "启动容器失败"; return 1; }

    # ----- 记录完成 -----
    log_success "容器 $CT_ID ($CT_NAME) 更新完成"
    echo "  配置备份: $CONF_BAK" | tee -a "$LOG_FILE"
    
    # 显示容器状态
    sleep 2
    log_info "容器状态"
    pct status $CT_ID | tee -a "$LOG_FILE"
    echo ""
    
    return 0
}

# ================== 主流程 ==================
main() {
    log_info "========== qBittorrent 批量更新开始 =========="
    
    # 第一步：检查镜像更新
    if ! check_image_update; then
        log_success "没有新镜像，所有容器无需更新"
        exit 0
    fi

    # 第二步：导出模板（只导出一次）
    export_template
    TEMPLATE_NAME=$(echo "$IMAGE_NAME" | sed 's/\//_/g' | sed 's/:/_/g').tar
    TEMPLATE_PATH="$TEMPLATE_DIR/$TEMPLATE_NAME"

    # 第三步：遍历更新所有容器
    local success_count=0
    local fail_count=0
    
    for container in "${CONTAINERS[@]}"; do
        CT_ID=$(echo "$container" | cut -d'|' -f1)
        CT_NAME=$(echo "$container" | cut -d'|' -f2)
        
        echo ""
        log_info "---------- 处理容器 $CT_ID ($CT_NAME) ----------"
        if update_container "$CT_ID" "$CT_NAME" "$TEMPLATE_PATH"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done

    # ----- 完成 -----
    echo ""
    log_info "========== 所有容器更新完成 =========="
    echo ""
    echo "  总容器数: ${#CONTAINERS[@]}"
    echo "  成功: $success_count"
    echo "  失败: $fail_count"
    echo "  镜像: $IMAGE_NAME"
    echo "  模板: $TEMPLATE_PATH"
    echo "  日志: $LOG_FILE"
}

# 执行主流程
main