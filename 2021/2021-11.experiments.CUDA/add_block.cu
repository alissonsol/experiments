// Based on "An Even Easier Introduction to CUDA", by Mark Harris
// https://developer.nvidia.com/blog/even-easier-introduction-cuda/

#include <iostream>
#include <math.h>

// Kernel function to add the elements of two arrays
__global__
void add(int n, float *x, float *y)
{
  int index = threadIdx.x;
  int stride = blockDim.x;
  for (int i = index; i < n; i += stride)
      y[i] = x[i] + y[i];
}

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

int main(int argc, char *argv[])
{
  int p = 6;
  if (argc == 2)
  {
      p = atoi(argv[1]);
  }
  long N = pow(10, p);
  long size = N*sizeof(float);
  std::cout << "N: " << N << std::endl;

  float *x, *y;

  // Allocate Unified Memory – accessible from CPU or GPU
  gpuErrchk(cudaMallocManaged(&x, size));
  gpuErrchk(cudaMallocManaged(&y, size));

  // initialize x and y arrays on the host
  for (int i = 0; i < N; i++) {
    x[i] = 1.0f;
    y[i] = 2.0f;
  }

  // Run kernel on N elements on the GPU
  add<<<1, 256>>>(N, x, y);

  // Wait for GPU to finish before accessing on host
  gpuAssert(cudaDeviceSynchronize());

  // Check for errors (all values should be 3.0f)
  float maxError = 0.0f;
  for (int i = 0; i < N; i++)
    maxError = fmax(maxError, fabs(y[i]-3.0f));
  std::cout << "Max error: " << maxError << std::endl;

  // Free memory
  gpuAssert(cudaFree(x));
  gpuAssert(cudaFree(y));
  
  return 0;
}