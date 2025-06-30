-- ailite/utils.lua
-- Utility functions

local M = {}

-- Namespace for highlights
M.ns_id = vim.api.nvim_create_namespace("ailite")

-- Get visual selection
function M.get_visual_selection()
	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")
	local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)

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
function M.extract_code_blocks(content)
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
function M.estimate_tokens(text)
	local config = require("ailite.config").get()
	local base_estimate = math.ceil(#text / config.context.token_estimation_ratio)

	-- Add 10% margin for code
	if text:match("```") or text:match("function") or text:match("class") then
		base_estimate = math.ceil(base_estimate * 1.1)
	end

	return base_estimate
end

-- Read file content
function M.read_file(filepath)
	local file = io.open(filepath, "r")
	if file then
		local content = file:read("*all")
		file:close()
		return content
	end
	return nil
end

-- Create temporary file
function M.create_temp_file(content)
	local tmpfile = vim.fn.tempname()
	local f = io.open(tmpfile, "w")
	if f then
		f:write(content)
		f:close()
		return tmpfile
	end
	return nil
end

-- Setup highlight groups
function M.setup_highlights()
	vim.api.nvim_set_hl(0, "AiliteUser", { fg = "#61afef", bold = true })
	vim.api.nvim_set_hl(0, "AiliteAssistant", { fg = "#98c379", bold = true })
	vim.api.nvim_set_hl(0, "AilitePrompt", { fg = "#c678dd", bold = true })
end

-- Get file extension
function M.get_file_extension(filepath)
	return vim.fn.fnamemodify(filepath, ":e")
end

-- Get file name
function M.get_file_name(filepath)
	return vim.fn.fnamemodify(filepath, ":t")
end

-- Get relative path
function M.get_relative_path(filepath)
	return vim.fn.fnamemodify(filepath, ":~:.")
end

-- Split text into lines
function M.split_lines(text)
	-- Handle different line endings properly
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	return vim.split(text, "\n", { plain = true })
end

-- Join lines
function M.join_lines(lines)
	return table.concat(lines, "\n")
end

-- Trim whitespace
function M.trim(str)
	return str:gsub("^%s+", ""):gsub("%s+$", "")
end

-- Format timestamp
function M.get_timestamp()
	return os.date("%H:%M:%S")
end

-- Show notification with formatted message
function M.notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO)
end

-- Confirm action
function M.confirm(message, choices, default)
	return vim.fn.confirm(message, choices, default)
end

-- Get user input
function M.input(prompt, default, completion)
	return vim.fn.input(prompt, default or "", completion)
end

return M
