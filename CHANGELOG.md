# 23.0.0
## Additions
- Added HScript sandboxing
    - Blocks implicit class access by dotted string (`new sys.io.File`, `Sys.systemName`, `import sys.FileSystem;`, `sys.io.File.getContent()`, `using SomeClass;`) by category via `hscriptBlockedLibs`/`HScriptSandbox.HScriptLib`, with `hscriptExtraBlockedClasses`/`hscriptExtraAllowedClasses` for explicit overrides
    - Bounds a sandboxed script with `hscriptInstructionLimit`/`hscriptTimeLimitMs` so a runaway loop or unbounded recursion can't hang the host
    - Classes set only via preset (e.g. `Sys` under `REGULAR`) are not reachable in a sandboxed script because they are not set, they must go through `hscriptExtraAllowedClasses` or an explicit `set()`
- Added `interpCompilesFunctionCode` (and `SScript.defaultCompile` to set the default for new instances). When enabled, a script function's body is compiled first time that function is called, then reused on every subsequent call, trading a one-time build cost for a cheaper path on repeated calls
- (**C++ ONLY**) Added `interpCachesCompiledLocals`; in compiled functions, locals are now cached and used instead of re-evaluating local variables, cached local variable changes when a local variable changes 
- Special Object now supports anonymous structures
- Added support for multiple typed `catch` clauses on a single `try` (e.g. `try { ... } catch(e:CustomException) { ... } catch(e:String) { ... } catch(e) { ... }`), matched in order against the thrown value's type
- Added enum pattern matching in `switch`, e.g. `case SomeCtor(x):` now binds `x` as a new local from the enum's constructor arguments instead of comparing it
- Added `variablesToSet` to the constructor, which allows scripts to have custom variables when creating a script
- Added `cast expr` and `cast(expr, Type)` support
- Added `untyped` support 
- Added `SScript.setEnum()`, to set Enums into scripts easily

## Changes
- (**C++ ONLY**) `+`, `%`, `++` and `--` on Dynamic values now go through native fast paths
- `SScript.defaultImprovedField` now defaults to `true`, again
- Removed every unnecessary checks in `set()`, so it runs faster
- Error messages and traces, if no file is present, now use the SScript instance turned into a String as their origin (unless `customOrigin` is set)
- Completely reworked `debugTraces`
- String interpolation now caches the parsed expression for each unique `${...}` segment instead of re-parsing it on every evaluation, so it's more optimized
- `remove()` and `clear()` now also clean up local variables
- `traceError` is now `public` and `dynamic`, so it can be overridden
- `new Map()` inside a script is now special-cased to always return a `Map<Dynamic, Dynamic>`

## Fixes
- Fixed string interpolations reporting errors incorrectly
- Fixed optional arguments not working as intended
- Fixed `using` not working as intended
- Fixed `get()` return an SScript instance instead of null when the script is inactive
- Fixed `returnValue` not working as expected
- Fixed `??`, `??=`, and `?.` not allowing further chained operations on their result (e.g. `a ?? b.c`, `a?.b()`)
- Fixed multiple bugs with null coalescing
- Fixed a bug in `destroy()`

## Removals
- `notAllowedClasses` has now no effect, due to sandboxing being added

# 22.4.1
## Additions
- Added `defaultTraces`

## Changes
- Changed some of the errors so they are logged, not thrown

# 22.4.0
## Additions
- Added `setByPackage`, which sets multiple classes in a package (not available if `DISABLED_MACRO_SUPERLATIVE` is defined)
- Added `className` argument to `call`, to improve backward compatibility

## Changes
- Reworked `traces`, if `true`, logs will now show the SScript instance the error came from, the error itself, the called function's name and the arguments passed to it
- `toString` method is now public and modified, it now displays the script's file name (or its `ID` if the script was created without a file)
- In `set`, `setClass`, and `setClassString`, the setAsFinal argument now defaults to `null`. When the object being set is a class and `setAsFinal` is `null`, `setAsFinal` will automatically be set to `true`

## Fixes
- Fixed multiple typos across the documentation

## Removals
- Removed dead code that supposedly added support for Haxe 2
    - SScript doesn't support Haxe 2 or 3

# 22.3.1
## Fixes
- Fixed C# compilation error (error CS1002)
- Optimized `for` loops

# 22.3.0
## Additions
- Added Static Extensions, with some limitations 

## Changes
- `presetter` is replaced with `presetMode`

## Fixes
- Some micro optimizations

# 22.2.2
## Fixes
- You can now edit the properties of special objects in scripts

# 22.2.1
## Fixes
- Fixed the `Special object cannot be an enum constructor` error showing up even if the special object is not an enum constructor

# 22.2.0
## Additions
- Special objects now supports Classes and Enums
- Added `removeSpecialObject`

## Changes
- Special object system has been highly optimized

# 22.1.2
## Fixes
- Fixed backward compatibility
- Fixed grammar issues in README

# 22.1.1
## Additions
- Added `FULL` as a Preset mode
- Added more backward compatibility
- You can now use `in` while importing with alias

## Changes
- Default preset mode is now `REGULAR`

# 22.1.0
## Additions
- Added partial backward compatibility for older SScript versions

## Fixes
- Optimized a lot of code
- Fixed freezing issues
- Fixed grammar issues

## Changes
- `unset` has been renamed to `remove`
- The improved field system is now disabled by default

## Removals
- Removed `fileName` from function calls; use `scriptFile` instead

# 22.0.1
## Fixes
- Fixed `Unexpected <eof>` error

# 22.0.0
## Removals
- Removed all broken features and unnecessary restrictions to avoid confusion and future headaches
    - Classes
    - Enum abstracts
    - `public`, `static`, and `private` keywords
    - Parsing that was too strict for its own good

## Additions
- Added `lastFunctionCall`, which stores the most recent successful (or unsuccessful) function call

## Fixes
- Fixed string interpolation

## Changes
- Moved SScript files to `hscript` and HScript files to `hscriptBase`
- Removed every mention of "Tea"; SScript instances are now referred to as "scripts"
- `defaultFun` now accepts arguments 

**Note**: SScript's history and versioning system is a mess (honestly the entire library is), so I am hoping to fix it in this update.
Everything that made SScript bad and unusable is removed and SScript goes back to its core, being a HScript fork.
From now on, SScript will use the Semantic Versioning system properly and I will fix any bugs I find.