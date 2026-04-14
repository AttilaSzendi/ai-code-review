#!/usr/bin/env bash
set -euo pipefail

MAX_DIFF_CHARS=100000
MAX_FILE_CHARS=10000
COMMENT_TAG="<!-- ai-code-review -->"

# Built-in file patterns to always exclude from review
DEFAULT_EXCLUDE="*.lock composer.lock package-lock.json yarn.lock pnpm-lock.yaml *.min.js *.min.css *.map *.snap *.svg *.png *.jpg *.jpeg *.gif *.ico *.woff *.woff2 *.ttf *.eot"

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
DIFF_ERR=$(mktemp)
DIFF=$(gh pr diff "$PR_NUMBER" --repo "$REPO" 2>"$DIFF_ERR") || true

if [[ -z "$DIFF" ]]; then
  if [[ -s "$DIFF_ERR" ]]; then
    echo "::warning::gh pr diff failed: $(cat "$DIFF_ERR")"
  fi
  rm -f "$DIFF_ERR"
  echo "Empty diff, skipping review."
  exit 0
fi
rm -f "$DIFF_ERR"

# ── Filter excluded files from diff ──────────────────────
ALL_EXCLUDE="$DEFAULT_EXCLUDE"
if [[ -n "${EXCLUDE_PATTERNS:-}" ]]; then
  IFS=',' read -ra CUSTOM_PATTERNS <<< "$EXCLUDE_PATTERNS"
  for pattern in "${CUSTOM_PATTERNS[@]}"; do
    ALL_EXCLUDE="${ALL_EXCLUDE} $(echo "$pattern" | xargs)"
  done
fi

AWK_PATTERN=""
for pattern in $ALL_EXCLUDE; do
  regex=$(echo "$pattern" | sed 's/\./[.]/g; s/\*/.*/g')
  if [[ -n "$AWK_PATTERN" ]]; then
    AWK_PATTERN="${AWK_PATTERN}|${regex}"
  else
    AWK_PATTERN="${regex}"
  fi
done

if [[ -n "$AWK_PATTERN" ]]; then
  FILTERED_DIFF=$(echo "$DIFF" | awk -v pat="($AWK_PATTERN)" '
    /^diff --git/ {
      skip = 0
      fname = $NF
      sub(/^b\//, "", fname)
      if (fname ~ pat) skip = 1
    }
    !skip { print }
  ')
  if [[ -z "$FILTERED_DIFF" ]]; then
    echo "All files excluded by filter, skipping review."
    exit 0
  fi
  if [[ ${#FILTERED_DIFF} -lt ${#DIFF} ]]; then
    echo "Filtered out excluded file patterns from diff."
  fi
  DIFF="$FILTERED_DIFF"
fi

TRUNCATED=false
if [[ ${#DIFF} -gt $MAX_DIFF_CHARS ]]; then
  DIFF="${DIFF:0:$MAX_DIFF_CHARS}"
  TRUNCATED=true
  echo "::warning::Diff truncated to ${MAX_DIFF_CHARS} chars."
fi

# ── Collect full file contents for context ────────────────
CHANGED_FILES=$(echo "$DIFF" | grep "^diff --git" | sed 's/diff --git a\/.* b\///')
FILE_CONTEXT=""
FILES_INCLUDED=0
for file in $CHANGED_FILES; do
  if [[ -f "$file" ]]; then
    FILE_SIZE=$(wc -c < "$file")
    if [[ "$FILE_SIZE" -lt "$MAX_FILE_CHARS" ]]; then
      FILE_CONTEXT="${FILE_CONTEXT}
--- ${file} (full file) ---
$(cat "$file")
--- end ${file} ---
"
      FILES_INCLUDED=$((FILES_INCLUDED + 1))
    else
      echo "Skipping full content of ${file} (${FILE_SIZE} bytes > ${MAX_FILE_CHARS} limit)"
    fi
  fi
done
if [[ "$FILES_INCLUDED" -gt 0 ]]; then
  echo "Included full content of ${FILES_INCLUDED} changed file(s) for context."
fi

# ── Project rules (optional file in repo root) ────────────
RULES=""
if [[ -f ".code-review.md" ]]; then
  RULES=$(cat .code-review.md)
  echo "Loaded project rules from .code-review.md"
fi

# ── System prompt ─────────────────────────────────────────
SYSTEM="You are a senior code reviewer. Review the pull request diff below.
You also have access to the full content of changed files for additional context.

Focus on:
- Bugs and logic errors
- Security vulnerabilities (OWASP top 10)
- Performance issues
- Code quality and readability
- Best practices for the language/framework used

Rules:
- Be concise and actionable — no fluff
- Only flag important issues, skip nitpicking (formatting, naming style)
- Line numbers MUST refer to lines visible in the diff (added or modified lines in the new version)
- Write in English

You MUST return your review as a JSON object with this exact structure. Do NOT wrap it in markdown code blocks.

{
  \"summary\": \"1-2 sentence overall assessment of the changes\",
  \"findings\": [
    {
      \"path\": \"relative/path/to/file\",
      \"line\": 42,
      \"severity\": \"critical\",
      \"body\": \"Markdown description of the issue and suggested fix\"
    }
  ]
}

Severity values: \"critical\" for bugs and security issues, \"warning\" for potential problems, \"suggestion\" for improvements.
If the code looks good, return an empty findings array with a positive summary.
IMPORTANT: Each finding's \"line\" must be a line number from the NEW version of the file that appears in the diff. The \"path\" must match the file path shown in the diff."

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

Warning: The diff was truncated. Review what is available."
fi

USER_MSG="${USER_MSG}

\`\`\`diff
${DIFF}
\`\`\`"

if [[ -n "$FILE_CONTEXT" ]]; then
  USER_MSG="${USER_MSG}

Full file contents for context:
${FILE_CONTEXT}"
fi

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

REVIEW_TEXT=$(echo "$BODY" | jq -r '.content[0].text')

if [[ -z "$REVIEW_TEXT" || "$REVIEW_TEXT" == "null" ]]; then
  echo "::error::Empty response from Claude."
  exit 1
fi

# ── Token usage (for cost tracking) ───────────────────────
INPUT_TOKENS=$(echo "$BODY" | jq -r '.usage.input_tokens // "?"')
OUTPUT_TOKENS=$(echo "$BODY" | jq -r '.usage.output_tokens // "?"')
echo "Tokens used: ${INPUT_TOKENS} input, ${OUTPUT_TOKENS} output"

# ── Parse structured response ─────────────────────────────
# Strip markdown code blocks if Claude wrapped the JSON
CLEAN_JSON=$(echo "$REVIEW_TEXT" | sed '/^```json$/d; /^```$/d')
REVIEW_JSON=$(echo "$CLEAN_JSON" | jq '.' 2>/dev/null) || true

if [[ -z "$REVIEW_JSON" || "$REVIEW_JSON" == "null" ]]; then
  echo "::warning::Could not parse JSON from Claude response, falling back to plain comment."
  post_fallback_comment "$REVIEW_TEXT"
  exit 0
fi

# ── Extract review data ──────────────────────────────────
SUMMARY=$(echo "$REVIEW_JSON" | jq -r '.summary // "No summary provided."')
FINDINGS_COUNT=$(echo "$REVIEW_JSON" | jq '.findings | length')
CRITICAL_COUNT=$(echo "$REVIEW_JSON" | jq '[.findings[] | select(.severity == "critical")] | length')
WARNING_COUNT=$(echo "$REVIEW_JSON" | jq '[.findings[] | select(.severity == "warning")] | length')
SUGGESTION_COUNT=$(echo "$REVIEW_JSON" | jq '[.findings[] | select(.severity == "suggestion")] | length')

echo "Findings: ${CRITICAL_COUNT} critical, ${WARNING_COUNT} warning, ${SUGGESTION_COUNT} suggestion"

# ── Determine review event ────────────────────────────────
if [[ "$CRITICAL_COUNT" -gt 0 ]]; then
  REVIEW_EVENT="REQUEST_CHANGES"
elif [[ "$FINDINGS_COUNT" -eq 0 ]]; then
  REVIEW_EVENT="APPROVE"
else
  REVIEW_EVENT="COMMENT"
fi
echo "Review decision: ${REVIEW_EVENT}"

# ── Build review body (summary) ──────────────────────────
REVIEW_BODY="${SUMMARY}"
if [[ "$FINDINGS_COUNT" -gt 0 ]]; then
  BADGES=""
  [[ "$CRITICAL_COUNT" -gt 0 ]] && BADGES="${BADGES}🔴 ${CRITICAL_COUNT} critical  "
  [[ "$WARNING_COUNT" -gt 0 ]] && BADGES="${BADGES}🟡 ${WARNING_COUNT} warning  "
  [[ "$SUGGESTION_COUNT" -gt 0 ]] && BADGES="${BADGES}🔵 ${SUGGESTION_COUNT} suggestion"
  REVIEW_BODY="${REVIEW_BODY}

${BADGES}"
fi
REVIEW_BODY="${REVIEW_BODY}

---
<sub>Reviewed by Claude (${MODEL}) · ${INPUT_TOKENS} input / ${OUTPUT_TOKENS} output tokens</sub>"

# ── Build inline comments ────────────────────────────────
INLINE_COMMENTS=$(echo "$REVIEW_JSON" | jq '[.findings[] | {
  path: .path,
  line: .line,
  side: "RIGHT",
  body: ((if .severity == "critical" then "🔴 **Critical** — "
         elif .severity == "warning" then "🟡 **Warning** — "
         else "🔵 **Suggestion** — " end) + .body)
}]')

# ── Try posting as PR review with inline comments ─────────
REVIEW_PAYLOAD=$(jq -n \
  --arg event "$REVIEW_EVENT" \
  --arg body "$REVIEW_BODY" \
  --argjson comments "$INLINE_COMMENTS" \
  '{event: $event, body: $body, comments: $comments}')

REVIEW_RESULT=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
  --method POST \
  --input - <<< "$REVIEW_PAYLOAD" 2>&1) || true

if echo "$REVIEW_RESULT" | jq -e '.id' > /dev/null 2>&1; then
  echo "✅ Review posted on PR #${PR_NUMBER} (${REVIEW_EVENT}, ${FINDINGS_COUNT} inline comments)"
  # Clean up old fallback comment if exists
  OLD_COMMENT_ID=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    --jq ".[] | select(.body | startswith(\"${COMMENT_TAG}\")) | .id" 2>/dev/null | head -1)
  if [[ -n "$OLD_COMMENT_ID" ]]; then
    gh api "repos/${REPO}/issues/comments/${OLD_COMMENT_ID}" --method DELETE 2>/dev/null || true
    echo "Cleaned up old fallback comment."
  fi
  exit 0
fi

# ── Fallback: post as regular comment with all findings ───
REVIEW_ERR=$(echo "$REVIEW_RESULT" | jq -r '.message // "unknown error"' 2>/dev/null || echo "unknown error")
echo "::warning::Inline review failed (${REVIEW_ERR}), falling back to comment."

FALLBACK_BODY="${COMMENT_TAG}
## 🤖 AI Code Review

${SUMMARY}
"

if [[ "$FINDINGS_COUNT" -gt 0 ]]; then
  FALLBACK_FINDINGS=$(echo "$REVIEW_JSON" | jq -r '.findings[] |
    (if .severity == "critical" then "### 🔴 Critical"
     elif .severity == "warning" then "### 🟡 Warning"
     else "### 🔵 Suggestion" end) +
    " — `" + .path + ":" + (.line | tostring) + "`\n\n" + .body + "\n"')
  FALLBACK_BODY="${FALLBACK_BODY}
${FALLBACK_FINDINGS}"
fi

FALLBACK_BODY="${FALLBACK_BODY}
---
<sub>Reviewed by Claude (${MODEL}) · ${INPUT_TOKENS} input / ${OUTPUT_TOKENS} output tokens</sub>"

COMMENT_FILE=$(mktemp)
echo "$FALLBACK_BODY" > "$COMMENT_FILE"

EXISTING_COMMENT_ID=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  --jq ".[] | select(.body | startswith(\"${COMMENT_TAG}\")) | .id" 2>/dev/null | head -1)

if [[ -n "$EXISTING_COMMENT_ID" ]]; then
  gh api "repos/${REPO}/issues/comments/${EXISTING_COMMENT_ID}" \
    --method PATCH \
    --field body=@"$COMMENT_FILE"
  echo "✅ Updated fallback comment on PR #${PR_NUMBER}"
else
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body-file "$COMMENT_FILE"
  echo "✅ Fallback comment posted on PR #${PR_NUMBER}"
fi
rm -f "$COMMENT_FILE"
