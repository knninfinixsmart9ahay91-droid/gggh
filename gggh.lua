-- Kenn Hub | Delta (Android) | Luau
-- Enable: TP ke tiap telur di area filter, pukul sebentar, langsung pindah ke telur lain
-- Break Anywhere: hit telur tanpa pindah karakter (stream area dari jarak jauh)
-- Auto Swing, Auto Steal (Instant/Safe/Walk/Anywhere), Auto Treadmill
-- Stealth Mode: jeda antar aksi diacak biar nggak kelihatan pola bot
-- FPS Boost: turunin quality/efek buat performa, reversible
-- Break Only, Skip Anim, Filter Area
-- Event: Farm Diamond (magnet, sedot diamond drop di sekitar pas break)

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local lp = Players.LocalPlayer
local T0 = os.clock()

local CONFIG = {
	LOGO_ID = "",
	HITS_PER_EGG = 1,
	SETTLE = 0.1,
	AFTER_HIT = 0.12,
	HIT_DELAY = 0.2,
	SWING_DELAY = 0.15,
	LOOP_DELAY = 0.05,
	NEAR_DISTANCE = 22,
	TELEPORT_OFFSET = Vector3.new(0, 4, 5),
	STREAM_MAX = 4,
	GHOST_COOLDOWN = 10,
	BLOCK_AFTER_REJECTS = 8,
	BLOCK_FOR = 30,
	RESCAN_EVERY = 1.5,
	-- auto steal
	STEAL_KEYS = { "steal", "curi", "grab", "rob" },
	SAFE_RADIUS = 45,
	STEAL_COOLDOWN = 6,
	STEAL_AFTER = 0.6,
	-- alur steal: ambil hewan -> nabrak penjaga -> bawa ke safe zone
	GUARD_KEYS = { "guard", "penjaga", "sentry", "security", "bouncer" },
	SAFEZONE_KEYS = { "area aman", "safezone", "safe zone", "safe_zone", "safearea", "safe area", "deposit", "dropoff", "drop off" },
	GUARD_RANGE = 150,
	CARRY_WAIT = 0.2,
	BUMP_TIME = 0.25,
	SAFE_STAY = 0.5,
	DROP_KEYS = { "drop", "letakkan", "taruh", "lepas", "release", "putdown", "letgo" },
	PICKUP_KEYS = { "pickup", "pick up", "ambil", "take", "carry" },
	REC_KEYS = { "steal", "drop", "pickup", "carry", "grab", "release", "safezone" },
	DROP_WAIT = 0.3,
	REPICK_DELAY = 5, -- jeda (detik) antara drop dan ambil lagi
	PICK_RANGE = 30,
	-- pengaman respawn: berhenti kalau mati terlalu sering pas steal
	DEATH_WINDOW = 90,
	MAX_DEATHS = 3,
	RESPAWN_SETTLE = 2.5,
	-- titik drop (di luar Area Aman) & titik aman (di dalam Area Aman)
	AREA_TEXTS = { "area aman", "safe area", "safe zone", "safezone" },
	DROP_OUT = 10,
	SAFE_IN = 12,
	WALK_IN = true,
	WALK_IN_TIME = 4,
	WALK_TIMEOUT = 20,
	-- auto treadmill
	TREADMILL_STAY = 10,
	TREADMILL_PROMPT_EVERY = 6,
	TREADMILL_RESCAN = 3,
	-- break anywhere
	ANYWHERE_RESCAN = 3,
	ANYWHERE_STREAM_RADIUS = 80,
	-- stealth
	STEALTH_JITTER = 0.25,
	-- event: farm diamond (magnet, jalan bareng break)
	DIAMOND_KEYS = { "diamond", "berlian" },
	DIAMOND_SKIP = { "treadmill", "teleport", "shop", "button" },
	DIAMOND_RANGE = 80, -- radius magnet (stud) dari karakter
	DIAMOND_RESCAN = 0.6,
	DIAMOND_STEP = 0.1,
	DIAMOND_RETRY = 1.5,
	DIAMOND_PULL = true, -- tarik diamond ke karakter sebelum disentuh
	HATCH_KEYS = { "hatch", "reveal", "opening", "eggopen", "petopen", "newpet", "congrat" },
}

-- urutan = nomor zone (Zone1 = Forest, Zone2 = Desert, ...)
local AREAS = {
	"All", "Forest", "Desert", "Snowy", "Candy", "Swamp", "Ocean",
	"Volcano (Hell)", "Blossom", "Galaxy", "Planet X",
	"Haunted Graveyard", "Fairy Castle", "Fantasy Expansion", "Other",
}

local NAME_KEYS = {
	["Haunted Graveyard"] = { "hauntedgraveyard", "graveyard", "haunted" },
	["Fairy Castle"] = { "fairycastle", "fairy" },
	["Fantasy Expansion"] = { "fantasyexpansion", "fantasy", "expansion" },
}

local STEAL_MODES = { "Instant", "Safe", "Walk", "Anywhere" }

local State = {
	enabled = false, autoSwing = true, autoSteal = false, autoTreadmill = false,
	breakAnywhere = false, stealth = true, fpsBoost = false,
	stealMode = "Instant", breakOnly = false, skipAnim = true,
	dropFirst = true, bumpGuard = true, farmDiamond = false,
	area = "All", alive = true,
}
local hitRemote = RS:WaitForChild("EggHitRequest", 5)
local hitArg = 2
local hitName = "Egg"
local hitDelay = CONFIG.HIT_DELAY
local rejects, landed = 0, 0
local lastReject = ""
local cache, lastScan = {}, 0
local visited, ghostCool = {}, {}
local known, anchors = {}, {}
local areaRejects, blocked = {}, {}
local curArea = nil
local statusText = ""
local stealText = ""
local areaCount = 0
local stealing = false
local stealCount = 0
local gains, firstGain = 0, nil
local recorded = {}
local lastAnywhereStream = 0
local dropLearn, uiSync, stealStopMsg, manualDrop, manualSafe = nil, nil, "", nil, nil
local gui

local function norm(s)
	return (string.lower(s):gsub("[^%w]", ""))
end

local function hasAny(str, list)
	str = string.lower(str)
	for _, k in ipairs(list) do
		if string.find(str, k, 1, true) then return true end
	end
	return false
end

-- Stealth Mode: acak jeda antar aksi biar nggak membentuk pola waktu yang identik
local function jitter(base)
	if not State.stealth then return base end
	local f = 1 + (math.random() * 2 - 1) * CONFIG.STEALTH_JITTER
	return math.max(0.02, base * f)
end

local function serArgs(...)
	local a, p = table.pack(...), {}
	for i = 1, a.n do
		local v = a[i]
		p[i] = typeof(v) == "Instance" and v.Name or tostring(v)
	end
	return table.concat(p, ", ")
end

local function recordCall(nm, m, args)
	local parts = {}
	for i = 1, args.n do
		local v = args[i]
		if typeof(v) == "Instance" then
			parts[i] = "<" .. v:GetFullName() .. ">"
		else
			parts[i] = tostring(v) .. " (" .. typeof(v) .. ")"
		end
	end
	if #recorded >= 25 then table.remove(recorded, 1) end
	table.insert(recorded, string.format("[%.1fs] %s:%s(%s)", os.clock() - T0, nm, m, table.concat(parts, ", ")))
end

pcall(function()
	if hookmetamethod and getnamecallmethod then
		local old
		old = hookmetamethod(game, "__namecall", (newcclosure or function(f) return f end)(function(self, ...)
			local m = getnamecallmethod()
			if (m == "FireServer" or m == "InvokeServer") and not (checkcaller and checkcaller()) then
				if self == hitRemote and m == "FireServer" then
					local a = table.pack(...)
					if typeof(a[2]) == "number" then hitArg = a[2] end
					if typeof(a[1]) == "Instance" then hitName = a[1].Name end
				end
				local ok, nm = pcall(function() return self.Name end)
				if ok and type(nm) == "string" then
					local lnm = string.lower(nm)
					if string.find(lnm, "treadmill", 1, true) or hasAny(lnm, CONFIG.REC_KEYS) then
						local args = table.pack(...)
						task.defer(recordCall, nm, m, args)
						if m == "FireServer" and hasAny(lnm, CONFIG.DROP_KEYS) then
							dropLearn = { remote = self, args = args }
						end
					end
				end
			end
			return old(self, ...)
		end))
	end
end)

pcall(function()
	local rej = RS:FindFirstChild("EggHitRejected")
	if rej and rej:IsA("RemoteEvent") then
		rej.OnClientEvent:Connect(function(...)
			rejects = rejects + 1
			hitDelay = math.min(hitDelay + 0.05, 0.6)
			lastReject = serArgs(...)
			if curArea then
				areaRejects[curArea] = (areaRejects[curArea] or 0) + 1
				if areaRejects[curArea] >= CONFIG.BLOCK_AFTER_REJECTS then
					blocked[curArea] = os.clock() + CONFIG.BLOCK_FOR
					areaRejects[curArea] = 0
					print("[KennHub] " .. curArea .. " ditolak terus, skip dulu. Alasan terakhir: " .. lastReject)
				end
			end
		end)
	end
	for _, n in ipairs({ "EggHitConfirmed", "EggHitLanded" }) do
		local r = RS:FindFirstChild(n)
		if r and r:IsA("RemoteEvent") then
			r.OnClientEvent:Connect(function()
				landed = landed + 1
				if curArea then areaRejects[curArea] = 0 end
			end)
		end
	end
	local sg = RS:FindFirstChild("SpeedGainRemote")
	if sg and sg:IsA("RemoteEvent") then
		sg.OnClientEvent:Connect(function(...)
			gains = gains + 1
			if not firstGain then firstGain = serArgs(...) end
		end)
	end
end)

----------------------------------------------------------------
-- Skip animasi hatch
----------------------------------------------------------------
local function hideHatch(inst)
	if gui and inst:IsDescendantOf(gui) then return end
	if not hasAny(inst.Name, CONFIG.HATCH_KEYS) then return end
	if inst:IsA("ScreenGui") then
		inst.Enabled = false
	elseif inst:IsA("Frame") or inst:IsA("ViewportFrame") or inst:IsA("ImageLabel") then
		inst.Visible = false
	end
end

local function fixCamera()
	local cam = workspace.CurrentCamera
	local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
	if cam and hum then
		if cam.CameraType ~= Enum.CameraType.Custom then cam.CameraType = Enum.CameraType.Custom end
		if cam.CameraSubject ~= hum then cam.CameraSubject = hum end
	end
end

task.spawn(function()
	local pg = lp:WaitForChild("PlayerGui")
	pg.DescendantAdded:Connect(function(d)
		if State.skipAnim and State.alive then task.defer(hideHatch, d) end
	end)
end)

----------------------------------------------------------------
-- Swing
----------------------------------------------------------------
local function swing()
	local char = lp.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local tool = char:FindFirstChildOfClass("Tool")
	if not tool then
		local bp = lp:FindFirstChild("Backpack")
		if bp then
			for _, t in ipairs(bp:GetChildren()) do
				if t:IsA("Tool") and string.find(string.lower(t.Name), "pickaxe", 1, true) then
					tool = t
					break
				end
			end
			tool = tool or bp:FindFirstChildOfClass("Tool")
		end
		if tool and hum then pcall(function() hum:EquipTool(tool) end) end
	end
	if tool then pcall(function() tool:Activate() end) end
end

task.spawn(function()
	while State.alive do
		if State.enabled and State.autoSwing then
			swing()
			task.wait(jitter(CONFIG.SWING_DELAY))
		else
			task.wait(0.2)
		end
	end
end)

----------------------------------------------------------------
-- Logika telur
----------------------------------------------------------------
local function hitPart(model)
	local p = model:FindFirstChild(hitName, true) or model:FindFirstChild("Egg", true)
	if p and p:IsA("BasePart") then return p end
	local best, size
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if not size or v > size then best, size = d, v end
		end
	end
	return best
end

local function hit(model)
	swing()
	local part = hitPart(model)
	if hitRemote and part then
		pcall(function() hitRemote:FireServer(part, hitArg) end)
	end
end

local function zoneNumber(inst)
	local cur = inst
	while cur and cur ~= workspace do
		local n = tonumber(string.match(cur.Name, "^[Zz]one%s*(%d+)"))
		if n then return n end
		cur = cur.Parent
	end
	return nil
end

local function ancestorModel(inst)
	local cur = inst.Parent
	while cur and cur ~= workspace do
		if cur:IsA("Model") then return cur end
		cur = cur.Parent
	end
	return nil
end

local function zonePosition(z)
	local eggs = z:FindFirstChild("Eggs", true)
	if eggs then
		for _, e in ipairs(eggs:GetChildren()) do
			local ok, cf = pcall(function() return e:GetPivot() end)
			if ok and cf.Position.Magnitude > 1 then return cf.Position end
		end
	end
	local minV, maxV
	for _, d in ipairs(z:GetDescendants()) do
		if d:IsA("BasePart") then
			local p = d.Position
			if not minV then
				minV, maxV = p, p
			else
				minV = Vector3.new(math.min(minV.X, p.X), math.min(minV.Y, p.Y), math.min(minV.Z, p.Z))
				maxV = Vector3.new(math.max(maxV.X, p.X), math.max(maxV.Y, p.Y), math.max(maxV.Z, p.Z))
			end
		end
	end
	if minV then
		local c = (minV + maxV) / 2
		return Vector3.new(c.X, maxV.Y + 8, c.Z)
	end
	if z:IsA("Model") then
		local ok, cf = pcall(function() return z:GetPivot() end)
		if ok and cf.Position.Magnitude > 1 then
			return cf.Position + Vector3.new(0, 10, 0)
		end
	end
	return nil
end

local function buildAnchors()
	local build = workspace:FindFirstChild("Build")
	local zb = build and build:FindFirstChild("ZoneBuilds")
	if zb then
		for _, z in ipairs(zb:GetChildren()) do
			local n = tonumber(string.match(z.Name, "(%d+)"))
			local areaName = n and AREAS[n + 1]
			if areaName and areaName ~= "Other" and areaName ~= "All" then
				local pos = zonePosition(z)
				if pos then anchors[areaName] = pos end
			end
		end
	end
	if build then
		local pool = {}
		for _, d in ipairs(build:GetDescendants()) do
			if d:IsA("Model") or d:IsA("Folder") then table.insert(pool, d) end
		end
		for areaName, keys in pairs(NAME_KEYS) do
			if not anchors[areaName] then
				for _, key in ipairs(keys) do
					for _, d in ipairs(pool) do
						if string.find(norm(d.Name), key, 1, true) then
							local pos = zonePosition(d)
							if pos then anchors[areaName] = pos break end
						end
					end
					if anchors[areaName] then break end
				end
			end
		end
	end
end

-- Break Anywhere: minta game nge-stream area tanpa memindahkan karakter
local function streamAreas()
	if State.area == "All" then
		for _, pos in pairs(anchors) do
			pcall(function() lp:RequestStreamAroundAsync(pos, CONFIG.ANYWHERE_STREAM_RADIUS) end)
		end
	else
		local pos = anchors[State.area]
		if pos then pcall(function() lp:RequestStreamAroundAsync(pos, CONFIG.ANYWHERE_STREAM_RADIUS) end) end
	end
end

local function collect()
	local out, seen, counts, seenKeys = {}, {}, {}, {}
	local function add(model)
		if not model or seen[model] then return end
		seen[model] = true
		local n = zoneNumber(model)
		local areaName = (n and AREAS[n + 1] and AREAS[n + 1] ~= "Other") and AREAS[n + 1] or "Other"
		local key = model:GetFullName()
		seenKeys[key] = true
		local ok, cf = pcall(function() return model:GetPivot() end)
		if ok then known[key] = { pos = cf.Position, area = areaName } end
		counts[areaName] = (counts[areaName] or 0) + 1
		table.insert(out, { model = model, area = areaName, key = key })
	end

	for _, d in ipairs(workspace:GetDescendants()) do
		if d.Name == "EggInfoUi" or d.Name == "EggOverhead" then
			add(ancestorModel(d))
		elseif d.Name == "Eggs" and (d:IsA("Folder") or d:IsA("Model")) then
			for _, e in ipairs(d:GetChildren()) do
				if e:IsA("Model") then add(e) end
			end
		end
	end

	local areaHasEgg = {}
	for key, k in pairs(known) do
		areaHasEgg[k.area] = true
		if not seenKeys[key] then
			table.insert(out, { ghost = true, pos = k.pos, area = k.area, key = key })
		end
	end
	for areaName, pos in pairs(anchors) do
		if not areaHasEgg[areaName] and not counts[areaName] then
			table.insert(out, { ghost = true, pos = pos, area = areaName, key = "anchor:" .. areaName })
		end
	end

	local c = 0
	for _ in pairs(counts) do c = c + 1 end
	areaCount = c
	return out, counts
end

local function refresh(force, verbose)
	if force or os.clock() - lastScan > CONFIG.RESCAN_EVERY then
		local ok, res, counts = pcall(collect)
		if ok then
			cache = res
			if verbose and counts then
				local parts = {}
				for k, v in pairs(counts) do table.insert(parts, k .. "=" .. v) end
				print("[KennHub] telur ke-load per area: " .. table.concat(parts, ", "))
			end
		end
		lastScan = os.clock()
	end
end

local function hrp()
	local c = lp.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function isUsable(t)
	if not t.model or not t.model.Parent then return false end
	local part = hitPart(t.model)
	if not part then return false end
	if part.Transparency >= 0.99 then return false end
	return true
end

local function inArea(t)
	return State.area == "All" or t.area == State.area
end

local function pickNext(root)
	local best, bestD, ghost, ghostD
	local now = os.clock()
	for _, t in ipairs(cache) do
		if inArea(t) and not visited[t.key] and not (blocked[t.area] and blocked[t.area] > now) then
			if t.ghost then
				if not State.breakOnly and not (ghostCool[t.key] and ghostCool[t.key] > now) then
					local d = (t.pos - root.Position).Magnitude
					if not ghostD or d < ghostD then ghost, ghostD = t, d end
				end
			elseif isUsable(t) then
				local d = (t.model:GetPivot().Position - root.Position).Magnitude
				if (not State.breakOnly or d <= CONFIG.NEAR_DISTANCE) and (not bestD or d < bestD) then
					best, bestD = t, d
				end
			end
		end
	end
	return best or ghost
end

local function loadArea(root, t)
	statusText = "Muat area: " .. t.area
	pcall(function() lp:RequestStreamAroundAsync(t.pos, 4) end)
	root.CFrame = CFrame.new(t.pos + CONFIG.TELEPORT_OFFSET)
	pcall(function() root.Anchored = true end)
	local t0 = os.clock()
	while os.clock() - t0 < CONFIG.STREAM_MAX and State.enabled and State.alive do
		task.wait(0.25)
		refresh(true)
		local found = false
		for _, c in ipairs(cache) do
			if c.area == t.area and not c.ghost then found = true break end
		end
		if found then break end
	end
	pcall(function() root.Anchored = false end)
end

local wasEnabled, lastArea = false, State.area

task.spawn(function()
	while State.alive do
		if State.enabled then
			while stealing and State.alive do task.wait(0.1) end

			if State.breakAnywhere then
				if os.clock() - lastAnywhereStream > CONFIG.ANYWHERE_RESCAN then
					streamAreas()
					lastAnywhereStream = os.clock()
				end
				refresh(false)

				local t = nil
				for _, c in ipairs(cache) do
					if inArea(c) and not c.ghost and isUsable(c) and not visited[c.key] then
						t = c
						break
					end
				end

				if t then
					visited[t.key] = true
					for i = 1, CONFIG.HITS_PER_EGG do
						if not (State.enabled and State.alive) then break end
						hit(t.model)
						task.wait(jitter(hitDelay))
					end
					statusText = "[Anywhere][" .. t.area .. "] " .. t.model.Name
					task.wait(jitter(CONFIG.AFTER_HIT))
				else
					visited = {}
					statusText = "Anywhere: muat/muter ulang..."
					task.wait(0.5)
				end
			else
				local root = hrp()
				if root then
					if not wasEnabled or lastArea ~= State.area then
						visited, blocked, areaRejects = {}, {}, {}
						refresh(true, true)
					end
					wasEnabled, lastArea = true, State.area
					refresh(false)
					if State.skipAnim then fixCamera() end

					local t = pickNext(root)
					if t then
						visited[t.key] = true
						curArea = t.area
						if t.ghost then
							ghostCool[t.key] = os.clock() + CONFIG.GHOST_COOLDOWN
							loadArea(root, t)
						else
							if not State.breakOnly then
								root.CFrame = CFrame.new(t.model:GetPivot().Position + CONFIG.TELEPORT_OFFSET)
								task.wait(jitter(CONFIG.SETTLE))
							end
							for _ = 1, CONFIG.HITS_PER_EGG do
								if not (State.enabled and State.alive) then break end
								hit(t.model)
								task.wait(jitter(hitDelay))
							end
							statusText = "[" .. t.area .. "] " .. t.model.Name
							task.wait(jitter(CONFIG.AFTER_HIT))
						end
					else
						visited = {}
						refresh(true)
						statusText = "Muter ulang..."
						task.wait(0.4)
					end
				end
			end
		else
			wasEnabled = false
			statusText = "Mati"
		end
		task.wait(jitter(CONFIG.LOOP_DELAY))
	end
end)

----------------------------------------------------------------
-- Auto Steal
----------------------------------------------------------------
local home = nil
do
	local r = hrp()
	if r then home = r.Position end
end

local function ownsInst(inst)
	local function matches(v)
		return v == lp.UserId or v == lp.Name or v == lp.DisplayName
			or v == tostring(lp.UserId) or (typeof(v) == "Instance" and v == lp)
	end
	for _, v in pairs(inst:GetAttributes()) do
		if matches(v) then return true end
	end
	for _, c in ipairs(inst:GetChildren()) do
		if c:IsA("ValueBase") then
			local ok, v = pcall(function() return c.Value end)
			if ok and matches(v) then return true end
		end
	end
	return false
end

local myPlotCache
local function myPlot()
	if myPlotCache and myPlotCache.Parent then return myPlotCache end
	local plots = workspace:FindFirstChild("Plots")
	if not plots then return nil end
	for _, p in ipairs(plots:GetChildren()) do
		if ownsInst(p) then
			myPlotCache = p
			return p
		end
	end
	return nil
end

local function plotOf(inst)
	local plots = workspace:FindFirstChild("Plots")
	if not plots then return nil end
	local cur = inst
	while cur and cur.Parent and cur.Parent ~= plots do cur = cur.Parent end
	if cur and cur.Parent == plots then return cur end
	return nil
end

local function homePos()
	local p = myPlot()
	if p then
		local ok, cf = pcall(function() return p:GetPivot() end)
		if ok then return cf.Position + Vector3.new(0, 6, 0) end
	end
	return home
end

local function promptPos(pp)
	local cur = pp.Parent
	while cur and cur ~= workspace do
		if cur:IsA("Attachment") then return cur.WorldPosition end
		if cur:IsA("BasePart") then return cur.Position end
		if cur:IsA("Model") then
			local ok, cf = pcall(function() return cur:GetPivot() end)
			if ok then return cf.Position end
		end
		cur = cur.Parent
	end
	return nil
end

local function collectSteal()
	local out = {}
	local mine = myPlot()
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and hasAny(d.ActionText .. " " .. d.ObjectText .. " " .. d.Name, CONFIG.STEAL_KEYS) then
			local pl = plotOf(d)
			local mineHit = mine and pl == mine
			local onMe = lp.Character and d:IsDescendantOf(lp.Character)
			if not mineHit and not onMe then table.insert(out, d) end
		end
	end
	return out
end

local function othersNear(pos, r)
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl ~= lp and pl.Character then
			local rp = pl.Character:FindFirstChild("HumanoidRootPart")
			if rp and (rp.Position - pos).Magnitude <= r then return true end
		end
	end
	return false
end

local function firePrompt(pp)
	pcall(function() pp.HoldDuration = 0 end)
	if fireproximityprompt then pcall(fireproximityprompt, pp) end
end

local function holdPrompt(pp)
	pcall(function()
		pp:InputHoldBegin()
		task.wait(math.max(pp.HoldDuration, 0.05) + 0.1)
		pp:InputHoldEnd()
	end)
	if fireproximityprompt then pcall(fireproximityprompt, pp) end
end

local function walkTo(pos, timeout)
	local char = lp.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = hrp()
	if not (hum and root) then return false end
	local t0 = os.clock()

	local function reach(p)
		hum:MoveTo(p)
		while os.clock() - t0 < timeout and State.autoSteal and State.alive do
			task.wait(0.1)
			root = hrp()
			if not root then return false end
			if (root.Position - p).Magnitude < 4 then return true end
		end
		return false
	end

	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
	local ok = pcall(function() path:ComputeAsync(root.Position, pos) end)
	if ok and path.Status == Enum.PathStatus.Success then
		for _, wp in ipairs(path:GetWaypoints()) do
			if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
			if not reach(wp.Position) and os.clock() - t0 >= timeout then break end
		end
	else
		reach(pos)
	end
	root = hrp()
	return root ~= nil and (root.Position - pos).Magnitude < 8
end

-- cari penjaga & safe zone (berdasarkan nama object), cache 4 detik
local POINTS_FILE = "kennhub_points.txt"

local function parseVec(s)
	local x, y, z = string.match(s or "", "^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$")
	if x then return Vector3.new(tonumber(x), tonumber(y), tonumber(z)) end
	return nil
end

local function savePoints()
	pcall(function()
		local function f(v) return v and string.format("%.2f,%.2f,%.2f", v.X, v.Y, v.Z) or "-" end
		writefile(POINTS_FILE, f(manualDrop) .. "|" .. f(manualSafe))
	end)
end

pcall(function()
	if isfile and isfile(POINTS_FILE) then
		local a, b = string.match(readfile(POINTS_FILE), "^(.-)|(.-)$")
		manualDrop, manualSafe = parseVec(a), parseVec(b)
	end
end)

-- part yang membawa tulisan "Area Aman" (SurfaceGui / BillboardGui)
local function labelPart(d)
	local g = d:FindFirstAncestorWhichIsA("SurfaceGui") or d:FindFirstAncestorWhichIsA("BillboardGui")
	if not g then return nil end
	local a = g.Adornee
	if a and a:IsA("BasePart") then return a end
	if g.Parent and g.Parent:IsA("BasePart") then return g.Parent end
	return nil
end

local special, lastSpecial = { guards = {}, safes = {}, drops = {} }, -100

local function scanSpecial()
	if os.clock() - lastSpecial < 4 then return special end
	lastSpecial = os.clock()
	local g, s, dr = {}, {}, {}
	local char = lp.Character
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			if hasAny(d.ActionText .. " " .. d.ObjectText .. " " .. d.Name, CONFIG.DROP_KEYS) then
				dr[#dr + 1] = d
			end
		elseif d:IsA("TextLabel") then
			if hasAny(d.Text, CONFIG.AREA_TEXTS) then
				local lp2 = labelPart(d)
				if lp2 then s[#s + 1] = lp2 end
			end
		elseif (d:IsA("Model") or d:IsA("BasePart")) and not (char and d:IsDescendantOf(char)) then
			if hasAny(d.Name, CONFIG.GUARD_KEYS) then
				g[#g + 1] = d
			elseif hasAny(d.Name, CONFIG.SAFEZONE_KEYS) then
				s[#s + 1] = d
			end
		end
	end
	special = { guards = g, safes = s, drops = dr }
	return special
end

local function instPos(inst)
	if inst:IsA("BasePart") then return inst.Position end
	if inst:IsA("Model") then
		local ok, cf = pcall(function() return inst:GetPivot() end)
		if ok then return cf.Position end
	end
	return nil
end

local function touchInst(inst)
	if not firetouchinterest then return end
	local r = hrp()
	if not r then return end
	local parts = {}
	if inst:IsA("BasePart") then
		parts[1] = inst
	else
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				parts[#parts + 1] = d
				if #parts >= 6 then break end
			end
		end
	end
	for _, part in ipairs(parts) do
		pcall(firetouchinterest, r, part, 0)
		pcall(firetouchinterest, r, part, 1)
	end
end

-- penjaga terdekat; utamakan yang satu plot dengan prompt yang diambil
local function pickGuard(list, pp, fromPos)
	local pl = plotOf(pp)
	local best, bestD
	for _, g in ipairs(list) do
		local gp = g.Parent and instPos(g)
		if gp then
			local d = (gp - fromPos).Magnitude
			if pl and plotOf(g) == pl then d = d - 10000 end
			if (d < 0 or d <= CONFIG.GUARD_RANGE) and (not bestD or d < bestD) then best, bestD = g, d end
		end
	end
	return best
end

-- safe zone: utamakan yang ada di plot sendiri, lalu yang terdekat ke base
local function pickSafeZone(list, h)
	local mine = myPlot()
	local best, bestD
	for _, z in ipairs(list) do
		local zp = z.Parent and instPos(z)
		if zp then
			local d = h and (zp - h).Magnitude or 0
			if mine and plotOf(z) == mine then d = d - 10000 end
			if not bestD or d < bestD then best, bestD = z, d end
		end
	end
	return best
end

local deaths, lastStep = {}, "-"

local function isAlive()
	local c = lp.Character
	local hm = c and c:FindFirstChildOfClass("Humanoid")
	return hm ~= nil and hm.Health > 0 and hrp() ~= nil
end

-- dipanggil kalau karakter mati/respawn pas steal: tunggu respawn, berhenti kalau kebanyakan
local function noteDeath()
	local now = os.clock()
	table.insert(deaths, now)
	for k = #deaths, 1, -1 do
		if now - deaths[k] > CONFIG.DEATH_WINDOW then table.remove(deaths, k) end
	end
	local t = os.clock()
	while State.alive and os.clock() - t < 15 and not isAlive() do task.wait(0.3) end
	task.wait(CONFIG.RESPAWN_SETTLE)
	if #deaths >= CONFIG.MAX_DEATHS then
		State.autoSteal = false
		stealStopMsg = "Steal berhenti: mati " .. #deaths .. "x (terakhir pas: " .. lastStep .. ")"
		stealText = stealStopMsg
		if uiSync then pcall(uiSync) end
	else
		stealText = "Steal: mati pas " .. lastStep .. ", lanjut pelan"
	end
end

-- drop hewan: pakai panggilan drop yang dipelajari (drop manual 1x), lalu prompt drop
local function dropAnimal()
	if dropLearn and dropLearn.remote and dropLearn.remote.Parent then
		local a = dropLearn.args
		local ok = pcall(function() dropLearn.remote:FireServer(table.unpack(a, 1, a.n)) end)
		if ok then return true end
	end
	local sp = scanSpecial()
	local r = hrp()
	local char = lp.Character
	local pick, pd
	for _, pp in ipairs(sp.drops) do
		if pp.Parent and pp.Enabled then
			local own = char and pp:IsDescendantOf(char)
			local pos = promptPos(pp)
			local d = own and -1 or ((pos and r) and (pos - r.Position).Magnitude or math.huge)
			if (own or d <= CONFIG.PICK_RANGE) and (not pd or d < pd) then pick, pd = pp, d end
		end
	end
	if pick then
		firePrompt(pick)
		return true
	end
	return false
end

-- cari prompt ambil/steal terdekat dari posisi sekarang (hewan yang baru di-drop)
local function freshPickup(rootPos)
	local best, bestD
	local char = lp.Character
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Enabled and not (char and d:IsDescendantOf(char)) then
			local txt = d.ActionText .. " " .. d.ObjectText .. " " .. d.Name
			if hasAny(txt, CONFIG.STEAL_KEYS) or hasAny(txt, CONFIG.PICKUP_KEYS) then
				local pos = promptPos(d)
				if pos then
					local dist = (pos - rootPos).Magnitude
					if dist <= CONFIG.PICK_RANGE and (not bestD or dist < bestD) then best, bestD = d, dist end
				end
			end
		end
	end
	return best
end

-- hitung titik drop (luar garis) & titik aman (dalam Area Aman) dari object zona
local function zoneGeometry(z, h)
	local part = z:IsA("BasePart") and z or z:FindFirstChildWhichIsA("BasePart", true)
	if not part then return nil end
	local P = part.Position
	local towards = h and Vector3.new(h.X - P.X, 0, h.Z - P.Z) or Vector3.new(0, 0, 1)
	if towards.Magnitude < 0.01 then towards = Vector3.new(0, 0, 1) end
	towards = towards.Unit
	local cf, sz = part.CFrame, part.Size
	local n
	if math.abs(sz.X - sz.Z) < 0.25 * math.max(sz.X, sz.Z) then
		n = towards
	else
		n = (sz.X >= sz.Z) and cf.LookVector or cf.RightVector
		n = Vector3.new(n.X, 0, n.Z)
		n = n.Magnitude > 0.01 and n.Unit or towards
		if n:Dot(towards) < 0 then n = -n end
	end
	local half = (math.abs(n:Dot(cf.RightVector)) * sz.X + math.abs(n:Dot(cf.LookVector)) * sz.Z) / 2
	local base = Vector3.new(P.X, P.Y + 3, P.Z)
	local safe
	if half > 25 then
		safe = base
	else
		safe = base + n * (half + CONFIG.SAFE_IN)
	end
	return { part = part, safe = safe, drop = base - n * (half + CONFIG.DROP_OUT), normal = n }
end

-- titik manual (tombol Set Titik) menang dari hitungan otomatis
local function resolvePoints(zone, h)
	local geo = zone and zoneGeometry(zone, h)
	return manualDrop or (geo and geo.drop), manualSafe or (geo and geo.safe), geo
end

local function walkIn(pos, timeout)
	local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
	if not (hum and hrp()) then return false end
	hum:MoveTo(pos)
	local t = os.clock()
	while os.clock() - t < timeout and State.alive do
		task.wait(0.1)
		local r = hrp()
		if not r or not isAlive() then return false end
		if Vector3.new(r.Position.X - pos.X, 0, r.Position.Z - pos.Z).Magnitude < 4 then return true end
	end
	return false
end

-- setelah hewan diambil: tabrak penjaga -> ke titik drop (luar) -> drop -> ambil lagi -> masuk Area Aman
local function carryToSafe(pp, fromPos, h, back, hold)
	local sp = scanSpecial()
	local zone = pickSafeZone(sp.safes, h)
	local dropP, safeP = resolvePoints(zone, h)

	if State.bumpGuard then
		local guard = pickGuard(sp.guards, pp, fromPos)
		if guard then
			local r = hrp()
			local gp = instPos(guard)
			if r and gp then
				lastStep = "nabrak penjaga"
				stealText = "Steal: nabrak penjaga"
				r.CFrame = CFrame.new(gp + Vector3.new(0, 2, 0))
				touchInst(guard)
				task.wait(jitter(CONFIG.BUMP_TIME))
			end
		end
		if not isAlive() then return end
	end

	if State.dropFirst then
		local r = hrp()
		if dropP and r then
			lastStep = "ke titik drop"
			stealText = "Steal: ke titik drop (luar Area Aman)"
			r.CFrame = CFrame.new(dropP)
			task.wait(jitter(CONFIG.DROP_WAIT))
			if not isAlive() then return end
		end
		lastStep = "drop"
		stealText = "Steal: drop dulu"
		if dropAnimal() then
			task.wait(jitter(CONFIG.DROP_WAIT))
			if not isAlive() then return end
			lastStep = "tunggu ambil lagi"
			local untilT = os.clock() + CONFIG.REPICK_DELAY
			while State.alive and os.clock() < untilT do
				stealText = string.format("Steal: ambil lagi dalam %.1fs", untilT - os.clock())
				task.wait(0.25)
				if not isAlive() then return end
			end
			if not State.alive then return end
			lastStep = "ambil lagi"
			stealText = "Steal: ambil lagi"
			r = hrp()
			local p2 = (r and freshPickup(r.Position)) or (pp.Parent and pp.Enabled and pp) or nil
			if p2 then
				if hold then holdPrompt(p2) else firePrompt(p2) end
				task.wait(jitter(CONFIG.CARRY_WAIT))
			else
				stealText = "Steal: prompt ambil lagi gak ketemu"
			end
		else
			stealText = "Steal: drop gak ketemu (drop manual 1x biar kebaca)"
		end
		if not isAlive() then return end
	end

	local r = hrp()
	if not r then return end
	lastStep = "bawa ke safe zone"
	stealText = "Steal: bawa ke safe zone"
	if safeP then
		local reached = CONFIG.WALK_IN and walkIn(safeP, CONFIG.WALK_IN_TIME)
		if not isAlive() then return end
		if not reached then
			r = hrp()
			if r then r.CFrame = CFrame.new(safeP) end
		end
		if zone then touchInst(zone) end
		task.wait(jitter(CONFIG.SAFE_STAY))
		stealText = "Steal: berhasil (safe zone)"
	else
		r.CFrame = h and CFrame.new(h) or back
		task.wait(jitter(CONFIG.SAFE_STAY))
		stealText = "Steal: selesai (safe zone gak ketemu, pulang ke base)"
	end
end

local stealCache, lastStealScan, stealCool = {}, 0, {}

task.spawn(function()
	local was = false
	while State.alive do
		if State.autoSteal then
			if not was then
				was = true
				stealStopMsg = ""
				deaths = {}
				if not myPlot() then
					local r = hrp()
					if r then home = r.Position end
				end
			end

			local root = hrp()
			if root and os.clock() - lastStealScan > 1.5 then
				local ok, res = pcall(collectSteal)
				if ok then stealCache = res end
				lastStealScan = os.clock()
			end

			if root then
				local best, bestD, bestPos
				for _, pp in ipairs(stealCache) do
					if pp.Parent and pp.Enabled and not (stealCool[pp] and stealCool[pp] > os.clock()) then
						local pos = promptPos(pp)
						if pos and (State.stealMode ~= "Safe" or not othersNear(pos, CONFIG.SAFE_RADIUS)) then
							local d = (pos - root.Position).Magnitude
							if not bestD or d < bestD then best, bestD, bestPos = pp, d, pos end
						end
					end
				end

				if best then
					stealing = true
					stealCool[best] = os.clock() + CONFIG.STEAL_COOLDOWN
					local h = homePos()
					local mode = State.stealMode
					stealText = "Steal (" .. mode .. ")"
					local charAtStart = lp.Character
					lastStep = "TP ke hewan"

					if mode == "Instant" then
						local back = root.CFrame
						root.CFrame = CFrame.new(bestPos + Vector3.new(0, 3, 0))
						task.wait(0.08)
						firePrompt(best)
						task.wait(jitter(CONFIG.CARRY_WAIT))
						carryToSafe(best, bestPos, h, back, false)

					elseif mode == "Safe" then
						local back = root.CFrame
						root.CFrame = CFrame.new(bestPos + Vector3.new(0, 3, 0))
						task.wait(0.35)
						if othersNear(bestPos, CONFIG.SAFE_RADIUS) then
							stealText = "Safe: ada orang, batal"
							root = hrp()
							if root then root.CFrame = h and CFrame.new(h) or back end
						else
							holdPrompt(best)
							task.wait(jitter(CONFIG.CARRY_WAIT))
							carryToSafe(best, bestPos, h, back, true)
						end

					elseif mode == "Walk" then
						if walkTo(bestPos, CONFIG.WALK_TIMEOUT) then
							holdPrompt(best)
							task.wait(0.3)
						else
							stealText = "Walk: gagal sampai"
						end
						if h then walkTo(h, CONFIG.WALK_TIMEOUT) end

					else -- Anywhere: tanpa pindah karakter sama sekali
						firePrompt(best)
						task.wait(jitter(0.25))
					end

					if lp.Character ~= charAtStart or not isAlive() then
						noteDeath()
					else
						stealCount = stealCount + 1
					end
					task.wait(jitter(CONFIG.STEAL_AFTER))
					stealing = false
				else
					stealText = "Steal: nunggu target (" .. #stealCache .. ")"
				end
			end
		else
			was = false
			stealing = false
		end
		task.wait(0.25)
	end
end)

----------------------------------------------------------------
-- Auto Treadmill
----------------------------------------------------------------
local tmEntries, lastTMScan = {}, 0
local tmDir = nil
local tmText = "Treadmill: mati"

local function isTreadmillName(inst)
	local nm = norm(inst.Name)
	return string.find(nm, "treadmill", 1, true) ~= nil and string.find(nm, "vfx", 1, true) == nil
end

local function insideFound(inst, found)
	local cur = inst.Parent
	while cur and cur ~= workspace do
		if found[cur] then return true end
		cur = cur.Parent
	end
	return false
end

local function findTreadmills()
	local out, found = {}, {}
	local function add(inst)
		if found[inst] then return end
		found[inst] = true
		local pp = inst:FindFirstChildWhichIsA("ProximityPrompt", true)
		table.insert(out, { inst = inst, prompt = pp })
	end
	for _, d in ipairs(workspace:GetDescendants()) do
		if not (lp.Character and d:IsDescendantOf(lp.Character)) then
			if (d:IsA("Model") or d:IsA("BasePart")) and isTreadmillName(d) and not insideFound(d, found) then
				add(d)
			elseif d:IsA("Folder") and isTreadmillName(d) then
				for _, c in ipairs(d:GetChildren()) do
					if (c:IsA("Model") or c:IsA("BasePart")) and not insideFound(c, found) then add(c) end
				end
			end
		end
	end
	return out
end

local function treadmillTop(inst)
	local ok, pos = pcall(function()
		if inst:IsA("Model") then
			local cf, size = inst:GetBoundingBox()
			return cf.Position + Vector3.new(0, size.Y / 2 + 3, 0)
		end
		return inst.Position + Vector3.new(0, inst.Size.Y / 2 + 3, 0)
	end)
	return ok and pos or nil
end

local function treadmillLook(inst)
	local ok, look = pcall(function()
		if inst:IsA("Model") then return inst:GetPivot().LookVector end
		return inst.CFrame.LookVector
	end)
	if not ok then return nil end
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.1 then return nil end
	return flat.Unit
end

local function pickTreadmill(root)
	local mine = myPlot()
	local best, bestD, bestMine
	for _, e in ipairs(tmEntries) do
		if e.inst.Parent then
			local top = treadmillTop(e.inst)
			if top then
				local d = (top - root.Position).Magnitude
				local isMine = (mine ~= nil) and e.inst:IsDescendantOf(mine) or false
				local better = false
				if not best then
					better = true
				elseif isMine and not bestMine then
					better = true
				elseif isMine == bestMine and d < bestD then
					better = true
				end
				if better then best, bestD, bestMine = e, d, isMine end
			end
		end
	end
	return best
end

task.spawn(function()
	local lastPrompt = 0
	local wasOn = false
	while State.alive do
		if State.autoTreadmill then
			while stealing and State.alive do task.wait(0.1) end
			local root = hrp()
			local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
			if root and hum then
				if not wasOn or os.clock() - lastTMScan > CONFIG.TREADMILL_RESCAN then
					local ok, res = pcall(findTreadmills)
					if ok then tmEntries = res end
					lastTMScan = os.clock()
				end
				wasOn = true

				local e = pickTreadmill(root)
				if e then
					local top = treadmillTop(e.inst)
					if top then
						if (root.Position - top).Magnitude > CONFIG.TREADMILL_STAY then
							root.CFrame = CFrame.new(top)
							task.wait(0.25)
							lastPrompt = 0
						end
						if e.prompt and e.prompt.Parent and os.clock() - lastPrompt > CONFIG.TREADMILL_PROMPT_EVERY then
							lastPrompt = os.clock()
							holdPrompt(e.prompt)
						end
						tmDir = treadmillLook(e.inst) or Vector3.new(0, 0, -1)
						tmText = "Treadmill: " .. e.inst.Name
					end
				else
					tmDir = nil
					tmText = "Treadmill: tidak ketemu (" .. #tmEntries .. ")"
				end
			end
		else
			wasOn = false
			tmDir = nil
			tmText = "Treadmill: mati"
		end
		task.wait(0.2)
	end
end)

local tmConn = RunService.Heartbeat:Connect(function()
	if State.alive and State.autoTreadmill and tmDir and not stealing then
		local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
		if hum then pcall(function() hum:Move(tmDir, false) end) end
	end
end)

----------------------------------------------------------------
-- Event: Farm Diamond
----------------------------------------------------------------
local diamondText = "Diamond: mati"
local diamondCount = 0

local function inAnyCharacter(inst)
	local cur = inst
	while cur and cur ~= workspace do
		if cur:IsA("Model") and Players:GetPlayerFromCharacter(cur) then return true end
		cur = cur.Parent
	end
	return false
end

-- cari kandidat diamond di workspace: prompt, click detector, atau part/model yang bisa disentuh
local function collectDiamonds()
	local out, covered = {}, {}
	local function skipName(d)
		local ok, full = pcall(function() return d:GetFullName() end)
		return ok and hasAny(full, CONFIG.DIAMOND_SKIP)
	end
	local all = workspace:GetDescendants()
	for _, d in ipairs(all) do
		if d:IsA("ProximityPrompt") or d:IsA("ClickDetector") then
			local par = d.Parent
			local txt = d.Name .. " " .. (par and par.Name or "")
			if d:IsA("ProximityPrompt") then txt = txt .. " " .. d.ActionText .. " " .. d.ObjectText end
			if hasAny(txt, CONFIG.DIAMOND_KEYS) and not inAnyCharacter(d) and not skipName(d) and not (d:IsA("ProximityPrompt") and not d.Enabled) then
				local pos = d:IsA("ProximityPrompt") and promptPos(d) or (par and instPos(par))
				if pos then
					table.insert(out, { kind = d:IsA("ProximityPrompt") and "prompt" or "click", inst = d, pos = pos })
					if par then covered[par] = true end
				end
			end
		end
	end
	for _, d in ipairs(all) do
		if (d:IsA("BasePart") or d:IsA("Model")) and hasAny(d.Name, CONFIG.DIAMOND_KEYS) and not covered[d] then
			local par = d.Parent
			local skip = inAnyCharacter(d) or d:IsA("Terrain") or skipName(d)
			if not skip and d:IsA("BasePart") and par and par:IsA("Model") and hasAny(par.Name, CONFIG.DIAMOND_KEYS) then skip = true end
			if not skip and d:FindFirstChildWhichIsA("ProximityPrompt", true) then skip = true end
			if not skip then
				local pos = instPos(d)
				if pos then table.insert(out, { kind = "touch", inst = d, pos = pos }) end
			end
		end
	end
	return out
end

-- magnet: ambil diamond di sekitar karakter tanpa pindah posisi, jalan bareng break
local function collectDiamond(t, r)
	if t.kind == "prompt" then
		firePrompt(t.inst)
	elseif t.kind == "click" then
		if fireclickdetector then pcall(fireclickdetector, t.inst) end
	else
		if CONFIG.DIAMOND_PULL then
			pcall(function()
				if t.inst:IsA("BasePart") then
					t.inst.CFrame = CFrame.new(r.Position)
				elseif t.inst:IsA("Model") then
					t.inst:PivotTo(CFrame.new(r.Position))
				end
			end)
		end
		touchInst(t.inst)
	end
end

task.spawn(function()
	local list, lastScan = {}, 0
	local cool = {}
	while State.alive do
		if State.farmDiamond then
			local r = hrp()
			if r and isAlive() then
				if os.clock() - lastScan > CONFIG.DIAMOND_RESCAN then
					local ok, res = pcall(collectDiamonds)
					if ok then list = res end
					lastScan = os.clock()
				end
				local n = 0
				for _, t in ipairs(list) do
					if t.inst.Parent and (cool[t.inst] or 0) < os.clock() then
						local pos = (t.kind == "touch" and instPos(t.inst)) or t.pos
						if pos and (pos - r.Position).Magnitude <= CONFIG.DIAMOND_RANGE then
							collectDiamond(t, r)
							cool[t.inst] = os.clock() + CONFIG.DIAMOND_RETRY
							n = n + 1
							diamondCount = diamondCount + 1
						end
					end
				end
				diamondText = "Diamond: magnet aktif (" .. diamondCount .. ")"
			end
		else
			diamondText = "Diamond: mati"
		end
		task.wait(CONFIG.DIAMOND_STEP)
	end
end)

local function diamondReport()
	local L = { "== DIAMOND (kandidat) ==" }
	local ok, list = pcall(collectDiamonds)
	if ok and #list > 0 then
		for i, t in ipairs(list) do
			if i > 30 then break end
			table.insert(L, t.kind .. " | " .. t.inst.ClassName .. " | " .. t.inst:GetFullName() .. " | pos=" .. tostring(t.pos))
		end
	else
		table.insert(L, "(tidak ada object/prompt bernama diamond/berlian/gem/crystal)")
	end
	return table.concat(L, "\n")
end

----------------------------------------------------------------
-- Performance / FPS Boost
----------------------------------------------------------------
local fpsOrig = { effects = {}, particles = {} }

local function setFps(on)
	if on then
		pcall(function()
			UserSettings():GetService("UserGameSettings").SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
		end)
		pcall(function() Lighting.GlobalShadows = false end)
		pcall(function() workspace.Terrain.Decoration = false end)
		for _, inst in ipairs(Lighting:GetDescendants()) do
			if inst:IsA("BloomEffect") or inst:IsA("SunRaysEffect") or inst:IsA("DepthOfFieldEffect")
				or inst:IsA("ColorCorrectionEffect") or inst:IsA("BlurEffect") then
				if fpsOrig.effects[inst] == nil then fpsOrig.effects[inst] = inst.Enabled end
				inst.Enabled = false
			end
		end
		for _, inst in ipairs(workspace:GetDescendants()) do
			if inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam")
				or inst:IsA("Fire") or inst:IsA("Smoke") then
				if fpsOrig.particles[inst] == nil then fpsOrig.particles[inst] = inst.Enabled end
				inst.Enabled = false
			end
		end
	else
		pcall(function()
			UserSettings():GetService("UserGameSettings").SavedQualityLevel = Enum.SavedQualitySetting.Automatic
		end)
		pcall(function() Lighting.GlobalShadows = true end)
		pcall(function() workspace.Terrain.Decoration = true end)
		for inst, v in pairs(fpsOrig.effects) do
			if inst.Parent then pcall(function() inst.Enabled = v end) end
		end
		for inst, v in pairs(fpsOrig.particles) do
			if inst.Parent then pcall(function() inst.Enabled = v end) end
		end
		fpsOrig.effects, fpsOrig.particles = {}, {}
	end
end

workspace.DescendantAdded:Connect(function(d)
	if State.fpsBoost and (d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Fire") or d:IsA("Smoke")) then
		task.defer(function() pcall(function() d.Enabled = false end) end)
	end
end)

----------------------------------------------------------------
-- UI (v2: tab, border gradient, ripple, animasi)
----------------------------------------------------------------
local function buildUI()
	local playerGui = lp:WaitForChild("PlayerGui")
	for _, n in ipairs({ "CnS_UI", "KennHub_UI" }) do
		local o = playerGui:FindFirstChild(n)
		if o then o:Destroy() end
	end

	gui = Instance.new("ScreenGui")
	gui.Name = "KennHub_UI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 999
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local THEME = {
		bg1 = Color3.fromRGB(26, 20, 46), bg2 = Color3.fromRGB(11, 11, 19),
		bar = Color3.fromRGB(22, 20, 36), card = Color3.fromRGB(30, 28, 46),
		cardHover = Color3.fromRGB(40, 37, 62), stroke = Color3.fromRGB(58, 54, 90),
		accent = Color3.fromRGB(124, 92, 255), accent2 = Color3.fromRGB(255, 92, 170),
		on = Color3.fromRGB(70, 210, 130), off = Color3.fromRGB(62, 60, 86),
		text = Color3.fromRGB(240, 240, 250), sub = Color3.fromRGB(150, 150, 180),
		red = Color3.fromRGB(235, 75, 90),
	}
	local W, H = 330, 350
	local BAR_H, TAB_H, FOOTER_H = 44, 34, 58
	local FULL_H = H
	local MIN_W, MIN_H, MAX_W, MAX_H = 270, 250, 520, 460

	local Debris = game:GetService("Debris")
	local QUAD, BACK, QUINT = Enum.EasingStyle.Quad, Enum.EasingStyle.Back, Enum.EasingStyle.Quint

	local function tween(o, t, props, style, dir)
		local tw = TweenService:Create(o, TweenInfo.new(t, style or QUAD, dir or Enum.EasingDirection.Out), props)
		tw:Play()
		return tw
	end

	local function corner(o, r)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, r or 8)
		c.Parent = o
		return c
	end

	local function label(parent, text, size, color, bold)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Text = text
		l.TextSize = size
		l.TextColor3 = color
		l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextTruncate = Enum.TextTruncate.AtEnd
		l.Parent = parent
		return l
	end

	----------------------------------------------------------------
	-- Frame utama: root (shadow + scale) -> main (isi)
	----------------------------------------------------------------
	local LOGO_URL = "https://files.catbox.moe/i8ew6o.png"
	local logoTargets = {}

	local function makeLogo(parent, radius, textSize)
		local k = Instance.new("TextLabel")
		k.Size = UDim2.fromScale(1, 1)
		k.BackgroundTransparency = 1
		k.Text = "K"
		k.Font = Enum.Font.GothamBlack
		k.TextSize = textSize
		k.TextColor3 = Color3.new(1, 1, 1)
		k.Parent = parent
		local img = Instance.new("ImageLabel")
		img.Size = UDim2.fromScale(1, 1)
		img.BackgroundTransparency = 1
		img.ScaleType = Enum.ScaleType.Crop
		img.Visible = false
		img.ZIndex = 2
		img.Parent = parent
		corner(img, radius)
		table.insert(logoTargets, { img = img, k = k })
	end

	local BG_URL = "https://files.catbox.moe/6cl5xr.jpg"

	-- download gambar dari URL -> simpan ke workspace executor -> getcustomasset
	local function fetchImage(url, fname, magic)
		local ok, res = pcall(function()
			local have = false
			if isfile then
				local okf, e = pcall(isfile, fname)
				have = okf and e or false
			end
			if not have then
				local data
				local req = (syn and syn.request) or request or http_request or (http and http.request)
				if req then
					local r = req({ Url = url, Method = "GET" })
					data = r and r.Body
				end
				if not data then data = game:HttpGet(url) end
				if type(data) ~= "string" or data:sub(1, #magic) ~= magic then error("gagal download") end
				writefile(fname, data)
			end
			return getcustomasset(fname)
		end)
		if ok and res then return res end
		return nil
	end

	local function fetchLogo()
		if CONFIG.LOGO_ID ~= "" then return "rbxassetid://" .. CONFIG.LOGO_ID end
		return fetchImage(LOGO_URL, "kennhub_logo.png", "\137PNG")
	end

	local root = Instance.new("Frame")
	root.AnchorPoint = Vector2.new(0, 0)
	root.Size = UDim2.fromOffset(W, FULL_H)
	root.Position = UDim2.fromOffset(16, 80)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = gui

	local popScale = Instance.new("UIScale")
	popScale.Scale = 0.8
	popScale.Parent = root

	local shadow = Instance.new("ImageLabel")
	shadow.BackgroundTransparency = 1
	shadow.Image = "rbxassetid://6014261993"
	shadow.ImageColor3 = Color3.new(0, 0, 0)
	shadow.ImageTransparency = 0.4
	shadow.ScaleType = Enum.ScaleType.Slice
	shadow.SliceCenter = Rect.new(49, 49, 450, 450)
	shadow.Size = UDim2.new(1, 44, 1, 44)
	shadow.Position = UDim2.fromOffset(-22, -18)
	shadow.ZIndex = 0
	shadow.Parent = root

	local main = Instance.new("Frame")
	main.Size = UDim2.fromScale(1, 1)
	main.BackgroundColor3 = Color3.new(1, 1, 1)
	main.BorderSizePixel = 0
	main.ClipsDescendants = true
	main.Parent = root
	corner(main, 14)

	local bgGrad = Instance.new("UIGradient")
	bgGrad.Color = ColorSequence.new(THEME.bg1, THEME.bg2)
	bgGrad.Rotation = 90
	bgGrad.Parent = main

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Transparency = 0.1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = main

	local strokeGrad = Instance.new("UIGradient")
	strokeGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, THEME.accent),
		ColorSequenceKeypoint.new(0.5, THEME.accent2),
		ColorSequenceKeypoint.new(1, THEME.accent),
	})
	strokeGrad.Parent = stroke

	-- gambar latar (diisi setelah download selesai)
	local bgImg = Instance.new("ImageLabel")
	bgImg.Size = UDim2.fromScale(1, 1)
	bgImg.BackgroundTransparency = 1
	bgImg.ScaleType = Enum.ScaleType.Crop
	bgImg.ImageTransparency = 1
	bgImg.ZIndex = 0
	bgImg.Visible = false
	bgImg.Parent = main
	corner(bgImg, 14)

	local bgDim = Instance.new("Frame")
	bgDim.Size = UDim2.fromScale(1, 1)
	bgDim.BackgroundColor3 = THEME.bg2
	bgDim.BackgroundTransparency = 1
	bgDim.BorderSizePixel = 0
	bgDim.ZIndex = 0
	bgDim.Visible = false
	bgDim.Parent = main
	corner(bgDim, 14)

	-- partikel melayang di background
	local particles = {}
	local rng = Random.new(7)
	for i = 1, 10 do
		local s = rng:NextInteger(3, 6)
		local p = Instance.new("Frame")
		p.Size = UDim2.fromOffset(s, s)
		p.BackgroundColor3 = (i % 2 == 0) and THEME.accent or THEME.accent2
		p.BackgroundTransparency = 0.8
		p.BorderSizePixel = 0
		p.ZIndex = 0
		p.Parent = main
		corner(p, 99)
		particles[i] = { f = p, x = rng:NextNumber(0.05, 0.95), speed = rng:NextNumber(0.03, 0.09), phase = rng:NextNumber(0, 1), sway = rng:NextNumber(0.01, 0.04) }
	end

	----------------------------------------------------------------
	-- Title bar
	----------------------------------------------------------------
	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, 0, 0, BAR_H)
	bar.BackgroundColor3 = THEME.bar
	bar.BackgroundTransparency = 0.15
	bar.BorderSizePixel = 0
	bar.ClipsDescendants = true
	bar.Parent = main
	corner(bar, 14)

	local barFill = Instance.new("Frame")
	barFill.Size = UDim2.new(1, 0, 0, 16)
	barFill.Position = UDim2.new(0, 0, 1, -16)
	barFill.BackgroundColor3 = THEME.bar
	barFill.BackgroundTransparency = 0.15
	barFill.BorderSizePixel = 0
	barFill.Parent = bar

	local shine = Instance.new("Frame")
	shine.Size = UDim2.new(0, 34, 1.8, 0)
	shine.Rotation = 20
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.93
	shine.BorderSizePixel = 0
	shine.Parent = bar

	local barLine = Instance.new("Frame")
	barLine.Size = UDim2.new(1, 0, 0, 2)
	barLine.Position = UDim2.new(0, 0, 1, -2)
	barLine.BackgroundColor3 = Color3.new(1, 1, 1)
	barLine.BorderSizePixel = 0
	barLine.Parent = bar
	local lineGrad = Instance.new("UIGradient")
	lineGrad.Color = ColorSequence.new(THEME.accent, THEME.accent2)
	lineGrad.Parent = barLine

	local logo = Instance.new("Frame")
	logo.Size = UDim2.fromOffset(30, 30)
	logo.Position = UDim2.fromOffset(10, 7)
	logo.BackgroundColor3 = Color3.new(1, 1, 1)
	logo.BorderSizePixel = 0
	logo.Parent = bar
	corner(logo, 9)

	local logoGrad = Instance.new("UIGradient")
	logoGrad.Color = ColorSequence.new(THEME.accent, THEME.accent2)
	logoGrad.Rotation = 45
	logoGrad.Parent = logo
	makeLogo(logo, 9, 19)

	local title = label(bar, "Kenn Hub", 17, THEME.text, true)
	title.Size = UDim2.new(1, -130, 1, 0)
	title.Position = UDim2.fromOffset(48, 0)

	local function barButton(text, xOff, color)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(28, 28)
		b.Position = UDim2.new(1, xOff, 0.5, -14)
		b.BackgroundColor3 = color
		b.BackgroundTransparency = 0.25
		b.Text = text
		b.TextColor3 = THEME.text
		b.Font = Enum.Font.GothamBold
		b.TextSize = 16
		b.AutoButtonColor = false
		b.Parent = bar
		corner(b, 8)
		b.MouseEnter:Connect(function() tween(b, 0.15, { BackgroundTransparency = 0 }) end)
		b.MouseLeave:Connect(function() tween(b, 0.15, { BackgroundTransparency = 0.25 }) end)
		return b
	end

	local minBtn = barButton("-", -70, THEME.off)
	local closeBtn = barButton("X", -38, THEME.red)

	----------------------------------------------------------------
	-- Body: tab bar + pages + footer
	----------------------------------------------------------------
	local body = Instance.new("Frame")
	body.Size = UDim2.new(1, 0, 1, -BAR_H)
	body.Position = UDim2.fromOffset(0, BAR_H)
	body.BackgroundTransparency = 1
	body.Parent = main

	local tabBar = Instance.new("Frame")
	tabBar.Size = UDim2.new(1, 0, 0, TAB_H)
	tabBar.BackgroundTransparency = 1
	tabBar.Parent = body

	local pageHolder = Instance.new("Frame")
	pageHolder.Size = UDim2.new(1, 0, 1, -(TAB_H + FOOTER_H))
	pageHolder.Position = UDim2.fromOffset(0, TAB_H)
	pageHolder.BackgroundTransparency = 1
	pageHolder.ClipsDescendants = true
	pageHolder.Parent = body

	local footer = Instance.new("Frame")
	footer.Size = UDim2.new(1, 0, 0, FOOTER_H)
	footer.Position = UDim2.new(0, 0, 1, -FOOTER_H)
	footer.BackgroundColor3 = THEME.bar
	footer.BackgroundTransparency = 0.15
	footer.BorderSizePixel = 0
	footer.Parent = body
	corner(footer, 14)

	local footFill = Instance.new("Frame")
	footFill.Size = UDim2.new(1, 0, 0, 16)
	footFill.BackgroundColor3 = THEME.bar
	footFill.BackgroundTransparency = 0.15
	footFill.BorderSizePixel = 0
	footFill.Parent = footer

	local footLine = Instance.new("Frame")
	footLine.Size = UDim2.new(1, 0, 0, 1)
	footLine.BackgroundColor3 = THEME.stroke
	footLine.BorderSizePixel = 0
	footLine.Parent = footer

	local TABS = { "Farm", "Steal", "Event", "Misc" }
	local tabBtns, pages = {}, {}

	local indicator = Instance.new("Frame")
	indicator.Size = UDim2.new(1 / #TABS, -20, 0, 3)
	indicator.Position = UDim2.new(0, 10, 1, -3)
	indicator.BackgroundColor3 = Color3.new(1, 1, 1)
	indicator.BorderSizePixel = 0
	indicator.ZIndex = 2
	indicator.Parent = tabBar
	corner(indicator, 2)
	local indGrad = Instance.new("UIGradient")
	indGrad.Color = ColorSequence.new(THEME.accent, THEME.accent2)
	indGrad.Parent = indicator

	local function newPage()
		local sf = Instance.new("ScrollingFrame")
		sf.Size = UDim2.fromScale(1, 1)
		sf.BackgroundTransparency = 1
		sf.BorderSizePixel = 0
		sf.ScrollBarThickness = 3
		sf.ScrollBarImageColor3 = THEME.accent
		sf.CanvasSize = UDim2.new()
		sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
		sf.ScrollingDirection = Enum.ScrollingDirection.Y
		sf.Visible = false
		sf.Parent = pageHolder
		local lay = Instance.new("UIListLayout")
		lay.Padding = UDim.new(0, 6)
		lay.SortOrder = Enum.SortOrder.LayoutOrder
		lay.Parent = sf
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 10)
		pad.PaddingRight = UDim.new(0, 12)
		pad.PaddingTop = UDim.new(0, 8)
		pad.PaddingBottom = UDim.new(0, 8)
		pad.Parent = sf
		return sf
	end

	local curTab
	local function selectTab(i, instant)
		if curTab == i then return end
		local dir = (curTab and i > curTab) and 1 or -1
		curTab = i
		for j, p in ipairs(pages) do
			if j == i then
				p.Visible = true
				if not instant then
					p.Position = UDim2.fromOffset(dir * 36, 0)
					tween(p, 0.28, { Position = UDim2.fromOffset(0, 0) }, QUINT)
				end
			else
				p.Visible = false
			end
			tween(tabBtns[j], 0.2, { TextColor3 = (j == i) and THEME.text or THEME.sub })
		end
		tween(indicator, 0.32, { Position = UDim2.new((i - 1) / #TABS, 10, 1, -3) }, BACK)
	end

	for i, name in ipairs(TABS) do
		pages[i] = newPage()
		local tb = Instance.new("TextButton")
		tb.Size = UDim2.new(1 / #TABS, 0, 1, -3)
		tb.Position = UDim2.new((i - 1) / #TABS, 0, 0, 0)
		tb.BackgroundTransparency = 1
		tb.Text = name
		tb.Font = Enum.Font.GothamBold
		tb.TextSize = 13
		tb.TextColor3 = THEME.sub
		tb.AutoButtonColor = false
		tb.Parent = tabBar
		tabBtns[i] = tb
		tb.Activated:Connect(function() selectTab(i) end)
	end

	----------------------------------------------------------------
	-- Komponen: row, ripple, toggle, cycle, action
	----------------------------------------------------------------
	local function ripple(row)
		local mp = UIS:GetMouseLocation()
		local rx, ry = mp.X - row.AbsolutePosition.X, mp.Y - row.AbsolutePosition.Y
		if rx < 0 or ry < 0 or rx > row.AbsoluteSize.X or ry > row.AbsoluteSize.Y then
			rx, ry = row.AbsoluteSize.X / 2, row.AbsoluteSize.Y / 2
		end
		local c = Instance.new("Frame")
		c.AnchorPoint = Vector2.new(0.5, 0.5)
		c.BackgroundColor3 = Color3.new(1, 1, 1)
		c.BackgroundTransparency = 0.8
		c.BorderSizePixel = 0
		c.Size = UDim2.fromOffset(0, 0)
		c.Position = UDim2.fromOffset(rx, ry)
		c.ZIndex = 5
		c.Parent = row
		corner(c, 999)
		local d = math.max(row.AbsoluteSize.X, row.AbsoluteSize.Y) * 2.2
		tween(c, 0.55, { Size = UDim2.fromOffset(d, d), BackgroundTransparency = 1 })
		Debris:AddItem(c, 0.6)
	end

	local function makeRow(parent)
		local n = (parent:GetAttribute("n") or 0) + 1
		parent:SetAttribute("n", n)

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 44)
		row.BackgroundColor3 = THEME.card
		row.BackgroundTransparency = 0.2
		row.BorderSizePixel = 0
		row.ClipsDescendants = true
		row.LayoutOrder = n
		row.Parent = parent
		corner(row, 10)

		local st = Instance.new("UIStroke")
		st.Color = THEME.stroke
		st.Thickness = 1
		st.Transparency = 0.3
		st.Parent = row

		local sc = Instance.new("UIScale")
		sc.Scale = 0.85
		sc.Parent = row
		task.delay(0.12 + 0.06 * n, function()
			if sc.Parent then tween(sc, 0.35, { Scale = 1 }, BACK) end
		end)

		local hit = Instance.new("TextButton")
		hit.Size = UDim2.fromScale(1, 1)
		hit.BackgroundTransparency = 1
		hit.Text = ""
		hit.AutoButtonColor = false
		hit.ZIndex = 10
		hit.Parent = row

		hit.MouseEnter:Connect(function() tween(row, 0.15, { BackgroundColor3 = THEME.cardHover }) end)
		hit.MouseLeave:Connect(function()
			tween(row, 0.15, { BackgroundColor3 = THEME.card })
			tween(sc, 0.12, { Scale = 1 })
		end)
		hit.MouseButton1Down:Connect(function() tween(sc, 0.08, { Scale = 0.97 }) end)
		hit.MouseButton1Up:Connect(function() tween(sc, 0.2, { Scale = 1 }, BACK) end)
		hit.Activated:Connect(function() ripple(row) end)

		return row, hit, st
	end

	local renderers = {}

	local function toggleRow(page, text, key, desc)
		local row, hit, rowStroke = makeRow(page)

		local mark = Instance.new("Frame")
		mark.AnchorPoint = Vector2.new(0, 0.5)
		mark.Position = UDim2.new(0, 0, 0.5, 0)
		mark.Size = UDim2.fromOffset(3, 0)
		mark.BackgroundColor3 = THEME.on
		mark.BorderSizePixel = 0
		mark.Parent = row
		corner(mark, 2)

		local l = label(row, text, 14, THEME.text, true)
		if desc then
			l.Size = UDim2.new(1, -80, 0, 18)
			l.Position = UDim2.fromOffset(14, 6)
			local d = label(row, desc, 11, THEME.sub, false)
			d.Size = UDim2.new(1, -80, 0, 14)
			d.Position = UDim2.fromOffset(14, 24)
		else
			l.Size = UDim2.new(1, -80, 1, 0)
			l.Position = UDim2.fromOffset(14, 0)
		end

		local sw = Instance.new("Frame")
		sw.Size = UDim2.fromOffset(44, 22)
		sw.Position = UDim2.new(1, -56, 0.5, -11)
		sw.BackgroundColor3 = THEME.off
		sw.BorderSizePixel = 0
		sw.Parent = row
		corner(sw, 11)

		local glow = Instance.new("UIStroke")
		glow.Color = THEME.on
		glow.Thickness = 2
		glow.Transparency = 1
		glow.Parent = sw

		local knob = Instance.new("Frame")
		knob.Size = UDim2.fromOffset(18, 18)
		knob.Position = UDim2.fromOffset(2, 2)
		knob.BackgroundColor3 = Color3.new(1, 1, 1)
		knob.BorderSizePixel = 0
		knob.Parent = sw
		corner(knob, 9)

		local function render()
			local on = State[key]
			tween(sw, 0.2, { BackgroundColor3 = on and THEME.on or THEME.off })
			tween(knob, 0.28, { Position = on and UDim2.fromOffset(24, 2) or UDim2.fromOffset(2, 2) }, BACK)
			tween(glow, 0.25, { Transparency = on and 0.5 or 1 })
			tween(mark, 0.28, { Size = UDim2.fromOffset(3, on and 24 or 0) }, BACK)
			tween(rowStroke, 0.25, { Color = on and THEME.on or THEME.stroke, Transparency = on and 0.5 or 0.3 })
			tween(l, 0.2, { TextColor3 = on and THEME.text or THEME.sub })
		end
		renderers[key] = render

		hit.Activated:Connect(function()
			State[key] = not State[key]
			if State[key] then
				if key == "autoTreadmill" and State.enabled and not State.breakAnywhere then
					State.enabled = false
					renderers.enabled()
				elseif key == "enabled" and State.autoTreadmill and not State.breakAnywhere then
					State.autoTreadmill = false
					renderers.autoTreadmill()
				end
			end
			if key == "breakAnywhere" or key == "enabled" then
				visited = {}
				lastAnywhereStream = 0
			end
			if key == "fpsBoost" then
				pcall(setFps, State.fpsBoost)
			end
			render()
		end)
		render()
	end

	local function popValue(v)
		v.TextTransparency = 1
		v.Position = v.Position + UDim2.fromOffset(0, 6)
		tween(v, 0.25, { TextTransparency = 0, Position = v.Position - UDim2.fromOffset(0, 6) }, BACK)
	end

	local function cycleRow(page, name)
		local row, hit = makeRow(page)
		local l = label(row, name, 14, THEME.text, false)
		l.Size = UDim2.new(0.4, 0, 1, 0)
		l.Position = UDim2.fromOffset(14, 0)

		local v = label(row, "", 13, THEME.accent, true)
		v.Size = UDim2.new(0.6, -40, 1, 0)
		v.Position = UDim2.new(0.4, 0, 0, 0)
		v.TextXAlignment = Enum.TextXAlignment.Right

		local a = label(row, ">", 16, THEME.accent2, true)
		a.Size = UDim2.fromOffset(20, 44)
		a.Position = UDim2.new(1, -26, 0, 0)
		a.TextXAlignment = Enum.TextXAlignment.Center

		hit.MouseButton1Down:Connect(function() tween(a, 0.1, { Position = UDim2.new(1, -20, 0, 0) }) end)
		hit.MouseButton1Up:Connect(function() tween(a, 0.25, { Position = UDim2.new(1, -26, 0, 0) }, BACK) end)
		return hit, v
	end

	local function actionRow(page, text)
		local row, hit, st = makeRow(page)
		st.Color = THEME.accent
		st.Transparency = 0.45
		local l = label(row, text, 14, THEME.text, true)
		l.Size = UDim2.new(1, -24, 1, 0)
		l.Position = UDim2.fromOffset(12, 0)
		l.TextXAlignment = Enum.TextXAlignment.Center
		return hit, l
	end

	----------------------------------------------------------------
	-- Isi halaman
	----------------------------------------------------------------
	local pFarm, pSteal, pEvent, pMisc = pages[1], pages[2], pages[3], pages[4]

	toggleRow(pFarm, "Enable", "enabled", "TP ke telur, pukul, pindah")
	toggleRow(pFarm, "Auto Swing", "autoSwing", "Ayun pickaxe otomatis")
	toggleRow(pFarm, "Break Only", "breakOnly")
	toggleRow(pFarm, "Break Anywhere", "breakAnywhere", "Hit telur tanpa pindah")
	local areaHit, areaVal = cycleRow(pFarm, "Filter Area")

	toggleRow(pSteal, "Auto Steal", "autoSteal", "Instant / Safe / Walk / Anywhere")
	toggleRow(pSteal, "Tabrak Penjaga", "bumpGuard", "Nabrak penjaga setelah ambil hewan")
	toggleRow(pSteal, "Drop Dulu", "dropFirst", "Drop, ambil lagi, baru ke safe zone")
	local modeHit, modeVal = cycleRow(pSteal, "Steal Mode")
	toggleRow(pSteal, "Auto Treadmill", "autoTreadmill", "Naik treadmill otomatis")

	local setDropBtn, setDropLbl = actionRow(pSteal, "Set Titik Drop (posisi sekarang)")
	local setSafeBtn, setSafeLbl = actionRow(pSteal, "Set Titik Aman (posisi sekarang)")
	local resetPtBtn, resetPtLbl = actionRow(pSteal, "Reset Titik (pakai otomatis)")

	local function flash(lbl, ok, okText, orig)
		lbl.Text = ok and okText or "Karakter gak ketemu"
		task.delay(1.6, function() lbl.Text = orig end)
	end
	setDropBtn.Activated:Connect(function()
		local r = hrp()
		if r then manualDrop = r.Position; savePoints() end
		flash(setDropLbl, r ~= nil, "Titik drop tersimpan!", "Set Titik Drop (posisi sekarang)")
	end)
	setSafeBtn.Activated:Connect(function()
		local r = hrp()
		if r then manualSafe = r.Position; savePoints() end
		flash(setSafeLbl, r ~= nil, "Titik aman tersimpan!", "Set Titik Aman (posisi sekarang)")
	end)
	resetPtBtn.Activated:Connect(function()
		manualDrop, manualSafe = nil, nil
		savePoints()
		flash(resetPtLbl, true, "Titik direset", "Reset Titik (pakai otomatis)")
	end)

	toggleRow(pEvent, "Farm Diamond", "farmDiamond", "Magnet: sedot diamond pas break")
	local diaBtn, diaLbl = actionRow(pEvent, "Copy Info Diamond")

	toggleRow(pMisc, "Skip Anim", "skipAnim", "Lewati animasi hatch")
	toggleRow(pMisc, "Stealth Mode", "stealth", "Jeda aksi diacak")
	toggleRow(pMisc, "FPS Boost", "fpsBoost", "Turunin quality & efek")
	local dumpBtn, dumpLbl = actionRow(pMisc, "Copy Info (Treadmill + Steal)")

	modeVal.Text = State.stealMode
	areaVal.Text = State.area

	local modeIdx = 1
	modeHit.Activated:Connect(function()
		modeIdx = modeIdx % #STEAL_MODES + 1
		State.stealMode = STEAL_MODES[modeIdx]
		modeVal.Text = State.stealMode
		popValue(modeVal)
	end)

	local areaIdx = 1
	areaHit.Activated:Connect(function()
		areaIdx = areaIdx % #AREAS + 1
		State.area = AREAS[areaIdx]
		areaVal.Text = State.area
		popValue(areaVal)
		visited, ghostCool, blocked, areaRejects = {}, {}, {}, {}
		lastAnywhereStream = 0
		refresh(true, true)
	end)

	uiSync = function()
		for _, rd in pairs(renderers) do rd() end
	end

	selectTab(1, true)

	----------------------------------------------------------------
	-- Footer
	----------------------------------------------------------------
	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(8, 8)
	dot.Position = UDim2.fromOffset(12, 9)
	dot.BackgroundColor3 = THEME.off
	dot.BorderSizePixel = 0
	dot.Parent = footer
	corner(dot, 4)

	local status = label(footer, "", 12, THEME.text, false)
	status.Size = UDim2.new(1, -36, 0, 18)
	status.Position = UDim2.fromOffset(28, 4)

	local hint = label(footer, "", 12, THEME.sub, false)
	hint.Size = UDim2.new(1, -24, 0, 18)
	hint.Position = UDim2.fromOffset(12, 22)

	local reasonLbl = label(footer, "", 11, THEME.sub, false)
	reasonLbl.Size = UDim2.new(1, -48, 0, 16)
	reasonLbl.Position = UDim2.fromOffset(12, 40)

	-- grip buat ubah ukuran (pojok kanan bawah)
	local grip = Instance.new("Frame")
	grip.AnchorPoint = Vector2.new(1, 1)
	grip.Size = UDim2.fromOffset(34, 34)
	grip.Position = UDim2.new(1, 0, 1, 0)
	grip.BackgroundTransparency = 1
	grip.Active = true
	grip.ZIndex = 20
	grip.Parent = main
	for _, d in ipairs({ { 24, 24 }, { 17, 24 }, { 24, 17 }, { 10, 24 }, { 17, 17 }, { 24, 10 } }) do
		local dotg = Instance.new("Frame")
		dotg.Size = UDim2.fromOffset(3, 3)
		dotg.Position = UDim2.fromOffset(d[1], d[2])
		dotg.BackgroundColor3 = THEME.sub
		dotg.BackgroundTransparency = 0.3
		dotg.BorderSizePixel = 0
		dotg.ZIndex = 21
		dotg.Parent = grip
		corner(dotg, 2)
	end

	----------------------------------------------------------------
	-- Animasi terus-menerus
	----------------------------------------------------------------
	----------------------------------------------------------------
	-- Ikon logo (kotak) - tap buat buka panel
	----------------------------------------------------------------
	local ICON = 56
	local icon = Instance.new("Frame")
	icon.Size = UDim2.fromOffset(ICON, ICON)
	icon.Position = UDim2.fromOffset(16, 80)
	icon.BackgroundColor3 = THEME.bg1
	icon.BorderSizePixel = 0
	icon.Active = true
	icon.Parent = gui
	corner(icon, 16)

	local iconScale = Instance.new("UIScale")
	iconScale.Scale = 0
	iconScale.Parent = icon

	local iconStroke = Instance.new("UIStroke")
	iconStroke.Thickness = 2.5
	iconStroke.Color = Color3.new(1, 1, 1)
	iconStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	iconStroke.Parent = icon
	local iconGrad = Instance.new("UIGradient")
	iconGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, THEME.accent),
		ColorSequenceKeypoint.new(0.5, THEME.accent2),
		ColorSequenceKeypoint.new(1, THEME.accent),
	})
	iconGrad.Parent = iconStroke

	local iconFace = Instance.new("Frame")
	iconFace.Size = UDim2.new(1, -8, 1, -8)
	iconFace.Position = UDim2.fromOffset(4, 4)
	iconFace.BackgroundColor3 = Color3.new(1, 1, 1)
	iconFace.BorderSizePixel = 0
	iconFace.Parent = icon
	corner(iconFace, 12)
	local faceGrad = Instance.new("UIGradient")
	faceGrad.Color = ColorSequence.new(THEME.accent, THEME.accent2)
	faceGrad.Rotation = 45
	faceGrad.Parent = iconFace
	makeLogo(iconFace, 12, 26)

	local iconDot = Instance.new("Frame")
	iconDot.Size = UDim2.fromOffset(12, 12)
	iconDot.Position = UDim2.new(1, -9, 0, -3)
	iconDot.BackgroundColor3 = THEME.on
	iconDot.BackgroundTransparency = 1
	iconDot.BorderSizePixel = 0
	iconDot.ZIndex = 5
	iconDot.Parent = icon
	corner(iconDot, 6)

	----------------------------------------------------------------
	-- Animasi terus-menerus
	----------------------------------------------------------------
	local t0 = os.clock()
	local hb
	hb = RunService.Heartbeat:Connect(function()
		if not State.alive then
			hb:Disconnect()
			return
		end
		local t = os.clock() - t0
		strokeGrad.Rotation = (t * 70) % 360
		logoGrad.Rotation = (t * 40) % 360
		iconGrad.Rotation = (t * 80) % 360
		faceGrad.Rotation = 45 + math.sin(t * 1.5) * 25
		shine.Position = UDim2.new(((t * 0.45) % 2.2) - 0.4, 0, -0.4, 0)
		for _, p in ipairs(particles) do
			local y = 1 - ((t * p.speed + p.phase) % 1)
			p.f.Position = UDim2.new(p.x + math.sin(t + p.phase * 6) * p.sway, 0, y, 0)
		end
		local active = State.enabled or State.autoSteal or State.autoTreadmill or State.breakAnywhere or State.farmDiamond
		dot.BackgroundColor3 = active and THEME.on or THEME.off
		dot.BackgroundTransparency = active and (0.1 + 0.4 * (0.5 + 0.5 * math.sin(t * 5))) or 0.2
		iconDot.BackgroundTransparency = active and (0.05 + 0.4 * (0.5 + 0.5 * math.sin(t * 5))) or 1
	end)

	----------------------------------------------------------------
	-- Buka / tutup panel, drag, resize
	----------------------------------------------------------------
	tween(iconScale, 0.5, { Scale = 1 }, BACK)

	local panelOpen = false

	local function openPanel()
		if panelOpen or not State.alive then return end
		panelOpen = true
		local sz = gui.AbsoluteSize
		local w, h = root.Size.X.Offset, root.Size.Y.Offset
		local x = math.clamp(icon.Position.X.Offset, 0, math.max(0, sz.X - w))
		local y = math.clamp(icon.Position.Y.Offset, 0, math.max(0, sz.Y - h))
		root.Position = UDim2.fromOffset(x, y)
		root.Visible = true
		popScale.Scale = 0.6
		tween(popScale, 0.4, { Scale = 1 }, BACK)
		tween(iconScale, 0.2, { Scale = 0 }, BACK, Enum.EasingDirection.In)
		task.delay(0.2, function()
			if panelOpen then icon.Visible = false end
		end)
	end

	local function closePanel()
		if not panelOpen then return end
		panelOpen = false
		icon.Position = UDim2.fromOffset(root.Position.X.Offset, root.Position.Y.Offset)
		icon.Visible = true
		iconScale.Scale = 0
		tween(iconScale, 0.4, { Scale = 1 }, BACK)
		tween(popScale, 0.22, { Scale = 0.6 }, QUAD, Enum.EasingDirection.In)
		task.delay(0.22, function()
			if not panelOpen then root.Visible = false end
		end)
	end

	minBtn.Activated:Connect(closePanel)

	local drag
	local dragConn

	closeBtn.Activated:Connect(function()
		State.alive = false
		State.enabled = false
		State.autoSteal = false
		State.autoTreadmill = false
		State.farmDiamond = false
		if State.fpsBoost then pcall(setFps, false) end
		if tmConn then tmConn:Disconnect() end
		if dragConn then dragConn:Disconnect() end
		local r = hrp()
		if r then pcall(function() r.Anchored = false end) end
		if panelOpen then
			tween(popScale, 0.25, { Scale = 0 }, BACK, Enum.EasingDirection.In)
		else
			tween(iconScale, 0.25, { Scale = 0 }, BACK, Enum.EasingDirection.In)
		end
		task.delay(0.3, function() gui:Destroy() end)
	end)

	local function isPress(i)
		return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch
	end

	local function beginDrag(kind, i, target)
		local mine = {
			kind = kind, start = i.Position, pos = target.Position,
			w = root.Size.X.Offset, h = root.Size.Y.Offset, moved = 0,
		}
		drag = mine
		i.Changed:Connect(function()
			if i.UserInputState == Enum.UserInputState.End and drag == mine then
				drag = nil
				if kind == "icon" and mine.moved < 8 then openPanel() end
			end
		end)
	end

	bar.Active = true
	bar.InputBegan:Connect(function(i)
		if isPress(i) then beginDrag("panel", i, root) end
	end)
	grip.InputBegan:Connect(function(i)
		if isPress(i) then beginDrag("resize", i, root) end
	end)
	icon.InputBegan:Connect(function(i)
		if isPress(i) then beginDrag("icon", i, icon) end
	end)

	dragConn = UIS.InputChanged:Connect(function(i)
		if not drag then return end
		if i.UserInputType ~= Enum.UserInputType.MouseMovement and i.UserInputType ~= Enum.UserInputType.Touch then return end
		local d = i.Position - drag.start
		drag.moved = math.max(drag.moved, d.Magnitude)
		local sz = gui.AbsoluteSize
		if drag.kind == "panel" then
			local x = math.clamp(drag.pos.X.Offset + d.X, -(root.Size.X.Offset - 70), sz.X - 70)
			local y = math.clamp(drag.pos.Y.Offset + d.Y, 0, sz.Y - BAR_H)
			root.Position = UDim2.fromOffset(x, y)
		elseif drag.kind == "icon" then
			local x = math.clamp(drag.pos.X.Offset + d.X, 0, sz.X - ICON)
			local y = math.clamp(drag.pos.Y.Offset + d.Y, 0, sz.Y - ICON)
			icon.Position = UDim2.fromOffset(x, y)
		elseif drag.kind == "resize" then
			local maxW = math.max(MIN_W, math.min(MAX_W, sz.X - root.Position.X.Offset))
			local maxH = math.max(MIN_H, math.min(MAX_H, sz.Y - root.Position.Y.Offset))
			local nw = math.clamp(drag.w + d.X, MIN_W, maxW)
			local nh = math.clamp(drag.h + d.Y, MIN_H, maxH)
			root.Size = UDim2.fromOffset(nw, nh)
		end
	end)

	-- ambil logo dari URL di background (kalau gagal tetap pakai huruf K)
	task.spawn(function()
		local asset = fetchLogo()
		if asset and State.alive then
			for _, t in ipairs(logoTargets) do
				t.img.Image = asset
				t.img.Visible = true
				t.k.Visible = false
			end
		end
	end)

	task.spawn(function()
		local asset = fetchImage(BG_URL, "kennhub_bg.jpg", "\255\216\255")
		if asset and State.alive then
			bgImg.Image = asset
			bgImg.Visible = true
			bgDim.Visible = true
			tween(bgImg, 0.6, { ImageTransparency = 0 })
			tween(bgDim, 0.6, { BackgroundTransparency = 0.5 })
		end
	end)

	return { status = status, hint = hint, reasonLbl = reasonLbl, dumpBtn = dumpBtn, dumpLbl = dumpLbl, diaBtn = diaBtn, diaLbl = diaLbl }
end

local UI = buildUI()
local status, hint, reasonLbl, dumpBtn, dumpLbl = UI.status, UI.hint, UI.reasonLbl, UI.dumpBtn, UI.dumpLbl
local diaBtn, diaLbl = UI.diaBtn, UI.diaLbl


task.spawn(function()
	while State.alive do
		local n = 0
		for _, t in ipairs(cache) do
			if inArea(t) and not t.ghost then n = n + 1 end
		end
		hint.Text = "Telur: " .. n .. " | kena: " .. landed .. " | tolak: " .. rejects .. " | steal: " .. stealCount .. " | gain: " .. gains
		local s = State.autoTreadmill and tmText or statusText
		if State.farmDiamond then s = s .. " | " .. diamondText end
		if State.autoSteal then s = s .. " | " .. stealText elseif stealStopMsg ~= "" then s = s .. " | " .. stealStopMsg end
		status.Text = s
		local now, names = os.clock(), {}
		for a, untilT in pairs(blocked) do
			if untilT > now then table.insert(names, a) end
		end
		if #names > 0 then
			reasonLbl.Text = "Skip (ditolak): " .. table.concat(names, ", ") .. (lastReject ~= "" and (" | " .. lastReject) or "")
		else
			reasonLbl.Text = lastReject ~= "" and ("Tolakan terakhir: " .. lastReject) or ""
		end
		task.wait(0.4)
	end
end)

----------------------------------------------------------------
-- Copy info (treadmill + steal + plots)
----------------------------------------------------------------
local function dumpAll()
	local L = {}
	local function add(s) table.insert(L, s) end

	add("== TREADMILL KANDIDAT (dipakai script) ==")
	local okT, tms = pcall(findTreadmills)
	if okT and #tms > 0 then
		for i, e in ipairs(tms) do
			if i > 30 then break end
			local top = treadmillTop(e.inst)
			add(e.inst.ClassName .. " | " .. e.inst:GetFullName() .. " | top=" .. (top and tostring(top) or "?")
				.. " | prompt=" .. (e.prompt and (e.prompt:GetFullName() .. " [" .. e.prompt.ActionText .. "/" .. e.prompt.ObjectText .. "]") or "tidak ada"))
		end
	else
		add("(tidak ada object bernama 'treadmill')")
	end

	add("\n== PANGGILAN REMOTE (treadmill/steal/drop, hasil sadapan) ==")
	add("drop dipelajari: " .. ((dropLearn and dropLearn.remote) and dropLearn.remote:GetFullName() or "belum (drop manual 1x pas bawa hewan)"))
	if #recorded == 0 then
		add("(belum ada. Naik treadmill manual sekali, lalu tekan Copy Info lagi)")
	else
		for _, r in ipairs(recorded) do add(r) end
	end

	add("\n== SPEED GAIN ==")
	add("jumlah event: " .. gains .. " | argumen pertama: " .. tostring(firstGain))

	add("\n== TARGET STEAL (kandidat) ==")
	local okS, steals = pcall(collectSteal)
	if okS then
		for i, pp in ipairs(steals) do
			if i > 30 then break end
			add(pp:GetFullName() .. " | action=" .. pp.ActionText .. " | obj=" .. pp.ObjectText .. " | enabled=" .. tostring(pp.Enabled))
		end
		if #steals == 0 then add("(tidak ada prompt dengan kata steal/curi/grab)") end
	end

	add("\n== PENJAGA / SAFE ZONE (kandidat) ==")
	local okG, sp = pcall(scanSpecial)
	if okG then
		for i, g in ipairs(sp.guards) do
			if i > 15 then break end
			add("guard | " .. g.ClassName .. " | " .. g:GetFullName())
		end
		for i, z in ipairs(sp.safes) do
			if i > 15 then break end
			add("safezone | " .. z.ClassName .. " | " .. z:GetFullName())
		end
		for i, pp in ipairs(sp.drops) do
			if i > 15 then break end
			add("dropprompt | " .. pp:GetFullName() .. " | action=" .. pp.ActionText .. " | obj=" .. pp.ObjectText)
		end
		if #sp.guards == 0 then add("(tidak ada object bernama guard/penjaga)") end
		if #sp.safes == 0 then add("(tidak ada object bernama safezone/deposit/area aman)") end
		local hz = homePos()
		local zz = pickSafeZone(sp.safes, hz)
		local geo = zz and zoneGeometry(zz, hz)
		add("zona dipakai: " .. (zz and zz:GetFullName() or "tidak ada"))
		if geo then add("titik drop otomatis: " .. tostring(geo.drop) .. " | titik aman otomatis: " .. tostring(geo.safe)) end
		add("titik manual -> drop: " .. tostring(manualDrop) .. " | aman: " .. tostring(manualSafe))
	end

	add("\n" .. diamondReport())

	add("\n== PLOTS ==")
	local plots = workspace:FindFirstChild("Plots")
	if plots then
		for _, p in ipairs(plots:GetChildren()) do
			local a = {}
			for k, v in pairs(p:GetAttributes()) do table.insert(a, k .. "=" .. tostring(v)) end
			add(p.Name .. " | " .. table.concat(a, ", ") .. (ownsInst(p) and " | <- PUNYAMU" or ""))
		end
	else
		add("Workspace.Plots tidak ketemu")
	end

	local text = table.concat(L, "\n")
	print("[KennHub] dump:\n" .. text)
	if setclipboard then pcall(setclipboard, text) end
end

dumpBtn.Activated:Connect(function()
	local ok = pcall(dumpAll)
	dumpLbl.Text = ok and "Tersalin ke clipboard!" or "Gagal salin"
	task.delay(2, function() dumpLbl.Text = "Copy Info (Treadmill + Steal)" end)
end)

diaBtn.Activated:Connect(function()
	local ok, text = pcall(diamondReport)
	if ok then
		print("[KennHub] " .. text)
		if setclipboard then pcall(setclipboard, text) end
	end
	diaLbl.Text = ok and "Tersalin ke clipboard!" or "Gagal salin"
	task.delay(2, function() diaLbl.Text = "Copy Info Diamond" end)
end)

buildAnchors()
refresh(true, true)

print("[KennHub] loaded | remote:", hitRemote ~= nil, "| hitArg:", hitArg)
