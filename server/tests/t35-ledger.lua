-- Runs the production Lua program with an in-memory model of Redis commands.
-- Real Redis durability and PostgreSQL recovery are covered by t35-rights.sh.
local write = assert(loadfile(assert(arg[1])))
local legacy = arg[2] == "legacy"
local day = 24 * 60 * 60 * 1000
local now = 1800000000000
local ttl = 45 * day
local parent = "deleted:cd70bd3c-ca1e-45e2-ada3-65e35ce42b40"
local child = "deleted:b987fd2e-5de3-42e4-9aeb-41102554746a"
local other = "deleted:fdce1162-00eb-4d27-a72c-4888eb21ee7d"
local seal = "synthetic:45"
local records = { ["ledger:identity"] = { value = seal } }

local function get(key)
    local entry = records[key]
    if entry and (not entry.deadline or entry.deadline > now) then return entry end
end

redis = {
    error_reply = error,
    call = function(command, key, value, option, expiry)
        local entry = get(key)
        if command == "get" then return entry and entry.value or false end
        if command == "exists" then return entry and 1 or 0 end
        if command == "time" then return { math.floor(now / 1000), now % 1000 * 1000 } end
        if command == "pexpiretime" then return entry and (entry.deadline or -1) or -2 end
        if command == "pttl" then return entry and (entry.deadline and entry.deadline - now or -1) or -2 end
        if command == "set" then
            local deadline
            if option == "PXAT" then deadline = assert(tonumber(expiry))
            elseif option == "PX" then deadline = now + assert(tonumber(expiry))
            elseif option == "KEEPTTL" then deadline = entry.deadline
            else error("unexpected expiry mode: " .. tostring(option)) end
            records[key] = { value = value, deadline = deadline }
            return "OK"
        end
        error("unexpected Redis command: " .. command)
    end,
}

local function run(duration, rootIndex, keys, identity)
    KEYS = { "ledger:identity", table.unpack(keys) }
    ARGV = { identity or seal, tostring(duration), tostring(rootIndex) }
    return write()
end

local function check(key, deadline)
    local entry = assert(get(key), "missing tombstone")
    assert(entry.value == "", "independent ledger contains a nonempty cascade value")
    assert(entry.deadline == deadline, "unexpected tombstone expiry")
end

-- Red on the original command with the original contacts tag argument.
if legacy then
    KEYS = { "ledger:identity", parent, child }
    ARGV = { seal, tostring(ttl), "contacts:synthetic-association" }
    write()
    check(child, now + ttl)
    return
end

assert(not pcall(run, ttl, 2, { parent, child }, "wrong identity"))
assert(not get(parent) and not get(child))
assert(run(0, 2, { parent, child }) == 1 and not get(parent))
assert(run(ttl, 2, { parent, child }) == 1)
check(parent, now + ttl)
check(child, now + ttl)

-- Successful recovery can repeat the same keys and never shorten longer coverage.
now = now + day
assert(run(ttl, 2, { parent, child }) == 1)
check(parent, now + ttl)
check(child, now + ttl)
records[child].deadline = now + ttl + day
assert(run(ttl, 2, { parent, child }) == 0)
assert(run(ttl, 0, { parent, child }) == 1)
check(child, now + ttl + day)

-- A half-present batch or weaker coverage cannot authorize normal retries.
local originalParent, originalChild = records[parent], records[child]
records[parent] = nil
assert(run(ttl, 2, { parent, child }) == 0 and not get(parent))
records[parent], records[child] = originalParent, nil
assert(run(ttl, 2, { parent, child }) == 0 and not get(child))
records[child] = { value = "", deadline = now + day }
assert(run(ttl, 2, { parent, child }) == 0)
check(child, now + day)
records[child] = originalChild
records[child].deadline = records[parent].deadline
records[child].value = "legacy"
assert(run(ttl, 2, { parent, child }) == 0)
records[child].value = ""
records[other] = { value = "", deadline = now + ttl }
assert(run(ttl, 3, { other, parent, child }) == 0)

-- Internal recovery uses the canonical source list even on a partial ledger.
records[parent] = nil
records[child].deadline = now + ttl + day
assert(run(ttl, 0, { parent, child }) == 1)
check(parent, now + ttl)
check(child, now + ttl + day)
now = now + ttl + day
assert(not get(parent) and not get(child) and not get(other))
assert(run(ttl, 2, { parent, child }) == 1)
check(parent, now + ttl)
check(child, now + ttl)
print("T35 ledger Lua regression passed")
