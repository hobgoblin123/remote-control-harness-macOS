# How to connect to container

Back to the [project README](../README.md).

## Connecting from your phone

Both published ports bind to `127.0.0.1` on the host, not `0.0.0.0`. To
reach them from a phone you need your own secure tunnel to the host
(Tailscale, SSH port forward, etc.) — this repo deliberately doesn't
expose anything on your LAN.

### Public tunnel for the webapp (opt-in)

For the `WEBAPP_PORT` specifically, the harness can also expose it to
the public internet via a Cloudflare quick tunnel. Set `EXPOSE_WEBAPP=true`
in `.env` and the next launch will:

- start `cloudflared` in a `tunnel` tmux session inside the container
- print a stable `https://*.trycloudflare.com` URL in the startup banner
- cache the URL at `/root/.logs/tunnel-url.txt`

The URL is stable for the container's lifetime and rotates on relaunch.
No Cloudflare account or domain required. The egress allowlist is
auto-extended with the Cloudflare tunnel edge endpoints
(`region1.v2.argotunnel.com`, `region2.v2.argotunnel.com`).

**What you're trading off:**

- The URL is the only access control. Anyone with it can reach the
  webapp — treat it like a secret.
- Traffic flows through Cloudflare's edge: they terminate TLS and
  re-encrypt over the tunnel, so request contents are visible to
  Cloudflare.
- Any vulnerability in the webapp is now exposed to the open internet
  rather than just `localhost`.
- Dev frameworks (Vite/Next/etc.) often reject requests where the
  `Host` header isn't `localhost`. You may need to allow the
  `*.trycloudflare.com` host in your dev server config.

`RC_PORT` is **not** tunneled — only the webapp. The remote-control
server stays bound to `127.0.0.1` and is reached over your existing
secure path (claude pairing flow).

If `EXPOSE_WEBAPP` is left unset (or set to anything other than `true`),
no tunnel is started and no extra hosts are added to the allowlist.

To pick up a change to `EXPOSE_WEBAPP` on an existing container, you
need to remove the container so the new env var is applied at create
time: `podman rm -f remote-code-<project>` (or `./launch.sh --reset`,
which also wipes the volume).

## Connecting from VSCode

VSCode's Dev Containers extension can attach to the running container via
podman's docker-compat socket. You get a VSCode window whose filesystem,
terminal, and extensions all live inside the container — the Claude Code
extension you install there uses the `claude` binary already in the image.

On the container host, enable the podman socket that matches your launch
mode — they're separate daemons with separate container views:

```bash
# rootless (default launch mode)
systemctl --user enable --now podman.socket   # -> /run/user/$UID/podman/podman.sock

# --rootful launch mode
sudo systemctl enable --now podman.socket     # -> /run/podman/podman.sock
```

On your local machine, in VSCode `settings.json`:

```jsonc
"dev.containers.dockerPath": "podman",
"docker.host": "ssh://user@host"            // omit if the host is local
```

For rootless, your SSH user's default podman context already points at the
user socket, so no extra `DOCKER_HOST` plumbing is needed. For `--rootful`,
VSCode's SSH session needs to reach the root socket — typically via
`DOCKER_HOST=unix:///run/podman/podman.sock` exported in the remote
environment, or by making your SSH user a member of a group the socket is
readable by (effectively root-equivalent — see [TODO.md](../TODO.md)).

Then: Command Palette → **Dev Containers: Attach to Running Container…** →
pick `remote-code-<project>`. From the new window, install the Claude
Code extension — it lands in `/root/.vscode-server/extensions/` on the
persistent volume and survives across launches.

First attach downloads VSCode server (~100MB) into `/root/.vscode-server/`;
`update.code.visualstudio.com`, `vscode.download.prss.microsoft.com`, and
`marketplace.visualstudio.com` are in the default [sample.env](../sample.env)
allowlist for this reason. Subsequent launches reuse the cached server.

The extension starts its own `claude` when you open it — it does not
share state with the tmux `claude` session [setup.sh](../setup.sh) launched.
If you want that one, open a terminal in VSCode and `tmux attach -t claude`.

## Claude remote-control

[setup.sh](../setup.sh) starts `claude remote-control` inside a detached
tmux session named `remote-control` on container boot. Two ways to see
what it's doing:

```bash
# Attach to the live tmux session (Ctrl-a d to detach without killing it;
# the container's tmux prefix is remapped from C-b to C-a so it doesn't
# collide with a host-side tmux you're attaching through)
podman exec -it remote-code-<project> tmux attach -t remote-control

# Or just tail the mirrored log
podman exec -it remote-code-<project> tail -f /root/.logs/remote-control.log
```

The first time you connect, grab the pairing URL/code from there and
hand it to your phone. Auth persists in the volume, so subsequent
launches don't need re-pairing.

If the server isn't reachable from the host on `127.0.0.1:$RC_PORT`,
check what interface it bound to — `claude remote-control` needs to
bind to `0.0.0.0` inside the container for podman's port publish to
forward correctly (same gotcha as the webapp).
