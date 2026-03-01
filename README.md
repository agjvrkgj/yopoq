# SOOP VOD Downloader Bot 🎬

自动下载 SOOP (AfreecaTV) VOD 并上传到 OneDrive 的 Telegram 机器人。

## 功能

- 📥 发送 SOOP VOD 链接或数字 ID 即可自动下载
- 📋 队列系统，自动按顺序下载上传
- ☁️ 自动上传到 OneDrive
- 🔧 自动修复视频封装（OneDrive 在线播放兼容）
- 🔞 支持 19 禁内容（需 SOOP 账号）
- ⚡ aria2c 多线程加速下载
- 🎬 支持多 Part 播放列表

## 一键部署

```bash
# 安装
bash <(curl -fsSL https://raw.githubusercontent.com/agjvrkgj/yopoq/main/install.sh)

# 卸载
bash <(curl -fsSL https://raw.githubusercontent.com/agjvrkgj/yopoq/main/install.sh) uninstall
```

## 手动部署

```bash
git clone https://github.com/agjvrkgj/yopoq.git
cd soop-downloader
bash install.sh
```

## Bot 命令

| 命令 | 说明 |
|------|------|
| `/start` | 显示帮助 |
| `/queue` | 查看下载队列 |
| `/clear` | 清空队列 |
| `/status` | 查看当前任务 |
| `/disk` | 查看磁盘空间 |
| `/onedrive` | 查看 OneDrive 状态 |

## 使用方式

1. 在 Telegram 找到你的 Bot
2. 发送 SOOP VOD 链接：`https://vod.sooplive.co.kr/player/188259589`
3. 或者直接发 ID：`188259589`
4. Bot 自动加入队列，下载 → 封装修复 → 上传 OneDrive → 自动清理

## 依赖

- Python 3.10+
- yt-dlp
- ffmpeg
- aria2c
- rclone (配置 OneDrive)

## 配置

安装脚本会引导你配置以下内容：

- Telegram Bot Token（从 @BotFather 获取）
- Telegram 管理员 ID
- SOOP 账号密码（可选，用于 19 禁内容）
- OneDrive（通过 rclone 配置）

## License

MIT
