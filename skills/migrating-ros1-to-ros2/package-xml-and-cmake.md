# package.xml and CMakeLists.txt conversion

Real diffs from tue-robotics migrations. Repo/commit cited per example so you can go read the full file if needed.

## package.xml

### Format and buildtool

```xml
<!-- BEFORE: often no format attribute, or format="2" -->
<package>
  <buildtool_depend>catkin</buildtool_depend>

<!-- AFTER -->
<?xml-model href="http://download.ros.org/schema/package_format3.xsd" schematypens="http://www.w3.org/2001/XMLSchema"?>
<package format="3">
  <buildtool_depend>ament_cmake</buildtool_depend>
```
(`rosconsole_bridge`, commit `a88d74f`)

### Dependency tags collapse

ROS1's `build_depend`/`run_depend`/`build_export_depend` split mostly collapses to plain `<depend>` (build+run+export in one), with `exec_depend` still used for runtime-only (Python scripts, launch_ros, rclpy):

```xml
<!-- BEFORE -->
<build_depend>cmake_modules</build_depend>
<depend>roscpp</depend>
<exec_depend>python3-rospkg</exec_depend>
<exec_depend>roslib</exec_depend>

<!-- AFTER -->
<depend>rclcpp</depend>
<exec_depend>ament_index_python</exec_depend>
<exec_depend>launch_ros</exec_depend>
<exec_depend>rclpy</exec_depend>
```
(`ed`, commit `8250398`)

### pluginlib export moves out of package.xml

```xml
<!-- BEFORE -->
<export>
  <ed plugin="${prefix}/plugins.xml" />
  <rosdoc config="rosdoc.yaml" />
</export>

<!-- AFTER -->
<export>
  <build_type>ament_cmake</build_type>
  <rosdoc config="rosdoc.yaml" />
</export>
<!-- the plugin registration moves to CMakeLists.txt: pluginlib_export_plugin_description_file(...) -->
```
Same for nodelets: `<export><nodelet plugin=.../></export>` is simply deleted — ROS2 components have no plugin-description XML at all (discovery is via the ament index + `rclcpp_components_register_nodes()`).

### Lint/test tooling test_depends

```xml
<test_depend>ament_cmake_clang_format</test_depend>
<test_depend>ament_cmake_clang_tidy</test_depend>
<test_depend>ament_cmake_gtest</test_depend>
<test_depend>ament_cmake_lint_cmake</test_depend>
<test_depend>ament_cmake_xmllint</test_depend>
<test_depend>clang-format-21</test_depend>
<test_depend>clang-tidy-21</test_depend>
<test_depend>tue_lint_config</test_depend>
```
Replaces a bare `<test_depend>catkin_lint_cmake</test_depend>`. **This exact block is org-specific**: `ament_clang_format`/`ament_clang_tidy` with version-pinning args (`--clang-format-version=21`, `--clang-tidy-version=21`, `JOBS`/`TIMEOUT`) are **not** vanilla upstream `ament_lint` — they require the org's own `ament_lint` fork plus `tue_lint_config`'s shared configs in the workspace. Outside that workspace, use the portable equivalent instead:
```xml
<test_depend>ament_lint_auto</test_depend>
<test_depend>ament_lint_common</test_depend>
```
with `find_package(ament_lint_auto REQUIRED)` + `ament_lint_auto_find_test_dependencies()` in CMakeLists.txt (shown in the minimal-package example below) — this is vanilla upstream `ament_lint`, needs no org-specific fork, and still covers `ament_cmake_lint_cmake`/`ament_cmake_xmllint`/cpplint/uncrustify if those are also listed as `test_depend`s. `catkin_lint_cmake` itself is never "migrated" — it stays ROS1-only and is simply dropped once a package moves to `ament_cmake`.

### Message-only package: rename and retarget

```xml
<!-- BEFORE: ed_msgs -->
<name>ed_msgs</name>
<buildtool_depend>catkin</buildtool_depend>
<depend>tue_serialization</depend>
<build_depend>message_generation</build_depend>
<build_export_depend>message_runtime</build_export_depend>
<exec_depend>message_runtime</exec_depend>

<!-- AFTER: ed_interfaces -->
<name>ed_interfaces</name>
<version>0.1.0</version>
<buildtool_depend>ament_cmake</buildtool_depend>
<depend>builtin_interfaces</depend>
<depend>tue_serialization_interfaces</depend>   <!-- deps also get the _msgs -> _interfaces rename -->
<build_depend>rosidl_default_generators</build_depend>
<exec_depend>rosidl_default_runtime</exec_depend>
<test_depend>ament_lint_common</test_depend>
<member_of_group>rosidl_interface_packages</member_of_group>  <!-- required tag, easy to forget -->
<export>
  <build_type>ament_cmake</build_type>
</export>
```
(`ed_msgs`→`ed_interfaces`, commit `9d93bcb`; identical pattern in `rgbd_msgs`→`rgbd_interfaces` and the `code_profiler`/`tue_serialization` splits below)

### .msg/.srv field type changes

```
# BEFORE
time last_update_time
duration age
tue_serialization/Binary[] images

# AFTER
builtin_interfaces/Time last_update_time
builtin_interfaces/Duration age
tue_serialization_interfaces/Binary[] images
```
ROS2 has no bare `time`/`duration` field type. Cross-package message field types follow the same `_msgs`→`_interfaces` rename as the packages themselves. Also: `.msg`/`.srv` files that were flat in the ROS1 package root must move under `msg/`/`srv/` subdirectories for ROS2.

## CMakeLists.txt

### Minimal package: one executable, no library, no messages

The smallest common case — a node with no exported library, no generated interfaces, no services:

```cmake
cmake_minimum_required(VERSION 3.8)
project(beacon_monitor)
if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(std_msgs REQUIRED)

add_executable(beacon_monitor_node src/beacon_monitor_node.cpp)
target_link_libraries(beacon_monitor_node
  rclcpp::rclcpp
  std_msgs::std_msgs__rosidl_typesupport_cpp
)

install(TARGETS beacon_monitor_node DESTINATION lib/${PROJECT_NAME})

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()
endif()
ament_package()
```
No `ament_export_targets`/`ament_export_dependencies` — those are only for a package that ships a library other packages will `find_package()` and link against. A plain executable has nothing to export. `<pkg>::<pkg>__rosidl_typesupport_cpp` (here `std_msgs::std_msgs__rosidl_typesupport_cpp`) is the same generated-typesupport target used for libraries in the split-package example below — it works identically on `add_executable` targets.

For the lint/test block, `ament_lint_auto_find_test_dependencies()` (from `ament_lint_auto`, vanilla upstream `ament_lint`) is the portable default — it picks up whichever `ament_cmake_*` linters are listed as `test_depend`s in package.xml, with no dependency on any org-specific tooling. Only reach for the full `ament_clang_format`/`ament_clang_tidy`/`tue_lint_config` block (§ "Lint/test tooling" above) if you're inside a workspace that has that fork; see the note there.

### Canonical library/plugin package conversion

```cmake
# BEFORE
cmake_minimum_required(VERSION 3.5)
project(ed)
find_package(catkin REQUIRED COMPONENTS
  cmake_modules code_profiler diagnostic_updater ${PROJECT_NAME}_msgs
  geolib2 pluginlib rgbd rgbd_msgs rosconsole_bridge roscpp tf2_ros
  tue_config tue_filesystem tue_serialization
)
find_package(OpenCV REQUIRED)
catkin_package(
  INCLUDE_DIRS include
  LIBRARIES ${PROJECT_NAME}_core ${PROJECT_NAME}_io ${PROJECT_NAME}_server
  CATKIN_DEPENDS code_profiler ${PROJECT_NAME}_msgs geolib2 pluginlib rgbd rgbd_msgs roscpp tf2_ros
  DEPENDS OpenCV PCL
)
include_directories(include SYSTEM 3rdparty/... ${catkin_INCLUDE_DIRS})
add_library(${PROJECT_NAME}_core ${HEADER_FILES} src/...)
target_link_libraries(${PROJECT_NAME}_core polypartition ... ${catkin_LIBRARIES})
add_dependencies(${PROJECT_NAME}_core ${catkin_EXPORTED_TARGETS})
catkin_install_python(PROGRAMS tools/entity-teleop DESTINATION ${CATKIN_PACKAGE_BIN_DESTINATION})
if (CATKIN_ENABLE_TESTING)
  find_package(catkin_lint_cmake REQUIRED)
  catkin_add_catkin_lint_test("-W2 --ignore LITERAL_PROJECT_NAME --ignore UNSORTED_LIST")
endif()
```

```cmake
# AFTER
cmake_minimum_required(VERSION 3.8)
project(ed)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()
if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Werror=all -Wextra -Werror=extra)
endif()

find_package(ament_cmake REQUIRED)
find_package(ament_index_cpp REQUIRED)
find_package(code_profiler REQUIRED)
find_package(diagnostic_updater REQUIRED)
find_package(ed_interfaces REQUIRED)
find_package(geolib2 REQUIRED)
find_package(pluginlib REQUIRED)
find_package(rclcpp REQUIRED)
find_package(rgbd REQUIRED)
find_package(rgbd_interfaces REQUIRED)
find_package(rosconsole_bridge REQUIRED)
find_package(tf2 REQUIRED)
find_package(tf2_ros REQUIRED)
find_package(tue_config REQUIRED)
find_package(tue_serialization REQUIRED)
# Non-ROS dependencies still use find_package() the same way
find_package(Boost REQUIRED COMPONENTS thread)
find_package(OpenCV REQUIRED)
find_package(PCL REQUIRED COMPONENTS common)

add_library(${PROJECT_NAME}_core SHARED ${HEADER_FILES} src/...)
target_include_directories(${PROJECT_NAME}_core PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>
)
# Prefer modern exported targets when the dependency ships them
target_link_libraries(${PROJECT_NAME}_core PUBLIC
  polypartition Boost::thread code_profiler::code_profiler geolib2::geolib
  rgbd::rgbd rosconsole_bridge::rosconsole_bridge tue_config::tue_config
  tue_serialization::tue_serialization
  ${PCL_LIBRARIES}
  # Core ROS 2 deps go in the same call - never ament_target_dependencies (see below)
  diagnostic_updater::diagnostic_updater pluginlib::pluginlib
  rclcpp::rclcpp tf2_ros::tf2_ros
)

pluginlib_export_plugin_description_file(${PROJECT_NAME} plugins.xml)

install(PROGRAMS tools/entity-teleop DESTINATION lib/${PROJECT_NAME})
install(DIRECTORY include/${PROJECT_NAME}/ DESTINATION include/${PROJECT_NAME})
install(FILES plugins.xml DESTINATION share/${PROJECT_NAME})
install(
  TARGETS polypartition ${PROJECT_NAME}_core ${PROJECT_NAME}_io ${PROJECT_NAME}_server
  EXPORT export_${PROJECT_NAME}
  ARCHIVE DESTINATION lib LIBRARY DESTINATION lib RUNTIME DESTINATION bin
)
ament_export_targets(export_${PROJECT_NAME} HAS_LIBRARY_TARGET)
ament_export_dependencies(
  ament_index_cpp code_profiler diagnostic_updater ed_interfaces geolib2
  pluginlib rclcpp rgbd rosconsole_bridge tf2_ros tue_config tue_serialization
  Boost OpenCV PCL
)

if(BUILD_TESTING)
  find_package(ament_cmake_gtest REQUIRED)
  find_package(ament_cmake_clang_format REQUIRED)
  find_package(ament_cmake_clang_tidy REQUIRED)
  find_package(ament_cmake_lint_cmake REQUIRED)
  find_package(ament_cmake_xmllint REQUIRED)
  find_package(tue_lint_config REQUIRED)
  ament_clang_format(CONFIG_FILE ${tue_lint_config_DIR}/../config/.clang-format --clang-format-version=21)
  # For large packages, cap parallelism and raise the timeout so clang-tidy doesn't
  # hit the default 300s and fail with "did not generate a result file".
  cmake_host_system_information(RESULT CLANG_TIDY_JOBS QUERY NUMBER_OF_LOGICAL_CORES)
  if(NOT CLANG_TIDY_JOBS OR CLANG_TIDY_JOBS EQUAL 0)
    set(CLANG_TIDY_JOBS 1)
  endif()
  ament_clang_tidy(CONFIG_FILE ${tue_lint_config_DIR}/../config/.clang-tidy --clang-tidy-version=21
    JOBS ${CLANG_TIDY_JOBS} TIMEOUT 600
    ${CMAKE_CURRENT_SOURCE_DIR} ${CMAKE_BINARY_DIR}/compile_commands.json)
  ament_lint_cmake(MAX_LINE_LENGTH 120)
  ament_xmllint(MAX_LINE_LENGTH 120)
endif()

ament_package()
```
(`ed`, commits `8250398` + `062b4a5`; full canonical file at `ed/CMakeLists.txt`)

`${tue_lint_config_DIR}/../config/...`: `<pkg>_DIR` is the ament-index CMake-config directory one level below `share/<pkg>/`, hence `/../config/` to reach the sibling `config/` directory where `tue_lint_config` installs its shared `.clang-format`/`.clang-tidy`.

If vendored/3rdparty source shouldn't be linted, exclude it from `compile_commands.json` around just that `add_library` call:
```cmake
set(CMAKE_EXPORT_COMPILE_COMMANDS OFF)
add_library(polypartition 3rdparty/polypartition/src/polypartition.cpp)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
```

### Never use ament_target_dependencies

`ament_target_dependencies` **does not exist on Rolling** — `ament_cmake_target_dependencies`
stopped shipping `ament_target_dependencies.cmake` there, so any CMakeLists using it fails to
configure with `Unknown CMake command "ament_target_dependencies"`. It is still present on Humble
and Jazzy, which is exactly why the mistake survives review: the package builds on the distro you
tested and breaks on the one you didn't.

Every ROS 2 dependency is reachable through `target_link_libraries` instead. Pick the first form
that applies:

| Dependency shape | Write this |
|---|---|
| Normal ament_cmake package (the common case) | `target_link_libraries(tgt PUBLIC pkg::pkg)` |
| Interface package, all typesupports | `target_link_libraries(tgt PUBLIC ${pkg_TARGETS})` |
| Interface package, one typesupport | `target_link_libraries(tgt PRIVATE pkg::pkg__rosidl_typesupport_cpp)` |
| No exported targets at all (rare, legacy) | `target_link_libraries(tgt PUBLIC ${pkg_LIBRARIES})` plus `target_include_directories(tgt SYSTEM PUBLIC ${pkg_INCLUDE_DIRS})` |

`pkg::pkg` covers far more than it looks like it should — verified on both Jazzy and Rolling for
`diagnostic_updater`, `pluginlib`, `rclcpp`, `tf2`, `tf2_ros`, `tf2_geometry_msgs`, `kdl_parser`,
`urdf`, and even the message packages `std_msgs` and `sensor_msgs`. Check an unfamiliar dependency
before guessing:

```cmake
# drop into any CMakeLists, configure once, then delete
find_package(somepkg REQUIRED)
if(TARGET somepkg::somepkg)
  message(STATUS "use somepkg::somepkg")
endif()
message(STATUS "somepkg_TARGETS = ${somepkg_TARGETS}")
```

Two behaviour changes to expect when you convert a call:

- **Visibility becomes yours to choose.** `ament_target_dependencies` linked everything
  `PUBLIC`/`INTERFACE`. `target_link_libraries` makes you say `PUBLIC` or `PRIVATE`, so a dependency
  used only in a `.cpp` should become `PRIVATE` and stop leaking into your exported link interface.
- **`ament_export_dependencies` is still required.** It is a separate mechanism and is not removed;
  keep listing every dependency whose targets appear on your `PUBLIC`/`INTERFACE` interface, or
  consumers fail at generate time with "the link interface of target `pkg::lib` contains
  `Foo::foo` but the target was not found".

### Message-only package: rosidl_generate_interfaces

```cmake
# BEFORE (ed_msgs)
find_package(catkin REQUIRED COMPONENTS message_generation tue_serialization geometry_msgs shape_msgs)
add_message_files(FILES EntityInfo.msg SubVolume.msg Volume.msg)
add_service_files(FILES GetGUICommand.srv Query.srv Reset.srv ...)
generate_messages(DEPENDENCIES tue_serialization geometry_msgs shape_msgs)
catkin_package(CATKIN_DEPENDS tue_serialization geometry_msgs shape_msgs message_runtime)

# AFTER (ed_interfaces)
find_package(ament_cmake REQUIRED)
find_package(builtin_interfaces REQUIRED)
find_package(geometry_msgs REQUIRED)
find_package(rosidl_default_generators REQUIRED)
find_package(shape_msgs REQUIRED)
find_package(tue_serialization_interfaces REQUIRED)

rosidl_generate_interfaces(${PROJECT_NAME}
  "msg/EntityInfo.msg" "msg/SubVolume.msg" "msg/Volume.msg"
  "srv/GetGUICommand.srv" "srv/Query.srv" "srv/Reset.srv"
  DEPENDENCIES builtin_interfaces geometry_msgs shape_msgs tue_serialization_interfaces
  ADD_LINTER_TESTS
)
ament_export_dependencies(rosidl_default_runtime)

if(BUILD_TESTING)
  find_package(ament_cmake_lint_cmake REQUIRED)
  find_package(ament_cmake_xmllint REQUIRED)
  ament_lint_cmake(MAX_LINE_LENGTH 120)
  ament_xmllint(MAX_LINE_LENGTH 120)
endif()
ament_package()
```
(`ed_msgs`→`ed_interfaces`, commit `9d93bcb`)

### Splitting a combined lib+msgs package

Repo layout changes from one `CMakeLists.txt`/`package.xml` pair to two sibling package directories in the same repo:
```
code_profiler/CMakeLists.txt + package.xml            (library, ament_cmake)
code_profiler_interfaces/CMakeLists.txt + package.xml  (rosidl, ament_cmake)
code_profiler_interfaces/msg/Statistics.msg
```

Library side links against the generated typesupport target directly instead of relying on `ament_target_dependencies` to discover it implicitly:
```cmake
find_package(code_profiler_interfaces REQUIRED)
find_package(rclcpp REQUIRED)
find_package(std_msgs REQUIRED)

add_library(${PROJECT_NAME} SHARED src/loop_timer.cpp src/profiler.cpp)
target_link_libraries(${PROJECT_NAME}
  PRIVATE
    code_profiler_interfaces::code_profiler_interfaces__rosidl_typesupport_cpp
    rclcpp::rclcpp
    std_msgs::std_msgs__rosidl_typesupport_cpp
)
ament_export_targets(export_${PROJECT_NAME} HAS_LIBRARY_TARGET)
ament_export_dependencies(code_profiler_interfaces rclcpp std_msgs)
```
Interfaces side is the minimal `rosidl_generate_interfaces` block from the previous section.
(`code_profiler`, commits `89a08f6`, `e708730`, `55e5528`; same split shape in `tue_serialization`/`tue_serialization_interfaces`)

### Minimal package, linked with namespaced targets

```cmake
# First pass (a88d74f) - DO NOT COPY, ament_target_dependencies is gone on Rolling
find_package(ament_cmake)
set(dependencies console_bridge_vendor console_bridge rcutils)
foreach(dependency ${dependencies})
  find_package(${dependency} REQUIRED)
endforeach()
add_library(${PROJECT_NAME} SHARED src/bridge.cpp)
ament_target_dependencies(${PROJECT_NAME} ${dependencies})
ament_export_targets(${PROJECT_NAME}Targets HAS_LIBRARY_TARGET)
ament_export_dependencies(${dependencies})
ament_package()

# Later hardening (069baca): "Don't use ament_target_dependencies"
target_link_libraries(${PROJECT_NAME}
  PUBLIC console_bridge::console_bridge
  PRIVATE rcutils::rcutils
)
```
(`rosconsole_bridge`) The second form is the only one to write today: `target_link_libraries` with
explicit `PUBLIC`/`PRIVATE`. It gets visibility right where `ament_target_dependencies` always
linked everything `PUBLIC`/`INTERFACE`, and unlike `ament_target_dependencies` it exists on every
distro. See "Never use ament_target_dependencies" above.

### gtest

```cmake
if(BUILD_TESTING)
  find_package(ament_cmake_gtest REQUIRED)
  ament_add_gtest(${PROJECT_NAME}-test test/test_${PROJECT_NAME}.cpp)
  target_link_libraries(${PROJECT_NAME}-test ${PROJECT_NAME})
endif()
```
Direct replacement for `catkin_add_gtest(...)` — same call shape.

### Tooling package that just shares config files

```cmake
# tue_lint_config/CMakeLists.txt — installs shared clang-format/clang-tidy configs
cmake_minimum_required(VERSION 3.8)
project(tue_lint_config)
find_package(ament_cmake REQUIRED)
install(DIRECTORY config DESTINATION share/${PROJECT_NAME}/)
if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()
endif()
ament_package()
```
Downstream packages consume it via `find_package(tue_lint_config REQUIRED)` + `${tue_lint_config_DIR}/../config/.clang-format`, as shown above.
