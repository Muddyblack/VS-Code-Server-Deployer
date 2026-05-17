#!/usr/bin/env bash
set -euo pipefail

trap 'echo "[!] error on line $LINENO. aborting." >&2; exit 1' ERR

SERVER_ARCHIVE="vscode-server-linux-x64.tar.gz"
CLI_ARCHIVE="vscode_cli_alpine_x64_cli.tar.gz"

for f in "$SERVER_ARCHIVE" "$CLI_ARCHIVE"; do
    if [ ! -f "$f" ]; then
        echo "[!] missing required file: $f" >&2
        exit 1
    fi
done

echo "[+] check commit_id"
commit_id=$(tar -axf "$SERVER_ARCHIVE" vscode-server-linux-x64/product.json -O \
    | grep '"commit":' \
    | sed 's#\s*"commit":\s*"\([^"]\+\)".*#\1#')

if [ -z "$commit_id" ]; then
    echo "[!] could not extract commit_id from $SERVER_ARCHIVE" >&2
    exit 1
fi
echo "[+] commit_id : $commit_id"

echo "[+] create .vscode-server directory structure"
mkdir -p ~/.vscode-server/cli/servers/

echo "[+] clean up existing version if present"
rm -rf ~/.vscode-server/cli/servers/Stable-"$commit_id"
rm -f  ~/.vscode-server/vscode-cli-"$commit_id".tar.gz*
rm -rf ~/.vscode-server/bin/"$commit_id"
rm -f  ~/.vscode-server/code-"$commit_id"

echo "[+] extract and setup vscode-cli"
tar -xzf "$CLI_ARCHIVE"
mv code ~/.vscode-server/code-"$commit_id"
chmod +x ~/.vscode-server/code-"$commit_id"

echo "[+] create Stable-$commit_id directory"
mkdir -p ~/.vscode-server/cli/servers/Stable-"$commit_id"/

echo "[+] uncompress $SERVER_ARCHIVE"
tar xf "$SERVER_ARCHIVE" -C ~/.vscode-server/cli/servers/Stable-"$commit_id"
mv ~/.vscode-server/cli/servers/Stable-"$commit_id"/vscode-server-linux-x64 \
   ~/.vscode-server/cli/servers/Stable-"$commit_id"/server

echo "[+] create lru.json file"
echo "[\"Stable-$commit_id/server\"]" > ~/.vscode-server/cli/servers/lru.json

echo "[+] finished. enjoy your remote code."
