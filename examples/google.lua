require 'wdm'

-- start page
local page = 'http://www.google.sk/search?q=lua'
for i=1,10 do
	-- retrieve the page
	local src = get(page)
	-- convert it to table
	local t = toTidy(src)
	
	-- get links with class "l"
	local res = getElements(t, 'tag=="a" and class=="l"')
	for _,link in ipairs(res) do
		-- print the link url and link text
		print(link.href, text(link))
	end
	
	-- get the element, whose first child is the 'next' image
	local nxt = getElements(t, 'self[1].tag=="img" and self[1].src=="nav_next.gif"')[1]
	-- construct the next url
	page = 'http://www.google.com' .. nxt.href
end