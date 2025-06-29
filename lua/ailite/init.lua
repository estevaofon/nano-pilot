-- ailite.nvim
-- A lightweight AI coding assistant for Neovim with Claude API integration

local M = {}
local api = vim.api
local fn = vim.fn

-- Default configuration
M.config = {
	api_key = nil,
	model = "claude-3-5-sonnet-20241022",
	max_tokens = 4096,
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
	-- Context configuration for large files
	context = {
		strategy = "auto", -- "single", "streaming", or "auto"
		max_tokens_per_message = 30000,
		token_estimation_ratio = 3,
		include_context_summary = true,
	},
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

-- State for streaming context
local streaming_state = {
	is_streaming = false,
	total_parts = 0,
	current_part = 0,
	context_summary = nil,
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

-- Estimate tokens more accurately
local function estimate_tokens(text)
	local base_estimate = math.ceil(#text / M.config.context.token_estimation_ratio)

	-- Add 10% margin for code
	if text:match("```") or text:match("function") or text:match("class") then
		base_estimate = math.ceil(base_estimate * 1.1)
	end

	return base_estimate
end

-- Create context summary without modifying code
local function create_context_summary(selected_files)
	local summary_parts = {}
	local total_lines = 0
	local total_size = 0
	local file_summaries = {}

	for _, filepath in ipairs(selected_files) do
		local file = io.open(filepath, "r")
		if file then
			local content = file:read("*all")
			file:close()

			local lines = vim.split(content, "\n")
			total_lines = total_lines + #lines
			total_size = total_size + #content

			local file_info = {
				name = vim.fn.fnamemodify(filepath, ":t"),
				path = vim.fn.fnamemodify(filepath, ":~:."),
				lines = #lines,
				size = #content,
				extension = vim.fn.fnamemodify(filepath, ":e"),
			}

			-- Detect main elements
			local functions = 0
			local classes = 0
			for _, line in ipairs(lines) do
				if line:match("^%s*function") or line:match("^%s*local%s+function") then
					functions = functions + 1
				elseif line:match("^%s*class%s+") then
					classes = classes + 1
				end
			end

			file_info.functions = functions
			file_info.classes = classes

			table.insert(file_summaries, file_info)
		end
	end

	table.insert(summary_parts, "=== CONTEXT SUMMARY ===")
	table.insert(summary_parts, string.format("Total files: %d", #selected_files))
	table.insert(summary_parts, string.format("Total lines: %d", total_lines))
	table.insert(summary_parts, string.format("Total size: %d bytes", total_size))
	table.insert(summary_parts, "")
	table.insert(summary_parts, "Files included:")

	for _, info in ipairs(file_summaries) do
		table.insert(
			summary_parts,
			string.format(
				"- %s (%d lines, %d functions, %d classes)",
				info.name,
				info.lines,
				info.functions,
				info.classes
			)
		)
	end

	return table.concat(summary_parts, "\n")
end

-- Split context for streaming
local function split_context_for_streaming(selected_files, prompt)
	local parts = {}
	local current_part = {
		files = {},
		estimated_tokens = 0,
	}

	-- Use 70% of limit to be safe
	local max_tokens = M.config.context.max_tokens_per_message * 0.7

	-- First, estimate total size
	local total_tokens = estimate_tokens(prompt)
	for _, filepath in ipairs(selected_files) do
		local file = io.open(filepath, "r")
		if file then
			local content = file:read("*all")
			file:close()
			total_tokens = total_tokens + estimate_tokens(content)
		end
	end

	vim.notify(
		string.format("Debug: Total estimated tokens: %d (limit per message: %d)", total_tokens, max_tokens),
		vim.log.levels.INFO
	)

	-- If fits in one message, return nil
	if total_tokens <= max_tokens then
		vim.notify("Debug: Context fits in single message", vim.log.levels.INFO)
		return nil
	end

	vim.notify("Debug: Splitting context into multiple parts", vim.log.levels.INFO)

	-- Split files into parts
	for _, filepath in ipairs(selected_files) do
		local file = io.open(filepath, "r")
		if file then
			local content = file:read("*all")
			file:close()

			local file_tokens = estimate_tokens(content)
			local file_data = {
				path = filepath,
				content = content,
				tokens = file_tokens,
			}

			-- If adding this file exceeds limit, create new part
			if current_part.estimated_tokens + file_tokens > max_tokens and #current_part.files > 0 then
				table.insert(parts, current_part)
				current_part = {
					files = {},
					estimated_tokens = 0,
				}
			end

			-- If a single file is larger than limit, need to split it
			if file_tokens > max_tokens then
				local lines = vim.split(content, "\n")
				local chunk_lines = {}
				local chunk_tokens = 0
				local chunk_start = 1

				for i, line in ipairs(lines) do
					local line_tokens = estimate_tokens(line)

					if chunk_tokens + line_tokens > max_tokens * 0.8 and #chunk_lines > 0 then
						-- Save current chunk
						table.insert(parts, {
							files = {
								{
									path = filepath,
									content = table.concat(chunk_lines, "\n"),
									tokens = chunk_tokens,
									partial = true,
									start_line = chunk_start,
									end_line = i - 1,
									total_lines = #lines,
								},
							},
							estimated_tokens = chunk_tokens,
						})

						-- Start new chunk
						chunk_lines = { line }
						chunk_tokens = line_tokens
						chunk_start = i
					else
						table.insert(chunk_lines, line)
						chunk_tokens = chunk_tokens + line_tokens
					end
				end

				-- Save last chunk
				if #chunk_lines > 0 then
					table.insert(parts, {
						files = {
							{
								path = filepath,
								content = table.concat(chunk_lines, "\n"),
								tokens = chunk_tokens,
								partial = true,
								start_line = chunk_start,
								end_line = #lines,
								total_lines = #lines,
							},
						},
						estimated_tokens = chunk_tokens,
					})
				end
			else
				-- File fits entirely
				table.insert(current_part.files, file_data)
				current_part.estimated_tokens = current_part.estimated_tokens + file_tokens
			end
		end
	end

	-- Add last part if any
	if #current_part.files > 0 then
		table.insert(parts, current_part)
	end

	return parts
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

	-- SEMPRE atualizar o conteúdo do buffer, mesmo se a janela já existir
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
			-- Usar o bloco atual correto
			local current_block = state.code_blocks[state.current_code_block]
			if current_block and state.original_buf and api.nvim_buf_is_valid(state.original_buf) then
				apply_code_to_file(current_block.code, state.original_buf)
				api.nvim_win_close(state.code_preview_win, true)
				state.code_preview_win = nil
			else
				vim.notify("Original buffer not found", vim.log.levels.ERROR)
			end
		end, opts)

		-- Copy code
		vim.keymap.set("n", M.config.keymaps.copy_code, function()
			-- Usar o bloco atual correto
			local current_block = state.code_blocks[state.current_code_block]
			if current_block then
				vim.fn.setreg("+", current_block.code)
				vim.notify("Code copied to clipboard", vim.log.levels.INFO)
			end
		end, opts)

		-- Navigate to next/previous code block dentro da janela de preview
		vim.keymap.set("n", M.config.keymaps.next_code_block, function()
			M.next_code_block()
		end, opts)

		vim.keymap.set("n", M.config.keymaps.prev_code_block, function()
			M.prev_code_block()
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
		-- Janela já existe - IMPORTANTE: atualizar o título para refletir o bloco atual
		api.nvim_win_set_config(state.code_preview_win, {
			title = string.format(" Code Block %d/%d - %s ", block_index, #state.code_blocks, block.language),
		})

		-- Garantir que o foco está na janela de preview
		api.nvim_set_current_win(state.code_preview_win)
	end
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
		title = " Ailite Chat - Press 'i' for new message, 't' for help ",
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

	vim.keymap.set("n", "t", function()
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
  • t        - Show full help
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
		M.config.keymaps.send_message,
		M.config.keymaps.next_code_block,
		M.config.keymaps.prev_code_block,
		M.config.keymaps.apply_code,
		M.config.keymaps.copy_code
	)

	vim.notify(help_text, vim.log.levels.INFO)
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

-- Call Claude API with better error handling
local function call_claude_api(prompt)
	if not M.config.api_key then
		vim.notify(
			"API key not configured! Use :lua require('ailite').setup({api_key = 'your-key'})",
			vim.log.levels.ERROR
		)
		return nil
	end

	-- Debug: log prompt size
	local prompt_size = #prompt
	vim.notify(
		string.format("Debug: Sending request with %d characters (~%d tokens)", prompt_size, estimate_tokens(prompt)),
		vim.log.levels.INFO
	)

	-- Prepare messages - IMPORTANT: streaming context is already in the prompt
	local messages = {}

	-- Only add history if we're not in streaming mode
	if not streaming_state.is_streaming then
		-- Add history
		local history_limit = M.config.history_limit or 20
		local history_start = math.max(1, #state.chat_history - history_limit + 1)

		for i = history_start, #state.chat_history do
			table.insert(messages, state.chat_history[i])
		end

		-- Prepare context with selected files
		local context = ""
		if #state.selected_files > 0 and not streaming_state.is_streaming then
			context = "Context - Project files:\n\n" .. get_selected_files_content() .. "\n\n"
		end

		-- Add current prompt with context
		table.insert(messages, {
			role = "user",
			content = context .. prompt,
		})
	else
		-- In streaming mode, just send the prompt as is
		table.insert(messages, {
			role = "user",
			content = prompt,
		})
	end

	-- Debug: Show message structure
	vim.notify("Debug: Messages array has " .. #messages .. " messages", vim.log.levels.INFO)

	-- Calculate total content size
	local total_content_size = 0
	for _, msg in ipairs(messages) do
		total_content_size = total_content_size + #msg.content
	end
	vim.notify("Debug: Total content size: " .. total_content_size .. " characters", vim.log.levels.INFO)

	-- Prepare request body
	local body = vim.fn.json_encode({
		model = M.config.model,
		messages = messages,
		max_tokens = M.config.max_tokens,
		temperature = M.config.temperature,
	})

	-- Create temp file for curl (helps with large requests)
	local tmpfile = vim.fn.tempname()
	local f = io.open(tmpfile, "w")
	if f then
		f:write(body)
		f:close()
	else
		vim.notify("Error creating temp file for request", vim.log.levels.ERROR)
		return nil
	end

	-- Make call using curl with temp file
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
		"@" .. tmpfile,
		"--max-time",
		"120", -- 2 minute timeout
		"-w",
		"\n%{http_code}", -- Add HTTP status code
	}

	vim.notify("Debug: Making API call...", vim.log.levels.INFO)
	local result = fn.system(curl_cmd)

	-- Clean up temp file
	os.remove(tmpfile)

	-- Check for curl errors
	if vim.v.shell_error ~= 0 then
		vim.notify("Curl error (code " .. vim.v.shell_error .. "): " .. result, vim.log.levels.ERROR)
		return nil
	end

	-- Separate response and HTTP code
	local lines = vim.split(result, "\n")
	local http_code = lines[#lines]
	table.remove(lines, #lines)
	local response_body = table.concat(lines, "\n")

	vim.notify("Debug: HTTP Status Code: " .. (http_code or "unknown"), vim.log.levels.INFO)

	-- Check HTTP codes
	if http_code == "401" then
		vim.notify("❌ Authentication failed! Check your API key.", vim.log.levels.ERROR)
		return nil
	elseif http_code == "429" then
		vim.notify("❌ Rate limit exceeded! Wait a moment and try again.", vim.log.levels.ERROR)
		return nil
	elseif http_code == "400" then
		vim.notify("❌ Bad request! Check your model name and request format.", vim.log.levels.ERROR)
	elseif http_code ~= "200" then
		vim.notify("❌ HTTP Error " .. http_code, vim.log.levels.ERROR)
	end

	-- Parse response
	local ok, response = pcall(vim.fn.json_decode, response_body)
	if not ok then
		vim.notify(
			"Error decoding API response. Raw response: " .. vim.inspect(response_body:sub(1, 500)),
			vim.log.levels.ERROR
		)
		return nil
	end

	if response.error then
		vim.notify("API error: " .. vim.inspect(response.error), vim.log.levels.ERROR)

		-- Check for specific error types
		if response.error.type == "invalid_request_error" then
			if response.error.message:match("max_tokens") then
				vim.notify("Token limit exceeded. Try using streaming mode or reducing context.", vim.log.levels.ERROR)
			elseif response.error.message:match("credit") or response.error.message:match("balance") then
				vim.notify("API credit/balance issue. Check your Anthropic account.", vim.log.levels.ERROR)
			end
		end

		return nil
	end

	if response.content and response.content[1] and response.content[1].text then
		vim.notify("Debug: Response received successfully", vim.log.levels.INFO)
		return response.content[1].text
	end

	vim.notify("Unexpected response format: " .. vim.inspect(response), vim.log.levels.ERROR)
	return nil
end

-- Send context in streaming (multiple messages)
local function send_context_streaming(prompt, selected_files)
	local parts = split_context_for_streaming(selected_files, prompt)

	-- If nil, context fits in one message
	if not parts then
		return send_context_single(prompt, selected_files)
	end

	streaming_state.is_streaming = true
	streaming_state.total_parts = #parts
	streaming_state.current_part = 0

	-- Create context summary
	if M.config.context.include_context_summary then
		streaming_state.context_summary = create_context_summary(selected_files)
	end

	-- Add to history the initial message
	table.insert(state.chat_history, {
		role = "user",
		content = prompt,
	})

	-- Render user message
	local line_count = api.nvim_buf_line_count(state.chat_buf)
	api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
	render_message_in_chat("user", prompt, line_count)

	-- Informative message about streaming
	api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, {
		"",
		string.format("📦 Contexto grande detectado. Enviando em %d partes...", #parts),
		"",
	})
	api.nvim_buf_set_option(state.chat_buf, "modifiable", false)

	-- Process parts sequentially
	process_streaming_parts(parts, prompt)
end

-- Process streaming parts
local function process_streaming_parts(parts, original_prompt)
	streaming_state.current_part = streaming_state.current_part + 1

	if streaming_state.current_part > #parts then
		-- All parts sent, send final question
		send_final_streaming_question(original_prompt)
		return
	end

	local part = parts[streaming_state.current_part]
	local part_content = {}

	-- Build part content
	if streaming_state.current_part == 1 then
		-- First part: include instructions and summary
		table.insert(part_content, "I'll provide you with code context in multiple parts.")
		table.insert(part_content, "Please read each part and simply respond 'Acknowledged' after each one.")
		table.insert(part_content, "After all parts are sent, I'll ask my actual question.")
		table.insert(part_content, "")

		if streaming_state.context_summary then
			table.insert(part_content, streaming_state.context_summary)
			table.insert(part_content, "")
		end
	end

	table.insert(
		part_content,
		string.format("=== PART %d/%d ===", streaming_state.current_part, streaming_state.total_parts)
	)
	table.insert(part_content, "")

	-- Add files from part
	for _, file_data in ipairs(part.files) do
		local header
		if file_data.partial then
			header = string.format(
				"File: %s (lines %d-%d of %d)",
				file_data.path,
				file_data.start_line,
				file_data.end_line,
				file_data.total_lines
			)
		else
			header = string.format("File: %s", file_data.path)
		end

		table.insert(part_content, header)
		table.insert(part_content, "```" .. vim.fn.fnamemodify(file_data.path, ":e"))
		table.insert(part_content, file_data.content)
		table.insert(part_content, "```")
		table.insert(part_content, "")
	end

	-- Add explicit instruction at end
	if streaming_state.current_part < streaming_state.total_parts then
		table.insert(part_content, "Please acknowledge receipt of this part.")
	else
		table.insert(part_content, "Please acknowledge receipt of this final part.")
	end

	local part_message = table.concat(part_content, "\n")

	-- Show progress indicator
	api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
	api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, {
		string.format(
			"⏳ Enviando parte %d/%d... (%d chars)",
			streaming_state.current_part,
			streaming_state.total_parts,
			#part_message
		),
	})
	api.nvim_buf_set_option(state.chat_buf, "modifiable", false)

	-- Send part
	vim.defer_fn(function()
		local response = call_claude_api(part_message)

		-- Remove indicator
		if state.chat_buf and api.nvim_buf_is_valid(state.chat_buf) then
			api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
			local line_count = api.nvim_buf_line_count(state.chat_buf)
			api.nvim_buf_set_lines(state.chat_buf, line_count - 1, line_count, false, {})

			-- Show brief response (acknowledgment)
			if response then
				api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, {
					string.format(
						"✓ Parte %d/%d recebida",
						streaming_state.current_part,
						streaming_state.total_parts
					),
					"",
				})

				-- Add to history for context continuity
				table.insert(state.chat_history, {
					role = "assistant",
					content = response,
				})
			else
				-- Error handling
				api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, {
					string.format("❌ Erro na parte %d/%d", streaming_state.current_part, streaming_state.total_parts),
					"",
				})

				-- Reset streaming state on error
				streaming_state.is_streaming = false
				streaming_state.total_parts = 0
				streaming_state.current_part = 0
				state.is_processing = false

				api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
				return
			end

			api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
		end

		-- Continue with next part
		vim.defer_fn(function()
			process_streaming_parts(parts, original_prompt)
		end, 1000) -- Give a bit more time between parts
	end, 100)
end

-- Send final streaming question
local function send_final_streaming_question(original_prompt)
	local final_message = string.format(
		"Now that you have all the context (%d parts), please answer my question:\n\n%s",
		streaming_state.total_parts,
		original_prompt
	)

	-- Processing indicator
	api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
	api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, {
		"",
		"🤔 Claude está analisando o contexto completo...",
	})
	api.nvim_buf_set_option(state.chat_buf, "modifiable", false)

	vim.defer_fn(function()
		local response = call_claude_api(final_message)

		-- Remove indicator
		if state.chat_buf and api.nvim_buf_is_valid(state.chat_buf) then
			api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
			local line_count = api.nvim_buf_line_count(state.chat_buf)
			api.nvim_buf_set_lines(state.chat_buf, line_count - 2, line_count, false, {})

			if response then
				render_message_in_chat("assistant", response, api.nvim_buf_line_count(state.chat_buf))

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
				api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, {
					"",
					"❌ Erro ao obter resposta da API",
				})
			end

			api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
		end

		-- Reset streaming state
		streaming_state.is_streaming = false
		streaming_state.total_parts = 0
		streaming_state.current_part = 0
		state.is_processing = false
	end, 100)
end

-- Send context in single message
local function send_context_single(prompt, selected_files)
	local context = ""

	if #selected_files > 0 then
		context = "Context - Project files:\n\n" .. get_selected_files_content() .. "\n\n"
	end

	return call_claude_api(context .. prompt)
end

-- Process prompt with streaming support
function M.process_prompt(prompt)
	if not prompt or prompt == "" then
		return
	end

	-- Reset code blocks
	state.code_blocks = {}
	state.current_code_block = 0

	-- Decide strategy based on configuration and size
	local strategy = M.config.context.strategy

	if strategy == "auto" then
		-- Estimate total size
		local total_tokens = estimate_tokens(prompt)
		for _, filepath in ipairs(state.selected_files) do
			local file = io.open(filepath, "r")
			if file then
				local content = file:read("*all")
				file:close()
				total_tokens = total_tokens + estimate_tokens(content)
			end
		end

		-- Decide based on size
		if total_tokens > M.config.context.max_tokens_per_message then
			strategy = "streaming"
		else
			strategy = "single"
		end
	end

	state.is_processing = true

	if strategy == "streaming" then
		-- Use streaming for large contexts
		send_context_streaming(prompt, state.selected_files)
	else
		-- Use original strategy
		-- Add prompt to history
		table.insert(state.chat_history, { role = "user", content = prompt })

		-- Render user message
		local line_count = api.nvim_buf_line_count(state.chat_buf)
		api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
		render_message_in_chat("user", prompt, line_count)
		api.nvim_buf_set_option(state.chat_buf, "modifiable", false)

		-- Processing indicator
		api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
		api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, { "", "🤔 Claude is thinking..." })
		api.nvim_buf_set_option(state.chat_buf, "modifiable", false)

		-- Make call
		vim.defer_fn(function()
			local response = send_context_single(prompt, state.selected_files)

			-- Remove indicator and show response
			if state.chat_buf and api.nvim_buf_is_valid(state.chat_buf) then
				api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
				local processing_line = api.nvim_buf_line_count(state.chat_buf) - 1
				api.nvim_buf_set_lines(state.chat_buf, processing_line, -1, false, {})

				if response then
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
					api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, {
						"",
						"❌ Error getting response from API",
					})
				end

				api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
			end

			state.is_processing = false
		end, 100)
	end
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
		"  • Context strategy: " .. M.config.context.strategy,
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

-- Estimate context size
function M.estimate_context()
	if #state.selected_files == 0 then
		vim.notify("No files selected", vim.log.levels.WARN)
		return
	end

	local total_tokens = 0
	local file_details = {}

	for _, filepath in ipairs(state.selected_files) do
		local file = io.open(filepath, "r")
		if file then
			local content = file:read("*all")
			file:close()

			local tokens = estimate_tokens(content)
			total_tokens = total_tokens + tokens

			table.insert(file_details, string.format("%s: ~%d tokens", vim.fn.fnamemodify(filepath, ":t"), tokens))
		end
	end

	local max_per_message = M.config.context.max_tokens_per_message
	local strategy = M.config.context.strategy

	if strategy == "auto" then
		strategy = total_tokens > max_per_message and "streaming" or "single"
	end

	local parts_needed = math.ceil(total_tokens / max_per_message)

	local info = {
		"=== Context Estimation ===",
		"",
		"Files:",
	}

	for _, detail in ipairs(file_details) do
		table.insert(info, "  " .. detail)
	end

	table.insert(info, "")
	table.insert(info, string.format("Total estimated tokens: ~%d", total_tokens))
	table.insert(info, string.format("Max tokens per message: %d", max_per_message))
	table.insert(info, string.format("Strategy: %s", strategy))

	if strategy == "streaming" then
		table.insert(info, string.format("Will send in ~%d parts", parts_needed))
	else
		table.insert(info, "Will send in single message")
	end

	vim.notify(table.concat(info, "\n"), vim.log.levels.INFO)
end

-- Set context strategy
function M.set_strategy(strategy)
	if strategy ~= "single" and strategy ~= "streaming" and strategy ~= "auto" then
		vim.notify("Invalid strategy. Use: single, streaming, or auto", vim.log.levels.ERROR)
		return
	end

	M.config.context.strategy = strategy
	vim.notify("Context strategy set to: " .. strategy, vim.log.levels.INFO)
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

-- Debug and troubleshooting functions
local function validate_model_name()
	local valid_models = {
		"claude-3-opus-20240229",
		"claude-3-sonnet-20240229",
		"claude-3-haiku-20240307",
		"claude-3-5-sonnet-20241022",
		"claude-2.1",
		"claude-2.0",
		"claude-instant-1.2",
	}

	local is_valid = false
	for _, model in ipairs(valid_models) do
		if M.config.model == model then
			is_valid = true
			break
		end
	end

	if not is_valid then
		vim.notify(
			"⚠️  Warning: Model '"
				.. M.config.model
				.. "' may not be valid. Valid models: "
				.. table.concat(valid_models, ", "),
			vim.log.levels.WARN
		)
	end
end

-- Simple API test
local function call_claude_api_simple(prompt)
	if not M.config.api_key then
		vim.notify("API key not configured!", vim.log.levels.ERROR)
		return nil
	end

	-- Simple message without history
	local messages = { {
		role = "user",
		content = prompt,
	} }

	local body = vim.fn.json_encode({
		model = M.config.model,
		messages = messages,
		max_tokens = 1024, -- Lower limit for testing
		temperature = 0.7,
	})

	-- Log request for debug
	vim.notify("Debug: Request body size: " .. #body .. " bytes", vim.log.levels.INFO)

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
		"-w",
		"\n%{http_code}", -- Add HTTP code at end
		"--max-time",
		"30",
	}

	local result = fn.system(curl_cmd)

	-- Separate response and HTTP code
	local lines = vim.split(result, "\n")
	local http_code = lines[#lines]
	table.remove(lines, #lines)
	local response_body = table.concat(lines, "\n")

	vim.notify("Debug: HTTP Status Code: " .. (http_code or "unknown"), vim.log.levels.INFO)

	-- Check common HTTP codes
	if http_code == "401" then
		vim.notify("❌ Authentication failed! Check your API key.", vim.log.levels.ERROR)
		return nil
	elseif http_code == "429" then
		vim.notify("❌ Rate limit exceeded! Wait a moment and try again.", vim.log.levels.ERROR)
		return nil
	elseif http_code == "400" then
		vim.notify("❌ Bad request! Check your model name and request format.", vim.log.levels.ERROR)
	elseif http_code ~= "200" then
		vim.notify("❌ HTTP Error " .. http_code, vim.log.levels.ERROR)
	end

	local ok, response = pcall(vim.fn.json_decode, response_body)
	if not ok then
		vim.notify("Error parsing response: " .. response_body:sub(1, 200), vim.log.levels.ERROR)
		return nil
	end

	if response.error then
		vim.notify("API Error: " .. vim.inspect(response.error), vim.log.levels.ERROR)
		return nil
	end

	if response.content and response.content[1] and response.content[1].text then
		return response.content[1].text
	end

	return nil
end

-- Debug command
function M.debug()
	local debug_info = {
		"=== AILITE DEBUG INFO ===",
		"",
		"1. Configuration:",
		"   API Key Set: " .. (M.config.api_key and "YES" or "NO"),
		"   API Key Length: " .. (M.config.api_key and #M.config.api_key or 0),
		"   Model: " .. M.config.model,
		"",
		"2. Environment:",
		"   ANTHROPIC_API_KEY: " .. (vim.env.ANTHROPIC_API_KEY and "SET" or "NOT SET"),
		"   CLAUDE_API_KEY: " .. (vim.env.CLAUDE_API_KEY and "SET" or "NOT SET"),
		"",
		"3. State:",
		"   Selected Files: " .. #state.selected_files,
		"   Chat History: " .. #state.chat_history .. " messages",
		"   Is Processing: " .. tostring(state.is_processing),
		"   Is Streaming: " .. tostring(streaming_state.is_streaming),
		"",
		"4. Testing Simple API Call...",
	}

	vim.notify(table.concat(debug_info, "\n"), vim.log.levels.INFO)

	-- Validate model
	validate_model_name()

	-- Simple test
	local test_result = call_claude_api_simple("Say 'Hello from Claude!' if you receive this.")

	if test_result then
		vim.notify("✅ API Test Successful: " .. test_result, vim.log.levels.INFO)
	else
		vim.notify("❌ API Test Failed", vim.log.levels.ERROR)

		-- Suggestions
		local suggestions = {
			"",
			"Troubleshooting suggestions:",
			"1. Check if your API key is correct",
			"2. Verify you have credits in your Anthropic account",
			"3. Try setting the API key directly:",
			"   :lua require('ailite').setup({api_key = 'sk-ant-...'})",
			"4. Check if the model name is correct:",
			"   :lua require('ailite').setup({model = 'claude-3-5-sonnet-20241022'})",
			"5. Test with curl directly:",
			"   curl -X POST https://api.anthropic.com/v1/messages \\",
			"     -H 'x-api-key: YOUR_KEY' \\",
			"     -H 'anthropic-version: 2023-06-01' \\",
			"     -H 'content-type: application/json' \\",
			'     -d \'{"model": "claude-3-5-sonnet-20241022", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 1024}\'',
		}

		vim.notify(table.concat(suggestions, "\n"), vim.log.levels.INFO)
	end
end

-- Show current configuration
function M.show_config()
	local config_info = {
		"=== Ailite Configuration ===",
		"",
		"API Key: " .. (M.config.api_key and (M.config.api_key:sub(1, 10) .. "...") or "NOT SET"),
		"Model: " .. M.config.model,
		"Max Tokens: " .. M.config.max_tokens,
		"Temperature: " .. M.config.temperature,
		"",
		"Context Settings:",
		"  Strategy: " .. M.config.context.strategy,
		"  Max Tokens/Message: " .. M.config.context.max_tokens_per_message,
		"  Token Estimation Ratio: " .. M.config.context.token_estimation_ratio,
		"  Include Summary: " .. tostring(M.config.context.include_context_summary),
	}

	vim.notify(table.concat(config_info, "\n"), vim.log.levels.INFO)
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

	-- New streaming commands
	vim.api.nvim_create_user_command("AiliteEstimateContext", function()
		M.estimate_context()
	end, {})

	vim.api.nvim_create_user_command("AiliteSetStrategy", function(opts)
		M.set_strategy(opts.args)
	end, {
		nargs = 1,
		complete = function()
			return { "single", "streaming", "auto" }
		end,
	})

	-- Debug commands
	vim.api.nvim_create_user_command("AiliteDebug", function()
		M.debug()
	end, {})

	vim.api.nvim_create_user_command("AiliteShowConfig", function()
		M.show_config()
	end, {})

	vim.api.nvim_create_user_command("AiliteSetApiKey", function(opts)
		if opts.args == "" then
			vim.notify("Usage: :AiliteSetApiKey sk-ant-...", vim.log.levels.ERROR)
			return
		end

		M.config.api_key = opts.args
		vim.notify("✅ API Key set temporarily. Test with :AiliteDebug", vim.log.levels.INFO)
	end, { nargs = 1 })

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
		{ "n", "<leader>ce", M.estimate_context, "Estimate Context Size" },
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
