//
//  Minimize.swift
//  MolecularRendererApp
//
//  Created by Philip Turner on 12/28/23.
//

import Foundation
import HDL
import MM4
import MolecularRenderer
import Numerics
import OpenMM

func minimizeTopology(_ topology: inout Topology) {
  var paramsDesc = MM4ParametersDescriptor()
  paramsDesc.atomicNumbers = topology.atoms.map(\.atomicNumber)
  paramsDesc.bonds = topology.bonds
  paramsDesc.hydrogenMassScale = 1
  let parameters = try! MM4Parameters(descriptor: paramsDesc)
  
  // MARK: - Stretch Force
  
  let stretchForce = OpenMM_CustomBondForce(energy: """
    potentialWellDepth * ((
      1 - exp(-beta * (r - equilibriumLength))
    )^2 - 1);
    """)
  stretchForce.addPerBondParameter(name: "potentialWellDepth")
  stretchForce.addPerBondParameter(name: "beta")
  stretchForce.addPerBondParameter(name: "equilibriumLength")
  
  do {
    let array = OpenMM_DoubleArray(size: 3)
    let bonds = parameters.bonds
    for bondID in bonds.indices.indices {
      // Pre-multiply constants in formulas as much as possible. For example,
      // the "beta" constant for bond stretch is multiplied by
      // 'OpenMM_AngstromsPerNm'. This reduces the amount of computation during
      // force execution.
      let bond = bonds.indices[bondID]
      let parameters = bonds.parameters[bondID]
      
      // Units: millidyne-angstrom -> kJ/mol
      var potentialWellDepth = Double(parameters.potentialWellDepth)
      potentialWellDepth *= MM4KJPerMolPerAJ
      
      // Units: angstrom^-1 -> nm^-1
      var beta = Double(
        parameters.stretchingStiffness / (2 * parameters.potentialWellDepth)
      ).squareRoot()
      beta /= OpenMM_NmPerAngstrom
      
      // Units: angstrom -> nm
      var equilibriumLength = Double(parameters.equilibriumLength)
      equilibriumLength *= OpenMM_NmPerAngstrom
      
      let particles = SIMD2<Int>(truncatingIfNeeded: bond)
      array[0] = potentialWellDepth
      array[1] = beta
      array[2] = equilibriumLength
      stretchForce.addBond(particles: particles, parameters: array)
    }
  }
  
  // MARK: - Bend Force
  
  let bendForce = OpenMM_CustomCompoundBondForce(numParticles: 3, energy: """
    bend;
    bend = bendingStiffness * deltaTheta^2;
    deltaTheta = angle(p1, p2, p3) - equilibriumAngle;
    """)
  bendForce.addPerBondParameter(name: "bendingStiffness")
  bendForce.addPerBondParameter(name: "equilibriumAngle")
  bendForce.addPerBondParameter(name: "stretchBendStiffness")
  bendForce.addPerBondParameter(name: "equilibriumLengthLeft")
  bendForce.addPerBondParameter(name: "equilibriumLengthRight")
  
  do {
    let particles = OpenMM_IntArray(size: 3)
    let array = OpenMM_DoubleArray(size: 5)
    let bonds = parameters.bonds
    let angles = parameters.angles
    for angleID in angles.indices.indices {
      let angle = angles.indices[angleID]
      let parameters = angles.parameters[angleID]
      
      // Units: millidyne-angstrom/rad^2 -> kJ/mol/rad^2
      //
      // WARNING: 143 needs to be divided by 2 before it becomes 71.94.
      var bendingStiffness = Double(parameters.bendingStiffness)
      bendingStiffness *= MM4KJPerMolPerAJ
      bendingStiffness /= 2
      
      // Units: degree -> rad
      var equilibriumAngle = Double(parameters.equilibriumAngle)
      equilibriumAngle *= OpenMM_RadiansPerDegree
      
      // Units: millidyne-angstrom/rad^2 -> kJ/mol/rad^2
      //
      // This part does not need to be divided by 2; it was never divided by
      // 2 in the first place (2.5118 was used instead of 1.2559).
      var stretchBendStiffness = Double(parameters.stretchBendStiffness)
      stretchBendStiffness *= MM4KJPerMolPerAJ
      
      // Units: angstrom -> nm
      @inline(__always)
      func sortBond<T>(_ codes: SIMD2<T>) -> SIMD2<T>
      where T: FixedWidthInteger {
        if codes[0] > codes[1] {
          return SIMD2(codes[1], codes[0])
        } else {
          return codes
        }
      }
      let bondLeft = sortBond(SIMD2(angle[0], angle[1]))
      let bondRight = sortBond(SIMD2(angle[1], angle[2]))
      
      @inline(__always)
      func createLength(_ bond: SIMD2<UInt32>) -> Double {
        guard let bondID = bonds.map[bond] else {
          fatalError("Invalid bond.")
        }
        let parameters = bonds.parameters[Int(bondID)]
        var equilibriumLength = Double(parameters.equilibriumLength)
        equilibriumLength *= OpenMM_NmPerAngstrom
        return equilibriumLength
      }
      
      let reorderedAngle = SIMD3<Int>(truncatingIfNeeded: angle)
      for lane in 0..<3 {
        particles[lane] = reorderedAngle[lane]
      }
      array[0] = bendingStiffness
      array[1] = equilibriumAngle
      array[2] = stretchBendStiffness
      array[3] = createLength(bondLeft)
      array[4] = createLength(bondRight)
      bendForce.addBond(particles: particles, parameters: array)
    }
  }
  
  func createExceptions(force: OpenMM_CustomNonbondedForce) {
    for bond in parameters.bonds.indices {
      let reordered = SIMD2<Int>(truncatingIfNeeded: bond)
      force.addExclusion(particles: reordered)
    }
    for exception in parameters.nonbondedExceptions13 {
      let reordered = SIMD2<Int>(truncatingIfNeeded: exception)
      force.addExclusion(particles: reordered)
    }
  }
  
  var cutoff: Double {
    // Since germanium will rarely be used, use the cutoff for silicon. The
    // slightly greater sigma for carbon allows greater accuracy in vdW forces
    // for bulk diamond. 1.020 nm also accomodates charge-charge interactions.
    let siliconRadius = 2.290 * OpenMM_NmPerAngstrom
    return siliconRadius * 2.5 * OpenMM_SigmaPerVdwRadius
  }
  
  let nonbondedForce = OpenMM_CustomNonbondedForce(energy: """
    epsilon * (
      -2.25 * (min(2, radius / r))^6 +
      1.84e5 * exp(-12.00 * (r / radius))
    );
    epsilon = select(isHydrogenBond, heteroatomEpsilon, hydrogenEpsilon);
    radius = select(isHydrogenBond, heteroatomRadius, hydrogenRadius);
    
    isHydrogenBond = step(hydrogenEpsilon1 * hydrogenEpsilon2);
    heteroatomEpsilon = sqrt(epsilon1 * epsilon2);
    hydrogenEpsilon = max(hydrogenEpsilon1, hydrogenEpsilon2);
    heteroatomRadius = radius1 + radius2;
    hydrogenRadius = max(hydrogenRadius1, hydrogenRadius2);
    """)
  nonbondedForce.addPerParticleParameter(name: "epsilon")
  nonbondedForce.addPerParticleParameter(name: "hydrogenEpsilon")
  nonbondedForce.addPerParticleParameter(name: "radius")
  nonbondedForce.addPerParticleParameter(name: "hydrogenRadius")
  
  nonbondedForce.nonbondedMethod = .cutoffNonPeriodic
  nonbondedForce.useSwitchingFunction = true
  nonbondedForce.cutoffDistance = cutoff
  nonbondedForce.switchingDistance = cutoff * pow(1.0 / 3, 1.0 / 6)
  
  do {
    let array = OpenMM_DoubleArray(size: 4)
    let atoms = parameters.atoms
    for atomID in parameters.atoms.indices {
      let parameters = atoms.parameters[Int(atomID)]
      
      // Units: kcal/mol -> kJ/mol
      let (epsilon, hydrogenEpsilon) = parameters.epsilon
      array[0] = Double(epsilon) * OpenMM_KJPerKcal
      array[1] = Double(hydrogenEpsilon) * OpenMM_KJPerKcal
      
      // Units: angstrom -> nm
      let (radius, hydrogenRadius) = parameters.radius
      array[2] = Double(radius) * OpenMM_NmPerAngstrom
      array[3] = Double(hydrogenRadius) * OpenMM_NmPerAngstrom
      nonbondedForce.addParticle(parameters: array)
    }
    createExceptions(force: nonbondedForce)
  }
  
  // MARK: - System
  
  let system = OpenMM_System()
  let arrayP = OpenMM_Vec3Array(size: parameters.atoms.count)
  let arrayV = OpenMM_Vec3Array(size: parameters.atoms.count)
  for atomID in parameters.atoms.indices {
    // Units: yg -> amu
    var mass = parameters.atoms.masses[atomID]
    mass *= Float(MM4AmuPerYg)
    system.addParticle(mass: Double(mass))
    arrayP[atomID] = SIMD3<Double>(topology.atoms[atomID].position)
    arrayV[atomID] = SIMD3<Double>.zero
  }
  
  stretchForce.transfer()
  bendForce.transfer()
  nonbondedForce.transfer()
  system.addForce(stretchForce)
  system.addForce(bendForce)
  system.addForce(nonbondedForce)
  
  let integrator = OpenMM_VerletIntegrator(stepSize: 0.001)
  let context = OpenMM_Context(system: system, integrator: integrator)
  context.positions = arrayP
  context.velocities = arrayV
  
  // MARK: - Minimization
  
  @discardableResult
  func reportState() -> [SIMD3<Float>] {
    let dataTypes: OpenMM_State.DataType = [
      OpenMM_State.DataType.energy, OpenMM_State.DataType.positions
    ]
    let query = context.state(types: dataTypes)
    let positions = query.positions
    var output: [SIMD3<Float>] = []
    
    print(query.potentialEnergy * MM4ZJPerKJPerMol,
          query.kineticEnergy * MM4ZJPerKJPerMol)
    for i in parameters.atoms.indices {
      let modified = SIMD3<Float>(positions[i])
      output.append(modified)
    }
    return output
  }
  reportState()

  OpenMM_LocalEnergyMinimizer.minimize(context: context)
  let minimizedPositions = reportState()
  for i in parameters.atoms.indices {
    topology.atoms[i].position = minimizedPositions[i]
  }
}
