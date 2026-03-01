"""Configuration template for SOOP VOD Downloader Bot"""

# Telegram
TG_TOKEN = "YOUR_BOT_TOKEN"
ADMIN_ID = 123456789

# Paths
DOWNLOAD_DIR = "/opt/soop-downloader/downloads"
LOG_DIR = "/opt/soop-downloader/logs"

# Rclone
RCLONE_REMOTE = "onedrive"
RCLONE_DEST = "SOOP_VOD"

# yt-dlp
YTDLP_FORMAT = "best"

# SOOP Account (for age-restricted content, leave empty if not needed)
SOOP_USERNAME = ""
SOOP_PASSWORD = ""
