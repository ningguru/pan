#!/bin/bash

# =================================================================
# NINGGURU CLOUD - 自动化部署脚本 V2.2 (修复YAML缩进BUG版)
# =================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 辅助函数 ---
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Banner ---
clear
echo -e "${GREEN}"
cat << "BANNER"
 _   _  _____  _   _  _____  _____  _   _ ______  _   _ 
| \ | ||_   _|| \ | ||  __ \|  __ \| | | || ___ \| | | |
|  \| |  | |  |  \| || |  \/| |  \/| | | || |_/ /| | | |
| . ` |  | |  | . ` || | __ | | __ | | | ||    / | | | |
| |\  | _| |_ | |\  || |_\ \| |_\ \| |_| || |\ \ | |_| |
|_| \_| \___/ \_| \_/ \____/ \____/ \___/ \_| \_| \___/ 
                                           CLOUD SYSTEM
BANNER
echo -e "${NC}"
echo -e "欢迎使用 NingGuru Cloud 交互式部署工具"
echo -e "系统时间: $(date)"
echo -e "----------------------------------------------------"

# 1. 检测网络环境
echo -e "\n${CYAN}>>> 第一步: 配置网络环境${NC}"
LOCAL_IP=$(hostname -I | awk '{print $1}')
PUBLIC_IP=$(curl -s ifconfig.me)

echo -e "检测到本地 IP: ${YELLOW}$LOCAL_IP${NC}"
echo -e "检测到公网 IP: ${YELLOW}$PUBLIC_IP${NC}"
echo -e "请选择服务绑定的地址 (用于生成分享链接):"
echo -e "1) 使用自动检测的公网 IP ($PUBLIC_IP)"
echo -e "2) 使用本地 IP ($LOCAL_IP) (仅内网使用)"
echo -e "3) 手动输入域名或 IP"

read -p "请输入选项 [1-3] (默认1): " IP_CHOICE
IP_CHOICE=${IP_CHOICE:-1}

case $IP_CHOICE in
    1) SERVER_HOST=$PUBLIC_IP ;;
    2) SERVER_HOST=$LOCAL_IP ;;
    3) 
        read -p "请输入域名或IP (例如 disk.ningguru.com): " CUSTOM_HOST
        SERVER_HOST=$CUSTOM_HOST
        ;;
    *) SERVER_HOST=$PUBLIC_IP ;;
esac
success "已设置服务地址: $SERVER_HOST"

# 2. 配置端口
echo -e "\n${CYAN}>>> 第二步: 配置服务端口${NC}"
read -p "请输入网盘 Web 访问端口 (默认 8080): " WEB_PORT
WEB_PORT=${WEB_PORT:-8080}
# API 端口固定为 8000 匹配前端代码
API_PORT=8000 

read -p "请输入 MinIO 控制台端口 (默认 9001): " MINIO_CONSOLE_PORT
MINIO_CONSOLE_PORT=${MINIO_CONSOLE_PORT:-9001}

read -p "请输入 MinIO API 端口 (默认 9000): " MINIO_API_PORT
MINIO_API_PORT=${MINIO_API_PORT:-9000}

success "端口配置: Web($WEB_PORT) / API($API_PORT) / MinIO($MINIO_API_PORT)"

# 3. 配置安全凭证
echo -e "\n${CYAN}>>> 第三步: 配置安全凭证${NC}"
read -p "设置管理员账号 (默认 ningguru): " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-ningguru}

while true; do
    read -p "设置管理员密码 (至少8位): " ADMIN_PASS
    if [ ${#ADMIN_PASS} -ge 8 ]; then
        break
    else
        error "密码长度太短，MinIO 要求至少 8 位，请重试。"
    fi
done
success "凭证配置完成"

# 4. 存储盘自动发现
echo -e "\n${CYAN}>>> 第四步: 存储资源池配置${NC}"
info "正在扫描系统中的数据盘 (/data*)..."

POSSIBLE_DISKS=($(ls -d /data* 2>/dev/null))

if [ ${#POSSIBLE_DISKS[@]} -eq 0 ]; then
    error "未检测到 /data* 目录，将使用当前目录下的 ./data 作为存储。"
    SELECTED_DISKS=("./data")
else
    echo -e "发现以下潜在存储盘:"
    for i in "${!POSSIBLE_DISKS[@]}"; do
        DISK_SIZE=$(df -h "${POSSIBLE_DISKS[$i]}" | awk 'NR==2 {print $2}')
        echo -e "$i) ${YELLOW}${POSSIBLE_DISKS[$i]}${NC} (容量: $DISK_SIZE)"
    done

    echo -e "请输入要使用的磁盘编号，用空格分隔 (例如: 0 1)"
    echo -e "输入 'all' 选择所有发现的磁盘"
    read -p "您的选择: " DISK_SELECTION

    SELECTED_DISKS=()
    if [ "$DISK_SELECTION" == "all" ]; then
        SELECTED_DISKS=("${POSSIBLE_DISKS[@]}")
    else
        for index in $DISK_SELECTION; do
            if [ -n "${POSSIBLE_DISKS[$index]}" ]; then
                SELECTED_DISKS+=("${POSSIBLE_DISKS[$index]}")
            fi
        done
    fi
fi

if [ ${#SELECTED_DISKS[@]} -eq 0 ]; then
    error "未选择有效磁盘，退出。"
    exit 1
fi
success "已选择存储资源池: ${SELECTED_DISKS[*]}"

# 5. 生成 docker-compose.yaml
echo -e "\n${CYAN}>>> 第五步: 生成配置文件${NC}"

# 构建 Volumes 和 Command 字符串
MINIO_VOLUMES_CONFIG=""
MINIO_COMMAND_ARGS=""
CTR=1

# 这里的循环逻辑做了优化，直接在字符串尾部追加，避免换行符混乱
for disk in "${SELECTED_DISKS[@]}"; do
    MINIO_VOLUMES_CONFIG="${MINIO_VOLUMES_CONFIG}      - ${disk}:/data${CTR}"$'\n'
    MINIO_COMMAND_ARGS="${MINIO_COMMAND_ARGS} /data${CTR}"
    ((CTR++))
done

# 使用 cat 生成文件，注意变量引用
cat > docker-compose.yaml <<YAML
version: '3.8'

services:
  minio:
    image: swr.cn-north-4.myhuaweicloud.com/ddn-k8s/quay.io/minio/minio:latest
    container_name: ningguru-storage
    command: server${MINIO_COMMAND_ARGS} --console-address ":9001" --address ":9000"
    volumes:
${MINIO_VOLUMES_CONFIG}    environment:
      MINIO_ROOT_USER: ${ADMIN_USER}
      MINIO_ROOT_PASSWORD: "${ADMIN_PASS}"
      MINIO_SERVER_URL: http://${SERVER_HOST}:${MINIO_API_PORT}
      MINIO_API_CORS_ALLOW_ORIGIN: "*"
    ports:
      - "${MINIO_API_PORT}:9000"
      - "${MINIO_CONSOLE_PORT}:9001"
    restart: always

  backend:
    build: ./backend
    container_name: ningguru-api
    environment:
      MINIO_ENDPOINT: minio:9000
      EXTERNAL_ENDPOINT: "${SERVER_HOST}:${MINIO_API_PORT}"
      MINIO_ACCESS_KEY: ${ADMIN_USER}
      MINIO_SECRET_KEY: "${ADMIN_PASS}"
    ports:
      - "${API_PORT}:8000"
    depends_on:
      - minio
    restart: always

  frontend:
    build: ./frontend
    container_name: ningguru-web
    ports:
      - "${WEB_PORT}:80"
    depends_on:
      - backend
    restart: always
YAML

success "docker-compose.yaml 生成完毕！"

# 6. 启动
echo -e "\n${CYAN}>>> 第六步: 启动服务${NC}"
read -p "是否立即构建并启动服务? (y/n): " START_NOW
if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
    # 由于刚才生成的 yaml 是错的，先暴力删除可能存在的旧容器，忽略报错
    info "正在清理旧环境..."
    docker rm -f ningguru-web ningguru-api ningguru-storage > /dev/null 2>&1
    
    info "正在构建并启动..."
    docker compose up -d --build
    
    if [ $? -eq 0 ]; then
        echo -e "\n----------------------------------------------------"
        success "部署成功! NingGuru Cloud 已上线"
        echo -e "📂 网盘地址:      ${GREEN}http://${SERVER_HOST}:${WEB_PORT}${NC}"
        echo -e "🔧 MinIO控制台:   ${GREEN}http://${SERVER_HOST}:${MINIO_CONSOLE_PORT}${NC}"
        echo -e "----------------------------------------------------"
    else
        error "启动失败，请检查上面生成的 docker-compose.yaml 内容是否正常"
    fi
fi
