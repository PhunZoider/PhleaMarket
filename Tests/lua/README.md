# Lua tests

Offline tests for the parts of Phlea Market that can be exercised without the
game. The first of them, and the reason this folder exists before any of the
mod does, is the item snapshot: turning a real `InventoryItem` into a table that
survives a server restart and turning it back again. Get that wrong and the
machine launders damaged gear into new gear, so it is worth pinning down
somewhere a mistake is cheap.

Nothing here is deployed. `deploy.cmd` copies only `Contents\mods\PhleaMarket`,
and removes `Tests` from the workshop staging folders outright.

## Running

```
Tests\lua\run.cmd
```

It needs LuaJIT, which is Lua 5.1:

```
winget install --id DEVCOM.LuaJIT --source winget
```

`run.cmd` looks for `luajit` on PATH and then in
`%LOCALAPPDATA%\Programs\LuaJIT\bin`, and runs every `test_*.lua` beside it.
Individual suites run on their own too:

```
luajit Tests\lua\test_item_snapshot.lua
```

## Why LuaJIT and not Lua 5.4

Project Zomboid is Lua 5.1, and the difference is not cosmetic: a suite that
passed under 5.4 would be testing code the game cannot run. `DEVCOM.Lua` in
winget only packages 5.4, hence LuaJIT.

## What the harness does

`harness.lua` is PhunMart2's, copied rather than shared. Two repositories that
reach into each other for a test harness are two repositories that cannot be
checked out independently, which is the whole point of this one being separate.
If it gains something worth having here, copy that across too.

It makes stock Lua resemble the B42.20.4 runtime in two halves:

**Taking things away.** B42.20.4 removed `loadstring`, `load` and `loadfile`.
The harness replaces them with functions that raise, so code reaching for them
fails here rather than working on a dev machine and being `nil` in the game.
`next` goes the same way, since mod code does not get it either. `pairs` and
`ipairs` keep working: they reach `next` below the C boundary.

**Standing things in.** An in-memory `getFileReader` / `getFileWriter` pair over
a table of strings, plus the few engine globals the modules touch on load:
`Events`, `isClient`, `ModData`, `SandboxVars`.

Anything loaded through `require` has to be loaded *before* `harness.strip()`,
because `require` needs the loader machinery that strip takes away.

## Testing against PhunMart

Phlea Market calls into `PhunMart` for the wallet, the compiler and the
registries. A suite that needs those adds the sibling checkout to `package.path`
rather than vendoring a copy:

```lua
local phunmart = root .. "/../PhunMart2/Contents/mods/PhunMart2/common/media/lua/shared"
package.path = phunmart .. "/?.lua;" .. package.path
```

That is a developer-machine assumption and the only one in here, so a suite that
makes it should say so at the top and skip cleanly when the path is missing,
rather than failing in a way that looks like a broken test.
