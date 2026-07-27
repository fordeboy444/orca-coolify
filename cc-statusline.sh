#!/usr/bin/env bash
# Claude Code custom status line — shows the real backing Ollama Cloud model
# (e.g. glm-5.2:cloud) instead of the built-in tier alias ("Opus"/"Sonnet 5"/...),
# followed by the reasoning-effort level (or "fast" in fast mode).
#
# Wired up by entrypoint.sh, which idempotently sets:
#   ~/.claude/settings.json .statusLine = {type:"command", command:"/opt/cc-statusline.sh", padding:2}
# The statusLine command receives a JSON payload on stdin (see code.claude.com/docs/en/statusline)
# with model.id, model.display_name, effort.level, fast_mode, etc. Its stdout replaces the
# built-in footer. The command inherits the container env, so the ANTHROPIC_DEFAULT_*_MODEL
# override vars (set by Coolify) are visible here.
#
# Resolution order (the docs don't document whether model.id carries the override tag or
# the canonical Anthropic id under a custom ANTHROPIC_BASE_URL, so we handle both):
#   1. model.id already looks like a real Ollama Cloud tag -> use it directly.
#   2. model.id is a canonical Anthropic id (claude-opus-5, etc.) -> map the tier to the
#      matching ANTHROPIC_DEFAULT_*_MODEL env var.
#   3. fall back to model.display_name (the tier alias, e.g. "Opus 5") -> matching override
#      env var; unknown -> ANTHROPIC_MODEL.

set -u
input=$(cat)
id=$(printf '%s' "$input"    | jq -r '.model.id // empty')
dn=$(printf '%s' "$input"    | jq -r '.model.display_name // empty' | tr '[:upper:]' '[:lower:]')
effort=$(printf '%s' "$input" | jq -r '.effort.level // empty')
fast=$(printf '%s' "$input"   | jq -r '.fast_mode // false')

case "$id" in
  *:cloud|*:latest|glm-*|minimax-*|deepseek-*|kimi-*|qwen*|gemma*|nemotron*)
    model="$id" ;;
  *opus*|claude-opus*)     model="${ANTHROPIC_DEFAULT_OPUS_MODEL:-$id}" ;;
  *sonnet*|claude-sonnet*) model="${ANTHROPIC_DEFAULT_SONNET_MODEL:-$id}" ;;
  *haiku*|claude-haiku*)   model="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-$id}" ;;
  *fable*|claude-fable*)   model="${ANTHROPIC_DEFAULT_FABLE_MODEL:-$id}" ;;
  *)
    case "$dn" in
      *opus*)   model="${ANTHROPIC_DEFAULT_OPUS_MODEL:-$id}" ;;
      *sonnet*) model="${ANTHROPIC_DEFAULT_SONNET_MODEL:-$id}" ;;
      *haiku*)  model="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-$id}" ;;
      *fable*)  model="${ANTHROPIC_DEFAULT_FABLE_MODEL:-$id}" ;;
      *)        model="${ANTHROPIC_MODEL:-$id}" ;;
    esac ;;
esac

out="$model"
if [ "$fast" = "true" ]; then
  out="$out · fast"
elif [ -n "$effort" ]; then
  out="$out · $effort"
fi
printf '%s' "$out"