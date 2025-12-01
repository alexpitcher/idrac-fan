#!/bin/bash

# Default values
VERBOSE=false
IP=""
USER=""
PASS=""
FAN_SPEED=""
DEVICE_ID=""
LIBRENMS_API_URL=""
LIBRENMS_API_TOKEN=""
ENV_FILE=".env"

# --- Logging ---
log_debug() {
  if [ "$VERBOSE" = true ]; then
    echo "[DEBUG] $1"
  fi
}

# --- Configuration Management ---
load_config() {
  if [ -f "$ENV_FILE" ]; then
    log_debug "Loading configuration from $ENV_FILE"
    source "$ENV_FILE"
    # Base64 decode credentials
    if [[ -n "$ENCODED_USER" ]]; then
      USER=$(echo -n "$ENCODED_USER" | base64 -d)
    fi
    if [[ -n "$ENCODED_PASS" ]]; then
      PASS=$(echo -n "$ENCODED_PASS" | base64 -d)
    fi
  else
    initial_setup
  fi
}

initial_setup() {
  echo "--- Initial Setup ---"
  echo "This script needs to be configured to connect to your iDRAC."
  
  read -p "Enter iDRAC IP Address: " IP
  read -p "Enter iDRAC Username: " USER
  read -s -p "Enter iDRAC Password: " PASS
  echo ""
  
  read -p "Do you want to configure optional LibreNMS integration for temperature monitoring? (y/n): " lnms_choice
  if [[ "$lnms_choice" == "y" || "$lnms_choice" == "Y" ]]; then
    read -p "Enter LibreNMS API URL: " LIBRENMS_API_URL
    read -p "Enter LibreNMS API Token: " LIBRENMS_API_TOKEN
    read -p "Enter LibreNMS Device ID for this server: " DEVICE_ID
  fi
  
  save_config
  echo "Configuration saved to $ENV_FILE. You can edit this file manually later."
}

save_config() {
  ENCODED_USER=$(echo -n "$USER" | base64)
  ENCODED_PASS=$(echo -n "$PASS" | base64)
  
  echo "ENCODED_USER=$ENCODED_USER" > "$ENV_FILE"
  echo "ENCODED_PASS=$ENCODED_PASS" >> "$ENV_FILE"
  echo "LAST_IP=$IP" >> "$ENV_FILE"
  echo "LIBRENMS_API_URL=$LIBRENMS_API_URL" >> "$ENV_FILE"
  echo "LIBRENMS_API_TOKEN=$LIBRENMS_API_TOKEN" >> "$ENV_FILE"
  echo "DEVICE_ID=$DEVICE_ID" >> "$ENV_FILE"
  
  log_debug "Configuration saved."
}

# --- LibreNMS Integration ---
fetch_core_temperatures() {
  if [ -z "$LIBRENMS_API_URL" ] || [ -z "$LIBRENMS_API_TOKEN" ] || [ -z "$DEVICE_ID" ]; then
    log_debug "LibreNMS not configured or device ID missing. Skipping temperature check."
    return
  fi
  
  log_debug "Fetching core temperatures from LibreNMS API..."
  response=$(curl -s -H "X-Auth-Token: $LIBRENMS_API_TOKEN" "$LIBRENMS_API_URL/devices/$DEVICE_ID/health/temperature")
  
  # Check if curl failed or response is not valid JSON
  if [ $? -ne 0 ] || ! echo "$response" | jq -e . >/dev/null 2>&1; then
      echo "[WARNING] Failed to fetch or parse temperature data from LibreNMS."
      return
  fi

  core_temperatures=$(echo "$response" | jq '.health | map(.current) | .[]')
  log_debug "Core temperatures: $core_temperatures"

  for temp in $core_temperatures; do
    if (( $(echo "$temp > 60" | bc -l) )); then
      echo "[WARNING] High Temperature Alert! A core temperature is above 60°C ($temp°C). Consider a higher fan speed."
      break
    fi
  done
}

# --- Main Logic ---
# Load existing config file or run initial setup
load_config

# Parse command-line arguments
# This will override any values from the .env file
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --ip)
      IP="$2"
      shift; shift
      ;;
    --speed)
      FAN_SPEED="$2"
      shift; shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    *) # unknown option
      shift
      ;;
  esac
done

log_debug "Starting script execution..."

# --- Interactive Mode (if variables are not set) ---
if [ -z "$IP" ]; then
  read -p "Use last saved IP ($LAST_IP)? (y/n): " use_last_ip
  if [[ "$use_last_ip" == "y" || "$use_last_ip" == "Y" ]]; then
    IP=$LAST_IP
  else
    read -p "Enter iDRAC IP Address: " IP
  fi
fi

# Validate IP
if ! [[ $IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "[ERROR] Invalid IP address format."
  exit 1
fi

# Temperature check
fetch_core_temperatures

if [ -z "$FAN_SPEED" ]; then
  read -p "Enter desired fan speed (0-100): " FAN_SPEED
fi

# Validate Fan Speed
if ! [[ $FAN_SPEED =~ ^[0-9]+$ ]] || [ $FAN_SPEED -lt 0 ] || [ $FAN_SPEED -gt 100 ]; then
  echo "[ERROR] Invalid fan speed. Must be between 0 and 100."
  exit 1
fi

# --- IPMI Commands ---
FAN_SPEED_HEX=$(printf '%x\n' $FAN_SPEED)
log_debug "Setting fan speed to $FAN_SPEED% (0x$FAN_SPEED_HEX)"

log_debug "Sending command to enable manual fan control..."
output_enable=$(ipmitool -I lanplus -H "$IP" -U "$USER" -P "$PASS" raw 0x30 0x30 0x01 0x00 2>&1)
if [ $? -ne 0 ]; then
  echo "[ERROR] Failed to enable manual fan control. IPMItool output:"
  echo "$output_enable"
  exit 1
fi
log_debug "Manual fan control enabled."

log_debug "Sending command to set fan speed..."
output_set=$(ipmitool -I lanplus -H "$IP" -U "$USER" -P "$PASS" raw 0x30 0x30 0x02 0xff 0x"$FAN_SPEED_HEX" 2>&1)

if [ $? -eq 0 ]; then
  echo "Successfully set fan speed to $FAN_SPEED% on $IP."
else
  echo "[ERROR] Failed to set fan speed. Analyzing error..."
  if echo "$output_set" | grep -q "unauthorized name"; then
    echo "[ERROR] Authentication failed: Incorrect username."
  elif echo "$output_set" | grep -q "RAKP 2 HMAC is invalid"; then
    echo "[ERROR] Authentication failed: Incorrect password."
  elif echo "$output_set" | grep -q "Get Auth Capabilities error"; then
    echo "[ERROR] Connection failed: Incorrect IP address or IPMI not enabled."
  else
    echo "[ERROR] An unknown error occurred. IPMItool output:"
    echo "$output_set"
  fi
  exit 1
fi

# Save the last used IP for next time
if [ "$IP" != "$LAST_IP" ]; then
    log_debug "Saving new IP to config."
    # This is a bit inefficient but safe
    sed -i.bak "s/^LAST_IP=.*/LAST_IP=$IP/" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
fi

log_debug "Script finished."
