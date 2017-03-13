local log = require "dist.log".logger
local cfg = require "dist.config"
local git = require "dist.git"
local utils = require "dist.utils"
local ordered = require "dist.ordered"
local pl = require "pl.import_into"()
local rocksolver = {}
rocksolver.const = require "rocksolver.constraints"

local manifest_module = {}

-- Return the joined manifest table from 'cfg.manifest_repos' locations
local manifest = nil
function manifest_module.get_manifest()
    -- Download manifest if this is first time we are requesting it in this run,
    -- otherwise it is cached in memory until luadist is terminated
    if manifest == nil then
        manifest, err = manifest_module.download_manifest(cfg.manifest_repos)
        if not manifest then
            return nil, "Error downloading manifest: " .. err
        end
    end

    return manifest
end

-- Download manifest from the table of git 'manifest_urls' and return manifest
-- table on success and nil and error message on error.
function manifest_module.download_manifest(manifest_urls)
    manifest_urls = manifest_urls or cfg.manifest_repos
    if type(manifest_urls) == "string" then manifest_urls = {manifest_urls} end

    assert(type(manifest_urls) == "table", "manifest.download_manifest: Argument 'manifest_urls' is not a table or string.")

    -- Retrieve manifests from repositories and collect them into one manifest table
    local manifest = {repo_path = {}, packages = {}}

    if #manifest_urls == 0 then
        return nil, "No manifest url specified."
    end

    log:info("Downloading manifest information...")
    for k, repo in pairs(manifest_urls) do

        if manifest_module.is_remote(repo) then
            clone_dir = pl.path.join(cfg.temp_dir_abs, "manifest_" .. tostring(k))

            -- Clone the repo and add its 'manifest-file' file to the manifest table
            ok, err = git.create_repo(clone_dir)

            local sha
            if ok then sha, err = git.fetch_branch(clone_dir, repo, "master") end
            if sha then ok, err = git.checkout_sha(sha, clone_dir) end

            if not (ok and sha) then
                if not cfg.debug then
                    pl.dir.rmtree(clone_dir)
                end

                return nil, "Could not download manifest from repository with url: '" .. repo .. "': " .. err
            end

            local manifest_file = pl.path.join(clone_dir, cfg.manifest_filename)
            current_manifest, err = manifest_module.load_manifest(manifest_file)
        elseif cfg.include_local_repos then
            current_manifest, err = manifest_module.generate_local_manifest(repo)
        else
            err = "Local repos are disabled."
        end

        if current_manifest then
            -- Merge manifest.package tables on first two levels (package name and version)
            -- Note: Don't use pl.tablex.merge because it would merge even dependencies if the same
            -- package version is present in two different manifests, we want to keep dependencies
            -- from manifest earlier in 'manifest_urls'
            for pkg, info in pairs(current_manifest.packages) do
                -- Current manifest provides new package, add it
                if manifest.packages[pkg] == nil then
                    manifest.packages[pkg] = info
                -- Add all versions which were not present in earlier manifests
                else
                    for version, deps in pairs(info) do
                        if manifest.packages[pkg][rocksolver.const.parseVersion(version).string] == nil then
                            manifest.packages[pkg][version] = deps
                        end
                    end
                end
            end

            table.insert(manifest.repo_path, current_manifest.repo_path)
        else
            return nil, "Could not load manifest from repository with url: '" .. repo .. "': " .. err
        end

        if not cfg.debug and manifest_module.is_remote(repo) then
            pl.dir.rmtree(clone_dir)

        end
    end
    -- Save the new manifest table to file for debug purposes
    if cfg.debug then
        pl.pretty.dump(manifest, pl.path.join(cfg.temp_dir_abs, cfg.manifest_filename))
    end

    return manifest
end

-- Load (by using provided 'load_fnc') and return table
-- from lua file 'filename', if file is not present, return nil.
local function load_file(filename, load_fnc)
    local fd, err = io.open(filename)
    if not fd then
        return nil, err
    end
    local str, err = fd:read("*all")
    fd:close()
    if not str then
        return nil, err
    end

    -- Remove "#!/usr/bin lua" like lines since they are not valid Lua
    -- but seem to be present in rockspec files
    str = str:gsub("^#![^\n]*\n", "")
    str = str:gsub("\n#![^\n]*\n", "")
    return load_fnc(str)
end

-- FIXME
-- Copy of pl.pretty.read with 'function' check commented out
local function save_global_env()
    local env = {}
    env.hook, env.mask, env.count = debug.gethook()
    debug.sethook()
    env.string_mt = getmetatable("")
    debug.setmetatable("", nil)
    return env
end

local function restore_global_env(env)
    if env then
        debug.setmetatable("", env.string_mt)
        debug.sethook(env.hook, env.mask, env.count)
    end
end

local function pretty_read(s)
    pl.utils.assert_arg(1,s,'string')
    if s:find '^%s*%-%-' then -- may start with a comment..
        s = s:gsub('%-%-.-\n','')
    end
    if not s:find '^%s*{' then return nil,"not a Lua table" end
    --[[if s:find '[^\'"%w_]function[^\'"%w_]' then
        local tok = lexer.lua(s)
        for t,v in tok do
            if t == 'keyword' and v == 'function' then
                return nil,"cannot have functions in table definition"
            end
        end
    end]]
    s = 'return '..s
    local chunk,err = pl.utils.load(s,'tbl','t',{})
    if not chunk then return nil,err end
    local global_env = save_global_env()
    local ok,ret = pcall(chunk)
    restore_global_env(global_env)
    if ok then return ret
    else
        return nil,ret
    end
end

-- Load and return manifest table from the manifest file,
-- if manifest file is not present, return nil.
function manifest_module.load_manifest(manifest_file)
    return load_file(manifest_file, pretty_read) --pl.pretty.read
end

-- Load and return rockspec table from the rockspec file,
-- if rockspec file is not present, return nil.
function manifest_module.load_rockspec(rockspec_file)
    return load_file(rockspec_file, pl.pretty.load)
end

-- Creates local manifest table, which has the same format as manifests from the remote repository.
-- Manifest contains all packages present in the deploy_dir. Function is searching for .rockspec files in all
-- subdirectories of deploy_dir, but only 1 level deep.
-- returns manifest table
function manifest_module.generate_local_manifest(deploy_dir)

    -- Get all subdirectories
    local subdirectories = pl.dir.getdirectories(deploy_dir)

    local local_manifest = {}

    local_manifest.packages = {}
    local local_rockspec_files = {}

    -- get all 'rockspec' files in 'cfg.root_dir' subdirectories,
    -- searching only 1 level deep.
    for _ ,subdir in pairs(subdirectories) do
        local rockspec_files = pl.dir.getfiles(subdir, "*.rockspec")
        for _ ,rockspec in pairs(rockspec_files) do
            table.insert(local_rockspec_files, rockspec)
        end
    end

    local packages_in_manifest = {}

    -- Iterate through all found rockspecs
    for _, local_rockspec_file in pairs(local_rockspec_files) do

        local local_rockspec, err = manifest_module.load_rockspec(local_rockspec_file)

        if not local_rockspec then
            log:error("Local rockspec "..local_rockspec_file.." could not be loaded: ".. err)
        else
            -- Fetch info about the package from the rockspec
            local pkg_name = local_rockspec.package

            local pkg_version = local_rockspec.version
            deps = ordered.Ordered()

            if local_rockspec.supported_platforms then
                deps.supported_platforms = local_rockspec.supported_platforms
            end

            deps.dependencies = local_rockspec.dependencies

            local packages_from_rockspec = local_manifest.packages

            -- if there already was other version of package 'pkg name'
            local pkg = packages_from_rockspec[pkg_name] or {}

            pkg[pkg_version] = deps
            packages_in_manifest[pkg_name] = pkg
            pkg[pkg_version].local_url = pl.path.dirname(local_rockspec_file)
        end
        local_manifest.packages = packages_in_manifest
    end
    local_manifest.repo_path = deploy_dir

    return local_manifest
end

--Test repo url if it is local or remote
-- Returns true if repo is remote and false for local repo (local folder).
function manifest_module.is_remote(repo)
    return pl.stringx.startswith(repo,"git://")
end

return manifest_module
