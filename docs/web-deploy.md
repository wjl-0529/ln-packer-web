# LN Packer Web 部署说明

LN Packer Web 是自托管 Web App，后端需要持续运行，因此不能直接部署到 GitHub Pages。服务器部署推荐使用 Docker Compose。

## Docker Compose

复制配置示例：

```bash
cp .env.example .env
```

启动服务：

```bash
docker compose up -d --build
```

默认访问地址：

```text
http://服务器 IP:8080
```

生成的 EPUB、任务记录和日志保存在宿主机 `./data` 目录。

## 访问令牌

个人或小范围公开部署时建议设置共享令牌：

```text
PACKER_ACCESS_TOKEN=改成一段足够长的随机字符串
```

前端右上角的“访问令牌”输入框会把令牌保存在浏览器本地，用于 API、SSE 进度和 EPUB 下载。

## 配置项

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PACKER_PORT` | `8080` | 宿主机 HTTP 端口 |
| `PACKER_DATA_DIR` | `/app/data` | 容器内任务和 EPUB 输出目录 |
| `PACKER_PUBLIC_DIR` | `/app/public` | 容器内前端静态文件目录 |
| `PACKER_MAX_CONCURRENT` | `1` | 同时运行的打包任务数 |
| `PACKER_CHAPTER_CONCURRENCY` | `6` | 单个任务内同时处理的章节数 |
| `PACKER_IMAGE_CONCURRENCY` | `8` | 单个任务内同时处理的图片数 |
| `PACKER_SOURCE_RATE_MODE` | `stable` | 源站请求策略，`stable` 稳定，`fast` 更快但更容易触发限流 |
| `PACKER_FILE_TTL_HOURS` | `24` | EPUB 文件保留小时数 |
| `PACKER_ACCESS_TOKEN` | 空 | 为空时不启用 API 令牌校验 |
| `NODE_IMAGE` | `node:22-alpine` | 前端构建基础镜像 |
| `DART_IMAGE` | `dart:stable` | Dart 编译基础镜像 |
| `DEBIAN_IMAGE` | `debian:bookworm-slim` | 最终运行基础镜像 |
| `APT_MIRROR` | 空 | Debian apt 镜像源，例如 `http://mirrors.aliyun.com/debian` |

如果服务器拉取官方镜像或 apt 源较慢，可在 `.env` 中替换 `NODE_IMAGE`、`DART_IMAGE`、`DEBIAN_IMAGE`，并设置 `APT_MIRROR=http://mirrors.aliyun.com/debian`。

## Windows 本地便携版

在 Windows 开发机上构建：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_local_windows.ps1
```

输出目录：

```text
dist/local-windows/LN Packer Web/
```

交给用户时保留整个文件夹即可。用户双击 `start.bat` 会自动启动服务并打开 `http://localhost:8080`，双击 `stop.bat` 停止服务。

## 本地开发

后端：

```bash
dart pub get
dart run bin/server.dart
```

前端：

```bash
cd web
npm install
npm run dev
```

Vite 开发服务会把 `/api` 代理到 `http://localhost:8080`。
