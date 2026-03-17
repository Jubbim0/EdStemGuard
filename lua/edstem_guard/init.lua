local Config = require("edstem_guard.config")

local M = {}

M._state = {
  prompted_bucket = {},
  opts = nil,
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "EdStem Guard" })
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function executable(bin)
  return vim.fn.executable(bin) == 1
end

local function run_cmd(cmd, cwd)
  local result = vim.system(cmd, {
    cwd = cwd,
    text = true,
  }):wait()

  return {
    code = result.code,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

local function buf_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return vim.fs.dirname(name)
end

local function git_root(start_dir)
  if not start_dir then
    return nil
  end

  local result = run_cmd({ "git", "rev-parse", "--show-toplevel" }, start_dir)
  if result.code ~= 0 then
    return nil
  end

  return trim(result.stdout)
end

local function repo_name(root)
  return vim.fs.basename(root)
end

local function is_edstem_repo(root)
  local result = run_cmd({ "git", "remote", "get-url", "origin" }, root)
  if result.code ~= 0 then
    return false
  end

  local url = trim(result.stdout)
  for _, pattern in ipairs(M._state.opts.remote_patterns) do
    if url:match(pattern) then
      return true
    end
  end

  return false
end

local function upstream_ref(root)
  local result = run_cmd({ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, root)
  if result.code ~= 0 then
    return nil
  end
  return trim(result.stdout)
end

local function changed_lines_since_upstream(root)
  local upstream = upstream_ref(root)
  local cmd

  if upstream then
    cmd = { "git", "diff", "--numstat", upstream }
  else
    cmd = { "git", "diff", "--numstat", "HEAD" }
  end

  local result = run_cmd(cmd, root)
  if result.code ~= 0 then
    return 0
  end

  local total = 0
  for line in result.stdout:gmatch("[^\r\n]+") do
    local added, removed = line:match("^(%d+)%s+(%d+)%s+")
    if added and removed then
      total = total + tonumber(added) + tonumber(removed)
    end
  end

  return total
end

local function get_compile_cmd(root, bufnr)
  local opts = M._state.opts

  if opts.repo_commands[root] then
    return opts.repo_commands[root]
  end

  local name = repo_name(root)
  if opts.repo_commands[name] then
    return opts.repo_commands[name]
  end

  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local file = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))

  if file ~= "" and file:match("%.cpp$") then
    return {
      "g++",
      file,
      "-fsyntax-only",
      "-std=c++20",
      "-Wall",
      "-Wextra",
    }
  end

  return nil
end

local function set_quickfix_from_text(text, title)
  local lines = vim.split(text or "", "\n", { plain = true, trimempty = true })
  if #lines == 0 then
    lines = { "Command failed, but no output was captured." }
  end

  vim.fn.setqflist({}, " ", {
    title = title or "EdStem Guard",
    lines = lines,
    efm = vim.o.errorformat,
  })

  vim.cmd("copen")
end

local function compile_repo(root, bufnr)
  local cmd = get_compile_cmd(root, bufnr)
  if not cmd then
    notify(
      "No compile command configured for repo: " .. repo_name(root) .. ", and current file is not a .cpp buffer.",
      vim.log.levels.WARN
    )
    return false
  end

  if cmd[1] == "g++" and not executable("g++") then
    notify("g++ was not found in PATH", vim.log.levels.ERROR)
    return false
  end

  notify("Running compile check: " .. table.concat(cmd, " "))
  local result = run_cmd(cmd, root)

  if result.code == 0 then
    notify("Compile check passed")
    return true
  end

  set_quickfix_from_text(result.stdout .. "\n" .. result.stderr, "EdStem compile errors")
  notify("Compile failed. Fix errors and save again.", vim.log.levels.ERROR)
  return false
end

local function has_any_changes(root)
  local result = run_cmd({ "git", "status", "--porcelain" }, root)
  if result.code ~= 0 then
    return false
  end
  return trim(result.stdout) ~= ""
end

local function commit_message(root)
  local value = M._state.opts.commit_message
  if type(value) == "function" then
    return value({
      root = root,
      repo = repo_name(root),
      changed_lines = changed_lines_since_upstream(root),
    })
  end
  return value
end

local function commit_and_push(root)
  if not has_any_changes(root) then
    notify("Nothing to commit; pushing anyway")
  else
    local add_result = run_cmd({ "git", "add", "-A" }, root)
    if add_result.code ~= 0 then
      set_quickfix_from_text(add_result.stdout .. "\n" .. add_result.stderr, "git add failed")
      notify("git add failed", vim.log.levels.ERROR)
      return false
    end

    local msg = commit_message(root)
    local commit_result = run_cmd({ "git", "commit", "-m", msg }, root)
    local combined = (commit_result.stdout or "") .. "\n" .. (commit_result.stderr or "")

    if commit_result.code ~= 0 and not combined:match("nothing to commit") then
      set_quickfix_from_text(combined, "git commit failed")
      notify("git commit failed", vim.log.levels.ERROR)
      return false
    end
  end

  local push_result = run_cmd({ "git", "push" }, root)
  if push_result.code ~= 0 then
    set_quickfix_from_text(push_result.stdout .. "\n" .. push_result.stderr, "git push failed")
    notify("git push failed", vim.log.levels.ERROR)
    return false
  end

  local changed = changed_lines_since_upstream(root)
  M._state.prompted_bucket[root] = math.floor(changed / M._state.opts.line_threshold)

  notify("Compile passed; changes committed and pushed to Ed")
  return true
end

function M.check_current_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= "" then
    return
  end

  local dir = buf_dir(bufnr)
  local root = git_root(dir)
  if not root or not is_edstem_repo(root) then
    return
  end

  local threshold = M._state.opts.line_threshold
  local changed = changed_lines_since_upstream(root)
  local bucket = math.floor(changed / threshold)

  if bucket <= 0 then
    M._state.prompted_bucket[root] = 0
    return
  end

  local last_bucket = M._state.prompted_bucket[root] or 0
  if bucket <= last_bucket then
    return
  end

  local choice = vim.fn.confirm(
    ("EdStem repo: about %d changed lines since last pushed state.\nRun compile check now?"):format(changed),
    "&Yes\n&Later",
    1
  )

  if choice ~= 1 then
    notify("Reminder deferred")
    return
  end

  local ok = compile_repo(root, bufnr)
  if ok then
    commit_and_push(root)
  end
  -- On failure, leave prompted_bucket unchanged so the next save prompts again.
end

function M.force_check()
  local bufnr = vim.api.nvim_get_current_buf()
  local dir = buf_dir(bufnr)
  local root = git_root(dir)

  if not root or not is_edstem_repo(root) then
    notify("Current buffer is not inside an EdStem Git repo", vim.log.levels.WARN)
    return
  end

  if compile_repo(root, bufnr) then
    commit_and_push(root)
  end
end

function M.info()
  local bufnr = vim.api.nvim_get_current_buf()
  local dir = buf_dir(bufnr)
  local root = git_root(dir)

  if not root then
    notify("Current buffer is not inside a Git repo", vim.log.levels.WARN)
    return
  end

  local is_ed = is_edstem_repo(root)
  local changed = changed_lines_since_upstream(root)
  local threshold = M._state.opts.line_threshold
  local bucket = math.floor(changed / threshold)
  local last_bucket = M._state.prompted_bucket[root] or 0

  local lines = {
    "EdStem Guard info",
    "root: " .. root,
    "repo: " .. repo_name(root),
    "edstem remote: " .. tostring(is_ed),
    "changed lines: " .. tostring(changed),
    "current bucket: " .. tostring(bucket),
    "last handled bucket: " .. tostring(last_bucket),
  }

  notify(table.concat(lines, "\n"))
end

function M.setup(user_opts)
  if not executable("git") then
    notify("git was not found in PATH; edstem_guard will be inactive", vim.log.levels.ERROR)
    return
  end

  M._state.opts = Config.merge(user_opts)

  local group = vim.api.nvim_create_augroup("EdStemGuard", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      if vim.api.nvim_buf_get_name(args.buf) == "" then
        return
      end
      require("edstem_guard").check_current_buffer()
    end,
    desc = "Prompt for compile/push in EdStem repos every N changed lines",
  })

  vim.api.nvim_create_user_command("EdStemGuardCheck", function()
    require("edstem_guard").force_check()
  end, {
    desc = "Force compile, commit, and push for current EdStem repo",
  })

  vim.api.nvim_create_user_command("EdStemGuardInfo", function()
    require("edstem_guard").info()
  end, {
    desc = "Show EdStem Guard status for the current repo",
  })
end

return M
