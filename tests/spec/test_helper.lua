-- test_helper.lua
-- Common test utilities and setup

local M = {}

-- Mock vim global if not in Neovim environment
if not vim then
    _G.vim = {
        api = {
            nvim_create_namespace = function() return 1 end,
            nvim_set_hl = function() end,
            nvim_buf_is_valid = function() return true end,
            nvim_win_is_valid = function() return true end,
            nvim_buf_line_count = function() return 10 end,
            nvim_buf_get_lines = function() return {} end,
            nvim_buf_set_lines = function() end,
            nvim_buf_set_option = function() end,
            nvim_create_buf = function() return 1 end,
            nvim_open_win = function() return 1 end,
            nvim_win_set_option = function() end,
            nvim_get_current_buf = function() return 1 end,
            nvim_create_augroup = function() return 1 end,
            nvim_create_autocmd = function() end,
            nvim_create_user_command = function() end,
            nvim_buf_add_highlight = function() end,
        },
        fn = {
            fnamemodify = function(path, mod)
                if mod == ":t" then
                    return path:match("([^/\\]+)$") or path
                elseif mod == ":e" then
                    return path:match("%.([^.]+)$") or ""
                elseif mod == ":p" then
                    return path
                elseif mod == ":~:." then
                    return path
                end
                return path
            end,
            tempname = function() return "/tmp/test_" .. os.time() end,
            json_encode = function(t) return vim.inspect(t) end,
            json_decode = function(s) return { content = {{ text = s }} } end,
            jobstart = function() return 1 end,
            timer_start = function() return 1 end,
            timer_stop = function() end,
            expand = function() return "test.lua" end,
            filereadable = function() return 1 end,
            confirm = function() return 1 end,
            input = function() return "test input" end,
            inputlist = function() return 1 end,
        },
        log = {
            levels = {
                INFO = 1,
                WARN = 2,
                ERROR = 3,
            }
        },
        env = {},
        o = {
            lines = 40,
            columns = 120,
        },
        bo = {
            filetype = "lua"
        },
        inspect = function(t) return tostring(t) end,
        split = function(str, sep)
            local result = {}
            for match in (str..sep):gmatch("(.-)"..sep) do
                table.insert(result, match)
            end
            return result
        end,
        tbl_deep_extend = function(behavior, ...)
            local result = {}
            for _, tbl in ipairs({...}) do
                for k, v in pairs(tbl) do
                    if type(v) == "table" and type(result[k]) == "table" then
                        result[k] = vim.tbl_deep_extend(behavior, result[k], v)
                    else
                        result[k] = v
                    end
                end
            end
            return result
        end,
        tbl_contains = function(t, value)
            for _, v in ipairs(t) do
                if v == value then return true end
            end
            return false
        end,
        deepcopy = function(t)
            if type(t) ~= 'table' then return t end
            local copy = {}
            for k, v in pairs(t) do
                copy[k] = vim.deepcopy(v)
            end
            return copy
        end,
        notify = function() end,
        cmd = function() end,
        defer_fn = function(fn) fn() end,
        wait = function() return true end,
        schedule = function(fn) fn() end,
    }
end

-- Mock file system operations
M.mock_fs = {
    files = {},
    
    set_file = function(path, content)
        M.mock_fs.files[path] = content
    end,
    
    read_file = function(path)
        return M.mock_fs.files[path]
    end,
    
    clear = function()
        M.mock_fs.files = {}
    end
}

-- Override io.open for tests
local original_io_open = io.open
M.setup_fs_mock = function()
    io.open = function(path, mode)
        -- Only mock files that we've explicitly set in our mock filesystem
        -- This prevents interfering with luarocks and other system files
        if mode == "r" then
            local content = M.mock_fs.files[path]
            if content then
                return {
                    read = function() return content end,
                    close = function() end
                }
            end
        elseif mode == "w" then
            -- Only mock write operations for our test files and temp files
            if M.mock_fs.files[path] ~= nil or path:match("^/test/") or path:match("^/tmp/") then
                return {
                    write = function(_, content)
                        M.mock_fs.files[path] = content
                    end,
                    close = function() end
                }
            end
        end
        -- Fall back to original io.open for all other files
        return original_io_open(path, mode)
    end
end

M.teardown_fs_mock = function()
    io.open = original_io_open
    M.mock_fs.clear()
end

return M
