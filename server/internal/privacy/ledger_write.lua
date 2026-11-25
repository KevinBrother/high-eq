if redis.call('get', KEYS[1]) ~= ARGV[1] then
    return redis.error_reply('ledger identity mismatch')
end

local ttl = tonumber(ARGV[2])
local parent = tonumber(ARGV[3])
local first = 2
if parent > 0 then
    -- The account lock and committed SQL intent identify the cascade. A live
    -- parent tombstone witnesses the atomic batch; a child by itself doesn't.
    for i = first, parent - 1 do
        if redis.call('exists', KEYS[i]) == 1 then return 0 end
    end
    local expiry = redis.call('pexpiretime', KEYS[parent])
    if expiry ~= -2 and (expiry < 0 or redis.call('get', KEYS[parent]) ~= '') then
        return 0
    end
    for i = parent + 1, #KEYS do
        local child = redis.call('pexpiretime', KEYS[i])
        if expiry == -2 then
            if child ~= -2 then return 0 end
        elseif child ~= expiry or redis.call('get', KEYS[i]) ~= '' then
            -- All members of an online batch have the same retention
            -- deadline. A separately refreshed key leaves ambiguous state.
            return 0
        end
    end
    first = parent
end

if ttl == 0 then return 1 end

local now = redis.call('time')
local deadline = math.max(now[1] * 1000 + math.floor(now[2] / 1000) + ttl, tonumber(ARGV[4]) or 0)
for i = first, #KEYS do
    local expiry = math.max(deadline, redis.call('pexpiretime', KEYS[i]))
    redis.call('set', KEYS[i], '', 'PXAT', string.format('%.0f', expiry))
end
return 1
