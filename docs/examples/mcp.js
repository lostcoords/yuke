// Connect one local stdio server and one remote HTTP server.
import { plugins } from "yuke";
import { mcp } from "yuke:plugins";

plugins.use(mcp({
  servers: {
    docs: {
      type: "stdio",
      command: "docs-mcp",
      args: ["--stdio"],
      env: { DOCS_ROOT: "${HOME}/docs" },
      cwd: "${HOME}",
    },
    "remote-docs": {
      type: "http",
      url: "https://mcp.example.com/mcp",
      headers: { "X-Tenant": "${MCP_TENANT}" },
      oauth: { clientId: "yuke-profile", scopes: ["mcp:tools"] },
    },
  },
  startupMs: 10_000,
  callMs: 60_000,
}));
