# Nodelets → rclcpp_components, and .launch → .launch.py

Evidence: `rgbd` repo, PR `#90` (commit `b67bc32`, range `fccd490..9218190`), converting `ros_to_rgbd` from a nodelet to a component.

## Nodelet → component

Old ROS1 nodelet, full shape:
```cpp
#include <nodelet/nodelet.h>
#include <pluginlib/class_list_macros.hpp>

class ROSToRGBDNodelet : public nodelet::Nodelet
{
public:
    ROSToRGBDNodelet() {}
private:
    virtual void onInit()
    {
        ros::NodeHandle nh = getNodeHandle();
        ros::NodeHandle nh_private = getPrivateNodeHandle();
        std::string rgb_type_str = "lossless";
        nh_private.getParam("rgb_storage", rgb_type_str);
        client_ = std::make_unique<rgbd::ClientRosNodelet>(nh);
        client_->initialize("rgb_image", "depth_image", "cam_info");
        server_ = std::make_unique<rgbd::Server>(nh);
        client_->getSync()->registerCallback(boost::bind(&ROSToRGBDNodelet::imageCallback, this, _1, _2));
    }
    bool imageCallback(const sensor_msgs::ImageConstPtr& rgb, const sensor_msgs::ImageConstPtr& depth)
    {
        if (!client_->imageCallback(rgb, depth)) { ROS_ERROR("..."); return false; }
        server_->send(*client_->getImage());
        return true;
    }
    std::unique_ptr<rgbd::ClientRosNodelet> client_;
    std::unique_ptr<rgbd::Server> server_;
};
PLUGINLIB_EXPORT_CLASS(rgbd::ROSToRGBDNodelet, nodelet::Nodelet)
```

New ROS2 component — split across three files: header, implementation, and a tiny registration-only translation unit.

```cpp
// ros_to_rgbd_component.h
class RosToRGBDComponent : public rclcpp::Node
{
public:
    explicit RosToRGBDComponent(const rclcpp::NodeOptions& options = rclcpp::NodeOptions());
private:
    bool initializeInterfaces();
    void runOnce();
    std::unique_ptr<ClientROS> client_;
    std::unique_ptr<Server> server_;
    rclcpp::TimerBase::SharedPtr timer_;
};
```

```cpp
// ros_to_rgbd_component.cpp
RosToRGBDComponent::RosToRGBDComponent(const rclcpp::NodeOptions& options) :
    rclcpp::Node("ros_to_rgbd", options),
    rgb_type_(parseRGBStorageType(declare_parameter<std::string>("rgb_storage", "lossless")))
{
    double rate = declare_parameter<double>("rate", 30.0);
    const auto period = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::duration<double>(1.0 / rate));
    timer_ = create_wall_timer(period, [this] { runOnce(); });
}
bool RosToRGBDComponent::initializeInterfaces()
{
    auto node = shared_from_this();   // needed: `this` is a raw pointer, constructors below want Node::SharedPtr
    client_ = std::make_unique<ClientROS>(node);
    server_ = std::make_unique<Server>(node);
    return client_->initialize("rgb_image", "depth_image", "cam_info");
}
void RosToRGBDComponent::runOnce()
{
    if (!interfaces_initialized_) { interfaces_initialized_ = initializeInterfaces(); if (!interfaces_initialized_) return; }
    if (auto image = client_->nextImage()) server_->send(*image);
}
```

```cpp
// ros_to_rgbd_component_registration.cpp — entire file
#include "rgbd/ros_to_rgbd_component.h"
#include <rclcpp_components/register_node_macro.hpp>
RCLCPP_COMPONENTS_REGISTER_NODE(rgbd::RosToRGBDComponent)
```

CMakeLists.txt:
```cmake
find_package(rclcpp_components REQUIRED)
add_library(ros_to_${PROJECT_NAME}_component SHARED
  src/ros_to_rgbd_component.cpp
  src/ros_to_rgbd_component_registration.cpp
)
target_link_libraries(ros_to_${PROJECT_NAME}_component
  ${PROJECT_NAME} rclcpp::rclcpp rclcpp_components::component
)
rclcpp_components_register_nodes(ros_to_${PROJECT_NAME}_component
  PLUGIN "rgbd::RosToRGBDComponent"
  EXECUTABLE ros_to_${PROJECT_NAME}
)
```
`rclcpp_components_register_nodes(... EXECUTABLE ...)` auto-generates the standalone executable wrapper — no hand-written `main()` for a components-based node. The generated executable name (`ros_to_rgbd` here) is whatever you pass to `EXECUTABLE`, and does **not** need to match the old ROS1 nodelet/executable name — update launch files accordingly (see below).

Structural mapping to remember:
- `nodelet::Nodelet::onInit()` → constructor body + `declare_parameter` in the initializer list.
- Blocking `nh_private.getParam(...)` → `declare_parameter<T>(name, default[, descriptor])`.
- `message_filters`/sync-driven `registerCallback` firing straight into nodelet code → often becomes an explicit `create_wall_timer` poll loop instead, if the underlying client wraps its own executor/sync (as `ClientROS` does here) rather than delivering straight into the node's callback.
- `PLUGINLIB_EXPORT_CLASS(..., nodelet::Nodelet)` → `RCLCPP_COMPONENTS_REGISTER_NODE(...)`. Delete `nodelet_plugins.xml` and its package.xml `<export>` entry entirely — ROS2 components have no plugin-description XML.

## .launch → .launch.py

```xml
<!-- BEFORE: standard_kinect.launch -->
<launch>
    <arg name="gdb" default="false"/>
    <arg if="$(arg gdb)" name="launch-prefix" value="gdb -ex run --args"/>
    <node name="rgbd_encoder" pkg="rgbd" type="rgbd_server" output="screen" launch-prefix="$(arg launch-prefix)">
        <remap from="cam_info" to="/camera/rgb/camera_info"/>
        <remap from="rgb_image" to="/camera/rgb/image_rect_color"/>
        <remap from="depth_image" to="/camera/depth_registered/hw_registered/image_rect_raw"/>
        <remap from="output" to="/camera/rgbd"/>
    </node>
</launch>
```

```python
# AFTER: standard_kinect.launch.py
from launch import LaunchDescription
from launch_ros.actions import Node


def generate_launch_description():
    return LaunchDescription([
        Node(
            package="rgbd",
            executable="ros_to_rgbd",   # the EXECUTABLE name from rclcpp_components_register_nodes, not the old ROS1 binary name
            name="rgbd_encoder",
            output="screen",
            remappings=[
                ("cam_info", "/camera/rgb/camera_info"),
                ("rgb_image", "/camera/rgb/image_rect_color"),
                ("depth_image", "/camera/depth_registered/hw_registered/image_rect_raw"),
                ("rgbd", "/camera/rgbd"),   # the internal topic name changed too — verify remap targets, don't copy blindly
            ],
        ),
    ])
```
Not every ROS1 launch idiom needs a literal round-trip translation — the `gdb`/`launch-prefix` conditional-arg dance was dropped entirely in this port rather than translated to `launch.conditions.IfCondition`. Decide per-argument whether it's still needed before porting it.

## Cross-distro subscriber QoS overload gotcha

`message_filters::Subscriber<T>::subscribe()` takes an `rclcpp::QoS` object on newer distros but a raw `rmw_qos_profile_t` on older ones. Detect the right overload at compile time with SFINAE rather than distro `#ifdef`s — more robust than guessing which distro has which signature:

```cpp
template <typename SubscriberT, typename NodeT>
auto subscribeSensorDataImpl(SubscriberT& sub, const NodeT& node, const std::string& topic,
                              rclcpp::SubscriptionOptions options, int)
    -> decltype(sub.subscribe(node, topic, rclcpp::SensorDataQoS(), options), void())
{
    sub.subscribe(node, topic, rclcpp::SensorDataQoS(), options);
}
template <typename SubscriberT, typename NodeT>
void subscribeSensorDataImpl(SubscriberT& sub, const NodeT& node, const std::string& topic,
                              rclcpp::SubscriptionOptions options, long)
{
    sub.subscribe(node, topic, rmw_qos_profile_sensor_data, options);
}
```
The `int`/`long` overload tiebreak plus `decltype(...)` SFINAE picks the QoS-object overload when it exists and falls back to the raw-profile overload otherwise, at compile time, on whatever distro you're building for.
