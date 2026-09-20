declare module "yuke:http-native" {
  import type { CancellationSignal } from "yuke:cancellation-native";

  export interface FetchOptions {
    method?: "GET" | "POST" | "PUT" | "PATCH" | "HEAD" | "DELETE";
    headers?: Record<string, string>;
    body?: string;
    timeoutMs?: number;
    signal?: CancellationSignal;
  }

  export interface HttpResponse {
    status: number;
    body: string;
    headers: Record<string, string>;
  }

  export function fetch(url?: string, options?: FetchOptions): Promise<HttpResponse>;
}
