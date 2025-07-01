-- ailite/chat.lua
-- Chat window and interaction management

local M = {}

local config = require("ailite.config")
local state = require("ailite.state")
local utils = require("ailite.utils")
local ui = require("ailite.ui")
local context = require("ailite.context")
local api = require("ailite.api")
local code = require("ailite.code")

-- Start input mode
function M.start_input_mode()
	if state.plugin.is_processing then
		utils.notify("⏳ Waiting for previous response...", vim.log.levels.WARN)
		return
	end

	if not state.is_chat_valid() then
		return
	end

	-- Make buffer editable
	vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", true)
	vim.api.nvim_buf_set_option(state.plugin.chat_buf, "readonly", false)

	-- Add input prompt
	local line_count = vim.api.nvim_buf_line_count(state.plugin.chat_buf)
	local input_line = ui.add_input_prompt(state.plugin.chat_buf, line_count)

	-- Mark input start
	state.start_input_mode(input_line)

	-- Move cursor after prompt
	if state.is_chat_win_valid() then
		local cfg = config.get()
		vim.api.nvim_win_set_cursor(state.plugin.chat_win, {
			input_line + 1,
			#cfg.chat_input_prefix,
		})
	end

	-- Enter insert mode
	vim.cmd("startinsert!")
end

-- Process user input
function M.process_user_input()
	if not state.plugin.is_in_input_mode or not state.plugin.input_start_line then
		return
	end

	local cfg = config.get()

	-- Get input lines
	local current_line = vim.api.nvim_buf_line_count(state.plugin.chat_buf)
	local input_lines =
		vim.api.nvim_buf_get_lines(state.plugin.chat_buf, state.plugin.input_start_line, current_line + 1, false)

	-- Remove prompt from first line
	if #input_lines > 0 then
		input_lines[1] = input_lines[1]:sub(#cfg.chat_input_prefix + 1)
	end

	-- Join lines
	local prompt = utils.trim(table.concat(input_lines, "\n"))

	if prompt == "" then
		-- Remove empty prompt lines
		vim.api.nvim_buf_set_lines(state.plugin.chat_buf, state.plugin.input_start_line - 1, -1, false, {})
		state.end_input_mode()
		return
	end

	-- Exit input mode
	state.end_input_mode()

	-- Make buffer non-editable temporarily
	vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", false)
	vim.api.nvim_buf_set_option(state.plugin.chat_buf, "readonly", true)

	-- Process the prompt
	M.process_prompt(prompt)
end

-- Cancel input
function M.cancel_input()
	if not state.plugin.is_in_input_mode or not state.plugin.input_start_line then
		return
	end

	-- Remove input lines
	vim.api.nvim_buf_set_lines(state.plugin.chat_buf, state.plugin.input_start_line - 1, -1, false, {})

	-- Reset state
	state.end_input_mode()

	-- Make buffer non-editable
	vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", false)
	vim.api.nvim_buf_set_option(state.plugin.chat_buf, "readonly", true)

	-- Exit insert mode
	vim.cmd("stopinsert")
end

-- Process prompt
function M.process_prompt(prompt)
	if not prompt or prompt == "" then
		return
	end

	-- Reset code blocks
	state.set_code_blocks({})

	-- Decide strategy
	local cfg = config.get()
	local strategy = cfg.context.strategy

	if strategy == "auto" then
		-- Estimate total size
		local total_tokens = utils.estimate_tokens(prompt)
		for _, filepath in ipairs(state.plugin.selected_files) do
			local content = utils.read_file(filepath)
			if content then
				total_tokens = total_tokens + utils.estimate_tokens(content)
			end
		end

		-- Decide based on size
		if total_tokens > cfg.context.max_tokens_per_message then
			strategy = "streaming"
		else
			strategy = "single"
		end
	end

	state.plugin.is_processing = true

	-- Define callback for handling responses
	local function handle_response(event_type, data)
		if event_type == "progress" then
			ui.show_streaming_progress(state.plugin.chat_buf, data.current, data.total, #data.message)
		elseif event_type == "part_complete" then
			ui.remove_last_line(state.plugin.chat_buf)
			vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", true)
			vim.api.nvim_buf_set_lines(state.plugin.chat_buf, -1, -1, false, {
				string.format("✓ Parte %d/%d recebida", data.current, data.total),
				"",
			})
			vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", false)
		elseif event_type == "final_processing" then
			vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", true)
			vim.api.nvim_buf_set_lines(state.plugin.chat_buf, -1, -1, false, {
				"",
				"🤔   Claude is thinking...",
			})
			vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", false)
		elseif event_type == "complete" then
			M.handle_complete_response(data.response)
		elseif event_type == "error" then
			ui.remove_last_line(state.plugin.chat_buf)
			vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", true)
			vim.api.nvim_buf_set_lines(state.plugin.chat_buf, -1, -1, false, {
				"",
				"❌ " .. (data.message or "Error getting response"),
			})
			vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", false)
			state.plugin.is_processing = false
		end
	end

	if strategy == "streaming" then
		-- Use streaming for large contexts
		context.send_context_streaming(prompt, state.plugin.selected_files, handle_response)
	else
		-- Use single message strategy
		-- Add prompt to history
		state.add_to_history("user", prompt)

		-- Render user message
		local line_count = vim.api.nvim_buf_line_count(state.plugin.chat_buf)
		vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", true)
		ui.render_message_in_chat(state.plugin.chat_buf, "user", prompt, line_count)
		vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", false)

		-- Processing indicator with animation
		ui.show_processing_indicator(state.plugin.chat_buf)

		-- Make async call
		context.send_context_single(prompt, state.plugin.selected_files, handle_response)
	end
end

-- Handle complete response
function M.handle_complete_response(response)
	if not state.is_chat_valid() then
		return
	end

	-- Remove processing indicator
	ui.remove_processing_indicator(state.plugin.chat_buf)

	if response then
		-- Render assistant message
		vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", true)
		ui.render_message_in_chat(
			state.plugin.chat_buf,
			"assistant",
			response,
			vim.api.nvim_buf_line_count(state.plugin.chat_buf)
		)
		vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", false)

		-- Add to history
		state.add_to_history("assistant", response)

		-- Extract code blocks
		local blocks = utils.extract_code_blocks(response)
		if #blocks > 0 then
			state.set_code_blocks(blocks)
			local cfg = config.get()
			utils.notify(
				string.format(
					"Found %d code blocks. Use %s/%s to navigate",
					#blocks,
					cfg.keymaps.prev_code_block,
					cfg.keymaps.next_code_block
				),
				vim.log.levels.INFO
			)
		end
	else
		vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(state.plugin.chat_buf, -1, -1, false, {
			"",
			"❌ Error getting response from API",
		})
		vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", false)
	end

	state.plugin.is_processing = false
end

-- Create chat window
function M.create_chat_window()
	-- Save reference to original buffer/window
	state.plugin.original_buf = vim.api.nvim_get_current_buf()
	state.plugin.original_win = vim.api.nvim_get_current_win()

	-- Create buffer if it doesn't exist
	if not state.is_chat_valid() then
		state.plugin.chat_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_option(state.plugin.chat_buf, "filetype", "markdown")
		vim.api.nvim_buf_set_option(state.plugin.chat_buf, "bufhidden", "hide")
		vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", false)
		vim.api.nvim_buf_set_option(state.plugin.chat_buf, "readonly", true)
		vim.api.nvim_buf_set_name(state.plugin.chat_buf, "Ailite-Chat")
	end

	-- Create window
	state.plugin.chat_win = ui.create_chat_window(state.plugin.chat_buf)

	-- Setup keymaps
	M.setup_chat_keymaps()

	-- Setup autocmds
	M.setup_chat_autocmds()

	-- Show welcome message if chat is empty
	local lines = vim.api.nvim_buf_get_lines(state.plugin.chat_buf, 0, -1, false)
	if #lines == 0 or (#lines == 1 and lines[1] == "") then
		ui.show_welcome_message(state.plugin.chat_buf)
	end
end

-- Setup chat keymaps
function M.setup_chat_keymaps()
	local cfg = config.get()
	local opts = { noremap = true, silent = true, buffer = state.plugin.chat_buf }

	-- Basic keys
	vim.keymap.set("n", "q", function()
		M.close_chat()
	end, opts)
	vim.keymap.set("n", "<Esc>", function()
		if state.plugin.is_in_input_mode then
			M.cancel_input()
		else
			M.close_chat()
		end
	end, opts)
	vim.keymap.set("n", "c", function()
		M.clear_chat()
	end, opts)
	vim.keymap.set("n", "i", function()
		M.start_input_mode()
	end, opts)
	vim.keymap.set("n", "o", function()
		M.start_input_mode()
	end, opts)
	vim.keymap.set("n", "a", function()
		M.start_input_mode()
	end, opts)
	vim.keymap.set("n", "t", function()
		M.show_help()
	end, opts)

	-- Code block navigation
	vim.keymap.set("n", cfg.keymaps.next_code_block, function()
		code.next_code_block()
	end, opts)
	vim.keymap.set("n", cfg.keymaps.prev_code_block, function()
		code.prev_code_block()
	end, opts)

	-- Insert mode keymaps
	vim.keymap.set("i", cfg.keymaps.send_message, function()
		M.process_user_input()
		vim.cmd("stopinsert")
	end, opts)
	vim.keymap.set("i", "<C-c>", function()
		M.cancel_input()
	end, opts)
end

-- Setup chat autocmds
function M.setup_chat_autocmds()
	local cfg = config.get()
	local group = vim.api.nvim_create_augroup("AiliteChat", { clear = true })

	-- Prevent editing outside input area
	vim.api.nvim_create_autocmd("TextChangedI", {
		group = group,
		buffer = state.plugin.chat_buf,
		callback = function()
			if not state.plugin.is_in_input_mode then
				vim.cmd("stopinsert")
				vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", false)
			end
		end,
	})

	-- Keep cursor in input area
	vim.api.nvim_create_autocmd("CursorMovedI", {
		group = group,
		buffer = state.plugin.chat_buf,
		callback = function()
			if state.plugin.is_in_input_mode and state.plugin.input_start_line then
				local cursor = vim.api.nvim_win_get_cursor(0)
				if cursor[1] < state.plugin.input_start_line + 1 then
					vim.api.nvim_win_set_cursor(0, {
						state.plugin.input_start_line + 1,
						#cfg.chat_input_prefix,
					})
				elseif cursor[1] == state.plugin.input_start_line + 1 and cursor[2] < #cfg.chat_input_prefix then
					vim.api.nvim_win_set_cursor(0, {
						state.plugin.input_start_line + 1,
						#cfg.chat_input_prefix,
					})
				end
			end
		end,
	})
end

-- Clear chat
function M.clear_chat()
	if state.is_chat_valid() then
		vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(state.plugin.chat_buf, 0, -1, false, {})
		vim.api.nvim_buf_set_option(state.plugin.chat_buf, "modifiable", false)
		state.clear_history()
		state.set_code_blocks({})
		state.end_input_mode()
		utils.notify("💬 Chat and history cleared")
	end
end

-- Close chat
function M.close_chat()
	-- Cancel input if active
	if state.plugin.is_in_input_mode then
		M.cancel_input()
	end

	if state.is_chat_win_valid() then
		vim.api.nvim_win_close(state.plugin.chat_win, true)
		state.plugin.chat_win = nil
	end
	if state.is_code_preview_win_valid() then
		vim.api.nvim_win_close(state.plugin.code_preview_win, true)
		state.plugin.code_preview_win = nil
	end
end

-- Toggle chat
function M.toggle_chat()
	if state.is_chat_win_valid() then
		M.close_chat()
	else
		M.create_chat_window()
	end
end

-- Show help
function M.show_help()
	local cfg = config.get()
	local help_text = string.format(
		[[
=== Ailite Help ===

CHAT COMMANDS:
  i, o, a     - Start new message
  %s     - Send message (insert mode)
  Esc         - Cancel input or close chat
  q           - Close chat
  c           - Clear chat and history
  t           - Show this help
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
  :AiliteEstimateContext - Estimate context size
  :AiliteSetStrategy   - Set context strategy
  :AiliteDebug         - Debug API connection

FEATURES:
  • Terminal-style interactive chat
  • Full conversation history for context
  • Selected files automatically included
  • Code blocks can be applied directly
  • Multiple code application methods
  • Syntax highlighting for code
  • Automatic handling of large files]],
		cfg.keymaps.send_message,
		cfg.keymaps.next_code_block,
		cfg.keymaps.prev_code_block,
		cfg.keymaps.apply_code,
		cfg.keymaps.copy_code
	)

	utils.notify(help_text, vim.log.levels.INFO)
end

return M
