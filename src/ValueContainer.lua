--!native
--!optimize 2

local Signal = require(script.SynchronousSignal)

type ScriptConnection = {
	Connected: boolean,
	Disconnect: (self: ScriptConnection) -> (),
}

export type ScriptSignal<T...> = {
	IsActive: (self: ScriptSignal<...T>) -> boolean,
	Fire: (self: ScriptSignal<...T>, ...T) -> (),
	Connect: (self: ScriptSignal<...T>, callback: (...T) -> ()) -> ScriptConnection,
	Once: (self: ScriptSignal<...T>, callback: (...T) -> ()) -> ScriptConnection,
	DisconnectAll: (self: ScriptSignal<...T>) -> (),
	Destroy: (self: ScriptSignal<...T>) -> (),
	Wait: (self: ScriptSignal<...T>) -> ...T,
}

type ThrottleOptions = { leading: boolean?, trailing: boolean? }

export type ReadOnlyValueContainer<T> = {
	Value: T,
	Changed: ScriptSignal<T, T>,
	Get: (self: ReadOnlyValueContainer<T>) -> T,
	Destroy: (self: ReadOnlyValueContainer<T>) -> (),
	Map: <U>(self: ReadOnlyValueContainer<T>, transformFn: (T) -> U) -> ReadOnlyValueContainer<U>,
	Filter: (self: ReadOnlyValueContainer<T>, filterFn: (T) -> boolean) -> ReadOnlyValueContainer<T?>,
	Debounce: (self: ReadOnlyValueContainer<T>, delayTime: number?) -> ReadOnlyValueContainer<T>,
	Throttle: (self: ReadOnlyValueContainer<T>, delayTime: number?, options: ThrottleOptions?) -> ReadOnlyValueContainer<T>,
	DistinctUntilChanged: (self: ReadOnlyValueContainer<T>, comparator: ((a: T, b: T) -> boolean)?) -> ReadOnlyValueContainer<T>,
	Scan: <U>(self: ReadOnlyValueContainer<T>, reducer: (acc: U, value: T) -> U, initialAccumulator: U) -> ReadOnlyValueContainer<U>,
	Peek: (self: ReadOnlyValueContainer<T>, callback: (newValue: T, oldValue: T) -> ()) -> ReadOnlyValueContainer<T>,
	Wait: (self: ReadOnlyValueContainer<T>) -> (T, T),
	AsReadOnly: (self: ReadOnlyValueContainer<T>) -> ReadOnlyValueContainer<T>,
}

export type ValueContainer<T> = ReadOnlyValueContainer<T> & {
	Set: (self: ValueContainer<T>, newValue: T) -> (),
}

local ValueContainerImpl = {}
local ValueContainerMetatable = {}

local _isFiring = false
local _dirtyContainers = {}

local function deepCompare(t1, t2, visited)
	if t1 == t2 then return true end
	if type(t1) ~= "table" or type(t2) ~= "table" then return false end

	visited = visited or {}
	if visited[t1] then
		return visited[t1] == t2
	end
	visited[t1] = t2
	visited[t2] = t1

	local keys1_count = 0
	for _ in pairs(t1) do keys1_count += 1 end
	local keys2_count = 0
	for _ in pairs(t2) do keys2_count += 1 end
	if keys1_count ~= keys2_count then return false end

	for k, v1 in pairs(t1) do
		local v2 = t2[k]
		if not deepCompare(v1, v2, visited) then return false end
	end
	return true
end

local function _fireDirtyContainers()
	if _isFiring then return end
	_isFiring = true
	local processedInThisTransaction = {}
	while next(_dirtyContainers) do
		local containersToProcess = _dirtyContainers
		_dirtyContainers = {}
		for container, data in pairs(containersToProcess) do
			if not container._isDestroyed then
				if processedInThisTransaction[container] then
					error("Cyclic dependency detected involving container: " .. tostring(container), 2)
				end
				processedInThisTransaction[container] = true
				container.Changed:Fire(data.newValue, data.oldValue)
			end
		end
	end
	_isFiring = false
end

ValueContainerMetatable.__index = function(self, key)
	if key == "Value" then return self._value end
	return ValueContainerImpl[key]
end

ValueContainerMetatable.__newindex = function(self, key, value)
	if key == "Value" then
		self:Set(value)
	else
		local message = string.format("Attempt to set unknown property '%s' on a ValueContainer. (Container: %s)", tostring(key), self._name)
		warn(message .. "\n" .. debug.traceback(nil, 2))
	end
end

ValueContainerMetatable.__tostring = function(self)
	local valueStr
	local value = self._value
	local valueType = typeof(value)
	if valueType == "table" then
		valueStr = "<table>"
	elseif valueType == "string" and #value > 40 then
		valueStr = string.format('"%s..."', string.sub(value, 1, 37))
	else
		valueStr = tostring(value)
	end
	return string.format("ValueContainer(%s): %s", self._name, valueStr)
end

function ValueContainerImpl.new<T>(initialValue: T, processFn: ((newValue: T, oldValue: T) -> T)?, name: string?, comparator: ((a: T, b: T) -> boolean)?): ValueContainer<T>
	local self = setmetatable({}, ValueContainerMetatable)
	rawset(self, "_value", initialValue)
	rawset(self, "_isDestroyed", false)
	rawset(self, "_process", processFn)
	rawset(self, "_name", name or "Unnamed")
	rawset(self, "_comparator", comparator or function(a, b) return a == b end)
	rawset(self, "Changed", Signal.new())
	rawset(self, "_connections", {})
	rawset(self, "_cleanupTasks", {})
	rawset(self, "_children", setmetatable({}, { __mode = "k" }))
	rawset(self, "_parents", setmetatable({}, {__mode = "k"}))
	rawset(self, "_isValueContainer", true)
	return (self :: any) :: ValueContainer<T>
end

function ValueContainerImpl:Get()
	return self._value
end

function ValueContainerImpl:Set(newValue: any)
	if self._isDestroyed then
		local message = string.format("Attempt to set value on a destroyed ValueContainer named '%s'.", self._name)
		warn(message .. "\n" .. debug.traceback(nil, 2))
		return
	end

	local oldValue = self._value
	if self._process then
		newValue = self._process(newValue, oldValue)
	end

	if self._comparator(oldValue, newValue) then
		return
	end

	rawset(self, "_value", newValue)
	_dirtyContainers[self] = { newValue = newValue, oldValue = oldValue }

	if not _isFiring then
		_fireDirtyContainers()
	end
end

function ValueContainerImpl:Destroy()
	if self._isDestroyed then return end
	rawset(self, "_isDestroyed", true)
	for parent in pairs(self._parents) do
		if parent._children then
			parent._children[self] = nil
		end
	end
	local childrenToDestroy = {}
	for child in pairs(self._children) do table.insert(childrenToDestroy, child) end
	for _, child in ipairs(childrenToDestroy) do
		if not child._isDestroyed then child:Destroy() end
	end
	for _, conn in ipairs(self._connections) do conn:Disconnect() end
	for _, taskFn in ipairs(self._cleanupTasks) do pcall(taskFn) end
	self.Changed:Destroy()
	_dirtyContainers[self] = nil
end

local function createDerivedContainer<T>(parents: {any}, createFn: () -> ValueContainer<T>, logicFn: (derivedValue: ValueContainer<T>) -> {ScriptConnection}, cleanupFn: (() -> ())?): ReadOnlyValueContainer<T>
	local derivedValue = createFn()
	for _, parent in ipairs(parents) do
		parent._children[derivedValue] = true
		derivedValue._parents[parent] = true
	end
	rawset(derivedValue, "_connections", logicFn(derivedValue))
	if cleanupFn then
		table.insert(derivedValue._cleanupTasks, cleanupFn)
	end
	return derivedValue:AsReadOnly()
end

function ValueContainerImpl:Map(transformFn)
	return createDerivedContainer({self}, function() return ValueContainerImpl.new(transformFn(self.Value), nil, self._name .. ":Map") end, function(derivedValue)
		return { self.Changed:Connect(function(newValue) derivedValue:Set(transformFn(newValue)) end) }
	end)
end

function ValueContainerImpl:Filter(filterFn)
	return createDerivedContainer({self}, function()
		local initialValue = self.Value
		if not filterFn(initialValue) then initialValue = nil end
		return ValueContainerImpl.new(initialValue, nil, self._name .. ":Filter")
	end, function(derivedValue)
		return { self.Changed:Connect(function(newValue) if filterFn(newValue) then derivedValue:Set(newValue) end end) }
	end)
end

function ValueContainerImpl:Debounce(delayTime)
	delayTime = delayTime or 0.1
	local debounceThread = nil
	return createDerivedContainer({self}, function() return ValueContainerImpl.new(self.Value, nil, self._name .. ":Debounce") end, function(derivedValue)
		return { self.Changed:Connect(function(newValue)
			if debounceThread then task.cancel(debounceThread) end
			debounceThread = task.delay(delayTime, function()
				debounceThread = nil
				if not derivedValue._isDestroyed then derivedValue:Set(newValue) end
			end)
		end) }
	end, function()
		if debounceThread then task.cancel(debounceThread) end
	end)
end

function ValueContainerImpl:Throttle(delayTime, options)
	delayTime = delayTime or 0.1
	options = options or { leading = true, trailing = false }
	return createDerivedContainer({self}, function() return ValueContainerImpl.new(self.Value, nil, self._name .. ":Throttle") end, function(derivedValue)
		local timeoutThread = nil
		local lastValue
		local isThrottling = false
		local hasTrailingValue = false
		local function onTimeout()
			timeoutThread = nil
			if options.trailing and hasTrailingValue then
				hasTrailingValue = false
				if not derivedValue._comparator(lastValue, derivedValue.Value) then
					derivedValue:Set(lastValue)
				end
			else
				hasTrailingValue = false
			end
			isThrottling = false
		end

		return { self.Changed:Connect(function(newValue)
			lastValue = newValue
			hasTrailingValue = true

			if not isThrottling then
				isThrottling = true
				if options.leading then
					derivedValue:Set(newValue)
				end
				timeoutThread = task.delay(delayTime, onTimeout)
			end
		end) }
	end, function()
		if timeoutThread then task.cancel(timeoutThread) end
	end)
end

function ValueContainerImpl:DistinctUntilChanged(comparator)
	local finalComparator = comparator or self._comparator

	return createDerivedContainer({self}, function() return ValueContainerImpl.new(self.Value, nil, self._name .. ":Distinct", finalComparator) end, function(derivedValue)
		return { self.Changed:Connect(function(newValue)
			if not (finalComparator(newValue, derivedValue:Get())) then
				derivedValue:Set(newValue)
			end
		end) }
	end)
end

function ValueContainerImpl:Scan(reducer, initialAccumulator)
	return createDerivedContainer({self}, function()
		return ValueContainerImpl.new(reducer(initialAccumulator, self.Value), nil, self._name .. ":Scan")
	end, function(derivedValue)
		return { self.Changed:Connect(function(newValue)
			derivedValue:Set(reducer(derivedValue:Get(), newValue))
		end) }
	end)
end

function ValueContainerImpl:Peek(callback)
	return createDerivedContainer({self}, function()
		return ValueContainerImpl.new(self.Value, nil, self._name .. ":Peek")
	end, function(derivedValue)
		local connection = self.Changed:Connect(function(newValue, oldValue)
			local success, err = pcall(callback, newValue, oldValue)
			if not success then
				warn(string.format("Error in Peek callback for %s: %s", tostring(self), tostring(err)))
			end

			derivedValue:Set(newValue)
		end)
		return { connection }
	end)
end

function ValueContainerImpl:Wait()
	return self.Changed:Wait()
end

function ValueContainerImpl:AsReadOnly()
	if self._readOnlyWrapper then return self._readOnlyWrapper end
	local originalSelf = self
	local readOnlyWrapper = {}
	rawset(readOnlyWrapper, "_isReadOnlyWrapper", true)
	rawset(readOnlyWrapper, "_source", originalSelf)
	local wrappedMethods = {}
	local readOnlyMetatable = {
		__index = function(_, key)
			if originalSelf._isDestroyed then
				if key == "Value" then return originalSelf._value end
				if key == "__tostring" then return tostring(originalSelf) end

				if ValueContainerImpl[key] then
					return function()
						warn(string.format("Attempt to call method '%s' on a destroyed ValueContainer: %s", key, originalSelf._name))
					end
				end
				return nil
			end
			if wrappedMethods[key] then return wrappedMethods[key] end
			if key == "Value" then return originalSelf._value end
			if key == "Changed" then return originalSelf.Changed end
			local method = ValueContainerImpl[key]
			if type(method) == "function" and key ~= "Set" and key ~= "new" then
				local wrapped = function(_, ...)
					local result = method(originalSelf, ...)
					if result == originalSelf then return readOnlyWrapper end

					if type(result) == "table" and result._isValueContainer then
						return result:AsReadOnly()
					end

					return result
				end
				wrappedMethods[key] = wrapped
				return wrapped
			end
			return nil
		end,
		__newindex = function(_, key, value)
			if originalSelf._isDestroyed then return end
			local message = string.format("Attempt to modify a read-only ValueContainer named '%s' (key: '%s').", originalSelf._name, tostring(key))
			warn(message .. "\n" .. debug.traceback(nil, 2))
		end,
		__tostring = function() return tostring(originalSelf) end,
	}
	local finalWrapper = (setmetatable(readOnlyWrapper, readOnlyMetatable) :: any) :: ReadOnlyValueContainer<any>
	rawset(self, "_readOnlyWrapper", finalWrapper)
	return finalWrapper
end

local ValueContainer = {}
function ValueContainer.new<T>(initialValue: T, processFn: ((newValue: T, oldValue: T) -> T)?, name: string?, comparator: ((a: T, b: T) -> boolean)?): ValueContainer<T>
	return ValueContainerImpl.new(initialValue, processFn, name, comparator)
end

function ValueContainer.Batch(callback: () -> ())
	if _isFiring then
		local success, err = pcall(callback)
		if not success then error(err) end
		return
	end
	_isFiring = true
	local success, err = pcall(callback)
	_isFiring = false
	if not success then error(err, 2) end
	_fireDirtyContainers()
end

function ValueContainer.Combine(...)
	local args = table.pack(...)
	local sources, combiner, sourceNames = {}, nil, {}
	if args.n == 2 and type(args[1]) == "table" and type(args[2]) == "function" then
		sources = args[1]
		combiner = args[2]
	else
		combiner = args[args.n]
		if typeof(combiner) ~= "function" then error("Last argument to ValueContainer.Combine must be a function.", 2) end
		for i = 1, args.n - 1 do table.insert(sources, args[i]) end
	end

	for i, source in ipairs(sources) do
		if typeof(source) ~= "table" or not source.Get then error(string.format("Argument #%d passed to ValueContainer.Combine is not a ValueContainer.", i), 2) end
		table.insert(sourceNames, source._name or "Unnamed")
	end

	local function calculateValue()
		local values = {}
		for i, source in ipairs(sources) do values[i] = source.Value end
		return combiner(unpack(values, 1, #values))
	end

	return createDerivedContainer(sources, function()
		local derivedName = "Combined(" .. table.concat(sourceNames, ", ") .. ")"
		return ValueContainerImpl.new(calculateValue(), nil, derivedName)
	end, function(derivedValue)
		local connections = {}
		local function update()
			if not derivedValue._isDestroyed then
				derivedValue:Set(calculateValue())
			end
		end

		for _, source in ipairs(sources) do
			table.insert(connections, source.Changed:Connect(update))
		end
		return connections
	end)
end

ValueContainer.deepCompare = deepCompare

return ValueContainer
