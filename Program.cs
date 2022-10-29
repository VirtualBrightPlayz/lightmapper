using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using SharpGLTF.Schema2;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.PixelFormats;
using Veldrid;
using Veldrid.Sdl2;
using Veldrid.SPIRV;
using Veldrid.StartupUtilities;

public class Program
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Params
    {
        public Matrix4x4 view;
        public Matrix4x4 invProj;
        public Vector4 seed;
        public Vector4 offsetPixels;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct World
    {
        public Sphere[] spheres;
        public MeshObject[] meshes;
        public MeshVertex[] meshVertices;
        public Vector4[] meshIndices;
        public PointLightObject[] lights;
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
    public struct PointLightObject
    {
        public Vector4 position;
        public Vector4 color;
        public Vector4 data;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MeshVertex
    {
        public Vector4 position;
        public Vector4 normal;
        public Vector4 uv01;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Vertex
    {
        public Vector2 position;
        public Vector2 uv;
    }

    public record ExternalLightData(float size);

    public static void Main(string[] args)
    {
        uint samples = 4;
        uint texSize = 512;
        uint baseTexSize = 64;

        string file = "cube.glb";
        string fileOut = "out.png";
        string renderOnly = "";
        string localPath = Path.Combine(typeof(Program).Assembly.Location, "..");
        localPath = Directory.GetCurrentDirectory();
        for (int i = 0; i < args.Length - 1; i++)
        {
            if (args[i].ToLower().Equals("-in"))
            {
                file = args[i + 1];
            }
            if (args[i].ToLower().Equals("-out"))
            {
                fileOut = args[i + 1];
            }
            if (args[i].ToLower().Equals("-render"))
            {
                renderOnly = args[i + 1];
            }
            if (args[i].ToLower().Equals("-samples"))
            {
                samples = uint.Parse(args[i + 1]);
            }
            if (args[i].ToLower().Equals("-texsize"))
            {
                texSize = uint.Parse(args[i + 1]);
            }
            if (args[i].ToLower().Equals("-basetexsize"))
            {
                baseTexSize = uint.Parse(args[i + 1]);
            }
        }

        Console.WriteLine("Begin");
        ModelRoot root = ModelRoot.Load(file);
        // var thing = root.LogicalNodes.Where(x => x.Mesh != null).SelectMany(x => x.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("POSITION").AsVector3Array())).ToArray();
        // var node = root.LogicalNodes.FirstOrDefault(x => x.Mesh != null);
        // var cam = root.LogicalNodes.FirstOrDefault(x => x.Camera != null);
        // var light = root.LogicalNodes.FirstOrDefault(x => x.PunctualLight != null);
        // var positions = node.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("POSITION").AsVector3Array()).ToArray();
        // var normals = node.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("NORMAL").AsVector3Array()).ToArray();
        // var uv0s = node.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("TEXCOORD_0").AsVector2Array()).ToArray();
        // var uv1s = node.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("TEXCOORD_1").AsVector2Array()).ToArray();
        // var indexes = node.Mesh.Primitives.SelectMany(x => x.GetTriangleIndices().SelectMany(x => new[] { x.A, x.B, x.C })).ToArray();
        var world = new World()
        {
            spheres = new Sphere[0],
            meshes = new MeshObject[0],
            meshVertices = new MeshVertex[0],
            meshIndices = new Vector4[0],
            lights = new PointLightObject[0],
        };
        {
            List<Sphere> spheres = new List<Sphere>();
            List<MeshObject> objects = new List<MeshObject>();
            List<MeshVertex> vertices = new List<MeshVertex>();
            List<Vector4> indexes = new List<Vector4>();
            List<PointLightObject> lights = new List<PointLightObject>();

            foreach (var node in root.LogicalNodes.Where(x => x.Mesh != null))
            {
                var positions = node.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("POSITION").AsVector3Array()).ToArray();
                var normals = node.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("NORMAL").AsVector3Array()).ToArray();
                var uv0s = node.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("TEXCOORD_0").AsVector2Array()).ToArray();
                var uv1s = node.Mesh.Primitives.SelectMany(x => x.GetVertexAccessor("TEXCOORD_1").AsVector2Array()).ToArray();
                var inds = node.Mesh.Primitives.SelectMany(x => x.GetTriangleIndices().SelectMany(x => new[] { x.A, x.B, x.C })).Select(x => new Vector4(x + vertices.Count)).ToArray();

                for (int i = 0; i < positions.Length; i++)
                {
                    vertices.Add(new MeshVertex()
                    {
                        position = new Vector4(positions[i], 1f),
                        normal = new Vector4(normals[i], 1f),
                        uv01 = new Vector4(uv0s[i].X, uv0s[i].Y, uv1s[i].X, uv1s[i].Y),
                    });
                }
                Matrix4x4.Invert(node.WorldMatrix, out var invModel);
                objects.Add(new MeshObject()
                {
                    model = node.WorldMatrix,
                    invModel = invModel,
                    indices = new Vector4(indexes.Count, inds.Length, !string.IsNullOrEmpty(renderOnly) && node.Mesh.Name != renderOnly ? 0 : 1, 0),
                });
                indexes.AddRange(inds);
            }

            foreach (var node in root.LogicalNodes.Where(x => x.PunctualLight != null))
            {
                ExternalLightData data = new ExternalLightData(0.01f);
                try
                {
                    data = node.PunctualLight.Extras.Deserialize<ExternalLightData>();
                }
                catch
                { }
                lights.Add(new PointLightObject()
                {
                    position = new Vector4(node.WorldMatrix.Translation, node.PunctualLight.Range),
                    color = new Vector4(node.PunctualLight.Color, node.PunctualLight.Intensity),
                    data = new Vector4(data.size),
                });
                spheres.Add(new Sphere()
                {
                    position = new Vector4(node.WorldMatrix.Translation, 1),
                    radius = new Vector4(data.size),
                    emission = new Vector4(node.PunctualLight.Color, 1),
                });
            }

            world.meshes = objects.ToArray();
            world.meshVertices = vertices.ToArray();
            world.meshIndices = indexes.ToArray();
            world.lights = lights.ToArray();
            // world.spheres = spheres.ToArray();
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

            string[] text = File.ReadAllLines(Path.Combine(localPath, "lightmap.glsl"));
            for (int i = 0; i < text.Length; i++)
            {
                string tline = text[i].Trim();
                if (tline.StartsWith("#include \""))
                {
                    text[i] = File.ReadAllText(Path.Combine(localPath, tline.Substring("#include \"".Length, tline.Length - "#include \"".Length - 1)));
                }
            }

            var result = SpirvCompilation.CompileCompute(Encoding.UTF8.GetBytes(string.Join(Environment.NewLine, text)), CrossCompileTarget.GLSL);
            var result2 = SpirvCompilation.CompileVertexFragment(Encoding.UTF8.GetBytes(File.ReadAllText(Path.Combine(localPath, "add.vert"))), Encoding.UTF8.GetBytes(File.ReadAllText(Path.Combine(localPath, "add.frag"))), CrossCompileTarget.GLSL, new CrossCompileOptions(gd.BackendType == GraphicsBackend.OpenGL, gd.BackendType == GraphicsBackend.Vulkan));

            Matrix4x4.Invert(Matrix4x4.CreatePerspectiveFieldOfView(90f * MathF.PI / 180f, 1f, 0.1f, 1000f), out var invProj);
            Matrix4x4.Invert(Matrix4x4.CreateLookAt(new Vector3(0, 2, 5), new Vector3(0, 0, 0), Vector3.UnitY), out var camView);
            // if (cam != null)
            {
                // Matrix4x4.Invert(cam.Camera.Matrix, out invProj);
                // Matrix4x4.Invert(cam.WorldMatrix, out camView);
                // camView = cam.WorldMatrix;
            }
            camView = Matrix4x4.CreateScale(1f, -1f, 1f) * camView;
            var paramz = new Params()
            {
                view = camView,
                invProj = invProj,
                seed = Vector4.Zero,
            };

            // compute setup
            using var shader = gd.ResourceFactory.CreateFromSpirv(new ShaderDescription(ShaderStages.Compute, Encoding.UTF8.GetBytes(result.ComputeShader), "main"));
            using var texture = gd.ResourceFactory.CreateTexture(TextureDescription.Texture2D(texSize, texSize, 1, 1, PixelFormat.R8_G8_B8_A8_UNorm, TextureUsage.Storage | TextureUsage.Sampled));
            using var textureOut = gd.ResourceFactory.CreateTexture(TextureDescription.Texture2D(texSize, texSize, 1, 1, PixelFormat.R8_G8_B8_A8_UNorm, TextureUsage.Storage | TextureUsage.Sampled));
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
            using var buffer13 = gd.ResourceFactory.CreateBuffer(new BufferDescription((uint)(world.lights.Length * Unsafe.SizeOf<PointLightObject>()), BufferUsage.StructuredBufferReadOnly, (uint)Unsafe.SizeOf<PointLightObject>()));
            gd.UpdateBuffer(buffer13, 0, world.lights);

            BindableResource[][] resources = new BindableResource[][]
            {
                new BindableResource[] { texture, buffer1, buffer2, buffer10, buffer11, buffer12, buffer13, textureOut },
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


            // gfx setup
            using var shader2Vert = gd.ResourceFactory.CreateFromSpirv(new ShaderDescription(ShaderStages.Vertex, Encoding.UTF8.GetBytes(File.ReadAllText(Path.Combine(localPath, "add.vert"))), "main"));
            using var shader2Frag = gd.ResourceFactory.CreateFromSpirv(new ShaderDescription(ShaderStages.Fragment, Encoding.UTF8.GetBytes(File.ReadAllText(Path.Combine(localPath, "add.frag"))), "main"));
            using var vertexBuffer = gd.ResourceFactory.CreateBuffer(new BufferDescription((uint)Unsafe.SizeOf<Vertex>() * 4, BufferUsage.VertexBuffer));
            gd.UpdateBuffer(vertexBuffer, 0, new Vertex[]
            {
                new Vertex()
                {
                    position = new Vector2(-1, 1),
                    uv = new Vector2(0, 1),
                },
                new Vertex()
                {
                    position = new Vector2(1, 1),
                    uv = new Vector2(1, 1),
                },
                new Vertex()
                {
                    position = new Vector2(-1, -1),
                    uv = new Vector2(0, 0),
                },
                new Vertex()
                {
                    position = new Vector2(1, -1),
                    uv = new Vector2(1, 0),
                },
            });
            using var indexBuffer = gd.ResourceFactory.CreateBuffer(new BufferDescription((uint)Unsafe.SizeOf<ushort>() * 4, BufferUsage.IndexBuffer));
            gd.UpdateBuffer(indexBuffer, 0, new ushort[]
            {
                0,
                1,
                2,
                3,
            });
            using var addBuffer1 = gd.ResourceFactory.CreateBuffer(new BufferDescription((uint)Unsafe.SizeOf<Vector4>(), BufferUsage.UniformBuffer));
            gd.UpdateBuffer(addBuffer1, 0, new Vector4(0, 0, textureOut.Width, textureOut.Height));
            using var gfxTexture = gd.ResourceFactory.CreateTexture(TextureDescription.Texture2D(textureOut.Width, textureOut.Height, 1, 1, PixelFormat.R8_G8_B8_A8_UNorm, TextureUsage.RenderTarget));
            using var gfxFramebuffer = gd.ResourceFactory.CreateFramebuffer(new FramebufferDescription(null, gfxTexture));
            using var gfxSampler = gd.ResourceFactory.CreateSampler(SamplerDescription.Point);

            BindableResource[][] gfxResources = new BindableResource[][]
            {
                new BindableResource[] { textureOut, gfxSampler, addBuffer1, texture },
            };
            List<ResourceLayout> gfxLayouts = new List<ResourceLayout>();
            List<ResourceSet> gfxSets = new List<ResourceSet>();
            for (int i = 0; i < result.Reflection.ResourceLayouts.Length; i++)
            {
                var layout = gd.ResourceFactory.CreateResourceLayout(result2.Reflection.ResourceLayouts[i]);
                var set = gd.ResourceFactory.CreateResourceSet(new ResourceSetDescription(layout, gfxResources[i]));
                gfxLayouts.Add(layout);
                gfxSets.Add(set);
            }
            using var gfxPipeline = gd.ResourceFactory.CreateGraphicsPipeline(new GraphicsPipelineDescription(BlendStateDescription.SingleAlphaBlend,
            DepthStencilStateDescription.Disabled,
            RasterizerStateDescription.CullNone,
            PrimitiveTopology.TriangleStrip,
            new ShaderSetDescription(new[] { new VertexLayoutDescription(result2.Reflection.VertexElements) }, new[] { shader2Vert, shader2Frag }), gfxLayouts.ToArray(), gfxFramebuffer.OutputDescription));

            Console.WriteLine("Middle");

            // while (window.Exists)
            for (int k = 0; k < samples; k++)
            {
                // Thread.Sleep(100);
                try
                {
                    if (Console.KeyAvailable)
                    {
                        Console.ReadKey();
                        break;
                    }
                }
                catch
                { }
                paramz.seed = new Vector4(Random.Shared.NextSingle());

                commandList.Begin();
                commandList.SetPipeline(pipeline);
                commandList.UpdateBuffer(buffer1, 0, paramz);
                for (int i = 0; i < sets.Count; i++)
                    commandList.SetComputeResourceSet((uint)i, sets[i]);
                commandList.End();
                gd.SubmitCommands(commandList);
                gd.WaitForIdle();

                int l = 0;
                for (int i = 0; i <= textureOut.Width; i+=(int)baseTexSize)
                {
                    for (int i2 = 0; i2 <= textureOut.Height; i2+=(int)baseTexSize)
                    {
                        commandList.Begin();
                        commandList.SetPipeline(pipeline);
                        for (int j = 0; j < sets.Count; j++)
                            commandList.SetComputeResourceSet((uint)j, sets[j]);
                        commandList.Dispatch(baseTexSize / 8, baseTexSize / 8, (uint)world.meshes.Length);
                        var paramz2 = paramz;
                        paramz2.offsetPixels = new Vector4(i, i2, 0, 0);
                        // commandList.UpdateBuffer(buffer1, (uint)(Unsafe.SizeOf<Matrix4x4>() * 2 + Unsafe.SizeOf<Vector4>() * 1), paramz2.offsetPixels);
                        commandList.UpdateBuffer(buffer1, 0, paramz2);
                        commandList.End();
                        gd.SubmitCommands(commandList);
                        gd.WaitForIdle();
                        // Thread.Sleep(25);
                        // Console.WriteLine($"Render ({l})({i},{i2}) Done");
                        // Console.Out.Flush();
                        l++;
                    }
                }

                commandList.Begin();
                commandList.SetFramebuffer(gfxFramebuffer);
                commandList.SetPipeline(gfxPipeline);

                if (k == 0)
                {
                    commandList.ClearColorTarget(0, RgbaFloat.Black);
                }
                else
                {
                }
                commandList.UpdateBuffer(addBuffer1, 0, new Vector4(k, 0, textureOut.Width, textureOut.Height));

                for (int i = 0; i < gfxSets.Count; i++)
                    commandList.SetGraphicsResourceSet((uint)i, gfxSets[i]);
                commandList.SetVertexBuffer(0, vertexBuffer);
                commandList.SetIndexBuffer(indexBuffer, IndexFormat.UInt16);
                commandList.DrawIndexed(4);

                commandList.CopyTexture(gfxTexture, textureOut);

                commandList.End();
                gd.SubmitCommands(commandList);
                gd.WaitForIdle();
                Thread.Sleep(25);
                Console.WriteLine($"Sample {k+1}/{samples} Done");
                Console.Out.Flush();
                // Thread.Sleep(100);
                // window.PumpEvents();
            }

            /*
            commandList.Begin();
            commandList.SetFramebuffer(gfxFramebuffer);
            commandList.SetPipeline(gfxPipeline);
            
            gd.UpdateBuffer(addBuffer1, 0, new Vector4(samples, 0, textureOut.Width, textureOut.Height));

            for (int i = 0; i < gfxSets.Count; i++)
                commandList.SetGraphicsResourceSet((uint)i, gfxSets[i]);
            commandList.SetVertexBuffer(0, vertexBuffer);
            commandList.SetIndexBuffer(indexBuffer, IndexFormat.UInt16);
            commandList.DrawIndexed(4);

            commandList.CopyTexture(gfxTexture, textureOut);

            commandList.End();
            gd.SubmitCommands(commandList);
            gd.WaitForIdle();
            */

            {
                using var mapTexture = gd.ResourceFactory.CreateTexture(TextureDescription.Texture2D(gfxTexture.Width, gfxTexture.Height, 1, 1, PixelFormat.R8_G8_B8_A8_UNorm, TextureUsage.Staging));
                commandList.Begin();
                commandList.CopyTexture(gfxTexture, mapTexture);
                commandList.End();
                gd.SubmitCommands(commandList);
                gd.WaitForIdle();

                var view = gd.Map<Rgba32>(mapTexture, MapMode.Read);
                Rgba32[] data = new Rgba32[view.Count];
                for (int i = 0; i < view.Count; i++)
                {
                    data[i] = view[i];
                    data[i].A = 255;
                }
                gd.Unmap(mapTexture);
                using var img = SixLabors.ImageSharp.Image.LoadPixelData<Rgba32>(data, (int)mapTexture.Width, (int)mapTexture.Height);
                using FileStream fs = File.OpenWrite(fileOut);
                img.SaveAsPng(fs);
            }

            // /*
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
                    data[i].A = 255;
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
                    data[i].A = 255;
                }
                gd.Unmap(mapTexture);
                using var img = SixLabors.ImageSharp.Image.LoadPixelData<Rgba32>(data, (int)mapTexture.Width, (int)mapTexture.Height);
                using FileStream fs = File.OpenWrite("outTex.png");
                img.SaveAsPng(fs);
            }

            {
                using var mapTexture = gd.ResourceFactory.CreateTexture(TextureDescription.Texture2D(gfxTexture.Width, gfxTexture.Height, 1, 1, PixelFormat.R8_G8_B8_A8_UNorm, TextureUsage.Staging));
                commandList.Begin();
                commandList.CopyTexture(gfxTexture, mapTexture);
                commandList.End();
                gd.SubmitCommands(commandList);
                gd.WaitForIdle();

                var view = gd.Map<Rgba32>(mapTexture, MapMode.Read);
                Rgba32[] data = new Rgba32[view.Count];
                for (int i = 0; i < view.Count; i++)
                {
                    data[i] = view[i];
                    data[i].A = 255;
                }
                gd.Unmap(mapTexture);
                using var img = SixLabors.ImageSharp.Image.LoadPixelData<Rgba32>(data, (int)mapTexture.Width, (int)mapTexture.Height);
                using FileStream fs = File.OpenWrite("gfxTex.png");
                img.SaveAsPng(fs);
            }
            // */

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