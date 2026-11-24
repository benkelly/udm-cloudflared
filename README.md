# udm-cloudflared

udm-cloudflared installs `cloudflared` on a UniFi gateway and keeps it there after firmware updates.
`cloudflared` is the connector, the program that links your network to a Cloudflare Tunnel.

The main use is a replica.
A replica is a second connector for the same tunnel.
If the host of your first connector stops, the tunnel stays up through the gateway.

Ubiquiti and Cloudflare do not support this installation.
You use it at your own risk.

Tested on a UDM SE with UniFi OS 6.0.17 and `cloudflared` 2026.11.2, in November 2026.

## How it works

The script puts the `cloudflared` binary and your tunnel token in `/data/cloudflared`.
UniFi OS keeps the `/data` directory during a restart and during a firmware update.
The script then creates a systemd service that starts `cloudflared` when the gateway starts.
The script uses no containers.

The script puts the service files in `/etc/systemd/system`.
On the test gateway, firmware updates kept the files in that directory.
If an update removes them, the `restore` command puts them back and downloads nothing.

## Requirements

You need these items:

- A gateway with UniFi OS 2.x or later, for example a UDM SE, a UDM Pro, or a UDR.
- SSH access to the gateway as the root user.
- A Cloudflare Tunnel that you manage from the Cloudflare dashboard, and its token.

## Installation

Do these steps in an SSH session on the gateway, as the root user.

1. Download the script and the example configuration file.

   ```sh
   mkdir -p /data/cloudflared && cd /data/cloudflared
   curl -fsSLO https://raw.githubusercontent.com/benkelly/udm-cloudflared/main/udm-cloudflared.sh
   curl -fsSL https://raw.githubusercontent.com/benkelly/udm-cloudflared/main/cloudflared.env.example -o cloudflared.env
   chmod +x udm-cloudflared.sh
   ```

2. Open the configuration file in an editor.

   ```sh
   vi cloudflared.env
   ```

3. Set `TUNNEL_TOKEN` to the token of your tunnel.
   To add a replica, use the same token as your first connector.

4. Start the installation.

   ```sh
   ./udm-cloudflared.sh install
   ```

5. Make sure that the new connector shows under your tunnel in the Cloudflare dashboard.

## Commands

Run each command on the gateway as the root user, from `/data/cloudflared`.
For example, `./udm-cloudflared.sh status` shows the state of the service.

| Command | Result |
| --- | --- |
| `install` | Downloads `cloudflared`, creates the service, and starts it. |
| `update` | Downloads the latest `cloudflared` and restarts the service. |
| `check` | Shows the installed version and the latest version of `cloudflared` and of the script. |
| `auto-update` | Does an update only if a newer release exists. The weekly timer runs this command. |
| `self-update` | Replaces the script with its newest release. |
| `restore` | Puts the service file back after a firmware update. |
| `status` | Shows the `cloudflared` version and the state of the service. |
| `version` | Shows the version of the script. |
| `uninstall` | Removes the service and keeps the files in `/data/cloudflared`. |
| `uninstall --purge` | Removes the service and deletes `/data/cloudflared`. |

## Automatic updates

The script can update `cloudflared` for you each week.
This function is off by default, because it lets the gateway download and run a new binary without you.
To turn it on, do these steps on the gateway as the root user.

1. Add this line to `/data/cloudflared/cloudflared.env`:

   ```sh
   AUTO_UPDATE=true
   ```

2. Run the installation again.

   ```sh
   /data/cloudflared/udm-cloudflared.sh install
   ```

A systemd timer then runs the `auto-update` command one time each week.
The command downloads `cloudflared` only if a newer release exists.
The command keeps the old binary if the new binary does not start.

To turn the function off, remove the line and run the installation again.

## Script updates

The script does not update itself automatically.
The weekly timer updates only `cloudflared`, not the script.
The `check` command tells you when a newer release of the script exists.

To get the newest release, run these commands on the gateway as the root user:

```sh
/data/cloudflared/udm-cloudflared.sh self-update
/data/cloudflared/udm-cloudflared.sh install
```

The first command downloads the script from the release tag, not from the `main` branch.
It keeps the old script if the new script is not valid.
The second command applies the new service files.

The download uses HTTPS from GitHub.
The script does not make sure that a signature or a checksum is correct.
Read the release notes before you run `self-update`.

### Releases

This part is for the maintainer.
To publish a release, set `SCRIPT_VERSION` in the script to the new version, for example `0.2.0`.
Then publish a GitHub release with the tag `v0.2.0`.
The tag must match the version, or `self-update` rejects the download.

## After a firmware update

In most cases, you do nothing after a firmware update.
The connector starts again when the gateway starts.

UniFi OS has a read-only firmware image and a separate partition for changes.
A firmware update replaces the image and keeps the partition.
The service files in `/etc/systemd/system` are on that partition.

On the test gateway, a UDM SE, the unit files of a different tool stayed in that directory from 2023 to 2026.
In that time, firmware updates took the gateway to UniFi OS 6.0.17.

Ubiquiti does not document this behavior.
A future firmware update or a different model can remove the files.
If the connector is not in the Cloudflare dashboard after a firmware update, run this command on the gateway:

```sh
/data/cloudflared/udm-cloudflared.sh restore
```

The command copies the service file back and starts the service.
If the weekly update is on, the command also puts the timer back.

## Limits

- A replica gives failover, a second path when the first one stops. It does not share the load.
  But while both connectors are up, Cloudflare can send a request to either connector.
- Each origin in your tunnel configuration must work from the gateway too.
  An origin is the address that a public host name points to, for example `http://homeassistant:8123`.
  A short name can work on your first host but not on the gateway.
  To test an origin, run these commands on the gateway:

  ```sh
  getent hosts homeassistant
  curl -s -o /dev/null -w '%{http_code}\n' http://homeassistant:8123/
  ```

  The first command must show an IP address. The second command must show an HTTP status code, not `000`.
- The gateway can only connect to hosts that are on. If a host is off, its services stay off.
- `cloudflared` does not update itself. Run the `update` command to get a new version, or turn on the weekly update.

## Security

Do not commit `cloudflared.env` to a repository.
Any person with the token can run a connector for your tunnel.
The script sets the file mode to 600, which lets only the root user read the file.

When `cloudflared` starts, it writes your full tunnel configuration to the system journal.
The configuration shows all your host names and origins.
Remove these lines before you share logs.
