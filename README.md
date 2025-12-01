# iDRAC Fan Control

A simple and flexible script for controlling Dell iDRAC fan speeds.

This script allows you to manually set the fan speed on your Dell server using IPMI. It provides a user-friendly interactive setup for first-time use and powerful command-line options for automation and advanced use.

Works on iDRAC versions up to 3.30.30.30. It can be run on macOS, Linux, or Windows (via WSL).

## Prerequisites

1.  **`ipmitool`**: Must be installed on your system.
    *   **Ubuntu/Debian**: `sudo apt install ipmitool`
    *   **macOS (Homebrew)**: `brew install ipmitool`
    *   **Other**: Check your package manager.

2.  **IPMI over LAN**: Must be enabled in your iDRAC settings (`iDRAC Settings -> Network`).

3.  **Required Dependencies for Temperature Monitoring**:
    *   **`jq`**: For parsing temperature data. Install with `sudo apt install jq` or `brew install jq`.
    *   **`bc`**: For floating-point number comparison. Install with `sudo apt install bc` or `brew install bc`.

## Features

-   **Interactive First-Time Setup**: Guides you through configuring the script on the first run.
-   **Secure Credential Storage**: Saves your credentials (base64 encoded) in a local `.env` file.
-   **Command-Line Arguments**: Override settings for non-interactive use.
-   **Optional LibreNMS Integration**: Fetches server temperatures and warns you if they are high (e.g., >60°C).
-   **IP Caching**: Remembers the last used IP address for quick re-use.
-   **Clear Error Handling**: Provides understandable error messages for common IPMI issues.

## Quick Start

1.  **Download the script**:
    ```bash
    curl -O https://raw.githubusercontent.com/alexpitcher/idrac-fan/main/main.sh
    # Or with wget:
    # wget https://raw.githubusercontent.com/alexpitcher/idrac-fan/main/main.sh
    ```

2.  **Make it executable**:
    ```bash
    chmod +x main.sh
    ```

3.  **Run it!**
    ```bash
    ./main.sh
    ```
    The first time you run it, it will guide you through the setup process.

## Usage

### Interactive Mode

Simply run the script without any arguments:

```bash
./main.sh
```

-   On the first run, it will prompt you for your iDRAC IP/credentials and optionally for LibreNMS details.
-   On subsequent runs, it will ask if you want to reuse the last IP and then prompt you for the desired fan speed.

### Non-Interactive (Command-Line) Mode

You can override the stored configuration using command-line flags. This is ideal for scripts or automation.

**Arguments:**

-   `--ip <IP_ADDRESS>`: The IP address of the iDRAC interface.
-   `--speed <PERCENTAGE>`: The desired fan speed (0-100).
-   `--verbose`: Enables verbose logging for debugging.

**Example:**

```bash
./main.sh --ip 192.168.1.100 --speed 20 --verbose
```

This command sets the fan speed to 20% on the iDRAC at `192.168.1.100` with debug output enabled.

## Configuration File (`.env`)

The script uses a `.env` file to store your configuration. It's created automatically during the initial setup.

**Example `.env` file:**

```
ENCODED_USER=cm9vdA==
ENCODED_PASS=cGFzc3dvcmQ=
LAST_IP=192.168.1.100
LIBRENMS_API_URL=https://librenms.example.com/api/v0
LIBRENMS_API_TOKEN=your_api_token
DEVICE_ID=12
```

-   `ENCODED_USER` / `ENCODED_PASS`: Your iDRAC credentials, encoded in base64.
-   `LAST_IP`: The last IP address you successfully connected to.
-   `LIBRENMS_API_URL` / `LIBRENMS_API_TOKEN` / `DEVICE_ID`: Optional settings for temperature monitoring. If these are blank, the feature will be skipped.

## License

This project is licensed under the MIT License.
