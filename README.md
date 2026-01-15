# Ralphy - Autonomous AI Coding Loop

Ralphy is a bash script that runs AI coding assistants (Claude Code or OpenCode) in an autonomous loop, working through tasks in your PRD until everything is complete.

## Features

- **Multi-engine support**: Works with both Claude Code and OpenCode
- **Autonomous loop**: Runs until all PRD tasks are complete
- **Progress visualization**: Real-time spinner with color-coded step detection
- **Retry logic**: Automatic retries with configurable delay on failures
- **Cost tracking**: Token usage and cost estimation at completion
- **Cross-platform notifications**: macOS, Linux, and Windows support
- **Iteration limits**: Optional max iterations to prevent runaway loops
- **Dry-run mode**: Preview what would be done without executing

## Prerequisites

- [Claude Code CLI](https://github.com/anthropics/claude-code) or [OpenCode CLI](https://opencode.ai/docs/)
- `jq` for JSON parsing
- `bc` for cost calculation (optional)

## Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/ralphy.git
   cd ralphy
   ```

2. Make the script executable:
   ```bash
   chmod +x ralphy.sh
   ```

3. Create a `PRD.md` file in your project directory with tasks formatted as:
   ```markdown
   # My Project PRD

   ## Tasks
   - [ ] Implement user authentication
   - [ ] Add dashboard page
   - [ ] Create API endpoints
   ```

## Usage

Run Ralphy from your project directory:

```bash
./ralphy.sh
```

Ralphy will:
1. Find the next incomplete task (`- [ ]`) in your PRD.md
2. Implement the feature
3. Write and run tests (unless skipped)
4. Run linting (unless skipped)
5. Update PRD.md to mark the task complete (`- [x]`)
6. Log progress to progress.txt
7. Commit the changes
8. Repeat until all tasks are done

## AI Engine Selection

| Flag | Description |
|------|-------------|
| `--claude` | Use Claude Code (default) |
| `--opencode` | Use OpenCode instead of Claude Code |

### Examples

```bash
# Run with Claude Code (default)
./ralphy.sh

# Run with OpenCode
./ralphy.sh --opencode

# Fast mode with OpenCode
./ralphy.sh --opencode --fast
```

## Workflow Options

| Flag | Description |
|------|-------------|
| `--no-tests` | Skip writing and running tests |
| `--no-lint` | Skip linting |
| `--fast` | Skip both tests and linting |

## Execution Options

| Flag | Description |
|------|-------------|
| `--max-iterations N` | Stop after N iterations (0 = unlimited) |
| `--max-retries N` | Max retries per task on failure (default: 3) |
| `--retry-delay N` | Seconds between retries (default: 5) |
| `--dry-run` | Show what would be done without executing |

## Other Options

| Flag | Description |
|------|-------------|
| `-v, --verbose` | Show debug output |
| `-h, --help` | Show help message |
| `--version` | Show version number |

## Examples

```bash
# Full mode with tests and linting (Claude Code)
./ralphy.sh

# Use OpenCode instead
./ralphy.sh --opencode

# Skip tests only
./ralphy.sh --no-tests

# Skip linting only
./ralphy.sh --no-lint

# Fast mode - skip both tests and linting
./ralphy.sh --fast

# Limit to 5 iterations
./ralphy.sh --max-iterations 5

# Preview without executing
./ralphy.sh --dry-run

# Combine options
./ralphy.sh --opencode --fast --max-iterations 10
```

## Required Files

| File | Required | Description |
|------|----------|-------------|
| `PRD.md` | Yes | Your product requirements with checkbox tasks |
| `progress.txt` | No | Created automatically if missing; logs progress |

## Progress Indicator

The progress indicator shows:
- **Spinner**: Animated status indicator
- **Current step**: Color-coded step name (Thinking, Reading code, Implementing, Writing tests, Testing, Linting, Staging, Committing)
- **Task name**: Current task being worked on
- **Elapsed time**: Time spent on current task

Step colors:
- 🔵 Cyan: Thinking, Reading code
- 🟣 Magenta: Implementing, Writing tests
- 🟡 Yellow: Testing, Linting
- 🟢 Green: Staging, Committing

## How It Works

### Claude Code Mode
Uses Claude Code's `--dangerously-skip-permissions` flag to run autonomously without confirmation prompts.

### OpenCode Mode
Uses OpenCode's `run` command with `OPENCODE_PERMISSION='{"*":"allow"}'` environment variable for autonomous operation.

Each iteration:
1. Reads your PRD.md and progress.txt for context
2. Identifies the highest-priority incomplete task
3. Implements the feature with tests and linting (unless skipped)
4. Marks the task complete and commits
5. Outputs `<promise>COMPLETE</promise>` when all tasks are done

## Cost Tracking

At completion, Ralphy displays:
- Total input tokens
- Total output tokens
- Estimated cost (based on Claude API pricing)

## Cross-Platform Notifications

Ralphy sends notifications when complete:

| Platform | Notification | Sound |
|----------|--------------|-------|
| macOS | Native notification | Glass.aiff |
| Linux | notify-send | freedesktop complete sound |
| Windows | PowerShell | System asterisk |

## Error Handling

- **Retry logic**: Failed API calls retry up to 3 times (configurable)
- **Graceful degradation**: Missing optional tools (bc) don't break execution
- **Clean shutdown**: Ctrl+C gracefully stops and cleans up
- **Error recovery**: Continues to next task after max retries exceeded

## Tips

- Keep PRD tasks small and focused for best results
- Use `--fast` for rapid prototyping, then run tests separately
- Use `--max-iterations` when you want controlled execution
- Check `progress.txt` for a log of what was done
- Use `--dry-run` to preview the prompt before executing
- Press Ctrl+C to stop gracefully at any time

## Changelog

### v2.0.0
- Added OpenCode support (`--opencode` flag)
- Refactored architecture for better maintainability
- Added retry logic with configurable retries and delay
- Added `--max-iterations` flag
- Added `--dry-run` mode
- Improved progress UI with colors
- Added cross-platform notification support (Linux/Windows)
- Added `--verbose` flag for debugging
- Better error handling and recovery

### v1.0.0
- Initial release with Claude Code support

## License

MIT
