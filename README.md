# opencode-review

Advisory pull request review with [OpenCode](https://opencode.ai) on any OpenAI-compatible endpoint. A check comments on the PR only when it finds something, so a clean PR gets no comment and no email. Every review is in the job's step summary. A check never fails the PR.

- `security`: reports medium or higher only.
- `code`: correctness, error handling, broken callers and missing tests. No style comments.

Edits are denied, and bash is limited to `git diff`, `git log` and `git show`, without paths outside the repository, `--no-index`, `--output` or redirects. This stops the agent from changing the tree by mistake. It is not a sandbox: the shell environment holds the API key. The GitHub token only reaches the step that posts the comment, not the agent. Config, prompts and permissions come only from this action. Project OpenCode config in the reviewed repo (a root `opencode.json`, `.opencode/`) is ignored, which `test/config-lock.sh` checks.

Repo rules go in a `Security review` or `Code review` section of the repo's `AGENTS.md`, or `CLAUDE.md` when there is no `AGENTS.md`.

## Inputs

| Input | Required | Default | |
|---|---|---|---|
| `check` | yes | | `security` or `code` |
| `base-url` | yes | | OpenAI-compatible base URL |
| `model` | yes | | model id |
| `small-model` | no | `model` | model for small tasks |
| `api-key` | yes | | endpoint API key |
| `github-token` | no | `github.token` | posts the comment when there are findings |
| `dry-run` | no | `false` | `true`: never comments, result in the step summary and a `review-<check>-<sha>` artifact |
| `opencode-version` | no | pinned | OpenCode release |

The job must check out the commit with `fetch-depth: 2` and have `bash`, `curl`, `tar` and `git`.

## Example

```yaml
name: PR Review

on:
  pull_request:
    types: [opened, ready_for_review]

permissions:
  contents: read
  pull-requests: write

jobs:
  review:
    name: Review (${{ matrix.check }})
    if: ${{ !github.event.pull_request.draft }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        check: [security, code]
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 2
      - uses: johnuopini/opencode-review@<sha> # v1.1.0
        continue-on-error: true
        with:
          check: ${{ matrix.check }}
          base-url: https://llm.example.com/v1
          model: my-model
          api-key: ${{ secrets.LLM_API_KEY }}
```

To review again, mark the PR as draft and then ready.
