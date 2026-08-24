# min CMake version required for this project
cmake_minimum_required(VERSION 3.16)
project(diploma_benchmarks LANGUAGES CXX)

# uses C++17 standards and enforces the standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# default to Release build when no build type is specified
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

option(USE_PAPI "Enable PAPI counter support" OFF)

# require OpenMP for parallel code support
find_package(OpenMP REQUIRED)

# global release flags for optimization and disabling debug checks
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -march=native -DNDEBUG")

# define benchmark executables and set release-only optimization flags
add_executable(laplace2d src/laplace2d.cpp)
target_compile_options(laplace2d PRIVATE $<$<CONFIG:Release>:-O3 -march=native>)
target_link_libraries(laplace2d PRIVATE OpenMP::OpenMP_CXX)

add_executable(pagerank src/pagerank.cpp)
target_compile_options(pagerank PRIVATE $<$<CONFIG:Release>:-O3 -march=native>)

add_executable(heapsort src/heapsort.cpp)
target_compile_options(heapsort PRIVATE $<$<CONFIG:Release>:-O3 -march=native>)

if(USE_PAPI)
    find_library(PAPI_LIBRARY NAMES papi REQUIRED)
    find_path(PAPI_INCLUDE_DIR NAMES papi.h REQUIRED)

    target_include_directories(heapsort PRIVATE ${PAPI_INCLUDE_DIR})
    target_link_libraries(heapsort PRIVATE ${PAPI_LIBRARY})

    target_include_directories(pagerank PRIVATE ${PAPI_INCLUDE_DIR})
    target_link_libraries(pagerank PRIVATE ${PAPI_LIBRARY})

    target_include_directories(laplace2d PRIVATE ${PAPI_INCLUDE_DIR})
    target_link_libraries(laplace2d PRIVATE ${PAPI_LIBRARY})
endif()
