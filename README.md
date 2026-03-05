# clarion-import-and-build

A PowerShell script that imports Clarion `.app` files from version-controlled APV folders and compiles the solution using MSBuild — without regenerating CLW source.

Designed for teams that commit their generated CLW source to source control and only need to re-import app changes and compile.

---

## How it works

### Step 1 — Import (optional)

For each project in the solution, the script:

1. Reads `up_vcSettings.ini` in the solution folder to find the UpperPark VC output folder (the `OutputFolder` key)
2. Calls **ClaInterface** (`BUILDTXA`) to assemble a `.upstxa` file from the APV folder for that app
3. Calls **ClarionCL `/ai`** to import the TXA into the `.app` file
4. Cleans up the temporary `.upstxa` file

> If `-SkipImport` is specified, this step is skipped entirely.

### Step 2 — Build

1. Parses the `.sln` file to find all `.cwproj` projects
2. Reads each `.cwproj` to extract its GUID and `<ProjectReference>` dependencies
3. Performs a topological sort so libraries are compiled before the executables that depend on them
4. Compiles each project with **MSBuild** (`/t:Rebuild`) in dependency order
5. Writes per-project build logs to `build-output\` in the solution folder
6. Copies failed project logs to `build-output\failed\` for easy inspection

---

## Requirements

| Requirement | Notes |
|---|---|
| Windows PowerShell 5.1+ or PowerShell 7+ | |
| Clarion 10 with `ClarionCL.exe` | Pass path via `-ClarionPath` |
| .NET Framework 4 (MSBuild) | Ships with Windows — `C:\Windows\Microsoft.NET\Framework\v4.0.30319\` |
| UpperPark ClaInterface | Required for import step only — `C:\Program Files (x86)\UpperParkSolutions\claInterface\ClaInterface.exe` |
| `up_vcSettings.ini` in solution folder | Written by UpperPark VC Interface — must contain `OutputFolder=` |
| `ClarionProperties.xml` in ConfigDir | Defaults to `%AppData%\SoftVelocity\Clarion\10.0` |

---

## Usage

Run from your solution directory or pass `-SolutionPath` explicitly.

```powershell
# Import APV changes then build (Release)
.\import-and-build.ps1 -ClarionPath "C:\Clarion10"

# Build only — skip import (CLWs already up to date)
.\import-and-build.ps1 -ClarionPath "C:\Clarion10" -SkipImport

# Debug build, keep going on errors
.\import-and-build.ps1 -ClarionPath "C:\Clarion10" -Configuration Debug -StopOnError $false

# Explicit solution path and custom Clarion config dir
.\import-and-build.ps1 -ClarionPath "C:\Clarion10" `
                        -SolutionPath "C:\Dev\MyApp\MyApp.sln" `
                        -ConfigDir "C:\MyClarionConfig"
```

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-ClarionPath` | String | *(required)* | Path to Clarion installation folder containing `bin\ClarionCL.exe` |
| `-SolutionPath` | String | `accura.sln` | Path to the `.sln` file |
| `-Configuration` | String | `Release` | `Debug` or `Release` |
| `-ConfigDir` | String | `%AppData%\SoftVelocity\Clarion\10.0` | Folder containing `ClarionProperties.xml` |
| `-SkipImport` | Switch | `$false` | Skip Step 1 and go straight to MSBuild |
| `-StopOnError` | Bool | `$true` | Stop on the first build failure (critical projects `classes` and `data` always stop) |

---

## Output

```
<solution-folder>\
  build-output\
    build_<project>.log     # MSBuild log for every project
    failed\
      build_<project>.log   # Logs for failed projects only
```

---

## License

MIT
