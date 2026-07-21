#!/bin/bash
set -e

# ================== 系统变量 ==================
STORAGE="a1sys"                                  # PVE 存储池名称
TEMPLATE_DIR="/a1sys/template/cache"             # PVE 模板目录

# ================== 容器分配 ==================
CORES="32"                                       # 分配线程
MEMORY="10240"                                   # 内存
SWAP="0"                                         # 缓存分配
ROOTFS="$STORAGE:1"                              # 容器分配大小

# ================== 配置变量 ==================
CT_ID="165"                                      # LXC 容器 ID
IMAGE_NAME="ghcr.io/openlistteam/openlist-git:latest"  # 镜像名
CT_NAME="65openlist"                             # 容器名称（用于日志）

LOG_FILE="/var/log/$CT_NAME.log"                 # 日志文件

# ================== 日志函数 ==================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ 错误: $1" | tee -a "$LOG_FILE" >&2
    exit 1
}

log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ↓ $1..." | tee -a "$LOG_FILE"
}

# ================== 主流程 ==================
main() {
    log "========================================="
    log "开始部署容器: $CT_NAME"
    log "========================================="
    
    # 第一步：检查/拉取镜像
    log "第一步：检查镜像"
    
    if podman image exists "$IMAGE_NAME"; then
        log "本地镜像存在，检查更新..."
        
        # 获取本地镜像 Digest
        LOCAL_DIGEST=$(podman image inspect "$IMAGE_NAME" --format '{{.Digest}}' 2>/dev/null || echo "")
        log_action "本地镜像Digest: ${LOCAL_DIGEST:0:19}..."
        
        # 拉取最新镜像
        podman pull "$IMAGE_NAME" || log_error "拉取最新镜像失败"
        
        # 获取新镜像 Digest
        NEW_DIGEST=$(podman image inspect "$IMAGE_NAME" --format '{{.Digest}}' 2>/dev/null || echo "")
        log_action "新镜像Digest: ${NEW_DIGEST:0:19}..."
        
        # 比较 Digest
        if [ -n "$LOCAL_DIGEST" ] && [ "$LOCAL_DIGEST" = "$NEW_DIGEST" ]; then
            log_success "镜像已是最新版本，无需更新"
        else
            log_success "镜像已更新到最新版本"
        fi
    else
        log "本地镜像不存在，开始拉取..."
        podman pull "$IMAGE_NAME" || log_error "拉取镜像失败"
        log_success "镜像拉取完成"
    fi
    
    # 第二步：导出镜像为模板
    log "第二步：导出镜像为 OCI 模板"
    mkdir -p "$TEMPLATE_DIR"
    
    TEMPLATE_NAME=$(echo "$IMAGE_NAME" | sed 's/\//_/g' | sed 's/:/_/g').tar
    TEMPLATE_PATH="$TEMPLATE_DIR/$TEMPLATE_NAME"
    
    log_action "导出镜像到: $TEMPLATE_PATH"
    podman save --format=oci-archive -o "$TEMPLATE_PATH" "$IMAGE_NAME" || log_error "导出镜像失败"
    log_success "模板已导出（大小: $(du -h "$TEMPLATE_PATH" | cut -f1)）"
    
    # 第三步：创建容器
    log "第三步：创建容器"
    pct create "$CT_ID" "$TEMPLATE_PATH" \
        --cores "$CORES" \
        --memory "$MEMORY" \
        --swap "$SWAP" \
        --rootfs "$ROOTFS" \
        --storage "$STORAGE" || log_error "创建容器失败"
    log_success "容器创建成功"
    
    # 完成
    echo ""
    log "========================================="
    log_success "部署完成！"
    echo ""
    echo "  容器 ID: $CT_ID"
    echo "  容器名: $CT_NAME"
    echo "  镜像: $IMAGE_NAME"
    echo "  模板: $TEMPLATE_PATH"
    echo ""
    log "========================================="
    
    sleep 2
    pct status "$CT_ID"
}

main