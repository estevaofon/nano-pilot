-- ailite/config.lua
-- Default configuration and validation

local M = {}

-- Default configuration
M.defaults = {
	api_key = nil,
	model = "claude-3-5-sonnet-20241022",
	max_tokens = 4096,
	temperature = 0.7,
	history_limit = 20,
	chat_window = {
		width = 90,
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
	assistant_name = "Claude", -- New configuration option
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

-- Valid model names
M.valid_models = {
	"claude-3-opus-20240229",
	"claude-3-sonnet-20240229",
	"claude-3-haiku-20240307",
	"claude-3-5-sonnet-20241022",
	"claude-2.1",
	"claude-2.0",
	"claude-instant-1.2",
}

-- Current configuration
M.current = vim.deepcopy(M.defaults)

-- Setup configuration
function M.setup(opts)
	M.current = vim.tbl_deep_extend("force", M.current, opts or {})

	-- Try to get API key from environment
	if not M.current.api_key then
		M.current.api_key = vim.env.ANTHROPIC_API_KEY or vim.env.CLAUDE_API_KEY
	end

	return M.current
end

-- Get current configuration
function M.get()
	return M.current
end

-- Set API key
function M.set_api_key(key)
	M.current.api_key = key
end

-- Set context strategy
function M.set_strategy(strategy)
	if strategy ~= "single" and strategy ~= "streaming" and strategy ~= "auto" then
		vim.notify("Invalid strategy. Use: single, streaming, or auto", vim.log.levels.ERROR)
		return false
	end

	M.current.context.strategy = strategy
	vim.notify("Context strategy set to: " .. strategy, vim.log.levels.INFO)
	return true
end

-- Validate model name
function M.validate_model()
	local is_valid = vim.tbl_contains(M.valid_models, M.current.model)

	if not is_valid then
		vim.notify(
			"⚠️  Warning: Model '"
				.. M.current.model
				.. "' may not be valid. Valid models: "
				.. table.concat(M.valid_models, ", "),
			vim.log.levels.WARN
		)
	end

	return is_valid
end

return M
