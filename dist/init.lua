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

    -- Table contains pairs <package, package directory>
    local package_directories = ordered.Ordered()

    for _, pkg in pairs(dependencies) do
        local pkg_name, pkg_version = rocksolver.const.split(tostring(pkg))

        -- Extract local url from package, if any
        local local_url = manifest.packages
        local_url = local_url[pkg_name][pkg_version]
        local_url = local_url.local_url

        -- Package with local url
        if local_url then
            log:info("Package ".. pkg .. " will be installed from local url " .. local_url)
            package_directories[pkg] = local_url

        --  Package fetched from remote repo
        else
            local dirs, err = downloader.fetch_pkgs({pkg}, cfg.temp_dir_abs, manifest.repo_path)
            package_directories[pkg] = dirs[pkg]
        end
    end

    -- Install packages
    for pkg, dir in pairs(package_directories) do
        ok, err = mgr.install_pkg(pkg, dir, variables)
        if not ok then
            return nil, "Error installing: " ..err, (utils.name_matches(tostring(pkg), package_names, true) and 4) or 5
        end

        -- If installation was successful, update local manifest
        table.insert(installed, pkg)
        mgr.save_installed(installed)
    end

    for pkg, dir in pairs(package_directories) do
        -- pl.pretty.dump(pkg:dependencies(cfg.platform))
        pkg.bin_dependencies = mgr.generate_bin_dependencies(pkg.spec.dependencies, installed)
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
-- 1 - manifest retrieval failed
-- 2 - dependency resolving failed
-- 3 - package download failed
-- 4 - installation of requested package failed
-- 5 - installation of dependency failed
-- 6 - no package to make found
local function _make (deploy_dir,variables, current_dir)

    -- Get installed packages
    local installed = mgr.get_installed()

    -- Get manifest including the local repos
    local manifest, err = mf.get_manifest()
    if not manifest then
        return nil, err, 1
    end

    local solver = rocksolver.DependencySolver(manifest, cfg.platform)

    -- Collect all rockspec files in the current_directory and sort them alphabetically.
    local rockspec_files =  pl.dir.getfiles(current_dir, "*.rockspec")
    table.sort(rockspec_files)

    -- Package specified in first rockspec will be installed, others will be ignored.
    if #rockspec_files == 0 then
        return nil, "Directory " .. current_dir .. " doesn't contain any .rockspec files.", 6
    elseif #rockspec_files > 1 then
        log:info("Multiple rockspec files found, file ".. pl.path.basename(rockspec_files[1]) .. "will be used.")
    else
        log:info("File ".. pl.path.basename(rockspec_files[1]) .. " will be used.")
    end

    local maked_pkg_rockspec =mf.load_rockspec(rockspec_files[1])
    local maked_pkg = maked_pkg_rockspec.package .. " " .. maked_pkg_rockspec.version
    package_names = {maked_pkg}

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
        local pkg_name, pkg_version = rocksolver.const.split(tostring(pkg))

        -- Extract local url from package, if any
        local local_url = manifest.packages
        local_url = local_url[pkg_name][pkg_version]
        local_url = local_url.local_url

        -- Maked package
        if tostring(pkg) == maked_pkg then
            package_directories[pkg] = current_dir

        -- Package with local url
        elseif local_url then
            log:info("Package ".. pkg .. " will be installed from local url " .. local_url)
            package_directories[pkg] = local_url

        --  Package fetched from remote repo
        else
            local dirs, err = downloader.fetch_pkgs({pkg}, cfg.temp_dir_abs, manifest.repo_path)
            package_directories[pkg] = dirs[pkg]
        end
    end


    -- Install packages. Installs every package 'pkg' from its package directory 'dir'
    for pkg, dir in pairs(package_directories) do
        -- Prevent cleaning our current direcory when making of package was not successful
        if dir == current_dir then
            store_debug = cfg.debug
            cfg.debug = true
            ok, err = mgr.install_pkg(pkg, dir, variables)
            if ok and store_debug == false then
                pl.dir.rmtree(current_dir)
                pl.dir.rmtree(pl.path.join(deploy_dir,"tmp",pkg.."-build"))
            end
            cfg.debug = store_debug
        else
            ok, err = mgr.install_pkg(pkg, dir, variables)
        end
        if not ok then
            return nil, "Error installing: " ..err, (utils.name_matches(tostring(pkg), package_names, true) and 4) or 5
        end

        -- If installation was successful, update local manifest
        table.insert(installed, pkg)
        mgr.save_installed(installed)
    end

    for pkg, dir in pairs(package_directories) do
        -- pl.pretty.dump(pkg:dependencies(cfg.platform))
        pkg.bin_dependencies = mgr.generate_bin_dependencies(pkg.spec.dependencies, installed)
        mgr.save_installed(installed)
    end

    return true
end

-- Public wrapper for 'make' functionality, ensures correct setting of 'deploy_dir'
-- and performs argument checks.
-- Local repositories are also searched when LuaDist searches for the missing dependencies
function dist.make(deploy_dir, variables, current_dir)
    assert(deploy_dir and type(deploy_dir) == "string", "dist.make: Argument 'deploy_dir' is not a string.")
    assert(current_dir and type(current_dir) == "string", "dist.make: Argument 'current_dir' is not a string.")

    if deploy_dir then cfg.update_root_dir(deploy_dir) end
    local result, err, status = _make(deploy_dir, variables, current_dir)
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

-- Exports all files of 'package_names' installed in 'deploy_dir'
-- to 'destination_dir' and creates rockspec for each package
-- Returns true on success and nil, error_message, error_code on error
-- Error codes:
-- 1 - 'deploy_dir' doesn't contain any packages
-- 2 - specified package not found in 'deploy_dir'
local function _pack(package_names, deploy_dir, destination_dir)

    -- Get all packages installed in deploy_dir
    local installed = mgr.get_installed()

    for _, pkg_name in pairs(package_names) do
        local found = false

        for _, installed_pkg in pairs(installed) do

            -- Check if specified deploy_dir contains any packages
            if not getmetatable(installed_pkg) == rocksolver.Package then
                return nil, "Argument 'installed' does not contain Package instances.", 1
            else
                -- Installed package matches 'pkg_name' of packed package
                if installed_pkg:matches(pkg_name) and not found then
                    found = true

                    -- Export package files to 'destination_dir'
                    local dep_hash = mgr.generate_dep_hash(installed_pkg.spec.dependencies,installed)
                    destination_dir = pl.path.join(destination_dir, installed_pkg.spec.package .. " " .. installed_pkg.spec.version .."_" .. dep_hash)
                    file_tab = mgr.copy_pkg(installed_pkg, deploy_dir, destination_dir)

                    -- Create rockspec for the installed package
                    local exported_rockspec = mgr.export_rockspec(installed_pkg, installed, file_tab)
                    local rockspec_filename = installed_pkg.spec.package .. "-" .. installed_pkg.spec.version ..".rockspec"
                    local rockspec_path = pl.path.join(destination_dir,rockspec_filename)

                    -- Write rockspec to file
                    local rockspec_file = io.open(rockspec_path, "w")
                    for k,v in pairs(exported_rockspec) do
                        rockspec_file:write(k .. ' = '.. pl.pretty.write(v).."\n")
                    end
                    rockspec_file:close()

                end
            end
        end
        -- Package with specified name isn't installed in specified directory
        if not found then
            return nil, "Package " .. pkg_name .. " not found in specified directory." , 2
        end
    end

    return true
end

-- Public wrapper for 'pack' functionality, ensures correct setting of 'deploy_dir'
-- and performs argument checks
function dist.pack(package_names, deploy_dir, destination_dir)

    if not package_names or not destination_dir then return true end
    if type(package_names) == "string" then package_names = {package_names} end

    assert(type(package_names) == "table", "dist.pack: Argument 'package_names' is not a table or string.")
    assert(deploy_dir and type(deploy_dir) == "string", "dist.pack: Argument 'deploy_dir' is not a string.")
    assert(destination_dir and type(destination_dir) == "string", "dist.pack: Argument 'destination_dir' is not a string.")

    if deploy_dir then cfg.update_root_dir(deploy_dir) end
    local result, err, status = _pack(package_names, deploy_dir, destination_dir)
    if deploy_dir then cfg.revert_root_dir() end

    return result, err, status
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
