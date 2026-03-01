"""Configuration template for SOOP VOD Downloader Bot"""

# Telegram
TG_TOKEN = "YOUR_BOT_TOKEN"
ADMIN_ID = 123456789

# Paths
DOWNLOAD_DIR = "/opt/soop-downloader/downloads"
LOG_DIR = "/opt/soop-downloader/logs"

# Rclone - Multiple OneDrive accounts
# Format: {display_name: {"remote": "rclone_remote_name", "dest": "folder_name"}}
# Each account needs a separate rclone remote configured via 'rclone config'
ONEDRIVE_ACCOUNTS = {
    "主账号": {"remote": "onedrive", "dest": "SOOP_VOD"},
    # "备用账号": {"remote": "onedrive2", "dest": "SOOP_VOD"},
}

# Default account
DEFAULT_ONEDRIVE = "主账号"

# yt-dlp
YTDLP_FORMAT = "best"

# SOOP Account (for age-restricted content, leave empty if not needed)
SOOP_USERNAME = ""
SOOP_PASSWORD = ""
