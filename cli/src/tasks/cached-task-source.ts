import type { Task, TaskSource, TaskSourceType } from "./types.ts";
import { YamlTaskSource } from "./yaml.ts";

interface CachedTaskSourceOptions {
	/**
	 * How often to flush pending completions to disk (ms).
	 * Set to 0 to disable auto-flush (manual flush only).
	 * Default: 1000ms
	 */
	flushIntervalMs?: number;
}

/**
 * A caching wrapper around any TaskSource that:
 * - Loads tasks once and caches them in memory
 * - Tracks completions in memory for instant filtering
 * - Batches markComplete() writes with debouncing
 * - Flushes pending writes on process exit
 *
 * This dramatically reduces file I/O for task sources that
 * read/write the entire file on every operation.
 */
export class CachedTaskSource implements TaskSource {
	private inner: TaskSource;
	private cachedTasks: Task[] | null = null;
	private pendingCompletions: Set<string> = new Set();
	private flushTimer: ReturnType<typeof setTimeout> | null = null;
	private flushIntervalMs: number;
	private isShuttingDown = false;

	constructor(inner: TaskSource, options?: CachedTaskSourceOptions) {
		this.inner = inner;
		this.flushIntervalMs = options?.flushIntervalMs ?? 1000;

		// Register exit handlers to flush pending writes
		this.registerExitHandlers();
	}

	get type(): TaskSourceType {
		return this.inner.type;
	}

	/**
	 * Get the underlying task source (useful for type checks)
	 */
	getInner(): TaskSource {
		return this.inner;
	}

	/**
	 * Check if the inner source is a YamlTaskSource
	 */
	isYamlSource(): boolean {
		return this.inner instanceof YamlTaskSource;
	}

	async getAllTasks(): Promise<Task[]> {
		if (!this.cachedTasks) {
			this.cachedTasks = await this.inner.getAllTasks();
		}
		// Filter out tasks that have been marked complete (pending flush)
		return this.cachedTasks.filter((t) => !this.pendingCompletions.has(t.id));
	}

	async getNextTask(): Promise<Task | null> {
		const tasks = await this.getAllTasks();
		return tasks[0] || null;
	}

	async markComplete(id: string): Promise<void> {
		this.pendingCompletions.add(id);
		this.scheduleFlush();
	}

	async countRemaining(): Promise<number> {
		const tasks = await this.getAllTasks();
		return tasks.length;
	}

	async countCompleted(): Promise<number> {
		// Get completed count from inner source + pending completions
		const innerCompleted = await this.inner.countCompleted();
		return innerCompleted + this.pendingCompletions.size;
	}

	/**
	 * Get tasks in a specific parallel group (filters out pending completions)
	 */
	async getTasksInGroup(group: number): Promise<Task[]> {
		if (!this.inner.getTasksInGroup) {
			throw new Error("Inner task source does not support getTasksInGroup");
		}
		const tasks = await this.inner.getTasksInGroup(group);
		return tasks.filter((t) => !this.pendingCompletions.has(t.id));
	}

	/**
	 * Get the parallel group of a task (YamlTaskSource only)
	 */
	async getParallelGroup(title: string): Promise<number> {
		if (!(this.inner instanceof YamlTaskSource)) {
			return 0;
		}
		return this.inner.getParallelGroup(title);
	}

	/**
	 * Flush all pending completions to the underlying source.
	 * Call this before exiting or when you need writes persisted immediately.
	 */
	async flush(): Promise<void> {
		if (this.flushTimer) {
			clearTimeout(this.flushTimer);
			this.flushTimer = null;
		}

		if (this.pendingCompletions.size === 0) {
			return;
		}

		// Write all pending completions to inner source
		for (const id of this.pendingCompletions) {
			await this.inner.markComplete(id);
		}
		this.pendingCompletions.clear();

		// Invalidate cache so next read picks up any external changes
		this.cachedTasks = null;
	}

	/**
	 * Invalidate the cache, forcing a fresh read on next access.
	 * Does NOT flush pending completions.
	 */
	invalidateCache(): void {
		this.cachedTasks = null;
	}

	/**
	 * Check if there are pending completions waiting to be flushed
	 */
	hasPendingWrites(): boolean {
		return this.pendingCompletions.size > 0;
	}

	private scheduleFlush(): void {
		if (this.flushIntervalMs === 0) {
			// Auto-flush disabled
			return;
		}
		if (this.flushTimer) {
			// Already scheduled
			return;
		}
		this.flushTimer = setTimeout(() => {
			this.flushTimer = null;
			this.flush().catch((err) => {
				console.error("CachedTaskSource: Failed to flush:", err);
			});
		}, this.flushIntervalMs);
	}

	private registerExitHandlers(): void {
		// Handle normal exit
		const exitHandler = () => {
			if (this.isShuttingDown) return;
			this.isShuttingDown = true;

			if (this.pendingCompletions.size > 0) {
				// Synchronous flush attempt - write each completion immediately
				// This is a best-effort since we can't await in exit handlers
				for (const id of this.pendingCompletions) {
					try {
						// Call markComplete but don't await - it's sync I/O internally
						// for markdown/yaml sources
						this.inner.markComplete(id);
					} catch {
						// Best effort - ignore errors during shutdown
					}
				}
			}
		};

		process.on("exit", exitHandler);
		process.on("SIGINT", () => {
			exitHandler();
			process.exit(130);
		});
		process.on("SIGTERM", () => {
			exitHandler();
			process.exit(143);
		});
	}
}

/**
 * Wrap a TaskSource with caching.
 * Convenience function that returns the same type hints.
 */
export function withCache(
	source: TaskSource,
	options?: CachedTaskSourceOptions,
): CachedTaskSource {
	return new CachedTaskSource(source, options);
}
