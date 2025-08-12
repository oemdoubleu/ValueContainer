# ValueContainer: A Reactive State Management Library for Luau

**ValueContainer** is a high-performance, FRP-inspired library for creating, transforming, and composing reactive state objects in Luau.

Inspired by industry standards like [Fusion](https://elttob.uk/Fusion/) and [RxJS](https://rxjs.dev/), ValueContainer is designed for building complex, data-driven systems, from UI components to intricate game mechanics, with a focus on performance and developer ergonomics.

## Core Features

*   **Declarative & Reactive:** Build systems where logic and UI react to state changes, not the other way around. Define data flows declaratively and let the library manage the updates.
*   **Rich Operator Set:** A comprehensive suite of composable operators (`Map`, `Filter`, `Combine`, `Debounce`, `Throttle`, `Scan`, etc.) allows for complex data transformations with minimal boilerplate.
*   **Automatic Memory Management:** A robust parent-child dependency graph ensures that when a source container is destroyed, all its derivatives are automatically cleaned up, preventing common memory leaks.
*   **Optimized for Performance:** Features synchronous, batched updates. Multiple changes within a single frame or transaction can be grouped using `ValueContainer.Batch()`, preventing redundant computations and intermediate state propagation.
*   **Enhanced Debuggability:** Named containers provide clear `tostring` representations, and the system includes built-in cyclic dependency detection to catch logic errors early.

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
-- The signal provides both the new and old values.
local connection = score.Changed:Connect(function(newScore, oldScore)
	print(string.format("Score transitioned from %d to %d", oldScore, newScore))
end)

-- Read the current value via the .Value property.
print("Initial score:", score.Value) --> Initial score: 0

-- Update the value using the :Set() method. This synchronously fires the .Changed signal.
score:Set(10) --> Prints: Score transitioned from 0 to 10

-- The .Value property can also be used for assignment, which is syntactic sugar for :Set().
score.Value = 25 --> Prints: Score transitioned from 10 to 25

-- Clean up the container and all associated connections.
score:Destroy()
```

### 2. Derived State with Operators

Operators create new `ReadOnlyValueContainer` instances that are derived from a source. They are updated automatically.

**`Map`**: Transforms a value into a new format.

```lua
local health = ValueContainer.new(100, nil, "Health")

-- `healthText` is a new, derived container that is passively updated.
local healthText = health:Map(function(h)
	return string.format("HP: %d/100", h)
end)

healthText.Changed:Connect(function(newText)
	print("UI text updated:", newText)
end)

print(healthText.Value) --> "HP: 100/100"
health:Set(80) --> Prints: UI text updated: HP: 80/100
```

### 3. Combining Multiple States

`ValueContainer.Combine` creates a new container derived from multiple sources. It re-computes its value whenever any of its dependencies change.

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

local c = ValueContainer.Combine(a, b, function(valA, valB)
	print("Re-computing C...")
	return valA + valB
end)

print("Initial C:", c.Value)
-- Prints: Re-computing C...
-- Prints: Initial C: 3

-- Group state changes into a single transaction.
ValueContainer.Batch(function()
	a:Set(10) -- The combiner for 'c' is NOT called yet.
	b:Set(20) -- The combiner for 'c' is NOT called yet.
end) -- All dirty containers are fired here. The combiner runs only once.

-- Prints: Re-computing C...
print("Final C:", c.Value) --> Final C: 30
```

### 5. Lifecycle and Encapsulation

**`Destroy()`**: Cascading cleanup is a core feature. Destroying a parent automatically destroys all its children (derived containers).

**`AsReadOnly()`**: To enforce proper data flow, you can expose a read-only version of a container. This prevents downstream consumers from modifying state they don't own.

```lua
-- In a service module
local PlayerService = {}
local _playerHealth = ValueContainer.new(100)

-- Expose an immutable public interface
PlayerService.Health = _playerHealth:AsReadOnly()

function PlayerService.TakeDamage(amount)
	-- Internal logic can modify the private state
	_playerHealth.Value -= amount
end

-- In a consumer script
local health = PlayerService.Health
print(health.Value) -- 100
PlayerService.TakeDamage(10)
print(health.Value) -- 90

-- This will produce a warning and have no effect.
health.Value = 1000 -- warn: Attempt to modify a read-only ValueContainer...
```

## API Reference

### `ValueContainer` Module

*   `ValueContainer.new<T>(initialValue: T, processFn?: (newValue, oldValue) -> T, name?: string, comparator?: (a, b) -> boolean): ValueContainer<T>`
    Constructs a new state container.
    -   `processFn`: An optional function to process/sanitize values before they are set.
    -   `name`: A debug name used in `tostring` and error messages.
    -   `comparator`: A function to check for equality. Defaults to `a == b`. For tables, use `ValueContainer.deepCompare`.

*   `ValueContainer.Batch(callback: () -> ())`
    Executes a callback, deferring all signal fires until the callback completes. Ensures atomicity.

*   `ValueContainer.Combine(sources...: ValueContainer, combiner: (...) -> U): ReadOnlyValueContainer<U>`
    Creates a derived container from multiple sources. An overload `(sources: {ValueContainer}, combiner: (...) -> U)` is also available.

*   `ValueContainer.deepCompare(a: any, b: any): boolean`
    A utility for performing a deep, recursive comparison of two tables.

### `ValueContainer<T>` Instance

#### Methods
*   `:Set(newValue: T)`: Updates the container's value and notifies subscribers.
*   `:Get(): T`: Returns the current value.
*   `:Destroy()`: Destroys the container, disconnects all signals, and triggers a cascading destroy on all derived children.
*   `:AsReadOnly(): ReadOnlyValueContainer<T>`: Returns a read-only proxy of the container.

#### Properties
*   `.Value: T`: A property for getting/setting the value (syntactic sugar for `:Get()`/`:Set()`).
*   `.Changed: ScriptSignal<T, T>`: A signal that fires with `(newValue, oldValue)` upon update.

#### Operators (all return a new `ReadOnlyValueContainer`)
*   `:Map<U>(transformFn: (T) -> U)`: Returns a new container with the transformed value.
*   `:Filter(filterFn: (T) -> boolean): ReadOnlyValueContainer<T?>`: Returns a new container that only updates if the value passes the predicate `filterFn`. If the initial value fails, it becomes `nil`.
*   `:Debounce(delayTime?: number)`: Delays updates until a specified time (`0.1s` default) has passed without any new values.
*   `:Throttle(delayTime?: number, options?: { leading?: boolean, trailing?: boolean })`: Limits the rate of updates.
*   `:DistinctUntilChanged(comparator?: (a: T, b: T) -> boolean)`: Prevents updates if the new value is the same as the old one, based on the provided comparator.
*   `:Scan<U>(reducer: (accumulator: U, value: T) -> U, initialAccumulator: U)`: Accumulates a value over time, similar to `Array.prototype.reduce`.
*   `:Peek(callback: (newValue: T, oldValue: T) -> ())`: Taps into the data stream to perform a side effect without modifying the value.

#### Utilities
*   `:Wait(): (T, T)`: Yields the current thread until the next `Changed` signal, returning `(newValue, oldValue)`.
