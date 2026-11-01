/**
 * omp adapter for the outl persistent-memory system.
 *
 * Translates omp lifecycle events into the Claude Code hook protocol and runs the shared
 * `claude-memory-hook`, so both harnesses drive one hook, one workspace, one index:
 *
 *   session_start / session_switch -> SessionStart      (context injected with the first prompt)
 *   before_agent_start             -> UserPromptSubmit  (push-retrieval pointers)
 *   tool_result(outl_page_get)     -> PostToolUse       (frecency touch; subagents included)
 *   session.compacting / session_compact -> PreCompact  (reminder in the summary + after it)
 *   session_before_switch /
 *   session_shutdown               -> SessionEnd        (detached on-close journaler)
 *
 * The hook runs with MEMORY_HARNESS=omp, so the background agents it launches
 * (memory-consolidate, claude-memory-dump) run as `omp -p`.
 * Overrides: MEMORY_HOOK_BIN (hook path), plus every env var the hook itself honours.
 */
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { type ChildProcess, spawn } from "node:child_process";
import { homedir } from "node:os";
import { basename, join } from "node:path";

const HOOK = process.env.MEMORY_HOOK_BIN || join(homedir(), ".local", "bin", "claude-memory-hook");
const HOOK_TIMEOUT_MS = 25_000;
const CUSTOM_TYPE = "claude-memory";
// omp registers MCP tools as mcp__<server>_<tool> with a redundant server prefix dropped.
const PAGE_GET_TOOLS: Record<string, true> = { mcp__outl_page_get: true, mcp__outl__outl_page_get: true };

interface HookOutput {
	hookSpecificOutput?: { additionalContext?: string };
	systemMessage?: string;
}

// Loose view of the ExtensionContext members this adapter reads.
interface Ctx {
	cwd: string;
	agent?: { kind?: "main" | "sub" };
	sessionManager?: { getSessionId?: () => string | undefined; getSessionFile?: () => string | undefined };
}

function hookEnv(): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = { ...process.env, MEMORY_HARNESS: "omp" };
	// The compiled omp binary is its own execPath; hand it to memory-agent so headless runs
	// work even when the hook's PATH lacks omp.
	if (!env.OMP_BIN && basename(process.execPath).startsWith("omp")) env.OMP_BIN = process.execPath;
	return env;
}

function runHook(payload: Record<string, unknown>, cwd: string): Promise<HookOutput | null> {
	const { promise, resolve } = Promise.withResolvers<HookOutput | null>();
	let child: ChildProcess;
	try {
		child = spawn(HOOK, [], { cwd, env: hookEnv(), stdio: ["pipe", "pipe", "ignore"] });
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

// Detached: survives omp exiting (SessionEnd fires during shutdown).
function fireHook(payload: Record<string, unknown>, cwd: string): void {
	try {
		const child = spawn(HOOK, [], { cwd, env: hookEnv(), detached: true, stdio: ["pipe", "ignore", "ignore"] });
		child.on("error", () => {});
		child.stdin?.on("error", () => {});
		child.stdin?.end(JSON.stringify(payload));
		child.unref();
	} catch {
		// best effort, like the hook itself
	}
}

const contextOf = (o: HookOutput | null) => o?.hookSpecificOutput?.additionalContext?.trim() || "";
const isMain = (ctx: Ctx) => ctx.agent?.kind !== "sub";
const sessionId = (ctx: Ctx) => ctx.sessionManager?.getSessionId?.() || "omp";

export default function claudeMemory(pi: ExtensionAPI) {
	// SessionStart context, injected with the first prompt of the session and cleared once
	// that prompt's turn starts (before_agent_start may be retried before it is accepted).
	let pendingStart: Promise<string> | null = null;

	const begin = (ctx: Ctx, source: string) => {
		if (!isMain(ctx)) return;
		pendingStart = runHook(
			{ hook_event_name: "SessionStart", source, session_id: sessionId(ctx), cwd: ctx.cwd },
			ctx.cwd,
		).then(contextOf);
	};

	const end = (ctx: Ctx, reason: string) => {
		if (!isMain(ctx)) return;
		const transcript = ctx.sessionManager?.getSessionFile?.();
		if (!transcript) return;
		fireHook(
			{ hook_event_name: "SessionEnd", reason, session_id: sessionId(ctx), transcript_path: transcript, cwd: ctx.cwd },
			ctx.cwd,
		);
	};

	pi.on("session_start", (_event, ctx) => begin(ctx as Ctx, "startup"));
	pi.on("session_switch", (_event, ctx) => begin(ctx as Ctx, "resume"));
	pi.on("session_before_switch", (_event, ctx) => end(ctx as Ctx, "clear"));
	pi.on("session_shutdown", (_event, ctx) => end(ctx as Ctx, "other"));

	pi.on("turn_start", () => {
		pendingStart = null;
	});

	pi.on("before_agent_start", async (event, ctx) => {
		const c = ctx as Ctx;
		if (!isMain(c) || event.reason === "revive") return;
		const parts: string[] = [];
		if (pendingStart) {
			const start = await pendingStart;
			if (start) parts.push(start);
		}
		const push = contextOf(
			await runHook(
				{ hook_event_name: "UserPromptSubmit", prompt: event.prompt ?? "", session_id: sessionId(c), cwd: c.cwd },
				c.cwd,
			),
		);
		if (push) parts.push(push);
		if (parts.length === 0) return;
		return { message: { customType: CUSTOM_TYPE, content: parts.join("\n\n"), display: false } };
	});

	// Awaited like Claude Code's PostToolUse: the hook only parses and backgrounds the touch,
	// and a print-mode run can otherwise exit before the hook gets that far.
	pi.on("tool_result", async (event, ctx) => {
		if (event.isError || !PAGE_GET_TOOLS[event.toolName]) return;
		const c = ctx as Ctx;
		await runHook(
			{
				hook_event_name: "PostToolUse",
				tool_name: event.toolName,
				tool_input: event.input,
				session_id: sessionId(c),
				cwd: c.cwd,
			},
			c.cwd,
		);
	});

	// PreCompact: the reminder rides into an LLM summary's additional context, and is re-sent
	// as a hidden message after compaction because local methods (snapcompact, shake) never
	// read that context.
	let compactReminder = "";
	pi.on("session.compacting", async (_event, ctx) => {
		const c = ctx as Ctx;
		if (!isMain(c)) return;
		const msg = (await runHook({ hook_event_name: "PreCompact", session_id: sessionId(c), cwd: c.cwd }, c.cwd))
			?.systemMessage;
		compactReminder = msg ?? "";
		return msg ? { context: [msg] } : undefined;
	});
	pi.on("session_compact", () => {
		if (!compactReminder) return;
		pi.sendMessage(
			{ customType: CUSTOM_TYPE, content: compactReminder, display: false },
			{ deliverAs: "nextTurn" },
		);
		compactReminder = "";
	});
}
