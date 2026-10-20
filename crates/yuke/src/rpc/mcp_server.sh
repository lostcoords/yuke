#!/bin/sh
# The MCP server of the RPC tests. It reads one JSON-RPC message per line, and its one tool `ping` answers `pong`.
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case $line in
    *'"method":"initialize"'*)
      result='{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"sh","version":"1.0.0"}}' ;;
    *'"method":"tools/list"'*)
      result='{"tools":[{"name":"ping","description":"Answer pong.","inputSchema":{"type":"object"}}]}' ;;
    *'"method":"tools/call"'*)
      result='{"content":[{"type":"text","text":"pong"}]}' ;;
    *) continue ;;
  esac
  printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$result"
done
