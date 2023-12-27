// Save as GitHub Gist instead of polluting the molecular-renderer source tree.

import Foundation
import HDL
import MolecularRenderer
import Numerics

func render100Reconstruction() -> [MRAtom] {
  var lattices: [[Entity]] = []
  lattices.append(latticeBasic100())
  lattices.append(latticeAdvanced100())
  lattices.append(latticeSpherical100())
  let topologies = lattices
    .map(reconstruct100(_:))
    .map(labelCarbonTypes(_:))
  
  var diamondoid = latticeDiamondoid()
  diamondoid.transform { $0.origin.y -= 3 }
  
  var output: [MRAtom] = []
  output += diamondoid.atoms
  output += topologies[0].atoms.map(MRAtom.init)
  output += topologies[1].atoms.map(MRAtom.init).map {
    var copy = $0
    copy.origin.x += 3
    return copy
  }
  output += topologies[2].atoms.map(MRAtom.init).map {
    var copy = $0
    copy.origin.x += 3
    copy.origin.y -= 4.5
    return copy
  }
  return output
}

func reconstruct100(_ atoms: [Entity]) -> Topology {
  var topology = Topology()
  topology.insert(atoms: atoms)
  
  let ccBondMatches = topology.match(topology.atoms)
  var ccBonds: [SIMD2<UInt32>] = []
  for i in topology.atoms.indices {
    for j in ccBondMatches[i] {
      if i < j {
        let bond = SIMD2(UInt32(i), UInt32(j))
        ccBonds.append(bond)
      }
    }
  }
  topology.insert(bonds: ccBonds)
  cleanupLooseCarbons(&topology, minimumNeighborCount: 1)
  
  regenerateHydrogens(&topology)
  cleanupFourHydrogenCollisions(&topology)
  cleanupThreeHydrogenCollisions(&topology)
  cleanupLooseCarbons(&topology, minimumNeighborCount: 2)
  cleanupLooseCarbons(&topology, minimumNeighborCount: 2)
  nudgeReconstructedCarbons(&topology)
  
  regenerateHydrogens(&topology)
  reconstruct100Chains(&topology)
  nudgeReconstructedCarbons(&topology)
  
  // TODO: Validate that the structures simulate in the old MM4 simulator.
  // Determine what the minimized bond topology actually looks like around these
  // carbons.
  //
  // TODO: If a carbon has 2 reconstructed bonds, create some nudges to make the
  // bond angles farther from 90 degrees and a little closer to 109.5 degrees.
  // Also, nudge those carbons a bit closer.
  regenerateHydrogens(&topology)
  createHydrogenBonds(&topology)
  return topology
}

// Searches for any pairs of hydrogens in a very simple situation. They collide,
// but their respective carbons are the only 5-ring carbons in the vicinity.
// There is no ambiguity about where to place bonds.
//
// Examples include bonds in the crevice between two (110) or (111) planes.
//
// The remaining situations, e.g. lines with several bonds, are not as simple.
// They are not handled yet. They might be the last missing piece before 99%
// of (100)-like collisions can be automatically reconstructed.
func reconstruct100Chains(_ topology: inout Topology) {
  let chBondLength =
  Element.carbon.covalentRadius + Element.hydrogen.covalentRadius
  
  let matches = topology.match(
    topology.atoms, algorithm: .absoluteRadius(0.080))
  let farMatches = topology.match(
    topology.atoms, algorithm: .absoluteRadius(chBondLength * 1.01))
  var carbonToCollisionMap: [Int: [SIMD2<UInt32>]] = [:]
  var collisionToCarbonMap: [SIMD2<UInt32>: [Int]] = [:]
  
  for i in topology.atoms.indices {
    let range = matches[i]
    guard topology.atoms[i].atomicNumber == 1 else {
      continue
    }
    if range.count == 2 {
      var list: [UInt32] = []
      list.append(UInt32(i))
      for j in range[(range.startIndex+1)...] {
        list.append(j)
      }
      list.sort()
      
      var collision: SIMD2<UInt32> = .zero
      for lane in 0..<2 {
        collision[lane] = list[lane]
      }
      let farMatchRange = farMatches[i]
      precondition(farMatchRange.count == 3)
      
      let carbonID = Int(farMatchRange[farMatchRange.endIndex - 1])
      var previous = carbonToCollisionMap[carbonID] ?? []
      previous.append(collision)
      carbonToCollisionMap[carbonID] = previous
      
      do {
        var previous = collisionToCarbonMap[collision] ?? []
        previous.append(carbonID)
        collisionToCarbonMap[collision] = previous
      }
    }
  }
  
  // To form chains, start at the end. Start with a place where there's
  // asymmetry. One carbon on a collision is free, the others are not. Remove
  // that carbon/collision from the list and add to the chain. Repeat another
  // time, except the carbon knows where the previous chain is (instead of
  // steading a new chain).
  
  // Finally, decide which carbon should start the chain. Rules in order of
  // priority:
  // - 1) One side is embedded within the bulk structure (bridgehead).
  // - 2) Whether both are bridgeheads
  //   - TODO: slightly more complex heuristics are needed for this case
  // - 3) Which end has the most negative X/Y/Z coordinates.
  
  // More simple approach:
  // - Walk inward from the edges, one atom at a time.
  // - The inner carbon becomes part of 2 5-membered rings. Being closest to
  //   the bulk, it has the smallest possible chance of also being in a ring
  //   somewhere else. In 99% of cases, it does not form a 4-membered ring.
  
  var hydrogensToRemove: [UInt32] = []
  
  // This function returns the number of collisions that were removed. Many
  // removals are duplicates, but all that matters is whether the return value
  // is zero.
  func shortenChainIteration() -> Int {
    var collisionsToRemove: [SIMD2<UInt32>: Bool] = [:]
    var carbonCollisionPairsToRemove: [SIMD3<UInt32>: Bool] = [:]
    
    for (collision, carbons) in collisionToCarbonMap {
      precondition(carbons.count == 2)
      
      var numCarbonsFree = 0
      var carbon1: Int = -1
      var carbon2: Int = -1
      for carbon in carbons {
        let collisions = carbonToCollisionMap[carbon]!
        if collisions.count == 1 {
          numCarbonsFree += 1
          carbon1 = carbon
        } else {
          precondition(collisions.count == 2, "Carbon had >2 collisions..")
          carbon2 = carbon
        }
      }
      
      if numCarbonsFree == 2 {
        // This chain is extremely simple to reconstruct.
        hydrogensToRemove.append(collision[0])
        hydrogensToRemove.append(collision[1])
        
        let newBond = SIMD2(UInt32(carbons[0]),
                            UInt32(carbons[1]))
        topology.insert(bonds: [newBond])
        
        carbonCollisionPairsToRemove[
          SIMD3(collision, UInt32(carbons[0]))] = true
        carbonCollisionPairsToRemove[
          SIMD3(collision, UInt32(carbons[1]))] = true
        collisionsToRemove[collision] = true
      } else if numCarbonsFree == 1 {
        hydrogensToRemove.append(collision[0])
        hydrogensToRemove.append(collision[1])
        
        let newBond = SIMD2(UInt32(carbons[0]),
                            UInt32(carbons[1]))
        topology.insert(bonds: [newBond])
        
        carbonCollisionPairsToRemove[
          SIMD3(collision, UInt32(carbons[0]))] = true
        carbonCollisionPairsToRemove[
          SIMD3(collision, UInt32(carbons[1]))] = true
        
        let collisions1 = carbonToCollisionMap[carbon1]!
        let collisions2 = carbonToCollisionMap[carbon2]!
        precondition(collisions1.count == 1)
        precondition(collisions2.count == 2)
        
        for collision in collisions2 {
          let carbons = collisionToCarbonMap[collision]!
          carbonCollisionPairsToRemove[
            SIMD3(collision, UInt32(carbons[0]))] = true
          carbonCollisionPairsToRemove[
            SIMD3(collision, UInt32(carbons[1]))] = true
          collisionsToRemove[collision] = true
        }
      }
    }
    
    for pair in carbonCollisionPairsToRemove.keys {
      let carbon = Int(pair[2])
      let collision = SIMD2(pair[0], pair[1])
      var previous = carbonToCollisionMap[carbon]!
      precondition(previous.contains(collision))
      
      previous.removeFirst(value: collision)
      if previous.count == 0 {
        _ = carbonToCollisionMap.removeValue(forKey: carbon)!
      } else {
        carbonToCollisionMap[carbon] = previous
      }
    }
    for collision in collisionsToRemove.keys {
      _ = collisionToCarbonMap.removeValue(forKey: collision)!
    }
    return collisionsToRemove.keys.count
  }
  
  // If the number of remaining keys doesn't change after an iteration, the
  // algorithm has failed to converge. If it reaches zero, it has converged.
  while true {
    let removed = shortenChainIteration()
    if removed <= 0 {
      break
    }
  }
  
  topology.remove(atoms: hydrogensToRemove)
}
