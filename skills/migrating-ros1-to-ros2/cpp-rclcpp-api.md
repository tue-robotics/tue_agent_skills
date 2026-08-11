# Porting roscpp C++ code to rclcpp

All examples from `ed`'s ROS2 migration (commits `8250398`, `062b4a5`) unless noted otherwise.

## Minimal shape: one node, one publisher, one subscriber, logging

This is the most common migration case and doesn't need a callback group, a private executor, or a services split — just `rclcpp::Node::make_shared` + `rclcpp::spin`:

```cpp
// BEFORE
#include <ros/ros.h>
#include <std_msgs/String.h>

class BeaconMonitor
{
public:
  BeaconMonitor(ros::NodeHandle& nh)
  {
    pub_ = nh.advertise<std_msgs::String>("beacon_health", 10);
    sub_ = nh.subscribe("beacon_raw", 10, &BeaconMonitor::callback, this);
  }
  void callback(const std_msgs::String::ConstPtr& msg)
  {
    ROS_INFO_STREAM("Received: " << msg->data);
    std_msgs::String out;
    out.data = "healthy:" + msg->data;
    pub_.publish(out);
  }
private:
  ros::Publisher pub_;
  ros::Subscriber sub_;
};

int main(int argc, char** argv)
{
  ros::init(argc, argv, "beacon_monitor");
  ros::NodeHandle nh;
  BeaconMonitor monitor(nh);
  ros::spin();
  return 0;
}
```

```cpp
// AFTER
#include <rclcpp/rclcpp.hpp>
#include <std_msgs/msg/string.hpp>

class BeaconMonitor
{
public:
  explicit BeaconMonitor(const rclcpp::Node::SharedPtr& node)
  : node_(node)
  {
    pub_ = node_->create_publisher<std_msgs::msg::String>("beacon_health", 10);
    sub_ = node_->create_subscription<std_msgs::msg::String>(
        "beacon_raw", 10, std::bind(&BeaconMonitor::callback, this, std::placeholders::_1));
  }
  // Match ed's own convention (robot_plugin.h): ConstSharedPtr by const-ref, not a bare SharedPtr —
  // the message is read-only in the callback and this avoids an unnecessary refcount bump per call.
  void callback(const std_msgs::msg::String::ConstSharedPtr& msg)
  {
    RCLCPP_INFO_STREAM(node_->get_logger(), "Received: " << msg->data);
    std_msgs::msg::String out;
    out.data = "healthy:" + msg->data;
    pub_->publish(out);
  }
private:
  rclcpp::Node::SharedPtr node_;
  rclcpp::Publisher<std_msgs::msg::String>::SharedPtr pub_;
  rclcpp::Subscription<std_msgs::msg::String>::SharedPtr sub_;
};

int main(int argc, char** argv)
{
  rclcpp::init(argc, argv);
  auto node = rclcpp::Node::make_shared("beacon_monitor");
  auto monitor = std::make_shared<BeaconMonitor>(node);
  rclcpp::spin(node);
  rclcpp::shutdown();
  return 0;
}
```
No callback group or private executor needed here — `rclcpp::spin(node)` on the node's own default executor is enough as long as the node's callbacks are all it needs to service. Reach for the callback-group/private-executor pattern below only when a *plugin or library* (not the top-level spun node) needs to pump its own callbacks independently, or when a synchronous service call must not block the node's main executor.

## Logging

```cpp
// BEFORE
ROS_WARN_NAMED("RobotPlugin", "Robot model error: No mesh geometry defined");
ROS_ERROR_STREAM_NAMED("RobotPlugin", "Could not load mesh shape from '" << abs_filename << "'");
ROS_ERROR("On joint callback: name and position vector must be of equal length.");

// AFTER
RCLCPP_WARN(rclcpp::get_logger("RobotPlugin"), "Robot model error: No mesh geometry defined");
RCLCPP_ERROR_STREAM(rclcpp::get_logger("RobotPlugin"), "Could not load mesh shape from '" << abs_filename << "'");
RCLCPP_ERROR(node_->get_logger(), "On joint callback: ...");
```
Rule: if the class holds a `node_` member, use `node_->get_logger()`. If it's a free function or a class with no node reference (e.g. a static geometry-conversion helper), use `rclcpp::get_logger("Name")` as the direct replacement for ROS1's `_NAMED` argument — there's no separate "named logger" macro in ROS2, the name just becomes the logger's name.

Throttled logging needs a clock and milliseconds, not seconds:
```cpp
RCLCPP_ERROR_THROTTLE(rclcpp::get_logger("ClientROS"), *node_->get_clock(), 1000, "cam_model not yet initialized");
```

## Node handle, subscriptions with a private callback queue

ROS1 plugins that aren't the top-level node often pumped their own `ros::CallbackQueue` manually so they wouldn't steal callbacks from the node's main spin loop:

```cpp
// BEFORE (.h)
ros::CallbackQueue cb_queue_;
std::map<std::string, ros::Subscriber> joint_subscribers_;

// BEFORE (.cpp)
ros::NodeHandle nh;
ros::SubscribeOptions sub_options = ros::SubscribeOptions::create<sensor_msgs::JointState>(
    topic, 10, boost::bind(&RobotPlugin::jointCallback, this, _1), ros::VoidPtr(), &cb_queue_);
joint_subscribers_[topic] = nh.subscribe(sub_options);
...
cb_queue_.callAvailable();  // pumped manually each process() tick
```

ROS2 replacement: give the plugin its own callback group and a private `SingleThreadedExecutor`, and call `spin_some()` where the old code called `callAvailable()`:

```cpp
// AFTER (.h)
rclcpp::CallbackGroup::SharedPtr cb_group_;
rclcpp::executors::SingleThreadedExecutor executor_;
std::map<std::string, rclcpp::Subscription<sensor_msgs::msg::JointState>::SharedPtr> joint_subscribers_;

// AFTER (.cpp)
cb_group_ = node_->create_callback_group(rclcpp::CallbackGroupType::MutuallyExclusive);
rclcpp::SubscriptionOptions sub_options;
sub_options.callback_group = cb_group_;
joint_subscribers_[topic] = node_->create_subscription<sensor_msgs::msg::JointState>(
    topic, 10, std::bind(&RobotPlugin::jointCallback, this, std::placeholders::_1), sub_options);
executor_.add_callback_group(cb_group_, node_->get_node_base_interface());
...
executor_.spin_some();
```
This is the idiomatic pattern any time a library/plugin (not the top-level node) needs to process its own callbacks without stealing from the global executor.

## Parameters — no global parameter server

```cpp
// BEFORE
if (!nh.getParam(urdf_rosparam, urdf_xml)) { config.addError(...); return; }

// AFTER
if (!node_->has_parameter(urdf_rosparam))
    node_->declare_parameter<std::string>(urdf_rosparam, "");
urdf_xml = node_->get_parameter(urdf_rosparam).as_string();
if (urdf_xml.empty()) { config.addError(...); return; }
```
**Gotcha:** ROS2 has no global parameter server. A pattern that read a parameter set on a *different* ROS1 node (e.g. `/robot_description` published globally) has no direct equivalent — either declare the parameter locally on your own node (a stopgap, leave a `// TODO(ROS2):` comment), or redesign as a `transient_local` QoS topic subscription.

Declaring a parameter with a validated numeric range (ROS2-only capability, no ROS1 equivalent):
```cpp
rcl_interfaces::msg::ParameterDescriptor rate_descriptor;
rate_descriptor.description = "Processing loop rate in Hz";
rcl_interfaces::msg::FloatingPointRange rate_range;
rate_range.from_value = 0.01;
rate_range.to_value = std::numeric_limits<double>::max();
rate_descriptor.floating_point_range.push_back(rate_range);
double rate = declare_parameter<double>("rate", 30.0, rate_descriptor);
```

## Time

```cpp
// BEFORE
r->insert(msg->header.stamp.toSec(), pos);
for (Crawler tc(world, robot_name_, ros::Time::now().toSec()); ...)
msg.last_update_time = ros::Time(e.lastUpdateTimestamp());   // ros::Time(double seconds)

// AFTER
r->insert(rclcpp::Time(msg->header.stamp).seconds(), pos);
for (Crawler tc(world, robot_name_, node_->now().seconds()); ...)
msg.last_update_time = rclcpp::Time(static_cast<int64_t>(e.lastUpdateTimestamp() * 1e9));  // rclcpp::Time(int64_t nanoseconds)
```
`rclcpp::Time` has no double-seconds constructor like `ros::Time` did — convert to integer nanoseconds explicitly.

## Publishers

```cpp
// BEFORE (.h)
ros::Publisher pub_stats_;

// BEFORE (.cpp)
if (pub_stats_.getTopic().empty())
{
    ros::NodeHandle nh;
    pub_stats_ = nh.advertise<std_msgs::String>("ed/stats", 10);
}
std_msgs::String msg; msg.data = s.str();
pub_stats_.publish(msg);

// AFTER (.h)
rclcpp::Publisher<std_msgs::msg::String>::SharedPtr pub_stats_;

// AFTER (.cpp)
if (!pub_stats_)
{
    pub_stats_ = node_->create_publisher<std_msgs::msg::String>("ed/stats", 10);
}
std_msgs::msg::String msg; msg.data = s.str();
pub_stats_->publish(msg);   // becomes a pointer: -> not .
```

A small library/utility class that must publish but doesn't own a node (unlike a class that owns `rclcpp::Node::SharedPtr node_`) takes a raw `rclcpp::Node*` per construction/call — the ROS2 equivalent of ROS1's ambient, default-constructible-anywhere `ros::NodeHandle nh;`:
```cpp
class ProfilePublisher
{
public:
    ProfilePublisher(const Profiler& profiler, rclcpp::Node* node);
    void publish() const;
private:
    void initialize(rclcpp::Node* node);
    rclcpp::Publisher<std_msgs::msg::String>::SharedPtr pub_stats_;
    rclcpp::Node* node_;
};
```
(`code_profiler`, commit `e708730`)

## Services

Message namespace: every ROS2 message/service type gains a `::msg::`/`::srv::`/`::action::` segment (`ed_msgs::EntityInfo` → `ed_interfaces::msg::EntityInfo`).

Server callback signature — `bool` return + mutable-ref args becomes `void` return + `shared_ptr` args (field access `.` → `->`, no success flag):
```cpp
// BEFORE
bool srvReset(ed_msgs::Reset::Request& req, ed_msgs::Reset::Response& /*res*/)
{
    ed_wm->reset(req.keep_all_shapes);
    return true;
}

// AFTER
void srvReset(const std::shared_ptr<ed_interfaces::srv::Reset::Request> req,
              std::shared_ptr<ed_interfaces::srv::Reset::Response> /*res*/)
{
    ed_wm->reset(req->keep_all_shapes);
}
```

Registration and main loop:
```cpp
// BEFORE
ros::init(argc, argv, "ed");
ros::NodeHandle nh_private("~");
ros::CallbackQueue cb_queue;
ros::AdvertiseServiceOptions opt = ros::AdvertiseServiceOptions::create<ed_msgs::SimpleQuery>(
    "simple_query", srvSimpleQuery, ros::VoidPtr(), &cb_queue);
ros::ServiceServer srv = nh_private.advertiseService(opt);
ros::Rate r(1000);
while (ros::ok()) { if (trigger.triggers()) cb_queue.callAvailable(); r.sleep(); }

// AFTER
rclcpp::init(argc, argv);
auto node = rclcpp::Node::make_shared("ed");
auto cb_group = node->create_callback_group(rclcpp::CallbackGroupType::MutuallyExclusive);
auto srv = node->create_service<ed_interfaces::srv::SimpleQuery>(
    "~/simple_query", &srvSimpleQuery, rclcpp::ServicesQoS(), cb_group);
rclcpp::executors::SingleThreadedExecutor executor;
executor.add_callback_group(cb_group, node->get_node_base_interface());
rclcpp::WallRate r(1000);
while (rclcpp::ok()) { if (trigger.triggers()) executor.spin_some(); r.sleep(); }
rclcpp::shutdown();
```
Note `"~/simple_query"` — the ROS1 private-namespace `~` prefix survives unchanged in ROS2 name resolution.

Client call — blocking `.call()` becomes async `send_request` + `spin_until_future_complete` on a **private** executor:
```cpp
// BEFORE
ros::NodeHandle nh;
sync_client_ = nh.serviceClient<ed_msgs::Query>(server_name);
ed_msgs::Query query;
query.request.since_revision = rev_number_;
if (!sync_client_.call(query)) { ... }
rev_number_ = query.response.new_revision;

// AFTER
cb_group_ = node_->create_callback_group(rclcpp::CallbackGroupType::MutuallyExclusive);
sync_client_ = node_->create_client<ed_interfaces::srv::Query>(server_name, rclcpp::ServicesQoS(), cb_group_);
executor_.add_callback_group(cb_group_, node_->get_node_base_interface());
auto request = std::make_shared<ed_interfaces::srv::Query::Request>();
request->since_revision = rev_number_;
auto future = sync_client_->async_send_request(request);
if (executor_.spin_until_future_complete(future) != rclcpp::FutureReturnCode::SUCCESS) { ... }
auto response = future.get();
rev_number_ = response->new_revision;
```
**Gotcha:** calling `rclcpp::spin_until_future_complete(node_, future)` (i.e. spinning the node's *main* executor) from inside a plugin/library deadlocks or steals callbacks the node's real spin loop needed. Give the caller its own callback group + private executor, exactly like the subscription pattern above, and spin that instead.

## tf2

```cpp
// BEFORE
tf_broadcaster_ = std::make_unique<tf2_ros::TransformBroadcaster>();
tf2::Stamped<tf2::Transform> t;
geo::convert(e->pose(), t);
t.frame_id_ = root_frame_id_;
t.stamp_ = ros::Time::now();
geometry_msgs::TransformStamped msg;
tf2::convert(t, msg);

// AFTER
tf_broadcaster_ = std::make_unique<tf2_ros::TransformBroadcaster>(node_);   // needs a node now
tf2::Stamped<tf2::Transform> t;
geo::convert(e->pose(), t);
geometry_msgs::msg::TransformStamped msg;
tf2::convert(t, msg);
msg.header.frame_id = root_frame_id_;   // frame_id/stamp set on the ROS msg after conversion, not on tf2::Stamped
msg.header.stamp = node_->now();
```
`tf2_ros::TransformBroadcaster`/`TransformListener` need a node reference in their ROS2 constructors:
```cpp
tf_buffer_ = ed::make_shared<tf2_ros::Buffer>(node_->get_clock());       // Buffer needs a clock
tf_listener_ = ed::make_shared<tf2_ros::TransformListener>(*tf_buffer_, node_);  // Listener needs the node
```

## pluginlib

The macro shape is unchanged:
```cpp
#include <pluginlib/class_list_macros.hpp>
#define ED_REGISTER_PLUGIN(Derived) PLUGINLIB_EXPORT_CLASS(Derived, ed::Plugin)
```
What changes: the plugin base class should carry an injected `rclcpp::Node::SharedPtr node_` (and anything else, e.g. a tf buffer) as a protected member, set by the container before `configure()`/`initialize()` — plugins get a node handle injected rather than creating their own `ros::NodeHandle`:
```cpp
// PluginContainer constructor gains a node parameter
// BEFORE: PluginContainer(const TFBufferConstPtr& tf_buffer);
// AFTER:  PluginContainer(const rclcpp::Node::SharedPtr& node, const TFBufferConstPtr& tf_buffer);
```
The `plugins.xml` class-list file format itself is unchanged between ROS1 and ROS2 (`<library path=...><class name=... type=... base_class_type=...>`). Only its *registration* moves from package.xml (`<export><pkg plugin=.../></export>`) to CMakeLists.txt (`pluginlib_export_plugin_description_file(...)`).

## ros::package → ament_index_cpp

```cpp
// BEFORE
#include <ros/package.h>
std::string pkg_path = ros::package::getPath(pkg);

// AFTER
#include <ament_index_cpp/get_package_share_directory.hpp>
std::string pkg_path = ament_index_cpp::get_package_share_directory(pkg);
```
See [cross-distro-and-deprecation.md](cross-distro-and-deprecation.md) for the version-guarded `get_package_share_path` variant needed on ament_index_cpp ≥1.13.
