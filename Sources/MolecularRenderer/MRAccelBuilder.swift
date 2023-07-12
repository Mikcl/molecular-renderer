//
//  MRAccelBuilder.swift
//  MolecularRenderer
//
//  Created by Philip Turner on 6/17/23.
//

import Metal
import simd

public class MRAccelBuilder {
  // Main rendering resources.
  var device: MTLDevice
  var commandQueue: MTLCommandQueue
  var atoms: [MRAtom] = []
  var styles: [MRAtomStyle] = []
  
  // Triple buffer because the CPU writes to these.
  var atomBuffers: [MTLBuffer?] = Array(repeating: nil, count: 3)
  
  // Data for uniform grids.
  var denseGridAtoms: [MTLBuffer?] = [nil, nil, nil]
  var ringIndex: Int = 0
  var denseGridData: MTLBuffer?
  var denseGridCounters: MTLBuffer?
  var denseGridReferences: MTLBuffer?
  var globalCounterBuffer: MTLBuffer
  
  // Pipeline state objects.
  var memsetPipeline: MTLComputePipelineState
  var densePass1Pipeline: MTLComputePipelineState
  var densePass2Pipeline: MTLComputePipelineState
  var densePass3Pipeline: MTLComputePipelineState
  
  // Keep track of memory sizes for exponential expansion.
  var maxAtomBufferSize: Int = 1 << 10
  var maxAtoms: Int = 1 << 1
  var maxGridSlots: Int = 1 << 1
  var maxGridCells: Int = 1 << 1
  var maxGridReferences: Int = 1 << 1
  var gridWidth: Int = 0
  
  // Indices into ring buffers of memory objects.
  var atomBufferIndex: Int = 0 // modulo 3
  
  public init(
    device: MTLDevice,
    commandQueue: MTLCommandQueue,
    library: MTLLibrary
  ) {
    self.device = device
    self.commandQueue = commandQueue
    
    let constants = MTLFunctionConstantValues()
    var pattern4: UInt32 = 0
    constants.setConstantValue(&pattern4, type: .uint, index: 10)
    
    let memsetFunction = try! library.makeFunction(
      name: "memset_pattern4", constantValues: constants)
    self.memsetPipeline = try! device
      .makeComputePipelineState(function: memsetFunction)
    
    let densePass1Function = library.makeFunction(name: "dense_grid_pass1")!
    self.densePass1Pipeline = try! device
      .makeComputePipelineState(function: densePass1Function)
    
    let densePass2Function = library.makeFunction(name: "dense_grid_pass2")!
    self.densePass2Pipeline = try! device
      .makeComputePipelineState(function: densePass2Function)
    
    let densePass3Function = library.makeFunction(name: "dense_grid_pass3")!
    self.densePass3Pipeline = try! device
      .makeComputePipelineState(function: densePass3Function)
    
    self.globalCounterBuffer = device.makeBuffer(length: 4)!
  }
}

extension MRAccelBuilder {
  // The entire process of fetching, resizing, and nil-coalescing.
  func cycle(
    from buffers: inout [MTLBuffer?],
    index: inout Int,
    currentSize: inout Int,
    desiredSize: Int,
    name: String
  ) -> MTLBuffer {
    var resource = fetch(from: buffers, size: desiredSize, index: index)
    if resource == nil {
      resource = create(
        currentSize: &currentSize, desiredSize: desiredSize, {
          $0.makeBuffer(length: $1)
        })
      resource!.label = name
    }
    guard let resource else { fatalError("This should never happen.") }
    append(resource, to: &buffers, index: &index)
    return resource
  }
  
  func fetch<T: MTLResource>(
    from buffers: [T?],
    size: Int,
    index: Int
  ) -> T? {
    guard let buffer = buffers[index] else {
      return nil
    }
    if buffer.allocatedSize < size {
      return nil
    }
    return buffer
  }
  
  func create<T: MTLResource>(
    currentSize: inout Int,
    desiredSize: Int,
    _ closure: (MTLDevice, Int) -> T?
  ) -> T {
    while currentSize < desiredSize {
      currentSize = currentSize << 1
    }
    guard let output = closure(self.device, currentSize) else {
      fatalError(
        "Could not create object of type \(T.self) with size \(currentSize).")
    }
    return output
  }
  
  func append<T: MTLResource>(
    _ object: T,
    to buffers: inout [T?],
    index: inout Int
  ) {
    buffers[index] = object
    index = (index + 1) % buffers.count
  }
}

extension MRAccelBuilder {
  // Only call this once per frame.
  internal func build() {
    // Generate or fetch a buffer.
    let atomSize = MemoryLayout<MRAtom>.stride
    let atomBufferSize = atoms.count * atomSize
    precondition(atomSize == 16, "Unexpected atom size.")
    let atomBuffer = cycle(
      from: &atomBuffers,
      index: &atomBufferIndex,
      currentSize: &maxAtomBufferSize,
      desiredSize: atomBufferSize,
      name: "Atoms")
    
    // Write the buffer's contents.
    do {
      let atomsPointer = atomBuffer.contents()
        .assumingMemoryBound(to: MRAtom.self)
      for (index, atom) in atoms.enumerated() {
        atomsPointer[index] = atom
      }
    }
  }
}

fileprivate func denseGridStatistics(
  atoms: [MRAtom],
  styles: [MRAtomStyle]
) -> (boundingBox: MRBoundingBox, references: Int) {
  precondition(atoms.count > 0, "Not enough atoms.")
  precondition(styles.count > 0, "Not enough styles.")
  precondition(styles.count < 255, "Too many styles.")
  
  let elementInstances = malloc(256 * 4)!
    .assumingMemoryBound(to: UInt32.self)
  var pattern4: UInt32 = 0
  memset_pattern4(elementInstances, &pattern4, 256 * 4)
  
  @_alignment(16)
  struct MRAtom4 {
    var atom1: MRAtom
    var atom2: MRAtom
    var atom3: MRAtom
    var atom4: MRAtom
  }
  
  let paddedNumAtoms = (atoms.count + 3) / 4 * 4
  let atomsPadded_raw = malloc(paddedNumAtoms * 16)!
  let atomsPadded_1 = atomsPadded_raw.assumingMemoryBound(to: MRAtom.self)
  let atomsPadded_4 = atomsPadded_raw.assumingMemoryBound(to: MRAtom4.self)
  
  memcpy(atomsPadded_raw, atoms, atoms.count * 16)
  var paddingAtom = atoms[0]
  paddingAtom.element = 255
  for i in atoms.count..<paddedNumAtoms {
    atomsPadded_1[i] = paddingAtom
  }
  
  var minCoordinates: SIMD4<Float> = .zero
  var maxCoordinates: SIMD4<Float> = .zero
  for chunkIndex in 0..<paddedNumAtoms / 4 {
    let chunk = atomsPadded_4[chunkIndex]
    elementInstances[Int(chunk.atom1.element)] &+= 1
    elementInstances[Int(chunk.atom2.element)] &+= 1
    elementInstances[Int(chunk.atom3.element)] &+= 1
    elementInstances[Int(chunk.atom4.element)] &+= 1
    
    let coords1 = unsafeBitCast(chunk.atom1, to: SIMD4<Float>.self)
    let coords2 = unsafeBitCast(chunk.atom2, to: SIMD4<Float>.self)
    let coords3 = unsafeBitCast(chunk.atom3, to: SIMD4<Float>.self)
    let coords4 = unsafeBitCast(chunk.atom4, to: SIMD4<Float>.self)
    let min12 = simd_min(coords1, coords2)
    let min34 = simd_min(coords3, coords4)
    let min1234 = simd_min(min12, min34)
    minCoordinates = simd_min(min1234, minCoordinates)
    
    let max12 = simd_max(coords1, coords2)
    let max34 = simd_max(coords3, coords4)
    let max1234 = simd_max(max12, max34)
    maxCoordinates = simd_max(max1234, maxCoordinates)
  }
  
  let cellWidth: Float = 4.0 / 9
  let epsilon: Float = 1e-4
  var references: Int = 0
  var maxRadius: Float = 0
  for i in 0..<styles.count {
    let radius = Float(styles[i].radius)
    let cellSpan = 1 + ceil((2 * radius + epsilon) / cellWidth)
    let cellCube = cellSpan * cellSpan * cellSpan
    
    let instances = elementInstances[i]
    references &+= Int(instances &* UInt32(cellCube))
    
    let presentMask: Float = (instances > 0) ? 1 : 0
    maxRadius = max(radius * presentMask, maxRadius)
  }
  maxRadius += epsilon
  minCoordinates -= maxRadius
  maxCoordinates += maxRadius
  
  free(elementInstances)
  free(atomsPadded_raw)
  
  let boundingBox = MRBoundingBox(
    min: MTLPackedFloat3Make(
      minCoordinates.x, minCoordinates.y, minCoordinates.z),
    max: MTLPackedFloat3Make(
      maxCoordinates.x, maxCoordinates.y, maxCoordinates.z))
  return (boundingBox, references)
}

extension MRAccelBuilder {
  // Utility for exponentially expanding memory allocations.
  private func allocate(
    _ buffer: inout MTLBuffer?,
    currentMaxElements: inout Int,
    desiredElements: Int,
    bytesPerElement: Int
  ) -> MTLBuffer {
    if let buffer, currentMaxElements >= desiredElements {
      return buffer
    }
    while currentMaxElements < desiredElements {
      currentMaxElements = currentMaxElements << 1
    }
    
    let bufferSize = currentMaxElements * bytesPerElement
    let newBuffer = device.makeBuffer(length: bufferSize)!
    buffer = newBuffer
    return newBuffer
  }
  
  internal func buildDenseGrid(encoder: MTLComputeCommandEncoder) {
    precondition(atoms.count < 1024 * 1024, "Too many atoms for a dense grid.")
    
    let statistics = denseGridStatistics(atoms: atoms, styles: styles)
    
    let minCoordinates = SIMD3(statistics.boundingBox.min.x,
                               statistics.boundingBox.min.y,
                               statistics.boundingBox.min.z)
    let maxCoordinates = SIMD3(statistics.boundingBox.max.x,
                               statistics.boundingBox.max.y,
                               statistics.boundingBox.max.z)
    let maxMagnitude = max(abs(minCoordinates), abs(maxCoordinates)).max()

    let cellWidth: Float = 4.0 / 9
    self.gridWidth = max(Int(2 * ceil(maxMagnitude / cellWidth)), gridWidth)
    let totalCells = gridWidth * gridWidth * gridWidth
    guard statistics.references < 8 * 1024 * 1024 else {
      fatalError("Too many references for a dense grid.")
    }
    
    // Allocate new memory.
    ringIndex = (ringIndex + 1) % 3
    let atomsBuffer = allocate(
      &denseGridAtoms[ringIndex],
      currentMaxElements: &maxAtoms,
      desiredElements: atoms.count,
      bytesPerElement: 16)
    memcpy(denseGridAtoms[ringIndex]!.contents(), atoms, atoms.count * 16)
    
    let paddedCells = (totalCells + 127) / 128 * 128
    let numSlots = paddedCells
    let dataBuffer = allocate(
      &denseGridData,
      currentMaxElements: &maxGridSlots,
      desiredElements: numSlots,
      bytesPerElement: 4)
    let countersBuffer = allocate(
      &denseGridCounters,
      currentMaxElements: &maxGridCells,
      desiredElements: totalCells,
      bytesPerElement: 4)
    
    let referencesBuffer = allocate(
      &denseGridReferences,
      currentMaxElements: &maxGridReferences,
      desiredElements: statistics.references,
      bytesPerElement: 2)
    
    encoder.setComputePipelineState(memsetPipeline)
    encoder.setBuffer(dataBuffer, offset: 0, index: 0)
    encoder.dispatchThreads(
      MTLSizeMake(paddedCells, 1, 1),
      threadsPerThreadgroup: MTLSizeMake(256, 1, 1))
    
    // TODO: Fix this now that we removed the dependency on Metal ray tracing,
    // the source of the Metal Frame Capture bug.
    encoder.setBuffer(globalCounterBuffer, offset: 0, index: 0)
    encoder.dispatchThreads(
      MTLSizeMake(1, 1, 1),
      threadsPerThreadgroup: MTLSizeMake(32, 1, 1))
    
    var constants: UInt16 = UInt16(gridWidth)
    encoder.setBytes(&constants, length: 2, index: 0)
    styles.withUnsafeBufferPointer {
      let length = $0.count * MemoryLayout<MRAtomStyle>.stride
      encoder.setBytes($0.baseAddress!, length: length, index: 1)
    }
    encoder.setBuffer(atomsBuffer, offset: 0, index: 2)
    encoder.setBuffer(dataBuffer, offset: 0, index: 3)
    encoder.setBuffer(countersBuffer, offset: 0, index: 4)
    encoder.setBuffer(globalCounterBuffer, offset: 0, index: 5)
    encoder.setBuffer(referencesBuffer, offset: 0, index: 6)
    
    encoder.setComputePipelineState(densePass1Pipeline)
    encoder.dispatchThreads(
      MTLSizeMake(atoms.count, 1, 1),
      threadsPerThreadgroup: MTLSizeMake(128, 1, 1))
    
    encoder.setComputePipelineState(densePass2Pipeline)
    encoder.dispatchThreadgroups(
      MTLSizeMake(paddedCells / 128, 1, 1),
      threadsPerThreadgroup: MTLSizeMake(128, 1, 1))
    
    encoder.setComputePipelineState(densePass3Pipeline)
    encoder.dispatchThreads(
      MTLSizeMake(atoms.count, 1, 1),
      threadsPerThreadgroup: MTLSizeMake(128, 1, 1))
  }
  
  // Call this after encoding the grid construction.
  internal func setGridWidth(arguments: inout Arguments) {
    precondition(gridWidth > 0, "Forgot to encode the grid construction.")
    arguments.gridWidth = UInt16(self.gridWidth)
  }
  
  internal func encodeGridArguments(encoder: MTLComputeCommandEncoder) {
    encoder.setBuffer(denseGridAtoms[ringIndex]!, offset: 0, index: 3)
    encoder.setBuffer(denseGridData!, offset: 0, index: 4)
    encoder.setBuffer(denseGridReferences!, offset: 0, index: 5)
  }
}
