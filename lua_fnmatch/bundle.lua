-- bundle.lua : one-time bundled signature lookups with registered callbacks (fnmatch.bundle).
--
-- Embedded into the fnmatch module at build time and run by luaopen_fnmatch with the module
-- table as its argument.
--
-- Hooking code registers what it needs: a function's signatures (alternatives, e.g. for several
-- game versions), the expected number of functions and a callback. `run()` then
--
--   1. analyses each image once: every signature of every function,
--   2. resolves every entry: the first alternative carried by the expected number of functions
--      wins. A found entry gives its functions its name, which can make the symbol-relation
--      signatures (s_*) of other entries resolve, so this repeats until a round finds nothing new,
--   3. only if every required entry was found: calls `before()`, every callback back to back,
--      `after()`.
--
-- So either all hooks are installed, together, or none is and the report says what is missing.

local fnmatch = ...

local bundle = {}
bundle.__index = bundle

local function type_name(value)
    -- the userdata metatables are protected with their type names
    local mt = getmetatable(value)
    return type(mt) == "string" and mt or type(value)
end

local function fail(message, level)
    error("fnmatch.bundle: " .. message, (level or 1) + 1)
end

-- fnmatch.bundle([source] [, options])
--   source:  an image, the default of every entry; without it, entries name a `module`
--   options: cache, threads: how run() analyses modules (as in fnmatch.module),
--            keep_images: keep the images run() opened (default: closed when run() returns),
--            before(report), after(report): called around the callbacks
function fnmatch.bundle(source, options)
    if options == nil and type(source) == "table" then
        source, options = nil, source
    end
    if source ~= nil and type_name(source) ~= "fnmatch.image" then
        fail("source must be an image, got " .. type_name(source), 2)
    end
    if options ~= nil and type(options) ~= "table" then
        fail("options must be a table", 2)
    end
    return setmetatable({
        _source = source,
        _options = options or {},
        _entries = {},
        _ran = false,
    }, bundle)
end

-- Canonical text of a signature, or a list of them (all on one function). Errors are reported at
-- the caller of register().
local function alternative(spec, name, i)
    local function one(sig, where)
        local text, message
        if type(sig) == "string" then
            text, message = fnmatch.signature.parse(sig)
        else
            message = "string expected, got " .. type(sig)
        end
        if text == nil then
            fail(string.format("%s: signature %s: %s", name, where, message), 4)
        end
        return text
    end
    if type(spec) == "table" then
        if #spec == 0 then
            fail(string.format("%s: signature #%d is an empty list", name, i), 3)
        end
        local all = {}
        for j, sig in ipairs(spec) do
            all[j] = one(sig, string.format("#%d.%d", i, j))
        end
        return all
    end
    local text = one(spec, "#" .. i) -- not a tail call: the error levels count this frame
    return text
end

-- bundle:register(spec) -> entry
--   name                  the function's name, for reports; once found, its functions get this
--                         name, which the symbol relations (s_*) of other entries refer to
--   signature             a signature, or
--   signatures            alternatives, tried in order: the first one carried by the expected
--                         number of functions wins. An alternative is a signature or a list of
--                         signatures that must all be on the function
--   module                where to look: a module loaded in this process, analysed by run(), or
--   image                 an image (default: the bundle's)
--   count                 expected number of functions (default 1), false for any number
--   offset                added to every function address (default 0)
--   required              if false, a missing entry is skipped instead of failing the run
--   priority              callbacks run by ascending priority (default 0), then in order
--   callback(address, entry)
--
-- The returned entry is filled in by run(): found, address, matches, functions, signature,
-- alternative, image, error.
function bundle:register(spec)
    if self._ran then
        fail("register() after run(), a bundle runs only once", 2)
    end
    if type(spec) ~= "table" then
        fail("register() expects a table", 2)
    end

    local index = #self._entries + 1
    if spec.name ~= nil and (type(spec.name) ~= "string" or spec.name == "") then
        fail("#" .. index .. ": name must be a non-empty string", 2)
    end
    local name = spec.name or ("#" .. index)

    local sources = spec.signatures
    if sources == nil then
        sources = { spec.signature }
    elseif spec.signature ~= nil then
        fail(name .. ": give either signature or signatures", 2)
    end
    if type(sources) ~= "table" or #sources == 0 then
        fail(name .. ": no signature", 2)
    end
    local signatures = {}
    for i, source in ipairs(sources) do
        signatures[i] = alternative(source, name, i)
    end

    local count = spec.count
    if count == nil then
        count = 1
    elseif count == false then
        count = nil
    elseif type(count) ~= "number" or count < 0 or count % 1 ~= 0 then
        fail(name .. ": count must be a non-negative integer or false", 2)
    end

    if spec.offset ~= nil and type(spec.offset) ~= "number" then
        fail(name .. ": offset must be a number", 2)
    end
    if spec.callback ~= nil and type(spec.callback) ~= "function" then
        fail(name .. ": callback must be a function", 2)
    end

    -- Modules are analysed when the bundle runs (they only have to be loaded by then). Entries in
    -- the same image share its analysis.
    local region
    if spec.image ~= nil then
        if type_name(spec.image) ~= "fnmatch.image" then
            fail(name .. ": image must be an image", 2)
        end
        region = { key = spec.image, image = spec.image }
    elseif spec.module ~= nil then
        if type(spec.module) ~= "string" then
            fail(name .. ": module must be a string", 2)
        end
        region = { key = "module:" .. spec.module:lower(), module = spec.module }
    elseif self._source ~= nil then
        region = { key = self._source, image = self._source }
    else
        fail(name .. ": no image, give image or module (or create the bundle with an image)", 2)
    end

    local entry = {
        name = name,
        signatures = signatures,
        count = count,
        offset = spec.offset or 0,
        required = spec.required ~= false,
        priority = spec.priority or 0,
        callback = spec.callback,
        found = false,
        _symbol = spec.name,
        _index = index,
        _region = region,
    }
    self._entries[index] = entry
    return entry
end

function bundle:entries()
    return self._entries
end

-- One image per region; modules are analysed here. Returns the images run() opened.
local function open_images(self, report)
    local images, opened = {}, {}
    for _, entry in ipairs(self._entries) do
        local region = entry._region
        local image = images[region.key]
        if image == nil then
            image = { image = region.image }
            if region.module ~= nil then
                local options = self._options
                image.image, image.error = fnmatch.module(region.module, { cache = options.cache, threads = options.threads })
                if image.image ~= nil then
                    opened[#opened + 1] = image.image
                end
            end
            images[region.key] = image
            report.images = report.images + 1
        end
        entry._image = image
    end
    return opened
end

-- Finds the entry with the first alternative carried by the expected number of functions.
local function resolve(entry)
    local image = entry._image.image
    if image == nil then
        entry.error = entry._image.error
        return false
    end
    local reasons = {}
    for i, sig in ipairs(entry.signatures) do
        local functions = image:find(sig)
        if entry.count == nil or #functions == entry.count then
            local matches = {}
            for j, address in ipairs(functions) do
                matches[j] = address + entry.offset
                if entry._symbol ~= nil then
                    image:set_name(address, entry._symbol)
                end
            end
            entry.found = true
            entry.alternative = i
            entry.signature = sig
            entry.image = image
            entry.functions = functions
            entry.matches = matches
            entry.address = matches[1]
            entry.error = nil
            return true
        end
        local reason = string.format("%d functions, expected %d", #functions, entry.count)
        reasons[#reasons + 1] = #entry.signatures > 1 and string.format("alternative %d: %s", i, reason) or reason
    end
    entry.error = table.concat(reasons, "; ")
    return false
end

local function close_all(images)
    for _, image in ipairs(images) do
        image:close()
    end
end

-- bundle:run() -> report
--   report.ok        every required entry was found (and the callbacks ran)
--   report.entries   all entries, report.failed the required ones that were not found,
--                    report.skipped the optional ones that were not found
--   report.images    how many images the entries used (each analysed once)
--   report.rounds    how many lookup rounds it took
--   report.error     what failed, when not ok
-- A callback that raises an error stops the remaining ones; after() still runs, then the error
-- is raised again.
function bundle:run()
    if self._ran then
        fail("run() can only be called once", 2)
    end
    self._ran = true

    local report = { ok = true, entries = self._entries, failed = {}, skipped = {}, images = 0, rounds = 0 }
    local options = self._options
    local opened = open_images(self, report)
    local release = options.keep_images and function() end or function() close_all(opened) end

    local pending = {}
    for i, entry in ipairs(self._entries) do
        pending[i] = entry
    end
    repeat
        report.rounds = report.rounds + 1
        local progress, unresolved = false, {}
        for _, entry in ipairs(pending) do
            local ok, err = pcall(resolve, entry)
            if not ok then
                release()
                error(err, 0)
            end
            if err then
                progress = true
            else
                unresolved[#unresolved + 1] = entry
            end
        end
        pending = unresolved
    until not progress or #pending == 0

    for _, entry in ipairs(self._entries) do
        if not entry.found then
            if entry.required then
                report.failed[#report.failed + 1] = entry
            else
                report.skipped[#report.skipped + 1] = entry
            end
        end
    end

    if #report.failed > 0 then
        report.ok = false
        local parts = {}
        for i, entry in ipairs(report.failed) do
            parts[i] = entry.name .. " (" .. tostring(entry.error) .. ")"
        end
        report.error = string.format("%d required entr%s not found: %s", #report.failed,
            #report.failed == 1 and "y" or "ies", table.concat(parts, ", "))
        release()
        return report
    end

    local ordered = {}
    for _, entry in ipairs(self._entries) do
        if entry.found and entry.callback ~= nil then
            ordered[#ordered + 1] = entry
        end
    end
    table.sort(ordered, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a._index < b._index
    end)

    if options.before ~= nil then
        local ok, err = pcall(options.before, report)
        if not ok then
            release()
            error(err, 0)
        end
    end
    for _, entry in ipairs(ordered) do
        local ok, err = pcall(entry.callback, entry.address, entry)
        if not ok then
            if options.after ~= nil then
                pcall(options.after, report)
            end
            release()
            fail(string.format("callback of %s failed: %s", entry.name, tostring(err)), 2)
        end
    end
    if options.after ~= nil then
        local ok, err = pcall(options.after, report)
        if not ok then
            release()
            error(err, 0)
        end
    end
    release()
    return report
end

function bundle:__tostring()
    return string.format("fnmatch.bundle (%d entries%s)", #self._entries, self._ran and ", ran" or "")
end
