// The dyadic bridge: the pi extension dyadic.nvim loads into each agent with `-e`.
// It adds what stock RPC lacks and stays thin: dyadic draws all UI in Neovim.
// See doc/dyadic.txt, section "Bridge", and docs/adr/0002-dyadic-ships-a-pi-extension.md.
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";

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

export default function (pi: ExtensionAPI) {
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
