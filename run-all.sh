#!/bin/bash
# 文件: /a1sys/A0script/00oci-updata/run-all.sh
# 功能: 按顺序执行所有容器更新脚本，完成后清理无标签旧镜像

SCRIPT_DIR="/a1sys/A0script/00oci-updata"

echo "========================================"
echo "  开始批量更新所有容器"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

for script in "$SCRIPT_DIR"/*.sh; do
    if [ -f "$script" ]; then
        # 跳过自身
        [ "$(basename "$script")" = "run-all.sh" ] && continue
        echo ""
        echo "→ 执行: $(basename "$script")"
        echo "----------------------------------------"
        bash "$script" || echo "⚠ 跳过: $(basename "$script") 执行失败，继续下一个..."
    fi
done

echo ""
echo "→ 清理无标签的旧镜像..."
podman image prune -f

echo ""
echo "========================================"
echo "  所有容器更新完成！"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
