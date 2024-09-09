#!/bin/bash
# Set the path to the .env file
ENV_FILE=".env"

# Check if the .env file exists
if [ ! -f "$ENV_FILE" ]; then
  # If the file does not exist, prompt the user for the username and password
  read -p "Enter the username: " USER
  read -s -p "Enter the password: " PASS
  echo ""

  # Encode the username and password using base64
  ENCODED_USER=$(echo -n "$USER" | base64)
  ENCODED_PASS=$(echo -n "$PASS" | base64)

  # Create the .env file and write the encoded username and password to it
  echo "ENCODED_USER=$ENCODED_USER" > "$ENV_FILE"
  echo "ENCODED_PASS=$ENCODED_PASS" >> "$ENV_FILE"
  echo "LAST_IP=" >> "$ENV_FILE"
else
  # If the file exists, read the values from it
  source "$ENV_FILE"
  # Decode the username and password
  USER=$(echo -n "$ENCODED_USER" | base64 -d)
  PASS=$(echo -n "$ENCODED_PASS" | base64 -d)
fi

IP=999.999.999.999

# Check if the IP address and fan speed were passed as arguments
if [ $# -eq 2 ]; then
  IP=$1
  FAN_SPEED=$2
else
  # Check if the last used IP is set
  if [ -n "$LAST_IP" ]; then
    # Ask the user if they would like to interact with the same host again
    read -p "Would you like to interact with $LAST_IP again? (y/n): " RESPONSE
    if [ "$RESPONSE" = "y" ]; then
      IP=$LAST_IP
    else
      # Prompt the user for the IP address
      read -p "Enter the IP address: " IP
    fi
  else
    # Prompt the user for the IP address
    read -p "Enter the IP address: " IP
  fi

  # Validate the IP address
  while ! [[ $IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; do
    read -p "Invalid IP address. Please enter a valid IP address: " IP
  done

  # Cache the last used IP
echo "LAST_IP=$IP" > temp.env
grep -v "^LAST_IP=" "$ENV_FILE" >> temp.env
mv temp.env "$ENV_FILE"

 CURRENT_FAN_SPEED=$(ipmitool -I lanplus -H $IP -U $USER -P $PASS sensor reading Fan1 | awk '{print $NF}')
  if [ $? -ne 0 ]; then
    echo "Error: Failed to retrieve current fan speed"
    exit 1
  fi

  # Calculate the percentage based on the current fan speed in RPM
  CURRENT_FAN_SPEED_PERCENTAGE=$(echo "scale=2; ($CURRENT_FAN_SPEED / 1320) * 17" | bc)
  echo "Current fan speed: $CURRENT_FAN_SPEED RPM ($CURRENT_FAN_SPEED_PERCENTAGE%)"
  # Prompt the user for the desired fan speed in percentage (0-100)
  read -p "Enter the desired fan speed in percentage (0-100): " FAN_SPEED
fi

# Validate the input fan speed
while ! [[ $FAN_SPEED =~ ^[0-9]+$ ]] || [ $FAN_SPEED -lt 0 ] || [ $FAN_SPEED -gt 100 ]; do
  read -p "Invalid input. Please enter a valid fan speed in percentage (0-100): " FAN_SPEED
done

FAN_SPEED_HEX=$(printf '%x\n' $FAN_SPEED)

# Use the decoded credentials and user input IP in the ipmitool command
ipmitool -I lanplus -U $USER -P $PASS -H $IP raw 0x30 0x30 0x01 0x00
ipmitool -I lanplus -H $IP -U $USER -P $PASS raw 0x30 0x30 0x02 0xff 0x$FAN_SPEED_HEX
