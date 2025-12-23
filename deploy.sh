#!/bin/bash

# =================================================================
# NINGGURU CLOUD - 部署脚本 V3.2 (默认全选磁盘版)
# =================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

clear
echo -e "${GREEN}"
cat << "BANNER"
 _   _  _____  _   _  _____  _____  _   _ ______  _   _ 
| \ | ||  _  || \ | ||  __ \|  __ \| | | || ___ \| | | |
|  \| || | | ||  \| || |  \/| |  \/| | | || |_/ /| | | |
| . ` || | | || . ` || | __ | | __ | | | ||    / | | | |
| |\  || |_| || |\  || |_\ \| |_\ \| |_| || |\ \ | |_| |
|_| \_|\_____/\_| \_/ \____/ \____/ \___/ \_| \_| \___/ 
                                            GIFT EDITION
BANNER
echo -e "${NC}"
echo -e "欢迎使用 NingGuru Cloud V3.2 (扩容优化版)"
echo -e "----------------------------------------------------"

# 1. 网络配置
echo -e "\n${CYAN}>>> 第一步: 配置网络环境${NC}"
read -p "请输入域名或IP (例如 pan.ningguru.cc.cd): " SERVER_HOST
SERVER_HOST=${SERVER_HOST:-127.0.0.1}
success "服务器地址: $SERVER_HOST"

# 2. 端口配置
echo -e "\n${CYAN}>>> 第二步: 配置服务端口${NC}"
read -p "Web 访问端口 (默认 8080): " WEB_PORT
WEB_PORT=${WEB_PORT:-8080}

read -p "API 后端端口 (默认 8000): " API_PORT
API_PORT=${API_PORT:-8000}

read -p "MinIO API 端口 (默认 9000): " MINIO_API_PORT
MINIO_API_PORT=${MINIO_API_PORT:-9000}

read -p "MinIO 控制台端口 (默认 9001): " MINIO_CONSOLE_PORT
MINIO_CONSOLE_PORT=${MINIO_CONSOLE_PORT:-9001}

success "端口配置: Web($WEB_PORT) / API($API_PORT) / MinIO($MINIO_API_PORT)"

# 3. 安全凭证 (MinIO)
echo -e "\n${CYAN}>>> 第三步: 配置 MinIO 底层凭证${NC}"
read -p "设置 MinIO 管理员账号 (默认 ningguru): " MINIO_USER
MINIO_USER=${MINIO_USER:-ningguru}
read -p "设置 MinIO 管理员密码 (默认 12345678): " MINIO_PASS
MINIO_PASS=${MINIO_PASS:-12345678}

# 4. 网站双重密码配置
echo -e "\n${CYAN}>>> 第四步: 配置网站访问密码 (双重锁)${NC}"
read -p "1. 设置全站访问密码 (打开网页就要输): " SITE_PASSWORD
read -p "2. 设置隐私空间密码 (进入隐私空间才输): " PRIVATE_PASSWORD

if [ -z "$SITE_PASSWORD" ] || [ -z "$PRIVATE_PASSWORD" ]; then
    error "密码不能为空！"
    exit 1
fi

# 5. 存储盘自动发现
echo -e "\n${CYAN}>>> 第五步: 存储资源池配置${NC}"
info "正在扫描系统中的数据盘 (/data*)..."

POSSIBLE_DISKS=($(ls -d /data* 2>/dev/null))

if [ ${#POSSIBLE_DISKS[@]} -eq 0 ]; then
    error "未检测到 /data* 目录，将使用当前目录下的 ./data 作为存储。"
    mkdir -p ./data
    SELECTED_DISKS=("./data")
else
    echo -e "发现以下潜在存储盘:"
    for i in "${!POSSIBLE_DISKS[@]}"; do
        DISK_SIZE=$(df -h "${POSSIBLE_DISKS[$i]}" | awk 'NR==2 {print $2}')
        echo -e "$i) ${YELLOW}${POSSIBLE_DISKS[$i]}${NC} (容量: $DISK_SIZE)"
    done

    echo -e "请输入要使用的磁盘编号，用空格分隔 (例如: 0 1)"
    echo -e "输入 'all' 或直接回车选择所有发现的磁盘"
    read -p "您的选择 [默认 all]: " DISK_SELECTION
    
    # --- 修改点：设置默认值为 all ---
    DISK_SELECTION=${DISK_SELECTION:-all}

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

# 6. 生成 docker-compose.yaml
echo -e "\n${CYAN}>>> 第六步: 生成配置文件${NC}"

MINIO_VOLUMES_CONFIG=""
MINIO_COMMAND_ARGS=""
CTR=1

for disk in "${SELECTED_DISKS[@]}"; do
    if [[ "$disk" == "./data" ]]; then
        disk="$(pwd)/data"
    fi
    MINIO_VOLUMES_CONFIG="${MINIO_VOLUMES_CONFIG}      - ${disk}:/data${CTR}"$'\n'
    MINIO_COMMAND_ARGS="${MINIO_COMMAND_ARGS} /data${CTR}"
    ((CTR++))
done

cat > docker-compose.yaml <<YAML
version: '3.8'

services:
  minio:
    image: swr.cn-north-4.myhuaweicloud.com/ddn-k8s/quay.io/minio/minio:latest
    container_name: ningguru-storage
    command: server${MINIO_COMMAND_ARGS} --console-address ":9001" --address ":9000"
    volumes:
${MINIO_VOLUMES_CONFIG}    environment:
      MINIO_ROOT_USER: ${MINIO_USER}
      MINIO_ROOT_PASSWORD: "${MINIO_PASS}"
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
      MINIO_ACCESS_KEY: ${MINIO_USER}
      MINIO_SECRET_KEY: "${MINIO_PASS}"
      SITE_PASSWORD: "${SITE_PASSWORD}"
      PRIVATE_PASSWORD: "${PRIVATE_PASSWORD}"
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

# 7. 启动
echo -e "\n${CYAN}>>> 第七步: 启动服务${NC}"
read -p "是否立即构建并启动服务? (y/n): " START_NOW
if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
    info "清理旧容器..."
    docker rm -f ningguru-web ningguru-api ningguru-storage > /dev/null 2>&1
    info "构建并启动..."
    docker compose up -d --build
    success "部署成功！"
fi
