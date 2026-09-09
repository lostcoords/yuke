declare module "yuke:tools" {
  type Schema = Record<string, unknown>;

  export function defineTool(
    name: string,
    definition: {
      description: string;
      parameters: Schema;
      spawnsAgents?: boolean;
      needsSkills?: boolean;
      execute: (
        args: any,
        signal: { aborted: boolean },
        context: { workspaceRoot: string, sessionId?: string, messageId?: number, partId?: number },
      ) => Promise<unknown>;
    },
  ): void;

  export function removeTool(name: string): boolean;
}
