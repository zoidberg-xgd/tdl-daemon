#!/bin/bash

###############################################################################
# tdl-daemon.sh - Telegram Downloader 守护进程脚本
# 
# 功能：
# 1. 在后台运行 tdl 下载任务
# 2. 实时查看输出（通过 screen）
# 3. 自动重启（当程序异常退出时）
# 4. 自动处理断点续传（使用 --continue 标志）
# 5. 友好的日志记录和状态监控
#
# 兼容性：
# - Linux: Ubuntu, Debian, CentOS, RHEL 等主流发行版
# - macOS: macOS 10.12+（支持 Intel 和 Apple Silicon）
#
# 使用方法：
#   ./tdl-daemon.sh start    - 启动守护进程
#   ./tdl-daemon.sh stop     - 停止守护进程
#   ./tdl-daemon.sh status   - 查看状态
#   ./tdl-daemon.sh logs     - 查看实时日志
#   ./tdl-daemon.sh attach   - 附加到运行中的会话（查看实时输出）
#   ./tdl-daemon.sh restart  - 重启守护进程
#   ./tdl-daemon.sh config   - 交互式配置
###############################################################################

set -euo pipefail

# 配置区域
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCREEN_NAME="tdl-daemon"
LOG_DIR="${SCRIPT_DIR}/logs"
PID_FILE="${LOG_DIR}/tdl-daemon.pid"
LOG_FILE="${LOG_DIR}/tdl-daemon.log"
STATUS_FILE="${LOG_DIR}/tdl-daemon.status"
CONFIG_FILE="${SCRIPT_DIR}/tdl-daemon.conf"
CONFIG_EXAMPLE="${SCRIPT_DIR}/tdl-daemon.conf.example"

# 默认配置值
WORK_DIR="${SCRIPT_DIR}"
TDL_CMD=""
TDL_ARGS=(
    # 示例参数，请根据实际情况修改
    # "--url" "https://t.me/..."
    # "--dir" "downloads"
    # "--threads" "4"
)
MAX_RESTARTS=10
RESTART_DELAY=5
RESTART_COUNT_FILE="${LOG_DIR}/restart_count.txt"

# 加载配置文件（如果存在）
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # 安全地加载配置文件
        source "$CONFIG_FILE" 2>/dev/null || {
            echo "[WARN] 配置文件加载失败，使用默认配置" >&2
            return 1
        }
        
        # 从配置文件构建 TDL_ARGS
        TDL_ARGS=()
        
        # 添加下载目录
        if [[ -n "${DOWNLOAD_DIR:-}" ]]; then
            TDL_ARGS+=("--dir" "$DOWNLOAD_DIR")
        fi
        
        # 添加线程数
        if [[ -n "${THREADS:-}" ]]; then
            TDL_ARGS+=("--threads" "$THREADS")
        fi
        
        # 添加所有 URL
        if [[ -n "${URLS:-}" ]] && [[ ${#URLS[@]} -gt 0 ]]; then
            for url in "${URLS[@]}"; do
                # 跳过空值和注释
                if [[ -n "$url" ]] && [[ ! "$url" =~ ^[[:space:]]*# ]]; then
                    TDL_ARGS+=("--url" "$url")
                fi
            done
        fi
        
        # 添加 takeout 标志
        if [[ "${USE_TAKEOUT:-}" == "yes" ]] || [[ "${USE_TAKEOUT:-}" == "y" ]]; then
            TDL_ARGS+=("--takeout")
        fi
        
        # 应用其他配置
        [[ -n "${WORK_DIR:-}" ]] && WORK_DIR="${WORK_DIR}"
        [[ -n "${TDL_CMD:-}" ]] && TDL_CMD="${TDL_CMD}"
        [[ -n "${MAX_RESTARTS:-}" ]] && MAX_RESTARTS="${MAX_RESTARTS}"
        [[ -n "${RESTART_DELAY:-}" ]] && RESTART_DELAY="${RESTART_DELAY}"
        
        return 0
    else
        return 1
    fi
}

# 初始化时加载配置（在 log_debug 定义之前，所以不使用日志函数）
load_config

# 检测终端是否支持颜色输出
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    # 终端支持颜色
    RED=$(tput setaf 1 2>/dev/null || echo "")
    GREEN=$(tput setaf 2 2>/dev/null || echo "")
    YELLOW=$(tput setaf 3 2>/dev/null || echo "")
    BLUE=$(tput setaf 4 2>/dev/null || echo "")
    NC=$(tput sgr0 2>/dev/null || echo "")
else
    # 终端不支持颜色或非交互式终端
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    NC=""
fi

# 检测操作系统类型（用于兼容性处理）
OS_TYPE=""
if [[ "$(uname -s)" == "Darwin" ]]; then
    OS_TYPE="macos"
elif [[ "$(uname -s)" == "Linux" ]]; then
    OS_TYPE="linux"
else
    OS_TYPE="other"
fi

###############################################################################
# 工具函数
###############################################################################

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # 确保日志目录存在
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE" 2>/dev/null || echo "[$timestamp] [$level] $message"
}

log_info() {
    log "INFO" "$@"
    if [[ -n "$GREEN" ]]; then
        echo -e "${GREEN}[INFO]${NC} $*"
    else
        echo "[INFO] $*"
    fi
}

log_warn() {
    log "WARN" "$@"
    if [[ -n "$YELLOW" ]]; then
        echo -e "${YELLOW}[WARN]${NC} $*"
    else
        echo "[WARN] $*"
    fi
}

log_error() {
    log "ERROR" "$@"
    if [[ -n "$RED" ]]; then
        echo -e "${RED}[ERROR]${NC} $*" >&2
    else
        echo "[ERROR] $*" >&2
    fi
}

log_debug() {
    log "DEBUG" "$@"
    if [[ "${DEBUG:-0}" == "1" ]]; then
        if [[ -n "$BLUE" ]]; then
            echo -e "${BLUE}[DEBUG]${NC} $*"
        else
            echo "[DEBUG] $*"
        fi
    fi
}

# 检查 screen 是否安装
check_screen() {
    if ! command -v screen &> /dev/null; then
        log_error "screen 未安装，请先安装："
        echo "  Ubuntu/Debian: sudo apt-get install screen"
        echo "  CentOS/RHEL:   sudo yum install screen"
        echo "  macOS:          brew install screen"
        exit 1
    fi
}

# 自动查找 tdl 命令
find_tdl() {
    local tdl_path=""
    
    # 如果 TDL_CMD 已设置，从中提取路径
    if [[ -n "$TDL_CMD" ]]; then
        # 兼容不同系统：优先使用 awk，如果没有则使用 cut
        if command -v awk >/dev/null 2>&1; then
            tdl_path=$(echo "$TDL_CMD" | awk '{print $1}')
        else
            tdl_path=$(echo "$TDL_CMD" | cut -d' ' -f1)
        fi
        
        # 如果是绝对路径，直接检查
        if [[ "$tdl_path" =~ ^/ ]]; then
            if [[ -f "$tdl_path" && -x "$tdl_path" ]]; then
                echo "$tdl_path"
                return 0
            fi
        else
            # 相对路径或在 PATH 中
            if command -v "$tdl_path" &> /dev/null; then
                command -v "$tdl_path"
                return 0
            fi
        fi
    fi
    
    # 方法 1: 在 PATH 中查找
    if command -v tdl &> /dev/null; then
        command -v tdl
        return 0
    fi
    
    # 方法 2: 在脚本所在目录的父目录查找（项目根目录）
    local parent_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [[ -f "$parent_dir/tdl" && -x "$parent_dir/tdl" ]]; then
        echo "$parent_dir/tdl"
        return 0
    fi
    
    # 方法 3: 在脚本所在目录查找
    if [[ -f "$SCRIPT_DIR/tdl" && -x "$SCRIPT_DIR/tdl" ]]; then
        echo "$SCRIPT_DIR/tdl"
        return 0
    fi
    
    # 方法 4: 在常见位置查找
    local common_paths=(
        "$HOME/go/bin/tdl"
        "$HOME/.local/bin/tdl"
        "/usr/local/bin/tdl"
        "/opt/tdl/tdl"
    )
    
    for path in "${common_paths[@]}"; do
        if [[ -f "$path" && -x "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# 检查 tdl 是否可用
check_tdl() {
    local tdl_path=$(find_tdl)
    
    if [[ -z "$tdl_path" ]]; then
        log_error "tdl 命令未找到"
        echo ""
        echo "脚本已尝试在以下位置查找 tdl："
        echo "  - PATH 环境变量"
        echo "  - 脚本目录的父目录: $SCRIPT_DIR/../tdl"
        echo "  - 脚本所在目录: $SCRIPT_DIR/tdl"
        echo "  - 常见位置: ~/go/bin/tdl, ~/.local/bin/tdl, /usr/local/bin/tdl"
        echo ""
        echo "请尝试以下方法之一："
        echo ""
        echo "方法 1: 将 tdl 添加到 PATH"
        echo "  export PATH=\"\$PATH:/path/to/tdl/directory\""
        echo ""
        echo "方法 2: 在配置文件中设置 TDL_CMD（推荐）"
        if [[ -f "$CONFIG_FILE" ]]; then
            echo "  编辑 $CONFIG_FILE，设置："
            echo "  TDL_CMD=\"/path/to/tdl dl\""
        else
            echo "  运行交互式配置："
            echo "  ./tdl-daemon.sh config"
            echo ""
            echo "  或创建配置文件 $CONFIG_FILE，设置："
            echo "  TDL_CMD=\"/path/to/tdl dl\""
        fi
        echo ""
        echo "方法 3: 将 tdl 放在脚本目录的父目录"
        echo "  cp /path/to/tdl $SCRIPT_DIR/../tdl"
        echo ""
        
        # 尝试查找可能的 tdl 位置
        local possible_locations=()
        if [[ -f "$SCRIPT_DIR/../tdl" ]]; then
            possible_locations+=("$SCRIPT_DIR/../tdl (父目录)")
        fi
        if [[ -f "$SCRIPT_DIR/tdl" ]]; then
            possible_locations+=("$SCRIPT_DIR/tdl (脚本目录)")
        fi
        if [[ -f "$HOME/go/bin/tdl" ]]; then
            possible_locations+=("$HOME/go/bin/tdl")
        fi
        if [[ -f "$HOME/.local/bin/tdl" ]]; then
            possible_locations+=("$HOME/.local/bin/tdl")
        fi
        if [[ -f "/usr/local/bin/tdl" ]]; then
            possible_locations+=("/usr/local/bin/tdl")
        fi
        
        if [[ ${#possible_locations[@]} -gt 0 ]]; then
            echo "提示: 检测到以下位置可能存在 tdl 文件："
            for loc in "${possible_locations[@]}"; do
                echo "  - $loc"
            done
            echo ""
            echo "如果上述位置有 tdl 文件，请检查文件权限："
            echo "  chmod +x /path/to/tdl"
        fi
        
        exit 1
    fi
    
    # 更新 TDL_CMD 为找到的路径
    TDL_CMD="$tdl_path dl"
    log_debug "找到 tdl: $tdl_path"
    
    # 如果配置文件存在且 TDL_CMD 为空，提示用户保存配置
    if [[ -f "$CONFIG_FILE" ]]; then
        local config_tdl_cmd=$(grep "^TDL_CMD=" "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)
        if [[ -z "$config_tdl_cmd" ]]; then
            log_info "提示: 建议在配置文件中保存 tdl 路径，避免每次查找"
            echo "  编辑 $CONFIG_FILE，添加："
            echo "  TDL_CMD=\"$TDL_CMD\""
        fi
    fi
}

# 创建必要的目录
setup_dirs() {
    mkdir -p "$LOG_DIR"
}

# 获取当前重启次数
get_restart_count() {
    if [[ -f "$RESTART_COUNT_FILE" ]]; then
        cat "$RESTART_COUNT_FILE"
    else
        echo "0"
    fi
}

# 增加重启次数
increment_restart_count() {
    local count=$(get_restart_count)
    echo $((count + 1)) > "$RESTART_COUNT_FILE"
}

# 重置重启次数
reset_restart_count() {
    echo "0" > "$RESTART_COUNT_FILE"
}

# 检查是否超过最大重启次数
check_max_restarts() {
    if [[ $MAX_RESTARTS -gt 0 ]]; then
        local count=$(get_restart_count)
        if [[ $count -ge $MAX_RESTARTS ]]; then
            log_error "已达到最大重启次数 ($MAX_RESTARTS)，停止自动重启"
            return 1
        fi
    fi
    return 0
}

# 检查 screen 会话是否存在
is_running() {
    # screen -list 输出格式: "\t123.session_name\t(Attached/Detached)"
    # 使用简单的匹配：包含会话名的行
    screen -list 2>/dev/null | grep -q "${SCREEN_NAME}" && return 0 || return 1
}

# 获取进程 PID
get_pid() {
    if [[ -f "$PID_FILE" ]]; then
        cat "$PID_FILE" 2>/dev/null || echo ""
    fi
}

# 保存状态
save_status() {
    local status="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "status=$status" > "$STATUS_FILE"
    echo "timestamp=$timestamp" >> "$STATUS_FILE"
    echo "restart_count=$(get_restart_count)" >> "$STATUS_FILE"
}

###############################################################################
# 核心功能
###############################################################################

# 启动守护进程
start_daemon() {
    check_screen
    check_tdl
    setup_dirs

    if is_running; then
        log_warn "守护进程已在运行中（screen: $SCREEN_NAME）"
        echo "使用 './tdl-daemon.sh attach' 查看实时输出"
        echo "使用 './tdl-daemon.sh stop' 停止守护进程"
        return 1
    fi

    log_info "启动 tdl 守护进程..."
    
    # 检查 TDL_ARGS 是否为空
    if [[ ${#TDL_ARGS[@]} -eq 0 ]]; then
        log_error "TDL_ARGS 未配置，请先配置下载参数"
        echo "提示: 编辑脚本中的 TDL_ARGS 部分，或使用 './tdl-daemon.sh config' 进行交互式配置"
        return 1
    fi
    
    # 检查是否已有 --continue 或 --restart 标志
    local has_continue=false
    local has_restart=false
    for arg in "${TDL_ARGS[@]}"; do
        if [[ "$arg" == "--continue" ]]; then
            has_continue=true
        fi
        if [[ "$arg" == "--restart" ]]; then
            has_restart=true
        fi
    done
    
    # 构建参数数组
    local cmd_args=("${TDL_ARGS[@]}")
    
    # 添加 --continue 标志（如果还没有的话）来自动处理断点续传
    if [[ "$has_continue" == false ]] && [[ "$has_restart" == false ]]; then
        cmd_args+=("--continue")
        log_info "自动添加 --continue 标志以支持断点续传"
    fi

    # 构建命令显示（用于日志）
    local cmd_display="$TDL_CMD"
    for arg in "${cmd_args[@]}"; do
        if [[ "$arg" =~ [[:space:]] ]]; then
            cmd_display="$cmd_display \"$arg\""
        else
            cmd_display="$cmd_display $arg"
        fi
    done
    log_info "执行命令: $cmd_display"
    log_info "工作目录: $WORK_DIR"
    
    # 创建启动脚本
    local start_script="${LOG_DIR}/start_script.sh"
    
    # 构建命令数组的字符串表示（用于脚本中）
    # 使用数组方式更安全，避免命令注入
    local cmd_args_str=""
    for arg in "${cmd_args[@]}"; do
        # 转义特殊字符，使用 printf %q 安全转义
        local escaped_arg=$(printf '%q' "$arg")
        if [[ -z "$cmd_args_str" ]]; then
            cmd_args_str="$escaped_arg"
        else
            cmd_args_str="$cmd_args_str $escaped_arg"
        fi
    done
    
    # 处理 TDL_CMD：如果包含空格，需要拆分成命令和子命令
    # TDL_CMD 格式通常是 "/path/to/tdl dl" 或 "tdl dl"
    local tdl_base_cmd=""
    local tdl_subcmd=""
    if [[ "$TDL_CMD" =~ ^(.+)[[:space:]]+(.+)$ ]]; then
        # 包含空格，拆分成基础命令和子命令
        tdl_base_cmd="${BASH_REMATCH[1]}"
        tdl_subcmd="${BASH_REMATCH[2]}"
    else
        # 不包含空格，假设是完整命令
        tdl_base_cmd="$TDL_CMD"
        tdl_subcmd=""
    fi
    
    # 转义命令部分
    local tdl_base_cmd_escaped=$(printf '%q' "$tdl_base_cmd")
    local tdl_subcmd_escaped=""
    [[ -n "$tdl_subcmd" ]] && tdl_subcmd_escaped=$(printf '%q' "$tdl_subcmd")
    
    cat > "$start_script" << EOF
#!/bin/bash
# 自动生成的启动脚本

cd "$WORK_DIR"
export PATH="\$PATH"

# 记录启动时间
echo "=========================================="
echo "tdl 守护进程启动"
echo "时间: \$(date '+%Y-%m-%d %H:%M:%S')"
echo "工作目录: $WORK_DIR"
echo "命令: $TDL_CMD $cmd_args_str"
echo "=========================================="
echo ""

# 运行命令
$tdl_base_cmd_escaped${tdl_subcmd_escaped:+ $tdl_subcmd_escaped} $cmd_args_str
exit_code=\$?

# 记录退出
echo ""
    echo "=========================================="
if [[ \$exit_code -eq 0 ]]; then
    echo "[SUCCESS] tdl 下载任务完成！"
    echo "时间: \$(date '+%Y-%m-%d %H:%M:%S')"
    echo "退出码: \$exit_code (成功)"
else
    echo "[ERROR] tdl 进程退出（可能出错）"
    echo "时间: \$(date '+%Y-%m-%d %H:%M:%S')"
    echo "退出码: \$exit_code"
fi
echo "=========================================="

exit \$exit_code
EOF
    chmod +x "$start_script"

    # 在 screen 中启动
    # 使用 -L 选项启用日志记录，-dmS 表示 detached mode
    # 确保路径被正确引用，避免空格导致的问题
    local start_script_quoted=$(printf '%q' "$start_script")
    local log_file_quoted=$(printf '%q' "$LOG_FILE")
    if ! screen -dmS "$SCREEN_NAME" bash -c "$start_script_quoted 2>&1 | tee -a $log_file_quoted"; then
        log_error "无法创建 screen 会话"
        return 1
    fi
    
    # 等待一下确保启动成功
    sleep 2
    
    # 检查 screen 会话是否存在
    if is_running; then
        # 更可靠地获取 screen 会话的 PID
        # 兼容不同系统的命令
        local pid=""
        if command -v awk >/dev/null 2>&1 && command -v cut >/dev/null 2>&1 && command -v head >/dev/null 2>&1; then
            pid=$(screen -list 2>/dev/null | grep "${SCREEN_NAME}" | awk '{print $1}' | cut -d. -f1 | head -1)
        elif command -v sed >/dev/null 2>&1; then
            pid=$(screen -list 2>/dev/null | grep "${SCREEN_NAME}" | sed 's/\..*//' | head -1)
        fi
        if [[ -n "$pid" ]]; then
            echo "$pid" > "$PID_FILE"
        fi
        reset_restart_count
        save_status "running"
        log_info "守护进程启动成功！"
        log_info "Screen 会话名称: $SCREEN_NAME"
        log_info "PID: ${pid:-未知}"
        log_info ""
        log_info "使用以下命令："
        log_info "  查看实时输出: ./tdl-daemon.sh attach"
        log_info "  查看日志:     ./tdl-daemon.sh logs"
        log_info "  查看状态:     ./tdl-daemon.sh status"
        log_info "  停止进程:     ./tdl-daemon.sh stop"
        return 0
    else
        # 检查是否是因为任务快速完成导致会话退出
        # 查看日志中是否有成功启动的记录
        if tail -30 "$LOG_FILE" 2>/dev/null | grep -q "tdl 守护进程启动"; then
            # 检查退出码，判断是成功完成还是出错
            # 兼容不同系统的 grep 命令
            local exit_code=""
            if command -v grep >/dev/null 2>&1; then
                exit_code=$(tail -30 "$LOG_FILE" 2>/dev/null | grep -E "退出码: [0-9]+" | tail -1 | grep -oE "[0-9]+" | head -1)
            else
                exit_code=$(tail -30 "$LOG_FILE" 2>/dev/null | sed -n 's/.*退出码: \([0-9]\+\).*/\1/p' | tail -1)
            fi
            
            if [[ "$exit_code" == "0" ]]; then
                echo ""
                echo "=========================================="
                if [[ -n "$GREEN" ]]; then
                    echo -e "${GREEN}[SUCCESS] 下载任务已完成！${NC}"
                else
                    echo "[SUCCESS] 下载任务已完成！"
                fi
                echo "=========================================="
                log_info "[SUCCESS] 下载任务已完成！"
                log_info "退出码: 0 (成功)"
                echo ""
                log_info "下载文件位置: downloads/"
                # 显示下载的文件
                if [[ -d "downloads" ]]; then
                    # 兼容不同系统的文件列表显示
                    local file_count=0
                    local files_found=false
                    
                    # 使用 find 命令更兼容地查找文件（兼容 Linux 和 macOS）
                    if command -v find >/dev/null 2>&1; then
                        # 统计文件数量
                        if command -v wc >/dev/null 2>&1; then
                            file_count=$(find downloads -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.tmp" \) 2>/dev/null | wc -l | tr -d ' ')
                        fi
                        
                        # 显示前几个文件
                        if [[ $file_count -gt 0 ]]; then
                            files_found=true
                            echo "下载的文件:"
                            if command -v awk >/dev/null 2>&1 && command -v ls >/dev/null 2>&1; then
                                find downloads -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.tmp" \) 2>/dev/null | head -5 | while read -r file; do
                                    if [[ -f "$file" ]]; then
                                        ls -lh "$file" 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
                                    fi
                                done
                            else
                                find downloads -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.tmp" \) 2>/dev/null | head -5
                            fi
                            if [[ $file_count -gt 0 ]]; then
                                echo "  共 $file_count 个文件"
                            fi
                        fi
                    else
                        # 回退到 ls 命令（如果 find 不可用）
                        local files=""
                        if command -v ls >/dev/null 2>&1; then
                            files=$(ls downloads/*.mp4 downloads/*.tmp 2>/dev/null | head -5)
                        fi
                        if [[ -n "$files" ]]; then
                            files_found=true
                            echo "下载的文件:"
                            if command -v awk >/dev/null 2>&1; then
                                ls -lh downloads/*.mp4 downloads/*.tmp 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' | head -5
                            else
                                ls -lh downloads/*.mp4 downloads/*.tmp 2>/dev/null | head -5
                            fi
                            if command -v wc >/dev/null 2>&1; then
                                file_count=$(ls downloads/*.mp4 2>/dev/null | wc -l | tr -d ' ')
                            fi
                            if [[ $file_count -gt 0 ]]; then
                                echo "  共 $file_count 个文件"
                            fi
                        fi
                    fi
                fi
                echo ""
                log_info "查看所有文件: ls -lh downloads/"
                save_status "completed"
                return 0
            else
                log_warn "screen 会话已退出，退出码: ${exit_code:-未知}"
                log_info "请查看日志确认: ./tdl-daemon.sh logs"
                log_info "或检查下载目录: ls -lh downloads/"
                save_status "failed"
                return 0  # 仍然返回成功，因为任务已执行
            fi
        else
            log_error "守护进程启动失败，请检查日志"
            return 1
        fi
    fi
}

# 停止守护进程
stop_daemon() {
    if ! is_running; then
        log_warn "守护进程未运行"
        return 1
    fi

    log_info "停止 tdl 守护进程..."
    
    # 尝试优雅地停止（发送 Ctrl+C）
    screen -S "$SCREEN_NAME" -X stuff $'\003' 2>/dev/null
    sleep 3  # 增加等待时间，确保程序有时间处理信号
    
    # 如果还在运行，强制停止
    if is_running; then
        screen -S "$SCREEN_NAME" -X quit 2>/dev/null
        sleep 1
    fi
    
    if ! is_running; then
        rm -f "$PID_FILE"
        save_status "stopped"
        log_info "守护进程已停止"
        return 0
    else
        log_error "停止守护进程失败"
        return 1
    fi
}

# 查看状态
show_status() {
    setup_dirs
    
    echo "=========================================="
    echo "tdl 守护进程状态"
    echo "=========================================="
    echo ""
    
        if is_running; then
        local pid=$(get_pid)
        if [[ -n "$GREEN" ]]; then
            echo -e "状态: ${GREEN}运行中${NC}"
        else
            echo "状态: 运行中"
        fi
        echo "Screen 会话: $SCREEN_NAME"
        echo "PID: ${pid:-未知}"
        
        if [[ -f "$STATUS_FILE" ]]; then
            echo ""
            echo "详细信息:"
            cat "$STATUS_FILE" | while IFS='=' read -r key value; do
                case "$key" in
                    status)
                        echo "  状态: $value"
                        ;;
                    timestamp)
                        echo "  最后更新: $value"
                        ;;
                    restart_count)
                        echo "  重启次数: $value"
                        ;;
                esac
            done
        fi
    else
        # 检查最后状态
        local last_status=""
        if [[ -f "$STATUS_FILE" ]]; then
            last_status=$(grep "^status=" "$STATUS_FILE" 2>/dev/null | cut -d= -f2)
        fi
        
        if [[ "$last_status" == "completed" ]]; then
            if [[ -n "$GREEN" ]]; then
                echo -e "状态: ${GREEN}已完成${NC}"
            else
                echo "状态: 已完成"
            fi
            echo ""
            echo "[SUCCESS] 下载任务已成功完成！"
        elif [[ "$last_status" == "failed" ]]; then
            if [[ -n "$RED" ]]; then
                echo -e "状态: ${RED}失败${NC}"
            else
                echo "状态: 失败"
            fi
        else
            if [[ -n "$RED" ]]; then
                echo -e "状态: ${RED}未运行${NC}"
            else
                echo "状态: 未运行"
            fi
        fi
        
        if [[ -f "$STATUS_FILE" ]]; then
            echo ""
            echo "最后状态:"
            cat "$STATUS_FILE" | while IFS='=' read -r key value; do
                case "$key" in
                    status)
                        if [[ "$value" == "completed" ]]; then
                            echo "  状态: $value (成功完成)"
                        else
                            echo "  状态: $value"
                        fi
                        ;;
                    timestamp)
                        echo "  最后更新: $value"
                        ;;
                    restart_count)
                        echo "  重启次数: $value"
                        ;;
                esac
            done
        fi
        
        # 如果已完成，显示下载文件信息
        if [[ "$last_status" == "completed" ]]; then
            echo ""
            echo "下载文件:"
            if [[ -d "downloads" ]]; then
                local file_count=0
                # 使用 find 命令更兼容地查找文件
                if command -v find >/dev/null 2>&1; then
                    if command -v wc >/dev/null 2>&1; then
                        file_count=$(find downloads -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.tmp" \) 2>/dev/null | wc -l | tr -d ' ')
                    fi
                    if [[ $file_count -gt 0 ]]; then
                        if command -v awk >/dev/null 2>&1 && command -v ls >/dev/null 2>&1; then
                            find downloads -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.tmp" \) 2>/dev/null | head -5 | while read -r file; do
                                if [[ -f "$file" ]]; then
                                    ls -lh "$file" 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
                                fi
                            done
                        else
                            find downloads -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.tmp" \) 2>/dev/null | head -5
                        fi
                        echo "  共 $file_count 个文件"
                    fi
                else
                    # 回退到 ls 命令
                    if command -v awk >/dev/null 2>&1; then
                        ls -lh downloads/*.mp4 downloads/*.tmp 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' | head -5
                    else
                        ls -lh downloads/*.mp4 downloads/*.tmp 2>/dev/null | head -5
                    fi
                    if command -v wc >/dev/null 2>&1; then
                        file_count=$(ls downloads/*.mp4 2>/dev/null | wc -l | tr -d ' ')
                    fi
                    if [[ $file_count -gt 0 ]]; then
                        echo "  共 $file_count 个文件"
                    fi
                fi
            fi
        fi
    fi
    
    echo ""
    echo "日志文件: $LOG_FILE"
    echo "工作目录: $WORK_DIR"
    echo "=========================================="
}

# 查看日志
show_logs() {
    setup_dirs
    
    if [[ ! -f "$LOG_FILE" ]]; then
        log_warn "日志文件不存在: $LOG_FILE"
        return 1
    fi
    
    echo "显示最后 50 行日志（使用 Ctrl+C 退出）..."
    echo "完整日志文件: $LOG_FILE"
    echo "=========================================="
    tail -f -n 50 "$LOG_FILE"
}

# 附加到 screen 会话（查看实时输出）
attach_session() {
    if ! is_running; then
        log_error "守护进程未运行"
        echo "使用 './tdl-daemon.sh start' 启动守护进程"
        return 1
    fi
    
    log_info "附加到 screen 会话（使用 Ctrl+A, D 退出）..."
    # 如果会话被其他终端附加，使用 -d -r 强制分离并附加
    if screen -list 2>/dev/null | grep -q "Attached.*${SCREEN_NAME}"; then
        screen -d -r "$SCREEN_NAME"
    else
        screen -r "$SCREEN_NAME"
    fi
}

# 监控并自动重启（后台监控进程）
monitor_daemon() {
    setup_dirs
    
    log_info "启动监控进程..."
    
    while true; do
        sleep 10  # 每 10 秒检查一次
        
        if ! is_running; then
            # 检查是否是因为任务完成而退出
            local last_status=""
            if [[ -f "$STATUS_FILE" ]]; then
                last_status=$(grep "^status=" "$STATUS_FILE" 2>/dev/null | cut -d= -f2)
            fi
            
            if [[ "$last_status" == "completed" ]]; then
                log_info "[SUCCESS] 检测到下载任务已完成，停止监控"
                echo ""
                echo "=========================================="
                if [[ -n "$GREEN" ]]; then
                    echo -e "${GREEN}[SUCCESS] 下载任务已完成！${NC}"
                else
                    echo "[SUCCESS] 下载任务已完成！"
                fi
                echo "=========================================="
                echo ""
                echo "下载文件位置: downloads/"
                if [[ -d "downloads" ]]; then
                    local file_count=0
                    # 使用 find 命令更兼容地查找文件
                    if command -v find >/dev/null 2>&1; then
                        if command -v wc >/dev/null 2>&1; then
                            file_count=$(find downloads -maxdepth 1 -type f -name "*.mp4" 2>/dev/null | wc -l | tr -d ' ')
                        fi
                        if [[ $file_count -gt 0 ]]; then
                            echo "共 $file_count 个文件已下载"
                            if command -v awk >/dev/null 2>&1 && command -v ls >/dev/null 2>&1; then
                                find downloads -maxdepth 1 -type f -name "*.mp4" 2>/dev/null | head -5 | while read -r file; do
                                    if [[ -f "$file" ]]; then
                                        ls -lh "$file" 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
                                    fi
                                done
                            else
                                find downloads -maxdepth 1 -type f -name "*.mp4" 2>/dev/null | head -5
                            fi
                        fi
                    else
                        # 回退到 ls 命令
                        if command -v wc >/dev/null 2>&1; then
                            file_count=$(ls downloads/*.mp4 2>/dev/null | wc -l | tr -d ' ')
                        fi
                        if [[ $file_count -gt 0 ]]; then
                            echo "共 $file_count 个文件已下载"
                            if command -v awk >/dev/null 2>&1; then
                                ls -lh downloads/*.mp4 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' | head -5
                            else
                                ls -lh downloads/*.mp4 2>/dev/null | head -5
                            fi
                        fi
                    fi
                fi
                echo ""
                exit 0
            fi
            
            log_warn "检测到守护进程已停止"
            
            if ! check_max_restarts; then
                log_error "超过最大重启次数，停止监控"
                save_status "failed"
                exit 1
            fi
            
            increment_restart_count
            local count=$(get_restart_count)
            log_info "尝试重启守护进程（第 $count 次）..."
            
            sleep "$RESTART_DELAY"
            start_daemon || {
                log_error "重启失败，将在 ${RESTART_DELAY} 秒后重试"
                sleep "$RESTART_DELAY"
            }
        fi
    done
}

# 重启守护进程
restart_daemon() {
    log_info "重启守护进程..."
    stop_daemon
    sleep 2
    start_daemon
}

# 交互式配置
interactive_config() {
    echo "=========================================="
    echo "tdl 守护进程交互式配置"
    echo "=========================================="
    echo ""

    # 检查是否已运行
    if is_running; then
        echo "警告: 检测到守护进程已在运行"
        echo ""
        read -p "是否要停止现有进程并重新配置？(y/N): " answer
        if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
            stop_daemon || return 1
            sleep 2
        else
            echo "已取消"
            return 1
        fi
    fi

    echo "请提供以下信息来配置下载任务："
    echo ""

    # 获取下载 URL（支持多个）
    echo "1. 输入 Telegram 消息链接 (URL):"
    echo "   可以输入多个 URL，每行一个，输入空行结束"
    echo "   示例:"
    echo "     https://t.me/channel/123"
    echo "     https://t.me/channel/456"
    echo "     (空行结束)"
    echo ""
    download_urls=()
    url_count=0
    while true; do
        read -p "   URL $((url_count + 1)) (留空结束): " url_input
        if [[ -z "$url_input" ]]; then
            if [[ $url_count -eq 0 ]]; then
                log_error "至少需要输入一个 URL"
                return 1
            fi
            break
        fi
        download_urls+=("$url_input")
        url_count=$((url_count + 1))
    done

    # 获取下载目录
    read -p "2. 输入下载目录 [默认: downloads]: " download_dir
    download_dir="${download_dir:-downloads}"

    # 获取线程数
    read -p "3. 输入下载线程数 [默认: 4]: " threads
    threads="${threads:-4}"

    # 是否使用 takeout 模式
    read -p "4. 是否使用 takeout 模式（降低限流）？(y/N): " use_takeout
    takeout_flag=""
    if [[ "$use_takeout" == "y" || "$use_takeout" == "Y" ]]; then
        takeout_flag="--takeout"
    fi

    echo ""
    echo "配置摘要:"
    echo "  URL 数量: $url_count"
    for i in "${!download_urls[@]}"; do
        echo "    URL $((i + 1)): ${download_urls[$i]}"
    done
    echo "  目录: $download_dir"
    echo "  线程数: $threads"
    echo "  Takeout: ${takeout_flag:-否}"
    echo ""

    read -p "确认配置？(Y/n): " confirm
    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
        echo "已取消"
        return 1
    fi

    # 更新配置文件
    echo ""
    echo "正在更新配置文件..."
    
    # 如果配置文件不存在，从示例文件创建
    if [[ ! -f "$CONFIG_FILE" ]]; then
        if [[ -f "$CONFIG_EXAMPLE" ]]; then
            cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
            log_info "已从示例文件创建配置文件: $CONFIG_FILE"
        else
            # 创建默认配置文件
            cat > "$CONFIG_FILE" << 'CONFEOF'
# tdl-daemon 配置文件
# 此文件由交互式配置生成

DOWNLOAD_DIR="downloads"
THREADS="4"
URLS=(
)
USE_TAKEOUT="no"
TDL_CMD=""
WORK_DIR=""
MAX_RESTARTS="10"
RESTART_DELAY="5"
CONFEOF
            log_info "已创建默认配置文件: $CONFIG_FILE"
        fi
    fi
    
    # 备份原配置文件
    if [[ -f "$CONFIG_FILE" ]]; then
        local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE" "$backup_file" 2>/dev/null || true
    fi
    
    # 更新配置文件
    local temp_config=$(mktemp)
    
    # 读取现有配置，保留注释和其他配置项
    local in_urls_section=false
    local url_section_start=0
    local url_section_end=0
    local line_num=0
    
    # 先找到 URLS 数组的位置
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if [[ "$line" =~ ^URLS=\( ]]; then
            in_urls_section=true
            url_section_start=$line_num
        fi
        if [[ "$in_urls_section" == true ]] && [[ "$line" =~ ^\) ]]; then
            url_section_end=$line_num
            break
        fi
    done < "$CONFIG_FILE"
    
    # 构建新配置文件
    line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        
        # 更新 DOWNLOAD_DIR
        if [[ "$line" =~ ^DOWNLOAD_DIR= ]]; then
            echo "DOWNLOAD_DIR=\"$download_dir\"" >> "$temp_config"
            continue
        fi
        
        # 更新 THREADS
        if [[ "$line" =~ ^THREADS= ]]; then
            echo "THREADS=\"$threads\"" >> "$temp_config"
            continue
        fi
        
        # 更新 USE_TAKEOUT
        if [[ "$line" =~ ^USE_TAKEOUT= ]]; then
            if [[ -n "$takeout_flag" ]]; then
                echo "USE_TAKEOUT=\"yes\"" >> "$temp_config"
            else
                echo "USE_TAKEOUT=\"no\"" >> "$temp_config"
            fi
            continue
        fi
        
        # 替换 URLS 数组
        if [[ $line_num -eq $url_section_start ]]; then
            echo "URLS=(" >> "$temp_config"
            for url in "${download_urls[@]}"; do
                echo "    \"$url\"" >> "$temp_config"
            done
            # 跳过原 URLS 数组的内容
            continue
        fi
        
        if [[ $line_num -gt $url_section_start ]] && [[ $line_num -lt $url_section_end ]]; then
            # 跳过原 URLS 数组的内容
            continue
        fi
        
        if [[ $line_num -eq $url_section_end ]]; then
            echo ")" >> "$temp_config"
            continue
        fi
        
        # 保留其他行
        echo "$line" >> "$temp_config"
    done < "$CONFIG_FILE"
    
    # 如果没找到 URLS 数组，添加它
    if [[ $url_section_start -eq 0 ]]; then
        # 在文件末尾添加
        cat "$CONFIG_FILE" > "$temp_config"
        echo "" >> "$temp_config"
        echo "URLS=(" >> "$temp_config"
        for url in "${download_urls[@]}"; do
            echo "    \"$url\"" >> "$temp_config"
        done
        echo ")" >> "$temp_config"
    fi
    
    # 替换配置文件
    if mv "$temp_config" "$CONFIG_FILE" 2>/dev/null; then
        log_info "配置文件已更新: $CONFIG_FILE"
        if [[ -n "${backup_file:-}" ]]; then
            log_info "原配置文件已备份为: $backup_file"
        fi
    else
        log_error "无法更新配置文件，可能需要权限"
        rm -f "$temp_config"
        return 1
    fi
    
    echo ""
    echo "=========================================="
    echo "配置已自动更新！"
    echo "=========================================="
    echo ""
    echo "配置文件: $CONFIG_FILE"
    echo ""
    echo "配置内容："
    echo "  DOWNLOAD_DIR=\"$download_dir\""
    echo "  THREADS=\"$threads\""
    echo "  USE_TAKEOUT=\"${use_takeout:-no}\""
    echo "  URLS=("
    for url in "${download_urls[@]}"; do
        echo "    \"$url\""
    done
    echo "  )"
    echo ""
    echo "=========================================="
    echo ""
    echo "提示: 你可以直接编辑 $CONFIG_FILE 来修改配置"
    echo ""
    
    read -p "是否立即启动守护进程？(Y/n): " start_now
    if [[ "$start_now" != "n" && "$start_now" != "N" ]]; then
        echo ""
        # 重新加载配置
        load_config
        start_daemon
    else
        echo ""
        echo "提示: 运行 './tdl-daemon.sh start' 启动守护进程"
    fi
}

###############################################################################
# 主函数
###############################################################################

main() {
    local command="${1:-}"
    
    case "$command" in
        start)
            start_daemon
            ;;
        stop)
            stop_daemon
            ;;
        restart)
            restart_daemon
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs
            ;;
        attach)
            attach_session
            ;;
        monitor)
            # 后台监控模式（可选，用于自动重启）
            monitor_daemon
            ;;
        config)
            # 交互式配置
            interactive_config
            ;;
        *)
            echo "tdl 守护进程管理脚本"
            echo ""
            echo "使用方法: $0 {start|stop|restart|status|logs|attach|monitor|config}"
            echo ""
            echo "命令说明:"
            echo "  config  - 交互式配置（推荐首次使用）"
            echo "  start   - 启动守护进程"
            echo "  stop    - 停止守护进程"
            echo "  restart - 重启守护进程"
            echo "  status  - 查看运行状态"
            echo "  logs    - 查看实时日志（tail -f）"
            echo "  attach  - 附加到 screen 会话查看实时输出"
            echo "  monitor - 启动监控进程（自动重启，可选）"
            echo ""
            echo "提示:"
            echo "  - 首次使用: ./tdl-daemon.sh config"
            echo "  - 使用 'attach' 命令可以实时查看程序输出"
            echo "  - 使用 'logs' 命令可以查看日志文件"
            echo "  - 在 screen 会话中按 Ctrl+A, D 可以退出而不停止程序"
            echo "  - --continue 标志会自动添加，无需手动配置"
            exit 1
            ;;
    esac
}

main "$@"

