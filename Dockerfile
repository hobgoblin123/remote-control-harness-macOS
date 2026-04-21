FROM ubuntu:24.04

# Ubuntu minimal ships no locale by default, so CLIs that gate box-drawing /
# emoji on a UTF-8 locale fall back to ASCII. C.UTF-8 is built into glibc,
# no `locales` package needed.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      openssh-client \
      tmux \
      ripgrep \
      fd-find \
      unzip \
      build-essential \
 && rm -rf /var/lib/apt/lists/*

# Neovim from the official prebuilt tarball — Ubuntu 24.04's apt nvim (0.9.5)
# is older than what current LazyVim requires. `stable` is a moving tag that
# points at the latest stable release; pin if you need reproducibility across
# base-image rebuilds.
RUN curl -fsSL "https://github.com/neovim/neovim/releases/download/stable/nvim-linux-x86_64.tar.gz" \
      | tar -xz -C /opt \
 && ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim

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

# tree-sitter CLI: LazyVim's treesitter config invokes this at first nvim
# startup to compile/verify parser grammars. Installing via pnpm would emit
# the "Ignored build scripts" warning because the npm package's only job is a
# postinstall that downloads this same binary from GitHub releases — and pnpm
# v10 blocks postinstall on global installs. Skip the middleman.
RUN curl -fsSL "https://github.com/tree-sitter/tree-sitter/releases/latest/download/tree-sitter-linux-x64.gz" \
      | gunzip > /usr/local/bin/tree-sitter \
 && chmod +x /usr/local/bin/tree-sitter

# Seed the LazyVim starter config into /root/.config/nvim, then pre-install
# plugins and treesitter parsers so the first interactive `nvim` run doesn't
# race async installers (opening a .tsx before the tsx parser finishes
# downloading throws "No parser for language 'tsx'"). /root is copied into
# the project's persistent volume on first launch, so /root/.local/share/nvim
# (plugins) and /root/.local/state/nvim (parsers) land in the volume too.
RUN git clone --depth 1 https://github.com/LazyVim/starter /root/.config/nvim \
 && rm -rf /root/.config/nvim/.git \
 && nvim --headless "+Lazy! sync" +qa \
 && nvim --headless \
      "+Lazy! load nvim-treesitter" \
      "+TSInstallSync bash c diff html javascript jsdoc json jsonc lua luadoc markdown markdown_inline python query regex toml tsx typescript vim vimdoc xml yaml" \
      +qa

# Interactive shells inside the container should get mise + pnpm on PATH.
RUN printf '%s\n' \
    '# --- remote-code-harness ---' \
    'export PATH="/root/.local/bin:$PATH"' \
    'export PNPM_HOME="/root/.local/share/pnpm"' \
    'export PATH="$PNPM_HOME:$PATH"' \
    'eval "$(/root/.local/bin/mise activate bash)"' \
    '# --- end remote-code-harness ---' \
    >> /root/.bashrc
