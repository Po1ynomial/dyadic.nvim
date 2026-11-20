// The bridge's file tools against pi's real tool definitions, with a fake dyadic answering
// bridge requests. Run with `just test-ts`.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import extension from "../pi/dyadic.ts";

type Request = Record<string, unknown> & { kind: string };
type Tool = {
  description: string;
  promptGuidelines?: string[];
  execute: (...args: unknown[]) => Promise<{ content: { type: string; text?: string }[]; details?: unknown }>;
};

// Load the extension into a fake pi; `answer` plays dyadic.
function load(answer: (request: Request) => unknown) {
  const tools: Record<string, Tool> = {};
  const requests: Request[] = [];
  const pi = {
    registerTool: (tool: Tool & { name: string }) => {
      tools[tool.name] = tool;
    },
    registerCommand: () => {},
    setLabel: () => {},
  };
  extension(pi as never);
  const cwd = mkdtempSync(join(tmpdir(), "dyadic-bridge-"));
  const ctx = {
    cwd,
    ui: {
      input: async (title: string, placeholder: string) => {
        assert.equal(title, "dyadic.bridge");
        const request = JSON.parse(placeholder) as Request;
        requests.push(request);
        try {
          return JSON.stringify({ ok: true, value: answer(request) ?? null });
        } catch (error) {
          return JSON.stringify({ ok: false, error: String(error) });
        }
      },
    },
  };
  const run = (name: string, params: unknown) => tools[name].execute("call-1", params, undefined, undefined, ctx);
  return { tools, requests, cwd, run };
}

function text(result: { content: { text?: string }[] }) {
  return result.content[0].text;
}

Deno.test("tools keep pi's text and add the fixed guidelines", () => {
  const { tools } = load(() => null);
  assert.match(tools.read.description, /unsaved changes, returns the editor's text/);
  assert.ok(tools.read.promptGuidelines?.includes("Use read to examine files instead of cat or sed."));
  for (const name of ["edit", "write"]) {
    assert.ok(tools[name].promptGuidelines?.some((g) => g.startsWith("The user may review a change")));
  }
});

Deno.test("read uses the disk unless dyadic has unsaved buffer text", async () => {
  let buffer: string | null = null;
  const { run, cwd, requests } = load(() => buffer);
  writeFileSync(join(cwd, "a.txt"), "disk\n");
  assert.match(text(await run("read", { path: "a.txt" })) ?? "", /disk/);
  assert.equal(requests[0].path, join(cwd, "a.txt"));
  buffer = "editor\n";
  const result = text(await run("read", { path: "a.txt" })) ?? "";
  assert.match(result, /editor/);
  assert.doesNotMatch(result, /disk/);
});

Deno.test("edit on the disk path behaves like pi's", async () => {
  const { run, cwd, requests } = load(() => ({ mode: "disk" }));
  writeFileSync(join(cwd, "a.txt"), "one\ntwo\n");
  const result = await run("edit", { path: "a.txt", edits: [{ oldText: "two", newText: "TWO" }] });
  assert.equal(text(result), "Successfully replaced 1 block(s) in a.txt.");
  assert.equal(readFileSync(join(cwd, "a.txt"), "utf-8"), "one\nTWO\n");
  assert.deepEqual(
    requests.map((r) => r.kind),
    ["prepare"],
  );
});

Deno.test("edit in a buffer matches the buffer's text and sends the result to dyadic", async () => {
  let applied: string | undefined;
  const { run, cwd } = load((request) => {
    if (request.kind === "prepare") return { mode: "buffer", text: "unsaved\ntwo\n" };
    applied = request.content as string;
    return {};
  });
  writeFileSync(join(cwd, "a.txt"), "disk\ntwo\n");
  const result = await run("edit", { path: "a.txt", edits: [{ oldText: "unsaved", newText: "changed" }] });
  assert.equal(applied, "changed\ntwo\n");
  assert.equal(text(result), "Successfully replaced 1 block(s) in a.txt.");
  // The disk is dyadic's business in buffer mode.
  assert.equal(readFileSync(join(cwd, "a.txt"), "utf-8"), "disk\ntwo\n");
});

Deno.test("review outcomes replace or extend the result, or fail the call", async () => {
  let outcome: Record<string, string> = {};
  const { run, cwd } = load((request) => (request.kind === "prepare" ? { mode: "review", text: "a\nb\n" } : outcome));
  writeFileSync(join(cwd, "a.txt"), "a\nb\n");
  const edits = { path: "a.txt", edits: [{ oldText: "a", newText: "A" }] };
  outcome = { note: "Accepted by the user; unsaved in the editor." };
  assert.equal(text(await run("edit", edits)), "Successfully replaced 1 block(s) in a.txt. Accepted by the user; unsaved in the editor.");
  outcome = { text: "The user accepted 1 of 2 hunks in a.txt.", diff: "@@ -1 +1 @@\n-a\n+A\n" };
  const partial = await run("edit", edits);
  assert.equal(text(partial), "The user accepted 1 of 2 hunks in a.txt.");
  assert.equal((partial.details as { diff: string }).diff, "@@ -1 +1 @@\n-a\n+A\n");
  outcome = { error: "The user rejected the change to a.txt." };
  await assert.rejects(run("edit", edits), /The user rejected the change to a\.txt\./);
});

Deno.test("write creates directories only on the disk path", async () => {
  const { run, cwd } = load(() => ({ mode: "disk" }));
  await run("write", { path: "deep/dir/new.txt", content: "hi\n" });
  assert.equal(readFileSync(join(cwd, "deep/dir/new.txt"), "utf-8"), "hi\n");
  let applied = "";
  const editor = load((request) => {
    if (request.kind === "prepare") return { mode: "review", text: "" };
    applied = request.content as string;
    return { note: "Accepted by the user; unsaved in the editor." };
  });
  const result = await editor.run("write", { path: "other/new.txt", content: "hello\n" });
  assert.equal(applied, "hello\n");
  assert.match(text(result) ?? "", /^Successfully wrote to other\/new.txt\. Accepted/);
  assert.throws(() => readFileSync(join(editor.cwd, "other/new.txt")));
});
