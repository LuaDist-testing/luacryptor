-- This file was automatically generated for the LuaDist project.

package = "luacryptor"
version = "1.0-1"
-- LuaDist source
source = {
  tag = "1.0-1",
  url = "git://github.com/LuaDist-testing/luacryptor.git"
}
-- Original source
-- source = {
--     url = "https://github.com/starius/luacryptor/" ..
--         "releases/download/0.1/luacryptor-1.0.tar.gz"
-- }
description = {
    summary =
        "Convert Lua file to C file " ..
        "with all functions encrypted",
    detailed = [[
    Luacryptor creates .c file, which can be compiled into
    binary library. Loading this library into Lua works as if
    original Lua module was loaded. Loading requires password.
    ]],
    homepage = "https://github.com/starius/luacryptor",
    license = "GPL-2+"
}
dependencies = {
    "lua ~> 5.1"
}
build = {
    type = "builtin",
    modules = {
        luacryptor = "luacryptor.lua",

        luacryptorext = "luacryptorext.c",
    },
    install = {
        bin = { "luacryptor" }
    },
}
