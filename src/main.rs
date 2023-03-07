use wgpu::util::DeviceExt;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::init();

    let samples = 4;
    let tex_size = 512;
    let base_tex_size = 64;
    
    // block the thread until future is completed
    // todo: wasm async suppprt
    let state = pollster::block_on(State::new())?;

    // create shaders

    let add_shader_module = state.device.create_shader_module(
        wgpu::ShaderModuleDescriptor {
            label: Some("Add Shader Module"),
            source: wgpu::ShaderSource::Wgsl(include_str!("add.wgsl").into()),
        }
    );

    let add_pipeline_bind_group_layout = state.device.create_bind_group_layout(
        &wgpu::BindGroupLayoutDescriptor {
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        multisampled: false,
                        view_dimension: wgpu::TextureViewDimension::D2,
                        sample_type: wgpu::TextureSampleType::Float { filterable: true }
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        multisampled: false,
                        view_dimension: wgpu::TextureViewDimension::D2,
                        sample_type: wgpu::TextureSampleType::Float { filterable: true }
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 3,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(
                        wgpu::SamplerBindingType::NonFiltering,
                    ),
                    count: None,
                },
            ],
            label: Some("add pipeline bind group layout"),
        }
    );

    let add_pipeline_layout =
        state.device.create_pipeline_layout(
            &wgpu::PipelineLayoutDescriptor {
                label: Some("Add Pipeline Layout"),
                bind_group_layouts: &[
                    &add_pipeline_bind_group_layout,
                ],
                push_constant_ranges: &[],
            }
        );
    
    let add_render_pipeline =
        state.device.create_render_pipeline(
            &wgpu::RenderPipelineDescriptor {
                label: Some("Add Render Pipeline"),
                layout: Some(&add_pipeline_layout),
                vertex: wgpu::VertexState {
                    module: &add_shader_module,
                    entry_point: "vs_main",
                    buffers: &[
                        wgpu::VertexBufferLayout {
                            array_stride: std::mem::size_of::<VertexInput>() as wgpu::BufferAddress,
                            step_mode: wgpu::VertexStepMode::Vertex,
                            attributes: &[
                                wgpu::VertexAttribute {
                                    offset: 0,
                                    shader_location: 0,
                                    format: wgpu::VertexFormat::Float32x2,
                                },
                                wgpu::VertexAttribute {
                                    offset: std::mem::size_of::<Vec2>() as wgpu::BufferAddress,
                                    shader_location: 1,
                                    format: wgpu::VertexFormat::Float32x2,
                                },
                            ],
                        },
                    ],
                },
                fragment: Some(wgpu::FragmentState {
                    module: &add_shader_module,
                    entry_point: "fs_main",
                    targets: &[Some(wgpu::ColorTargetState {
                        format: wgpu::TextureFormat::Bgra8Unorm,
                        blend: Some(wgpu::BlendState::REPLACE),
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                primitive: wgpu::PrimitiveState {
                    topology: wgpu::PrimitiveTopology::TriangleStrip,
                    strip_index_format: None,
                    front_face: wgpu::FrontFace::Ccw,
                    cull_mode: None,
                    polygon_mode: wgpu::PolygonMode::Fill,
                    unclipped_depth: false,
                    conservative: false,
                },
                depth_stencil: None,
                multisample: wgpu::MultisampleState {
                    count: 1,
                    mask: !0,
                    alpha_to_coverage_enabled: false,
                },
                multiview: None,
            }
        );

        let compute_shader_module = state.device.create_shader_module(
            wgpu::ShaderModuleDescriptor {
                label: Some("compute shader module"),
                source: wgpu::ShaderSource::Wgsl(include_str!("compute.wgsl").into()),
            }
        );

        let compute_pipeline_bind_group_layout = state.device.create_bind_group_layout(
            &wgpu::BindGroupLayoutDescriptor {
                entries: &[
                    wgpu::BindGroupLayoutEntry {
                        binding: 0,
                        visibility: wgpu::ShaderStages::COMPUTE,
                        ty: wgpu::BindingType::Buffer {
                            ty: wgpu::BufferBindingType::Uniform,
                            has_dynamic_offset: false,
                            min_binding_size: None,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 1,
                        visibility: wgpu::ShaderStages::COMPUTE,
                        ty: wgpu::BindingType::Buffer {
                            ty: wgpu::BufferBindingType::Storage { read_only: true },
                            has_dynamic_offset: false,
                            min_binding_size: None,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 2,
                        visibility: wgpu::ShaderStages::COMPUTE,
                        ty: wgpu::BindingType::Buffer {
                            ty: wgpu::BufferBindingType::Storage { read_only: true },
                            has_dynamic_offset: false,
                            min_binding_size: None,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 3,
                        visibility: wgpu::ShaderStages::COMPUTE,
                        ty: wgpu::BindingType::Buffer {
                            ty: wgpu::BufferBindingType::Storage { read_only: true },
                            has_dynamic_offset: false,
                            min_binding_size: None,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 4,
                        visibility: wgpu::ShaderStages::COMPUTE,
                        ty: wgpu::BindingType::Buffer {
                            ty: wgpu::BufferBindingType::Storage { read_only: true },
                            has_dynamic_offset: false,
                            min_binding_size: None,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 5,
                        visibility: wgpu::ShaderStages::COMPUTE,
                        ty: wgpu::BindingType::Buffer {
                            ty: wgpu::BufferBindingType::Storage { read_only: true },
                            has_dynamic_offset: false,
                            min_binding_size: None,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 6,
                        visibility: wgpu::ShaderStages::COMPUTE,
                        ty: wgpu::BindingType::StorageTexture {
                            access: wgpu::StorageTextureAccess::WriteOnly,
                            format: wgpu::TextureFormat::Rgba32Float,
                            view_dimension: wgpu::TextureViewDimension::D2,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 7,
                        visibility: wgpu::ShaderStages::COMPUTE,
                        ty: wgpu::BindingType::StorageTexture {
                            access: wgpu::StorageTextureAccess::ReadWrite,
                            format: wgpu::TextureFormat::Rgba32Float,
                            view_dimension: wgpu::TextureViewDimension::D2,
                        },
                        count: None,
                    },
                ],
                label: Some("compute pipeline bind group layout"),
            }
        );

        let compute_pipeline_layout =
            state.device.create_pipeline_layout(
                &wgpu::PipelineLayoutDescriptor {
                    label: Some("compute pipeline layout"),
                    bind_group_layouts: &[
                        &compute_pipeline_bind_group_layout,
                    ],
                    push_constant_ranges: &[],
                }
            );
        
        let raytrace_compute_pipeline =
            state.device.create_compute_pipeline(
                &wgpu::ComputePipelineDescriptor {
                    label: Some("raytrace compute pipeline"),
                    layout: Some(&compute_pipeline_layout),
                    module: &compute_shader_module,
                    entry_point: "main_raytrace",
                }
            );
        
        let lightmap_compute_pipeline =
            state.device.create_compute_pipeline(
                &wgpu::ComputePipelineDescriptor {
                    label: Some("lightmap compute pipeline"),
                    layout: Some(&compute_pipeline_layout),
                    module: &compute_shader_module,
                    entry_point: "main_lightmap",
                }
            );

        


    



    // create input and output textures

    let texture = state.device.create_texture(
        &wgpu::TextureDescriptor {
            label: Some("Texture"),
            size: wgpu::Extent3d {
                width: tex_size,
                height: tex_size,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba32Float,
            usage: wgpu::TextureUsages::STORAGE_BINDING,
            view_formats: &[],
        }
    );

    let texture_view = texture.create_view(
        &wgpu::TextureViewDescriptor {
            label: Some("Texture View"),
            format: Some(wgpu::TextureFormat::Rgba32Float),
            dimension: Some(wgpu::TextureViewDimension::D2),
            aspect: wgpu::TextureAspect::All,
            base_mip_level: 0,
            mip_level_count: None,
            base_array_layer: 0,
            array_layer_count: None,
        }
    );

    let out_texture = state.device.create_texture(
        &wgpu::TextureDescriptor {
            label: Some("Output Texture"),
            size: wgpu::Extent3d {
                width: tex_size,
                height: tex_size,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba32Float,
            usage: wgpu::TextureUsages::STORAGE_BINDING,
            view_formats: &[],
        }
    );

    let out_texture_view = out_texture.create_view(
        &wgpu::TextureViewDescriptor {
            label: Some("Texture View"),
            format: Some(wgpu::TextureFormat::Rgba32Float),
            dimension: Some(wgpu::TextureViewDimension::D2),
            aspect: wgpu::TextureAspect::All,
            base_mip_level: 0,
            mip_level_count: None,
            base_array_layer: 0,
            array_layer_count: None,
        }
    );

    // create buffers

    let world = World::default();


    let param_data = Params {
        view: todo!(),
        inv_proj: todo!(),
        seed: todo!(),
        offset_pixels: todo!(),
    };

    let param_uniform_buffer = state.device.create_buffer_init(
        &wgpu::util::BufferInitDescriptor {
            label: Some("Params Uniform Buffer"),
            contents: bytemuck::cast_slice(&[param_data]),
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::UNIFORM,
        }
    );

    let sphere_storage_buffer = state.device.create_buffer_init(
        &wgpu::util::BufferInitDescriptor {
            label: Some("Sphere Storage Buffer"),
            contents: bytemuck::cast_slice(world.spheres.as_slice()),
            usage: wgpu::BufferUsages::STORAGE,
        }
    );

    let mesh_storage_buffer = state.device.create_buffer_init(
        &wgpu::util::BufferInitDescriptor {
            label: Some("Mesh Storage Buffer"),
            contents: bytemuck::cast_slice(world.meshes.as_slice()),
            usage: wgpu::BufferUsages::STORAGE,
        }
    );

    // todo: this could maybe be used as a vertex buffer for the add shader?
    let vertex_storage_buffer = state.device.create_buffer_init(
        &wgpu::util::BufferInitDescriptor {
            label: Some("Vertex Storage Buffer"),
            contents: bytemuck::cast_slice(world.verticies.as_slice()),
            usage: wgpu::BufferUsages::STORAGE,
        }
    );

    let index_storage_buffer = state.device.create_buffer_init(
        &wgpu::util::BufferInitDescriptor {
            label: Some("Index Storage Buffer"),
            contents: bytemuck::cast_slice(world.indicies.as_slice()),
            usage: wgpu::BufferUsages::STORAGE,
        }
    );

    let point_light_storage_buffer = state.device.create_buffer_init(
        &wgpu::util::BufferInitDescriptor {
            label: Some("Point Light Storage Buffer"),
            contents: bytemuck::cast_slice(world.lights.as_slice()),
            usage: wgpu::BufferUsages::STORAGE,
        }
    );

    let compute_bind_group = state.device.create_bind_group(
        &wgpu::BindGroupDescriptor {
            label: Some("Compute Bind Group"),
            layout: &compute_pipeline_bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::Buffer(
                        wgpu::BufferBinding {
                            buffer: &param_uniform_buffer,
                            offset: 0,
                            size: wgpu::BufferSize::new(std::mem::size_of::<Params>() as wgpu::BufferAddress),
                        }
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Buffer(
                        wgpu::BufferBinding {
                            buffer: &sphere_storage_buffer,
                            offset: 0,
                            size: wgpu::BufferSize::new((std::mem::size_of::<Sphere>() * world.spheres.len()) as wgpu::BufferAddress),
                        }
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::Buffer(
                        wgpu::BufferBinding {
                            buffer: &mesh_storage_buffer,
                            offset: 0,
                            size: wgpu::BufferSize::new((std::mem::size_of::<MeshObject>() * world.meshes.len()) as wgpu::BufferAddress),
                        }
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::Buffer(
                        wgpu::BufferBinding {
                            buffer: &vertex_storage_buffer,
                            offset: 0,
                            size: wgpu::BufferSize::new((std::mem::size_of::<MeshVertex>() * world.verticies.len()) as wgpu::BufferAddress),
                        }
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: wgpu::BindingResource::Buffer(
                        wgpu::BufferBinding {
                            buffer: &index_storage_buffer,
                            offset: 0,
                            size: wgpu::BufferSize::new((std::mem::size_of::<Vec4>() * world.indicies.len()) as wgpu::BufferAddress),
                        }
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 5,
                    resource: wgpu::BindingResource::Buffer(
                        wgpu::BufferBinding {
                            buffer: &point_light_storage_buffer,
                            offset: 0,
                            size: wgpu::BufferSize::new((std::mem::size_of::<PointLightObject>() * world.lights.len()) as wgpu::BufferAddress),
                        }
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 6,
                    resource: wgpu::BindingResource::TextureView(
                        &texture_view
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 7,
                    resource: wgpu::BindingResource::TextureView(
                        &out_texture_view
                    ),
                },
            ],
        }
    );

    // run command buffers
    for i in (0..=tex_size).step_by(base_tex_size) {
        for i2 in (0..=tex_size).step_by(base_tex_size) {
            let mut encoder = state.device.create_command_encoder(
                &wgpu::CommandEncoderDescriptor {
                    label: Some("Compute Loop Encoder"),
                },
            );
            // compute pass
            {
                let mut compute_pass = encoder.begin_compute_pass(
                    &wgpu::ComputePassDescriptor {
                        label: Some("Compute Pass"),
                    }
                );

                compute_pass.set_pipeline(&lightmap_compute_pipeline);
                compute_pass.set_bind_group(0, &compute_bind_group, &[]);
                compute_pass.dispatch_workgroups((base_tex_size / 8) as u32, (base_tex_size / 8) as u32, 1);
            }

            // submit command encode (also runs light function calls)
            state.queue.submit(std::iter::once(encoder.finish()));

            // update params buffer (all this does is tell the queue to write at next submit before executing commands)
            let mut new_param_data = param_data.clone();
            new_param_data.offset_pixels = [i as f32, i2 as f32, 0.0, 0.0];
            state.queue.write_buffer(&param_uniform_buffer, 0, bytemuck::cast_slice(&[new_param_data]));
        }
    }

    Ok(())
}

struct State {
    device: wgpu::Device,
    queue: wgpu::Queue,
}

impl State {
    async fn new() -> Result<Self, Box<dyn std::error::Error>> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::all(),
            dx12_shader_compiler: Default::default(),
        });

        let adapter = instance.request_adapter(
            &wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: None,
                force_fallback_adapter: false,
            },
        ).await.unwrap();

        let (device, queue) = adapter.request_device(
            &wgpu::DeviceDescriptor {
                features: wgpu::Features::default() | wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES,
                limits: wgpu::Limits::default(),
                label: None,
            },
            None
        ).await?;

        Ok(Self {
            device,
            queue,
        })
    }
}

type Mat4 = [Vec4; 4];
type Vec4 = [f32; 4];
type Vec2 = [f32; 2];

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct Params
{
    view: Mat4,
    inv_proj: Mat4,
    seed: Vec4,
    offset_pixels: Vec4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct VertexInput
{
    position: Vec2,
    uv: Vec2,
}

#[derive(Debug, Default)]
struct World
{
    spheres: Vec<Sphere>,
    meshes: Vec<MeshObject>,
    verticies: Vec<MeshVertex>,
    indicies: Vec<Vec4>,
    lights: Vec<PointLightObject>,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct Sphere
{
    position: Vec4,
    radius: Vec4,
    albedo: Vec4,
    specular: Vec4,
    emission: Vec4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct AABB
{
    min_pos: Vec4,
    max_pos: Vec4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct MeshObject
{
    model: Mat4,
    inv_model: Mat4,
    indices:  Vec4,
    aabb: AABB,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct PointLightObject
{
    position: Vec4,
    color: Vec4,
    data: Vec4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct MeshVertex
{
    position: Vec4,
    normal: Vec4,
    uv01: Vec4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct Vertex
{
    position: Vec2,
    uv: Vec2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct BVHNode
{
    aabb: AABB,
    index: Vec4,
}