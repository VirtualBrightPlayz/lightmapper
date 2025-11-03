#include <cstdint>
#include <ctime>
#include <cstdio>
#include <iostream>
#include <fstream>
#include <vector>
#include <algorithm>
#include <map>

#include "shared_data.h"

#define TINYGLTF_IMPLEMENTATION
#include "tiny_gltf.h"
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include "imgui.h"
#include "implot3d.h"
#include "imgui_impl_sdl3.h"
#include "imgui_impl_sdlgpu3.h"

#include <SDL3/SDL.h>
#include <SDL3/SDL_init.h>
#include <SDL3/SDL_stdinc.h>
#include <SDL3/SDL_filesystem.h>
#include <SDL3/SDL_video.h>
#include <SDL3/SDL_events.h>
#include <SDL3/SDL_gpu.h>
#include <SDL3/SDL_time.h>
#include <SDL3/SDL_messagebox.h>
#include <SDL3/SDL_dialog.h>
#include <SDL3/SDL_thread.h>
#include <SDL3/SDL_mutex.h>


struct BakedLightmapData {
    uint32_t width;
    void* colorData;
    void* dirData;
};

struct BakeThreadConfig {
    SDL_GPUDevice* gpu;
    std::string filePath;
    uint16_t textureSize;
    BakedLightmapData output;
};

struct PreviewPerView {
    float4x4 uWorld;
    float4x4 uInvWorld;
    float4x4 uView;
    float4x4 uInvView;
    float4x4 uProjection;
    float4x4 uInvProjection;
    float3 uViewPos;
};

bool should_cancel_bake = false;

std::time_t last_progress_time = (std::time_t)0;
int32_t last_progress_value = -1;

std::vector<std::string> logged_data = {};

void progress_reset() {
    last_progress_time = (std::time_t)0;
    last_progress_value = -1;
    std::cout << (char)27 << "]9;4;0;0" << (char)7;
}

void report_progress(const int32_t progress) {
    std::time_t cur = std::time(nullptr);
    last_progress_value = progress;
    if (cur > last_progress_time) {
        std::cout << (char)27 << "]9;4;1;" << progress << (char)7;
        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "[%i%%]", progress);
        last_progress_time = cur;
    }
}

uint8_t* malloc_file(const std::string path, size_t* filesize) {
    std::ifstream file;
    file.open(path, std::ios::in | std::ios::ate | std::ios::binary);
    if (!file.is_open()) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "File not found: %s", path);
        return {};
    }
    *filesize = file.tellg();
    uint8_t* filedata = (uint8_t*)malloc(*filesize);
    file.seekg(0);
    file.read((char*)filedata, *filesize);
    file.close();
    return filedata;
}

SDL_GPUComputePipeline* create_pipeline(SDL_GPUDevice* gpu, size_t filesize, uint8_t* filedata) {
    SDL_GPUComputePipelineCreateInfo createInfo{};
    createInfo.code_size = filesize;
    createInfo.code = filedata;
    createInfo.entrypoint = "main";
    createInfo.format = SDL_GPU_SHADERFORMAT_SPIRV;
    createInfo.num_readonly_storage_textures = 0;
    createInfo.num_readonly_storage_buffers = 5;
    createInfo.num_readwrite_storage_textures = 1;
    createInfo.num_readwrite_storage_buffers = 0;
    createInfo.num_uniform_buffers = 0;
    createInfo.threadcount_x = 8;
    createInfo.threadcount_y = 8;
    createInfo.threadcount_z = 1;

    SDL_GPUComputePipeline* pipeline = SDL_CreateGPUComputePipeline(gpu, &createInfo);
    return pipeline;
}

bool create_buffer(SDL_GPUDevice* gpu, size_t datasize, SDL_GPUBufferUsageFlags usage, SDL_GPUBuffer** bufferOut) {
    SDL_GPUBufferCreateInfo bufferCreateInfo{};
    bufferCreateInfo.usage = usage;
    bufferCreateInfo.size = (uint32_t)datasize;
    SDL_GPUBuffer* buffer = SDL_CreateGPUBuffer(gpu, &bufferCreateInfo);
    if (buffer == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU buffer creation failed: %s", SDL_GetError());
        return false;
    }
    *bufferOut = buffer;
    return true;
}

bool upload_buffer(SDL_GPUDevice* gpu, SDL_GPUBuffer* buffer, size_t datasize, void* data) {
    SDL_GPUTransferBufferCreateInfo transferCreateInfo{};
    transferCreateInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    transferCreateInfo.size = (uint32_t)datasize;
    SDL_GPUTransferBuffer* transferBuffer = SDL_CreateGPUTransferBuffer(gpu, &transferCreateInfo);
    if (transferBuffer == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU transfer buffer creation failed: %s", SDL_GetError());
        return false;
    }
    void* rawBufferData = SDL_MapGPUTransferBuffer(gpu, transferBuffer, true);
    if (rawBufferData == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU transfer buffer mapping failed: %s", SDL_GetError());
        return false;
    }
    memcpy(rawBufferData, data, datasize);
    SDL_UnmapGPUTransferBuffer(gpu, transferBuffer);
    SDL_GPUCommandBuffer* cmdbuf = SDL_AcquireGPUCommandBuffer(gpu);
    if (cmdbuf == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU command buffer acquisition failed: %s", SDL_GetError());
        return false;
    }
    SDL_GPUCopyPass* copyPass = SDL_BeginGPUCopyPass(cmdbuf);
    SDL_GPUTransferBufferLocation transferSrcInfo{};
    transferSrcInfo.transfer_buffer = transferBuffer;
    transferSrcInfo.offset = 0;
    SDL_GPUBufferRegion destBufferInfo{};
    destBufferInfo.buffer = buffer;
    destBufferInfo.offset = 0;
    destBufferInfo.size = (uint32_t)datasize;
    SDL_UploadToGPUBuffer(copyPass, &transferSrcInfo, &destBufferInfo, true);
    SDL_EndGPUCopyPass(copyPass);
    SDL_GPUFence* fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmdbuf);
    if (fence == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU command buffer submission failed: %s", SDL_GetError());
        return false;
    }
    SDL_WaitForGPUFences(gpu, true, &fence, 1);
    SDL_ReleaseGPUFence(gpu, fence);
    SDL_ReleaseGPUTransferBuffer(gpu, transferBuffer);
    return true;
}

bool upload_buffer_tex(SDL_GPUDevice* gpu, SDL_GPUTexture* buffer, uint32_t width, uint32_t height, uint32_t compSize, void* data) {
    SDL_GPUTransferBufferCreateInfo transferCreateInfo{};
    transferCreateInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    transferCreateInfo.size = width * height * compSize;
    SDL_GPUTransferBuffer* transferBuffer = SDL_CreateGPUTransferBuffer(gpu, &transferCreateInfo);
    if (transferBuffer == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU transfer buffer creation failed: %s", SDL_GetError());
        return false;
    }
    void* rawBufferData = SDL_MapGPUTransferBuffer(gpu, transferBuffer, true);
    if (rawBufferData == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU transfer buffer mapping failed: %s", SDL_GetError());
        return false;
    }
    memcpy(rawBufferData, data, width * height * compSize);
    SDL_UnmapGPUTransferBuffer(gpu, transferBuffer);
    SDL_GPUCommandBuffer* cmdbuf = SDL_AcquireGPUCommandBuffer(gpu);
    if (cmdbuf == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU command buffer acquisition failed: %s", SDL_GetError());
        return false;
    }
    SDL_GPUCopyPass* copyPass = SDL_BeginGPUCopyPass(cmdbuf);
    SDL_GPUTextureTransferInfo transferSrcInfo{};
    transferSrcInfo.transfer_buffer = transferBuffer;
    transferSrcInfo.pixels_per_row = width;
    transferSrcInfo.rows_per_layer = height;
    SDL_GPUTextureRegion destBufferInfo{};
    destBufferInfo.texture = buffer;
    destBufferInfo.w = width;
    destBufferInfo.h = height;
    destBufferInfo.d = 1;
    SDL_UploadToGPUTexture(copyPass, &transferSrcInfo, &destBufferInfo, true);
    SDL_EndGPUCopyPass(copyPass);
    SDL_GPUFence* fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmdbuf);
    if (fence == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU command buffer submission failed: %s", SDL_GetError());
        return false;
    }
    SDL_WaitForGPUFences(gpu, true, &fence, 1);
    SDL_ReleaseGPUFence(gpu, fence);
    SDL_ReleaseGPUTransferBuffer(gpu, transferBuffer);
    return true;
}

void load_glb(std::string file, std::vector<MeshObject>& meshes, std::vector<MeshVertex>& verts, std::vector<uint4>& inds, std::vector<PointLightObject>& lights) {
    tinygltf::TinyGLTF loader{};
    tinygltf::Model model{};
    std::string err;
    std::string warn;
    if (file.length() > 4 && file.compare(file.length() - 4, 4, ".glb") == 0) {
        if (!loader.LoadBinaryFromFile(&model, &err, &warn, file)) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Load \"%s\" file failed: %s", file.c_str(), err.c_str());
            return;
        } else if (!warn.empty()) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Loaded \"%s\" with warning: %s", file.c_str(), warn.c_str());
        }
    } else {
        if (!loader.LoadASCIIFromFile(&model, &err, &warn, file)) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Load \"%s\" file failed: %s", file.c_str(), err.c_str());
            return;
        } else if (!warn.empty()) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Loaded \"%s\" with warning: %s", file.c_str(), warn.c_str());
        }
    }

    for (size_t i = 0; i < model.meshes.size(); i++) {
        for (size_t j = 0; j < model.meshes[i].primitives.size(); j++) {
            tinygltf::Primitive primitive = model.meshes[i].primitives[j];
            MeshObject mesh{};

            // read indices from mesh
            std::vector<uint32_t> indsTmp{};
            tinygltf::Accessor indexAccess = model.accessors[primitive.indices];
            tinygltf::BufferView indexView = model.bufferViews[indexAccess.bufferView];
            tinygltf::Buffer indexBuffer = model.buffers[indexView.buffer];

            if (indexAccess.type == TINYGLTF_TYPE_SCALAR && indexAccess.componentType == TINYGLTF_COMPONENT_TYPE_UNSIGNED_SHORT) {
                uint16_t* indexData = (uint16_t*)indexBuffer.data.data();
                assert(indexAccess.ByteStride(indexView) == sizeof(uint16_t));
                assert(indexAccess.byteOffset == 0);
                for (size_t k = 0; k < indexView.byteLength; k+=indexAccess.ByteStride(indexView)) {
                    uint16_t index = 0;
                    memcpy(&index, &indexBuffer.data.data()[k + indexView.byteOffset], sizeof(uint16_t));
                    indsTmp.push_back(index);
                }
            }

            // read vertices from mesh
            std::vector<float3> positions{};
            std::vector<float3> normals{};
            std::vector<float2> texcoord0{};
            std::vector<float2> texcoord1{};
            // read position data
            if (primitive.attributes.count("POSITION") != 0) {
                tinygltf::Accessor positionAccess = model.accessors[primitive.attributes["POSITION"]];
                tinygltf::BufferView positionView = model.bufferViews[positionAccess.bufferView];
                tinygltf::Buffer positionBuffer = model.buffers[positionView.buffer];
                assert(positionAccess.byteOffset == 0);

                if (positionAccess.type == TINYGLTF_TYPE_VEC3 && positionAccess.componentType == TINYGLTF_COMPONENT_TYPE_FLOAT) {
                    assert(positionAccess.ByteStride(positionView) == sizeof(float3));
                    for (size_t k = 0; k < positionView.byteLength; k+=positionAccess.ByteStride(positionView)) {
                        float3 position = float3();
                        memcpy(&position, &positionBuffer.data.data()[k + positionView.byteOffset], sizeof(float3));
                        positions.push_back(position);
                    }
                }
            }
            // read normal data
            if (primitive.attributes.count("NORMAL") != 0) {
                tinygltf::Accessor positionAccess = model.accessors[primitive.attributes["NORMAL"]];
                tinygltf::BufferView positionView = model.bufferViews[positionAccess.bufferView];
                tinygltf::Buffer positionBuffer = model.buffers[positionView.buffer];
                assert(positionAccess.byteOffset == 0);

                if (positionAccess.type == TINYGLTF_TYPE_VEC3 && positionAccess.componentType == TINYGLTF_COMPONENT_TYPE_FLOAT) {
                    assert(positionAccess.ByteStride(positionView) == sizeof(float3));
                    for (size_t k = 0; k < positionView.byteLength; k+=positionAccess.ByteStride(positionView)) {
                        float3 position = float3();
                        memcpy(&position, &positionBuffer.data.data()[k + positionView.byteOffset], sizeof(float3));
                        normals.push_back(position);
                    }
                }
            }
            // read texcoord0 data
            if (primitive.attributes.count("TEXCOORD_0") != 0) {
                tinygltf::Accessor positionAccess = model.accessors[primitive.attributes["TEXCOORD_0"]];
                tinygltf::BufferView positionView = model.bufferViews[positionAccess.bufferView];
                tinygltf::Buffer positionBuffer = model.buffers[positionView.buffer];
                assert(positionAccess.byteOffset == 0);

                if (positionAccess.type == TINYGLTF_TYPE_VEC2 && positionAccess.componentType == TINYGLTF_COMPONENT_TYPE_FLOAT) {
                    assert(positionAccess.ByteStride(positionView) == sizeof(float2));
                    for (size_t k = 0; k < positionView.byteLength; k+=positionAccess.ByteStride(positionView)) {
                        float2 position = float2();
                        memcpy(&position, &positionBuffer.data.data()[k + positionView.byteOffset], sizeof(float2));
                        texcoord0.push_back(position);
                    }
                }
            }
            // read texcoord1 data
            if (primitive.attributes.count("TEXCOORD_1") != 0) {
                tinygltf::Accessor positionAccess = model.accessors[primitive.attributes["TEXCOORD_1"]];
                tinygltf::BufferView positionView = model.bufferViews[positionAccess.bufferView];
                tinygltf::Buffer positionBuffer = model.buffers[positionView.buffer];
                assert(positionAccess.byteOffset == 0);

                if (positionAccess.type == TINYGLTF_TYPE_VEC2 && positionAccess.componentType == TINYGLTF_COMPONENT_TYPE_FLOAT) {
                    assert(positionAccess.ByteStride(positionView) == sizeof(float2));
                    for (size_t k = 0; k < positionView.byteLength; k+=positionAccess.ByteStride(positionView)) {
                        float2 position = float2();
                        memcpy(&position, &positionBuffer.data.data()[k + positionView.byteOffset], sizeof(float2));
                        // position = glm::fract(position);
                        texcoord1.push_back(position);
                    }
                }
            }
            // compile the data into the MeshVertex struct
            if (positions.size() != 0 && positions.size() == normals.size() && positions.size() == texcoord0.size() && positions.size() == texcoord1.size()) {
                mesh.indices.x = (uint32_t)inds.size();
                mesh.indices.y = (uint32_t)indsTmp.size();
                uint32_t vertOffset = (uint32_t)verts.size();
                // mesh.indices.y = 6;
                // assert(indsTmp.size() == positions.size());
                for (size_t k = 0; k < positions.size(); k++) {
                    MeshVertex vertex{};
                    size_t k2 = k;
                    vertex.position = float4(positions[k2], 0);
                    vertex.normal = float4(normals[k2], 0);
                    vertex.uv01 = float4(texcoord0[k2], texcoord1[k2]);
                    verts.push_back(vertex);
                    if (k == 0) {
                        mesh.aabb.min_pos = vertex.position;
                        mesh.aabb.max_pos = vertex.position;
                    } else {
                        mesh.aabb.min_pos = glm::min(mesh.aabb.min_pos, vertex.position);
                        mesh.aabb.max_pos = glm::max(mesh.aabb.max_pos, vertex.position);
                    }
                }
                for (size_t k = 0; k < indsTmp.size(); k++) {
                    assert(indsTmp[k] < positions.size());
                    assert(indsTmp[k] + vertOffset < verts.size());
                    // MeshVertex vert = verts[indsTmp[k] + mesh.indices.x];
                    inds.push_back(uint4(indsTmp[k] + vertOffset, 0, 0, 0));
                }
            } else {
                SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "positions, normals, texcoord0 and texcoord1 are different sizes");
            }

            mesh.model = glm::identity<float4x4>();
            mesh.invModel = glm::inverse(mesh.model);

            meshes.push_back(mesh);
        }
    }

    for (size_t i = 0; i < model.nodes.size(); i++) {
        tinygltf::Node node = model.nodes[i];
        if (node.mesh != -1) {
            float4x4 t = glm::identity<float4x4>();
            float4x4 r = glm::identity<float4x4>();
            float4x4 s = glm::identity<float4x4>();
            if (node.translation.size() == 3)
                t = glm::translate(float4x4(), *(float3*)node.translation.data());
            if (node.rotation.size() == 4)
                r = float4x4(*(glm::quat*)node.rotation.data());
            if (node.scale.size() == 3)
                s = glm::scale(float4x4(), *(float3*)node.scale.data());
            float4x4 m = t * r * s;
            size_t meshIndex = 0;
            for (size_t j = 0; j < model.meshes.size(); j++) {
                if (j == node.mesh) {
                    for (size_t k = 0; k < model.meshes[j].primitives.size(); k++) {
                        meshes[meshIndex + k].model = m;
                        meshes[meshIndex + k].invModel = glm::inverse(m);
                        meshes[meshIndex + k].indices.z = 1; // render flag
                    }
                    break;
                } else {
                    meshIndex += model.meshes[j].primitives.size();
                }
            }
        }
        if (node.light != -1) {
            tinygltf::Light mdlLight = model.lights[node.light];
            PointLightObject light{};
            light.color.r = (float)mdlLight.color[0];
            light.color.g = (float)mdlLight.color[1];
            light.color.b = (float)mdlLight.color[2];
            light.color.a = (float)mdlLight.intensity / 1000; // 1000 lumens = 1 intensity?
            if (node.translation.size() == 3) {
                light.position.x = (float)node.translation[0];
                light.position.y = (float)node.translation[1];
                light.position.z = (float)node.translation[2];
            }
            light.position.w = (float)mdlLight.range;
            if (mdlLight.extras.IsObject() && mdlLight.extras.Has("size")) {
                light.data.x = (float)mdlLight.extras.Get("size").GetNumberAsDouble();
            }
            lights.push_back(light);
        }
    }
}

bool bake_lightmaps(BakedLightmapData* data, SDL_GPUDevice* gpu, bool (* shouldCancelFunc)(), const std::string glbPath, const uint16_t texSize, const uint32_t seed = 0) {
    progress_reset();
    const uint16_t w = texSize;
    const uint16_t h = w;
    const uint16_t calcWidth = 128;

    bool result = true;
    if (data != nullptr) {
        if (data->colorData != nullptr) {
            free(data->colorData);
            data->colorData = nullptr;
        }
        if (data->dirData != nullptr) {
            free(data->dirData);
            data->dirData = nullptr;
        }
    }

    std::vector<MeshObject> meshes{};
    std::vector<MeshVertex> verts{};
    std::vector<uint4> inds{};
    std::vector<PointLightObject> lights{};
    load_glb(glbPath, meshes, verts, inds, lights);

    if (meshes.size() == 0 || verts.size() == 0 || inds.size() == 0 || lights.size() == 0) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "The selected glb file is missing meshes or lights");
        result = false;
        progress_reset();
        return result;
    }

    size_t filesize = 0;
    uint8_t* lightmap = (uint8_t *)SDL_LoadFile("assets/lightmap.spv", &filesize);
    if (lightmap == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Lightmap shader file not found");
        result = false;
    } else {
        SDL_GPUComputePipeline* pipeline = create_pipeline(gpu, filesize, lightmap);
        SDL_free(lightmap);
        lightmap = nullptr;
        if (pipeline == nullptr) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Compute pipeline creation failed: %s", SDL_GetError());
            result = false;
        } else {
            ParamsType params{};
            params.inSeed = float4(0);
            params.inSeed.x = (float)seed;
            params.offsetPixels = uint4(0);

            SDL_GPUBuffer* paramsBuffer = nullptr;
            SDL_GPUBuffer* meshesBuffer = nullptr;
            SDL_GPUBuffer* vertsBuffer = nullptr;
            SDL_GPUBuffer* indsBuffer = nullptr;
            SDL_GPUBuffer* lightsBuffer = nullptr;

            create_buffer(gpu, sizeof(ParamsType), SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ, &paramsBuffer);
            upload_buffer(gpu, paramsBuffer, sizeof(ParamsType), &params);

            create_buffer(gpu, sizeof(MeshObject) * meshes.size(), SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ, &meshesBuffer);
            upload_buffer(gpu, meshesBuffer, sizeof(MeshObject) * meshes.size(), meshes.data());

            create_buffer(gpu, sizeof(MeshVertex) * verts.size(), SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ, &vertsBuffer);
            upload_buffer(gpu, vertsBuffer, sizeof(MeshVertex) * verts.size(), verts.data());

            create_buffer(gpu, sizeof(uint4) * inds.size(), SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ, &indsBuffer);
            upload_buffer(gpu, indsBuffer, sizeof(uint4) * inds.size(), inds.data());

            create_buffer(gpu, sizeof(PointLightObject) * lights.size(), SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ, &lightsBuffer);
            upload_buffer(gpu, lightsBuffer, sizeof(PointLightObject) * lights.size(), lights.data());

            SDL_GPUTextureCreateInfo textureCreateInfo{};
            textureCreateInfo.type = SDL_GPU_TEXTURETYPE_2D;
            textureCreateInfo.format = SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT;
            textureCreateInfo.usage = SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE;
            textureCreateInfo.width = w;
            textureCreateInfo.height = h;
            textureCreateInfo.layer_count_or_depth = 1;
            textureCreateInfo.num_levels = 1;
            SDL_GPUTexture* texture = SDL_CreateGPUTexture(gpu, &textureCreateInfo);
            if (texture == nullptr) {
                SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU texture creation failed: %s", SDL_GetError());
                result = false;
            } else {

                // SDL_GPUTextureCreateInfo textureCreateInfo{};
                // textureCreateInfo.type = SDL_GPU_TEXTURETYPE_2D;
                // textureCreateInfo.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
                // textureCreateInfo.usage = SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE;
                // textureCreateInfo.width = w;
                // textureCreateInfo.height = h;
                // textureCreateInfo.layer_count_or_depth = 1;
                // textureCreateInfo.num_levels = 1;
                // SDL_GPUTexture* outputTexture = SDL_CreateGPUTexture(gpu, &textureCreateInfo);

                SDL_GPUTransferBufferCreateInfo transferCreateInfo{};
                transferCreateInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
                transferCreateInfo.size = w * h * 4 * sizeof(float);
                SDL_GPUTransferBuffer* transferBuffer = SDL_CreateGPUTransferBuffer(gpu, &transferCreateInfo);
                if (transferBuffer == nullptr) {
                    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU transfer buffer creation failed: %s", SDL_GetError());
                    result = false;
                } else {
                    if (data != nullptr) {
                        data->colorData = malloc(w * h * 4);
                        data->dirData = malloc(w * h * 4);
                        data->width = w;
                    }
                    size_t wCalc = w / calcWidth;
                    size_t hCalc = h / calcWidth;
                    size_t count = w * h * 2;
                    for (size_t k = 0; k < 2; k++) {
                        for (size_t i = 0; i < w; i+=calcWidth) {
                            for (size_t j = 0; j < h; j+=calcWidth) {
                                report_progress((int)((float)(k * w * h + i * w + j) / (float)count * 100.0f));
                                params.offsetPixels.x = (uint32_t)i;
                                params.offsetPixels.y = (uint32_t)j;
                                params.offsetPixels.z = (uint32_t)k;
                                upload_buffer(gpu, paramsBuffer, sizeof(ParamsType), &params);
                                SDL_GPUCommandBuffer* cmdbuf = SDL_AcquireGPUCommandBuffer(gpu);
                                if (cmdbuf == nullptr) {
                                    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU command buffer acquisition failed: %s", SDL_GetError());
                                    result = false;
                                } else {
                                    // compute pass
                                    SDL_GPUStorageTextureReadWriteBinding binding{};
                                    binding.texture = texture;
                                    binding.cycle = true;
                                    SDL_GPUComputePass* computePass = SDL_BeginGPUComputePass(cmdbuf, &binding, 1, nullptr, 0);
                                    SDL_GPUBuffer* bufferBindings[] = {paramsBuffer, meshesBuffer, vertsBuffer, indsBuffer, lightsBuffer};
                                    SDL_BindGPUComputeStorageBuffers(computePass, 0, bufferBindings, 5);
                                    SDL_BindGPUComputePipeline(computePass, pipeline);
                                    SDL_DispatchGPUCompute(computePass, calcWidth / 8, calcWidth / 8, 1);
                                    SDL_EndGPUComputePass(computePass);
                                    /*
                                    // copy pass
                                    SDL_GPUCopyPass* copyPass = SDL_BeginGPUCopyPass(cmdbuf);
                                    SDL_GPUTextureRegion sourceRegion{};
                                    sourceRegion.texture = texture;
                                    sourceRegion.w = w;
                                    sourceRegion.h = h;
                                    sourceRegion.d = 1;
                                    SDL_GPUTextureTransferInfo destInfo{};
                                    destInfo.transfer_buffer = transferBuffer;
                                    SDL_DownloadFromGPUTexture(copyPass, &sourceRegion, &destInfo);
                                    SDL_EndGPUCopyPass(copyPass);
                                    */
                                    SDL_GPUFence* fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmdbuf);
                                    if (fence == nullptr) {
                                        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU command buffer submission failed: %s", SDL_GetError());
                                        result = false;
                                    } else {
                                        SDL_WaitForGPUFences(gpu, true, &fence, 1);
                                        SDL_ReleaseGPUFence(gpu, fence);
                                        if (shouldCancelFunc != nullptr && shouldCancelFunc()) {
                                            // k = 2;
                                            i = w;
                                            j = h;
                                        }
                                    }
                                }
                            }
                        }
                        SDL_GPUCommandBuffer* cmdbuf = SDL_AcquireGPUCommandBuffer(gpu);
                        if (cmdbuf == nullptr) {
                            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU command buffer acquisition failed: %s", SDL_GetError());
                        } else {
                            // copy pass
                            SDL_GPUCopyPass* copyPass = SDL_BeginGPUCopyPass(cmdbuf);
                            // SDL_GPUTextureLocation srcLocation{};
                            // srcLocation.texture = texture;
                            // SDL_GPUTextureLocation dstLocation{};
                            // dstLocation.texture = outputTexture;
                            // SDL_CopyGPUTextureToTexture(copyPass, &srcLocation, &dstLocation, w, h, 1, true);
                            SDL_GPUTextureRegion sourceRegion{};
                            sourceRegion.texture = texture;
                            sourceRegion.w = w;
                            sourceRegion.h = h;
                            sourceRegion.d = 1;
                            SDL_GPUTextureTransferInfo destInfo{};
                            destInfo.transfer_buffer = transferBuffer;
                            SDL_DownloadFromGPUTexture(copyPass, &sourceRegion, &destInfo);
                            SDL_EndGPUCopyPass(copyPass);
                            SDL_GPUFence* fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmdbuf);
                            if (fence == nullptr) {
                                SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "GPU command buffer submission failed: %s", SDL_GetError());
                            } else {
                                SDL_WaitForGPUFences(gpu, true, &fence, 1);
                                SDL_ReleaseGPUFence(gpu, fence);
                                void* rawBufferData = SDL_MapGPUTransferBuffer(gpu, transferBuffer, true);
                                float* rgba32 = (float*)rawBufferData;
                                uint8_t* rgba8 = (uint8_t*)malloc(w * h * 4);
                                for (size_t l = 0; l < w * h * 4; l++) {
                                    float val = rgba32[l];
                                    // assert(val <= 1.0f);
                                    rgba8[l] = (uint8_t)(SDL_clamp(val, 0.0f, 1.0f) * 255.0f);
                                }
                                stbi_flip_vertically_on_write(0);
                                if (k == 0)
                                {
                                    if (data != nullptr)
                                        memcpy(data->colorData, rgba8, w * h * 4);
                                    stbi_write_png("color.png", w, h, 4, rgba8, w * 4);
                                }
                                else if (k == 1)
                                {
                                    if (data != nullptr)
                                        memcpy(data->dirData, rgba8, w * h * 4);
                                    stbi_write_png("dir.png", w, h, 4, rgba8, w * 4);
                                }
                                else
                                {
                                    stbi_write_png("output.png", w, h, 4, rgba8, w * 4);
                                }
                                free(rgba8);
                                SDL_UnmapGPUTransferBuffer(gpu, transferBuffer);
                            }
                        }
                    }
                    SDL_ReleaseGPUTransferBuffer(gpu, transferBuffer);
                }
                SDL_ReleaseGPUTexture(gpu, texture);
            }

            SDL_ReleaseGPUBuffer(gpu, paramsBuffer);
            SDL_ReleaseGPUBuffer(gpu, meshesBuffer);
            SDL_ReleaseGPUBuffer(gpu, vertsBuffer);
            SDL_ReleaseGPUBuffer(gpu, indsBuffer);
            SDL_ReleaseGPUBuffer(gpu, lightsBuffer);

            SDL_ReleaseGPUComputePipeline(gpu, pipeline);
        }
    }
    progress_reset();
    return result;
}

std::vector<SDL_Vertex> get_SDL_verts(const AABB aabb, const std::vector<MeshVertex>& verts, const std::vector<uint4>& inds) {
    std::vector<SDL_Vertex> sdl_verts{};
    float3 minpos = float3(aabb.min_pos.x, aabb.min_pos.y, aabb.min_pos.z);
    float3 maxpos = float3(aabb.max_pos.x, aabb.max_pos.y, aabb.max_pos.z);
    for (size_t i = 0; i < inds.size(); i++) {
        float4 pos2 = verts[inds[i].x].position;
        float4x4 view = glm::lookAt(maxpos * 1.5f, float3(0, 0, 0), float3(0, 0, 1));
        float orthoSize = 1.0f / 100.0f;
        float4x4 proj = glm::ortho(0.0f, orthoSize, 0.0f, orthoSize, 0.1f, 1000.0f);
        float4 pos = float4(pos2.x, pos2.y, pos2.z, 1.0f);
        pos = proj * view * pos;
        SDL_Vertex vert{};
        vert.position.x = pos.x + 512.0f;
        vert.position.y = pos.y + 512.0f;
        vert.color.r = 1;
        vert.color.g = 1;
        vert.color.b = 1;
        vert.color.a = 1;
        vert.tex_coord.x = verts[inds[i].x].uv01.z;
        vert.tex_coord.y = verts[inds[i].x].uv01.w;
        sdl_verts.push_back(vert);
    }
    return sdl_verts;
}

std::vector<ImPlot3DPoint> get_ImPlot3D_verts(const AABB aabb, const std::vector<MeshVertex>& verts, const std::vector<uint4>& inds) {
    std::vector<ImPlot3DPoint> sdl_verts{};
    float3 minpos = float3(aabb.min_pos.x, aabb.min_pos.y, aabb.min_pos.z);
    float3 maxpos = float3(aabb.max_pos.x, aabb.max_pos.y, aabb.max_pos.z);
    for (size_t i = 0; i < verts.size(); i++) {
        float4 pos2 = verts[i].position;
        float4x4 view = glm::lookAt(maxpos * 1.5f, float3(0, 0, 0), float3(0, 0, 1));
        float orthoSize = 1.0f / 100.0f;
        float4x4 proj = glm::ortho(0.0f, orthoSize, 0.0f, orthoSize, 0.1f, 1000.0f);
        float4 pos = float4(pos2.x, pos2.y, pos2.z, 1.0f);
        // pos = proj * view * pos;
        ImPlot3DPoint vert = ImPlot3DPoint(pos.x, pos.y, pos.z);
        sdl_verts.push_back(vert);
    }
    return sdl_verts;
}

SDL_GPUShader* load_shader(SDL_GPUDevice* gpu, std::string filepath, SDL_GPUShaderStage stage, uint32_t samplers, uint32_t uniforms) {
    size_t codeSize;
    void* code = SDL_LoadFile(filepath.c_str(), &codeSize);

    SDL_GPUShaderCreateInfo shaderInfo{};
    shaderInfo.code = (const uint8_t*)code;
    shaderInfo.code_size = codeSize;
    shaderInfo.entrypoint = "main";
    shaderInfo.format = SDL_GPU_SHADERFORMAT_SPIRV;
    shaderInfo.stage = stage;
    shaderInfo.num_samplers = samplers;
    shaderInfo.num_uniform_buffers = uniforms;
    shaderInfo.num_storage_buffers = 0;
    shaderInfo.num_storage_textures = 0;
    SDL_GPUShader* shader = SDL_CreateGPUShader(gpu, &shaderInfo);
    if (shader == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Unable to create shader: %s", SDL_GetError());
    }
    if (code != nullptr) {
        SDL_free(code);
    }
    return shader;
}

SDL_GPUTextureCreateInfo create_texture_info(uint32_t w, uint32_t h) {
    SDL_GPUTextureCreateInfo info{};
    info.type = SDL_GPU_TEXTURETYPE_2D;
    info.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    info.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER;
    info.width = w;
    info.height = h;
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    return info;
}

SDL_GPUTexture* load_texture(SDL_GPUDevice* gpu, const char* path) {
    int x,y,n;
    unsigned char* data = stbi_load(path, &x, &y, &n, 4);
    if (data == nullptr) {
        return nullptr;
    }
    SDL_GPUTexture* tex = SDL_CreateGPUTexture(gpu, &create_texture_info(x, y));
    upload_buffer_tex(gpu, tex, x, y, 4, (void*)data);
    stbi_image_free(data);
    return tex;
}

void render_preview(SDL_GPUDevice* gpu, SDL_GPUTexture* outputTexture, SDL_GPUTextureFormat outputFormat, const std::string path) {
    std::vector<MeshObject> meshes{};
    std::vector<MeshVertex> verts{};
    std::vector<uint4> inds{};
    std::vector<PointLightObject> lights{};
    load_glb(path, meshes, verts, inds, lights);
    if (meshes.size() == 0) {
        return;
    }
    AABB aabb{};
    for (size_t i = 0; i < verts.size(); i++) {
        aabb.min_pos = glm::min(aabb.min_pos, verts[i].position);
        aabb.max_pos = glm::max(aabb.max_pos, verts[i].position);
    }
    float3 minpos = float3(aabb.min_pos.x, aabb.min_pos.y, aabb.min_pos.z);
    float3 maxpos = float3(aabb.max_pos.x, aabb.max_pos.y, aabb.max_pos.z);
    float dist = glm::distance(minpos, maxpos);

    std::vector<uint16_t> indexes{};
    for (size_t i = 0; i < inds.size(); i++) {
        indexes.push_back((uint16_t)inds[i].x);
    }

    SDL_GPUShader* vertShader = load_shader(gpu, "assets/basic.vert.spv", SDL_GPU_SHADERSTAGE_VERTEX, 0, 1);
    SDL_GPUShader* fragShader = load_shader(gpu, "assets/basic.frag.spv", SDL_GPU_SHADERSTAGE_FRAGMENT, 1, 0);

    SDL_GPUTexture* colorTex = load_texture(gpu, "color.png");

    SDL_GPUSamplerCreateInfo samplerInfo{};
    SDL_GPUSampler* sampler = SDL_CreateGPUSampler(gpu, &samplerInfo);

    SDL_GPUBuffer* vertexBuffer;
    create_buffer(gpu, verts.size() * sizeof(MeshVertex), SDL_GPU_BUFFERUSAGE_VERTEX, &vertexBuffer);
    upload_buffer(gpu, vertexBuffer, verts.size() * sizeof(MeshVertex), verts.data());

    SDL_GPUBuffer* indexBuffer;
    create_buffer(gpu, indexes.size() * sizeof(uint16_t), SDL_GPU_BUFFERUSAGE_INDEX, &indexBuffer);
    upload_buffer(gpu, indexBuffer, indexes.size() * sizeof(uint16_t), indexes.data());

    SDL_GPUVertexBufferDescription vertState{0, sizeof(MeshVertex), SDL_GPU_VERTEXINPUTRATE_VERTEX, 0};
    SDL_GPUVertexAttribute attribs[3] = {
        SDL_GPUVertexAttribute{0, 0, SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, sizeof(float) * 0},
        SDL_GPUVertexAttribute{1, 0, SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, sizeof(float) * 4},
        SDL_GPUVertexAttribute{2, 0, SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, sizeof(float) * 8},
    };

    SDL_GPUGraphicsPipelineCreateInfo createInfo{};
    createInfo.vertex_shader = vertShader;
    createInfo.fragment_shader = fragShader;

    SDL_GPUColorTargetDescription colorTargetDesc{};
    colorTargetDesc.format = outputFormat;
    colorTargetDesc.blend_state.enable_blend = false;

    createInfo.target_info.num_color_targets = 1;
    createInfo.target_info.color_target_descriptions = &colorTargetDesc;
    createInfo.target_info.depth_stencil_format = SDL_GPU_TEXTUREFORMAT_INVALID;
    createInfo.target_info.has_depth_stencil_target = false;

    createInfo.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    createInfo.rasterizer_state.fill_mode = SDL_GPU_FILLMODE_FILL;
    createInfo.rasterizer_state.cull_mode = SDL_GPU_CULLMODE_BACK;
    createInfo.rasterizer_state.front_face = SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE;
    createInfo.vertex_input_state.num_vertex_buffers = (uint32_t)1;
    createInfo.vertex_input_state.vertex_buffer_descriptions = &vertState;
    createInfo.vertex_input_state.num_vertex_attributes = (uint32_t)3;
    createInfo.vertex_input_state.vertex_attributes = attribs;

    createInfo.depth_stencil_state.compare_op = SDL_GPU_COMPAREOP_LESS_OR_EQUAL;
    createInfo.depth_stencil_state.enable_depth_test = true;
    createInfo.depth_stencil_state.enable_depth_write = true;
    createInfo.depth_stencil_state.enable_stencil_test = false;

    SDL_GPUGraphicsPipeline* pipeline = SDL_CreateGPUGraphicsPipeline(gpu, &createInfo);

    SDL_GPUCommandBuffer* cmdbuf = SDL_AcquireGPUCommandBuffer(gpu);

    SDL_GPUColorTargetInfo colorInfo{};
    colorInfo.texture = outputTexture;
    colorInfo.load_op = SDL_GPU_LOADOP_CLEAR;
    colorInfo.store_op = SDL_GPU_STOREOP_STORE;
    SDL_GPURenderPass* renderPass = SDL_BeginGPURenderPass(cmdbuf, &colorInfo, 1, nullptr);

    PreviewPerView uniform{};
    uniform.uWorld = glm::identity<float4x4>();
    uniform.uInvWorld = glm::inverse(uniform.uWorld);
    uniform.uView = glm::lookAt(maxpos * 1.5f, float3(0, 0, 0), float3(0, 1, 0));
    uniform.uInvView = glm::inverse(uniform.uView);
    float orthoSize = dist;
    uniform.uProjection = glm::ortho(-orthoSize, orthoSize, -orthoSize, orthoSize, 0.1f, 1000.0f);
    uniform.uInvProjection = glm::inverse(uniform.uProjection);
    SDL_PushGPUVertexUniformData(cmdbuf, 0, &uniform, sizeof(PreviewPerView));
    SDL_GPUTextureSamplerBinding samplerBinding{};
    samplerBinding.texture = colorTex;
    samplerBinding.sampler = sampler;
    SDL_BindGPUFragmentSamplers(renderPass, 0, &samplerBinding, 1);
    SDL_BindGPUGraphicsPipeline(renderPass, pipeline);

    SDL_GPUBufferBinding vertexBinding{};
    vertexBinding.buffer = vertexBuffer;
    SDL_BindGPUVertexBuffers(renderPass, 0, &vertexBinding, 1);
    SDL_GPUBufferBinding indexBinding{};
    indexBinding.buffer = indexBuffer;
    SDL_BindGPUIndexBuffer(renderPass, &indexBinding, SDL_GPU_INDEXELEMENTSIZE_16BIT);

    SDL_DrawGPUIndexedPrimitives(renderPass, (uint32_t)indexes.size(), 1, 0, 0, 0);

    SDL_EndGPURenderPass(renderPass);

    SDL_GPUFence* fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmdbuf);
    SDL_WaitForGPUFences(gpu, true, &fence, 1);

    SDL_ReleaseGPUGraphicsPipeline(gpu, pipeline);

    SDL_ReleaseGPUBuffer(gpu, vertexBuffer);
    SDL_ReleaseGPUBuffer(gpu, indexBuffer);

    SDL_ReleaseGPUSampler(gpu, sampler);
    SDL_ReleaseGPUTexture(gpu, colorTex);

    SDL_ReleaseGPUShader(gpu, fragShader);
    SDL_ReleaseGPUShader(gpu, vertShader);
}

void file_select(void* userdata, const char* const* filelist, int filter) {
    std::string* path = (std::string*)userdata;
    if (filelist == nullptr || filelist[0] == nullptr) {
        *path = "";
        return;
    }
    *path = std::string(filelist[0]);
}

bool bake_thread_should_stop() {
    return should_cancel_bake;
}

int bake_thread(void* userdata) {
    BakeThreadConfig* config = (BakeThreadConfig*)userdata;
    if (bake_lightmaps(&config->output, config->gpu, bake_thread_should_stop, config->filePath, config->textureSize)) {
        return EXIT_SUCCESS;
    } else {
        return EXIT_FAILURE;
    }
}

bool gui_main(SDL_GPUDevice* gpu) {
    SDL_WindowFlags windowFlags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIDDEN;
    SDL_Window* window = SDL_CreateWindow("Lightmap Tool", 1200, 800, windowFlags);
    if (window == nullptr) {
        SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "Window creation failed: %s", SDL_GetError());
        return false;
    }
    SDL_ClaimWindowForGPUDevice(gpu, window);
    SDL_SetWindowPosition(window, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
    SDL_ShowWindow(window);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO(); (void)io;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    ImPlot3D::CreateContext();

    ImGui::StyleColorsDark();
    ImPlot3D::StyleColorsDark();

    ImGui_ImplSDL3_InitForSDLGPU(window);
    ImGui_ImplSDLGPU3_InitInfo initInfo{};
    initInfo.Device = gpu;
    initInfo.ColorTargetFormat = SDL_GetGPUSwapchainTextureFormat(gpu, window);
    ImGui_ImplSDLGPU3_Init(&initInfo);

    std::string filepath = "";
    BakeThreadConfig config = {};
    SDL_Thread* thread = nullptr;
    SDL_GPUTexture* colorTex = nullptr;
    int32_t colorTexWidth = 0;
    SDL_GPUTexture* dirTex = nullptr;
    int32_t dirTexWidth = 0;

    std::vector<MeshObject> meshes{};
    std::vector<MeshVertex> verts{};
    std::vector<uint4> inds{};
    std::vector<PointLightObject> lights{};
    std::vector<ImPlot3DPoint> points{};
    std::vector<unsigned int> plotInds{};
    AABB aabb{};
    SDL_GPUTexture* previewTex = SDL_CreateGPUTexture(gpu, &create_texture_info(1024, 1024));

    bool done = false;
    while (!done) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            ImGui_ImplSDL3_ProcessEvent(&event);
            if (event.type == SDL_EVENT_QUIT)
                done = true;
            if (event.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED && event.window.windowID == SDL_GetWindowID(window))
                done = true;
        }

        if (last_progress_value == -1) {
            SDL_SetWindowProgressState(window, SDL_PROGRESS_STATE_NONE);
        } else {
            SDL_SetWindowProgressState(window, SDL_PROGRESS_STATE_NORMAL);
            SDL_SetWindowProgressValue(window, last_progress_value / 100.0f);
        }

        ImGui_ImplSDLGPU3_NewFrame();
        ImGui_ImplSDL3_NewFrame();
        ImGui::NewFrame();

        {
            ImGuiViewport* vp = ImGui::GetMainViewport();

            if (ImGui::BeginMainMenuBar()) {
                if (ImGui::BeginMenu("Menu")) {
                    if (ImGui::MenuItem("Open File")) {
                        SDL_DialogFileFilter filter{"glTF 2.0", "glb;gltf"};
                        SDL_ShowOpenFileDialog(file_select, &filepath, window, &filter, 1, nullptr, false);
                    }
                    if (ImGui::MenuItem("Bake")) {
                        should_cancel_bake = true;
                        if (thread != nullptr) {
                            SDL_WaitThread(thread, nullptr);
                            thread = nullptr;
                        }
                        should_cancel_bake = false;
                        config.gpu = gpu;
                        config.filePath = filepath;
                        config.textureSize = 1024;
                        thread = SDL_CreateThread(bake_thread, "Lightmap Bake Thread", &config);
                        if (thread == nullptr) {
                            // TODO: handle error
                        }
                    }
                    if (ImGui::MenuItem("Preview")) {
                        meshes.clear();
                        verts.clear();
                        inds.clear();
                        lights.clear();
                        points.clear();
                        plotInds.clear();
                        load_glb(filepath, meshes, verts, inds, lights);
                        aabb = {};
                        for (size_t i = 0; i < meshes.size(); i++) {
                            aabb.min_pos = glm::min(aabb.min_pos, meshes[i].aabb.min_pos);
                            aabb.max_pos = glm::max(aabb.max_pos, meshes[i].aabb.max_pos);
                        }
                        points = get_ImPlot3D_verts(aabb, verts, inds);
                        for (size_t i = 0; i < inds.size(); i++) {
                            plotInds.push_back(inds[i].x);
                        }
                        render_preview(gpu, previewTex, SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, filepath);
                    }
                    ImGui::EndMenu();
                }
                ImGui::EndMainMenuBar();
            }

            ImGui::SetNextWindowPos(vp->WorkPos);
            ImGui::SetNextWindowSize(vp->WorkSize);
            ImGui::Begin("Logs", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings);
            if (colorTex != nullptr) {
                ImGui::Image(colorTex, ImVec2(128.0f, 128.0f));
            }
            if (dirTex != nullptr) {
                if (colorTex != nullptr) {
                    ImGui::SameLine();
                }
                ImGui::Image(dirTex, ImVec2(128.0f, 128.0f));
            }

            ImGui::Image(previewTex, ImVec2(512.0f, 512.0f));
            for (size_t i = 0; i < logged_data.size(); i++) {
                std::string logLine = logged_data.at(i);
                ImGui::TextUnformatted(logLine.c_str());
            }
            ImGui::End();

            if (last_progress_value != -1) {
                ImGui::OpenPopup("Progress");
            }

            ImVec2 center = vp->GetCenter();
            ImGui::SetNextWindowPos(center, ImGuiCond_Appearing, ImVec2(0.5f, 0.5f));
            if (ImGui::BeginPopupModal("Progress", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
                ImGui::Text("Please wait...");
                ImGui::ProgressBar(last_progress_value / 100.0f);
                if (last_progress_value == -1 || ImGui::Button("Cancel")) {
                    should_cancel_bake = true;
                    if (thread != nullptr) {
                        SDL_WaitThread(thread, nullptr);
                        thread = nullptr;
                    }
                    ImGui::CloseCurrentPopup();
                    // bake finished, update images
                    if (colorTex != nullptr)
                        SDL_ReleaseGPUTexture(gpu, colorTex);
                    if (dirTex != nullptr)
                        SDL_ReleaseGPUTexture(gpu, dirTex);
                    colorTex = load_texture(gpu, "color.png");
                    dirTex = load_texture(gpu, "dir.png");
                    render_preview(gpu, previewTex, SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, filepath);
                }
                ImGui::EndPopup();
            }
        }

        ImGui::Render();
        
        SDL_GPUCommandBuffer* cmdbuf = SDL_AcquireGPUCommandBuffer(gpu);
        SDL_GPUTexture* swapchainTexture = nullptr;
        SDL_AcquireGPUSwapchainTexture(cmdbuf, window, &swapchainTexture, nullptr, nullptr);
        if (swapchainTexture != nullptr) {
            ImDrawData* drawData = ImGui::GetDrawData();
            ImGui_ImplSDLGPU3_PrepareDrawData(drawData, cmdbuf);
            SDL_GPUColorTargetInfo colorInfo{};
            colorInfo.texture = swapchainTexture;
            colorInfo.load_op = SDL_GPU_LOADOP_CLEAR;
            colorInfo.store_op = SDL_GPU_STOREOP_STORE;
            SDL_GPURenderPass* renderPass = SDL_BeginGPURenderPass(cmdbuf, &colorInfo, 1, nullptr);
            ImGui_ImplSDLGPU3_RenderDrawData(drawData, cmdbuf, renderPass);
            SDL_EndGPURenderPass(renderPass);
        }
        SDL_GPUFence* fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmdbuf);
        SDL_WaitForGPUFences(gpu, true, &fence, 1);
    }

    if (colorTex != nullptr)
        SDL_ReleaseGPUTexture(gpu, colorTex);
    if (dirTex != nullptr)
        SDL_ReleaseGPUTexture(gpu, dirTex);
    SDL_ReleaseGPUTexture(gpu, previewTex);

    ImGui_ImplSDLGPU3_Shutdown();
    ImGui_ImplSDL3_Shutdown();
    ImPlot3D::DestroyContext();
    ImGui::DestroyContext();

    SDL_ReleaseWindowFromGPUDevice(gpu, window);
    SDL_DestroyWindow(window);
    return true;
}

void on_log(void* userdata, int category, SDL_LogPriority priority, const char* message) {
    SDL_GetDefaultLogOutputFunction()(userdata, category, priority, message);
    logged_data.push_back(message);
}

int main(int argc, char *argv[]) {
    if (!SDL_Init(SDL_INIT_EVENTS | SDL_INIT_VIDEO)) {
        return EXIT_FAILURE;
    }

    SDL_SetLogOutputFunction(on_log, nullptr);

    for (int i = 0; i < SDL_GetNumGPUDrivers(); i++) {
        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "GPU API supported: %s", SDL_GetGPUDriver(i));
    }

    SDL_GPUDevice* gpu = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_SPIRV, true, nullptr);
    if (gpu == nullptr) {
        SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU device creation failed: %s", SDL_GetError());
        SDL_Quit();
        return EXIT_FAILURE;
    }

    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Selected GPU API: %s", SDL_GetGPUDeviceDriver(gpu));

    if (argc > 1) {
        bake_lightmaps(nullptr, gpu, nullptr, argv[1], 1024);
    } else {
        // bake_lightmaps(nullptr, gpu, nullptr, "assets/test1.glb", 1024);
        gui_main(gpu);
    }

    SDL_DestroyGPUDevice(gpu);
    SDL_Quit();
    return EXIT_SUCCESS;
}
