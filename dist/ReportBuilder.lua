local pl = require "pl.import_into"()
pl.template = require "pl.template"

local tmpl = {
    intro = [[
# Report for '$(command)'

]],

    stage_begin = [[

## $(i). $(name)

]],

    header = [[

### $(header)
]],

    manifest_urls = [[

- **Manifest URLs**:
@ for _, v in ipairs(urls) do
    - $(v)
@ end
]],

    step = [[
- $(step)
]],

    hint = [[

@ if type(hint) == "string" then
- *hint:* $(hint)
@ elseif type(hint) == "table" then
- *hint*:
@   for _, v in ipairs(hint) do
    - $(v)
@   end
@ end
]],

    package = [[
- **$(pkg.name)**
@ if pkg.url then
    - **remote:** $(pkg.url)
@ end
    - **local:** $(pkg.local_path)
]],

    err = [[
- **Error:** $(err)
]],

    cmake_variables = [[
- **CMake Variables:**
@ for k, v in pairs(variables) do
    - `$(k)` = $(v)
@ end
]],

    rockspec_files = [[
- **Rockspec files found:**
@ for _, v in ipairs(files) do
    - $(v)
@ end
]]
}

local ReportBuilder = {}
ReportBuilder.__index = ReportBuilder

function ReportBuilder.new(command)
    local self = setmetatable({}, ReportBuilder)

    self.command = command
    self.sections = {}

    return self
end

function ReportBuilder:begin_stage(description)
    table.insert(self.sections, {
        type = "stage",
        data = description
    })
end

function ReportBuilder:add_header(header)
    table.insert(self.sections, {
        type = "header",
        data = header
    })
end

function ReportBuilder:add_manifest_urls(urls)
    table.insert(self.sections, {
        type = "manifest_urls",
        data = urls
    })
end

function ReportBuilder:add_step(description)
    table.insert(self.sections, {
        type = "step",
        data = description
    })
end

function ReportBuilder:add_package(pkg, url, local_path)
    table.insert(self.sections, {
        type = "package",
        data = {
            name = pkg,
            url = url,
            local_path = local_path
        }
    })
end

function ReportBuilder:add_hint(hint)
    table.insert(self.sections, {
        type = "hint",
        data = hint
    })
end

function ReportBuilder:add_error(err)
    table.insert(self.sections, {
        type = "error",
        data = err
    })
end

function ReportBuilder:add_cmake_variables(variables)
    table.insert(self.sections, {
        type = "cmake_variables",
        data = variables
    })
end

function ReportBuilder:add_rockspec_files(files)
    table.insert(self.sections, {
        type = "rockspec_files",
        data = files
    })
end


function ReportBuilder:generate()
    local res = pl.template.substitute(tmpl.intro, {
        _escape = '@',
        command = self.command
    })

    local current_stage = 1
    for _, section in pairs(self.sections) do
        if section.type == "stage" then
            res = res .. pl.template.substitute(tmpl.stage_begin, {
                _escape = '@',
                i = current_stage,
                name = section.data
            })
            current_stage = current_stage + 1
        elseif section.type == "header" then
            res = res .. pl.template.substitute(tmpl.header, {
                _escape = '@',
                header = section.data
            })
        elseif section.type == "manifest_urls" then
            res = res .. pl.template.substitute(tmpl.manifest_urls, {
                _escape = '@',
                ipairs = ipairs,
                urls = section.data
            })
        elseif section.type == "step" then
            res = res .. pl.template.substitute(tmpl.step, {
                _escape = '@',
                step = section.data
            })
        elseif section.type == "package" then
            res = res .. pl.template.substitute(tmpl.package, {
                _escape = '@',
                pkg = section.data
            })
        elseif section.type == "hint" then
            res = res .. pl.template.substitute(tmpl.hint, {
                _escape = '@',
                ipairs = ipairs,
                type = type,
                hint = section.data
            })
        elseif section.type == "error" then
            res = res .. pl.template.substitute(tmpl.err, {
                _escape = '@',
                err = section.data
            })
        elseif section.type == "cmake_variables" then
            res = res .. pl.template.substitute(tmpl.cmake_variables, {
                _escape = '@',
                pairs = pairs,
                variables = section.data
            })
        elseif section.type == "rockspec_files" then
            res = res .. pl.template.substitute(tmpl.rockspec_files, {
                _escape = '@',
                ipairs = ipairs,
                files = section.data
            })
        end
    end

    return res
end

return ReportBuilder

