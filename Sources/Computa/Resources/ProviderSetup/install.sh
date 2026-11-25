#!/bin/sh
# Invoked only by the native picker for an explicitly selected provider.
set -eu
umask 077
install_codex() (
    [ "$(/usr/bin/uname -m)" = arm64 ] || { echo "This installer requires an Apple silicon Mac."; exit 1; }
    directory="$HOME/.local/share/kolmogor/bin"
    mkdir -p "$directory"
    stage=$(/usr/bin/mktemp -d "$directory/.codex-install.XXXXXX")
    trap 'rm -rf "$stage"' EXIT
    release=https://github.com/openai/codex/releases/download/rust-v0.172.0
    archive="$stage/release.tar.gz"
    /usr/bin/curl -fL --proto '=https' --proto-redir '=https' --retry 2 --max-time 300 \
        "$release/codex-aarch64-apple-darwin.tar.gz" -o "$archive"
    digest=$(/usr/bin/shasum -a 256 "$archive")
    [ "${digest%% *}" = bd121f8abd6b28b3fc476da04a348e25a83e89eda19d39107f68f8e966053092 ] || { echo "The Codex download failed its integrity check."; exit 1; }
    /usr/bin/tar -xOzf "$archive" codex-aarch64-apple-darwin > "$stage/codex"
    chmod 755 "$stage/codex"
    "$stage/codex" --version
    mv -f "$stage/codex" "$directory/codex"
)
brew_install() {
    if [ -x /opt/homebrew/bin/brew ]; then brew=/opt/homebrew/bin/brew
    elif [ -x /usr/local/bin/brew ]; then brew=/usr/local/bin/brew
    else
        echo "Install Homebrew from https://brew.sh, then choose Install again in Kolmogor."
        /usr/bin/open https://brew.sh
        exit 1
    fi
    "$brew" install "$@"
}
ensure_npm() {
    command -v npm >/dev/null || brew_install node
}
case "${1:-}" in
    codex) install_codex ;;
    antigravity) brew_install --cask antigravity-cli ;;
    qwen) brew_install qwen-code ;;
    opencode) brew_install opencode ;;
    kimi) ensure_npm; npm install --global --prefix "$HOME/.local" @moonshot-ai/kimi-code ;;
    claude) command -v claude >/dev/null || brew_install --cask claude-code
           ensure_npm; npm install --global --prefix "$HOME/.local" @agentclientprotocol/claude-agent-acp ;;
    *) exit 64 ;;
esac
