import { test } from "node:test";
import assert from "node:assert";
import { summarize } from "./live";

test("summarize joins slugs", () => {
  assert.ok(summarize(["A B"]).startsWith("a-b"));
});
