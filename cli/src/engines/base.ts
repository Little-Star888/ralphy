import type { AIEngine, AIResult, ProgressCallback } from "./types.ts";

/**
 * Check if a command is available in PATH
 */
export async function commandExists(command: string): Promise<boolean> {
	try {
		const proc = Bun.spawn(["which", command], {
			stdout: "pipe",
			stderr: "pipe",
		});
		const exitCode = await proc.exited;
		return exitCode === 0;
	} catch {
		return false;
	}
}

/**
 * Execute a command and return stdout
 */
export async function execCommand(
	command: string,
	args: string[],
	workDir: string,
	env?: Record<string, string>
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
	const proc = Bun.spawn([command, ...args], {
		cwd: workDir,
		stdout: "pipe",
		stderr: "pipe",
		env: { ...process.env, ...env },
	});

	const [stdout, stderr, exitCode] = await Promise.all([
		new Response(proc.stdout).text(),
		new Response(proc.stderr).text(),
		proc.exited,
	]);

	return { stdout, stderr, exitCode };
}

/**
 * Parse token counts from stream-json output (Claude/Qwen format)
 */
export function parseStreamJsonResult(output: string): {
	response: string;
	inputTokens: number;
	outputTokens: number;
} {
	const lines = output.split("\n").filter(Boolean);
	let response = "";
	let inputTokens = 0;
	let outputTokens = 0;

	for (const line of lines) {
		try {
			const parsed = JSON.parse(line);
			if (parsed.type === "result") {
				response = parsed.result || "Task completed";
				inputTokens = parsed.usage?.input_tokens || 0;
				outputTokens = parsed.usage?.output_tokens || 0;
			}
		} catch {
			// Ignore non-JSON lines
		}
	}

	return { response: response || "Task completed", inputTokens, outputTokens };
}

/**
 * Check for errors in stream-json output
 */
export function checkForErrors(output: string): string | null {
	const lines = output.split("\n").filter(Boolean);

	for (const line of lines) {
		try {
			const parsed = JSON.parse(line);
			if (parsed.type === "error") {
				return parsed.error?.message || parsed.message || "Unknown error";
			}
		} catch {
			// Ignore non-JSON lines
		}
	}

	return null;
}

/**
 * Execute a command with streaming output, calling onLine for each line
 */
export async function execCommandStreaming(
	command: string,
	args: string[],
	workDir: string,
	onLine: (line: string) => void,
	env?: Record<string, string>
): Promise<{ exitCode: number }> {
	const proc = Bun.spawn([command, ...args], {
		cwd: workDir,
		stdout: "pipe",
		stderr: "pipe",
		env: { ...process.env, ...env },
	});

	// Read stdout line by line
	const reader = proc.stdout.getReader();
	const decoder = new TextDecoder();
	let buffer = "";

	try {
		while (true) {
			const { done, value } = await reader.read();
			if (done) break;

			buffer += decoder.decode(value, { stream: true });
			const lines = buffer.split("\n");
			buffer = lines.pop() || "";

			for (const line of lines) {
				if (line.trim()) {
					onLine(line);
				}
			}
		}

		// Process any remaining buffer
		if (buffer.trim()) {
			onLine(buffer);
		}
	} finally {
		reader.releaseLock();
	}

	const exitCode = await proc.exited;
	return { exitCode };
}

/**
 * Detect the current step from a JSON output line
 * Returns step name like "Reading code", "Implementing", etc.
 */
export function detectStepFromOutput(line: string): string | null {
	try {
		const parsed = JSON.parse(line);

		// Check for tool calls in various formats
		const toolName =
			parsed.tool?.toLowerCase() ||
			parsed.name?.toLowerCase() ||
			parsed.tool_name?.toLowerCase() ||
			"";

		const command = parsed.command?.toLowerCase() || "";
		const content = JSON.stringify(parsed).toLowerCase();

		// Git commit
		if (content.includes("git commit") || command.includes("git commit")) {
			return "Committing";
		}

		// Git add/staging
		if (content.includes("git add") || command.includes("git add")) {
			return "Staging";
		}

		// Linting
		if (
			content.includes("lint") ||
			content.includes("eslint") ||
			content.includes("biome") ||
			content.includes("prettier")
		) {
			return "Linting";
		}

		// Testing
		if (
			content.includes("vitest") ||
			content.includes("jest") ||
			content.includes("bun test") ||
			content.includes("npm test") ||
			content.includes("pytest") ||
			content.includes("go test")
		) {
			return "Testing";
		}

		// Writing tests
		if (
			content.includes(".test.") ||
			content.includes(".spec.") ||
			content.includes("__tests__") ||
			content.includes("_test.go")
		) {
			return "Writing tests";
		}

		// Writing/Editing code
		if (toolName === "write" || toolName === "edit") {
			return "Implementing";
		}

		// Reading code
		if (toolName === "read" || toolName === "glob" || toolName === "grep") {
			return "Reading code";
		}

		return null;
	} catch {
		return null;
	}
}

/**
 * Base implementation for AI engines
 */
export abstract class BaseAIEngine implements AIEngine {
	abstract name: string;
	abstract cliCommand: string;

	async isAvailable(): Promise<boolean> {
		return commandExists(this.cliCommand);
	}

	abstract execute(prompt: string, workDir: string): Promise<AIResult>;

	/**
	 * Execute with streaming progress updates (optional implementation)
	 */
	executeStreaming?(
		prompt: string,
		workDir: string,
		onProgress: ProgressCallback
	): Promise<AIResult>;
}
