cmake_minimum_required(VERSION 3.16)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../../../VERSION" REMOLD_VERSION)
string(STRIP "${REMOLD_VERSION}" REMOLD_VERSION)
project(Kinect360RemoldLinux VERSION ${REMOLD_VERSION} LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
include(GNUInstallDirs)
find_package(Threads REQUIRED)
find_package(Python3 COMPONENTS Interpreter REQUIRED)


option(REMOLD_BUILD_HARDWARE "Build Kinect hardware services" ON)
option(REMOLD_BUILD_IP_CAMERA "Build the native HTTP/MJPEG camera" ON)

add_library(remold_common INTERFACE)
target_include_directories(remold_common INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_definitions(remold_common INTERFACE _FILE_OFFSET_BITS=64)

function(remold_enable_warnings target)
  if(MSVC)
    target_compile_options(${target} PRIVATE /W4 /permissive-)
  else()
    target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic)
  endif()
endfunction()

add_executable(kinect360-remoldctl src/remoldctl.cpp)
target_link_libraries(kinect360-remoldctl PRIVATE remold_common Threads::Threads)
remold_enable_warnings(kinect360-remoldctl)

add_executable(kinect360-remold-nui src/nui_compat.cpp)
target_link_libraries(kinect360-remold-nui PRIVATE remold_common Threads::Threads)
remold_enable_warnings(kinect360-remold-nui)

if(REMOLD_BUILD_HARDWARE)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(LIBUSB REQUIRED IMPORTED_TARGET libusb-1.0>=1.0.18)
  pkg_check_modules(ALSA REQUIRED IMPORTED_TARGET alsa)

  find_program(CABEXTRACT_EXECUTABLE cabextract)
  find_program(MSIEXTRACT_EXECUTABLE msiextract)
  if(NOT CABEXTRACT_EXECUTABLE OR NOT MSIEXTRACT_EXECUTABLE)
    message(FATAL_ERROR "Linux hardware build requires cabextract and msiextract (msitools) so Microsoft Kinect Runtime v1.8 UACFirmware can be extracted during compilation.")
  endif()

  set(REMOLD_FIRMWARE_CACHE_DIR "${CMAKE_BINARY_DIR}/downloads" CACHE PATH "Cache for pinned Microsoft Kinect Runtime v1.8")
  set(REMOLD_GENERATED_DIR "${CMAKE_BINARY_DIR}/generated")
  set(REMOLD_FIRMWARE_HEADER "${REMOLD_GENERATED_DIR}/Kinect360RemoldAudioFirmware.generated.h")
  set(REMOLD_FIRMWARE_BIN "${CMAKE_BINARY_DIR}/UACFirmware-01.02.709.00")
  add_custom_command(
    OUTPUT "${REMOLD_FIRMWARE_HEADER}" "${REMOLD_FIRMWARE_BIN}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${REMOLD_GENERATED_DIR}"
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/scripts/prepare-runtime-uac-firmware.py"
            --cache-dir "${REMOLD_FIRMWARE_CACHE_DIR}"
            --output-header "${REMOLD_FIRMWARE_HEADER}"
            --output-bin "${REMOLD_FIRMWARE_BIN}"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/scripts/prepare-runtime-uac-firmware.py"
    COMMENT "[3/4] Downloading/validating Kinect Runtime v1.8 and extracting UACFirmware 01.02.709.00"
    VERBATIM)
  add_custom_target(remold-uac-firmware DEPENDS "${REMOLD_FIRMWARE_HEADER}" "${REMOLD_FIRMWARE_BIN}")

  add_executable(kinect360-remold-broker src/broker.cpp)
  target_link_libraries(kinect360-remold-broker PRIVATE remold_common PkgConfig::LIBUSB Threads::Threads)
  remold_enable_warnings(kinect360-remold-broker)

  add_executable(kinect360-remold-camera src/camera_bridge.cpp src/kinect_usb_camera.cpp)
  target_link_libraries(kinect360-remold-camera PRIVATE remold_common PkgConfig::LIBUSB Threads::Threads)
  remold_enable_warnings(kinect360-remold-camera)

  add_executable(kinect360-remold-audio src/audio_bridge.cpp "${REMOLD_FIRMWARE_HEADER}")
  add_dependencies(kinect360-remold-audio remold-uac-firmware)
  target_include_directories(kinect360-remold-audio PRIVATE "${REMOLD_GENERATED_DIR}")
  target_link_libraries(kinect360-remold-audio PRIVATE remold_common PkgConfig::LIBUSB PkgConfig::ALSA Threads::Threads)
  remold_enable_warnings(kinect360-remold-audio)

  add_executable(kinect360-remold-v4l2 src/v4l2_bridge.cpp)
  target_link_libraries(kinect360-remold-v4l2 PRIVATE remold_common Threads::Threads)
  remold_enable_warnings(kinect360-remold-v4l2)

  if(REMOLD_BUILD_IP_CAMERA)
    find_package(JPEG REQUIRED)
    add_executable(kinect360-remold-camera-ip src/camera_ip.cpp)
    target_link_libraries(kinect360-remold-camera-ip PRIVATE remold_common JPEG::JPEG Threads::Threads)
    remold_enable_warnings(kinect360-remold-camera-ip)
  endif()
endif()

install(TARGETS kinect360-remoldctl RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(TARGETS kinect360-remold-nui RUNTIME DESTINATION ${CMAKE_INSTALL_LIBEXECDIR}/kinect360-remold)
install(PROGRAMS scripts/ensure-v4l2-device.sh DESTINATION ${CMAKE_INSTALL_LIBEXECDIR}/kinect360-remold)
if(REMOLD_BUILD_HARDWARE)
  install(TARGETS kinect360-remold-broker kinect360-remold-camera kinect360-remold-audio kinect360-remold-v4l2
          RUNTIME DESTINATION ${CMAKE_INSTALL_LIBEXECDIR}/kinect360-remold)
  if(TARGET kinect360-remold-camera-ip)
    install(TARGETS kinect360-remold-camera-ip RUNTIME DESTINATION ${CMAKE_INSTALL_LIBEXECDIR}/kinect360-remold)
  endif()
endif()
