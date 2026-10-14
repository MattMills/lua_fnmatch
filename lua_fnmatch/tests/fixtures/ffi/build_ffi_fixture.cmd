@echo off
rem build_ffi_fixture.cmd: builds ffi_fixture.dll and its PDB with MSVC. Run it from this
rem directory in a Visual Studio x64 developer prompt. The declarations ffi_fixture.ffi.lua
rem come from the PDB (see README.md, "Typed functions and classes: fnmatch.ffi"):
rem   stellar-fnmatch extract-one --exe ffi_fixture.dll --pdb ffi_fixture.pdb --id ffi_fixture --out ffi_fixture.fnx
rem   stellar-fnmatch cdef --pdb ffi_fixture.pdb --fnx ffi_fixture.fnx --exe ffi_fixture.dll --out ffi_fixture.ffi.lua --classes-file classes.txt --functions-file functions.txt
rem The .obj, .exp, .lib and vc140.pdb it leaves are not needed.
cl /nologo /LD /O1 /Zi /EHsc /MD /GS- ffi_fixture.cpp /link /DEBUG:FULL /INCREMENTAL:NO /OPT:REF /OPT:ICF /OUT:ffi_fixture.dll /PDB:ffi_fixture.pdb
