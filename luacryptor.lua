local m = {}

function m.cleanSource(src)
    src = src:gsub("function [%w_%.]+%(", "function (")
    src = src:gsub(".*function", "function")
    return src
end

function m.dump(str)
    if not m.numtab then
        m.numtab = {}
        for i = 0, 255 do
            m.numtab[string.char(i)] = ("%3d,"):format(i)
        end
    end
    str = str
        :gsub(".", m.numtab)
        :gsub(("."):rep(60), "%0\n")
    if str:sub(-1, -1) == ',' then
        str = str:sub(1, -2)
    end
    return str
end

function m.undump(str)
    local arr = loadstring('return {' .. str .. '}')()
    local unPack = unpack or table.unpack
    return string.char(unPack(arr))
end

function m.fileContent(fname)
    local f = assert(io.open(fname,"rb"))
    local content = f:read("*a")
    f:close()
    return content
end

function m.dumpFile(fname)
    return m.dump(m.fileContent(fname))
end

function m.encryptFileContent(fname, password)
    local lc = require 'luacryptorext'
    local content = m.fileContent(fname)
    return lc.encrypt(content, password)
end

function m.decryptFileContent(fname, password)
    local lc = require 'luacryptorext'
    local content = m.fileContent(fname)
    return lc.decrypt(content, password)
end

function m.embed_luaopen() return [[
LUALIB_API int luaopen_@modname@(lua_State *L) {
    lua_getfield(L, LUA_REGISTRYINDEX, "__luacryptor_pwd");
    const char* password = lua_tostring(L, -1);
    lua_pop(L, 1);
    if (!password) {
        printf("Set password in register property:\n"
            "debug.getregistry().__luacryptor_pwd = 'pwd'\n");
        return 0;
    }
    const char lua_enc_dump[] = { @lua_enc_dump@ };
    lua_pushcfunction(L, twofish_decrypt);
    lua_pushlstring(L, lua_enc_dump, sizeof(lua_enc_dump));
    lua_pushstring(L, password);
    lua_call(L, 2, 1);
    if (lua_type(L, -1) != LUA_TSTRING) {
        printf("Failed to decrypt Lua source\n");
        return 0;
    }
    size_t orig_size;
    const char* orig = lua_tolstring(L, -1, &orig_size);
    int status = luaL_loadbuffer(L, orig, orig_size,
        "@basename@");
    if (status) {
        printf("%s\n", lua_tostring(L, -1));
        printf("Wrong password?\n");
        lua_pop(L, 2); // orig, error message
        return 0;
    }
    lua_pcall(L, 0, 1, 0);
    return 1; // chunk execution result
}]] end

function m.module_names(fname_lua)
    local fname_c = fname_lua:gsub('.lua$', '.c')
    local basename = fname_lua:gsub('.lua$', '')
    local modname = basename
    modname = modname:gsub('.+/', '')
    modname = modname:gsub('.+\\', '')
    return fname_c, basename, modname
end

function m.embed(fname_lua, password)
    local lua_enc = m.encryptFileContent(fname_lua, password)
    local lua_enc_dump = m.dump(lua_enc)
    local fname_c, basename, modname = m.module_names(fname_lua)
    local f_c = io.open(fname_c, 'w')
    local lc = require 'luacryptorext'
    f_c:write(lc.luacryptorbase)
    local ttt = m.embed_luaopen():gsub('@[%w_]+@', {
        ['@modname@'] = modname,
        ['@basename@'] = basename,
        ['@lua_enc_dump@'] = lua_enc_dump,
    })
    f_c:write(ttt)
    f_c:close()
end

function m.get_lines_of_file(fname)
    local lines = {}
    for line in io.lines(fname) do
        table.insert(lines, line)
    end
    return lines
end

function m.get_source_of_function(name, func, lines)
    local info = debug.getinfo(func)
    local linedefined = info.linedefined
    local lastlinedefined = info.lastlinedefined
    local line1 = m.cleanSource(lines[linedefined])
    assert(line1:find("function") == 1,
        "Can't find start of function " .. name ..
        '. First line is ' .. line1)
    local src = 'return ' .. line1 .. '\n'
    for i = linedefined + 1, lastlinedefined do
        src = src .. lines[i] .. '\n'
    end
    return src
end

function m.encrypt_functions(mod, lines, password, bytecode)
    local lc = require 'luacryptorext'
    local name2enc = {}
    for name, func in pairs(mod) do
        assert(type(func) == 'function',
            'Module must contain only functions!')
        local src = m.get_source_of_function(name, func, lines)
        local upvname, upv = debug.getupvalue(func, 1)
        if upv then
            assert(upv == mod,
                'You can use only module as upvalue')
            assert(not debug.getupvalue(func, 2),
                'You can use only one upvalue (module itself)')
            src = 'local ' .. upvname .. '\n' .. src
        end
        if bytecode then
            src = 'return function() ' .. src .. ' end'
            src = string.dump(loadstring(src))
        end
        local name_enc = lc.sha256(password .. name)
        local src_enc = lc.encrypt(src, password .. name)
        name2enc[name_enc] = src_enc
    end
    return name2enc
end

function m.encrypted_selector(name2enc)
    local t = [[static int luacryptor_get_decrypted(
        lua_State* L) {
    if (!lua_tostring(L, 1)) {
        // Unknown function name
        return 0;
    }
    lua_getfield(L, LUA_REGISTRYINDEX, "__luacryptor_pwd");
    if (lua_type(L, -1) != LUA_TSTRING) {
        printf("Set password in register property:\n"
            "debug.getregistry().__luacryptor_pwd = 'pwd'\n");
        return 0;
    }
    lua_pushvalue(L, 1); // name
    lua_concat(L, 2); // password .. name
    // 2 is password .. name
    if (!lua_tostring(L, 2)) {
        printf("Failed to get final password\n");
        return 0;
    }
    // get sha256(password .. name)
    lua_pushcfunction(L, lua_calc_sha256);
    lua_pushvalue(L, 2); /* password .. name */
    lua_call(L, 1, 1);
    // 3 is sha256(password .. name)
    size_t name_hash_size;
    const char* name_hash =
        lua_tolstring(L, 3, &name_hash_size);
    if (!name_hash || name_hash_size != 32) {
        printf("Failed to get encrypted name\n");
        return 0;
    }
    ]]
    local i = 0
    for name, src_enc in pairs(name2enc) do
        i = i + 1
        local tt = [[
        const char nn@i@[] = { @dump(name)@ };
        if (memcmp(name_hash, nn@i@, 32) == 0) {
            const char cc[] = { @dump(src_enc)@ };
            lua_pushcfunction(L, twofish_decrypt);
            lua_pushlstring(L, cc, sizeof(cc));
            lua_pushvalue(L, 2); /* password .. name */
            lua_call(L, 2, 1);
            return 1;
        } ]]
        t = t .. tt:gsub('@[%w_#()]+@', {
            ['@i@'] = i,
            ['@dump(name)@'] = m.dump(name),
            ['@dump(src_enc)@'] = m.dump(src_enc),
        })
    end
    t = t .. 'return 0; }'
    return t
end

function m.enc_func_luaopen() return [[
static int enc_func_call(lua_State* L) {
    int argc = lua_gettop(L);
    lua_pushcfunction(L, luacryptor_get_decrypted);
    lua_getfield(L, 1, "name");
    int s = lua_pcall(L, 1, 1, 0);
    if (s) {
        printf("%s\n", lua_tostring(L, -1));
        printf("Failed to decrypt Lua source\n");
        return 0;
    }
    if (lua_type(L, -1) != LUA_TSTRING) {
        printf("Failed to decrypt Lua source\n");
        return 0;
    }
    // load
    size_t orig_size;
    const char* orig = lua_tolstring(L, -1, &orig_size);
    int status = luaL_loadbuffer(L, orig, orig_size,
        "@basename@");
    if (status) {
        printf("%s\n", lua_tostring(L, -1));
        printf("Wrong password?\n");
        return 0;
    }
    @bytecode@lua_pcall(L, 0, 1, 0); // get wrapper
    lua_pcall(L, 0, 1, 0); // get original function
    // pass module as first upvalue
    lua_getfield(L, 1, "module");
    if (lua_setupvalue(L, -2, 1) == 0) {
         // no upvalues here
         lua_pop(L, 1);
    }
    // mark stack index before orig
    int marker;
    lua_pushlightuserdata(L, &marker);
    // push orig func and its args
    lua_pushvalue(L, -2);
    int i;
    for (i = 2; i <= argc; i++) {
        lua_pushvalue(L, i);
    }
    lua_pcall(L, argc - 1, LUA_MULTRET, 0); // call orig func
    int results = 0;
    int last_index = -1;
    while (lua_touserdata(L, last_index) != &marker) {
        results += 1;
        last_index -= 1;
    }
    return results;
}

static int enc_func_index(lua_State* L) {
    lua_pushcfunction(L, luacryptor_get_decrypted);
    lua_pushvalue(L, -2); // name
    lua_pcall(L, 1, 1, 0);
    if (lua_type(L, -1) != LUA_TSTRING) {
        return 0;
    }
    lua_pop(L, 1); // remove decrypted function
    // name is -1
    lua_newtable(L); // function
    lua_pushvalue(L, -2); // name
    lua_setfield(L, -2, "name"); // function.name = name
    lua_pushvalue(L, 1); // module
    lua_setfield(L, -2, "module"); // function.module = module
    lua_newtable(L); // metatable
    lua_pushcfunction(L, enc_func_call);
    lua_setfield(L, -2, "__call");
    lua_setmetatable(L, -2);
    return 1; // function table
}

LUALIB_API int luaopen_@modname@(lua_State *L) {
    lua_newtable(L); // module
    lua_newtable(L); // metatable
    lua_pushcfunction(L, enc_func_index);
    lua_setfield(L, -2, "__index");
    lua_setmetatable(L, -2);
    return 1; // module table
}]] end

function m.encfunc(fname_lua, password, bytecode)
    local mod = assert(loadfile(fname_lua))()
    local lines = m.get_lines_of_file(fname_lua)
    local name2enc = m.encrypt_functions(mod, lines, password,
        bytecode)
    local encrypted_selector = m.encrypted_selector(name2enc)
    local fname_c, basename, modname = m.module_names(fname_lua)
    local f_c = io.open(fname_c, 'w')
    local lc = require 'luacryptorext'
    f_c:write(lc.luacryptorbase)
    f_c:write(encrypted_selector)
    local ttt = m.enc_func_luaopen():gsub('@[%w_]+@', {
        ['@modname@'] = modname,
        ['@basename@'] = basename,
        ['@bytecode@'] = bytecode and ' ' or '//',
    })
    f_c:write(ttt)
    f_c:close()
end

function m.build(cfile, binfile, ext)
    if binfile and binfile:sub(-1) == '/' then
        local cfile1 = cfile:gsub('.+/', '')
        binfile = binfile .. cfile1:gsub('.c$', '.' .. ext)
    elseif not binfile then
        binfile = cfile:gsub('.c$', '.' .. ext)
    end
    local headers = '/usr/include/lua5.1/'
    local lib = 'lua5.1'
    local cmd = 'cc %s -o %s -I . -I %s -l%s'
    if ext == 'so' then
        cmd = cmd .. ' -shared -fpic'
    end
    os.execute(string.format(cmd, cfile, binfile, headers, lib))
end

function m.buildso(cfile, sofile)
    m.build(cfile, sofile, 'so')
end

function m.buildexe(cfile, exefile)
    m.build(cfile, exefile, 'exe')
end

return m

