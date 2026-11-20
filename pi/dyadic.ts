// The dyadic bridge: the pi extension dyadic.nvim loads into each agent with `-e`.
// It adds what stock RPC lacks and stays thin: dyadic draws all UI in Neovim.
// See doc/dyadic.txt, section "Bridge", and docs/adr/0002-dyadic-ships-a-pi-extension.md.
import { constants } from "node:fs";
import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { resolve } from "node:path";
import {
  createEditToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
  type EditOperations,
  type ExtensionAPI,
  type ExtensionCommandContext,
  type ExtensionContext,
  type WriteOperations,
} from "@earendil-works/pi-coding-agent";

// Bridge requests travel as `input` dialogs with this title and JSON in the placeholder;
// dyadic answers with JSON `{ ok, value }` or `{ ok: false, error }`.
const BRIDGE_TITLE = "dyadic.bridge";

async function call(
  ctx: ExtensionContext,
  kind: string,
  payload: Record<string, unknown>,
  signal?: AbortSignal,
): Promise<unknown> {
  const raw = await ctx.ui.input(BRIDGE_TITLE, JSON.stringify({ kind, ...payload }), { signal });
  if (raw === undefined) {
    throw new Error(signal?.aborted ? "Aborted" : "dyadic.nvim did not answer the bridge request");
  }
  const reply = JSON.parse(raw);
  if (!reply || reply.ok !== true) {
    throw new Error(reply?.error ?? "dyadic.nvim failed the bridge request");
  }
  return reply.value;
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

type Args = Record<string, unknown>;
type Subcommand = (args: Args, ctx: ExtensionCommandContext, pi: ExtensionAPI) => Promise<void>;

const subcommands: Record<string, Subcommand> = {
  // Reload is terminal for this handler: code after it would run in the old runtime.
  reload: async (_args, ctx) => {
    await ctx.reload();
  },

  // Move within the session tree. The outcome goes back as a `result` request carrying the
  // caller's token, since a command's prompt response carries no data.
  tree: async (args, ctx) => {
    let outcome: Args;
    try {
      const result = await ctx.navigateTree(String(args.id), {
        summarize: args.summarize === true,
        customInstructions: typeof args.instructions === "string" ? args.instructions : undefined,
      });
      outcome = { cancelled: result.cancelled };
    } catch (error) {
      outcome = { error: message(error) };
    }
    await call(ctx, "result", { token: args.token, outcome });
  },

  // Set a label, or clear it with an empty one.
  label: async (args, ctx, pi) => {
    let outcome: Args = {};
    try {
      const label = typeof args.label === "string" && args.label.trim() !== "" ? args.label.trim() : undefined;
      pi.setLabel(String(args.id), label);
    } catch (error) {
      outcome = { error: message(error) };
    }
    await call(ctx, "result", { token: args.token, outcome });
  },
};

// dyadic sends `/dyadic <name> [json]`; the prompt response arrives after the handler
// returns, and a thrown error reaches dyadic as an extension_error event.
function parse(text: string): { name: string; args: Args } {
  const trimmed = text.trim();
  const space = trimmed.indexOf(" ");
  if (space === -1) {
    return { name: trimmed, args: {} };
  }
  const args = JSON.parse(trimmed.slice(space + 1));
  if (!args || typeof args !== "object" || Array.isArray(args)) {
    throw new Error("dyadic: command arguments must be a JSON object");
  }
  return { name: trimmed.slice(0, space), args };
}

// Editor-backed file tools. pi keeps its own matching, results, and rendering; only file
// access goes through dyadic, which decides per file whether it is read from or changed in
// a buffer, reviewed by the user, or left to the disk. The model-facing text is fixed: the
// guidelines describe the behaviour once, and results only add what one call decided.

const READ_NOTE =
  " If the file is open in the user's editor with unsaved changes, returns the editor's text, which may differ from the file on disk.";
const READ_GUIDELINES = ["Files open in the user's editor are read from the editor; unsaved editor text is their current content."];
const CHANGE_GUIDELINES = [
  "Files open in the user's editor are changed there and saved. Saving may run the user's formatters; if an edit no longer matches, read the file again.",
  "The user may review a change before it lands, accepting or rejecting parts of it, optionally with a reason. A reviewed change stays unsaved in the editor until the user saves it, so commands that read from disk don't see it. Ask the user to save when you need it on disk; don't write the file another way to get around the review.",
  "A rejection with a reason asks for a revision. Without a reason, don't propose the same change again unless asked.",
];

// What dyadic decided for one file: the disk, or the editor with the buffer's text.
type Plan = { mode: "disk" } | { mode: "buffer" | "review"; text: string };
// What dyadic reports after applying: text replacing pi's result, a note added to it, an
// error that fails the call, or a diff of what landed.
type Outcome = { text?: string; note?: string; error?: string; diff?: string };

// pi resolves tool paths this way; read only uses it to ask for a buffer first.
function resolvePath(cwd: string, path: string): string {
  let p = path.startsWith("@") ? path.slice(1) : path;
  if (p === "~") {
    p = homedir();
  } else if (p.startsWith("~/")) {
    p = resolve(homedir(), p.slice(2));
  }
  return resolve(cwd, p);
}

// File operations for one edit or write call. The first operation asks dyadic for the plan
// with the exact path pi resolved; later ones reuse it.
function editorOperations(ctx: ExtensionContext, tool: string, signal?: AbortSignal) {
  let plan: Promise<Plan> | undefined;
  let outcome: Outcome | undefined;
  let directory: string | undefined;
  const prepare = (path: string) => {
    plan ??= call(ctx, "prepare", { path, tool }, signal) as Promise<Plan>;
    return plan;
  };
  const apply = async (path: string, content: string) => {
    const p = await prepare(path);
    if (p.mode === "disk") {
      if (directory) {
        await mkdir(directory, { recursive: true });
      }
      await writeFile(path, content, "utf-8");
      return;
    }
    outcome = (await call(ctx, "apply", { path, content, tool }, signal)) as Outcome;
    if (outcome?.error) {
      throw new Error(outcome.error);
    }
  };
  const edit: EditOperations = {
    access: async (path) => {
      if ((await prepare(path)).mode === "disk") {
        await access(path, constants.R_OK | constants.W_OK);
      }
    },
    readFile: async (path) => {
      const p = await prepare(path);
      return p.mode === "disk" ? readFile(path) : Buffer.from(p.text, "utf-8");
    },
    writeFile: apply,
  };
  const write: WriteOperations = {
    // The directory is created only when the file goes to disk; a buffer creates it on save.
    mkdir: async (dir) => {
      directory = dir;
    },
    writeFile: apply,
  };
  return { edit, write, outcome: () => outcome };
}

type ToolResult = { content: { type: string; text?: string }[]; details?: unknown };

function finish<R extends ToolResult>(result: R, outcome: Outcome | undefined): R {
  if (!outcome) {
    return result;
  }
  const first = result.content[0];
  if (first && first.type === "text") {
    if (outcome.text !== undefined) {
      first.text = outcome.text;
    } else if (outcome.note) {
      // pi's write result has no final period.
      const base = (first.text ?? "").replace(/([^.!?])$/, "$1.");
      first.text = `${base} ${outcome.note}`;
    }
  }
  if (outcome.diff !== undefined && result.details && typeof result.details === "object") {
    result.details = { ...result.details, diff: outcome.diff, patch: outcome.diff };
  }
  return result;
}

function registerFileTools(pi: ExtensionAPI) {
  const cwd = process.cwd();
  const read = createReadToolDefinition(cwd);
  pi.registerTool({
    ...read,
    description: read.description + READ_NOTE,
    promptGuidelines: [...(read.promptGuidelines ?? []), ...READ_GUIDELINES],
    async execute(id, params, signal, onUpdate, ctx) {
      const path = resolvePath(ctx.cwd, params.path);
      const text = (await call(ctx, "read", { path }, signal)) as string | null;
      if (typeof text !== "string") {
        return read.execute(id, params, signal, onUpdate, ctx);
      }
      const fromBuffer = createReadToolDefinition(ctx.cwd, {
        operations: {
          access: async () => {},
          readFile: async () => Buffer.from(text, "utf-8"),
          detectImageMimeType: async () => null,
        },
      });
      return fromBuffer.execute(id, params, signal, onUpdate, ctx);
    },
  });

  const edit = createEditToolDefinition(cwd);
  pi.registerTool({
    ...edit,
    promptGuidelines: [...(edit.promptGuidelines ?? []), ...CHANGE_GUIDELINES],
    executionMode: "sequential",
    async execute(id, params, signal, onUpdate, ctx) {
      const ops = editorOperations(ctx, "edit", signal);
      const tool = createEditToolDefinition(ctx.cwd, { operations: ops.edit });
      return finish(await tool.execute(id, params, signal, onUpdate, ctx), ops.outcome());
    },
  });

  const write = createWriteToolDefinition(cwd);
  pi.registerTool({
    ...write,
    promptGuidelines: [...(write.promptGuidelines ?? []), ...CHANGE_GUIDELINES],
    executionMode: "sequential",
    async execute(id, params, signal, onUpdate, ctx) {
      const ops = editorOperations(ctx, "write", signal);
      const tool = createWriteToolDefinition(ctx.cwd, { operations: ops.write });
      return finish(await tool.execute(id, params, signal, onUpdate, ctx), ops.outcome());
    },
  });
}

export default function (pi: ExtensionAPI) {
  registerFileTools(pi);
  pi.registerCommand("dyadic", {
    description: "Commands dyadic.nvim sends to its bridge",
    handler: async (text, ctx) => {
      const { name, args } = parse(text);
      const run = subcommands[name];
      if (!run) {
        throw new Error(`dyadic: unknown bridge command "${name}"`);
      }
      await run(args, ctx, pi);
    },
  });
}
