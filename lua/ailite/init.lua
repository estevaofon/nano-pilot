-- ailite/init.lua
-- Main plugin file

local M = {}

-- Setup plugin
function M.setup(opts)
	-- Setup configuration
	local config = require("ailite.config")
	config.setup(opts)

	-- Setup utilities
	local utils = require("ailite.utils")
	utils.setup_highlights()

	-- Create commands
	M.create_commands()

	-- Setup keymaps
	local keymaps = require("ailite.keymaps")
	keymaps.setup()

	-- Notify setup complete
	local cfg = config.get()
	if cfg.api_key then
		utils.notify("✨ Ailite loaded successfully! Use <leader>cc to open chat.", vim.log.levels.INFO)
	else
		utils.notify(
			"⚠️  Ailite: API key not configured! Set ANTHROPIC_API_KEY or configure in setup().",
			vim.log.levels.WARN
		)
	end
end

-- Create user commands
function M.create_commands()
	local chat = require("ailite.chat")
	local files = require("ailite.files")
	local code = require("ailite.code")
	local context = require("ailite.context")
	local api = require("ailite.api")
	local config = require("ailite.config")
	local utils = require("ailite.utils")

	-- Chat commands
	vim.api.nvim_create_user_command("AiliteChat", function()
		chat.toggle_chat()
	end, {})

	vim.api.nvim_create_user_command("AilitePrompt", function()
		M.prompt()
	end, {})

	vim.api.nvim_create_user_command("AiliteClearChat", function()
		chat.clear_chat()
	end, {})

	vim.api.nvim_create_user_command("AiliteHelp", function()
		chat.show_help()
	end, {})

	-- File commands
	vim.api.nvim_create_user_command("AiliteSelectFiles", function()
		files.select_files()
	end, {})

	vim.api.nvim_create_user_command("AiliteListFiles", function()
		files.list_selected_files()
	end, {})

	vim.api.nvim_create_user_command("AiliteClearFiles", function()
		files.clear_selected_files()
	end, {})

	vim.api.nvim_create_user_command("AiliteToggleFile", function()
		files.toggle_current_file()
	end, {})

	-- Code commands
	vim.api.nvim_create_user_command("AiliteReplaceFile", function()
		code.replace_file_with_last_code()
	end, {})

	vim.api.nvim_create_user_command("AiliteDiffApply", function()
		code.apply_code_with_diff()
	end, {})

	vim.api.nvim_create_user_command("AiliteApplyCode", function()
		local state = require("ailite.state")
		if #state.plugin.code_blocks > 0 then
			code.show_code_preview(state.plugin.current_code_block or 1)
		else
			utils.notify("No code blocks available", vim.log.levels.WARN)
		end
	end, {})

	-- Context commands
	vim.api.nvim_create_user_command("AiliteEstimateContext", function()
		context.estimate_context()
	end, {})

	vim.api.nvim_create_user_command("AiliteSetStrategy", function(opts)
		config.set_strategy(opts.args)
	end, {
		nargs = 1,
		complete = function()
			return { "single", "streaming", "auto" }
		end,
	})

	-- Info and debug commands
	vim.api.nvim_create_user_command("AiliteInfo", function()
		M.show_info()
	end, {})

	vim.api.nvim_create_user_command("AiliteDebug", function()
		api.debug()
	end, {})

	vim.api.nvim_create_user_command("AiliteShowConfig", function()
		M.show_config()
	end, {})

	vim.api.nvim_create_user_command("AiliteSetApiKey", function(opts)
		if opts.args == "" then
			utils.notify("Usage: :AiliteSetApiKey sk-ant-...", vim.log.levels.ERROR)
			return
		end

		config.set_api_key(opts.args)
		utils.notify("✅ API Key set temporarily. Test with :AiliteDebug", vim.log.levels.INFO)
	end, { nargs = 1 })
end

-- Quick prompt
function M.prompt()
	local state = require("ailite.state")
	local chat = require("ailite.chat")
	local utils = require("ailite.utils")

	if state.plugin.is_processing then
		utils.notify("⏳ Waiting for previous response...", vim.log.levels.WARN)
		return
	end

	local prompt = utils.input("💬 Prompt: ")
	if prompt == "" then
		return
	end

	-- Show chat if not open
	if not state.is_chat_win_valid() then
		chat.create_chat_window()
	end

	chat.process_prompt(prompt)
end

-- Prompt with visual selection
function M.prompt_with_selection()
	local utils = require("ailite.utils")
	local state = require("ailite.state")
	local chat = require("ailite.chat")

	local selection = utils.get_visual_selection()
	if selection == "" then
		utils.notify("No selection found", vim.log.levels.WARN)
		return
	end

	-- Open chat if not open
	if not state.is_chat_win_valid() then
		chat.create_chat_window()
	end

	-- Create prompt with selection context
	local prompt = string.format(
		"About the selected code:\n```%s\n%s\n```\n\nWhat would you like to do with this code?",
		vim.bo.filetype,
		selection
	)

	chat.process_prompt(prompt)
end

-- Show plugin info
function M.show_info()
	local config = require("ailite.config")
	local state = require("ailite.state")
	local utils = require("ailite.utils")

	local cfg = config.get()

	local info = {
		"=== 🚀 Ailite Info ===",
		"",
		"📊 State:",
		"  • History: " .. #state.plugin.chat_history .. " messages",
		"  • Selected files: " .. #state.plugin.selected_files,
		"  • Code blocks: " .. #state.plugin.code_blocks,
		"  • History limit: " .. (cfg.history_limit or 20) .. " messages",
		"",
		"🔧 Configuration:",
		"  • Model: " .. cfg.model,
		"  • Max tokens: " .. cfg.max_tokens,
		"  • Temperature: " .. cfg.temperature,
		"  • API Key: " .. (cfg.api_key and "✅ Configured" or "❌ Not configured"),
		"  • Context strategy: " .. cfg.context.strategy,
		"",
	}

	if #state.plugin.selected_files > 0 then
		table.insert(info, "📄 Files in context:")
		for i, file in ipairs(state.plugin.selected_files) do
			table.insert(info, string.format("  %d. %s", i, utils.get_relative_path(file)))
		end
		table.insert(info, "")
	end

	table.insert(info, "⌨️  Main shortcuts:")
	table.insert(info, "  • <leader>cc - Toggle chat")
	table.insert(info, "  • <leader>cp - Quick prompt")
	table.insert(info, "  • <leader>cf - Select files")
	table.insert(info, "  • <leader>ct - Toggle current file")

	utils.notify(table.concat(info, "\n"), vim.log.levels.INFO)
end

-- Show current configuration
function M.show_config()
	local config = require("ailite.config")
	local utils = require("ailite.utils")

	local cfg = config.get()

	local config_info = {
		"=== Ailite Configuration ===",
		"",
		"API Key: " .. (cfg.api_key and (cfg.api_key:sub(1, 10) .. "...") or "NOT SET"),
		"Model: " .. cfg.model,
		"Max Tokens: " .. cfg.max_tokens,
		"Temperature: " .. cfg.temperature,
		"",
		"Context Settings:",
		"  Strategy: " .. cfg.context.strategy,
		"  Max Tokens/Message: " .. cfg.context.max_tokens_per_message,
		"  Token Estimation Ratio: " .. cfg.context.token_estimation_ratio,
		"  Include Summary: " .. tostring(cfg.context.include_context_summary),
	}

	utils.notify(table.concat(config_info, "\n"), vim.log.levels.INFO)
end

return M
