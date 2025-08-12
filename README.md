# ValueContainer: A Reactive State Management Library for Luau

**ValueContainer** is a high-performance, FRP-inspired library for creating, transforming, and composing reactive state objects in Luau.

Inspired by industry standards like [Fusion](https://elttob.uk/Fusion/) and [RxJS](https://rxjs.dev/), ValueContainer is designed for building complex, data-driven systems, from UI components to intricate game mechanics, with a focus on performance and developer ergonomics.

## Core Features

*   **Declarative & Reactive:** Build systems where logic and UI react to state changes, not the other way around. Define data flows declaratively and let the library manage the updates.
*   **Automatic Dependency Tracking:** The `ValueContainer.Computed` primitive automatically detects and subscribes to dependencies, enabling dynamic and complex data flows with minimal code.
*   **Rich Operator Set:** A comprehensive suite of composable operators (`Map`, `Select`, `Filter`, `Combine`, `Debounce`, `Throttle`, `Scan`, etc.) allows for complex data transformations.
*   **Automatic Memory Management:** A robust parent-child dependency graph and automatic cleanup via `__gc` ensure that when a source container is destroyed, all its derivatives are automatically cleaned up, preventing memory leaks.
*   **Optimized for Performance:** Features a synchronous, robust transaction system. Multiple changes can be grouped using `ValueContainer.Batch()`, preventing redundant computations.
*   **Enhanced Debuggability:** Named containers, precise cyclic dependency detection, a global error handler, and a dependency graph inspector (`ValueContainer.inspect`) help catch logic errors early.

## Why Use ValueContainer?

At its core, `ValueContainer` solves two common problems in game development: **state synchronization** and **change observation**.

In many applications, a piece of state (like a player's health) needs to be reflected in multiple places (a UI bar, a visual effect, another game system). Manually keeping these parts in sync is tedious and error-prone. Similarly, simply tracking when a variable changes often requires custom-built signals or placing the value inside a Roblox `Instance` (like a `NumberValue` or `BoolValue`).

`ValueContainer` provides a standardized, reactive pattern for this. Instead of creating `Instance` objects solely to monitor their `.Changed` event, you can create a lightweight, pure-Luau container. This is especially powerful for managing state that doesn't need to exist within the game's DataModel, keeping your project hierarchy clean and your logic self-contained.

It formalizes the concept of "a value that can change," allowing you to build systems that automatically react to updates rather than manually checking for them, leading to cleaner, more maintainable, and less error-prone code.

## Installation

1.  Place model from releases into a shared location within your project.
2.  Require the module in your script.

```lua
local ValueContainer = require(path.to.ValueContainer)
```

## Core Concepts & Usage

### 1. Creating and Updating State

A `ValueContainer` is the fundamental reactive primitive.

```lua
local ValueContainer = require(path.to.ValueContainer)

-- Create a container with an initial value and a debug name.
local score = ValueContainer.new(0, nil, "PlayerScore")

-- Subscribe to its .Changed signal to react to updates.
local connection = score.Changed:Connect(function(newScore, oldScore)
	print(string.format("Score transitioned from %d to %d", oldScore, newScore))
end)

-- Read the current value via the .Value property.
print("Initial score:", score.Value) --> Initial score: 0

-- Update the value using the :Set() method.
score:Set(10) --> Prints: Score transitioned from 0 to 10

-- The .Value property can also be used for assignment (syntactic sugar for :Set()).
score.Value = 25 --> Prints: Score transitioned from 10 to 25

score:Destroy()
```

### 2. Computed State with `Computed`

This is the most powerful feature for creating derived state. `ValueContainer.Computed` runs a function and automatically detects which containers were read during its execution, making them dependencies.

```lua
local price = ValueContainer.new(100)
local taxRate = ValueContainer.new(0.07)

-- `totalPrice` automatically depends on `price` and `taxRate`.
-- It will re-calculate if either of them changes.
local totalPrice = ValueContainer.Computed(function()
    return price.Value * (1 + taxRate.Value)
end, "TotalPrice")

print(totalPrice.Value) --> 107

price.Value = 200
print(totalPrice.Value) --> 214

taxRate.Value = 0.1
print(totalPrice.Value) --> 220
```
Operators like `:Map` and `:Select` are convenient shortcuts for `Computed`.

### 3. Combining Multiple States

`ValueContainer.Combine` is a specialized version of `Computed` for combining a list of sources.

```lua
local firstName = ValueContainer.new("John")
local lastName = ValueContainer.new("Doe")

-- The combiner function receives the current values of the sources in order.
local fullName = ValueContainer.Combine(firstName, lastName, function(fName, lName)
	return fName .. " " .. lName
end)

print(fullName.Value) --> "John Doe"
lastName:Set("Smith")
print(fullName.Value) --> "John Smith"
```

### 4. Batching for Performance

To apply multiple state changes atomically and avoid redundant intermediate computations, use `ValueContainer.Batch()`.

```lua
local a = ValueContainer.new(1)
local b = ValueContainer.new(2)

-- This computed value depends on a and b.
local c = ValueContainer.Computed(function()
	print("Re-computing C...")
	return a.Value + b.Value
end)

print("Initial C:", c.Value)
--> Prints: Re-computing C...
--> Prints: Initial C: 3

-- Group state changes into a single transaction.
ValueContainer.Batch(function()
	a:Set(10) -- The function for 'c' is NOT called yet.
	b:Set(20) -- The function for 'c' is NOT called yet.
end) -- All dirty containers are fired here. The `Computed` function runs only once.

--> Prints: Re-computing C...
print("Final C:", c.Value) --> Final C: 30
```

### 5. Lifecycle and Encapsulation

**`Destroy()`**: Cascading cleanup is a core feature. Destroying a parent automatically destroys all its children (derived containers).

**`AsReadOnly()`**: To enforce proper data flow, expose a read-only version of a container. This prevents downstream consumers from modifying state they don't own.

```lua
-- In a service module
local PlayerService = {}
local _playerHealth = ValueContainer.new(100)
PlayerService.Health = _playerHealth:AsReadOnly() -- Expose public interface

function PlayerService.TakeDamage(amount)
	_playerHealth.Value -= amount -- Modify private state
end

-- This will produce a warning and have no effect.
PlayerService.Health.Value = 1000 -- warn: Attempt to modify a read-only ValueContainer...
```

### 6. Debugging and Introspection

Use `ValueContainer.inspect()` to print a visual representation of a container's dependency graph.

```lua
local health = ValueContainer.new(100, nil, "Health")
local isLowHealth = health:Map(function(h) return h < 25 end, "IsLowHealth")
local lowHealthEffect = isLowHealth:Peek(function(isLow) print("Low health effect active:", isLow) end)

ValueContainer.inspect(health)
--[[
Inspecting dependency graph:
● ValueContainer(Health): 100
  └─ Children:
     └─ ValueContainer(IsLowHealth): false
        └─ Children:
           └─ ValueContainer(IsLowHealth:Peek): false
]]
```

## API Reference

### `ValueContainer` Module

*   `ValueContainer.new<T>(initialValue: T, processFn?: (newValue, oldValue) -> T, name?: string, comparator?: (a, b) -> boolean): ValueContainer<T>`
    Constructs a new state container.
*   `ValueContainer.Computed<T>(computeFn: () -> T, name?: string): ReadOnlyValueContainer<T>`
    Creates a derived container that automatically tracks dependencies and re-computes when they change.
*   `ValueContainer.Combine(sources...: ValueContainer, combiner: (...) -> U): ReadOnlyValueContainer<U>`
    Creates a derived container from multiple sources.
*   `ValueContainer.watch<T>(computeFn: ()->T, listenerFn: (newValue: T, oldValue: T) -> (), comparator?: (a, b) -> boolean): () -> ()`
    Runs a `listenerFn` when the result of `computeFn` changes. Returns a `disconnect` function.
*   `ValueContainer.Batch(callback: () -> ())`
    Executes a callback, deferring all signal fires until the callback completes. Ensures atomicity.
*   `ValueContainer.fromPromise<T>(promiseFn: ()->T, name?: string): ReadOnlyValueContainer<{status, value?, error?}>`
    Creates a container from a promise-like function.
*   `ValueContainer.fromSignal(rbxSignal, name?: string): ReadOnlyValueContainer<any...>`
    Creates a container from an `RBXScriptSignal`.
*   `ValueContainer.onError(handler: (err) -> ())`
    Sets a global error handler for `Computed` and `watch`.
*   `ValueContainer.inspect(container)`
    Prints the dependency graph for a given container.
*   `ValueContainer.deepCompare(a, b): boolean`
    A utility for performing a deep, recursive comparison of two tables.

### `ValueContainer<T>` Instance

#### Methods
*   `:Set(newValue: T)`: Updates the container's value.
*   `:Get(): T`: Returns the current value. Reading it inside a `Computed` function registers a dependency.
*   `:Destroy()`: Destroys the container and its children.
*   `:AsReadOnly(): ReadOnlyValueContainer<T>`: Returns a read-only proxy.

#### Properties
*   `.Value: T`: A property for getting/setting the value. Reading it inside `Computed` registers a dependency.
*   `.Changed: ScriptSignal<T, T>`: A signal that fires with `(newValue, oldValue)` upon update.

#### Operators (all return a new `ReadOnlyValueContainer`)
*   `:Map<U>(transformFn: (T) -> U)`: Returns a new container with the transformed value.
*   `:Select<U>(keyOrSelectorFn: string | number | ((T) -> U))`: Selects a sub-state from a container holding a table.
*   `:switchMap<U>(transformFn: (T) -> ValueContainer<U>)`: Maps to a container and switches to its value.
*   `:Filter(filterFn: (T) -> boolean): ReadOnlyValueContainer<T?>`: Returns a new container that only updates if the value passes the predicate.
*   `:Debounce(delayTime?: number)`: Delays updates until a specified time has passed without new values.
*   `:Throttle(delayTime?: number, options?: { leading?: boolean, trailing?: boolean })`: Limits the rate of updates.
*   `:DistinctUntilChanged(comparator?: (a: T, b: T) -> boolean)`: Prevents updates if the new value is the same as the old one.
*   `:Scan<U>(reducer: (accumulator: U, value: T) -> U, initialAccumulator: U)`: Accumulates a value over time.
*   `:Peek(callback: (newValue: T, oldValue: T) -> ())`: Taps into the data stream to perform a side effect.

#### Utilities
*   `:Wait(): (T, T)`: Yields the current thread until the next `Changed` signal, returning `(newValue, oldValue)`.
