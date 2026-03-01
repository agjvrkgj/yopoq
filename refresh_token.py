#!/usr/bin/env python3
"""Refresh rclone OneDrive token - supports Client Credentials and ROPC."""
import requests
import json
import time
import os

TENANT_ID = os.environ.get("AZ_TENANT_ID", "")
CLIENT_ID = os.environ.get("AZ_CLIENT_ID", "")
CLIENT_SECRET = os.environ.get("AZ_CLIENT_SECRET", "")
USERNAME = os.environ.get("AZ_USERNAME", "")
PASSWORD = os.environ.get("AZ_PASSWORD", "")
GRANT_MODE = os.environ.get("GRANT_MODE", "client_credentials")
DRIVE_USER = os.environ.get("DRIVE_USER", "")
RCLONE_CONF = "/root/.config/rclone/rclone.conf"

# Load from azure_config.json if exists
_config_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "azure_config.json")
if os.path.exists(_config_file):
    with open(_config_file) as f:
        _cfg = json.load(f)
        TENANT_ID = TENANT_ID or _cfg.get("tenant_id", "")
        CLIENT_ID = CLIENT_ID or _cfg.get("client_id", "")
        CLIENT_SECRET = CLIENT_SECRET or _cfg.get("client_secret", "")
        USERNAME = USERNAME or _cfg.get("username", "")
        PASSWORD = PASSWORD or _cfg.get("password", "")
        GRANT_MODE = _cfg.get("grant_mode", GRANT_MODE)
        DRIVE_USER = _cfg.get("drive_user", DRIVE_USER)


def refresh_token():
    if not all([TENANT_ID, CLIENT_ID, CLIENT_SECRET]):
        print("[!] Azure credentials not configured, skipping token refresh")
        return False

    url = f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token"

    if GRANT_MODE == "ropc" and USERNAME and PASSWORD:
        # ROPC: uses user's credentials directly
        data = {
            "grant_type": "password",
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "scope": "https://graph.microsoft.com/.default offline_access",
            "username": USERNAME,
            "password": PASSWORD,
        }
    else:
        # Client Credentials: app-only, no user credentials needed
        data = {
            "grant_type": "client_credentials",
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "scope": "https://graph.microsoft.com/.default",
        }

    resp = requests.post(url, data=data)
    token = resp.json()

    if "access_token" not in token:
        print(f"[!] Token refresh failed: {token.get('error_description', 'unknown')}")
        return False

    headers = {"Authorization": f"Bearer {token['access_token']}"}

    # Client credentials uses /users/{id}/drive, ROPC uses /me/drive
    if GRANT_MODE != "ropc" or not USERNAME:
        if DRIVE_USER:
            drive_url = f"https://graph.microsoft.com/v1.0/users/{DRIVE_USER}/drive"
        else:
            print("[!] Client credentials mode requires drive_user in azure_config.json")
            print("[!] Set drive_user to the user's email or ID")
            return False
    else:
        drive_url = "https://graph.microsoft.com/v1.0/me/drive"

    drive_resp = requests.get(drive_url, headers=headers)
    drive_info = drive_resp.json()

    if "id" not in drive_info:
        print(f"[!] Failed to get drive info: {drive_info.get('error', {}).get('message', 'unknown')}")
        return False

    drive_id = drive_info.get("id", "")
    drive_type = drive_info.get("driveType", "business")

    rclone_token = {
        "access_token": token["access_token"],
        "token_type": token.get("token_type", "Bearer"),
        "refresh_token": token.get("refresh_token", ""),
        "expiry": time.strftime(
            "%Y-%m-%dT%H:%M:%S.000000000+00:00",
            time.gmtime(time.time() + token.get("expires_in", 3600)),
        ),
    }

    config = f"""[onedrive]
type = onedrive
client_id = {CLIENT_ID}
client_secret = {CLIENT_SECRET}
drive_id = {drive_id}
drive_type = {drive_type}
token = {json.dumps(rclone_token)}
"""

    os.makedirs(os.path.dirname(RCLONE_CONF), exist_ok=True)
    with open(RCLONE_CONF, "w") as f:
        f.write(config)

    print(f"[*] Token refreshed ({GRANT_MODE}), expires in {token.get('expires_in', '?')}s")
    return True


if __name__ == "__main__":
    if refresh_token():
        print("[*] ✅ Token refresh successful")
    else:
        print("[!] ❌ Token refresh failed")
        exit(1)
