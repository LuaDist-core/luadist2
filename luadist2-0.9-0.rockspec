package = "luadist2"
version = "0.9-0"
source = {
    tag = "0.9-0",
    url = "git://github.com/LuaDist-core/luadist2.git"
}
description = {
    summary = "Lua package manager",
    homepage = "https://github.com/f4rnham/luadist2.git",
    license = "MIT"
}
dependencies = {
    "lua >= 5.1",
    "lualogging >= 1.3.0-1",
    "rocksolver >= 0.4-1",
    "rockspec2cmake >= 0.1-1",
    "penlight >= 1.4.1",
    "lua-git >= 0.5-1",
    "lua2c >= 0.1-1",
}
build = {
    type = "cmake",
}
