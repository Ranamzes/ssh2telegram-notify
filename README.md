# SSH to Telegram Notification Setup Guide

This guide explains how to set up Telegram notifications for SSH logins on your Linux server.

## Prerequisites

- Linux server with SSH access
- Root or sudo privileges
- curl installed
- jq installed (for JSON parsing)
- Telegram account

1. **Install required packages:**

```bash
# For Debian/Ubuntu
sudo apt-get update
sudo apt-get install -y curl jq

# For CentOS/RHEL
sudo yum install -y curl jq

# For Alpine Linux
apk add curl jq

# For Arch Linux
pacman -S curl jq
```

## Step 1: Create Telegram Bot

1. Open Telegram and search for @BotFather
2. Send `/newbot` command
3. Follow instructions to create bot
4. Save the bot token
5. Start chat with your bot
6. Get chat ID:
   - Send a message to your bot
   - Visit: `https://api.telegram.org/bot<YourBOTToken>/getUpdates`
   - Find "chat":{"id":XXXXXXXXX}

## Step 2: Get IPInfo Token

1. Register at [ipinfo.io](https://ipinfo.io)
2. Get your token from [token page](https://ipinfo.io/account/token)
3. Free plan includes 50,000 requests per month

## Step 3: Create Notification Script

Create the script file. DON'T FORGET TO PUT YOUR DATA IN THE VARIABLES!:

```bash
sudo tee /usr/local/bin/ssh2tg.sh << 'EOF'
#!/usr/bin/env bash

#-----------------------EDIT THESE VARIABLES-----------------------#

TOKEN="YOUR_IPINFO_TOKEN"
KEY="YOUR_TELEGRAM_BOT_TOKEN"
TARGET="YOUR_TELEGRAM_CHAT_ID"
IGNORE_IPS="" # Space-separated list of IPs to ignore

#------------------------------------------------------------------#

# Function to check if IP should be ignored
is_ip_ignored() {
    local ip="$1"
    for ignore_ip in $IGNORE_IPS; do
        if [ "$ip" = "$ignore_ip" ]; then
            return 0  # True, IP should be ignored
        fi
    done
    return 1  # False, IP should not be ignored
}

# Exit if not session opening
if [ "$PAM_TYPE" != "open_session" ]; then
    logger -t ssh2tg "Skipping notification for PAM_TYPE=$PAM_TYPE"
    exit 0
fi

# Check if IP should be ignored
if is_ip_ignored "$PAM_RHOST"; then
    logger -t ssh2tg "Skipping notification for ignored IP: $PAM_RHOST"
    exit 0
fi

# Check for required dependency
if ! command -v jq &> /dev/null; then
    logger -t ssh2tg "Error: jq is not installed. Please install it first."
    exit 1
fi

# Debug logging
exec 1> >(logger -t ssh2tg) 2>&1
logger -t ssh2tg "Script started for user $PAM_USER from $PAM_RHOST"

# Lock file mechanism
LOCK_FILE="/tmp/ssh2tg_${PAM_USER}_${PAM_RHOST}.lock"
LOCK_TIMEOUT=5  # seconds

if [ -f "$LOCK_FILE" ]; then
    LOCK_TIME=$(stat -c %Y "$LOCK_FILE")
    CURRENT_TIME=$(date +%s)
    if [ $((CURRENT_TIME - LOCK_TIME)) -lt $LOCK_TIMEOUT ]; then
        logger -t ssh2tg "Skipping duplicate notification"
        exit 0
    fi
fi

touch "$LOCK_FILE"

# Configuration
URL="https://api.telegram.org/bot$KEY/sendMessage"
DATE1="$(date "+%H:%M:%S")"
DATE2="$(date "+%d %B %Y")"

# Get real hostname
SERVER_NAME=$(hostname -s)

# Enhanced GEO data handling with better JSON parsing
logger -t ssh2tg "Fetching GEO data for $PAM_RHOST"
GEO_RESPONSE=$(curl -s "ipinfo.io/$PAM_RHOST?token=$TOKEN")
logger -t ssh2tg "GEO Response: $GEO_RESPONSE"

# Parse GEO data using jq
CITY=$(echo "$GEO_RESPONSE" | jq -r '.city // empty')
REGION=$(echo "$GEO_RESPONSE" | jq -r '.region // empty')
COUNTRY=$(echo "$GEO_RESPONSE" | jq -r '.country // empty')
ORG=$(echo "$GEO_RESPONSE" | jq -r '.org // empty')
POSTAL=$(echo "$GEO_RESPONSE" | jq -r '.postal // empty')
TIMEZONE=$(echo "$GEO_RESPONSE" | jq -r '.timezone // empty')
LOC=$(echo "$GEO_RESPONSE" | jq -r '.loc // empty')
REMOTE_HOSTNAME=$(echo "$GEO_RESPONSE" | jq -r '.hostname // empty')

# Basic system info
MEMORY=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
LOAD=$(uptime | awk -F'average:' '{print $2}' | xargs)

# Build location details
LOCATION_INFO=""
[ ! -z "$CITY" ] && LOCATION_INFO+="• City: $CITY"$'\n'
[ ! -z "$REGION" ] && LOCATION_INFO+="• Region: $REGION"$'\n'
[ ! -z "$COUNTRY" ] && LOCATION_INFO+="• Country: $COUNTRY"$'\n'
[ ! -z "$POSTAL" ] && LOCATION_INFO+="• Postal Code: $POSTAL"$'\n'
[ ! -z "$TIMEZONE" ] && LOCATION_INFO+="• Timezone: $TIMEZONE"$'\n'

# Add Maps link if coordinates available
[ ! -z "$LOC" ] && LOCATION_INFO+="• Maps: https://www.google.com/maps?q=${LOC}"$'\n'

# Build network details
NETWORK_INFO=""
[ ! -z "$ORG" ] && NETWORK_INFO+="• Provider: $ORG"$'\n'
[ ! -z "$REMOTE_HOSTNAME" ] && NETWORK_INFO+="• Remote Hostname: $REMOTE_HOSTNAME"$'\n'

# Remove trailing newlines
LOCATION_INFO=${LOCATION_INFO%$'\n'}
NETWORK_INFO=${NETWORK_INFO%$'\n'}

# Build message with proper formatting using $'\n' for newlines
TEXT="🔐 *$PAM_USER* logged in to *$SERVER_NAME*
⏰ Time: $DATE1
📅 Date: $DATE2
🌍 Address: $PAM_RHOST
🔧 Service: $PAM_SERVICE
💻 TTY: $PAM_TTY

📊 System:
• Memory: $MEMORY
• Load: $LOAD"

# Add location details if not empty
if [ ! -z "$LOCATION_INFO" ]; then
    TEXT+=$'\n\n'
    TEXT+="📍 Location Details:"$'\n'
    TEXT+="$LOCATION_INFO"
fi

# Add network details if not empty
if [ ! -z "$NETWORK_INFO" ]; then
    TEXT+=$'\n\n'
    TEXT+="🌐 Network Details:"$'\n'
    TEXT+="$NETWORK_INFO"
fi

PAYLOAD="chat_id=$TARGET&text=$TEXT&parse_mode=Markdown&disable_web_page_preview=true"

logger -t ssh2tg "Sending notification"
curl -s --max-time 10 --retry 5 --retry-delay 2 --retry-max-time 10 -d "$PAYLOAD" $URL

# Cleanup old lock files
find /tmp -name "ssh2tg_*.lock" -mmin +1 -delete
EOF
```

## Step 4: Set Permissions

Set correct permissions for the script:

```bash
sudo chmod 755 /usr/local/bin/ssh2tg.sh
```

## Step 5: Configure PAM

1. Create PAM configuration file:

```bash
sudo tee /etc/pam.d/sshd-notify << 'EOF'
session optional pam_exec.so /usr/local/bin/ssh2tg.sh expose_authtok
EOF
```

2. Add include to SSH PAM configuration:

```bash
sudo sed -i '/sshd-notify/d' /etc/pam.d/sshd
echo "@include sshd-notify" | sudo tee -a /etc/pam.d/sshd
```

## Step 6: Restart SSH Service

Restart SSH service to apply changes:

```bash
sudo systemctl restart ssh
```

## Testing

1. Log out from your SSH session
2. Log in again
3. Check Telegram for notification
4. Check logs if needed:
   ```bash
   sudo journalctl -t ssh2tg
   ```

## Troubleshooting

### No notifications
- Check if bot token is correct
- Verify chat ID
- Check script permissions
- Review logs: `sudo journalctl -t ssh2tg`
- Verify UsePAM is enabled in SSH config
	`sudo sed -i 's/^UsePAM no/UsePAM yes/' /etc/ssh/sshd_config; sudo systemctl restart ssh`
