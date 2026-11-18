import type { ToolExecuteResult } from "yuke:tools";

export const result = {
  text: "The build failed. Read the compiler errors before retrying.",
  isError: true,
} satisfies ToolExecuteResult;
