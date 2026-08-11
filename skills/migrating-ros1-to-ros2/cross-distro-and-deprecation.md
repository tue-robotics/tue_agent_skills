# Cross-distro compatibility, and when to deprecate instead of port

## Guard on the dependency's own version, not on ROS_DISTRO

If a package must build across multiple ROS2 distros (e.g. Humble + Jazzy + Rolling) at once, don't branch on the distro — branch on the specific dependency's own version macro. Distro version and a given library's version don't move in lockstep.

```cpp
// tue_config, commit 96f74e1
#include <ament_index_cpp/version.h>
#if AMENT_INDEX_CPP_VERSION_GTE(1, 13, 0)
#include <ament_index_cpp/get_package_share_path.hpp>
#else
#include <ament_index_cpp/get_package_share_directory.hpp>
#endif
...
#if AMENT_INDEX_CPP_VERSION_GTE(1, 13, 0)
    result = ament_index_cpp::get_package_share_path(args[1]).string();
#else
    result = ament_index_cpp::get_package_share_directory(args[1]);
#endif
```
Rationale from the commit message: the single-argument `get_package_share_directory` is deprecated starting ament_index_cpp 1.13 (Rolling) and its header is removed in 1.14; `get_package_share_path` (returns `std::filesystem::path`, same `PackageNotFoundError` behavior) is the replacement, but isn't available pre-1.13 (Humble/Jazzy) — so guard on `AMENT_INDEX_CPP_VERSION_GTE`, not on which distro you think you're on.

## Header .h → .hpp renames across distros

Several ROS2 packages renamed public headers from `.h` to `.hpp` at different times across distros. If you need to support more than one distro, guard with `__has_include`, not a distro macro:

```cpp
#if __has_include(<diagnostic_updater/diagnostic_updater.hpp>)
#include <diagnostic_updater/diagnostic_updater.hpp>
#else
#include <diagnostic_updater/diagnostic_updater.h>
#endif
```
Same pattern recurs for `cv_bridge/cv_bridge.hpp`, `tf2_geometry_msgs/tf2_geometry_msgs.hpp`, and others — check each dependency individually, don't assume they all renamed on the same distro.

For a QoS-type overload difference where `__has_include` doesn't apply (the header exists on both sides but the function signature differs), use SFINAE instead — see the `message_filters::Subscriber::subscribe()` example in [nodelets-and-launch.md](nodelets-and-launch.md).

## Don't chase clang-tidy "modernize" suggestions past your oldest supported distro's compiler

```cpp
// Breaks on Humble/Jazzy's toolchain (attempted C++20)
return std::ranges::any_of(shapes_.begin(), shapes_.end(), [&p](const auto& shape) { ... });

// C++11-compatible, with NOLINT to keep clang-tidy quiet
return std::any_of(shapes_.begin(), shapes_.end(),  // NOLINT(modernize-use-ranges)
                    [&p](const auto& shape) { ... });
```
Same for `std::cmp_greater_equal` (C++20, reverted to explicit cast + `NOLINT(modernize-use-integer-sign-comparison)`) and `set::contains` (C++20, reverted to `find() != end()`).

(`geolib2`, commit `c587458`, from the commit message: "Previous changes attempted to use C++20 features that aren't available in older ROS distros. This fix reverts to C++11-compatible code and uses NOLINT comments to suppress clang-tidy modernization suggestions that can't be satisfied across all target distros.")

If your shared lint config (e.g. `tue_lint_config`'s `.clang-tidy`, applied repo-wide) flags a modernization the oldest distro's compiler can't build, the fix is a deliberate revert + `NOLINT` annotation — not a conditional-compilation `#ifdef` per feature. Conditional compilation for individual C++ standard features gets unmaintainable fast; picking the lowest common standard and annotating the lint exception doesn't.

## Deciding to deprecate instead of port

Not every package should be ported. `tue_filesystem` (a `boost::filesystem`-alike path/crawler wrapper) was **not** ported to ROS2 — the maintainers reverted an attempted port and shipped a pure documentation deprecation instead, because C++17's `std::filesystem` now covers the same job:

```markdown
## ROS2 migration

This package is obsolete. It can be fully replaced by using the `std::filesystem`
in C++17 and newer. See the [migration guide](doc/migrate_to_std_filesystem.md).
```
(`tue_filesystem`, commit `68c4554`)

Signs a package is a deprecation candidate rather than a port candidate:
- It's a small helper/wrapper whose entire job is now covered by the C++17/20 standard library (filesystem, optional, variant, etc.) or a ROS2-native primitive.
- It has few or no message/interface dependents that would need a parallel split.
- Porting it would just be reproducing stdlib functionality with an extra ROS dependency layer.

If you deprecate, write a downstream migration doc, not just a "removed" note. `tue_filesystem/doc/migrate_to_std_filesystem.md` is a good template shape:
1. Preconditions (verify C++17, verify the standard library ships `<filesystem>` without extra link flags on your minimum supported compiler).
2. Usage discovery: concrete `grep` commands consumers can run against their own codebase to find call sites.
3. Exact API mapping table, old type/method → new type/method, **with quirks called out** (e.g. `tue::filesystem::Path::parentPath()` returned `"."` for an empty parent; `std::filesystem::path::parent_path()` returns an empty path instead — callers relying on the `"."` behavior need a patch, not just a rename).
4. A full code skeleton for anything with no 1:1 stdlib equivalent (their `Crawler` class → a skeleton reproducing all of its toggles via `std::filesystem::recursive_directory_iterator`).
5. The trivial package.xml/CMakeLists.txt side of it: just remove the dependency, no replacement `find_package()` needed for stdlib features on GCC≥9/Clang≥9.
6. Validation commands and a review checklist for the consumer to run before merging their migration.

On the consumer side, this looks like a dependency simply disappearing with nothing replacing it — `ed`'s own migration dropped `<depend>tue_filesystem</depend>` (and the matching `find_package`/`ament_export_dependencies` entries) with no substitute, because the code switched to plain `#include <filesystem>` internally.

## Packages needing little to no porting

A package with no ROS message dependencies and no roscpp API usage beyond simple conversions (`geolib2`: only consumes `geometry_msgs`/`sensor_msgs`/`shape_msgs`/`tf2`/`image_geometry`, generates nothing) may already be nearly done once package.xml/CMakeLists.txt are in ament_cmake form. Don't assume such a package needs the `_interfaces` split treatment (§ package-xml-and-cmake.md) just because sibling packages in the same org needed it — check whether it actually generates messages first.
