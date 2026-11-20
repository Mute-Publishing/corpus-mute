-- Module:MuteIssues
-- Lists the Mute magazine issues straight from the Wikibase items (live: edits to an item show up
-- when the page is next parsed/purged). Used by the Main Page: {{#invoke:MuteIssues|list}}
--
-- Issue items are those with "instance of" (P1) = Q1. There is no query function in wikitext, so the
-- module probes item IDs from Q4 upwards and stops after a run of IDs that do not exist.
-- Properties: P1 instance of, P4 title, P5 volume, P6 number, P7 publication date, P16 sort key.
local p = {}

local CLASS_ISSUE = 'Q1'
local FIRST_ID = 4
local MAX_GAP = 25       -- stop after this many consecutive missing IDs
local MAX_PROBES = 240   -- Wikibase limits entity loads per page (default 250); raise
                         -- $wgWBClientSettings['entityAccessLimit'] if the catalogue outgrows this

local function firstValue( entity, pid )
	local st = entity:getBestStatements( pid )[1]
	if st and st.mainsnak.snaktype == 'value' then
		return st.mainsnak.datavalue.value
	end
	return nil
end

local function isIssue( entity )
	for _, st in ipairs( entity:getBestStatements( 'P1' ) ) do
		local v = st.mainsnak.datavalue and st.mainsnak.datavalue.value
		if v and v.id == CLASS_ISSUE then
			return true
		end
	end
	return false
end

local function collect()
	local issues, gap = {}, 0
	for n = FIRST_ID, FIRST_ID + MAX_PROBES - 1 do
		local id = 'Q' .. n
		local entity = mw.wikibase.getEntity( id )
		if entity then
			gap = 0
			if isIssue( entity ) then
				local title = firstValue( entity, 'P4' )
				local date = firstValue( entity, 'P7' )
				table.insert( issues, {
					id = id,
					title = title and title.text or entity:getLabel( 'en' ) or id,
					volume = tonumber( firstValue( entity, 'P5' ) ),
					number = tonumber( firstValue( entity, 'P6' ) ),
					date = date and date.time or nil,
					sort = firstValue( entity, 'P16' ) or id,
				} )
			end
		else
			gap = gap + 1
			if gap >= MAX_GAP then
				break
			end
		end
	end
	table.sort( issues, function ( a, b ) return a.sort < b.sort end )
	return issues
end

local function formatDate( time )
	if not time then
		return nil
	end
	-- "+2013-04-00T00:00:00Z" -> "April 2013" (month precision); "+2013-00-00..." -> "2013"
	local y, m = time:match( '^%+?(%d+)%-(%d+)' )
	if not y then
		return nil
	end
	y = tonumber( y )
	m = tonumber( m )
	if m and m >= 1 and m <= 12 then
		return mw.language.getContentLanguage():formatDate( 'F Y', string.format( '%04d-%02d-01', y, m ) )
	end
	return tostring( y )
end

local function label( issue )
	local parts = {}
	if issue.volume and issue.number then
		table.insert( parts, string.format( 'Vol %d, No. %d', issue.volume, issue.number ) )
	end
	return table.concat( parts, '' )
end

function p.list( frame )
	local issues = collect()
	if #issues == 0 then
		return "''No issues found.''"
	end

	-- group by volume, keeping the sort-key order
	local order, groups = {}, {}
	for _, issue in ipairs( issues ) do
		local key = issue.volume or 0
		if not groups[key] then
			groups[key] = {}
			table.insert( order, key )
		end
		table.insert( groups[key], issue )
	end
	table.sort( order )

	local out = {}
	table.insert( out, string.format( "''%d issues, read live from the catalogue.''\n", #issues ) )
	for _, key in ipairs( order ) do
		local group = groups[key]
		table.insert( out, string.format( '=== %s (%d) ===',
			key == 0 and 'Other issues' or ( 'Volume ' .. key ), #group ) )
		for _, issue in ipairs( group ) do
			local line = { '* [[Item:' .. issue.id .. '|' }
			local lbl = label( issue )
			-- Items without a real title carry a placeholder label like "Mute Vol 1, No. 5";
			-- show just the volume/number for those instead of repeating it.
			local placeholder = issue.title:match( '^Mute Vol' ) ~= nil
			if lbl ~= '' and placeholder then
				table.insert( line, lbl .. ']]' )
			elseif lbl ~= '' then
				table.insert( line, lbl .. ' - ' .. issue.title .. ']]' )
			else
				table.insert( line, issue.title .. ']]' )
			end
			local d = formatDate( issue.date )
			if d then
				table.insert( line, ' (' .. d .. ')' )
			end
			table.insert( out, table.concat( line ) )
		end
		table.insert( out, '' )
	end
	return frame:preprocess( table.concat( out, '\n' ) )
end

return p
