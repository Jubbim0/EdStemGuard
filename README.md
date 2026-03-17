# nvim-edstem-guard

A small Neovim plugin that helps you stay compliant with EdStem assessment workflows by prompting you to compile, commit, and push after every configurable chunk of local changes.

It is designed for workflows where you work locally in a Git clone of an EdStem challenge repo and want a guardrail before you drift too far past the "push frequently" rule.

## Features

- Detects Git repos whose `origin` remote matches EdStem challenge remotes
- Watches file saves with a `BufWritePost` autocmd
- Prompts every _N_ changed lines since upstream
- Runs a compile check before commit and push
- On success: stages, commits, and pushes automatically
- On failure: opens quickfix and prompts again on the next save
- Supports repo-specific compile commands for non-trivial projects
- Includes a simple single-file C++ fallback for `.cpp` buffers

## Requirements

- Neovim 0.10+
- `git` in `PATH`
- `g++` in `PATH` if you want to use the default single-file C++ fallback

## Installation

### lazy.nvim / LazyVim

```lua
{
  "YOUR_GITHUB_USERNAME/nvim-edstem-guard",
  main = "edstem_guard",
  opts = {
    line_threshold = 20,
    repo_commands = {
      ["singly"] = { "make" },
      ["assignment1"] = { "make", "compile" },
    },
  },
}
```

`main = "edstem_guard"` is included explicitly so module loading is unambiguous.

## Default compile behavior

If no repo-specific command is configured and the current buffer is a `.cpp` file, the plugin falls back to:

```bash
g++ /absolute/path/to/file.cpp -fsyntax-only -std=c++20 -Wall -Wextra
```

This fallback is only meant for simple single-file C++ tasks. Multi-file projects, Makefiles, CMake projects, custom include paths, and non-C++ projects should use `repo_commands`.

## Configuration

```lua
require("edstem_guard").setup({
  line_threshold = 20,
  remote_patterns = {
    "^git%.edstem%.org:challenge/.+/.+$",
    "^ssh://git%.edstem%.org/challenge/.+/.+$",
  },
  repo_commands = {
    ["singly"] = { "make" },
    ["forward_list"] = { "make" },
    ["assignment1"] = { "make", "compile" },
    ["/full/path/to/special/repo"] = { "./scripts/check-build.sh" },
  },
  commit_message = function(ctx)
    return ("checkpoint: %s (%s changed lines)"):format(
      os.date("%Y-%m-%d %H:%M:%S"),
      ctx.changed_lines
    )
  end,
})
```

### Options

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `line_threshold` | `number` | `20` | Prompt after each threshold bucket of changed lines |
| `remote_patterns` | `string[]` | EdStem SSH patterns | Repo is active only if `origin` matches one of these |
| `repo_commands` | `table` | `{}` | Map repo basename or full repo root path to command arrays |
| `commit_message` | `string \| function(ctx)` | timestamped message | Function receives `{ root, repo, changed_lines }` |

## Commands

- `:EdStemGuardCheck` — force compile, commit, and push for the current EdStem repo
- `:EdStemGuardInfo` — show current repo status as seen by the plugin

## How it works

1. Save a file.
2. If the file is inside a Git repo whose `origin` looks like an EdStem challenge remote, the plugin checks the current diff against upstream.
3. Once you cross the next `line_threshold` bucket, it prompts you.
4. If you confirm, it runs the compile command.
5. If the compile succeeds, it stages, commits, and pushes.
6. If the compile fails, quickfix opens and the next save prompts again.

## Notes and caveats

- The fallback compile command only checks syntax for a single `.cpp` file.
- For any non-trivial project, set a repo-specific command.
- This plugin is a workflow guardrail, not a policy guarantee. You are still responsible for following your course rules correctly.
- `Later` defers only the current save. If you save again while still over the threshold, you will be prompted again.

## Publishing checklist

Before tagging `v1.0.0`, verify these manually:

- [ ] single-file `.cpp` fallback works
- [ ] repo-specific command works
- [ ] compile failure opens quickfix
- [ ] successful compile commits and pushes
- [ ] non-EdStem repos stay silent
- [ ] no duplicate prompts after a successful push

## License

MIT
