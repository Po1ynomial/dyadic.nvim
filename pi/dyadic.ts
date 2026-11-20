// The dyadic bridge: the pi extension dyadic.nvim loads into each agent with `-e`.
// It adds what stock RPC lacks and stays thin: dyadic draws all UI in Neovim.
// See doc/dyadic.txt, section "Bridge", and docs/adr/0002-dyadic-ships-a-pi-extension.md.
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";

type Subcommand = (args: Record<string, unknown>, ctx: ExtensionCommandContext) => Promise<void>;

const subcommands: Record<string, Subcommand> = {
  // Reload is terminal for this handler: code after it would run in the old runtime.
  reload: async (_args, ctx) => {
    await ctx.reload();
  },
};

// dyadic sends `/dyadic <name> [json]`; the prompt response arrives after the handler
// returns, and a thrown error reaches dyadic as an extension_error event.
function parse(text: string): { name: string; args: Record<string, unknown> } {
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
      await run(args, ctx);
    },
  });
}
