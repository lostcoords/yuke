// Shared host module types. Keep in sync with fs.odin.

declare module "yuke:fs" {
  export interface FsStat {
    name: string;
    size: number;
    isDirectory: boolean;
    isFile: boolean;
  }

  export interface Fs {
    readFile(path: string): Promise<string>;
    stat(path: string): Promise<FsStat>;
    readDir(path: string): Promise<FsStat[]>;
  }

  export const fs: Fs;
}
