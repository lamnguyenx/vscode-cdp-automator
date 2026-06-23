.PHONY: windows-resizer panel-resizer clean

windows-resizer: windows-resizer/windows-resizer.exe

windows-resizer/windows-resizer.exe: windows-resizer/windows-resizer.swift
	swiftc -o windows-resizer/windows-resizer.exe windows-resizer/windows-resizer.swift
	@echo "Built windows-resizer/windows-resizer.exe"

panel-resizer: panel-resizer/panel-resizer.exe

panel-resizer/panel-resizer.exe: panel-resizer/panel-resizer.swift
	swiftc -o panel-resizer/panel-resizer.exe panel-resizer/panel-resizer.swift
	@echo "Built panel-resizer/panel-resizer.exe"

clean:
	rm -f windows-resizer/windows-resizer.exe panel-resizer/panel-resizer.exe
