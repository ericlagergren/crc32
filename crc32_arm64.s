// Copyright 2017 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include "textflag.h"

// castagnoliUpdate updates the non-inverted crc with the given data.

// func castagnoliUpdate(crc uint32, p []byte) uint32
TEXT ·castagnoliUpdate(SB), NOSPLIT, $0-36
	MOVWU crc+0(FP), R9     // CRC value
	MOVD  p+8(FP), R13      // data pointer
	MOVD  p_len+16(FP), R11 // len(p)

	CMP $8, R11
	BLT less_than_8

update:
	MOVD.P  8(R13), R10
	CRC32CX R10, R9
	SUB     $8, R11

	CMP $8, R11
	BLT less_than_8

	JMP update

less_than_8:
	TBZ $2, R11, less_than_4

	MOVWU.P 4(R13), R10
	CRC32CW R10, R9

less_than_4:
	TBZ $1, R11, less_than_2

	MOVHU.P 2(R13), R10
	CRC32CH R10, R9

less_than_2:
	TBZ $0, R11, done

	MOVBU   (R13), R10
	CRC32CB R10, R9

done:
	MOVWU R9, ret+32(FP)
	RET

// ieeeUpdate updates the non-inverted crc with the given data.

// func ieeeUpdate(crc uint32, p []byte) uint32
TEXT ·ieeeUpdate(SB), NOSPLIT, $0-36
	MOVWU crc+0(FP), R9     // CRC value
	MOVD  p+8(FP), R13      // data pointer
	MOVD  p_len+16(FP), R11 // len(p)

	CMP $8, R11
	BLT less_than_8

update:
	MOVD.P 8(R13), R10
	CRC32X R10, R9
	SUB    $8, R11

	CMP $8, R11
	BLT less_than_8

	JMP update

less_than_8:
	TBZ $2, R11, less_than_4

	MOVWU.P 4(R13), R10
	CRC32W  R10, R9

less_than_4:
	TBZ $1, R11, less_than_2

	MOVHU.P 2(R13), R10
	CRC32H  R10, R9

less_than_2:
	TBZ $0, R11, done

	MOVBU  (R13), R10
	CRC32B R10, R9

done:
	MOVWU R9, ret+32(FP)
	RET

// func ieeePMULL(crc uint32, p []byte) uint32
TEXT ·ieeePMULL(SB), NOSPLIT, $0-36
#define value R0
#define p_ptr R1
#define remain R2
#define data R3

#define v0 V0
#define v1 V1
#define v2 V2
#define v3 V3
#define v4 V4
#define v5 V5
#define v6 V6
#define v7 V7
#define v8 V8
#define v9 V9
#define v10 V10
#define v11 V11

#define r0 V12
#define r1 V13
#define r2 V14
#define r3 V15
#define r4 V16
#define r5 V17
#define r6 V18
#define r7 V19
#define r8 V20
#define r9 V21
#define r10 V22
#define r11 V23

#define tmp V24

#define poly V28
#define k12 V29
#define k34 V30
#define k45 V31

// The algorithm is taken from Intel's "Fast CRC Computation
// Using PCLMULQDQ Instruction" paper [intel] with the idea for
// a fold-by-12 taken from [dougallj].
//
// [intel] https://www.intel.com/content/dam/www/public/us/en/documents/white-papers/fast-crc-computation-generic-polynomials-pclmulqdq-paper.pdf
// [dougallj] https://dougallj.wordpress.com/2022/05/22/faster-crc32-on-the-apple-m1/

// reduce sets
//    tmp = ki*a
//    a   = ki*a
//    a   = a^b^tmp
//
// The Apple M1 fuses VPMULL + VEOR if it matches one of
//    VPMULL A, B, C
//    VEOR   A, A, D
// or
//    VPMULL A, B, C
//    VEOR   A, D, A
#define reduce(a, b, ki) \
	VPMULL  ki.D1, a.D1, tmp.Q1     \
	VEOR    b.B16, tmp.B16, tmp.B16 \
	VPMULL2 ki.D2, a.D2, a.Q1       \
	VEOR    a.B16, tmp.B16, a.B16

	MOVWU crc+0(FP), value
	MOVD  p+8(FP), p_ptr
	MOVD  p_len+16(FP), remain

	// k12 is assigned inside either have12blocks or have4blocks.
	VMOVQ $0x1751997d0, $0x0ccaa009e, k34
	VMOVQ $0xccaa009e, $0x163cd6124, k45
	VMOVQ $0x1f7011641, $0x1db710641, poly

	VEOR tmp.B16, tmp.B16, tmp.B16
	VMOV value, tmp.S[0]

	// Are there at least 12 blocks?
	//
	// Note that the two strides (12 and 4) are mutually
	// exclusive since they require a different k12 value. Both
	// paths reconnect for steps 2 and 3, though.
	CMP $192, remain
	BLO have4blocks

	// We have at least 12 blocks, so process 12 at a time.
have12blocks:
	// k12 is taken from [dougallj].
	VMOVQ $0x1821d8bc0, $0x12e958ac4, k12

	VLD1.P 64(p_ptr), [v0.B16, v1.B16, v2.B16, v3.B16]
	VLD1.P 64(p_ptr), [v4.B16, v5.B16, v6.B16, v7.B16]
	VLD1.P 64(p_ptr), [v8.B16, v9.B16, v10.B16, v11.B16]

	// XOR in the input: v0 ^= value
	VEOR tmp.B16, v0.B16, v0.B16

	SUB $192, remain
	CMP $192, remain
	BLO fold12to1

	// Step 1: iteratively fold by twelve.
	//
	// Perform the following (simplified to folding by 12).
	//
	// | v3 | v2 | v1 | v0 | r3 | r2 | r1 | r0 | ...
	//   |    |    |    |    |    |    |    |
	//   |    |    |    |____|____|____|___XOR
	//   |    |    |_________|____|___XOR   |
	//   |    |______________|___XOR   |    |
	//   |__________________XOR   |    |    |
	//                       |    |    |    |
	//                       v0   v1   v2   v3
reduceBy12:
	VLD1.P 64(p_ptr), [r0.B16, r1.B16, r2.B16, r3.B16]
	VLD1.P 64(p_ptr), [r4.B16, r5.B16, r6.B16, r7.B16]
	VLD1.P 64(p_ptr), [r8.B16, r9.B16, r10.B16, r11.B16]

	reduce(v0, r0, k12)
	reduce(v1, r1, k12)
	reduce(v2, r2, k12)
	reduce(v3, r3, k12)
	reduce(v4, r4, k12)
	reduce(v5, r5, k12)
	reduce(v6, r6, k12)
	reduce(v7, r7, k12)
	reduce(v8, r8, k12)
	reduce(v9, r9, k12)
	reduce(v10, r10, k12)
	reduce(v11, r11, k12)

	SUB $192, remain
	CMP $191, remain
	BHI reduceBy12

	// Complete step 1 by folding the 12 blocks down into
	// a single 128-bit block.
fold12to1:
	reduce(v0, v1, k34)
	reduce(v0, v2, k34)
	reduce(v0, v3, k34)
	reduce(v0, v4, k34)
	reduce(v0, v5, k34)
	reduce(v0, v6, k34)
	reduce(v0, v7, k34)
	reduce(v0, v8, k34)
	reduce(v0, v9, k34)
	reduce(v0, v10, k34)
	reduce(v0, v11, k34)

	// Are there any remaining singles?
	CMP $16, remain
	BLO step3
	B   step2

	// We have at least 4 blocks, so process 4 at a time.
have4blocks:
	VMOVQ $0x154442bd4, $0x1c6e41596, k12

	VLD1.P 64(p_ptr), [v0.B16, v1.B16, v2.B16, v3.B16]

	// XOR in the input: v0 ^= value
	VEOR tmp.B16, v0.B16, v0.B16

	SUB $64, remain
	CMP $64, remain
	BLO fold4to1

reduceBy4:
	VLD1.P 64(p_ptr), [r0.B16, r1.B16, r2.B16, r3.B16]

	reduce(v0, r0, k12)
	reduce(v1, r1, k12)
	reduce(v2, r2, k12)
	reduce(v3, r3, k12)

	SUB $64, remain
	CMP $63, remain
	BHI reduceBy4

fold4to1:
	reduce(v0, v1, k34)
	reduce(v0, v2, k34)
	reduce(v0, v3, k34)

	// Are there any remaining singles?
	CMP $16, remain
	BLO step3

	// Step 2: Iteratively fold in the remaining 128-bit blocks.
step2:
	VLD1.P 16(p_ptr), [r0.B16]
	reduce(v0, r0, k34)
	SUB    $16, remain
	CMP    $15, remain
	BHI    step2

#define x v0
#define a r0
#define b r1
#define c r2
#define d r3

// Final reduction.
// Input: degree-63 polynomial R(x),
//        degree-32 polynomial P(x),
//        μ = floor((x^64 / P(x)))
// Output: C(x) = R(x) mod P(x)
// Step 1: T1(x) = floor((R(x)/x^32)) * μ
// Step 2: T2(x) = floor((T1(x)/x^32)) * P(x)
// Step 3: C(x) = R(x) xor T2(x) mod x^32
// After step 3, the 32 high-order coefficients of C will be 0.
step3:
	VPMULL  k45.D1, x.D1, b.Q1  // b = x*k45
	VEOR    c.B16, c.B16, c.B16 // c[1] = 0
	VMOV    x.D[1], c.D[0]      // c[0] = x[1]
	VEOR    b.B16, c.B16, a.B16 // a = b^c
	VEOR    d.B16, d.B16, d.B16 // d = 0
	VMOV    a.S[0], d.S[2]      // d[2] = a[0]
	VMOV    a.S[1], a.S[0]      // a[0] = a[1]
	VMOV    a.S[2], a.S[1]      // a[1] = a[2]
	VMOV    a.B16, b.B16        // b = a
	VPMULL2 d.D2, k45.D2, a.Q1  // a = d*k45
	VEOR    a.B16, b.B16, a.B16 // a ^= b
	VMOV    a.S[0], d.S[0]      // d[0] = a[0]
	VPMULL  d.D1, poly.D1, b.Q1 // b = d*poly
	VMOV    b.S[0], d.S[2]      // d[2] = b[0]
	VMOV    a.B16, b.B16        // b = a
	VPMULL2 d.D2, poly.D2, a.Q1 // a = d*poly
	VEOR    a.B16, b.B16, a.B16 // a ^= b

	VMOV  a.S[1], value
	MOVWU value, ret+32(FP)
	RET

#undef a
#undef b
#undef c
#undef d
#undef x

#undef value
#undef p_ptr
#undef remain
#undef data

#undef v0
#undef v1
#undef v2
#undef v3
#undef v4
#undef v5
#undef v6
#undef v7
#undef v8
#undef v9
#undef v10
#undef v11

#undef r0
#undef r1
#undef r2
#undef r3
#undef r4
#undef r5
#undef r6
#undef r7
#undef r8
#undef r9
#undef r10
#undef r11

#undef tmp

#undef poly
#undef k12
#undef k34
#undef k45
