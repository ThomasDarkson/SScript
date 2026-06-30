## 22.4.1
## Additions
- Added `defaultTraces`

## Changes
- Changed some of the errors so they are logged, not thrown

## 22.4.0
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

## 22.3.1
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