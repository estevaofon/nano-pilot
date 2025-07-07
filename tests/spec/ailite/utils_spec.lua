local helper = require("spec.test_helper")

describe("ailite.utils", function()
	local utils

	before_each(function()
		-- Clear any cached modules
		package.loaded["ailite.utils"] = nil
		utils = require("ailite.utils")
	end)

	describe("normalize_path", function()
		it("should convert backslashes to forward slashes", function()
			local path = utils.normalize_path("C:\\Users\\test\\file.lua")
			assert.truthy(path:match("/"))
			assert.falsy(path:match("\\"))
		end)

		it("should return nil for nil input", function()
			assert.is_nil(utils.normalize_path(nil))
		end)

		it("should handle already normalized paths", function()
			local path = "/home/user/file.lua"
			assert.equals(path, utils.normalize_path(path))
		end)
	end)

	describe("split_lines", function()
		it("should split text by newlines", function()
			local text = "line1\nline2\nline3"
			local lines = utils.split_lines(text)
			assert.equals(3, #lines)
			assert.equals("line1", lines[1])
			assert.equals("line2", lines[2])
			assert.equals("line3", lines[3])
		end)

		it("should handle CRLF line endings", function()
			local text = "line1\r\nline2\r\nline3"
			local lines = utils.split_lines(text)
			assert.equals(3, #lines)
			assert.equals("line1", lines[1])
		end)

		it("should handle empty lines", function()
			local text = "line1\n\nline3"
			local lines = utils.split_lines(text)
			assert.equals(3, #lines)
			assert.equals("", lines[2])
		end)
	end)

	describe("extract_code_blocks", function()
		it("should extract single code block", function()
			-- Usando concatenação para evitar problemas com escape
			local content = "Some text\n" .. "```lua\nlocal x = 1\n```" .. "\nMore text"
			local blocks = utils.extract_code_blocks(content)
			assert.equals(1, #blocks)
			assert.equals("lua", blocks[1].language)
			assert.equals("local x = 1", blocks[1].code)
		end)

		it("should extract multiple code blocks", function()
			local content = "```python\ndef hello():\n    pass\n```\n\n```javascript\nconst x = 1;\n```"
			local blocks = utils.extract_code_blocks(content)
			assert.equals(2, #blocks)
			assert.equals("python", blocks[1].language)
			assert.equals("javascript", blocks[2].language)
		end)

		it("should handle code blocks without language", function()
			local content = "```\nplain text\n```"
			local blocks = utils.extract_code_blocks(content)
			assert.equals(1, #blocks)
			assert.equals("text", blocks[1].language)
		end)
	end)

	describe("estimate_tokens", function()
		it("should estimate tokens based on character count", function()
			local text = "This is a test string"
			local tokens = utils.estimate_tokens(text)
			assert.is_true(tokens > 0)
		end)

		it("should add margin for code", function()
			local plain_text = string.rep("a", 100)
			local code_text = "```\n" .. string.rep("a", 100) .. "\n```"
			local plain_tokens = utils.estimate_tokens(plain_text)
			local code_tokens = utils.estimate_tokens(code_text)
			assert.is_true(code_tokens > plain_tokens)
		end)
	end)

	describe("trim", function()
		it("should remove leading and trailing whitespace", function()
			assert.equals("test", utils.trim("  test  "))
			assert.equals("test", utils.trim("\t\ntest\r\n"))
			assert.equals("test string", utils.trim("  test string  "))
		end)

		it("should handle empty strings", function()
			assert.equals("", utils.trim(""))
			assert.equals("", utils.trim("   "))
		end)
	end)

	describe("file operations", function()
		before_each(function()
			helper.setup_fs_mock()
		end)

		after_each(function()
			helper.teardown_fs_mock()
		end)

		it("should read file content", function()
			helper.mock_fs.set_file("/test/file.lua", "local x = 1")
			local content = utils.read_file("/test/file.lua")
			assert.equals("local x = 1", content)
		end)

		it("should return nil for non-existent file", function()
			local content = utils.read_file("/non/existent.lua")
			assert.is_nil(content)
		end)

		it("should create temporary file", function()
			local content = "test content"
			local tmpfile = utils.create_temp_file(content)
			assert.is_string(tmpfile)
			assert.equals(content, helper.mock_fs.files[tmpfile])
		end)
	end)
end)
