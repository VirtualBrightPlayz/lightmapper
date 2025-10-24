#include <cstdint>
#include <iostream>
#include <fstream>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

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
    createInfo.num_readonly_storage_buffers = 0;
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

void dispatch(SDL_GPUDevice* gpu, SDL_GPUComputePipeline* pipeline) {

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
        SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU Device creation failed: %s", SDL_GetError());
        SDL_Quit();
        return EXIT_FAILURE;
    }

    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Selected GPU API: %s", SDL_GetGPUDeviceDriver(gpu));

    int w = 512;
    int h = 512;
    size_t filesize = 0;
    uint8_t* lightmap = malloc_file("assets/lightmap.spv", &filesize);
    if (lightmap == nullptr) {
        SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "Lightmap shader file not found");
    } else {
        SDL_GPUComputePipeline* pipeline = create_pipeline(gpu, filesize, lightmap);
        if (pipeline == nullptr) {
            SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "Compute pipeline creation failed: %s", SDL_GetError());
        } else {
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
                SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU Texture creation failed: %s", SDL_GetError());
            } else {
                SDL_GPUTransferBufferCreateInfo transferCreateInfo{};
                transferCreateInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
                transferCreateInfo.size = w * h * 4;
                SDL_GPUTransferBuffer* transferBuffer = SDL_CreateGPUTransferBuffer(gpu, &transferCreateInfo);
                if (transferBuffer == nullptr) {
                    SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU Transfer Buffer creation failed: %s", SDL_GetError());
                } else {
                    SDL_GPUCommandBuffer* cmdbuf = SDL_AcquireGPUCommandBuffer(gpu);
                    if (cmdbuf == nullptr) {
                        SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU Command Buffer acquisition failed: %s", SDL_GetError());
                    } else {
                        // compute pass
                        SDL_GPUStorageTextureReadWriteBinding bindings[1] = {0};
                        bindings[0].texture = texture;
                        bindings[0].cycle = true;
                        SDL_GPUComputePass* computePass = SDL_BeginGPUComputePass(cmdbuf, bindings, 1, nullptr, 0);
                        SDL_BindGPUComputePipeline(computePass, pipeline);
                        SDL_DispatchGPUCompute(computePass, w / 8, h / 8, 1);
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
                            SDL_LogCritical(SDL_LOG_CATEGORY_APPLICATION, "GPU Command Buffer submission failed: %s", SDL_GetError());
                        } else {
                            SDL_WaitForGPUFences(gpu, true, &fence, 1);
                            SDL_ReleaseGPUFence(gpu, fence);
                            void* rawBufferData = SDL_MapGPUTransferBuffer(gpu, transferBuffer, true);
                            stbi_write_png("output.png", w, h, 4, rawBufferData, w);
                            SDL_UnmapGPUTransferBuffer(gpu, transferBuffer);
                        }
                    }
                    SDL_ReleaseGPUTransferBuffer(gpu, transferBuffer);
                }
                SDL_ReleaseGPUTexture(gpu, texture);
            }
            SDL_ReleaseGPUComputePipeline(gpu, pipeline);
        }
    }

    SDL_DestroyGPUDevice(gpu);
    SDL_Quit();
    return EXIT_SUCCESS;
}
