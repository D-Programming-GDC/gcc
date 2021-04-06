// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package dwarf_test

import (
	. "debug/dwarf"
	"encoding/binary"
	"path/filepath"
	"reflect"
	"testing"
)

func TestSplit(t *testing.T) {
	// debug/dwarf doesn't (currently) support split DWARF, but
	// the attributes that pointed to the split DWARF used to
	// cause loading the DWARF data to fail entirely (issue
	// #12592). Test that we can at least read the DWARF data.
	d := elfData(t, "testdata/split.elf")
	r := d.Reader()
	e, err := r.Next()
	if err != nil {
		t.Fatal(err)
	}
	if e.Tag != TagCompileUnit {
		t.Fatalf("bad tag: have %s, want %s", e.Tag, TagCompileUnit)
	}
	// Check that we were able to parse the unknown section offset
	// field, even if we can't figure out its DWARF class.
	const AttrGNUAddrBase Attr = 0x2133
	f := e.AttrField(AttrGNUAddrBase)
	if _, ok := f.Val.(int64); !ok {
		t.Fatalf("bad attribute value type: have %T, want int64", f.Val)
	}
	if f.Class != ClassUnknown {
		t.Fatalf("bad class: have %s, want %s", f.Class, ClassUnknown)
	}
}

// wantRange maps from a PC to the ranges of the compilation unit
// containing that PC.
type wantRange struct {
	pc     uint64
	ranges [][2]uint64
}

func TestReaderSeek(t *testing.T) {
	want := []wantRange{
		{0x40059d, [][2]uint64{{0x40059d, 0x400601}}},
		{0x400600, [][2]uint64{{0x40059d, 0x400601}}},
		{0x400601, [][2]uint64{{0x400601, 0x400611}}},
		{0x4005f0, [][2]uint64{{0x40059d, 0x400601}}}, // loop test
		{0x10, nil},
		{0x400611, nil},
	}
	testRanges(t, "testdata/line-gcc.elf", want)

	want = []wantRange{
		{0x401122, [][2]uint64{{0x401122, 0x401166}}},
		{0x401165, [][2]uint64{{0x401122, 0x401166}}},
		{0x401166, [][2]uint64{{0x401166, 0x401179}}},
	}
	testRanges(t, "testdata/line-gcc-dwarf5.elf", want)

	want = []wantRange{
		{0x401130, [][2]uint64{{0x401130, 0x40117e}}},
		{0x40117d, [][2]uint64{{0x401130, 0x40117e}}},
		{0x40117e, nil},
	}
	testRanges(t, "testdata/line-clang-dwarf5.elf", want)
}

func TestRangesSection(t *testing.T) {
	want := []wantRange{
		{0x400500, [][2]uint64{{0x400500, 0x400549}, {0x400400, 0x400408}}},
		{0x400400, [][2]uint64{{0x400500, 0x400549}, {0x400400, 0x400408}}},
		{0x400548, [][2]uint64{{0x400500, 0x400549}, {0x400400, 0x400408}}},
		{0x400407, [][2]uint64{{0x400500, 0x400549}, {0x400400, 0x400408}}},
		{0x400408, nil},
		{0x400449, nil},
		{0x4003ff, nil},
	}
	testRanges(t, "testdata/ranges.elf", want)
}

func testRanges(t *testing.T, name string, want []wantRange) {
	d := elfData(t, name)
	r := d.Reader()
	for _, w := range want {
		entry, err := r.SeekPC(w.pc)
		if err != nil {
			if w.ranges != nil {
				t.Errorf("%s: missing Entry for %#x", name, w.pc)
			}
			if err != ErrUnknownPC {
				t.Errorf("%s: expected ErrUnknownPC for %#x, got %v", name, w.pc, err)
			}
			continue
		}

		ranges, err := d.Ranges(entry)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if !reflect.DeepEqual(ranges, w.ranges) {
			t.Errorf("%s: for %#x got %x, expected %x", name, w.pc, ranges, w.ranges)
		}
	}
}

func TestReaderRanges(t *testing.T) {
	type subprograms []struct {
		name   string
		ranges [][2]uint64
	}
	tests := []struct {
		filename    string
		subprograms subprograms
	}{
		{
			"testdata/line-gcc.elf",
			subprograms{
				{"f1", [][2]uint64{{0x40059d, 0x4005e7}}},
				{"main", [][2]uint64{{0x4005e7, 0x400601}}},
				{"f2", [][2]uint64{{0x400601, 0x400611}}},
			},
		},
		{
			"testdata/line-gcc-dwarf5.elf",
			subprograms{
				{"main", [][2]uint64{{0x401147, 0x401166}}},
				{"f1", [][2]uint64{{0x401122, 0x401147}}},
				{"f2", [][2]uint64{{0x401166, 0x401179}}},
			},
		},
		{
			"testdata/line-clang-dwarf5.elf",
			subprograms{
				{"main", [][2]uint64{{0x401130, 0x401144}}},
				{"f1", [][2]uint64{{0x401150, 0x40117e}}},
				{"f2", [][2]uint64{{0x401180, 0x401197}}},
			},
		},
	}

	for _, test := range tests {
		d := elfData(t, test.filename)
		subprograms := test.subprograms

		r := d.Reader()
		i := 0
		for entry, err := r.Next(); entry != nil && err == nil; entry, err = r.Next() {
			if entry.Tag != TagSubprogram {
				continue
			}

			if i > len(subprograms) {
				t.Fatalf("%s: too many subprograms (expected at most %d)", test.filename, i)
			}

			if got := entry.Val(AttrName).(string); got != subprograms[i].name {
				t.Errorf("%s: subprogram %d name is %s, expected %s", test.filename, i, got, subprograms[i].name)
			}
			ranges, err := d.Ranges(entry)
			if err != nil {
				t.Errorf("%s: subprogram %d: %v", test.filename, i, err)
				continue
			}
			if !reflect.DeepEqual(ranges, subprograms[i].ranges) {
				t.Errorf("%s: subprogram %d ranges are %x, expected %x", test.filename, i, ranges, subprograms[i].ranges)
			}
			i++
		}

		if i < len(subprograms) {
			t.Errorf("%s: saw only %d subprograms, expected %d", test.filename, i, len(subprograms))
		}
	}
}

func Test64Bit(t *testing.T) {
	// I don't know how to generate a 64-bit DWARF debug
	// compilation unit except by using XCOFF, so this is
	// hand-written.
	tests := []struct {
		name      string
		info      []byte
		addrSize  int
		byteOrder binary.ByteOrder
	}{
		{
			"32-bit little",
			[]byte{0x30, 0, 0, 0, // comp unit length
				4, 0, // DWARF version 4
				0, 0, 0, 0, // abbrev offset
				8, // address size
				0,
				0, 0, 0, 0, 0, 0, 0, 0,
				0, 0, 0, 0, 0, 0, 0, 0,
				0, 0, 0, 0, 0, 0, 0, 0,
				0, 0, 0, 0, 0, 0, 0, 0,
				0, 0, 0, 0, 0, 0, 0, 0,
			},
			8, binary.LittleEndian,
		},
		{
			"64-bit little",
			[]byte{0xff, 0xff, 0xff, 0xff, // 64-bit DWARF
				0x30, 0, 0, 0, 0, 0, 0, 0, // comp unit length
				4, 0, // DWARF version 4
				0, 0, 0, 0, 0, 0, 0, 0, // abbrev offset
				8, // address size
				0, 0, 0, 0, 0,
				0, 0, 0, 0, 0, 0, 0, 0,
				0, 0, 0, 0, 0, 0, 0, 0,
				0, 0, 0, 0, 0, 0, 0, 0,
				0, 0, 0, 0, 0, 0, 0, 0,
			},
			8, binary.LittleEndian,
		},
		{
			"64-bit big",
			[]byte{0xff, 0xff, 0xff, 0xff, // 64-bit DWARF
				0, 0, 0, 0, 0, 0, 0, 0x30, // comp unit length
				0, 4, // DWARF version 4
				0, 0, 0, 0, 0, 0, 0, 0, // abbrev offset
				8, // address size
				0, 0, 0, 0, 0,
				0, 0, 0, 0, 0, 0, 0, 0,
				0, 0, 0, 0, 0, 0, 0, 0,
				0, 0, 0, 0, 0, 0, 0, 0,
				0, 0, 0, 0, 0, 0, 0, 0,
			},
			8, binary.BigEndian,
		},
	}

	for _, test := range tests {
		data, err := New(nil, nil, nil, test.info, nil, nil, nil, nil)
		if err != nil {
			t.Errorf("%s: %v", test.name, err)
		}

		r := data.Reader()
		if r.AddressSize() != test.addrSize {
			t.Errorf("%s: got address size %d, want %d", test.name, r.AddressSize(), test.addrSize)
		}
		if r.ByteOrder() != test.byteOrder {
			t.Errorf("%s: got byte order %s, want %s", test.name, r.ByteOrder(), test.byteOrder)
		}
	}
}

func TestUnitIteration(t *testing.T) {
	// Iterate over all ELF test files we have and ensure that
	// we get the same set of compilation units skipping (method 0)
	// and not skipping (method 1) CU children.
	files, err := filepath.Glob(filepath.Join("testdata", "*.elf"))
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		t.Run(file, func(t *testing.T) {
			d := elfData(t, file)
			var units [2][]interface{}
			for method := range units {
				for r := d.Reader(); ; {
					ent, err := r.Next()
					if err != nil {
						t.Fatal(err)
					}
					if ent == nil {
						break
					}
					if ent.Tag == TagCompileUnit {
						units[method] = append(units[method], ent.Val(AttrName))
					}
					if method == 0 {
						if ent.Tag != TagCompileUnit {
							t.Fatalf("found unexpected tag %v on top level", ent.Tag)
						}
						r.SkipChildren()
					}
				}
			}
			t.Logf("skipping CUs:     %v", units[0])
			t.Logf("not-skipping CUs: %v", units[1])
			if !reflect.DeepEqual(units[0], units[1]) {
				t.Fatal("set of CUs differ")
			}
		})
	}
}
