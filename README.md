# pve-oci-updater

PVE 9.x 环境下，通过 OCI 镜像自动更新 LXC 容器的脚本集。

## 背景

Proxmox VE 9.1 开始支持通过 OCI 镜像直接创建 LXC 容器，但目前官方并未提供镜像自动更新的机制。对于运行 20+ 容器的家庭服务器或小型生产环境，手动逐个更新容器镜像既不现实也不安全。

本套脚本正是为了解决这个痛点而生。

## 功能

- 检查 OCI 镜像更新（基于 Digest 比对，精准判断）
- 导出镜像为 PVE LXC 模板（OCI archive 格式）
- 重建容器并完整恢复原有配置（支持非特权容器）
- 依赖容器管理（更新主容器时自动停止/恢复依赖容器）
- 批量更新同镜像的多个容器（一次拉取，复用模板）
- 全自动串行编排（配合 cron 实现定时无人值守更新）

## 依赖

- Proxmox VE 9.x（已测试 9.2）
- Podman（用于拉取和导出 OCI 镜像）
- bash 4.0+

## 目录结构

建议将脚本放在 PVE 宿主机的统一目录下，例如：`/a1sys/A0script/00oci-updata/`

```
/a1sys/A0script/00oci-updata/
├── create-container.sh    # 首次拉取镜像并创建容器
├── update-batch.sh        # 单镜像多容器批量更新
├── update-single.sh       # 单镜像单容器更新（含依赖管理）
└── run-all.sh             # 批量运行目标路径下所有脚本
```

## 脚本说明

| 脚本 | 用途 | 说明 |
|------|------|------|
| `create-container.sh` | 首次创建容器 | 拉取镜像 → 导出模板 → 创建容器。**容器未启动、无网络、无配置**，所有配置需手动完成 |
| `update-single.sh` | 更新单个容器 | 适用于单镜像单容器场景，支持配置依赖容器（更新前自动停止，完成后自动恢复） |
| `update-batch.sh` | 批量更新多个容器 | 适用于**同一个镜像**启动的多个容器，一次拉取、复用模板，批量重建 |
| `run-all.sh` | 调度器 | 按顺序执行目标路径下所有 `.sh` 脚本，单个失败不影响后续执行 |

## 使用方法

### 1. 首次创建容器

编辑 `create-container.sh`，修改变量：

```bash
CT_ID="165"                                      # LXC 容器 ID
IMAGE_NAME="ghcr.io/openlistteam/openlist-git:latest"  # OCI 镜像名
CT_NAME="65openlist"                             # 容器名称（仅用于日志）
CORES="32"                                       # CPU 核心数
MEMORY="10240"                                   # 内存大小（MB）
ROOTFS="a1sys:1"                                 # 存储池:大小（GB）
```

执行：

```bash
bash /a1sys/A0script/00oci-updata/create-container.sh
```

> ⚠️ 此脚本仅创建容器，**不会启动容器**，网络、挂载卷、环境变量等所有配置需通过 PVE 界面或 `pct set` 手动完成。

### 2. 更新单个容器（含依赖管理）

编辑 `update-single.sh`，修改变量：

```bash
CT_ID="161"                                      # 要更新的容器 ID
IMAGE_NAME="docker.io/jgraph/drawio:latest"      # OCI 镜像名
CT_NAME="61drawio"                               # 容器名称（仅用于日志）
DEPENDENT_CT_IDS="162 163"                       # 依赖容器 ID（多个用空格隔开）
```

执行：

```bash
bash /a1sys/A0script/00oci-updata/update-single.sh
```

脚本自动完成：检查更新 → 备份配置 → 停止依赖容器 → 停止并删除旧容器 → 重建 → 恢复配置 → 启动 → 恢复依赖容器。

### 3. 批量更新同镜像的多个容器

编辑 `update-batch.sh`，修改变量：

```bash
CONTAINERS=(
    "130|30qbittorrent-bt"
    "131|31qbittorrent-bt"
)
IMAGE_NAME="lscr.io/linuxserver/qbittorrent:latest"
```

执行：

```bash
bash /a1sys/A0script/00oci-updata/update-batch.sh
```

脚本逻辑：检查一次镜像更新 → 有更新则导出模板 → 遍历列表中所有容器，逐个重建。

### 4. 全自动定时更新

将需要定时执行的脚本放在 `update-single.sh` 同级目录，然后执行：

```bash
bash /a1sys/A0script/00oci-updata/run-all.sh
```

配合 crontab 实现每日自动更新：

```bash
# 每天凌晨 3 点执行所有更新
0 3 * * * /a1sys/A0script/00oci-updata/run-all.sh >> /var/log/pve-oci-updater.log 2>&1
```

## 配置变量说明

所有脚本顶部的变量均为硬编码，请根据实际环境修改：

| 变量 | 说明 | 示例 |
|------|------|------|
| `STORAGE` | PVE 存储池名称 | `a1sys` |
| `TEMPLATE_DIR` | OCI 模板存放目录 | `/a1sys/template/cache` |
| `BACKUP_DIR` | 容器配置备份目录 | `/a1sys/A0script/00lxc_backup` |
| `CORES` | 容器 CPU 核心数 | `32` |
| `MEMORY` | 容器内存大小（MB） | `10240` |
| `SWAP` | 容器 Swap（MB） | `0` |
| `ROOTFS` | 容器 rootfs 存储池:大小 | `a1sys:1` |

## 注意事项

- **非特权容器**：本套脚本完整支持非特权容器，配置中的 `unprivileged` 标志会被备份和恢复
- **模板缓存**：`update-batch.sh` 按天缓存模板，同一天内重复运行不会重复导出，节省时间
- **依赖容器**：`update-single.sh` 支持依赖容器管理，更新主容器时自动停止/恢复
- **容错处理**：`run-all.sh` 中单个脚本失败不会中断其他脚本执行
- **首次创建**：`create-container.sh` 创建的容器是裸容器，需手动配置网络、挂载、环境变量等
- **容易失败**：`ROOTFS`容量不足，创建失败

## 已知限制

- 容器创建后，后续配置（挂载卷、网络设置等）需通过 PVE 界面或 `pct set` 手动完成
- 当前仅支持 PVE 9.x 的 OCI 模板格式（`oci-archive`）

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request。

## 致谢

本套脚本已在 PVE 9.2 + 非特权容器 + 20+ 容器的生产环境中稳定运行。
```
