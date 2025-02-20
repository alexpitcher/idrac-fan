# iDRAC-Fan

Dell iDRAC fan control automation. This script works on iDRAC versions up to 3.30.30.30. You can run this on your local machine, ideally macOS or Linux. If you're using Windows, it's recommended to use WSL (Windows Subsystem for Linux).
## Prerequisites

Before running the script, ensure you meet the following requirements:

1. **`ipmitool` must be installed**:

- On **Ubuntu/Debian**:
```bash

sudo apt install ipmitool

```
- On **macOS** (using Homebrew):
```bash

brew install ipmitool

```

2. **IPMI over LAN must be enabled** in the iDRAC settings:

- Navigate to `iDRAC -> iDRAC Settings -> Network` and ensure IPMI over LAN is enabled.

3. **User Permissions**:

- Your user must have permission to access IPMI. The default `root` user typically has permission.
## Features

- **Credentials Management**: The script securely stores and manages your iDRAC credentials in a `.env` file, encoded using base64.
- **Input Validation**: It validates the IP address and fan speed inputs.
- **Error Handling**: Provides clear error messages for issues such as incorrect credentials or IP address.
- **IP Caching**: It caches the last used IP address for convenience, so you don't need to enter it every time.
- **LibreNMS API Integration**: The script now interacts with the LibreNMS API to fetch core temperatures of the server using the provided device ID.
- **Temperature-Based Fan Speed Suggestion**: If any core temperature exceeds 60 degrees Celsius, the script suggests increasing the fan speed.

## Quick Start

To quickly download and run the script, use the following one-liner:

`bash <(curl -s https://raw.githubusercontent.com/alexpitcher/idrac-fan/refs/heads/main/main.sh)
`
Alternatively, if you prefer using `wget`:

`bash <(wget -qO- https://raw.githubusercontent.com/alexpitcher/idrac-fan/refs/heads/main/main.sh)`

This command will fetch the script from GitHub and execute it directly on your system.
## Script Usage

### Running the Script

To run the script manually, use this command:

`chmod +x ipmi_fan_control.sh`
`/ipmi_fan_control.sh [--verbose] [DEVICE_ID] [IP_ADDRESS] [FAN_SPEED]`

#### Arguments:

- `--verbose` (optional): Enables verbose logging, outputting debug messages for troubleshooting.
- `DEVICE_ID`: The device ID of the Proxmox server (Dell server where iDRAC is running). If not provided, you will be prompted for it.
- `IP_ADDRESS`: The IP address of the iDRAC interface. If not provided, you will be prompted for it.
- `FAN_SPEED`: The desired fan speed in percentage (0-100). If not provided, you will be prompted for it.

Example:

`./ipmi_fan_control.sh --verbose 12345 192.168.1.100 75`

This example runs the script in verbose mode, fetches core temperatures from the LibreNMS API for device ID `12345`, connects to `192.168.1.100`, and sets the fan speed to 75%.

### `.env` File

The script uses a `.env` file to store the encoded credentials (username and password) and the last used IP address. This file is created if it doesn't exist, and you will be prompted to enter your credentials.

#### Example `.env` File:
```
ENCODED_USER=dXNlcjE=
ENCODED_PASS=cGFzc3dvcmQxMjM=
LAST_IP=192.168.1.100
LIBRENMS_API_URL=https://librenms.example.com/api/v0
LIBRENMS_API_TOKEN=your_api_token_here
```
The credentials are stored in base64 encoded form to ensure they are not in plain text.

### Error Handling

The script checks for common error messages from `ipmitool`:

- **Incorrect Username**: Authentication fails with the message `RAKP 2 message indicates an error : unauthorized name`.
- **Incorrect Password**: Authentication fails with the message `RAKP 2 HMAC is invalid`.
- **Incorrect IP Address**: The IP address may be unreachable, with the error message `Get Auth Capabilities error`.

If the fan speed cannot be set, the script will provide additional details from the `ipmitool` output.

#### Example Output:
```[DEBUG] Starting script execution...
[DEBUG] Fetching core temperatures from LibreNMS API...
[DEBUG] Core temperatures: 55 62 58
Warning: Some cores have temperatures exceeding 60 degrees Celsius. Consider increasing the fan speed.
[DEBUG] Sending IPMI command to initialize fan control with verbose output...
[DEBUG] Successfully initialized fan control.
[DEBUG] Sending IPMI command to set fan speed with verbose output...
[ERROR] Authentication failed: Incorrect password.
```
### Debugging

Enable verbose output by running the script with the `--verbose` flag. This will print debug messages to help you understand the script's execution and troubleshoot issues.

## License

This script is provided under the MIT License. Feel free to modify and use it as needed.
