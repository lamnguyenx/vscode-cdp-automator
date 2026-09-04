.PHONY: vscode-ui-resizer clean

vscode-ui-resizer: vscode-ui-resizer/vscode-ui-resizer.exe

vscode-ui-resizer/vscode-ui-resizer.exe: vscode-ui-resizer/*.swift
	swiftc -o vscode-ui-resizer/vscode-ui-resizer.exe vscode-ui-resizer/*.swift
	@echo "Built vscode-ui-resizer/vscode-ui-resizer.exe"

clean:
	rm -f vscode-ui-resizer/vscode-ui-resizer.exe windows-resizer/windows-resizer.exe panel-resizer/panel-resizer.exe

