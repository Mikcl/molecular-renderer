//
//  HexagonalGrid.swift
//  MolecularRenderer
//
//  Created by Philip Turner on 10/22/23.
//

// Hexagonal Grid
//
// Source: https://www.redblobgames.com/grids/hexagons/#coordinates-doubled
// Similar to "Doubled coordinates", except halved and then compressed in the
// X direction (right -> 1/2 right) when storing in memory.

// TODO: - Add parity back again if needed.
// In loops, it will perform an XOR with the parity's raw value.

/// The larger set of columns is typically half cut-off at either cap.
///
/// `firstRowStaggered` is equivalent to `firstRowOrigin`, but with some extra
/// padding for atoms cut off by the hexagonal zigzag on the very bottom. At
/// first glance, one would intuit that most hexagonal grids use the staggered
/// parity.
enum HexagonalGridParity: Int32 {
  /// First row and column are larger than second.
  case firstRowOrigin = 0
  
  /// Second row and column are larger than first.
  case firstRowStaggered = 1
}

func transformHKLtoXYZ(_ input: SIMD3<Float>) -> SIMD3<Float> {
  var output = SIMD3(1, 0, 0) * input.x
  output += SIMD3(-0.5, 0.8660254038, 0) * input.y
  output += SIMD3(0, 0, 1) * input.z
  return output
}
func transformHH2KLtoXYZ(_ input: SIMD3<Float>) -> SIMD3<Float> {
  var output = SIMD3(1, 0, 0) * input.x
  output += SIMD3(0, 1.732050808, 0) * input.y
  output += SIMD3(0, 0, 1) * input.z
  return output
}
func transformHH2KLtoHKL(_ input: SIMD3<Float>) -> SIMD3<Float> {
  var output = SIMD3(1, 0, 0) * input.x
  output += SIMD3(1, 2, 0) * input.y
  output += SIMD3(0, 0, 1) * input.z
  return output
}


struct HexagonalCell {
  // Multiply the plane's origin by [3, 3, 8] and direction by [8, 8, 3].
  // Span: [0 -> 2h], [0 -> 2k], [0 -> l]
  static let x0 = SIMD8<Float>(2, 4, 5, 4, 2, 1, 2, 4)
  static let y0 = SIMD8<Float>(1, 2, 4, 5, 4, 2, 1, 2)
  static let z0 = SIMD8<Float>(0, 1, 0, 1, 0, 1, 5, 4)
  
  // Ring: x = [2, 4, 5, 4, 2, 1, repeat]
  //       y = [1, 2, 4, 5, 4, 2, repeat]
  //       z = [0, 1, 0, 1, 0, 1, 5, 4, 5, 4, 5, 4]
  static let x1 = SIMD4<Float>(5, 4, 2, 1)
  static let y1 = SIMD4<Float>(4, 5, 4, 2)
  static let z1 = SIMD4<Float>(5, 4, 5, 4)
  
  // Binary mask corresponding to the plane's "one volume" and "zero volume".
  static func intersect(
    origin: SIMD3<Float>,
    normal: SIMD3<Float>
  ) -> SIMD16<UInt8> {
    //    let scaledOrigin = origin * SIMD3(3, 3, 8)
    //    let scaledNormal = normal * SIMD3(8, 8, 3)
    //    
    //    let delta_x0 = x0 - scaledOrigin.x
    //    let delta_y0 = y0 - scaledOrigin.y
    //    let delta_z0 = z0 - scaledOrigin.z
    //    var dotProduct0 = delta_x0 * scaledNormal.x
    //    dotProduct0 += delta_y0 * scaledNormal.y
    //    dotProduct0 += delta_z0 * scaledNormal.z
    //    
    //    let delta_x1 = x1 - scaledOrigin.x
    //    let delta_y1 = y1 - scaledOrigin.y
    //    let delta_z1 = z1 - scaledOrigin.z
    //    var dotProduct1 = delta_x1 * scaledNormal.x
    //    dotProduct1 += delta_y1 * scaledNormal.y
    //    dotProduct1 += delta_z1 * scaledNormal.z
    //    
    //    var mask0: SIMD8<Int32> = .one
    //    var mask1: SIMD4<Int32> = .one
    //    mask0.replace(with: SIMD8.zero, where: dotProduct0 .> 0)
    //    mask1.replace(with: SIMD4.zero, where: dotProduct1 .> 0)
    //    let output0 = SIMD8<UInt8>(truncatingIfNeeded: mask0)
    //    let output1 = SIMD4<UInt8>(truncatingIfNeeded: mask1)
    //    return SIMD16(
    //      lowHalf: output0,
    //      highHalf: SIMD8(lowHalf: output1, highHalf: .zero))
    
    // Debugging the dot product by de-vectorizing it, having the plane
    // transformed into XYZ space beforehand.
    var x_coords: [Float] = []
    var y_coords: [Float] = []
    var z_coords: [Float] = []
    for i in 0..<8 {
      x_coords.append(x0[i])
      y_coords.append(y0[i])
      z_coords.append(z0[i])
    }
    for i in 0..<4 {
      x_coords.append(x1[i])
      y_coords.append(y1[i])
      z_coords.append(z1[i])
    }
    var output: SIMD16<UInt8> = .zero
    for i in 0..<12 {
      let coordsHKL = SIMD3(x_coords[i],
                            y_coords[i],
                            z_coords[i])
      
      var coords = coordsHKL * SIMD3(1.0 / 3, 1.0 / 3, 1.0 / 8)
      coords = transformHKLtoXYZ(coords)
      let distance = ((coords - origin) * normal).sum()
      func abs(_ x: SIMD3<Float>) -> SIMD3<Float> {
        var output = x
        output.replace(with: -x, where: x .< 0)
        return output
      }
      
      if all(abs(normal - SIMD3<Float>(0.0, 1.7320508, 0.0)) .< 0.01) {
//        print(i, coords, origin, normal, distance)
      }
      if distance <= 0.01 {
        output[i] = 1
      }
    }
    return output
  }
}

struct HexagonalMask: LatticeMask {
  var mask: [SIMD16<UInt8>]
  
  /// Create a mask using a plane.
  ///
  /// The dimensions for this grid will appear very lopsided. `x` increments by
  /// one roughly every 2 hexagons in the `h` direction. Meanwhile, `y`
  /// increments by one exactly every hexagon in the `k` direction. This is the
  /// most direct way to represent the underlying storage.
  init(
    dimensions: SIMD3<Int32>,
    origin untransformedOrigin: SIMD3<Float>,
    normal untransformedNormal: SIMD3<Float>
  ) {
    let origin = transformHH2KLtoXYZ(untransformedOrigin)
    let normal = transformHH2KLtoXYZ(untransformedNormal)
    
    // Initialize the mask with everything in the one volume. The full mask
    // prevents the entity types from being set to "empty".
    mask = Array(repeating: SIMD16(repeating: 255), count: Int(
      dimensions.x * dimensions.y * dimensions.z))
    
    if all(normal .== 0) {
      // This cannot be evaluated. It is a permissible escape hatch to create a
      // mask with no intersection.
      return
    }
    
    #if false
    // Derivation of formula:
    // (r - r0) * n = 0
    // (x - x0)nx + (y - y0)ny + (z - z0)nz = 0
    // x = x0 + (1 / nx) (-(y - y0)ny - (z - z0)nz) = 0
    let sdfDimensionY = (Int(dimensions.y * 2 + 1) + 7) / 8 * 8
    let sdfDimensionZ = Int(dimensions.z + 1)
    var sdf: UnsafeMutableRawPointer = .allocate(
      byteCount: 4 * sdfDimensionY * sdfDimensionZ, alignment: 32)
    defer { sdf.deallocate() }
    
    // Solve the equations in parallel, 8 elements at a time.
    let sdfVector = sdf.assumingMemoryBound(to: SIMD8<Float>.self)
    let sdfScalar = sdf.assumingMemoryBound(to: Float.self)
    for z in 0..<sdfDimensionZ {
      for arrayIndex in 0..<sdfDimensionY / 8 {
        let base = Int32(truncatingIfNeeded: arrayIndex &* 8)
        let offset = SIMD8<Int8>(-1, 0, 1, 2, 3, 4, 5, 6)
        let y = SIMD8<Int32>(repeating: base) &+
        SIMD8<Int32>(truncatingIfNeeded: offset)
        
        let deltaY = SIMD8<Float>(y) - origin.y
        let deltaZ = Float(z) - origin.z
        let rhs = -deltaY * normal.y - deltaZ * normal.z
        let x = origin.x + (1 / normal.x) * rhs
        
        // intersection x < 0      -> distance > 0, zero volume
        // intersection x > length -> distance < 0, one volume
        sdfVector[z &* sdfDimensionY / 8 &+ arrayIndex] = x
      }
    }
    #endif
    
    for z in 0..<dimensions.z {
      // Note that the 'y' coordinate here starts at zero, while the actual
      // floating-point value should start at -0.5.
      for y in 0..<dimensions.y {
        let parityOffset: Float = (y & 1 == 0) ? 1.5 : 0.0
        let loopOffset: Int32 = (y & 1 == 0) ? -1 : 0
        var baseAddress = (z &* dimensions.y &+ y)
        baseAddress = baseAddress &* dimensions.x
        
        for x in 0..<dimensions.x + loopOffset {
          var lowerCorner = SIMD3(Float(x) * 3 + parityOffset,
                                  Float(y) - 1,
                                  Float(z))
          lowerCorner.y /= 2
          lowerCorner = transformHH2KLtoXYZ(lowerCorner)
          
//          print("intersect", origin, normal)
          let cellMask = HexagonalCell.intersect(
            origin: origin - lowerCorner, normal: normal)
          mask[Int(baseAddress + x)] = cellMask
        }
        
        #if false
        let offsetY = SIMD4<UInt8>(0, 2, 0, 2)
        let offsetZ = SIMD4<UInt8>(0, 0, 1, 1)
        var searchY = SIMD4<Int32>(repeating: y)
        var searchZ = SIMD4<Int32>(repeating: z)
        searchY &+= SIMD4(truncatingIfNeeded: offsetY)
        searchZ &+= SIMD4(truncatingIfNeeded: offsetZ)
        let addresses = searchZ &* Int32(sdfDimensionY) &+ searchY
        
        var gathered: SIMD4<Float> = .zero
        for lane in 0..<4 {
          gathered[lane] = sdfScalar[Int(addresses[lane])]
        }
        let gatheredMin = gathered.min()
        let gatheredMax = gathered.max()
        let gatheredNaN =
        gathered[0].isNaN ||
        gathered[1].isNaN ||
        gathered[2].isNaN ||
        gathered[3].isNaN
        
        var loopStart: Int32 = 0
        var loopEnd = dimensions.x
        var leftMask = SIMD16<UInt8>(repeating: normal.x > 0 ? 255 : 0)
        var rightMask = SIMD16<UInt8>(repeating: normal.x < 0 ? 255 : 0)
        if gatheredNaN {
          // pass
          print("NaN")
        } else if gatheredMin > Float(dimensions.x) || gatheredMax < 0 {
          var distance = (Float(y) - 1 - origin.y) * normal.y
          distance += (Float(z) - origin.z) * normal.z
          loopEnd = 0
          
          if distance > 0 {
            // "zero" volume
            rightMask = SIMD16(repeating: 0)
            print("zero volume")
          } else {
            // "one" volume
            rightMask = SIMD16(repeating: 255)
            print("one volume")
          }
        } else {
          // Add a floating-point epsilon to the gathered min/max, as the sharp
          // cutoff could miss atoms in the next cell, which lie perfectly on
          // the plane.
          if gatheredMin > 0 {
            loopStart = Int32((gatheredMin - 0.001).rounded(.down))
            loopStart = max(loopStart, 0)
            print("gatheredMin > 0")
          }
          if gatheredMax < Float(dimensions.x) {
            loopEnd = Int32((gatheredMax + 0.001).rounded(.up))
            loopEnd = min(loopEnd, dimensions.x)
            print("gatheredMax < Float(\(dimensions.x))")
          }
        }
        
        // Non-staggered columns have one slot wasted in memory. This is
        // regardless of how wide the associated rows are. The memory wasting
        // is O(kl) in an O(hkl) context.
        //
        // Except - the data isn't packed by column. It's packed by row. No
        // extra slots are wasted, but understanding **why none are wasted** can
        // reinforce your comprehension of the data layout.
        var baseAddress = (z &* Int32(dimensions.y * 2 - 1) &+ y)
        baseAddress = baseAddress &* Int32(dimensions.x)
        
        // Staggered rows have one slot wasted in memory. This is regardless of
        // how tall the associated columns are. The memory wasting is O(hl) in
        // an O(hkl) context.
        var parityOffset = Float(0)
        var dimensionsX: Int32 = dimensions.x
        if (y & 1) /*^ Int32(parity.rawValue) == 1*/ == 0 {
//          parityOffset = 1.5
          dimensionsX -= 1
        }
        loopEnd = min(loopEnd, dimensionsX)
//        loopStart = 0
//        loopEnd = dimensionsX
        
        for x in 0..<loopStart {
          mask[Int(baseAddress + x)] = leftMask
        }
        for x in loopEnd..<dimensions.x {
          mask[Int(baseAddress + x)] = rightMask
        }
        
        // Correct the floating-point value for 'y' to be shifted downward
        // by -0.5.
        var lowerCorner = SIMD3<Float>(0, Float(y) - 1, Float(z))
        for x in loopStart..<loopEnd {
          lowerCorner.x = Float(x) * 3 + parityOffset
          
          // This matrix maps from h/h + 2k/l -> h/k/l.
          // | 1  1 |
          // | 0  2 |
          let columns = (SIMD2<Float>(1, 0),
                         SIMD2<Float>(1, 2))
          @inline(__always)
          func transform(_ input: SIMD3<Float>) -> SIMD3<Float> {
            var simd4 = SIMD4(input, 0)
            simd4.lowHalf = columns.0 * simd4.x + columns.1 * simd4.y
            return unsafeBitCast(simd4, to: SIMD3<Float>.self)
          }
          
          let cellMask = HexagonalCell.intersect(
            origin: transform(origin - lowerCorner),
            normal: transform(normal))
//          print(normal, x, y, z, origin, lowerCorner, transform(origin - lowerCorner), transform(normal), cellMask)
          mask[Int(baseAddress + x)] = cellMask
//          mask[Int(baseAddress + x)] = SIMD16(repeating: 0)
        }
        #endif
      }
    }
  }
}

struct HexagonalGrid: LatticeGrid {
  var dimensions: SIMD3<Int32>
  var entityTypes: [SIMD16<Int8>]
  var hexagonSideLength: Float
  var prismHeight: Float
  
  /// Create a mask using a plane.
  init(bounds: SIMD3<Float>, material: MaterialType) {
    var repeatingUnit: SIMD16<Int8>
    switch material {
    case .elemental(let element):
      let scalar = Int8(clamping: element.rawValue)
      repeatingUnit = SIMD16(repeating: scalar)
    case .checkerboard(let a, let b):
      let scalarA = Int8(clamping: a.rawValue)
      let scalarB = Int8(clamping: b.rawValue)
      let unit = unsafeBitCast(SIMD2(scalarA, scalarB), to: UInt16.self)
      let repeated = SIMD8<UInt16>(repeating: unit)
      repeatingUnit = unsafeBitCast(repeated, to: SIMD16<Int8>.self)
    }
    repeatingUnit.highHalf.highHalf = SIMD4(repeating: 0)
    
    // Increase the bounds by a small amount, so atoms on the edge will be
    // present in the next cell.
    var transformedBounds = SIMD3(bounds.x * 1.0 / 3,
                                  bounds.y * 2 + 1,
                                  bounds.z)
    
    // Dimensions are in h/h2k/l for now.
    dimensions = SIMD3<Int32>(transformedBounds.rounded(.up))
    dimensions.replace(with: SIMD3.zero, where: dimensions .< 0)
    entityTypes = Array(repeating: repeatingUnit, count: Int(
      dimensions.x * dimensions.y * dimensions.z))
    
    // Set this to carbon lattice constants for now. Eventually, we'll need to
    // scale it to perfectly line up with diamond.
    hexagonSideLength = 0.251
    prismHeight = 0.412
    
    // Intersect yourself with some h/h + 2k/l planes.
    let hMinus = (SIMD3<Float>(-1, 0, 0))
    let hPlus = (SIMD3<Float>(1, 0, 0))
    let h2kMinus = (SIMD3<Float>(0, -1, 0))
    let h2kPlus = (SIMD3<Float>(0, 1, 0))
    let lMinus = (SIMD3<Float>(0, 0, -1))
    let lPlus = (SIMD3<Float>(0, 0, 1))
    self.initializeBounds(bounds, normals: [
      hMinus, hPlus, h2kMinus, h2kPlus, lMinus, lPlus
    ])
  }
  
  // Cut() can be implemented by replacing with ".empty" in the mask's zero
  // volume.
  mutating func replace(with other: Int8, where mask: HexagonalMask) {
    var newValue = SIMD16(repeating: other)
    newValue.highHalf.highHalf = SIMD4(repeating: 0)
    
    for cellID in entityTypes.indices {
      let condition = mask.mask[cellID] .== 0
      entityTypes[cellID].replace(with: newValue, where: condition)
    }
  }
  
  var entities: [Entity] {
    var output: [Entity] = []
    let sqrt34 = Float(0.75).squareRoot()
    let outputScale = SIMD3<Float>(
      hexagonSideLength, hexagonSideLength, prismHeight
    )
    for z in 0..<dimensions.z {
      for y in 0..<dimensions.y {
        let parityOffset: Float = (y & 1 == 0) ? 1.5 : 0.0
        let loopOffset: Int32 = (y & 1 == 0) ? -1 : 0
        var baseAddress = (z &* dimensions.y &+ y)
        baseAddress = baseAddress &* dimensions.x
        
        for x in 0..<dimensions.x + loopOffset {
          var lowerCorner = SIMD3<Float>(SIMD3(x, y, z))
          lowerCorner.x *= 3
          lowerCorner.x += parityOffset
          lowerCorner.y -= 1
          lowerCorner.y /= 2
          
          lowerCorner = transformHH2KLtoHKL(lowerCorner)
          lowerCorner *= outputScale
          lowerCorner = transformHKLtoXYZ(lowerCorner)
          
          let cell = entityTypes[Int(baseAddress + x)]
          for lane in 0..<12 {
            guard cell[lane] != 0 else {
              continue
            }
            
            var x: Float
            var y: Float
            var z: Float
            if lane < 8 {
              x = HexagonalCell.x0[lane] / 3
              y = HexagonalCell.y0[lane] / 3
              z = HexagonalCell.z0[lane] / 8
            } else {
              x = HexagonalCell.x1[lane - 8] / 3
              y = HexagonalCell.y1[lane - 8] / 3
              z = HexagonalCell.z1[lane - 8] / 8
            }
            let type = EntityType(compactRepresentation: cell[lane])
            
            var position = SIMD3<Float>(x, y, z)
            position *= outputScale
            position = transformHKLtoXYZ(position)
            position += lowerCorner
            
            let entity = Entity(
              position: position, type: type)
            output.append(entity)
          }
        }
      }
    }
    return output
  }
}

/// Test function that returns the initial grid. Try with:
/// - diamond
/// - moissanite
/// - germanium
public func Hexagonal_init(
  bounds: SIMD3<Float>, material: MaterialType
) -> [Entity] {
  HexagonalGrid(bounds: bounds, material: material).entities
}
