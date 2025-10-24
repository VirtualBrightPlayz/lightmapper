cmake_minimum_required(VERSION 3.10)
project(lightmap CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CROSS_PLATFORM_DETERMINISTIC ON)

# set(INTERPROCEDURAL_OPTIMIZATION ON)
# set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)

# set(USE_STATIC_MSVC_RUNTIME_LIBRARY ON)
set(OVERRIDE_CXX_FLAGS OFF)
# set(BUILD_SHARED_LIBS ON)

if (MSVC)
    set(CMAKE_VS_PLATFORM_TOOLSET_HOST_ARCHITECTURE "x64")
    if (USE_STATIC_MSVC_RUNTIME_LIBRARY)
        set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    endif()
    # set(CMAKE_CXX_FLAGS_DEBUG "/GS /Od /Ob0 /RTC1")
    # set(CMAKE_CXX_FLAGS_RELEASE "/GS- /Gy /O2 /Oi /Ot")
    # set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /Zc:__cplusplus /Gm- /MP /nologo /diagnostics:classic /FC /fp:except- /Zc:inline")
endif()

# find_package(Vulkan REQUIRED)
find_package(SDL3 REQUIRED)
# find_package(SDL3_shadercross REQUIRED)
add_subdirectory(tinyobjloader)
add_subdirectory(glm)
#add_subdirectory(FastNoise2)
add_subdirectory(volk)
# include(JoltPhysics/Build/CMakeLists.txt)
#add_subdirectory(JoltPhysics/Build)

#add_library(imgui STATIC imgui/imgui.cpp imgui/imgui_draw.cpp imgui/imgui_tables.cpp imgui/imgui_widgets.cpp imgui/backends/imgui_impl_sdl3.cpp imgui/backends/imgui_impl_sdlrenderer3.cpp imgui/backends/imgui_impl_vulkan.cpp)
#target_compile_definitions(imgui PUBLIC VK_NO_PROTOTYPES)
#target_include_directories(imgui PUBLIC SDL3::Headers imgui imgui/backends volk)
#target_link_libraries(imgui PUBLIC SDL3::SDL3-shared volk)

file(GLOB_RECURSE SRCS src/**.cpp src/**.c src/**.hpp src/**.h)

add_executable(lightmap main.cpp)
target_compile_definitions(lightmap PUBLIC VK_NO_PROTOTYPES)
target_sources(lightmap PUBLIC ${SRCS})
target_include_directories(lightmap PUBLIC src/ glm SDL3::Headers tinyobjloader)
target_link_libraries(lightmap PUBLIC glm SDL3::SDL3-shared tinyobjloader)

set(SHADER_SOURCES assets/lightmap.slang)

add_custom_command(
    TARGET lightmap POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory $<TARGET_FILE_DIR:lightmap>/assets
)

add_custom_command(
    TARGET lightmap POST_BUILD
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMAND ${CMAKE_COMMAND} -E copy_directory assets $<TARGET_FILE_DIR:lightmap>/assets
)

foreach(shader_file ${SHADER_SOURCES})
    get_filename_component(file_spv ${shader_file} NAME_WE)
    set(file_spv "${file_spv}")
    get_filename_component(file_dxil ${shader_file} NAME_WE)
    set(file_dxil "${file_dxil}")
    add_custom_command(
        TARGET lightmap POST_BUILD
        COMMAND slangc ${CMAKE_CURRENT_SOURCE_DIR}/${shader_file} -emit-spirv-via-glsl -target spirv -profile spirv_1_0 -entry main -o $<TARGET_FILE_DIR:lightmap>/assets/${file_spv}.spv
        # COMMAND slangc ${CMAKE_CURRENT_SOURCE_DIR}/${shader_file} -target spirv -profile spirv_1_3 -entry vertexMain -o $<TARGET_FILE_DIR:lightmap>/assets/${file_spv}.vert.spv
        # COMMAND slangc ${CMAKE_CURRENT_SOURCE_DIR}/${shader_file} -target spirv -profile spirv_1_3 -entry fragmentMain -o $<TARGET_FILE_DIR:lightmap>/assets/${file_spv}.frag.spv
        # COMMAND slangc ${CMAKE_CURRENT_SOURCE_DIR}/${shader_file} -target dxil -profile sm_6_0 -entry vertexMain -o $<TARGET_FILE_DIR:lightmap>/assets/${file_dxil}.vert.dxil
        # COMMAND slangc ${CMAKE_CURRENT_SOURCE_DIR}/${shader_file} -target dxil -profile sm_6_0 -entry fragmentMain -o $<TARGET_FILE_DIR:lightmap>/assets/${file_dxil}.frag.dxil
        # COMMAND slangc ${CMAKE_CURRENT_SOURCE_DIR}/${shader_file} -target dxbc -profile sm_5_1 -entry vertexMain -o $<TARGET_FILE_DIR:lightmap>/assets/${file_dxil}.vert.dxbc
        # COMMAND slangc ${CMAKE_CURRENT_SOURCE_DIR}/${shader_file} -target dxbc -profile sm_5_1 -entry fragmentMain -o $<TARGET_FILE_DIR:lightmap>/assets/${file_dxil}.frag.dxbc
    )
endforeach()
