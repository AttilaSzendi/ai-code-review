#!/usr/bin/env bash
set -euo pipefail

MAX_DIFF_CHARS=100000

# ── Validate ──────────────────────────────────────────────
if [[ -z "${PR_NUMBER:-}" ]]; then
  echo "::error::No PR number. This action must run on pull_request events."
  exit 1
fi
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "::error::Missing ANTHROPIC_API_KEY."
  exit 1
fi

echo "Reviewing PR #${PR_NUMBER} with ${MODEL}..."

# ── PR metadata ───────────────────────────────────────────
PR_TITLE=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json title -q '.title')
PR_BODY=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json body -q '.body')

# ── Diff ──────────────────────────────────────────────────
DIFF=$(gh pr diff "$PR_NUMBER" --repo "$REPO" 2>/dev/null || true)

if [[ -z "$DIFF" ]]; then
  echo "Empty diff, skipping review."
  exit 0
fi

TRUNCATED=false
if [[ ${#DIFF} -gt $MAX_DIFF_CHARS ]]; then
  DIFF="${DIFF:0:$MAX_DIFF_CHARS}"
  TRUNCATED=true
  echo "::warning::Diff truncated to ${MAX_DIFF_CHARS} chars."
fi

# ── Project rules (optional file in repo root) ────────────
RULES=""
if [[ -f ".code-review.md" ]]; then
  RULES=$(cat .code-review.md)
  echo "Loaded project rules from .code-review.md"
fi

# ── System prompt ─────────────────────────────────────────
SYSTEM="You are a senior code reviewer. Review the pull request diff below.

Focus on:
- Bugs and logic errors
- Security vulnerabilities (OWASP top 10)
- Performance issues
- Code quality and readability
- Best practices for the language/framework used

Rules:
- Be concise and actionable — no fluff
- Only flag important issues, skip nitpicking (formatting, naming style)
- If the code looks good, say so in one sentence
- Group findings by severity: 🔴 Critical, 🟡 Warning, 🔵 Suggestion
- Reference specific file names and line numbers from the diff
- Write in English"

if [[ -n "$RULES" ]]; then
  SYSTEM="${SYSTEM}

Project-specific rules:
${RULES}"
fi

if [[ -n "${PROJECT_CONTEXT:-}" ]]; then
  SYSTEM="${SYSTEM}

Additional context:
${PROJECT_CONTEXT}"
fi

# ── User message ──────────────────────────────────────────
USER_MSG="PR: ${PR_TITLE}
Description: ${PR_BODY:-No description provided.}"

if [[ "$TRUNCATED" == "true" ]]; then
  USER_MSG="${USER_MSG}

⚠️ The diff was truncated. Review what is available."
fi

USER_MSG="${USER_MSG}

\`\`\`diff
${DIFF}
\`\`\`"

# ── Claude API call ───────────────────────────────────────
PAYLOAD=$(jq -n \
  --arg model "$MODEL" \
  --argjson max_tokens "${MAX_TOKENS}" \
  --arg system "$SYSTEM" \
  --arg user "$USER_MSG" \
  '{
    model: $model,
    max_tokens: $max_tokens,
    system: $system,
    messages: [{role: "user", content: $user}]
  }')

RESPONSE=$(curl -s -w "\n%{http_code}" \
  https://api.anthropic.com/v1/messages \
  -H "content-type: application/json" \
  -H "x-api-key: ${ANTHROPIC_API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "::error::Claude API HTTP ${HTTP_CODE}: $(echo "$BODY" | jq -r '.error.message // .')"
  exit 1
fi

REVIEW=$(echo "$BODY" | jq -r '.content[0].text')

if [[ -z "$REVIEW" || "$REVIEW" == "null" ]]; then
  echo "::error::Empty response from Claude."
  exit 1
fi

# ── Token usage (for cost tracking) ───────────────────────
INPUT_TOKENS=$(echo "$BODY" | jq -r '.usage.input_tokens // "?"')
OUTPUT_TOKENS=$(echo "$BODY" | jq -r '.usage.output_tokens // "?"')
echo "Tokens used: ${INPUT_TOKENS} input, ${OUTPUT_TOKENS} output"

# ── Post review comment ──────────────────────────────────
COMMENT_FILE=$(mktemp)
cat > "$COMMENT_FILE" <<EOF
## 🤖 AI Code Review

${REVIEW}

---
<sub>Reviewed by Claude (${MODEL}) · ${INPUT_TOKENS} input / ${OUTPUT_TOKENS} output tokens</sub>
EOF

gh pr comment "$PR_NUMBER" --repo "$REPO" --body-file "$COMMENT_FILE"
rm -f "$COMMENT_FILE"

echo "✅ Review posted on PR #${PR_NUMBER}"
