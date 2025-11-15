# tdl-daemon

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

tdl 下载任务的守护进程管理工具，支持后台运行、实时监控、自动重启和断点续传。

> 基于 [tdl](https://github.com/iyear/tdl) 项目

## 功能特性

- 后台运行：使用 screen 在后台运行 tdl 下载任务
- 实时监控：通过 screen 会话查看实时输出和进度
- 自动重启：程序异常退出时自动重启
- 断点续传：自动添加 `--continue` 标志，无需交互式输入
- 配置文件：支持独立的配置文件，无需修改脚本
- 多 URL 支持：支持同时下载多个 Telegram 消息链接
- 交互式配置：提供交互式配置向导

## 前置要求

- `screen` 已安装
- [`tdl`](https://github.com/iyear/tdl) 已安装（脚本会自动查找）
- Bash 4.0+（Linux 和 macOS 通常已预装）

### 安装依赖

```bash
# Ubuntu/Debian
sudo apt-get install screen

# CentOS/RHEL
sudo yum install screen

# macOS
brew install screen
```

## 安装

### 从 GitHub 安装

**推荐方式：将脚本放在 tdl 项目根目录下**

```bash
# 在 tdl 项目根目录下克隆仓库
git clone https://github.com/zoidberg-xgd/tdl-daemon.git

# 进入目录并设置执行权限
cd tdl-daemon
chmod +x tdl-daemon.sh
```

**优势**：
- 脚本会自动在父目录找到 `tdl` 命令，无需配置
- 下载文件统一管理
- 便于维护和更新

**其他位置**：tdl-daemon 也可以放在任何位置运行，但需要手动配置 `TDL_CMD` 路径。

## 快速开始

### 0. 安装位置（推荐）

将 `tdl-daemon` 放在 tdl 项目根目录下，目录结构如下：

```
tdl/                    # tdl 项目根目录
├── tdl                # tdl 可执行文件
└── tdl-daemon/        # tdl-daemon 脚本目录
    ├── tdl-daemon.sh
    ├── tdl-daemon.conf.example
    └── ...
```

这样脚本会自动找到 `tdl` 命令，无需额外配置。

### 1. 配置

**方法一：使用配置文件（推荐）**

```bash
# 复制配置文件模板
cp tdl-daemon.conf.example tdl-daemon.conf

# 编辑配置文件
vi tdl-daemon.conf
```

配置文件示例：
```bash
DOWNLOAD_DIR="downloads"
THREADS="4"
URLS=(
    "https://t.me/your_channel/123"
    "https://t.me/your_channel/456"
)
USE_TAKEOUT="no"
```

**方法二：交互式配置**

```bash
./tdl-daemon.sh config
```

交互式配置会自动创建 `tdl-daemon.conf` 文件。

### 2. 启动

```bash
./tdl-daemon.sh start
```

### 3. 查看输出

```bash
./tdl-daemon.sh attach
# 退出: Ctrl+A, D (程序继续运行)
```

## 命令

| 命令 | 说明 |
|------|------|
| `config` | 交互式配置 |
| `start` | 启动守护进程 |
| `stop` | 停止守护进程 |
| `restart` | 重启守护进程 |
| `status` | 查看运行状态 |
| `logs` | 查看实时日志 |
| `attach` | 附加到 screen 会话查看实时输出 |
| `monitor` | 启动监控进程（自动重启） |

## 配置

### 配置文件说明

推荐使用 `tdl-daemon.conf` 配置文件，配置文件位置：`tdl-daemon.conf`（与脚本同目录）

### 基本配置

```bash
DOWNLOAD_DIR="downloads"
THREADS="4"
URLS=(
    "https://t.me/channel/123"
)
USE_TAKEOUT="no"
```

注意：`--continue` 标志会自动添加，无需手动配置。

### 配置示例

**单个 URL：**
```bash
DOWNLOAD_DIR="downloads"
THREADS="4"
URLS=(
    "https://t.me/channel/123"
)
USE_TAKEOUT="no"
```

**多个 URL：**
```bash
DOWNLOAD_DIR="downloads"
THREADS="4"
URLS=(
    "https://t.me/channel/123"
    "https://t.me/channel/456"
    "https://t.me/channel/789"
)
USE_TAKEOUT="no"
```

**Takeout 模式：**
```bash
DOWNLOAD_DIR="downloads"
THREADS="4"
URLS=(
    "https://t.me/channel/123"
)
USE_TAKEOUT="yes"
```

### 高级配置

在 `tdl-daemon.conf` 中配置：

```bash
MAX_RESTARTS="10"    # 最大重启次数（0=无限制）
RESTART_DELAY="5"    # 重启延迟（秒）
TDL_CMD=""           # tdl 命令路径（留空自动查找）
WORK_DIR=""          # 工作目录（留空使用脚本目录）
```

注意：配置文件不支持 `--include` 等高级参数。如需使用这些参数，请直接编辑脚本中的 `TDL_ARGS`（当配置文件不存在时）。

## 工作原理

1. 自动查找 tdl 命令（按以下顺序）：
   - PATH 环境变量
   - 脚本目录的父目录（推荐位置）
   - 脚本所在目录
   - 常见安装位置
2. 使用 screen 在后台运行 tdl 命令
3. 自动添加 `--continue` 标志以支持断点续传
4. 监控进程状态，异常退出时自动重启
5. 所有输出记录到 `logs/tdl-daemon.log`

## 使用场景

### NAS/服务器后台运行

```bash
# SSH 连接到服务器
cd /path/to/tdl-daemon
./tdl-daemon.sh start

# 断开 SSH，程序继续运行
# 重新连接后查看进度
./tdl-daemon.sh attach
```

### 网络不稳定环境

脚本自动检测程序退出并重启，使用 `--continue` 继续下载。

## 故障排查

### 启动失败

```bash
# 检查依赖
which screen
which tdl

# 查看日志
cat logs/tdl-daemon.log
```

### 无法附加会话

```bash
# 查看所有 screen 会话
screen -list

# 使用会话 ID 附加
screen -r <session_id>
```

### 程序不断重启

```bash
# 查看日志
./tdl-daemon.sh logs

# 查看状态
./tdl-daemon.sh status

# 手动测试命令
tdl dl --url "..." --dir "downloads" --continue
```

### 断点续传不工作

确保：
- 命令中没有 `--restart` 标志（会清除进度）
- 脚本会自动添加 `--continue`（如果未指定）

## Screen 会话管理

- `Ctrl+A, D` - 退出会话（detach，程序继续运行）
- `Ctrl+A, K` - 杀死会话（kill，程序停止）

## 高级用法

### 监控模式

在独立的 screen 会话中运行监控进程：

```bash
screen -dmS tdl-monitor bash -c "./tdl-daemon.sh monitor"
```

### Systemd 集成

创建 `/etc/systemd/system/tdl-daemon.service`:

```ini
[Unit]
Description=tdl Downloader Daemon
After=network.target

[Service]
Type=simple
User=your_user
WorkingDirectory=/path/to/tdl-daemon
ExecStart=/path/to/tdl-daemon/tdl-daemon.sh start
ExecStop=/path/to/tdl-daemon/tdl-daemon.sh stop
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

启用服务：

```bash
sudo systemctl enable tdl-daemon
sudo systemctl start tdl-daemon
sudo systemctl status tdl-daemon
```

## 注意事项

1. 首次使用前测试命令：`tdl dl --url "..." --dir "downloads" --continue`
2. 日志文件位于 `logs/tdl-daemon.log`，会不断增长，需定期清理
3. 确保脚本有执行权限：`chmod +x tdl-daemon.sh`

## 许可证

本项目采用 [MIT License](LICENSE) 许可证。

## 贡献

欢迎提交 Issue 和 Pull Request。
