# Ralphy - Autonomous AI Coding Loop

Ralphy is a bash script that runs AI coding assistants (Claude Code or OpenCode) in an autonomous loop, working through tasks until everything is complete.

## Features

- **Multi-engine support**: Works with both Claude Code and OpenCode
- **Multiple PRD formats**: Markdown, YAML, or GitHub Issues
- **Parallel execution**: Run independent tasks concurrently
- **Git branch workflow**: Create feature branches and PRs automatically
- **Retry logic**: Automatic retries with configurable delay on failures
- **Progress visualization**: Real-time spinner with color-coded step detection
- **Cost tracking**: Token usage and cost estimation at completion
- **Cross-platform**: macOS, Linux, and Windows support

## Prerequisites

- [Claude Code CLI](https://github.com/anthropics/claude-code) or [OpenCode CLI](https://opencode.ai/docs/)
- `jq` for JSON parsing
- `yq` for YAML parsing (optional, only if using YAML tasks)
- `gh` for GitHub integration (optional, only if using GitHub Issues)
- `bc` for cost calculation (optional)

## Quick Start

```bash
# Clone and setup
git clone https://github.com/yourusername/ralphy.git
chmod +x ralphy.sh

# Create a PRD.md with tasks
cat > PRD.md << 'EOF'
# My Project

## Tasks
- [ ] Create user authentication
- [ ] Add dashboard page
- [ ] Build API endpoints
EOF

# Run Ralphy
./ralphy.sh
```

## AI Engine Selection

| Flag | Description |
|------|-------------|
| `--claude` | Use Claude Code (default) |
| `--opencode` | Use OpenCode instead of Claude Code |

```bash
./ralphy.sh --opencode
```

## PRD Sources

Ralphy supports three task sources:

### 1. Markdown (default)

```bash
./ralphy.sh --prd PRD.md
```

Format:
```markdown
# Project PRD

## Tasks
- [ ] Task one
- [ ] Task two
- [x] Completed task
```

### 2. YAML

```bash
./ralphy.sh --yaml tasks.yaml
```

Format:
```yaml
tasks:
  - title: Implement user login
    completed: false
    parallel_group: 1  # Optional: tasks with same group can run in parallel
  
  - title: Implement user signup  
    completed: false
    parallel_group: 1  # Same group as login - can run together
  
  - title: Add password reset
    completed: false
    parallel_group: 2  # Different group - runs after group 1
```

### 3. GitHub Issues

```bash
./ralphy.sh --github owner/repo
./ralphy.sh --github owner/repo --github-label "ready"
```

Uses open issues from the specified repository. Issues are closed automatically when completed.

## Parallel Execution

Spin up multiple AI agents simultaneously, each working in its own isolated git worktree:

```bash
# Run up to 3 agents in parallel (default)
./ralphy.sh --parallel

# Run up to 5 agents in parallel
./ralphy.sh --parallel --max-parallel 5

# Parallel with automatic PR creation
./ralphy.sh --parallel --create-pr
```

### How Parallel Mode Works

1. **Isolated Worktrees** - Each agent gets its own git worktree (separate directory)
2. **Separate Branches** - Each agent works on its own branch (`ralphy/agent-N-task-name`)
3. **No Conflicts** - Agents can't interfere with each other's work
4. **Batched Execution** - Tasks run in batches of `--max-parallel` size

```
Batch 1: Agent 1 ─┬─► Branch: ralphy/agent-1-create-user-model
         Agent 2 ─┼─► Branch: ralphy/agent-2-create-post-model  
         Agent 3 ─┘─► Branch: ralphy/agent-3-add-api-endpoints

Batch 2: Agent 4 ───► Branch: ralphy/agent-4-add-authentication
         Agent 5 ───► Branch: ralphy/agent-5-add-dashboard
```

### YAML Parallel Groups (optional)

Control which tasks can run together:

```yaml
tasks:
  - title: Create User model
    parallel_group: 1
  - title: Create Post model
    parallel_group: 1  # Runs with User model
  - title: Add relationships
    parallel_group: 2  # Runs after group 1 completes
```

## Git Branch Workflow

Create a separate branch for each task with optional PR creation:

```bash
# Create feature branches
./ralphy.sh --branch-per-task

# Specify base branch (default: current branch)
./ralphy.sh --branch-per-task --base-branch main

# Create PRs automatically
./ralphy.sh --branch-per-task --create-pr

# Create draft PRs
./ralphy.sh --branch-per-task --create-pr --draft-pr
```

Branch naming: `ralphy/<slugified-task-name>`

Example: Task "Add user authentication" → Branch `ralphy/add-user-authentication`

## All Options

### Workflow Options
| Flag | Description |
|------|-------------|
| `--no-tests` | Skip writing and running tests |
| `--no-lint` | Skip linting |
| `--fast` | Skip both tests and linting |

### Execution Options
| Flag | Description |
|------|-------------|
| `--max-iterations N` | Stop after N iterations (0 = unlimited) |
| `--max-retries N` | Max retries per task on failure (default: 3) |
| `--retry-delay N` | Seconds between retries (default: 5) |
| `--dry-run` | Show what would be done without executing |

### Parallel Options
| Flag | Description |
|------|-------------|
| `--parallel` | Run independent tasks in parallel |
| `--max-parallel N` | Max concurrent tasks (default: 3) |

### Git Branch Options
| Flag | Description |
|------|-------------|
| `--branch-per-task` | Create a new git branch for each task |
| `--base-branch NAME` | Base branch to create task branches from |
| `--create-pr` | Create a pull request after each task |
| `--draft-pr` | Create PRs as drafts |

### PRD Source Options
| Flag | Description |
|------|-------------|
| `--prd FILE` | PRD file path (default: PRD.md) |
| `--yaml FILE` | Use YAML task file instead of markdown |
| `--github REPO` | Fetch tasks from GitHub issues (e.g., owner/repo) |
| `--github-label TAG` | Filter GitHub issues by label |

### Other Options
| Flag | Description |
|------|-------------|
| `-v, --verbose` | Show debug output |
| `-h, --help` | Show help message |
| `--version` | Show version number |

## Examples

```bash
# Basic usage with Claude Code
./ralphy.sh

# Use OpenCode with fast mode
./ralphy.sh --opencode --fast

# Feature branch workflow with PRs
./ralphy.sh --branch-per-task --create-pr --base-branch main

# Parallel execution with GitHub Issues
./ralphy.sh --github myorg/myrepo --parallel --max-parallel 4

# YAML tasks with parallel groups
./ralphy.sh --yaml tasks.yaml --parallel

# Limit iterations and create draft PRs
./ralphy.sh --max-iterations 5 --branch-per-task --create-pr --draft-pr

# Dry run to preview
./ralphy.sh --dry-run --verbose
```

## Progress Indicator

The progress indicator shows:
- **Spinner**: Animated status indicator
- **Current step**: Color-coded (Thinking → Reading → Implementing → Testing → Committing)
- **Task name**: Current task being worked on
- **Elapsed time**: Time spent on current task

## Cost Tracking

At completion, Ralphy displays:
- Total input/output tokens
- Estimated cost (based on Claude API pricing)
- Branches created (if using `--branch-per-task`)

## How It Works

1. **Read tasks** from PRD.md, YAML file, or GitHub Issues
2. **Create branch** (optional) for the task
3. **Send prompt** to AI with task context
4. **AI implements** the feature, writes tests, runs linting
5. **Mark complete** and commit changes
6. **Create PR** (optional) for the branch
7. **Repeat** until all tasks are done

### Autonomous Operation

- **Claude Code**: Uses `--dangerously-skip-permissions` flag
- **OpenCode**: Uses `OPENCODE_PERMISSION='{"*":"allow"}'` environment variable

## Changelog

### v3.0.0
- Added parallel task execution (`--parallel`, `--max-parallel`)
- Added git branch per task (`--branch-per-task`, `--create-pr`, `--draft-pr`)
- Added multiple PRD formats (Markdown, YAML, GitHub Issues)
- Added YAML parallel groups for controlled concurrency
- Improved task interface abstraction

### v2.0.0
- Added OpenCode support (`--opencode` flag)
- Added retry logic with configurable retries and delay
- Added `--max-iterations`, `--dry-run`, `--verbose` flags
- Improved progress UI with colors
- Added cross-platform notification support

### v1.0.0
- Initial release with Claude Code support

## License

MIT
