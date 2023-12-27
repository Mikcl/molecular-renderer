// Save as GitHub Gist instead of polluting the molecular-renderer source tree.

import Foundation
import HDL
import MM4
import MolecularRenderer
import Numerics

func createReconstructionDemo() -> [MRAtom] {
  let lattice = createBeamLattice()
  var topology = Topology()
  topology.insert(atoms: lattice)
  
  var reconstruction = Reconstruction()
  reconstruction.topology = topology
  reconstruction.prepare()
  
  // TODO:
  // - 1) Move all of this into a function in 'Scratch4'.
  // - 2) Test the raw structure(s) in MM4, see if it works by some miracle.
  // - 3) Create the CPU-side energy minimizer.
  let warpStructure = Bool.random() ? true : true
  
  do {
    var updates: [Reconstruction.CollisionState?] = []
    for _ in reconstruction.hydrogensToAtomsMap.indices {
      updates.append(nil)
    }
    
    func withTwoWayCollisions(_ closure: (UInt32, [UInt32]) -> Void) {
      for i in reconstruction.hydrogensToAtomsMap.indices {
        let atomList = reconstruction.hydrogensToAtomsMap[i]
        if atomList.count > 2 {
          fatalError("3-way collisions not handled yet.")
        }
        if atomList.count < 2 {
          continue
        }
        closure(UInt32(i), atomList)
      }
    }
    
    let orbitals = reconstruction.topology.nonbondingOrbitals()
    for i in orbitals.indices {
      let orbital = orbitals[i]
      if orbital.count == 2 {
        precondition(reconstruction.initialTypes[i] == .secondary)
      } else if orbital.count == 1 {
        precondition(reconstruction.initialTypes[i] == .tertiary)
      } else if orbital.count == 0 {
        precondition(reconstruction.initialTypes[i] == .quaternary)
      }
    }
    
    withTwoWayCollisions { i, atomList in
      var bridgeheadID: Int = -1
      var sidewallID: Int = -1
      var bothBridgehead = true
      var bothSidewall = true
      for atomID in atomList {
        switch reconstruction.initialTypes[Int(atomID)] {
        case .secondary:
          sidewallID = Int(atomID)
          bothBridgehead = false
        case .tertiary:
          bridgeheadID = Int(atomID)
          bothSidewall = false
        default:
          fatalError("This should never happen.")
        }
      }
      
      var linkedList: [Int] = []
      
      if bothBridgehead {
        fatalError("Edge case not handled yet.")
      } else if bothSidewall {
      outer:
        for atomID in atomList {
          var hydrogens = reconstruction.atomsToHydrogensMap[Int(atomID)]
          precondition(
            hydrogens.count == 2, "Sidewall did not have 2 hydrogens.")
          
          if hydrogens[0] == UInt32(i) {
            
          } else if hydrogens[1] == UInt32(i) {
            hydrogens = [hydrogens[1], hydrogens[0]]
          } else {
            fatalError("Unexpected hydrogen list.")
          }
          precondition(hydrogens.first! == UInt32(i))
          precondition(hydrogens.last! != UInt32(i))
          
          let nextHydrogen = Int(hydrogens.last!)
          let atomList2 = reconstruction.hydrogensToAtomsMap[nextHydrogen]
          if atomList2.count == 1 {
            // This is the end of the list.
            linkedList.append(Int(atomID))
            linkedList.append(Int(hydrogens.first!))
            precondition(reconstruction
              .hydrogensToAtomsMap[Int(hydrogens.first!)].count == 2)
            var atomListCopy = atomList
            precondition(atomListCopy.count == 2)
            atomListCopy.removeAll(where: { $0 == atomID })
            precondition(atomListCopy.count == 1)
            
            linkedList.append(Int(atomListCopy[0]))
            break outer
          }
        }
        
        if linkedList.count == 0 {
          // Edge case: middle of a bond chain. This is never handled. If there
          // is a self-referential ring, the entire ring is skipped.
          return
        }
        
        precondition(linkedList.count == 3, "Unexpected linked list length.")
      } else {
        precondition(bridgeheadID >= 0 && sidewallID >= 0)
        
        // The IDs of the elements are interleaved. First a carbon, then the
        // connecting collision, then a carbon, then a collision, etc. The end
        // must always be a carbon.
        linkedList.append(bridgeheadID)
        linkedList.append(Int(i))
        linkedList.append(sidewallID)
      }
      
      var iterationCount = 0
    outer:
      while true {
        defer {
          iterationCount += 1
          if iterationCount > 1000 {
            fatalError(
              "(100) reconstructon took too many iterations to converge.")
          }
        }
        let endOfList = linkedList.last!
        let existingHydrogen = linkedList[linkedList.count - 2]
        
        var hydrogens = reconstruction.atomsToHydrogensMap[endOfList]
        switch hydrogens.count {
        case 1:
          // If this happens, the end of the list is a bridgehead carbon.
          precondition(
            hydrogens[0] == UInt32(existingHydrogen),
            "Unexpected hydrogen list.")
          
          let centerType = reconstruction.initialTypes[endOfList]
          precondition(centerType == .tertiary, "Must be a bridgehead carbon.")
          break outer
        case 2:
          if hydrogens[0] == UInt32(existingHydrogen) {
            
          } else if hydrogens[1] == UInt32(existingHydrogen) {
            hydrogens = [hydrogens[1], hydrogens[0]]
          } else {
            fatalError("Unexpected hydrogen list.")
          }
          precondition(hydrogens.first! == UInt32(existingHydrogen))
          precondition(hydrogens.last! != UInt32(existingHydrogen))
          
          let nextHydrogen = Int(hydrogens.last!)
          var atomList = reconstruction.hydrogensToAtomsMap[nextHydrogen]
          if atomList.count == 1 {
            // This is the end of the list.
            break outer
          }
          linkedList.append(nextHydrogen)
          precondition(atomList.count == 2) // this may not always be true
          
          precondition(atomList.contains(UInt32(endOfList)))
          atomList.removeAll(where: { $0 == UInt32(endOfList) })
          precondition(atomList.count == 1)
          linkedList.append(Int(atomList[0]))
          
          break outer
        case 3:
          fatalError("3-way collisions not handled yet.")
        default:
          fatalError("Unexpected hydrogen count: \(hydrogens.count)")
        }
      }
      
      // Choose which traversal path to accept based on a rule.
      var reverseLinkedList = true
      var highStrainOnWarp = false
      var lowStrainOnWarp = false
      do {
        let firstAtom = reconstruction.topology.atoms[linkedList.first!]
        let lastAtom = reconstruction.topology.atoms[linkedList.last!]
        let delta = lastAtom.position - firstAtom.position
        
        var perpendicularAxis = -1
        for axisID in 0..<3 {
          guard abs(delta[axisID]) < 10 / 1000 else {
            continue
          }
          precondition(perpendicularAxis == -1)
          perpendicularAxis = axisID
        }
        precondition(perpendicularAxis != -1)
        
        switch perpendicularAxis {
        case 0:
          // x
          if delta.z > 0 {
            reverseLinkedList = false
          }
        case 1:
          // y
          if delta.x < 0 {
            reverseLinkedList = false
          }
        case 2:
          // z
          if delta.x < 0 {
            reverseLinkedList = false
          }
          
          let anOrbital = orbitals[linkedList.first!].first!
          if anOrbital.z > 0 {
            highStrainOnWarp = true
          } else {
            lowStrainOnWarp = true
          }
        default:
          fatalError("This should never happen.")
        }
      }
      if reverseLinkedList {
        linkedList.reverse()
      }
      
      // Choose which bonds to form based on a rule.
      // - A more elaborate rule can selectively form bonds on one side, causing
      //   immense strain that naturally keeps it in a shell structure.
      if linkedList.count == 3 {
        print("hello world")
        let listElement = linkedList[1]
        if updates[listElement] == nil {
          updates[listElement] = .bond
        }
      } else {
        for i in linkedList.indices {
          guard i % 2 == 1 else {
            continue
          }
          let listElement = linkedList[i]
          guard updates[listElement] == nil else {
            continue
          }
          
          if warpStructure && highStrainOnWarp {
            updates[listElement] = .bond
          } else if warpStructure && lowStrainOnWarp {
            updates[listElement] = .keep
          } else {
            if i % 4 == 1 {
              updates[listElement] = .bond
            } else {
              updates[listElement] = .keep
            }
          }
        }
      }
    }
    
    reconstruction.updateCollisions(updates.map { $0 ?? .keep })
  }
  
  reconstruction.apply()
  topology = reconstruction.topology
  
  return topology.atoms.map(MRAtom.init)
}

// This may output one of two materials - C or Si. The code handling it must
// function correctly in either case. Being a single element reduces the
// complexity of rules regarding hydrogen locations for detecting collisions.
// It could theoretically be extended to mixed-element structures, but with
// extra effort and restrictions on the code processing the geometry.
func createBeamLattice() -> [Entity] {
  let lattice = Lattice<Cubic> { h, k, l in
    Bounds { 10 * h + 3 * k + 2 * l }
    Material { .elemental(.carbon) }
    
    #if false
    Volume {
      // These two cuts can be commented out to see how the structure warps
      // differently without them.
      Convex {
        Origin { 1.5 * k + 1.75 * l }
        Concave {
          Plane { k }
          Plane { l }
        }
      }
      Convex {
        Origin { 1.5 * k + 0.25 * l }
        Concave {
          Plane { -k }
          Plane { -l }
        }
      }
      Replace { .empty }
    }
    #endif
  }
  return lattice.atoms
}
