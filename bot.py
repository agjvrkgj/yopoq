#!/usr/bin/env python3
"""
SOOP VOD Downloader Telegram Bot
- Download SOOP (AfreecaTV) VODs via yt-dlp
- Supports single videos AND playlists (multi-part VODs)
- Queue system: auto-download next after current finishes
- Upload to OneDrive via rclone
- Controlled via Telegram bot
"""

import os
import re
import json
import asyncio
import logging
import subprocess
import time
import hashlib
from pathlib import Path
from datetime import datetime
from collections import deque

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand
from telegram.ext import (
    Application,
    CommandHandler,
    MessageHandler,
    CallbackQueryHandler,
    ContextTypes,
    filters,
    Defaults,
)
from telegram.constants import ParseMode
from telegram import LinkPreviewOptions

from config import *
from refresh_token import refresh_token as do_refresh_token

# ── Logging ──────────────────────────────────────────────────────────────
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(os.path.join(LOG_DIR, "bot.log")),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger(__name__)

# ── Globals ──────────────────────────────────────────────────────────────
SOOP_URL_PATTERN = re.compile(r"https?://vod\.sooplive\.co\.kr/player/(\d+)")
SOOP_ID_PATTERN = re.compile(r"^(\d{6,})$")

# Queue system
download_queue: deque = deque()  # [{url, title, chat_id, is_playlist, part_count}]
is_processing = False
current_task: dict | None = None


# ── Helpers ──────────────────────────────────────────────────────────────

def is_admin(user_id: int) -> bool:
    return user_id == ADMIN_ID


def human_size(size_bytes: int) -> str:
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if abs(size_bytes) < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"


def human_duration(seconds: int) -> str:
    h, r = divmod(seconds, 3600)
    m, s = divmod(r, 60)
    if h > 0:
        return f"{h}h{m:02d}m{s:02d}s"
    return f"{m}m{s:02d}s"


def short_id(url: str) -> str:
    return hashlib.md5(url.encode()).hexdigest()[:12]


def get_video_info(url: str) -> list[dict]:
    """Get video metadata via yt-dlp."""
    try:
        logger.info(f"Getting video info for: {url}")
        result = subprocess.run(
            ["yt-dlp", "--dump-json", "--no-download",
             "--username", SOOP_USERNAME, "--password", SOOP_PASSWORD, url],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.stderr:
            logger.warning(f"yt-dlp stderr: {result.stderr[:500]}")
        if result.returncode != 0:
            logger.error(f"yt-dlp exit code {result.returncode}: {result.stderr[:500]}")
            return []
        if result.stdout.strip():
            videos = []
            for line in result.stdout.strip().split("\n"):
                line = line.strip()
                if line:
                    try:
                        videos.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
            return videos
    except subprocess.TimeoutExpired:
        logger.error(f"yt-dlp timed out for {url}")
    except Exception as e:
        logger.error(f"Failed to get video info: {e}")
    return []


async def download_video(url: str, progress_callback=None) -> list[str]:
    """Download video(s) using yt-dlp, return list of file paths."""
    output_template = os.path.join(DOWNLOAD_DIR, "%(title)s [%(id)s].%(ext)s")
    cmd = [
        "yt-dlp",
        "-f", YTDLP_FORMAT,
        "--merge-output-format", "mp4",
        "-o", output_template,
        "--newline",
        "--no-part",
        "--concurrent-fragments", "8",
        "--downloader", "aria2c",
        "--downloader-args", "aria2c:-x 16 -s 16 -k 1M",
        "--username", SOOP_USERNAME,
        "--password", SOOP_PASSWORD,
        url,
    ]

    process = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )

    filepaths = []
    last_update = 0
    current_part = 0

    async for line in process.stdout:
        line = line.decode("utf-8", errors="replace").strip()
        logger.info(f"yt-dlp: {line}")

        if "[download] Downloading item" in line:
            part_match = re.search(r"item (\d+) of (\d+)", line)
            if part_match:
                current_part = int(part_match.group(1))
                total_parts = int(part_match.group(2))
                if progress_callback:
                    await progress_callback(f"⬇️ 下载 Part {current_part}/{total_parts}...")

        if progress_callback and "[download]" in line and "%" in line:
            now = time.time()
            if now - last_update >= 3:
                last_update = now
                pct_match = re.search(r"(\d+\.?\d*)%", line)
                if pct_match:
                    part_info = f" (Part {current_part})" if current_part > 0 else ""
                    await progress_callback(f"⬇️ 下载中{part_info}... {pct_match.group(0)}")

        dest_match = re.search(r"\[(?:download|Merger)\] Destination: (.+)", line)
        if dest_match:
            fp = dest_match.group(1).strip()
            if fp not in filepaths:
                filepaths.append(fp)

        merge_match = re.search(r'\[Merger\] Merging formats into "(.+)"', line)
        if merge_match:
            fp = merge_match.group(1).strip()
            if filepaths:
                filepaths[-1] = fp
            else:
                filepaths.append(fp)

        already_match = re.search(r'\[download\] (.+\.mp4) has already been downloaded', line)
        if already_match:
            fp = already_match.group(1).strip()
            if fp not in filepaths:
                filepaths.append(fp)

    await process.wait()

    if process.returncode != 0:
        return []

    filepaths = [fp for fp in filepaths if os.path.exists(fp)]

    if not filepaths:
        files = sorted(Path(DOWNLOAD_DIR).glob("*.mp4"), key=os.path.getmtime, reverse=True)
        if files:
            filepaths = [str(files[0])]

    return filepaths


async def upload_to_onedrive(filepath: str, progress_callback=None) -> bool:
    """Upload file to OneDrive via rclone."""
    try:
        do_refresh_token()
    except Exception as e:
        logger.warning(f"Token refresh failed: {e}")

    filename = os.path.basename(filepath)
    dest = f"{RCLONE_REMOTE}:{RCLONE_DEST}/{filename}"

    cmd = [
        "rclone", "copyto",
        filepath,
        dest,
        "--progress",
        "--stats", "3s",
        "--stats-one-line",
    ]

    process = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )

    last_update = 0

    async for line in process.stdout:
        line = line.decode("utf-8", errors="replace").strip()
        logger.info(f"rclone: {line}")

        if progress_callback:
            now = time.time()
            if now - last_update >= 5:
                last_update = now
                pct_match = re.search(r"(\d+)%", line)
                if pct_match:
                    await progress_callback(f"☁️ 上传 OneDrive... {pct_match.group(0)}")

    await process.wait()
    return process.returncode == 0


async def cleanup_file(filepath: str):
    try:
        os.remove(filepath)
        logger.info(f"Cleaned up: {filepath}")
    except Exception as e:
        logger.error(f"Cleanup failed: {e}")


async def remux_video(filepath: str, progress_callback=None) -> str:
    """Remux video with ffmpeg for OneDrive compatibility."""
    if not filepath or not os.path.exists(filepath):
        return filepath

    base, ext = os.path.splitext(filepath)
    remuxed = base + "_remux" + ext

    logger.info(f"Remuxing: {filepath} -> {remuxed}")
    if progress_callback:
        await progress_callback("🔧 修复视频封装...")

    process = await asyncio.create_subprocess_exec(
        "ffmpeg", "-i", filepath,
        "-c", "copy",
        "-movflags", "+faststart",
        "-y", remuxed,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )

    async for line in process.stdout:
        pass

    await process.wait()

    if process.returncode == 0 and os.path.exists(remuxed):
        os.remove(filepath)
        os.rename(remuxed, filepath)
        logger.info(f"Remux done: {filepath}")
        return filepath
    else:
        logger.warning(f"Remux failed, keeping original: {filepath}")
        if os.path.exists(remuxed):
            os.remove(remuxed)
        return filepath


# ── Queue Worker ─────────────────────────────────────────────────────────

async def queue_worker(app: Application):
    """Process download queue sequentially."""
    global is_processing, current_task

    if is_processing:
        return

    is_processing = True

    try:
        while download_queue:
            task = download_queue.popleft()
            current_task = task

            url = task["url"]
            title = task["title"]
            chat_id = task["chat_id"]
            is_playlist = task.get("is_playlist", False)
            part_count = task.get("part_count", 1)
            queue_remaining = len(download_queue)

            logger.info(f"Queue: processing {title} (remaining: {queue_remaining})")

            # Send status message
            queue_info = f"\n📋 队列剩余: {queue_remaining}" if queue_remaining > 0 else ""
            label = f"{title} ({part_count} Parts)" if is_playlist else title

            status_msg = await app.bot.send_message(
                chat_id=chat_id,
                text=f"⬇️ 开始下载\n\n{label}{queue_info}",
            )

            try:
                # ── Download ──
                last_text = [""]

                async def dl_progress(text: str):
                    if text != last_text[0]:
                        last_text[0] = text
                        try:
                            await status_msg.edit_text(f"{text}\n\n{label}{queue_info}")
                        except Exception:
                            pass

                filepaths = await download_video(url, dl_progress)

                if not filepaths:
                    await status_msg.edit_text(f"❌ 下载失败\n\n{label}")
                    continue

                # ── Remux ──
                for i, fp in enumerate(filepaths):
                    if os.path.exists(fp):
                        part_label = f" ({i+1}/{len(filepaths)})" if len(filepaths) > 1 else ""
                        try:
                            await status_msg.edit_text(f"🔧 修复视频封装{part_label}...\n\n{label}")
                        except Exception:
                            pass
                        filepaths[i] = await remux_video(fp)

                total_size = sum(os.path.getsize(fp) for fp in filepaths if os.path.exists(fp))

                # ── Upload ──
                success_count = 0
                for i, filepath in enumerate(filepaths, 1):
                    if not os.path.exists(filepath):
                        continue

                    file_size = os.path.getsize(filepath)
                    file_label = f"({i}/{len(filepaths)}) " if len(filepaths) > 1 else ""

                    await status_msg.edit_text(
                        f"☁️ 上传到 OneDrive {file_label}\n\n"
                        f"{os.path.basename(filepath)}\n"
                        f"文件大小: {human_size(file_size)}{queue_info}"
                    )

                    async def ul_progress(text: str):
                        try:
                            await status_msg.edit_text(
                                f"{text} {file_label}\n\n"
                                f"{os.path.basename(filepath)}\n"
                                f"文件大小: {human_size(file_size)}{queue_info}"
                            )
                        except Exception:
                            pass

                    success = await upload_to_onedrive(filepath, ul_progress)

                    if success:
                        success_count += 1
                        await cleanup_file(filepath)
                    else:
                        logger.error(f"Upload failed for {filepath}")

                # ── Summary ──
                if success_count == len(filepaths):
                    files_list = "\n".join(f"  • {os.path.basename(fp)}" for fp in filepaths)
                    next_info = f"\n\n⏭ 队列剩余: {len(download_queue)}" if download_queue else ""
                    await status_msg.edit_text(
                        f"✅ 完成!\n\n"
                        f"标题: {title}\n"
                        f"文件数: {success_count}\n"
                        f"总大小: {human_size(total_size)}\n"
                        f"OneDrive: {RCLONE_DEST}/\n\n"
                        f"{files_list}{next_info}"
                    )
                else:
                    await status_msg.edit_text(
                        f"⚠️ 部分完成 ({success_count}/{len(filepaths)})\n\n{title}"
                    )

            except Exception as e:
                logger.exception(f"Pipeline error for {url}")
                try:
                    await status_msg.edit_text(f"❌ 出错了\n\n{str(e)}")
                except Exception:
                    pass

    finally:
        current_task = None
        is_processing = False


# ── Bot Handlers ─────────────────────────────────────────────────────────

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id):
        await update.message.reply_text("⛔ 无权限")
        return

    await update.message.reply_text(
        "🎬 SOOP VOD 下载机器人\n\n"
        "发送 SOOP VOD 链接或数字 ID 即可自动加入队列\n"
        "支持单视频和多 Part 播放列表\n\n"
        "命令:\n"
        "/start - 显示帮助\n"
        "/queue - 查看下载队列\n"
        "/clear - 清空队列\n"
        "/status - 查看当前任务\n"
        "/disk - 查看磁盘空间\n"
        "/onedrive - 查看 OneDrive 状态",
    )


async def cmd_queue(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id):
        return

    lines = []

    if current_task:
        lines.append(f"🔄 正在处理: {current_task.get('title', '未知')}")
    else:
        lines.append("💤 当前无任务")

    if download_queue:
        lines.append(f"\n📋 队列 ({len(download_queue)} 个):")
        for i, task in enumerate(download_queue, 1):
            lines.append(f"  {i}. {task.get('title', '未知')}")
    else:
        lines.append("\n📋 队列为空")

    await update.message.reply_text("\n".join(lines))


async def cmd_clear(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id):
        return

    count = len(download_queue)
    download_queue.clear()
    await update.message.reply_text(f"🗑 已清空队列 ({count} 个任务已移除)")


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id):
        return

    lines = []

    if current_task:
        lines.append(f"🔄 当前任务: {current_task.get('title', '未知')}")
    else:
        lines.append("✅ 当前无活跃任务")

    lines.append(f"📋 队列: {len(download_queue)} 个待处理")

    await update.message.reply_text("\n".join(lines))


async def cmd_disk(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id):
        return

    result = subprocess.run(["df", "-h", DOWNLOAD_DIR], capture_output=True, text=True)
    dl_files = list(Path(DOWNLOAD_DIR).glob("*"))
    dl_size = sum(f.stat().st_size for f in dl_files if f.is_file())

    await update.message.reply_text(
        f"💾 磁盘状态\n\n{result.stdout}\n"
        f"下载目录文件数: {len(dl_files)}\n"
        f"下载目录大小: {human_size(dl_size)}",
    )


async def cmd_onedrive(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id):
        return

    result = subprocess.run(
        ["rclone", "about", f"{RCLONE_REMOTE}:"],
        capture_output=True, text=True, timeout=15,
    )

    if result.returncode == 0:
        await update.message.reply_text(f"☁️ OneDrive 状态\n\n{result.stdout}")
    else:
        await update.message.reply_text(
            f"❌ rclone 未配置或连接失败\n\n{result.stderr}",
        )


async def handle_url(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle incoming SOOP VOD URLs or bare IDs."""
    if not is_admin(update.effective_user.id):
        await update.message.reply_text("⛔ 无权限")
        return

    text = update.message.text.strip()

    # Extract VOD IDs
    vod_ids = SOOP_URL_PATTERN.findall(text)

    if not vod_ids:
        id_match = SOOP_ID_PATTERN.match(text)
        if id_match:
            vod_ids = [id_match.group(1)]

    if not vod_ids:
        return

    for vod_id in vod_ids:
        url = f"https://vod.sooplive.co.kr/player/{vod_id}"
        await add_to_queue(update, context, url)


async def add_to_queue(update: Update, context: ContextTypes.DEFAULT_TYPE, url: str):
    """Get video info and add to download queue."""
    status_msg = await update.message.reply_text("🔍 获取视频信息...")

    videos = await asyncio.get_event_loop().run_in_executor(None, get_video_info, url)

    if not videos:
        await status_msg.edit_text("❌ 无法获取视频信息，请检查链接是否正确")
        return

    if len(videos) == 1:
        info = videos[0]
        title = info.get("title", "Unknown")
        uploader = info.get("uploader", "Unknown")
        duration = info.get("duration_string", "Unknown")
        resolution = info.get("resolution", "Unknown")

        task = {
            "url": url,
            "title": title,
            "chat_id": update.effective_chat.id,
            "is_playlist": False,
            "part_count": 1,
        }

        download_queue.append(task)
        pos = len(download_queue)
        processing_text = " (正在处理中)" if is_processing else ""

        await status_msg.edit_text(
            f"📥 已加入队列 #{pos}{processing_text}\n\n"
            f"标题: {title}\n"
            f"主播: {uploader}\n"
            f"时长: {duration}\n"
            f"分辨率: {resolution}"
        )
    else:
        playlist_title = videos[0].get("playlist_title") or videos[0].get("title", "Unknown")
        uploader = videos[0].get("uploader", "Unknown")
        total_duration = sum(v.get("duration", 0) for v in videos)

        parts_info = []
        for i, v in enumerate(videos, 1):
            dur = v.get("duration_string", "?")
            res = v.get("resolution", "?")
            parts_info.append(f"  Part {i}: {dur} ({res})")

        task = {
            "url": url,
            "title": playlist_title,
            "chat_id": update.effective_chat.id,
            "is_playlist": True,
            "part_count": len(videos),
        }

        download_queue.append(task)
        pos = len(download_queue)
        processing_text = " (正在处理中)" if is_processing else ""

        await status_msg.edit_text(
            f"📥 已加入队列 #{pos}{processing_text}\n\n"
            f"标题: {playlist_title} ({len(videos)} Parts)\n"
            f"主播: {uploader}\n"
            f"总时长: {human_duration(total_duration)}\n\n"
            + "\n".join(parts_info)
        )

    # Start queue worker if not running
    if not is_processing:
        asyncio.create_task(queue_worker(context.application))


async def post_init(app: Application):
    """Set bot commands menu after startup."""
    commands = [
        BotCommand("start", "显示帮助"),
        BotCommand("queue", "查看下载队列"),
        BotCommand("clear", "清空队列"),
        BotCommand("status", "查看当前任务"),
        BotCommand("disk", "查看磁盘空间"),
        BotCommand("onedrive", "查看 OneDrive 状态"),
    ]
    await app.bot.set_my_commands(commands)
    logger.info("Bot commands menu set")


# ── Main ─────────────────────────────────────────────────────────────────

def main():
    logger.info("Starting SOOP VOD Downloader Bot...")

    defaults = Defaults(link_preview_options=LinkPreviewOptions(is_disabled=True))
    app = Application.builder().token(TG_TOKEN).defaults(defaults).post_init(post_init).build()

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("queue", cmd_queue))
    app.add_handler(CommandHandler("clear", cmd_clear))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("disk", cmd_disk))
    app.add_handler(CommandHandler("onedrive", cmd_onedrive))

    app.add_handler(MessageHandler(
        filters.TEXT & ~filters.COMMAND & (filters.Regex(SOOP_URL_PATTERN) | filters.Regex(SOOP_ID_PATTERN)),
        handle_url,
    ))

    logger.info("Bot is running!")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
