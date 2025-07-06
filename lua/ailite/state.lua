-- ailite/state.lua
-- Global state management

local M = {}

-- Plugin state
M.plugin = {
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
	last_prompt_was_sent = false,
	unsent_prompt = nil,
}

-- State for streaming context
M.streaming = {
	is_streaming = false,
	total_parts = 0,
	current_part = 0,
	context_summary = nil,
}

-- Reset states
function M.reset_plugin()
	M.plugin = {
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
		input_start_line = nil,
		is_in_input_mode = false,
		current_input_lines = {},
		last_prompt_was_sent = false,
		unsent_prompt = nil,
	}
end

function M.reset_streaming()
	M.streaming = {
		is_streaming = false,
		total_parts = 0,
		current_part = 0,
		context_summary = nil,
	}
end

-- File management with path normalization
function M.add_file(filepath)
	-- Normalize path before adding
	local utils = require("ailite.utils")
	filepath = utils.normalize_path(filepath)
	if not filepath then
		return false
	end

	-- Check if already exists (with normalized path)
	for _, existing_file in ipairs(M.plugin.selected_files) do
		if existing_file == filepath then
			return false
		end
	end

	table.insert(M.plugin.selected_files, filepath)
	return true
end

function M.remove_file(filepath)
	-- Normalize path before removing
	local utils = require("ailite.utils")
	filepath = utils.normalize_path(filepath)
	if not filepath then
		return false
	end

	for i, file in ipairs(M.plugin.selected_files) do
		if file == filepath then
			table.remove(M.plugin.selected_files, i)
			return true
		end
	end
	return false
end

function M.clear_files()
	M.plugin.selected_files = {}
end

-- Chat history management
function M.add_to_history(role, content)
	table.insert(M.plugin.chat_history, { role = role, content = content })
end

function M.clear_history()
	M.plugin.chat_history = {}
end

-- Code blocks management
function M.set_code_blocks(blocks)
	M.plugin.code_blocks = blocks
	M.plugin.current_code_block = #blocks > 0 and 1 or 0
end

function M.next_code_block()
	if #M.plugin.code_blocks == 0 then
		return nil
	end

	M.plugin.current_code_block = M.plugin.current_code_block % #M.plugin.code_blocks + 1
	return M.plugin.current_code_block
end

function M.prev_code_block()
	if #M.plugin.code_blocks == 0 then
		return nil
	end

	M.plugin.current_code_block = M.plugin.current_code_block - 1
	if M.plugin.current_code_block < 1 then
		M.plugin.current_code_block = #M.plugin.code_blocks
	end
	return M.plugin.current_code_block
end

function M.get_current_code_block()
	if M.plugin.current_code_block > 0 and M.plugin.current_code_block <= #M.plugin.code_blocks then
		return M.plugin.code_blocks[M.plugin.current_code_block]
	end
	return nil
end

-- Input mode management
function M.start_input_mode(line)
	M.plugin.input_start_line = line
	M.plugin.is_in_input_mode = true
	M.plugin.current_input_lines = {}
end

function M.end_input_mode()
	M.plugin.is_in_input_mode = false
	M.plugin.input_start_line = nil
	M.plugin.current_input_lines = {}
end

-- Buffer/Window validation helpers
function M.is_chat_valid()
	return M.plugin.chat_buf and vim.api.nvim_buf_is_valid(M.plugin.chat_buf)
end

function M.is_chat_win_valid()
	return M.plugin.chat_win and vim.api.nvim_win_is_valid(M.plugin.chat_win)
end

function M.is_code_preview_valid()
	return M.plugin.code_preview_buf and vim.api.nvim_buf_is_valid(M.plugin.code_preview_buf)
end

function M.is_code_preview_win_valid()
	return M.plugin.code_preview_win and vim.api.nvim_win_is_valid(M.plugin.code_preview_win)
end

return M
