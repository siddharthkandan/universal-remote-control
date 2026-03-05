#!/usr/bin/env bash
# lib-cli.sh — CLI detection and field mapping for Claude/Codex/Gemini
# Usage: source this file, then call detect_cli or get_cli_field

detect_cli() {
  # $1 = hook payload (JSON string) or empty
  local payload="${1:-}"
  if echo "$payload" | jq -e '.type == "agent-turn-complete"' >/dev/null 2>&1; then
    echo "codex"
  elif echo "$payload" | jq -e 'has("prompt_response")' >/dev/null 2>&1; then
    echo "gemini"
  elif echo "$payload" | jq -e 'has("last_assistant_message")' >/dev/null 2>&1; then
    echo "claude"
  else
    echo "unknown"
  fi
}

get_cli_field() {
  # $1 = cli name, $2 = field name
  local cli="$1" field="$2"
  case "$cli" in
    claude)
      case "$field" in
        response_field)  echo "last_assistant_message" ;;
        payload_source)  echo "stdin" ;;
        hook_output)     echo "" ;;
        turn_id_field)   echo "session_turn" ;;
      esac ;;
    codex)
      case "$field" in
        response_field)  echo "last-assistant-message" ;;
        payload_source)  echo "argv1" ;;
        hook_output)     echo "" ;;
        turn_id_field)   echo "turn-id" ;;
      esac ;;
    gemini)
      case "$field" in
        response_field)  echo "prompt_response" ;;
        payload_source)  echo "stdin" ;;
        hook_output)     echo '{"continue":true}' ;;
        turn_id_field)   echo "session_turn" ;;
      esac ;;
  esac
}
