# aitodo.nvim

Minimalist Neovim plugin for AI-powered TODO processing.

For detailed help after installation, see `:help aitodo`.

If help doesn't appear after installation, regenerate tags: >
    :helptags ALL
<

## Setup

Install using your favorite plugin manager:

```vim
" vim-plug
Plug 'elblah/aitodo.nvim'
```

```lua
-- lazy.nvim
{
  "elblah/aitodo.nvim",
}
```

## Usage

- `<C-a>` in insert mode - Insert `AITODO:` comment (language-aware)
- `<leader>aa` - Process AITODOs in current file
- `<leader>ap` - Process AITODOs with custom prompt
- `<leader>al` - Open log file for current buffer
- `<leader>as` - Stop currently running job

## Configuration

```lua
require("aitodo").setup({
  log_enabled = true,  -- Enable logging (default: true)
  log_dir = "/tmp/aitodo",  -- Log directory (default: /tmp/aitodo)
  keymaps = {
    insert_todo = "<C-a>",       -- Insert AITODO comment (default: <C-a>)
    process = "<leader>aa",       -- Process file (default: <leader>aa)
    process_prompt = "<leader>ap",  -- Process with prompt (default: <leader>ap)
    open_log = "<leader>al",      -- Open log (default: <leader>al>)
    stop = "<leader>as",          -- Stop job (default: <leader>as>)
  },
})

-- Disable specific keymaps by setting to false:
require("aitodo").setup({
  keymaps = {
    insert_todo = false,  -- Disable this keymap
    open_log = "<leader>al",  -- Others work as usual
  },
})
```

Set the path to the aicoder script via environment variable:

```bash
export AITODO_AICODER_SCRIPT="/path/to/your/aicoder-script"
```

Default: `~/bin/aicoder-nvim`

## Environment Variables Passed to Script

The following environment variables are available to your script:

- `AITODO_FILEPATH` - Current file path
- `AITODO_PROMPT_ADDITIONAL` - Custom prompt (if provided)
- `AITODO_LINE`, `AITODO_COLUMN` - Cursor position
- `AITODO_BUFFER_ID` - Current buffer ID
- `AITODO_FILETYPE` - File type
- `AITODO_NVIM_PID` - Neovim process ID
- `AITODO_CWD` - Working directory
- `AITODO_VISUAL_SELECTION` - Selected text (if any)
- `AICODER_DISABLE_COLORS=1` - Disable ANSI color codes in output

Log file: `/tmp/aitodo/aitodo-<nvim_pid>-<buffer_id>.log` (if logging enabled)

## Script Interface

Your aicoder script will be called as follows:

```
<script> <filepath> [--prompt <additional_prompt>]
```

When stopping a running job, the plugin calls:

```
<script> --stop <pid>
```

Where `<pid>` is the process ID of the running script. Your script should handle the `--stop` parameter to terminate its own processing and any child processes gracefully.

See `examples/aicoder-nvim` for a reference implementation.

## API

```lua
local aitodo = require("aitodo")

-- Configure the plugin
aitodo.setup({ ... })

-- Process current file (optional prompt)
aitodo.process("custom prompt")

-- Stop currently running job
aitodo.stop()

-- Get comment prefix for a filetype
aitodo.get_comment_prefix("python")  -- Returns "# AITODO: "

-- Get log path for a buffer
aitodo.get_log_path(1)  -- Returns "/tmp/aitodo/aitodo-<pid>-1.log"

-- Get current visual selection (if any)
aitodo.get_visual_selection()  -- Returns selected text or nil
```
