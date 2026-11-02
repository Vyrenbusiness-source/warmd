#!/usr/bin/env bash
# Installs warmd to ~/.warmd and links it into ~/.local/bin. Run it again to update.
set -eu
DIR="${WARMD_DIR_INSTALL:-$HOME/.warmd}"
BIN="${WARMD_BIN:-$HOME/.local/bin}"
if [ -d "$DIR/.git" ]; then git -C "$DIR" pull -q --ff-only
else git clone -q --depth 1 https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents.git "$DIR"; fi
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexec bash "%s/bin/warmd" "$@"\n' "$DIR" > "$BIN/warmd"
chmod +x "$BIN/warmd" "$DIR/bin/warmd"
echo "warmd installed to $BIN/warmd"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Add this to your shell profile: export PATH=\"$BIN:\$PATH\"";; esac
