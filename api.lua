---
-- SQL specific API view
-- 
-- Copyright Tor Hveem <thveem> 2013
-- 
--
local setmetatable = setmetatable
local ngx = ngx
local string = string
local cjson = require "cjson"
local io = require "io"
local assert = assert
local conf

module(...)

local mt = { __index = _M }

if not conf then
    local f = assert(io.open(ngx.var.document_root .. "/etc/config.json", "r"))
    local c = f:read("*all")
    f:close()

    conf = cjson.decode(c)
end

-- The function sending subreq to nginx postgresql location with rds_json on
-- returns json body to the caller
local function dbreq(sql)
    ngx.log(ngx.ERR, 'SQL: ' .. sql)
    local dbreq = ngx.location.capture("/pg", { args = { sql = sql } })
    local json = dbreq.body
    return json
end

function max(match)
    local key = ngx.req.get_uri_args()['key']
    if not key then ngx.exit(403) end
    -- Make sure valid request, only accept plain lowercase ascii string for key name
    keytest = ngx.re.match(key, '[a-z]+', 'oj')
    if not keytest then ngx.exit(403) end

    local sql = "SELECT date_trunc('day', datetime) AS datetime, MAX("..key..") AS "..key.." FROM "..conf.db.name.." WHERE date_part('year', datetime) < 2013 GROUP BY 1"
    
    return dbreq(sql)
end

-- Latest record in db
function now(match)
    return dbreq("SELECT * FROM "..conf.db.name.." ORDER BY datetime DESC LIMIT 1")
end
-- Last 60 samples from db
function recent(match)
    return dbreq("SELECT * FROM "..conf.db.name.." ORDER BY datetime DESC LIMIT 60")
end

-- Helper function to get a start argument and return SQL constrains
local function getDateConstrains(startarg)
    local where = ''
    local andwhere = ''
    if startarg then 
        local start
        local endpart = "365 days"
        if string.upper(startarg) == 'TODAY' then
            start = "CURRENT_DATE" 
            -- XXX fixme, use postgresql function
        elseif string.upper(startarg) == '3DAY' then
            start = "CURRENT_DATE - INTERVAL '3 days'"
            endpart = '3 days'
        elseif string.upper(startarg) == 'WEEK' then
            start = "date(date_trunc('week', current_timestamp))"
            endpart = '1 week'
        elseif string.upper(startarg) == 'MONTH' then
            start = "to_date( to_char(current_date,'yyyy-MM') || '-01','yyyy-mm-dd')" 
            endpart = '1 month'
        else
            start = "DATE '" .. startarg .. "-01-01'"
        end
        local wherepart = [[
        (
            datetime BETWEEN ]]..start..[[
            AND 
            ]]..start..[[ + INTERVAL ']]..endpart..[['
        )
        ]]
        where = 'WHERE ' .. wherepart
        andwhere = 'AND ' .. wherepart
    end
    return where, andwhere
end

-- Function to return extremeties from database, min/maxes for different time intervals
function record(match)

    local key = match[1]
    local func = string.upper(match[2])
    local where, andwhere = getDateConstrains(ngx.req.get_uri_args()['start'])

    local sql = dbreq([[
        SELECT
            datetime, 
            ]]..key..[[
        FROM ]]..conf.db.name..[[ 
        WHERE
        ]]..key..[[ = (
            SELECT 
                ]]..func..[[(]]..key..[[) 
                FROM ]]..conf.db.name..[[
                ]]..where..[[
                LIMIT 1 
            )
        ]]..andwhere..[[
        LIMIT 1
        ]])
    
    return sql
end

function index()
    local sql = dbreq([[
    SELECT  
        date_trunc('hour', datetime) AS datetime,
        AVG(outtemp) as outtemp,
        MIN(outtemp) as tempmin,
        MAX(outtemp) as tempmax,
        AVG(rain) as rain,
        AVG(windspeed) as windspeed,
        AVG(winddir) as winddir,
        AVG(barometer) as barometer,
        AVG(outhumidity) as outhumidity
    FROM ]]..conf.db.name..[[ 
    WHERE datetime 
        BETWEEN now() - INTERVAL '3 days'
        AND now()
    GROUP BY 1
    ORDER BY 1
    ]])
    return sql
end

function day(match)
    --- XXX support for day as arg
    --- current day for now
    local sql = dbreq([[
    SELECT  
        *,
        outtemp as tempmin,
        outtemp as tempmax
    FROM ]]..conf.db.name..[[ 
    WHERE datetime 
        BETWEEN CURRENT_DATE
        AND CURRENT_DATE + INTERVAL '1 day'
    ORDER BY datetime
    ]])
    return sql
end

function year(match)
    local year = match[1]
    local syear = year .. '-01-01'
    local json = dbreq([[
        SELECT 
            date_trunc('day', datetime) AS datetime,
            AVG(outtemp) as outtemp,
            MIN(outtemp) as tempmin,
            MAX(outtemp) as tempmax,
            MAX(rain) as rain,
            AVG(windspeed) as windspeed,
            AVG(winddir) as winddir,
            AVG(barometer) as barometer
        FROM ]]..conf.db.name..[[ 
        WHERE datetime BETWEEN DATE ']]..syear..[['
        AND DATE ']]..syear..[[' + INTERVAL '365 days'
        GROUP BY 1
        ORDER BY 1
        ]])
    return json
end

function windhist(match)
    local where, andwhere = getDateConstrains(ngx.req.get_uri_args()['start'])
    return dbreq([[
        SELECT count(*), (winddir/10)::int*10+10 as d, avg(windspeed)*1.94384449 as avg
        FROM archive
        ]]..where..[[
        GROUP BY 2
        ORDER BY 2
    ]])
end

local class_mt = {
    -- to prevent use of casual module global variables
    __newindex = function (table, key, val)
        error('attempt to write to undeclared variable "' .. key .. '"')
    end
}

setmetatable(_M, class_mt)
