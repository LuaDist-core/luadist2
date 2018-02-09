local pl = require "pl.import_into"()
pl.template = require "pl.template"

local tmpl = {
    intro = [[
# Report for package $(package_name)

]],

    dependencies = [[
## Dependencies
@ for _, dep in pairs(dependencies) do
    - $(dep)
@ end

]],

    manifest_urls = [[
    - Trying to get manifest from the following URLs:
@ for _, url in pairs(urls) do
        - $(url)
@ end
]],

    stage_begin = [[

## $(i). $(name)

]],

    step = [[
    - $(step)
]],

    err = [[

### Error:
    - $(err)
@ if possible_fix ~= nil then
    - $(possible_fix)
@ end

]]
}

local ReportBuilder = {}
ReportBuilder.__index = ReportBuilder

function ReportBuilder.new(package_name)
    local self = setmetatable({}, ReportBuilder)

    self.package_name = package_name
    self.dependencies = {}
    self.sections = {}

    return self
end

function ReportBuilder:begin_stage(description)
    table.insert(self.sections, {
        type = "stage",
        data = description
    })
end

function ReportBuilder:add_step(description)
    table.insert(self.sections, {
        type = "step",
        data = description
    })
end

function ReportBuilder:add_manifest_urls(urls)
    table.insert(self.sections, {
        type = "manifest_urls",
        data = urls
    })
end

function ReportBuilder:add_error(err, possible_fix)
    table.insert(self.sections, {
        type = "error",
        data = err,
        possible_fix = possible_fix
    })
end

function ReportBuilder:clear_dependencies()
    for k in pairs(self.dependencies) do
        self.dependencies[k] = nil
    end
end

function ReportBuilder:add_dependency(dependency)
    table.insert(self.dependencies, dependency)
end

function ReportBuilder:generate()
    local res = pl.template.substitute(tmpl.intro, {
        _escape = '@',
        package_name = self.package_name
    })

    if #self.dependencies > 0 then
        res = res .. pl.template.substitute(tmpl.dependencies, {
            _escape = '@',
            pairs = pairs,
            dependencies = self.dependencies
        })
    end

    local current_stage = 1
    for _, section in pairs(self.sections) do
        if section.type == "stage" then
            res = res .. pl.template.substitute(tmpl.stage_begin, {
                _escape = '@',
                i = current_stage,
                name = section.data
            })
            current_stage = current_stage + 1
        elseif section.type == "manifest_urls" then
            res = res .. pl.template.substitute(tmpl.manifest_urls, {
                _escape = '@',
                pairs = pairs,
                urls = section.data
            })
        elseif section.type == "step" then
            res = res .. pl.template.substitute(tmpl.step, {
                _escape = '@',
                step = section.data
            })
        elseif section.type == "error" then
            res = res .. pl.template.substitute(tmpl.err, {
                _escape = '@',
                err = section.data,
                possible_fix = section.possible_fix
            })
        end
    end

    return res
end

return ReportBuilder

