-- ailite/api.lua
-- Claude API communication

local M = {}

local config = require("ailite.config")
local state = require("ailite.state")
local utils = require("ailite.utils")

-- Build curl command
local function build_curl_command(body_file, timeout)
	local cfg = config.get()

	return {
		"curl",
		"-s",
		"-X",
		"POST",
		"https://api.anthropic.com/v1/messages",
		"-H",
		"Content-Type: application/json",
		"-H",
		"x-api-key: " .. cfg.api_key,
		"-H",
		"anthropic-version: 2023-06-01",
		"-d",
		"@" .. body_file,
		"--max-time",
		tostring(timeout or 120),
		"-w",
		"\n%{http_code}", -- Add HTTP status code
	}
end

-- Parse API response
local function parse_response(result)
	-- Check for curl errors
	if vim.v.shell_error ~= 0 then
		utils.notify("Curl error (code " .. vim.v.shell_error .. "): " .. result, vim.log.levels.ERROR)
		return nil, nil
	end

	-- Separate response and HTTP code
	local lines = vim.split(result, "\n")
	local http_code = lines[#lines]
	table.remove(lines, #lines)
	local response_body = table.concat(lines, "\n")

	utils.notify("Debug: HTTP Status Code: " .. (http_code or "unknown"), vim.log.levels.INFO)

	-- Check HTTP codes
	if http_code == "401" then
		utils.notify("❌ Authentication failed! Check your API key.", vim.log.levels.ERROR)
		return nil, nil
	elseif http_code == "429" then
		utils.notify("❌ Rate limit exceeded! Wait a moment and try again.", vim.log.levels.ERROR)
		return nil, nil
	elseif http_code == "400" then
		utils.notify("❌ Bad request! Check your model name and request format.", vim.log.levels.ERROR)
		return nil, nil
	elseif http_code ~= "200" then
		utils.notify("❌ HTTP Error " .. http_code, vim.log.levels.ERROR)
		return nil, nil
	end

	-- Parse JSON response
	local ok, response = pcall(vim.fn.json_decode, response_body)
	if not ok then
		utils.notify(
			"Error decoding API response. Raw response: " .. vim.inspect(response_body:sub(1, 500)),
			vim.log.levels.ERROR
		)
		return nil, nil
	end

	return response, http_code
end

-- Handle API errors
local function handle_api_error(response)
	if not response.error then
		return false
	end

	utils.notify("API error: " .. vim.inspect(response.error), vim.log.levels.ERROR)

	-- Check for specific error types
	if response.error.type == "invalid_request_error" then
		if response.error.message:match("max_tokens") then
			utils.notify("Token limit exceeded. Try using streaming mode or reducing context.", vim.log.levels.ERROR)
		elseif response.error.message:match("credit") or response.error.message:match("balance") then
			utils.notify("API credit/balance issue. Check your Anthropic account.", vim.log.levels.ERROR)
		end
	end

	return true
end

-- Call Claude API
function M.call_api(messages, options)
	local cfg = config.get()

	if not cfg.api_key then
		utils.notify(
			"API key not configured! Use :lua require('ailite').setup({api_key = 'your-key'})",
			vim.log.levels.ERROR
		)
		return nil
	end

	options = options or {}

	-- Debug: log size
	local total_content_size = 0
	for _, msg in ipairs(messages) do
		total_content_size = total_content_size + #msg.content
	end
	utils.notify(
		string.format("Debug: Sending request with %d messages, %d total characters", #messages, total_content_size),
		vim.log.levels.INFO
	)

	-- Prepare request body
	local body = vim.fn.json_encode({
		model = cfg.model,
		messages = messages,
		max_tokens = options.max_tokens or cfg.max_tokens,
		temperature = options.temperature or cfg.temperature,
	})

	-- Create temp file for curl
	local tmpfile = utils.create_temp_file(body)
	if not tmpfile then
		utils.notify("Error creating temp file for request", vim.log.levels.ERROR)
		return nil
	end

	-- Make API call
	utils.notify("Debug: Making API call...", vim.log.levels.INFO)
	local curl_cmd = build_curl_command(tmpfile, options.timeout)
	local result = vim.fn.system(curl_cmd)

	-- Clean up temp file
	os.remove(tmpfile)

	-- Parse response
	local response, http_code = parse_response(result)
	if not response then
		return nil
	end

	-- Handle errors
	if handle_api_error(response) then
		return nil
	end

	-- Extract content
	if response.content and response.content[1] and response.content[1].text then
		utils.notify("Debug: Response received successfully", vim.log.levels.INFO)
		return response.content[1].text
	end

	utils.notify("Unexpected response format: " .. vim.inspect(response), vim.log.levels.ERROR)
	return nil
end

-- Simple API test
function M.test_api()
	local cfg = config.get()

	if not cfg.api_key then
		utils.notify("API key not configured!", vim.log.levels.ERROR)
		return false
	end

	-- Simple message
	local messages = { {
		role = "user",
		content = "Say 'Hello from Claude!' if you receive this.",
	} }

	local response = M.call_api(messages, { max_tokens = 1024, timeout = 30 })

	if response then
		utils.notify("✅ API Test Successful: " .. response, vim.log.levels.INFO)
		return true
	else
		utils.notify("❌ API Test Failed", vim.log.levels.ERROR)
		return false
	end
end

-- Debug API connection
function M.debug()
	local cfg = config.get()

	local debug_info = {
		"=== AILITE DEBUG INFO ===",
		"",
		"1. Configuration:",
		"   API Key Set: " .. (cfg.api_key and "YES" or "NO"),
		"   API Key Length: " .. (cfg.api_key and #cfg.api_key or 0),
		"   Model: " .. cfg.model,
		"",
		"2. Environment:",
		"   ANTHROPIC_API_KEY: " .. (vim.env.ANTHROPIC_API_KEY and "SET" or "NOT SET"),
		"   CLAUDE_API_KEY: " .. (vim.env.CLAUDE_API_KEY and "SET" or "NOT SET"),
		"",
		"3. State:",
		"   Selected Files: " .. #state.plugin.selected_files,
		"   Chat History: " .. #state.plugin.chat_history .. " messages",
		"   Is Processing: " .. tostring(state.plugin.is_processing),
		"   Is Streaming: " .. tostring(state.streaming.is_streaming),
		"",
		"4. Testing Simple API Call...",
	}

	utils.notify(table.concat(debug_info, "\n"), vim.log.levels.INFO)

	-- Validate model
	config.validate_model()

	-- Test API
	if not M.test_api() then
		-- Show troubleshooting suggestions
		local suggestions = {
			"",
			"Troubleshooting suggestions:",
			"1. Check if your API key is correct",
			"2. Verify you have credits in your Anthropic account",
			"3. Try setting the API key directly:",
			"   :lua require('ailite').setup({api_key = 'sk-ant-...'})",
			"4. Check if the model name is correct:",
			"   :lua require('ailite').setup({model = 'claude-3-5-sonnet-20241022'})",
			"5. Test with curl directly:",
			"   curl -X POST https://api.anthropic.com/v1/messages \\",
			"     -H 'x-api-key: YOUR_KEY' \\",
			"     -H 'anthropic-version: 2023-06-01' \\",
			"     -H 'content-type: application/json' \\",
			'     -d \'{"model": "claude-3-5-sonnet-20241022", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 1024}\'',
		}

		utils.notify(table.concat(suggestions, "\n"), vim.log.levels.INFO)
	end
end

return M
