#!/bin/bash
# 文件: /a1sys/A0script/update-all.sh
# 功能: 按顺序执行所有容器更新脚本

# 脚本目录
SCRIPT_DIR="/a1sys/A0script/00oci-updata"

echo "========================================"
echo "  开始批量更新所有容器"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

# 按顺序执行所有脚本
for script in "$SCRIPT_DIR"/*.sh; do
    if [ -f "$script" ]; then
        echo ""
        echo "→ 执行: $(basename $script)"
        echo "----------------------------------------"
        bash "$script" || echo "⚠ 跳过: $(basename $script) 执行失败，继续下一个..."
    fi
done

echo ""
echo "========================================"
echo "  所有容器更新完成！"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"