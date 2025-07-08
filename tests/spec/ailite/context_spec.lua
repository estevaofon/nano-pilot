local helper = require("spec.test_helper")

describe("ailite.context", function()
	local context
	local mock_config
	local mock_utils
	local mock_state

	before_each(function()
		helper.setup_fs_mock()
		
		-- Clear any cached modules
		package.loaded["ailite.context"] = nil
		package.loaded["ailite.config"] = nil
		package.loaded["ailite.utils"] = nil
		package.loaded["ailite.state"] = nil
		
		-- Mock config
		mock_config = {
			get = function()
				return {
					context = {
						max_tokens_per_message = 1000,
						include_context_summary = true,
						strategy = "auto"
					},
					history_limit = 20
				}
			end
		}
		package.loaded["ailite.config"] = mock_config
		
		-- Mock utils
		mock_utils = {
			estimate_tokens = function(text)
				return math.floor(#text / 4) -- Simple estimation: 4 chars per token
			end,
			read_file = function(path)
				return helper.mock_fs.read_file(path)
			end,
			split_lines = function(text)
				return vim.split(text, "\n")
			end,
			get_file_extension = function(path)
				return path:match("%.([^.]+)$") or ""
			end,
			get_file_name = function(path)
				return path:match("([^/\\]+)$") or path
			end,
			notify = function() end
		}
		package.loaded["ailite.utils"] = mock_utils
		
		-- Mock state
		mock_state = {
			plugin = {
				selected_files = {},
				chat_history = {},
				chat_buf = 1,
				is_processing = false
			},
			streaming = {
				is_streaming = false,
				current_part = 0,
				total_parts = 0,
				context_summary = nil
			},
			add_to_history = function() end,
			reset_streaming = function() end
		}
		package.loaded["ailite.state"] = mock_state
		
		-- Mock other dependencies
		package.loaded["ailite.api"] = { call_api_async = function() end }
		package.loaded["ailite.files"] = { 
			get_selected_files_content = function() return "" end,
			create_context_summary = function() return "Summary" end
		}
		
		context = require("ailite.context")
	end)

	after_each(function()
		helper.teardown_fs_mock()
	end)

	describe("split_context_for_streaming", function()
		it("should return nil when context fits in single message", function()
			-- Create small files that fit in one message
			local selected_files = {"/test/small1.lua", "/test/small2.lua"}
			local prompt = "Test prompt"
			
			helper.mock_fs.set_file("/test/small1.lua", "local x = 1")
			helper.mock_fs.set_file("/test/small2.lua", "local y = 2")
			
			local parts = context.split_context_for_streaming(selected_files, prompt)
			
			assert.is_nil(parts)
		end)

		it("should split context into multiple parts when exceeding token limit", function()
			-- Create large files that exceed token limit
			local selected_files = {"/test/large1.lua", "/test/large2.lua"}
			local prompt = "Test prompt"
			
			-- Create content that will exceed the 70% of 1000 tokens limit (700 tokens)
			local large_content1 = string.rep("a", 1500) -- ~375 tokens
			local large_content2 = string.rep("b", 1500) -- ~375 tokens
			
			helper.mock_fs.set_file("/test/large1.lua", large_content1)
			helper.mock_fs.set_file("/test/large2.lua", large_content2)
			
			local parts = context.split_context_for_streaming(selected_files, prompt)
			
			assert.is_not_nil(parts)
			assert.is_true(#parts > 1)
			assert.equals(2, #parts) -- Should split into 2 parts
			
			-- Check that each part has the expected structure
			for _, part in ipairs(parts) do
				assert.is_not_nil(part.files)
				assert.is_not_nil(part.estimated_tokens)
				assert.is_true(#part.files > 0)
			end
		end)

		it("should handle single file larger than token limit by splitting lines", function()
			local selected_files = {"/test/huge.lua"}
			local prompt = "Test prompt"
			
			-- Create content with many lines that exceed token limit
			local lines = {}
			for i = 1, 100 do
				table.insert(lines, string.rep("line " .. i .. " ", 20)) -- ~100 chars per line
			end
			local huge_content = table.concat(lines, "\n")
			
			helper.mock_fs.set_file("/test/huge.lua", huge_content)
			
			local parts = context.split_context_for_streaming(selected_files, prompt)
			
			assert.is_not_nil(parts)
			assert.is_true(#parts > 1)
			
			-- Check that partial file information is included
			local found_partial = false
			for _, part in ipairs(parts) do
				for _, file_data in ipairs(part.files) do
					if file_data.partial then
						found_partial = true
						assert.is_not_nil(file_data.start_line)
						assert.is_not_nil(file_data.end_line)
						assert.is_not_nil(file_data.total_lines)
					end
				end
			end
			assert.is_true(found_partial)
		end)
	end)

	describe("estimate_context", function()
		it("should warn when no files are selected", function()
			local notify_called = false
			local notify_level = nil
			
			mock_utils.notify = function(msg, level)
				notify_called = true
				notify_level = level
			end
			
			mock_state.plugin.selected_files = {}
			
			context.estimate_context()
			
			assert.is_true(notify_called)
			assert.equals(vim.log.levels.WARN, notify_level)
		end)

		it("should provide detailed context estimation for selected files", function()
			local notifications = {}
			
			mock_utils.notify = function(msg, level)
				table.insert(notifications, {message = msg, level = level})
			end
			
			-- Set up selected files
			mock_state.plugin.selected_files = {"/test/file1.lua", "/test/file2.lua"}
			
			helper.mock_fs.set_file("/test/file1.lua", string.rep("a", 400)) -- ~100 tokens
			helper.mock_fs.set_file("/test/file2.lua", string.rep("b", 800)) -- ~200 tokens
			
			context.estimate_context()
			
			assert.is_true(#notifications > 0)
			
			-- Check that the estimation includes expected information
			local estimation_found = false
			for _, notification in ipairs(notifications) do
				local msg = notification.message
				if msg and msg:find("Context Estimation") then
					estimation_found = true
					assert.is_not_nil(msg:find("Total estimated tokens"))
					assert.is_not_nil(msg:find("file1.lua"))
					assert.is_not_nil(msg:find("file2.lua"))
					assert.is_not_nil(msg:find("Strategy"))
				end
			end
			assert.is_true(estimation_found)
		end)

		it("should determine strategy based on token count", function()
			local notifications = {}
			
			mock_utils.notify = function(msg, level)
				table.insert(notifications, {message = msg, level = level})
			end
			
			-- Test with small files (should use single strategy)
			mock_state.plugin.selected_files = {"/test/small.lua"}
			helper.mock_fs.set_file("/test/small.lua", "small content")
			
			context.estimate_context()
			
			local single_strategy_found = false
			for _, notification in ipairs(notifications) do
				local msg = notification.message
				if msg and msg:find("Strategy: single") then
					single_strategy_found = true
					break
				end
			end
			assert.is_true(single_strategy_found)
			
			-- Reset notifications and selected files
			notifications = {}
			mock_state.plugin.selected_files = {"/test/large.lua"}
			
			-- Test with large files (should use streaming strategy)
			helper.mock_fs.set_file("/test/large.lua", string.rep("a", 4100)) -- ~1025 tokens (exceeds 1000 limit)
			
			context.estimate_context()
			
			local streaming_strategy_found = false
			for _, notification in ipairs(notifications) do
				local msg = notification.message
				if msg and msg:find("Strategy: streaming") then
					streaming_strategy_found = true
					break
				end
			end
			assert.is_true(streaming_strategy_found)
		end)
	end)
end)