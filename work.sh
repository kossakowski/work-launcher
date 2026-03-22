#!/bin/bash
# ============================================================
# WORK LAUNCHER - AI coding launcher for WSL + Windows Terminal
# ============================================================
# Dependencies: fzf (install: sudo apt install fzf)
#
# Usage:
#   work                        → fuzzy search projects, open tabs
#   work anprojekt              → fuzzy match "anprojekt", open tabs
#   work add [name] [path]      → add project (path defaults to $PWD)
#   work rm                     → remove project (fuzzy picker)
#   work ls                     → list all projects
#   work config                 → show current tool config
#   work set-config c=5 g=1 x=0 → set number of claude/gemini/codex tabs
# ============================================================

WORK_PROJECTS_FILE="$HOME/.work_projects"
WORK_CONFIG_FILE="$HOME/.work_config"

# --- config helpers ---

_work_config_get() {
    local key="$1"
    local default="$2"
    if [[ -f "$WORK_CONFIG_FILE" ]]; then
        local val
        val=$(grep "^${key}=" "$WORK_CONFIG_FILE" | cut -d= -f2)
        [[ -n "$val" ]] && echo "$val" || echo "$default"
    else
        echo "$default"
    fi
}

_work_config_set() {
    local key="$1"
    local val="$2"
    if [[ -f "$WORK_CONFIG_FILE" ]] && grep -q "^${key}=" "$WORK_CONFIG_FILE"; then
        sed -i "s/^${key}=.*/${key}=${val}/" "$WORK_CONFIG_FILE"
    else
        echo "${key}=${val}" >> "$WORK_CONFIG_FILE"
    fi
}

# --- tab launcher ---

_work_make_script() {
    local path="$1"
    local tool="$2"   # claude | gemini | codex
    local script="$HOME/.work_launch_${tool}.sh"
    printf '#!/bin/bash\ncd %q\n%s\nexec bash\n' "$path" "$tool" > "$script"
    chmod +x "$script"
    echo "$script"
}

_work_open_tabs() {
    local path="$1"
    local n_claude n_gemini n_codex
    n_claude=$(_work_config_get "CLAUDE" "4")
    n_gemini=$(_work_config_get "GEMINI" "1")
    n_codex=$(_work_config_get  "CODEX"  "1")

    local distro="${WSL_DISTRO_NAME:-Ubuntu}"
    local total=$(( n_claude + n_gemini + n_codex ))

    if (( total == 0 )); then
        echo "All tools set to 0. Use: work set-config c=5 g=1 x=0" >&2
        return 1
    fi

    # Pre-build per-tool launch scripts (avoids semicolons in wt.exe args)
    local s_claude s_gemini s_codex
    (( n_claude > 0 )) && s_claude=$(_work_make_script "$path" "claude")
    (( n_gemini > 0 )) && s_gemini=$(_work_make_script "$path" "gemini")
    (( n_codex  > 0 )) && s_codex=$(_work_make_script  "$path" "codex")

    # Build flat wt.exe args: first tab has no leading ";"
    local wt_args=()
    local first=1

    _add_tabs() {
        local count="$1"
        local script="$2"
        local label="$3"
        for (( i=0; i<count; i++ )); do
            if (( first )); then
                wt_args+=("new-tab" "--title" "$label" "wsl.exe" "-d" "$distro" "--" "bash" "-li" "$script")
                first=0
            else
                wt_args+=(";" "new-tab" "--title" "$label" "wsl.exe" "-d" "$distro" "--" "bash" "-li" "$script")
            fi
        done
    }

    (( n_claude > 0 )) && _add_tabs "$n_claude" "$s_claude" "Claude"
    (( n_gemini > 0 )) && _add_tabs "$n_gemini" "$s_gemini" "Gemini"
    (( n_codex  > 0 )) && _add_tabs "$n_codex"  "$s_codex"  "Codex"

    echo "Opening: ${n_claude}×Claude  ${n_gemini}×Gemini  ${n_codex}×Codex  →  $path"
    wt.exe "${wt_args[@]}"
}

# --- project picker ---

_work_select_project() {
    local query="$1"
    if [[ ! -f "$WORK_PROJECTS_FILE" ]] || [[ ! -s "$WORK_PROJECTS_FILE" ]]; then
        echo "No projects saved. Use: work add [name] [path]" >&2
        return 1
    fi

    local selected
    if [[ -n "$query" ]]; then
        selected=$(grep -i "$query" "$WORK_PROJECTS_FILE" | \
                   fzf --filter="$query" --no-sort | head -1)
        if [[ -z "$selected" ]]; then
            echo "No project matching: $query" >&2
            return 1
        fi
    else
        selected=$(cat "$WORK_PROJECTS_FILE" | \
                   fzf --prompt="Project > " \
                       --preview='echo "Path: $(echo {} | cut -d"|" -f2)"' \
                       --height=40%)
        [[ -z "$selected" ]] && return 1
    fi

    echo "$selected"
}

# --- main function ---

work() {
    local subcmd="$1"

    case "$subcmd" in

        add)
            local name="${2}"
            local path="${3:-$PWD}"
            if [[ -z "$name" ]]; then
                echo "Usage: work add <n> [path]"
                return 1
            fi
            [[ -f "$WORK_PROJECTS_FILE" ]] && sed -i "/^${name}|/d" "$WORK_PROJECTS_FILE"
            echo "${name}|${path}" >> "$WORK_PROJECTS_FILE"
            echo "Added: $name → $path"
            ;;

        rm)
            local selected
            selected=$(_work_select_project) || return 1
            local name
            name=$(echo "$selected" | cut -d'|' -f1)
            sed -i "/^${name}|/d" "$WORK_PROJECTS_FILE"
            echo "Removed: $name"
            ;;

        ls)
            if [[ ! -f "$WORK_PROJECTS_FILE" ]] || [[ ! -s "$WORK_PROJECTS_FILE" ]]; then
                echo "No projects saved."
                return 0
            fi
            echo "Saved projects:"
            column -t -s'|' "$WORK_PROJECTS_FILE" | awk '{printf "  %-20s %s\n", $1, $2}'
            ;;

        config)
            echo "Current tool config:"
            printf "  Claude : %s tabs\n" "$(_work_config_get CLAUDE 5)"
            printf "  Gemini : %s tabs\n" "$(_work_config_get GEMINI 1)"
            printf "  Codex  : %s tabs\n" "$(_work_config_get CODEX  0)"
            echo ""
            echo "Change with: work set-config c=5 g=1 x=0"
            ;;

        set-config)
            shift
            local changed=0
            for arg in "$@"; do
                local k v
                k=$(echo "$arg" | cut -d= -f1 | tr '[:upper:]' '[:lower:]')
                v=$(echo "$arg" | cut -d= -f2)
                if ! [[ "$v" =~ ^[0-9]+$ ]]; then
                    echo "Invalid value '$v' — must be a number." >&2
                    return 1
                fi
                case "$k" in
                    c|claude) _work_config_set "CLAUDE" "$v"; echo "  Claude → $v tabs" ; changed=1 ;;
                    g|gemini) _work_config_set "GEMINI" "$v"; echo "  Gemini → $v tabs" ; changed=1 ;;
                    x|codex)  _work_config_set "CODEX"  "$v"; echo "  Codex  → $v tabs" ; changed=1 ;;
                    *)
                        echo "Unknown key '$k'. Use: c/claude, g/gemini, x/codex" >&2
                        return 1
                        ;;
                esac
            done
            (( changed )) || echo "Nothing changed. Example: work set-config c=5 g=1 x=0"
            ;;

        help|--help|-h)
            echo "work - AI coding launcher for WSL + Windows Terminal"
            echo ""
            echo "  work                    Interactive fuzzy project picker"
            echo "  work <query>            Fuzzy match project by name and open"
            echo "  work add <n> [path]     Add project (path defaults to cwd)"
            echo "  work rm                 Remove a project (fuzzy picker)"
            echo "  work ls                 List all projects"
            echo "  work config             Show current tool tab counts"
            echo "  work set-config c=N g=N x=N"
            echo "                          Set tabs: c=claude g=gemini x=codex"
            echo ""
            echo "  Defaults: claude=4, gemini=1, codex=1"
            ;;

        *)
            local selected
            selected=$(_work_select_project "$subcmd") || return 1
            local path
            path=$(echo "$selected" | cut -d'|' -f2)
            if [[ ! -d "$path" ]]; then
                echo "Path not found: $path" >&2
                return 1
            fi
            _work_open_tabs "$path"
            ;;
    esac
}

# Tab completion
_work_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local subcommands="add rm ls config set-config help"
    if [[ COMP_CWORD -eq 1 ]]; then
        local projects=""
        [[ -f "$WORK_PROJECTS_FILE" ]] && projects=$(cut -d'|' -f1 "$WORK_PROJECTS_FILE" | tr '\n' ' ')
        COMPREPLY=($(compgen -W "$subcommands $projects" -- "$cur"))
    fi
}
complete -F _work_completions work
