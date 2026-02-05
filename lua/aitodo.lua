local M = {}

local config = {
  log_enabled = true,
  log_dir = "/tmp/aitodo",
  keymaps = {
    insert_todo = "<C-a>",
    process = "<leader>aa",
    process_prompt = "<leader>ap",
    open_log = "<leader>al",
    stop = "<leader>as",
  },
}

local current_job_id = nil
local job_stopped_intentionally = false
local buffer_jobs = {}

local comment_prefixes = {
  python = "# AITODO: ",
  sh = "# AITODO: ",
  ruby = "# AITODO: ",
  lua = "-- AITODO: ",
  javascript = "// AITODO: ",
  typescript = "// AITODO: ",
  java = "// AITODO: ",
  c = "// AITODO: ",
  cpp = "// AITODO: ",
  rust = "// AITODO: ",
  go = "// AITODO: ",
  swift = "// AITODO: ",
  php = "// AITODO: ",
}

local function get_comment_prefix(ft)
  return comment_prefixes[ft] or "AITODO: "
end

local function get_log_path(bufnr)
  local pid = vim.fn.getpid()
  return string.format("%s/aitodo-%d-%d.log", config.log_dir, pid, bufnr)
end

local function get_visual_selection()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]

  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  return table.concat(lines, "\n")
end

local function process_file(prompt)
  local filepath = vim.api.nvim_buf_get_name(0)
  if filepath == "" then
    vim.notify("No file", vim.log.levels.WARN)
    return
  end

  vim.cmd("write")

  local bufnr = vim.api.nvim_get_current_buf()
  local output_buf = vim.api.nvim_create_buf(false, true)

  print("Processing... please wait...")
  vim.bo[bufnr].modifiable = false

  local script = vim.env.AITODO_AICODER_SCRIPT or (vim.env.HOME .. "/bin/aicoder-nvim")
  local script_args = { script, filepath }

  if prompt then
    table.insert(script_args, "--prompt")
    table.insert(script_args, prompt)
  end

  local script_cmd_str = table.concat(script_args, " ")

  local env = {
    AITODO_FILEPATH = filepath,
    AITODO_LINE = tostring(vim.api.nvim_win_get_cursor(0)[1]),
    AITODO_COLUMN = tostring(vim.api.nvim_win_get_cursor(0)[2]),
    AITODO_BUFFER_ID = tostring(bufnr),
    AITODO_FILETYPE = vim.bo.filetype,
    AITODO_NVIM_PID = tostring(vim.fn.getpid()),
    AITODO_CWD = vim.fn.getcwd(),
    AICODER_DISABLE_COLORS = "1",
  }

  if prompt then
    env.AITODO_PROMPT_ADDITIONAL = prompt
  end

  local visual_selection = get_visual_selection()
  if visual_selection then
    env.AITODO_VISUAL_SELECTION = visual_selection
  end

  local full_cmd = script_cmd_str
  if config.log_enabled then
    local log_path = get_log_path(bufnr)
    vim.fn.mkdir(config.log_dir, "p")
    full_cmd = string.format("%s > '%s' 2>&1", script_cmd_str, log_path)
  end

  current_job_id = vim.fn.jobstart(full_cmd, {
    env = env,
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, data)
      end
    end,
    on_exit = function(_, exit_code)
      current_job_id = nil
      buffer_jobs[bufnr] = nil
      vim.bo[bufnr].modifiable = true
      if exit_code == 0 then
        vim.schedule(function()
          vim.cmd("edit!")
          vim.cmd("redraw!")
          vim.notify("Done!", vim.log.levels.INFO)
        end)
      elseif not job_stopped_intentionally then
        vim.schedule(function()
          vim.cmd("botright split")
          vim.api.nvim_win_set_buf(0, output_buf)
        end)
      end
      job_stopped_intentionally = false
    end,
  })

  -- Get the actual process PID after job starts
  vim.schedule(function()
    local ok, pid = pcall(vim.fn.jobpid, current_job_id)
    if ok and pid then
      buffer_jobs[bufnr] = pid
      print("Processing... please wait (PID: " .. pid .. ")")
    end
  end)
end

local function stop_job()
  local bufnr = vim.api.nvim_get_current_buf()
  local job_pid = buffer_jobs[bufnr]

  print("Stopping job, PID: " .. tostring(job_pid))

  if job_pid then
    job_stopped_intentionally = true
    local script = vim.env.AITODO_AICODER_SCRIPT or (vim.env.HOME .. "/bin/aicoder-nvim")
    local result = vim.fn.system(script .. " --stop " .. job_pid)
    print("Stop result: " .. result)
    buffer_jobs[bufnr] = nil
    vim.bo[bufnr].modifiable = true
    vim.notify("Job stopped (PID: " .. job_pid .. ")", vim.log.levels.INFO)
  else
    vim.notify("No active job for this buffer", vim.log.levels.WARN)
  end
end

local function setup_keymaps()
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "*",
    callback = function()
      if config.keymaps.insert_todo then
        local prefix = get_comment_prefix(vim.bo.filetype)
        vim.keymap.set("i", config.keymaps.insert_todo, prefix, { buffer = true })
      end
    end,
  })

  if config.keymaps.process then
    vim.keymap.set("n", config.keymaps.process, function()
      process_file()
    end, { desc = "Process AITODOs" })
  end

  if config.keymaps.process_prompt then
    vim.keymap.set("n", config.keymaps.process_prompt, function()
      vim.ui.input({ prompt = "Prompt: " }, function(input)
        if input then
          process_file(input)
        end
      end)
    end, { desc = "Process AITODOs with prompt" })
  end

  if config.keymaps.open_log then
    vim.keymap.set("n", config.keymaps.open_log, function()
      if not config.log_enabled then
        vim.notify("Logging is disabled", vim.log.levels.WARN)
        return
      end

      local bufnr = vim.api.nvim_get_current_buf()
      local log_path = get_log_path(bufnr)

      if vim.fn.filereadable(log_path) == 0 then
        vim.notify("No log file found for this buffer", vim.log.levels.WARN)
        return
      end

      vim.cmd("edit " .. log_path)
    end, { desc = "Open AITODO log for current buffer" })
  end

  if config.keymaps.stop then
    vim.keymap.set("n", config.keymaps.stop, function()
      stop_job()
    end, { desc = "Stop AITODO job" })
  end
end

function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
  setup_keymaps()
end

function M.process(prompt)
  process_file(prompt)
end

function M.stop()
  stop_job()
end

M.get_comment_prefix = get_comment_prefix

function M.get_log_path(bufnr)
  return get_log_path(bufnr)
end

function M.get_visual_selection()
  return get_visual_selection()
end

setup_keymaps()

return M
