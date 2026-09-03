declare module "yuke:tools" {
  type Schema = Record<string, unknown>;

  export function defineTool(
    name: string,
    definition: {
      description: string;
      parameters: Schema;
      execute: (
        args: any,
        signal: { aborted: boolean },
        context: { workspaceRoot: string },
      ) => Promise<unknown>;
    },
  ): void;

  export function removeTool(name: string): boolean;
}
