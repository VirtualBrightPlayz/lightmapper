using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using SharpGLTF.Schema2;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.PixelFormats;
using Veldrid;
using Veldrid.Sdl2;
using Veldrid.SPIRV;
using Veldrid.StartupUtilities;

// [assembly: CLSCompliant(true)]
// [assembly: InternalsVisibleTo(ILGPU.Context.RuntimeAssemblyName)]

public class Program
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Params
    {
        public Matrix4x4 view;
        public Matrix4x4 invProj;
        public Vector4 seed;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct World
    {
        public Sphere[] spheres;
        public MeshObject[] meshes;
        public MeshVertex[] meshVertices;
        public Vector4[] meshIndices;
        public uint SizeOf()
        {
            return (uint)(Unsafe.SizeOf<World>() + Unsafe.SizeOf<Sphere>() * spheres.Length);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Sphere
    {
        public Vector4 position;
        public Vector4 radius;
        public Vector4 albedo;
        public Vector4 specular;
        public Vector4 emission;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MeshObject
    {
        public Matrix4x4 model;
        public Matrix4x4 invModel;
        public Vector4 indices;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MeshVertex
    {
        public Vector4 position;
        public Vector4 normal;
        public Vector4 uv01;
    }

    public static void Main(string[] args)
    {
        Console.WriteLine("Begin");

        ModelRoot root = ModelRoot.Load("cube.glb");
        var node = root.LogicalNodes.FirstOrDefault(x => x.Mesh != null);
        var cam = root.LogicalNodes.FirstOrDefault(x => x.Camera != null);
        var light = root.LogicalNodes.FirstOrDefault(x => x.PunctualLight != null);
        var positions = node.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("POSITION").AsVector3Array()).ToArray();
        var normals = node.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("NORMAL").AsVector3Array()).ToArray();
        var uv0s = node.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("TEXCOORD_0").AsVector2Array()).ToArray();
        var uv1s = node.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("TEXCOORD_1").AsVector2Array()).ToArray();
        var indexes = node.Mesh.Primitives.SelectMany(x => x.GetTriangleIndices().SelectMany(x => new[] { x.A, x.B, x.C })).ToArray();
        var vertices = new MeshVertex[positions.Length];
        for (int i = 0; i < vertices.Length; i++)
        {
            vertices[i] = new MeshVertex()
            {
                position = new Vector4(positions[i], 1f),
                normal = new Vector4(normals[i], 1f),
                uv01 = new Vector4(uv0s[i].X, uv0s[i].Y, uv1s[i].X, uv1s[i].Y),
            };
        }

        WindowCreateInfo windowCI = new WindowCreateInfo()
        {
            WindowInitialState = WindowState.Hidden,
            WindowWidth = 100,
            WindowHeight = 100,
        };
        GraphicsDeviceOptions options = new GraphicsDeviceOptions()
        {
            HasMainSwapchain = false,
        };
        VeldridStartup.CreateWindowAndGraphicsDevice(windowCI, options, GraphicsBackend.Vulkan, out Sdl2Window window, out GraphicsDevice gd);

        {
            using var commandList = gd.ResourceFactory.CreateCommandList();

            string[] text = File.ReadAllLines("lightmap.glsl");
            for (int i = 0; i < text.Length; i++)
            {
                string tline = text[i].Trim();
                if (tline.StartsWith("#include \""))
                {
                    text[i] = File.ReadAllText(tline.Substring("#include \"".Length, tline.Length - "#include \"".Length - 1));
                }
            }

            var result = SpirvCompilation.CompileCompute(Encoding.UTF8.GetBytes(string.Join(Environment.NewLine, text)), CrossCompileTarget.GLSL);

            Matrix4x4.Invert(Matrix4x4.CreatePerspectiveFieldOfView(74f * MathF.PI / 180f, 1f, 0.1f, 1000f), out var invProj);
            // Matrix4x4.Invert(cam.Camera.Matrix, out var invProj);
            // Matrix4x4.Invert(Matrix4x4.CreateLookAt(new Vector3(0, 2, 5), new Vector3(0, 0, 0), -Vector3.UnitY), out var camView);
            Matrix4x4.Invert(cam.WorldMatrix, out var camView);
            camView = cam.WorldMatrix;
            camView = Matrix4x4.CreateScale(1f, -1f, 1f) * camView;
            Matrix4x4.Invert(node.WorldMatrix, out var invModel);
            var paramz = new Params()
            {
                view = camView,
                invProj = invProj,
                seed = new Vector4(Random.Shared.NextSingle()),
            };
            var world = new World()
            {
                spheres = new Sphere[]
                {
                    new Sphere()
                    {
                        position = new Vector4(light.WorldMatrix.Translation, 1f),
                        radius = Vector4.One * light.PunctualLight.Intensity,
                        albedo = new Vector4(light.PunctualLight.Color, 1f),
                        specular = new Vector4(light.PunctualLight.Color, 1f),
                        emission = new Vector4(light.PunctualLight.Color, 1f),
                    },
                },
                // spheres = new Sphere[0],
                /*spheres = new Sphere[]
                {
                    new Sphere()
                    {
                        position = new Vector4(0, 2, 0, 1),
                        radius = Vector4.One,
                        albedo = Vector4.One * 1f,
                        specular = Vector4.One * 1f,
                        emission = Vector4.One * 1f,
                    },
                },*/
                meshes = new MeshObject[]
                {
                    new MeshObject()
                    {
                        model = node.WorldMatrix,
                        invModel = invModel,
                        indices = new Vector4(0, indexes.Length, 0, 0),
                    },
                },
                meshVertices = vertices,
                meshIndices = indexes.Select(x => new Vector4(x)).ToArray(),
            };
            Console.WriteLine(Unsafe.SizeOf<World>());
            Console.WriteLine(Unsafe.SizeOf<Sphere>());

            using var shader = gd.ResourceFactory.CreateFromSpirv(new ShaderDescription(ShaderStages.Compute, Encoding.UTF8.GetBytes(result.ComputeShader), "main"));
            using var texture = gd.ResourceFactory.CreateTexture(TextureDescription.Texture2D(1024, 1024, 1, 1, PixelFormat.R8_G8_B8_A8_UNorm, TextureUsage.Storage));
            using var textureOut = gd.ResourceFactory.CreateTexture(TextureDescription.Texture2D(1024, 1024, 1, 1, PixelFormat.R8_G8_B8_A8_UNorm, TextureUsage.Storage));
            using var buffer1 = gd.ResourceFactory.CreateBuffer(new BufferDescription((uint)Unsafe.SizeOf<Params>(), BufferUsage.UniformBuffer));
            gd.UpdateBuffer(buffer1, 0, paramz);
            using var buffer2 = gd.ResourceFactory.CreateBuffer(new BufferDescription((uint)(world.spheres.Length * Unsafe.SizeOf<Sphere>()), BufferUsage.StructuredBufferReadOnly, (uint)Unsafe.SizeOf<Sphere>()));
            gd.UpdateBuffer(buffer2, 0, world.spheres);
            using var buffer10 = gd.ResourceFactory.CreateBuffer(new BufferDescription((uint)(world.meshes.Length * Unsafe.SizeOf<MeshObject>()), BufferUsage.StructuredBufferReadOnly, (uint)Unsafe.SizeOf<MeshObject>()));
            gd.UpdateBuffer(buffer10, 0, world.meshes);
            using var buffer11 = gd.ResourceFactory.CreateBuffer(new BufferDescription((uint)(world.meshVertices.Length * Unsafe.SizeOf<MeshVertex>()), BufferUsage.StructuredBufferReadOnly, (uint)Unsafe.SizeOf<MeshVertex>()));
            gd.UpdateBuffer(buffer11, 0, world.meshVertices);
            using var buffer12 = gd.ResourceFactory.CreateBuffer(new BufferDescription((uint)(world.meshIndices.Length * Unsafe.SizeOf<Vector4>()), BufferUsage.StructuredBufferReadOnly, (uint)Unsafe.SizeOf<Vector4>()));
            gd.UpdateBuffer(buffer12, 0, world.meshIndices);

            BindableResource[][] resources = new BindableResource[][]
            {
                new BindableResource[] { texture, buffer1, buffer2, buffer10, buffer11, buffer12, textureOut },
            };
            List<ResourceLayout> layouts = new List<ResourceLayout>();
            List<ResourceSet> sets = new List<ResourceSet>();
            for (int i = 0; i < result.Reflection.ResourceLayouts.Length; i++)
            {
                var layout = gd.ResourceFactory.CreateResourceLayout(result.Reflection.ResourceLayouts[i]);
                var set = gd.ResourceFactory.CreateResourceSet(new ResourceSetDescription(layout, resources[i]));
                layouts.Add(layout);
                sets.Add(set);
            }
            using var pipeline = gd.ResourceFactory.CreateComputePipeline(new ComputePipelineDescription(shader, layouts.ToArray(), 16, 16, 1));
            // using var pipeline = gd.ResourceFactory.CreateComputePipeline(new ComputePipelineDescription(shader, layouts.ToArray(), 16, 1, 1));

            Console.WriteLine("Middle");

            // while (window.Exists)
            {
                commandList.Begin();
                commandList.SetPipeline(pipeline);
                for (int i = 0; i < sets.Count; i++)
                    commandList.SetComputeResourceSet((uint)i, sets[i]);
                // commandList.Dispatch(texture.Width / 16, texture.Height / 16, 1);
                commandList.Dispatch(textureOut.Width / 16, textureOut.Height / 16, 1);
                // commandList.Dispatch(textureOut.Width / 32, textureOut.Height / 32, 1);
                // commandList.Dispatch((uint)(world.meshes.Length / 16), 1, 1);
                commandList.End();
                gd.SubmitCommands(commandList);
                gd.WaitForIdle();
                // window.PumpEvents();
            }

            {
                using var mapTexture = gd.ResourceFactory.CreateTexture(TextureDescription.Texture2D(texture.Width, texture.Height, 1, 1, PixelFormat.R8_G8_B8_A8_UNorm, TextureUsage.Staging));
                commandList.Begin();
                commandList.CopyTexture(texture, mapTexture);
                commandList.End();
                gd.SubmitCommands(commandList);
                gd.WaitForIdle();

                var view = gd.Map<Rgba32>(mapTexture, MapMode.Read);
                Rgba32[] data = new Rgba32[view.Count];
                for (int i = 0; i < view.Count; i++)
                {
                    data[i] = view[i];
                }
                gd.Unmap(mapTexture);
                using var img = SixLabors.ImageSharp.Image.LoadPixelData<Rgba32>(data, (int)mapTexture.Width, (int)mapTexture.Height);
                using FileStream fs = File.OpenWrite("tex.png");
                img.SaveAsPng(fs);
            }

            {
                using var mapTexture = gd.ResourceFactory.CreateTexture(TextureDescription.Texture2D(textureOut.Width, textureOut.Height, 1, 1, PixelFormat.R8_G8_B8_A8_UNorm, TextureUsage.Staging));
                commandList.Begin();
                commandList.CopyTexture(textureOut, mapTexture);
                commandList.End();
                gd.SubmitCommands(commandList);
                gd.WaitForIdle();

                var view = gd.Map<Rgba32>(mapTexture, MapMode.Read);
                Rgba32[] data = new Rgba32[view.Count];
                for (int i = 0; i < view.Count; i++)
                {
                    data[i] = view[i];
                }
                gd.Unmap(mapTexture);
                using var img = SixLabors.ImageSharp.Image.LoadPixelData<Rgba32>(data, (int)mapTexture.Width, (int)mapTexture.Height);
                using FileStream fs = File.OpenWrite("outTex.png");
                img.SaveAsPng(fs);
            }

            for (int i = 0; i < layouts.Count; i++)
            {
                layouts[i].Dispose();
            }
            for (int i = 0; i < sets.Count; i++)
            {
                sets[i].Dispose();
            }
        }
        gd.Dispose();
        Console.WriteLine("End");
    }
}