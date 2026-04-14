# AI Code Review

AI-powered code review GitHub Action using the Claude API.

Automatically reviews pull request diffs and posts a comment with findings grouped by severity.

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
| `contents: read` | Needed by `gh pr diff` to fetch the pull request diff |
| `pull-requests: write` | Needed to post the review comment on the PR |

### Required secrets

Add `ANTHROPIC_API_KEY` to your repository secrets (Settings → Secrets and variables → Actions).

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `anthropic-api-key` | yes | — | Anthropic API key |
| `model` | no | `claude-sonnet-4-6` | Claude model to use |
| `max-tokens` | no | `4096` | Max tokens for Claude response |
| `project-context` | no | — | Additional project-specific review instructions |

## Project-specific rules

Create a `.code-review.md` file in your repository root to add custom review instructions. These will be appended to the system prompt.

## How it works

1. Fetches the PR title, description, and diff via the GitHub CLI
2. Sends the diff to the Claude API with a code review prompt
3. Posts the review as a PR comment with findings grouped by severity:
   - 🔴 Critical — bugs, security issues
   - 🟡 Warning — potential problems
   - 🔵 Suggestion — improvements
