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
ROOTFS="$STORAGE:2"									# 容器分配大小（因为lxc采用的是raw格式）

# ================== 配置变量 ==================
CT_ID="161"										# LXC 容器 ID（要更新的容器）
IMAGE_NAME="docker.io/jgraph/drawio:latest"				# 镜像名
CT_NAME="61drawio"									# 容器名称（用于日志）
# 依赖，填写客户端的 CT_ID，多个用空格隔开。没有依赖，则可将该变量留空""
DEPENDENT_CT_IDS=""

LOG_FILE="/var/log/$CT_NAME.log"						# 日志文件
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
    exit 1
}

# ================== 检查容器是否存在 ==================
check_container() {
    if pct status "$CT_ID" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ================== 清理函数（确保依赖容器最终被启动） ==================
STOPPED_DEPS=""   # 记录被我们停止的依赖容器列表
cleanup_deps() {
    if [ -n "$STOPPED_DEPS" ]; then
        log_info "正在恢复依赖容器..."
        for dep_ct in $STOPPED_DEPS; do
            pct start "$dep_ct" 2>/dev/null || log_action "容器 $dep_ct 启动（或已在运行）"
        done
        log_success "依赖容器已处理"
    fi
}
trap cleanup_deps EXIT

# ================== 主流程 ==================
main() {
    # ----- 前置检查：容器必须存在 -----
    if ! check_container; then
        log_error "容器 $CT_ID 不存在，请先手动创建"
    fi
    log_info "容器 $CT_ID 存在，开始更新流程"

    # ----- 第一步：检查更新 -----
    log_info "第一步：检查镜像更新"

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
        exit 0
    fi
    log_success "发现新版本，继续更新"

    # ----- 第二步：备份配置（在任何停止操作之前） -----
    log_info "第二步：备份当前容器配置"
    mkdir -p "$BACKUP_DIR"
    CONF_PATH="/etc/pve/lxc/${CT_ID}.conf"
    CONF_BAK="$BACKUP_DIR/${CT_ID}.conf.$(date +%Y%m%d_%H%M%S)"
    
    log_action "备份配置文件到: $CONF_BAK"
    cp "$CONF_PATH" "$CONF_BAK" || log_error "备份配置文件失败"
    log_success "配置文件已备份"

    # ----- 第三步：停止依赖容器（如果有） -----
    if [ -n "$DEPENDENT_CT_IDS" ]; then
        log_info "第三步：停止依赖容器"
        # 清理空白字符，去重
        DEPS_CLEAN=$(echo "$DEPENDENT_CT_IDS" | xargs -n1 | sort -u | xargs)
        for dep_ct in $DEPS_CLEAN; do
            if pct status "$dep_ct" &>/dev/null; then
                log_action "停止依赖容器 $dep_ct"
                pct stop "$dep_ct" 2>/dev/null || log_action "容器 $dep_ct 停止信号已发送"
                # 稍等片刻确保停止
                sleep 3
            else
                log_action "依赖容器 $dep_ct 不存在，跳过"
            fi
        done
        # 记录已停止的依赖列表（用于最终恢复）
        STOPPED_DEPS="$DEPS_CLEAN"
        log_success "依赖容器已全部停止"
    else
        log_info "第三步：无依赖容器，跳过"
    fi

    # ----- 第四步：导出镜像为 OCI 模板 -----
    log_info "第四步：导出新镜像为模板"
    mkdir -p "$TEMPLATE_DIR"

    TEMPLATE_NAME=$(echo "$IMAGE_NAME" | sed 's/\//_/g' | sed 's/:/_/g').tar
    TEMPLATE_PATH="$TEMPLATE_DIR/$TEMPLATE_NAME"

    log_action "导出镜像到: $TEMPLATE_PATH"
    podman save --format=oci-archive -o "$TEMPLATE_PATH" "$IMAGE_NAME" || log_error "导出镜像失败"
    log_success "模板已导出（大小: $(du -h "$TEMPLATE_PATH" | cut -f1)）"

    # ----- 第五步：停止并删除旧容器 -----
    log_info "第五步：停止并删除旧容器"

    log_action "停止容器 $CT_ID"
    pct stop "$CT_ID" 2>/dev/null || true
    sleep 5

    log_action "删除容器 $CT_ID"
    pct destroy "$CT_ID" 2>/dev/null || log_error "删除容器失败"
    log_success "旧容器已删除"

    # ----- 第六步：重建容器并恢复配置 -----
    log_info "第六步：重建容器并恢复配置"

    log_action "创建新容器"
    pct create "$CT_ID" "$TEMPLATE_PATH" --cores $CORES --memory $MEMORY --swap $SWAP \
        --rootfs $ROOTFS --storage $STORAGE || log_error "创建容器失败"
    log_success "新容器已创建"

    log_action "恢复配置文件"
    cp "$CONF_BAK" "$CONF_PATH" || log_error "恢复配置文件失败"
    log_success "配置文件已恢复"

    log_action "启动容器"
    pct start "$CT_ID" || log_error "启动容器失败"
    log_success "容器已启动"

    # ----- 完成 -----
    echo ""
    log_info "更新完成！"
    echo ""
    echo "  容器 ID: $CT_ID"
    echo "  镜像: $IMAGE_NAME"
    echo "  配置备份: $CONF_BAK"
    echo "  模板文件: $TEMPLATE_PATH（保留供下次使用）"
    if [ -n "$STOPPED_DEPS" ]; then
        echo "  依赖容器已重新启动: $STOPPED_DEPS"
    fi
    echo ""

    # 显示容器状态
    sleep 2
    log_info "主容器状态"
    pct status "$CT_ID"
    echo ""
    log_info "关键配置"
    pct config "$CT_ID" | grep -E "hostname|memory|cores|net|rootfs|unprivileged"

    # 依赖容器恢复将由 EXIT trap 自动完成（此处也会触发，但 trap 保证不遗漏）
}

# 执行主流程
main