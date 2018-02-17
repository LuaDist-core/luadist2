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
        data = err,
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
        end
    end

    return res
end

return ReportBuilder

