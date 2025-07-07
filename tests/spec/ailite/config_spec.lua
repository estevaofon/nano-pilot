require("spec.test_helper")

describe("ailite.config", function()
	local config

	before_each(function()
		package.loaded["ailite.config"] = nil
		config = require("ailite.config")
		vim.env.ANTHROPIC_API_KEY = nil
		vim.env.CLAUDE_API_KEY = nil
	end)

	describe("setup", function()
		it("should use default values when no opts provided", function()
			local cfg = config.setup()
			assert.equals("claude-3-5-sonnet-20241022", cfg.model)
			assert.equals(4096, cfg.max_tokens)
			assert.equals(0.7, cfg.temperature)
			assert.equals(">>> ", cfg.chat_input_prefix)
		end)

		it("should override defaults with provided options", function()
			local cfg = config.setup({
				api_key = "test-key",
				model = "claude-2.1",
				max_tokens = 8192,
				assistant_name = "TestBot",
			})
			assert.equals("test-key", cfg.api_key)
			assert.equals("claude-2.1", cfg.model)
			assert.equals(8192, cfg.max_tokens)
			assert.equals("TestBot", cfg.assistant_name)
		end)

		it("should get API key from environment", function()
			vim.env.ANTHROPIC_API_KEY = "env-key"
			local cfg = config.setup()
			assert.equals("env-key", cfg.api_key)
		end)

		it("should prefer ANTHROPIC_API_KEY over CLAUDE_API_KEY", function()
			vim.env.ANTHROPIC_API_KEY = "anthropic-key"
			vim.env.CLAUDE_API_KEY = "claude-key"
			local cfg = config.setup()
			assert.equals("anthropic-key", cfg.api_key)
		end)
	end)

	describe("API key management", function()
		it("should set API key", function()
			config.setup()
			config.set_api_key("new-key")
			assert.equals("new-key", config.get().api_key)
		end)
	end)

	describe("strategy management", function()
		it("should set valid strategies", function()
			config.setup()
			assert.is_true(config.set_strategy("single"))
			assert.equals("single", config.get().context.strategy)

			assert.is_true(config.set_strategy("streaming"))
			assert.equals("streaming", config.get().context.strategy)

			assert.is_true(config.set_strategy("auto"))
			assert.equals("auto", config.get().context.strategy)
		end)

		it("should reject invalid strategies", function()
			config.setup()
			assert.is_false(config.set_strategy("invalid"))
			assert.not_equals("invalid", config.get().context.strategy)
		end)
	end)

	describe("model validation", function()
		it("should validate known models", function()
			config.setup({ model = "claude-3-opus-20240229" })
			assert.is_true(config.validate_model())

			config.setup({ model = "claude-3-5-sonnet-20241022" })
			assert.is_true(config.validate_model())
		end)

		it("should warn for unknown models", function()
			config.setup({ model = "unknown-model" })
			assert.is_false(config.validate_model())
		end)
	end)

	describe("deep configuration", function()
		it("should properly merge nested configurations", function()
			local cfg = config.setup({
				chat_window = {
					width = 100,
					-- height not specified, should use default
				},
				keymaps = {
					send_message = "<CR>",
					-- others should remain default
				},
			})

			assert.equals(100, cfg.chat_window.width)
			assert.equals(35, cfg.chat_window.height) -- default
			assert.equals("rounded", cfg.chat_window.border) -- default

			assert.equals("<CR>", cfg.keymaps.send_message)
			assert.equals("<C-a>", cfg.keymaps.apply_code) -- default
		end)
	end)
end)
