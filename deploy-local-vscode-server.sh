echo "[+] check commit_id"
commit_id=$(tar -axf vscode-server-linux-x64.tar.gz vscode-server-linux-x64/product.json -O | grep '"commit":' | sed 's#\s*"commit":\s*"\([^"]\+\)".*#\1#')
echo "[+] commit_id : $commit_id"

echo "[+] create .vscode-server directory structure"
mkdir -p ~/.vscode-server/cli/servers/

echo "[+] clean up existing version if present"
rm -rf ~/.vscode-server/cli/servers/Stable-$commit_id
rm -f ~/.vscode-server/vscode-cli-$commit_id.tar.gz*
# Also clean up legacy bin structure if it exists
rm -rf ~/.vscode-server/bin/$commit_id
rm -f ~/.vscode-server/code-$commit_id

echo "[+] extract and setup vscode-cli"
tar -xzf vscode_cli_alpine_x64_cli.tar.gz
mv code ~/.vscode-server/code-$commit_id
chmod +x ~/.vscode-server/code-$commit_id

echo "[+] create Stable-$commit_id directory"
mkdir -p ~/.vscode-server/cli/servers/Stable-$commit_id/

echo "[+] uncompress vscode-server-linux-x64.tar.gz"
tar xf vscode-server-linux-x64.tar.gz -C ~/.vscode-server/cli/servers/Stable-$commit_id
mv ~/.vscode-server/cli/servers/Stable-$commit_id/vscode-server-linux-x64 ~/.vscode-server/cli/servers/Stable-$commit_id/server

echo "[+] create lru.json file"
echo "[\"Stable-$commit_id/server\"]" > ~/.vscode-server/cli/servers/lru.json

echo "[+] finished. enjoy your remote code."