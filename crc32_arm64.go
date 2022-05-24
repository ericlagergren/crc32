// Copyright 2017 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// ARM64-specific hardware-assisted CRC32 algorithms. See crc32.go for a
// description of the interface that each architecture-specific file
// implements.

package crc32

import (
	"runtime"

	"golang.org/x/sys/cpu"
)

//go:noescape
func castagnoliUpdate(crc uint32, p []byte) uint32

//go:noescape
func ieeeUpdate(crc uint32, p []byte) uint32

//go:noescape
func ieeePMULL(crc uint32, p []byte) uint32

var hasCRC32 = cpu.ARM64.HasCRC32 || runtime.GOOS == "darwin"
var hasPMULL = cpu.ARM64.HasPMULL || runtime.GOOS == "darwin"

func archAvailableCastagnoli() bool {
	return hasCRC32
}

func archInitCastagnoli() {
	if !hasCRC32 {
		panic("arch-specific crc32 instruction for Catagnoli not available")
	}
}

func archUpdateCastagnoli(crc uint32, p []byte) uint32 {
	if !hasCRC32 {
		panic("arch-specific crc32 instruction for Castagnoli not available")
	}
	return ^castagnoliUpdate(^crc, p)
}

func archAvailableIEEE() bool {
	return hasCRC32
}

func archInitIEEE() {
	if !hasCRC32 {
		panic("arch-specific crc32 instruction for IEEE not available")
	}
}

func archUpdateIEEE(crc uint32, p []byte) uint32 {
	if !hasCRC32 {
		panic("arch-specific crc32 instruction for IEEE not available")
	}
	if hasPMULL && len(p) >= 64 {
		n := len(p) &^ 15
		crc = ^ieeePMULL(^crc, p[:n])
		p = p[n:]
	}
	if len(p) == 0 {
		return crc
	}
	return ^ieeeUpdate(^crc, p)
}
