cmake_minimum_required(VERSION 3.16)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../../VERSION" REMOLD_VERSION)
string(STRIP "${REMOLD_VERSION}" REMOLD_VERSION)
project(Kinect360RemoldSdkBridge VERSION ${REMOLD_VERSION} LANGUAGES C CXX)
include(GNUInstallDirs)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
add_library(kinect360-remold-sdk-bridge STATIC src/remold_sdk_bridge.cpp)
add_library(Kinect360Remold::sdk ALIAS kinect360-remold-sdk-bridge)
set_target_properties(kinect360-remold-sdk-bridge PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(kinect360-remold-sdk-bridge PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)
if(MSVC)
  target_compile_options(kinect360-remold-sdk-bridge PRIVATE /W4 /permissive-)
else()
  target_compile_options(kinect360-remold-sdk-bridge PRIVATE -Wall -Wextra -Wpedantic)
endif()
install(TARGETS kinect360-remold-sdk-bridge EXPORT Kinect360RemoldSdkTargets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT Kinect360RemoldSdkTargets
  NAMESPACE Kinect360Remold::
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/Kinect360RemoldSdk)
