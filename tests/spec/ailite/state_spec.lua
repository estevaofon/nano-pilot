require("spec.test_helper")

describe("ailite.state", function()
	local state

	before_each(function()
		package.loaded["ailite.state"] = nil
		package.loaded["ailite.utils"] = nil
		state = require("ailite.state")
	end)

	describe("file management", function()
		before_each(function()
			state.clear_files()
		end)

		it("should add files with normalization", function()
			assert.is_true(state.add_file("/test/file1.lua"))
			assert.equals(1, #state.plugin.selected_files)
		end)

		it("should not add duplicate files", function()
			state.add_file("/test/file1.lua")
			assert.is_false(state.add_file("/test/file1.lua"))
			assert.equals(1, #state.plugin.selected_files)
		end)

		it("should remove files", function()
			state.add_file("/test/file1.lua")
			state.add_file("/test/file2.lua")
			assert.is_true(state.remove_file("/test/file1.lua"))
			assert.equals(1, #state.plugin.selected_files)
			assert.equals("/test/file2.lua", state.plugin.selected_files[1])
		end)

		it("should clear all files", function()
			state.add_file("/test/file1.lua")
			state.add_file("/test/file2.lua")
			state.clear_files()
			assert.equals(0, #state.plugin.selected_files)
		end)
	end)

	describe("chat history", function()
		before_each(function()
			state.clear_history()
		end)

		it("should add messages to history", function()
			state.add_to_history("user", "Hello")
			state.add_to_history("assistant", "Hi there!")
			assert.equals(2, #state.plugin.chat_history)
			assert.equals("user", state.plugin.chat_history[1].role)
			assert.equals("Hello", state.plugin.chat_history[1].content)
		end)

		it("should clear history", function()
			state.add_to_history("user", "Test")
			state.clear_history()
			assert.equals(0, #state.plugin.chat_history)
		end)
	end)

	describe("code blocks", function()
		it("should set and navigate code blocks", function()
			local blocks = {
				{ language = "lua", code = "print(1)" },
				{ language = "python", code = "print(2)" },
				{ language = "javascript", code = "console.log(3)" },
			}

			state.set_code_blocks(blocks)
			assert.equals(3, #state.plugin.code_blocks)
			assert.equals(1, state.plugin.current_code_block)

			-- Test next navigation
			assert.equals(2, state.next_code_block())
			assert.equals(3, state.next_code_block())
			assert.equals(1, state.next_code_block()) -- wrap around

			-- Test previous navigation
			assert.equals(3, state.prev_code_block()) -- wrap around
			assert.equals(2, state.prev_code_block())
			assert.equals(1, state.prev_code_block())
		end)

		it("should handle empty code blocks", function()
			state.set_code_blocks({})
			assert.is_nil(state.next_code_block())
			assert.is_nil(state.prev_code_block())
			assert.is_nil(state.get_current_code_block())
		end)

		it("should get current code block", function()
			local blocks = { { language = "lua", code = "test" } }
			state.set_code_blocks(blocks)
			local current = state.get_current_code_block()
			assert.equals("lua", current.language)
			assert.equals("test", current.code)
		end)
	end)

	describe("input mode", function()
		it("should manage input mode state", function()
			assert.is_false(state.plugin.is_in_input_mode)

			state.start_input_mode(10)
			assert.is_true(state.plugin.is_in_input_mode)
			assert.equals(10, state.plugin.input_start_line)

			state.end_input_mode()
			assert.is_false(state.plugin.is_in_input_mode)
			assert.is_nil(state.plugin.input_start_line)
		end)
	end)

	describe("streaming state", function()
		it("should reset streaming state", function()
			state.streaming.is_streaming = true
			state.streaming.total_parts = 5
			state.streaming.current_part = 3

			state.reset_streaming()

			assert.is_false(state.streaming.is_streaming)
			assert.equals(0, state.streaming.total_parts)
			assert.equals(0, state.streaming.current_part)
			assert.is_nil(state.streaming.context_summary)
		end)
	end)

	describe("validation helpers", function()
		it("should validate buffers and windows", function()
			state.plugin.chat_buf = 1
			state.plugin.chat_win = 1

			assert.is_true(state.is_chat_valid())
			assert.is_true(state.is_chat_win_valid())

			state.plugin.chat_buf = nil
			assert.is_nil(state.is_chat_valid())
		end)
	end)
end)
