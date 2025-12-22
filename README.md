# NingGuru Cloud (Gift Edition) ☁️

> 专为个人和团队打造的高性能私有云盘系统。
> 基于 Docker + MinIO 深度定制，支持多主题切换、S3 协议直传与弹性扩容。

## 📖 目录

- [核心特性](#-核心特性)
- [快速部署](#-快速部署)
- [架构与配置](#-架构与配置)
    - [服务端口](#服务端口)
    - [Nginx 反向代理 (生产环境配置)](#nginx-反向代理-生产环境配置)
- [使用指南](#-使用指南)
    - [Web 端访问](#web-端访问)
    - [MinIO 控制台](#minio-控制台)
- [高级玩法：搭建私有图床](#-高级玩法搭建私有图床)
- [运维指南：存储横向扩容](#-运维指南存储横向扩容)

---

## ✨ 核心特性

- **🚀 极速传输**：前端直连 MinIO 存储，大文件上传跑满带宽，无中间层损耗。
- **🎨 魔法主题**：内置哆啦A梦、海绵宝宝、疯狂动物城等 6 套精美 UI，支持一键热切换。
- **📱 全端适配**：响应式设计，完美适配 PC、平板与手机端。
- **💾 弹性存储**：支持多硬盘挂载，自动识别系统数据盘进行容量聚合。
- **🔌 S3 兼容**：原生兼容 AWS S3 协议，可作为 PicGo 图床、Rclone 挂载盘使用。

---

## 🚀 快速部署

本项目集成了自动化运维脚本，一键完成环境检测与容器编排。

1. **运行部署脚本**
   
   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   ```
   
   *脚本会自动扫描 `/data\*` 目录下的磁盘，并生成 `docker-compose.yaml`。*

   2.**更新静态资源 (可选)**

如果你修改了前端代码或增加了背景图，需执行以下命令同步到运行中的容器：

```
docker cp frontend/index.html ningguru-web:/usr/share/nginx/html/index.html
# 同步背景图
docker cp frontend/bg ningguru-web:/usr/share/nginx/html/
```

------

## 🛠 架构与配置

### 服务端口

| **服务名称**      | **容器端口** | **宿主机端口 (默认)** | **说明**                      |
| ----------------- | ------------ | --------------------- | ----------------------------- |
| **Frontend**      | 80           | `8080`                | 网盘 Web 界面 (用户访问)      |
| **Backend**       | 8000         | `8000`                | 业务逻辑 API                  |
| **MinIO API**     | 9000         | `9000`                | S3 数据读写接口 (图床/上传用) |
| **MinIO Console** | 9001         | `9001`                | 存储管理后台                  |

### Nginx 反向代理 (生产环境配置)

为了使用域名 `pan.ningguru.cc.cd` 访问，并去除端口号，需要在宿主机配置 Nginx。

**配置文件路径**: `/etc/nginx/conf.d/ningguru.conf`

Nginx

```
server {
    listen 80;
    server_name pan.ningguru.cc.cd;

    # 解除上传大小限制 (非常重要，否则无法上传大文件)
    client_max_body_size 0;

    # --- 网盘 Web 界面转发 ---
    location / {
        proxy_pass [http://127.0.0.1:8080](http://127.0.0.1:8080); # 转发到 Docker 映射的 8080 端口
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # --- MinIO API 转发 (可选，用于外部工具连接) ---
    # 建议直接开放 9000 端口，或者配置 distinct location
}
```

*配置完成后，执行 `nginx -s reload` 生效。*

------

## 🖥 使用指南

### Web 端访问

- **地址**: `http://pan.ningguru.cc.cd`
- **功能**: 文件上传、下载、新建文件夹、批量删除、视频在线预览。
- **主题切换**: 点击右上角“魔法棒”图标即可切换背景风格。

### MinIO 控制台

- **地址**: `http://pan.ningguru.cc.cd:9001`
- **默认账号**: `ningguru` (或你在部署时设置的账号)
- **默认密码**: `12345678`
- **功能**: 管理存储桶 (Buckets)、查看底层文件、创建访问密钥 (Access Keys)。

------

## 📸 高级玩法：搭建私有图床

利用 MinIO 的 S3 兼容性，你可以将其作为 Typora + PicGo 的图床，实现“截图即上传”。

1. **创建存储桶:**

   登录 MinIO 控制台 -> Buckets -> Create Bucket (例如命名为 images)。

2. **设置公开访问权限:**

   点击刚创建的 Bucket -> Access Policy -> Set directly to Public (这样外部才能看到图片)。

3. **获取密钥:**

   点击左侧菜单 Identity -> Users (或 Access Keys) -> Create Access Key。

   - 记下 `Access Key` 和 `Secret Key`。

4. **配置 PicGo (S3 插件)**:

   - **应用密钥ID**: (填入 Access Key)
   - **应用密钥**: (填入 Secret Key)
   - **桶名**: `images`
   - **文件路径**: `{year}/{month}/{filename}`
   - **地区**: `us-east-1` (默认)
   - **自定义节点 (Endpoint)**: `http://pan.ningguru.cc.cd:9000` (**注意是 9000端口**)

------

## ⚙️ 运维指南：存储横向扩容

本系统支持动态挂载多块硬盘，无需重新编译代码。

**场景**：服务器插了一块新硬盘，挂载到了 `/data3` 目录。

**操作步骤**：

1. 确保新硬盘已挂载：

   Bash

   ```
   df -h | grep data3
   ```

2. 重新运行部署脚本：

   Bash

   ```
   ./deploy.sh
   ```

3. 在“存储资源池配置”步骤中，脚本会自动发现 `/data3`。

4. 选择 `all` 或者手动输入包含新盘的序号。

5. 确认重启。

**原理**：MinIO 容器会自动将新挂载的 `/data3` 识别为新的 Drive，从而实现容量的线性叠加。