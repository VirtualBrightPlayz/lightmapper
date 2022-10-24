using System.Numerics;
using ILGPU;
using ILGPU.Runtime;
using ILGPU.Runtime.CPU;
using ILGPU.Runtime.Cuda;
using ILGPU.Runtime.OpenCL;

public class RaytraceKernel
{
    private static Context context;
    private static Accelerator accelerator;
    public static System.Action<Index2D, ArrayView<int>> kernel;

    private static void KernelMain(Index2D index, ArrayView<int> data)
    {
        Matrix4x4 proj = Matrix4x4.CreatePerspectiveFieldOfView(90f, 1f, 0.01f, 1000f);
        Matrix4x4 view = Matrix4x4.CreateLookAt(new Vector3(0, 0, -1), Vector3.Zero, Vector3.UnitY);
    }

    public static void CompileGPU()
    {
        context = Context.CreateDefault();
        accelerator = context.CreateCLAccelerator(0);


        kernel = accelerator.LoadAutoGroupedStreamKernel<Index2D, ArrayView<int>>(KernelMain);
    }

    public static void Dispose()
    {
        accelerator.Dispose();
        context.Dispose();
    }

    public static void RunGPU(int[] buffer, int width, int height, int max_samples)
    {
        var dev_out = accelerator.Allocate1D<int>(buffer.LongLength);
    }
}