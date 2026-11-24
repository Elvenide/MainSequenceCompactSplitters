# Getting Started with Elvenide's Compact Splitters

> [!NOTE]
> **Main Sequence vs. Demo**: **Elvenide's Compact Splitters** is tested and working in the full version of **Main Sequence**. While it may work in the **Main Sequence Demo**, it is developed exclusively for the full game and using it in the demo is not recommended.

**Elvenide's Compact Splitters** is a standalone, client-side UE4SS Lua mod for **Main Sequence**. It is designed to be 100% save-safe and cleanly removable at any time without affecting your save files.

## Prerequisites

- **Main Sequence** installed via Steam (default: `C:\Program Files (x86)\Steam\steamapps\common\Main Sequence`)
- **UE4SS v4.0.0+** (Unreal Engine 5.7 compatible)

## Installation

Choose either **MSCoreManager** (recommended) or **Manual UE4SS Installation** below.

### Option 1: Install with MSCoreManager (Recommended)

1. **Install MSCoreManager & UE4SS** (if you haven't already):
   - Download the latest **MSCoreManager** executable by **xxalex3xx97** from [github.com/xxalex3xx97/MSCore/releases/latest](https://github.com/xxalex3xx97/MSCore/releases/latest).
   - Run `MSCoreManager` and follow its prompts to automatically install and configure UE4SS for *Main Sequence*.
2. **Install Elvenide's Compact Splitters**:
   - Open **MSCoreManager** and click **Add mod...**.
   - Paste in `https://github.com/Elvenide/MainSequenceCompactSplitters` to install automatically from GitHub Releases (MSCoreManager uses `manifest.txt` and **$(System.Collections.Hashtable.ZipBase)-v<version>.zip**).
   - *(Alternatively, if installing from a local archive in MSCoreManager, download **$(System.Collections.Hashtable.ZipBase)-v<version>.zip** from [github.com/Elvenide/MainSequenceCompactSplitters/releases](https://github.com/Elvenide/MainSequenceCompactSplitters/releases).)*
3. **Launch Main Sequence**:
   - **Elvenide's Compact Splitters** activates automatically once loaded—no additional in-game configuration required.

### Option 2: Manual UE4SS Installation

1. **Install UE4SS** (if you haven't already):
   - Download the latest UE4SS release (`UE4SS_v4.0.0.zip` or newer) from the [RE-UE4SS Releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases).
   - Extract the contents into your game's `Win64` folder:
     ```
     Main Sequence\Windows\MainSequence\Binaries\Win64\
     ```
     (You should see `dwmapi.dll` and the `ue4ss\` folder inside `Binaries\Win64\`.)
   - Open `ue4ss\UE4SS-settings.ini` and set the engine version override for Main Sequence:
     ```ini
     [EngineVersionOverride]
     MajorVersion = 5
     MinorVersion = 7
     ```
2. **Install Elvenide's Compact Splitters**:
   - Download **$(System.Collections.Hashtable.ZipBase)-v<version>.zip** from [github.com/Elvenide/MainSequenceCompactSplitters/releases](https://github.com/Elvenide/MainSequenceCompactSplitters/releases).
   - Open the zip, navigate into its `Mods\` folder, and copy the `MainSequenceCompactSplitters` folder into:
     ```
     Main Sequence\Windows\MainSequence\Binaries\Win64\ue4ss\Mods\MainSequenceCompactSplitters\
     ```
     *(You can safely leave `mscore.mod` inside `MainSequenceCompactSplitters\`—UE4SS ignores it.)*
   - Ensure `MainSequenceCompactSplitters\enabled.txt` exists (an empty file is fine).
   - Open `ue4ss\Mods\mods.txt` and add `MainSequenceCompactSplitters : 1` **above** `Keybinds : 1`:
     ```ini
     MainSequenceCompactSplitters : 1

     ; Built-in keybinds, do not move up!
     Keybinds : 1
     ```
3. **Launch Main Sequence**:
   - **Elvenide's Compact Splitters** activates automatically once loaded—no additional in-game configuration required.

## Uninstalling

- Remove or rename `MainSequenceCompactSplitters\enabled.txt` (or delete the `MainSequenceCompactSplitters` folder and remove `MainSequenceCompactSplitters : 1` from `mods.txt`).
- Your saves remain completely intact with no missing-mod dependencies.