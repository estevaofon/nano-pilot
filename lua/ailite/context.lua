-- ailite/context.lua
-- Context management and streaming strategies

local M = {}

local config = require("ailite.config")
local state = require("ailite.state")
local utils = require("ailite.utils")
local api = require("ailite.api")
local files = require("ailite.files")

-- Build streaming part message
local function build_part_message(part, part_num, total_parts)
	local cfg = config.get()
	local part_content = {}

	-- Build part content
	if part_num == 1 then
		-- First part: include instructions and summary
		table.insert(part_content, "I'll provide you with code context in multiple parts.")
		table.insert(part_content, "Please read each part and simply respond 'Acknowledged' after each one.")
		table.insert(part_content, "After all parts are sent, I'll ask my actual question.")
		table.insert(part_content, "")

		if cfg.context.include_context_summary and state.streaming.context_summary then
			table.insert(part_content, state.streaming.context_summary)
			table.insert(part_content, "")
		end
	end

	table.insert(part_content, string.format("=== PART %d/%d ===", part_num, total_parts))
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
		table.insert(part_content, "```" .. utils.get_file_extension(file_data.path))
		table.insert(part_content, file_data.content)
		table.insert(part_content, "```")
		table.insert(part_content, "")
	end

	-- Add explicit instruction at end
	if part_num < total_parts then
		table.insert(part_content, "Please acknowledge receipt of this part.")
	else
		table.insert(part_content, "Please acknowledge receipt of this final part.")
	end

	return table.concat(part_content, "\n")
end

-- Split context for streaming
function M.split_context_for_streaming(selected_files, prompt)
	local cfg = config.get()
	local parts = {}
	local current_part = {
		files = {},
		estimated_tokens = 0,
	}

	-- Use 70% of limit to be safe
	local max_tokens = cfg.context.max_tokens_per_message * 0.7

	-- First, estimate total size
	local total_tokens = utils.estimate_tokens(prompt)
	for _, filepath in ipairs(selected_files) do
		local content = utils.read_file(filepath)
		if content then
			total_tokens = total_tokens + utils.estimate_tokens(content)
		end
	end

	utils.notify(
		string.format("Debug: Total estimated tokens: %d (limit per message: %d)", total_tokens, max_tokens),
		vim.log.levels.INFO
	)

	-- If fits in one message, return nil
	if total_tokens <= max_tokens then
		utils.notify("Debug: Context fits in single message", vim.log.levels.INFO)
		return nil
	end

	utils.notify("Debug: Splitting context into multiple parts", vim.log.levels.INFO)

	-- Split files into parts
	for _, filepath in ipairs(selected_files) do
		local content = utils.read_file(filepath)
		if content then
			local file_tokens = utils.estimate_tokens(content)
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
				local lines = utils.split_lines(content)
				local chunk_lines = {}
				local chunk_tokens = 0
				local chunk_start = 1

				for i, line in ipairs(lines) do
					local line_tokens = utils.estimate_tokens(line)

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

-- Send final streaming question
function M.send_final_streaming_question(original_prompt, callback)
	local final_message = string.format(
		"Now that you have all the context (%d parts), please answer my question:\n\n%s",
		state.streaming.total_parts,
		original_prompt
	)

	callback("final_processing", {})

	local messages = {}

	-- Add history for context
	for _, msg in ipairs(state.plugin.chat_history) do
		table.insert(messages, msg)
	end

	-- Add final question
	table.insert(messages, {
		role = "user",
		content = final_message,
	})

	api.call_api_async(messages, { animation_buf = state.plugin.chat_buf }, function(response)
		if response then
			callback("complete", { response = response })
		else
			callback("error", { message = "Failed to get final response" })
		end

		-- Reset streaming state
		state.reset_streaming()
		state.plugin.is_processing = false
	end)
end

-- Process streaming parts
function M.process_streaming_parts(parts, original_prompt, callback)
	state.streaming.current_part = state.streaming.current_part + 1

	if state.streaming.current_part > #parts then
		-- All parts sent, send final question
		M.send_final_streaming_question(original_prompt, callback)
		return
	end

	local part = parts[state.streaming.current_part]
	local part_message = build_part_message(part, state.streaming.current_part, #parts)

	-- Show progress
	callback("progress", {
		current = state.streaming.current_part,
		total = #parts,
		message = part_message,
	})

	-- Send part asynchronously
	local messages = {}

	-- Add history for context continuity
	for _, msg in ipairs(state.plugin.chat_history) do
		table.insert(messages, msg)
	end

	-- Add current part
	table.insert(messages, {
		role = "user",
		content = part_message,
	})

	api.call_api_async(messages, {}, function(response)
		if response then
			-- Add to history for context continuity
			state.add_to_history("assistant", response)

			callback("part_complete", {
				current = state.streaming.current_part,
				total = #parts,
				response = response,
			})

			-- Continue with next part after a delay
			vim.defer_fn(function()
				M.process_streaming_parts(parts, original_prompt, callback)
			end, 1000)
		else
			-- Error handling
			callback("error", {
				current = state.streaming.current_part,
				total = #parts,
			})

			-- Reset streaming state on error
			state.reset_streaming()
			state.plugin.is_processing = false
		end
	end)
end

-- Send context in single message
function M.send_context_single(prompt, selected_files, callback)
	local context = ""

	if #selected_files > 0 then
		context = "Context - Project files:\n\n" .. files.get_selected_files_content() .. "\n\n"
	end

	-- Build messages with history
	local messages = {}
	local cfg = config.get()

	-- Add history
	local history_limit = cfg.history_limit or 20
	local history_start = math.max(1, #state.plugin.chat_history - history_limit + 1)

	for i = history_start, #state.plugin.chat_history do
		table.insert(messages, state.plugin.chat_history[i])
	end

	-- Add current message
	table.insert(messages, {
		role = "user",
		content = context .. prompt,
	})

	-- Make async API call with animation
	api.call_api_async(messages, { animation_buf = state.plugin.chat_buf }, function(response)
		if response then
			callback("complete", { response = response })
		else
			callback("error", { message = "Failed to get response" })
		end
	end)
end

-- Send context in streaming mode
function M.send_context_streaming(prompt, selected_files, callback)
	local cfg = config.get()
	local parts = M.split_context_for_streaming(selected_files, prompt)

	-- If nil, context fits in one message
	if not parts then
		return M.send_context_single(prompt, selected_files, callback)
	end

	state.streaming.is_streaming = true
	state.streaming.total_parts = #parts
	state.streaming.current_part = 0

	-- Create context summary
	if cfg.context.include_context_summary then
		state.streaming.context_summary = files.create_context_summary()
	end

	-- Add to history the initial message
	state.add_to_history("user", prompt)

	-- Start processing parts
	M.process_streaming_parts(parts, prompt, callback)
end

-- Estimate context size
function M.estimate_context()
	if #state.plugin.selected_files == 0 then
		utils.notify("No files selected", vim.log.levels.WARN)
		return
	end

	local cfg = config.get()
	local total_tokens = 0
	local file_details = {}

	for _, filepath in ipairs(state.plugin.selected_files) do
		local content = utils.read_file(filepath)
		if content then
			local tokens = utils.estimate_tokens(content)
			total_tokens = total_tokens + tokens

			table.insert(file_details, string.format("%s: ~%d tokens", utils.get_file_name(filepath), tokens))
		end
	end

	local max_per_message = cfg.context.max_tokens_per_message
	local strategy = cfg.context.strategy

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

	utils.notify(table.concat(info, "\n"), vim.log.levels.INFO)
end

return M
