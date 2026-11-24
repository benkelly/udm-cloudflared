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

A firmware update can remove the service file from `/etc/systemd/system`.
The `restore` command puts the file back and downloads nothing.

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
| `restore` | Puts the service file back after a firmware update. |
| `status` | Shows the `cloudflared` version and the state of the service. |
| `uninstall` | Removes the service and keeps the files in `/data/cloudflared`. |
| `uninstall --purge` | Removes the service and deletes `/data/cloudflared`. |

## After a firmware update

If the connector is not in the Cloudflare dashboard after a firmware update, run this command on the gateway:

```sh
/data/cloudflared/udm-cloudflared.sh restore
```

The command copies the service file back and starts the service.

You can also run the restore each time the gateway starts.
For this, you need [unifi-on-boot](https://github.com/unredacted/unifi-on-boot), a package that runs your scripts at each start.
If the package is on the gateway, create this file there:

```sh
cat > /data/on_boot.d/10-cloudflared.sh <<'EOF'
#!/bin/bash
/data/cloudflared/udm-cloudflared.sh restore
EOF
chmod +x /data/on_boot.d/10-cloudflared.sh
```

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
- `cloudflared` does not update itself. Run the `update` command to get a new version.

## Security

Do not commit `cloudflared.env` to a repository.
Any person with the token can run a connector for your tunnel.
The script sets the file mode to 600, which lets only the root user read the file.

When `cloudflared` starts, it writes your full tunnel configuration to the system journal.
The configuration shows all your host names and origins.
Remove these lines before you share logs.
