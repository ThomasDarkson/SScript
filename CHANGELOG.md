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