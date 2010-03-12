require 'luasql.sqlite3'

-- handle luacurl and Lua-cURL
pcall(require, 'curl')
pcall(require, 'luacurl')
assert(curl, "curl library not found (luacurl or Lua-cURL)")

-- optional iconv
pcall(require, 'iconv')

-- optional compression
pcall(require, 'bz2')

-- optional html tidy
pcall(require, 'tidy')

-- Charset conversion
if iconv then
	local ic = iconv.new('utf8', 'windows-1250')
	function toUtf8(s)
		return ic:iconv(s)
	end

	function encoding(e)
		ic = iconv.new('utf8', e)
	end
end

function log(...)
	if verbose then
		print(...)
	end
end

-- XML
do
	local function decode(s)
		return (s:gsub('&(.-);', { amp = '&', lt = '<', gt = '>', nbsp = ' ' }))
	end

	-- modified Roberto's XML parser http://lua-users.org/wiki/LuaXml to behave like the
	-- one from Yutaka Ueno - creates flatter trees
	function parseargs(xml, s, parent)
		local arg = setmetatable({xml=xml}, {__index = {parent = parent}})
		string.gsub(s, "(%w+)=([\"'])(.-)%2", function (w, _, a)
			arg[w] = decode(a)
		end)
		return arg
	end

	function toXml(s)
		local stack = {}
		local top = {}
		table.insert(stack, top)
		local ni,c,label,xarg, empty
		local i, j = 1, 1
		while true do
			ni,j,c,label,xarg, empty = string.find(s, "<(%/?)([%?%w]+)(.-)(%/?)>", i)
			if not ni then break end
			local text = string.sub(s, i, ni-1)
			if not string.find(text, "^%s*$") then
				table.insert(top, decode(text))
			end
			if empty == "/" then  -- empty element tag
				table.insert(top, parseargs(label, xarg, top))
			elseif c == "" then   -- start tag
				top = parseargs(label, xarg, top)
				table.insert(stack, top)   -- new level
			else  -- end tag
				local toclose = table.remove(stack)  -- remove top
				top = stack[#stack]
				if #stack < 1 then
					error("nothing to close with "..label)
				end
				if toclose.xml ~= label then
					error("trying to close "..toclose.xml.." with "..label)
				end
				table.insert(top, toclose)
			end
			i = j+1
		end
		local text = string.sub(s, i)
		if not string.find(text, "^%s*$") then
			table.insert(stack[#stack], text)
		end
		if #stack > 1 then
			error("unclosed "..stack[#stack].xml)
		end
		return stack[1]
	end

	if tidy then
		local tidy = tidy.new()
		tidy:setCharEncoding("utf8")

		-- returns a LOM-like (http://www.keplerproject.org/luaexpat/lom.html) table 
		function toTidy(s)
			tidy:parse(s)
			return tidy:toTable()
		end
	end

	-- flatten text from a table
	function text(x)
		if type(x) == "string" then return x end
		local res = {}
		local function r(z)
			for _,v in ipairs(z) do
				if type(v) == "string" then table.insert(res, v)
				elseif type(v) == "table" then r(v)
				end
			end
		end
		r(x)
		return table.concat(res)
	end

	-- simple dumping
	function repr(x)
		local function r(x, i)
			local s = ("+"):rep(i)
			for k,v in pairs(x) do
				print(s .. tostring(k) .. ' = ' .. tostring(v))
				if type(v) == "table" then r(v, i+1) end
			end
		end
		r(x, 0)
	end

	function trim(s)
		assert(type(s) == "string", "cannot trim "..type(s))
		return (s:gsub("^%s*(.-)%s*$", "%1"))
	end

	-- quasi-XPath: accepts a table and a string/function condition
	-- returns an array of elements, for which the function returns true
	-- during iteration, the environment for the condition is set to each element
	local code_cache = setmetatable({}, {__mode="v"})
	function getElements(doc, cond)
		local res = {}
		if type(cond) == "string" then
			if code_cache[cond] then cond = code_cache[cond] else
				cond = assert(loadstring('return function() return '..cond..' end'))()
				code_cache[cond] = cond
			end
		else
			cond = cond or function() return true end
		end

		local default = {}
		setmetatable(default, {__index = function() return default end})
		local current
		local env = setmetatable({}, {__index = function(t,k)
			if current[k] then return current[k]  else return default end
		end})
		setfenv(cond, env)

		local function findElements(x)
			for _,e in ipairs(x or {}) do
				if type(e) == 'table' then
					current = e
					if cond(e) then
						table.insert(res, e)
					end
					findElements(e)
				end
			end
		end
		findElements(doc)
		return res
	end
end

-- Database
do
	local sqlite3 = assert(luasql.sqlite3())
	local db = assert(sqlite3:connect('database.db'))

	-- simplified access to SQL - returns an iterator function in case of SELECT
	function sql(s)
		log('[sql]', s)
		local cur, err = db:execute(s)
		assert(cur, (err or '')..' in '..s)
		if type(cur) == 'number' then
			return cur
		else
			return function()
				return cur:fetch()
			end
		end
	end

	function lastid()
		return db:getlastautoid()
	end
end

-- HTTP Downloading
do
	local c=curl.new and curl.new() or curl.easy_init()

	local filters = {}
	function addFilter(f) table.insert(filters, f) end
	function clearFilters() filters = {} end

	do
		local f = io.open('cache/TEST.txt', 'w')
		if not f then
			os.execute('mkdir cache')
		else
			f:close()
			os.remove('cache/TEST.txt')
		end
	end
	
	local function open(fn, mode)
		return bz2 and bz2.open(fn, mode, 9) or io.open(fn, mode)
	end

	local function getlocal(url)
		local path = url:gsub('[^%a%d]', '_')
		local f, e = open('cache/'..path)
		if f then
			local ret = f:read('*a')
			f:close()
			return ret
		end
	end

	local function writelocal(url, s)
		local path = url:gsub('[^%a%d]', '_')
		local f = assert(open('cache/'..path, 'wb'))
		f:write(s)
		f:close()
	end

	function get(url)
		log('[http]', 'get', url)

		local cache = getlocal(url)
		if cache then return cache end

		c:setopt(curl.OPT_URL,url)
		local t = {}
		c:setopt(curl.OPT_WRITEFUNCTION, function (a, b)
			local s
			-- luacurl and Lua-cURL friendly
			if type(a) == "string" then s = a else s = b end
			table.insert(t, s)
			return #s
		end)
		assert(c:perform())
		local ret = table.concat(t)
		for _,f in ipairs(filters) do
			ret = f(ret)
		end

		writelocal(url, ret)

		return ret
	end
end
