# OpenCL: run on devices that refuse a profiling queue

Not for merge as it stands; this directory is notes and logs only. The fix itself is the commit below it
(`rc5-72/opencl: run on devices that refuse a profiling queue`), based on dcti master c4c96931.

## Problem

The OpenCL client always creates its command queue with `CL_QUEUE_PROFILING_ENABLE`
(`rc5-72/opencl/ocl_ref.cpp` and `ocl_1pipe.cpp`, unchanged since the first OpenCL commit 2c71f424 of 2012).
It uses the kernel start and end times only to tune the run size.

On a Raspberry Pi 4 (V3D 4.2.14.0, Mesa rusticl 26.2.7, `RUSTICL_ENABLE=v3d`) `-gpuinfo` works, but `-test`,
`-stress` and `-bench` all stop with:

    Error creating command queue on device 0
    Error code -35, message: Invalid queue properties

Log: `logs/opencl-rpi4-20261122-1145.txt`

## Cause

- Mesa rusticl accepts a profiling queue only when the Gallium driver has a timestamp query and a non-zero
  timer resolution (`has_timestamp` in rusticl `core/device.rs`, checked in `api/queue.rs`; Mesa commit
  66737599 of 2023-08-29, "rusticl/event: disable profiling for devices without timestamps").
- V3D never sets a timer resolution (`-gpuinfo` shows "Device timer resolution (ns): 0"), so the queue is
  refused with `CL_INVALID_QUEUE_PROPERTIES`.
- Rusticl still lists profiling in `CL_DEVICE_QUEUE_ON_HOST_PROPERTIES`, so only trying the queue tells.
- The OpenCL specification names `CL_QUEUE_PROFILING_ENABLE` as the mandated minimum capability.

## Fix

- If the profiling queue is refused with `CL_INVALID_QUEUE_PROPERTIES`, create the queue without profiling
  and record that in the device context (`gpuProfiling = false`).
- Without profiling, the cores take the kernel start and end times from the host clock through
  `OCLGetHostProfilingInfo()`, which has the same parameters and return values as `clGetEventProfilingInfo()`
  and uses `CliGetMonotonicClock()`.
- The same `startTime` and `endTime` variables feed the run size controller, which is unchanged.
- Devices that accept profiling take the same path as before.

## Devices that refuse profiling (Mesa 26.2 source)

- Always: v3d (Raspberry Pi 4 and 5), nouveau nv50, virgl, svga, d3d12.
- Depending on the kernel: panfrost, freedreno, r600, zink.
- Not affected: radeonsi, iris, crocus, nouveau nvc0, asahi, llvmpipe.
- Outside Mesa nothing was found that refuses it.

## Testing

- Raspberry Pi 4, real V3D (run by skralg), log `logs/opencl-rpi4-20261122-1627.txt`:
  - `-test`: 32/32 on all four cores.
  - `-bench`: CL ANSI 1-pipe 646,577; CL 1-pipe 6,416,803; CL 2-pipe 3,825,147; CL 4-pipe 3,418,877 keys/sec.
  - `-stress`: tests 1 to 3 passed on core 0; the run was then stopped by the script's 600 second limit during
    test 4, which needs about 22 minutes on core 0 at that rate. Not yet run to completion.
- Fallback forced on an RTX 5060 Ti and on PoCL (Linux amd64): `-test` and `-stress` pass.
- Normal profiling path on PoCL in CI: Windows ARM64 (MSVC), Linux amd64 and Linux arm64 build without new
  warnings and pass `-test` on all four cores.
