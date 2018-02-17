-- this script is meant to be executed with a Lua executable within standard LuaDist
-- directory structure

local pl = require "pl.import_into"()

local lua_command = pl.path.abspath(arg[-1])
local luadist_root = pl.path.normpath(pl.path.join(lua_command, "../.."))
local luadist_lib_path = pl.path.normpath(pl.path.join(luadist_root, "lib/lua/luadist.lua"))

current_directory = pl.path.currentdir()

target_directory = pl.path.join(current_directory, "_testdir")
target_lua_command = pl.path.join(target_directory, "bin/lua")

luadist_command_no_target = lua_command .. " " .. luadist_lib_path
luadist_command = luadist_command_no_target .. " " .. target_directory

local help_text = [[
Usage: ./lua test.lua <COMMAND>

Where <COMMAND> is one of the following:
]]

function print_help()
    print(help_text)

    local longest = 0
    for _, v in pairs(commands) do
        if #v.name > longest then
            longest = #v.name
        end
    end

    for _, v in pairs(commands) do
        io.write("    " .. v.name)
        for i = #v.name + 1, longest do
            io.write(" ")
        end
        print(" - " .. v.description)
    end

    return 0
end

commands = {
    {
        name = "help",
        description = "print this help",
        run = print_help
    },
    {
        name = "clean",
        description = "removes the target directory (" .. target_directory .. ")",
        run = function ()
            return run_clean()
        end
    },
    {
        name = "install",
        description = "test the install command",
        run = function ()
            return run_install()
        end
    },
    {
        name = "install_luadist",
        description = "test installing LuaDist itself (contains Lua version enforcement logic)",
        run = function ()
            return run_install_luadist()
        end
    },
    {
        name = "make",
        description = "test the make command",
        run = function ()
            return run_make()
        end
    },
    {
        name = "make_luadist",
        description = "test the make command on LuaDist2",
        run = function ()
            return run_make_luadist()
        end
    },
}

function run_clean()
    if pl.path.exists(target_directory) then
        print("== Removing directory " .. target_directory)
        pl.dir.rmtree(target_directory)
    end

    pl.utils.execute(luadist_command_no_target .. " remove xml lub")

    return 0
end

function run_install()
    local packages = "xml luacheck"
    local to_remove = packages .. " lub luafilesystem"

    if pl.path.exists(target_directory) then
        print("== Cleaning up, removing packages " .. to_remove)
        pl.utils.execute(luadist_command .. " remove " .. to_remove)

        for pkg in packages:gmatch("%S+") do
            print("== Trying to require '" .. pkg .. "', this attempt should fail...")
            local ok, code = pl.utils.execute(target_lua_command .. " -e 'require \"" .. pkg .. "\"'")
            if ok then
                print("== Error: Require '" .. pkg .. "' was successful even if it shouldn't be there.")
                return 1
            end
        end
        print("== Success!")
    end

    print("== Installing '" .. packages .. "'")
    local ok, code = pl.utils.execute(luadist_command .. " install " .. packages)
    if not ok then
        return code
    end

    pl.path.chdir(target_directory)

    for pkg in packages:gmatch("%S+") do
        print("== Trying to require '" .. pkg .. "'...")
        local ok, code = pl.utils.execute(target_lua_command .. " -e 'require \"" .. pkg .. "\"'")
        if not ok then
            return code
        end
    end

    print("== Success!")
    return 0
end

function run_install_luadist()
    local package = "luadist2"

    if pl.path.exists(target_directory) then
        print("== Cleaning up, removing '" .. target_directory .. "' directory")
        pl.dir.rmtree(target_directory)
    end

    print("== Installing package '" .. package .. "'")
    local ok, code = pl.utils.execute(luadist_command .. " install " .. package)
    if not ok then
        return code
    end

    local ok, code = pl.utils.execute(target_lua_command .. " -e 'require \"socket\"'")
    if not ok then
        return code
    end

    print("== Success!")
    return 0
end

local function make_helper(url, dest_dir, require_pkg)
    if pl.path.exists(target_directory) then
        print("== Directory '" .. target_directory .. "' exists, deleting...")
        local ok, code = pl.utils.execute("rm -r " .. target_directory)
        if not ok then
            print("== Deleting failed")
            return code
        end
    end

    print("== Copying LuaDist into '" .. target_directory .. "'")
    -- FIXME: ugly
    -- create a clone of a functional LuaDist install so we won't interfere with anything else
    local ok, code = pl.utils.execute("cp -r " .. luadist_root .. " " .. target_directory)
    if not ok then
        print("== Something went wrong while cloning LuaDist")
        return code
    end

    if pl.path.exists(dest_dir) then
        print("== Directory '" .. dest_dir .. "' exists, deleting...")
        pl.dir.rmtree(dest_dir)
    end

    print("== Cloning '" .. url .. "'")
    local ok, code = pl.utils.execute("GIT_TERMINAL_PROMPT=0 git clone --depth 1 " .. url .. " " .. dest_dir)
    if not ok then
        return code
    end

    local luadist_exec =
        pl.path.join(target_directory, "bin/lua") .. " " ..
        pl.path.join(target_directory, "lib/lua/luadist.lua")

    print("== Running 'luadist make' from '" .. dest_dir .. "'")
    local original_dir = current_directory
    pl.path.chdir(dest_dir)
    pl.utils.execute(luadist_exec .. " make")
    pl.path.chdir(original_dir)

    print("== Trying to require '" .. require_pkg .. "'...")
    local ok, code = pl.utils.execute(target_lua_command .. " -e 'require \"" .. require_pkg .. "\"'")
    if not ok then
        return code
    end

    print("== Running 'luadist list' - see if everything is in there")
    pl.utils.execute(luadist_exec .. " list")
    return 0
end

function run_make()
    local url = "https://github.com/LuaDist2/xml"
    local dest_dir = "./xml"
    dest_dir = pl.path.normpath(pl.path.join(current_directory, dest_dir))

    return make_helper(url, dest_dir, "xml")
end

function run_make_luadist()
    local url = "https://github.com/LuaDist-core/luadist2"
    local dest_dir = "./luadist2"
    dest_dir = pl.path.normpath(pl.path.join(current_directory, dest_dir))

    return make_helper(url, dest_dir, "socket")
end

local function call_command(name)
    if not name then
        name = "help"
    end

    for _, cmd in ipairs(commands) do
        if cmd.name == name then
            if cmd.name ~= "help" then
                print("=== Running command '" .. cmd.name .. "'")
            end
            local code = cmd.run()
            return true, code
        end
    end

    return false, 0
end

local ok, code = call_command(arg[1])
if not ok then
    if arg[1] then
        print("Unrecognized command: " .. arg[1])
        print_help()
        return 1
    end
end

return code

