# LN Packer Web Windows 本地便携版

## 启动

双击 `start.bat`。脚本会在后台启动服务，并自动打开：

```text
http://localhost:8080
```

本地版不需要安装 Dart、Node 或 Docker。生成的 EPUB、任务记录和日志保存在当前目录的 `data` 文件夹。

## 停止

双击 `stop.bat`。

## 常用设置

- 默认端口是 `8080`。如需临时修改，可在命令行先设置 `PACKER_PORT` 再运行 `start.bat`。
- 默认同时只运行 1 个打包任务，避免源站限流。
- 默认文件保留 24 小时，可用 `PACKER_FILE_TTL_HOURS` 调整。
