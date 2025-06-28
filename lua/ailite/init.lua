-- ailite.nvim
-- A lightweight AI coding assistant for Neovim with Claude API integration

local M = {}
local api = vim.api
local fn = vim.fn

-- Default configuration
M.config = {
	api_key = nil,
	model = "claude-3-5-sonnet-20241022",
	max_tokens = 8192,
	temperature = 0.7,
	history_limit = 20,
	chat_window = {
		width = 100,
		height = 35,
		border = "rounded",
	},
	code_window = {
		width = 80,
		height = 20,
		border = "rounded",
	},
	keymaps = {
		apply_code = "<C-a>",
		copy_code = "<C-c>",
		next_code_block = "<C-n>",
		prev_code_block = "<C-p>",
		toggle_diff = "<C-d>",
		send_message = "<C-s>",
		new_line = "<CR>",
		cancel_input = "<Esc>",
	},
	-- Interactive chat configuration
	chat_input_prefix = ">>> ",
	assistant_prefix = "Claude: ",
	user_prefix = "You: ",
}

-- Plugin state
local state = {
	chat_buf = nil,
	chat_win = nil,
	code_preview_buf = nil,
	code_preview_win = nil,
	selected_files = {},
	chat_history = {},
	is_processing = false,
	code_blocks = {},
	current_code_block = 0,
	original_buf = nil,
	original_win = nil,
	-- Interactive chat state
	input_start_line = nil,
	is_in_input_mode = false,
	current_input_lines = {},
}

-- Namespace for highlights
local ns_id = api.nvim_create_namespace("ailite")

-- Utilities
local function get_visual_selection()
	local start_pos = fn.getpos("'<")
	local end_pos = fn.getpos("'>")
	local lines = api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)

	if #lines == 0 then
		return ""
	end

	-- Adjust first and last line based on column selection
	if #lines == 1 then
		lines[1] = lines[1]:sub(start_pos[3], end_pos[3])
	else
		lines[1] = lines[1]:sub(start_pos[3])
		lines[#lines] = lines[#lines]:sub(1, end_pos[3])
	end

	return table.concat(lines, "\n")
end

-- Extract code blocks from response
local function extract_code_blocks(content)
	local blocks = {}
	local pattern = "```(%w*)\n(.-)\n```"

	for lang, code in content:gmatch(pattern) do
		table.insert(blocks, {
			language = lang ~= "" and lang or "text",
			code = code,
			start_line = nil,
			end_line = nil,
		})
	end

	return blocks
end

-- Apply code to file
local function apply_code_to_file(code, target_buf)
	if not target_buf or not api.nvim_buf_is_valid(target_buf) then
		vim.notify("Invalid buffer", vim.log.levels.ERROR)
		return
	end

	-- Ask user how to apply the code
	local choices = {
		"",
		"1. Replace entire file",
		"2. Insert at cursor",
		"3. Append to end",
		"4. Cancel",
	}

	local choice = fn.inputlist(choices)

	if choice == 1 then
		-- Replace entire file content
		local lines = vim.split(code, "\n")
		api.nvim_buf_set_lines(target_buf, 0, -1, false, {})
		api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
		vim.notify("✅ File completely replaced", vim.log.levels.INFO)

		-- Offer to save the file
		local save = fn.confirm("Save the file now?", "&Yes\n&No", 1)
		if save == 1 then
			local current_buf = api.nvim_get_current_buf()
			api.nvim_set_current_buf(target_buf)
			vim.cmd("write")
			api.nvim_set_current_buf(current_buf)
			vim.notify("💾 File saved", vim.log.levels.INFO)
		end
	elseif choice == 2 then
		-- Insert at cursor
		local win = fn.bufwinid(target_buf)
		if win ~= -1 then
			local cursor = api.nvim_win_get_cursor(win)
			local lines = vim.split(code, "\n")
			api.nvim_buf_set_lines(target_buf, cursor[1] - 1, cursor[1] - 1, false, lines)
			vim.notify("✅ Code inserted at cursor", vim.log.levels.INFO)
		else
			vim.notify("Buffer window not found", vim.log.levels.ERROR)
		end
	elseif choice == 3 then
		-- Append to end
		local lines = vim.split(code, "\n")
		api.nvim_buf_set_lines(target_buf, -1, -1, false, lines)
		vim.notify("✅ Code appended to end of file", vim.log.levels.INFO)
	end
end

-- Render message in chat with formatting
local function render_message_in_chat(role, content, start_line)
	if not state.chat_buf or not api.nvim_buf_is_valid(state.chat_buf) then
		return
	end

	local lines = {}
	local timestamp = os.date("%H:%M:%S")

	-- Add separator if not the first message
	if start_line > 0 then
		table.insert(lines, "")
		table.insert(
			lines,
			"─────────────────────────────────────"
		)
		table.insert(lines, "")
	end

	-- Message header
	local header
	if role == "user" then
		header = string.format("%s [%s]", M.config.user_prefix, timestamp)
	else
		header = string.format("%s [%s]", M.config.assistant_prefix, timestamp)
	end
	table.insert(lines, header)
	table.insert(lines, "")

	-- Add content
	for line in content:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	-- Insert lines into buffer
	api.nvim_buf_set_lines(state.chat_buf, start_line, start_line, false, lines)

	-- Apply highlights
	local header_line = start_line
	if start_line > 0 then
		header_line = start_line + 3 -- Skip separator lines
	end

	if role == "user" then
		api.nvim_buf_add_highlight(state.chat_buf, ns_id, "AiliteUser", header_line, 0, -1)
	else
		api.nvim_buf_add_highlight(state.chat_buf, ns_id, "AiliteAssistant", header_line, 0, -1)
	end

	return #lines
end

-- Start input mode
local function start_input_mode()
	if state.is_processing then
		vim.notify("⏳ Waiting for previous response...", vim.log.levels.WARN)
		return
	end

	if not state.chat_buf or not api.nvim_buf_is_valid(state.chat_buf) then
		return
	end

	-- Make buffer editable
	api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
	api.nvim_buf_set_option(state.chat_buf, "readonly", false)

	-- Add input prompt
	local line_count = api.nvim_buf_line_count(state.chat_buf)
	local prompt_lines = { "", M.config.chat_input_prefix }

	api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, prompt_lines)

	-- Mark input start
	state.input_start_line = line_count + 1
	state.is_in_input_mode = true
	state.current_input_lines = {}

	-- Move cursor after prompt
	if state.chat_win and api.nvim_win_is_valid(state.chat_win) then
		api.nvim_win_set_cursor(state.chat_win, { state.input_start_line + 1, #M.config.chat_input_prefix })
	end

	-- Apply highlight to prompt
	api.nvim_buf_add_highlight(
		state.chat_buf,
		ns_id,
		"AilitePrompt",
		state.input_start_line,
		0,
		#M.config.chat_input_prefix
	)

	-- Enter insert mode
	vim.cmd("startinsert!")
end

-- Process user input
local function process_user_input()
	if not state.is_in_input_mode or not state.input_start_line then
		return
	end

	-- Get input lines
	local current_line = api.nvim_buf_line_count(state.chat_buf)
	local input_lines = api.nvim_buf_get_lines(state.chat_buf, state.input_start_line, current_line + 1, false)

	-- Remove prompt from first line
	if #input_lines > 0 then
		input_lines[1] = input_lines[1]:sub(#M.config.chat_input_prefix + 1)
	end

	-- Join lines
	local prompt = table.concat(input_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")

	if prompt == "" then
		-- Remove empty prompt lines
		api.nvim_buf_set_lines(state.chat_buf, state.input_start_line - 1, -1, false, {})
		state.is_in_input_mode = false
		state.input_start_line = nil
		return
	end

	-- Exit input mode
	state.is_in_input_mode = false
	state.input_start_line = nil

	-- Make buffer non-editable temporarily
	api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
	api.nvim_buf_set_option(state.chat_buf, "readonly", true)

	-- Process the prompt
	M.process_prompt(prompt)
end

-- Cancel input
local function cancel_input()
	if not state.is_in_input_mode or not state.input_start_line then
		return
	end

	-- Remove input lines
	api.nvim_buf_set_lines(state.chat_buf, state.input_start_line - 1, -1, false, {})

	-- Reset state
	state.is_in_input_mode = false
	state.input_start_line = nil

	-- Make buffer non-editable
	api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
	api.nvim_buf_set_option(state.chat_buf, "readonly", true)

	-- Exit insert mode
	vim.cmd("stopinsert")
end

-- Create chat window
local function create_chat_window()
	-- Save reference to original buffer/window
	state.original_buf = api.nvim_get_current_buf()
	state.original_win = api.nvim_get_current_win()

	-- Create buffer if it doesn't exist
	if not state.chat_buf or not api.nvim_buf_is_valid(state.chat_buf) then
		state.chat_buf = api.nvim_create_buf(false, true)
		api.nvim_buf_set_option(state.chat_buf, "filetype", "markdown")
		api.nvim_buf_set_option(state.chat_buf, "bufhidden", "hide")
		api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
		api.nvim_buf_set_option(state.chat_buf, "readonly", true)
		api.nvim_buf_set_name(state.chat_buf, "Ailite-Chat")
	end

	-- Calculate position
	local width = M.config.chat_window.width
	local height = M.config.chat_window.height
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- Create window
	state.chat_win = api.nvim_open_win(state.chat_buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		border = M.config.chat_window.border,
		style = "minimal",
		title = " Ailite Chat - Press 'i' for new message, 'h' for help ",
		title_pos = "center",
	})

	-- Window settings
	api.nvim_win_set_option(state.chat_win, "wrap", true)
	api.nvim_win_set_option(state.chat_win, "linebreak", true)
	api.nvim_win_set_option(state.chat_win, "cursorline", true)

	-- Set up keymaps for normal mode
	local opts = { noremap = true, silent = true, buffer = state.chat_buf }

	-- Basic keys
	vim.keymap.set("n", "q", function()
		M.close_chat()
	end, opts)

	vim.keymap.set("n", "<Esc>", function()
		if state.is_in_input_mode then
			cancel_input()
		else
			M.close_chat()
		end
	end, opts)

	vim.keymap.set("n", "c", function()
		M.clear_chat()
	end, opts)

	vim.keymap.set("n", "i", function()
		start_input_mode()
	end, opts)

	vim.keymap.set("n", "o", function()
		start_input_mode()
	end, opts)

	vim.keymap.set("n", "a", function()
		start_input_mode()
	end, opts)

	vim.keymap.set("n", "h", function()
		M.show_help()
	end, opts)

	-- Code block navigation
	vim.keymap.set("n", M.config.keymaps.next_code_block, function()
		M.next_code_block()
	end, opts)

	vim.keymap.set("n", M.config.keymaps.prev_code_block, function()
		M.prev_code_block()
	end, opts)

	-- Insert mode keymaps (when in input)
	vim.keymap.set("i", M.config.keymaps.send_message, function()
		process_user_input()
		vim.cmd("stopinsert")
	end, opts)

	vim.keymap.set("i", "<C-c>", function()
		cancel_input()
	end, opts)

	-- Set up autocmds for the buffer
	local group = api.nvim_create_augroup("AiliteChat", { clear = true })

	-- Prevent editing outside input area
	api.nvim_create_autocmd("TextChangedI", {
		group = group,
		buffer = state.chat_buf,
		callback = function()
			if not state.is_in_input_mode then
				vim.cmd("stopinsert")
				api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
			end
		end,
	})

	-- Keep cursor in input area
	api.nvim_create_autocmd("CursorMovedI", {
		group = group,
		buffer = state.chat_buf,
		callback = function()
			if state.is_in_input_mode and state.input_start_line then
				local cursor = api.nvim_win_get_cursor(0)
				if cursor[1] < state.input_start_line + 1 then
					api.nvim_win_set_cursor(0, { state.input_start_line + 1, #M.config.chat_input_prefix })
				elseif cursor[1] == state.input_start_line + 1 and cursor[2] < #M.config.chat_input_prefix then
					api.nvim_win_set_cursor(0, { state.input_start_line + 1, #M.config.chat_input_prefix })
				end
			end
		end,
	})

	-- Show welcome message if chat is empty
	local lines = api.nvim_buf_get_lines(state.chat_buf, 0, -1, false)
	if #lines == 0 or (#lines == 1 and lines[1] == "") then
		local welcome_msg = [[
Welcome to Ailite! 🚀

This is an interactive chat with Claude. Press 'i' to start a new message.

Available commands:
  • i, o, a  - Start new message
  • Ctrl+S   - Send message (in insert mode)
  • Esc      - Cancel input or close chat
  • h        - Show full help
  • c        - Clear chat
  • q        - Close chat

Start by pressing 'i' to send your first message!]]

		api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
		local welcome_lines = vim.split(welcome_msg, "\n")
		api.nvim_buf_set_lines(state.chat_buf, 0, -1, false, welcome_lines)
		api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
	end
end

-- Show help
function M.show_help()
	local help_text = string.format(
		[[
=== Ailite Help ===

CHAT COMMANDS:
  i, o, a     - Start new message
  %s     - Send message (insert mode)
  Esc         - Cancel input or close chat
  q           - Close chat
  c           - Clear chat and history
  h           - Show this help
  %s       - Next code block
  %s       - Previous code block

CODE PREVIEW COMMANDS:
  %s       - Apply code to file
  %s       - Copy code to clipboard
  q, Esc      - Close preview

GLOBAL COMMANDS:
  :AiliteChat          - Open/close chat
  :AiliteSelectFiles   - Select files for context
  :AiliteListFiles     - List selected files
  :AiliteToggleFile    - Toggle current file
  :AiliteInfo          - Show state information
  :AiliteReplaceFile   - Replace file with last code
  :AiliteDiffApply     - Apply code with diff preview

FEATURES:
  • Terminal-style interactive chat
  • Full conversation history for context
  • Selected files automatically included
  • Code blocks can be applied directly
  • Multiple code application methods
  • Syntax highlighting for code]],
		M.config.keymaps.send_message,
		M.config.keymaps.next_code_block,
		M.config.keymaps.prev_code_block,
		M.config.keymaps.apply_code,
		M.config.keymaps.copy_code
	)

	vim.notify(help_text, vim.log.levels.INFO)
end

-- Process prompt
function M.process_prompt(prompt)
	if not prompt or prompt == "" then
		return
	end

	-- Reset code blocks
	state.code_blocks = {}
	state.current_code_block = 0

	-- Add prompt to history
	table.insert(state.chat_history, { role = "user", content = prompt })

	-- Render user message
	local line_count = api.nvim_buf_line_count(state.chat_buf)
	api.nvim_buf_set_option(state.chat_buf, "modifiable", true)

	-- Clear input prompt if it exists
	if state.input_start_line then
		api.nvim_buf_set_lines(state.chat_buf, state.input_start_line - 1, -1, false, {})
	end

	render_message_in_chat("user", prompt, api.nvim_buf_line_count(state.chat_buf))
	api.nvim_buf_set_option(state.chat_buf, "modifiable", false)

	-- Show processing indicator
	state.is_processing = true
	api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
	local processing_line = api.nvim_buf_line_count(state.chat_buf)
	api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, { "", "🤔 Claude is thinking..." })
	api.nvim_buf_set_option(state.chat_buf, "modifiable", false)

	-- Scroll to bottom
	if state.chat_win and api.nvim_win_is_valid(state.chat_win) then
		local line_count = api.nvim_buf_line_count(state.chat_buf)
		api.nvim_win_set_cursor(state.chat_win, { line_count, 0 })
	end

	-- Make async call
	vim.defer_fn(function()
		local response = call_claude_api(prompt)

		-- Remove processing indicator
		if state.chat_buf and api.nvim_buf_is_valid(state.chat_buf) then
			api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
			api.nvim_buf_set_lines(state.chat_buf, processing_line, -1, false, {})
		end

		if response then
			-- Render response
			render_message_in_chat("assistant", response, api.nvim_buf_line_count(state.chat_buf))
			table.insert(state.chat_history, { role = "assistant", content = response })

			-- Extract code blocks
			local blocks = extract_code_blocks(response)
			if #blocks > 0 then
				state.code_blocks = blocks
				state.current_code_block = 1
				vim.notify(
					string.format(
						"Found %d code blocks. Use %s/%s to navigate",
						#blocks,
						M.config.keymaps.prev_code_block,
						M.config.keymaps.next_code_block
					),
					vim.log.levels.INFO
				)
			end
		else
			api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, { "", "❌ Error getting response from API" })
		end

		api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
		state.is_processing = false

		-- Scroll to bottom
		if state.chat_win and api.nvim_win_is_valid(state.chat_win) then
			vim.defer_fn(function()
				local line_count = api.nvim_buf_line_count(state.chat_buf)
				api.nvim_win_set_cursor(state.chat_win, { line_count, 0 })
			end, 50)
		end
	end, 100)
end

-- Show code preview
local function show_code_preview(block_index)
	if not state.code_blocks or #state.code_blocks == 0 then
		vim.notify("No code blocks available", vim.log.levels.WARN)
		return
	end

	local block = state.code_blocks[block_index]
	if not block then
		return
	end

	-- Create preview buffer if it doesn't exist
	if not state.code_preview_buf or not api.nvim_buf_is_valid(state.code_preview_buf) then
		state.code_preview_buf = api.nvim_create_buf(false, true)
		api.nvim_buf_set_option(state.code_preview_buf, "bufhidden", "hide")
	end

	-- Set content
	local lines = vim.split(block.code, "\n")
	api.nvim_buf_set_lines(state.code_preview_buf, 0, -1, false, lines)

	-- Set filetype based on language
	if block.language and block.language ~= "" then
		api.nvim_buf_set_option(state.code_preview_buf, "filetype", block.language)
	end

	-- Create window if it doesn't exist
	if not state.code_preview_win or not api.nvim_win_is_valid(state.code_preview_win) then
		local width = M.config.code_window.width
		local height = M.config.code_window.height
		local row = math.floor((vim.o.lines - height) / 2)
		local col = math.floor((vim.o.columns - width) / 2)

		state.code_preview_win = api.nvim_open_win(state.code_preview_buf, true, {
			relative = "editor",
			row = row,
			col = col,
			width = width,
			height = height,
			border = M.config.code_window.border,
			style = "minimal",
			title = string.format(" Code Block %d/%d - %s ", block_index, #state.code_blocks, block.language),
			title_pos = "center",
		})

		-- Set up keymaps in preview
		local opts = { noremap = true, silent = true, buffer = state.code_preview_buf }

		-- Apply code
		vim.keymap.set("n", M.config.keymaps.apply_code, function()
			if state.original_buf and api.nvim_buf_is_valid(state.original_buf) then
				apply_code_to_file(block.code, state.original_buf)
				api.nvim_win_close(state.code_preview_win, true)
				state.code_preview_win = nil
			else
				vim.notify("Original buffer not found", vim.log.levels.ERROR)
			end
		end, opts)

		-- Copy code
		vim.keymap.set("n", M.config.keymaps.copy_code, function()
			vim.fn.setreg("+", block.code)
			vim.notify("Code copied to clipboard", vim.log.levels.INFO)
		end, opts)

		-- Close preview
		vim.keymap.set("n", "q", function()
			api.nvim_win_close(state.code_preview_win, true)
			state.code_preview_win = nil
		end, opts)

		vim.keymap.set("n", "<Esc>", function()
			api.nvim_win_close(state.code_preview_win, true)
			state.code_preview_win = nil
		end, opts)
	else
		-- Update title
		api.nvim_win_set_config(state.code_preview_win, {
			title = string.format(" Code Block %d/%d - %s ", block_index, #state.code_blocks, block.language),
		})
	end
end

-- Navigate code blocks
function M.next_code_block()
	if #state.code_blocks == 0 then
		vim.notify("No code blocks available", vim.log.levels.WARN)
		return
	end

	state.current_code_block = state.current_code_block % #state.code_blocks + 1
	show_code_preview(state.current_code_block)
end

function M.prev_code_block()
	if #state.code_blocks == 0 then
		vim.notify("No code blocks available", vim.log.levels.WARN)
		return
	end

	state.current_code_block = state.current_code_block - 1
	if state.current_code_block < 1 then
		state.current_code_block = #state.code_blocks
	end
	show_code_preview(state.current_code_block)
end

-- Replace entire file with code
function M.replace_file_with_last_code()
	if #state.code_blocks == 0 then
		vim.notify("❌ No code blocks available", vim.log.levels.ERROR)
		return
	end

	if not state.original_buf or not api.nvim_buf_is_valid(state.original_buf) then
		vim.notify("❌ Original buffer not found", vim.log.levels.ERROR)
		return
	end

	-- Get code from current or first block
	local block = state.code_blocks[state.current_code_block] or state.code_blocks[1]
	local code = block.code

	-- Confirm replacement
	local filename = fn.fnamemodify(api.nvim_buf_get_name(state.original_buf), ":t")
	local confirm =
		fn.confirm(string.format("⚠️  Replace ALL content of '%s'?", filename), "&Yes\n&No\n&View preview", 2)

	if confirm == 1 then
		-- Replace file
		local lines = vim.split(code, "\n")
		api.nvim_buf_set_lines(state.original_buf, 0, -1, false, {})
		api.nvim_buf_set_lines(state.original_buf, 0, -1, false, lines)

		vim.notify("✅ File replaced completely", vim.log.levels.INFO)

		-- Offer to save
		local save = fn.confirm("💾 Save file now?", "&Yes\n&No", 1)
		if save == 1 then
			local current_buf = api.nvim_get_current_buf()
			api.nvim_set_current_buf(state.original_buf)
			vim.cmd("write")
			api.nvim_set_current_buf(current_buf)
			vim.notify("💾 File saved", vim.log.levels.INFO)
		end
	elseif confirm == 3 then
		-- Show preview
		show_code_preview(state.current_code_block or 1)
	end
end

-- Apply code with diff preview
function M.apply_code_with_diff()
	if #state.code_blocks == 0 then
		vim.notify("❌ No code blocks available", vim.log.levels.ERROR)
		return
	end

	if not state.original_buf or not api.nvim_buf_is_valid(state.original_buf) then
		vim.notify("❌ Original buffer not found", vim.log.levels.ERROR)
		return
	end

	-- Create temporary buffer for diff
	local diff_buf = api.nvim_create_buf(false, true)
	local block = state.code_blocks[state.current_code_block] or state.code_blocks[1]

	-- Get current content
	local current_lines = api.nvim_buf_get_lines(state.original_buf, 0, -1, false)
	local new_lines = vim.split(block.code, "\n")

	-- Create side-by-side view
	local diff_lines = {
		"=== DIFF PREVIEW ===",
		"",
		"CURRENT FILE (" .. #current_lines .. " lines) -> NEW CONTENT (" .. #new_lines .. " lines)",
		"",
	}

	-- Show first 10 lines of each
	table.insert(diff_lines, "--- First lines of current file ---")
	for i = 1, math.min(10, #current_lines) do
		table.insert(diff_lines, current_lines[i])
	end
	if #current_lines > 10 then
		table.insert(diff_lines, "... (" .. (#current_lines - 10) .. " lines omitted)")
	end

	table.insert(diff_lines, "")
	table.insert(diff_lines, "+++ First lines of new content +++")
	for i = 1, math.min(10, #new_lines) do
		table.insert(diff_lines, new_lines[i])
	end
	if #new_lines > 10 then
		table.insert(diff_lines, "... (" .. (#new_lines - 10) .. " lines omitted)")
	end

	api.nvim_buf_set_lines(diff_buf, 0, -1, false, diff_lines)

	-- Show in floating window
	local width = 80
	local height = 25
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local diff_win = api.nvim_open_win(diff_buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		border = "rounded",
		style = "minimal",
		title = " Confirm Replacement ",
		title_pos = "center",
	})

	-- Keymaps for diff
	local opts = { noremap = true, silent = true, buffer = diff_buf }

	-- Confirm replacement
	vim.keymap.set("n", "y", function()
		api.nvim_win_close(diff_win, true)
		api.nvim_buf_set_lines(state.original_buf, 0, -1, false, {})
		api.nvim_buf_set_lines(state.original_buf, 0, -1, false, new_lines)
		vim.notify("✅ File replaced", vim.log.levels.INFO)
	end, opts)

	-- Cancel
	vim.keymap.set("n", "n", function()
		api.nvim_win_close(diff_win, true)
		vim.notify("❌ Replacement cancelled", vim.log.levels.INFO)
	end, opts)

	vim.keymap.set("n", "q", function()
		api.nvim_win_close(diff_win, true)
	end, opts)

	vim.keymap.set("n", "<Esc>", function()
		api.nvim_win_close(diff_win, true)
	end, opts)

	-- Show instructions
	api.nvim_buf_set_lines(diff_buf, -1, -1, false, {
		"",
		"─────────────────────────────────────",
		"Press 'y' to confirm, 'n' to cancel",
	})
end

-- Helper functions
local function get_selected_files_content()
	local content = {}

	for _, filepath in ipairs(state.selected_files) do
		local file = io.open(filepath, "r")
		if file then
			local file_content = file:read("*all")
			file:close()

			table.insert(
				content,
				string.format("### File: %s\n```%s\n%s\n```", filepath, fn.fnamemodify(filepath, ":e"), file_content)
			)
		end
	end

	return table.concat(content, "\n\n")
end

-- Call Claude API
call_claude_api = function(prompt)
	if not M.config.api_key then
		vim.notify(
			"API key not configured! Use :lua require('ailite').setup({api_key = 'your-key'})",
			vim.log.levels.ERROR
		)
		return nil
	end

	-- Prepare context with selected files
	local context = ""
	if #state.selected_files > 0 then
		context = "Context - Project files:\n\n" .. get_selected_files_content() .. "\n\n"
	end

	-- Prepare messages
	local messages = {}

	-- Add history
	local history_limit = M.config.history_limit or 20
	local history_start = math.max(1, #state.chat_history - history_limit + 1)

	for i = history_start, #state.chat_history do
		table.insert(messages, state.chat_history[i])
	end

	-- Add current prompt with context
	local current_message = {
		role = "user",
		content = context .. prompt,
	}
	table.insert(messages, current_message)

	-- Prepare request body
	local body = vim.fn.json_encode({
		model = M.config.model,
		messages = messages,
		max_tokens = M.config.max_tokens,
		temperature = M.config.temperature,
	})

	-- Make call using curl
	local curl_cmd = {
		"curl",
		"-s",
		"-X",
		"POST",
		"https://api.anthropic.com/v1/messages",
		"-H",
		"Content-Type: application/json",
		"-H",
		"x-api-key: " .. M.config.api_key,
		"-H",
		"anthropic-version: 2023-06-01",
		"-d",
		body,
	}

	local result = fn.system(curl_cmd)

	-- Parse response
	local ok, response = pcall(vim.fn.json_decode, result)
	if not ok then
		vim.notify("Error decoding API response: " .. result, vim.log.levels.ERROR)
		return nil
	end

	if response.error then
		vim.notify("API error: " .. response.error.message, vim.log.levels.ERROR)
		return nil
	end

	if response.content and response.content[1] and response.content[1].text then
		return response.content[1].text
	end

	return nil
end

-- File management functions
function M.toggle_file(filepath)
	local index = nil
	for i, file in ipairs(state.selected_files) do
		if file == filepath then
			index = i
			break
		end
	end

	if index then
		table.remove(state.selected_files, index)
		vim.notify("📄 File removed: " .. filepath)
	else
		table.insert(state.selected_files, filepath)
		vim.notify("📄 File added: " .. filepath)
	end
end

function M.toggle_current_file()
	local current_file = fn.expand("%:p")
	if current_file ~= "" then
		M.toggle_file(current_file)
	else
		vim.notify("No file open", vim.log.levels.WARN)
	end
end

function M.select_files()
	-- Use telescope if available
	local ok, telescope = pcall(require, "telescope.builtin")
	if ok then
		telescope.find_files({
			attach_mappings = function(prompt_bufnr, map)
				local actions = require("telescope.actions")
				local action_state = require("telescope.actions.state")

				-- Toggle file
				map("i", "<CR>", function()
					local selection = action_state.get_selected_entry()
					if selection then
						local filepath = selection.path or selection.filename
						M.toggle_file(filepath)
					end
				end)

				-- Remove file
				map("i", "<C-x>", function()
					local selection = action_state.get_selected_entry()
					if selection then
						local filepath = selection.path or selection.filename
						local index = nil
						for i, file in ipairs(state.selected_files) do
							if file == filepath then
								index = i
								break
							end
						end
						if index then
							table.remove(state.selected_files, index)
							vim.notify("File removed: " .. filepath)
						end
					end
				end)

				-- Add multiple
				map("i", "<C-a>", function()
					local picker = action_state.get_current_picker(prompt_bufnr)
					local multi_selections = picker:get_multi_selection()

					local added = 0
					for _, selection in ipairs(multi_selections) do
						local filepath = selection.path or selection.filename
						if not vim.tbl_contains(state.selected_files, filepath) then
							table.insert(state.selected_files, filepath)
							added = added + 1
						end
					end

					actions.close(prompt_bufnr)
					vim.notify(added .. " files added")
				end)

				return true
			end,
			prompt_title = "Select Files (Enter=toggle, C-x=remove, C-a=multiple)",
		})
	else
		-- Fallback
		local filepath = fn.input("File path: ", fn.expand("%:p:h") .. "/", "file")
		if filepath ~= "" and fn.filereadable(filepath) == 1 then
			M.toggle_file(filepath)
		end
	end
end

function M.list_selected_files()
	if #state.selected_files == 0 then
		vim.notify("No files selected", vim.log.levels.INFO)
		return
	end

	local file_list = {}
	for i, file in ipairs(state.selected_files) do
		table.insert(file_list, string.format("%d. %s", i, file))
	end

	vim.notify("📁 Selected files:\n" .. table.concat(file_list, "\n"), vim.log.levels.INFO)
end

function M.clear_selected_files()
	state.selected_files = {}
	vim.notify("✨ File selection cleared")
end

function M.clear_chat()
	if state.chat_buf and api.nvim_buf_is_valid(state.chat_buf) then
		api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
		api.nvim_buf_set_lines(state.chat_buf, 0, -1, false, {})
		api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
		state.chat_history = {}
		state.code_blocks = {}
		state.current_code_block = 0
		state.is_in_input_mode = false
		state.input_start_line = nil
		vim.notify("💬 Chat and history cleared")
	end
end

function M.close_chat()
	-- Cancel input if active
	if state.is_in_input_mode then
		cancel_input()
	end

	if state.chat_win and api.nvim_win_is_valid(state.chat_win) then
		api.nvim_win_close(state.chat_win, true)
		state.chat_win = nil
	end
	if state.code_preview_win and api.nvim_win_is_valid(state.code_preview_win) then
		api.nvim_win_close(state.code_preview_win, true)
		state.code_preview_win = nil
	end
end

function M.toggle_chat()
	if state.chat_win and api.nvim_win_is_valid(state.chat_win) then
		M.close_chat()
	else
		create_chat_window()
	end
end

function M.show_info()
	local info = {
		"=== 🚀 Ailite Info ===",
		"",
		"📊 State:",
		"  • History: " .. #state.chat_history .. " messages",
		"  • Selected files: " .. #state.selected_files,
		"  • Code blocks: " .. #state.code_blocks,
		"  • History limit: " .. (M.config.history_limit or 20) .. " messages",
		"",
		"🔧 Configuration:",
		"  • Model: " .. M.config.model,
		"  • Max tokens: " .. M.config.max_tokens,
		"  • Temperature: " .. M.config.temperature,
		"  • API Key: " .. (M.config.api_key and "✅ Configured" or "❌ Not configured"),
		"",
	}

	if #state.selected_files > 0 then
		table.insert(info, "📄 Files in context:")
		for i, file in ipairs(state.selected_files) do
			table.insert(info, string.format("  %d. %s", i, vim.fn.fnamemodify(file, ":~:.")))
		end
		table.insert(info, "")
	end

	table.insert(info, "⌨️  Main shortcuts:")
	table.insert(info, "  • <leader>cc - Toggle chat")
	table.insert(info, "  • <leader>cp - Quick prompt")
	table.insert(info, "  • <leader>cf - Select files")
	table.insert(info, "  • <leader>ct - Toggle current file")

	vim.notify(table.concat(info, "\n"), vim.log.levels.INFO)
end

-- Prompt with visual selection
function M.prompt_with_selection()
	local selection = get_visual_selection()
	if selection == "" then
		vim.notify("No selection found", vim.log.levels.WARN)
		return
	end

	-- Open chat if not open
	if not state.chat_win or not api.nvim_win_is_valid(state.chat_win) then
		create_chat_window()
	end

	-- Create prompt with selection context
	local prompt = string.format(
		"About the selected code:\n```%s\n%s\n```\n\nWhat would you like to do with this code?",
		vim.bo.filetype,
		selection
	)

	M.process_prompt(prompt)
end

-- Quick prompt
function M.prompt()
	if state.is_processing then
		vim.notify("⏳ Waiting for previous response...", vim.log.levels.WARN)
		return
	end

	local prompt = fn.input("💬 Prompt: ")
	if prompt == "" then
		return
	end

	-- Show chat if not open
	if not state.chat_win or not api.nvim_win_is_valid(state.chat_win) then
		create_chat_window()
	end

	M.process_prompt(prompt)
end

-- Plugin setup
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	-- Try to get API key from environment
	if not M.config.api_key then
		M.config.api_key = vim.env.ANTHROPIC_API_KEY or vim.env.CLAUDE_API_KEY
	end

	-- Create commands
	vim.api.nvim_create_user_command("AiliteChat", function()
		M.toggle_chat()
	end, {})
	vim.api.nvim_create_user_command("AilitePrompt", function()
		M.prompt()
	end, {})
	vim.api.nvim_create_user_command("AiliteSelectFiles", function()
		M.select_files()
	end, {})
	vim.api.nvim_create_user_command("AiliteListFiles", function()
		M.list_selected_files()
	end, {})
	vim.api.nvim_create_user_command("AiliteClearFiles", function()
		M.clear_selected_files()
	end, {})
	vim.api.nvim_create_user_command("AiliteClearChat", function()
		M.clear_chat()
	end, {})
	vim.api.nvim_create_user_command("AiliteToggleFile", function()
		M.toggle_current_file()
	end, {})
	vim.api.nvim_create_user_command("AiliteInfo", function()
		M.show_info()
	end, {})
	vim.api.nvim_create_user_command("AiliteHelp", function()
		M.show_help()
	end, {})
	vim.api.nvim_create_user_command("AiliteReplaceFile", function()
		M.replace_file_with_last_code()
	end, {})
	vim.api.nvim_create_user_command("AiliteDiffApply", function()
		M.apply_code_with_diff()
	end, {})
	vim.api.nvim_create_user_command("AiliteApplyCode", function()
		if #state.code_blocks > 0 then
			show_code_preview(state.current_code_block or 1)
		else
			vim.notify("No code blocks available", vim.log.levels.WARN)
		end
	end, {})

	-- Create default keymaps
	local keymaps = {
		{ "n", "<leader>cc", M.toggle_chat, "Toggle Ailite Chat" },
		{ "n", "<leader>cp", M.prompt, "Ailite Quick Prompt" },
		{ "v", "<leader>cp", M.prompt_with_selection, "Ailite Prompt with Selection" },
		{ "n", "<leader>cf", M.select_files, "Ailite Select Files for Context" },
		{ "n", "<leader>cl", M.list_selected_files, "Ailite List Selected Files" },
		{ "n", "<leader>ct", M.toggle_current_file, "Ailite Toggle Current File" },
		{ "n", "<leader>ci", M.show_info, "Show Ailite Info" },
		{ "n", "<leader>ch", M.show_help, "Show Ailite Help" },
		{
			"n",
			"<leader>ca",
			function()
				if #state.code_blocks > 0 then
					show_code_preview(1)
				else
					vim.notify("No code blocks available", vim.log.levels.WARN)
				end
			end,
			"Apply Code from Last Response",
		},
		{ "n", "<leader>cr", M.replace_file_with_last_code, "Replace Entire File with Code" },
		{ "n", "<leader>cd", M.apply_code_with_diff, "Apply Code with Diff Preview" },
	}

	for _, map in ipairs(keymaps) do
		vim.keymap.set(map[1], map[2], map[3], { desc = map[4], noremap = true, silent = true })
	end

	-- Create custom highlight groups
	vim.api.nvim_set_hl(0, "AiliteUser", { fg = "#61afef", bold = true })
	vim.api.nvim_set_hl(0, "AiliteAssistant", { fg = "#98c379", bold = true })
	vim.api.nvim_set_hl(0, "AilitePrompt", { fg = "#c678dd", bold = true })

	-- Notify that plugin is loaded
	if M.config.api_key then
		vim.notify("✨ Ailite loaded successfully! Use <leader>cc to open chat.", vim.log.levels.INFO)
	else
		vim.notify(
			"⚠️  Ailite: API key not configured! Set ANTHROPIC_API_KEY or configure in setup().",
			vim.log.levels.WARN
		)
	end
end

return M
