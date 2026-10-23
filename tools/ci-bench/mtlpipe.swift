// mtlpipe.swift: compile a Metal compute kernel at run time, create its
// pipeline, print the pipeline statistics the runtime exposes, and write a
// binary archive holding the compiled GPU code.
//
// usage: mtlpipe kernel.metal function out.archive [extra compiler -D flags]
//
// Used by tools/ci-bench/ci-macos-arm64.sh. Build with
//   swiftc -O -o mtlpipe mtlpipe.swift
import Foundation
import Metal

let args = CommandLine.arguments
if args.count < 4 {
  FileHandle.standardError.write("usage: mtlpipe kernel.metal function out.archive [-DNAME=1 ...]\n".data(using: .utf8)!)
  exit(1)
}

guard let device = MTLCreateSystemDefaultDevice() else {
  print("no Metal device")
  exit(2)
}
print("device: \(device.name)")
print("  registryID: \(device.registryID)")
print("  maxThreadsPerThreadgroup: \(device.maxThreadsPerThreadgroup)")
print("  supportsFamily apple7: \(device.supportsFamily(.apple7))")
print("  supportsFamily apple8: \(device.supportsFamily(.apple8))")
print("  supportsFamily apple9: \(device.supportsFamily(.apple9))")

var source: String
do {
  source = try String(contentsOfFile: args[1], encoding: .utf8)
} catch {
  print("cannot read \(args[1]): \(error)")
  exit(1)
}

let options = MTLCompileOptions()
var macros: [String: NSObject] = [:]
for arg in args.dropFirst(4) {
  if arg.hasPrefix("-D") {
    let def = arg.dropFirst(2)
    let parts = def.split(separator: "=", maxSplits: 1)
    let name = String(parts[0])
    let value = parts.count > 1 ? String(parts[1]) : "1"
    macros[name] = value as NSString
  }
}
if !macros.isEmpty {
  options.preprocessorMacros = macros
  print("  macros: \(macros)")
}

let library: MTLLibrary
do {
  library = try device.makeLibrary(source: source, options: options)
} catch {
  print("makeLibrary failed: \(error)")
  exit(3)
}

guard let function = library.makeFunction(name: args[2]) else {
  print("function \(args[2]) not found")
  exit(3)
}

let descriptor = MTLComputePipelineDescriptor()
descriptor.computeFunction = function
descriptor.label = args[2]

// binary archive first: it holds the compiled code for this device
do {
  let archive = try device.makeBinaryArchive(descriptor: MTLBinaryArchiveDescriptor())
  try archive.addComputePipelineFunctions(descriptor: descriptor)
  try archive.serialize(to: URL(fileURLWithPath: args[3]))
  print("binary archive: \(args[3])")
} catch {
  print("binary archive failed: \(error)")
}

do {
  let pipeline = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
  print("pipeline:")
  print("  maxTotalThreadsPerThreadgroup: \(pipeline.maxTotalThreadsPerThreadgroup)")
  print("  threadExecutionWidth: \(pipeline.threadExecutionWidth)")
  print("  staticThreadgroupMemoryLength: \(pipeline.staticThreadgroupMemoryLength)")
} catch {
  print("makeComputePipelineState failed: \(error)")
  exit(4)
}
