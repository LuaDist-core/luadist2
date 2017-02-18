-- Main API of LuaDist

local log = require "dist.log".logger
local cfg = require "dist.config"
local git = require "dist.git"
local mf = require "dist.manifest"
local utils = require "dist.utils"
local mgr = require "dist.manager"
local downloader = require "dist.downloader"
local ordered = require "dist.ordered"
local pl = require "pl.import_into"()
local rocksolver = {}
rocksolver.DependencySolver = require "rocksolver.DependencySolver"
rocksolver.Package = require "rocksolver.Package"
rocksolver.const = require "rocksolver.constraints"
rocksolver.utils = require "rocksolver.utils"

local dist = {}

-- Installs 'package_names' using optional CMake 'variables',
-- returns true on success and nil, error_message, error_code on error
-- Error codes:
-- 1 - manifest retrieval failed
-- 2 - dependency resolving failed
-- 3 - package download failed
-- 4 - installation of requested package failed
-- 5 - installation of dependency failed
local function _install(package_names, variables)
    -- Get installed packages
    local installed = mgr.get_installed()

    -- Get manifest
    local manifest, err = mf.get_manifest()
    if not manifest then
        return nil, err, 1
    end

    local solver = rocksolver.DependencySolver(manifest, cfg.platform)


    local function resolve_dependencies(package_names, _installed, preinstall_lua)
        local dependencies = ordered.Ordered()
        local installed = rocksolver.utils.deepcopy(_installed)

        if preinstall_lua then
            table.insert(installed, preinstall_lua)
        end

        for _, package_name in pairs(package_names) do
            -- Resolve dependencies
            local new_dependencies, err = solver:resolve_dependencies(package_name, installed)

            if err then
                return nil, err
            end

            -- Update dependencies to install with currently found ones and update installed packages
            -- for next dependency resolving as if previously found dependencies were already installed
            for _, dependency in pairs(new_dependencies) do
                dependencies[dependency] = dependency
                installed[dependency] = dependency
            end
        end

        return dependencies
    end

    -- Try to resolve dependencies as is
    local dependencies, err = resolve_dependencies(package_names, installed)

    -- If we failed, it is most likely because wrong version of lua package was selected,
    -- try to cycle through all of them, we may eventually succeed
    if not dependencies then
        -- If lua is already installed, we can do nothing about it, user will have to upgrade / downgrade it manually
        if installed.lua then
            return nil, err, 2
        end

        -- Try all versions of lua, newer first
        for version, info in rocksolver.utils.sort(manifest.packages.lua or {}, rocksolver.const.compareVersions) do
            log:info("Trying to force usage of 'lua %s' to solve dependency resolving issues", version)

            -- Here we do not care about returned error message, we will use the original one if all fails
            local new_dependencies = resolve_dependencies(package_names, installed, rocksolver.Package("lua", version, info, true))

            if new_dependencies then
                dependencies = ordered.Ordered()
                dependencies[rocksolver.Package("lua", version, info, false)] = rocksolver.Package("lua", version, info, false)
                for _, dep in pairs(new_dependencies) do
                    dependencies[dep] = dep
                end
                break
            end
        end

        if not dependencies then
            return nil, err, 2
        end
    end

    -- Fetch the packages from repository
    local dirs, err = downloader.fetch_pkgs(dependencies, cfg.temp_dir_abs, manifest.repo_path)
    if not dirs then
        return nil, "Error downloading packages: " .. err, 3
    end

    -- Install fetched packages
    for pkg, dir in pairs(dirs) do
        ok, err = mgr.install_pkg(pkg, dir, variables)
        if not ok then
            return nil, "Error installing: " ..err, (utils.name_matches(tostring(pkg), package_names, true) and 4) or 5
        end

        -- If installation was successful, update local manifest
        table.insert(installed, pkg)
        mgr.save_installed(installed)
    end

    return true
end

-- Public wrapper for 'install' functionality, ensures correct setting of 'deploy_dir'
-- and performs argument checks
function dist.install(package_names, deploy_dir, variables)
    if not package_names then return true end
    if type(package_names) == "string" then package_names = {package_names} end

    assert(type(package_names) == "table", "dist.install: Argument 'package_names' is not a table or string.")
    assert(deploy_dir and type(deploy_dir) == "string", "dist.install: Argument 'deploy_dir' is not a string.")

    if deploy_dir then cfg.update_root_dir(deploy_dir) end
    local result, err, status = _install(package_names, variables)
    if deploy_dir then cfg.revert_root_dir() end

    return result, err, status
end

-- Makes 'package_names' using optional CMake 'variables',
-- returns true on success and nil, error_message, error_code on error
-- Error codes:
-- 1 - creating local manifest failed
-- 2 - dependency resolving failed
-- 4 - installation of requested package failed
-- 5 - installation of dependency failed
local function _make(package_names, variables)
    -- Get installed packages
    local installed = mgr.get_installed()


    -- Creates local manifest table, which has the same format as manifests from the remote repository.
    -- Manifest contains all packages present in the 'cfg.root_dir'. Function is searching for .rockspec files in all
    -- subdirectories of 'cfg.root_dir', but only 1 level deep.
    -- Subdirectory with package must have name 'package_name verison', e.g. 'inilazy 1.05-1', 'yaml 1.1.2-1', 'bk-tree 1.0.0-1'.
    -- returns manifest table

    local function generate_local_manifest()

        -- Get all subdirectories
        local subdirectories = pl.dir.getdirectories(cfg.root_dir)

        local local_manifest = ordered.Ordered()

        local_manifest["packages"] = {}
        local local_rockspec_files = {}

        -- get all 'rockspec' files in 'cfg.root_dir' subdirectories,
        -- searching only 1 level deep.
        -- Subdirectory with package must have name 'package_name verison', e.g. 'inilazy 1.05-1', 'yaml 1.1.2-1', 'bk-tree 1.0.0-1'.
        for _ ,subdir in pairs(subdirectories) do
            local rockspec_files = pl.dir.getfiles(subdir, "*.rockspec")
            for _ ,rockspec in pairs(rockspec_files) do
                table.insert(local_rockspec_files, rockspec)
            end
        end

        local packages_in_manifest = {}

        -- Iterate through all found rockspecs
        for _, local_rockspec_file in pairs(local_rockspec_files) do

            local pkg = {}
            local local_rockspec = mf.load_rockspec(local_rockspec_file)

            if not local_rockspec then
                log:error("Local rockspec "..local_rockspec_file.."could not be loaded")
            else
                -- Fetch info about the package from the rockspec
                local pkg_name = local_rockspec["package"]
                local pkg_version = local_rockspec["version"]
                deps = {}
                deps["dependencies"] = local_rockspec["dependencies"]

                if local_rockspec["supported_platforms"] then
                    deps["supported_platforms"] = local_rockspec["supported_platforms"]
                end

                local packages_from_rockspec = local_manifest["packages"]

                -- if there already was other version of package 'pkg name'
                if packages_from_rockspec[pkg_name] then
                    pkg = packages_from_rockspec[pkg_name]
                end

                pkg[pkg_version] = deps
                packages_in_manifest[pkg_name] = pkg
            end
            local_manifest["packages"] = packages_in_manifest

        end
        local_manifest["local_path"] = cfg.root_dir

        return local_manifest
    end

    -- Generate local manifest
    local manifest, err = generate_local_manifest(cfg.root_dir)
    if not manifest then
        return nil, err, 1
    end

    local solver = rocksolver.DependencySolver(manifest, cfg.platform)


    local function resolve_dependencies(package_names, _installed, preinstall_lua)
        local dependencies = ordered.Ordered()
        local installed = rocksolver.utils.deepcopy(_installed)

        if preinstall_lua then
            table.insert(installed, preinstall_lua)
        end

        for _, package_name in pairs(package_names) do
            -- Resolve dependencies
            local new_dependencies, err = solver:resolve_dependencies(package_name, installed)

            if err then
                return nil, err
            end

            -- Update dependencies to install with currently found ones and update installed packages
            -- for next dependency resolving as if previously found dependencies were already installed
            for _, dependency in pairs(new_dependencies) do
                dependencies[dependency] = dependency
                installed[dependency] = dependency
            end
        end

        return dependencies
    end

    -- Try to resolve dependencies as is
    local dependencies, err = resolve_dependencies(package_names, installed)

    -- If we failed, it is most likely because wrong version of lua package was selected,
    -- try to cycle through all of them, we may eventually succeed
    if not dependencies then
        -- If lua is already installed, we can do nothing about it, user will have to upgrade / downgrade it manually
        if installed.lua then
            return nil, err, 2
        end

        -- Try all versions of lua, newer first
        for version, info in rocksolver.utils.sort(manifest.packages.lua or {}, rocksolver.const.compareVersions) do
            log:info("Trying to force usage of 'lua %s' to solve dependency resolving issues", version)

            -- Here we do not care about returned error message, we will use the original one if all fails
            local new_dependencies = resolve_dependencies(package_names, installed, rocksolver.Package("lua", version, info, true))

            if new_dependencies then
                dependencies = ordered.Ordered()
                dependencies[rocksolver.Package("lua", version, info, false)] = rocksolver.Package("lua", version, info, false)
                for _, dep in pairs(new_dependencies) do
                    dependencies[dep] = dep
                end
                break
            end
        end

        if not dependencies then
            return nil, err, 2
        end
    end

    -- Table contains pairs <package, package directory>
    local package_directories = ordered.Ordered()

    for _, pkg in pairs(dependencies) do
        local pkg_dir = pl.path.join(cfg.root_dir, tostring(pkg))
        package_directories[pkg] = pkg_dir
    end



    -- Install packages. Installs every package 'pkg' from its package directory 'dir'
    for pkg, dir in pairs(package_directories) do
        -- prevent cleaning up (deleting the package subfolder)
        cfg.debug = true
        ok, err = mgr.install_pkg(pkg, dir, variables)
        cfg.debug = false

        if not ok then
            return nil, "Error installing: " ..err, (utils.name_matches(tostring(pkg), package_names, true) and 4) or 5
        end

        -- If installation was successful, update local manifest
        table.insert(installed, pkg)
        mgr.save_installed(installed)
    end

    return true
end

-- Public wrapper for 'make' functionality, ensures correct setting of 'deploy_dir'
-- and performs argument checks.
-- Maked package including missing dependencies must be present in 'deploy_dir'.
function dist.make(package_names, deploy_dir, variables)
    if not package_names then return true end
    if type(package_names) == "string" then package_names = {package_names} end

    assert(type(package_names) == "table", "dist.make: Argument 'package_names' is not a table or string.")
    assert(deploy_dir and type(deploy_dir) == "string", "dist.make: Argument 'deploy_dir' is not a string.")

    if deploy_dir then cfg.update_root_dir(deploy_dir) end
    local result, err, status = _make(package_names, variables)
    if deploy_dir then cfg.revert_root_dir() end

    return result, err, status
end

-- Removes 'package_names' and returns amount of removed modules
--
-- In constrast to cli remove command, this one doesn't remove all packages
-- when supplied argument is empty table (to prevent possible mistakes),
-- to achieve such functionality use remove(get_installed(DIR))
local function _remove(package_names)
    local installed = mgr.get_installed()
    local removed = 0
    for _, pkg_name in pairs(package_names) do
        local name, version = rocksolver.const.split(tostring(pkg_name))
        local found_pkg = nil

        for i, pkg in pairs(installed) do
            if name == pkg.name and (not version or version == tostring(pkg.version)) then
                found_pkg = table.remove(installed, i)
                break
            end
        end

        if found_pkg == nil then
            log:error("Could not remove package '%s', no records of its installation were found", tostring(pkg_name))
        else
            ok, err = mgr.remove_pkg(found_pkg)
            if not ok then
                return nil, "Error removing: " .. err
            end

            -- If removal was successful, update local manifest
            mgr.save_installed(installed)
            removed = removed + 1
        end
    end

    return removed
end

-- Public wrapper for 'remove' functionality, ensures correct setting of 'deploy_dir'
-- and performs argument checks
function dist.remove(package_names, deploy_dir)
    if type(package_names) == "string" then package_names = {package_names} end

    assert(type(package_names) == "table", "dist.remove: Argument 'package_names' is not a string or table.")
    assert(deploy_dir and type(deploy_dir) == "string", "dist.remove: Argument 'deploy_dir' is not a string.")

    if deploy_dir then cfg.update_root_dir(deploy_dir) end
    local result, err = _remove(package_names)
    if deploy_dir then cfg.revert_root_dir() end

    return result, err
end

-- Returns list of installed packages from provided 'deploy_dir'
function dist.get_installed(deploy_dir)
    assert(deploy_dir and type(deploy_dir) == "string", "dist.get_installed: Argument 'deploy_dir' is not a string.")

    if deploy_dir then cfg.update_root_dir(deploy_dir) end
    local result, err = mgr.get_installed()
    if deploy_dir then cfg.revert_root_dir() end

    return result, err
end

-- Downloads packages specified in 'package_names' into 'download_dir' and
-- returns table <package, package_download_dir>
function dist.fetch(download_dir, package_names)
    download_dir = download_dir or cfg.temp_dir_abs

    assert(type(download_dir) == "string", "dist.fetch: Argument 'download_dir' is not a string.")
    assert(type(package_names) == "table", "dist.fetch: Argument 'package_names' is not a table.")
    download_dir = pl.path.abspath(download_dir)

    local packages = {}
    local manifest, err = mf.get_manifest()
    if not manifest then
        return nil, err
    end

    for _, pkg_name in pairs(package_names) do
        -- If Package instances were provided (through Lua interface), just use them
        if getmetatable(pkg_name) == rocksolver.Package then
            table.insert(packages, pkg_name)
        -- Find best matching package instance for user provided name
        else
            assert(type(pkg_name) == "string", "dist.fetch: Elements of argument 'package_names' are not package instances or strings.")

            local name, version = rocksolver.const.split(pkg_name)

            -- If version was provided, use it
            if version ~= nil then
                table.insert(packages, rocksolver.Package(name, version, {}, false))
            -- Else fetch most recent one
            else
                if manifest.packages[name] ~= nil then
                    local latest_pkg = nil

                    for version, _ in pairs(manifest.packages[name]) do
                        if not latest_pkg or latest_pkg < rocksolver.Package(name, version, {}, false) then
                            latest_pkg = rocksolver.Package(name, version, {}, false)
                        end
                    end

                    assert(latest_pkg ~= nil)
                    table.insert(packages, latest_pkg)
                    log:info("Could not determine version of package '%s' to fetch from provided input, getting latest one '%s'", name, tostring(latest_pkg))
                else
                    return nil, "Could not find any information about package '" .. name .. "', please verify that it exists in manifest repositories"
                end
            end
        end
    end

    return downloader.fetch_pkgs(packages, download_dir, manifest.repo_path)
end

-- Downloads packages specified in 'package_names' into 'download_dir',
-- loads their rockspec files and returns table <package, rockspec>
function dist.get_rockspec(download_dir, package_names)
    download_dir = download_dir or cfg.temp_dir_abs

    assert(type(download_dir) == "string", "dist.get_rockspec: Argument 'download_dir' is not a string.")
    assert(type(package_names) == "table", "dist.get_rockspec: Argument 'package_names' is not a table.")
    download_dir = pl.path.abspath(download_dir)

    local downloads, err = dist.fetch(download_dir, package_names)
    if not downloads then
        return nil, "Could not download packages: " .. err
    end

    local rockspecs = {}
    for pkg, dir in pairs(downloads) do
        local rockspec_file = pl.path.join(dir, pkg.name .. "-" .. tostring(pkg.version) .. ".rockspec")
        local rockspec, err = mf.load_rockspec(rockspec_file)
        if not rockspec then
            return nil, "Cound not load rockspec for package '" .. pkg .. "' from '" .. rockspec_file .. "': " .. err
        end

        rockspecs[pkg] = rockspec
    end

    return rockspecs
end

return dist
