.PHONY: vscode-ui-resizer clean

vscode-ui-resizer: vscode-ui-resizer/vscode-ui-resizer.exe

vscode-ui-resizer/vscode-ui-resizer.exe: vscode-ui-resizer/Package.swift vscode-ui-resizer/*.swift
	cd vscode-ui-resizer && swift build -c release --disable-sandbox
	cp .build/release/vscode-ui-resizer vscode-ui-resizer.exe
	@echo "Built vscode-ui-resizer/vscode-ui-resizer.exe"

clean:
	rm -f vscode-ui-resizer/vscode-ui-resizer.exe windows-resizer/windows-resizer.exe panel-resizer/panel-resizer.exe

