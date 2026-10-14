local IS_WIN = PATHSEP == "\\"
local SYSTEM = rawget(_G, "system")
local cached = nil
local M = {}

local function join(directory, name)
  if directory:sub(-1) == "/" or directory:sub(-1) == "\\" then
    return directory .. name
  end
  return directory .. (IS_WIN and "\\" or "/") .. name
end

local function quote(path)
  if IS_WIN then return '"' .. path:gsub('"', '\\"') .. '"' end
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

local function file_exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local function capture(command)
  if type(SYSTEM) == "table" and type(SYSTEM.popen) == "function" then
    local ok, result = pcall(SYSTEM.popen, command)
    if ok then
      if type(result) == "string" and result ~= "" then return result end
      local kind = type(result)
      if kind == "table" or kind == "userdata" then
        local read_ok, output = pcall(function() return result:read("*a") end)
        pcall(function() result:close() end)
        if read_ok and type(output) == "string" and output ~= "" then
          return output
        end
      end
    end
  end

  if type(io.popen) ~= "function" then return nil end
  local null = IS_WIN and " 2>NUL" or " 2>/dev/null"
  local ok, pipe = pcall(io.popen, command .. null, "r")
  if not ok or not pipe then return nil end
  local read_ok, output = pcall(function() return pipe:read("*a") end)
  pcall(function() pipe:close() end)
  if not read_ok or type(output) ~= "string" then return nil end
  return output
end

local function candidates()
  local paths, seen = {}, {}
  local function add(path)
    if type(path) ~= "string" then return end
    path = path:gsub("^%s+", ""):gsub("%s+$", "")
    if path:sub(1, 1) == '"' and path:sub(-1) == '"' then path = path:sub(2, -2) end
    if path == "" then return end
    local key = IS_WIN and path:lower() or path
    if seen[key] then return end
    seen[key] = true
    paths[#paths + 1] = path
  end

  local path = os.getenv("PATH") or ""
  local separator = IS_WIN and ";" or ":"
  for entry in (path .. separator):gmatch("(.-)" .. separator) do
    local directory = entry
    directory = directory:gsub("^%s+", ""):gsub("%s+$", "")
    if directory:sub(1, 1) == '"' and directory:sub(-1) == '"' then
      directory = directory:sub(2, -2)
    end
    if directory ~= "" and directory ~= "." then
      if IS_WIN then
        add(join(directory, "git.exe"))
      else
        add(join(directory, "git"))
      end
    end
  end

  if IS_WIN then
    local program_files = os.getenv("ProgramFiles") or "C:/Program Files"
    local program_files_x86 = os.getenv("ProgramFiles(x86)") or "C:/Program Files (x86)"
    for _, base in ipairs({ program_files, program_files_x86 }) do
      add(join(join(base, "Git"), "cmd\\git.exe"))
      add(join(join(base, "Git"), "bin\\git.exe"))
    end
    local local_app_data = os.getenv("LOCALAPPDATA")
    if local_app_data then add(join(join(local_app_data, "Programs\\Git"), "cmd\\git.exe")) end
    local home = os.getenv("USERPROFILE")
    if home then
      add(join(join(home, "scoop\\apps\\git\\current"), "cmd\\git.exe"))
      add(join(join(home, "scoop\\apps\\git\\current"), "bin\\git.exe"))
    end
    local chocolatey = os.getenv("ChocolateyInstall") or "C:/ProgramData/chocolatey"
    add(join(chocolatey, "bin\\git.exe"))
    add("C:/msys64/usr/bin/git.exe")
    add("C:/msys64/mingw64/bin/git.exe")
  else
    for _, path in ipairs({
      "/usr/bin/git", "/bin/git", "/usr/local/bin/git", "/usr/local/git/bin/git",
      "/opt/homebrew/bin/git", "/opt/local/bin/git", "/nix/var/nix/profiles/default/bin/git",
      "/home/linuxbrew/.linuxbrew/bin/git",
    }) do
      add(path)
    end
    local home = os.getenv("HOME")
    if home then
      add(join(join(home, ".local/bin"), "git"))
      add(join(join(home, "bin"), "git"))
      add(join(join(home, ".nix-profile/bin"), "git"))
      add(join(join(home, ".linuxbrew/bin"), "git"))
    end
  end

  return paths
end

function M.find()
  if cached then return cached end
  local checked = false
  local last_error = nil
  for _, path in ipairs(candidates()) do
    if file_exists(path) then
      checked = true
      local output = capture(quote(path) .. " --version")
      if output and output:find("git version", 1, true) then
        cached = quote(path)
        return cached
      end
      last_error = output and output:sub(1, 200) or "could not run git --version"
    end
  end
  cached = nil
  local reason = "Git was not found in PATH or common installation locations"
  if checked then reason = last_error end
  return false, reason
end

return M
