/**
 * pi adapter for the outl persistent-memory system.
 *
 * Translates pi lifecycle events into the memory-hook protocol (Claude Code's hook JSON schema)
 * and runs the shared `memory-hook`, so every harness drives one hook, one workspace, one index:
 *
 *   session_start (not reload)               -> SessionStart      (context injected with the first prompt)
 *   before_agent_start (user prompt)         -> UserPromptSubmit  (push-retrieval pointers)
 *   tool_result(mcp__outl__outl_page_get)    -> PostToolUse       (frecency touch; codemode calls included)
 *   session_before_compact                   -> PreCompact        (reminder delivered after compaction)
 *   session_shutdown (not reload)            -> SessionEnd        (detached on-close journaler)
 *
 * The hook runs with MEMORY_HARNESS=pi, so the background agents it launches
 * (memory-consolidate, memory-dump) run as `pi -p`.
 * Overrides: MEMORY_HOOK_BIN (hook path), plus every env var the hook itself honours.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type ChildProcess, spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const HOOK = process.env.MEMORY_HOOK_BIN || join(homedir(), ".local", "bin", "memory-hook");
const HOOK_TIMEOUT_MS = 25_000;
const CUSTOM_TYPE = "llm-harness-memory";
const PAGE_GET_TOOL = "mcp__outl__outl_page_get";

// pi session_start / session_shutdown reasons -> Claude Code SessionStart sources / SessionEnd
// reasons; a reason pi adds later falls back to "startup" / "other". "reload" swaps the
// extension runtime inside the same conversation, so it neither starts nor ends a session.
const START_SOURCE: Record<string, string> = { new: "clear", resume: "resume", fork: "resume" };
const END_REASON: Record<string, string> = { new: "clear" };

interface HookOutput {
	hookSpecificOutput?: { additionalContext?: string };
	systemMessage?: string;
}

const HOOK_ENV: NodeJS.ProcessEnv = { ...process.env, MEMORY_HARNESS: "pi" };

function runHook(payload: Record<string, unknown>, cwd: string): Promise<HookOutput | null> {
	const { promise, resolve } = Promise.withResolvers<HookOutput | null>();
	let child: ChildProcess;
	try {
		child = spawn(HOOK, [], { cwd, env: HOOK_ENV, stdio: ["pipe", "pipe", "ignore"] });
	} catch {
		resolve(null);
		return promise;
	}
	let out = "";
	const timer = setTimeout(() => {
		child.kill();
		resolve(null);
	}, HOOK_TIMEOUT_MS);
	child.stdout?.on("data", d => {
		out += d;
	});
	child.on("error", () => {
		clearTimeout(timer);
		resolve(null);
	});
	child.on("close", () => {
		clearTimeout(timer);
		const text = out.trim();
		try {
			resolve(text ? (JSON.parse(text) as HookOutput) : null);
		} catch {
			resolve(null);
		}
	});
	child.stdin?.on("error", () => {});
	child.stdin?.end(JSON.stringify(payload));
	return promise;
}

// Detached: survives pi exiting (SessionEnd fires during shutdown).
function fireHook(payload: Record<string, unknown>, cwd: string): void {
	try {
		const child = spawn(HOOK, [], { cwd, env: HOOK_ENV, detached: true, stdio: ["pipe", "ignore", "ignore"] });
		child.on("error", () => {});
		child.stdin?.on("error", () => {});
		child.stdin?.end(JSON.stringify(payload));
		child.unref();
	} catch {
		// best effort, like the hook itself
	}
}

const contextOf = (o: HookOutput | null) => o?.hookSpecificOutput?.additionalContext?.trim() || "";
const sessionId = (ctx: ExtensionContext) => ctx.sessionManager.getSessionId() || "pi";

export default function llmHarnessMemory(pi: ExtensionAPI) {
	// SessionStart context, injected with the first prompt of the session and cleared once
	// that prompt's turn starts.
	let pendingStart: Promise<string> | null = null;

	pi.on("session_start", (event, ctx) => {
		if (event.reason === "reload") return;
		const source = START_SOURCE[event.reason] ?? "startup";
		pendingStart = runHook(
			{ hook_event_name: "SessionStart", source, session_id: sessionId(ctx), cwd: ctx.cwd },
			ctx.cwd,
		).then(contextOf);
	});

	// Fires before teardown, so the session manager still describes the ending session.
	pi.on("session_shutdown", (event, ctx) => {
		const transcript = ctx.sessionManager.getSessionFile();
		if (event.reason === "reload" || !transcript) return;
		const reason = END_REASON[event.reason] ?? "other";
		fireHook(
			{ hook_event_name: "SessionEnd", reason, session_id: sessionId(ctx), transcript_path: transcript, cwd: ctx.cwd },
			ctx.cwd,
		);
	});

	pi.on("turn_start", () => {
		pendingStart = null;
	});

	pi.on("before_agent_start", async (event, ctx) => {
		if (event.messageType !== "user") return;
		const parts: string[] = [];
		if (pendingStart) {
			const start = await pendingStart;
			if (start) parts.push(start);
		}
		const push = contextOf(
			await runHook(
				{ hook_event_name: "UserPromptSubmit", prompt: event.prompt, session_id: sessionId(ctx), cwd: ctx.cwd },
				ctx.cwd,
			),
		);
		if (push) parts.push(push);
		if (parts.length === 0) return;
		return { message: { customType: CUSTOM_TYPE, content: parts.join("\n\n"), display: false } };
	});

	// Awaited like Claude Code's PostToolUse: the hook only parses and backgrounds the touch,
	// and a print-mode run can otherwise exit before the hook gets that far.
	pi.on("tool_result", async (event, ctx) => {
		if (event.isError || event.toolName !== PAGE_GET_TOOL) return;
		await runHook(
			{
				hook_event_name: "PostToolUse",
				tool_name: event.toolName,
				tool_input: event.input,
				session_id: sessionId(ctx),
				cwd: ctx.cwd,
			},
			ctx.cwd,
		);
	});

	// PreCompact: pi's compaction takes no extra context, so the reminder is fetched before
	// compaction and re-sent as a hidden message once the summary replaces the history.
	let compactReminder = "";
	pi.on("session_before_compact", async (_event, ctx) => {
		compactReminder =
			(await runHook({ hook_event_name: "PreCompact", session_id: sessionId(ctx), cwd: ctx.cwd }, ctx.cwd))
				?.systemMessage ?? "";
	});
	pi.on("session_compact", () => {
		if (!compactReminder) return;
		pi.sendMessage({ customType: CUSTOM_TYPE, content: compactReminder, display: false }, { deliverAs: "nextTurn" });
		compactReminder = "";
	});
	pi.on("session_compact_failed", () => {
		compactReminder = "";
	});
}
