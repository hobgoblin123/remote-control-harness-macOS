FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      openssh-client \
      tmux \
 && rm -rf /var/lib/apt/lists/*

# Install mise under /root/.local so it lands inside the project's persistent
# volume on first launch (podman initializes empty named volumes from the
# image's contents of the mount target).
RUN curl -fsSL https://mise.jdx.dev/install.sh | sh

ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="/root/.local/bin:/root/.local/share/mise/shims:${PNPM_HOME}:${PATH}"

# Pin node LTS + pnpm, then install claude code via pnpm. Note: node ships
# npm bundled — it exists on disk but we don't use it anywhere.
#
# pnpm v10 blocks postinstall scripts for globally-installed packages, so
# claude-code's native-binary download never runs. We invoke its install.cjs
# manually after `pnpm add -g` to finish the install.
RUN mkdir -p "$PNPM_HOME" \
 && mise use -g node@lts pnpm@latest \
 && mise exec -- pnpm add -g @anthropic-ai/claude-code \
 && mise exec -- node "$(mise exec -- pnpm root -g)/@anthropic-ai/claude-code/install.cjs"

# Interactive shells inside the container should get mise + pnpm on PATH.
RUN printf '%s\n' \
    '# --- remote-code-harness ---' \
    'export PATH="/root/.local/bin:$PATH"' \
    'export PNPM_HOME="/root/.local/share/pnpm"' \
    'export PATH="$PNPM_HOME:$PATH"' \
    'eval "$(/root/.local/bin/mise activate bash)"' \
    '# --- end remote-code-harness ---' \
    >> /root/.bashrc
