# Running on a remote host

Back to the [project README](../README.md).

The harness runs identically on a remote Linux box (Hetzner, AWS, DO,
etc.) — including aarch64 instances. You launch the container on the
remote host and attach VSCode to it from your laptop over SSH. Nothing
in the harness itself changes; the only difference is one extra setting
in your local VSCode config and a working SSH key into the host.

## On the remote host (one-time)

1. Install the [prerequisites](../README.md#prerequisites) for your launch
   mode (rootless is recommended for remote — fewer SSH-side gotchas).
2. Clone this repo, copy `sample.env` to `.env`, fill it in, and run
   `./launch.sh` the same way you would locally.
3. Enable the podman socket so your laptop's VSCode has something to
   talk to over SSH:

   ```bash
   # rootless (default launch mode)
   systemctl --user enable --now podman.socket
   loginctl enable-linger $USER   # keep the user socket alive after logout

   # --rootful launch mode
   sudo systemctl enable --now podman.socket
   ```

## On your laptop

1. Confirm SSH key auth works without a password prompt:

   ```bash
   ssh user@remote-host    # should drop you in without prompting
   ```

   Password auth doesn't play well with VSCode's `docker.host` over SSH —
   use a key, ideally with `ssh-agent` so VSCode can reuse it.

2. In your local VSCode `settings.json`:

   ```jsonc
   "dev.containers.dockerPath": "podman",
   "docker.host": "ssh://user@remote-host"
   ```

   For `--rootful` mode on the remote, VSCode's SSH session also needs
   `DOCKER_HOST=unix:///run/podman/podman.sock` exported in the remote
   shell environment, or your SSH user has to be in a group that can read
   the root socket. Rootless avoids both.

3. Command Palette → **Dev Containers: Attach to Running Container…** →
   pick `remote-code-<project>`.

## Reaching the published ports

`launch.sh` binds `RC_PORT` and the webapp port to `127.0.0.1` on the
remote host, not `0.0.0.0` — same posture as the local-only setup
described in [How to connect to container.md](How%20to%20connect%20to%20container.md#connecting-from-your-phone).
To reach them from your laptop's browser or phone, tunnel them over SSH:

```bash
ssh -L 8080:127.0.0.1:8080 -L 9090:127.0.0.1:9090 user@remote-host
```

Or use Tailscale / a WireGuard mesh if you'd rather not keep an SSH
session open.

## Things that feel different vs. local

- **First attach is slow.** VSCode pulls ~100MB of server into the
  container over your laptop↔remote link. It's cached in the persistent
  volume after that, so subsequent attaches are quick.
- **Terminal latency tracks your RTT.** A laptop in the US talking to a
  Hetzner Helsinki box is usable but noticeable; same-continent is fine.
- **The pairing URL for `claude remote-control`** uses `127.0.0.1:$RC_PORT`
  — pair via the SSH tunnel above, not the remote host's public IP.
