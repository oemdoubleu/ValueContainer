--!optimize 2
--!native
--!nocheck

--[[
	SynchronousSignal

	An API signal implementation that performs all actions immediately (synchronously).
	Calling :Fire() immediately executes all subscribers on the same execution thread before returning control.
]]

export type ScriptSignal<T...> = {
	IsActive: (self: ScriptSignal<T...>) -> boolean,
	Fire: (self: ScriptSignal<T...>, ...T) -> (),
	Connect: (self: ScriptSignal<T...>, callback: (...T) -> ()) -> ScriptConnection,
	Once: (self: ScriptSignal<T...>, callback: (...T) -> ()) -> ScriptConnection,
	ConnectOnce: (self: ScriptSignal<T...>, callback: (...T) -> ()) -> ScriptConnection,
	DisconnectAll: (self: ScriptSignal<T...>) -> (),
	Destroy: (self: ScriptSignal<T...>) -> (),
	Wait: (self: ScriptSignal<T...>) -> ...T,
}
export type ScriptConnection = {
	Disconnect: (self: ScriptConnection) -> (),
	Destroy: (self: ScriptConnection) -> (),
	Connected: boolean,
}

local ScriptSignal = {}
ScriptSignal.__index = ScriptSignal

local ScriptConnection = {}
ScriptConnection.__index = ScriptConnection

function ScriptSignal.new()
	return setmetatable({
		_isActive = true,
		_connections = setmetatable({}, { __mode = "k" }), 
	}, ScriptSignal)
end

function ScriptSignal.Is(object)
	return typeof(object) == 'table' and getmetatable(object) == ScriptSignal
end

function ScriptSignal:IsActive()
	return self._isActive
end

function ScriptSignal:Connect(handler)
	assert(typeof(handler) == 'function', "Аргумент #1 (handler) должен быть функцией")

	if not self._isActive then
		return setmetatable({ Connected = false }, ScriptConnection)
	end

	local connection = setmetatable({
		Connected = true,
		_signal = self,
		_handler = handler,
	}, ScriptConnection)

	self._connections[connection] = true
	return connection
end

function ScriptSignal:Once(handler)
	assert(typeof(handler) == 'function', "Аргумент #1 (handler) должен быть функцией")
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end
ScriptSignal.ConnectOnce = ScriptSignal.Once

function ScriptSignal:Wait()
	local thread = coroutine.running()
	local connection

	connection = self:Once(function(...)
		task.spawn(thread, ...)
	end)

	return coroutine.yield()
end

function ScriptSignal:Fire(...)
	if not self._isActive then
		return
	end

	local connectionsToFire = {}
	for c in pairs(self._connections) do
		table.insert(connectionsToFire, c)
	end

	for _, connection in ipairs(connectionsToFire) do
		if connection.Connected then
			connection._handler(...)
		end
	end
end

function ScriptSignal:DisconnectAll()
	if not self._isActive then
		return
	end

	for connection in pairs(self._connections) do
		connection.Connected = false
		connection._signal = nil
		connection._handler = nil
	end
	self._connections = {}
end

function ScriptSignal:Destroy()
	if not self._isActive then
		return
	end
	self:DisconnectAll()
	self._isActive = false
end

function ScriptConnection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false

	local signal = self._signal
	if signal and signal._connections[self] then
		signal._connections[self] = nil
	end

	self._signal = nil
	self._handler = nil
end
ScriptConnection.Destroy = ScriptConnection.Disconnect

return ScriptSignal
