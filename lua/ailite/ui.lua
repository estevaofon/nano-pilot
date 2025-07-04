-- ailite/ui.lua
-- UI components and window management

local M = {}

local config = require("ailite.config")
local utils = require("ailite.utils")

-- Create chat window
function M.create_chat_window(chat_buf)
	local cfg = config.get()

	-- Calculate dimensions for full right side
	local width = cfg.chat_window.width
	-- Use full height minus status line and command line
	local height = vim.o.lines - 2
	-- Start from top
	local row = 0
	-- Position on the right side
	local col = vim.o.columns - width

	-- Create window
	local win = vim.api.nvim_open_win(chat_buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		border = cfg.chat_window.border,
		style = "minimal",
		title = " Ailite Chat - Press 'i' for new message, 't' for help ",
		title_pos = "center",
	})

	-- Window settings
	vim.api.nvim_win_set_option(win, "wrap", true)
	vim.api.nvim_win_set_option(win, "linebreak", true)
	vim.api.nvim_win_set_option(win, "cursorline", true)

	return win
end

-- Create code preview window
function M.create_code_preview_window(buf, block_index, total_blocks, language)
	local cfg = config.get()

	local width = cfg.code_window.width
	local height = cfg.code_window.height
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		border = cfg.code_window.border,
		style = "minimal",
		title = string.format(" Code Block %d/%d - %s ", block_index, total_blocks, language),
		title_pos = "center",
	})

	return win
end

-- Update code preview window title
function M.update_code_preview_title(win, block_index, total_blocks, language)
	vim.api.nvim_win_set_config(win, {
		title = string.format(" Code Block %d/%d - %s ", block_index, total_blocks, language),
	})
end

-- Create diff window
function M.create_diff_window(buf)
	local width = math.min(100, math.floor(vim.o.columns * 0.8))
	local height = math.min(35, math.floor(vim.o.lines * 0.8))
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		border = "rounded",
		style = "minimal",
		title = " 🔍 Diff Preview - Review Changes ",
		title_pos = "center",
	})

	-- Set window options for better readability
	vim.api.nvim_win_set_option(win, "wrap", false)
	vim.api.nvim_win_set_option(win, "cursorline", true)
	vim.api.nvim_win_set_option(win, "number", false)
	vim.api.nvim_win_set_option(win, "relativenumber", false)
	vim.api.nvim_win_set_option(win, "signcolumn", "no")

	return win
end

-- Render message in chat buffer
function M.render_message_in_chat(buf, role, content, start_line)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return 0
	end

	local cfg = config.get()
	local lines = {}
	local timestamp = utils.get_timestamp()

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
		header = string.format("%s [%s]", cfg.user_prefix, timestamp)
	else
		header = string.format("%s [%s]", cfg.assistant_prefix, timestamp)
	end
	table.insert(lines, header)
	table.insert(lines, "")

	-- Add content
	for line in content:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	-- Insert lines into buffer
	vim.api.nvim_buf_set_lines(buf, start_line, start_line, false, lines)

	-- Apply highlights
	local header_line = start_line
	if start_line > 0 then
		header_line = start_line + 3 -- Skip separator lines
	end

	if role == "user" then
		vim.api.nvim_buf_add_highlight(buf, utils.ns_id, "AiliteUser", header_line, 0, -1)
	else
		vim.api.nvim_buf_add_highlight(buf, utils.ns_id, "AiliteAssistant", header_line, 0, -1)
	end

	return #lines
end

-- Show welcome message
function M.show_welcome_message(buf)
	local cfg = config.get()
	local assistant_name = cfg.assistant_name or "Claude"

	local welcome_msg = string.format(
		[[
Welcome to Ailite! 🚀

This is an interactive chat with %s. Press 'i' to start a new message.

Available commands:
  • i, o, a  - Start new message
  • Ctrl+S   - Send message (in insert mode)
  • Esc      - Cancel input or close chat
  • t        - Show full help
  • c        - Clear chat
  • q        - Close chat

Start by pressing 'i' to send your first message!]],
		assistant_name
	)

	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	local welcome_lines = utils.split_lines(welcome_msg)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, welcome_lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- Add input prompt to buffer
function M.add_input_prompt(buf, line)
	local cfg = config.get()
	vim.api.nvim_buf_set_option(buf, "modifiable", true)

	local prompt_lines = { "", cfg.chat_input_prefix }
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, prompt_lines)

	-- Apply highlight to prompt
	vim.api.nvim_buf_add_highlight(buf, utils.ns_id, "AilitePrompt", line + 1, 0, #cfg.chat_input_prefix)

	return line + 1
end

-- Show streaming progress
function M.show_streaming_progress(buf, current, total, message_size)
	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
		string.format("⏳ Enviando parte %d/%d... (%d chars)", current, total, message_size or 0),
	})
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- Remove last line from buffer
function M.remove_last_line(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	local line_count = vim.api.nvim_buf_line_count(buf)
	vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, {})
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- Show processing indicator
function M.show_processing_indicator(buf)
	local cfg = config.get()
	local assistant_name = cfg.assistant_name or "Claude"

	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "🤔 " .. assistant_name .. " is thinking" })
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- Remove processing indicator
function M.remove_processing_indicator(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	local line_count = vim.api.nvim_buf_line_count(buf)
	vim.api.nvim_buf_set_lines(buf, line_count - 2, line_count, false, {})
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

return M
