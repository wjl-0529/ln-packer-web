<h1 align="center">bili-novel-UI-Packer</h1>

<p align="center">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green">
  <img alt="Dart" src="https://img.shields.io/badge/Dart-3.x-0175C2">
  <img alt="React" src="https://img.shields.io/badge/React-18-61DAFB">
  <img alt="Docker" src="https://img.shields.io/badge/Docker-Compose-2496ED">
</p>

bili-novel-UI-Packer 是一个自托管轻小说 EPUB 打包工具。它在原有 Dart CLI 打包能力上增加了 Web 后端、React 工作台、任务进度、取消任务、中文搜索、下载管理、Docker 部署和 Windows 本地便携版。

> 本项目基于 [Montaro2017/bili_novel_packer](https://github.com/Montaro2017/bili_novel_packer) 二次开发，沿用 MIT License。Web 化、UI、部署方案和部分重构由 AI 辅助开发，并经过人工确认与测试。

## 功能特性

- 支持将哔哩轻小说 / 轻小说文库内容打包为 EPUB。
- 提供 React + Vite Web UI：搜索或粘贴小说链接、读取目录、选择分卷、查看进度、保存 EPUB。
- 提供 Dart Shelf 后端：任务队列、SSE 实时进度、轮询兜底、取消任务、历史记录、文件下载。
- 保留 CLI 入口 `bin/main.dart`，也可作为命令行工具使用。
- 支持 Docker Compose 一键部署，数据保存到本地 `data/`。
- 支持 Windows 本地便携包，双击 `start.bat` 即可使用。
- 支持共享访问令牌，适合个人或小范围自托管。

## 支持站点

- [哔哩轻小说 / linovelib](https://www.bilinovel.com)
- [轻小说文库 / wenku8](https://www.wenku8.net)

源站可能存在限流、Cloudflare 或页面结构变化。本项目只做清晰的错误提示，不绕过站点限制。

## 快速开始

### Docker Compose

```bash
cp .env.example .env
docker compose up -d --build
```

访问：

```text
http://localhost:8080
```

生成的 EPUB、任务记录和日志保存在 `./data`。

### Windows 本地便携版

在 Windows 开发机上构建：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_local_windows.ps1
```

输出目录：

```text
dist/local-windows/bili-novel-UI-Packer/
```

将整个文件夹交给用户，双击 `start.bat` 启动，双击 `stop.bat` 停止。用户不需要安装 Dart、Node 或 Docker。

### 本地开发

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

Vite 会把 `/api` 代理到 `http://localhost:8080`。

### CLI 使用

```bash
dart run bin/main.dart
```

或编译为可执行文件：

```bash
dart compile exe bin/main.dart -o build/bili-novel-ui-packer-cli
```

## 配置项

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PACKER_PORT` | `8080` | HTTP 服务端口 |
| `PACKER_DATA_DIR` | `/app/data` | 任务和 EPUB 输出目录 |
| `PACKER_PUBLIC_DIR` | `/app/public` | 前端静态文件目录 |
| `PACKER_MAX_CONCURRENT` | `1` | 同时运行的打包任务数 |
| `PACKER_CHAPTER_CONCURRENCY` | `6` | 单个任务内同时处理的章节数 |
| `PACKER_IMAGE_CONCURRENCY` | `8` | 单个任务内同时处理的图片数 |
| `PACKER_SOURCE_RATE_MODE` | `stable` | `stable` 更稳，`fast` 更快但更容易触发限流 |
| `PACKER_FILE_TTL_HOURS` | `24` | EPUB 文件保留小时数 |
| `PACKER_ACCESS_TOKEN` | 空 | 为空时不启用 API 令牌校验 |
| `NODE_IMAGE` | `node:22-alpine` | 前端构建基础镜像 |
| `DART_IMAGE` | `dart:stable` | Dart 编译基础镜像 |
| `DEBIAN_IMAGE` | `debian:bookworm-slim` | 最终运行基础镜像 |
| `APT_MIRROR` | 空 | Debian apt 镜像源，例如 `http://mirrors.aliyun.com/debian` |

## 部署说明

详细部署步骤见 [docs/web-deploy.md](docs/web-deploy.md)。

GitHub Pages 只能托管静态页面，不能运行 Dart 后端服务；本项目服务器部署请使用 Docker Compose 或自行运行 `bin/server.dart`。

## 测试

```bash
dart test test/web
cd web
npm run build
```

也可以编译服务端确认发布构建可用：

```bash
dart compile exe bin/server.dart -o build/server
```

## 来源与致谢

本项目是 [Montaro2017/bili_novel_packer](https://github.com/Montaro2017/bili_novel_packer) 的二次开发版本。感谢原项目提供的轻小说解析、打包和 EPUB 生成基础能力。

主要二次开发内容：

- Web App 化：Dart Shelf API + React/Vite 前端。
- 自托管部署：Dockerfile、Docker Compose、Windows 本地便携包。
- 任务系统：历史记录、SSE 进度、取消任务、文件管理。
- 搜索与 UI：中文搜索、Cloudflare 验证提示、移动端适配。

## AI 辅助开发声明

本项目的 Web 化、UI 设计、部署方案、部分重构和测试补充由 AI 辅助开发。所有生成或修改内容仍需人工理解、确认和维护；使用者应自行确认打包内容、源站规则和部署安全性。

## License

MIT License。请保留原项目与本项目的版权和许可声明。
