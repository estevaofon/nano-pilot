-- simple-cursor.nvim
-- Plugin estilo Cursor IDE para Neovim com integração Claude API e chat interativo

local M = {}
local api = vim.api
local fn = vim.fn

-- Configuração padrão
M.config = {
	api_key = nil,
	model = "claude-3-5-sonnet-20241022",
	max_tokens = 8192,
	temperature = 0.7,
	history_limit = 20,
	chat_window = {
		width = 100,
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
	-- Configurações do chat interativo
	chat_input_prefix = ">>> ",
	assistant_prefix = "Claude: ",
	user_prefix = "You: ",
}

-- Estado do plugin
local state = {
	chat_buf = nil,
	chat_win = nil,
	code_preview_buf = nil,
	code_preview_win = nil,
	selected_files = {},
	chat_history = {},
	is_processing = false,
	code_blocks = {},
	current_code_block = 0,
	original_buf = nil,
	original_win = nil,
	-- Estado do chat interativo
	input_start_line = nil,
	is_in_input_mode = false,
	current_input_lines = {},
}

-- Namespace para highlights
local ns_id = api.nvim_create_namespace("simple_cursor")

-- Utilitários
local function get_visual_selection()
	local start_pos = fn.getpos("'<")
	local end_pos = fn.getpos("'>")
	local lines = api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)

	if #lines == 0 then
		return ""
	end

	-- Ajustar primeira e última linha baseado na seleção de coluna
	if #lines == 1 then
		lines[1] = lines[1]:sub(start_pos[3], end_pos[3])
	else
		lines[1] = lines[1]:sub(start_pos[3])
		lines[#lines] = lines[#lines]:sub(1, end_pos[3])
	end

	return table.concat(lines, "\n")
end

-- Função para extrair blocos de código da resposta
local function extract_code_blocks(content)
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

-- Função para aplicar código no arquivo
local function apply_code_to_file(code, target_buf)
	if not target_buf or not api.nvim_buf_is_valid(target_buf) then
		vim.notify("Buffer inválido", vim.log.levels.ERROR)
		return
	end

	-- Perguntar ao usuário como aplicar o código
	local choices = {
		"",
		"1. Substituir todo o arquivo",
		"2. Inserir no cursor",
		"3. Anexar ao final",
		"4. Cancelar",
	}

	local choice = fn.inputlist(choices)

	if choice == 1 then
		-- Substituir todo o conteúdo do arquivo
		local lines = vim.split(code, "\n")
		api.nvim_buf_set_lines(target_buf, 0, -1, false, {})
		api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
		vim.notify("✅ Arquivo completamente substituído", vim.log.levels.INFO)

		-- Salvar o arquivo automaticamente se desejar
		local save = fn.confirm("Deseja salvar o arquivo agora?", "&Sim\n&Não", 1)
		if save == 1 then
			local current_buf = api.nvim_get_current_buf()
			api.nvim_set_current_buf(target_buf)
			vim.cmd("write")
			api.nvim_set_current_buf(current_buf)
			vim.notify("💾 Arquivo salvo", vim.log.levels.INFO)
		end
	elseif choice == 2 then
		-- Inserir no cursor
		local win = fn.bufwinid(target_buf)
		if win ~= -1 then
			local cursor = api.nvim_win_get_cursor(win)
			local lines = vim.split(code, "\n")
			api.nvim_buf_set_lines(target_buf, cursor[1] - 1, cursor[1] - 1, false, lines)
			vim.notify("✅ Código inserido no cursor", vim.log.levels.INFO)
		else
			vim.notify("Janela do buffer não encontrada", vim.log.levels.ERROR)
		end
	elseif choice == 3 then
		-- Anexar ao final
		local lines = vim.split(code, "\n")
		api.nvim_buf_set_lines(target_buf, -1, -1, false, lines)
		vim.notify("✅ Código anexado ao final do arquivo", vim.log.levels.INFO)
	end
end

-- Função para renderizar mensagem no chat com formatação
local function render_message_in_chat(role, content, start_line)
	if not state.chat_buf or not api.nvim_buf_is_valid(state.chat_buf) then
		return
	end

	local lines = {}
	local timestamp = os.date("%H:%M:%S")

	-- Adicionar separador se não for a primeira mensagem
	if start_line > 0 then
		table.insert(lines, "")
		table.insert(
			lines,
			"─────────────────────────────────────"
		)
		table.insert(lines, "")
	end

	-- Cabeçalho da mensagem
	local header
	if role == "user" then
		header = string.format("%s [%s]", M.config.user_prefix, timestamp)
	else
		header = string.format("%s [%s]", M.config.assistant_prefix, timestamp)
	end
	table.insert(lines, header)
	table.insert(lines, "")

	-- Adicionar conteúdo
	for line in content:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	-- Inserir linhas no buffer
	api.nvim_buf_set_lines(state.chat_buf, start_line, start_line, false, lines)

	-- Aplicar highlights
	local header_line = start_line
	if start_line > 0 then
		header_line = start_line + 3 -- Pular linhas do separador
	end

	if role == "user" then
		api.nvim_buf_add_highlight(state.chat_buf, ns_id, "SimpleCursorUser", header_line, 0, -1)
	else
		api.nvim_buf_add_highlight(state.chat_buf, ns_id, "SimpleCursorAssistant", header_line, 0, -1)
	end

	return #lines
end

-- Função para iniciar modo de input
local function start_input_mode()
	if state.is_processing then
		vim.notify("⏳ Aguarde a resposta anterior...", vim.log.levels.WARN)
		return
	end

	if not state.chat_buf or not api.nvim_buf_is_valid(state.chat_buf) then
		return
	end

	-- Tornar buffer editável
	api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
	api.nvim_buf_set_option(state.chat_buf, "readonly", false)

	-- Adicionar prompt de input
	local line_count = api.nvim_buf_line_count(state.chat_buf)
	local prompt_lines = { "", M.config.chat_input_prefix }

	api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, prompt_lines)

	-- Marcar início do input
	state.input_start_line = line_count + 1
	state.is_in_input_mode = true
	state.current_input_lines = {}

	-- Mover cursor para depois do prompt
	if state.chat_win and api.nvim_win_is_valid(state.chat_win) then
		api.nvim_win_set_cursor(state.chat_win, { state.input_start_line + 1, #M.config.chat_input_prefix })
	end

	-- Aplicar highlight no prompt
	api.nvim_buf_add_highlight(
		state.chat_buf,
		ns_id,
		"SimpleCursorPrompt",
		state.input_start_line,
		0,
		#M.config.chat_input_prefix
	)

	-- Entrar em modo insert
	vim.cmd("startinsert!")
end

-- Função para processar input do usuário
local function process_user_input()
	if not state.is_in_input_mode or not state.input_start_line then
		return
	end

	-- Pegar linhas do input
	local current_line = api.nvim_buf_line_count(state.chat_buf)
	local input_lines = api.nvim_buf_get_lines(state.chat_buf, state.input_start_line, current_line + 1, false)

	-- Remover o prompt da primeira linha
	if #input_lines > 0 then
		input_lines[1] = input_lines[1]:sub(#M.config.chat_input_prefix + 1)
	end

	-- Juntar as linhas
	local prompt = table.concat(input_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")

	if prompt == "" then
		-- Remover linhas vazias do prompt
		api.nvim_buf_set_lines(state.chat_buf, state.input_start_line - 1, -1, false, {})
		state.is_in_input_mode = false
		state.input_start_line = nil
		return
	end

	-- Sair do modo de input
	state.is_in_input_mode = false
	state.input_start_line = nil

	-- Tornar buffer não editável temporariamente
	api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
	api.nvim_buf_set_option(state.chat_buf, "readonly", true)

	-- Processar o prompt
	M.process_prompt(prompt)
end

-- Função para cancelar input
local function cancel_input()
	if not state.is_in_input_mode or not state.input_start_line then
		return
	end

	-- Remover linhas do input
	api.nvim_buf_set_lines(state.chat_buf, state.input_start_line - 1, -1, false, {})

	-- Resetar estado
	state.is_in_input_mode = false
	state.input_start_line = nil

	-- Tornar buffer não editável
	api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
	api.nvim_buf_set_option(state.chat_buf, "readonly", true)

	-- Sair do modo insert
	vim.cmd("stopinsert")
end

-- Função melhorada para criar janela de chat
local function create_chat_window()
	-- Salvar referência ao buffer/janela original
	state.original_buf = api.nvim_get_current_buf()
	state.original_win = api.nvim_get_current_win()

	-- Criar buffer se não existir
	if not state.chat_buf or not api.nvim_buf_is_valid(state.chat_buf) then
		state.chat_buf = api.nvim_create_buf(false, true)
		api.nvim_buf_set_option(state.chat_buf, "filetype", "markdown")
		api.nvim_buf_set_option(state.chat_buf, "bufhidden", "hide")
		api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
		api.nvim_buf_set_option(state.chat_buf, "readonly", true)
		api.nvim_buf_set_name(state.chat_buf, "SimpleCursor-Chat")
	end

	-- Calcular posição
	local width = M.config.chat_window.width
	local height = M.config.chat_window.height
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- Criar janela
	state.chat_win = api.nvim_open_win(state.chat_buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		border = M.config.chat_window.border,
		style = "minimal",
		title = " Simple Cursor Chat - 'i' para nova mensagem, 'h' para ajuda ",
		title_pos = "center",
	})

	-- Configurações da janela
	api.nvim_win_set_option(state.chat_win, "wrap", true)
	api.nvim_win_set_option(state.chat_win, "linebreak", true)
	api.nvim_win_set_option(state.chat_win, "cursorline", true)

	-- Configurar keymaps para o modo normal
	local opts = { noremap = true, silent = true, buffer = state.chat_buf }

	-- Teclas básicas
	vim.keymap.set("n", "q", function()
		M.close_chat()
	end, opts)

	vim.keymap.set("n", "<Esc>", function()
		if state.is_in_input_mode then
			cancel_input()
		else
			M.close_chat()
		end
	end, opts)

	vim.keymap.set("n", "c", function()
		M.clear_chat()
	end, opts)

	vim.keymap.set("n", "i", function()
		start_input_mode()
	end, opts)

	vim.keymap.set("n", "o", function()
		start_input_mode()
	end, opts)

	vim.keymap.set("n", "a", function()
		start_input_mode()
	end, opts)

	vim.keymap.set("n", "h", function()
		M.show_help()
	end, opts)

	-- Navegação de blocos de código
	vim.keymap.set("n", M.config.keymaps.next_code_block, function()
		M.next_code_block()
	end, opts)

	vim.keymap.set("n", M.config.keymaps.prev_code_block, function()
		M.prev_code_block()
	end, opts)

	-- Keymaps para modo insert (quando em input)
	vim.keymap.set("i", M.config.keymaps.send_message, function()
		process_user_input()
		vim.cmd("stopinsert")
	end, opts)

	vim.keymap.set("i", "<C-c>", function()
		cancel_input()
	end, opts)

	-- Configurar autocmds para o buffer
	local group = api.nvim_create_augroup("SimpleCursorChat", { clear = true })

	-- Prevenir edição fora da área de input
	api.nvim_create_autocmd("TextChangedI", {
		group = group,
		buffer = state.chat_buf,
		callback = function()
			if not state.is_in_input_mode then
				vim.cmd("stopinsert")
				api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
			end
		end,
	})

	-- Manter cursor na área de input
	api.nvim_create_autocmd("CursorMovedI", {
		group = group,
		buffer = state.chat_buf,
		callback = function()
			if state.is_in_input_mode and state.input_start_line then
				local cursor = api.nvim_win_get_cursor(0)
				if cursor[1] < state.input_start_line + 1 then
					api.nvim_win_set_cursor(0, { state.input_start_line + 1, #M.config.chat_input_prefix })
				elseif cursor[1] == state.input_start_line + 1 and cursor[2] < #M.config.chat_input_prefix then
					api.nvim_win_set_cursor(0, { state.input_start_line + 1, #M.config.chat_input_prefix })
				end
			end
		end,
	})

	-- Mostrar mensagem de boas-vindas se o chat estiver vazio
	local lines = api.nvim_buf_get_lines(state.chat_buf, 0, -1, false)
	if #lines == 0 or (#lines == 1 and lines[1] == "") then
		local welcome_msg = [[
Bem-vindo ao Simple Cursor! 🚀

Este é um chat interativo com Claude. Digite 'i' para começar uma nova mensagem.

Comandos disponíveis:
  • i, o, a  - Iniciar nova mensagem
  • Ctrl+S   - Enviar mensagem (no modo insert)
  • Esc      - Cancelar input ou fechar chat
  • h        - Mostrar ajuda completa
  • c        - Limpar chat
  • q        - Fechar chat

Comece digitando 'i' para enviar sua primeira mensagem!]]

		api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
		local welcome_lines = vim.split(welcome_msg, "\n")
		api.nvim_buf_set_lines(state.chat_buf, 0, -1, false, welcome_lines)
		api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
	end
end

-- Função para mostrar ajuda
function M.show_help()
	local help_text = string.format(
		[[
=== Simple Cursor - Ajuda ===

COMANDOS NO CHAT:
  i, o, a     - Iniciar nova mensagem
  %s     - Enviar mensagem (modo insert)
  Esc         - Cancelar input ou fechar chat
  q           - Fechar chat
  c           - Limpar chat e histórico
  h           - Mostrar esta ajuda
  %s       - Próximo bloco de código
  %s       - Bloco de código anterior

COMANDOS NO PREVIEW DE CÓDIGO:
  %s       - Aplicar código no arquivo
  %s       - Copiar código
  q, Esc      - Fechar preview

COMANDOS GLOBAIS:
  :SimpleCursorChat          - Abrir/fechar chat
  :SimpleCursorSelectFiles   - Selecionar arquivos para contexto
  :SimpleCursorListFiles     - Listar arquivos selecionados
  :SimpleCursorToggleFile    - Toggle arquivo atual
  :SimpleCursorInfo          - Mostrar informações do estado
  :SimpleCursorReplaceFile   - Substituir arquivo com último código
  :SimpleCursorDiffApply     - Aplicar código com diff preview

RECURSOS:
  • Chat interativo estilo terminal
  • Histórico completo mantido para contexto
  • Arquivos selecionados incluídos automaticamente
  • Blocos de código podem ser aplicados diretamente
  • Suporta múltiplas formas de aplicação de código
  • Syntax highlighting para código]],
		M.config.keymaps.send_message,
		M.config.keymaps.next_code_block,
		M.config.keymaps.prev_code_block,
		M.config.keymaps.apply_code,
		M.config.keymaps.copy_code
	)

	vim.notify(help_text, vim.log.levels.INFO)
end

-- Função melhorada de processamento de prompt
function M.process_prompt(prompt)
	if not prompt or prompt == "" then
		return
	end

	-- Resetar blocos de código
	state.code_blocks = {}
	state.current_code_block = 0

	-- Adicionar prompt ao histórico
	table.insert(state.chat_history, { role = "user", content = prompt })

	-- Renderizar mensagem do usuário
	local line_count = api.nvim_buf_line_count(state.chat_buf)
	api.nvim_buf_set_option(state.chat_buf, "modifiable", true)

	-- Limpar prompt de input se existir
	if state.input_start_line then
		api.nvim_buf_set_lines(state.chat_buf, state.input_start_line - 1, -1, false, {})
	end

	render_message_in_chat("user", prompt, api.nvim_buf_line_count(state.chat_buf))
	api.nvim_buf_set_option(state.chat_buf, "modifiable", false)

	-- Indicar processamento
	state.is_processing = true
	api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
	local processing_line = api.nvim_buf_line_count(state.chat_buf)
	api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, { "", "🤔 Claude está pensando..." })
	api.nvim_buf_set_option(state.chat_buf, "modifiable", false)

	-- Scroll para o final
	if state.chat_win and api.nvim_win_is_valid(state.chat_win) then
		local line_count = api.nvim_buf_line_count(state.chat_buf)
		api.nvim_win_set_cursor(state.chat_win, { line_count, 0 })
	end

	-- Fazer chamada assíncrona
	vim.defer_fn(function()
		local response = call_claude_api(prompt)

		-- Remover indicador de processamento
		if state.chat_buf and api.nvim_buf_is_valid(state.chat_buf) then
			api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
			api.nvim_buf_set_lines(state.chat_buf, processing_line, -1, false, {})
		end

		if response then
			-- Renderizar resposta
			render_message_in_chat("assistant", response, api.nvim_buf_line_count(state.chat_buf))
			table.insert(state.chat_history, { role = "assistant", content = response })

			-- Extrair blocos de código
			local blocks = extract_code_blocks(response)
			if #blocks > 0 then
				state.code_blocks = blocks
				state.current_code_block = 1
				vim.notify(
					string.format(
						"Encontrados %d blocos de código. Use %s/%s para navegar",
						#blocks,
						M.config.keymaps.prev_code_block,
						M.config.keymaps.next_code_block
					),
					vim.log.levels.INFO
				)
			end
		else
			api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, { "", "❌ Erro ao obter resposta da API" })
		end

		api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
		state.is_processing = false

		-- Scroll para o final
		if state.chat_win and api.nvim_win_is_valid(state.chat_win) then
			vim.defer_fn(function()
				local line_count = api.nvim_buf_line_count(state.chat_buf)
				api.nvim_win_set_cursor(state.chat_win, { line_count, 0 })
			end, 50)
		end
	end, 100)
end

-- Função para mostrar preview de código
local function show_code_preview(block_index)
	if not state.code_blocks or #state.code_blocks == 0 then
		vim.notify("Nenhum bloco de código disponível", vim.log.levels.WARN)
		return
	end

	local block = state.code_blocks[block_index]
	if not block then
		return
	end

	-- Criar buffer de preview se não existir
	if not state.code_preview_buf or not api.nvim_buf_is_valid(state.code_preview_buf) then
		state.code_preview_buf = api.nvim_create_buf(false, true)
		api.nvim_buf_set_option(state.code_preview_buf, "bufhidden", "hide")
	end

	-- Definir conteúdo
	local lines = vim.split(block.code, "\n")
	api.nvim_buf_set_lines(state.code_preview_buf, 0, -1, false, lines)

	-- Definir filetype baseado na linguagem
	if block.language and block.language ~= "" then
		api.nvim_buf_set_option(state.code_preview_buf, "filetype", block.language)
	end

	-- Se a janela não existe, criar
	if not state.code_preview_win or not api.nvim_win_is_valid(state.code_preview_win) then
		local width = M.config.code_window.width
		local height = M.config.code_window.height
		local row = math.floor((vim.o.lines - height) / 2)
		local col = math.floor((vim.o.columns - width) / 2)

		state.code_preview_win = api.nvim_open_win(state.code_preview_buf, true, {
			relative = "editor",
			row = row,
			col = col,
			width = width,
			height = height,
			border = M.config.code_window.border,
			style = "minimal",
			title = string.format(" Bloco de Código %d/%d - %s ", block_index, #state.code_blocks, block.language),
			title_pos = "center",
		})

		-- Configurar keymaps no preview
		local opts = { noremap = true, silent = true, buffer = state.code_preview_buf }

		-- Aplicar código
		vim.keymap.set("n", M.config.keymaps.apply_code, function()
			if state.original_buf and api.nvim_buf_is_valid(state.original_buf) then
				apply_code_to_file(block.code, state.original_buf)
				api.nvim_win_close(state.code_preview_win, true)
				state.code_preview_win = nil
			else
				vim.notify("Buffer original não encontrado", vim.log.levels.ERROR)
			end
		end, opts)

		-- Copiar código
		vim.keymap.set("n", M.config.keymaps.copy_code, function()
			vim.fn.setreg("+", block.code)
			vim.notify("Código copiado para a área de transferência", vim.log.levels.INFO)
		end, opts)

		-- Fechar preview
		vim.keymap.set("n", "q", function()
			api.nvim_win_close(state.code_preview_win, true)
			state.code_preview_win = nil
		end, opts)

		vim.keymap.set("n", "<Esc>", function()
			api.nvim_win_close(state.code_preview_win, true)
			state.code_preview_win = nil
		end, opts)
	else
		-- Atualizar título
		api.nvim_win_set_config(state.code_preview_win, {
			title = string.format(" Bloco de Código %d/%d - %s ", block_index, #state.code_blocks, block.language),
		})
	end
end

-- Função para navegar entre blocos de código
function M.next_code_block()
	if #state.code_blocks == 0 then
		vim.notify("Nenhum bloco de código disponível", vim.log.levels.WARN)
		return
	end

	state.current_code_block = state.current_code_block % #state.code_blocks + 1
	show_code_preview(state.current_code_block)
end

function M.prev_code_block()
	if #state.code_blocks == 0 then
		vim.notify("Nenhum bloco de código disponível", vim.log.levels.WARN)
		return
	end

	state.current_code_block = state.current_code_block - 1
	if state.current_code_block < 1 then
		state.current_code_block = #state.code_blocks
	end
	show_code_preview(state.current_code_block)
end

-- Função para substituir arquivo completo
function M.replace_file_with_last_code()
	if #state.code_blocks == 0 then
		vim.notify("❌ Nenhum bloco de código disponível", vim.log.levels.ERROR)
		return
	end

	if not state.original_buf or not api.nvim_buf_is_valid(state.original_buf) then
		vim.notify("❌ Buffer original não encontrado", vim.log.levels.ERROR)
		return
	end

	-- Pegar o código do bloco atual ou primeiro bloco
	local block = state.code_blocks[state.current_code_block] or state.code_blocks[1]
	local code = block.code

	-- Confirmar substituição
	local filename = fn.fnamemodify(api.nvim_buf_get_name(state.original_buf), ":t")
	local confirm = fn.confirm(
		string.format("⚠️  Substituir TODO o conteúdo de '%s'?", filename),
		"&Sim\n&Não\n&Ver preview",
		2
	)

	if confirm == 1 then
		-- Substituir arquivo
		local lines = vim.split(code, "\n")
		api.nvim_buf_set_lines(state.original_buf, 0, -1, false, {})
		api.nvim_buf_set_lines(state.original_buf, 0, -1, false, lines)

		vim.notify("✅ Arquivo substituído completamente", vim.log.levels.INFO)

		-- Oferecer salvar
		local save = fn.confirm("💾 Salvar arquivo agora?", "&Sim\n&Não", 1)
		if save == 1 then
			local current_buf = api.nvim_get_current_buf()
			api.nvim_set_current_buf(state.original_buf)
			vim.cmd("write")
			api.nvim_set_current_buf(current_buf)
			vim.notify("💾 Arquivo salvo", vim.log.levels.INFO)
		end
	elseif confirm == 3 then
		-- Mostrar preview
		show_code_preview(state.current_code_block or 1)
	end
end

-- Função para aplicar código com diff preview
function M.apply_code_with_diff()
	if #state.code_blocks == 0 then
		vim.notify("❌ Nenhum bloco de código disponível", vim.log.levels.ERROR)
		return
	end

	if not state.original_buf or not api.nvim_buf_is_valid(state.original_buf) then
		vim.notify("❌ Buffer original não encontrado", vim.log.levels.ERROR)
		return
	end

	-- Criar um buffer temporário para mostrar o diff
	local diff_buf = api.nvim_create_buf(false, true)
	local block = state.code_blocks[state.current_code_block] or state.code_blocks[1]

	-- Pegar conteúdo atual
	local current_lines = api.nvim_buf_get_lines(state.original_buf, 0, -1, false)
	local new_lines = vim.split(block.code, "\n")

	-- Criar visualização lado a lado
	local diff_lines = {
		"=== DIFF PREVIEW ===",
		"",
		"ARQUIVO ATUAL (" .. #current_lines .. " linhas) -> NOVO CONTEÚDO (" .. #new_lines .. " linhas)",
		"",
	}

	-- Mostrar primeiras 10 linhas de cada
	table.insert(diff_lines, "--- Primeiras linhas do arquivo atual ---")
	for i = 1, math.min(10, #current_lines) do
		table.insert(diff_lines, current_lines[i])
	end
	if #current_lines > 10 then
		table.insert(diff_lines, "... (" .. (#current_lines - 10) .. " linhas omitidas)")
	end

	table.insert(diff_lines, "")
	table.insert(diff_lines, "+++ Primeiras linhas do novo conteúdo +++")
	for i = 1, math.min(10, #new_lines) do
		table.insert(diff_lines, new_lines[i])
	end
	if #new_lines > 10 then
		table.insert(diff_lines, "... (" .. (#new_lines - 10) .. " linhas omitidas)")
	end

	api.nvim_buf_set_lines(diff_buf, 0, -1, false, diff_lines)

	-- Mostrar em janela flutuante
	local width = 80
	local height = 25
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local diff_win = api.nvim_open_win(diff_buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		border = "rounded",
		style = "minimal",
		title = " Confirmar Substituição ",
		title_pos = "center",
	})

	-- Keymaps para o diff
	local opts = { noremap = true, silent = true, buffer = diff_buf }

	-- Confirmar substituição
	vim.keymap.set("n", "y", function()
		api.nvim_win_close(diff_win, true)
		api.nvim_buf_set_lines(state.original_buf, 0, -1, false, {})
		api.nvim_buf_set_lines(state.original_buf, 0, -1, false, new_lines)
		vim.notify("✅ Arquivo substituído", vim.log.levels.INFO)
	end, opts)

	-- Cancelar
	vim.keymap.set("n", "n", function()
		api.nvim_win_close(diff_win, true)
		vim.notify("❌ Substituição cancelada", vim.log.levels.INFO)
	end, opts)

	vim.keymap.set("n", "q", function()
		api.nvim_win_close(diff_win, true)
	end, opts)

	vim.keymap.set("n", "<Esc>", function()
		api.nvim_win_close(diff_win, true)
	end, opts)

	-- Mostrar instruções
	api.nvim_buf_set_lines(diff_buf, -1, -1, false, {
		"",
		"─────────────────────────────────────",
		"Pressione 'y' para confirmar, 'n' para cancelar",
	})
end

-- Funções auxiliares
local function get_selected_files_content()
	local content = {}

	for _, filepath in ipairs(state.selected_files) do
		local file = io.open(filepath, "r")
		if file then
			local file_content = file:read("*all")
			file:close()

			table.insert(
				content,
				string.format("### Arquivo: %s\n```%s\n%s\n```", filepath, fn.fnamemodify(filepath, ":e"), file_content)
			)
		end
	end

	return table.concat(content, "\n\n")
end

-- Função call_claude_api
call_claude_api = function(prompt)
	if not M.config.api_key then
		vim.notify(
			"API key não configurada! Use :lua require('simple-cursor').setup({api_key = 'sua-chave'})",
			vim.log.levels.ERROR
		)
		return nil
	end

	-- Preparar contexto com arquivos selecionados
	local context = ""
	if #state.selected_files > 0 then
		context = "Contexto - Arquivos do projeto:\n\n" .. get_selected_files_content() .. "\n\n"
	end

	-- Preparar mensagens
	local messages = {}

	-- Adicionar histórico
	local history_limit = M.config.history_limit or 20
	local history_start = math.max(1, #state.chat_history - history_limit + 1)

	for i = history_start, #state.chat_history do
		table.insert(messages, state.chat_history[i])
	end

	-- Adicionar prompt atual com contexto
	local current_message = {
		role = "user",
		content = context .. prompt,
	}
	table.insert(messages, current_message)

	-- Preparar corpo da requisição
	local body = vim.fn.json_encode({
		model = M.config.model,
		messages = messages,
		max_tokens = M.config.max_tokens,
		temperature = M.config.temperature,
	})

	-- Fazer chamada usando curl
	local curl_cmd = {
		"curl",
		"-s",
		"-X",
		"POST",
		"https://api.anthropic.com/v1/messages",
		"-H",
		"Content-Type: application/json",
		"-H",
		"x-api-key: " .. M.config.api_key,
		"-H",
		"anthropic-version: 2023-06-01",
		"-d",
		body,
	}

	local result = fn.system(curl_cmd)

	-- Parse da resposta
	local ok, response = pcall(vim.fn.json_decode, result)
	if not ok then
		vim.notify("Erro ao decodificar resposta da API: " .. result, vim.log.levels.ERROR)
		return nil
	end

	if response.error then
		vim.notify("Erro da API: " .. response.error.message, vim.log.levels.ERROR)
		return nil
	end

	if response.content and response.content[1] and response.content[1].text then
		return response.content[1].text
	end

	return nil
end

-- Funções de gerenciamento de arquivos
function M.toggle_file(filepath)
	local index = nil
	for i, file in ipairs(state.selected_files) do
		if file == filepath then
			index = i
			break
		end
	end

	if index then
		table.remove(state.selected_files, index)
		vim.notify("📄 Arquivo removido: " .. filepath)
	else
		table.insert(state.selected_files, filepath)
		vim.notify("📄 Arquivo adicionado: " .. filepath)
	end
end

function M.toggle_current_file()
	local current_file = fn.expand("%:p")
	if current_file ~= "" then
		M.toggle_file(current_file)
	else
		vim.notify("Nenhum arquivo aberto", vim.log.levels.WARN)
	end
end

function M.select_files()
	-- Usar telescope se disponível
	local ok, telescope = pcall(require, "telescope.builtin")
	if ok then
		telescope.find_files({
			attach_mappings = function(prompt_bufnr, map)
				local actions = require("telescope.actions")
				local action_state = require("telescope.actions.state")

				-- Toggle arquivo
				map("i", "<CR>", function()
					local selection = action_state.get_selected_entry()
					if selection then
						local filepath = selection.path or selection.filename
						M.toggle_file(filepath)
					end
				end)

				-- Remover arquivo
				map("i", "<C-x>", function()
					local selection = action_state.get_selected_entry()
					if selection then
						local filepath = selection.path or selection.filename
						local index = nil
						for i, file in ipairs(state.selected_files) do
							if file == filepath then
								index = i
								break
							end
						end
						if index then
							table.remove(state.selected_files, index)
							vim.notify("Arquivo removido: " .. filepath)
						end
					end
				end)

				-- Adicionar múltiplos
				map("i", "<C-a>", function()
					local picker = action_state.get_current_picker(prompt_bufnr)
					local multi_selections = picker:get_multi_selection()

					local added = 0
					for _, selection in ipairs(multi_selections) do
						local filepath = selection.path or selection.filename
						if not vim.tbl_contains(state.selected_files, filepath) then
							table.insert(state.selected_files, filepath)
							added = added + 1
						end
					end

					actions.close(prompt_bufnr)
					vim.notify(added .. " arquivos adicionados")
				end)

				return true
			end,
			prompt_title = "Selecionar Arquivos (Enter=toggle, C-x=remover, C-a=múltiplos)",
		})
	else
		-- Fallback
		local filepath = fn.input("Caminho do arquivo: ", fn.expand("%:p:h") .. "/", "file")
		if filepath ~= "" and fn.filereadable(filepath) == 1 then
			M.toggle_file(filepath)
		end
	end
end

function M.list_selected_files()
	if #state.selected_files == 0 then
		vim.notify("Nenhum arquivo selecionado", vim.log.levels.INFO)
		return
	end

	local file_list = {}
	for i, file in ipairs(state.selected_files) do
		table.insert(file_list, string.format("%d. %s", i, file))
	end

	vim.notify("📁 Arquivos selecionados:\n" .. table.concat(file_list, "\n"), vim.log.levels.INFO)
end

function M.clear_selected_files()
	state.selected_files = {}
	vim.notify("✨ Seleção de arquivos limpa")
end

function M.clear_chat()
	if state.chat_buf and api.nvim_buf_is_valid(state.chat_buf) then
		api.nvim_buf_set_option(state.chat_buf, "modifiable", true)
		api.nvim_buf_set_lines(state.chat_buf, 0, -1, false, {})
		api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
		state.chat_history = {}
		state.code_blocks = {}
		state.current_code_block = 0
		state.is_in_input_mode = false
		state.input_start_line = nil
		vim.notify("💬 Chat e histórico limpos")
	end
end

function M.close_chat()
	-- Cancelar input se estiver ativo
	if state.is_in_input_mode then
		cancel_input()
	end

	if state.chat_win and api.nvim_win_is_valid(state.chat_win) then
		api.nvim_win_close(state.chat_win, true)
		state.chat_win = nil
	end
	if state.code_preview_win and api.nvim_win_is_valid(state.code_preview_win) then
		api.nvim_win_close(state.code_preview_win, true)
		state.code_preview_win = nil
	end
end

function M.toggle_chat()
	if state.chat_win and api.nvim_win_is_valid(state.chat_win) then
		M.close_chat()
	else
		create_chat_window()
	end
end

function M.show_info()
	local info = {
		"=== 🚀 Simple Cursor Info ===",
		"",
		"📊 Estado:",
		"  • Histórico: " .. #state.chat_history .. " mensagens",
		"  • Arquivos selecionados: " .. #state.selected_files,
		"  • Blocos de código: " .. #state.code_blocks,
		"  • Limite de histórico: " .. (M.config.history_limit or 20) .. " mensagens",
		"",
		"🔧 Configuração:",
		"  • Modelo: " .. M.config.model,
		"  • Max tokens: " .. M.config.max_tokens,
		"  • Temperatura: " .. M.config.temperature,
		"  • API Key: " .. (M.config.api_key and "✅ Configurada" or "❌ Não configurada"),
		"",
	}

	if #state.selected_files > 0 then
		table.insert(info, "📄 Arquivos no contexto:")
		for i, file in ipairs(state.selected_files) do
			table.insert(info, string.format("  %d. %s", i, vim.fn.fnamemodify(file, ":~:.")))
		end
		table.insert(info, "")
	end

	table.insert(info, "⌨️  Atalhos principais:")
	table.insert(info, "  • <leader>cc - Toggle chat")
	table.insert(info, "  • <leader>cp - Prompt rápido")
	table.insert(info, "  • <leader>cf - Selecionar arquivos")
	table.insert(info, "  • <leader>ct - Toggle arquivo atual")

	vim.notify(table.concat(info, "\n"), vim.log.levels.INFO)
end

-- Função para prompt com seleção visual
function M.prompt_with_selection()
	local selection = get_visual_selection()
	if selection == "" then
		vim.notify("Nenhuma seleção encontrada", vim.log.levels.WARN)
		return
	end

	-- Abrir chat se não estiver aberto
	if not state.chat_win or not api.nvim_win_is_valid(state.chat_win) then
		create_chat_window()
	end

	-- Criar prompt com contexto da seleção
	local prompt = string.format(
		"Sobre o código selecionado:\n```%s\n%s\n```\n\nO que você gostaria de fazer com este código?",
		vim.bo.filetype,
		selection
	)

	M.process_prompt(prompt)
end

-- Função para prompt rápido
function M.prompt()
	if state.is_processing then
		vim.notify("⏳ Aguarde a resposta anterior...", vim.log.levels.WARN)
		return
	end

	local prompt = fn.input("💬 Prompt: ")
	if prompt == "" then
		return
	end

	-- Mostrar chat se não estiver aberto
	if not state.chat_win or not api.nvim_win_is_valid(state.chat_win) then
		create_chat_window()
	end

	M.process_prompt(prompt)
end

-- Setup do plugin
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	-- Tentar pegar API key do ambiente
	if not M.config.api_key then
		M.config.api_key = vim.env.ANTHROPIC_API_KEY or vim.env.CLAUDE_API_KEY
	end

	-- Criar comandos
	vim.api.nvim_create_user_command("SimpleCursorChat", function()
		M.toggle_chat()
	end, {})
	vim.api.nvim_create_user_command("SimpleCursorPrompt", function()
		M.prompt()
	end, {})
	vim.api.nvim_create_user_command("SimpleCursorSelectFiles", function()
		M.select_files()
	end, {})
	vim.api.nvim_create_user_command("SimpleCursorListFiles", function()
		M.list_selected_files()
	end, {})
	vim.api.nvim_create_user_command("SimpleCursorClearFiles", function()
		M.clear_selected_files()
	end, {})
	vim.api.nvim_create_user_command("SimpleCursorClearChat", function()
		M.clear_chat()
	end, {})
	vim.api.nvim_create_user_command("SimpleCursorToggleCurrentFile", function()
		M.toggle_current_file()
	end, {})
	vim.api.nvim_create_user_command("SimpleCursorInfo", function()
		M.show_info()
	end, {})
	vim.api.nvim_create_user_command("SimpleCursorHelp", function()
		M.show_help()
	end, {})
	vim.api.nvim_create_user_command("SimpleCursorReplaceFile", function()
		M.replace_file_with_last_code()
	end, {})
	vim.api.nvim_create_user_command("SimpleCursorDiffApply", function()
		M.apply_code_with_diff()
	end, {})
	vim.api.nvim_create_user_command("SimpleCursorApplyCode", function()
		if #state.code_blocks > 0 then
			show_code_preview(state.current_code_block or 1)
		else
			vim.notify("Nenhum bloco de código disponível", vim.log.levels.WARN)
		end
	end, {})

	-- Criar atalhos padrão
	local keymaps = {
		{ "n", "<leader>cc", M.toggle_chat, "Toggle Simple Cursor Chat" },
		{ "n", "<leader>cp", M.prompt, "Simple Cursor Prompt" },
		{ "v", "<leader>cp", M.prompt_with_selection, "Prompt with Selection" },
		{ "n", "<leader>cf", M.select_files, "Select Files for Context" },
		{ "n", "<leader>cl", M.list_selected_files, "List Selected Files" },
		{ "n", "<leader>ct", M.toggle_current_file, "Toggle Current File" },
		{ "n", "<leader>ci", M.show_info, "Show Simple Cursor Info" },
		{ "n", "<leader>ch", M.show_help, "Show Simple Cursor Help" },
		{
			"n",
			"<leader>ca",
			function()
				if #state.code_blocks > 0 then
					show_code_preview(1)
				else
					vim.notify("Nenhum bloco de código disponível", vim.log.levels.WARN)
				end
			end,
			"Apply Code from Last Response",
		},
		{ "n", "<leader>cr", M.replace_file_with_last_code, "Replace Entire File with Code" },
		{ "n", "<leader>cd", M.apply_code_with_diff, "Apply Code with Diff Preview" },
	}

	for _, map in ipairs(keymaps) do
		vim.keymap.set(map[1], map[2], map[3], { desc = map[4], noremap = true, silent = true })
	end

	-- Criar highlight groups customizados
	vim.api.nvim_set_hl(0, "SimpleCursorUser", { fg = "#61afef", bold = true })
	vim.api.nvim_set_hl(0, "SimpleCursorAssistant", { fg = "#98c379", bold = true })
	vim.api.nvim_set_hl(0, "SimpleCursorPrompt", { fg = "#c678dd", bold = true })

	-- Notificar que o plugin foi carregado
	if M.config.api_key then
		vim.notify("✨ Simple Cursor carregado com sucesso! Use <leader>cc para abrir o chat.", vim.log.levels.INFO)
	else
		vim.notify(
			"⚠️  Simple Cursor: API key não configurada! Configure com ANTHROPIC_API_KEY ou na setup().",
			vim.log.levels.WARN
		)
	end
end

return M
