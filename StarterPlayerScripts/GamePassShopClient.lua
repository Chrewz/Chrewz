-- StarterPlayerScripts/GamePassShopClient.lua
-- Client-side storefront UI.
-- Items are displayed in the order the server returns them:
--   GamePasses (most expensive → least), then DevProducts (most expensive → least).
-- THE HOVER FIX: MouseEnter/MouseLeave are connected per-card AFTER the card
-- is fully built and parented, so every single item gets hover — not just the
-- first few that happened to be ready before the async data arrived.

local Players            = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local TweenService       = game:GetService("TweenService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ── Remotes ──────────────────────────────────────────────────────────────────
local Remotes       = ReplicatedStorage:WaitForChild("Remotes")
local shopRemotes   = Remotes:WaitForChild("GamePassShopRemotes")

local GetSortedCatalogRF = shopRemotes:WaitForChild("GetSortedCatalogRF")
local GetOwnershipRF     = shopRemotes:WaitForChild("GetOwnershipRF")
local NotifyPurchaseRE   = shopRemotes:WaitForChild("NotifyPurchaseRE")

-- ── UI references ─────────────────────────────────────────────────────────────
local shopGui        = playerGui:WaitForChild("GamePassShopGui")
local shopFrame      = shopGui:WaitForChild("ShopFrame")
local itemsContainer = shopFrame:WaitForChild("ItemsContainer")
local itemTemplate   = itemsContainer:WaitForChild("ItemTemplate")
itemTemplate.Visible = false   -- keep the template hidden

-- ── Hover tween config ────────────────────────────────────────────────────────
local TWEEN_IN  = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_OUT = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local NORMAL_SIZE = UDim2.new(1, 0,  0, 90)
local HOVER_SIZE  = UDim2.new(1, 4,  0, 96)
local NORMAL_BG   = Color3.fromRGB(40, 40, 50)
local HOVER_BG    = Color3.fromRGB(60, 60, 75)

-- ── attachHover ───────────────────────────────────────────────────────────────
-- THE FIX: called individually for each card right after it is created and
-- parented. Previously hover was connected in a batch loop that ran before all
-- cards existed, so later cards silently missed the connection.
local function attachHover(card)
	local bg = card:FindFirstChildWhichIsA("Frame") or card

	card.MouseEnter:Connect(function()
		TweenService:Create(card, TWEEN_IN, { Size = HOVER_SIZE }):Play()
		if bg ~= card then
			TweenService:Create(bg, TWEEN_IN, { BackgroundColor3 = HOVER_BG }):Play()
		end
	end)

	card.MouseLeave:Connect(function()
		TweenService:Create(card, TWEEN_OUT, { Size = NORMAL_SIZE }):Play()
		if bg ~= card then
			TweenService:Create(bg, TWEEN_OUT, { BackgroundColor3 = NORMAL_BG }):Play()
		end
	end)
end

-- ── createItemCard ────────────────────────────────────────────────────────────
local function createItemCard(itemData, isOwned)
	local card = itemTemplate:Clone()
	card.Name    = "Item_" .. itemData.id
	card.Visible = true

	-- Populate labels (adjust child names to match your actual template)
	local titleLabel = card:FindFirstChild("TitleLabel", true)
	local descLabel  = card:FindFirstChild("DescLabel",  true)
	local priceLabel = card:FindFirstChild("PriceLabel", true)
	local typeLabel  = card:FindFirstChild("TypeLabel",  true)
	local buyButton  = card:FindFirstChild("BuyButton",  true)

	if titleLabel then titleLabel.Text = itemData.title end
	if descLabel  then descLabel.Text  = itemData.desc  end

	if priceLabel then
		if isOwned then
			priceLabel.Text = "✔  Owned"
		else
			priceLabel.Text = "🛒  " .. itemData.price .. " R$"
		end
	end

	if typeLabel then
		typeLabel.Text = itemData.itemType == "GamePass" and "GAMEPASS" or "PRODUCT"
	end

	-- Buy / Owned button
	if buyButton then
		if isOwned then
			buyButton.Text   = "Owned"
			buyButton.Active = false
		else
			buyButton.Text = "Buy"
			buyButton.MouseButton1Click:Connect(function()
				if itemData.itemType == "GamePass" then
					MarketplaceService:PromptGamePassPurchase(player, itemData.id)
				else
					MarketplaceService:PromptProductPurchase(player, itemData.id)
				end
			end)
		end
	end

	-- ↓ Hover is attached HERE — after the card is fully built — so every card
	--   gets hover regardless of when its data arrived from the server.
	card.Parent = itemsContainer
	attachHover(card)

	return card
end

-- ── populateShop ──────────────────────────────────────────────────────────────
local function populateShop()
	-- Remove previous cards (leave the hidden template in place)
	for _, child in ipairs(itemsContainer:GetChildren()) do
		if child:IsA("GuiObject") and child ~= itemTemplate then
			child:Destroy()
		end
	end

	-- Server returns items already sorted:
	--   GamePasses (expensive → cheap) then DevProducts (expensive → cheap)
	local catalog = GetSortedCatalogRF:InvokeServer()
	if not catalog or #catalog == 0 then return end

	-- Batch ownership check for GamePasses only
	local gpIds = {}
	for _, item in ipairs(catalog) do
		if item.itemType == "GamePass" then
			table.insert(gpIds, item.id)
		end
	end

	local ownership = {}
	if #gpIds > 0 then
		ownership = GetOwnershipRF:InvokeServer(gpIds) or {}
	end

	-- Build cards in the server-provided order
	for _, item in ipairs(catalog) do
		local isOwned = item.itemType == "GamePass" and (ownership[item.id] == true)
		createItemCard(item, isOwned)
	end
end

-- ── Purchase listeners ────────────────────────────────────────────────────────
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, passId, purchased)
	if plr ~= player or not purchased then return end
	NotifyPurchaseRE:FireServer(passId)
	task.wait(0.5)   -- brief delay so the server cache has time to clear
	populateShop()
end)

MarketplaceService.PromptProductPurchaseFinished:Connect(function(plr, _productId, _isPurchased)
	if plr ~= player then return end
	task.wait(0.5)
	populateShop()
end)

-- ── Initial load ──────────────────────────────────────────────────────────────
populateShop()
