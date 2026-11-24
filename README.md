# Elvenide's Compact Splitters

**Elvenide's Compact Splitters** is a factory ergonomics mod for **Main Sequence** that lets you walk directly over Splitters and Belt Balancers (singleplayer) and scales Splitters, Balancers, and Underground Belts to 2/3 height, built with UE4SS Lua.

It is designed to feel native to the base game—matching its exact UI style—and is **100% save-safe and removable** without adding custom items, machines, or save dependencies.

## Getting Started

- **[Getting Started & Installation Guide](docs/get-started.md)**

## Splitter, Balancer & Underground Belt Tweaks

Makes factory floors easier to navigate by letting you walk directly over Splitters and Belt Balancers, and compacts Splitters, Belt Balancers, and Underground Belts to 2/3 height.

![Walking through a compacted Belt Balancer](docs/images/splitter-balancer-tweaks.png)
*Player walking directly across a 2/3-height Belt Balancer on a factory conveyor line.*

### Features

- **Walk-Through Splitters & Belt Balancers (Single-Player Only)**:
  - Disables player collision on Splitters and Belt Balancers so you can walk across logistics lines smoothly -- matching vanilla conveyor belts -- while keeping building bounds and placement rules intact.
  - Always active in single-player and **automatically disabled in multiplayer** (both host and client) to prevent movement desync.
- **Compact 2/3 Height (Toggleable)**:
  - Scales Splitter, Belt Balancer, and Underground Belt meshes vertically to **2/3 height**, anchored cleanly to the floor.
  - Works in both single-player and multiplayer.
- **Instant & Automatic**:
  - Applies automatically to existing machines on map load and to newly built machines immediately upon construction.

## Credits

**Elvenide's Compact Splitters** is created and maintained by Elvenide. This is an unofficial mod and I'm not affiliated with Main Sequence.

> If you have questions or run into issues, feel free to reach out in #modding-guides within the [official Main Sequence Discord server](https://discord.com/invite/uy8w2pTcQE).
