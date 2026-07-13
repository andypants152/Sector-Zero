import Foundation

/// A decoded 8086 instruction, independent of how its bytes were fetched.
///
/// Milestone 3 covers only the single-byte opcodes NOP and HLT; any other
/// opcode decodes to `.unknown` carrying the raw byte so callers can surface
/// or trap it. Operand-bearing cases (immediates, ModR/M) will be added as
/// later milestones land.
enum Instruction: Equatable {
    case nop
    case hlt
    case movImmediateToRegister8(Register8, UInt8)
    case movImmediateToRegister16(Register16, UInt16)
    case movRegisterToRM8(source: Register8, destination: ModRMOperand, eaClocks: Int)
    case movRegisterToRM16(source: Register16, destination: ModRMOperand, eaClocks: Int)
    case movRMToRegister8(destination: Register8, source: ModRMOperand, eaClocks: Int)
    case movRMToRegister16(destination: Register16, source: ModRMOperand, eaClocks: Int)
    case aluRegisterToRM8(op: ALUBinaryOp, source: Register8, destination: ModRMOperand, eaClocks: Int)
    case aluRegisterToRM16(op: ALUBinaryOp, source: Register16, destination: ModRMOperand, eaClocks: Int)
    case aluRMToRegister8(op: ALUBinaryOp, destination: Register8, source: ModRMOperand, eaClocks: Int)
    case aluRMToRegister16(op: ALUBinaryOp, destination: Register16, source: ModRMOperand, eaClocks: Int)
    case unknown(UInt8)
}

/// A binary ALU operation decoded from an r/m↔reg opcode block. SUB and CMP
/// join in milestone 11.
enum ALUBinaryOp: Equatable, Sendable {
    case add
}
