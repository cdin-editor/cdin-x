-- Ex-command line tokenizer.
--
-- Splits the text typed after ":" into a command name and arguments,
-- honouring single and double quotes so paths with spaces survive:
--   :rename "my file.txt" other.txt
--     -> "rename", "my file.txt", "other.txt"
--
-- A backslash escapes the next character inside quotes, which is what
-- makes a Windows path like "C:\dir\" pass through intact.
local M = {}

function M.tokenize(s)
  local tokens = {}
  local i = 1
  while i <= #s do
    while i <= #s and s:sub(i, i):match("%s") do i = i + 1 end
    if i > #s then break end
    local ch = s:sub(i, i)
    if ch == '"' or ch == "'" then
      local quote = ch
      i = i + 1
      local start = i
      while i <= #s and s:sub(i, i) ~= quote do
        if s:sub(i, i) == "\\" then i = i + 1 end
        i = i + 1
      end
      tokens[#tokens + 1] = s:sub(start, i - 1)
      i = i + 1
    else
      local start = i
      while i <= #s and not s:sub(i, i):match("%s") do i = i + 1 end
      tokens[#tokens + 1] = s:sub(start, i - 1)
    end
  end
  return tokens
end

return M
