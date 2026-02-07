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
local jobs = {}
local buffer_detached = {}
local ns = vim.api.nvim_create_namespace("aitodo_processing")

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

local function generate_job_id()
  return string.format("%d_%s", os.time(), string.match(string.gsub(tostring(math.random()), "0.", ""), "^%d+"))
end

local function get_temp_dir(bufnr, job_id)
  return string.format("%s/%d/%s", config.log_dir, bufnr, job_id)
end

local function save_base_file(bufnr, temp_dir)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")
  local base_path = temp_dir .. "/base.txt"
  vim.fn.mkdir(temp_dir, "p")
  local f = io.open(base_path, "w")
  if f then
    f:write(content)
    f:close()
  end
  return content, base_path
end

local function read_file_content(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function merge_files(user_edits_path, base_path, ai_file_path)
  local cmd = string.format("git merge-file -p --union '%s' '%s' '%s'", user_edits_path, base_path, ai_file_path)
  local result = vim.fn.system(cmd)
  local success = (vim.v.shell_error == 0)
  return success, result
end

local function cleanup_job(job_id)
  local job = jobs[job_id]
  if not job then
    return
  end

  local bufnr = job.bufnr
  if bufnr and buffer_detached[bufnr] == job_id then
    if vim.fn.bufexists(bufnr) == 1 then
      vim.bo[bufnr].buftype = ""
    end
    buffer_detached[bufnr] = nil
  end

  if job.temp_dir then
    vim.fn.delete(job.temp_dir, "rf")
  end

  jobs[job_id] = nil
end

local function restore_buffer(bufnr)
  if vim.fn.bufexists(bufnr) == 1 then
    vim.bo[bufnr].buftype = ""
  end
end

local function process_file(prompt)
  local filepath = vim.api.nvim_buf_get_name(0)
  if filepath == "" then
    vim.notify("No file", vim.log.levels.WARN)
    return
  end

  vim.cmd("write")

  local bufnr = vim.api.nvim_get_current_buf()
  local job_id = generate_job_id()
  local temp_dir = get_temp_dir(bufnr, job_id)

  local base_content, base_path = save_base_file(bufnr, temp_dir)

  buffer_jobs[bufnr] = job_id
  jobs[job_id] = {
    bufnr = bufnr,
    base_content = base_content,
    base_path = base_path,
    temp_dir = temp_dir,
  }

  vim.bo[bufnr].buftype = "nofile"
  buffer_detached[bufnr] = job_id

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

  local output_buf = vim.api.nvim_create_buf(false, true)
  local log_path = nil
  local full_cmd = script_cmd_str
  if config.log_enabled then
    log_path = get_log_path(bufnr)
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
      local job = jobs[job_id]
      local job_bufnr = job and job.bufnr

      current_job_id = nil
      if job_bufnr then
        buffer_jobs[job_bufnr] = nil
      end

      if exit_code == 0 then
        vim.schedule(function()
          if not job then
            cleanup_job(job_id)
            return
          end

          if vim.fn.bufexists(job_bufnr) == 0 then
            cleanup_job(job_id)
            return
          end

          vim.api.nvim_buf_clear_namespace(job_bufnr, ns, 0, -1)

          local current_lines = vim.api.nvim_buf_get_lines(job_bufnr, 0, -1, false)
          local current_content = table.concat(current_lines, "\n")

          if current_content == job.base_content then
            vim.api.nvim_buf_set_lines(job_bufnr, 0, -1, false, vim.fn.readfile(filepath))
            vim.bo[job_bufnr].modified = false
            vim.bo[job_bufnr].buftype = ""
            vim.notify("Done! (AI changes applied)", vim.log.levels.INFO)
          else
            local user_edits_path = job.temp_dir .. "/user_edits.txt"
            local user_f = io.open(user_edits_path, "w")
            if user_f then
              user_f:write(current_content)
              user_f:close()
            end

            local success, merged_content = merge_files(user_edits_path, job.base_path, filepath)

            if success then
              local merged_lines = vim.fn.split(merged_content, "\n", true)
              vim.api.nvim_buf_set_lines(job_bufnr, 0, -1, false, merged_lines)
              restore_buffer(job_bufnr)
              vim.fn.writefile(merged_lines, filepath)
              vim.api.nvim_buf_call(job_bufnr, function()
                vim.cmd("silent! edit!")
              end)
              vim.notify("Done! (Your edits merged with AI changes)", vim.log.levels.INFO)
            else
              restore_buffer(job_bufnr)
              vim.notify("Merge failed. Keeping your edits.", vim.log.levels.ERROR)
            end
          end

          cleanup_job(job_id)
          vim.cmd("redraw!")
        end)
      elseif not job_stopped_intentionally then
        vim.schedule(function()
          if not job then
            cleanup_job(job_id)
            return
          end

          if job_bufnr and vim.fn.bufexists(job_bufnr) == 1 then
            vim.api.nvim_buf_clear_namespace(job_bufnr, ns, 0, -1)
          end

          restore_buffer(job_bufnr)
          cleanup_job(job_id)

          vim.cmd("botright split")
          vim.api.nvim_win_set_buf(0, output_buf)
        end)
      else
        vim.schedule(function()
          restore_buffer(job_bufnr)
          cleanup_job(job_id)
        end)
      end

      job_stopped_intentionally = false
    end,
  })

  vim.schedule(function()
    local ok, pid = pcall(vim.fn.jobpid, current_job_id)
    if ok and pid then
      jobs[job_id].pid = pid
      print("Processing... please wait (PID: " .. pid .. ")")

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for i, line in ipairs(lines) do
        if line:match("AITODO:") then
          vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
            virt_text = {{"↻ Processing...", "Comment"}},
            virt_text_pos = "eol",
          })
        end
      end
    end
  end)
end

local function stop_job()
  local bufnr = vim.api.nvim_get_current_buf()
  local job_id = buffer_jobs[bufnr]
  local job = jobs[job_id]

  if job then
    local pid = job.pid
    print("Stopping job, PID: " .. tostring(pid))

    job_stopped_intentionally = true
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local script = vim.env.AITODO_AICODER_SCRIPT or (vim.env.HOME .. "/bin/aicoder-nvim")
    local result = vim.fn.system(script .. " --stop " .. pid)
    print("Stop result: " .. result)
    vim.notify("Job stopped (PID: " .. pid .. ")", vim.log.levels.INFO)
  else
    vim.notify("No active job for this buffer", vim.log.levels.WARN)
  end
end

local function setup_keymaps()
  vim.api.nvim_create_autocmd("BufDelete", {
    callback = function(ev)
      local bufnr = ev.buf
      local job_id = buffer_jobs[bufnr]
      if job_id then
        local job = jobs[job_id]
        if job and job.pid then
          local script = vim.env.AITODO_AICODER_SCRIPT or (vim.env.HOME .. "/bin/aicoder-nvim")
          vim.fn.system(script .. " --stop " .. job.pid)
        end
        cleanup_job(job_id)
      end
    end,
  })

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

function M.get_active_job_count()
  local count = 0
  for _ in pairs(buffer_jobs) do
    count = count + 1
  end
  return count
end

setup_keymaps()

return M
