use wgpu::Instance;

fn main() {
    env_logger::init();
    
    // block the thread until future is completed
    // todo: wasm async suppprt
    let state = pollster::block_on(State::new());

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
                    buffers: &[],
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

        let raytrace_pipeline_layout =
            state.device.create_pipeline_layout(
                &wgpu::PipelineLayoutDescriptor {
                    label: Some("raytrace pipeline layout"),
                    bind_group_layouts: &[],
                    push_constant_ranges: &[],
                }
            );
        
        let raytrace_compute_pipeline =
            state.device.create_compute_pipeline(
                &wgpu::ComputePipelineDescriptor {
                    label: Some("raytrace compute pipeline"),
                    layout: Some(&raytrace_pipeline_layout),
                    module: &compute_shader_module,
                    entry_point: "main_raytrace",
                }
            );


    



    // create input and output textures


    // create buffers


    // run command buffers
}

struct State {
    device: wgpu::Device,
    queue: wgpu::Queue,
}

impl State {
    async fn new() -> Self {
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
                features: wgpu::Features::all_webgpu_mask(),
                limits: wgpu::Limits::default(),
                label: None,
            },
            None
        ).await.unwrap();

        Self {
            device,
            queue,
        }
    }
}

type Vec4 = [f32; 4];
type Vec2 = [f32; 2];
type Mat4 = [Vec4; 4];

#[repr(C)]
struct Params
{
    view: Mat4,
    inv_proj: Mat4,
    seed: Vec4,
    offset_pixels: Vec4,
}

#[repr(C)]
struct Sphere
{
    position: Vec4,
    radius: Vec4,
    albedo: Vec4,
    specular: Vec4,
    emission: Vec4,
}

#[repr(C)]
struct AABB
{
    min_pos: Vec4,
    max_pos: Vec4,
}

#[repr(C)]
struct MeshObject
{
    model: Mat4,
    inv_model: Mat4,
    indices:  Vec4,
    aabb: AABB,
}

#[repr(C)]
struct PointLightObject
{
    position: Vec4,
    color: Vec4,
    data: Vec4,
}

#[repr(C)]
struct MeshVertex
{
    position: Vec4,
    normal: Vec4,
    uv01: Vec4,
}

#[repr(C)]
struct Vertex
{
    position: Vec2,
    uv: Vec2,
}

#[repr(C)]
struct BVHNode
{
    aabb: AABB,
    index: Vec4,
}