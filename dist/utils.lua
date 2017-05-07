local pl = require "pl.import_into"()

local utils = {}

-- Obtain LuaDist location by checking available package locations
function utils.get_luadist_location()
  local paths = {}
  package.path:gsub("([^;]+)", function(c) table.insert(paths, c) end)

  for _, curr_path in pairs(paths) do
    if (pl.path.isabs(curr_path) and curr_path:find("[/\\]lib[/\\]lua[/\\]%?.lua$")) then
      -- Remove path to lib/lua
      curr_path = curr_path:gsub("[/\\]lib[/\\]lua[/\\]%?.lua$", "")
      -- Clean the path up a bit
      curr_path = curr_path:gsub("[/\\]bin[/\\]%.[/\\]%.%.", "")
      curr_path = curr_path:gsub("[/\\]bin[/\\]%.%.", "")
      return curr_path
    end
  end
  return nil
end

-- Return string argument quoted for a command line usage
function utils.quote(argument)
    assert(type(argument) == "string", "utils.quote: Argument 'argument' is not a string.")

    -- replace '/' path separators for '\' on Windows
    if pl.path.is_windows and argument:match("^[%u%U.]?:?[/\\].*") then
        argument = argument:gsub("//","\\"):gsub("/","\\")
    end

    -- Windows doesn't recognize paths starting with two slashes or backslashes
    -- so we double every backslash except for the first one
    if pl.path.is_windows and argument:match("^[/\\].*") then
        local prefix = argument:sub(1,1)
        argument = argument:sub(2):gsub("\\",  "\\\\")
        argument = prefix .. argument
    else
        argument = argument:gsub("\\",  "\\\\")
    end
    argument = argument:gsub('"',  '\\"')

    return '"' .. argument .. '"'
end

-- Returns true if 'pkg_name' partially (or fully if 'full_match' is specified)
-- matches at least one provided string in table 'strings', returns true if table 'strings' is empty
function utils.name_matches(pkg_name, strings, full_match)
    if strings == nil or #strings == 0 then
        return true
    end

    if type(strings) == "string" then
        strings = {strings}
    end

    assert(type(pkg_name) == "string", "utils.name_matches: Argument 'pkg_name' is not a string.")
    assert(type(strings) == "table", "utils.name_matches: Argument 'strings' is not a string or table.")

    for _, str in pairs(strings) do
        if (full_match == nil and pkg_name:find(str) ~= nil) or pkg_name == str then
            return true
        end
    end

    return false
end

function utils.generate_config()
  local result = [[#include "lua.h"
#include "lauxlib.h"

@SLUA_LUAOPEN@

static const luaL_Reg slua_preloadedlibs[] = {
@SLUA_PRELOADEDLIBS@
  {NULL, NULL}
};


LUALIB_API void sluaL_openlibs (lua_State *L) {
  const luaL_Reg *lib;
  /* add open functions from 'preloadedlibs' into 'package.preload' table */
  luaL_getsubtable(L, LUA_REGISTRYINDEX, "_PRELOAD");
  for (lib = slua_preloadedlibs; lib->func; lib++) {
    lua_pushcfunction(L, lib->func);
    lua_setfield(L, -2, lib->name);
  }
  lua_pop(L, 1);  /* remove _PRELOAD table */
}

]]

  return result

end

-- generator for main CMakeLists.txt file in static build
function utils.generate_cmakelist(modules)
  local result = [[# Copyright (C) 2017 LuaDist

cmake_minimum_required(VERSION 3.4)
project(lua_static)

# Basic lua 
set( LUA_LIBRARY "liblua" CACHE STRING "Lua library location" FORCE )
set( LUA_INCLUDE_DIR "${CMAKE_CURRENT_BINARY_DIR}/lua" "${CMAKE_CURRENT_SOURCE_DIR}/lua/src" CACHE STRING "Lua include location" FORCE )
set( ZLIB_LIBRARY "libzlib" CACHE STRING "Zlib library location" FORCE )
set( ZLIB_INCLUDE_DIR "${CMAKE_CURRENT_BINARY_DIR}/Zlib" "${CMAKE_CURRENT_SOURCE_DIR}/Zlib/src" CACHE STRING "Zlib include location" FORCE )
]]

  -- set dist/lua2c/lua path
  local path = pl.text.Template[[set (DIST_PATH "${path}" CACHE STRING "" FORCE)
]]
  result = result .. path:substitute({path = utils.get_luadist_location()})

  -- Prepare list of dists from dists_modules
  local dists = "DISTS"
  for _, pkg in pairs(modules) do
    dists = dists .. '\n "' .. pkg.name .. '"'
  end

  local set_dist = pl.text.Template[[set ( ${dists} 
) 
]]
  result = result .. set_dist:substitute({dists = dists})
  result = result .. [[
find_program(LUA lua PATHS ${DIST_PATH}/bin NO_DEFAULT_PATH)
if(NOT LUA)
    message(FATAL_ERROR "lua not found!")
endif()
find_program(BIN bin2c.lua PATHS ${DIST_PATH}/lib/lua NO_DEFAULT_PATH)
if(NOT BIN)
    message(FATAL_ERROR "bin2c not found!")
endif()

set(LUA_BUILD_AS_DLL OFF)

foreach ( MODULE IN ITEMS ${DISTS})
 add_subdirectory(${MODULE} EXCLUDE_FROM_ALL)
endforeach ()

foreach(module ${LUA_STATIC_MODULES})
  message(STATUS ${module})
  string(REPLACE "." "_" module_name ${module})
  string(CONCAT SLUA_LUAOPEN "${SLUA_LUAOPEN}" "extern int luaopen_${module_name}(lua_State *L);\n")
  string(CONCAT SLUA_PRELOADEDLIBS "${SLUA_PRELOADEDLIBS}" "  {\"${module}\", luaopen_${module_name}},\n")
endforeach()

configure_file(modules.c.in modules.c @ONLY)

add_library(libslua STATIC ${CMAKE_CURRENT_BINARY_DIR}/modules.c)
set_target_properties (libslua PROPERTIES OUTPUT_NAME slua CLEAN_DIRECT_OUTPUT 1 )
target_link_libraries(libslua liblua ${LUA_STATIC_LIB_MODULES})
target_include_directories(libslua PUBLIC lua/src ${CMAKE_CURRENT_BINARY_DIR}/lua)
#target_compile_definitions(libslua PRIVATE -DLUA_USERCONFIG="modules.h")

add_executable(slua lua.c)
target_link_libraries(slua libslua)
]]

  return result

end

return utils


--[[

foreach(module ${LUA_STATIC_MODULES})
  message(STATUS ${module})
  string(REPLACE "." "_" module_name ${module})
  string(CONCAT SLUA_LUAOPEN "${SLUA_LUAOPEN}" "extern int luaopen_${module_name}(lua_State *L);\n")
  string(CONCAT SLUA_PRELOADEDLIBS "${SLUA_PRELOADEDLIBS}" "  {\"${module}\", luaopen_${module_name}},\n")
endforeach()

]]--
