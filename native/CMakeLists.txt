cmake_minimum_required(VERSION 3.13)
project(touchpad_helper LANGUAGES C)

find_package(PkgConfig REQUIRED)

add_executable(touchpad-helper main.c)
target_compile_features(touchpad-helper PRIVATE c_std_11)
target_compile_options(touchpad-helper PRIVATE -Wall -Wextra)

pkg_check_modules(EI QUIET libei-1.0)
if(EI_FOUND)
  target_compile_definitions(touchpad-helper PRIVATE HAVE_EI=1)
  target_include_directories(touchpad-helper PRIVATE ${EI_INCLUDE_DIRS})
  target_link_libraries(touchpad-helper PRIVATE ${EI_LINK_LIBRARIES})
endif()

find_path(UINPUT_HEADER linux/uinput.h)
if(UINPUT_HEADER)
  target_compile_definitions(touchpad-helper PRIVATE HAVE_UINPUT=1)
endif()

pkg_check_modules(XTST QUIET xtst)
if(XTST_FOUND)
  target_compile_definitions(touchpad-helper PRIVATE HAVE_X11=1)
  target_include_directories(touchpad-helper PRIVATE ${XTST_INCLUDE_DIRS})
  target_link_libraries(touchpad-helper PRIVATE ${XTST_LINK_LIBRARIES})
  pkg_check_modules(X11 QUIET x11)
  if(X11_FOUND)
    target_include_directories(touchpad-helper PRIVATE ${X11_INCLUDE_DIRS})
    target_link_libraries(touchpad-helper PRIVATE ${X11_LINK_LIBRARIES})
  endif()
endif()

target_link_libraries(touchpad-helper PRIVATE m)

if(NOT EI_FOUND AND NOT XTST_FOUND)
  message(FATAL_ERROR "no input backend available (need libei-1.0 or xtst)")
endif()