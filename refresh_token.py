#!/usr/bin/env python3
"""Refresh rclone OneDrive token via ROPC (Resource Owner Password Credentials)."""
import requests
import json
import time
import os

# Azure credentials - set via environment or edit directly
TENANT_ID = os.environ.get("AZ_TENANT_ID", "")
CLIENT_ID = os.environ.get("AZ_CLIENT_ID", "")
CLIENT_SECRET = os.environ.get("AZ_CLIENT_SECRET", "")
USERNAME = os.environ.get("AZ_USERNAME", "")
PASSWORD = os.environ.get("AZ_PASSWORD", "")
RCLONE_CONF = os.environ.get("RCLONE_CONF", "/root/.config/rclone/rclone.conf")

# Try loading from config file in same directory
_config_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "azure_config.json")
if os.path.exists(_config_file):
    with open(_config_file) as f:
        _cfg = json.load(f)
        TENANT_ID = TENANT_ID or _cfg.get("tenant_id", "")
        CLIENT_ID = CLIENT_ID or _cfg.get("client_id", "")
        CLIENT_SECRET = CLIENT_SECRET or _cfg.get("client_secret", "")
        USERNAME = USERNAME or _cfg.get("username", "")
        PASSWORD = PASSWORD or _cfg.get("password", "")


def refresh_token():
    if not all([TENANT_ID, CLIENT_ID, CLIENT_SECRET, USERNAME, PASSWORD]):
        print("[!] Azure credentials not configured, skipping token refresh")
        return False

    url = f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token"
    data = {
        "grant_type": "password",
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "scope": "https://graph.microsoft.com/.default offline_access",
        "username": USERNAME,
        "password": PASSWORD,
    }

    resp = requests.post(url, data=data)
    token = resp.json()

    if "access_token" not in token:
        print(f"[!] Token refresh failed: {token.get('error_description', 'unknown')}")
        return False

    headers = {"Authorization": f"Bearer {token['access_token']}"}
    drive_resp = requests.get("https://graph.microsoft.com/v1.0/me/drive", headers=headers)
    drive_info = drive_resp.json()
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

    print(f"[*] Token refreshed, expires in {token.get('expires_in', '?')}s")
    return True


if __name__ == "__main__":
    if refresh_token():
        print("[*] ✅ Token refresh successful")
    else:
        print("[!] ❌ Token refresh failed")
        exit(1)
