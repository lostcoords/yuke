import { equal } from "yuke:internal/test";
import { client } from "yuke:internal/client";
// No engine is attached in a unit test, so a view read answers its empty projection.
equal(client.sessionOutline("00".repeat(16)), null);
