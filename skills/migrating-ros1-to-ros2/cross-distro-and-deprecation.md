# Cross-distro compatibility, and when to deprecate instead of port

## Build-system commands get removed too, and there is no guard for it

Version guards (below) cover C++ APIs. A CMake command that a newer distro deletes cannot be guarded
the same way — there is no macro to test and no fallback worth writing. The only fix is to stop using
it everywhere, including on the older distros that still have it.

The live case: **`ament_target_dependencies` does not exist on Rolling.** Measured 2026-08-18 —
`/opt/ros/jazzy/share/ament_cmake_target_dependencies/cmake/` contains
`ament_target_dependencies.cmake`; the Rolling copy of that directory does not. A CMakeLists using
it configures cleanly on Jazzy and fails on Rolling with:

```
CMake Error at CMakeLists.txt:8 (ament_target_dependencies):
  Unknown CMake command "ament_target_dependencies".
```

Do not wrap it in `if(COMMAND ament_target_dependencies)` — that just hides the divergence and keeps
two link paths alive. `target_link_libraries` with namespaced targets works on every distro, so
convert unconditionally; see [package-xml-and-cmake.md](package-xml-and-cmake.md#never-use-ament_target_dependencies)
for the per-dependency mapping.

When you touch a CMakeLists during a migration, grep the whole repo rather than only the file you
came for:

```bash
grep -rn "ament_target_dependencies" --include=CMakeLists.txt --include=*.cmake .
```

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
Rationale from the commit message: the single-argument `get_package_share_directory` is deprecated starting ament_index_cpp 1.13 (Rolling) and its header is removed in 1.14; `get_package_share_path` (returns `std::filesystem::path`, same `PackageNotFoundError` behavior) is the replacement.

**Check whether you still need the guard before copying it.** That `#if` was written for
Humble. Measured 2026-08-18: Jazzy ships ament_index_cpp **1.8.4** and Rolling **1.13.3**,
and `get_package_share_path` is declared *identically* on both — same signature, same
return type, same throws — so a Jazzy+Rolling package just calls it:

```cpp
#include <ament_index_cpp/get_package_share_path.hpp>
std::string const pkg_path = ament_index_cpp::get_package_share_path(pkg).string();
```

The replacement being newer than the deprecation does not mean it is unavailable on the
older distro; back-ported additions are common. Compile a one-line call on your oldest
target under `-Werror=deprecated-declarations` before reaching for `#if`.
(`ed`, commit `c941f92` — this was the last rolling CI failure, reported as
`clang-diagnostic-deprecated-declarations`, which a zero-findings clang-tidy bar fails on.)

## uint8[] message fields are rosidl::Buffer on Rolling, std::vector elsewhere

Rolling changed the C++ type rosidl generates for a `uint8[]` field from
`std::vector<uint8_t>` to `rosidl::Buffer<uint8_t>`. Anything that passed the field
straight to an API expecting a `std::vector` stops compiling — on Rolling only:

```
error: no matching function for call to 'imdecode(const ...::Binary_<...>::_data_type&, cv::ImreadModes)'
note: no known conversion for argument 1 from
  'const rosidl::Buffer<unsigned char, std::allocator<unsigned char>>' to 'cv::InputArray'
```

Check the generated header rather than guessing which fields are affected — measured
2026-08-18, **only `uint8[]` moved**:

| Field | Jazzy | Rolling |
|---|---|---|
| `uint8[]` | `std::vector<uint8_t>` | **`rosidl::Buffer<uint8_t>`** |
| `byte[]`, `int32[]`, `float64[]` | `std::vector<T>` | `std::vector<T>` |
| `string[]`, nested `Msg[]` | `std::vector<T>` | `std::vector<T>` |

```bash
sed -n '/_<field>_type =/,+2p' /opt/ros/$ROS_DISTRO/include/<pkg>/<pkg>/msg/detail/<msg>__struct.hpp
```

`rosidl::Buffer` is contiguous, exposes `std::vector`'s own `iterator`/`const_iterator`
types, and is assignable *from* a `std::vector` — so copying through a vector at the
boundary compiles on every distro, with no `#if` and no `__has_include`:

```cpp
// reading a field into an API that wants std::vector
std::vector<unsigned char> const buf(msg->data.begin(), msg->data.end());
cv::Mat const image = cv::imdecode(buf, cv::IMREAD_UNCHANGED);

// writing a field from an API that fills a std::vector&
std::vector<unsigned char> out;
tue::serialization::convert(archive, out);
msg->data = std::move(out);
```

Do not reach for `const_cast` plus a `cv::Mat` view to dodge the copy: it buys one
memcpy back and costs a `NOLINT` for `cppcoreguidelines-pro-type-const-cast`.

The other fix worth considering is templating the API that only speaks
`std::vector` — `tue::serialization::convert` is declared solely in those terms, which
is why `ed` has to copy at all. That is the right change if you own the API; copying at
the call site is the right change if you do not.
(`ed`, commit `e4a69ba` — five call sites on `tue_serialization_interfaces/Binary.data`)

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

## Pick the standard from your oldest supported distro, then take everything it gives you

The C++ standard a package can use is set by the **oldest distro still in its CI matrix**,
not by preference. So this decision has two halves, and skipping either one is a mistake:

**While an old distro is in the matrix, don't chase clang-tidy past its compiler.**

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

**When that old distro leaves the matrix, raise the standard and revisit those NOLINTs.**
The suppressions above were bought to satisfy a compiler that is no longer a target;
leaving them is leaving the package on an older dialect for no reason. Dropping Humble
left `ed` with Jazzy and rolling-u24, both Ubuntu 24.04 / GCC 13, so C++20 became free —
matching `rgbd`, which was already on 20:

```cmake
if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 20)
endif()
set(CMAKE_CXX_STANDARD_REQUIRED ON)   # easy to forget; without it CMake silently decays
```

Expect the bill to arrive as lint findings, not compile errors: raising `ed` to 20 turned on
four checks that only fire in C++20 mode, 55 findings over 28 sites. That is the point —
they were latent all along.

| Check | Rewrite |
|---|---|
| `readability-container-contains` | `find(k) != end()` → `contains(k)` |
| `modernize-use-ranges` | `std::sort(b, e)` → `std::ranges::sort(r)` |
| `modernize-use-starts-ends-with` | `substr(0, n) == p` → `starts_with(p)` |
| `modernize-use-std-numbers` | `3.14159...` → `std::numbers::pi`, `(1 + sqrt(5)) / 2` → `std::numbers::phi` |

`clang-tidy --fix` handles most of it, but **review the diff** — on `ed` it got four things
wrong or incomplete:

- **`std::ranges::unique`'s fix-it does not compile.** It returns a *subrange*, so the
  erase-the-tail idiom needs both of its ends:
  ```cpp
  std::ranges::sort(paths);
  auto const duplicates = std::ranges::unique(paths);   // NOT erase(unique(paths), end())
  paths.erase(duplicates.begin(), duplicates.end());
  ```
- `starts_with` makes hand-written length guards (`id.size() >= prefix.size() &&`)
  redundant; the tool leaves them in place.
- It inserts `<algorithm>` wherever it happens to land, including *inside* a
  `#if __has_include(...)` branch, and will add a second copy if one already exists.
- A local `constexpr double PI` that existed only because `M_PI` is not guaranteed by
  `<cmath>` should be deleted, not redefined in terms of `std::numbers::pi`.

Expect knock-on findings too: `contains()` is const-only where `end()` was not, so
`misc-const-correctness` can suddenly see variables it previously could not.
(`ed`, commit `d2782dc`)

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
