-- Main API of LuaDist

local log = require "dist.log".logger
local cfg = require "dist.config"
local git = require "dist.git"
local mf = require "dist.manifest"
local utils = require "dist.utils"
local mgr = require "dist.manager"
local downloader = require "dist.downloader"
local ordered = require "dist.ordered"
local ReportBuilder = require "dist.ReportBuilder"
local pl = require "pl.import_into"()
local rocksolver = {}
rocksolver.DependencySolver = require "rocksolver.DependencySolver"
rocksolver.Package = require "rocksolver.Package"
rocksolver.const = require "rocksolver.constraints"
rocksolver.utils = require "rocksolver.utils"
local r2cmake = require 'rockspec2cmake'

local dist = {}

local function write_report(report, deploy_dir, command)
    local report_path = pl.path.join(deploy_dir, command:gsub(" ", "_") .. ".md")
    print("Creating report file '" .. report_path .. "'")
    local report_file = io.open(report_path, "w")
    if not report_file then
        print("Error creating report file for command '" .. command .. "'.")
    end
    report_file:write(report:generate())
    report_file:close()
end

local function resolve_dependencies(report, solver, package_names, _installed, preinstall_lua)
    local dependencies = ordered.Ordered()
    local installed = rocksolver.utils.deepcopy(_installed)

    if preinstall_lua then
        table.insert(installed, preinstall_lua)
    end

    for _, package_name in pairs(package_names) do
        -- Resolve dependencies
        local new_dependencies, err = solver:resolve_dependencies(package_name, installed)

        if err then
            report:add_error(err)
            return nil, err
        end

        -- Update dependencies to install with currently found ones and update installed packages
        -- for next dependency resolving as if previously found dependencies were already installed
        for _, dependency in pairs(new_dependencies) do
            dependencies[dependency] = dependency
            installed[dependency] = dependency
        end
    end

    report:add_header("Resolved dependencies:")
    for k in pairs(dependencies) do
        report:add_step(k)
    end
    return dependencies
end

-- Final logic for resolving dependencies, includes trying out different versions of Lua if an error
-- occured.
local function final_resolve_dependencies(report, manifest, solver, package_names, installed)
    -- Try to resolve dependencies as is
    local dependencies, err = resolve_dependencies(report, solver, package_names, installed)
    if dependencies then
        return dependencies
    end

    -- If we failed, it is most likely because wrong version of lua package was selected,
    -- try to cycle through all of them, we may eventually succeed

    for _, v in pairs(installed) do
        -- If lua is already installed, we can do nothing about it, user will have to upgrade / downgrade it manually
        if v.name == "lua" then
            report:add_hint({
                "The error may be caused by your version of Lua not being compatible with all the dependencies.",
                "Maybe consider upgrading / downgrading your Lua version."
            })
            return nil, err
        end
    end

    -- Try all versions of lua, newer first
    for version, info in rocksolver.utils.sort(manifest.packages.lua or {}, rocksolver.const.compareVersions) do
        local text = ("Trying to force usage of 'lua %s' to solve dependency resolving issues"):format(version)
        log:info(text)
        report:add_step(text)

        -- Here we do not care about returned error message, we will use the original one if all fails
        local new_dependencies = resolve_dependencies(report, solver, package_names, installed, rocksolver.Package("lua", version, info, true))

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
        return nil, err
    end

    return dependencies
end



-- Installs 'package_names' using optional CMake 'variables',
-- returns true on success and nil, error_message, error_code on error
-- Error codes:
-- 1 - manifest retrieval failed
-- 2 - dependency resolving failed
-- 3 - package download failed
-- 4 - installation of requested package failed
-- 5 - installation of dependency failed
local function _install(package_names, variables, report)
    -- Get installed packages
    local installed = mgr.get_installed()

    report:begin_stage("Manifest retrieval")

    -- Get manifest
    local manifest, err, more_info = mf.get_manifest()

    if more_info.downloading then
        report:add_step("Downloading manifest...")
        report:add_manifest_urls(more_info.used_repos)
    else
        report:add_step("Manifest already present, probably from previous download step.")
    end

    if not manifest then
        report:add_error(err)
        return nil, err, 1
    end

    report:add_step("Success")
    report:begin_stage("Dependency solving")

    local solver = rocksolver.DependencySolver(manifest, cfg.platform)

    local dependencies, err = final_resolve_dependencies(report, manifest, solver, package_names, installed)
    if not dependencies then
        return nil, err, 2
    end

    report:begin_stage("Fetching packages")

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
            report:add_package(pkg, nil, local_url)
            package_directories[pkg] = local_url

        --  Package fetched from remote repo
        else
            local dirs, err, urls = downloader.fetch_pkgs({pkg}, cfg.temp_dir_abs, manifest.repo_path)
            -- TODO: handle errors
            report:add_package(pkg, urls[pkg].remote_url, urls[pkg].local_url)
            package_directories[pkg] = dirs[pkg]
        end
    end

    report:begin_stage("Installing packages")

    -- Install packages
    for pkg, dir in pairs(package_directories) do
        report:add_header(pkg)

        ok, err = mgr.install_pkg(report, pkg, dir, variables)
        if not ok then
            return nil, "Error installing: " .. err, (utils.name_matches(tostring(pkg), package_names, true) and 4) or 5
        end

        -- If installation was successful, update local manifest
        table.insert(installed, pkg)
        mgr.save_installed(installed)

        report:add_step("Updating local manifest at '" .. cfg.local_manifest_file_abs .. "'")
    end

    -- TODO: report

    -- Mark binary dependencies of current package present in the time of installation
    for pkg, dir in pairs(package_directories) do
        local bin_deps, err = rocksolver.utils.generate_bin_dependencies(pkg:dependencies(cfg.platform), installed)
        -- save bin dependencies of package
        pkg.bin_dependencies = bin_deps
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

    local command = "install"
    for _, v in ipairs(package_names) do
        command = command .. " " .. v
    end

    local report = ReportBuilder.new(command)

    if deploy_dir then cfg.update_root_dir(deploy_dir) end
    local result, err, status = _install(package_names, variables, report)
    if deploy_dir then cfg.revert_root_dir() end

    if cfg.report then
        write_report(report, deploy_dir, command)
    end

    return result, err, status
end

-- Staticly build 'package_names' into 'dest_dir' using optional CMake 'variables',
-- returns true on success and nil, error_message, error_code on error
-- Error codes:
-- 1 - manifest retrieval failed
-- 2 - dependency resolving failed
-- 3 - repositary download failed
-- 4 - rockspec load failed
-- 5 - r2cmake process failed
-- 6 - main CMakeList.txt file creation failed
-- 7 - creation of modules.c.in file failed
local function _static(package_names, dest_dir, variables)
    -- Nothing is instaled for static build
    local installed = {}

    -- Get manifest
    local manifest, err = mf.get_manifest()
    if not manifest then
        return nil, err, 1
    end

    local solver = rocksolver.DependencySolver(manifest, cfg.platform)

    -- TODO: move to dist.static and make it work
    local report = ReportBuilder.new("static")

    -- Try to resolve dependencies as is
    local dependencies, err = resolve_dependencies(report, solver, package_names, installed)
    if not dependencies then
        return nil, err, 2
    end

    -- Fetch the packages from repository and store them to dest_dir
    local download_dirs, err = downloader.fetch_pkgs(dependencies, pl.path.abspath(dest_dir), manifest.repo_path, true)
    if not download_dirs then
        return nil, "Error downloading packages: " .. err, 3
    end

    -- Save rockspecs of modules for preparing some essential data
    local rockspecs = {}
    for pkg, dir in pairs(download_dirs) do
        local rockspec_file = pl.path.join(dir, pkg.name .. "-" .. tostring(pkg.version) .. ".rockspec")
        local rockspec, err = mf.load_rockspec(rockspec_file)
        if not rockspec then
            return nil, "Cound not load rockspec for package '" .. pkg .. "' from '" .. rockspec_file .. "': " .. err, 4
        end
        rockspecs[pkg] = rockspec

        -- Create CMakeList.txt file for module with buildin type of build
        --rockspec.build.type = 'none'
        if rockspec.build.type ~= 'cmake' then
            local cmake, err = r2cmake.process_rockspec(rockspec, dir, true)

            if not cmake then
                return nil, "Fatal error, cmake not generated: " .. err, 5
            else
                log:info("Successfully generated CMakeList.txt file for '%s'...", tostring(pkg))
            end
        else
            log:info("'%s' uses own CMakeLists.txt file...", tostring(pkg))
        end
    end

    -- Create main CMakeList.txt in dest_dir with modules and dependencies in right order
    local cmake_commands = utils.generate_cmakelist(dependencies)
    local cmake_output_file = io.open(pl.path.join(dest_dir, "CMakeLists.txt"), "w")
    if not cmake_output_file then
        return nil, "Error creating CMakeLists.txt file in '" .. dest_dir .. "'", 6
    end
    cmake_output_file:write(cmake_commands)
    cmake_output_file:close()

    -- Create modules.c.in file in dest_dir
    local config_file = utils.generate_config()
    local config_output_file = io.open(pl.path.join(dest_dir, "modules.c.in"), "w")
    if not config_output_file then
        return nil, "Error creating modules.c.in file in '" .. dest_dir .. "'", 7
    end
    config_output_file:write(config_file)
    config_output_file:close()

    log:info("Successfully created file's for staic build ...\n")

    return true
end

-- Public wrapper for 'static' functionality, ensures correct setting of 'dest_dir'
-- and performs argument checks
function dist.static(package_names, dest_dir, variables)
    if not package_names then return true end
    if type(package_names) == "string" then package_names = {package_names} end

    assert(type(package_names) == "table", "dist.install: Argument 'package_names' is not a table or string.")

    if deploy_dir then cfg.update_root_dir(dest_dir) end
    local result, err, status = _static(package_names, dest_dir, variables)
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
local function _make(deploy_dir, variables, current_dir, report)
    -- Collect all rockspec files in the current_directory and sort them alphabetically.
    local rockspec_files =  pl.dir.getfiles(current_dir, "*.rockspec")
    table.sort(rockspec_files)

    report:begin_stage("Searching for Rockspec files")

    -- Package specified in first rockspec will be installed, others will be ignored.
    if #rockspec_files == 0 then
        local text = "Directory " .. current_dir .. " doesn't contain any .rockspec files."
        report:add_error(text)
        return nil, text, 6
    elseif #rockspec_files > 1 then
        report:add_rockspec_files(rockspec_files)
        report:add_step("File '" .. rockspec_files[1] .. "' will be used.")
        log:info("Multiple rockspec files found, file ".. pl.path.basename(rockspec_files[1]) .. "will be used.")
    else
        report:add_step("File '" .. rockspec_files[1] .. "' will be used.")
        log:info("File ".. pl.path.basename(rockspec_files[1]) .. " will be used.")
    end

    local maked_pkg_rockspec = mf.load_rockspec(rockspec_files[1])
    local maked_pkg = maked_pkg_rockspec.package .. " " .. maked_pkg_rockspec.version
    package_names = {maked_pkg}

    -- Get installed packages
    local installed = mgr.get_installed()

    report:begin_stage("Manifest retrieval")
    report:add_step()

    -- Get manifest including the local repos
    local manifest, err = mf.get_manifest()
    if not manifest then
        report:add_error(err)
        return nil, err, 1
    end

    report:add_step("Success")
    report:begin_stage("Dependency solving")

    local solver = rocksolver.DependencySolver(manifest, cfg.platform)

    local dependencies, err = final_resolve_dependencies(report, manifest, solver, package_names, installed)
    if not dependencies then
        return nil, err, 2
    end

    report:begin_stage("Fetching packages")

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
            report:add_package(pkg, nil, current_dir)
            package_directories[pkg] = current_dir

        -- Package with local url
        elseif local_url then
            log:info("Package ".. pkg .. " will be installed from local url " .. local_url)
            report:add_package(pkg, nil, local_url)
            package_directories[pkg] = local_url

        --  Package fetched from remote repo
        else
            local dirs, err, urls = downloader.fetch_pkgs({pkg}, cfg.temp_dir_abs, manifest.repo_path)
            -- TODO: handle errors
            report:add_package(pkg, urls[pkg].remote_url, urls[pkg].local_url)
            package_directories[pkg] = dirs[pkg]
        end
    end

    report:begin_stage("Installing packages")

    -- Install packages. Installs every package 'pkg' from its package directory 'dir'
    for pkg, dir in pairs(package_directories) do
        report:add_header(pkg)

        -- Prevent cleaning our current direcory when making of package was not successful
        if dir == current_dir then
            store_debug = cfg.debug
            cfg.debug = true
            ok, err = mgr.install_pkg(report, pkg, dir, variables)
            if ok and store_debug == false then
                pl.dir.rmtree(current_dir)
                pl.dir.rmtree(pl.path.join(deploy_dir,"tmp",pkg.."-build"))
            end
            cfg.debug = store_debug
        else
            ok, err = mgr.install_pkg(report, pkg, dir, variables)
        end
        if not ok then
            return nil, "Error installing: " ..err, (utils.name_matches(tostring(pkg), package_names, true) and 4) or 5
        end

        -- If installation was successful, update local manifest
        table.insert(installed, pkg)
        mgr.save_installed(installed)

        report:add_step("Updating local manifest at '" .. cfg.local_manifest_file_abs .. "'")
    end

    -- TODO: report


    -- Mark binary dependencies of current package present in the time of installation
    for pkg, dir in pairs(package_directories) do
        local bin_deps = rocksolver.utils.generate_bin_dependencies(pkg:dependencies(cfg.platform), installed)
            -- save bin dependencies of package
            pkg.bin_dependencies = bin_deps
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

    local command = "make"
    local report = ReportBuilder.new(command)

    if deploy_dir then cfg.update_root_dir(deploy_dir) end
    local result, err, status = _make(deploy_dir, variables, current_dir, report)
    if deploy_dir then cfg.revert_root_dir() end

    if cfg.report then
        write_report(report, deploy_dir, command)
    end

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
local function _pack(package_names, deploy_dir, destination_dir)

    -- Get all packages installed in deploy_dir
    local installed = mgr.get_installed()

    -- Store original destination_dir
    local temp_dest_dir = destination_dir


    for _, pkg_name in pairs(package_names) do
        local found = false

        for _, installed_pkg in pairs(installed) do

            -- Restore original destination_dir
            temp_dest_dir = destination_dir

            -- Check if specified deploy_dir contains any packages
            if not getmetatable(installed_pkg) == rocksolver.Package then
                return nil, "Argument 'installed' does not contain Package instances.", 1
            else
                -- Installed package matches 'pkg_name' of packed package
                if installed_pkg:matches(pkg_name) and not found then
                    found = true

                    -- Export package files to 'temp_dest_dir'
                    local dep_hash = rocksolver.utils.generate_dep_hash(cfg.platform, installed_pkg:dependencies(cfg.platform), installed)
                    temp_dest_dir = pl.path.join(temp_dest_dir, installed_pkg.name .. " " .. installed_pkg.spec.version .."_" .. dep_hash)
                    file_tab, err = mgr.copy_pkg(installed_pkg, deploy_dir, temp_dest_dir)

                    if not file_tab then
                        return nil, err
                    end
                    -- Create rockspec for the installed package
                    local exported_rockspec = mgr.export_rockspec(installed_pkg, installed, file_tab)
                    local rockspec_filename = installed_pkg.name .. "-" .. installed_pkg.spec.version ..".rockspec"
                    local rockspec_path = pl.path.join(temp_dest_dir ,rockspec_filename)

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
            print("Package " .. pkg_name .. " not found in specified directory.")
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

