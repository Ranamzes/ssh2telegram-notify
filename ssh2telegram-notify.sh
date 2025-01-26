#!/usr/bin/env bash

#-----------------------EDIT THESE VARIABLES-----------------------#

TOKEN="YOUR_IPINFO_TOKEN"
KEY="YOUR_TELEGRAM_BOT_TOKEN"
TARGET="YOUR_TELEGRAM_CHAT_ID"

#------------------------------------------------------------------#

# Exit if not session opening
if [ "$PAM_TYPE" != "open_session" ]; then
    logger -t ssh2tg "Skipping notification for PAM_TYPE=$PAM_TYPE"
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
