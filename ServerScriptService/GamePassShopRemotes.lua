-- ServerScriptService/GamePassShopRemotes.lua
-- Creates/ensures Remotes.GamePassShopRemotes.* functions used by the client storefront UI.
-- Items are automatically sorted most-expensive → least-expensive,
-- with all GamePasses listed before DevProducts.

local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local MarketplaceService = game:GetService("MarketplaceService")

-- ── GamepassService (catalog + ownership) ───────────────────────────────────
local GamepassService
do
	local ok, gm = pcall(function()
		return require(ServerScriptService.Modules:WaitForChild("GamepassService"))
	end)
	if ok and gm then GamepassService = gm end
end

-- ── Remotes folder ───────────────────────────────────────────────────────────
local RemotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not RemotesFolder then
	RemotesFolder = Instance.new("Folder")
	RemotesFolder.Name = "Remotes"
	RemotesFolder.Parent = ReplicatedStorage
end

local shopRemotes = RemotesFolder:FindFirstChild("GamePassShopRemotes")
if not shopRemotes then
	shopRemotes = Instance.new("Folder")
	shopRemotes.Name = "GamePassShopRemotes"
	shopRemotes.Parent = RemotesFolder
end

-- ── Price cache (avoid hammering the catalog API) ────────────────────────────
-- Keys: numeric id for GamePasses, "dp_<id>" for DevProducts.
local priceCache = {}

local function getGamepassPrice(id)
	if priceCache[id] ~= nil then return priceCache[id] end
	local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, id, Enum.InfoType.GamePass)
	local price = (ok and info and info.PriceInRobux) or 0
	priceCache[id] = price
	return price
end

local function getDevProductPrice(id)
	local key = "dp_" .. id
	if priceCache[key] ~= nil then return priceCache[key] end
	local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, id, Enum.InfoType.Product)
	local price = (ok and info and info.PriceInRobux) or 0
	priceCache[key] = price
	return price
end

-- ── Helper: ensure a RemoteFunction exists ───────────────────────────────────
local function ensureRemoteFunction(name)
	local rf = shopRemotes:FindFirstChild(name)
	if not rf then
		rf = Instance.new("RemoteFunction")
		rf.Name = name
		rf.Parent = shopRemotes
	end
	return rf
end

local function ensureRemoteEvent(name)
	local re = shopRemotes:FindFirstChild(name)
	if not re then
		re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = shopRemotes
	end
	return re
end

-- ── GetSortedCatalogRF ───────────────────────────────────────────────────────
-- Returns an ordered array of all shop items.
-- Each entry: { id, title, desc, price, itemType ("GamePass" | "DevProduct") }
-- Order: GamePasses (most expensive → least), then DevProducts (most expensive → least).
local GetSortedCatalogRF = ensureRemoteFunction("GetSortedCatalogRF")

GetSortedCatalogRF.OnServerInvoke = function(_player)
	local gamepasses  = {}
	local devproducts = {}

	if GamepassService then
		-- Collect GamePasses
		if GamepassService.CATALOG then
			for rawId, data in pairs(GamepassService.CATALOG) do
				local id = tonumber(rawId)
				if id then
					table.insert(gamepasses, {
						id       = id,
						title    = data.title or ("GamePass " .. id),
						desc     = data.desc  or "",
						price    = getGamepassPrice(id),
						itemType = "GamePass",
					})
				end
			end
		end

		-- Collect DevProducts
		if GamepassService.DEVPRODUCTS then
			for rawId, data in pairs(GamepassService.DEVPRODUCTS) do
				local id = tonumber(rawId)
				if id then
					table.insert(devproducts, {
						id       = id,
						title    = data.title or ("Product " .. id),
						desc     = data.desc  or "",
						price    = getDevProductPrice(id),
						itemType = "DevProduct",
					})
				end
			end
		end
	end

	-- Sort each group: most expensive first
	table.sort(gamepasses,  function(a, b) return a.price > b.price end)
	table.sort(devproducts, function(a, b) return a.price > b.price end)

	-- Combine: all GamePasses first, then DevProducts
	local result = {}
	for _, item in ipairs(gamepasses)  do table.insert(result, item) end
	for _, item in ipairs(devproducts) do table.insert(result, item) end
	return result
end

-- ── GetCatalogRF ─────────────────────────────────────────────────────────────
-- Returns a table mapping id → { title, desc, price } for the requested GamePass ids.
local GetCatalogRF = ensureRemoteFunction("GetCatalogRF")

GetCatalogRF.OnServerInvoke = function(_player, requestedIds)
	local out = {}
	if GamepassService and GamepassService.CATALOG then
		for _, rawId in ipairs(requestedIds or {}) do
			local id = tonumber(rawId)
			if id and GamepassService.CATALOG[id] then
				out[id] = {
					title = GamepassService.CATALOG[id].title,
					desc  = GamepassService.CATALOG[id].desc,
					price = getGamepassPrice(id),
				}
			end
		end
	end
	return out
end

-- ── GetOwnershipRF ───────────────────────────────────────────────────────────
-- Accepts an array of GamePass ids, returns { [id] = true/false }.
local GetOwnershipRF = ensureRemoteFunction("GetOwnershipRF")

GetOwnershipRF.OnServerInvoke = function(player, requestedIds)
	local out = {}
	if not GamepassService then
		for _, rawId in ipairs(requestedIds or {}) do
			local id = tonumber(rawId)
			if id then out[id] = false end
		end
		return out
	end
	for _, rawId in ipairs(requestedIds or {}) do
		local id = tonumber(rawId)
		if id and id > 0 then
			local ok, owns = pcall(function()
				return GamepassService:Owns(player, id)
			end)
			out[id] = ok and (owns == true) or false
		end
	end
	return out
end

-- ── NotifyPurchaseRE ─────────────────────────────────────────────────────────
-- Client fires this after a successful purchase prompt so the server can clear
-- ownership caches and allow fresh checks.
local NotifyPurchaseRE = ensureRemoteEvent("NotifyPurchaseRE")

NotifyPurchaseRE.OnServerEvent:Connect(function(player, passId)
	if typeof(passId) ~= "number" then return end

	-- Invalidate the price cache entry so it re-fetches on next catalog request
	priceCache[passId]          = nil
	priceCache["dp_" .. passId] = nil

	-- Clear the ownership cache so the next :Owns() call goes to Roblox fresh
	if GamepassService then
		pcall(function()
			GamepassService:Clear(player)
		end)
	end
end)
