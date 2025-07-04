-- ailite/files.lua
-- File selection and management

local M = {}

local state = require("ailite.state")
local utils = require("ailite.utils")

-- Toggle file in selection
function M.toggle_file(filepath)
	-- Normalize the path
	filepath = utils.normalize_path(filepath)
	if not filepath then
		utils.notify("Invalid file path", vim.log.levels.ERROR)
		return
	end

	local removed = state.remove_file(filepath)

	if removed then
		utils.notify("📄 File removed: " .. utils.get_relative_path(filepath))
	else
		state.add_file(filepath)
		utils.notify("📄 File added: " .. utils.get_relative_path(filepath))
	end
end

-- Toggle current file
function M.toggle_current_file()
	local current_file = vim.fn.expand("%:p")
	if current_file ~= "" then
		M.toggle_file(current_file)
	else
		utils.notify("No file open", vim.log.levels.WARN)
	end
end

-- Select files using telescope or input
function M.select_files()
	-- Use telescope if available
	local ok, telescope = pcall(require, "telescope.builtin")
	if ok then
		M.select_files_telescope(telescope)
	else
		M.select_files_fallback()
	end
end

-- Select files using telescope
function M.select_files_telescope(telescope)
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
					local filepath = utils.normalize_path(selection.path or selection.filename)
					if filepath and state.remove_file(filepath) then
						utils.notify("File removed: " .. utils.get_relative_path(filepath))
					end
				end
			end)

			-- Add multiple
			map("i", "<C-a>", function()
				local picker = action_state.get_current_picker(prompt_bufnr)
				local multi_selections = picker:get_multi_selection()

				local added = 0
				for _, selection in ipairs(multi_selections) do
					local filepath = utils.normalize_path(selection.path or selection.filename)
					if filepath and state.add_file(filepath) then
						added = added + 1
					end
				end

				actions.close(prompt_bufnr)
				utils.notify(added .. " files added")
			end)

			return true
		end,
		prompt_title = "Select Files (Enter=toggle, C-x=remove, C-a=multiple)",
	})
end

-- Fallback file selection
function M.select_files_fallback()
	local filepath = utils.input("File path: ", vim.fn.expand("%:p:h") .. "/", "file")
	if filepath ~= "" and vim.fn.filereadable(filepath) == 1 then
		M.toggle_file(filepath)
	end
end

-- List selected files
function M.list_selected_files()
	local files = state.plugin.selected_files

	if #files == 0 then
		utils.notify("No files selected", vim.log.levels.INFO)
		return
	end

	local file_list = {}
	for i, file in ipairs(files) do
		-- Use relative path for display
		table.insert(file_list, string.format("%d. %s", i, utils.get_relative_path(file)))
	end

	utils.notify("📁 Selected files:\n" .. table.concat(file_list, "\n"), vim.log.levels.INFO)
end

-- Clear selected files
function M.clear_selected_files()
	state.clear_files()
	utils.notify("✨ File selection cleared")
end

-- Get selected files content formatted
function M.get_selected_files_content()
	local content = {}

	for _, filepath in ipairs(state.plugin.selected_files) do
		local file_content = utils.read_file(filepath)
		if file_content then
			local extension = utils.get_file_extension(filepath)
			-- Use relative path for display
			local display_path = utils.get_relative_path(filepath)
			table.insert(content, string.format("### File: %s\n```%s\n%s\n```", display_path, extension, file_content))
		end
	end

	return table.concat(content, "\n\n")
end

-- Create file summary for a single file
function M.create_file_summary(filepath)
	local content = utils.read_file(filepath)
	if not content then
		return nil
	end

	local lines = utils.split_lines(content)
	local summary = {
		name = utils.get_file_name(filepath),
		path = utils.get_relative_path(filepath),
		lines = #lines,
		size = #content,
		extension = utils.get_file_extension(filepath),
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

	summary.functions = functions
	summary.classes = classes

	return summary
end

-- Create context summary
function M.create_context_summary()
	local summary_parts = {}
	local total_lines = 0
	local total_size = 0
	local file_summaries = {}

	for _, filepath in ipairs(state.plugin.selected_files) do
		local summary = M.create_file_summary(filepath)
		if summary then
			total_lines = total_lines + summary.lines
			total_size = total_size + summary.size
			table.insert(file_summaries, summary)
		end
	end

	table.insert(summary_parts, "=== CONTEXT SUMMARY ===")
	table.insert(summary_parts, string.format("Total files: %d", #state.plugin.selected_files))
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

return M
