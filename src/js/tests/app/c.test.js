import { equal } from "yuke:test";
import { client } from "yuke:client";
// No engine is attached in a unit test, so a view read answers its empty projection.
equal(client.sessionOutline("00".repeat(16)), null);
