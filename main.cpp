#include <cstdint>
#include <iostream>
#include <fstream>
#include <vector>
#include <map>

#include "shared_data.h"

#define TINYGLTF_IMPLEMENTATION
#include "tiny_gltf.h"
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <tiny_obj_loader.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_init.h>
#include <SDL3/SDL_stdinc.h>
#include <SDL3/SDL_video.h>
#include <SDL3/SDL_events.h>
#include <SDL3/SDL_gpu.h>
#include <SDL3/SDL_time.h>

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
    free(filedata);
    return pipeline;
}

bool create_buffer(SDL_GPUDevice* gpu, size_t datasize, SDL_GPUBuffer** bufferOut) {
    SDL_GPUBufferCreateInfo bufferCreateInfo{};
    bufferCreateInfo.usage = SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ;
    bufferCreateInfo.size = (uint32_t)datasize;
    SDL_GPUBuffer* buffer = SDL_CreateGPUBuffer(gpu, &bufferCreateInfo);
    if (buffer == nullptr) {
        SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU buffer creation failed: %s", SDL_GetError());
        return false;
    }
    *bufferOut = buffer;
    return true;
}

bool upload_buffer(SDL_GPUDevice* gpu, SDL_GPUBuffer* buffer, size_t datasize, void* data) {
    SDL_GPUTransferBufferCreateInfo transferCreateInfo{};
    transferCreateInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
    transferCreateInfo.size = (uint32_t)datasize;
    SDL_GPUTransferBuffer* transferBuffer = SDL_CreateGPUTransferBuffer(gpu, &transferCreateInfo);
    if (transferBuffer == nullptr) {
        SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU transfer buffer creation failed: %s", SDL_GetError());
        return false;
    }
    void* rawBufferData = SDL_MapGPUTransferBuffer(gpu, transferBuffer, true);
    if (rawBufferData == nullptr) {
        SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU transfer buffer mapping failed: %s", SDL_GetError());
        return false;
    }
    memcpy(rawBufferData, data, datasize);
    SDL_UnmapGPUTransferBuffer(gpu, transferBuffer);
    SDL_GPUCommandBuffer* cmdbuf = SDL_AcquireGPUCommandBuffer(gpu);
    if (cmdbuf == nullptr) {
        SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU command buffer acquisition failed: %s", SDL_GetError());
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
        SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU command buffer submission failed: %s", SDL_GetError());
        return false;
    }
    SDL_WaitForGPUFences(gpu, true, &fence, 1);
    SDL_ReleaseGPUFence(gpu, fence);
    SDL_ReleaseGPUTransferBuffer(gpu, transferBuffer);
    return true;
}

void load_glb(std::vector<MeshObject>& meshes, std::vector<MeshVertex>& verts, std::vector<uint4>& inds, std::vector<PointLightObject>& lights) {
    tinygltf::TinyGLTF loader{};
    tinygltf::Model model{};
    std::string err;
    std::string warn;
    if (!loader.LoadBinaryFromFile(&model, &err, &warn, "assets/test1.glb")) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Load .glb file failed: %s", err.c_str());
        return;
    } else {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "%s", warn.c_str());
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

int main(int argc, char *argv[]) {
    if (!SDL_Init(SDL_INIT_EVENTS | SDL_INIT_VIDEO)) {
        return EXIT_FAILURE;
    }

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

    int w = 1024;
    int h = w;
    int calcWidth = 128;
    size_t filesize = 0;
    uint8_t* lightmap = malloc_file("assets/lightmap.spv", &filesize);
    if (lightmap == nullptr) {
        SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "Lightmap shader file not found");
    } else {
        SDL_GPUComputePipeline* pipeline = create_pipeline(gpu, filesize, lightmap);
        // free(lightmap);
        // lightmap = nullptr;
        if (pipeline == nullptr) {
            SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "Compute pipeline creation failed: %s", SDL_GetError());
        } else {
            ParamsType params{};
            params.inSeed = float4(0);
            params.offsetPixels = uint4(0);

            /*
            tinyobj::ObjReader reader{};
            if (!reader.ParseFromFile("assets/test.obj")) {
                SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "Load .obj file failed: %s", reader.Error().c_str());
            }
            auto shapes = reader.GetShapes();
            auto attribs = reader.GetAttrib();
            */
            std::vector<MeshObject> meshes{};
            std::vector<MeshVertex> verts{};
            std::vector<uint4> inds{};
            std::vector<PointLightObject> lights{};
            load_glb(meshes, verts, inds, lights);
            /*
            meshes.reserve(shapes.size());
            for (size_t i = 0; i < shapes.size(); i++) {
                MeshObject mesh{};
                mesh.indices.x = (float)inds.size();
                mesh.indices.y = (float)shapes[i].mesh.indices.size();
                for (size_t j = 0; j < shapes[i].mesh.indices.size(); j++) {
                    auto index = shapes[i].mesh.indices[j];
                    MeshVertex vertex{};
                    // positions
                    vertex.position.x = attribs.vertices[index.vertex_index * 3];
                    vertex.position.y = attribs.vertices[index.vertex_index * 3 + 1];
                    vertex.position.z = attribs.vertices[index.vertex_index * 3 + 2];
                    // normals
                    vertex.normal.x = attribs.normals[index.normal_index * 3];
                    vertex.normal.y = attribs.normals[index.normal_index * 3 + 1];
                    vertex.normal.z = attribs.normals[index.normal_index * 3 + 2];
                    // uv coords
                    vertex.uv01.z = attribs.texcoords[index.texcoord_index * 2];
                    vertex.uv01.w = attribs.texcoords[index.texcoord_index * 2 + 1];
                    inds.push_back(float4(verts.size(), 0, 0, 0));
                    verts.push_back(vertex);
                }
                mesh.indices.z = 1; // render flag
                mesh.model = glm::identity<float4x4>();
                mesh.invModel = glm::inverse(mesh.model);
                mesh.aabb.min_pos = float4(-10);
                mesh.aabb.max_pos = float4(10);
                meshes.push_back(mesh);
            }
            */
            /*
            {
                PointLightObject light{};
                // w = range
                light.position = float4(0, 0, 5, 100);
                light.color = float4(1);
                light.data.x = 0.1f;
                lights.push_back(light);
            }
            */

            SDL_GPUBuffer* paramsBuffer = nullptr;
            SDL_GPUBuffer* meshesBuffer = nullptr;
            SDL_GPUBuffer* vertsBuffer = nullptr;
            SDL_GPUBuffer* indsBuffer = nullptr;
            SDL_GPUBuffer* lightsBuffer = nullptr;
            if (!create_buffer(gpu, sizeof(ParamsType), &paramsBuffer)) {
                // error
            }
            upload_buffer(gpu, paramsBuffer, sizeof(ParamsType), &params);

            create_buffer(gpu, sizeof(MeshObject) * meshes.size(), &meshesBuffer);
            upload_buffer(gpu, meshesBuffer, sizeof(MeshObject) * meshes.size(), meshes.data());

            create_buffer(gpu, sizeof(MeshVertex) * verts.size(), &vertsBuffer);
            upload_buffer(gpu, vertsBuffer, sizeof(MeshVertex) * verts.size(), verts.data());

            create_buffer(gpu, sizeof(uint4) * inds.size(), &indsBuffer);
            upload_buffer(gpu, indsBuffer, sizeof(uint4) * inds.size(), inds.data());

            create_buffer(gpu, sizeof(PointLightObject) * lights.size(), &lightsBuffer);
            upload_buffer(gpu, lightsBuffer, sizeof(PointLightObject) * lights.size(), lights.data());

            SDL_GPUTextureCreateInfo textureCreateInfo{};
            textureCreateInfo.type = SDL_GPU_TEXTURETYPE_2D;
            textureCreateInfo.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
            textureCreateInfo.usage = SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE;
            textureCreateInfo.width = w;
            textureCreateInfo.height = h;
            textureCreateInfo.layer_count_or_depth = 1;
            textureCreateInfo.num_levels = 1;
            SDL_GPUTexture* texture = SDL_CreateGPUTexture(gpu, &textureCreateInfo);
            if (texture == nullptr) {
                SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU texture creation failed: %s", SDL_GetError());
            } else {
                SDL_GPUTransferBufferCreateInfo transferCreateInfo{};
                transferCreateInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
                transferCreateInfo.size = w * h * 4;
                SDL_GPUTransferBuffer* transferBuffer = SDL_CreateGPUTransferBuffer(gpu, &transferCreateInfo);
                if (transferBuffer == nullptr) {
                    SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU transfer buffer creation failed: %s", SDL_GetError());
                } else {
                    for (size_t i = 0; i < w; i+=calcWidth) {
                        for (size_t j = 0; j < h; j+=calcWidth) {
                            params.offsetPixels.x = (uint32_t)i;
                            params.offsetPixels.y = (uint32_t)j;
                            params.offsetPixels.z = 1;
                            upload_buffer(gpu, paramsBuffer, sizeof(ParamsType), &params);
                            SDL_GPUCommandBuffer* cmdbuf = SDL_AcquireGPUCommandBuffer(gpu);
                            if (cmdbuf == nullptr) {
                                SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU command buffer acquisition failed: %s", SDL_GetError());
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
                                SDL_GPUFence* fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmdbuf);
                                if (fence == nullptr) {
                                    SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU command buffer submission failed: %s", SDL_GetError());
                                } else {
                                    SDL_WaitForGPUFences(gpu, true, &fence, 1);
                                    SDL_ReleaseGPUFence(gpu, fence);
                                }
                            }
                        }
                    }
                    void* rawBufferData = SDL_MapGPUTransferBuffer(gpu, transferBuffer, true);
                    stbi_flip_vertically_on_write(0);
                    stbi_write_png("output.png", w, h, 4, rawBufferData, w * 4);
                    SDL_UnmapGPUTransferBuffer(gpu, transferBuffer);
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

    SDL_DestroyGPUDevice(gpu);
    SDL_Quit();
    return EXIT_SUCCESS;
}
