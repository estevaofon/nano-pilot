-- ailite/code.lua
-- Code block management and application

local M = {}

local config = require("ailite.config")
local state = require("ailite.state")
local utils = require("ailite.utils")
local ui = require("ailite.ui")

-- Apply code to file
function M.apply_code_to_file(code, target_buf)
	if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
		utils.notify("Invalid buffer", vim.log.levels.ERROR)
		return
	end

	-- Ask user how to apply the code
	local choices = {
		"", -- Empty first element for prompt
		"1. Replace entire file",
		"2. Insert at cursor",
		"3. Append to end",
		"4. Cancel",
	}
	local choice = vim.fn.inputlist(choices)

	if choice == 1 then
		-- Replace entire file content
		local lines = utils.split_lines(code)
		vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
		utils.notify("✅ File completely replaced", vim.log.levels.INFO)

		-- Offer to save the file
		local save = vim.fn.confirm("Save the file now?", "&Yes\n&No", 1)
		if save == 1 then
			local current_buf = vim.api.nvim_get_current_buf()
			vim.api.nvim_set_current_buf(target_buf)
			vim.cmd("write")
			vim.api.nvim_set_current_buf(current_buf)
			utils.notify("💾 File saved", vim.log.levels.INFO)
		end
	elseif choice == 2 then
		-- Insert at cursor
		local win = vim.fn.bufwinid(target_buf)
		if win ~= -1 then
			local cursor = vim.api.nvim_win_get_cursor(win)
			local lines = utils.split_lines(code)
			vim.api.nvim_buf_set_lines(target_buf, cursor[1] - 1, cursor[1] - 1, false, lines)
			utils.notify("✅ Code inserted at cursor", vim.log.levels.INFO)
		else
			utils.notify("Buffer window not found", vim.log.levels.ERROR)
		end
	elseif choice == 3 then
		-- Append to end
		local lines = utils.split_lines(code)
		vim.api.nvim_buf_set_lines(target_buf, -1, -1, false, lines)
		utils.notify("✅ Code appended to end of file", vim.log.levels.INFO)
	end
end

-- Show code preview window
function M.show_code_preview(block_index)
	local blocks = state.plugin.code_blocks

	if not blocks or #blocks == 0 then
		utils.notify("No code blocks available", vim.log.levels.WARN)
		return
	end

	local block = blocks[block_index]
	if not block then
		return
	end

	-- Create preview buffer if it doesn't exist
	if not state.is_code_preview_valid() then
		state.plugin.code_preview_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_option(state.plugin.code_preview_buf, "bufhidden", "hide")
	end

	-- Update buffer content
	local lines = utils.split_lines(block.code)
	vim.api.nvim_buf_set_lines(state.plugin.code_preview_buf, 0, -1, false, lines)

	-- Set filetype based on language
	if block.language and block.language ~= "" then
		vim.api.nvim_buf_set_option(state.plugin.code_preview_buf, "filetype", block.language)
	end

	-- Create window if it doesn't exist
	if not state.is_code_preview_win_valid() then
		state.plugin.code_preview_win =
			ui.create_code_preview_window(state.plugin.code_preview_buf, block_index, #blocks, block.language)
		M.setup_code_preview_keymaps()
	else
		-- Update window title
		ui.update_code_preview_title(state.plugin.code_preview_win, block_index, #blocks, block.language)
		-- Ensure focus is on preview window
		vim.api.nvim_set_current_win(state.plugin.code_preview_win)
	end
end

-- Setup keymaps for code preview
function M.setup_code_preview_keymaps()
	local cfg = config.get()
	local opts = { noremap = true, silent = true, buffer = state.plugin.code_preview_buf }

	-- Apply code
	vim.keymap.set("n", cfg.keymaps.apply_code, function()
		local current_block = state.get_current_code_block()
		if current_block and state.plugin.original_buf and vim.api.nvim_buf_is_valid(state.plugin.original_buf) then
			M.apply_code_to_file(current_block.code, state.plugin.original_buf)
			vim.api.nvim_win_close(state.plugin.code_preview_win, true)
			state.plugin.code_preview_win = nil
		else
			utils.notify("Original buffer not found", vim.log.levels.ERROR)
		end
	end, opts)

	-- Copy code
	vim.keymap.set("n", cfg.keymaps.copy_code, function()
		local current_block = state.get_current_code_block()
		if current_block then
			vim.fn.setreg("+", current_block.code)
			utils.notify("Code copied to clipboard", vim.log.levels.INFO)
		end
	end, opts)

	-- Navigate blocks
	vim.keymap.set("n", cfg.keymaps.next_code_block, function()
		M.next_code_block()
	end, opts)

	vim.keymap.set("n", cfg.keymaps.prev_code_block, function()
		M.prev_code_block()
	end, opts)

	-- Close preview
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(state.plugin.code_preview_win, true)
		state.plugin.code_preview_win = nil
	end, opts)

	vim.keymap.set("n", "<Esc>", function()
		vim.api.nvim_win_close(state.plugin.code_preview_win, true)
		state.plugin.code_preview_win = nil
	end, opts)
end

-- Navigate to next code block
function M.next_code_block()
	local index = state.next_code_block()
	if index then
		M.show_code_preview(index)
	else
		utils.notify("No code blocks available", vim.log.levels.WARN)
	end
end

-- Navigate to previous code block
function M.prev_code_block()
	local index = state.prev_code_block()
	if index then
		M.show_code_preview(index)
	else
		utils.notify("No code blocks available", vim.log.levels.WARN)
	end
end

-- Replace entire file with code
function M.replace_file_with_last_code()
	local blocks = state.plugin.code_blocks

	if #blocks == 0 then
		utils.notify("❌ No code blocks available", vim.log.levels.ERROR)
		return
	end

	if not state.plugin.original_buf or not vim.api.nvim_buf_is_valid(state.plugin.original_buf) then
		utils.notify("❌ Original buffer not found", vim.log.levels.ERROR)
		return
	end

	-- Get code from current or first block
	local block = state.get_current_code_block() or blocks[1]
	local code = block.code

	-- Confirm replacement
	local filename = utils.get_file_name(vim.api.nvim_buf_get_name(state.plugin.original_buf))
	local confirm =
		utils.confirm(string.format("⚠️  Replace ALL content of '%s'?", filename), "&Yes\n&No\n&View preview", 2)

	if confirm == 1 then
		-- Replace file
		local lines = utils.split_lines(code)
		-- Clear the buffer and set new content in one operation
		vim.api.nvim_buf_set_lines(state.plugin.original_buf, 0, -1, false, lines)

		utils.notify("✅ File replaced completely", vim.log.levels.INFO)

		-- Offer to save
		local save = utils.confirm("💾 Save file now?", "&Yes\n&No", 1)
		if save == 1 then
			local current_buf = vim.api.nvim_get_current_buf()
			vim.api.nvim_set_current_buf(state.plugin.original_buf)
			vim.cmd("write")
			vim.api.nvim_set_current_buf(current_buf)
			utils.notify("💾 File saved", vim.log.levels.INFO)
		end
	elseif confirm == 3 then
		-- Show preview
		M.show_code_preview(state.plugin.current_code_block or 1)
	end
end

-- Apply code with diff preview
function M.apply_code_with_diff()
	local blocks = state.plugin.code_blocks

	if #blocks == 0 then
		utils.notify("❌ No code blocks available", vim.log.levels.ERROR)
		return
	end

	if not state.plugin.original_buf or not vim.api.nvim_buf_is_valid(state.plugin.original_buf) then
		utils.notify("❌ Original buffer not found", vim.log.levels.ERROR)
		return
	end

	-- Create temporary buffer for diff
	local diff_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(diff_buf, "filetype", "diff")

	local block = state.get_current_code_block() or blocks[1]

	-- Get current content
	local current_lines = vim.api.nvim_buf_get_lines(state.plugin.original_buf, 0, -1, false)
	local new_lines = utils.split_lines(block.code)

	-- Use vim.diff for professional diff output
	local current_content = table.concat(current_lines, "\n")
	local new_content = table.concat(new_lines, "\n")

	local diff_output = vim.diff(current_content, new_content, {
		algorithm = "histogram",
		ctxlen = 3,
		interhunkctxlen = 0,
		linematch = true,
	})

	-- Parse and format the diff
	local diff_lines = {}
	local highlights = {} -- Store highlight information

	-- Add header
	table.insert(
		diff_lines,
		"╭─────────────────────────────────────────────────────────╮"
	)
	table.insert(diff_lines, "│                    DIFF PREVIEW                         │")
	table.insert(
		diff_lines,
		"╰─────────────────────────────────────────────────────────╯"
	)
	table.insert(diff_lines, "")

	local filename = utils.get_file_name(vim.api.nvim_buf_get_name(state.plugin.original_buf))
	table.insert(diff_lines, "File: " .. filename)
	table.insert(diff_lines, string.format("@@ %d lines → %d lines @@", #current_lines, #new_lines))
	table.insert(diff_lines, "")

	-- Process diff output line by line
	local line_num = #diff_lines + 1
	for line in diff_output:gmatch("[^\r\n]+") do
		if line:match("^@@") then
			-- Hunk header
			table.insert(diff_lines, line)
			table.insert(highlights, { line = line_num, type = "hunk" })
		elseif line:match("^%-") then
			-- Deletion
			table.insert(diff_lines, line)
			table.insert(highlights, { line = line_num, type = "delete" })
		elseif line:match("^%+") then
			-- Addition
			table.insert(diff_lines, line)
			table.insert(highlights, { line = line_num, type = "add" })
		else
			-- Context or other
			table.insert(diff_lines, line)
		end
		line_num = line_num + 1
	end

	-- Add footer with instructions
	table.insert(diff_lines, "")
	table.insert(
		diff_lines,
		"─────────────────────────────────────────────────────────"
	)
	table.insert(diff_lines, "         Press 'y' to apply, 'n' to cancel              ")
	table.insert(
		diff_lines,
		"─────────────────────────────────────────────────────────"
	)

	vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, diff_lines)

	-- Show in floating window
	local diff_win = ui.create_diff_window(diff_buf)

	-- Apply syntax highlighting
	local ns_id = vim.api.nvim_create_namespace("ailite_diff")
	for _, hl in ipairs(highlights) do
		if hl.type == "delete" then
			vim.api.nvim_buf_add_highlight(diff_buf, ns_id, "DiffDelete", hl.line - 1, 0, -1)
		elseif hl.type == "add" then
			vim.api.nvim_buf_add_highlight(diff_buf, ns_id, "DiffAdd", hl.line - 1, 0, -1)
		elseif hl.type == "hunk" then
			vim.api.nvim_buf_add_highlight(diff_buf, ns_id, "DiffChange", hl.line - 1, 0, -1)
		end
	end

	-- Make buffer non-modifiable
	vim.api.nvim_buf_set_option(diff_buf, "modifiable", false)

	-- Keymaps for diff
	local opts = { noremap = true, silent = true, buffer = diff_buf }

	-- Confirm replacement
	vim.keymap.set("n", "y", function()
		vim.api.nvim_win_close(diff_win, true)
		vim.api.nvim_buf_set_lines(state.plugin.original_buf, 0, -1, false, new_lines)
		utils.notify("✅ Changes applied successfully", vim.log.levels.INFO)
	end, opts)

	-- Cancel
	vim.keymap.set("n", "n", function()
		vim.api.nvim_win_close(diff_win, true)
		utils.notify("❌ Changes cancelled", vim.log.levels.INFO)
	end, opts)

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(diff_win, true)
	end, opts)

	vim.keymap.set("n", "<Esc>", function()
		vim.api.nvim_win_close(diff_win, true)
	end, opts)
end

return M
