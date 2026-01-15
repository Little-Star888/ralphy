#!/bin/bash

# ============================================
# Ralphy - Autonomous AI Coding Loop
# Supports both Claude Code and OpenCode
# Runs until PRD is complete
# ============================================

set -euo pipefail

# ============================================
# CONFIGURATION & DEFAULTS
# ============================================

VERSION="2.0.0"

# Runtime options
SKIP_TESTS=false
SKIP_LINT=false
USE_OPENCODE=false
DRY_RUN=false
MAX_ITERATIONS=0  # 0 = unlimited
MAX_RETRIES=3
RETRY_DELAY=5
VERBOSE=false

# Colors (detect if terminal supports colors)
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
  MAGENTA=$(tput setaf 5)
  CYAN=$(tput setaf 6)
  BOLD=$(tput bold)
  DIM=$(tput dim)
  RESET=$(tput sgr0)
else
  RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" BOLD="" DIM="" RESET=""
fi

# Global state
ai_pid=""
monitor_pid=""
tmpfile=""
current_step="Thinking"
total_input_tokens=0
total_output_tokens=0
iteration=0
retry_count=0

# ============================================
# UTILITY FUNCTIONS
# ============================================

log_info() {
  echo "${BLUE}[INFO]${RESET} $*"
}

log_success() {
  echo "${GREEN}[OK]${RESET} $*"
}

log_warn() {
  echo "${YELLOW}[WARN]${RESET} $*"
}

log_error() {
  echo "${RED}[ERROR]${RESET} $*" >&2
}

log_debug() {
  if [[ "$VERBOSE" == true ]]; then
    echo "${DIM}[DEBUG] $*${RESET}"
  fi
}

# ============================================
# HELP & VERSION
# ============================================

show_help() {
  cat << EOF
${BOLD}Ralphy${RESET} - Autonomous AI Coding Loop (v${VERSION})

${BOLD}USAGE:${RESET}
  ./ralphy.sh [options]

${BOLD}AI ENGINE OPTIONS:${RESET}
  --opencode          Use OpenCode instead of Claude Code
  --claude            Use Claude Code (default)

${BOLD}WORKFLOW OPTIONS:${RESET}
  --no-tests          Skip writing and running tests
  --no-lint           Skip linting
  --fast              Skip both tests and linting

${BOLD}EXECUTION OPTIONS:${RESET}
  --max-iterations N  Stop after N iterations (0 = unlimited)
  --max-retries N     Max retries per task on failure (default: 3)
  --retry-delay N     Seconds between retries (default: 5)
  --dry-run           Show what would be done without executing

${BOLD}OTHER OPTIONS:${RESET}
  -v, --verbose       Show debug output
  -h, --help          Show this help
  --version           Show version number

${BOLD}EXAMPLES:${RESET}
  ./ralphy.sh                    # Run with Claude Code
  ./ralphy.sh --opencode         # Run with OpenCode
  ./ralphy.sh --fast --opencode  # Fast mode with OpenCode
  ./ralphy.sh --max-iterations 5 # Stop after 5 tasks

${BOLD}REQUIRED FILES:${RESET}
  PRD.md        Product requirements with checkbox tasks (- [ ] task)
  progress.txt  Created automatically if missing

EOF
}

show_version() {
  echo "Ralphy v${VERSION}"
}

# ============================================
# ARGUMENT PARSING
# ============================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --no-tests|--skip-tests)
        SKIP_TESTS=true
        shift
        ;;
      --no-lint|--skip-lint)
        SKIP_LINT=true
        shift
        ;;
      --fast)
        SKIP_TESTS=true
        SKIP_LINT=true
        shift
        ;;
      --opencode)
        USE_OPENCODE=true
        shift
        ;;
      --claude)
        USE_OPENCODE=false
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --max-iterations)
        MAX_ITERATIONS="${2:-0}"
        shift 2
        ;;
      --max-retries)
        MAX_RETRIES="${2:-3}"
        shift 2
        ;;
      --retry-delay)
        RETRY_DELAY="${2:-5}"
        shift 2
        ;;
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      --version)
        show_version
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        echo "Use --help for usage"
        exit 1
        ;;
    esac
  done
}

# ============================================
# PRE-FLIGHT CHECKS
# ============================================

check_requirements() {
  local missing=()

  # Check for PRD.md
  if [[ ! -f "PRD.md" ]]; then
    log_error "PRD.md not found in current directory"
    exit 1
  fi

  # Check for AI CLI
  if [[ "$USE_OPENCODE" == true ]]; then
    if ! command -v opencode &>/dev/null; then
      log_error "OpenCode CLI not found. Install from https://opencode.ai/docs/"
      exit 1
    fi
  else
    if ! command -v claude &>/dev/null; then
      log_error "Claude Code CLI not found. Install from https://github.com/anthropics/claude-code"
      exit 1
    fi
  fi

  # Check for jq
  if ! command -v jq &>/dev/null; then
    missing+=("jq")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_warn "Missing optional dependencies: ${missing[*]}"
    log_warn "Token tracking may not work properly"
  fi

  # Create progress.txt if missing
  if [[ ! -f "progress.txt" ]]; then
    log_warn "progress.txt not found, creating it..."
    touch progress.txt
  fi
}

# ============================================
# CLEANUP HANDLER
# ============================================

cleanup() {
  local exit_code=$?
  
  # Kill background processes
  [[ -n "$monitor_pid" ]] && kill "$monitor_pid" 2>/dev/null || true
  [[ -n "$ai_pid" ]] && kill "$ai_pid" 2>/dev/null || true
  
  # Kill any remaining child processes
  pkill -P $$ 2>/dev/null || true
  
  # Remove temp file
  [[ -n "$tmpfile" ]] && rm -f "$tmpfile"
  
  # Show message on interrupt
  if [[ $exit_code -eq 130 ]]; then
    printf "\n"
    log_warn "Interrupted! Cleaned up."
  fi
}

# ============================================
# TASK DETECTION
# ============================================

get_next_task() {
  grep -m1 '^\- \[ \]' PRD.md 2>/dev/null | sed 's/^- \[ \] //' | cut -c1-50 || echo "Working..."
}

count_remaining_tasks() {
  grep -c '^\- \[ \]' PRD.md 2>/dev/null || echo "0"
}

count_completed_tasks() {
  grep -c '^\- \[x\]' PRD.md 2>/dev/null || echo "0"
}

# ============================================
# PROGRESS MONITOR
# ============================================

monitor_progress() {
  local file=$1
  local task=$2
  local start_time
  start_time=$(date +%s)
  local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local spin_idx=0

  task="${task:0:40}"

  while true; do
    local elapsed=$(($(date +%s) - start_time))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    # Check latest output for step indicators
    if [[ -f "$file" ]] && [[ -s "$file" ]]; then
      local content
      content=$(tail -c 5000 "$file" 2>/dev/null || true)

      if echo "$content" | grep -qE 'git commit|"command":"git commit'; then
        current_step="Committing"
      elif echo "$content" | grep -qE 'git add|"command":"git add'; then
        current_step="Staging"
      elif echo "$content" | grep -qE 'progress\.txt'; then
        current_step="Logging"
      elif echo "$content" | grep -qE 'PRD\.md'; then
        current_step="Updating PRD"
      elif echo "$content" | grep -qE 'lint|eslint|biome|prettier'; then
        current_step="Linting"
      elif echo "$content" | grep -qE 'vitest|jest|bun test|npm test|pytest|go test'; then
        current_step="Testing"
      elif echo "$content" | grep -qE '\.test\.|\.spec\.|__tests__|_test\.go'; then
        current_step="Writing tests"
      elif echo "$content" | grep -qE '"tool":"[Ww]rite"|"tool":"[Ee]dit"|"name":"write"|"name":"edit"'; then
        current_step="Implementing"
      elif echo "$content" | grep -qE '"tool":"[Rr]ead"|"tool":"[Gg]lob"|"tool":"[Gg]rep"|"name":"read"|"name":"glob"|"name":"grep"'; then
        current_step="Reading code"
      fi
    fi

    local spinner_char="${spinstr:$spin_idx:1}"
    local step_color=""
    
    # Color-code steps
    case "$current_step" in
      "Thinking"|"Reading code") step_color="$CYAN" ;;
      "Implementing"|"Writing tests") step_color="$MAGENTA" ;;
      "Testing"|"Linting") step_color="$YELLOW" ;;
      "Staging"|"Committing") step_color="$GREEN" ;;
      *) step_color="$BLUE" ;;
    esac

    # Use tput for cleaner line clearing
    tput cr 2>/dev/null || printf "\r"
    tput el 2>/dev/null || true
    printf "  %s ${step_color}%-16s${RESET} │ %s ${DIM}[%02d:%02d]${RESET}" "$spinner_char" "$current_step" "$task" "$mins" "$secs"

    spin_idx=$(( (spin_idx + 1) % ${#spinstr} ))
    sleep 0.12
  done
}

# ============================================
# NOTIFICATION (Cross-platform)
# ============================================

notify_done() {
  local message="${1:-Ralphy has completed all tasks!}"
  
  # macOS
  if command -v afplay &>/dev/null; then
    afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
  fi
  
  # macOS notification
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$message\" with title \"Ralphy\"" 2>/dev/null || true
  fi
  
  # Linux (notify-send)
  if command -v notify-send &>/dev/null; then
    notify-send "Ralphy" "$message" 2>/dev/null || true
  fi
  
  # Linux (paplay for sound)
  if command -v paplay &>/dev/null; then
    paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null &
  fi
  
  # Windows (powershell)
  if command -v powershell.exe &>/dev/null; then
    powershell.exe -Command "[System.Media.SystemSounds]::Asterisk.Play()" 2>/dev/null || true
  fi
}

notify_error() {
  local message="${1:-Ralphy encountered an error}"
  
  # macOS
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$message\" with title \"Ralphy - Error\"" 2>/dev/null || true
  fi
  
  # Linux
  if command -v notify-send &>/dev/null; then
    notify-send -u critical "Ralphy - Error" "$message" 2>/dev/null || true
  fi
}

# ============================================
# PROMPT BUILDER
# ============================================

build_prompt() {
  local prompt="@PRD.md @progress.txt
1. Find the highest-priority incomplete task and implement it."

  local step=2
  
  if [[ "$SKIP_TESTS" == false ]]; then
    prompt="$prompt
$step. Write tests for the feature.
$((step+1)). Run tests and ensure they pass before proceeding."
    step=$((step+2))
  fi

  if [[ "$SKIP_LINT" == false ]]; then
    prompt="$prompt
$step. Run linting and ensure it passes before proceeding."
    step=$((step+1))
  fi

  prompt="$prompt
$step. Update the PRD to mark the task as complete.
$((step+1)). Append your progress to progress.txt.
$((step+2)). Commit your changes with a descriptive message.
ONLY WORK ON A SINGLE TASK."

  if [[ "$SKIP_TESTS" == false ]]; then
    prompt="$prompt Do not proceed if tests fail."
  fi
  if [[ "$SKIP_LINT" == false ]]; then
    prompt="$prompt Do not proceed if linting fails."
  fi

  prompt="$prompt
If ALL tasks in the PRD are complete, output <promise>COMPLETE</promise>."

  echo "$prompt"
}

# ============================================
# AI ENGINE ABSTRACTION
# ============================================

run_ai_command() {
  local prompt=$1
  local output_file=$2
  
  if [[ "$USE_OPENCODE" == true ]]; then
    # OpenCode: use 'run' command with JSON format and permissive settings
    # Using OPENCODE_PERMISSION env var for allow-all
    OPENCODE_PERMISSION='{"*":"allow"}' opencode run \
      --format json \
      "$prompt" > "$output_file" 2>&1 &
  else
    # Claude Code: use existing approach
    claude --dangerously-skip-permissions \
      --verbose \
      --output-format stream-json \
      -p "$prompt" > "$output_file" 2>&1 &
  fi
  
  ai_pid=$!
}

parse_ai_result() {
  local result=$1
  local response=""
  local input_tokens=0
  local output_tokens=0
  
  if [[ "$USE_OPENCODE" == true ]]; then
    # OpenCode JSON format parsing
    # OpenCode outputs newline-delimited JSON events
    local last_result
    last_result=$(echo "$result" | grep '"type":"result"' | tail -1 || echo "")
    
    if [[ -n "$last_result" ]]; then
      response=$(echo "$last_result" | jq -r '.result // .text // "No result text"' 2>/dev/null || echo "Could not parse result")
      input_tokens=$(echo "$last_result" | jq -r '.usage.input_tokens // .usage.inputTokens // 0' 2>/dev/null || echo "0")
      output_tokens=$(echo "$last_result" | jq -r '.usage.output_tokens // .usage.outputTokens // 0' 2>/dev/null || echo "0")
    else
      # Try to get any text from the stream
      response=$(echo "$result" | jq -sr 'map(select(.text)) | .[].text' 2>/dev/null | tail -1 || echo "$result" | tail -20)
    fi
  else
    # Claude Code stream-json parsing
    local result_line
    result_line=$(echo "$result" | grep '"type":"result"' | tail -1)
    
    if [[ -n "$result_line" ]]; then
      response=$(echo "$result_line" | jq -r '.result // "No result text"' 2>/dev/null || echo "Could not parse result")
      input_tokens=$(echo "$result_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo "0")
      output_tokens=$(echo "$result_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo "0")
    fi
  fi
  
  # Sanitize token counts
  [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
  [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0
  
  echo "$response"
  echo "---TOKENS---"
  echo "$input_tokens"
  echo "$output_tokens"
}

check_for_errors() {
  local result=$1
  
  # Check for API errors in stream
  if echo "$result" | grep -q '"type":"error"'; then
    local error_msg
    error_msg=$(echo "$result" | grep '"type":"error"' | head -1 | jq -r '.error.message // .message // .' 2>/dev/null || echo "Unknown error")
    echo "$error_msg"
    return 1
  fi
  
  return 0
}

# ============================================
# COST CALCULATION
# ============================================

calculate_cost() {
  local input=$1
  local output=$2
  
  if command -v bc &>/dev/null; then
    # Claude pricing: $3/M input, $15/M output
    echo "scale=4; ($input * 0.000003) + ($output * 0.000015)" | bc
  else
    echo "N/A"
  fi
}

# ============================================
# MAIN LOOP
# ============================================

run_iteration() {
  ((iteration++))
  retry_count=0
  
  echo ""
  echo "${BOLD}>>> Task $iteration${RESET}"
  
  local remaining
  remaining=$(count_remaining_tasks)
  local completed
  completed=$(count_completed_tasks)
  echo "${DIM}    Completed: $completed | Remaining: $remaining${RESET}"
  echo "--------------------------------------------"

  # Get current task for display
  current_task=$(get_next_task)
  current_step="Thinking"

  # Temp file for AI output
  tmpfile=$(mktemp)

  # Build the prompt
  local prompt
  prompt=$(build_prompt)

  if [[ "$DRY_RUN" == true ]]; then
    log_info "DRY RUN - Would execute:"
    echo "${DIM}$prompt${RESET}"
    rm -f "$tmpfile"
    tmpfile=""
    return 0
  fi

  # Run with retry logic
  while [[ $retry_count -lt $MAX_RETRIES ]]; do
    # Start AI command
    run_ai_command "$prompt" "$tmpfile"

    # Start progress monitor in background
    monitor_progress "$tmpfile" "$current_task" &
    monitor_pid=$!

    # Wait for AI to finish
    wait "$ai_pid" 2>/dev/null || true
    local exit_code=$?

    # Stop the monitor
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    monitor_pid=""

    # Show completion
    tput cr 2>/dev/null || printf "\r"
    tput el 2>/dev/null || true

    # Read result
    local result
    result=$(cat "$tmpfile" 2>/dev/null || echo "")

    # Check for empty response
    if [[ -z "$result" ]]; then
      ((retry_count++))
      log_error "Empty response (attempt $retry_count/$MAX_RETRIES)"
      if [[ $retry_count -lt $MAX_RETRIES ]]; then
        log_info "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        continue
      fi
      rm -f "$tmpfile"
      tmpfile=""
      return 1
    fi

    # Check for API errors
    local error_msg
    if ! error_msg=$(check_for_errors "$result"); then
      ((retry_count++))
      log_error "API error: $error_msg (attempt $retry_count/$MAX_RETRIES)"
      if [[ $retry_count -lt $MAX_RETRIES ]]; then
        log_info "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        continue
      fi
      rm -f "$tmpfile"
      tmpfile=""
      return 1
    fi

    # Parse the result
    local parsed
    parsed=$(parse_ai_result "$result")
    local response
    response=$(echo "$parsed" | sed '/^---TOKENS---$/,$d')
    local tokens
    tokens=$(echo "$parsed" | sed -n '/^---TOKENS---$/,$p' | tail -2)
    local input_tokens
    input_tokens=$(echo "$tokens" | head -1)
    local output_tokens
    output_tokens=$(echo "$tokens" | tail -1)

    printf "  ${GREEN}✓${RESET} %-16s │ %s\n" "Done" "$current_task"
    
    if [[ -n "$response" ]]; then
      echo ""
      echo "$response"
    fi

    # Update totals
    total_input_tokens=$((total_input_tokens + input_tokens))
    total_output_tokens=$((total_output_tokens + output_tokens))

    rm -f "$tmpfile"
    tmpfile=""

    # Check for completion
    if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
      return 2  # Special code for "all done"
    fi

    return 0
  done

  return 1
}

show_summary() {
  echo ""
  echo "${BOLD}============================================${RESET}"
  echo "${GREEN}PRD complete!${RESET} Finished $iteration task(s)."
  echo "${BOLD}============================================${RESET}"
  echo ""
  echo "${BOLD}>>> Cost Summary${RESET}"
  echo "Input tokens:  $total_input_tokens"
  echo "Output tokens: $total_output_tokens"
  echo "Total tokens:  $((total_input_tokens + total_output_tokens))"
  
  local cost
  cost=$(calculate_cost "$total_input_tokens" "$total_output_tokens")
  echo "Est. cost:     \$$cost"
  echo "${BOLD}============================================${RESET}"
}

main() {
  parse_args "$@"
  
  # Set up cleanup trap
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP
  
  # Check requirements
  check_requirements
  
  # Show banner
  echo "${BOLD}============================================${RESET}"
  echo "${BOLD}Ralphy${RESET} - Running until PRD is complete"
  echo "Engine: $([ "$USE_OPENCODE" = true ] && echo "${CYAN}OpenCode${RESET}" || echo "${MAGENTA}Claude Code${RESET}")"
  
  local mode_parts=()
  [[ "$SKIP_TESTS" == true ]] && mode_parts+=("no-tests")
  [[ "$SKIP_LINT" == true ]] && mode_parts+=("no-lint")
  [[ "$DRY_RUN" == true ]] && mode_parts+=("dry-run")
  [[ $MAX_ITERATIONS -gt 0 ]] && mode_parts+=("max:$MAX_ITERATIONS")
  
  if [[ ${#mode_parts[@]} -gt 0 ]]; then
    echo "Mode: ${YELLOW}${mode_parts[*]}${RESET}"
  fi
  echo "${BOLD}============================================${RESET}"

  # Main loop
  while true; do
    local result_code=0
    run_iteration || result_code=$?
    
    case $result_code in
      0)
        # Success, continue
        ;;
      1)
        # Error, but continue to next task
        log_warn "Task failed after $MAX_RETRIES attempts, continuing..."
        ;;
      2)
        # All tasks complete
        show_summary
        notify_done
        exit 0
        ;;
    esac
    
    # Check max iterations
    if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
      log_warn "Reached max iterations ($MAX_ITERATIONS)"
      show_summary
      notify_done "Ralphy stopped after $MAX_ITERATIONS iterations"
      exit 0
    fi
    
    # Small delay between iterations
    sleep 1
  done
}

# Run main
main "$@"
