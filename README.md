# AI Code Review

AI-powered code review GitHub Action using the Claude API.

Automatically reviews pull request diffs and posts inline review comments on the exact lines where issues are found.

## Features

- **Inline review comments** — findings appear directly on the affected lines, not as a wall of text
- **Severity-based decisions** — critical issues trigger `REQUEST_CHANGES`, blocking the PR merge
- **Full file context** — reads changed files so Claude understands the broader codebase, not just the diff
- **Smart file filtering** — automatically excludes lock files, minified assets, images, and fonts
- **Duplicate handling** — updates existing review on each push instead of spamming new comments
- **Graceful fallback** — if inline comments fail (e.g., line mismatch), falls back to a formatted PR comment

## Usage

```yaml
name: AI Code Review

on:
  pull_request:
    types: [opened, synchronize]

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write

    steps:
      - uses: AttilaSzendi/ai-code-review@main
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

### Required permissions

The job **must** have both of these permissions:

| Permission | Why |
|---|---|
| `contents: read` | Needed by `gh pr diff` and `actions/checkout` to access the repository |
| `pull-requests: write` | Needed to submit reviews and post comments on the PR |

### Required secrets

Add `ANTHROPIC_API_KEY` to your repository secrets (Settings > Secrets and variables > Actions).

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `anthropic-api-key` | yes | - | Anthropic API key |
| `model` | no | `claude-sonnet-4-6` | Claude model to use |
| `max-tokens` | no | `4096` | Max tokens for Claude response |
| `project-context` | no | - | Additional project-specific review instructions |
| `exclude-patterns` | no | - | Comma-separated glob patterns to exclude (e.g. `*.lock,*.min.js`) |

### Built-in exclusions

These file patterns are always excluded from review (no configuration needed):

`*.lock`, `composer.lock`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `*.min.js`, `*.min.css`, `*.map`, `*.snap`, `*.svg`, `*.png`, `*.jpg`, `*.jpeg`, `*.gif`, `*.ico`, `*.woff`, `*.woff2`, `*.ttf`, `*.eot`

## Review behavior

| Findings | Review event | Effect |
|---|---|---|
| Any `critical` finding | `REQUEST_CHANGES` | Blocks PR merge (if branch protection requires reviews) |
| Only `warning` / `suggestion` | `COMMENT` | Informational review, does not block |
| No findings | `APPROVE` | Approves the PR |

## Project-specific rules

Create a `.code-review.md` file in your repository root to add custom review instructions. These will be appended to the system prompt.

## How it works

1. Checks out the repository to access full file contents
2. Fetches the PR title, description, and diff via the GitHub CLI
3. Filters out excluded files (lock files, assets, etc.)
4. Reads the full content of changed files for context
5. Sends everything to the Claude API requesting structured JSON output
6. Parses findings and posts a GitHub PR Review with inline comments on affected lines
7. If inline review fails, falls back to a formatted issue comment
