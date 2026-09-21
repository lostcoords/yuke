declare module "yuke:mcp-native" {
  export const mcpState: {
    configPath(): string | undefined;
    readTrust(server: string, identity: string): boolean | undefined;
    writeTrust(server: string, identity: string, approved: boolean): void;
    resetTrust(server: string): void;
  };
}
