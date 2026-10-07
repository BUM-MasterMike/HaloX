# DSOAL (DirectSound → OpenAL Soft) — tested Win32 build

This folder contains the exact DSOAL Win32 binaries that are bundled into
HaloX by default. They are the build that is known to run stable and fluid
inside HaloX (Wine/WineskinCX 23.7.1): no `msvcp140.dll.?_Throw_Cpp_error`
abort, no "The game has encountered a segmentation fault" dialog, working
server join.

These files are **byte-identical** to the ones used in the known-good
reference wrapper (Halo Combat Evolved.app, DSOAL overlay):

| File            | Size    | MD5                              |
|-----------------|---------|----------------------------------|
| `dsound.dll`    | 249870  | `2c000de0cbdc5eb34a5a3c798bda6221` |
| `dsoal-aldrv.dll` | 2433550 | `a28813c4e90f58a10b84f44950cc8fd8` |
| `alsoft.ini`    | 15865   | `dd1e390fa0d1d63835dfe47dd29a44d6` |

## Provenance / version

- **DSOAL** upstream: https://github.com/kcat/dsoal
  - Commit `d9fed51a` ("Make sure extension functions are properly aligned on
    32-bit", Chris Robinson, 2023-04-13). The commit hash is embedded in the
    binary string table.
  - Build era: April 2023.
- **OpenAL Soft** (bundled inside `dsoal-aldrv.dll`): **1.23.1**
  (string `1.1 ALSOFT 1.23.1`).

> Note: newer DSOAL (e.g. the GitHub `latest-master` daily builds) use a
> modern C++ runtime whose exception path calls `msvcp140.dll._Throw_Cpp_error`.
> Wine's builtin `msvcp140` does not implement that export, which aborts the
> game and surfaces as Halo's "Segmentation fault" watson dialog.
> The April 2023 build does not hit that path and is the working default.

## Why these files are checked in

- The exact April 2023 binaries are no longer published by DSOAL CI
  (the GitHub `archive` release only holds newer rebuilds).
- They are the only build verified to work in HaloX.
- Bundling them makes the build deterministic: no runtime download of a
  moving "latest" target.

## License

- `dsound.dll` — **DSOAL**, LGPL-2.1 (copyright Chris Robinson/kcat et al.).
  Source: https://github.com/kcat/dsoal
- `dsoal-aldrv.dll` — **OpenAL Soft** (renamed), LGPL-2.1.
  Source: https://github.com/kcat/openal-soft (release 1.23.1)
- `alsoft.ini` — OpenAL Soft configuration text.

Both projects are licensed under the GNU Lesser General Public License v2.1.
See `LICENSE.LGPL-2.1` in this directory. The full license text is also
available at https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt.

The binaries are distributed unmodified and dynamically loaded by the game;
they are separate works and do not make HaloX a derivative work.