import type { AIEngine } from "../engines/types.ts";
import { completeMerge } from "../git/merge.ts";
import { logDebug, logInfo, logError } from "../ui/logger.ts";

/**
 * Build a prompt for AI-assisted conflict resolution
 */
function buildConflictResolutionPrompt(conflictedFiles: string[], branchName: string): string {
	const fileList = conflictedFiles.map((f) => `  - ${f}`).join("\n");

	return `You are resolving a git merge conflict. The following files have conflicts after merging branch "${branchName}":

${fileList}

For each conflicted file:
1. Read the file to see the conflict markers (<<<<<<, =======, >>>>>>>)
2. Understand what both versions are trying to do
3. Edit the file to resolve the conflict by combining both changes appropriately
4. Remove ALL conflict markers - the file should be valid code with no markers remaining
5. Make sure the resulting code is syntactically valid and logically correct

After resolving all conflicts in all files:
1. Run 'git add' on each resolved file to stage it
2. Run 'git commit --no-edit' to complete the merge

Important: Do not create new commits for individual file resolutions. Only run 'git commit --no-edit' once at the very end after ALL files are resolved and staged.`;
}

/**
 * Attempt to resolve merge conflicts using AI
 * Returns true if conflicts were successfully resolved
 */
export async function resolveConflictsWithAI(
	engine: AIEngine,
	conflictedFiles: string[],
	branchName: string,
	workDir: string,
	modelOverride?: string
): Promise<boolean> {
	if (conflictedFiles.length === 0) {
		return true;
	}

	logInfo(`Attempting AI-assisted conflict resolution for ${conflictedFiles.length} file(s)...`);
	logDebug(`Conflicted files: ${conflictedFiles.join(", ")}`);

	const prompt = buildConflictResolutionPrompt(conflictedFiles, branchName);
	const engineOptions = modelOverride ? { modelOverride } : undefined;

	try {
		const result = await engine.execute(prompt, workDir, engineOptions);

		if (result.success) {
			// Verify the merge was completed by the AI
			const completed = await completeMerge(workDir);
			if (completed) {
				logInfo("AI successfully resolved merge conflicts");
				return true;
			}
			// Try to complete it ourselves if AI staged but didn't commit
			logDebug("AI may have resolved files but didn't complete merge, attempting to finalize...");
			return await completeMerge(workDir);
		}

		logError(`AI conflict resolution failed: ${result.error || "Unknown error"}`);
		return false;
	} catch (error) {
		const errorMsg = error instanceof Error ? error.message : String(error);
		logError(`AI conflict resolution error: ${errorMsg}`);
		return false;
	}
}
