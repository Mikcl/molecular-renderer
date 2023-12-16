// Save as GitHub Gist instead of polluting the molecular-renderer source tree.

import Foundation
import HDL
import MM4
import MolecularRenderer
import Numerics

func createNanomachinery() -> [MRAtom] {
  // diamond claw
  let robotClaw = createRobotClawLattice()
  var robotClawDiamondoid = Diamondoid(atoms: robotClaw.entities.map(MRAtom.init))
  let robotClawCoM = robotClawDiamondoid.createCenterOfMass()
  robotClawDiamondoid.translate(offset: [-robotClawCoM.x, 0, -robotClawCoM.z])
  
  // diamond claw topper - several small hexagonal prisms, each
  // rotated a bit
  let hexagon = createHexagonLattice()
  var hexagonDiamondoid = Diamondoid(
    atoms: hexagon.entities.map(MRAtom.init))
  hexagonDiamondoid.translate(offset: -hexagonDiamondoid.createCenterOfMass())
  hexagonDiamondoid.rotate(angle: Quaternion(angle: -.pi / 2, axis: [1, 0, 0]))
  hexagonDiamondoid.translate(offset: [0, 23, 0])
  var hexagons: [Diamondoid] = []
  for i in 0..<13 {
    var output = hexagonDiamondoid
    output.translate(offset: [0, Float(i) * 0.8, 0])
    let angle = Float(i) * 4 * .pi / 180
    output.rotate(angle: Quaternion(angle: angle, axis: [0, 1, 0]))
    hexagons.append(output)
  }
  
  // silicon carbide band
  let band = createBandLattice()
  var bandDiamondoid = Diamondoid(atoms: band.entities.map(MRAtom.init))
  bandDiamondoid.translate(offset: -bandDiamondoid.createCenterOfMass())
  bandDiamondoid.rotate(angle: Quaternion(angle: -.pi / 2, axis: [1, 0, 0]))
  bandDiamondoid.rotate(angle: Quaternion(angle: -.pi / 2, axis: [0, 1, 0]))
  
  do {
    let maxX = bandDiamondoid.atoms.reduce(-Float.greatestFiniteMagnitude) {
      max($0, $1.x)
    }
    let minY = bandDiamondoid.atoms.reduce(Float.greatestFiniteMagnitude) {
      min($0, $1.y)
    }
    bandDiamondoid.translate(offset: [6.15 - maxX, 0, 0])
    bandDiamondoid.translate(offset: [0, 2.5 - minY, 0])
  }
  
  // silicon roof piece - instantiate one in the top, middle, and bottom
  let roofPiece = createRoofPieceLattice()
  var roofPieceDiamondoid = Diamondoid(
    atoms: roofPiece.entities.map(MRAtom.init))
  roofPieceDiamondoid.translate(offset: [0, 17, 0])
  
  // rod for controlling the arms - one for each arm, each a different length
  // rods on one side are elevated a half-spacing above rods on the other side
  let controlRod = createControlRod(length: 80)
  var controlRodDiamondoid = Diamondoid(
    atoms: controlRod.entities.map(MRAtom.init))
  controlRodDiamondoid.translate(
    offset: -controlRodDiamondoid.createCenterOfMass())
  controlRodDiamondoid.rotate(angle: Quaternion(angle: .pi / 2, axis: [1, 0, 0]))
  do {
    let minX = controlRodDiamondoid.atoms.reduce(Float.greatestFiniteMagnitude) {
      min($0, $1.x)
    }
    let minZ = controlRodDiamondoid.atoms.reduce(Float.greatestFiniteMagnitude) {
      min($0, $1.z)
    }
    controlRodDiamondoid.translate(offset: [3 - minX, 0, 0])
    controlRodDiamondoid.translate(offset: [0, 21, 0])
    controlRodDiamondoid.translate(offset: [0, 0, -3 - minZ])
  }
  
  
  // need to create a Swift data structure to encapsulate the initialization and
  // assembly of a single assembly line
  
  // missing pieces:
  // - track depicting products being moved through the sequence of arms
  // - housing
  // - piece to connect housings of nearby assembly lines
  // - larger assembly line in front of the rows of robot arms
  
  let diamondoids = [
    robotClawDiamondoid,
    bandDiamondoid,
    roofPieceDiamondoid,
    controlRodDiamondoid
  ] + hexagons
  let output = diamondoids.flatMap { $0.atoms }
//  + controlRod.entities.map(MRAtom.init).map {
//    var copy = $0
////    copy.origin.x += 3.5
////    copy.origin.y += 20
//    copy.origin.z += 10
//    return copy
//  }
  print(output.count)
  return output
}

func createRobotClawLattice() -> Lattice<Hexagonal> {
  Lattice<Hexagonal> { h, k, l in
    let h2k = h + 2 * k
    Bounds { 30 * h + 85 * h2k + 4 * l }
    Material { .elemental(.carbon) }
    
    Volume {
      Origin { 15 * h + 10 * h2k + 2 * l }
      
      Concave {
        for direction in [h, -h, k, h + k] {
          Convex {
            Origin { 9 * direction }
            Plane { -direction }
          }
        }
      }
      Concave {
        Convex {
          for direction in [h, -h] {
            Convex {
              Origin { 6 * direction }
              Plane { direction }
            }
          }
        }
        Convex {
          for direction in [h, -h, k, h + k] {
            Convex {
              Origin { 14 * direction }
              Plane { direction }
            }
          }
          for direction in [-k, -h - k] {
            Convex {
              Origin { -2 * h2k }
              Origin { 14 * direction }
              Plane { direction }
            }
          }
        }
      }
      
      for hSign in [Float(1), -1] {
        Concave {
          Origin { 34 * h2k }
          Convex {
            Origin { 6 * hSign * h }
            Plane { hSign * h + h2k }
          }
          Convex {
            Origin { 4 * hSign * h }
            Plane { hSign * h }
          }
        }
      }
      
      Replace { .empty }
    }
  }
}

func createHexagonLattice() -> Lattice<Hexagonal> {
  Lattice<Hexagonal> { h, k, l in
    let h2k = h + 2 * k
    Bounds { 24 * h + 24 * h2k + 3 * l }
    Material { .checkerboard(.carbon, .germanium) }
    
    Volume {
      Convex {
        Origin { 0.7 * l }
        Plane { l }
      }
      
      Origin { 12 * h + 12 * h2k }
      
      let directions1 = [h, h + k, k, -h, -k - h, -k]
      var directions2: [SIMD3<Float>] = []
      directions2.append(h * 2 + k)
      directions2.append(h + 2 * k)
      directions2.append(k - h)
      directions2 += directions2.map(-)
      
      for direction in directions1 {
        Convex {
          Origin { 6 * 1.5 * direction }
          Plane { direction }
        }
      }
      for direction in directions2 {
        Convex {
          Origin { (6 - 0.5) * direction }
          Plane { direction }
        }
      }
      Concave {
        for direction in directions1 {
          Convex {
            Origin { 4 * 1.5 * direction }
            Plane { -direction }
          }
        }
        for direction in directions2 {
          Convex {
            Origin { (4 - 0.5) * direction }
            Plane { -direction }
          }
        }
      }
      
      Replace { .empty }
    }
  }
}

func createBandLattice() -> Lattice<Hexagonal> {
  Lattice<Hexagonal> { h, k, l in
    let h2k = h + 2 * k
    Bounds { 10 * h + 9 * h2k + 60 * l }
    Material { .checkerboard(.carbon, .silicon) }
    
    Volume {
      Origin { 5 * h + 3.5 * h2k + 0 * l }
      
      Concave {
        Origin { -0.25 * h2k }
        for direction in [4 * h, 1.75 * h2k, -4 * h, -2.25 * h2k] {
          Convex {
            Origin { 1 * direction }
            Plane { -direction }
          }
        }
      }
      
      for directionPair in [(h, 2 * h + k), (-h, k - h)] {
        Concave {
          Convex {
            Origin { 2 * directionPair.0 }
            Plane { directionPair.0 }
          }
          Convex {
            Origin { 3.75 * directionPair.1 }
            Plane { directionPair.1 }
          }
        }
      }
      
      Concave {
        Origin { 2.8 * l }
        Plane { l }
        Origin { 2.5 * h2k }
        Plane { -h2k }
      }
      
      for direction in [h, -h] {
        Concave {
          Origin { 2.8 * l }
          Plane { l }
          Origin { 2 * direction }
          Plane { direction }
        }
      }
      
      Replace { .empty }
    }
  }
}

func createRoofPieceLattice() -> Lattice<Hexagonal> {
  Lattice<Hexagonal> { h, k, l in
    let holeSpacing: Float = 8
    let holeWidth: Float = 5
    
    let xWidth: Float = 22
    let yHeight: Float = 4
    let xCenter: Float = 7.5
    let zWidth: Float = (3*2) * holeSpacing
    let h2k = h + 2 * k
    Bounds { xWidth * h + yHeight * h2k + zWidth * l }
    Material { .elemental(.silicon) }
    
    Volume {
      Convex {
        Origin { 1 * h }
        Plane { -h }
      }
      Convex {
        Origin { xWidth * h }
        Concave {
          Origin { yHeight/2 * h2k }
          Origin { -4 * h }
          Plane { -k + h }
          Plane { h + k + h }
        }
        
        Origin { -6 * h }
        Concave {
          Origin { 1 * h2k }
          Plane { -h2k }
          Plane { -h - k }
        }
        Concave {
          Origin { (yHeight - 1) * h2k }
          Plane { h2k }
          Plane { k }
        }
      }
      Origin { xCenter * h + yHeight/2 * h2k + 0 * l }
      
      for hDirection in [h, -h] {
        for lIndex in 0...Int(zWidth / holeSpacing + 1e-3) {
          Concave {
            Origin { (hDirection.x > 0) ? 3 * h : -2 * h }
            Plane { hDirection }
            
            Origin { holeSpacing * Float(lIndex) * l }
            Convex {
              Origin { -holeWidth/2 * l }
              Origin { -0.25 * l }
              Plane { l }
            }
            Convex {
              Origin { holeWidth/2 * l }
              Plane { -l }
            }
          }
        }
      }
      
      Replace { .empty }
    }
  }
}

func createControlRod(length: Int) -> Lattice<Hexagonal> {
  Lattice<Hexagonal> { h, k, l in
    let h2k = h + 2 * k
    Bounds { 8 * h + Float(length) * h2k + 2 * l }
    Material { .elemental(.carbon) }
    
    Volume {
      // Add a hook-like feature to the end of the control rod.
      Convex {
        Origin { 6 * h }
        Plane { h - k }
      }
      Concave {
        Origin { 6 * h + 3 * h2k }
        Plane { -h }
        Plane { k - h }
      }
      
      Replace { .empty }
    }
  }
}
