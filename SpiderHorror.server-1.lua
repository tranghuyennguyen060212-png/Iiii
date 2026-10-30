--[[
  SPIDER HORROR  -  dán vào ServerScriptService (loại Script, KHÔNG phải LocalScript)
  Bấm Play là chơi được, không cần xuất bản.

  Luật chơi: tìm đủ chìa khóa trong mê cung bê tông tối đen, mở cửa thoát.
  Con nhện đầu người bám trên trần sẽ đuổi theo bạn. Chạm là chết.
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

-- ================= CẤU HÌNH =================
local CFG = {
	GRID = 8,              -- mê cung GRID x GRID ô
	CELL = 22,             -- kích thước mỗi ô (studs)
	HEIGHT = 18,           -- độ cao trần
	WALL_T = 2,            -- độ dày tường
	KEYS = 3,              -- số chìa khóa cần nhặt
	PATROL_SPEED = 12,     -- tốc độ nhện khi tuần tra
	CHASE_SPEED = 24,      -- tốc độ khi thấy người chơi
	LUNGE_SPEED = 42,      -- tốc độ lao xuống
	SIGHT = 75,            -- tầm nhìn của nhện
	LUNGE_RANGE = 16,      -- khoảng cách bắt đầu lao xuống
	KILL_RANGE = 5,        -- khoảng cách giết
	WALK_SPEED = 13,
	-- (tùy chọn) dán ID âm thanh Roblox vào đây, để trống = không có tiếng
	SCARE_SOUND = "",
	AMBIENT_SOUND = "",
}

local S, H, T, N = CFG.CELL, CFG.HEIGHT, CFG.WALL_T, CFG.GRID
local CEIL_Y = H - 5.5 -- độ cao thân nhện khi bám trần

local state = {
	gen = 0, map = nil, open = nil, collected = 0, won = false, m = nil, door = nil,
	phase = "lobby", starting = false, lobbyPrompt = nil,
}
local returnToLobby -- khai báo trước, định nghĩa ở phần SẢNH CHỜ bên dưới

-- ================= TIỆN ÍCH =================
local function mkPart(parent, size, cf, color, mat)
	local p = Instance.new("Part")
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat or Enum.Material.Concrete
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function cellCenter(x, z)
	return Vector3.new((x - 0.5) * S, 0, (z - 0.5) * S)
end

local function cellOf(pos)
	return {
		math.clamp(math.floor(pos.X / S) + 1, 1, N),
		math.clamp(math.floor(pos.Z / S) + 1, 1, N),
	}
end

-- ================= ÁNH SÁNG ĐEN TRẮNG =================
local function setupLighting()
	for _, c in ipairs(Lighting:GetChildren()) do
		if c:IsA("PostEffect") or c:IsA("Sky") or c:IsA("Atmosphere") then
			c:Destroy()
		end
	end
	Lighting.ClockTime = 0
	Lighting.Brightness = 0
	Lighting.Ambient = Color3.new(0.025, 0.025, 0.025)
	Lighting.OutdoorAmbient = Color3.new(0, 0, 0)
	Lighting.EnvironmentDiffuseScale = 0
	Lighting.EnvironmentSpecularScale = 0
	Lighting.FogColor = Color3.new(0, 0, 0)
	Lighting.FogStart = 4
	Lighting.FogEnd = 85
	Lighting.GlobalShadows = true

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Saturation = -1
	cc.Contrast = 0.35
	cc.Brightness = -0.03
	cc.Parent = Lighting

	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.35
	bloom.Size = 24
	bloom.Threshold = 0.95
	bloom.Parent = Lighting

	if CFG.AMBIENT_SOUND ~= "" then
		local s = Instance.new("Sound")
		s.SoundId = CFG.AMBIENT_SOUND
		s.Looped = true
		s.Volume = 0.6
		s.Parent = workspace
		s:Play()
	end
end

-- ================= MÊ CUNG =================
local DIRS = { { 0, -1, "n", "s" }, { 0, 1, "s", "n" }, { 1, 0, "e", "w" }, { -1, 0, "w", "e" } }

local function genMaze()
	local open, visited = {}, {}
	for x = 1, N do
		open[x], visited[x] = {}, {}
		for z = 1, N do
			open[x][z] = { n = false, s = false, e = false, w = false }
		end
	end
	local stack = { { 1, 1 } }
	visited[1][1] = true
	while #stack > 0 do
		local cur = stack[#stack]
		local opts = {}
		for _, d in ipairs(DIRS) do
			local nx, nz = cur[1] + d[1], cur[2] + d[2]
			if nx >= 1 and nx <= N and nz >= 1 and nz <= N and not visited[nx][nz] then
				table.insert(opts, { nx, nz, d })
			end
		end
		if #opts == 0 then
			table.remove(stack)
		else
			local o = opts[math.random(#opts)]
			open[cur[1]][cur[2]][o[3][3]] = true
			open[o[1]][o[2]][o[3][4]] = true
			visited[o[1]][o[2]] = true
			table.insert(stack, { o[1], o[2] })
		end
	end
	-- mở thêm vài lối để có vòng lặp (chạy trốn được)
	for _ = 1, N * 2 do
		local x, z = math.random(1, N - 1), math.random(1, N)
		open[x][z].e = true
		open[x + 1][z].w = true
	end
	return open
end

-- BFS: trả về ô kế tiếp trên đường từ 'from' tới 'to'
local function bfsNext(open, from, to)
	if from[1] == to[1] and from[2] == to[2] then
		return nil
	end
	local function key(x, z) return x * 100 + z end
	local prev = { [key(from[1], from[2])] = false }
	local queue, head = { from }, 1
	while head <= #queue do
		local c = queue[head]
		head += 1
		if c[1] == to[1] and c[2] == to[2] then
			break
		end
		for _, d in ipairs(DIRS) do
			if open[c[1]][c[2]][d[3]] then
				local nx, nz = c[1] + d[1], c[2] + d[2]
				local k = key(nx, nz)
				if prev[k] == nil then
					prev[k] = c
					table.insert(queue, { nx, nz })
				end
			end
		end
	end
	local cur = to
	local p = prev[key(cur[1], cur[2])]
	if p == nil then
		return nil
	end
	while p and not (p[1] == from[1] and p[2] == from[2]) do
		cur = p
		p = prev[key(cur[1], cur[2])]
	end
	return cur
end

-- ================= NHỆN ĐẦU NGƯỜI =================
local function place(p, a, b)
	local len = (b - a).Magnitude
	if len < 0.01 then return end
	p.Size = Vector3.new(p.Size.X, p.Size.Y, len)
	p.CFrame = CFrame.lookAt(a, b) * CFrame.new(0, 0, -len / 2)
end

local function buildMonster()
	local model = Instance.new("Model")
	model.Name = "TheThing"
	model.Parent = workspace
	local mon = { model = model, body = {}, legs = {}, phase = 0 }

	local function add(size, localCF, color, sphere, mat)
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.Size = size
		p.Color = color
		p.Material = mat or Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if sphere then
			local m = Instance.new("SpecialMesh")
			m.MeshType = Enum.MeshType.Sphere
			m.Parent = p
		end
		p.Parent = model
		table.insert(mon.body, { part = p, cf = localCF })
		return p
	end

	local BLACK = Color3.fromRGB(12, 12, 12)
	local SKIN = Color3.fromRGB(205, 200, 195)
	local DARKSKIN = Color3.fromRGB(150, 145, 140)

	-- thân nhện
	add(Vector3.new(5, 4.5, 6.5), CFrame.new(0, 0, 2.8), BLACK, true)
	add(Vector3.new(3.2, 3, 3.4), CFrame.new(0, 0, -0.2), BLACK, true)

	-- ĐẦU NGƯỜI (xoay 180° so với thân bị lật => đầu thẳng đứng, lủng lẳng dưới trần)
	local headCF = CFrame.new(0, 0, -2.9) * CFrame.Angles(0, 0, math.pi)
	add(Vector3.new(3.4, 4.2, 3.4), headCF, SKIN, true)
	-- mũi
	add(Vector3.new(0.5, 0.9, 0.6), headCF * CFrame.new(0, -0.1, -1.65), DARKSKIN, true)
	-- hai hốc mắt đen + đồng tử trắng nhỏ
	for _, sx in ipairs({ -0.85, 0.85 }) do
		add(Vector3.new(0.9, 1.4, 0.6), headCF * CFrame.new(sx, 0.55, -1.45), BLACK, true)
		add(Vector3.new(0.22, 0.22, 0.2), headCF * CFrame.new(sx * 0.95, 0.35, -1.78), Color3.new(1, 1, 1), true, Enum.Material.Neon)
	end
	-- miệng há rộng + răng
	add(Vector3.new(2.1, 1.1, 0.6), headCF * CFrame.new(0, -1.15, -1.45), BLACK, true)
	for i = -4, 4 do
		add(Vector3.new(0.17, 0.5, 0.2), headCF * CFrame.new(i * 0.22, -0.78, -1.72), Color3.fromRGB(235, 235, 225))
		add(Vector3.new(0.17, 0.45, 0.2), headCF * CFrame.new(i * 0.22, -1.55, -1.70), Color3.fromRGB(235, 235, 225))
	end
	-- tóc dài rũ xuống
	for i = -3, 3 do
		local len = 3 + math.abs(i) * 0.4
		add(Vector3.new(0.12, len, 0.12),
			headCF * CFrame.new(i * 0.5, 1.2 - len / 2 + 0.6, -0.4 + math.random() * 0.4) * CFrame.Angles(0, 0, (math.random() - 0.5) * 0.2),
			BLACK)
	end

	-- 8 chân, mỗi chân 2 đoạn
	local zs = { -1.6, -0.4, 0.9, 2.3 }
	for i = 1, 8 do
		local side = (i <= 4) and -1 or 1
		local idx = (i - 1) % 4 + 1
		local function seg(th)
			local p = Instance.new("Part")
			p.Anchored = true
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = false
			p.Size = Vector3.new(th, th, 1)
			p.Color = BLACK
			p.Material = Enum.Material.SmoothPlastic
			p.Parent = model
			return p
		end
		local hip = Vector3.new(side * 1.2, 0, zs[idx])
		table.insert(mon.legs, {
			up = seg(0.34),
			low = seg(0.24),
			hip = hip,
			knee = hip + Vector3.new(side * 4.5, 2.4, (idx <= 2) and -1.5 or 1.5),
			foot = hip + Vector3.new(side * 8.5, -5.5, (idx - 2.5) * 2.4),
			off = i * 1.3,
		})
	end
	return mon
end

local function updateMonster(mon, rootCF, dt, speed)
	mon.phase += dt * (1.5 + speed * 0.3)
	for _, b in ipairs(mon.body) do
		b.part.CFrame = rootCF * b.cf
	end
	for _, leg in ipairs(mon.legs) do
		local ph = mon.phase + leg.off
		local lift = math.max(0, math.sin(ph))
		local a = rootCF:PointToWorldSpace(leg.hip)
		local b = rootCF:PointToWorldSpace(leg.knee + Vector3.new(0, 0, math.sin(ph) * 0.8))
		local c = rootCF:PointToWorldSpace(leg.foot + Vector3.new(0, lift * 1.2, math.cos(ph) * 1.5))
		place(leg.up, a, b)
		place(leg.low, b, c)
	end
end

-- ================= GIAO DIỆN (HUD / JUMPSCARE) =================
local function getGui(pl)
	local pg = pl:FindFirstChild("PlayerGui")
	return pg and pg:FindFirstChild("HorrorGui")
end

local function makeGui(pl)
	local g = Instance.new("ScreenGui")
	g.Name = "HorrorGui"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true

	local hud = Instance.new("TextLabel")
	hud.Name = "Hud"
	hud.BackgroundTransparency = 1
	hud.Position = UDim2.new(0, 20, 0, 20)
	hud.Size = UDim2.new(0, 300, 0, 40)
	hud.Font = Enum.Font.Code
	hud.TextSize = 28
	hud.TextColor3 = Color3.new(1, 1, 1)
	hud.TextXAlignment = Enum.TextXAlignment.Left
	hud.Text = ""
	hud.Parent = g

	local msg = Instance.new("TextLabel")
	msg.Name = "Msg"
	msg.BackgroundTransparency = 1
	msg.AnchorPoint = Vector2.new(0.5, 0.5)
	msg.Position = UDim2.new(0.5, 0, 0.3, 0)
	msg.Size = UDim2.new(0.8, 0, 0, 60)
	msg.Font = Enum.Font.Code
	msg.TextSize = 36
	msg.TextColor3 = Color3.new(1, 1, 1)
	msg.TextStrokeTransparency = 0
	msg.Visible = false
	msg.Parent = g

	local scare = Instance.new("Frame")
	scare.Name = "Scare"
	scare.BackgroundColor3 = Color3.new(0, 0, 0)
	scare.BorderSizePixel = 0
	scare.Size = UDim2.new(1, 0, 1, 0)
	scare.ZIndex = 50
	scare.Visible = false
	scare.Parent = g
	local face = Instance.new("TextLabel")
	face.Name = "Face"
	face.BackgroundTransparency = 1
	face.Size = UDim2.new(1, 0, 1, 0)
	face.Font = Enum.Font.Code
	face.TextScaled = true
	face.TextColor3 = Color3.new(1, 1, 1)
	face.Text = "NÓ ĐÃ THẤY BẠN"
	face.ZIndex = 51
	face.Parent = scare

	g.Parent = pl:WaitForChild("PlayerGui")
	return g
end

local function updateHud()
	for _, pl in ipairs(Players:GetPlayers()) do
		local g = getGui(pl)
		if g then
			if state.phase == "lobby" then
				g.Hud.Text = "SẢNH CHỜ"
			else
				g.Hud.Text = ("CHÌA KHÓA  %d / %d"):format(state.collected, CFG.KEYS)
			end
		end
	end
end

local function say(text, dur, onlyPlayer)
	for _, pl in ipairs(onlyPlayer and { onlyPlayer } or Players:GetPlayers()) do
		local g = getGui(pl)
		if g then
			local msg = g.Msg
			msg.Text = text
			msg.Visible = true
			task.delay(dur or 4, function()
				if msg.Text == text then
					msg.Visible = false
				end
			end)
		end
	end
end

local function jumpscare(pl)
	local g = getGui(pl)
	if not g then return end
	local f = g.Scare
	f.Visible = true
	if CFG.SCARE_SOUND ~= "" then
		local s = Instance.new("Sound")
		s.SoundId = CFG.SCARE_SOUND
		s.Volume = 3
		s.Parent = g
		s:Play()
		Debris:AddItem(s, 5)
	end
	task.spawn(function()
		for i = 1, 10 do
			local white = (i % 2 == 1)
			f.BackgroundColor3 = white and Color3.new(1, 1, 1) or Color3.new(0, 0, 0)
			f.Face.TextColor3 = white and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
			task.wait(0.06)
		end
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.Face.TextColor3 = Color3.new(1, 1, 1)
		task.wait(1.4)
		f.Visible = false
	end)
end

-- ================= TẠO MÀN CHƠI =================
local function shuffle(t)
	for i = #t, 2, -1 do
		local j = math.random(i)
		t[i], t[j] = t[j], t[i]
	end
	return t
end

local function buildLevel()
	state.gen += 1
	local gen = state.gen
	if state.map then state.map:Destroy() end
	if state.m then state.m.mon.model:Destroy() state.m = nil end
	state.collected, state.won = 0, false

	local map = Instance.new("Folder")
	map.Name = "Map"
	map.Parent = workspace
	state.map = map
	local open = genMaze()
	state.open = open

	local WALL = Color3.fromRGB(105, 105, 105)
	local FLOOR = Color3.fromRGB(60, 60, 60)

	mkPart(map, Vector3.new(N * S + T, 1, N * S + T), CFrame.new(N * S / 2, -0.5, N * S / 2), FLOOR)
	mkPart(map, Vector3.new(N * S + T, 1, N * S + T), CFrame.new(N * S / 2, H + 0.5, N * S / 2), Color3.fromRGB(45, 45, 45))

	for x = 1, N do
		for z = 1, N do
			local c = open[x][z]
			if not c.n then
				mkPart(map, Vector3.new(S + T, H, T), CFrame.new((x - 0.5) * S, H / 2, (z - 1) * S), WALL)
			end
			if not c.w then
				mkPart(map, Vector3.new(T, H, S + T), CFrame.new((x - 1) * S, H / 2, (z - 0.5) * S), WALL)
			end
			if z == N and not c.s then
				mkPart(map, Vector3.new(S + T, H, T), CFrame.new((x - 0.5) * S, H / 2, z * S), WALL)
			end
			if x == N and not c.e then
				mkPart(map, Vector3.new(T, H, S + T), CFrame.new(x * S, H / 2, (z - 0.5) * S), WALL)
			end
		end
	end

	-- cửa thoát ở góc xa nhất
	local door = mkPart(map, Vector3.new(9, 13, 1), CFrame.new((N - 0.5) * S, 6.5, N * S - T / 2 - 0.5),
		Color3.fromRGB(120, 0, 0), Enum.Material.Neon)
	door.Name = "ExitDoor"
	state.door = door
	local dl = Instance.new("PointLight")
	dl.Range = 20
	dl.Brightness = 1
	dl.Color = Color3.fromRGB(255, 60, 60)
	dl.Parent = door
	door.Touched:Connect(function(hit)
		if state.won or state.collected < CFG.KEYS then return end
		local pl = Players:GetPlayerFromCharacter(hit.Parent)
		if not pl then return end
		state.won = true
		say("BẠN ĐÃ THOÁT KHỎI NÓ.", 6)
		task.delay(6, function()
			returnToLobby()
		end)
	end)

	-- chìa khóa
	local cells = {}
	for x = 1, N do
		for z = 1, N do
			if not (x == 1 and z == 1) and not (x == N and z == N) then
				table.insert(cells, { x, z })
			end
		end
	end
	shuffle(cells)
	for i = 1, CFG.KEYS do
		local cc = cellCenter(cells[i][1], cells[i][2])
		local key = Instance.new("Part")
		key.Name = "Key"
		key.Shape = Enum.PartType.Ball
		key.Size = Vector3.new(1.4, 1.4, 1.4)
		key.Anchored = true
		key.CanCollide = false
		key.Material = Enum.Material.Neon
		key.Color = Color3.new(1, 1, 1)
		key.Position = cc + Vector3.new(0, 2.5, 0)
		key.Parent = map
		local kl = Instance.new("PointLight")
		kl.Range = 14
		kl.Brightness = 1.2
		kl.Parent = key
		local pp = Instance.new("ProximityPrompt")
		pp.ActionText = "Nhặt"
		pp.ObjectText = "Chìa khóa"
		pp.HoldDuration = 0.6
		pp.MaxActivationDistance = 8
		pp.RequiresLineOfSight = false
		pp.Parent = key
		pp.Triggered:Connect(function()
			if not key.Parent then return end
			key:Destroy()
			state.collected += 1
			updateHud()
			if state.collected >= CFG.KEYS then
				door.Color = Color3.new(1, 1, 1)
				dl.Color = Color3.new(1, 1, 1)
				say("CỬA THOÁT ĐÃ MỞ. CHẠY ĐI!", 5)
			else
				say(("Đã nhặt %d/%d chìa khóa"):format(state.collected, CFG.KEYS), 3)
			end
		end)
	end

	-- vài bóng đèn chập chờn
	shuffle(cells)
	for i = 1, 5 do
		local cc = cellCenter(cells[i][1], cells[i][2])
		local lamp = mkPart(map, Vector3.new(1.5, 0.3, 4), CFrame.new(cc.X, H - 0.2, cc.Z), Color3.new(1, 1, 1), Enum.Material.Neon)
		local ll = Instance.new("PointLight")
		ll.Range = 24
		ll.Brightness = 0.9
		ll.Parent = lamp
		task.spawn(function()
			while state.gen == gen and lamp.Parent do
				local on = math.random() > 0.35
				ll.Enabled = on
				lamp.Material = on and Enum.Material.Neon or Enum.Material.Concrete
				lamp.Color = on and Color3.new(1, 1, 1) or Color3.fromRGB(30, 30, 30)
				task.wait(math.random() * 1.5 + 0.05)
			end
		end)
	end

	-- con nhện
	local start = cellCenter(math.ceil(N / 2), math.ceil(N / 2))
	state.m = {
		mon = buildMonster(),
		pos = Vector3.new(start.X, CEIL_Y, start.Z),
		yaw = 0, cool = 4, sightT = 0, vis = false, goal = nil,
	}
	updateHud()
end

-- ================= NGƯỜI CHƠI =================
local function setupPlayerCharacter(pl, ch)
	local head = ch:WaitForChild("Head")
	local light = Instance.new("PointLight")
	light.Name = "Torch"
	light.Range = 26
	light.Brightness = 1.6
	light.Color = Color3.new(1, 1, 1)
	light.Shadows = true
	light.Parent = head
	local hum = ch:WaitForChild("Humanoid")
	hum.WalkSpeed = CFG.WALK_SPEED
	hum.JumpHeight = 0
	-- đang trong trận: hồi sinh ngay trong mê cung thay vì ở sảnh
	if state.phase == "playing" then
		ch:WaitForChild("HumanoidRootPart")
		ch:PivotTo(CFrame.new(cellCenter(1, 1) + Vector3.new(0, 3, 0)))
	end
	updateHud()
end

local function onPlayer(pl)
	pl.CameraMode = Enum.CameraMode.LockFirstPerson
	makeGui(pl)
	pl.CharacterAdded:Connect(function(ch)
		setupPlayerCharacter(pl, ch)
	end)
	if pl.Character then
		task.spawn(setupPlayerCharacter, pl, pl.Character)
	end
	updateHud()
end

-- ================= KHỞI ĐỘNG =================
math.randomseed(os.time())
Players.RespawnTime = 3
setupLighting()

local bp = workspace:FindFirstChild("Baseplate")
if bp then bp:Destroy() end
for _, d in ipairs(workspace:GetDescendants()) do
	if d:IsA("SpawnLocation") then d:Destroy() end
end

-- ================= SẢNH CHỜ (LOBBY) =================
local LOBBY = Vector3.new(-100, 0, 88) -- nằm ngoài mê cung (mê cung chiếm X từ 0 tới 176)

local function cleanupLevel()
	state.gen += 1 -- dừng các vòng lặp đèn chập chờn của màn cũ
	if state.map then state.map:Destroy() state.map = nil end
	if state.m then state.m.mon.model:Destroy() state.m = nil end
	state.collected, state.won = 0, false
end

local function startRound()
	if state.phase ~= "lobby" or state.starting then return end
	state.starting = true
	if state.lobbyPrompt then state.lobbyPrompt.Enabled = false end
	for n = 3, 1, -1 do
		say(("Trận đấu bắt đầu sau %d..."):format(n), 1.1)
		task.wait(1)
	end
	buildLevel()
	state.phase = "playing"
	state.starting = false
	local startCF = CFrame.new(cellCenter(1, 1) + Vector3.new(0, 3, 0))
	for _, pl in ipairs(Players:GetPlayers()) do
		local ch = pl.Character
		if ch and ch:FindFirstChild("HumanoidRootPart") then
			ch:PivotTo(startCF)
		end
	end
	updateHud()
	say("TÌM CHÌA KHÓA. ĐỪNG NHÌN LÊN TRẦN.", 5)
end

function returnToLobby()
	cleanupLevel()
	state.phase = "lobby"
	state.starting = false
	if state.lobbyPrompt then state.lobbyPrompt.Enabled = true end
	for _, pl in ipairs(Players:GetPlayers()) do
		pl:LoadCharacter() -- hồi sinh tại sảnh
	end
	updateHud()
end

local function buildLobby()
	local old = workspace:FindFirstChild("Lobby")
	if old then old:Destroy() end
	local lob = Instance.new("Folder")
	lob.Name = "Lobby"
	lob.Parent = workspace

	local W, D, LH = 44, 44, 16
	local cx, cz = LOBBY.X, LOBBY.Z
	local WALLC = Color3.fromRGB(90, 90, 90)

	-- sàn, trần, 4 tường
	mkPart(lob, Vector3.new(W + T, 1, D + T), CFrame.new(cx, -0.5, cz), Color3.fromRGB(55, 55, 55))
	mkPart(lob, Vector3.new(W + T, 1, D + T), CFrame.new(cx, LH + 0.5, cz), Color3.fromRGB(40, 40, 40))
	mkPart(lob, Vector3.new(W + T, LH, T), CFrame.new(cx, LH / 2, cz - D / 2), WALLC)
	mkPart(lob, Vector3.new(W + T, LH, T), CFrame.new(cx, LH / 2, cz + D / 2), WALLC)
	mkPart(lob, Vector3.new(T, LH, D + T), CFrame.new(cx - W / 2, LH / 2, cz), WALLC)
	mkPart(lob, Vector3.new(T, LH, D + T), CFrame.new(cx + W / 2, LH / 2, cz), WALLC)

	-- bảng chữ
	local function sign(size, cf, face, text)
		local p = mkPart(lob, size, cf, Color3.fromRGB(8, 8, 8), Enum.Material.SmoothPlastic)
		local sg = Instance.new("SurfaceGui")
		sg.Face = face
		sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		sg.PixelsPerStud = 40
		sg.Parent = p
		local tl = Instance.new("TextLabel")
		tl.BackgroundTransparency = 1
		tl.Size = UDim2.new(1, 0, 1, 0)
		tl.Font = Enum.Font.Code
		tl.TextScaled = true
		tl.TextColor3 = Color3.new(1, 1, 1)
		tl.Text = text
		tl.Parent = sg
		return p
	end
	sign(Vector3.new(34, 8, 0.4), CFrame.new(cx, 9, cz - 20.8), Enum.NormalId.Back, "SPIDER HORROR\nKẺ BÁM TRẦN")
	sign(Vector3.new(0.4, 10, 24), CFrame.new(cx - 20.8, 8, cz), Enum.NormalId.Right,
		"LUẬT CHƠI\n1. Tìm 3 chìa khóa\n2. Đừng nhìn lên trần\n3. Chạy tới cửa thoát\nNó chạm vào bạn là chết")

	-- bệ + nút bắt đầu
	mkPart(lob, Vector3.new(4, 4, 4), CFrame.new(cx, 2, cz - 8), Color3.fromRGB(35, 35, 35))
	local btn = mkPart(lob, Vector3.new(3, 0.5, 3), CFrame.new(cx, 4.25, cz - 8), Color3.fromRGB(200, 0, 0), Enum.Material.Neon)
	btn.CanCollide = false
	local bl = Instance.new("PointLight")
	bl.Range = 16
	bl.Brightness = 1.5
	bl.Color = Color3.fromRGB(255, 40, 40)
	bl.Parent = btn
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = "Bắt đầu"
	pp.ObjectText = "Vào mê cung"
	pp.HoldDuration = 1
	pp.MaxActivationDistance = 10
	pp.RequiresLineOfSight = false
	pp.Parent = btn
	pp.Triggered:Connect(function()
		startRound()
	end)
	state.lobbyPrompt = pp

	-- đèn trần chập chờn
	for _, o in ipairs({ { -10, -10 }, { 10, -10 }, { -10, 10 }, { 10, 10 } }) do
		local lamp = mkPart(lob, Vector3.new(1.5, 0.3, 5), CFrame.new(cx + o[1], LH - 0.2, cz + o[2]),
			Color3.new(1, 1, 1), Enum.Material.Neon)
		local ll = Instance.new("PointLight")
		ll.Range = 30
		ll.Brightness = 0.8
		ll.Parent = lamp
		task.spawn(function()
			while lamp.Parent do
				local on = math.random() > 0.2
				ll.Enabled = on
				lamp.Material = on and Enum.Material.Neon or Enum.Material.Concrete
				lamp.Color = on and Color3.new(1, 1, 1) or Color3.fromRGB(30, 30, 30)
				task.wait(math.random() * 2 + 0.1)
			end
		end)
	end

	-- điểm hồi sinh trong sảnh
	local sp = Instance.new("SpawnLocation")
	sp.Anchored = true
	sp.Size = Vector3.new(6, 1, 6)
	sp.Position = Vector3.new(cx, 0.5, cz + 12)
	sp.Transparency = 1
	sp.CanCollide = false
	sp.Neutral = true
	sp.Duration = 0
	sp.Parent = lob
end

buildLobby()
Players.PlayerAdded:Connect(onPlayer)
for _, pl in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayer, pl)
end

-- ================= AI CỦA NHỆN =================
RunService.Heartbeat:Connect(function(dt)
	local m = state.m
	if not m or state.won then return end

	-- người chơi gần nhất còn sống
	local target, tdist, tpl, thum
	for _, pl in ipairs(Players:GetPlayers()) do
		local ch = pl.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if hrp and hum and hum.Health > 0 then
			local d = (hrp.Position - m.pos).Magnitude
			if not tdist or d < tdist then
				target, tdist, tpl, thum = hrp, d, pl, hum
			end
		end
	end

	m.cool = math.max(0, m.cool - dt)
	m.sightT -= dt
	local visible = false
	if target and tdist < CFG.SIGHT and m.cool <= 0 then
		if m.sightT <= 0 then
			m.sightT = 0.2
			local rp = RaycastParams.new()
			rp.FilterType = Enum.RaycastFilterType.Include
			rp.FilterDescendantsInstances = { state.map }
			m.vis = workspace:Raycast(m.pos, target.Position - m.pos, rp) == nil
		end
		visible = m.vis
	else
		m.vis = false
	end

	-- chọn đích đến + tốc độ
	local speed = CFG.PATROL_SPEED
	local dest
	if visible and tdist < CFG.LUNGE_RANGE then
		speed = CFG.LUNGE_SPEED
		dest = target.Position + Vector3.new(0, 1.5, 0)
	else
		local fromC = cellOf(m.pos)
		local goalC
		if visible then
			speed = CFG.CHASE_SPEED
			goalC = cellOf(target.Position)
			m.goal = goalC
		else
			if not m.goal or (m.goal[1] == fromC[1] and m.goal[2] == fromC[2]) then
				m.goal = { math.random(N), math.random(N) }
			end
			goalC = m.goal
		end
		local nxt = bfsNext(state.open, fromC, goalC) or fromC
		local cc = cellCenter(nxt[1], nxt[2])
		dest = Vector3.new(cc.X, CEIL_Y, cc.Z)
		if visible and fromC[1] == goalC[1] and fromC[2] == goalC[2] then
			dest = Vector3.new(target.Position.X, CEIL_Y, target.Position.Z)
		end
	end

	-- di chuyển
	local vec = dest - m.pos
	local dist = vec.Magnitude
	local newPos = m.pos
	if dist > 0.001 then
		newPos = m.pos + vec.Unit * math.min(dist, speed * dt)
	end
	local dx, dz = newPos.X - m.pos.X, newPos.Z - m.pos.Z
	if dx * dx + dz * dz > 1e-6 then
		local ty = math.atan2(-dx, -dz)
		local d = (ty - m.yaw + math.pi) % (2 * math.pi) - math.pi
		m.yaw += d * math.min(1, dt * 8)
	end
	m.pos = newPos

	-- giết người chơi
	if target and tdist < CFG.KILL_RANGE and m.cool <= 0 then
		thum.Health = 0
		jumpscare(tpl)
		m.cool = 6
		local far
		repeat
			far = { math.random(N), math.random(N) }
		until math.abs(far[1] - 1) + math.abs(far[2] - 1) >= N
		local fc = cellCenter(far[1], far[2])
		m.pos = Vector3.new(fc.X, CEIL_Y, fc.Z)
		m.goal = nil
	end

	-- vẽ nhện (lật ngược để bám trần) + giật giật khi đuổi
	local jitter = Vector3.zero
	if visible then
		jitter = Vector3.new((math.random() - 0.5) * 0.25, (math.random() - 0.5) * 0.15, (math.random() - 0.5) * 0.25)
	end
	local rootCF = CFrame.new(m.pos + jitter) * CFrame.Angles(0, m.yaw, 0) * CFrame.Angles(0, 0, math.pi)
	updateMonster(m.mon, rootCF, dt, speed)
end)
