local M = {}

M.defaults = {
  line_threshold = 20,
  remote_patterns = {
    "^git%.edstem%.org:challenge/.+/.+$",
    "^ssh://git%.edstem%.org/challenge/.+/.+$",
  },
  repo_commands = {},
  commit_message = function(ctx)
    local changed = ctx and ctx.changed_lines or "?"
    return ("checkpoint: %s (%s changed lines)"):format(os.date("%Y-%m-%d %H:%M:%S"), changed)
  end,
}

local function validate(opts)
  vim.validate({
    line_threshold = { opts.line_threshold, "number" },
    remote_patterns = { opts.remote_patterns, "table" },
    repo_commands = { opts.repo_commands, "table" },
  })

  if opts.line_threshold < 1 then
    error("line_threshold must be at least 1")
  end

  if type(opts.commit_message) ~= "function" and type(opts.commit_message) ~= "string" then
    error("commit_message must be a string or function")
  end
end

function M.merge(user_opts)
  local opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})
  validate(opts)
  return opts
end

return M
