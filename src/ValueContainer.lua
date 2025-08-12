--!native
--!optimize 2

--[[
	ValueContainer
	Высокопроизводительная, вдохновленная FRP, библиотека для создания, преобразования и
	композиции объектов с реактивным состоянием в Luau.
]]

local Signal = require(script.SynchronousSignal)

local errorHandler = nil
local _isBatching = false
local _dirtyContainers = {}
local _captureStack = {}
local _processedInTransaction = {}
local _currentlyFiring = {}

type ScriptConnection = { Connected: boolean, Disconnect: (self: ScriptConnection) -> () }
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
	switchMap: <U>(self: ReadOnlyValueContainer<T>, transformFn: (T) -> ReadOnlyValueContainer<U>) -> ReadOnlyValueContainer<U?>,
	Select: <U>(self: ReadOnlyValueContainer<T>, keyOrSelectorFn: string | number | ((T) -> U)) -> ReadOnlyValueContainer<U?>,
}
export type ValueContainer<T> = ReadOnlyValueContainer<T> & {
	Set: (self: ValueContainer<T>, newValue: T) -> (),
}

local ValueContainerImpl = {}
local ValueContainerMetatable = {}

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
	if _isBatching then return end

	_isBatching = true
	_processedInTransaction = {}

	while next(_dirtyContainers) do
		local containersToProcess = _dirtyContainers
		_dirtyContainers = {}

		for container, data in pairs(containersToProcess) do
			if not container._isDestroyed then
				if _processedInTransaction[container] then
					continue
				end
				_processedInTransaction[container] = true

				_currentlyFiring[container] = true
				container.Changed:Fire(data.newValue, data.oldValue)
				_currentlyFiring[container] = nil
			end
		end
	end

	_isBatching = false
	_processedInTransaction = {}
	_currentlyFiring = {}
end

function ValueContainerMetatable:__index(key)
	if key == "Value" then
		if #_captureStack > 0 then
			_captureStack[#_captureStack][self] = true
		end
		return self._value
	end
	return ValueContainerImpl[key]
end

function ValueContainerMetatable:__newindex(key, value)
	if key == "Value" then
		self:Set(value)
	else
		local message = string.format("Attempt to set unknown property '%s' on a ValueContainer. (Container: %s)", tostring(key), self._name)
		warn(message)
	end
end

function ValueContainerMetatable:__tostring()
	local value = self._value
	local valueType = typeof(value)
	local valueStr
	if valueType == "table" then
		valueStr = "<table>"
	elseif valueType == "string" and #value > 40 then
		valueStr = string.format('"%s..."', string.sub(value, 1, 37))
	else
		valueStr = tostring(value)
	end
	return string.format("ValueContainer(%s): %s", self._name, valueStr)
end

function ValueContainerMetatable:__gc()
	if not self._isDestroyed then
		self:Destroy()
	end
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
	rawset(self, "_parents", setmetatable({}, { __mode = "k" }))
	rawset(self, "_isValueContainer", true)

	return (self :: any) :: ValueContainer<T>
end

function ValueContainerImpl:Get()
	if #_captureStack > 0 then
		_captureStack[#_captureStack][self] = true
	end
	return self._value
end

function ValueContainerImpl:Set(newValue: any)
	if _currentlyFiring[self] then
		error("Cyclic dependency detected: Attempt to set a ValueContainer while it is already firing changes.", 2)
	end

	if self._isDestroyed then return end

	local oldValue = self._value
	if self._process then
		newValue = self._process(newValue, oldValue)
	end

	if self._comparator(oldValue, newValue) then
		return
	end

	rawset(self, "_value", newValue)
	_dirtyContainers[self] = { newValue = newValue, oldValue = oldValue }

	if not _isBatching then
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
	for child in pairs(self._children) do
		table.insert(childrenToDestroy, child)
	end
	for _, child in ipairs(childrenToDestroy) do
		if not child._isDestroyed then
			child:Destroy()
		end
	end

	for _, conn in ipairs(self._connections) do conn:Disconnect() end
	for _, taskFn in ipairs(self._cleanupTasks) do pcall(taskFn) end

	self.Changed:Destroy()
	_dirtyContainers[self] = nil
end

function ValueContainerImpl:Wait()
	return self.Changed:Wait()
end

function ValueContainerImpl:AsReadOnly()
	if self._readOnlyWrapper then return self._readOnlyWrapper end

	local originalSelf = self
	local readOnlyWrapper = {}
	local wrappedMethods = {}

	local readOnlyMetatable = {
		__index = function(_, key)
			if key == "_isDestroyed" then return originalSelf._isDestroyed end

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
			if key == "Value" then
				if #_captureStack > 0 then _captureStack[#_captureStack][originalSelf] = true end
				return originalSelf._value
			end
			if key == "Changed" then return originalSelf.Changed end

			local method = ValueContainerImpl[key]
			if type(method) == "function" and key ~= "Set" and key ~= "new" then
				local wrapped = function(_, ...)
					local result = method(originalSelf, ...)
					if result == originalSelf then return readOnlyWrapper end
					if type(result) == "table" and result._isValueContainer then return result:AsReadOnly() end
					return result
				end
				wrappedMethods[key] = wrapped
				return wrapped
			end
			return nil
		end,
		__newindex = function(_, key)
			if originalSelf._isDestroyed then return end
			local message = string.format("Attempt to modify a read-only ValueContainer named '%s' (key: '%s').", originalSelf._name, tostring(key))
			warn(message)
		end,
		__tostring = function() return tostring(originalSelf) end,
	}

	local finalWrapper = (setmetatable(readOnlyWrapper, readOnlyMetatable) :: any) :: ReadOnlyValueContainer<any>
	rawset(self, "_readOnlyWrapper", finalWrapper)
	return finalWrapper
end

local ValueContainer

local function createDerivedContainer<T>(parents: {any}, createFn: () -> ValueContainer<T>, logicFn: (d: ValueContainer<T>) -> {ScriptConnection}, cleanupFn: (() -> ())?): ReadOnlyValueContainer<T>
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
	local self = self
	return ValueContainer.Computed(function()
		return transformFn(self.Value)
	end, self._name .. ":Map")
end

function ValueContainerImpl:Select(keyOrSelectorFn)
	local self = self
	if type(keyOrSelectorFn) == "function" then
		return ValueContainer.Computed(function()
			local data = self.Value
			return data and keyOrSelectorFn(data)
		end, self._name .. ":SelectFn")
	else
		return ValueContainer.Computed(function()
			local data = self.Value
			return (type(data) == "table") and data[keyOrSelectorFn]
		end, self._name .. ":" .. tostring(keyOrSelectorFn))
	end
end

function ValueContainerImpl:switchMap(transformFn)
	local self = self
	return ValueContainer.Computed(function()
		local innerContainer = transformFn(self.Value)
		if not (type(innerContainer) == "table" and innerContainer._isValueContainer) then
			warn("switchMap must return a ValueContainer")
			return nil
		end
		return innerContainer.Value
	end, self._name .. ":switchMap")
end

function ValueContainerImpl:Filter(filterFn)
	return createDerivedContainer({self}, function()
		local initialValue = self.Value
		if not filterFn(initialValue) then
			initialValue = nil
		end
		return ValueContainerImpl.new(initialValue, nil, self._name .. ":Filter")
	end, function(derivedValue)
		return {
			self.Changed:Connect(function(newValue)
				if filterFn(newValue) then
					derivedValue:Set(newValue)
				end
			end)
		}
	end)
end

function ValueContainerImpl:Debounce(delayTime)
	delayTime = delayTime or 0.1
	local debounceThread = nil
	return createDerivedContainer({self}, function()
		return ValueContainerImpl.new(self.Value, nil, self._name .. ":Debounce")
	end, function(derivedValue)
		return {
			self.Changed:Connect(function(newValue)
				if debounceThread then task.cancel(debounceThread) end
				debounceThread = task.delay(delayTime, function()
					debounceThread = nil
					if not derivedValue._isDestroyed then
						derivedValue:Set(newValue)
					end
				end)
			end)
		}
	end, function()
		if debounceThread then task.cancel(debounceThread) end
	end)
end

function ValueContainerImpl:Throttle(delayTime: number?, options: ThrottleOptions?)
	delayTime = delayTime or 0.1
	local opts = options or {}
	local leading = if opts.leading ~= nil then opts.leading else true
	local trailing = if opts.trailing ~= nil then opts.trailing else false

	return createDerivedContainer({ self }, function()
		return ValueContainerImpl.new(self.Value, nil, self._name .. ":Throttle")
	end, function(derivedValue)
		local timeoutThread
		local lastValue
		local isThrottling = false
		local hasTrailingValue = false

		local function onTimeout()
			timeoutThread = nil
			if trailing and hasTrailingValue then
				hasTrailingValue = false
				if not derivedValue._comparator(lastValue, derivedValue.Value) then
					derivedValue:Set(lastValue)
				end
			else
				hasTrailingValue = false
			end
			isThrottling = false
		end

		return {
			self.Changed:Connect(function(newValue)
				lastValue = newValue
				hasTrailingValue = true
				if not isThrottling then
					isThrottling = true
					if leading then
						derivedValue:Set(newValue)
					end
					timeoutThread = task.delay(delayTime, onTimeout)
				end
			end)
		}
	end, function()
		if timeoutThread then task.cancel(timeoutThread) end
	end)
end

function ValueContainerImpl:DistinctUntilChanged(comparator)
	local finalComparator = comparator or self._comparator
	return createDerivedContainer({self}, function()
		return ValueContainerImpl.new(self.Value, nil, self._name .. ":Distinct", finalComparator)
	end, function(derivedValue)
		return {
			self.Changed:Connect(function(newValue)
				if not finalComparator(newValue, derivedValue:Get()) then
					derivedValue:Set(newValue)
				end
			end)
		}
	end)
end

function ValueContainerImpl:Scan(reducer, initialAccumulator)
	return createDerivedContainer({self}, function()
		return ValueContainerImpl.new(reducer(initialAccumulator, self.Value), nil, self._name .. ":Scan")
	end, function(derivedValue)
		return {
			self.Changed:Connect(function(newValue)
				derivedValue:Set(reducer(derivedValue:Get(), newValue))
			end)
		}
	end)
end

function ValueContainerImpl:Peek(callback)
	return createDerivedContainer({self}, function()
		return ValueContainerImpl.new(self.Value, nil, self._name .. ":Peek")
	end, function(derivedValue)
		return {
			self.Changed:Connect(function(newValue, oldValue)
				pcall(callback, newValue, oldValue)
				derivedValue:Set(newValue)
			end)
		}
	end)
end


ValueContainer = {}

function ValueContainer.onError(handler: ((...any) -> ())?)
	if handler and typeof(handler) ~= "function" then
		error("Error handler must be a function.", 2)
	end
	errorHandler = handler
end

function ValueContainer.new<T>(initialValue: T, processFn:((n:T,o:T)->T)?, name:string?, comparator:((a:T,b:T)->boolean)?): ValueContainer<T>
	return ValueContainerImpl.new(initialValue, processFn, name, comparator)
end

function ValueContainer.Batch(callback: () -> ())
	if _isBatching then
		pcall(callback)
		return
	end
	_isBatching = true
	local success, err = pcall(callback)
	_isBatching = false
	if not success then error(err, 2) end
	_fireDirtyContainers()
end

function ValueContainer.Computed<T>(computeFn: () -> T, name: string?): ReadOnlyValueContainer<T>
	local derivedName = name or "Computed"
	local derivedContainer = ValueContainerImpl.new(nil, nil, derivedName)

	local weakDerivedContainer = setmetatable({ ref = derivedContainer }, { __mode = "v" })
	local connections = {}

	local function recompute()
		local container = weakDerivedContainer.ref
		if not container or container._isDestroyed then
			for _, conn in ipairs(connections) do conn:Disconnect() end
			return
		end

		if _isBatching and _processedInTransaction[container] then return end
		if _isBatching then _processedInTransaction[container] = true end

		for parent in pairs(container._parents) do if parent._children then parent._children[container] = nil end end
		table.clear(container._parents)
		for _, conn in ipairs(connections) do conn:Disconnect() end
		table.clear(connections)

		local newDependencies = {}
		table.insert(_captureStack, newDependencies)
		local success, newValue = pcall(computeFn)
		table.remove(_captureStack)

		if not success then
			local errorMessage = `Error in ValueContainer.Computed("{derivedName}"): {tostring(newValue)}`
			if errorHandler then pcall(errorHandler, errorMessage, debug.traceback(nil, 2)) else warn(errorMessage) end
			return
		end

		for dep in pairs(newDependencies) do
			if not dep._isDestroyed then
				table.insert(connections, dep.Changed:Connect(recompute))
				dep._children[container] = true
				container._parents[dep] = true
			end
		end

		container:Set(newValue)
	end

	recompute()

	table.insert(derivedContainer._cleanupTasks, function()
		for _, conn in ipairs(connections) do conn:Disconnect() end
	end)

	return derivedContainer:AsReadOnly()
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
		if typeof(source) ~= "table" or not source._isValueContainer then
			error(string.format("Argument #%d passed to ValueContainer.Combine is not a ValueContainer.", i), 2)
		end
		table.insert(sourceNames, source._name or "Unnamed")
	end

	local combinedName = "Combined(" .. table.concat(sourceNames, ", ") .. ")"

	return ValueContainer.Computed(function()
		local values = {}
		for i, source in ipairs(sources) do
			values[i] = source.Value
		end
		return combiner(unpack(values, 1, #values))
	end, combinedName)
end

function ValueContainer.watch<T>(computeFn:()->T, listenerFn:(n:T,o:T)->(), comparator:((a:T,b:T)->boolean)?):()->()
	local lastValue, connections, isFirstRun, isDestroyed = {}, {}, true, false
	local cmp = comparator or function(a, b) return a == b end

	local function recompute()
		if isDestroyed then return end

		for _, conn in ipairs(connections) do conn:Disconnect() end
		table.clear(connections)

		local newDependencies = {}
		table.insert(_captureStack, newDependencies)
		local success, newValue = pcall(computeFn)
		table.remove(_captureStack)

		if not success then
			local errMsg = "Error in ValueContainer.watch compute function: " .. tostring(newValue)
			if errorHandler then pcall(errorHandler, errMsg, debug.traceback(nil, 2)) else warn(errMsg) end
			return
		end

		for dep in pairs(newDependencies) do
			if not dep._isDestroyed then
				table.insert(connections, dep.Changed:Connect(recompute))
			end
		end

		if isFirstRun or not cmp(newValue, lastValue) then
			local oldValue = lastValue
			lastValue, isFirstRun = newValue, false
			pcall(listenerFn, newValue, oldValue)
		end
	end

	recompute()

	return function()
		if isDestroyed then return end
		isDestroyed = true
		for _, conn in ipairs(connections) do conn:Disconnect() end
		table.clear(connections)
	end
end

function ValueContainer.fromPromise<T>(promiseFn:()->T, name:string?):ReadOnlyValueContainer<{status:string,value:T?,error:any?}>
	local container = ValueContainer.new({ status = "pending" }, nil, name or "fromPromise")
	task.spawn(function()
		local success, result = pcall(promiseFn)
		if not container._isDestroyed then
			if success then
				container:Set({ status = "resolved", value = result })
			else
				container:Set({ status = "rejected", error = result })
			end
		end
	end)
	return container:AsReadOnly()
end

function ValueContainer.fromSignal(rbxSignal: RBXScriptSignal, name:string?):ReadOnlyValueContainer<any...>
	local container = ValueContainer.new(nil, nil, name or "fromSignal")
	local connection = rbxSignal:Connect(function(...)
		container:Set({...})
	end)
	table.insert(container._cleanupTasks, function()
		connection:Disconnect()
	end)
	return container:AsReadOnly()
end

function ValueContainer.inspect(container)
	local visited = {}
	local function inspectRecursive(c, indent, prefix)
		local sourceContainer = c._source or c
		if not sourceContainer or not sourceContainer._isValueContainer then return end

		if visited[sourceContainer] then
			print(indent .. prefix .. tostring(sourceContainer) .. " (cyclic)")
			return
		end
		visited[sourceContainer] = true
		print(indent .. prefix .. tostring(sourceContainer))

		local parents, children = {}, {}
		for parent in pairs(sourceContainer._parents) do table.insert(parents, parent) end
		if #parents > 0 then
			print(indent .. "  ├─ Parents:")
			for i, parent in ipairs(parents) do
				inspectRecursive(parent, indent .. "  │  ", i == #parents and "└─ " or "├─ ")
			end
		end

		for child in pairs(sourceContainer._children) do table.insert(children, child) end
		if #children > 0 then
			print(indent .. "  └─ Children:")
			for i, child in ipairs(children) do
				inspectRecursive(child, indent .. "     ", i == #children and "└─ " or "├─ ")
			end
		end
	end
	print("Inspecting dependency graph:")
	inspectRecursive(container, "", "● ")
end

ValueContainer.deepCompare = deepCompare

return ValueContainer
